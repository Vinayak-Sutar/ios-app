import Foundation
import NotesCore

/// Carrying out the inverse of whatever happened last.
///
/// Separate from `Journal`, which is the pure record of what to reverse. This
/// is the part that touches the disk, and keeping the two apart is what lets
/// the model be tested on Windows while only the file handling is written
/// blind.
@MainActor
enum Undo {

    struct Result: Encodable {
        /// What the page shows in its toast; nil when there was nothing to do.
        var undone: String?
    }

    static func perform(vault: Vault, embedding: EmbedderBox, reminders: Reminders) async -> Result {
        guard let operation = vault.journal.pop() else {
            return Result(undone: nil)
        }

        switch operation {
        case let .created(id):
            // Undoing a creation removes the note, and must not itself be
            // undoable — otherwise Ctrl+Z twice resurrects it.
            try? vault.delete(id, recordUndo: false)
            await reminders.cancel(noteID: id)

        case let .moved(id, from, _):
            guard var entry = vault.entry(id) else { break }
            entry.note.updated = Timestamp.utcNow()
            _ = try? vault.save(
                entry.note, topic: from, vector: entry.vector, needsReview: false, recordUndo: false
            )

        case let .edited(id, title, body):
            guard var entry = vault.entry(id) else { break }
            entry.note.title = title
            entry.note.body = body
            entry.note.updated = Timestamp.utcNow()
            // The text is going back to what it was, so the vector has to as
            // well, or search would answer for a version that no longer exists.
            let vector = await embedding.embed(entry.note.embeddingText)
            _ = try? vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: vector, needsReview: entry.needsReview, recordUndo: false
            )

        case let .deleted(_, markdown, _):
            let note = FrontmatterCodec.load(markdown)
            let vector = await embedding.embed(note.embeddingText)
            _ = try? vault.save(
                note, topic: note.primaryTopic, vector: vector,
                needsReview: false, recordUndo: false
            )
            if note.remind != nil { await reminders.schedule(note) }

        case let .ticked(id, body):
            guard var entry = vault.entry(id) else { break }
            entry.note.body = body
            entry.note.updated = Timestamp.utcNow()
            // Ticking does not change what a note is about, so the old vector
            // still describes it and re-embedding would be wasted work.
            _ = try? vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview, recordUndo: false
            )
        }

        Log.vault.notice("undid: \(operation.describe, privacy: .public)")
        return Result(undone: operation.describe)
    }
}
