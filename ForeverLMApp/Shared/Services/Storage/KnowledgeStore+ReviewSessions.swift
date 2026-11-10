import Foundation
import SQLite3
import OSLog
import CloudKit

/// One parsed turn of an imported external review chat. A tutor prompt
/// (`question`), the learner's reply (`answer`), and optional tutor feedback
/// (`evaluation`) — any of which may be nil for irregular conversations.
struct ReviewChatTurn {
    let question: String?
    let answer: String?
    let evaluation: String?
    /// When the turn happened, when the record it was read from says so (a
    /// Claude Code session file stamps every message); nil for a transcript
    /// typed into a tool argument, which is dated at the moment it arrives.
    var answeredAt: Date? = nil
}

enum ReviewTranscriptRole: Equatable, Sendable {
    case assistant
    case learner
}

struct ReviewTranscriptMessage: Sendable {
    let role: ReviewTranscriptRole
    let text: String
    var timestamp: Date? = nil
}

/// Shared parsing for role-labelled transcripts received from MCP clients. Keeping
/// this outside the MCP transport lets storage persist new exports per turn and
/// lets the transcript UI recover older one-block exports without rewriting them.
enum ReviewTranscriptParser {
    static func messages(from transcript: String) -> [ReviewTranscriptMessage] {
        var messages: [ReviewTranscriptMessage] = []
        var currentRole: ReviewTranscriptRole?
        var buffer: [String] = []

        func flushMessage() {
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let role = currentRole, !text.isEmpty {
                messages.append(ReviewTranscriptMessage(role: role, text: text))
            }
            buffer.removeAll()
        }

        for rawLine in transcript.components(separatedBy: "\n") {
            if let header = header(in: rawLine) {
                flushMessage()
                currentRole = header.role
                if !header.content.isEmpty {
                    buffer.append(header.content)
                }
            } else {
                buffer.append(rawLine)
            }
        }
        flushMessage()
        return messages
    }

