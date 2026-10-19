import AppKit
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import ForeverLM

@Suite("Course Quiz Planning")
struct CourseQuizPlanningTests {
    /// Twenty numbered lines, one every 30 seconds.
    private let lines: [LectureQuizLine] = (1...20).map {
        LectureQuizLine(number: $0, seconds: Double(($0 - 1) * 30), text: "Line \($0) says something about membrane potential and ATP.")
    }

    private func part(_ index: Int, lines: [LectureQuizLine]? = nil) -> CourseQuizPart {
        CourseQuizPart(lectureID: "lecture-\(index)", lectureTitle: "Lecture \(index)", sourceID: "video-\(index)", lines: lines ?? self.lines)
    }

    private func raw(
        part: Int? = nil,
        firstLine: Int? = nil,
        lastLine: Int,
        question: String = "Why does the membrane potential fall?",
        answer: String = "Because protons leak back.",
        quote: String? = nil
    ) -> CourseQuizDraft.Question {
        CourseQuizDraft.Question(
            part: part, firstLine: firstLine, lastLine: lastLine,
            question: question, answer: answer, keyPoints: [" protons leak ", ""], quote: quote
        )
    }

    // MARK: The ladder

    private func lectures(_ count: Int) -> [(id: String, title: String)] {
        (1...count).map { ("lecture-\($0)", "Lecture \($0)") }
    }

    @Test("Eighteen lectures: a practice quiz each, a checkpoint every four, and a test")
    func ladderOfEighteen() {
        let slots = CourseQuizPlanning.ladder(courseID: "course", lectures: lectures(18))
        #expect(slots.filter { $0.kind == .practice }.count == 18)
        let checkpoints = slots.filter { $0.kind == .checkpoint }
        #expect(checkpoints.map(\.lectureIDs.count) == [4, 4, 4, 4, 2])
        #expect(checkpoints.map(\.title) == ["Quiz 1", "Quiz 2", "Quiz 3", "Quiz 4", "Quiz 5"])
        #expect(checkpoints.map(\.afterLectureID) == ["lecture-4", "lecture-8", "lecture-12", "lecture-16", "lecture-18"])
        let test = slots.filter { $0.kind == .test }
        #expect(test.count == 1)
        #expect(test.first?.lectureIDs.count == 18)
        #expect(test.first?.afterLectureID == "lecture-18")
    }

    @Test("A lone lecture left at the end joins the checkpoint before it")
    func loneTrailingLecture() {
        let checkpoints = CourseQuizPlanning.ladder(courseID: "course", lectures: lectures(9)).filter { $0.kind == .checkpoint }
        #expect(checkpoints.map(\.lectureIDs.count) == [4, 5])
    }

