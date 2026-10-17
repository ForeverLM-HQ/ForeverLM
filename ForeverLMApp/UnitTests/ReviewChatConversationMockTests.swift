import Foundation
import Testing
@testable import ForeverLM

@Suite("iOS mock conversation fixtures")
@MainActor
struct ReviewChatConversationMockTests {

    @Test("Learner says review request -> first review starter is a compact checklist prompt")
    func learnerReviewRequestGeneratesReviewStarter() throws {
        let payload = ReviewSessionManager.initialPayloadForTesting(
            mode: .review,
            topic: "Memory systems",
            hasAttachedSource: true,
            sourceContext: "Active recall and spacing effects improve long-term retention."
        )

        let first = try #require(payload.messages.first)
        #expect(first.role == "user")
        #expect(first.content == "Use the attached source text to start the review. Show a compact checklist of the core concepts you plan to review, then ask one deep question about the first concept.")
        #expect(payload.system.contains("review tutor"))
    }

    @Test("Learner says summarize request -> first model prompt is summary-oriented")
    func learnerSummaryRequestGeneratesSummaryStarter() throws {
        let payload = ReviewSessionManager.initialPayloadForTesting(
            mode: .summarize,
            topic: "Memory systems",
            hasAttachedSource: true,
            sourceContext: "Active recall and spacing effects improve long-term retention."
        )

        let first = try #require(payload.messages.first)
        #expect(first.role == "user")
        #expect(first.content == "Use the attached source text to summarize the source material. Focus on the main ideas, important definitions, mechanisms, claims, caveats, and what I should remember.")
        #expect(payload.system.contains("source summarizer"))
    }

    @Test("Mock tutor response with retrieval tool call is split into visible text + hidden action")
    func tutorToolCallResponseIsDisplayedAndParsed() {
        let rawResponse = ##"Can you focus on chapter 2 first?<flm_tool_call>{"tool":"retrieve_sources","source_ids":["source-17"],"query":"space repetition","reason":"Need focused passages","max_sources":1}</flm_tool_call>"##

        let visible = ReviewSessionManager.displayableMessageContent(role: .assistant, content: rawResponse)
        let retrievalRequested = ReviewSessionManager.retrievalToolCallForTesting(rawResponse)

        #expect(visible == "Can you focus on chapter 2 first?")
        #expect(retrievalRequested == true)
        #expect(ReviewSessionManager.retrievalToolCallWantsFullTextForTesting(rawResponse) == false)
    }

    @Test("Notebook notes action and transcript flow stays user-visible for iOS review rounds")
    func notebookNotesToolCallAndConversationFlowRoundTrip() {
        let visibleTurn = ReviewSessionManager.displayableMessageContent(
            role: .assistant,
            content: ##"Updated note structure prepared.<flm_tool_call>{"tool":"replace_synthesis","markdown":"# Notes\n\nUpdated structure."}</flm_tool_call>"##
        )

        let transcriptPayload = ReviewSessionManager.resumedPayloadForTesting(
            messages: [
                (role: "assistant", content: "Start here. Why does retrieval practice matter?"),
                (role: "user", content: "Because it forces recall from memory."),
                (role: "assistant", content: visibleTurn ?? ""),
                (role: "user", content: "Please make that clearer for spaced repetition.")
            ],
            systemPrompt: "Tutor prompt.\n\nAttached source text currently available:\n\nRetrieval practice strengthens long-term memory." )

        #expect(visibleTurn == "Updated note structure prepared.")
        #expect(transcriptPayload.messages.map { $0.role } == ["user", "assistant", "user", "assistant", "user"])
        #expect(transcriptPayload.messages.first?.content.contains("Continue this existing ForeverLM chat from the saved transcript. The assistant's previous message follows.") == true)
        #expect(transcriptPayload.messages[1].content == "Start here. Why does retrieval practice matter?")
        #expect(transcriptPayload.messages[3].content == visibleTurn)
        #expect(transcriptPayload.messages.last?.content == "Please make that clearer for spaced repetition.")
    }

    @Test("Copy conversation preserves Markdown and compact tool activity")
    func copiedConversationIsReadableAndComplete() {
        let transcript = ReviewSessionManager.copiedConversationText(from: [
            ReviewSessionManager.Message(role: .user, content: "How does this work?"),
            ReviewSessionManager.Message(
                role: .tool,
                content: "internal operation",
                toolActivity: .init(
                    toolName: "search_sources_semantic",
                    detail: "retrieval practice",
                    state: .succeeded,
                    resultPreview: "This expanded payload must stay out of the clipboard."
                )
            ),
            ReviewSessionManager.Message(
                role: .assistant,
                content: "It preserves **Markdown**.\n\n```swift\nlet answer = 42\n```"
            ),
            ReviewSessionManager.Message(role: .assistant, content: "   ")
        ])

        #expect(transcript == """
        You:
        How does this work?

        ForeverLM:
        Searched sources — retrieval practice

        It preserves **Markdown**.

        ```swift
        let answer = 42
        ```
        """)
        #expect(!transcript.contains("internal operation"))
        #expect(!transcript.contains("expanded payload"))
    }

    @Test("Copy conversation from a saved chat reads every turn in order, once")
    func copiedConversationFromSavedExchanges() {
        func exchange(_ n: Int, _ question: String, _ answer: String?, _ evaluation: String?) -> ReviewExchangeRecord {
            ReviewExchangeRecord(
                id: "exchange-\(n)",
                sessionID: "session-1",
                sequenceNumber: n,
                question: question,
                userAnswer: answer,
                evaluation: evaluation,
                score: nil,
                sourceRefs: [],
                knowledgeNote: nil,
                answeredAt: nil,
                contextContent: nil
            )
        }
        // Stored out of order, and the second question is the first reply
        // stored again, as a chat resumed from disk keeps it.
        let transcript = ReviewSessionManager.copiedConversationText(fromStored: [
            exchange(2, "It is a **kinase**.", "Why?", "Because it adds phosphate."),
            exchange(1, "What is AMPK?", "An energy sensor.", "It is a **kinase**.")
        ])

        #expect(transcript == """
        ForeverLM:
        What is AMPK?

        You:
        An energy sensor.

        ForeverLM:
        It is a **kinase**.

        You:
        Why?

        ForeverLM:
        Because it adds phosphate.
        """)
        #expect(ReviewSessionManager.copiedConversationText(fromStored: []).isEmpty)
    }

    @Test("Copy answer joins text fragments around collapsed source activity")
    func copiedAnswerIncludesCollapsedActivityWithoutExpansion() {
        let answer = ReviewSessionManager.copiedAnswerText(from: [
            .init(role: .assistant, content: "I’ll inspect the paper."),
            .init(
                role: .tool,
                content: "",
                toolActivity: .init(
                    toolName: "get_source_content",
                    detail: "Mechanism of age-related accumulation",
                    state: .succeeded,
                    resultPreview: "Full source text"
                )
            ),
            .init(role: .assistant, content: "Here is the grounded answer.")
        ])

        #expect(answer == """
        I’ll inspect the paper.

        Read source — Mechanism of age-related accumulation

        Here is the grounded answer.
        """)
        #expect(!answer.contains("Full source text"))
    }
}
