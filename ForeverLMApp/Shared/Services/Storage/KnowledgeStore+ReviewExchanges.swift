// KnowledgeStore: adding, importing and reconciling the exchanges of a review session.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    @discardableResult
    func addReviewExchange(
        sessionID: String,
        question: String,
        answer: String,
        evaluation: String,
        score: Double?,
        knowledgeNote: String?,
        sourceRefs: [String],
        answeredAt: Date = Date()
    ) throws -> Int {
        var nextSequence = 1
        try queryBind("SELECT exchange_count FROM review_sessions WHERE id = ?", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            nextSequence = Int(sqlite3_column_int(stmt, 0)) + 1
        }

        let exchangeID = UUID().uuidString
        let refsJSON = jsonString(from: sourceRefs)

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, exchangeID)
                bind(stmt, 2, sessionID)
                sqlite3_bind_int(stmt, 3, Int32(nextSequence))
                bind(stmt, 4, question)
                bind(stmt, 5, answer)
                bind(stmt, 6, evaluation)
                if let score {
                    sqlite3_bind_double(stmt, 7, score)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                bind(stmt, 8, refsJSON)
                bind(stmt, 9, knowledgeNote)
                sqlite3_bind_double(stmt, 10, answeredAt.timeIntervalSinceReferenceDate)
            }
            try execBind("UPDATE review_sessions SET exchange_count = ? WHERE id = ?", { stmt in
                sqlite3_bind_int(stmt, 1, Int32(nextSequence))
                bind(stmt, 2, sessionID)
            })
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return nextSequence
    }

    @discardableResult
    func addReviewPrompt(
        sessionID: String,
        question: String,
        sourceRefs: [String]
    ) throws -> Int {
        var nextSequence = 1
        try queryBind("SELECT exchange_count FROM review_sessions WHERE id = ?", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            nextSequence = Int(sqlite3_column_int(stmt, 0)) + 1
        }

        let exchangeID = UUID().uuidString
        let refsJSON = jsonString(from: sourceRefs)

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at)
                VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, NULL, NULL)
            """) { stmt in
                bind(stmt, 1, exchangeID)
                bind(stmt, 2, sessionID)
                sqlite3_bind_int(stmt, 3, Int32(nextSequence))
                bind(stmt, 4, question)
                bind(stmt, 5, refsJSON)
            }
            try execBind("UPDATE review_sessions SET exchange_count = ? WHERE id = ?", { stmt in
                sqlite3_bind_int(stmt, 1, Int32(nextSequence))
                bind(stmt, 2, sessionID)
            })
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return nextSequence
    }

    /// Persist the learner's message the moment it is sent — before the tutor
    /// reply is generated — so an app crash or kill mid-generation never loses
    /// it. If the newest exchange is an unanswered tutor prompt, the message is
    /// recorded as its answer; otherwise a new exchange row is opened with the
    /// message and no evaluation yet. `answerPendingReviewExchange` later fills
    /// in the evaluation on the same row.
    @discardableResult
    func recordPendingReviewUserMessage(
        sessionID: String,
        answer: String,
        sourceRefs: [String],
        contextContent: String? = nil,
        answeredAt: Date = Date()
    ) throws -> Int {
        var pendingSequence: Int?
        try queryBind("""
            SELECT sequence_number
            FROM review_exchanges
            WHERE session_id = ?
              AND user_answer IS NULL
              AND evaluation IS NULL
            ORDER BY sequence_number DESC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            pendingSequence = Int(sqlite3_column_int(stmt, 0))
        }

        if let pendingSequence {
            try execBind("""
                UPDATE review_exchanges
                SET user_answer = ?,
                    answered_at = ?,
                    -- Only a message that carried a passage may overwrite one.
                    -- A plain follow-up typed into a doc-opened chat has no
                    -- context of its own and must not blank the row's.
                    context_content = COALESCE(?, context_content)
                WHERE session_id = ?
                  AND sequence_number = ?
            """) { stmt in
                bind(stmt, 1, answer)
                sqlite3_bind_double(stmt, 2, answeredAt.timeIntervalSinceReferenceDate)
                bind(stmt, 3, contextContent)
                bind(stmt, 4, sessionID)
                sqlite3_bind_int(stmt, 5, Int32(pendingSequence))
            }
            noteStoreChanged()
            return pendingSequence
        }

        var nextSequence = 1
        try queryBind("SELECT exchange_count FROM review_sessions WHERE id = ?", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            nextSequence = Int(sqlite3_column_int(stmt, 0)) + 1
        }

        let exchangeID = UUID().uuidString
        let refsJSON = jsonString(from: sourceRefs)

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at, context_content)
                VALUES (?, ?, ?, '', ?, NULL, NULL, ?, NULL, ?, ?)
            """) { stmt in
                bind(stmt, 1, exchangeID)
                bind(stmt, 2, sessionID)
                sqlite3_bind_int(stmt, 3, Int32(nextSequence))
                bind(stmt, 4, answer)
                bind(stmt, 5, refsJSON)
                sqlite3_bind_double(stmt, 6, answeredAt.timeIntervalSinceReferenceDate)
                bind(stmt, 7, contextContent)
            }
            try execBind("UPDATE review_sessions SET exchange_count = ? WHERE id = ?", { stmt in
                sqlite3_bind_int(stmt, 1, Int32(nextSequence))
                bind(stmt, 2, sessionID)
            })
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return nextSequence
    }

    /// Writes a tutor reply onto an exchange whose evaluation is still pending,
    /// including a row whose user_answer was persisted eagerly when the
    /// learner sent their message, so the reply lands on that row instead of
    /// a duplicate.
    ///
    /// `sequence` names the row: the one `recordPendingReviewUserMessage`
    /// returned for the message this reply answers. It is answered only while
    /// it has no reply; nil comes back when it has one already or is gone.
    /// The chat always passes it. Without it the reply takes the oldest
    /// pending row after the last evaluated exchange, which is right only
    /// while every earlier message got its reply: a turn that ended with
    /// none (a quiz grade cut short by Send now, a failure the learner
    /// answered past) left its row pending, and on 2026-09-27 every later
    /// reply in a course quiz landed on an earlier message than its own.
    @discardableResult
    func answerPendingReviewExchange(
        sessionID: String,
        sequence: Int? = nil,
        answer: String,
        evaluation: String,
        score: Double?,
        knowledgeNote: String?,
        sourceRefs: [String],
        answeredAt: Date = Date()
    ) throws -> Int? {
        var pendingSequence: Int?
        if let sequence {
            try queryBind("""
                SELECT sequence_number
                FROM review_exchanges
                WHERE session_id = ?
                  AND sequence_number = ?
                  AND evaluation IS NULL
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
                sqlite3_bind_int(stmt, 2, Int32(sequence))
            }) { stmt in
                pendingSequence = Int(sqlite3_column_int(stmt, 0))
            }
        } else {
            // The subquery pins the search to rows after the last evaluated
            // exchange, so historical evaluation-less rows in resumed or
            // imported sessions are never touched.
            try queryBind("""
                SELECT sequence_number
                FROM review_exchanges
                WHERE session_id = ?
                  AND evaluation IS NULL
                  AND sequence_number > COALESCE((
                      SELECT MAX(sequence_number)
                      FROM review_exchanges
                      WHERE session_id = ?
                        AND evaluation IS NOT NULL
                  ), 0)
                ORDER BY sequence_number ASC
                LIMIT 1
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
                bind(stmt, 2, sessionID)
            }) { stmt in
                pendingSequence = Int(sqlite3_column_int(stmt, 0))
            }
        }

        guard let pendingSequence else { return nil }

        let refsJSON = jsonString(from: sourceRefs)
        // COALESCE keeps an eagerly-persisted user message intact: when messages
        // were queued mid-generation, the caller's "last user message" may be a
        // later one than the message this row already holds.
        try execBind("""
            UPDATE review_exchanges
            SET user_answer = COALESCE(user_answer, ?),
                evaluation = ?,
                score = ?,
                source_refs = ?,
                knowledge_note = ?,
                answered_at = ?
            WHERE session_id = ?
              AND sequence_number = ?
        """) { stmt in
            bind(stmt, 1, answer)
            bind(stmt, 2, evaluation)
            if let score {
                sqlite3_bind_double(stmt, 3, score)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bind(stmt, 4, refsJSON)
            bind(stmt, 5, knowledgeNote)
            sqlite3_bind_double(stmt, 6, answeredAt.timeIntervalSinceReferenceDate)
            bind(stmt, 7, sessionID)
            sqlite3_bind_int(stmt, 8, Int32(pendingSequence))
        }
        noteStoreChanged()
        return pendingSequence
    }

    func completeReviewSession(sessionID: String, overallScore: Double?, summary: String, endedAt: Date = Date()) throws {
        try execBind("""
            UPDATE review_sessions
            SET status = 'completed', overall_score = ?, summary = ?, ended_at = ?
            WHERE id = ?
        """) { stmt in
            if let overallScore {
                sqlite3_bind_double(stmt, 1, overallScore)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            bind(stmt, 2, summary)
            sqlite3_bind_double(stmt, 3, endedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 4, sessionID)
        }
        noteStoreChanged()
    }

    /// Import a full external chat as a completed review. The transcript
    /// is parsed into individual question/answer exchanges so it displays per-turn
    /// and is searchable, rather than being stored as one opaque blob.
    /// `kind` is `.chat` for a chat that did not review its sources, so a later
    /// import into it knows not to mark them (see `markImportedChatAsChat`).
    @discardableResult
    func importReviewChatSession(
        id: String,
        title: String,
        turns: [ReviewChatTurn],
        sourceIDs: [String],
        goalID: String? = nil,
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        kind: ReviewSessionKind? = nil,
        chatKind: ChatKind? = nil,
        marksReviewed: Bool? = nil
    ) throws -> ReviewSessionRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw KnowledgeStoreError.invalidData("Session title is required.") }
        // A chat read from its client's record ran at the hours the record
        // says; one typed into a tool argument is dated at the import.
        let finishedAt = max(endedAt ?? createdAt, createdAt)
        let sourceIDsJSON = jsonString(from: sourceIDs)
        let trimmedSummary = trimmedNonEmpty(summary)
        let cleanedTurns = turns.filter {
            trimmedNonEmpty($0.question) != nil || trimmedNonEmpty($0.answer) != nil || trimmedNonEmpty($0.evaluation) != nil
        }
        let exchangeCount = cleanedTurns.count

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary, source_ids, card_ids, exchange_count, model_provider, model_id, goal_id, kind)
                VALUES (?, ?, ?, ?, 'completed', ?, ?, ?, '[]', ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, id)
                bind(stmt, 2, trimmedTitle)
                sqlite3_bind_double(stmt, 3, createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 4, finishedAt.timeIntervalSinceReferenceDate)
                if let overallScore {
                    sqlite3_bind_double(stmt, 5, overallScore)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                bind(stmt, 6, trimmedSummary)
                bind(stmt, 7, sourceIDsJSON)
                sqlite3_bind_int(stmt, 8, Int32(exchangeCount))
                bind(stmt, 9, trimmedNonEmpty(modelProvider))
                bind(stmt, 10, trimmedNonEmpty(modelID))
                bind(stmt, 11, trimmedNonEmpty(goalID))
                bind(stmt, 12, kind?.rawValue)
            }

            for (index, turn) in cleanedTurns.enumerated() {
                let exchangeID = UUID().uuidString
                try execBind("""
                    INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?)
                """) { stmt in
                    bind(stmt, 1, exchangeID)
                    bind(stmt, 2, id)
                    sqlite3_bind_int(stmt, 3, Int32(index + 1))
                    bind(stmt, 4, trimmedNonEmpty(turn.question) ?? "")
                    bind(stmt, 5, trimmedNonEmpty(turn.answer))
                    bind(stmt, 6, trimmedNonEmpty(turn.evaluation))
                    bind(stmt, 7, sourceIDsJSON)
                    sqlite3_bind_double(stmt, 8, (turn.answeredAt ?? createdAt).timeIntervalSinceReferenceDate)
                }
            }

            try replaceReviewSessionSources(sessionID: id, sourceIDs: sourceIDs)
            try keepChatShapeForGeneration2(sessionID: id, kind: chatKind, marksReviewed: marksReviewed)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return ReviewSessionRecord(
            id: id,
            title: trimmedTitle,
            url: nil,
            createdAt: createdAt,
            status: "completed",
            sourceIDs: sourceIDs,
            summary: trimmedSummary,
            overallScore: overallScore,
            exchangeCount: exchangeCount,
            modelProvider: trimmedNonEmpty(modelProvider),
            modelID: trimmedNonEmpty(modelID),
            goalID: trimmedNonEmpty(goalID)
        )
    }

    /// Append further parsed turns to an imported chat, for a chat too long to
    /// arrive in one call. Sequence numbers continue after the stored ones, the
    /// given sources join the session's, and a summary, score or model given
    /// here replaces the stored value while a nil leaves it alone. The session
    /// stays completed; its end moves to now so the Schedule reads it as
    /// finished when the last chunk lands.
    @discardableResult
    func appendReviewChatExchanges(
        sessionID: String,
        turns: [ReviewChatTurn],
        sourceIDs additionalSourceIDs: [String],
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        appendedAt: Date = Date()
    ) throws -> ReviewSessionRecord {
        let cleanedTurns = turns.filter {
            trimmedNonEmpty($0.question) != nil || trimmedNonEmpty($0.answer) != nil || trimmedNonEmpty($0.evaluation) != nil
        }
        guard !cleanedTurns.isEmpty else { throw KnowledgeStoreError.invalidData("The transcript had no readable messages.") }

        var existing: (title: String, createdAt: Date, sourceIDs: [String], summary: String?, overallScore: Double?, modelProvider: String?, modelID: String?)?
        try queryBind("""
            SELECT topic, started_at, source_ids, summary, overall_score, model_provider, model_id
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            existing = (
                title: self.string(stmt, 0) ?? "",
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                sourceIDs: self.decodeStringArray(json: self.string(stmt, 2)) ?? [],
                summary: self.string(stmt, 3),
                overallScore: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4),
                modelProvider: self.string(stmt, 5),
                modelID: self.string(stmt, 6)
            )
        }
        guard let existing else {
            throw KnowledgeStoreError.invalidData("No review session with id \(sessionID).")
        }

        let mergedSourceIDs = dictUnique(existing.sourceIDs + additionalSourceIDs)
        let sourceIDsJSON = jsonString(from: mergedSourceIDs)
        let mergedSummary = trimmedNonEmpty(summary) ?? existing.summary
        let mergedScore = overallScore ?? existing.overallScore
        let mergedProvider = trimmedNonEmpty(modelProvider) ?? existing.modelProvider
        let mergedModelID = trimmedNonEmpty(modelID) ?? existing.modelID
        // The chat's effort and speed describe its model: they stay while
        // the model does and go when an import names another.
        let keepsModelTuning = mergedProvider == existing.modelProvider && mergedModelID == existing.modelID

        var nextSequence = 1
        try queryBind("SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM review_exchanges WHERE session_id = ?", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            nextSequence = Int(sqlite3_column_int(stmt, 0))
        }

        var exchangeCount = 0
        try exec("BEGIN IMMEDIATE")
        do {
            for (offset, turn) in cleanedTurns.enumerated() {
                try execBind("""
                    INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?)
                """) { stmt in
                    bind(stmt, 1, UUID().uuidString)
                    bind(stmt, 2, sessionID)
                    sqlite3_bind_int(stmt, 3, Int32(nextSequence + offset))
                    bind(stmt, 4, trimmedNonEmpty(turn.question) ?? "")
                    bind(stmt, 5, trimmedNonEmpty(turn.answer))
                    bind(stmt, 6, trimmedNonEmpty(turn.evaluation))
                    bind(stmt, 7, sourceIDsJSON)
                    sqlite3_bind_double(stmt, 8, (turn.answeredAt ?? appendedAt).timeIntervalSinceReferenceDate)
                }
            }
            try queryBind("SELECT COUNT(*) FROM review_exchanges WHERE session_id = ?", bind: { stmt in
                bind(stmt, 1, sessionID)
            }) { stmt in
                exchangeCount = Int(sqlite3_column_int(stmt, 0))
            }
            try execBind("""
                UPDATE review_sessions
                SET ended_at = ?, status = 'completed', overall_score = ?, summary = ?, source_ids = ?,
                    exchange_count = ?, model_provider = ?, model_id = ?,
                    model_effort = CASE WHEN ? = 1 THEN model_effort END,
                    model_speed = CASE WHEN ? = 1 THEN model_speed END
                WHERE id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, appendedAt.timeIntervalSinceReferenceDate)
                if let mergedScore {
                    sqlite3_bind_double(stmt, 2, mergedScore)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                bind(stmt, 3, mergedSummary)
                bind(stmt, 4, sourceIDsJSON)
                sqlite3_bind_int(stmt, 5, Int32(exchangeCount))
                bind(stmt, 6, mergedProvider)
                bind(stmt, 7, mergedModelID)
                sqlite3_bind_int(stmt, 8, keepsModelTuning ? 1 : 0)
                sqlite3_bind_int(stmt, 9, keepsModelTuning ? 1 : 0)
                bind(stmt, 10, sessionID)
            }
            try replaceReviewSessionSources(sessionID: sessionID, sourceIDs: mergedSourceIDs)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return ReviewSessionRecord(
            id: sessionID,
            title: existing.title,
            url: nil,
            createdAt: existing.createdAt,
            status: "completed",
            sourceIDs: mergedSourceIDs,
            summary: mergedSummary,
            overallScore: mergedScore,
            exchangeCount: exchangeCount,
            modelProvider: mergedProvider,
            modelID: mergedModelID
        )
    }

    /// What reconciling an imported chat with its client's record did.
    struct ReviewChatReconciliation {
        let record: ReviewSessionRecord
        /// Exchanges the record had gained since the last import.
        let appended: Int
        /// Stored exchanges that disagreed with the record and were rewritten
        /// from it — a retyped or shortened turn an earlier call had saved.
        let replaced: Int
    }

    /// Make an imported chat's stored exchanges equal to the turns read from
    /// its client's record. The record is the conversation as it happened, so
    /// it is authoritative: the longest run of stored exchanges that already
    /// match it keep their rows (and ids), whatever follows is deleted, and the
    /// record's remaining turns are written in their place — a repeat call on
    /// an unchanged record writes nothing. The session stays completed and its
    /// end moves to the record's last turn, so the Schedule reads the hours
    /// the chat actually ran.
    @discardableResult
    func reconcileReviewChatExchanges(
        sessionID: String,
        turns: [ReviewChatTurn],
        sourceIDs additionalSourceIDs: [String],
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        endedAt: Date?,
        reconciledAt: Date = Date()
    ) throws -> ReviewChatReconciliation {
        let cleanedTurns = turns.filter {
            trimmedNonEmpty($0.question) != nil || trimmedNonEmpty($0.answer) != nil || trimmedNonEmpty($0.evaluation) != nil
        }
        guard !cleanedTurns.isEmpty else { throw KnowledgeStoreError.invalidData("The transcript had no readable messages.") }

        var existing: (title: String, createdAt: Date, sourceIDs: [String], summary: String?, overallScore: Double?, modelProvider: String?, modelID: String?, goalID: String?)?
        try queryBind("""
            SELECT topic, started_at, source_ids, summary, overall_score, model_provider, model_id, goal_id
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            existing = (
                title: self.string(stmt, 0) ?? "",
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                sourceIDs: self.decodeStringArray(json: self.string(stmt, 2)) ?? [],
                summary: self.string(stmt, 3),
                overallScore: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4),
                modelProvider: self.string(stmt, 5),
                modelID: self.string(stmt, 6),
                goalID: self.string(stmt, 7)
            )
        }
        guard let existing else {
            throw KnowledgeStoreError.invalidData("No review session with id \(sessionID).")
        }

        let stored = try loadReviewExchanges(sessionID: sessionID).sorted { $0.sequenceNumber < $1.sequenceNumber }
        var kept = 0
        while kept < stored.count, kept < cleanedTurns.count {
            let exchange = stored[kept]
            let turn = cleanedTurns[kept]
            guard exchange.question == (trimmedNonEmpty(turn.question) ?? ""),
                  exchange.userAnswer == trimmedNonEmpty(turn.answer),
                  exchange.evaluation == trimmedNonEmpty(turn.evaluation) else { break }
            kept += 1
        }
        let replaced = stored.count - kept
        let appended = cleanedTurns.count - kept - min(replaced, cleanedTurns.count - kept)

        let mergedSourceIDs = dictUnique(existing.sourceIDs + additionalSourceIDs)
        let sourceIDsJSON = jsonString(from: mergedSourceIDs)
        let mergedSummary = trimmedNonEmpty(summary) ?? existing.summary
        let mergedScore = overallScore ?? existing.overallScore
        let mergedProvider = trimmedNonEmpty(modelProvider) ?? existing.modelProvider
        let mergedModelID = trimmedNonEmpty(modelID) ?? existing.modelID
        // The chat's effort and speed describe its model: they stay while
        // the model does and go when an import names another.
        let keepsModelTuning = mergedProvider == existing.modelProvider && mergedModelID == existing.modelID
        let finishedAt = max(endedAt ?? cleanedTurns.last?.answeredAt ?? reconciledAt, existing.createdAt)

        try exec("BEGIN IMMEDIATE")
        do {
            if replaced > 0 {
                let dropFrom = stored[kept].sequenceNumber
                try execBind("DELETE FROM review_exchanges WHERE session_id = ? AND sequence_number >= ?") { stmt in
                    bind(stmt, 1, sessionID)
                    sqlite3_bind_int(stmt, 2, Int32(dropFrom))
                }
            }
            var nextSequence = (stored.prefix(kept).last?.sequenceNumber ?? 0) + 1
            for turn in cleanedTurns.dropFirst(kept) {
                try execBind("""
                    INSERT INTO review_exchanges (id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?)
                """) { stmt in
                    bind(stmt, 1, UUID().uuidString)
                    bind(stmt, 2, sessionID)
                    sqlite3_bind_int(stmt, 3, Int32(nextSequence))
                    bind(stmt, 4, trimmedNonEmpty(turn.question) ?? "")
                    bind(stmt, 5, trimmedNonEmpty(turn.answer))
                    bind(stmt, 6, trimmedNonEmpty(turn.evaluation))
                    bind(stmt, 7, sourceIDsJSON)
                    sqlite3_bind_double(stmt, 8, (turn.answeredAt ?? reconciledAt).timeIntervalSinceReferenceDate)
                }
                nextSequence += 1
            }
            try execBind("""
                UPDATE review_sessions
                SET ended_at = ?, status = 'completed', overall_score = ?, summary = ?, source_ids = ?,
                    exchange_count = ?, model_provider = ?, model_id = ?,
                    model_effort = CASE WHEN ? = 1 THEN model_effort END,
                    model_speed = CASE WHEN ? = 1 THEN model_speed END
                WHERE id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, finishedAt.timeIntervalSinceReferenceDate)
                if let mergedScore {
                    sqlite3_bind_double(stmt, 2, mergedScore)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                bind(stmt, 3, mergedSummary)
                bind(stmt, 4, sourceIDsJSON)
                sqlite3_bind_int(stmt, 5, Int32(cleanedTurns.count))
                bind(stmt, 6, mergedProvider)
                bind(stmt, 7, mergedModelID)
                sqlite3_bind_int(stmt, 8, keepsModelTuning ? 1 : 0)
                sqlite3_bind_int(stmt, 9, keepsModelTuning ? 1 : 0)
                bind(stmt, 10, sessionID)
            }
            try replaceReviewSessionSources(sessionID: sessionID, sourceIDs: mergedSourceIDs)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return ReviewChatReconciliation(
            record: ReviewSessionRecord(
                id: sessionID,
                title: existing.title,
                url: nil,
                createdAt: existing.createdAt,
                status: "completed",
                sourceIDs: mergedSourceIDs,
                summary: mergedSummary,
                overallScore: mergedScore,
                exchangeCount: cleanedTurns.count,
                modelProvider: mergedProvider,
                modelID: mergedModelID,
                goalID: existing.goalID
            ),
            appended: appended,
            replaced: replaced
        )
    }

}
