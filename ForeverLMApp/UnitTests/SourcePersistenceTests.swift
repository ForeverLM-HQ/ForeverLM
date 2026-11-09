import Testing
import CloudKit
import Foundation
import SQLite3
@testable import ForeverLM

/// Creates an in-memory KnowledgeStore for unit testing.
private func makeInMemoryStore() throws -> KnowledgeStore {
    try KnowledgeStore(inMemory: true)
}

/// Helper: create a StudioArticle with sensible defaults for testing.
private func makeArticle(url: String, title: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

private func installPreparedPaperText(
    _ text: String = "Durable canonical paper text.",
    on paper: inout StudioArticle
) {
    let hash = PaperContentPreparationService.sha256(text)
    paper.installPreparedPaperContent(
        raw: text,
        clean: text,
        metadata: PaperContentPreparationMetadata(
            cleanerVersion: PaperContentPreparationMetadata.currentVersion,
            rawSHA256: hash,
            cleanSHA256: hash,
            preparedAt: Date()
        )
    )
}

/// A production-shaped v34 fixture for the v35 paper-review migration. These
/// tables use their actual released v34 definitions; missing unrelated tables
/// are created additively by the upgrader, as they would be for a supported
/// historical store that never used those features.
private func createVersion34PaperReviewFixture(
    at root: URL,
    paperCount: Int,
    incompatibleReviewQueue: Bool = false
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version34Fixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version34Fixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    let reviewQueueSQL = incompatibleReviewQueue
        ? "CREATE TABLE source_review_guide_queue (incompatible TEXT);"
        : """
          CREATE TABLE source_review_guide_queue (
              source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
              source_sha256 TEXT NOT NULL,
              enqueued_at REAL NOT NULL,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              last_error TEXT
          );
          """
    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued',
            error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article',
            existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active',
            archived_at TEXT,
            public_url TEXT,
            is_consumed INTEGER,
            reading_position_page INTEGER,
            reading_position_locator TEXT,
            connector_label TEXT,
            read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE paper_content_preparations (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            raw_content TEXT NOT NULL,
            raw_sha256 TEXT NOT NULL,
            clean_sha256 TEXT,
            cleaner_version INTEGER NOT NULL DEFAULT 0,
            prepared_at REAL
        );
        CREATE TABLE papers (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author TEXT,
            doi TEXT,
            published_doi TEXT,
            journal TEXT,
            published_year TEXT,
            is_paywalled INTEGER NOT NULL DEFAULT 0,
            paper_ingestion_method TEXT
        );
        CREATE TABLE canonical_content_cleanup_queue (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            target_version INTEGER NOT NULL,
            enqueued_at REAL NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            source_sha256 TEXT
        );
        CREATE TABLE source_review_guides (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            source_sha256 TEXT NOT NULL,
            guide TEXT NOT NULL,
            generator_version INTEGER NOT NULL,
            generated_at REAL NOT NULL
        );
        \(reviewQueueSQL)
        CREATE TABLE learning_goals (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            start_at REAL NOT NULL,
            end_at REAL NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            kind TEXT,
            description TEXT,
            topic TEXT,
            discovery_enabled INTEGER,
            daily_target INTEGER,
            last_quiz_date TEXT,
            last_discovery_at REAL,
            notes TEXT,
            parent_notebook_id TEXT,
            research_questions TEXT
        );
        CREATE TABLE learning_goal_items (
            id TEXT PRIMARY KEY,
            goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
            source_id TEXT NOT NULL,
            added_at REAL NOT NULL,
            completed_at REAL,
            origin TEXT,
            review_state TEXT,
            relevance REAL,
            last_quizzed_at REAL,
            quiz_count INTEGER,
            last_score REAL,
            sequence REAL,
            UNIQUE(goal_id, source_id)
        );
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            operation TEXT NOT NULL,
            changed_at REAL NOT NULL,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            system_fields BLOB,
            user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key),
            UNIQUE (record_name)
        );
        COMMIT;
        """)

    try exec("BEGIN IMMEDIATE;")
    do {
        for index in 0..<paperCount {
            let sourceID = String(format: "paper-%05d", index)
            let clean = "Clean canonical paper body \(index)."
            let raw = "Publisher header \(index).\n\n\(clean)\n\nReferences\nCitation noise."
            let rawHash = PaperContentPreparationService.sha256(raw)
            let cleanHash = PaperContentPreparationService.sha256(clean)
            try exec("""
                INSERT INTO sources (id, date_added, state, source_type, status)
                VALUES ('\(sourceID)', \(index), 'ready', 'paper', 'active');
                INSERT INTO source_content (source_id, content)
                VALUES ('\(sourceID)', '\(clean)');
                INSERT INTO paper_content_preparations
                    (source_id, raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at)
                VALUES ('\(sourceID)', '\(raw)', '\(rawHash)', '\(cleanHash)',
                        \(PaperContentPreparationMetadata.currentVersion), 1);
                INSERT INTO papers (source_id, url, normalized_url, title, author, journal, published_year)
                VALUES ('\(sourceID)', 'https://example.com/\(sourceID)',
                        'https://example.com/\(sourceID)', 'Paper \(index)',
                        'Researcher', 'Journal', '2026');
                """)
        }
        if paperCount > 0 {
            let clean = "Clean canonical paper body 0."
            let cleanHash = PaperContentPreparationService.sha256(clean)
            try exec("""
                INSERT INTO source_review_guides
                    (source_id, source_sha256, guide, generator_version, generated_at)
                VALUES ('paper-00000', '\(cleanHash)', 'Legacy DeepSeek guide', 1, 1);
                INSERT INTO learning_goals
                    (id, title, start_at, end_at, created_at, updated_at, status)
                VALUES ('goal-1', 'Migration Goal', 1, 2, 1, 1, 'active');
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at)
                VALUES ('item-1', 'goal-1', 'paper-00000', 1);
                INSERT INTO sync_metadata
                    (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                VALUES ('source', 'paper-00000', 'source-paper-00000', 1, 0);
                INSERT INTO sync_changes
                    (entity_type, logical_key, record_name, operation, changed_at)
                VALUES ('source', 'paper-00000', 'source-paper-00000', 'save', 1);
                """)
        }
        if !incompatibleReviewQueue {
            try exec("""
                INSERT INTO sources (id, date_added, state, source_type, status)
                VALUES ('video-pending', 0, 'ready', 'video', 'active');
                INSERT INTO source_content (source_id, content)
                VALUES ('video-pending', 'Video source text.');
                INSERT INTO source_review_guide_queue
                    (source_id, source_sha256, enqueued_at, attempt_count)
                VALUES ('video-pending', 'legacy', 1, 0);
                """)
        }
        try exec("PRAGMA user_version = 34; COMMIT;")
    } catch {
        try? exec("ROLLBACK;")
        throw error
    }
}

/// Starts from the released v34 table definitions above and adds the one table
/// present by v35, yielding the actual v36 repair surface. The v35 paper-review
/// and v36 text-presence migrations have already completed for stores at this
/// version; unrelated feature tables remain additive just as they do in a
/// supported sparse store.
private func promoteFixtureToVersion36(
    at root: URL,
    incompatibleSourceRepairQueue: Bool = false
) throws {
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version36Fixture", code: 1)
    }
    defer { sqlite3_close(database) }

    let queueSQL = incompatibleSourceRepairQueue
        ? "CREATE TABLE source_sync_repair_queue (incompatible TEXT);"
        : """
          CREATE TABLE source_sync_repair_queue (
              source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
              enqueued_at REAL NOT NULL
          );
          """
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(
        database,
        "BEGIN IMMEDIATE; \(queueSQL) PRAGMA user_version = 36; COMMIT;",
        nil,
        nil,
        &message
    )
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "Version36Fixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// Version 40 did not change the paper/source relationship shape inherited from
/// the production v34 fixture. Add the released v36 repair queue, attach portable
/// PDF paths, and advance only the version stamp so the v41 test exercises the
/// real pre-figure-index surface rather than today's schema with a lowered number.
private func promoteFixtureToVersion40(
    at root: URL,
    incompatibleFigureQueue: Bool = false
) throws {
    try promoteFixtureToVersion36(at: root)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version40Fixture", code: 1)
    }
    defer { sqlite3_close(database) }

    let incompatibleSQL = incompatibleFigureQueue
        ? "CREATE TABLE paper_figure_index_queue (incompatible TEXT);"
        : ""
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, """
        BEGIN IMMEDIATE;
        UPDATE papers
        SET local_file_path = 'Papers/' || source_id || '.pdf';
        \(incompatibleSQL)
        PRAGMA user_version = 40;
        COMMIT;
        """, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "Version40Fixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// A production-shaped v74 fixture for the v75 figure-image retirement.
///
/// Builds the *released* v74 figure surface: `paper_figures` still carries the
/// `image_path NOT NULL` column, and canonical text still ends in the block of
/// absolute `file://` image links that PDF extraction used to append. Creating
/// today's schema and lowering the version stamp would test neither.
private func promoteFixtureToVersion74(
    at root: URL,
    figurePaperCount: Int = 1,
    incompatibleMarkdownRepairQueue: Bool = false
) throws {
    try promoteFixtureToVersion40(at: root)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version74Fixture", code: 1)
    }
    defer { sqlite3_close(database) }

    var statements = """
        BEGIN IMMEDIATE;
        CREATE TABLE paper_figures (
            figure_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            figure_label TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            caption TEXT NOT NULL,
            image_path TEXT NOT NULL,
            analysis_json TEXT,
            UNIQUE(source_id, figure_label, page_index)
        );
        CREATE TABLE paper_figure_index_state (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            pdf_path TEXT NOT NULL,
            index_version INTEGER NOT NULL,
            page_count INTEGER NOT NULL,
            indexed_at REAL NOT NULL
        );
        """
    if incompatibleMarkdownRepairQueue {
        statements += "CREATE TABLE paper_figure_markdown_repair_queue (incompatible TEXT);\n"
    }
    for index in 0..<figurePaperCount {
        let sourceID = String(format: "paper-%05d", index)
        let body = "Clean canonical paper body \(index)."
        let legacy = body
            + "\n\n## Figures\n\n"
            + "![Figure 1 | Response over time.]"
            + "(file:///Users/someone/Library/Application%20Support/ForeverLM/Content/Papers/"
            + "Figures/\(sourceID)/page-0003.jpg)"
        let escaped = legacy.replacingOccurrences(of: "'", with: "''")
        statements += """
            INSERT INTO paper_figures
                (figure_id, source_id, figure_label, page_index, caption, image_path, analysis_json)
            VALUES ('fig_\(sourceID)', '\(sourceID)', 'Figure 1', 2, 'Figure 1 | Response over time.',
                    'Papers/Figures/\(sourceID)/page-0003.jpg', NULL);
            UPDATE source_content SET content = '\(escaped)' WHERE source_id = '\(sourceID)';
            """
    }
    statements += "\nPRAGMA user_version = 74;\nCOMMIT;"

    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, statements, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "Version74Fixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// A production-shaped v43 fixture for the v44 listenable-queue policy change.
/// Version 43 introduced these exact tables; unrelated feature tables are
/// intentionally absent and are installed additively by the upgrader, matching a
/// released store that never populated those features.
private func createVersion43ListenableFixture(
    at root: URL,
    sourceCounts: [StudioSourceType: Int],
    failQueueRetirement: Bool = false
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version43ListenableFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version43ListenableFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued',
            error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article',
            existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active',
            archived_at TEXT,
            public_url TEXT,
            is_consumed INTEGER,
            reading_position_page INTEGER,
            reading_position_locator TEXT,
            connector_label TEXT,
            read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE articles (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author TEXT
        );
        CREATE TABLE papers (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author TEXT,
            doi TEXT,
            published_doi TEXT,
            journal TEXT,
            published_year TEXT,
            is_paywalled INTEGER NOT NULL DEFAULT 0,
            paper_ingestion_method TEXT
        );
        CREATE TABLE book_sources (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT
        );
        CREATE TABLE course_sources (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT
        );
        CREATE TABLE meeting_sources (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            occurred_at REAL,
            transcript_status TEXT,
            presenter TEXT
        );
        CREATE TABLE x_posts (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author_handle TEXT,
            post_text TEXT
        );
        CREATE TABLE slack_messages (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author TEXT,
            workspace TEXT,
            channel TEXT
        );
        CREATE TABLE source_listenable_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            source_sha256 TEXT NOT NULL,
            content TEXT NOT NULL,
            generator_version INTEGER NOT NULL,
            preparation_signature TEXT,
            prepared_at REAL NOT NULL
        );
        CREATE TABLE source_listenable_content_queue (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            target_version INTEGER NOT NULL,
            source_sha256 TEXT,
            enqueued_at REAL NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT
        );
        CREATE INDEX idx_source_listenable_content_queue_order
        ON source_listenable_content_queue(enqueued_at, source_id);
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            operation TEXT NOT NULL,
            changed_at REAL NOT NULL,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            system_fields BLOB,
            user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key),
            UNIQUE (record_name)
        );
        CREATE TABLE learning_goals (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            start_at REAL NOT NULL,
            end_at REAL NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            kind TEXT,
            description TEXT,
            topic TEXT,
            discovery_enabled INTEGER,
            daily_target INTEGER,
            last_quiz_date TEXT,
            last_discovery_at REAL,
            notes TEXT,
            parent_notebook_id TEXT,
            research_questions TEXT
        );
        CREATE TABLE learning_goal_items (
            id TEXT PRIMARY KEY,
            goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
            source_id TEXT NOT NULL,
            added_at REAL NOT NULL,
            completed_at REAL,
            origin TEXT,
            review_state TEXT,
            relevance REAL,
            last_quizzed_at REAL,
            quiz_count INTEGER,
            last_score REAL,
            sequence REAL,
            UNIQUE(goal_id, source_id)
        );
        COMMIT;
        """)

    let firstLogicalKey = sourceCounts
        .filter { $0.value > 0 }
        .map { $0.key.rawValue }
        .sorted()
        .first
        .map { "\($0)-00001" }

    try exec("BEGIN IMMEDIATE;")
    do {
        for (sourceType, count) in sourceCounts where count > 0 {
            let prefix = sourceType.rawValue
            let subtypeTable: String
            switch sourceType {
            case .article: subtypeTable = "articles"
            case .paper: subtypeTable = "papers"
            case .book: subtypeTable = "book_sources"
            case .course: subtypeTable = "course_sources"
            case .meeting: subtypeTable = "meeting_sources"
            case .xPost: subtypeTable = "x_posts"
            default:
                throw NSError(domain: "Version43ListenableFixture", code: 3)
            }
            try exec("""
                WITH RECURSIVE ids(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM ids WHERE n < \(count)
                )
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT '\(prefix)-' || printf('%05d', n), n, 'ready', '\(sourceType.rawValue)', 'active'
                FROM ids;
                INSERT INTO source_content (source_id, content)
                SELECT id, 'Durable canonical text for ' || id || '.'
                FROM sources WHERE source_type = '\(sourceType.rawValue)';
                INSERT INTO \(subtypeTable) (source_id, url, normalized_url, title, domain)
                SELECT id, 'https://example.com/' || id, 'https://example.com/' || id,
                       'Fixture ' || id, 'example.com'
                FROM sources WHERE source_type = '\(sourceType.rawValue)';
                INSERT INTO source_listenable_content_queue
                    (source_id, target_version, source_sha256, enqueued_at, attempt_count)
                SELECT id, 1, NULL, date_added, 0
                FROM sources WHERE source_type = '\(sourceType.rawValue)';
                """)
        }
        if sourceCounts[.book, default: 0] > 0 {
            try exec("""
                INSERT INTO source_listenable_content
                    (source_id, source_sha256, content, generator_version, preparation_signature, prepared_at)
                VALUES ('book-00001', 'legacy-hash', 'Already prepared book narration.', 1, NULL, 1);
                """)
        }
        if let firstLogicalKey {
            try exec("""
                INSERT INTO sync_metadata
                    (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                VALUES ('source', '\(firstLogicalKey)', 'source-\(firstLogicalKey)', 1, 0);
                INSERT INTO sync_changes
                    (entity_type, logical_key, record_name, operation, changed_at)
                VALUES ('source', '\(firstLogicalKey)', 'source-\(firstLogicalKey)', 'save', 1);
                INSERT INTO learning_goals
                    (id, title, start_at, end_at, created_at, updated_at, status)
                VALUES ('goal-1', 'Migration Goal', 1, 2, 1, 1, 'active');
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, sequence)
                VALUES ('item-1', 'goal-1', '\(firstLogicalKey)', 1, 1);
                """)
        }
        if failQueueRetirement {
            try exec("""
                CREATE TRIGGER fail_v44_queue_retirement
                BEFORE DELETE ON source_listenable_content_queue
                WHEN OLD.source_id = 'book-00001'
                BEGIN
                    SELECT RAISE(ABORT, 'injected v44 queue retirement failure');
                END;
                """)
        }
        try exec("PRAGMA user_version = 43; COMMIT;")
    } catch {
        try? exec("ROLLBACK;")
        throw error
    }
}

