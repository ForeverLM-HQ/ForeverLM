import Foundation
import Testing
@testable import ForeverLM

/// The Sitting record (docs/cloudkit-schema-design.md §3.5.23): one writer, answers written once each,
/// parts at 200 answers or the byte limit, uncounted answers kept, and the migrated history under
/// deterministic ids that two Macs derive alike, quiz scores included.
@Suite("Sitting projection")
struct SittingProjectionTests {
    private typealias F = MemorySyncFixture

    private static func answer(_ card: String, at: Int64, rating: String? = "good", counted: Bool = true, gradeState: String? = "graded",
                               response: String = "Four") -> SyncJSON {
        var answer: [String: SyncJSON] = [
            "subject": .string("crd:" + card), "at": SyncJSON(at), "prompt": "How many?", "response": .string(response),
            "counted": .bool(counted), "practice": false,
        ]
        if let rating { answer["rating"] = .string(rating) }
        if let gradeState { answer["gradeState"] = .string(gradeState) }
        return .object(answer)
    }

    @Test("This Mac's sitting goes out with its answers; another device's is projected and never sent back")
    func singleWriter() throws {
        let (root, store) = try F.makeStore("sitting-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let at = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try store.execute("INSERT INTO memory_sittings (id, device_id, kind, started_at, part) VALUES ('mine', ?, 'cards', ?, 1)",
                          [.text(F.deviceID), .real(at.timeIntervalSinceReferenceDate)])
        let answer = MemoryAnswerCodec.answer(
            for: MemoryAttempt(id: "a-1", memoryItemID: "card-1", prompt: "How many?", learnerAnswer: "Four", scheduleRating: .good,
                               gradeState: .graded, attemptedAt: at),
            curriculumFingerprint: "fp"
        )
        try store.appendAnswer("a-1", answer: answer, at: at, toSittingStartingWith: "mine", newSitting: (F.deviceID, "cards", nil))

        let mine = try #require(F.fields(try F.pending(store)["Sitting:mine"]))
        #expect(mine["deviceID"] == .string(F.deviceID) && mine["kind"] == "cards" && mine["part"] == 1)
        #expect(mine["answers"]?["a-1"] == answer, "the answer as written, once")
        #expect(mine["answers"]?["a-1"]?["counted"] == true && mine["answers"]?["a-1"]?["curriculumFingerprint"] == "fp")

        try F.apply(store, [try F.record(.sitting, "theirs", [
            "deviceID": "iphoneaa", "kind": "memoryReview", "startedAt": SyncJSON(Int64(1_759_000_000_000)), "part": 1, "chatID": "chat-9",
            "answers": .object(["b-1": Self.answer("card-1", at: 1_759_000_100_000)]),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sittings WHERE id = 'theirs' AND device_id = 'iphoneaa'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_attempts WHERE id = 'b-1' AND session_id = 'chat-9' AND schedule_rating = 'good'") == 1)
        // Touched here by mistake, it still never goes out: it has one writer, and it is not this Mac.
        try store.execute("UPDATE memory_sittings SET ended_at = 1 WHERE id = 'theirs'")
        #expect(try F.pending(store)["Sitting:theirs"] == nil)
    }

    @Test("A bout brought in from another device is never re-sent under this Mac's id by a local touch")
    func inboundBoutStaysTheirs() throws {
        let (root, store) = try F.makeStore("sitting-bout-theirs")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try F.record(.sitting, "bout-1", [
            "deviceID": "iphoneaa", "kind": "bout", "startedAt": SyncJSON(Int64(1_759_000_000_000)), "part": 1,
            "scope": .object(["title": .string("Read the chapter"), "plannedMinutes": SyncJSON(25)]),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_bouts WHERE id = 'bout-1'") == 1)
        try store.execute("UPDATE learning_bouts SET learned = 'ATP synthase is a rotor' WHERE id = 'bout-1'")
        #expect(try F.pending(store)["Sitting:bout-1"] == nil, "the bout has one writer, and it is not this Mac")
    }

    @Test("An attempt the learner deleted here is not made again when its Sitting arrives again")
    func deletedAttemptStaysDeleted() throws {
        let (root, store) = try F.makeStore("sitting-deleted-attempt")
        defer { try? FileManager.default.removeItem(at: root) }
        func sitting(ended: Int64?) throws -> ReplicaRecord {
            var fields: [String: SyncJSON] = [
                "deviceID": "iphoneaa", "kind": "memoryReview", "startedAt": SyncJSON(Int64(1_759_000_000_000)), "part": 1,
                "answers": .object(["b-1": Self.answer("card-1", at: 1_759_000_100_000)]),
            ]
            if let ended { fields["endedAt"] = SyncJSON(ended) }
            return try F.record(.sitting, "theirs", fields)
        }
        try F.apply(store, [try sitting(ended: nil)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_attempts WHERE id = 'b-1'") == 1)
        try store.execute("DELETE FROM memory_attempts WHERE id = 'b-1'")
        try F.apply(store, [try sitting(ended: 1_759_000_200_000)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sittings WHERE id = 'theirs' AND ended_at IS NOT NULL") == 1, "the Sitting itself updated")
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_attempts WHERE id = 'b-1'") == 0, "the deleted attempt is not resurrected")
    }

    @Test("A sitting continues in a new part at 200 answers, and at the byte limit")
    func parts() throws {
        let (root, store) = try F.makeStore("sitting-parts")
        defer { try? FileManager.default.removeItem(at: root) }
        let at = Date(timeIntervalSinceReferenceDate: 780_000_000)
        for index in 0..<205 {
            try store.appendAnswer("a-\(index)", answer: Self.answer("card-\(index % 7)", at: 1_759_000_000_000 + Int64(index)),
                                   at: at.addingTimeInterval(Double(index)), toSittingStartingWith: "long", newSitting: (F.deviceID, "cards", nil))
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sitting_answers WHERE sitting_id = 'long'") == 200)
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sitting_answers WHERE sitting_id = 'long#2'") == 5)
        #expect(try F.text(store, "SELECT part || '|' || device_id || '|' || kind FROM memory_sittings WHERE id = 'long#2'") == "2|\(F.deviceID)|cards")
        let pending = try F.pending(store)
        #expect(F.fields(pending["Sitting:long"])?["answers"]?.objectValue?.count == 200)
        #expect(F.fields(pending["Sitting:long#2"])?["part"] == 2)

        // Long answers fill a part by bytes first: 100 KiB of answer JSON at most.
        let wordy = String(repeating: "mitochondria ", count: 2_400)
        for index in 0..<5 {
            try store.appendAnswer("w-\(index)", answer: Self.answer("card-1", at: 1_759_000_000_000, response: wordy), at: at,
                                   toSittingStartingWith: "wordy", newSitting: (F.deviceID, "cards", nil))
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sittings WHERE id = 'wordy' OR id LIKE 'wordy#%'") == 2)
        #expect(try F.count(store, "SELECT COALESCE(MAX(s), 0) FROM (SELECT SUM(length(answer_json)) AS s FROM memory_sitting_answers WHERE sitting_id LIKE 'wordy%' GROUP BY sitting_id)") <= KnowledgeStore.sittingPartAnswerBytes)
        // The limit counts bytes, not characters: answers in a script of three-byte characters fill a part too.
        let multibyte = String(repeating: "\u{7DDA}\u{7C92}\u{4F53} ", count: 2_400)
        for index in 0..<5 {
            try store.appendAnswer("m-\(index)", answer: Self.answer("card-1", at: 1_759_000_000_000, response: multibyte), at: at,
                                   toSittingStartingWith: "multi", newSitting: (F.deviceID, "cards", nil))
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sittings WHERE id = 'multi' OR id LIKE 'multi#%'") >= 2)
        #expect(try F.count(store, "SELECT COALESCE(MAX(s), 0) FROM (SELECT SUM(length(CAST(answer_json AS BLOB))) AS s FROM memory_sitting_answers WHERE sitting_id LIKE 'multi%' GROUP BY sitting_id)") <= KnowledgeStore.sittingPartAnswerBytes)
        // An answer is written once: the same id again adds nothing.
        #expect(try store.appendAnswer("a-0", answer: Self.answer("card-0", at: 1), at: at, toSittingStartingWith: "long", newSitting: (F.deviceID, "cards", nil)) == nil)
    }

    @Test("Answers that did not count are kept; only those with a grade or that count become attempts")
    func uncountedAnswersKept() throws {
        let (root, store) = try F.makeStore("sitting-uncounted")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try F.record(.sitting, "web-sitting", [
            "deviceID": "webaaaaa", "kind": "memoryReview", "startedAt": SyncJSON(Int64(1_759_000_000_000)), "part": 1,
            "answers": .object([
                "practice-1": Self.answer("card-1", at: 1_759_000_001_000, rating: "good", counted: false, gradeState: nil),
                "failed-1": Self.answer("card-1", at: 1_759_000_002_000, rating: nil, counted: false, gradeState: "failed"),
                "graded-1": Self.answer("card-1", at: 1_759_000_003_000),
                "quiz-1": ["subject": "qz:cq-1#q3", "at": 1_759_000_004_000, "correct": false, "counted": true, "practice": false],
            ]),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sitting_answers WHERE sitting_id = 'web-sitting'") == 4, "every answer kept")
        #expect(try F.text(store, "SELECT group_concat(id || ':' || grade_state, ',') FROM (SELECT id, grade_state FROM memory_attempts ORDER BY id)")
                == "failed-1:failed,graded-1:graded")
        #expect(try F.count(store, "SELECT counted FROM memory_sitting_answers WHERE answer_id = 'practice-1'") == 0)
        #expect(try F.text(store, "SELECT subject FROM memory_sitting_answers WHERE answer_id = 'quiz-1'") == "qz:cq-1#q3")
    }

    @Test("Migrated attempts get the same Sittings on two Macs, by chat or by day, and quiz scores one each")
    func legacyIDsOnTwoMacs() throws {
        func mac(_ name: String) throws -> (URL, KnowledgeStore) {
            let (root, store) = try F.makeStore(name, triggers: false)
            try F.item(store, id: "item-1")
            // Two days without a chat, one memory review chat; the same rows on both Macs.
            try F.attempt(store, id: "att-1", item: "item-1", at: 780_000_000)
            try F.attempt(store, id: "att-2", item: "item-1", at: 780_000_600, rating: "again")
            try F.attempt(store, id: "att-3", item: "item-1", at: 780_200_000)
            try F.attempt(store, id: "att-4", item: "item-1", at: 780_300_000, session: "memory-2026-09-20")
            try F.preference(store, key: "courseQuiz.score.cq-1", value: ["right": 3, "total": 4, "takenAt": 1_759_000_000.0])
            try F.preference(store, key: "lectureQuiz.score.src-9", value: ["right": 1, "total": 4, "takenAt": 1_758_000_000.0, "passedAt": 1_757_000_000.0])
            for step in KnowledgeStore.memoryActivationDerivations { try step.run(store) }
            return (root, store)
        }
        let (rootA, a) = try mac("legacy-a")
        let (rootB, b) = try mac("legacy-b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let rows = "SELECT group_concat(sitting_id || '<' || answer_id || '>' || answer_json, char(10)) FROM (SELECT * FROM memory_sitting_answers ORDER BY answer_id)"
        let sittings = "SELECT group_concat(id || '|' || device_id || '|' || kind || '|' || COALESCE(chat_id, '') || '|' || COALESCE(result_json, ''), char(10)) FROM (SELECT * FROM memory_sittings ORDER BY id)"
        #expect(try F.text(a, rows) == F.text(b, rows))
        #expect(try F.text(a, sittings) == F.text(b, sittings))

        let day1 = SyncIdentity.migratedSittingID("day:" + F.day(780_000_000))
        let day2 = SyncIdentity.migratedSittingID("day:" + F.day(780_200_000))
        let chat = SyncIdentity.migratedSittingID("session:memory-2026-09-20")
        #expect(try F.text(a, "SELECT group_concat(answer_id, ',') FROM (SELECT answer_id FROM memory_sitting_answers WHERE sitting_id = ? ORDER BY answer_id)", [.text(day1)]) == "att-1,att-2")
        #expect(try F.text(a, "SELECT sitting_id FROM memory_sitting_answers WHERE answer_id = 'att-3'") == day2)
        #expect(try F.text(a, "SELECT kind || '|' || chat_id || '|' || device_id FROM memory_sittings WHERE id = ?", [.text(chat)]) == "memoryReview|memory-2026-09-20|legacy22")

        let quiz = SyncIdentity.migratedSittingID("quiz:courseQuiz:courseQuiz.score.cq-1")
        let result = try #require(try F.text(a, "SELECT result_json FROM memory_sittings WHERE id = ?", [.text(quiz)]))
        let parsed = try SyncJSON(parsing: Data(result.utf8))
        #expect(parsed["right"] == 3 && parsed["of"] == 4 && parsed["passed"] == true)
        #expect(try F.text(a, "SELECT kind || '|' || scope_json FROM memory_sittings WHERE id = ?", [.text(quiz)]) == "courseQuiz|{\"quizID\":\"cq-1\"}")
        let lecture = SyncIdentity.migratedSittingID("quiz:lectureQuiz:lectureQuiz.score.src-9")
        let lectureResult = try SyncJSON(parsing: Data((try F.text(a, "SELECT result_json FROM memory_sittings WHERE id = ?", [.text(lecture)]) ?? "").utf8))
        #expect(lectureResult["passed"] == false && lectureResult["passedAt"] == SyncJSON(SyncTime.milliseconds(Date(timeIntervalSince1970: 1_757_000_000))),
                "a failed retake keeps the first pass")

        // Run again, and after a generation-1 attempt: the history only grows, under the same ids.
        try F.attempt(a, id: "att-5", item: "item-1", at: 780_000_900)
        for step in KnowledgeStore.memoryActivationDerivations { try step.run(a) }
        #expect(try F.text(a, "SELECT sitting_id FROM memory_sitting_answers WHERE answer_id = 'att-5'") == day1)
        #expect(try F.count(a, "SELECT COUNT(*) FROM memory_sitting_answers") == 5)
    }

    @Test("An inbound card answer schedules its card; an answer held already is never rewritten")
    func inboundAnswersSchedule() throws {
        let (root, store) = try F.makeStore("sitting-schedule")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.replica.apply { _ in try F.item(store, id: "card-1", createdAt: 780_000_000) }
        try F.apply(store, [try F.record(.sitting, "s-1", [
            "deviceID": "iphoneaa", "kind": "cards", "startedAt": SyncJSON(Int64(1_759_000_000_000)), "part": 1,
            "answers": .object(["x-1": Self.answer("card-1", at: SyncTime.milliseconds(cocoaSeconds: 780_200_000))]),
        ])])
        #expect(try F.count(store, "SELECT repetition_count FROM memory_schedules WHERE memory_item_id = 'card-1'") == 1)
        let before = try F.text(store, "SELECT answer_json FROM memory_sitting_answers WHERE answer_id = 'x-1'")
        try F.apply(store, [try F.record(.sitting, "s-1", [
            "deviceID": "iphoneaa", "kind": "cards", "startedAt": SyncJSON(Int64(1_759_000_000_000)), "part": 1,
            "answers": .object(["x-1": Self.answer("card-1", at: 1, rating: "again")]),
        ])])
        #expect(try F.text(store, "SELECT answer_json FROM memory_sitting_answers WHERE answer_id = 'x-1'") == before)
        #expect(try F.text(store, "SELECT schedule_rating FROM memory_attempts WHERE id = 'x-1'") == "good")
    }

    @Test("Under generation 2 an attempt made here joins this device's Sitting: the chat's, or the day's cards")
    func generation2Recorder() throws {
        let (root, store) = try F.makeStore("sitting-recorder")
        defer { try? FileManager.default.removeItem(at: root) }
        let morning = Date(timeIntervalSinceReferenceDate: 780_000_000)
        func attempt(_ id: String, at: Date, session: String? = nil) -> MemoryAttempt {
            MemoryAttempt(id: id, memoryItemID: "card-1", sessionID: session, prompt: "Q", learnerAnswer: "A",
                          scheduleRating: .good, gradeState: .graded, attemptedAt: at)
        }
        try store.recordSittingAnswer(attempt("r-1", at: morning), curriculumFingerprint: nil)
        try store.recordSittingAnswer(attempt("r-2", at: morning.addingTimeInterval(60)), curriculumFingerprint: nil)
        try store.recordSittingAnswer(attempt("r-3", at: morning.addingTimeInterval(120), session: "memory-chat"), curriculumFingerprint: nil)
        try store.recordSittingAnswer(attempt("r-4", at: morning.addingTimeInterval(180), session: "memory-chat"), curriculumFingerprint: nil)
        #expect(try F.count(store, "SELECT COUNT(DISTINCT sitting_id) FROM memory_sitting_answers WHERE answer_id IN ('r-1', 'r-2')") == 1)
        #expect(try F.count(store, "SELECT COUNT(DISTINCT sitting_id) FROM memory_sitting_answers WHERE answer_id IN ('r-3', 'r-4')") == 1)
        #expect(try F.text(store, "SELECT kind || '|' || device_id FROM memory_sittings WHERE chat_id = 'memory-chat'") == "memoryReview|\(F.deviceID)")
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sittings") == 2)

        // Not activated yet: the activation will derive these from the attempts, so nothing is recorded twice.
        let (rootB, unactivated) = try F.makeStore("sitting-recorder-b", activated: false)
        defer { try? FileManager.default.removeItem(at: rootB) }
        try unactivated.recordSittingAnswer(attempt("r-9", at: morning), curriculumFingerprint: nil)
        #expect(try F.count(unactivated, "SELECT COUNT(*) FROM memory_sitting_answers") == 0)
    }
}
