import Foundation
import SQLite3

/// One podcast episode queued for the transcript completeness audit
/// (`PodcastTranscriptDetruncationService`).
struct PodcastTranscriptDetruncationCandidate: Sendable, Equatable {
    let sourceID: String
    let title: String
    let podcastName: String
    let allowsFormatting: Bool
    /// The public Apple Podcasts episode whose TTML the audit fetches, once,
    /// for an episode this Mac stores no TTML for; nil when the TTML is here.
    let appleTrackID: Int64?
    /// Attempts that failed so far.
    let attemptCount: Int
}

/// What the audit reads for one episode: the stored transcript, and the TTML
/// it is measured against when this Mac keeps one.
struct PodcastTranscriptAuditInputs: Sendable {
    let transcript: String
    let rawTTML: String?
}

/// What the completeness audit found for one episode, as
/// `podcast_transcript_audits.outcome` keeps it.
enum PodcastTranscriptAuditOutcome: String, Sendable, Equatable {
    /// Hydration wrote the transcript from a whole extraction of the TTML.
    case hydrated
    /// The stored transcript holds the episode, or stops early at a place the
    /// retired cap could not have put it (a closing read the ad pass removed).
    case complete
    /// The stored transcript stopped at the retired cap, and the whole episode
    /// replaced it.
    case restored
    /// The stored transcript's ending is not in the episode text, so nothing
    /// could be said about it and it was left as it is.
    case unplaced
    /// Apple Podcasts has no transcript for the episode to measure against.
    case noTranscript = "no_transcript"
}

struct PodcastTranscriptAuditRecord: Sendable, Equatable {
    let outcome: PodcastTranscriptAuditOutcome
    /// The TTML the transcript was measured against or derived from; nil when
    /// Apple had none.
    let ttmlSHA256: String?
}

extension KnowledgeStore {

    /// Attempts before an episode stays in the queue as a record of what was
    /// tried. A stored TTML that cannot be parsed fails every time; a fetch
    /// fails for a network, an expired token or a rate limit, which pass, so
    /// the attempts are spread out (`podcastTranscriptAuditRetryDelay`).
    static let maximumPodcastTranscriptDetruncationAttempts = 5

