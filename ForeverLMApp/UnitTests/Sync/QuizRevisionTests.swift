import Foundation
import Testing
@testable import ForeverLM

/// A quiz's revision and its satellites (docs/cloudkit-schema-design.md §3.5.11, §8d, WP9): a save that
/// changes the questions counts a revision under generation 2 and no other save does; generation 1
/// counts nothing; the questions and the drawing travel as satellites laid out from the row; and an
/// inbound quiz whose questions this Mac has not fetched yet never has its questions overwritten by a
/// local edit.
@Suite("Quiz revision")
struct QuizRevisionTests {
    typealias F = NotebookSyncFixture
    typealias C = CourseSyncFixture

    private static func quiz(_ questions: [String], title: String = "Motifs", author: CourseQuiz.Author = .foreverlm) -> CourseQuiz {
        CourseQuiz(
            id: "cq-1", courseID: "crs-1", kind: .practice, title: title, lectureIDs: ["lec-1"], afterLectureID: "lec-1",
            questions: questions.enumerated().map { index, text in
                CourseQuizQuestion(
                    id: "q\(index + 1)", sourceID: "src-video", firstLine: index, lastLine: index, startSeconds: nil,
                    question: text, answer: "Answer \(index + 1).", keyPoints: [], quote: nil
                )
            },
            author: author,
            createdAt: Date(timeIntervalSinceReferenceDate: 300),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )
    }

    private static func revision(_ store: KnowledgeStore) throws -> Int64? {
        try store.scalarInteger("SELECT revision FROM course_quizzes WHERE id = 'cq-1'")
    }

    @Test("The same questions written with their keys in another order are no new revision")
    func sameQuestionsAreNoRevision() {
        let a = #"[{"id":"q1","question":"Why?","answer":"Because","keyPoints":["a","b"]}]"#
        let b = #"[ { "keyPoints" : ["a", "b"], "answer" : "Because", "question" : "Why?", "id" : "q1" } ]"#
        #expect(KnowledgeStore.sameQuestions(a, b))
        #expect(!KnowledgeStore.sameQuestions(a, #"[{"id":"q1","question":"Why not?","answer":"Because","keyPoints":["a","b"]}]"#))
        #expect(!KnowledgeStore.sameQuestions(a, #"[{"id":"q1","question":"Why?","answer":"Because","keyPoints":["b","a"]}]"#), "order of an array matters")
        #expect(!KnowledgeStore.sameQuestions(a, "[]"))
    }

    @Test("A save that changes the questions counts a revision; a rename or the same questions again counts none")
    func revisionCountsQuestionChanges() throws {
        let (root, store) = try F.makeStore("quiz-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-1", course: "crs-1", number: 1)
        try store.saveCourseQuiz(Self.quiz(["What is a motif?"]))
        #expect(try Self.revision(store) == 1)
        try F.sendAll(store)
        try store.saveCourseQuiz(Self.quiz(["What is a motif?"], title: "Network motifs"))
        #expect(try Self.revision(store) == 1, "a rename is no new revision")
        let renamed = try #require(try F.pending(store)["Quiz:cq-1"])
        #expect(Set(renamed.stamps.keys.map(\.field)) == ["title"])
        try F.sendAll(store)

        try store.saveCourseQuiz(Self.quiz(["What is a motif?", "Why a feed-forward loop?"], title: "Network motifs"))
        #expect(try Self.revision(store) == 2)
        let rewritten = try #require(F.savedFields(try F.pending(store)["Quiz:cq-1"]))
        #expect(rewritten["revision"] == SyncJSON(2) && rewritten["questionCount"] == SyncJSON(2))
        let held = try #require(try F.text(store, "SELECT questions_json FROM course_quizzes WHERE id = 'cq-1'"))
        #expect(rewritten["questions"].flatMap(FileRef.init(json:))?.hash == SyncIdentity.sha256Hex(Data(held.utf8)))
        try F.sendAll(store)
        try store.saveCourseQuiz(Self.quiz(["What is a motif?", "Why a feed-forward loop?"], title: "Network motifs"))
        #expect(try Self.revision(store) == 2, "the same questions again are no new revision")
        #expect(try F.pending(store).isEmpty)
    }

