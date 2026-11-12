import SwiftUI

// MARK: - The log's words

/// How the Activity pane says what the log holds. Mirrored on the web by the
/// `*Text` helpers of the same names.
enum DayActivityText {
    static func dayTitle(for date: Date, isToday: Bool) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let text = formatter.string(from: date)
        return isToday ? "Today · \(text)" : text
    }

    static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// What the log holds for the day, kind by kind in the lane's order,
    /// kinds with nothing logged left out: "Reading 1h 40m · Chat 25m". Nil
    /// when nothing was logged.
    static func loggedSummary(_ detail: DayPlanDetail) -> String? {
        let totals = detail.loggedMinutesByKind
        let parts = DayActivityKind.allCases.compactMap { kind -> String? in
            guard let minutes = totals[kind], minutes > 0 else { return nil }
            return "\(kind.displayName) \(durationText(minutes))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One thing the day was spent on: its minutes by kind in the lane's
    /// order, how many sittings when more than one, and when it spanned —
    /// "Reading 28m · Chat 24m · 4 sittings · 14:43–20:50".
    static func groupSummary(_ group: DayActivityGroup) -> String {
        var parts = DayActivityKind.allCases.compactMap { kind -> String? in
            guard let minutes = group.minutesByKind[kind], minutes > 0 else { return nil }
            return "\(kind.displayName) \(durationText(minutes))"
        }
        let sittings = group.sittings.count
        if sittings > 1 { parts.append("\(sittings) sittings") }
        parts.append("\(DayPlan.clockString(minute: group.startMinute))–\(DayPlan.clockString(minute: group.endMinute))")
        return parts.joined(separator: " · ")
    }

    /// A card's second line: one kind reads "Reading · 15:33–16:24 · 32m";
    /// a mixed sitting names each kind's minutes — "Reading 11m · Chat 7m ·
    /// 18:49–19:27".
    static func sittingSummary(_ sitting: DayActivitySitting) -> String {
        let times = "\(DayPlan.clockString(minute: sitting.startMinute))–\(DayPlan.clockString(minute: sitting.endMinute))"
        let minutes = sitting.minutesByKind
        let kinds = DayActivityKind.allCases.filter { (minutes[$0] ?? 0) > 0 }
        if kinds.count <= 1 {
            return "\(sitting.kind.displayName) · \(times) · \(durationText(sitting.loggedMinutes))"
        }
        let parts = kinds.map { "\($0.displayName) \(durationText(minutes[$0] ?? 0))" }
        return (parts + [times]).joined(separator: " · ")
    }

    /// "3 glances under 2 minutes", nil when nothing was folded.
    static func glancesSummary(_ groups: [DayActivityGroup]) -> String? {
        let count = groups.filter(\.isGlance).count
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "glance" : "glances") under \(DayPlan.activityGlanceMinutes) minutes"
    }
}

// MARK: - The log's clock

/// The Activity pane's clock: its hour height, gutter and the sitting cards'
/// metrics.
enum DayActivityClock {
    static let hourHeight: CGFloat = 64
    static let gutterWidth: CGFloat = 52
    /// Between two side-by-side sittings.
    static let sittingColumnGap: CGFloat = 2
    /// A card is never drawn shorter than this, so a sitting holds its
    /// column for at least the minutes the card covers.
    static let sittingCardMinimumHeight: CGFloat = 14
    /// Below this a sitting's card is one line: a two-line card on a
    /// fourteen-point sliver spilled past its edge (product owner, 2026-09-21), and
    /// the icon-only bar that replaced it was a long empty dashed strip
    /// ("this looks bad", 2026-09-22). The short card centres its icon, its
    /// title at nine points and, when wide, its clock on the one line a
    /// fourteen-point card holds; the summary waits for the tooltip.
    static let sittingCardTextHeight: CGFloat = 22
    static func sittingCardShowsText(height: CGFloat) -> Bool { height >= sittingCardTextHeight }

    /// The x offset and width of one sitting among those sharing a host
    /// `hostWidth` wide, one column for every column the layout asked for.
    /// Every column the layout asked for gets its own slice, so a burst of
    /// short sittings does not print titles on top of each other. Pure.
    static func sittingColumnFrame(placed: (column: Int, columnCount: Int)?, hostWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let placed = placed ?? (column: 0, columnCount: 1)
        let columnCount = max(1, placed.columnCount)
        let column = min(columnCount - 1, max(0, placed.column))
        let columnWidth = (hostWidth - CGFloat(columnCount - 1) * sittingColumnGap) / CGFloat(columnCount)
        return (CGFloat(column) * (columnWidth + sittingColumnGap), columnWidth)
    }
}

extension DayActivityKind {
    var tint: Color {
        switch self {
        case .reading: return .teal
        case .listening: return .indigo
        case .watching: return .pink
        case .chat: return .cyan
        case .doc: return .orange
        case .offTrack: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .reading: return "book"
        case .listening: return "headphones"
        case .watching: return "play.rectangle"
        case .chat: return "bubble.left.and.bubble.right"
        case .doc: return "doc.richtext"
        case .offTrack: return "arrow.uturn.backward"
        }
    }
}

extension DayActivitySitting {
    /// The source this sitting is on, from its group's key; nil for a chat
    /// with no single source or a Doc.
    var sourceID: String? {
        let prefix = "source/"
        guard groupID.hasPrefix(prefix) else { return nil }
        let id = String(groupID.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

extension StudioViewModel {
    /// The sources each chat in `activities` was about, from the review-session
    /// records. A chat about exactly one source joins that source in the log.
    func dayChatSources(for activities: [DayActivity]) -> [String: [String]] {
        var chatSources: [String: [String]] = [:]
        for activity in activities where activity.kind == .chat {
            if let session = reviewSessionLinks.first(where: { $0.id == activity.targetID }) {
                chatSources[activity.targetID] = session.sourceIDs
            }
        }
        return chatSources
    }
}