/// A released v44 store in which article and paper derivatives have already
/// drained. Version 45 must preserve them for immediate launch while durably
/// requeueing only papers for the new sidebar-ordering contract.
private func createVersion44PreparedNarrationFixture(
    at root: URL,
    articleCount: Int,
    paperCount: Int,
    bookCount: Int = 0,
    startingVersion: Int = 44,
    paperCleanerVersion: Int = 8,
    failPaperRequeue: Bool = false,
    failCanonicalRequeue: Bool = false
) throws {
    try createVersion43ListenableFixture(
        at: root,
        sourceCounts: [
            .article: articleCount,
            .paper: paperCount,
            .book: bookCount,
        ]
    )

    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version44PreparedNarrationFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version44PreparedNarrationFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        BEGIN IMMEDIATE;
        DELETE FROM source_listenable_content_queue;
        CREATE TABLE IF NOT EXISTS paper_content_preparations (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            raw_content TEXT NOT NULL,
            raw_sha256 TEXT NOT NULL,
            clean_sha256 TEXT,
            cleaner_version INTEGER NOT NULL DEFAULT 0,
            prepared_at REAL
        );
        CREATE TABLE IF NOT EXISTS canonical_content_cleanup_queue (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            target_version INTEGER NOT NULL,
            enqueued_at REAL NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            source_sha256 TEXT
        );
        INSERT INTO paper_content_preparations
            (source_id, raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at)
        SELECT id,
               'Raw extraction with a boxed sidebar for ' || id || '.',
               'raw-hash-' || id,
               'clean-hash-' || id,
               \(paperCleanerVersion),
               1
        FROM sources
        WHERE source_type = 'paper';
        INSERT INTO source_listenable_content
            (source_id, source_sha256, content, generator_version, preparation_signature, prepared_at)
        SELECT id,
               'old-hash-' || id,
               'Previously prepared narration for ' || id || '.',
               1,
               CASE WHEN source_type = 'paper' THEN 'old-paper-contract' ELSE NULL END,
               1
        FROM sources
        WHERE source_type IN ('article', 'paper');
        PRAGMA user_version = \(startingVersion);
        COMMIT;
        """)

    if failPaperRequeue {
        try exec("""
            CREATE TRIGGER fail_v45_paper_requeue
            BEFORE INSERT ON source_listenable_content_queue
            WHEN NEW.source_id = 'paper-00001'
            BEGIN
                SELECT RAISE(ABORT, 'injected v45 paper requeue failure');
            END;
        """)
    }
    if failCanonicalRequeue {
        try exec("""
            CREATE TRIGGER fail_v46_canonical_requeue
            BEFORE INSERT ON canonical_content_cleanup_queue
            WHEN NEW.source_id = 'paper-00001'
            BEGIN
                SELECT RAISE(ABORT, 'injected v46 canonical requeue failure');
            END;
            """)
    }
}

/// A production-shaped v56 store after the bounded v55 cleanup queue has
/// drained and v56 has staged stale paper narration for deferred replacement.
/// Versions 45–56 added queues and data repairs to the released v44 tables, not
/// new source tables, so this fixture applies that final released queue state
/// explicitly instead of stamping today's schema with an older version number.
private func createVersion56HighlightsFixture(
    at root: URL,
    articleCount: Int,
    paperCount: Int,
    bookCount: Int = 0
) throws {
    try createVersion44PreparedNarrationFixture(
        at: root,
        articleCount: articleCount,
        paperCount: paperCount,
        bookCount: bookCount,
        paperCleanerVersion: PaperContentPreparationMetadata.currentVersion
    )

    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version56HighlightsFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, """
        BEGIN IMMEDIATE;
        DELETE FROM canonical_content_cleanup_queue;
        DELETE FROM source_listenable_content_queue;
        INSERT INTO source_listenable_content_queue
            (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
        SELECT s.id,
               \(SourceListenableContentMetadata.currentVersion),
               pp.clean_sha256,
               1,
               0,
               NULL
        FROM sources s
        JOIN paper_content_preparations pp ON pp.source_id = s.id
        WHERE s.source_type = 'paper';
        PRAGMA user_version = 56;
        COMMIT;
        """, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "Version56HighlightsFixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// A production-shaped v57 database: start from the released v56 tables/queues,
/// then install the exact v57 highlight table and index before stamping 57. This
/// deliberately does not create today's schema and lower `user_version`.
private func createVersion57MemoryTutorFixture(
    at root: URL,
    articleCount: Int,
    paperCount: Int,
    bookCount: Int = 0
) throws {
    try createVersion56HighlightsFixture(
        at: root,
        articleCount: articleCount,
        paperCount: paperCount,
        bookCount: bookCount
    )

    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version57MemoryTutorFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, """
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE source_highlights (
            highlight_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            quads_json TEXT NOT NULL,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            note TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_source_highlights_source_page
        ON source_highlights(source_id, page_index, created_at);
        CREATE TABLE courses (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            course_code TEXT,
            institution TEXT,
            instructors TEXT,
            playlist_url TEXT,
            is_hidden INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO source_highlights (
            highlight_id, source_id, page_index, quads_json, text, color,
            note, created_at, updated_at
        )
        SELECT 'fixture-highlight', id, 0, '[]', 'Existing annotation',
               'yellow', NULL, 1, 1
        FROM sources
        ORDER BY id
        LIMIT 1;
        PRAGMA user_version = 57;
        COMMIT;
        """, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "Version57MemoryTutorFixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// A production-shaped v58 database from the release window where Schedule
/// portable-identity columns existed but their lookup indexes did not. Version
/// 59 must add those indexes before any save can force them with `INDEXED BY`.
private func createVersion58ScheduledIdentityFixture(
    at root: URL,
    sourceCount: Int,
    conflictingIndexName: String? = nil
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version58ScheduledIdentityFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version58ScheduledIdentityFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued',
            error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article',
            existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active',
            archived_at TEXT,
            public_url TEXT,
            is_consumed INTEGER,
            reading_position_page INTEGER,
            reading_position_locator TEXT,
            connector_label TEXT,
            read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE articles (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author TEXT
        );
        CREATE TABLE scheduled_sources (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL UNIQUE,
            source_url TEXT,
            source_normalized_url TEXT,
            source_doi TEXT,
            source_published_doi TEXT,
            planned_at REAL NOT NULL,
            added_at REAL NOT NULL,
            completed_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_scheduled_sources_source ON scheduled_sources(source_id);
        CREATE INDEX idx_scheduled_sources_planned ON scheduled_sources(planned_at);
        CREATE TABLE scheduled_source_goals (
            scheduled_source_id TEXT NOT NULL,
            goal_id TEXT NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY (scheduled_source_id, goal_id)
        );
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            operation TEXT NOT NULL,
            changed_at REAL NOT NULL,
            tutor_only INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            system_fields BLOB,
            user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key),
            UNIQUE (record_name)
        );
        WITH RECURSIVE ids(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM ids WHERE n < \(sourceCount)
        )
        INSERT INTO sources (id, date_added, state, source_type, status)
        SELECT 'article-' || printf('%05d', n), n, 'ready', 'article', 'active'
        FROM ids;
        INSERT INTO source_content (source_id, content)
        SELECT id, 'Existing source text for ' || id FROM sources;
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        SELECT id,
               'https://example.com/' || id,
               'https://example.com/' || id,
               'Existing ' || id,
               'example.com'
        FROM sources;
        INSERT INTO scheduled_sources (
            id, source_id, source_url, source_normalized_url,
            planned_at, added_at, completed_at, created_at, updated_at
        )
        SELECT 'schedule-' || id,
               id,
               'https://example.com/' || id,
               'https://example.com/' || id,
               date_added,
               date_added,
               NULL,
               date_added,
               date_added
        FROM sources;
        INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
        SELECT id, 'goal-1', added_at FROM scheduled_sources;
        INSERT INTO sync_metadata (
            entity_type, logical_key, record_name, user_modification_at, is_deleted
        ) VALUES ('source', 'article-00001', 'source-article-00001', 1, 0);
        INSERT INTO sync_changes (
            entity_type, logical_key, record_name, operation, changed_at, tutor_only
        ) VALUES ('source', 'article-00001', 'source-article-00001', 'save', 1, 0);
        PRAGMA user_version = 58;
        COMMIT;
        """)

    if let conflictingIndexName {
        try exec("CREATE TABLE \(conflictingIndexName) (sentinel TEXT)")
    }
}

/// A production-shaped v59 database for the v60 reader-note anchor migration.
/// The relevant released tables retain their exact v59 shape: highlights have
/// PDF geometry and note text, but no portable text-quote context columns yet.
private func createVersion59ReaderNotesFixture(
    at root: URL,
    sourceCount: Int,
    conflictWithHighlightIndex: Bool = false
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version59ReaderNotesFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version59ReaderNotesFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued',
            error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article',
            existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active',
            archived_at TEXT,
            public_url TEXT,
            is_consumed INTEGER,
            reading_position_page INTEGER,
            reading_position_locator TEXT,
            connector_label TEXT,
            read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE articles (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            local_file_path TEXT,
            normalized_url TEXT,
            title TEXT,
            domain TEXT NOT NULL DEFAULT '',
            discovery_origin TEXT,
            word_count INTEGER,
            artwork_url TEXT,
            author TEXT
        );
        CREATE TABLE source_highlights (
            highlight_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            quads_json TEXT NOT NULL,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            note TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_source_highlights_source_page
        ON source_highlights(source_id, page_index, created_at);
        CREATE TABLE courses (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            course_code TEXT,
            institution TEXT,
            instructors TEXT,
            playlist_url TEXT,
            is_hidden INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            operation TEXT NOT NULL,
            changed_at REAL NOT NULL,
            tutor_only INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            record_name TEXT NOT NULL,
            system_fields BLOB,
            user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key),
            UNIQUE (record_name)
        );
        WITH RECURSIVE ids(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM ids WHERE n < \(sourceCount)
        )
        INSERT INTO sources (id, date_added, state, source_type, status)
        SELECT 'article-' || printf('%05d', n), n, 'ready', 'article', 'active'
        FROM ids;
        INSERT INTO source_content (source_id, content)
        SELECT id, 'Existing source text for ' || id FROM sources;
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        SELECT id,
               'https://example.com/' || id,
               'https://example.com/' || id,
               'Existing ' || id,
               'example.com'
        FROM sources;
        INSERT INTO source_highlights (
            highlight_id, source_id, page_index, quads_json, text, color,
            note, created_at, updated_at
        )
        SELECT 'highlight-' || id, id, 0, '[]', 'Existing annotation for ' || id,
               'yellow', 'Existing note', date_added, date_added
        FROM sources;
        INSERT INTO courses (
            id, title, course_code, institution, instructors, playlist_url, is_hidden
        ) VALUES (
            'course-existing', 'Existing Course', 'CS-59', 'Fixture University',
            'Ada Example', 'https://www.youtube.com/playlist?list=PLfixture', 0
        );
        INSERT INTO sync_metadata (
            entity_type, logical_key, record_name, user_modification_at, is_deleted
        ) VALUES ('source', 'article-00001', 'source-article-00001', 1, 0);
        INSERT INTO sync_changes (
            entity_type, logical_key, record_name, operation, changed_at, tutor_only
        ) VALUES ('source', 'article-00001', 'source-article-00001', 'save', 1, 0);
        PRAGMA user_version = 59;
        COMMIT;
        """)

    if conflictWithHighlightIndex {
        try exec("DROP INDEX idx_source_highlights_source_page")
        try exec("CREATE TABLE idx_source_highlights_source_page (sentinel TEXT)")
    }
}

/// Production-shaped v60 storage for the v62 global-artifact migration. It
/// includes the released, unrelated `artifacts` table that exposed the v61 name
/// collision, plus populated Notebook files to prove migration does not scan,
/// move, reinterpret, or hide existing user data at launch.
private func createVersion60ArtifactFixture(
    at root: URL,
    sourceCount: Int,
    notebookFileCount: Int,
    conflictingGlobalArtifactIndex: Bool = false
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version60ArtifactFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version60ArtifactFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY, date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued', error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article', existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active', archived_at TEXT, public_url TEXT,
            is_consumed INTEGER, reading_position_page INTEGER, reading_position_locator TEXT,
            connector_label TEXT, read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE articles (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL, local_file_path TEXT, normalized_url TEXT, title TEXT,
            domain TEXT NOT NULL DEFAULT '', discovery_origin TEXT, word_count INTEGER,
            artwork_url TEXT, author TEXT
        );
        CREATE TABLE learning_goals (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, start_at REAL NOT NULL,
            end_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'active', kind TEXT, description TEXT, topic TEXT,
            discovery_enabled INTEGER, daily_target INTEGER, last_quiz_date TEXT,
            last_discovery_at REAL, notes TEXT, parent_notebook_id TEXT, research_questions TEXT
        );
        CREATE TABLE learning_goal_items (
            id TEXT PRIMARY KEY,
            goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
            source_id TEXT NOT NULL, added_at REAL NOT NULL, completed_at REAL,
            origin TEXT, review_state TEXT, relevance REAL, last_quizzed_at REAL,
            quiz_count INTEGER, last_score REAL, sequence REAL,
            UNIQUE(goal_id, source_id)
        );
        CREATE TABLE notebook_files (
            id TEXT PRIMARY KEY,
            notebook_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL,
            content_type TEXT, size_bytes INTEGER NOT NULL DEFAULT 0,
            modified_at REAL NOT NULL, created_at REAL NOT NULL,
            UNIQUE(notebook_id, relative_path)
        );
        CREATE TABLE artifacts (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            source_ids TEXT NOT NULL DEFAULT '[]',
            generated_at REAL NOT NULL,
            imported_card_ids TEXT NOT NULL DEFAULT '{}',
            audio_file_path TEXT
        );
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            operation TEXT NOT NULL, changed_at REAL NOT NULL,
            tutor_only INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            system_fields BLOB, user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key), UNIQUE (record_name)
        );
        INSERT INTO learning_goals (
            id, title, start_at, end_at, created_at, updated_at, status, kind, topic
        ) VALUES ('notebook-1', 'Existing Notebook', 1, 32503680000, 1, 1, 'active', 'companion', 'existing');
        WITH RECURSIVE ids(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM ids WHERE n < \(sourceCount)
        )
        INSERT INTO sources (id, date_added, state, source_type, status)
        SELECT 'article-' || printf('%05d', n), n, 'ready', 'article', 'active' FROM ids;
        INSERT INTO source_content (source_id, content)
        SELECT id, 'Existing source text for ' || id FROM sources;
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        SELECT id, 'https://example.com/' || id, 'https://example.com/' || id,
               'Existing ' || id, 'example.com' FROM sources;
        INSERT INTO learning_goal_items (id, goal_id, source_id, added_at)
        VALUES ('item-1', 'notebook-1', 'article-00001', 1);
        INSERT INTO artifacts (
            id, type, title, content, source_ids, generated_at
        ) VALUES (
            'legacy-artifact-1', 'study-guide', 'Existing Study Guide',
            'Legacy artifact content must remain untouched.', '["article-00001"]', 1
        );
        WITH RECURSIVE files(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM files WHERE n < \(notebookFileCount)
        )
        INSERT INTO notebook_files (
            id, notebook_id, relative_path, name, role, content_type,
            size_bytes, modified_at, created_at
        )
        SELECT 'file-' || printf('%05d', n), 'notebook-1',
               'Projects/notebook-1/Draft-' || printf('%05d', n) || '.md',
               'Draft-' || printf('%05d', n) || '.md', 'file', 'text/markdown',
               100, n, n FROM files;
        INSERT INTO sync_metadata (
            entity_type, logical_key, record_name, user_modification_at, is_deleted
        ) VALUES ('source', 'article-00001', 'source-article-00001', 1, 0);
        INSERT INTO sync_changes (
            entity_type, logical_key, record_name, operation, changed_at, tutor_only
        ) VALUES ('source', 'article-00001', 'source-article-00001', 'save', 1, 0);
        PRAGMA user_version = 60;
        COMMIT;
        """)

    if conflictingGlobalArtifactIndex {
        try exec("CREATE TABLE idx_global_artifacts_updated (sentinel TEXT)")
    }
}

/// A successful v61 database could only come from an install without the retired
/// legacy `artifacts` table. Its v61 migration added exactly these two tables on
/// top of v60; v62 must carry their rows and complete Notebook link set forward.
private func createVersion61GlobalArtifactFixture(
    at root: URL,
    conflictingGlobalArtifactIndex: Bool = false
) throws {
    try createVersion60ArtifactFixture(at: root, sourceCount: 2, notebookFileCount: 2)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version61GlobalArtifactFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version61GlobalArtifactFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        BEGIN IMMEDIATE;
        DROP TABLE artifacts;
        CREATE TABLE artifacts (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            home_project_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_artifacts_updated ON artifacts(updated_at DESC, id);
        CREATE INDEX idx_artifacts_home_project ON artifacts(home_project_id, updated_at DESC);
        CREATE TABLE artifact_project_links (
            artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
            project_id TEXT NOT NULL,
            linked_at REAL NOT NULL,
            PRIMARY KEY (artifact_id, project_id)
        );
        CREATE INDEX idx_artifact_project_links_project
            ON artifact_project_links(project_id, artifact_id);
        INSERT INTO artifacts (
            id, title, home_project_id, created_at, updated_at
        ) VALUES ('v61-global-artifact', 'Existing Global Draft', 'notebook-1', 2, 3);
        INSERT INTO artifact_project_links (artifact_id, project_id, linked_at)
        VALUES ('v61-global-artifact', 'notebook-1', 3);
        PRAGMA user_version = 61;
        COMMIT;
        """)

    if conflictingGlobalArtifactIndex {
        try exec("CREATE TABLE idx_global_artifacts_updated (sentinel TEXT)")
    }
}

/// Production-shaped v62 storage for the v63 automatic source-activity table.
/// The released Schedule shape and its sync rows are populated so the migration
/// proves it is additive and does not reinterpret or republish existing plans.
private func createVersion62SourceActivityFixture(
    at root: URL,
    sourceCount: Int,
    conflictingActivityIndex: Bool = false
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "Version62SourceActivityFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "Version62SourceActivityFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY, date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued', error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article', existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active', archived_at TEXT, public_url TEXT,
            is_consumed INTEGER, reading_position_page INTEGER, reading_position_locator TEXT,
            connector_label TEXT, read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE articles (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL, local_file_path TEXT, normalized_url TEXT, title TEXT,
            domain TEXT NOT NULL DEFAULT '', discovery_origin TEXT, word_count INTEGER,
            artwork_url TEXT, author TEXT
        );
        CREATE TABLE scheduled_sources (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL UNIQUE,
            source_url TEXT, source_normalized_url TEXT, source_doi TEXT,
            source_published_doi TEXT, planned_at REAL NOT NULL, added_at REAL NOT NULL,
            completed_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE INDEX idx_scheduled_sources_source ON scheduled_sources(source_id);
        CREATE INDEX idx_scheduled_sources_planned ON scheduled_sources(planned_at);
        CREATE INDEX idx_scheduled_sources_identity_url ON scheduled_sources(source_normalized_url);
        CREATE INDEX idx_scheduled_sources_identity_doi ON scheduled_sources(source_doi);
        CREATE INDEX idx_scheduled_sources_identity_published_doi ON scheduled_sources(source_published_doi);
        CREATE TABLE scheduled_source_goals (
            scheduled_source_id TEXT NOT NULL, goal_id TEXT NOT NULL, added_at REAL NOT NULL,
            PRIMARY KEY (scheduled_source_id, goal_id)
        );
        CREATE INDEX idx_ssg_goal ON scheduled_source_goals(goal_id);
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            operation TEXT NOT NULL, changed_at REAL NOT NULL,
            tutor_only INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            system_fields BLOB, user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key), UNIQUE(record_name)
        );
        WITH RECURSIVE ids(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM ids WHERE n < \(sourceCount)
        )
        INSERT INTO sources (id, date_added, state, source_type, status)
        SELECT 'source-' || printf('%05d', n), n, 'ready', 'article', 'active' FROM ids;
        INSERT INTO source_content (source_id, content)
        SELECT id, 'Existing source text for ' || id FROM sources;
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        SELECT id, 'https://example.com/' || id, 'https://example.com/' || id,
               'Existing ' || id, 'example.com' FROM sources;
        INSERT INTO scheduled_sources (
            id, source_id, source_normalized_url, planned_at, added_at,
            completed_at, created_at, updated_at
        )
        SELECT 'placement-' || id, id, 'https://example.com/' || id,
               date_added, date_added, NULL, date_added, date_added FROM sources;
        INSERT INTO sync_metadata (
            entity_type, logical_key, record_name, user_modification_at, is_deleted
        ) VALUES ('scheduledSource', 'placement-source-00001', 'scheduled-source-1', 1, 0);
        INSERT INTO sync_changes (
            entity_type, logical_key, record_name, operation, changed_at, tutor_only
        ) VALUES ('scheduledSource', 'placement-source-00001', 'scheduled-source-1', 'save', 1, 1);
        PRAGMA user_version = 62;
        COMMIT;
        """)

    if conflictingActivityIndex {
        try exec("CREATE TABLE idx_source_activity_days_source_day (sentinel TEXT)")
    }
}

/// Production-observed v63 shape: source activity storage exists and the
/// version stamp is current for that build, but scheduled_sources is missing
/// is_automatic. This exact drift made review completion roll back while trying
/// to record the reviewed source on Schedule.
private func createMalformedVersion63SourceActivityFixture(
    at root: URL,
    sourceCount: Int,
    conflictingPlacementIndex: Bool = false
) throws {
    try createVersion62SourceActivityFixture(at: root, sourceCount: sourceCount)

    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "MalformedVersion63SourceActivityFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "MalformedVersion63SourceActivityFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        BEGIN IMMEDIATE;
        CREATE TABLE source_activity_days (
            id TEXT PRIMARY KEY,
            scheduled_source_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            day_start REAL NOT NULL,
            first_activity_at REAL NOT NULL,
            last_activity_at REAL NOT NULL,
            kinds INTEGER NOT NULL,
            completed_kinds INTEGER NOT NULL,
            UNIQUE(source_id, day_start)
        );
        CREATE INDEX idx_source_activity_days_source_day
            ON source_activity_days(source_id, day_start);
        INSERT INTO scheduled_source_goals (
            scheduled_source_id, goal_id, added_at
        ) VALUES ('placement-source-00001', 'goal-preserved', 1);
        PRAGMA user_version = 63;
        COMMIT;
        """)

    if conflictingPlacementIndex {
        try exec("CREATE TABLE idx_source_activity_days_placement (sentinel TEXT)")
    } else {
        try exec("""
            CREATE INDEX idx_source_activity_days_placement
                ON source_activity_days(scheduled_source_id)
            """)
    }
}

@Suite("Source Persistence")
struct SourcePersistenceTests {

    @Test("Paper figure index persists portable page relationships and invalidates with the PDF")
    func paperFigureIndexLifecycle() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/visual-paper",
            title: "Visual Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        paper.localFilePath = "Papers/visual-paper.pdf"
        installPreparedPaperText(on: &paper)
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)

        #expect(try store.paperFigureIndexQueueCount() == 1)
        let candidate = try #require(try store.nextPaperFigureIndexCandidate())
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.pdfPath == "Papers/visual-paper.pdf")

        let figure = PaperFigureRecord(
            id: PaperFigureIndexContract.figureID(
                sourceID: paper.id,
                figureLabel: "Figure 2",
                pageIndex: 2
            ),
            sourceID: paper.id,
            figureLabel: "Figure 2",
            pageIndex: 2,
            caption: "Figure 2 | The treatment arm separates from control.",
            analysis: nil
        )
        try store.replacePaperFigureIndex(
            sourceID: paper.id,
            pdfPath: candidate.pdfPath,
            pageCount: 12,
            figures: [figure],
            indexVersion: candidate.targetVersion
        )

        #expect(try store.paperFigureIndexQueueCount() == 0)
        let stored = try #require(try store.paperFigures(sourceID: paper.id).first)
        #expect(stored == figure)
        #expect(stored.pageNumber == 3)

        // Metadata-only saves keep a current derived index. Re-extracting the
        // PDF body is explicit evidence that the same path may hold new bytes.
        var renamed = try #require(try store.loadSources().first { $0.id == paper.id })
        renamed.title = "Visual Paper (renamed)"
        try store.saveSource(renamed)
        #expect(try store.paperFigureIndexQueueCount() == 0)

        installPreparedPaperText("Fresh extraction from a replaced PDF.", on: &renamed)
        try store.saveSource(renamed)
        #expect(try store.paperFigureIndexQueueCount() == 1)

        try store.updateSourceType(paper.id, to: StudioSourceType.article.rawValue)
        #expect(try store.paperFigureIndexQueueCount() == 0)
        #expect(try store.paperFigures(sourceID: paper.id).isEmpty)
    }

    @Test("A figure index is current only for the PDF the paper has now")
    func paperFigureIndexCurrencyFollowsThePDF() throws {
        // A supplement joined to a paper moves it to a new file. Its index,
        // built from the old file, no longer names every figure, so the
        // figure tools must read it again rather than take it as stored.
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/supplemented-paper",
            title: "Supplemented Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.localFilePath = "Papers/supplemented-paper.pdf"
        installPreparedPaperText(on: &paper)
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)
        let candidate = try #require(try store.nextPaperFigureIndexCandidate())
        try store.replacePaperFigureIndex(
            sourceID: paper.id,
            pdfPath: candidate.pdfPath,
            pageCount: 8,
            figures: [],
            indexVersion: PaperFigureIndexContract.currentVersion
        )
        #expect(try store.paperFigureIndexIsCurrent(sourceID: paper.id))

        var joined = try #require(try store.loadSources().first { $0.id == paper.id })
        joined.localFilePath = "Papers/supplemented-paper-with-supplement.pdf"
        try store.saveSource(joined)
        #expect(try !store.paperFigureIndexIsCurrent(sourceID: paper.id))
    }

    @Test("Paper figure preparation selects only the explicitly requested source")
    func paperFigurePreparationSelectsRequestedSource() throws {
        let store = try makeInMemoryStore()
        var first = StudioArticle(
            url: "https://example.com/first-visual-paper",
            title: "First Visual Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        first.localFilePath = "Papers/first-visual-paper.pdf"
        installPreparedPaperText(on: &first)
        let completedFirstMetadata = first.completePaperMetadataExtractionAfterLLM()
        #expect(completedFirstMetadata)
        first.state = .ready
        try store.saveSource(first)

        var requested = StudioArticle(
            url: "https://example.com/requested-visual-paper",
            title: "Requested Visual Paper",
            sourceType: .paper,
            author: "Grace Researcher",
            journal: "Science",
            publishedYear: "2025"
        )
        requested.localFilePath = "Papers/requested-visual-paper.pdf"
        installPreparedPaperText(on: &requested)
        let completedRequestedMetadata = requested.completePaperMetadataExtractionAfterLLM()
        #expect(completedRequestedMetadata)
        requested.state = .ready
        try store.saveSource(requested)

        #expect(try store.paperFigureIndexQueueCount() == 2)
        let oldest = try #require(try store.nextPaperFigureIndexCandidate())
        #expect(oldest.sourceID == first.id)

        let selected = try #require(
            try store.paperFigureIndexCandidate(sourceID: requested.id)
        )
        #expect(selected.sourceID == requested.id)
        #expect(selected.pdfPath == "Papers/requested-visual-paper.pdf")
        #expect(try store.paperFigureIndexQueueCount() == 2)
    }

    @Test("Paper figure sync is optional and carries every stored column")
    func paperFigureSyncRoundTrips() throws {
        let article = makeArticle(url: "https://example.com/figure-sync", title: "Figure Sync")
        let analysis = ForeverLM.PaperFigureAnalysis(
            summary: "The treated group separates from control.",
            visualEvidence: ["The blue series rises after week four."],
            figureRect: ForeverLM.PaperFigureRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5),
            panels: [],
            analysisVersion: ForeverLM.PaperFigureAnalysis.currentVersion,
            generatedAt: Date(timeIntervalSinceReferenceDate: 1234)
        )
        let synced = ForeverLM.SyncedPaperFigure(
            id: "figure-sync-1",
            sourceID: article.id,
            figureLabel: "Figure 1",
            pageIndex: 3,
            caption: "Figure 1 | Separation over time.",
            analysis: analysis
        )

        let encoded = try JSONEncoder().encode(
            CloudKitSourcePayload(article: article, paperFigures: [synced])
        )
        let decoded = try JSONDecoder().decode(CloudKitSourcePayload.self, from: encoded)
        #expect(decoded.hasPaperFiguresPayload)
        #expect(decoded.paperFigures == [synced])

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "paperFigures")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(CloudKitSourcePayload.self, from: legacyData)
        #expect(!legacy.hasPaperFiguresPayload)
        #expect(legacy.paperFigures.isEmpty)

        let store = try makeInMemoryStore()
        try store.saveSource(article)
        try store.replacePaperFigureIndex(
            sourceID: article.id,
            pdfPath: "Papers/figure-sync.pdf",
            pageCount: 8,
            figures: [PaperFigureRecord(
                id: synced.id,
                sourceID: synced.sourceID,
                figureLabel: synced.figureLabel,
                pageIndex: synced.pageIndex,
                caption: "Older local caption",
                analysis: nil
            )],
            indexVersion: PaperFigureIndexContract.currentVersion
        )
        try store.savePaperFiguresFromSync(sourceID: article.id, figures: [synced])
        let stored = try #require(try store.paperFigures(sourceID: article.id).first)
        #expect(stored.caption == synced.caption)
        #expect(stored.analysis == Optional(analysis))
        #expect(stored.pageIndex == synced.pageIndex)

        try store.savePaperFiguresFromSync(sourceID: article.id, figures: [])
        #expect(try store.paperFigures(sourceID: article.id).isEmpty)
    }

    @Test("The legacy figure block is stripped only when it is unmistakably generated")
    func legacyFigureBlockStrippingIsConservative() {
        let generated = """
            Body text about the assay.

            ## Figures

            ![Figure 1 | Response.](file:///Users/someone/Content/Papers/Figures/p/page-0003.jpg)

            ![Figure 2 | Dose.](file:///Users/someone/Content/Papers/Figures/p/page-0007.jpg)
            """
        #expect(
            LegacyPaperFigureMarkdown.stripping(generated) == "Body text about the assay."
        )

        // A paper with its own Figures section keeps it.
        let authored = """
            Body text.

            ## Figures

            Figure 1 is discussed at length in the supplement.
            """
        #expect(LegacyPaperFigureMarkdown.stripping(authored) == nil)

        // Links that are not ours are left alone.
        let remote = """
            Body text.

            ## Figures

            ![Figure 1](https://example.com/figure-1.png)
            """
        #expect(LegacyPaperFigureMarkdown.stripping(remote) == nil)

        // Nothing to do is reported as nothing to do, so the drain stays idempotent.
        #expect(LegacyPaperFigureMarkdown.stripping("Body text only.") == nil)
        #expect(LegacyPaperFigureMarkdown.stripping("") == nil)
    }

    @Test("Ready sources require durable readable text")
    func readySourcesRequireDurableReadableText() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/textless-paper",
            title: "Textless Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)

        #expect(throws: (any Error).self) {
            try store.saveSource(paper)
        }

        let raw = "Textless Paper\n\nA durable result."
        paper.installPreparedPaperContent(
            raw: raw,
            clean: raw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(raw),
                preparedAt: Date()
            )
        )
        try store.saveSource(paper)
        #expect(try store.loadSourceContent(paper.id) == raw)
    }

    @Test("A review request, not a save, prepares and persists a versioned guide")
    func reviewRequestPreparesAndPersistsReviewGuide() throws {
        let store = try makeInMemoryStore()
        let raw = "Publisher header\n\nCanonical source text about a causal mechanism.\n\nReferences\nNoise"
        let clean = "Canonical source text about a causal mechanism."
        var paper = StudioArticle(
            url: "https://example.com/review-paper",
            title: "Review Guide Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        // Saving a reviewable paper schedules nothing on its own.
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id) == nil)

        // A review starting is what creates the work.
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        #expect(try store.sourceReviewGuideQueueCount() == 1)
        let candidate = try #require(try store.sourceReviewGuideCandidate(sourceID: paper.id))
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.title == paper.title)
        #expect(candidate.content == clean)
        #expect(!candidate.content.contains("Publisher header"))
        #expect(!candidate.content.contains("References"))
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id)?.sourceID == paper.id)

        try store.applySourceReviewGuide(
            candidate: candidate,
            guide: "Question: Explain the mechanism.\nStrong answer: Cause produces effect."
        )

        let prepared = try #require(try store.loadSourceReviewGuide(paper.id))
        #expect(prepared.generatorVersion == SourceReviewGuide.currentVersion)
        #expect(prepared.sourceSHA256 == candidate.sourceSHA256)
        #expect(prepared.guide.contains("Strong answer"))
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        #expect(try store.hasPendingSyncChange(entity: .source, logicalKey: paper.id))

        // Metadata-only saves retain the prepared guide; a canonical text change
        // invalidates it, and the replacement waits for the next review request.
        try store.saveSource(paper)
        #expect(try store.loadSourceReviewGuide(paper.id) != nil)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        let changedRaw = "Header\n\nChanged canonical source text.\n\nFooter"
        let changedClean = "Changed canonical source text."
        paper.installPreparedPaperContent(
            raw: changedRaw,
            clean: changedClean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(changedRaw),
                cleanSHA256: PaperContentPreparationService.sha256(changedClean),
                preparedAt: Date()
            )
        )
        try store.saveSource(paper)
        #expect(try store.loadSourceReviewGuide(paper.id) == nil)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id)?.content == changedClean)
    }

    @Test("A guide from an earlier generator keeps its paper out of the preparation queue")
    func earlierGeneratorGuideIsNotRegenerated() throws {
        let store = try makeInMemoryStore()
        let raw = "Publisher header\n\nCanonical text about an earlier generator.\n\nReferences\nNoise"
        let clean = "Canonical text about an earlier generator."
        var paper = StudioArticle(
            url: "https://example.com/earlier-generator-paper",
            title: "Earlier Generator Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        // Stand in for a guide generated before the current version shipped.
        try store.execForTesting("""
            INSERT INTO source_review_guides
                (source_id, source_sha256, guide, generator_version, generated_at)
            VALUES ('\(paper.id)', '\(PaperContentPreparationService.sha256(clean))',
                    'Earlier generator questions', \(SourceReviewGuide.currentVersion - 1), 1)
        """)

        // A review request must not treat the version gap as missing work.
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        let readable = try #require(try store.loadSourceReviewGuide(paper.id))
        #expect(readable.guide == "Earlier generator questions")
        #expect(readable.generatorVersion == SourceReviewGuide.currentVersion - 1)
    }

    @Test("A cleanup that re-read the paper's PDF commits the complete extraction as its raw text")
    func cleanupCommitsFreshPDFExtraction() throws {
        let store = try makeInMemoryStore()
        // An older build stopped PDF extraction at 50,000 characters, mid-word.
        let capped = "Useful mechanism and resu"
        var paper = StudioArticle(
            url: "https://example.com/capped-paper",
            title: "Capped Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Cell",
            publishedYear: "2026"
        )
        paper.localFilePath = "Papers/capped-paper.pdf"
        paper.installPreparedPaperContent(
            raw: capped,
            clean: capped,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(capped),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        let stored = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(stored.localFilePath == "Papers/capped-paper.pdf")
        #expect(stored.storedTextSHA256 == stored.rawSHA256)

        let complete = "Useful mechanism and result.\nSTAR★METHODS\nKEY RESOURCES TABLE\nNocodazole MedChemExpress Cat#HY-13520"
        let candidate = stored.replacingRaw(with: complete)
        #expect(candidate.raw == complete)
        #expect(candidate.rawSHA256 == PaperContentPreparationService.sha256(complete))
        #expect(candidate.storedTextSHA256 == stored.rawSHA256)
        #expect(candidate.localFilePath == stored.localFilePath)

        let prepared = PreparedPaperContent(
            raw: candidate.raw,
            clean: complete,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(complete),
                preparedAt: Date()
            )
        )

        // A change to the stored row while the cleanup ran still aborts the write.
        var edited = paper
        let editedRaw = "Useful mechanism and resu (edited)"
        edited.installPreparedPaperContent(
            raw: editedRaw,
            clean: editedRaw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(editedRaw),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        try store.saveSource(edited)
        #expect(throws: (any Error).self) {
            try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)
        }
        #expect(try store.loadPaperContentPreparation(paper.id)?.raw == editedRaw)

        let restaged = try #require(try store.nextCanonicalContentCleanupCandidate())
        let fresh = restaged.replacingRaw(with: complete)
        try store.applyCanonicalContentCleanup(candidate: fresh, prepared: prepared)

        #expect(try store.loadPaperContentPreparation(paper.id)?.raw == complete)
        #expect(try store.loadSourceContent(paper.id) == complete)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    /// The Illustrated AlphaFold (2026-10-06): its raw text stopped mid-word at
    /// the retired 50,000-character cap while `article.html` held the rest, and
    /// cleaner v19 had cleaned the prefix again.
    @Test("An article cleanup cleans its archived page's complete text when the stored text stops short of it")
    func articleCleanupCompletesCappedTextFromArchivedPage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivedArticleCompletion_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = directory.appendingPathComponent("article.html")
        let paragraphs = (1...12).map { "<p>Paragraph \($0) explains step \($0) of the architecture in plain words for the reader.</p>" }
        let pageHTML = "<html><body><h1>The Illustrated Model</h1>" + paragraphs.joined()
            + "<h2>Discussion</h2><p>The discussion closes the article with what the model leaves open.</p></body></html>"
        try pageHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        let complete = SourceService.readableTextFromHTML(pageHTML)
        // An older build kept only the first characters, cut mid-word.
        let cut = try #require(complete.range(of: "Paragraph 4 expl"))
        let capped = String(complete[..<cut.upperBound])

        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/the-illustrated-model",
            title: "The Illustrated Model",
            sourceType: .article
        )
        article.localFilePath = pageURL.path
        article.installPreparedArticleContent(
            raw: capped,
            clean: capped,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(capped),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        article.state = .ready
        try store.saveSource(article)

        let stored = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(stored.raw == capped)
        #expect(stored.localFilePath == pageURL.path)

        let working = await CanonicalContentCleanupService.withCompleteExtraction(stored)
        #expect(working.raw == complete)
        #expect(working.raw.hasSuffix("what the model leaves open."))
        #expect(working.storedTextSHA256 == stored.rawSHA256)

        let prepared = PreparedPaperContent(
            raw: working.raw,
            clean: working.raw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: working.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(working.raw),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: working, prepared: prepared)

        #expect(try store.loadArticleContentPreparation(article.id)?.raw == complete)
        #expect(try store.loadSourceContent(article.id) == complete)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("An article cleanup keeps stored text that is whole, or fuller than its archived page")
    func articleCleanupKeepsWholeStoredText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivedArticleCompletion_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = directory.appendingPathComponent("article.html")
        let paragraphs = (1...12).map { "Paragraph \($0) explains step \($0) of the argument in plain words." }
        // The page now shows a paywall's preview; the stored text came from an
        // archived copy of the whole article.
        let previewHTML = "<html><body>" + paragraphs.prefix(3).map { "<p>\($0)</p>" }.joined()
            + "<p>" + Array(repeating: "Subscribe to keep reading this post and get access to the full archive.", count: 6).joined(separator: " ")
            + "</p></body></html>"
        try previewHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        let whole = paragraphs.joined(separator: "\n\n")

        for stored in [whole, SourceService.readableTextFromHTML(previewHTML)] {
            let candidate = CanonicalContentCleanupCandidate(
                sourceID: UUID().uuidString,
                title: "The Argument",
                sourceType: .article,
                raw: stored,
                rawSHA256: PaperContentPreparationService.sha256(stored),
                isPendingIngestion: false,
                localFilePath: pageURL.path
            )
            let working = await CanonicalContentCleanupService.withCompleteExtraction(candidate)
            #expect(working.raw == stored)
            #expect(working.storedRawSHA256 == nil)
        }
    }

    @Test("Stored article text stops short of its page only when the page continues the same text")
    func storedArticleTextStopsShortOnlyOfItsContinuation() {
        let words = (1...300).map { "word\($0)" }
        let page = words.joined(separator: " ") + "."
        let stopsShort = CanonicalContentCleanupService.storedArticleText(_:stopsShortOf:)

        // A prefix cut mid-word, as the retired cap cut it.
        #expect(stopsShort(words[..<150].joined(separator: " ") + " word15", page))
        #expect(!stopsShort(page, page))
        // A page that only adds a sign-off after the same last words.
        #expect(!stopsShort(page, page + " Thanks for reading, share this post with a friend."))
        // An older extraction's list items and superscripts line up with today's.
        let older = "Tokens\nPDE Predicted distance error between tokens, capturing the accuracy of predicted difference"
        let newer = "## Tokens\n\n- PDE Predicted distance error between tokens, capturing the accuracy of predicted differences^(3) between all pairs of tokens.\n"
            + words[..<60].joined(separator: " ")
        #expect(stopsShort(older, newer))
        // The page's next word has to continue the stored text's last one.
        #expect(!stopsShort(older, newer.replacingOccurrences(of: "differences", with: "outcomes")))
        // A page telling the text in another order (Research Square): the
        // stored text's closing notice recurs in the page, but above nearly
        // all of what the stored text says.
        let body = words.joined(separator: " ")
        let notice = "Journal Publication published 16 Mar 2026 Read the published version in Nature Communications Version 1 posted You are reading this latest preprint version"
        #expect(!stopsShort(body + "\n" + notice, "Download PDF " + notice + "\n" + body))
    }

    // MARK: - Text past a U+0000 (schema 134)

    /// A paper as PDFKit hands it back when a glyph has no Unicode mapping:
    /// U+0000 where a minus sign or an "fi" ligature was printed. On
    /// 2026-09-23 the text before the first one was all SQLite kept.
    private static let extractionWithUnmappedGlyphs =
        "Abstract.\u{000C}A t-statistic t=\u{0000}43.49 confirms the scienti\u{0000}c claim.\nMethods and results follow."

    private static func paperForTextFidelity(url: String) -> StudioArticle {
        StudioArticle(
            url: url,
            title: "Text Fidelity Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "bioRxiv",
            publishedYear: "2024"
        )
    }

    @Test("Text holding U+0000 is stored and read back whole, so its hash still names it")
    func textPastNULRoundTripsThroughStorage() throws {
        let store = try makeInMemoryStore()
        let raw = Self.extractionWithUnmappedGlyphs
        let clean = "A t-statistic t=\u{0000}43.49 confirms the scienti\u{0000}c claim.\nMethods and results follow."
        var paper = Self.paperForTextFidelity(url: "https://example.com/nul-round-trip")
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
        #expect(paperMetadataCompleted)
        try store.saveSource(paper)

        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == raw)
        #expect(PaperContentPreparationService.sha256(preparation.raw) == preparation.metadata.rawSHA256)
        let stored = try #require(try store.loadSourceContent(paper.id))
        #expect(stored == clean)
        #expect(PaperContentPreparationService.sha256(stored) == preparation.metadata.cleanSHA256)
        #expect(stored.hasSuffix("Methods and results follow."), "nothing after the first U+0000 is lost")
        var byteLength = 0
        try store.query("SELECT length(CAST(raw_content AS BLOB)) FROM paper_content_preparations") { stmt in
            byteLength = Int(sqlite3_column_int64(stmt, 0))
        }
        #expect(byteLength == raw.utf8.count)
    }

    @Test("A cleanup commit keeps a fresh PDF extraction past its first U+0000, and word count agrees with the stored text")
    func cleanupCommitKeepsExtractionPastNUL() throws {
        let store = try makeInMemoryStore()
        // What the stored row held: the extraction cut at its first U+0000.
        let stub = "Abstract.\u{000C}A t-statistic t="
        var paper = Self.paperForTextFidelity(url: "https://example.com/nul-cleanup")
        paper.localFilePath = "Papers/nul-cleanup.pdf"
        paper.installPreparedPaperContent(
            raw: stub,
            clean: stub,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(stub),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
        #expect(paperMetadataCompleted)
        try store.saveSource(paper)

        let stored = try #require(try store.nextCanonicalContentCleanupCandidate())
        let complete = Self.extractionWithUnmappedGlyphs
        let candidate = stored.replacingRaw(with: complete)
        let clean = String(complete.dropFirst("Abstract.\u{000C}".count))
        let prepared = PreparedPaperContent(
            raw: candidate.raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)

        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == complete)
        #expect(PaperContentPreparationService.sha256(preparation.raw) == preparation.metadata.rawSHA256)
        let storedClean = try #require(try store.loadSourceContent(paper.id))
        #expect(storedClean == clean)
        let reloaded = try #require(try store.loadSources().first { $0.id == paper.id })
        #expect(reloaded.wordCount == storedClean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
    }

    @Test("A preparation whose hash does not name its raw text is refused, and nothing is written")
    func mismatchedPreparationIsRefused() throws {
        let store = try makeInMemoryStore()
        let full = Self.extractionWithUnmappedGlyphs
        var paper = Self.paperForTextFidelity(url: "https://example.com/nul-mismatch")
        paper.installPreparedPaperContent(
            raw: "Abstract.",
            clean: "Abstract.",
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(full),
                cleanSHA256: PaperContentPreparationService.sha256("Abstract."),
                preparedAt: Date()
            )
        )
        let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
        #expect(paperMetadataCompleted)
        #expect(throws: KnowledgeStoreError.self) { try store.saveSource(paper) }
        #expect(try store.loadPaperContentPreparation(paper.id) == nil)
        #expect(try store.loadSourceContent(paper.id) == nil)
    }

    @Test("PDF extraction marks an unmapped glyph U+FFFD instead of emitting U+0000")
    func unmappedGlyphBecomesReplacementCharacter() {
        #expect(
            PDFTextExtractor.markingUnmappedGlyphs("t=\u{0000}43.49 scienti\u{0000}c")
                == "t=\u{FFFD}43.49 scienti\u{FFFD}c"
        )
        let plain = "No unmapped glyphs here.\u{000C}Page two."
        #expect(PDFTextExtractor.markingUnmappedGlyphs(plain) == plain)
    }

    @Test("Schema 134 audits every preparation once and re-queues only a row whose stored text is shorter than its hash")
    func version134AuditRequeuesTruncatedPreparations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentIntegrityAudit_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let full = Self.extractionWithUnmappedGlyphs
        let fullHash = PaperContentPreparationService.sha256(full)
        let truncated = "Abstract.\u{000C}A t-statistic t="
        let healthyRaw = "Healthy body.\nReferences"
        let damagedID: String
        let healthyID: String
        let articleID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            var damaged = Self.paperForTextFidelity(url: "https://example.com/audit-damaged")
            damaged.installPreparedPaperContent(
                raw: full,
                clean: full,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: fullHash,
                    cleanSHA256: fullHash,
                    preparedAt: Date()
                )
            )
            let damagedMetadataCompleted = damaged.completePaperMetadataExtractionAfterLLM()
            #expect(damagedMetadataCompleted)
            try store.saveSource(damaged)
            var healthy = Self.paperForTextFidelity(url: "https://example.com/audit-healthy")
            healthy.installPreparedPaperContent(
                raw: healthyRaw,
                clean: "Healthy body.",
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: PaperContentPreparationService.sha256(healthyRaw),
                    cleanSHA256: PaperContentPreparationService.sha256("Healthy body."),
                    preparedAt: Date()
                )
            )
            let healthyMetadataCompleted = healthy.completePaperMetadataExtractionAfterLLM()
            #expect(healthyMetadataCompleted)
            try store.saveSource(healthy)
            var article = StudioArticle(
                url: "https://example.com/audit-article",
                title: "Audit Article",
                sourceType: .article
            )
            article.installPreparedArticleContent(
                raw: "Article raw.",
                clean: "Article raw.",
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: PaperContentPreparationService.sha256("Article raw."),
                    cleanSHA256: PaperContentPreparationService.sha256("Article raw."),
                    preparedAt: Date()
                )
            )
            article.state = .ready
            try store.saveSource(article)
            damagedID = damaged.id
            healthyID = healthy.id
            articleID = article.id
        }

        // Reproduce what a schema-133 build stored: the text cut at its first
        // U+0000 under the whole extraction's hashes, as a C-string bind wrote it.
        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        for sql in [
            "UPDATE paper_content_preparations SET raw_content = '\(truncated)' WHERE source_id = '\(damagedID)'",
            "UPDATE source_content SET content = '\(truncated)' WHERE source_id = '\(damagedID)'",
            "DELETE FROM canonical_content_cleanup_queue",
            "DELETE FROM sync_changes",
            "DROP TABLE IF EXISTS canonical_content_integrity_audit_queue",
            "PRAGMA user_version = 133",
        ] {
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        sqlite3_close(database)

        let migrated = try KnowledgeStore(storeDirectory: root)
        var version: Int32 = 0
        try migrated.query("PRAGMA user_version") { stmt in version = sqlite3_column_int(stmt, 0) }
        #expect(version == KnowledgeStore.schemaVersion)
        // Staging only: ids are queued, no text is read or rewritten, and the
        // library is visible while the audit waits.
        #expect(try migrated.canonicalContentIntegrityAuditQueueCount() == 3)
        #expect(Set(try migrated.loadSources().map(\.id)) == [damagedID, healthyID, articleID])
        #expect(try migrated.loadPaperContentPreparation(damagedID)?.metadata.rawSHA256 == fullHash)
        #expect(try migrated.canonicalContentCleanupQueueCount() == 0)

        let first = try migrated.auditCanonicalContentIntegrity(limit: 2)
        #expect(first.audited == 2)
        #expect(first.remaining == 1)
        let second = try migrated.auditCanonicalContentIntegrity(limit: 2)
        #expect(second.audited == 1)
        #expect(second.remaining == 0)
        #expect(first.requeuedSourceIDs + second.requeuedSourceIDs == [damagedID])

        // The damaged row now says what it holds, and the cleanup will redo it.
        let restated = try #require(try migrated.loadPaperContentPreparation(damagedID))
        #expect(restated.raw == truncated)
        #expect(restated.metadata.rawSHA256 == PaperContentPreparationService.sha256(truncated))
        #expect(restated.metadata.cleanerVersion == 0)
        #expect(restated.metadata.cleanSHA256 == nil)
        #expect(try migrated.canonicalContentCleanupCandidates(limit: 10).map(\.sourceID) == [damagedID])
        #expect(try migrated.pendingSyncChanges().map(\.logicalKey) == [damagedID])
        // Rows whose text matches their hash are untouched.
        let untouched = try #require(try migrated.loadPaperContentPreparation(healthyID))
        #expect(untouched.metadata.cleanerVersion == PaperContentPreparationMetadata.currentVersion)
        #expect(untouched.raw == healthyRaw)
        #expect(try migrated.loadArticleContentPreparation(articleID)?.metadata.cleanerVersion
            == PaperContentPreparationMetadata.currentVersion)

        // Retired: a second pass finds nothing to do.
        let idle = try migrated.auditCanonicalContentIntegrity(limit: 50)
        #expect(idle.audited == 0)
        #expect(idle.requeuedSourceIDs.isEmpty)
    }

    @Test("Schema 134 stages a production-sized library well under a second")
    func version134ScalesToALargeLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentIntegrityAuditScale_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The largest real library held 1,441 preparations on 2026-09-23.
        let sourceCount = 3_000
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            for index in 0..<sourceCount {
                let raw = "Article \(index) body.\nFooter"
                var article = StudioArticle(
                    url: "https://example.com/audit-scale/\(index)",
                    title: "Audit Scale \(index)",
                    sourceType: .article
                )
                article.installPreparedArticleContent(
                    raw: raw,
                    clean: raw,
                    metadata: PaperContentPreparationMetadata(
                        cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                        rawSHA256: PaperContentPreparationService.sha256(raw),
                        cleanSHA256: PaperContentPreparationService.sha256(raw),
                        preparedAt: Date()
                    )
                )
                article.state = .ready
                try store.saveSource(article)
            }
            try store.execForTesting("DROP TABLE IF EXISTS canonical_content_integrity_audit_queue")
            try store.execForTesting("PRAGMA user_version = 133")
        }

        let started = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(started)

        #expect(try migrated.canonicalContentIntegrityAuditQueueCount() == sourceCount)
        #expect(elapsed < 1.0, "Migration took \(elapsed)s for \(sourceCount) preparations")
        #expect(try migrated.loadSources().count == sourceCount, "sources stay visible while the audit waits")
    }

    @Test("A failed schema-134 step leaves the store at 133 with its data")
    func version134RollsBackOnFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentIntegrityAuditRollback_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paperID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            var paper = Self.paperForTextFidelity(url: "https://example.com/audit-rollback")
            let raw = "Rollback body."
            paper.installPreparedPaperContent(
                raw: raw,
                clean: raw,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: PaperContentPreparationService.sha256(raw),
                    cleanSHA256: PaperContentPreparationService.sha256(raw),
                    preparedAt: Date()
                )
            )
            let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
            #expect(paperMetadataCompleted)
            try store.saveSource(paper)
            paperID = paper.id
        }
        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        // A same-named table of another shape makes the step's INSERT fail.
        #expect(sqlite3_exec(database, "DROP TABLE IF EXISTS canonical_content_integrity_audit_queue", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE canonical_content_integrity_audit_queue (incompatible TEXT)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 133", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) { _ = try KnowledgeStore(storeDirectory: root) }

        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        var storedVersion: Int32 = 0
        if sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            storedVersion = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        #expect(storedVersion == 133)
        var kept = 0
        if sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM paper_content_preparations WHERE source_id = '\(paperID)'", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            kept = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        #expect(kept == 1, "the library survives the failed migration")
    }

    @Test("Paper review waits for cleanup and receives only the cleaned derivative")
    func paperReviewWaitsForCanonicalCleanup() throws {
        let store = try makeInMemoryStore()
        let raw = "Publisher footer\n\nUseful mechanism and result.\n\nReferences\nCitation noise"
        var paper = StudioArticle(
            url: "https://example.com/pending-cleanup-paper",
            title: "Pending Cleanup Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        // Model a legacy ready paper whose raw extraction is still its readable
        // snapshot. The version-0 preparation is what durably schedules cleanup;
        // current writes may not claim a paper is ready with unattested text.
        paper.installPreparedPaperContent(
            raw: raw,
            clean: raw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id) == nil)

        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        let clean = "Useful mechanism and result."
        try store.applyCanonicalContentCleanup(
            candidate: cleanup,
            prepared: PreparedPaperContent(
                raw: cleanup.raw,
                clean: clean,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: cleanup.rawSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        )

        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        // Cleanup finishing still schedules nothing; the cleaned derivative is
        // only prepared once a review asks for it.
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: paper.id))
        #expect(review.content == clean)
        #expect(!review.content.contains("Publisher footer"))
        #expect(!review.content.contains("References"))
    }

    @Test("Source review guide and paper figures sync optionally and round-trip")
    func sourceReviewGuideSyncPayloadRoundTrips() throws {
        let article = makeArticle(url: "https://example.com/review-sync", title: "Review Sync")
        let guide = SourceReviewGuide(
            sourceSHA256: "abc123",
            guide: "Question and strong answer",
            generatorVersion: SourceReviewGuide.currentVersion,
            generatedAt: Date(timeIntervalSinceReferenceDate: 1234)
        )

        let analysis = ForeverLM.PaperFigureAnalysis(
            summary: "Panel b rises while control remains flat.",
            visualEvidence: ["The blue series increases across the x-axis."],
            figureRect: ForeverLM.PaperFigureRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
            panels: [ForeverLM.PaperFigurePanel(
                id: "figure-2-panel-b",
                label: "b",
                explanation: "The treatment separates from control.",
                rect: ForeverLM.PaperFigureRect(x: 0.5, y: 0.2, width: 0.4, height: 0.6)
            )],
            analysisVersion: ForeverLM.PaperFigureAnalysis.currentVersion,
            generatedAt: Date(timeIntervalSinceReferenceDate: 1234)
        )
        let figure = ForeverLM.SyncedPaperFigure(
            id: "figure-2",
            sourceID: article.id,
            figureLabel: "Figure 2",
            pageIndex: 3,
            caption: "Figure 2 | Treatment response.",
            analysis: analysis
        )
        let listenableMetadata = SourceListenableContentMetadata(
            sourceSHA256: "source-hash",
            generatorVersion: SourceListenableContentMetadata.currentVersion,
            preparationSignature: "route-hash",
            characterCount: 12_345,
            preparedAt: Date(timeIntervalSinceReferenceDate: 1234)
        )
        let encoded = try JSONEncoder().encode(CloudKitSourcePayload(
            article: article,
            listenableContentMetadata: listenableMetadata,
            sourceReviewGuide: guide,
            paperFigures: [figure]
        ))
        let decoded = try JSONDecoder().decode(CloudKitSourcePayload.self, from: encoded)
        #expect(decoded.sourceReviewGuide == guide)
        #expect(decoded.listenableContentMetadata == listenableMetadata)
        #expect(decoded.hasListenableContentPayload)
        #expect(decoded.paperFigures == [figure])

        let legacyEncoded = try JSONEncoder().encode(CloudKitSourcePayload(article: article))
        let legacyDecoded = try JSONDecoder().decode(CloudKitSourcePayload.self, from: legacyEncoded)
        #expect(legacyDecoded.sourceReviewGuide == nil)
        #expect(legacyDecoded.listenableContentMetadata == nil)
        #expect(legacyDecoded.hasListenableContentPayload)
        #expect(legacyDecoded.paperFigures.isEmpty)
    }

    @Test("insertSourceIfNew inserts a new source")
    func testInsertSourceIfNewInsertsNewSource() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        let inserted = try store.insertSourceIfNew(&article)
        #expect(inserted)
        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].title == "Post 1")
    }

    @Test("Article read status round-trips through SQLite")
    func articleReadStatusRoundTrips() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/read-test", title: "Read Test")
        article.sourceType = .article
        try store.saveSource(article)

        let readAt = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try store.updateSourceReadAt(sourceID: article.id, readAt: readAt)

        let loaded = try store.loadSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].readAt == readAt)
        #expect(loaded[0].isRead)

        try store.updateSourceReadAt(sourceID: article.id, readAt: nil)
        let cleared = try store.loadSources()
        #expect(cleared[0].readAt == nil)
        #expect(!cleared[0].isRead)
    }

    @Test("Hidden source attribute round-trips for every source type")
    func hiddenSourceRoundTripsForEverySourceType() throws {
        let store = try makeInMemoryStore()
        let sourceTypes: [StudioSourceType] = [
            .article, .paper, .podcast, .book, .course, .meeting, .video, .xPost, .manual, .unclassified
        ]

        for sourceType in sourceTypes {
            let article = StudioArticle(
                url: "https://example.com/\(sourceType.rawValue)",
                title: "\(sourceType.rawValue) source",
                sourceType: sourceType
            )
            try store.saveSource(article)
            try store.setSourceHidden(article.id, hidden: true)
        }

        let loaded = try store.loadSources()
        let hiddenTypes = Set(loaded.filter(\.isHidden).map(\.sourceType))

        #expect(hiddenTypes == Set(sourceTypes))
    }

    @Test("Saving source metadata preserves existing hidden source state")
    func saveSourcePreservesExistingHiddenState() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/hidden", title: "Hidden")

        try store.saveSource(article)
        try store.setSourceHidden(article.id, hidden: true)
        try store.saveSource(article)

        let loaded = try store.loadSources()
        #expect(loaded.first?.isHidden == true)
    }

    @Test("Video playlist metadata persists and queues sync")
    func videoPlaylistMetadataPersistsAndQueuesSync() throws {
        let store = try makeInMemoryStore()
        let metadata = VideoPlaylistMetadata(
            title: "Quantum Biology Conference",
            playlistURL: "https://www.youtube.com/playlist?list=PL-quantum-bio",
            lastRefreshedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            isHidden: true
        )

        try store.saveVideoPlaylistGroup(id: "playlist-1", metadata: metadata)

        #expect(try store.loadVideoPlaylistGroups()["playlist-1"] == metadata)
        #expect(try store.loadVideoPlaylistForSync("playlist-1")?.metadata == metadata)
        #expect(try store.hasPendingSyncChange(entity: .videoPlaylist, logicalKey: "playlist-1"))
    }

    @Test("Unchanged YouTube feed metadata does not queue source sync")
    func unchangedYouTubeFeedMetadataDoesNotQueueSync() throws {
        let store = try makeInMemoryStore()
        let playlistID = "liked-feed"
        try store.saveVideoPlaylistGroup(
            id: playlistID,
            metadata: VideoPlaylistMetadata(
                title: "Liked videos",
                playlistURL: YouTubeService.likedVideosPlaylistURL
            )
        )
        let likedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let publishedAt = Date(timeIntervalSinceReferenceDate: 500)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=unchanged",
            title: "Unchanged",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: playlistID
        )
        video.courseSortIndex = 0
        video.likedAt = likedAt
        video.videoPublishedAt = publishedAt
        try store.saveSource(video)
        try store.clearAllPendingSyncChanges()

        #expect(try !store.updateCourseSortIndex(video.id, 0))
        #expect(try !store.updateVideoFeedDates(
            sourceID: video.id,
            likedAt: likedAt,
            videoPublishedAt: publishedAt
        ))
        #expect(try store.pendingSyncChanges().isEmpty)

        #expect(try store.updateCourseSortIndex(video.id, 1))
        #expect(try store.updateVideoFeedDates(
            sourceID: video.id,
            likedAt: likedAt.addingTimeInterval(1),
            videoPublishedAt: publishedAt
        ))
        #expect(try store.pendingSyncChanges().map(\.logicalKey) == [video.id])
    }

    @Test("Pending CloudKit saves for missing local records are discarded")
    func pendingCloudKitSavesForMissingLocalRecordsAreDiscarded() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/present", title: "Present")
        try store.saveSource(article)
        try store.clearAllPendingSyncChanges()

        try store.requeueSyncChange(entity: .source, logicalKey: article.id, operation: .save)
        try store.requeueSyncChange(entity: .source, logicalKey: "missing-source", operation: .save)
        let discarded = try store.discardPendingSavesMissingLocalRecords()

        #expect(discarded.map(\.logicalKey) == ["missing-source"])
        #expect(try store.pendingSyncChanges().map(\.logicalKey) == [article.id])
    }

    @Test("Legacy database without source public URL still lists sources")
    func legacyDatabaseWithoutSourcePublicURLStillListsSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy_sources_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbPath = root.appendingPathComponent("knowledge.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw KnowledgeStoreError.openFailed(SQLITE_CANTOPEN)
        }
        sqlite3_exec(db, """
            CREATE TABLE sources (
                id TEXT PRIMARY KEY,
                date_added REAL NOT NULL,
                state TEXT NOT NULL DEFAULT 'queued',
                error_message TEXT,
                source_type TEXT NOT NULL DEFAULT 'article',
                existing_card_count INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'active',
                archived_at TEXT,
                is_consumed INTEGER
            );
            PRAGMA user_version = 1;
        """, nil, nil, nil)
        sqlite3_close(db)

        let store = try KnowledgeStore(storeDirectory: root)
        let article = makeArticle(url: "https://example.com/legacy", title: "Legacy Source")

        try store.saveSource(article)
        let loaded = try store.loadSources()

        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Legacy Source")
    }

    @Test("AI-extracted paper metadata persists and queues source sync")
    func aiExtractedPaperMetadataPersistsAndQueuesSourceSync() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "Papers/example.pdf",
            title: "Unresolved Paper",
            sourceType: .paper,
            localFilePath: "Papers/example.pdf"
        )

        try store.saveSource(paper)
        try store.clearAllPendingSyncChanges()

        paper.title = "Attention Is All You Need"
        paper.author = "Ashish Vaswani et al."
        paper.journal = "NeurIPS"
        paper.publishedYear = "2017"
        paper.doi = "10.5555/example"
        installPreparedPaperText(on: &paper)
        let attested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(paper)

        let loaded = try store.loadSources()
        let saved = try #require(loaded.first(where: { $0.id == paper.id }))
        let sourceChange = try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        }
        let syncMetadata = try store.loadSyncMetadata(entity: .source, logicalKey: paper.id)

        #expect(saved.title == "Attention Is All You Need")
        #expect(saved.author == "Ashish Vaswani et al.")
        #expect(saved.journal == "NeurIPS")
        #expect(saved.publishedYear == "2017")
        #expect(saved.doi == "10.5555/example")
        #expect(saved.paperIngestionMethod == .llm)
        #expect(saved.isPaperReadyForListenPreparation)
        #expect(!saved.hasSuccessfulPaperIngestion)
        #expect(sourceChange?.operation == .save)
        #expect(syncMetadata?.isDeleted == false)
    }

    @Test("Ready paper persistence requires a durable LLM attestation")
    func readyPaperPersistenceRequiresLLMAttestation() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "Papers/unattested.pdf",
            title: "Unattested Paper",
            sourceType: .paper,
            localFilePath: "Papers/unattested.pdf",
            author: "A. Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        // Complete-looking metadata is not proof that the mandatory model call ran.
        paper.state = .ready

        #expect(throws: (any Error).self) {
            try store.saveSource(paper)
        }
        #expect(try store.loadSources().isEmpty)
    }

    @Test("Paper is fully prepared only after durable Listen content commits")
    func paperFullReadinessRequiresListenableContent() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "Papers/listen-ready.pdf",
            title: "Listen-ready Paper",
            sourceType: .paper,
            localFilePath: "Papers/listen-ready.pdf",
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        let canonical = "Durable canonical paper text."
        installPreparedPaperText(canonical, on: &paper)
        let metadataAttested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(metadataAttested)
        try store.saveSource(paper)

        var loaded = try #require(try store.loadSources().first)
        #expect(loaded.isPaperReadyForListenPreparation)
        #expect(!loaded.hasSuccessfulPaperIngestion)

        let sourceHash = PaperContentPreparationService.sha256(canonical)
        try store.applySourceListenableContent(
            candidate: SourceListenableContentCandidate(
                sourceID: paper.id,
                title: paper.title,
                sourceType: .paper,
                canonicalText: canonical,
                sourceSHA256: sourceHash
            ),
            text: "Durable narration text.",
            preparationSignature: PaperNarrationFilter.preparationContractPrefix + "test"
        )

        loaded = try #require(try store.loadSources().first)
        #expect(loaded.hasSuccessfulPaperIngestion)
    }

    /// Listen narrates the source's text, so a bibliographic gate must not
    /// withhold it. Unsigned editorials fail that gate permanently, and gating
    /// narration on `.ready` left iOS listing them, offering Listen, and only
    /// then reporting that the source was still preparing.
    @Test("A failed metadata gate still queues Listen preparation")
    func unattestedPaperQueuesListenableContentPreparation() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "Papers/unsigned-editorial.pdf",
            title: "Anti-aging interventions need less hype",
            sourceType: .paper,
            localFilePath: "Papers/unsigned-editorial.pdf",
            journal: "Nature Medicine",
            publishedYear: "2026"
        )
        let canonical = "An unsigned editorial with a full body of readable text."
        installPreparedPaperText(canonical, on: &paper)
        paper.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["author"])
        )
        try store.saveSource(paper)

        let candidate = try #require(try store.sourceListenableContentCandidates(limit: 10).first)
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.canonicalText == canonical)

        let loaded = try #require(try store.loadSources().first)
        // The metadata failure is untouched: the paper still needs attention.
        #expect(loaded.state == .error)
        #expect(!loaded.hasSuccessfulPaperIngestion)
    }

    /// The content handoff is discarded from memory after every successful
    /// ingest, so a later save legitimately carries no text. Treating that as
    /// evidence the source lost its text dropped the queued narration — and for
    /// a paper that re-enters metadata extraction on every launch, nothing ever
    /// put it back.
    @Test("A save without in-memory text keeps queued Listen preparation")
    func savingWithoutInMemoryTextKeepsQueuedListenablePreparation() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "Papers/unsigned-editorial.pdf",
            title: "Anti-aging interventions need less hype",
            sourceType: .paper,
            localFilePath: "Papers/unsigned-editorial.pdf",
            journal: "Nature Medicine",
            publishedYear: "2026"
        )
        installPreparedPaperText("Canonical text that outlives the handoff.", on: &paper)
        paper.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["author"])
        )
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 1)

        paper.discardPersistedPaperContentFromMemory()
        // A metadata retry parks the paper back in `queued` before the model runs.
        paper.prepareForPaperMetadataExtraction()
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 1)

        // Archiving is what genuinely retires the work.
        paper.status = .archived
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 0)
    }

    @Test("Paper persistence trims authors without parsing human-written names")
    func paperPersistencePreservesAuthorMeaning() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/single-author-paper",
            title: "Single Author Paper",
            sourceType: .paper
        )
        paper.author = "  Samuel I. Gould; samuel i. gould  "

        try store.saveSource(paper)

        let saved = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        #expect(saved.author == "Samuel I. Gould; samuel i. gould")
    }

    @Test("Queued paper extraction is retained raw but hidden from downstream source content")
    func queuedPaperStagesRawContent() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/queued-paper",
            title: "Queued Paper",
            sourceType: .paper
        )
        paper.content = "Publisher header\n\nSubstantive extracted paper text"
        paper.prepareForPaperMetadataExtraction()

        try store.saveSource(paper)

        #expect(try store.loadSourceContent(paper.id) == nil)
        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == paper.content)
        #expect(preparation.metadata.cleanerVersion == 0)
        #expect(preparation.metadata.cleanSHA256 == nil)
    }

    @Test("Ready paper persists clean canonical text and raw extraction separately")
    func preparedPaperPersistsRawAndCleanContent() throws {
        let store = try makeInMemoryStore()
        let raw = "Journal furniture\n\nCanonical Paper\n\nAbstract body\n\nReferences\n1. Noise"
        let clean = "Canonical Paper\n\nAbstract body"
        var paper = StudioArticle(
            url: "https://example.com/prepared-paper",
            title: "Canonical Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        // Called outside the macro: `#expect` captures its expression in a
        // closure, which cannot call a mutating member on `paper`.
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)

        try store.saveSource(paper)

        #expect(try store.loadSourceContent(paper.id) == clean)
        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == raw)
        #expect(preparation.metadata.cleanSHA256 == PaperContentPreparationService.sha256(clean))
    }

    @Test("Ready article persists clean canonical text and raw extraction separately")
    func preparedArticlePersistsRawAndCleanContent() throws {
        let store = try makeInMemoryStore()
        let raw = "Site navigation\n\nCanonical Article\n\nSubstantive body\n\nRelated stories"
        let clean = "Canonical Article\n\nSubstantive body"
        var article = StudioArticle(
            url: "https://example.com/prepared-article",
            title: "Canonical Article",
            sourceType: .article
        )
        article.installPreparedArticleContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        article.state = .ready

        try store.saveSource(article)

        #expect(try store.loadSourceContent(article.id) == clean)
        let preparation = try #require(try store.loadArticleContentPreparation(article.id))
        #expect(preparation.raw == raw)
        #expect(preparation.metadata.cleanerVersion == PaperContentPreparationMetadata.currentVersion)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)

        try store.ensureSourceReviewGuidePreparation(sourceID: article.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: article.id))
        #expect(review.sourceType == .article)
        #expect(review.title == article.title)
        #expect(review.content == clean)
        #expect(!review.content.contains("Site navigation"))
        #expect(!review.content.contains("Related stories"))
    }

    @Test("Legacy ready articles enter the resumable canonical cleanup queue")
    func legacyArticleQueuesCanonicalCleanup() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/legacy-article",
            title: "Legacy Article",
            sourceType: .article
        )
        article.content = "Legacy Article\n\nUseful body\n\nWebsite footer"
        article.state = .ready
        try store.saveSource(article)

        #expect(try store.sourceReviewGuideCandidate(sourceID: article.id) == nil)
        try store.ensureSourceReviewGuidePreparation(sourceID: article.id)
        #expect(try store.sourceReviewGuideQueueCount() == 0)

        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        #expect(candidate.sourceType == .article)
        #expect(candidate.raw == article.content)

        let clean = "Legacy Article\n\nUseful body"
        let prepared = PreparedPaperContent(
            raw: candidate.raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)

        #expect(try store.loadSourceContent(article.id) == clean)
        #expect(try store.loadArticleContentPreparation(article.id)?.raw == article.content)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        // Once cleanup commits, the next review request can use the cleaned
        // article without ever exposing the legacy raw extraction.
        try store.ensureSourceReviewGuidePreparation(sourceID: article.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: article.id))
        #expect(review.content == clean)
        #expect(!review.content.contains("Website footer"))
        #expect(try store.sourceReviewGuideQueueCount() == 1)
        #expect(try store.pendingSyncChanges().contains { $0.entity == .source && $0.logicalKey == article.id })
    }

    @Test("Transcript-backed sources can prepare a review from canonical content")
    func transcriptBackedSourceCanPrepareReviewGuide() throws {
        let store = try makeInMemoryStore()
        let transcript = "A complete transcript explaining the experiment and its result."
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=reviewable",
            title: "Reviewable Video",
            sourceType: .video
        )
        video.content = transcript
        video.state = .ready
        try store.saveSource(video)

        try store.ensureSourceReviewGuidePreparation(sourceID: video.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: video.id))
        #expect(review.sourceType == .video)
        #expect(review.title == video.title)
        #expect(review.content == transcript)
        #expect(review.sourceSHA256 == PaperContentPreparationService.sha256(transcript))
    }

    @Test("Canonical cleanup selects a distinct bounded batch for parallel preparation")
    func canonicalCleanupSelectsDistinctBatch() throws {
        let store = try makeInMemoryStore()
        for index in 1...5 {
            var article = StudioArticle(
                url: "https://example.com/cleanup-batch-\(index)",
                title: "Cleanup Batch \(index)",
                sourceType: .article
            )
            article.content = "Useful body \(index).\nWebsite footer."
            article.state = .ready
            try store.saveSource(article)
        }

        let candidates = try store.canonicalContentCleanupCandidates(limit: 4)
        #expect(candidates.count == 4)
        #expect(Set(candidates.map(\.sourceID)).count == 4)
        #expect(candidates.allSatisfy { $0.sourceType == .article })
        #expect(try store.canonicalContentCleanupQueueCount() == 5)
    }

    @Test("Canonical cleanup prioritizes the newest eligible sources")
    func canonicalCleanupPrioritizesNewestSources() throws {
        let store = try makeInMemoryStore()
        var older = StudioArticle(
            url: "https://example.com/older-cleanup",
            title: "Older Cleanup",
            sourceType: .article
        )
        older.content = "Older useful body."
        older.state = .ready
        older.dateAdded = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveSource(older)

        var newer = StudioArticle(
            url: "https://example.com/newer-cleanup",
            title: "Newer Cleanup",
            sourceType: .article
        )
        newer.content = "Newer useful body."
        newer.state = .ready
        newer.dateAdded = Date(timeIntervalSinceReferenceDate: 200)
        try store.saveSource(newer)

        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == newer.id)
    }

    @Test("Transient article cleanup is durable pending work and promotes only after cleanup")
    func transientArticleCleanupRetriesDurably() throws {
        let store = try makeInMemoryStore()
        let raw = "Running head\nThe useful article body.\nPublisher footer"
        var article = StudioArticle(
            url: "https://example.com/transient-cleanup",
            title: "Transient Cleanup",
            sourceType: .article
        )
        article.stageArticleContentCleanup(raw: raw)
        article.state = .queued
        article.errorMessage = nil
        try store.saveSource(article)

        #expect(try store.loadSourceContent(article.id) == nil)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        #expect(candidate.raw == raw)
        #expect(candidate.isPendingIngestion)

        let clean = "Transient Cleanup\n\nThe useful article body."
        let prepared = PreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)

        let completed = try #require(try store.loadSourceForSync(article.id))
        #expect(completed.state == .ready)
        #expect(completed.errorMessage == nil)
        #expect(try store.loadSourceContent(article.id) == clean)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Paid source clean-up runs in production and in an opted-in Dev launch only")
    func paidSourceCleanupPolicy() {
        #expect(PaidSourceCleanupPolicy.runsPaidCleanup(isDevelopment: false, environment: [:]))
        #expect(!PaidSourceCleanupPolicy.runsPaidCleanup(isDevelopment: true, environment: [:]))
        #expect(!PaidSourceCleanupPolicy.runsPaidCleanup(
            isDevelopment: true,
            environment: [PaidSourceCleanupPolicy.optInEnvironmentKey: "0"]
        ))
        #expect(PaidSourceCleanupPolicy.runsPaidCleanup(
            isDevelopment: true,
            environment: [PaidSourceCleanupPolicy.optInEnvironmentKey: "1"]
        ))
    }

    @Test("The pending-only candidate batch leaves historical re-clean rows behind")
    func pendingOnlyCandidatesSkipHistoricalRows() throws {
        let store = try makeInMemoryStore()
        var historical = StudioArticle(
            url: "https://example.com/historical-cleanup",
            title: "Historical Cleanup",
            sourceType: .article
        )
        historical.content = "Already readable body.\nWebsite footer."
        historical.state = .ready
        historical.dateAdded = Date(timeIntervalSinceReferenceDate: 200)
        try store.saveSource(historical)

        var pending = StudioArticle(
            url: "https://example.com/pending-cleanup",
            title: "Pending Cleanup",
            sourceType: .article
        )
        pending.stageArticleContentCleanup(raw: "Navigation\nA new article body.\nFooter")
        pending.state = .queued
        pending.dateAdded = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveSource(pending)

        #expect(try store.canonicalContentCleanupCandidates(limit: 10).count == 2)
        let pendingOnly = try store.canonicalContentCleanupCandidates(
            limit: 10,
            pendingIngestionOnly: true
        )
        #expect(pendingOnly.map(\.sourceID) == [pending.id])
        #expect(pendingOnly.first?.isPendingIngestion == true)
    }

    @Test("Publishing without clean-up makes a queued article readable from its raw text")
    func publishingWithoutCleanupPromotesAQueuedArticle() throws {
        let store = try makeInMemoryStore()
        let raw = "Running head\nThe useful article body.\nPublisher footer"
        var article = StudioArticle(
            url: "https://example.com/dev-raw-publish",
            title: "Dev Raw Publish",
            sourceType: .article
        )
        article.stageArticleContentCleanup(raw: raw)
        article.state = .queued
        try store.saveSource(article)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.isPendingIngestion)

        try store.publishCanonicalContentWithoutCleanup(candidate: candidate)

        let published = try #require(try store.loadSourceForSync(article.id))
        #expect(published.state == .ready)
        #expect(published.errorMessage == nil)
        #expect(try store.loadSourceContent(article.id) == raw)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        // Honest attribution: no model touched this text, and a later save still
        // sees a version below the current contract.
        let preparation = try #require(try store.loadArticleContentPreparation(article.id))
        #expect(preparation.metadata.cleanerVersion == PaperContentPreparationMetadata.deterministicVersion)
        #expect(preparation.metadata.cleanSHA256 == PaperContentPreparationService.sha256(raw))
    }

    @Test("Publishing without clean-up counts a queued paper as ingested")
    func publishingWithoutCleanupCompletesAPaper() throws {
        let store = try makeInMemoryStore()
        let raw = "## Abstract\nA complete paper body long enough to publish.\nReferences"
        var paper = StudioArticle(
            url: "https://example.com/dev-raw-paper.pdf",
            title: "Dev Raw Paper",
            sourceType: .paper
        )
        paper.stagePaperContentCleanup(raw: raw)
        // A queued paper is enqueued for clean-up only once its metadata stage
        // has attested it, as the ingestion pipeline does before this point.
        paper.author = "A. Author"
        paper.journal = "Journal of Tests"
        paper.publishedYear = "2026"
        let attested = paper.attestPaperMetadataExtractionAfterLLM()
        #expect(attested)
        paper.state = .queued
        try store.saveSource(paper)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceType == .paper)
        #expect(candidate.isPendingIngestion)

        try store.publishCanonicalContentWithoutCleanup(candidate: candidate)

        let published = try #require(try store.loadSourceForSync(paper.id))
        #expect(published.state == .ready)
        // Honest attribution, as for an article: no model produced this text, so
        // the paper does not claim a completed clean-up and a later save re-queues it.
        #expect(!published.hasCompletedPaperContentCleanup)
        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.metadata.cleanerVersion == PaperContentPreparationMetadata.deterministicVersion)
        #expect(try store.loadSourceContent(paper.id) == raw)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Publishing without clean-up never touches a historical re-clean row")
    func publishingWithoutCleanupIgnoresHistoricalRows() throws {
        let store = try makeInMemoryStore()
        let clean = "Already readable body."
        var historical = StudioArticle(
            url: "https://example.com/historical-untouched",
            title: "Historical Untouched",
            sourceType: .article
        )
        historical.content = clean
        historical.state = .ready
        try store.saveSource(historical)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(!candidate.isPendingIngestion)

        try store.publishCanonicalContentWithoutCleanup(candidate: candidate)

        #expect(try store.loadSourceContent(historical.id) == clean)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.loadArticleContentPreparation(historical.id) == nil)
    }

    @Test("A drain that may not spend a model publishes pending sources raw and leaves history queued")
    func unpaidDrainPublishesPendingAndKeepsHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-unpaid-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)

        var historical = StudioArticle(
            url: "https://example.com/unpaid-historical",
            title: "Unpaid Historical",
            sourceType: .article
        )
        historical.content = "Readable body.\nWebsite footer."
        historical.state = .ready
        historical.dateAdded = Date(timeIntervalSinceReferenceDate: 200)
        try await storage.saveSource(historical)

        let raw = "Navigation\nA new article body.\nFooter"
        var pending = StudioArticle(
            url: "https://example.com/unpaid-pending",
            title: "Unpaid Pending",
            sourceType: .article
        )
        pending.stageArticleContentCleanup(raw: raw)
        pending.state = .queued
        pending.dateAdded = Date(timeIntervalSinceReferenceDate: 100)
        try await storage.saveSource(pending)
        #expect(try await storage.canonicalContentCleanupQueueCount() == 2)

        let service = CanonicalContentCleanupService(
            storage: storage,
            aiService: AIService(),
            runsPaidCleanup: false
        )
        let result = await service.drain()

        #expect(result.errorMessage == nil)
        #expect(result.processedSourceIDs == [pending.id])
        #expect(result.remainingCount == 1)
        let published = try #require(try await storage.loadSourceWithoutContent(pending.id))
        #expect(published.state == .ready)
        #expect(try await storage.loadSourceContent(pending.id) == raw)
        let remaining = try await storage.canonicalContentCleanupCandidates(limit: 10)
        #expect(remaining.map(\.sourceID) == [historical.id])
        // The Listen derivative is paid too, so the raw publish queues none.
        #expect(try await storage.sourceListenableContentQueueCount() == 0)
    }

    @Test("Permanent pending cleanup failure becomes an explicit source error")
    func permanentPendingCleanupFailureIsVisible() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/permanent-cleanup",
            title: "Permanent Cleanup",
            sourceType: .article
        )
        article.stageArticleContentCleanup(raw: "Useful article body")
        article.state = .queued
        try store.saveSource(article)

        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        try store.failPendingCanonicalContentCleanup(
            candidate: candidate,
            message: "Source Content Cleanup is not configured."
        )

        let failed = try #require(try store.loadSourceForSync(article.id))
        #expect(failed.state == .error)
        #expect(failed.errorMessage?.contains("not configured") == true)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Completed canonical cleanup clears a stale timeout without another AI pass")
    func completedCleanupClearsStaleTimeout() throws {
        let store = try makeInMemoryStore()
        let raw = "Navigation\nA complete article body.\nPublisher footer"
        let clean = "A Return to the Beginning\n\nA complete article body."
        var article = StudioArticle(
            url: "https://example.com/already-cleaned",
            title: "A Return to the Beginning",
            sourceType: .article
        )
        article.installPreparedArticleContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        article.state = .ready
        article.errorMessage =
            "Article ingestion failed during Source Content Cleanup: The request timed out."
        try store.saveSource(article)

        #expect(try store.clearCompletedCanonicalContentCleanupFailure(sourceID: article.id))
        let repaired = try #require(try store.loadSourceForSync(article.id))
        #expect(repaired.state == .ready)
        #expect(repaired.errorMessage == nil)
        #expect(try store.loadSourceContent(article.id) == clean)
        #expect(try !store.clearCompletedCanonicalContentCleanupFailure(sourceID: article.id))
    }

    @Test("Canonical cleanup prunes historical work after a source is archived")
    func canonicalCleanupPrunesArchivedQueueRows() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/stale-archived-cleanup",
            title: "Stale Archived Cleanup",
            sourceType: .article
        )
        article.content = "Useful body followed by publisher noise."
        article.state = .ready
        try store.saveSource(article)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)

        // Reproduce an old/synced status-only archive that bypassed the modern
        // archive transaction and therefore left its local durable work behind.
        try store.execForTesting("UPDATE sources SET status = 'archived' WHERE id = '\(article.id)'")

        #expect(try store.pruneIneligibleCanonicalContentCleanupQueue() == 1)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Cleanup failures never retire source text by attempt count")
    func canonicalCleanupFailuresRemainRetriable() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/paywalled-post",
            title: "Paywalled Post",
            sourceType: .article
        )
        article.content = "Paywalled Post\n\nJoin to unlock\n\nBecome a member"
        article.state = .ready
        try store.saveSource(article)

        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        try store.recordCanonicalContentCleanupFailure(
            sourceID: article.id,
            message: "Provider unavailable",
            consumesAttempt: false
        )
        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == article.id)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)

        // Re-saving metadata leaves the same text to fail the same way.
        article.title = "Paywalled Post (renamed)"
        try store.saveSource(article)
        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == article.id)

        // Re-extracted text is genuinely new work, so it earns a fresh budget.
        article.content = "Paywalled Post\n\nThe full essay finally extracted."
        try store.saveSource(article)
        let revived = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(revived.sourceID == article.id)
    }

    @Test("A failed cleanup waits out its retry delay, and its attempts run out")
    func canonicalCleanupRetriesAreBounded() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/rate-limited-paper",
            title: "Rate Limited Paper",
            sourceType: .article
        )
        article.content = "Rate Limited Paper\n\nA body the free model never finishes."
        article.state = .ready
        try store.saveSource(article)

        // A transient round (a 429 from the backup) spends an attempt too.
        let before = Date()
        #expect(try store.recordCanonicalContentCleanupFailure(
            sourceID: article.id,
            message: "Rate limited (429)"
        ) == 1)
        #expect(try store.canonicalContentCleanupCandidates(limit: 10).isEmpty)
        let due = try #require(try store.nextCanonicalContentCleanupRetryDate())
        #expect(abs(due.timeIntervalSince(before) - CanonicalContentCleanupRetry.baseDelay) < 60)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.canonicalContentCleanupCandidates(
            limit: 10,
            now: due.addingTimeInterval(1)
        ).map(\.sourceID) == [article.id])

        var attempts = 1
        while attempts < CanonicalContentCleanupRetry.maximumAttempts {
            attempts = try store.recordCanonicalContentCleanupFailure(
                sourceID: article.id,
                message: "Rate limited (429)"
            )
        }
        // Spent: never picked again, not counted, no retry to wake for.
        #expect(try store.canonicalContentCleanupCandidates(
            limit: 10,
            now: Date().addingTimeInterval(30 * 24 * 60 * 60)
        ).isEmpty)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        #expect(try store.nextCanonicalContentCleanupRetryDate() == nil)

        // New text is new work with a fresh budget.
        article.content = "Rate Limited Paper\n\nThe full text, extracted again."
        try store.saveSource(article)
        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == article.id)
    }

    @Test("Cleanup retry delays double from 15 minutes to 12 hours over about a day")
    func canonicalCleanupRetryDelays() {
        let retry = CanonicalContentCleanupRetry.self
        #expect(retry.delay(afterAttempts: 0) == 0)
        #expect(retry.delay(afterAttempts: 1) == 15 * 60)
        #expect(retry.delay(afterAttempts: 2) == 30 * 60)
        #expect(retry.delay(afterAttempts: 7) == 12 * 60 * 60)
        #expect(retry.delay(afterAttempts: 60) == 12 * 60 * 60)
        let span = (1..<retry.maximumAttempts).map { retry.delay(afterAttempts: $0) }.reduce(0, +)
        #expect(span > 24 * 60 * 60 && span < 30 * 60 * 60)

        // A parked source is not re-staged as transient, though its last
        // error was a 429.
        let parked = StudioArticle.paperContentCleanupFailureMessage(
            retry.exhaustedMessage(attempts: 8, lastError: "Rate limited (429)")
        )
        #expect(!PaperContentPreparationService.isTransientIngestionFailure(parked))
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            StudioArticle.paperContentCleanupFailureMessage("Rate limited (429)")
        ))
    }

    @Test("Canonical cleanup commits before listenable-content preparation is queued, for an automatic-audio kind")
    func canonicalCleanupQueuesSecondListenableSave() throws {
        let store = try makeInMemoryStore()
        store.automaticAudioSourceTypes = { ["article"] }
        var article = StudioArticle(
            url: "https://example.com/two-stage-source",
            title: "Two Stage Source",
            sourceType: .article
        )
        article.content = "Publisher navigation\n\nThe canonical body remains."
        article.state = .ready
        try store.saveSource(article)

        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.sourceListenableContentQueueCount() == 0)

        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        try Self.commitCleanup(cleanup, clean: "Two Stage Source\n\nThe canonical body remains.", in: store)

        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        #expect(try store.nextSourceListenableContentCandidate()?.sourceID == article.id)
    }

    @Test("A clean-up commit queues no paid Listen preparation unless automatic audio covers the kind")
    func cleanupCommitDoesNotQueueListenPreparation() throws {
        let store = try makeInMemoryStore()
        // Automatic audio covers papers only: the article must not be queued.
        store.automaticAudioSourceTypes = { ["paper"] }
        var article = StudioArticle(
            url: "https://example.com/lazy-listen-source",
            title: "Lazy Listen Source",
            sourceType: .article
        )
        article.content = "Publisher navigation\n\nThe body nobody has listened to."
        article.state = .ready
        try store.saveSource(article)

        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        let clean = "Lazy Listen Source\n\nThe body nobody has listened to."
        try Self.commitCleanup(cleanup, clean: clean, in: store)
        #expect(try store.sourceListenableContentQueueCount() == 0)
        #expect(try store.nextSourceListenableContentCandidate() == nil)

        // Pressing Listen prepares it then; the narration is bound to the
        // cleaned text like any other.
        let listen = SourceListenableContentCandidate(
            sourceID: article.id,
            title: article.title,
            sourceType: .article,
            canonicalText: clean,
            sourceSHA256: PaperContentPreparationService.sha256(clean)
        )
        try store.applySourceListenableContent(
            candidate: listen,
            text: "Lazy Listen Source. The body nobody has listened to.",
            preparationSignature: nil
        )
        #expect(try store.loadSourceListenableContent(article.id) != nil)

        // A later change to the text retires that narration instead of
        // re-buying it.
        try store.execForTesting("UPDATE source_content SET content = 'Changed elsewhere.' WHERE source_id = '\(article.id)'")
        try store.enqueueSourceListenableContentPreparation(
            sourceID: article.id,
            content: "Changed elsewhere."
        )
        #expect(try store.loadSourceListenableContent(article.id) == nil)
        #expect(try store.sourceListenableContentQueueCount() == 0)
    }

    @Test("An import queues no paid Listen preparation until automatic audio asks for it")
    func importDoesNotQueueListenPreparation() throws {
        let store = try makeInMemoryStore()
        store.automaticAudioSourceTypes = { [] }
        var paper = StudioArticle(
            url: "https://example.com/read-not-heard",
            title: "Read Not Heard",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        installPreparedPaperText("Read Not Heard\n\nA body nobody listens to.", on: &paper)
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 0)

        // Automatic audio switched on afterwards finds the paper unprepared
        // and queues it from the stored text.
        store.automaticAudioSourceTypes = { ["paper"] }
        #expect(try store.queueSourceListenableContentPreparation(sourceID: paper.id))
        let candidate = try #require(try store.nextSourceListenableContentCandidate())
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.canonicalText == "Read Not Heard\n\nA body nobody listens to.")
    }

    private static func commitCleanup(
        _ cleanup: CanonicalContentCleanupCandidate,
        clean: String,
        in store: KnowledgeStore
    ) throws {
        try store.applyCanonicalContentCleanup(
            candidate: cleanup,
            prepared: PreparedPaperContent(
                raw: cleanup.raw,
                clean: clean,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: cleanup.rawSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        )
    }

    @Test("Listenable content is source-bound, persisted, and invalidated by new canonical text")
    func listenableContentLifecycle() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "https://example.com/source-bound-paper",
            title: "Source-Bound Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        installPreparedPaperText("Source-Bound Paper\n\nFirst canonical body.", on: &paper)
        let completedInitialMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedInitialMetadata)
        paper.state = .ready
        try store.saveSource(paper)

        let candidate = try #require(try store.nextSourceListenableContentCandidate())
        try store.applySourceListenableContent(
            candidate: candidate,
            text: "Source-Bound Paper. First canonical body.",
            preparationSignature: "luna-route"
        )
        let stored = try #require(try store.loadSourceListenableContent(paper.id))
        #expect(stored.text == "Source-Bound Paper. First canonical body.")
        #expect(stored.metadata.sourceSHA256 == candidate.sourceSHA256)
        #expect(stored.metadata.characterCount == stored.text.count)
        #expect(
            try store.sourceListenableContentSummaries(for: [paper.id])[paper.id]
                == SourceListenableContentSummary(
                    characterCount: stored.text.count,
                    preparationSignature: "luna-route"
                )
        )
        #expect(try store.sourceListenableContentQueueCount() == 0)

        installPreparedPaperText("Source-Bound Paper\n\nSecond canonical body.", on: &paper)
        let completedReplacementMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedReplacementMetadata)
        try store.saveSource(paper)
        #expect(try store.loadSourceListenableContent(paper.id) == nil)
        let replacement = try #require(try store.nextSourceListenableContentCandidate())
        #expect(replacement.sourceSHA256 != candidate.sourceSHA256)

        do {
            try store.applySourceListenableContent(
                candidate: candidate,
                text: "Stale narration must not be saved.",
                preparationSignature: "luna-route"
            )
            Issue.record("Expected stale listenable content to be rejected")
        } catch KnowledgeStoreError.sourceContentChanged {
            // The reader distinguishes this expected race from real preparation
            // failures so it can refresh the canonical snapshot once.
        }
        #expect(try store.loadSourceListenableContent(paper.id) == nil)
        #expect(try store.nextSourceListenableContentCandidate()?.sourceSHA256 == replacement.sourceSHA256)
    }

    @Test("An unchanged cleaned paper still replaces a stale narration contract")
    func unchangedPaperRequeuesStaleNarrationContract() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "https://example.com/unchanged-paper-contract",
            title: "Unchanged Paper Contract",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        installPreparedPaperText(
            "Unchanged Paper Contract\n\nThe canonical body needs no textual edits.",
            on: &paper
        )
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)

        let original = try #require(try store.nextSourceListenableContentCandidate())
        try store.applySourceListenableContent(
            candidate: original,
            text: original.canonicalText,
            preparationSignature: "pre-v4-paper-contract"
        )
        #expect(try store.sourceListenableContentQueueCount() == 0)

        try store.enqueueSourceListenableContentPreparation(
            sourceID: paper.id,
            content: original.canonicalText
        )

        #expect(try store.loadSourceListenableContent(paper.id) == nil)
        #expect(try store.nextSourceListenableContentCandidate()?.sourceID == paper.id)
    }

    @Test("Listenable preparation selects a distinct bounded batch")
    func listenableContentBatchSelection() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var sourceIDs: [String] = []
        for index in 0..<3 {
            var paper = StudioArticle(
                url: "https://example.com/batched-paper-\(index)",
                title: "Batched Paper \(index)",
                sourceType: .paper,
                author: "Ada Researcher",
                journal: "Journal",
                publishedYear: "2026"
            )
            paper.dateAdded = Date(timeIntervalSinceReferenceDate: Double(index))
            installPreparedPaperText(
                "Batched Paper \(index)\n\nCanonical body \(index).",
                on: &paper
            )
            let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
            #expect(completedMetadata)
            paper.state = .ready
            try store.saveSource(paper)
            sourceIDs.append(paper.id)
        }

        let batch = try store.sourceListenableContentCandidates(limit: 2)
        #expect(batch.count == 2)
        #expect(Set(batch.map(\.sourceID)).count == 2)
        #expect(batch.map(\.sourceID) == Array(sourceIDs.reversed().prefix(2)))
        #expect(try store.nextSourceListenableContentCandidate()?.sourceID == batch.first?.sourceID)
        #expect(try store.sourceListenableContentCandidates(limit: 0).isEmpty)
    }

    @Test("Books do not queue generated listenable content")
    func booksDoNotQueueListenableContent() throws {
        let store = try makeInMemoryStore()
        var book = StudioArticle(
            url: "Books/chapter.xhtml",
            title: "A Chapter",
            sourceType: .book
        )
        book.content = "A Chapter\n\nAlready suitable for direct narration."
        book.state = .ready
        try store.saveSource(book)

        #expect(try store.sourceListenableContentQueueCount() == 0)
        #expect(try store.nextSourceListenableContentCandidate() == nil)
    }

    @Test("Versions 45–46 requeue prepared papers through cleanup without hiding sources or touching articles")
    func version45RequeuesPreparedPapersForSidebarOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListenableContentV45Tests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try createVersion44PreparedNarrationFixture(
            at: root,
            articleCount: 2,
            paperCount: 3,
            bookCount: 2
        )

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(try migrated.sourceListenableContentQueueCount() == 3)
        // Schema 132 (cleaner v19) also queues every ready article for cleanup.
        #expect(try migrated.canonicalContentCleanupQueueCount() == 5)
        #expect(try migrated.loadSourcesWithoutContent().count == 7)
        #expect(try migrated.pendingSyncChanges().count == 1)
        #expect(try migrated.loadLearningGoal("goal-1")?.items.count == 1)
        #expect(
            try migrated.loadSourceListenableContent("article-00001")?.text
                == "Previously prepared narration for article-00001."
        )
        #expect(
            try migrated.loadSourceListenableContent("paper-00001")?.text
                == "Previously prepared narration for paper-00001."
        )
        let candidates = try migrated.sourceListenableContentCandidates(limit: 10)
        #expect(candidates.isEmpty)
        #expect(try migrated.nextCanonicalContentCleanupCandidate()?.sourceType == .paper)
    }

    @Test("Versions 45–56 requeue a production-scale paper library within the launch budget")
    func version45PaperRequeueScales() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListenableContentV45ScaleTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try createVersion44PreparedNarrationFixture(
            at: root,
            articleCount: 5_000,
            paperCount: 5_000
        )

        let clock = ContinuousClock()
        let start = clock.now
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = start.duration(to: clock.now)

        #expect(try migrated.sourceListenableContentQueueCount() == 5_000)
        // Schema 132 (cleaner v19) also queues every ready article for cleanup.
        #expect(try migrated.canonicalContentCleanupQueueCount() == 10_000)
        #expect(try migrated.loadSourcesWithoutContent().count == 10_000)
        #expect(try migrated.loadSourcesWithoutContent().contains { $0.id == "article-05000" })
        #expect(try migrated.loadSourcesWithoutContent().contains { $0.id == "paper-05000" })
        #expect(try migrated.pendingSyncChanges().count == 1)
        #expect(try migrated.loadLearningGoal("goal-1")?.items.count == 1)
        #expect(elapsed < .seconds(10))
    }

    @Test("Reader notes persist quote anchors, edits, colors, and deletion")
    func readerNotePersistenceRoundTrip() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/reader-note", title: "Reader Note")
        article.content = "Before the important result after the important result."
        article.state = .ready
        try store.saveSource(article)

        let quote = "important result"
        let selected = article.content!.range(of: quote)!
        let anchor = ReaderTextAnchor(text: article.content!, range: selected)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var highlight = SourceHighlight(
            id: "hl-round-trip",
            sourceID: article.id,
            quote: quote,
            note: "First note",
            color: .yellow,
            anchor: anchor,
            pdfAnchor: ReaderPDFAnchor(
                pageIndex: 2,
                rects: [CGRect(x: 10, y: 20, width: 80, height: 12)]
            ),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try store.saveSourceHighlight(highlight)

        var loaded = try #require(store.sourceHighlights(sourceID: article.id).first)
        #expect(loaded == highlight)
        #expect(loaded.anchor.resolve(in: article.content!) == selected)

        highlight.note = "Revised note"
        highlight.color = .blue
        highlight.updatedAt = Date(timeIntervalSince1970: 2_000)
        try store.saveSourceHighlight(highlight)
        loaded = try #require(store.sourceHighlights(sourceID: article.id).first)
        #expect(loaded.note == "Revised note")
        #expect(loaded.color == .blue)
        #expect(loaded.createdAt == createdAt)

        try store.deleteSourceHighlight(id: highlight.id)
        #expect(try store.sourceHighlights(sourceID: article.id).isEmpty)
    }

    @Test("Reader text anchors use context to resolve repeated passages after reflow")
    func readerTextAnchorResolvesRepeatedPassage() throws {
        let original = "Alpha lead important result alpha tail. Beta lead important result beta tail."
        let second = try #require(original.range(of: "important result", options: [], range: original.range(of: "Beta lead")!.lowerBound..<original.endIndex))
        let anchor = ReaderTextAnchor(text: original, range: second)
        let reflowed = "Alpha lead\nimportant   result alpha tail. Beta lead\nimportant result beta tail."
        let resolved = try #require(anchor.resolve(in: reflowed))
        #expect(String(reflowed[resolved]) == "important result")
        #expect(reflowed[..<resolved.lowerBound].contains("Beta lead"))
    }

    @Test("Migration stays fast on a production-shaped paper library")
    func paperMigrationScaleRegression() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperReviewGuideV35ScaleTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try createVersion34PaperReviewFixture(at: root, paperCount: 3_000)

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(startedAt)

        // The version-42 sweep retires the whole backlog rather than paying to
        // prepare 3,000 guides the learner may never ask for.
        #expect(try migrated.sourceReviewGuideQueueCount() == 0)
        #expect(try migrated.loadSources().filter { $0.sourceType == .paper }.count == 3_000)
        #expect(elapsed < 10)
    }

    @Test("A production-sized version 18 upgrade remains set-based and preserves the library")
    func productionSizedVersion18MigrationRemainsFastAndNonDestructive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-schema-v18-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paperCount = 600
        let embeddingCount = 30_000
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE n(x) AS (
                    VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < \(paperCount)
                )
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('scale-paper-%04d', x), 0, 'ready', 'paper', 'active' FROM n;
                WITH RECURSIVE n(x) AS (
                    VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < \(paperCount)
                )
                INSERT INTO papers
                    (source_id, url, title, domain, author, journal, published_year, paper_ingestion_method)
                SELECT printf('scale-paper-%04d', x),
                       printf('Papers/scale-%04d.pdf', x),
                       printf('Scale Paper %04d', x),
                       'local', 'Ada Researcher', 'Nature Aging', '2026', 'legacy'
                FROM n;
                WITH RECURSIVE n(x) AS (
                    VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < \(paperCount)
                )
                INSERT INTO source_content (source_id, content)
                SELECT printf('scale-paper-%04d', x), 'Canonical text that must remain byte-for-byte intact.' FROM n;
                WITH RECURSIVE n(x) AS (
                    VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < \(paperCount)
                )
                INSERT INTO source_fts (source_id, title, author, body)
                SELECT printf('scale-paper-%04d', x), printf('Scale Paper %04d', x), 'Ada', 'indexed body' FROM n;
                WITH RECURSIVE n(x) AS (
                    VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < \(embeddingCount)
                )
                INSERT INTO embeddings (entity_type, entity_id, model, vector, updated_at)
                SELECT 'source_chunk',
                       printf('scale-paper-%04d::chunk::%05d', ((x - 1) % \(paperCount)) + 1, x),
                       'default', X'00', 0
                FROM n;
                DELETE FROM canonical_content_cleanup_queue;
                DELETE FROM sync_changes;
                PRAGMA user_version = 17;
                COMMIT;
            """)
        }

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let migrationDuration = Date().timeIntervalSince(startedAt)

        #expect(migrationDuration < 3.0)
        #expect(try migrated.loadSources().count == paperCount)
        #expect(try migrated.canonicalContentCleanupQueueCount() == paperCount)
        var remainingFTS = 0
        var remainingEmbeddings = 0
        try migrated.query("SELECT COUNT(*) FROM source_fts") { stmt in
            remainingFTS = Int(sqlite3_column_int64(stmt, 0))
        }
        try migrated.query("SELECT COUNT(*) FROM embeddings WHERE entity_type = 'source_chunk'") { stmt in
            remainingEmbeddings = Int(sqlite3_column_int64(stmt, 0))
        }
        #expect(remainingFTS == paperCount)
        #expect(remainingEmbeddings == embeddingCount)
    }

    @Test("updateSourceType migrates article to paper and queues source sync")
    func updateSourceTypeMigratesArticleToPaperAndQueuesSourceSync() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/research-note", title: "Research Note")
        article.author = "Ada Lovelace"

        try store.saveSource(article)
        try store.clearAllPendingSyncChanges()

        try store.updateSourceType(article.id, to: StudioSourceType.paper.rawValue)

        let saved = try #require(try store.loadSources().first(where: { $0.id == article.id }))
        let sourceChange = try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == article.id
        }
        let syncMetadata = try store.loadSyncMetadata(entity: .source, logicalKey: article.id)

        #expect(saved.sourceType == .paper)
        #expect(saved.url == article.url)
        #expect(saved.title == "Research Note")
        #expect(saved.author == "Ada Lovelace")
        #expect(sourceChange?.operation == .save)
        #expect(syncMetadata?.isDeleted == false)
    }

    @Test("Paywall status persists and queues source sync")
    func paywallStatusPersistsAndQueuesSourceSync() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://www.nature.com/articles/example",
            title: "Paywalled Paper",
            sourceType: .paper
        )

        try store.saveSource(paper)
        try store.clearAllPendingSyncChanges()

        paper.state = .error
        paper.errorMessage = "paywall"
        paper.isPaywalled = true
        try store.saveSource(paper)

        let saved = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        let sourceChange = try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        }
        let syncMetadata = try store.loadSyncMetadata(entity: .source, logicalKey: paper.id)

        #expect(saved.sourceType == .paper)
        #expect(saved.state == .error)
        #expect(saved.errorMessage == "paywall")
        #expect(saved.isPaywalled)
        #expect(sourceChange?.operation == .save)
        #expect(syncMetadata?.isDeleted == false)
    }

    @Test("A paywall suspicion persists with the paper, queues sync, and clears when written back nil")
    func paywallSuspicionPersistsAndClears() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/12345678/",
            title: "Suspected Paper",
            sourceType: .paper
        )
        try store.saveSource(paper)
        try store.clearAllPendingSyncChanges()
        #expect(try #require(try store.loadSources().first(where: { $0.id == paper.id })).paywallSuspicion == nil)

        paper.paywallSuspicion = "Abstract-only page; the only full-text link says Get Access."
        try store.saveSource(paper)
        let saved = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        #expect(saved.paywallSuspicion == "Abstract-only page; the only full-text link says Get Access.")
        #expect(!saved.isPaywalled, "a suspicion is not a marker")
        #expect(saved.state == .queued, "the paper stays in the attention list")
        let sourceChange = try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        }
        #expect(sourceChange?.operation == .save)

        paper.paywallSuspicion = nil
        paper.isPaywalled = true
        try store.saveSource(paper)
        let marked = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        #expect(marked.paywallSuspicion == nil)
        #expect(marked.isPaywalled)
    }

    @Test("Remote paper keeps original URL when local PDF is attached")
    func remotePaperKeepsOriginalURLWhenLocalPDFAttached() throws {
        let store = try makeInMemoryStore()
        let remoteURL = "https://www.nature.com/articles/35016601"
        var paper = StudioArticle(
            url: remoteURL,
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )

        try store.saveSource(paper)
        try store.clearAllPendingSyncChanges()

        paper.localFilePath = "Papers/10.1038_35016601.pdf"
        paper.domain = "Local PDF"
        paper.author = "Teruhiko Wakayama et al."
        paper.journal = "Nature"
        paper.publishedYear = "2000"
        paper.doi = "10.1038/35016601"
        installPreparedPaperText(on: &paper)
        let attested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(paper)

        let loaded = try store.loadSources()
        let saved = try #require(loaded.first(where: { $0.id == paper.id }))
        var rediscovered = StudioArticle(
            url: remoteURL,
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )
        rediscovered.doi = "10.1038/35016601"
        let changes = try store.pendingSyncChanges()

        #expect(saved.url == remoteURL)
        #expect(saved.localFilePath?.hasSuffix("Papers/10.1038_35016601.pdf") == true)
        #expect(try store.insertSourceIfNew(&rediscovered) == false)
        #expect(try store.loadSources().count == 1)
        #expect(changes.contains {
            $0.entity == .source && $0.logicalKey == paper.id && $0.operation == .save
        })
    }

    @Test("Hidden sources are queued for CloudKit sync")
    func hiddenSourcesAreQueuedForSync() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/hidden", title: "Hidden")

        try store.saveSource(article)
        try store.setSourceHidden(article.id, hidden: true)

        let payload = try store.loadHiddenSourceForSync(article.id)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .hiddenSource && $0.logicalKey == article.id
        }

        #expect(payload?.sourceID == article.id)
        #expect(change?.operation == .save)
    }

    @Test("Remote hidden source record waits for source row")
    func remoteHiddenSourceWaitsForSourceRow() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/deferred-hidden", title: "Deferred Hidden")

        try store.saveHiddenSourceRecord(
            CloudKitHiddenSourcePayload(sourceID: article.id, hiddenAt: Date())
        )
        try store.saveSource(article)

        let loaded = try store.loadSources()
        #expect(loaded.first?.isHidden == true)
    }

    @Test("Unhiding sources queues a CloudKit deletion")
    func unhiddenSourcesQueueCloudKitDeletion() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/hidden", title: "Hidden")

        try store.saveSource(article)
        try store.setSourceHidden(article.id, hidden: true)
        try store.clearAllPendingSyncChanges()
        try store.setSourceHidden(article.id, hidden: false)

        let payload = try store.loadHiddenSourceForSync(article.id)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .hiddenSource && $0.logicalKey == article.id
        }

        #expect(payload == nil)
        #expect(change?.operation == .delete)
    }

    @Test("Video cited papers are queued for CloudKit sync")
    func videoCitedPapersAreQueuedForSync() throws {
        let store = try makeInMemoryStore()
        let video = makeArticle(url: "https://youtube.com/watch?v=cited", title: "Talk")
        try store.saveSource(video)

        let paper = VideoCitedPaper(
            sourceID: video.id,
            title: "Mitochondrial transplantation in vivo",
            doi: "10.1000/mito",
            slideTimeSeconds: 412
        )
        try store.saveVideoCitedPaper(paper)

        let payload = try store.loadVideoCitedPaperForSync(paper.id)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .videoCitedPaper && $0.logicalKey == paper.id
        }

        #expect(payload?.paper.id == paper.id)
        #expect(payload?.paper.sourceID == video.id)
        #expect(payload?.sourceIdentity?.sourceID == video.id)
        #expect(try store.loadVideoCitedPapers(forSourceID: video.id).count == 1)
        #expect(change?.operation == .save)
    }

    @Test("Remote video cited paper record keeps both source links")
    func remoteVideoCitedPaperKeepsBothSourceLinks() throws {
        let store = try makeInMemoryStore()
        let video = makeArticle(url: "https://youtube.com/watch?v=remote-cited", title: "Remote Talk")
        var importedPaper = makeArticle(url: "https://doi.org/10.1000/imported", title: "Imported Paper")
        importedPaper.sourceType = .paper
        try store.saveSource(video)
        try store.saveSource(importedPaper)

        let paper = VideoCitedPaper(
            sourceID: video.id,
            title: "Imported Paper",
            status: .imported,
            importedSourceID: importedPaper.id
        )
        try store.saveVideoCitedPaperRecord(
            CloudKitVideoCitedPaperPayload(paper: paper)
        )

        let loaded = try store.loadVideoCitedPaper(id: paper.id)
        #expect(loaded?.sourceID == video.id)
        // The relationship, not just the row, has to survive the trip: a stripped
        // importedSourceID would make an already-imported paper look like an open candidate.
        #expect(loaded?.importedSourceID == importedPaper.id)
        #expect(loaded?.status == .imported)
    }

    @Test("A linked source keeps its kind and context through the store and the CloudKit payload")
    func linkedSourceCandidateRoundTrip() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.substack.com/p/post", title: "A post")
        try store.saveSource(article)

        let linked = VideoCitedPaper(
            sourceID: article.id,
            title: "A talk on mitochondria",
            url: "https://www.youtube.com/watch?v=abc123",
            kind: .video,
            context: "Recommended as a primer."
        )
        try store.saveVideoCitedPaper(linked)

        let loaded = try store.loadVideoCitedPaper(id: linked.id)
        #expect(loaded?.kind == .video)
        #expect(loaded?.context == "Recommended as a primer.")
        #expect(loaded?.url == linked.url)

        // The relationship rides the record as JSON, so the other Mac reads the same kind
        // and context and offers the candidate as the video it is.
        let payload = try #require(try store.loadVideoCitedPaperForSync(linked.id))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CloudKitVideoCitedPaperPayload.self, from: data)
        #expect(decoded.paper.kind == .video)
        #expect(decoded.paper.context == "Recommended as a primer.")

        let remote = try makeInMemoryStore()
        try remote.saveSource(article)
        try remote.saveVideoCitedPaperRecord(decoded)
        let applied = try remote.loadVideoCitedPaper(id: linked.id)
        #expect(applied?.kind == .video)
        #expect(applied?.context == "Recommended as a primer.")
    }

    @Test("Deleting a video cited paper queues a CloudKit deletion")
    func deletingVideoCitedPaperQueuesCloudKitDeletion() throws {
        let store = try makeInMemoryStore()
        let video = makeArticle(url: "https://youtube.com/watch?v=deleted-cited", title: "Talk")
        try store.saveSource(video)

        let paper = VideoCitedPaper(sourceID: video.id, title: "Dropped candidate")
        try store.saveVideoCitedPaper(paper)
        try store.clearAllPendingSyncChanges()
        try store.deleteVideoCitedPaper(id: paper.id)

        let payload = try store.loadVideoCitedPaperForSync(paper.id)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .videoCitedPaper && $0.logicalKey == paper.id
        }

        #expect(payload == nil)
        #expect(change?.operation == .delete)
    }

    @Test("Hidden podcast shows are queued for CloudKit sync")
    func hiddenPodcastShowsAreQueuedForSync() throws {
        let store = try makeInMemoryStore()

        try store.setPodcastShowHidden("Example Show", hidden: true)

        let payload = try store.loadHiddenPodcastShowForSync("Example Show")
        let change = try store.pendingSyncChanges().first {
            $0.entity == .hiddenPodcastShow && $0.logicalKey == "Example Show"
        }

        #expect(payload?.showName == "Example Show")
        #expect(change?.operation == .save)
    }

    @Test("Hidden podcast show marks matching episodes hidden")
    func hiddenPodcastShowMarksMatchingEpisodesHidden() throws {
        let store = try makeInMemoryStore()
        var podcast = StudioArticle(
            url: "apple-podcast://episode/1001",
            title: "Episode 1001",
            sourceType: .podcast
        )
        podcast.domain = "Example Show"

        try store.saveSource(podcast)
        try store.setPodcastShowHidden("Example Show", hidden: true)

        let hidden = try #require(store.loadSources().first(where: { $0.id == podcast.id }))
        #expect(hidden.isHidden == true)

        try store.setPodcastEpisodeVisibleOverride(podcast.id, visible: true)

        let visible = try #require(store.loadSources().first(where: { $0.id == podcast.id }))
        #expect(visible.isHidden == false)
    }

    @Test("Unhiding a show reveals the episodes hidden after it and keeps the ones hidden before")
    func unhidingAShowRevealsEpisodesHiddenAfterIt() throws {
        let store = try makeInMemoryStore()
        var chosen = StudioArticle(url: "apple-podcast://episode/2001", title: "Skipped on purpose", sourceType: .podcast)
        chosen.domain = "Example Show"
        var consequence = StudioArticle(url: "apple-podcast://episode/2002", title: "Hidden with the show", sourceType: .podcast)
        consequence.domain = "Example Show"
        var untouched = StudioArticle(url: "apple-podcast://episode/2003", title: "Never hidden itself", sourceType: .podcast)
        untouched.domain = "Example Show"
        for article in [chosen, consequence, untouched] { try store.saveSource(article) }

        // The learner hid one episode, then the whole show; another device then
        // mirrored the show's state onto an episode of its own accord.
        try store.setPodcastEpisodeHidden(chosen.id, hidden: true)
        usleep(5_000)
        try store.setPodcastShowHidden("Example Show", hidden: true)
        usleep(5_000)
        try store.setPodcastEpisodeHidden(consequence.id, hidden: true)

        let revealed = try store.setPodcastShowHidden("Example Show", hidden: false)

        #expect(revealed == [consequence.id])
        let hiddenIDs = try store.loadHiddenPodcastEpisodeIDs()
        #expect(hiddenIDs.contains(chosen.id))
        #expect(!hiddenIDs.contains(consequence.id))
        #expect(!hiddenIDs.contains(untouched.id))
        let sources = try store.loadSources()
        #expect(sources.first { $0.id == chosen.id }?.isHidden == true)
        #expect(sources.first { $0.id == consequence.id }?.isHidden == false)
        // The revealed episode's hidden record is withdrawn from sync too.
        let change = try store.pendingSyncChanges().first {
            $0.entity == .hiddenSource && $0.logicalKey == consequence.id
        }
        #expect(change?.operation == .delete)
    }

    @Test("Podcast dedup recognizes legacy single-slash episode URLs")
    func podcastDedupRecognizesLegacySingleSlashEpisodeURLs() throws {
        let store = try makeInMemoryStore()
        var legacy = StudioArticle(
            url: "apple-podcast:/episode/1000758651501",
            title: "He Hacked Finance And Is Now Building An AI CEO",
            sourceType: .podcast
        )
        legacy.domain = "Core Memory"

        try store.saveSource(legacy)

        var rediscovered = StudioArticle(
            url: "apple-podcast://episode/1000758651501",
            title: legacy.title,
            sourceType: .podcast
        )
        rediscovered.domain = legacy.domain

        #expect(try store.insertSourceIfNew(&rediscovered) == false)
        #expect(try store.loadSources().count == 1)
        #expect(store.sourceExistsByURL(rediscovered.url)?.id == legacy.id)
    }

    @Test("Private podcast dedup recognizes local UUID changes")
    func privatePodcastDedupRecognizesLocalUUIDChanges() throws {
        let store = try makeInMemoryStore()
        let playedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var first = StudioArticle(
            url: "apple-podcast://episode/local/first-local-id",
            title: "Private Feed Episode",
            sourceType: .podcast
        )
        first.domain = "Private Feed"
        first.dateAdded = playedAt

        try store.saveSource(first)

        var rediscovered = StudioArticle(
            url: "apple-podcast://episode/private/stable-feed-hash",
            title: first.title,
            sourceType: .podcast
        )
        rediscovered.domain = first.domain
        rediscovered.dateAdded = playedAt

        #expect(try store.insertSourceIfNew(&rediscovered) == false)
        #expect(try store.loadSources().count == 1)
    }

    @Test("Unhiding podcast shows queues a CloudKit deletion")
    func unhiddenPodcastShowsQueueCloudKitDeletion() throws {
        let store = try makeInMemoryStore()

        try store.setPodcastShowHidden("Example Show", hidden: true)
        try store.clearAllPendingSyncChanges()
        try store.setPodcastShowHidden("Example Show", hidden: false)

        let payload = try store.loadHiddenPodcastShowForSync("Example Show")
        let change = try store.pendingSyncChanges().first {
            $0.entity == .hiddenPodcastShow && $0.logicalKey == "Example Show"
        }

        #expect(payload == nil)
        #expect(change?.operation == .delete)
    }

    @Test("Hidden YouTube channels hide videos, allow overrides, and sync")
    func hiddenYouTubeChannelVisibilityAndSync() throws {
        let store = try makeInMemoryStore()
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=hidden-channel",
            title: "Channel video",
            sourceType: .video
        )
        video.domain = "Example Channel"
        try store.saveSource(video)

        try store.setYouTubeChannelHidden("Example Channel", hidden: true)

        let hidden = try #require(store.loadSources().first(where: { $0.id == video.id }))
        let payload = try store.loadHiddenYouTubeChannelForSync("example channel")
        let save = try store.pendingSyncChanges().first {
            $0.entity == .hiddenYouTubeChannel && $0.logicalKey == "Example Channel"
        }
        #expect(hidden.isHidden)
        #expect(payload?.channelName == "Example Channel")
        #expect(save?.operation == .save)

        try store.setYouTubeVideoVisibleOverride(video.id, visible: true)
        let visible = try #require(store.loadSources().first(where: { $0.id == video.id }))
        #expect(!visible.isHidden)

        try store.clearAllPendingSyncChanges()
        try store.setYouTubeChannelHidden("Example Channel", hidden: false)
        let deletion = try store.pendingSyncChanges().first {
            $0.entity == .hiddenYouTubeChannel && $0.logicalKey == "Example Channel"
        }
        #expect(try store.loadHiddenYouTubeChannels().isEmpty)
        #expect(deletion?.operation == .delete)
    }

    @Test("Projection repair stays visible to concurrent library readers")
    func projectionRepairIsAtomicForConcurrentReaders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceProjectionAtomicRepairTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try KnowledgeStore(storeDirectory: root)
        let article = makeArticle(
            url: "https://example.com/projection-repair",
            title: "Projection Repair"
        )
        try writer.saveSource(article)

        // Open the second connection before making the definition stale, matching
        // the app's storage and CloudKit connections during startup.
        let reader = try KnowledgeStore(storeDirectory: root)
        let expected = KnowledgeStore.sourceProjectionViewSQL(
            sourceColumnNames: try writer.tableColumnNames("sources"),
            readingStates: writer.keepsReadingStates
        )
        let stale = expected.replacingOccurrences(
            of: "CREATE VIEW source_projection AS",
            with: "CREATE VIEW source_projection AS\n            -- stale test definition"
        )
        try writer.execForTesting("BEGIN IMMEDIATE")
        try writer.execForTesting("DROP VIEW source_projection")
        try writer.execForTesting(stale)
        try writer.execForTesting("COMMIT")

        let didDrop = DispatchSemaphore(value: 0)
        let mayCreate = DispatchSemaphore(value: 0)
        let didFinish = DispatchSemaphore(value: 0)
        writer.afterSourceProjectionDropForTesting = {
            didDrop.signal()
            _ = mayCreate.wait(timeout: .now() + 5)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { didFinish.signal() }
            try? writer.reconcileSourceProjectionView()
        }

        let reachedDrop = didDrop.wait(timeout: .now() + 5)
        #expect(reachedDrop == .success)
        if reachedDrop == .success {
            // While the writer has dropped the view inside its uncommitted
            // transaction, another connection must still load the intact library.
            let visibleSources = try reader.loadSourcesWithoutContent()
            #expect(visibleSources.contains { $0.id == article.id })
        }

        mayCreate.signal()
        #expect(didFinish.wait(timeout: .now() + 5) == .success)

        let repairedSources = try reader.loadSourcesWithoutContent()
        #expect(repairedSources.contains { $0.id == article.id })
        var repairedDefinition: String?
        try reader.query("SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'source_projection'") { stmt in
            repairedDefinition = reader.string(stmt, 0)
        }
        #expect(
            repairedDefinition?.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var rewroteHealthyView = false
        writer.afterSourceProjectionDropForTesting = {
            rewroteHealthyView = true
        }
        try writer.reconcileSourceProjectionView()
        #expect(!rewroteHealthyView)

        // A view left absent by an older build's interrupted non-transactional
        // repair is also restored without touching any source rows.
        writer.afterSourceProjectionDropForTesting = nil
        try writer.execForTesting("DROP VIEW source_projection")
        try writer.reconcileSourceProjectionView()
        #expect(try reader.loadSourcesWithoutContent().contains { $0.id == article.id })
    }

    @Test("A source filed into two groups still projects exactly one row")
    func sourceInTwoGroupsNotebooksOneRow() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/two-groups", title: "Two Groups")
        try store.saveSource(article)

        // `group_members` is keyed `(source_id, group_id)`, so a second
        // membership is representable however it got written. It used to fan
        // `source_projection` out into two rows, and callers that key rows by
        // source id trap the process on the duplicate rather than degrade.
        try store.updateParentGroup(article.id, "aaa-group")
        try store.execForTesting(
            "INSERT INTO group_members (source_id, group_id) VALUES ('\(article.id)', 'zzz-group')"
        )

        var projectedRows = 0
        var projectedGroup: String?
        try store.query("SELECT parent_group FROM source_projection WHERE id = '\(article.id)'") { stmt in
            projectedRows += 1
            projectedGroup = store.string(stmt, 0)
        }
        #expect(projectedRows == 1)
        // The surviving membership is the lowest group id — deterministic, and
        // the row the `(source_id, group_id)` primary key already made SQLite
        // emit first, so a first-row-wins caller sees no folder move.
        #expect(projectedGroup == "aaa-group")

        #expect(try store.loadActiveSources().filter { $0.id == article.id }.count == 1)
    }

    @Test("Dismissing a source archives matching active source")
    func dismissingSourceArchivesMatchingActiveSource() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/dismiss-me", title: "Dismiss Me")

        try store.saveSource(article)
        try store.dismissSource(url: article.url, title: article.title)

        let active = try store.loadActiveSources()
        let all = try store.loadSourcesWithoutContent()
        let sourceChange = try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == article.id
        }
        let dismissedChange = try store.pendingSyncChanges().first {
            $0.entity == .dismissedSource && $0.logicalKey == article.url
        }

        #expect(active.isEmpty)
        #expect(all.first?.status == .archived)
        #expect(sourceChange?.operation == .save)
        #expect(dismissedChange?.operation == .save)
    }

    @Test("Remote dismissed source record archives matching active source")
    func remoteDismissedSourceArchivesMatchingActiveSource() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/remote-dismissed", title: "Remote Dismissed")

        try store.saveSource(article)
        try store.saveDismissedSourceRecord(
            CloudKitDismissedSourcePayload(
                url: article.url,
                title: article.title,
                dismissedAt: Date()
            )
        )

        let active = try store.loadActiveSources()
        let all = try store.loadSourcesWithoutContent()

        #expect(active.isEmpty)
        #expect(all.first?.status == .archived)
    }

    @Test("Book metadata keeps ID and title separate")
    func bookMetadataKeepsIDAndTitleSeparate() throws {
        let store = try makeInMemoryStore()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"

        try store.saveBookMetadata(groupName: uuid, title: uuid, coverPath: "Books/Immune/cover.jpg")

        let books = try store.loadBooks()

        #expect(books.titles[uuid] == uuid)
        #expect(books.titles["Immune"] == nil)
    }

    @Test("Single book metadata save persists author")
    func singleBookMetadataSavePersistsAuthor() throws {
        let store = try makeInMemoryStore()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"

        try store.saveBookMetadata(
            groupName: uuid,
            title: "Immune",
            subtitle: "A Journey into the Mysterious System That Keeps You Alive",
            author: "Philipp Dettmer",
            edition: "First Edition",
            coverPath: "Books/Immune/cover.jpg"
        )

        let payload = try store.loadBookForSync(uuid)

        #expect(payload?.title == "Immune")
        #expect(payload?.subtitle == "A Journey into the Mysterious System That Keeps You Alive")
        #expect(payload?.author == "Philipp Dettmer")
        #expect(payload?.edition == "First Edition")
        #expect(payload?.coverPath == "Books/Immune/cover.jpg")
    }

    @Test("Remote book payload applies to legacy book table")
    func remoteBookPayloadAppliesToLegacyBookTable() throws {
        let store = try makeInMemoryStore()
        let uuid = "2113A94E-BCC1-4670-9AAC-8E38EE9D7234"
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try store.execForTesting("DROP TABLE books")
        try store.execForTesting("""
            CREATE TABLE books (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                author TEXT,
                cover_path TEXT,
                kind TEXT
            )
        """)

        try store.saveBookRecord(
            CloudKitBookPayload(
                id: uuid,
                title: "An Introduction to Systems Biology",
                subtitle: "Design Principles of Biological Circuits",
                author: "Uri Alon",
                edition: "Second Edition",
                coverPath: "Books/SystemsBiology/cover.jpg"
            )
        )

        let books = try store.loadBooks()

        #expect(books.titles[uuid] == "An Introduction to Systems Biology")
        #expect(books.authors[uuid] == "Uri Alon")
        #expect(books.coverPaths[uuid]?.hasSuffix("Books/SystemsBiology/cover.jpg") == true)
        #expect(books.subtitles[uuid] == nil)
        #expect(books.editions[uuid] == nil)
    }

    @Test("Remote book payload preserves payload title")
    func remoteBookPayloadPreservesPayloadTitle() throws {
        let store = try makeInMemoryStore()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"

        try store.saveBookRecord(
            CloudKitBookPayload(
                id: uuid,
                title: uuid,
                subtitle: "An Elegant Tour",
                author: "Philipp Dettmer",
                edition: "Second Edition",
                coverPath: "Books/Immune/cover.jpg"
            )
        )

        let payload = try store.loadBookForSync(uuid)

        #expect(payload?.title == uuid)
        #expect(payload?.subtitle == "An Elegant Tour")
        #expect(payload?.edition == "Second Edition")
    }

    @Test("Book subtitle and edition round-trip through single-field saves")
    func bookSubtitleAndEditionRoundTripThroughFieldSaves() throws {
        let store = try makeInMemoryStore()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"
        try store.saveBookMetadata(groupName: uuid, title: "Tidal Notes", coverPath: nil)

        try store.setBookField(.subtitle, of: uuid, to: "A Field Guide to the Shore")
        try store.setBookField(.author, of: uuid, to: "Zara Holt")
        try store.setBookField(.edition, of: uuid, to: "First Edition")

        let books = try store.loadBooks()

        #expect(books.titles[uuid] == "Tidal Notes")
        #expect(books.subtitles[uuid] == "A Field Guide to the Shore")
        #expect(books.authors[uuid] == "Zara Holt")
        #expect(books.editions[uuid] == "First Edition")
    }

    /// The regression the whole-table book save had: a book that arrived by
    /// sync before the view model reloaded was deleted, and the deletion
    /// synced, when the learner edited any other book.
    @Test("Editing one book's field leaves a book memory never loaded, and queues no deletion")
    func editingOneBookFieldLeavesOtherBooksAndQueuesNoDeletion() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(groupName: "book-edited", title: "Tidal Notes", author: "Zara Holt", coverPath: nil, kind: "Field Guide")
        // Arrived by sync: in the database, not in any view model's memory.
        try store.saveBookRecord(
            CloudKitBookPayload(
                id: "book-synced",
                title: "Salt Marsh Ledger",
                subtitle: "Notes from Acme Lab",
                author: "Ines Varga",
                edition: "Second Edition",
                coverPath: nil
            )
        )
        try store.clearAllPendingSyncChanges()

        try store.setBookField(.edition, of: "book-edited", to: "Third Edition")
        try store.setBookField(.kind, of: "book-edited", to: "")

        let books = try store.loadBooks()
        #expect(books.titles["book-synced"] == "Salt Marsh Ledger")
        #expect(books.subtitles["book-synced"] == "Notes from Acme Lab")
        #expect(books.authors["book-synced"] == "Ines Varga")
        #expect(books.editions["book-synced"] == "Second Edition")
        // The edited book changed only in the field written; a cleared field is nil.
        #expect(books.titles["book-edited"] == "Tidal Notes")
        #expect(books.authors["book-edited"] == "Zara Holt")
        #expect(books.editions["book-edited"] == "Third Edition")
        #expect(books.kinds["book-edited"] == nil)

        let pending = try store.pendingSyncChanges()
        #expect(!pending.contains { $0.operation == .delete })
        #expect(pending.filter { $0.entity == .book }.map(\.logicalKey) == ["book-edited"])
    }

    @Test("Setting a field of a book with no row throws and writes nothing")
    func settingFieldOfMissingBookThrows() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.clearAllPendingSyncChanges()

        #expect(throws: KnowledgeStoreError.self) {
            try store.setBookField(.author, of: "no-such-book", to: "Zara Holt")
        }
        #expect(try store.loadBooks().titles.isEmpty)
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test("insertSourceIfNew skips existing active source")
    func testInsertSourceIfNewSkipsExistingActiveSource() throws {
        let store = try makeInMemoryStore()
        var article1 = makeArticle(url: "https://example.com/post-1", title: "Original Title")
        let inserted1 = try store.insertSourceIfNew(&article1)
        #expect(inserted1)

        var article2 = makeArticle(url: "https://example.com/post-1", title: "New Title")
        let inserted2 = try store.insertSourceIfNew(&article2)
        #expect(!inserted2)

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].title == "Original Title")
    }

    @Test("saving grouped source replaces stale group membership")
    func savingGroupedSourceReplacesStaleGroupMembership() throws {
        let store = try makeInMemoryStore()
        let oldGroup = "Immune"
        let newGroup = "91dd38ad-7356-5d08-b691-a44493dff38a"
        var chapter = StudioArticle(
            url: "Books/Immune/Chapters/01 What Is the Immune System?.pdf",
            title: "Immune - 1) What Is the Immune System?",
            sourceType: .book,
            localFilePath: "Books/Immune/Chapters/01 What Is the Immune System?.pdf"
        )

        chapter.parentGroup = oldGroup
        try store.saveSource(chapter)
        chapter.parentGroup = newGroup
        try store.saveSource(chapter)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active.first?.parentGroup == newGroup)
    }

    @Test("book chapter lookup finds archived source by local file path")
    func bookChapterLookupFindsArchivedSourceByLocalFilePath() throws {
        let store = try makeInMemoryStore()
        let relativePath = "Books/Test Book/Chapters/ForeverLMCombinedChapters/01 Introduction.xhtml"
        var chapter = StudioArticle(
            url: relativePath,
            title: "Introduction",
            sourceType: .book,
            localFilePath: relativePath
        )
        chapter.parentGroup = "book-test"
        try store.insertSourceIfNew(&chapter)
        try store.archiveSource(chapter.id)

        let absolutePath = "/Users/other/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/\(relativePath)"
        #expect(store.sourceExistsByURL(absolutePath)?.id == chapter.id)
        #expect(store.sourceExistsByNormalizedURL(URLNormalizer.normalize(absolutePath))?.id == chapter.id)
        #expect(store.sourceExistsByBookLocalFilePath(absolutePath)?.id == chapter.id)
        #expect(store.sourceExistsByBookLocalFilePath(absolutePath)?.status == .archived)
    }

    @Test("a team's copy of a paper does not stand in for the learner's own row")
    func teamCopyDoesNotBlockOwnImport() throws {
        let store = try makeInMemoryStore()
        let url = "https://pmc.ncbi.nlm.nih.gov/articles/PMC2924931/"
        // A team's copy has a team-scoped id, as sharing makes it; a paper's own id is minted from its
        // address, so a copy left on that id would be the learner's own row.
        var teamCopy = StudioArticle(
            url: url, title: "Mitochondrial uncoupling and lifespan", sourceType: .paper,
            id: TeamContentIdentity.sourceID(teamID: "team-1", url: url)
        )
        teamCopy.teamID = "team-1"
        try store.insertSourceIfNew(&teamCopy)

        #expect(store.sourceExistsByURL(url) == nil)
        #expect(store.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) == nil)

        var own = StudioArticle(url: url, title: "Mitochondrial uncoupling and lifespan", sourceType: .paper)
        try store.insertSourceIfNew(&own)
        #expect(store.sourceExistsByURL(url)?.id == own.id)
        #expect(own.id != teamCopy.id)
    }

    @Test("CloudKit duplicate replacement preserves local source content")
    func cloudKitDuplicateReplacementPreservesLocalSourceContent() throws {
        let store = try makeInMemoryStore()
        var local = StudioArticle(
            url: "Books/Immune/Chapters/01 What Is the Immune System?.pdf",
            title: "Local Chapter",
            sourceType: .book,
            localFilePath: "Books/Immune/Chapters/01 What Is the Immune System?.pdf",
            id: "local-source"
        )
        local.parentGroup = "Immune"
        local.content = "The immune system protects the body."
        try store.saveSource(local)

        var remote = StudioArticle(
            url: "Books/Immune/Chapters/01 What Is the Immune System?.pdf",
            title: "Remote Chapter",
            sourceType: .book,
            localFilePath: "Books/Immune/Chapters/01 What Is the Immune System?.pdf",
            id: "remote-source"
        )
        remote.parentGroup = "91dd38ad-7356-5d08-b691-a44493dff38a"
        remote.content = try store.loadLocalDuplicateContent(of: remote)

        try store.withoutSyncTracking {
            try store.deleteLocalDuplicate(of: remote)
            try store.saveSource(remote)
        }

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active.first?.id == remote.id)
        #expect(try store.loadSourceContent(remote.id) == "The immune system protects the body.")
    }

    @Test("Paper identity merge archives the duplicate and preserves relationships")
    func paperIdentityMergePreservesRelationships() throws {
        let store = try makeInMemoryStore()
        var canonical = StudioArticle(
            url: "https://www.nature.com/articles/s42255-024-01200-x",
            title: "Recommendations for mitochondria transfer and transplantation nomenclature and characterization",
            sourceType: .paper,
            id: "canonical-paper"
        )
        canonical.state = .queued
        canonical.doi = "10.1038/s42255-024-01200-x"
        var duplicate = StudioArticle(
            url: "/Users/other/Papers/10.1038_s42255-024-01200-x.pdf",
            title: canonical.title,
            sourceType: .paper,
            localFilePath: "Papers/10.1038_s42255-024-01200-x.pdf",
            id: "duplicate-paper"
        )
        duplicate.state = .queued
        duplicate.doi = canonical.doi
        try store.saveSource(canonical)
        try store.saveSource(duplicate)

        let goalID = "mitochondria-notebook"
        let now = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveLearningGoalRecord(
            LearningGoalRecord(
                id: goalID,
                title: "Mitochondria",
                startAt: now,
                endAt: Date(timeIntervalSinceReferenceDate: 200),
                createdAt: now,
                updatedAt: now,
                status: LearningGoalStatus.active.rawValue,
                items: [
                    LearningGoalItem(
                        id: "canonical-item",
                        goalID: goalID,
                        sourceID: canonical.id,
                        addedAt: now,
                        reviewState: LearningGoalItemReviewState.rejected.rawValue
                    ),
                    LearningGoalItem(
                        id: "duplicate-item",
                        goalID: goalID,
                        sourceID: duplicate.id,
                        addedAt: now,
                        reviewState: LearningGoalItemReviewState.approved.rawValue
                    ),
                ],
                kind: "companion"
            )
        )
        try store.createReviewSession(
            id: "duplicate-review",
            topic: "Review",
            sourceIDs: [canonical.id, duplicate.id]
        )

        try store.archivePaperIdentityDuplicate(
            duplicate.id,
            replacingWith: canonical.id
        )

        #expect(try store.loadActiveSources().map(\.id) == [canonical.id])
        let storedDuplicate = try store.loadSources().first { $0.id == duplicate.id }
        #expect(storedDuplicate?.status == .archived)
        let goalItems = try store.loadLearningGoalItems(goalID: goalID)
        #expect(goalItems.count == 1)
        #expect(goalItems.first?.sourceID == canonical.id)
        #expect(goalItems.first?.reviewState == LearningGoalItemReviewState.approved.rawValue)
        #expect(try store.reviewSessionSourceIDsBySessionID()["duplicate-review"] == [canonical.id])
    }

    /// A dismissal arriving from CloudKit archives matching local sources, and
    /// that archive has to reach CloudKit too. It happens inside
    /// `withoutSyncTracking` — which exists to stop the arriving DismissedSource
    /// record from echoing back — so `archiveSource`'s own change tracking is
    /// suppressed. Left unpublished, the server keeps the source active with its
    /// text already wiped here, and other devices list a source that opens to
    /// nothing.
    @Test("dismissal archive publishes to CloudKit even under sync suppression")
    func testDismissalArchivePublishesUnderSuppression() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        try store.insertSourceIfNew(&article)
        // Clear the insert's own pending change so the assertion can only be
        // satisfied by the archive republishing itself.
        try store.clearPendingSyncChange(entity: .source, logicalKey: article.id)

        try store.withoutSyncTracking {
            try store.saveDismissedSourceRecord(
                CloudKitDismissedSourcePayload(
                    url: "https://example.com/post-1",
                    title: "Post 1",
                    dismissedAt: Date()
                )
            )
        }

        #expect(try store.loadActiveSources().isEmpty)
        #expect(
            try store.hasPendingSyncChange(entity: .source, logicalKey: article.id),
            "The archive was never queued for CloudKit, so other devices keep showing this source as active."
        )
    }

    @Test("insertSourceIfNew skips archived source")
    func testInsertSourceIfNewSkipsArchivedSource() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-1", title: "Original")
        try store.insertSourceIfNew(&article)

        try store.archiveSource(article.id)

        var fresh = makeArticle(url: "https://example.com/post-1", title: "Refreshed")
        let inserted = try store.insertSourceIfNew(&fresh)
        #expect(!inserted, "Archived sources should not be re-inserted")
    }

    @Test("archiveSource cascades to content")
    func testArchiveCascadesContent() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-1", title: "Post")
        article.content = "Full text content of the article."
        try store.insertSourceIfNew(&article)

        // Verify content exists
        let contentBefore = try store.loadSourceContent(article.id)
        #expect(contentBefore != nil)

        try store.archiveSource(article.id)

        let contentAfter = try store.loadSourceContent(article.id)
        #expect(contentAfter == nil)
    }

    @Test("archiveSource does not delete other sources")
    func testArchiveDoesNotDeleteOtherSources() throws {
        let store = try makeInMemoryStore()
        var article1 = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        var article2 = makeArticle(url: "https://example.com/post-2", title: "Post 2")
        try store.insertSourceIfNew(&article1)
        try store.insertSourceIfNew(&article2)

        try store.archiveSource(article1.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].title == "Post 2")

        // The archived source still exists in the DB
        let all = try store.loadSources()
        #expect(all.count == 2)
    }

    @Test("normalized URL prevents duplicates")
    func testNormalizedURLPreventsDuplicates() throws {
        let store = try makeInMemoryStore()
        // Two URLs that normalize to the same value (trailing slash difference)
        var article1 = makeArticle(url: "https://example.com/post", title: "Without Slash")
        var article2 = makeArticle(url: "https://example.com/post/", title: "With Slash")

        // Verify they normalize to the same thing
        #expect(article1.normalizedURL == article2.normalizedURL)

        let inserted1 = try store.insertSourceIfNew(&article1)
        let inserted2 = try store.insertSourceIfNew(&article2)
        #expect(inserted1)
        #expect(!inserted2)

        let all = try store.loadSources()
        #expect(all.count == 1)
    }

    @Test("YouTube URL variants do not create duplicate video sources")
    func youtubeURLVariantsDoNotCreateDuplicateVideoSources() throws {
        let store = try makeInMemoryStore()
        var original = StudioArticle(
            url: "https://youtu.be/abc123",
            title: "Original",
            sourceType: .video
        )
        var duplicate = StudioArticle(
            url: "https://www.youtube.com/watch?v=abc123&list=PL-course",
            title: "Playlist Variant",
            sourceType: .video
        )

        #expect(try store.insertSourceIfNew(&original))
        #expect(!(try store.insertSourceIfNew(&duplicate)))

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].id == original.id)
    }

    @Test("YouTube video title is preserved before persistence")
    func youtubeVideoTitleIsPreservedBeforePersistence() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://www.youtube.com/watch?v=abc123",
            title: "My Lecture - YouTube",
            sourceType: .video
        )

        #expect(try store.insertSourceIfNew(&article))
        #expect(article.title == "My Lecture - YouTube")

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].title == "My Lecture - YouTube")
    }

    @Test("loadActiveSources excludes archived")
    func testLoadActiveSourcesExcludesArchived() throws {
        let store = try makeInMemoryStore()
        var article1 = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        var article2 = makeArticle(url: "https://example.com/post-2", title: "Post 2")
        try store.insertSourceIfNew(&article1)
        try store.insertSourceIfNew(&article2)

        try store.archiveSource(article1.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].title == "Post 2")
    }

    @Test("source review dates come from completed reviews and Schedule items")
    func testSourceReviewDates() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/review-me",
            title: "Review Me",
            sourceType: .article,
            id: "source-review-1"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.insertSourceIfNew(&article)
        var scheduledArticle = StudioArticle(
            url: "https://example.com/schedule-reviewed",
            title: "Schedule Reviewed",
            sourceType: .article,
            id: "source-schedule-reviewed"
        )
        scheduledArticle.normalizedURL = URLNormalizer.normalize(scheduledArticle.url)
        try store.insertSourceIfNew(&scheduledArticle)

        try store.createReviewSession(
            id: "session-active",
            topic: "Draft review",
            sourceIDs: [article.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        #expect((try store.sourceReviewDates())[article.id] == nil)

        try store.completeReviewSession(
            sessionID: "session-active",
            overallScore: 0.8,
            summary: "Covered the main points.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        #expect((try store.sourceReviewDates())[article.id] == Date(timeIntervalSinceReferenceDate: 200))

        _ = try store.saveReviewSessionLink(
            title: "Claude follow-up review",
            url: "https://claude.ai/share/reviewed",
            sourceIDs: [article.id],
            createdAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        #expect((try store.sourceReviewDates())[article.id] == Date(timeIntervalSinceReferenceDate: 300))

        let scheduleReviewedAt = Date(timeIntervalSinceReferenceDate: 400)
        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: LearningGoalRecord(
                    id: "goal-reviewed",
                    title: "Reviewed Plan",
                    startAt: Date(timeIntervalSinceReferenceDate: 0),
                    endAt: Date(timeIntervalSinceReferenceDate: 7 * 24 * 60 * 60),
                    createdAt: Date(timeIntervalSinceReferenceDate: 0),
                    updatedAt: scheduleReviewedAt,
                    status: "active",
                    items: [
                        LearningGoalItem(
                            id: "item-reviewed",
                            goalID: "goal-reviewed",
                            sourceID: scheduledArticle.id,
                            addedAt: Date(timeIntervalSinceReferenceDate: 0),
                            completedAt: scheduleReviewedAt
                        )
                    ]
                ),
                sourceIdentities: []
            )
        )
        #expect((try store.sourceReviewDates())[scheduledArticle.id] == scheduleReviewedAt)
    }

    @Test("review eligibility follows equivalent paper DOI records")
    func reviewEligibilityFollowsEquivalentPaperDOIRecords() throws {
        let store = try makeInMemoryStore()
        let doi = "10.1101/2026.01.02.123456"
        var detectedPaper = StudioArticle(
            url: "https://doi.org/\(doi)",
            title: "Detected Paper",
            sourceType: .paper,
            id: "detected-paper"
        )
        detectedPaper.doi = doi
        var scheduledPaper = StudioArticle(
            url: "Papers/detected-paper.pdf",
            title: "Scheduled Paper",
            sourceType: .paper,
            id: "scheduled-paper"
        )
        scheduledPaper.doi = doi.uppercased()
        try store.saveSource(detectedPaper)
        try store.saveSource(scheduledPaper)

        try store.createReviewSession(
            id: "session-paper-review",
            topic: "Detected paper review",
            sourceIDs: [detectedPaper.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.completeReviewSession(
            sessionID: "session-paper-review",
            overallScore: nil,
            summary: "Reviewed the detected paper.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        #expect(try store.sourceIdsWithLinkedChatSession().contains(scheduledPaper.id))
        #expect(try store.sourceHasLinkedChatSession(scheduledPaper.id))
        #expect((try store.sourceReviewDates())[scheduledPaper.id] == Date(timeIntervalSinceReferenceDate: 200))
    }

    @Test("review sessions store the last in-app model used")
    func reviewSessionsStoreLastModelUsed() throws {
        let store = try makeInMemoryStore()

        try store.createReviewSession(
            id: "session-model",
            topic: "Model review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            modelProvider: AIProvider.openai.rawValue,
            modelID: "gpt-5.4"
        )

        var session = try #require(try store.loadReviewSessionLinks().first { $0.id == "session-model" })
        #expect(session.modelProvider == AIProvider.openai.rawValue)
        #expect(session.modelID == "gpt-5.4")

        try store.updateReviewSessionModel(
            sessionID: "session-model",
            modelProvider: AIProvider.anthropic.rawValue,
            modelID: "claude-sonnet-4-6",
            modelEffort: AIEffort.high.rawValue,
            modelSpeed: nil
        )

        session = try #require(try store.loadReviewSessionLinks().first { $0.id == "session-model" })
        #expect(session.modelProvider == AIProvider.anthropic.rawValue)
        #expect(session.modelID == "claude-sonnet-4-6")
        #expect(try store.loadReviewSessionModelRoute(sessionID: "session-model")?.modelEffort == "high")
    }

    @Test("CloudKit review sessions remap linked sources by identity")
    func cloudKitReviewSessionsRemapLinkedSourcesByIdentity() throws {
        let store = try makeInMemoryStore()
        let localSourceID = "local-review-source"
        let remoteSourceID = "remote-review-source"
        let url = "https://example.com/same-review-source"
        var article = StudioArticle(
            url: url,
            title: "Same Review Source",
            sourceType: .article,
            id: localSourceID
        )
        article.normalizedURL = URLNormalizer.normalize(url)
        try store.saveSource(article)

        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: "remote-session",
                topic: "Remote review",
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: "completed",
                overallScore: 0.9,
                summary: "Reviewed remotely.",
                sourceIDs: [remoteSourceID],
                cardIDs: [],
                exchangeCount: 1,
                modelProvider: AIProvider.gemini.rawValue,
                modelID: "gemini-2.5-pro",
                goalID: "remote-goal",
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "exchange-1",
                        sessionID: "remote-session",
                        sequenceNumber: 1,
                        question: "Explain it.",
                        userAnswer: "Answer.",
                        evaluation: "Good.",
                        score: 0.9,
                        sourceRefs: [remoteSourceID],
                        knowledgeNote: nil,
                        answeredAt: Date(timeIntervalSinceReferenceDate: 150)
                    )
                ],
                sourceIdentities: [
                    CloudKitSourceIdentityPayload(
                        sourceID: remoteSourceID,
                        url: url,
                        normalizedURL: URLNormalizer.normalize(url),
                        doi: nil,
                        publishedDOI: nil
                    )
                ]
            )
        )

        let session = try #require(try store.loadReviewSessionLinks().first { $0.id == "remote-session" })
        #expect(session.sourceIDs == [localSourceID])
        #expect(session.modelProvider == AIProvider.gemini.rawValue)
        #expect(session.modelID == "gemini-2.5-pro")
        #expect(session.goalID == "remote-goal")
        #expect(try store.sourceIdsWithLinkedChatSession().contains(localSourceID))
        #expect((try store.sourceReviewDates())[localSourceID] == Date(timeIntervalSinceReferenceDate: 200))
    }

    @Test("CloudKit review sessions defer missing Source links until the Source arrives")
    func cloudKitReviewSessionsDeferMissingSourceLinks() throws {
        let store = try makeInMemoryStore()
        let sourceID = "later-source"
        let sessionID = "session-before-source-order"

        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: sessionID,
                topic: "Out-of-order review",
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: "completed",
                overallScore: 0.8,
                summary: "The session arrived first.",
                sourceIDs: [sourceID],
                cardIDs: [],
                exchangeCount: 0,
                modelProvider: nil,
                modelID: nil,
                goalID: nil,
                exchanges: []
            )
        )

        var linkCount = -1
        try store.query("SELECT COUNT(*) FROM review_session_sources") { statement in
            linkCount = Int(sqlite3_column_int64(statement, 0))
        }
        #expect(linkCount == 0)
        #expect(try store.loadReviewSessionForSync(sessionID)?.sourceIDs == [sourceID])

        try store.saveSource(StudioArticle(
            url: "https://example.com/later-source",
            title: "Later Source",
            sourceType: .article,
            id: sourceID
        ))

        try store.query("SELECT COUNT(*) FROM review_session_sources") { statement in
            linkCount = Int(sqlite3_column_int64(statement, 0))
        }
        #expect(linkCount == 1)
        #expect(try store.sourceHasLinkedChatSession(sourceID))
    }

    @Test("CloudKit review goal presence preserves legacy links and explicit null clears")
    func cloudKitReviewGoalPresenceIsLossless() throws {
        let store = try makeInMemoryStore()

        func payload(goalID: String?) -> CloudKitReviewSessionPayload {
            CloudKitReviewSessionPayload(
                id: "goal-presence-session",
                topic: "Goal relationship parity",
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: "completed",
                overallScore: 0.8,
                summary: "Reviewed relationship parity.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 0,
                goalID: goalID,
                exchanges: []
            )
        }

        try store.saveReviewSessionRecord(payload(goalID: "goal-linked"))
        #expect(try store.loadReviewSessionLinks().first {
            $0.id == "goal-presence-session"
        }?.goalID == "goal-linked")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let explicitNullData = try encoder.encode(payload(goalID: nil))
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: explicitNullData) as? [String: Any]
        )
        #expect(legacyObject.keys.contains("goalID"))
        #expect(legacyObject["goalID"] is NSNull)

        // A pre-goalID client omitted the field. Updating other session content
        // must not silently detach an existing Notebook relationship.
        legacyObject.removeValue(forKey: "goalID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyPayload = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self,
            from: legacyData
        )
        #expect(!legacyPayload.goalIDFieldIsPresent)
        try store.saveReviewSessionRecord(legacyPayload)
        #expect(try store.loadReviewSessionLinks().first {
            $0.id == "goal-presence-session"
        }?.goalID == "goal-linked")

        // Current clients encode nil as an explicit null, which intentionally
        // clears the relationship and survives a decode/apply round trip.
        let clearingPayload = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self,
            from: explicitNullData
        )
        #expect(clearingPayload.goalIDFieldIsPresent)
        #expect(clearingPayload.goalID == nil)
        try store.saveReviewSessionRecord(clearingPayload)
        #expect(try store.loadReviewSessionLinks().first {
            $0.id == "goal-presence-session"
        }?.goalID == nil)
    }

    @Test("CloudKit preserves and updates a source-less mobile chat")
    func cloudKitPreservesAndUpdatesSourceLessMobileChat() throws {
        let store = try makeInMemoryStore()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let endedAt = Date(timeIntervalSinceReferenceDate: 200)

        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: "ios-live-source-less",
                topic: "Voice session",
                startedAt: startedAt,
                endedAt: endedAt,
                status: "completed",
                overallScore: nil,
                summary: "General CarPlay conversation.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 1,
                modelProvider: AIProvider.gemini.rawValue,
                modelID: "gemini-live",
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "ios-live-source-less::exchange::0000",
                        sessionID: "ios-live-source-less",
                        sequenceNumber: 0,
                        question: "What would you like to review?",
                        userAnswer: "Help me plan today's study session.",
                        evaluation: nil,
                        score: nil,
                        sourceRefs: [],
                        knowledgeNote: "Recorded from an iOS realtime voice session.",
                        answeredAt: endedAt
                    )
                ]
            )
        )

        let session = try #require(
            try store.loadReviewSessionLinks().first { $0.id == "ios-live-source-less" }
        )
        #expect(session.status == "completed")
        #expect(session.sourceIDs.isEmpty)
        #expect(session.exchangeCount == 1)

        let exchanges = try store.loadReviewSessionExchanges(sessionID: session.id)
        #expect(exchanges.count == 1)
        #expect(exchanges[0].sourceRefs.isEmpty)
        #expect(exchanges[0].userAnswer == "Help me plan today's study session.")

        let updatedEndedAt = Date(timeIntervalSinceReferenceDate: 300)
        try store.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: session.id,
                topic: "Voice session",
                startedAt: startedAt,
                endedAt: updatedEndedAt,
                status: "completed",
                overallScore: nil,
                summary: "General CarPlay conversation with two turns.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 2,
                modelProvider: AIProvider.gemini.rawValue,
                modelID: "gemini-live",
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "ios-live-source-less::exchange::0000",
                        sessionID: session.id,
                        sequenceNumber: 0,
                        question: "What would you like to review?",
                        userAnswer: "Help me plan today's study session.",
                        evaluation: "Let's start with your scheduled sources.",
                        score: nil,
                        sourceRefs: [],
                        knowledgeNote: "Recorded from an iOS realtime voice session.",
                        answeredAt: endedAt
                    ),
                    CloudKitReviewExchangePayload(
                        id: "ios-live-source-less::exchange::0001",
                        sessionID: session.id,
                        sequenceNumber: 1,
                        question: "Which source should we discuss first?",
                        userAnswer: "The first one on today's Schedule.",
                        evaluation: "I'll open that source now.",
                        score: nil,
                        sourceRefs: [],
                        knowledgeNote: "Recorded from an iOS realtime voice session.",
                        answeredAt: updatedEndedAt
                    )
                ]
            )
        )

        let roundTrip = try #require(try store.loadReviewSessionForSync(session.id))
        #expect(roundTrip.sourceIDs.isEmpty)
        #expect(roundTrip.exchangeCount == 2)
        #expect(roundTrip.exchanges.count == 2)
        #expect(roundTrip.exchanges[0].evaluation == "Let's start with your scheduled sources.")
        #expect(roundTrip.exchanges[1].userAnswer == "The first one on today's Schedule.")
        #expect(roundTrip.sourceIdentities.isEmpty)
    }

    @Test("CloudKit review session payload preserves its Goal link")
    func cloudKitReviewSessionPayloadPreservesGoalLink() throws {
        let store = try makeInMemoryStore()
        try store.createReviewSession(
            id: "goal-linked-session",
            topic: "Goal review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            goalID: "goal-123"
        )

        let payload = try #require(try store.loadReviewSessionForSync("goal-linked-session"))
        #expect(payload.goalID == "goal-123")
    }

    @Test("CloudKit learning goals remap item sources by identity")
    func cloudKitLearningGoalsRemapItemSourcesByIdentity() throws {
        let store = try makeInMemoryStore()
        let localSourceID = "local-scheduled-source"
        let remoteSourceID = "remote-scheduled-source"
        let url = "https://example.com/same-scheduled-source"
        var article = StudioArticle(
            url: url,
            title: "Same Scheduled Source",
            sourceType: .article,
            id: localSourceID
        )
        article.normalizedURL = URLNormalizer.normalize(url)
        try store.saveSource(article)

        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end = Date(timeIntervalSinceReferenceDate: 100 + 7 * 24 * 60 * 60)
        let completedAt = Date(timeIntervalSinceReferenceDate: 300)
        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: LearningGoalRecord(
                    id: "remote-goal",
                    title: "Remote Plan",
                    startAt: start,
                    endAt: end,
                    createdAt: start,
                    updatedAt: completedAt,
                    status: "active",
                    items: [
                        LearningGoalItem(
                            id: "remote-item",
                            goalID: "remote-goal",
                            sourceID: remoteSourceID,
                            addedAt: start,
                            completedAt: completedAt
                        )
                    ]
                ),
                sourceIdentities: [
                    CloudKitSourceIdentityPayload(
                        sourceID: remoteSourceID,
                        url: url,
                        normalizedURL: URLNormalizer.normalize(url),
                        doi: nil,
                        publishedDOI: nil
                    )
                ]
            )
        )

        let goal = try #require(try store.loadLearningGoal("remote-goal"))
        #expect(goal.items.map(\.sourceID) == [localSourceID])
        #expect(goal.items.first?.completedAt == completedAt)
    }

    /// A Goal arriving from another Mac must stay a Goal. When `parentNotebookID`
    /// was dropped from the inbound mapping it was written NULL, so the receiving
    /// device presented the Goal as a top-level Notebook and then propagated the
    /// nulled parent back on its next edit.
    /// A Goal that syncs in without its `parent_notebook_id` is a sync bug, not a
    /// partial success — it arrives stripped of the relationship that makes it a
    /// Goal rather than a Notebook.
    @Test("CloudKit learning goals keep their parent Notebook")
    func cloudKitLearningGoalsKeepParent() throws {
        let store = try makeInMemoryStore()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end = Date(timeIntervalSinceReferenceDate: 100 + 7 * 24 * 60 * 60)

        let notebook = try store.createCompanionGoal(
            title: "Mitochondrial biology",
            description: nil,
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: nil
        )

        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: LearningGoalRecord(
                    id: "remote-nested-goal",
                    title: "Write article about mitochondrial transplantation",
                    startAt: start,
                    endAt: end,
                    createdAt: start,
                    updatedAt: end,
                    status: LearningGoalStatus.active.rawValue,
                    items: [],
                    kind: LearningGoalRecord.companionKind,
                    parentNotebookID: notebook.id
                ),
                sourceIdentities: []
            )
        )

        let received = try #require(try store.loadLearningGoal("remote-nested-goal"))
        #expect(received.parentNotebookID == notebook.id)
        #expect(received.isNotebookGoal)
        #expect(!received.isNotebook)
    }

    /// `researchQuestions` is the same inbound-mapping trap `parentNotebookID` fell
    /// into: `LearningGoalRecord.init` defaults it to nil, so leaving it out of the
    /// payload mapping compiles clean and silently nulls the field. The upsert's
    /// COALESCE guard then always keeps the local value, and a Notebook's defining
    /// questions never reach the other Mac.
    @Test("CloudKit learning goals carry their research questions")
    func cloudKitLearningGoalsCarryResearchQuestions() throws {
        let store = try makeInMemoryStore()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end = Date(timeIntervalSinceReferenceDate: 100 + 7 * 24 * 60 * 60)
        let questions = [
            "Why might mitochondrial transplantation work mechanistically?",
            "Are mtDNA mutations primarily responsible for mitochondrial dysfunction as we age?",
        ]

        func receive(_ researchQuestions: [String]?) throws {
            try store.saveLearningGoalRecord(
                CloudKitLearningGoalPayload(
                    goal: LearningGoalRecord(
                        id: "remote-notebook",
                        title: "Mitochondrial Transplantation",
                        startAt: start,
                        endAt: end,
                        createdAt: start,
                        updatedAt: end,
                        status: LearningGoalStatus.active.rawValue,
                        items: [],
                        kind: LearningGoalRecord.companionKind,
                        researchQuestions: researchQuestions
                    ),
                    sourceIdentities: []
                )
            )
        }

        try receive(questions)
        #expect(try store.loadLearningGoal("remote-notebook")?.researchQuestions == questions)

        // nil is "never set" — an older device with no opinion must not wipe the list.
        try receive(nil)
        #expect(try store.loadLearningGoal("remote-notebook")?.researchQuestions == questions)

        // An explicit clear travels as [] and wins.
        try receive([])
        #expect(try store.loadLearningGoal("remote-notebook")?.researchQuestions == [])
    }

    @Test("Goal lifecycle status is explicit, not inferred from the deadline")
    func goalLifecycleStatusIsExplicit() throws {
        let store = try makeInMemoryStore()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let passed = Date(timeIntervalSinceReferenceDate: 1000)

        let notebook = try store.createCompanionGoal(
            title: "Parent",
            description: nil,
            topic: "parent",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: nil
        )
        let goal = try store.createCompanionGoal(
            title: "Ship the article",
            description: nil,
            topic: "article",
            startAt: start,
            endAt: passed,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )

        // Deadline long past, but the work was never marked finished.
        let overdue = try #require(try store.loadLearningGoal(goal.id))
        #expect(overdue.lifecycleStatus == .active)
        #expect(overdue.isOverdue())
        #expect(!overdue.isDone)

        try store.setLearningGoalStatus(goalID: goal.id, status: .done)
        let done = try #require(try store.loadLearningGoal(goal.id))
        #expect(done.isDone)
        // Finished work is never also overdue.
        #expect(!done.isOverdue())

        // An open-ended Notebook can never be overdue.
        let parent = try #require(try store.loadLearningGoal(notebook.id))
        #expect(!parent.isOverdue())
    }

    /// The Schedule reads `scheduled_sources` but `LearningGoalRecord.completedCount`
    /// reads `learning_goal_items`. Only the placement was ever written by the review
    /// path, so every companion goal reported 0% done regardless of work finished.
    @Test("Completing a scheduled source marks it complete on the goal too")
    func completionMirrorsOntoGoalItems() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/mito-transfer",
            title: "Mitochondrial transfer",
            sourceType: .article,
            id: "src-mito"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.saveSource(article)

        let goal = try store.createCompanionGoal(
            title: "Write the article",
            description: nil,
            topic: "mitochondrial transplantation",
            startAt: Date(timeIntervalSinceReferenceDate: 0),
            endAt: Date(timeIntervalSinceReferenceDate: 10 * 86_400),
            dailyTarget: 2,
            discoveryEnabled: false,
            seedSourceIDs: [article.id],
            parentNotebookID: nil
        )
        try store.addSourceToGoal(
            sourceID: article.id,
            goalID: goal.id,
            plannedAt: Date(timeIntervalSinceReferenceDate: 86_400)
        )

        #expect(try #require(try store.loadLearningGoal(goal.id)).completedCount == 0)

        try store.markScheduledSourceDone(sourceID: article.id)

        let done = try #require(try store.loadLearningGoal(goal.id))
        #expect(done.completedCount == 1)
        #expect(done.items.first { $0.sourceID == article.id }?.isCompleted == true)

        // Reopening puts the source back on the calendar without erasing the
        // durable record that it was completed for this Notebook. A NULL item
        // completion would not converge through CloudKit's max-date merge.
        try store.reopenScheduledSource(sourceID: article.id)
        let reopened = try #require(try store.loadLearningGoal(goal.id))
        #expect(reopened.completedCount == 1)
        #expect(reopened.items.first { $0.sourceID == article.id }?.isCompleted == true)
    }

    @Test("Source activity creates one pending calendar entry and preserves existing plans")
    func sourceActivityCreatesIdempotentCalendarEntry() throws {
        let store = try makeInMemoryStore()
        var active = StudioArticle(
            url: "https://example.com/active-reading",
            title: "Active reading",
            sourceType: .article,
            id: "source-active-reading"
        )
        active.normalizedURL = URLNormalizer.normalize(active.url)
        try store.saveSource(active)

        let activityDay = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(try store.recordScheduledSourceActivity(sourceID: active.id, on: activityDay, kind: .reading))
        #expect(!(try store.recordScheduledSourceActivity(sourceID: active.id, on: activityDay, kind: .reading)))
        #expect(try store.recordScheduledSourceActivity(
            sourceID: active.id,
            on: activityDay.addingTimeInterval(86_400),
            kind: .chat
        ))

        let activeEntry = try #require(
            try store.loadScheduledSources().first { $0.placement.sourceID == active.id }
        )
        let activePlacement = activeEntry.placement
        #expect(Calendar.current.isDate(
            activePlacement.plannedAt,
            inSameDayAs: activityDay.addingTimeInterval(86_400)
        ))
        #expect(!activePlacement.isCompleted)
        #expect(activeEntry.activityDays.count == 2)
        #expect(activeEntry.isAutomatic)
        #expect(activeEntry.activityDays[0].kinds == [.reading])
        #expect(activeEntry.activityDays[1].kinds == [.chat])

        var planned = StudioArticle(
            url: "https://example.com/planned-reading",
            title: "Planned reading",
            sourceType: .article,
            id: "source-planned-reading"
        )
        planned.normalizedURL = URLNormalizer.normalize(planned.url)
        try store.saveSource(planned)
        let futureDay = activityDay.addingTimeInterval(5 * 86_400)
        try store.setScheduledSourcePlannedDate(sourceID: planned.id, plannedAt: futureDay)

        #expect(try store.recordScheduledSourceActivity(sourceID: planned.id, on: activityDay, kind: .listening))
        let plannedEntry = try #require(
            try store.loadScheduledSources().first { $0.placement.sourceID == planned.id }
        )
        let plannedPlacement = plannedEntry.placement
        #expect(Calendar.current.isDate(plannedPlacement.plannedAt, inSameDayAs: futureDay))
        #expect(!plannedEntry.isAutomatic)
        #expect(plannedEntry.activityDays.map(\.kinds) == [Set([.listening])])
    }

    @Test("Consumption history reports each day's activity without claiming completion")
    func consumptionHistoryReportsActivityDays() throws {
        let store = try makeInMemoryStore()
        var read = StudioArticle(
            url: "https://example.com/history-read",
            title: "History read",
            sourceType: .article,
            id: "source-history-read"
        )
        read.normalizedURL = URLNormalizer.normalize(read.url)
        try store.saveSource(read)

        var listened = StudioArticle(
            url: "https://example.com/history-listened",
            title: "History listened",
            sourceType: .podcast,
            id: "source-history-listened"
        )
        listened.normalizedURL = URLNormalizer.normalize(listened.url)
        try store.saveSource(listened)

        let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let later = earlier.addingTimeInterval(86_400)
        _ = try store.recordScheduledSourceActivity(sourceID: read.id, on: earlier, kind: .reading)
        _ = try store.recordScheduledSourceActivity(sourceID: listened.id, on: later, kind: .listening)
        // An explicit "I finished this" log is the only thing that marks a kind
        // complete; merely opening never does.
        try store.recordScheduledSourceCompletion(sourceID: listened.id, on: later, kind: .listening)

        let history = try store.loadSourceConsumptionHistory()
        #expect(history.count == 2)

        // Newest day first.
        let newest = try #require(history.first)
        #expect(newest.sourceID == listened.id)
        #expect(newest.title == "History listened")
        #expect(newest.kinds == [.listening])
        #expect(newest.completedKinds == [.listening])
        #expect(newest.isConsumption)

        let older = try #require(history.last)
        #expect(older.sourceID == read.id)
        #expect(older.kinds == [.reading])
        #expect(older.completedKinds.isEmpty)
        #expect(Calendar.current.isDate(older.dayStart, inSameDayAs: earlier))
    }

    @Test("Starting a review atomically adds its sources to the calendar")
    func reviewStartAddsCalendarEntries() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/review-start",
            title: "Review start",
            sourceType: .article,
            id: "source-review-start"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.saveSource(article)
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_100_000)

        try store.createReviewSession(
            id: "review-start-session",
            topic: "Review start",
            sourceIDs: [article.id],
            startedAt: startedAt,
            scheduleActivityAt: startedAt
        )

        let entry = try #require(try store.loadScheduledSources().first)
        let placement = entry.placement
        #expect(placement.sourceID == article.id)
        #expect(Calendar.current.isDate(placement.plannedAt, inSameDayAs: startedAt))
        #expect(!placement.isCompleted)
        #expect(entry.activityDays.first?.kinds == [.review])
    }

    @Test("Re-parenting validates the target is a top-level Notebook")
    func reparentingValidatesTarget() throws {
        let store = try makeInMemoryStore()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = Date(timeIntervalSinceReferenceDate: 10_000)

        let notebook = try store.createCompanionGoal(
            title: "Parent", description: nil, topic: "p",
            startAt: start, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let goalA = try store.createCompanionGoal(
            title: "Goal A", description: nil, topic: "a",
            startAt: start, endAt: end,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let goalB = try store.createCompanionGoal(
            title: "Goal B", description: nil, topic: "b",
            startAt: start, endAt: end,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let otherNotebook = try store.createCompanionGoal(
            title: "Other Parent", description: nil, topic: "other",
            startAt: start, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        // Goals cannot nest under other Goals.
        #expect(throws: (any Error).self) {
            try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: goalB.id)
        }
        // Nor under themselves.
        #expect(throws: (any Error).self) {
            try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: goalA.id)
        }
        // A Notebook that already holds Goals cannot become a nested Goal.
        #expect(throws: (any Error).self) {
            try store.setLearningGoalParentNotebook(goalID: notebook.id, parentNotebookID: goalA.id)
        }

        // Untagging is an ordinary state since schema 120: the Goal keeps its
        // deadline and everything it holds, and stands on its own. It never
        // becomes a Notebook — the deadline, not the parent, says which it is.
        try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: nil)
        let untagged = try #require(try store.loadLearningGoal(goalA.id))
        #expect(untagged.parentNotebookID == nil)
        #expect(untagged.isGoal && untagged.isStandaloneGoal)
        #expect(!untagged.isNotebook && !untagged.isNotebookGoal)
        #expect(untagged.endAt == end)

        try store.setLearningGoalParentNotebook(goalID: goalA.id, parentNotebookID: otherNotebook.id)
        let reparented = try #require(try store.loadLearningGoal(goalA.id))
        #expect(reparented.parentNotebookID == otherNotebook.id)
        #expect(reparented.isNotebookGoal)
    }

    @Test("active review sessions are linked but not reviewed")
    func activeReviewSessionIsLinkedButNotReviewed() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/active-review",
            title: "Active Review",
            sourceType: .article,
            id: "source-active-review"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.insertSourceIfNew(&article)

        try store.createReviewSession(
            id: "session-active",
            topic: "Active review",
            sourceIDs: [article.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        #expect(try store.sourceIdsWithReviewSession().contains(article.id))
        #expect(!(try store.sourceIdsWithLinkedChatSession().contains(article.id)))
        #expect((try store.sourceReviewDates())[article.id] == nil)
    }

    @Test("reopen review session only writes completed sessions")
    func reopenReviewSessionOnlyWritesCompletedSessions() throws {
        let store = try makeInMemoryStore()

        try store.createReviewSession(
            id: "session-active",
            topic: "Active review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-active" }?.overallScore == nil)
        try store.clearAllPendingSyncChanges()

        try store.reopenReviewSession(sessionID: "session-active")
        #expect(try store.pendingSyncChanges().isEmpty)
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-active" }?.status == "active")

        try store.completeReviewSession(
            sessionID: "session-active",
            overallScore: nil,
            summary: "Completed once.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        try store.clearAllPendingSyncChanges()

        try store.reopenReviewSession(sessionID: "session-active")
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-active" }?.status == "active")
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .reviewSession && $0.logicalKey == "session-active"
        })
    }

    @Test("relative file path round-trips")
    func testRelativeFilePathRoundTrips() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/paper.pdf", title: "Paper")
        article.localFilePath = "Documents/papers/paper.pdf"
        try store.insertSourceIfNew(&article)

        let loaded = try store.loadSources()
        #expect(loaded.count == 1)
        // The relative path should survive the round-trip (it may be resolved to absolute by
        // StorageService.absoluteSourcePath, but since it doesn't start with / and isn't http,
        // it gets the library root prepended — the important thing is it doesn't lose the value)
        #expect(loaded[0].localFilePath != nil)
        #expect(loaded[0].localFilePath!.contains("paper.pdf"))
    }

    /// Regression: the macOS 27 upgrade made iCloud fork the whole KB into
    /// `Documents/ForeverLM 2`, stranding ~370 paper PDFs. Resolving a file
    /// inside a fork depends on the fork's absolute path mapping back to the
    /// same relative path as the canonical folder — that equivalence is what
    /// lets `locateLocalPath` find the file and stops the Papers tab from
    /// reporting hundreds of papers as having lost their PDFs.
    @Test("iCloud conflict-fork paths map to the canonical relative path")
    func testConflictForkPathsMapToCanonicalRelativePath() {
        let home = NSHomeDirectory()
        let forkPaths = [
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM 2/Papers/x.pdf",
            "\(home)/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM 3/Papers/x.pdf",
            "\(home)/Documents/ForeverLM 2/Papers/x.pdf",
        ]
        for path in forkPaths {
            #expect(StorageService.relativeSourcePath(path) == "Papers/x.pdf")
        }

        // The canonical folder maps the same way, so a fork and the real folder
        // are interchangeable as far as source identity is concerned.
        let canonical = "\(home)/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/x.pdf"
        #expect(StorageService.relativeSourcePath(canonical) == "Papers/x.pdf")

        // A path outside any content root must stay untouched, so the fork
        // lookup in `locateLocalPath` never fires for unrelated files.
        let external = "/tmp/somewhere-else/x.pdf"
        #expect(StorageService.relativeSourcePath(external) == external)
    }

    /// Regression: a paper published by the other Mac reported "PDF needed"
    /// forever, with its own bytes sitting in the CloudKit record being applied.
    ///
    /// Builds before commit 3c62e0d put the *publishing* Mac's absolute path on
    /// the wire, and once content moved out of `Documents/ForeverLM` those paths
    /// had no marker component to key on — so the receiving Mac could only match
    /// its own `/Users/<name>` prefix, which never matches. The path reduced to
    /// nothing, and `materializeInboundSourcePDFIfNeeded` reads that as "a layout
    /// this device knows nothing about" and declines to install the PDF.
    ///
    /// `normalizedSourceKey` has always documented the opposite: paths from
    /// different machines map to the same key. This pins that promise to the
    /// local content root, which is the root that broke it.
    @Test("another Mac's content path reduces to the same relative key")
    func testForeignHomeContentPathsReduceToRelativeKey() {
        let foreignHome = "/Users/some-other-account"
        let localSuffix = (StorageService.localContentRootPath as NSString)
            .abbreviatingWithTildeInPath
        // Only run the home-relative half when this device's roots really do sit
        // under its home; a CI account with a relocated home has nothing to pin.
        guard localSuffix.hasPrefix("~/") else { return }
        let suffix = String(localSuffix.dropFirst(2))

        let foreignLocalRoot = "\(foreignHome)/\(suffix)/Papers/x.pdf"
        #expect(StorageService.relativeSourcePath(foreignLocalRoot) == "Papers/x.pdf")

        // The same holds for every historical root, so a second Mac that never
        // left the ubiquity container is read the same way.
        let foreignRoots = [
            "\(foreignHome)/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/x.pdf",
            "\(foreignHome)/Documents/ForeverLM/Papers/x.pdf",
        ]
        for path in foreignRoots {
            #expect(StorageService.relativeSourcePath(path) == "Papers/x.pdf")
        }

        // The documented contract: the foreign absolute form and the stored
        // relative form are one source, not two.
        #expect(
            StorageService.normalizedSourceKey(foreignLocalRoot)
                == StorageService.normalizedSourceKey("Papers/x.pdf")
        )

        // Reducing makes the path app-managed, which is what stops startup
        // reconciliation from reading a not-yet-arrived file as a deletion.
        #expect(StorageService.isAppManagedSourcePath(foreignLocalRoot))

        // And it makes the file findable here: the inbound PDF lands under this
        // Mac's own root rather than being refused.
        let candidates = StorageService.sourceFileCandidatePaths(for: foreignLocalRoot)
        #expect(
            candidates.contains(
                (StorageService.libraryRootPath as NSString).appendingPathComponent("Papers/x.pdf")
            )
        )

        // Another account's unrelated file is still none of our business — the
        // reduction is keyed on a content root, not on `/Users/<name>` alone.
        let unrelated = "\(foreignHome)/Downloads/x.pdf"
        #expect(StorageService.relativeSourcePath(unrelated) == unrelated)
        #expect(!StorageService.isAppManagedSourcePath(unrelated))
    }

    /// The app used to answer "where is this file" in three places that each
    /// knew rules the others didn't, so it could open a file it simultaneously
    /// reported as missing. They now share
    /// `StorageService.sourceFileCandidatePaths`; this pins them together, since
    /// the cost of them drifting apart again is a library that looks half-empty.
    @Test("every file resolver agrees on where a source file is")
    func testFileResolversAgree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-agreement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = dir.appendingPathComponent("present.pdf")
        try Data("%PDF-1.4".utf8).write(to: present)
        let absent = dir.appendingPathComponent("absent.pdf").path

        for path in [present.path, absent] {
            let viaStorage = StorageService.locateSourceFile(path)
            let viaSourceService = SourceService.resolveLocalFileURL(path)?.path
            var article = makeArticle(url: "https://example.com/x", title: "X")
            article.localFilePath = path
            let viaArticle = article.resolvedLocalPath

            #expect(viaStorage == viaSourceService)
            // `resolvedLocalPath` reports the path it would use even on a miss,
            // so compare it only where a file was actually located.
            if let viaStorage {
                #expect(viaArticle == viaStorage)
            }
        }

        // `file://` inputs reach the resolver only through SourceService — a
        // stored `localFilePath` is always a plain or relative path, and
        // `resolvedLocalPath` screens out anything containing "://" before
        // resolving. Both file-URL-aware entry points must still agree.
        let fileURLForm = "file://" + present.path
        #expect(StorageService.locateSourceFile(fileURLForm) == present.path)
        #expect(SourceService.resolveLocalFileURL(fileURLForm)?.path == present.path)

        // A not-yet-downloaded iCloud file leaves a `.name.icloud` placeholder
        // beside it. Reading it as absent is what makes the app offer to
        // re-download a paper it already has.
        let evicted = dir.appendingPathComponent("evicted.pdf")
        let placeholder = dir.appendingPathComponent(".evicted.pdf.icloud")
        try Data().write(to: placeholder)
        #expect(StorageService.locateSourceFile(evicted.path) == evicted.path)
        #expect(SourceService.resolveLocalFileURL(evicted.path)?.path == evicted.path)
    }

    /// The offline fallback must not live in `~/Documents`: with "Desktop &
    /// Documents Folders" syncing on (the macOS default) that folder IS iCloud
    /// Drive, so the fallback became a second synced root that could fork
    /// against the private container — which is exactly what happened.
    @Test("the offline content root is local, not a second synced root")
    func testLocalContentRootIsNotSynced() {
        let local = StorageService.localContentRootPath
        #expect(local.contains("Application Support"))
        #expect(!local.contains("Mobile Documents"))
        #expect(!local.hasPrefix(NSHomeDirectory() + "/Documents"))

        // knowledge.db survives these events because Application Support is never
        // synced; content now shares that property when iCloud is unavailable.
        #expect(local.hasPrefix(NSHomeDirectory()) || local.hasPrefix("/"))
    }

    /// A stored relative path has to resolve against every root the app has ever
    /// written to, so moving between the private container, iCloud Drive and
    /// local storage never strands a file.
    @Test("stored relative paths are searched against every known content root")
    func testRelativePathsSearchAllKnownRoots() {
        let roots = StorageService.knownContentRoots
        // The roots carry the running build's product folder: `ForeverLM` in a
        // release build, `ForeverLM Dev` in the Dev build these tests run in.
        let folder = ForeverLMRuntimeIdentity.productFolderName
        #expect(roots.contains(StorageService.libraryRootPath))
        #expect(roots.contains(StorageService.localContentRootPath))
        #expect(roots.contains { $0.hasSuffix("com~apple~CloudDocs/Documents/\(folder)") })
        #expect(roots.contains { $0.hasSuffix("iCloud~com~foreverlm/Documents/\(folder)") })
        // The retired container is deliberately absent: it is drained and its
        // `Documents` is empty, so searching it can only ever miss.
        #expect(!roots.contains { $0.contains("iCloud~com~feynmanlm") })
        #expect(roots.contains { $0.hasSuffix("/Documents/\(folder)") })
        // The real `~/Documents` is not searched: it is the CloudDocs
        // `Documents` when Desktop & Documents syncing is on and unsynced when
        // it is off, and touching it raises the Documents-folder TCC prompt.
        let realDocuments = (NSHomeDirectory() as NSString).appendingPathComponent("Documents") + "/"
        #expect(!roots.contains { $0.hasPrefix(realDocuments) })

        // Each root contributes a candidate for the same stored path...
        let candidates = StorageService.sourceFileCandidatePaths(for: "Papers/x.pdf")
        for root in Set(roots) {
            #expect(candidates.contains((root as NSString).appendingPathComponent("Papers/x.pdf")))
        }
        // ...with no duplicates, since roots overlap by configuration.
        #expect(candidates.count == Set(candidates).count)

        // A file under the local root still reduces to its relative form even
        // while iCloud is available, or the same file would be stored absolute on
        // one launch and relative on the next.
        let localFile = (StorageService.localContentRootPath as NSString)
            .appendingPathComponent("Papers/x.pdf")
        #expect(StorageService.relativeSourcePath(localFile) == "Papers/x.pdf")
    }

    /// Content is written locally, not into the ubiquity container. CloudDocs
    /// resolves a *directory* conflict in document scope by bouncing one side to
    /// a numbered name, and this library forked that way repeatedly — the app
    /// re-creating a root iCloud had not yet delivered was the other half of it.
    ///
    /// The move needed no migration precisely because resolution is root-agnostic,
    /// so the invariant worth pinning is that nothing already written became
    /// unreachable: the container and its forks stay searchable, and only new
    /// writes land locally.
    @Test("content is written locally while every iCloud root stays readable")
    func testContentRootIsLocalAndLegacyRootsStayReadable() {
        #expect(StorageService.libraryRootPath == StorageService.localContentRootPath)
        #expect(!StorageService.libraryRootPath.contains("Mobile Documents"))

        // The container is still a known root: that is where most of this
        // library's files are, and they were not moved.
        #expect(StorageService.ubiquityContentRootPath.contains("iCloud~com~foreverlm"))
        #expect(StorageService.knownContentRoots.contains(StorageService.ubiquityContentRootPath))

        // A stored relative path resolves against the local root first and the
        // container after it, so a new write and a legacy file both land.
        let candidates = StorageService.sourceFileCandidatePaths(for: "Papers/x.pdf")
        let localCandidate = (StorageService.localContentRootPath as NSString)
            .appendingPathComponent("Papers/x.pdf")
        let containerCandidate = (StorageService.ubiquityContentRootPath as NSString)
            .appendingPathComponent("Papers/x.pdf")
        #expect(candidates.first == localCandidate)
        #expect(candidates.contains(containerCandidate))
    }

    /// Synced audio is the deliberate exception under generation 1: it has no
    /// CloudKit entity there, and the iPhone reads these files straight out of
    /// the container, so CloudDocs is its only transport. If this ever follows
    /// `libraryRootPath`, Mac narration silently stops reaching the phone.
    /// Generation 2 moves a device's narration to its own working folder
    /// (`MacNarrationLibrary.install`, covered by `MacNarrationTests`), and the
    /// test host installs that answer from its own library's generation, so
    /// this reads the generation-1 tree itself rather than `audioRootURL()`.
    @Test("synced audio's generation-1 tree still resolves inside the ubiquity container")
    func testSyncedAudioStaysInTheUbiquityContainer() {
        let audioRoot = SyncedArticleAudioStore.ubiquityAudioRootURL().path
        #expect(audioRoot.hasPrefix(StorageService.ubiquityContentRootPath))
        #expect(!audioRoot.hasPrefix(StorageService.localContentRootPath))
        #expect(audioRoot.hasSuffix("/Audio"))
    }

}

