import EventKit
import Foundation
import RRCore

struct StoreError: Error, CustomStringConvertible {
    let description: String
}

/// The only code that touches Apple Reminders.
final class Store {
    private let store = EKEventStore()

    /// Asks macOS for Reminders access; the first run shows the system prompt.
    func requestAccess() async throws {
        let denied = StoreError(description:
            "No access to Reminders. Allow it for your terminal in System Settings > " +
            "Privacy & Security > Reminders, then run rr again.")
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            guard try await store.requestFullAccessToReminders() else { throw denied }
        default:
            throw denied
        }
    }

    private var lists: [EKCalendar] {
        store.calendars(for: .reminder).filter(\.allowsContentModifications)
    }

    var listNames: [String] { lists.map(\.title).sorted() }

    /// The list to write to: the named one (case-insensitive) or the default list.
    func list(named name: String?) throws -> EKCalendar {
        guard let name else {
            guard let list = store.defaultCalendarForNewReminders() else {
                throw StoreError(description: "Reminders has no default list.")
            }
            return list
        }
        guard let list = lists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw StoreError(description:
                "No list named \"\(name)\". Lists: \(listNames.joined(separator: ", ")).")
        }
        return list
    }

    func create(_ plan: Plan, in list: EKCalendar) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = plan.title
        reminder.notes = plan.notes
        if let first = plan.first {
            reminder.dueDateComponents = DateComponents(
                year: first.year, month: first.month, day: first.day,
                hour: plan.time?.hour, minute: plan.time?.minute)
        }
        if let rule = plan.rule {
            reminder.addRecurrenceRule(recurrenceRule(rule))
        }
        if plan.time != nil {
            // Without an alarm a timed reminder shows its time but never notifies.
            // Offsets are relative to the due date, so they move with each occurrence.
            reminder.addAlarm(EKAlarm(relativeOffset: 0))
            for alert in plan.alerts {
                reminder.addAlarm(EKAlarm(relativeOffset: -TimeInterval(alert.secondsBefore)))
            }
        }
        try store.save(reminder, commit: true)
    }
}

/// Converts the rule the preview was computed from into EventKit's form.
func recurrenceRule(_ rule: Rule, calendar: Calendar = .current) -> EKRecurrenceRule {
    func weekday(_ w: Weekday) -> EKWeekday { EKWeekday(rawValue: w.number)! }

    let frequency: EKRecurrenceFrequency
    var daysOfWeek: [EKRecurrenceDayOfWeek]?
    var daysOfMonth: [NSNumber]?
    var months: [NSNumber]?

    switch rule.unit {
    case .day:
        frequency = .daily
    case .week:
        frequency = .weekly
        daysOfWeek = rule.weekdays.map { EKRecurrenceDayOfWeek(weekday($0)) }
    case .month, .year:
        frequency = rule.unit == .month ? .monthly : .yearly
        if let ordinal = rule.ordinal {
            daysOfWeek = rule.weekdays.map { EKRecurrenceDayOfWeek(weekday($0), weekNumber: ordinal) }
        } else if rule.unit == .month {
            daysOfMonth = rule.monthDays.map { NSNumber(value: $0) }
        }
        // A yearly rule takes its day of the month from the due date.
        if rule.unit == .year { months = rule.months.map { NSNumber(value: $0) } }
    }

    var end: EKRecurrenceEnd?
    switch rule.end {
    case .count(let n):
        end = EKRecurrenceEnd(occurrenceCount: n)
    case .until(let day):
        let endOfDay = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 23, minute: 59, second: 59))!
        end = EKRecurrenceEnd(end: endOfDay)
    case nil:
        break
    }

    return EKRecurrenceRule(
        recurrenceWith: frequency, interval: rule.interval,
        daysOfTheWeek: daysOfWeek, daysOfTheMonth: daysOfMonth, monthsOfTheYear: months,
        weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
}
