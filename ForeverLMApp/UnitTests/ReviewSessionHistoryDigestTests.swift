import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The rolling summary of a chat's older turns used to be rebuilt from scratch
/// on every reopen, in one request carrying the whole backlog, and the reply
/// waited on it. Schema 88 saves the summary beside the session, the fold runs
/// in the background in bounded batches, and a reopened chat resumes from the
/// message the saved summary stopped on. These tests pin the storage contract
/// and the two pure decisions the fold makes: where a batch ends, and where a
/// saved summary lines up with a rebuilt transcript.
@Suite("Chat history summary")
struct ReviewSessionHistoryDigestTests {

    private typealias Message = ReviewSessionManager.Message

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    private static func scalarInt(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    /// A released v87 store is today's shape minus the digest table, which is
    /// the entire schema delta. The chat is written first so the fixture holds
    /// what a real v87 store held: a long conversation and no saved summary.
    private static func makeVersion87Store(
        at root: URL,
        populate: (KnowledgeStore) throws -> Void
    ) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try populate(store)
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("DROP TABLE review_session_history_digests")
        try store.execForTesting("PRAGMA user_version = 87")
    }

    @discardableResult
    private static func addChat(to store: KnowledgeStore, sessionID: String, turns: Int) throws -> [ReviewExchangeRecord] {
        try store.createReviewSession(id: sessionID, topic: "A long chat", sourceIDs: [])
        for turn in 0..<turns {
            _ = try store.addReviewExchange(
                sessionID: sessionID,
                question: "Question \(turn)",
                answer: "Answer \(turn)",
                evaluation: "Evaluation \(turn)",
                score: nil,
                knowledgeNote: nil,
                sourceRefs: []
            )
        }
        return try store.loadReviewSessionExchanges(sessionID: sessionID)
    }

