import Foundation
import SQLite3
import OSLog
import CloudKit

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
    // Each version's change, from 1 to 174, is in the history of this file: the steps that brought a
    // store up to 174 were deleted when 174 became the oldest store this build migrates (2026-11-09,
    // `minimumMigratableSchemaVersion`).
    //
    // 175: generation-1 sync is gone (2026-11-09). Its seven tables
    // (`sync_changes`, `sync_metadata`, `sync_conflicts`, `sync_asset_digests`,
    // `sync_engine_states`, `source_sync_repair_queue`,
    // `review_session_sync_repair_queue`) are dropped, and a fresh store never
    // makes them. On a store at 174 the < 175 step first records in
    // `ck_activation` what the last of them told the activation: a store with generation-1 sync history
    // and no mode yet activates `deferred`, and an unactivated `full` journal
    // continues as `deferred`. Nothing else is read from them; `card_meta` and
    // `card_reviews` are not theirs and stay.
    //
    // 176: tables and a column nothing reads or writes any more are gone (2026-11-10), and a fresh store
    // never makes them: `artifact_collaboration` (an Artifact's sharing is a Doc space now),
    // `journal_watch_excluded_notebooks`, `paper_figure_markdown_repair_queue`, `ck_legacy_snapshot` (the old
    // catch-up's leftovers) and `videos.legacy_cap_verified_at`. `ck_legacy_bodies`, which is still
    // written (a Doc body's acknowledged upload), is renamed `ck_body_sends`, rows and all.
    static let schemaVersion: Int32 = 176
    static let generation1RemovalSchemaVersion: Int32 = 175
    static let deadObjectsRemovalSchemaVersion: Int32 = 176
    /// The oldest store this build migrates: schema 174, which every build from 2026-11-04 to build 288
    /// wrote. An older store is refused (product owner, 2026-11: old versions are no longer supported),
    /// so the steps that brought a store up to 174 are gone.
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

        // A rule for every CREATE TABLE below: no comma inside a `--` comment
        // that sits between a table's second-to-last column and its last one.
        // SQLite's `ALTER TABLE … DROP COLUMN` of the last column removes the
        // text from the nearest preceding comma to the column's end by raw
        // character scan, so a comma inside such a comment leaves the closing
        // paren commented out ("incomplete input", SQLite 3.51). The migration
        // fixtures drop columns exactly this way to rebuild released shapes;
        // `sources.team_id`, `global_artifacts.archived_at` and
        // `review_sessions.loaded_source_ids` each hit it on 2026-09-13.
        try exec("""
            CREATE TABLE IF NOT EXISTS sources (
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
                read_at REAL,
                -- How much of a memory review this source gets: quick,
                -- standard or deep (schema 89). NULL means the default.
                review_depth TEXT,
                -- The team whose library this source is a copy in (schema 96).
                -- NULL is the learner's own library. A team copy has a
                -- team-scoped id so the same paper shared by two members is
                -- one team row and never collides with anyone's own copy.
                team_id TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_team ON sources(team_id, status)")

        try exec("""
            CREATE TABLE IF NOT EXISTS source_content (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                content TEXT NOT NULL
            )
        """)

        // Listen consumes a second, source-hash-bound derivative instead of
        // preparing long documents after the user presses Play. Its queue is
        // local-only resumable work; the completed derivative syncs with Source.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_listenable_content (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                content TEXT NOT NULL,
                generator_version INTEGER NOT NULL,
                preparation_signature TEXT,
                prepared_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS source_listenable_content_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                source_sha256 TEXT,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_source_listenable_content_queue_order
            ON source_listenable_content_queue(enqueued_at, source_id)
        """)

        // The original extraction is retained separately from the canonical,
        // cleaned source_content derivative. Consumers never query this table;
        // it exists for auditability and versioned reprocessing only.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_content_preparations (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                raw_content TEXT NOT NULL,
                raw_sha256 TEXT NOT NULL,
                clean_sha256 TEXT,
                cleaner_version INTEGER NOT NULL DEFAULT 0,
                prepared_at REAL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS article_content_preparations (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                raw_content TEXT NOT NULL,
                raw_sha256 TEXT NOT NULL,
                clean_sha256 TEXT,
                cleaner_version INTEGER NOT NULL DEFAULT 0,
                prepared_at REAL
            )
        """)

        // Original readable transcript plus version/hash proof for the
        // deletion-only podcast ad cleanup. This derivative metadata syncs with
        // Source; the queue below is local resumable work.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_preparations (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                input_content TEXT NOT NULL,
                input_sha256 TEXT NOT NULL,
                clean_sha256 TEXT NOT NULL,
                cleaner_version INTEGER NOT NULL DEFAULT 0,
                prepared_at REAL
            )
        """)
        // A row owes the ad pass, or (schema 172) the whole formatting pass
        // for a transcript saved raw: `format_input_sha256` names that raw
        // text and `learner_asked` puts an episode the learner asked for first.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_cleanup_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                source_sha256 TEXT,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                format_input_sha256 TEXT,
                learner_asked INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_podcast_transcript_cleanup_queue_order
            ON podcast_transcript_cleanup_queue(attempt_count, enqueued_at, source_id)
        """)

        // Local-only completeness audit (`PodcastTranscriptDetruncationService`).
        // Every podcast transcript the retired 50,000-character import cap may
        // have cut is measured once against its episode's TTML text, stored or
        // fetched once from Apple: where the transcript stops in that text says
        // whether the cap cut it (`PodcastTranscriptCompleteness`), and only a
        // cut one is rewritten. Bookkeeping is resumable derived state; a
        // restored transcript syncs as part of Source.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_detruncation_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                -- When a failed attempt may be tried again (schema 167)
                retry_after REAL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_podcast_transcript_detruncation_queue_order
            ON podcast_transcript_detruncation_queue(attempt_count, enqueued_at, source_id)
        """)
        // What the audit found for each episode (schema 167): `hydrated` (made
        // from a whole extraction of the TTML), `complete`, `restored`,
        // `unplaced` or `no_transcript`, and the TTML it measured. An episode
        // with a row here is not audited again, so the ad pass's deletions
        // after a restore never send it back.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_audits (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                ttml_sha256 TEXT,
                outcome TEXT NOT NULL,
                audited_at REAL NOT NULL
            )
        """)

        // Local-only durable work queue. The canonical result itself syncs as
        // part of Source; queue bookkeeping is resumable derived state and must
        // not become another cross-device identity surface.
        try exec("""
            CREATE TABLE IF NOT EXISTS canonical_content_cleanup_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                -- Hash of the text the queued attempts were made against, so
                -- re-saving a source's metadata cannot revive an exhausted
                -- attempt budget while re-extracting its text does.
                source_sha256 TEXT
            )
        """)

        // Local-only, one-time (schema 134): preparations whose stored raw text
        // may be shorter than the hash beside it says. See
        // `auditCanonicalContentIntegrity`; the queue empties once per library.
        try exec("""
            CREATE TABLE IF NOT EXISTS canonical_content_integrity_audit_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Local-only (schema 135): a bulk re-queue into a paid background
        // queue waiting for the learner's decision, and the sources it holds.
        // See `holdingBulkRequeue`. Each Mac drains its own queues, so each
        // Mac asks; nothing here syncs.
        try exec("""
            CREATE TABLE IF NOT EXISTS background_ai_bulk_jobs (
                id TEXT PRIMARY KEY,
                queue TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at REAL NOT NULL,
                -- pending | run_all | run_affected | skip | released
                status TEXT NOT NULL DEFAULT 'pending',
                decided_at REAL
            )
        """)
        try exec("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_background_ai_bulk_jobs_pending
            ON background_ai_bulk_jobs(queue) WHERE status = 'pending'
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS background_ai_bulk_job_sources (
                job_id TEXT NOT NULL REFERENCES background_ai_bulk_jobs(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                -- 1 or 0 when the change can say whether it reaches this
                -- source; NULL when it cannot.
                affected INTEGER,
                held_at REAL NOT NULL,
                PRIMARY KEY (job_id, source_id)
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_background_ai_bulk_job_sources_source
            ON background_ai_bulk_job_sources(source_id)
        """)

        // Local-only durable work queue for the one-time chrome refilter of
        // archives written before ArticleChromeFilter existed. The result is the
        // article's own reader document, which syncs as a Source asset; the
        // queue itself is resumable derived state and stays on this device.
        try exec("""
            CREATE TABLE IF NOT EXISTS article_chrome_refilter_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)

        // Per-member, so no foreign key to the source since schema 154.
        try createPerMemberTable(Self.sourceUnderstandingTable)

        // Identity, staleness, and the source relationship live here; the prose
        // itself is a markdown file the learner can open and edit.
        // body_sha256 is what the model last wrote, so a file that
        // no longer matches is a hand edit to read back rather than overwrite.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_review_guides (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                guide TEXT NOT NULL,
                generator_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            )
        """)

        // Local-only resumable work. The resulting guide syncs in the encrypted
        // Source payload; attempts and errors are device-local derived state.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_review_guide_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)

        // A paper's guided walkthrough (schema 122, walkthrough-design.md): the
        // steps the Reader follows beside the PDF, as one JSON document keyed by
        // the text they were written against. One row a paper; it syncs inside
        // the encrypted Source payload like the review guide above, and goes
        // with the source when the source is deleted.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_walkthroughs (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                walkthrough_json TEXT NOT NULL,
                walkthrough_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            )
        """)

        // A saved animation's guided walkthrough (schema 124): the steps the chat
        // plays beside the animation, each pinning the page to one of its own
        // steps. One row an animation, keyed by the artifact; the fingerprint
        // is the animation's address, so a re-addressed animation reads as
        // stale. Syncs inside the encrypted Artifact payload and goes with
        // the artifact when it is deleted.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_walkthroughs (
                artifact_id TEXT PRIMARY KEY REFERENCES global_artifacts(id) ON DELETE CASCADE,
                artifact_sha256 TEXT NOT NULL,
                walkthrough_json TEXT NOT NULL,
                walkthrough_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            )
        """)

        // The Ideas tab (schema 126): a thought the learner jotted down, and
        // the sources, chats, Docs, Goals and Notebooks it is linked to. The
        // links carry no foreign keys — a link is to a record's id whatever
        // table holds it, and CloudKit may deliver the Idea before the record
        // — so a row resolves each link against the library and a record
        // that is gone reads as no chip. Both travel in one `Idea` CloudKit
        // record (docs/ideas-design.md).
        try exec("""
            CREATE TABLE IF NOT EXISTS ideas (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ideas_status_created ON ideas(status, created_at DESC)")
        try exec("""
            CREATE TABLE IF NOT EXISTS idea_links (
                idea_id TEXT NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                target_id TEXT NOT NULL,
                added_at REAL NOT NULL,
                PRIMARY KEY (idea_id, kind, target_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_idea_links_target ON idea_links(kind, target_id)")

        // Sensemaking (schema 165, docs/sensemaking-design.md): what ForeverLM
        // wrote to help the learner see a topic, a source and a card at more
        // than one level of abstraction. All three are derived, rewritable and
        // local to this Mac; none is a record of the learner's.
        // An Atlas: a topic laid out as concepts, its whole body one JSON
        // payload (`Atlas`), read and written whole.
        try exec("""
            CREATE TABLE IF NOT EXISTS atlases (
                id TEXT PRIMARY KEY,
                topic TEXT NOT NULL,
                notebook_id TEXT,
                scope_json TEXT NOT NULL DEFAULT '{}',
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_atlases_updated ON atlases(updated_at DESC)")
        // A source's reading levels for the Reader, written from the text
        // whose SHA-256 is `content_sha256`; a change of text makes them stale.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_levels (
                source_id TEXT PRIMARY KEY,
                content_sha256 TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                model TEXT,
                created_at REAL NOT NULL
            )
        """)
        // A source card's written faces on the Canvas: far (a few words), mid
        // (a sentence) and near (two or three lines), from the card's text
        // whose fingerprint is `fingerprint`.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_faces (
                source_id TEXT PRIMARY KEY,
                fingerprint TEXT NOT NULL,
                far TEXT NOT NULL,
                mid TEXT NOT NULL,
                near_json TEXT NOT NULL DEFAULT '[]',
                model TEXT,
                created_at REAL NOT NULL
            )
        """)

        // Directions (schema 147): what a search proposed toward a Goal,
        // Notebook or Idea, and the learner's answer. The home carries no
        // foreign key — it is a `learning_goals` or `ideas` id, and CloudKit
        // may deliver the Direction before its home — so a Direction whose
        // home is gone is shown nowhere; deleting a Goal or an Idea deletes
        // its Directions in the same transaction. Evidence is a JSON array in
        // the row: it is only ever read and written with its Direction. One
        // `ResearchDirection` CloudKit record per row
        // (docs/directions-design.md).
        try exec("""
            CREATE TABLE IF NOT EXISTS research_directions (
                id TEXT PRIMARY KEY,
                home_kind TEXT NOT NULL,
                home_id TEXT NOT NULL,
                title TEXT NOT NULL,
                rationale TEXT NOT NULL DEFAULT '',
                angle TEXT NOT NULL DEFAULT 'other',
                evidence_json TEXT NOT NULL DEFAULT '[]',
                objection TEXT,
                next_step TEXT,
                status TEXT NOT NULL DEFAULT 'proposed',
                verdict_reason TEXT,
                chat_session_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                decided_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_research_directions_home ON research_directions(home_id, status)")

        // The learner's chat skills (schema 136): a `/` name, the one
        // description the chat reads to decide when a skill applies, and the
        // instructions it reads when it does. The name is not UNIQUE: two
        // Macs can each write one of the same name, and an inbound record
        // must not fail on the other's row; local writes refuse a taken name
        // and a lookup takes the newest edit. One `Skill` CloudKit record a
        // row, private zone only.
        try exec("""
            CREATE TABLE IF NOT EXISTS skills (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                instructions TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_skills_name ON skills(name, updated_at DESC)")

        // A walk's progress (schema 133): the card the learner is on, the
        // steps dealt, the questions' outcomes and the chat questions went
        // to, one row a walk keyed by its source or animation. Per learner,
        // never in a team; one `WalkthroughProgress` CloudKit record a row.
        try exec("""
            CREATE TABLE IF NOT EXISTS walkthrough_progress (
                subject_id TEXT PRIMARY KEY,
                progress_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        // The day close (schema 127): what this device has already folded
        // into understanding documents, so the pass that runs at shutdown, at
        // the evening hour and again before the morning's review can each
        // pick up only what is new. `watermark` is the instant everything
        // before it was consolidated; a chat row records the last turn its
        // consolidation read, because a chat may go on the next day. Local
        // derived state: the documents it produces sync as files, the
        // summaries it writes ride the ReviewSession record, and another Mac
        // running the same pass rewrites rather than duplicates.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_day_close_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                watermark REAL NOT NULL,
                last_run_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS chat_consolidations (
                session_id TEXT PRIMARY KEY REFERENCES review_sessions(id) ON DELETE CASCADE,
                through_sequence INTEGER NOT NULL,
                consolidated_at REAL NOT NULL,
                source_count INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Regenerable visual index: which page carries which labelled figure, and
        // what a vision model made of it. Every column is portable and projects
        // through the encrypted Source sync payload.
        //
        // There is no image column. Until schema 75 each figure also owned a
        // rendered page JPEG on disk, which was pure duplication — the pixels
        // were already in the PDF a page index away — and cost this library
        // 4.9 GB across 9,030 files. Clients render the page on demand instead.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figures (
                figure_id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                figure_label TEXT NOT NULL,
                page_index INTEGER NOT NULL CHECK(page_index >= 0),
                caption TEXT NOT NULL,
                analysis_json TEXT,
                UNIQUE(source_id, figure_label, page_index)
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_index_state (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                pdf_path TEXT NOT NULL,
                index_version INTEGER NOT NULL,
                page_count INTEGER NOT NULL,
                indexed_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_index_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                pdf_path TEXT NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_figures_source_page
            ON paper_figures(source_id, page_index)
        """)

        // One-time removal of the rendered page JPEGs that schema 75 stopped
        // producing. Deliberately local and unsynced: the files are this Mac's,
        // so each device has to run its own sweep — a synced "done" flag would
        // let the second Mac skip a library it still holds gigabytes of.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_image_sweep_state (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                enqueued_at REAL NOT NULL,
                completed_at REAL,
                removed_directory_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)

        // User-authored highlights and the notes written on them are durable
        // source annotations. The table predates the reader UI that writes it,
        // so a database upgraded by one of those builds is already the right
        // shape apart from the anchor columns the column migration below adds.
        //
        // `page_index`/`quads_json` are the PDF fast path: PDFKit paints those
        // quads without re-reading the document. Every reader — web, EPUB,
        // transcript, PDF — additionally stores the portable text-quote anchor
        // (`anchor_prefix`/`anchor_suffix`/`anchor_offset`), which is what
        // survives a re-fetch or a reflow. Non-PDF rows park at page 0 with no
        // quads. A highlight is the learner's own, so since schema 154 it has
        // no foreign key to its source.
        try createPerMemberTable(Self.sourceHighlightsTable)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_figure_index_queue_order
            ON paper_figure_index_queue(attempt_count, enqueued_at)
        """)

        try exec("CREATE INDEX IF NOT EXISTS idx_sources_status ON sources(status)")

        try exec("""
            CREATE TABLE IF NOT EXISTS chat_context (
                key TEXT PRIMARY KEY,
                source_ids TEXT NOT NULL DEFAULT '[]',
                last_updated REAL NOT NULL
            )
        """)

        // Account-level user preferences (see SyncedPreferenceKeys for which keys
        // qualify). One row — and so one CloudKit record — per preference key,
        // deliberately not a single blob row like chat_context above: conflict
        // resolution is row-level last-write-wins over an opaque payload, so a
        // shared row would mean one Mac changing the theme and the other changing
        // the font size silently loses one of the two edits.
        //
        // `value` holds an XML property list, not JSON. UserDefaults distinguishes
        // Bool from Int (`object(forKey:) as? Bool` returns nil for a plain
        // NSNumber), and JSON does not — round-tripping a Bool through JSON would
        // silently flip several settings to their defaults.
        try exec("""
            CREATE TABLE IF NOT EXISTS user_preferences (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)


        try exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT 'default',
                vector BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (entity_type, entity_id, model)
            )
        """)

        // Full-text index over source text, ranked by BM25. This is the half of search
        // the embedding cannot do: a pooled 512-dim vector dilutes a rare token like a
        // gene symbol until it carries no signal (swapping GDF15 for GFRAL moves the
        // vector 0.6%), so exact/rare terms — gene names, acronyms, proper nouns — are
        // retrieved lexically and fused with the semantic hits. Inverse document
        // frequency does the opposite of pooling: the rarer the term, the stronger it
        // scores, which is exactly the behaviour an exact match needs.
        //
        // Local derived data, like `embeddings`: never synced to CloudKit, rebuilt on
        // each device by `SourceEmbeddingIndexer`. That is what lets the indexer feed it
        // text extracted on the fly from a paper's PDF without writing that text back
        // into `source_content` (which would re-push every paper as a new CloudKit asset).
        //
        // Tokenizer: `unicode61` keeps "GDF15" as a single token. Porter stemming is
        // deliberately NOT used — it mangles symbol-like tokens. `remove_diacritics 2`
        // folds accents so "Müller" matches "Muller".
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS source_fts USING fts5(
                source_id UNINDEXED,
                title,
                author,
                body,
                tokenize = "unicode61 remove_diacritics 2"
            )
        """)

        // Which version of the index-time analysis wrote each full-text row.
        //
        // Separate from `source_index_state` because the two go stale for different
        // reasons and cost different amounts to repair. That table tracks the *text* a
        // source was indexed from, and clearing it re-embeds — model time, and money.
        // This one tracks how that text was analyzed, and a raised
        // `SourceSearchEngine.indexAnalyzerVersion` needs nothing but the full-text rows
        // rewritten. Keeping them apart is what lets the analyzer improve without
        // re-embedding the library.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_fts_state (
                source_id TEXT PRIMARY KEY,
                analyzer_version INTEGER NOT NULL,
                written_at REAL NOT NULL
            )
        """)

        // Where each source's full-text row is, by rowid (schema 168).
        try createSourceFTSRowTables()

        // The PDF books still split into chapter files (schema 169).
        try createBookFileMergeQueue()

        // The books added on this Mac whose chapters are still to be found (schema 171).
        try createBookImportFinishQueue()

        // The files books were added from on this Mac, by sha256 (schema 173).
        try createBookFileDigests()

        // Each paper's reference list, and the queue of papers owed a read (schema 174).
        try createPaperReferenceTables()

        // What the indexer has already done, and for which version of a source's text.
        //
        // "Has an embedding" is not a sufficient completion test: a source indexed while
        // it was still title-only (a podcast before its transcript arrives, a paper before
        // its PDF is attached) would look done forever and never pick up its real content.
        // So the indexer records a fingerprint of the text it actually indexed — the stored
        // content length and the local file path — and re-indexes whenever that changes.
        // The model id is part of the key, so switching embedding models retires every row.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_index_state (
                source_id TEXT NOT NULL,
                model TEXT NOT NULL,
                content_length INTEGER NOT NULL,
                file_path TEXT NOT NULL DEFAULT '',
                indexed_at REAL NOT NULL,
                PRIMARY KEY (source_id, model)
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS ai_usage_events (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                operation TEXT NOT NULL,
                task TEXT, -- feature that made the call (AIUsageEvent.task); NULL on rows from before the column
                session_id TEXT,
                activity_id TEXT,
                subject_id TEXT,
                subject_type TEXT,
                subject_title TEXT,
                created_at REAL NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cached_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER,
                reasoning_tokens INTEGER,
                audio_input_tokens INTEGER,
                audio_output_tokens INTEGER,
                image_count INTEGER,
                total_tokens INTEGER,
                character_count INTEGER,
                duration_seconds REAL,
                provider_reported_cost REAL,
                estimated_cost REAL,
                currency TEXT,
                raw_usage_json TEXT,
                client_platform TEXT,
                server_ledger_id INTEGER,
                server_request_id TEXT,
                latency_ms INTEGER,
                -- 1 when the learner's own router key paid for this call
                -- and it went straight to that router. Such a call never
                -- reached the proxy so no server row will stand in for it
                -- and it stays visible on its own merit.
                own_key INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_usage_events_created ON ai_usage_events(created_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_usage_events_model ON ai_usage_events(provider, model)")
        // Chat/review session attribution (AIUsageAttribution). Partial index:
        // background work leaves session_id NULL, so only attributed rows —
        // a small fraction of the ledger — pay for the per-session cost sum.
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_usage_events_session ON ai_usage_events(session_id) WHERE session_id IS NOT NULL")
        try exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_usage_events_server_ledger ON ai_usage_events(server_ledger_id) WHERE server_ledger_id IS NOT NULL")

        // Exact one-shot task results, keyed by a digest of model + complete
        // request. Prompts are never persisted. Reads enforce the TTL, so a
        // repeated background event reuses completed work without inference.
        try exec("""
            CREATE TABLE IF NOT EXISTS ai_response_cache (
                request_key TEXT PRIMARY KEY,
                response TEXT NOT NULL,
                created_at REAL NOT NULL
            )
        """)

        // Local cursor for the authoritative managed-proxy ledger mirror. It is
        // local-only accounting state, not user content and not CloudKit synced.
        try exec("""
            CREATE TABLE IF NOT EXISTS managed_ai_usage_sync_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                last_ledger_id INTEGER NOT NULL DEFAULT 0
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS dismissed_sources (
                url TEXT PRIMARY KEY,
                title TEXT,
                dismissed_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_podcast_shows (
                show_name TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_youtube_channels (
                channel_name TEXT PRIMARY KEY COLLATE NOCASE,
                hidden_at REAL NOT NULL
            )
        """)

        // The hidden and visible marks are the learner's own; since schema 154
        // none has a foreign key to its source.
        try createPerMemberTable(Self.hiddenSourcesTable)

        try exec("""
            CREATE TABLE IF NOT EXISTS pending_hidden_sources (
                source_id TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try createPerMemberTable(Self.hiddenPodcastEpisodesTable)

        // The docs, sites and chats the learner hid (schema 114), synced as
        // HiddenArtifact and HiddenReviewSession records in the private zone.
        // No foreign key on purpose: a hide can arrive from CloudKit before
        // the record it is about, and the row waits for it; the record's own
        // delete removes the row.
        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_artifacts (
                artifact_id TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_review_sessions (
                session_id TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try createPerMemberTable(Self.visiblePodcastEpisodeOverridesTable)
        try createPerMemberTable(Self.visibleYouTubeVideoOverridesTable)

        try exec("""
            CREATE TABLE IF NOT EXISTS review_sessions (
                id TEXT PRIMARY KEY,
                topic TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                status TEXT NOT NULL DEFAULT 'active',
                overall_score REAL,
                summary TEXT,
                source_ids TEXT NOT NULL DEFAULT '[]',
                card_ids TEXT NOT NULL DEFAULT '[]',
                exchange_count INTEGER NOT NULL DEFAULT 0,
                model_provider TEXT,
                model_id TEXT,
                -- Links the session back to the Learning Companion goal it belongs to.
                goal_id TEXT,
                -- chat / review / memory (schema 89). NULL on older rows, whose
                -- kind is read from the id prefix instead.
                kind TEXT,
                -- A memory review's stable tutor briefing: the day's plan, its
                -- ideas and material. Syncs inside the session record so a
                -- prepared chat opens the same review on either device.
                briefing TEXT,
                -- The team this chat was shared into as a read-only transcript
                -- snapshot (schema 96). NULL is a live chat of the learner's own.
                team_id TEXT,
                -- Which of source_ids the model had actually read when the chat
                -- was last open (schema 104) as a JSON list so a reopened chat
                -- holds what it held instead of coming back catalog-only. Local
                -- to this Mac and never synced: it describes this process's
                -- prompt rather than the conversation. NULL is a chat recorded
                -- before the column; its loaded set is read off the transcript's
                -- citations on resume. '[]' is a chat that had read nothing.
                -- Schema 112's hidden_at column is retired (114): a hidden
                -- chat is a hidden_review_sessions row and a store that has
                -- the column keeps it unread and unwritten.
                loaded_source_ids TEXT,
                -- The reasoning effort and output speed the chat's last reply
                -- was asked for (schema 149) beside the model it names so a
                -- reopened chat goes on with the whole route it was held in.
                -- NULL is the model's own default effort and standard speed
                -- and every chat recorded before the columns.
                model_effort TEXT,
                model_speed TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL,
                -- The Chat record's kind; whether an import's later appends
                -- mark sources reviewed; and its context mode (158). NULL until
                -- the generation-2 activation derives them and then written by
                -- every generation-2 creation site. (No commas in comments
                -- before a dropped column: SQLite 3.51 and older mishandle them.)
                chat_kind TEXT,
                marks_reviewed INTEGER,
                context_mode TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_review_sessions_team ON review_sessions(team_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS review_exchanges (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
                sequence_number INTEGER NOT NULL,
                question TEXT NOT NULL,
                user_answer TEXT,
                evaluation TEXT,
                score REAL,
                source_refs TEXT DEFAULT '[]',
                knowledge_note TEXT,
                answered_at REAL,
                context_content TEXT,
                -- Memory review grading (schema 89): which ideas came back in
                -- this answer, whether the question was fit to grade, the
                -- operation it asked for, and the learner's steer afterwards.
                idea_coverage TEXT,
                question_verdict TEXT,
                operation TEXT,
                steer TEXT,
                -- The learner's thumb on one of this exchange's tutor turns
                -- (schema 93): liked/disliked, their reason, which field they
                -- rated, and the unit's clock for sync.
                rating TEXT,
                rating_reason TEXT,
                rating_field TEXT,
                rated_at REAL,
                -- The Exchange record's passage anchor and the sources its
                -- reply cited (158), JSON, as another device sent them.
                anchor_json TEXT,
                cited_source_ids TEXT,
                UNIQUE(session_id, sequence_number)
            )
        """)

        // Junction table: many-to-many between review sessions and sources
        try exec("""
            CREATE TABLE IF NOT EXISTS review_session_sources (
                session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                PRIMARY KEY (session_id, source_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_fss_source ON review_session_sources(source_id)")

        // The rolling summary of a chat's older turns (schema 88). Before it
        // was stored, every reopen of a long chat rebuilt the summary from
        // scratch in one oversized model call. Local-only and regenerable —
        // the exchanges it summarises are what syncs — so it is never
        // published to CloudKit and carries no sync metadata. The cursor is
        // an (exchange, field) pair, not a message index; see
        // `ReviewSessionHistoryDigest`.
        try exec("""
            CREATE TABLE IF NOT EXISTS review_session_history_digests (
                session_id TEXT PRIMARY KEY REFERENCES review_sessions(id) ON DELETE CASCADE,
                digest TEXT NOT NULL,
                through_exchange_id TEXT NOT NULL,
                through_field TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        // The ideas a consumed source asks to be remembered (schema 89): the
        // unit of memory review. Extracted once per source text, synced as
        // their own `SourceIdea` record, retired rather than deleted when the
        // text changes. source_id has no FK for the reason memory_item_sources
        // gives: CloudKit may deliver an idea before its Source, and the id is
        // remapped by portable identity on arrival.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_ideas (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                statement TEXT NOT NULL,
                recall_note TEXT NOT NULL,
                anchors_json TEXT NOT NULL DEFAULT '[]',
                wanted INTEGER NOT NULL DEFAULT 0,
                origin_session_id TEXT,
                content_hash TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                sort_index INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_source_ideas_source
            ON source_ideas(source_id, status, sort_index)
        """)

        // Time spent on the day's memory review (schema 91): one row per device
        // per day, summed by `MemoryReviewProgress` into today's progress and
        // the streak. A device only writes its own row, so two devices working
        // the same day add up instead of racing. Synced as `MemoryReviewActivity`.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_review_activity (
                id TEXT PRIMARY KEY,
                day TEXT NOT NULL,
                device_id TEXT NOT NULL,
                active_seconds REAL NOT NULL DEFAULT 0,
                goal_seconds REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_memory_review_activity_day
            ON memory_review_activity(day)
        """)

        // AI-native memory targets. These are source-grounded concepts rather
        // than static flashcards: the tutor generates a fresh prompt from the
        // target, rubric, learner context, and one or more anchors at review time.
        // goal_id intentionally has no FK because CloudKit may deliver the item
        // before its Notebook record.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_items (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                target TEXT NOT NULL,
                rubric_json TEXT NOT NULL,
                learner_context TEXT,
                goal_id TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                -- The idea this target is a weak spot of (schema 89). NULL for
                -- the items the external assistant created before ideas existed.
                idea_id TEXT
            )
        """)

        // Anchors travel inside their parent MemoryItem CloudKit record. source_id
        // has no FK because source IDs are remapped by portable identity on arrival
        // and the Source record may be delivered in a later batch.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_item_sources (
                id TEXT PRIMARY KEY,
                memory_item_id TEXT NOT NULL REFERENCES memory_items(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                locator_json TEXT,
                excerpt TEXT NOT NULL,
                source_sha256 TEXT NOT NULL,
                source_url TEXT,
                source_normalized_url TEXT,
                source_doi TEXT,
                source_published_doi TEXT,
                sort_index INTEGER NOT NULL
            )
        """)

        // Attempts are immutable top-level sync events. Deliberately omit foreign
        // keys to the item/session/exchange: CloudKit does not guarantee delivery
        // order, and preserving an orphaned attempt is safer than dropping history.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_attempts (
                id TEXT PRIMARY KEY,
                memory_item_id TEXT NOT NULL,
                session_id TEXT,
                exchange_id TEXT,
                attempt_type TEXT NOT NULL,
                prompt TEXT NOT NULL,
                learner_answer TEXT NOT NULL,
                feedback TEXT,
                score REAL CHECK (score IS NULL OR (score >= 0 AND score <= 1)),
                schedule_rating TEXT,
                grade_state TEXT NOT NULL,
                grading_error TEXT,
                evidence_json TEXT,
                attempted_at REAL NOT NULL,
                model_provider TEXT,
                model_id TEXT,
                model_metadata_json TEXT,
                parent_curriculum_fingerprint TEXT,
                UNIQUE(session_id, exchange_id)
            )
        """)

        // Local-only, regenerable projection. CloudKit syncs immutable attempts;
        // each device applies the portable scheduler to rebuild this row.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_schedules (
                memory_item_id TEXT PRIMARY KEY REFERENCES memory_items(id) ON DELETE CASCADE,
                due_at REAL NOT NULL,
                last_attempt_at REAL,
                last_success_at REAL,
                stability REAL NOT NULL DEFAULT 0,
                difficulty REAL NOT NULL DEFAULT 0.5,
                repetition_count INTEGER NOT NULL DEFAULT 0,
                lapse_count INTEGER NOT NULL DEFAULT 0,
                algorithm_version INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_items_goal_status ON memory_items(goal_id, status, updated_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_item ON memory_item_sources(memory_item_id, sort_index)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_source ON memory_item_sources(source_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_identity_url ON memory_item_sources(source_normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_identity_doi ON memory_item_sources(source_doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_identity_published_doi ON memory_item_sources(source_published_doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_attempts_item_date ON memory_attempts(memory_item_id, attempted_at, id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_attempts_session ON memory_attempts(session_id, exchange_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_schedules_due ON memory_schedules(due_at, memory_item_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS learning_goals (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                start_at REAL NOT NULL,
                end_at REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                -- Learning Companion fields (proactive daily-quiz goals). Plain
                -- Schedule goals leave them NULL; companion goals are tagged
                -- kind = 'companion'.
                kind TEXT,
                description TEXT,
                topic TEXT,
                discovery_enabled INTEGER,
                daily_target INTEGER,
                last_quiz_date TEXT,
                last_discovery_at REAL,
                -- A Notebook's short description: display copy for the gallery
                -- card and overview. description above is the standing chat
                -- Instructions, so the two never share a column. Carried in the
                -- learningGoal CloudKit payload.
                summary TEXT,
                -- Notebook synthesis notes (markdown): the Internal Review
                -- accumulates what's been learned here. Carried in the learningGoal
                -- CloudKit payload.
                notes TEXT,
                -- When set, this companion goal is a timebound Goal nested inside the
                -- named Notebook (another companion goal). NULL = a top-level Notebook.
                -- Carried in the learningGoal CloudKit payload.
                parent_notebook_id TEXT,
                -- The Notebook's defining research questions as a JSON string array, in
                -- priority order. NULL = never set (and syncs as no-opinion); an
                -- explicitly cleared list is stored as "[]". Carried in the
                -- learningGoal CloudKit payload.
                research_questions TEXT,
                -- The GitHub repository a Notebook is about, as owner/repo
                -- (schema 102). Only the name lives here: chats read the
                -- repository live through the GitHub tools and nothing from it
                -- is stored. NULL = never set (syncs as no-opinion); an explicit
                -- unlink is stored as ''. Carried in the learningGoal CloudKit
                -- payload.
                repository TEXT,
                -- The artifact a Goal is for (schema 121): the id of the Doc,
                -- Site or animation that is its deliverable. Only the id lives
                -- here; the row resolves the record from the library. NULL =
                -- never set (syncs as no-opinion); an explicit unlink is stored
                -- as ''. Carried in the learningGoal CloudKit payload.
                artifact_id TEXT,
                -- Where the learner put a Goal in the Goals tab (schema 125):
                -- its index in the order last made by hand. NULL = never
                -- placed, which reads by deadline after the placed rows and
                -- syncs as no-opinion. Carried in the learningGoal CloudKit
                -- payload.
                sort_order INTEGER,
                -- The team whose library this Notebook belongs to (schema 96);
                -- NULL is My Library. Routes the record to the team's zone.
                team_id TEXT,
                -- Schema v2 (154): NULL until the generation-2 activation
                -- derives them (a Notebook or a Goal and its redirects)
                entity_kind TEXT,
                merged_into TEXT,
                fold_kind TEXT,
                moving_to TEXT,
                moved_to TEXT,
                -- The schema-v2 logical id and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goals_team ON learning_goals(team_id, status)")

        try exec("""
            CREATE TABLE IF NOT EXISTS learning_goal_items (
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
                -- User-defined study order within a Notebook pool. NULL = unsequenced
                -- (sorts after sequenced items, by added_at). Kept separate from
                -- added_at, which the retired per-goal planner stamped as a planned date.
                sequence REAL,
                order_key TEXT,
                UNIQUE(goal_id, source_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goals_status ON learning_goals(status)")
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goal_items_goal ON learning_goal_items(goal_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goal_items_source ON learning_goal_items(source_id)")


        // A local, regenerable projection over the iCloud Drive Notebook workspace.
        // The actual file plus its user-owned relative path is the cross-device
        // source of truth; scanning `Projects/<notebook id>/` rebuilds these rows.
        // `role` remains only for v12 schema compatibility and carries "file".
        // Since schema 154 no foreign key ties a row to its notebook, and
        // `notebook_id` may be NULL: generation 2 leaves a deleted notebook's
        // files unfiled (`releaseFilesOfDeletedNotebook`).
        try createPerMemberTable(Self.notebookFilesTable)

        // Canonical Markdown artifacts are global documents. Keep the `global_`
        // prefix: released databases can contain an older, unrelated `artifacts`
        // table (`type`, `content`, `generated_at`). Reusing that name made the
        // first v61 migration fail closed before the library could open.
        // `home_notebook_id` is only an organizational label and Notebook links are
        // many-to-many; neither references learning_goals because CloudKit may
        // deliver an artifact before the linked Notebook.
        try exec("""
            CREATE TABLE IF NOT EXISTS global_artifacts (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                home_notebook_id TEXT,
                is_draft INTEGER NOT NULL DEFAULT 0,
                linked_url TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                -- The team whose library this Doc belongs to (schema 96).
                team_id TEXT,
                -- When the learner archived it; NULL while current (schema 106).
                -- Schema 111's hidden_at column is retired (114): a hidden doc
                -- is a hidden_artifacts row and a store that has the column
                -- keeps it unread and unwritten.
                archived_at REAL,
                -- What the record is when its link would misname it: 'animation'
                -- (schema 117); NULL for a Markdown doc and every linked page.
                kind TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL,
                -- The body's FileRef (159) written by the generation-2 body
                -- publisher once its satellites are acknowledged; NULL under
                -- generation 1 (no commas in comments before a dropped column)
                body_ref TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifacts_team ON global_artifacts(team_id, updated_at DESC)")
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifacts_updated ON global_artifacts(updated_at DESC, id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifacts_home_notebook ON global_artifacts(home_notebook_id, updated_at DESC)")
        try exec("""
            CREATE TABLE IF NOT EXISTS global_artifact_notebook_links (
                artifact_id TEXT NOT NULL REFERENCES global_artifacts(id) ON DELETE CASCADE,
                notebook_id TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY (artifact_id, notebook_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifact_notebook_links_notebook ON global_artifact_notebook_links(notebook_id, artifact_id)")
        // The sources a record is about (schema 117): an animation's paper,
        // one row a link. No foreign key on the source — a source can arrive
        // from CloudKit after the record that names it, or be deleted before
        // it — so a dangling id is simply one no source answers to.
        try exec("""
            CREATE TABLE IF NOT EXISTS global_artifact_source_links (
                artifact_id TEXT NOT NULL REFERENCES global_artifacts(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY (artifact_id, source_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifact_source_links_source ON global_artifact_source_links(source_id, artifact_id)")

        // Threaded comments are independent child records so sharing an
        // Artifact hierarchy includes discussion without modifying Markdown.
        // Anchors are revision-bound; a detached quote remains reviewable after
        // edits instead of being silently moved to unrelated prose.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_comments (
                id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL REFERENCES global_artifacts(id) ON DELETE CASCADE,
                parent_comment_id TEXT REFERENCES artifact_comments(id) ON DELETE CASCADE,
                author_record_name TEXT NOT NULL,
                author_display_name TEXT NOT NULL,
                body TEXT NOT NULL,
                anchor_revision TEXT NOT NULL,
                anchor_start INTEGER NOT NULL,
                anchor_end INTEGER NOT NULL,
                anchor_quote TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                resolved_at REAL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_comments_artifact
            ON artifact_comments(artifact_id, created_at, id)
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_comments_parent
            ON artifact_comments(parent_comment_id, created_at, id)
        """)

        // Where a chat came from. A conversation opened on a highlighted passage
        // is about that passage, and nothing else recorded that: the session kept
        // the passage's sources and the doc's Notebook, so a chat could be traced
        // to what it stood on but never to the sentence that prompted it.
        //
        // Anchors are revision-bound and never re-anchored, exactly like
        // artifact_comments above. Offsets into a doc that has since been
        // rewritten cannot be trusted, so the quote is the durable identity and
        // the offsets are a hint the reader uses only while the revision still
        // matches.
        //
        // artifact_id deliberately carries no foreign key, for the same reason
        // learning_goal_items.goal_id does not: CloudKit can deliver the chat
        // before the doc it points at, and a link that refuses to land is worse
        // than one that waits for its doc to arrive. `deleteArtifactRecord`
        // sweeps the rows a deleted doc leaves behind.
        //
        // UNIQUE keeps asking twice about one passage from stacking rows; a later
        // revision genuinely is a different anchor, and gets its own.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_chat_links (
                id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL,
                session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
                anchor_revision TEXT NOT NULL,
                anchor_start INTEGER NOT NULL,
                anchor_end INTEGER NOT NULL,
                anchor_quote TEXT NOT NULL,
                section_title TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                UNIQUE(session_id, artifact_id, anchor_revision, anchor_start, anchor_end)
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_chat_links_artifact
            ON artifact_chat_links(artifact_id, created_at, id)
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_chat_links_session
            ON artifact_chat_links(session_id)
        """)

        // Durable Notebook-to-course subscriptions. A linked course contributes its
        // current sources to the Notebook immediately, and future course additions are
        // materialized into learning_goal_items by the course/source write paths.
        //
        // course_id deliberately has no FK: CloudKit may deliver the Notebook before
        // the course record. The relationship remains valid and begins contributing
        // as soon as the matching course arrives.
        try exec("""
            CREATE TABLE IF NOT EXISTS notebook_course_links (
                goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                course_id TEXT NOT NULL,
                PRIMARY KEY (goal_id, course_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_course_links_course ON notebook_course_links(course_id)")

        // Directional, non-hierarchical Notebook references. A Notebook can draw
        // contextual material from another Notebook without copying its sources
        // or making it a child. The destination deliberately has no FK because
        // CloudKit may deliver the referring Notebook first.
        try exec("""
            CREATE TABLE IF NOT EXISTS notebook_related_notebook_links (
                notebook_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                related_notebook_id TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY (notebook_id, related_notebook_id),
                CHECK (notebook_id <> related_notebook_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_related_notebook_links_related ON notebook_related_notebook_links(related_notebook_id, notebook_id)")

        // Child-Goal lookups filter on the parent, so index it (the older
        // idx_learning_goals_status indexes a column that only ever held 'active'
        // until Goals gained real lifecycle state).
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goals_parent ON learning_goals(parent_notebook_id)")

        // Evolving "gaps in understanding" per companion goal; carried inside the
        // learningGoal CloudKit payload (no separate synced entity).
        try exec("""
            CREATE TABLE IF NOT EXISTS learning_goal_gaps (
                id TEXT PRIMARY KEY,
                goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                summary TEXT NOT NULL,
                source_id TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                severity REAL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                resolved_at REAL,
                session_id TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goal_gaps_goal ON learning_goal_gaps(goal_id, status)")

        // Shared calendar placement: a source sits on the Schedule once (one planned
        // day, one completion state) and is tagged with one or more plain Schedule
        // goals via scheduled_source_goals. source_id has no FK on purpose (mirrors
        // learning_goal_items: CloudKit can deliver a placement before its source).
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_sources (
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
                updated_at REAL NOT NULL,
                is_automatic INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_source ON scheduled_sources(source_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_planned ON scheduled_sources(planned_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_identity_url ON scheduled_sources(source_normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_identity_doi ON scheduled_sources(source_doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_identity_published_doi ON scheduled_sources(source_published_doi)")

        // Daily source activity is the automatic half of Schedule. It is kept
        // separate from the one editable planned placement so reading, listening,
        // chat, and review history never destroy a future plan or one another.
        // No FK by design: ScheduledSource/Source CloudKit delivery order is not
        // guaranteed, and reconciliation is performed by the storage actor.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_activity_days (
                id TEXT PRIMARY KEY,
                scheduled_source_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                day_start REAL NOT NULL,
                first_activity_at REAL NOT NULL,
                last_activity_at REAL NOT NULL,
                kinds INTEGER NOT NULL,
                completed_kinds INTEGER NOT NULL,
                max_fraction REAL NOT NULL DEFAULT 0,
                engaged_seconds REAL NOT NULL DEFAULT 0,
                UNIQUE(source_id, day_start)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_source_activity_days_source_day ON source_activity_days(source_id, day_start)")
        try exec("CREATE INDEX IF NOT EXISTS idx_source_activity_days_placement ON source_activity_days(scheduled_source_id)")

        // Many-to-many membership between a shared placement and plain Schedule goals.
        // Neither column has an FK: goal/placement deletion is handled in app code so
        // CloudKit delivery order can't fail an INSERT.
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_source_goals (
                scheduled_source_id TEXT NOT NULL,
                goal_id TEXT NOT NULL,
                added_at REAL NOT NULL,
                PRIMARY KEY (scheduled_source_id, goal_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ssg_goal ON scheduled_source_goals(goal_id)")

        // Recurring instructions the app sends to itself. Distinct from
        // `scheduled_sources`, which places library material on a study day:
        // these place an *action* on a clock. `notebook_id` deliberately carries
        // no FK — CloudKit may deliver a task before its Notebook — and Notebook
        // deletion detaches the reference in app code, exactly as it does for
        // Schedule placements.
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_tasks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                instruction TEXT NOT NULL,
                notebook_id TEXT,
                source_ids TEXT NOT NULL DEFAULT '[]',
                cadence TEXT NOT NULL DEFAULT 'daily',
                weekday INTEGER,
                day_of_month INTEGER,
                hour INTEGER NOT NULL DEFAULT 8,
                minute INTEGER NOT NULL DEFAULT 0,
                time_zone TEXT,
                start_date REAL,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_occurrence_at REAL,
                last_run_at REAL,
                last_run_status TEXT,
                run_now_requested_at REAL,
                runner_device_id TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_enabled ON scheduled_tasks(is_enabled)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_notebook ON scheduled_tasks(notebook_id)")

        // One receipt per occurrence. The UNIQUE constraint is the duplicate
        // guard: two Macs awake at 7am both try to claim the same instant and
        // exactly one INSERT survives, so one morning can only ever produce one
        // chat. Receipts also ride along in the task's CloudKit payload, so a
        // second device sees the same history rather than "never run".
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_task_runs (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES scheduled_tasks(id) ON DELETE CASCADE,
                occurrence_at REAL NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                status TEXT NOT NULL,
                session_id TEXT,
                message TEXT,
                device_name TEXT,
                attempt INTEGER NOT NULL DEFAULT 1,
                retry_at REAL,
                ring_slot TEXT,
                UNIQUE(task_id, occurrence_at)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_task ON scheduled_task_runs(task_id, occurrence_at DESC)")

        // The time-block planner: one row per local date and the blocks drawn
        // on it. The day's id *is* its date so two devices planning the same
        // day offline produce one record; the day and its blocks travel in one
        // `DayPlan` CloudKit record. Rows are never destroyed: an edit lands on
        // the row, and `deleted_at` tombstones a block removed or replaced by a
        // redraw, so a merge can union by id. `revision` and
        // `superseded_in_revision` are the numbered columns builds before
        // 2026-09-30 drew; a row with the latter set is not part of the plan.
        // `notebook_id` carries no FK, like scheduled_tasks.
        try exec("""
            CREATE TABLE IF NOT EXISTS day_plans (
                id TEXT PRIMARY KEY,
                plan_date TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1,
                notes TEXT,
                shutdown_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_day_plans_date ON day_plans(plan_date)")
        try exec("""
            CREATE TABLE IF NOT EXISTS time_blocks (
                id TEXT PRIMARY KEY,
                day_plan_id TEXT NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
                start_minute INTEGER NOT NULL,
                end_minute INTEGER NOT NULL,
                title TEXT NOT NULL,
                notes TEXT,
                notebook_id TEXT,
                -- The Goal this hour is meant to serve, when the learner said.
                -- No FK, for the same reason as notebook_id.
                goal_id TEXT,
                -- The first of source_ids, kept for clients that read one source.
                source_id TEXT,
                -- JSON array of source ids, in the order they were added.
                source_ids TEXT NOT NULL DEFAULT '[]',
                -- What kind of hour the block is: work, read, review.
                purpose TEXT NOT NULL DEFAULT 'work',
                -- The calendar event the block mirrors, and its page, when a
                -- connected calendar drew it. No FK: the calendar is outside.
                calendar_event_id TEXT,
                calendar_event_url TEXT,
                -- Where the hour is, as the calendar says it: the event's
                -- conference link or else its room. The import's, not the
                -- learner's; notes are the learner's.
                location TEXT,
                status TEXT NOT NULL DEFAULT 'planned',
                revision INTEGER NOT NULL DEFAULT 1,
                superseded_in_revision INTEGER,
                deleted_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_time_blocks_plan ON time_blocks(day_plan_id, start_minute)")

        // The Planner's log: what the app saw the learner do, a span per sitting
        // on one thing (a source open in the Reader, a chat, a Doc), drawn beside
        // the plan and riding in the day's DayPlan record. target_id carries no
        // FK: the log still reads after the paper or chat is gone.
        try exec("""
            CREATE TABLE IF NOT EXISTS day_activities (
                id TEXT PRIMARY KEY,
                day_plan_id TEXT NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
                start_minute INTEGER NOT NULL,
                end_minute INTEGER NOT NULL,
                kind TEXT NOT NULL,
                target_id TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_day_activities_plan ON day_activities(day_plan_id, start_minute)")

        // A timed learning bout: the clock the learner set, what came out of
        // it, and the break the write-up earned. Rides in the day's DayPlan
        // record beside its blocks and its log. block_id carries no FK — a
        // redraw supersedes the block's row and the bout must still read —
        // and neither does notebook_id, for the reason day_plans gives.
        try exec("""
            CREATE TABLE IF NOT EXISTS learning_bouts (
                id TEXT PRIMARY KEY,
                day_plan_id TEXT NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
                block_id TEXT,
                title TEXT NOT NULL DEFAULT '',
                notebook_id TEXT,
                -- JSON array of source ids, copied from the block at the start.
                source_ids TEXT NOT NULL DEFAULT '[]',
                planned_minutes INTEGER NOT NULL,
                started_at REAL NOT NULL,
                -- The learner stopped learning. The timer running out does not
                -- set this: the clock never ends a bout.
                ended_at REAL,
                learned TEXT,
                unclear TEXT,
                -- The write-up was saved. This is when the break is earned.
                written_at REAL,
                break_minutes INTEGER NOT NULL DEFAULT 0,
                break_started_at REAL,
                break_ended_at REAL,
                abandoned_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_bouts_plan ON learning_bouts(day_plan_id, started_at)")

        // Papers read off a video's slides at ingest, held as candidates until the
        // learner decides. source_id (the video) and imported_source_id (the paper
        // created on import) deliberately carry no FK, mirroring scheduled_sources:
        // CloudKit can deliver a candidate before either source row exists.
        try exec("""
            CREATE TABLE IF NOT EXISTS video_cited_papers (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                title TEXT NOT NULL,
                authors TEXT,
                year TEXT,
                journal TEXT,
                doi TEXT,
                url TEXT,
                slide_time_seconds REAL,
                slide_image_path TEXT,
                status TEXT NOT NULL,
                imported_source_id TEXT,
                kind TEXT NOT NULL DEFAULT 'paper',
                context TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_video_cited_papers_source ON video_cited_papers(source_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_video_cited_papers_status ON video_cited_papers(status)")

        // Journals (schema 99): publisher feeds this Mac follows, the articles
        // they announced, and the matching call's verdicts. All four tables are
        // device-local — the feed list and its HTTP validators describe this
        // machine's polling, and a match becomes synced library data only when
        // the learner accepts it (docs/journals-design.md). Pure DDL on empty
        // tables; cost cannot grow with the library.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_feeds (
                id TEXT PRIMARY KEY,
                feed_url TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                site_url TEXT,
                added_at REAL NOT NULL,
                last_checked_at REAL,
                last_succeeded_at REAL,
                last_error TEXT,
                etag TEXT,
                last_modified TEXT,
                item_count INTEGER NOT NULL DEFAULT 0
            )
        """)
        // The article URL is the identity: one row however many followed feeds
        // announce it, judged once. feed_id is the feed that announced it first.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_feed_items (
                item_url TEXT PRIMARY KEY,
                feed_id TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                authors TEXT,
                doi TEXT,
                journal TEXT,
                published_at REAL,
                first_seen_at REAL NOT NULL,
                judged_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_journal_feed_items_feed ON journal_feed_items(feed_id, first_seen_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_journal_feed_items_judged ON journal_feed_items(judged_at)")
        // notebook_id carries no foreign key, like scheduled_tasks: a Notebook
        // deleted on another Mac still has its rows here, and they are simply
        // never shown. state is pending / accepted / dismissed; a dismissal is
        // the tombstone that keeps the same article from being offered to the
        // same Notebook twice.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_article_matches (
                item_url TEXT NOT NULL,
                notebook_id TEXT NOT NULL,
                reason TEXT,
                matched_at REAL NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                decided_at REAL,
                source_id TEXT,
                PRIMARY KEY (item_url, notebook_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_journal_article_matches_notebook ON journal_article_matches(notebook_id, state)")
        try exec("""
            CREATE TABLE IF NOT EXISTS courses (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                course_code TEXT,
                institution TEXT,
                instructors TEXT,
                playlist_url TEXT,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                pending_playlist_import INTEGER NOT NULL DEFAULT 0,
                -- The team whose library this course is a copy in (schema 145).
                -- NULL is the learner's own library.
                team_id TEXT,
                -- The notebook the course lives in (schema 150).
                -- No foreign key: CloudKit may deliver the course first.
                -- NULL is in no notebook.
                home_notebook_id TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL,
                created_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_courses_team ON courses(team_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_courses_home_notebook ON courses(home_notebook_id)")
        try exec("""
            CREATE TABLE IF NOT EXISTS video_playlists (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                playlist_url TEXT NOT NULL,
                last_refreshed_at REAL,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                -- YouTube plugin: which playlists auto-refresh in the background
                -- and how they were followed: "liked", "foreverlm", or "channel"
                -- (a channel's uploads playlist).
                auto_import INTEGER NOT NULL DEFAULT 0,
                connector_kind TEXT
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS course_lectures (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL,
                lecture_number INTEGER NOT NULL,
                title TEXT,
                created_at REAL NOT NULL,
                order_key TEXT,
                UNIQUE(course_id, lecture_number)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_course_lectures_course ON course_lectures(course_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS source_units (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                locator TEXT NOT NULL,
                title TEXT,
                UNIQUE(source_id, kind, locator)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_source_units_source ON source_units(source_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS course_lecture_items (
                id TEXT PRIMARY KEY,
                lecture_id TEXT NOT NULL REFERENCES course_lectures(id) ON DELETE CASCADE,
                source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,
                source_unit_id TEXT REFERENCES source_units(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                label TEXT,
                sort_index INTEGER NOT NULL,
                created_at REAL NOT NULL,
                order_key TEXT,
                span_json TEXT,
                span_slot INTEGER,
                CHECK (source_id IS NOT NULL OR source_unit_id IS NOT NULL),
                UNIQUE(lecture_id, source_id, source_unit_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_course_lecture_items_lecture ON course_lecture_items(lecture_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_course_lecture_items_source ON course_lecture_items(source_id)")
        // An item may name a source unit instead of the source. Visibility asks
        // the question the other way round ("is this source in any course?"), so
        // that lookup needs an index of its own — without it SQLite builds a
        // transient one over the whole item table every time it is asked.
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_course_lecture_items_source_unit
            ON course_lecture_items(source_unit_id)
        """)
        // A course's quizzes (schema 138): course structure written ahead of
        // time, placed after a lecture. No foreign key to `courses`, like
        // `course_lectures`: a course's rows arrive before or after its
        // metadata in sync, and `deleteCourseGroup` removes them with it.
        try exec("""
            CREATE TABLE IF NOT EXISTS course_quizzes (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                lecture_ids_json TEXT NOT NULL DEFAULT '[]',
                after_lecture_id TEXT,
                questions_json TEXT NOT NULL DEFAULT '[]',
                author TEXT NOT NULL DEFAULT 'foreverlm',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                symbol TEXT,
                artwork BLOB,
                revision INTEGER NOT NULL DEFAULT 1
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_course_quizzes_course ON course_quizzes(course_id)")


        try exec("""
            CREATE TABLE IF NOT EXISTS books (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                subtitle TEXT,
                author TEXT,
                edition TEXT,
                cover_path TEXT,
                kind TEXT
            )
        """)

        // Same staging contract for stored text that still carries HTML
        // character references: migration enqueues IDs set-wise, and bounded
        // post-launch batches read, decode, and republish the content.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_text_reference_repair_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Version 79 stages historical Zoom recordings set-wise; bounded
        // post-launch batches perform the relationship and sync writes after
        // the existing library is already visible.
        try exec("""
            CREATE TABLE IF NOT EXISTS zoom_meeting_adoption_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Version 144 stages every paper with a DOI for one check of its title
        // against the title the DOI is registered under (a PDF's text can lose
        // a glyph; the catalog keeps it). Local-only: each Mac checks its own
        // library, and a restored title travels as an ordinary Source change.
        // `RegisteredPaperTitleCheckService` asks Crossref and DataCite off-main
        // in bounded batches after launch; a row leaves when answered.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_registered_title_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_registered_title_order
            ON paper_registered_title_queue(attempt_count, enqueued_at)
        """)

        // Version 148 stages every personal YouTube video for one check of its
        // stored transcript against its captions, fetched again (a video keeps
        // no raw captions). Local-only: each Mac checks its own library, and a
        // rewritten transcript travels as an ordinary Source change.
        // `YouTubeTranscriptCheckService` fetches off-main in bounded batches
        // after launch; a row leaves when answered.
        try exec("""
            CREATE TABLE IF NOT EXISTS youtube_transcript_check_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_youtube_transcript_check_order
            ON youtube_transcript_check_queue(attempt_count, enqueued_at)
        """)

        // Version 166 stages every source of the learner's own library for one
        // check of its stored text for the soft hyphens older builds kept
        // (U+00AD, and a literal `&shy;` the decoder did not know). Local-only:
        // each Mac repairs its own copy, and the repaired text travels as an
        // ordinary Source change. `drainStoredSoftHyphenRepairBatch` reads it
        // after launch in bounded batches; a row leaves when answered.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_text_soft_hyphen_repair_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Teams (schema 96). A row is the local projection of one team zone:
        // its CloudKit address, this account's role in it, and the share that
        // carries the roster. Content rows point at it through `team_id`.
        try exec("""
            CREATE TABLE IF NOT EXISTS teams (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
                permission TEXT NOT NULL CHECK (permission IN ('readOnly', 'readWrite')),
                zone_scope TEXT NOT NULL,
                zone_name TEXT NOT NULL,
                zone_owner_record_name TEXT,
                share_record_name TEXT,
                share_url TEXT,
                created_at REAL NOT NULL,
                joined_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                family_plan_code TEXT
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS team_members (
                team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                user_record_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                email TEXT,
                role TEXT NOT NULL,
                permission TEXT NOT NULL,
                acceptance_status TEXT NOT NULL,
                is_current_user INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                PRIMARY KEY (team_id, user_record_name)
            )
        """)
        // Notebook tasks (schema 96). Every Notebook can carry tasks; a team
        // Notebook's tasks sync in the team zone and can name an assignee by
        // CloudKit user record name. notebook_id has no foreign key for the
        // same reason learning_goal_items.source_id has none: CloudKit may
        // deliver a task before its Notebook.
        try exec("""
            CREATE TABLE IF NOT EXISTS notebook_tasks (
                id TEXT PRIMARY KEY,
                notebook_id TEXT NOT NULL,
                team_id TEXT,
                title TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'todo',
                assignee_record_name TEXT,
                assignee_display_name TEXT,
                due_at REAL,
                source_id TEXT,
                artifact_id TEXT,
                sort_order REAL NOT NULL DEFAULT 0,
                created_by_record_name TEXT,
                created_by_display_name TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL,
                order_key TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_tasks_notebook ON notebook_tasks(notebook_id, status, sort_order)")
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_tasks_team ON notebook_tasks(team_id)")

        // A member's request that a source cited on a team Doc be shared into
        // the team (docs/teams-design.md, decision 14). Synced in the team
        // zone; the URL is the card's address as written, matched against a
        // holder's library the way the card matches. artifact_id has no
        // foreign key because CloudKit may deliver the request before its Doc.
        try exec("""
            CREATE TABLE IF NOT EXISTS share_requests (
                id TEXT PRIMARY KEY,
                team_id TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT,
                artifact_id TEXT,
                requested_by_record_name TEXT,
                requested_by_display_name TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                resolved_by_record_name TEXT,
                resolved_by_display_name TEXT,
                fulfilled_source_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                resolved_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_share_requests_team ON share_requests(team_id, status)")
        try exec("CREATE INDEX IF NOT EXISTS idx_share_requests_url ON share_requests(url)")

        // --- Per-type source tables ---

        try exec("""
            CREATE TABLE IF NOT EXISTS articles (
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
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS papers (
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
                paper_ingestion_method TEXT,
                paywall_suspicion TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS podcasts (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                show_name TEXT,
                web_page_url TEXT,
                raw_ttml TEXT,
                -- Retired by schema 167 (podcast_transcript_audits): neither read nor written
                detruncated_ttml_sha256 TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS book_sources (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                page_start INTEGER,
                page_count INTEGER
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS course_sources (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_groups (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                drive_folder_url TEXT,
                local_folder_path TEXT,
                recurrence_rule TEXT,
                timezone TEXT,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                merged_into_group_id TEXT,
                schedule_json TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_sources (
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
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_artifacts (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                url TEXT,
                local_file_path TEXT,
                mime_type TEXT,
                modified_at REAL,
                sort_index INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_artifacts_group ON meeting_artifacts(group_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_artifacts_source ON meeting_artifacts(source_id)")

        // What a meeting session's transcript asked someone to do. source_id
        // carries no FK: the item is part of the series' record and must
        // read after the session is gone, and CloudKit may deliver the group
        // before the session. done_at is monotonic (a done item stays done),
        // which is what lets two Macs' rows union safely.
        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_action_items (
                id TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                text TEXT NOT NULL,
                owner TEXT,
                due_hint TEXT,
                done_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_action_items_group ON meeting_action_items(group_id, created_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_action_items_source ON meeting_action_items(source_id, position)")

        try exec("""
            CREATE TABLE IF NOT EXISTS videos (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                platform TEXT,
                -- Both dates come from the Liked-feed sync (playlistItems
                -- `snippet.publishedAt` and `contentDetails.videoPublishedAt`). They
                -- stay NULL for videos that never came through that feed —
                -- Safari-discovered rows, manual adds — and for liked rows until the
                -- next feed refresh.
                liked_at REAL,
                video_published_at REAL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS x_posts (
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
                post_text TEXT,
                author TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS group_members (
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL,
                sort_index INTEGER,
                lecture_group_id TEXT,
                PRIMARY KEY (source_id, group_id)
            )
        """)

        // Recreate the view to pick up schema changes (e.g. removed repos table)
        try exec("DROP VIEW IF EXISTS source_projection")
        try exec(Self.sourceProjectionViewSQL(sourceColumnNames: try tableColumnNames("sources")))

        // Indexes for common queries
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_state ON sources(state)")
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_source_type ON sources(source_type)")
        try exec("CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON group_members(group_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_articles_normalized_url ON articles(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_normalized_url ON papers(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_doi ON papers(doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_published_doi ON papers(published_doi)")
        // Legacy rows may contain uppercase DOI characters. New writes normalize,
        // while these indexed NOCASE lookups preserve portable identity for old rows.
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_doi_nocase ON papers(doi COLLATE NOCASE)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_published_doi_nocase ON papers(published_doi COLLATE NOCASE)")
        try exec("CREATE INDEX IF NOT EXISTS idx_podcasts_normalized_url ON podcasts(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_book_sources_normalized_url ON book_sources(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_course_sources_normalized_url ON course_sources(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_sources_normalized_url ON meeting_sources(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_videos_normalized_url ON videos(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_x_posts_normalized_url ON x_posts(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_review_exchanges_session ON review_exchanges(session_id)")
        // Served the question calibration's read of every rated turn, newest
        // first, until that pass was retired on 2026-09-27. Kept rather than
        // dropped: removing it would be a schema change for nothing, and being
        // partial, it costs an unrated library nothing.
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_review_exchanges_rated
            ON review_exchanges(rated_at DESC) WHERE rating IS NOT NULL
        """)

        // The schema-v2 replica, outbox and activation tables (schema 154),
        // created empty; only a store's generation-2 activation fills them.
        try createReplicaTables()
        try createWireKeyIndexes()
        // Schema 155's Source and Collection tables, empty (WP7).
        try createSourceSyncTables()
        // Schema 156's notebook tables, empty (WP8). A migrating store
        // already has the back-pointer view.
        try createNotebookSyncTables()
        // Schema 157's course table, empty (WP9).
        try createCourseSyncTables()
        if !isMigration {
            try createNotebookChildrenView()
        }
        // A store at 175 or older holds `ck_legacy_bodies`: it takes its new name first, or the
        // creation below would make a second, empty table.
        if isMigration && currentVersion < Self.deadObjectsRemovalSchemaVersion {
            try renameBodySendsTable()
        }
        // Schema 159's Artifact tables, empty (WP11).
        try createArtifactSyncTables()
        // Schema 160's reading state, empty (WP12).
        try createReadingSyncTables()
        // Schema 161's memory tables, empty (WP13).
        try createMemorySyncTables()
        // Schema 162's jobs table, empty (WP14).
        try createTasksSyncTables()
        // Schema 163's Device and import-blocked tables, empty (WP12b).
        try createPersonalStateSyncTables()

        if isMigration {
            if currentVersion < Self.generation1RemovalSchemaVersion {
                // Generation 1 is gone (2026-11-09): what its tables still
                // told the activation is recorded in its journal, then the
                // seven tables go. Set-based; no application row is read.
                try recordGeneration1HistoryInActivationJournal()
                try dropGeneration1Tables()
            }
            if currentVersion < Self.deadObjectsRemovalSchemaVersion {
                try dropDeadSchemaObjects()
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
    /// intact (2026-07-23). The view owns no rows, so it is safe to re-derive at
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
    /// and crashed semantic source search mid-answer (2026-08-31). Pinning the
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

extension KnowledgeStore {
}

// MARK: - Schema 131: lessons become walkthroughs

extension KnowledgeStore {
}

// MARK: - Schema 164: a notebook is no longer called a project

extension KnowledgeStore {
}
