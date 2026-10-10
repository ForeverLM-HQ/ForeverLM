import Foundation
import Testing
@testable import ForeverLM

/// A meeting's recording is matched to the calendar event it was, on the
/// clock, so the invitation can say who was there (`MeetingCalendarEvent`).
/// The cases are the ones the Planner's blocks were pinned by until
/// 2026-09-30, now against the Mac's Calendar.
@Suite("Meeting calendar event")
struct MeetingCalendarEventTests {

    private func at(_ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!
            .addingTimeInterval(TimeInterval(minute * 60))
    }

    private func event(
        _ title: String, _ start: Int, _ end: Int, id: String? = nil,
        others: Bool = true, declined: Bool = false, attendees: [String] = []
    ) -> AppleCalendarEvent {
        AppleCalendarEvent(
            calendarID: "CAL", eventIdentifier: id ?? "\(title)@\(start)", occurrenceDate: nil,
            title: title, start: at(start), end: at(end), isAllDay: false, isDeclined: declined,
            isFree: false, isCancelled: false, isBirthday: false, location: nil, url: nil,
            attendeeNames: attendees, hasOtherPeople: others
        )
    }

    @Test("A recording lands on the meeting it started in, and nowhere when the day held no such meeting")
    func findsItsEvent() {
        let standup = event("Robin <> Zara standup", 690, 720, attendees: ["Robin Vale", "Zara Holt"])
        let review = event("Design review", 720, 780)
        let writing = event("Write", 600, 690, others: false)
        let events = [writing, standup, review]

        // Zoom stamps the file when recording begins: a minute late, or a
        // couple of minutes early, is still that meeting.
        #expect(MeetingCalendarEvent.event(startingAt: at(692), title: "Robin <> Zara standup", in: events) == standup)
        #expect(MeetingCalendarEvent.event(startingAt: at(686), title: "Robin <> Zara standup", in: events) == standup)
        #expect(MeetingCalendarEvent.event(startingAt: at(745), title: "Design review", in: events) == review)

        // The two windows overlap through the grace, so the name decides.
        #expect(MeetingCalendarEvent.event(startingAt: at(719), title: "Design review", in: events) == review)
        #expect(MeetingCalendarEvent.event(startingAt: at(719), title: "  ROBIN <> ZARA STANDUP ", in: events) == standup)
        // An unfamiliar name falls back to the window that actually holds it.
        #expect(MeetingCalendarEvent.event(startingAt: at(719), title: "Ad hoc call", in: events) == standup)
        // A meeting outranks the learner's own hour of work around it.
        #expect(MeetingCalendarEvent.event(startingAt: at(685), title: "Ad hoc call", in: events) == standup)

        #expect(MeetingCalendarEvent.event(startingAt: at(900), title: "Robin <> Zara standup", in: events) == nil, "an unplanned meeting is just a transcript")
        let declined = event("Robin <> Zara standup", 690, 720, declined: true)
        #expect(MeetingCalendarEvent.event(startingAt: at(692), title: "Robin <> Zara standup", in: [declined]) == nil, "a declined invitation is not a meeting the learner was in")
    }

    @Test("Two calls with one title: the nearer start takes a recording made in the gap")
    func sameTitle() {
        // 2026-09-19: 08:30–09:10 and 09:15–09:45, the second recording
        // started at 09:10, in the gap.
        let first = event("Robin <> Zara", 510, 550)
        let second = event("Robin <> Zara", 555, 585)
        #expect(MeetingCalendarEvent.event(startingAt: at(550), title: "Robin <> Zara", in: [first, second]) == second)
        #expect(MeetingCalendarEvent.event(startingAt: at(510), title: "Robin <> Zara", in: [first, second]) == first)
    }

    @Test("A reconnect in the host's own room goes to the event still to run, not the call that ended")
    func reconnect() {
        // 2026-09-21: the reconnect ran in the host's personal room, which the
        // calendar showed as its own event, and the recording filed under the
        // first call's name.
        let first = event("Robin <> Zara", 510, 550)
        let room = event("Robin Vale's Zoom Meeting", 555, 585)
        #expect(MeetingCalendarEvent.event(startingAt: at(553), title: "Robin <> Zara", in: [first, room]) == room)
        #expect(MeetingCalendarEvent.event(startingAt: at(550), title: "Robin <> Zara", in: [first, room]) == room, "the end minute is not inside the event")
        // Before the first call ends, its name still holds it.
        #expect(MeetingCalendarEvent.event(startingAt: at(548), title: "Robin <> Zara", in: [first, room]) == first)
        // With nothing after it, a late recording still goes to the call it is named for.
        #expect(MeetingCalendarEvent.event(startingAt: at(553), title: "Robin <> Zara", in: [first]) == first)
    }

    @Test("The guest list reads as one line, and an empty one says nothing")
    func participantLine() {
        #expect(MeetingCalendarEvent.participantLine(["Robin Vale", " Zara Holt ", ""]) == "Robin Vale, Zara Holt")
        #expect(MeetingCalendarEvent.participantLine([]) == nil)
    }
}
