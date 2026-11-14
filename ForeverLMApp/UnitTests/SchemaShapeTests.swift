import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The names of the tables, indexes and views a fresh store holds once `createSchema` has run, written
/// out so that a change to the schema has to change this list on purpose.
///
/// Left out on purpose:
/// - SQLite's own `sqlite_*` entries.
/// - The shadow tables SQLite's FTS5 module makes beside `source_fts` (`source_fts_data`,
///   `source_fts_idx`, `source_fts_content`, `source_fts_docsize`, `source_fts_config`). `createSchema`
///   asks for the virtual table; which shadow tables back it is the module's business.
/// - Triggers. `createSchema` installs none: the outbox triggers (`ck_outbox_*`, `ck_ready_*`,
///   `ck_relist_*`) are installed by the sync layer when a store's activation runs, so a fresh store
///   holds no trigger.
@Suite("Schema shape")
struct SchemaShapeTests {
    private static let ftsShadowTables: Set<String> = [
        "source_fts_data", "source_fts_idx", "source_fts_content", "source_fts_docsize", "source_fts_config",
    ]

    private static func names(_ store: KnowledgeStore, type: String) throws -> [String] {
        var names: [String] = []
        try store.query("SELECT name FROM sqlite_master WHERE type = '\(type)' AND name NOT LIKE 'sqlite_%' ORDER BY name") { statement in
            if let text = sqlite3_column_text(statement, 0) {
                names.append(String(cString: text))
            }
        }
        return names.filter { !ftsShadowTables.contains($0) }.sorted()
    }

    @Test("A fresh store holds exactly the tables the schema names")
    func tables() throws {
        let store = try KnowledgeStore(inMemory: true)
        #expect(try Self.names(store, type: "table") == Self.tables)
    }

    @Test("A fresh store holds exactly the indexes the schema names")
    func indexes() throws {
        let store = try KnowledgeStore(inMemory: true)
        #expect(try Self.names(store, type: "index") == Self.indexes)
    }

    @Test("A fresh store holds exactly the views the schema names, and no trigger")
    func viewsAndTriggers() throws {
        let store = try KnowledgeStore(inMemory: true)
        #expect(try Self.names(store, type: "view") == Self.views)
        #expect(try Self.names(store, type: "trigger").isEmpty)
    }

    private static let tables: [String] = [
        "activity_logs", "ai_response_cache", "ai_usage_events", "article_chrome_refilter_queue",
        "article_content_preparations", "articles", "artifact_chat_links", "artifact_comments", "artifact_files",
        "artifact_walkthroughs", "atlases", "background_ai_bulk_job_sources", "background_ai_bulk_jobs",
        "blocked_podcast_shows", "book_file_digests", "book_file_merge_queue", "book_import_finish_queue",
        "book_sources", "books", "canonical_content_cleanup_queue", "canonical_content_integrity_audit_queue",
        "chat_consolidations", "chat_context", "ck_activation", "ck_apply_guard", "ck_backfill_queue",
        "ck_blob_jobs", "ck_blobs", "ck_body_sends", "ck_clock", "ck_echo", "ck_engine_state", "ck_forwarded",
        "ck_identity", "ck_manifest_pending", "ck_move_items", "ck_move_jobs", "ck_outbox", "ck_outbox_fields",
        "ck_patches", "ck_pending_deletes", "ck_quarantine", "ck_records", "ck_seed_cursor", "ck_text_bases",
        "ck_unprojected", "ck_zones", "course_enrollments", "course_lecture_items", "course_lectures",
        "course_quizzes", "course_sources", "courses", "day_activities", "day_plans", "device_activity_days",
        "devices", "dismissed_sources", "embeddings", "global_artifact_notebook_links",
        "global_artifact_source_links", "global_artifacts", "group_members", "hidden_artifacts",
        "hidden_podcast_episodes", "hidden_podcast_shows", "hidden_review_sessions", "hidden_sources",
        "hidden_youtube_channels", "idea_links", "ideas", "jobs", "journal_article_matches", "journal_feed_items",
        "journal_feeds", "learning_bouts", "learning_goal_gaps", "learning_goal_items", "learning_goals",
        "managed_ai_usage_sync_state", "meeting_action_items", "meeting_artifacts", "meeting_groups",
        "meeting_sources", "memory_attempts", "memory_card_states", "memory_day_close_state", "memory_item_sources",
        "memory_items", "memory_review_activity", "memory_schedules", "memory_sitting_answers", "memory_sittings",
        "notebook_course_links", "notebook_files", "notebook_related_notebook_links", "notebook_research_questions",
        "notebook_resolution", "notebook_states", "notebook_task_lists", "notebook_tasks", "paper_content_preparations",
        "paper_figure_image_sweep_state", "paper_figure_index_queue", "paper_figure_index_state", "paper_figures",
        "paper_reference_reads", "paper_references", "paper_registered_title_queue", "papers",
        "pending_hidden_sources", "podcast_transcript_audits", "podcast_transcript_cleanup_queue",
        "podcast_transcript_detruncation_queue", "podcast_transcript_preparations", "podcasts", "practices",
        "reading_states", "research_directions", "review_exchanges", "review_session_history_digests",
        "review_session_sources", "review_sessions", "scheduled_source_goals", "scheduled_sources",
        "scheduled_task_runs", "scheduled_tasks", "share_requests", "skills", "source_activity_days",
        "source_collections", "source_content", "source_derived", "source_faces", "source_files", "source_fts",
        "source_fts_row_backfill", "source_fts_rows", "source_fts_state", "source_highlights", "source_ideas",
        "source_index_state", "source_levels", "source_listenable_content", "source_listenable_content_queue",
        "source_review_guide_queue", "source_review_guides", "source_text_reference_repair_queue",
        "source_text_soft_hyphen_repair_queue", "source_understanding", "source_units", "source_walkthroughs",
        "source_wire_fields", "source_work_keys", "sources", "team_members", "teams", "time_blocks",
        "user_preferences", "video_cited_papers", "video_playlists", "videos", "visible_podcast_episode_overrides",
        "visible_youtube_video_overrides", "walkthrough_progress", "x_posts", "youtube_transcript_check_queue",
        "zoom_meeting_adoption_queue",
    ]