    /// How long an episode waits after a failed attempt: 15 minutes, then an
    /// hour, 4 hours and 16 hours.
    static func podcastTranscriptAuditRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        15 * 60 * pow(4, Double(max(0, attempt - 1)))
    }

    /// `p` (`podcasts`) holds a TTML. `octet_length` is answered from the
    /// record header, so no TTML is read to answer it.
    static let podcastStoredTTMLSQL = "COALESCE(octet_length(p.raw_ttml), 0) > 0"

    /// `p` (`podcasts`) of `s` (`sources`) is a public Apple Podcasts episode
    /// (`apple-podcast://episode/<digits>`) whose stored text did not come from
    /// a YouTube video's captions, so one fetch of Apple's TTML can measure it.
    /// A private feed's placeholder has no public id to fetch by.
    static let podcastFetchableFromAppleSQL = """
        p.url GLOB 'apple-podcast://episode/[0-9]*'
        AND substr(p.url, 25) NOT GLOB '*[^0-9]*'
        AND COALESCE(s.public_url, '') NOT LIKE '%youtube.com/%'
        AND COALESCE(s.public_url, '') NOT LIKE '%youtu.be/%'
        """

    /// An episode the audit can measure, with or without a stored TTML.
    static let podcastTranscriptAuditableSQL =
        "(\(podcastStoredTTMLSQL) OR (\(podcastFetchableFromAppleSQL)))"

    /// Queued episodes due for an attempt, of one kind: those whose TTML is
    /// stored here (`fetchingTTML` false), measured locally, or those the audit
    /// fetches Apple's TTML for.
    func podcastTranscriptDetruncationCandidates(
        fetchingTTML: Bool,
        limit: Int,
        now: Date = Date()
    ) throws -> [PodcastTranscriptDetruncationCandidate] {
        guard limit > 0 else { return [] }
        let kind = fetchingTTML
            ? "NOT (\(Self.podcastStoredTTMLSQL)) AND \(Self.podcastFetchableFromAppleSQL)"
            : Self.podcastStoredTTMLSQL
        var candidates: [PodcastTranscriptDetruncationCandidate] = []
        try queryBind("""
            SELECT q.source_id,
                   COALESCE(NULLIF(p.title, ''), 'Untitled episode'),
                   COALESCE(NULLIF(p.show_name, ''), NULLIF(p.domain, ''), 'Podcast'),
                   CASE WHEN NOT EXISTS (
                            SELECT 1 FROM hidden_sources hs WHERE hs.source_id IN (s.id, s.wire_key)
                        )
                        AND NOT EXISTS (
                            SELECT 1 FROM hidden_podcast_episodes hpe WHERE hpe.source_id IN (s.id, s.wire_key)
                        )
                        AND (
                            EXISTS (
                                SELECT 1 FROM visible_podcast_episode_overrides vpeo
                                WHERE vpeo.source_id IN (s.id, s.wire_key)
                            )
                            OR NOT EXISTS (
                                SELECT 1 FROM hidden_podcast_shows hps
                                WHERE hps.show_name = p.domain
                                   OR hps.show_name = p.show_name
                            )
                        )
                   THEN 1 ELSE 0 END,
                   p.url,
                   q.attempt_count
            FROM podcast_transcript_detruncation_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN podcasts p ON p.source_id = q.source_id
            WHERE q.attempt_count < ?
              AND (q.retry_after IS NULL OR q.retry_after <= ?)
              AND s.status = 'active'
              AND s.source_type = 'podcast'
              AND EXISTS (SELECT 1 FROM source_content sc WHERE sc.source_id = q.source_id)
              AND \(kind)
            ORDER BY q.attempt_count ASC, q.enqueued_at ASC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(Self.maximumPodcastTranscriptDetruncationAttempts))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        }) { stmt in
            guard let sourceID = self.string(stmt, 0) else { return }
            // An address the SQL accepts and Int64 cannot hold is handed over
            // without an id, and the audit records that there is nothing to
            // fetch rather than meeting the row again on every drain.
            let trackID = fetchingTTML ? Self.extractTrackIdFromURL(self.string(stmt, 4) ?? "") : nil
            candidates.append(
                PodcastTranscriptDetruncationCandidate(
                    sourceID: sourceID,
                    title: self.string(stmt, 1) ?? "Untitled episode",
                    podcastName: self.string(stmt, 2) ?? "Podcast",
                    allowsFormatting: sqlite3_column_int64(stmt, 3) == 1,
                    appleTrackID: trackID,
                    attemptCount: Int(sqlite3_column_int64(stmt, 5))
                )
            )
        }
        return candidates
    }

    /// Queued episodes due for an attempt now, of both kinds. A row that failed
    /// its last attempt and waits for its retry time is not counted, and neither
    /// is a row that ran out of attempts, which stays as a record.
    func podcastTranscriptDetruncationQueueCount(now: Date = Date()) throws -> Int {
        var count = 0
        try queryBind("""
            SELECT COUNT(*)
            FROM podcast_transcript_detruncation_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN podcasts p ON p.source_id = q.source_id
            WHERE q.attempt_count < ?
              AND (q.retry_after IS NULL OR q.retry_after <= ?)
              AND s.status = 'active'
              AND s.source_type = 'podcast'
              AND EXISTS (SELECT 1 FROM source_content sc WHERE sc.source_id = q.source_id)
              AND \(Self.podcastTranscriptAuditableSQL)
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(Self.maximumPodcastTranscriptDetruncationAttempts))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func podcastTranscriptAuditInputs(sourceID: String) throws -> PodcastTranscriptAuditInputs? {
        var inputs: PodcastTranscriptAuditInputs?
        try queryBind("""
            SELECT sc.content, p.raw_ttml
            FROM podcasts p
            JOIN source_content sc ON sc.source_id = p.source_id
            WHERE p.source_id = ?
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            inputs = PodcastTranscriptAuditInputs(
                transcript: self.string(stmt, 0) ?? "",
                rawTTML: self.string(stmt, 1).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return inputs
    }

    /// Records what the audit found and takes the episode off the queue. The
    /// record is what keeps the episode from being audited again: the ad pass
    /// that follows a restore saves the transcript without its TTML, and that
    /// save must not put the episode back.
    func recordPodcastTranscriptAudit(
        sourceID: String,
        ttmlSHA256: String?,
        outcome: PodcastTranscriptAuditOutcome
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertPodcastTranscriptAudit(sourceID: sourceID, ttmlSHA256: ttmlSHA256, outcome: outcome)
            try execBind(
                "DELETE FROM podcast_transcript_detruncation_queue WHERE source_id = ?"
            ) { stmt in
                self.bind(stmt, 1, sourceID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Replaces a transcript the retired cap cut with the whole episode and
    /// records the audit, in one transaction.
    ///
    /// The text is written only while the stored transcript is still
    /// `auditedTranscript`, the one the audit measured: a transcript hydrated,
    /// cleaned or edited since is newer than the measurement, and the episode
    /// stays queued to be measured again (false is returned). What follows any
    /// new transcript follows this one: the ad pass is staged for the whole
    /// episode and its preparation against the cut text goes (a hidden episode
    /// gets no ad pass), Listen and the review guide are prepared again, the
    /// full-text and embedding rows and the generation-2 text satellite are
    /// renewed (`invalidateCanonicalContentIndexes`), the word count follows,
    /// and the record is marked for CloudKit. A fetched TTML is kept, as
    /// hydration keeps one; a stored one is left as it is.
    ///
    /// The downgrade guard `saveTranscript` holds applies here too, though a
    /// whole episode is never shorter than the part the cap left.
    @discardableResult
    func restorePodcastTranscript(
        sourceID: String,
        auditedTranscript: String,
        restoredTranscript: String,
        fetchedTTML: String?,
        ttmlSHA256: String
    ) throws -> Bool {
        guard Double(restoredTranscript.count)
                >= Double(auditedTranscript.count) * Self.podcastTranscriptDowngradeFloor else {
            throw KnowledgeStoreError.invalidData(
                """
                Refusing to replace the \(auditedTranscript.count)-character transcript for \
                \(sourceID) with \(restoredTranscript.count) characters.
                """
            )
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("UPDATE source_content SET content = ? WHERE source_id = ? AND content = ?") { stmt in
                self.bind(stmt, 1, restoredTranscript)
                self.bind(stmt, 2, sourceID)
                self.bind(stmt, 3, auditedTranscript)
            }
            guard sqlite3_changes(db) > 0 else {
                try exec("COMMIT")
                return false
            }
            let wordCount = Self.storedWordCount(of: restoredTranscript)
            if let fetchedTTML {
                try execBind("UPDATE podcasts SET raw_ttml = ?, word_count = ? WHERE source_id = ?") { stmt in
                    self.bind(stmt, 1, fetchedTTML)
                    sqlite3_bind_int64(stmt, 2, Int64(wordCount))
                    self.bind(stmt, 3, sourceID)
                }
            } else {
                try execBind("UPDATE podcasts SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(wordCount))
                    self.bind(stmt, 2, sourceID)
                }
            }
            try execBind("DELETE FROM podcast_transcript_preparations WHERE source_id = ?") { stmt in
                self.bind(stmt, 1, sourceID)
            }
            try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
            try enqueueSourceListenableContentPreparation(sourceID: sourceID, content: restoredTranscript)
            try retireSourceReviewGuidePreparation(sourceID: sourceID)
            try invalidateCanonicalContentIndexes(sourceID: sourceID)
            try upsertPodcastTranscriptAudit(sourceID: sourceID, ttmlSHA256: ttmlSHA256, outcome: .restored)
            try execBind(
                "DELETE FROM podcast_transcript_detruncation_queue WHERE source_id = ?"
            ) { stmt in
                self.bind(stmt, 1, sourceID)
            }
            noteStoreChanged()
            try exec("COMMIT")
            return true
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func removePodcastTranscriptFromDetruncationQueue(sourceID: String) throws {
        try execBind(
            "DELETE FROM podcast_transcript_detruncation_queue WHERE source_id = ?"
        ) { stmt in
            self.bind(stmt, 1, sourceID)
        }
    }

    func podcastTranscriptAudit(sourceID: String) throws -> PodcastTranscriptAuditRecord? {
        var record: PodcastTranscriptAuditRecord?
        try queryBind(
            "SELECT outcome, ttml_sha256 FROM podcast_transcript_audits WHERE source_id = ?",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { stmt in
            guard let outcome = self.string(stmt, 0).flatMap(PodcastTranscriptAuditOutcome.init(rawValue:)) else { return }
            record = PodcastTranscriptAuditRecord(outcome: outcome, ttmlSHA256: self.string(stmt, 1))
        }
        return record
    }

    /// A failed attempt: counted, and the episode waits `retryAfter` before
    /// the next one.
    func recordPodcastTranscriptDetruncationFailure(
        sourceID: String,
        message: String,
        retryAfter: Date?
    ) throws {
        try execBind("""
            UPDATE podcast_transcript_detruncation_queue
            SET attempt_count = attempt_count + 1, last_error = ?, retry_after = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, String(message.prefix(500)))
            if let retryAfter {
                sqlite3_bind_double(stmt, 2, retryAfter.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            bind(stmt, 3, sourceID)
        }
    }

    /// Queue one episode for the completeness audit unless it has been audited
    /// (or hydrated from a whole TTML) already. The audit record, not the
    /// transcript, decides, which is what keeps the audit from fighting the ad
    /// pass on a sponsor-heavy show: the deletions that follow an audit do not
    /// put the episode back. Returns whether the episode was queued.
    @discardableResult
    func enqueuePodcastTranscriptDetruncationIfNeeded(sourceID: String) throws -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO podcast_transcript_detruncation_queue
                (source_id, enqueued_at, attempt_count, last_error, retry_after)
            SELECT s.id, ?, 0, NULL, NULL
            FROM sources s
            JOIN podcasts p ON p.source_id = s.id
            WHERE s.id = ?
              AND s.source_type = 'podcast'
              AND s.status = 'active'
              AND EXISTS (
                  SELECT 1 FROM source_content sc
                  WHERE sc.source_id = s.id AND TRIM(sc.content) != ''
              )
              AND NOT EXISTS (
                  SELECT 1 FROM podcast_transcript_audits a WHERE a.source_id = s.id
              )
              AND \(Self.podcastTranscriptAuditableSQL)
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
            self.bind(stmt, 2, sourceID)
        }
        return sqlite3_changes(db) > 0
    }

    /// Records that hydration itself produced this transcript from a complete
    /// extraction of `ttmlSHA256`, so the audit never needs to look at it.
    /// Inside the caller's transaction.
    func recordPodcastTranscriptFullExtraction(
        sourceID: String,
        ttmlSHA256: String
    ) throws {
        try upsertPodcastTranscriptAudit(sourceID: sourceID, ttmlSHA256: ttmlSHA256, outcome: .hydrated)
        try execBind(
            "DELETE FROM podcast_transcript_detruncation_queue WHERE source_id = ?"
        ) { stmt in
            self.bind(stmt, 1, sourceID)
        }
    }

    private func upsertPodcastTranscriptAudit(
        sourceID: String,
        ttmlSHA256: String?,
        outcome: PodcastTranscriptAuditOutcome
    ) throws {
        try execBind("""
            INSERT INTO podcast_transcript_audits (source_id, ttml_sha256, outcome, audited_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                ttml_sha256 = excluded.ttml_sha256,
                outcome = excluded.outcome,
                audited_at = excluded.audited_at
        """) { stmt in
            self.bind(stmt, 1, sourceID)
            self.bind(stmt, 2, ttmlSHA256)
            self.bind(stmt, 3, outcome.rawValue)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSinceReferenceDate)
        }
    }
}

