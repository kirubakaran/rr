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

/// The current moment as the resolver needs it, passed in so tests are deterministic.
public struct Now: Sendable {
    public let day: Day, time: TimeOfDay
    public init(day: Day, time: TimeOfDay) { self.day = day; self.time = time }

    public init(date: Date = Date(), calendar: Calendar = .current) {
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
            guard let n = s.offsetAmount, n >= 0, let unit = s.offsetUnit else {
                throw PlanError.invalid("relative start has no amount or unit")
            }
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
            guard a.amount > 0 else { throw PlanError.invalid("alert amount must be positive") }
            let unitSeconds = [.minute: 60, .hour: 3600, .day: 86400, .week: 604_800][a.unit]!
            return Alert(secondsBefore: a.amount * unitSeconds,
                         label: "\(a.amount) \(a.unit.rawValue)\(a.amount == 1 ? "" : "s") before")
        }
        .filter { seen.insert($0.secondsBefore).inserted }
        .sorted { $0.secondsBefore > $1.secondsBefore }
    }

    /// Makes every field of the rule explicit and finds the first occurrence.
    private static func rule(_ r: Intent.Recurrence, stated: Day?, today: Day, searchFrom: Day,
                             assumptions: inout [String]) throws -> (Rule, Day) {
        guard r.interval >= 1 else { throw PlanError.invalid("repeat interval must be at least 1") }
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

        var end: Rule.End?
        if let n = r.count {
            guard n >= 1 else { throw PlanError.invalid("occurrence count must be at least 1") }
            end = .count(n)
        } else if let text = r.until, !text.isEmpty {
            guard let last = Day(iso: text) else { throw PlanError.invalid("end date \"\(text)\" is not YYYY-MM-DD") }
            end = .until(last)
        }

        let rule = Rule(unit: unit, interval: r.interval, weekdays: weekdays, ordinal: ordinal,
                        monthDays: monthDays, months: months, end: end)

        // Where the cycle is counted from, and the earliest acceptable first date.
        let anchor: Day, earliest: Day
        if let stated {
            anchor = stated; earliest = stated
        } else {
            earliest = searchFrom
            switch unit {
            case .day, .week:
                // Start at the soonest matching day and count "every other" from there.
                var soonest = rule
                soonest.interval = 1
                anchor = soonest.first(onOrAfter: searchFrom, anchor: searchFrom) ?? searchFrom
            case .month:
                if r.interval > 1, let m = r.anchorMonth, (1...12).contains(m) {
                    anchor = Day(today.year - 1, m, 1)!
                } else {
                    anchor = Day(today.year, today.month, 1)!
                }
            case .year:
                anchor = Day(today.year, 1, 1)!
            }
        }
        guard let first = rule.first(onOrAfter: earliest, anchor: anchor) else {
            throw PlanError.invalid("that schedule never occurs")
        }
        if case .until(let last) = end, last < first {
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
