import Foundation
import Testing
@testable import ForeverLM

@Suite("Lecture Quiz Planning")
struct LectureQuizPlanningTests {
    /// Twenty numbered lines, one every 30 seconds.
    private let lines: [LectureQuizLine] = (1...20).map {
        LectureQuizLine(number: $0, seconds: Double(($0 - 1) * 30), text: "Line \($0) says something about membrane potential and ATP.")
    }

    @Test("An untimed transcript's block carries only numbers")
    func untimedTranscript() {
        let plain = (1...5).map { LectureQuizLine(number: $0, seconds: nil, text: "Paragraph \($0).") }
        #expect(LectureQuizPlanning.transcriptBlock(plain).text.hasPrefix("[1] Paragraph 1.\n[2] Paragraph 2."))
    }

    @Test("A timed block prints the number and the time")
    func timedBlock() {
        let block = LectureQuizPlanning.transcriptBlock(Array(lines.prefix(3)))
        #expect(block.text == """
        [1 · 0:00] Line 1 says something about membrane potential and ATP.
        [2 · 0:30] Line 2 says something about membrane potential and ATP.
        [3 · 1:00] Line 3 says something about membrane potential and ATP.
        """)
        #expect(!block.truncated)
        #expect(LectureQuizPlanning.transcriptBlock(lines, budget: 200).truncated)
    }

    @Test("About one question per two and a half minutes, eight to sixty")
    func targetCount() {
        #expect(LectureQuizPlanning.targetQuestionCount(spanSeconds: 300) == 8)
        #expect(LectureQuizPlanning.targetQuestionCount(spanSeconds: 40 * 60) == 16)
        #expect(LectureQuizPlanning.targetQuestionCount(spanSeconds: 3 * 3600) == 60)
        #expect(LectureQuizPlanning.targetQuestionCount(spanSeconds: nil) == 15)
    }

    @Test("A sitting counts right answers and remembered ones; partial, forgotten and skipped are not right")
    func score() {
        let score = LectureQuizScore(outcomes: [
            .graded(.correct), .graded(.partial), .graded(.incorrect), .remembered, .forgot, .skipped,
        ])
        #expect(score.right == 2)
        #expect(score.total == 6)
        #expect(score.label == "2 of 6 right")
    }

    @Test("A score survives the preference row it is kept in")
    func scoreRoundTrip() throws {
        let score = LectureQuizScore(right: 3, total: 5, takenAt: Date(timeIntervalSince1970: 1_790_000_000))
        let decoded = try #require(LectureQuizScore(preferenceValue: score.preferenceValue))
        #expect(decoded.right == 3)
        #expect(decoded.total == 5)
        #expect(decoded.takenAt.timeIntervalSince1970 == 1_790_000_000)
        #expect(LectureQuizScore.preferenceKey(sourceID: "abc") == "lectureQuiz.score.abc")
    }

    @Test("A row that is not a sitting is ignored")
    func rejectsBadRows() {
        #expect(LectureQuizScore(preferenceValue: "3/5") == nil)
        #expect(LectureQuizScore(preferenceValue: ["right": 1, "total": 0]) == nil)
        #expect(LectureQuizScore(preferenceValue: ["right": 6, "total": 5]) == nil)
        #expect(LectureQuizScore(preferenceValue: ["right": 2]) == nil)
    }

    @Test("Stored scores are read back per lecture, and other keys are left alone")
    func scoresFromDefaults() throws {
        let suite = "LectureQuizPlanningTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LectureQuizScore(right: 4, total: 5, takenAt: Date()).preferenceValue,
                     forKey: LectureQuizScore.preferenceKey(sourceID: "lecture-1"))
        defaults.set(["right": 9, "total": 2], forKey: LectureQuizScore.preferenceKey(sourceID: "lecture-2"))
        defaults.set("unrelated", forKey: "reader.videoQuizCheckpoints")
        let scores = LectureQuizScore.scoresFromDefaults(defaults)
        #expect(Set(scores.keys) == ["lecture-1"])
        #expect(scores["lecture-1"]?.label == "4 of 5 right")
    }
}

/// `LectureQuizTimeline`: a quiz question is timed where its lecture says its
/// quote, not at the start of the thirty-second block the quote is in.
@Suite("Lecture Quiz Timeline")
struct LectureQuizTimelineTests {
    /// "Mitochondrial Cell Biology 3" from 3:18 to 5:03 as its transcript is
    /// stored: blocks of YouTube captions, each timed at its start. Question 6
    /// of the product owner's "Biogenesis, Quality, and Signaling" quiz quotes "Only 13
    /// of …", which YouTube's captions have at 4:04; the quiz sent him to
    /// 3:52, the block's start (2026-09-28).
    private let lines: [LectureQuizLine] = [
        LectureQuizLine(number: 1, seconds: 198, text: "the complexity of generating components of mitochondria, and the truth is that the different pathways are going to be regulated in different manners, so just measuring one or two parameters it's not going to tell you how much mitochondrial activity there is, because mitochondrial activity is not a very specific term. Having said that, to generate more of mitochondrial mass involves coordinated control of mitochondrial and nuclear proteins, lipids, and also the replication of mitochondrial DNA because we have"),
        LectureQuizLine(number: 2, seconds: 232, text: "many, many copies of mitochondrial DNA per cell. Remember, always, that most mitochondrial proteins are encoded by nuclear genes. Only 13 of mitochondrial oxidative phosphorylation protein components of mitochondria oxidative phosphorylation are encoded by mitochondrial DNA; the rest of those 1,500 proteins that mitochondria express are encoded in the nucleus, and that means that these proteins have to be imported into mitochondria. Importing proteins into mitochondria requires transporters of these proteins into mitochondria, and"),
        LectureQuizLine(number: 3, seconds: 271, text: "these transporters are the Tim and Tom system. So Tom stands for the transporter of the outer mitochondrial membrane, and this is a transporter that's going to recognize these proteins that have a target sequence that targets them towards mitochondria. It's going to recognize this target sequence; it's going to transport these proteins into the intermembrane space with the N-terminal and its positive charge on this end terminal first. Then the rest of the transport is going to happen through"),
        LectureQuizLine(number: 4, seconds: 303, text: "Tim, which is the transporter in the inner membrane, and Tim often is related structurally to Tom, forming a supercomplex, and actually Tim and Tom can be in those contact sites between the inner and outer mitochondrial membrane. Tim is going to transport this protein into mitochondria, and this transport is dependent on the inner mitochondrial membrane potential, which is actually going to attract this positive charge of this N-terminal of this unfolded protein within mitochondria. Each protein"),
    ]

    private let only13 = "Only 13 of mitochondrial oxidative phosphorylation protein components"

    @Test("A quote is timed where it falls in its block, a moment early, not at the block's start")
    func quoteWithinItsBlock() {
        let timeline = LectureQuizTimeline(lines)
        #expect(timeline.seconds(saying: only13) == 239, "3:59, before the 4:04 the captions give, not 3:52")
        #expect(timeline.seconds(saying: "recognize these proteins that have a target sequence that targets them towards mitochondria") == 279, "the captions: 4:41")
    }

    @Test("A quote opening a block is timed at the block, and one running over a marker from where it starts")
    func blockEdges() {
        let timeline = LectureQuizTimeline(lines)
        #expect(timeline.seconds(saying: "these transporters are the Tim and Tom system") == 271, "never before its own line")
        #expect(timeline.seconds(saying: "because we have many, many copies of mitochondrial DNA per cell") == 228)
    }

    @Test("The last block, with no next time, runs at the lecture's pace")
    func lastBlock() {
        #expect(LectureQuizTimeline(lines).seconds(saying: "this transport is dependent on the inner mitochondrial membrane potential") == 320, "the captions: 5:24")
    }

    @Test("A paragraph with no time of its own is placed between the times around it")
    func untimedParagraph() {
        var gapped = lines
        gapped[1] = LectureQuizLine(number: 2, seconds: nil, text: lines[1].text)
        #expect(LectureQuizTimeline(gapped).seconds(saying: only13) == 240)
    }

    @Test("Words the lecture never says, an untimed text, and a quote outside the lines it rests on have no moment")
    func noMoment() {
        let timeline = LectureQuizTimeline(lines)
        #expect(timeline.seconds(saying: "only thirteen of mitochondrial proteins") == nil)
        #expect(timeline.seconds(saying: "") == nil)
        #expect(timeline.seconds(saying: only13, within: 3...4) == nil)
        #expect(timeline.seconds(saying: only13, within: 1...2) == 239)
        #expect(timeline.seconds(saying: only13, within: 7...9) == nil)
        let untimed = lines.map { LectureQuizLine(number: $0.number, seconds: nil, text: $0.text) }
        #expect(!LectureQuizTimeline(untimed).isTimed)
        #expect(LectureQuizTimeline(untimed).seconds(saying: only13) == nil)
    }

    @Test("A stored quiz is retimed from its quotes; a question with no quote, or on a source not read, keeps its time")
    func storedQuizRetimed() {
        func question(_ id: String, sourceID: String, startSeconds: Double?, quote: String?) -> CourseQuizQuestion {
            CourseQuizQuestion(
                id: id, sourceID: sourceID, firstLine: nil, lastLine: nil, startSeconds: startSeconds,
                question: "Question \(id)?", answer: "Answer.", keyPoints: [], quote: quote
            )
        }
        let stored = [
            question("q6", sourceID: "mcb3", startSeconds: 232, quote: only13),
            question("q7", sourceID: "mcb3", startSeconds: 271, quote: nil),
            question("q8", sourceID: "elsewhere", startSeconds: 40, quote: only13),
            question("q9", sourceID: "mcb3", startSeconds: nil, quote: "these transporters are the Tim and Tom system"),
        ]
        let timed = CourseQuizPlanning.timedByQuotes(stored, lines: ["mcb3": lines])
        #expect(timed.map(\.startSeconds) == [239, 271, 40, 271])
        #expect(timed.map(\.id) == stored.map(\.id))
        #expect(timed.map(\.quote) == stored.map(\.quote))
    }

    @Test("A written question rewatches from its quote within the lines it names, and from its first line without one")
    func writtenQuestionTimedFromQuote() {
        let part = CourseQuizPart(lectureID: "lecture-3", lectureTitle: "Lecture 3", sourceID: "mcb3", lines: lines)
        let questions = CourseQuizPlanning.questions(
            from: CourseQuizDraft(questions: [
                CourseQuizDraft.Question(
                    part: nil, firstLine: 1, lastLine: 2, question: "How many OXPHOS proteins does mtDNA encode?",
                    answer: "13.", keyPoints: nil, quote: only13
                ),
                CourseQuizDraft.Question(
                    part: nil, firstLine: 3, lastLine: 3, question: "What does TOM recognize?",
                    answer: "A target sequence.", keyPoints: nil, quote: nil
                ),
                CourseQuizDraft.Question(
                    part: nil, firstLine: 4, lastLine: 4, question: "What drives import through TIM?",
                    answer: "The membrane potential.", keyPoints: nil, quote: only13
                ),
            ]),
            parts: [part]
        )
        #expect(questions.map(\.startSeconds) == [239, 271, 303], "a quote outside its lines leaves the first line's time")
    }
}