// MARK: - StorageService Persistence Tests

/// Creates an in-memory StorageService for unit testing.
private func makeInMemoryService() throws -> StorageService {
    try StorageService(inMemory: true)
}

@Suite("Full-text analyzer statistics")
struct FullTextAnalyzerStatisticsTests {

    @Test("both spellings of a term count toward one document frequency")
    func documentFrequencyCountsBothSpellings() throws {
        let store = try makeInMemoryStore()

        try store.replaceSourceFTS(
            sourceID: "source-hyphenated",
            title: "Mitochondrial stress markers",
            author: "",
            body: "Circulating GDF-15 rises with mitochondrial dysfunction."
        )
        try store.replaceSourceFTS(
            sourceID: "source-bare",
            title: "A mystery hormone",
            author: "",
            body: "GDF15 remains poorly understood."
        )

        // The statistic a query-time rewrite cannot repair: rarity is measured on one
        // token, so `lexicalWeight` sees a rare anchor whichever spelling was typed
        // instead of a term the index appears never to have heard of.
        #expect(try store.sourceFTSDocumentFrequency(term: "gdf15") == 2)

        // The separated spelling is still there — the closed-up token is added, not
        // substituted, so a phrase query and a plain word query both still work.
        #expect(try store.sourceFTSDocumentFrequency(term: "gdf 15") == 1)
        #expect(try store.sourceFTSDocumentFrequency(term: "mitochondrial") == 1)
        #expect(try store.sourceFTSDocumentFrequency(term: "gdf16") == 0)
    }
}