    @Test("A short course gets no checkpoints; the test already covers it")
    func shortCourse() {
        let slots = CourseQuizPlanning.ladder(courseID: "course", lectures: lectures(3))
        #expect(slots.map(\.kind) == [.practice, .practice, .practice, .test])
        #expect(CourseQuizPlanning.ladder(courseID: "course", lectures: lectures(3), includeTest: false).map(\.kind)
            == [.practice, .practice, .practice])
        #expect(CourseQuizPlanning.ladder(courseID: "course", lectures: []).isEmpty)
    }

    @Test("Identities are stable, so two Macs writing a course converge on one quiz each")
    func stableIdentities() {
        let first = CourseQuizPlanning.ladder(courseID: "course", lectures: lectures(9))
        let second = CourseQuizPlanning.ladder(courseID: "course", lectures: lectures(9))
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.first?.id == CourseQuizPlanning.practiceID(courseID: "course", lectureID: "lecture-1"))
        #expect(CourseQuizPlanning.testID(courseID: "course") != CourseQuizPlanning.testID(courseID: "other"))
    }

    @Test("The checkpoint interval is kept within its range")
    func checkpointInterval() {
        let everyTwo = CourseQuizPlanning.ladder(courseID: "c", lectures: lectures(6), checkpointEvery: 1)
        #expect(everyTwo.filter { $0.kind == .checkpoint }.map(\.lectureIDs.count) == [2, 2, 2])
    }

    private func titled(_ titles: [String]) -> [(id: String, title: String)] {
        titles.enumerated().map { ("lecture-\($0.offset + 1)", $0.element) }
    }

    private func checkpointSpans(_ titles: [String], every: Int = 4) -> [ClosedRange<Int>] {
        CourseQuizPlanning.ladder(courseID: "c", lectures: titled(titles), checkpointEvery: every)
            .filter { $0.kind == .checkpoint }
            .map { slot in
                let numbers = slot.lectureIDs.compactMap { Int($0.dropFirst("lecture-".count)) }
                return (numbers.first ?? 0)...(numbers.last ?? 0)
            }
    }

    @Test("A checkpoint closes a lecture series instead of counting four lectures")
    func checkpointsFollowSeries() {
        // The Mitochondrial Bioenergetics course as the product owner saw it on
        // 2026-09-28, with checkpoints after lectures 4, 8, 12 and 16.
        let titles = [
            "Course organization",
            "Mitochondrial Cell Biology 1", "Mitochondrial Cell Biology 2", "Mitochondrial Cell Biology 3",
            "Isolated Mitochondria and Permeabilized Cells/Tissues 1",
            "Isolated Mitochondria and Permeabilized Cells/Tissues 2",
            "Isolated Mitochondria and Permeabilized Cells/Tissues 3",
            "Mitochondrial Ion Transport 1", "Mitochondrial Ion Transport 2",
            "Mitochondrial Ion Transport 3", "Mitochondrial Ion Transport 4",
            "Intact Cell Measurements 1", "Intact Cell Measurements 2", "Intact Cell Measurements 3",
            "Mitochondrial Oxidants and Antioxidants 1", "Mitochondrial Oxidants and Antioxidants 2",
            "Mitochondrial Oxidants and Antioxidants 3",
            "When and How to Measure Mitochondrial Inner Membrane Potentials",
        ]
        #expect(checkpointSpans(titles) == [1...4, 5...7, 8...11, 12...14, 15...18])
        let afterLectures = CourseQuizPlanning.ladder(courseID: "c", lectures: titled(titles))
            .filter { $0.kind == .checkpoint }.map(\.afterLectureID)
        #expect(afterLectures == ["lecture-4", "lecture-7", "lecture-11", "lecture-14", "lecture-18"])
    }

    @Test("Titles with no series, or one series through the course, keep a checkpoint every four")
    func noSeriesKeepsTheCount() {
        // Numbered by the course, one topic each: Systems Biology.
        let distinct = [
            "1) Basic concepts", "2) Auto-regulation, a network motif", "3) Feed Forward Loops",
            "4) Temporal order, Global Structure, and Memory", "5) Robustness using bifunctional components",
            "6) Robustness in bacterial chemotaxis", "7) Fold Change Detection", "8) Dynamic Compensation",
            "9) How to build a Biological Oscillator.", "10) Optimality in Biological Circuits.",
            "11) Evolution and Multi-Objective Optimality.", "12) Modularity",
        ]
        #expect(checkpointSpans(distinct) == [1...4, 5...8, 9...12])
        #expect(checkpointSpans((1...18).map { "Lecture \($0)" }) == [1...4, 5...8, 9...12, 13...16, 17...18])
        #expect(checkpointSpans((1...9).map { "Bioenergetics \($0)" }) == [1...4, 5...9],
                "a series that is the whole course is the course counting")
        // CS336: two lectures called "Parallelism" share a checkpoint, and
        // the checkpoints still fall where a count of four put them.
        let cs336 = [
            "1) Overview, Tokenization", "2) PyTorch (einops)", "3) Architectures", "4) Attention Alternatives",
            "5) GPUs, TPUs", "6) Kernels, Triton, XLA", "7) Parallelism", "8) Parallelism",
            "9) Scaling Laws", "10) Inference", "11) Scaling Laws", "12) Evaluation",
            "13) Data (Sources, Datasets)", "14) Data", "15) Mid/Post-Training", "16) Post-Training - RLVR",
            "17) Alignment - Multimodality", "18) Guest Lecture: Dan Fu",
        ]
        #expect(checkpointSpans(cs336) == [1...4, 5...8, 9...12, 13...16, 17...18])
    }

    @Test("Short series share a checkpoint, a long one is cut, and a lone lecture joins the smaller side")
    func seriesSizes() {
        let short = ["A 1", "A 2", "B 1", "B 2", "C 1", "C 2", "D 1", "D 2"]
        #expect(checkpointSpans(short) == [1...4, 5...8])
        let long = (1...8).map { "Membranes \($0)" } + ["Transport 1", "Transport 2", "Transport 3"]
        #expect(checkpointSpans(long) == [1...4, 5...8, 9...11])
        let fiveParts = (1...5).map { "Membranes \($0)" } + ["Transport 1", "Transport 2", "Transport 3"]
        #expect(checkpointSpans(fiveParts) == [1...5, 6...8], "five parts are not cut four and one")
        let lone = ["A 1", "A 2", "A 3", "A 4", "Guest lecture", "B 1", "B 2", "B 3"]
        #expect(checkpointSpans(lone) == [1...4, 5...8])
    }

    @Test("A lecture's series topic drops the course's numbering and the part number")
    func seriesTopics() {
        let topic = CourseQuizPlanning.lectureSeriesTopic
        #expect(topic("Mitochondrial Ion Transport 2") == "mitochondrial ion transport")
        #expect(topic("8) Mitochondrial Ion Transport 1") == "mitochondrial ion transport")
        #expect(topic("Mitochondrial Ion Transport, Part II") == "mitochondrial ion transport")
        #expect(topic("Mitochondrial Ion Transport (3 of 4)") == "mitochondrial ion transport")
        #expect(topic("Lecture 4: Mitochondrial ion transport - Pt. 1") == "mitochondrial ion transport")
        #expect(topic("7) Parallelism") == "parallelism")
        #expect(topic("Isolated Mitochondria and Permeabilized Cells/Tissues 3")
            == "isolated mitochondria and permeabilized cells/tissues")
        #expect(topic("6) Kernels, Triton, XLA") == "kernels, triton, xla", "a capital word is not a numeral")
        #expect(topic("Lecture 12") == nil)
        #expect(topic("Part 2") == nil)
        #expect(topic("   ") == nil)
    }

    // MARK: Checking a draft

    @Test("A question keeps the lines it names, in the part it names, and starts watching at its first line")
    func keepsNamedStretch() {
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [raw(part: 2, firstLine: 5, lastLine: 8)]),
            parts: [part(1), part(2)]
        )
        #expect(questions.count == 1)
        #expect(questions[0].sourceID == "video-2")
        #expect(questions[0].firstLine == 5)
        #expect(questions[0].lastLine == 8)
        #expect(questions[0].startSeconds == 120)
        #expect(questions[0].keyPoints == ["protons leak"])
        #expect(questions[0].id == CourseQuizPlanning.questionID(sourceID: "video-2", question: "Why does the membrane potential fall?"))
    }

    @Test("A practice quiz's draft names no part and reads the one lecture")
    func practiceDraftHasNoPart() {
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [raw(firstLine: 2, lastLine: 3)]),
            parts: [part(1)]
        )
        #expect(questions.first?.sourceID == "video-1")
    }

    @Test("A part or last line that is not there drops the question; a bad first line narrows to the last")
    func dropsAndNarrows() {
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                raw(part: 1, firstLine: 2, lastLine: 99),
                raw(part: 3, lastLine: 4),
                raw(part: 1, firstLine: 12, lastLine: 10),
                raw(part: 1, firstLine: 99, lastLine: 4),
            ]),
            parts: [part(1), part(2)]
        )
        #expect(questions.map(\.lastLine) == [4, 10])
        #expect(questions.map(\.firstLine) == [4, 10])
    }

    @Test("Empty questions and repeats are dropped, and the rest come back in course order")
    func dedupesAndOrders() {
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                raw(part: 2, lastLine: 3, question: "Second lecture"),
                raw(part: 1, lastLine: 15, question: "Later"),
                raw(part: 1, lastLine: 3, question: "  "),
                raw(part: 1, lastLine: 6, question: "Earlier"),
                raw(part: 1, lastLine: 15, question: "Repeat"),
                raw(part: 2, lastLine: 15, question: "Same line, other lecture"),
            ]),
            parts: [part(1), part(2)]
        )
        #expect(questions.map(\.question) == ["Earlier", "Later", "Second lecture", "Same line, other lecture"])
        #expect(questions.map(\.id) == questions.map { CourseQuizPlanning.questionID(sourceID: $0.sourceID, question: $0.question) })
    }

    @Test("A problem set runs basics first: by level, then course order; a recall and a problem on one line are both kept")
    func ordersByLevel() {
        func leveled(_ level: String?, part: Int = 1, lastLine: Int, question text: String) -> CourseQuizDraft.Question {
            var drafted = raw(part: part, lastLine: lastLine, question: text)
            drafted.level = level
            return drafted
        }
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                leveled("challenge", lastLine: 4, question: "Hard"),
                leveled("apply", lastLine: 12, question: "Use it"),
                leveled("recall", part: 2, lastLine: 2, question: "Second lecture fact"),
                leveled(" Recall ", lastLine: 12, question: "Fact"),
                leveled("explain", lastLine: 4, question: "Why"),
                leveled("recall", lastLine: 12, question: "Same level, same line"),
            ]),
            parts: [part(1), part(2)]
        )
        #expect(questions.map(\.question) == ["Fact", "Second lecture fact", "Why", "Use it", "Hard"])
        #expect(questions.map(\.level) == [.recall, .recall, .explain, .apply, .challenge])
        #expect(Set(questions.map(\.id)).count == 5)
    }

    // MARK: Question identity

    @Test("A question's id is what it asks about which source, never where it sits")
    func questionIDIsContent() {
        let id = CourseQuizPlanning.questionID(sourceID: "video-1", question: "Why does the membrane potential fall?")
        #expect(id.hasPrefix("q-"))
        #expect(id == CourseQuizPlanning.questionID(sourceID: "video-1", question: "  Why does the membrane potential fall?\n"))
        #expect(id != CourseQuizPlanning.questionID(sourceID: "video-2", question: "Why does the membrane potential fall?"))
        #expect(id != CourseQuizPlanning.questionID(sourceID: "video-1", question: "Why does the membrane potential rise?"))
    }

    @Test("A rewrite that reorders, re-anchors and relevels a quiz keeps each question's id, and a new question at an old place gets its own")
    func rewriteKeepsQuestionIDs() throws {
        func leveled(_ level: String, lastLine: Int, question text: String) -> CourseQuizDraft.Question {
            var drafted = raw(lastLine: lastLine, question: text)
            drafted.level = level
            return drafted
        }
        let first = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                leveled("recall", lastLine: 4, question: "What leaks?"),
                leveled("apply", lastLine: 12, question: "What if the leak doubles?"),
            ]),
            parts: [part(1)]
        )
        // Written again: a new recall question takes the first place, and
        // "What leaks?" moves down as an explain question on other lines.
        let second = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                leveled("recall", lastLine: 2, question: "What pumps?"),
                leveled("explain", lastLine: 6, question: "What leaks?"),
                leveled("apply", lastLine: 12, question: "What if the leak doubles?"),
            ]),
            parts: [part(1)],
            previous: first
        )
        #expect(second.map(\.question) == ["What pumps?", "What leaks?", "What if the leak doubles?"])
        let leaks = try #require(second.first { $0.question == "What leaks?" })
        #expect(leaks.id == first[0].id, "the question keeps its id at its new place")
        #expect(second[2].id == first[1].id)
        #expect(second[0].id != first[0].id, "the question now at the old first place is a new one")
        #expect(Set(second.map(\.id)).count == 3)
    }

    @Test("A missed question's card keeps its picture on the side the quiz showed it")
    func memoryQuestionKeepsPicture() throws {
        let slide = SourceImageReference(sourceID: "video-1", location: .moment(90))
        var question = CourseQuizQuestion(
            id: "q1", sourceID: "video-1", firstLine: 2, lastLine: 2, startSeconds: 30,
            question: "What pumps?", answer: "Complex I.", keyPoints: [], quote: nil
        )
        question.picture = CourseQuizPicture(reference: slide, caption: "The pumping slide", placement: .question)
        let asked = try #require(CourseQuizPlanning.memoryQuestion(quizID: "quiz", question: question, lines: []))
        #expect(asked.frontImages.map(\.target) == [slide.urlString])
        #expect(asked.frontImages.first?.alt == "The pumping slide")
        #expect(asked.backImages.isEmpty)

        question.picture = CourseQuizPicture(reference: slide, caption: nil, placement: .answer)
        let answered = try #require(CourseQuizPlanning.memoryQuestion(quizID: "quiz", question: question, lines: []))
        #expect(answered.backImages.map(\.target) == [slide.urlString])
        #expect(answered.card(itemID: "item").backImages.map(\.target) == [slide.urlString])

        question.picture = .awaitingDrawing(brief: "A pump", caption: nil, placement: .answer)
        let waiting = try #require(CourseQuizPlanning.memoryQuestion(quizID: "quiz", question: question, lines: []))
        #expect(waiting.frontImages.isEmpty && waiting.backImages.isEmpty, "a picture not drawn yet is none")
    }

    @Test("A rewrite keeps the positional id a quiz stored before content ids for the same question")
    func rewriteKeepsLegacyIDs() {
        let stored = [
            CourseQuizQuestion(
                id: "q1", sourceID: "video-1", firstLine: 2, lastLine: 2, startSeconds: 30,
                question: "What pumps?", answer: "Complex I.", keyPoints: [], quote: nil
            ),
            CourseQuizQuestion(
                id: "q2", sourceID: "video-1", firstLine: 4, lastLine: 4, startSeconds: 90,
                question: "What leaks?", answer: "Protons.", keyPoints: [], quote: nil
            ),
        ]
        let rewritten = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                raw(lastLine: 4, question: "What leaks?"),
                raw(lastLine: 9, question: "What couples them?"),
            ]),
            parts: [part(1)],
            previous: stored
        )
        #expect(rewritten.map(\.id) == ["q2", CourseQuizPlanning.questionID(sourceID: "video-1", question: "What couples them?")])
    }

    @Test("The same question twice in one quiz is told apart, so ids never repeat")
    func duplicateQuestionsStayUnique() {
        let many = (1...4).map { raw(lastLine: $0 * 2) }
        let questions = CourseQuizPlanning.questions(from: CourseQuizDraft(questions: many), parts: [part(1)])
        let base = CourseQuizPlanning.questionID(sourceID: "video-1", question: "Why does the membrane potential fall?")
        #expect(questions.map(\.id) == [base, "\(base)-2", "\(base)-3", "\(base)-4"])
        let again = CourseQuizPlanning.questions(from: CourseQuizDraft(questions: many), parts: [part(1)], previous: questions)
        #expect(again.map(\.id) == questions.map(\.id))
    }

    @Test("A question's Memory item follows it through a rewrite that moves it; a new question at its old place starts its own")
    func memoryItemFollowsQuestion() throws {
        let store = try KnowledgeStore(inMemory: true)
        var lecture = StudioArticle(
            url: "https://example.com/lecture-1", title: "Lecture 1",
            sourceType: .article, discoveryOrigin: .manual, id: "video-1"
        )
        lecture.content = lines.map(\.text).joined(separator: "\n")
        lecture.state = .ready
        try store.saveSource(lecture)
        let quizID = CourseQuizPlanning.practiceID(courseID: "course", lectureID: "lecture-1")
        func record(_ question: CourseQuizQuestion, rating: MemoryScheduleRating) throws {
            let memoryQuestion = try #require(CourseQuizPlanning.memoryQuestion(quizID: quizID, question: question, lines: lines))
            try store.recordSourceQuestionAttempt(
                memoryQuestion, answer: "An answer.", feedback: "Feedback.",
                score: rating == .again ? 0 : 1, rating: rating
            )
        }

        let first = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [raw(lastLine: 4, question: "What leaks?")]),
            parts: [part(1)]
        )
        try record(first[0], rating: .again)
        let item = try #require(try store.loadMemoryItems().first)

        let second = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                raw(lastLine: 2, question: "What pumps?"),
                raw(lastLine: 4, question: "What leaks?"),
            ]),
            parts: [part(1)],
            previous: first
        )
        #expect(second[0].question == "What pumps?")
        try record(second[1], rating: .again)
        #expect(try store.loadMemoryItems().map(\.id) == [item.id], "missing the moved question again is not a second item")
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).count == 2)

        try record(second[0], rating: .again)
        let items = try store.loadMemoryItems()
        #expect(items.count == 2)
        let fresh = try #require(items.first { $0.id != item.id })
        #expect(MemoryCard(storedIn: fresh)?.front == "What pumps?", "the new question's item carries its own words")
        #expect(MemoryCard(storedIn: item)?.front == "What leaks?")
        #expect(MemoryCard(storedIn: item)?.origin == .courseQuiz)
    }

    @Test("A stored question's level survives a round trip under the key \"level\", and an unknown one still decodes")
    func levelCoding() throws {
        let question = CourseQuizQuestion(
            id: "q1", sourceID: "video-1", firstLine: 1, lastLine: 2, startSeconds: 0,
            question: "Why?", answer: "Because.", keyPoints: [], quote: nil, levelName: "apply"
        )
        let data = try JSONEncoder().encode(question)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["level"] as? String == "apply")
        #expect(try JSONDecoder().decode(CourseQuizQuestion.self, from: data).level == .apply)
        let later = #"{"id":"q1","question":"Why?","answer":"Because.","keyPoints":[],"level":"synthesis"}"#
        let decoded = try JSONDecoder().decode(CourseQuizQuestion.self, from: Data(later.utf8))
        #expect(decoded.levelName == "synthesis")
        #expect(decoded.level == nil)
        let older = #"{"id":"q1","question":"Why?","answer":"Because.","keyPoints":[]}"#
        #expect(try JSONDecoder().decode(CourseQuizQuestion.self, from: Data(older.utf8)).levelName == nil)
    }

    @Test("No more than the limit")
    func capsCount() {
        let many = (1...10).map { raw(lastLine: $0 * 2) }
        #expect(CourseQuizPlanning.questions(from: CourseQuizDraft(questions: many), parts: [part(1)], limit: 6).count == 6)
    }

    @Test("An untimed source has no moment to rewatch")
    func untimed() {
        let plain = (1...5).map { LectureQuizLine(number: $0, seconds: nil, text: "Paragraph \($0).") }
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [raw(firstLine: 2, lastLine: 3)]),
            parts: [part(1, lines: plain)]
        )
        #expect(questions.first?.startSeconds == nil)
    }

    @Test("The grader reads the covered lines, and Memory is offered the quote first")
    func coveredAndExcerpts() {
        let question = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [raw(firstLine: 5, lastLine: 7, quote: "membrane potential and ATP")]),
            parts: [part(1)]
        )[0]
        #expect(CourseQuizPlanning.coveredLines(for: question, in: lines).map(\.number) == [5, 6, 7])
        let excerpts = CourseQuizPlanning.memoryExcerpts(for: question, in: lines)
        #expect(excerpts.first == "membrane potential and ATP")
        #expect(excerpts.count == 4)
    }

    @Test("The writers' JSON decodes, with or without a part")
    func decodesDraft() throws {
        let json = """
        {"questions": [{"part": 2, "first_line": 40, "last_line": 46, "question": "Q", "answer": "A", "key_points": ["k"], "quote": "q"},
                       {"first_line": 1, "last_line": 2, "question": "Q2", "answer": "A2"}]}
        """
        let draft: CourseQuizDraft = try MemoryReviewPlanning.decodeJSON(json)
        #expect(draft.questions.map(\.part) == [2, nil])
        #expect(draft.questions.first?.keyPoints == ["k"])
    }

    // MARK: Material

    @Test("The material labels each line with its part and time")
    func materialBlock() {
        let block = CourseQuizPlanning.materialBlock([part(1, lines: Array(lines.prefix(2))), part(2, lines: Array(lines.prefix(1)))])
        #expect(block.text == """
        Part 1: Lecture 1
        [1.1 · 0:00] Line 1 says something about membrane potential and ATP.
        [1.2 · 0:30] Line 2 says something about membrane potential and ATP.

        Part 2: Lecture 2
        [2.1 · 0:00] Line 1 says something about membrane potential and ATP.
        """)
        #expect(!block.truncated)
    }

    @Test("A part too long for its share is sampled through the whole lecture, keeping line numbers")
    func sampling() {
        let long = (1...400).map { LectureQuizLine(number: $0, seconds: nil, text: String(repeating: "word ", count: 40)) }
        let (kept, truncated) = CourseQuizPlanning.sampledLines(long, budget: 10_000)
        #expect(truncated)
        #expect(kept.count < long.count)
        #expect((kept.last?.number ?? 0) > 350, "the end of the lecture is still read")
        #expect(kept.map(\.number) == kept.map(\.number).sorted())
        let block = CourseQuizPlanning.materialBlock([part(1, lines: long)], budget: 10_000)
        #expect(block.truncated)
        #expect(block.text.hasPrefix("Part 1: Lecture 1 (excerpts)"))
    }

    // MARK: Outline

    private func quiz(_ id: String, _ kind: CourseQuiz.Kind, after: String?, covers: [String]) -> CourseQuiz {
        CourseQuiz(
            id: id, courseID: "course", kind: kind, title: id, lectureIDs: covers, afterLectureID: after,
            questions: [], author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("Quizzes follow their lecture: practice, then checkpoint, then test; a lost lecture falls back or ends the course")
    func placements() {
        let placed = CourseQuizPlanning.placements(
            quizzes: [
                quiz("test", .test, after: "l2", covers: ["l1", "l2"]),
                quiz("p2", .practice, after: "l2", covers: ["l2"]),
                quiz("cp", .checkpoint, after: "l2", covers: ["l1", "l2"]),
                quiz("gone", .checkpoint, after: "l9", covers: ["l1", "l9"]),
                quiz("orphan", .practice, after: "l7", covers: ["l7"]),
            ],
            lectureOrder: ["l1", "l2"]
        )
        #expect(placed.afterLecture["l2"]?.map(\.id) == ["p2", "cp", "test"])
        #expect(placed.afterLecture["l1"]?.map(\.id) == ["gone"])
        #expect(placed.atEnd.map(\.id) == ["orphan"])
    }

    // MARK: Storage and sync

    private func sampleQuiz(courseID: String, lectureID: String) -> CourseQuiz {
        CourseQuiz(
            id: CourseQuizPlanning.practiceID(courseID: courseID, lectureID: lectureID),
            courseID: courseID,
            kind: .practice,
            title: "Quiz: One",
            lectureIDs: [lectureID],
            afterLectureID: lectureID,
            questions: [CourseQuizQuestion(
                id: "q1", sourceID: "video", firstLine: 2, lastLine: 3, startSeconds: 30,
                question: "Q?", answer: "A.", keyPoints: ["k"], quote: "quoted words"
            )],
            author: .foreverlm,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_100)
        )
    }

    @Test("A quiz round-trips through the store, rides its course's payload, and goes with its course")
    func storeAndSync() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveCourseGroup(name: "course", metadata: CourseMetadata(title: "Bioenergetics"))
        let lecture = CourseSession(courseName: "course", number: 1, title: "One")
        try store.saveCourseLecture(lecture)
        let quiz = sampleQuiz(courseID: "course", lectureID: lecture.id)
        try store.saveCourseQuiz(quiz)

        #expect(try store.loadCourseQuizzes(courseID: "course") == [quiz])
        #expect(try store.loadCourseQuiz(quiz.id) == quiz)

        let payload = try #require(try store.loadCourseForSync("course"))
        let decoded = try JSONDecoder().decode(CloudKitCoursePayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.quizzes == [quiz])

        // Another Mac: the payload's quizzes replace its own.
        let other = try KnowledgeStore(inMemory: true)
        try other.withoutSyncTracking {
            try other.replaceCourseQuizzesFromSync(courseID: "course", quizzes: decoded.quizzes ?? [])
        }
        #expect(try other.loadCourseQuizzes(courseID: "course") == [quiz])

        _ = try store.deleteCourseGroup(name: "course")
        #expect(try store.loadCourseQuizzes(courseID: "course").isEmpty)
    }

    @Test("A Course record from a build without quizzes decodes with none, and does not read as an empty list")
    func olderPayload() throws {
        let json = #"{"id": "course", "name": "Bioenergetics", "title": "Bioenergetics", "isHidden": false, "lectures": [], "lectureItems": []}"#
        let payload = try JSONDecoder().decode(CloudKitCoursePayload.self, from: Data(json.utf8))
        #expect(payload.quizzes == nil)
    }

    @Test("Deleting a quiz removes only it")
    func deleteOne() throws {
        let store = try KnowledgeStore(inMemory: true)
        let first = sampleQuiz(courseID: "course", lectureID: "l1")
        let second = sampleQuiz(courseID: "course", lectureID: "l2")
        try store.saveCourseQuiz(first)
        try store.saveCourseQuiz(second)
        try store.deleteCourseQuiz(first.id)
        #expect(try store.loadCourseQuizzes(courseID: "course").map(\.id) == [second.id])
    }

    // MARK: Titles, symbols and pictures

    @Test("A writer's title is cleaned to a short topic name, and the course test keeps its own")
    func topicTitles() throws {
        #expect(CourseQuizNaming.cleanTitle("  \"Quiz: Cristae and Supercomplexes.\" ") == "Cristae and Supercomplexes")
        #expect(CourseQuizNaming.cleanTitle("Quiz 3") == nil, "a numbered placeholder is not a name")
        #expect(CourseQuizNaming.cleanTitle("   ") == nil)
        let long = CourseQuizNaming.cleanTitle(String(repeating: "Membrane ", count: 12))
        #expect((long?.count ?? 0) <= CourseQuizNaming.maximumTitleCharacters)
        #expect(long?.hasSuffix(" ") == false)

        let slots = CourseQuizPlanning.ladder(
            courseID: "c",
            lectures: (1...5).map { ("l\($0)", "Lecture \($0)") },
            checkpointEvery: 4
        )
        let practice = try #require(slots.first { $0.kind == .practice })
        let checkpoint = try #require(slots.first { $0.kind == .checkpoint })
        let test = try #require(slots.first { $0.kind == .test })
        #expect(CourseQuizNaming.title(for: practice, written: "Proton Leak") == "Proton Leak")
        #expect(CourseQuizNaming.title(for: practice, written: nil) == practice.title)
        #expect(CourseQuizNaming.title(for: checkpoint, written: "Isolated Mitochondria") == "Isolated Mitochondria")
        #expect(CourseQuizNaming.title(for: test, written: "Everything") == "Course test")
    }

    @Test("Whether a quiz is named is read from its title")
    func namedness() {
        var quiz = sampleQuiz(courseID: "course", lectureID: "l1")
        #expect(!quiz.hasTopicTitle, "the ladder's \"Quiz: <lecture>\"")
        quiz.title = "Proton Leak"
        #expect(quiz.hasTopicTitle)
        let checkpoint = CourseQuiz(
            id: "cp", courseID: "course", kind: .checkpoint, title: "Quiz 2", lectureIDs: ["l1"],
            afterLectureID: "l1", questions: [], author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
        #expect(!checkpoint.hasTopicTitle)
    }

    @Test("A symbol name is shaped like one")
    func symbolShape() {
        #expect(CourseQuizNaming.cleanSymbol(" Bolt.Heart.Fill ") == "bolt.heart.fill")
        #expect(CourseQuizNaming.cleanSymbol("bolt heart") == nil)
        #expect(CourseQuizNaming.cleanSymbol("../etc") == nil)
        #expect(CourseQuizNaming.cleanSymbol(nil) == nil)
        #expect(CourseQuizGeneratorService.availableSymbol("atom") == "atom")
        #expect(CourseQuizGeneratorService.availableSymbol("not.a.real.symbol.anywhere") == nil)
    }

    @Test("A writer's draft carries its title and symbol, and an older draft decodes without them")
    func draftNaming() throws {
        let named = #"{"title": "Proton Leak", "symbol": "drop", "questions": []}"#
        let draft = try JSONDecoder().decode(CourseQuizDraft.self, from: Data(named.utf8))
        #expect(draft.title == "Proton Leak")
        #expect(draft.symbol == "drop")
        let older = try JSONDecoder().decode(CourseQuizDraft.self, from: Data(#"{"questions": []}"#.utf8))
        #expect(older.title == nil && older.symbol == nil)
    }

    @Test("A quiz's symbol and picture round-trip through the store and ride its course's payload")
    func symbolAndArtworkStoreAndSync() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveCourseGroup(name: "course", metadata: CourseMetadata(title: "Bioenergetics"))
        var quiz = sampleQuiz(courseID: "course", lectureID: "l1")
        quiz.title = "Proton Leak"
        quiz.symbol = "drop"
        quiz.artwork = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02])
        try store.saveCourseQuiz(quiz)
        #expect(try store.loadCourseQuiz(quiz.id) == quiz)

        let payload = try #require(try store.loadCourseForSync("course"))
        let decoded = try JSONDecoder().decode(CloudKitCoursePayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.quizzes == [quiz])

        quiz.artwork = nil
        try store.saveCourseQuiz(quiz)
        #expect(try store.loadCourseQuiz(quiz.id)?.artwork == nil, "removing a picture clears it")
    }

    @Test("A quiz from a build without symbols or pictures decodes with neither")
    func olderQuizPayload() throws {
        let quiz = sampleQuiz(courseID: "course", lectureID: "l1")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(quiz)) as? [String: Any])
        object.removeValue(forKey: "symbol")
        object.removeValue(forKey: "artwork")
        let decoded = try JSONDecoder().decode(CourseQuiz.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == quiz)
        #expect(decoded.symbol == nil && decoded.artwork == nil)
    }

    @Test("A drawn picture is kept as a small square JPEG")
    func artworkJPEG() throws {
        let image = NSImage(size: NSSize(width: 1024, height: 768))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 768).fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: 300, y: 200, width: 400, height: 400)).fill()
        image.unlockFocus()
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let jpeg = try #require(CourseQuizGeneratorService.artworkJPEG(from: png))
        #expect(jpeg.count <= CourseQuizNaming.maximumArtworkBytes)
        let rep = try #require(NSBitmapImageRep(data: jpeg))
        #expect(rep.pixelsWide == CourseQuizNaming.artworkPixelSize)
        #expect(rep.pixelsHigh == CourseQuizNaming.artworkPixelSize)
    }

    @Test("A stored quiz's score is its own preference row")
    func scoreKey() throws {
        #expect(LectureQuizScore.preferenceKey(courseQuizID: "cq-1") == "courseQuiz.score.cq-1")
        #expect(SyncedPreferenceKeys.isSynced("courseQuiz.score.cq-1"))
        let suite = "CourseQuizPlanningTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LectureQuizScore(right: 3, total: 4, takenAt: Date()).preferenceValue, forKey: "courseQuiz.score.cq-1")
        defaults.set(LectureQuizScore(right: 1, total: 4, takenAt: Date()).preferenceValue, forKey: "lectureQuiz.score.video")
        let scores = LectureQuizScore.scoresFromDefaults(defaults, prefix: LectureQuizScore.courseQuizPreferenceKeyPrefix)
        #expect(Set(scores.keys) == ["cq-1"])
    }
}

@Suite("Course Quiz in Chat")
struct CourseQuizChatTests {
    private func question(
        _ number: Int,
        level: CourseQuizQuestion.Level?,
        lastLine: Int,
        startSeconds: Double? = nil,
        sourceID: String = "video"
    ) -> CourseQuizQuestion {
        CourseQuizQuestion(
            id: "q\(number)", sourceID: sourceID, firstLine: lastLine, lastLine: lastLine,
            startSeconds: startSeconds, question: "Question \(number)?", answer: "Answer \(number).",
            keyPoints: ["point \(number)"], quote: nil, levelName: level?.rawValue
        )
    }

    private func quiz(_ questions: [CourseQuizQuestion]) -> CourseQuiz {
        CourseQuiz(
            id: "quiz", courseID: "course", kind: .practice, title: "Cristae", lectureIDs: ["l1"],
            afterLectureID: "l1", questions: questions, author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
    }

    private func state(_ questions: [CourseQuizQuestion], readings: [CourseQuizReading] = []) -> CourseQuizChatState {
        CourseQuizChatState(request: CourseQuizChatRequest(
            quiz: quiz(questions),
            topic: "Quiz: Cristae",
            subtitle: "Lecture 1",
            sourceIDs: ["video"],
            sourceTitles: ["video": "Mitochondrial Cell Biology 1"],
            readings: readings,
            grade: { _, _, _ in (.graded(VideoQuizGrade(verdict: .correct, feedback: "Yes.")), nil) },
            recorded: { _, _ in }
        ))
    }

    // MARK: Picking a sitting back up

    @Test("A sitting's chat id names its quiz, and no other chat's id does")
    func sittingSessionID() {
        let id = CourseQuizSitting.sessionID(forQuizID: "abc-123")
        #expect(id.hasPrefix("course-quiz-abc-123-"))
        #expect(CourseQuizSitting.quizID(inSessionID: id) == "abc-123")
        #expect(CourseQuizSitting.quizID(inSessionID: "memory-2026-09-26") == nil)
        #expect(CourseQuizSitting.quizID(inSessionID: UUID().uuidString) == nil)
        #expect(CourseQuizSitting.quizID(inSessionID: "course-quiz-") == nil)
        #expect(CourseQuizSitting.quizID(inSessionID: "course-quiz-abc-not-a-uuid") == nil)
    }

    @Test("A reopened chat goes on from the first question it has not graded, and keeps the grades it had")
    func resumesWhereItStopped() throws {
        var first = state([question(1, level: .recall, lastLine: 3), question(2, level: .explain, lastLine: 5), question(3, level: .apply, lastLine: 7)])
        first.record(.correct, forQuestionAt: 0)
        first.record(.partial, forQuestionAt: 1)
        let stored = try #require(first.sitting.briefingText)
        let sitting = try #require(CourseQuizSitting(briefing: stored))
        #expect(sitting.quizID == "quiz")

        let resumed = CourseQuizChatState(request: first.request, resuming: sitting)
        #expect(resumed.currentIndex == 2)
        #expect(resumed.verdicts == ["q1": .correct, "q2": .partial])
        #expect(resumed.progressNote.contains("2 of 3 questions graded"))
        #expect(resumed.progressNote.contains("on question 3"))
        guard case .success(let target) = resumed.questionToGrade(arguments: ["question": 3, "answer": "x"]) else {
            Issue.record("The resumed quiz would not grade question 3"); return
        }
        #expect(target.index == 2)
        #expect(CourseQuizSitting(briefing: "Daily review focus: …") == nil)
        #expect(CourseQuizSitting(briefing: nil) == nil)
    }

    @Test("A grade is kept only while its question is still the one at that id")
    func rewrittenQuizDropsStaleGrades() {
        let sitting = CourseQuizSitting(quizID: "quiz", grades: [
            "q1": .init(verdict: .correct, question: "Question 1?"),
            "q2": .init(verdict: .incorrect, question: "A question the quiz no longer asks?"),
            "q9": .init(verdict: .correct, question: "Question 9?"),
        ])
        let current = quiz([question(1, level: .recall, lastLine: 3), question(2, level: .recall, lastLine: 5)])
        #expect(sitting.verdicts(for: current) == ["q1": .correct])
        let other = CourseQuizSitting(quizID: "another quiz", grades: ["q1": .init(verdict: .correct, question: "Question 1?")])
        #expect(CourseQuizChatState(request: state([question(1, level: .recall, lastLine: 3)]).request, resuming: other).verdicts.isEmpty)
    }

    @Test("A wholly superseded sitting is history, not a fresh chat for the rewritten quiz")
    func rewrittenQuizDoesNotReuseOldChat() {
        let old = CourseQuizSitting(quizID: "quiz", grades: [
            "old-q1": .init(verdict: .correct, question: "The old first question?"),
            "old-q2": .init(verdict: .incorrect, question: "The old second question?"),
        ])
        let row = (
            sessionID: CourseQuizSitting.sessionID(forQuizID: "quiz"),
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            briefing: old.briefingText
        )
        let rewritten = quiz([
            question(1, level: .recall, lastLine: 3),
            question(2, level: .explain, lastLine: 5),
            question(3, level: .apply, lastLine: 7),
        ])
        #expect(!old.canResume(in: rewritten))
        #expect(CourseQuizSitting.latest(rows: [row], quizzes: [rewritten]).isEmpty)
        #expect(CourseQuizSitting.latestFinished(rows: [row], quizzes: [rewritten]).isEmpty)

        // A blank current sitting remains reusable, and an exact surviving
        // grade still resumes where it left off.
        let blank = CourseQuizSitting(quizID: "quiz")
        #expect(blank.canResume(in: rewritten))
        let matching = CourseQuizSitting(quizID: "quiz", grades: [
            "q1": .init(verdict: .correct, question: "Question 1?"),
        ])
        #expect(matching.canResume(in: rewritten))
    }

    @Test("Each quiz's row follows its newest sitting, finished or not")
    func latestSittings() {
        let lectureQuiz = quiz([question(1, level: .recall, lastLine: 3), question(2, level: .recall, lastLine: 5)])
        let older = CourseQuizSitting(quizID: "quiz", grades: [
            "q1": .init(verdict: .correct, question: "Question 1?"),
            "q2": .init(verdict: .correct, question: "Question 2?"),
        ])
        let newer = CourseQuizSitting(quizID: "quiz", grades: ["q1": .init(verdict: .partial, question: "Question 1?")])
        let olderID = CourseQuizSitting.sessionID(forQuizID: "quiz")
        let newerID = CourseQuizSitting.sessionID(forQuizID: "quiz")
        let rows: [(sessionID: String, startedAt: Date, briefing: String?)] = [
            (olderID, Date(timeIntervalSinceReferenceDate: 100), older.briefingText),
            (newerID, Date(timeIntervalSinceReferenceDate: 200), newer.briefingText),
            (CourseQuizSitting.sessionID(forQuizID: "gone"), Date(timeIntervalSinceReferenceDate: 300), CourseQuizSitting(quizID: "gone").briefingText),
            (CourseQuizSitting.sessionID(forQuizID: "quiz"), Date(timeIntervalSinceReferenceDate: 50), nil),
        ]
        let latest = CourseQuizSitting.latest(rows: rows, quizzes: [lectureQuiz])
        #expect(Set(latest.keys) == ["quiz"])
        #expect(latest["quiz"]?.sessionID == newerID)
        #expect(latest["quiz"]?.done == 1)
        #expect(latest["quiz"]?.isFinished == false)
        let finished = CourseQuizSitting.latest(rows: [rows[0]], quizzes: [lectureQuiz])["quiz"]
        #expect(finished?.score?.right == 2)
        #expect(finished?.score?.takenAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test("A quiz's results are its newest finished sitting, past a newer one under way")
    func latestFinishedSittings() {
        let lectureQuiz = quiz([question(1, level: .recall, lastLine: 3), question(2, level: .recall, lastLine: 5)])
        let done = CourseQuizSitting(quizID: "quiz", grades: [
            "q1": .init(verdict: .correct, question: "Question 1?"),
            "q2": .init(verdict: .incorrect, question: "Question 2?"),
        ])
        let doneID = CourseQuizSitting.sessionID(forQuizID: "quiz")
        let rows: [(sessionID: String, startedAt: Date, briefing: String?)] = [
            (CourseQuizSitting.sessionID(forQuizID: "quiz"), Date(timeIntervalSinceReferenceDate: 50), done.briefingText),
            (doneID, Date(timeIntervalSinceReferenceDate: 100), done.briefingText),
            (CourseQuizSitting.sessionID(forQuizID: "quiz"), Date(timeIntervalSinceReferenceDate: 200), CourseQuizSitting(quizID: "quiz").briefingText),
        ]
        let finished = CourseQuizSitting.latestFinished(rows: rows, quizzes: [lectureQuiz])
        #expect(finished["quiz"]?.sessionID == doneID)
        #expect(finished["quiz"]?.score?.right == 1)
        #expect(CourseQuizSitting.latest(rows: rows, quizzes: [lectureQuiz])["quiz"]?.isUnderWay == false)
        #expect(CourseQuizSitting.latestFinished(rows: [rows[2]], quizzes: [lectureQuiz]).isEmpty)
    }

    @Test("A click on a quiz continues it, opens its results, or starts it, as Khan Academy does")
    func quizOpening() {
        let score = LectureQuizScore(right: 3, total: 4, takenAt: Date(timeIntervalSinceReferenceDate: 100))
        let results = CourseQuizSittingProgress(sessionID: "done", done: 4, total: 4, score: score)
        let fresh = CourseQuizSittingProgress(sessionID: "fresh", done: 0, total: 4, score: nil)
        let halfway = CourseQuizSittingProgress(sessionID: "halfway", done: 2, total: 4, score: nil)
        let all: (String) -> Bool = { _ in true }
        func open(_ latest: CourseQuizSittingProgress?, _ finished: CourseQuizSittingProgress?, retake: Bool = false, exists: (String) -> Bool = all) -> String? {
            CourseQuizOpening.chatToOpen(latest: latest, lastFinished: finished, retake: retake, chatExists: exists)
        }
        // A finished quiz opened again, left on question 1: its results.
        #expect(open(fresh, results) == "done")
        #expect(open(results, results) == "done")
        // Under way: picked back up; Start Over leaves it.
        #expect(open(halfway, results) == "halfway")
        #expect(open(halfway, nil, retake: true) == nil)
        // A retake reuses a sitting still on question 1.
        #expect(open(fresh, results, retake: true) == "fresh")
        #expect(open(results, results, retake: true) == nil)
        // Never taken: a sitting on question 1 is reused, else a new one.
        #expect(open(fresh, nil) == "fresh")
        #expect(open(nil, nil) == nil)
        // A deleted chat is passed over.
        #expect(open(fresh, results, exists: { $0 == "fresh" }) == "fresh")
        #expect(open(halfway, results, exists: { $0 == "done" }) == "done")
    }

    @Test("The tutor reads the questions, their levels and places, and never the answers")
    func briefingHidesAnswers() {
        let quiz = state([
            question(1, level: .recall, lastLine: 3, startSeconds: 754),
            question(2, level: .challenge, lastLine: 9),
        ])
        let briefing = quiz.questionList
        #expect(briefing.contains("1. [Recall · Mitochondrial Cell Biology 1 at 12:34 · source_id video]: Question 1?"))
        #expect(briefing.contains("2. [Challenge · Mitochondrial Cell Biology 1 · source_id video]: Question 2?"))
        #expect(!briefing.contains("Answer 1."))
        #expect(!briefing.contains("point 1"))
    }

    @Test("A quiz opens on its stored question 1, written by the app, without its answer")
    func openingMessageIsTheStoredFirstQuestion() {
        let quiz = state([
            question(1, level: .recall, lastLine: 3, startSeconds: 754),
            question(2, level: .challenge, lastLine: 9),
        ])
        #expect(quiz.openingMessage == "Quiz: Cristae · 2 questions\n\n**Question 1 of 2 · Recall**\n\nQuestion 1?")
        #expect(!quiz.openingMessage.contains("Answer 1."))
    }

    @Test("Only the question the quiz is on is graded, once, with the learner's answer; no later one is graded ahead of it")
    func gradesInOrder() {
        var quiz = state([question(1, level: .recall, lastLine: 3), question(2, level: .explain, lastLine: 5)])
        #expect(quiz.currentIndex == 0)
        guard case .failure = quiz.questionToGrade(arguments: ["question": 2, "answer": "x"]) else {
            Issue.record("Question 2 was graded while the quiz was on question 1"); return
        }
        guard case .failure = quiz.questionToGrade(arguments: ["question": 1, "answer": "  "]) else {
            Issue.record("An empty answer was graded"); return
        }
        guard case .success(let target) = quiz.questionToGrade(arguments: ["question": 1, "answer": " I don't know "]) else {
            Issue.record("An \"I don't know\" answer to the current question was refused"); return
        }
        #expect(target.index == 0)
        #expect(target.attempt.answer == "I don't know")
        #expect(target.attempt.followUp == nil)
        #expect(target.attempt.mayFollowUp, "the learner can reply in the chat, so a first answer may be followed up")
        quiz.record(.incorrect, forQuestionAt: 0)
        guard case .failure(let again) = quiz.questionToGrade(arguments: ["question": "1", "answer": "x"]) else {
            Issue.record("Question 1 was graded twice"); return
        }
        #expect(again.message.contains("already been graded"))
        #expect(quiz.currentIndex == 1)
    }

    @Test("A grade hands the tutor the reference answer, the moment to rewatch and the next question")
    func acknowledgementLeadsOn() {
        var quiz = state([
            question(1, level: .recall, lastLine: 3, startSeconds: 754.6),
            question(2, level: .apply, lastLine: 5),
        ])
        quiz.record(.partial, forQuestionAt: 0)
        let text = quiz.acknowledgement(
            forQuestionAt: 0,
            grade: VideoQuizGrade(verdict: .partial, feedback: "Half of it."),
            memoryError: nil
        )
        #expect(text.contains("Question 1 of 2 graded: partly right."))
        #expect(text.contains("Reference answer: Answer 1."))
        // ForeverLM writes the rewatch link under the feedback itself: the
        // tutor is told where it goes, never its address.
        #expect(text.contains("ForeverLM puts a link to Mitochondrial Cell Biology 1 at 12:34 under your feedback: write no link to it."))
        #expect(!text.contains("foreverlm://source"))
        #expect(text.contains("Next: **Question 2 of 2 · Apply** — Question 2?"))
        #expect(!quiz.isFinished)
    }

    @Test("A grade the chat's free model could not give has the tutor propose switching the chat's model")
    func gradingFailureProposesSwitch() {
        let text = CourseQuizChatState.gradingFailure(
            "Nemotron Nano 9B V2 (free) sent back a reply that is not a grade.",
            questionNumber: 1,
            model: .init(name: "Nemotron Nano 9B V2 (free)", isFree: true)
        )
        #expect(text.hasPrefix("Error: The grader could not grade this answer: Nemotron Nano 9B V2 (free) sent back a reply that is not a grade. Tell the learner"))
        #expect(text.contains("send their answer to question 1 again"))
        #expect(text.contains("Nemotron Nano 9B V2 (free), the model this chat runs on, a free model."))
        #expect(text.contains("Propose switching this chat to another model with the model chip under the message box"))
        #expect(!text.contains("Video Quiz Grading"))
        #expect(!text.contains("Video Checkpoint Grading"))
        #expect(!text.contains("set_ai_task_settings"), "the chat's model is the learner's pick in the composer, not a task")

        let paid = CourseQuizChatState.gradingFailure(
            "Upstream error", questionNumber: 2,
            model: .init(name: "GPT-5 Mini", isFree: false)
        )
        #expect(paid.hasPrefix("Error: The grader could not grade this answer: Upstream error. Tell the learner"))
        #expect(paid.contains("GPT-5 Mini, the model this chat runs on."))
        #expect(!paid.contains("free model"))
    }

    @Test("A busy grader, or one whose answer is no grade, is asked again twice, briefly; a lasting failure is not")
    func gradeRetryDelay() {
        let busy = AIError.httpError(status: 503, message: "Service temporarily overloaded", retryAfterSeconds: nil)
        #expect(QuizGrading.retryDelay(after: busy, failedAttempts: 1) == 2)
        #expect(QuizGrading.retryDelay(after: busy, failedAttempts: 2) == 4)
        #expect(QuizGrading.retryDelay(after: busy, failedAttempts: 3) == nil)
        #expect(QuizGrading.retryDelay(after: URLError(.networkConnectionLost), failedAttempts: 1) == 2)
        #expect(QuizGrading.retryDelay(after: AIError.httpError(status: 429, message: "slow down", retryAfterSeconds: 5), failedAttempts: 1) == 5)
        #expect(QuizGrading.retryDelay(after: AIError.httpError(status: 429, message: "slow down", retryAfterSeconds: 60), failedAttempts: 1) == nil)
        #expect(QuizGrading.retryDelay(after: AIError.httpError(status: 401, message: "bad key", retryAfterSeconds: nil), failedAttempts: 1) == nil)
        #expect(QuizGrading.retryDelay(after: CancellationError(), failedAttempts: 1) == nil)
        // An answer that is not a grade (product owner, 2026-09-27: "there should
        // be some fallbacks here"): unreadable, empty, or cut off.
        #expect(QuizGrading.retryDelay(after: AIError.invalidResponse, failedAttempts: 1) == 2)
        #expect(QuizGrading.retryDelay(after: AIError.invalidResponse, failedAttempts: 2) == 4)
        #expect(QuizGrading.retryDelay(after: AIError.invalidResponse, failedAttempts: 3) == nil)
        #expect(QuizGrading.retryDelay(after: AIError.emptyAnswer(model: "nvidia/nemotron-3-super-120b-a12b:free"), failedAttempts: 1) == 2)
        #expect(QuizGrading.retryDelay(after: AIError.outputTokenLimit("stopped at the length limit"), failedAttempts: 1) == 2)
        #expect(QuizGrading.retryDelay(after: AIError.apiError("The request was refused."), failedAttempts: 1) == nil)
    }

    @Test("A grade is asked for again until one comes back, after 2 s and 4 s, and the last failure is reported")
    func gradeWithRetries() async throws {
        var waits: [Double] = []
        var tries = 0
        let grade: VideoQuizGrade = try await QuizGrading.withRetries(
            sleep: { waits.append($0) },
            operation: {
                tries += 1
                if tries < 3 { throw AIError.invalidResponse }
                return VideoQuizGrade(verdict: .correct, feedback: "Yes.")
            }
        )
        #expect(grade.verdict == .correct)
        #expect(tries == 3)
        #expect(waits == [2, 4])

        waits = []
        tries = 0
        do {
            _ = try await QuizGrading.withRetries(
                sleep: { waits.append($0) },
                operation: { () async throws -> VideoQuizGrade in
                    tries += 1
                    throw AIError.invalidResponse
                }
            )
            Issue.record("Three answers that were not grades still gave a grade")
        } catch {
            #expect(QuizGrading.isUnusableAnswer(error))
        }
        #expect(tries == QuizGrading.attempts)
        #expect(waits == [2, 4])

        waits = []
        tries = 0
        do {
            _ = try await QuizGrading.withRetries(
                sleep: { waits.append($0) },
                operation: { () async throws -> VideoQuizGrade in
                    tries += 1
                    throw AIError.httpError(status: 402, message: "AI balance empty", retryAfterSeconds: nil)
                }
            )
            Issue.record("A failure every model shares gave a grade")
        } catch {
            #expect(!QuizGrading.isUnusableAnswer(error))
        }
        #expect(tries == 1, "a lasting failure is reported at once")
        #expect(waits.isEmpty)
    }

    @Test("A grade no try could give names the model that was asked, and whether another could get past it")
    func gradingFailureNamesTheModel() {
        let unreadable = QuizGradingFailure(underlying: AIError.invalidResponse, modelName: "Claude Sonnet 5", modelIsFree: false)
        #expect(unreadable.localizedDescription == "Claude Sonnet 5 sent back a reply that is not a grade.")
        #expect(unreadable.anotherModelCouldGrade)
        let empty = QuizGradingFailure(underlying: AIError.emptyAnswer(model: "x:free"), modelName: "Nemotron 3 Super (free)", modelIsFree: true)
        #expect(empty.localizedDescription == "Nemotron 3 Super (free) sent back an empty answer.")
        let busy = QuizGradingFailure(
            underlying: AIError.httpError(status: 503, message: "Service temporarily overloaded", retryAfterSeconds: nil),
            modelName: "Nemotron 3 Super (free)", modelIsFree: true
        )
        #expect(busy.localizedDescription == "Nemotron 3 Super (free) could not grade it: Service temporarily overloaded")
        #expect(busy.anotherModelCouldGrade)
        #expect(QuizGradingFailure(underlying: URLError(.networkConnectionLost), modelName: "M", modelIsFree: false).anotherModelCouldGrade)
        #expect(!QuizGradingFailure(underlying: URLError(.notConnectedToInternet), modelName: "M", modelIsFree: false).anotherModelCouldGrade)
        #expect(!QuizGradingFailure(
            underlying: AIError.httpError(status: 402, message: "AI balance empty", retryAfterSeconds: nil),
            modelName: "M", modelIsFree: false
        ).anotherModelCouldGrade)
        #expect(!QuizGradingFailure(underlying: AIError.missingAPIKey, modelName: "M", modelIsFree: false).anotherModelCouldGrade)
    }

    @Test("A quiz's chat grades on the chat's own model, where the chat runs, with no backups of its own")
    func gradesOnTheChatsModel() {
        var chat = AITaskConfig(provider: .openRouter, apiKey: "key", model: "anthropic/claude-sonnet-5", effort: .high)
        chat.taskLabel = "chat"
        let grader = CourseQuizChatState.graderConfig(forChat: chat)
        #expect(grader.provider == .openRouter)
        #expect(grader.model == "anthropic/claude-sonnet-5")
        #expect(grader.apiKey == "key")
        #expect(grader.effort == .high)
        #expect(!grader.isBackup)
        #expect(grader.taskLabel == QuizGrading.chatTaskLabel)
        #expect(grader.taskLabel == "chat_quiz_grading")
        // No background task's route or its backups: chat has none.
        #expect(AIBackupModels.configs(after: grader).isEmpty)
        #expect(AIService.openRouterHostSlots(forTaskLabel: grader.taskLabel) == ["chat"])
        #expect(AIUsageTaskLabel.text(for: "chat_quiz_grading") == "Grade Quiz Answer in Chat")
    }

    @Test("An answer on its way gets one follow-up; the reply is graded with it, even after the chat is reopened")
    func followUpBeforeTheGrade() throws {
        var quiz = state([question(1, level: .explain, lastLine: 3), question(2, level: .recall, lastLine: 5)])
        guard case .success(let first) = quiz.questionToGrade(arguments: ["question": 1, "answer": "Mitophagy stops"]) else {
            Issue.record("The first answer to question 1 was refused"); return
        }
        #expect(first.attempt.mayFollowUp)
        quiz.recordFollowUp("Why does it stop?", answer: first.attempt.answer, forQuestionAt: 0)
        #expect(quiz.currentIndex == 0, "a follow-up grades nothing")
        #expect(quiz.verdicts.isEmpty)
        #expect(quiz.progressNote.contains("the grader has asked a follow-up on the learner's answer: \"Why does it stop?\""))
        let asked = quiz.followUpRequest(forQuestionAt: 0, followUp: "Why does it stop?")
        #expect(asked.contains("Question 1 of 2 is not graded yet"))
        #expect(asked.contains("Follow-up: Why does it stop?"))
        #expect(asked.contains("no verdict yet"))
        #expect(!asked.contains("Answer 1."), "a follow-up carries no reference answer")
        #expect(!asked.contains("point 1"))

        // Closed before the reply and opened again: the follow-up still waits.
        let stored = try #require(quiz.sitting.briefingText)
        #expect(stored.contains("\"follow_up\""))
        let resumed = CourseQuizChatState(request: quiz.request, resuming: CourseQuizSitting(briefing: stored))
        #expect(resumed.followUp == quiz.followUp)
        guard case .success(let reply) = resumed.questionToGrade(arguments: ["question": 1, "answer": " It needs fission first "]) else {
            Issue.record("The reply to the follow-up was refused"); return
        }
        #expect(reply.index == 0)
        #expect(reply.attempt.answer == "Mitophagy stops", "the first answer is kept")
        #expect(reply.attempt.followUp == QuizAnswerAttempt.FollowUp(question: "Why does it stop?", reply: "It needs fission first"))
        #expect(!reply.attempt.mayFollowUp, "there is no second follow-up")
        #expect(reply.attempt.memoryText == "Mitophagy stops\nFollow-up: Why does it stop?\nIt needs fission first")
        guard case .failure(let empty) = resumed.questionToGrade(arguments: ["question": 1, "answer": "  "]) else {
            Issue.record("An empty reply was graded"); return
        }
        #expect(empty.message.contains("reply to the follow-up"))

        // One grade for the answer and its reply, and the follow-up is gone.
        quiz.record(.correct, forQuestionAt: 0)
        #expect(quiz.followUp == nil)
        #expect(quiz.sitting.followUp == nil)
        #expect(quiz.currentIndex == 1)
        guard case .success(let next) = quiz.questionToGrade(arguments: ["question": 2, "answer": "OPA1"]) else {
            Issue.record("Question 2 was refused after question 1's grade"); return
        }
        #expect(next.attempt.followUp == nil)
        #expect(next.attempt.mayFollowUp)
    }

    @Test("A waiting follow-up is dropped when its question was rewritten, and a sitting from before follow-ups reads as none")
    func staleFollowUpIsDropped() throws {
        let questions = [question(1, level: .explain, lastLine: 3), question(2, level: .recall, lastLine: 5)]
        let rewritten = CourseQuizSitting(
            quizID: "quiz",
            grades: [:],
            followUp: .init(questionID: "q1", question: "An older wording?", answer: "a", followUp: "f")
        )
        #expect(CourseQuizChatState(request: state(questions).request, resuming: rewritten).followUp == nil)
        let older = try #require(CourseQuizSitting(briefing: #"{"course_quiz_sitting":{"grades":{"q1":{"question":"Question 1?","verdict":"correct"}},"quiz_id":"quiz"}}"#))
        #expect(older.followUp == nil)
        #expect(older.verdicts(for: quiz(questions)) == ["q1": .correct])
    }

    @Test("A free model's name ends in (free) once")
    func freeModelName() {
        #expect(AIModelCatalog.markingFree("Space Bunny Alpha", isFree: true) == "Space Bunny Alpha (free)")
        #expect(AIModelCatalog.markingFree("Nemotron 3 Ultra (free)", isFree: true) == "Nemotron 3 Ultra (free)")
        #expect(AIModelCatalog.markingFree("Nemotron 3 Ultra (Free)", isFree: true) == "Nemotron 3 Ultra (Free)")
        #expect(AIModelCatalog.markingFree("GPT-5 Mini", isFree: false) == "GPT-5 Mini")
        // The Free Models Router's own name says it already.
        #expect(!AIModelCatalog.pickerName(provider: .openRouter, modelID: AIModelDefaults.openRouterFreeRouter).hasSuffix("(free)"))
    }

    @Test("A grade no model could give proposes no switch")
    func gradingFailureWithoutModel() {
        let text = CourseQuizChatState.gradingFailure("No API key", questionNumber: 3, model: nil)
        #expect(text.contains("send their answer to question 3 again"))
        #expect(!text.contains("Propose switching"))
    }

    @Test("The last first-pass grade records the score and offers corrections for missed questions")
    func lastGradeScores() {
        var quiz = state([question(1, level: .recall, lastLine: 3), question(2, level: .explain, lastLine: 5)])
        quiz.record(.correct, forQuestionAt: 0)
        quiz.record(.partial, forQuestionAt: 1)
        #expect(quiz.isFinished)
        #expect(quiz.score.right == 1)
        #expect(quiz.score.total == 2)
        let text = quiz.acknowledgement(
            forQuestionAt: 1,
            grade: VideoQuizGrade(verdict: .partial, feedback: "Close."),
            memoryError: "no passage"
        )
        #expect(text.contains("That was the last question. Score: 1 of 2 right."))
        #expect(text.contains("Not fully right: questions 2."))
        #expect(text.contains("Memory could not keep this question (no passage)"))
        #expect(text.contains("may answer any not-fully-right question again here"))
        guard case .failure = quiz.questionToGrade(arguments: ["question": 3, "answer": "x"]) else {
            Issue.record("A question outside the finished quiz was graded"); return
        }
    }

    @Test("A finished 5 of 8 sitting can correct missed questions to 8 of 8, including across a reopen and follow-up")
    func finishedSittingCanReachEveryQuestionRight() throws {
        let questions = (1...8).map { question($0, level: .recall, lastLine: $0 * 2) }
        var quiz = state(questions)
        for index in questions.indices {
            quiz.record([1, 3, 7].contains(index) ? .incorrect : .correct, forQuestionAt: index)
        }
        #expect(quiz.isFinished)
        #expect(quiz.score.right == 5)
        #expect(quiz.progressNote.contains("Questions 2, 4, 8 are not fully right and may be corrected"))

        guard case .success(let firstCorrection) = quiz.questionToGrade(arguments: ["question": 2, "answer": "A better start"]) else {
            Issue.record("The finished quiz refused a revised answer to question 2"); return
        }
        #expect(firstCorrection.index == 1)
        quiz.recordFollowUp("What completes it?", answer: firstCorrection.attempt.answer, forQuestionAt: firstCorrection.index)

        // A correction awaiting its grader follow-up is kept when the results
        // chat is closed and reopened, and no other correction jumps it.
        let stored = try #require(quiz.sitting.briefingText)
        var resumed = CourseQuizChatState(request: quiz.request, resuming: CourseQuizSitting(briefing: stored))
        #expect(resumed.followUp?.questionID == "q2")
        #expect(resumed.progressNote.contains("completed quiz is revisiting question 2"))
        guard case .failure(let waiting) = resumed.questionToGrade(arguments: ["question": 4, "answer": "Too soon"]) else {
            Issue.record("Another question displaced a correction's pending follow-up"); return
        }
        #expect(waiting.message.contains("Question 2 is waiting"))
        guard case .success(let reply) = resumed.questionToGrade(arguments: ["question": 2, "answer": "The missing part"]) else {
            Issue.record("The correction's follow-up reply was refused after reopen"); return
        }
        #expect(reply.attempt.answer == "A better start")
        #expect(reply.attempt.followUp?.reply == "The missing part")
        resumed.record(.correct, forQuestionAt: 1)

        for number in [4, 8] {
            guard case .success(let correction) = resumed.questionToGrade(arguments: ["question": number, "answer": "Corrected answer"]) else {
                Issue.record("The finished quiz refused a correction to question \(number)"); return
            }
            resumed.record(.correct, forQuestionAt: correction.index)
        }
        #expect(resumed.score.right == 8)
        #expect(resumed.progress(sessionID: "sitting").score?.right == 8)
        #expect(resumed.progressNote.contains("every question is fully right"))
        let acknowledgement = resumed.acknowledgement(
            forQuestionAt: 7,
            grade: VideoQuizGrade(verdict: .correct, feedback: "Yes."),
            memoryError: nil,
            isCorrection: true
        )
        #expect(acknowledgement.contains("Correction recorded. Updated score: 8 of 8 right."))
        #expect(acknowledgement.contains("Every question is now fully right."))
        guard case .failure(let alreadyRight) = resumed.questionToGrade(arguments: ["question": 2, "answer": "Again"]) else {
            Issue.record("An already fully right question was regraded"); return
        }
        #expect(alreadyRight.message.contains("already fully right"))
    }

    // MARK: Skipping a question

    @Test("A skipped question gets no grade and no answer, moves the quiz on, and counts as not right")
    func skipMovesOnWithoutAGrade() {
        var quiz = state([
            question(1, level: .recall, lastLine: 3),
            question(2, level: .explain, lastLine: 5),
            question(3, level: .apply, lastLine: 7),
        ])
        #expect(quiz.skipToolSpec.name == "skip_quiz_question")
        guard case .failure(let ahead) = quiz.questionToSkip(arguments: ["question": 2]) else {
            Issue.record("Question 2 was skipped while the quiz was on question 1"); return
        }
        #expect(ahead.message.contains("The learner is on question 1"))
        guard case .success(let index) = quiz.questionToSkip(arguments: ["question": "1"]) else {
            Issue.record("The question the quiz is on could not be skipped"); return
        }
        #expect(index == 0)
        quiz.recordSkip(forQuestionAt: 0)
        #expect(quiz.currentIndex == 1)
        #expect(quiz.verdicts.isEmpty, "a skip is no grade")
        #expect(quiz.skipped == ["q1"])
        #expect(quiz.progress(sessionID: "s").done == 1)
        #expect(quiz.progress(sessionID: "s").isUnderWay)
        guard case .failure(let skippedAlready) = quiz.questionToGrade(arguments: ["question": 1, "answer": "x"]) else {
            Issue.record("A skipped question was graded"); return
        }
        #expect(skippedAlready.message.contains("Question 1 was skipped"))
        #expect(quiz.progressNote.contains("Skipped by the learner: questions 1."))
        #expect(quiz.progressNote.contains("on question 2"))

        let skip = quiz.skipAcknowledgement(forQuestionAt: 0)
        #expect(skip.contains("Question 1 of 3 skipped at the learner's request"))
        #expect(skip.contains("nothing kept in Memory"))
        #expect(skip.contains("Next: **Question 2 of 3 · Explain** — Question 2?"))
        #expect(!skip.contains("Answer 1."), "a skip does not give the answer away")
        #expect(!skip.contains("point 1"))

        quiz.record(.correct, forQuestionAt: 1)
        quiz.recordSkip(forQuestionAt: 2)
        #expect(quiz.isFinished)
        #expect(quiz.score.right == 1)
        #expect(quiz.score.total == 3, "a skip counts against the pass")
        #expect(!quiz.score.passes)
        #expect(quiz.progress(sessionID: "s").score?.right == 1)
        let last = quiz.skipAcknowledgement(forQuestionAt: 2)
        #expect(last.contains("That was the last question. Score: 1 of 3 right."))
        #expect(last.contains("Skipped, and counted as not right: questions 1, 3."))
        #expect(!last.contains("Not fully right"))
        #expect(last.contains("without their answers"))
        #expect(!last.contains("Answer 3."))
        #expect(quiz.progressNote.contains("every question has been graded or skipped"))
        guard case .failure = quiz.questionToSkip(arguments: ["question": 3]) else {
            Issue.record("A finished quiz skipped again"); return
        }

        // Once every question is settled, a skipped one can still be answered
        // as a correction, and then counts as graded.
        guard case .success(let late) = quiz.questionToGrade(arguments: ["question": 3, "answer": "A late answer"]) else {
            Issue.record("A skipped question could not be answered after the last question"); return
        }
        #expect(late.index == 2)
        quiz.record(.correct, forQuestionAt: late.index)
        #expect(quiz.skipped == ["q1"])
        #expect(quiz.score.right == 2)
    }

    // MARK: The sitting owns the open question

    private func worded(_ number: Int, _ text: String) -> CourseQuizQuestion {
        CourseQuizQuestion(
            id: "q\(number)", sourceID: "video", firstLine: number, lastLine: number,
            startSeconds: nil, question: text, answer: "Answer \(number).",
            keyPoints: [], quote: nil, levelName: CourseQuizQuestion.Level.recall.rawValue
        )
    }

    @Test("A reply that asks the next question before the open one is graded is caught, as it was at question 6")
    func replyPastTheOpenQuestionIsCaught() {
        // The product owner's sitting of 2026-09-28: five graded, the grader never called
        // for question 6, and this reply, word for word, on the screen.
        var quiz = state([
            worded(1, "Why is mitochondrial biogenesis better understood as expansion of a network's components?"),
            worded(2, "Why must mitochondrial mass be regulated rather than maximized?"),
            worded(3, "Name two signaling components highlighted as regulators of mitochondrial biogenesis."),
            worded(4, "Why can measuring PGC-1α and one mitochondrial marker give a misleading picture of biogenesis?"),
            worded(5, "What three broad biosynthetic systems must be coordinated to expand mitochondrial mass?"),
            worded(6, "How many oxidative-phosphorylation proteins are encoded by mitochondrial DNA, and where are most mitochondrial proteins encoded?"),
            worded(7, "What does TOM recognize, and across which membrane does it act?"),
        ])
        for index in 0..<5 { quiz.record(.partial, forQuestionAt: index) }
        #expect(quiz.currentIndex == 5)
        let selfGraded = """
            Close — the nucleus is right, but the number is 13, not 17. Only 13 of the oxidative-phosphorylation components come from mitochondrial DNA; the rest of the ~1,500 mitochondrial proteins are nuclear-encoded and must be imported.

            ![13 mtDNA-encoded OXPHOS subunits](foreverlm://image/generated/8e4d5b2c-1f4a-4a3e-9c1d-6b2f8a7e5d41)

            [Rewatch 3:52](foreverlm://source/video?t=232)

            **Question 7 of 7 · Recall**

            What does TOM recognize, and across which membrane does it act?
            """
        #expect(quiz.questionShownOutOfTurn(in: selfGraded) == 7)
        // Its heading alone, or its words alone, give it away.
        #expect(quiz.questionShownOutOfTurn(in: "Close.\n\n### Question 7 of 7") == 7)
        #expect(quiz.questionShownOutOfTurn(in: "Close. Next: *What does TOM recognize,*\nand across which membrane does it act?") == 7)
        #expect(quiz.questionShownOutOfTurn(in: "> **Question 7 of 7 · Recall**") == 7)

        // Keeping to question 6 is fine: asking it again, answering a question
        // of the learner's, asking the grader's follow-up.
        #expect(quiz.questionShownOutOfTurn(in: "**Question 6 of 7 · Recall**\n\nHow many oxidative-phosphorylation proteins are encoded by mitochondrial DNA, and where are most mitochondrial proteins encoded?") == nil)
        #expect(quiz.questionShownOutOfTurn(in: "OXPHOS is oxidative phosphorylation. Give question 6 your best answer.") == nil)
        // A question named in passing is not asked: no heading at a line's start.
        #expect(quiz.questionShownOutOfTurn(in: "After this we reach question 7 of 7, the last.") == nil)
        // Another quiz's count is not this one's heading.
        #expect(quiz.questionShownOutOfTurn(in: "**Question 7 of 20 · Recall**") == nil)
        // A short question is matched by its heading only.
        #expect(CourseQuizChatState.shownQuestionMinimumWords == 5)

        let correction = quiz.outOfTurnCorrection(shown: 7)
        #expect(correction.contains("the learner has not seen it"))
        #expect(correction.contains("it showed question 7, but the quiz is on question 6, which has no grade"))
        #expect(correction.contains("call grade_quiz_answer now with question 6"))
        #expect(correction.contains("skip_quiz_question"))
        #expect(!correction.contains("Answer 6."), "the correction gives the tutor no reference answer")
        let failure = quiz.outOfTurnFailure(shown: 7)
        #expect(failure.contains("went on to question 7 while question 6 was still waiting for its grade"))
        #expect(failure.contains("nothing was graded or kept"))
        #expect(quiz.progressNote.contains("Until grade_quiz_answer or skip_quiz_question returns for question 6, never say whether an answer is right, never give its answer, and never show another question"))

        // Once question 6 is graded, the same reply keeps to the sitting: its
        // feedback is on a settled question and question 7 is the open one.
        quiz.record(.partial, forQuestionAt: 5)
        #expect(quiz.questionShownOutOfTurn(in: selfGraded) == nil)
    }

    @Test("Past a follow-up, a skip, or the last question, only a question not yet reached is out of turn")
    func outOfTurnFollowsTheSitting() {
        let questions = [
            worded(1, "What does the lecture say sets the width of a crista junction?"),
            worded(2, "What happens to the cristae when OPA1 is lost, and why?"),
            worded(3, "Predict how oligomycin and FCCP affect voltage heterogeneity along the inner membrane."),
        ]
        let asksTwo = "**Question 2 of 3 · Recall**\n\nWhat happens to the cristae when OPA1 is lost, and why?"
        let asksThree = "**Question 3 of 3 · Recall**\n\nPredict how oligomycin and FCCP affect voltage heterogeneity along the inner membrane."

        // A follow-up grades nothing: the sitting is still on question 1.
        var followedUp = state(questions)
        followedUp.recordFollowUp("Which protein?", answer: "an oligomer", forQuestionAt: 0)
        #expect(followedUp.questionShownOutOfTurn(in: "Right track.\n\n" + asksTwo) == 2)
        let correction = followedUp.outOfTurnCorrection(shown: 2)
        #expect(correction.contains("question 1 is still waiting for the learner's reply to the grader's follow-up"))
        #expect(correction.contains("their reply as they wrote it"))
        #expect(followedUp.progressNote.contains("Until grade_quiz_answer or skip_quiz_question returns for question 1"))

        // A skip settles question 1: naming it is fine, question 2 is open.
        var skipped = state(questions)
        skipped.recordSkip(forQuestionAt: 0)
        #expect(skipped.questionShownOutOfTurn(in: "Skipped: what does the lecture say sets the width of a crista junction?\n\n" + asksTwo) == nil)
        #expect(skipped.questionShownOutOfTurn(in: asksThree) == 3)

        // A finished sitting may revisit any question.
        var finished = state(questions)
        for index in questions.indices { finished.record(.incorrect, forQuestionAt: index) }
        #expect(finished.isFinished)
        #expect(finished.questionShownOutOfTurn(in: asksTwo + "\n\n" + asksThree) == nil)
        #expect(!finished.progressNote.contains("ForeverLM withholds"))
        var revisiting = finished
        revisiting.recordFollowUp("Why?", answer: "they widen", forQuestionAt: 1)
        #expect(!revisiting.progressNote.contains("ForeverLM withholds"), "a completed quiz's correction has no open question to keep to")
    }

    @Test("A skip is kept with the chat: a reopened quiz goes on past it, and asks it again once reworded")
    func skipSurvivesAReopen() throws {
        let questions = [question(1, level: .recall, lastLine: 3), question(2, level: .explain, lastLine: 5)]
        var graded = state(questions)
        graded.record(.correct, forQuestionAt: 0)
        #expect(try #require(graded.sitting.briefingText).contains("skipped") == false, "a sitting without skips is kept as before")

        var quiz = state(questions)
        quiz.recordSkip(forQuestionAt: 0)
        let stored = try #require(quiz.sitting.briefingText)
        #expect(stored.contains(#""skipped":{"q1":"Question 1?"}"#))
        let resumed = CourseQuizChatState(request: quiz.request, resuming: CourseQuizSitting(briefing: stored))
        #expect(resumed.skipped == ["q1"])
        #expect(resumed.currentIndex == 1)

        let reworded = CourseQuizSitting(quizID: "quiz", skipped: ["q1": "An older wording?"])
        #expect(CourseQuizChatState(request: quiz.request, resuming: reworded).currentIndex == 0)

        let finished = CourseQuizSitting(
            quizID: "quiz",
            grades: ["q1": .init(verdict: .correct, question: "Question 1?")],
            skipped: ["q2": "Question 2?"]
        )
        let progress = finished.progress(for: quiz.request.quiz, sessionID: "s", takenAt: Date(timeIntervalSinceReferenceDate: 100))
        #expect(progress.done == 2)
        #expect(progress.isFinished)
        #expect(progress.score?.right == 1)
        #expect(progress.score?.total == 2)
    }

    @Test("Skipping during a follow-up drops the follow-up and the answer it followed")
    func skipDropsAWaitingFollowUp() {
        var quiz = state([question(1, level: .explain, lastLine: 3), question(2, level: .recall, lastLine: 5)])
        quiz.recordFollowUp("Why does it stop?", answer: "Mitophagy stops", forQuestionAt: 0)
        guard case .success(let index) = quiz.questionToSkip(arguments: ["question": 1]) else {
            Issue.record("A question with a follow-up waiting could not be skipped"); return
        }
        quiz.recordSkip(forQuestionAt: index)
        #expect(quiz.followUp == nil)
        #expect(quiz.sitting.followUp == nil)
        #expect(quiz.verdicts.isEmpty)
        #expect(quiz.currentIndex == 1)
    }

    // MARK: Planned readings

    private func reading(
        sources: Set<String> = ["video"],
        pages: ClosedRange<Int>? = 3...5,
        reason: String? = "Your cell biology covers the rest."
    ) -> CourseQuizReading {
        CourseQuizReading(
            lectureSourceIDs: sources,
            lectureTitle: "Lecture 2, Mitochondrial Cell Biology 1",
            chapterID: "chapter10",
            chapterTitle: "10 Mitochondrial Structure",
            bookTitle: "Bioenergetics 4",
            sections: "10.2 Cristae [and junctions]",
            pages: pages,
            reason: reason
        )
    }

    @Test("The tutor reads the planned readings, and each question names its lecture's")
    func briefingListsPlannedReadings() {
        let quiz = state(
            [question(1, level: .recall, lastLine: 3), question(2, level: .explain, lastLine: 5, sourceID: "other")],
            readings: [reading()]
        )
        let briefing = quiz.questionList
        #expect(briefing.contains("1. [Recall · Mitochondrial Cell Biology 1 · source_id video · reading R1]: Question 1?"))
        #expect(briefing.contains("2. [Explain · the lecture · source_id other]: Question 2?"))
        #expect(briefing.contains("R1. With Lecture 2, Mitochondrial Cell Biology 1: 10.2 Cristae [and junctions] (Bioenergetics 4, 10 Mitochondrial Structure, pages 3–5)"))
        #expect(briefing.contains("[10.2 Cristae (and junctions)](foreverlm://source/chapter10?page=3)"))
        #expect(briefing.contains("why: Your cell biology covers the rest."))
        #expect(quiz.readingToolSpec?.name == CourseQuizChatState.readingToolName)
    }

    @Test("A quiz whose lectures have no planned reading says nothing of readings")
    func noReadingsNoMention() {
        var quiz = state([question(1, level: .recall, lastLine: 3), question(2, level: .apply, lastLine: 5)])
        #expect(!quiz.questionList.contains("Planned readings"))
        #expect(quiz.readingToolSpec == nil)
        quiz.record(.incorrect, forQuestionAt: 0)
        let text = quiz.acknowledgement(
            forQuestionAt: 0, grade: VideoQuizGrade(verdict: .incorrect, feedback: "No."), memoryError: nil
        )
        #expect(!text.contains("reading"))
    }

    @Test("A grade points to the question's planned reading at its first page")
    func acknowledgementGivesPlannedReading() {
        var quiz = state(
            [question(1, level: .recall, lastLine: 3), question(2, level: .apply, lastLine: 5)],
            readings: [reading(pages: 7...7)]
        )
        quiz.record(.incorrect, forQuestionAt: 0)
        let text = quiz.acknowledgement(
            forQuestionAt: 0, grade: VideoQuizGrade(verdict: .incorrect, feedback: "No."), memoryError: nil
        )
        #expect(text.contains("Planned reading R1: [10.2 Cristae (and junctions)](foreverlm://source/chapter10?page=7) (Bioenergetics 4, 10 Mitochondrial Structure, page 7)"))
        #expect(text.contains("the planned reading's link when the answer was missed"))
    }

    @Test("read_planned_reading takes a reading by its number, R1 or 1, and no other")
    func readingByNumber() {
        let quiz = state([question(1, level: .recall, lastLine: 3)], readings: [reading(), reading(pages: nil)])
        guard case .success(let first) = quiz.readingToRead(arguments: ["reading": 1]) else {
            Issue.record("Reading 1 was refused"); return
        }
        #expect(first.number == 1 && first.reading.pages == 3...5)
        guard case .success(let second) = quiz.readingToRead(arguments: ["reading": "R2"]) else {
            Issue.record("Reading R2 was refused"); return
        }
        #expect(second.number == 2 && second.reading.pages == nil)
        guard case .failure = quiz.readingToRead(arguments: ["reading": 3]) else {
            Issue.record("A reading the quiz does not have was read"); return
        }
        guard case .failure = quiz.readingToRead(arguments: [:]) else {
            Issue.record("A call naming no reading was read"); return
        }
    }

    @Test("A reading's text is exactly its pages of the chapter, or the chapter when read whole")
    func readingTextIsItsPages() {
        let content = "10 Mitochondrial Structure\n[page 1]\nOne.\n[page 2]\nTwo.\n[page 3]\nThree.\n[page 4]\nFour."
        #expect(CourseQuizReading.text(of: 2...3, in: content) == "[page 2]\nTwo.\n[page 3]\nThree.")
        #expect(CourseQuizReading.text(of: nil, in: content) == content)
        #expect(CourseQuizReading.text(of: 8...9, in: content) == nil)
        let result = CourseQuizChatState.readingResult(number: 1, reading: reading(), text: "[page 3]\nThree.")
        #expect(result.hasPrefix("Planned reading R1: 10.2 Cristae [and junctions]\nWhere: Bioenergetics 4, 10 Mitochondrial Structure, pages 3–5."))
        #expect(result.contains("Why it was planned: Your cell biology covers the rest."))
        #expect(result.hasSuffix("[page 3]\nThree."))
    }
}

@Suite("Course Quiz Pictures")
struct CourseQuizPictureTests {
    private static let content = """
    [0:00] Welcome to the lecture.

    [12:03] Cardiolipin has four acyl chains.

    ## Extracted video slide frames

    Representative slide screenshots extracted from this video's frames.

    ### Slide frame 1 [0:00–0:40]
    Image: Videos/video/Slides/slide_001_000000s.jpg

    ### Slide frame 2 [12:03–13:10]
    Image: Videos/video/Slides/slide_002_000723s.jpg

    Recognized slide text:
    Inner Mitochondrial Membrane
    Phospholipids   Cardiolipin

    ### Slide frame 3 [21:00–21:40]
    Image: Videos/video/Slides/slide_003_001260s.jpg
    Non-slide: true
    """

    private func question(_ number: Int, startSeconds: Double? = 723, picture: CourseQuizPicture? = nil) -> CourseQuizQuestion {
        CourseQuizQuestion(
            id: "q\(number)", sourceID: "video", firstLine: 2, lastLine: 2,
            startSeconds: startSeconds, question: "Question \(number)?", answer: "Answer \(number).",
            keyPoints: [], quote: nil, levelName: "recall", picture: picture
        )
    }

    private func state(_ questions: [CourseQuizQuestion]) -> CourseQuizChatState {
        CourseQuizChatState(request: CourseQuizChatRequest(
            quiz: CourseQuiz(
                id: "quiz", courseID: "course", kind: .practice, title: "Cardiolipin", lectureIDs: ["l1"],
                afterLectureID: "l1", questions: questions, author: .foreverlm, createdAt: Date(), updatedAt: Date()
            ),
            topic: "Quiz: Cardiolipin",
            subtitle: "Lecture 2",
            sourceIDs: ["video"],
            sourceTitles: ["video": "Mitochondrial Cell Biology 2"],
            grade: { _, _, _ in (.graded(VideoQuizGrade(verdict: .correct, feedback: "Yes.")), nil) },
            recorded: { _, _ in }
        ))
    }

    private let frame = SourceImageReference(sourceID: "video", location: .moment(723))
    /// Slide 2 as it stands before slide 3: 10 seconds before 13:10.
    private let builtFrame = SourceImageReference(sourceID: "video", location: .moment(780))

    @Test("A quiz stored before pictures still decodes, and a picture survives the round trip")
    func codable() throws {
        let old = #"{"id":"q1","sourceID":"video","question":"Q?","answer":"A.","keyPoints":[],"level":"recall"}"#
        let decoded = try JSONDecoder().decode(CourseQuizQuestion.self, from: Data(old.utf8))
        #expect(decoded.picture == nil)
        let pictured = question(1, picture: CourseQuizPicture(reference: frame, caption: "The IMM slide", placement: .answer))
        let again = try JSONDecoder().decode(CourseQuizQuestion.self, from: JSONEncoder().encode(pictured))
        #expect(again == pictured)
        #expect(again.picture?.placement == .answer)
        #expect(again.identified(as: "q9").picture == pictured.picture)
        let unknown = #"{"image":"foreverlm://image/video/at/723","placement":"later"}"#
        #expect(try JSONDecoder().decode(CourseQuizPicture.self, from: Data(unknown.utf8)).placement == .answer)
    }

    @Test("save_course_quiz takes show_source_image's line, or a time and crop in the question's video")
    func parsesAssistantPictures() throws {
        let line = frame.markdown(alt: "Mitochondrial Cell Biology 2 at 12:03")
        let fromLine = try #require(try CourseQuizPicture.parse(["image": "  \(line) ", "show_with": "question"], sourceID: "video").get())
        #expect(fromLine.reference == frame)
        #expect(fromLine.caption == "Mitochondrial Cell Biology 2 at 12:03")
        #expect(fromLine.placement == .question)

        let fromTime = try #require(try CourseQuizPicture.parse(
            ["at": "12:03", "crop": ["x": 0.5, "y": 0.2, "width": 0.5, "height": 0.6], "caption": "Cardiolipin", "show_with": "answer"],
            sourceID: "video"
        ).get())
        #expect(fromTime.reference?.location == .moment(723))
        #expect(fromTime.reference?.crop != nil)
        #expect(fromTime.placement == .answer)

        #expect(try CourseQuizPicture.parse(nil, sourceID: "video").get() == nil)
        #expect(throws: CourseQuizPicture.PictureError.self) { try CourseQuizPicture.parse(["at": 723], sourceID: nil).get() }
        #expect(throws: CourseQuizPicture.PictureError.self) { try CourseQuizPicture.parse(["image": "https://example.com/a.png"], sourceID: "video").get() }
        #expect(throws: CourseQuizPicture.PictureError.self) { try CourseQuizPicture.parse(["at": 723, "show_with": "later"], sourceID: "video").get() }
        #expect(throws: CourseQuizPicture.PictureError.self) { try CourseQuizPicture.parse(["caption": "no picture"], sourceID: "video").get() }
    }

    @Test("The writer reads a video's slides with their words, and a pick becomes that frame")
    func writerSlides() throws {
        let slides = CourseQuizPictures.slides(from: Self.content, sourceID: "video", byMoment: true)
        #expect(slides.map(\.number) == [1, 2])
        #expect(slides[1].reference == builtFrame)
        #expect(slides[1].text == "Inner Mitochondrial Membrane Phospholipids Cardiolipin")
        let recording = CourseQuizPictures.slides(from: Self.content, sourceID: "video", byMoment: false)
        #expect(recording[1].reference.location == .slide(2))

        let block = try #require(CourseQuizPictures.block(slides, heading: "Slides:"))
        #expect(block.contains("[S2 · 12:03–13:10] Inner Mitochondrial Membrane"))
        #expect(block.contains("[S1 · 0:00–0:40] (no words recognized)"))
        let sampled = try #require(CourseQuizPictures.block(slides, heading: "Slides:", budget: 60))
        #expect(sampled.split(separator: "\n").count == 2)

        let part = CourseQuizPart(
            lectureID: "l1", lectureTitle: "Lecture 2", sourceID: "video",
            lines: [LectureQuizLine(number: 1, seconds: 0, text: "Welcome."), LectureQuizLine(number: 2, seconds: 723, text: "Cardiolipin has four acyl chains.")],
            slides: slides
        )
        let draft = CourseQuizDraft(questions: [
            CourseQuizDraft.Question(part: nil, firstLine: 2, lastLine: 2, question: "What does the slide show?", answer: "Cardiolipin.", keyPoints: nil, quote: nil, level: "recall", slide: 2, slideWith: "question", slideShows: "The inner membrane's lipids"),
            CourseQuizDraft.Question(part: nil, firstLine: 2, lastLine: 2, question: "How many chains?", answer: "Four.", keyPoints: nil, quote: nil, level: "explain", slide: 2),
            CourseQuizDraft.Question(part: nil, firstLine: 2, lastLine: 2, question: "Why?", answer: "Because.", keyPoints: nil, quote: nil, level: "apply", slide: 9, slideWith: "question"),
        ])
        let questions = CourseQuizPlanning.questions(from: draft, parts: [part])
        #expect(questions.count == 3)
        #expect(questions[0].picture?.reference == builtFrame)
        #expect(questions[0].picture?.placement == .question)
        #expect(questions[0].picture?.caption == "The inner membrane's lipids")
        // No placement given: held for the answer, so it cannot give it away.
        #expect(questions[1].picture?.placement == .answer)
        #expect(questions[2].picture == nil)
    }

    /// Kowaltowski's "Isolated Mitochondria and Permeabilized Cells/Tissues
    /// 3" shows only a title and the speaker at 0:00 and its electrode
    /// diagram and equations by 4:50; 22 quiz pictures had been a lecture's
    /// 0:00 like that one.
    @Test("A slide that builds is pictured as it stands before the next one, from its longest time on screen")
    func builtSlides() throws {
        let content = """
        [0:00] Today we measure the membrane potential.

        ## Extracted video slide frames

        ### Slide frame 1 [0:00–4:55]
        Image: Videos/lecture/Slides/slide_001_000150s.jpg

        ### Slide frame 2 [4:55–6:05] [20:00–25:00]
        Image: Videos/lecture/Slides/slide_002_000330s.jpg

        ### Slide frame 3 [6:05–9:20] [9:20–10:15]
        Image: Videos/lecture/Slides/slide_003_000560s.jpg

        ### Slide frame 4 [10:15–10:27]
        Image: Videos/lecture/Slides/slide_004_000621s.jpg

        ### Slide frame 5 [25:00–26:00] [27:00–28:00]
        Image: Videos/lecture/Slides/slide_005_001530s.jpg

        ### Slide frame 6 [29:00–29:50]
        Image: Videos/lecture/Slides/slide_006_001765s.jpg
        """
        let slides = CourseQuizPictures.slides(from: content, sourceID: "lecture", byMoment: true)
        #expect(slides.map(\.reference.location) == [
            .moment(285),   // 10 seconds before the next slide, not its title card at 0:00
            .moment(1490),  // the end of its longer showing, not of its first
            .moment(605),   // two windows that touch are one showing, 6:05–10:15
            .moment(621),   // a 12-second slide is pictured midway, clear of both edges
            .moment(1670),  // of two showings as long, the later
            .moment(1770),  // the talk's last window may run past the video's end: 20 seconds back
        ])
        // The writer still reads when each came on screen, and every showing.
        #expect(slides.map(\.seconds) == [0, 295, 365, 615, 1500, 1740])
        let block = try #require(CourseQuizPictures.block(slides, heading: "Slides:"))
        #expect(block.contains("[S1 · 0:00–4:55] (no words recognized)"))
        #expect(block.contains("[S2 · 4:55–6:05, 20:00–25:00]"))
        #expect(block.contains("[S3 · 6:05–10:15]"))

        // A deck stored before windows had ends keeps its one time: the
        // stored frame's own, taken mid-run.
        let legacy = """
        ## Extracted video slide frames

        ### Slide frame 1 [2:05]
        Image: Videos/old/Slides/slide_001_000125s.jpg
        """
        let old = CourseQuizPictures.slides(from: legacy, sourceID: "old", byMoment: true)
        #expect(old.map(\.reference.location) == [.moment(125)])
        #expect(try #require(CourseQuizPictures.block(old, heading: "Slides:")).contains("[S1 · 2:05] (no words recognized)"))
    }

    @Test("A picture pass reads the slides and the questions it may picture, and pins only what fits")
    func picturePassOnWrittenQuiz() throws {
        let slides = CourseQuizPictures.slides(from: Self.content, sourceID: "video", byMoment: true)
        let lecture = CourseQuizPart(lectureID: "l1", lectureTitle: "Lecture 2", sourceID: "video", lines: [], slides: slides)
        let reading = CourseQuizPart(
            lectureID: "l1", lectureTitle: "Lecture 2", sourceID: "book", lines: [],
            reading: CourseQuizPartReading(title: "Chapter 8", place: "Bioenergetics, pages 2–8", pages: 2...8)
        )
        let kept = CourseQuizPicture(reference: frame, caption: "Kept", placement: .question)
        let onBook = CourseQuizQuestion(
            id: "q3", sourceID: "book", firstLine: 1, lastLine: 1, startSeconds: nil,
            question: "Question 3?", answer: "Answer 3.", keyPoints: [], quote: nil
        )
        let quiz = CourseQuiz(
            id: "quiz", courseID: "course", kind: .practice, title: "Cardiolipin", lectureIDs: ["l1"],
            afterLectureID: "l1", questions: [question(1), question(2, picture: kept), onBook, question(4)],
            author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
        let parts = [lecture, reading]

        // The reading has no slides, and a question with a picture keeps it.
        let candidates = CourseQuizPictures.candidates(in: quiz, parts: parts, replacing: false)
        #expect(candidates == [0, 3])
        #expect(CourseQuizPictures.candidates(in: quiz, parts: parts, replacing: true) == [0, 1, 3])

        let material = CourseQuizPictures.pickerMaterial(quiz: quiz, parts: parts, candidates: candidates)
        #expect(material.contains("Part 1: slides of Lecture 2"))
        #expect(material.contains("[S2 · 12:03–13:10] Inner Mitochondrial Membrane"))
        #expect(material.contains("Q1 · part 1 · at 12:03 · recall: Question 1?"))
        #expect(material.contains("Reference answer: Answer 4."))
        #expect(!material.contains("Question 2?"))
        #expect(!material.contains("Question 3?"))

        let draft = try JSONDecoder().decode(CourseQuizPictures.PickDraft.self, from: Data("""
            {"pictures": [
              {"question": 1, "slide": 2, "slide_with": "question", "slide_shows": "The inner membrane's lipids"},
              {"question": 1, "slide": 1, "slide_with": "answer"},
              {"question": 2, "slide": 2, "slide_with": "question"},
              {"question": 3, "slide": 2},
              {"question": 4, "slide": 9},
              {"question": 12, "slide": 2}
            ]}
            """.utf8))
        let applied = CourseQuizPictures.applying(draft, to: quiz, parts: parts, candidates: candidates)
        #expect(applied.pinned == 1)
        #expect(applied.questions.map(\.id) == quiz.questions.map(\.id))
        #expect(applied.questions[0].picture?.reference == builtFrame)
        #expect(applied.questions[0].picture?.placement == .question)
        #expect(applied.questions[0].picture?.caption == "The inner membrane's lipids")
        #expect(applied.questions[1].picture == kept)
        #expect(applied.questions[2].picture == nil)
        #expect(applied.questions[3].picture == nil)
    }

    @Test("The quiz shows a question's picture above it, and an answer's picture with its grade")
    func chatShowsPictures() {
        let above = CourseQuizPicture(reference: frame, caption: "The inner membrane's lipids", placement: .question)
        let after = CourseQuizPicture(reference: SourceImageReference(sourceID: "video", location: .moment(800)), caption: "Four chains drawn", placement: .answer)
        var quiz = state([question(1, picture: above), question(2, picture: after), question(3, picture: above), question(4)])
        let line = frame.markdown(alt: "The inner membrane's lipids")

        let opening = quiz.openingMessage
        #expect(opening.contains("**Question 1 of 4 · Recall**\n\n\(line)\n\nQuestion 1?"))
        // The tutor is told what a picture shows, never its address.
        #expect(quiz.questionList.contains("ForeverLM shows it with its picture, \"The inner membrane's lipids\", between the heading and the question."))
        #expect(!quiz.questionList.contains("foreverlm://image"))
        // The answer picture's caption stays out of the tutor's head.
        #expect(!quiz.questionList.contains("Four chains drawn"))
        #expect(quiz.questionList.contains("Has a picture for the answer"))

        quiz.record(.correct, forQuestionAt: 0)
        let first = quiz.acknowledgement(forQuestionAt: 0, grade: VideoQuizGrade(verdict: .correct, feedback: "Yes."), memoryError: nil)
        #expect(!first.contains("Picture for the answer"))
        #expect(!first.contains("show_source_image"))

        quiz.record(.incorrect, forQuestionAt: 1)
        let second = quiz.acknowledgement(forQuestionAt: 1, grade: VideoQuizGrade(verdict: .incorrect, feedback: "No."), memoryError: nil)
        #expect(second.contains("Picture for the answer: ForeverLM shows \"Four chains drawn\" with your feedback, with a link to Mitochondrial Cell Biology 2 at 12:03 under it"))
        #expect(!second.contains("foreverlm://source"))
        #expect(second.contains("ForeverLM shows this question's picture, \"The inner membrane's lipids\", between its heading and its text"))
        #expect(!second.contains("foreverlm://image"))

        // ForeverLM, not the tutor, puts the stored pictures in the reply:
        // the answer picture before the next block with the rewatch link
        // under it, which the chat draws as its caption, then a rule, then
        // the next question's picture above its words.
        let answerLine = "![Four chains drawn](foreverlm://image/video/at/800)"
        let rewatch = "[Rewatch 12:03](foreverlm://source/video?t=723)"
        let written = "Not quite. Here is why.\n\n**Question 3 of 4 · Recall**\n\nQuestion 3?"
        let placed = quiz.placingPictures(in: written, answeredQuestionIndex: 1)
        #expect(placed == "Not quite. Here is why.\n\n\(answerLine)\n\n\(rewatch)\n\n---\n\n**Question 3 of 4 · Recall**\n\n\(line)\n\nQuestion 3?")
        #expect(quiz.placingPictures(in: placed, answeredQuestionIndex: 1) == placed)
        // What the tutor wrote of the stored pictures goes, wherever it stood:
        // here the question's picture above the heading and the answer
        // picture after the question, where it would come too late.
        let misplaced = "Not quite. Here is why.\n\n\(line)\n\n**Question 3 of 4 · Recall**\n\nQuestion 3?\n\n\(answerLine)"
        #expect(quiz.placingPictures(in: misplaced, answeredQuestionIndex: 1) == placed)
        // The tutor's own rewatch link is where ForeverLM's picture and link
        // go, and a rule it drew is not drawn twice.
        let linked = "Not quite.\n\n\(rewatch)\n\nHere is why.\n\n***\n\n**Question 3 of 4 · Recall**\n\nQuestion 3?"
        #expect(quiz.placingPictures(in: linked, answeredQuestionIndex: 1) == "Not quite.\n\n\(answerLine)\n\n\(rewatch)\n\nHere is why.\n\n---\n\n**Question 3 of 4 · Recall**\n\n\(line)\n\nQuestion 3?")
        // A picture the tutor showed with show_source_image is its own.
        let lookedUp = "Not quite.\n\n![The slide at 1:40](foreverlm://image/video/at/100?crop=0.1,0.1,0.5,0.5)"
        #expect(quiz.placingPictures(in: lookedUp, answeredQuestionIndex: nil) == lookedUp)
        // Asked again after a question of the learner's, with no grade: the
        // question still comes with its picture, and no answer picture does.
        let again = "The IMM is the inner membrane.\n\n**Question 3 of 4 · Recall**\n\nQuestion 3?"
        #expect(quiz.placingPictures(in: again, answeredQuestionIndex: nil) == "The IMM is the inner membrane.\n\n---\n\n**Question 3 of 4 · Recall**\n\n\(line)\n\nQuestion 3?")
        // A reply that is only the question needs no rule above it.
        #expect(quiz.placingPictures(in: "**Question 3 of 4 · Recall**\n\nQuestion 3?", answeredQuestionIndex: nil) == "**Question 3 of 4 · Recall**\n\n\(line)\n\nQuestion 3?")
        // A question named inside a sentence is not being asked.
        #expect(quiz.placingPictures(in: "Skipped so far: Question 3? and no other.", answeredQuestionIndex: nil) == "Skipped so far: Question 3? and no other.")
        // With no question after it, the answer picture closes the reply.
        #expect(quiz.placingPictures(in: "Not quite.", answeredQuestionIndex: 1) == "Not quite.\n\n\(answerLine)\n\n\(rewatch)")

        quiz.record(.incorrect, forQuestionAt: 2)
        let third = quiz.acknowledgement(forQuestionAt: 2, grade: VideoQuizGrade(verdict: .incorrect, feedback: "No."), memoryError: nil)
        // Question 4 has no picture of its own: the tutor is pointed at its moment.
        #expect(third.contains("show_source_image (source_id video, at 723"))

        quiz.record(.partial, forQuestionAt: 3)
        let last = quiz.acknowledgement(forQuestionAt: 3, grade: VideoQuizGrade(verdict: .partial, feedback: "Partly."), memoryError: nil)
        #expect(last.contains("No picture is stored for this question"))
    }

    @Test("A picture the learner has just been shown is not shown again, and the rewatch link stays under the feedback")
    func repeatedPictureShowsOnce() {
        // Questions 16 and 17 of "Biogenesis, Quality, and Signaling" kept the
        // same slide for their answers, so question 17's feedback showed again
        // the slide question 16's had just shown (product owner, 2026-09-28).
        let slide = SourceImageReference(sourceID: "video", location: .moment(695))
        var quiz = state([
            question(1, startSeconds: 632, picture: CourseQuizPicture(reference: slide, caption: "axonal transport diagram", placement: .answer)),
            question(2, startSeconds: 654, picture: CourseQuizPicture(reference: slide, caption: "mitochondrial transport directions", placement: .answer)),
            question(3, startSeconds: 674),
        ])
        quiz.record(.partial, forQuestionAt: 0)
        #expect(quiz.answerBlock(forQuestionAt: 0) == "\(slide.markdown(alt: "axonal transport diagram"))\n\n[Rewatch 10:32](foreverlm://source/video?t=632)")

        quiz.record(.incorrect, forQuestionAt: 1)
        #expect(quiz.answerPictureLine(forQuestionAt: 1) == nil)
        #expect(quiz.answerBlock(forQuestionAt: 1) == "[Rewatch 10:54](foreverlm://source/video?t=654)", "missed, so the link stays")
        let text = quiz.acknowledgement(forQuestionAt: 1, grade: VideoQuizGrade(verdict: .incorrect, feedback: "No."), memoryError: nil)
        #expect(text.contains("so ForeverLM does not show it again: refer to no picture."))
        #expect(!text.contains("Picture for the answer"))
        #expect(text.contains("ForeverLM puts a link to Mitochondrial Cell Biology 2 at 10:54 under your feedback: write no link to it."))
        let reply = "That was a miss.\n\n[Rewatch 10:54](foreverlm://source/video?t=654)\n\n**Question 3 of 3 · Recall**\n\nQuestion 3?"
        #expect(quiz.placingPictures(in: reply, answeredQuestionIndex: 1) == "That was a miss.\n\n[Rewatch 10:54](foreverlm://source/video?t=654)\n\n---\n\n**Question 3 of 3 · Recall**\n\nQuestion 3?")
        // Answered again once the sitting is done, long after question 1: it shows.
        #expect(quiz.answerPictureLine(forQuestionAt: 1, isCorrection: true) == slide.markdown(alt: "mitochondrial transport directions"))

        // The last reply goes on to the result: a link into the same lecture
        // there stays, and only the tutor's link to this question's moment
        // makes way for ForeverLM's.
        quiz.record(.incorrect, forQuestionAt: 2)
        let closing = "Not quite.\n\n[Rewatch 11:14](foreverlm://source/video?t=674)\n\nScore: 0/3.\n\n[Transport](foreverlm://source/video?t=600)"
        #expect(quiz.placingPictures(in: closing, answeredQuestionIndex: 2) == closing)

        // Nor is an answer's picture shown when the next question shows it above its words.
        var next = state([
            question(1, picture: CourseQuizPicture(reference: slide, caption: "the transport slide", placement: .answer)),
            question(2, picture: CourseQuizPicture(reference: slide, caption: "the transport slide", placement: .question)),
        ])
        next.record(.correct, forQuestionAt: 0)
        #expect(next.answerPictureLine(forQuestionAt: 0) == nil)
        #expect(next.answerBlock(forQuestionAt: 0) == nil, "right and no picture: nothing under the feedback")
    }
}

/// A lecture's readings quizzed with it (docs/lecture-quiz-design.md,
/// "Readings"), and every learning point given a question.
@Suite("Course Quiz Readings")
struct CourseQuizReadingTests {
    /// Three pages of a chapter's stored text, split at form feeds the way
    /// `PDFTextExtractor.embeddedText` keeps them, with no paragraph breaks.
    private let chapter = [
        "224 BIOENERGETICS 4\nThe translocator exchanges ADP for ATP. It carries one nucleotide at a time.\nIts matrix face opens after the cytoplasmic face closes. The exchange is electrogenic. It moves one charge.",
        "",
        "Carboxyatractylate locks it facing out. Bongkrekate locks it facing in. Both stop oxidative phosphorylation.",
    ].joined(separator: "\u{000C}")

    private let lectureLines: [LectureQuizLine] = (1...6).map {
        LectureQuizLine(number: $0, seconds: Double($0 * 60), text: "Lecture line \($0) on transport.")
    }

    private func readingPart(_ lines: [LectureQuizLine], pages: ClosedRange<Int>? = 1...3) -> CourseQuizPart {
        CourseQuizPart(
            lectureID: "l8", lectureTitle: "Mitochondrial Ion Transport 1", sourceID: "chapter8", lines: lines,
            reading: CourseQuizPartReading(title: "8.2 The Adenine Nucleotide Translocator", place: "Chapter 8: Transporters, pages 1–3", pages: pages)
        )
    }

    private func lecturePart() -> CourseQuizPart {
        CourseQuizPart(lectureID: "l8", lectureTitle: "Mitochondrial Ion Transport 1", sourceID: "video8", lines: lectureLines)
    }

    private func raw(part: Int? = nil, lastLine: Int, points: [Int]?, question: String = "Why?", answer: String = "Because.") -> CourseQuizDraft.Question {
        var raw = CourseQuizDraft.Question(
            part: part, firstLine: lastLine, lastLine: lastLine,
            question: question, answer: answer, keyPoints: [], quote: nil
        )
        raw.points = points
        return raw
    }

    @Test("A chapter's text splits page by page into runs of a few sentences, each knowing its page")
    func pagedLinesKnowTheirPage() {
        let lines = CourseQuizPlanning.lines(from: chapter)
        #expect(lines.map(\.number) == Array(1...lines.count))
        #expect(lines.allSatisfy { $0.seconds == nil })
        #expect(Set(lines.compactMap(\.page)) == [1, 3], "the empty page 2 has no line")
        #expect(lines.first?.text.hasPrefix("224 BIOENERGETICS 4 The translocator exchanges ADP for ATP.") == true)
        // Four sentences a line at most, and no line spans a page break.
        #expect(lines.filter { $0.page == 1 }.count == 2)
        #expect(lines.last?.page == 3)
        #expect(lines.last?.text == "Carboxyatractylate locks it facing out. Bongkrekate locks it facing in. Both stop oxidative phosphorylation.")
    }

    @Test("Text without page breaks still reads as a transcript")
    func unpagedTextIsATranscript() {
        let lines = CourseQuizPlanning.lines(from: "First paragraph.\n\nSecond paragraph.")
        #expect(lines.map(\.text) == ["First paragraph.", "Second paragraph."])
        #expect(lines.allSatisfy { $0.page == nil })
    }

    @Test("A reading keeps only its planned pages, and none when its pages cannot be told")
    func readingLinesArePlannedPages() {
        let lines = CourseQuizPlanning.lines(from: chapter)
        #expect(CourseQuizPlanning.readingLines(lines, pages: 3...3)?.map(\.page) == [3])
        #expect(CourseQuizPlanning.readingLines(lines, pages: nil)?.count == lines.count)
        #expect(CourseQuizPlanning.readingLines(lines, pages: 8...9) == nil)
        #expect(CourseQuizPlanning.readingLines(lectureLines, pages: 1...2) == nil, "a transcript has no pages to choose")
    }

    @Test("The writer reads a reading's lines with their pages, under a title naming its lecture and place")
    func materialBlockTitlesReadings() {
        let reading = readingPart(CourseQuizPlanning.lines(from: chapter))
        let block = CourseQuizPlanning.materialBlock([lecturePart(), reading]).text
        #expect(block.contains("Part 1: Mitochondrial Ion Transport 1\n[1.1 · 1:00] Lecture line 1 on transport."))
        #expect(block.contains("Part 2: Reading with Mitochondrial Ion Transport 1: 8.2 The Adenine Nucleotide Translocator (Chapter 8: Transporters, pages 1–3)"))
        #expect(block.contains("[2.1 · p.1] 224 BIOENERGETICS 4"))
        #expect(block.contains("[2.3 · p.3] Carboxyatractylate"))
        let practice = LectureQuizPlanning.transcriptBlock(reading.lines).text
        #expect(practice.hasPrefix("[1 · p.1] 224 BIOENERGETICS 4"))
    }

    @Test("A reading's question rests on the chapter, with the page its stretch starts on")
    func readingQuestionCarriesItsPage() {
        let reading = readingPart(CourseQuizPlanning.lines(from: chapter))
        let draft = CourseQuizDraft(questions: [
            raw(lastLine: 2, points: [1]),
            raw(lastLine: 3, points: [2]).moved(toPart: 2),
        ])
        let questions = CourseQuizPlanning.questions(from: draft, parts: [lecturePart(), reading])
        #expect(questions.count == 2)
        #expect(questions[0].sourceID == "video8" && questions[0].startSeconds == 120 && questions[0].page == nil)
        #expect(questions[1].sourceID == "chapter8" && questions[1].startSeconds == nil && questions[1].page == 3)
        #expect(questions[0].id != questions[1].id)
    }

    @Test("A question's page survives the Course record")
    func pageRoundTrips() throws {
        let question = CourseQuizQuestion(
            id: "q1", sourceID: "chapter8", firstLine: 3, lastLine: 3, startSeconds: nil,
            question: "Q?", answer: "A.", keyPoints: [], quote: nil, page: 3
        )
        let data = try JSONEncoder().encode(question)
        #expect(try JSONDecoder().decode(CourseQuizQuestion.self, from: data).page == 3)
        let old = #"{"id":"q1","sourceID":"video","firstLine":1,"lastLine":1,"question":"Q?","answer":"A.","keyPoints":[]}"#
        #expect(try JSONDecoder().decode(CourseQuizQuestion.self, from: Data(old.utf8)).page == nil)
    }

    @Test("The writer's learning points and each question's points decode")
    func draftDecodesPoints() throws {
        let json = #"{"learning_points": ["ADP in, ATP out", "It is electrogenic"], "questions": [{"level": "recall", "points": [1, 2], "first_line": 1, "last_line": 2, "question": "Q?", "answer": "A.", "key_points": [], "quote": "x"}], "title": "Translocator"}"#
        let draft: CourseQuizDraft = try MemoryReviewPlanning.decodeJSON(json)
        #expect(draft.learningPoints == ["ADP in, ATP out", "It is electrogenic"])
        #expect(draft.questions.first?.points == [1, 2])
        #expect(draft.title == "Translocator")
    }

    @Test("A learning point counts as covered only by a question the checks keep")
    func uncoveredPoints() {
        let parts = [lecturePart()]
        let draft = CourseQuizDraft(
            questions: [
                raw(lastLine: 2, points: [1]),
                raw(lastLine: 99, points: [2]),              // no such line: dropped
                raw(part: 3, lastLine: 2, points: [3]),      // no such part: dropped
                raw(lastLine: 4, points: [4], answer: " "),  // no answer: dropped
                raw(lastLine: 5, points: nil),
            ],
            learningPoints: ["one", "two", "three", "four", "five"]
        )
        #expect(CourseQuizPlanning.uncoveredPoints(in: draft, parts: parts) == [2, 3, 4, 5])
        #expect(CourseQuizPlanning.uncoveredPoints(in: CourseQuizDraft(questions: []), parts: parts).isEmpty,
                "a draft that lists no points leaves nothing to check")
    }

    @Test("The coverage call names the list as written and the points still without a question")
    func coverageInstruction() {
        let text = CourseQuizCoverage(points: ["ADP in, ATP out", "It is electrogenic", "One charge moves"], missing: [2, 3]).instruction
        #expect(text.contains("1. ADP in, ATP out\n2. It is electrogenic\n3. One charge moves"))
        #expect(text.contains("These have no question yet: 2, 3."))
        #expect(text.contains(#"{"questions": [...]}"#))
    }

    @Test("A reading pass hears the lecture's points so it adds to them")
    func readingInstructionCarriesLecturePoints() {
        let text = CourseQuizReadingInstructions.practice(lecturePoints: ["The translocator is electrogenic", " "])
        #expect(text.contains("[12 · p.5]"))
        #expect(text.contains("- The translocator is electrogenic"))
        #expect(!text.contains("- \n"))
        #expect(!CourseQuizReadingInstructions.practice(lecturePoints: []).contains("already ask about"))
    }

    @Test("Readings raise the questions a quiz asks and keeps")
    func readingCounts() {
        let short = readingPart([LectureQuizLine(number: 1, seconds: nil, text: String(repeating: "a", count: 900), page: 1)])
        let long = readingPart((1...40).map { LectureQuizLine(number: $0, seconds: nil, text: String(repeating: "a", count: 1_000), page: $0) })
        #expect(CourseQuizPlanning.readingQuestionCount(for: short) == 3)
        #expect(CourseQuizPlanning.readingQuestionCount(for: long) == 27)
        #expect(CourseQuizPlanning.practiceQuestionLimit(readings: 0) == LectureQuizPlanning.maximumQuestions)
        #expect(CourseQuizPlanning.practiceQuestionLimit(readings: 1) == LectureQuizPlanning.maximumQuestions + CourseQuizPlanning.maximumQuestionsPerReading)
        #expect(CourseQuizPlanning.practiceQuestionLimit(readings: 9) == CourseQuizPlanning.maximumPracticeQuestions)
        let lectures = [lecturePart(), lecturePart(), lecturePart()]
        #expect(CourseQuizPlanning.questionCount(for: .checkpoint, parts: lectures) == 12)
        #expect(CourseQuizPlanning.questionCount(for: .checkpoint, parts: lectures + [short, short]) == 16)
        #expect(CourseQuizPlanning.questionCount(for: .practice, parts: [lecturePart(), short])
                == CourseQuizPlanning.questionCount(for: .practice, parts: [lecturePart()]))
    }

    @Test("A chapter's stored pages are found at its form feeds, for read_planned_reading")
    func pageTextsReadFormFeeds() {
        let pages = TextbookOutline.pageTexts(chapter)
        #expect(pages.keys.sorted() == [1, 2, 3])
        #expect(pages[2] == "", "a page with no text is still a page")
        #expect(pages[3] == "Carboxyatractylate locks it facing out. Bongkrekate locks it facing in. Both stop oxidative phosphorylation.")
        #expect(CourseQuizReading.text(of: 3...3, in: chapter) == "[page 3]\nCarboxyatractylate locks it facing out. Bongkrekate locks it facing in. Both stop oxidative phosphorylation.")
        #expect(CourseQuizReading.text(of: nil, in: chapter)?.hasPrefix("[page 1]\n\n224 BIOENERGETICS 4") == true)
        #expect(TextbookOutline.pageCount(ofText: chapter) == 3)
    }

    // MARK: In the chat

    private func chatState(_ questions: [CourseQuizQuestion]) -> CourseQuizChatState {
        CourseQuizChatState(request: CourseQuizChatRequest(
            quiz: CourseQuiz(
                id: "quiz", courseID: "course", kind: .practice, title: "Transport", lectureIDs: ["l8"],
                afterLectureID: "l8", questions: questions, author: .foreverlm, createdAt: Date(), updatedAt: Date()
            ),
            topic: "Quiz: Transport",
            subtitle: "Lecture 8",
            sourceIDs: ["video8"],
            sourceTitles: ["video8": "Mitochondrial Ion Transport 1", "chapter8": "Chapter 8: Transporters"],
            readings: [
                CourseQuizReading(
                    lectureSourceIDs: ["video8"], lectureTitle: "Lecture 8, Mitochondrial Ion Transport 1",
                    chapterID: "chapter8", chapterTitle: "Chapter 8: Transporters", bookTitle: "Bioenergetics 4",
                    sections: "8.2 The Adenine Nucleotide Translocator", pages: 2...8, reason: nil
                ),
                CourseQuizReading(
                    lectureSourceIDs: ["video8"], lectureTitle: "Lecture 8, Mitochondrial Ion Transport 1",
                    chapterID: "chapter8", chapterTitle: "Chapter 8: Transporters", bookTitle: "Bioenergetics 4",
                    sections: "8.5 Calcium Transport", pages: 20...24, reason: nil
                ),
            ],
            grade: { _, _, _ in (.graded(VideoQuizGrade(verdict: .correct, feedback: "Yes.")), nil) },
            recorded: { _, _ in }
        ))
    }

    @Test("A reading's question is headed with its page, and sends the learner back to reread it")
    func readingQuestionInChat() {
        let questions = [
            CourseQuizQuestion(
                id: "q1", sourceID: "chapter8", firstLine: 30, lastLine: 31, startSeconds: nil,
                question: "Why is the exchange electrogenic?", answer: "ATP carries one more charge.",
                keyPoints: [], quote: nil, levelName: "explain", page: 5
            ),
            CourseQuizQuestion(
                id: "q2", sourceID: "video8", firstLine: 3, lastLine: 3, startSeconds: 180,
                question: "What does the translocator swap?", answer: "ADP for ATP.",
                keyPoints: [], quote: nil, levelName: "recall"
            ),
        ]
        var quiz = chatState(questions)
        #expect(quiz.questionList.contains("1. [Explain · Chapter 8: Transporters page 5 · source_id chapter8 · reading R1]: Why is the exchange electrogenic?"))
        #expect(quiz.readingNumbers(for: questions[0]) == [1], "only the reading whose pages hold it")
        #expect(quiz.readingNumbers(for: questions[1]) == [1, 2], "a lecture's question goes with all its readings")
        quiz.record(.incorrect, forQuestionAt: 0)
        let text = quiz.acknowledgement(forQuestionAt: 0, grade: VideoQuizGrade(verdict: .incorrect, feedback: "No."), memoryError: nil)
        #expect(text.contains("ForeverLM puts a link to page 5 of Chapter 8: Transporters under your feedback: write no link to it."))
        #expect(!text.contains("Reread page 5]("))
        #expect(!text.contains("Rewatch"))
        #expect(text.contains("show_source_image (source_id chapter8, page 5"))
        #expect(text.contains("Add the planned reading's link when the answer was missed."))

        // The reread link goes under the feedback, and a planned reading's
        // link to the same chapter, which the tutor writes, stays its own.
        let written = "Not quite.\n\n[Chapter 8, pages 2–8](foreverlm://source/chapter8?page=2)\n\n**Question 2 of 2 · Recall**\n\nWhat does the translocator swap?"
        #expect(quiz.placingPictures(in: written, answeredQuestionIndex: 0) == "Not quite.\n\n[Chapter 8, pages 2–8](foreverlm://source/chapter8?page=2)\n\n[Reread page 5](foreverlm://source/chapter8?page=5)\n\n---\n\n**Question 2 of 2 · Recall**\n\nWhat does the translocator swap?")
    }
}

/// Pictures of every kind on a quiz question (docs/lecture-quiz-design.md,
/// "Pictures"): a reading's figures, an image in the store drawn by ForeverLM
/// or kept from another app, and a drawing briefed for ForeverLM to make.
@Suite("Course Quiz Figures and Drawn Pictures")
struct CourseQuizDrawnPictureTests {
    private let storedID = "0f3c2a9e-5b7d-4c1e-9a2b-6d8e4f1a3c5b"
    private let figureReference = SourceImageReference(
        sourceID: "book", location: .page(5),
        crop: PaperFigureRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5)
    )

    private func readingPart(figures: [CourseQuizFigure]) -> CourseQuizPart {
        CourseQuizPart(
            lectureID: "l1", lectureTitle: "Lecture 2", sourceID: "book",
            lines: [LectureQuizLine(number: 1, seconds: nil, text: "The rotor turns as protons cross.", page: 5)],
            figures: figures,
            reading: CourseQuizPartReading(title: "Chapter 8", place: "Bioenergetics, pages 5–6", pages: 5...6)
        )
    }

    private func question(_ number: Int, sourceID: String = "book", picture: CourseQuizPicture? = nil) -> CourseQuizQuestion {
        CourseQuizQuestion(
            id: "q\(number)", sourceID: sourceID, firstLine: 1, lastLine: 1,
            startSeconds: nil, question: "Question \(number)?", answer: "Answer \(number).",
            keyPoints: [], quote: nil, levelName: "explain", picture: picture, page: 5
        )
    }

    @Test("A stored image, a reading's page and a brief each parse, and each is shown or waits as it should")
    func parsesEveryKind() throws {
        let url = CourseQuizPicture.storedImageURL(id: storedID)
        let resolve: (String) -> String? = { $0 == self.storedID ? self.storedID : nil }

        let byID = try #require(try CourseQuizPicture.parse(
            ["image_id": storedID.uppercased(), "caption": "The rotor", "show_with": "question"],
            sourceID: "book", resolveStoredImage: resolve
        ).get())
        #expect(byID.storedImageID == storedID)
        #expect(byID.isShowable)
        #expect(byID.markdown(fallbackAlt: "x") == "![The rotor](\(url))")

        let byLine = try #require(try CourseQuizPicture.parse(
            ["image": "![A drawn rotor](\(url))", "show_with": "answer"],
            sourceID: "book", resolveStoredImage: resolve
        ).get())
        #expect(byLine.storedImageID == storedID)
        #expect(byLine.caption == "A drawn rotor")
        #expect(byLine.placement == .answer)

        let page = try #require(try CourseQuizPicture.parse(
            ["page": 5, "crop": ["x": 0.1, "y": 0.2, "width": 0.8, "height": 0.5], "show_with": "question"],
            sourceID: "book"
        ).get())
        #expect(page.reference?.location == .page(5))
        #expect(page.reference?.crop != nil)

        let brief = try #require(try CourseQuizPicture.parse(
            ["brief": "Protons crossing the rotor ring", "caption": "The ring", "show_with": "question"],
            sourceID: "book"
        ).get())
        #expect(brief.isAwaitingDrawing)
        #expect(!brief.isShowable)
        #expect(brief.markdown(fallbackAlt: "x") == nil)
        let drawn = brief.drawn(as: url)
        #expect(drawn.storedImageID == storedID)
        #expect(drawn.brief == "Protons crossing the rotor ring")
        #expect(drawn.caption == "The ring")

        // An image this Mac does not hold is refused by name, as is a page with no source.
        #expect(throws: CourseQuizPicture.PictureError.self) {
            try CourseQuizPicture.parse(["image_id": storedID, "show_with": "question"], sourceID: "book").get()
        }
        #expect(throws: CourseQuizPicture.PictureError.self) {
            try CourseQuizPicture.parse(["page": 5, "show_with": "question"], sourceID: nil).get()
        }
        #expect(throws: CourseQuizPicture.PictureError.self) {
            try CourseQuizPicture.parse(["page": 0, "show_with": "question"], sourceID: "book").get()
        }
    }

    @Test("A stored or briefed picture survives the round trip, and a build without briefs reads it as a picture it cannot show")
    func codable() throws {
        let briefed = question(1, picture: .awaitingDrawing(brief: "The rotor", caption: nil, placement: .answer))
        let again = try JSONDecoder().decode(CourseQuizQuestion.self, from: JSONEncoder().encode(briefed))
        #expect(again == briefed)
        #expect(again.picture?.isAwaitingDrawing == true)
        let stored = question(2, picture: CourseQuizPicture(storedImage: CourseQuizPicture.storedImageURL(id: storedID), caption: "Drawn", placement: .question, brief: "The rotor"))
        #expect(try JSONDecoder().decode(CourseQuizQuestion.self, from: JSONEncoder().encode(stored)) == stored)
        let json = String(decoding: try JSONEncoder().encode(briefed.picture), as: UTF8.self)
        #expect(json.contains("\"image\":\"\""), "the image key stays, so an older build still decodes the quiz")
    }

    @Test("A reading's figures are listed for the writer, and a figure or a drawing it names becomes the question's picture")
    func writerFiguresAndDrawings() throws {
        let figures = CourseQuizPictures.figures(from: [
            (reference: figureReference, page: 5, caption: "Figure 8-3.   The rotor of\nATP synthase"),
            (reference: SourceImageReference(sourceID: "book", location: .page(6)), page: 6, caption: ""),
        ])
        #expect(figures.map(\.number) == [1, 2])
        #expect(figures[0].caption == "Figure 8-3. The rotor of ATP synthase")
        let block = try #require(CourseQuizPictures.figureBlock(figures, heading: "Figures:"))
        #expect(block.contains("[F1 · p.5] Figure 8-3. The rotor of ATP synthase"))
        #expect(block.contains("[F2 · p.6] (no caption)"))

        let part = readingPart(figures: figures)
        var shown = CourseQuizDraft.Question(part: nil, firstLine: 1, lastLine: 1, question: "What turns?", answer: "The rotor.", keyPoints: nil, quote: nil, level: "recall")
        shown.figure = 1
        shown.figureWith = "question"
        shown.figureShows = "The rotor"
        var drawn = CourseQuizDraft.Question(part: nil, firstLine: 1, lastLine: 1, question: "Why does it turn?", answer: "Protons cross it.", keyPoints: nil, quote: nil, level: "explain")
        drawn.draw = "Protons flowing through the c-ring, turning it"
        drawn.drawWith = "answer"
        var unknown = CourseQuizDraft.Question(part: nil, firstLine: 1, lastLine: 1, question: "What stops it?", answer: "Oligomycin.", keyPoints: nil, quote: nil, level: "apply")
        unknown.figure = 9
        let draft = CourseQuizDraft(questions: [shown, drawn, unknown])

        let questions = CourseQuizPlanning.questions(from: draft, parts: [part])
        #expect(questions[0].picture?.reference == figureReference)
        #expect(questions[0].picture?.placement == .question)
        #expect(questions[1].picture?.isAwaitingDrawing == true)
        #expect(questions[1].picture?.brief == "Protons flowing through the c-ring, turning it")
        #expect(questions[1].picture?.placement == .answer)
        #expect(questions[2].picture == nil)

        // A run that will not draw keeps no brief.
        let undrawn = CourseQuizPlanning.questions(from: draft, parts: [part], drawingLimit: 0)
        #expect(undrawn[1].picture == nil)
        #expect(undrawn[0].picture?.reference == figureReference)

        let material = CourseQuizPlanning.materialBlock([part]).text
        #expect(material.contains("Figures of part 1:\n[F1 · p.5] Figure 8-3."))
    }

    @Test("Drawings stop at the quiz's allowance, and a rewrite keeps the picture a question already had in the store")
    func drawingLimitAndRewrite() {
        let cap = CourseQuizPictures.maximumDrawingsPerQuiz
        #expect(cap >= 12, "by default a quiz aims for a picture on each question, so the cap must not starve a practice quiz")
        let briefs = (1...(cap + 2)).map { question($0, picture: .awaitingDrawing(brief: "Brief \($0)", caption: nil, placement: .answer)) }
        let limited = CourseQuizPictures.limitingDrawings(briefs, to: cap)
        #expect(limited.filter { $0.picture?.isAwaitingDrawing == true }.count == cap)
        #expect(limited.prefix(cap).allSatisfy { $0.picture != nil })
        #expect(limited.suffix(2).allSatisfy { $0.picture == nil })
        #expect(CourseQuizGenerationOptions().briefsDrawings, "drawing is on by default in ordinary quiz writing")

        let kept = CourseQuizPicture(storedImage: CourseQuizPicture.storedImageURL(id: storedID), caption: "Drawn", placement: .question, brief: "Brief 1")
        let previous = [question(1, picture: kept), question(2, picture: kept)]
        let figure = CourseQuizPicture(reference: figureReference, caption: nil, placement: .question)
        let rewritten = [question(1, picture: .awaitingDrawing(brief: "Brief 1 again", caption: nil, placement: .answer)), question(2, picture: figure), question(3)]
        let carried = CourseQuizPictures.keepingStoredPictures(rewritten, from: previous)
        #expect(carried[0].picture == kept, "the drawing is not paid for twice")
        #expect(carried[1].picture == figure, "a figure named now still wins")
        #expect(carried[2].picture == nil)
    }

    @Test("A picture pass on a reading lists its figures, and with drawing lists every part and may brief a drawing")
    func picturePassWithFiguresAndDrawing() throws {
        let figures = CourseQuizPictures.figures(from: [(reference: figureReference, page: 5, caption: "Figure 8-3. The rotor")])
        let reading = readingPart(figures: figures)
        let bare = CourseQuizPart(lectureID: "l1", lectureTitle: "Lecture 2", sourceID: "video", lines: [])
        let quiz = CourseQuiz(
            id: "quiz", courseID: "course", kind: .practice, title: "Rotors", lectureIDs: ["l1"],
            afterLectureID: "l1", questions: [question(1, sourceID: "video"), question(2), question(3, sourceID: "video")],
            author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
        #expect(CourseQuizPictures.candidates(in: quiz, parts: [bare, reading], replacing: false) == [1])
        let candidates = CourseQuizPictures.candidates(in: quiz, parts: [bare, reading], replacing: false, drawing: true)
        #expect(candidates == [0, 1, 2])

        let material = CourseQuizPictures.pickerMaterial(quiz: quiz, parts: [bare, reading], candidates: candidates, drawing: true)
        #expect(material.contains("Part 1: Lecture 2, with no slide or figure listed; a picture for its questions can only be drawn."))
        #expect(material.contains("Part 2: figures of the reading Chapter 8 (Bioenergetics, pages 5–6)"))
        #expect(material.contains("[F1 · p.5] Figure 8-3. The rotor"))
        #expect(material.contains("Q2 · part 2 · p.5 · explain: Question 2?"))

        let draft = try JSONDecoder().decode(CourseQuizPictures.PickDraft.self, from: Data("""
            {"pictures": [
              {"question": 2, "figure": 1, "figure_with": "answer", "figure_shows": "The rotor"},
              {"question": 1, "draw": "The rotor turning", "draw_with": "question", "draw_shows": "A rotor"},
              {"question": 3, "draw": "A second drawing past the limit"}
            ]}
            """.utf8))
        let applied = CourseQuizPictures.applying(draft, to: quiz, parts: [bare, reading], candidates: candidates, drawingLimit: 1)
        #expect(applied.pinned == 2)
        #expect(applied.questions[1].picture?.reference == figureReference)
        #expect(applied.questions[1].picture?.placement == .answer)
        #expect(applied.questions[0].picture?.isAwaitingDrawing == true)
        #expect(applied.questions[0].picture?.caption == "A rotor")
        #expect(applied.questions[2].picture == nil)
        #expect(CourseQuizPictures.awaitingDrawing(in: CourseQuiz(
            id: "quiz", courseID: "course", kind: .practice, title: "Rotors", lectureIDs: ["l1"],
            afterLectureID: "l1", questions: applied.questions, author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )) == [0])
    }

    @Test("A drawing shown before the answer is told nothing of it; one shown with the answer may draw it")
    func drawingPrompt() throws {
        let before = question(1, picture: .awaitingDrawing(brief: "The c-ring and its protons", caption: nil, placement: .question))
        let prompt = try #require(CourseQuizPictures.drawingPrompt(for: before, quizTitle: "Rotors", courseTitle: "Bioenergetics"))
        #expect(prompt.contains("What the picture must show: The c-ring and its protons"))
        #expect(prompt.contains("must neither show nor label the answer"))
        #expect(!prompt.contains("Answer 1."))
        let after = question(2, picture: .awaitingDrawing(brief: "The rotor", caption: nil, placement: .answer))
        #expect(try #require(CourseQuizPictures.drawingPrompt(for: after, quizTitle: "Rotors", courseTitle: nil)).contains("Answer 2."))
        #expect(CourseQuizPictures.drawingPrompt(for: question(3), quizTitle: "Rotors", courseTitle: nil) == nil)
    }

    @Test("The quiz shows a stored picture with its question, and a picture still to draw leaves the tutor to find one")
    func chatShowsStoredPictures() {
        let url = CourseQuizPicture.storedImageURL(id: storedID)
        let stored = CourseQuizPicture(storedImage: url, caption: "The drawn rotor", placement: .question)
        let waiting = CourseQuizPicture.awaitingDrawing(brief: "The rotor", caption: nil, placement: .question)
        let quiz = CourseQuizChatState(request: CourseQuizChatRequest(
            quiz: CourseQuiz(
                id: "quiz", courseID: "course", kind: .practice, title: "Rotors", lectureIDs: ["l1"],
                afterLectureID: "l1", questions: [question(1, picture: stored), question(2, picture: waiting)],
                author: .foreverlm, createdAt: Date(), updatedAt: Date()
            ),
            topic: "Quiz: Rotors",
            subtitle: "Lecture 2",
            sourceIDs: ["book"],
            sourceTitles: ["book": "Bioenergetics 4"],
            grade: { _, _, _ in (.graded(VideoQuizGrade(verdict: .correct, feedback: "Yes.")), nil) },
            recorded: { _, _ in }
        ))
        #expect(quiz.openingMessage.contains("![The drawn rotor](\(url))"))
        #expect(quiz.pictureLine(for: quiz.questions[1], shownWith: .question) == nil)
        #expect(quiz.questionList.components(separatedBy: "ForeverLM shows it with its picture").count == 2, "only the drawn picture is listed")
        #expect(!quiz.questionList.contains("Has a picture for the answer"))
        let page = CourseQuizPicture(reference: SourceImageReference(sourceID: "book", location: .page(5)), caption: nil, placement: .question)
        #expect(quiz.pictureLine(for: question(3, picture: page), shownWith: .question) == "![Bioenergetics 4, page 5](foreverlm://image/book/page/5)")
    }
}

/// The package a course's record carries for the stored pictures its quizzes
/// show (`courseQuizPicturesAsset`): out of one Mac's store, into another's.
@Suite("Course Quiz Picture Package")
struct CourseQuizPicturePackageTests {
    @Test("A drawing run holds its course's uploads until the last run on it ends")
    func holdsUploads() {
        let course = "course-\(UUID().uuidString)"
        #expect(!CourseQuizPicturePackage.isHoldingUploads(courseID: course))
        CourseQuizPicturePackage.holdUploads(courseID: course)
        CourseQuizPicturePackage.holdUploads(courseID: course)
        CourseQuizPicturePackage.releaseUploads(courseID: course)
        #expect(CourseQuizPicturePackage.isHoldingUploads(courseID: course))
        CourseQuizPicturePackage.releaseUploads(courseID: course)
        #expect(!CourseQuizPicturePackage.isHoldingUploads(courseID: course))
        CourseQuizPicturePackage.releaseUploads(courseID: course)
        #expect(!CourseQuizPicturePackage.isHoldingUploads(courseID: course))
    }

    @Test("A question's drawing is kept as a compact JPEG on white, never larger than drawn")
    func compactsDrawings() throws {
        let width = 2400, height = 1600
        let space = CGColorSpaceCreateDeviceRGB()
        // Transparent on the left; shaded noise on the right half, as a drawn
        // picture's gradients are, so the PNG is large.
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12_345
        for row in 0..<height {
            for column in (width / 2)..<width {
                seed = seed &* 1_103_515_245 &+ 12_345
                let offset = (row * width + column) * 4
                canvas[offset] = UInt8(truncatingIfNeeded: seed >> 16)
                canvas[offset + 1] = UInt8(truncatingIfNeeded: column)
                canvas[offset + 2] = UInt8(truncatingIfNeeded: row)
                canvas[offset + 3] = 255
            }
        }
        let context = try #require(CGContext(
            data: &canvas, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let compact = CourseQuizGeneratorService.compactDrawing(GeneratedImage(data: png as Data, mediaType: "image/png"))
        #expect(compact.mediaType == "image/jpeg")
        #expect(compact.data.count < png.length)
        let source = try #require(CGImageSourceCreateWithData(compact.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == CourseQuizGeneratorService.drawingPixelSize)

        // A pixel of the transparent left half comes out white, not black.
        var pixels = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
        let reader = try #require(CGContext(
            data: &pixels, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
            bytesPerRow: decoded.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        reader.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        let offset = (20 * decoded.width + 20) * 4
        #expect(pixels[offset] > 230 && pixels[offset + 1] > 230 && pixels[offset + 2] > 230, "a transparent background is flattened onto white")

        let unreadable = GeneratedImage(data: Data([0x01, 0x02]), mediaType: "image/png")
        #expect(CourseQuizGeneratorService.compactDrawing(unreadable).data == unreadable.data, "bytes that are not a picture are kept as they are")
    }

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func root(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quiz_picture_package_\(name)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(GeneratedImageStore.directory), withIntermediateDirectories: true)
        return url
    }

    private func quiz(showing ids: [String]) -> CourseQuiz {
        CourseQuiz(
            id: "quiz", courseID: "course", kind: .practice, title: "Rotors", lectureIDs: ["l1"], afterLectureID: "l1",
            questions: ids.enumerated().map { offset, id in
                CourseQuizQuestion(
                    id: "q\(offset)", sourceID: "video", firstLine: nil, lastLine: nil, startSeconds: nil,
                    question: "Q\(offset)?", answer: "A.", keyPoints: [], quote: nil,
                    picture: CourseQuizPicture(storedImage: CourseQuizPicture.storedImageURL(id: id), caption: nil, placement: .answer)
                )
            },
            author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("The pictures a Mac holds travel whole; the receiving store gains only what it lacks")
    func roundTrip() throws {
        let sender = try root("sender")
        let receiver = try root("receiver")
        defer {
            try? FileManager.default.removeItem(at: sender)
            try? FileManager.default.removeItem(at: receiver)
        }
        let held = "1a2b3c4d-0000-4000-8000-000000000001"
        let missing = "1a2b3c4d-0000-4000-8000-000000000002"
        let already = "1a2b3c4d-0000-4000-8000-000000000003"
        let senderStore = sender.appendingPathComponent(GeneratedImageStore.directory)
        try Self.png.write(to: senderStore.appendingPathComponent("\(held).png"))
        try Self.png.write(to: senderStore.appendingPathComponent("\(already).png"))
        let receiverStore = receiver.appendingPathComponent(GeneratedImageStore.directory)
        let kept = Data(Self.png.reversed())
        try kept.write(to: receiverStore.appendingPathComponent("\(already).jpg"))

        let ids = CourseQuizPicturePackage.storedImageIDs(in: [quiz(showing: [held, missing, held, already])])
        #expect(ids == [held, missing, already])
        let files = CourseQuizPicturePackage.localFiles(for: ids, root: sender)
        #expect(files.map(\.id) == [held, already], "a picture this Mac lacks is left out; the rest still travel")
        let digest = CourseQuizPicturePackage.digest(files)
        #expect(digest.hasPrefix("q:"))
        #expect(CourseQuizPicturePackage.digest(files) == digest)
        #expect(CourseQuizPicturePackage.digest(Array(files.prefix(1))) != digest)

        let package = try #require(CourseQuizPicturePackage.encode(files))
        let packageURL = receiver.appendingPathComponent("package.plist")
        try package.write(to: packageURL)
        let written = CourseQuizPicturePackage.materialize(packageAt: packageURL, root: receiver)
        #expect(written == [held])
        #expect(try Data(contentsOf: receiverStore.appendingPathComponent("\(held).png")) == Self.png)
        #expect(try Data(contentsOf: receiverStore.appendingPathComponent("\(already).jpg")) == kept, "nothing in the store is replaced")
        #expect(CourseQuizPicturePackage.materialize(packageAt: packageURL, root: receiver).isEmpty)
    }

    @Test("A name that is not a store file, or bytes that are not a picture, never land")
    func refusesWhatIsNotAPicture() throws {
        let receiver = try root("hostile")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let entries: [String: Data] = [
            "../escape.png": Self.png,
            "not-an-id.png": Self.png,
            "1a2b3c4d-0000-4000-8000-000000000009.txt": Self.png,
            "1a2b3c4d-0000-4000-8000-00000000000a.png": Data("not a picture".utf8),
            "1a2b3c4d-0000-4000-8000-00000000000b.png": Self.png,
        ]
        let packageURL = receiver.appendingPathComponent("package.plist")
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0).write(to: packageURL)
        #expect(CourseQuizPicturePackage.materialize(packageAt: packageURL, root: receiver) == ["1a2b3c4d-0000-4000-8000-00000000000b"])
        #expect(!FileManager.default.fileExists(atPath: receiver.appendingPathComponent("escape.png").path))
    }
}
