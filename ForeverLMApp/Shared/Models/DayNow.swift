import Foundation

// MARK: - Where the clock stands

/// What today's calendar says about this minute — the state the Now chip reads
/// in every Studio window's rail footer and every Reader window's toolbar.
///
/// The day is the Mac's Calendar (product owner, 2026-09-30: "there should be no
/// distinction between mac calendar and planner anymore … the agent can plan
/// our day by literally writing to the mac calendar", and "the mac calendar is
/// what gets shown in the bottom left"). Derived on every tick from today's
/// events and nothing else; nothing that draws it writes anything.
enum DayNowState: Equatable, Sendable {
    /// The Mac's Calendar is off for ForeverLM, or macOS refused it.
    case calendarOff
    /// Today's calendar holds nothing timed.
    case empty
    /// Before the day's first event.
    case beforeFirst(next: AppleCalendarEvent)
    /// Inside an event. When events overlap, the one that began last: the
    /// newest commitment is the one the hour is in.
    case inEvent(AppleCalendarEvent)
    /// Between events. `next` is nil after the day's last.
    case between(next: AppleCalendarEvent?)

    var currentEvent: AppleCalendarEvent? {
        if case .inEvent(let event) = self { return event }
        return nil
    }
}

/// How the chip marks what it says: a filled dot inside an event, a ring
/// for one about to start, a timer while a bout runs.
enum DayNowTone: Equatable, Sendable {
    case event
    /// An event starting within `DayNow.upcomingMinutes`.
    case upcoming
    case bout
}

/// One row of the day's schedule in the chip's popover (`DayNow.scheduleRows`).
enum DayNowScheduleRow: Equatable, Identifiable, Sendable {
    case event(AppleCalendarEvent)
    /// Where the clock stands, drawn between the events around it.
    case now

    var id: String {
        switch self {
        case .event(let event): return event.occurrenceKey
        case .now: return "now"
        }
    }
}

/// What the chip draws: one line, an optional tail, and a tone.
struct DayNowPresentation: Equatable, Sendable {
    var title: String
    /// "32m left", "12m over", "in 10m". Nil when there is nothing to add.
    var detail: String?
    var tone: DayNowTone

    /// The chip's compact form when the rail is hidden and it has only a few
    /// points of chrome to stand in: the detail alone, or the title when the
    /// detail says nothing.
    var compactText: String { detail ?? title }
}

enum DayNow {

    // MARK: State

