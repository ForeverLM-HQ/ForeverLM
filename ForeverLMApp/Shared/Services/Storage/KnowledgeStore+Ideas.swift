import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Source ideas

    static let sourceIdeaColumns = """
        id, source_id, statement, recall_note, anchors_json, wanted, origin_session_id,
        content_hash, status, sort_index, created_at, updated_at
        """

    private func readSourceIdeaRow(_ stmt: OpaquePointer?) -> SourceIdea? {
        guard let id = string(stmt, 0),
              let sourceID = string(stmt, 1),
              let statement = string(stmt, 2),
              let contentHash = string(stmt, 7),
              let statusRaw = string(stmt, 8),
              let status = SourceIdeaStatus(rawValue: statusRaw) else { return nil }
        let anchors: [SourceIdeaAnchor] = {
            guard let json = string(stmt, 4), let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([SourceIdeaAnchor].self, from: data)) ?? []
        }()
        return SourceIdea(
            id: id,
            sourceID: sourceID,
            statement: statement,
            recallNote: string(stmt, 3) ?? "",
            anchors: anchors,
            wanted: sqlite3_column_int(stmt, 5) != 0,
            originSessionID: string(stmt, 6),
            contentHash: contentHash,
            status: status,
            sortIndex: Int(sqlite3_column_int(stmt, 9)),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11))
        )
    }

    /// The active ideas of each source, in extraction order.
    func loadSourceIdeas(sourceIDs: [String], includeRetired: Bool = false) throws -> [String: [SourceIdea]] {
        let ids = Array(Set(sourceIDs))
        guard !ids.isEmpty else { return [:] }
        var result: [String: [SourceIdea]] = [:]
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let statusClause = includeRetired ? "" : "AND status = 'active'"
        try queryBind("""
            SELECT \(Self.sourceIdeaColumns)
            FROM source_ideas
            WHERE source_id IN (\(placeholders)) \(statusClause)
            ORDER BY source_id, sort_index, id
        """, bind: { stmt in
            for (index, id) in ids.enumerated() {
                bind(stmt, index + 1, id)
            }
        }) { stmt in
            if let idea = self.readSourceIdeaRow(stmt) {
                result[idea.sourceID, default: []].append(idea)
            }
        }
        return result
    }

    /// The hash the source's active ideas were extracted from, or nil when the
    /// source has none. `SourceIdeaExtractionService` compares it with the
    /// current text to decide whether a source needs extraction.
    func sourceIdeaContentHash(sourceID: String) throws -> String? {
        var hash: String?
        try queryBind("""
            SELECT content_hash FROM source_ideas
            WHERE source_id = ? AND status = 'active'
            ORDER BY updated_at DESC LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            hash = self.string(stmt, 0)
        }
        return hash
    }

    /// Replaces a source's ideas with a new generation. Ideas from an older
    /// hash are retired, never deleted, so a target or an exchange that names
    /// one still resolves; ideas of the same hash are rewritten in place.
    func replaceSourceIdeas(sourceID: String, contentHash: String, ideas: [SourceIdea], now: Date = Date()) throws {
        guard ideas.allSatisfy({ $0.sourceID == sourceID && $0.contentHash == contentHash }) else {
            throw KnowledgeStoreError.invalidData("Ideas must belong to the source and hash they replace.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            var retiredIDs: [String] = []
            try queryBind("""
                SELECT id FROM source_ideas
                WHERE source_id = ? AND status = 'active' AND content_hash != ?
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
                bind(stmt, 2, contentHash)
            }) { stmt in
                if let id = self.string(stmt, 0) { retiredIDs.append(id) }
            }
            for id in retiredIDs {
                try execBind("UPDATE source_ideas SET status = 'retired', updated_at = ? WHERE id = ?") { stmt in
                    bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 2, id)
                }
            }
            for idea in ideas.prefix(SourceIdea.maximumPerSource) {
                try upsertSourceIdeaRow(idea)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Retires one idea — "that's not what I care about in this". Remembered,
    /// so a later re-extraction of the same text does not bring it back.
    func setSourceIdeaStatus(id: String, status: SourceIdeaStatus, now: Date = Date()) throws {
        try execBind("UPDATE source_ideas SET status = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, status.rawValue)
            bind(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, id)
        }
    }

    private func upsertSourceIdeaRow(_ idea: SourceIdea) throws {
        let anchorsJSON = (try? JSONEncoder().encode(idea.anchors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try execBind("""
            INSERT INTO source_ideas (
                id, source_id, statement, recall_note, anchors_json, wanted, origin_session_id,
                content_hash, status, sort_index, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id,
                statement = excluded.statement,
                recall_note = excluded.recall_note,
                anchors_json = excluded.anchors_json,
                wanted = excluded.wanted,
                origin_session_id = excluded.origin_session_id,
                content_hash = excluded.content_hash,
                status = excluded.status,
                sort_index = excluded.sort_index,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, idea.id)
            bind(stmt, 2, idea.sourceID)
            bind(stmt, 3, idea.statement)
            bind(stmt, 4, idea.recallNote)
            bind(stmt, 5, anchorsJSON)
            bind(stmt, 6, idea.wanted ? 1 : 0)
            bind(stmt, 7, idea.originSessionID)
            bind(stmt, 8, idea.contentHash)
            bind(stmt, 9, idea.status.rawValue)
            bind(stmt, 10, idea.sortIndex)
            bind(stmt, 11, idea.createdAt.timeIntervalSinceReferenceDate)
            bind(stmt, 12, idea.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    // MARK: Sync

    // MARK: - Review depth

    func loadSourceReviewDepths(sourceIDs: [String]) throws -> [String: MemoryReviewDepth] {
        let ids = Array(Set(sourceIDs))
        guard !ids.isEmpty else { return [:] }
        return try readingStateReviewDepths(sourceIDs: ids).compactMapValues(MemoryReviewDepth.init(rawValue:))
    }

    /// Sets or clears a source's review depth. Synced with the source, since
    /// "keep this one quick" is about the material, not the Mac it was said on.
    func setSourceReviewDepth(sourceID: String, depth: MemoryReviewDepth?, now: Date = Date()) throws {
        var exists = false
        try queryBind("SELECT 1 FROM sources WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { _ in
            exists = true
        }
        guard exists else {
            throw KnowledgeStoreError.invalidData("No source \(sourceID) to set a review depth on.")
        }
        try updateReadingState(sourceID: sourceID) { $0.reviewDepth = depth?.rawValue }
        return
    }

    // MARK: - Memory review chat briefing

    /// The briefing a memory chat's tutor carries: the day's plan, its ideas
    /// and material. Stored so a resume after relaunch, a chat prepared by the
    /// daily task, and the other device all open the same review; it rides
    /// inside the ReviewSession record.
    func setReviewSessionBriefing(sessionID: String, briefing: String?) throws {
        try execBind("UPDATE review_sessions SET briefing = ? WHERE id = ?") { stmt in
            bind(stmt, 1, briefing)
            bind(stmt, 2, sessionID)
        }
        noteStoreChanged()
    }

    func loadReviewSessionBriefing(sessionID: String) throws -> String? {
        var briefing: String?
        try queryBind("SELECT briefing FROM review_sessions WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            briefing = self.string(stmt, 0)
        }
        return briefing
    }

    /// Every course quiz sitting kept with a chat of the learner's own
    /// (`CourseQuizSitting`), newest first: the chat's id, when it started,
    /// and the row's briefing holding its grades. A handful of rows, read
    /// whole for the quiz rows' progress.
    func loadCourseQuizSittingRows() throws -> [(sessionID: String, startedAt: Date, briefing: String?)] {
        var rows: [(sessionID: String, startedAt: Date, briefing: String?)] = []
        try queryBind("""
            SELECT id, started_at, briefing
            FROM review_sessions
            WHERE id LIKE ? AND team_id IS NULL
            ORDER BY started_at DESC
        """, bind: { stmt in
            bind(stmt, 1, CourseQuizSitting.sessionIDPrefix + "%")
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            rows.append((id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)), self.string(stmt, 2)))
        }
        return rows
    }

    // MARK: - Contour grades and steers

    /// Stamps a graded contour onto the exchange the tutor's reply landed on.
    /// The coverage rides in the session record, so both devices derive the
    /// same rung from it; nothing else is written for the schedule.
    func recordMemoryContourGrade(sessionID: String, sequence: Int, grade: MemoryContourGrade) throws {
        guard let coverageJSON = MemoryIdeaCoverage.encode(grade.coverage) else {
            throw KnowledgeStoreError.invalidData("The contour grade could not be encoded.")
        }
        try execBind("""
            UPDATE review_exchanges
            SET idea_coverage = ?,
                question_verdict = ?,
                operation = ?,
                score = ?
            WHERE session_id = ? AND sequence_number = ?
        """) { stmt in
            bind(stmt, 1, coverageJSON)
            bind(stmt, 2, grade.verdict.rawValue)
            bind(stmt, 3, grade.operation.rawValue)
            sqlite3_bind_double(stmt, 4, grade.score)
            bind(stmt, 5, sessionID)
            sqlite3_bind_int(stmt, 6, Int32(sequence))
        }
        noteStoreChanged()
    }

    /// Stamps the tutor's verdict on a teach-back explanation onto the
    /// exchange its reply landed on (`TeachBack.Explanation`): the operation,
    /// `sound`, the score. The sources ride in the row's own `source_refs`,
    /// written with the turn; `idea_coverage` is left alone.
    func recordTeachBackExplanation(
        sessionID: String,
        sequence: Int,
        operation: MemoryQuestionOperation,
        score: Double
    ) throws {
        try execBind("""
            UPDATE review_exchanges
            SET question_verdict = ?, operation = ?, score = ?
            WHERE session_id = ? AND sequence_number = ?
        """) { stmt in
            bind(stmt, 1, MemoryQuestionVerdict.sound.rawValue)
            bind(stmt, 2, operation.rawValue)
            sqlite3_bind_double(stmt, 3, score)
            bind(stmt, 4, sessionID)
            sqlite3_bind_int(stmt, 5, Int32(sequence))
        }
        noteStoreChanged()
    }

    /// When each source was last explained so that it held: a teach-back
    /// verdict (`recordTeachBackExplanation`) of `held`, read off the
    /// exchange's `source_refs`. What the morning's pick reads.
    func explainedSourceDates() throws -> [String: Date] {
        var latest: [String: Date] = [:]
        try queryBind("""
            SELECT source_refs, COALESCE(answered_at, 0)
            FROM review_exchanges
            WHERE operation IN ('explain', 'connect')
              AND question_verdict = 'sound'
              AND idea_coverage IS NULL
              AND score >= ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, TeachBack.explainedScore)
        }) { stmt in
            let at = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            guard let json = self.string(stmt, 0), let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
            for id in ids where (latest[id] ?? .distantPast) < at {
                latest[id] = at
            }
        }
        return latest
    }

    /// Records the learner's steer after the latest graded contour that has not
    /// been steered yet, and returns that contour's coverage so the caller
    /// knows which source it was about. nil when nothing was waiting for one.
    @discardableResult
    func recordMemoryReviewSteer(sessionID: String, steer: MemoryReviewSteer) throws -> [MemoryIdeaCoverage]? {
        var target: (sequence: Int, coverage: String)?
        try queryBind("""
            SELECT sequence_number, idea_coverage
            FROM review_exchanges
            WHERE session_id = ?
              AND idea_coverage IS NOT NULL
              AND steer IS NULL
            ORDER BY sequence_number DESC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            if let coverage = self.string(stmt, 1) {
                target = (Int(sqlite3_column_int(stmt, 0)), coverage)
            }
        }
        guard let target else { return nil }
        try execBind("""
            UPDATE review_exchanges SET steer = ?
            WHERE session_id = ? AND sequence_number = ?
        """) { stmt in
            bind(stmt, 1, steer.rawValue)
            bind(stmt, 2, sessionID)
            sqlite3_bind_int(stmt, 3, Int32(target.sequence))
        }
        noteStoreChanged()
        return MemoryIdeaCoverage.decode(target.coverage)
    }

    /// Every graded contour, per source, oldest first: the evidence the ladder
    /// is derived from. Small by construction — a few graded rows per review —
    /// so it is read whole and folded in Swift, where the source an idea id
    /// belongs to is a prefix, not a join. A topic's grade spans sources and a
    /// probe re-grades ideas already graded, so the rows go through
    /// `MemoryLadderEvidence`: one outcome per source per session, from each
    /// idea's first grade that day.
    func memoryContourHistory() throws -> [String: [MemoryContourOutcome]] {
        var rows: [MemoryGradedExchange] = []
        try query("""
            SELECT session_id, sequence_number, idea_coverage, question_verdict, COALESCE(answered_at, 0)
            FROM review_exchanges
            WHERE idea_coverage IS NOT NULL
            ORDER BY COALESCE(answered_at, 0) ASC, sequence_number ASC
        """) { stmt in
            guard let sessionID = self.string(stmt, 0) else { return }
            rows.append(MemoryGradedExchange(
                sessionID: sessionID,
                sequenceNumber: Int(sqlite3_column_int(stmt, 1)),
                ideaCoverage: self.string(stmt, 2),
                questionVerdict: self.string(stmt, 3),
                answeredAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            ))
        }
        var bySource: [String: [MemoryContourOutcome]] = [:]
        for outcome in MemoryLadderEvidence.outcomes(rows) {
            bySource[outcome.sourceID, default: []].append(MemoryContourOutcome(
                sourceID: outcome.sourceID,
                sessionID: outcome.sessionID,
                gradedAt: outcome.gradedAt ?? Date(timeIntervalSinceReferenceDate: 0),
                producedFraction: outcome.producedFraction
            ))
        }
        return bySource
    }

    /// The steers recorded in one session, oldest first, each with the source
    /// its contour was about. What "three Nexts in a row on podcasts" is read from.
    func memoryReviewSteers(sessionID: String) throws -> [(sourceID: String, steer: MemoryReviewSteer)] {
        var result: [(sourceID: String, steer: MemoryReviewSteer)] = []
        try queryBind("""
            SELECT idea_coverage, steer
            FROM review_exchanges
            WHERE session_id = ? AND idea_coverage IS NOT NULL AND steer IS NOT NULL
            ORDER BY sequence_number ASC
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let steer = self.string(stmt, 1).flatMap(MemoryReviewSteer.init(rawValue:)),
                  let first = MemoryIdeaCoverage.decode(self.string(stmt, 0)).first,
                  let sourceID = SourceIdea.sourceID(fromIdeaID: first.ideaID) else { return }
            result.append((sourceID, steer))
        }
        return result
    }

}
