// KnowledgeStore: saving a review session from its synced record.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    func saveReviewSessionRecord(_ payload: CloudKitReviewSessionPayload) throws {
        let resolvedSourceIDs = try resolveSourceIDs(payload.sourceIDs, identities: payload.sourceIdentities)
        let resolvedExchanges = try payload.exchanges.map { exchange in
            CloudKitReviewExchangePayload(
                id: exchange.id,
                sessionID: exchange.sessionID,
                sequenceNumber: exchange.sequenceNumber,
                question: exchange.question,
                userAnswer: exchange.userAnswer,
                evaluation: exchange.evaluation,
                score: exchange.score,
                sourceRefs: try resolveSourceIDs(exchange.sourceRefs, identities: payload.sourceIdentities),
                knowledgeNote: exchange.knowledgeNote,
                answeredAt: exchange.answeredAt,
                contextContent: exchange.contextContent,
                ideaCoverage: exchange.ideaCoverage,
                questionVerdict: exchange.questionVerdict,
                operation: exchange.operation,
                steer: exchange.steer,
                rating: exchange.rating,
                ratingReason: exchange.ratingReason,
                ratingField: exchange.ratingField,
                ratedAt: exchange.ratedAt
            )
        }
        guard resolvedExchanges.allSatisfy({ $0.sessionID == payload.id }) else {
            throw KnowledgeStoreError.invalidData(
                "A synced review exchange points to a different session."
            )
        }
        let inboundExchangeIDs = resolvedExchanges.map(\.id)
        guard Set(inboundExchangeIDs).count == inboundExchangeIDs.count else {
            throw KnowledgeStoreError.invalidData(
                "A synced review transcript reuses one exchange identity twice."
            )
        }
        let inboundSequenceNumbers = resolvedExchanges.map(\.sequenceNumber)
        // iPhone recorders have always emitted the first exchange as sequence 0.
        // Preserve that deployed identity contract; staging below maps 0 to -1.
        guard inboundSequenceNumbers.allSatisfy({ $0 >= 0 }),
              Set(inboundSequenceNumbers).count == inboundSequenceNumbers.count else {
            throw KnowledgeStoreError.invalidData(
                "A synced review transcript must use distinct nonnegative sequence numbers."
            )
        }

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary, source_ids, card_ids, exchange_count, model_provider, model_id, goal_id, kind, briefing, team_id, model_effort, model_speed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    topic = excluded.topic,
                    -- A pre-v89 client sends neither; keep what is known.
                    kind = COALESCE(excluded.kind, review_sessions.kind),
                    briefing = COALESCE(excluded.briefing, review_sessions.briefing),
                    team_id = COALESCE(excluded.team_id, review_sessions.team_id),
                    started_at = excluded.started_at,
                    ended_at = excluded.ended_at,
                    status = excluded.status,
                    overall_score = excluded.overall_score,
                    summary = excluded.summary,
                    source_ids = excluded.source_ids,
                    card_ids = excluded.card_ids,
                    exchange_count = excluded.exchange_count,
                    model_provider = excluded.model_provider,
                    model_id = excluded.model_id,
                    -- A pre-149 client sends no effort or speed: keep the
                    -- local ones while its model is still theirs.
                    model_effort = CASE
                        WHEN ? = 1 THEN excluded.model_effort
                        WHEN review_sessions.model_provider IS excluded.model_provider
                         AND review_sessions.model_id IS excluded.model_id
                        THEN review_sessions.model_effort
                    END,
                    model_speed = CASE
                        WHEN ? = 1 THEN excluded.model_speed
                        WHEN review_sessions.model_provider IS excluded.model_provider
                         AND review_sessions.model_id IS excluded.model_id
                        THEN review_sessions.model_speed
                    END,
                    goal_id = CASE
                        WHEN ? = 1 THEN excluded.goal_id
                        ELSE review_sessions.goal_id
                    END
            """) { stmt in
                bind(stmt, 1, payload.id)
                bind(stmt, 2, payload.topic)
                sqlite3_bind_double(stmt, 3, payload.startedAt.timeIntervalSinceReferenceDate)
                if let endedAt = payload.endedAt {
                    sqlite3_bind_double(stmt, 4, endedAt.timeIntervalSinceReferenceDate)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                bind(stmt, 5, payload.status)
                if let overallScore = payload.overallScore {
                    sqlite3_bind_double(stmt, 6, overallScore)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                bind(stmt, 7, payload.summary)
                bind(stmt, 8, jsonString(from: resolvedSourceIDs))
                bind(stmt, 9, jsonString(from: payload.cardIDs))
                sqlite3_bind_int(stmt, 10, Int32(payload.exchangeCount))
                bind(stmt, 11, payload.modelProvider)
                bind(stmt, 12, payload.modelID)
                bind(stmt, 13, payload.goalID)
                bind(stmt, 14, payload.kind)
                bind(stmt, 15, payload.briefing)
                bind(stmt, 16, payload.teamID)
                bind(stmt, 17, payload.modelEffort)
                bind(stmt, 18, payload.modelSpeed)
                sqlite3_bind_int(stmt, 19, payload.modelTuningFieldIsPresent ? 1 : 0)
                sqlite3_bind_int(stmt, 20, payload.modelTuningFieldIsPresent ? 1 : 0)
                sqlite3_bind_int(stmt, 21, payload.goalIDFieldIsPresent ? 1 : 0)
            }

            // CloudKit does not guarantee Source-before-session delivery. Keep
            // the complete portable relationship in `source_ids`, but notebook
            // only sources that already exist into the foreign-key junction.
            // `persistSourceRows` fills any deferred link when its Source lands.
            try replaceReviewSessionSources(
                sessionID: payload.id,
                sourceIDs: resolvedSourceIDs,
                allowMissingSources: true
            )

            // Session records and concept attempts sync independently. Preserve any
            // exchange already referenced by an immutable attempt when an older or
            // out-of-order session payload does not know about that exchange yet.
            var linkedAttemptsByExchangeID: [String: MemoryAttempt] = [:]
            var linkedAttemptIDs: [String] = []
            try queryBind("""
                SELECT id
                FROM memory_attempts
                WHERE session_id = ? AND exchange_id IS NOT NULL
                ORDER BY id
            """, bind: { stmt in
                bind(stmt, 1, payload.id)
            }) { stmt in
                if let id = self.string(stmt, 0) {
                    linkedAttemptIDs.append(id)
                }
            }
            for attemptID in linkedAttemptIDs {
                guard let attempt = try loadMemoryAttempt(attemptID),
                      let exchangeID = attempt.exchangeID else { continue }
                linkedAttemptsByExchangeID[exchangeID] = attempt
            }

            let existingExchanges = try loadReviewExchanges(sessionID: payload.id)
            let existingByID = Dictionary(uniqueKeysWithValues: existingExchanges.map { ($0.id, $0) })
            let inboundIDSet = Set(inboundExchangeIDs)
            for (exchangeID, attempt) in linkedAttemptsByExchangeID {
                guard existingByID[exchangeID] != nil || inboundIDSet.contains(exchangeID) else {
                    throw KnowledgeStoreError.invalidData(
                        "Synced session \(payload.id) is missing exchange \(exchangeID) linked to immutable memory history."
                    )
                }
                if let inbound = resolvedExchanges.first(where: { $0.id == exchangeID }) {
                    guard attempt.prompt == inbound.question,
                          attempt.learnerAnswer == inbound.userAnswer,
                          (attempt.feedback ?? attempt.gradingError) == inbound.evaluation,
                          attempt.score == inbound.score else {
                        throw KnowledgeStoreError.invalidData(
                            "Synced transcript content disagrees with immutable memory attempt \(attempt.id)."
                        )
                    }
                }
            }

            try execBind("""
                UPDATE review_exchanges
                SET sequence_number = -(sequence_number + 1)
                WHERE session_id = ?
            """) { stmt in
                bind(stmt, 1, payload.id)
            }
            for exchange in resolvedExchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
                var existingSessionID: String?
                try queryBind("""
                    SELECT session_id
                    FROM review_exchanges
                    WHERE id = ?
                    LIMIT 1
                """, bind: { stmt in
                    bind(stmt, 1, exchange.id)
                }) { stmt in
                    existingSessionID = self.string(stmt, 0)
                }
                guard existingSessionID == nil || existingSessionID == payload.id else {
                    throw KnowledgeStoreError.invalidData(
                        "review exchange \(exchange.id) belongs to a different session."
                    )
                }
                try execBind("""
                    INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at, context_content,
                        idea_coverage, question_verdict, operation, steer,
                        rating, rating_reason, rating_field, rated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        session_id = excluded.session_id,
                        sequence_number = excluded.sequence_number,
                        question = excluded.question,
                        user_answer = excluded.user_answer,
                        evaluation = excluded.evaluation,
                        score = excluded.score,
                        source_refs = excluded.source_refs,
                        knowledge_note = excluded.knowledge_note,
                        answered_at = excluded.answered_at,
                        -- A pre-v84 client round-tripping a session sends the
                        -- transcript back with no context at all. Taking that as
                        -- authoritative would erase the passage from a chat the
                        -- other Mac still shows it on, so an absent value keeps
                        -- what is already stored.
                        context_content = COALESCE(excluded.context_content, review_exchanges.context_content),
                        -- The same rule for the v89 grading columns: a client
                        -- that cannot carry them must not blank them.
                        idea_coverage = COALESCE(excluded.idea_coverage, review_exchanges.idea_coverage),
                        question_verdict = COALESCE(excluded.question_verdict, review_exchanges.question_verdict),
                        operation = COALESCE(excluded.operation, review_exchanges.operation),
                        steer = COALESCE(excluded.steer, review_exchanges.steer),
                        -- A rating is one unit keyed on rated_at: a payload that
                        -- carries a rated_at is authoritative for all four
                        -- columns — including a NULL rating, which is how a
                        -- thumb taken back on one Mac reaches the other — and a
                        -- payload with none (a pre-v93 client, or a phone
                        -- rewrite of a session it made) leaves the stored
                        -- rating alone.
                        rating = CASE WHEN excluded.rated_at IS NULL THEN review_exchanges.rating ELSE excluded.rating END,
                        rating_reason = CASE WHEN excluded.rated_at IS NULL THEN review_exchanges.rating_reason ELSE excluded.rating_reason END,
                        rating_field = CASE WHEN excluded.rated_at IS NULL THEN review_exchanges.rating_field ELSE excluded.rating_field END,
                        rated_at = CASE WHEN excluded.rated_at IS NULL THEN review_exchanges.rated_at ELSE excluded.rated_at END
                """) { stmt in
                    bind(stmt, 1, exchange.id)
                    bind(stmt, 2, exchange.sessionID)
                    sqlite3_bind_int(stmt, 3, Int32(exchange.sequenceNumber))
                    bind(stmt, 4, exchange.question)
                    bind(stmt, 5, exchange.userAnswer)
                    bind(stmt, 6, exchange.evaluation)
                    if let score = exchange.score {
                        sqlite3_bind_double(stmt, 7, score)
                    } else {
                        sqlite3_bind_null(stmt, 7)
                    }
                    bind(stmt, 8, jsonString(from: exchange.sourceRefs))
                    bind(stmt, 9, exchange.knowledgeNote)
                    if let answeredAt = exchange.answeredAt {
                        sqlite3_bind_double(stmt, 10, answeredAt.timeIntervalSinceReferenceDate)
                    } else {
                        sqlite3_bind_null(stmt, 10)
                    }
                    bind(stmt, 11, exchange.contextContent)
                    bind(stmt, 12, exchange.ideaCoverage)
                    bind(stmt, 13, exchange.questionVerdict)
                    bind(stmt, 14, exchange.operation)
                    bind(stmt, 15, exchange.steer)
                    bind(stmt, 16, exchange.rating)
                    bind(stmt, 17, exchange.ratingReason)
                    bind(stmt, 18, exchange.ratingField)
                    if let ratedAt = exchange.ratedAt {
                        sqlite3_bind_double(stmt, 19, ratedAt.timeIntervalSinceReferenceDate)
                    } else {
                        sqlite3_bind_null(stmt, 19)
                    }
                }
            }

            var nextSequence = max(0, resolvedExchanges.map(\.sequenceNumber).max() ?? 0) + 1
            let preservedLinkedExchanges = existingExchanges
                .filter { linkedAttemptsByExchangeID[$0.id] != nil && !inboundIDSet.contains($0.id) }
                .sorted {
                    if $0.sequenceNumber != $1.sequenceNumber {
                        return $0.sequenceNumber < $1.sequenceNumber
                    }
                    return $0.id < $1.id
                }
            for exchange in preservedLinkedExchanges {
                try execBind("""
                    UPDATE review_exchanges
                    SET sequence_number = ?
                    WHERE id = ? AND session_id = ?
                """) { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(nextSequence))
                    bind(stmt, 2, exchange.id)
                    bind(stmt, 3, payload.id)
                }
                nextSequence += 1
            }
            try execBind("""
                DELETE FROM review_exchanges
                WHERE session_id = ? AND sequence_number < 0
            """) { stmt in
                bind(stmt, 1, payload.id)
            }
            try execBind("""
                UPDATE review_sessions
                SET exchange_count = (
                    SELECT COUNT(*) FROM review_exchanges WHERE session_id = ?
                )
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, payload.id)
                bind(stmt, 2, payload.id)
            }
            if let docLinks = payload.docLinks {
                try replaceArtifactChatLinks(sessionID: payload.id, links: docLinks)
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

}
