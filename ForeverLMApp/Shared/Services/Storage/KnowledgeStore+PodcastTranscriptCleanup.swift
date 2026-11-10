// KnowledgeStore: podcast transcript ad cleanup.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - Podcast transcript ad cleanup

    static let maximumPodcastTranscriptCleanupAttempts = 3

    /// The next episodes the clean-up drain works on: one the learner asked to
    /// be formatted first, then rows that have not failed, transcripts owed
    /// their formatting ahead of the ad backlog, oldest first.
    ///
    /// A row owed the formatting pass is offered for it only while its stored
    /// text is still the raw text it was queued for. A transcript replaced
    /// since (YouTube captions, the learner's own speaker names, a synced
    /// copy) is someone's text and is not formatted over: the row falls back
    /// to the ad pass, and loses its place and its exemption from hiding, here.
    ///
    /// - Parameter formattingOnly: only rows owed the formatting pass, as past
    ///   the daily background cap, where the ad backlog waits for the next day
    ///   but a transcript just fetched is still formatted.
    func podcastTranscriptCleanupCandidates(
        limit: Int,
        formattingOnly: Bool = false
    ) throws -> [PodcastTranscriptCleanupCandidate] {
        guard limit > 0 else { return [] }
        try reviveReasoningRejectedPodcastTranscriptCleanups()
        while true {
            var results: [PodcastTranscriptCleanupCandidate] = []
            var replaced: [(sourceID: String, formatInputSHA256: String)] = []
            try queryBind("""
                SELECT s.id,
                       COALESCE(p.title, 'Untitled episode'),
                       COALESCE(NULLIF(p.show_name, ''), NULLIF(p.domain, ''), 'Podcast'),
                       sc.content,
                       q.format_input_sha256
                FROM podcast_transcript_cleanup_queue q
                JOIN sources s ON s.id = q.source_id
                JOIN podcasts p ON p.source_id = s.id
                JOIN source_content sc ON sc.source_id = s.id
                LEFT JOIN podcast_transcript_preparations prep ON prep.source_id = s.id
                WHERE s.source_type = 'podcast'
                  AND s.state = 'ready'
                  AND s.status = 'active'
                  AND TRIM(sc.content) != ''
                  AND q.target_version <= \(PodcastTranscriptCleanupMetadata.currentVersion)
                  AND q.attempt_count < \(Self.maximumPodcastTranscriptCleanupAttempts)
                  AND COALESCE(prep.cleaner_version, 0) < q.target_version
                  AND (? = 0 OR q.format_input_sha256 IS NOT NULL)
                  -- A bulk re-queue waits for the learner (schema 135).
                  AND \(Self.bulkHoldExclusion(.podcastTranscriptCleanup))
                  AND (q.learner_asked = 1 OR (\(Self.podcastEpisodeVisibleSQL(source: "s", podcast: "p"))))
                ORDER BY q.learner_asked DESC,
                         CASE WHEN q.last_error IS NULL THEN 0 ELSE 1 END,
                         CASE WHEN q.format_input_sha256 IS NULL THEN 1 ELSE 0 END,
                         q.enqueued_at,
                         s.id
                LIMIT ?
            """, bind: { stmt in
                sqlite3_bind_int(stmt, 1, formattingOnly ? 1 : 0)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }) { stmt in
                guard let sourceID = string(stmt, 0),
                      let title = string(stmt, 1),
                      let podcastName = string(stmt, 2),
                      let input = string(stmt, 3) else { return }
                let inputSHA256 = PaperContentPreparationService.sha256(input)
                let formatInputSHA256 = string(stmt, 4)
                if let formatInputSHA256, formatInputSHA256 != inputSHA256 {
                    replaced.append((sourceID, formatInputSHA256))
                    return
                }
                results.append(PodcastTranscriptCleanupCandidate(
                    sourceID: sourceID,
                    title: title,
                    podcastName: podcastName,
                    input: input,
                    inputSHA256: inputSHA256,
                    formatsTranscript: formatInputSHA256 != nil
                ))
            }
            guard !replaced.isEmpty else { return results }
            // Each pass takes at least one row out of the formatting pass, so
            // this ends; the next selects what the batch should hold now.
            for row in replaced {
                try execBind("""
                    UPDATE podcast_transcript_cleanup_queue
                    SET format_input_sha256 = NULL, learner_asked = 0
                    WHERE source_id = ? AND format_input_sha256 = ?
                """) { stmt in
                    bind(stmt, 1, row.sourceID)
                    bind(stmt, 2, row.formatInputSHA256)
                }
            }
        }
    }

    func podcastTranscriptCleanupQueueCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM podcast_transcript_cleanup_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN podcasts p ON p.source_id = s.id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN podcast_transcript_preparations prep ON prep.source_id = s.id
            WHERE s.source_type = 'podcast'
              AND s.state = 'ready'
              AND s.status = 'active'
              AND TRIM(sc.content) != ''
              AND q.attempt_count < \(Self.maximumPodcastTranscriptCleanupAttempts)
              AND COALESCE(prep.cleaner_version, 0) < q.target_version
              -- A bulk re-queue waits for the learner (schema 135).
              AND \(Self.bulkHoldExclusion(.podcastTranscriptCleanup))
              AND (q.learner_asked = 1 OR (\(Self.podcastEpisodeVisibleSQL(source: "s", podcast: "p"))))
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Until 2026-09-03 the cleanup request asked OpenRouter to turn reasoning
    /// off entirely, and first-generation GPT-5 models refused with a 400
    /// ("Reasoning is mandatory for this endpoint and cannot be disabled").
    /// That failure was counted as a real attempt, so an episode on such a
    /// model burned its whole budget without the cleaner ever reading a word.
    /// The request now asks for the lowest effort the model accepts; give those
    /// rows their attempts back so the next drain picks them up. Idempotent and
    /// bounded by the queue's size, so it can run ahead of every drain.
    private func reviveReasoningRejectedPodcastTranscriptCleanups() throws {
        try exec("""
            UPDATE podcast_transcript_cleanup_queue
            SET attempt_count = 0,
                last_error = NULL
            WHERE attempt_count > 0
              AND last_error LIKE '%Reasoning is mandatory%'
        """)
    }

    func recordPodcastTranscriptCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String,
        consumesAttempt: Bool
    ) throws {
        try execBind("""
            UPDATE podcast_transcript_cleanup_queue
            SET attempt_count = attempt_count + ?,
                last_error = ?,
                source_sha256 = ?,
                enqueued_at = ?
            WHERE source_id = ?
        """) { stmt in
            sqlite3_bind_int(stmt, 1, consumesAttempt ? 1 : 0)
            bind(stmt, 2, message)
            bind(stmt, 3, sourceSHA256)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 5, sourceID)
        }
    }

    func loadPodcastTranscriptPreparation(
        _ sourceID: String
    ) throws -> (input: String, metadata: PodcastTranscriptCleanupMetadata)? {
        var result: (String, PodcastTranscriptCleanupMetadata)?
        try queryBind("""
            SELECT input_content, input_sha256, clean_sha256, cleaner_version, prepared_at
            FROM podcast_transcript_preparations
            WHERE source_id = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let input = string(stmt, 0),
                  let inputSHA = string(stmt, 1),
                  let cleanSHA = string(stmt, 2) else { return }
            let preparedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            result = (input, PodcastTranscriptCleanupMetadata(
                cleanerVersion: Int(sqlite3_column_int(stmt, 3)),
                inputSHA256: inputSHA,
                cleanSHA256: cleanSHA,
                preparedAt: preparedAt
            ))
        }
        return result
    }

    /// Whether `text` is what an episode's stored clean-up was made from, while
    /// storage holds what it became. A loaded row keeps the transcript it was
    /// given until the drain's refresh reaches it, and a `saveSource` of that
    /// row in between (a rename, a hide) would write the raw or ad-laden text
    /// back over the formatted one and leave the record saying the pass ran.
    func isPodcastTranscriptCleanupInput(_ text: String, sourceID: String) throws -> Bool {
        var hashes: (input: String, clean: String)?
        try queryBind("""
            SELECT input_sha256, clean_sha256
            FROM podcast_transcript_preparations
            WHERE source_id = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let input = string(stmt, 0), let clean = string(stmt, 1) else { return }
            hashes = (input, clean)
        }
        guard let hashes, hashes.input != hashes.clean else { return false }
        return PaperContentPreparationService.sha256(text) == hashes.input
    }

    func upsertPodcastTranscriptPreparation(
        sourceID: String,
        input: String,
        metadata: PodcastTranscriptCleanupMetadata
    ) throws {
        try execBind("""
            INSERT INTO podcast_transcript_preparations
                (source_id, input_content, input_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                input_content = excluded.input_content,
                input_sha256 = excluded.input_sha256,
                clean_sha256 = excluded.clean_sha256,
                cleaner_version = excluded.cleaner_version,
                prepared_at = excluded.prepared_at
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, input)
            bind(stmt, 3, metadata.inputSHA256)
            bind(stmt, 4, metadata.cleanSHA256)
            sqlite3_bind_int(stmt, 5, Int32(metadata.cleanerVersion))
            if let preparedAt = metadata.preparedAt {
                sqlite3_bind_double(stmt, 6, preparedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
        }
    }

    func applyPodcastTranscriptCleanup(
        candidate: PodcastTranscriptCleanupCandidate,
        prepared: PreparedPodcastTranscriptCleanup
    ) throws {
        guard prepared.metadata.cleanerVersion == PodcastTranscriptCleanupMetadata.currentVersion,
              prepared.metadata.inputSHA256 == candidate.inputSHA256,
              PaperContentPreparationService.sha256(prepared.input) == candidate.inputSHA256,
              PaperContentPreparationService.sha256(prepared.clean) == prepared.metadata.cleanSHA256,
              !prepared.clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prepared.clean.count * 100 >= prepared.input.count * 55 else {
            throw KnowledgeStoreError.invalidData(
                "Podcast transcript cleanup hashes, version, or deletion limit did not validate."
            )
        }

        try exec("BEGIN IMMEDIATE")
        do {
            guard let current = try loadSourceContent(candidate.sourceID),
                  PaperContentPreparationService.sha256(current) == candidate.inputSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Podcast transcript changed while ad cleanup was running; it will be retried."
                )
            }
            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, prepared.clean)
            }
            try upsertPodcastTranscriptPreparation(
                sourceID: candidate.sourceID,
                input: prepared.input,
                metadata: prepared.metadata
            )
            try execBind("UPDATE podcasts SET word_count = ? WHERE source_id = ?") { stmt in
                sqlite3_bind_int64(
                    stmt,
                    1,
                    Int64(prepared.clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
                )
                bind(stmt, 2, candidate.sourceID)
            }
            try invalidateCanonicalContentIndexes(sourceID: candidate.sourceID)
            try retireSourceReviewGuidePreparation(sourceID: candidate.sourceID)
            try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Restores recent cleanup results from their versioned, hash-proven input.
    /// Used by a guarded maintenance pilot when review finds that the prompt
    /// contract was too broad; the source, derivatives, durable queue, and sync
    /// rail are repaired together rather than by editing SQLite out of band.
    func restorePodcastTranscriptCleanups(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        var sourceIDs: [String] = []
        try queryBind("""
            SELECT source_id
            FROM podcast_transcript_preparations
            ORDER BY prepared_at DESC, source_id
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }) { stmt in
            if let sourceID = string(stmt, 0) { sourceIDs.append(sourceID) }
        }

        var restored: [String] = []
        for sourceID in sourceIDs {
            try exec("BEGIN IMMEDIATE")
            do {
                guard let preparation = try loadPodcastTranscriptPreparation(sourceID) else {
                    try exec("COMMIT")
                    continue
                }
                try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                    bind(stmt, 1, sourceID)
                    bind(stmt, 2, preparation.input)
                }
                try execBind("UPDATE podcasts SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(
                        stmt,
                        1,
                        Int64(preparation.input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
                    )
                    bind(stmt, 2, sourceID)
                }
                try execBind("DELETE FROM podcast_transcript_preparations WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
                try invalidateCanonicalContentIndexes(sourceID: sourceID)
                try enqueueSourceListenableContentPreparation(sourceID: sourceID, content: preparation.input)
                try retireSourceReviewGuidePreparation(sourceID: sourceID)
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
                noteStoreChanged()
                try exec("COMMIT")
                restored.append(sourceID)
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
        return restored
    }

}
