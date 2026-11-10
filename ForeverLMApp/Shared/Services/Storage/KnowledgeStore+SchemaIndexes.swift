extension KnowledgeStore {

    /// Recreates the `source_projection` view to pick up the current columns.
    func createSourceProjectionView() throws {
        // Recreate the view to pick up schema changes (e.g. removed repos table)
        try exec("DROP VIEW IF EXISTS source_projection")
        try exec(Self.sourceProjectionViewSQL(sourceColumnNames: try tableColumnNames("sources")))
    }

    /// The indexes for common queries.
    func createCommonIndexes() throws {
        // Indexes for common queries
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_state ON sources(state)")
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_source_type ON sources(source_type)")
        try exec("CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON group_members(group_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_articles_normalized_url ON articles(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_normalized_url ON papers(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_doi ON papers(doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_published_doi ON papers(published_doi)")
        // Older rows may contain uppercase DOI characters. New writes normalize,
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
    }

    /// The replica, outbox and activation tables and the Source, Notebook and Course sync tables.
    func createReplicaAndSourceSyncTables() throws {
        // The schema-v2 replica, outbox and activation tables (schema 154),
        // created empty; only a store's generation-2 activation fills them.
        try createReplicaTables()
        try createWireKeyIndexes()
        // Schema 155's Source and Collection tables, empty.
        try createSourceSyncTables()
        // Schema 156's notebook tables, empty. A migrating store
        // already has the back-pointer view.
        try createNotebookSyncTables()
        // Schema 157's course table, empty.
        try createCourseSyncTables()
    }

    /// The Artifact, reading, memory, job and personal-state sync tables.
    func createArtifactAndStateSyncTables() throws {
        // Schema 159's Artifact tables, empty.
        try createArtifactSyncTables()
        // Schema 160's reading state, empty.
        try createReadingSyncTables()
        // Schema 161's memory tables, empty.
        try createMemorySyncTables()
        // Schema 162's jobs table, empty.
        try createTasksSyncTables()
        // Schema 163's Device and import-blocked tables, empty.
        try createPersonalStateSyncTables()
    }
}
