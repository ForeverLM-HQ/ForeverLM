// KnowledgeStore: the canonical content cleanup queue, its audit and its application.
import Foundation
import SQLite3

extension KnowledgeStore {

    func nextCanonicalContentCleanupCandidate() throws -> CanonicalContentCleanupCandidate? {
        try canonicalContentCleanupCandidates(limit: 1).first
    }

    /// Durable preparation work is meaningful only while its source remains
    /// active and in the supported article/paper set. Normal archive paths
    /// already remove these rows transactionally; this bounded set-based prune
    /// handles historical or synced status changes that predate that invariant.
    func pruneIneligibleCanonicalContentCleanupQueue() throws -> Int {
        // A spoken script is never cleaned (see `saveSource`); an explainer
        // queued by a build before that rule leaves the queue here.
        try exec("""
            DELETE FROM canonical_content_cleanup_queue
            WHERE EXISTS (
                SELECT 1
                FROM sources s
                WHERE s.id = canonical_content_cleanup_queue.source_id
                  AND (
                        s.status != 'active'
                     OR s.source_type NOT IN ('article', 'paper')
                  )
            )
            OR EXISTS (
                SELECT 1
                FROM articles a
                WHERE a.source_id = canonical_content_cleanup_queue.source_id
                  AND \(Self.spokenScriptURLMatch("a.url"))
            )
        """)
        return Int(sqlite3_changes(db))
    }

    /// SQL that is true for a row whose URL `column` names a spoken script
    /// ForeverLM wrote: an explainer, or an audio overview's script
    /// (`TextToSpeechPreparationPolicy.spokenScriptURLPrefixes`; neither prefix
    /// holds a LIKE wildcard).
    static func spokenScriptURLMatch(_ column: String) -> String {
        "(" + TextToSpeechPreparationPolicy.spokenScriptURLPrefixes
            .map { "COALESCE(\(column), '') LIKE '\($0)%'" }
            .joined(separator: " OR ") + ")"
    }

    /// SQL that is true for every row but an audio overview's script, by its
    /// URL `column`: the retelling is kept out of Memory, idea extraction and
    /// the search indexes, so a review or a citation never lands on it
    /// instead of the sources it retells.
    static func notAudioOverviewScriptURL(_ column: String) -> String {
        "COALESCE(\(column), '') NOT LIKE '\(TextToSpeechPreparationPolicy.audioOverviewURLPrefix)%'"
    }

    /// SQL that is true for a queue row `q` whose attempts are not spent and
    /// whose retry delay has passed at `:now` (`CanonicalContentCleanupRetry`).
    static var canonicalContentCleanupRetryGate: String {
        let retry = CanonicalContentCleanupRetry.self
        return """
            q.attempt_count < \(retry.maximumAttempts)
            AND (
                q.attempt_count = 0
                OR q.enqueued_at + \(canonicalContentCleanupRetryDelaySQL) <= :now
            )
            """
    }

    /// `CanonicalContentCleanupRetry.delay(afterAttempts: q.attempt_count)` for
    /// a row that has failed at least once.
    private static var canonicalContentCleanupRetryDelaySQL: String {
        let retry = CanonicalContentCleanupRetry.self
        return "MIN(\(Int(retry.maximumDelay)), \(Int(retry.baseDelay)) * (1 << MIN(q.attempt_count - 1, 20)))"
    }

