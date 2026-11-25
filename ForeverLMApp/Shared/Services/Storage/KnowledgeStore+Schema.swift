import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Pragmas & Schema

    func pragmas() throws {
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA busy_timeout = 10000")
    }

    /// The schema installed into a brand-new database and the target for one-time,
    /// transactional startup migrations. A store already at this version takes the
    /// read-only fast path apart from the code-owned `source_projection` view drift
    /// check.
    // Migration steps run from `minimumMigratableSchemaVersion` (174) up to this version:
    //
    // 175: the seven generation-1 sync tables (`sync_changes`, `sync_metadata`, `sync_conflicts`,
    // `sync_asset_digests`, `sync_engine_states`, `source_sync_repair_queue`,
    // `review_session_sync_repair_queue`) are dropped, and a fresh store never makes them. The step first
    // records in `ck_activation` what the last of them told the activation: a store with generation-1 sync
    // history and no mode yet activates `deferred`, and an unactivated `full` journal continues as
    // `deferred`. Nothing else is read from them; `card_meta` and `card_reviews` are not theirs and stay.
    //
    // 176: `artifact_collaboration` (an Artifact's sharing is a Doc space), `journal_watch_excluded_notebooks`,
    // `paper_figure_markdown_repair_queue`, `ck_legacy_snapshot` and `videos.legacy_cap_verified_at` are
    // dropped, because nothing reads or writes them, and a fresh store never makes them.
    // `ck_legacy_bodies`, which is still written (a Doc body's acknowledged upload), is renamed
    // `ck_body_sends`, rows and all.
    //
    // 177: a notebook's own task Board lists. `notebook_task_lists` (one row per element of
    // `Notebook.boardLists`) is created empty, and `notebook_tasks.list_id` (`Task.listID`) is added,
    // NULL on every existing row: DDL only.
    //
    // 178: the chat a Board card was taken into. `notebook_tasks.chat_id` (`Task.chatID`) is added,
    // NULL on every existing row: DDL only.
    //
    // 179: the learner's chat skills are gone from the app (product owner, 2026-11-21: "remove skills
    // from the app"). `skills` and `idx_skills_name` are dropped, and a fresh store never makes them.
    //
    // 180: a mark flagged to follow up, apart from its color (product owner, 2026-11-25: "the color
    // shouldn't necessarily itself code for followup"). `source_highlights.follow_up_at` is added, and
    // every blue or pink mark — the two colors that put a mark on the To Follow Up list until now — is
    // flagged as of when it was made, so nothing on that list falls off it.
    static let schemaVersion: Int32 = 180
    static let generation1RemovalSchemaVersion: Int32 = 175
    static let deadObjectsRemovalSchemaVersion: Int32 = 176
    static let boardListsSchemaVersion: Int32 = 177
    static let boardChatSchemaVersion: Int32 = 178
    static let skillsRemovalSchemaVersion: Int32 = 179
    static let highlightFollowUpSchemaVersion: Int32 = 180
    /// The oldest store this build migrates: schema 174. An older store is
    /// refused (product owner, 2026-11: old versions are no longer supported).
    static let minimumMigratableSchemaVersion: Int32 = 174

    /// Migrates the store to `schemaVersion` from `minimumMigratableSchemaVersion` or later, or creates
    /// it there.
    func createSchema() throws {
        var currentVersion: Int32 = 0
        try query("PRAGMA user_version") { stmt in
            currentVersion = sqlite3_column_int(stmt, 0)
        }
        guard currentVersion != Self.schemaVersion else {
            try reconcileSourceProjectionView()
            return
        }

        var hasApplicationTables = false
        try query("""
            SELECT EXISTS(
                SELECT 1
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
            )
        """) { stmt in
            hasApplicationTables = sqlite3_column_int(stmt, 0) != 0
        }
        guard currentVersion <= Self.schemaVersion else {
            throw KnowledgeStoreError.invalidData(
                "Knowledge database schema version \(currentVersion) is newer than this build supports (\(Self.schemaVersion)). Update ForeverLM before opening this database."
            )
        }
        let isFreshDatabase = currentVersion == 0 && !hasApplicationTables
        guard isFreshDatabase || currentVersion >= Self.minimumMigratableSchemaVersion else {
            throw KnowledgeStoreError.invalidData(
                "Knowledge database schema version \(currentVersion) is older than this build migrates (\(Self.minimumMigratableSchemaVersion)). Open it with ForeverLM 0.208.0 (build 288) or earlier first."
            )
        }
        let isMigration = !isFreshDatabase

        var migrationNeedsRollback = false
        if isMigration {
            try exec("BEGIN IMMEDIATE")
            migrationNeedsRollback = true
        }
        defer {
            if migrationNeedsRollback {
                try? exec("ROLLBACK")
            }
        }

        // A version that adds a column to an existing table adds it in its own
        // step below, before anything reads it; a new table comes from the
        // shared `CREATE TABLE IF NOT EXISTS` statements here.

        try createSourceTables()
        try createWalkthroughIdeaAndDirectionTables()
        try createPaperFigureAndHighlightTables()
        try createPreferenceAndSearchTables()
        try createAIUsageTables()
        try createHiddenSourceTables()
        try createReviewAndMemoryTables()
        try createLearningGoalTables()
        try createArtifactTables()
        try createNotebookLinkTables()
        try createScheduleTables()
        try createDayPlanTables()
        try createVideoCitedPaperAndJournalTables()
        try createCourseTables()
        try createSourceRepairQueueTables()
        try createTeamTables()
        try createSourceTypeTables()
        try createSourceProjectionView()
        try createCommonIndexes()
        try createReplicaAndSourceSyncTables()
        if !isMigration {
            try createNotebookChildrenView()
        }
        // A store at 175 or older holds `ck_legacy_bodies`: it takes its new name first, or the
        // creation below would make a second, empty table.
        if isMigration && currentVersion < Self.deadObjectsRemovalSchemaVersion {
            try renameBodySendsTable()
        }
        try createArtifactAndStateSyncTables()

        if isMigration {
            if currentVersion < Self.generation1RemovalSchemaVersion {
                // What the generation-1 tables still
                // told the activation is recorded in its journal, then the
                // seven tables go. Set-based; no application row is read.
                try recordGeneration1HistoryInActivationJournal()
                try dropGeneration1Tables()
            }
            if currentVersion < Self.deadObjectsRemovalSchemaVersion {
                try dropDeadSchemaObjects()
            }
            if currentVersion < Self.boardListsSchemaVersion {
                // A store at 176 made `notebook_tasks` without it; the table's CREATE above was a no-op.
                if try scalarInteger("SELECT COUNT(*) FROM pragma_table_info('notebook_tasks') WHERE name = 'list_id'") == 0 {
                    try exec("ALTER TABLE notebook_tasks ADD COLUMN list_id TEXT")
                }
            }
            if currentVersion < Self.boardChatSchemaVersion {
                if try scalarInteger("SELECT COUNT(*) FROM pragma_table_info('notebook_tasks') WHERE name = 'chat_id'") == 0 {
                    try exec("ALTER TABLE notebook_tasks ADD COLUMN chat_id TEXT")
                }
            }
            if currentVersion < Self.skillsRemovalSchemaVersion {
                try exec("DROP TABLE IF EXISTS skills")
            }
            if currentVersion < Self.highlightFollowUpSchemaVersion {
                if try scalarInteger("SELECT COUNT(*) FROM pragma_table_info('source_highlights') WHERE name = 'follow_up_at'") == 0 {
                    try exec("ALTER TABLE source_highlights ADD COLUMN follow_up_at REAL")
                }
                try exec("UPDATE source_highlights SET follow_up_at = created_at WHERE follow_up_at IS NULL AND color IN ('blue', 'pink')")
            }
            // Preparing the projection catches an older, structurally incompatible
            // table before the version stamp commits. The transaction then rolls
            // back completely instead of leaving a half-migrated store.
            try query("SELECT * FROM source_projection LIMIT 0") { _ in }
        } else {
            // WAL is persistent database configuration, so set it once for a new
            // database rather than issuing journal-mode writes on every launch.
            try exec("PRAGMA journal_mode = WAL")
        }

        // The version is the last write in the migration transaction. A failure
        // anywhere above leaves the old version and schema intact.
        try exec("PRAGMA user_version = \(Self.schemaVersion)")
        if isMigration {
            try exec("COMMIT")
            migrationNeedsRollback = false
            logger.notice(
                "Migrated knowledge database schema from \(currentVersion) to \(Self.schemaVersion)"
            )
        }
    }

    /// Generation 1's tables, dropped by the < 175 step.
    static let generation1Tables = [
        "sync_changes", "sync_metadata", "sync_conflicts", "sync_asset_digests",
        "sync_engine_states", "source_sync_repair_queue", "review_session_sync_repair_queue",
    ]

    /// The < 175 step's first half: what generation 1's tables told the
    /// activation, written into its journal before they go. A store with
    /// generation-1 sync history (a `sync_metadata` row with the server's
    /// system fields, which only an acknowledged save or a delivered record
    /// leaves) and no mode yet activates `deferred`: no build can reach the old
    /// container for its account. A journal an earlier build left at `full`
    /// before its catch-up continues as `deferred`. A store without history
    /// keeps no mode, and its activation decides `fresh`. An activated journal
    /// is never touched.
    func recordGeneration1HistoryInActivationJournal() throws {
        let hasMetadata = try scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sync_metadata')"
        ) == 1
        let hasHistory = try hasMetadata
            && scalarInteger("SELECT EXISTS(SELECT 1 FROM sync_metadata WHERE system_fields IS NOT NULL)") == 1
        if hasHistory {
            try exec("""
                INSERT INTO ck_activation (id, step, mode, started_at)
                VALUES (1, '\(ActivationStep.recordCopy.rawValue)', '\(ActivationMode.deferred.rawValue)', \(Date().timeIntervalSinceReferenceDate))
                ON CONFLICT(id) DO UPDATE SET
                    step = excluded.step, mode = excluded.mode, started_at = excluded.started_at
                WHERE ck_activation.mode IS NULL AND ck_activation.activated_at IS NULL
            """)
        }
        try exec("""
            UPDATE ck_activation SET mode = '\(ActivationMode.deferred.rawValue)'
            WHERE id = 1 AND mode = '\(ActivationMode.full.rawValue)' AND activated_at IS NULL
              AND (step IS NULL OR step IN ('\(ActivationStep.recordCopy.rawValue)', '\(ActivationStep.catchUp.rawValue)'))
        """)
    }

    /// The < 175 step's second half: generation 1's tables go, with their
    /// indexes, and none is left, or the migration rolls back.
    func dropGeneration1Tables() throws {
        for table in Self.generation1Tables {
            try exec("DROP TABLE IF EXISTS \(table)")
        }
        let names = Self.generation1Tables.map { "'\($0)'" }.joined(separator: ", ")
        let left = try scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE name IN (\(names))") ?? 0
        guard left == 0 else {
            throw KnowledgeStoreError.invalidData("Schema 175 left \(left) generation-1 tables.")
        }
    }

    /// The tables the < 176 step drops, with their indexes.
    static let deadSchemaTables = [
        "artifact_collaboration", "journal_watch_excluded_notebooks", "paper_figure_markdown_repair_queue",
        "ck_legacy_snapshot",
    ]

    /// The < 176 step's first half, run before the Artifact tables are created: `ck_legacy_bodies` becomes
    /// `ck_body_sends` with its rows. Only when the old name exists and the new one does not.
    func renameBodySendsTable() throws {
        let hasOld = try scalarInteger("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ck_legacy_bodies')") == 1
        let hasNew = try scalarInteger("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ck_body_sends')") == 1
        if hasOld && !hasNew {
            try exec("ALTER TABLE ck_legacy_bodies RENAME TO ck_body_sends")
        }
    }

    /// The < 176 step's second half: the dead tables and the dead column go, and none is left, or the
    /// migration rolls back. `source_projection` was recreated above and names no dropped column.
    func dropDeadSchemaObjects() throws {
        for table in Self.deadSchemaTables {
            try exec("DROP TABLE IF EXISTS \(table)")
        }
        if try tableColumnNames("videos").contains("legacy_cap_verified_at") {
            try exec("ALTER TABLE videos DROP COLUMN legacy_cap_verified_at")
        }
        let names = (Self.deadSchemaTables + ["ck_legacy_bodies", "idx_artifact_collaboration_zone", "idx_paper_figure_markdown_repair_order"])
            .map { "'\($0)'" }.joined(separator: ", ")
        let left = try scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE name IN (\(names))") ?? 0
        let column: Int64 = try tableColumnNames("videos").contains("legacy_cap_verified_at") ? 1 : 0
        guard left + column == 0 else {
            throw KnowledgeStoreError.invalidData("Schema 176 left \(left + column) dead schema objects.")
        }
    }

    /// Heals `source_projection` when its stored definition drifts from this
    /// build's. A changed view definition otherwise only ever runs for
    /// brand-new databases, so a build that reshaped the view and then read a
    /// new column turned every source query into "no such column" against an
    /// existing store — the whole library rendered as empty while the data sat
    /// intact. The view owns no rows, so it is safe to re-derive at
    /// launch. Replacement is transactional because the app can hold multiple
    /// connections to the same database; readers must continue seeing the old
    /// projection until the new one commits. The common path — stored definition
    /// already matches — stays read-only.
    func reconcileSourceProjectionView() throws {
        let expected = Self.sourceProjectionViewSQL(sourceColumnNames: try tableColumnNames("sources"))

        func storedDefinition() throws -> String? {
            var stored: String?
            try query("SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'source_projection'") { stmt in
                stored = self.string(stmt, 0)
            }
            return stored
        }

        func definitionMatchesExpected(_ stored: String?) -> Bool {
            guard let stored else { return false }
            // SQLite omits whitespace before CREATE when persisting sqlite_master,
            // while Swift multiline strings retain their source indentation.
            // Interior whitespace remains exact so real definition drift is still
            // detected without turning every healthy launch into a schema write.
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !definitionMatchesExpected(try storedDefinition()) else { return }

        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback {
                try? exec("ROLLBACK")
            }
        }

        // Another connection may have completed the same repair while this one
        // waited for the write lock. Recheck under the lock to avoid needless DDL.
        if !definitionMatchesExpected(try storedDefinition()) {
            try exec("DROP VIEW IF EXISTS source_projection")
            #if DEBUG
            afterSourceProjectionDropForTesting?()
            #endif
            try exec(expected)
        }

        try exec("COMMIT")
        needsRollback = false
    }

    /// The exact `source_projection` definition this build expects. Fresh
    /// database creation, migrations, and the launch-time drift check must all
    /// derive the view from this one string, or the drift comparison stops
    /// meaning anything. The defensive NULL projections also let older supported
    /// source tables reach the additive-column migration safely.
    ///
    /// The view promises exactly one row per source, and every caller depends on
    /// it — several key rows by `id` into a dictionary, which traps the process
    /// on a duplicate. `group_members` is keyed `(source_id, group_id)`, so a
    /// source filed into two groups otherwise fans the join out into two rows
    /// and crashed semantic source search mid-answer. Pinning the
    /// join to `MIN(group_id)` restores one row per source and preserves what
    /// first-row-wins callers already saw, because the `(source_id, group_id)`
    /// primary key made SQLite emit the lowest `group_id` first anyway.
    ///
    /// With `readingStates` (schema v2 §3.5.18, §4.3), which every store's view
    /// has, the reading columns come from the member's `reading_states` row on
    /// the source's wire id, never from `sources`, and a hidden or visible mark
    /// counts whether it names the row's own id or its wire id, so a team copy
    /// and the personal copy read one state. Only a test building a library of
    /// an old schema passes `false`.
    static func sourceProjectionViewSQL(sourceColumnNames: Set<String>, readingStates: Bool = true) -> String {
        let sourcePublicURLProjection = sourceColumnNames.contains("public_url")
            ? "s.public_url"
            : "NULL AS public_url"
        let sourceReadingPositionPageProjection = sourceColumnNames.contains("reading_position_page")
            ? "s.reading_position_page"
            : "NULL AS reading_position_page"
        let sourceReadingPositionLocatorProjection = sourceColumnNames.contains("reading_position_locator")
            ? "s.reading_position_locator"
            : "NULL AS reading_position_locator"
        let sourceReadAtProjection = sourceColumnNames.contains("read_at")
            ? "s.read_at"
            : "NULL AS read_at"
        let sourcePluginLabelProjection = sourceColumnNames.contains("connector_label")
            ? "s.connector_label"
            : "NULL AS connector_label"
        let sourceTeamIDProjection = sourceColumnNames.contains("team_id")
            ? "s.team_id"
            : "NULL AS team_id"
        // Generation 2: the member's reading state on the wire id, and marks on either id.
        let readingColumns = (readingStates
            ? [
                "rs.position AS reading_position_page",
                ReadingLocatorCodec.macLocatorSQL("rs.locator_json") + " AS reading_position_locator",
                "rs.read_at AS read_at",
            ]
            : [sourceReadingPositionPageProjection, sourceReadingPositionLocatorProjection, sourceReadAtProjection]
        ).joined(separator: ",\n        ")
        func marked(_ table: String) -> String {
            "EXISTS (SELECT 1 FROM \(table) mark WHERE mark.source_id IN (s.id, s.wire_key))"
        }
        let hiddenSource = readingStates ? marked("hidden_sources") : "hs.source_id IS NOT NULL"
        let hiddenEpisode = readingStates ? marked("hidden_podcast_episodes") : "hpe.source_id IS NOT NULL"
        let episodeNotOverridden = readingStates ? "NOT " + marked("visible_podcast_episode_overrides") : "vpeo.source_id IS NULL"
        let videoNotOverridden = readingStates ? "NOT " + marked("visible_youtube_video_overrides") : "vyvo.source_id IS NULL"
        let videoOverrideJoin = readingStates ? "" : "\n    LEFT JOIN visible_youtube_video_overrides vyvo ON vyvo.source_id = s.id"
        let markJoins = (readingStates
            ? ["LEFT JOIN reading_states rs ON rs.wire_id = s.wire_key"]
            : [
                "LEFT JOIN hidden_sources hs ON hs.source_id = s.id",
                "LEFT JOIN hidden_podcast_episodes hpe ON hpe.source_id = s.id",
                "LEFT JOIN visible_podcast_episode_overrides vpeo ON vpeo.source_id = s.id",
            ]
        ).map { "\n    " + $0 }.joined()

        return """
            CREATE VIEW source_projection AS
            SELECT
                s.id,
                s.date_added,
                s.state,
                s.error_message,
                s.source_type,
                s.existing_card_count,
                s.status,
                s.archived_at,
                \(sourcePublicURLProjection),
                \(readingColumns),
                CASE
                    WHEN \(hiddenSource) THEN 1
                    WHEN \(hiddenEpisode) THEN 1
                    WHEN \(episodeNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_podcast_shows hps
                        WHERE hps.show_name = pod.domain
                           OR hps.show_name = pod.show_name
                    ) THEN 1
                    WHEN \(videoNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_youtube_channels hyc
                        WHERE hyc.channel_name = v.domain
                    ) THEN 1
                    ELSE 0
                END AS is_hidden,
                CASE
                    WHEN \(episodeNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_podcast_shows hps
                        WHERE hps.show_name = pod.domain
                           OR hps.show_name = pod.show_name
                    ) THEN 1
                    WHEN \(videoNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_youtube_channels hyc
                        WHERE hyc.channel_name = v.domain
                    ) THEN 1
                    ELSE 0
                END AS is_collection_hidden,
                COALESCE(a.url, p.url, pod.url, bs.url, cs.url, ms.url, v.url, xp.url) AS url,
                COALESCE(a.local_file_path, p.local_file_path, pod.local_file_path, bs.local_file_path, cs.local_file_path, ms.local_file_path, v.local_file_path, xp.local_file_path) AS local_file_path,
                COALESCE(a.normalized_url, p.normalized_url, pod.normalized_url, bs.normalized_url, cs.normalized_url, ms.normalized_url, v.normalized_url, xp.normalized_url) AS normalized_url,
                COALESCE(
                    a.title,
                    p.title,
                    pod.title,
                    bs.title,
                    cs.title,
                    ms.title,
                    v.title,
                    CASE
                        WHEN xp.title IS NOT NULL AND xp.title != '' THEN xp.title
                        WHEN xp.post_text IS NOT NULL AND xp.post_text != '' THEN substr(replace(replace(xp.post_text, char(10), ' '), char(13), ' '), 1, 80)
                        ELSE xp.url
                    END
                ) AS title,
                COALESCE(a.domain, p.domain, pod.domain, bs.domain, cs.domain, ms.domain, v.domain, xp.domain, '') AS domain,
                COALESCE(a.discovery_origin, p.discovery_origin, pod.discovery_origin, bs.discovery_origin, cs.discovery_origin, ms.discovery_origin, v.discovery_origin, xp.discovery_origin) AS discovery_origin,
                COALESCE(a.word_count, p.word_count, pod.word_count, bs.word_count, cs.word_count, ms.word_count, v.word_count, xp.word_count) AS word_count,
                COALESCE(a.artwork_url, p.artwork_url, pod.artwork_url, bs.artwork_url, cs.artwork_url, ms.artwork_url, v.artwork_url, xp.artwork_url) AS artwork_url,
                COALESCE(a.author, p.author, ms.presenter, xp.author) AS author,
                p.journal,
                p.published_year,
                p.is_paywalled,
                p.doi,
                p.published_doi,
                p.paper_ingestion_method,
                p.paywall_suspicion,
                pod.web_page_url AS podcast_web_page_url,
                v.liked_at,
                v.video_published_at,
                gm.group_id AS parent_group,
                COALESCE(book_meta.title, course_meta.title, video_playlist_meta.title, meeting_meta.title) AS parent_group_title,
                gm.sort_index AS group_sort_index,
                gm.lecture_group_id,
                bs.page_start AS book_page_start,
                bs.page_count AS book_page_count,
                \(sourcePluginLabelProjection),
                \(sourceTeamIDProjection)
            FROM sources s
            LEFT JOIN articles a ON a.source_id = s.id
            LEFT JOIN papers p ON p.source_id = s.id
            LEFT JOIN podcasts pod ON pod.source_id = s.id
            LEFT JOIN book_sources bs ON bs.source_id = s.id
            LEFT JOIN course_sources cs ON cs.source_id = s.id
            LEFT JOIN meeting_sources ms ON ms.source_id = s.id
            LEFT JOIN videos v ON v.source_id = s.id
            LEFT JOIN x_posts xp ON xp.source_id = s.id
            LEFT JOIN group_members gm
                ON gm.source_id = s.id
               AND gm.group_id = (
                   SELECT MIN(g2.group_id) FROM group_members g2 WHERE g2.source_id = s.id
               )\(videoOverrideJoin)
            LEFT JOIN books book_meta ON book_meta.id = gm.group_id
            LEFT JOIN courses course_meta ON course_meta.id = gm.group_id
            LEFT JOIN video_playlists video_playlist_meta ON video_playlist_meta.id = gm.group_id
            LEFT JOIN meeting_groups meeting_meta ON meeting_meta.id = gm.group_id\(markJoins)
        """
    }
}
