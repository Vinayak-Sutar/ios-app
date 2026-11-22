import Foundation

/// Where a note sits in a hand-arranged list.
///
/// Dragging a note only works if three things agree: what the list is sorted
/// by, what a drop between two rows means, and what a note that has never been
/// dragged is worth. The first version of this stored a position nothing read,
/// so a reorder survived until the next refresh and then sprang back.
///
/// The rules:
///
/// 1. Lists are sorted **ascending** by position, and a note with no position
///    of its own gets one derived from its id — negated, so the newest note
///    still leads. An untouched list therefore reads exactly as it always
///    did, and dragging one note does not renumber the rest.
/// 2. A note dropped between two others takes the midpoint of their
///    positions. Fractions mean a drop never has to touch its neighbours.
public enum NoteOrder {

    /// The millisecond timestamp in a ULID's first ten characters.
    ///
    /// Decoded rather than parsed from `created`, because the id is the one
    /// field that is always there and never edited: a note hand-written in
    /// the Files app may have no `created` at all.
    public static func milliseconds(ofULID id: String) -> UInt64? {
        guard id.count == 26 else { return nil }
        var value: UInt64 = 0
        for character in id.prefix(10) {
            guard let digit = ULID.alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | UInt64(digit)
        }
        return value
    }

    /// A note's place in the list: its own position if it has been dragged,
    /// otherwise its age, negated so that newest comes first.
    public static func position(_ note: Note) -> Double {
        if let order = note.order { return order }
        guard let milliseconds = milliseconds(ofULID: note.id) else { return 0 }
        return -Double(milliseconds)
    }

    /// Sort two notes the way every list in the app shows them.
    ///
    /// The id breaks a tie, so two notes written in the same millisecond keep
    /// a stable order instead of swapping places between requests.
    public static func before(_ a: Note, _ b: Note) -> Bool {
        let first = position(a)
        let second = position(b)
        if first != second { return first < second }
        return a.id > b.id
    }

    /// A position between two neighbours, or just outside the end ones.
    ///
    /// `before` is the row above the drop and `after` the row below, which is
    /// how the page sends them. So a drop at the end of the list has to land
    /// *after* its only neighbour, and one at the top *before* it — which the
    /// first version had precisely the wrong way round.
    public static func between(before: Double?, after: Double?) -> Double {
        switch (before, after) {
        case let (.some(above), .some(below)): return (above + below) / 2
        case let (.some(above), .none): return above + 1
        case let (.none, .some(below)): return below - 1
        case (.none, .none): return 0
        }
    }
}
