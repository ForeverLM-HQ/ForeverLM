import Foundation
import Testing
@testable import ForeverLM

/// The course quiz MCP tools (docs/lecture-quiz-design.md): save, read, list
/// in get_course, record a sitting, remove. Writing quizzes with a model is
/// covered by the planning suite; here only its refusals are.
@Suite("MCP course quiz tools", .serialized)
struct MCPCourseQuizToolTests {

    private func makeStore() throws -> (MCPDataStore, KnowledgeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_course_quiz_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), root)
    }

    /// A two-lecture course with a transcript source on the first lecture.
    private func seedCourse(_ knowledge: KnowledgeStore) throws -> (courseID: String, lectures: [CourseSession], sourceID: String) {
        try knowledge.saveCourseGroup(name: "bioenergetics", metadata: CourseMetadata(title: "Bioenergetics"))
        let one = CourseSession(courseName: "bioenergetics", number: 1, title: "Proton circuits")
        let two = CourseSession(courseName: "bioenergetics", number: 2, title: "Respirometry")
        try knowledge.saveCourseLecture(one)
        try knowledge.saveCourseLecture(two)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Proton circuits",
            sourceType: .video, discoveryOrigin: .manual, id: "video-one"
        )
        video.content = "[0:00] The proton circuit couples respiration to ATP synthesis through the membrane potential."
        video.state = .ready
        try knowledge.saveSource(video)
        _ = try knowledge.saveCourseLectureItem(CourseLectureItem(lectureId: one.id, sourceId: video.id, role: .video, sortIndex: 0))
        return ("bioenergetics", [one, two], video.id)
    }

    /// The one learning point every test question tests.
    private let learningPoints = ["The proton circuit couples respiration to ATP synthesis through the membrane potential."]

    private func question(_ text: String, sourceID: String? = nil, quote: String? = nil) -> [String: Any] {
        var question: [String: Any] = ["question": text, "answer": "The membrane potential.", "key_points": ["membrane potential"], "points": [1]]
        if let sourceID { question["source_id"] = sourceID }
        if let quote { question["quote"] = quote }
        return question
    }

    @Test("A saved checkpoint shows in get_course after its last lecture, and get_course_quiz hides answers unless asked")
    func saveAndRead() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)

        let saved = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "checkpoint",
            "title": "Quiz 1",
            "lecture_ids": seeded.lectures.map(\.id),
            "questions": [question("What couples respiration to ATP synthesis?", sourceID: seeded.sourceID,
                                   quote: "couples respiration to ATP synthesis through the membrane potential")],
        ])
        #expect(saved.contains("Saved Quiz 1"))
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        #expect(quiz.id == CourseQuizPlanning.checkpointID(courseID: seeded.courseID, lectureIDs: seeded.lectures.map(\.id)))
        #expect(quiz.author == .assistant)
        #expect(quiz.afterLectureID == seeded.lectures[1].id)

        let course = try store.getCourse(courseIdentifier: seeded.courseID)
        #expect(course.contains("quizzes: 1 (practice 0, checkpoint 1, test 0)"))
        #expect(course.contains("▸ Quiz 1 (quiz_id: \(quiz.id), kind: checkpoint, 1 questions, covers lectures 1–2"))
        #expect(course.contains("is the next quiz to complete"))
        let lectureTwoLine = try #require(course.range(of: "2. Respirometry"))
        let quizLine = try #require(course.range(of: "▸ Quiz 1"))
        #expect(lectureTwoLine.lowerBound < quizLine.lowerBound, "the checkpoint follows the last lecture it covers")

        let questionID = CourseQuizPlanning.questionID(sourceID: seeded.sourceID, question: "What couples respiration to ATP synthesis?")
        #expect(quiz.questions.map(\.id) == [questionID])
        let hidden = try store.getCourseQuiz(arguments: ["quiz_id": quiz.id])
        #expect(hidden.contains("[\(questionID)] What couples respiration to ATP synthesis?"))
        #expect(!hidden.contains("Answer:"))
        let shown = try store.getCourseQuiz(arguments: ["quiz_id": quiz.id, "include_answers": true])
        #expect(shown.contains("Answer: The membrane potential."))

        let scoreKey = LectureQuizScore.preferenceKey(courseQuizID: quiz.id)
        defer { UserDefaults.standard.removeObject(forKey: scoreKey) }
        UserDefaults.standard.set(
            LectureQuizScore(right: 0, total: 1, takenAt: Date()).preferenceValue,
            forKey: scoreKey
        )
        let completed = try store.getCourse(courseIdentifier: seeded.courseID)
        #expect(completed.contains("completed, not passed (1 right to pass; completion still opens the course)"))
        #expect(completed.contains("gate: every quiz is completed; nothing is locked"))
    }

    @Test("A question on a timed transcript is timed where its quote is said, over start_seconds, and a stored one is read out that way")
    func quoteTimesTheQuestion() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=bcdefghijkl", title: "Respirometry",
            sourceType: .video, discoveryOrigin: .manual, id: "video-two"
        )
        video.content = """
        [0:00] The proton circuit couples respiration to ATP synthesis through the membrane potential.

        [0:30] Oligomycin blocks the ATP synthase, so the proton current falls to the leak and respiration slows to match it.

        [1:00] Uncouplers carry protons back across the membrane and respiration rises to its maximum.
        """
        video.state = .ready
        try knowledge.saveSource(video)
        var slowed = question("What does oligomycin do to respiration?", sourceID: video.id, quote: "respiration slows to match it")
        slowed["start_seconds"] = 30
        let uncoupled = question("What do uncouplers do?", sourceID: video.id, quote: "Uncouplers carry protons back across the membrane")
        _ = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "practice", "lecture_ids": [seeded.lectures[1].id],
            "questions": [slowed, uncoupled],
        ])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        #expect(quiz.questions.map(\.startSeconds) == [49, 60], "0:49 where the quote is said, not the block's 0:30")

        // A quiz saved before quotes timed it keeps its block's time in the
        // store; an assistant reading it is sent where the quote is said.
        var early = quiz
        early.questions[0].startSeconds = 30
        try knowledge.saveCourseQuiz(early)
        let read = try store.getCourseQuiz(arguments: ["quiz_id": quiz.id])
        #expect(read.contains("at 0:49"))
        #expect(!read.contains("at 0:30"))
    }

    @Test("A practice quiz takes the ladder's place for its lecture, and saving again replaces it")
    func practiceReplaces() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        let arguments: [String: Any] = [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "practice",
            "lecture_ids": [seeded.lectures[0].id],
            "questions": [question("First?")],
        ]
        _ = try store.saveCourseQuiz(arguments: arguments)
        var again = arguments
        again["questions"] = [question("Second?"), question("Third?")]
        let replaced = try store.saveCourseQuiz(arguments: again)
        #expect(replaced.hasPrefix("Replaced"))
        let quizzes = try knowledge.loadCourseQuizzes(courseID: seeded.courseID)
        #expect(quizzes.count == 1)
        #expect(quizzes.first?.id == CourseQuizPlanning.practiceID(courseID: seeded.courseID, lectureID: seeded.lectures[0].id))
        #expect(quizzes.first?.questions.map(\.question) == ["Second?", "Third?"])
    }

    @Test("A rewritten quiz shows its current question count and labels an old short score as previous-version history")
    func rewrittenQuizLabelsOldScore() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        let base: [String: Any] = [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "practice", "lecture_ids": [seeded.lectures[0].id],
            "questions": [question("The old question?")],
        ]
        _ = try store.saveCourseQuiz(arguments: base)
        let quizID = CourseQuizPlanning.practiceID(courseID: seeded.courseID, lectureID: seeded.lectures[0].id)
        let scoreKey = LectureQuizScore.preferenceKey(courseQuizID: quizID)
        defer { UserDefaults.standard.removeObject(forKey: scoreKey) }
        UserDefaults.standard.set(
            LectureQuizScore(right: 1, total: 1, takenAt: Date()).preferenceValue,
            forKey: scoreKey
        )

        var rewritten = base
        rewritten["questions"] = [question("New question one?"), question("New question two?")]
        _ = try store.saveCourseQuiz(arguments: rewritten)
        let course = try store.getCourse(courseIdentifier: seeded.courseID)
        #expect(course.contains("2 questions"))
        #expect(course.contains("score: previous version 1 of 1 right"))
        #expect(course.contains("previous version completed"))
        #expect(!course.contains("not passed (1 right to pass; completion still opens the course)"))
        let quiz = try store.getCourseQuiz(arguments: ["quiz_id": quizID])
        #expect(quiz.contains("latest sitting: previous version: 1 of 1 right; current quiz has 2 questions"))
    }

    @Test("Bad input is refused by name")
    func refusals() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        #expect(throws: MCPError.self) {
            try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "practice", "lecture_ids": seeded.lectures.map(\.id), "questions": [question("Q?")]])
        }
        #expect(throws: MCPError.self) {
            try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "checkpoint", "lecture_ids": ["not-a-lecture"], "questions": [question("Q?")]])
        }
        #expect(throws: MCPError.self) {
            try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "quiz", "questions": [question("Q?")]])
        }
        #expect(throws: MCPError.self) {
            try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "test", "questions": [["question": "No answer"]]])
        }
        #expect(throws: MCPError.self) {
            try store.getCourseQuiz(arguments: ["quiz_id": "cq-missing"])
        }
    }

    @Test("A quiz lists its learning points first, and one left without a question is refused by name")
    func learningPointsCovered() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        let practice: [String: Any] = [
            "course_id": seeded.courseID, "kind": "practice",
            "lecture_ids": [seeded.lectures[0].id], "questions": [question("What couples respiration to ATP synthesis?")],
        ]
        #expect(throws: MCPError.self, "no learning points listed") {
            try store.saveCourseQuiz(arguments: practice)
        }
        var unnumbered = practice
        unnumbered["learning_points"] = learningPoints
        unnumbered["questions"] = [["question": "What couples respiration to ATP synthesis?", "answer": "The membrane potential."]]
        #expect(throws: MCPError.self, "a question names no learning point") {
            try store.saveCourseQuiz(arguments: unnumbered)
        }
        var outOfRange = practice
        outOfRange["learning_points"] = learningPoints
        outOfRange["questions"] = [question("What couples respiration to ATP synthesis?").merging(["points": [2]]) { $1 }]
        #expect(throws: MCPError.self, "a question names a point past the list") {
            try store.saveCourseQuiz(arguments: outOfRange)
        }
        var uncovered = practice
        uncovered["learning_points"] = learningPoints + ["Cardiolipin has four acyl chains, not two."]
        do {
            _ = try store.saveCourseQuiz(arguments: uncovered)
            Issue.record("a quiz with an untested learning point was saved")
        } catch let MCPError.invalidInput(message) {
            #expect(message.contains("1 of 2 learning points have no question"))
            #expect(message.contains("2. Cardiolipin has four acyl chains, not two."))
        }
        #expect(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).isEmpty, "nothing refused was saved")

        var covered = uncovered
        covered["questions"] = [
            question("What couples respiration to ATP synthesis?"),
            question("How many acyl chains does cardiolipin carry?").merging(["points": [2]]) { $1 },
        ]
        let saved = try store.saveCourseQuiz(arguments: covered)
        #expect(saved.contains("2 questions on 2 learning points"))
    }

    @Test("A sitting in the assistant's chat keeps the score and sends a miss to Memory")
    func recordResult() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        _ = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "test",
            "questions": [
                question("What couples respiration to ATP synthesis?", sourceID: seeded.sourceID,
                         quote: "couples respiration to ATP synthesis through the membrane potential"),
                question("A second question?"),
            ],
        ])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        let key = LectureQuizScore.preferenceKey(courseQuizID: quiz.id)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let answer = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id,
            "results": [["question_id": quiz.questions[0].id, "outcome": "incorrect", "answer": "ATP itself"]],
            "finish": true,
        ])
        #expect(answer.contains("Recorded Course test: 0 of 2 right"))
        #expect(answer.contains("Completed: what comes after this quiz in the course is open."))
        let score = try #require(UserDefaults.standard.object(forKey: key).flatMap(LectureQuizScore.init(preferenceValue:)))
        #expect(score.total == 2)
        #expect(score.right == 0)
        #expect(try knowledge.loadMemoryItems().count == 1, "the miss became a Memory item anchored to the quote")

        await #expect(throws: MCPError.self) {
            try await store.recordCourseQuizResult(arguments: ["quiz_id": quiz.id, "results": [["question_id": "q9", "outcome": "correct"]]])
        }
    }

    @Test("A question on a source with text is refused without a quote its text contains, and a quote of the page's words reaches Memory")
    func quotesAnchorInMemory() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        // The Wolf et al. cristae paper's text as it is stored: the PDF's
        // line ends kept, with a hyphen at each word they break.
        var paper = StudioArticle(url: "https://example.com/cristae", title: "Individual cristae", sourceType: .article, discoveryOrigin: .manual, id: "cristae")
        paper.normalizedURL = URLNormalizer.normalize(paper.url)
        paper.content = """
        Impairment of cristae structure through deletion of MICOS-
        complex components or Opa1 diminished this intramitochondrial
        heterogeneity of DΨm. We imaged the IMM using the LSM880 with Airyscan as well as STED micro-
        scopy.
        """
        paper.state = .ready
        try knowledge.saveSource(paper)
        func save(_ questions: [[String: Any]]) throws -> String {
            try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "test", "questions": questions])
        }

        do {
            _ = try save([
                question("What happened to the heterogeneity?", sourceID: paper.id),
                question("What couples respiration to ATP synthesis?", sourceID: seeded.sourceID, quote: "couples respiration to heat"),
                question("A question on no source?"),
            ])
            Issue.record("a quiz whose questions have no Memory anchor was saved")
        } catch let MCPError.invalidInput(message) {
            #expect(message.contains("2 of 3 questions have no Memory anchor"))
            #expect(message.contains("Question 1: no quote"))
            #expect(message.contains("Question 2: \"couples respiration to heat\" is not in the source's text"))
            #expect(!message.contains("Question 3"), "a question on no source has nothing to quote")
        }
        #expect(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).isEmpty, "nothing refused was saved")

        let heterogeneity = "deletion of MICOS-complex components or Opa1 diminished this intramitochondrial heterogeneity"
        _ = try save([
            question("What happened to the heterogeneity?", sourceID: paper.id, quote: heterogeneity),
            question("What imaged the cristae?", sourceID: paper.id, quote: "using the LSM880 with Airyscan as well as STED microscopy"),
            question("What couples respiration to ATP synthesis?", sourceID: seeded.sourceID, quote: "The proton circuit couples respiration"),
        ])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        let key = LectureQuizScore.preferenceKey(courseQuizID: quiz.id)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let recorded = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id,
            "results": quiz.questions.map { ["question_id": $0.id, "outcome": "incorrect"] },
        ])
        #expect(!recorded.contains("not saved to Memory"), "every miss reached Memory: \(recorded)")
        let items = try knowledge.loadMemoryItems()
        #expect(items.count == 3)
        #expect(items.contains { $0.sources.first?.excerpt == heterogeneity }, "the item keeps the quote as the learner reads it")
    }

    @Test("Answers recorded a call at a time build one sitting, under way in the app until its last answer completes it")
    func recordIteratively() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        _ = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "test",
            "questions": [
                question("What couples respiration to ATP synthesis?", sourceID: seeded.sourceID,
                         quote: "couples respiration to ATP synthesis through the membrane potential"),
                question("A second question?"),
                question("A third question?"),
            ],
        ])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        let key = LectureQuizScore.preferenceKey(courseQuizID: quiz.id)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let first = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id,
            "results": [["question_id": quiz.questions[0].id, "outcome": "incorrect", "answer": "ATP itself", "feedback": "Not quite: the membrane potential."]],
        ])
        #expect(first.contains("Started a sitting of Course test"))
        #expect(first.contains("1 of 3 questions done, 0 right so far; next unanswered: question 2 [\(quiz.questions[1].id)]"))
        #expect(UserDefaults.standard.object(forKey: key) == nil, "no score until the sitting completes")
        #expect(try knowledge.loadMemoryItems().count == 1, "the miss reached Memory with its own call")

        let rows = try knowledge.loadCourseQuizSittingRows()
        #expect(rows.count == 1)
        let sessionID = try #require(rows.first?.sessionID)
        #expect(CourseQuizSitting.quizID(inSessionID: sessionID) == quiz.id, "the sitting is the app's own kind of quiz chat")
        let underWay = try #require(CourseQuizSitting.latest(rows: rows, quizzes: [quiz])[quiz.id])
        #expect(underWay.isUnderWay && underWay.done == 1 && underWay.total == 3, "the quiz's row reads In progress")
        #expect(try store.getCourseQuiz(arguments: ["quiz_id": quiz.id]).contains("sitting under way: 1 of 3 done, 0 right (sitting_id: \(sessionID))"))
        #expect(try store.getCourse(courseIdentifier: seeded.courseID).contains("sitting under way: 1 of 3 answered"))
        #expect(try knowledge.deleteReviewSessionIfNoRecordedConversation(sessionID) == false, "the recorded answer keeps the chat from reading as abandoned")

        // Without sitting_id a call goes on with the sitting under way.
        let second = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id,
            "results": [["question_id": quiz.questions[1].id, "outcome": "correct", "answer": "Yes"]],
        ])
        #expect(second.contains("Recorded in the sitting of Course test (sitting_id: \(sessionID))"))
        #expect(try knowledge.loadCourseQuizSittingRows().count == 1)

        let last = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id, "sitting_id": sessionID,
            "results": [["question_id": quiz.questions[2].id, "outcome": "skipped"]],
        ])
        #expect(last.contains("Recorded Course test: 1 of 3 right"))
        let score = try #require(UserDefaults.standard.object(forKey: key).flatMap(LectureQuizScore.init(preferenceValue:)))
        #expect(score.right == 1 && score.total == 3)
        let finished = try #require(CourseQuizSitting.latestFinished(rows: try knowledge.loadCourseQuizSittingRows(), quizzes: [quiz])[quiz.id])
        #expect(finished.sessionID == sessionID, "a click on the finished quiz opens this chat as its results")
        let chat = try #require(try knowledge.loadReviewSessionForSync(sessionID))
        let exchanges = chat.exchanges.sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.map(\.userAnswer) == ["ATP itself", "Yes", "(skipped)"], "each question and answer is in the sitting's chat")
        #expect(exchanges.first?.evaluation == "Not quite: the membrane potential.")
        #expect(chat.status == "completed")

        // A correction to the completed sitting updates its score; a call
        // without sitting_id after it starts a retake.
        let corrected = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id, "sitting_id": sessionID,
            "results": [["question_id": quiz.questions[0].id, "outcome": "correct", "answer": "The membrane potential"]],
        ])
        #expect(corrected.contains("question 1 correct (regraded)"))
        #expect(corrected.contains("Recorded Course test: 2 of 3 right"))
        let retake = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id,
            "results": [["question_id": quiz.questions[0].id, "outcome": "correct", "answer": "The membrane potential"]],
        ])
        #expect(retake.contains("Started a sitting of Course test"))
        #expect(try knowledge.loadCourseQuizSittingRows().count == 2)
    }

    @Test("finish completes a sitting the learner stopped, the questions left skipped, and new_sitting starts over")
    func finishAndStartOver() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        _ = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "test",
            "questions": [question("Question one?"), question("Question two?"), question("Question three?")],
        ])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        let key = LectureQuizScore.preferenceKey(courseQuizID: quiz.id)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        _ = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id,
            "results": [["question_id": quiz.questions[0].id, "outcome": "correct", "answer": "One"]],
        ])
        let firstSitting = try #require(try knowledge.loadCourseQuizSittingRows().first?.sessionID)
        _ = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id, "new_sitting": true,
            "results": [["question_id": quiz.questions[0].id, "outcome": "correct", "answer": "One"]],
        ])
        let rows = try knowledge.loadCourseQuizSittingRows()
        #expect(rows.count == 2, "new_sitting starts over beside the sitting under way")
        let retake = try #require(rows.map { $0.sessionID }.first { $0 != firstSitting })

        let stopped = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": quiz.id, "sitting_id": retake, "finish": true,
            "results": [["question_id": quiz.questions[1].id, "outcome": "incorrect", "answer": "Two"]],
        ])
        #expect(stopped.contains("Recorded Course test: 1 of 3 right"))
        let sitting = try #require(CourseQuizSitting(briefing: try knowledge.loadReviewSessionBriefing(sessionID: retake)))
        #expect(sitting.skips(for: quiz) == [quiz.questions[2].id], "the question never asked counts as skipped")

        await #expect(throws: MCPError.self) {
            try await store.recordCourseQuizResult(arguments: [
                "quiz_id": quiz.id, "sitting_id": retake, "new_sitting": true,
                "results": [["question_id": quiz.questions[2].id, "outcome": "correct"]],
            ])
        }
        await #expect(throws: MCPError.self) {
            try await store.recordCourseQuizResult(arguments: [
                "quiz_id": quiz.id, "sitting_id": CourseQuizSitting.sessionID(forQuizID: "another-quiz"),
                "results": [["question_id": quiz.questions[2].id, "outcome": "correct"]],
            ])
        }
    }

    @Test("Saving a quiz again with a question added ahead keeps each question's id, and so its Memory item")
    func resaveKeepsMemoryItems() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        let asked = question(
            "What couples respiration to ATP synthesis?", sourceID: seeded.sourceID,
            quote: "couples respiration to ATP synthesis through the membrane potential"
        )
        let added = question(
            "What does the proton circuit run through?", sourceID: seeded.sourceID,
            quote: "through the membrane potential"
        )
        _ = try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "test", "questions": [asked]])
        let first = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        let key = LectureQuizScore.preferenceKey(courseQuizID: first.id)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        _ = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": first.id,
            "results": [["question_id": first.questions[0].id, "outcome": "incorrect"]],
        ])
        let item = try #require(try knowledge.loadMemoryItems().first)

        _ = try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "test", "questions": [added, asked]])
        let second = try #require(try knowledge.loadCourseQuiz(first.id))
        #expect(second.questions.map(\.question) == ["What does the proton circuit run through?", "What couples respiration to ATP synthesis?"])
        #expect(second.questions[1].id == first.questions[0].id, "the question keeps its id in second place")
        let recorded = try await store.recordCourseQuizResult(arguments: [
            "quiz_id": second.id,
            "results": [
                ["question_id": second.questions[0].id, "outcome": "incorrect"],
                ["question_id": second.questions[1].id, "outcome": "forgot"],
            ],
        ])
        #expect(!recorded.contains("not saved to Memory"), "every answer reached Memory: \(recorded)")
        let items = try knowledge.loadMemoryItems()
        #expect(items.count == 2, "the moved question stays on its item; only the new one adds an item")
        #expect(try knowledge.loadMemoryAttempts(memoryItemID: item.id).count == 2)
        #expect(items.contains { $0.id != item.id && MemoryCard(storedIn: $0)?.front == "What does the proton circuit run through?" })
    }

    @Test("Saving over a quiz stored with positional ids keeps a repeated question's id")
    func resaveKeepsLegacyIDs() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        let id = CourseQuizPlanning.testID(courseID: seeded.courseID)
        try knowledge.saveCourseQuiz(CourseQuiz(
            id: id, courseID: seeded.courseID, kind: .test, title: "Course test",
            lectureIDs: seeded.lectures.map(\.id), afterLectureID: seeded.lectures.last?.id,
            questions: [CourseQuizQuestion(
                id: "q1", sourceID: seeded.sourceID, firstLine: nil, lastLine: nil, startSeconds: nil,
                question: "What couples respiration to ATP synthesis?", answer: "The membrane potential.",
                keyPoints: [], quote: nil
            )],
            author: .assistant, createdAt: Date(), updatedAt: Date()
        ))
        _ = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints,
            "kind": "test",
            "questions": [question("A new first question?"), question("What couples respiration to ATP synthesis?", sourceID: seeded.sourceID,
                                                                         quote: "couples respiration to ATP synthesis through the membrane potential")],
        ])
        let saved = try #require(try knowledge.loadCourseQuiz(id))
        #expect(saved.questions.map(\.id) == [CourseQuizPlanning.questionID(sourceID: nil, question: "A new first question?"), "q1"])
    }

    @Test("Removing a quiz leaves the rest of the course alone")
    func delete() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        _ = try store.saveCourseQuiz(arguments: ["course_id": seeded.courseID, "learning_points": learningPoints, "kind": "test", "questions": [question("Q?")]])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        let removed = try store.deleteCourseQuiz(arguments: ["quiz_id": quiz.id])
        #expect(removed.contains("Removed Course test"))
        #expect(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).isEmpty)
        #expect(try knowledge.loadCourseLectures().count == 2)
    }

    @Test("Renaming a quiz changes only its title and symbol")
    func rename() throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seedCourse(knowledge)
        _ = try store.saveCourseQuiz(arguments: [
            "course_id": seeded.courseID, "learning_points": learningPoints, "kind": "practice",
            "lecture_ids": [seeded.lectures[0].id], "questions": [question("Q?")],
        ])
        let quiz = try #require(try knowledge.loadCourseQuizzes(courseID: seeded.courseID).first)
        #expect(!quiz.hasTopicTitle)
        let renamed = try store.renameCourseQuiz(arguments: ["quiz_id": quiz.id, "title": "Quiz: Cristae and Supercomplexes."])
        #expect(renamed.contains("to Cristae and Supercomplexes"))
        let saved = try #require(try knowledge.loadCourseQuiz(quiz.id))
        #expect(saved.title == "Cristae and Supercomplexes")
        #expect(saved.hasTopicTitle)
        #expect(saved.questions.map(\.id) == quiz.questions.map(\.id))
        #expect(throws: MCPError.self) {
            try store.renameCourseQuiz(arguments: ["quiz_id": quiz.id, "title": "  "])
        }
    }

    @Test("A course with no lecture text has nothing to quiz, said before anything is spent")
    func nothingToQuiz() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try knowledge.saveCourseGroup(name: "empty", metadata: CourseMetadata(title: "Empty"))
        try knowledge.saveCourseLecture(CourseSession(courseName: "empty", number: 1, title: "Nothing yet"))
        await #expect(throws: MCPError.self) {
            try await store.generateCourseQuizzes(arguments: ["course_id": "empty"])
        }
    }
}

