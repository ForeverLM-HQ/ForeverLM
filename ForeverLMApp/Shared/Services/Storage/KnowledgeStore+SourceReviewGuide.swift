// KnowledgeStore: source review guide preparation.
import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Source review guide preparation

    /// Keeps review-guide work transactionally coupled to canonical source text.
    /// Re-saving metadata does not reset a failed attempt unless the text changed.
    func enqueueSourceReviewGuidePreparation(sourceID: String, content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        let sourceSHA256 = PaperContentPreparationService.sha256(content)
        // Any readable guide for this exact text is enough. Matching only the
        // current generator version would re-enqueue the whole library on every
        // version bump, which is regeneration, not preparation.
        var hasUsableGuide = false
        try queryBind("""
            SELECT g.generator_version, s.source_type
            FROM source_review_guides g
            JOIN sources s ON s.id = g.source_id
            WHERE g.source_id = ?
              AND g.source_sha256 = ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
            self.bind(stmt, 2, sourceSHA256)
        }) { stmt in
            guard let rawSourceType = self.string(stmt, 1),
                  let sourceType = StudioSourceType(rawValue: rawSourceType) else { return }
            hasUsableGuide = SourceReviewGuide.isCompatible(
                generatorVersion: Int(sqlite3_column_int(stmt, 0)),
                sourceType: sourceType
            )
        }

        if hasUsableGuide {
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        try execBind("""
            INSERT INTO source_review_guide_queue
                (source_id, source_sha256, enqueued_at, attempt_count, last_error)
            VALUES (?, ?, ?, 0, NULL)
            ON CONFLICT(source_id) DO UPDATE SET
                source_sha256 = excluded.source_sha256,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
            WHERE source_review_guide_queue.source_sha256 != excluded.source_sha256
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, sourceSHA256)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
        }
    }

    /// A source becomes eligible only when `source_content` is its stable
    /// canonical derivative. Papers and web articles must have completed the
    /// current cleanup contract; transcript-backed source types are canonical
    /// when their ready `source_content` row is committed.
    func reconcileSourceReviewGuidePreparation(sourceID: String) throws {
        var content: String?
        try queryBind("""
            SELECT sc.content
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            WHERE s.id = ?
              AND s.state = 'ready'
              AND s.status = 'active'
              AND CASE
                    WHEN s.source_type = 'paper' THEN
                        pp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND pp.clean_sha256 IS NOT NULL
                    WHEN s.source_type IN ('article', 'manual', 'unclassified') THEN
                        ap.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND ap.clean_sha256 IS NOT NULL
                    ELSE 1
                  END
              AND NOT EXISTS (
                  SELECT 1
                  FROM canonical_content_cleanup_queue cq
                  WHERE cq.source_id = s.id
              )
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in content = self.string(stmt, 0) }

        if let content {
            try enqueueSourceReviewGuidePreparation(sourceID: sourceID, content: content)
        } else {
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
        }
    }

    /// The one place preparation is ever scheduled: a review is starting and
    /// this source has no usable guide. Nothing enqueues speculatively.
    func ensureSourceReviewGuidePreparation(sourceID: String) throws {
        try reconcileSourceReviewGuidePreparation(sourceID: sourceID)
    }

    /// Saving a source never schedules preparation. It only retires a pending
    /// row, whose recorded attempt describes text that has just changed; the
    /// next review request recreates it against the new canonical text.
    func retireSourceReviewGuidePreparation(sourceID: String) throws {
        try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    /// The requested source's pending preparation, validated against the exact
    /// canonical text that was queued. There is no ordered backlog to pick from:
    /// preparation is always for the one source a review is about to start.
    func sourceReviewGuideCandidate(sourceID: String) throws -> SourceReviewGuideCandidate? {
        var row: (
            sourceID: String,
            sourceType: StudioSourceType,
            title: String,
            content: String,
            queuedSHA256: String,
            attemptCount: Int
        )?
        try queryBind("""
            SELECT q.source_id,
                   s.source_type,
                   COALESCE(sp.title, 'Untitled'),
                   sc.content,
                   q.source_sha256,
                   q.attempt_count
            FROM source_review_guide_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            LEFT JOIN source_projection sp ON sp.id = s.id
            WHERE q.source_id = ?
              AND s.state = 'ready'
              AND s.status = 'active'
              AND CASE
                    WHEN s.source_type = 'paper' THEN
                        pp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND pp.clean_sha256 IS NOT NULL
                    WHEN s.source_type IN ('article', 'manual', 'unclassified') THEN
                        ap.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND ap.clean_sha256 IS NOT NULL
                    ELSE 1
                  END
              AND NOT EXISTS (
                  SELECT 1
                  FROM canonical_content_cleanup_queue cq
                  WHERE cq.source_id = s.id
              )
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let resolvedSourceID = self.string(stmt, 0),
                  let sourceTypeRaw = self.string(stmt, 1),
                  let sourceType = StudioSourceType(rawValue: sourceTypeRaw),
                  let title = self.string(stmt, 2),
                  let content = self.string(stmt, 3),
                  let queuedSHA256 = self.string(stmt, 4) else { return }
            row = (
                resolvedSourceID,
                sourceType,
                title,
                content,
                queuedSHA256,
                Int(sqlite3_column_int(stmt, 5))
            )
        }
        guard let row else { return nil }
        guard !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "Canonical source content is empty before review preparation for \(row.sourceID)."
            )
        }
        let sourceSHA256 = PaperContentPreparationService.sha256(row.content)
        guard sourceSHA256 == row.queuedSHA256 else {
            throw KnowledgeStoreError.invalidData(
                "Canonical source content changed before review preparation for \(row.sourceID)."
            )
        }
        return SourceReviewGuideCandidate(
            sourceID: row.sourceID,
            sourceType: row.sourceType,
            title: row.title,
            content: row.content,
            sourceSHA256: sourceSHA256,
            attemptCount: row.attemptCount
        )
    }

    func sourceReviewGuideQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_review_guide_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func recordSourceReviewGuideFailure(sourceID: String, message: String) throws {
        try execBind("""
            UPDATE source_review_guide_queue
            SET attempt_count = attempt_count + 1,
                last_error = ?,
                enqueued_at = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, message)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 3, sourceID)
        }
    }

    func sourceReviewGuideFailure(sourceID: String) throws -> String? {
        var message: String?
        try queryBind(
            "SELECT last_error FROM source_review_guide_queue WHERE source_id = ? LIMIT 1",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { stmt in message = self.string(stmt, 0) }
        return message
    }

    func applySourceReviewGuide(candidate: SourceReviewGuideCandidate, guide: String) throws {
        let trimmedGuide = guide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuide.isEmpty else {
            throw KnowledgeStoreError.invalidData("Review guide generation returned empty content.")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            var currentContent: String?
            try queryBind("""
                SELECT sc.content
                FROM sources s
                JOIN source_content sc ON sc.source_id = s.id
                WHERE s.id = ?
                  AND s.state = 'ready'
                  AND s.status = 'active'
                LIMIT 1
            """, bind: { stmt in
                self.bind(stmt, 1, candidate.sourceID)
            }) { stmt in currentContent = self.string(stmt, 0) }
            guard let currentContent,
                  PaperContentPreparationService.sha256(currentContent) == candidate.sourceSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Source text changed while its review guide was being prepared; it will be retried."
                )
            }
            let generatedAt = Date()
            try execBind("""
                INSERT INTO source_review_guides
                    (source_id, source_sha256, guide, generator_version, generated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source_sha256 = excluded.source_sha256,
                    guide = excluded.guide,
                    generator_version = excluded.generator_version,
                    generated_at = excluded.generated_at
            """) { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, candidate.sourceSHA256)
                bind(stmt, 3, trimmedGuide)
                sqlite3_bind_int(stmt, 4, Int32(SourceReviewGuide.currentVersion))
                sqlite3_bind_double(stmt, 5, generatedAt.timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            try queuePublishedSourceFilesRefresh(sourceID: candidate.sourceID)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadSourceReviewGuide(_ sourceID: String) throws -> SourceReviewGuide? {
        var result: SourceReviewGuide?
        try queryBind("""
            SELECT rg.source_sha256, rg.guide, rg.generator_version, rg.generated_at,
                   sc.content, s.source_type
            FROM source_review_guides rg
            JOIN sources s ON s.id = rg.source_id
            JOIN source_content sc ON sc.source_id = rg.source_id
            WHERE rg.source_id = ?
              AND s.state = 'ready'
              AND s.status = 'active'
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let sourceSHA256 = self.string(stmt, 0),
                  let guide = self.string(stmt, 1),
                  let content = self.string(stmt, 4),
                  let rawSourceType = self.string(stmt, 5),
                  let sourceType = StudioSourceType(rawValue: rawSourceType),
                  SourceReviewGuide.isCompatible(
                    generatorVersion: Int(sqlite3_column_int(stmt, 2)),
                    sourceType: sourceType
                  ),
                  PaperContentPreparationService.sha256(content) == sourceSHA256 else { return }
            result = SourceReviewGuide(
                sourceSHA256: sourceSHA256,
                guide: guide,
                generatorVersion: Int(sqlite3_column_int(stmt, 2)),
                generatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            )
        }
        return result
    }

}
