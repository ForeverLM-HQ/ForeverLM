import Testing
import Foundation
@testable import ForeverLM

/// One sitting, one session. A free Zoom account ends a call after forty
/// minutes and the host starts a new meeting, so one standup used to arrive
/// as two sessions of its series (product owner, 2026-09-19: "there should just be
/// 1 a day since there is only 1 standup a day … you should merge those
/// transcripts"). These pin the rule that says which sessions are one
/// sitting, the document the fold writes, and what the fold moves.
private enum Fixture {
    static let group = "zoom:examplefellowship.zoom.us"
    static let topic = "Robin <> Zara standup"
    static let day = "2026-09-19"

    /// A moment on the fixture day, in the calendar the store reads keys in.
    static func moment(_ minutes: Int, day: String = day) -> Date {
        DayPlan.startOfDay(day, calendar: .current)!.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// A session as the Zoom watcher files it: the start to the minute in the
    /// session key, the topic in `domain`, the transcript under its heading.
    static func session(start: Date, transcript: String, group: String = group, topic: String = topic) -> StudioArticle {
        let key = StudioViewModel.readAISessionKey(title: topic, date: start, includeTime: true)
        var article = StudioArticle(
            url: "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(key))",
            title: key,
            sourceType: .meeting,
            discoveryOrigin: .zoom,
            parentGroup: group
        )
        article.domain = topic
        article.dateAdded = start
        article.content = "# \(key)\n\n## Transcript\n\n\(transcript)"
        article.wordCount = article.content?.split(separator: " ").count
        article.state = .ready
        return article
    }

    static func artifact(_ session: StudioArticle, kind: MeetingArtifactKind, path: String) -> MeetingArtifact {
        MeetingArtifact(
            id: SourceIdentity.stableID(for: "\(session.id):zoom-local:\(kind.rawValue)"),
            sourceId: session.id,
            groupId: session.parentGroup ?? group,
            kind: kind,
            title: "\(topic) \(kind.label)",
            url: nil,
            localFilePath: path,
            mimeType: kind == .recording ? "audio/mp4" : "text/plain",
            modifiedAt: session.dateAdded,
            sortIndex: kind.sortRank
        )
    }

    static func temporaryRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@Suite("Meeting session continuation rule")
struct MeetingSessionContinuationTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test("a call that starts on the same day within four hours of the first is the same sitting; a later one, or the next day's, is not")
    func runsFoldOneSitting() {
        typealias S = MeetingSessionContinuation.Session
        let lateNight = S(id: "night", startedAt: Self.at(18, 23, 50))
        let first = S(id: "first", startedAt: Self.at(19, 8, 30))
        let reconnect = S(id: "reconnect", startedAt: Self.at(19, 9, 10))
        let afternoon = S(id: "afternoon", startedAt: Self.at(19, 14, 0))
        let tomorrow = S(id: "tomorrow", startedAt: Self.at(20, 8, 30))
        let all = [tomorrow, reconnect, afternoon, first, lateNight]

        let automatic = MeetingSessionContinuation.runs(all, calendar: Self.calendar)
        #expect(automatic == [[lateNight], [first, reconnect], [afternoon], [tomorrow]])
        #expect(MeetingSessionContinuation.mergeGroups(all, calendar: Self.calendar) == [[first, reconnect]])

        // The explicit rule is the day alone.
        let wholeDay = MeetingSessionContinuation.mergeGroups(all, window: nil, calendar: Self.calendar)
        #expect(wholeDay == [[first, reconnect, afternoon]])

        // Ten minutes apart across midnight is two days, not one sitting.
        let justAfterMidnight = S(id: "after", startedAt: Self.at(19, 0, 5))
        #expect(MeetingSessionContinuation.runs([lateNight, justAfterMidnight], calendar: Self.calendar)
            == [[lateNight], [justAfterMidnight]])

        // Exactly the window still counts; a second past it does not.
        let atWindow = S(id: "edge", startedAt: first.startedAt.addingTimeInterval(MeetingSessionContinuation.window))
        let pastWindow = S(id: "past", startedAt: first.startedAt.addingTimeInterval(MeetingSessionContinuation.window + 1))
        #expect(MeetingSessionContinuation.runs([first, atWindow], calendar: Self.calendar) == [[first, atWindow]])
        #expect(MeetingSessionContinuation.runs([first, pastWindow], calendar: Self.calendar) == [[first], [pastWindow]])
    }

