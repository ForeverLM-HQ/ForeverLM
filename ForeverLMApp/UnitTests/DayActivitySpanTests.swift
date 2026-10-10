import Foundation
import Testing
@testable import ForeverLM

/// Work ForeverLM did not watch, put on the clock at the hours it ran: an
/// imported ChatGPT or Claude conversation carrying its own times.
/// See docs/tethered-workday-design.md.
@Suite("Imported day activity spans")
struct DayActivitySpanTests {

    private func temporaryRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLMTests-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A local moment on a fixed day, so the minute arithmetic is the store's
    /// and not the test machine's clock.
    private func moment(_ hour: Int, _ minute: Int = 0, day: Int = 18) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = day
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    @Test("An imported chat lands at the hours it ran, not at the minute it was imported")
    func importedSpanKeepsItsHours() throws {
        let root = temporaryRoot("ImportedSpan")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-18"

        let span = try #require(try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_1", title: "GDF15 in ChatGPT",
            from: moment(14), to: moment(15, 30)
        ))
        #expect(span.startMinute == 14 * 60)
        #expect(span.endMinute == 15 * 60 + 30)
        #expect(span.kind == .chat)
        #expect(span.dayPlanID == date, "the span belongs to the day it began in")

        let stored = try #require(try store.loadDayPlan(date)).activities
        #expect(stored.count == 1)
    }

    @Test("Re-importing the same chat widens its own span rather than drawing a second beside it")
    func reimportDoesNotDuplicate() throws {
        let root = temporaryRoot("ImportedSpanAgain")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-18"

        _ = try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_1", title: "First pass",
            from: moment(14), to: moment(15)
        )
        // The same conversation, imported again with a fuller range — which is
        // what a second export of a chat that continued looks like.
        let widened = try #require(try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_1", title: "Second pass",
            from: moment(13, 30), to: moment(16)
        ))
        #expect(widened.startMinute == 13 * 60 + 30)
        #expect(widened.endMinute == 16 * 60)
        #expect(widened.title == "Second pass")
        #expect(try #require(try store.loadDayPlan(date)).activities.count == 1)

        // A different chat is a different thing and gets its own span.
        _ = try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_2", title: "Another",
            from: moment(17), to: moment(17, 20)
        )
        #expect(try #require(try store.loadDayPlan(date)).activities.count == 2)
    }

    @Test("A declared range joins the chat's span it continues and bridges two it touches; one hours off is a sitting of its own")
    func declaredRangesSplitAtGaps() throws {
        let root = temporaryRoot("ImportedSpanGaps")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-18"

        _ = try store.recordDayActivitySpan(kind: .chat, targetID: "chat_1", title: "T", from: moment(14), to: moment(15))
        // An exchange appended three hours later, with its own hours.
        _ = try store.recordDayActivitySpan(kind: .chat, targetID: "chat_1", title: "T", from: moment(17), to: moment(17, 20))
        let apart = try #require(try store.loadDayPlan(date)).activities.sorted { $0.startMinute < $1.startMinute }
        #expect(apart.map { [$0.startMinute, $0.endMinute] } == [[14 * 60, 15 * 60], [17 * 60, 17 * 60 + 20]],
                "the afternoon between them is not drawn")

        // Within the merge gap of both ends, a range makes the two one sitting.
        let bridged = try #require(try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_1", title: "T", from: moment(15, 5), to: moment(16, 55)
        ))
        #expect(bridged.startMinute == 14 * 60 && bridged.endMinute == 17 * 60 + 20)
        #expect(try #require(try store.loadDayPlan(date)).activities.count == 1)
    }

    @Test("Observations join by the heartbeat's rule: one within the merge gap of a span's end continues it, one further starts another")
    func observedRunsFollowTheMergeGap() {
        let gap = DayPlan.activityMergeGapMinutes
        #expect(DayActivity.observedRuns(atMinutes: []).isEmpty)
        let joined = DayActivity.observedRuns(atMinutes: [600 + gap + 1, 600])
        #expect(joined.map { [$0.start, $0.end] } == [[600, 600 + gap + 2]], "unsorted stamps, one sitting")
        let split = DayActivity.observedRuns(atMinutes: [600, 600 + gap + 2])
        #expect(split.map { [$0.start, $0.end] } == [[600, 601], [600 + gap + 2, 600 + gap + 3]])
        #expect(DayActivity.observedRuns(atMinutes: [-1, DayPlan.minutesPerDay]).isEmpty, "a minute outside the day is dropped")
        // Each stamp agrees with what the heartbeat would have drawn.
        let span = DayActivity(dayPlanID: "2026-09-18", startMinute: 600, endMinute: 601, kind: .chat, targetID: "c", title: "")
        #expect(span.continues(atMinute: 600 + gap + 1))
        #expect(!span.continues(atMinute: 600 + gap + 2))
    }

    /// The reported chat's messages: a question and its answer at half past
    /// two, then nothing until seven.
    private var reportedStamps: [Date] {
        [moment(14, 26, day: 28), moment(14, 30, day: 28), moment(19, 0, day: 28), moment(19, 4, day: 28)]
    }

    @Test("A chat read from its session file is drawn in sittings, not across the afternoon the learner was away")
    func recordedChatIsDrawnInSittings() throws {
        let root = temporaryRoot("RecordedChatSittings")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-28"

        let spans = try store.recordDayActivityObservations(kind: .chat, targetID: "chat_1", title: "Seven papers", at: reportedStamps)
        #expect(spans.map { [$0.startMinute, $0.endMinute] } == [[14 * 60 + 26, 14 * 60 + 31], [19 * 60, 19 * 60 + 5]])
        #expect(spans.allSatisfy { $0.dayPlanID == date && $0.kind == .chat && $0.title == "Seven papers" })
        #expect(try #require(try store.loadDayPlan(date)).activities.count == 2)

        // The whole record again, as every later import sends it: the same
        // spans under the same ids.
        let again = try store.recordDayActivityObservations(kind: .chat, targetID: "chat_1", title: "Seven papers", at: reportedStamps)
        #expect(again.map(\.id) == spans.map(\.id))
        #expect(again.map { [$0.startMinute, $0.endMinute] } == spans.map { [$0.startMinute, $0.endMinute] })
        #expect(try #require(try store.loadDayPlan(date)).activities.count == 2)

        // The record grew: its last sitting lengthens, and a message after
        // another long gap is a sitting of its own.
        let grown = try store.recordDayActivityObservations(
            kind: .chat, targetID: "chat_1", title: "Seven papers",
            at: reportedStamps + [moment(19, 12, day: 28), moment(21, 0, day: 28)]
        )
        #expect(grown.map { [$0.startMinute, $0.endMinute] } == [[14 * 60 + 26, 14 * 60 + 31], [19 * 60, 19 * 60 + 13], [21 * 60, 21 * 60 + 1]])
        #expect(Array(grown.prefix(2)).map(\.id) == spans.map(\.id))
    }

    @Test("A span an older build drew across the whole chat becomes its first sitting under its own id; a turn had in ForeverLM stays")
    func wideSpanIsRedrawnFromTheRecord() throws {
        let root = temporaryRoot("RecordedChatWideSpan")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-28"

        // What build 167 drew for the reported chat: its first turn to its last.
        let wide = try #require(try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_1", title: "Seven papers",
            from: moment(14, 26, day: 28), to: moment(19, 4, day: 28)
        ))
        #expect(wide.durationMinutes == 278)
        // The chat continued in ForeverLM that evening.
        let inApp = try #require(try store.recordDayActivity(kind: .chat, targetID: "chat_1", title: "Seven papers", at: moment(21, 30, day: 28)))

        let spans = try store.recordDayActivityObservations(kind: .chat, targetID: "chat_1", title: "Seven papers", at: reportedStamps)
        #expect(spans.first?.id == wide.id, "the other Macs keep the newest copy of a span by id, so reusing it shortens theirs")
        #expect(spans.map { [$0.startMinute, $0.endMinute] } == [[14 * 60 + 26, 14 * 60 + 31], [19 * 60, 19 * 60 + 5]])

        let stored = try #require(try store.loadDayPlan(date)).activities
            .filter { $0.targetID == "chat_1" }
            .sorted { $0.startMinute < $1.startMinute }
        #expect(stored.map(\.id) == [wide.id, spans[1].id, inApp.id])
        #expect(stored.reduce(0) { $0 + $1.durationMinutes } == 5 + 5 + 1)
    }

    @Test("A range that runs past midnight is cut at the end of the day it began in")
    func midnightIsTheEdge() throws {
        let root = temporaryRoot("ImportedSpanMidnight")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)

        let span = try #require(try store.recordDayActivitySpan(
            kind: .chat, targetID: "chat_late", title: "Late",
            from: moment(23), to: moment(1, 30, day: 19)
        ))
        #expect(span.startMinute == 23 * 60)
        #expect(span.endMinute == DayPlan.minutesPerDay, "a day never runs past its own midnight")
        #expect(span.dayPlanID == "2026-09-18")
        #expect((try store.loadDayPlan("2026-09-19")?.activities ?? []).isEmpty)
    }

    @Test("A span that does not end after it starts, or names nothing, is refused")
    func refusals() throws {
        let root = temporaryRoot("ImportedSpanRefused")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)

        #expect(throws: KnowledgeStoreError.self) {
            _ = try store.recordDayActivitySpan(
                kind: .chat, targetID: "chat_1", title: "T", from: moment(15), to: moment(14)
            )
        }
        #expect(throws: KnowledgeStoreError.self) {
            _ = try store.recordDayActivitySpan(
                kind: .chat, targetID: "   ", title: "T", from: moment(14), to: moment(15)
            )
        }
    }

}

