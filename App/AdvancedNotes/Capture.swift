import Foundation
import NotesCore

/// Saving something: the one path that matters.
///
/// The order is the design, and it is inherited from the Python engine rather
/// than invented: **the Markdown file is written before the model is ever
/// consulted.** Apple's model can refuse ordinary content with a guardrail
/// violation, the embedder's assets may still be downloading, and a decode can
/// fail — so every one of those costs a filing decision and nothing more. A
/// note that reached the box always reaches the disk.
@MainActor
final class Capture {

    private let vault: Vault
    private let intelligence: Intelligence
    private let embedding: EmbedderBox
    var thresholds: Thresholds

    /// Notes to accumulate before the vault is allowed to grow collections.
    ///
    /// An empty vault has no centroids to compare against, so the first notes
    /// would each invent a collection from their own incidental wording. The
    /// Python app clusters at 20; here they simply queue in Inbox until there
    /// is something to compare against.
    static let defaultColdStartNotes = 20

    /// Overridable from `_dev/overrides.json`, so filing can be reached in one
    /// sitting without typing twenty notes.
    var coldStartNotes = Capture.defaultColdStartNotes

    /// File on similarity alone, never asking the model. Separates two
    /// questions that otherwise arrive together: whether the embeddings
    /// cluster, and whether the model picks well from them.
    var retrievalOnly = false

    init(vault: Vault, intelligence: Intelligence, embedding: EmbedderBox, thresholds: Thresholds) {
        self.vault = vault
        self.intelligence = intelligence
        self.embedding = embedding
        self.thresholds = thresholds
    }

    struct Outcome {
        var note: Note
        var path: String
        var decision: Decision
        var relatedCount: Int
    }

    func capture(text raw: String) async -> Outcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. On disk first, in Inbox, with a provisional title. Nothing below
        //    this line is allowed to lose it.
        var note = Note(
            title: Self.provisionalTitle(from: text),
            body: text,
            kind: Self.guessKind(from: text)
        )
        var path = (try? vault.save(note, topic: nil, vector: [], needsReview: false)) ?? ""

        // 2. Embed. Without a vector there is nothing to compare, so the note
        //    stays in Inbox — which is the honest answer, not a failure.
        let vector = await embedding.embed(note.embeddingText)
        if vector.isEmpty {
            Log.model.notice("no vector; leaving in Inbox")
            let decision = Decision.inbox(reason: "the embedder is not ready yet", usedModel: false)
            return Outcome(note: note, path: path, decision: decision, relatedCount: 0)
        }

        // 3. Retrieve. Rank by similarity to each collection's centroid.
        let candidates = vault.candidates(for: vector, limit: thresholds.topicCandidates)
        let coldStart = max(0, coldStartNotes - vault.entries.count)

        var decision: Decision
        if coldStart > 0 {
            decision = Decision.inbox(
                reason: "still learning your collections (\(coldStart) more notes)",
                usedModel: false
            )
        } else if retrievalOnly {
            decision = Router.decideFromRetrieval(candidates, thresholds)
        } else if Router.retrievalIsConfident(candidates, thresholds) {
            // Retrieval alone measured 40/40 against a 4B model's 34/40, and
            // every deviation from its rank-1 was a mistake. So when it is
            // sure, the model is not asked at all - saving a slow call and the
            // risk of being overruled wrongly.
            decision = Router.decideFromRetrieval(candidates, thresholds)
        } else {
            decision = await decideWithModel(text: text, candidates: candidates)
        }

        // 4. Apply.
        note.topics = decision.topicPath.map { [$0] } ?? []
        note.updated = Timestamp.utcNow()
        if let better = pendingTitle { note.title = better; pendingTitle = nil }
        if let kind = pendingKind { note.kind = kind; pendingKind = nil }
        if let due = pendingDue { note.due = due; note.remind = due; pendingDue = nil }

        path = (try? vault.save(
            note,
            topic: decision.topicPath,
            vector: vector,
            needsReview: decision.outcome == .review
        )) ?? path

        Log.routes.notice(
            "captured \(note.id, privacy: .public) -> \(decision.outcome.rawValue, privacy: .public): \(decision.reason, privacy: .public)"
        )

