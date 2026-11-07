import Testing
import Foundation
@testable import ForeverLM

@Suite("To Read list")
struct ToReadListTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Noon on Saturday 7 November 2026, UTC.
    private static let now = Date(timeIntervalSince1970: 1_794_052_800)

    private static func daysAgo(_ days: Int, hour: Int = 9) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    private static func candidate(
        _ id: String,
        type: String = "article",
        added: Date = daysAgo(0),
        finished: Bool = false,
        putAway: Bool = false,
        paywalled: Bool = false,
        grouped: Bool = false,
        spoken: Bool = false
    ) -> ToReadCandidate {
        ToReadCandidate(
            id: id, sourceType: type, dateAdded: added, isFinished: finished,
            isPutAway: putAway, isPaywalled: paywalled, belongsToGroup: grouped, isSpokenScript: spoken
        )
    }

    @Test("Saved, unfinished sources wait, newest saved first")
    func newestFirst() {
        let waiting = ToReadList.waiting([
            Self.candidate("old", added: Self.daysAgo(9)),
            Self.candidate("new", added: Self.daysAgo(0)),
            Self.candidate("mid", type: "paper", added: Self.daysAgo(3)),
            Self.candidate("post", type: "xPost", added: Self.daysAgo(1)),
        ])
        #expect(waiting.map(\.id) == ["new", "post", "mid", "old"])
    }

    @Test("Finished, put-away, paywalled, grouped and spoken sources do not wait")
    func leftOut() {
        let waiting = ToReadList.waiting([
            Self.candidate("kept"),
            Self.candidate("read", finished: true),
            Self.candidate("hidden", putAway: true),
            Self.candidate("shelf", paywalled: true),
            Self.candidate("chapter", grouped: true),
            Self.candidate("script", spoken: true),
        ])
        #expect(waiting.map(\.id) == ["kept"])
    }

    @Test("Feeds, books, courses and meetings stay out: they arrive by the hundred")
    func feedKindsStayOut() {
        let kinds = ["podcast", "video", "book", "course", "meeting"]
        let waiting = ToReadList.waiting(kinds.map { Self.candidate($0, type: $0) })
        #expect(waiting.isEmpty)
    }

    @Test("A web page awaiting classification or added by hand still waits")
    func webStorageStatesWait() {
        let waiting = ToReadList.waiting([
            Self.candidate("a", type: "manual"),
            Self.candidate("b", type: "unclassified"),
        ])
        #expect(Set(waiting.map(\.id)) == ["a", "b"])
    }

    @Test("Two sources saved at one moment keep a fixed order")
    func tiesKeepAFixedOrder() {
        let moment = Self.daysAgo(0)
        let first = ToReadList.waiting([Self.candidate("b", added: moment), Self.candidate("a", added: moment)])
        let second = ToReadList.waiting([Self.candidate("a", added: moment), Self.candidate("b", added: moment)])
        #expect(first.map(\.id) == ["a", "b"])
        #expect(second.map(\.id) == ["a", "b"])
    }

    @Test("Sections follow the calendar day, not twenty-four hours")
    func sectionsByCalendarDay() {
        let late = Self.calendar.date(byAdding: .hour, value: 23, to: Self.calendar.startOfDay(for: Self.now))!
        let justBeforeMidnight = Self.calendar.date(byAdding: .minute, value: -1, to: Self.calendar.startOfDay(for: Self.now))!
        #expect(ToReadList.Section.containing(late, now: Self.now, calendar: Self.calendar) == .today)
        #expect(ToReadList.Section.containing(justBeforeMidnight, now: Self.now, calendar: Self.calendar) == .yesterday)
        #expect(ToReadList.Section.containing(Self.daysAgo(2), now: Self.now, calendar: Self.calendar) == .thisWeek)
        #expect(ToReadList.Section.containing(Self.daysAgo(6), now: Self.now, calendar: Self.calendar) == .thisWeek)
        #expect(ToReadList.Section.containing(Self.daysAgo(7), now: Self.now, calendar: Self.calendar) == .earlier)
        #expect(ToReadList.Section.containing(Self.daysAgo(-1), now: Self.now, calendar: Self.calendar) == .today)
    }

    @Test("Sections keep order, drop empty ones and keep each source's place")
    func sectionsGroupInOrder() {
        let waiting = ToReadList.waiting([
            Self.candidate("earlier", added: Self.daysAgo(30)),
            Self.candidate("today-1", added: Self.daysAgo(0, hour: 11)),
            Self.candidate("today-2", added: Self.daysAgo(0, hour: 8)),
            Self.candidate("week", added: Self.daysAgo(4)),
        ])
        let sections = ToReadList.sections(waiting, dateAdded: \.dateAdded, now: Self.now, calendar: Self.calendar)
        #expect(sections.map(\.section) == [.today, .thisWeek, .earlier])
        #expect(sections[0].items.map(\.id) == ["today-1", "today-2"])
        #expect(sections[1].items.map(\.id) == ["week"])
        #expect(sections[2].items.map(\.id) == ["earlier"])
    }

    @Test("No waiting sources, no sections")
    func noSections() {
        let sections = ToReadList.sections([ToReadCandidate](), dateAdded: \.dateAdded, now: Self.now, calendar: Self.calendar)
        #expect(sections.isEmpty)
    }
}
