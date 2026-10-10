import Foundation
import Testing
@testable import ForeverLM

/// What runs the activation's queues and the inbound satellites on the Mac (docs/cloudkit-schema-design.md
/// §13.3 step 4, §3.5.30): the drain lays out every source's pointers and every Understanding document in
/// bounded batches until the queues are empty, and the reader fetches the satellites inbound quizzes and
/// chats wait for and writes them into their rows.
@Suite("Sync backfill drain", .serialized)
struct SyncBackfillDrainTests {
    typealias F = NotebookSyncFixture
    typealias C = CourseSyncFixture

    @Test("The drain empties the source-files and Understanding queues, in batches")
    func drainsEveryQueue() async throws {
        let (root, store) = try MemorySyncFixture.makeStore("drain")
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent("understanding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: notes)
        }
        try F.quietly(store) {
            for index in 1...7 {
                let id = "src-\(index)"
                try F.addSource(store, id)
                try store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(id), .text("Body of \(id). " + String(repeating: "word ", count: 40))])
            }
        }
        try Data("# What I understand\nMotifs.".utf8).write(to: notes.appendingPathComponent("src-1.md"))
        try store.execute("""
            INSERT INTO source_understanding (source_id, relative_path, generated_at, generator_version, body_sha256, discussed_idea_ids)
            VALUES ('src-1', 'src-1.md', 10, 1, 'a', '[]')
        """)
        try store.queueSourceFilesBackfill()
        try store.queueUnderstandingBackfill()
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind IN ('sourceFiles', 'understanding')") == 8)

        KnowledgeStore.understandingRootOverride = notes.path
        defer { KnowledgeStore.understandingRootOverride = nil }
        let laid = await SyncBackfillDrain.run(store: .direct(store), batch: 3)
        #expect(laid == 8)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind IN ('sourceFiles', 'understanding')") == 0)
        #expect(try F.count(store, "SELECT COUNT(DISTINCT source_id) FROM source_files WHERE role = 'text'") == 7, "every source's text is a pointer")
        #expect(try F.count(store, "SELECT COUNT(*) FROM reading_states WHERE wire_id = 'src-1' AND understanding_json IS NOT NULL") == 1,
                "the Understanding document is the ReadingState's satellite")
    }

    @Test("The reader fetches an inbound quiz's questions and writes them into the row, and a wrong body is not taken")
    func readerWritesQuizQuestions() async throws {
        let (root, store) = try F.makeStore("reader-quiz")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-1", course: "crs-1", number: 1)
        try C.addQuiz(store, "cq-1", course: "crs-1", after: "lec-1", covers: ["lec-1"])
        try F.sendAll(store)
        let questions = #"[{"id":"q2","question":"Why robustness?","answer":"Integral feedback","keyPoints":[]}]"#
        let file = try #require(QuizSatellites.questionsFile(quizID: "cq-1", json: questions))
        var remote = try #require(try F.held(store, .quiz, "cq-1")).fields
        remote["questions"] = file.value
        remote["revision"] = SyncJSON(2)
        try F.apply(store, [try F.record(.quiz, "cq-1", remote, ms: 1_800_000_000_000)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'quizSatellites'") == 1)

        let wrong = SatelliteReader(store: .direct(store)) { _ in Data("[]".utf8) }
        #expect(await wrong.drain() == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'quizSatellites' AND attempts = 1") == 1, "a wrong body spends an attempt")

        let reader = SatelliteReader(store: .direct(store)) { _ in Data(questions.utf8) }
        #expect(await reader.drain() == 1)
        #expect(try F.text(store, "SELECT questions_json FROM course_quizzes WHERE id = 'cq-1'") == questions)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'quizSatellites'") == 0)
    }
}
