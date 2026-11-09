import Foundation
import Testing
@testable import ForeverLM

/// Private chat kinds and what never enters a space (docs/cloudkit-schema-design.md D19, D20, D50,
/// §3.5.13, §9.2, WP10): a review, memory review, quiz sitting, walk or voice chat filed in a space
/// notebook stays in `Library`; grading and scores are left out of a space; every generation-2
/// creation site writes its kind; an import's score into a space chat stays local and is not sent
/// again (R5-m1, R6-m10).
@Suite("Private chat kinds")
struct PrivateChatKindTests {
    typealias F = ChatSyncFixture
    typealias N = NotebookSyncFixture

    @Test("Chats of a private kind filed in a space notebook are placed in Library, with their exchanges; a chat follows its notebook into the space")
    func privateKindsStayInLibrary() throws {
        let (root, store) = try N.makeStore("kind-placement")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.addNotebook(store, "nb-s")
        try F.holdSpaceNotebook(store, "nb-s")
        var exchanges: [String: String] = [:]
        for kind in ChatKind.allCases where kind != .transcript {
            let id = "chat-\(kind.rawValue)"
            try F.addChat(store, id, kind: kind == .voice ? .chat : kind, goalID: "nb-s")
            if kind == .voice {
                // No creation site writes voice; only the classifier gives it to a recorded voice session.
                try store.execute("UPDATE review_sessions SET chat_kind = 'voice' WHERE id = ?", [.text(id)])
            }
            exchanges[kind.rawValue] = try F.addExchange(store, chat: id)
        }
        let pending = try N.pending(store)
        for kind in ChatKind.allCases where kind != .transcript {
            let chat = try #require(pending["Chat:chat-\(kind.rawValue)"])
            let exchange = try #require(pending["Exchange:\(exchanges[kind.rawValue] ?? "")"])
            #expect(N.savedFields(chat)?["kind"] == .string(kind.rawValue))
            #expect(N.savedFields(chat)?["notebookID"] == .string("nb-s"), "filed in the space notebook, from Library")
            let expected = kind.isPrivate ? N.libraryZoneKey : F.spaceZoneKey
            #expect(chat.zoneKey == expected, "\(kind.rawValue) chat")
            #expect(exchange.zoneKey == expected, "\(kind.rawValue) exchange")
        }
    }

    @Test("Grading and a score are encoded only for a private chat, refused in a space, and kept in the local rows")
    func gradingNeverEntersASpace() throws {
        let (root, store) = try N.makeStore("kind-grading")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.addNotebook(store, "nb-s")
        try F.holdSpaceNotebook(store, "nb-s")
        try F.addChat(store, "chat-1", kind: .chat, goalID: "nb-s")
        let exchangeID = try F.addExchange(store, chat: "chat-1", score: 0.5)
        try store.execute("UPDATE review_exchanges SET idea_coverage = ?, question_verdict = 'fit' WHERE id = ?", [
            .text(MemoryIdeaCoverage.encode([MemoryIdeaCoverage(ideaID: "src-a#idea-1", status: .produced)])), .text(exchangeID),
        ])
        // The same exchange in a review, in Library, carries both.
        try F.addChat(store, "review-1", kind: .review)
        let reviewed = try F.addExchange(store, chat: "review-1", score: 0.5)
        try store.execute("UPDATE review_exchanges SET idea_coverage = ?, question_verdict = 'fit' WHERE id = ?", [
            .text(MemoryIdeaCoverage.encode([MemoryIdeaCoverage(ideaID: "src-a#idea-1", status: .produced)])), .text(reviewed),
        ])
        let pending = try N.pending(store)
        let review = try #require(N.savedFields(pending["Exchange:\(reviewed)"]))
        #expect(review["score"] == .number(0.5))
        #expect(review["grading"]?["ideaCoverage"] == .array([.object(["ideaID": "src-a#idea-1", "status": "produced"])]))
        #expect(review["grading"]?["questionVerdict"] == .string("fit"))
        let local = try #require(N.savedFields(pending["Exchange:\(exchangeID)"]))
        #expect(local["score"] == nil && local["grading"] == nil, "a chat's exchange never encodes them")
        let refusals = SpaceWriteGuard.refusals(writing: "Exchange", fields: review, by: .init(user: "alice", permission: .readWrite, isOwner: true))
        #expect(refusals.contains(.privateKindsOnlyField(type: "Exchange", field: "score")))
        #expect(refusals.contains(.privateKindsOnlyField(type: "Exchange", field: "grading")))

        let sent = try F.sendAll(store)
        #expect(sent["Exchange:\(exchangeID)"]?.zoneKey == F.spaceZoneKey)
        let server = try #require(try N.held(store, .exchange, exchangeID, zoneKey: F.spaceZoneKey))
        #expect(server.fields["score"] == nil && server.fields["grading"] == nil)
        #expect(server.fields["evaluation"] == .string("Right: four per NADH."), "the rest went")
        #expect(try N.text(store, "SELECT score FROM review_exchanges WHERE id = ?", [.text(exchangeID)]) == "0.5")
    }

