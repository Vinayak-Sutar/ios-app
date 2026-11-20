import XCTest
@testable import NotesCore

final class ChecklistTests: XCTestCase {

    func testFindsCheckboxes() {
        let body = """
            Shopping
            - [ ] milk
            - [x] coffee
            not a task
            """
        let items = Checklist.items(in: body)
        XCTAssertEqual(items.map(\.text), ["milk", "coffee"])
        XCTAssertEqual(items.map(\.done), [false, true])
        XCTAssertEqual(items.map(\.line), [1, 2])
    }

    func testAcceptsEveryBulletStyleAndBothTickMarks() {
        let body = "- [ ] a\n* [x] b\n+ [X] c"
        let items = Checklist.items(in: body)
        XCTAssertEqual(items.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(items.map(\.done), [false, true, true])
    }

    func testIgnoresThingsThatAreNotTasks() {
        let body = """
            - a plain bullet
            [ ] no bullet
            - [y] not a tick
            -[ ] no space
            text
            """
        XCTAssertEqual(Checklist.items(in: body).count, 0)
    }

    /// A checkbox inside a code fence is an example, not a task.
    func testSkipsCodeFences() {
        let body = """
            - [ ] real
            ```
            - [ ] example in code
            ```
            - [x] also real
            """
        XCTAssertEqual(Checklist.items(in: body).map(\.text), ["real", "also real"])
    }

    // MARK: - Marks

    func testParsesEveryMark() {
        let body = "- [x] Optics 📅 2026-11-10 ⏰ 2026-11-05 18:00 🔁 every week ✅ 2026-10-27"
        let item = Checklist.items(in: body)[0]
        XCTAssertEqual(item.text, "Optics")
        XCTAssertEqual(item.due, "2026-11-10")
        XCTAssertEqual(item.remind, "2026-11-05 18:00")
        XCTAssertEqual(item.repeatRule, "every week")
        XCTAssertEqual(item.completed, "2026-10-27")
    }

    /// A phone keyboard emits these with a variation selector and a laptop
    /// often does not. Missing that means silently ignoring the user's marks.
    func testToleratesTheVariationSelector() {
        let plain = "- [ ] call mum ⏰ 2026-11-05 18:00"
        let withSelector = "- [ ] call mum \u{23F0}\u{FE0F} 2026-11-05 18:00"
        XCTAssertEqual(
            Checklist.items(in: plain)[0].remind,
            Checklist.items(in: withSelector)[0].remind
        )
    }

    func testTextKeepsItsOwnWords() {
        let item = Checklist.items(in: "- [ ] buy milk and bread 📅 2026-11-10")[0]
        XCTAssertEqual(item.text, "buy milk and bread")
    }

    func testRenderRoundTrips() {
        let source = "- [x] Optics 📅 2026-11-10 ⏰ 2026-11-05 18:00 🔁 every week ✅ 2026-10-27"
        let item = Checklist.items(in: source)[0]
        XCTAssertEqual(Checklist.render(item), source)
    }

    // MARK: - Ticking

    func testTickingRecordsTheDayAndKeepsOtherMarks() {
        let body = "- [ ] Optics ⏰ 2026-11-05 18:00 🔁 every week"
        let updated = Checklist.setDone(body, line: 0, text: "Optics", done: true, today: "2026-11-21")
        XCTAssertEqual(updated, "- [x] Optics ⏰ 2026-11-05 18:00 🔁 every week ✅ 2026-11-21")
    }

    func testUntickingClearsTheCompletionDay() {
        let body = "- [x] Optics ✅ 2026-11-21"
        let updated = Checklist.setDone(body, line: 0, text: "Optics", done: false, today: "2026-11-22")
        XCTAssertEqual(updated, "- [ ] Optics")
    }

    /// The line number comes from a page that may be a moment out of date, so
    /// it is a hint. Ticking the wrong line silently is the failure to avoid.
    func testStaleLineNumberFindsTheItemByText() {
        let body = "- [ ] milk\n- [ ] coffee\n- [ ] bread"
        let updated = Checklist.setDone(body, line: 0, text: "bread", done: true, today: "2026-11-21")
        XCTAssertEqual(updated, "- [ ] milk\n- [ ] coffee\n- [x] bread ✅ 2026-11-21")
    }

    func testUnknownItemChangesNothing() {
        let body = "- [ ] milk"
        XCTAssertNil(Checklist.setDone(body, line: 0, text: "sardines", done: true, today: "2026-11-21"))
        XCTAssertNil(Checklist.setDone(body, line: 99, text: "sardines", done: true, today: "2026-11-21"))
    }

    func testIndentationIsPreserved() {
        let body = "  - [ ] nested"
        let updated = Checklist.setDone(body, line: 0, text: "nested", done: true, today: "2026-11-21")
        XCTAssertEqual(updated, "  - [x] nested ✅ 2026-11-21")
    }

    func testSurroundingLinesAreUntouched() {
        let body = "# Heading\n\n- [ ] one\n- [ ] two\n\nfooter"
        let updated = Checklist.setDone(body, line: 2, text: "one", done: true, today: "2026-11-21")
        XCTAssertEqual(updated, "# Heading\n\n- [x] one ✅ 2026-11-21\n- [ ] two\n\nfooter")
    }

    // MARK: - Progress

    func testProgressCounts() {
        XCTAssertEqual(Checklist.progress(in: "- [ ] a\n- [x] b\n- [x] c"), [2, 3])
    }

    /// nil, not [0, 0] — that is how a plain note is told apart from an empty
    /// list, and the page renders them differently.
    func testPlainNoteHasNoProgress() {
        XCTAssertNil(Checklist.progress(in: "just some text"))
    }
}
