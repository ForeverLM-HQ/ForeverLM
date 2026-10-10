import Foundation
import Testing
@testable import ForeverLM

/// An exchange lifted out of a memory review into an ordinary chat: what the
/// new chat is told, and what it is not.
@Suite("Memory review chat handoff")
struct MemoryReviewChatHandoffTests {
    private static let ideas: [SourceIdea] = [
        idea(id: "idea-regen", statement: "Axolotls regrow limbs without forming tumours."),
        idea(id: "idea-neoteny", statement: "They keep larval traits for life."),
        idea(id: "idea-genome", statement: "Their genome is ten times the human one."),
    ]

    private static func idea(id: String, statement: String) -> SourceIdea {
        SourceIdea(id: id, sourceID: "src-axolotl", statement: statement, recallNote: "", contentHash: "h", sortIndex: 0)
    }

    private static func exchange(
        userAnswer: String? = "They regrow limbs.",
        evaluation: String? = "Regeneration came back; the cancer resistance did not.",
        sourceRefs: [String] = ["src-axolotl"],
        ideaCoverage: String? = """
        [{"idea_id":"idea-regen","status":"produced"},
         {"idea_id":"idea-neoteny","status":"partial"},
         {"idea_id":"idea-genome","status":"missing"},
         {"idea_id":"idea-retired","status":"missing"}]
        """
    ) -> ReviewExchangeRecord {
        ReviewExchangeRecord(
            id: "ex-1",
            sessionID: "memory-2026-09-07",
            sequenceNumber: 1,
            question: "What was “Are Axolotls Immortal?” mainly about?",
            userAnswer: userAnswer,
            evaluation: evaluation,
            score: 0.5,
            sourceRefs: sourceRefs,
            knowledgeNote: nil,
            answeredAt: Date(),
            contextContent: nil,
            ideaCoverage: ideaCoverage
        )
    }

    @Test("The handoff carries the three turns, the missed ideas by statement, and the exchange's sources")
    func carriesExchange() {
        let handoff = MemoryReviewChatHandoff(
            exchange: Self.exchange(),
            reviewTitle: "7 September 2026",
            ideas: Self.ideas,
            fallbackSourceIDs: ["src-other"]
        )
        #expect(handoff.reviewSessionID == "memory-2026-09-07")
        #expect(handoff.reviewTitle == "7 September 2026")
        #expect(handoff.sourceIDs == ["src-axolotl"])
        #expect(handoff.headline == "What was “Are Axolotls Immortal?” mainly about?")
        #expect(handoff.transcript == """
        Tutor: What was “Are Axolotls Immortal?” mainly about?
        Learner: They regrow limbs.
        Grader: Regeneration came back; the cancer resistance did not.
        """)
        // Produced ideas are not a gap; a retired id the grade still names has
        // no statement to give and is dropped rather than shown as an id.
        #expect(handoff.missedIdeas == [
            .init(statement: "They keep larval traits for life.", status: .partial),
            .init(statement: "Their genome is ten times the human one.", status: .missing),
        ])
    }

    @Test("The model reads the exchange, the gaps, and the instruction not to grade")
    func contextualContentFramesTheChat() {
        let handoff = MemoryReviewChatHandoff(
            exchange: Self.exchange(),
            reviewTitle: "7 September 2026",
            ideas: Self.ideas,
            fallbackSourceIDs: []
        )
        let content = handoff.contextualContent
        #expect(content.hasPrefix("From the memory review \"7 September 2026\":\nTutor: "))
        #expect(content.contains("Ideas the grader did not hear back in full:\n- They keep larval traits for life. (partly recalled)\n- Their genome is ten times the human one. (not recalled)"))
        #expect(content.contains("Do not grade them"))
        #expect(content.contains("do not continue the review"))
        #expect(!content.contains("idea-"))
    }

    @Test("An unanswered question is one line, and no gaps section without a grade")
    func unansweredQuestion() {
        let handoff = MemoryReviewChatHandoff(
            exchange: Self.exchange(userAnswer: nil, evaluation: nil, ideaCoverage: nil),
            reviewTitle: "7 September 2026",
            ideas: Self.ideas,
            fallbackSourceIDs: []
        )
        #expect(handoff.transcript == "Tutor: What was “Are Axolotls Immortal?” mainly about?")
        #expect(handoff.missedIdeas.isEmpty)
        #expect(!handoff.contextualContent.contains("Ideas the grader"))
    }

    @Test("The chip reads the opening message by its question, not its briefing")
    func headlineIsTheQuestionParagraph() {
        var exchange = Self.exchange()
        exchange = ReviewExchangeRecord(
            id: exchange.id, sessionID: exchange.sessionID, sequenceNumber: 1,
            question: "Today covers your mitochondrial-aging materials.\n\nIn your own words, what was this source about?",
            userAnswer: nil, evaluation: nil, score: nil, sourceRefs: [], knowledgeNote: nil,
            answeredAt: nil, contextContent: nil
        )
        let handoff = MemoryReviewChatHandoff(exchange: exchange, reviewTitle: "7 September 2026", ideas: [], fallbackSourceIDs: [])
        #expect(handoff.headline == "In your own words, what was this source about?")
        #expect(handoff.transcript.hasPrefix("Tutor: Today covers your mitochondrial-aging materials.\n\nIn your own words"))
    }

    @Test("An exchange without sources of its own takes the review's")
    func fallsBackToReviewSources() {
        let handoff = MemoryReviewChatHandoff(
            exchange: Self.exchange(sourceRefs: []),
            reviewTitle: "7 September 2026",
            ideas: [],
            fallbackSourceIDs: ["src-a", "src-b"]
        )
        #expect(handoff.sourceIDs == ["src-a", "src-b"])
    }

    @Test("A legacy 'Memory · ' title reads as the review's date, like the rail row")
    func legacyTitle() {
        let handoff = MemoryReviewChatHandoff(
            exchange: Self.exchange(),
            reviewTitle: "Memory · 7 Sep",
            ideas: [],
            fallbackSourceIDs: []
        )
        let expected = MemoryReviewSession.title(for: MemoryReviewSession.date(fromSessionID: "memory-2026-09-07")!)
        #expect(handoff.reviewTitle == expected)
    }

    @Test("Malformed coverage JSON contributes no gaps rather than failing the handoff")
    func malformedCoverage() {
        #expect(MemoryReviewChatHandoff.missedIdeas(coverageJSON: "not json", ideas: Self.ideas).isEmpty)
        #expect(MemoryReviewChatHandoff.missedIdeas(coverageJSON: nil, ideas: Self.ideas).isEmpty)
    }

    @Test("As a selection request: the chip shows the question, the model gets the exchange, the chat gets the sources")
    func asSelectionRequest() {
        let handoff = MemoryReviewChatHandoff(
            exchange: Self.exchange(),
            reviewTitle: "7 September 2026",
            ideas: Self.ideas,
            fallbackSourceIDs: []
        )
        let request = ReaderSelectionExplanationRequest(reviewHandoff: handoff)
        #expect(request.selectedText == handoff.headline)
        #expect(request.sourceIDs == ["src-axolotl"])
        #expect(request.contextTitle == "Memory review: 7 September 2026")
        #expect(request.reviewHandoff == handoff)
        // Not a passage: the exchange block replaces the "Selected passage"
        // shape, and there is no doc to anchor a link to.
        #expect(request.contextualContent(fallbackTitle: "Are Axolotls Immortal?") == handoff.contextualContent)
        #expect(request.docAnchor == nil)
    }
}
