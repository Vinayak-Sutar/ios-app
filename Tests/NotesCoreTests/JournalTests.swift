import XCTest
@testable import NotesCore

final class JournalTests: XCTestCase {

    func testEmptyJournalOffersNoUndo() {
        var journal = Journal()
        XCTAssertFalse(journal.canUndo)
        XCTAssertNil(journal.pop())
        XCTAssertNil(journal.top)
    }

    func testUndoIsMostRecentFirst() {
        var journal = Journal()
        journal.record(.created(id: "a"), at: "t1")
        journal.record(.created(id: "b"), at: "t2")
        journal.record(.created(id: "c"), at: "t3")

        XCTAssertEqual(journal.pop(), .created(id: "c"))
        XCTAssertEqual(journal.pop(), .created(id: "b"))
        XCTAssertEqual(journal.pop(), .created(id: "a"))
        XCTAssertFalse(journal.canUndo)
    }

    func testHistoryIsBounded() {
        var journal = Journal()
        for index in 0..<(Journal.limit + 25) {
            journal.record(.created(id: "n\(index)"), at: "t")
        }
        XCTAssertEqual(journal.count, Journal.limit)
        // The oldest were dropped, not the newest.
        XCTAssertEqual(journal.top, .created(id: "n\(Journal.limit + 24)"))
    }

    /// Undoing an edit to a note that no longer exists would recreate it as a
    /// fragment, which is worse than not offering the undo at all.
    func testForgettingANoteRemovesAllItsEntries() {
        var journal = Journal()
        journal.record(.created(id: "a"), at: "t")
        journal.record(.edited(id: "a", title: "old", body: "text"), at: "t")
        journal.record(.created(id: "b"), at: "t")
        journal.record(.moved(id: "a", from: "Work", to: "Ideas"), at: "t")

        journal.forget(noteID: "a")

        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.pop(), .created(id: "b"))
    }

    func testDeletionCarriesTheWholeNote() {
        // Not a reference: by the time you want it back the file is gone, so a
        // reference would be a promise the journal cannot keep.
        let markdown = "---\nid: x\n---\n\nthe body\n"
        var journal = Journal()
        journal.record(.deleted(id: "x", markdown: markdown, path: "Work/x.md"), at: "t")

        guard case let .deleted(_, stored, path) = journal.pop() else {
            return XCTFail("wrong operation")
        }
        XCTAssertEqual(stored, markdown)
        XCTAssertEqual(path, "Work/x.md")
    }

    func testEveryOperationReportsItsNote() {
        let operations: [Journal.Operation] = [
            .created(id: "n"),
            .moved(id: "n", from: "A", to: "B"),
            .edited(id: "n", title: "t", body: "b"),
            .deleted(id: "n", markdown: "m", path: "p"),
            .ticked(id: "n", body: "b")
        ]
        for operation in operations {
            XCTAssertEqual(operation.noteID, "n", "\(operation)")
        }
    }

    /// The user reads these, so they stay in the app's plain register.
    func testDescriptionsAreInPlainWords() {
        XCTAssertEqual(Journal.Operation.created(id: "n").describe, "Removed the note")
        XCTAssertEqual(
            Journal.Operation.moved(id: "n", from: "Movies", to: "Ideas").describe,
            "Moved it back to Movies"
        )
        XCTAssertEqual(
            Journal.Operation.moved(id: "n", from: nil, to: "Ideas").describe,
            "Put it back in Inbox"
        )
        for operation in [
            Journal.Operation.created(id: "n"),
            .moved(id: "n", from: "A", to: "B"),
            .edited(id: "n", title: "t", body: "b"),
            .deleted(id: "n", markdown: "m", path: "p"),
            .ticked(id: "n", body: "b")
        ] {
            let words = operation.describe
            XCTAssertFalse(words.isEmpty)
            for jargon in ["entity", "mutation", "vector", "embedding", "topic"] {
                XCTAssertFalse(words.lowercased().contains(jargon), "jargon in: \(words)")
            }
        }
    }

    func testClearEmptiesEverything() {
        var journal = Journal()
        journal.record(.created(id: "a"), at: "t")
        journal.clear()
        XCTAssertFalse(journal.canUndo)
        XCTAssertEqual(journal.count, 0)
    }
}
