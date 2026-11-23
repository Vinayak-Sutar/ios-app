import XCTest
@testable import NotesCore

final class PaceTests: XCTestCase {

    private func day(_ text: String) -> PlainDate {
        guard let date = PlainDate.parse(text) else {
            XCTFail("bad fixture date \(text)")
            return PlainDate(year: 2026, month: 1, day: 1)
        }
        return date
    }

    func testAFinishedListIsDone() {
        let report = Pace.of(
            done: 5, total: 5,
            start: day("2026-11-01"), due: day("2026-11-30"), today: day("2026-11-10")
        )
        XCTAssertEqual(report?.state, "done")
        XCTAssertEqual(report?.left, 0)
    }

    func testAnEmptyListHasNothingToSay() {
        XCTAssertNil(Pace.of(done: 0, total: 0, start: nil, due: nil, today: day("2026-11-10")))
    }

    func testALeisurelyListIsOnTrack() {
        // Ten items over thirty days, three done after three: bang on.
        let report = Pace.of(
            done: 3, total: 10,
            start: day("2026-11-01"), due: day("2026-12-01"), today: day("2026-11-10")
        )
        XCTAssertEqual(report?.state, "on_track")
        XCTAssertEqual(report?.left, 7)
    }

    func testFallingBehindIsSaidPlainly() {
        // Nothing done, and three weeks of the month gone.
        let report = Pace.of(
            done: 0, total: 10,
            start: day("2026-11-01"), due: day("2026-12-01"), today: day("2026-11-25")
        )
        XCTAssertEqual(report?.state, "behind")
    }

    /// Rounded up, because a third of an item a day is one item a day.
    func testThePerDayRateRoundsUp() {
        let report = Pace.of(
            done: 0, total: 4,
            start: day("2026-11-01"), due: day("2026-11-13"), today: day("2026-11-10")
        )
        XCTAssertEqual(report?.daysLeft, 3)
        XCTAssertEqual(report?.perDay, 2)
    }

    func testPastTheDeadlineEverythingLeftIsLate() {
        let report = Pace.of(
            done: 1, total: 4,
            start: day("2026-11-01"), due: day("2026-11-05"), today: day("2026-11-10")
        )
        XCTAssertEqual(report?.state, "behind")
        XCTAssertEqual(report?.daysLeft, -5)
        XCTAssertEqual(report?.perDay, 3)
    }

    /// A list with a check-in but no deadline: something is left, and no rate
    /// it has to be done at.
    func testNoDeadlineMeansNoRush() {
        let report = Pace.of(done: 1, total: 4, start: day("2026-11-01"), due: nil, today: day("2026-11-10"))
        XCTAssertEqual(report?.state, "no_rush")
        XCTAssertEqual(report?.left, 3)
        XCTAssertEqual(report?.perDay, 0)
    }

    /// The reason this compares rate with rate: items added halfway through
    /// should change what is needed from here, not retroactively make you
    /// late. Counting against a straight line from the start would.
    func testItemsAddedLaterDoNotMakeYouLate() {
        // A week in, the list doubled; there is still a fortnight to go.
        let report = Pace.of(
            done: 5, total: 20,
            start: day("2026-11-01"), due: day("2026-12-01"), today: day("2026-11-08")
        )
        XCTAssertEqual(report?.state, "on_track")
    }

    func testWithNoStartDateTheDeadlineDecides() {
        XCTAssertEqual(
            Pace.of(done: 0, total: 5, start: nil, due: day("2026-11-11"), today: day("2026-11-10"))?.state,
            "behind"
        )
        XCTAssertEqual(
            Pace.of(done: 0, total: 5, start: nil, due: day("2026-11-30"), today: day("2026-11-10"))?.state,
            "on_track"
        )
    }

    /// One item left on the last day is not a crisis.
    func testOneItemOnTheLastDayIsNotBehind() {
        XCTAssertEqual(
            Pace.of(done: 4, total: 5, start: nil, due: day("2026-11-10"), today: day("2026-11-10"))?.state,
            "on_track"
        )
    }

    func testADeadlineBeforeTheStartIsIgnoredRatherThanDividedBy() {
        let report = Pace.of(
            done: 0, total: 3,
            start: day("2026-11-20"), due: day("2026-11-10"), today: day("2026-11-05")
        )
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.daysLeft, 5)
    }
}
