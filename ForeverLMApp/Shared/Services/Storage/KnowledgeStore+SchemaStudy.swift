import Foundation
import SQLite3

extension KnowledgeStore {

    /// Walkthroughs, Ideas, Atlases, Directions, Skills and the day-close state.
    func createWalkthroughIdeaAndDirectionTables() throws {
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
    }

    /// Review sessions, exchanges, source ideas and the memory tables.
    func createReviewAndMemoryTables() throws {
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
    }

    /// Learning goals (Notebooks) and their items, and the Notebook files.
    func createLearningGoalTables() throws {
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
    }

    /// Global artifacts, their links, comments and chat links.
    func createArtifactTables() throws {
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
    }

    /// Notebook-to-course and Notebook-to-Notebook links and the goal gaps.
    func createNotebookLinkTables() throws {
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
    }
}
