import Foundation
import NotesCore

/// The notes on disk, plus the in-memory index over them.
///
/// Same contract as the Python app: **the Markdown files are the truth and the
/// index is a disposable cache.** Delete `index.json` and `reload()`
/// reconstructs everything from frontmatter alone. That is what makes the vault
/// safe to expose in the Files app — the user can edit or delete a file there
/// and the app recovers by rescanning, rather than holding a stale view of
/// something that no longer exists.
///
/// No SQLite for the prototype. At a few hundred notes a dictionary and a
/// brute-force cosine scan are microseconds, and FTS5 plus triggers plus
/// partial indexes is a lot of machinery to get right blind.
@MainActor
final class Vault {

    struct Entry {
        var note: Note
        /// Relative to the vault root, e.g. `gaming/malenia-timing.md`.
        var path: String
        var vector: [Float]
        var needsReview: Bool
    }

    let root: URL
    private let indexURL: URL

    private(set) var entries: [String: Entry] = [:]
    /// Every change that can be taken back. In memory only: undo is for the
    /// action you just regretted, not for history.
    var journal = Journal()
    /// Collection path -> running centroid and member count.
    private(set) var centroids: [String: (vector: [Float], count: Int)] = [:]

    static let inboxDirectory = "Inbox"

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = documents.appendingPathComponent("Vault", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.indexURL = support.appendingPathComponent("index.json")
    }

