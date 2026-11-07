import Foundation

// MARK: - The quarter's plan
//
// Planning at three scales, as Cal Newport teaches it: a quarterly plan of
// the season's bigger picture, its objectives and the strategies and habits
// that serve them; and the week and the day, which are planned onto the
// Mac's Calendar, written with the quarter's plan in view and moved around
// as the week goes (product owner, 2026-11-07: "weekly planning is just
// putting stuff on the calendar for the week; we can always move it
// around"). Only the quarter is a Page.
//
// That Page is an ordinary Markdown Doc in My Library whose id is its
// quarter (`plan-2026-q4`), so the same quarter planned on two Macs or on a
// phone is one record, as a daily note is (`DailyNote`), and whose title
// names it ("Q4 2026"), so `[[Q4 2026]]` links it before it exists.
// Quarters are calendar quarters.

/// One calendar quarter: a plan Page's period.
struct PlanQuarter: Hashable, Sendable, Identifiable {
    let year: Int
    /// 1 to 4.
    let quarter: Int

    init(year: Int, quarter: Int) {
        self.year = year
        self.quarter = quarter
    }

    static let idPrefix = "plan-"

    // MARK: Identity

    /// `2026-Q4`.
    var key: String { String(format: "%04d-Q%d", year, quarter) }

    /// The Page's id: `plan-2026-q4`.
    var id: String { Self.idPrefix + key.lowercased() }

    /// The quarter a key names (`2026-Q4`, any case); nil for any other text.
    init?(key: String) {
        let upper = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = upper.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, let year = Int(parts[0]), year > 0,
              parts[1].count == 2, parts[1].hasPrefix("Q"),
              let quarter = Int(parts[1].dropFirst()), (1...4).contains(quarter) else { return nil }
        self.init(year: year, quarter: quarter)
    }

    /// The quarter a plan Page's id names; nil for any other id.
    init?(id: String) {
        guard id.hasPrefix(Self.idPrefix),
              let quarter = PlanQuarter(key: String(id.dropFirst(Self.idPrefix.count))),
              quarter.id == id else { return nil }
        self = quarter
    }

    static func isPlanID(_ id: String) -> Bool { PlanQuarter(id: id) != nil }

    // MARK: Dates

    /// The calendar quarters are read in: Gregorian, in the Mac's time zone
    /// (or the one given, for tests).
    static func gregorian(_ zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The quarter `date` falls in, where the Mac is.
    static func containing(_ date: Date, zone: TimeZone = .current) -> PlanQuarter {
        let parts = gregorian(zone).dateComponents([.year, .month], from: date)
        return PlanQuarter(year: parts.year ?? 0, quarter: ((parts.month ?? 1) - 1) / 3 + 1)
    }

    /// Midnight of the quarter's first day.
    func start(zone: TimeZone = .current) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = (quarter - 1) * 3 + 1
        components.day = 1
        return Self.gregorian(zone).date(from: components)
    }

    /// Midnight after the quarter's last day: the next one's start.
    func end(zone: TimeZone = .current) -> Date? {
        offset(by: 1).start(zone: zone)
    }

    /// The quarter `count` quarters on (back, for a negative count).
    func offset(by count: Int) -> PlanQuarter {
        let index = year * 4 + (quarter - 1) + count
        return PlanQuarter(year: Int((Double(index) / 4).rounded(.down)), quarter: ((index % 4) + 4) % 4 + 1)
    }

    // MARK: Words

    /// The Page's title, which `[[…]]` links it by: "Q4 2026".
    var title: String { "Q\(quarter) \(year)" }

    /// The quarter a title such as "Q4 2026" names; nil for any other title.
    /// How `[[Q4 2026]]` finds its plan before the Page exists.
    init?(title: String) {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 2, words[0].count == 2, words[0].uppercased().hasPrefix("Q"),
              let quarter = Int(words[0].dropFirst()), (1...4).contains(quarter),
              words[1].count == 4, let year = Int(words[1]) else { return nil }
        self.init(year: year, quarter: quarter)
    }

    /// The days the quarter spans, short: "Oct 1 – Dec 31".
    func rangeText(zone: TimeZone = .current, locale: Locale = .current) -> String {
        guard let start = start(zone: zone), let end = end(zone: zone),
              let last = Self.gregorian(zone).date(byAdding: .day, value: -1, to: end) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(formatter.string(from: start)) – \(formatter.string(from: last))"
    }

    // MARK: The Page it starts as

    /// The heading the popover reads the quarter's objectives under
    /// (`PlanGlance`).
    static let objectivesHeading = "Objectives"

    /// The Markdown a new plan Page starts with, as Newport describes a
    /// quarterly plan (product owner, 2026-11-07, of the first template: "is
    /// that how Cal Newport suggested?" — it was not, then "yes, rework
    /// them"): the bigger picture at its top, the season's objectives, and
    /// the strategies, habits and rules of thumb it runs. His plans are free
    /// text with no set form; the headings only seed it. Built from lines,
    /// since an empty bullet is "- " and a trailing space in a multi-line
    /// literal does not survive every editor.
    var template: String {
        [
            "## Big picture", "", "- ", "",
            "## \(Self.objectivesHeading)", "", "- ", "",
            "## Strategies and habits", "", "- ", "",
        ].joined(separator: "\n")
    }
}

