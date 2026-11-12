import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - CloudKit Sync

    func saveDerivedSourceContent(_ sourceId: String, content: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try writeSourceContent(sourceID: sourceId, content: content)
            try execBind("UPDATE sources SET state = ? WHERE id = ? AND source_type != ?") { stmt in
                bind(stmt, 1, StudioArticleState.ready.rawValue)
                bind(stmt, 2, sourceId)
                bind(stmt, 3, StudioSourceType.paper.rawValue)
            }
            try enqueueSourceListenableContentPreparation(sourceID: sourceId, content: content)
            try retireSourceReviewGuidePreparation(sourceID: sourceId)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func saveBookRecord(_ payload: CloudKitBookPayload) throws {
        let bookColumns = try tableColumnNames("books")
        if bookColumns.contains("subtitle") && bookColumns.contains("edition") {
            try execBind("""
                INSERT INTO books (id, title, subtitle, author, edition, cover_path, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    author = excluded.author,
                    edition = excluded.edition,
                    cover_path = excluded.cover_path,
                    kind = excluded.kind
            """) { stmt in
                bind(stmt, 1, payload.id)
                bind(stmt, 2, payload.title)
                bind(stmt, 3, payload.subtitle)
                bind(stmt, 4, SourceAuthor.storable(payload.author))
                bind(stmt, 5, payload.edition)
                bind(stmt, 6, payload.coverPath)
                bind(stmt, 7, payload.kind)
            }
        } else {
            try execBind("""
                INSERT INTO books (id, title, author, cover_path, kind)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    author = excluded.author,
                    cover_path = excluded.cover_path,
                    kind = excluded.kind
            """) { stmt in
                bind(stmt, 1, payload.id)
                bind(stmt, 2, payload.title)
                bind(stmt, 3, SourceAuthor.storable(payload.author))
                bind(stmt, 4, payload.coverPath)
                bind(stmt, 5, payload.kind)
            }
        }
    }

    // MARK: - User preferences

    /// Persist a locally-changed preference and queue it for sync.
    ///
    /// `ON CONFLICT ... DO UPDATE SET` rather than `INSERT OR REPLACE`: the latter
    /// blanks columns absent from the statement, which is the failure mode already
    /// documented for `review_sessions.goal_id` in docs/backend-storage-sync.md.
    func writePreference(key: String, valuePlistXML: String, updatedAt: Date = Date()) throws {
        try execBind("""
            INSERT INTO user_preferences (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, valuePlistXML)
            sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSinceReferenceDate)
        }
        // Generation 2: a quiz score or a deck's card states are memory records (§10).
        try mirrorMemoryPreference(key: key, valuePlistXML: valuePlistXML)
    }

    /// Clear a preference.
    func deletePreference(key: String) throws {
        try execBind("DELETE FROM user_preferences WHERE key = ?") { stmt in
            bind(stmt, 1, key)
        }
    }

    /// Every stored preference as `key -> plist XML`. Used to rehydrate
    /// `UserDefaults` after a remote change; small enough (tens of short strings)
    /// to load wholesale rather than tracking which keys the sync touched.
    func loadAllPreferences() throws -> [String: String] {
        var values: [String: String] = [:]
        try query("SELECT key, value FROM user_preferences") { stmt in
            if let key = self.string(stmt, 0), let value = self.string(stmt, 1) {
                values[key] = value
            }
        }
        return values
    }

    /// What `repairUnreadablePreferences()` did: the keys it rewrote, and the
    /// keys it could not read and left as they were.
    struct PreferenceRepairReport: Equatable, Sendable {
        var repaired: [String] = []
        var unreadable: [String] = []
    }

    /// Rewrite every synced preference row whose value `PreferenceStore.decodePlist`
    /// rejects but `recoverPlist` can read, and name the rows that stay unreadable.
    ///
    /// Two `meetingFolder.image.*` rows once carried a plist with
    /// the two-character text `\t` where the encoder writes a tab — what a
    /// `sqlite3` insert typed with escape sequences leaves, since SQL string
    /// literals expand nothing. Written on one Mac and carried by sync to the
    /// other, the row was on both and readable on neither, and hydration skipped
    /// it in silence, so the folder icon looked as if it had never synced. Going
    /// through `writePreference` re-encodes the value canonically and queues the
    /// row, so the clean copy also replaces the broken mirror on the other Mac.
    ///
    /// Not a launch-time job in the banned sense: the table holds tens of rows
    /// that hydration decodes anyway, nothing is written unless a row fails to
    /// decode, and a repaired row decodes next time, so the work retires itself.
    /// An empty value is the payload's form for "no value", not damage, and is
    /// left alone; so is a row for a key that does not sync, since nothing reads it.
    func repairUnreadablePreferences() throws -> PreferenceRepairReport {
        var report = PreferenceRepairReport()
        for (key, xml) in try loadAllPreferences().sorted(by: { $0.key < $1.key }) {
            guard SyncedPreferenceKeys.isSynced(key),
                  !xml.isEmpty,
                  PreferenceStore.decodePlist(xml) == nil
            else { continue }
            if let value = PreferenceStore.recoverPlist(xml),
               let canonical = PreferenceStore.encodePlist(value) {
                try writePreference(key: key, valuePlistXML: canonical)
                report.repaired.append(key)
            } else {
                report.unreadable.append(key)
            }
        }
        return report
    }

    /// The SQLite half of `ICloudStorageUsage`: what sync has uploaded to the
    /// learner's own iCloud database, from its upload ledger (`ck_blobs`, one
    /// row per stored part). That is the library's zone and every space they
    /// own; a team they were invited to lives in the shared database and is
    /// billed to its creator.
    ///
    /// Parts are counted at the size they were uploaded at. A text body is
    /// stored gzipped and a PDF as it is, which is how the two are told apart
    /// from the covers, pictures, audio and book files that make up the rest.
    func iCloudSyncedSourceStorage() throws -> ICloudSyncedSourceStorage {
        var storage = ICloudSyncedSourceStorage(documentBytes: 0, textBytes: 0, otherBytes: 0)
        try query("""
            SELECT CASE WHEN role = 'pdf' THEN 0 WHEN enc = 'gzip' THEN 1 ELSE 2 END,
                   COALESCE(SUM(part_bytes), 0)
            FROM ck_blobs
            WHERE zone_key LIKE 'private/%'
            GROUP BY 1
        """) { stmt in
            let bytes = sqlite3_column_int64(stmt, 1)
            switch sqlite3_column_int(stmt, 0) {
            case 0: storage.documentBytes = bytes
            case 1: storage.textBytes = bytes
            default: storage.otherBytes = bytes
            }
        }
        return storage
    }

    /// Decode the HTML character references left in a bounded slice of stored
    /// source text, then republish those sources so the phone stops showing
    /// `&ldquo;` in the reader.
    ///
    /// Deliberately after launch rather than in the schema transaction: this
    /// reads and rewrites content, which is proportional to the library. Each
    /// batch commits on its own, so a quit midway leaves the rest durable, and
    /// re-running is harmless — decoding is idempotent on text that no longer
    /// holds a reference, and the row leaves the queue either way.
    ///
    /// Every decode strictly shortens the text, so `source_index_state`'s
    /// recorded content length stops matching and the ordinary indexer rebuilds
    /// full text and embeddings for the repaired sources.
    func drainSourceTextReferenceRepairBatch(limit: Int) throws -> [String] {
        let boundedLimit = max(1, min(limit, 100))
        var candidates: [(sourceID: String, content: String)] = []
        try query("""
            SELECT q.source_id, sc.content
            FROM source_text_reference_repair_queue q
            JOIN source_content sc ON sc.source_id = q.source_id
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let content = self.string(stmt, 1) else { return }
            candidates.append((sourceID, content))
        }

        // A queued source whose content row has since gone (archived, deleted)
        // has no repair left to do, but its queue row would otherwise block the
        // batch window forever.
        var orphanedIDs: [String] = []
        try query("""
            SELECT q.source_id
            FROM source_text_reference_repair_queue q
            WHERE NOT EXISTS (
                SELECT 1 FROM source_content sc WHERE sc.source_id = q.source_id
            )
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            if let sourceID = self.string(stmt, 0) { orphanedIDs.append(sourceID) }
        }

        guard !candidates.isEmpty || !orphanedIDs.isEmpty else { return [] }

        try exec("BEGIN IMMEDIATE")
        var repairedIDs: [String] = []
        do {
            for candidate in candidates {
                let decoded = candidate.content.decodingHTMLCharacterReferences()
                if decoded != candidate.content {
                    try execBind("UPDATE source_content SET content = ? WHERE source_id = ?") { stmt in
                        bind(stmt, 1, decoded)
                        bind(stmt, 2, candidate.sourceID)
                    }
                    // The text other devices read is published again (generation 2).
                    try queueSourceFilesRefresh(sourceID: candidate.sourceID)
                    repairedIDs.append(candidate.sourceID)
                }
                try execBind(
                    "DELETE FROM source_text_reference_repair_queue WHERE source_id = ?"
                ) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            }
            for sourceID in orphanedIDs {
                try execBind(
                    "DELETE FROM source_text_reference_repair_queue WHERE source_id = ?"
                ) { stmt in
                    bind(stmt, 1, sourceID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return repairedIDs
    }

    func sourceTextReferenceRepairQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_text_reference_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// An article's reader document was rewritten on this Mac: tell the app's
    /// own views. Sync publishes a reader document once, when the library is
    /// first seeded, and not again after a rewrite (the source publisher
    /// leaves `readerHTML` to a later package), so another device keeps the
    /// document it has until it rebuilds its own from the source text.
    func republishArticleReaderDocument(sourceID: String) throws {
        noteStoreChanged()
    }

    func loadSourceForSync(_ sourceID: String) throws -> StudioArticle? {
        var article: StudioArticle?
        let sql = "SELECT \(Self.sourceColumns) \(Self.sourceJoins) WHERE sp.id = ? LIMIT 1"
        try queryBind(sql, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            article = readSourceRow(stmt)
            article?.content = try? loadSourceContent(sourceID)
            article?.podcastMatch = nil
            article?.podcastMatchTrackId = nil
        }
        return article
    }

    func loadPodcastRawTTML(_ sourceID: String) throws -> String? {
        var rawTTML: String?
        try queryBind("SELECT raw_ttml FROM podcasts WHERE source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            rawTTML = string(stmt, 0)
        }
        return rawTTML
    }

    func loadCourseForSync(_ name: String) throws -> CloudKitCoursePayload? {
        var payload: CloudKitCoursePayload?
        let lecturesForCourse = try loadCourseLectures().filter { $0.courseName == name }
        let lectureIds = Set(lecturesForCourse.map(\.id))
        let itemsForCourse = try loadCourseLectureItems().filter { lectureIds.contains($0.lectureId) }
        let quizzesForCourse = try loadCourseQuizzes(courseID: name)
        let unitsForCourse = try loadSourceUnits(ids: itemsForCourse.compactMap(\.sourceUnitId))
        try queryBind("""
            SELECT id, title, course_code, institution, instructors, playlist_url,
                   is_hidden, pending_playlist_import
            FROM courses
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            guard let courseID = self.string(stmt, 0),
                  let title = self.string(stmt, 1) else { return }
            payload = CloudKitCoursePayload(
                id: courseID,
                title: title,
                courseCode: self.string(stmt, 2),
                institution: self.string(stmt, 3),
                instructors: self.string(stmt, 4),
                playlistURL: self.string(stmt, 5),
                isHidden: sqlite3_column_int(stmt, 6) != 0,
                pendingPlaylistImport: sqlite3_column_int(stmt, 7) != 0,
                lectures: lecturesForCourse,
                lectureItems: itemsForCourse,
                quizzes: quizzesForCourse,
                sourceUnits: unitsForCourse
            )
        }
        return payload
    }

    func saveAIUsageEvent(_ event: AIUsageEvent) throws {
        // AI usage telemetry is local-only and intentionally NOT synced via CloudKit.
        // It is an append-only per-API-call cost ledger; syncing each call produced
        // thousands of CloudKit records that clogged the content sync queue.
        try saveAIUsageEventRecord(event)
    }

    func managedAIUsageCursor() throws -> Int64 {
        var cursor: Int64 = 0
        try query("SELECT last_ledger_id FROM managed_ai_usage_sync_state WHERE singleton = 1") { stmt in
            cursor = sqlite3_column_int64(stmt, 0)
        }
        return cursor
    }

    func cachedAIResponse(for requestKey: String, notOlderThan cutoff: Date) throws -> String? {
        var response: String?
        try queryBind("""
            SELECT response
            FROM ai_response_cache
            WHERE request_key = ? AND created_at >= ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, requestKey)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSinceReferenceDate)
        }) { stmt in
            response = self.string(stmt, 0)
        }
        return response
    }

    func saveCachedAIResponse(_ response: String, for requestKey: String, at date: Date = Date()) throws {
        try execBind("""
            INSERT INTO ai_response_cache (request_key, response, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(request_key) DO UPDATE SET
                response = excluded.response,
                created_at = excluded.created_at
        """) { stmt in
            bind(stmt, 1, requestKey)
            bind(stmt, 2, response)
            sqlite3_bind_double(stmt, 3, date.timeIntervalSinceReferenceDate)
        }
    }

    /// Mirrors a page from the proxy's append-only D1 ledger and advances the
    /// cursor in the same SQLite transaction. A crash can therefore replay a
    /// page but can never skip it; the unique server ledger id makes replays
    /// idempotent.
    func importManagedAIUsageEvents(
        _ rows: [ManagedAI.UsageLedgerEvent],
        through cursor: Int64
    ) throws {
        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback { try? exec("ROLLBACK") }
        }

        for row in rows {
            // A repaired server debit is appended with a fresh cursor id so
            // clients that already mirrored the broken row receive it. Remove
            // that superseded `:unmetered` mirror in the same transaction;
            // otherwise the exact replacement would coexist with the warning
            // forever even though D1 no longer counts the failed record.
            if row.exactCost != 0, let requestID = row.requestID {
                try execBind("""
                    DELETE FROM ai_usage_events
                    WHERE server_ledger_id IS NOT NULL
                      AND server_request_id = ?
                """) { stmt in
                    bind(stmt, 1, "\(requestID):unmetered")
                }
            }
            let billedUSD = row.exactCost != 0
                ? Double(row.billedMicrousd) / 1_000_000
                : nil
            let cacheCreation = (row.cacheWrite5mTokens ?? 0) + (row.cacheWrite1hTokens ?? 0)
            let event = AIUsageEvent(
                id: "managed-ledger-\(row.id)",
                provider: row.provider,
                model: row.model,
                operation: "managed_proxy",
                task: row.task,
                sessionID: nil,
                activityID: row.activityID,
                subjectID: row.subjectID,
                subjectType: row.subjectType,
                subjectTitle: row.sourceTitle,
                createdAt: Date(timeIntervalSince1970: row.createdAtUnix),
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cachedInputTokens: row.cachedInputTokens,
                cacheCreationInputTokens: cacheCreation > 0 ? cacheCreation : nil,
                reasoningTokens: row.reasoningTokens,
                audioInputTokens: nil,
                audioOutputTokens: nil,
                imageCount: nil,
                totalTokens: (row.inputTokens ?? 0) + (row.outputTokens ?? 0),
                characterCount: nil,
                durationSeconds: nil,
                providerReportedCost: billedUSD,
                estimatedCost: billedUSD,
                currency: billedUSD == nil ? nil : "USD",
                rawUsageJSON: nil,
                clientPlatform: row.clientPlatform,
                serverLedgerID: row.id,
                serverRequestID: row.requestID
            )
            try saveAIUsageEventRecord(event)
        }

        // Also reconcile databases where an older app build already imported
        // both records before learning how server repairs are represented. This
        // set-based cleanup runs whenever the event-driven usage sync imports a
        // page (including an empty one), so advancing the cursor early cannot
        // leave a superseded warning behind permanently.
        try exec("""
            DELETE FROM ai_usage_events
            WHERE id IN (
                SELECT stale.id
                FROM ai_usage_events AS stale
                JOIN ai_usage_events AS exact
                  ON exact.server_request_id = substr(
                      stale.server_request_id,
                      1,
                      length(stale.server_request_id) - 10
                  )
                WHERE stale.server_ledger_id IS NOT NULL
                  AND stale.server_request_id LIKE '%:unmetered'
                  AND exact.server_ledger_id IS NOT NULL
                  AND COALESCE(exact.provider_reported_cost, exact.estimated_cost) IS NOT NULL
            )
        """)

        try execBind("""
            INSERT INTO managed_ai_usage_sync_state (singleton, last_ledger_id)
            VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET
                last_ledger_id = MAX(last_ledger_id, excluded.last_ledger_id)
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, cursor)
        }
        try exec("COMMIT")
        needsRollback = false
    }

    func saveAIUsageEventRecord(_ event: AIUsageEvent) throws {
        try execBind("""
            INSERT INTO ai_usage_events (
                id, provider, model, operation, task, session_id,
                activity_id, subject_id, subject_type, subject_title, created_at,
                input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                reasoning_tokens, audio_input_tokens, audio_output_tokens, image_count, total_tokens,
                character_count, duration_seconds, provider_reported_cost, estimated_cost,
                currency, raw_usage_json, client_platform, server_ledger_id, server_request_id,
                latency_ms, own_key
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider = excluded.provider,
                model = excluded.model,
                operation = excluded.operation,
                task = excluded.task,
                session_id = excluded.session_id,
                activity_id = excluded.activity_id,
                subject_id = excluded.subject_id,
                subject_type = excluded.subject_type,
                subject_title = excluded.subject_title,
                created_at = excluded.created_at,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                cache_creation_input_tokens = excluded.cache_creation_input_tokens,
                reasoning_tokens = excluded.reasoning_tokens,
                audio_input_tokens = excluded.audio_input_tokens,
                audio_output_tokens = excluded.audio_output_tokens,
                image_count = excluded.image_count,
                total_tokens = excluded.total_tokens,
                character_count = excluded.character_count,
                duration_seconds = excluded.duration_seconds,
                provider_reported_cost = excluded.provider_reported_cost,
                estimated_cost = excluded.estimated_cost,
                currency = excluded.currency,
                raw_usage_json = excluded.raw_usage_json,
                client_platform = excluded.client_platform,
                server_ledger_id = excluded.server_ledger_id,
                server_request_id = excluded.server_request_id,
                latency_ms = excluded.latency_ms,
                own_key = excluded.own_key
        """) { stmt in
            bind(stmt, 1, event.id)
            bind(stmt, 2, event.provider)
            bind(stmt, 3, event.model)
            bind(stmt, 4, event.operation)
            bind(stmt, 5, event.task)
            bind(stmt, 6, event.sessionID)
            bind(stmt, 7, event.activityID)
            bind(stmt, 8, event.subjectID)
            bind(stmt, 9, event.subjectType)
            bind(stmt, 10, event.subjectTitle)
            sqlite3_bind_double(stmt, 11, event.createdAt.timeIntervalSinceReferenceDate)
            bind(stmt, 12, event.inputTokens)
            bind(stmt, 13, event.outputTokens)
            bind(stmt, 14, event.cachedInputTokens)
            bind(stmt, 15, event.cacheCreationInputTokens)
            bind(stmt, 16, event.reasoningTokens)
            bind(stmt, 17, event.audioInputTokens)
            bind(stmt, 18, event.audioOutputTokens)
            bind(stmt, 19, event.imageCount)
            bind(stmt, 20, event.totalTokens)
            bind(stmt, 21, event.characterCount)
            bind(stmt, 22, event.durationSeconds)
            bind(stmt, 23, event.providerReportedCost)
            // Priced at the write, whatever path the row came from, so no
            // caller can land an unpriced row the rate card could have priced.
            bind(stmt, 24, event.ledgerEstimatedCost)
            bind(stmt, 25, event.currency)
            bind(stmt, 26, event.rawUsageJSON)
            bind(stmt, 27, event.clientPlatform)
            if let serverLedgerID = event.serverLedgerID {
                sqlite3_bind_int64(stmt, 28, serverLedgerID)
            } else {
                sqlite3_bind_null(stmt, 28)
            }
            bind(stmt, 29, event.serverRequestID)
            bind(stmt, 30, event.latencyMilliseconds)
            sqlite3_bind_int(stmt, 31, event.paidByOwnKey ? 1 : 0)
        }
    }

    /// Prices every stored row that still has no cost but can now get one
    /// (`AIUsageEvent.ledgerEstimatedCost`): rows written before the write
    /// itself priced them, and rows whose model only gained a rate since —
    /// a later build's rate card, or a refreshed OpenRouter directory. Only a
    /// NULL `estimated_cost` is ever filled, so a price already stamped is
    /// never rewritten. Returns how many rows it priced.
    @discardableResult
    func repriceUnpricedAIUsageEvents() throws -> Int {
        var unpriced: [AIUsageEvent] = []
        try query("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND \(Self.aiUsageEventCostExpression) IS NULL
        """) { stmt in
            if let event = self.decodeAIUsageEvent(stmt) { unpriced.append(event) }
        }
        let priced = unpriced.compactMap { event in
            event.ledgerEstimatedCost.map { (event.id, $0) }
        }
        guard !priced.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback { try? exec("ROLLBACK") }
        }
        for (id, cost) in priced {
            try execBind("""
                UPDATE ai_usage_events
                SET estimated_cost = ?
                WHERE id = ? AND estimated_cost IS NULL
            """) { stmt in
                bind(stmt, 1, cost)
                bind(stmt, 2, id)
            }
        }
        try exec("COMMIT")
        needsRollback = false
        return priced.count
    }

    /// How many picture calls still have no cost. Their price is OpenRouter's
    /// image directory's, which is read over the network, so the repricing
    /// sweep reads it only when this is above zero.
    func unpricedImageUsageEventCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND operation = 'image_generation'
              AND \(Self.aiUsageEventCostExpression) IS NULL
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Rows OpenRouter has charged for but whose charge the ledger has not
    /// read yet: a generation id is stored (`CloudArticleTTS.generationMarker`)
    /// and no cost is. Newest first, so what the learner is looking at settles
    /// before older leftovers.
    func aiUsageEventsAwaitingGenerationCost(limit: Int) throws -> [(id: String, rawUsageJSON: String)] {
        var rows: [(id: String, rawUsageJSON: String)] = []
        try queryBind("""
            SELECT id, raw_usage_json
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND \(Self.aiUsageEventCostExpression) IS NULL
              AND raw_usage_json LIKE '%"generation_id"%'
            ORDER BY created_at DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }) { stmt in
            if let id = self.string(stmt, 0), let raw = self.string(stmt, 1) {
                rows.append((id, raw))
            }
        }
        return rows
    }

    /// Stamps OpenRouter's own charge on a row that was waiting for it. Only a
    /// row still without any cost is written, so a price already there stands.
    func setAIUsageEventGenerationCost(id: String, costUSD: Double) throws {
        try execBind("""
            UPDATE ai_usage_events
            SET provider_reported_cost = ?, estimated_cost = ?, currency = 'USD'
            WHERE id = ?
              AND server_ledger_id IS NULL
              AND provider_reported_cost IS NULL
              AND estimated_cost IS NULL
        """) { stmt in
            bind(stmt, 1, costUSD)
            bind(stmt, 2, costUSD)
            bind(stmt, 3, id)
        }
    }

    /// Resets to zero every stored estimate for a call OpenRouter says it
    /// billed nothing for (`AIUsageEvent.estimatesSpendOpenRouterDidNotBill`).
    /// A stored estimate that priced a `:free` call at its paid sibling's list
    /// rate even though the row's own usage said cost 0 adds spend that never
    /// happened to every total. This is the one case a stamped estimate is
    /// rewritten: the provider's bill contradicts it. Returns how many rows
    /// it corrected.
    @discardableResult
    func zeroEstimatesOpenRouterDidNotBill() throws -> Int {
        var invented: [String] = []
        // The LIKE is only a cheap prefilter; the Swift check decides.
        try query("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            WHERE server_ledger_id IS NULL
              AND estimated_cost > 0
              AND COALESCE(provider_reported_cost, 0) <= 0
              AND raw_usage_json LIKE '%"cost":0%'
        """) { stmt in
            if let event = self.decodeAIUsageEvent(stmt), event.estimatesSpendOpenRouterDidNotBill {
                invented.append(event.id)
            }
        }
        guard !invented.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback { try? exec("ROLLBACK") }
        }
        for id in invented {
            try execBind("""
                UPDATE ai_usage_events
                SET estimated_cost = 0
                WHERE id = ? AND server_ledger_id IS NULL
            """) { stmt in
                bind(stmt, 1, id)
            }
        }
        try exec("COMMIT")
        needsRollback = false
        return invented.count
    }

    /// Column list every per-call read shares, so the row decoder below can be
    /// used against any of them.
    private static let aiUsageEventColumns = """
        id, provider, model, operation, task, session_id,
        activity_id, subject_id, subject_type, subject_title, created_at,
        input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
        reasoning_tokens, audio_input_tokens, audio_output_tokens, image_count, total_tokens,
        character_count, duration_seconds, provider_reported_cost, estimated_cost,
        currency, raw_usage_json, client_platform, server_ledger_id, server_request_id,
        latency_ms, own_key
    """

    private func decodeAIUsageEvent(_ stmt: OpaquePointer?) -> AIUsageEvent? {
        guard let id = string(stmt, 0),
              let provider = string(stmt, 1),
              let model = string(stmt, 2),
              let operation = string(stmt, 3) else {
            return nil
        }
        return AIUsageEvent(
            id: id,
            provider: provider,
            model: model,
            operation: operation,
            task: string(stmt, 4),
            sessionID: string(stmt, 5),
            activityID: string(stmt, 6),
            subjectID: string(stmt, 7),
            subjectType: string(stmt, 8),
            subjectTitle: string(stmt, 9),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10)),
            inputTokens: optionalInt(stmt, 11),
            outputTokens: optionalInt(stmt, 12),
            cachedInputTokens: optionalInt(stmt, 13),
            cacheCreationInputTokens: optionalInt(stmt, 14),
            reasoningTokens: optionalInt(stmt, 15),
            audioInputTokens: optionalInt(stmt, 16),
            audioOutputTokens: optionalInt(stmt, 17),
            imageCount: optionalInt(stmt, 18),
            totalTokens: optionalInt(stmt, 19),
            characterCount: optionalInt(stmt, 20),
            durationSeconds: optionalDouble(stmt, 21),
            providerReportedCost: optionalDouble(stmt, 22),
            estimatedCost: optionalDouble(stmt, 23),
            currency: string(stmt, 24),
            rawUsageJSON: string(stmt, 25),
            clientPlatform: string(stmt, 26),
            serverLedgerID: sqlite3_column_type(stmt, 27) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(stmt, 27),
            serverRequestID: string(stmt, 28),
            latencyMilliseconds: optionalInt(stmt, 29),
            ownKey: sqlite3_column_int(stmt, 30) != 0
        )
    }

    /// Recorded spend attributed to one chat/review session. `totalUSD` prefers
    /// the provider's own billed amount per row and falls back to the list-price
    /// estimate; `unpricedEventCount` says how many rows carried neither, so the
    /// UI can mark the total as a floor rather than exact.
    struct AIUsageSessionCost: Sendable, Equatable {
        var totalUSD: Double = 0
        var eventCount: Int = 0
        var unpricedEventCount: Int = 0
    }

    /// Sums the ledger for one session, bounded to rows recorded strictly
    /// before `cutoff`. The caller counts events at/after the cutoff live from
    /// the record notification, so the two halves partition cleanly and a row
    /// can never be counted twice however the load races an active stream.
    func aiUsageCost(sessionID: String, before cutoff: Date) throws -> AIUsageSessionCost {
        var cost = AIUsageSessionCost()
        try queryBind("""
            SELECT
                COALESCE(SUM(\(Self.aiUsageEventCostExpression)), 0),
                COUNT(*),
                COALESCE(SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END), 0)
            FROM ai_usage_events
            WHERE session_id = ? AND created_at < ?
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSinceReferenceDate)
        }) { stmt in
            cost.totalUSD = sqlite3_column_double(stmt, 0)
            cost.eventCount = Int(sqlite3_column_int64(stmt, 1))
            cost.unpricedEventCount = Int(sqlite3_column_int64(stmt, 2))
        }
        return cost
    }

    /// Period and column filters shared by the paged read, the count, and the
    /// CSV export, so a filtered view can never disagree with its own total.
    /// Once server rows exist, they replace client estimates over the server's
    /// covered time range. Rows before the first server entry remain visible;
    /// rows during coverage come only from D1, preventing double counting.
    ///
    /// A direct-rail call is the exception. `own_key` is set only when the
    /// learner's own key paid *and* the call went straight to the router, so
    /// the proxy never saw it and no D1 row will ever arrive to stand in for
    /// it. Deferring to server coverage would erase it from the pane, its
    /// totals and the export — the spend the learner most needs to see, since
    /// it is the spend ForeverLM is not billing them for. There is nothing to
    /// double count, so it stays.
    private static let aiUsageAccountingRowPredicate = """
        (server_ledger_id IS NOT NULL
         OR own_key = 1
         OR created_at < COALESCE(
            (SELECT MIN(authoritative.created_at)
               FROM ai_usage_events AS authoritative
              WHERE authoritative.server_ledger_id IS NOT NULL),
            1.0e100
        ))
    """

    struct AIUsageEventFilter: Sendable, Equatable {
        var since: Date?
        /// Exclusive upper bound on `created_at`, so a report for an explicit
        /// period stops at the end of its last day rather than at "now".
        var until: Date?
        var provider: String?
        var model: String?
        var operation: String?
        var task: String?
        var clientPlatform: String?
        /// Only the calls the learner's own key paid for straight at the router
        /// (`own_key`), or only the rest. Nil counts both.
        var paidByOwnKey: Bool?

        init(since: Date? = nil, until: Date? = nil, provider: String? = nil, model: String? = nil, operation: String? = nil, task: String? = nil, clientPlatform: String? = nil, paidByOwnKey: Bool? = nil) {
            self.since = since
            self.until = until
            self.provider = provider
            self.model = model
            self.operation = operation
            self.task = task
            self.clientPlatform = clientPlatform
            self.paidByOwnKey = paidByOwnKey
        }

        fileprivate var whereClause: String {
            var clauses: [String] = [KnowledgeStore.aiUsageAccountingRowPredicate]
            if since != nil { clauses.append("created_at >= ?") }
            if until != nil { clauses.append("created_at < ?") }
            if provider != nil { clauses.append("provider = ?") }
            if model != nil { clauses.append("model = ?") }
            if operation != nil { clauses.append("operation = ?") }
            if task != nil { clauses.append("task = ?") }
            if clientPlatform != nil { clauses.append("client_platform = ?") }
            // A literal, not a bound value, so `bindAIUsageFilter` stays in step.
            if let paidByOwnKey { clauses.append(paidByOwnKey ? "own_key = 1" : "own_key = 0") }
            return "WHERE " + clauses.joined(separator: " AND ")
        }
    }

    /// Binds the filter's values in `whereClause` order and returns the next
    /// free parameter index, so callers can append LIMIT/OFFSET after it.
    private func bindAIUsageFilter(_ filter: AIUsageEventFilter, to stmt: OpaquePointer?) -> Int32 {
        var index: Int32 = 1
        if let since = filter.since {
            sqlite3_bind_double(stmt, index, since.timeIntervalSinceReferenceDate)
            index += 1
        }
        if let until = filter.until {
            sqlite3_bind_double(stmt, index, until.timeIntervalSinceReferenceDate)
            index += 1
        }
        for value in [filter.provider, filter.model, filter.operation, filter.task, filter.clientPlatform].compactMap({ $0 }) {
            bind(stmt, Int(index), value)
            index += 1
        }
        return index
    }

    /// One page of the per-call ledger, newest first. The AI Usage pane pages
    /// through this so every recorded call stays reachable — the summaries
    /// above it aggregate the same rows and would otherwise be the only view.
    /// `id` breaks ties so paging can't repeat or skip rows recorded in the
    /// same instant.
    func loadAIUsageEvents(filter: AIUsageEventFilter = .init(), limit: Int, offset: Int = 0) throws -> [AIUsageEvent] {
        var events: [AIUsageEvent] = []
        try queryBind("""
            SELECT \(Self.aiUsageEventColumns)
            FROM ai_usage_events
            \(filter.whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ? OFFSET ?
        """, bind: { stmt in
            let index = self.bindAIUsageFilter(filter, to: stmt)
            sqlite3_bind_int64(stmt, index, Int64(limit))
            sqlite3_bind_int64(stmt, index + 1, Int64(offset))
        }) { stmt in
            if let event = self.decodeAIUsageEvent(stmt) {
                events.append(event)
            }
        }
        return events
    }

    /// What one call cost, in SQL: the amount the provider actually billed when
    /// it reported a real one, else the list-price estimate stamped at record
    /// time. `NULLIF(...,0)` mirrors `AIUsageParser.billedCost` — a reported
    /// zero is "not reported", not free — so the pane's per-row cost and these
    /// totals can never disagree.
    ///
    /// The trailing CASE is the one place a reported zero is taken at face
    /// value: no estimate exists and the row reports no billable quantity at
    /// all, so the call consumed nothing and cost exactly nothing. Without it
    /// an empty row (a voice session that ended before the model answered)
    /// counted against the unpriced warning as if real spend were missing.
    /// `AIUsageEvent.accountedCostUSD` is the same rule in Swift.
    static let aiUsageEventCostExpression = """
        COALESCE(
            NULLIF(provider_reported_cost, 0),
            estimated_cost,
            CASE WHEN provider_reported_cost = 0
                      AND COALESCE(input_tokens, 0) = 0
                      AND COALESCE(output_tokens, 0) = 0
                      AND COALESCE(cached_input_tokens, 0) = 0
                      AND COALESCE(cache_creation_input_tokens, 0) = 0
                      AND COALESCE(reasoning_tokens, 0) = 0
                      AND COALESCE(audio_input_tokens, 0) = 0
                      AND COALESCE(audio_output_tokens, 0) = 0
                      AND COALESCE(image_count, 0) = 0
                      AND COALESCE(total_tokens, 0) = 0
                      AND COALESCE(character_count, 0) = 0
                      AND COALESCE(duration_seconds, 0) = 0
                 THEN 0 END
        )
        """

    /// Count, total spend, and how many calls carry no cost at all. The
    /// unpriced count is reported rather than folded into the total silently:
    /// a total that quietly omits calls understates real spend.
    ///
    /// Also carries the prompt-cache read and write token sums, so a caching
    /// regression is visible as a number instead of only as a larger bill.
    func aiUsageEventTotals(
        filter: AIUsageEventFilter = .init()
    ) throws -> AIUsageEventTotals {
        var totals = AIUsageEventTotals()
        try queryBind("""
            SELECT COUNT(*),
                   SUM(\(Self.aiUsageEventCostExpression)),
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END),
                   SUM(COALESCE(cached_input_tokens, 0)),
                   SUM(COALESCE(cache_creation_input_tokens, 0))
            FROM ai_usage_events
            \(filter.whereClause)
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            totals = AIUsageEventTotals(
                count: Int(sqlite3_column_int64(stmt, 0)),
                cost: self.optionalDouble(stmt, 1),
                unpriced: Int(sqlite3_column_int64(stmt, 2)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 3)),
                cacheWriteTokens: Int(sqlite3_column_int64(stmt, 4))
            )
        }
        return totals
    }

    /// Total recorded calls matching the filter, so the pane can say how many
    /// rows remain unloaded instead of implying the first page is everything.
    func countAIUsageEvents(filter: AIUsageEventFilter = .init()) throws -> Int {
        try aiUsageEventTotals(filter: filter).count
    }

    /// Task-first rows for the human-readable usage log. Every task gets a
    /// drill-down identity: an explicit source first, then its chat session,
    /// workflow activity, or immutable event as the historical last resort.
    /// This query returns a small aggregate even when the append-only ledger
    /// contains tens of thousands of calls; SwiftUI never receives the full
    /// ledger to group it.
    ///
    /// Rows come most spend first, because the pane is read to find where the
    /// money went. SQLite sorts NULL lowest, so a task with no priced call
    /// falls to the bottom; ties, such as a run of free tasks, go most recent
    /// first.
    func loadAIUsageTaskActivities(
        filter: AIUsageEventFilter = .init()
    ) throws -> [AIUsageTaskActivitySummary] {
        let resolvedSubjectType = """
            CASE
                WHEN (subject_id IS NOT NULL AND TRIM(subject_id) <> '')
                  OR (subject_title IS NOT NULL AND TRIM(subject_title) <> '')
                    THEN COALESCE(NULLIF(TRIM(subject_type), ''), 'item')
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> '' THEN 'chat'
                WHEN review_sessions.id IS NOT NULL THEN 'chat'
                ELSE 'activity'
            END
        """
        let subjectIdentity = """
            CASE
                WHEN subject_id IS NOT NULL AND TRIM(subject_id) <> ''
                    THEN COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_id
                WHEN subject_title IS NOT NULL AND TRIM(subject_title) <> ''
                    THEN 'title-only' || char(31) || COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_title
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> ''
                    THEN 'chat' || char(31) || session_id
                WHEN review_sessions.id IS NOT NULL
                    THEN 'chat' || char(31) || activity_id
                WHEN activity_id IS NOT NULL AND TRIM(activity_id) <> ''
                    THEN 'activity' || char(31) || activity_id
                ELSE 'event' || char(31) || ai_usage_events.id
            END
        """
        let taskKey = "COALESCE(NULLIF(TRIM(task), ''), '__unattributed__')"
        var rows: [AIUsageTaskActivitySummary] = []
        try queryBind("""
            SELECT \(taskKey) AS task_key,
                   NULLIF(TRIM(task), '') AS task_value,
                   CASE WHEN COUNT(DISTINCT \(resolvedSubjectType)) = 1
                        THEN MAX(\(resolvedSubjectType)) ELSE NULL END AS sole_subject_type,
                   COUNT(DISTINCT \(subjectIdentity)) AS subject_count,
                   COUNT(DISTINCT COALESCE(
                       NULLIF(TRIM(activity_id), ''),
                       NULLIF(TRIM(session_id), ''),
                       ai_usage_events.id
                   )) AS activity_count,
                   COUNT(*) AS call_count,
                   COALESCE(SUM(input_tokens), 0) AS input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS output_tokens,
                   SUM(\(Self.aiUsageEventCostExpression)) AS cost,
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END) AS unpriced_count,
                   MAX(created_at) AS latest_at
            FROM ai_usage_events
            LEFT JOIN review_sessions ON review_sessions.id = COALESCE(
                NULLIF(TRIM(ai_usage_events.session_id), ''),
                NULLIF(TRIM(ai_usage_events.activity_id), '')
            )
            \(filter.whereClause)
            GROUP BY task_key
            ORDER BY cost DESC, latest_at DESC, task_key ASC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let key = self.string(stmt, 0) else { return }
            rows.append(AIUsageTaskActivitySummary(
                key: key,
                task: self.string(stmt, 1),
                subjectType: self.string(stmt, 2),
                subjectCount: Int(sqlite3_column_int64(stmt, 3)),
                activityCount: Int(sqlite3_column_int64(stmt, 4)),
                callCount: Int(sqlite3_column_int64(stmt, 5)),
                inputTokens: Int(sqlite3_column_int64(stmt, 6)),
                outputTokens: Int(sqlite3_column_int64(stmt, 7)),
                cost: self.optionalDouble(stmt, 8),
                unpricedCallCount: Int(sqlite3_column_int64(stmt, 9)),
                latestAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))
            ))
        }
        let models = try loadAIUsageModelUses(groupKey: taskKey, filter: filter)
        for index in rows.indices {
            rows[index].models = models[rows[index].key] ?? []
        }
        return rows
    }

    /// Item rows beneath one task. Deterministic source identity is preferred;
    /// title-only rows from the already-deployed source-title attribution are
    /// kept visibly grouped as title-only data, never promoted to source identity.
    /// Chat identity falls back to activity_id because authoritative proxy
    /// rows preserve that workflow ID but do not carry the local session_id.
    /// LIMIT/OFFSET is applied in SQLite so a large grouped result never crosses
    /// onto the UI actor just to be discarded there.
    func loadAIUsageSubjectActivities(
        task: String?,
        filter: AIUsageEventFilter = .init(),
        limit: Int = Int.max,
        offset: Int = 0
    ) throws -> [AIUsageSubjectActivitySummary] {
        let subjectKey = """
            CASE
                WHEN subject_id IS NOT NULL AND TRIM(subject_id) <> ''
                    THEN 'id' || char(31) || COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_id
                WHEN subject_title IS NOT NULL AND TRIM(subject_title) <> ''
                    THEN 'title-only' || char(31) || COALESCE(NULLIF(TRIM(subject_type), ''), 'item') || char(31) || subject_title
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> ''
                    THEN 'chat' || char(31) || session_id
                WHEN review_sessions.id IS NOT NULL
                    THEN 'chat' || char(31) || activity_id
                WHEN activity_id IS NOT NULL AND TRIM(activity_id) <> ''
                    THEN 'activity' || char(31) || activity_id
                ELSE 'event' || char(31) || ai_usage_events.id
            END
        """
        let resolvedSubjectID = """
            COALESCE(
                NULLIF(TRIM(subject_id), ''),
                NULLIF(TRIM(session_id), ''),
                NULLIF(TRIM(activity_id), ''),
                ai_usage_events.id
            )
        """
        let resolvedSubjectType = """
            CASE
                WHEN (subject_id IS NOT NULL AND TRIM(subject_id) <> '')
                  OR (subject_title IS NOT NULL AND TRIM(subject_title) <> '')
                    THEN COALESCE(NULLIF(TRIM(subject_type), ''), 'item')
                WHEN session_id IS NOT NULL AND TRIM(session_id) <> '' THEN 'chat'
                WHEN review_sessions.id IS NOT NULL THEN 'chat'
                ELSE 'activity'
            END
        """
        let resolvedSubjectTitle = """
            COALESCE(
                NULLIF(TRIM(subject_title), ''),
                (
                    SELECT NULLIF(TRIM(source_projection.title), '')
                    FROM source_projection
                    WHERE source_projection.id = ai_usage_events.subject_id
                    LIMIT 1
                ),
                NULLIF(TRIM(review_sessions.topic), '')
            )
        """
        let taskPredicate = task == nil
            ? "(task IS NULL OR TRIM(task) = '')"
            : "task = ?"
        var rows: [AIUsageSubjectActivitySummary] = []
        try queryBind("""
            SELECT \(subjectKey) AS subject_key,
                   MAX(\(resolvedSubjectID)) AS subject_id,
                   MAX(\(resolvedSubjectType)) AS subject_type,
                   MAX(\(resolvedSubjectTitle)) AS subject_title,
                   COUNT(DISTINCT COALESCE(
                       NULLIF(TRIM(activity_id), ''),
                       NULLIF(TRIM(session_id), ''),
                       ai_usage_events.id
                   )) AS activity_count,
                   COUNT(*) AS call_count,
                   COALESCE(SUM(input_tokens), 0) AS input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS output_tokens,
                   SUM(\(Self.aiUsageEventCostExpression)) AS cost,
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END) AS unpriced_count,
                   MAX(created_at) AS latest_at
            FROM ai_usage_events
            LEFT JOIN review_sessions ON review_sessions.id = COALESCE(
                NULLIF(TRIM(ai_usage_events.session_id), ''),
                NULLIF(TRIM(ai_usage_events.activity_id), '')
            )
            \(filter.whereClause) AND \(taskPredicate)
            GROUP BY subject_key
            ORDER BY latest_at DESC, subject_key ASC
            LIMIT ? OFFSET ?
        """, bind: { stmt in
            var next = self.bindAIUsageFilter(filter, to: stmt)
            if let task {
                self.bind(stmt, Int(next), task)
                next += 1
            }
            sqlite3_bind_int64(stmt, next, Int64(max(0, limit)))
            sqlite3_bind_int64(stmt, next + 1, Int64(max(0, offset)))
        }) { stmt in
            guard let key = self.string(stmt, 0) else { return }
            rows.append(AIUsageSubjectActivitySummary(
                key: key,
                subjectID: self.string(stmt, 1),
                subjectType: self.string(stmt, 2),
                subjectTitle: self.string(stmt, 3),
                activityCount: Int(sqlite3_column_int64(stmt, 4)),
                callCount: Int(sqlite3_column_int64(stmt, 5)),
                inputTokens: Int(sqlite3_column_int64(stmt, 6)),
                outputTokens: Int(sqlite3_column_int64(stmt, 7)),
                cost: self.optionalDouble(stmt, 8),
                unpricedCallCount: Int(sqlite3_column_int64(stmt, 9)),
                latestAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))
            ))
        }
        guard !rows.isEmpty else { return rows }
        // Only the page's items: a task with thousands of chats would
        // otherwise group every one of them to name the models of fifty.
        let pageKeys = rows.map(\.key)
        let models = try loadAIUsageModelUses(
            groupKey: subjectKey,
            filter: filter,
            predicate: taskPredicate,
            having: "group_key IN (\(Array(repeating: "?", count: pageKeys.count).joined(separator: ", ")))",
            bind: { stmt, first in
                var next = first
                if let task {
                    self.bind(stmt, Int(next), task)
                    next += 1
                }
                for key in pageKeys {
                    self.bind(stmt, Int(next), key)
                    next += 1
                }
            }
        )
        for index in rows.indices {
            rows[index].models = models[rows[index].key] ?? []
        }
        return rows
    }

    /// The models behind each row of an activity-log query, most calls first.
    /// `groupKey` is the SQL expression the caller grouped its rows by, so a
    /// row finds its models under its own key, and `predicate` narrows the
    /// scan the way the caller's query was narrowed. `bind` receives the first
    /// parameter index after the filter's. Grouped by model id alone: the
    /// ledger spells one router two ways ("OpenRouter", "openrouter").
    private func loadAIUsageModelUses(
        groupKey: String,
        filter: AIUsageEventFilter,
        predicate: String? = nil,
        having: String? = nil,
        bind: (OpaquePointer?, Int32) -> Void = { _, _ in }
    ) throws -> [String: [AIUsageModelUse]] {
        var uses: [String: [AIUsageModelUse]] = [:]
        try queryBind("""
            SELECT \(groupKey) AS group_key,
                   MAX(ai_usage_events.provider) AS provider,
                   ai_usage_events.model AS model,
                   COUNT(*) AS call_count,
                   COALESCE(SUM(\(Self.byokUsagePredicate)), 0) AS byok_calls,
                   COALESCE(SUM(\(Self.creditUsagePredicate)), 0) AS credit_calls
            FROM ai_usage_events
            LEFT JOIN review_sessions ON review_sessions.id = COALESCE(
                NULLIF(TRIM(ai_usage_events.session_id), ''),
                NULLIF(TRIM(ai_usage_events.activity_id), '')
            )
            \(filter.whereClause)\(predicate.map { " AND \($0)" } ?? "")
            GROUP BY group_key, ai_usage_events.model
            \(having.map { "HAVING \($0)" } ?? "")
            ORDER BY group_key ASC, call_count DESC, model ASC
        """, bind: { stmt in
            bind(stmt, self.bindAIUsageFilter(filter, to: stmt))
        }) { stmt in
            guard let key = self.string(stmt, 0),
                  let provider = self.string(stmt, 1),
                  let model = self.string(stmt, 2) else { return }
            uses[key, default: []].append(AIUsageModelUse(
                provider: provider,
                model: model,
                callCount: Int(sqlite3_column_int64(stmt, 3)),
                byokCallCount: Int(sqlite3_column_int64(stmt, 4)),
                creditCallCount: Int(sqlite3_column_int64(stmt, 5))
            ))
        }
        return uses
    }

    /// OpenRouter's `usage.is_byok`, read from the stored raw usage block
    /// (compact JSON, but the spaced spelling is matched too).
    private static let byokUsagePredicate = """
        (ai_usage_events.raw_usage_json LIKE '%"is_byok":true%'
         OR ai_usage_events.raw_usage_json LIKE '%"is_byok": true%')
        """
    private static let creditUsagePredicate = """
        (ai_usage_events.raw_usage_json LIKE '%"is_byok":false%'
         OR ai_usage_events.raw_usage_json LIKE '%"is_byok": false%')
        """

    /// One row per task and model the ledger saw in the period, with every
    /// billable token dimension summed and the cost expression the pane uses,
    /// so a cost report can say which model each feature actually ran and what
    /// it paid per call. Rows recorded before task attribution existed group
    /// under an empty task. Grouped in SQLite: the ledger never crosses the
    /// actor boundary row by row.
    func loadAIUsageTaskModelSummaries(filter: AIUsageEventFilter = .init()) throws -> [AIUsageTaskModelSummary] {
        var rows: [AIUsageTaskModelSummary] = []
        try queryBind("""
            SELECT COALESCE(NULLIF(TRIM(task), ''), '') AS task_key,
                   provider,
                   model,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cached_input_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(reasoning_tokens), 0),
                   SUM(\(Self.aiUsageEventCostExpression)),
                   SUM(CASE WHEN \(Self.aiUsageEventCostExpression) IS NULL THEN 1 ELSE 0 END),
                   MAX(created_at)
            FROM ai_usage_events
            \(filter.whereClause)
            GROUP BY task_key, provider, model
            ORDER BY task_key ASC, provider ASC, model ASC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let task = self.string(stmt, 0),
                  let provider = self.string(stmt, 1),
                  let model = self.string(stmt, 2) else { return }
            rows.append(AIUsageTaskModelSummary(
                task: task,
                provider: provider,
                model: model,
                callCount: Int(sqlite3_column_int64(stmt, 3)),
                inputTokens: Int(sqlite3_column_int64(stmt, 4)),
                outputTokens: Int(sqlite3_column_int64(stmt, 5)),
                cachedInputTokens: Int(sqlite3_column_int64(stmt, 6)),
                cacheCreationInputTokens: Int(sqlite3_column_int64(stmt, 7)),
                reasoningTokens: Int(sqlite3_column_int64(stmt, 8)),
                cost: self.optionalDouble(stmt, 9),
                unpricedCallCount: Int(sqlite3_column_int64(stmt, 10)),
                latestAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11))
            ))
        }
        return rows
    }

    /// Per-local-day spend under a full filter, priced with the same cost
    /// expression as the totals (provider-billed amount first, then the
    /// list-price estimate), so a day's figure agrees with the period total.
    /// This one is for the usage report over MCP.
    func loadAIUsageDailyCosts(filter: AIUsageEventFilter = .init()) throws -> [AIUsageDailyTotal] {
        var totals: [AIUsageDailyTotal] = []
        try queryBind("""
            SELECT strftime('%Y-%m-%d', created_at + 978307200, 'unixepoch', 'localtime') AS day,
                   COUNT(*),
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   SUM(\(Self.aiUsageEventCostExpression))
            FROM ai_usage_events
            \(filter.whereClause)
            GROUP BY day
            ORDER BY day ASC
        """, bind: { stmt in
            _ = self.bindAIUsageFilter(filter, to: stmt)
        }) { stmt in
            guard let day = self.string(stmt, 0) else { return }
            totals.append(AIUsageDailyTotal(
                day: day,
                requestCount: Int(sqlite3_column_int64(stmt, 1)),
                inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                estimatedCost: self.optionalDouble(stmt, 4)
            ))
        }
        return totals
    }


    /// Execute raw SQL — exposed for testing only. Use targeted methods in production code.
    func execForTesting(_ sql: String) throws {
        try exec(sql)
    }
}

// MARK: - Schema-forward usage accounting

extension KnowledgeStore {
    /// Append one immutable usage event when normal `KnowledgeStore` startup
    /// fails. This is intentionally the only operation allowed against a
    /// database whose `user_version` is newer than this build supports.
    ///
    /// The writer discovers the live table columns and supplies only values
    /// this build understands. It never creates or alters a table, changes
    /// `user_version`, reads application records, or updates sync state. A
    /// missing required ledger column fails the call rather than guessing.
    static func appendAIUsageEventForwardCompatibly(
        _ event: AIUsageEvent,
        storeDirectory: URL,
        after primaryFailure: String
    ) throws {
        enum SQLiteValue {
            case text(String?)
            case integer(Int?)
            case integer64(Int64?)
            case real(Double?)
        }

        struct Field {
            let name: String
            let value: SQLiteValue
        }

        func combinedError(_ compatibilityFailure: String) -> KnowledgeStoreError {
            .invalidData(
                "AI usage could not be recorded. Primary storage failed: "
                    + primaryFailure
                    + ". Schema-forward ledger append failed: "
                    + compatibilityFailure
            )
        }

        let databasePath = storeDirectory.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databasePath,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw combinedError("SQLite open error \(openResult).")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 10_000)

        var tableInfo: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(ai_usage_events)",
            -1,
            &tableInfo,
            nil
        ) == SQLITE_OK else {
            throw combinedError(String(cString: sqlite3_errmsg(database)))
        }
        var liveColumns = Set<String>()
        while sqlite3_step(tableInfo) == SQLITE_ROW {
            if let rawName = sqlite3_column_text(tableInfo, 1) {
                liveColumns.insert(String(cString: rawName))
            }
        }
        sqlite3_finalize(tableInfo)

        let requiredColumns: Set<String> = ["id", "provider", "model", "operation", "created_at"]
        let missingRequiredColumns = requiredColumns.subtracting(liveColumns).sorted()
        guard missingRequiredColumns.isEmpty else {
            throw combinedError(
                "ai_usage_events is missing required column(s): "
                    + missingRequiredColumns.joined(separator: ", ")
                    + "."
            )
        }

        let knownFields: [Field] = [
            Field(name: "id", value: .text(event.id)),
            Field(name: "provider", value: .text(event.provider)),
            Field(name: "model", value: .text(event.model)),
            Field(name: "operation", value: .text(event.operation)),
            Field(name: "task", value: .text(event.task)),
            Field(name: "session_id", value: .text(event.sessionID)),
            Field(name: "activity_id", value: .text(event.activityID)),
            Field(name: "subject_id", value: .text(event.subjectID)),
            Field(name: "subject_type", value: .text(event.subjectType)),
            Field(name: "subject_title", value: .text(event.subjectTitle)),
            Field(name: "created_at", value: .real(event.createdAt.timeIntervalSinceReferenceDate)),
            Field(name: "input_tokens", value: .integer(event.inputTokens)),
            Field(name: "output_tokens", value: .integer(event.outputTokens)),
            Field(name: "cached_input_tokens", value: .integer(event.cachedInputTokens)),
            Field(name: "cache_creation_input_tokens", value: .integer(event.cacheCreationInputTokens)),
            Field(name: "reasoning_tokens", value: .integer(event.reasoningTokens)),
            Field(name: "audio_input_tokens", value: .integer(event.audioInputTokens)),
            Field(name: "audio_output_tokens", value: .integer(event.audioOutputTokens)),
            Field(name: "image_count", value: .integer(event.imageCount)),
            Field(name: "total_tokens", value: .integer(event.totalTokens)),
            Field(name: "character_count", value: .integer(event.characterCount)),
            Field(name: "duration_seconds", value: .real(event.durationSeconds)),
            Field(name: "provider_reported_cost", value: .real(event.providerReportedCost)),
            Field(name: "estimated_cost", value: .real(event.ledgerEstimatedCost)),
            Field(name: "currency", value: .text(event.currency)),
            Field(name: "raw_usage_json", value: .text(event.rawUsageJSON)),
            Field(name: "client_platform", value: .text(event.clientPlatform)),
            Field(name: "server_ledger_id", value: .integer64(event.serverLedgerID)),
            Field(name: "server_request_id", value: .text(event.serverRequestID)),
            Field(name: "latency_ms", value: .integer(event.latencyMilliseconds)),
        ]
        let fields = knownFields.filter { liveColumns.contains($0.name) }
        let placeholders = Array(repeating: "?", count: fields.count).joined(separator: ", ")
        let sql = """
            INSERT INTO ai_usage_events (\(fields.map(\.name).joined(separator: ", ")))
            VALUES (\(placeholders))
            ON CONFLICT(id) DO NOTHING
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw combinedError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, field) in fields.enumerated() {
            let index = Int32(offset + 1)
            switch field.value {
            case .text(let value):
                if let value {
                    SQLiteText.bind(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .integer(let value):
                if let value {
                    sqlite3_bind_int64(statement, index, Int64(value))
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .integer64(let value):
                if let value {
                    sqlite3_bind_int64(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .real(let value):
                if let value {
                    sqlite3_bind_double(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw combinedError(String(cString: sqlite3_errmsg(database)))
        }
    }
}

/// Aggregate for the AI Usage pane: how many calls, what they cost, how many
/// carry no price, and how the prompt cache actually behaved.
///
/// The cache figures are deliberately reads-and-writes only, with no total-prompt
/// denominator. `ai_usage_events.input_tokens` is stored exactly as the provider
/// reported it, and the two conventions disagree: Anthropic-direct excludes
/// cached and cache-write tokens from it, while the OpenAI/OpenRouter shape
/// includes them (which is why `AIProviderPricing.TokenRates.inputIncludesCached` exists). A
/// `cached / (cached + write + input)` ratio would therefore double-count the
/// denominator on most of this app's traffic. Reads-versus-writes needs no such
/// assumption and answers the question that matters anyway.
struct AIUsageEventTotals: Sendable, Equatable {
    var count: Int = 0
    var cost: Double?
    var unpriced: Int = 0
    /// Prompt tokens served from the provider's cache, billed at ~0.1x input.
    var cacheReadTokens: Int = 0
    /// Prompt tokens written into the cache, billed at 1.25x (5-minute TTL) or
    /// 2x (1-hour TTL) input.
    var cacheWriteTokens: Int = 0

    /// Share of cache-handled prompt tokens that were reads rather than writes,
    /// or `nil` when nothing touched the cache in this range.
    ///
    /// How to read it: a write is only worth making if it is read back, so
    /// healthy caching sits high — each write amortized over many turns. Around
    /// 0.5 means every write is read back roughly once, which barely breaks even.
    /// Below 0.5 the app is writing more than it reads, the signature of a prefix
    /// that changes before it can be reused: a volatile system head, a churning
    /// tool list, or budget truncation moving the cut boundary every turn.
    var cacheReadShare: Double? {
        let handled = cacheReadTokens + cacheWriteTokens
        guard handled > 0 else { return nil }
        return Double(cacheReadTokens) / Double(handled)
    }
}
