import Foundation

/// A date and time with no timezone, because that is what a reminder is.
///
/// `due` and `remind` are stored as local wall-clock — `"2026-11-15T18:00:00"`
/// — and that is deliberate: a reminder set for 6pm means 6pm wherever you
/// are, not 6pm in the zone you were in when you set it. Converting to an
/// absolute instant and back is how a reminder ends up firing at 3am after a
/// flight.
///
/// Arithmetic is done here rather than through `Calendar` for two reasons. It
/// makes every rule testable on Windows, where there is no timezone database
/// at all; and `Calendar` carries a locale, so the same code can produce a
/// different answer on two devices.
public struct PlainDate: Sendable, Equatable, Comparable, Hashable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    // MARK: - Text

    /// Accepts `yyyy-MM-dd` and `yyyy-MM-ddTHH:mm[:ss]`, with a space instead
    /// of the `T` as well — the model writes it both ways.
    public static func parse(_ text: String) -> PlainDate? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "T", with: " ")
        let parts = cleaned.components(separatedBy: " ").filter { !$0.isEmpty }
        guard let datePart = parts.first else { return nil }

        let date = datePart.components(separatedBy: "-")
        guard date.count == 3,
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              date[0].count == 4,
              (1...12).contains(month),
              (1...daysIn(month: month, year: year)).contains(day) else {
            return nil
        }

        var hour = 0
        var minute = 0
        if parts.count > 1 {
            let time = parts[1].components(separatedBy: ":")
            guard let h = Int(time[0]), time.count >= 2, let m = Int(time[1]),
                  (0...23).contains(h), (0...59).contains(m) else {
                return nil
            }
            hour = h
            minute = m
        }
        return PlainDate(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    /// The form the vault stores: `2026-11-15T18:00:00`.
    public var stamp: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:00", year, month, day, hour, minute)
    }

    /// Just the day: `2026-11-15`.
    public var dayStamp: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: - Calendar facts

    public static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 30
        }
    }

    /// Days since 1970-01-01, which is all the ordering and difference
    /// arithmetic needs.
    public var dayNumber: Int {
        // Howard Hinnant's days-from-civil algorithm: exact, branch-free and
        // valid for any proleptic Gregorian date, which matters because a
        // yearly repeat can run past any range a lookup table would cover.
        var y = year
        let m = month
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public static func fromDayNumber(_ number: Int, hour: Int = 0, minute: Int = 0) -> PlainDate {
        var z = number + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        y += m <= 2 ? 1 : 0
        z = 0
        return PlainDate(year: y, month: m, day: d, hour: hour, minute: minute)
    }

    /// 1 = Monday through 7 = Sunday, following ISO rather than the
    /// Sunday-first convention, because the repeat rules talk about weekdays.
    public var weekday: Int {
        let shifted = (dayNumber + 3) % 7      // 1970-01-01 was a Thursday
        return shifted >= 0 ? shifted + 1 : shifted + 8
    }

    public var isWeekend: Bool { weekday >= 6 }

    // MARK: - Arithmetic

    public func addingDays(_ count: Int) -> PlainDate {
        PlainDate.fromDayNumber(dayNumber + count, hour: hour, minute: minute)
    }

    /// Months, clamped to the end of the target month.
    ///
    /// A monthly reminder set on the 31st lands on the 30th in April and the
    /// 28th in February — and, crucially, goes back to the 31st in May,
    /// because the clamp is applied on the way out rather than stored.
    public func addingMonths(_ count: Int) -> PlainDate {
        let total = (year * 12 + (month - 1)) + count
        let newYear = total >= 0 ? total / 12 : (total - 11) / 12
        let newMonth = total - newYear * 12 + 1
        let limit = PlainDate.daysIn(month: newMonth, year: newYear)
        return PlainDate(
            year: newYear, month: newMonth, day: min(day, limit),
            hour: hour, minute: minute
        )
    }

    public func addingYears(_ count: Int) -> PlainDate {
        let target = year + count
        let limit = PlainDate.daysIn(month: month, year: target)
        return PlainDate(
            year: target, month: month, day: min(day, limit),
            hour: hour, minute: minute
        )
    }

    public var startOfDay: PlainDate {
        PlainDate(year: year, month: month, day: day, hour: 0, minute: 0)
    }

    /// Whole days from this date to another, ignoring the time.
    public func days(until other: PlainDate) -> Int {
        other.dayNumber - dayNumber
    }

    public static func < (lhs: PlainDate, rhs: PlainDate) -> Bool {
        if lhs.dayNumber != rhs.dayNumber { return lhs.dayNumber < rhs.dayNumber }
        if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
        return lhs.minute < rhs.minute
    }
}