// MARK: - The quarter at a glance

/// What the calendar glyph's popover shows of the quarter the day serves:
/// its title and its written objectives (`DayNowPopover`). The week and the
/// day are on the calendar the popover already shows. Read from the plan's
/// Markdown off the main actor.
struct PlanGlance: Equatable, Sendable {
    let quarter: PlanQuarter
    /// Whether the quarter's plan Page exists.
    let exists: Bool
    /// The written bullets under Objectives, in order.
    let objectives: [String]

    /// How many objectives the glance shows.
    static let lineLimit = 5
}

/// Reading a plan Page's outline: the bullets under one of its headings.
/// Pure, so the popover's reading is tested apart.
enum PlanOutline {
    /// The written top-level bullets under the `## heading` (any level, its
    /// words matched without case), up to the next heading: each bullet's
    /// text with its marker, a task box and `[[` `]]` and `**` taken off.
    /// Empty bullets, the template's, are left out.
    static func items(under heading: String, in markdown: String, limit: Int = PlanGlance.lineLimit) -> [String] {
        var items: [String] = []
        var inSection = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let title = headingText(line) {
                if inSection { break }
                inSection = title.caseInsensitiveCompare(heading) == .orderedSame
                continue
            }
            guard inSection, raw.first.map({ !$0.isWhitespace }) ?? false,
                  let text = bulletText(line), !text.isEmpty else { continue }
            items.append(text)
            if items.count == limit { break }
        }
        return items
    }

    private static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let words = line.drop(while: { $0 == "#" })
        guard words.first == " " else { return nil }
        return words.trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(_ line: String) -> String? {
        var text: Substring
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            text = line.dropFirst(2)
        } else if line == "-" || line == "*" || line == "+" {
            return ""
        } else if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
                  !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
                  line[line.index(after: dot)...].first == " " {
            text = line[line.index(dot, offsetBy: 2)...]
        } else {
            return nil
        }
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text = text.dropFirst(box.count) }
        var clean = String(text)
        for mark in ["[[", "]]", "**"] { clean = clean.replacingOccurrences(of: mark, with: "") }
        // A block id the editor keeps at a line's end (` ^abc123def`).
        if let caret = clean.range(of: #" \^[a-z0-9]{9}$"#, options: .regularExpression) { clean.removeSubrange(caret) }
        return clean.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - The quarter's weeks, read off the calendar

/// One timed event as the Plan place reads it: the calendar's, cut down to
/// what ties it to a quarter, so the reading stays pure and compiles on the
/// phone (which has no `AppleCalendarEvent`).
struct PlanCalendarItem: Equatable, Sendable {
    /// The occurrence's key, unique on the calendar.
    let key: String
    let title: String
    let start: Date
    let end: Date
    let notes: String
    /// Someone else's time: a meeting that stays where it is.
    let isMeeting: Bool
}

/// One block of a week as the Plan place draws it.
struct PlanBlock: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isMeeting: Bool
    /// Planned toward the quarter: its notes link the quarter's plan or name
    /// one of its objectives. Meetings never are; they are the week's ground.
    let servesQuarter: Bool
    /// The objective, by its place in the plan's Objectives, its notes name.
    let objective: Int?

    var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// One day of a week: its blocks by start.
struct PlanDay: Equatable, Sendable, Identifiable {
    /// `2026-11-09`, the name the Day pane takes.
    let date: String
    let start: Date
    let blocks: [PlanBlock]

    var id: String { date }
    /// The minutes planned toward the quarter that day.
    var plannedMinutes: Int { blocks.filter(\.servesQuarter).reduce(0) { $0 + $1.minutes } }
}

/// One week of a quarter, Monday to Sunday.
struct PlanWeek: Equatable, Sendable, Identifiable {
    let start: Date
    /// Seven days, Monday first.
    let days: [PlanDay]

    var id: Date { start }
    var plannedBlocks: [PlanBlock] { days.flatMap(\.blocks).filter(\.servesQuarter) }
    var plannedMinutes: Int { plannedBlocks.reduce(0) { $0 + $1.minutes } }
    /// Planned minutes per objective, by the objective's place.
    var minutesByObjective: [Int: Int] {
        plannedBlocks.reduce(into: [:]) { sums, block in
            if let objective = block.objective { sums[objective, default: 0] += block.minutes }
        }
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return false }
        return date >= start && date < end
    }
}

