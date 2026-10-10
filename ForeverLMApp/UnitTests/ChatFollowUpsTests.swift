import Foundation
import Testing
@testable import ForeverLM

/// The suggested questions a chat reply ends with: the `<flm_follow_ups>`
/// tail is split off the reply, hidden while it streams, never stored, and
/// asked for only in a chat whose answers are answers (docs/chat-design.md,
/// "Suggested questions under the answer"). The fixtures are the shared
/// contract with the renderer's `splitFollowUps` (library-chat-markdown.test.ts).
@Suite("Chat follow-up questions")
struct ChatFollowUpsTests {
    struct Fixture: CustomTestStringConvertible, Sendable {
        let name: String
        let input: String
        let prose: String
        let questions: [String]
        var testDescription: String { name }
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "a complete block",
            input: "Answer.\n\n<flm_follow_ups>\nWhy A?\nHow B?\nWhat C?\n</flm_follow_ups>",
            prose: "Answer.",
            questions: ["Why A?", "How B?", "What C?"]
        ),
        Fixture(
            name: "list markers and quotes come off, three at most",
            input: "Answer.\n<flm_follow_ups>\n- Why A?\n2. How B?\n* \"What C?\"\nFourth?\n</flm_follow_ups>\n",
            prose: "Answer.",
            questions: ["Why A?", "How B?", "What C?"]
        ),
        Fixture(
            name: "an unterminated block is cut and yields nothing",
            input: "Answer.\n<flm_follow_ups>\nWhy A?\nHow",
            prose: "Answer.",
            questions: []
        ),
        Fixture(
            name: "a trailing piece of the tag is cut",
            input: "Answer.\n<flm_fol",
            prose: "Answer.",
            questions: []
        ),
        Fixture(
            name: "a linked line is no question, and the prose keeps its links",
            input: "See [it](foreverlm://source/X).\n<flm_follow_ups>\nOpen [it](foreverlm://source/X)?\nWhy A?\n</flm_follow_ups>",
            prose: "See [it](foreverlm://source/X).",
            questions: ["Why A?"]
        ),
        Fixture(
            name: "no block, and a bare angle bracket stays",
            input: "No block; a < b.",
            prose: "No block; a < b.",
            questions: []
        ),
        Fixture(
            name: "duplicates by case go, empty lines go",
            input: "Answer.\n<flm_follow_ups>\nwhy a?\nWhy A?\n\n</flm_follow_ups>",
            prose: "Answer.",
            questions: ["why a?"]
        ),
        // What a cheaper model dresses the block in.
        Fixture(
            name: "a label line over the block goes with it",
            input: "Answer.\n\nSuggested questions:\n<flm_follow_ups>\nWhy A?\n</flm_follow_ups>",
            prose: "Answer.",
            questions: ["Why A?"]
        ),
        Fixture(
            name: "a bold label goes, and a template's sample lines are no questions",
            input: "Answer.\n**Suggested questions:**\n<flm_follow_ups>\nFirst question?\nWhy A?\nSecond question?\nThird question?\n</flm_follow_ups>",
            prose: "Answer.",
            questions: ["Why A?"]
        ),
        Fixture(
            name: "a fence around the block leaves no empty code box",
            input: "Answer.\n\n```\n<flm_follow_ups>\nWhy A?\nHow B?\n</flm_follow_ups>\n```",
            prose: "Answer.",
            questions: ["Why A?", "How B?"]
        ),
        Fixture(
            name: "a fence whose closing is still arriving, or never comes, goes too",
            input: "Answer.\n```\n<flm_follow_ups>\nWhy A?\n</flm_follow_ups>\n`",
            prose: "Answer.",
            questions: ["Why A?"]
        ),
        Fixture(
            name: "a fence opened for a block still streaming goes with it",
            input: "Answer.\n\n```text\n<flm_follow_ups>\nWhy",
            prose: "Answer.",
            questions: []
        ),
        Fixture(
            name: "a label over a tag still arriving goes with it",
            input: "Answer.\nSuggested questions:\n<flm_fo",
            prose: "Answer.",
            questions: []
        ),
        Fixture(
            name: "the reply's own code block keeps its closing fence",
            input: "Run:\n```\nls\n```\n<flm_follow_ups>\nWhy A?\n</flm_follow_ups>",
            prose: "Run:\n```\nls\n```",
            questions: ["Why A?"]
        ),
    ]

    @Test("The tail splits off the prose", arguments: fixtures)
    func split(_ fixture: Fixture) {
        let split = ChatFollowUps.split(fixture.input)
        #expect(split.prose == fixture.prose)
        #expect(split.questions == fixture.questions)
        #expect(ChatFollowUps.hidingBlock(in: fixture.input) == fixture.prose)
    }

    @Test("While a reply streams, no part of the block is ever shown")
    func hiddenAtEveryPrefix() {
        let prose = "Cristae fold the inner membrane."
        let reply = prose + "\n\n<flm_follow_ups>\nWhy do cristae fold?\nWhat sets their width?\n</flm_follow_ups>"
        for length in 0...reply.count {
            var shown = ChatFollowUps.hidingBlock(in: String(reply.prefix(length)))
            // A lone "<" could open any tag; the streaming path's tool-call
            // stripper, which runs first, takes that one.
            if shown.hasSuffix("<") { shown.removeLast() }
            shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(prose.hasPrefix(shown), "prefix \(length) showed \(shown)")
        }
        #expect(ChatFollowUps.hidingBlock(in: reply) == prose)
    }

    @Test("Only the last complete block's lines are questions, and every block leaves the prose")
    func lastBlockWins() {
        let split = ChatFollowUps.split(
            "One.\n<flm_follow_ups>\nOld?\n</flm_follow_ups>\nTwo.\n<flm_follow_ups>\nNew?\n</flm_follow_ups>"
        )
        #expect(split.prose == "One.\n\nTwo.")
        #expect(split.questions == ["New?"])
    }

    @Test("Over-long lines and tags are no questions; curly quotes and numbering come off")
    func lineRules() {
        let long = String(repeating: "word ", count: 40) + "end?"
        let split = ChatFollowUps.split(
            "A.\n<flm_follow_ups>\n\(long)\n<b>Bold?</b>\n1) “Why does it   leak?”\n</flm_follow_ups>"
        )
        #expect(split.questions == ["Why does it leak?"])
    }

    // MARK: - Every reader of a reply sees the prose alone

    @Test("The rendered, copied and quoted reply has no block, even one stored with it")
    @MainActor
    func displayedAndCopiedWithoutTheBlock() {
        let raw = Self.fixtures[0].input
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: raw) == "Answer.")
        let reply = ReviewSessionManager.Message(role: .assistant, content: raw)
        let question = ReviewSessionManager.Message(role: .user, content: "Why?")
        #expect(ReviewSessionManager.copiedAnswerText(from: [reply]) == "Answer.")
        #expect(!ReviewSessionManager.copiedConversationText(from: [question, reply]).contains("flm_follow_ups"))
        #expect(!ReviewSessionManager.copiedConversationText(from: [question, reply]).contains("Why A?"))
    }

    private static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    private static func storedReplies(_ storage: StorageService, sessionID: String) async throws -> [String?] {
        try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map(\.evaluation)
    }

    @MainActor
    private static func chat(
        _ name: String,
        sessionID: String = "chat"
    ) async throws -> (ReviewSessionManager, StorageService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString)", isDirectory: true)
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: sessionID, topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: sessionID, generationInFlight: false)
        // The learner has asked, so the reply has a turn to answer.
        await manager.saveLearnerMessageForTesting("why do cristae fold?")
        manager.beginTurnForTesting()
        return (manager, storage, root)
    }

    @Test("A finished turn stores its reply without the block, so history, fork, MCP and search never see it")
    @MainActor
    func storedReplyHasNoBlock() async throws {
        let (manager, storage, root) = try await Self.chat("FollowUpsStored")
        defer { try? FileManager.default.removeItem(at: root) }

        // Through the generation loops' own last step (`settleAnswer`).
        _ = try await manager.settleReplyForTesting(Self.fixtures[0].input, config: Self.config)
        #expect(try await Self.storedReplies(storage, sessionID: "chat") == ["Answer."])

        // The store strips the block itself too, for a reply that reaches it
        // whole (Stop saves whatever had streamed).
        let (raw, rawStorage, rawRoot) = try await Self.chat("FollowUpsStoredRaw")
        defer { try? FileManager.default.removeItem(at: rawRoot) }
        try await raw.finishTurnForTesting(reply: Self.fixtures[0].input, config: Self.config)
        #expect(try await Self.storedReplies(rawStorage, sessionID: "chat") == ["Answer."])
    }

    /// Both streams retry a reply with nothing the learner could read for a
    /// visible answer (`Retrying for a visible answer`), and a reply that is
    /// only the block is one: they test what `hidingBlock` leaves. Should one
    /// reach the end of a turn anyway, nothing is stored and the turn fails
    /// as an empty stream does.
    @Test("A reply that is only the block is no answer: it is retried, and never stored as an empty one")
    @MainActor
    func blockOnlyReplyIsNoAnswer() async throws {
        let blockOnly = "<flm_follow_ups>\nWhy A?\n</flm_follow_ups>"
        #expect(ChatFollowUps.hidingBlock(in: blockOnly).isEmpty)
        #expect(ChatFollowUps.hidingBlock(in: "\n\n" + blockOnly + "\n").isEmpty)

        let (manager, storage, root) = try await Self.chat("FollowUpsBlockOnly")
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: AIError.self) {
            _ = try await manager.settleReplyForTesting(blockOnly, config: Self.config)
        }
        #expect(!manager.chatMessages.contains { $0.role == .assistant })
        let stored = try await Self.storedReplies(storage, sessionID: "chat")
        #expect(stored.allSatisfy { ($0 ?? "").isEmpty }, "stored \(stored)")
    }

    @Test("Stop keeps what streamed, without the block")
    @MainActor
    func stoppedReplyHasNoBlock() async throws {
        let (manager, storage, root) = try await Self.chat("FollowUpsStopped")
        defer { try? FileManager.default.removeItem(at: root) }

        // Words had landed, so the model switch ends the turn as a Stop.
        let restarts = await manager.restartTurnForTesting(
            streamed: "Answer.\n<flm_follow_ups>\nWhy A?\n</flm_follow_ups>",
            config: Self.config
        )

        #expect(!restarts)
        #expect(try await Self.storedReplies(storage, sessionID: "chat") == ["Answer."])
    }

    @Test("A settled reply keeps its questions on its row in a chat, and none in a memory review")
    @MainActor
    func questionsLandOnTheRow() async throws {
        let (manager, _, root) = try await Self.chat("FollowUpsRow")
        defer { try? FileManager.default.removeItem(at: root) }

        let row = try await manager.settleReplyForTesting(Self.fixtures[0].input, config: Self.config)
        #expect(row?.content == "Answer.")
        #expect(row?.followUpQuestions == ["Why A?", "How B?", "What C?"])

        let (review, _, reviewRoot) = try await Self.chat("FollowUpsMemoryRow", sessionID: "memory-2026-09-30")
        defer { try? FileManager.default.removeItem(at: reviewRoot) }
        let reviewRow = try await review.settleReplyForTesting(Self.fixtures[0].input, config: Self.config)
        #expect(reviewRow?.content == "Answer.")
        #expect(reviewRow?.followUpQuestions == [])
    }

    // MARK: - Which chats are asked for them

    @Test("Chats that answer get the answer shape and the block; a review, a course quiz, a memory review and a walk do not")
    @MainActor
    func promptGate() {
        for mode in [ReviewSessionManager.InitialPromptMode.assistant, .summarize, .shallowRead, .deepRead, .deepResearch] {
            let gate = ReviewSessionManager.followUpGateForTesting(mode: mode)
            #expect(gate.offers, "\(mode) should offer suggested questions")
            #expect(gate.stable.contains(Prompts.answerShape))
            #expect(gate.stable.contains(Prompts.followUpQuestions))
            // The reminder rides the tail, where a long chat still sees it.
            #expect(gate.volatile.contains(Prompts.followUpQuestionsReminder))
            #expect(!gate.stable.contains(Prompts.followUpQuestionsReminder))
        }
        // A review the learner opened by typing is study.
        let study = ReviewSessionManager.followUpGateForTesting(mode: .review, learnerWrote: true)
        #expect(study.offers)
        #expect(study.stable.contains(Prompts.followUpQuestions))

        let closed = [
            ReviewSessionManager.followUpGateForTesting(mode: .review),
            ReviewSessionManager.followUpGateForTesting(mode: .assistant, courseQuiz: Self.courseQuiz()),
            ReviewSessionManager.followUpGateForTesting(mode: .assistant, sessionID: "memory-2026-09-30"),
            ReviewSessionManager.followUpGateForTesting(mode: .assistant, walkthrough: Self.walkthrough()),
        ]
        for gate in closed {
            #expect(!gate.offers)
            #expect(!gate.stable.contains(Prompts.answerShape))
            #expect(!gate.stable.contains("<flm_follow_ups>"))
            #expect(!gate.volatile.contains("<flm_follow_ups>"))
        }
    }

    @Test("The block is asked for in words, with no label line and no sample questions to copy")
    func promptHasNothingToEcho() {
        #expect(!Prompts.followUpQuestions.contains("Suggested questions:"))
        #expect(!Prompts.followUpQuestions.contains("First question?"))
        #expect(Prompts.followUpQuestions.contains("<flm_follow_ups>"))
        #expect(Prompts.followUpQuestions.contains("</flm_follow_ups>"))
        // The answer comes first, told the way the textbook rules ask, and a
        // short answer's steps are a list rather than headings.
        #expect(Prompts.answerShape.contains("Lead with the answer in a short first paragraph, told concretely, the way a good textbook does"))
        #expect(Prompts.answerShape.contains("Steps of a sentence each are a numbered list"))
        #expect(Prompts.answerShape.contains("A review, a quiz or a Deep Research plan keeps its own shape"))
    }

    @Test("The answer shape follows the response budget, once")
    @MainActor
    func promptPlacement() throws {
        let stable = ReviewSessionManager.followUpGateForTesting(mode: .assistant).stable
        let budget = try #require(stable.range(of: "Response budget:"))
        let shape = try #require(stable.range(of: Prompts.answerShape))
        #expect(budget.upperBound < shape.lowerBound)
        #expect(stable.components(separatedBy: Prompts.followUpQuestions).count == 2)
    }

    @Test("The study chat no longer asks its own follow-up question")
    func studyChatDropsItsFollowUp() {
        #expect(!Prompts.studyChat.contains("Ask at most one focused follow-up question"))
        #expect(Prompts.answerShape.contains("no \"Would you like…\" question"))
    }

    @Test("The response budget reads the same on the Mac and in the phone's memory review")
    @MainActor
    func responseBudgetMatchesThePortableCopy() throws {
        func budgetLine(_ prompt: String) -> String? {
            prompt.components(separatedBy: "\n").first { $0.hasPrefix("Response budget:") }
        }
        let mac = try #require(budgetLine(ReviewSessionManager.followUpGateForTesting(mode: .review).stable))
        let portable = try #require(budgetLine(
            MemoryReviewTutoring.systemPrompt(briefing: "B", localClockDescription: "Wednesday, 2026-09-30, 09:00")
        ))
        #expect(mac == portable)
        #expect(mac.contains("Prefer short paragraphs and compact sections"))
        #expect(!mac.contains("explicit next steps"))
    }

    // MARK: - Save to note

    @Test("A saved note is named after the learner's question, cut at a word, or after the chat")
    func noteTitle() {
        #expect(ReviewChatSaveToNote.title(
            learnerMessage: "  Why   do cristae\nfold the way they do?",
            chatTitle: "Cristae",
            answer: "x"
        ) == "Why do cristae")
        let long = "How does the proton gradient across the inner mitochondrial membrane drive ATP synthase rotation in detail?"
        let cut = ReviewChatSaveToNote.title(learnerMessage: long, chatTitle: "Cristae", answer: "x")
        #expect(cut == "How does the proton gradient across the inner mitochondrial membrane drive ATP…")
        #expect(cut.count <= ReviewChatSaveToNote.maximumTitleLength + 1)
        #expect(ReviewChatSaveToNote.title(learnerMessage: "why?", chatTitle: "Cristae Junctions", answer: "x") == "Cristae Junctions")
        #expect(ReviewChatSaveToNote.title(learnerMessage: nil, chatTitle: "Cristae Junctions", answer: "x") == "Cristae Junctions")
        #expect(ReviewChatSaveToNote.title(learnerMessage: "why?", chatTitle: " ", answer: "x") == "why?")
    }

    @Test("A saved note holds the reply rows as read, without tool or thinking rows or the block")
    @MainActor
    func noteBody() {
        let tool = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: ReviewSessionManager.Message.ToolActivity(
                kind: .tool, toolName: "retrieve_sources", detail: nil, state: .succeeded, resultPreview: nil
            )
        )
        let lead = ReviewSessionManager.Message(role: .assistant, content: "Let me look. [1](foreverlm://source/S1?t=754)")
        let answer = ReviewSessionManager.Message(role: .assistant, content: Self.fixtures[0].input)
        #expect(ReviewChatSaveToNote.markdown(of: [lead, tool, answer])
            == "Let me look. [1](foreverlm://source/S1?t=754)\n\nAnswer.")
    }

    // MARK: - Fixtures

    /// A walk over a talk, with nothing dealt, so setting it writes no
    /// progress anywhere.
    private static func walkthrough() -> ReviewSessionManager.WalkthroughPlayback {
        let talk = StudioArticle(url: "https://example.com/talk", title: "Talk", sourceType: .article, discoveryOrigin: .manual)
        return ReviewSessionManager.WalkthroughPlayback(
            subject: .source(talk),
            walkthrough: PaperWalkthrough(
                sourceID: talk.id,
                sourceSHA256: "x",
                title: "W",
                steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "S", body: "B.")],
                author: .app
            ),
            currentIndex: 0,
            playedStepIDs: []
        )
    }

    private static func courseQuiz() -> CourseQuizChatState {
        let question = CourseQuizQuestion(
            id: "q1", sourceID: "video", firstLine: 3, lastLine: 3,
            startSeconds: nil, question: "Question 1?", answer: "Answer 1.",
            keyPoints: ["point 1"], quote: nil, levelName: CourseQuizQuestion.Level.recall.rawValue
        )
        let quiz = CourseQuiz(
            id: "quiz", courseID: "course", kind: .practice, title: "Cristae", lectureIDs: ["l1"],
            afterLectureID: "l1", questions: [question], author: .foreverlm, createdAt: Date(), updatedAt: Date()
        )
        return CourseQuizChatState(request: CourseQuizChatRequest(
            quiz: quiz,
            topic: "Quiz: Cristae",
            subtitle: "Lecture 1",
            sourceIDs: ["video"],
            sourceTitles: ["video": "Mitochondrial Cell Biology 1"],
            grade: { _, _, _ in (.graded(VideoQuizGrade(verdict: .correct, feedback: "Yes.")), nil) },
            recorded: { _, _ in }
        ))
    }
}
