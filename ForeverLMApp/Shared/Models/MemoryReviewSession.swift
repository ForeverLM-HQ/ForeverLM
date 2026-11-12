import Foundation

/// Identity of the day's memory review chat.
///
/// There is one review per local day, and the session id says which day. That
/// makes "open today's review" a lookup by id rather than a query, and lets two
/// devices that both start the day's review converge on one synced record
/// instead of producing two. The prefix is read the way `ReviewSessionOrigin`
/// reads `ios-` and `carplay-`: from the id, with no schema change.
///
/// Foundation only, and compiled into the iPhone too: the phone's voice tutor
/// looks the day's chat up by this id. The Mac-side request that carries the
/// assembled cohort lives in `MemoryReviewRequest.swift`.
enum MemoryReviewSession {
    static let idPrefix = "memory-"

    /// The rail glyph for the action and for the chats it produces.
    static let sidebarIcon = "brain"

    static func sessionID(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%@%04d-%02d-%02d",
            idPrefix,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func isMemorySession(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(idPrefix)
    }

    /// The chat's title: the full date, and nothing else. The rows are reached
    /// from Memory — the Memory pane's grid — so repeating "Memory" in each one
    /// would say nothing their place does not.
    static func title(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("d MMMM y")
        return formatter.string(from: date)
    }

    /// The day key a session id names — "2026-09-17", the form the goal and
    /// the history grid count in — or nil for an id that is not a memory
    /// review's.
    static func dayKey(fromSessionID sessionID: String) -> String? {
        guard sessionID.hasPrefix(idPrefix) else { return nil }
        let key = String(sessionID.dropFirst(idPrefix.count))
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return key
    }

    /// The local day a session id names, or nil for an id that is not a
    /// memory review's.
    static func date(fromSessionID sessionID: String, calendar: Calendar = .current) -> Date? {
        guard sessionID.hasPrefix(idPrefix) else { return nil }
        let parts = sessionID.dropFirst(idPrefix.count).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)
    }

    /// What the rail shows for a memory chat. Reviews saved before the title
    /// dropped its "Memory · " prefix keep that title in their record; those
    /// rows read their date from the id instead, so the run under Memory is
    /// uniform. A title the learner typed is left alone.
    static func displayTitle(storedTitle: String, sessionID: String, calendar: Calendar = .current) -> String {
        guard storedTitle.hasPrefix(memoryTitlePrefix),
              let date = date(fromSessionID: sessionID, calendar: calendar) else { return storedTitle }
        return title(for: date, calendar: calendar)
    }

    static let memoryTitlePrefix = "Memory · "
}
