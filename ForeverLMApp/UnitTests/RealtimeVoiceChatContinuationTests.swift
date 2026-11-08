import Foundation
import Testing
@testable import ForeverLM

@Suite("A chat carried on by voice")
struct RealtimeVoiceChatContinuationTests {
    private typealias Continuation = RealtimeVoiceChatContinuation

    @Test("The voice model is told the chat's turns in order, under its title")
    func sectionKeepsTheChatInOrder() {
        let chat = Continuation.Chat(
            sessionID: "chat-1",
            title: "Cristae and ATP synthase",
            turns: [
                .init(role: .learner, text: "Why do cristae fold?"),
                .init(role: .assistant, text: "To pack more membrane for ATP synthase dimers."),
                .init(role: .learner, text: "   "),
            ]
        )
        let section = Continuation.section(for: chat)
        #expect(section.title == "This chat so far")
        #expect(section.text.contains("\u{201C}Cristae and ATP synthase\u{201D}"))
        let learner = section.text.range(of: "Learner: Why do cristae fold?")
        let answer = section.text.range(of: "ForeverLM: To pack more membrane")
        #expect(learner != nil && answer != nil)
        if let learner, let answer { #expect(learner.lowerBound < answer.lowerBound) }
        #expect(!section.text.contains("Learner:    "), "an empty turn is left out")
    }

    @Test("A long chat keeps its latest turns and says the earlier ones are left out")
    func longChatKeepsTheTail() {
        let old = String(repeating: "old words ", count: 2_000)
        let new = String(repeating: "new words ", count: 2_000)
        let chat = Continuation.Chat(
            sessionID: "chat-2",
            title: "",
            turns: [
                .init(role: .learner, text: old),
                .init(role: .assistant, text: old),
                .init(role: .learner, text: new),
                .init(role: .assistant, text: new),
            ]
        )
        let text = Continuation.section(for: chat).text
        #expect(text.count <= Continuation.transcriptBudget + 200)
        #expect(text.contains("earlier turns of the chat are left out"))
        #expect(text.hasSuffix(new.trimmingCharacters(in: .whitespaces)))
    }

    @Test("An empty chat says so, and the opening greets instead of recapping")
    func emptyChat() {
        let chat = Continuation.Chat(sessionID: "chat-3", title: "", turns: [])
        #expect(Continuation.section(for: chat).text == "The chat has no messages yet.")
        #expect(Continuation.kickoff(hasMessages: false).contains("empty chat"))
        #expect(Continuation.kickoff(hasMessages: true).contains("where the chat left off"))
    }

    @Test("The chat keeps what ForeverLM said, a mark where the learner spoke, and a cut-off reply")
    func noteKeepsForeverLMsSide() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var interrupted = RealtimeVoiceTurn(id: "t2", role: .tutor, text: "The inner membrane folds so")
        interrupted.wasInterrupted = true
        let turns = [
            RealtimeVoiceTurn(id: "t1", role: .tutor, text: "We left off at cristae."),
            RealtimeVoiceTurn(id: "l1", role: .learner, text: RealtimeVoiceTurn.spokenMark),
            interrupted,
            RealtimeVoiceTurn(id: "l2", role: .learner, text: RealtimeVoiceTurn.spokenMark),
        ]
        let note = try #require(Continuation.note(turns: turns, startedAt: start, endedAt: start.addingTimeInterval(190)))
        let parts = note.components(separatedBy: "\n\n")
        #expect(parts.first?.hasPrefix("**Voice conversation** \u{00B7} 3 min") == true)
        #expect(parts.dropFirst().map { $0 } == [
            "We left off at cristae.",
            "*You spoke.*",
            "The inner membrane folds so *(cut off)*",
            "*You spoke.*",
        ])
    }

    @Test("A call in which ForeverLM said nothing adds nothing to the chat")
    func silentCallAddsNothing() {
        let now = Date()
        let turns = [RealtimeVoiceTurn(id: "l1", role: .learner, text: RealtimeVoiceTurn.spokenMark)]
        #expect(Continuation.note(turns: turns, startedAt: now, endedAt: now) == nil)
    }
}
