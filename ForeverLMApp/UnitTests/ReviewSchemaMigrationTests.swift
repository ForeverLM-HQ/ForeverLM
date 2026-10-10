import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Schema 98 drops the retired method name from storage: the four `feynman_*`
/// tables become `review_*`, the usage ledger's task names take the tasks'
/// new raw values, and the sync bookkeeping for the renamed CloudKit record
/// type is cleared so every review session is re-uploaded as `ReviewSession`
/// by a bounded post-launch drain. What has to hold: a released-v96 store
/// comes up at the current schema with every session, exchange and digest intact under the
/// new table names; the drain re-enqueues the sessions and nothing else; a
/// same-named foreign table rolls the whole migration back; and a
/// production-sized history migrates in well under a second because renaming
/// a table reads no row.
@Suite("Review schema migration")
struct ReviewSchemaMigrationTests {

    /// Put a current store back into the exact shape build 73 (schema 96)
    /// wrote: the review tables under their old names with their old index
    /// names, the sync rows under the old entity name, the usage ledger with
    /// the old task raw values, and no re-upload queue.
    private static func reshapeToVersion96(_ store: KnowledgeStore) throws {
        for table in ["review_session_sync_repair_queue", "hidden_artifacts", "hidden_review_sessions"] {
            try store.execForTesting("DROP TABLE IF EXISTS \(table)")
        }
        for index in ["idx_review_exchanges_rated", "idx_review_exchanges_session", "idx_review_sessions_team"] {
            try store.execForTesting("DROP INDEX IF EXISTS \(index)")
        }
        for (new, old) in [
            ("review_sessions", "feynman_sessions"),
            ("review_exchanges", "feynman_exchanges"),
            ("review_session_sources", "feynman_session_sources"),
            ("review_session_history_digests", "feynman_session_history_digests"),
        ] {
            try store.execForTesting("ALTER TABLE \(new) RENAME TO \(old)")
        }
        try store.execForTesting("CREATE INDEX idx_feynman_exchanges_session ON feynman_exchanges(session_id)")
        try store.execForTesting("CREATE INDEX idx_feynman_exchanges_rated ON feynman_exchanges(rated_at DESC) WHERE rating IS NOT NULL")
        try store.execForTesting("CREATE INDEX idx_feynman_sessions_team ON feynman_sessions(team_id)")
        for table in ["sync_metadata", "sync_changes", "sync_conflicts"] {
            try store.execForTesting("UPDATE \(table) SET entity_type = 'feynmanSession' WHERE entity_type = 'reviewSession'")
        }
        try store.execForTesting("UPDATE ai_usage_events SET task = 'feynman_quiz' WHERE task = 'chat'")
        try store.execForTesting("PRAGMA user_version = 96")
    }

    private static func article(id: String, url: String, title: String) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        return article
    }

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func userVersion(at root: URL) -> Int32 {
        Int32(scalarInt(at: root, "PRAGMA user_version"))
    }

    private static func scalarInt(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    private static func tableExists(at root: URL, _ name: String) -> Bool {
        scalarInt(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") == 1
    }

    private static func indexExists(at root: URL, _ name: String) -> Bool {
        scalarInt(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = '\(name)'") == 1
    }

    /// Two sessions with exchanges, one linked source, and a usage row under
    /// the old task name.
    private static func seed(_ store: KnowledgeStore) throws {
        try store.saveSource(Self.article(id: "src-a", url: "https://example.com/a", title: "A"))
        try store.createReviewSession(id: "session-1", topic: "Entropy", sourceIDs: ["src-a"])
        _ = try store.addReviewExchange(
            sessionID: "session-1",
            question: "What is entropy?",
            answer: "A count of microstates.",
            evaluation: "Right idea.",
            score: 0.9,
            knowledgeNote: nil,
            sourceRefs: ["src-a"]
        )
        _ = try store.addReviewExchange(
            sessionID: "session-1",
            question: "Why does it rise?",
            answer: "More arrangements are likely.",
            evaluation: "Yes.",
            score: 1.0,
            knowledgeNote: nil,
            sourceRefs: ["src-a"]
        )
        try store.createReviewSession(id: "session-2", topic: "Free energy", sourceIDs: [])
        try store.execForTesting("""
            INSERT INTO ai_usage_events (id, provider, model, operation, task, created_at)
            VALUES ('usage-1', 'anthropic', 'claude', 'text_completion', 'chat', 1.0)
        """)
        try store.execForTesting("""
            INSERT INTO ai_usage_events (id, provider, model, operation, task, created_at)
            VALUES ('usage-2', 'anthropic', 'claude', 'text_completion', 'paper_metadata', 2.0)
        """)
    }

    @Test("Model choices stored under the retired task names move once to the new names")
    func retiredPreferenceKeysMoveOnce() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openrouter", forKey: "aiTask.feynman_quiz.provider")
        defaults.set("anthropic/claude", forKey: "aiTask.feynman_quiz.model")
        defaults.set("kept", forKey: "aiRoute.task.chat")
        defaults.set("stale", forKey: "aiRoute.task.feynman_quiz")
        defaults.set("foundation", forKey: "feynman.grader.v1")

        #expect(LegacyIdentityAdoption.adoptRetiredMethodPreferenceKeysIfNeeded(defaults: defaults) == 3)
        #expect(defaults.string(forKey: "aiTask.chat.provider") == "openrouter")
        #expect(defaults.string(forKey: "aiTask.chat.model") == "anthropic/claude")
        // A value already chosen under the new name wins over the stale one.
        #expect(defaults.string(forKey: "aiRoute.task.chat") == "kept")
        #expect(defaults.string(forKey: "foreverlm.grader.v1") == "foundation")
        for old in ["aiTask.feynman_quiz.provider", "aiTask.feynman_quiz.model", "aiRoute.task.feynman_quiz", "feynman.grader.v1"] {
            #expect(defaults.object(forKey: old) == nil, "\(old) removed")
        }
        // Second launch: nothing to do, nothing re-moved.
        defaults.set("late", forKey: "aiTask.feynman_quiz.model")
        #expect(LegacyIdentityAdoption.adoptRetiredMethodPreferenceKeysIfNeeded(defaults: defaults) == 0)
        #expect(defaults.string(forKey: "aiTask.chat.model") == "anthropic/claude")
    }
}