    // MARK: - Lifecycle

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Self.inboxDirectory), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Keep the cache out of iCloud backups: it is rebuildable, and a stale
        // one restored onto another device would be worse than none.
        var support = indexURL.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? support.setResourceValues(values)
    }

    /// Rescan the Markdown and rebuild the index, reusing any vector we already
    /// hold for an unchanged note so a reload does not re-embed the vault.
    func reload(using embedder: AppleEmbedder?) async {
        let cached = loadIndexFile()
        var next: [String: Entry] = [:]

        for url in markdownFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let note = FrontmatterCodec.load(text)
            let path = relativePath(of: url)

            var vector = cached[note.id]?.vector ?? []
            // Re-embed only when the note's meaning could have changed.
            if vector.isEmpty || cached[note.id]?.updated != note.updated {
                vector = (try? await embedder?.embed(note.embeddingText)) ?? []
            }
            next[note.id] = Entry(
                note: note,
                path: path,
                vector: vector,
                needsReview: cached[note.id]?.needsReview ?? false
            )
        }

        entries = next
        rebuildCentroids()
        saveIndexFile()
        Log.vault.notice("loaded \(self.entries.count, privacy: .public) notes, \(self.centroids.count, privacy: .public) collections")
    }

    private func rebuildCentroids() {
        var grouped: [String: [[Float]]] = [:]
        for entry in entries.values {
            guard let topic = entry.note.primaryTopic, !entry.vector.isEmpty else { continue }
            grouped[topic, default: []].append(entry.vector)
        }
        centroids = grouped.mapValues { (Vectors.mean($0), $0.count) }
    }

    // MARK: - Queries

    var collectionPaths: [String] {
        var seen = Set<String>()
        for entry in entries.values {
            if let topic = entry.note.primaryTopic { seen.insert(topic) }
        }
        return seen.sorted()
    }

    /// Newest first. ULIDs sort by creation time, so sorting by id is the same
    /// as sorting by date without parsing anything.
    func notes(topic: String? = nil, kind: String? = nil, status: String? = nil) -> [Entry] {
        entries.values
            .filter { entry in
                if let topic, entry.note.primaryTopic != topic { return false }
                if let kind, entry.note.kind != kind { return false }
                if let status, entry.note.status != status { return false }
                return true
            }
            .sorted { $0.note.id > $1.note.id }
    }

    func entry(_ id: String) -> Entry? { entries[id] }

    var inbox: [Entry] {
        notes().filter { $0.note.primaryTopic == nil }
    }

    var needingReview: [Entry] {
        notes().filter { $0.needsReview && $0.note.primaryTopic != nil }
    }

    /// Collection candidates for a note vector, best first.
    func candidates(for vector: [Float], limit: Int) -> [Candidate] {
        guard !vector.isEmpty else { return [] }
        return centroids
            .map { path, value in
                Candidate(
                    path: path,
                    similarity: Vectors.cosine(vector, value.vector),
                    noteCount: value.count
                )
            }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }

    /// Substring match fused with vector similarity.
    ///
    /// Not Reciprocal Rank Fusion yet: with no FTS5 there is no second ranked
    /// list to fuse, so a literal match simply outranks a semantic one.
    func search(_ query: String, vector: [Float], limit: Int = 40) -> [(entry: Entry, score: Double, via: String)] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var scored: [(Entry, Double, String)] = []
        for entry in entries.values {
            let haystack = (entry.note.title + " " + entry.note.body).lowercased()
            let literal = haystack.contains(needle)
            let similarity = vector.isEmpty ? 0 : Vectors.cosine(vector, entry.vector)

            if literal {
                scored.append((entry, 1.0 + similarity, similarity > 0 ? "both" : "fts"))
            } else if similarity > 0.2 {
                scored.append((entry, similarity, "vector"))
            }
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { (entry: $0.0, score: $0.1, via: $0.2) }
    }

    // MARK: - Writing

    /// Where a note's file belongs, given its collection.
    func url(for note: Note, topic: String?) -> (url: URL, relative: String) {
        var directory = root
        var components: [String] = []
        if let topic, !topic.isEmpty {
            components = Slug.dirComponents(forTopicPath: topic)
        } else {
            components = [Self.inboxDirectory]
        }
        for component in components {
            directory = directory.appendingPathComponent(component, isDirectory: true)
        }

        var stem = Slug.filenameStem(title: note.title, body: note.body)
        // A second note with the same title gets its id's tail appended, the
        // same way the Python vault disambiguates.
        let relativeDirectory = components.joined(separator: "/")
        let candidate = relativeDirectory + "/" + stem + ".md"
        if let owner = entries.values.first(where: { $0.path == candidate }), owner.note.id != note.id {
            stem += "-" + String(note.id.suffix(6)).lowercased()
        }

        return (
            directory.appendingPathComponent(stem + ".md"),
            relativeDirectory + "/" + stem + ".md"
        )
    }

    /// Write the file first, index second.
    ///
    /// Deliberate ordering, inherited from the Python engine: a note reaches
    /// disk before anything that can fail is allowed to run, so filing is the
    /// only thing a failure can cost.
    @discardableResult
    func save(
        _ note: Note,
        topic: String?,
        vector: [Float],
        needsReview: Bool,
        recordUndo: Bool = false
    ) throws -> String {
        let target = url(for: note, topic: topic)

        if recordUndo {
            if let existing = entries[note.id] {
                // Record what it was, before it stops being that.
                if existing.note.primaryTopic != topic {
                    journal.record(
                        .moved(id: note.id, from: existing.note.primaryTopic, to: topic),
                        at: Timestamp.utcNow()
                    )
                } else if existing.note.body != note.body || existing.note.title != note.title {
                    journal.record(
                        .edited(id: note.id, title: existing.note.title, body: existing.note.body),
                        at: Timestamp.utcNow()
                    )
                }
            } else {
                journal.record(.created(id: note.id), at: Timestamp.utcNow())
            }
        }

        // Moving collections leaves the old file behind otherwise.
        if let existing = entries[note.id], existing.path != target.relative {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(existing.path))
        }

        var stored = note
        stored.topics = topic.map { [$0] } ?? []
        try writeAtomically(FrontmatterCodec.render(stored), to: target.url)

        entries[note.id] = Entry(
            note: stored, path: target.relative, vector: vector, needsReview: needsReview
        )
        rebuildCentroids()
        saveIndexFile()
        return target.relative
    }

    func delete(_ id: String, recordUndo: Bool = true) throws {
        guard let entry = entries[id] else { return }
        if recordUndo {
            // Capture the file before removing it: afterwards there is nothing
            // left to reconstruct it from.
            let markdown = FrontmatterCodec.render(entry.note)
            journal.record(
                .deleted(id: id, markdown: markdown, path: entry.path),
                at: Timestamp.utcNow()
            )
        } else {
            journal.forget(noteID: id)
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.path))
        entries.removeValue(forKey: id)
        rebuildCentroids()
        saveIndexFile()
    }

    /// Remember a checklist body before it is ticked, so the tick can be
    /// taken back without re-embedding: ticking does not change what a note
    /// is about.
    func recordTick(id: String, previousBody: String) {
        journal.record(.ticked(id: id, body: previousBody), at: Timestamp.utcNow())
    }

    func setReviewed(_ id: String) {
        entries[id]?.needsReview = false
        saveIndexFile()
    }

    /// Write to a staging file and replace, so a note is never half-written.
    /// Staging lives in Caches: same volume, so the replace is a rename, and
    /// no stray `.tmp` files appear in the user's Files view.
    private func writeAtomically(_ text: String, to url: URL) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let staging = caches.appendingPathComponent("write-\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
    }

    // MARK: - Files

    func markdownFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }

    private func relativePath(of url: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            .replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - The index cache

    private struct Cached: Codable {
        var updated: String
        var needsReview: Bool
        /// base64 little-endian float32.
        var vector: String
    }

    private func loadIndexFile() -> [String: (updated: String, needsReview: Bool, vector: [Float])] {
        guard let data = try? Data(contentsOf: indexURL),
              let raw = try? JSONDecoder().decode([String: Cached].self, from: data) else {
            return [:]
        }
        return raw.mapValues {
            (updated: $0.updated, needsReview: $0.needsReview, vector: Vectors.decodeBase64($0.vector))
        }
    }

    private func saveIndexFile() {
        let payload = entries.mapValues {
            Cached(
                updated: $0.note.updated,
                needsReview: $0.needsReview,
                vector: Vectors.encodeBase64($0.vector)
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
