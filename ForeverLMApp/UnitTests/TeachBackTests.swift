import Foundation
import Testing
@testable import ForeverLM

/// The Feynman Technique (`TeachBack`): a notebook chat that opens by asking
/// the learner what they know, whose tutor probes and then fills in rather
/// than explains first, and which keeps that tutor when it is reopened because its id
/// names it.
@Suite("Teach back")
@MainActor
struct TeachBackTests {

    private static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    @Test("A teach-back's id carries its kind, and the chat is kept as a private review")
    func sessionIDNamesTheChat() {
        let uuid = UUID(uuidString: "6F0C1E2A-3B4D-4C5E-8F60-718293A4B5C6")!
        let id = TeachBack.sessionID(uuid: uuid)
        #expect(id == "teach-back-6F0C1E2A-3B4D-4C5E-8F60-718293A4B5C6")
        #expect(TeachBack.isSessionID(id))
        #expect(!TeachBack.isSessionID(uuid.uuidString))
        #expect(!TeachBack.isSessionID(CourseQuizSitting.sessionID(forQuizID: "q1")))
        #expect(ReviewSessionManager.createdChatKind(fixedSessionID: id, mode: .review) == .review)
        #expect(ChatKindClassifier.kind(of: .init(id: id, kind: ChatKind.review.rawValue)) == .review)
        #expect(ChatKind.review.isPrivate)
        #expect(TeachBack.topic(notebookTitle: "Mitochondria") == "Feynman Technique: Mitochondria")
    }

    @Test("The opening is written ahead: it names the notebook and asks what the learner knows, from memory")
    func scriptedOpening() {
        let opening = TeachBack.openingMessage(notebookTitle: "Mitochondria")
        #expect(opening == "Tell me what you know about \u{201C}Mitochondria\u{201D}, in your own words, from memory, in whatever order it comes. I'll show you pictures from your sources and ask about the gaps.")
        #expect(!opening.contains("\u{2014}"), "Web serves the same words, and its files carry no em dash")
    }

    @Test("A chat started with a teach-back id runs the teach-back tutor, reports Review, and offers no suggested questions")
    func startedChatRunsTheTeachBackTutor() {
        let started = ReviewSessionManager.startedChatForTesting(fixedSessionID: TeachBack.sessionID())
        #expect(started.isTeachBack)
        #expect(started.mode == .review)
        #expect(!started.offers, "the tutor's question is the next step, not one of the learner's")
        #expect(started.stable.hasPrefix(Prompts.teachBackTutor))
        #expect(!started.stable.contains("Review plan"), "no plan, unlike a review")
        #expect(started.stable.components(separatedBy: Prompts.hiddenIDs).count == 2, "the id rule rides the head once")

        for other in [nil, UUID().uuidString, CourseQuizSitting.sessionID(forQuizID: "q1")] {
            let review = ReviewSessionManager.startedChatForTesting(fixedSessionID: other)
            #expect(!review.isTeachBack)
            #expect(review.stable.hasPrefix(Prompts.reviewTutor))
        }
        let chat = ReviewSessionManager.startedChatForTesting(fixedSessionID: nil, mode: .assistant)
        #expect(!chat.isTeachBack)
        #expect(chat.offers)
    }

    @Test("The tutor's rules: learner-led, one question at the biggest gap, filling the gap after a failed retry, then the simplest version and the limits, never ending on its own")
    func tutorPromptRules() {
        let prompt = Prompts.teachBackTutor
        for rule in [
            "Feynman Technique",
            "tells you what they know about its subject in their own words, from memory",
            "never do it for them",
            "never summarize them, quote them at length, or explain any part of the subject before the learner has tried",
            "their text is not loaded",
            "Never show a plan",
            "Lead with pictures",
            "show the picture that settles it",
            "Never write a paragraph, a list or a wall of text",
            "exactly one prompting question, aimed at the biggest gap",
            "a technical term used without saying what it means",
            "a claim with no evidence behind it",
            "do not correct it. Show the picture that settles it and ask a question that lets them notice the problem themselves",
            "When they do not know, or their second try still misses it, fill the gap",
            "say which source it comes from and where",
            "ask them to say it back in their own words",
            "ask for the simplest version",
            "probe their assumptions and limits",
            "Never name a tool",
            "Never decide that the session is over",
        ] {
            #expect(prompt.contains(rule), "the prompt lacks: \(rule)")
        }
        // Web sends these words byte for byte from its own copy.
        #expect(!prompt.contains("\u{2014}"))
        #expect(!prompt.contains("\\"))
        #expect(!prompt.contains("ID:"), "the id rule is Prompts.hiddenIDs's, not restated here")
    }