@Suite("StorageService Persistence")
struct StorageServicePersistenceTests {

    @Test("paper metadata backfill preserves a concurrently attached PDF")
    func paperMetadataBackfillPreservesConcurrentAttachment() async throws {
        let svc = try makeInMemoryService()
        var original = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/39933528/",
            title: "Impact of physical activity",
            sourceType: .paper
        )
        original.author = nil
        try await svc.saveSource(original)

        var candidate = original
        candidate.author = "Marina Cefis et al."
        candidate.journal = "Cell Reports Medicine"
        candidate.publishedYear = "2025"
        candidate.doi = "10.1016/j.xcrm.2025.101968"
        let patch = PaperMetadataBackfillPatch(original: original, candidate: candidate)

        var attached = original
        attached.url = "https://pmc.ncbi.nlm.nih.gov/articles/PMC11866497/"
        attached.localFilePath = "/tmp/PMC11866497.pdf"
        attached.domain = "Local PDF"
        try await svc.saveSource(attached)

        let merged = try await svc.mergePaperMetadataBackfill(patch)

        #expect(merged?.url == attached.url)
        #expect(merged?.localFilePath == attached.localFilePath)
        #expect(merged?.domain == "Local PDF")
        #expect(merged?.author == candidate.author)
        #expect(merged?.journal == candidate.journal)
        #expect(merged?.publishedYear == candidate.publishedYear)
        #expect(merged?.doi == candidate.doi)
    }

    @Test("the full-text index stores a separated term closed up as well")
    func fullTextIndexAnalyzesSymbolSpellings() async throws {
        let svc = try makeInMemoryService()
        var hyphenated = makeArticle(url: "https://example.com/hyphenated", title: "Mitochondrial stress markers")
        try await svc.insertSourceIfNew(&hyphenated)
        var bare = makeArticle(url: "https://example.com/bare", title: "A mystery hormone")
        try await svc.insertSourceIfNew(&bare)

        // Written the way the indexer writes them, from text that names the protein only
        // in the body, each spelling it the other way.
        try await svc.replaceSourceFTS(
            sourceID: hyphenated.id,
            title: "Mitochondrial stress markers",
            author: "",
            body: "Circulating GDF-15 rises with mitochondrial dysfunction in muscle."
        )
        try await svc.replaceSourceFTS(
            sourceID: bare.id,
            title: "A mystery hormone",
            author: "",
            body: "GDF15 remains poorly understood as a signal of cellular stress."
        )

        // No embedding: this is the lexical branch alone, and the point is that it no
        // longer needs the query rewritten to reach both spellings — the index itself
        // holds `gdf15` for the hyphenated source.
        let bareQuery = await svc.searchSources(queryText: "GDF15", queryVector: nil, limit: 5)
            .map(\.sourceId)
        #expect(Set(bareQuery) == [hyphenated.id, bare.id])

        let hyphenQuery = await svc.searchSources(queryText: "GDF-15", queryVector: nil, limit: 5)
            .map(\.sourceId)
        #expect(Set(hyphenQuery) == [hyphenated.id, bare.id])

        let unrelated = await svc.searchSources(queryText: "GDF16", queryVector: nil, limit: 5)
        #expect(unrelated.isEmpty)
    }

    @Test("a full-text row written by an older analyzer is rewritten, without re-embedding")
    func staleFullTextRowsAreReanalyzed() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/stale", title: "Mitochondrial stress markers")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Circulating GDF-15 rises with mitochondrial dysfunction.")

        // A source with no full-text row at all is the same gap an older analyzer leaves.
        #expect(await svc.sourcesNeedingFTSRebuild().map(\.id) == [article.id])

        try await svc.replaceSourceFTS(
            sourceID: article.id,
            title: "Mitochondrial stress markers",
            author: "",
            body: "Circulating GDF-15 rises with mitochondrial dysfunction."
        )

        // Writing the row stamps the analyzer that wrote it, so the gap closes.
        #expect(await svc.sourcesNeedingFTSRebuild().isEmpty)

        // And closing it did not claim the source is embedded — that gap is tracked
        // separately, so a reanalysis never spends model time.
        #expect(await svc.sourcesMissingIndex().map(\.id) == [article.id])
    }

    @Test("an indexed stamp with no vectors behind it puts the source back in the gap")
    func stampedSourceWithoutVectorsIsReindexed() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://x.com/someone/status/1", title: "A short post")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "The link to our paper.")
        try await svc.saveSourceChunkEmbeddings(
            sourceId: article.id,
            embeddings: [(chunkId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: 0), vector: [1, 0, 0])]
        )
        try await svc.recordSourceIndexed(sourceID: article.id)
        #expect(await svc.sourcesMissingIndex().isEmpty)

        // The vectors go while the stamp and the content length stay put.
        try await svc.saveSourceChunkEmbeddings(sourceId: article.id, embeddings: [])

        #expect(await svc.sourcesMissingIndex().map(\.id) == [article.id])
    }

    @Test("archiving drops the indexed stamp, so a restored source is embedded again")
    func archiveDropsIndexedStamp() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://x.com/someone/status/2", title: "A restored post")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Same text before and after.")
        try await svc.saveSourceChunkEmbeddings(
            sourceId: article.id,
            embeddings: [(chunkId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: 0), vector: [0, 1, 0])]
        )
        try await svc.recordSourceIndexed(sourceID: article.id)
        #expect(await svc.sourcesMissingIndex().isEmpty)

        try await svc.archiveSource(article.id)
        try await svc.unarchiveSource(article.id)
        // Sync brings the text back byte for byte, so the length the stamp
        // recorded still matches.
        try await svc.saveTranscript(article.id, "Same text before and after.")

        #expect(await svc.sourcesMissingIndex().map(\.id) == [article.id])
        #expect(await svc.embeddedChunkSourceIds().isEmpty)
    }

    @Test("saveTranscript persists content and sets state to ready")
    func testSaveTranscriptPersists() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/episode-1", title: "Episode 1")
        try await svc.insertSourceIfNew(&article)

        try await svc.saveTranscript(article.id, "Hello world transcript content.")

        let content = await svc.loadSourceContent(article.id)
        #expect(content == "Hello world transcript content.")
    }

    @Test("updateSourceType persists type")
    func testUpdateSourceTypePersists() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/doc", title: "Doc")
        try await svc.insertSourceIfNew(&article)

        try await svc.updateSourceType(article.id, to: StudioSourceType.paper.rawValue)

        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].sourceType == .paper)
    }

    @Test("updateParentGroup persists group")
    func testUpdateParentGroupPersists() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/lecture", title: "Lecture")
        try await svc.insertSourceIfNew(&article)

        try await svc.updateParentGroup(article.id, "Physics 101")

        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].parentGroup == "Physics 101")
    }

    @Test("archiveSource cleans up content")
    func testArchiveSourceCleansUpContent() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/post", title: "Post")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Some content here.")

        try await svc.archiveSource(article.id)

        let active = try await svc.loadActiveSources()
        #expect(active.isEmpty)
        let content = await svc.loadSourceContent(article.id)
        #expect(content == nil)
    }

    @Test("transcript survives reload")
    func testTranscriptSurvivesReload() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/ep2", title: "Episode 2")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Persistent transcript.")

        // Re-load via a different path to ensure it's from DB
        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        let content = await svc.loadSourceContent(article.id)
        #expect(content == "Persistent transcript.")
    }

    @Test("podcast transcript upgrade reuses existing source row")
    func testPodcastTranscriptUpgradeReusesExistingSourceRow() async throws {
        let svc = try makeInMemoryService()

        var placeholder = makeArticle(url: "apple-podcast://episode/12345", title: "Show - Episode")
        placeholder.sourceType = .podcast
        placeholder.domain = "Show"
        placeholder.state = .queued
        try await svc.insertSourceIfNew(&placeholder)

        var upgraded = StudioArticle(
            url: placeholder.url,
            title: placeholder.title,
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: placeholder.id
        )
        upgraded.domain = "Show"

        let existing = await svc.sourceRecordByNormalizedURL(URLNormalizer.normalize(upgraded.url))
        #expect(existing?.id == placeholder.id)

        try await svc.saveSource(upgraded)
        try await svc.saveTranscript(upgraded.id, "Transcript body", rawTTML: "<tt></tt>")

        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == placeholder.id)
        #expect(loaded[0].sourceType == .podcast)

        let content = await svc.loadSourceContent(placeholder.id)
        #expect(content == "Transcript body")
    }

    @Test("reconciliation archives source with missing file")
    func testReconciliationArchivesMissingFile() async throws {
        let svc = try makeInMemoryService()
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-\(UUID()).pdf")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data("test".utf8))

        var article = makeArticle(url: "file://\(tempFile.path)")
        article.localFilePath = tempFile.path
        article.sourceType = .paper
        try await svc.insertSourceIfNew(&article)

        // File exists — should stay active
        var active = try await svc.loadActiveSources()
        #expect(active.count == 1)

        // Delete the file
        try FileManager.default.removeItem(at: tempFile)

        // Reconcile: article with missing local file should be archived
        let archived = try await svc.reconcileLocalFiles()
        #expect(archived == 1)

        active = try await svc.loadActiveSources()
        #expect(active.count == 0)
    }

    @Test("reconciliation preserves missing app-managed PDF path")
    func testReconciliationPreservesMissingAppManagedPDFPath() async throws {
        let svc = try makeInMemoryService()
        let article = StudioArticle(
            url: "https://example.com/paper",
            title: "Synced Paper",
            sourceType: .paper,
            localFilePath: "Papers/synced-paper.pdf"
        )
        try await svc.saveSource(article)

        let archived = try await svc.reconcileLocalFiles()

        let active = try await svc.loadActiveSources()
        #expect(archived == 0)
        #expect(active.count == 1)
        // loadActiveSources resolves app-managed relative paths to an absolute
        // path under libraryRootPath, which differs per environment (iCloud
        // container vs ~/Documents fallback). The behavior under test is that
        // reconciliation preserved the missing app-managed path instead of
        // clearing or archiving it, so compare in relative form.
        #expect(active[0].localFilePath.map(StorageService.relativeSourcePath) == "Papers/synced-paper.pdf")
    }

    @Test("reconciliation still clears missing external cache for web source")
    func testReconciliationClearsMissingExternalCacheForWebSource() async throws {
        let svc = try makeInMemoryService()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-cache-\(UUID()).pdf")
        let article = StudioArticle(
            url: "https://example.com/paper",
            title: "Externally Cached Paper",
            sourceType: .paper,
            localFilePath: tempFile.path
        )
        try await svc.saveSource(article)

        let archived = try await svc.reconcileLocalFiles()

        let active = try await svc.loadActiveSources()
        #expect(archived == 0)
        #expect(active.count == 1)
        #expect(active[0].localFilePath == nil)
    }

    @Test("full workflow survives relaunch")
    func testFullWorkflowSurvivesRelaunch() async throws {
        let svc = try makeInMemoryService()

        // Step 1: Import videos into a course
        var v1 = makeArticle(url: "https://youtube.com/watch?v=lecture1")
        v1.sourceType = .video
        v1.parentGroup = "MIT 6.006"
        var v2 = makeArticle(url: "https://youtube.com/watch?v=lecture2")
        v2.sourceType = .video
        v2.parentGroup = "MIT 6.006"
        _ = try await svc.insertSourceIfNew(&v1)
        _ = try await svc.insertSourceIfNew(&v2)

        // Step 2: Fetch a transcript
        try await svc.saveTranscript(v1.id, "Welcome to lecture 1 on algorithms...")

        // Step 3: Organize the course
        try await svc.updateCourseSortOrder([(v2.id, 0), (v1.id, 1)])

        // Step 4: Drag an article to papers
        var paper = makeArticle(url: "https://arxiv.org/abs/1706.03762")
        _ = try await svc.insertSourceIfNew(&paper)
        try await svc.updateSourceType(paper.id, to: StudioSourceType.paper.rawValue)

        // === SIMULATE RELAUNCH ===
        let sources = try await svc.loadActiveSources()

        // Verify everything survived
        #expect(sources.count == 3)

        // Transcript persisted
        let transcript = await svc.loadSourceContent(v1.id)
        #expect(transcript == "Welcome to lecture 1 on algorithms...")

        // Course sort order persisted
        let courseSources = sources
            .filter { $0.parentGroup == "MIT 6.006" }
            .sorted { ($0.courseSortIndex ?? Int.max) < ($1.courseSortIndex ?? Int.max) }
        #expect(courseSources[0].id == v2.id)
        #expect(courseSources[1].id == v1.id)

        // Source type change persisted
        let paperSource = sources.first { $0.url == "https://arxiv.org/abs/1706.03762" }
        #expect(paperSource?.sourceType == .paper)

        // Step 5: Discovery re-running should NOT duplicate
        var rediscoveredV1 = makeArticle(url: "https://youtube.com/watch?v=lecture1")
        let inserted = try await svc.insertSourceIfNew(&rediscoveredV1)
        #expect(!inserted, "Should skip — already exists in DB")

        let sourcesAfterRediscovery = try await svc.loadActiveSources()
        #expect(sourcesAfterRediscovery.count == 3, "No duplicates")
    }

    @Test("reconciliation keeps source with existing file")
    func testReconciliationKeepsExistingFile() async throws {
        let svc = try makeInMemoryService()
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-\(UUID()).pdf")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var article = makeArticle(url: "file://\(tempFile.path)")
        article.localFilePath = tempFile.path
        article.sourceType = .paper
        try await svc.insertSourceIfNew(&article)

        let archived = try await svc.reconcileLocalFiles()
        #expect(archived == 0)

        let active = try await svc.loadActiveSources()
        #expect(active.count == 1)
        }
    }

    @Test("Meeting groups and artifacts round-trip")
    func meetingGroupsAndArtifactsRoundTrip() throws {
        let store = try makeInMemoryStore()
        try store.saveMeetingGroup(
            name: "acme",
            metadata: MeetingMetadata(
                title: "Acme Longevity Nexus",
                driveFolderURL: "https://drive.google.com/drive/folders/example",
                localFolderPath: "/tmp/Acme",
                recurrenceRule: "FREQ=WEEKLY",
                timezone: "America/Los_Angeles"
            )
        )
        var article = StudioArticle(
            url: "meeting://acme/2025-11-23",
            title: "Acme Longevity Nexus - 2025/11/23",
            sourceType: .meeting,
            discoveryOrigin: .localMeetings,
            parentGroup: "acme"
        )
        article.content = "Transcript text"
        article.wordCount = 2
        article.state = .ready
        try store.saveSource(article)
        try store.saveMeetingArtifact(MeetingArtifact(
            sourceId: article.id,
            groupId: "acme",
            kind: .transcript,
            title: "Transcript",
            localFilePath: "/tmp/Acme/transcript.txt"
        ))

        let groups = try store.loadMeetingGroups()
        #expect(groups["acme"]?.title == "Acme Longevity Nexus")
        let sources = try store.loadSources()
        #expect(sources.first?.sourceType == .meeting)
        #expect(sources.first?.parentGroup == "acme")
        let artifacts = try store.loadMeetingArtifacts(groupID: "acme")
        #expect(artifacts.count == 1)
        #expect(artifacts[0].kind == .transcript)
    }

    @Test("Merging meeting groups moves relationships and preserves an incoming import alias")
    func meetingGroupMergeIsAtomicAndDurable() throws {
        let store = try makeInMemoryStore()
        try store.saveMeetingGroup(
            name: "read-ai-weekly",
            metadata: MeetingMetadata(title: "Weekly Sync from Read AI")
        )
        try store.saveMeetingGroup(
            name: "weekly",
            metadata: MeetingMetadata(title: "Weekly Sync")
        )
        var article = StudioArticle(
            url: "meeting://read-ai-weekly/2026-08-31",
            title: "Weekly Sync — August 31",
            sourceType: .meeting,
            discoveryOrigin: .readAI,
            parentGroup: "read-ai-weekly"
        )
        article.content = "# Weekly Sync\n\n## Transcript\n\nMaterial"
        article.state = .ready
        try store.saveSource(article)
        try store.saveMeetingArtifact(MeetingArtifact(
            id: "read-ai-transcript",
            sourceId: article.id,
            groupId: "read-ai-weekly",
            kind: .transcript,
            title: "Transcript"
        ))
        try store.clearAllPendingSyncChanges()

        try store.mergeMeetingGroup("read-ai-weekly", into: "weekly")

        let groups = try store.loadMeetingGroups()
        #expect(groups["read-ai-weekly"]?.isHidden == true)
        #expect(groups["read-ai-weekly"]?.mergedIntoGroupID == "weekly")
        #expect(groups["weekly"]?.title == "Weekly Sync")
        #expect(try store.loadSources().first(where: { $0.id == article.id })?.parentGroup == "weekly")
        #expect(try store.loadMeetingArtifacts(groupID: "read-ai-weekly").isEmpty)
        #expect(try store.loadMeetingArtifacts(groupID: "weekly").map(\.id) == ["read-ai-transcript"])

        // This is the exact title Read AI will keep supplying after the merge.
        #expect(try store.resolvedMeetingGroupID(matching: "Weekly Sync from Read AI") == "weekly")
        let pending = try store.pendingSyncChanges()
        let changed = Set(pending.map { "\($0.entity.rawValue):\($0.logicalKey)" })
        #expect(changed.contains("source:\(article.id)"))
        #expect(changed.contains("meetingGroup:read-ai-weekly"))
        #expect(changed.contains("meetingGroup:weekly"))
    }