extension KnowledgeStore {

    /// The band of stored lengths worth one comparison against a fresh caption
    /// fetch.
    ///
    /// A video keeps no raw transcript, so nothing local can say how much of one
    /// is missing — which is also why this is a band rather than the exact
    /// 50,000 the old check used. Measured on a real library, the lengths run
    /// smoothly from 40,000 to 58,000 with two transcripts sitting exactly on
    /// the cap and a third at 51,013 that ends mid-word: captions were capped
    /// before the formatting pass, and formatting then added punctuation and
    /// paragraph breaks, so a capped video can land either side of the round
    /// number. The band is deliberately wider than the cap in both directions
    /// and costs a healthy video one caption fetch, once, ever.
    static let legacyYouTubeCapSuspectRange = 47_000...53_000

    /// True when this video's transcript is in the suspect band and has never
    /// been compared against a fresh fetch. The stamp is what keeps a healthy
    /// video of that length from re-fetching on every open.
    func youTubeLegacyCapNeedsVerification(sourceID: String) throws -> Bool {
        var needs = false
        try queryBind("""
            SELECT 1
            FROM sources s
            JOIN videos v ON v.source_id = s.id
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.id = ?
              AND s.status = 'active'
              AND v.legacy_cap_verified_at IS NULL
              AND length(sc.content) BETWEEN ? AND ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(Self.legacyYouTubeCapSuspectRange.lowerBound))
            sqlite3_bind_int(stmt, 3, Int32(Self.legacyYouTubeCapSuspectRange.upperBound))
        }) { _ in
            needs = true
        }
        return needs
    }

    /// Records that this video's transcript has been measured against the
    /// captions it came from, whether or not it needed replacing.
    func markYouTubeLegacyCapVerified(sourceID: String) throws {
        try execBind("""
            UPDATE videos SET legacy_cap_verified_at = ? WHERE source_id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
            self.bind(stmt, 2, sourceID)
        }
    }
}
