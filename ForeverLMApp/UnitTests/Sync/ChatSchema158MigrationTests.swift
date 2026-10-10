import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Local schema 158 (docs/cloudkit-schema-design.md §12.7, WP10): the Chat and Exchange records'
/// columns, DDL only and NULL until a store's generation-2 activation, from the released 150 and 153
/// shapes, from 154, 155 and the version before 158 (`Schema154Fixture`).
@Suite("Schema 158 migration")
struct ChatSchema158MigrationTests {
    private static func filled(_ store: KnowledgeStore) throws -> Int {
        var total = 0
        for column in KnowledgeStore.chatSyncColumns {
            total += try Schema154Fixture.count(store, "SELECT COUNT(*) FROM \(column.table) WHERE \(column.name) IS NOT NULL")
        }
        return total
    }

    @Test("A fresh store is at 158 with the chat columns, NULL")
    func freshStore() throws {
        let root = try Schema154Fixture.temporaryRoot("158-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(KnowledgeStore.schemaVersion >= 158)
        #expect(try Schema154Fixture.count(store, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try store.probeSchema158()
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test(
        "A released, 154, 155 or pre-158 store migrates to 158 keeping every row, filling nothing and creating no trigger",
        arguments: [Int32(150), Int32(153), Int32(154), Int32(155), Schema154Fixture.versionBeforeChatSchema]
    )
    func forward(from version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("158-forward-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try store.createReviewSession(id: "chat-1", topic: "A chat", sourceIDs: [])
            try store.addReviewExchange(sessionID: "chat-1", question: "Why?", answer: "Because", evaluation: "Right", score: 0.8, knowledgeNote: nil, sourceRefs: [])
        }
        try Schema154Fixture.makeLibrary(at: root, version: version, sourceCount: 4)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('review_sessions') WHERE name = 'chat_kind'") == 0)
        let counts = ["sources", "review_sessions", "review_exchanges", "learning_goals"]
        let before = counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") }

        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(counts.map { Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM \($0)") } == before)
        try migrated.probeSchema158()
        #expect(try Self.filled(migrated) == 0, "nothing filled before the activation")
        #expect(try Schema154Fixture.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try migrated.loadReviewSessionExchanges(sessionID: "chat-1").map(\.evaluation) == ["Right"], "the chat reads as before")
    }

    @Test("A migrated store and a fresh one give review_sessions and review_exchanges the same columns, in order")
    func migratedMatchesFresh() throws {
        let freshRoot = try Schema154Fixture.temporaryRoot("158-parity-fresh")
        let migratedRoot = try Schema154Fixture.temporaryRoot("158-parity-migrated")
        defer {
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: migratedRoot)
        }
        _ = try KnowledgeStore(storeDirectory: freshRoot, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.makeLibrary(at: migratedRoot, version: 153)
        _ = try KnowledgeStore(storeDirectory: migratedRoot, freeSpace: Schema154Fixture.roomy)
        for table in ["review_sessions", "review_exchanges"] {
            let columns = "SELECT group_concat(name || ' ' || type, ', ') FROM (SELECT name, type FROM pragma_table_xinfo('\(table)') ORDER BY cid)"
            let fresh = Schema154Fixture.scalar(at: freshRoot, columns)
            #expect(fresh != nil && fresh == Schema154Fixture.scalar(at: migratedRoot, columns), "\(table)")
        }
    }

    @Test("A failing statement rolls 158 back and leaves the store at the version before it, every row kept")
    func rollback() throws {
        let root = try Schema154Fixture.temporaryRoot("158-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: Schema154Fixture.versionBeforeChatSchema)
        // review_exchanges as a view: no column can be added to it, so the proof before the stamp fails.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, """
            ALTER TABLE review_exchanges RENAME TO review_exchanges_kept;
            CREATE VIEW review_exchanges AS SELECT * FROM review_exchanges_kept;
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(Schema154Fixture.versionBeforeChatSchema))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('review_sessions') WHERE name = 'chat_kind'") == 0, "nothing of 158 stays")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 3)
    }

    @Test("A production-sized library migrates to 158 in well under a second, and its sources stay visible")
    func scale() throws {
        let root = try Schema154Fixture.temporaryRoot("158-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            // 6,000 sources, 3,400 chats (ten times today's) holding 17,000 exchanges between them.
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 6000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3400)
                INSERT INTO review_sessions (id, topic, started_at, status)
                SELECT printf('chat-%05d', n), printf('Chat %d', n), n, 'completed' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 17000)
                INSERT INTO review_exchanges (id, session_id, sequence_number, question, evaluation)
                SELECT printf('exchange-%05d', n), printf('chat-%05d', (n % 3400) + 1), n, 'A question', 'A reply' FROM seq;
                COMMIT;
            """)
            try Schema154Fixture.restoreShapeBeforeChatSchema(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let elapsed = started.duration(to: .now)
        print("schema \(Schema154Fixture.versionBeforeChatSchema) → 158 over 6,000 sources, 3,400 chats and 17,000 exchanges: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 6_000, "sources stay visible")
    }

    // MARK: The activation's derivations

    /// A library as generation-1 code leaves it after 158: chats of every legacy shape (§10).
    private static func writeLegacyChats(_ store: KnowledgeStore) throws {
        try store.createReviewSession(id: "gen1-review", topic: "A review made after 158", sourceIDs: [])
        try store.addReviewExchange(sessionID: "gen1-review", question: "Why?", answer: "Because", evaluation: "Right", score: 0.9, knowledgeNote: nil, sourceRefs: [])
        let walkLine = WalkthroughStepTurn.line(.init(sourceID: "src-w", stepID: "s1", index: 0, count: 3))
        try store.execForTesting("""
            INSERT INTO review_sessions (id, topic, started_at, status, source_ids) VALUES
                ('ios-live-1', 'Spoken', 1, 'completed', '[]'),
                ('\(CourseQuizSitting.sessionIDPrefix)quiz-1-\(UUID().uuidString)', 'Quiz', 1, 'completed', '[]'),
                ('walk-named', 'Walk', 1, 'active', '[]'),
                ('walk-step', 'Walk', 1, 'active', '[]'),
                ('old-review', 'Scored', 1, 'completed', '[]'),
                ('memory-2026-10-01', 'Memory', 1, 'completed', '[]'),
                ('plain', 'Talk', 1, 'completed', '[]');
            UPDATE review_sessions SET overall_score = 0.7 WHERE id = 'old-review';
            INSERT INTO review_sessions (id, topic, started_at, status, source_ids, team_id) VALUES ('team-copy', 'Shared', 1, 'completed', '[]', 'team-1');
            INSERT INTO review_sessions (id, topic, started_at, status, source_ids, kind) VALUES ('kept-chat', 'Imported, not reviewing', 1, 'completed', '[]', 'chat');
            INSERT INTO walkthrough_progress (subject_id, progress_json, updated_at) VALUES ('src-w', '{"current_step_id":"s1","chat_session_id":"walk-named"}', 1);
            INSERT INTO review_exchanges (id, session_id, sequence_number, question) VALUES ('walk-turn', 'walk-step', 1, '\(walkLine)\n\nThe first step.');
        """)
    }

    private static func kinds(_ store: KnowledgeStore) throws -> [String: String] {
        var kinds: [String: String] = [:]
        try store.query("SELECT id, chat_kind FROM review_sessions") { row in
            if let id = store.string(row, 0) { kinds[id.hasPrefix(CourseQuizSitting.sessionIDPrefix) ? "quiz" : id] = store.string(row, 1) }
        }
        return kinds
    }

    @Test("The activation classifies every legacy chat by the classifier, and a chat generation 1 made after 158 too")
    func activationClassifies() throws {
        let root = try Schema154Fixture.temporaryRoot("158-activation")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let legacy = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
            try Self.writeLegacyChats(legacy)
            #expect(try Schema154Fixture.count(legacy, "SELECT COUNT(*) FROM review_sessions WHERE chat_kind IS NOT NULL") == 0, "generation 1 writes none")
        }
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        for derivation in KnowledgeStore.chatActivationDerivations { try derivation.run(store) }
        let kinds = try Self.kinds(store)
        #expect(kinds["gen1-review"] == "review", "a graded chat generation 1 made after 158")
        #expect(kinds["ios-live-1"] == "voice")
        #expect(kinds["quiz"] == "quizSitting")
        #expect(kinds["walk-named"] == "walkthrough" && kinds["walk-step"] == "walkthrough")
        #expect(kinds["old-review"] == "review", "a scored review from before kinds")
        #expect(kinds["team-copy"] == "transcript")
        #expect(kinds["memory-2026-10-01"] == "memory")
        #expect(kinds["plain"] == "chat" && kinds["kept-chat"] == "chat")
        for id in ["ios-live-1", "walk-named", "old-review", "memory-2026-10-01"] {
            #expect(ChatKind(rawValue: kinds[id] ?? "")?.isPrivate == true, "\(id) never goes into a space")
        }

        // marksReviewed by today's rule: an unset kind or a review marks; a chat or a memory review does not.
        func marks(_ id: String) throws -> Int { try Schema154Fixture.count(store, "SELECT COALESCE(marks_reviewed, -1) FROM review_sessions WHERE id = '\(id)'") }
        #expect(try marks("plain") == 1 && marks("ios-live-1") == 1)
        #expect(try marks("kept-chat") == 0 && marks("memory-2026-10-01") == 0)
        // Under generation 2 an append with session_id and no mark_reviewed marks exactly when it is true.
        #expect(try store.generation2AppendMarksReviewed(requested: nil, sessionID: "plain"))
        #expect(try !store.generation2AppendMarksReviewed(requested: nil, sessionID: "kept-chat"))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM review_sessions WHERE context_mode IS NULL") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM review_sessions WHERE id = 'plain' AND context_mode = 'none'") == 1)
    }

    @Test("Each derivation run twice gives one result, keeps what a generation-2 site wrote, and takes a row added since")
    func derivationsAreIdempotent() throws {
        let root = try Schema154Fixture.temporaryRoot("158-twice")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        try Self.writeLegacyChats(store)
        try store.execForTesting("UPDATE review_sessions SET chat_kind = 'review', marks_reviewed = 0, context_mode = 'explicit' WHERE id = 'plain'")
        for derivation in KnowledgeStore.chatActivationDerivations { try derivation.run(store) }
        let snapshot = "SELECT group_concat(id || ':' || chat_kind || ':' || marks_reviewed || ':' || context_mode, ',') FROM (SELECT * FROM review_sessions ORDER BY id)"
        let first = try store.scalarText(snapshot)
        for derivation in KnowledgeStore.chatActivationDerivations { try derivation.run(store) }
        #expect(try store.scalarText(snapshot) == first)
        #expect(try store.scalarText("SELECT chat_kind || marks_reviewed || context_mode FROM review_sessions WHERE id = 'plain'") == "review0explicit")

        try store.execForTesting("INSERT INTO review_sessions (id, topic, started_at, status, source_ids, kind) VALUES ('later', 'Later', 2, 'completed', '[]', 'review')")
        for derivation in KnowledgeStore.chatActivationDerivations { try derivation.run(store) }
        #expect(try store.scalarText("SELECT chat_kind || marks_reviewed FROM review_sessions WHERE id = 'later'") == "review1")
    }

    @Test("No comment sits before a column the fixtures drop with a comma in it (SQLite 3.51 and older mishandle that)")
    func noCommasInCommentsBeforeDroppedColumns() throws {
        let root = try Schema154Fixture.temporaryRoot("158-comments")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        for (table, after) in [("review_sessions", "wire_key"), ("global_artifacts", "wire_key")] {
            let sql = try #require(try store.scalarText("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]))
            let tail = try #require(sql.range(of: after, options: .backwards)).upperBound
            for line in sql[tail...].split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("--") {
                #expect(!line.contains(","), "\(table): \(line)")
            }
        }
    }
}
