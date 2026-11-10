import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Stores for the tests that open a library from disk: a library made with today's code, either at the
/// current schema or in the shape schema 174 released (the oldest this build migrates), which is
/// today's shape with generation 1's tables back and stamped 174.
enum Schema154Fixture {
    static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Schema154-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One value through a connection of its own, read-only. A rollback copy is opened immutable, as
    /// the app reads one, so reading it creates no side file.
    static func scalar(at root: URL, _ sql: String, file: String = "knowledge.db") -> String? {
        var database: OpaquePointer?
        let path = root.appendingPathComponent(file).path
        let opened = file == "knowledge.db"
            ? sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
            : sqlite3_open_v2("file:\(path)?immutable=1", &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    static func count(at root: URL, _ sql: String, file: String = "knowledge.db") -> Int {
        Int(scalar(at: root, sql, file: file) ?? "") ?? -1
    }

    static func count(_ store: KnowledgeStore, _ sql: String) throws -> Int {
        Int(try store.scalarInteger(sql) ?? -1)
    }

    /// The per-member tables: the learner's own state about a source, which outlives the source.
    static let perMemberTableNames = [
        "source_highlights", "hidden_sources", "hidden_podcast_episodes", "visible_podcast_episode_overrides",
        "visible_youtube_video_overrides", "source_understanding", "notebook_files",
    ]

    /// Generation 1's seven tables as every released schema below 175 had them, verbatim from
    /// `createSchema` before 175. Today's code never makes them (schema 175 drops them), so a library
    /// given an older shape gets them back, empty; a test that fills them before giving the shape
    /// calls this first.
    static func restoreGeneration1Tables(_ store: KnowledgeStore) throws {
        try store.executeScript(generation1TablesSQL)
    }

    static let generation1TablesSQL = """
        CREATE TABLE IF NOT EXISTS sync_changes (entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            operation TEXT NOT NULL, changed_at REAL NOT NULL, tutor_only INTEGER NOT NULL DEFAULT 0,
            zone_scope TEXT NOT NULL DEFAULT 'private', zone_name TEXT NOT NULL DEFAULT 'Knowledge', zone_owner_record_name TEXT,
            PRIMARY KEY (entity_type, logical_key));
        CREATE TABLE IF NOT EXISTS source_sync_repair_queue (source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE, enqueued_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS review_session_sync_repair_queue (session_id TEXT PRIMARY KEY REFERENCES review_sessions(id) ON DELETE CASCADE, enqueued_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_metadata (entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            system_fields BLOB, user_modification_at REAL NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
            zone_scope TEXT NOT NULL DEFAULT 'private', zone_name TEXT NOT NULL DEFAULT 'Knowledge', zone_owner_record_name TEXT,
            PRIMARY KEY (entity_type, logical_key), UNIQUE (record_name));
        CREATE INDEX IF NOT EXISTS idx_sync_metadata_zone ON sync_metadata(zone_scope, zone_name, zone_owner_record_name);
        CREATE TABLE IF NOT EXISTS sync_conflicts (entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            reason TEXT NOT NULL, local_modification_at REAL NOT NULL, server_modification_at REAL NOT NULL, detected_at REAL NOT NULL,
            server_payload BLOB, server_system_fields BLOB,
            zone_scope TEXT NOT NULL DEFAULT 'private', zone_name TEXT NOT NULL DEFAULT 'Knowledge', zone_owner_record_name TEXT,
            PRIMARY KEY (entity_type, logical_key));
        CREATE INDEX IF NOT EXISTS idx_sync_conflicts_detected ON sync_conflicts(detected_at DESC);
        CREATE TABLE IF NOT EXISTS sync_asset_digests (record_name TEXT NOT NULL, field TEXT NOT NULL, digest TEXT, pending_digest TEXT,
            staged_attempts INTEGER NOT NULL DEFAULT 0, first_staged_at REAL, last_staged_at REAL, PRIMARY KEY (record_name, field));
        CREATE TABLE IF NOT EXISTS sync_engine_states (scope TEXT PRIMARY KEY, state_serialization BLOB);
        """

    /// Gives a store made by today's code schema 174's released shape, and stamps it.
    static func restoreSchema174Shape(_ store: KnowledgeStore) throws {
        try restoreGeneration1Tables(store)
        try store.execForTesting("PRAGMA user_version = 174")
    }

    struct Library {
        let sourceIDs: [String]
        let notebookID: String
    }

    /// Writes a source's every kind of per-member row, as the Reader, the hide filters and the day
    /// close leave them.
    static func addPerMemberRows(_ store: KnowledgeStore, sourceID: String) throws {
        try store.execForTesting("""
            INSERT INTO source_highlights (highlight_id, source_id, page_index, quads_json, text, color, note,
                created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset, publication_update)
            VALUES ('hl-\(sourceID)', '\(sourceID)', 3, '[]', 'A passage, quoted', 'yellow', 'my note', 1, 2,
                'before', 'after', 120, 'since then');
            INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('\(sourceID)', 10);
            INSERT INTO hidden_podcast_episodes (source_id, hidden_at) VALUES ('\(sourceID)', 11);
            INSERT INTO visible_podcast_episode_overrides (source_id, visible_at) VALUES ('\(sourceID)', 12);
            INSERT INTO visible_youtube_video_overrides (source_id, visible_at) VALUES ('\(sourceID)', 13);
            INSERT INTO source_understanding (source_id, relative_path, derived_through_session_id, generated_at,
                generator_version, body_sha256, open_thread_count, discussed_idea_ids)
            VALUES ('\(sourceID)', 'Understanding/\(sourceID).md', 'chat-1', 3, 2, 'abc', 1, '["idea-1"]');
        """)
    }

    /// A library of `sourceCount` articles, the first two with every kind of per-member row, and a
    /// notebook holding the first source and one workspace file; in schema 174's released shape when
    /// `version` is 174, else at the current schema.
    @discardableResult
    static func makeLibrary(at root: URL, version: Int32?, sourceCount: Int = 3) throws -> Library {
        let store = try KnowledgeStore(storeDirectory: root)
        var sourceIDs: [String] = []
        for index in 0..<sourceCount {
            var article = StudioArticle(url: "https://example.org/schema154/\(index)", title: "Paper \(index)", sourceType: .article)
            try store.insertSourceIfNew(&article)
            sourceIDs.append(article.id)
        }
        for sourceID in sourceIDs.prefix(2) {
            try addPerMemberRows(store, sourceID: sourceID)
        }
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria", topic: "Mitochondria", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: Array(sourceIDs.prefix(1))
        )
        try store.execForTesting("""
            INSERT INTO notebook_files (id, notebook_id, relative_path, name, role, content_type, size_bytes, modified_at, created_at)
            VALUES ('file-1', '\(notebook.id)', 'Projects/\(notebook.id)/data.tsv', 'data.tsv', 'file', 'text/tab-separated-values', 42, 4, 5)
        """)
        if let version {
            precondition(version == 174, "schema 174 is the oldest released shape this build opens")
            try restoreSchema174Shape(store)
        }
        return Library(sourceIDs: sourceIDs, notebookID: notebook.id)
    }
}