    /// - Parameter pendingIngestionOnly: restrict the batch to sources whose
    ///   ingestion is waiting on this pass (`queued`), leaving the historical
    ///   re-clean rows for a drain that is allowed to spend a model on them.
    /// - Parameter now: rows still waiting out a failed attempt's retry delay
    ///   at this time are left for a later drain.
    func canonicalContentCleanupCandidates(
        limit: Int,
        pendingIngestionOnly: Bool = false,
        now: Date = Date()
    ) throws -> [CanonicalContentCleanupCandidate] {
        guard limit > 0 else { return [] }
        var results: [CanonicalContentCleanupCandidate] = []
        let stateClause = pendingIngestionOnly
            ? "s.state = 'queued'"
            : "s.state IN ('ready', 'queued')"
        try queryBind("""
            SELECT s.id,
                   COALESCE(p.title, a.title, 'Untitled'),
                   s.source_type,
                   CASE WHEN s.source_type = 'paper'
                        THEN COALESCE(pp.raw_content, sc.content)
                        ELSE COALESCE(ap.raw_content, sc.content)
                   END,
                   s.state,
                   CASE WHEN s.source_type = 'paper' THEN p.local_file_path ELSE a.local_file_path END
            FROM canonical_content_cleanup_queue q
            JOIN sources s ON s.id = q.source_id
            LEFT JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN papers p ON p.source_id = s.id
            LEFT JOIN articles a ON a.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            WHERE \(stateClause)
              AND s.status = 'active'
              AND NOT \(Self.spokenScriptURLMatch("a.url"))
              AND q.target_version <= \(PaperContentPreparationMetadata.currentVersion)
              AND \(Self.canonicalContentCleanupRetryGate)
              -- A bulk re-queue waits for the learner (schema 135).
              AND \(Self.bulkHoldExclusion(.canonicalCleanup))
            -- Untouched work goes first so one provider-sensitive paper cannot
            -- repeatedly occupy a catch-up batch and starve the rest. Within
            -- each group, newly ingested sources still become usable first.
            ORDER BY CASE WHEN q.last_error IS NULL THEN 0 ELSE 1 END,
                     s.date_added DESC,
                     q.enqueued_at,
                     s.id
            LIMIT :limit
        """, bind: { stmt in
            sqlite3_bind_double(
                stmt,
                sqlite3_bind_parameter_index(stmt, ":now"),
                now.timeIntervalSinceReferenceDate
            )
            sqlite3_bind_int(stmt, sqlite3_bind_parameter_index(stmt, ":limit"), Int32(limit))
        }) { stmt in
            guard let sourceID = string(stmt, 0),
                  let title = string(stmt, 1),
                  let rawType = string(stmt, 2),
                  let sourceType = StudioSourceType(rawValue: rawType),
                  let raw = string(stmt, 3),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            results.append(CanonicalContentCleanupCandidate(
                sourceID: sourceID,
                title: title,
                sourceType: sourceType,
                raw: raw,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                isPendingIngestion: self.string(stmt, 4) == StudioArticleState.queued.rawValue,
                localFilePath: self.string(stmt, 5)
            ))
        }
        return results
    }

