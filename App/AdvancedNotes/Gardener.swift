import Foundation
import NotesCore

/// Two jobs that both come down to clustering: deriving a taxonomy from
/// scratch, and noticing when an existing one has gone wrong.
@MainActor
final class Gardener {

    private let vault: Vault
    private let embedding: EmbedderBox

    init(vault: Vault, embedding: EmbedderBox) {
        self.vault = vault
        self.embedding = embedding
    }

    // MARK: - Cold start

    /// Derive a starting taxonomy from the notes in Inbox, once there are
    /// enough of them to cluster.
    ///
    /// An empty vault has no centroids to compare against, so the first notes
    /// would each invent a collection from their own incidental wording —
    /// which is how you get "Covering Deduction" instead of "Tax". Letting
    /// them queue and then clustering once means each name comes from what a
    /// group of notes has in common rather than from whichever note arrived
    /// first.
    @discardableResult
    func bootstrap() async -> [String] {
        let unfiled = vault.inbox.filter { !$0.vector.isEmpty }
        let k = Clustering.chooseK(count: unfiled.count)
        guard k >= 2 else { return [] }

        let clusters = Clustering.cluster(unfiled.map(\.vector), k: k)
        var created: [String] = []
        var existing = Set(vault.collectionPaths)

        for cluster in clusters where cluster.members.count >= 3 {
            let members = cluster.members.map { unfiled[$0] }
            let texts = members.map { $0.note.embeddingText }
            guard let name = Clustering.name(from: texts, existing: existing) else { continue }

            // Through the gate, not around it. A derived name is still a
            // proposal, and the whole point of the gate is that nothing
            // creates a collection without passing it.
            let nameVector = await embedding.embed(name)
            let outcome = Gate.decide(
                proposed: name,
                existing: vault.gateCandidates(),
                aliases: vault.aliases,
                proposedVector: nameVector,
                thresholds: Thresholds.appleGuess(embedderID: embedding.identifier)
            )
            guard case let .create(folder) = outcome else { continue }

            for member in members {
                var note = member.note
                note.updated = Timestamp.utcNow()
                // Flagged: a decision nobody asked for is one the user should
                // see, even when it is right.
                _ = try? vault.save(note, topic: folder, vector: member.vector, needsReview: true)
            }
            existing.insert(folder)
            created.append(folder)
            Log.vault.notice("bootstrapped \(folder, privacy: .public) from \(members.count, privacy: .public) notes")
        }
        return created
    }

    // MARK: - Tidying up

    struct Proposal: Sendable {
        var id: String
        /// "merge" or "dissolve" — the two the app can actually carry out.
        var kind: String
        var summary: String
        var detail: String
        var score: Double
        var from: String
        var into: String?
    }

    /// Suggestions for an existing taxonomy that has drifted.
    ///
    /// Only merge and dissolve, because those are the two this app can
    /// perform. Offering a split or a reparent it cannot apply would be a
    /// button that does nothing.
    func proposals() -> [Proposal] {
        var out: [Proposal] = []
        let collections = vault.gateCandidates().filter { !$0.centroid.isEmpty }

        // Two collections that have become the same thing.
        for i in 0..<collections.count {
            for j in (i + 1)..<collections.count {
                let a = collections[i]
                let b = collections[j]
                let score = Vectors.cosine(a.centroid, b.centroid)
                guard score >= Thresholds.appleGuess(embedderID: "x").dedupeCentroid else { continue }

                // The smaller one folds into the larger: fewer notes move,
                // and the name that survives is the one with more behind it.
                let (from, into) = a.noteCount <= b.noteCount ? (a, b) : (b, a)
                out.append(Proposal(
                    id: "merge:\(from.path)->\(into.path)",
                    kind: "merge",
                    summary: "Fold \(from.path) into \(into.path)?",
                    detail: String(
                        format: "They hold much the same things (%.2f). %d notes would move.",
                        score, from.noteCount
                    ),
                    score: min(1, score),
                    from: from.path,
                    into: into.path
                ))
            }
        }

        // A collection that never grew. Provisional ones are supposed to earn
        // their folder; one that has not is clutter.
        for collection in collections where collection.noteCount == 1 {
            out.append(Proposal(
                id: "dissolve:\(collection.path)",
                kind: "dissolve",
                summary: "Put \(collection.path) back in Inbox?",
                detail: "It only ever held one note.",
                score: 0.5,
                from: collection.path,
                into: nil
            ))
        }

        return out.sorted { $0.score > $1.score }
    }

    /// Carry one out. Every note moves through the vault's normal save, so
    /// the whole thing lands in the undo journal and one Ctrl+Z puts it back.
    func apply(_ proposal: Proposal) async -> Bool {
        let members = vault.notes(topic: proposal.from)
        guard !members.isEmpty else { return false }

        for member in members {
            var note = member.note
            note.updated = Timestamp.utcNow()
            _ = try? vault.save(
                note, topic: proposal.into, vector: member.vector,
                needsReview: member.needsReview, recordUndo: true
            )
        }
        if proposal.kind == "merge", let into = proposal.into {
            // Remember the fold, so the dead name resolves straight to the
            // survivor next time rather than being proposed again.
            vault.aliases[NormKey.key(proposal.from)] = into
        }
        Log.vault.notice("applied \(proposal.id, privacy: .public)")
        return true
    }
}