    /// The events that hold a stretch of `day`: timed, not declined, not
    /// marked free, not cancelled, touching the day. By start.
    static func timedEvents(_ events: [AppleCalendarEvent], on day: Date, calendar: Calendar = .current) -> [AppleCalendarEvent] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events
            .filter { $0.holdsTime && $0.end > dayStart && $0.start < dayEnd }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
    }

    // MARK: The day pane's calendar lane

    /// The minutes of `day` an event covers, for drawing it on the Day pane's
    /// clock: its start and end clipped to the day, so an event that began
    /// yesterday starts at 00:00 and one that runs past midnight ends at 24:00.
    /// An event too short to see still covers one minute.
    static func minuteSpan(of event: AppleCalendarEvent, on day: Date, calendar: Calendar = .current) -> (start: Int, end: Int) {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        func minute(_ date: Date) -> Int {
            if date <= dayStart { return 0 }
            if date >= dayEnd { return DayPlan.minutesPerDay }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let start = minute(event.start)
        return (start, max(minute(event.end), min(start + 1, DayPlan.minutesPerDay)))
    }

    /// `hours` widened to hold every timed event of `day`, so the clock never
    /// cuts a meeting off. Pure.
    static func hourRange(_ hours: ClosedRange<Int>, holding events: [AppleCalendarEvent], on day: Date, calendar: Calendar = .current) -> ClosedRange<Int> {
        var start = hours.lowerBound
        var end = hours.upperBound
        for event in timedEvents(events, on: day, calendar: calendar) {
            let span = minuteSpan(of: event, on: day, calendar: calendar)
            start = min(start, span.start / 60)
            end = max(end, Int((Double(span.end) / 60).rounded(.up)))
        }
        return max(0, start)...min(24, max(end, start + 1))
    }

    /// The all-day events of the day that are the learner's to see: not a
    /// birthday, a cancelled or a declined one.
    static func allDayEvents(_ events: [AppleCalendarEvent]) -> [AppleCalendarEvent] {
        events.filter { $0.isAllDay && !$0.isBirthday && !$0.isCancelled && !$0.isDeclined }
    }

    /// Where the clock stands on today's calendar at `now`.
    static func state(events: [AppleCalendarEvent], calendarOn: Bool, now: Date, calendar: Calendar = .current) -> DayNowState {
        guard calendarOn else { return .calendarOff }
        let timed = timedEvents(events, on: now, calendar: calendar)
        guard let first = timed.first else { return .empty }
        let current = timed
            .filter { $0.start <= now && now < $0.end }
            .max { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end > rhs.end
            }
        if let current { return .inEvent(current) }
        if now < first.start { return .beforeFirst(next: first) }
        return .between(next: timed.first { $0.start > now })
    }

    // MARK: Presentation

    /// How soon an event has to start for the chip to show it ahead of time.
    static let upcomingMinutes = 15

    /// The chip's line for `state`, or nil when nothing is happening: the
    /// chip then draws nothing (product owner, 2026-10-06: "cleaner and fewer
    /// buttons and bells and whistles", with ChatGPT's sidebar as the model).
    /// It shows an event the clock is in, one starting within
    /// `upcomingMinutes`, and a live bout, which takes the chip over whatever
    /// the calendar says: the bout is the learner's own declaration of what
    /// this hour is. Until that day a quiet hour said so too — *Day starts
    /// 09:30*, *Free until 14:00*, *Nothing more today*, *Nothing on the
    /// calendar*, *Calendar is off*.
    static func presentation(state: DayNowState, bout: LearningBout?, now: Date) -> DayNowPresentation? {
        if let bout, let live = boutPresentation(bout, now: now) {
            return live
        }
        switch state {
        case .calendarOff, .empty, .between(next: nil):
            return nil
        case .beforeFirst(let next), .between(next: let next?):
            guard next.start.timeIntervalSince(now) <= TimeInterval(upcomingMinutes * 60) else { return nil }
            return DayNowPresentation(title: displayTitle(next), detail: startsText(at: next.start, now: now), tone: .upcoming)
        case .inEvent(let event):
            return DayNowPresentation(title: displayTitle(event), detail: remainingText(until: event.end, now: now), tone: .event)
        }
    }

    /// The chip while a bout runs: its title and where its clock stands. Nil
    /// for a bout that is finished, so the calendar's own line shows again.
    static func boutPresentation(_ bout: LearningBout, now: Date) -> DayNowPresentation? {
        switch bout.phase(now: now) {
        case .learning:
            let seconds = bout.timerEndsAt.timeIntervalSince(now)
            let minutes = Int((abs(seconds) / 60).rounded(.up))
            let detail = seconds >= 0 ? "\(durationText(minutes)) left" : "\(durationText(minutes)) over"
            return DayNowPresentation(title: bout.title, detail: detail, tone: .bout)
        case .writing:
            return DayNowPresentation(title: bout.title, detail: "write it up", tone: .bout)
        case .earned:
            return DayNowPresentation(title: bout.title, detail: "break earned", tone: .bout)
        case .resting:
            if let endsAt = bout.breakEndsAt {
                let minutes = max(0, Int((endsAt.timeIntervalSince(now) / 60).rounded(.up)))
                return DayNowPresentation(title: "Break", detail: "\(durationText(minutes)) left", tone: .bout)
            }
            return DayNowPresentation(title: "Break", detail: nil, tone: .bout)
        case .complete, .abandoned:
            return nil
        }
    }

    /// An event's title, or what the Calendar app calls an untitled one.
    static func displayTitle(_ event: AppleCalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "New Event" : title
    }

    /// "32m left", "1h 5m left"; "ending" in the event's last minute.
    static func remainingText(until end: Date, now: Date) -> String {
        let left = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        guard left > 1 else { return "ending" }
        return "\(durationText(left)) left"
    }

    /// "in 10m"; "starting" in the minute before it does.
    static func startsText(at start: Date, now: Date) -> String {
        let ahead = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        guard ahead > 1 else { return "starting" }
        return "in \(durationText(ahead))"
    }

    /// "45m", "1h", "1h 30m".
    static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// "09:30", on the learner's clock.
    static func clockString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return DayPlan.clockString(minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// "10:00–11:00".
    static func rangeText(_ event: AppleCalendarEvent) -> String {
        "\(clockString(event.start))–\(clockString(event.end))"
    }

    /// How far through `event` the clock is, 0 at its start and 1 at its end.
    static func progress(of event: AppleCalendarEvent, now: Date) -> Double? {
        let length = event.end.timeIntervalSince(event.start)
        guard length > 0 else { return nil }
        return min(max(now.timeIntervalSince(event.start) / length, 0), 1)
    }

    // MARK: The day's schedule

    /// The rows of the day's schedule in the chip's popover: today's timed
    /// events by start, and — before the first or between two — a line where
    /// the clock stands. Inside an event that event's row says where the
    /// clock is.
    static func scheduleRows(events: [AppleCalendarEvent], state: DayNowState, now: Date) -> [DayNowScheduleRow] {
        var rows = events.map(DayNowScheduleRow.event)
        switch state {
        case .beforeFirst, .between:
            let index = events.firstIndex { $0.start > now } ?? events.count
            rows.insert(.now, at: index)
        case .inEvent, .empty, .calendarOff:
            break
        }
        return rows
    }
}

// MARK: - The popover's ways on

/// The rows at the foot of the Now chip's popover, in order: what can be done
/// with the day from the chip. **Activity** — what the day actually held, on a
/// clock — is the last of them whatever the calendar's state: since shell
/// stage 4 (2026-10-01) the rail has no Activity row, and the chip, which
/// shows the day, is where the day's record is reached.
enum DayNowMenuRow: String, Equatable, Sendable, CaseIterable {
    /// Plan the Day (or Tomorrow, late in the day) in a chat that writes the
    /// calendar's events.
    case planDay
    /// A bout on the clock, offered while none runs and the clock is in no
    /// event (an event's own Start a Bout is beside its title).
    case startBout
    case openCalendar
    /// macOS refused Calendar access: the way to Privacy & Security.
    case openPrivacySettings
    /// Calendar is off in ForeverLM: the way to turn it on.
    case turnOnCalendar
    /// The Activity pane, in the chip's own window.
    case activity

    /// The rows for the calendar's state and the clock's.
    static func rows(calendarOn: Bool, calendarBlocked: Bool, boutRunning: Bool, inEvent: Bool) -> [DayNowMenuRow] {
        var rows: [DayNowMenuRow]
        if calendarOn {
            rows = [.planDay]
            if !boutRunning, !inEvent { rows.append(.startBout) }
            rows.append(.openCalendar)
        } else if calendarBlocked {
            rows = [.openPrivacySettings]
        } else {
            rows = [.turnOnCalendar]
        }
        rows.append(.activity)
        return rows
    }
}