    @Test("An import's score appended to a chat in a space notebook stays local, named in the log, and is not sent again")
    func importedScoreStaysLocal() throws {
        let (root, store) = try N.makeStore("kind-import-score")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.addNotebook(store, "nb-s")
        try F.holdSpaceNotebook(store, "nb-s")
        try store.importReviewChatSession(
            id: "chat-1", title: "Team talk", turns: [ReviewChatTurn(question: "Q", answer: "A", evaluation: "E")], sourceIDs: [], goalID: "nb-s",
            summary: nil, overallScore: nil, modelProvider: nil, modelID: nil, chatKind: .chat, marksReviewed: false
        )
        try F.sendAll(store)
        #expect(try N.held(store, .chat, "chat-1", zoneKey: F.spaceZoneKey)?.fields["kind"] == .string("chat"))

        try store.appendReviewChatExchanges(
            sessionID: "chat-1", turns: [ReviewChatTurn(question: "Q2", answer: "A2", evaluation: "E2")], sourceIDs: [], summary: nil,
            overallScore: 0.9, modelProvider: nil, modelID: nil
        )
        let change = try #require(try N.pending(store)["Chat:chat-1"])
        #expect(N.savedFields(change)?["overallScore"] == nil, "a chat's score is never encoded")
        let sent = try F.sendAll(store)
        #expect(sent.keys.contains { $0.hasPrefix("Exchange:") }, "the appended exchange goes")
        #expect(try N.held(store, .chat, "chat-1", zoneKey: F.spaceZoneKey)?.fields["overallScore"] == nil)
        #expect(try N.text(store, "SELECT overall_score FROM review_sessions WHERE id = 'chat-1'") == "0.9", "the local row keeps it")
        #expect(try N.pending(store)["Chat:chat-1"] == nil, "its outbox row went with the acknowledgement")
        #expect(try N.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'review_sessions' AND column = 'overall_score'") == 0)
    }

    @Test("Every generation-2 creation site writes its kind, and none writes voice")
    func creationSitesWriteKinds() throws {
        let (root, store) = try N.makeStore("kind-sites")
        defer { try? FileManager.default.removeItem(at: root) }
        func kind(_ id: String) throws -> String? { try N.text(store, "SELECT chat_kind FROM review_sessions WHERE id = ?", [.text(id)]) }
        func marks(_ id: String) throws -> String? { try N.text(store, "SELECT marks_reviewed FROM review_sessions WHERE id = ?", [.text(id)]) }

        try F.addChat(store, "plain", kind: .chat)
        try F.addChat(store, "a-review", kind: .review)
        try F.addChat(store, "\(CourseQuizSitting.sessionIDPrefix)quiz-1-\(UUID().uuidString)", kind: .quizSitting)
        try F.addChat(store, "walk", kind: .walkthrough)
        try F.addChat(store, "\(MemoryReviewSession.idPrefix)2026-10-04", kind: nil)
        #expect(try kind("plain") == "chat" && kind("a-review") == "review" && kind("walk") == "walkthrough")
        #expect(try kind("\(MemoryReviewSession.idPrefix)2026-10-04") == "memory", "the day's memory review is memory by its id")
        #expect(try N.count(store, "SELECT COUNT(*) FROM review_sessions WHERE chat_kind = 'quizSitting'") == 1)
        #expect(try N.count(store, "SELECT COUNT(*) FROM review_sessions WHERE chat_kind = 'voice'") == 0)
        #expect(try N.text(store, "SELECT context_mode FROM review_sessions WHERE id = 'plain'") == "none")

        // The app's chat manager: the kind each start gives.
        #expect(ReviewSessionManager.createdChatKind(fixedSessionID: nil, mode: .review) == .review)
        #expect(ReviewSessionManager.createdChatKind(fixedSessionID: nil, mode: .assistant) == .chat)
        #expect(ReviewSessionManager.createdChatKind(fixedSessionID: nil, mode: .deepRead) == .chat)
        #expect(ReviewSessionManager.createdChatKind(fixedSessionID: MemoryReviewSession.idPrefix + "2026-10-04", mode: .review) == .memory)
        #expect(ReviewSessionManager.createdChatKind(fixedSessionID: CourseQuizSitting.sessionID(forQuizID: "q1"), mode: .review) == .quizSitting)

        // Imports: a review when scored, else a chat, and the call's choice of marking.
        _ = try store.importReviewChatSession(
            id: "imported-scored", title: "Scored", turns: [ReviewChatTurn(question: "Q", answer: "A", evaluation: "E")], sourceIDs: [],
            summary: nil, overallScore: 0.7, modelProvider: nil, modelID: nil,
            chatKind: ChatKindClassifier.kind(of: .init(id: "", hasOverallScore: true)), marksReviewed: true
        )
        _ = try store.importReviewChatSession(
            id: "imported-chat", title: "Talk", turns: [ReviewChatTurn(question: "Q", answer: "A", evaluation: "E")], sourceIDs: [],
            summary: nil, overallScore: nil, modelProvider: nil, modelID: nil, kind: .chat,
            chatKind: ChatKindClassifier.kind(of: .init(id: "", kind: "chat")), marksReviewed: false
        )
        #expect(try kind("imported-scored") == "review" && marks("imported-scored") == "1")
        #expect(try kind("imported-chat") == "chat" && marks("imported-chat") == "0")

        // A link to an external chat is a chat.
        let link = try store.saveReviewSessionLink(title: "Elsewhere", url: "https://example.com/chat/1")
        #expect(try kind(link.id) == "chat")
    }