    private static let indexes: [String] = [
        "idx_ai_usage_events_created", "idx_ai_usage_events_model", "idx_ai_usage_events_server_ledger",
        "idx_ai_usage_events_session", "idx_articles_normalized_url", "idx_artifact_chat_links_artifact",
        "idx_artifact_chat_links_session", "idx_artifact_comments_artifact", "idx_artifact_comments_parent",
        "idx_atlases_updated", "idx_background_ai_bulk_job_sources_source", "idx_background_ai_bulk_jobs_pending",
        "idx_book_file_digests_book", "idx_book_sources_normalized_url", "idx_ck_blob_jobs_order",
        "idx_ck_blobs_owner", "idx_ck_identity_local", "idx_ck_outbox_dirty", "idx_ck_patches_dirty",
        "idx_ck_records_wire", "idx_ck_unprojected_ready", "idx_ck_unprojected_waiting", "idx_ck_zones_name",
        "idx_course_lecture_items_lecture", "idx_course_lecture_items_source",
        "idx_course_lecture_items_source_unit", "idx_course_lectures_course", "idx_course_quizzes_course",
        "idx_course_sources_normalized_url", "idx_courses_home_notebook", "idx_courses_team", "idx_courses_wire_key",
        "idx_day_activities_plan", "idx_day_plans_date", "idx_fss_source",
        "idx_global_artifact_notebook_links_notebook", "idx_global_artifact_source_links_source",
        "idx_global_artifacts_home_notebook", "idx_global_artifacts_team", "idx_global_artifacts_updated",
        "idx_global_artifacts_wire_key", "idx_group_members_group_id", "idx_idea_links_target",
        "idx_ideas_status_created", "idx_jobs_status", "idx_journal_article_matches_notebook",
        "idx_journal_feed_items_feed", "idx_journal_feed_items_judged", "idx_learning_bouts_plan",
        "idx_learning_goal_gaps_goal", "idx_learning_goal_items_goal", "idx_learning_goal_items_source",
        "idx_learning_goals_parent", "idx_learning_goals_status", "idx_learning_goals_team",
        "idx_learning_goals_wire_key", "idx_meeting_action_items_group", "idx_meeting_action_items_source",
        "idx_meeting_artifacts_group", "idx_meeting_artifacts_source", "idx_meeting_sources_normalized_url",
        "idx_memory_attempts_item_date", "idx_memory_attempts_session", "idx_memory_item_sources_identity_doi",
        "idx_memory_item_sources_identity_published_doi", "idx_memory_item_sources_identity_url",
        "idx_memory_item_sources_item", "idx_memory_item_sources_source", "idx_memory_items_goal_status",
        "idx_memory_review_activity_day", "idx_memory_schedules_due", "idx_memory_sitting_answers_sitting",
        "idx_memory_sittings_writer", "idx_notebook_course_links_course", "idx_notebook_files_notebook",
        "idx_notebook_files_notebook_role", "idx_notebook_related_notebook_links_related",
        "idx_notebook_tasks_notebook", "idx_notebook_tasks_team", "idx_paper_figure_index_queue_order",
        "idx_paper_figures_source_page", "idx_paper_reference_reads_queue", "idx_paper_registered_title_order",
        "idx_papers_doi", "idx_papers_doi_nocase", "idx_papers_normalized_url", "idx_papers_published_doi",
        "idx_papers_published_doi_nocase", "idx_podcast_transcript_cleanup_queue_order",
        "idx_podcast_transcript_detruncation_queue_order", "idx_podcasts_normalized_url",
        "idx_research_directions_home", "idx_review_exchanges_rated", "idx_review_exchanges_session",
        "idx_review_sessions_team", "idx_review_sessions_wire_key", "idx_scheduled_sources_identity_doi",
        "idx_scheduled_sources_identity_published_doi", "idx_scheduled_sources_identity_url",
        "idx_scheduled_sources_planned", "idx_scheduled_sources_source", "idx_scheduled_task_runs_task",
        "idx_scheduled_tasks_enabled", "idx_scheduled_tasks_notebook", "idx_share_requests_team",
        "idx_share_requests_url", "idx_skills_name", "idx_source_activity_days_placement",
        "idx_source_activity_days_source_day", "idx_source_highlights_source_page", "idx_source_ideas_source",
        "idx_source_listenable_content_queue_order", "idx_source_units_source", "idx_source_work_keys_key",
        "idx_sources_source_type", "idx_sources_state", "idx_sources_status", "idx_sources_team",
        "idx_sources_wire_key", "idx_ssg_goal", "idx_time_blocks_plan", "idx_video_cited_papers_source",
        "idx_video_cited_papers_status", "idx_videos_normalized_url", "idx_x_posts_normalized_url",
        "idx_youtube_transcript_check_order",
    ]

    private static let views: [String] = [
        "ck_notebook_children", "source_projection",
    ]
}
