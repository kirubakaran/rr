import Foundation

/// What the model returns: the structure of the sentence, with no computed dates.
public struct Intent: Codable, Equatable, Sendable {
    public var title: String
    public var list: String?
    public var notes: String?
    public var start: Start
    /// 24-hour "HH:MM", or nil when no time of day was stated.
    public var time: String?
    public var recurrence: Recurrence
    public var alerts: [Alert]
    public var assumptions: [String]
    /// Set when the request cannot be expressed with these fields.
    public var unsupported: String?

    public struct Start: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case none, date, offset, weekday }
        public enum OffsetUnit: String, Codable, Sendable { case day, week, month }
        public var kind: Kind = .none
        public var year: Int?
        public var month: Int?
        public var day: Int?
        public var offsetAmount: Int?
        public var offsetUnit: OffsetUnit?
        public var weekday: Weekday?

        enum CodingKeys: String, CodingKey {
            case kind, year, month, day, weekday
            case offsetAmount = "offset_amount", offsetUnit = "offset_unit"
        }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .none
            year = try c.decodeIfPresent(Int.self, forKey: .year)
            month = try c.decodeIfPresent(Int.self, forKey: .month)
            day = try c.decodeIfPresent(Int.self, forKey: .day)
            offsetAmount = try c.decodeIfPresent(Int.self, forKey: .offsetAmount)
            offsetUnit = try c.decodeIfPresent(OffsetUnit.self, forKey: .offsetUnit)
            weekday = try c.decodeIfPresent(Weekday.self, forKey: .weekday)
        }
    }

    public struct Recurrence: Codable, Equatable, Sendable {
        public enum Unit: String, Codable, Sendable { case none, day, week, month, year }
        public var unit: Unit = .none
        public var interval: Int = 1
        public var weekdays: [Weekday] = []
        public var ordinal: Int?
        public var monthDays: [Int] = []
        public var months: [Int] = []
        public var anchorMonth: Int?
        public var count: Int?
        public var until: String?

        enum CodingKeys: String, CodingKey {
            case unit, interval, weekdays, ordinal, months, count, until
            case monthDays = "month_days", anchorMonth = "anchor_month"
        }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unit = try c.decodeIfPresent(Unit.self, forKey: .unit) ?? .none
            interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1
            weekdays = try c.decodeIfPresent([Weekday].self, forKey: .weekdays) ?? []
            ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal)
            monthDays = try c.decodeIfPresent([Int].self, forKey: .monthDays) ?? []
            months = try c.decodeIfPresent([Int].self, forKey: .months) ?? []
            anchorMonth = try c.decodeIfPresent(Int.self, forKey: .anchorMonth)
            count = try c.decodeIfPresent(Int.self, forKey: .count)
            until = try c.decodeIfPresent(String.self, forKey: .until)
        }
    }

    public struct Alert: Codable, Equatable, Sendable {
        public enum Unit: String, Codable, Sendable { case minute, hour, day, week }
        public var amount: Int
        public var unit: Unit
    }

    enum CodingKeys: String, CodingKey {
        case title, list, notes, start, time, recurrence, alerts, assumptions, unsupported
    }

    /// Only `title` is required, so an intent file written by hand can stay short.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        list = try c.decodeIfPresent(String.self, forKey: .list)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        start = try c.decodeIfPresent(Start.self, forKey: .start) ?? Start()
        time = try c.decodeIfPresent(String.self, forKey: .time)
        recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence) ?? Recurrence()
        alerts = try c.decodeIfPresent([Alert].self, forKey: .alerts) ?? []
        assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        unsupported = try c.decodeIfPresent(String.self, forKey: .unsupported)
    }

    public static func decode(json: Data) throws -> Intent {
        try JSONDecoder().decode(Intent.self, from: json)
    }

    // MARK: - What the model is told

    /// JSON Schema for constrained output. Only features that Anthropic structured
    /// outputs, OpenAI strict mode and Ollama all accept: no numeric bounds, every
    /// property required, nullable scalars and no nullable objects.
    public static var schema: [String: Any] {
        func nullable(_ type: String) -> [String: Any] { ["type": [type, "null"]] }
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties,
             "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let weekdays = Weekday.allCases.map(\.rawValue)
        let ints: [String: Any] = ["type": "array", "items": ["type": "integer"]]
        return object([
            "title": ["type": "string"],
            "list": nullable("string"),
            "notes": nullable("string"),
            "start": object([
                "kind": ["type": "string", "enum": ["none", "date", "offset", "weekday"]],
                "year": nullable("integer"),
                "month": nullable("integer"),
                "day": nullable("integer"),
                "offset_amount": nullable("integer"),
                "offset_unit": ["type": ["string", "null"], "enum": ["day", "week", "month", NSNull()]],
                "weekday": ["type": ["string", "null"], "enum": weekdays + [NSNull()]],
            ]),
            "time": nullable("string"),
            "recurrence": object([
                "unit": ["type": "string", "enum": ["none", "day", "week", "month", "year"]],
                "interval": ["type": "integer"],
                "weekdays": ["type": "array", "items": ["type": "string", "enum": weekdays]],
                "ordinal": nullable("integer"),
                "month_days": ints,
                "months": ints,
                "anchor_month": nullable("integer"),
                "count": nullable("integer"),
                "until": nullable("string"),
            ]),
            "alerts": ["type": "array", "items": object([
                "amount": ["type": "integer"],
                "unit": ["type": "string", "enum": ["minute", "hour", "day", "week"]],
            ])],
            "assumptions": ["type": "array", "items": ["type": "string"]],
            "unsupported": nullable("string"),
        ])
    }

    public static func systemPrompt(today: Day, lists: [String]) -> String {
        let listLine = lists.isEmpty
            ? "The user's existing lists are not known; set list to the name the user says, or null."
            : "The user's existing lists: " + lists.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        return """
        You turn one sentence describing a reminder into a JSON object for Apple Reminders. \
        You extract structure only. Never work out calendar dates: code computes every date \
        from your output and shows the result to the user for approval.

        Today is \(today.weekday.name) \(today). \(listLine)

        Fields:
        - title: the task itself, short, first letter capitalised, without the schedule words.
        - list: the existing list the user names (match loosely, return the exact existing name), otherwise null.
        - notes: detail the user gave that is neither the title nor the schedule, otherwise null.
        - start: when the reminder is first due.
          - kind "none": no date stated. Use this for a repeating reminder with no stated start.
          - kind "date": a calendar date the user stated. Fill month and day, and year only if stated. Leave unstated parts null.
          - kind "offset": relative to today. "today" is 0 day, "tomorrow" is 1 day, "in two weeks" is 2 week.
          - kind "weekday": the next occurrence of a weekday ("on Friday", "next Tuesday").
        - time: 24-hour "HH:MM" if the user gave a time of day ("5pm" is "17:00", "noon" is "12:00"), otherwise null. Never invent a time.
        - recurrence: unit "none" if it does not repeat. Otherwise:
          - unit and interval: "every 2 weeks" is week and 2, "quarterly" is month and 3, "twice a year" is month and 6.
          - weekdays: for a weekly rule, the days it repeats on ("every weekday" is week, 1, mon to fri). For a monthly or yearly rule with ordinal, the weekday meant.
          - ordinal: 1 to 4, or -1 for last, only for phrases like "the 2nd Tuesday" or "the last Friday of the month". Otherwise null.
          - month_days: days of the month for a monthly or yearly rule ("on the 10th" is [10]). -1 means the last day of the month.
          - months: for a yearly rule, the months it occurs in, 1 to 12. "every April 15" is year, 1, months [4], month_days [15]. Several dates a year that share the day of the month ("the 15th of January, April, June and September") are one yearly rule with those months.
          - anchor_month: only for a monthly rule with interval above 1 and no stated start: the month the cycle is aligned to. For "every quarter" use 1 and add the assumption "quarters start in January". Otherwise null.
          - count: the number of occurrences if the user limits it ("for 10 weeks" is 10), otherwise null.
          - until: "YYYY-MM-DD" if the user states an end date, otherwise null.
        - alerts: early alerts before the due time ("remind me 3 days before" is amount 3, unit day). Empty if none. Do not add an alert for the due time itself.
        - assumptions: one short phrase for each choice you made that the user did not state and that could reasonably have gone another way. Do not mention the time of day. Empty if none.
        - unsupported: normally null. If the request cannot be represented with these fields (dates that differ in day of month, exceptions such as "except holidays", locations), one sentence saying what cannot be expressed. Still fill in the other fields as well as you can.

        For fields that do not apply use null, an empty array, or interval 1.
        """
    }
}
