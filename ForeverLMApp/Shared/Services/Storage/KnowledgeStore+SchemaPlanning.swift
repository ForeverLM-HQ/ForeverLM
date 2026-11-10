extension KnowledgeStore {

    /// Scheduled sources, source activity and scheduled tasks.
    func createScheduleTables() throws {
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
    }

    /// Day plans, time blocks, day activities and learning bouts.
    func createDayPlanTables() throws {
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
    }

    /// Papers cited by videos and the followed journals.
    func createVideoCitedPaperAndJournalTables() throws {
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
    }

    /// Courses, lectures, source units, lecture items and quizzes.
    func createCourseTables() throws {
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
    }

    /// Teams, members, Notebook tasks and share requests.
    func createTeamTables() throws {
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
    }
}
