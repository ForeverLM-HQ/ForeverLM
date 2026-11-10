extension KnowledgeStore {

    /// The AI usage ledger, the response cache and the managed-proxy cursor.
    func createAIUsageTables() throws {
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
    }
}