@Suite("Unreviewed consumed sources")
struct UnreviewedConsumedSourceTests {

    /// A source with extracted text, so it clears the "worth reviewing against" bar.
    private func makeConsumableSource(
        url: String,
        title: String,
        sourceType: StudioSourceType = .article
    ) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: sourceType)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = String(repeating: "Body text worth reviewing. ", count: 20)
        return article
    }

    @Test("Only consumed sources are offered for a first review")
    func onlyConsumedSourcesQualify() throws {
        let store = try makeInMemoryStore()

        let untouched = makeConsumableSource(url: "https://example.com/untouched", title: "Untouched")
        let read = makeConsumableSource(url: "https://example.com/read", title: "Read")
        let skimmed = makeConsumableSource(url: "https://example.com/skimmed", title: "Skimmed")
        let studied = makeConsumableSource(url: "https://example.com/studied", title: "Studied")
        for article in [untouched, read, skimmed, studied] {
            try store.saveSource(article)
        }

        try store.updateSourceReadAt(sourceID: read.id, readAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
        try store.updateSourceReadingLocator(
            sourceID: skimmed.id,
            locator: ArticleReadingPositionLocator(scrollFraction: 0.05).encoded
        )
        try store.updateSourceReadingPosition(sourceID: studied.id, page: 12)

        let candidates = try store.unreviewedConsumedSources()
        #expect(Set(candidates.map(\.sourceID)) == [read.id])
    }

    @Test("An already-reviewed source is not new, however it was reviewed")
    func reviewedSourcesAreExcluded() throws {
        let store = try makeInMemoryStore()
        let article = makeConsumableSource(url: "https://example.com/reviewed", title: "Reviewed")
        try store.saveSource(article)
        try store.updateSourceReadAt(sourceID: article.id, readAt: Date(timeIntervalSinceReferenceDate: 780_000_000))

        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [article.id])

        let sessionID = UUID().uuidString
        try store.createReviewSession(id: sessionID, topic: "Review", sourceIDs: [article.id])
        // An open session does not count — only a completed one retires the source
        // from the never-reviewed bucket.
        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [article.id])

        try store.completeReviewSession(sessionID: sessionID, overallScore: 0.8, summary: "Solid")
        #expect(try store.unreviewedConsumedSources().isEmpty)
    }

    @Test("Text-less sources never enter the bucket; hidden ones do, because hiding is visual only")
    func ineligibleSourcesAreExcluded() throws {
        let store = try makeInMemoryStore()
        let readAt = Date(timeIntervalSinceReferenceDate: 780_000_000)

        let hidden = makeConsumableSource(url: "https://example.com/hidden", title: "Hidden")
        var empty = makeConsumableSource(url: "https://example.com/empty", title: "No text")
        empty.content = nil
        let visible = makeConsumableSource(url: "https://example.com/visible", title: "Visible")
        for article in [hidden, empty, visible] {
            try store.saveSource(article)
            try store.updateSourceReadAt(sourceID: article.id, readAt: readAt)
        }
        try store.setSourceHidden(hidden.id, hidden: true)

        // A hidden source left the sources list, not the learner's knowledge
        // (product owner, 2026-09-11), so it is still offered for its first review.
        #expect(Set(try store.unreviewedConsumedSources().map(\.sourceID)) == [hidden.id, visible.id])
    }

    @Test("Restricting to a Notebook's sources scopes the bucket")
    func restrictScopesResults() throws {
        let store = try makeInMemoryStore()
        let readAt = Date(timeIntervalSinceReferenceDate: 780_000_000)

        let inNotebook = makeConsumableSource(url: "https://example.com/in", title: "In notebook")
        let outsideNotebook = makeConsumableSource(url: "https://example.com/out", title: "Outside")
        for article in [inNotebook, outsideNotebook] {
            try store.saveSource(article)
            try store.updateSourceReadAt(sourceID: article.id, readAt: readAt)
        }

        let scoped = try store.unreviewedConsumedSources(restrictToSourceIDs: [inNotebook.id])
        #expect(scoped.map(\.sourceID) == [inNotebook.id])
    }

    @Test("An unheard podcast episode is not offered; a completed one is")
    func podcastsNeedAnExplicitReadMark() throws {
        let store = try makeInMemoryStore()
        let unheard = makeConsumableSource(
            url: "https://example.com/ep-1",
            title: "Episode 1",
            sourceType: .podcast
        )
        let heard = makeConsumableSource(
            url: "https://example.com/ep-2",
            title: "Episode 2",
            sourceType: .podcast
        )
        try store.saveSource(unheard)
        try store.saveSource(heard)
        try store.updateSourceReadAt(sourceID: heard.id, readAt: Date(timeIntervalSinceReferenceDate: 780_000_000))

        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [heard.id])
    }

    // MARK: - Measured depth

    @Test("A mostly-played episode is offered even though nothing marked it read")
    func substantialListeningQualifiesWithoutReadAt() throws {
        let store = try makeInMemoryStore()
        let abandoned = makeConsumableSource(
            url: "https://example.com/ep-abandoned",
            title: "Abandoned after the intro",
            sourceType: .podcast
        )
        let mostlyPlayed = makeConsumableSource(
            url: "https://example.com/ep-mostly",
            title: "Played nearly to the end",
            sourceType: .podcast
        )
        try store.saveSource(abandoned)
        try store.saveSource(mostlyPlayed)

        let day = Date(timeIntervalSinceReferenceDate: 780_000_000)
        _ = try store.recordScheduledSourceActivity(
            sourceID: abandoned.id,
            on: day,
            kind: .listening,
            fraction: 0.14
        )
        _ = try store.recordScheduledSourceActivity(
            sourceID: mostlyPlayed.id,
            on: day,
            kind: .listening,
            fraction: 0.78
        )

        // Neither ever reached read_at; only measured depth separates them.
        let offered = try store.unreviewedConsumedSources()
        #expect(offered.map(\.sourceID) == [mostlyPlayed.id])
        // Dated by when it was actually listened to, never by date_added — an
        // auto-ingested backlog must not look consumed the day it was imported.
        #expect(offered.first?.consumedAt == day)
    }

    @Test("Depth keeps the furthest point reached, not the latest sample")
    func depthMergesWithMax() throws {
        let store = try makeInMemoryStore()
        let episode = makeConsumableSource(
            url: "https://example.com/ep-merge",
            title: "Merged depth",
            sourceType: .podcast
        )
        try store.saveSource(episode)
        let day = Date(timeIntervalSinceReferenceDate: 780_000_000)

        for fraction in [0.2, 0.65, 0.4] {
            _ = try store.recordScheduledSourceActivity(
                sourceID: episode.id,
                on: day,
                kind: .listening,
                fraction: fraction
            )
        }

        let days = try store.loadSourceActivityDays(sourceID: episode.id)
        #expect(days.count == 1)
        // Scrubbing back to 0.4 must not retract the 0.65 already reached.
        #expect(days[0].maxFraction == 0.65)
        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [episode.id])
    }

    @Test("Finishing a source records full depth whatever sampling last saw")
    func completionRecordsFullDepth() throws {
        let store = try makeInMemoryStore()
        let episode = makeConsumableSource(
            url: "https://example.com/ep-complete",
            title: "Completed",
            sourceType: .podcast
        )
        try store.saveSource(episode)
        let day = Date(timeIntervalSinceReferenceDate: 780_000_000)

        _ = try store.recordScheduledSourceActivity(
            sourceID: episode.id,
            on: day,
            kind: .listening,
            fraction: 0.42
        )
        try store.recordScheduledSourceCompletion(
            sourceID: episode.id,
            on: day,
            kind: .listening
        )

        let days = try store.loadSourceActivityDays(sourceID: episode.id)
        #expect(days[0].completedKinds == [.listening])
        #expect(days[0].maxFraction == 1)
        #expect(days[0].effectiveFraction == 1)
    }

    @Test("External chapter range completion is atomic and records listening for every chapter")
    func externalChapterCompletionIsAtomic() throws {
        let store = try makeInMemoryStore()
        let chapters = (1...4).map { number in
            makeConsumableSource(
                url: "https://example.com/book/chapter-\(number)",
                title: "Chapter \(number)",
                sourceType: .book
            )
        }
        for chapter in chapters { try store.saveSource(chapter) }
        let day = Date(timeIntervalSinceReferenceDate: 780_500_000)

        try store.recordScheduledSourceCompletions(
            sourceIDs: chapters.map(\.id),
            on: day,
            kind: .listening
        )

        let schedule = try store.loadScheduledSources()
        #expect(schedule.count == 4)
        #expect(Set(schedule.map(\.placement.sourceID)) == Set(chapters.map(\.id)))
        #expect(schedule.allSatisfy { $0.placement.completedAt != nil && $0.isAutomatic })
        #expect(schedule.allSatisfy {
            $0.activityDays.count == 1
                && $0.activityDays[0].completedKinds == [.listening]
                && $0.activityDays[0].maxFraction == 1
        })
        #expect(try store.loadSources().allSatisfy { $0.readAt == day })

        let rollbackStore = try makeInMemoryStore()
        try rollbackStore.saveSource(chapters[0])
        #expect(throws: (any Error).self) {
            try rollbackStore.recordScheduledSourceCompletions(
                sourceIDs: [chapters[0].id, "missing-source"],
                on: day,
                kind: .listening
            )
        }
        #expect(try rollbackStore.loadScheduledSources().isEmpty)
        #expect(try rollbackStore.loadSources().first?.readAt == nil)
    }

    @Test("Merely opening a source still proves nothing")
    func openingWithoutDepthIsNotConsumption() throws {
        let store = try makeInMemoryStore()
        let opened = makeConsumableSource(url: "https://example.com/opened", title: "Opened")
        try store.saveSource(opened)

        // The reader logs activity on open; with no measured depth that must
        // stay exactly as weak a signal as it was before v66.
        _ = try store.recordScheduledSourceActivity(
            sourceID: opened.id,
            on: Date(timeIntervalSinceReferenceDate: 780_000_000),
            kind: .reading
        )

        let days = try store.loadSourceActivityDays(sourceID: opened.id)
        #expect(days[0].kinds == [.reading])
        #expect(days[0].hasMeasuredDepth == false)
        #expect(try store.unreviewedConsumedSources().isEmpty)
    }

    @Test("The depth upgrade stays set-based across a large activity history")
    func version66ScaleRegression() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityDepthV66ScaleTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let rowCount = 5_000
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let article = makeConsumableSource(
                url: "https://example.com/depth-scale",
                title: "Depth scale source"
            )
            try store.saveSource(article)
            _ = try store.recordScheduledSourceActivity(
                sourceID: article.id,
                on: Date(timeIntervalSinceReferenceDate: 780_000_000),
                kind: .reading
            )
            try seedActivityDayRows(at: root, count: rowCount)
        }

        try downgradeActivityDaysToVersion65(at: root)

        // ALTER TABLE ADD COLUMN with a constant default is metadata-only in
        // SQLite; the upgrade must not walk the history row by row.
        let started = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(started)

        var total = 0
        try migrated.query("SELECT COUNT(*) FROM source_activity_days") { stmt in
            total = Int(sqlite3_column_int64(stmt, 0))
        }
        #expect(total == rowCount + 1)
        var unmeasured = 0
        try migrated.query("SELECT COUNT(*) FROM source_activity_days WHERE max_fraction = 0") { stmt in
            unmeasured = Int(sqlite3_column_int64(stmt, 0))
        }
        #expect(unmeasured == total)
        #expect(elapsed < 5)
    }
}

