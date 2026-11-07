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
