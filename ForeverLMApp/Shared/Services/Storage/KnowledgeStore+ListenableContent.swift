// KnowledgeStore: listenable source content preparation.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - Listenable source content

    /// Couples the Listen derivative to canonical text. Callers invoke this in
    /// the same transaction that writes source_content, so stale narration can
    /// never survive a canonical-text change.
    ///
    /// The paid preparation is queued now only when automatic audio covers
    /// the source's kind, since automatic generation waits for the prepared
    /// derivative and never makes one. Any other change only retires the
    /// stale derivative, and Listen prepares when someone presses it
    /// (`ArticleSpeechService`, and the iPhone's own pass). Cleaner v19 queued
    /// a paid preparation for every one of ~1,380 re-cleaned sources nobody
    /// had asked to hear; on 2026-09-25 the product owner asked that a new import wait
    /// for a listener too, since most papers are read, not heard.
    func enqueueSourceListenableContentPreparation(
        sourceID: String,
        content: String
    ) throws {
        var eligibleSourceType: StudioSourceType?
        try queryBind("""
            SELECT s.source_type
            FROM sources s
            WHERE s.id = ?
              -- `error` is deliberate: a paper that failed the metadata gate has
              -- canonical text all the same, and Listen narrates the text. See
              -- StudioArticle.isEligibleForListenableContentPreparation.
              AND s.state IN ('ready', 'error')
              AND s.status = 'active'
              AND s.source_type IN ('article', 'paper')
              -- A spoken script (an explainer, an audio overview's carrier)
              -- is written for the ear and is never prepared; its URL lives on
              -- the articles row (`TextToSpeechPreparationPolicy.spokenScriptURLPrefixes`).
              AND NOT EXISTS (
                  SELECT 1 FROM articles a
                  WHERE a.source_id = s.id
                    AND (a.url LIKE 'foreverlm://explainer/%' OR a.url LIKE 'foreverlm://audio-overview/%')
              )
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue q WHERE q.source_id = s.id
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let rawType = self.string(stmt, 0) else { return }
            eligibleSourceType = StudioSourceType(rawValue: rawType)
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eligibleSourceType != nil, !trimmed.isEmpty else {
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        let sourceSHA256 = PaperContentPreparationService.sha256(trimmed)
        var alreadyPrepared = false
        try queryBind("""
            SELECT 1
            FROM source_listenable_content
            WHERE source_id = ?
              AND source_sha256 = ?
              AND generator_version = ?
              AND COALESCE(preparation_signature, '') LIKE ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, sourceSHA256)
            sqlite3_bind_int(stmt, 3, Int32(SourceListenableContentMetadata.currentVersion))
            bind(stmt, 4, "\(PaperNarrationFilter.preparationContractPrefix)%")
        }) { _ in alreadyPrepared = true }
        if alreadyPrepared {
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        try execBind("DELETE FROM source_listenable_content WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
        if let eligibleSourceType,
           !automaticAudioSourceTypes().contains(eligibleSourceType.rawValue) {
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }
        try execBind("""
            INSERT INTO source_listenable_content_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            VALUES (?, ?, ?, ?, 0, NULL)
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                source_sha256 = excluded.source_sha256,
                enqueued_at = excluded.enqueued_at,
                attempt_count = CASE
                    WHEN source_listenable_content_queue.source_sha256 = excluded.source_sha256
                    THEN source_listenable_content_queue.attempt_count ELSE 0 END,
                last_error = CASE
                    WHEN source_listenable_content_queue.source_sha256 = excluded.source_sha256
                    THEN source_listenable_content_queue.last_error ELSE NULL END
        """) { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(SourceListenableContentMetadata.currentVersion))
            bind(stmt, 3, sourceSHA256)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSinceReferenceDate)
        }
    }

    /// Queues one source's Listen preparation from its stored text, for
    /// automatic audio that found none ready: a kind switched on after the
    /// text arrived was never queued (`enqueueSourceListenableContentPreparation`).
    /// Returns whether the source is now queued. A row already queued is left
    /// as it is, so a bulk re-queue held for the learner stays held.
    @discardableResult
    func queueSourceListenableContentPreparation(sourceID: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            func isQueued() throws -> Bool {
                var queued = false
                try queryBind("SELECT 1 FROM source_listenable_content_queue WHERE source_id = ?", bind: { stmt in
                    bind(stmt, 1, sourceID)
                }) { _ in queued = true }
                return queued
            }
            if try !isQueued() {
                var content: String?
                try queryBind("SELECT content FROM source_content WHERE source_id = ?", bind: { stmt in
                    bind(stmt, 1, sourceID)
                }) { stmt in
                    content = self.string(stmt, 0)
                }
                if let content {
                    try enqueueSourceListenableContentPreparation(sourceID: sourceID, content: content)
                }
            }
            let queued = try isQueued()
            try exec("COMMIT")
            return queued
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func sourceListenableContentCandidates(limit: Int) throws -> [SourceListenableContentCandidate] {
        guard limit > 0 else { return [] }

        var results: [SourceListenableContentCandidate] = []
        var changedHashes: [(sourceID: String, sourceSHA256: String)] = []
        try queryBind("""
            SELECT q.source_id,
                   COALESCE(p.title, a.title, b.title, c.title, m.title, x.title, 'Untitled'),
                   s.source_type,
                   sc.content,
                   q.source_sha256
            FROM source_listenable_content_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN papers p ON p.source_id = s.id
            LEFT JOIN articles a ON a.source_id = s.id
            LEFT JOIN book_sources b ON b.source_id = s.id
            LEFT JOIN course_sources c ON c.source_id = s.id
            LEFT JOIN meeting_sources m ON m.source_id = s.id
            LEFT JOIN x_posts x ON x.source_id = s.id
            -- Matches the enqueue predicate: `error` sources carry canonical text
            -- too, and Listen narrates the text, not the bibliography.
            WHERE s.state IN ('ready', 'error')
              AND s.status = 'active'
              AND s.source_type IN ('article', 'paper')
              AND COALESCE(a.url, '') NOT LIKE 'foreverlm://explainer/%'
              AND COALESCE(a.url, '') NOT LIKE 'foreverlm://audio-overview/%'
              AND q.target_version <= \(SourceListenableContentMetadata.currentVersion)
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id
              )
              -- A bulk re-queue waits for the learner (schema 135).
              AND \(Self.bulkHoldExclusion(.listenPreparation))
            ORDER BY q.attempt_count,
                     s.date_added DESC,
                     q.enqueued_at,
                     q.source_id
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }) { stmt in
            guard let sourceID = string(stmt, 0),
                  let title = string(stmt, 1),
                  let rawType = string(stmt, 2),
                  let sourceType = StudioSourceType(rawValue: rawType),
                  let canonicalText = string(stmt, 3) else { return }
            let normalized = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            let actualHash = PaperContentPreparationService.sha256(normalized)
            results.append(SourceListenableContentCandidate(
                sourceID: sourceID,
                title: title,
                sourceType: sourceType,
                canonicalText: canonicalText,
                sourceSHA256: actualHash
            ))
            if self.string(stmt, 4) != actualHash {
                changedHashes.append((sourceID, actualHash))
            }
        }
        for changedHash in changedHashes {
            try? execBind("""
                UPDATE source_listenable_content_queue
                SET source_sha256 = ?, attempt_count = 0, last_error = NULL
                WHERE source_id = ?
            """) { update in
                bind(update, 1, changedHash.sourceSHA256)
                bind(update, 2, changedHash.sourceID)
            }
        }
        return results
    }

    func nextSourceListenableContentCandidate() throws -> SourceListenableContentCandidate? {
        try sourceListenableContentCandidates(limit: 1).first
    }

    func sourceListenableContentQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_listenable_content_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func recordSourceListenableContentFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String
    ) throws {
        try execBind("""
            UPDATE source_listenable_content_queue
            SET attempt_count = attempt_count + 1,
                last_error = ?,
                source_sha256 = ?,
                enqueued_at = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, message)
            bind(stmt, 2, sourceSHA256)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 4, sourceID)
        }
    }

    func applySourceListenableContent(
        candidate: SourceListenableContentCandidate,
        text: String,
        preparationSignature: String?
    ) throws {
        let narration = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MacArticleSpeechText.containsLetterOrDigit(narration) else {
            throw KnowledgeStoreError.invalidData("Listenable-content preparation returned no narratable text.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            guard let current = try loadSourceContent(candidate.sourceID),
                  PaperContentPreparationService.sha256(
                    current.trimmingCharacters(in: .whitespacesAndNewlines)
                  ) == candidate.sourceSHA256 else {
                throw KnowledgeStoreError.sourceContentChanged
            }
            try execBind("""
                INSERT INTO source_listenable_content
                    (source_id, source_sha256, content, generator_version, preparation_signature, prepared_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source_sha256 = excluded.source_sha256,
                    content = excluded.content,
                    generator_version = excluded.generator_version,
                    preparation_signature = excluded.preparation_signature,
                    prepared_at = excluded.prepared_at
            """) { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, candidate.sourceSHA256)
                bind(stmt, 3, narration)
                sqlite3_bind_int(stmt, 4, Int32(SourceListenableContentMetadata.currentVersion))
                bind(stmt, 5, preparationSignature)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
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

    func loadSourceListenableContent(_ sourceID: String) throws -> StoredSourceListenableContent? {
        var result: StoredSourceListenableContent?
        try queryBind("""
            SELECT content, source_sha256, generator_version, preparation_signature, prepared_at
            FROM source_listenable_content
            WHERE source_id = ?
              AND generator_version = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(SourceListenableContentMetadata.currentVersion))
        }) { stmt in
            guard let text = string(stmt, 0), let sourceSHA256 = string(stmt, 1) else { return }
            result = StoredSourceListenableContent(
                text: text,
                metadata: SourceListenableContentMetadata(
                    sourceSHA256: sourceSHA256,
                    generatorVersion: Int(sqlite3_column_int(stmt, 2)),
                    preparationSignature: string(stmt, 3),
                    characterCount: text.count,
                    preparedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
                )
            )
        }
        return result
    }

    /// Listen-ready length and preparation identity per source without loading
    /// the narration bodies into memory. This is the exact persisted derivative
    /// family consumed by Listen, not canonical source text.
    func sourceListenableContentSummaries(
        for sourceIDs: [String]
    ) throws -> [String: SourceListenableContentSummary] {
        let uniqueIDs = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return [:] }

        var summaries: [String: SourceListenableContentSummary] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < uniqueIDs.count {
            let chunk = Array(uniqueIDs[offset..<min(offset + chunkSize, uniqueIDs.count)])
            offset += chunkSize
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT source_id, LENGTH(content), preparation_signature
                FROM source_listenable_content
                WHERE generator_version = ?
                  AND source_id IN (\(placeholders))
            """
            try queryBind(sql, bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(SourceListenableContentMetadata.currentVersion))
                for (index, sourceID) in chunk.enumerated() {
                    self.bind(stmt, index + 2, sourceID)
                }
            }) { stmt in
                guard let sourceID = self.string(stmt, 0),
                      let characterCount = self.optionalInt(stmt, 1),
                      characterCount > 0 else { return }
                summaries[sourceID] = SourceListenableContentSummary(
                    characterCount: characterCount,
                    preparationSignature: self.string(stmt, 2)
                )
            }
        }
        return summaries
    }

}