/// Reproduces the released v65 shape of `source_activity_days` — identical in
/// every respect except that measured depth does not exist yet — so the upgrade
/// is exercised against a table that really lacks the column rather than
/// today's schema with a lowered version stamp.
private func downgradeActivityDaysToVersion65(at root: URL) throws {
    try executeFixtureSQL(
        at: root,
        sql: """
        BEGIN IMMEDIATE;
        ALTER TABLE source_activity_days DROP COLUMN max_fraction;
        PRAGMA user_version = 65;
        COMMIT;
        """
    )
}

/// Bulk activity history for the scale regression, written straight to SQLite so
/// the fixture cost stays out of the measured upgrade.
private func seedActivityDayRows(at root: URL, count: Int) throws {
    var statements = ["BEGIN IMMEDIATE;"]
    for index in 0..<count {
        let dayStart = 780_000_000 + Double(index) * 86_400
        statements.append("""
            INSERT INTO source_activity_days (
                id, scheduled_source_id, source_id, day_start,
                first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction
            ) VALUES (
                'scale-activity-\(index)', 'scale-placement', 'scale-source', \(dayStart),
                \(dayStart), \(dayStart), 1, 0, 0
            );
            """)
    }
    statements.append("COMMIT;")
    try executeFixtureSQL(at: root, sql: statements.joined(separator: "\n"))
}

