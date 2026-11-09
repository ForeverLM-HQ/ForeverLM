import Foundation
import Testing
@testable import ForeverLM

/// Memory Check by Voice: the review's turns rebuilt from the spoken
/// conversation (`RealtimeVoiceMemoryCheckLedger`), and the brief and tools
/// the realtime model gets (`RealtimeVoiceMemoryCheck`).
@Suite("Memory Check by Voice")
struct RealtimeVoiceMemoryCheckTests {
    private func tutor(_ text: String) -> RealtimeVoiceTurn {
        RealtimeVoiceTurn(id: UUID().uuidString, role: .tutor, text: text)
    }

    private func learner() -> RealtimeVoiceTurn {
        RealtimeVoiceTurn(id: UUID().uuidString, role: .learner, text: RealtimeVoiceTurn.spokenMark)
    }

    private let grade = MemoryContourGrade(
        sourceID: "topic-1",
        coverage: [MemoryIdeaCoverage(ideaID: "idea-a", status: .produced)],
        score: 1,
        verdict: .sound,
        operation: .recall,
        evaluation: nil
    )

    @Test("Card talk before the review starts is not the review's")
    func cardsStayOutOfTheReview() {
        var ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: false)
        var transcript = [tutor("You have two cards. First: what is ATP?"), learner(), tutor("Right. That's the cards.")]
        ledger.startReview(at: transcript.count)
        ledger.turn(to: "topic-1", at: transcript.count)
        transcript += [tutor("Today is about mitochondria. What do you now understand about them?"), learner()]
        let writes = ledger.close(at: transcript.count, transcript: transcript)
        #expect(writes == [.opening(question: "<flm_source_turn id=\"topic-1\"/>\n\nToday is about mitochondria. What do you now understand about them?")])
    }

    @Test("A graded answer is saved with what was said after it, at the next turn")
    func turnSavedOneStepBehind() {
        var ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: true)
        var transcript = [tutor("What do you now understand about mitochondria?"), learner()]
        ledger.startReview(at: 0)
        // The prepared opening was asked again: nothing to save before the first answer.
        #expect(ledger.close(at: transcript.count, transcript: transcript).isEmpty)
        ledger.begin(.init(answer: RealtimeVoiceMemoryCheck.savedAnswer(learnerSaid: "They make ATP."), grade: grade, steer: nil))
        transcript += [tutor("That came back. Go deeper or move on?"), learner()]
        let writes = ledger.close(at: transcript.count, transcript: transcript)
        #expect(writes == [.turn(answer: "(spoken) They make ATP.", reply: "That came back. Go deeper or move on?", grade: grade, steer: nil)])
    }

    @Test("A steer is its own turn, and the call's end saves the last one")
    func steerAndFinish() {
        var ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: true)
        var transcript = [tutor("Go deeper or move on?"), learner()]
        ledger.startReview(at: 0)
        _ = ledger.close(at: transcript.count, transcript: transcript)
        ledger.begin(.init(answer: MemoryReviewTutoring.steerMessage(.deeper), grade: nil, steer: .deeper))
        transcript += [tutor("Why does the proton gradient matter?"), learner(), tutor("Goodbye.")]
        let writes = ledger.finish(transcript: transcript)
        #expect(writes == [.turn(answer: "Go deeper.", reply: "Why does the proton gradient matter?\n\nGoodbye.", grade: nil, steer: .deeper)])
        #expect(ledger.finish(transcript: transcript).isEmpty)
    }

    @Test("A call that ends on a grade still saves it, saying where it stopped")
    func endsOnAGrade() {
        var ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: true)
        let transcript = [tutor("What do you understand about it?"), learner()]
        ledger.startReview(at: 0)
        _ = ledger.close(at: transcript.count, transcript: transcript)
        ledger.begin(.init(answer: "(spoken) Not much.", grade: grade, steer: nil))
        #expect(ledger.finish(transcript: transcript) == [
            .turn(answer: "(spoken) Not much.", reply: RealtimeVoiceMemoryCheckLedger.stoppedHere, grade: grade, steer: nil),
        ])
    }

    @Test("A cards-only call saves nothing on the review")
    func cardsOnly() {
        var ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: false)
        #expect(ledger.finish(transcript: [tutor("Two cards. Done.")]).isEmpty)
    }

    @Test("A heading with nothing after it heads nothing")
    func trailingHeadingDropped() {
        var ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: true)
        let transcript = [tutor("That came back.")]
        ledger.startReview(at: 0)
        ledger.turn(to: "topic-2", at: 1)
        #expect(ledger.text(from: 0, to: 1, transcript: transcript) == "That came back.")
    }

    @Test("The graders ask for learner_said beside their own fields")
    func graderCarriesLearnerSaid() {
        for byTopic in [false, true] {
            let tool = RealtimeVoiceMemoryCheck.gradeTool(byTopic: byTopic)
            let parameters = tool["parameters"] as? [String: Any]
            let properties = parameters?["properties"] as? [String: Any]
            let required = parameters?["required"] as? [String] ?? []
            #expect(tool["type"] as? String == "function")
            #expect(properties?[RealtimeVoiceMemoryCheck.learnerSaidField] != nil)
            #expect(required.contains(RealtimeVoiceMemoryCheck.learnerSaidField))
            #expect(required.contains(byTopic ? "topic_id" : "source_id"))
        }
    }

    @Test("The brief carries the cards, the voice rules and the typed review's prompt")
    func instructions() {
        let card = RealtimeVoiceCardReview.Card(id: "card-1", question: "What is ATP?", answer: "The cell's energy currency.", source: nil)
        let text = RealtimeVoiceMemoryCheck.instructions(
            cards: [card],
            dueCards: 1,
            review: .init(briefing: "TOPICS, in order", history: [(role: "assistant", content: "<flm_source_turn id=\"topic-1\"/>\n\nWhat do you understand?")], byTopic: true),
            localClockDescription: "Monday"
        )
        #expect(text.contains("card_id: card-1"))
        #expect(text.contains(RealtimeVoiceMemoryCheck.startReviewToolName))
        #expect(text.contains("TOPICS, in order"))
        // The prepared opening is handed over to be said, without its tag.
        #expect(text.contains("open with it in your"))
        #expect(!text.contains("THE REVIEW SO FAR"))
        #expect(text.contains("What do you understand?"))
    }
}
