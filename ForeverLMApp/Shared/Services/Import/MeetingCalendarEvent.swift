import Foundation
import OSLog

/// Ties a meeting's recording or transcript to the calendar event it was.
///
/// The Mac's Calendar holds the meeting before it happens; its recording and
/// transcript land after. The invitation is the one record of who was asked
/// to a call whose transcript carries no speaker names, so a session with no
/// other word on who was there takes the event's guest list, read at filing
/// time. The match is made on the clock — the recording's start against the
/// day's events — with the title only breaking a tie among events not yet
/// over when the recording began, so which meeting a transcript belongs to
/// stays a deterministic question.
enum MeetingCalendarEvent {
    /// How far outside an event's window a recording may start and still be
    /// that meeting. Zoom stamps the file when recording begins, which is a
    /// few minutes either side of the invitation, and a standup that starts
    /// late is still the standup.
    static let graceMinutes = 10

    /// The event a recording starting at `start` belongs to, out of a day's
    /// events, or nil when the day holds no meeting it could be. Pure.
    ///
    /// Back-to-back meetings overlap through the grace, so rank: an event
    /// still to run or running over one that had ended when the recording
    /// began, then the one the recording is named after, then one with other
    /// people on it over the learner's own hour of work (a recording is of a
    /// meeting), then the one whose window actually holds it, then the
    /// nearest start. The first rule is
    /// for a reconnect: Zoom's forty-minute cut ends the "Alan <> Zara"
    /// call at 09:12, the host starts a new one at 09:13 in a personal room
    /// the calendar shows as "Alan Young's Zoom Meeting" 09:15–09:45,
    /// and the recording files under the first call's topic (2026-09-21). A
    /// recording cannot begin inside a meeting that is over; only a day with
    /// nothing else takes it.
    static func event(startingAt start: Date, title: String, in events: [AppleCalendarEvent]) -> AppleCalendarEvent? {
        let grace = TimeInterval(graceMinutes * 60)
        let candidates = events.filter { event in
            event.holdsTime
                && start >= event.start.addingTimeInterval(-grace)
                && start <= event.end.addingTimeInterval(grace)
        }
        guard candidates.count > 1 else { return candidates.first }
        let wanted = normalized(title)
        return candidates
            .map { event in
                (event: event,
                 over: start >= event.end ? 1 : 0,
                 named: normalized(event.title) == wanted ? 0 : 1,
                 meeting: event.hasOtherPeople ? 0 : 1,
                 inside: (start >= event.start && start < event.end) ? 0 : 1,
                 distance: abs(start.timeIntervalSince(event.start)))
            }
            .min { lhs, rhs in
                if lhs.over != rhs.over { return lhs.over < rhs.over }
                if lhs.named != rhs.named { return lhs.named < rhs.named }
                if lhs.meeting != rhs.meeting { return lhs.meeting < rhs.meeting }
                if lhs.inside != rhs.inside { return lhs.inside < rhs.inside }
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.event.eventIdentifier < rhs.event.eventIdentifier
            }?.event
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Who the calendar invited to the meeting that began at `startedAt`,
    /// as the invitation spells them, read from the Mac's Calendar now.
    /// Nothing when the calendar is off, the day holds no such meeting, or
    /// the calendar cannot be read: the caller has a session to file either
    /// way.
    static func invitedNames(startedAt: Date, title: String, service: AppleCalendarService = .shared) async -> [String] {
        guard service.isConnected else { return [] }
        let grace = TimeInterval(graceMinutes * 60)
        do {
            // A meeting that began hours before the recording and is still
            // running touches the window, so reach back a whole day.
            let events = try await service.shownEvents(
                from: startedAt.addingTimeInterval(-MemoryTutorScheduler.secondsPerDay),
                to: startedAt.addingTimeInterval(grace + 60)
            )
            return event(startingAt: startedAt, title: title, in: events)?.attendeeNames ?? []
        } catch {
            Logger(subsystem: "ForeverLM", category: "MeetingCalendarEvent")
                .error("Reading the invitation for \(title, privacy: .private) failed: \(error.localizedDescription)")
            return []
        }
    }

    /// The titles of the meetings on `date`'s calendar, for naming a
    /// recording whose own folder says only that the host's room was used.
    static func meetingTitles(on date: String, service: AppleCalendarService = .shared) async -> [String] {
        guard service.isConnected,
              let dayStart = DayPlan.startOfDay(date),
              let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart),
              let events = try? await service.shownEvents(from: dayStart, to: dayEnd) else { return [] }
        return events.filter(\.holdsTime).map(\.title).filter { !$0.isEmpty }
    }

    /// The names a session shows for who was there, from the calendar's
    /// guest list, or nil when the list is empty. One line, comma-separated,
    /// the way the folder importers write a session's presenters.
    static func participantLine(_ names: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }

    /// When the meeting a session records started, if its row knows that to
    /// the minute: a `meeting://<group>/<session key>` session whose key
    /// spells the date and time (`readAISessionKey(includeTime: true)`, which
    /// is how the Zoom watcher, the folder importers and
    /// `import_meeting_transcript_files` file a session). The key is read
    /// rather than `dateAdded` because only the key says whether the row
    /// knows the start at all: a Zoom cloud recording is dated when its link
    /// arrived, an hour after the meeting or a minute before the next one,
    /// and a session keyed by day alone started at some hour nobody wrote
    /// down. Pure.
    static func knownStart(of article: StudioArticle, calendar: Calendar = .current) -> Date? {
        // The key is read off the URL by hand, not through URLComponents: a
        // series id with a colon (`zoom:examplefellowship.zoom.us`) made
        // URLComponents refuse the URL, and every session of that series
        // answered nil here (2026-09-19).
        guard let key = StudioViewModel.meetingSessionKey(fromSourceURL: article.url) else { return nil }
        let pattern = #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})\s+(\d{1,2})[:.](\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: key, range: NSRange(key.startIndex..<key.endIndex, in: key)),
              match.numberOfRanges == 6 else { return nil }
        let fields = (1..<6).compactMap { index -> Int? in
            Range(match.range(at: index), in: key).flatMap { Int(key[$0]) }
        }
        guard fields.count == 5 else { return nil }
        var dateComponents = DateComponents()
        dateComponents.year = fields[0]
        dateComponents.month = fields[1]
        dateComponents.day = fields[2]
        dateComponents.hour = fields[3]
        dateComponents.minute = fields[4]
        return calendar.date(from: dateComponents)
    }
}