private func executeFixtureSQL(at root: URL, sql: String) throws {
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "ActivityDepthFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
        sqlite3_free(message)
        throw NSError(
            domain: "ActivityDepthFixture",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

/// Adds sources whose stored text still carries HTML character references to a
/// released-shape fixture, so the v68 staging pass has real work to find.
private func addEscapedSourceText(
    at root: URL,
    rows: [(id: String, content: String)]
) throws {
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "EscapedSourceTextFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "EscapedSourceTextFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    let statements = rows.map { row in
        let escaped = row.content.replacingOccurrences(of: "'", with: "''")
        return """
        INSERT INTO sources (id, date_added, state, source_type, status)
        VALUES ('\(row.id)', 1, 'ready', 'article', 'active');
        INSERT INTO source_content (source_id, content) VALUES ('\(row.id)', '\(escaped)');
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        VALUES ('\(row.id)', 'https://example.com/\(row.id)',
                'https://example.com/\(row.id)', 'Escaped \(row.id)', 'example.com');
        """
    }.joined(separator: "\n")
    try exec("BEGIN IMMEDIATE;\n\(statements)\nCOMMIT;")
}

@Suite("Stored HTML character reference repair")
struct StoredHTMLCharacterReferenceRepairTests {
    private static let escaped = "I&#39;ve heard people say &ldquo;M&amp;M&rdquo; &ndash; Pokorn&yacute;"
    private static let decoded = "I've heard people say \u{201C}M&M\u{201D} \u{2013} Pokorn\u{00FD}"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Draining decodes the staged text and republishes the source")
    func drainDecodesAndRepublishes() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/entities", title: "Entities")
        article.content = Self.escaped
        article.state = .ready
        try store.saveSource(article)
        try store.execForTesting("DELETE FROM sync_changes")
        try store.execForTesting("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            VALUES ('\(article.id)', 0)
        """)

        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50) == [article.id])
        #expect(try store.loadSourceContent(article.id) == Self.decoded)
        #expect(try store.sourceTextReferenceRepairQueueCount() == 0)

        // The iPad reads the content asset off the Source record, so a local-only
        // repair would leave the phone showing the references forever.
        let pending = try store.pendingSyncChanges()
        #expect(pending.contains { $0.entity == .source && $0.logicalKey == article.id })

        // Resumable and idempotent: a second pass finds nothing left to do.
        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50).isEmpty)
    }

    @Test("Draining leaves text without references alone")
    func drainLeavesCleanTextAlone() throws {
        let store = try makeInMemoryStore()
        let text = "AT&T, Q&A, and a lone & walk through unchanged."
        var article = makeArticle(url: "https://example.com/clean", title: "Clean")
        article.content = text
        article.state = .ready
        try store.saveSource(article)
        try store.execForTesting("DELETE FROM sync_changes")
        try store.execForTesting("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            VALUES ('\(article.id)', 0)
        """)

        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50).isEmpty)
        #expect(try store.loadSourceContent(article.id) == text)
        #expect(try store.sourceTextReferenceRepairQueueCount() == 0)
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test("A staged source whose content is gone leaves the queue")
    func drainClearsOrphanedQueueRows() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/orphan", title: "Orphan")
        try store.saveSource(article)
        try store.execForTesting("DELETE FROM source_content")
        try store.execForTesting("DELETE FROM sync_changes")
        try store.execForTesting("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            VALUES ('\(article.id)', 0)
        """)

        #expect(try store.drainSourceTextReferenceRepairBatch(limit: 50).isEmpty)
        #expect(try store.sourceTextReferenceRepairQueueCount() == 0)
    }
}

/// Schema 143: a title a scholarly catalog handed over with its inline markup
/// is stored as the text it draws. Crossref's record for the 1971 FEBS Letters
/// paper is the one a chat's Sources list showed with its tags.
@Suite("Stored title markup repair")
struct StoredTitleMarkupRepairTests {
    private static let markedUp = "Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production in pigeon heart mitochondria"
    private static let folded = "Respiratory chain linked H₂O₂ production in pigeon heart mitochondria"
    private static let paperID = "febs-1971-h2o2"
    private static let weeklyID = "weekly-meeting-notes"
    private static let weeklyTitle = "Robin <> Zara - Weekly"
    private static let plainID = "plain-article"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// The released schema-142 library. 143 changes no table, so today's shape
    /// with the stamp lowered is that library exactly. The marked-up title goes
    /// in the way build 159 stored it, straight into the subtype table, because
    /// a save through `StudioArticle` now folds it on the way.
    private func createVersion142Library(at root: URL, extraPapers: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(StudioArticle(
            url: "https://doi.org/10.1016/0014-5793(71)80459-3",
            title: "Placeholder",
            sourceType: .paper,
            id: Self.paperID
        ))
        try store.saveSource(StudioArticle(
            url: "https://example.com/weekly",
            title: Self.weeklyTitle,
            sourceType: .article,
            id: Self.weeklyID
        ))
        try store.saveSource(StudioArticle(
            url: "https://example.com/plain",
            title: "A plain title",
            sourceType: .article,
            id: Self.plainID
        ))
        try store.execForTesting("UPDATE papers SET title = '\(Self.markedUp)' WHERE source_id = '\(Self.paperID)'")
        try store.replaceSourceFTS(sourceID: Self.paperID, title: Self.markedUp, author: "", body: "")
        if extraPapers > 0 {
            // A production-sized library: one title in a thousand carries a
            // catalog's italics, and every one has a title to scan.
            try store.execForTesting("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraPapers))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('paper-%05d', i), 0, 'ready', 'paper' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraPapers))
                INSERT INTO papers (source_id, url, title)
                SELECT printf('paper-%05d', i),
                       printf('https://example.com/papers/%d', i),
                       CASE WHEN i % 1000 = 0
                            THEN printf('Cytochrome <i>c</i> release, study %d', i)
                            ELSE printf('Mitochondrial study %d', i) END
                FROM n;
            """)
        }
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("PRAGMA user_version = 142")
    }

    private func storedTitle(_ sourceID: String, table: String, in store: KnowledgeStore) throws -> String? {
        var title: String?
        try store.query("SELECT title FROM \(table) WHERE source_id = '\(sourceID)'") { statement in
            title = store.string(statement, 0)
        }
        return title
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test("Schema 143 folds a stored title's markup, stages it for republish, and leaves a `<` that is text alone")
    func version143FoldsStoredTitles() throws {
        let root = makeRoot("v143-fold")
        defer { try? FileManager.default.removeItem(at: root) }
        try createVersion142Library(at: root)

        let migrated = try KnowledgeStore(storeDirectory: root)

        var version: Int32 = 0
        try migrated.query("PRAGMA user_version") { statement in version = sqlite3_column_int(statement, 0) }
        #expect(version == KnowledgeStore.schemaVersion)
        #expect(try storedTitle(Self.paperID, table: "papers", in: migrated) == Self.folded)
        #expect(try storedTitle(Self.weeklyID, table: "articles", in: migrated) == Self.weeklyTitle)
        #expect(try storedTitle(Self.plainID, table: "articles", in: migrated) == "A plain title")
        // The library is whole while the republish waits.
        #expect(Set(try migrated.loadSources().map(\.id)) == [Self.paperID, Self.weeklyID, Self.plainID])
        #expect(try migrated.loadSources().first { $0.id == Self.paperID }?.title == Self.folded)

        // Only the changed source is staged, the migration itself publishes
        // nothing, and the full-text row that indexed the tags as words is due
        // for a rewrite.
        #expect(try migrated.sourceSyncRepairQueueCount() == 1)
        #expect(try migrated.pendingSyncChanges().allSatisfy { $0.entity != .source })
        #expect(try count("SELECT COUNT(*) FROM source_fts_state WHERE source_id = '\(Self.paperID)'", in: migrated) == 0)

        // The phone draws the title off the Source record, so the drain has to
        // republish it.
        #expect(try migrated.drainSourceSyncRepairBatch(limit: 50) == 1)
        #expect(try migrated.pendingSyncChanges().contains { $0.entity == .source && $0.logicalKey == Self.paperID })
        #expect(try !migrated.pendingSyncChanges().contains { $0.entity == .source && $0.logicalKey == Self.weeklyID })
    }

    @Test("Schema 143 reads only the titles holding a `<` at production scale")
    func version143ScaleRegression() throws {
        let root = makeRoot("v143-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try createVersion142Library(at: root, extraPapers: 5_000)

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 1.0)
        #expect(try count("SELECT COUNT(*) FROM papers", in: migrated) == 5_001)
        // The FEBS paper and the five italicised titles; nothing else is touched.
        #expect(try migrated.sourceSyncRepairQueueCount() == 6)
        #expect(try storedTitle("paper-01000", table: "papers", in: migrated) == "Cytochrome c release, study 1000")
        #expect(try storedTitle("paper-00999", table: "papers", in: migrated) == "Mitochondrial study 999")
    }

    @Test("Schema 143 rolls back and leaves the released library intact")
    func version143RollsBack() throws {
        let root = makeRoot("v143-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try createVersion142Library(at: root)

        // A structurally incompatible queue table `CREATE TABLE IF NOT EXISTS`
        // will not replace: staging fails after the title was rewritten, inside
        // the migration transaction.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            #expect(sqlite3_exec(
                database,
                "DROP TABLE source_sync_repair_queue; CREATE TABLE source_sync_repair_queue (unexpected TEXT)",
                nil, nil, nil
            ) == SQLITE_OK)
            sqlite3_close(database)
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func text(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        #expect(text("PRAGMA user_version") == "142")
        #expect(text("SELECT COUNT(*) FROM sources") == "3")
        #expect(text("SELECT title FROM papers WHERE source_id = '\(Self.paperID)'") == Self.markedUp)
        #expect(text("SELECT COUNT(*) FROM source_fts_state WHERE source_id = '\(Self.paperID)'") == "1")
    }
}

/// Schema 144: a stored author that is not a name is cleared, and every paper
/// with a DOI is staged to have its title checked against the registered one.
/// The fixture is a released schema-143 library: today's shape without the one
/// table 144 adds. The markup and the profile link go in the way older builds
/// stored them, straight into the subtype table, because a save through
/// `StudioArticle` now turns them away.
@Suite("Stored author repair and registered-title staging")
struct StoredAuthorRepairMigrationTests {
    private static let headID = "src_772d6a3c1740e956a41c0eb9794158ee676fc8a16287282a198b0a67052701ee"
    private static let profileID = "63339EAA-D59E-49DA-8ED1-E530AA504D67"
    private static let namedID = "named-article"
    private static let paperID = "src_901f36ad0112f7d80758f2eb513a32b16d456a4dfdc9f23066a5f132414b8f6a"
    private static let noDOIID = "paper-without-doi"
    private static let headAuthor = #"width=device-width,initial-scale=1,maximum-scale=1" name="viewport"><link href="/fonts/libre-franklin-v4-latin-regular.woff2" rel="preload" as="font" crossorigin="anonymous"><title>Quantum Country</title><meta content="#
    private static let profileAuthor = "https://www.nytimes.com/by/jasmine-sun"
    private static let damagedTitle = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by -Ketoglutarate Dehydrogenase"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build 159 shipped 142 and main carried 143 before 144; neither changed a
    /// table, so both released shapes are today's without the 144 queue.
    private func createReleasedLibrary(at root: URL, version: Int32 = 143, extraRows: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(StudioArticle(url: "https://quantum.country/", title: "Quantum Country", sourceType: .article, id: Self.headID))
        try store.saveSource(StudioArticle(
            url: "https://www.nytimes.com/2026/01/03/business/chinese-peptides-silicon-valley.html",
            title: "Chinese peptides",
            sourceType: .article,
            id: Self.profileID
        ))
        try store.saveSource(StudioArticle(url: "https://example.com/named", title: "Named", sourceType: .article, author: "Jane Doe", id: Self.namedID))
        var paper = StudioArticle(
            url: "https://doi.org/10.1523/jneurosci.1842-04.2004",
            title: Self.damagedTitle,
            sourceType: .paper,
            author: "Laszlo Tretter; Vera Adam-Vizi",
            id: Self.paperID
        )
        paper.doi = "10.1523/jneurosci.1842-04.2004"
        try store.saveSource(paper)
        try store.saveSource(StudioArticle(url: "https://example.com/paper.pdf", title: "A paper without a DOI", sourceType: .paper, id: Self.noDOIID))
        try store.execForTesting("UPDATE articles SET author = '\(Self.headAuthor)' WHERE source_id = '\(Self.headID)'")
        try store.execForTesting("UPDATE articles SET author = '\(Self.profileAuthor)' WHERE source_id = '\(Self.profileID)'")
        try store.replaceSourceFTS(sourceID: Self.headID, title: "Quantum Country", author: Self.headAuthor, body: "")
        if extraRows > 0 {
            // A production-sized library: one article author in a thousand is
            // a profile link, and every paper has a DOI to check.
            try store.execForTesting("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('article-%05d', i), 0, 'ready', 'article' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO articles (source_id, url, title, author)
                SELECT printf('article-%05d', i), printf('https://example.com/a/%d', i), printf('Article %d', i),
                       CASE WHEN i % 1000 = 0 THEN printf('https://example.com/by/writer-%d', i)
                            ELSE printf('Writer %d; Editor %d', i, i) END
                FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('paper-%05d', i), 0, 'ready', 'paper' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO papers (source_id, url, title, author, doi)
                SELECT printf('paper-%05d', i), printf('https://doi.org/10.1000/x%d', i),
                       printf('Mitochondrial study %d', i), printf('Author %d; Colleague %d', i, i), printf('10.1000/x%d', i)
                FROM n;
            """)
        }
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("""
            DROP INDEX IF EXISTS idx_paper_registered_title_order;
            DROP TABLE paper_registered_title_queue;
            PRAGMA user_version = \(version);
        """)
    }

    private func author(_ sourceID: String, in store: KnowledgeStore) throws -> String? {
        var value: String?
        try store.query("""
            SELECT author FROM articles WHERE source_id = '\(sourceID)'
            UNION ALL SELECT author FROM papers WHERE source_id = '\(sourceID)'
        """) { statement in
            value = store.string(statement, 0)
        }
        return value
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test(
        "Schema 144 clears the authors that are not names, stages them for republish, and queues every paper with a DOI",
        arguments: [Int32(142), Int32(143)]
    )
    func version144RepairsAndStages(from released: Int32) throws {
        let root = makeRoot("v144-from-\(released)")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root, version: released)

        let migrated = try KnowledgeStore(storeDirectory: root)

        var version: Int32 = 0
        try migrated.query("PRAGMA user_version") { statement in version = sqlite3_column_int(statement, 0) }
        #expect(version == KnowledgeStore.schemaVersion)
        #expect(try author(Self.headID, in: migrated) == nil)
        #expect(try author(Self.profileID, in: migrated) == nil)
        #expect(try author(Self.namedID, in: migrated) == "Jane Doe")
        #expect(try author(Self.paperID, in: migrated) == "Laszlo Tretter; Vera Adam-Vizi")
        // The library is whole while the republish and the checks wait.
        #expect(Set(try migrated.loadSources().map(\.id)) == [Self.headID, Self.profileID, Self.namedID, Self.paperID, Self.noDOIID])

        // Only the cleared sources are staged, the migration itself publishes
        // nothing, and the full-text row that indexed the markup is due for a
        // rewrite.
        #expect(try migrated.sourceSyncRepairQueueCount() == 2)
        #expect(try migrated.pendingSyncChanges().allSatisfy { $0.entity != .source })
        #expect(try count("SELECT COUNT(*) FROM source_fts_state WHERE source_id = '\(Self.headID)'", in: migrated) == 0)
        #expect(try migrated.drainSourceSyncRepairBatch(limit: 50) == 2)
        let republished = Set(try migrated.pendingSyncChanges().filter { $0.entity == .source }.map(\.logicalKey))
        #expect(republished == [Self.headID, Self.profileID])

        // The paper with a DOI waits for its check; the one without is not staged.
        #expect(try migrated.registeredPaperTitleQueueCount() == 1)
        #expect(try migrated.registeredPaperTitleCandidates(limit: 10).map(\.sourceID) == [Self.paperID])
        #expect(try migrated.registeredPaperTitleCandidates(limit: 10).first?.title == Self.damagedTitle)
    }

    @Test("Schema 144 reads only the author cells that could fail at production scale")
    func version144ScaleRegression() throws {
        let root = makeRoot("v144-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root, extraRows: 5_000)

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 1.0)
        // The fixture's two plus the five profile links; nothing else touched.
        #expect(try migrated.sourceSyncRepairQueueCount() == 7)
        #expect(try author("article-01000", in: migrated) == nil)
        #expect(try author("article-00999", in: migrated) == "Writer 999; Editor 999")
        #expect(try migrated.registeredPaperTitleQueueCount() == 5_001)
    }

    @Test("Schema 144 rolls back and leaves the released library intact")
    func version144RollsBack() throws {
        let root = makeRoot("v144-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root)

        // A structurally incompatible queue table `CREATE TABLE IF NOT EXISTS`
        // will not replace: staging fails after the author was cleared, inside
        // the migration transaction.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            #expect(sqlite3_exec(
                database,
                "DROP TABLE source_sync_repair_queue; CREATE TABLE source_sync_repair_queue (unexpected TEXT)",
                nil, nil, nil
            ) == SQLITE_OK)
            sqlite3_close(database)
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func text(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        #expect(text("PRAGMA user_version") == "143")
        #expect(text("SELECT COUNT(*) FROM sources") == "5")
        #expect(text("SELECT author FROM articles WHERE source_id = '\(Self.headID)'") == Self.headAuthor)
        #expect(text("SELECT COUNT(*) FROM sqlite_master WHERE name = 'paper_registered_title_queue'") == "0")
        #expect(text("SELECT COUNT(*) FROM source_fts_state WHERE source_id = '\(Self.headID)'") == "1")
    }

    @Test("A save never stores an author that is not a name, for a source or a book")
    func writersRefuseImplausibleAuthors() throws {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, id: "post")
        article.author = Self.profileAuthor
        try store.saveSource(article)
        #expect(try author("post", in: store) == nil)

        try store.saveBookMetadata(groupName: "book-1", title: "A book", author: Self.headAuthor, coverPath: nil)
        #expect(try store.loadBooks().authors["book-1"] == nil)
        try store.saveBookMetadata(groupName: "book-1", title: "A book", author: "Nick Lane", coverPath: nil)
        #expect(try store.loadBooks().authors["book-1"] == "Nick Lane")
    }
}

/// The post-launch half of schema 144: each staged paper's title against the
/// title its DOI is registered under, with the catalogs stubbed.
@Suite("Registered paper title check")
struct RegisteredPaperTitleCheckServiceTests {
    private static let damaged = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by -Ketoglutarate Dehydrogenase"
    private static let registered = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by α-Ketoglutarate Dehydrogenase"

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func seedPaper(_ id: String, title: String, doi: String, in store: KnowledgeStore) throws {
        var paper = StudioArticle(url: "https://doi.org/\(doi)", title: title, sourceType: .paper, id: id)
        paper.doi = doi
        try store.saveSource(paper)
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test("Restores the lost glyph, leaves another work's record and an unregistered DOI alone, and keeps asking an unanswered one")
    func drainAppliesTheRule() async throws {
        let root = makeRoot("registered-title")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedPaper("a-damaged", title: Self.damaged, doi: "10.1523/jneurosci.1842-04.2004", in: store)
        try seedPaper("b-wrong-record", title: "KL1333, a derivative of β-lapachone, protects against ototoxicity", doi: "10.1016/j.lfs.2020.118394", in: store)
        try seedPaper("c-unregistered", title: "A bioRxiv version suffix", doi: "10.1101/2025.06.26.661135v2", in: store)
        try seedPaper("d-offline", title: "Asked while offline", doi: "10.1000/offline", in: store)
        #expect(try store.enqueueRegisteredPaperTitleChecks() == 4)
        try store.clearAllPendingSyncChanges()

        let service = RegisteredPaperTitleCheckService(storage: storage) { doi in
            switch doi {
            case "10.1523/jneurosci.1842-04.2004": return .title(Self.registered)
            case "10.1016/j.lfs.2020.118394": return .title("Cardiac function and tolerance to ischemia/reperfusion injury")
            case "10.1101/2025.06.26.661135v2": return .unregistered
            default: return .unavailable("offline")
            }
        }
        let result = await service.drain()

        #expect(result.restored == [RestoredPaperTitle(sourceID: "a-damaged", title: Self.registered)])
        #expect(try store.loadSourceForSync("a-damaged")?.title == Self.registered)
        #expect(try store.loadSourceForSync("a-damaged")?.doi == "10.1523/jneurosci.1842-04.2004")
        #expect(try store.loadSourceForSync("b-wrong-record")?.title == "KL1333, a derivative of β-lapachone, protects against ototoxicity")
        // Only the restored paper travels to the other devices.
        #expect(Set(try store.pendingSyncChanges().filter { $0.entity == .source }.map(\.logicalKey)) == ["a-damaged"])

        // Answered rows leave; the unanswered one stays, one attempt per batch
        // that reached it, and the drain stopped once nothing was answered.
        #expect(result.remainingCount == 1)
        #expect(try store.registeredPaperTitleCandidates(limit: 10).map(\.sourceID) == ["d-offline"])
        #expect(try count("SELECT attempt_count FROM paper_registered_title_queue WHERE source_id = 'd-offline'", in: store) == 2)

        // Offline again: the drain ends at once without answering anything.
        let offline = await service.drain()
        #expect(offline.checkedCount == 0)
        #expect(offline.restored.isEmpty)
    }

    @Test("A title the learner changed since it was staged, or a source that is no longer a paper, is not overwritten")
    func titlesTheLearnerOwnsStand() async throws {
        let root = makeRoot("registered-title-owned")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedPaper("renamed", title: Self.damaged, doi: "10.1523/jneurosci.1842-04.2004", in: store)
        try seedPaper("moved", title: Self.damaged, doi: "10.1000/moved-to-articles", in: store)
        #expect(try store.enqueueRegisteredPaperTitleChecks() == 2)
        // The learner renamed one; the other became an article.
        try store.execForTesting("UPDATE papers SET title = 'My notes on alpha-KGDH' WHERE source_id = 'renamed'")
        var moved = try #require(try store.loadSourceForSync("moved"))
        moved.sourceType = .article
        try store.saveSource(moved)

        let service = RegisteredPaperTitleCheckService(storage: storage) { _ in .title(Self.registered) }
        let result = await service.drain()

        #expect(result.restored.isEmpty)
        #expect(try store.loadSourceForSync("renamed")?.title == "My notes on alpha-KGDH")
        #expect(try store.registeredPaperTitleQueueCount() == 0, "both rows leave the queue")
    }
}

/// Schema 148: every personal YouTube video staged for the post-launch check
/// of its stored transcript against its captions.
@Suite("YouTube transcript check staging")
struct YouTubeTranscriptCheckMigrationTests {
    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    /// Build 165 shipped 146 and main carried 147 before 148. 147 added
    /// `research_directions` and nothing else, so 146's shape is today's
    /// without it and without the 148 queue.
    private func createReleasedLibrary(at root: URL, version: Int32 = 147, extraVideos: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        var lecture = StudioArticle(url: "https://www.youtube.com/watch?v=6BqWzEPN3xg", title: "Intact Cell Measurements 1", sourceType: .video, id: "yt-lecture")
        lecture.content = "[0:00] So hello again. Our class today is about how to measure mitochondrial bioenergetics."
        lecture.state = .ready
        try store.saveSource(lecture)
        try store.saveSource(StudioArticle(url: "https://youtu.be/cvfACkaRwU4", title: "Queued, no transcript yet", sourceType: .video, id: "yt-queued"))
        try store.saveSource(StudioArticle(url: "https://vimeo.com/76979871", title: "Not YouTube", sourceType: .video, id: "vimeo"))
        try store.saveSource(StudioArticle(url: "https://www.youtube.com/watch?v=Y0NPG98yEjY", title: "A team's copy", sourceType: .video, id: "yt-team"))
        try store.saveSource(StudioArticle(url: "https://example.com/post", title: "An article", sourceType: .article, id: "article"))
        try store.execForTesting("UPDATE sources SET team_id = 'team-1' WHERE id = 'yt-team'")
        if extraVideos > 0 {
            // A production-sized library: four in five videos are YouTube's,
            // each with a few thousand characters of text the migration never reads.
            try store.execForTesting("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraVideos))
                INSERT INTO sources (id, date_added, state, source_type)
                SELECT printf('video-%05d', i), 0, 'ready', 'video' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraVideos))
                INSERT INTO videos (source_id, url, title)
                SELECT printf('video-%05d', i),
                       CASE WHEN i % 5 = 0 THEN printf('https://vimeo.com/%d', i)
                            ELSE printf('https://www.youtube.com/watch?v=v%010d', i) END,
                       printf('Lecture %d', i)
                FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraVideos))
                INSERT INTO source_content (source_id, content)
                SELECT printf('video-%05d', i), printf('[0:00] %s', hex(randomblob(1000))) FROM n;
            """)
        }
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("""
            DROP INDEX IF EXISTS idx_youtube_transcript_check_order;
            DROP TABLE youtube_transcript_check_queue;
            \(version < 147 ? "DROP TABLE IF EXISTS research_directions;" : "")
            PRAGMA user_version = \(version);
        """)
    }

    @Test(
        "Schema 148 stages every personal YouTube video and nothing else, and publishes nothing",
        arguments: [Int32(146), Int32(147)]
    )
    func version148Stages(from released: Int32) throws {
        let root = makeRoot("v148-from-\(released)")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root, version: released)

        let migrated = try KnowledgeStore(storeDirectory: root)

        var version: Int32 = 0
        try migrated.query("PRAGMA user_version") { statement in version = sqlite3_column_int(statement, 0) }
        #expect(version == KnowledgeStore.schemaVersion)
        #expect(KnowledgeStore.schemaVersion == 174)
        // The library is whole while the checks wait, the transcript untouched.
        #expect(Set(try migrated.loadSources().map(\.id)) == ["yt-lecture", "yt-queued", "vimeo", "yt-team", "article"])
        #expect(try migrated.loadSourceContent("yt-lecture")?.hasPrefix("[0:00] So hello again.") == true)
        #expect(try migrated.pendingSyncChanges().isEmpty)

        #expect(try migrated.youTubeTranscriptCheckQueueCount() == 2)
        #expect(try migrated.youTubeTranscriptCheckCandidates(limit: 10) == [
            YouTubeTranscriptCheckCandidate(sourceID: "yt-lecture", url: "https://www.youtube.com/watch?v=6BqWzEPN3xg"),
            YouTubeTranscriptCheckCandidate(sourceID: "yt-queued", url: "https://youtu.be/cvfACkaRwU4"),
        ].sorted { $0.sourceID < $1.sourceID })
    }

    @Test("Schema 148 stages ids only at production scale")
    func version148ScaleRegression() throws {
        let root = makeRoot("v148-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root, extraVideos: 5_000)

        let startedAt = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 1.0)
        // The fixture's two plus the four in five of the extra videos on YouTube.
        #expect(try migrated.youTubeTranscriptCheckQueueCount() == 4_002)
        #expect(try count("SELECT COUNT(*) FROM youtube_transcript_check_queue WHERE source_id = 'video-00005'", in: migrated) == 0)
    }

    @Test("Schema 148 rolls back and leaves the released library intact")
    func version148RollsBack() throws {
        let root = makeRoot("v148-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try createReleasedLibrary(at: root)

        // A same-named queue of another shape, which `CREATE TABLE IF NOT
        // EXISTS` will not replace: the probe fails inside the migration.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            #expect(sqlite3_exec(database, "CREATE TABLE youtube_transcript_check_queue (unexpected TEXT)", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func text(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        #expect(text("PRAGMA user_version") == "147")
        #expect(text("SELECT COUNT(*) FROM sources") == "5")
        #expect(text("SELECT COUNT(*) FROM youtube_transcript_check_queue") == "0")
        #expect(text("SELECT substr(content, 1, 22) FROM source_content WHERE source_id = 'yt-lecture'") == "[0:00] So hello again.")
    }
}

/// The post-launch half of schema 148: each staged video's stored transcript
/// against its captions, with the caption fetch stubbed. The fixture is
/// "Isolated Mitochondria and Permeabilized Cells/Tissues 3" at 8:47, as
/// Transcript Formatting stored it and as YouTube's captions have it.
@Suite("YouTube transcript check")
struct YouTubeTranscriptCheckServiceTests {
    private static let url = "https://www.youtube.com/watch?v=2GyLXusxhk4"

    private static let captions = """
    [8:47] of the mitochondrial inner membrane and the matrix and they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another sometimes these probes can block these reactions so they can be inhibitors of lipid oxidation so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation

    [9:15] and inhibiting this process in your media because of your probe and not because it's not happening one of my pet peeves about membrane potential measurements and this is very important is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential
    """

    /// The model's text: the clause at 8:47 and the opening of 9:15 lost,
    /// the two blocks run into one paragraph.
    private static let formatted = """
    [8:47] Of the mitochondrial inner membrane and the matrix, they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another. Sometimes these probes can block these reactions, so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation. And not because it's not happening; one of my pet peeves about membrane potential measurements, and this is very important, is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential.
    """

