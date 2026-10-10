import Foundation
import Testing
@testable import ForeverLM

/// Memory under generation 2 (docs/cloudkit-schema-design.md D23, §3.5.13, §3.5.24, §8c, §14.2 WP19b): the
/// history grid's minutes from the ActivityLog fold, every device's log and the legacy per-device clocks
/// summed, and its days from the day-named memory Chats, as the Memory screen draws them; and the memory
/// review's candidates from the replica's sources, activity days and highlights.
@Suite("iPhone memory read models", .serialized)
struct MobileMemoryModelTests {
    typealias F = MobileReadModelFixture
    static let goalNow: TimeInterval = 15 * 60

    static func log(_ day: String, device: String, seconds: Double?, legacy: [String: (active: Double, goal: Double)] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = ["day": .string(day), "deviceID": .string(device)]
        if let seconds { fields["review"] = .object(["seconds": .number(seconds), "cardsAnswered": SyncJSON(3)]) }
        if !legacy.isEmpty {
            fields["reviewByDevice"] = .object(legacy.mapValues { .object(["activeSeconds": .number($0.active), "goalSeconds": .number($0.goal)]) })
        }
        return try MobileSyncFixture.envelope(.activityLog, "al:\(day):\(device)", fields)
    }

    @Test("The minutes fold every device's log and the legacy clocks of each old device, a legacy day by the goal it had")
    func activityFold() async throws {
        let replica = try await F.replica(spaceName: nil)
        try await MobileSyncFixture.apply([
            (F.library, try Self.log("2026-09-01", device: "legacy22", seconds: nil, legacy: ["mac-old": (600, 1_200), "ipad-old": (300, 1_200)])),
            (F.library, try Self.log("2026-10-02", device: "phoneaaa", seconds: 420)),
            (F.library, try Self.log("2026-10-02", device: "macbbbbb", seconds: 500)),
            (F.library, try Self.log("2026-10-03", device: "macbbbbb", seconds: nil)),
            (F.library, try Self.log("2026-10-01", device: "legacy22", seconds: nil, legacy: ["mac-old": (200, 600)])),
            (F.library, try Self.log("2026-10-01", device: "phoneaaa", seconds: 100)),
        ], to: replica)
        let rows = try await MobileReadModels.reviewActivity(MobileProjection(replica: replica), goalSecondsNow: Self.goalNow)
        let days = MemoryReviewProgress.days(from: rows)
        #expect(days["2026-09-01"] == MemoryReviewDayProgress(day: "2026-09-01", activeSeconds: 900, goalSeconds: 1_200),
                "two old devices' clocks summed, judged by the goal they had")
        #expect(days["2026-10-02"] == MemoryReviewDayProgress(day: "2026-10-02", activeSeconds: 920, goalSeconds: Self.goalNow))
        #expect(days["2026-10-02"]?.isComplete == true)
        #expect(days["2026-10-03"] == nil, "a log with no review time adds no day")
        #expect(days["2026-10-01"] == MemoryReviewDayProgress(day: "2026-10-01", activeSeconds: 300, goalSeconds: Self.goalNow),
                "a day both kinds hold sums them, under the goal in force now")
        #expect(rows.filter { $0.day == "2026-10-02" }.map(\.deviceID).sorted() == ["macbbbbb", "phoneaaa"])
    }

    @Test("The grid's days come from the memory Chats: earlier days with turns to open, and the days the learner answered in")
    func historyDays() async throws {
        let replica = try await F.replica(spaceName: nil)
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        try await MobileSyncFixture.apply([
            (F.library, try F.chat("memory-2026-09-20", notebook: nil, kind: "memory", edited: 1)),
            (F.library, try F.exchange("m1", chat: "memory-2026-09-20", seq: 1, question: "What is ATP?", answer: "Energy currency")),
            (F.library, try F.chat("memory-2026-09-21", notebook: nil, kind: "memory", edited: 2)),
            (F.library, try F.exchange("m2", chat: "memory-2026-09-21", seq: 1, question: "Prepared, never sat")),
            (F.library, try F.chat("memory-2026-09-22", notebook: nil, kind: "memory", edited: 3)),
            (F.library, try F.chat("memory-2026-09-23", notebook: nil, kind: "memory", edited: 4)),
            (F.library, try F.exchange("m3", chat: "memory-2026-09-23", seq: 1, question: "Q", answer: "A")),
            (F.library, try F.mark("hidden", "cht:memory-2026-09-23")),
            (F.library, try F.chat("memory-2026-10-03", notebook: nil, kind: "memory", edited: 5)),
            (F.library, try F.exchange("m4", chat: "memory-2026-10-03", seq: 1, question: "Today", answer: "Yes")),
            (F.library, try F.chat("ch-plain", notebook: nil, edited: 6)),
            (F.library, try F.exchange("m5", chat: "ch-plain", seq: 1, question: "Not memory", answer: "No")),
        ], to: replica)
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        #expect(snapshot.memoryChats.map(\.id).sorted() == ["memory-2026-09-20", "memory-2026-09-21", "memory-2026-09-22",
                                                            "memory-2026-09-23", "memory-2026-10-03"])
        let days = MobileMemoryHistoryDays.days(of: snapshot.memoryChats, now: now)
        #expect(days.chatDays == ["2026-09-20", "2026-09-21"], "an empty chat, a hidden one and today's are not days to open")
        #expect(days.answeredDays == ["2026-09-20", "2026-09-23", "2026-10-03"], "an answer colours a day, a hidden chat's too")

        let grid = MemoryReviewHistory.grid(chatDays: days.chatDays, answeredDays: days.answeredDays,
                                            progress: ["2026-09-20": MemoryReviewDayProgress(day: "2026-09-20", activeSeconds: 900, goalSeconds: 900)],
                                            now: now)
        let squares = Dictionary(uniqueKeysWithValues: grid.weeks.flatMap(\.days).map { ($0.key, $0) })
        #expect(squares["2026-09-20"]?.level == .met && squares["2026-09-20"]?.hasChat == true)
        #expect(squares["2026-09-21"]?.level == MemoryReviewHistory.Level.none && squares["2026-09-21"]?.hasChat == true)
        #expect(squares["2026-09-23"]?.level == .partial)
    }

    @Test("A switched phone's memory review candidates come from the replica: its sources, every device's activity and the member's highlights")
    func reviewCandidates() async throws {
        let replica = try await F.replica(spaceName: nil)
        let noon = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        let now = noon.addingTimeInterval(86_400)
        let at = SyncTime.milliseconds(noon)
        func activity(_ fraction: Double, seconds: Double) -> SyncJSON {
            .object(["kinds": .array(["read"]), "firstAt": SyncJSON(at - 60_000), "lastAt": SyncJSON(at), "maxFraction": .number(fraction),
                     "engagedSeconds": .number(seconds)])
        }
        func log(_ device: String, _ sources: [String: SyncJSON]) throws -> SyncEnvelope {
            try MobileSyncFixture.envelope(.activityLog, "al:2026-10-02:\(device)",
                                           ["day": .string("2026-10-02"), "deviceID": .string(device), "sources": .object(sources)])
        }
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("srcA", "Membranes", added: 1)),
            (F.catalog, try F.source("srcB", "Fission", added: 2)),
            (F.catalog, try F.source("srcC", "Cristae", added: 3)),
            (F.catalog, try F.source("srcD", "Old", added: 4, ["status": .string("archived")])),
            // Neither device's time alone reaches the floor of a finished read; together they do.
            (F.library, try log("phoneaaa", ["srcA": activity(0.95, seconds: 100), "srcB": activity(0.3, seconds: 20),
                                             "srcD": activity(1, seconds: 600)])),
            (F.library, try log("macbbbbb", ["srcA": activity(0.4, seconds: 60)])),
            (F.library, try MobileSyncFixture.envelope(.highlight, "hl_b", [
                "sourceID": "srcB", "locator": .object(["t": "text", "quote": "Fission."]), "text": "Fission.",
                "createdAt": SyncJSON(at), "editedAt": SyncJSON(at),
            ])),
        ], to: replica)
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        #expect(snapshot.placements.isEmpty, "none of them is on the Schedule")
        #expect(snapshot.activityDays["srcA"]?.first?.engagedSeconds == 160)

        let inputs = MobileCloudSourceCatalog.memoryReviewInputs(snapshot)
        #expect(inputs.sources.first { $0.id == "srcB" }?.annotationCount == 1)
        let candidates = MemoryReviewCandidates.candidates(sources: inputs.sources, activityDays: inputs.activityDays,
                                                           sessions: inputs.sessions, now: now)
        #expect(candidates.map(\.sourceID) == ["srcA", "srcB"], "nothing logged on srcC, and an archived source is not reviewed")
        #expect(candidates.first { $0.sourceID == "srcA" }?.confidence == .complete, "both devices' seconds are added")
        #expect(candidates.first { $0.sourceID == "srcB" }?.confidence == .substantial, "a partial read lifted by its highlight")
        #expect(candidates.first?.consumedAt == noon)
    }
}

