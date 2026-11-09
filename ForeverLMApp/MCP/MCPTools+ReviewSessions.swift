import CryptoKit
import Foundation
import ImageIO
import Network
import OSLog
import PDFKit
import SQLite3

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
                    "Memory review session \(sessionID) was not found. ForeverLM will not import its transcript as an ordinary review because that would detach required concept attempts and consume legacy state. Restart memory_review and retry with its new session_id."
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
                    "This memory review contains no structured memory_attempts. ForeverLM will not complete a reviewed transcript or consume its legacy/Schedule state without graded concept evidence. Submit every covered attempt, or omit transcript and gaps to close an untouched session."
                )
            }
            guard try knowledgeStore().deleteReviewSessionIfNoRecordedConversation(sessionID) else {
                throw MCPError.invalidInput(
                    "This memory review has a durable queue or recorded learner conversation but no structured memory_attempts. It remains open so no review or Schedule state is consumed."
                )
            }
            return "Untouched memory review closed. No concept schedule, legacy review state, Schedule item, quiz count, or gap was changed."
        }
        if hasAnyMemoryEvidence, !hasGradedMemoryEvidence {
            throw MCPError.invalidInput(
                "This review contains only failed memory grading evidence. It remains open so no concept, legacy, Schedule, quiz, or gap state is consumed; retry grading before completing it."
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

    func reviewSessionIsCompleted(sessionID: String) throws -> Bool {
        try withDB { db in
            let rows = try query(
                db,
                "SELECT status FROM review_sessions WHERE id = ? LIMIT 1",
                params: [sessionID]
            )
            return rows.first?["status"] as? String == "completed"
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
    /// team this account can only read takes nothing. Until 2026-09-30 this
    /// wrote the member's own ids straight into a team's Notebook. The review
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

    func ensureReviewSessionExists(sessionID: String) throws {
        guard try reviewSessionExists(sessionID: sessionID) else {
            throw MCPError.notFound("Review session not found: \(sessionID)")
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
        return ISO8601DateFormatter().date(from: trimmed)
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

    func getReviewSessions(topic: String?, sourceId: String? = nil) throws -> String {
        // Screen record mode (admin only): chats the take keeps off screen are
        // dropped after the query, so the unfiltered listing's cap of 20 is
        // lifted while the scope is on and applied to what is left. Nil scope:
        // an empty set and the original LIMIT 20.
        let screenScope = screenRecordScope()
        let screenRecordHidden = try screenRecordHiddenReviewSessionIDs(scope: screenScope)
        return try withDB { db in
            let queried: [[String: Any]]
            if let sourceId, !sourceId.isEmpty {
                queried = try query(db, """
                    SELECT fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary,
                           fs.model_provider, fs.model_id, h.hidden_at,
                           COUNT(fe.id) AS exchange_count
                    FROM review_sessions fs
                    LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
                    JOIN review_session_sources fss ON fs.id = fss.session_id
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                    WHERE fss.source_id = ?
                    GROUP BY fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary, fs.model_provider, fs.model_id, h.hidden_at
                    ORDER BY fs.started_at DESC
                """, params: [sourceId])
            } else if let topic, !topic.isEmpty {
                queried = try query(db, """
                    SELECT fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary,
                           fs.model_provider, fs.model_id, h.hidden_at,
                           COUNT(fe.id) AS exchange_count
                    FROM review_sessions fs
                    LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                    WHERE fs.topic LIKE ?
                    GROUP BY fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary, fs.model_provider, fs.model_id, h.hidden_at
                    ORDER BY fs.started_at DESC
                """, params: ["%\(topic)%"])
            } else {
                queried = try query(db, """
                    SELECT fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary,
                           fs.model_provider, fs.model_id, h.hidden_at,
                           COUNT(fe.id) AS exchange_count
                    FROM review_sessions fs
                    LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                    GROUP BY fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary, fs.model_provider, fs.model_id, h.hidden_at
                    ORDER BY fs.started_at DESC
                    LIMIT \(screenScope == nil ? 20 : -1)
                """)
            }
            let unfilteredListing = (sourceId ?? "").isEmpty && (topic ?? "").isEmpty
            let visible = screenScope == nil ? queried : queried.filter { row in
                guard let id = row["id"] as? String else { return false }
                return !screenRecordHidden.contains(id)
            }
            let rows = unfilteredListing && screenScope != nil ? Array(visible.prefix(20)) : visible
            let pins = ChatPinRows.read()
            var lines = ["Review sessions (\(rows.count)):"]
            for r in rows {
                let id = r["id"] as? String ?? ""
                let t = r["topic"] as? String ?? ""
                let score = r["overall_score"] as? Double ?? 0
                let status = r["status"] as? String ?? ""
                let exchanges = r["exchange_count"] as? Int ?? 0
                let date = (r["started_at"] as? Double).map { appleToISO($0) } ?? ""
                let summary = r["summary"] as? String ?? ""
                let model = [r["model_provider"] as? String, r["model_id"] as? String]
                    .compactMap { value in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    .joined(separator: " / ")
                // A hidden chat is still the learner's: it stays listed, marked,
                // so an assistant can find it and show it again.
                let hidden = r["hidden_at"] is Double ? " [hidden from the sidebar]" : ""
                let pinned = pins.isPinned(id) ? " [pinned]" : ""
                lines.append("- \(t) (id: \(id)) [\(status)]\(pinned)\(hidden) \(String(format: "%.0f%%", score * 100)) (\(exchanges) exchanges, \(date)\(model.isEmpty ? "" : ", model: \(model)"))\(summary.isEmpty ? "" : " — \(summary)")")
            }
            return lines.joined(separator: "\n")
        }
    }

    func getReviewSessionTranscript(sessionID: String) throws -> String {
        return try withDB { db in
            let sessions = try query(db, """
                SELECT topic, status, overall_score, summary, model_provider, model_id
                FROM review_sessions
                WHERE id = ?
                LIMIT 1
            """, params: [sessionID])
            guard let session = sessions.first else {
                throw MCPError.notFound("Review session not found: \(sessionID)")
            }
            let topic = session["topic"] as? String ?? "Untitled"
            let status = session["status"] as? String ?? ""
            let score = session["overall_score"] as? Double
            let summary = session["summary"] as? String ?? ""
            let model = [session["model_provider"] as? String, session["model_id"] as? String]
                .compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .joined(separator: " / ")

            let exchanges = try query(db, """
                SELECT sequence_number, question, user_answer, evaluation, score, knowledge_note
                FROM review_exchanges
                WHERE session_id = ?
                ORDER BY sequence_number ASC
            """, params: [sessionID])

            var lines = ["Review session: \(topic)", "Status: \(status)"]
            if !model.isEmpty {
                lines.append("Last model: \(model)")
            }
            if let score {
                lines.append("Score: \(String(format: "%.0f%%", score * 100))")
            }
            if !summary.isEmpty {
                lines.append("Summary: \(summary)")
            }
            guard !exchanges.isEmpty else {
                lines.append("No exported transcript or recorded exchanges saved for this session.")
                return lines.joined(separator: "\n")
            }

            lines.append("")
            for exchange in exchanges {
                let sequence = exchange["sequence_number"] as? Int ?? 0
                let question = (exchange["question"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let answer = (exchange["user_answer"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let evaluation = (exchange["evaluation"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("## Exchange \(sequence)")
                if !question.isEmpty, question != RealtimeExchangeLedger.openConversationQuestion {
                    lines.append("Assistant: \(question)")
                }
                if let answer, !answer.isEmpty {
                    lines.append("Learner: \(answer)")
                }
                if let evaluation, !evaluation.isEmpty {
                    lines.append("Assistant: \(evaluation)")
                }
                if let exchangeScore = exchange["score"] as? Double {
                    lines.append("Exchange score: \(String(format: "%.0f%%", exchangeScore * 100))")
                }
                if let note = exchange["knowledge_note"] as? String, !note.isEmpty {
                    lines.append("Note: \(note)")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }

    func importReviewChat(
        title: String,
        transcript: String,
        transcriptFile: String? = nil,
        sourceIDs requestedSourceIDs: [String]?,
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        notebookID: String? = nil,
        sessionID appendToSessionID: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        marksReviewed requestedMarksReviewed: Bool? = nil
    ) throws -> String {
        var trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileArgument = transcriptFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A chat link, `foreverlm://chat/<id>`, names the session as well as
        // its bare id does, whichever layer the argument arrives through.
        let appendTarget = appendToSessionID.map { Self.reviewSessionID(from: $0) }
        guard !trimmedTranscript.isEmpty || !fileArgument.isEmpty else {
            throw MCPError.invalidInput("transcript or transcript_file is required.")
        }

        // The assistant's own record of the chat beats its retelling: a session
        // file holds the turns as the learner saw them, timed, with the source
        // links the answer carried. It is read whole every time, and with
        // session_id the stored chat is brought level with it.
        let record: AssistantTranscriptFile?
        let turns: [ReviewChatTurn]
        if !fileArgument.isEmpty {
            let url = try resolveTranscriptFile(fileArgument)
            do {
                record = try AssistantTranscriptFile.read(at: url)
            } catch let error as AssistantTranscriptFile.ReadError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            turns = record?.turns ?? []
            if trimmedTitle.isEmpty, let recordTitle = record?.title { trimmedTitle = recordTitle }
        } else {
            record = nil
            turns = parseReviewTranscript(trimmedTranscript)
        }
        guard !trimmedTitle.isEmpty || appendTarget?.isEmpty == false else { throw MCPError.invalidInput("title is required.") }
        guard !turns.isEmpty else { throw MCPError.invalidInput("transcript had no readable messages.") }

        let store = try knowledgeStore()
        let recordProvider = record?.kind == .claudeCodeSession ? "Claude" : nil
        let resolvedProvider = cleanedOptional(modelProvider) ?? recordProvider
        let resolvedModelID = cleanedOptional(modelID) ?? record?.modelID

        if let appendTarget, !appendTarget.isEmpty {
            if let record {
                return try reconcileReviewChat(
                    sessionID: appendTarget,
                    with: record,
                    sourceIDs: requestedSourceIDs.map(sanitizedSourceIDs) ?? [],
                    summary: summary,
                    overallScore: overallScore,
                    modelProvider: resolvedProvider,
                    modelID: resolvedModelID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    marksReviewed: requestedMarksReviewed,
                    store: store
                )
            }
            return try appendReviewChatChunk(
                to: appendTarget,
                turns: turns,
                sourceIDs: requestedSourceIDs.map(sanitizedSourceIDs) ?? [],
                summary: summary,
                overallScore: overallScore,
                modelProvider: modelProvider,
                modelID: modelID,
                startedAt: startedAt,
                endedAt: endedAt,
                marksReviewed: requestedMarksReviewed,
                store: store
            )
        }
        let marksReviewed = requestedMarksReviewed ?? true

        // Only the ids given: what the app has selected is never a default.
        let resolvedSourceIDs = sanitizedSourceIDs(requestedSourceIDs ?? [])

        let explicitNotebook: LearningGoalRecord?
        if let rawNotebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawNotebookID.isEmpty {
            explicitNotebook = try resolveMCPChatHome(notebookID: rawNotebookID, store: store)
        } else {
            explicitNotebook = nil
        }

        // The hours the conversation ran: the caller's when it declares them,
        // else the record's own stamps — a session file saw every turn happen.
        let ranFrom = startedAt ?? record?.startedAt
        let ranTo = endedAt ?? record?.endedAt
        let session = try store.importReviewChatSession(
            id: UUID().uuidString,
            title: trimmedTitle,
            turns: turns,
            sourceIDs: resolvedSourceIDs,
            goalID: explicitNotebook?.id,
            summary: summary,
            overallScore: overallScore,
            modelProvider: resolvedProvider,
            modelID: resolvedModelID,
            createdAt: ranFrom ?? Date(),
            endedAt: ranTo,
            // The choice is the chat's, not this call's: every later call with
            // session_id reads it back (`appendMarksReviewed`).
            kind: marksReviewed ? nil : .chat,
            // Under generation 2 the chat records the choice itself, and its kind is the
            // classifier's on what this call knows: a review when scored, else a chat.
            chatKind: ChatKindClassifier.kind(of: ChatKindClassifier.Evidence(
                id: "", kind: marksReviewed ? nil : ReviewSessionKind.chat.rawValue, hasOverallScore: overallScore != nil
            )),
            marksReviewed: marksReviewed
        )
        // An imported review is a completed review, so reflect it on the
        // Schedule: mark any scheduled placements for these sources done instead
        // of leaving them pending with a "Chat started" label. A chat that only
        // researched or discussed its sources (`marksReviewed` false) did not
        // review the learner on them, and leaves the Schedule as it was.
        if marksReviewed {
            try markScheduledSourcesReviewed(resolvedSourceIDs)
        }

        let scoreText = overallScore.map { " Score: \(String(format: "%.0f%%", $0 * 100))." } ?? ""
        let sourcePlural = resolvedSourceIDs.count == 1 ? "" : "s"
        let sourceText: String
        if resolvedSourceIDs.isEmpty {
            sourceText = marksReviewed
                ? " No sources were linked; pass source_ids to mark sources reviewed."
                : " No sources were linked."
        } else if marksReviewed {
            sourceText = " Linked to \(resolvedSourceIDs.count) source\(sourcePlural), now counted as reviewed and marked done on the Schedule."
        } else {
            sourceText = " Linked to \(resolvedSourceIDs.count) source\(sourcePlural), without marking them reviewed."
        }
        let clockText = recordChatOnDayLog(sessionID: session.id, title: session.title, record: record, from: ranFrom, to: ranTo, store: store)
        let notebookText = explicitNotebook.map {
            " Filed under \(Self.companionName($0))."
        } ?? ""
        let originText = record.map { " from \(Self.describe($0))" } ?? ""
        let continueText = record == nil
            ? "A chat too long for one call continues here: pass session_id \(session.id) with each further chunk and its turns are appended."
            : "After each later answer, call again with session_id \(session.id) and the same transcript_file: the stored chat is brought level with the record."
        let savedAs = marksReviewed ? "a completed review session" : "a saved chat"
        // The new chat's id rides on its own line, never beside its title
        // (Prompts.hiddenIDs); the caller keeps it for session_id.
        return "Imported chat '\(session.title)'\(originText) as \(savedAs) with \(turns.count) exchange\(turns.count == 1 ? "" : "s").\(scoreText)\(sourceText)\(notebookText)\(clockText) It now appears in the app's review sessions and its transcript is searchable. \(continueText)\nsession_id: \(session.id)"
    }

    private static func describe(_ record: AssistantTranscriptFile) -> String {
        switch record.kind {
        case .claudeCodeSession: return "its Claude Code session file"
        case .roleLabelledText: return "its transcript file"
        }
    }

    /// `transcript_file` names the assistant's own record of the chat: a
    /// Claude Code session id, which is looked up under the notebooks
    /// directory, or a path, vetted like every other client-provided path
    /// with that directory added to the roots a client may read from.
    func resolveTranscriptFile(_ argument: String) throws -> URL {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebooksRoot = claudeCodeProjectsRoot
        if AssistantTranscriptFile.isSessionID(trimmed) {
            guard let url = AssistantTranscriptFile.claudeCodeSessionFile(id: trimmed, notebooksRoot: notebooksRoot) else {
                throw MCPError.invalidInput(
                    "No Claude Code session \(trimmed) is recorded under \(notebooksRoot.path) on this Mac. Pass the session file's path, or transcript with the turns themselves."
                )
            }
            return try validateClientProvidedPath(url.path, additionalRoots: [notebooksRoot.path])
        }
        let url = try validateClientProvidedPath(trimmed, additionalRoots: [notebooksRoot.path])
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidInput("File not found: \(trimmed)")
        }
        return url
    }

    /// Puts an imported chat on the day's log at the hours it ran: a chat
    /// had in ChatGPT at two in the afternoon and imported at ten at night
    /// belongs on the clock at two, not at ten. Without a time nothing is
    /// drawn, because the app did not see this hour and must not invent one
    /// (docs/tethered-workday-design.md); a session file's stamps count as
    /// seen.
    ///
    /// A record that stamps its messages is drawn from those stamps, each one
    /// an observation the way a turn of an in-app chat is, so an hour the
    /// learner spent away between two messages is not drawn: on 2026-09-28 a
    /// chat drawn from its first turn to its last covered 14:26–19:04, an
    /// afternoon spent elsewhere. Without stamps, a declared `started_at` and
    /// `ended_at` are drawn as one span. Returns the sentence to append to the
    /// tool's answer.
    private func recordChatOnDayLog(
        sessionID: String,
        title: String,
        record: AssistantTranscriptFile?,
        from: Date?,
        to: Date?,
        store: KnowledgeStore
    ) -> String {
        do {
            let stamps = record?.messages.compactMap(\.timestamp) ?? []
            let spans: [DayActivity]
            if !stamps.isEmpty {
                spans = try store.recordDayActivityObservations(kind: .chat, targetID: sessionID, title: title, at: stamps)
            } else if let from, let to, to > from,
                      let span = try store.recordDayActivitySpan(kind: .chat, targetID: sessionID, title: title, from: from, to: to) {
                spans = [span]
            } else {
                return ""
            }
            return Self.dayLogSentence(for: spans)
        } catch {
            // The chat is imported either way; only its place on the clock
            // is lost, and saying so is better than failing the import.
            return " It could not be put on the day's log: \(error.localizedDescription)"
        }
    }

    /// " It is on the day's log for 2026-09-28 (14:26–14:31, 19:00–19:05)
    /// at the hours it ran." — every sitting named, so an assistant can see a
    /// gap was left undrawn rather than guess.
    static func dayLogSentence(for spans: [DayActivity]) -> String {
        guard !spans.isEmpty else { return "" }
        let byDay = Dictionary(grouping: spans, by: \.dayPlanID)
        let days = byDay.keys.sorted().map { day -> String in
            let clocks = (byDay[day] ?? [])
                .sorted { $0.startMinute < $1.startMinute }
                .map { "\(DayPlan.clockString(minute: $0.startMinute))–\(DayPlan.clockString(minute: $0.endMinute))" }
                .joined(separator: ", ")
            return "\(day) (\(clocks))"
        }
        return " It is on the day's log for \(days.joined(separator: " and ")) at the hours it ran."
    }

    /// Whether a call with session_id counts the sources it adds as reviewed.
    /// The call's own `mark_reviewed` decides when it is given; otherwise the
    /// chat's first import already did. A chat first saved with
    /// `mark_reviewed` false is stored as an ordinary chat (`kind` chat) and
    /// never marks a source reviewed later: on 2026-09-28 a chat saved that way
    /// marked the seven sources a later call linked reviewed, placed them on
    /// the Schedule done and stamped them read. An explicit false on a
    /// chat stored before imports wrote the kind stamps it, so the calls after
    /// it remember; a chat with no kind otherwise reads as the review its first
    /// import defaulted to.
    private func appendMarksReviewed(requested: Bool?, sessionID: String, store: KnowledgeStore) throws -> Bool {
        // Generation 2 reads the chat's own `marks_reviewed`, never its kind (§3.5.13).
        if store.syncGeneration == .two {
            return try store.generation2AppendMarksReviewed(requested: requested, sessionID: sessionID)
        }
        let kind = try store.loadReviewSessionKind(sessionID: sessionID)
        if requested == false, kind == nil {
            try store.markImportedChatAsChat(sessionID: sessionID)
        }
        if let requested { return requested }
        return kind == nil || kind == .review
    }

    private static func addedSourcesSentence(count: Int, markedReviewed: Bool) -> String {
        guard count > 0 else { return "" }
        let linked = "\(count) more source\(count == 1 ? "" : "s") linked"
        return markedReviewed
            ? " \(linked), now counted as reviewed and marked done on the Schedule."
            : " \(linked), without marking \(count == 1 ? "it" : "them") reviewed."
    }

    /// The record half of `import_review_chat` with `session_id`: the chat's
    /// client record is read whole and the stored exchanges are made equal
    /// to it, so a turn saved before its answer was written is replaced by
    /// the answer, and a turn the record has gained is appended.
    private func reconcileReviewChat(
        sessionID: String,
        with record: AssistantTranscriptFile,
        sourceIDs additionalSourceIDs: [String],
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        startedAt: Date?,
        endedAt: Date?,
        marksReviewed requestedMarksReviewed: Bool?,
        store: KnowledgeStore
    ) throws -> String {
        guard let existing = try store.loadReviewSessionForSync(sessionID) else {
            throw MCPError.invalidInput(
                "No review session with id \(sessionID). Import the first chunk of a chat without session_id, then pass the id that call returns with each further chunk."
            )
        }
        let marksReviewed = try appendMarksReviewed(requested: requestedMarksReviewed, sessionID: sessionID, store: store)
        let newSourceIDs = additionalSourceIDs.filter { !existing.sourceIDs.contains($0) }
        let outcome = try store.reconcileReviewChatExchanges(
            sessionID: sessionID,
            turns: record.turns,
            sourceIDs: additionalSourceIDs,
            summary: summary,
            overallScore: overallScore,
            modelProvider: modelProvider,
            modelID: modelID,
            endedAt: endedAt ?? record.endedAt
        )
        if marksReviewed {
            try markScheduledSourcesReviewed(newSourceIDs)
        }
        let clockText = recordChatOnDayLog(
            sessionID: sessionID,
            title: outcome.record.title,
            record: record,
            from: startedAt ?? record.startedAt,
            to: endedAt ?? record.endedAt,
            store: store
        )

        let count = outcome.record.exchangeCount
        let holds = "it holds \(count) exchange\(count == 1 ? "" : "s")"
        let changeText: String
        if outcome.appended == 0, outcome.replaced == 0 {
            changeText = "'\(outcome.record.title)' already matches \(Self.describe(record)); nothing was added and \(holds)."
        } else {
            var parts: [String] = []
            if outcome.appended > 0 { parts.append("\(outcome.appended) exchange\(outcome.appended == 1 ? "" : "s") appended") }
            if outcome.replaced > 0 { parts.append("\(outcome.replaced) stored exchange\(outcome.replaced == 1 ? "" : "s") rewritten from the record") }
            changeText = "'\(outcome.record.title)' now matches \(Self.describe(record)): \(parts.joined(separator: ", ")); \(holds)."
        }
        let scoreText = overallScore.map { " Score: \(String(format: "%.0f%%", $0 * 100))." } ?? ""
        let sourceText = Self.addedSourcesSentence(count: newSourceIDs.count, markedReviewed: marksReviewed)
        return "\(changeText)\(scoreText)\(sourceText)\(clockText) Call again with the same session_id and transcript_file after the next answer."
    }

    /// The append half of `import_review_chat`: a further chunk of a chat whose
    /// first chunk already made the session. A chunk whose turns are exactly
    /// the stored tail is a retried call, not a repeat of the conversation, so
    /// it is acknowledged and stored once. A chunk that declares the hours it
    /// ran is drawn on the day's log as a span of its own, or joined to the
    /// chat's span it continues.
    private func appendReviewChatChunk(
        to sessionID: String,
        turns: [ReviewChatTurn],
        sourceIDs additionalSourceIDs: [String],
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        startedAt: Date?,
        endedAt: Date?,
        marksReviewed requestedMarksReviewed: Bool?,
        store: KnowledgeStore
    ) throws -> String {
        guard let existing = try store.loadReviewSessionForSync(sessionID) else {
            throw MCPError.invalidInput(
                "No review session with id \(sessionID). Import the first chunk of a chat without session_id, then pass the id that call returns with each further chunk."
            )
        }
        let marksReviewed = try appendMarksReviewed(requested: requestedMarksReviewed, sessionID: sessionID, store: store)
        let chunk = turns.filter {
            cleanedOptional($0.question) != nil
                || cleanedOptional($0.answer) != nil
                || cleanedOptional($0.evaluation) != nil
        }
        guard !chunk.isEmpty else { throw MCPError.invalidInput("transcript had no readable messages.") }

        let tail = existing.exchanges.sorted { $0.sequenceNumber < $1.sequenceNumber }.suffix(chunk.count)
        let alreadyStored = tail.count == chunk.count && zip(tail, chunk).allSatisfy { exchange, turn in
            exchange.question == (cleanedOptional(turn.question) ?? "")
                && exchange.userAnswer == cleanedOptional(turn.answer)
                && exchange.evaluation == cleanedOptional(turn.evaluation)
        }
        if alreadyStored {
            return "Those \(chunk.count) exchange\(chunk.count == 1 ? "" : "s") are already the end of '\(existing.topic)'; nothing was added. The session holds \(existing.exchangeCount) exchange\(existing.exchangeCount == 1 ? "" : "s")."
        }

        let newSourceIDs = additionalSourceIDs.filter { !existing.sourceIDs.contains($0) }
        let record = try store.appendReviewChatExchanges(
            sessionID: sessionID,
            turns: chunk,
            sourceIDs: additionalSourceIDs,
            summary: summary,
            overallScore: overallScore,
            modelProvider: modelProvider,
            modelID: modelID
        )
        if marksReviewed {
            try markScheduledSourcesReviewed(newSourceIDs)
        }
        let clockText = recordChatOnDayLog(
            sessionID: sessionID,
            title: record.title,
            record: nil,
            from: startedAt,
            to: endedAt,
            store: store
        )

        let scoreText = overallScore.map { " Score: \(String(format: "%.0f%%", $0 * 100))." } ?? ""
        let sourceText = Self.addedSourcesSentence(count: newSourceIDs.count, markedReviewed: marksReviewed)
        return "Appended \(chunk.count) exchange\(chunk.count == 1 ? "" : "s") to '\(record.title)'; it now holds \(record.exchangeCount).\(scoreText)\(sourceText)\(clockText) Pass the same session_id with the next chunk, or stop here: the session is complete as stored."
    }

    /// Parse a role-labeled chat transcript into question/answer exchanges.
    /// Assistant messages form the question side, user messages the answer side;
    /// consecutive same-role messages merge. If no role markers are found the
    /// whole transcript is kept as a single exchange rather than dropped.
    func parseReviewTranscript(_ transcript: String) -> [ReviewChatTurn] {
        ReviewTranscriptParser.turns(from: transcript)
    }

    func searchReviewSessions(queryText: String, limit: Int) throws -> String {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Provide a non-empty query." }
        let cappedLimit = max(1, min(limit, 50))
        // Screen record mode (admin only): hidden chats are dropped after the
        // query, so the SQL limit is lifted while the scope is on and the
        // requested one applied to what is left. Nil scope: unchanged.
        let screenScope = screenRecordScope()
        let screenRecordHidden = try screenRecordHiddenReviewSessionIDs(scope: screenScope)
        return try withDB { db in
            let like = "%\(trimmed)%"
            let queried = try query(db, """
                SELECT fs.id, fs.topic, fs.status, fs.overall_score, fs.started_at
                FROM review_sessions fs
                WHERE fs.id IN (
                    SELECT fs2.id FROM review_sessions fs2
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs2.id
                    WHERE fs2.topic LIKE ? OR fs2.summary LIKE ?
                       OR fe.question LIKE ? OR fe.user_answer LIKE ? OR fe.evaluation LIKE ?
                )
                ORDER BY fs.started_at DESC
                LIMIT ?
            """, params: [like, like, like, like, like, screenScope == nil ? cappedLimit : -1])
            let rows = screenScope == nil ? queried : Array(queried.filter { row in
                guard let id = row["id"] as? String else { return false }
                return !screenRecordHidden.contains(id)
            }.prefix(cappedLimit))

            guard !rows.isEmpty else {
                return "No review sessions match \"\(trimmed)\"."
            }

            var lines = ["Review sessions matching \"\(trimmed)\" (\(rows.count)):"]
            for r in rows {
                let id = r["id"] as? String ?? ""
                let topic = r["topic"] as? String ?? "Untitled"
                let status = r["status"] as? String ?? ""
                let date = (r["started_at"] as? Double).map { appleToISO($0) } ?? ""
                let scoreText = (r["overall_score"] as? Double).map { " \(String(format: "%.0f%%", $0 * 100))" } ?? ""
                lines.append("- \(topic) (id: \(id)) [\(status)]\(scoreText) — \(date)")
                let snippet = try reviewMatchSnippet(db, sessionID: id, like: like, term: trimmed)
                if !snippet.isEmpty {
                    lines.append("  …\(snippet)…")
                }
            }
            lines.append("\nUse get_review_session_transcript with a session id to read a full match.")
            return lines.joined(separator: "\n")
        }
    }

    private func reviewMatchSnippet(_ db: OpaquePointer, sessionID: String, like: String, term: String) throws -> String {
        let rows = try query(db, """
            SELECT question, user_answer, evaluation
            FROM review_exchanges
            WHERE session_id = ?
              AND (question LIKE ? OR user_answer LIKE ? OR evaluation LIKE ?)
            ORDER BY sequence_number ASC
            LIMIT 1
        """, params: [sessionID, like, like, like])
        guard let row = rows.first else { return "" }
        let candidates = [row["question"] as? String, row["user_answer"] as? String, row["evaluation"] as? String].compactMap { $0 }
        let lowerTerm = term.lowercased()
        for text in candidates {
            guard let range = text.lowercased().range(of: lowerTerm) else { continue }
            let matchOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let startOffset = max(0, matchOffset - 60)
            let startIndex = text.index(text.startIndex, offsetBy: startOffset)
            let snippet = String(text[startIndex...].prefix(160))
            return snippet.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    func listReviewSessionLinks() throws -> String {
        // Screen record mode (admin only): the chats the take may show. Empty
        // hidden set, and so every link, when the mode is off.
        let screenRecordHidden = try screenRecordHiddenReviewSessionIDs(scope: screenRecordScope())
        let links = try knowledgeStore().loadReviewSessionLinks()
            .filter { !screenRecordHidden.contains($0.id) }
        guard !links.isEmpty else {
            return "No saved review session links."
        }
        var lines = ["Review session links (\(links.count)):"]
        for link in links {
            let fmt = ISO8601DateFormatter()
            let urlText = link.url.map { "\n  \($0)" } ?? ""
            let sourceText = link.sourceIDs.isEmpty ? "" : ", sources: \(link.sourceIDs.joined(separator: ", "))"
            lines.append("- [\(link.provider.rawValue)] \(link.title) (id: \(link.id), saved: \(fmt.string(from: link.createdAt))\(sourceText))\(urlText)")
        }
        return lines.joined(separator: "\n")
    }

    func normalizedPaperImportURL(_ rawURL: String) throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("url is required")
        }
        if trimmed.lowercased().hasPrefix("doi:") {
            return "https://doi.org/\(String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if trimmed.hasPrefix("10.") {
            return "https://doi.org/\(trimmed)"
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw MCPError.invalidInput("url must be an http(s) URL or DOI")
        }
        return trimmed
    }

    /// A plugin may stage a private PDF locally, but an ingest-scoped token
    /// must not be able to point the app at arbitrary PDFs elsewhere on disk.
    /// Each authenticated plugin therefore gets one private inbox under the
    /// app's local support directory. The plugin name comes from its OAuth
    /// registration and is already sanitized by MCPOAuthProvider.
    func pluginInboxURL(connectorLabel: String, create: Bool = true) throws -> URL {
        let base: URL
        if dbPathOverride != nil {
            base = URL(fileURLWithPath: knowledgeDBPath)
                .deletingLastPathComponent()
                .appendingPathComponent("ConnectorInbox", isDirectory: true)
        } else {
            base = localAppDataDir.appendingPathComponent("ConnectorInbox", isDirectory: true)
        }
        let label = MCPOAuthProvider.sanitizedPluginLabel(connectorLabel)
        let inbox = base.appendingPathComponent(Self.safeFilenameBase(label), isDirectory: true)
        if create {
            try FileManager.default.createDirectory(
                at: inbox,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
        }
        return inbox.standardizedFileURL.resolvingSymlinksInPath()
    }

    func getConnectorInbox(connectorLabel: String) throws -> String {
        let inbox = try pluginInboxURL(connectorLabel: connectorLabel)
        return try jsonString([
            "connector": MCPOAuthProvider.sanitizedPluginLabel(connectorLabel),
            "path": inbox.path,
            "max_file_bytes": Self.maxClientProvidedFileBytes,
        ] as [String: Any])
    }

    func validatePluginStagedPDF(_ rawPath: String, connectorLabel: String) throws -> URL {
        let candidate = try validateClientProvidedPath(rawPath)
        let inbox = try pluginInboxURL(connectorLabel: connectorLabel)
        guard candidate.path == inbox.path || candidate.path.hasPrefix(inbox.path + "/") else {
            throw MCPError.invalidInput(
                "file_path must be inside this plugin's staging directory. Call get_connector_inbox first."
            )
        }
        guard candidate.pathExtension.lowercased() == "pdf" else {
            throw MCPError.invalidInput("import_connector_paper accepts PDF files only.")
        }
        return candidate
    }

    /// Reject obvious local-network and machine-local targets before allowing an
    /// ingest plugin to ask ForeverLM to resolve a paper URL. Full-access
    /// assistants retain the historical import_paper_from_url behavior; this is
    /// the narrower plugin boundary. Redirects remain subject to URLSession's
    /// normal HTTP policy, while the Slack plugin itself only submits links it
    /// classified as academic papers.
    func validatePluginPaperURL(_ rawURL: String) throws -> String {
        let normalized = try normalizedPaperImportURL(rawURL)
        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw MCPError.invalidInput("url must be a public paper URL or DOI.")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw MCPError.invalidInput("Plugin paper URLs must use HTTPS.")
        }
        if let port = components.port, port != 443 {
            throw MCPError.invalidInput("Plugin paper URLs may use only the standard HTTPS port.")
        }
        let blockedNames = ["localhost", "localhost.localdomain"]
        guard !blockedNames.contains(host),
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else {
            throw MCPError.invalidInput("Plugin paper URLs must not target this Mac or a private network host.")
        }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            let blocked = bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || bytes[0] >= 224
            guard !blocked else {
                throw MCPError.invalidInput("Plugin paper URLs must not target a private or reserved IP address.")
            }
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            let isUnspecifiedOrLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && (bytes.last == 0 || bytes.last == 1)
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            guard !isUnspecifiedOrLoopback, !isUniqueLocal, !isLinkLocal else {
                throw MCPError.invalidInput("Plugin paper URLs must not target a private or reserved IP address.")
            }
        }
        let academicHosts = [
            "acm.org", "arxiv.org", "biorxiv.org", "cell.com", "doi.org",
            "ieee.org", "medrxiv.org", "nature.com", "openreview.net", "osf.io",
            "pubmed.ncbi.nlm.nih.gov", "science.org", "sciencedirect.com",
            "semanticscholar.org", "springer.com", "wiley.com", "zenodo.org",
        ]
        guard academicHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw MCPError.invalidInput(
                "Plugin URL imports are limited to recognized academic hosts. Download a direct PDF into get_connector_inbox and import it by file_path instead."
            )
        }
        return normalized
    }

    func importPluginPaper(
        url: String?,
        filePath: String?,
        sourceURL: String?,
        title: String?,
        connectorLabel: String
    ) async throws -> String {
        let remoteURL = Self.nilIfBlank(url ?? "")
        let localPath = Self.nilIfBlank(filePath ?? "")
        guard (remoteURL == nil) != (localPath == nil) else {
            throw MCPError.invalidInput("Supply exactly one of url or file_path.")
        }

        if let remoteURL {
            let safeURL = try validatePluginPaperURL(remoteURL)
            return try await importPaperFromURL(
                safeURL,
                title: title,
                connectorLabel: connectorLabel
            )
        }

        let staged = try validatePluginStagedPDF(localPath!, connectorLabel: connectorLabel)
        guard let canonicalURL = Self.httpURLString(sourceURL ?? ""),
              URL(string: canonicalURL)?.scheme?.lowercased() == "https" else {
            throw MCPError.invalidInput(
                "source_url is required for a staged PDF and must be its stable public HTTPS provenance URL."
            )
        }
        return try await importLocalPDFAsPaper(
            filePath: staged.path,
            title: title,
            canonicalURL: canonicalURL,
            connectorLabel: connectorLabel
        )
    }

    /// Imports a paper whose PDF is served at one address and whose identity is
    /// another — a Slack file's `download_url` and its permalink, for instance.
    ///
    /// The download address is transport, so it is never stored: the paper's
    /// canonical URL and dedup key is `sourceURL`, the same rule
    /// `import_connector_paper` applies to a staged PDF. The bytes are fetched
    /// through the importer's ordinary PDF download (which carries the managed
    /// session when the host is ForeverLM's own gateway), staged under the
    /// temporary directory, and filed by the local-PDF path so identity, dedup
    /// and the required metadata step are the ones every paper goes through.
    func importPaperFromDownloadURLOutcome(
        _ rawURL: String,
        sourceURL rawSourceURL: String,
        title: String?
    ) async throws -> PaperImportOutcome {
        switch try await stagePaperFromDownloadURL(rawURL, sourceURL: rawSourceURL, title: title) {
        case .settled(let outcome):
            return outcome
        case .staged(let staged):
            return try await finishStagedLocalPaper(staged)
        }
    }

    /// `importPaperFromDownloadURLOutcome` up to the models: the PDF
    /// downloaded, holding nothing, and staged as a local PDF
    /// (`stageLocalPDFAsPaper`), which saves it as a pending paper in a
    /// stretch of its own.
    func stagePaperFromDownloadURL(
        _ rawURL: String,
        sourceURL rawSourceURL: String,
        title: String?
    ) async throws -> LocalPaperStaging {
        let downloadURL = try normalizedPaperImportURL(rawURL)
        guard let canonicalURL = Self.httpURLString(rawSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPError.invalidInput(
                "source_url must be an http(s) URL: the file's stable provenance address, such as a Slack file permalink."
            )
        }
        let held = try await withStoreGate(.shared) { () -> (id: String, status: SourceStatus)? in
            let store = try knowledgeStore()
            guard let existing = store.sourceExistsByNormalizedURL(URLNormalizer.normalize(canonicalURL))
                    ?? store.sourceExistsByURL(canonicalURL),
                  let article = try store.loadSourceForSync(existing.id),
                  !Self.existingPaperTakesArrivingPDF(article) else { return nil }
            return (existing.id, existing.status)
        }
        if let held {
            return .settled(PaperImportOutcome(message: "Source already exists (id: \(held.id), status: \(held.status.rawValue))", sourceID: held.id))
        }

        let pdfURL = try await resolvedPDFURLForAttachment(downloadURL)
        let leaf = URL(string: pdfURL)?.deletingPathExtension().lastPathComponent
        let baseName = Self.safeFilenameBase(Self.nilIfBlank(leaf ?? "") ?? "paper")
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLM-paper-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let staged = stagingDir.appendingPathComponent(baseName).appendingPathExtension("pdf")
        try await downloadPaperPDFForImport(from: pdfURL, sourceURL: canonicalURL, to: staged)
        return try await stageLocalPDFAsPaper(filePath: staged.path, title: title, canonicalURL: canonicalURL)
    }

    /// `importPaperFromDownloadURLOutcome`'s answer alone.
    func importPaperFromDownloadURL(
        _ rawURL: String,
        sourceURL rawSourceURL: String,
        title: String?
    ) async throws -> String {
        try await importPaperFromDownloadURLOutcome(rawURL, sourceURL: rawSourceURL, title: title).message
    }

    func resolvedPaperPDFURL(
        sourceURL: String,
        pageMetadata: PaperService.PaperPageMetadata?,
        doi storedDOI: String? = nil
    ) async throws -> String {
        if let direct = PaperService.paperPDFURL(from: sourceURL) {
            return direct
        }

        // A PMC article is fetched from NCBI's own PDF route, whose
        // proof-of-work check `downloadPDF` answers. Europe PMC's render, which
        // the lookup used to return, answers apps with 403 (2026-09-23).
        if let route = PaperService.ncbiPMCPDFURL(forArticleURL: sourceURL),
           PaperService.isNCBIPMCURL(sourceURL) {
            return route
        }

        if let pmcid = PaperService.extractPMCID(from: sourceURL),
           let pmcResult = await PaperService.lookupPMCByPMCID(pmcid: pmcid),
           let pdfURL = pmcResult.orderedPDFURLs.first {
            return pdfURL
        }

        if let pmid = PaperService.extractPMID(from: sourceURL),
           let pmcResult = await PaperService.lookupPMCByPMID(pmid: pmid),
           let pdfURL = pmcResult.orderedPDFURLs.first {
            return pdfURL
        }

        if let metaPDF = pageMetadata?.pdfURL,
           let resolved = Self.resolveURL(metaPDF, relativeTo: sourceURL) {
            return resolved
        }

        if let extracted = await PaperService.extractPDFURLFromWebPage(at: sourceURL) {
            return extracted
        }

        let doi = PaperService.openAccessLookupDOI(url: sourceURL, storedDOI: storedDOI)
            ?? PaperService.openAccessLookupDOI(url: "", storedDOI: pageMetadata?.doi)
        if let doi {
            if let pmcResult = await PaperService.lookupPMC(doi: doi), let pdfURL = pmcResult.orderedPDFURLs.first {
                return pdfURL
            }
            if let unpaywallURL = await PaperService.lookupUnpaywall(doi: doi) {
                return unpaywallURL
            }
        }

        throw PaperPDFUnavailableError(sourceURL: sourceURL)
    }

    func existingPaperByDOI(_ doi: String) throws -> (id: String, status: SourceStatus)? {
        let normalizedDOI = Self.normalizeDOI(doi)
        return try withDB { db in
            let rows = try query(
                db,
                "SELECT id, status FROM source_projection WHERE LOWER(doi) = ? LIMIT 1",
                params: [normalizedDOI.lowercased()]
            )
            guard let row = rows.first, let id = row["id"] as? String else { return nil }
            let status = (row["status"] as? String).flatMap { SourceStatus(rawValue: $0) } ?? .active
            return (id: id, status: status)
        }
    }

    func uniquePaperDestination(in papersDir: URL, doi: String?, url: String) -> URL {
        let filename = Self.preferredPaperFilename(doi: doi, url: url)
        var candidate = papersDir.appendingPathComponent(filename)
        let ext = candidate.pathExtension.isEmpty ? "pdf" : candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = papersDir
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    func cleanedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func fallbackPaperTitle(from sourceURL: String, pdfURL: String) -> String {
        let candidateURL = URL(string: sourceURL) ?? URL(string: pdfURL)
        let stem = candidateURL?.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stem, !stem.isEmpty, stem != "/" {
            return stem
        }
        return URL(string: sourceURL)?.host ?? "Imported Paper"
    }

    func titleNeedsReplacement(_ title: String, sourceURL: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasPrefix("http") { return true }
        if trimmed.lowercased().hasSuffix(".pdf") { return true }
        // Blank, the host's own name, a redirect page's "Redirecting", a bot
        // check's "Just a moment…": chrome a landing page wore, never a paper's
        // title. Four Elsevier DOIs were saved as "Redirecting" this way.
        if PaperService.isInterstitialPageTitle(trimmed, url: sourceURL) { return true }
        return false
    }

    /// The landing page's title when it is worth keeping: trimmed, and not a
    /// URL, a filename or an interstitial's. Nil otherwise, so a caller falls
    /// through to the next source rather than saving or searching by chrome.
    func usablePageTitle(_ title: String?, sourceURL: String) -> String? {
        guard let title = cleanedOptional(title), !titleNeedsReplacement(title, sourceURL: sourceURL) else {
            return nil
        }
        return title
    }

    static func preferredPaperFilename(doi: String?, url: String) -> String {
        let filename: String
        if let doi, !doi.isEmpty {
            filename = normalizeDOI(doi).replacingOccurrences(of: "/", with: "_") + ".pdf"
        } else if let parsed = URL(string: url), parsed.pathExtension.lowercased() == "pdf", !parsed.lastPathComponent.isEmpty {
            filename = parsed.lastPathComponent
        } else {
            let fallbackStem = url
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            filename = String(fallbackStem.prefix(80)) + ".pdf"
        }
        return sanitizeFilename(filename, fallback: "paper.pdf")
    }

    static func sanitizeFilename(_ filename: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = filename
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".pdf" else { return fallback }
        return cleaned.lowercased().hasSuffix(".pdf") ? cleaned : "\(cleaned).pdf"
    }

    static func resolveURL(_ value: String, relativeTo baseURLString: String) -> String? {
        guard let baseURL = URL(string: baseURLString) else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute.absoluteString
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    static func extractPDFTitle(from path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              let attrs = doc.documentAttributes,
              let title = attrs[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count < 300, !trimmed.lowercased().hasSuffix(".pdf") else {
            return nil
        }
        return trimmed
    }

    static func extractDOIFromPDF(at path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        if let attrs = doc.documentAttributes {
            for key in [PDFDocumentAttribute.subjectAttribute, PDFDocumentAttribute.keywordsAttribute] {
                if let value = attrs[key] as? String, let doi = extractDOIFromText(value) {
                    return doi
                }
            }
        }
        if let firstPageText = doc.page(at: 0)?.string, let doi = extractDOIFromText(firstPageText) {
            return doi
        }
        return nil
    }

    static func extractDOIFromText(_ text: String) -> String? {
        PaperService.firstPrintedDOI(in: text).map(normalizeDOI)
    }

    static func normalizeDOI(_ doi: String) -> String {
        var value = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"^https?://(?:dx\.)?doi\.org/"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"^doi:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        while value.hasSuffix(".") || value.hasSuffix(",") || value.hasSuffix(";") {
            value.removeLast()
        }
        return value
    }

    func recordPaperPDFIdentityMismatch(
        _ rejection: PaperPDFIdentityMismatchError,
        requestedURL: String,
        request: PaperPDFIdentity.Request,
        sourceID: String?
    ) {
        logger.warning(
            "Turned away the PDF at \(rejection.pdfURL, privacy: .public) for \(requestedURL, privacy: .public): \(rejection.reason, privacy: .public)"
        )
        PaperIngestionDiagnostics.recordPDFIdentityMismatch(
            sourceID: sourceID,
            requestedURL: requestedURL,
            requestedDOI: request.doi,
            pdfURL: rejection.pdfURL,
            reason: rejection.reason
        )
    }

    /// `paperHasPDF` is the existing paper's state when one is being rechecked;
    /// a paper that already has its file is never fetched again as the reader.
    func downloadPaperPDFForImport(
        from pdfURL: String,
        sourceURL: String,
        to destination: URL,
        label: String? = nil,
        paperHasPDF: Bool = false
    ) async throws {
        do {
            try await SourceService.shared.downloadPDF(from: pdfURL, to: destination.path)
        } catch {
            if ScienceDirectService.isScienceDirectURL(pdfURL) || ScienceDirectService.isScienceDirectURL(sourceURL) {
                try await ScienceDirectService.downloadPDFWithAuthenticatedWebSession(
                    from: pdfURL,
                    to: destination.path,
                    label: label
                )
                return
            }
            // The publisher answered ForeverLM's own client with a page while
            // the reader holds a session for the host: fetch the file as the
            // reader, so Recheck all recovers a paper the subscription covers.
            // See `WebSessionPDFDownload` for the gates.
            guard let url = URL(string: pdfURL) else { throw error }
            let readerCookies = await InAppWebSession.cookies(for: url)
            let decision = WebSessionPDFDownload.decision(
                pdfURL: pdfURL,
                after: error,
                cookies: readerCookies,
                paperHasPDF: paperHasPDF
            )
            guard decision == .attempt else { throw error }
            let data = try await WebSessionPDFDownloader.download(
                url,
                landingPage: URL(string: sourceURL) ?? WebSessionPDFDownloader.landingPageURL(forPDF: url)
            )
            try data.write(to: destination)
        }
    }

    /// The answer an import gives and the library source it produced or
    /// matched. The id is the one the import itself saved or found — never
    /// parsed back out of the answer — so a caller can file that source
    /// somewhere (`import_paper_from_url`'s notebook_id). Nil when the import
    /// ended with no row it can name.
    struct PaperImportOutcome: Sendable {
        let message: String
        let sourceID: String?
    }

    /// `import_paper_from_url` for a caller that wants the paper read before
    /// it answers (a connector's paper, a course's citations, a video's cited
    /// paper): staged with its PDF, then read by the models in the same call.
    /// A failure is saved on the paper, which keeps its PDF.
    func importPaperFromURLOutcome(
        _ rawURL: String,
        title titleOverride: String?,
        connectorLabel: String? = nil
    ) async throws -> PaperImportOutcome {
        switch try await stagePaperFromURL(rawURL, title: titleOverride, connectorLabel: connectorLabel) {
        case .settled(let outcome):
            return outcome
        case .staged(let staged):
            return try await finishStagedLocalPaper(staged)
        }
    }

    /// The half of a URL import that needs no model: the paper's PDF found and
    /// downloaded (the publisher's, then open-access copies, each held to the
    /// paper asked for), its text extracted and its bibliography looked up,
    /// then saved as a pending paper with its PDF, ready for
    /// `finishStagedLocalPaper`. A publisher that blocks the PDF leaves a
    /// paywalled paper, and a paper the library already holds by URL or DOI
    /// answers with its id (or, when it has no PDF, takes this one).
    ///
    /// The store is held only for each lookup and save, never across a
    /// download or a scholarly lookup. Until 2026-10-12 the dispatcher held it
    /// alone for the whole import, models included: several imports sent
    /// together ran one after another, every other call queued behind them,
    /// and the later clients timed out. Imports now run side by side, so the
    /// PDF is downloaded into a folder of its own and claimed in the Papers
    /// folder by the move that puts it there (`movePaperIntoPapersFolder`),
    /// and the library is asked again for the paper inside the stretch that
    /// saves it.
    func stagePaperFromURL(
        _ rawURL: String,
        title titleOverride: String?,
        connectorLabel: String? = nil
    ) async throws -> LocalPaperStaging {
        let sourceURL = try normalizedPaperImportURL(rawURL)
        let normalizedURL = URLNormalizer.normalize(sourceURL)
        if let existing = try await withStoreGate(.shared, { try existingSource(atPaperURL: sourceURL, normalizedURL: normalizedURL) }) {
            return .settled(PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id))
        }

        let pageMetadata = await PaperService.fetchPaperPageMetadata(at: sourceURL)
        var doi = (PaperService.extractDOI(from: sourceURL) ?? pageMetadata?.doi).map(Self.normalizeDOI)
        if let settled = try await existingPaperAnswer(doi: doi) {
            return .settled(settled)
        }

        let papersDir = sourceContentRoot.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papersDir, withIntermediateDirectories: true)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLM-paper-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let destination = stagingDir.appendingPathComponent(Self.preferredPaperFilename(doi: doi, url: sourceURL))

        // What was asked for, before any PDF speaks for itself. Every file
        // below is held to it (`PaperPDFIdentity`): an index can list another
        // paper's copy under this DOI, and once the Paper Metadata model has
        // read that copy it rewrites the bibliography to match, so a wrong
        // file has to be caught here or it passes for the paper.
        var identity = PaperPDFIdentity.Request(
            doi: doi,
            titles: [cleanedOptional(titleOverride), usablePageTitle(pageMetadata?.title, sourceURL: sourceURL)]
                .compactMap { $0 }
        )
        var rejectedPDFs: [PaperPDFIdentityMismatchError] = []
        /// Whether the file just written to `destination` is the paper asked
        /// for. Another paper's file is removed and recorded, and the caller
        /// goes on to its next candidate.
        func acceptsDownloadedPDF(from pdfURL: String) async -> Bool {
            let verdict = await PaperPDFIdentity.verdict(forPDFAt: destination, request: &identity)
            guard case .mismatch(let reason) = verdict else { return true }
            try? FileManager.default.removeItem(at: destination)
            let rejection = PaperPDFIdentityMismatchError(pdfURL: pdfURL, reason: reason)
            rejectedPDFs.append(rejection)
            recordPaperPDFIdentityMismatch(rejection, requestedURL: sourceURL, request: identity, sourceID: nil)
            return false
        }

        // Resolve and download the publisher's PDF, then fall back to open-access
        // copies. Resolution and download fail in the same paywall-shaped ways
        // (no PDF link anywhere, 401/402/403, an HTML page served instead of the
        // file), so the publisher's own failure is kept aside and classified
        // once every fallback has also come up empty.
        var downloadedPDFURL: String?
        var publisherError: Error?
        do {
            let resolved = try await resolvedPaperPDFURL(sourceURL: sourceURL, pageMetadata: pageMetadata)
            do {
                try await downloadPaperPDFForImport(from: resolved, sourceURL: sourceURL, to: destination)
                if await acceptsDownloadedPDF(from: resolved) {
                    downloadedPDFURL = resolved
                }
            } catch {
                publisherError = error
                try? FileManager.default.removeItem(at: destination)
                if sourceURL.lowercased().contains("doi.org/10.1101/"), resolved.contains("biorxiv.org") {
                    let medrxivURL = resolved.replacingOccurrences(of: "biorxiv.org", with: "medrxiv.org")
                    do {
                        try await downloadPaperPDFForImport(from: medrxivURL, sourceURL: sourceURL, to: destination)
                        if await acceptsDownloadedPDF(from: medrxivURL) {
                            downloadedPDFURL = medrxivURL
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
            }
        } catch {
            publisherError = error
        }

        var lastDownloadError = publisherError
        if downloadedPDFURL == nil {
            let alternatives = await PaperService.findOpenAccessAlternatives(
                url: sourceURL,
                title: cleanedOptional(titleOverride) ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL) ?? "",
                doi: doi
            )
            for alternative in alternatives {
                do {
                    let alternativePDFURL = try await resolvedPaperPDFURL(
                        sourceURL: alternative.replacementURL,
                        pageMetadata: nil
                    )
                    try await downloadPaperPDFForImport(
                        from: alternativePDFURL,
                        sourceURL: alternative.replacementURL,
                        to: destination
                    )
                    guard await acceptsDownloadedPDF(from: alternativePDFURL) else { continue }
                    downloadedPDFURL = alternativePDFURL
                    break
                } catch {
                    lastDownloadError = error
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }

        guard let pdfURL = downloadedPDFURL else {
            let failure = lastDownloadError ?? PaperPDFUnavailableError(sourceURL: sourceURL)
            // The publisher blocking the PDF is not a reason to lose the paper.
            // Studio keeps a paper whose download hits a paywall as a paywalled
            // row, and the bulk download pass marks one the same way; the URL
            // import used to be the one path that threw and saved nothing, so
            // the assistant told the learner the paper "wasn't added" even
            // though every recovery path here works from a saved row. A file
            // turned away as another paper counts as no PDF of this one, and
            // the evidence names it.
            let evidence = (publisherError.flatMap(Self.paperPaywallEvidence(for:))
                ?? Self.paperPaywallEvidence(for: failure))
                .map { Self.paperPaywallEvidence($0, rejecting: rejectedPDFs) }
            if let evidence {
                let scholarlyMetadata = await PaperService.fetchPaperMetadata(
                    url: sourceURL,
                    title: cleanedOptional(titleOverride) ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL) ?? "",
                    doi: doi
                )
                if doi == nil, let metaDOI = scholarlyMetadata?.doi {
                    doi = Self.normalizeDOI(metaDOI)
                }
                let paywalledDOI = doi
                // Asked again where the row is saved: another call may have
                // brought the paper in while this one looked for its PDF.
                let saved = try await withStoreGate(.exclusive) { () -> PaperImportOutcome? in
                    if let existing = try existingSource(atPaperURL: sourceURL, normalizedURL: normalizedURL) {
                        return PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                    }
                    if let paywalledDOI, let existing = try existingPaperByDOI(paywalledDOI) {
                        return PaperImportOutcome(message: "Paper already exists for DOI \(paywalledDOI) (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                    }
                    guard let message = try savePaywalledPaperImport(
                        sourceURL: sourceURL,
                        normalizedURL: normalizedURL,
                        titleOverride: titleOverride,
                        pageMetadata: pageMetadata,
                        scholarlyMetadata: scholarlyMetadata,
                        doi: paywalledDOI,
                        evidence: evidence,
                        connectorLabel: connectorLabel
                    ) else { return nil }
                    // Saved under the address it was asked for, which is how
                    // its row is found again.
                    return PaperImportOutcome(message: message, sourceID: try knowledgeStore().sourceExistsByNormalizedURL(normalizedURL)?.id)
                }
                if let saved {
                    return .settled(saved)
                }
            }
            throw failure
        }
        if doi == nil {
            doi = PaperService.extractDOI(from: pdfURL).map(Self.normalizeDOI)
        }
        if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
            return .settled(settled)
        }

        guard SourceService.canOpenPDF(at: destination.path) else {
            throw SourceError.pdfReadFailed
        }

        let pdfText = try SourceService.shared.extractTextFromPDF(at: destination.path)
        if doi == nil {
            doi = Self.extractDOIFromPDF(at: destination.path) ?? Self.extractDOIFromText(pdfText)
        }
        if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
            return .settled(settled)
        }

        var resolvedTitle = cleanedOptional(titleOverride)
            ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL)
            ?? Self.extractPDFTitle(from: destination.path)
            ?? fallbackPaperTitle(from: sourceURL, pdfURL: pdfURL)

        var metadata = await PaperService.fetchPaperMetadata(url: sourceURL, title: resolvedTitle, doi: doi)
        if let metaTitle = metadata?.title, titleNeedsReplacement(resolvedTitle, sourceURL: sourceURL) {
            resolvedTitle = metaTitle
        }
        if doi == nil {
            doi = metadata?.doi.map(Self.normalizeDOI)
        }
        if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
            return .settled(settled)
        }

        if metadata == nil, let pageTitle = usablePageTitle(pageMetadata?.title, sourceURL: sourceURL), pageTitle != resolvedTitle {
            metadata = await PaperService.fetchPaperMetadata(url: sourceURL, title: pageTitle, doi: doi)
        }
        if doi == nil, let metaDOI = metadata?.doi {
            doi = Self.normalizeDOI(metaDOI)
            if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
                return .settled(settled)
            }
        }

        let paperPDF = try movePaperIntoPapersFolder(destination, papersDir: papersDir, doi: doi, sourceURL: sourceURL)
        let host = URL(string: sourceURL)?.host ?? "Paper"
        var article = StudioArticle(
            url: sourceURL,
            title: resolvedTitle,
            sourceType: .paper,
            discoveryOrigin: connectorLabel == nil ? .manual : .plugin,
            localFilePath: relativeSourceContentPath(paperPDF) ?? StorageService.relativeSourcePath(paperPDF.path),
            author: pageMetadata?.authorsDisplay ?? metadata?.authorsDisplay ?? StudioArticle.unknownPaperAuthor,
            journal: pageMetadata?.journal ?? metadata?.journal ?? StudioArticle.unknownPaperJournal,
            publishedYear: pageMetadata?.year ?? metadata?.year ?? StudioArticle.unknownPaperYear
        )
        article.normalizedURL = normalizedURL
        article.connectorLabel = connectorLabel
        article.domain = host
        article.content = pdfText
        article.wordCount = pdfText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.prepareForPaperMetadataExtraction()
        article.doi = doi ?? metadata?.doi.map(Self.normalizeDOI)
        article.isPaywalled = false
        // Scholarly APIs provide context, but every successful paper import must
        // read the paper itself with the configured Paper Metadata model.
        let firstPageText = PDFDocument(url: paperPDF)?.page(at: 0)?.string ?? ""

        let pending = article
        let settled: PaperImportOutcome?
        do {
            settled = try await withStoreGate(.exclusive) { () -> PaperImportOutcome? in
                // Another call may have brought in the same paper while this
                // one downloaded and read it.
                if let existing = try existingSource(atPaperURL: sourceURL, normalizedURL: normalizedURL) {
                    return PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                }
                if let settled = try await settleDownloadedPDFForExistingPaper(doi: pending.doi, pdf: paperPDF, pdfURL: pdfURL) {
                    return settled
                }
                try knowledgeStore().saveSource(pending)
                return nil
            }
        } catch {
            try? FileManager.default.removeItem(at: paperPDF)
            throw error
        }
        if let settled {
            try? FileManager.default.removeItem(at: paperPDF)
            return .settled(settled)
        }
        return .staged(StagedLocalPaper(
            article: article,
            destination: paperPDF,
            firstPageText: firstPageText,
            marks: "",
            downloadedFrom: pdfURL
        ))
    }

    /// The library's source at a paper's address, by its normalized URL or
    /// the URL as given. Read inside a store stretch.
    private func existingSource(atPaperURL sourceURL: String, normalizedURL: String) throws -> (id: String, status: SourceStatus)? {
        let store = try knowledgeStore()
        guard let existing = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(sourceURL) else {
            return nil
        }
        return (existing.id, existing.status)
    }

    /// "Paper already exists" for a DOI the library holds; nil when it holds
    /// none (or there is no DOI). Reads in a shared stretch of its own.
    private func existingPaperAnswer(doi: String?) async throws -> PaperImportOutcome? {
        guard let doi, let existing = try await withStoreGate(.shared, { try existingPaperByDOI(doi) }) else {
            return nil
        }
        return PaperImportOutcome(message: "Paper already exists for DOI \(doi) (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
    }

    /// What became of a downloaded PDF whose DOI the library already holds: a
    /// paper listed without a PDF (paywalled, or its file gone) takes a copy
    /// of it (`adoptPDFForExistingPaper`, which reads it with the Paper
    /// Metadata model as attach_pdf_to_paper does, holding the store alone),
    /// any other answers that it already exists. Nil when the DOI is new, found
    /// in a shared stretch so a new paper never waits for the store alone. The
    /// caller removes its own file.
    private func settleDownloadedPDFForExistingPaper(doi: String?, pdf: URL, pdfURL: String) async throws -> PaperImportOutcome? {
        guard let doi, try await withStoreGate(.shared, { try existingPaperByDOI(doi) }) != nil else { return nil }
        return try await withStoreGate(.exclusive) { () -> PaperImportOutcome? in
            guard let existing = try existingPaperByDOI(doi) else { return nil }
            let adopted = try await adoptPDFForExistingPaper(id: existing.id, stagedPDF: pdf, attachedFrom: pdfURL)
            return PaperImportOutcome(message: adopted ?? "Paper already exists for DOI \(doi) (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
        }
    }

    /// Moves a downloaded PDF into the Papers folder under the paper's own
    /// name (`preferredPaperFilename`), or that name numbered when it is
    /// taken. URL imports run side by side, so the name is claimed by the move
    /// itself, which never overwrites, rather than by a look beforehand: two
    /// papers whose links both end in `fulltext.pdf` would otherwise be
    /// written to the same file.
    func movePaperIntoPapersFolder(_ downloaded: URL, papersDir: URL, doi: String?, sourceURL: String) throws -> URL {
        var lastError: Error?
        for _ in 0..<20 {
            let candidate = uniquePaperDestination(in: papersDir, doi: doi, url: sourceURL)
            do {
                try FileManager.default.moveItem(at: downloaded, to: candidate)
                return candidate
            } catch {
                // Taken between the look and the move: the next free name.
                guard FileManager.default.fileExists(atPath: candidate.path) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? SourceError.pdfReadFailed
    }

    /// `importPaperFromURLOutcome`'s answer alone.
    func importPaperFromURL(
        _ rawURL: String,
        title titleOverride: String?,
        connectorLabel: String? = nil
    ) async throws -> String {
        try await importPaperFromURLOutcome(rawURL, title: titleOverride, connectorLabel: connectorLabel).message
    }

    /// Save a paper whose PDF the publisher blocks as the paywalled row Studio
    /// would have kept: the paper itself, with whatever bibliography the landing
    /// page and the scholarly APIs gave, marked paywalled with the same state
    /// `set_source_paywall_status` writes. No PDF and no text are stored, so the
    /// row is exactly what `attach_pdf_to_paper`, a PDF dropped into the Papers
    /// folder, and `recheck_paywalled_papers` all know how to finish.
    ///
    /// Returns nil when nothing identifies the page as a paper at all: no DOI,
    /// no citation metadata on the page, and no scholarly record. Saving that
    /// as a paywalled paper would file an arbitrary web page under Papers, so
    /// the caller reports the download failure instead.
    func savePaywalledPaperImport(
        sourceURL: String,
        normalizedURL: String,
        titleOverride: String?,
        pageMetadata: PaperService.PaperPageMetadata?,
        scholarlyMetadata: PaperService.CrossrefMetadata?,
        doi: String?,
        evidence: String,
        connectorLabel: String?
    ) throws -> String? {
        guard doi != nil || pageMetadata != nil || scholarlyMetadata != nil else { return nil }
        let store = try knowledgeStore()

        // The scholarly record is keyed by the DOI, so its title is the paper's.
        // The landing page's is whatever the publisher served instead of the
        // PDF — for an Elsevier DOI, linkinghub's "Redirecting" page — so it
        // stands in only when no record was found, and never when it is an
        // interstitial's.
        var resolvedTitle = cleanedOptional(titleOverride)
            ?? cleanedOptional(scholarlyMetadata?.title)
            ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL)
            ?? fallbackPaperTitle(from: sourceURL, pdfURL: sourceURL)
        if let metaTitle = cleanedOptional(scholarlyMetadata?.title),
           titleNeedsReplacement(resolvedTitle, sourceURL: sourceURL) {
            resolvedTitle = metaTitle
        }

        var article = StudioArticle(
            url: sourceURL,
            title: resolvedTitle,
            sourceType: .paper,
            discoveryOrigin: connectorLabel == nil ? .manual : .plugin,
            author: cleanedOptional(pageMetadata?.authorsDisplay)
                ?? cleanedOptional(scholarlyMetadata?.authorsDisplay)
                ?? StudioArticle.unknownPaperAuthor,
            journal: cleanedOptional(pageMetadata?.journal)
                ?? cleanedOptional(scholarlyMetadata?.journal)
                ?? StudioArticle.unknownPaperJournal,
            publishedYear: cleanedOptional(pageMetadata?.year)
                ?? cleanedOptional(scholarlyMetadata?.year)
                ?? StudioArticle.unknownPaperYear
        )
        article.normalizedURL = normalizedURL
        article.connectorLabel = connectorLabel
        article.domain = URL(string: sourceURL)?.host ?? "Paper"
        article.doi = doi.map(Self.normalizeDOI)
        // Mirrors setSourcePaywallStatus(isPaywalled: true) for a paper.
        article.state = .error
        article.statusFlag = .paywall
        article.isPaywalled = true
        try store.saveSource(article)

        let metadataSummary = [
            article.author.map { "author: \($0)" },
            article.journal.map { "journal: \($0)" },
            article.publishedYear.map { "year: \($0)" },
            article.doi.map { "doi: \($0)" },
        ].compactMap { $0 }.joined(separator: ", ")
        return "Added paper '\(article.title)' (id: \(article.id)) and marked it paywalled: \(evidence). "
            + "Its bibliography is saved (\(metadataSummary)) but no PDF or full text yet. "
            + "To finish it: call attach_pdf_to_paper with a local PDF path (or a PDF URL you can reach), "
            + "drop the PDF into the ForeverLM/Papers folder in iCloud Drive, "
            + "or call recheck_paywalled_papers later to look for a legitimate free copy."
    }

    /// An author handed to a source-writing tool must be a name
    /// (`SourceAuthor`). The field would drop markup or a web address on its
    /// own; a tool says so instead, so the caller learns the value was not kept.
    static func requirePlausibleSourceAuthor(_ author: String?) throws {
        guard let author, !SourceAuthor.isPlausible(author) else { return }
        let shown = author.count > 80 ? "\(author.prefix(80))…" : author
        throw MCPError.invalidInput(
            "author must be a name or a list of names — not markup, a web address or a paragraph (got \"\(shown)\")."
        )
    }

    /// - Parameter connectorLabel: non-nil only for ingest-scoped plugin
    ///   clients. Stamps `discovery_origin = plugin` plus the label, both
    ///   derived from the caller's authenticated OAuth client — never from tool
    ///   arguments — so provenance can't be spoofed and bulk removal stays
    ///   trustworthy.
    /// - Parameter occurredAt: when a meeting happened, as ISO 8601. Meetings
    ///   are dated by it — the Meetings tab, the Schedule, and a source search's
    ///   `occurred:` all read `dateAdded`, which for a meeting means the meeting
    ///   date, not the push date. Without it a plugin's whole history lands
    ///   on the day it first ran (126 Read AI meetings dated 2026-09-02).
    /// - Parameter videoChannel: a YouTube video's uploader, looked up before
    ///   the store gate was taken (`addSourceNamingVideoChannel`).
    func addSource(url: String, title: String, sourceType: String, content: String?, parentGroup: String?, author: String?, occurredAt: String? = nil, connectorLabel: String? = nil, videoChannel: String? = nil) throws -> String {
        try Self.requirePlausibleSourceAuthor(author)
        let store = try knowledgeStore()
        let type = Self.filedSourceType(claimed: sourceType, url: url)
        let occurredAtDate = try Self.parsedOccurredAt(occurredAt, sourceType: type)
        guard type != .paper else {
            throw MCPError.invalidInput(
                "add_source cannot ingest papers. Use import_paper_from_url or import_local_pdf_as_paper so the mandatory Paper Metadata LLM call runs on the paper."
            )
        }
        // A page ForeverLM links is never a source (product owner, 2026-09-09: "codex
        // sites should always obviously be ingested as a 'site' not as an
        // article"). The app's routes all send such a link to `linkPage`; the
        // tool contract has a tool for it, so the caller is sent there rather
        // than redirected — add_source answers with a line, link_page with the
        // entry, and a plugin's batch reports the refusal per item.
        if let kind = StudioViewModel.linkedPageKind(forSourceURL: url) {
            throw MCPError.invalidInput(
                "add_source does not import a \(kind.label). ForeverLM links that kind of page instead of scraping it — a Codex site answers an anonymous fetch with its sign-in page, so an article made from it would hold nothing. Call link_page with the same url; the entry lands in \(kind.section.title)."
            )
        }
        // Convoke results are not sources (product owner, 2026-09-12): a plugin
        // pushed two under platform.convoke.bio/mcp addresses, and the batch
        // route reports this per item the way it reports a linked page.
        if let refusal = StudioViewModel.sourceRefusal(forSourceURL: url) {
            throw MCPError.invalidInput("add_source does not import this url. \(refusal)")
        }
        // A playlist is a course, never a source (2026-09-26). Asked to ingest
        // one, an assistant had only this tool and built the course by hand:
        // the playlist page became a course source, the course took its title
        // as its ID, and lessons went in as `course` material instead of
        // videos. The app's own importer does it right, and
        // import_youtube_playlist runs it, so the caller is sent there.
        if YouTubePlaylistService.isPlaylistURL(url) {
            throw MCPError.invalidInput(
                "add_source does not import a YouTube playlist: a playlist is a course, not a source. Call import_youtube_playlist with this url — it creates the course (or fills the one that already names this playlist), puts each video on its own numbered lecture and fetches the transcripts."
            )
        }
        // A Teachable lecture page is the course's sidebar and a player; saved
        // as a source it would hold the outline, not the talk. The importer
        // reads the page as the learner and transcribes the audio.
        if TeachableCourseService.isLectureURL(url), (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPError.invalidInput(
                "add_source does not import a Teachable lecture: its page holds the course outline, not the talk. Call import_teachable_course with this url — it files the course's video lectures and transcribes their audio."
            )
        }
        // A Gemini Notebook address is a whole notebook; fetched as a page it
        // is Google's sign-in. The importer reads it as the learner and files
        // its sources, chats and notes as a Notebook.
        if GeminiNotebookService.isNotebookURL(url) {
            throw MCPError.invalidInput(
                "add_source does not import a Gemini Notebook: its address is a whole notebook, not a page. Call import_gemini_notebook with this url — it files the notebook as a Notebook with its sources, its chats and its notes."
            )
        }
        // Course material reaches a list only through a course, so a course
        // source with no course is a source nothing can show. Ask for the course
        // instead of adding an invisible row.
        if type == .course, (parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            throw MCPError.invalidInput(
                "A course source needs parent_group set to the course it belongs to — the Courses tab lists courses, so course material outside one is never shown. Call list_courses or create_course first, or add this as a different source_type."
            )
        }
        // The same for a chapter: the Books tab lists books, and a book source
        // with no group is a loose row above them carrying a raw file path where
        // a cover and a book title belong. Nothing files it afterwards either —
        // `saveSource` writes a `group_members` row only when the article names a
        // group, and only the book importer ever names one. This is what happened
        // to "Radical Life Extension": thirteen of its fourteen chapters were
        // re-added here with no parent_group, and the fourteenth stayed in the
        // book only because it already existed and was skipped.
        if type == .book, (parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            throw MCPError.invalidInput(
                "A book source needs parent_group set to the book it belongs to — the Books tab lists books, so a chapter outside one is a loose row with no cover and no book to open it from. Pass the book's display title (created when it does not exist yet) or its book_id from list_sources, or add this as a different source_type."
            )
        }
        let normalizedURL = URLNormalizer.normalize(url)
        if let existing = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url) {
            if existing.status == .archived, store.isSourceDismissed(url: url) {
                return Self.removedSourceRefusal(title: title)
            }
            return "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))"
        }
        // A URL the learner removed is a tombstone, not a gap. `dismissed_sources`
        // outlives the archived row — deleting a meeting series takes its
        // sessions' rows with it — and every in-app discovery route already
        // refuses it (`insertSourceIfNew`, the feed mirrors, sync). This route
        // did not: it asked only whether the row still existed, so a plugin
        // or the recordings mailbox could file a recording the learner had
        // removed that afternoon. Only an explicit re-add in the app lifts the
        // tombstone (`prepareExplicitSourceReAdd`); a caller here never does.
        if store.isSourceDismissed(url: url) {
            return Self.removedSourceRefusal(title: title)
        }
        if type == .meeting, let parentGroup,
           let refusal = try Self.removedMeetingSeriesRefusal(parentGroup: parentGroup, sessionTitle: title, store: store) {
            return refusal
        }
        let domain = Self.newSourceDomain(url: url, sourceType: type, parentGroup: parentGroup, videoChannel: videoChannel)
        var resolvedParentGroup: String?
        var resolvedParentGroupTitle: String?

        let pluginOrigin = type == .meeting
            ? connectorLabel.flatMap(MeetingProvider.forPluginLabel)?.pluginDiscoveryOrigin
            : nil
        var article = StudioArticle(
            url: url,
            title: title,
            sourceType: type,
            discoveryOrigin: pluginOrigin ?? (connectorLabel != nil ? .plugin : .manual),
            author: author
        )
        article.connectorLabel = connectorLabel
        article.normalizedURL = normalizedURL
        article.domain = domain
        // A podcast's text is its transcript, which the app fetches once it
        // has found the episode on Apple Podcasts (`findAndOfferPodcast`, run
        // for a queued web podcast with no text). What a caller holds for a
        // web address is the episode's page, its show notes; kept, the row
        // would read as ready and never be looked up.
        let looksUpEpisode = type == .podcast && url.lowercased().hasPrefix("http")
        let droppedPodcastText = looksUpEpisode
            && !(content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let content, !looksUpEpisode {
            // Text an assistant copied off a page keeps the page's soft
            // hyphens; they are no part of the words.
            let text = content.removingSoftHyphens()
            article.content = text
            article.wordCount = text.split(separator: " ").count
            article.state = .ready
        }
        if let occurredAtDate {
            article.dateAdded = occurredAtDate
        }

        if let parentGroup {
            let groupID = try resolveGroupID(input: parentGroup, preferredType: sourceType, store: store)
            resolvedParentGroup = groupID
            resolvedParentGroupTitle = parentGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            article.parentGroup = groupID
        }

        try store.saveSource(article)
        // A meeting whose transcript arrived with it is a stored transcript:
        // the funnel folds it into the sitting it continues and reads the
        // series' action items, as for a transcript the app fetched itself.
        if type == .meeting, article.state == .ready {
            MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id)
        }

        let groupText: String
        if let groupID = resolvedParentGroup {
            let title = resolvedParentGroupTitle?.isEmpty == false ? resolvedParentGroupTitle! : groupID
            let label = (sourceType == "book" || sourceType == "course" || sourceType == "meeting") ? sourceType : "group"
            groupText = ", \(label): \(title), group_id: \(groupID)"
        } else {
            groupText = ""
        }
        let occurredText = occurredAtDate.map { ", occurred_at: \(Self.iso8601String($0))" } ?? ""
        var message = "Added source '\(title)' (id: \(article.id), type: \(type.rawValue)\(groupText)\(occurredText))"
        if article.content == nil, ZoomRecordingService.isZoomRecordingURL(url) {
            message += ". This is a Zoom recording link — call fetch_video_transcript with this id to fetch its transcript."
        }
        if looksUpEpisode {
            let claimedType = StudioSourceType(rawValue: sourceType)
            if claimedType != .podcast {
                message += ". Filed as a podcast, not \(sourceType): \(URL(string: url)?.host ?? url) hosts podcast episodes"
            }
            message += ". ForeverLM reads a podcast from its transcript: it looks this episode up on Apple Podcasts, and the learner confirms the match in the app — or call find_podcast_match, then resolve_podcast_match with this id"
            if droppedPodcastText {
                message += ". The content passed was not kept: an episode's page holds its show notes, not what was said"
            }
            message += "."
        }
        return message
    }

    /// The type a new source is filed under: the caller's, except that a link
    /// on a podcast host is an episode whatever the caller called it, as the
    /// app files a pasted one (`addArticle`). On 2026-10-02, with no `podcast`
    /// in the tool's list, an assistant filed a podcasts.apple.com episode as
    /// a video: it sat in the YouTube tab with no picture, the episode page's
    /// text standing in for a transcript.
    static func filedSourceType(claimed: String, url: String) -> StudioSourceType {
        if StudioViewModel.isPodcastHostURL(url) { return .podcast }
        return StudioSourceType(rawValue: claimed) ?? .manual
    }

    /// `add_source` as the tool runs it. A YouTube video's uploader is looked
    /// up first, holding nothing, and the save then holds the store gate alone
    /// (`MCPToolRegistry.selfGatedToolNames`), so no other call waits on
    /// YouTube. Until 2026-09-28 the row took the URL's host for its channel
    /// and waited for the app's backfill to name it: two Peter Attia episodes
    /// were listed under "www.youtube.com", out of reach of a `show` search.
    ///
    /// `notebookID` is add_source's notebook_id: checked before anything is
    /// added, and the source the save produced or matched then joins that
    /// Notebook (`fileImportedSources`), said after the save's own answer.
    func addSourceNamingVideoChannel(
        url: String,
        title: String,
        sourceType: String,
        content: String?,
        parentGroup: String?,
        author: String?,
        occurredAt: String?,
        connectorLabel: String?,
        notebookID: String? = nil
    ) async throws -> String {
        let notebook: LearningGoalRecord? = Self.nilIfBlank(notebookID ?? "") == nil
            ? nil
            : try await withStoreGate(.shared) { try notebookForImport(notebookID: notebookID) }
        let channel = await Self.uploaderChannelForNewVideo(url: url, sourceType: sourceType)
        let (message, sourceID) = try await withStoreGate(.exclusive) { () -> (String, String?) in
            let message = try addSource(
                url: url,
                title: title,
                sourceType: sourceType,
                content: content,
                parentGroup: parentGroup,
                author: author,
                occurredAt: occurredAt,
                connectorLabel: connectorLabel,
                videoChannel: channel
            )
            guard let notebook, !message.hasPrefix(Self.removedByLearnerPrefix) else { return (message, nil) }
            return (message, importedLibrarySourceID(url: url, notebook: notebook, store: try knowledgeStore()))
        }
        guard let notebook else { return message }
        let filing = await fileImportedSources(sourceID.map { [$0] } ?? [], in: notebook)
        return message + "\n" + filing.answer(for: notebook, batch: false)
    }

    /// The uploader of a YouTube video about to be added. Nil for anything
    /// that is not a YouTube video, and when YouTube names no uploader; the
    /// save then keeps the URL's host until the app's channel backfill
    /// (`backfillMissingVideoChannels`) names it.
    static func uploaderChannelForNewVideo(url: String, sourceType: String) async -> String? {
        guard StudioSourceType(rawValue: sourceType) == .video,
              YouTubeTranscriptService.isYouTubeURL(url),
              !YouTubePlaylistService.isPlaylistURL(url),
              let videoId = YouTubeTranscriptService.extractVideoId(from: url),
              let metadata = await YouTubeTranscriptService.shared.fetchVideoMetadata(videoId: videoId) else {
            return nil
        }
        return YouTubeTranscriptService.channelName(of: metadata)
    }

    /// What a new source stores as `domain`. For a video that is its
    /// uploader's channel — the name list_shows reports, filter_sources' `show`
    /// matches and the Videos sidebar prints under the title — whenever it is
    /// known; otherwise the URL's host stands in.
    static func newSourceDomain(url: String, sourceType: StudioSourceType, parentGroup: String?, videoChannel: String?) -> String {
        if sourceType == .video,
           let channel = videoChannel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channel.isEmpty {
            return channel
        }
        if let host = URL(string: url)?.host { return host }
        return parentGroup ?? "Local"
    }

    /// `occurred_at` parsed for a source of `sourceType`. Only meetings carry a
    /// date of their own; for every other type `dateAdded` means what it says,
    /// so a value there is a plugin bug worth reporting rather than a field
    /// to quietly drop. Unparseable input is refused for the same reason: a
    /// meeting silently dated by its push would look exactly like the bug this
    /// field exists to fix.
    static func parsedOccurredAt(_ raw: String?, sourceType: StudioSourceType) throws -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard sourceType == .meeting else {
            throw MCPError.invalidInput(
                "occurred_at is only accepted for source_type \"meeting\"; other sources are dated by when they were added."
            )
        }
        guard let date = parseFlexibleTimestamp(raw) else {
            throw MCPError.invalidInput(
                "occurred_at must be an ISO 8601 timestamp such as 2026-09-02T16:55:00Z (got \"\(raw)\")."
            )
        }
        return date
    }

    static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Every refusal that stands in for a learner's removal starts with this,
    /// so `add_sources` can count it apart from an addition and a caller can
    /// tell "the learner took this out" from "this failed".
    static let removedByLearnerPrefix = "Not added:"

    /// The answer for a URL the learner removed. A plain result, not a tool
    /// error: the recordings mailbox files a notice once and marks it done on
    /// any answer, and an assistant reads it as the decision it is rather than
    /// as something to retry.
    static func removedSourceRefusal(title: String) -> String {
        "\(removedByLearnerPrefix) '\(title)' was removed by the learner, so it stays removed. Only re-adding it from the app brings it back."
    }

    /// Whether filing a meeting under `parentGroup` would bring back a series
    /// the learner removed, and the answer to give if so.
    ///
    /// `removeMeetingGroup` records the series' stable identity and title
    /// (`StudioViewModel.recordMeetingGroupRemoval`), hides the row while the
    /// Undo notice is up, and then deletes it. `resolveGroupID` knew none of
    /// that: an unknown title made a fresh group, and a known one was matched
    /// by title even while hidden — so a Read AI push or a recordings-mailbox
    /// notice could stand a removed series straight back up. The tombstone
    /// speaks only for a series that is gone or hidden: one the learner has
    /// visibly back (an explicit import lifts the tombstone, but an older
    /// title-only entry can outlive that) is a series to file into.
    static func removedMeetingSeriesRefusal(
        parentGroup: String,
        sessionTitle: String,
        store: KnowledgeStore
    ) throws -> String? {
        let trimmed = parentGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let removed: Bool
        let seriesTitle: String
        if let existingID = try store.resolvedMeetingGroupID(matching: trimmed) {
            let metadata = try store.loadMeetingGroups()[existingID] ?? MeetingMetadata(title: trimmed)
            guard metadata.isHidden else { return nil }
            removed = StudioViewModel.isMeetingGroupRemoved(groupID: existingID, metadata: metadata)
            seriesTitle = metadata.title ?? trimmed
        } else {
            removed = StudioViewModel.isMeetingGroupTitleRemoved(trimmed)
                || StudioViewModel.loadRemovedMeetingGroupIdentities().contains("group:\(trimmed)")
            seriesTitle = trimmed
        }
        guard removed else { return nil }
        return "\(removedByLearnerPrefix) the meeting series '\(seriesTitle)' was removed by the learner, so it stays removed and '\(sessionTitle)' was not filed into it. Only importing the series again from the app brings it back."
    }

    /// Batch form of `addSource` for plugin feeds: one metered tool call, one
    /// result line per item, and nothing silently dropped — every item is
    /// accounted for as added, updated, already existing, or failed. Items that
    /// already exist are only touched when that item sets `update_existing`,
    /// and updates go through `updateSourceContent`, which enforces plugin
    /// ownership for ingest-scoped callers. A meeting's `occurred_at` and
    /// `parent_group` travel with the update too, so a plugin that first
    /// pushed its history without them can re-push once and have every meeting
    /// take its real date and its series.
    func addSources(_ items: [[String: Any]], connectorLabel: String?) throws -> String {
        try addSourcesBatch(items, connectorLabel: connectorLabel).text
    }

    /// `add_sources`' answer, and the address of every item the library holds
    /// afterwards — added, updated or already there — so the batch can be
    /// filed in a Notebook (notebook_id) by the addresses it deduplicated on.
    struct SourceBatchResult {
        let text: String
        let heldURLs: [String]
    }

    func addSourcesBatch(_ items: [[String: Any]], connectorLabel: String?) throws -> SourceBatchResult {
        guard !items.isEmpty else {
            return SourceBatchResult(text: "Error: sources must be a non-empty array of {url, title, source_type, ...} items.", heldURLs: [])
        }
        guard items.count <= MCPToolRegistry.maxBatchSourceItems else {
            return SourceBatchResult(
                text: "Error: add_sources accepts at most \(MCPToolRegistry.maxBatchSourceItems) items per call (got \(items.count)). Split the batch into smaller calls.",
                heldURLs: []
            )
        }

        var lines: [String] = []
        var heldURLs: [String] = []
        var added = 0, updated = 0, alreadyExisting = 0, failed = 0, removedByLearner = 0
        let store = try knowledgeStore()

        for (index, item) in items.enumerated() {
            let url = (item["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !title.isEmpty else {
                failed += 1
                lines.append("[\(index)] Error: url and title are required")
                continue
            }

            do {
                let normalizedURL = URLNormalizer.normalize(url)
                let existing = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url)
                if let existing {
                    if item["update_existing"] as? Bool == true {
                        let message = try updateSourceContent(
                            sourceID: existing.id,
                            url: nil,
                            content: item["content"] as? String,
                            title: item["title"] as? String,
                            author: item["author"] as? String,
                            parentGroup: item["parent_group"] as? String,
                            occurredAt: item["occurred_at"] as? String,
                            restrictToPluginLabel: connectorLabel
                        )
                        if message.hasPrefix("Error:") {
                            failed += 1
                        } else {
                            updated += 1
                            heldURLs.append(url)
                        }
                        lines.append("[\(index)] \(message)")
                    } else {
                        alreadyExisting += 1
                        heldURLs.append(url)
                        lines.append("[\(index)] Already exists (id: \(existing.id), status: \(existing.status.rawValue))")
                    }
                } else {
                    let message = try addSource(
                        url: url,
                        title: title,
                        sourceType: item["source_type"] as? String ?? "article",
                        content: item["content"] as? String,
                        parentGroup: item["parent_group"] as? String,
                        author: item["author"] as? String,
                        occurredAt: item["occurred_at"] as? String,
                        connectorLabel: connectorLabel
                    )
                    if message.hasPrefix(Self.removedByLearnerPrefix) {
                        removedByLearner += 1
                    } else {
                        added += 1
                        heldURLs.append(url)
                    }
                    lines.append("[\(index)] \(message)")
                }
            } catch {
                failed += 1
                lines.append("[\(index)] Error: \(error.localizedDescription)")
            }
        }

        let prefix = failed == items.count ? "Error: every item failed. " : ""
        let removedText = removedByLearner > 0 ? ", \(removedByLearner) removed by the learner" : ""
        let summary = "\(prefix)Batch complete: \(added) added, \(updated) updated, \(alreadyExisting) already existed\(removedText), \(failed) failed (of \(items.count))."
        return SourceBatchResult(text: ([summary] + lines).joined(separator: "\n"), heldURLs: heldURLs)
    }

    /// Replace an existing source's stored text (and optionally title/author),
    /// matched by ID or canonical URL. `restrictToPluginLabel` is non-nil for
    /// ingest-scoped callers and confines them to sources stamped with their own
    /// label — an ingest client must not be able to overwrite the user's own
    /// sources, another plugin's, or anything else it didn't add.
    ///
    /// `parentGroup` and `occurredAt` apply to meetings only: the series the
    /// meeting belongs to (resolved by id or title, created when new, exactly as
    /// `addSource` does) and when it happened. Both exist so a re-push can
    /// correct a meeting that was first pushed without them; for other types
    /// the group is left alone and a date is refused.
    func updateSourceContent(
        sourceID: String?,
        url: String?,
        content: String?,
        title: String?,
        author: String?,
        parentGroup: String? = nil,
        occurredAt: String? = nil,
        restrictToPluginLabel: String?
    ) throws -> String {
        try Self.requirePlausibleSourceAuthor(author)
        let store = try knowledgeStore()

        var resolvedID: String?
        if let sourceID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
            resolvedID = sourceID
        } else if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            let normalizedURL = URLNormalizer.normalize(url)
            resolvedID = (store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url))?.id
            if resolvedID == nil {
                return "Error: no source found for url \(url). Add it first with add_source."
            }
        }
        guard let id = resolvedID else {
            return "Error: provide source_id or url of an existing source."
        }
        guard var article = try store.loadSourceForSync(id) else {
            throw MCPError.notFound("Source not found: \(id)")
        }

        if let restrictToPluginLabel {
            guard article.connectorLabel == restrictToPluginLabel else {
                let owner = article.connectorLabel.map { "plugin '\($0)'" } ?? "the app or another origin"
                return "Error: this ingest connection ('\(restrictToPluginLabel)') can only update sources it added itself. '\(article.title)' was added by \(owner)."
            }
        }

        var changedFields: [String] = []
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Soft hyphens are no part of the words (`removingSoftHyphens()`).
            let text = content.removingSoftHyphens()
            article.content = text
            article.wordCount = text.split(separator: " ").count
            if article.sourceType == .paper {
                article.prepareForPaperMetadataExtraction()
            } else {
                article.state = .ready
            }
            changedFields.append("content")
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != article.title {
            article.title = title
            changedFields.append("title")
        }
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty, author != article.author {
            article.author = author
            changedFields.append("author")
        }
        if let occurredAtDate = try Self.parsedOccurredAt(occurredAt, sourceType: article.sourceType),
           occurredAtDate != article.dateAdded {
            article.dateAdded = occurredAtDate
            changedFields.append("occurred_at")
        }
        if article.sourceType == .meeting,
           let parentGroup = parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !parentGroup.isEmpty {
            // Moving a session into a removed series would recreate the series.
            if let refusal = try Self.removedMeetingSeriesRefusal(
                parentGroup: parentGroup, sessionTitle: article.title, store: store
            ) {
                return "Error: \(refusal)"
            }
            let groupID = try resolveGroupID(input: parentGroup, preferredType: "meeting", store: store)
            // Compare through the merge aliases: a meeting already filed under a
            // series the learner merged into this one is where it belongs.
            let currentGroupID = try article.parentGroup.map { try store.canonicalMeetingGroupID($0) }
            if currentGroupID != groupID {
                article.parentGroup = groupID
                changedFields.append("parent_group")
            }
        }
        guard !changedFields.isEmpty else {
            return "Error: nothing to update — provide content, title, or author."
        }

        try store.saveSource(article)
        let wordText = changedFields.contains("content") ? " (\(article.wordCount ?? 0) words)" : ""
        return "Updated \(changedFields.joined(separator: ", ")) of '\(article.title)'\(wordText)"
    }

    /// Remove every active source a user-built plugin added, by its stamped
    /// label. Full-scope connections only (the registry never exposes this to
    /// ingest clients). Each source goes through the same path as
    /// `remove_source` — URL dismissed so discovery won't re-add it, then
    /// archived (undownloaded papers are deleted) — so a revoked plugin's
    /// content disappears the same way a manual Studio removal would.
    func removePluginSources(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: connector_label is required."
        }
        let store = try knowledgeStore()
        let ids = try store.activeSourceIDs(withPluginLabel: trimmed)
        guard !ids.isEmpty else {
            return "No active sources found for plugin '\(trimmed)'."
        }

        var lines: [String] = []
        var removed = 0, failed = 0
        for id in ids {
            do {
                lines.append(try removeSource(id))
                removed += 1
            } catch {
                failed += 1
                lines.append("Error removing \(id): \(error.localizedDescription)")
            }
        }
        let summary = "Removed \(removed) of \(ids.count) sources added by plugin '\(trimmed)'\(failed > 0 ? " (\(failed) failed)" : "")."
        return ([summary] + lines).joined(separator: "\n")
    }

    func deleteSource(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.deleteSource(sourceID)
        return "Deleted source '\(article.title)'"
    }

    func removeSource(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }

        try store.dismissSource(url: article.url, title: article.title)
        if let webURL = article.podcastWebPageURL {
            try store.dismissSource(url: webURL, title: article.title)
        }

        if article.sourceType == .paper && article.resolvedPDFPath == nil {
            try store.deleteSource(sourceID)
            return "Removed and deleted undownloaded paper '\(article.title)'"
        }

        try store.archiveSource(sourceID)
        return "Removed and archived source '\(article.title)'"
    }

    func archiveSource(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.archiveSource(sourceID)
        return "Archived source '\(article.title)'"
    }

    /// Restore an archived source to active. This is also the inverse of
    /// `removeSource`: an explicit restore clears the URL dismissal tombstones that
    /// removal created, or the next sync would immediately archive the source again.
    /// When a local file's text was wiped on archive, rebuild the cached content from
    /// that file so the source is immediately readable and reviewable. Schedule
    /// assignments are not restored (archiving dropped them); re-add via Schedule tools.
    func unarchiveSourceRestoringContent(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        // The work is the store's, shared with the app's own Unarchive action
        // on a planner block's source row; only the sentence is composed here.
        guard let outcome = try store.unarchiveSourceRestoringContent(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        let note = outcome.rebuiltContent
            ? " and rebuilt its content from the local file"
            : " (no local file content to rebuild; re-fetch if the source needs text)"
        return "Unarchived source '\(outcome.title)'\(note)"
    }

    // MARK: - Article reading view

    private func readingViewArticle(_ rawSourceID: String) throws -> StudioArticle {
        let store = try knowledgeStore()
        let sourceID = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.invalidInput("Source not found: \(sourceID)")
        }
        guard article.sourceType == .article else {
            throw MCPError.invalidInput("A reading view is only for web articles; '\(article.title)' is a \(article.sourceType.rawValue).")
        }
        return article
    }

    private func readingViewPayload(_ article: StudioArticle, view: ArticleReadingView?) throws -> String {
        guard let view else {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "has_reading_view": false,
            ] as [String: Any])
        }
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "has_reading_view": true,
            "instruction": view.instruction,
            "shown_in_reader": view.isShown,
            "hidden_piece_count": view.removals.count,
            "examples": Array(view.removals.prefix(20)),
        ] as [String: Any])
    }

    func makeArticleReadingView(sourceID: String, instruction: String) async throws -> String {
        let article = try readingViewArticle(sourceID)
        let view = try await ArticleReadingViewService.make(
            sourceID: article.id,
            title: article.title,
            instruction: instruction
        )
        if view.removals.isEmpty {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "saved": false,
                "message": "The model found nothing in '\(article.title)' that matches \"\(view.instruction)\", so nothing was changed.",
            ] as [String: Any])
        }
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "saved": true,
            "instruction": view.instruction,
            "hidden_piece_count": view.removals.count,
            "examples": Array(view.removals.prefix(20)),
            "message": "The Reader now hides these pieces of '\(article.title)'. Open the article in the Reader to see it; set_article_reading_view_shown switches back to the original.",
        ] as [String: Any])
    }

    func getArticleReadingView(sourceID: String) throws -> String {
        let article = try readingViewArticle(sourceID)
        return try readingViewPayload(article, view: ArticleReadingViewStore.load(sourceID: article.id))
    }

    func setArticleReadingViewShown(sourceID: String, shown: Bool) throws -> String {
        let article = try readingViewArticle(sourceID)
        guard let view = ArticleReadingViewStore.setShown(shown, sourceID: article.id) else {
            throw MCPError.invalidInput("'\(article.title)' has no reading view yet. Make one with make_article_reading_view.")
        }
        return try readingViewPayload(article, view: view)
    }

    func clearArticleReadingView(sourceID: String) throws -> String {
        let article = try readingViewArticle(sourceID)
        let had = ArticleReadingViewStore.load(sourceID: article.id) != nil
        ArticleReadingViewStore.remove(sourceID: article.id)
        return had
            ? "Removed the reading view of '\(article.title)'; the Reader shows the original."
            : "'\(article.title)' had no reading view."
    }

    func setSourceHidden(sourceID: String, hidden: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.setSourceHidden(sourceID, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") source '\(article.title)'"
    }

    func setSourcePaywallStatus(sourceID: String, isPaywalled: Bool) throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard [.article, .paper, .unclassified].contains(article.sourceType) else {
            throw MCPError.invalidInput("Paywall status is only available for article, paper, or unclassified sources.")
        }

        article.isPaywalled = isPaywalled
        if isPaywalled {
            article.state = article.sourceType == .paper ? .error : .ready
            article.statusFlag = .paywall
        } else if article.statusFlag == .paywall {
            article.errorMessage = nil
            // Metadata attestation alone does not make a paper readable — see the
            // twin in StudioViewModel.clearPaywalledStatus. Require the durable
            // text too, so clearing a paywall marker cannot promote a paper the
            // reader, chat and CarPlay will all fail to open.
            article.state = article.sourceType == .paper
                && !(article.hasPaperIngestionAttestation
                     && ((try? store.hasReadableSourceContent(sourceID)) ?? false))
                ? .queued
                : .ready
        }
        try store.saveSource(article)
        return "\(isPaywalled ? "Marked" : "Cleared paywall status for") source '\(article.title)'\(isPaywalled ? " as paywalled" : "")"
    }

    func setPodcastEpisodeHidden(sourceID: String, hidden: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .podcast else {
            throw MCPError.invalidInput("set_podcast_episode_hidden requires a podcast source.")
        }
        try store.setPodcastEpisodeHidden(sourceID, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") podcast episode '\(article.title)'"
    }

    func setPodcastShowHidden(showName: String, hidden: Bool) throws -> String {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("show_name is required.")
        }
        try knowledgeStore().setPodcastShowHidden(trimmed, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") podcast show '\(trimmed)'"
    }

    /// Block or unblock a show's future imports — the same preference the
    /// Studio menu's "Never Import <show>" writes, so the two cannot disagree
    /// about what is blocked or about how show names are matched.
    func setPodcastShowImportBlocked(showName: String, blocked: Bool) throws -> String {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("show_name is required.")
        }
        guard SourceDiscovery.setPodcastShowBlocked(trimmed, blocked: blocked) else {
            return blocked
                ? "Podcast show '\(trimmed)' was already blocked from importing."
                : "Podcast show '\(trimmed)' was not blocked."
        }
        return blocked
            ? "Blocked podcast show '\(trimmed)': its episodes will no longer be imported. Episodes already in the library are unchanged."
            : "Importing podcast show '\(trimmed)' again."
    }

    func setPodcastEpisodeVisibleOverride(sourceID: String, visible: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .podcast else {
            throw MCPError.invalidInput("set_podcast_episode_visible_override requires a podcast source.")
        }
        try store.setPodcastEpisodeVisibleOverride(sourceID, visible: visible)
        return "\(visible ? "Force-showing" : "Removed force-show override for") podcast episode '\(article.title)'"
    }

    func setYouTubeChannelHidden(channelName: String, hidden: Bool) throws -> String {
        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("channel_name is required.")
        }
        try knowledgeStore().setYouTubeChannelHidden(trimmed, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") YouTube channel '\(trimmed)'"
    }

    func setYouTubeVideoVisibleOverride(sourceID: String, visible: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .video, article.isYouTubeURL else {
            throw MCPError.invalidInput("set_youtube_video_visible_override requires a YouTube video source.")
        }
        try store.setYouTubeVideoVisibleOverride(sourceID, visible: visible)
        return "\(visible ? "Force-showing" : "Removed force-show override for") YouTube video '\(article.title)'"
    }

    func attachTextFileToSource(sourceID: String, filePath: String) throws -> String {
        let sourceURL = try validateClientProvidedPath(filePath)
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard [.article, .manual, .unclassified].contains(article.sourceType) else {
            throw MCPError.invalidInput("attach_text_file_to_source is available for article, manual, and unclassified sources.")
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MCPError.invalidInput("File not found: \(filePath)")
        }
        let data = try Data(contentsOf: sourceURL)
        guard let raw = Self.decodeTextData(data),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidInput("Could not read text from \(filePath)")
        }

        let ext = sourceURL.pathExtension.lowercased()
        let text = (ext == "html" || ext == "htm" || ext == "xhtml")
            ? EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            : raw.removingSoftHyphens().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MCPError.invalidInput("Could not extract non-empty text from \(filePath)")
        }

        let destination = try copyFileIntoContentRoot(
            sourceURL,
            folder: "Articles",
            baseName: article.title,
            fallbackExtension: ext.isEmpty ? "txt" : ext
        )
        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        article.errorMessage = nil
        article.isPaywalled = false
        try store.saveSource(article)
        return "Attached text file to '\(article.title)' (path: \(article.localFilePath ?? destination.path))"
    }

    func attachPDFToPaper(sourceID: String, filePath: String?, pdfURL: String?) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("attach_pdf_to_paper requires a paper source.")
        }

        let trimmedPDFURL = Self.nilIfBlank(pdfURL ?? "")
        let trimmedFilePath = Self.nilIfBlank(filePath ?? "")
        let input = trimmedPDFURL ?? trimmedFilePath
        guard let input else {
            throw MCPError.invalidInput("attach_pdf_to_paper requires file_path or pdf_url.")
        }

        let destination: URL
        let attachedFrom: String
        if let remoteURL = Self.httpURLString(input) {
            let pdfDownloadURL = try await resolvedPDFURLForAttachment(remoteURL)
            let doi = Self.nilIfBlank(article.doi ?? "")
                ?? PaperService.extractDOI(from: article.url)
                ?? PaperService.extractDOI(from: pdfDownloadURL)
            let papersDir = sourceContentRoot.appendingPathComponent("Papers", isDirectory: true)
            try FileManager.default.createDirectory(at: papersDir, withIntermediateDirectories: true)
            destination = uniquePaperDestination(in: papersDir, doi: doi, url: pdfDownloadURL)
            try await downloadPaperPDFForImport(from: pdfDownloadURL, sourceURL: article.url, to: destination)
            attachedFrom = pdfDownloadURL
        } else {
            let sourceURL = try validateClientProvidedPath(input)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw MCPError.invalidInput("File not found: \(input)")
            }
            guard SourceService.canOpenPDF(at: sourceURL.path) else {
                throw MCPError.invalidInput("Could not read PDF: \(input)")
            }
            let doi = Self.nilIfBlank(article.doi ?? "") ?? PaperService.extractDOI(from: article.url)
            let baseName = doi.map { Self.safeFilenameBase($0.replacingOccurrences(of: "/", with: "-")) }
                ?? Self.safeFilenameBase(article.title)
            destination = try copyFileIntoContentRoot(
                sourceURL,
                folder: "Papers",
                baseName: baseName,
                fallbackExtension: "pdf"
            )
            attachedFrom = sourceURL.path
        }

        return try await finishAttachingPDF(article: &article, sourceID: sourceID, destination: destination, attachedFrom: attachedFrom, namesID: false)
    }

    /// attach_supplementary_pdf: the journal's supplementary file joined after
    /// the paper's own pages (`PaperSupplementPDF`). No model runs: the paper
    /// keeps its metadata, and its figure index is read again from the joined
    /// file the next time anything asks for a figure.
    func attachSupplementaryPDF(sourceID: String, filePath: String?, pdfURL: String?) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("attach_supplementary_pdf requires a paper source.")
        }
        guard let stored = Self.nilIfBlank(article.localFilePath ?? ""),
              FileManager.default.fileExists(atPath: StorageService.absoluteSourcePath(stored)) else {
            throw MCPError.invalidInput("'\(article.title)' has no PDF of its own on this Mac yet. Attach the article first with attach_pdf_to_paper.")
        }
        guard let input = Self.nilIfBlank(pdfURL ?? "") ?? Self.nilIfBlank(filePath ?? "") else {
            throw MCPError.invalidInput("attach_supplementary_pdf requires file_path or pdf_url.")
        }

        let supplementPath: String
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        if let remoteURL = Self.httpURLString(input) {
            let download = FileManager.default.temporaryDirectory
                .appendingPathComponent("supplement-\(UUID().uuidString).pdf")
            staged = download
            try await downloadPaperPDFForImport(from: remoteURL, sourceURL: article.url, to: download, paperHasPDF: true)
            supplementPath = download.path
        } else {
            let sourceURL = try validateClientProvidedPath(input)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw MCPError.invalidInput("File not found: \(input)")
            }
            supplementPath = sourceURL.path
        }

        let outcome: PaperSupplementPDF.Outcome
        do {
            outcome = try PaperSupplementPDF.append(
                supplementAt: supplementPath,
                toPaperAt: StorageService.absoluteSourcePath(stored)
            )
        } catch let failure as PaperSupplementPDF.Failure {
            throw MCPError.invalidInput(failure.localizedDescription)
        }
        let destination = URL(fileURLWithPath: outcome.path)
        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(outcome.path)
        // A paper that keeps its text keeps the supplement's too.
        if article.content != nil,
           let text = try? SourceService.shared.extractTextFromPDF(at: outcome.path),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            article.content = text
            article.wordCount = text.split(separator: " ").count
        }
        try store.saveSource(article)
        let firstAdded = outcome.articlePageCount + 1
        let lastAdded = outcome.articlePageCount + outcome.addedPageCount
        return "Joined \(outcome.addedPageCount) supplementary pages to '\(article.title)' as pages \(firstAdded)–\(lastAdded), after its \(outcome.articlePageCount) article pages (path: \(article.localFilePath ?? outcome.path)). "
            + "Call show_source_image with this source_id to list its figures, supplementary ones included."
    }

    /// Whether a PDF that arrives for `article` should be attached to it rather
    /// than refused as a duplicate: a paper the library lists but cannot read —
    /// paywalled, or with no PDF on disk — is not really there yet.
    ///
    /// Decided against the disk, not `resolvedPDFPath`: on the main thread that
    /// property answers from a cache that is empty for a row nobody has drawn
    /// yet, which would read a paper with its PDF as one without.
    static func existingPaperTakesArrivingPDF(_ article: StudioArticle) -> Bool {
        guard article.sourceType == .paper else { return false }
        for candidate in [article.localFilePath, article.url].compactMap({ $0 }) {
            let absolute = StorageService.absoluteSourcePath(candidate)
            if absolute.hasPrefix("/"),
               absolute.lowercased().hasSuffix(".pdf"),
               FileManager.default.fileExists(atPath: absolute) {
                return false
            }
        }
        return true
    }

    /// A PDF that arrives for a paper the library already lists — the same DOI
    /// in a file posted to Slack, a download of a paywalled paper's open copy —
    /// completes that paper when it has none of its own, instead of being
    /// answered "already exists" and dropped. Returns nil when the existing
    /// paper already has a readable PDF, in which case the duplicate answer
    /// stands. The staged file is copied, never moved; callers clean up theirs.
    func adoptPDFForExistingPaper(id: String, stagedPDF: URL, attachedFrom: String) async throws -> String? {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(id), Self.existingPaperTakesArrivingPDF(article) else { return nil }
        let doi = Self.nilIfBlank(article.doi ?? "")
            ?? PaperService.extractDOI(from: article.url)
            ?? Self.extractDOIFromPDF(at: stagedPDF.path)
        let baseName = doi.map { Self.safeFilenameBase($0.replacingOccurrences(of: "/", with: "-")) }
            ?? Self.safeFilenameBase(article.title)
        let destination = try copyFileIntoContentRoot(stagedPDF, folder: "Papers", baseName: baseName, fallbackExtension: "pdf")
        return try await finishAttachingPDF(article: &article, sourceID: id, destination: destination, attachedFrom: attachedFrom, namesID: true)
    }

    /// The half of attach_pdf_to_paper after the file is in the Papers folder:
    /// read it, extract text and the required metadata, clear the paywall
    /// state, and save. `namesID` is false for attach_pdf_to_paper, whose
    /// caller passed the id (Prompts.hiddenIDs), and true where a paper import
    /// adopted the PDF: that answer keeps the paper imports' "(id: …" shape.
    private func finishAttachingPDF(article: inout StudioArticle, sourceID: String, destination: URL, attachedFrom: String, namesID: Bool) async throws -> String {
        let store = try knowledgeStore()
        guard SourceService.canOpenPDF(at: destination.path),
              let document = PDFDocument(url: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw MCPError.invalidInput("Could not read PDF: \(attachedFrom)")
        }

        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        let firstPageText = document.page(at: 0)?.string ?? ""
        let text: String
        do {
            text = try SourceService.shared.extractTextFromPDF(at: destination.path)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceError.pdfReadFailed
            }
        } catch {
            // Keep the attached file and an explicit retryable error in the
            // library. Discarding the path here made the failed operation look
            // as if the learner had never selected a PDF at all.
            article.content = nil
            article.wordCount = nil
            article.state = .error
            article.errorMessage = "Attached PDF has no readable paper text."
            try store.saveSource(article)
            throw MCPError.invalidInput("Attached PDF has no readable paper text: \(attachedFrom)")
        }

        article.content = text
        article.wordCount = article.content?.split(separator: " ").count
        article.prepareForPaperMetadataExtraction()
        article.isPaywalled = false
        if article.doi == nil {
            article.doi = PaperService.extractDOI(from: article.url)
                ?? Self.extractDOIFromPDF(at: destination.path)
                ?? Self.extractDOIFromText(firstPageText)
        }
        let metadataStatus: String
        do {
            metadataStatus = try await extractRequiredPaperMetadataWithAI(
                article: &article,
                firstPageText: firstPageText
            )
        } catch {
            // Keep the attachment as an explicit failed/pending paper so the
            // operation cannot look successful and can be retried in place.
            try? store.saveSource(article)
            throw error
        }
        try store.saveSource(article)
        let marks = importDocumentMarks(sourceID: sourceID, pdfPath: destination.path)
        let idText = namesID ? "id: \(sourceID), " : ""
        return "Attached PDF to '\(article.title)' (\(idText)path: \(article.localFilePath ?? destination.path), \(article.wordCount ?? 0) words; \(metadataStatus))\(marks)"
    }

    /// Human-readable paywall evidence when a paper-PDF download failure indicates
    /// the paper sits behind a paywall, or nil when the failure looks transient
    /// (network error, 404, unreadable file) and the paper should stay in the
    /// needs-attention pool for a future retry. Every paywall-shaped error here is
    /// only reached after the open-access fallbacks (PMC, Unpaywall, mirror hosts)
    /// have also failed.
    static func paperPaywallEvidence(for error: Error) -> String? {
        if let unavailable = error as? PaperPDFUnavailableError {
            return "no open-access PDF found for \(unavailable.sourceURL) (direct link, PMC, and Unpaywall all came up empty)"
        }
        // Another paper's file is no PDF of this one.
        if let mismatch = error as? PaperPDFIdentityMismatchError {
            return mismatch.evidence
        }
        // A `PDFFetchRefusal` carries the host's own answer; its
        // classification decides, and its sentence is the evidence.
        let refusal = error as? PDFFetchRefusal
        switch SourceError.classifying(error) {
        case .accessDenied?:
            return refusal?.message ?? "publisher denied access (HTTP 403)"
        case .httpError(let code)? where code == 401 || code == 402:
            return refusal?.message ?? "publisher requires login or payment (HTTP \(code))"
        case .fetchFailed?:
            return refusal?.message ?? "publisher served a web page instead of the PDF"
        default:
            return nil
        }
    }

    /// Paywall evidence that also names each file turned away as another
    /// paper, so the learner is told why a PDF that was found was not used.
    static func paperPaywallEvidence(_ evidence: String, rejecting rejected: [PaperPDFIdentityMismatchError]) -> String {
        ([evidence] + rejected.map(\.evidence)).joined(separator: "; ")
    }

    /// Bulk-resolve PDFs for every paper that still needs one — the MCP equivalent of
    /// the Studio "Try Papers Needing Attention" button. Selects papers with no local
    /// PDF, an http(s) landing URL, and no paywall marker, then runs the same
    /// resolve → open-access fallback → download → extract → persist pipeline used by
    /// import_paper_from_url. Papers whose failure is paywall-shaped (access denied,
    /// login/payment required, HTML served instead of a PDF, or no open-access copy
    /// anywhere) are automatically marked paywalled so they leave the retry pool;
    /// transient failures are left untouched and reported with source IDs. No failure
    /// is ever masked with a fabricated PDF.
    ///
    /// Processes at most `limit` papers per call (default 25) so a single request stays
    /// within HTTP timeouts; call again to continue draining the backlog.
    ///
    /// The store gate is held per paper, not for the batch
    /// (`MCPToolRegistry.selfGatedToolNames`): a paper's import rewrites its whole row
    /// with what the metadata model returned, so it holds the gate alone for that one
    /// paper, and calls that arrive meanwhile run between papers.
    func downloadPapersNeedingAttention(sourceIDs: [String]?, limit: Int?) async throws -> String {
        let allSources = try await withStoreGate(.shared) {
            try knowledgeStore().loadActiveSources()
        }

        // Storage-degraded guard, mirroring the visible attention list: when many
        // recorded PDFs fail to stat at once (iCloud Drive rebuilding its local
        // replica after an OS upgrade, KB folder not synced yet), those papers are
        // NOT missing their PDFs and re-downloading them from publishers is the
        // wrong remedy. They are excluded even when explicitly requested by ID.
        let unavailableIDs = StudioViewModel.unavailableRecordedPaperPDFIDs(in: allSources)
        let unavailableNote = unavailableIDs.isEmpty ? "" :
            "\n\nNote: \(unavailableIDs.count) papers have a recorded PDF whose file isn't currently available on this Mac (usually iCloud Drive still downloading). They were excluded from this pass instead of being re-downloaded from publishers."

        func needsAttention(_ a: StudioArticle) -> Bool {
            a.sourceType == .paper
                && a.resolvedPDFPath == nil
                && !unavailableIDs.contains(a.id)
                && !a.hasPaywallMarker
                && a.url.hasPrefix("http")
                && a.state != .fetching
        }

        let allCandidates = allSources.filter(needsAttention)
        var targets = allCandidates
        if let sourceIDs, !sourceIDs.isEmpty {
            let wanted = Set(sourceIDs)
            targets = allCandidates.filter { wanted.contains($0.id) }
        }

        let totalPending = targets.count
        guard totalPending > 0 else { return "No papers need PDF attention." + unavailableNote }

        let batchSize = max(1, min(limit ?? 25, 100))
        let batch = Array(targets.prefix(batchSize))

        var downloaded: [String] = []
        var markedPaywalled: [String] = []
        var failed: [String] = []
        for article in batch {
            do {
                let detail = try await withStoreGate(.exclusive) {
                    try await downloadPaperPDFForExistingSource(
                        article.id,
                        preferOpenAccessAlternative: true
                    )
                }
                downloaded.append("✓ \(Self.sourceLink(title: article.title, id: article.id)) — \(detail)")
            } catch {
                if let evidence = Self.paperPaywallEvidence(for: error) {
                    do {
                        _ = try await withStoreGate(.exclusive) {
                            try setSourcePaywallStatus(sourceID: article.id, isPaywalled: true)
                        }
                        markedPaywalled.append("⊘ \(Self.sourceLink(title: article.title, id: article.id)) — \(evidence)")
                    } catch {
                        failed.append("✗ \(Self.sourceLink(title: article.title, id: article.id)): detected paywall (\(evidence)) but could not mark it: \(error.localizedDescription)")
                    }
                } else {
                    failed.append("✗ \(Self.sourceLink(title: article.title, id: article.id)): \(error.localizedDescription)")
                }
            }
        }

        let remaining = totalPending - batch.count
        var report = "Paper download pass: \(downloaded.count) downloaded, \(markedPaywalled.count) marked paywalled, \(failed.count) failed (of \(batch.count) attempted; \(remaining) still pending)."
        if !downloaded.isEmpty { report += "\n\nDownloaded:\n" + downloaded.joined(separator: "\n") }
        if !markedPaywalled.isEmpty {
            report += "\n\nMarked paywalled (excluded from future passes; attach a PDF with attach_pdf_to_paper or clear with set_source_paywall_status):\n"
                + markedPaywalled.joined(separator: "\n")
        }
        if !failed.isEmpty { report += "\n\nFailed (left unchanged; if you know a source is paywalled, mark it with set_source_paywall_status):\n" + failed.joined(separator: "\n") }
        if remaining > 0 { report += "\n\nCall download_papers_needing_attention again to continue (\(remaining) remaining)." }
        report += unavailableNote
        return report
    }

    /// Revisit acknowledged paywalls without first clearing their marker. A paper
    /// leaves this set only when the normal import pipeline has attached a readable
    /// PDF and persisted the cleared state. This is deliberately separate from
    /// `downloadPapersNeedingAttention`: acknowledged paywalls should not be retried
    /// during ordinary background maintenance, but an assistant must be able to
    /// perform the same explicit recheck as the Studio UI.
    ///
    /// Holds the store gate per paper, as `downloadPapersNeedingAttention` does.
    func recheckPaywalledPapers(sourceIDs: [String]?, limit: Int?) async throws -> String {
        let store = try knowledgeStore()
        let allSources = try await withStoreGate(.shared) {
            try store.loadActiveSources()
        }
        let unavailableIDs = StudioViewModel.unavailableRecordedPaperPDFIDs(in: allSources)
        let unavailableNote = unavailableIDs.isEmpty ? "" :
            "\n\nNote: \(unavailableIDs.count) papers have a recorded PDF whose file isn't currently available on this Mac. They were excluded while iCloud finishes making those files available."

        func needsRecheck(_ article: StudioArticle) -> Bool {
            article.sourceType == .paper
                && article.resolvedPDFPath == nil
                && !unavailableIDs.contains(article.id)
                && article.hasPaywallMarker
                && article.url.hasPrefix("http")
                && article.state != .fetching
        }

        var targets = allSources.filter(needsRecheck)
        if let sourceIDs, !sourceIDs.isEmpty {
            let wanted = Set(sourceIDs)
            targets = targets.filter { wanted.contains($0.id) }
        }

        let totalPending = targets.count
        guard totalPending > 0 else { return "No paywalled papers need rechecking." + unavailableNote }

        let batchSize = max(1, min(limit ?? 25, 100))
        let batch = Array(targets.prefix(batchSize))
        var recovered: [String] = []
        var failed: [String] = []

        for article in batch {
            do {
                let detail = try await withStoreGate(.exclusive) {
                    try await downloadPaperPDFForExistingSource(article.id)
                }
                recovered.append("✓ \(Self.sourceLink(title: article.title, id: article.id)) — \(detail)")
            } catch {
                // Metadata extraction can fail loudly after the readable PDF has
                // already been attached and persisted. That is still a successful
                // paywall recovery, with an explicit metadata warning.
                let reloaded = try? await withStoreGate(.shared) { try store.loadSourceForSync(article.id) }
                if let updated = reloaded,
                   updated.resolvedPDFPath != nil,
                   !updated.hasPaywallMarker {
                    recovered.append("✓ \(Self.sourceLink(title: article.title, id: article.id)) — PDF recovered; metadata processing failed: \(error.localizedDescription)")
                } else {
                    failed.append("✗ \(Self.sourceLink(title: article.title, id: article.id)): \(error.localizedDescription)")
                }
            }
        }

        let remaining = totalPending - batch.count
        var report = "Paywall recheck: \(recovered.count) recovered, \(failed.count) not recovered (of \(batch.count) attempted; \(remaining) still pending)."
        if !recovered.isEmpty { report += "\n\nRecovered:\n" + recovered.joined(separator: "\n") }
        if !failed.isEmpty { report += "\n\nStill marked paywalled:\n" + failed.joined(separator: "\n") }
        if remaining > 0 { report += "\n\nCall recheck_paywalled_papers again to continue (\(remaining) remaining)." }
        report += unavailableNote
        return report
    }

    /// Resolve and download the PDF for an existing paper source from its landing URL,
    /// falling back to an open-access alternative, then extract text + AI metadata and
    /// persist (clearing error/paywall state). Throws on any failure so the caller can
    /// classify it (paywall-shaped vs transient) and report it rather than masking it.
    func downloadPaperPDFForExistingSource(
        _ sourceID: String,
        preferOpenAccessAlternative: Bool = false
    ) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.invalidInput("Source not found: \(sourceID)")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("download_papers_needing_attention requires a paper source.")
        }
        let landingURL = article.url
        let storedDOI = article.doi
        let doi = Self.nilIfBlank(storedDOI ?? "")
            ?? PaperService.extractDOI(from: landingURL)

        let papersDir = sourceContentRoot.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papersDir, withIntermediateDirectories: true)
        let destination = uniquePaperDestination(in: papersDir, doi: doi, url: landingURL)

        var alternatives: [PaperService.OpenAccessAlternativeResult] = []
        if preferOpenAccessAlternative {
            alternatives = await PaperService.findOpenAccessAlternatives(
                url: landingURL,
                title: article.title,
                doi: storedDOI
            )
        }

        // The paper this row already is: every file below is held to it, as
        // an import holds its files to the request (`PaperPDFIdentity`).
        var identity = PaperPDFIdentity.Request(
            doi: doi,
            titles: [article.title].filter { !titleNeedsReplacement($0, sourceURL: landingURL) }
        )

        func attemptDownload(from sourceURL: String) async throws -> String {
            let pageMetadata: PaperService.PaperPageMetadata?
            if sourceURL == landingURL {
                pageMetadata = await PaperService.fetchPaperPageMetadata(at: sourceURL)
            } else {
                pageMetadata = nil
            }
            let pdfURL = try await resolvedPaperPDFURL(
                sourceURL: sourceURL,
                pageMetadata: pageMetadata,
                doi: storedDOI
            )
            let paperHasPDF = article.resolvedPDFPath != nil
            let downloadedURL: String
            do {
                try await downloadPaperPDFForImport(
                    from: pdfURL, sourceURL: sourceURL, to: destination, paperHasPDF: paperHasPDF
                )
                downloadedURL = pdfURL
            } catch {
                guard sourceURL.lowercased().contains("doi.org/10.1101/"), pdfURL.contains("biorxiv.org") else {
                    throw error
                }
                let medrxivURL = pdfURL.replacingOccurrences(of: "biorxiv.org", with: "medrxiv.org")
                try await downloadPaperPDFForImport(
                    from: medrxivURL, sourceURL: sourceURL, to: destination, paperHasPDF: paperHasPDF
                )
                downloadedURL = medrxivURL
            }
            // Another paper's file throws, so the caller removes it and goes
            // on to its next candidate.
            if case .mismatch(let reason) = await PaperPDFIdentity.verdict(forPDFAt: destination, request: &identity) {
                let rejection = PaperPDFIdentityMismatchError(pdfURL: downloadedURL, reason: reason)
                recordPaperPDFIdentityMismatch(rejection, requestedURL: landingURL, request: identity, sourceID: sourceID)
                throw rejection
            }
            return downloadedURL
        }

        var candidates: [String] = []
        candidates.append(contentsOf: alternatives.map(\.replacementURL))
        candidates.append(landingURL)

        var downloadedPDFURL: String?
        var lastDownloadError: Error?
        for sourceURL in candidates {
            do {
                downloadedPDFURL = try await attemptDownload(from: sourceURL)
                break
            } catch {
                lastDownloadError = error
                try? FileManager.default.removeItem(at: destination)
            }
        }

        if downloadedPDFURL == nil, alternatives.isEmpty {
            alternatives = await PaperService.findOpenAccessAlternatives(
                url: landingURL,
                title: article.title,
                doi: storedDOI
            )
            for alternative in alternatives {
                do {
                    downloadedPDFURL = try await attemptDownload(from: alternative.replacementURL)
                    break
                } catch {
                    lastDownloadError = error
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }

        guard downloadedPDFURL != nil else {
            throw lastDownloadError ?? PaperPDFUnavailableError(sourceURL: landingURL)
        }

        guard SourceService.canOpenPDF(at: destination.path), let document = PDFDocument(url: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw MCPError.invalidInput("Downloaded file is not a readable PDF")
        }

        let firstPageText = document.page(at: 0)?.string ?? ""
        let text = try SourceService.shared.extractTextFromPDF(at: destination.path)

        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        article.content = text
        article.wordCount = article.content?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.prepareForPaperMetadataExtraction()
        article.isPaywalled = false
        if article.doi == nil {
            article.doi = doi
                ?? PaperService.extractDOI(from: landingURL)
                ?? Self.extractDOIFromPDF(at: destination.path)
                ?? Self.extractDOIFromText(firstPageText)
        }
        let metadataStatus: String
        do {
            metadataStatus = try await extractRequiredPaperMetadataWithAI(
                article: &article,
                firstPageText: firstPageText
            )
        } catch {
            try? store.saveSource(article)
            throw error
        }
        try store.saveSource(article)
        return "\(article.wordCount ?? 0) words; \(metadataStatus)"
    }

    // MARK: - Group management (MCP/UI parity)

    /// Rename a course, video-playlist, or meeting group by updating its metadata title.
    /// `groupKey` is the course name, the video-playlist id, or the meeting group name.
    func renameGroup(groupType: String, groupKey: String, newTitle: String) throws -> String {
        let store = try knowledgeStore()
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = groupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPError.invalidInput("new_title is required.") }
        guard !key.isEmpty else { throw MCPError.invalidInput("group_key is required.") }

        switch groupType {
        case "course":
            guard var meta = try store.loadCourseGroups()[key] else { throw MCPError.notFound("Course group not found: \(key)") }
            meta.title = title
            try store.saveCourseGroup(name: key, metadata: meta)
        case "video_playlist":
            guard var meta = try store.loadVideoPlaylistGroups()[key] else { throw MCPError.notFound("Video playlist not found: \(key)") }
            meta.title = title
            try store.saveVideoPlaylistGroup(id: key, metadata: meta)
        case "meeting":
            guard var meta = try store.loadMeetingGroups()[key] else { throw MCPError.notFound("Meeting group not found: \(key)") }
            meta.title = title
            try store.saveMeetingGroup(name: key, metadata: meta)
        default:
            throw MCPError.invalidInput("group_type must be one of: course, video_playlist, meeting.")
        }
        return "Renamed \(groupType) '\(key)' to '\(title)'."
    }

    /// Hide or unhide a course, video-playlist, or meeting group.
    func setGroupHidden(groupType: String, groupKey: String, hidden: Bool) throws -> String {
        let store = try knowledgeStore()
        let key = groupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MCPError.invalidInput("group_key is required.") }

        switch groupType {
        case "course":
            guard var meta = try store.loadCourseGroups()[key] else { throw MCPError.notFound("Course group not found: \(key)") }
            meta.isHidden = hidden
            try store.saveCourseGroup(name: key, metadata: meta)
        case "video_playlist":
            guard var meta = try store.loadVideoPlaylistGroups()[key] else { throw MCPError.notFound("Video playlist not found: \(key)") }
            meta.isHidden = hidden
            try store.saveVideoPlaylistGroup(id: key, metadata: meta)
        case "meeting":
            guard var meta = try store.loadMeetingGroups()[key] else { throw MCPError.notFound("Meeting group not found: \(key)") }
            meta.isHidden = hidden
            try store.saveMeetingGroup(name: key, metadata: meta)
        default:
            throw MCPError.invalidInput("group_type must be one of: course, video_playlist, meeting.")
        }
        return "\(hidden ? "Hid" : "Unhid") \(groupType) '\(key)'."
    }

    // MARK: - review session edits (MCP/UI parity)

    /// Delete a review session (or external session link) by ID.
    func deleteReviewSession(sessionID: String) throws -> String {
        let store = try knowledgeStore()
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("session_id is required.") }
        try store.deleteReviewSession(id)
        return "Deleted review session \(id)."
    }

    /// Replace the set of sources linked to a review session.
    func updateReviewSessionLinkedSources(sessionID: String, sourceIDs: [String]) throws -> String {
        let store = try knowledgeStore()
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("session_id is required.") }
        // A memory review's record is not the whole story: its briefing lists
        // the day's material too, and a reopen restores from it whatever the
        // record lost. Leaving a source out of a memory review therefore
        // records the removal there as well, the way the strip's × does.
        var removedFromReview: [String] = []
        if MemoryReviewSession.isMemorySession(id),
           let existing = try store.loadReviewSessionForSync(id),
           var briefing = try store.loadReviewSessionBriefing(sessionID: id) {
            let kept = Set(sourceIDs)
            removedFromReview = existing.sourceIDs.filter { !kept.contains($0) }
            if !removedFromReview.isEmpty {
                for sourceID in removedFromReview {
                    briefing = MemoryReviewTutoring.briefing(briefing, removingSource: sourceID)
                }
                try store.setReviewSessionBriefing(sessionID: id, briefing: briefing)
            }
        }
        // The junction's foreign key points at `sources`, so an id that is not a
        // source here would fail the whole replace with a bare constraint error.
        // A memory review may also list chats, which are not sources.
        if !MemoryReviewSession.isMemorySession(id) {
            let unknown = try sourceIDs.filter { try store.loadSourceWithoutContent($0) == nil }
            if !unknown.isEmpty {
                throw MCPError.notFound("No source with id \(unknown.joined(separator: ", ")) in this library. Add it first (add_sources, add_notebook_sources), then link it.")
            }
        }
        try store.updateReviewSessionSources(sessionID: id, sourceIDs: sourceIDs)
        followTeamShares { storage in await storage.propagateChatToTeams(sessionID: id) }
        var message = "Updated review session \(id) to \(sourceIDs.count) linked source\(sourceIDs.count == 1 ? "" : "s")."
        if !removedFromReview.isEmpty {
            message += " Removed \(removedFromReview.count) source\(removedFromReview.count == 1 ? "" : "s") from today's memory review; "
                + "the tutor stops asking about them when the review is next opened."
        }
        return message
    }

    /// The sidebar row's Rename, Move to Notebook and Hide, for a chat the
    /// assistant knows only by id.
    func updateReviewSession(
        sessionID: String,
        title: String?,
        notebookID: String?,
        isHidden: Bool? = nil,
        isPinned: Bool? = nil
    ) throws -> String {
        let store = try knowledgeStore()
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("session_id is required.") }
        guard title != nil || notebookID != nil || isHidden != nil || isPinned != nil else {
            throw MCPError.invalidInput("Pass title, notebook_id, is_hidden, is_pinned, or several.")
        }
        if isPinned != nil, MemoryReviewSession.isMemorySession(id) {
            throw MCPError.invalidInput("A day's memory review is Memory's and is never pinned.")
        }
        guard try store.loadReviewSessionForSync(id) != nil else {
            throw MCPError.notFound("Review session not found: \(id). Call get_review_sessions for the current ids.")
        }
        if let title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { throw MCPError.invalidInput("title cannot be empty.") }
            try store.updateReviewSessionTitle(sessionID: id, title: trimmedTitle)
        }
        if let notebookID {
            let trimmedNotebookID = notebookID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNotebookID.isEmpty {
                try store.updateReviewSessionGoal(sessionID: id, goalID: nil)
            } else {
                let goal = try resolveMCPChatHome(notebookID: trimmedNotebookID, store: store)
                try store.updateReviewSessionGoal(sessionID: id, goalID: goal.id)
            }
        }
        // Hiding is the learner's view of the chat, not a record change: the
        // chat is not republished and no team copy follows it; the hide
        // syncs as a record of its own.
        if let isHidden {
            try store.setReviewSessionHidden(id, hidden: isHidden)
        }
        // A pin is the learner's synced preference row (`ChatPins`), written
        // as Pin Chat writes it; the open window reseeds its pins from the
        // rows on the data-change reload.
        var pins = ChatPinRows.read()
        if let isPinned, isPinned != pins.isPinned(id) {
            if isPinned {
                let seconds = pins.newPinValue(at: Date())
                ChatPinRows.write(String(seconds), sessionID: id)
                pins = pins.setting(seconds, for: id)
            } else {
                ChatPinRows.write(nil, sessionID: id)
                pins = pins.setting(nil, for: id)
            }
        }
        guard let updated = try store.loadReviewSessionForSync(id) else {
            throw MCPError.notFound("Review session not found: \(id).")
        }
        if title != nil || notebookID != nil {
            followTeamShares { storage in await storage.propagateChatToTeams(sessionID: id) }
        }
        let hiddenAt = try store.reviewSessionHiddenAt(sessionID: id)
        let placement = updated.goalID == nil
            ? "‘\(updated.topic)’ is in the ungrouped Chats list."
            : "‘\(updated.topic)’ is filed under Notebook \(updated.goalID ?? "")."
        return try jsonString([
            "status": "updated",
            "session_id": id,
            "title": updated.topic,
            "notebook_id": updated.goalID.map { $0 as Any } ?? NSNull(),
            "is_hidden": hiddenAt != nil,
            "hidden_at": hiddenAt.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
            "is_pinned": pins.isPinned(id),
            "message": (hiddenAt == nil
                ? placement
                : placement + " It is hidden from the sidebar; the Hidden fold under Chats lists it.")
                + (pins.isPinned(id) ? " It is pinned: Home's sidebar lists it under Pinned." : ""),
        ] as [String: Any])
    }

    // MARK: - Plugin auto-import preferences (MCP/UI parity)

    /// Toggle automatic import for the YouTube plugin.
    func setPluginAutoImport(plugin: String, enabled: Bool) throws -> String {
        switch plugin {
        case "youtube", "you_tube":
            StudioViewModel.setYouTubeAutoImportEnabled(enabled)
            return "YouTube auto-import \(enabled ? "enabled" : "disabled")."
        default:
            throw MCPError.invalidInput("plugin must be youtube.")
        }
    }

    // MARK: - Course lectures (MCP/UI parity)

    /// Create a numbered lecture inside a course. The number is auto-assigned as the
    /// next available number for that course unless `number` is given.
    func createCourseLecture(courseName: String, title: String?, number: Int?) throws -> String {
        let store = try knowledgeStore()
        let course = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !course.isEmpty else { throw MCPError.invalidInput("course_name is required.") }

        let existing = try store.loadCourseLectures().filter { $0.courseName == course }
        let resolvedNumber = number ?? ((existing.map(\.number).max() ?? 0) + 1)
        let lecture = CourseSession(courseName: course, number: resolvedNumber, title: Self.nilIfBlank(title ?? ""))
        try store.saveCourseLecture(lecture)
        // The new lecture's id rides on its own line (Prompts.hiddenIDs).
        return "Created lecture \(resolvedNumber)\(lecture.title.map { " '\($0)'" } ?? "") in course '\(course)'.\nlecture_id: \(lecture.id)"
    }

    /// Rename a course lecture by ID.
    func renameCourseLecture(lectureID: String, title: String) throws -> String {
        let store = try knowledgeStore()
        let id = lectureID.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("lecture_id is required.") }
        guard !newTitle.isEmpty else { throw MCPError.invalidInput("title is required.") }
        guard var lecture = try store.loadCourseLectures().first(where: { $0.id == id }) else {
            throw MCPError.notFound("Lecture not found: \(id)")
        }
        lecture.title = newTitle
        try store.saveCourseLecture(lecture)
        return "Renamed lecture \(lecture.number) of course '\(lecture.courseName)' to '\(newTitle)'."
    }

    /// Attach a source to a course lecture as a material.
    func addSourceToLecture(lectureID: String, sourceID: String, role: String?) throws -> String {
        let store = try knowledgeStore()
        let lecture = lectureID.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lecture.isEmpty else { throw MCPError.invalidInput("lecture_id is required.") }
        guard !source.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let lectureRecord = try store.loadCourseLectures().first(where: { $0.id == lecture }) else {
            throw MCPError.notFound("Lecture not found: \(lecture)")
        }

        let existingItems = try store.loadCourseLectureItems().filter { $0.lectureId == lecture }
        let nextSort = (existingItems.map(\.sortIndex).max() ?? -1) + 1
        let resolvedRole = role.flatMap { CourseLectureItemRole(rawValue: $0) } ?? .other
        let item = CourseLectureItem(lectureId: lecture, sourceId: source, role: resolvedRole, sortIndex: nextSort)
        try store.saveCourseLectureItem(item)
        let sourceName = (try store.loadSourceForSync(source)).map { "'\($0.title)'" } ?? "the source"
        return "Added \(sourceName) to lecture \(lectureRecord.number) of course '\(lectureRecord.courseName)' (role: \(resolvedRole.rawValue))."
    }

    /// Remove a material from a course lecture by lecture-item ID.
    func removeCourseLectureItem(itemID: String) throws -> String {
        let store = try knowledgeStore()
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("item_id is required.") }
        try store.deleteCourseLectureItem(id)
        return "Removed lecture item \(id)."
    }

    // MARK: - Misc source/group ops (MCP/UI parity)

    /// Change a source's type (e.g. reclassify an article as a paper).
    func moveSourceType(sourceID: String, newType: String) throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = newType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        let valid = ["article", "paper", "podcast", "book", "course", "video", "meeting", "manual", "unclassified"]
        guard valid.contains(type) else {
            throw MCPError.invalidInput("new_type must be one of: \(valid.joined(separator: ", ")).")
        }
        try store.updateSourceType(id, to: type)
        let title = (try store.loadSourceForSync(id))?.title
        return "Changed the type of \(title.map { "'\($0)'" } ?? "the source") to \(type)."
    }

    /// Remove every episode of a podcast show (matched by show name), the same way the
    /// Studio "Remove All from <show>" action does: dismiss + archive each, and
    /// stop importing the show, so playing another episode does not bring it
    /// back. `set_podcast_show_import_blocked` with `false` undoes the block.
    func removeAllFromPodcastShow(showName: String) throws -> String {
        let store = try knowledgeStore()
        let name = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MCPError.invalidInput("show_name is required.") }
        let episodes = try store.loadActiveSources().filter { $0.sourceType == .podcast && $0.domain == name }
        guard !episodes.isEmpty else { return "No episodes found for podcast show '\(name)'." }
        var removed = 0
        for episode in episodes {
            _ = try removeSource(episode.id)
            removed += 1
        }
        SourceDiscovery.setPodcastShowBlocked(name, blocked: true)
        return "Removed \(removed) episode\(removed == 1 ? "" : "s") from podcast show '\(name)', and stopped importing it."
    }

    // MARK: - AI metadata extraction (MCP/UI parity)

    /// Run AI paper-metadata extraction for an existing paper source.
    func extractPaperMetadataForSource(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard var article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("extract_paper_metadata requires a paper source.")
        }

        var firstPageText = ""
        if let path = article.resolvedPDFPath, let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            firstPageText = doc.page(at: 0)?.string ?? ""
        }
        if firstPageText.isEmpty {
            firstPageText = String(((try? store.loadSourceContent(id)) ?? article.content ?? "").prefix(8000))
        }
        article.prepareForPaperMetadataExtraction()
        let status: String
        do {
            status = try await extractRequiredPaperMetadataWithAI(
                article: &article,
                firstPageText: firstPageText
            )
        } catch {
            try? store.saveSource(article)
            throw error
        }
        try store.saveSource(article)
        return "Paper metadata for '\(article.title)': \(status)."
    }

    /// Run AI title/author extraction for an article source.
    func extractArticleMetadataForSource(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard var article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }
        guard let config = KeychainService.resolveConfig(for: .articleMetadata) else {
            return "AI metadata extraction skipped: sign in with Apple in ForeverLM."
        }
        let content = (try? store.loadSourceContent(id)) ?? article.content
        guard let result = await AIService().fixArticleTitle(
            source: AIUsageSource(source: article),
            currentTitle: article.title, url: article.url, content: content, config: config
        ) else {
            return "AI could not extract metadata for '\(article.title)'."
        }
        var changed: [String] = []
        if let t = Self.nilIfBlank(result.title ?? ""), t != article.title { article.title = t; changed.append("title") }
        if let a = Self.nilIfBlank(result.author ?? "") { article.author = a; changed.append("author") }
        if let y = Self.nilIfBlank(result.year ?? "") { article.publishedYear = y; changed.append("year") }
        guard !changed.isEmpty else { return "AI found no new metadata for '\(article.title)'." }
        try store.saveSource(article)
        return "Updated \(changed.joined(separator: ", ")) for '\(article.title)'."
    }

    /// Find duplicate papers via AI and optionally archive the lower-quality copies.
    func findDuplicatePapers(archiveDuplicates: Bool) async throws -> String {
        let store = try knowledgeStore()
        let papers = try store.loadActiveSources().filter { $0.sourceType == .paper }
        guard papers.count >= 2 else { return "Not enough papers to check for duplicates." }
        guard let config = KeychainService.resolveConfig(for: .duplicateDetection) else {
            return "Duplicate detection skipped: sign in with Apple in ForeverLM."
        }
        let input = papers.map { (title: $0.title, url: $0.url) }
        let groups = await AIService().findDuplicatePapers(papers: input, config: config).filter { $0.count > 1 }
        guard !groups.isEmpty else { return "No duplicate papers found." }

        var lines: [String] = []
        var archived = 0
        for group in groups {
            let arts = group.compactMap { papers.indices.contains($0) ? papers[$0] : nil }
            guard arts.count > 1,
                  let keep = arts.max(by: { StudioViewModel.paperStorageScore($0) < StudioViewModel.paperStorageScore($1) })
            else { continue }
            let losers = arts.filter { $0.id != keep.id }
            // Each paper as the link a reply can show (Prompts.hiddenIDs).
            lines.append("• keep \(Self.sourceLink(title: keep.title, id: keep.id)); duplicate\(losers.count == 1 ? "" : "s"): " + losers.map { Self.sourceLink(title: $0.title, id: $0.id) }.joined(separator: ", "))
            if archiveDuplicates {
                for loser in losers { _ = try archiveSource(loser.id); archived += 1 }
            }
        }
        let header = archiveDuplicates
            ? "Found \(groups.count) duplicate group(s); archived \(archived) duplicate(s):"
            : "Found \(groups.count) duplicate group(s) (pass archive_duplicates=true to remove the lower-quality copies):"
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: - Podcast matching (MCP/UI parity)

    /// Search for a podcast episode matching a source and stage the match for
    /// confirmation. The match is handed to the app (`offerPodcastMatch`),
    /// whose source holds it for the reader's Confirm button and for
    /// resolve_podcast_match: it has no column, so a match this tool wrote to
    /// SQLite alone was gone by the time resolve_podcast_match read the row
    /// back, and the row was left asking to confirm nothing (2026-10-02).
    func findPodcastMatch(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }

        let lowerURL = article.url.lowercased()
        let isYouTube = lowerURL.contains("youtube.com") || lowerURL.contains("youtu.be")
        // An Apple Podcasts episode link names its episode (`?i=`), so it is
        // looked up rather than searched for by a title that may not be Apple's.
        let linkNamesEpisode = PodcastFinderService.applePodcastsEpisodeIdentity(fromURL: article.url) != nil
        let match = linkNamesEpisode
            ? await PodcastFinderService.shared.findPodcast(forApplePodcastsURL: article.url)
            : isYouTube
            ? await PodcastFinderService.shared.findPodcast(forYouTubeURL: article.url)
            : await PodcastFinderService.shared.findPodcast(byTitle: article.title)
        guard let match else { return "No podcast match found for '\(article.title)'." }

        let offer = try await Self.offerPodcastMatchInTheApp(match, sourceID: id)
        let found = "\(match.podcastName) — \(match.episodeTitle)"
        switch offer {
        case .awaitingConfirmation, .confirmed:
            let basis = linkNamesEpisode ? " (the episode its Apple Podcasts link names)" : ""
            return "Found podcast match for '\(article.title)': \(found)\(basis). Confirm or reject with resolve_podcast_match."
        case .alreadyInLibrary(let title):
            return "Found \(found), but the library already holds it as \"\(title)\"; '\(article.title)' was marked as that duplicate."
        case .sourceGone:
            throw MCPError.notFound("Source not found in the open library: \(id)")
        }
    }

    @MainActor
    private static func offerPodcastMatchInTheApp(
        _ match: PodcastFinderService.PodcastMatch,
        sourceID: String
    ) async throws -> StudioViewModel.PodcastMatchOffer {
        let studio = try AppModelBridge.requireStudio()
        // Staged for the learner or the assistant to confirm, as the tool says.
        return await studio.offerPodcastMatch(match, for: sourceID, confirmingAtOnce: false)
    }

    /// Confirm or reject the match find_podcast_match staged, on the app's own
    /// source (`confirmPodcastMatch`, `rejectPodcastMatch`), as the reader's
    /// Confirm and Reject buttons do. Confirming fetches the transcript.
    func resolvePodcastMatch(sourceID: String, confirm: Bool) async throws -> String {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        return try await Self.resolvePodcastMatchInTheApp(sourceID: id, confirm: confirm)
    }

    @MainActor
    private static func resolvePodcastMatchInTheApp(sourceID id: String, confirm: Bool) async throws -> String {
        let studio = try AppModelBridge.requireStudio()
        guard let article = studio.articles.first(where: { $0.id == id }) else { throw MCPError.notFound("Source not found: \(id)") }
        // A row left asking to confirm a match nobody holds — a relaunch drops
        // a staged match — can still be rejected back to the queue.
        guard let match = studio.heldPodcastMatch(for: id)?.info else {
            guard !confirm, article.statusFlag == .confirmPodcast else {
                return "No pending podcast match on \(id). Call find_podcast_match first."
            }
            await studio.rejectPodcastMatch(for: id)
            return "No match was held for '\(article.title)'; it is back in the queue, and find_podcast_match looks for its episode again."
        }
        if confirm {
            await studio.confirmPodcastMatch(for: id)
            let confirmed = studio.articles.first(where: { $0.id == id })
            if confirmed?.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return "Confirmed podcast match for '\(match.episodeTitle)', and its transcript is in: get_source_content reads it."
            }
            return "Confirmed podcast match for '\(match.episodeTitle)'. \(confirmed?.errorMessage ?? "Its transcript is being fetched; get_source_content returns it when it is done.")"
        }
        await studio.rejectPodcastMatch(for: id)
        return "Rejected podcast match; '\(article.title)' returned to queued."
    }

    // MARK: - A podcast episode's transcript from YouTube (Reader parity)

    /// The Reader's Find on YouTube: candidates from the episode's own page,
    /// the show's channel and YouTube search, best match first. Nothing is
    /// attached; `import_podcast_youtube_transcript` takes the confirmed one.
    func findPodcastOnYouTube(sourceID: String, alwaysForShow: Bool?) async throws -> String {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        return try jsonString(try await Self.findPodcastOnYouTubeLikeTheReader(sourceID: id, alwaysForShow: alwaysForShow))
    }

    /// The Reader's Use Transcript, for a video named by its address or id.
    func importPodcastYouTubeTranscript(sourceID: String, video: String, replace: Bool) async throws -> String {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let videoID = Self.youtubeVideoID(fromArgument: video) else {
            throw MCPError.invalidInput("video must be a YouTube video address (youtube.com/watch?v=…, youtu.be/…) or its 11-character id.")
        }
        return try jsonString(try await Self.importPodcastYouTubeTranscriptLikeTheReader(
            sourceID: id,
            videoID: videoID,
            replace: replace
        ))
    }

    nonisolated static func youtubeVideoID(fromArgument raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 11,
           value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return value
        }
        return ForeverLMCore.youtubeVideoID(from: value.contains("://") ? value : "https://" + value)
    }

    @MainActor
    private static func requirePodcastEpisode(_ sourceID: String, in studio: StudioViewModel) throws -> StudioArticle {
        guard let episode = studio.articles.first(where: { $0.id == sourceID }) else {
            throw MCPError.invalidInput("No source has id \(sourceID).")
        }
        guard episode.sourceType == .podcast else {
            throw MCPError.invalidInput("'\(episode.title)' is not a podcast episode. A YouTube video's own transcript comes from fetch_video_transcript.")
        }
        return episode
    }

    @MainActor
    private static func findPodcastOnYouTubeLikeTheReader(sourceID: String, alwaysForShow: Bool?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let episode = try requirePodcastEpisode(sourceID, in: studio)
        guard YouTubeService.shared.isSignedIn else {
            throw MCPError.invalidInput("YouTube is not connected. The learner connects it in Plugins › YouTube (open_settings youtube); then call find_podcast_on_youtube again.")
        }
        // The Reader's checkbox names the show by the episode's domain.
        let show = episode.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alwaysForShow {
            guard !show.isEmpty else {
                throw MCPError.invalidInput("'\(episode.title)' names no show, so always_for_show has nothing to set.")
            }
            studio.setYouTubeTranscriptFallback(forPodcastShow: show, enabled: alwaysForShow)
        }
        let candidates = try await studio.findYouTubeTranscriptCandidates(for: sourceID)
        let dates = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "source_id": sourceID,
            "episode": episode.title,
            "show": StudioViewModel.podcastYouTubeShowName(for: episode),
            "has_transcript": episode.state == .ready,
            "candidates": candidates.map { candidate -> [String: Any] in
                var row: [String: Any] = [
                    "video_id": candidate.videoId,
                    "url": candidate.url,
                    "title": candidate.title,
                    "found_by": (candidate.foundBy ?? .search).rawValue,
                ]
                if let channel = candidate.channelTitle { row["channel"] = channel }
                if let published = candidate.publishedAt { row["published_at"] = dates.string(from: published) }
                if let description = candidate.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    row["description"] = String(description.prefix(400))
                }
                return row
            },
            "message": "Ranked best match first; nothing is attached yet. Show the learner the first candidate (its title, channel, date and found_by) and ask whether it is this episode, since an upload is often titled differently. Once they confirm, call import_podcast_youtube_transcript with source_id and the video's url.",
        ]
        if !show.isEmpty {
            payload["always_find_show_on_youtube"] = studio.prefersYouTubeTranscript(forPodcastShow: show)
        }
        return payload
    }

    @MainActor
    private static func importPodcastYouTubeTranscriptLikeTheReader(
        sourceID: String,
        videoID: String,
        replace: Bool
    ) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let episode = try requirePodcastEpisode(sourceID, in: studio)
        if episode.state == .ready, !replace {
            let origin = episode.publicURL.flatMap(ForeverLMCore.youtubeVideoID(from:)).map { "the YouTube video \($0)" }
                ?? "Apple Podcasts"
            throw MCPError.invalidInput("'\(episode.title)' already has its transcript, from \(origin). Pass replace true to replace it with this video's captions.")
        }
        // The formatter is told the video's own title and channel when YouTube
        // can say them; the captions themselves need no connection.
        let described = YouTubeService.shared.isSignedIn
            ? (try? await YouTubeService.shared.videos(ids: [videoID]))?.first
            : nil
        let candidate = described ?? YouTubeVideoSearchResult(
            videoId: videoID,
            title: episode.title,
            channelTitle: nil,
            description: nil,
            publishedAt: nil
        )
        let imported = try await studio.importRawYouTubeTranscript(for: sourceID, from: candidate)
        // Formatting reads the whole transcript with the learner's model,
        // minutes for a long episode, so it runs after the answer as work
        // cancel_ai_work can stop.
        let workID = MCPRunningWork.shared.startBackground(
            tool: "import_podcast_youtube_transcript",
            about: "formatting the YouTube transcript of \(episode.title)"
        ) { @MainActor in
            await studio.formatImportedYouTubeTranscript(imported)
        }
        return [
            "source_id": sourceID,
            "episode": episode.title,
            "video_url": candidate.url,
            "video_title": imported.videoTitle,
            "words": imported.wordCount,
            "work_id": workID,
            "message": "Attached the captions of \(candidate.url) to '\(episode.title)' (\(imported.wordCount) words); the episode is readable now. ForeverLM is formatting them into paragraphs and removing ad reads (work_id \(workID); cancel_ai_work stops it and the raw captions stay).",
        ]
    }

    // MARK: - Content refetch + local import (MCP/UI parity)

    /// The path `refetch_source_content` takes for a source.
    enum RefetchRoute: Equatable {
        /// A Teachable lecture: its text is its audio's transcript, made again.
        case teachableTranscript
        /// Text a Gemini Notebook kept, stored under the notebook's address.
        case geminiNotebookText
        /// A web article: the app's Refresh from Website, with its guards.
        case websiteRefresh
        /// An article-typed source whose address is a PDF file, not a page.
        case pdfAddress
        /// A podcast episode: its transcript fetched again from Apple Podcasts
        /// the way hydration fetches one. Its address is an Apple episode, or
        /// a page that is not a transcript.
        case podcastTranscript
        /// Every other type: its text fetched from its address.
        case plainFetch
    }

    nonisolated static func refetchRoute(for article: StudioArticle) -> RefetchRoute {
        // A Teachable lecture's text is its audio's transcript; the page itself
        // is the course sidebar.
        if TeachableCourseService.isLectureURL(article.url) { return .teachableTranscript }
        // A source a Gemini Notebook held only as text is stored under the
        // notebook's address, and that address fetched is Google's page.
        if GeminiNotebookService.isNotebookURL(article.url) { return .geminiNotebookText }
        switch article.sourceType {
        case .article, .manual, .unclassified:
            return PaperService.isDirectPDFURL(article.url) ? .pdfAddress : .websiteRefresh
        case .podcast:
            return .podcastTranscript
        default:
            return .plainFetch
        }
    }

    /// Re-fetch a source's content and store it. A web article goes through
    /// the app's own Refresh from Website (`refreshArticleFromWebsiteOutcome`),
    /// so an assistant's refetch can no more replace a saved article with a
    /// paywall preview or a bot check than the menu item can.
    func refetchSourceContent(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard var article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }
        let route = Self.refetchRoute(for: article)
        // A podcast's address is an Apple episode, which is not fetched over
        // http(s), or the episode's page, whose text is never its transcript.
        if route == .podcastTranscript {
            return try await Self.refetchPodcastTranscriptLikeTheApp(article)
        }
        guard article.url.hasPrefix("http") else {
            throw MCPError.invalidInput("Source has no http(s) URL to refetch.")
        }
        switch route {
        case .teachableTranscript:
            try await MainActor.run {
                let studio = try AppModelBridge.requireStudio()
                Task { await studio.fetchTeachableTranscript(for: id, forceRefresh: true) }
            }
            return "Transcribing '\(article.title)' again from its audio. This takes a few minutes; get_source_content returns the new transcript when it is done."
        case .geminiNotebookText:
            throw MCPError.invalidInput(
                "'\(article.title)' holds the text a Gemini Notebook kept for it, and its address is the notebook's, so there is no page to fetch it from again."
            )
        case .websiteRefresh:
            return try await Self.refreshArticleLikeTheMenu(article)
        case .pdfAddress:
            throw MCPError.invalidInput(
                "'\(article.title)' is addressed to a PDF file, not a web page, so there is no page to refetch: ForeverLM reads its text from the PDF."
            )
        case .podcastTranscript, .plainFetch:
            break
        }

        let content = try await SourceService.shared.fetchContent(from: article.url)
        article.content = content
        article.wordCount = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if article.sourceType == .paper {
            article.prepareForPaperMetadataExtraction()
            do {
                _ = try await extractRequiredPaperMetadataWithAI(
                    article: &article,
                    firstPageText: String(content.prefix(12_000))
                )
            } catch {
                try? store.saveSource(article)
                throw error
            }
        } else {
            article.state = .ready
            article.errorMessage = nil
        }
        try store.saveSource(article)
        return "Refetched content for '\(article.title)' (\(article.wordCount ?? 0) words)."
    }

    @MainActor
    private static func refreshArticleLikeTheMenu(_ article: StudioArticle) async throws -> String {
        try await refreshArticle(article, in: AppModelBridge.requireStudio())
    }

    @MainActor
    private static func refetchPodcastTranscriptLikeTheApp(_ article: StudioArticle) throws -> String {
        try refetchPodcastTranscript(article, in: AppModelBridge.requireStudio())
    }

    /// `refetch_source_content` for a podcast: the episode's transcript fetched
    /// again from Apple Podcasts by the app's own hydration
    /// (`refetchPodcastTranscript(for:config:)`), never its page's text stored
    /// as a transcript. Formatting a long episode takes minutes, so the fetch
    /// runs after the answer as work `cancel_ai_work` can stop, and the stored
    /// transcript stays until the new one is saved. A transcript taken from
    /// YouTube is fetched again from YouTube, by its own tool.
    @MainActor
    static func refetchPodcastTranscript(
        _ article: StudioArticle,
        in studio: StudioViewModel,
        fetchAppleTranscript: (@Sendable (Int64, String) async -> StudioViewModel.PodcastTranscriptFetchOutcome)? = nil
    ) throws -> String {
        if let videoID = article.publicURL.flatMap(ForeverLMCore.youtubeVideoID(from:)) {
            throw MCPError.invalidInput(
                "'\(article.title)' holds the captions of the YouTube video \(videoID), not Apple's transcript; import_podcast_youtube_transcript with replace true fetches them again."
            )
        }
        if studio.prefersYouTubeTranscript(forPodcastShow: article.domain) {
            throw MCPError.invalidInput(
                "'\(article.domain)' is set to take its transcripts from YouTube; import_podcast_youtube_transcript attaches a video's captions to '\(article.title)'."
            )
        }
        guard studio.podcastHydrationCandidate(for: article.id, userInitiated: true) != nil else {
            throw MCPError.invalidInput(
                "'\(article.title)' has no Apple Podcasts episode ForeverLM can fetch a transcript for."
            )
        }
        let id = article.id
        let config = KeychainService.resolveConfig(for: .transcriptFormatting)
        let workID = MCPRunningWork.shared.startBackground(
            tool: "refetch_source_content",
            about: "fetching the transcript of \(article.title) again from Apple Podcasts"
        ) { @MainActor in
            if let fetchAppleTranscript {
                await studio.refetchPodcastTranscript(for: id, config: config, fetchAppleTranscript: fetchAppleTranscript)
            } else {
                await studio.refetchPodcastTranscript(for: id, config: config)
            }
        }
        return "Fetching the transcript of '\(article.title)' again from Apple Podcasts, as work \(workID). The stored transcript stays until the new one is saved; get_source_content returns the new one when the work finishes, and cancel_ai_work stops it."
    }

    /// The menu item's run for `refetch_source_content`, answered in words an
    /// assistant can pass on. A refresh that could not read the article is an
    /// error; one that read it and kept the saved copy is an answer.
    @MainActor
    static func refreshArticle(
        _ article: StudioArticle,
        in studio: StudioViewModel,
        work: ArticleWebsiteRefreshWork? = nil
    ) async throws -> String {
        let outcome = await studio.refreshArticleFromWebsiteOutcome(article.id, work: work)
        let answer = refetchAnswer(for: outcome, title: article.title)
        if answer.isError { throw MCPError.invalidInput(answer.text) }
        return answer.text
    }

    nonisolated static func refetchAnswer(
        for outcome: ArticleWebsiteRefreshOutcome,
        title: String
    ) -> (text: String, isError: Bool) {
        switch outcome {
        case .refreshed(let savedWords, let words, let archivedPage):
            let count = savedWords > 0 ? "\(savedWords) → \(words) words" : "\(words) words"
            let page = archivedPage ? ", and its page re-archived" : ""
            return ("Refreshed '\(title)' from its website through ForeverLM's browser: \(count)\(page).", false)
        case .unchanged(let words):
            return ("'\(title)' is unchanged: its website returned the saved text word for word (\(words) words), so nothing was written.", false)
        case .keptSavedCopy(let savedWords, let fetchedWords):
            return ("Kept the saved '\(title)' (\(savedWords) words): its website returned less text (\(fetchedWords) words), as a paywall preview or a sign-in wall does, and a refresh never replaces an article with less of it. If the learner has access, they can sign in to the site in ForeverLM's Reader and refetch again.", false)
        case .securityCheck:
            return ("The website showed a bot check instead of '\(title)', so the saved article was kept. The learner can open it in ForeverLM's Reader, pass the check there, and refetch again.", true)
        case .failed(.capture, let reason):
            return ("Couldn't read '\(title)' from its website: \(reason). The saved article was kept.", true)
        case .failed(.cleanup, let reason):
            return ("Source Content Cleanup failed for the refetched '\(title)': \(reason). The saved article was kept.", true)
        case .failed(.savedCopy, let reason):
            return ("Couldn't read the saved '\(title)' to measure the refetch against: \(reason). Nothing was changed.", true)
        case .failed(.save, let reason):
            return ("Couldn't save the refetched '\(title)': \(reason). The saved article and its page were kept.", true)
        case .alreadyRunning:
            return ("ForeverLM is fetching '\(title)' already; get_source_content returns its text once that finishes.", true)
        case .notRefreshable:
            return ("'\(title)' is not a web article ForeverLM can refresh from its website.", true)
        case .notInLibrary:
            return ("'\(title)' is archived or no longer in the library (unarchive_source brings back an archived one), so it was not refreshed.", true)
        }
    }

    /// A PDF on its way in as a new paper, a local file's or one
    /// `import_paper_from_url` downloaded: in the Papers folder and saved
    /// there as a pending paper, its Paper Metadata and Source Content Cleanup
    /// still to run.
    struct StagedLocalPaper {
        var article: StudioArticle
        let destination: URL
        let firstPageText: String
        /// The sentence `importDocumentMarks` returned for the PDF's own marks.
        let marks: String
        /// The address the PDF was downloaded from; nil for a file on the Mac.
        var downloadedFrom: String? = nil

        /// How the import's answers begin.
        var answerLead: String {
            downloadedFrom == nil ? "Imported local PDF as paper" : "Imported paper"
        }
    }

    /// What staging a local or downloaded PDF came to.
    enum LocalPaperStaging {
        /// Nothing left to read: the library already held the paper, or a
        /// paper it held without a PDF took this one.
        case settled(PaperImportOutcome)
        case staged(StagedLocalPaper)
    }

    /// What reads a staged paper: the Paper Metadata model and Source Content
    /// Cleanup (`extractRequiredPaperMetadataWithAI`) unless a test hands in
    /// its own. It fills in the article and answers with its status line.
    typealias StagedPaperReader = (inout StudioArticle, String) async throws -> String

    /// Import a local PDF file from disk as a NEW paper source (copies into the synced
    /// Papers folder, extracts text). For attaching to an existing paper use attach_pdf_to_paper.
    ///
    /// The paper is saved with its PDF before any model reads it, as the app's
    /// own import saves its pending row, and a failure is saved on it rather
    /// than the PDF being taken back. On 2026-10-12 a call whose client timed
    /// out was cancelled during Source Content Cleanup: the metadata step had
    /// saved the paper as pending, and this function then deleted the PDF it
    /// had just copied, leaving a paper reading "PDF needed" with no content.
    func importLocalPDFAsPaperOutcome(
        filePath: String,
        title: String?,
        canonicalURL: String? = nil,
        connectorLabel: String? = nil
    ) async throws -> PaperImportOutcome {
        switch try await stageLocalPDFAsPaper(
            filePath: filePath,
            title: title,
            canonicalURL: canonicalURL,
            connectorLabel: connectorLabel
        ) {
        case .settled(let outcome):
            return outcome
        case .staged(let staged):
            return try await finishStagedLocalPaper(staged)
        }
    }

    /// `importLocalPDFAsPaperOutcome`'s answer alone.
    func importLocalPDFAsPaper(
        filePath: String,
        title: String?,
        canonicalURL: String? = nil,
        connectorLabel: String? = nil
    ) async throws -> String {
        try await importLocalPDFAsPaperOutcome(
            filePath: filePath,
            title: title,
            canonicalURL: canonicalURL,
            connectorLabel: connectorLabel
        ).message
    }

    /// The half of a local PDF's import that needs no model: the file checked,
    /// matched against the papers the library holds (by its provenance URL or
    /// its DOI), copied into the Papers folder and read, then saved as a
    /// pending paper together with its PDF's own highlights. The store is
    /// held only for the match and the save, so the copy and the text
    /// extraction of a long PDF queue nobody.
    func stageLocalPDFAsPaper(
        filePath: String,
        title: String?,
        canonicalURL: String? = nil,
        connectorLabel: String? = nil
    ) async throws -> LocalPaperStaging {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw MCPError.invalidInput("file_path is required.") }
        let fileURL = try validateClientProvidedPath(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MCPError.invalidInput("File not found: \(path)")
        }
        guard SourceService.canOpenPDF(at: fileURL.path) else {
            throw MCPError.invalidInput("Could not read PDF: \(path)")
        }

        let doi = Self.extractDOIFromPDF(at: fileURL.path).map(Self.normalizeDOI)
        if let settled = try await settleLocalPDFForExistingPaper(fileURL: fileURL, canonicalURL: canonicalURL, doi: doi) {
            return .settled(settled)
        }
        let baseName = doi.map { Self.safeFilenameBase($0.replacingOccurrences(of: "/", with: "-")) }
            ?? Self.safeFilenameBase(fileURL.deletingPathExtension().lastPathComponent)
        let destination = try copyFileIntoContentRoot(fileURL, folder: "Papers", baseName: baseName, fallbackExtension: "pdf")

        let pdfText: String
        do {
            pdfText = try SourceService.shared.extractTextFromPDF(at: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let relativePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        let resolvedTitle = Self.nilIfBlank(title ?? "")
            ?? Self.extractPDFTitle(from: destination.path)
            ?? fileURL.deletingPathExtension().lastPathComponent

        var article = StudioArticle(
            url: canonicalURL ?? relativePath,
            title: resolvedTitle,
            sourceType: .paper,
            discoveryOrigin: connectorLabel == nil ? .manual : .plugin,
            localFilePath: relativePath,
            author: StudioArticle.unknownPaperAuthor,
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: StudioArticle.unknownPaperYear
        )
        article.normalizedURL = URLNormalizer.normalize(canonicalURL ?? relativePath)
        article.connectorLabel = connectorLabel
        article.content = pdfText
        article.wordCount = pdfText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.prepareForPaperMetadataExtraction()
        article.isPaywalled = false
        article.doi = doi
        let firstPageText = PDFDocument(url: destination)?.page(at: 0)?.string ?? ""

        let pending = article
        let saved: (settled: PaperImportOutcome?, marks: String)
        do {
            saved = try await withStoreGate(.exclusive) { () async throws -> (settled: PaperImportOutcome?, marks: String) in
                // Another call may have brought in the same paper while this
                // one copied and read the file.
                if let settled = try await settleLocalPDFForExistingPaper(fileURL: fileURL, canonicalURL: canonicalURL, doi: doi) {
                    return (settled, "")
                }
                try knowledgeStore().saveSource(pending)
                return (nil, importDocumentMarks(sourceID: pending.id, pdfPath: destination.path))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if let settled = saved.settled {
            try? FileManager.default.removeItem(at: destination)
            return .settled(settled)
        }
        return .staged(StagedLocalPaper(
            article: article,
            destination: destination,
            firstPageText: firstPageText,
            marks: saved.marks
        ))
    }

    /// The paper the library already holds for a local PDF, by the PDF's
    /// provenance URL or its DOI, and what became of the PDF: a paper listed
    /// without one (paywalled, or its PDF gone) takes it, any other answers
    /// that it already exists. Nil when the paper is new.
    private func settleLocalPDFForExistingPaper(
        fileURL: URL,
        canonicalURL: String?,
        doi: String?
    ) async throws -> PaperImportOutcome? {
        try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            if let canonicalURL {
                let normalized = URLNormalizer.normalize(canonicalURL)
                if let existing = store.sourceExistsByNormalizedURL(normalized) ?? store.sourceExistsByURL(canonicalURL) {
                    if let adopted = try await adoptPDFForExistingPaper(id: existing.id, stagedPDF: fileURL, attachedFrom: fileURL.path) {
                        return PaperImportOutcome(message: adopted, sourceID: existing.id)
                    }
                    return PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                }
            }
            if let doi, let existing = try existingPaperByDOI(doi) {
                // The same paper, listed but unread — paywalled, or its PDF gone —
                // takes this file rather than turning it away.
                if let adopted = try await adoptPDFForExistingPaper(id: existing.id, stagedPDF: fileURL, attachedFrom: fileURL.path) {
                    return PaperImportOutcome(message: adopted, sourceID: existing.id)
                }
                return PaperImportOutcome(message: "Paper already exists for DOI \(doi) (id: \(existing.id)).", sourceID: existing.id)
            }
            return nil
        }
    }

    /// The half of a paper's import that the models do: Paper Metadata
    /// and Source Content Cleanup on the staged paper, then its save. It holds
    /// the store only for its reads and writes, never across a model call.
    /// Whatever stops it, the paper keeps its PDF: a failure is saved on the
    /// paper (Papers that need attention shows it, extract_paper_metadata
    /// retries it), and a stopped read leaves it pending for the app's own
    /// metadata pass to finish.
    func finishStagedLocalPaper(
        _ staged: StagedLocalPaper,
        reader: StagedPaperReader? = nil
    ) async throws -> PaperImportOutcome {
        var article = staged.article
        let metadataStatus: String
        do {
            if let reader {
                metadataStatus = try await reader(&article, staged.firstPageText)
            } else {
                metadataStatus = try await extractRequiredPaperMetadataWithAI(
                    article: &article,
                    firstPageText: staged.firstPageText
                )
            }
        } catch {
            try? await saveFinishedLocalPaper(article)
            if Task.isCancelled || AITransientErrorClassifier.isCancellation(error) { throw error }
            throw MCPError.invalidInput(
                "\(error.localizedDescription) The paper '\(article.title)' stays in the library with its PDF (id: \(article.id)), marked with this failure; extract_paper_metadata retries it."
            )
        }
        try await saveFinishedLocalPaper(article)
        guard staged.downloadedFrom != nil else {
            return PaperImportOutcome(
                message: "\(staged.answerLead) '\(article.title)' (id: \(article.id), \(article.wordCount ?? 0) words; \(metadataStatus)).\(staged.marks)",
                sourceID: article.id
            )
        }
        let metadataSummary = [
            article.author.map { "author: \($0)" },
            article.journal.map { "journal: \($0)" },
            article.publishedYear.map { "year: \($0)" },
            article.doi.map { "doi: \($0)" },
        ].compactMap { $0 }.joined(separator: ", ")
        return PaperImportOutcome(
            message: "\(staged.answerLead) '\(article.title)' (id: \(article.id), PDF: \(article.localFilePath ?? staged.destination.path), \(metadataSummary); \(metadataStatus))\(staged.marks)",
            sourceID: article.id
        )
    }

    /// Saves what the models made of a staged paper, holding the store alone
    /// for the write only. A paper deleted while they read it is not written
    /// back. A team Notebook the paper was filed in while it was read holds a
    /// copy taken from the pending row; once the paper is ready, that copy
    /// takes it again (`refreshTeamCopiesAwaitingText`), as it does after the
    /// app's own save.
    private func saveFinishedLocalPaper(_ article: StudioArticle) async throws {
        try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            guard try store.loadSourceForSync(article.id) != nil else {
                throw MCPError.notFound("The paper '\(article.title)' was deleted while its metadata was read, so nothing was saved to it.")
            }
            try store.saveSource(article)
        }
        await notebookFileStorage.refreshTeamCopiesAwaitingText(of: [article])
    }

    // MARK: - A local paper in the background

    /// At most this many local papers are read by the models at once. An
    /// assistant importing a folder sends its PDFs together; each answers as
    /// soon as it is staged, and the rest wait their turn here rather than
    /// asking the learner's models for a dozen cleanups at once.
    nonisolated static let localPaperReadingLine = MCPWaitingLine(width: 3)

    /// `import_local_pdf_as_paper` and `import_local_file`'s paper route:
    /// the paper is staged at once (in the library with its PDF) and read by
    /// the models in the background, so the call answers in seconds with the
    /// paper's id and the work's id. Before 2026-10-12 the call held the
    /// store alone for the whole read, a minute or more a paper: seven
    /// imports sent together ran one after another, every other call waited
    /// behind them, and the later imports' clients timed out.
    func importLocalPDFAsPaperInBackground(
        filePath: String,
        title: String?,
        tool: String,
        approvedSpendUSD: Double?
    ) async throws -> String {
        // Nothing could read the paper: say so now rather than after the answer.
        guard KeychainService.resolveConfig(for: .paperMetadata) != nil else {
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperMetadata)
                ?? "Paper Metadata AI is not configured. Sign in with Apple in ForeverLM and configure the Paper Metadata task."
            throw MCPError.invalidInput("Paper ingestion failed: \(reason)")
        }
        switch try await stageLocalPDFAsPaper(filePath: filePath, title: title) {
        case .settled(let outcome):
            return outcome.message
        case .staged(let staged):
            return try await readStagedPaperInBackground(staged, tool: tool, approvedSpendUSD: approvedSpendUSD)
        }
    }

    /// Starts the models on a staged paper in the background and answers with
    /// the paper's id and the work's. With no Paper Metadata model set up the
    /// paper is read at once instead, which fails before any model call, saves
    /// that failure on the paper (it keeps its PDF) and throws it, so the
    /// client hears it now rather than from Papers that need attention.
    func readStagedPaperInBackground(
        _ staged: StagedLocalPaper,
        tool: String,
        approvedSpendUSD: Double?
    ) async throws -> String {
        guard KeychainService.resolveConfig(for: .paperMetadata) != nil else {
            return try await finishStagedLocalPaper(staged).message
        }
        let workID = startStagedLocalPaperReading(staged, tool: tool, spendLimitUSD: approvedSpendUSD)
        let article = staged.article
        let pdf = staged.downloadedFrom == nil ? "" : "PDF: \(article.localFilePath ?? staged.destination.path), "
        return """
        \(staged.answerLead) '\(article.title)' (id: \(article.id), \(pdf)\(article.wordCount ?? 0) words): it is in the library with its PDF. The Paper Metadata model and Source Content Cleanup read it in the background, usually within a minute or two.\(staged.marks)
        work_id: \(workID) (list_running_ai_work shows it while it runs; cancel_ai_work stops it, and the paper keeps its PDF for extract_paper_metadata to finish)
        When it is done, the paper carries its title, authors, venue and year, and get_source_content returns its cleaned text. A failure is saved on the paper and shows under Papers that need attention.
        """
    }

    /// Reads a staged paper as background work and returns the work's id.
    /// The open window shows the paper as being read while it waits and
    /// while it is read, which also keeps the app's own metadata pass off it.
    @discardableResult
    func startStagedLocalPaperReading(
        _ staged: StagedLocalPaper,
        tool: String,
        spendLimitUSD: Double?,
        reader: StagedPaperReader? = nil
    ) -> String {
        let sourceID = staged.article.id
        // A store over another database (a test's) has no window.
        let showsInWindow = dbPathOverride == nil
        return MCPRunningWork.shared.startBackground(
            tool: tool,
            about: "paper \(staged.article.title)",
            spendLimitUSD: spendLimitUSD
        ) { @MainActor [self] in
            if showsInWindow { AppModelBridge.studio?.paperMetadataEnrichmentInFlight.insert(sourceID) }
            let callID = MCPRunningWork.currentCallID
            if let callID { MCPRunningWork.shared.setDetail(callID, "Waiting for the papers ahead of it") }
            await Self.localPaperReadingLine.enter()
            if let callID { MCPRunningWork.shared.setDetail(callID, "Reading its metadata and cleaning its text") }
            if !Task.isCancelled {
                do {
                    _ = try await finishStagedLocalPaper(staged, reader: reader)
                } catch {
                    logger.warning("MCP local paper \(sourceID, privacy: .public) was not finished: \(error.localizedDescription, privacy: .public)")
                }
            }
            await Self.localPaperReadingLine.leave()
            if showsInWindow, let studio = AppModelBridge.studio {
                studio.paperMetadataEnrichmentInFlight.remove(sourceID)
                studio.dropPaperProcessingStepIfIdle(sourceID)
            }
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
    }

    // MARK: - Any local file

    /// What `import_local_file` makes of a file.
    enum LocalFileImportKind: String {
        case paper, book, text
    }

    /// A PDF this long is taken for a book when the caller leaves `kind` to the
    /// tool: papers and reviews run to tens of pages, books to hundreds.
    nonisolated static let localPDFBookPageThreshold = 100

    nonisolated static let localTextFileExtensions: Set<String> = ["txt", "md", "markdown"]

    /// The route a file takes, from its extension, its page count (a PDF's)
    /// and the kind the caller asked for ("auto" or none lets the tool choose).
    nonisolated static func localFileImportKind(
        fileExtension rawExtension: String,
        pdfPageCount: Int?,
        requested rawRequested: String?
    ) throws -> LocalFileImportKind {
        let ext = rawExtension.lowercased()
        let requestedWord = (rawRequested ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requested: LocalFileImportKind?
        if requestedWord.isEmpty || requestedWord == "auto" {
            requested = nil
        } else if let kind = LocalFileImportKind(rawValue: requestedWord) {
            requested = kind
        } else {
            throw MCPError.invalidInput("kind must be auto, paper, book or text, not \(rawRequested ?? "").")
        }

        if ext == "pdf" {
            if requested == .text {
                throw MCPError.invalidInput("A PDF imports as a paper or a book, not as text.")
            }
            return requested ?? ((pdfPageCount ?? 0) >= localPDFBookPageThreshold ? .book : .paper)
        }
        if StudioViewModel.supportedBookFileExtensions.contains(ext) {
            guard requested == nil || requested == .book else {
                throw MCPError.invalidInput("A .\(ext) file imports only as a book.")
            }
            return .book
        }
        if localTextFileExtensions.contains(ext) {
            guard requested == nil || requested == .text else {
                throw MCPError.invalidInput("A .\(ext) file imports only as text.")
            }
            return .text
        }
        throw MCPError.invalidInput(
            "import_local_file takes PDF, EPUB, Kindle (azw, azw3, mobi, prc), plain text and Markdown (txt, md, markdown) files, not .\(ext.isEmpty ? "(none)" : ext). An audio or video file has its own tools: transcribe_meeting_recording, import_video_overview."
        )
    }

    /// Import any file on this Mac the way the app's own import of it does: a
    /// PDF as a paper (`import_local_pdf_as_paper`) or a book, an EPUB or
    /// Kindle file as a book through Add Book's importer, a text or Markdown
    /// file as a text source. A book is chapterized in the background, since a
    /// long one outlasts a tool call; the answer names its work.
    func importLocalFile(
        filePath: String,
        kind: String?,
        title: String?,
        approvedSpendUSD: Double?
    ) async throws -> String {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw MCPError.invalidInput("file_path is required.") }
        let fileURL = try validateClientProvidedPath(path)
        var isDirectory: ObjCBool = false
        // An unpacked .epub (Apple Books keeps them as folders) is a book too.
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw MCPError.invalidInput("File not found: \(path)")
        }
        let ext = fileURL.pathExtension.lowercased()
        if isDirectory.boolValue && ext != "epub" {
            throw MCPError.invalidInput("file_path names a folder, not a file: \(path)")
        }
        var pageCount: Int?
        if ext == "pdf" {
            guard let document = PDFDocument(url: fileURL) else {
                throw MCPError.invalidInput("Could not read PDF: \(path)")
            }
            pageCount = document.pageCount
        }

        let requestedWord = (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let leftToTheTool = requestedWord.isEmpty || requestedWord == "auto"
        switch try Self.localFileImportKind(fileExtension: ext, pdfPageCount: pageCount, requested: kind) {
        case .paper:
            return try await importLocalPDFAsPaperInBackground(
                filePath: fileURL.path,
                title: title,
                tool: "import_local_file",
                approvedSpendUSD: approvedSpendUSD
            )
        case .book:
            return try await Self.startLocalBookImport(
                fileURL: fileURL,
                pageCount: pageCount,
                chosenByPageCount: leftToTheTool && ext == "pdf",
                spendLimitUSD: approvedSpendUSD
            )
        case .text:
            return try await Self.importLocalTextFile(fileURL: fileURL)
        }
    }

    /// Puts a book in Add Book's line and answers at once. The import runs as
    /// this call's background work, so its model calls count against the
    /// call's spend ceiling; a failure shows in the app as Add Book's does.
    @MainActor
    private static func startLocalBookImport(
        fileURL: URL,
        pageCount: Int?,
        chosenByPageCount: Bool,
        spendLimitUSD: Double?
    ) throws -> String {
        let studio = try AppModelBridge.requireStudio()
        let name = fileURL.lastPathComponent
        let workID = MCPRunningWork.shared.startBackground(
            tool: "import_local_file",
            about: "book \(name)",
            spendLimitUSD: spendLimitUSD
        ) { @MainActor in
            do {
                try await studio.importBook(from: fileURL.path)
            } catch {
                if studio.bookImportsPending == 0 { studio.bookImportStatus = "" }
                studio.errorMessage = "Couldn’t import \(name): \(error.localizedDescription)"
                studio.showBookImportError = true
            }
        }
        let pages = pageCount.map { " (\($0) pages)" } ?? ""
        let why = chosenByPageCount
            ? " It was taken for a book because it runs to \(localPDFBookPageThreshold) pages or more; pass kind paper to import it as a paper instead."
            : ""
        return """
        Importing \(name)\(pages) as a book in the background, the way Add Book does: ForeverLM reads its title and author, splits it into chapters and files each chapter under the book. A long book takes a few minutes.\(why)
        work_id: \(workID) (list_running_ai_work shows it while it runs; cancel_ai_work stops it)
        When it is done, list_sources with source_type book, or search_sources_keyword for its title, lists the chapters. A failure shows in the app and ends the work.
        """
    }

    /// A text or Markdown file as a text source, as dropping it on the app does.
    @MainActor
    private static func importLocalTextFile(fileURL: URL) async throws -> String {
        let studio = try AppModelBridge.requireStudio()
        let path = fileURL.path
        if let held = studio.articles.first(where: { $0.url == path || $0.localFilePath == path }) {
            return "Already in the library: '\(held.title)' (id: \(held.id))."
        }
        let known = Set(studio.articles.map(\.id))
        try await studio.importTextFile(from: path)
        guard let made = studio.articles.first(where: { !known.contains($0.id) }) else {
            throw MCPError.invalidInput("Nothing was imported from \(fileURL.lastPathComponent): the file holds no text.")
        }
        return "Imported '\(made.title)' as a text source (id: \(made.id), \(made.wordCount ?? 0) words)."
    }

    static func httpURLString(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }
        return value
    }

    func resolvedPDFURLForAttachment(_ urlString: String) async throws -> String {
        if let direct = PaperService.paperPDFURL(from: urlString) {
            return direct
        }
        if let extracted = await PaperService.extractPDFURLFromWebPage(at: urlString) {
            return extracted
        }
        throw MCPError.invalidInput("No downloadable PDF URL found for \(urlString)")
    }

    func extractRequiredPaperMetadataWithAI(
        article: inout StudioArticle,
        firstPageText: String
    ) async throws -> String {
        let paperText = firstPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperText.isEmpty else {
            let message = "Paper ingestion failed: no readable paper text was available for the Paper Metadata LLM call."
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }
        guard let config = KeychainService.resolveConfig(for: .paperMetadata) else {
            // A plugin sees only this sentence, so it has to name the actual
            // blocker. Signing in fixes an absent account and nothing else.
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperMetadata)
                ?? "Paper Metadata AI is not configured. Sign in with Apple in ForeverLM and configure the Paper Metadata task."
            let message = "Paper ingestion failed: \(reason)"
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }
        let articleID = article.id
        let maximumAttempts = 3
        var result: AIService.PaperMetadataResult?
        var lastError: Error?
        var metadataMaxTokens = AIService.paperMetadataMaxTokens

        for attempt in 1...maximumAttempts {
            do {
                result = try await AIService().extractPaperMetadata(
                    source: AIUsageSource(source: article),
                    url: article.url,
                    title: article.title,
                    firstPageText: paperText,
                    maxTokens: metadataMaxTokens,
                    config: config
                )
                break
            } catch {
                // A stopped call is not a failed extraction. Retrying would
                // fail twice more at once, and recording it would mark a paper
                // failed that nothing was wrong with; the paper stays pending.
                if Task.isCancelled || AITransientErrorClassifier.isCancellation(error) { throw error }
                lastError = error
                logger.warning(
                    "MCP paper metadata extraction attempt \(attempt)/\(maximumAttempts) failed for \(articleID) using \(config.provider.shortName): \(error.localizedDescription)"
                )
                PaperIngestionDiagnostics.recordAttempt(
                    sourceID: articleID,
                    provider: config.provider.shortName,
                    attempt: attempt,
                    maximumAttempts: maximumAttempts,
                    message: error.localizedDescription
                )
                // A reasoning model that spent its whole output ceiling thinking
                // answers within a larger one.
                if case AIError.outputTokenLimit = error,
                   let raised = AIService.paperMetadataRaisedMaxTokens(after: metadataMaxTokens) {
                    metadataMaxTokens = raised
                    continue
                }
                if attempt < maximumAttempts {
                    try? await Task.sleep(for: .seconds(attempt))
                }
            }
        }

        guard let result else {
            let detail = lastError?.localizedDescription ?? "unknown error"
            let message = "Paper ingestion failed: Paper Metadata AI (\(config.provider.shortName)) failed after \(maximumAttempts) attempts: \(detail)"
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }

        // The title the model read off the PDF can have lost a glyph its font
        // could not map; the DOI's registered title restores it when the two
        // are otherwise the same title (`RegisteredPaperTitle`).
        let lookupDOI = result.doi ?? article.doi
        let registeredTitle = await PaperService.registeredTitleIfKnown(forDOI: lookupDOI)
        let updatedFields = Self.applyExtractedPaperMetadata(
            result,
            to: &article,
            registeredTitle: registeredTitle
        )
        // Mirrors the app: a field the document never prints is a blank to fill
        // in later, not a failed ingestion. Only a result that resolved no
        // bibliographic field at all reads as an extraction that did not happen.
        guard article.hasAttestablePaperMetadata else {
            // `article` keeps whatever the extractor did resolve; the caller
            // persists it, so the learner finishes from a real title rather than
            // from the dropped filename.
            let message = StudioArticle.paperMetadataIncompleteMessage(
                missing: article.missingRequiredPaperMetadataFields
            )
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }

        // Cleanup runs once. A paper that already carries canonical text is here
        // for its metadata alone, and a second full-document pass would charge
        // the learner twice for the same text.
        let cleanupStatus: String
        if article.hasCompletedPaperContentCleanup {
            cleanupStatus = "Source Content Cleanup already had the canonical text"
        } else {
            // The store is read and written in stretches of their own, so a
            // caller that holds no gate (a paper import finishing in the
            // background) lets every other call run during the model calls.
            let storedRaw = try await withStoreGate(.shared) {
                try knowledgeStore().loadPaperContentPreparation(articleID)?.raw
            }
            let rawText = storedRaw ?? article.content ?? firstPageText
            do {
                let prepared = try await PaperContentPreparationService().prepare(
                    source: AIUsageSource(source: article),
                    rawText: rawText
                )
                article.installPreparedPaperContent(
                    raw: prepared.raw,
                    clean: prepared.clean,
                    metadata: prepared.metadata,
                    wordCount: prepared.wordCount
                )
            } catch where AITransientErrorClassifier.isCancellation(error) {
                // The caller went away mid-request. Nothing is known about this
                // paper, so leave the staged text queued for the durable drain
                // instead of parking it behind a failure it never earned.
                article.stagePaperContentCleanup(
                    raw: rawText,
                    rawSHA256: PaperContentPreparationService.sha256(rawText)
                )
                article.state = .queued
                article.errorMessage = nil
                let pending = article
                try? await withStoreGate(.exclusive) { try knowledgeStore().saveSource(pending) }
                NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                throw error
            } catch {
                let message = StudioArticle.paperContentCleanupFailureMessage(
                    error.localizedDescription
                )
                recordPaperIngestionFailure(&article, message: message)
                throw MCPError.invalidInput(message)
            }
            cleanupStatus = "Source Content Cleanup saved the canonical text"
        }
        guard article.completePaperMetadataExtractionAfterLLM() else {
            throw MCPError.invalidInput("Paper metadata attestation failed after content cleanup.")
        }
        let fieldSummary = updatedFields.isEmpty ? "confirmed existing metadata" : "updated \(updatedFields.joined(separator: ", "))"
        let blanks = article.missingRequiredPaperMetadataFields
        let blankSummary = blanks.isEmpty ? "" : "; the document prints no \(blanks.joined(separator: ", "))"
        return "Paper Metadata AI \(fieldSummary); \(cleanupStatus)\(blankSummary)"
    }

    private func recordPaperIngestionFailure(
        _ article: inout StudioArticle,
        message: String
    ) {
        article.failPaperIngestionMetadata(message)
        PaperIngestionDiagnostics.recordFailure(
            sourceID: article.id,
            title: article.title,
            message: message
        )
    }

    /// `registeredTitle` is the title the paper's DOI is registered under,
    /// when known; see `StudioViewModel.applyExtractedPaperMetadata`, whose
    /// rule this is.
    static func applyExtractedPaperMetadata(
        _ result: AIService.PaperMetadataResult,
        to article: inout StudioArticle,
        registeredTitle: String? = nil
    ) -> [String] {
        var updatedFields: [String] = []
        if let title = result.title, !title.isEmpty, article.title != title {
            article.title = title
            updatedFields.append("title")
        }
        if let restored = RegisteredPaperTitle.restoringLostCharacters(
            in: article.title,
            registered: registeredTitle
        ) {
            article.title = restored
            if !updatedFields.contains("title") { updatedFields.append("title") }
        }
        if let doi = result.doi, article.doi != doi {
            article.doi = doi
            updatedFields.append("DOI")
        }
        if let author = result.author, article.author != author {
            article.author = author
            updatedFields.append("author")
        }
        if let journal = result.journal, article.journal != journal {
            article.journal = journal
            updatedFields.append("journal")
        }
        if let year = result.year, article.publishedYear != year {
            article.publishedYear = year
            updatedFields.append("year")
        }
        return updatedFields
    }

    /// A download (YouTube, a Zoom recording) holds no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the source is checked, and a transcript
    /// already stored marked ready, in one short stretch held alone, and what a
    /// download brought is saved in another.
    func fetchVideoTranscript(sourceID: String, passcode: String? = nil) async throws -> String {
        enum Start {
            case notFound
            case cached(StudioArticle)
            case download(StudioArticle)
        }
        let start: Start = try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            guard var article = try store.loadSourceForSync(sourceID) else {
                return .notFound
            }
            let isZoom = ZoomRecordingService.isZoomRecordingURL(article.url)
            // A Zoom recording is a meeting session; the gateway's transcript
            // nudge and an assistant's retry both reach it through this tool.
            guard article.sourceType == .video || (article.sourceType == .meeting && isZoom) else {
                throw MCPError.invalidInput("fetch_video_transcript requires a video source or a Zoom meeting session.")
            }
            guard YouTubeTranscriptService.isYouTubeURL(article.url) || isZoom || TeachableCourseService.isLectureURL(article.url) else {
                throw MCPError.invalidInput("fetch_video_transcript currently supports YouTube URLs, Zoom recording links and Teachable lectures.")
            }

            if let cachedTranscript = try store.loadSourceContent(sourceID),
               !cachedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                article.content = cachedTranscript
                article.wordCount = cachedTranscript.split(separator: " ").count
                article.state = .ready
                article.errorMessage = nil
                try store.saveSource(article)
                return .cached(article)
            }
            return .download(article)
        }
        let article: StudioArticle
        switch start {
        case .notFound:
            throw MCPError.notFound("Source not found: \(sourceID)")
        case .cached(let cached):
            return "Transcript already cached for '\(cached.title)' (\(cached.wordCount ?? 0) words)"
        case .download(let found):
            article = found
        }
        let isZoom = ZoomRecordingService.isZoomRecordingURL(article.url)
        let isTeachable = TeachableCourseService.isLectureURL(article.url)

        if isTeachable {
            let workID = try await MainActor.run { try Self.startTeachableTranscript(sourceID: sourceID) }
            return "Transcribing '\(article.title)' from its audio in ForeverLM (work_id: \(workID); cancel_ai_work stops it). This takes a few minutes; call fetch_video_transcript or get_source_content again for the transcript. If the source shows an error instead, it names the cause — most often that the learner must sign in to the school in ForeverLM's browser."
        }

        if isZoom {
            let trimmedPasscode = passcode?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suppliedPasscode = trimmedPasscode.flatMap { $0.isEmpty ? nil : $0 }
            let savedPasscode: String?
            if suppliedPasscode == nil {
                savedPasscode = await Task.detached(priority: .userInitiated) {
                    KeychainService.zoomRecordingPasscode(forSourceID: sourceID)
                }.value
            } else {
                savedPasscode = nil
            }

            let result: ZoomRecordingService.RecordingTranscript
            do {
                result = try await ZoomRecordingService.shared.fetchTranscript(
                    from: article.url,
                    passcode: suppliedPasscode ?? savedPasscode
                )
            } catch ZoomRecordingService.ZoomRecordingError.passcodeRequired {
                throw MCPError.invalidInput(
                    "This Zoom recording requires a passcode. Ask the user for the recording passcode and call fetch_video_transcript again with the passcode argument."
                )
            } catch {
                if savedPasscode != nil,
                   case ZoomRecordingService.ZoomRecordingError.wrongPasscode = error {
                    _ = await Task.detached(priority: .utility) {
                        KeychainService.deleteZoomRecordingPasscode(forSourceID: sourceID)
                    }.value
                }
                throw error
            }
            let passcodeSaved: Bool?
            if let suppliedPasscode {
                passcodeSaved = await Task.detached(priority: .utility) {
                    KeychainService.saveZoomRecordingPasscode(suppliedPasscode, forSourceID: sourceID)
                }.value
            } else {
                passcodeSaved = nil
            }
            let saved = try await saveSourceAfterWait(sourceID) { stored in
                if let topic = result.topic, !topic.isEmpty {
                    stored.title = topic
                }
                stored.content = result.transcript
                stored.wordCount = result.transcript.split(separator: " ").count
                stored.state = .ready
                stored.errorMessage = nil
                return true
            }
            let keychainStatus = passcodeSaved == false
                ? ". Warning: the passcode could not be saved to Keychain"
                : ""
            return "Fetched Zoom transcript for '\(saved.title)' (\(saved.wordCount ?? 0) words)\(keychainStatus)"
        }

        let (transcript, videoTitle) = try await YouTubeTranscriptService.shared.fetchTranscript(from: article.url)
        let fetchedTitle = videoTitle.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let slideResult = await YouTubeSlideExtractionService.shared.appendingSlideContext(
            to: transcript,
            videoURL: article.url,
            sourceID: article.id,
            videoTitle: videoTitle ?? article.title
        )
        let saved = try await saveSourceAfterWait(sourceID) { stored in
            if let fetchedTitle {
                stored.title = fetchedTitle
            }
            stored.content = slideResult.content
            stored.wordCount = slideResult.content.split(separator: " ").count
            stored.state = .ready
            stored.errorMessage = nil
            return true
        }
        var message = "Fetched transcript for '\(saved.title)' (\(saved.wordCount ?? 0) words"
        if slideResult.slideCount > 0 {
            message += ", \(slideResult.slideCount) slide frame screenshots"
        }
        message += ")"
        if let errorMessage = slideResult.errorMessage {
            message += "\nSlide extraction unavailable: \(errorMessage)"
        }
        return message
    }

    func fetchSourceFromArchive(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard [.article, .manual, .unclassified].contains(article.sourceType) else {
            throw MCPError.invalidInput("fetch_source_from_archive is available for article, manual, and unclassified sources.")
        }
        guard article.url.hasPrefix("http://") || article.url.hasPrefix("https://") else {
            throw MCPError.invalidInput("fetch_source_from_archive requires a web URL.")
        }

        let content = try await SourceService.shared.fetchArchiveContent(for: article.url)
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
        article.errorMessage = nil
        article.isPaywalled = false
        try store.saveSource(article)
        return "Fetched archive.ph content for '\(article.title)' (\(article.wordCount ?? 0) words)"
    }

    func clearSourceDerivedData(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.clearSourceDerivedData(sourceID)
        return "Cleared cached text and embeddings for '\(article.title)'"
    }

    func listSourceActions(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }

        var lines = [
            "Available durable actions for '\(article.title)' (type: \(article.sourceType.rawValue)):",
            "- get_source_content: read source text",
            "- update_source: rename, edit author, edit parent_group, update content, or change source_type",
            "- assign_sources_to_day: put on the Schedule",
            "- get_review_sessions: show review sessions for this source",
            "- add_notebook_sources: add to an explicitly identified Notebook",
            "- set_source_hidden: hide or unhide source",
            "- remove_source: Studio Remove behavior with dismissal plus archive/delete",
            "- archive_source: archive without dismissal",
            "- delete_source: permanently delete",
            "- clear_source_derived_data: clear cached text and embeddings"
        ]

        switch article.sourceType {
        case .article, .paper, .unclassified:
            lines.append("- set_source_paywall_status: mark or clear paywalled status")
        default:
            break
        }

        if [.article, .manual, .unclassified].contains(article.sourceType) {
            lines.append("- attach_text_file_to_source: attach local text/Markdown/HTML as source content")
        }

        if StudioViewModel.supportsLinkDiscovery(article) {
            lines.append("- scan_article_for_linked_sources: read this article's links for the sources it points at (other articles, papers, videos, podcasts)")
            lines.append("- list_video_cited_papers: list the linked sources found, with what the article says about each")
            lines.append("- import_video_cited_paper: add one of those sources to the library")
            lines.append("- update_video_cited_paper_status: dismiss one of those sources, or restore a dismissed one")
        }

        if article.sourceType == .paper {
            lines.append("- update_source: edit paper journal, published_year, DOI, and paywall status")
            lines.append("- attach_pdf_to_paper: attach a local PDF and extract text")
            if article.resolvedPDFPath == nil, article.url.hasPrefix("http") {
                // A paper caught in a storage-level outage has a PDF on record and
                // must not be advertised as re-downloadable — see
                // `downloadPapersNeedingAttention`. Only a paper that HAS a
                // recorded path can be in that set, so papers that never had a
                // PDF skip the whole-library load entirely.
                let hasRecordedPDF = !(article.localFilePath ?? "").isEmpty
                let isUnavailable = hasRecordedPDF && StudioViewModel.unavailableRecordedPaperPDFIDs(
                    in: (try? store.loadActiveSources()) ?? []
                ).contains(article.id)
                if isUnavailable {
                    lines.append("- (PDF on record but its file isn't available on this Mac yet — usually iCloud Drive still downloading. Not a candidate for paper download or paywall recheck.)")
                } else if article.hasPaywallMarker {
                    lines.append("- recheck_paywalled_papers: look again for a legitimate free PDF and attach it if found")
                } else {
                    lines.append("- download_papers_needing_attention: bulk-download missing paper PDFs (this paper qualifies)")
                }
            }
        }

        if article.sourceType == .podcast {
            lines.append("- set_podcast_episode_hidden: hide or unhide this episode")
            lines.append("- set_podcast_show_hidden: hide or unhide show '\(article.domain)'")
            lines.append("- set_podcast_show_import_blocked: stop importing show '\(article.domain)' entirely, or let it back in")
            lines.append("- set_podcast_episode_visible_override: force-show this episode while its show is hidden")
        }

        if article.sourceType == .video {
            lines.append("- fetch_video_transcript: fetch and store a YouTube transcript (plus slide frame context) or a Zoom recording transcript (pass passcode if the recording is protected)")
            lines.append("- list_video_cited_papers: list the papers found on this video's slides")
            lines.append("- import_video_cited_paper: add one of those papers to the library")
            lines.append("- update_video_cited_paper_status: dismiss one of those papers, or restore a dismissed one")
            lines.append("- scan_video_for_cited_papers: read this video's slides for cited papers (catch-up for videos ingested before slide scanning existed)")
            if article.isYouTubeURL {
                lines.append("- set_youtube_channel_hidden: hide or unhide channel '\(article.domain)'")
                lines.append("- set_youtube_video_visible_override: force-show this video while its channel is hidden")
            }
        }

        lines.append("")
        lines.append("Unavailable to MCP because they operate local UI instead of durable app state:")
        lines.append("- Open in Window, Open in Safari, Open in VS Code, Reveal in Finder, native file picker, clipboard copy")
        return lines.joined(separator: "\n")
    }

    func updateSource(
        sourceID: String,
        title: String?,
        author: String?,
        sourceType: String? = nil,
        journal: String? = nil,
        publishedYear: String? = nil,
        doi: String? = nil,
        isPaywalled: Bool? = nil,
        parentGroup: String?,
        content: String?
    ) throws -> String {
        try Self.requirePlausibleSourceAuthor(author)
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        var changedFields: [String] = []

        if let title {
            article.title = title
            changedFields.append("title")
        }
        if let author {
            article.author = author
            changedFields.append("author")
        }
        if let sourceType {
            guard let type = StudioSourceType(rawValue: sourceType) else {
                throw MCPError.invalidInput("Unsupported source_type: \(sourceType)")
            }
            let previousType = article.sourceType
            article.sourceType = type
            if type == .paper, previousType != .paper {
                article.prepareForPaperMetadataExtraction()
            }
            changedFields.append("source_type")
        }
        if let journal {
            article.journal = Self.nilIfBlank(journal)
            changedFields.append("journal")
        }
        if let publishedYear {
            article.publishedYear = Self.nilIfBlank(publishedYear)
            changedFields.append("published_year")
        }
        if let doi {
            article.doi = Self.nilIfBlank(doi)
            changedFields.append("doi")
        }
        if let isPaywalled {
            guard [.article, .paper, .unclassified].contains(article.sourceType) else {
                throw MCPError.invalidInput("is_paywalled is only available for article, paper, or unclassified sources.")
            }
            article.isPaywalled = isPaywalled
            if isPaywalled {
                article.state = article.sourceType == .paper ? .error : .ready
                article.statusFlag = .paywall
            } else if article.statusFlag == .paywall {
                article.errorMessage = nil
                article.state = article.sourceType == .paper && !article.hasPaperIngestionAttestation
                    ? .queued
                    : .ready
            }
            changedFields.append("is_paywalled")
        }
        if let parentGroup {
            article.parentGroup = try resolveGroupID(input: parentGroup, preferredType: article.sourceType.rawValue, store: store)
            changedFields.append("parent_group")
        }
        if let content {
            article.content = content
            article.wordCount = content.split(separator: " ").count
            if article.sourceType == .paper {
                article.prepareForPaperMetadataExtraction()
            } else {
                article.state = .ready
            }
            changedFields.append("content")
        }
        if changedFields.isEmpty {
            return "No fields to update."
        }
        try store.saveSource(article)
        if article.sourceType == .meeting, changedFields.contains("parent_group"), let groupID = article.parentGroup {
            // The session's recording and transcript rows name its series
            // too, and go where the session goes.
            try store.moveMeetingArtifacts(sourceID: sourceID, toGroupID: groupID)
        }
        return "Updated source \(sourceID): \(changedFields.joined(separator: ", "))"
    }

    static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func decodeTextData(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .ascii)
    }

    func copyFileIntoContentRoot(
        _ sourceURL: URL,
        folder: String,
        baseName: String,
        fallbackExtension: String
    ) throws -> URL {
        let destinationDirectory = sourceContentRoot.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackExtension
            : sourceURL.pathExtension
        var destination = destinationDirectory
            .appendingPathComponent(Self.safeFilenameBase(baseName))
            .appendingPathExtension(fileExtension)
        var suffix = 2
        while destination.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
            if !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                    return destination
                } catch {
                    // Imports run side by side: another one took the name
                    // between the look and the copy, which never overwrites.
                    guard FileManager.default.fileExists(atPath: destination.path), suffix < 100 else { throw error }
                }
            }
            destination = destinationDirectory
                .appendingPathComponent("\(Self.safeFilenameBase(baseName))-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return destination
    }

    static func safeFilenameBase(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "source" : String(cleaned.prefix(120))
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