    private static let slides = """


    ## Extracted video slide frames

    ### Slide frame 1 [8:30–9:40]
    Image: Videos/video/Slides/slide_001_000510s.jpg
    """

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func seedVideo(_ id: String, content: String?, url: String = Self.url, in store: KnowledgeStore) throws {
        var video = StudioArticle(url: url, title: "Isolated Mitochondria 3", sourceType: .video, id: id)
        video.content = content
        video.state = content == nil ? .queued : .ready
        try store.saveSource(video)
    }

    private func count(_ sql: String, in store: KnowledgeStore) throws -> Int {
        var value = 0
        try store.query(sql) { statement in value = Int(sqlite3_column_int64(statement, 0)) }
        return value
    }

    @Test("Puts back what the model dropped, keeps the slide frames, publishes the change and leaves the queue")
    func rewritesADroppedRun() async throws {
        let root = makeRoot("yt-check-rewrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("video", content: Self.formatted + Self.slides, in: store)
        #expect(try store.enqueueYouTubeTranscriptChecks() == 1)
        try store.clearAllPendingSyncChanges()

        let service = YouTubeTranscriptCheckService(storage: storage) { url in
            #expect(url == Self.url)
            return Self.captions
        }
        let result = await service.drain()

        let stored = try #require(try store.loadSourceContent("video"))
        #expect(result.rewritten.map(\.sourceID) == ["video"])
        #expect(result.rewritten.first?.content == stored)
        #expect(stored.contains("these reactions, so they can be inhibitors of lipid oxidation so you may be measuring"))
        #expect(stored.contains("\n\n[9:15] And inhibiting this process in your media because of your probe and not because it's not happening;"))
        #expect(stored.hasSuffix(Self.slides), "the slide frames block is kept as it was")
        #expect(Set(try store.pendingSyncChanges().filter { $0.entity == .source }.map(\.logicalKey)) == ["video"])
        #expect(result.remainingCount == 0)

        // Checked once: a later drain has nothing to fetch.
        let again = await YouTubeTranscriptCheckService(storage: storage) { _ in
            Issue.record("a checked video is not fetched again")
            return Self.captions
        }.drain()
        #expect(again.checkedCount == 0)
    }

    @Test("A transcript of raw captions, or one without markers, is left as it is")
    func leavesRawCaptionsAlone() async throws {
        let root = makeRoot("yt-check-raw")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("raw", content: Self.captions, in: store)
        try seedVideo("untimed", content: "A transcript someone pasted without times.", in: store)
        try seedVideo("empty", content: nil, in: store)
        #expect(try store.enqueueYouTubeTranscriptChecks() == 3)
        try store.clearAllPendingSyncChanges()

        let result = await YouTubeTranscriptCheckService(storage: storage) { _ in Self.captions }.drain()

        #expect(result.rewritten.isEmpty)
        #expect(try store.loadSourceContent("raw") == Self.captions)
        #expect(try store.pendingSyncChanges().isEmpty)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 0, "all three are answered")
    }

    @Test("A transcript is kept when the check would move a highlight or the lines a quiz question rests on")
    func keepsAnchoredText() async throws {
        let root = makeRoot("yt-check-anchored")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("highlighted", content: Self.formatted, in: store)
        try seedVideo("quizzed", content: Self.formatted, in: store)
        try seedVideo("free", content: Self.formatted, in: store)

        // A highlight across the words the check puts back between.
        let quote = "block these reactions, so you may be measuring"
        try store.saveSourceHighlight(SourceHighlight(
            id: "hl", sourceID: "highlighted", quote: quote, note: "", color: .yellow,
            anchor: ReaderTextAnchor(exact: quote), createdAt: Date(), updatedAt: Date()
        ))
        // A question on line 1, where the model ran 9:15 into 8:47's
        // paragraph: re-cut into caption blocks, its quote is on line 2.
        try store.saveCourseGroup(name: "course", metadata: CourseMetadata(title: "Bioenergetics"))
        let lecture = CourseSession(courseName: "course", number: 1, title: "Membrane potential")
        try store.saveCourseLecture(lecture)
        try store.saveCourseQuiz(CourseQuiz(
            id: CourseQuizPlanning.practiceID(courseID: "course", lectureID: lecture.id),
            courseID: "course", kind: .practice, title: "Quiz", lectureIDs: [lecture.id],
            afterLectureID: lecture.id,
            questions: [CourseQuizQuestion(
                id: "q1", sourceID: "quizzed", firstLine: 1, lastLine: 1, startSeconds: nil,
                question: "Why calibrate?", answer: "Fluorescence is not membrane potential.",
                keyPoints: ["no one-to-one relation"],
                quote: "a change in fluorescence or a change in absorbance does not correlate one to one"
            )],
            author: .foreverlm, createdAt: Date(), updatedAt: Date()
        ))
        #expect(try store.enqueueYouTubeTranscriptChecks() == 3)
        try store.clearAllPendingSyncChanges()

        let result = await YouTubeTranscriptCheckService(storage: storage) { _ in Self.captions }.drain()

        #expect(result.rewritten.map(\.sourceID) == ["free"])
        #expect(try store.loadSourceContent("highlighted") == Self.formatted)
        #expect(try store.loadSourceContent("quizzed") == Self.formatted)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 0, "a kept transcript is answered too")
    }

    @Test("Offline, a failed fetch counts an attempt and ends the drain; a video without captions, or one reformatted meanwhile, is left alone")
    func failuresAndRaces() async throws {
        let root = makeRoot("yt-check-failures")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try seedVideo("a", content: Self.formatted, url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", in: store)
        try seedVideo("b", content: Self.formatted, url: "https://www.youtube.com/watch?v=bbbbbbbbbbb", in: store)
        #expect(try store.enqueueYouTubeTranscriptChecks() == 2)
        try store.clearAllPendingSyncChanges()

        let offline = await YouTubeTranscriptCheckService(storage: storage) { _ in
            throw URLError(.notConnectedToInternet)
        }.drain()
        #expect(offline.checkedCount == 0)
        #expect(try count("SELECT MAX(attempt_count) FROM youtube_transcript_check_queue", in: store) == 1)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 2)

        // "a" has no captions any more; "b" is reformatted while its captions
        // are fetched, and the newer text stands.
        let database = root.appendingPathComponent("knowledge.db").path
        let result = await YouTubeTranscriptCheckService(storage: storage) { url in
            guard url.hasSuffix("bbbbbbbbbbb") else { throw YouTubeTranscriptError.noTranscriptAvailable }
            var connection: OpaquePointer?
            guard sqlite3_open(database, &connection) == SQLITE_OK else { throw URLError(.cannotOpenFile) }
            defer { sqlite3_close(connection) }
            sqlite3_busy_timeout(connection, 2_000)
            #expect(sqlite3_exec(
                connection,
                "UPDATE source_content SET content = '[0:00] Reformatted meanwhile.' WHERE source_id = 'b'",
                nil, nil, nil
            ) == SQLITE_OK)
            return Self.captions
        }.drain()
        #expect(result.rewritten.isEmpty)
        #expect(try store.loadSourceContent("a") == Self.formatted)
        #expect(try store.loadSourceContent("b") == "[0:00] Reformatted meanwhile.")
        #expect(try store.pendingSyncChanges().isEmpty)
        #expect(try store.youTubeTranscriptCheckQueueCount() == 0)
    }
}

// MARK: - Search index rows found by key (schema 168)

/// A source's chunk vectors go as a range on the embeddings key, which matches the prefix
/// exactly: an id that only shares the source's leading characters, differs from it in case
/// or holds LIKE's wildcards keeps its vectors.
@Suite("Embedding prefix deletes")
struct EmbeddingPrefixDeleteTests {
    private static func chunk(_ sourceID: String, _ index: Int = 0) -> String {
        StorageService.sourceChunkEmbeddingId(sourceId: sourceID, index: index)
    }

    private static func save(_ store: KnowledgeStore, _ entityID: String, type: KnowledgeEntityType = .sourceChunk, model: String = "m") throws {
        try store.saveEmbedding(entityType: type, entityId: entityID, vector: [1, 0], model: model)
    }

    /// Every embedding left, as `type/id/model`.
    private static func left(_ store: KnowledgeStore) throws -> Set<String> {
        var rows: Set<String> = []
        try store.query("SELECT entity_type || '/' || entity_id || '/' || model FROM embeddings") { stmt in
            if let row = store.string(stmt, 0) { rows.insert(row) }
        }
        return rows
    }

    @Test("One source's chunks go; an id sharing its leading characters or differing in case keeps its own")
    func deletesOneSourceExactly() throws {
        let store = try makeInMemoryStore()
        let neighbours = ["src_ab", "src_A", "SRC_A", "src_", "src_a_"]
        for id in ["src_a"] + neighbours {
            try Self.save(store, Self.chunk(id, 0))
            try Self.save(store, Self.chunk(id, 1))
        }
        // At the range's edges: a proper prefix of the prefix, its bound, and an id past the bound.
        for edge in ["src_a::chunk:", "src_a::chunk:;", "src_a::chunk:;0000"] {
            try Self.save(store, edge)
        }
        // The same id as another kind of entity.
        try Self.save(store, Self.chunk("src_a"), type: .concept)

        try store.deleteEmbeddings(entityType: .sourceChunk, entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: "src_a"))

        var expected: Set<String> = [
            "source_chunk/src_a::chunk:/m", "source_chunk/src_a::chunk:;/m", "source_chunk/src_a::chunk:;0000/m",
            "concept/\(Self.chunk("src_a"))/m",
        ]
        for id in neighbours {
            expected.insert("source_chunk/\(Self.chunk(id, 0))/m")
            expected.insert("source_chunk/\(Self.chunk(id, 1))/m")
        }
        #expect(try Self.left(store) == expected)
    }

    @Test("A source id holding LIKE's wildcards matches only itself")
    func wildcardsAreLiteral() throws {
        let store = try makeInMemoryStore()
        for id in ["a_b%c", "aXbYYc", "a_b%cd"] {
            try Self.save(store, Self.chunk(id))
        }

        try store.deleteEmbeddings(entityType: .sourceChunk, entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: "a_b%c"))

        #expect(try Self.left(store) == ["source_chunk/\(Self.chunk("aXbYYc"))/m", "source_chunk/\(Self.chunk("a_b%cd"))/m"])
    }

    @Test("Given a model, only that model's chunks of the source go")
    func deletesOneModel() throws {
        let store = try makeInMemoryStore()
        for model in ["m", "n"] {
            try Self.save(store, Self.chunk("src_a"), model: model)
            try Self.save(store, Self.chunk("src_ab"), model: model)
        }

        try store.deleteEmbeddings(entityType: .sourceChunk, entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: "src_a"), model: "m")

        #expect(try Self.left(store) == [
            "source_chunk/\(Self.chunk("src_a"))/n", "source_chunk/\(Self.chunk("src_ab"))/m", "source_chunk/\(Self.chunk("src_ab"))/n",
        ])
    }

    @Test("The bound sorts, in SQLite's own order, after every text that begins with the prefix and before every other above it")
    func upperBound() throws {
        #expect(KnowledgeStore.textPrefixUpperBound("src_a::chunk::") == "src_a::chunk:;")
        #expect(KnowledgeStore.textPrefixUpperBound("é") == "ê")
        #expect(KnowledgeStore.textPrefixUpperBound("a\u{D7FF}") == "a\u{E000}")
        #expect(KnowledgeStore.textPrefixUpperBound("a\u{10FFFF}") == "b")
        #expect(KnowledgeStore.textPrefixUpperBound("\u{10FFFF}") == nil)
        #expect(KnowledgeStore.textPrefixUpperBound("") == nil)

        let store = try makeInMemoryStore()
        let texts = ["", "a", "A", "ab", "a\u{D7FF}", "a\u{D7FF}x", "a\u{E000}", "a\u{FFFF}", "a\u{10000}",
                     "a\u{10FFFF}", "a\u{10FFFF}z", "b", "e", "e\u{301}", "é", "ê"]
        for prefix in ["a", "a\u{D7FF}", "a\u{10FFFF}", "e", "é", ""] {
            let bound = KnowledgeStore.textPrefixUpperBound(prefix)
            for text in texts {
                var values: [SQLiteValue] = [.text(text), .text(prefix)]
                if let bound { values.append(.text(bound)) }
                let inRange = try store.scalarInteger(
                    bound == nil ? "SELECT ?1 >= ?2" : "SELECT ?1 >= ?2 AND ?1 < ?3", values
                ) == 1
                #expect(inRange == text.unicodeScalars.starts(with: prefix.unicodeScalars), "\(prefix.debugDescription) / \(text.debugDescription)")
            }
        }
    }
}

/// A source's full-text row is found by the rowid `source_fts_rows` keeps for it (schema 168),
/// not by reading every row for the UNINDEXED `source_id`.
@Suite("Full-text rows by rowid")
struct SourceFTSRowTests {
    /// The full-text rows' sources, in order.
    static func rows(_ store: KnowledgeStore) throws -> [String] {
        var ids: [String] = []
        try store.query("SELECT source_id FROM source_fts ORDER BY source_id") { stmt in
            if let id = store.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Whether the map holds one rowid for each row, and each rowid is its source's row.
    static func mapIsExact(_ store: KnowledgeStore) throws -> Bool {
        try store.scalarInteger("""
            SELECT (SELECT COUNT(*) FROM source_fts_rows) = (SELECT COUNT(*) FROM source_fts)
               AND NOT EXISTS (
                    SELECT 1 FROM source_fts_rows r
                    WHERE NOT EXISTS (SELECT 1 FROM source_fts f WHERE f.rowid = r.fts_rowid AND f.source_id = r.source_id)
               )
        """) == 1
    }

    static func matches(_ store: KnowledgeStore, _ term: String) throws -> [String] {
        try store.searchSourceFTS(matchExpression: "\"\(term)\"", limit: 20).map { $0.id }.sorted()
    }

    @Test("Deleting one source's row leaves every other source's, an id sharing its leading characters or differing in case included")
    func deleteLeavesOtherSources() throws {
        let store = try makeInMemoryStore()
        for id in ["src_a", "src_ab", "src_A", "src_"] {
            try store.replaceSourceFTS(sourceID: id, title: "Title of \(id)", author: "", body: "mitochondria")
        }

        try store.deleteSourceFTS(sourceID: "src_a")

        #expect(try Self.rows(store) == ["src_", "src_A", "src_ab"])
        #expect(try Self.matches(store, "mitochondria") == ["src_", "src_A", "src_ab"])
        #expect(try Self.mapIsExact(store))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_state WHERE source_id = 'src_a'") == 0)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_state") == 3)
    }

    @Test("Writing a source's row again replaces it: one row, the new words, under its new rowid")
    func replaceKeepsOneRow() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "First", author: "", body: "glycolysis")
        try store.replaceSourceFTS(sourceID: "src_ab", title: "Neighbour", author: "", body: "glycolysis")
        try store.replaceSourceFTS(sourceID: "src_a", title: "Second", author: "", body: "oxphos")

        #expect(try Self.rows(store) == ["src_a", "src_ab"])
        #expect(try Self.matches(store, "glycolysis") == ["src_ab"])
        #expect(try Self.matches(store, "oxphos") == ["src_a"])
        #expect(try Self.mapIsExact(store))
    }

    @Test("A stamp dropped to have the row written again keeps the rowid, so the rewrite replaces the row")
    func droppedStampKeepsTheRowid() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "A <i>marked</i> title", author: "", body: "")
        // What a repaired title does (`restoreRegisteredPaperTitle`, the schema-144 folds).
        try store.execute("DELETE FROM source_fts_state WHERE source_id = 'src_a'")

        try store.replaceSourceFTS(sourceID: "src_a", title: "A plain title", author: "", body: "")

        #expect(try Self.rows(store) == ["src_a"])
        #expect(try Self.matches(store, "marked").isEmpty)
        #expect(try Self.mapIsExact(store))
    }

    @Test("A rowid the map should not hold takes no other source's row")
    func staleRowidTakesNothing() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "A", author: "", body: "")
        try store.replaceSourceFTS(sourceID: "src_b", title: "B", author: "", body: "")
        try store.execute("""
            UPDATE source_fts_rows SET fts_rowid = (SELECT fts_rowid FROM source_fts_rows WHERE source_id = 'src_b')
            WHERE source_id = 'src_a'
        """)

        try store.deleteSourceFTS(sourceID: "src_a")

        #expect(try Self.rows(store).contains("src_b"))
    }

    @Test("Inside a caller's transaction the row, its rowid and its stamp roll back together")
    func joinsTheCallersTransaction() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "Kept", author: "", body: "")
        try store.replaceSourceFTS(sourceID: "src_b", title: "Also kept", author: "", body: "")

        try store.execute("BEGIN IMMEDIATE")
        try store.replaceSourceFTS(sourceID: "src_a", title: "Rolled back", author: "", body: "")
        try store.deleteSourceFTS(sourceID: "src_b")
        try store.execute("ROLLBACK")

        #expect(try Self.rows(store) == ["src_a", "src_b"])
        #expect(try Self.matches(store, "kept") == ["src_a", "src_b"])
        #expect(try Self.matches(store, "rolled").isEmpty)
        #expect(try Self.mapIsExact(store))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_state") == 2)
    }

    @Test("A rewrite that fails partway leaves the old row, its rowid and its stamp as they were")
    func failedRewriteChangesNothing() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "Kept", author: "", body: "")
        try store.execute("CREATE TEMP TRIGGER refuse_stamp BEFORE INSERT ON source_fts_state BEGIN SELECT RAISE(ABORT, 'refused'); END")

        #expect(throws: (any Error).self) {
            try store.replaceSourceFTS(sourceID: "src_a", title: "Lost", author: "", body: "")
        }

        #expect(try Self.matches(store, "kept") == ["src_a"])
        #expect(try Self.matches(store, "lost").isEmpty)
        #expect(try Self.mapIsExact(store))
        #expect(sqlite3_get_autocommit(store.db) != 0, "no transaction is left open")
    }
}

/// Full-text rows written before schema 168 kept no rowid. The migration stages their record
/// (`source_fts_row_backfill`); the indexer records them in batches after launch, and a write
/// that comes first records the rest before it looks for its row.
@Suite("Full-text rows written before schema 168")
struct SourceFTSRowBackfillTests {
    /// Rows as builds before 168 wrote them, straight into `source_fts` with a stamp and no rowid
    /// kept, `stampless` ones with their stamp dropped since, and the record staged as the
    /// migration stages it.
    private static func storeWithOldRows(_ ids: [String], stampless: Set<String> = []) throws -> KnowledgeStore {
        let store = try makeInMemoryStore()
        for id in ids {
            try store.execute(
                "INSERT INTO source_fts (source_id, title, author, body) VALUES (?, ?, '', 'mitochondria')",
                [.text(id), .text("Title of \(id)")]
            )
            guard !stampless.contains(id) else { continue }
            try store.execute(
                "INSERT OR REPLACE INTO source_fts_state (source_id, analyzer_version, written_at) VALUES (?, ?, 0)",
                [.text(id), .integer(Int64(SourceSearchEngine.indexAnalyzerVersion))]
            )
        }
        try store.enqueueSourceFTSRowBackfill()
        return store
    }

    private static func pending(_ store: KnowledgeStore) throws -> Bool {
        try store.scalarInteger("SELECT COUNT(*) FROM source_fts_row_backfill") == 1
    }

    @Test("A delete before the record is done records every old row first, then takes only its own")
    func deleteRecordsTheOldRowsFirst() throws {
        let store = try Self.storeWithOldRows(["src_a", "src_ab", "src_A", "src_b"], stampless: ["src_b"])

        try store.deleteSourceFTS(sourceID: "src_a")

        #expect(try SourceFTSRowTests.rows(store) == ["src_A", "src_ab", "src_b"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
        #expect(try !Self.pending(store))

        // A row whose stamp was dropped since is found all the same.
        try store.deleteSourceFTS(sourceID: "src_b")
        #expect(try SourceFTSRowTests.rows(store) == ["src_A", "src_ab"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
    }

    @Test("A source's row written while old rows wait leaves no old row of it behind")
    func writeWhileOldRowsWait() throws {
        let store = try Self.storeWithOldRows(["src_a", "src_b"])

        try store.replaceSourceFTS(sourceID: "src_new", title: "New", author: "", body: "oxphos")
        try store.replaceSourceFTS(sourceID: "src_a", title: "A again", author: "", body: "oxphos")

        #expect(try SourceFTSRowTests.rows(store) == ["src_a", "src_b", "src_new"])
        #expect(try SourceFTSRowTests.matches(store, "mitochondria") == ["src_b"])
        #expect(try SourceFTSRowTests.matches(store, "oxphos") == ["src_a", "src_new"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
        #expect(try !Self.pending(store))
    }

    @Test("Batches record the old rows in rowid order, pass over rows written meanwhile, and the last retires the record")
    func batches() throws {
        let store = try Self.storeWithOldRows((0..<5).map { "src_\($0)" })

        #expect(try store.recordSourceFTSRows(limit: 2))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_rows") == 2)
        #expect(try store.scalarInteger("SELECT after_rowid FROM source_fts_row_backfill") == 2)
        // A source already recorded is written again between batches.
        try store.replaceSourceFTS(sourceID: "src_0", title: "Again", author: "", body: "oxphos")
        #expect(try store.recordSourceFTSRows(limit: 2))
        #expect(try store.recordSourceFTSRows(limit: 2))
        #expect(try !store.recordSourceFTSRows(limit: 2))

        #expect(try !Self.pending(store))
        #expect(try SourceFTSRowTests.rows(store) == (0..<5).map { "src_\($0)" })
        #expect(try SourceFTSRowTests.mapIsExact(store))
        // Nothing left to record: an answer at once.
        #expect(try !store.recordSourceFTSRows(limit: 2))
    }

    @Test("Two rows for one source keep the later")
    func twoRowsKeepTheLater() throws {
        let store = try makeInMemoryStore()
        try store.execute("""
            INSERT INTO source_fts (source_id, title, author, body) VALUES
                ('src_a', 'Earlier', '', 'glycolysis'),
                ('src_b', 'Other', '', 'glycolysis'),
                ('src_a', 'Later', '', 'oxphos')
        """)
        try store.enqueueSourceFTSRowBackfill()

        #expect(try !store.recordSourceFTSRows(limit: nil))

        #expect(try SourceFTSRowTests.rows(store) == ["src_a", "src_b"])
        #expect(try SourceFTSRowTests.matches(store, "glycolysis") == ["src_b"])
        #expect(try SourceFTSRowTests.matches(store, "oxphos") == ["src_a"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
    }

    @Test("With nothing staged, a source with no rowid kept has no row, and no row is read to look for one")
    func nothingStagedLooksNowhere() throws {
        let store = try makeInMemoryStore()
        // Planted: a row no rowid names, which only a write outside `replaceSourceFTS` leaves. A
        // delete that still read every row's id would find and take it.
        try store.execute("INSERT INTO source_fts (source_id, title, author, body) VALUES ('planted', 'Planted', '', 'glycolysis')")

        try store.deleteSourceFTS(sourceID: "planted")
        try store.replaceSourceFTS(sourceID: "planted", title: "Written", author: "", body: "oxphos")

        #expect(try SourceFTSRowTests.matches(store, "glycolysis") == ["planted"])
        #expect(try SourceFTSRowTests.matches(store, "oxphos") == ["planted"])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_rows") == 1)
    }
}

/// Schema 168 on a library in a released shape: the map comes in empty and the record of the
/// rows already written is staged; no full-text row is read or changed until after launch.
@Suite("Full-text row map migration", .serialized)
struct SourceFTSRowMapMigrationTests {
    /// A library at `version` as released: `Schema154Fixture`'s shapes up to 163, today's store
    /// stamped 165 for 165; without the two 168 tables either way, and with a full-text row and
    /// stamp per source written as builds before 168 wrote them, plus `extraRows` rows more.
    private static func makeReleasedLibrary(at root: URL, version: Int32, extraRows: Int = 0) throws -> Schema154Fixture.Library {
        let library = try Schema154Fixture.makeLibrary(at: root, version: version == 165 ? nil : version)
        let handle = try SQLiteHandle(path: root.appendingPathComponent("knowledge.db").path)
        for id in library.sourceIDs {
            try handle.execute("INSERT INTO source_fts (source_id, title, author, body) VALUES (?, 'A paper', '', 'mitochondria')", [.text(id)])
            try handle.execute("INSERT INTO source_fts_state (source_id, analyzer_version, written_at) VALUES (?, 1, 0)", [.text(id)])
        }
        if extraRows > 0 {
            try handle.executeScript("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraRows))
                INSERT INTO source_fts (source_id, title, author, body)
                SELECT printf('paper-%05d', i), printf('Paper %d', i), '', hex(randomblob(500)) FROM n;
            """)
        }
        try handle.executeScript("""
            DROP TABLE source_fts_rows;
            DROP TABLE source_fts_row_backfill;
            \(version == 165 ? "PRAGMA user_version = 165;" : "")
        """)
        return library
    }

    private static func open(_ root: URL, freeSpace: (URL) throws -> Int64? = Schema154Fixture.roomy) throws -> KnowledgeStore {
        Schema154Fixture.newLaunch(root)
        return try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: freeSpace)
    }

    @Test("A released library comes up at the current schema, the map empty, the record staged, every full-text row as it was", arguments: [Int32(153), Int32(163), Int32(165)])
    func forwardMigration(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("fts-rows-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.makeReleasedLibrary(at: root, version: version)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(version))

        let store = try Self.open(root)

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_fts_rows") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_fts_row_backfill WHERE after_rowid = 0") == 1)
        #expect(try SourceFTSRowTests.rows(store) == library.sourceIDs.sorted())
        // The library is whole and on screen while the record waits.
        #expect(Set(try store.loadActiveSources().map(\.id)) == Set(library.sourceIDs))
        if version == 165 {
            #expect(try store.pendingSyncChanges().isEmpty, "the step writes nothing that syncs")
        }

        // After launch a delete records the old rows, takes its own, and leaves the rest found by rowid.
        try store.deleteSourceFTS(sourceID: library.sourceIDs[0])
        #expect(try SourceFTSRowTests.rows(store) == library.sourceIDs.dropFirst().sorted())
        #expect(try SourceFTSRowTests.matches(store, "mitochondria") == library.sourceIDs.dropFirst().sorted())
        #expect(try SourceFTSRowTests.mapIsExact(store))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_fts_row_backfill") == 0)
    }

    @Test("A store an older build held at 153 for want of room gains the map and the staged record, so its full-text writes work while it waits")
    func heldAt153() throws {
        let root = try Schema154Fixture.temporaryRoot("fts-rows-held")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { LibraryUpgradeSpace.record(nil) }
        let library = try Self.makeReleasedLibrary(at: root, version: 153)
        let tight: (URL) throws -> Int64? = { _ in 1_500_000_000 }

        let waiting = try Self.open(root, freeSpace: tight)
        #expect(waiting.upgradeWaitingForSpace != nil)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 153)
        #expect(try Schema154Fixture.count(waiting, "SELECT COUNT(*) FROM source_fts_row_backfill") == 1)
        try waiting.deleteSourceFTS(sourceID: library.sourceIDs[0])
        try waiting.replaceSourceFTS(sourceID: library.sourceIDs[1], title: "A paper", author: "", body: "oxphos")
        #expect(try SourceFTSRowTests.rows(waiting) == library.sourceIDs.dropFirst().sorted())
        #expect(try SourceFTSRowTests.mapIsExact(waiting))

        // Held again, it keeps what it has; given room, it comes up at the current schema whole.
        _ = try Self.open(root, freeSpace: tight)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 153)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM source_fts_rows") == library.sourceIDs.count - 1)
        let later = try Self.open(root)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        try later.deleteSourceFTS(sourceID: library.sourceIDs[1])
        #expect(try SourceFTSRowTests.rows(later) == library.sourceIDs.dropFirst(2).sorted())
        #expect(try SourceFTSRowTests.mapIsExact(later))
    }

    @Test("A same-named table of another shape rolls the migration back and leaves the released library as it was")
    func rollsBack() throws {
        let root = try Schema154Fixture.temporaryRoot("fts-rows-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.makeReleasedLibrary(at: root, version: 165)
        try SQLiteHandle(path: root.appendingPathComponent("knowledge.db").path)
            .executeScript("CREATE TABLE source_fts_rows (unexpected TEXT)")

        #expect(throws: (any Error).self) { _ = try Self.open(root) }

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 165)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM source_fts") == library.sourceIDs.count)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'source_fts_row_backfill'") == 0)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('source_fts_rows') WHERE name = 'unexpected'") == 1)
    }

    @Test("Reads no full-text row at production scale, well under a second; the rows are recorded after launch")
    func scaleRegression() throws {
        let root = try Schema154Fixture.temporaryRoot("fts-rows-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.makeReleasedLibrary(at: root, version: 165, extraRows: 5_000)

        let started = ContinuousClock.now
        let store = try Self.open(root)
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .seconds(1))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_fts_rows") == 0)
        while try store.recordSourceFTSRows(limit: 256) {}
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_fts_rows") == 5_000 + library.sourceIDs.count)
        #expect(try SourceFTSRowTests.mapIsExact(store))
    }
}

/// An archived or deleted source leaves search whole: its full-text row, the stamps and rowid kept
/// for it, the record of being indexed and its vectors of every model. Before 2026-10-06 an
/// archive or delete arriving by sync took none of it, a duplicate's archive left its vectors, a
/// delete left its full-text row, and the vector index loaded every stored chunk at launch: on the
/// production library 391 archived or deleted sources held some of it, among them 263 full-text rows
/// and 36,705 vectors.
@Suite("A source out of search")
struct SourceOutOfSearchTests {
    private static let model = StorageService.sourceEmbeddingModel

    /// A source as the indexer leaves one: a full-text row holding `word`, its stamps, two chunk
    /// vectors of the current model, one of an older model and a source-level vector.
    private static func indexedSource(_ store: KnowledgeStore, _ name: String, word: String) throws -> String {
        var article = makeArticle(url: "https://example.com/\(name)", title: "Title of \(name)")
        _ = try store.insertSourceIfNew(&article)
        try store.replaceSourceFTS(sourceID: article.id, title: "Title of \(name)", author: "", body: word)
        for index in 0..<2 {
            try store.saveEmbedding(
                entityType: .sourceChunk,
                entityId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: index),
                vector: [1, 0],
                model: model
            )
        }
        try store.saveEmbedding(
            entityType: .sourceChunk,
            entityId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: 0),
            vector: [0, 1],
            model: "an-older-model"
        )
        try store.saveEmbedding(entityType: .source, entityId: article.id, vector: [1, 1], model: model)
        try store.recordSourceIndexed(sourceID: article.id, model: model)
        return article.id
    }

    /// What search still holds of `id`.
    private static func held(_ store: KnowledgeStore, _ id: String) throws -> Set<String> {
        var parts: Set<String> = []
        let checks: [(String, String)] = [
            ("full-text row", "SELECT COUNT(*) FROM source_fts WHERE source_id = ?1"),
            ("rowid", "SELECT COUNT(*) FROM source_fts_rows WHERE source_id = ?1"),
            ("analyzer stamp", "SELECT COUNT(*) FROM source_fts_state WHERE source_id = ?1"),
            ("indexed record", "SELECT COUNT(*) FROM source_index_state WHERE source_id = ?1"),
            ("chunk vectors", "SELECT COUNT(*) FROM embeddings WHERE entity_type = 'source_chunk' AND entity_id >= ?1 || '::chunk::' AND entity_id < ?1 || '::chunk:;'"),
            ("source vector", "SELECT COUNT(*) FROM embeddings WHERE entity_type = 'source' AND entity_id = ?1"),
        ]
        for (part, sql) in checks {
            if (try store.scalarInteger(sql, [.text(id)]) ?? 0) > 0 { parts.insert(part) }
        }
        return parts
    }

    private static let everything: Set<String> = ["full-text row", "rowid", "analyzer stamp", "indexed record", "chunk vectors", "source vector"]

    private static func keywordHits(_ store: KnowledgeStore, _ word: String) throws -> Set<String> {
        Set(try store.searchSourceFTS(matchExpression: "\"\(word)\"", limit: 20).map(\.id))
    }

    @Test("Archiving takes the whole of a source out of search, and another source keeps all of its own")
    func archiveTakesItAll() throws {
        let store = try makeInMemoryStore()
        let archived = try Self.indexedSource(store, "archived", word: "telomere")
        let kept = try Self.indexedSource(store, "kept", word: "telomere")
        #expect(try Self.held(store, archived) == Self.everything)

        try store.archiveSource(archived)

        #expect(try Self.held(store, archived).isEmpty)
        #expect(try Self.held(store, kept) == Self.everything)
        #expect(try Self.keywordHits(store, "telomere") == [kept])
        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 10).isEmpty)
    }

    @Test("Deleting takes the full-text row and the stamps too, not only the vectors")
    func deleteTakesItAll() throws {
        let store = try makeInMemoryStore()
        let deleted = try Self.indexedSource(store, "deleted", word: "mitophagy")

        try store.deleteSourceRows(deleted)

        #expect(try Self.held(store, deleted).isEmpty)
        #expect(try Self.keywordHits(store, "mitophagy").isEmpty)
    }

    @Test("Clearing a source's text takes its full-text row with the vectors, so the old words are not found")
    func clearedTextLeavesNoRow() throws {
        let store = try makeInMemoryStore()
        let cleared = try Self.indexedSource(store, "cleared", word: "glycolysis")

        try store.clearSourceDerivedData(cleared)

        #expect(try Self.held(store, cleared).isEmpty)
        #expect(try Self.keywordHits(store, "glycolysis").isEmpty)
    }

    @Test("An archive or a delete that took nothing with it is found, and dropping its rows leaves the active sources alone")
    func sweepFindsWhatSyncLeft() throws {
        let store = try makeInMemoryStore()
        let active = try Self.indexedSource(store, "active", word: "ketone")
        let archivedBySync = try Self.indexedSource(store, "archived-by-sync", word: "ketone")
        let deletedBySync = try Self.indexedSource(store, "deleted-by-sync", word: "ketone")
        // What an inbound record applies (`SourceProjection.apply`, `applyDeletion`): the row
        // changes and nothing else does.
        try store.execute("UPDATE sources SET status = 'archived' WHERE id = ?", [.text(archivedBySync)])
        try store.execute("DELETE FROM sources WHERE id = ?", [.text(deletedBySync)])
        #expect(try Self.keywordHits(store, "ketone") == [active, archivedBySync, deletedBySync], "keyword search reads no status")

        let found = try store.sourcesOutOfSearchHoldingSearchRows(limit: 10)
        #expect(found == [archivedBySync, deletedBySync].sorted())
        for id in found { try store.dropSourceSearchRows(sourceID: id) }

        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 10).isEmpty)
        #expect(try Self.held(store, archivedBySync).isEmpty)
        #expect(try Self.held(store, deletedBySync).isEmpty)
        #expect(try Self.held(store, active) == Self.everything)
        #expect(try Self.keywordHits(store, "ketone") == [active])
    }

    @Test("An archived source holding only vectors, as older builds left them, is found too, a page at a time")
    func vectorsAloneAreFound() throws {
        let store = try makeInMemoryStore()
        var ids: [String] = []
        for name in ["a", "b", "c"] {
            let id = try Self.indexedSource(store, name, word: "lactate")
            try store.execute("UPDATE sources SET status = 'archived' WHERE id = ?", [.text(id)])
            // The full-text row, its stamps and the indexed record went; the vectors stayed.
            try store.deleteSourceFTS(sourceID: id)
            try store.deleteSourceIndexState(sourceID: id)
            #expect(try Self.held(store, id) == ["chunk vectors", "source vector"])
            ids.append(id)
        }

        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 2) == Array(ids.sorted().prefix(2)))
        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 10) == ids.sorted())
        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 0).isEmpty)
    }

    @Test("The service's sweep takes out a deleted source's full-text row, so search stops finding it")
    func serviceSweep() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/kept", title: "Butyrate and the colon")
        try await svc.insertSourceIfNew(&article)
        try await svc.replaceSourceFTS(sourceID: article.id, title: "Butyrate and the colon", author: "", body: "butyrate")
        // A full-text row whose source was deleted by sync.
        try await svc.replaceSourceFTS(sourceID: "src_deleted_elsewhere", title: "Gone", author: "", body: "butyrate")
        let before = await svc.searchSources(queryText: "butyrate", queryVector: nil, limit: 5).map(\.sourceId)
        #expect(Set(before) == [article.id, "src_deleted_elsewhere"])

        #expect(try await svc.dropSearchRowsOfSourcesOutOfSearch(limit: 64) == 1)
        #expect(try await svc.dropSearchRowsOfSourcesOutOfSearch(limit: 64) == 0)

        let after = await svc.searchSources(queryText: "butyrate", queryVector: nil, limit: 5).map(\.sourceId)
        #expect(after == [article.id])
    }

    @Test("The vector index loads only the chunks of sources in search")
    func vectorLoadKeepsSourcesInSearch() {
        let chunk = { (source: String, index: Int) in StorageService.sourceChunkEmbeddingId(sourceId: source, index: index) }
        let embeddings: [String: [Float]] = [
            chunk("src_a", 0): [1], chunk("src_a", 1): [2], chunk("src_ab", 0): [3], chunk("src_gone", 0): [4], "not-a-chunk": [5],
        ]
        let kept = StorageService.chunkVectors(embeddings, ofSourcesIn: ["src_a", "src_ab"])
        #expect(Set(kept.keys) == [chunk("src_a", 0), chunk("src_a", 1), chunk("src_ab", 0)])
        #expect(StorageService.chunkVectors(embeddings, ofSourcesIn: []).isEmpty)
    }
}