/// The Memory feature on a switched phone (docs/cloudkit-schema-design.md §3.5.22, §3.5.23, §10, §14.2 WP19b,
/// WP20b): its cards, the answers about them, the sources a review names and the ideas it is graded
/// against, read from the replica where generation 1 read the zone mirror. Run against the real catalog
/// over a replica a phone synced, so the screens' own reads are what is under test.
@Suite("iPhone memory reads under generation 2", .serialized)
struct MobileSwitchedMemoryTests {
    typealias Sitting = MobileSittingRecorderTests
    typealias F = MobileReadModelFixture
    static let now = Sitting.now

    /// A card with a face, anchored on `src1`, so the phone may ask it.
    static func item(_ id: String, source: String = "src1") -> MemoryItem {
        MemoryItem(id: id, kind: .concept, target: "GDF15 binds GFRAL",
                   rubricJSON: "{\"card\":{\"cardID\":\"\(id)\",\"front\":\"What binds GDF15?\",\"origin\":\"manual\"},\"criteria\":[]}",
                   sources: [MemoryItemSource(id: "\(id)-a", memoryItemID: id, sourceID: source, excerpt: "GFRAL", sourceSHA256: "h", sortIndex: 0)],
                   createdAt: now, updatedAt: now)
    }

    /// The catalog a switched phone reads, over `phone`'s replica.
    static func catalog(_ phone: MobileTestDevice, _ writer: MobileRecordWriter) -> MobileCloudSourceCatalog {
        MobileCloudSourceCatalog(projection: { phone.projection }, ideas: MobileSourceIdeaStore(writer: { writer }))
    }

