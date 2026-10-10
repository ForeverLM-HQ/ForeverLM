import Foundation
import Testing
@testable import ForeverLM

/// When an Exchange is sent, and how a long one fits its record (docs/cloudkit-schema-design.md
/// §3.5.14, §3.2 rule 8, WP10): a turn is sent once it holds anything, what it gains later follows as
/// an update, only a truly empty turn stays local, and a 300 KiB pasted question spills into a
/// satellite and round-trips.
@Suite("Exchange completion")
struct ExchangeCompletionTests {
    typealias F = ChatSyncFixture
    typealias N = NotebookSyncFixture

    @Test("A tutor prompt is sent once written; the learner's answer and then the reply follow as updates of what changed")
    func promptIsSentAndGrows() throws {
        let (root, store) = try N.makeStore("exchange-prompt")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try F.addChat(store, "chat-1", kind: .review)
        let sequence = try store.addReviewPrompt(sessionID: "chat-1", question: "What does Complex I pump?", sourceRefs: [])
        let exchangeID = try F.exchangeID(store, chat: "chat-1", sequence: sequence)
        let asked = try #require(N.savedFields(try N.pending(store)["Exchange:\(exchangeID)"]), "a prompt holds the tutor's text: every device shows it")
        #expect(asked["question"] == .string("What does Complex I pump?"))
        #expect((asked["userAnswer"] ?? .null) == .null && (asked["evaluation"] ?? .null) == .null)
        try F.sendAll(store)
        let held = try #require(try N.held(store, .exchange, exchangeID))

        try store.recordPendingReviewUserMessage(sessionID: "chat-1", answer: "Protons", sourceRefs: [], answeredAt: Date(timeIntervalSinceReferenceDate: 21_000))
        let answer = try #require(try N.pending(store)["Exchange:\(exchangeID)"], "the answer goes onto the Exchange already sent")
        let answered = try #require(N.savedFields(answer))
        #expect(answered["question"] == .string("What does Complex I pump?") && answered["userAnswer"] == .string("Protons"))
        #expect(answered["createdAt"] == held.fields["createdAt"] && answered["seq"] == held.fields["seq"], "seq and createdAt stand once held")
        #expect(!answer.stamps.keys.contains { $0.field == "question" }, "only what changed is sent")
        try F.sendAll(store)

        try store.answerPendingReviewExchange(sessionID: "chat-1", sequence: sequence, answer: "Protons", evaluation: "Right.", score: 1,
                                              knowledgeNote: nil, sourceRefs: [])
        let reply = try #require(try N.pending(store)["Exchange:\(exchangeID)"])
        #expect(N.savedFields(reply)?["evaluation"] == .string("Right."))
        #expect(!reply.stamps.keys.contains { $0.field == "question" || $0.field == "userAnswer" }, "only what changed is sent")
    }

    @Test("An imported turn with a question and no answer is sent; a truly empty turn stays local until it holds something")
    func emptyTurnStaysLocal() throws {
        let (root, store) = try N.makeStore("exchange-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try store.importReviewChatSession(
            id: "chat-1", title: "Imported", turns: [
                ReviewChatTurn(question: "Q1", answer: "A1", evaluation: nil),
                ReviewChatTurn(question: "Q2", answer: nil, evaluation: nil),
            ], sourceIDs: [], summary: nil, overallScore: nil, modelProvider: nil, modelID: nil, chatKind: .chat, marksReviewed: true
        )
        #expect(try N.pending(store).keys.filter { $0.hasPrefix("Exchange:") }.count == 2, "the assistant's last turn of an ended chat is sent too")
        try F.sendAll(store)

        try store.execute("""
            INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at)
            VALUES ('ex-empty', 'chat-1', 3, ' ', NULL, NULL, NULL, '[]', NULL, NULL)
        """)
        #expect(try N.pending(store)["Exchange:ex-empty"] == nil, "a turn with no question, answer or reply has nothing to show")
        try F.sendAll(store)
        #expect(try N.held(store, .exchange, "ex-empty") == nil)
        #expect(try N.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'review_exchanges'") == 0, "its rows went")

        try store.execute("UPDATE review_exchanges SET question = 'Q3' WHERE id = 'ex-empty'")
        let filled = try #require(N.savedFields(try N.pending(store)["Exchange:ex-empty"]), "the write that fills it sends it whole")
        #expect(filled["question"] == .string("Q3") && filled["chatID"] == .string("chat-1") && filled["seq"] == SyncJSON(Int64(3)))

        #expect(!ExchangeProjection.isComplete(["question": .text("  "), "user_answer": .null, "evaluation": .text("\n")]))
        #expect(ExchangeProjection.isComplete(["question": .text("Q"), "user_answer": .null, "evaluation": .null]))
        #expect(ExchangeProjection.isComplete(["question": .text(""), "user_answer": .text("Mine"), "evaluation": .null]))
        #expect(ExchangeProjection.isComplete(["question": .text(""), "user_answer": .null, "evaluation": .text("A reply")]))
    }