/// How a quarter's weeks and days are read off the calendar: the quarter is
/// a Page and the week and the day are the calendar (product owner,
/// 2026-11-07), so the plan's three scales are tied together here, by
/// reading, never by a week record. A block serves the quarter when the
/// chat that planned it linked the quarter's plan in its notes, as `/plan
/// week` does, or named one of its objectives there.
enum PlanQuarterWeeks {
    /// The calendar weeks are read in: Gregorian, Monday first, as ISO weeks.
    static func weekCalendar(_ zone: TimeZone = .current) -> Calendar {
        var calendar = PlanQuarter.gregorian(zone)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// The Mondays of the quarter's weeks. A week straddling two quarters
    /// belongs to the one its Thursday is in, as an ISO week belongs to a
    /// year, so every week is in exactly one quarter.
    static func weekStarts(of quarter: PlanQuarter, calendar: Calendar) -> [Date] {
        guard let start = quarter.start(zone: calendar.timeZone),
              let end = quarter.end(zone: calendar.timeZone),
              let firstMonday = calendar.dateInterval(of: .weekOfYear, for: start)?.start else { return [] }
        var mondays: [Date] = []
        var monday = firstMonday
        while monday < end {
            if let thursday = calendar.date(byAdding: .day, value: 3, to: monday),
               PlanQuarter.containing(thursday, zone: calendar.timeZone) == quarter {
                mondays.append(monday)
            }
            guard let next = calendar.date(byAdding: .day, value: 7, to: monday) else { break }
            monday = next
        }
        return mondays
    }

    /// The span the quarter's weeks cover, for reading its calendar once.
    static func span(of quarter: PlanQuarter, calendar: Calendar) -> DateInterval? {
        let mondays = weekStarts(of: quarter, calendar: calendar)
        guard let first = mondays.first, let last = mondays.last,
              let end = calendar.date(byAdding: .day, value: 7, to: last) else { return nil }
        return DateInterval(start: first, end: end)
    }

    /// The quarter's weeks with their days and blocks. `items` are the timed
    /// events of the span; `objectives` the plan's written Objectives.
    static func weeks(
        of quarter: PlanQuarter,
        items: [PlanCalendarItem],
        objectives: [String],
        calendar: Calendar
    ) -> [PlanWeek] {
        let names = objectives.map(objectiveName)
        let blocks = items.map { block($0, quarter: quarter, objectiveNames: names) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        return weekStarts(of: quarter, calendar: calendar).map { monday in
            let days: [PlanDay] = (0..<7).compactMap { offset in
                guard let dayStart = calendar.date(byAdding: .day, value: offset, to: monday),
                      let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
                return PlanDay(
                    date: PlanDate.string(for: dayStart, calendar: calendar),
                    start: dayStart,
                    blocks: blocks.filter { $0.start >= dayStart && $0.start < dayEnd }
                )
            }
            return PlanWeek(start: monday, days: days)
        }
    }

    static func block(_ item: PlanCalendarItem, quarter: PlanQuarter, objectiveNames: [String]) -> PlanBlock {
        let objective = item.isMeeting ? nil : objectiveIndex(notes: item.notes, names: objectiveNames)
        let linksPlan = item.notes.range(of: quarter.id, options: .caseInsensitive) != nil
        return PlanBlock(
            id: item.key,
            title: item.title,
            start: item.start,
            end: item.end,
            isMeeting: item.isMeeting,
            servesQuarter: !item.isMeeting && (linksPlan || objective != nil),
            objective: objective
        )
    }

    /// An objective's name: its words before a parenthesis, a colon or a
    /// dash, the way objectives are written ("Etcelera (the DPG-16
    /// predictions handed over)" is "Etcelera").
    static func objectiveName(_ objective: String) -> String {
        var name = Substring(objective)
        for stop in [" (", ":", " — ", " – ", " - "] {
            if let range = name.range(of: stop) { name = name[..<range.lowerBound] }
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The objective whose name the notes say, the longest name winning when
    /// one holds another; names under three letters never match.
    static func objectiveIndex(notes: String, names: [String]) -> Int? {
        guard !notes.isEmpty else { return nil }
        var best: (index: Int, length: Int)?
        for (index, name) in names.enumerated() where name.count >= 3 {
            guard notes.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            if best.map({ name.count > $0.length }) ?? true { best = (index, name.count) }
        }
        return best?.index
    }

    /// Minutes said short: "45 min", "3 h", "2.5 h".
    static func hoursText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        let rounded = (hours * 2).rounded() / 2
        return rounded == rounded.rounded() ? "\(Int(rounded)) h" : String(format: "%.1f h", rounded)
    }
}

/// A quarter as the Plan place draws it: the plan's objectives above, its
/// weeks and days below.
struct PlanOverview: Equatable, Sendable {
    let quarter: PlanQuarter
    /// Whether the quarter's plan Page exists.
    let exists: Bool
    /// The plan's written Objectives, in order.
    let objectives: [String]
    let weeks: [PlanWeek]
    /// Whether the Mac's Calendar is on for ForeverLM; off, the weeks are empty.
    let calendarOn: Bool

    /// How many objectives the Plan place lists and colours.
    static let objectiveLimit = 8

    /// Planned minutes per objective across the quarter.
    var minutesByObjective: [Int: Int] {
        weeks.reduce(into: [:]) { sums, week in
            for (objective, minutes) in week.minutesByObjective { sums[objective, default: 0] += minutes }
        }
    }
}