/// The course outline a chat about a lecture reads (`CourseChatOutline`):
/// The product owner, 2026-09-27, "it should be aware that a course already has
/// predefined quizzes for each lecture".
@Suite("Course chat outline", .serialized)
struct CourseChatOutlineTests {

    /// Eight lectures, each with a video, and a practice quiz after lectures
    /// 1 and 2, a checkpoint on 1–4 and the course test.
    private func seed(_ knowledge: KnowledgeStore) throws -> (lectures: [CourseSession], videoIDs: [String], quizzes: [String: CourseQuiz]) {
        try knowledge.saveCourseGroup(name: "mito", metadata: CourseMetadata(title: "Mitochondrial Cell Biology"))
        var lectures: [CourseSession] = []
        var videoIDs: [String] = []
        for number in 1...8 {
            let lecture = CourseSession(courseName: "mito", number: number, title: number == 3 ? nil : "Mitochondrial Cell Biology \(number)")
            try knowledge.saveCourseLecture(lecture)
            var video = StudioArticle(
                url: "https://www.youtube.com/watch?v=lecture\(number)xx", title: "Video [\(number)]",
                sourceType: .video, discoveryOrigin: .manual, id: "video-\(number)"
            )
            // A ready source needs its readable text stored with it.
            video.content = "[0:00] Lecture \(number) on the inner mitochondrial membrane."
            video.state = .ready
            try knowledge.saveSource(video)
            _ = try knowledge.saveCourseLectureItem(CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0))
            lectures.append(lecture)
            videoIDs.append(video.id)
        }
        func quiz(_ id: String, _ kind: CourseQuiz.Kind, _ title: String, _ covered: [CourseSession], after: CourseSession?, questions: Int) -> CourseQuiz {
            CourseQuiz(
                id: id, courseID: "mito", kind: kind, title: title,
                lectureIDs: covered.map(\.id), afterLectureID: after?.id,
                questions: (1...questions).map {
                    CourseQuizQuestion(id: "q\($0)", sourceID: nil, firstLine: nil, lastLine: nil, startSeconds: nil,
                                       question: "Question \($0)?", answer: "Answer.", keyPoints: [], quote: nil)
                },
                author: .foreverlm, createdAt: Date(), updatedAt: Date()
            )
        }
        let quizzes = [
            "one": quiz("quiz-one", .practice, "Cristae and Supercomplexes", [lectures[0]], after: lectures[0], questions: 18),
            "two": quiz("quiz-two", .practice, "Mitochondrial Dynamics", [lectures[1]], after: lectures[1], questions: 12),
            "checkpoint": quiz("quiz-cp", .checkpoint, "Isolation and Respiration", Array(lectures[0...3]), after: lectures[3], questions: 8),
            "test": quiz("quiz-test", .test, "Course test", lectures, after: nil, questions: 20),
        ]
        for quiz in quizzes.values { try knowledge.saveCourseQuiz(quiz) }
        return (lectures, videoIDs, quizzes)
    }

    private func makeKnowledge() throws -> (KnowledgeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("course_chat_outline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        return (try store.knowledgeStore(), root)
    }

    @Test("A chat on lecture 1 sees the next lectures and every quiz after them, each as a link that opens the quiz")
    func lectureChatSeesQuizzes() throws {
        let (knowledge, root) = try makeKnowledge()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seed(knowledge)

        let material = try #require(try knowledge.courseChatOutlineMaterial(forSourceIDs: [seeded.videoIDs[0]]))
        let text = CourseChatOutline.text(attachedSourceIDs: [seeded.videoIDs[0]], material: material)

        #expect(text.hasPrefix(CourseChatOutline.instruction))
        #expect(text.contains("Course \"Mitochondrial Cell Biology\" (course_id: mito): 8 lectures, 4 quizzes written."))
        #expect(text.contains("1. [Mitochondrial Cell Biology 1](foreverlm://source/video-1) (attached to this chat)"))
        #expect(text.contains("   ▸ [Cristae and Supercomplexes](foreverlm://quiz/quiz-one): practice quiz on lecture 1, 18 questions"))
        #expect(text.contains("2. [Mitochondrial Cell Biology 2](foreverlm://source/video-2)\n   ▸ [Mitochondrial Dynamics](foreverlm://quiz/quiz-two): practice quiz on lecture 2, 12 questions"))
        // A lecture without a title is named by its video, brackets escaped.
        #expect(text.contains("3. [Video (3)](foreverlm://source/video-3)"))
        #expect(text.contains("   ▸ [Isolation and Respiration](foreverlm://quiz/quiz-cp): checkpoint quiz on lectures 1–4, 8 questions"))
        #expect(text.contains("5. [Mitochondrial Cell Biology 5]"))
        #expect(!text.contains("6. [Mitochondrial Cell Biology 6]"), "the window stops four lectures past the attached one")
        // The course test follows lecture 8, past the window, and still shows:
        // it covers the attached lecture.
        #expect(text.contains("(3 later lectures not listed)\n   ▸ [Course test](foreverlm://quiz/quiz-test): course test on lectures 1–8, 20 questions"))
        #expect(!text.contains("earlier lecture"))
        // The instruction says quizzes keep their score; the outline itself
        // names none.
        #expect(!text.dropFirst(CourseChatOutline.instruction.count).contains("score"), "the block rides the cached catalog, so it carries no score")
    }

    @Test("A later lecture's window starts two lectures before it")
    func laterLectureWindow() throws {
        let (knowledge, root) = try makeKnowledge()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try seed(knowledge)
        let attached = [seeded.videoIDs[6]]
        let material = try #require(try knowledge.courseChatOutlineMaterial(forSourceIDs: attached))
        let text = CourseChatOutline.text(attachedSourceIDs: attached, material: material)
        #expect(text.contains("(4 earlier lectures not listed)"))
        #expect(text.contains("5. [Mitochondrial Cell Biology 5]"))
        #expect(text.contains("7. [Mitochondrial Cell Biology 7](foreverlm://source/video-7) (attached to this chat)"))
        #expect(!text.contains("later lecture"))
        #expect(text.contains("8. [Mitochondrial Cell Biology 8](foreverlm://source/video-8)\n   ▸ [Course test](foreverlm://quiz/quiz-test)"))
        #expect(!text.contains("quiz-one"))
    }

    @Test("A source that is no lecture's material gets no outline")
    func nonLectureHasNone() throws {
        let (knowledge, root) = try makeKnowledge()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try seed(knowledge)
        #expect(try knowledge.courseChatOutlineMaterial(forSourceIDs: ["paper-elsewhere"]) == nil)
        #expect(try knowledge.courseChatOutlineMaterial(forSourceIDs: []) == nil)
    }

    @Test("get_course hands out each quiz's link")
    func getCourseLinksQuizzes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("course_chat_outline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        _ = try seed(try store.knowledgeStore())
        let course = try store.getCourse(courseIdentifier: "mito")
        #expect(course.contains("link: foreverlm://quiz/quiz-two)"))
    }
}