    @Test("a session's start is the time in its key, or its date when it has no key; a day-keyed session has no start")
    func knownStartReadsTheKeyThenTheDate() {
        let keyed = StudioArticle(
            url: "meeting://zara/\(StudioViewModel.percentEncodedMeetingPathComponent("Robin <> Zara - 2026/09/19 08:32"))",
            title: "Robin <> Zara - 2026/09/19 08:32", sourceType: .meeting, parentGroup: "zara"
        )
        #expect(MeetingSessionContinuation.knownStart(of: keyed, calendar: Self.calendar) == Self.at(19, 8, 32))

        // The real series id carries a colon, which URLComponents reads as a
        // port; the key is read off the string, so the start is still known.
        let colonGroup = StudioArticle(
            url: "meeting://zoom:examplefellowship.zoom.us/Robin%20%3C%3E%20Zara%20-%202026/09/19%2008:30",
            title: "Robin <> Zara - 2026/09/19 08:30", sourceType: .meeting, parentGroup: "zoom:examplefellowship.zoom.us"
        )
        #expect(StudioViewModel.meetingSessionKey(fromSourceURL: colonGroup.url) == "Robin <> Zara - 2026/09/19 08:30")
        #expect(MeetingCalendarEvent.knownStart(of: colonGroup, calendar: Self.calendar) == Self.at(19, 8, 30))
        #expect(MeetingSessionContinuation.knownStart(of: colonGroup, calendar: Self.calendar) == Self.at(19, 8, 30))

        var dayOnly = StudioArticle(
            url: "meeting://zara/2026/09/19", title: "Robin <> Zara - 2026/09/19", sourceType: .meeting, parentGroup: "zara"
        )
        dayOnly.dateAdded = Self.at(19, 9, 0)
        #expect(MeetingSessionContinuation.knownStart(of: dayOnly, calendar: Self.calendar) == nil)

        var cloud = StudioArticle(
            url: "https://examplefellowship.zoom.us/rec/share/abc", title: "Robin <> Zara", sourceType: .meeting, parentGroup: "zara"
        )
        cloud.dateAdded = Self.at(19, 9, 41)
        #expect(MeetingSessionContinuation.knownStart(of: cloud, calendar: Self.calendar) == cloud.dateAdded)
    }

