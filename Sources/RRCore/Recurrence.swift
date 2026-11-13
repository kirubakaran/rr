import Foundation

/// Days of the week, Monday first.
public enum Weekday: String, Codable, CaseIterable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    /// 0 for Monday ... 6 for Sunday.
    public var mondayIndex: Int { Weekday.allCases.firstIndex(of: self)! }
    /// Gregorian weekday number as EventKit and Foundation use it: 1 for Sunday ... 7 for Saturday.
    public var number: Int { (mondayIndex + 1) % 7 + 1 }
    public var name: String {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][mondayIndex]
    }
    public var short: String { String(name.prefix(3)) }
}

/// A calendar date with no time and no time zone.
public struct Day: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let year: Int, month: Int, day: Int

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Nil when the date does not exist (February 30, month 13).
    public init?(_ year: Int, _ month: Int, _ day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Day.daysIn(year: year, month: month) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    init(utcDate: Date) {
        let c = Day.utc.dateComponents([.year, .month, .day], from: utcDate)
        year = c.year!; month = c.month!; day = c.day!
    }

    /// Noon UTC on this day; only used for day arithmetic.
    var utcDate: Date {
        Day.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public static func daysIn(year: Int, month: Int) -> Int {
        guard (1...12).contains(month),
              let first = utc.date(from: DateComponents(year: year, month: month, day: 1)) else { return 0 }
        return utc.range(of: .day, in: .month, for: first)!.count
    }

    public func adding(days: Int) -> Day {
        Day(utcDate: Day.utc.date(byAdding: .day, value: days, to: utcDate)!)
    }

    /// Adds months, clamping the day (January 31 plus one month is the last day of February).
    public func adding(months: Int) -> Day {
        let (y, m) = Day.month(year, month, plus: months)
        return Day(y, m, min(day, Day.daysIn(year: y, month: m)))!
    }

    public var weekday: Weekday {
        let n = Day.utc.component(.weekday, from: utcDate) // 1 = Sunday
        return Weekday.allCases[(n + 5) % 7]
    }

    static func month(_ year: Int, _ month: Int, plus n: Int) -> (Int, Int) {
        let total = year * 12 + (month - 1) + n
        return (total / 12, total % 12 + 1)
    }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Parses "YYYY-MM-DD".
    public init?(iso: String) {
        let p = iso.split(separator: "-").map { Int($0) }
        guard p.count == 3, let y = p[0], let m = p[1], let d = p[2], let day = Day(y, m, d) else { return nil }
        self = day
    }
}

/// The one recurrence representation. The preview computes dates from it and the
/// EventKit writer converts it, so the two cannot drift apart.
///
/// Every field that matters for the unit is explicit (a monthly rule always lists
/// its days of the month), so nothing depends on how Apple fills in defaults.
public struct Rule: Equatable, Sendable {
    public enum Unit: String, Sendable { case day, week, month, year }
    public enum End: Equatable, Sendable {
        case count(Int)
        case until(Day)
    }

    public var unit: Unit
    public var interval: Int
    /// Weekly: the days it repeats on. Monthly or yearly with `ordinal`: the weekday(s) meant.
    public var weekdays: [Weekday]
    /// 1...4 or -1 (last), as in "the 2nd Tuesday". Nil otherwise.
    public var ordinal: Int?
    /// Monthly: days of the month, -1 for the last day. Yearly: exactly one day.
    public var monthDays: [Int]
    /// Yearly: the months it occurs in.
    public var months: [Int]
    public var end: End?

    public init(unit: Unit, interval: Int = 1, weekdays: [Weekday] = [], ordinal: Int? = nil,
                monthDays: [Int] = [], months: [Int] = [], end: End? = nil) {
        self.unit = unit; self.interval = interval; self.weekdays = weekdays
        self.ordinal = ordinal; self.monthDays = monthDays; self.months = months; self.end = end
    }

    /// The dates in one month that the month-level fields select, in order.
    func days(inYear y: Int, month m: Int) -> [Day] {
        let length = Day.daysIn(year: y, month: m)
        var out: [Int] = []
        if let ordinal {
            let firstWeekday = Day(y, m, 1)!.weekday.mondayIndex
            for w in weekdays {
                let firstMatch = 1 + (w.mondayIndex - firstWeekday + 7) % 7
                if ordinal == -1 {
                    out.append(firstMatch + 7 * ((length - firstMatch) / 7))
                } else {
                    let d = firstMatch + 7 * (ordinal - 1)
                    if d <= length { out.append(d) }
                }
            }
        } else {
            for d in monthDays {
                if d == -1 { out.append(length) } else if d >= 1 && d <= length { out.append(d) }
            }
        }
        return Array(Set(out)).sorted().map { Day(y, m, $0)! }
    }

    /// Candidate dates in the `index`-th period counted from the period containing `anchor`.
    func candidates(period index: Int, anchor: Day) -> [Day] {
        switch unit {
        case .day:
            return [anchor.adding(days: index * interval)]
        case .week:
            let monday = anchor.adding(days: -anchor.weekday.mondayIndex + 7 * interval * index)
            return weekdays.map(\.mondayIndex).sorted().map { monday.adding(days: $0) }
        case .month:
            let (y, m) = Day.month(anchor.year, anchor.month, plus: index * interval)
            return days(inYear: y, month: m)
        case .year:
            let y = anchor.year + index * interval
            return months.sorted().flatMap { days(inYear: y, month: $0) }
        }
    }

    /// Calls `body` with each occurrence on or after `anchor`, in order, ignoring `end`.
    /// Stops when `body` returns false, or after a long run of empty periods.
    func forEach(from anchor: Day, _ body: (Day) -> Bool) {
        var emptyRun = 0
        var index = 0
        while emptyRun < 500 {
            let found = candidates(period: index, anchor: anchor).filter { $0 >= anchor }
            emptyRun = found.isEmpty ? emptyRun + 1 : 0
            for d in found where !body(d) { return }
            index += 1
        }
    }

    /// The first occurrence on or after `day`, with periods counted from `anchor`.
    public func first(onOrAfter day: Day, anchor: Day) -> Day? {
        var result: Day?
        forEach(from: anchor) { d in
            if d >= day { result = d; return false }
            return true
        }
        return result
    }

    /// Up to `limit` occurrences starting at `first`, which must itself be an occurrence.
    public func occurrences(first: Day, limit: Int) -> [Day] {
        var out: [Day] = []
        var cap = limit
        if case .count(let n) = end { cap = min(cap, n) }
        guard cap > 0 else { return [] }
        forEach(from: first) { d in
            if case .until(let last) = end, d > last { return false }
            out.append(d)
            return out.count < cap
        }
        return out
    }
}