        let related = vault.candidates(for: vector, limit: 6).filter { $0.similarity > 0.5 }.count
        return Outcome(note: note, path: path, decision: decision, relatedCount: related)
    }

    // The model's extra findings, applied after the routing decision so a
    // refusal cannot cost the title as well as the filing.
    private var pendingTitle: String?
    private var pendingKind: String?
    private var pendingDue: String?

    private func decideWithModel(text: String, candidates: [Candidate]) async -> Decision {
        guard Intelligence.availability.isAvailable else {
            return Router.decideFromRetrieval(candidates, thresholds)
                .withReason("the on-device model is unavailable; used retrieval")
        }

        do {
            let reading = try await intelligence.read(text: text, candidates: candidates)
            pendingTitle = Self.cleanTitle(reading.title)
            pendingKind = reading.kind.rawName
            pendingDue = Self.parseDue(reading.due)

            let choice: ModelChoice
            if let slot = reading.collection.slot {
                choice = .slot(slot)
            } else if case .newCollection = reading.collection {
                choice = .newCollection(reading.newCollectionName)
            } else {
                choice = .noneFit
            }

            return Router.apply(
                choice: choice,
                candidates: candidates,
                thresholds: thresholds,
                existingCollections: vault.collectionPaths,
                collectionCount: vault.collectionPaths.count
            )
        } catch {
            // Guardrail refusals land here, and so does everything else. The
            // note is already saved; only the filing degrades.
            Log.model.error("capture reading failed: \(error.localizedDescription, privacy: .public)")
            return Router.decideFromRetrieval(candidates, thresholds)
                .withReason("the model declined; used retrieval instead")
        }
    }

    // MARK: - Fallbacks that need no model

    /// A title good enough to show immediately, replaced by the model's if one
    /// arrives. First line, trimmed of Markdown, capped.
    static func provisionalTitle(from text: String) -> String {
        let first = text
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var line = first.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") || line.hasPrefix("-") || line.hasPrefix("*") {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        if line.count > 60 { line = String(line.prefix(60)) + "..." }
        return line.isEmpty ? "Untitled" : line
    }

    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Small models like to wrap a title in quotes and end it with a stop.
        if title.hasPrefix("\"") && title.hasSuffix("\"") && title.count > 1 {
            title = String(title.dropFirst().dropLast())
        }
        while title.hasSuffix(".") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.uppercased() != "NONE", title.count <= 120 else { return nil }
        return title
    }

    static func guessKind(from text: String) -> String {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return "link" }
        return "note"
    }

    /// `yyyy-MM-dd HH:mm` from the model into the vault's local wall-clock
    /// form. Anything else is ignored rather than guessed at — a reminder that
    /// fires at the wrong hour is worse than none.
    static func parseDue(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.uppercased() != "NONE" else { return nil }

        let parts = text.replacingOccurrences(of: "T", with: " ").components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let date = parts[0]
        let time = parts[1].components(separatedBy: ":").prefix(2).joined(separator: ":")

        let dateParts = date.components(separatedBy: "-")
        guard dateParts.count == 3,
              dateParts[0].count == 4,
              Int(dateParts[0]) != nil, Int(dateParts[1]) != nil, Int(dateParts[2]) != nil,
              time.components(separatedBy: ":").count == 2,
              let hour = Int(time.components(separatedBy: ":")[0]),
              let minute = Int(time.components(separatedBy: ":")[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return String(format: "%@-%@-%@T%02d:%02d:00", dateParts[0], dateParts[1], dateParts[2], hour, minute)
    }
}

/// Holds the embedder so callers do not each have to handle it being absent.
///
/// Stays on the main actor because that is where its callers are, but the
/// embedder itself is an actor — so `prepare` and `embed` hop off to a
/// background executor and the UI keeps running while a model loads.
///
/// `info` is cached at prepare time rather than read through on every access:
/// a property read that costs an actor hop is a property read that gets called
/// in a loop by accident.
@MainActor
final class EmbedderBox {
    private(set) var embedder: AppleEmbedder?
    private(set) var info: AppleEmbedder.Info?
    private(set) var failure: String?

    func prepare() async {
        guard embedder == nil else { return }
        do {
            let made = try AppleEmbedder()
            try await made.prepare()
            info = await made.info()
            embedder = made
            failure = nil
            Log.embed.notice("embedder ready: \(self.identifier, privacy: .public)")
        } catch {
            failure = "\(error)"
            Log.embed.error("embedder unavailable: \(self.failure ?? "", privacy: .public)")
        }
    }

    func embed(_ text: String) async -> [Float] {
        guard let embedder else { return [] }
        do {
            return try await embedder.embed(text)
        } catch {
            Log.embed.error("embed failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    var identifier: String { info?.embedderID ?? "unavailable" }
}

extension NoteKind {
    var rawName: String {
        switch self {
        case .note: return "note"
        case .task: return "task"
        case .link: return "link"
        case .idea: return "idea"
        case .reference: return "reference"
        }
    }
}