/// Settings → History read off the day's log: time blocks with their minutes,
/// and nothing the log did not see. See `ActivityHistory`.
@Suite("History as time blocks")
struct ActivityHistoryTests {

    private static let day = "2026-09-22"

    private func span(
        _ kind: DayActivityKind, _ target: String, _ start: Int, _ end: Int, title: String = ""
    ) -> DayActivity {
        DayActivity(dayPlanID: Self.day, startMinute: start, endMinute: end, kind: kind, targetID: target, title: title)
    }

    private func detail(_ activities: [DayActivity]) -> DayPlanDetail {
        DayPlanDetail(plan: DayPlan(date: Self.day), blocks: [], activities: activities)
    }

    private func ledger(
        _ sourceID: String,
        kinds: Set<SourceActivityKind>,
        completed: Set<SourceActivityKind> = [],
        engagedSeconds: Double = 0,
        at hour: Int = 7
    ) -> SourceConsumptionEntry {
        let dayStart = DayPlan.startOfDay(Self.day) ?? Date()
        let at = dayStart.addingTimeInterval(TimeInterval(hour * 3600))
        return SourceConsumptionEntry(
            id: "sad-\(sourceID)", sourceID: sourceID, dayStart: dayStart,
            firstActivityAt: at, lastActivityAt: at,
            kinds: kinds, completedKinds: completed, maxFraction: completed.isEmpty ? 0 : 1,
            title: "Title \(sourceID)", sourceType: "paper", domain: nil, groupTitle: nil,
            isArchived: false, engagedSeconds: engagedSeconds
        )
    }

