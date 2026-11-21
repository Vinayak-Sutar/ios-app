import XCTest
@testable import NotesCore

final class PlainDateTests: XCTestCase {

    func testParsesBothStoredForms() {
        XCTAssertEqual(PlainDate.parse("2026-11-15"), PlainDate(year: 2026, month: 11, day: 15))
        XCTAssertEqual(
            PlainDate.parse("2026-11-15T18:30:00"),
            PlainDate(year: 2026, month: 11, day: 15, hour: 18, minute: 30)
        )
        // The model writes a space instead of the T often enough to accept it.
        XCTAssertEqual(
            PlainDate.parse("2026-11-15 18:30"),
            PlainDate(year: 2026, month: 11, day: 15, hour: 18, minute: 30)
        )
    }

    func testRejectsImpossibleDates() {
        for text in [
            "", "not a date", "2026-13-01", "2026-00-10", "2026-02-30",
            "2026-11-15T25:00", "2026-11-15T10:61", "26-11-15", "2026/11/15"
        ] {
            XCTAssertNil(PlainDate.parse(text), "accepted \(text.debugDescription)")
        }
    }

    func testAcceptsLeapDayOnlyInLeapYears() {
        XCTAssertNotNil(PlainDate.parse("2028-02-29"))
        XCTAssertNil(PlainDate.parse("2026-02-29"))
        XCTAssertNil(PlainDate.parse("2100-02-29"), "2100 is not a leap year")
        XCTAssertNotNil(PlainDate.parse("2000-02-29"), "2000 is a leap year")
    }

    func testStampRoundTrips() {
        let date = PlainDate(year: 2026, month: 1, day: 5, hour: 9, minute: 7)
        XCTAssertEqual(date.stamp, "2026-01-05T09:07:00")
        XCTAssertEqual(PlainDate.parse(date.stamp), date)
        XCTAssertEqual(date.dayStamp, "2026-01-05")
    }

    // MARK: - Day numbers

    func testDayNumberMatchesKnownEpochs() {
        XCTAssertEqual(PlainDate(year: 1970, month: 1, day: 1).dayNumber, 0)
        XCTAssertEqual(PlainDate(year: 1970, month: 1, day: 2).dayNumber, 1)
        XCTAssertEqual(PlainDate(year: 1969, month: 12, day: 31).dayNumber, -1)
        XCTAssertEqual(PlainDate(year: 2000, month: 1, day: 1).dayNumber, 10957)
    }

    func testDayNumberRoundTripsOverManyYears() {
        var date = PlainDate(year: 2020, month: 1, day: 1)
        for _ in 0..<(366 * 12) {
            let restored = PlainDate.fromDayNumber(date.dayNumber)
            XCTAssertEqual(restored.year, date.year)
            XCTAssertEqual(restored.month, date.month)
            XCTAssertEqual(restored.day, date.day)
            date = date.addingDays(1)
        }
    }

    /// 1 = Monday. 1970-01-01 was a Thursday, which anchors the rest.
    func testWeekday() {
        XCTAssertEqual(PlainDate(year: 1970, month: 1, day: 1).weekday, 4)
        XCTAssertEqual(PlainDate(year: 2026, month: 11, day: 23).weekday, 1, "a Monday")
        XCTAssertEqual(PlainDate(year: 2026, month: 11, day: 29).weekday, 7, "a Sunday")
        XCTAssertTrue(PlainDate(year: 2026, month: 11, day: 28).isWeekend)
        XCTAssertFalse(PlainDate(year: 2026, month: 11, day: 27).isWeekend)
    }

    // MARK: - Arithmetic

    func testAddingDaysCrossesMonthsAndYears() {
        XCTAssertEqual(
            PlainDate(year: 2026, month: 1, day: 31).addingDays(1).dayStamp, "2026-02-01"
        )
        XCTAssertEqual(
            PlainDate(year: 2026, month: 12, day: 31).addingDays(1).dayStamp, "2027-01-01"
        )
        XCTAssertEqual(
            PlainDate(year: 2028, month: 2, day: 28).addingDays(1).dayStamp, "2028-02-29"
        )
    }

    func testAddingDaysKeepsTheTime() {
        let date = PlainDate(year: 2026, month: 11, day: 15, hour: 18, minute: 30)
        XCTAssertEqual(date.addingDays(10).stamp, "2026-11-25T18:30:00")
    }

    /// A monthly reminder on the 31st should visit the 30th in April and the
    /// 28th in February — and come back to the 31st in May. Clamping on the
    /// way out rather than storing the clamped day is what makes that work.
    func testMonthlyClampsWithoutLosingTheDay() {
        let original = PlainDate(year: 2026, month: 1, day: 31)
        XCTAssertEqual(original.addingMonths(1).dayStamp, "2026-02-28")
        XCTAssertEqual(original.addingMonths(2).dayStamp, "2026-03-31")
        XCTAssertEqual(original.addingMonths(3).dayStamp, "2026-04-30")
        XCTAssertEqual(original.addingMonths(4).dayStamp, "2026-05-31")
    }

    func testAddingMonthsGoesBackwards() {
        XCTAssertEqual(PlainDate(year: 2026, month: 1, day: 15).addingMonths(-1).dayStamp, "2025-12-15")
        XCTAssertEqual(PlainDate(year: 2026, month: 1, day: 15).addingMonths(-13).dayStamp, "2024-12-15")
    }

    func testAddingYearsHandlesTheLeapDay() {
        XCTAssertEqual(PlainDate(year: 2028, month: 2, day: 29).addingYears(1).dayStamp, "2029-02-28")
        XCTAssertEqual(PlainDate(year: 2028, month: 2, day: 29).addingYears(4).dayStamp, "2032-02-29")
    }

