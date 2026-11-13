import Foundation

public struct TimeOfDay: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int, minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour; self.minute = minute
    }

    /// Parses 24-hour "HH:MM".
    public init?(_ text: String) {
        let p = text.split(separator: ":").map { Int($0) }
        guard p.count == 2, let h = p[0], let m = p[1], let t = TimeOfDay(hour: h, minute: m) else { return nil }
        self = t
    }

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { (a.hour, a.minute) < (b.hour, b.minute) }

    /// "9:00 AM"
    public var description: String {
        String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }
}

extension Calendar {
    /// Gregorian in the user's time zone. rr's dates are Gregorian throughout, so the
    /// user's own calendar setting (Buddhist, Japanese, ...) must never be used to read them.
    public static var gregorianLocal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
}

/// The current moment as the resolver needs it, passed in so tests are deterministic.
public struct Now: Sendable {
    public let day: Day, time: TimeOfDay
    public init(day: Day, time: TimeOfDay) { self.day = day; self.time = time }

    public init(date: Date = Date(), calendar: Calendar = .gregorianLocal) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        day = Day(c.year!, c.month!, c.day!)!
        time = TimeOfDay(hour: c.hour!, minute: c.minute!)!
    }
}

public enum PlanError: Error, CustomStringConvertible {
    /// The request is outside what rr can represent.
    case unsupported(String)
    /// The intent is malformed or contradicts itself.
    case invalid(String)

    public var description: String {
        switch self {
        case .unsupported(let why): return "Not supported: \(why)"
        case .invalid(let why): return "Could not interpret that: \(why)"
        }
    }
}

/// A fully resolved reminder: actual first date, explicit rule, alert offsets.
/// This is what the preview prints and what the writer saves.
public struct Plan: Equatable, Sendable {
    public struct Alert: Equatable, Sendable {
        public let secondsBefore: Int
        public let label: String
    }

    public var title: String
    public var list: String?
    public var notes: String?
    /// First due date; nil for a reminder with no date.
    public var first: Day?
    public var time: TimeOfDay?
    public var rule: Rule?
    public var alerts: [Alert]
    public var assumptions: [String]

