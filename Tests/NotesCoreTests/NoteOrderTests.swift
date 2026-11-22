import XCTest
@testable import NotesCore

final class NoteOrderTests: XCTestCase {

    private func note(id: String, order: Double? = nil) -> Note {
        var made = Note(title: "n", body: "b")
        made.id = id
        made.order = order
        return made
    }

    // MARK: - Reading the clock out of an id

    func testReadsTheTimestampFromAULID() {
        let id = ULID.generate(milliseconds: 1_700_000_000_000, randomHigh: 0, randomLow: 0)
        XCTAssertEqual(NoteOrder.milliseconds(ofULID: id), 1_700_000_000_000)
    }

    func testIgnoresAnythingThatIsNotAULID() {
        XCTAssertNil(NoteOrder.milliseconds(ofULID: "hand-written"))
        XCTAssertNil(NoteOrder.milliseconds(ofULID: ""))
        // Right length, wrong alphabet: U, I, L and O are not Crockford base32.
        XCTAssertNil(NoteOrder.milliseconds(ofULID: String(repeating: "U", count: 26)))
    }

    // MARK: - The default order

    /// The whole point of deriving a position from the id: a list nobody has
    /// dragged must read exactly as it did before positions existed.
    func testUndraggedNotesStayNewestFirst() {
        let older = note(id: ULID.generate(milliseconds: 1_000))
        let newer = note(id: ULID.generate(milliseconds: 2_000))
        XCTAssertTrue(NoteOrder.before(newer, older))
        XCTAssertFalse(NoteOrder.before(older, newer))
    }

    func testAnExplicitPositionWins() {
        let dragged = note(id: ULID.generate(milliseconds: 1_000), order: -9_999_999_999_999)
        let newer = note(id: ULID.generate(milliseconds: 2_000))
        XCTAssertTrue(NoteOrder.before(dragged, newer))
    }

    func testNotesFromTheSameMillisecondDoNotSwapPlaces() {
        let a = note(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let b = note(id: "01ARZ3NDEKTSV4RRFFQ69G5FAW")
        XCTAssertEqual(NoteOrder.before(a, b), !NoteOrder.before(b, a))
    }

    func testANoteWithNoUsableIdSortsSomewhereDefinite() {
        XCTAssertEqual(NoteOrder.position(note(id: "hand-written")), 0)
    }

    // MARK: - Dropping

    func testADropBetweenTwoRowsLandsBetweenThem() {
        let position = NoteOrder.between(before: 10, after: 20)
        XCTAssertGreaterThan(position, 10)
        XCTAssertLessThan(position, 20)
    }

    /// The case the first version had backwards: dropped at the end, a note
    /// must sort after the row above it, not before.
    func testADropAtTheEndLandsAfterTheLastRow() {
        XCTAssertGreaterThan(NoteOrder.between(before: 10, after: nil), 10)
    }

    func testADropAtTheTopLandsBeforeTheFirstRow() {
        XCTAssertLessThan(NoteOrder.between(before: nil, after: 10), 10)
    }

    func testTheOnlyNoteInAListNeedsNoPositionAtAll() {
        XCTAssertEqual(NoteOrder.between(before: nil, after: nil), 0)
    }

    /// Dragging the bottom note to the top, then sorting, must actually put it
    /// there — the end-to-end version of the two one-sided cases.
    func testADraggedNoteSortsWhereItWasDropped() {
        var first = note(id: ULID.generate(milliseconds: 3_000))
        let middle = note(id: ULID.generate(milliseconds: 2_000))
        var last = note(id: ULID.generate(milliseconds: 1_000))

        // The page sends the rows either side of the drop; at the top there
        // is nothing above.
        last.order = NoteOrder.between(before: nil, after: NoteOrder.position(first))
        var sorted = [first, middle, last].sorted(by: NoteOrder.before)
        XCTAssertEqual(sorted.map(\.id), [last.id, first.id, middle.id])

        // And back down to the end.
        first.order = NoteOrder.between(before: NoteOrder.position(middle), after: nil)
        sorted = [first, middle, last].sorted(by: NoteOrder.before)
        XCTAssertEqual(sorted.map(\.id), [last.id, middle.id, first.id])
    }

    /// Positions derived from a millisecond clock are around 1.7e12, so a
    /// midpoint must still land strictly between its neighbours rather than
    /// collapsing onto one of them.
    func testMidpointsSurviveTimestampSizedPositions() {
        let above = -1_700_000_000_000.0
        let below = -1_699_999_999_999.0
        let between = NoteOrder.between(before: above, after: below)
        XCTAssertGreaterThan(between, above)
        XCTAssertLessThan(between, below)
    }
}