    static func turns(from transcript: String) -> [ReviewChatTurn] {
        var turns = turns(from: messages(from: transcript))

        if turns.isEmpty {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                turns.append(
                    ReviewChatTurn(
                        question: "Exported chat transcript",
                        answer: trimmed,
                        evaluation: nil
                    )
                )
            }
        }
        return turns
    }

    /// Fold role-tagged messages into exchanges: an assistant message opens a
    /// turn's question side, the learner's reply closes it, and consecutive
    /// same-role messages merge. A turn is dated by the last message in it.
    static func turns(from messages: [ReviewTranscriptMessage]) -> [ReviewChatTurn] {
        var turns: [ReviewChatTurn] = []
        var question: String?
        var answer: String?
        var answeredAt: Date?

        func flushTurn() {
            if question != nil || answer != nil {
                turns.append(ReviewChatTurn(question: question, answer: answer, evaluation: nil, answeredAt: answeredAt))
            }
            question = nil
            answer = nil
            answeredAt = nil
        }

        for message in messages {
            switch message.role {
            case .assistant:
                if answer != nil { flushTurn() }
                question = [question, message.text].compactMap { $0 }.joined(separator: "\n\n")
            case .learner:
                answer = [answer, message.text].compactMap { $0 }.joined(separator: "\n\n")
            }
            answeredAt = message.timestamp ?? answeredAt
        }
        flushTurn()
        return turns
    }

    private static func role(forLabel label: String) -> ReviewTranscriptRole? {
        let normalized = label
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t#*_>•-–—\"'`[]()"))
            .lowercased()
        switch normalized {
        case "assistant", "claude", "chatgpt", "chat gpt", "gpt", "gemini", "grok", "ai", "tutor", "model", "foreverlm", "q", "question", "interviewer":
            return .assistant
        case "user", "you", "me", "human", "learner", "student", "a", "answer", "my answer", "reply":
            return .learner
        default:
            return nil
        }
    }

    private static func header(
        in line: String
    ) -> (role: ReviewTranscriptRole, content: String)? {
        var stripped = line.trimmingCharacters(in: .whitespaces)
        while let first = stripped.first, "#>-*_•".contains(first) {
            stripped.removeFirst()
            stripped = stripped.trimmingCharacters(in: .whitespaces)
        }
        guard !stripped.isEmpty else { return nil }

        if let colon = stripped.firstIndex(of: ":") {
            let labelPart = String(stripped[stripped.startIndex..<colon])
            guard labelPart.count <= 20, let role = role(forLabel: labelPart) else { return nil }
            let remainder = String(stripped[stripped.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^[*_~`]+\s*"#, with: "", options: .regularExpression)
            return (role, remainder)
        }

        let labelOnly = stripped.trimmingCharacters(
            in: CharacterSet(charactersIn: " \t#*_>•-")
        )
        guard labelOnly.count <= 20, let role = role(forLabel: labelOnly) else { return nil }
        return (role, "")
    }
}

/// App-owned parent identity for an imported review whose original host session
/// is unavailable. The combined memory completion transaction may create this
/// exact active parent and immediately finish it; retries validate the same
/// fields instead of leaving a separately committed phantom session.
struct ReviewSessionRecoverySeed: Equatable, Sendable {
    let topic: String
    let startedAt: Date
    let sourceIDs: [String]
    let cardIDs: [String]
    let modelProvider: String?
    let modelID: String?
    let goalID: String?

    init(
        topic: String,
        startedAt: Date,
        sourceIDs: [String],
        cardIDs: [String] = [],
        modelProvider: String? = nil,
        modelID: String? = nil,
        goalID: String? = nil
    ) {
        self.topic = topic
        self.startedAt = startedAt
        self.sourceIDs = sourceIDs
        self.cardIDs = cardIDs
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.goalID = goalID
    }
}

/// The route a chat's last reply ran on, as its row keeps it: the model and
/// the effort and speed it was asked for (schema 149). Raw values, as the
/// store keeps every model field; nil effort is the model's own default and
/// nil speed is standard.
struct ReviewSessionModelRoute: Equatable, Sendable {
    let modelProvider: String?
    let modelID: String?
    let modelEffort: String?
    let modelSpeed: String?
}

extension KnowledgeStore {
    // MARK: - Review Sessions

    func createReviewSession(
        id: String,
        topic: String,
        sourceIDs: [String],
        cardIDs: [String] = [],
        startedAt: Date = Date(),
        modelProvider: String? = nil,
        modelID: String? = nil,
        modelEffort: String? = nil,
        modelSpeed: String? = nil,
        goalID: String? = nil,
        scheduleActivityAt: Date? = nil,
        scheduleActivityKind: SourceActivityKind = .review,
        kind: ReviewSessionKind? = nil,
        briefing: String? = nil,
        chatKind: ChatKind? = nil
    ) throws {
        let sourceIDsJSON = jsonString(from: sourceIDs)
        let cardIDsJSON = jsonString(from: cardIDs)
        // A memory review is a memory review by its id alone, so the column
        // agrees with the prefix even when the caller did not say.
        let resolvedKind = kind ?? (MemoryReviewSession.isMemorySession(id) ? .memory : nil)
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_sessions (id, topic, started_at, status, overall_score, exchange_count, source_ids, card_ids, model_provider, model_id, model_effort, model_speed, goal_id, kind, briefing)
                VALUES (?, ?, ?, 'active', NULL, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, id)
                bind(stmt, 2, topic)
                sqlite3_bind_double(stmt, 3, startedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 4, sourceIDsJSON)
                bind(stmt, 5, cardIDsJSON)
                bind(stmt, 6, modelProvider)
                bind(stmt, 7, modelID)
                bind(stmt, 8, modelEffort)
                bind(stmt, 9, modelSpeed)
                bind(stmt, 10, goalID)
                bind(stmt, 11, resolvedKind?.rawValue)
                bind(stmt, 12, briefing)
            }
            try replaceReviewSessionSources(sessionID: id, sourceIDs: sourceIDs)
            try keepChatShapeForGeneration2(sessionID: id, kind: chatKind ?? (resolvedKind == .memory ? .memory : nil))
            // A memory review's sources are its material, not something the
            // learner has done yet: the day's memory session is created at the
            // day's start (07:00) with every candidate attached, and stamping
            // them here put a morning of "Reviewed" rows in History that no one
            // reviewed (product owner, 2026-09-22). A graded answer records the
            // review, source by source, when it happens.
            if let scheduleActivityAt, resolvedKind != .memory {
                for sourceID in sourceIDs {
                    try recordScheduledSourceActivityRows(
                        sourceID: sourceID,
                        on: scheduleActivityAt,
                        kind: scheduleActivityKind,
                        recordedAt: startedAt
                    )
                }
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Clone one chat through a specific persisted message boundary. A fork is
    /// deliberately an active session with fresh identities: subsequent turns,
    /// edits, and CloudKit changes must never mutate the original conversation.
    func forkReviewSession(
        sessionID: String,
        throughExchangeID: String,
        field: ReviewExchangeMessageField,
        createdAt: Date = Date()
    ) throws -> ReviewSessionRecord {
        var topic: String?
        var storedSourceIDs: [String] = []
        var modelProvider: String?
        var modelID: String?
        var modelEffort: String?
        var modelSpeed: String?
        var goalID: String?

        try queryBind("""
            SELECT topic, source_ids, model_provider, model_id, goal_id, model_effort, model_speed
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            topic = self.string(stmt, 0)
            storedSourceIDs = self.decodeStringArray(json: self.string(stmt, 1)) ?? []
            modelProvider = self.string(stmt, 2)
            modelID = self.string(stmt, 3)
            goalID = self.string(stmt, 4)
            modelEffort = self.string(stmt, 5)
            modelSpeed = self.string(stmt, 6)
        }

        guard let topic else {
            throw KnowledgeStoreError.invalidData("The chat to fork could not be found.")
        }

        var linkedSourceIDs: [String] = []
        try queryBind("""
            SELECT source_id
            FROM review_session_sources
            WHERE session_id = ?
            ORDER BY source_id
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                linkedSourceIDs.append(sourceID)
            }
        }
        let sourceIDs = linkedSourceIDs.isEmpty ? storedSourceIDs : linkedSourceIDs

        let exchanges = try loadReviewExchanges(sessionID: sessionID)
        guard let boundaryIndex = exchanges.firstIndex(where: { $0.id == throughExchangeID }) else {
            throw KnowledgeStoreError.invalidData("The response to fork could not be found in this chat.")
        }

        var copiedExchanges = Array(exchanges.prefix(through: boundaryIndex))
        let boundary = copiedExchanges[boundaryIndex]
        switch field {
        case .question:
            copiedExchanges[boundaryIndex] = CloudKitReviewExchangePayload(
                id: boundary.id,
                sessionID: boundary.sessionID,
                sequenceNumber: boundary.sequenceNumber,
                question: boundary.question,
                userAnswer: nil,
                evaluation: nil,
                score: nil,
                sourceRefs: boundary.sourceRefs,
                knowledgeNote: nil,
                answeredAt: nil
            )
        case .userAnswer:
            copiedExchanges[boundaryIndex] = CloudKitReviewExchangePayload(
                id: boundary.id,
                sessionID: boundary.sessionID,
                sequenceNumber: boundary.sequenceNumber,
                question: boundary.question,
                userAnswer: boundary.userAnswer,
                evaluation: nil,
                score: nil,
                sourceRefs: boundary.sourceRefs,
                knowledgeNote: nil,
                answeredAt: boundary.answeredAt
            )
        case .evaluation:
            break
        }

        let hasLearnerTurn = copiedExchanges.contains {
            $0.userAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard hasLearnerTurn else {
            throw KnowledgeStoreError.invalidData(
                "Start the conversation before forking this response."
            )
        }

        let newSessionID = UUID().uuidString
        let forkTitle = "\(topic) — fork"
        let sourceIDsJSON = jsonString(from: sourceIDs)

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO review_sessions (
                    id, topic, started_at, ended_at, status, overall_score, summary,
                    source_ids, card_ids, exchange_count, model_provider, model_id, goal_id,
                    model_effort, model_speed
                )
                VALUES (?, ?, ?, NULL, 'active', NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, newSessionID)
                bind(stmt, 2, forkTitle)
                sqlite3_bind_double(stmt, 3, createdAt.timeIntervalSinceReferenceDate)
                bind(stmt, 4, sourceIDsJSON)
                // A memory review's attempts are immutable evidence tied to the
                // original session. The conversational fork keeps its context,
                // but starts without claiming those target identities.
                bind(stmt, 5, "[]")
                sqlite3_bind_int(stmt, 6, Int32(copiedExchanges.count))
                bind(stmt, 7, modelProvider)
                bind(stmt, 8, modelID)
                bind(stmt, 9, goalID)
                bind(stmt, 10, modelEffort)
                bind(stmt, 11, modelSpeed)
            }

            for (index, exchange) in copiedExchanges.enumerated() {
                try execBind("""
                    INSERT INTO review_exchanges (
                        id, session_id, sequence_number, question, user_answer,
                        evaluation, score, source_refs, knowledge_note, answered_at,
                        context_content
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, UUID().uuidString)
                    bind(stmt, 2, newSessionID)
                    sqlite3_bind_int(stmt, 3, Int32(index + 1))
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
                }
            }

            try replaceReviewSessionSources(sessionID: newSessionID, sourceIDs: sourceIDs)
            // A fork holds the original's answers, so it keeps its kind: a review's stays private.
            try keepChatShapeForGeneration2(sessionID: newSessionID, kind: try chatKind(sessionID: sessionID))
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return ReviewSessionRecord(
            id: newSessionID,
            title: forkTitle,
            createdAt: createdAt,
            status: "active",
            sourceIDs: sourceIDs,
            exchangeCount: copiedExchanges.count,
            modelProvider: modelProvider,
            modelID: modelID,
            goalID: goalID
        )
    }

    /// Stamp the route a reply ran on. The effort and speed are written with
    /// the model every time, nil included, so they always describe the model
    /// beside them and never one the chat has since left.
    func updateReviewSessionModel(
        sessionID: String,
        modelProvider: String,
        modelID: String,
        modelEffort: String?,
        modelSpeed: String?
    ) throws {
        let trimmedProvider = modelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty, !trimmedModel.isEmpty else { return }

        try execBind("""
            UPDATE review_sessions
            SET model_provider = ?, model_id = ?, model_effort = ?, model_speed = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, trimmedProvider)
            bind(stmt, 2, trimmedModel)
            bind(stmt, 3, trimmedNonEmpty(modelEffort))
            bind(stmt, 4, trimmedNonEmpty(modelSpeed))
            bind(stmt, 5, sessionID)
        }
        noteStoreChanged()
    }

    /// The route a chat's row keeps, read fresh when the chat is reopened so
    /// it goes on with the model, effort and speed it was held in. nil when
    /// the chat has no row.
    func loadReviewSessionModelRoute(sessionID: String) throws -> ReviewSessionModelRoute? {
        var route: ReviewSessionModelRoute?
        try queryBind("""
            SELECT model_provider, model_id, model_effort, model_speed
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            route = ReviewSessionModelRoute(
                modelProvider: self.string(stmt, 0),
                modelID: self.string(stmt, 1),
                modelEffort: self.string(stmt, 2),
                modelSpeed: self.string(stmt, 3)
            )
        }
        return route
    }

    func updateReviewSessionTitle(sessionID: String, title: String) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        try execBind("""
            UPDATE review_sessions
            SET topic = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, trimmedTitle)
            bind(stmt, 2, sessionID)
        }
        noteStoreChanged()
    }

    /// Replace a session's title only while it still reads `provisionalTitle`.
    ///
    /// The AI-suggested title is generated after the first reply, while the
    /// learner may already have renamed the chat from the rail. A plain update
    /// would overwrite that rename with the suggestion; this compare-and-swap
    /// leaves any title that diverged from the echoed opening message alone.
    /// Returns false when the stored title no longer matched and nothing changed.
    @discardableResult
    func replaceProvisionalReviewSessionTitle(
        sessionID: String,
        provisionalTitle: String,
        title: String
    ) throws -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }

        try execBind("""
            UPDATE review_sessions
            SET topic = ?
            WHERE id = ? AND topic = ?
        """) { stmt in
            bind(stmt, 1, trimmedTitle)
            bind(stmt, 2, sessionID)
            bind(stmt, 3, provisionalTitle)
        }
        guard sqlite3_changes(db) > 0 else { return false }
        noteStoreChanged()
        return true
    }

    /// Move a session into a Notebook, or out of any Notebook when `goalID` is nil.
    func updateReviewSessionGoal(sessionID: String, goalID: String?) throws {
        try execBind("""
            UPDATE review_sessions
            SET goal_id = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, goalID)
            bind(stmt, 2, sessionID)
        }
        noteStoreChanged()
    }

    /// The Notebook or Goal a session is filed under, nil when it is loose.
    func loadReviewSessionGoalID(sessionID: String) throws -> String? {
        var result: String?
        try queryBind(
            "SELECT goal_id FROM review_sessions WHERE id = ? LIMIT 1",
            bind: { stmt in bind(stmt, 1, sessionID) }
        ) { stmt in
            result = self.string(stmt, 0).flatMap { $0.isEmpty ? nil : $0 }
        }
        return result
    }

    /// Remember which of a chat's sources had their text in the model's
    /// context, so the chat reopens holding them (schema 104). Local state
    /// about this Mac's prompt, like the history digest below: no sync
    /// bookkeeping, no CloudKit pass.
    func updateReviewSessionLoadedSources(sessionID: String, sourceIDs: [String]) throws {
        try execBind("UPDATE review_sessions SET loaded_source_ids = ? WHERE id = ?") { stmt in
            bind(stmt, 1, jsonString(from: sourceIDs))
            bind(stmt, 2, sessionID)
        }
    }

    /// The sources a chat had read when it was last open, in load order. nil
    /// for a chat recorded before the loaded set was kept, as distinct from a
    /// chat that had read nothing, which is [].
    func loadReviewSessionLoadedSourceIDs(sessionID: String) throws -> [String]? {
        var result: [String]?
        try queryBind(
            "SELECT loaded_source_ids FROM review_sessions WHERE id = ? LIMIT 1",
            bind: { stmt in bind(stmt, 1, sessionID) }
        ) { stmt in
            guard let json = self.string(stmt, 0) else { return }
            result = self.decodeStringArray(json: json) ?? []
        }
        return result
    }

    /// The saved rolling summary of a chat's older turns, if one was folded.
    /// Local cache, never synced: see `ReviewSessionHistoryDigest`.
    func loadReviewSessionHistoryDigest(sessionID: String) throws -> ReviewSessionHistoryDigest? {
        var result: ReviewSessionHistoryDigest?
        try queryBind("""
            SELECT digest, through_exchange_id, through_field, updated_at
            FROM review_session_history_digests
            WHERE session_id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let digest = self.string(stmt, 0),
                  let exchangeID = self.string(stmt, 1),
                  let rawField = self.string(stmt, 2),
                  let field = ReviewExchangeMessageField(rawValue: rawField) else {
                // An unreadable row is a cache miss, not an error: the summary
                // is rebuilt from the exchanges and the next fold overwrites it.
                return
            }
            result = ReviewSessionHistoryDigest(
                sessionID: sessionID,
                digest: digest,
                throughExchangeID: exchangeID,
                throughField: field,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            )
        }
        return result
    }

    /// Replace the saved summary for a session. It does not sync: the digest
    /// is derived from the exchanges, which are what iCloud carries.
    func saveReviewSessionHistoryDigest(_ digest: ReviewSessionHistoryDigest) throws {
        let trimmed = digest.digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try execBind("""
            INSERT INTO review_session_history_digests
                (session_id, digest, through_exchange_id, through_field, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                digest = excluded.digest,
                through_exchange_id = excluded.through_exchange_id,
                through_field = excluded.through_field,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, digest.sessionID)
            bind(stmt, 2, trimmed)
            bind(stmt, 3, digest.throughExchangeID)
            bind(stmt, 4, digest.throughField.rawValue)
            bind(stmt, 5, digest.updatedAt.timeIntervalSince1970)
        }
    }

}
