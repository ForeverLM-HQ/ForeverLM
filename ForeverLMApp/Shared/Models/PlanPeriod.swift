import Foundation

// MARK: - Plans: a quarter and a week
//
// Planning at three scales, as Cal Newport teaches it: a quarterly plan of
// the season's few objectives and the strategy for each; a weekly plan,
// written with the quarter's plan and the calendar in view; and the day,
// planned in time blocks with the week's plan in view. The day is the Mac's
// Calendar, which `/plan` fills (`PlanTheDay`); a quarter's and a week's plan
// are Pages.
//
// Each such Page is an ordinary Markdown Doc in My Library whose id is its
// period (`plan-2026-q4`, `plan-2026-w45`), so the same period planned on two
// Macs is one record, as a daily note is (`DailyNote`), and whose title names
// it ("Q4 2026", "Week of November 2nd, 2026"), so `[[Q4 2026]]` links it
// before it exists. Quarters are calendar quarters; weeks are ISO 8601 weeks,
// Monday to Sunday, numbered the same on every Mac whatever its locale says
// a week starts on, since the number is the record's identity.

/// How long a plan looks ahead.
enum PlanScale: String, CaseIterable, Identifiable, Sendable {
    case quarter
    case week

    var id: String { rawValue }

    /// The Plan place's pill.
    var title: String {
        switch self {
        case .quarter: return "Quarter"
        case .week: return "Week"
        }
    }
}

/// One quarter or one week: a plan's period.
enum PlanPeriod: Hashable, Sendable, Identifiable {
    /// A calendar quarter, 1 to 4.
    case quarter(year: Int, quarter: Int)
    /// An ISO 8601 week, 1 to 53, of its week-numbering year (which differs
    /// from the calendar year for a week that straddles New Year).
    case week(year: Int, week: Int)

    static let idPrefix = "plan-"

    var scale: PlanScale {
        switch self {
        case .quarter: return .quarter
        case .week: return .week
        }
    }

    // MARK: Identity

    /// `2026-Q4`, `2026-W45`.
    var key: String {
        switch self {
        case .quarter(let year, let quarter): return String(format: "%04d-Q%d", year, quarter)
        case .week(let year, let week): return String(format: "%04d-W%02d", year, week)
        }
    }

    /// The Page's id: `plan-2026-q4`, `plan-2026-w45`.
    var id: String { Self.idPrefix + key.lowercased() }

    /// The period a key names (`2026-Q4`, `2026-W45`, any case); nil for any
    /// other text and for a week its year does not have.
    init?(key: String) {
        let upper = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = upper.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, let year = Int(parts[0]), year > 0 else { return nil }
        let tail = parts[1]
        if tail.count == 2, tail.hasPrefix("Q"), let quarter = Int(tail.dropFirst()), (1...4).contains(quarter) {
            self = .quarter(year: year, quarter: quarter)
        } else if tail.count == 3, tail.hasPrefix("W"), let week = Int(tail.dropFirst()),
                  (1...Self.weeks(inISOYear: year)).contains(week) {
            self = .week(year: year, week: week)
        } else {
            return nil
        }
    }

    /// The period a plan Page's id names; nil for any other id.
    init?(id: String) {
        guard id.hasPrefix(Self.idPrefix) else { return nil }
        guard let period = PlanPeriod(key: String(id.dropFirst(Self.idPrefix.count))),
              period.id == id else { return nil }
        self = period
    }

    static func isPlanID(_ id: String) -> Bool { PlanPeriod(id: id) != nil }

    // MARK: Calendars