    @Test("The drawing is the quiz's picture satellite, and an assistant's quiz is the learner's")
    func pictureAndAuthor() throws {
        let (root, store) = try F.makeStore("quiz-picture")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try C.addQuiz(store, "cq-1", course: "crs-1", after: nil, covers: [], author: "assistant", artwork: jpeg)
        let fields = try #require(F.savedFields(try F.pending(store)["Quiz:cq-1"]))
        #expect(fields["author"] == .string("learner"))
        #expect(fields["lessonID"] == nil || fields["lessonID"] == .null, "a quiz that follows no lesson ends the course")
        let picture = try #require(fields["pictures"]?[QuizSatellites.artworkKey].flatMap(FileRef.init(json:)))
        #expect(picture.role == "picture.artwork" && picture.mime == "image/jpeg" && picture.encoding == "identity")
        #expect(picture.hash == SyncIdentity.sha256Hex(jpeg) && picture.owner == "cq-1")
        try F.sendAll(store)

        try store.execute("UPDATE course_quizzes SET artwork = NULL WHERE id = 'cq-1'")
        let cleared = try #require(F.savedFields(try F.pending(store)["Quiz:cq-1"]))
        #expect(cleared["pictures"]?[QuizSatellites.artworkKey] == .null, "removing the drawing removes its element")

        // An inbound record keeps the learner as an assistant's quiz here.
        try F.apply(store, [try F.record(.quiz, "cq-2", [
            "courseID": .string("crs-1"), "kind": .string("checkpoint"), "title": .string("Checkpoint"), "author": .string("learner"),
            "revision": SyncJSON(1), "coversLessonIDs": .object(["lec-z": .bool(true)]), "createdAt": SyncJSON(Int64(1_758_000_000_000)),
        ])])
        #expect(try F.text(store, "SELECT author || '|' || kind || '|' || lecture_ids_json FROM course_quizzes WHERE id = 'cq-2'") == #"assistant|checkpoint|["lec-z"]"#)
    }

    @Test("Questions not fetched yet are held back from a local edit, then taken when their bytes arrive")
    func unfetchedQuestionsAreHeldBack() throws {
        let (root, store) = try F.makeStore("quiz-fetch")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-1", course: "crs-1", number: 1)
        try C.addQuiz(store, "cq-1", course: "crs-1", after: "lec-1", covers: ["lec-1"])
        try F.sendAll(store)

        // Another Mac rewrote the questions: revision 2, a new questions satellite this Mac has not fetched.
        let newQuestions = #"[{"id":"q2","question":"Why robustness?","answer":"Integral feedback","keyPoints":[]}]"#
        let file = try #require(QuizSatellites.questionsFile(quizID: "cq-1", json: newQuestions))
        var remote = try #require(try F.held(store, .quiz, "cq-1")).fields
        remote["questions"] = file.value
        remote["revision"] = SyncJSON(2)
        remote["questionCount"] = SyncJSON(1)
        try F.apply(store, [try F.record(.quiz, "cq-1", remote, ms: 1_800_000_000_000)])
        #expect(try Self.revision(store) == 2)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'quizSatellites' AND target = 'cq-1'") == 1)

        // A local rename sends the title and never the stale questions.
        try store.execute("UPDATE course_quizzes SET title = 'Robustness' WHERE id = 'cq-1'")
        let rename = try #require(try F.pending(store)["Quiz:cq-1"])
        #expect(Set(rename.stamps.keys.map(\.field)) == ["title"])
        #expect(F.savedFields(rename)?["questions"] == file.value)
        try F.sendAll(store)

        // The satellite reader writes the bytes in; the quiz then matches what the server holds.
        try store.replica.apply { _ in
            try QuizSatellites.received(Data(newQuestions.utf8), role: QuizSatellites.questionsRole, quizID: "cq-1", connection: store)
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'quizSatellites'") == 0)
        #expect(try F.text(store, "SELECT questions_json FROM course_quizzes WHERE id = 'cq-1'") == newQuestions)
        try store.execute("UPDATE course_quizzes SET symbol = 'bolt' WHERE id = 'cq-1'")
        #expect(Set(try #require(try F.pending(store)["Quiz:cq-1"]).stamps.keys.map(\.field)) == ["symbol"], "the questions are the server's")
    }
}
