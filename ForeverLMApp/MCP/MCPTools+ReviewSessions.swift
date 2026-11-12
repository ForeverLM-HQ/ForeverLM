import CryptoKit
import Foundation
import OSLog

private struct PreparedMCPMemoryReview {
    let items: [MemoryItem]
    let attempts: [MemoryAttempt]
    let expectedCurriculumFingerprints: [String: String]

    static let empty = PreparedMCPMemoryReview(
        items: [],
        attempts: [],
        expectedCurriculumFingerprints: [:]
    )
}

struct MCPOperationSessionIdentity {
    let sessionID: String
    let sessionIDPrefix: String
}

extension MCPDataStore {

    // MARK: - Review Sessions

    func startReviewSession(
        topic: String,
        sourceID: String? = nil,
        sourceIDs requestedSourceIDs: [String] = [],
        operationID: String? = nil,
        hostSessionID: String? = nil
    ) async throws -> String {
        try await startScopedReviewSession(
            topic: topic,
            sourceID: sourceID,
            sourceIDs: requestedSourceIDs,
            notebookID: nil,
            operationID: operationID,
            hostSessionID: hostSessionID
        )
    }

    /// Notebook-aware entry point used by MCP dispatch. Kept separate from the
    /// longstanding unscoped signature so existing in-app callers cannot inherit
    /// Notebook context accidentally.
    func startScopedReviewSession(
        topic: String,
        sourceID: String? = nil,
        sourceIDs requestedSourceIDs: [String] = [],
        notebookID: String?,
        operationID: String? = nil,
        hostSessionID: String? = nil
    ) async throws -> String {
        let rawNotebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitNotebook: LearningGoalRecord?
        if rawNotebookID.isEmpty {
            explicitNotebook = nil
        } else {
            explicitNotebook = try resolveMCPChatHome(notebookID: rawNotebookID, store: knowledgeStore())
        }
        let explicitSourceIDs = sanitizedSourceIDs(([sourceID].compactMap { $0 }) + requestedSourceIDs)
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)
        if let excludedSourceID = explicitSourceIDs.first(where: { excludedSourceIDs.contains($0) }) {
            throw MCPError.invalidInput(
                "source_id \(excludedSourceID) is excluded from knowledge search and AI in ForeverLM Settings."
            )
        }
        if let explicitNotebook {
            guard !explicitSourceIDs.isEmpty else {
                throw MCPError.invalidInput(
                    "source_id or source_ids is required when notebook_id is provided. Use list_notebook_sources with notebook_id \(explicitNotebook.id) to choose approved sources."
                )
            }
            // The sources its chats draw on: its own and those of the context
            // notebooks the learner put in, ticked or not.
            let approved = Set(notebookChatPoolSourceIDs(goal: explicitNotebook, store: try knowledgeStore()))
            if let outsideNotebook = explicitSourceIDs.first(where: { !approved.contains($0) }) {
                throw MCPError.invalidInput(
                    "source_id \(outsideNotebook) is not approved in Notebook '\(explicitNotebook.title)'. Use list_notebook_sources with notebook_id \(explicitNotebook.id)."
                )
            }
        }
        let hostSession = try resolvedHostSessionID(hostSessionID)
        // What a review bound to the in-app chat covered, filed in the chat's
        // Notebook once the session is written (`fileReviewedSourcesInSessionNotebook`).
        var reviewedInHostSession: [String] = []
        let started = try withDB { db in
            let normalizedTopic = normalizedReviewTopic(topic)
            // Notebook attribution is request-scoped. App selection alone never
            // attaches a review to a Notebook.
            let linkedGoalID = explicitNotebook?.id
            // An idempotency key is for callers with no session of their own. The
            // in-app chat's session already is that key, so its value is ignored
            // rather than rejected.
            let operationSession = try hostSession != nil ? nil : deterministicMCPOperationSessionIdentity(
                operationID,
                namespace: "start-review-session-v1",
                sessionPrefix: "mcp-review-session",
                requestFields: [
                    "version": 1,
                    "topic": normalizedTopic,
                    "source_ids": explicitSourceIDs,
                    "notebook_id": linkedGoalID ?? NSNull(),
                ]
            )
            let existingOperationSession: CloudKitReviewSessionPayload?
            if hostSession == nil, let operationSession {
                if let conflictingID = try existingMCPOperationSessionID(
                    prefix: operationSession.sessionIDPrefix
                ), conflictingID != operationSession.sessionID {
                    throw MCPError.invalidInput(
                        "operation_id was already used with different start_review_session arguments. Use a new operation_id."
                    )
                }
                if let existing = try knowledgeStore().loadReviewSessionForSync(
                    operationSession.sessionID
                ) {
                    guard existing.status == "active",
                          existing.topic == normalizedTopic,
                          existing.goalID == linkedGoalID,
                          (explicitSourceIDs.isEmpty || existing.sourceIDs == explicitSourceIDs),
                          existing.cardIDs.isEmpty else {
                        throw MCPError.invalidInput(
                            "operation_id was already used for a different or completed review session. Use a new operation_id."
                        )
                    }
                    existingOperationSession = existing
                } else {
                    existingOperationSession = nil
                }
            } else {
                existingOperationSession = nil
            }

            // An exact provider retry reuses the sources stored on its durable
            // session. Do not run topic discovery again: a concurrent sync or a
            // newly imported source must not mutate the already-returned review.
            let sources: [[String: Any]]
            let sourceIDs: [String]
            if let existingOperationSession {
                if let excludedSourceID = existingOperationSession.sourceIDs.first(where: { excludedSourceIDs.contains($0) }) {
                    throw MCPError.invalidInput(
                        "source_id \(excludedSourceID) is excluded from knowledge search and AI in ForeverLM Settings."
                    )
                }
                sourceIDs = existingOperationSession.sourceIDs
                sources = try sourceRows(db, sourceIDs: sourceIDs)
            } else {
                let candidates = try explicitSourceIDs.isEmpty
                    ? findReviewSessionSources(db, topic: normalizedTopic)
                    : sourceRows(db, sourceIDs: explicitSourceIDs)
                sources = candidates.filter { row in
                    guard let id = row["id"] as? String else { return false }
                    return !excludedSourceIDs.contains(id)
                }
                sourceIDs = sources.compactMap { $0["id"] as? String }
            }

            // In-app Chat already opened and persists this session turn by turn, so
            // the review binds to it. Creating a second row here would leave an
            // exchange-less session in the browser that can never be resumed.
            let sessionID: String
            if let hostSession {
                sessionID = hostSession
                try linkReviewSessionSources(sessionID: hostSession, adding: sourceIDs)
                reviewedInHostSession = sourceIDs
            } else {
                sessionID = operationSession?.sessionID ?? UUID().uuidString
                if existingOperationSession == nil {
                    try knowledgeStore().createReviewSession(
                        id: sessionID,
                        topic: normalizedTopic,
                        sourceIDs: sourceIDs,
                        startedAt: Date(),
                        goalID: linkedGoalID,
                        scheduleActivityAt: Date(),
                        scheduleActivityKind: .review,
                        chatKind: .review
                    )
                }
            }

            // Host-owned in-app chats do not pass through session creation here,
            // so log the review start explicitly as well. The operation is
            // idempotent for newly created sessions and preplanned sources.
            for sourceID in sourceIDs {
                try knowledgeStore().recordScheduledSourceActivity(
                    sourceID: sourceID,
                    on: Date(),
                    kind: .review
                )
            }

            let destinationLine: String = {
                if let notebook = explicitNotebook {
                    return "This review is saved into ForeverLM, linked to your Notebook \"\(notebook.title)\"."
                }
                return "This review is saved into ForeverLM."
            }()

            // Bound to the in-app chat, the transcript is already being written turn
            // by turn, so asking for an export would only duplicate it.
            let closingLine = hostSession == nil
                ? "Only after the learner explicitly asks to stop or confirms they want to finish, call end_review_session with this Session ID, the score, a summary, and the full transcript to save it."
                : "This chat is the review session — every message is already recorded, so no transcript needs to be exported. Only after the learner explicitly asks to stop or confirms they want to finish, call end_review_session with this Session ID, the score, and a summary."

            // Load source content for context
            var context = """
            Review session started: \(normalizedTopic)
            Session ID: \(sessionID)
            (The Session ID above is internal bookkeeping for your end_review_session call only — never show it to the learner.)
            \(destinationLine)
            \(closingLine)

            Presentation: Do not open your reply with a status line such as "Review started", the Session ID, or a "Source: …" preamble — the app already shows that the review has begun. Begin directly with the review-plan checklist, then your first question.

            Review structure:
            - Before the first question, infer 3-7 core concepts from the source material when available, or from the topic otherwise, and show them as a compact checklist.
            - Keep the checklist dynamic: mark concepts covered and add or revise items when needed. Covering it does not end the review. Continue for as many turns or hours as the learner wants by going deeper, revisiting gaps, making connections, or following their questions; do not proactively suggest ending.
            - Do not summarize the source up front; use short concept labels until the learner attempts an answer or asks for help.
            - Ask one deep, mechanism-level question at a time.
            - Never say goodbye, tell the learner they are done, or call end_review_session unless they explicitly ask to stop or confirm that they want to finish.

            Related sources (\(sources.count)):
            """
            for s in sources {
                // Each source as the link a reply can show (Prompts.hiddenIDs).
                let link = Self.sourceLink(title: s["title"] as? String ?? "", id: s["id"] as? String ?? "")
                context += "\n- \(link) (\(s["source_type"] as? String ?? ""), \(s["word_count"] as? Int ?? 0) words)"
            }

            // Load content for context
            if !sourceIDs.isEmpty {
                let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
                let contentRows = try query(db, """
                    SELECT sp.title, sc.content
                    FROM source_projection sp
                    JOIN source_content sc ON sp.id = sc.source_id
                    WHERE sp.id IN (\(placeholders))
                """, params: sourceIDs)
                for r in contentRows {
                    let title = r["title"] as? String ?? ""
                    let content = r["content"] as? String ?? ""
                    let preview = String(content.prefix(2000))
                    context += "\n\n---\n## \(title)\n\(preview)"
                }
            }

            // Past sessions
            let pastSessions = try query(db, """
                SELECT id, overall_score, summary, started_at FROM review_sessions
                WHERE topic LIKE ? AND status = 'completed'
                ORDER BY started_at DESC LIMIT 3
            """, params: ["%\(normalizedTopic)%"])
            if !pastSessions.isEmpty {
                context += "\n\nPast sessions:"
                for ps in pastSessions {
                    let score = ps["overall_score"] as? Double ?? 0
                    let summary = ps["summary"] as? String ?? ""
                    context += "\n- Score: \(String(format: "%.0f%%", score * 100)) — \(summary)"
                }
            }

            return context
        }
        if let hostSession {
            // Runs even when the session already listed every source: a source
            // can be linked to the session and still be missing from the pool.
            await fileReviewedSourcesInSessionNotebook(sessionID: hostSession, sourceIDs: reviewedInHostSession)
        }
        return started
    }

    func normalizedReviewTopic(_ topic: String) -> String {
        var result = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^\s*please\s+use\s+foreverlm\s+to\s+(?:re-)?quiz\s+me\s+(?:again\s+)?on\s+(?:this\s+)?(?:source\(s\)|source|sources)?\s*:?\s*"#,
            #"(?i)^\s*please\s+quiz\s+me\s+on\s+"#,
            #"(?i)^\s*quiz\s+me\s+on\s+"#,
            #"(?i)^\s*review\s+me\s+on\s+"#,
            #"(?i)^\s*please\s+review\s+me\s+on\s+"#,
            #"(?i)^\s*start\s+a\s+(?:review|session)\s+(?:on|for)\s+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }

    func normalizedMatchText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func findReviewSessionSources(_ db: OpaquePointer, topic: String) throws -> [[String: Any]] {
        let likeRows = try query(db, """
            SELECT sp.id, sp.title, sp.source_type, COALESCE(sp.parent_group_title, sp.parent_group) AS parent_group,
                   COALESCE(NULLIF(sp.author, ''), bk.author) AS author, sp.word_count, sp.date_added
            FROM source_projection sp
            LEFT JOIN books bk ON bk.id = sp.parent_group AND sp.source_type = 'book'
            WHERE sp.title LIKE ? OR COALESCE(sp.parent_group_title, sp.parent_group) LIKE ?
               OR sp.author LIKE ? OR bk.author LIKE ?
            ORDER BY sp.date_added DESC LIMIT 10
        """, params: ["%\(topic)%", "%\(topic)%", "%\(topic)%", "%\(topic)%"])
        if !likeRows.isEmpty {
            return likeRows
        }

        let normalizedTopic = normalizedMatchText(topic)
        guard !normalizedTopic.isEmpty else { return [] }
        let allRows = try query(db, """
            SELECT sp.id, sp.title, sp.source_type, COALESCE(sp.parent_group_title, sp.parent_group) AS parent_group,
                   COALESCE(NULLIF(sp.author, ''), bk.author) AS author, sp.word_count, sp.date_added
            FROM source_projection sp
            LEFT JOIN books bk ON bk.id = sp.parent_group AND sp.source_type = 'book'
            ORDER BY sp.date_added DESC
            LIMIT 500
        """)
        let topicTokens = Set(normalizedTopic.split(separator: " ").map(String.init))
        let ranked = allRows.compactMap { row -> (score: Int, row: [String: Any])? in
            let title = row["title"] as? String ?? ""
            let group = row["parent_group"] as? String ?? ""
            let author = row["author"] as? String ?? ""
            let haystack = normalizedMatchText([title, group, author].joined(separator: " "))
            guard !haystack.isEmpty else { return nil }
            if haystack == normalizedTopic || normalizedTopic.contains(haystack) || haystack.contains(normalizedTopic) {
                return (1000, row)
            }
            let haystackTokens = Set(haystack.split(separator: " ").map(String.init))
            let overlap = topicTokens.intersection(haystackTokens).count
            let score = overlap * 10 - abs(haystackTokens.count - topicTokens.count)
            return score > 20 ? (score, row) : nil
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? ((lhs.row["date_added"] as? Double ?? 0) > (rhs.row["date_added"] as? Double ?? 0)) : lhs.score > rhs.score }
        return ranked.prefix(10).map(\.row)
    }

    func sourceRows(_ db: OpaquePointer, sourceIDs: [String]) throws -> [[String: Any]] {
        guard !sourceIDs.isEmpty else { return [] }
        let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try query(db, """
            SELECT id, title, source_type, COALESCE(parent_group_title, parent_group) AS parent_group, author, word_count, date_added
            FROM source_projection
            WHERE id IN (\(placeholders))
        """, params: sourceIDs)
        // Uniquing rather than `uniqueKeysWithValues` for the same reason as the
        // source search lookup: a duplicate projection row must degrade to one
        // result, not trap the process.
        let rowsByID = Dictionary(
            rows.compactMap { row -> (String, [String: Any])? in
                guard let id = row["id"] as? String else { return nil }
                return (id, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return sourceIDs.compactMap { rowsByID[$0] }
    }

    func endReviewSession(
        sessionID rawSessionID: String,
        hostSessionID: String? = nil,
        overallScore: Double,
        summary: String,
        transcript: String? = nil,
        gaps: [[String: Any]] = [],
        memoryAttempts rawMemoryAttempts: [[String: Any]] = [],
        sourceIDs fallbackSourceIDs: [String] = [],
        topic fallbackTopic: String? = nil
    ) throws -> String {
        let hostSession = try resolvedHostSessionID(hostSessionID)
        // In-app Chat is itself the session: an id the model lost or invented must
        // resolve back to the chat the learner is in, never spawn an imported
        // duplicate of a review that is already persisted here.
        let sessionID = hostSession ?? rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        // The host chat persists every turn as it happens, so re-appending an
        // exported transcript would duplicate the whole review as one exchange.
        let trimmedTranscript = hostSession == nil
            ? transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        // The session_id round-trips from start_review_session / daily_quiz through a
        // long review chat, so it can get lost, hallucinated, or point at a session
        // created in another window or database. When it can't be resolved, do not
        // discard a review that actually happened: if a transcript was supplied, save
        // it as a completed imported review and say so plainly. Nothing is faked — the
        // score and summary still come from the caller; only persistence is recovered
        // instead of being thrown away on a bookkeeping mismatch.
        let sessionExists = try !sessionID.isEmpty && reviewSessionExists(sessionID: sessionID)
        guard sessionExists else {
            if isMCPMemoryReviewSessionID(sessionID) {
                throw MCPError.notFound(
                    "Memory review session \(sessionID) was not found. ForeverLM will not import its transcript as an ordinary review because that would detach required concept attempts and consume source-level review state. Restart memory_review and retry with its new session_id."
                )
            }
            guard rawMemoryAttempts.isEmpty else {
                throw MCPError.notFound(
                    "Memory attempts cannot be attached because the review session was not found. Recover the session_id before retrying; ForeverLM will not silently save unlinked scheduling evidence."
                )
            }
            guard gaps.isEmpty else {
                throw MCPError.notFound(
                    "Understanding gaps cannot be attached because the review session was not found. Recover the session_id before retrying; ForeverLM will not silently detach gaps from their Learning Companion goal."
                )
            }
            guard let trimmedTranscript, !trimmedTranscript.isEmpty else {
                let idText = sessionID.isEmpty ? "(no session_id provided)" : "'\(sessionID)'"
                throw MCPError.notFound("""
                Review session \(idText) was not found, so there is no session to update. The session_id comes from the start_review_session or daily_quiz response (the "Session ID:" line). To save this review anyway, call end_review_session again with the full chat as `transcript` and the reviewed `source_ids` — it will be stored as a completed review and the sources marked reviewed.
                """)
            }
            let importTitle = cleanedOptional(fallbackTopic)
                ?? cleanedOptional(summary).map { String($0.prefix(80)) }
                ?? "Review session"
            let recoverySourceIDs = sanitizedSourceIDs(fallbackSourceIDs)
            guard !recoverySourceIDs.isEmpty else {
                throw MCPError.invalidInput(
                    "source_ids is required when recovering a review whose session_id was not found. ForeverLM will not infer durable source identity from ambient app context."
                )
            }
            let recoverySessionID = try deterministicMCPMemoryID(
                prefix: "mcp-recovered-review",
                fields: [
                    "version": 1,
                    "requested_session_id": sessionID,
                    "title": importTitle,
                    "transcript": trimmedTranscript,
                    "source_ids": recoverySourceIDs,
                    "summary": cleanedOptional(summary) ?? NSNull(),
                    "overall_score": overallScore,
                ],
                context: "recovered review identity"
            )
            let turns = parseReviewTranscript(trimmedTranscript)
            guard !turns.isEmpty else {
                throw MCPError.invalidInput("transcript had no readable messages.")
            }
            try validateSourcesExist(recoverySourceIDs)
            let knowledge = try knowledgeStore()
            let existingRecovery = try knowledge.loadReviewSessionForSync(recoverySessionID)
            if let existing = existingRecovery {
                guard (existing.status == "active" || existing.status == "completed"),
                      existing.topic == importTitle,
                      existing.goalID == nil,
                      existing.sourceIDs == recoverySourceIDs,
                      existing.cardIDs.isEmpty else {
                    throw MCPError.invalidInput(
                        "Recovered review identity conflicts with an existing session. ForeverLM will not overwrite a divergent retry."
                    )
                }
            }
            let recoveredAt: Date
            if existingRecovery?.status == "completed" {
                guard let durableEndedAt = existingRecovery?.endedAt else {
                    throw MCPError.invalidInput(
                        "Recovered review \(recoverySessionID) is completed without a durable completion time. ForeverLM will not guess one during replay."
                    )
                }
                recoveredAt = durableEndedAt
            } else {
                recoveredAt = Date()
            }
            try knowledge.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: recoverySessionID,
                overallScore: overallScore,
                summary: cleanedOptional(summary) ?? importTitle,
                endedAt: recoveredAt,
                exportedTranscript: trimmedTranscript,
                transcriptKnowledgeNote: "Recovered from an MCP review whose original session identity was unavailable.",
                sessionSourceIDs: recoverySourceIDs,
                scheduleReviewDate: recoveredAt,
                createIfMissing: ReviewSessionRecoverySeed(
                    topic: importTitle,
                    startedAt: recoveredAt,
                    sourceIDs: recoverySourceIDs
                ),
                attempts: []
            )
            let idText = sessionID.isEmpty ? "No session_id was provided" : "Session '\(sessionID)' was not found"
            return "\(idText), so the review was saved atomically as a completed imported review (recovery session \(recoverySessionID)), linked to \(recoverySourceIDs.count) source\(recoverySourceIDs.count == 1 ? "" : "s") with its transcript and Schedule completion."
        }
        let sessionSourceIDs = try reviewSessionSourceIDs(sessionID: sessionID)
        guard let persistedSession = try knowledgeStore().loadReviewSessionForSync(sessionID) else {
            throw MCPError.notFound("Review session \(sessionID) disappeared before completion.")
        }
        let launchedCurriculumFingerprints = hostSession == nil
            ? try mcpExpectedCurriculumFingerprints(cardIDs: persistedSession.cardIDs)
            : [:]
        let preparedMemory: PreparedMCPMemoryReview
        if hostSession == nil {
            preparedMemory = try prepareMCPMemoryAttempts(
                rawMemoryAttempts,
                sessionID: sessionID,
                sessionSourceIDs: sessionSourceIDs,
                launchedCurriculumFingerprints: launchedCurriculumFingerprints
            )
        } else {
            // The in-app manager already records each attempt atomically with
            // its live exchange; accepting an exported copy would duplicate it.
            preparedMemory = .empty
        }
        let endedAt: Date
        if persistedSession.status == "completed" {
            guard let durableEndedAt = persistedSession.endedAt else {
                throw MCPError.invalidInput(
                    "Completed review session \(sessionID) has no durable completion time. ForeverLM will not guess one during replay."
                )
            }
            endedAt = durableEndedAt
        } else {
            endedAt = Date()
        }
        let goalID = try reviewSessionGoalID(sessionID: sessionID)
        let isMemoryReviewSession = isMCPMemoryReviewSessionID(sessionID)
        let existingMemoryAttempts = try knowledgeStore().loadMemoryAttempts(
            memoryItemID: nil,
            sessionID: sessionID
        )
        let allMemoryAttempts = existingMemoryAttempts + preparedMemory.attempts
        let gradedMemoryAttempts = allMemoryAttempts.filter {
            $0.gradeState == .graded
        }
        let hasAnyMemoryEvidence = !allMemoryAttempts.isEmpty
        let hasGradedMemoryEvidence = !gradedMemoryAttempts.isEmpty
        if isMemoryReviewSession, !hasGradedMemoryEvidence {
            guard trimmedTranscript?.isEmpty != false, gaps.isEmpty else {
                throw MCPError.invalidInput(
                    "This memory review contains no structured memory_attempts. ForeverLM will not complete a reviewed transcript or consume its source-level review/Schedule state without graded concept evidence. Submit every covered attempt, or omit transcript and gaps to close an untouched session."
                )
            }
            guard try knowledgeStore().deleteReviewSessionIfNoRecordedConversation(sessionID) else {
                throw MCPError.invalidInput(
                    "This memory review has a durable queue or recorded learner conversation but no structured memory_attempts. It remains open so no review or Schedule state is consumed."
                )
            }
            return "Untouched memory review closed. No concept schedule, source-level review state, Schedule item, quiz count, or gap was changed."
        }
        if hasAnyMemoryEvidence, !hasGradedMemoryEvidence {
            throw MCPError.invalidInput(
                "This review contains only failed memory grading evidence. It remains open so no concept, source-level, Schedule, quiz, or gap state is consumed; retry grading before completing it."
            )
        }
        let reviewedMemorySourceIDs: [String]
        if hasGradedMemoryEvidence {
            let preparedItems = Dictionary(
                uniqueKeysWithValues: preparedMemory.items.map { ($0.id, $0) }
            )
            var reviewed = Set<String>()
            for attempt in gradedMemoryAttempts {
                let item: MemoryItem?
                if let preparedItem = preparedItems[attempt.memoryItemID] {
                    item = preparedItem
                } else {
                    item = try knowledgeStore().loadMemoryItem(attempt.memoryItemID)
                }
                guard let item else {
                    throw MCPError.invalidInput(
                        "Memory attempt \(attempt.id) no longer resolves to its canonical item. The review remains open."
                    )
                }
                reviewed.formUnion(item.sources.map(\.sourceID))
            }
            reviewedMemorySourceIDs = sessionSourceIDs.filter(reviewed.contains)
            guard Set(reviewedMemorySourceIDs) == reviewed else {
                throw MCPError.invalidInput(
                    "A memory attempt is anchored outside this review session. The review remains open."
                )
            }
        } else {
            reviewedMemorySourceIDs = sessionSourceIDs
        }
        if goalID == nil, !gaps.isEmpty {
            throw MCPError.invalidInput(
                "Understanding gaps can only be attached to a review session linked to a Learning Companion goal."
            )
        }
        let parsedGaps = try goalID.map {
            try parseCompanionGaps(
                gaps,
                goalID: $0,
                sessionID: sessionID,
                sessionSourceIDs: Set(reviewedMemorySourceIDs),
                recordedAt: endedAt
            )
        } ?? []

        // Transcript, concept attempts (including first-review item intake),
        // Schedule completion, Learning Companion counters/gaps, and the final
        // session status are one SQLite transaction. A completed session is the
        // durable idempotency marker, so a lost MCP response can be retried
        // without advancing a schedule or quiz count twice.
        try knowledgeStore().completeReviewSessionAndRecordMemoryAttempts(
            sessionID: sessionID,
            overallScore: overallScore,
            summary: summary,
            endedAt: endedAt,
            exportedTranscript: trimmedTranscript,
            transcriptKnowledgeNote: trimmedTranscript == nil
                ? nil
                : "Exported from an MCP review.",
            sessionSourceIDs: sessionSourceIDs,
            reviewedSourceIDs: hasAnyMemoryEvidence ? reviewedMemorySourceIDs : nil,
            scheduleReviewDate: endedAt,
            companionGoalID: goalID,
            companionQuizDate: goalID.map { _ in isoDateOnly(endedAt) },
            companionGaps: parsedGaps,
            items: preparedMemory.items,
            expectedCurriculumFingerprints: preparedMemory.expectedCurriculumFingerprints,
            attempts: preparedMemory.attempts
        )

        var companionLine = ""
        if let goalID {
            companionLine = "\nRecorded against Learning Companion goal \(goalID)."
            if !parsedGaps.isEmpty {
                companionLine += " Tracked \(parsedGaps.count) gap\(parsedGaps.count == 1 ? "" : "s")."
            }
        }

        let transcriptLine = (trimmedTranscript?.isEmpty == false) ? "\nTranscript exported to ForeverLM." : ""
        let memoryLine = preparedMemory.attempts.isEmpty
            ? ""
            : "\nRecorded \(preparedMemory.attempts.count) concept memory attempt\(preparedMemory.attempts.count == 1 ? "" : "s") with exact session/exchange linkage."
        return "Session ended. Score: \(String(format: "%.0f%%", overallScore * 100))\nSummary: \(summary)\(transcriptLine)\(memoryLine)\(companionLine)"
    }

    func parseCompanionGaps(
        _ raw: [[String: Any]],
        goalID: String,
        sessionID: String,
        sessionSourceIDs: Set<String>,
        recordedAt: Date
    ) throws -> [LearningGoalGap] {
        try raw.enumerated().map { index, entry in
            guard let rawSummary = entry["summary"] as? String else {
                throw MCPError.invalidInput("gaps[\(index)].summary is required.")
            }
            let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, summary.count <= 2_000 else {
                throw MCPError.invalidInput(
                    "gaps[\(index)].summary must be non-empty and at most 2000 characters."
                )
            }
            let status = ((entry["status"] as? String) ?? "open")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard ["open", "improving", "resolved"].contains(status) else {
                throw MCPError.invalidInput(
                    "gaps[\(index)].status must be open, improving, or resolved."
                )
            }
            let sourceID: String?
            if let rawSourceID = entry["source_id"] as? String {
                let trimmed = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty || sessionSourceIDs.contains(trimmed) else {
                    throw MCPError.invalidInput(
                        "gaps[\(index)].source_id is not attached to this review session."
                    )
                }
                sourceID = trimmed.isEmpty ? nil : trimmed
            } else {
                sourceID = nil
            }
            let severity: Double?
            if let rawSeverity = entry["severity"] {
                guard let value = ToolArgumentNumber.value(rawSeverity),
                      value.isFinite,
                      (0...1).contains(value) else {
                    throw MCPError.invalidInput(
                        "gaps[\(index)].severity must be a finite number from 0.0 to 1.0."
                    )
                }
                severity = value
            } else {
                severity = nil
            }
            let gapID = try deterministicMCPMemoryID(
                prefix: "mcp-review-gap",
                fields: [
                    "version": 1,
                    "session_id": sessionID,
                    "occurrence_index": index,
                    "summary": summary,
                    "source_id": sourceID ?? NSNull(),
                    "status": status,
                    "severity": severity ?? NSNull(),
                ],
                context: "gaps[\(index)] identity"
            )
            return LearningGoalGap(
                id: gapID,
                goalID: goalID,
                summary: summary,
                sourceID: sourceID,
                status: status,
                severity: severity,
                firstSeenAt: recordedAt,
                lastSeenAt: recordedAt,
                resolvedAt: status == "resolved" ? recordedAt : nil,
                sessionID: sessionID
            )
        }
    }

    func mcpMemoryItemCardID(_ item: MemoryItem) -> String {
        "memory-item-v2:\(MemoryTutorIdentity.immutableCurriculumFingerprint(item)):\(item.id)"
    }

    func mcpMemoryItemCardIdentity(
        _ cardID: String
    ) throws -> (itemID: String, fingerprint: String)? {
        let prefix = "memory-item-v2:"
        guard cardID.hasPrefix(prefix) else { return nil }
        let remainder = cardID.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ":") else {
            throw MCPError.invalidInput(
                "The persisted memory review contains a malformed curriculum snapshot. Start a new review."
            )
        }
        let fingerprint = String(remainder[..<separator])
        let itemID = String(remainder[remainder.index(after: separator)...])
        guard !fingerprint.isEmpty, !itemID.isEmpty else {
            throw MCPError.invalidInput(
                "The persisted memory review contains an incomplete curriculum snapshot. Start a new review."
            )
        }
        return (itemID, fingerprint)
    }

    func mcpExpectedCurriculumFingerprints(
        cardIDs: [String]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for cardID in cardIDs {
            if cardID.hasPrefix("memory-item:") {
                throw MCPError.invalidInput(
                    "This active memory review predates immutable curriculum snapshots. Start a new review before recording more answers."
                )
            }
            guard let identity = try mcpMemoryItemCardIdentity(cardID) else { continue }
            if let prior = result[identity.itemID], prior != identity.fingerprint {
                throw MCPError.invalidInput(
                    "The persisted memory review contains conflicting curriculum snapshots. Start a new review."
                )
            }
            result[identity.itemID] = identity.fingerprint
        }
        return result
    }

    /// Validate externally conducted concept attempts before the session is
    /// completed. Existing reviews assert an app-issued item ID. A first review
    /// instead supplies semantic curriculum plus exact canonical evidence; the
    /// app validates the source association and creates every durable identity.
    private func prepareMCPMemoryAttempts(
        _ raw: [[String: Any]],
        sessionID: String,
        sessionSourceIDs: [String],
        launchedCurriculumFingerprints: [String: String]
    ) throws -> PreparedMCPMemoryReview {
        guard !raw.isEmpty else { return .empty }
        let sessionSources = Set(sessionSourceIDs)
        let store = try knowledgeStore()
        var intakeItemsByID: [String: MemoryItem] = [:]
        var expectedCurriculumFingerprints: [String: String] = [:]
        let prepared = try raw.enumerated().map { index, entry -> (MemoryItem?, MemoryAttempt) in
            func requiredString(_ key: String, limit: Int) throws -> String {
                guard let rawValue = entry[key] as? String else {
                    throw MCPError.invalidInput("memory_attempts[\(index)].\(key) is required.")
                }
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= limit else {
                    throw MCPError.invalidInput("memory_attempts[\(index)].\(key) must be non-empty and at most \(limit) characters.")
                }
                return value
            }

            guard let score = ToolArgumentNumber.value(entry["score"]),
                  let qualityRaw = (entry["retrieval_quality"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  let quality = MemoryRetrievalQuality(rawValue: qualityRaw),
                  let rating = MemoryTutorGradeMapping.rating(quality: quality, score: score) else {
                throw MCPError.invalidInput(
                    "memory_attempts[\(index)] needs a finite score from 0.0 to 1.0 and retrieval_quality not_recalled, hinted, or independent."
                )
            }
            guard let rawMissing = entry["missing_rubric_elements"] as? [String], rawMissing.count <= 12 else {
                throw MCPError.invalidInput("memory_attempts[\(index)].missing_rubric_elements is required and capped at 12 entries.")
            }
            let missing = try rawMissing.enumerated().map { missingIndex, rawValue -> String in
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 500 else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].missing_rubric_elements[\(missingIndex)] must be non-empty and at most 500 characters."
                    )
                }
                return value
            }
            let misconception: String?
            if let rawValue = entry["misconception"] as? String {
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count <= 1_000 else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].misconception must be at most 1000 characters."
                    )
                }
                misconception = value.isEmpty ? nil : value
            } else {
                misconception = nil
            }

            let suppliedItemID = (entry["item_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let createdItem: MemoryItem?
            let item: MemoryItem
            let attemptType: MemoryAttemptType
            if let itemID = suppliedItemID, !itemID.isEmpty {
                guard itemID.count <= 200,
                      let existing = try store.loadMemoryItem(itemID),
                      existing.status == .active else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].item_id is not an active memory item from ForeverLM."
                    )
                }
                guard let expectedFingerprint = launchedCurriculumFingerprints[itemID] else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].item_id was not launched with this memory review. Reload the queue before grading it."
                    )
                }
                guard MemoryTutorIdentity.immutableCurriculumFingerprint(existing)
                    == expectedFingerprint else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].item_id changed after this review was prepared. Reload the memory review queue before retrying."
                    )
                }
                expectedCurriculumFingerprints[itemID] = expectedFingerprint
                let intakeKeys = ["source_id", "semantic_target", "rubric", "evidence_excerpt"]
                    .filter { entry[$0] != nil }
                guard intakeKeys.isEmpty else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)] names an existing item_id, so first-review curriculum fields must be omitted."
                    )
                }
                let itemSources = Set(existing.sources.map(\.sourceID))
                guard !itemSources.isEmpty, itemSources.isSubset(of: sessionSources) else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].item_id is not grounded entirely in this review session's sources."
                    )
                }
                item = existing
                createdItem = nil
                attemptType = .imported
            } else {
                guard entry["item_id"] == nil || suppliedItemID?.isEmpty == true else {
                    throw MCPError.invalidInput("memory_attempts[\(index)].item_id must be a string when provided.")
                }
                let sourceID = try requiredString("source_id", limit: 200)
                guard sessionSources.contains(sourceID) else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].source_id is not attached to this review session."
                    )
                }
                let semanticTarget = try requiredString("semantic_target", limit: 1_000)
                guard let rawRubric = entry["rubric"] as? [String], (1...12).contains(rawRubric.count) else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].rubric must contain 1 to 12 criteria for a first review."
                    )
                }
                let rubric = try rawRubric.enumerated().map { rubricIndex, rawValue -> String in
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, value.count <= 500 else {
                        throw MCPError.invalidInput(
                            "memory_attempts[\(index)].rubric[\(rubricIndex)] must be non-empty and at most 500 characters."
                        )
                    }
                    return value
                }
                let excerpt = try requiredString("evidence_excerpt", limit: 2_000)
                guard excerpt.count >= 20 else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].evidence_excerpt must contain at least 20 grounded characters."
                    )
                }
                let anchorValidation: MemorySourceAnchorValidation
                do {
                    anchorValidation = try store.validatedMemorySourceAnchor(
                        sourceID: sourceID,
                        excerpt: excerpt
                    )
                } catch {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)].evidence_excerpt is not exact canonical evidence for source_id \(sourceID): \(error.localizedDescription)"
                    )
                }
                guard let rubricData = try? JSONSerialization.data(
                    withJSONObject: ["criteria": rubric],
                    options: [.sortedKeys]
                ), let rubricJSON = String(data: rubricData, encoding: .utf8) else {
                    throw MCPError.invalidInput("memory_attempts[\(index)].rubric could not be encoded.")
                }
                let itemID = MemoryTutorIdentity.firstReviewItemID(
                    portableSourceKey: anchorValidation.portableSourceKey
                )
                let anchorID = MemoryTutorIdentity.firstReviewAnchorID(
                    memoryItemID: itemID
                )
                let anchor = MemoryItemSource(
                    id: anchorID,
                    memoryItemID: itemID,
                    sourceID: sourceID,
                    excerpt: anchorValidation.excerpt,
                    sourceSHA256: anchorValidation.sourceSHA256,
                    sortIndex: 0
                )
                let now = Date()
                let candidate = MemoryItem(
                    id: itemID,
                    kind: .concept,
                    target: semanticTarget,
                    rubricJSON: rubricJSON,
                    learnerContext: misconception,
                    goalID: nil,
                    sources: [anchor],
                    createdAt: now,
                    updatedAt: now
                )
                let firstOccurrence = intakeItemsByID[itemID] == nil
                if let priorCandidate = intakeItemsByID[itemID] {
                    // A Socratic retry may reveal a different misconception, but
                    // it is still another attempt against the same stable
                    // curriculum. Preserve the first item's learner context and
                    // timestamps; only target/rubric/anchor divergence conflicts.
                    guard MemoryTutorIdentity.hasSameImmutableCurriculum(
                        priorCandidate,
                        candidate
                    ) else {
                        throw MCPError.invalidInput(
                            "memory_attempts[\(index)] conflicts with another first-review curriculum for the same source."
                        )
                    }
                    item = priorCandidate
                } else if let existing = try store.loadMemoryItem(itemID) {
                    guard MemoryTutorIdentity.hasSameImmutableCurriculum(
                        existing,
                        candidate
                    ) else {
                        throw MCPError.invalidInput(
                            "memory_attempts[\(index)] conflicts with an already recorded immutable first-review item."
                        )
                    }
                    item = existing
                } else {
                    item = candidate
                }
                intakeItemsByID[itemID] = item
                createdItem = firstOccurrence ? item : nil
                attemptType = firstOccurrence ? .discovery : .review
            }

            let evaluation = try requiredString("evaluation", limit: 4_000)
            let prompt = try requiredString("prompt", limit: 8_000)
            let learnerAnswer = try requiredString("learner_answer", limit: 20_000)
            let evidence: [String: Any] = [
                "retrieval_quality": quality.rawValue,
                "missing_rubric_elements": missing,
                "misconception": misconception ?? NSNull(),
            ]
            guard JSONSerialization.isValidJSONObject(evidence),
                  let evidenceData = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                  let evidenceJSON = String(data: evidenceData, encoding: .utf8) else {
                throw MCPError.invalidInput("memory_attempts[\(index)] evidence could not be encoded.")
            }

            // A lost MCP response is safe to retry. Identity is app-owned and
            // deterministic over the session plus the ordered learner exchange;
            // the model never supplies or selects it. The occurrence index keeps
            // two deliberately repeated prompts/answers as distinct attempts.
            let attemptID = try deterministicMCPMemoryID(
                prefix: "mcp-memory-attempt",
                fields: [
                    "version": 1,
                    "session_id": sessionID,
                    "occurrence_index": index,
                    "memory_item_id": item.id,
                    "prompt": prompt,
                    "learner_answer": learnerAnswer,
                ],
                context: "memory_attempts[\(index)] attempt identity"
            )
            let candidate = MemoryAttempt(
                id: attemptID,
                memoryItemID: item.id,
                // The atomic completion helper creates both relationship IDs.
                // Passing only one is intentionally rejected by storage.
                sessionID: nil,
                exchangeID: nil,
                attemptType: attemptType,
                prompt: prompt,
                learnerAnswer: learnerAnswer,
                feedback: evaluation,
                score: score,
                scheduleRating: rating,
                gradeState: .graded,
                evidenceJSON: evidenceJSON,
                attemptedAt: Date().addingTimeInterval(Double(index) / 1_000)
            )

            // A committed first call may have lost its transport response. Reuse
            // the exact linked row so the second call neither advances the
            // schedule nor creates another exchange. Divergent grading under the
            // same exchange identity fails closed instead of rewriting history.
            if let existing = try store.loadMemoryAttempt(attemptID) {
                guard existing.memoryItemID == candidate.memoryItemID,
                      existing.sessionID == sessionID,
                      existing.exchangeID != nil,
                      existing.attemptType == candidate.attemptType,
                      existing.prompt == candidate.prompt,
                      existing.learnerAnswer == candidate.learnerAnswer,
                      existing.feedback == candidate.feedback,
                      existing.score == candidate.score,
                      existing.scheduleRating == candidate.scheduleRating,
                      existing.gradeState == candidate.gradeState,
                      existing.gradingError == candidate.gradingError,
                      existing.evidenceJSON == candidate.evidenceJSON else {
                    throw MCPError.invalidInput(
                        "memory_attempts[\(index)] conflicts with an already recorded immutable attempt."
                    )
                }
                return (createdItem, existing)
            }
            return (createdItem, candidate)
        }
        return PreparedMCPMemoryReview(
            items: prepared.compactMap(\.0),
            attempts: prepared.map(\.1),
            expectedCurriculumFingerprints: expectedCurriculumFingerprints
        )
    }

    private func deterministicMCPMemoryID(
        prefix: String,
        fields: [String: Any],
        context: String
    ) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            throw MCPError.invalidInput("\(context) could not be encoded.")
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }

    /// Provider retries must address the same app-owned session without giving
    /// the model control of its database identity. The operation id is only an
    /// idempotency assertion; its bounded digest becomes the durable key. The
    /// key is optional, so a blank one means the same as none.
    func deterministicMCPOperationSessionIdentity(
        _ rawOperationID: String?,
        namespace: String,
        sessionPrefix: String,
        requestFields: [String: Any]
    ) throws -> MCPOperationSessionIdentity? {
        let operationID = rawOperationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !operationID.isEmpty else { return nil }
        guard operationID.count <= 200 else {
            throw MCPError.invalidInput("operation_id must be 200 characters or fewer.")
        }
        let operationNamespace = try deterministicMCPMemoryID(
            prefix: "\(sessionPrefix)-operation",
            fields: [
                "namespace": namespace,
                "operation_id": operationID,
            ],
            context: "operation_id"
        )
        let sessionID = try deterministicMCPMemoryID(
            prefix: operationNamespace,
            fields: requestFields,
            context: "operation request"
        )
        return MCPOperationSessionIdentity(
            sessionID: sessionID,
            sessionIDPrefix: "\(operationNamespace)-"
        )
    }

    func existingMCPOperationSessionID(prefix: String) throws -> String? {
        try withDB { db in
            try query(
                db,
                "SELECT id FROM review_sessions WHERE id LIKE ? ORDER BY id LIMIT 1",
                params: ["\(prefix)%"]
            ).first?["id"] as? String
        }
    }

    func isMCPMemoryReviewSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix("mcp-memory-review-")
    }

    func reviewSessionGoalID(sessionID: String) throws -> String? {
        try withDB { db in
            let rows = try query(db, "SELECT goal_id FROM review_sessions WHERE id = ? LIMIT 1", params: [sessionID])
            return rows.first?["goal_id"] as? String
        }
    }

    /// Reflect a completed or imported review on the Schedule. Sources that
    /// aren't on the Schedule at all are placed on today so the review leaves a trace;
    /// sources already planned for a day are checked off in place. Idempotent
    /// (completion is COALESCEd, not overwritten).
    func markScheduledSourcesReviewed(_ sourceIDs: [String]) throws {
        let ids = sourceIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let store = try knowledgeStore()
        let today = Date()
        for sourceID in ids {
            try store.recordScheduledSourceReview(sourceID: sourceID, on: today)
        }
    }

    func reviewSessionExists(sessionID: String) throws -> Bool {
        try withDB { db in
            try query(db, "SELECT id FROM review_sessions WHERE id = ? LIMIT 1", params: [sessionID]).isEmpty == false
        }
    }

    /// The caller's own review session, when it has one that still exists. In-app
    /// Chat passes the session it already opened; remote MCP clients pass nil. A
    /// stale id (a session deleted while the chat was open) resolves to nil so the
    /// tool falls back to its normal create-a-session path.
    func resolvedHostSessionID(_ hostSessionID: String?) throws -> String? {
        guard let trimmed = hostSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              try reviewSessionExists(sessionID: trimmed) else {
            return nil
        }
        return trimmed
    }

    /// Union the reviewed sources into a session that already exists, so a review
    /// bound to the in-app chat still links back to every source it covered,
    /// and file them in the Notebook the session belongs to.
    func mergeReviewSessionSourceIDs(sessionID: String, adding sourceIDs: [String]) async throws {
        try linkReviewSessionSources(sessionID: sessionID, adding: sourceIDs)
        // Runs even when the session already listed every source: a source can
        // be linked to the session and still be missing from the Notebook pool.
        await fileReviewedSourcesInSessionNotebook(sessionID: sessionID, sourceIDs: sourceIDs)
    }

    /// The session's own list of the sources it covered, unioned with these.
    func linkReviewSessionSources(sessionID: String, adding sourceIDs: [String]) throws {
        let additions = sourceIDs.filter { !$0.isEmpty }
        guard !additions.isEmpty else { return }
        let existing = try reviewSessionSourceIDs(sessionID: sessionID)
        let merged = existing + additions.filter { !existing.contains($0) }
        if merged.count != existing.count {
            try knowledgeStore().updateReviewSessionSources(sessionID: sessionID, sourceIDs: merged)
        }
    }

    /// Add sources worked through in a session to the Notebook that owns it.
    ///
    /// Mirrors the in-app rule that bringing a source into a Notebook's chat
    /// adds it to that Notebook. Without this, studying a source through an
    /// external assistant would leave it out of the pool the assistant is
    /// shown next session — the two surfaces would disagree about what the
    /// Notebook contains.
    ///
    /// Filed through add_notebook_sources' own write (`fileSourcesInTeamPool`):
    /// a team's Notebook holds the team's copies of the learner's own sources,
    /// never their ids, what arrives is ticked for the Notebook's chats, and a
    /// team this account can only read takes nothing. The member's own ids
    /// are never written straight into a team's Notebook. The review
    /// goes on either way — a read-only member may review a team notebook's
    /// sources, only its pool is not theirs to change — so a refusal is
    /// logged, never raised. A source the Notebook already reaches (its id, or
    /// for a team's Notebook the team's copy, anywhere its chats draw on: its
    /// own sources and those of the context notebooks the learner put in) is
    /// left alone.
    func fileReviewedSourcesInSessionNotebook(sessionID: String, sourceIDs: [String]) async {
        let additions = sanitizedSourceIDs(sourceIDs)
        guard !additions.isEmpty else { return }
        do {
            let pending = try await withStoreGate(.shared) { () -> (goal: LearningGoalRecord, ids: [String])? in
                guard let goalID = try reviewSessionGoalID(sessionID: sessionID) else { return nil }
                let store = try knowledgeStore()
                guard let goal = try store.loadLearningGoal(goalID), goal.isCompanion else { return nil }
                let reached = Set(goal.isNotebook ? notebookChatPoolSourceIDs(goal: goal, store: store) : [])
                var newIDs: [String] = []
                for id in additions where !reached.contains(id) {
                    // A team's Notebook reaches an own source through the team's copy.
                    if let teamID = goal.teamID,
                       let source = try store.loadSourceWithoutContent(id),
                       source.teamID == nil,
                       reached.contains(try store.teamSourceCopyID(teamID: teamID, url: source.url)) {
                        continue
                    }
                    newIDs.append(id)
                }
                return newIDs.isEmpty ? nil : (goal, newIDs)
            }
            guard let pending else { return }
            let filing = try await fileSourcesInTeamPool(pending.ids, in: pending.goal)
            if !filing.refused.isEmpty {
                let reasons = filing.refused.map { "\($0.sourceID): \($0.reason)" }.joined(separator: "; ")
                logger.notice("Reviewed sources left out of Notebook \(pending.goal.id, privacy: .public): \(reasons, privacy: .public)")
            }
        } catch {
            logger.notice("Reviewed sources not filed in the Notebook of session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func reviewSessionSourceIDs(sessionID: String) throws -> [String] {
        return try withDB { db in
            let rows = try query(db, """
                SELECT source_id
                FROM review_session_sources
                WHERE session_id = ?
                ORDER BY source_id
            """, params: [sessionID])
            return rows.compactMap { $0["source_id"] as? String }
        }
    }

    /// The session a `session_id` argument names. A chat reaches the plugin as
    /// the address the app's Copy Link puts on the clipboard,
    /// `foreverlm://chat/<id>` (or the running build's own scheme), so that
    /// spelling is accepted wherever a bare id is. A Markdown link or an
    /// address in angle brackets, as a pasted chat often arrives, yields the
    /// same id; anything else is trimmed and used as the id it is.
    /// An ISO 8601 moment from a tool argument, with or without fractional
    /// seconds — assistants send both, and a timestamp that fails to parse
    /// must leave the import alone rather than land the chat at the wrong hour.
    static func parseISODate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        return KnowledgeStore.iso8601Formatter.date(from: trimmed)
    }

    static func reviewSessionID(from argument: Any?) -> String {
        var raw = (argument as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasPrefix("<"), raw.hasSuffix(">") {
            raw = String(raw.dropFirst().dropLast())
        } else if raw.hasPrefix("["), raw.hasSuffix(")"),
                  let open = raw.lastIndex(of: "(") {
            raw = String(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)])
        }
        if case .chat(let id)? = StudioEntityLink.parse(destination: raw) { return id }
        return raw
    }
}

/// No downloadable PDF URL could be resolved for a paper landing page: the
/// direct link, PMC, page metadata, and Unpaywall lookups all came up empty.
/// Typed (rather than a generic MCPError) so the paper-download pipeline can
/// recognize it as paywall evidence without matching on message strings.
struct PaperPDFUnavailableError: LocalizedError {
    let sourceURL: String
    var errorDescription: String? { "No downloadable PDF URL found for \(sourceURL)" }
}
