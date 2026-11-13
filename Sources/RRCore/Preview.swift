import Foundation

/// Plain English formatting. Deliberately not locale-aware, so output is the same everywhere.
public enum Format {
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]

    /// "Jan 10", with the year appended when it differs from `currentYear` (always, if nil).
    public static func date(_ d: Day, currentYear: Int?) -> String {
        let base = "\(monthNames[d.month - 1].prefix(3)) \(d.day)"
        return d.year == currentYear ? base : "\(base), \(d.year)"
    }

    /// "10th", "22nd", "last day" for -1.
    public static func ordinal(_ n: Int) -> String {
        if n == -1 { return "last day" }
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// "a", "a and b", "a, b and c"
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// "every 3 months on the 10th"
    public static func describe(_ rule: Rule) -> String {
        let n = rule.interval
        func every(_ unit: String) -> String { n == 1 ? "every \(unit)" : "every \(n) \(unit)s" }
        let weekdayNames = list(rule.weekdays.map(\.name))
        let nth = rule.ordinal.map { $0 == -1 ? "last" : ordinal($0) } ?? ""
        let days = list(rule.monthDays.map(ordinal))
        let months = list(rule.months.map { monthNames[$0 - 1] })

        var text: String
        switch rule.unit {
        case .day:
            text = every("day")
        case .week:
            if n == 1 && rule.weekdays == [.mon, .tue, .wed, .thu, .fri] {
                text = "every weekday"
            } else if n == 1 && rule.weekdays.count == 7 {
                text = "every day"
            } else {
                text = "\(every("week")) on \(weekdayNames)"
            }
        case .month:
            text = rule.ordinal != nil ? "\(every("month")) on the \(nth) \(weekdayNames)"
                                       : "\(every("month")) on the \(days)"
        case .year:
            text = rule.ordinal != nil ? "\(every("year")) on the \(nth) \(weekdayNames) of \(months)"
                                       : "\(every("year")) on the \(days) of \(months)"
        }
        switch rule.end {
        case .count(let c): text += c == 1 ? ", once" : ", \(c) times"
        case .until(let d): text += ", until \(date(d, currentYear: nil))"
        case nil: break
        }
        return text
    }
}

extension Plan {
    /// The text shown before asking to create. `calendar` supplies the time zone used
    /// to work out when each early alert actually fires.
    public func preview(listName: String, currentYear: Int, calendar: Calendar = .current,
                        count: Int = 4) -> String {
        var lines = [title]
        func add(_ label: String, _ value: String) {
            lines.append("  " + (label + ":").padding(toLength: 9, withPad: " ", startingAt: 0) + value)
        }
        add("list", listName)

        if let first {
            var due = "\(first.weekday.short), \(Format.date(first, currentYear: currentYear))"
            if let time { due += ", \(time)" }
            add("due", due)
        } else {
            add("due", "no date")
        }
        if let rule { add("repeats", Format.describe(rule)) }

        if let first, let time {
            let dueDate = calendar.date(from: DateComponents(
                year: first.year, month: first.month, day: first.day, hour: time.hour, minute: time.minute))!
            for alert in alerts {
                let fires = Now(date: dueDate.addingTimeInterval(-Double(alert.secondsBefore)), calendar: calendar)
                let on = "\(fires.day.weekday.short), \(Format.date(fires.day, currentYear: currentYear)), \(fires.time)"
                add("alert", "\(alert.label) (\(rule == nil ? "" : "first: ")\(on))")
            }
        }
        if rule != nil {
            let dates = upcoming(count)
            let text = dates.map { Format.date($0, currentYear: currentYear) }.joined(separator: " · ")
            add("next", dates.count < count ? text + " (ends)" : text)
        }
        if let notes { add("notes", notes) }
        if !assumptions.isEmpty { add("assumed", assumptions.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}