    /// Rows still to clean: those waiting out a retry delay included, those
    /// whose attempts are spent not (`CanonicalContentCleanupRetry`).
    func canonicalContentCleanupQueueCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*) FROM canonical_content_cleanup_queue
            WHERE attempt_count < \(CanonicalContentCleanupRetry.maximumAttempts)
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// When the earliest row waiting out a failed attempt's retry delay is
    /// due. Nil when no row waits (a row due already counts as waiting until
    /// a drain picks it).
    func nextCanonicalContentCleanupRetryDate() throws -> Date? {
        var due: Double?
        try query("""
            SELECT MIN(q.enqueued_at + \(Self.canonicalContentCleanupRetryDelaySQL))
            FROM canonical_content_cleanup_queue q
            JOIN sources s ON s.id = q.source_id
            WHERE q.attempt_count > 0
              AND q.attempt_count < \(CanonicalContentCleanupRetry.maximumAttempts)
              AND s.status = 'active'
              AND s.state IN ('ready', 'queued')
        """) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                due = sqlite3_column_double(stmt, 0)
            }
        }
        return due.map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    /// One bounded batch of the schema-134 integrity audit.
    ///
    /// Until `SQLiteText`, a text bind stopped at the string's first U+0000, so
    /// a PDF whose extraction carried one (PDFKit's unmapped glyph) stored only
    /// the text before it while the preparation's hashes, computed in Swift,
    /// described the whole extraction. Such a row claims a cleanup it does not
    /// hold, so the audit hashes each queued row's stored raw text and, where it
    /// disagrees with `raw_sha256`, restates the preparation as what it is — an
    /// uncleaned extraction of the stored text, version 0 — and queues the
    /// source for the canonical cleanup, whose drain extracts the PDF again.
    /// Rows that agree are only dequeued. No model is called here, and the
    /// Source record is marked changed so the copy other devices hold stops
    /// contradicting itself too.
    func auditCanonicalContentIntegrity(
        limit: Int
    ) throws -> (audited: Int, requeuedSourceIDs: [String], remaining: Int) {
        let pending = try canonicalContentIntegrityAuditQueueCount()
        // Once the queue is empty — every launch after the first — the audit
        // is one count and never takes the write lock.
        guard limit > 0, pending > 0 else { return (0, [], pending) }
        try exec("BEGIN IMMEDIATE")
        do {
            var rows: [(sourceID: String, table: String?, raw: String?, rawSHA256: String?)] = []
            try queryBind("""
                SELECT q.source_id,
                       CASE WHEN pp.source_id IS NOT NULL THEN 'paper_content_preparations'
                            WHEN ap.source_id IS NOT NULL THEN 'article_content_preparations'
                       END,
                       COALESCE(pp.raw_content, ap.raw_content),
                       COALESCE(pp.raw_sha256, ap.raw_sha256)
                FROM canonical_content_integrity_audit_queue q
                LEFT JOIN paper_content_preparations pp ON pp.source_id = q.source_id
                LEFT JOIN article_content_preparations ap ON ap.source_id = q.source_id
                ORDER BY q.enqueued_at, q.source_id
                LIMIT ?
            """, bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            }) { stmt in
                guard let sourceID = self.string(stmt, 0) else { return }
                rows.append((sourceID, self.string(stmt, 1), self.string(stmt, 2), self.string(stmt, 3)))
            }

            var requeued: [String] = []
            for row in rows {
                if let table = row.table, let raw = row.raw, let recorded = row.rawSHA256 {
                    let actual = PaperContentPreparationService.sha256(raw)
                    if actual != recorded {
                        try execBind("""
                            UPDATE \(table)
                            SET raw_sha256 = ?, clean_sha256 = NULL, cleaner_version = 0, prepared_at = NULL
                            WHERE source_id = ? AND raw_sha256 = ?
                        """) { stmt in
                            bind(stmt, 1, actual)
                            bind(stmt, 2, row.sourceID)
                            bind(stmt, 3, recorded)
                        }
                        try enqueueCanonicalContentCleanupIfNeeded(
                            sourceID: row.sourceID,
                            preparationTable: table
                        )
                        noteStoreChanged()
                        requeued.append(row.sourceID)
                    }
                }
                try execBind("DELETE FROM canonical_content_integrity_audit_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, row.sourceID)
                }
            }
            let remaining = try canonicalContentIntegrityAuditQueueCount()
            try exec("COMMIT")
            return (rows.count, requeued, remaining)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func canonicalContentIntegrityAuditQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM canonical_content_integrity_audit_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Records a failed cleanup round and moves the source to the back of the
    /// queue. Returns the row's attempt count afterwards (0 when no row).
    ///
    /// - Parameter consumesAttempt: `false` only where no model was asked (the
    ///   Dev build's raw publish). A model round spends an attempt even when it
    ///   failed transiently, so the row then waits out its retry delay
    ///   (`CanonicalContentCleanupRetry`).
    @discardableResult
    func recordCanonicalContentCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String? = nil,
        consumesAttempt: Bool = true
    ) throws -> Int {
        try execBind("""
            UPDATE canonical_content_cleanup_queue
            SET attempt_count = attempt_count + ?,
                last_error = ?,
                enqueued_at = ?,
                source_sha256 = COALESCE(?, source_sha256)
            WHERE source_id = ?
        """) { stmt in
            sqlite3_bind_int(stmt, 1, consumesAttempt ? 1 : 0)
            bind(stmt, 2, message)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 4, sourceSHA256)
            bind(stmt, 5, sourceID)
        }
        var attempts = 0
        try queryBind(
            "SELECT attempt_count FROM canonical_content_cleanup_queue WHERE source_id = ?",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { stmt in attempts = Int(sqlite3_column_int(stmt, 0)) }
        return attempts
    }

    /// A queued source is a new ingestion, not a historical re-clean. When its
    /// durable retry reaches a permanent failure, surface that failure and
    /// retire only this queue row. Ready sources keep their last good canonical
    /// text and remain eligible for a later historical cleanup retry.
    func failPendingCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        message: String
    ) throws {
        guard candidate.isPendingIngestion else { return }
        let visibleMessage = candidate.sourceType == .paper
            ? StudioArticle.paperContentCleanupFailureMessage(message)
            : PaperContentPreparationService.articleIngestionFailureMessage(
                for: AIError.apiError(message)
            )
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE sources
                SET state = 'error', error_message = ?
                WHERE id = ? AND state = 'queued'
            """) { stmt in
                bind(stmt, 1, visibleMessage)
                bind(stmt, 2, candidate.sourceID)
            }
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A ready Source row can still carry the preceding cleanup timeout after
    /// its canonical text was committed. Clear only a code-owned cleanup failure,
    /// and only when the current preparation contract and clean hash prove that
    /// cleanup actually completed. This never calls AI or rewrites content.
    @discardableResult
    func clearCompletedCanonicalContentCleanupFailure(sourceID: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE sources
                SET error_message = NULL
                WHERE id = ?
                  AND state = 'ready'
                  AND (
                        error_message LIKE 'Article ingestion failed during Source Content Cleanup:%'
                     OR error_message LIKE 'Paper cleanup couldn''t finish.%'
                     OR error_message LIKE '%Paper ingestion failed during Source Content Cleanup:%'
                  )
                  AND (
                        EXISTS (
                            SELECT 1 FROM article_content_preparations ap
                            WHERE ap.source_id = sources.id
                              AND ap.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                              AND ap.clean_sha256 IS NOT NULL
                        )
                     OR EXISTS (
                            SELECT 1 FROM paper_content_preparations pp
                            WHERE pp.source_id = sources.id
                              AND pp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                              AND pp.clean_sha256 IS NOT NULL
                        )
                  )
            """) { stmt in
                bind(stmt, 1, sourceID)
            }
            let changed = sqlite3_changes(db) > 0
            if changed {
                noteStoreChanged()
            }
            try exec("COMMIT")
            return changed
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func applyCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        prepared: PreparedPaperContent
    ) throws {
        guard prepared.metadata.cleanerVersion == PaperContentPreparationMetadata.currentVersion,
              prepared.metadata.rawSHA256 == candidate.rawSHA256,
              PaperContentPreparationService.sha256(prepared.clean) == prepared.metadata.cleanSHA256 else {
            throw KnowledgeStoreError.invalidData("Canonical content cleanup hashes or version did not validate.")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            let currentRaw: String?
            if candidate.sourceType == .paper {
                currentRaw = try loadPaperContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            } else {
                currentRaw = try loadArticleContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            }
            // The stored row must still be the text the candidate was read
            // from; `prepared.raw` may be a fresh extraction of the PDF.
            guard let currentRaw,
                  PaperContentPreparationService.sha256(currentRaw) == candidate.storedTextSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Source text changed while canonical cleanup was running; it will be retried."
                )
            }

            try writeSourceContent(sourceID: candidate.sourceID, content: prepared.clean)
            if candidate.isPendingIngestion {
                try execBind("""
                    UPDATE sources
                    SET state = 'ready', error_message = NULL
                    WHERE id = ? AND state = 'queued'
                """) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            } else {
                // A successful historical re-clean supersedes any cleanup
                // failure still attached to this otherwise-ready row.
                try execBind("""
                    UPDATE sources
                    SET error_message = NULL
                    WHERE id = ?
                      AND (
                            error_message LIKE 'Article ingestion failed during Source Content Cleanup:%'
                         OR error_message LIKE 'Paper cleanup couldn''t finish.%'
                         OR error_message LIKE '%Paper ingestion failed during Source Content Cleanup:%'
                      )
                """) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            }
            if candidate.sourceType == .paper {
                try upsertPaperContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: prepared.raw,
                    metadata: prepared.metadata
                )
                try execBind("UPDATE papers SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(prepared.clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count))
                    bind(stmt, 2, candidate.sourceID)
                }
            } else {
                try upsertArticleContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: prepared.raw,
                    metadata: prepared.metadata
                )
                try execBind("UPDATE articles SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(prepared.clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count))
                    bind(stmt, 2, candidate.sourceID)
                }
            }
            try invalidateCanonicalContentIndexes(sourceID: candidate.sourceID)
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            // Listen is prepared when the learner asks for it, or now for
            // automatic-audio kinds.
            try enqueueSourceListenableContentPreparation(
                sourceID: candidate.sourceID,
                content: prepared.clean
            )
            // Any preparation recorded against the pre-cleanup text is void.
            // The cleaned derivative is prepared when a review asks for it.
            try retireSourceReviewGuidePreparation(sourceID: candidate.sourceID)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Finish a pending ingestion without a model: the raw extraction becomes
    /// the canonical text and the source turns `ready`. This is the Dev build's
    /// route (`PaidSourceCleanupPolicy`); the installed app never takes it.
    ///
    /// The preparation row records the deterministic version with the raw
    /// text's own hash as its clean hash — the same attribution a synced record
    /// without preparation metadata receives — so the paper counts as ingested
    /// while any later `saveSource` still sees a version below the current
    /// contract and re-queues it for a drain that may spend a model. No Listen
    /// derivative is queued: that stage is paid too.
    func publishCanonicalContentWithoutCleanup(
        candidate: CanonicalContentCleanupCandidate
    ) throws {
        guard candidate.isPendingIngestion else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let currentRaw: String?
            if candidate.sourceType == .paper {
                currentRaw = try loadPaperContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            } else {
                currentRaw = try loadArticleContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            }
            guard let currentRaw,
                  PaperContentPreparationService.sha256(currentRaw) == candidate.storedTextSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Source text changed while it was being published; it will be retried."
                )
            }

            let metadata = PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.deterministicVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: candidate.rawSHA256,
                preparedAt: Date()
            )
            let wordCount = Int64(
                candidate.raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            )
            try writeSourceContent(sourceID: candidate.sourceID, content: candidate.raw)
            try execBind("""
                UPDATE sources
                SET state = 'ready', error_message = NULL
                WHERE id = ? AND state = 'queued'
            """) { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            if candidate.sourceType == .paper {
                try upsertPaperContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: candidate.raw,
                    metadata: metadata
                )
                try execBind("UPDATE papers SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, wordCount)
                    bind(stmt, 2, candidate.sourceID)
                }
            } else {
                try upsertArticleContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: candidate.raw,
                    metadata: metadata
                )
                try execBind("UPDATE articles SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, wordCount)
                    bind(stmt, 2, candidate.sourceID)
                }
            }
            try invalidateCanonicalContentIndexes(sourceID: candidate.sourceID)
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

}
