import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The time-block planner's model and storage: one plan per day edited in
/// place, the merge rules that keep two Macs on one day, the running-behind signal, and the
/// extension arithmetic. See docs/planner-design.md.
@Suite("Day plans")
struct DayPlanTests {
    @Test("Spans come off the log for good, and the day they sat in is touched")
    func deleteDayActivities() throws {
        let store = try KnowledgeStore(inMemory: true)
        let morning = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let date = DayPlan.dateString(for: morning)
        let reading = try #require(try store.recordDayActivitySpan(kind: .reading, targetID: "src-atlas", title: "Atlas", from: morning, to: morning.addingTimeInterval(1800)))
        let chat = try #require(try store.recordDayActivitySpan(kind: .chat, targetID: "chat-1", title: "About the atlas", from: morning.addingTimeInterval(1800), to: morning.addingTimeInterval(2400)))
        let before = try #require(try store.loadDayPlan(date))
        #expect(before.activities.count == 2)
        try store.deleteDayActivities([reading.id, " \(reading.id) ", ""])
        let after = try #require(try store.loadDayPlan(date))
        #expect(after.activities.map(\.id) == [chat.id])
        #expect(after.plan.updatedAt >= before.plan.updatedAt)
        try store.deleteDayActivities(["no-such-span"])
        #expect(try store.loadDayPlan(date)?.activities.count == 1, "an unknown id deletes nothing and is not an error")
        try store.deleteDayActivities([])
        #expect(try store.loadDayPlan(date)?.activities.count == 1)
    }


    // MARK: - Model

    @Test("A block's purpose parses tolerantly, is work by default, and says which hours are about material")
    func purposeParsing() {
        #expect(TimeBlockPurpose.parse(nil) == .work)
        #expect(TimeBlockPurpose.parse("") == .work)
        #expect(TimeBlockPurpose.parse("  Review ") == .review)
        #expect(TimeBlockPurpose.parse("READ") == .read)
        #expect(TimeBlockPurpose.parse("deep") == .work, "the retired kind is not a purpose and reads as work")
        #expect(TimeBlock(dayPlanID: "2026-09-19", startMinute: 540, endMinute: 600, title: "X").purpose == .work)
        #expect(TimeBlockPurpose.allCases.map(\.displayName) == ["Work", "Read", "Review"])
        #expect(TimeBlockPurpose.allCases.map(\.needsSources) == [false, true, true])
        #expect(TimeBlockPurpose.work.symbolName == nil, "work is the default and wears nothing")
        #expect(TimeBlockPurpose.read.symbolName != nil && TimeBlockPurpose.review.symbolName != nil)
    }