    /// Turns an intent into a plan. All date arithmetic happens here, never in the model.
    public init(_ intent: Intent, now: Now, defaultTime: TimeOfDay) throws {
        let today = now.day
        title = intent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlanError.invalid("no title") }
        if let why = intent.unsupported?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
            throw PlanError.unsupported(why)
        }
        list = intent.list.flatMap { $0.isEmpty ? nil : $0 }
        notes = intent.notes.flatMap { $0.isEmpty ? nil : $0 }
        assumptions = intent.assumptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        if let text = intent.time {
            guard let t = TimeOfDay(text) else { throw PlanError.invalid("time \"\(text)\" is not HH:MM") }
            time = t
        }

        // The date the user stated, if any.
        var stated: Day?
        let s = intent.start
        switch s.kind {
        case .none:
            break
        case .date:
            if let y = s.year {
                try Plan.check(y, 1900...2200, "year")
                guard let m = s.month, let d = Day(y, m, s.day ?? 1) else {
                    throw PlanError.invalid("start date does not exist")
                }
                stated = d
                if d < today { assumptions.append("\(Format.date(d, currentYear: nil)) is in the past") }
            } else if let m = s.month {
                stated = (today.year...today.year + 8).lazy
                    .compactMap { Day($0, m, s.day ?? 1) }.first { $0 >= today }
            } else if let d = s.day {
                stated = (0..<24).lazy.compactMap { i -> Day? in
                    let (y, m) = Day.month(today.year, today.month, plus: i)
                    return Day(y, m, d)
                }.first { $0 >= today }
            }
            guard stated != nil else { throw PlanError.invalid("start date does not exist") }
        case .offset:
            guard let n = s.offsetAmount, let unit = s.offsetUnit else {
                throw PlanError.invalid("relative start has no amount or unit")
            }
            try Plan.check(n, 0...1000, "relative start")
            switch unit {
            case .day: stated = today.adding(days: n)
            case .week: stated = today.adding(days: 7 * n)
            case .month: stated = today.adding(months: n)
            }
        case .weekday:
            guard let w = s.weekday else { throw PlanError.invalid("start weekday missing") }
            stated = today.adding(days: (w.mondayIndex - today.weekday.mondayIndex + 6) % 7 + 1)
        }

        let r = intent.recurrence
        let repeats = r.unit != .none

        // An early alert is an offset from a due time, so there has to be one.
        if !intent.alerts.isEmpty && time == nil {
            guard stated != nil || repeats else {
                throw PlanError.invalid("an early alert needs a due date")
            }
            time = defaultTime
            assumptions.append("due at \(defaultTime) (default; an early alert needs a time)")
        }
        let timePassedToday = time.map { $0 <= now.time } ?? false

        if repeats {
            let (resolved, firstDay) = try Plan.rule(r, stated: stated, today: today,
                                                     searchFrom: timePassedToday ? today.adding(days: 1) : today,
                                                     assumptions: &assumptions)
            rule = resolved
            first = firstDay
        } else if let stated {
            first = stated
        } else if time != nil {
            first = timePassedToday ? today.adding(days: 1) : today
            if timePassedToday { assumptions.append("tomorrow, because \(time!) has passed today") }
        }

        var seen = Set<Int>()
        alerts = try intent.alerts.map { a -> Alert in
            try Plan.check(a.amount, 1...1000, "alert amount")
            let unitSeconds = [.minute: 60, .hour: 3600, .day: 86400, .week: 604_800][a.unit]!
            return Alert(secondsBefore: a.amount * unitSeconds,
                         label: "\(a.amount) \(a.unit.rawValue)\(a.amount == 1 ? "" : "s") before")
        }
        .filter { seen.insert($0.secondsBefore).inserted }
        .sorted { $0.secondsBefore > $1.secondsBefore }
    }

    /// Rejects numbers outside a practical range before any arithmetic is done with them.
    private static func check(_ n: Int, _ range: ClosedRange<Int>, _ what: String) throws {
        guard range.contains(n) else {
            throw PlanError.invalid("\(what) must be between \(range.lowerBound) and \(range.upperBound), not \(n)")
        }
    }

    /// Makes every field of the rule explicit and finds the first occurrence.
    private static func rule(_ r: Intent.Recurrence, stated: Day?, today: Day, searchFrom: Day,
                             assumptions: inout [String]) throws -> (Rule, Day) {
        try check(r.interval, 1...1000, "repeat interval")
        let base = stated ?? today
        let inferred = stated == nil
        var weekdays = Weekday.allCases.filter(r.weekdays.contains)
        var monthDays = Array(Set(r.monthDays)).sorted()
        var months = Array(Set(r.months)).sorted()
        var ordinal = r.ordinal == 0 ? nil : r.ordinal

        guard monthDays.allSatisfy({ (1...31).contains($0) || $0 == -1 }) else {
            throw PlanError.invalid("day of month must be 1 to 31, or -1 for the last day")
        }
        guard months.allSatisfy((1...12).contains) else { throw PlanError.invalid("month must be 1 to 12") }
        if let o = ordinal, !((1...4).contains(o) || o == -1) {
            throw PlanError.unsupported("only the 1st to 4th or the last weekday of a month")
        }

        // Fields that mean nothing for the unit are dropped; models tend to fill them in.
        let unit = Rule.Unit(rawValue: r.unit.rawValue)!
        switch unit {
        case .day:
            weekdays = []; monthDays = []; months = []; ordinal = nil
        case .week:
            monthDays = []; months = []; ordinal = nil
            if weekdays.isEmpty {
                weekdays = [base.weekday]
                if inferred { assumptions.append("repeats on \(base.weekday.name) (today's weekday)") }
            }
            if r.interval > 1 && weekdays.count > 1 && weekdays.contains(.sun) {
                assumptions.append("weeks counted Monday to Sunday (Apple may place Sunday differently; untested)")
            }
        case .month, .year:
            if unit == .month {
                months = []
            } else if months.isEmpty {
                months = [base.month]
                if inferred { assumptions.append("repeats in \(Format.monthNames[base.month - 1]) (this month)") }
            }
            if ordinal != nil {
                guard !weekdays.isEmpty else { throw PlanError.invalid("an ordinal needs a weekday") }
                monthDays = []
            } else {
                guard weekdays.isEmpty else {
                    throw PlanError.unsupported(
                        "weekdays in a monthly or yearly rule need an ordinal, as in \"the 2nd Tuesday\"")
                }
                if monthDays.isEmpty {
                    monthDays = [base.day]
                    if inferred { assumptions.append("repeats on the \(Format.ordinal(base.day)) (today's date)") }
                }
                // EventKit takes the day of a yearly rule from the due date, so only one is possible.
                if unit == .year {
                    guard monthDays.count == 1, monthDays[0] > 0 else {
                        throw PlanError.unsupported(
                            "a yearly rule can use only one day of the month; split it into separate reminders")
                    }
                }
            }
        }

        // At most one limit: a count, an end date, or a length of time.
        let until = r.until.flatMap { $0.isEmpty ? nil : $0 }
        guard [r.count != nil, until != nil, r.durationAmount != nil].filter({ $0 }).count <= 1 else {
            throw PlanError.invalid("more than one limit given (a count, an end date, a duration); state one")
        }
        var end: Rule.End?
        if let n = r.count {
            try check(n, 1...10000, "occurrence count")
            end = .count(n)
        } else if let until {
            guard let last = Day(iso: until) else { throw PlanError.invalid("end date \"\(until)\" is not YYYY-MM-DD") }
            try check(last.year, 1900...2200, "end year")
            end = .until(last)
        }

        var rule = Rule(unit: unit, interval: r.interval, weekdays: weekdays, ordinal: ordinal,
                        monthDays: monthDays, months: months, end: end)

        // Where the cycle is counted from, and the earliest acceptable first date.
        let anchor: Day, earliest: Day
        if let stated {
            anchor = stated; earliest = stated
        } else if unit == .month, r.interval > 1, let m = r.anchorMonth, (1...12).contains(m) {
            anchor = Day(today.year - 1, m, 1)!; earliest = searchFrom
        } else {
            // Start at the soonest date that matches, and count "every other" from there.
            // (Every four years on February 29 has to start in a leap year.)
            let periodStart: Day
            switch unit {
            case .day, .week: periodStart = searchFrom
            case .month: periodStart = Day(searchFrom.year, searchFrom.month, 1)!
            case .year: periodStart = Day(searchFrom.year, 1, 1)!
            }
            var soonest = rule
            soonest.interval = 1
            anchor = soonest.first(onOrAfter: searchFrom, anchor: periodStart) ?? periodStart
            earliest = searchFrom
        }
        guard let first = rule.first(onOrAfter: earliest, anchor: anchor) else {
            throw PlanError.invalid("that schedule never occurs")
        }

        // A length of time ("for 10 weeks") runs from the first occurrence.
        if let n = r.durationAmount {
            guard let durationUnit = r.durationUnit else { throw PlanError.invalid("duration has no unit") }
            try check(n, 1...1000, "duration")
            let after: Day
            switch durationUnit {
            case .day: after = first.adding(days: n)
            case .week: after = first.adding(days: 7 * n)
            case .month: after = first.adding(months: n)
            case .year: after = first.adding(months: 12 * n)
            }
            rule.end = .until(after.adding(days: -1))
        }
        if case .until(let last) = rule.end, last < first {
            throw PlanError.invalid("the end date \(last) is before the first occurrence \(first)")
        }
        return (rule, first)
    }

    /// The next due dates, starting with the first.
    public func upcoming(_ count: Int) -> [Day] {
        guard let first else { return [] }
        return rule?.occurrences(first: first, limit: count) ?? [first]
    }
}