/// A question's picture over MCP (docs/lecture-quiz-design.md, "Pictures"):
/// a picture made in another app and kept with save_image, pinned by its
/// image_id; a brief for ForeverLM to draw; a reading's page; and taking a
/// picture away, each without touching the question.
@Suite("MCP course quiz pictures", .serialized)
struct MCPCourseQuizPictureToolTests {
    private func makeStore() throws -> (MCPDataStore, KnowledgeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_course_quiz_pictures_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), root)
    }

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    @Test("A picture made in another app is pinned by image_id, listed by get_course_quiz, replaced by a brief and taken away alone")
    func storedPictureLifecycle() async throws {
        let (store, knowledge, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try knowledge.saveCourseGroup(name: "bioenergetics", metadata: CourseMetadata(title: "Bioenergetics"))
        let lecture = CourseSession(courseName: "bioenergetics", number: 1, title: "Proton circuits")
        try knowledge.saveCourseLecture(lecture)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Proton circuits",
            sourceType: .video, discoveryOrigin: .manual, id: "video-one"
        )
        video.content = "[0:00] The proton circuit couples respiration to ATP synthesis through the membrane potential."
        video.state = .ready
        try knowledge.saveSource(video)
        _ = try knowledge.saveCourseLectureItem(CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0))

        let kept = await store.saveImage(arguments: [
            "prompt": "The proton circuit as a loop across the inner membrane",
            "title": "Proton circuit",
            "image_base64": "data:image/png;base64," + Self.png.base64EncodedString(),
            "model": "ChatGPT (GPT Image 2)",
        ])
        #expect(!kept.isError, "\(kept.text)")
        let imageLine = try #require(kept.text.split(separator: "\n").first { $0.hasPrefix("image_id: ") })
        let imageID = String(imageLine.dropFirst("image_id: ".count))
        defer {
            if let group = GeneratedImageStore.group(containing: imageID) {
                for version in group.versions { try? FileManager.default.removeItem(atPath: version.path) }
            }
        }

        let text = "What couples respiration to ATP synthesis?"
        let saved = try store.saveCourseQuiz(arguments: [
            "course_id": "bioenergetics",
            "learning_points": ["The proton circuit couples respiration to ATP synthesis through the membrane potential."],
            "kind": "practice",
            "lecture_ids": [lecture.id],
            "questions": [[
                "question": text, "answer": "The membrane potential.", "points": [1], "source_id": video.id,
                "quote": "couples respiration to ATP synthesis through the membrane potential",
                "picture": ["image_id": imageID, "caption": "The proton loop", "show_with": "question"],
            ] as [String: Any]],
        ])
        #expect(saved.contains("1 with a picture"))
        var quiz = try #require(try knowledge.loadCourseQuizzes(courseID: "bioenergetics").first)
        let questionID = try #require(quiz.questions.first?.id)
        #expect(quiz.questions.first?.picture?.storedImageID == imageID)
        #expect(quiz.questions.first?.picture?.placement == .question)

        let read = try store.getCourseQuiz(arguments: ["quiz_id": quiz.id])
        #expect(read.contains("Picture, shown with the question: foreverlm://image/generated/\(imageID) (The proton loop)"))
        #expect(read.contains("get_image image_id \(imageID)"))

        // The same picture by the line list_images and save_image hand out.
        let byLine = try store.setCourseQuizPicture(arguments: [
            "quiz_id": quiz.id, "question_id": questionID,
            "picture": ["image": "![Proton circuit](foreverlm://image/generated/\(imageID))", "show_with": "answer"],
        ])
        #expect(byLine.contains("shown with the answer: foreverlm://image/generated/\(imageID)"))

        let briefed = try store.setCourseQuizPicture(arguments: [
            "quiz_id": quiz.id, "question_id": questionID,
            "picture": ["brief": "Protons pumped out by the chain and flowing back through ATP synthase", "show_with": "answer"],
        ])
        #expect(briefed.contains("not drawn yet"))
        quiz = try #require(try knowledge.loadCourseQuiz(quiz.id))
        #expect(quiz.questions.first?.picture?.isAwaitingDrawing == true)
        #expect(!(try store.getCourseQuiz(arguments: ["quiz_id": quiz.id])).contains("Protons pumped out"), "an answer's brief stays hidden without include_answers")

        let paged = try store.setCourseQuizPicture(arguments: [
            "quiz_id": quiz.id, "question_id": questionID,
            "picture": ["page": 2, "crop": ["x": 0.1, "y": 0.1, "width": 0.8, "height": 0.5], "show_with": "question"],
        ])
        #expect(paged.contains("show_source_image source_id \(video.id), page 2"))

        #expect(throws: MCPError.self) {
            try store.setCourseQuizPicture(arguments: [
                "quiz_id": quiz.id, "question_id": questionID,
                "picture": ["image_id": "00000000-0000-4000-8000-000000000000", "show_with": "question"],
            ])
        }
        #expect(throws: MCPError.self) {
            try store.setCourseQuizPicture(arguments: ["quiz_id": quiz.id, "question_id": "no-such-question", "remove": true])
        }

        let removed = try store.setCourseQuizPicture(arguments: ["quiz_id": quiz.id, "question_id": questionID, "remove": true])
        #expect(removed.contains("Removed the picture"))
        let after = try #require(try knowledge.loadCourseQuiz(quiz.id))
        #expect(after.questions.first?.picture == nil)
        #expect(after.questions.map(\.id) == [questionID])
        #expect(after.questions.first?.question == text)
    }

    @Test("set_course_quiz_picture is registered and writes")
    func registered() {
        let tool = MCPToolRegistry(store: MCPDataStore()).tools.first { $0.name == "set_course_quiz_picture" }
        #expect(tool != nil)
        #expect((tool?.inputSchema["required"] as? [String]) == ["quiz_id", "question_id"])
    }
}
