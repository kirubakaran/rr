import XCTest
@testable import RRCore

final class RRCoreTests: XCTestCase {
    // Friday 2026-11-13, 8:00 AM.
    let now = Now(day: Day(2026, 11, 13)!, time: TimeOfDay(hour: 8, minute: 0)!)
    let nine = TimeOfDay(hour: 9, minute: 0)!
    var pacific: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func plan(_ json: String, now: Now? = nil) throws -> Plan {
        try Plan(Intent.decode(json: Data(json.utf8)), now: now ?? self.now, defaultTime: nine)
    }

    func dates(_ p: Plan, _ n: Int = 4) -> [String] { p.upcoming(n).map(\.description) }

    // MARK: - Day

    func testDayBasics() {
        XCTAssertNil(Day(2027, 2, 29))
        XCTAssertNotNil(Day(2028, 2, 29))
        XCTAssertEqual(Day(2026, 11, 13)!.weekday, .fri)
        XCTAssertEqual(Day(2026, 12, 31)!.adding(days: 1), Day(2027, 1, 1))
        XCTAssertEqual(Day(2027, 1, 31)!.adding(months: 1), Day(2027, 2, 28))
        XCTAssertEqual(Weekday.sun.number, 1)
        XCTAssertEqual(Weekday.mon.number, 2)
        XCTAssertEqual(Weekday.sat.number, 7)
    }

    // MARK: - The README example

    func testQuarterlyWithEarlyAlert() throws {
        let p = try plan("""
        {"title": "Pay estimated taxes",
         "recurrence": {"unit": "month", "interval": 3, "month_days": [10], "anchor_month": 1},
         "alerts": [{"amount": 3, "unit": "day"}],
         "assumptions": ["quarters start in January"]}
        """)
        XCTAssertEqual(p.first, Day(2027, 1, 10))
        XCTAssertEqual(p.time, nine)
        XCTAssertEqual(dates(p), ["2027-01-10", "2027-04-10", "2027-07-10", "2027-10-10"])
        XCTAssertEqual(p.alerts.map(\.secondsBefore), [259_200])
        XCTAssertEqual(p.preview(listName: "Reminders", currentYear: 2026, calendar: pacific), """
        Pay estimated taxes
          list:    Reminders
          due:     Sun, Jan 10, 2027, 9:00 AM
          repeats: every 3 months on the 10th
          alert:   3 days before (first: Thu, Jan 7, 2027, 9:00 AM)
          next:    Jan 10, 2027 · Apr 10, 2027 · Jul 10, 2027 · Oct 10, 2027
          assumed: quarters start in January; due at 9:00 AM (default; an early alert needs a time)
        """)
    }

    func testQuarterCycleIsAlignedNotRestarted() throws {
        // In February the next quarter date on a January cycle is April, not May.
        let feb = Now(day: Day(2027, 2, 20)!, time: nine)
        let p = try plan("""
        {"title": "x", "recurrence": {"unit": "month", "interval": 3, "month_days": [10], "anchor_month": 1}}
        """, now: feb)
        XCTAssertEqual(dates(p, 2), ["2027-04-10", "2027-07-10"])
    }

    // MARK: - Recurrence shapes

    func testYearlyInSeveralMonths() throws {
        // The real US estimated tax dates fit one yearly rule.
        let p = try plan("""
        {"title": "Estimated tax", "recurrence": {"unit": "year", "months": [1, 4, 6, 9], "month_days": [15]}}
        """)
        XCTAssertEqual(dates(p, 5), ["2027-01-15", "2027-04-15", "2027-06-15", "2027-09-15", "2028-01-15"])
        XCTAssertEqual(Format.describe(p.rule!), "every year on the 15th of January, April, June and September")
    }

    func testYearlyWithTwoDaysIsUnsupported() {
        XCTAssertThrowsError(try plan("""
        {"title": "x", "recurrence": {"unit": "year", "months": [4], "month_days": [1, 15]}}
        """))
    }

