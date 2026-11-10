extension KnowledgeStore {

    /// Sources and the per-source content, preparation and background-work tables.
    func createSourceTables() throws {
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
    }

    /// Paper figures, highlights and the chat context.
    func createPaperFigureAndHighlightTables() throws {
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
    }

    /// Synced preferences, embeddings, the full-text index and the book and reference queues.
    func createPreferenceAndSearchTables() throws {
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
    }

    /// Dismissed and hidden sources, shows, channels and episodes.
    func createHiddenSourceTables() throws {
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
    }

    /// Books and the local repair and check queues.
    func createSourceRepairQueueTables() throws {
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
    }

    /// The per-type source tables, meetings and the group members.
    func createSourceTypeTables() throws {
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
    }
}