    /// Another device's card and its answer, as the Mac writes them.
    static func macCard(_ id: String, source: String) throws -> [(String, SyncEnvelope)] {
        let kept = MobileMemoryRecords.kept(from: item(id, source: source))
        let answer = MobileMemoryRecords.answer(for: Sitting.attempt("att-mac", item: id, session: nil, at: now.addingTimeInterval(-86_400 * 3)),
                                                curriculumFingerprint: "fp-mac")
        return [
            (F.library, try MobileSyncFixture.envelope(.card, id, [
                "status": .string("kept"), "deckSourceID": .string(source), "origin": .string("manual"), "kept": kept,
                "keptAt": SyncJSON(SyncTime.milliseconds(now)),
            ])),
            (F.library, try MobileSyncFixture.envelope(.sitting, "sit-mac", [
                "deviceID": .string("macbbbbb"), "kind": .string("cards"), "part": SyncJSON(1),
                "startedAt": SyncJSON(SyncTime.milliseconds(now.addingTimeInterval(-86_400 * 3))), "answers": .object(["att-mac": answer]),
            ])),
        ]
    }

    @Test("The catalog serves the cards this phone kept and another device kept, and every answer about them, from the replica")
    func cardsAndAnswers() async throws {
        let (_, phone, writer) = try await Sitting.phoneWithBlobs()
        let recorder = MobileMemoryAttemptRecorder(writer: { writer })
        _ = try await recorder.recordKeeping(Self.item("card1"), sourceIdentities: [],
                                             firstAttempt: Sitting.attempt("att1", item: "card1", session: nil))
        try await MobileSyncFixture.apply(try Self.macCard("card2", source: "src2"), to: phone.replica)

        let catalog = Self.catalog(phone, writer)
        _ = try await catalog.loadSources(forceRefresh: true)

        #expect(await catalog.currentMemoryItems().map(\.id).sorted() == ["card1", "card2"], "the phone's own Card and the Mac's")
        #expect(await catalog.currentMemoryAttempts().map(\.id) == ["att-mac", "att1"], "oldest answer first")
        let context = try #require(await catalog.currentCardAnswerContext(memoryItemID: "card1"), "an answer can be decided on a switched phone")
        #expect(context.history.map(\.id) == ["att1"])
        #expect(context.item.target == "GDF15 binds GFRAL")
        #expect(await catalog.currentCardAnswerContext(memoryItemID: "nope") == nil)
        #expect(await catalog.currentCardReviewNotebookIDs() == ["nb1"])

        let listed = await catalog.currentKeptCardListings().map(\.id).sorted()
        #expect(listed == ["card1", "card2"], "All Cards lists what the replica holds")
        let held = await catalog.currentMnemonicReadingHeld(itemIDs: ["card2"])
        #expect(held.items.map(\.id) == ["card2"] && held.attempts.map(\.id) == ["att-mac"])

        // Card 1 sits in notebook nb1 through its source; card 2's source is in none.
        let counts = try #require(await catalog.currentNotebookCardCounts(notebookID: "nb1", now: Self.now, budgetMinutes: nil, newPerDay: 5))
        #expect(counts.kept == 1)
        #expect(await catalog.currentNotebookCardCounts(notebookID: "ghost", now: Self.now, budgetMinutes: nil, newPerDay: 5) == nil)
        let practice = try #require(await catalog.currentNotebookPractice(notebookID: "nb1", now: Self.now))
        #expect(practice.entries.map(\.item.id) == ["card1"])
        // Card 2 was answered three days ago and is due; card 1 was answered just now.
        let due = await catalog.currentDueMemoryItems(now: Self.now.addingTimeInterval(86_400 * 2), limit: 12).map(\.item.id)
        #expect(due.contains("card2"))
    }

