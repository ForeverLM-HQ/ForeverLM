import Foundation
import Testing
@testable import ForeverLM

/// The Chat, Exchange and rated-Mark projections (docs/cloudkit-schema-design.md §3.5.13, §3.5.14,
/// §3.5.19, WP10): a round trip of every field the Mac holds, an Exchange applied before its Chat, a
/// cascaded source row that is not a removal, ratings as the member's Marks, and a deleted chat.
@Suite("Chat projection")
struct ChatProjectionTests {
    typealias F = ChatSyncFixture
    typealias N = NotebookSyncFixture

    @Test("A chat's rows encode every field it holds, and its records project back into the same rows on another Mac")
    func roundTrip() throws {
        let (root, store) = try N.makeStore("chat-round")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.addNotebook(store, "nb-1")
        for source in ["src-a", "src-b"] { try N.addSource(store, source) }
        try F.addChat(store, "chat-1", kind: .review, sourceIDs: ["src-a", "src-b"], cardIDs: ["card-2", "card-1"], goalID: "nb-1", briefing: "Today: Complex I")
        let exchangeID = try F.addExchange(store, chat: "chat-1", score: 0.75)
        try store.completeReviewSession(sessionID: "chat-1", overallScore: 0.8, summary: "Knew the pumps", endedAt: Date(timeIntervalSinceReferenceDate: 30_000))
        try store.execute("""
            INSERT INTO artifact_chat_links (id, artifact_id, session_id, anchor_revision, anchor_start, anchor_end, anchor_quote, section_title, created_at)
            VALUES ('link-1', 'doc-1', 'chat-1', 'rev-1', 10, 42, 'the quoted passage', 'Methods', 15000)
        """)

        let pending = try N.pending(store)
        let chat = try #require(N.savedFields(pending["Chat:chat-1"]))
        #expect(chat["kind"] == .string("review"))
        #expect(chat["notebookID"] == .string("nb-1"))
        #expect(chat["title"] == .string("Chat chat-1"))
        #expect(chat["status"] == .string("ended"))
        #expect(chat["model"] == .object(["provider": "openrouter", "id": "vendor/model", "effort": "high"]))
        #expect(chat["contextMode"] == .string("explicit"))
        #expect(chat["contextSourceIDs"] == .object(["src-a": true, "src-b": true]))
        #expect(chat["cardIDs"] == .object(["card-1": true, "card-2": true]))
        #expect(chat["docLinks"]?["link-1"]?["quote"] == .string("the quoted passage"))
        #expect(chat["docLinks"]?["link-1"]?["start"] == SyncJSON(Int64(10)))
        let briefing = try #require(chat["briefing"].flatMap(FileRef.init(json:)))
        #expect(briefing.role == "briefing" && briefing.owner == "chat-1")
        #expect(briefing.hash == SyncIdentity.sha256Hex(Data("Today: Complex I".utf8)))
        #expect(chat["summary"] == .string("Knew the pumps"))
        #expect(chat["overallScore"] == .number(0.8))
        #expect(chat["createdAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 10_000)))
        #expect(chat["editedAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 30_000)))
        #expect(chat["loadedSourceIDs"] == nil && chat["exchangeCount"] == nil, "what a chat loaded and how many exchanges it has stay local")
        let exchange = try #require(N.savedFields(pending["Exchange:\(exchangeID)"]))
        #expect(exchange["chatID"] == .string("chat-1") && exchange["seq"] == SyncJSON(Int64(1)))
        #expect(exchange["question"] == .string("What does Complex I pump?"))
        #expect(exchange["userAnswer"] == .string("Protons") && exchange["evaluation"] == .string("Right: four per NADH."))
        #expect(exchange["score"] == .number(0.75))
        #expect(exchange["sourceRefs"] == .array(["src-a"]))
        #expect(exchange["createdAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 20_000)))

        // Another Mac holds the notebook and the sources, and nothing else.
        let (otherRoot, other) = try N.makeStore("chat-round-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try N.prepareReplica(other)
        try N.addNotebook(other, "nb-1")
        for source in ["src-a", "src-b"] { try N.addSource(other, source) }
        try N.apply(other, [try F.received(pending["Chat:chat-1"]), try F.received(pending["Exchange:\(exchangeID)"])])
        #expect(try N.text(other, """
            SELECT topic || '|' || status || '|' || goal_id || '|' || model_provider || '|' || model_id || '|' || model_effort || '|' || chat_kind
                || '|' || context_mode || '|' || summary || '|' || overall_score || '|' || exchange_count FROM review_sessions WHERE id = 'chat-1'
        """) == "Chat chat-1|completed|nb-1|openrouter|vendor/model|high|review|explicit|Knew the pumps|0.8|1")
        #expect(try N.count(other, "SELECT COUNT(*) FROM review_session_sources WHERE session_id = 'chat-1'") == 2)
        #expect(Set(KnowledgeStore.decodeJSONStringArray(try N.text(other, "SELECT card_ids FROM review_sessions WHERE id = 'chat-1'"))) == ["card-1", "card-2"])
        #expect(try N.text(other, "SELECT anchor_quote FROM artifact_chat_links WHERE id = 'link-1'") == "the quoted passage")
        #expect(try N.text(other, "SELECT evaluation FROM review_exchanges WHERE id = ?", [.text(exchangeID)]) == "Right: four per NADH.")
        // The briefing is a satellite this Mac does not hold yet: it waits, and the reader writes it in.
        #expect(try N.text(other, "SELECT briefing FROM review_sessions WHERE id = 'chat-1'") == nil)
        #expect(try ChatSatellites.waiting(.chat, "chat-1", connection: other)["briefing"] != nil)
        try other.replica.apply { _ in try ChatSatellites.received(Data("Today: Complex I".utf8), field: "briefing", .chat, "chat-1", connection: other) }
        #expect(try N.text(other, "SELECT briefing FROM review_sessions WHERE id = 'chat-1'") == "Today: Complex I")
        #expect(try ChatSatellites.waiting(.chat, "chat-1", connection: other).isEmpty)
        #expect(try N.pending(other).keys.allSatisfy { $0.hasPrefix("Notebook:") || $0.hasPrefix("Source:") }, "an apply sends nothing back")

        let back = try #require(try ChatProjection.loadRows(localID: "chat-1", connection: other).map(ChatProjection.encodeRows))
        for field in ["kind", "notebookID", "title", "status", "model", "contextMode", "contextSourceIDs", "cardIDs", "docLinks", "briefing",
                      "summary", "overallScore", "createdAt"] {
            #expect(back[field] == chat[field], "\(field) round-trips")
        }
    }

    @Test("An Exchange applied before its Chat waits, then projects when the Chat arrives")
    func exchangeBeforeChat() throws {
        let (root, store) = try N.makeStore("chat-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.apply(store, [try N.record(.exchange, "exc-1", [
            "chatID": "chat-9", "seq": 1, "createdAt": SyncJSON(Int64(1_759_000_000_000)), "question": "Why?", "evaluation": "Because.",
        ])])
        #expect(try N.count(store, "SELECT COUNT(*) FROM review_exchanges") == 0)
        #expect(try N.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Chat' AND waiting_on_id = 'chat-9'") == 1)
        try N.apply(store, [try N.record(.chat, "chat-9", [
            "kind": "chat", "title": "Late", "status": "active", "contextMode": "none", "createdAt": SyncJSON(Int64(1_758_000_000_000)),
            "editedAt": SyncJSON(Int64(1_759_000_000_000)),
        ])])
        #expect(try N.text(store, "SELECT evaluation FROM review_exchanges WHERE id = 'exc-1' AND session_id = 'chat-9'") == "Because.")
        #expect(try N.count(store, "SELECT exchange_count FROM review_sessions WHERE id = 'chat-9'") == 1)
        #expect(try N.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        #expect(try N.pending(store).isEmpty)
    }

    @Test("A chat's source row that goes with its source is not a removal; an unlink is")
    func cascadedSourceRowIsNotARemoval() throws {
        let (root, store) = try N.makeStore("chat-cascade")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        for source in ["src-a", "src-b"] { try N.addSource(store, source) }
        try F.addChat(store, "chat-1", sourceIDs: ["src-a", "src-b"])
        try F.sendAll(store)
        #expect(try N.held(store, .chat, "chat-1")?.fields["contextSourceIDs"] == .object(["src-a": true, "src-b": true]))

        try store.deleteSourceRows("src-a")
        #expect(try N.count(store, "SELECT COUNT(*) FROM review_session_sources WHERE source_id = 'src-a'") == 0, "the row cascaded")
        let afterDelete = try N.pending(store)["Chat:chat-1"]
        #expect(afterDelete?.stamps.keys.contains { $0.field == "contextSourceIDs" } != true, "no removal is sent")
        try F.sendAll(store)
        #expect(try N.held(store, .chat, "chat-1")?.fields["contextSourceIDs"]?["src-a"] == .bool(true), "the server keeps it")

        try store.execute("DELETE FROM review_session_sources WHERE session_id = 'chat-1' AND source_id = 'src-b'")
        let unlink = try #require(try N.pending(store)["Chat:chat-1"])
        #expect(N.savedFields(unlink)?["contextSourceIDs"]?["src-b"] == .bool(false))
        #expect(Set(unlink.stamps.keys.map { "\($0.field):\($0.element ?? "")" }) == ["contextSourceIDs:src-b"])
    }

    @Test("A thumb on an exchange is the member's Mark, flipped off when taken back; an unrated exchange has none")
    func ratingsAreMarks() throws {
        let (root, store) = try N.makeStore("chat-rating")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try F.addChat(store, "chat-1")
        let rated = try F.addExchange(store, chat: "chat-1")
        let unrated = try F.addExchange(store, chat: "chat-1", question: "And Complex II?")
        try store.execute("UPDATE review_exchanges SET rating = 'liked', rating_reason = 'clear', rating_field = 'evaluation', rated_at = 25000 WHERE id = ?", [.text(rated)])
        let pending = try N.pending(store)
        let markID = MarkKey(kind: "rated", target: "exc:\(rated)").id
        let mark = try #require(N.savedFields(pending["Mark:\(markID)"]))
        #expect(mark["kind"] == .string("rated") && mark["target"] == .string("exc:\(rated)") && mark["on"] == .bool(true))
        #expect(mark["value"] == .object(["rating": "liked", "reason": "clear", "field": "evaluation"]))
        #expect(mark["at"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 25_000)))
        #expect(pending["Mark:\(MarkKey(kind: "rated", target: "exc:\(unrated)").id)"] == nil)
        #expect(N.savedFields(pending["Exchange:\(rated)"])?["rating"] == nil, "a rating is never on the shared Exchange")
        try F.sendAll(store)

        try store.execute("UPDATE review_exchanges SET rating = NULL, rating_reason = NULL, rating_field = NULL, rated_at = 26000 WHERE id = ?", [.text(rated)])
        let off = try #require(N.savedFields(try N.pending(store)["Mark:\(markID)"]))
        #expect(off["on"] == .bool(false), "taken back, the Mark is off, never deleted")

        // Another Mac: a Mark before its exchange waits for it, then rates it.
        let (otherRoot, other) = try N.makeStore("chat-rating-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try N.prepareReplica(other)
        try N.apply(other, [try N.record(.mark, markID, mark)])
        #expect(try N.count(other, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Exchange'") == 1)
        try N.apply(other, [
            try N.record(.chat, "chat-1", ["kind": "chat", "title": "T", "status": "active", "contextMode": "none", "createdAt": SyncJSON(Int64(1)), "editedAt": SyncJSON(Int64(1))]),
            try N.record(.exchange, rated, ["chatID": "chat-1", "seq": 1, "createdAt": SyncJSON(Int64(1)), "question": "Q", "evaluation": "E"]),
        ])
        #expect(try N.text(other, "SELECT rating || '|' || rating_field FROM review_exchanges WHERE id = ?", [.text(rated)]) == "liked|evaluation")
        #expect(try N.pending(other).isEmpty)
    }

    @Test("A deleted chat deletes its record and its exchanges' records")
    func deletedChat() throws {
        let (root, store) = try N.makeStore("chat-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try F.addChat(store, "chat-1")
        let exchangeID = try F.addExchange(store, chat: "chat-1")
        try F.sendAll(store)
        try store.deleteReviewSession("chat-1")
        let pending = try N.pending(store)
        #expect(pending["Chat:chat-1"]?.action == .delete)
        #expect(pending["Exchange:\(exchangeID)"]?.action == .delete)
    }
}
