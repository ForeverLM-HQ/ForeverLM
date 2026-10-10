import Foundation

/// A day the Planner names: `YYYY-MM-DD` in the learner's own calendar.
///
/// The plan's id *is* its date, so every client has to agree on how one is
/// spelled and how the day before it is found. These four live apart from
/// `DayPlan` because the phone compiles them — it reads a bout out of today's
/// and yesterday's records — and `DayPlan` itself pulls in the rest of the
/// planner's models. `DayPlan`'s own statics delegate here, so there is one
/// implementation and the two can never drift.
enum PlanDate {

    /// `YYYY-MM-DD` for a moment in a calendar's local day.
    static func string(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Local midnight of a `YYYY-MM-DD` string, or nil when it is not one.
    /// The day component is read back because `DateComponents` happily rolls
    /// the 31st of February into March.
    static func startOfDay(_ dateString: String, calendar: Calendar = .current) -> Date? {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    static func isValid(_ dateString: String, calendar: Calendar = .current) -> Bool {
        startOfDay(dateString, calendar: calendar) != nil
    }

    /// The `YYYY-MM-DD` string `days` after `dateString`.
    static func string(_ dateString: String, offsetBy days: Int, calendar: Calendar = .current) -> String? {
        guard let start = startOfDay(dateString, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return string(for: shifted, calendar: calendar)
    }
}
