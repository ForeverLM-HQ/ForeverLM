// KnowledgeStore: review session links, hidden state, loading, and deleting sessions.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    /// Returns the IDs of review sessions whose title, summary, or any stored
    /// exchange text matches the query. Powers transcript-content search in the app.
    func searchReviewSessionIDs(matching query: String) throws -> Set<String> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let like = "%\(trimmed)%"
        var ids = Set<String>()
        try queryBind("""
            SELECT DISTINCT fs.id
            FROM review_sessions fs
            LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
            WHERE fs.topic LIKE ?1
               OR fs.summary LIKE ?1
               OR fe.question LIKE ?1
               OR fe.user_answer LIKE ?1
               OR fe.evaluation LIKE ?1
        """, bind: { stmt in
            bind(stmt, 1, like)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    func reopenReviewSession(sessionID: String) throws {
        var shouldReopen = false
        try queryBind("SELECT status FROM review_sessions WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            shouldReopen = string(stmt, 0) == "completed"
        }
        guard shouldReopen else { return }

        try execBind("""
            UPDATE review_sessions
            SET status = 'active', ended_at = NULL
            WHERE id = ?
              AND status = 'completed'
        """) { stmt in
            bind(stmt, 1, sessionID)
        }
        noteStoreChanged()
    }

    @discardableResult
    func saveReviewSessionLink(title: String, url: String, sourceIDs: [String] = [], createdAt: Date = Date()) throws -> ReviewSessionRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw KnowledgeStoreError.invalidData("Session title is required.") }
        guard let parsedURL = URL(string: trimmedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              parsedURL.host != nil else {
            throw KnowledgeStoreError.invalidData("A valid external chat URL is required.")
        }

        if let existing = try loadReviewSessionLink(url: trimmedURL) {
            let sourceIDsJSON = jsonString(from: sourceIDs)
            try exec("BEGIN IMMEDIATE")
            do {
            try execBind("""
                UPDATE review_sessions
                    SET topic = ?, started_at = ?, source_ids = ?
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, trimmedTitle)
                sqlite3_bind_double(stmt, 2, createdAt.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, sourceIDsJSON)
                    bind(stmt, 4, existing.id)
            }
                try replaceReviewSessionSources(sessionID: existing.id, sourceIDs: sourceIDs)
                noteStoreChanged()
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
            return ReviewSessionRecord(
                id: existing.id,
                title: trimmedTitle,
                url: existing.url,
                createdAt: createdAt,
                status: existing.status,
                sourceIDs: sourceIDs,
                modelProvider: existing.modelProvider,
                modelID: existing.modelID
            )
        }

        let id = UUID().uuidString
        let sourceIDsJSON = jsonString(from: sourceIDs)
        try exec("BEGIN IMMEDIATE")
        do {
        try execBind("""
            INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary, source_ids, card_ids, exchange_count)
                VALUES (?, ?, ?, NULL, 'external_link', NULL, ?, ?, '[]', 0)
        """) { stmt in
            bind(stmt, 1, id)
            bind(stmt, 2, trimmedTitle)
            sqlite3_bind_double(stmt, 3, createdAt.timeIntervalSinceReferenceDate)
            bind(stmt, 4, trimmedURL)
                bind(stmt, 5, sourceIDsJSON)
        }
            try replaceReviewSessionSources(sessionID: id, sourceIDs: sourceIDs)
            try keepChatShapeForGeneration2(sessionID: id, kind: .chat)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return ReviewSessionRecord(id: id, title: trimmedTitle, url: trimmedURL, createdAt: createdAt, status: "external_link", sourceIDs: sourceIDs)
    }

    func loadReviewSessionLinks() throws -> [ReviewSessionRecord] {
        var links: [ReviewSessionRecord] = []
        let sourceIDsBySessionID = try reviewSessionSourceIDsBySessionID()
        try query("""
            SELECT fs.id, fs.topic, fs.summary, fs.started_at, fs.status, fs.source_ids,
                   fs.overall_score, fs.exchange_count, fs.model_provider, fs.model_id, fs.goal_id, fs.team_id,
                   h.hidden_at
            FROM review_sessions fs
            LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
            ORDER BY fs.started_at DESC
        """) { stmt in
            guard let id = self.string(stmt, 0),
                  let title = self.string(stmt, 1),
                  let status = self.string(stmt, 4) else { return }
            let rawSummary = self.string(stmt, 2)
            let isURL = rawSummary?.hasPrefix("https://") == true || rawSummary?.hasPrefix("http://") == true
            let url = isURL ? rawSummary : nil
            let summary = isURL ? nil : rawSummary
            let overallScore: Double? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            let exchangeCount = Int(sqlite3_column_int(stmt, 7))
            let modelProvider = self.string(stmt, 8)
            let modelID = self.string(stmt, 9)
            let goalID = self.string(stmt, 10)
            let sourceIDs = self.decodeStringArray(json: self.string(stmt, 5)) ?? []
            links.append(ReviewSessionRecord(
                id: id,
                title: title,
                url: url,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                status: status,
                sourceIDs: sourceIDs.isEmpty ? (sourceIDsBySessionID[id] ?? []) : sourceIDs,
                summary: summary,
                overallScore: overallScore,
                exchangeCount: exchangeCount,
                modelProvider: modelProvider,
                modelID: modelID,
                goalID: goalID,
                teamID: self.string(stmt, 11),
                hiddenAt: sqlite3_column_type(stmt, 12) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 12))
            ))
        }
        return links
    }

    /// When a chat was hidden from the sidebar, or nil when it is shown. Nil
    /// also for a session that does not exist; callers that need the
    /// distinction check `loadReviewSessionForSync` first.
    func reviewSessionHiddenAt(sessionID: String) throws -> Date? {
        var hiddenAt: Date?
        try queryBind("SELECT hidden_at FROM hidden_review_sessions WHERE session_id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, sessionID)
        }) { stmt in
            hiddenAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return hiddenAt
    }

    /// Hides a chat from the sidebar, or shows it again, on every Mac signed
    /// into this account. The hide is a `hidden_review_sessions` row, never a
    /// field of the chat: `saveReviewSessionRecord` cannot touch it, so a
    /// CloudKit merge of the same chat leaves the learner's choice standing,
    /// and the chat itself is not marked changed — hiding is the learner's
    /// view of the chat, not a fact about it. The row syncs as a private-zone
    /// `HiddenReviewSession`, so a team snapshot hidden here is hidden for
    /// this account alone. Re-hiding a hidden chat keeps its original date;
    /// showing a shown chat is a no-op. Returns the resulting date, or nil
    /// when the chat is shown or does not exist.
    @discardableResult
    func setReviewSessionHidden(_ sessionID: String, hidden: Bool) throws -> Date? {
        var exists = false
        try queryBind("SELECT 1 FROM review_sessions WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, sessionID)
        }) { _ in exists = true }
        guard exists else { return nil }
        let existing = try reviewSessionHiddenAt(sessionID: sessionID)
        if hidden {
            if let existing { return existing }
            let hiddenAt = Date()
            try execBind("INSERT INTO hidden_review_sessions (session_id, hidden_at) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET hidden_at = excluded.hidden_at") { stmt in
                self.bind(stmt, 1, sessionID)
                sqlite3_bind_double(stmt, 2, hiddenAt.timeIntervalSinceReferenceDate)
            }
            return hiddenAt
        }
        guard existing != nil else { return nil }
        try execBind("DELETE FROM hidden_review_sessions WHERE session_id = ?") { stmt in
            self.bind(stmt, 1, sessionID)
        }
        return nil
    }

    func loadReviewSessionExchanges(sessionID: String) throws -> [ReviewExchangeRecord] {
        try loadReviewExchanges(sessionID: sessionID).map {
            ReviewExchangeRecord(
                id: $0.id,
                sessionID: $0.sessionID,
                sequenceNumber: $0.sequenceNumber,
                question: $0.question,
                userAnswer: $0.userAnswer,
                evaluation: $0.evaluation,
                score: $0.score,
                sourceRefs: $0.sourceRefs,
                knowledgeNote: $0.knowledgeNote,
                answeredAt: $0.answeredAt,
                contextContent: $0.contextContent,
                ideaCoverage: $0.ideaCoverage,
                questionVerdict: $0.questionVerdict,
                operation: $0.operation,
                steer: $0.steer,
                rating: $0.rating.flatMap(ReviewTurnRating.init(rawValue:)),
                ratingReason: $0.ratingReason,
                ratingField: $0.ratingField.flatMap(ReviewExchangeMessageField.init(rawValue:)),
                ratedAt: $0.ratedAt
            )
        }
    }

    func deleteReviewExchangeMessage(
        sessionID: String,
        exchangeID: String,
        field: ReviewExchangeMessageField
    ) throws {
        var existingSessionID: String?
        try queryBind("""
            SELECT session_id
            FROM review_exchanges
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, exchangeID)
        }) { stmt in
            existingSessionID = self.string(stmt, 0)
        }

        guard existingSessionID == sessionID else {
            throw KnowledgeStoreError.invalidData("Chat message could not be found in this session.")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            var protectsImmutableMemoryAttempt = false
            try queryBind("""
                SELECT 1
                FROM memory_attempts
                WHERE session_id = ? AND exchange_id = ?
                LIMIT 1
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
                bind(stmt, 2, exchangeID)
            }) { _ in
                protectsImmutableMemoryAttempt = true
            }
            guard !protectsImmutableMemoryAttempt else {
                throw KnowledgeStoreError.invalidData(
                    "A transcript message linked to immutable memory history cannot be edited or removed."
                )
            }

            switch field {
            case .question:
                try execBind("UPDATE review_exchanges SET question = '' WHERE id = ? AND session_id = ?") { stmt in
                    bind(stmt, 1, exchangeID)
                    bind(stmt, 2, sessionID)
                }
            case .userAnswer:
                try execBind("""
                    UPDATE review_exchanges
                    SET user_answer = NULL,
                        answered_at = CASE
                            WHEN evaluation IS NULL OR TRIM(evaluation) = '' THEN NULL
                            ELSE answered_at
                        END
                    WHERE id = ? AND session_id = ?
                """) { stmt in
                    bind(stmt, 1, exchangeID)
                    bind(stmt, 2, sessionID)
                }
            case .evaluation:
                try execBind("""
                    UPDATE review_exchanges
                    SET evaluation = NULL,
                        score = NULL,
                        knowledge_note = NULL,
                        answered_at = CASE
                            WHEN user_answer IS NULL OR TRIM(user_answer) = '' THEN NULL
                            ELSE answered_at
                        END
                    WHERE id = ? AND session_id = ?
                """) { stmt in
                    bind(stmt, 1, exchangeID)
                    bind(stmt, 2, sessionID)
                }
            }

            try execBind("""
                DELETE FROM review_exchanges
                WHERE session_id = ?
                  AND TRIM(question) = ''
                  AND (user_answer IS NULL OR TRIM(user_answer) = '')
                  AND (evaluation IS NULL OR TRIM(evaluation) = '')
            """) { stmt in
                bind(stmt, 1, sessionID)
            }

            var exchangeIDs: [String] = []
            try queryBind("""
                SELECT id
                FROM review_exchanges
                WHERE session_id = ?
                ORDER BY sequence_number ASC
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
            }) { stmt in
                if let id = self.string(stmt, 0) {
                    exchangeIDs.append(id)
                }
            }

            for (index, id) in exchangeIDs.enumerated() {
                try execBind("""
                    UPDATE review_exchanges
                    SET sequence_number = ?
                    WHERE id = ?
                """) { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(index + 1))
                    bind(stmt, 2, id)
                }
            }

            try execBind("UPDATE review_sessions SET exchange_count = ? WHERE id = ?") { stmt in
                sqlite3_bind_int(stmt, 1, Int32(exchangeIDs.count))
                bind(stmt, 2, sessionID)
            }

            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadReviewSessionLink(url: String) throws -> ReviewSessionRecord? {
        var link: ReviewSessionRecord?
        let sourceIDsBySessionID = try reviewSessionSourceIDsBySessionID()
        try queryBind("""
            SELECT id, topic, summary, started_at, status, source_ids, model_provider, model_id
            FROM review_sessions
            WHERE status = 'external_link' AND summary = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, url)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let title = self.string(stmt, 1),
                  let storedURL = self.string(stmt, 2),
                  let status = self.string(stmt, 4) else { return }
            let sourceIDs = self.decodeStringArray(json: self.string(stmt, 5)) ?? []
            link = ReviewSessionRecord(
                id: id,
                title: title,
                url: storedURL,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                status: status,
                sourceIDs: sourceIDs.isEmpty ? (sourceIDsBySessionID[id] ?? []) : sourceIDs,
                modelProvider: self.string(stmt, 6),
                modelID: self.string(stmt, 7)
            )
        }
        return link
    }

    func loadReviewSessionForSync(_ sessionID: String) throws -> CloudKitReviewSessionPayload? {
        var payload: CloudKitReviewSessionPayload?
        try queryBind("""
            SELECT id, topic, started_at, ended_at, status, overall_score, summary, source_ids, card_ids, exchange_count, model_provider, model_id, goal_id, kind, briefing, team_id,
                   model_effort, model_speed
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let topic = self.string(stmt, 1),
                  let status = self.string(stmt, 4) else { return }
            let sourceIDs = self.decodeStringArray(json: self.string(stmt, 7)) ?? []
            let cardIDs = self.decodeStringArray(json: self.string(stmt, 8)) ?? []
            payload = CloudKitReviewSessionPayload(
                id: id,
                topic: topic,
                startedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
                endedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                status: status,
                overallScore: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                summary: self.string(stmt, 6),
                sourceIDs: sourceIDs,
                cardIDs: cardIDs,
                exchangeCount: Int(sqlite3_column_int(stmt, 9)),
                modelProvider: self.string(stmt, 10),
                modelID: self.string(stmt, 11),
                modelEffort: self.string(stmt, 16),
                modelSpeed: self.string(stmt, 17),
                goalID: self.string(stmt, 12),
                exchanges: [],
                kind: self.string(stmt, 13),
                briefing: self.string(stmt, 14),
                teamID: self.string(stmt, 15)
            )
        }

        guard var session = payload else { return nil }
        let exchanges = try loadReviewExchanges(sessionID: sessionID)
        let identitySourceIDs = dictUnique(session.sourceIDs + exchanges.flatMap(\.sourceRefs))
        session = CloudKitReviewSessionPayload(
            id: session.id,
            topic: session.topic,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            status: session.status,
            overallScore: session.overallScore,
            summary: session.summary,
            sourceIDs: session.sourceIDs,
            cardIDs: session.cardIDs,
            exchangeCount: session.exchangeCount,
            modelProvider: session.modelProvider,
            modelID: session.modelID,
            modelEffort: session.modelEffort,
            modelSpeed: session.modelSpeed,
            goalID: session.goalID,
            exchanges: exchanges,
            sourceIdentities: try sourceIdentities(for: identitySourceIDs),
            docLinks: try artifactChatLinks(sessionID: sessionID).map {
                CloudKitArtifactChatLinkPayload(
                    id: $0.id,
                    artifactID: $0.artifactID,
                    anchorRevision: $0.anchorRevision,
                    anchorStart: $0.anchorStart,
                    anchorEnd: $0.anchorEnd,
                    anchorQuote: $0.anchorQuote,
                    sectionTitle: $0.sectionTitle,
                    createdAt: $0.createdAt
                )
            },
            kind: session.kind,
            briefing: session.briefing,
            teamID: session.teamID
        )
        return session
    }

    /// Loads the app-owned target identities attached to a review session.
    /// Memory Review Chat uses these to restore its exact queue even when the
    /// app stopped before the first learner answer produced a MemoryAttempt.
    func loadReviewSessionCardIDs(sessionID: String) throws -> [String] {
        var cardIDs: [String] = []
        var found = false
        try queryBind("""
            SELECT card_ids
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            found = true
            guard let raw = self.string(stmt, 0),
                  let decoded = self.decodeStringArray(json: raw) else {
                throw KnowledgeStoreError.invalidData(
                    "The saved review contains invalid target identities."
                )
            }
            cardIDs = decoded
        }
        guard found else {
            throw KnowledgeStoreError.invalidData("The saved review no longer exists.")
        }
        return cardIDs
    }

    func deleteReviewSession(_ sessionID: String) throws {
        try requireSpaceDeletion(.chat, sessionID)
        // One transaction: either the session and its linked immutable memory
        // attempts go together, or neither does. Retaining attempts after their
        // exact transcript disappears would leave broken relationships.
        try exec("BEGIN IMMEDIATE")
        do {
            var memoryItemIDs = Set<String>()
            try queryBind("""
                SELECT DISTINCT memory_item_id
                FROM memory_attempts
                WHERE session_id = ?
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
            }) { stmt in
                if let memoryItemID = self.string(stmt, 0) { memoryItemIDs.insert(memoryItemID) }
            }
            try execBind("DELETE FROM memory_attempts WHERE session_id = ?") { stmt in
                bind(stmt, 1, sessionID)
            }
            try execBind("DELETE FROM review_sessions WHERE id = ?", { stmt in
                bind(stmt, 1, sessionID)
            })
            // The hide goes with the chat.
            try execBind("DELETE FROM hidden_review_sessions WHERE session_id = ?") { stmt in
                bind(stmt, 1, sessionID)
            }
            for memoryItemID in memoryItemIDs.sorted() {
                try rebuildMemorySchedule(memoryItemID: memoryItemID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Delete a local review that has no learner-authored transcript to resume.
    ///
    /// The eligibility check and deletion share one write transaction so a review
    /// completed by another client cannot be removed between the check and delete.
    /// External chat links are never eligible, and neither is a chat that has
    /// played walkthrough steps: the steps it shows are the walk so far, kept
    /// like a memory review's opening question even before the learner types
    /// (walkthrough-design.md, "the panel becomes a chat").
    @discardableResult
    func deleteReviewSessionIfNoRecordedConversation(_ sessionID: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            var shouldDelete = false
            try queryBind("""
                SELECT fs.card_ids
                FROM review_sessions fs
                WHERE fs.id = ?
                  AND fs.status IN ('active', 'completed')
                  AND NOT EXISTS (
                      SELECT 1
                      FROM review_exchanges fe
                      WHERE fe.session_id = fs.id
                        AND fe.user_answer IS NOT NULL
                        AND TRIM(fe.user_answer) != ''
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM review_exchanges fw
                      WHERE fw.session_id = fs.id
                        AND fw.question LIKE ?
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM memory_attempts ma
                      WHERE ma.session_id = fs.id
                  )
                LIMIT 1
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
                bind(stmt, 2, "%<\(WalkthroughStepTurn.tagName) %")
            }) { stmt in
                guard let rawCardIDs = self.string(stmt, 0),
                      let cardIDs = self.decodeStringArray(json: rawCardIDs) else {
                    // Unknown/malformed target identity is meaningful state. Fail
                    // closed rather than deleting a review we cannot classify.
                    return
                }
                shouldDelete = cardIDs.isEmpty
            }

            guard shouldDelete else {
                try exec("COMMIT")
                return false
            }

            try execBind("DELETE FROM review_sessions WHERE id = ?", { stmt in
                bind(stmt, 1, sessionID)
            })
            if try reviewSessionHiddenAt(sessionID: sessionID) != nil {
                try execBind("DELETE FROM hidden_review_sessions WHERE session_id = ?") { stmt in
                    bind(stmt, 1, sessionID)
                }
            }
            try exec("COMMIT")
            return true
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Replace the set of sources linked to an existing review session.
    func updateReviewSessionSources(sessionID: String, sourceIDs: [String]) throws {
        let sourceIDsJSON = jsonString(from: sourceIDs)
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("UPDATE review_sessions SET source_ids = ? WHERE id = ?") { stmt in
                bind(stmt, 1, sourceIDsJSON)
                bind(stmt, 2, sessionID)
            }
            try replaceReviewSessionSources(sessionID: sessionID, sourceIDs: sourceIDs)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

}