    @Test("A teach-back keeps its opening as the tutor's first question, its replies on the answers, and its tutor when reopened")
    func teachBackKeepsItsTutorWhenReopened() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeachBack_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let sessionID = TeachBack.sessionID()
        try await storage.createReviewSession(
            id: sessionID,
            topic: TeachBack.topic(notebookTitle: "Mitochondria"),
            sourceIDs: [],
            chatKind: .review
        )
        let manager = ReviewSessionManager(storage: storage)
        let opening = TeachBack.openingMessage(notebookTitle: "Mitochondria")
        await manager.openScriptedReviewForTesting(sessionID: sessionID, opening: opening)
        #expect(manager.isTeachBackSession)

        let probe = "You said the cristae change shape. What makes them change shape?"
        await manager.saveLearnerMessageForTesting("It is about how cristae change shape when cells need more energy.")
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: probe, config: Self.config)
        #expect(manager.isTeachBackSession, "a learner's message never turns it into study")

        let exchanges = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.first?.question == opening)
        #expect(exchanges.first?.userAnswer == "It is about how cristae change shape when cells need more energy.")
        #expect(exchanges.first?.evaluation == probe)

        #expect(ReviewSessionManager.resumedPromptKindForTesting(sessionID: sessionID, exchanges: exchanges) == "teachBack")
        #expect(ReviewSessionManager.resumedPromptKindForTesting(sessionID: sessionID, exchanges: []) == "teachBack")
        // The same transcript under any other id is a review, as before.
        #expect(ReviewSessionManager.resumedPromptKindForTesting(sessionID: UUID().uuidString, exchanges: exchanges) == "review")
    }

    @Test("A chat of a Notebook offers start_feynman_technique when its pane can open it, and no other chat does")
    func notebookChatOffersTheTool() {
        func offered(notebook: String?, opens: Bool) -> Bool {
            ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: true,
                appTools: [],
                hasSynthesisContext: false,
                notebookScopeID: notebook,
                opensTeachBack: opens
            ).contains { $0.name == TeachBack.toolName }
        }
        #expect(TeachBack.toolName == "start_feynman_technique")
        #expect(offered(notebook: "nb-1", opens: true))
        #expect(!offered(notebook: nil, opens: true), "a chat in no Notebook has none to open it in")
        #expect(!offered(notebook: "nb-1", opens: false), "a manager with no pane, as on the iPhone, cannot open a chat")
    }

    @Test("A recent teach-back lists what was worked on, with the time and the chats, and asks for one explained")
    func recentOpening() {
        let one = TeachBack.recentOpeningMessage(
            lines: [.init(title: "Cristae remodeling", minutes: 40, chatTitles: [])],
            sinceYesterday: true
        )
        #expect(one.contains("“Cristae remodeling” (40 min)"))
        #expect(one.contains("since yesterday"))
        #expect(TeachBack.recentTopic(sourceTitles: ["Cristae remodeling"]) == "Feynman Technique: Cristae remodeling")

        let many = TeachBack.recentOpeningMessage(
            lines: [
                .init(title: "Mitonuclear match", minutes: 257, chatTitles: ["Free radical leak", "Joint fitness", "Idea card", "Biomarker"]),
                .init(title: "Urolithin A", minutes: 148, chatTitles: []),
            ],
            otherChats: ["mtDNA editing first"],
            sinceYesterday: false
        )
        #expect(many.contains("- “Mitonuclear match” (4 h 17 min; you asked: Free radical leak; Joint fitness; Idea card; and 1 more)"))
        #expect(many.contains("- “Urolithin A” (2 h 28 min)"))
        #expect(many.contains("You also asked about: mtDNA editing first."))
        #expect(many.contains("this past week"))
        #expect(many.contains("Pick one"))
        #expect(TeachBack.recentTopic(sourceTitles: ["A", "B"]) == "Feynman Technique: recent reading")
    }

    @Test("The recent list ranks by time and chats, not by what was opened last")
    func recentEngagementsRankByTime() {
        // 2026-11-24's shape: four hours on one paper and chats about it in
        // the day, then a book's front and back matter flicked through at
        // night and a page opened outside the library.
        func span(_ start: Int, _ end: Int, _ kind: DayActivityKind, _ id: String, _ title: String = "") -> DayActivity {
            DayActivity(dayPlanID: "2026-11-24", startMinute: start, endMinute: end, kind: kind, targetID: id, title: title)
        }
        let activities = [
            span(600, 857, .reading, "paper"),
            span(700, 702, .chat, "chat-leak", "Free Radical Leak"),
            span(710, 711, .chat, "chat-named", "mitonuclear match"),
            span(712, 716, .chat, "chat-fitness", "Joint Fitness"),
            span(720, 740, .chat, TeachBack.sessionID(), "Feynman Technique: Mitonuclear match"),
            span(703, 704, .chat, "chat-none", "mtDNA Editing First"),
            span(800, 803, .reading, "brief"),
            span(900, 901, .reading, "chatted-briefly"),
            span(905, 906, .chat, "chat-brief", "Clarifying Meaning"),
            span(1350, 1352, .reading, "index"),
            span(1352, 1353, .reading, "bibliography"),
            span(1353, 1354, .reading, "external-reader:pubmed.ncbi.nlm.nih.gov/1"),
            span(1355, 1425, .listening, "chapter"),
            span(1360, 1361, .reading, "hidden"),
        ]
        let titles = ["paper": "Mitonuclear match", "brief": "Glanced at", "chatted-briefly": "Asked about",
                      "index": "Index", "bibliography": "Bibliography", "chapter": "1 What is life?", "hidden": "Hidden"]
        let result = TeachBack.recentEngagements(
            activities: activities,
            chatSources: ["chat-leak": ["paper"], "chat-named": ["paper"], "chat-fitness": ["paper"], "chat-none": [], "chat-brief": ["chatted-briefly"]],
            isEligible: { $0 != "hidden" && !$0.hasPrefix("nope") },
            title: { titles[$0] ?? "" }
        )
        #expect(result.sources.map(\.sourceID) == ["paper", "chapter", "chatted-briefly"])
        #expect(result.sources.first?.minutes == 264, "chat time counts toward the source it discussed; a Feynman chat does not")
        #expect(result.sources.first?.chatTitles == ["Joint Fitness", "Free Radical Leak"], "busiest chat first; one named after the source is left out")
        #expect(result.otherChats == ["mtDNA Editing First"])
        #expect(TeachBack.isFrontOrBackMatter("List of illustrations"))
        #expect(TeachBack.isFrontOrBackMatter(" Copyright Page "))
        #expect(!TeachBack.isFrontOrBackMatter("Epilogue: From the deep"))
    }

    // MARK: - The morning routine (docs/morning-routine-design.md)

    @Test("The morning's pick: yesterday's unexplained first, then kept sources by dryness, then explained ones gone dry")
    func morningPickOrder() {
        var inputs = MorningPickRule.Inputs()
        inputs.recent = ["yesterday-a", "yesterday-explained", "yesterday-b"]
        inputs.due = [
            .init(sourceID: "kept-fading", daysOverdue: 0),
            .init(sourceID: "kept-dry", daysOverdue: 4),
            .init(sourceID: "explained-dry", daysOverdue: 2),
            .init(sourceID: "explained-fading", daysOverdue: 0),
        ]
        let then = Date(timeIntervalSinceReferenceDate: 0)
        inputs.explainedAt = ["yesterday-explained": then, "explained-dry": then, "explained-fading": then]
        let queue = MorningPickRule.queue(inputs)
        #expect(queue.map(\.sourceIDs) == [["yesterday-a"], ["yesterday-b"], ["kept-dry"], ["kept-fading"], ["explained-dry"]])
        #expect(queue.map(\.reason) == [.yesterday, .yesterday, .keptNotExplained, .keptNotExplained, .explainedDry])
    }

    @Test("A source passed over is not picked; the weekly connection leads with yesterday's source and an explained one")
    func morningPickSkipsAndConnects() {
        var inputs = MorningPickRule.Inputs()
        inputs.recent = ["a", "b"]
        inputs.skipped = ["a"]
        inputs.explainedAt = ["old": Date(timeIntervalSinceReferenceDate: 0)]
        inputs.connectionPartner = "old"
        let queue = MorningPickRule.queue(inputs)
        #expect(queue.first == MorningPick(sourceIDs: ["b", "old"], reason: .connection))
        #expect(!queue.contains { $0.sourceIDs.contains("a") })
        inputs.connectionPartner = "never-explained"
        #expect(MorningPickRule.queue(inputs).first?.reason == .yesterday, "a partner must already be explained")
    }

    @Test("record_explanation takes only the chat's sources and a known verdict")
    func explanationValidation() {
        let chat: Set<String> = ["s1", "s2"]
        guard case .success(let one) = TeachBack.Explanation.validate(arguments: ["source_ids": ["s1"], "verdict": "held"], chatSourceIDs: chat) else {
            Issue.record("a held explanation of one source is valid"); return
        }
        #expect(one.operation == .explain)
        #expect(one.verdict.score == 1)
        guard case .success(let two) = TeachBack.Explanation.validate(arguments: ["source_ids": ["s1", "s2", "s1"], "verdict": "partial"], chatSourceIDs: chat) else {
            Issue.record("two sources tie together"); return
        }
        #expect(two.sourceIDs == ["s1", "s2"])
        #expect(two.operation == .connect)
        if case .success = TeachBack.Explanation.validate(arguments: ["source_ids": ["elsewhere"], "verdict": "held"], chatSourceIDs: chat) {
            Issue.record("a source outside the chat is refused")
        }
        if case .success = TeachBack.Explanation.validate(arguments: ["source_ids": ["s1"], "verdict": "great"], chatSourceIDs: chat) {
            Issue.record("an unknown verdict is refused")
        }
    }

    @Test("A held explanation is what the pick reads as explained; partial is not, and a memory review grade is not")
    func explainedSourceDatesReadHeldOnly() throws {
        let store = try KnowledgeStore(inMemory: true)
        let sessionID = TeachBack.morningSessionID()
        try store.createReviewSession(id: sessionID, topic: "This morning", sourceIDs: [])
        let held = try store.addReviewExchange(sessionID: sessionID, question: "Explain it", answer: "It goes like this", evaluation: "Yes", score: nil, knowledgeNote: nil, sourceRefs: ["held-source"])
        try store.recordTeachBackExplanation(sessionID: sessionID, sequence: held, operation: .explain, score: TeachBack.Verdict.held.score)
        let partial = try store.addReviewExchange(sessionID: sessionID, question: "And this?", answer: "Not sure", evaluation: "Close", score: nil, knowledgeNote: nil, sourceRefs: ["partial-source"])
        try store.recordTeachBackExplanation(sessionID: sessionID, sequence: partial, operation: .explain, score: TeachBack.Verdict.partial.score)
        let explained = try store.explainedSourceDates()
        #expect(Set(explained.keys) == ["held-source"])
    }

    @Test("The reminder names the pick and the cards, or keeps the cards' words")
    func morningReminderWords() {
        #expect(CohortReviewNotifications.reminderWords(explain: "Cristae remodeling", cardCount: 12)
            == ("This morning", "Explain: Cristae remodeling. Then 12 cards."))
        #expect(CohortReviewNotifications.reminderWords(explain: "X", cardCount: 0).body == "Explain: X.")
        #expect(CohortReviewNotifications.reminderWords(explain: nil, cardCount: 5).title == "Today's review is ready")
    }

    @Test("A morning chat's id keeps the teach-back's tutor")
    func morningSessionKeepsTheTutor() {
        let id = TeachBack.morningSessionID()
        #expect(TeachBack.isSessionID(id))
        #expect(TeachBack.isMorningSessionID(id))
        #expect(!TeachBack.isMorningSessionID(TeachBack.sessionID()))
    }

    @Test("An explanation's grading is what both devices read as explained; a memory review grade is not")
    func explanationGradingIsShared() {
        #expect(MorningPickRule.explanationGrading(sourceCount: 1) == ("explain", "sound"))
        #expect(MorningPickRule.explanationGrading(sourceCount: 2).operation == "connect")
        #expect(MorningPickRule.isExplanation(operation: "explain", verdict: "sound", hasIdeaCoverage: false))
        #expect(!MorningPickRule.isExplanation(operation: "explain", verdict: "sound", hasIdeaCoverage: true), "a memory review's own grade")
        #expect(!MorningPickRule.isExplanation(operation: "recall", verdict: "sound", hasIdeaCoverage: false))
        #expect(TeachBack.explainedScore == MorningPickRule.explainedScore)
    }

    @Test("The voice Feynman Technique asks the learner to explain first and records each judged explanation")
    func voiceExplainInstructions() {
        let source = RealtimeVoiceSource(id: "s1", title: "Cristae remodeling", sourceType: "paper", byline: nil, text: "The paper's text.", reviewGuide: nil)
        let text = RealtimeVoiceTutor.instructions(for: source, opening: .explain)
        #expect(text.contains("Feynman Technique"))
        #expect(text.contains("never explain any part"))
        #expect(text.contains(RealtimeVoiceTutor.recordAnswerToolName))
        #expect(text.contains("this morning's explanation"))
        #expect(RealtimeVoiceTutor.kickoffMessage(for: .explain).contains("morning"))
    }
}