    @Test("the merged document has one section of each kind, every part in start order under a reconnection line, whatever order the parts came in")
    func mergedContentJoinsSectionsInStartOrder() {
        typealias Part = MeetingSessionContinuation.Part
        let first = Part(
            content: "# Robin <> Zara - 2026/09/19 08:30\n\n## Transcript\n\n[08:30:05] Robin: Part one.\n\n## Recording\n\naudio1.m4a",
            startedAt: Self.at(19, 8, 30),
            title: "Robin <> Zara - 2026/09/19 08:30"
        )
        // A Zoom cloud session stores the bare transcript; a notes-only part
        // brings a section the first part lacks.
        let second = Part(
            content: "Zara: Part two, after the call dropped.",
            startedAt: Self.at(19, 9, 10),
            title: "Robin <> Zara - 2026/09/19 09:10"
        )
        let third = Part(
            content: "# Notes\n\n## Notes\n\nDecided to read Safee 2019.\n\n## Recording\n\naudio3.m4a",
            startedAt: Self.at(19, 9, 40),
            title: "Robin <> Zara - 2026/09/19 09:40"
        )

        let merged = MeetingSessionContinuation.mergedContent([third, second, first], calendar: Self.calendar)
        #expect(merged.hasPrefix("# Robin <> Zara - 2026/09/19 08:30\n"))
        #expect(merged.components(separatedBy: "\n## Transcript\n").count == 2)
        #expect(merged.components(separatedBy: "\n## Recording\n").count == 2)
        #expect(merged.components(separatedBy: "\n## Notes\n").count == 2)

        let transcript = MeetingContent.text(for: .transcript, in: merged)
        #expect(transcript == """
        [08:30:05] Robin: Part one.

        —— Reconnected at 09:10 ——

        Zara: Part two, after the call dropped.
        """)
        #expect(MeetingContent.text(for: .recording, in: merged) == "audio1.m4a\n\n—— Reconnected at 09:40 ——\n\naudio3.m4a")
        #expect(MeetingContent.text(for: .notes, in: merged) == "Decided to read Safee 2019.")

        // Deterministic: the parts' order in the call changes nothing.
        #expect(MeetingSessionContinuation.mergedContent([first, second, third], calendar: Self.calendar) == merged)
        // Sections keep MeetingContent's order, so the extractor reads the
        // result as it reads any session.
        let transcriptAt = merged.range(of: "\n## Transcript\n")!.lowerBound
        let notesAt = merged.range(of: "\n## Notes\n")!.lowerBound
        let recordingAt = merged.range(of: "\n## Recording\n")!.lowerBound
        #expect(transcriptAt < notesAt && notesAt < recordingAt)
    }
}

@Suite("Meeting session merge")
struct MeetingSessionMergeStoreTests {

    @Test("folding the second call into the first keeps its id, joins the transcripts, and moves files, blocks and links; the fold is idempotent")
    func foldingTheSecondCallIntoTheFirst() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveMeetingGroup(name: Fixture.group, metadata: MeetingMetadata(title: Fixture.topic))
        let first = Fixture.session(start: Fixture.moment(510), transcript: "[08:30:05] Robin: Part one.")
        let second = Fixture.session(start: Fixture.moment(550), transcript: "[09:10:12] Zara: Part two.")
        try store.saveSource(first)
        try store.saveSource(second)
        for (session, path) in [(first, "/Zoom/2026-09-19 08.30.13 Robin __ Zara/audio1.m4a"), (second, "/Zoom/2026-09-19 09.10.32 Robin __ Zara/audio2.m4a")] {
            try store.saveMeetingArtifact(Fixture.artifact(session, kind: .recording, path: path))
            try store.saveMeetingArtifact(Fixture.artifact(session, kind: .transcript, path: path))
        }
        // The Planner drew a block for each calendar event, and each call's
        // transcript completed its own.
        let firstBlock = try store.addTimeBlock(TimeBlock(
            dayPlanID: Fixture.day, startMinute: 510, endMinute: 550, title: Fixture.topic, calendarEventID: "google:primary/e1"
        ))
        let secondBlock = try store.addTimeBlock(TimeBlock(
            dayPlanID: Fixture.day, startMinute: 555, endMinute: 585, title: Fixture.topic, calendarEventID: "google:primary/e2"
        ))
        try store.attachSourceToTimeBlock(first.id, blockID: firstBlock.id, completing: true)
        try store.attachSourceToTimeBlock(second.id, blockID: secondBlock.id, completing: true)
        let now = Date()
        for session in [first, second] {
            try store.saveMeetingActionItems(
                [MeetingActionItem(groupID: Fixture.group, sourceID: session.id, position: 1, text: "Read the paper", createdAt: now, updatedAt: now)],
                groupID: Fixture.group, sourceID: session.id
            )
        }
        try store.createReviewSession(id: "chat-about-part-two", topic: "Standup", sourceIDs: [second.id])

        // The order the ids come in does not choose the survivor; the start does.
        let outcome = try #require(try store.mergeMeetingSessions([second.id, first.id]))
        #expect(outcome.survivorID == first.id)
        #expect(outcome.absorbedIDs == [second.id])
        #expect(outcome.groupID == Fixture.group)
        #expect(outcome.date == Fixture.day)

        #expect(try store.loadActiveSources().map(\.id) == [first.id])
        let absorbed = try #require(try store.loadSources().first { $0.id == second.id })
        #expect(absorbed.status == .archived)
        #expect(try store.loadSourceContent(second.id) == nil, "the text lives in the survivor now")

        let survivor = try #require(try store.loadSourceWithoutContent(first.id))
        #expect(survivor.title == first.title)
        #expect(survivor.url == first.url)
        #expect(survivor.dateAdded == first.dateAdded)
        #expect(survivor.state == .ready)
        let content = try #require(try store.loadSourceContent(first.id))
        #expect(MeetingContent.text(for: .transcript, in: content) == """
        [08:30:05] Robin: Part one.

        —— Reconnected at 09:10 ——

        [09:10:12] Zara: Part two.
        """)

        // Both calls' files are the survivor's; the reconnect's own row lists none.
        #expect(try store.loadMeetingArtifacts(sourceID: first.id).count == 4)
        #expect(try store.loadMeetingArtifacts(sourceID: second.id).isEmpty)

        // Both blocks name the survivor, and stay done.
        let plan = try #require(try store.loadDayPlan(Fixture.day))
        let blocks = Dictionary(uniqueKeysWithValues: plan.currentBlocks.map { ($0.id, $0) })
        #expect(blocks[firstBlock.id]?.sourceIDs == [first.id])
        #expect(blocks[secondBlock.id]?.sourceIDs == [first.id])
        #expect(blocks[secondBlock.id]?.status == .done)

        // The chat about part two is about the sitting.
        #expect(try store.reviewSessionSourceIDsBySessionID()["chat-about-part-two"] == [first.id])

        // The survivor's transcript is new: its items are read again, so none
        // are kept from either part.
        #expect(try store.loadMeetingActionItems(groupID: Fixture.group).isEmpty)

        // Nothing left to fold; the archived row cannot be merged again.
        #expect(try store.sameDayMeetingSessionRuns(groupID: Fixture.group).isEmpty)
        #expect(throws: (any Error).self) { try store.mergeMeetingSessions([first.id, second.id]) }
        #expect(try store.mergeMeetingSessions([first.id]) == nil)

        // The absorbed row keeps its URL, which is what every ingest route
        // checks before filing: the same recording is never filed twice.
        #expect(try store.sourceExistsByURL(second.url)?.status == .archived)
        var again = Fixture.session(start: Fixture.moment(550), transcript: "[09:10:12] Zara: Part two.")
        #expect(try store.insertSourceIfNew(&again) == false)
    }

    @Test("folding two calls that were both on the calendar keeps one activity ledger: a shared day folds, the other call's own days move")
    func foldingKeepsBothCallsActivityDays() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveMeetingGroup(name: Fixture.group, metadata: MeetingMetadata(title: Fixture.topic))
        let first = Fixture.session(start: Fixture.moment(510), transcript: "[08:30:05] Robin: Part one.")
        let second = Fixture.session(start: Fixture.moment(550), transcript: "[09:10:12] Zara: Part two.")
        try store.saveSource(first)
        try store.saveSource(second)

        // Both transcripts were read on the standup day, and the second call's
        // again the day after. Reading puts a session on the calendar by itself,
        // so both are placed, with one day in common and one the first lacks —
        // the shape that used to fail the merge on the ledger's primary key.
        let day = Fixture.moment(600)
        let dayAfter = Fixture.moment(600 + 24 * 60)
        _ = try store.recordScheduledSourceActivity(sourceID: first.id, on: day, kind: .reading, fraction: 0.4, engagedSeconds: 120)
        _ = try store.recordScheduledSourceActivity(sourceID: second.id, on: day, kind: .reading, fraction: 0.9, engagedSeconds: 300)
        _ = try store.recordScheduledSourceActivity(sourceID: second.id, on: dayAfter, kind: .reading, fraction: 1.0)
        let sessionIDs: Set<String> = [first.id, second.id]
        #expect(try store.loadScheduledSources().filter { sessionIDs.contains($0.placement.sourceID) }.count == 2)
        #expect(try store.loadSourceActivityDays(sourceID: first.id).map(\.engagedSeconds) == [120])
        #expect(try store.loadSourceActivityDays(sourceID: second.id).map(\.engagedSeconds) == [300, 0])
        #expect(try store.loadSourceActivityDays(sourceID: second.id).map(\.maxFraction) == [0.9, 1.0])

        let outcome = try #require(try store.mergeMeetingSessions([second.id, first.id]))
        #expect(outcome.survivorID == first.id)

        // One placement, the survivor's, carrying both days.
        let placements = try store.loadScheduledSources().filter { sessionIDs.contains($0.placement.sourceID) }
        #expect(placements.map(\.placement.sourceID) == [first.id])
        #expect(placements.first?.activityDays.count == 2)

        let calendar = Calendar.current
        let days = try store.loadSourceActivityDays(sourceID: first.id)
        #expect(days.map(\.dayStart) == [calendar.startOfDay(for: day), calendar.startOfDay(for: dayAfter)])
        // The shared day keeps the deeper read and the longer sitting — the
        // seconds too, which the placement repair that follows a source save
        // used to rebuild without — and the other call's day is the survivor's
        // now, under the survivor's own id for that day.
        #expect(days[0].maxFraction == 0.9)
        #expect(days[0].engagedSeconds == 300)
        #expect(days[1].maxFraction == 1.0)
        let survivorKey = try store.portableMemorySourceKey(sourceID: first.id)
        #expect(days[1].id == MemoryTutorIdentity.sourceActivityDayID(portableSourceKey: survivorKey, dayStart: calendar.startOfDay(for: dayAfter)))
        #expect(try store.loadSourceActivityDays(sourceID: second.id).isEmpty)
    }

    @Test("the automatic rule takes only ready sessions with a start known to the minute, on the same day within the window; the explicit rule takes the day")
    func continuationRunHonoursDayWindowAndReadiness() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveMeetingGroup(name: Fixture.group, metadata: MeetingMetadata(title: Fixture.topic))
        let first = Fixture.session(start: Fixture.moment(510), transcript: "One.")
        let reconnect = Fixture.session(start: Fixture.moment(550), transcript: "Two.")
        let afternoon = Fixture.session(start: Fixture.moment(14 * 60), transcript: "Three.")
        var transcribing = Fixture.session(start: Fixture.moment(560), transcript: "")
        transcribing.content = MeetingContent.inserting(section: .recording, text: "audio.m4a", into: nil, title: transcribing.title)
        transcribing.state = .fetching
        var dayKeyed = StudioArticle(
            url: "meeting://\(Fixture.group)/2026/09/19", title: "\(Fixture.topic) - 2026/09/19",
            sourceType: .meeting, discoveryOrigin: .googleDriveMeetings, parentGroup: Fixture.group
        )
        dayKeyed.domain = Fixture.topic
        dayKeyed.dateAdded = Fixture.moment(540)
        dayKeyed.content = "# Notes\n\n## Notes\n\nFrom the Drive folder."
        dayKeyed.state = .ready
        let tomorrow = Fixture.session(start: Fixture.moment(510, day: "2026-09-20"), transcript: "Next day.")
        for session in [first, reconnect, afternoon, transcribing, dayKeyed, tomorrow] {
            try store.saveSource(session)
        }

        #expect(try store.meetingSessionContinuationRun(for: reconnect.id) == [first.id, reconnect.id])
        #expect(try store.meetingSessionContinuationRun(for: first.id) == [first.id, reconnect.id])
        #expect(try store.meetingSessionContinuationRun(for: afternoon.id) == nil, "four hours on is another meeting")
        #expect(try store.meetingSessionContinuationRun(for: transcribing.id) == nil, "its transcript is still on its way")
        #expect(try store.meetingSessionContinuationRun(for: dayKeyed.id) == nil, "a day-keyed file has no start")
        #expect(try store.meetingSessionContinuationRun(for: tomorrow.id) == nil)

        // The explicit rule: the whole day, and a day-keyed session is dated
        // by its row; a session still transcribing is left alone.
        #expect(try store.sameDayMeetingSessionRuns(groupID: Fixture.group)
            == [[first.id, dayKeyed.id, reconnect.id, afternoon.id]])
        #expect(try store.sameDayMeetingSessionRuns(groupID: Fixture.group, date: "2026-09-20").isEmpty)
        #expect(try store.sameDayMeetingSessionRuns(groupID: Fixture.group, date: Fixture.day).count == 1)

        // A merge across series, or over a session still transcribing, is refused.
        try store.saveMeetingGroup(name: "other", metadata: MeetingMetadata(title: "Other"))
        let elsewhere = Fixture.session(start: Fixture.moment(520), transcript: "Elsewhere.", group: "other", topic: "Other")
        try store.saveSource(elsewhere)
        #expect(throws: (any Error).self) { try store.mergeMeetingSessions([first.id, elsewhere.id]) }
        #expect(throws: (any Error).self) { try store.mergeMeetingSessions([first.id, transcribing.id]) }
        #expect(try store.loadActiveSources().count == 7, "a refused merge changes nothing")
    }

    @Test("a series merged into another still folds its sessions, whichever id they were filed under")
    func aliasedSeriesFoldsTogether() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveMeetingGroup(name: "zara-old", metadata: MeetingMetadata(title: "Robin <> Zara"))
        try store.saveMeetingGroup(name: Fixture.group, metadata: MeetingMetadata(title: Fixture.topic))
        let underOldID = Fixture.session(start: Fixture.moment(510), transcript: "One.", group: "zara-old")
        let underNewID = Fixture.session(start: Fixture.moment(550), transcript: "Two.")
        try store.saveSource(underOldID)
        try store.saveSource(underNewID)
        try store.mergeMeetingGroup("zara-old", into: Fixture.group)

        #expect(try store.meetingSessionContinuationRun(for: underNewID.id) == [underOldID.id, underNewID.id])
        let outcome = try #require(try store.mergeMeetingSessions([underOldID.id, underNewID.id]))
        #expect(outcome.groupID == Fixture.group)
        #expect(try store.loadActiveSources().map(\.id) == [underOldID.id])
    }
}

/// The routes: every stored transcript ends in
/// `MeetingActionItemExtractor.noteTranscriptReady`, so the fold lives there
/// once rather than in each importer. These drive that funnel against a
/// test store, and the Zoom watcher's own filing before it.
@Suite("Meeting session merge funnel")
struct MeetingSessionMergeFunnelTests {

    @Test("a second call's transcript lands in the first session, and a third call of the same sitting lands there too")
    func aSecondCallLandsInTheFirstSession() async throws {
        let root = Fixture.temporaryRoot("MeetingMergeFunnel")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveMeetingGroup(name: Fixture.group, metadata: MeetingMetadata(title: Fixture.topic))
        let first = Fixture.session(start: Fixture.moment(512), transcript: "One.")
        try await storage.saveSource(first)
        let extractor = MeetingActionItemExtractor(storage: storage)
        #expect(await extractor.handleTranscriptReady(sourceID: first.id) == nil, "the first call stands alone")

        let second = Fixture.session(start: Fixture.moment(551), transcript: "Two.")
        try await storage.saveSource(second)
        let merged = try #require(await extractor.handleTranscriptReady(sourceID: second.id))
        #expect(merged.survivorID == first.id)
        #expect(merged.absorbedIDs == [second.id])
        #expect(try await storage.loadActiveSources().map(\.id) == [first.id])

        let third = Fixture.session(start: Fixture.moment(600), transcript: "Three.")
        try await storage.saveSource(third)
        let again = try #require(await extractor.handleTranscriptReady(sourceID: third.id))
        #expect(again.survivorID == first.id)
        let content = try #require(await storage.loadSourceContent(first.id))
        #expect(MeetingContent.text(for: .transcript, in: content) == """
        One.

        —— Reconnected at 09:11 ——

        Two.

        —— Reconnected at 10:00 ——

        Three.
        """)
        #expect(await extractor.handleTranscriptReady(sourceID: first.id) == nil, "nothing left to fold")
    }

    @Test("two caption files of one standup become one session, and a second pass of the watcher files nothing twice")
    func zoomWatcherFilesOnceAndNeverTwice() async throws {
        let root = Fixture.temporaryRoot("MeetingMergeZoom")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveMeetingGroup(name: Fixture.group, metadata: MeetingMetadata(title: Fixture.topic))
        let zoomFolder = root.appendingPathComponent("Zoom")
        try FileManager.default.createDirectory(at: zoomFolder, withIntermediateDirectories: true)
        // Zoom names the file in the Mac's own offset; the fixture uses
        // whatever offset the test Mac has so the day is the same one the
        // store reads.
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: Fixture.moment(510))
        let sign = offsetSeconds < 0 ? "-" : "+"
        let offset = String(format: "GMT%@%d:%02d", sign, abs(offsetSeconds) / 3600, (abs(offsetSeconds) % 3600) / 60)
        try """
        08:30:05 --> 08:30:07
        Robin Vale: Part one.

        """.write(to: zoomFolder.appendingPathComponent("\(Fixture.topic) 2026-09-19 08:30(\(offset)).txt"), atomically: true, encoding: .utf8)
        try """
        09:10:12 --> 09:10:14
        Zara Holt: Part two, after the drop.

        """.write(to: zoomFolder.appendingPathComponent("\(Fixture.topic) 2026-09-19 09:10(\(offset)).txt"), atomically: true, encoding: .utf8)

        let files = StudioViewModel.zoomLocalTranscriptFiles(roots: [zoomFolder.path])
        #expect(files.count == 2)
        let inserted = await StudioViewModel.importZoomLocalTranscripts(files, storage: storage, removedGroupTitles: [])
        #expect(inserted.count == 2)

        // What the watcher's funnel does once the second file is filed.
        let extractor = MeetingActionItemExtractor(storage: storage)
        let merged = try #require(await extractor.handleTranscriptReady(sourceID: inserted[1]))
        #expect(merged.survivorID == inserted[0])
        let active = try await storage.loadActiveSources()
        #expect(active.map(\.id) == [inserted[0]])
        let content = try #require(await storage.loadSourceContent(inserted[0]))
        #expect(content.contains("[08:30:05] Robin Vale: Part one."))
        #expect(content.contains("—— Reconnected at 09:10 ——"))
        #expect(content.contains("[09:10:12] Zara Holt: Part two, after the drop."))
        #expect(try await storage.loadMeetingArtifacts(sourceID: inserted[0]).count == 2, "both caption files are the session's")

        // The backstop pass sees the same two files: the archived row answers
        // for the second, so nothing is filed or appended again.
        let secondPass = await StudioViewModel.importZoomLocalTranscripts(files, storage: storage, removedGroupTitles: [])
        #expect(secondPass.isEmpty)
        #expect(try await storage.loadActiveSources().map(\.id) == [inserted[0]])
        #expect(await storage.loadSourceContent(inserted[0]) == content)
        #expect(await extractor.handleTranscriptReady(sourceID: inserted[0]) == nil)
    }
}
