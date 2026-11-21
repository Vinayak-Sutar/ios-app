import Foundation

/// Repeating reminders, in the words people actually write.
///
/// Rules are stored as the user's own phrase — `"every monday"`, `"weekdays"`,
/// `"every 2 weeks"` — rather than as a structure. That keeps the Markdown
/// readable in any editor, which is the point of the vault, and it means a
/// rule nobody has taught the parser yet still survives a round trip instead
/// of being silently dropped.
public enum Repeats {

    public enum Rule: Sendable, Equatable {
        case days(Int)
        case weeks(Int)
        case months(Int)
        case years(Int)
        /// Monday to Friday, skipping the weekend.
        case weekdays
        /// A particular day of the week; 1 = Monday.
        case weekday(Int)
    }

    static let weekdayNames: [String: Int] = [
        "monday": 1, "mon": 1, "tuesday": 2, "tue": 2, "tues": 2,
        "wednesday": 3, "wed": 3, "thursday": 4, "thu": 4, "thurs": 4,
        "friday": 5, "fri": 5, "saturday": 6, "sat": 6, "sunday": 7, "sun": 7
    ]

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "other": 2, "two": 2, "three": 3,
        "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "twelve": 12
    ]

    public static func parse(_ text: String) -> Rule? {
        var words = text.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        // Single-word shorthands.
        if words.count == 1 {
            switch words[0] {
            case "daily", "day": return .days(1)
            case "weekly", "week": return .weeks(1)
            case "fortnightly", "biweekly": return .weeks(2)
            case "monthly", "month": return .months(1)
            case "yearly", "annually", "year": return .years(1)
            case "weekdays", "weekday": return .weekdays
            default:
                if let day = weekdayNames[words[0]] { return .weekday(day) }
                return nil
            }
        }

        if words[0] == "every" { words.removeFirst() }
        guard !words.isEmpty else { return nil }

        // "every weekday", "every monday"
        if words.count == 1 { return parse(words[0]) }

        // "every other week", "every 2 weeks", "every three days"
        let countWord = words[0]
        let count = Int(countWord) ?? numberWords[countWord]
        guard let count, count > 0, words.count >= 2 else {
            // "every monday morning" and the like: find a weekday anywhere.
            for word in words {
                if let day = weekdayNames[word] { return .weekday(day) }
            }
            return nil
        }

        let unit = words[1].hasSuffix("s") ? String(words[1].dropLast()) : words[1]
        switch unit {
        case "day": return .days(count)
        case "week": return .weeks(count)
        case "month": return .months(count)
        case "year": return .years(count)
        case "weekday": return .weekdays
        default:
            if let day = weekdayNames[words[1]] { return .weekday(day) }
            return nil
        }
    }

    /// The next occurrence strictly after `after`, counted from `anchor`.
    ///
    /// Counting from the anchor rather than from "now" is what keeps a monthly
    /// reminder on the 31st: each step is computed from the original date, so
    /// February's clamp to the 28th does not then drag March to the 28th too.
    public static func next(after: PlainDate, rule: Rule, anchor: PlainDate) -> PlainDate {
        switch rule {
        case let .days(count):
            var date = anchor
            // Step rather than divide: it is at most a few dozen iterations
            // for any realistic gap, and it keeps every unit on one code path.
            while date <= after { date = date.addingDays(count) }
            return date

        case let .weeks(count):
            var date = anchor
            while date <= after { date = date.addingDays(7 * count) }
            return date

        case let .months(count):
            var date = anchor
            var steps = 1
            while date <= after {
                date = anchor.addingMonths(count * steps)
                steps += 1
            }
            return date

        case let .years(count):
            var date = anchor
            var steps = 1
            while date <= after {
                date = anchor.addingYears(count * steps)
                steps += 1
            }
            return date

        case .weekdays:
            var date = after.addingDays(1)
            // Preserve the time of day from the anchor, since only the day
            // moves.
            date = PlainDate(
                year: date.year, month: date.month, day: date.day,
                hour: anchor.hour, minute: anchor.minute
            )
            while date.isWeekend { date = date.addingDays(1) }
            return date

        case let .weekday(target):
            var date = after.addingDays(1)
            date = PlainDate(
                year: date.year, month: date.month, day: date.day,
                hour: anchor.hour, minute: anchor.minute
            )
            while date.weekday != target { date = date.addingDays(1) }
            return date
        }
    }

    /// Convenience over the stored strings the vault holds.
    public static func nextStamp(after: String, rule: String, anchor: String? = nil) -> String? {
        guard let parsed = parse(rule),
              let afterDate = PlainDate.parse(after) else { return nil }
        let anchorDate = anchor.flatMap { PlainDate.parse($0) } ?? afterDate
        return next(after: afterDate, rule: parsed, anchor: anchorDate).stamp
    }

    /// Plain words for a rule, for a chip in the interface.
    public static func describe(_ rule: Rule) -> String {
        switch rule {
        case let .days(1): return "Every day"
        case let .days(n): return "Every \(n) days"
        case let .weeks(1): return "Every week"
        case let .weeks(2): return "Every 2 weeks"
        case let .weeks(n): return "Every \(n) weeks"
        case let .months(1): return "Every month"
        case let .months(n): return "Every \(n) months"
        case let .years(1): return "Every year"
        case let .years(n): return "Every \(n) years"
        case .weekdays: return "Every weekday"
        case let .weekday(day):
            let names = ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            return "Every \(names[min(max(day, 1), 7)])"
        }
    }
}
