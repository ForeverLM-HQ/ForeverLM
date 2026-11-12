import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The phone's learning history (docs/cloudkit-schema-design.md §3.5.22–§3.5.24, D23, D24, D44; §14.2
/// WP20b). An answer joins this device's Sitting, written once, a card kept here is a Card, the review
/// minutes and the sources the learner spent time with are this device's ActivityLog, and a bout's break
/// end is `breakEndsAt`; Sittings go out at most every 30 s, logs every 5 minutes.
@Suite("iPhone Sitting recorder", .serialized)
struct MobileSittingRecorderTests {
    typealias Fixture = MobileWriterFixture
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func attempt(_ id: String, item: String = "card1", session: String? = "memory-2027-01-15", rating: MemoryScheduleRating = .good,
                        feedback: String? = "Right: GFRAL.", at date: Date = now) -> MemoryAttempt {
        MemoryAttempt(id: id, memoryItemID: item, sessionID: session, exchangeID: session.map { "\($0)::exchange::0001" }, prompt: "What binds GDF15?",
                      learnerAnswer: "GFRAL", feedback: feedback, score: 1, scheduleRating: rating, gradeState: .graded, attemptedAt: date,
                      modelProvider: "OpenRouter", modelID: "model-a")
    }

    static func item(_ id: String = "card1", target: String = "GDF15 binds GFRAL") -> MemoryItem {
        MemoryItem(id: id, kind: .concept, target: target, rubricJSON: "{\"criteria\":[]}",
                   sources: [MemoryItemSource(id: "a1", memoryItemID: id, sourceID: "src1", excerpt: "GFRAL", sourceSHA256: "h", sortIndex: 0)],
                   createdAt: now, updatedAt: now)
    }

    static func recorder(_ writer: MobileRecordWriter) -> MobileMemoryAttemptRecorder {
        MobileMemoryAttemptRecorder(writer: { writer })
    }

    static func sittingID(_ scope: String) -> String {
        MobileMemoryRecords.sittingID(deviceID: Fixture.deviceID, scope: scope)
    }

    // MARK: - Answers