    @Test("A fork keeps its original's kind, since it holds the original's answers")
    func forkKeepsKind() throws {
        let (root, store) = try N.makeStore("kind-fork")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addChat(store, "a-review", kind: .review)
        try store.recordPendingReviewUserMessage(sessionID: "a-review", answer: "Protons", sourceRefs: [])
        try store.answerPendingReviewExchange(sessionID: "a-review", answer: "Protons", evaluation: "Right.", score: 1, knowledgeNote: nil, sourceRefs: [])
        let exchangeID = try F.exchangeID(store, chat: "a-review", sequence: 1)
        let fork = try store.forkReviewSession(sessionID: "a-review", throughExchangeID: exchangeID, field: .evaluation)
        #expect(try N.text(store, "SELECT chat_kind FROM review_sessions WHERE id = ?", [.text(fork.id)]) == "review")
    }

    @Test("Under generation 2 an append reads the chat's marksReviewed, and an explicit false is remembered")
    func appendReadsMarksReviewed() throws {
        let (root, store) = try N.makeStore("kind-marks")
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, marks, kind) in [("reviewing", true, ChatKind.chat), ("talk", false, ChatKind.chat)] {
            _ = try store.importReviewChatSession(
                id: id, title: id, turns: [ReviewChatTurn(question: "Q", answer: "A", evaluation: "E")], sourceIDs: [], summary: nil,
                overallScore: nil, modelProvider: nil, modelID: nil, kind: marks ? nil : .chat, chatKind: kind, marksReviewed: marks
            )
        }
        #expect(try store.generation2AppendMarksReviewed(requested: nil, sessionID: "reviewing"))
        #expect(try !store.generation2AppendMarksReviewed(requested: nil, sessionID: "talk"))
        #expect(try store.generation2AppendMarksReviewed(requested: true, sessionID: "talk"), "the call decides when it says")
        #expect(try !store.generation2AppendMarksReviewed(requested: nil, sessionID: "talk"), "an explicit true is not remembered")
        #expect(try !store.generation2AppendMarksReviewed(requested: false, sessionID: "reviewing"))
        #expect(try !store.generation2AppendMarksReviewed(requested: nil, sessionID: "reviewing"), "an explicit false is")
        // A chat with no stored choice marks only as a review.
        try F.addChat(store, "app-review", kind: .review)
        try F.addChat(store, "app-chat", kind: .chat)
        #expect(try store.generation2AppendMarksReviewed(requested: nil, sessionID: "app-review"))
        #expect(try !store.generation2AppendMarksReviewed(requested: nil, sessionID: "app-chat"))
    }
}
