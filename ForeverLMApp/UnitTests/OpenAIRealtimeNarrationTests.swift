import Foundation
import Testing
@testable import ForeverLM

/// Listen on OpenAI runs on the learner's own OpenAI key: a Realtime session
/// reads each section aloud, and a reading that strays from the text is refused
/// so the speech clients read the section again in halves
/// (`OpenAIRealtimeNarration`). Ported from the proxy's narration tests.
@Suite("OpenAI narration")
struct OpenAIRealtimeNarrationTests {
    typealias Narration = OpenAIRealtimeNarration

    private let paragraph = "The mitochondrion is the organelle that produces most of the cell's chemical energy. It has its own small genome, inherited from the mother, and its inner membrane folds into cristae that hold the respiratory complexes. In 2026 researchers measured membrane potential in living cells and found that it varied between neighbouring organelles."

    private func faithful(_ text: String, _ transcript: String) -> Bool {
        Narration.isFaithful(Narration.fidelity(text: text, transcript: transcript))
    }

    @Test("A word-for-word reading is faithful, and a number said as words does not count as added")
    func verbatim() {
        #expect(faithful(paragraph, paragraph))
        #expect(faithful(paragraph, paragraph.replacingOccurrences(of: "In 2026", with: "In twenty twenty six")))
        #expect(faithful("Figure 3 shows 45%.", "Figure three shows forty five percent."))
    }

    @Test("A skipped paragraph, a summary and a greeting are refused")
    func strays() {
        #expect(!faithful(paragraph, "The mitochondrion is the organelle that produces most of the cell's chemical energy."))
        #expect(!faithful(paragraph, "Sure! Here is a summary: mitochondria make energy and have their own genome. Let me know if you want more."))
        #expect(!faithful(paragraph, "Hello there. " + paragraph + " Anything else I can help with today, my friend, about these organelles?"))
    }

    @Test("Empty text and accents compare sensibly")
    func edges() {
        let empty = Narration.fidelity(text: "", transcript: "")
        #expect(empty.covered == 1 && empty.added == 0)
        #expect(Narration.fidelity(text: "Café déjà vu", transcript: "cafe deja vu").covered == 1)
    }

    @Test("The session opens with the narrator's instructions, the text, and a response request")
    func clientEvents() throws {
        let events = Narration.clientEvents(voice: "marin", text: "Read this.")
        #expect(events.map { $0["type"] as? String } == ["session.update", "conversation.item.create", "response.create"])
        let session = try #require(events[0]["session"] as? [String: Any])
        #expect(session["instructions"] as? String == Narration.instructions)
        let item = try #require(events[1]["item"] as? [String: Any])
        let content = try #require((item["content"] as? [[String: Any]])?.first)
        #expect(content["text"] as? String == "Read this.")
    }

    @Test("Without an own OpenAI key the answer is a 401 naming the key, and nothing goes to the network")
    func noKey() async throws {
        ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = nil }
        var request = URLRequest(url: Narration.requestURL)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-realtime-2.1-mini", "input": "Hello.", "voice": "marin",
        ])
        let (data, response) = try await URLSession.shared.speechData(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect(ManagedAI.serviceError(from: data)?.code == "no_openai_key")
        #expect(CloudArticleTTS.isAccountFailure(ManagedAI.ServiceError(code: "no_openai_key", message: "")))
    }

    @Test("An unknown voice is a 400, not a session")
    func unknownVoice() async throws {
        ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = .some("sk-test")
        defer { ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = nil }
        var request = URLRequest(url: Narration.requestURL)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-realtime-2.1-mini", "input": "Hello.", "voice": "nope",
        ])
        let (_, response) = try await URLSession.shared.speechData(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }
}
