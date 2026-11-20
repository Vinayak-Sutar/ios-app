import Foundation

/// Undo, as a stack of operations that each carry their own inverse.
///
/// The Python app's rule is that **nothing is one-way**: every organisational
/// change writes a row that knows how to reverse itself. That is a stronger
/// design than snapshotting, because the inverse is computed when the change
/// is made — while the old value is still at hand — rather than reconstructed
/// afterwards from a diff.
///
/// A deletion carries the note's whole rendered Markdown, not a reference. By
/// the time you want it back the file is gone, so a reference would be a
/// promise the journal cannot keep.
public struct Journal: Sendable {

    public enum Operation: Sendable, Equatable {
        /// A note was created; undoing removes it.
        case created(id: String)
        /// A note moved collections; undoing puts it back.
        case moved(id: String, from: String?, to: String?)
        /// A note's text changed; undoing restores the old title and body.
        case edited(id: String, title: String, body: String)
        /// A note was deleted; undoing writes the whole file back.
        case deleted(id: String, markdown: String, path: String)
        /// A checklist item was ticked or unticked.
        case ticked(id: String, body: String)

        /// What to tell the user, in the app's own plain register — no
        /// "entity", no "mutation".
        public var describe: String {
            switch self {
            case .created: return "Removed the note"
            case let .moved(_, from, _):
                return from.map { "Moved it back to \($0)" } ?? "Put it back in Inbox"
            case .edited: return "Put the text back"
            case .deleted: return "Brought the note back"
            case .ticked: return "Unticked it"
            }
        }

        public var noteID: String {
            switch self {
            case let .created(id), let .moved(id, _, _), let .edited(id, _, _),
                 let .deleted(id, _, _), let .ticked(id, _):
                return id
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        public let operation: Operation
        public let at: String

        public init(operation: Operation, at: String) {
            self.operation = operation
            self.at = at
        }
    }

    /// How many steps back you can go.
    ///
    /// Bounded because this lives in memory and a deletion entry holds a whole
    /// note. Deep history is not what undo is for — the next action after a
    /// mistake is almost always undoing it.
    public static let limit = 50

    private var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }
    public var canUndo: Bool { !entries.isEmpty }
    public var top: Operation? { entries.last?.operation }

    public mutating func record(_ operation: Operation, at: String) {
        entries.append(Entry(operation: operation, at: at))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    /// Take the most recent operation off the stack.
    public mutating func pop() -> Operation? {
        entries.popLast()?.operation
    }

    /// Drop everything about one note.
    ///
    /// Used when a note is deleted for good: undoing an edit to a note that no
    /// longer exists would recreate it as a fragment, which is worse than not
    /// offering the undo.
    public mutating func forget(noteID: String) {
        entries.removeAll { $0.operation.noteID == noteID }
    }

    public mutating func clear() {
        entries.removeAll()
    }
}