    func testOrdering() {
        let morning = PlainDate(year: 2026, month: 11, day: 15, hour: 9)
        let evening = PlainDate(year: 2026, month: 11, day: 15, hour: 18)
        let tomorrow = PlainDate(year: 2026, month: 11, day: 16, hour: 1)
        XCTAssertLessThan(morning, evening)
        XCTAssertLessThan(evening, tomorrow)
        XCTAssertEqual(morning.days(until: tomorrow), 1)
        XCTAssertEqual(evening.days(until: morning), 0, "same day, regardless of time")
    }
}

final class RepeatsTests: XCTestCase {

    func testParsesShorthands() {
        XCTAssertEqual(Repeats.parse("daily"), .days(1))
        XCTAssertEqual(Repeats.parse("weekly"), .weeks(1))
        XCTAssertEqual(Repeats.parse("fortnightly"), .weeks(2))
        XCTAssertEqual(Repeats.parse("monthly"), .months(1))
        XCTAssertEqual(Repeats.parse("yearly"), .years(1))
        XCTAssertEqual(Repeats.parse("weekdays"), .weekdays)
    }

    func testParsesEveryPhrases() {
        XCTAssertEqual(Repeats.parse("every day"), .days(1))
        XCTAssertEqual(Repeats.parse("every 2 weeks"), .weeks(2))
        XCTAssertEqual(Repeats.parse("every three days"), .days(3))
        XCTAssertEqual(Repeats.parse("every other week"), .weeks(2))
        XCTAssertEqual(Repeats.parse("every month"), .months(1))
    }

    func testParsesWeekdays() {
        XCTAssertEqual(Repeats.parse("every monday"), .weekday(1))
        XCTAssertEqual(Repeats.parse("mondays"), nil, "plural weekday is not a rule we claim")
        XCTAssertEqual(Repeats.parse("every friday"), .weekday(5))
        XCTAssertEqual(Repeats.parse("every monday morning"), .weekday(1))
        XCTAssertEqual(Repeats.parse("sunday"), .weekday(7))
    }

    func testRejectsNonsense() {
        for text in ["", "sometimes", "every blue moon", "every 0 days", "whenever"] {
            XCTAssertNil(Repeats.parse(text), "accepted \(text.debugDescription)")
        }
    }

    // MARK: - Next occurrence

    func testDailyAdvancesPastNow() {
        let anchor = PlainDate(year: 2026, month: 11, day: 1, hour: 9)
        let now = PlainDate(year: 2026, month: 11, day: 5, hour: 12)
        XCTAssertEqual(Repeats.next(after: now, rule: .days(1), anchor: anchor).stamp, "2026-11-06T09:00:00")
    }

    func testEveryThreeDaysStaysOnTheAnchorsRhythm() {
        let anchor = PlainDate(year: 2026, month: 11, day: 1)
        let now = PlainDate(year: 2026, month: 11, day: 5)
        // 1, 4, 7 — not 8, which is what counting from "now" would give.
        XCTAssertEqual(Repeats.next(after: now, rule: .days(3), anchor: anchor).dayStamp, "2026-11-07")
    }

    /// The reason anchoring matters: counting from the anchor each time keeps
    /// a monthly reminder on the 31st instead of letting February drag it.
    func testMonthlyOnTheThirtyFirstKeepsComingBack() {
        let anchor = PlainDate(year: 2026, month: 1, day: 31)
        var now = PlainDate(year: 2026, month: 2, day: 1)
        let expected = ["2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31"]
        var seen: [String] = []
        for _ in expected {
            let next = Repeats.next(after: now, rule: .months(1), anchor: anchor)
            seen.append(next.dayStamp)
            now = next
        }
        XCTAssertEqual(seen, expected)
    }

    func testWeekdaysSkipsTheWeekend() {
        // 2026-11-27 is a Friday.
        let friday = PlainDate(year: 2026, month: 11, day: 27, hour: 9)
        let next = Repeats.next(after: friday, rule: .weekdays, anchor: friday)
        XCTAssertEqual(next.dayStamp, "2026-11-30", "should skip to Monday")
        XCTAssertEqual(next.hour, 9, "time of day is preserved")
    }

    func testWeekdayRuleLandsOnThatDay() {
        let now = PlainDate(year: 2026, month: 11, day: 23, hour: 9)   // a Monday
        let next = Repeats.next(after: now, rule: .weekday(1), anchor: now)
        XCTAssertEqual(next.dayStamp, "2026-11-30")
        XCTAssertEqual(next.weekday, 1)
    }

    func testNextIsAlwaysStrictlyLater() {
        let anchor = PlainDate(year: 2026, month: 11, day: 15, hour: 9)
        for rule in [Repeats.Rule.days(1), .weeks(1), .months(1), .years(1), .weekdays, .weekday(3)] {
            let next = Repeats.next(after: anchor, rule: rule, anchor: anchor)
            XCTAssertGreaterThan(next, anchor, "\(rule) did not advance")
        }
    }

    func testStampConvenience() {
        XCTAssertEqual(
            Repeats.nextStamp(after: "2026-11-05T12:00:00", rule: "daily", anchor: "2026-11-01T09:00:00"),
            "2026-11-06T09:00:00"
        )
        XCTAssertNil(Repeats.nextStamp(after: "nonsense", rule: "daily"))
        XCTAssertNil(Repeats.nextStamp(after: "2026-11-05T12:00:00", rule: "never"))
    }

    func testDescriptionsAreReadable() {
        XCTAssertEqual(Repeats.describe(.days(1)), "Every day")
        XCTAssertEqual(Repeats.describe(.weeks(2)), "Every 2 weeks")
        XCTAssertEqual(Repeats.describe(.weekdays), "Every weekday")
        XCTAssertEqual(Repeats.describe(.weekday(1)), "Every Monday")
    }
}
