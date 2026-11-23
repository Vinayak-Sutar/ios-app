import Foundation

/// How a to-do list with a deadline is going.
///
/// The Today screen shows one line per list — "a bit behind: about 3 a day
/// would catch up" — and that line is the only thing standing between a list
/// with a deadline and a list you remember about on the deadline. The bridge
/// sent no lists at all, so the screen simply had no such line.
///
/// Rate against rate, not count against count: the question is whether you now
/// have to go faster than you did when you started. That survives a list you
/// added items to halfway through, where "you should have done 6 by now" does
/// not.
public enum Pace {

    public struct Report: Sendable, Equatable, Codable {
        /// "done", "behind", "on_track" or "no_rush" — the words `app.html`
        /// branches on.
        public var state: String
        public var left: Int
        /// What finishing on time now costs per day, rounded up: a third of an
        /// item a day is one item a day.
        public var perDay: Int
        /// Negative when the deadline has passed.
        public var daysLeft: Int

        public init(state: String, left: Int, perDay: Int, daysLeft: Int) {
            self.state = state
            self.left = left
            self.perDay = perDay
            self.daysLeft = daysLeft
        }
    }

    /// Needing more than a fifth again the original rate counts as behind.
    /// Some slack on purpose: a list is not behind because one item slipped a
    /// day, and a screen that cries wolf gets ignored.
    public static let tolerance = 1.2

    public static func of(
        done: Int,
        total: Int,
        start: PlainDate?,
        due: PlainDate?,
        today: PlainDate
    ) -> Report? {
        guard total > 0 else { return nil }
        let left = Swift.max(0, total - done)

        if left == 0 {
            return Report(state: "done", left: 0, perDay: 0, daysLeft: due.map { today.days(until: $0) } ?? 0)
        }
        guard let due else {
            // A list with a check-in but no deadline: there is something left,
            // and no rate that it has to be done at.
            return Report(state: "no_rush", left: left, perDay: 0, daysLeft: 0)
        }

        let daysLeft = today.days(until: due)
        // Past the deadline there is no rate left to calculate: what remains
        // is what is late.
        guard daysLeft >= 0 else {
            return Report(state: "behind", left: left, perDay: left, daysLeft: daysLeft)
        }

        let perDay = Int(ceil(Double(left) / Double(Swift.max(1, daysLeft))))
        let now = Double(left) / Double(Swift.max(1, daysLeft))

        // The rate the whole list needed on the day it was given a deadline.
        // Without a start date there is nothing to compare against, so the
        // deadline itself decides.
        guard let start, start < due else {
            return Report(
                state: daysLeft <= 1 && left > 1 ? "behind" : "on_track",
                left: left, perDay: perDay, daysLeft: daysLeft
            )
        }

        let span = Swift.max(1, start.days(until: due))
        let original = Double(total) / Double(span)
        return Report(
            state: now > original * tolerance ? "behind" : "on_track",
            left: left,
            perDay: perDay,
            daysLeft: daysLeft
        )
    }
}