    @Test("A memory review's material is not a review: only the minutes the review chat ran are listed, as a review")
    func memoryMaterialIsNotReviewed() throws {
        // 07:00 stamps on seven papers from the day's memory session being
        // created, and two minutes of the learner actually in it at 11:02.
        let stamps = (1...7).map { ledger("paper-\($0)", kinds: [.review]) }
        let days = ActivityHistory.days(
            details: [detail([span(.chat, "memory-2026-09-22", 11 * 60 + 2, 11 * 60 + 5, title: "September 22, 2026")])],
            ledger: stamps
        )
        let today = try #require(days.first)
        #expect(days.count == 1)
        #expect(today.untimed.isEmpty, "a review stamp is not time spent")
        let block = try #require(today.blocks.first)
        #expect(today.blocks.count == 1)
        #expect(block.title == "Memory review")
        #expect(block.minutes == [.review: 3])
        #expect(block.startMinute == 11 * 60 + 2 && block.endMinute == 11 * 60 + 5)
    }

    @Test("Reading and the chat about that one paper are one time block, with each part's minutes")
    func readingAndItsChatAreOneBlock() throws {
        let days = ActivityHistory.days(
            details: [detail([
                span(.reading, "paper", 13 * 60 + 8, 13 * 60 + 33, title: "Na paper"),
                span(.chat, "chat-1", 13 * 60 + 40, 13 * 60 + 52, title: "Sodium"),
                span(.reading, "paper", 17 * 60, 17 * 60 + 20, title: "Na paper"),
            ])],
            ledger: [],
            chatSources: ["chat-1": ["paper"]]
        )
        let blocks = try #require(days.first?.blocks)
        #expect(blocks.map(\.startMinute) == [13 * 60 + 8, 17 * 60], "two sittings, hours apart, in the order they happened")
        #expect(blocks[0].title == "Na paper")
        #expect(blocks[0].minutes == [.read: 25, .chat: 12])
        #expect(blocks[0].endMinute == 13 * 60 + 52)
        #expect(blocks[1].minutes == [.read: 20])
        #expect(days.first?.loggedMinutes == 57)
    }

