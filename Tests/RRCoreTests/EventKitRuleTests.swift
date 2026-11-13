import EventKit
import XCTest
import RRCore
@testable import rr

/// Building an EKRecurrenceRule needs no Reminders permission, so the conversion is testable.
final class EventKitRuleTests: XCTestCase {
    func testMonthlyByDay() {
        let r = recurrenceRule(Rule(unit: .month, interval: 3, monthDays: [10]))
        XCTAssertEqual(r.frequency, .monthly)
        XCTAssertEqual(r.interval, 3)
        XCTAssertEqual(r.daysOfTheMonth, [10])
        XCTAssertNil(r.daysOfTheWeek)
        XCTAssertNil(r.recurrenceEnd)
    }

    func testWeeklyAndOrdinal() {
        let weekly = recurrenceRule(Rule(unit: .week, interval: 2, weekdays: [.mon, .fri], end: .count(5)))
        XCTAssertEqual(weekly.frequency, .weekly)
        XCTAssertEqual(weekly.daysOfTheWeek?.map(\.dayOfTheWeek), [.monday, .friday])
        XCTAssertEqual(weekly.recurrenceEnd?.occurrenceCount, 5)

        let lastFriday = recurrenceRule(Rule(unit: .month, weekdays: [.fri], ordinal: -1))
        XCTAssertEqual(lastFriday.daysOfTheWeek?.first?.dayOfTheWeek, .friday)
        XCTAssertEqual(lastFriday.daysOfTheWeek?.first?.weekNumber, -1)
        XCTAssertNil(lastFriday.daysOfTheMonth)
    }

    func testYearlyUsesMonthsOnly() {
        let r = recurrenceRule(Rule(unit: .year, monthDays: [15], months: [1, 4, 6, 9]))
        XCTAssertEqual(r.frequency, .yearly)
        XCTAssertEqual(r.monthsOfTheYear, [1, 4, 6, 9])
        XCTAssertNil(r.daysOfTheMonth)
    }
}