    @Test("A graded answer joins this device's Sitting for its chat, written once in the Mac's Answer shape; a replay is fine and another answer under its id refused")
    func answersJoinTheSitting() async throws {
        let replica = try await Fixture.replica(space: nil)
        let recorder = Self.recorder(Fixture.writer(replica, at: Self.now))
        let attempt = Self.attempt("att1")
        _ = try await recorder.record(attempt, parentCurriculumFingerprint: "fp1")
        let sitting = try #require(try await Fixture.held(replica, .sitting, Self.sittingID("memory-2027-01-15"), in: Fixture.library))
        #expect(sitting.fields["deviceID"] == .string(Fixture.deviceID))
        #expect(sitting.fields["kind"] == .string("memoryReview"))
        #expect(sitting.fields["chatID"] == .string("memory-2027-01-15"))
        #expect(sitting.fields["part"] == SyncJSON(1))
        #expect(sitting.fields["startedAt"] == SyncJSON(SyncTime.milliseconds(Self.now)))
        let answer = try #require(sitting.fields["answers"]?["att1"])
        #expect(answer["subject"] == .string("crd:card1"))
        #expect(answer["counted"] == .bool(true))
        #expect(answer["rating"] == .string("good"))
        #expect(answer["outcome"] == .string("graded:good"))
        #expect(answer["curriculumFingerprint"] == .string("fp1"))
        #expect(answer["exchangeID"] == .string("memory-2027-01-15::exchange::0001"))
        #expect(answer["model"] == .object(["provider": "OpenRouter", "id": "model-a"]))
        #expect(answer["attemptType"] == nil, "a review is the default")

        let stamps = try #require(try await Fixture.patch(replica, .sitting, Self.sittingID("memory-2027-01-15"), in: Fixture.library)).stamps
        _ = try await recorder.record(attempt, parentCurriculumFingerprint: "fp1")
        #expect(try await Fixture.patch(replica, .sitting, Self.sittingID("memory-2027-01-15"), in: Fixture.library)?.stamps == stamps,
                "the same answer again writes nothing")
        await #expect(throws: MobileMemoryAttemptRecorderError.self) {
            _ = try await recorder.record(Self.attempt("att1", rating: .again), parentCurriculumFingerprint: "fp1")
        }
        #expect(try await Fixture.held(replica, .sitting, Self.sittingID("memory-2027-01-15"), in: Fixture.library)?.fields["answers"]?["att1"] == answer,
                "the first answer stands")
    }

    @Test("The card review's self-graded answers are the day's cards Sitting; an answer already held under its id counts as recorded, whatever it holds")
    func selfGradedAnswers() async throws {
        let replica = try await Fixture.replica(space: nil)
        let recorder = Self.recorder(Fixture.writer(replica, at: Self.now))
        let attempt = Self.attempt("self1", session: nil)
        #expect(try await recorder.recordSelfGraded(attempt, parentCurriculumFingerprint: "fp1") == .recorded)
        #expect(try await recorder.recordSelfGraded(Self.attempt("self1", session: nil, rating: .again), parentCurriculumFingerprint: "fp1") == .alreadyRecorded)
        let day = MemoryReviewGoal.dayKey(for: Self.now)
        let sitting = try #require(try await Fixture.held(replica, .sitting, Self.sittingID("day:\(day)"), in: Fixture.library))
        #expect(sitting.fields["kind"] == .string("cards"))
        #expect(sitting.fields["chatID"] == nil)
        #expect(sitting.fields["answers"]?["self1"]?["rating"] == .string("good"))
    }

    @Test("A part closes at 200 answers, or at 100 KiB of answers: the next answer starts `<firstID>#2` with the first part's kind and start")
    func partsRollOver() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica, at: Self.now)
        try await writer.transaction { write in
            for index in 0..<201 { _ = try write.recordAnswer(Self.attempt("a\(index)"), curriculumFingerprint: nil) }
        }
        let first = Self.sittingID("memory-2027-01-15")
        #expect(try await Fixture.held(replica, .sitting, first, in: Fixture.library)?.fields["answers"]?.objectValue?.count == 200)
        let second = try #require(try await Fixture.held(replica, .sitting, "\(first)#2", in: Fixture.library))
        #expect(second.fields["part"] == SyncJSON(2))
        #expect(second.fields["kind"] == .string("memoryReview"))
        #expect(second.fields["startedAt"] == SyncJSON(SyncTime.milliseconds(Self.now)))
        #expect(second.fields["answers"]?.objectValue?.keys.sorted() == ["a200"])
        #expect(try await writer.transaction { try $0.recordAnswer(Self.attempt("a7"), curriculumFingerprint: nil) } == .alreadyRecorded,
                "an answer in an earlier part is found")

        let long = String(repeating: "x", count: 5_000)
        try await writer.transaction { write in
            for index in 0..<21 { _ = try write.recordAnswer(Self.attempt("b\(index)", session: "chat-long", feedback: long), curriculumFingerprint: nil) }
        }
        let longFirst = Self.sittingID("chat-long")
        let held = try #require(try await Fixture.held(replica, .sitting, longFirst, in: Fixture.library)?.fields["answers"]?.objectValue)
        #expect(held.count < 21 && held.count >= 19, "the byte limit closed the part")
        #expect(try await Fixture.held(replica, .sitting, "\(longFirst)#2", in: Fixture.library) != nil)
    }

    @Test("A Sitting waiting to be sent keeps its first write's time: it goes out 30 s after the first answer however often the learner answers, and at once when flushed")
    func savedAtMostEveryThirtySeconds() async throws {
        let replica = try await Fixture.replica(space: nil)
        _ = try await Self.recorder(Fixture.writer(replica, at: Self.now)).record(Self.attempt("att1"), parentCurriculumFingerprint: "fp")
        _ = try await Self.recorder(Fixture.writer(replica, at: Self.now.addingTimeInterval(20))).record(Self.attempt("att2"), parentCurriculumFingerprint: "fp")
        let dirty = try await replica.read { try $0.connection.scalarText("SELECT dirty_at FROM ck_patches WHERE record_type = 'Sitting'", []) }
        #expect(dirty.flatMap(Double.init) == Self.now.timeIntervalSinceReferenceDate)
        let due = try await Fixture.changes(replica, at: Self.now.addingTimeInterval(31)).map(\.recordType)
        #expect(due.contains(.sitting))
        #expect(!(try await Fixture.changes(replica, at: Self.now.addingTimeInterval(29)).map(\.recordType).contains(.sitting)))

        try await Fixture.writer(replica, at: Self.now).transaction { _ = try $0.recordAnswer(Self.attempt("att3", session: "other"), curriculumFingerprint: nil) }
        try await Fixture.writer(replica, at: Self.now).flushLearningHistory()
        #expect(try await Fixture.changes(replica, at: Self.now).filter { $0.recordType == .sitting }.count == 2)
    }

    @Test("A flush makes a waiting Sitting due and tells the session to send it, unless the caller sends it itself, as the app leaving the foreground does")
    func flushSendsSoonOrLeavesItToTheCaller() async throws {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func add() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica, at: Self.now)
        try await writer.transaction { _ = try $0.recordAnswer(Self.attempt("att1"), curriculumFingerprint: nil) }
        let heard = Heard()
        writer.whenWritten { _ in heard.add() }
        #expect(try await writer.flushLearningHistory(sendsSoon: false) == true, "something was waiting")
        #expect(heard.value == 0, "the caller runs the round, so no second one is scheduled")
        #expect(try await Fixture.changes(replica, at: Self.now).filter { $0.recordType == .sitting }.count == 1, "and the Sitting is due")
        #expect(try await writer.flushLearningHistory(sendsSoon: false) == true, "still waiting, since nothing sent it")

        try await writer.transaction { _ = try $0.recordAnswer(Self.attempt("att2", session: "other"), curriculumFingerprint: nil) }
        #expect(heard.value == 1, "the write itself asks for a round after its debounce")
        try await writer.flushLearningHistory()
        #expect(heard.value == 2, "the default flush asks the session for one now")
        let empty = try await Fixture.replica(space: nil)
        #expect(try await Fixture.writer(empty, at: Self.now).flushLearningHistory() == false, "nothing waiting, nothing to send")
    }

    // MARK: - Cards

    @Test("A card kept here is a Card with its kept wording and the answer that kept it; a card kept first elsewhere keeps its wording and takes the answer")
    func keepingCards() async throws {
        let replica = try await Fixture.replica(space: nil)
        let recorder = Self.recorder(Fixture.writer(replica, at: Self.now))
        let item = Self.item()
        let first = Self.attempt("keep1", session: nil)
        #expect(try await recorder.recordKeeping(item, sourceIdentities: [], firstAttempt: first) == .kept)
        let card = try #require(try await Fixture.held(replica, .card, "card1", in: Fixture.library))
        #expect(card.fields["status"] == .string("kept"))
        #expect(card.fields["deckSourceID"] == .string("src1"))
        #expect(card.fields["kept"]?["front"] == .string("GDF15 binds GFRAL"))
        #expect(card.fields["kept"]?["fingerprint"] == .string(MemoryTutorIdentity.immutableCurriculumFingerprint(item)))
        #expect(card.fields["legacy"]?["kind"] == .string("concept"))
        #expect(try await Fixture.held(replica, .sitting, Self.sittingID("day:\(MemoryReviewGoal.dayKey(for: Self.now))"), in: Fixture.library)?
            .fields["answers"]?["keep1"] != nil)
        let back = try #require(MobileMemoryRecords.item(fromCard: card.fields, id: "card1"))
        #expect(MemoryTutorIdentity.hasSameImmutableCurriculum(back, item), "the card reads back as the item it was kept from")

        let other = Self.item(target: "GDF15 signals through GFRAL and RET")
        let result = try await recorder.recordKeeping(other, sourceIdentities: [], firstAttempt: Self.attempt("keep2", session: nil))
        guard case .keptElsewhere(let held, let outcome) = result else { Issue.record("kept elsewhere expected"); return }
        #expect(held.target == "GDF15 binds GFRAL")
        #expect(outcome == .recorded)
        #expect(try await Fixture.held(replica, .card, "card1", in: Fixture.library)?.fields["kept"] == card.fields["kept"], "the first Keep stands")
    }

    // MARK: - The device's ActivityLog

    @Test("The Memory goal's minutes are this device's ActivityLog review clock, read back by the Memory grid as this device's row; never lowered")
    func reviewClock() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica, at: Self.now)
        try await MobileMemoryGoalModel.save(day: "2027-01-15", seconds: 420, goalSeconds: 900, at: Self.now, writer: { writer })
        let log = try #require(try await Fixture.held(replica, .activityLog, "al:2027-01-15:\(Fixture.deviceID)", in: Fixture.library))
        #expect(log.fields["day"] == .string("2027-01-15"))
        #expect(log.fields["review"] == .object(["seconds": 420, "goalSeconds": 900, "at": SyncJSON(SyncTime.milliseconds(Self.now))]))
        try await writer.transaction { try $0.recordReviewSeconds(day: "2027-01-15", seconds: 300, goalSeconds: 900, at: Self.now) }
        #expect(try await writer.read { try $0.reviewSeconds(day: "2027-01-15") } == 420)
        let rows = try await replica.read { try MobileReadModels.reviewActivity(in: $0.connection, goalSecondsNow: 900, now: Self.now) }
        #expect(rows.map(\.deviceID) == [Fixture.deviceID])
        #expect(rows.first?.activeSeconds == 420)
        #expect(try await Fixture.changes(replica, at: Self.now.addingTimeInterval(299)).filter { $0.recordType == .activityLog }.isEmpty,
                "a log waits 5 minutes")
    }

    @Test("A source is logged once it has 30 s of engaged use; a chat at once; a completion adds its kind; opening alone logs nothing")
    func sourceActivity() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica, at: Self.now)
        let recorder = MobileActivityLogRecorder()
        let day = MemoryReviewGoal.dayKey(for: Self.now)
        try await recorder.record(sourceID: "src1", kind: .reading, at: Self.now, fraction: nil, engagedSeconds: 0, completed: false, writer: writer)
        try await recorder.record(sourceID: "src1", kind: .reading, at: Self.now.addingTimeInterval(20), fraction: 0.2, engagedSeconds: 20, completed: false, writer: writer)
        #expect(try await writer.read { try $0.heldSourceActivity(sourceID: "src1", day: day) } == nil, "20 s is not enough")
        try await recorder.record(sourceID: "src1", kind: .reading, at: Self.now.addingTimeInterval(35), fraction: 0.4, engagedSeconds: 15, completed: false, writer: writer)
        let element = try #require(try await writer.read { try $0.heldSourceActivity(sourceID: "src1", day: day) })
        #expect(element["kinds"] == ["read"])
        #expect(element["engagedSeconds"] == 35)
        #expect(element["maxFraction"] == 0.4)
        #expect(element["firstAt"] == SyncJSON(SyncTime.milliseconds(Self.now)))
        #expect(element["lastAt"] == SyncJSON(SyncTime.milliseconds(Self.now.addingTimeInterval(35))))
        try await recorder.record(sourceID: "src1", kind: .reading, at: Self.now.addingTimeInterval(40), fraction: 0.5, engagedSeconds: 5, completed: false, writer: writer)
        #expect(try await writer.read { try $0.heldSourceActivity(sourceID: "src1", day: day) }?["engagedSeconds"] == 40, "logged, every second counts")

        try await recorder.record(sourceID: "src2", kind: .chat, at: Self.now, fraction: nil, engagedSeconds: 0, completed: false, writer: writer)
        #expect(try await writer.read { try $0.heldSourceActivity(sourceID: "src2", day: day) }?["kinds"] == ["chat"])
        try await recorder.record(sourceID: "src3", kind: .listening, at: Self.now, fraction: 1, engagedSeconds: 0, completed: true, writer: writer)
        let done = try #require(try await writer.read { try $0.heldSourceActivity(sourceID: "src3", day: day) })
        #expect(done["completedKinds"] == ["listen"])
        #expect(done["maxFraction"] == 1)
    }

    // MARK: - Quiz sittings, bouts

    @Test("A learning bout is read from its Sitting; ending its break writes breakEndsAt now and the bout is over on this phone")
    func learningBoutBreak() async throws {
        let replica = try await Fixture.replica(space: nil)
        let now = Date()
        let started = now.addingTimeInterval(-3_600)
        try await Fixture.apply(replica, [(Fixture.library, try MobileSyncFixture.envelope(.sitting, "bout1", [
            "deviceID": "macaaaaa", "kind": "bout", "startedAt": SyncJSON(SyncTime.milliseconds(started)), "part": 1,
            "scope": .object(["title": "GDF15", "plannedMinutes": 50, "notebookID": "nb1", "sourceIDs": ["src1"]]),
            "endedAt": SyncJSON(SyncTime.milliseconds(now.addingTimeInterval(-600))),
            "writeUp": .object(["learned": "GFRAL is the receptor.", "unclear": "", "writtenAt": SyncJSON(SyncTime.milliseconds(now.addingTimeInterval(-300)))]),
            "breakMinutes": 10, "breakEndsAt": SyncJSON(SyncTime.milliseconds(now.addingTimeInterval(300))),
        ]))])
        let defaults = try #require(UserDefaults(suiteName: "MobileSittingRecorderTests.bout"))
        defaults.removePersistentDomain(forName: "MobileSittingRecorderTests.bout")
        let writer = Fixture.writer(replica, at: now)
        let store = MobileLearningBoutStore(writer: { writer }, defaults: defaults)
        let live = try #require(try await store.fetchLive(now: now))
        #expect(live.id == "bout1")
        #expect(live.title == "GDF15")
        #expect(live.notebookID == "nb1")
        #expect(live.phase(now: now) == .resting)
        #expect(abs((live.breakEndsAt ?? .distantPast).timeIntervalSince(now.addingTimeInterval(300))) < 0.01)

        let ended = try await store.endBreak(live, now: now)
        #expect(ended.breakEndedAt == now)
        #expect(try await Fixture.held(replica, .sitting, "bout1", in: Fixture.library)?.fields["breakEndsAt"] == SyncJSON(SyncTime.milliseconds(now)))
        #expect(try await Fixture.patch(replica, .sitting, "bout1", in: Fixture.library)?.changes.keys.sorted() == ["breakEndsAt", "editedAt"],
                "only the break's end, never the Mac's write-up")
        #expect(try await store.fetchLive(now: now.addingTimeInterval(1)) == nil, "the break this phone ended is over")
        defaults.removePersistentDomain(forName: "MobileSittingRecorderTests.bout")
    }

    // MARK: - The day's memory review and a source's ideas

    /// The seeded library on a phone that synced it once, with a writer that uploads satellites.
    static func phoneWithBlobs() async throws -> (server: FakeCloudKit, phone: MobileTestDevice, writer: MobileRecordWriter) {
        let server = try MobileReplicaTests.seededLibrary()
        let phone = try await MobileReplicaTests.phone(server)
        try await phone.sync()
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let blobs = BlobStore(transport: phone.transport, store: phone.replica, deviceID: phone.deviceID, pacer: { _ in pacer })
        return (server, phone, MobileRecordWriter(replica: phone.replica, deviceID: phone.deviceID, blobs: blobs, clock: { Date().addingTimeInterval(-60) }))
    }

    @Test("The day's memory review is a memory Chat with its briefing as a satellite and one Exchange per turn; a turn fills the open question, the next asks the last reply")
    func memoryReviewChat() async throws {
        let (server, phone, writer) = try await Self.phoneWithBlobs()
        let store = MobileMemoryReviewStore(writer: { writer })
        let session = "memory-2027-01-15"
        let briefing = "## Today\nGDF15 and its receptor."
        let created = try await store.create(MobileMemoryReviewStore.Draft(
            sessionID: session, topic: "Memory review, 15 January", briefing: briefing, sourceIDs: ["src1"], sourceIdentities: [["sourceID": "src1"]],
            modelProvider: "OpenRouter", modelID: "model-a", openingQuestion: "What binds GDF15?", startedAt: Self.now
        ))
        #expect(created.briefing == briefing)
        #expect(created.isActive)
        #expect(created.sourceIDs == ["src1"])
        #expect(created.openQuestion == "What binds GDF15?")
        let chat = try #require(try await Fixture.held(phone.replica, .chat, session, in: "private/Library"))
        #expect(chat.fields["kind"] == .string("memory"))
        let file = try #require(chat.fields["briefing"].flatMap(FileRef.init(json:)))
        #expect(file.role == "briefing")
        #expect(file.hash == SyncIdentity.sha256Hex(Data(briefing.utf8)))
        let content = SyncIdentity.contentID(owner: session, role: "briefing", partHash32: try #require(file.parts.first))
        #expect(server.storedRecord(RecordNaming.recordName(type: .content, id: content, salt: MobileSyncFixture.librarySalt), zone: "Content",
                                    owner: MobileReplicaTests.alice) != nil, "the briefing's bytes are on the server before the chat names them")

        let grade = MemoryContourGrade(sourceID: "src1", coverage: [MemoryIdeaCoverage(ideaID: "i1", status: .produced)], score: 1,
                                       verdict: .sound, operation: .recall, evaluation: nil)
        var review = try await store.recordTurn(sessionID: session, answer: "GFRAL", reply: "Right. And where is GFRAL?", grade: grade,
                                                steerBefore: nil, answeredAt: Self.now)
        #expect(review.exchanges.count == 1)
        #expect(review.exchanges[0].userAnswer == "GFRAL")
        // The coverage, not its JSON text: JSONEncoder's key order differs from one encode to the next.
        #expect(MemoryIdeaCoverage.decode(review.exchanges[0].ideaCoverage) == grade.coverage)
        #expect(review.exchanges[0].questionVerdict == "sound")
        #expect(review.openQuestion == "Right. And where is GFRAL?")

        review = try await store.recordTurn(sessionID: session, answer: "The hindbrain", reply: "Yes.", grade: nil, steerBefore: .deeper,
                                            answeredAt: Self.now.addingTimeInterval(30))
        #expect(review.exchanges.map(\.sequenceNumber) == [1, 2])
        #expect(review.exchanges[1].question == "Right. And where is GFRAL?")
        #expect(review.exchanges[0].steer == "deeper", "the steer lands on the graded exchange it steered")
        #expect(try await Fixture.held(phone.replica, .chat, session, in: "private/Library")?.fields["editedAt"] == SyncJSON(SyncTime.milliseconds(Self.now.addingTimeInterval(30))))

        try await phone.sync()
        let other = MobileMemoryReviewStore(writer: { writer })
        #expect(try await other.fetch(sessionID: session)?.briefing == briefing, "another reader fetches the briefing by name")
    }

    @Test("Ideas the phone extracted are the source's ideas satellite, pointed at with a provisional stamp only when the source has none")
    func ideasSatellite() async throws {
        let (_, phone, writer) = try await Self.phoneWithBlobs()
        let store = MobileSourceIdeaStore(writer: { writer })
        let ideas = (0..<3).map { index in
            SourceIdea(id: "idea-\(index)", sourceID: "src1", statement: "Idea \(index)", recallNote: "Note", contentHash: "h", status: .active,
                       sortIndex: 2 - index, createdAt: Self.now, updatedAt: Self.now)
        }
        try await store.save(ideas, sourceIdentity: ["sourceID": "src1"])
        let source = try #require(try await Fixture.held(phone.replica, .source, "src1", in: "private/Catalog"))
        let file = try #require(source.fields["derived"]?["ideas"].flatMap(FileRef.init(json:)))
        #expect(file.role == "ideas")
        guard case .elements(let stamps)? = source.stamps["derived"], let stamp = stamps["ideas"] else { Issue.record("an element stamp"); return }
        #expect(stamp == SourceSkeleton.provisionalStamp(.lastWriter, deviceID: phone.deviceID), "provisional, so a Mac maker's output beats it")
        #expect(await store.ideas(sourceIDs: ["src1", "src2"])["src1"]?.map(\.id) == ["idea-2", "idea-1", "idea-0"])

        try await store.save([ideas[0]], sourceIdentity: ["sourceID": "src1"])
        #expect(try await Fixture.held(phone.replica, .source, "src1", in: "private/Catalog")?.fields["derived"]?["ideas"] == file.value,
                "a source that names ideas keeps them")
        try await store.save([SourceIdea(id: "x", sourceID: "not-held", statement: "S", recallNote: "N", contentHash: "h", status: .active,
                                         sortIndex: 0, createdAt: Self.now, updatedAt: Self.now)], sourceIdentity: [:])
        #expect(try await Fixture.held(phone.replica, .source, "not-held", in: "private/Catalog") == nil, "no skeleton for a source the phone lacks")
    }

    // MARK: - Generation 1

}
