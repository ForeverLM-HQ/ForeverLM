import Foundation
import SQLite3

/// The day close's bookkeeping (schema 127): what this device has already
/// folded into understanding documents, and since when. The pass itself is
/// `DayClosePass`; these are the rows it reads and writes so a run that
/// repeats — at shutdown, at the evening hour, again before the morning's
/// review — finds only what is new.
extension KnowledgeStore {

    /// Where the last close left off on this device.
    struct DayCloseState: Equatable, Sendable {
        /// Everything recorded before this instant has been consolidated.
        let watermark: Date
        let lastRunAt: Date
    }

    func dayCloseState() throws -> DayCloseState? {
        var state: DayCloseState?
        try query("SELECT watermark, last_run_at FROM memory_day_close_state WHERE id = 1") { stmt in
            state = DayCloseState(
                watermark: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)),
                lastRunAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            )
        }
        return state
    }

    func recordDayCloseRun(watermark: Date, now: Date = Date()) throws {
        try execBind("""
            INSERT INTO memory_day_close_state (id, watermark, last_run_at) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET watermark = excluded.watermark, last_run_at = excluded.last_run_at
        """) { stmt in
            sqlite3_bind_double(stmt, 1, watermark.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
        }
    }

    /// One chat the day close has to fold in: the learner wrote in it after
    /// `since`, and its newest turn is past what any earlier close read.
    struct DayCloseChatSubject: Equatable, Sendable {
        let sessionID: String
        let title: String
        /// `ReviewSessionKind`; nil for a chat recorded before the column.
        let kind: String?
        /// The material the record names (`source_ids`): a memory review's
        /// or a review's whole material list, an ordinary chat's attachments.
        let recordedSourceIDs: [String]
        let lastLearnerTurnAt: Date
        /// The highest exchange sequence number the transcript holds now.
        let throughSequence: Int

        var isMemoryReview: Bool { MemoryReviewSession.isMemorySession(sessionID) }
        /// A memory review or a review is evidence about every source it
        /// named; an ordinary chat vouches only for what it cited or opened on.
        var isReview: Bool { isMemoryReview || kind == ReviewSessionKind.review.rawValue }
    }

    /// Chats with a learner turn in (`since`, `now`] whose transcript has
    /// grown past the last consolidation, oldest first. A team's read-only
    /// copy and a scheduled task's output are not the learner's day.
    func dayCloseChatSubjects(since: Date, now: Date) throws -> [DayCloseChatSubject] {
        var subjects: [DayCloseChatSubject] = []
        try queryBind("""
            SELECT fs.id, fs.topic, fs.kind, COALESCE(fs.source_ids, '[]'),
                   COALESCE(MAX(e.answered_at), fs.ended_at, fs.started_at) AS last_turn,
                   MAX(e.sequence_number)
            FROM review_sessions fs
            JOIN review_exchanges e ON e.session_id = fs.id
            WHERE fs.status IN ('active', 'completed')
              AND fs.team_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM scheduled_task_runs r WHERE r.session_id = fs.id)
            GROUP BY fs.id
            HAVING SUM(CASE WHEN TRIM(COALESCE(e.user_answer, '')) <> '' THEN 1 ELSE 0 END) > 0
               AND last_turn > ? AND last_turn <= ?
               AND MAX(e.sequence_number) > COALESCE(
                   (SELECT c.through_sequence FROM chat_consolidations c WHERE c.session_id = fs.id), -1)
            ORDER BY last_turn ASC
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            let recorded = (self.string(stmt, 3)?.data(using: .utf8))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            subjects.append(
                DayCloseChatSubject(
                    sessionID: id,
                    title: self.string(stmt, 1) ?? "Chat",
                    kind: self.string(stmt, 2),
                    recordedSourceIDs: recorded,
                    lastLearnerTurnAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                    throughSequence: Int(sqlite3_column_int64(stmt, 5))
                )
            )
        }
        return subjects
    }

    /// The sources a chat is evidence about. A review names its material; an
    /// ordinary chat vouches for the sources its turns cite by in-app link,
    /// plus the one source it was opened on (`ChatSourceEvidence`), by the
    /// same rule the engagement ledger uses — attachment of a whole Notebook
    /// vouches for none of it. Only ids that name a source come back.
    func dayCloseDiscussedSourceIDs(for subject: DayCloseChatSubject) throws -> [String] {
        var attached: [String] = []
        try queryBind("SELECT source_id FROM review_session_sources WHERE session_id = ?", bind: { stmt in
            bind(stmt, 1, subject.sessionID)
        }) { stmt in
            if let id = self.string(stmt, 0) { attached.append(id) }
        }

        var candidates: Set<String>
        if subject.isReview {
            candidates = Set(subject.recordedSourceIDs).union(attached)
        } else {
            var tokens: [String] = []
            try queryBind("""
                SELECT question, user_answer, evaluation
                FROM review_exchanges
                WHERE session_id = ?
                  AND (instr(COALESCE(question, ''), ?) > 0
                    OR instr(COALESCE(user_answer, ''), ?) > 0
                    OR instr(COALESCE(evaluation, ''), ?) > 0)
            """, bind: { stmt in
                bind(stmt, 1, subject.sessionID)
                for index in 2...4 { bind(stmt, index, ChatSourceEvidence.sourceLinkMarker) }
            }) { stmt in
                tokens.append(contentsOf: ChatSourceEvidence.sourceLinkTokens(
                    question: self.string(stmt, 0),
                    userAnswer: self.string(stmt, 1),
                    evaluation: self.string(stmt, 2)
                ))
            }
            var cited = Set<String>()
            for token in Set(tokens) {
                if let resolved = try resolveSourceID(forLinkToken: token) { cited.insert(resolved) }
            }
            candidates = ChatSourceEvidence.discussedSourceIDs(attached: attached, cited: cited)
        }
        guard !candidates.isEmpty else { return [] }

        // A chat in the material list (`ReviewableChat`) has no sources row and
        // no understanding document of its own; only sources are kept.
        let ids = candidates.sorted()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var existing: [String] = []
        try queryBind("""
            SELECT id FROM sources WHERE id IN (\(placeholders)) AND status = 'active'
        """, bind: { stmt in
            for (index, id) in ids.enumerated() { bind(stmt, index + 1, id) }
        }) { stmt in
            if let id = self.string(stmt, 0) { existing.append(id) }
        }
        return existing.sorted()
    }

    func recordChatConsolidation(sessionID: String, throughSequence: Int, sourceCount: Int, now: Date = Date()) throws {
        try execBind("""
            INSERT INTO chat_consolidations (session_id, through_sequence, consolidated_at, source_count)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                through_sequence = excluded.through_sequence,
                consolidated_at = excluded.consolidated_at,
                source_count = excluded.source_count
        """) { stmt in
            bind(stmt, 1, sessionID)
            sqlite3_bind_int64(stmt, 2, Int64(throughSequence))
            sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 4, Int64(sourceCount))
        }
    }

    func chatConsolidationThroughSequence(sessionID: String) throws -> Int? {
        var through: Int?
        try queryBind("SELECT through_sequence FROM chat_consolidations WHERE session_id = ?", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            through = Int(sqlite3_column_int64(stmt, 0))
        }
        return through
    }

    /// The closer's three-line summary on the session record, without
    /// touching its status: an active chat stays open, a completed review
    /// keeps its end. The record syncs, so the other device reads the same
    /// summary and the planner's `recentReviewSessionSummaries` sees it once
    /// the session is completed.
    func setReviewSessionSummary(sessionID: String, summary: String) throws {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try execBind("UPDATE review_sessions SET summary = ? WHERE id = ?") { stmt in
            bind(stmt, 1, trimmed)
            bind(stmt, 2, sessionID)
        }
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
    }

    /// Sources the learner reached in (`since`, `now`]: marked read, or with
    /// an activity day that ended in the window. Whether the reading went far
    /// enough to be reviewed is the consumption model's call, made by the
    /// caller through `cohortCandidates`.
    func sourceIDsReached(since: Date, now: Date) throws -> [String] {
        var ids = Set<String>()
        try queryBind("""
            SELECT sp.id FROM source_projection sp
            WHERE sp.status = 'active' AND sp.is_collection_hidden = 0
              AND sp.read_at IS NOT NULL AND sp.read_at > ? AND sp.read_at <= ?
            UNION
            SELECT sp.id FROM source_projection sp
            JOIN source_activity_days sad ON sad.source_id = sp.id
            WHERE sp.status = 'active' AND sp.is_collection_hidden = 0
              AND sad.last_activity_at > ? AND sad.last_activity_at <= ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSinceReferenceDate)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids.sorted()
    }
}