    func testMonthEndAndShortMonths() throws {
        let last = try plan(#"{"title": "x", "recurrence": {"unit": "month", "month_days": [-1]}}"#,
                            now: Now(day: Day(2027, 12, 31)!, time: nine))
        XCTAssertEqual(dates(last, 3), ["2027-12-31", "2028-01-31", "2028-02-29"])
        XCTAssertEqual(Format.describe(last.rule!), "every month on the last day")

        // The 31st skips months that have no 31st, as iCalendar rules do.
        let thirtyFirst = try plan(#"{"title": "x", "recurrence": {"unit": "month", "month_days": [31]}}"#)
        XCTAssertEqual(dates(thirtyFirst), ["2026-12-31", "2027-01-31", "2027-03-31", "2027-05-31"])
    }

    func testOrdinalWeekdays() throws {
        let second = try plan("""
        {"title": "x", "recurrence": {"unit": "month", "weekdays": ["tue"], "ordinal": 2}}
        """)
        XCTAssertEqual(dates(second, 3), ["2026-12-08", "2027-01-12", "2027-02-09"])
        XCTAssertEqual(Format.describe(second.rule!), "every month on the 2nd Tuesday")

        let lastFriday = try plan("""
        {"title": "x", "recurrence": {"unit": "month", "weekdays": ["fri"], "ordinal": -1}}
        """)
        XCTAssertEqual(dates(lastFriday, 3), ["2026-11-27", "2026-12-25", "2027-01-29"])

        let thanksgiving = try plan("""
        {"title": "x", "recurrence": {"unit": "year", "months": [11], "weekdays": ["thu"], "ordinal": 4}}
        """)
        XCTAssertEqual(dates(thanksgiving, 2), ["2026-11-26", "2027-11-25"])
        XCTAssertEqual(Format.describe(thanksgiving.rule!), "every year on the 4th Thursday of November")
    }

    func testWeekly() throws {
        let biweekly = try plan("""
        {"title": "x", "recurrence": {"unit": "week", "interval": 2, "weekdays": ["fri", "mon"]}}
        """)
        // Starts today (Friday); the following Monday is in the skipped week.
        XCTAssertEqual(dates(biweekly, 5), ["2026-11-13", "2026-11-23", "2026-11-27", "2026-12-07", "2026-12-11"])
        XCTAssertEqual(Format.describe(biweekly.rule!), "every 2 weeks on Monday and Friday")

        // "Every other Thursday" said on a Friday starts with the coming Thursday.
        let thursdays = try plan(#"{"title": "x", "recurrence": {"unit": "week", "interval": 2, "weekdays": ["thu"]}}"#)
        XCTAssertEqual(dates(thursdays, 2), ["2026-11-19", "2026-12-03"])

        let weekdays = try plan("""
        {"title": "x", "time": "07:30",
         "recurrence": {"unit": "week", "weekdays": ["mon", "tue", "wed", "thu", "fri"]}}
        """)
        // 7:30 has passed today, so it starts on the next weekday.
        XCTAssertEqual(dates(weekdays, 2), ["2026-11-16", "2026-11-17"])
        XCTAssertEqual(Format.describe(weekdays.rule!), "every weekday")

        let bare = try plan(#"{"title": "x", "recurrence": {"unit": "week"}}"#)
        XCTAssertEqual(bare.rule?.weekdays, [.fri])
        XCTAssertEqual(bare.assumptions, ["repeats on Friday (today's weekday)"])
    }

    func testDailyAndEnds() throws {
        let counted = try plan(#"{"title": "x", "recurrence": {"unit": "day", "interval": 3, "count": 3}}"#)
        XCTAssertEqual(dates(counted, 10), ["2026-11-13", "2026-11-16", "2026-11-19"])
        XCTAssertEqual(Format.describe(counted.rule!), "every 3 days, 3 times")

        let until = try plan(#"{"title": "x", "recurrence": {"unit": "week", "until": "2026-12-01"}}"#)
        XCTAssertEqual(dates(until, 10), ["2026-11-13", "2026-11-20", "2026-11-27"])
        XCTAssertTrue(until.preview(listName: "L", currentYear: 2026, calendar: pacific).contains("(ends)"))
    }

    func testStatedStartBeginsTheCycle() throws {
        let p = try plan("""
        {"title": "x", "start": {"kind": "date", "month": 3, "day": 3},
         "recurrence": {"unit": "week", "interval": 2}}
        """)
        XCTAssertEqual(dates(p, 2), ["2027-03-03", "2027-03-17"])
        XCTAssertTrue(p.assumptions.isEmpty)
    }

    // MARK: - One-off reminders

    func testStartKinds() throws {
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "offset", "offset_amount": 1, "offset_unit": "day"}}"#).first,
                       Day(2026, 11, 14))
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "offset", "offset_amount": 2, "offset_unit": "week"}}"#).first,
                       Day(2026, 11, 27))
        // "Friday" said on a Friday means next week.
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "weekday", "weekday": "fri"}}"#).first,
                       Day(2026, 11, 20))
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "weekday", "weekday": "mon"}}"#).first,
                       Day(2026, 11, 16))
        // A date without a year is the next one.
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "date", "month": 4, "day": 15}}"#).first,
                       Day(2027, 4, 15))
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "date", "month": 12, "day": 1}}"#).first,
                       Day(2026, 12, 1))
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "date", "day": 5}}"#).first, Day(2026, 12, 5))
        XCTAssertEqual(try plan(#"{"title": "x", "start": {"kind": "date", "month": 2, "day": 29}}"#).first,
                       Day(2028, 2, 29))
    }

    func testTimeOnly() throws {
        XCTAssertEqual(try plan(#"{"title": "x", "time": "17:00"}"#).first, Day(2026, 11, 13))
        let passed = try plan(#"{"title": "x", "time": "07:00"}"#)
        XCTAssertEqual(passed.first, Day(2026, 11, 14))
        XCTAssertEqual(passed.assumptions, ["tomorrow, because 7:00 AM has passed today"])
    }

    func testNoDate() throws {
        let p = try plan(#"{"title": " Buy milk ", "list": "Groceries"}"#)
        XCTAssertEqual(p.title, "Buy milk")
        XCTAssertNil(p.first)
        XCTAssertEqual(p.preview(listName: "Groceries", currentYear: 2026, calendar: pacific), """
        Buy milk
          list:    Groceries
          due:     no date
        """)
    }

    // MARK: - Alerts and errors

    func testAlertAcrossDaylightSaving() throws {
        // Clocks go forward on 2027-03-14 in Los Angeles; three days is a fixed 72 hours.
        let p = try plan("""
        {"title": "x", "start": {"kind": "date", "year": 2027, "month": 3, "day": 15}, "time": "09:00",
         "alerts": [{"amount": 3, "unit": "day"}, {"amount": 30, "unit": "minute"}]}
        """)
        let text = p.preview(listName: "L", currentYear: 2026, calendar: pacific)
        XCTAssertTrue(text.contains("alert:   3 days before (Fri, Mar 12, 2027, 8:00 AM)"), text)
        XCTAssertTrue(text.contains("alert:   30 minutes before (Mon, Mar 15, 2027, 8:30 AM)"), text)
    }

    func testErrors() {
        XCTAssertThrowsError(try plan(#"{"title": "x", "unsupported": "dates differ"}"#)) {
            XCTAssertEqual("\($0)", "Not supported: dates differ")
        }
        XCTAssertThrowsError(try plan(#"{"title": ""}"#))
        XCTAssertThrowsError(try plan(#"{"title": "x", "time": "25:00"}"#))
        XCTAssertThrowsError(try plan(#"{"title": "x", "alerts": [{"amount": 1, "unit": "day"}]}"#))
        XCTAssertThrowsError(try plan(#"{"title": "x", "start": {"kind": "date", "year": 2027, "month": 2, "day": 30}}"#))
        XCTAssertThrowsError(try plan(#"{"title": "x", "recurrence": {"unit": "month", "weekdays": ["mon"]}}"#))
        XCTAssertThrowsError(try plan(#"{"title": "x", "recurrence": {"unit": "month", "month_days": [40]}}"#))
    }

    // MARK: - Review fixes

    func testLeapDayEveryFourYears() throws {
        let p = try plan("""
        {"title": "x", "recurrence": {"unit": "year", "interval": 4, "months": [2], "month_days": [29]}}
        """)
        XCTAssertEqual(dates(p, 3), ["2028-02-29", "2032-02-29", "2036-02-29"])
    }

    func testEveryOtherMonthStartsAtSoonestMatch() throws {
        let p = try plan(#"{"title": "x", "recurrence": {"unit": "month", "interval": 2, "month_days": [5]}}"#)
        XCTAssertEqual(dates(p, 2), ["2026-12-05", "2027-02-05"])
    }

    func testDurationIsNotACount() throws {
        // Ten weeks of weekdays is fifty reminders, ending the day before week eleven.
        let p = try plan("""
        {"title": "x", "recurrence": {"unit": "week", "weekdays": ["mon", "tue", "wed", "thu", "fri"],
                                      "duration_amount": 10, "duration_unit": "week"}}
        """)
        XCTAssertEqual(p.first, Day(2026, 11, 13))
        XCTAssertEqual(p.rule?.end, .until(Day(2027, 1, 21)!))
        XCTAssertEqual(p.upcoming(1000).count, 50)

        let months = try plan("""
        {"title": "x", "start": {"kind": "date", "year": 2027, "month": 1, "day": 31},
         "recurrence": {"unit": "day", "duration_amount": 1, "duration_unit": "month"}}
        """)
        XCTAssertEqual(months.rule?.end, .until(Day(2027, 2, 27)!))
    }

    func testConflictingLimitsAreRejected() {
        XCTAssertThrowsError(try plan(#"{"title": "x", "recurrence": {"unit": "day", "count": 10, "until": "2026-11-14"}}"#))
        XCTAssertThrowsError(try plan("""
        {"title": "x", "recurrence": {"unit": "day", "count": 10, "duration_amount": 2, "duration_unit": "week"}}
        """))
    }

    func testHugeNumbersAreRejectedNotCrashed() {
        let huge = Int.max
        for json in [
            #"{"title": "x", "time": "09:00", "alerts": [{"amount": \#(huge), "unit": "week"}]}"#,
            #"{"title": "x", "start": {"kind": "offset", "offset_amount": \#(huge), "offset_unit": "week"}}"#,
            #"{"title": "x", "start": {"kind": "offset", "offset_amount": \#(huge), "offset_unit": "month"}}"#,
            #"{"title": "x", "start": {"kind": "date", "year": \#(huge), "month": 1, "day": 1}}"#,
            #"{"title": "x", "recurrence": {"unit": "week", "interval": \#(huge)}}"#,
            #"{"title": "x", "recurrence": {"unit": "year", "interval": \#(huge)}}"#,
            #"{"title": "x", "recurrence": {"unit": "day", "count": \#(huge)}}"#,
            #"{"title": "x", "recurrence": {"unit": "day", "duration_amount": \#(huge), "duration_unit": "year"}}"#,
            #"{"title": "x", "recurrence": {"unit": "day", "until": "999999999-01-01"}}"#,
        ] {
            XCTAssertThrowsError(try plan(json), json)
        }
    }

    func testNonexistentTimeIsShownAdjusted() throws {
        // 2:30 AM does not exist on 2027-03-14 in Los Angeles.
        let p = try plan("""
        {"title": "x", "start": {"kind": "date", "year": 2027, "month": 3, "day": 14}, "time": "02:30",
         "alerts": [{"amount": 30, "unit": "minute"}]}
        """)
        let text = p.preview(listName: "L", currentYear: 2026, calendar: pacific)
        XCTAssertTrue(text.contains(
            "due:     Sun, Mar 14, 2027, 3:30 AM (2:30 AM does not exist that day; the clocks change)"), text)
        XCTAssertTrue(text.contains("alert:   30 minutes before (Sun, Mar 14, 2027, 3:00 AM)"), text)
    }

    func testDatesAreReadAsGregorian() {
        // Whatever calendar the user has set, "now" must come out in Gregorian years.
        let date = Date(timeIntervalSince1970: 1_794_500_000) // November 2026
        XCTAssertEqual(Calendar.gregorianLocal.identifier, .gregorian)
        XCTAssertEqual(Now(date: date).day.year, 2026)
    }

    func testSchemaIsSerializable() throws {
        let data = try JSONSerialization.data(withJSONObject: Intent.schema)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("anchor_month"))
    }
}