    @Test("A block's purpose rides its record as a key, and a record without the key is work")
    func purposeCodable() throws {
        let block = TimeBlock(dayPlanID: "2026-09-19", startMinute: 540, endMinute: 630, title: "Review GDF15", sourceIDs: ["src-a"], purpose: .review)
        let encoded = try JSONEncoder().encode(block)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"purpose\":\"review\""))
        #expect(try JSONDecoder().decode(TimeBlock.self, from: encoded).purpose == .review)

        // A block written by a build before schema 123 says nothing about
        // what kind of hour it is; it is work, as every block was.
        let older = try JSONDecoder().decode(TimeBlock.self, from: Data("""
        {"id":"b","dayPlanID":"2026-09-19","startMinute":540,"endMinute":600,"title":"Old","sourceIDs":["src-a"]}
        """.utf8))
        #expect(older.purpose == .work)
        // A word a newer build might one day write is read as work too, never
        // as a decode failure that drops the whole day.
        let stranger = try JSONDecoder().decode(TimeBlock.self, from: Data("""
        {"id":"b","dayPlanID":"2026-09-19","startMinute":540,"endMinute":600,"title":"New","purpose":"rehearse"}
        """.utf8))
        #expect(stranger.purpose == .work)
    }

    @Test("The day's memory review block is drawn as a review; the closing block is work")
    func drawnBlocksCarryTheirPurpose() throws {
        let review = try #require(DayPlan.memoryReviewBlock(for: "2026-09-19", among: [], minutes: 15, earliestMinute: 540))
        #expect(review.purpose == .review)
        #expect(review.sourceIDs.isEmpty, "the one review drawn without sources: it reviews the day's memory")
        #expect(DayPlan.isMemoryReviewTitle(review.title))
        #expect(DayPlan.isMemoryReviewTitle("  memory review "))
        #expect(!DayPlan.isMemoryReviewTitle("Review GDF15"))
        let closing = try #require(DayPlan.closingBlock(for: "2026-09-19", after: [review]))
        #expect(closing.purpose == .work)
    }

    @Test("A block's location and notes give up their web links as buttons, named for the meeting service")
    func blockLinks() {
        let zoom = "https://us05web.zoom.us/j/12345678901?pwd=ExAmPlEpAsScOdEeXaMpLePaSsCoDe.1"
        // The calendar's conference link lives in `location`; it is the Join button.
        var block = TimeBlock(dayPlanID: "2026-09-19", startMinute: 510, endMinute: 550, title: "Weekly lab sync", location: zoom)
        #expect(block.links.map(\.label) == ["Join Zoom"])
        #expect(block.links.first?.url.absoluteString == zoom)
        #expect(block.locationText == nil, "a link is the Join button, not a line of the editor")
        // A link the learner wrote into the notes is a button too, after the calendar's, and once.
        block.notes = "Ask about the atlas: https://www.example.org/agenda and \(zoom)"
        #expect(block.links.map(\.label) == ["Join Zoom", "Open example.org"])
        // A room is a line, not a button; a hand-drawn block has neither.
        block.location = "Room 4.12, Oxford"
        #expect(block.locationText == "Room 4.12, Oxford")
        #expect(block.links.map(\.label) == ["Open example.org", "Join Zoom"])
        #expect(TimeBlock(dayPlanID: "2026-09-19", startMinute: 510, endMinute: 550, title: "Write").links.isEmpty)

        // A location string with a link in prose, and the same link twice, gives one button.
        let meet = TimeBlockLink.links(in: "Standup at https://meet.google.com/abc-defg-hij (also https://meet.google.com/abc-defg-hij)")
        #expect(meet.map(\.label) == ["Join Google Meet"])

        // Anything else is opened under its host; several links keep their order.
        let mixed = TimeBlockLink.links(in: "Notes: https://www.example.org/agenda then https://teams.microsoft.com/l/meetup-join/x")
        #expect(mixed.map(\.label) == ["Open example.org", "Join Teams"])

        // Plain text, an address, or a non-web scheme is not a button.
        #expect(TimeBlockLink.links(in: nil).isEmpty)
        #expect(TimeBlockLink.links(in: "Room 4.12, Oxford").isEmpty)
        #expect(TimeBlockLink.links(in: "mailto:zara@example.org").isEmpty)
    }

    @Test("At midnight a pane on today follows the clock; a pane on another day stays put")
    func selectionAfterDayChange() {
        #expect(DayModel.selection(afterDayChange: "2026-09-10", from: "2026-09-10", to: "2026-09-11") == "2026-09-11")
        #expect(DayModel.selection(afterDayChange: "2026-09-12", from: "2026-09-10", to: "2026-09-11") == "2026-09-12")
        #expect(DayModel.selection(afterDayChange: "2026-09-08", from: "2026-09-10", to: "2026-09-11") == "2026-09-08")
        // The clock can also move backwards (a time-zone change, a corrected clock).
        #expect(DayModel.selection(afterDayChange: "2026-09-11", from: "2026-09-11", to: "2026-09-10") == "2026-09-10")
    }

    @Test("A sitting is drawn in the block that held most of it, cut to the block, or in the free stretch between blocks that did")
    func activityPlacements() {
        // The product owner's 2026-09-20 clock: the TCA block at 13:15 had TCA reading beside it in the old lane and read as a failed plan.
        let date = "2026-09-20"
        let tca = TimeBlock(dayPlanID: date, startMinute: 795, endMinute: 870, title: "TCA cycle measurements")
        let waypoint = TimeBlock(dayPlanID: date, startMinute: 945, endMinute: 1080, title: "Grant writing")
        func sitting(_ id: String, _ start: Int, _ end: Int) -> DayActivitySitting {
            DayActivitySitting(id: id, groupID: id, kind: .reading, title: id, startMinute: start, endMinute: end, spans: [])
        }
        let mito = sitting("mito", 779, 820)   // 12:59–13:40: 25 minutes inside the block, 16 before it
        let chat = sitting("chat", 818, 845)   // wholly inside
        let early = sitting("early", 920, 950) // 15:20–15:50: 5 inside the writing block, 25 in the stretch before it
        let free = sitting("free", 648, 680)   // 10:48–11:20, no block near
        let placed = DayPlanDetail.activityPlacements([mito, chat, early, free], blocks: [tca, waypoint], clockStartMinute: 360, clockEndMinute: 1440)
        #expect(placed["mito"] == DayActivityPlacement(host: .block(id: tca.id), drawnStartMinute: 795, drawnEndMinute: 820))
        #expect(placed["chat"] == DayActivityPlacement(host: .block(id: tca.id), drawnStartMinute: 818, drawnEndMinute: 845))
        #expect(placed["early"] == DayActivityPlacement(host: .free(startMinute: 870, endMinute: 945), drawnStartMinute: 920, drawnEndMinute: 945))
        #expect(placed["free"] == DayActivityPlacement(host: .free(startMinute: 360, endMinute: 795), drawnStartMinute: 648, drawnEndMinute: 680))
        // A tie goes to the block: the plan's frame is the better host.
        let tie = sitting("tie", 860, 880)
        #expect(DayPlanDetail.activityPlacements([tie], blocks: [tca], clockStartMinute: 0, clockEndMinute: 1440)["tie"]?.blockID == tca.id)
        // Of two blocks the one holding more of it wins, and the card is cut to that one.
        let straddle = sitting("straddle", 860, 960)
        #expect(DayPlanDetail.activityPlacements([straddle], blocks: [tca, waypoint], clockStartMinute: 0, clockEndMinute: 1440)["straddle"]
            == DayActivityPlacement(host: .free(startMinute: 870, endMinute: 945), drawnStartMinute: 870, drawnEndMinute: 945))
        // A sitting with no minutes goes where its start falls.
        let point = sitting("point", 800, 800)
        #expect(DayPlanDetail.activityPlacements([point], blocks: [tca], clockStartMinute: 0, clockEndMinute: 1440)["point"]?.blockID == tca.id)
    }

    @Test("A sitting's card counts its lines and columns")
    func cardMetrics() {
        // A sitting's card takes its two-line layout from 22 points; under
        // that it is one centred line.
        #expect(!DayActivityClock.sittingCardShowsText(height: DayActivityClock.sittingCardMinimumHeight))
        #expect(!DayActivityClock.sittingCardShowsText(height: 21))
        #expect(DayActivityClock.sittingCardShowsText(height: 22))
        // Sittings sharing a host split it one column each; a fourth
        // column is its own, not drawn over the third.
        let alone = DayActivityClock.sittingColumnFrame(placed: nil, hostWidth: 300)
        #expect(alone.x == 0 && alone.width == 300)
        let right = DayActivityClock.sittingColumnFrame(placed: (column: 1, columnCount: 2), hostWidth: 302)
        #expect(right.x == 152 && right.width == 150)
        let third = DayActivityClock.sittingColumnFrame(placed: (column: 2, columnCount: 4), hostWidth: 302)
        let fourth = DayActivityClock.sittingColumnFrame(placed: (column: 3, columnCount: 4), hostWidth: 302)
        #expect(third.x == 152 && third.width == 74)
        #expect(fourth.x == 228 && fourth.width == 74)
    }

    @Test("The Activity clock opens on the hour of the day's first card, inside the clock")
    func activityClockOpeningHour() {
        let groups = DayPlanDetail.activityGroups([
            DayActivity(id: "a", dayPlanID: "d", startMinute: 8 * 60 + 23, endMinute: 8 * 60 + 30, kind: .reading, targetID: "s", title: "S"),
            DayActivity(id: "b", dayPlanID: "d", startMinute: 13 * 60 + 38, endMinute: 14 * 60 + 14, kind: .reading, targetID: "t", title: "T"),
        ])
        let sittings = DayPlanDetail.activitySittings(groups)
        // A plan with a block at 00:15 draws the clock from midnight; the
        // log still opens at 08:00.
        #expect(DayActivityTimelineView.openingHour(sittings: sittings, hourRange: 0...24, fallback: 0) == 8)
        #expect(DayActivityTimelineView.openingHour(sittings: [], hourRange: 0...24, fallback: 7) == 7)
        #expect(DayActivityTimelineView.openingHour(sittings: sittings, hourRange: 10...20, fallback: 7) == 10)
        #expect(DayActivityTimelineView.openingHour(sittings: [], hourRange: 6...9, fallback: 12) == 8)
    }

    @Test("By source spans the hours the log covers and keeps its hour labels apart")
    func activityBySourceAxis() {
        let groups = DayPlanDetail.activityGroups([
            DayActivity(id: "a", dayPlanID: "d", startMinute: 8 * 60 + 23, endMinute: 8 * 60 + 30, kind: .reading, targetID: "s", title: "S"),
            DayActivity(id: "b", dayPlanID: "d", startMinute: 16 * 60 + 45, endMinute: 16 * 60 + 50, kind: .reading, targetID: "s", title: "S"),
        ])
        let sittings = DayPlanDetail.activitySittings(groups)
        #expect(DayActivityBySourceView.axisHours(sittings) == 8...17)
        #expect(DayActivityBySourceView.axisHours([]) == nil)
        let onTheHour = DayPlanDetail.activitySittings(DayPlanDetail.activityGroups([
            DayActivity(id: "c", dayPlanID: "d", startMinute: 9 * 60, endMinute: 9 * 60 + 5, kind: .reading, targetID: "u", title: "U"),
        ]))
        #expect(DayActivityBySourceView.axisHours(onTheHour) == 9...10)
        #expect(DayActivityBySourceView.labelStride(pointsPerHour: 120) == 1)
        #expect(DayActivityBySourceView.labelStride(pointsPerHour: 30) == 2)
        #expect(DayActivityBySourceView.labelStride(pointsPerHour: 12) == 4)
        #expect(DayActivityBySourceView.titleWidth(for: 300) == 150)
        #expect(DayActivityBySourceView.titleWidth(for: 1800) == 340)
    }

    @Test("Log spans that overlap sit in separate lane columns; a later span takes the first free one")
    func activityColumns() {
        let reading = DayActivity(id: "a", dayPlanID: "2026-09-09", startMinute: 600, endMinute: 660, kind: .reading, targetID: "src", title: "Atlas")
        let chat = DayActivity(id: "b", dayPlanID: "2026-09-09", startMinute: 620, endMinute: 640, kind: .chat, targetID: "chat", title: "About the atlas")
        let doc = DayActivity(id: "c", dayPlanID: "2026-09-09", startMinute: 630, endMinute: 700, kind: .doc, targetID: "doc", title: "Notes")
        let later = DayActivity(id: "d", dayPlanID: "2026-09-09", startMinute: 660, endMinute: 720, kind: .reading, targetID: "src2", title: "Next")
        let columns = DayPlanDetail.activityColumns([later, doc, chat, reading])
        #expect(columns == ["a": 0, "b": 1, "c": 2, "d": 0])
        #expect(DayPlanDetail.activityColumns([] as [DayActivity]).isEmpty)
    }

    @Test("A short span holds its column for as long as its card is drawn, so the next card does not land on it")
    func activityColumnsMinimumMinutes() {
        // 2026-09-10: a three-minute video and the chat that followed it at 19:00.
        let reading = DayActivity(id: "r", dayPlanID: "2026-09-10", startMinute: 1129, endMinute: 1140, kind: .reading, targetID: "src", title: "Overview")
        let video = DayActivity(id: "v", dayPlanID: "2026-09-10", startMinute: 1130, endMinute: 1133, kind: .watching, targetID: "vid", title: "Rutter 2")
        let chat = DayActivity(id: "c", dayPlanID: "2026-09-10", startMinute: 1133, endMinute: 1140, kind: .chat, targetID: "chat", title: "Rutter")
        #expect(DayPlanDetail.activityColumns([reading, video, chat]) == ["r": 0, "v": 1, "c": 1])
        #expect(DayPlanDetail.activityColumns([reading, video, chat], minimumMinutes: 14) == ["r": 0, "v": 1, "c": 2])
        // Column counts are per overlap cluster: a lone span elsewhere keeps the whole lane.
        let lone = DayActivity(id: "l", dayPlanID: "2026-09-10", startMinute: 900, endMinute: 930, kind: .reading, targetID: "x", title: "Lone")
        let layout = DayPlanDetail.activityLayout(placing: [reading, video, chat, lone].map { ($0.id, $0.startMinute, $0.endMinute) }, minimumMinutes: 14)
        #expect(layout["l"].map { [$0.column, $0.columnCount] } == [0, 1])
        #expect(layout["r"].map { [$0.column, $0.columnCount] } == [0, 3])
        #expect(layout["c"].map { [$0.column, $0.columnCount] } == [2, 3])
        // A span whose minimum extent bridges into the next one joins its cluster.
        let bridged = DayPlanDetail.activityLayout(placing: [("a", 600, 603), ("b", 610, 640)], minimumMinutes: 14)
        #expect(bridged["a"].map { [$0.column, $0.columnCount] } == [0, 2])
        #expect(DayPlanDetail.activityLayout(placing: [("a", 600, 603), ("b", 610, 640)])["b"].map { [$0.column, $0.columnCount] } == [0, 1])
    }

    /// The evening of 2026-09-10 as the production log recorded it, trimmed.
    private static let september10: [DayActivity] = [
        DayActivity(id: "s1", dayPlanID: "2026-09-10", startMinute: 863, endMinute: 864, kind: .reading, targetID: "src_50ae", title: "Scalable workflows"),
        DayActivity(id: "c1", dayPlanID: "2026-09-10", startMinute: 883, endMinute: 902, kind: .chat, targetID: "chat_overview", title: "Overview of methods that determine mito"),
        DayActivity(id: "c2", dayPlanID: "2026-09-10", startMinute: 925, endMinute: 929, kind: .chat, targetID: "chat_overview", title: "Overview of methods that determine mito"),
        DayActivity(id: "m1", dayPlanID: "2026-09-10", startMinute: 933, endMinute: 951, kind: .reading, targetID: "src_0837", title: "MRI is a bioelectric mapping device"),
        DayActivity(id: "m2", dayPlanID: "2026-09-10", startMinute: 970, endMinute: 984, kind: .reading, targetID: "src_0837", title: "MRI is a bioelectric mapping device"),
        DayActivity(id: "b1", dayPlanID: "2026-09-10", startMinute: 989, endMinute: 990, kind: .chat, targetID: "chat_browser", title: "can you use the browser"),
        DayActivity(id: "o1", dayPlanID: "2026-09-10", startMinute: 1129, endMinute: 1140, kind: .reading, targetID: "src_59cc", title: "Overview of methods that determine mitochondrial membrane potential"),
        DayActivity(id: "v1", dayPlanID: "2026-09-10", startMinute: 1130, endMinute: 1133, kind: .watching, targetID: "src_6268", title: "Jared Rutter 2"),
        DayActivity(id: "r1", dayPlanID: "2026-09-10", startMinute: 1133, endMinute: 1140, kind: .chat, targetID: "chat_rutter", title: "Rutter on Mitochondrial Metabolism"),
        DayActivity(id: "o2", dayPlanID: "2026-09-10", startMinute: 1163, endMinute: 1167, kind: .reading, targetID: "src_59cc", title: "Overview of methods that determine mitochondrial membrane potential"),
        DayActivity(id: "o3", dayPlanID: "2026-09-10", startMinute: 1239, endMinute: 1250, kind: .reading, targetID: "src_59cc", title: "Overview of methods that determine mitochondrial membrane potential"),
    ]

    @Test("The log groups by thing: a chat about one source joins the source, glances fold, longest first")
    func activityGroups() {
        let groups = DayPlanDetail.activityGroups(Self.september10, chatSources: [
            "chat_overview": ["src_59cc"],
            "chat_rutter": ["src_6268", "src_bd27"],
        ])
        #expect(groups.map(\.id) == ["source/src_59cc", "source/src_0837", "chat/chat_rutter", "source/src_6268", "source/src_50ae", "chat/chat_browser"])
        let overview = groups[0]
        #expect(overview.kind == .reading)
        #expect(overview.targetID == "src_59cc")
        #expect(overview.title == "Overview of methods that determine mitochondrial membrane potential", "the source's own title wins over the chat's")
        #expect(overview.minutesByKind == [.reading: 26, .chat: 23])
        #expect(overview.totalMinutes == 49)
        #expect(overview.startMinute == 883 && overview.endMinute == 1250)
        #expect(!overview.isGlance)
        // Two chat turns 23 minutes apart are one sitting; the paper at 18:49 is another; 20:39 a third.
        #expect(overview.sittings.map { [$0.startMinute, $0.endMinute] } == [[883, 929], [1129, 1167], [1239, 1250]])
        #expect(overview.sittings[0].kind == .chat)
        #expect(overview.sittings[1].kind == .reading)
        #expect(overview.sittings[0].loggedMinutes == 23 && overview.sittings[0].durationMinutes == 46)
        #expect(overview.sittings[0].id == "source/src_59cc@883")
        // A chat about two sources stays a chat; the video it followed is its own thing.
        #expect(groups[2].kind == .chat && groups[2].targetID == "chat_rutter")
        #expect(groups[3].kind == .watching && groups[3].title == "Jared Rutter 2")
        // The two one-minute things are glances and leave the lane.
        #expect(groups.filter(\.isGlance).map(\.id) == ["source/src_50ae", "chat/chat_browser"])
        #expect(DayPlanDetail.activitySittings(groups).map(\.id) == [
            "source/src_59cc@883", "source/src_0837@933", "source/src_59cc@1129", "source/src_6268@1130", "chat/chat_rutter@1133", "source/src_59cc@1239",
        ])
        #expect(DayPlanDetail.activityGroups([]).isEmpty)
        // Without the chat's sources the chat is its own thing, titled from the chat.
        let unlinked = DayPlanDetail.activityGroups(Self.september10)
        #expect(unlinked.map(\.id).prefix(2) == ["source/src_0837", "source/src_59cc"])
        #expect(unlinked.first { $0.id == "chat/chat_overview" }?.title == "Overview of methods that determine mito")
    }

    @Test("A span reads under the name its thing carries now; a thing that is gone keeps the stored name")
    func resolvingCurrentTitles() {
        let spans = [
            DayActivity(id: "a", dayPlanID: "d", startMinute: 600, endMinute: 640, kind: .reading, targetID: "src_1", title: "file:///Users/x/Downloads/d41586.pdf"),
            DayActivity(id: "b", dayPlanID: "d", startMinute: 610, endMinute: 620, kind: .chat, targetID: "chat_1", title: "New chat"),
            DayActivity(id: "c", dayPlanID: "d", startMinute: 700, endMinute: 720, kind: .doc, targetID: "doc_1", title: "Untitled"),
            DayActivity(id: "d", dayPlanID: "d", startMinute: 800, endMinute: 810, kind: .watching, targetID: "src_gone", title: "A video since deleted"),
        ]
        let resolved = DayPlanDetail.resolvingCurrentTitles(spans, currentTitles: [
            "source/src_1": "When Fat Stops Protecting",
            "chat/chat_1": "Caloric restriction and somatic mutation",
            "doc/doc_1": "  The Landscape of Mitochondrial Therapeutics  ",
            "source/src_other": "Not in this day",
        ])
        #expect(resolved.map(\.title) == [
            "When Fat Stops Protecting",
            "Caloric restriction and somatic mutation",
            "The Landscape of Mitochondrial Therapeutics",
            "A video since deleted",
        ])
        // Nothing else about a span moves, and an empty name is not a rename.
        #expect(resolved.map(\.id) == spans.map(\.id))
        #expect(DayPlanDetail.resolvingCurrentTitles(spans, currentTitles: [:]) == spans)
        #expect(DayPlanDetail.resolvingCurrentTitles(spans, currentTitles: ["source/src_1": "   "]) == spans)
    }

    @Test("A sitting with a gap keeps its spans, so the lane can band the minutes actually logged")
    func sittingSpans() {
        let groups = DayPlanDetail.activityGroups(Self.september10)
        let mri = groups.first { $0.id == "source/src_0837" }!
        #expect(mri.sittings.count == 1)
        #expect(mri.sittings[0].spans.map(\.id) == ["m1", "m2"])
        #expect(mri.sittings[0].loggedMinutes == 32 && mri.sittings[0].durationMinutes == 51)
        // 31 minutes of silence is a new sitting.
        let apart = DayPlanDetail.activityGroups([
            DayActivity(id: "x", dayPlanID: "d", startMinute: 600, endMinute: 610, kind: .reading, targetID: "s", title: "S"),
            DayActivity(id: "y", dayPlanID: "d", startMinute: 641, endMinute: 650, kind: .reading, targetID: "s", title: "S"),
        ])
        #expect(apart[0].sittings.count == 2)
    }

    @Test("The What you did row and the lane card say the minutes by kind, the sittings and the span")
    func groupAndSittingSummaries() {
        let groups = DayPlanDetail.activityGroups(Self.september10, chatSources: ["chat_overview": ["src_59cc"]])
        let overview = groups[0]
        #expect(DayActivityText.groupSummary(overview) == "Reading 26m · Chat 23m · 3 sittings · 14:43–20:50")
        let mri = groups.first { $0.id == "source/src_0837" }!
        #expect(DayActivityText.groupSummary(mri) == "Reading 32m · 15:33–16:24")
        #expect(DayActivityText.sittingSummary(mri.sittings[0]) == "Reading · 15:33–16:24 · 32m")
        #expect(DayActivityText.sittingSummary(overview.sittings[0]) == "Chat · 14:43–15:29 · 23m")
        let mixed = DayPlanDetail.activityGroups([
            DayActivity(id: "a", dayPlanID: "d", startMinute: 1129, endMinute: 1140, kind: .reading, targetID: "s", title: "S"),
            DayActivity(id: "b", dayPlanID: "d", startMinute: 1133, endMinute: 1140, kind: .chat, targetID: "c", title: "C"),
        ], chatSources: ["c": ["s"]])
        #expect(DayActivityText.sittingSummary(mixed[0].sittings[0]) == "Reading 11m · Chat 7m · 18:49–19:00")
        #expect(DayActivityText.glancesSummary(groups) == "2 glances under 2 minutes")
        #expect(DayActivityText.glancesSummary(Array(groups.prefix(1))) == nil)
        #expect(DayActivityText.glancesSummary(groups.filter { $0.id == "chat/chat_browser" }) == "1 glance under 2 minutes")
    }

    @Test("The logged line names each kind with time, in lane order, and is absent when nothing was logged")
    func loggedSummary() {
        let plan = DayPlan(date: "2026-09-09")
        let empty = DayPlanDetail(plan: plan, blocks: [])
        #expect(DayActivityText.loggedSummary(empty) == nil)
        let detail = DayPlanDetail(plan: plan, blocks: [], activities: [
            DayActivity(dayPlanID: plan.id, startMinute: 900, endMinute: 925, kind: .chat, targetID: "chat", title: "Q"),
            DayActivity(dayPlanID: plan.id, startMinute: 600, endMinute: 660, kind: .reading, targetID: "a", title: "A"),
            DayActivity(dayPlanID: plan.id, startMinute: 700, endMinute: 740, kind: .reading, targetID: "b", title: "B"),
        ])
        #expect(detail.loggedMinutesByKind == [.reading: 100, .chat: 25])
        #expect(DayActivityText.loggedSummary(detail) == "Reading 1h 40m · Chat 25m")
        // The lane widens the hours the clock opens on the way blocks do.
        #expect(detail.focusHourRange() == 7...19)
        let late = DayPlanDetail(plan: plan, blocks: [], activities: [
            DayActivity(dayPlanID: plan.id, startMinute: 21 * 60 + 10, endMinute: 21 * 60 + 40, kind: .doc, targetID: "d", title: "D"),
        ])
        #expect(late.focusHourRange() == 7...22)
    }

    @Test("An observation continues a span within the merge gap and links back to what it saw")
    func activityContinuation() {
        let span = DayActivity(dayPlanID: "2026-09-09", startMinute: 600, endMinute: 630, kind: .reading, targetID: "src-1", title: "Atlas")
        #expect(span.continues(atMinute: 629))
        #expect(span.continues(atMinute: 630 + DayPlan.activityMergeGapMinutes))
        #expect(!span.continues(atMinute: 630 + DayPlan.activityMergeGapMinutes + 1))
        #expect(!span.continues(atMinute: 599), "a span never grows backwards")
        #expect(span.link == "foreverlm://source/src-1")
        #expect(DayActivity(dayPlanID: "2026-09-09", startMinute: 0, endMinute: 1, kind: .chat, targetID: "chat 1", title: "").link == "foreverlm://chat/chat%201")
        #expect(DayActivity(dayPlanID: "2026-09-09", startMinute: 0, endMinute: 1, kind: .doc, targetID: "doc-1", title: "").link == "foreverlm://doc/doc-1")
    }

    @Test("Clock strings and dates parse both ways")
    func clockAndDateParsing() {
        #expect(DayPlan.minute(fromClock: "09:30") == 570)
        #expect(DayPlan.minute(fromClock: "9:05") == 545)
        #expect(DayPlan.minute(fromClock: "24:00") == 1440)
        #expect(DayPlan.minute(fromClock: "24:01") == nil)
        #expect(DayPlan.minute(fromClock: "930") == nil)
        #expect(DayPlan.minute(fromClock: "morning") == nil)
        #expect(DayPlan.clockString(minute: 570) == "09:30")
        #expect(DayPlan.clockString(minute: 1440) == "24:00")
        #expect(DayPlan.isValidDateString("2026-09-09"))
        #expect(!DayPlan.isValidDateString("2026-02-30"))
        #expect(!DayPlan.isValidDateString("09/09/2026"))
        #expect(DayPlan.dateString("2026-09-30", offsetBy: 1) == "2026-10-01")
        #expect(DayPlan.dateString("2026-01-01", offsetBy: -1) == "2025-12-31")
    }

    @Test("A tombstone, or a row an older build left behind in a column, is not part of the day's plan")
    func legacyColumnRowsAreNotCurrent() {
        var left = TimeBlock(dayPlanID: "2026-09-09", startMinute: 540, endMinute: 630, title: "Write", revision: 1)
        #expect(left.isCurrent)
        left.supersededInRevision = 2
        #expect(!left.isCurrent)
        var tombstoned = TimeBlock(dayPlanID: "2026-09-09", startMinute: 540, endMinute: 630, title: "Gone", revision: 2)
        tombstoned.deletedAt = Date()
        #expect(!tombstoned.isCurrent)
        let drawn = TimeBlock(dayPlanID: "2026-09-09", startMinute: 660, endMinute: 720, title: "Read", revision: 2)
        let detail = DayPlanDetail(plan: DayPlan(date: "2026-09-09", revision: 2), blocks: [left, tombstoned, drawn])
        #expect(detail.currentBlocks.map(\.id) == [drawn.id], "a day an older build redrew reads as its last column")
    }

    @Test("The day's minutes count every block not skipped, done ones once done; overdue needs an open block past its end plus grace")
    func metricsAndOverdue() {
        let plan = DayPlan(date: "2026-09-09")
        var deep = TimeBlock(dayPlanID: plan.id, startMinute: 540, endMinute: 660, title: "Deep")
        var shallow = TimeBlock(dayPlanID: plan.id, startMinute: 660, endMinute: 690, title: "Email")
        var detail = DayPlanDetail(plan: plan, blocks: [deep, shallow])
        #expect(detail.minutesPlanned == 150)
        #expect(detail.minutesDone == 0)
        deep.status = .done
        detail = DayPlanDetail(plan: plan, blocks: [deep, shallow])
        #expect(detail.minutesDone == 120)
        // A skipped block leaves the plan's count.
        shallow.status = .skipped
        detail = DayPlanDetail(plan: plan, blocks: [deep, shallow])
        #expect(detail.minutesPlanned == 120)
        shallow.status = .planned
        detail = DayPlanDetail(plan: plan, blocks: [deep, shallow])
        // Email ended at 11:30; at 11:35 it is merely running long, at 11:45 it is overdue.
        #expect(detail.overdueBlocks(atMinute: 695).isEmpty)
        #expect(detail.overdueBlocks(atMinute: 705).map(\.title) == ["Email"])
        #expect(detail.block(atMinute: 600)?.title == "Deep")
        #expect(detail.focusHourRange() == 7...19)
        let late = TimeBlock(dayPlanID: plan.id, startMinute: 20 * 60 + 30, endMinute: 22 * 60 + 15, title: "Late")
        #expect(DayPlanDetail(plan: plan, blocks: [late]).focusHourRange() == 7...23)
        // Whatever the day holds, the day itself has all of it.
        #expect(DayPlan.dayHourRange == 0...24)
    }

    @Test("The clock draws the learner's day window, widened to hold whatever the day contains")
    func clockHourRange() {
        let plan = DayPlan(date: "2026-09-21")
        // The window as set, six to midnight by default.
        #expect(DayPlanDetail.clockHourRange(dayStart: 6, dayEnd: 24) == 6...24)
        #expect(DayPlanDetail(plan: plan, blocks: []).clockHourRange(dayStart: 8, dayEnd: 22) == 8...22)
        // A block or a logged span outside the window widens the clock to hold it;
        // one inside leaves it alone.
        let early = TimeBlock(dayPlanID: plan.id, startMinute: 4 * 60 + 30, endMinute: 5 * 60 + 15, title: "Early")
        let inside = TimeBlock(dayPlanID: plan.id, startMinute: 9 * 60, endMinute: 10 * 60, title: "Nine")
        #expect(DayPlanDetail(plan: plan, blocks: [inside]).clockHourRange(dayStart: 6, dayEnd: 22) == 6...22)
        #expect(DayPlanDetail(plan: plan, blocks: [early, inside]).clockHourRange(dayStart: 6, dayEnd: 22) == 4...22)
        var gone = early
        gone.deletedAt = Date()
        #expect(DayPlanDetail(plan: plan, blocks: [gone, inside]).clockHourRange(dayStart: 6, dayEnd: 22) == 6...22)
        let late = DayPlanDetail(plan: plan, blocks: [], activities: [
            DayActivity(dayPlanID: plan.id, startMinute: 22 * 60 + 10, endMinute: 22 * 60 + 40, kind: .doc, targetID: "d", title: "D"),
        ])
        #expect(late.clockHourRange(dayStart: 6, dayEnd: 22) == 6...23)
        // Ends out of order, or off the day, are put right rather than trusted.
        #expect(DayPlanDetail.clockHourRange(dayStart: 22, dayEnd: 6) == 22...23)
        #expect(DayPlanDetail.clockHourRange(dayStart: -3, dayEnd: 30) == 0...24)
        #expect(PlannerDayHours.ordered(start: 23, end: 23) == 23...24)
        // What the setter and the pane refuse.
        #expect(PlannerDayHours.validationMessage(start: 6, end: 24) == nil)
        #expect(PlannerDayHours.validationMessage(start: 24, end: nil) != nil)
        #expect(PlannerDayHours.validationMessage(start: nil, end: 0) != nil)
        #expect(PlannerDayHours.validationMessage(start: 10, end: 10) != nil)
    }

    @Test("A block over by more than its own length was left open, not run long, and that is when Done and Skipped replace fifteen more minutes")
    func wasLeftOpen() {
        // The product owner's 2026-09-20 panel: a fifteen-minute Memory review at "55m over".
        let review = TimeBlock(dayPlanID: "2026-09-20", startMinute: 600, endMinute: 615, title: "Memory review")
        #expect(!review.wasLeftOpen(atMinute: 614), "still inside the block")
        #expect(!review.wasLeftOpen(atMinute: 630), "fifteen minutes over a fifteen-minute block is running long")
        #expect(review.wasLeftOpen(atMinute: 631), "a minute more than its own length: it did not happen")
        #expect(review.wasLeftOpen(atMinute: 670), "55m over")
        var done = review
        done.status = .done
        #expect(!done.wasLeftOpen(atMinute: 670), "a closed block was answered for")
        var skipped = review
        skipped.status = .skipped
        #expect(!skipped.wasLeftOpen(atMinute: 670))
        var replaced = review
        replaced.deletedAt = Date()
        #expect(!replaced.wasLeftOpen(atMinute: 670), "a replaced row is not on the clock")
        // A two-hour block at forty minutes over is running long; at two hours and one minute it was left.
        let deep = TimeBlock(dayPlanID: "2026-09-20", startMinute: 540, endMinute: 660, title: "Deep")
        #expect(!deep.wasLeftOpen(atMinute: 700))
        #expect(deep.wasLeftOpen(atMinute: 781))
    }

    @Test("The card's word for an open block follows the hour: nothing inside the grace, running long inside its own length, not closed out past it or once the day is shut")
    func openNote() {
        // The product owner (2026-09-20): two afternoon blocks still read "Running late" at ten in the evening.
        let tca = TimeBlock(dayPlanID: "2026-09-20", startMinute: 810, endMinute: 870, title: "TCA cycle measurements")
        #expect(tca.openNote(nowMinute: 879, dayIsShut: false) == nil, "nine minutes over is the grace")
        #expect(tca.openNote(nowMinute: 880, dayIsShut: false) == .runningLong(minutesOver: 10))
        #expect(tca.openNote(nowMinute: 895, dayIsShut: false)?.text == "Running long · 25m over")
        #expect(tca.openNote(nowMinute: 930, dayIsShut: false) == .runningLong(minutesOver: 60), "an hour over a one-hour block is still running long")
        #expect(tca.openNote(nowMinute: 931, dayIsShut: false) == .leftOpen(endMinute: 870), "a minute more than its own length: it did not happen")
        #expect(tca.openNote(nowMinute: 1335, dayIsShut: false)?.text == "Not closed out · ended 14:30")
        #expect(tca.openNote(nowMinute: 1335, dayIsShut: false)?.isRunningLong == false, "a question, not an alarm")
        // Once the day is shut nothing is running: a block that has begun is left open at once, one not yet begun says nothing.
        #expect(tca.openNote(nowMinute: 850, dayIsShut: true) == .leftOpen(endMinute: 870))
        #expect(tca.openNote(nowMinute: 800, dayIsShut: true) == nil)
        var done = tca
        done.status = .done
        #expect(done.openNote(nowMinute: 1335, dayIsShut: true) == nil, "a closed block was answered for")
        var replaced = tca
        replaced.deletedAt = Date()
        #expect(replaced.openNote(nowMinute: 1335, dayIsShut: false) == nil, "a replaced row is not on the clock")
        // A two-hour block an hour and five over is running long, said in hours.
        let deep = TimeBlock(dayPlanID: "2026-09-20", startMinute: 960, endMinute: 1080, title: "Grant writing")
        #expect(deep.openNote(nowMinute: 1145, dayIsShut: false)?.text == "Running long · 1h 5m over")
    }

    @Test("What is left of a day is every stretch no current block holds, from a minute to the day's end")
    func freeStretchesFromNow() throws {
        let date = "2026-09-29"
        let reading = TimeBlock(id: "reading", dayPlanID: date, startMinute: 1080, endMinute: 1110, title: "Read Picard")
        let talk = TimeBlock(id: "talk", dayPlanID: date, startMinute: 1200, endMinute: 1260, title: "Talk", calendarEventID: "google:x/1")
        // A calendar block over the talk's end: the cursor moves past both.
        let dinner = TimeBlock(id: "dinner", dayPlanID: date, startMinute: 1230, endMinute: 1290, title: "Dinner", calendarEventID: "google:x/2")
        let tight = TimeBlock(id: "tight", dayPlanID: date, startMinute: 1300, endMinute: 1320, title: "Call")
        var gone = TimeBlock(id: "gone", dayPlanID: date, startMinute: 1320, endMinute: 1400, title: "Deleted")
        gone.deletedAt = Date()
        let all = [talk, reading, dinner, tight, gone]

        // From inside a block: the free time starts where it ends; ten
        // minutes between Dinner and the call is less than a quarter hour.
        #expect(DayPlan.freeStretches(from: 1090, to: 1440, among: all) == [1110..<1200, 1320..<1440])
        #expect(DayPlan.freeStretches(from: 1090, to: 1440, among: all, minimumMinutes: 5) == [1110..<1200, 1290..<1300, 1320..<1440])
        // Cut at the day's end, and nothing once the day is over.
        #expect(DayPlan.freeStretches(from: 1090, to: 1260, among: all) == [1110..<1200])
        #expect(DayPlan.freeStretches(from: 1440, to: 1440, among: all).isEmpty)
        #expect(DayPlan.freeStretches(from: 1100, to: 1080, among: all).isEmpty)
    }

    @Test("A log span seen within the reader's batch of the clock is still going; one older is over")
    func ongoingSpan() {
        let span = DayActivity(dayPlanID: "2026-09-29", startMinute: 1077, endMinute: 1091, kind: .reading, targetID: "src", title: "Picard")
        // Stored ends are exclusive: seen during 18:10, the span ends at 18:11.
        #expect(span.isOngoing(atMinute: 1090))
        #expect(span.isOngoing(atMinute: 1093), "the reader writes its time every two minutes")
        #expect(!span.isOngoing(atMinute: 1094))
        #expect(!span.isOngoing(atMinute: 1070), "a span that has not begun is not going")
    }

    @Test("The free time of a day is read around a minute, forward from one, and as the nearest start for a length")
    func freeTime() throws {
        let date = "2026-09-19"
        let read = TimeBlock(id: "read", dayPlanID: date, startMinute: 540, endMinute: 600, title: "Read")
        let standup = TimeBlock(id: "standup", dayPlanID: date, startMinute: 660, endMinute: 720, title: "Standup")
        var gone = TimeBlock(id: "gone", dayPlanID: date, startMinute: 600, endMinute: 660, title: "Deleted")
        gone.deletedAt = Date()
        let all = [read, standup, gone]

        // Around a minute: the gap it is in; a deleted row is no wall.
        #expect(DayPlan.freeStretch(around: 630, among: all) == 600...660)
        #expect(DayPlan.freeStretch(around: 100, among: all) == 0...540)
        #expect(DayPlan.freeStretch(around: 900, among: all) == 720...1440)
        #expect(DayPlan.freeStretch(around: 570, among: all) == nil)
        // The moment a block ends is free; the moment it starts is not.
        #expect(DayPlan.freeStretch(around: 600, among: all) == 600...660)
        #expect(DayPlan.freeStretch(around: 660, among: all) == nil)
        // Forward from a minute: pushed past the block that holds it.
        #expect(DayPlan.firstFreeStretch(from: 570, among: all) == 600...660)
        #expect(DayPlan.firstFreeStretch(from: 630, among: all) == 630...660)
        #expect(DayPlan.firstFreeStretch(from: 1439, among: all) == nil)
        // A gap too small to hold the minimum block is skipped.
        let tight = TimeBlock(id: "tight", dayPlanID: date, startMinute: 603, endMinute: 660, title: "Tight")
        #expect(DayPlan.firstFreeStretch(from: 570, among: [read, tight, standup]) == 720...1440)

        // The nearest start for a length: ties go to the earlier one.
        #expect(DayPlan.nearestFreeStart(forDuration: 60, near: 630, among: all) == 600)
        #expect(DayPlan.nearestFreeStart(forDuration: 30, near: 630, among: all) == 630)
        #expect(DayPlan.nearestFreeStart(forDuration: 90, near: 630, among: all) == 720)
        #expect(DayPlan.nearestFreeStart(forDuration: 60, near: 690, among: all) == 720)
        // Nothing that long anywhere: nil.
        let day = TimeBlock(id: "day", dayPlanID: date, startMinute: 0, endMinute: 1400, title: "All day")
        #expect(DayPlan.nearestFreeStart(forDuration: 60, near: 700, among: [day]) == nil)
        #expect(DayPlan.nearestFreeStart(forDuration: 30, near: 700, among: [day]) == 1400)
    }

    // MARK: - Storage

    @Test("Schema 128 gives a calendar block's import-written notes to the location column and leaves the learner's notes alone")
    func locationColumnMigratesFromSchema127() throws {
        let root = temporaryRoot("DayPlanLocationMigration")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = "2026-09-20"
        let meetingID: String, seriesID: String, handID: String, roomID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            // Build 127's import wrote the Meet link, or the room, into the notes.
            let meeting = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 540, endMinute: 615, title: "Acme Longevity Nexus", notes: "https://meet.google.com/aaa-bbbb-ccc", calendarEventID: "google:primary/nexus", calendarEventURL: "https://calendar.google.com/event?eid=1"))
            let room = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 800, endMinute: 830, title: "Dentist", notes: "Main St", calendarEventID: "apple:CAL-1/EV-1"))
            // A meeting series' occurrence and a hand-drawn block: the notes are the learner's.
            let series = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 660, endMinute: 675, title: "Standup", notes: "Ask about the atlas", calendarEventID: "meeting:zoom:examplefellowship.zoom.us/2026-09-20"))
            let hand = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 720, endMinute: 780, title: "Write", notes: "Section 2"))
            (meetingID, seriesID, handID, roomID) = (meeting.id, series.id, hand.id, room.id)
            // Back to the exact shape build 127 (schema 127) wrote: no location column.
            try store.execForTesting("DROP VIEW IF EXISTS source_projection")
            try store.execForTesting("ALTER TABLE time_blocks DROP COLUMN location")
            try store.execForTesting("PRAGMA user_version = 127")
        }

        let migrated = try KnowledgeStore(storeDirectory: root)
        var version: Int32 = 0
        try migrated.query("PRAGMA user_version") { stmt in version = sqlite3_column_int(stmt, 0) }
        #expect(version == KnowledgeStore.schemaVersion)
        let detail = try #require(try migrated.loadDayPlan(date))
        let byID = Dictionary(uniqueKeysWithValues: detail.blocks.map { ($0.id, $0) })
        #expect(byID[meetingID]?.location == "https://meet.google.com/aaa-bbbb-ccc")
        #expect(byID[meetingID]?.notes == nil, "the notes fall free for what to bring up")
        #expect(byID[meetingID]?.links.map(\.label) == ["Join Google Meet"])
        #expect(byID[roomID]?.location == "Main St" && byID[roomID]?.locationText == "Main St" && byID[roomID]?.notes == nil)
        #expect(byID[seriesID]?.notes == "Ask about the atlas" && byID[seriesID]?.location == nil, "a series' notes were never the import's")
        #expect(byID[handID]?.notes == "Section 2" && byID[handID]?.location == nil)

        // The column works at once, and a block reads back what was written.
        var placed = try #require(byID[handID])
        placed.location = "Room 4.12"
        _ = try migrated.updateTimeBlock(placed)
        #expect(try migrated.loadDayPlan(date)?.blocks.first { $0.id == handID }?.location == "Room 4.12")
    }

    @Test("A day has one plan: every edit lands on the block's own row, and a delete tombstones it")
    func editsLandInPlace() throws {
        let root = temporaryRoot("DayPlanInPlace")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-09"

        let first = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 540, endMinute: 630, title: "Write the intro"))
        var detail = try #require(try store.loadDayPlan(date))
        #expect(detail.currentBlocks.map(\.id) == [first.id])

        // How it went, and what and when it is, all land on the one row.
        var done = first
        done.status = .done
        let stillFirst = try store.updateTimeBlock(done)
        #expect(stillFirst.id == first.id && stillFirst.status == .done)
        var moved = stillFirst
        moved.startMinute = 600
        moved.endMinute = 690
        moved.title = "Write the intro, again"
        moved.sourceIDs = ["src-intro"]
        let edited = try store.updateTimeBlock(moved)
        #expect(edited.id == first.id)
        detail = try #require(try store.loadDayPlan(date))
        #expect(detail.blocks.count == 1, "an edit draws no second row")
        #expect(detail.currentBlocks.first?.startMinute == 600)
        #expect(detail.currentBlocks.first?.title == "Write the intro, again")
        #expect(detail.currentBlocks.first?.status == .done)
        #expect(detail.plan.revision == 1, "nothing opens a column")

        // A delete tombstones the row, and a deleted block takes no edit.
        try store.deleteTimeBlock(first.id)
        detail = try #require(try store.loadDayPlan(date))
        #expect(detail.currentBlocks.isEmpty)
        #expect(detail.blocks.count == 1)
        #expect(detail.blocks.first?.deletedAt != nil && detail.blocks.first?.supersededInRevision == nil)
        #expect(throws: (any Error).self) {
            _ = try store.updateTimeBlock(edited)
        }
    }

    @Test("A day an older build redrew reads as its last column, and edits there land in place")
    func legacyRedrawnDayEditsInPlace() throws {
        let root = temporaryRoot("DayPlanLegacyColumns")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-09"
        let now = Date()
        // As a build that drew columns left the day: redrawn into column 2,
        // the morning's review left behind in column 1, an afternoon block
        // drawn in column 2.
        let review = TimeBlock(dayPlanID: date, startMinute: 540, endMinute: 555, title: "Memory review", revision: 1, supersededInRevision: 2, createdAt: now, updatedAt: now)
        let afternoon = TimeBlock(dayPlanID: date, startMinute: 840, endMinute: 930, title: "Read", revision: 2, createdAt: now, updatedAt: now)
        try store.saveDayPlanRecord(CloudKitDayPlanPayload(plan: DayPlan(date: date, revision: 2, createdAt: now, updatedAt: now), blocks: [review, afternoon]))
        var detail = try #require(try store.loadDayPlan(date))
        #expect(detail.currentBlocks.map(\.id) == [afternoon.id])

        var later = afternoon
        later.startMinute = 900
        later.endMinute = 990
        #expect(try store.updateTimeBlock(later).id == afternoon.id)
        let evening = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 1020, endMinute: 1080, title: "Write"))
        #expect(evening.revision == 2, "stamped with the day's column, so the older build shows it too")
        _ = try store.reviseDayPlan(date, replacing: [afternoon.id], replacements: [
            TimeBlock(dayPlanID: date, startMinute: 900, endMinute: 960, title: "Read, shorter"),
        ])
        detail = try #require(try store.loadDayPlan(date))
        #expect(detail.plan.revision == 2)
        #expect(detail.currentBlocks.map(\.title) == ["Read, shorter", "Write"])
        #expect(detail.blocks.first { $0.id == review.id }?.supersededInRevision == 2, "the older build's row is left as it was")
        #expect(detail.blocks.first { $0.id == afternoon.id }?.deletedAt != nil)
    }

    @Test("A redraw carrying a block's id moves that block in place, however the moves overlap on the way")
    func redrawRewritesCarriedBlocksInPlace() throws {
        let root = temporaryRoot("DayPlanRedrawInPlace")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-09"
        let deep = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 540, endMinute: 600, title: "Deep", sourceIDs: ["src-a"]))
        let email = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 600, endMinute: 630, title: "Email"))
        // Extend's shape: the first block grows over the second's old hour,
        // and the second moves on. Written one at a time, the first would be
        // refused for overlapping the second.
        var longer = deep
        longer.endMinute = 630
        var pushed = email
        pushed.startMinute = 630
        pushed.endMinute = 660
        let detail = try store.reviseDayPlan(date, replacing: [deep.id, email.id], replacements: [longer, pushed])
        #expect(detail.blocks.count == 2, "moved, not replaced: no tombstones and no new rows")
        #expect(detail.currentBlocks.map(\.id) == [deep.id, email.id])
        #expect(detail.currentBlocks.map(\.endMinute) == [630, 660])
        #expect(detail.currentBlocks.first?.sourceIDs == ["src-a"])
        #expect(detail.currentBlocks.first?.createdAt == deep.createdAt)
        // A draft over a kept block is still refused whole.
        var over = longer
        over.endMinute = 700
        #expect(throws: KnowledgeStoreError.self) {
            _ = try store.reviseDayPlan(date, replacing: [deep.id], replacements: [over])
        }
        #expect(try store.loadTimeBlock(deep.id)?.endMinute == 630)
    }

    @Test("No two blocks share a minute: the store refuses a block drawn, moved or redrawn over another, and a calendar block is never refused")
    func storeRefusesOverlaps() throws {
        let root = temporaryRoot("DayPlanOverlaps")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-19"

        let read = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 540, endMinute: 630, title: "Read"))
        // Drawn over it: refused, naming what is in the way; nothing written.
        let refused = #expect(throws: KnowledgeStoreError.self) {
            _ = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 600, endMinute: 660, title: "Email"))
        }
        if case .invalidData(let message)? = refused {
            #expect(message.contains("‘Email’ 10:00–11:00 overlaps ‘Read’ 09:00–10:30"))
        } else {
            Issue.record("expected invalidData, got \(String(describing: refused))")
        }
        #expect(try store.loadDayPlan(date)?.currentBlocks.count == 1)
        // Touching is not overlapping.
        let email = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 630, endMinute: 660, title: "Email"))

        // Moved onto the other: refused; the block stays where it was.
        var moved = email
        moved.startMinute = 600
        moved.endMinute = 630
        #expect(throws: KnowledgeStoreError.self) { _ = try store.updateTimeBlock(moved) }
        #expect(try store.loadTimeBlock(email.id)?.startMinute == 630)
        // A change that leaves the time alone is never refused, even on a
        // block that overlaps — here, the calendar's meeting laid over it.
        var meeting = TimeBlock(dayPlanID: date, startMinute: 600, endMinute: 645, title: "Call")
        meeting.calendarEventID = "google:primary/call"
        meeting = try store.addTimeBlock(meeting)
        var done = email
        done.status = .done
        #expect(try store.updateTimeBlock(done).status == .done)
        // The meeting itself moves where the calendar says.
        meeting.startMinute = 550
        meeting.endMinute = 640
        #expect(try store.updateTimeBlock(meeting).startMinute == 550)

        // A redraw with two drafts over one hour, or a draft over a kept
        // block, is refused whole: nothing is written.
        #expect(throws: KnowledgeStoreError.self) {
            _ = try store.reviseDayPlan(date, replacing: [read.id], replacements: [
                TimeBlock(dayPlanID: date, startMinute: 800, endMinute: 860, title: "One"),
                TimeBlock(dayPlanID: date, startMinute: 830, endMinute: 890, title: "Two"),
            ])
        }
        #expect(throws: KnowledgeStoreError.self) {
            _ = try store.reviseDayPlan(date, replacing: [read.id], replacements: [
                TimeBlock(dayPlanID: date, startMinute: 640, endMinute: 700, title: "Over the email"),
            ])
        }
        #expect(try store.loadTimeBlock(read.id)?.isCurrent == true, "a refused redraw replaces nothing")
        // Clear of everything — the meeting the calendar moved over the
        // reading's old hour included — the redraw lands.
        let detail = try store.reviseDayPlan(date, replacing: [read.id], replacements: [
            TimeBlock(dayPlanID: date, startMinute: 800, endMinute: 860, title: "Read again"),
        ])
        #expect(detail.plan.revision == 1, "a redraw opens no column")
        #expect(detail.currentBlocks.map(\.title).sorted() == ["Call", "Email", "Read again"])
        #expect(detail.blocks.first { $0.id == read.id }?.deletedAt != nil, "the replaced block is tombstoned")
    }

    @Test("Every planner write queues the day for sync and deleting the day tombstones it")
    func persistenceTracksSync() throws {
        let root = temporaryRoot("DayPlanSync")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-10"

        let block = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 480, endMinute: 600, title: "Read"))
        #expect(try store.pendingSyncChanges().contains { $0.entity == .dayPlan && $0.logicalKey == date && $0.operation == .save })
        try store.clearAllPendingSyncChanges()

        try store.setDayPlanNotes(date, notes: "  Ideas: revisit the atlas  ")
        #expect(try store.loadDayPlan(date)?.plan.notes == "Ideas: revisit the atlas")
        #expect(try store.pendingSyncChanges().contains { $0.entity == .dayPlan && $0.logicalKey == date })
        try store.clearAllPendingSyncChanges()

        try store.setDayPlanShutdown(date, at: Date())
        #expect(try store.loadDayPlan(date)?.plan.isShutDown == true)
        #expect(try store.pendingSyncChanges().contains { $0.entity == .dayPlan && $0.logicalKey == date })
        try store.clearAllPendingSyncChanges()

        _ = try store.reviseDayPlan(date, replacing: [block.id], replacements: [
            TimeBlock(dayPlanID: date, startMinute: 480, endMinute: 660, title: "Read, longer"),
        ])
        let revised = try #require(try store.loadDayPlan(date))
        #expect(revised.currentBlocks.map(\.title) == ["Read, longer"])
        #expect(try store.pendingSyncChanges().contains { $0.entity == .dayPlan && $0.logicalKey == date }, "a redraw queues the day")
        try store.clearAllPendingSyncChanges()

        try store.deleteDayPlan(date)
        #expect(try store.loadDayPlan(date) == nil)
        #expect(try store.pendingSyncChanges().contains { $0.entity == .dayPlan && $0.logicalKey == date && $0.operation == .delete })
    }

    @Test("The log reads back under the names the source, chat and Doc carry now")
    func logReadsCurrentTitles() throws {
        let root = temporaryRoot("DayPlanLogTitles")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-11"
        let midnight = try #require(DayPlan.startOfDay(date))
        func at(_ minute: Int) -> Date { midnight.addingTimeInterval(TimeInterval(minute * 60)) }

        // A paper saved from a download is seen under its file URL.
        var paper = StudioArticle(url: "file:///Users/x/Downloads/d41586-025-01234-5.pdf", title: "file:///Users/x/Downloads/d41586-025-01234-5.pdf", sourceType: .paper)
        try store.insertSourceIfNew(&paper)
        try store.createReviewSession(id: "chat_1", topic: "New chat", sourceIDs: [paper.id])
        let doc = ArtifactRecord(id: "doc_1", title: "Untitled", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: Date(), updatedAt: Date())
        try store.saveArtifactRecord(doc)

        _ = try store.recordDayActivity(kind: .reading, targetID: paper.id, title: paper.title, at: at(600))
        _ = try store.recordDayActivity(kind: .chat, targetID: "chat_1", title: "New chat", at: at(610))
        _ = try store.recordDayActivity(kind: .doc, targetID: "doc_1", title: "Untitled", at: at(700))
        _ = try store.recordDayActivity(kind: .watching, targetID: "src_gone", title: "A video since deleted", at: at(800))

        // All three are renamed afterwards; the log follows.
        paper.title = "Targeting Elevated Intracellular Sodium"
        try store.saveSource(paper)
        try store.updateReviewSessionTitle(sessionID: "chat_1", title: "Caloric restriction and somatic mutation")
        var renamedDoc = doc
        renamedDoc.title = "The Landscape of Mitochondrial Therapeutics"
        try store.saveArtifactRecord(renamedDoc)

        let detail = try #require(try store.loadDayPlan(date))
        #expect(detail.activities.map(\.title) == [
            "Targeting Elevated Intracellular Sodium",
            "Caloric restriction and somatic mutation",
            "The Landscape of Mitochondrial Therapeutics",
            "A video since deleted",
        ], "a thing that is gone keeps the name it was seen under")
        // The stored row is untouched — it is the fallback, not the display
        // name — and it is what travels to the other Macs.
        let payload = try #require(try store.loadDayPlanForSync(date))
        #expect(payload.activities.map(\.title).first == "file:///Users/x/Downloads/d41586-025-01234-5.pdf")
    }

    @Test("The log records what was seen a minute at a time, merges sittings, and rides with the day")
    func logRecordsAndMergesSpans() throws {
        let root = temporaryRoot("DayPlanLog")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-11"
        let midnight = try #require(DayPlan.startOfDay(date))
        func at(_ minute: Int, seconds: Int = 0) -> Date { midnight.addingTimeInterval(TimeInterval(minute * 60 + seconds)) }

        // The first observation makes the day and a one-minute span.
        let first = try #require(try store.recordDayActivity(kind: .reading, targetID: "src-atlas", title: "Atlas", at: at(600)))
        #expect(first.startMinute == 600 && first.endMinute == 601)
        #expect(try store.hasDayPlan(date))
        #expect(try store.pendingSyncChanges().contains { $0.entity == .dayPlan && $0.logicalKey == date })
        // A second look inside the same minute changes nothing.
        #expect(try store.recordDayActivity(kind: .reading, targetID: "src-atlas", title: "Atlas", at: at(600, seconds: 30)) == nil)
        // Heartbeats within the gap lengthen the same span.
        let grown = try #require(try store.recordDayActivity(kind: .reading, targetID: "src-atlas", title: "Atlas", at: at(603)))
        #expect(grown.id == first.id)
        #expect(grown.endMinute == 604)
        // A different thing at the same time is its own span.
        let chat = try #require(try store.recordDayActivity(kind: .chat, targetID: "chat-1", title: "About the atlas", at: at(602)))
        #expect(chat.id != first.id)
        // A silence longer than the gap starts a new sitting on the same source.
        let again = try #require(try store.recordDayActivity(kind: .reading, targetID: "src-atlas", title: "Atlas, renamed", at: at(604 + DayPlan.activityMergeGapMinutes + 1)))
        #expect(again.id != first.id)
        #expect(again.title == "Atlas, renamed")

        let detail = try #require(try store.loadDayPlan(date))
        #expect(detail.activities.map(\.id) == [first.id, chat.id, again.id], "by start time")
        #expect(detail.activities.first?.endMinute == 604)
        #expect(detail.currentBlocks.isEmpty, "nothing observed ever draws or completes a block")
        #expect(detail.loggedMinutesByKind == [.reading: 5, .chat: 1])

        // The log travels in the day's record and is removed with the day.
        let payload = try #require(try store.loadDayPlanForSync(date))
        #expect(payload.activities.count == 3)
        try store.deleteDayPlan(date)
        #expect(try store.loadDayPlan(date) == nil)

        #expect(throws: (any Error).self) {
            _ = try store.recordDayActivity(kind: .doc, targetID: "   ", title: "X", at: at(600))
        }
    }

    @Test("Invalid blocks are refused before anything is written")
    func validation() throws {
        let root = temporaryRoot("DayPlanValidation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(throws: (any Error).self) {
            _ = try store.addTimeBlock(TimeBlock(dayPlanID: "not-a-date", startMinute: 540, endMinute: 600, title: "X"))
        }
        #expect(throws: (any Error).self) {
            _ = try store.addTimeBlock(TimeBlock(dayPlanID: "2026-09-09", startMinute: 540, endMinute: 600, title: "   "))
        }
        #expect(try store.loadDayPlan("2026-09-09") == nil)
        // A backwards range is straightened to the minimum length, not refused.
        let short = try store.addTimeBlock(TimeBlock(dayPlanID: "2026-09-09", startMinute: 600, endMinute: 590, title: "Tiny"))
        #expect(short.endMinute == 605)
    }

    // MARK: - CloudKit

    @Test("A day round-trips through CloudKit with every column and every relationship")
    func cloudKitRoundTrip() throws {
        let senderRoot = temporaryRoot("DayPlanSender")
        let receiverRoot = temporaryRoot("DayPlanReceiver")
        defer {
            try? FileManager.default.removeItem(at: senderRoot)
            try? FileManager.default.removeItem(at: receiverRoot)
        }
        let sender = try KnowledgeStore(storeDirectory: senderRoot)
        let receiver = try KnowledgeStore(storeDirectory: receiverRoot)
        let date = "2026-09-11"

        let first = try sender.addTimeBlock(TimeBlock(
            dayPlanID: date, startMinute: 540, endMinute: 660, title: "Atlas draft",
            notes: "Section 2", notebookID: "notebook-mito", sourceIDs: ["src-atlas", "src-review"], purpose: .review,
            calendarEventID: "google:primary/evt-atlas", calendarEventURL: "https://calendar.google.com/event?eid=atlas"
        ))
        var moved = first
        moved.startMinute = 600
        moved.endMinute = 720
        _ = try sender.updateTimeBlock(moved)
        try sender.setDayPlanNotes(date, notes: "Shutdown: carry the figure to Friday")
        try sender.setDayPlanShutdown(date, at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let midnight = try #require(DayPlan.startOfDay(date))
        let logged = try #require(try sender.recordDayActivity(kind: .reading, targetID: "src-atlas", title: "Atlas", at: midnight.addingTimeInterval(600 * 60)))

        let payload = try #require(try sender.loadDayPlanForSync(date))
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: encoded)
        try receiver.saveDayPlanRecord(decoded)

        let landed = try #require(try receiver.loadDayPlan(date))
        #expect(landed.plan.revision == 1)
        #expect(landed.plan.notes == "Shutdown: carry the figure to Friday")
        #expect(landed.plan.isShutDown)
        // Every relationship field has to survive the trip, or the block lands
        // on the second Mac stripped of what makes it meaningful.
        let current = try #require(landed.currentBlocks.first)
        #expect(current.id == first.id)
        #expect(current.notebookID == "notebook-mito")
        #expect(current.sourceIDs == ["src-atlas", "src-review"])
        #expect(current.calendarEventID == "google:primary/evt-atlas", "the moved block keeps its event, and the event lands")
        #expect(current.calendarEventURL == "https://calendar.google.com/event?eid=atlas")
        #expect(current.notes == "Section 2")
        #expect(current.startMinute == 600 && current.endMinute == 720)
        // The one-source field older clients read carries the first source.
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(encodedText.contains("\"sourceID\":\"src-atlas\""))
        // The log's spans carry their own `kind` (reading, chat, doc); the block's is gone.
        #expect(!encodedText.contains("\"kind\":\"deep\""), "the retired block kind is not written")
        // What kind of hour the block is rides the record as its own key
        // (schema 123) and lands.
        #expect(encodedText.contains("\"purpose\":\"review\""))
        #expect(current.purpose == .review)
        #expect(landed.blocks.count == 1, "a moved block is one row")
        #expect(landed.activities == [logged], "the log lands with the day")
        #expect(try receiver.pendingSyncChanges().isEmpty, "an inbound apply queues nothing")

        // A record written before the log existed still decodes: no activities.
        let older = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: Data("""
        {"plan":{"id":"2026-09-11","date":"2026-09-11","revision":1},"blocks":[{"id":"b","dayPlanID":"2026-09-11","startMinute":540,"endMinute":600,"title":"Old"}]}
        """.utf8))
        #expect(older.activities.isEmpty)
        #expect(older.blocks.first?.calendarEventID == nil, "a block written before build 101 has no event")
        #expect(older.blocks.first?.purpose == .work, "a block written before schema 123 is work")

        // A block written by a build up to 99 carries one source and a kind:
        // the source becomes the list, the kind is dropped on the floor.
        let legacy = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: Data("""
        {"plan":{"id":"2026-09-11","date":"2026-09-11","revision":1},"blocks":[
          {"id":"b1","dayPlanID":"2026-09-11","startMinute":540,"endMinute":600,"title":"Read","kind":"shallow","sourceID":" src-old ","status":"planned","revision":1}
        ]}
        """.utf8))
        #expect(legacy.blocks.first?.sourceIDs == ["src-old"])

        // Inbound log spans are unioned by id, newest-wins: the Mac that kept
        // reading has the longer, newer span, and a span only it saw stays.
        var longer = logged
        longer.endMinute = 640
        longer.updatedAt = logged.updatedAt.addingTimeInterval(60)
        let elsewhere = DayActivity(dayPlanID: date, startMinute: 700, endMinute: 720, kind: .chat, targetID: "chat-1", title: "Q")
        try receiver.saveDayPlanRecord(CloudKitDayPlanPayload(plan: landed.plan, blocks: [], activities: [longer, elsewhere]))
        var stale = logged
        stale.endMinute = 602
        stale.updatedAt = logged.updatedAt.addingTimeInterval(-60)
        try receiver.saveDayPlanRecord(CloudKitDayPlanPayload(plan: landed.plan, blocks: [], activities: [stale]))
        let merged = try #require(try receiver.loadDayPlan(date))
        #expect(merged.activities.map(\.id) == [logged.id, elsewhere.id])
        #expect(merged.activities.first?.endMinute == 640, "a stale shorter span never shortens the newer one")
    }

    @Test("Inbound sync unions blocks, never brings back a deleted one, and keeps a row an older build redrew off the plan")
    func inboundMerge() throws {
        let root = temporaryRoot("DayPlanMerge")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-12"
        let now = Date()

        _ = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 540, endMinute: 600, title: "Local only"), now: now)
        let shared = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 600, endMinute: 660, title: "Shared, local title"), now: now)
        let afternoon = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 900, endMinute: 960, title: "Afternoon"), now: now)
        // This Mac took the shared block off the day.
        try store.deleteTimeBlock(shared.id, now: now)

        // The other Mac, on a build that still draws columns, never saw the
        // delete: it retitled the shared row a minute later, drew a row of
        // its own, and redrew the afternoon into column 2, which left the
        // afternoon's block behind in column 1. Its day's note is older.
        var remoteShared = shared
        remoteShared.title = "Shared, remote title"
        remoteShared.updatedAt = now.addingTimeInterval(60)
        let remoteOnly = TimeBlock(dayPlanID: date, startMinute: 780, endMinute: 840, title: "Remote only", revision: 2, createdAt: now, updatedAt: now)
        var remoteAfternoon = afternoon
        remoteAfternoon.supersededInRevision = 2
        remoteAfternoon.updatedAt = now.addingTimeInterval(60)
        let remotePlan = DayPlan(date: date, revision: 2, notes: "remote note", createdAt: now, updatedAt: now.addingTimeInterval(-30))
        try store.saveDayPlanRecord(CloudKitDayPlanPayload(plan: remotePlan, blocks: [remoteShared, remoteOnly, remoteAfternoon]))

        let merged = try #require(try store.loadDayPlan(date))
        #expect(merged.plan.notes == nil, "the older remote note does not outrank the newer local day")
        #expect(merged.plan.revision == 2, "the stored revision only ever advances, as the older build expects")
        #expect(Set(merged.currentBlocks.map(\.title)) == ["Local only", "Remote only"])
        let sharedRow = try #require(merged.blocks.first { $0.id == shared.id })
        #expect(sharedRow.deletedAt != nil, "a deleted block stays deleted whatever the remote says")
        #expect(sharedRow.title == "Shared, remote title", "the newer remote edit still wins the fields")
        #expect(merged.blocks.first { $0.id == afternoon.id }?.supersededInRevision == 2, "a row the older build left in a column stays off the plan")

        // A block drawn here now carries the day's stored revision, so the
        // older build shows it in its current column.
        let evening = try store.addTimeBlock(TimeBlock(dayPlanID: date, startMinute: 1020, endMinute: 1080, title: "Evening"), now: now)
        #expect(evening.revision == 2)
    }

    // MARK: - Helpers

    @Test("A series' action items read back as the latest session's, open first")
    func meetingActionItemsForPlanner() throws {
        let earlier = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = Date(timeIntervalSinceReferenceDate: 2_000)
        let old = MeetingActionItem(groupID: "g", sourceID: "s1", position: 1, text: "Old", createdAt: earlier, updatedAt: earlier)
        let a = MeetingActionItem(groupID: "g", sourceID: "s2", position: 1, text: "A", doneAt: later, createdAt: later, updatedAt: later)
        let b = MeetingActionItem(groupID: "g", sourceID: "s2", position: 2, text: "B", createdAt: later, updatedAt: later)
        let c = MeetingActionItem(groupID: "g", sourceID: "s2", position: 3, text: "C", createdAt: later, updatedAt: later)
        #expect(MeetingActionItems.forPlanner([old, a, b, c]).map(\.text) == ["B", "C", "A"])
        #expect(MeetingActionItems.forPlanner([]).isEmpty)
        #expect(a.id == "s2#1", "the id is the app's, never the model's")
        let parsed = try AIService.parseMeetingActionItems("""
        Sure: {"items":[{"text":"Send the protocol","owner":"Zara","due":"Friday"},{"text":"","owner":"x"},{"text":"Rerun the assay","owner":"","due":""}]}
        """)
        #expect(parsed.map(\.text) == ["Send the protocol", "Rerun the assay"])
        #expect(parsed[0].owner == "Zara" && parsed[0].due == "Friday")
        #expect(parsed[1].owner == nil && parsed[1].due == nil)
        #expect(throws: (any Error).self) { _ = try AIService.parseMeetingActionItems("no json here") }
    }

    @Test("A calendar block's event survives every storage write and a redraw")
    func calendarFieldsInStorage() throws {
        let root = temporaryRoot("DayPlanCalendar")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let date = "2026-09-15"

        let block = try store.addTimeBlock(TimeBlock(
            dayPlanID: date, startMinute: 600, endMinute: 630, title: "Standup",
            calendarEventID: " google:primary/e1 ", calendarEventURL: "https://calendar.google.com/event?eid=1"
        ))
        #expect(block.calendarEventID == "google:primary/e1", "trimmed like every other field")
        #expect(block.isFromCalendar)
        var moved = block
        moved.startMinute = 615
        moved.endMinute = 645
        let edited = try store.updateTimeBlock(moved)
        #expect(edited.id == block.id)
        #expect(edited.calendarEventID == "google:primary/e1" && edited.calendarEventURL == "https://calendar.google.com/event?eid=1")
        let revised = try store.reviseDayPlan(date, replacing: [edited.id], replacements: [
            TimeBlock(dayPlanID: date, startMinute: 630, endMinute: 660, title: "Standup", calendarEventID: "google:primary/e1"),
        ])
        #expect(revised.currentBlocks.first?.calendarEventID == "google:primary/e1")
        #expect(revised.currentBlocks.first?.calendarEventURL == nil)
        #expect(revised.blocks.filter { $0.calendarEventID == "google:primary/e1" }.count == 2, "the replaced row keeps its event too, tombstoned, so the import never draws back what a redraw replaced")
    }

    private func temporaryRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