    @Test("A 300 KiB pasted question spills into a satellite, and another Mac holds it whole once the reader brings it")
    func longQuestionSpills() throws {
        let (root, store) = try N.makeStore("exchange-spill")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try F.addChat(store, "chat-1")
        var chapter = ""
        var line = 0
        while chapter.utf8.count < 300 * 1024 {
            line += 1
            chapter += "Paragraph \(line): the proton gradient across the inner membrane drives ATP synthase, turn \(line * 7919 % 104_729).\n"
        }
        let exchangeID = try F.addExchange(store, chat: "chat-1", question: chapter)

        let change = try #require(try N.pending(store)["Exchange:\(exchangeID)"])
        let fields = try #require(N.savedFields(change))
        let file = try #require(fields["question"].flatMap(SyncEnvelope.spilledFile))
        #expect(file.role == "field.question" && file.owner == exchangeID)
        #expect(file.size == Int64(chapter.utf8.count) && file.hash == SyncIdentity.sha256Hex(Data(chapter.utf8)))
        guard case .save(let envelope) = change.action else { Issue.record("not a save"); return }
        #expect(try envelope.storedPayload().count < 16 * 1024, "the record stays small")
        let uploads = ChatSatellites.uploads(fields: fields, texts: ["question": chapter])
        #expect(uploads.count == 1)
        #expect(try F.satelliteBody(try #require(uploads.first).stored) == Data(chapter.utf8), "the uploader's bytes are the text")
        try F.sendAll(store)
        #expect(try N.pending(store).isEmpty, "an unchanged long field is not sent again")

        // Another Mac: the question waits for its satellite, and is held back from the encoder meanwhile.
        let (otherRoot, other) = try N.makeStore("exchange-spill-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try N.prepareReplica(other)
        try N.apply(other, [
            try N.record(.chat, "chat-1", ["kind": "chat", "title": "T", "status": "active", "contextMode": "none", "createdAt": SyncJSON(Int64(1)), "editedAt": SyncJSON(Int64(1))]),
            try N.record(.exchange, exchangeID, fields),
        ])
        #expect(try N.text(other, "SELECT question FROM review_exchanges WHERE id = ?", [.text(exchangeID)]) == "")
        #expect(try ChatSatellites.waiting(.exchange, exchangeID, connection: other)["question"] != nil)
        try other.execute("UPDATE review_exchanges SET knowledge_note = 'ATP' WHERE id = ?", [.text(exchangeID)])
        let edit = try #require(try N.pending(other)["Exchange:\(exchangeID)"])
        #expect(Set(edit.stamps.keys.map(\.field)) == ["knowledgeNote"], "the waited-for question is never sent over the server's")

        try other.replica.apply { _ in
            try ChatSatellites.received(try F.satelliteBody(try #require(uploads.first).stored), field: "question", .exchange, exchangeID, connection: other)
        }
        #expect(try N.text(other, "SELECT question FROM review_exchanges WHERE id = ?", [.text(exchangeID)]) == chapter)
        #expect(try ChatSatellites.waiting(.exchange, exchangeID, connection: other).isEmpty)
        let back = try #require(try ExchangeProjection.loadRows(localID: exchangeID, connection: other).map(ExchangeProjection.encodeRows))
        #expect(back["question"] == fields["question"], "the text encodes to the same satellite")
    }
}