    @Test("An answer the phone writes joins what the catalog holds at once, and survives the next replica load")
    func ownAnswers() async throws {
        let (_, phone, writer) = try await Sitting.phoneWithBlobs()
        let recorder = MobileMemoryAttemptRecorder(writer: { writer })
        _ = try await recorder.recordKeeping(Self.item("card1"), sourceIdentities: [],
                                             firstAttempt: Sitting.attempt("att1", item: "card1", session: nil))
        let catalog = Self.catalog(phone, writer)
        _ = try await catalog.loadSources(forceRefresh: true)
        #expect(await catalog.currentCardAnswerContext(memoryItemID: "card1")?.history.map(\.id) == ["att1"])

        let second = Sitting.attempt("att2", item: "card1", session: nil, at: Self.now.addingTimeInterval(3_600))
        #expect(try await recorder.recordSelfGraded(second, parentCurriculumFingerprint: "fp1") == .recorded)
        await catalog.noteRecordedMemoryAttempt(second, recordName: MobileMemoryAttemptRecorder.recordName(for: "att2"))
        #expect(await catalog.currentCardAnswerContext(memoryItemID: "card1")?.history.map(\.id).sorted() == ["att1", "att2"])

        _ = try await catalog.loadSources(forceRefresh: true)
        #expect(await catalog.currentCardAnswerContext(memoryItemID: "card1")?.history.map(\.id).sorted() == ["att1", "att2"],
                "the replica holds the written answer, so a reload keeps it")
    }

    @Test("A review's sources are read from the replica, hidden ones stay named but not available, and a finished chat's sources count as reviewed")
    func sourcesByID() async throws {
        let (_, phone, writer) = try await Sitting.phoneWithBlobs()
        try await MobileSyncFixture.apply([
            (F.library, try F.mark("hidden", "src:src2")),
            (F.library, try F.chat("ch-done", notebook: "nb1", edited: 5, ["status": .string("ended"), "contextMode": .string("explicit"),
                                                                         "contextSourceIDs": F.set(["src1"])])),
            (F.library, try F.chat("ch-live", notebook: "nb1", edited: 6, ["contextMode": .string("explicit"), "contextSourceIDs": F.set(["src2"])])),
        ], to: phone.replica)
        let catalog = Self.catalog(phone, writer)
        _ = try await catalog.loadSources(forceRefresh: true)

        #expect(await catalog.currentSources(ids: ["src1", "src2", "missing"]).map(\.id) == ["src1", "src2"])
        #expect(await catalog.currentAvailableSources(ids: ["src1", "src2", "missing"]).map(\.id) == ["src1"], "a hidden source is not activated")
        #expect(await catalog.currentReviewedSourceIDs() == ["src1"], "a running chat reviews nothing yet")
    }

    @Test("The grader's ideas on a switched phone are the sources' ideas satellites")
    func ideasForGrading() async throws {
        let (_, phone, writer) = try await Sitting.phoneWithBlobs()
        let store = MobileSourceIdeaStore(writer: { writer })
        let ideas = (0..<2).map { index in
            SourceIdea(id: "idea-\(index)", sourceID: "src1", statement: "Idea \(index)", recallNote: "Note", contentHash: "h", status: .active,
                       sortIndex: index, createdAt: Self.now, updatedAt: Self.now)
        }
        try await store.save(ideas, sourceIdentity: ["sourceID": "src1"])
        let catalog = Self.catalog(phone, writer)
        _ = try await catalog.loadSources(forceRefresh: true)
        #expect(await catalog.currentSourceIdeas(sourceIDs: ["src1", "src2"]).mapValues { $0.map(\.id) } == ["src1": ["idea-0", "idea-1"]],
                "without these the grader has nothing to grade against and rejects every answer")
    }

    @Test("The cards and answers are decoded once: a library read again for a rename keeps them, and what another device writes next is read at the next load")
    func decodedUntilSomethingArrives() async throws {
        let (_, phone, writer) = try await Sitting.phoneWithBlobs()
        try await MobileSyncFixture.apply(try Self.macCard("card2", source: "src1"), to: phone.replica)
        let catalog = Self.catalog(phone, writer)
        _ = try await catalog.loadSources(forceRefresh: true)
        #expect(await catalog.currentMemoryAttempts().map(\.id) == ["att-mac"])

        phone.replica.resetDecodeCount()
        _ = try await catalog.loadSources(forceRefresh: true)
        #expect(await catalog.currentMemoryAttempts().map(\.id) == ["att-mac"])
        #expect(await catalog.currentMemoryItems().map(\.id) == ["card2"])
        #expect(phone.replica.decodedRecords == 0, "nothing arrived, so no card and no sitting is decoded again")

        // The Mac's sitting gains an answer, as a later sync round delivers it.
        let first = MobileMemoryRecords.answer(for: Sitting.attempt("att-mac", item: "card2", session: nil, at: Self.now.addingTimeInterval(-86_400 * 3)),
                                               curriculumFingerprint: "fp-mac")
        let second = MobileMemoryRecords.answer(for: Sitting.attempt("att-mac-2", item: "card2", session: nil, at: Self.now), curriculumFingerprint: "fp-mac")
        try await MobileSyncFixture.apply([(F.library, try MobileSyncFixture.envelope(.sitting, "sit-mac", [
            "deviceID": .string("macbbbbb"), "kind": .string("cards"), "part": SyncJSON(1),
            "startedAt": SyncJSON(SyncTime.milliseconds(Self.now.addingTimeInterval(-86_400 * 3))),
            "answers": .object(["att-mac": first, "att-mac-2": second]),
        ]))], to: phone.replica)
        #expect(await catalog.currentMemoryAttempts().map(\.id) == ["att-mac", "att-mac-2"], "the arrival is seen without waiting for a load")
    }

    @Test("An answer reads back as the attempt it was written from")
    func answerRoundTrip() throws {
        let graded = Sitting.attempt("att1", item: "card1", session: "memory-2027-01-15")
        let answer = MobileMemoryRecords.answer(for: graded, curriculumFingerprint: "fp1")
        let object = try #require(answer.objectValue)
        let read = try #require(MobileMemoryRecords.attempt(answerID: "att1", answer: object, sessionID: "memory-2027-01-15"))
        #expect(read.memoryItemID == "card1" && read.sessionID == "memory-2027-01-15" && read.scheduleRating == .good)
        #expect(read.score == 1 && read.gradeState == .graded && read.feedback == graded.feedback)
        #expect(read.attemptedAt == graded.attemptedAt && read.modelID == "model-a" && read.exchangeID == graded.exchangeID)
        // A practice answer that counted for nothing is no attempt, and nor is an answer about anything but a card.
        #expect(MobileMemoryRecords.attempt(answerID: "p", answer: ["subject": "crd:card1", "at": SyncJSON(1), "counted": .bool(false)], sessionID: nil) == nil)
        #expect(MobileMemoryRecords.attempt(answerID: "q", answer: ["subject": "qst:x", "at": SyncJSON(1)], sessionID: nil) == nil)
    }
}
