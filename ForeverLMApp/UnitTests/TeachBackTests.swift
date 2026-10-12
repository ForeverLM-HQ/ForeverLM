import Foundation
import Testing
@testable import ForeverLM

/// The Studio's Feynman Technique (`TeachBack`): a chat on one paper that
/// opens by asking the learner to explain it, whose tutor probes rather than
/// explains, and which keeps that tutor when it is reopened because its id
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
        #expect(TeachBack.topic(sourceTitle: "Cristae remodelling") == "Feynman Technique: Cristae remodelling")
    }

    @Test("The opening is written ahead: it names the paper and asks for an explanation from memory")
    func scriptedOpening() {
        let opening = TeachBack.openingMessage(sourceTitle: "Cristae remodelling")
        #expect(opening == "Explain \u{201C}Cristae remodelling\u{201D} to me in your own words, as you would to a bright friend who hasn't read it. Don't look back at it first: what question does it ask, what did it find, and how does it know? Start wherever you like, and I'll ask about whatever I can't follow yet.")
        #expect(!opening.contains("\u{2014}"), "Web Studio serves the same words, and its files carry no em dash")
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

    @Test("The tutor's rules: learner-led, one question at the biggest gap, the passage after a failed retry, then the simplest version and the limits, never ending on its own")
    func tutorPromptRules() {
        let prompt = Prompts.teachBackTutor
        for rule in [
            "Feynman Technique",
            "in their own words, from memory",
            "never do it for them",
            "never summarize it, quote it at length, or explain any part of it before the learner has tried",
            "Never show a plan",
            "exactly one question, aimed at the biggest gap",
            "a technical term used without saying what it means",
            "a claim with no evidence behind it",
            "do not correct it. Ask a question that lets them notice the problem themselves",
            "If their second try still misses it, point them to the place in the paper that settles it",
            "show it in the Reader beside the chat",
            "ask for the simplest version",
            "probe its assumptions and limits",
            "Never name a tool",
            "Never decide that the session is over",
        ] {
            #expect(prompt.contains(rule), "the prompt lacks: \(rule)")
        }
        // Web Studio sends these words byte for byte from its own copy.
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
            topic: TeachBack.topic(sourceTitle: "Cristae remodelling"),
            sourceIDs: [],
            chatKind: .review
        )
        let manager = ReviewSessionManager(storage: storage)
        let opening = TeachBack.openingMessage(sourceTitle: "Cristae remodelling")
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
}