    /// The calendar quarters and day titles are read in: Gregorian, in the
    /// Mac's time zone (or the one given, for tests).
    static func gregorian(_ zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The calendar weeks are numbered in: ISO 8601, weeks from Monday, the
    /// first week the one holding the year's first Thursday.
    static func iso(_ zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone
        return calendar
    }

    /// 52 or 53: an ISO year has 53 weeks when December 28th falls in week 53.
    static func weeks(inISOYear year: Int) -> Int {
        let zone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        components.year = year
        components.month = 12
        components.day = 28
        guard let date = gregorian(zone).date(from: components) else { return 52 }
        return iso(zone).component(.weekOfYear, from: date)
    }

    // MARK: Finding periods

    /// The quarter or week `date` falls in, where the Mac is.
    static func containing(_ date: Date, scale: PlanScale, zone: TimeZone = .current) -> PlanPeriod {
        switch scale {
        case .quarter:
            let parts = gregorian(zone).dateComponents([.year, .month], from: date)
            return .quarter(year: parts.year ?? 0, quarter: ((parts.month ?? 1) - 1) / 3 + 1)
        case .week:
            let calendar = iso(zone)
            return .week(
                year: calendar.component(.yearForWeekOfYear, from: date),
                week: calendar.component(.weekOfYear, from: date)
            )
        }
    }

    /// Midnight the period starts: a quarter's first day, a week's Monday.
    func start(zone: TimeZone = .current) -> Date? {
        switch self {
        case .quarter(let year, let quarter):
            var components = DateComponents()
            components.year = year
            components.month = (quarter - 1) * 3 + 1
            components.day = 1
            return Self.gregorian(zone).date(from: components)
        case .week(let year, let week):
            var components = DateComponents()
            components.yearForWeekOfYear = year
            components.weekOfYear = week
            components.weekday = 2
            return Self.iso(zone).date(from: components)
        }
    }

    /// Midnight after the period's last day: the next one's start.
    func end(zone: TimeZone = .current) -> Date? {
        offset(by: 1, zone: zone)?.start(zone: zone)
    }

    /// The period `count` periods on (back, for a negative count).
    func offset(by count: Int, zone: TimeZone = .current) -> PlanPeriod? {
        guard let start = start(zone: zone) else { return nil }
        let moved: Date?
        switch self {
        case .quarter:
            moved = Self.gregorian(zone).date(byAdding: .month, value: 3 * count, to: start)
        case .week:
            moved = Self.iso(zone).date(byAdding: .day, value: 7 * count, to: start)
        }
        return moved.map { Self.containing($0, scale: scale, zone: zone) }
    }

    /// The days of a week, Monday first; empty for a quarter.
    func days(zone: TimeZone = .current) -> [Date] {
        guard case .week = self, let monday = start(zone: zone) else { return [] }
        let calendar = Self.gregorian(zone)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    /// The quarter a week belongs to: the one holding its Thursday, as ISO
    /// gives a week to the year holding its Thursday. A quarter's is itself.
    func quarter(zone: TimeZone = .current) -> PlanPeriod? {
        switch self {
        case .quarter:
            return self
        case .week:
            let days = days(zone: zone)
            guard days.count == 7 else { return nil }
            return Self.containing(days[3], scale: .quarter, zone: zone)
        }
    }

    /// The weeks of a quarter, each the quarter's by its Thursday, in order;
    /// empty for a week.
    func weeks(zone: TimeZone = .current) -> [PlanPeriod] {
        guard case .quarter = self, let start = start(zone: zone) else { return [] }
        var week = Self.containing(start, scale: .week, zone: zone)
        if week.quarter(zone: zone) != self, let next = week.offset(by: 1, zone: zone) { week = next }
        var weeks: [PlanPeriod] = []
        while week.quarter(zone: zone) == self, weeks.count < 15 {
            weeks.append(week)
            guard let next = week.offset(by: 1, zone: zone) else { break }
            week = next
        }
        return weeks
    }

    // MARK: Words

    /// The Page's title, which `[[…]]` links it by: "Q4 2026", "Week of
    /// November 2nd, 2026" (its Monday, as a daily note writes a day).
    func title(zone: TimeZone = .current) -> String {
        switch self {
        case .quarter(let year, let quarter):
            return "Q\(quarter) \(year)"
        case .week:
            guard let monday = start(zone: zone) else { return key }
            return Self.weekTitlePrefix + DailyNote.title(for: monday, calendar: Self.gregorian(zone))
        }
    }

    static let weekTitlePrefix = "Week of "

    /// The period a title names: "Q4 2026", or "Week of " and a Monday as a
    /// daily note writes a day. How `[[Q4 2026]]` finds its plan before the
    /// Page exists. Nil for any other title.
    init?(title: String, zone: TimeZone = .current) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(separator: " ")
        if words.count == 2, words[0].count == 2, words[0].uppercased().hasPrefix("Q"),
           let quarter = Int(words[0].dropFirst()), (1...4).contains(quarter),
           words[1].count == 4, let year = Int(words[1]) {
            self = .quarter(year: year, quarter: quarter)
            return
        }
        guard text.lowercased().hasPrefix(Self.weekTitlePrefix.lowercased()) else { return nil }
        let calendar = Self.gregorian(zone)
        guard let dayKey = DailyNote.dayKey(fromTitle: String(text.dropFirst(Self.weekTitlePrefix.count)), calendar: calendar),
              let day = DailyNote.date(forDayKey: dayKey, calendar: calendar) else { return nil }
        let week = Self.containing(day, scale: .week, zone: zone)
        // A week is named by its Monday; any other day names no week.
        guard let monday = week.start(zone: zone), calendar.isDate(monday, inSameDayAs: day) else { return nil }
        self = week
    }

    /// The days the period spans, short: "Oct 1 – Dec 31", "Nov 2 – 8",
    /// "Dec 28 – Jan 3".
    func rangeText(zone: TimeZone = .current, locale: Locale = .current) -> String {
        guard let start = start(zone: zone), let end = end(zone: zone) else { return "" }
        let calendar = Self.gregorian(zone)
        guard let last = calendar.date(byAdding: .day, value: -1, to: end) else { return "" }
        let monthDay = DateFormatter()
        monthDay.locale = locale
        monthDay.timeZone = zone
        monthDay.setLocalizedDateFormatFromTemplate("MMMd")
        let dayOnly = DateFormatter()
        dayOnly.locale = locale
        dayOnly.timeZone = zone
        dayOnly.setLocalizedDateFormatFromTemplate("d")
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: last)
        let tail = sameMonth ? dayOnly.string(from: last) : monthDay.string(from: last)
        return "\(monthDay.string(from: start)) – \(tail)"
    }

    // MARK: The Page it starts as

    /// The Markdown a new plan Page starts with: its headings, as Newport's
    /// plans are laid out, each with a bullet to write on. A week links its
    /// quarter and lists its days.
    func template(zone: TimeZone = .current) -> String {
        // Built from lines, since an empty bullet is "- " and a trailing space
        // in a multi-line literal does not survive every editor.
        switch self {
        case .quarter:
            return [
                "## Objectives", "", "- ", "",
                "## Strategies", "", "- ", "",
                "## Not this quarter", "", "- ", "",
                "## Looking back", "", "- ", "",
            ].joined(separator: "\n")
        case .week:
            var lines: [String] = []
            if let quarter = quarter(zone: zone) {
                lines.append("Quarter: [[\(quarter.title(zone: zone))]]")
                lines.append("")
            }
            lines.append(contentsOf: ["## Big rocks", "", "- ", "", "## Deep work", "", "- ", "", "## Days", ""])
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "en_US_POSIX")
            weekday.timeZone = zone
            weekday.dateFormat = "EEEE"
            for day in days(zone: zone) {
                lines.append("- \(weekday.string(from: day)): ")
            }
            lines.append(contentsOf: ["", "## Looking back", "", "- ", ""])
            return lines.joined(separator: "\n")
        }
    }
}