     @Test("A saved summary round-trips, replaces itself, and dies with its chat")
    func digestRoundTripAndCascade() throws {
        let root = try Self.temporaryRoot("digest-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let exchanges = try Self.addChat(to: store, sessionID: "chat", turns: 4)

        let pendingBeforeSaving = try store.pendingSyncChanges().count
        let first = ReviewSessionHistoryDigest(
            sessionID: "chat",
            digest: "Learner is studying GDF15 signalling.",
            throughExchangeID: exchanges[1].id,
            throughField: .evaluation,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try store.saveReviewSessionHistoryDigest(first)
        #expect(try store.loadReviewSessionHistoryDigest(sessionID: "chat") == first)

        // A later fold replaces the row rather than adding a second one.
        let second = ReviewSessionHistoryDigest(
            sessionID: "chat",
            digest: "Learner is studying GDF15 signalling; settled on the GFRAL receptor.",
            throughExchangeID: exchanges[3].id,
            throughField: .userAnswer,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.saveReviewSessionHistoryDigest(second)
        #expect(try store.loadReviewSessionHistoryDigest(sessionID: "chat") == second)
        #expect(Self.scalarInt(at: root, "SELECT COUNT(*) FROM review_session_history_digests") == 1)

        // An empty summary is never worth saving over a real one.
        try store.saveReviewSessionHistoryDigest(ReviewSessionHistoryDigest(
            sessionID: "chat", digest: "  \n", throughExchangeID: exchanges[3].id,
            throughField: .userAnswer, updatedAt: Date()
        ))
        #expect(try store.loadReviewSessionHistoryDigest(sessionID: "chat") == second)

        // The digest is a local cache of synced exchanges, never a synced record:
        // saving it enqueues nothing for CloudKit.
        #expect(try store.pendingSyncChanges().count == pendingBeforeSaving)

        try store.deleteReviewSession("chat")
        #expect(Self.scalarInt(at: root, "SELECT COUNT(*) FROM review_session_history_digests") == 0)
    }

    // MARK: - Where a fold batch ends

    private static func turn(_ index: Int, role: Message.Role = .user, characters: Int = 10, exchangeID: String? = nil, field: ReviewExchangeMessageField? = nil) -> Message {
        Message(
            role: role,
            content: String(repeating: "x", count: characters) + " \(index)",
            exchangeID: exchangeID,
            exchangeField: field
        )
    }

    @Test("A fold batch stops at the character limit and advances at least one message")
    @MainActor
    func foldBatchIsBoundedByCharacters() {
        // 30 messages of ~1,000 characters each, all older than the recent window.
        let messages = (0..<30).map { Self.turn($0, role: $0.isMultiple(of: 2) ? .assistant : .user, characters: 1_000) }
        let batch = ReviewSessionManager.historyFoldBatch(
            from: messages,
            coveredMessageCount: 0,
            olderCount: 30,
            characterLimit: 5_200,
            turnCharacterLimit: 4_000
        )
        // Five ~1,010-character lines fit under 5,200; the sixth would not.
        #expect(batch?.endIndex == 5)
        #expect(batch?.transcript.components(separatedBy: "\n\n").count == 5)
        #expect(batch?.transcript.hasPrefix("Tutor: ") == true)

        // The next batch resumes exactly where the previous one stopped.
        let next = ReviewSessionManager.historyFoldBatch(
            from: messages,
            coveredMessageCount: 5,
            olderCount: 30,
            characterLimit: 5_200,
            turnCharacterLimit: 4_000
        )
        #expect(next?.endIndex == 10)
        #expect(next?.transcript.contains(" 5") == true)
        #expect(next?.transcript.contains(" 4\n") == false)

        // One turn larger than the whole budget still moves the fold forward.
        let oversized = ReviewSessionManager.historyFoldBatch(
            from: [Self.turn(0, characters: 50_000), Self.turn(1)],
            coveredMessageCount: 0,
            olderCount: 2,
            characterLimit: 4_000,
            turnCharacterLimit: 4_000
        )
        #expect(oversized?.endIndex == 1)
        #expect((oversized?.transcript.count ?? 0) <= 4_000 + "Learner: ".count)
    }

    @Test("A fold batch never reaches into the verbatim recent window")
    @MainActor
    func foldBatchRespectsOlderCount() {
        let messages = (0..<25).map { Self.turn($0) }
        let batch = ReviewSessionManager.historyFoldBatch(
            from: messages,
            coveredMessageCount: 0,
            olderCount: 5,
            characterLimit: 100_000,
            turnCharacterLimit: 4_000
        )
        #expect(batch?.endIndex == 5)
        #expect(ReviewSessionManager.historyFoldBatch(
            from: messages, coveredMessageCount: 5, olderCount: 5,
            characterLimit: 100_000, turnCharacterLimit: 4_000
        ) == nil)
    }

    @Test("The saved cursor is the last persisted message, and harness rows are folded silently")
    @MainActor
    func foldBatchCursorSkipsUnsavedAndHarnessRows() {
        let toolRow = Message(
            role: .tool,
            content: "",
            toolActivity: .init(kind: .tool, toolName: "search_sources", detail: nil, state: .succeeded, resultPreview: nil)
        )
        let messages = [
            Self.turn(0, role: .assistant, exchangeID: "e1", field: .question),
            Self.turn(1, role: .user, exchangeID: "e1", field: .userAnswer),
            toolRow,
            Self.turn(2, role: .assistant, exchangeID: "e1", field: .evaluation),
            Self.turn(3, role: .user),  // not persisted yet
            toolRow,
        ]
        let batch = ReviewSessionManager.historyFoldBatch(
            from: messages,
            coveredMessageCount: 0,
            olderCount: messages.count,
            characterLimit: 100_000,
            turnCharacterLimit: 4_000
        )
        #expect(batch?.endIndex == messages.count)
        #expect(batch?.cursor == .init(exchangeID: "e1", field: .evaluation))
        // Tool rows contribute no transcript line.
        #expect(batch?.transcript.components(separatedBy: "\n\n").count == 4)

        // A range holding only harness rows yields an empty transcript that the
        // fold marks covered without a request.
        let harnessOnly = ReviewSessionManager.historyFoldBatch(
            from: [toolRow, toolRow],
            coveredMessageCount: 0,
            olderCount: 2,
            characterLimit: 100_000,
            turnCharacterLimit: 4_000
        )
        #expect(harnessOnly?.transcript.isEmpty == true)
        #expect(harnessOnly?.endIndex == 2)
        #expect(harnessOnly?.cursor == nil)
    }

    // MARK: - Lining a saved summary up with a reopened transcript

    @Test("A saved summary covers the rebuilt transcript through its cursor, or not at all")
    @MainActor
    func savedDigestLinesUpByCursor() {
        let rebuilt = [
            Self.turn(0, role: .assistant, exchangeID: "e1", field: .question),
            Self.turn(1, role: .user, exchangeID: "e1", field: .userAnswer),
            Self.turn(2, role: .assistant, exchangeID: "e1", field: .evaluation),
            Self.turn(3, role: .user, exchangeID: "e2", field: .userAnswer),
            Self.turn(4, role: .assistant, exchangeID: "e2", field: .evaluation),
        ]
        func digest(_ exchangeID: String, _ field: ReviewExchangeMessageField) -> ReviewSessionHistoryDigest {
            ReviewSessionHistoryDigest(sessionID: "s", digest: "d", throughExchangeID: exchangeID, throughField: field, updatedAt: Date())
        }
        #expect(ReviewSessionManager.historyDigestCoveredMessageCount(in: rebuilt, through: digest("e1", .evaluation)) == 3)
        #expect(ReviewSessionManager.historyDigestCoveredMessageCount(in: rebuilt, through: digest("e2", .userAnswer)) == 4)
        // The message the summary stopped on was deleted: the summary cannot be
        // trusted against this transcript and is rebuilt instead.
        #expect(ReviewSessionManager.historyDigestCoveredMessageCount(in: rebuilt, through: digest("e1", .userAnswer).replacingExchange("gone")) == nil)
    }

    @Test("An oversized summary keeps its newest lines")
    @MainActor
    func boundedDigestKeepsTheEnd() {
        let digest = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let bounded = ReviewSessionManager.boundedHistoryDigest(digest, limit: 40)
        #expect(bounded.hasPrefix("[Earlier summary trimmed]\n"))
        #expect(bounded.hasSuffix("line 99"))
        #expect(bounded.count <= 40 + "[Earlier summary trimmed]\n".count)
        #expect(ReviewSessionManager.boundedHistoryDigest("short", limit: 40) == "short")
    }

    @Test("The payload keeps the saved summary out of the cacheable stable head")
    @MainActor
    func restoredDigestRidesInVolatilePrompt() {
        let messages = (0..<30).map { (role: $0.isMultiple(of: 2) ? "assistant" : "user", content: "turn-\($0)") }
        let parts = ReviewSessionManager.historyDigestPayloadPartsForTesting(
            messages: messages,
            digest: "Saved summary of the first eight turns.",
            coveredMessageCount: 8,
            systemPrompt: "Tutor prompt."
        )
        #expect(parts.stable == "Tutor prompt.")
        #expect(parts.volatile.contains("Saved summary of the first eight turns."))
        // Turns after the saved boundary but before the recent window still
        // ride in the deterministic compact, so nothing is lost mid-fold.
        #expect(parts.volatile.contains("Turns since that summary:"))
        #expect(parts.volatile.contains("turn-8"))
        #expect(parts.volatile.contains("turn-7") == false)
    }
}

private extension ReviewSessionHistoryDigest {
    func replacingExchange(_ exchangeID: String) -> ReviewSessionHistoryDigest {
        ReviewSessionHistoryDigest(
            sessionID: sessionID,
            digest: digest,
            throughExchangeID: exchangeID,
            throughField: throughField,
            updatedAt: updatedAt
        )
    }
}