    @Test("A minute's look is a glance, folded away from the time blocks")
    func briefLookIsAGlance() throws {
        let days = ActivityHistory.days(
            details: [detail([
                span(.reading, "long", 600, 640),
                span(.reading, "brief", 700, 701),
            ])],
            ledger: []
        )
        let today = try #require(days.first)
        #expect(today.blocks.map(\.targetID) == ["long"])
        #expect(today.glances.map(\.targetID) == ["brief"])
    }

    @Test("Time with no minute on the clock is listed only with real evidence")
    func untimedNeedsEvidence() throws {
        let days = ActivityHistory.days(
            details: [detail([span(.reading, "on-clock", 600, 630)])],
            ledger: [
                ledger("phone", kinds: [.reading], engagedSeconds: 720),
                ledger("marked", kinds: [.reading], completed: [.reading]),
                ledger("dwell", kinds: [.reading], engagedSeconds: 30),
                ledger("on-clock", kinds: [.reading], engagedSeconds: 1_800),
                ledger("cited", kinds: [.chat, .review], completed: [.review]),
            ]
        )
        let untimed = try #require(days.first?.untimed)
        #expect(untimed.map(\.sourceID).sorted() == ["marked", "phone"])
        let phone = try #require(untimed.first { $0.sourceID == "phone" })
        #expect(phone.part == .read && phone.engagedMinutes == 12 && !phone.isFinished)
        #expect(untimed.first { $0.sourceID == "marked" }?.isFinished == true)
    }

    @Test("A filter keeps the blocks with that part, and drops a day left with nothing")
    func filterKeepsMatchingBlocks() throws {
        let other = "2026-09-21"
        let days = ActivityHistory.days(
            details: [
                detail([span(.reading, "paper", 600, 630), span(.chat, "chat-2", 700, 720, title: "Chat")]),
                DayPlanDetail(plan: DayPlan(date: other), blocks: [], activities: [
                    DayActivity(dayPlanID: other, startMinute: 600, endMinute: 640, kind: .watching, targetID: "video", title: "Video"),
                ]),
            ],
            ledger: [],
            filter: .chats
        )
        #expect(days.map(\.id) == [Self.day])
        #expect(days.first?.blocks.map(\.targetID) == ["chat-2"])
        #expect(days.first?.loggedMinutes == 20)
    }

    @Test("The filter menu offers only the kinds the days hold, a review as Chats and time with no clock as its own kind")
    func filterMenuOffersTheKindsHeld() {
        let reading = ActivityHistory.days(details: [detail([span(.reading, "paper", 600, 630)])], ledger: [])
        #expect(ActivityHistory.filters(in: reading) == [.read], "one kind is nothing to filter")

        let mixed = ActivityHistory.days(
            details: [detail([
                span(.reading, "paper", 600, 630),
                span(.chat, "memory-2026-09-22", 700, 705),
                span(.doc, "doc-1", 800, 830),
            ])],
            ledger: [ledger("phone", kinds: [.listening], engagedSeconds: 600)]
        )
        #expect(ActivityHistory.filters(in: mixed) == [.read, .listened, .chats])
        #expect(ActivityHistory.filters(in: []).isEmpty)
    }
}
