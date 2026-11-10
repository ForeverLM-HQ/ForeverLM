import Foundation
import Testing
@testable import ForeverLM

@Suite("Driving source answer planner")
struct DrivingSourceAnswerPlannerTests {

    @Test("Preserves source order without keyword passage scoring")
    func preservesSourceOrder() {
        let source = """
        The paper opens with a general history of cellular aging and several unrelated examples.

        Partial reprogramming resets epigenetic marks without forcing a complete return to pluripotency. The source emphasizes that short pulses can make epigenetic clocks look younger while preserving cell identity.

        A later section discusses microscopy methods and plate-reader settings that are not important for this question.

        Safety concerns include teratoma risk, loss of identity, and the need to control reprogramming duration carefully.
        """

        let prompt = DrivingSourceAnswerPlanner.makePrompt(
            DrivingSourceAnswerRequest(
                sourceTitle: "Reprogramming",
                sourceText: source,
                question: "What does it say about epigenetic clocks in partial reprogramming?",
                recentMessages: []
            )
        )

        #expect(prompt.passages.map(\.text) == [source])
    }

    @Test("Builds a prompt bounded for low-latency driving answers")
    func buildsBoundedPrompt() {
        let repeated = Array(repeating: "Noise paragraph about unrelated background.", count: 900)
            .joined(separator: "\n\n")
        let source = repeated + "\n\nRetrieval practice improves retention by forcing recall and exposing gaps."
        let longHistory = Array(0..<12).map { index in
            MobileSourceChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: String(repeating: "previous long turn ", count: 80)
            )
        }

        let prompt = DrivingSourceAnswerPlanner.makePrompt(
            DrivingSourceAnswerRequest(
                sourceTitle: "Memory Systems",
                sourceText: source,
                question: "How does retrieval practice improve retention?",
                recentMessages: longHistory
            )
        )

        #expect(prompt.contextCharacterCount <= DrivingSourceAnswerPlanner.maxSourceCharacters)
        #expect(prompt.messages.count <= DrivingSourceAnswerPlanner.maxRecentMessages + 1)
        #expect(prompt.messages.last?.content.contains("Retrieval practice improves retention") == true)
        #expect(prompt.system.contains("low-latency spoken answers"))
    }

    @Test("Compacts spoken answers for Siri or in-app speech")
    func compactsSpokenAnswer() {
        let raw = """
        # Answer
        \(String(repeating: "The source says partial reprogramming may reset epigenetic marks while preserving identity. ", count: 30))
        <flm_tool_call>{"tool":"retrieve_sources"}</flm_tool_call>
        """

        let spoken = DrivingSourceAnswerPlanner.spokenAnswer(from: raw)

        #expect(spoken.count <= DrivingSourceAnswerPlanner.maxSpokenAnswerCharacters)
        #expect(!spoken.contains("<flm_tool_call>"))
        #expect(!spoken.contains("#"))
    }

}
