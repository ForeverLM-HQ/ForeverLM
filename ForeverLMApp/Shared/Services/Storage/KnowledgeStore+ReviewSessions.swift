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
            try markRecordChanged(entity: .reviewSession, logicalKey: id)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: newSessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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

    /// Replace the saved summary for a session. No `markRecordChanged`: the
    /// digest is derived from the exchanges, which are what CloudKit carries.
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: id)
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

    /// Records that an imported chat did not review its sources, so a later
    /// import into it leaves the sources it adds unreviewed too. Only a chat
    /// with no kind is stamped: nil already reads as an ordinary chat
    /// everywhere else, so the stamp changes nothing but that default, and a
    /// review or a memory review keeps what it is. The kind rides the
    /// session's record, so the other Macs learn it too.
    func markImportedChatAsChat(sessionID: String) throws {
        guard !MemoryReviewSession.isMemorySession(sessionID) else { return }
        try execBind("UPDATE review_sessions SET kind = ? WHERE id = ? AND kind IS NULL") { stmt in
            bind(stmt, 1, ReviewSessionKind.chat.rawValue)
            bind(stmt, 2, sessionID)
        }
        if sqlite3_changes(db) > 0 {
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
        }
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
                try markRecordChanged(entity: .reviewSession, logicalKey: existing.id)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: id)
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
            try markRecordChanged(entity: .hiddenReviewSession, logicalKey: sessionID, at: hiddenAt)
            return hiddenAt
        }
        guard existing != nil else { return nil }
        try execBind("DELETE FROM hidden_review_sessions WHERE session_id = ?") { stmt in
            self.bind(stmt, 1, sessionID)
        }
        try markRecordDeleted(entity: .hiddenReviewSession, logicalKey: sessionID)
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

            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: payload.id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Doc passages a chat was opened on

    /// Records that this conversation started on a passage of a doc.
    ///
    /// Idempotent by anchor: asking twice about the same words in the same chat
    /// refreshes the one row rather than stacking duplicates. A second passage,
    /// or the same passage after the doc has been revised, is a genuinely
    /// different anchor and gets its own row.
    ///
    /// The session is marked changed so the link reaches the other Mac inside
    /// the session record it belongs to.
    @discardableResult
    func linkArtifactPassageToChat(
        artifactID: String,
        sessionID: String,
        anchorRevision: String,
        anchorStart: Int,
        anchorEnd: Int,
        anchorQuote: String,
        sectionTitle: String,
        createdAt: Date = Date()
    ) throws -> ArtifactChatLinkRecord {
        let quote = anchorQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifactID.isEmpty, !sessionID.isEmpty, !quote.isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "A chat can only be linked to a passage that has a doc, a chat, and some words."
            )
        }
        let record = ArtifactChatLinkRecord(
            id: UUID().uuidString,
            artifactID: artifactID,
            sessionID: sessionID,
            anchorRevision: anchorRevision,
            anchorStart: max(0, anchorStart),
            anchorEnd: max(max(0, anchorStart), anchorEnd),
            anchorQuote: quote,
            sectionTitle: sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: createdAt
        )
        try execBind("""
            INSERT INTO artifact_chat_links (
                id, artifact_id, session_id, anchor_revision, anchor_start,
                anchor_end, anchor_quote, section_title, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, artifact_id, anchor_revision, anchor_start, anchor_end)
            DO UPDATE SET
                anchor_quote = excluded.anchor_quote,
                section_title = excluded.section_title
        """) { statement in
            bind(statement, 1, record.id)
            bind(statement, 2, record.artifactID)
            bind(statement, 3, record.sessionID)
            bind(statement, 4, record.anchorRevision)
            sqlite3_bind_int64(statement, 5, sqlite3_int64(record.anchorStart))
            sqlite3_bind_int64(statement, 6, sqlite3_int64(record.anchorEnd))
            bind(statement, 7, record.anchorQuote)
            bind(statement, 8, record.sectionTitle)
            sqlite3_bind_double(statement, 9, record.createdAt.timeIntervalSinceReferenceDate)
        }
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID, at: createdAt)
        return record
    }

    /// Every passage of this doc that has a conversation behind it, oldest first.
    func artifactChatLinks(artifactID: String) throws -> [ArtifactChatLinkRecord] {
        try artifactChatLinks(
            whereClause: "artifact_id = ?",
            bindValue: artifactID
        )
    }

    /// Every doc passage this chat was opened on, oldest first.
    func artifactChatLinks(sessionID: String) throws -> [ArtifactChatLinkRecord] {
        try artifactChatLinks(
            whereClause: "session_id = ?",
            bindValue: sessionID
        )
    }

    private func artifactChatLinks(
        whereClause: String,
        bindValue: String
    ) throws -> [ArtifactChatLinkRecord] {
        var links: [ArtifactChatLinkRecord] = []
        try queryBind("""
            SELECT id, artifact_id, session_id, anchor_revision, anchor_start,
                   anchor_end, anchor_quote, section_title, created_at
            FROM artifact_chat_links
            WHERE \(whereClause)
            ORDER BY created_at, id
        """, bind: { statement in
            bind(statement, 1, bindValue)
        }) { statement in
            guard let id = self.string(statement, 0),
                  let artifactID = self.string(statement, 1),
                  let sessionID = self.string(statement, 2),
                  let quote = self.string(statement, 6) else { return }
            links.append(ArtifactChatLinkRecord(
                id: id,
                artifactID: artifactID,
                sessionID: sessionID,
                anchorRevision: self.string(statement, 3) ?? "",
                anchorStart: Int(sqlite3_column_int64(statement, 4)),
                anchorEnd: Int(sqlite3_column_int64(statement, 5)),
                anchorQuote: quote,
                sectionTitle: self.string(statement, 7) ?? "",
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8))
            ))
        }
        return links
    }

    /// Forgets one passage-to-chat link. The conversation and the doc both
    /// survive it — this only says the two are no longer related.
    func deleteArtifactChatLink(_ linkID: String) throws {
        var sessionID: String?
        try queryBind(
            "SELECT session_id FROM artifact_chat_links WHERE id = ? LIMIT 1",
            bind: { statement in bind(statement, 1, linkID) }
        ) { statement in
            sessionID = self.string(statement, 0)
        }
        guard let sessionID else { return }
        try execBind("DELETE FROM artifact_chat_links WHERE id = ?") { statement in
            bind(statement, 1, linkID)
        }
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
    }

    /// Drops the links a deleted doc leaves behind. `artifact_id` carries no
    /// foreign key — CloudKit may deliver a chat before its doc — so nothing
    /// sweeps these rows automatically.
    func deleteArtifactChatLinks(artifactID: String) throws {
        var sessionIDs: [String] = []
        try queryBind(
            "SELECT DISTINCT session_id FROM artifact_chat_links WHERE artifact_id = ?",
            bind: { statement in bind(statement, 1, artifactID) }
        ) { statement in
            if let id = self.string(statement, 0) { sessionIDs.append(id) }
        }
        guard !sessionIDs.isEmpty else { return }
        try execBind("DELETE FROM artifact_chat_links WHERE artifact_id = ?") { statement in
            bind(statement, 1, artifactID)
        }
        for sessionID in sessionIDs {
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
        }
    }

    /// Replaces a session's links with what an inbound sync payload says they
    /// are. Called inside the session's own transaction, and never marks the
    /// session changed: doing so would bounce the record straight back out.
    func replaceArtifactChatLinks(
        sessionID: String,
        links: [CloudKitArtifactChatLinkPayload]
    ) throws {
        try execBind("DELETE FROM artifact_chat_links WHERE session_id = ?") { statement in
            bind(statement, 1, sessionID)
        }
        for link in links {
            let quote = link.anchorQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.artifactID.isEmpty, !quote.isEmpty else { continue }
            try execBind("""
                INSERT INTO artifact_chat_links (
                    id, artifact_id, session_id, anchor_revision, anchor_start,
                    anchor_end, anchor_quote, section_title, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, artifact_id, anchor_revision, anchor_start, anchor_end)
                DO UPDATE SET
                    anchor_quote = excluded.anchor_quote,
                    section_title = excluded.section_title
            """) { statement in
                bind(statement, 1, link.id)
                bind(statement, 2, link.artifactID)
                bind(statement, 3, sessionID)
                bind(statement, 4, link.anchorRevision)
                sqlite3_bind_int64(statement, 5, sqlite3_int64(max(0, link.anchorStart)))
                sqlite3_bind_int64(statement, 6, sqlite3_int64(max(0, link.anchorEnd)))
                bind(statement, 7, quote)
                bind(statement, 8, link.sectionTitle)
                sqlite3_bind_double(statement, 9, link.createdAt.timeIntervalSinceReferenceDate)
            }
        }
    }

    func deleteReviewSession(_ sessionID: String) throws {
        try requireSpaceDeletion(.chat, sessionID)
        // The local delete and CloudKit tombstone are one correctness boundary:
        // either the session plus its linked immutable memory attempts and all
        // tombstones commit, or none do. Retaining attempts after their exact
        // transcript disappears would leave broken cross-device relationships.
        let deletedAt = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            var linkedAttempts: [(id: String, memoryItemID: String)] = []
            try queryBind("""
                SELECT id, memory_item_id
                FROM memory_attempts
                WHERE session_id = ?
                ORDER BY id
            """, bind: { stmt in
                bind(stmt, 1, sessionID)
            }) { stmt in
                guard let id = self.string(stmt, 0),
                      let memoryItemID = self.string(stmt, 1) else { return }
                linkedAttempts.append((id, memoryItemID))
            }
            try execBind("DELETE FROM memory_attempts WHERE session_id = ?") { stmt in
                bind(stmt, 1, sessionID)
            }
            try execBind("DELETE FROM review_sessions WHERE id = ?", { stmt in
                bind(stmt, 1, sessionID)
            })
            // The hide goes with the chat, tombstone included; a remote
            // delete runs suppressed and the deleting client may never have
            // known the hide record existed, so its tombstone is published
            // explicitly, as the memory attempts below are.
            if try reviewSessionHiddenAt(sessionID: sessionID) != nil {
                try execBind("DELETE FROM hidden_review_sessions WHERE session_id = ?") { stmt in
                    bind(stmt, 1, sessionID)
                }
                if syncTrackingSuppressionDepth > 0 {
                    try enqueueCascadingRecordDeletion(entity: .hiddenReviewSession, logicalKey: sessionID, at: deletedAt)
                } else {
                    try markRecordDeleted(entity: .hiddenReviewSession, logicalKey: sessionID, at: deletedAt)
                }
            }
            for memoryItemID in Set(linkedAttempts.map(\.memoryItemID)).sorted() {
                try rebuildMemorySchedule(memoryItemID: memoryItemID)
            }
            for attempt in linkedAttempts {
                if syncTrackingSuppressionDepth > 0 {
                    // The inbound session tombstone already exists on the server,
                    // but an older deleting client may never have known about the
                    // separately synced memory attempt. Publish that dependent
                    // tombstone explicitly so it cannot be fetched back orphaned.
                    try enqueueCascadingRecordDeletion(
                        entity: .memoryAttempt,
                        logicalKey: attempt.id,
                        at: deletedAt
                    )
                } else {
                    try markRecordDeleted(
                        entity: .memoryAttempt,
                        logicalKey: attempt.id,
                        at: deletedAt
                    )
                }
            }
            try markRecordDeleted(entity: .reviewSession, logicalKey: sessionID, at: deletedAt)
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
                try markRecordDeleted(entity: .hiddenReviewSession, logicalKey: sessionID)
            }
            try markRecordDeleted(entity: .reviewSession, logicalKey: sessionID)
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
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Record that a session references specific sources.
    func linkReviewSession(_ sessionId: String, toSourceIds sourceIds: [String]) throws {
        for sourceId in sourceIds {
            try execBind("INSERT OR IGNORE INTO review_session_sources (session_id, source_id) VALUES (?, ?)", {
                self.bind($0, 1, sessionId)
                self.bind($0, 2, sourceId)
            })
        }
        try markRecordChanged(entity: .reviewSession, logicalKey: sessionId)
    }

    /// Sources attached to the learner's most recent ordinary chats and review
    /// sessions. Memory-check launch sessions are excluded by their non-empty
    /// `card_ids`: their source relationship is the whole planned queue, not
    /// evidence that every target was actually discussed. The result is only a
    /// queue-ordering preference; review dates and schedules remain unchanged.
    func recentReviewSourceActivity(
        now: Date = Date(),
        sessionLimit: Int = 12,
        maximumAgeDays: Int = 14
    ) throws -> [MemoryTutorRecentSourceActivity] {
        let boundedSessionLimit = max(0, min(sessionLimit, 50))
        let boundedAgeDays = max(1, min(maximumAgeDays, 90))
        guard boundedSessionLimit > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(boundedAgeDays) * 86_400)
        var result: [MemoryTutorRecentSourceActivity] = []
        try queryBind("""
            WITH recent_sessions AS (
                SELECT
                    fs.id,
                    MAX(COALESCE(fe.answered_at, fs.ended_at, fs.started_at)) AS activity_at
                FROM review_sessions fs
                LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                WHERE fs.status IN ('active', 'completed', 'external_link')
                  AND COALESCE(fs.card_ids, '[]') = '[]'
                GROUP BY fs.id
                HAVING (fs.status = 'external_link' OR COUNT(fe.id) > 0)
                   AND activity_at >= ?
                ORDER BY activity_at DESC, fs.id
                LIMIT ?
            )
            SELECT fss.source_id, MAX(recent_sessions.activity_at) AS discussed_at
            FROM recent_sessions
            JOIN review_session_sources fss
              ON fss.session_id = recent_sessions.id
            GROUP BY fss.source_id
            ORDER BY discussed_at DESC, fss.source_id
        """, bind: { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(statement, 2, Int64(boundedSessionLimit))
        }) { statement in
            guard let sourceID = self.string(statement, 0) else { return }
            result.append(MemoryTutorRecentSourceActivity(
                sourceID: sourceID,
                discussedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)
                )
            ))
        }
        return result
    }

    /// Returns the latest review date for each source. A source is reviewed
    /// once it has a completed local review session, a saved external review
    /// chat link, or a completed Schedule item.
    func sourceReviewDates() throws -> [String: Date] {
        let aliasMap = try buildSourceIdentityAliasMap()
        var result: [String: Date] = [:]
        var rows: [(id: String, date: Date)] = []
        var sessionRows: [String: (date: Date, sourceIDs: Set<String>)] = [:]
        try query("""
            SELECT id, source_ids, COALESCE(ended_at, started_at)
            FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """) { stmt in
            guard let sessionID = self.string(stmt, 0) else { return }
            sessionRows[sessionID] = (
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
                Set(self.decodeStringArray(json: self.string(stmt, 1)) ?? [])
            )
        }
        try query("""
            SELECT fss.session_id, fss.source_id
            FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
        """) { stmt in
            guard let sessionID = self.string(stmt, 0),
                  let sourceID = self.string(stmt, 1),
                  var row = sessionRows[sessionID] else { return }
            row.sourceIDs.insert(sourceID)
            sessionRows[sessionID] = row
        }
        for (sessionID, attemptedSourceIDs) in try attemptedMemorySourceIDsBySessionID() {
            guard var row = sessionRows[sessionID] else { continue }
            row.sourceIDs = attemptedSourceIDs
            sessionRows[sessionID] = row
        }
        for row in sessionRows.values {
            for sourceID in row.sourceIDs {
                rows.append((sourceID, row.date))
            }
        }
        try query("""
            SELECT source_id, MAX(completed_at)
            FROM learning_goal_items
            WHERE completed_at IS NOT NULL
            GROUP BY source_id
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            rows.append((id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))))
        }
        for row in rows {
            recordReviewDate(row.date, for: row.id, aliasMap: aliasMap, into: &result)
        }
        return result
    }

    /// When a completed session has concept attempts, their anchors are the
    /// authoritative coverage set. The session itself may retain the larger queue
    /// it launched with so transcript context and resume remain lossless.
    private func attemptedMemorySourceIDsBySessionID() throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        try query("""
            SELECT ma.session_id, mis.source_id
            FROM memory_attempts ma
            JOIN review_sessions fs ON fs.id = ma.session_id
            LEFT JOIN memory_item_sources mis
              ON mis.memory_item_id = ma.memory_item_id
             AND ma.grade_state = 'graded'
            WHERE ma.session_id IS NOT NULL
              AND fs.status IN ('completed', 'external_link')
            ORDER BY ma.session_id, mis.source_id
        """) { stmt in
            guard let sessionID = self.string(stmt, 0) else { return }
            if result[sessionID] == nil { result[sessionID] = [] }
            if let sourceID = self.string(stmt, 1) {
                result[sessionID]?.insert(sourceID)
            }
        }
        return result
    }

    /// Per-source retention stats from completed/external reviews: when each
    /// source was last reviewed, the most recent recall score, and how many times it
    /// has been reviewed. Keyed by raw source_id and restricted to currently-active
    /// sources. Powers the daily memory-training surface. Pass `restrictToSourceIDs`
    /// (e.g. one Learning Companion goal's approved sources) for a per-notebook refresh.
    func memoryReviewStats(restrictToSourceIDs requestedSourceIDs: Set<String>? = nil) throws -> [MemoryReviewStat] {
        // Screen record mode (admin only): unchanged when off.
        let restrictToSourceIDs = try screenRecordNarrowedMemorySourceIDs(requestedSourceIDs)
        struct SessionRow { var date: Date; var score: Double?; var sourceIDs: Set<String> }
        var sessions: [String: SessionRow] = [:]

        // Session-level rows carry the score and the JSON source list.
        try query("""
            SELECT id, COALESCE(ended_at, started_at), overall_score, source_ids
            FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            let score: Double? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let ids = Set(self.decodeStringArray(json: self.string(stmt, 3)) ?? [])
            sessions[id] = SessionRow(date: date, score: score, sourceIDs: ids)
        }

        // The junction table covers sessions whose source_ids JSON is empty.
        try query("""
            SELECT fss.session_id, fss.source_id
            FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
        """) { stmt in
            guard let sid = self.string(stmt, 0), let srcID = self.string(stmt, 1) else { return }
            sessions[sid]?.sourceIDs.insert(srcID)
        }

        // Memory-review sessions may launch with a larger queue than the learner
        // actually reaches. Once concept attempts exist, their item anchors are
        // the authoritative reviewed-source set; the session relationship remains
        // the full launch/transcript context for resume and sync.
        for (sessionID, attemptedSourceIDs) in try attemptedMemorySourceIDsBySessionID() {
            sessions[sessionID]?.sourceIDs = attemptedSourceIDs
        }

        // Fold sessions into per-source aggregates (each session counted once per
        // source). `lastScore` tracks the most recent *scored* session and stays
        // order-independent regardless of dictionary iteration order.
        struct Aggregate { var last: Date; var lastScore: Double?; var lastScoreDate: Date?; var count: Int }
        var bySource: [String: Aggregate] = [:]
        for row in sessions.values {
            for srcID in row.sourceIDs {
                if let restrict = restrictToSourceIDs, !restrict.contains(srcID) { continue }
                if var agg = bySource[srcID] {
                    agg.count += 1
                    if row.date > agg.last { agg.last = row.date }
                    if let score = row.score, agg.lastScoreDate == nil || row.date >= agg.lastScoreDate! {
                        agg.lastScore = score
                        agg.lastScoreDate = row.date
                    }
                    bySource[srcID] = agg
                } else {
                    bySource[srcID] = Aggregate(
                        last: row.date,
                        lastScore: row.score,
                        lastScoreDate: row.score != nil ? row.date : nil,
                        count: 1
                    )
                }
            }
        }
        guard !bySource.isEmpty else { return [] }

        // Resolve title/type, keeping only active sources (drops archived/deleted).
        let ids = Array(bySource.keys)
        var meta: [String: (title: String, type: String)] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < ids.count {
            let chunk = Array(ids[offset..<min(offset + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            try queryBind("""
                SELECT id, title, source_type
                FROM source_projection
                WHERE status = 'active'
                  AND is_collection_hidden = 0
                  AND id IN (\(placeholders))
            """, bind: { stmt in
                for (index, id) in chunk.enumerated() { bind(stmt, index + 1, id) }
            }) { stmt in
                guard let id = self.string(stmt, 0) else { return }
                meta[id] = (self.string(stmt, 1) ?? id, self.string(stmt, 2) ?? "unknown")
            }
            offset += chunkSize
        }

        return bySource.compactMap { srcID, agg in
            guard let resolved = meta[srcID] else { return nil }
            return MemoryReviewStat(
                sourceID: srcID,
                title: resolved.title,
                sourceType: resolved.type,
                lastReviewedAt: agg.last,
                lastScore: agg.lastScore,
                reviewCount: agg.count
            )
        }
    }

    /// Sources the learner has consumed but never reviewed — how new material
    /// enters the retention loop at all.
    ///
    /// `memoryReviewStats` can only score sources that already have review history,
    /// so without this a source read once and never reviewed would never come due
    /// and would simply be forgotten. Eligibility is deliberately narrow: the
    /// source must be active, not hidden, have extracted text worth reviewing
    /// against, have no completed review of any kind, and carry positive evidence
    /// of consumption (see `SourceConsumption` — mere presence in the library never
    /// qualifies). Pass `restrictToSourceIDs` to scope to one goal's sources.
    func unreviewedConsumedSources(restrictToSourceIDs requestedSourceIDs: Set<String>? = nil) throws -> [MemoryReviewNewCandidate] {
        // Screen record mode (admin only): unchanged when off.
        let restrictToSourceIDs = try screenRecordNarrowedMemorySourceIDs(requestedSourceIDs)
        // Alias-aware and broader than `memoryReviewStats`: a source reviewed under
        // a since-deduped ID, or completed on the Schedule, is not new.
        let reviewed = try sourceIdsWithCompletedReviewSession()

        var candidates: [MemoryReviewNewCandidate] = []
        // `depth`/`depth_at` widen intake beyond explicitly finished sources: a
        // podcast played to 70% is evidence the learner went through it, even
        // though nothing ever set read_at. The bare `last_activity_at` beside a
        // single MAX() is SQLite's documented min/max row selection — it is the
        // timestamp of the deepest day, not an arbitrary one. The content check
        // must stay `octet_length` (answered from the record header); trimming
        // materialized every source's full text on each call.
        try query("""
            SELECT sp.id, sp.title, sp.source_type, sp.date_added, sp.read_at,
                   sp.reading_position_page, sp.reading_position_locator,
                   COALESCE(depth.fraction, 0), depth.reached_at
            FROM source_projection sp
            JOIN source_content sc ON sc.source_id = sp.id
            LEFT JOIN (
                SELECT source_id,
                       MAX(CASE WHEN completed_kinds != 0 THEN 1.0 ELSE max_fraction END) AS fraction,
                       last_activity_at AS reached_at
                FROM source_activity_days
                GROUP BY source_id
            ) depth ON depth.source_id = sp.id
            WHERE sp.status = 'active'
              AND sp.is_collection_hidden = 0
              AND octet_length(sc.content) > 0
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            if let restrict = restrictToSourceIDs, !restrict.contains(id) { return }
            if reviewed.contains(id) { return }

            let signals = SourceConsumptionSignals(
                readAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                readingPositionPage: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(stmt, 5)),
                readingPositionLocator: self.string(stmt, 6),
                dateAdded: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                maxFraction: sqlite3_column_double(stmt, 7),
                deepestActivityAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8))
            )
            guard let consumedAt = SourceConsumption.consumedAt(
                signals,
                minimumConfidence: .substantial
            ) else { return }

            candidates.append(
                MemoryReviewNewCandidate(
                    sourceID: id,
                    title: self.string(stmt, 1) ?? id,
                    sourceType: self.string(stmt, 2) ?? "unknown",
                    consumedAt: consumedAt
                )
            )
        }
        return candidates
    }

    /// Most recent completed reviews linked to a Learning Companion goal, newest
    /// first, for the in-app goal dashboard's history list.
    func companionRecentSessions(goalID: String, limit: Int) throws -> [CompanionSessionSummary] {
        var sessions: [CompanionSessionSummary] = []
        try queryBind("""
            SELECT id, COALESCE(ended_at, started_at), overall_score, summary
            FROM review_sessions
            WHERE goal_id = ? AND status = 'completed'
            ORDER BY COALESCE(ended_at, started_at) DESC
            LIMIT ?
        """, bind: { stmt in
            bind(stmt, 1, goalID)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            sessions.append(
                CompanionSessionSummary(
                    id: id,
                    endedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                    overallScore: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
                    summary: self.string(stmt, 3)
                )
            )
        }
        return sessions
    }

    /// Returns the set of source IDs that have been reviewed through any source,
    /// including completed Schedule items.
    func sourceIdsWithCompletedReviewSession() throws -> Set<String> {
        Set(try sourceReviewDates().keys)
    }

    /// Returns source IDs referenced by any review session, including active chats.
    func sourceIdsWithReviewSession() throws -> Set<String> {
        var sourceIDs = Set<String>()
        try query("SELECT DISTINCT source_id FROM review_session_sources") { stmt in
            if let id = self.string(stmt, 0) { sourceIDs.insert(id) }
        }
        try query("SELECT source_ids FROM review_sessions") { stmt in
            for id in self.decodeStringArray(json: self.string(stmt, 0)) ?? [] {
                sourceIDs.insert(id)
            }
        }
        return try expandingSourceIdentityAliases(sourceIDs)
    }

    /// Returns source IDs that have a completed local review session or a saved external chat link.
    func sourceIdsWithLinkedChatSession() throws -> Set<String> {
        var sourceIDs = Set<String>()
        try query("""
            SELECT DISTINCT fss.source_id FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fs.status IN ('completed', 'external_link')
        """) { stmt in
            if let id = self.string(stmt, 0) { sourceIDs.insert(id) }
        }
        try query("""
            SELECT source_ids FROM review_sessions
            WHERE status IN ('completed', 'external_link')
        """) { stmt in
            for id in self.decodeStringArray(json: self.string(stmt, 0)) ?? [] {
                sourceIDs.insert(id)
            }
        }
        return try expandingSourceIdentityAliases(sourceIDs)
    }

    /// Expand a set of source IDs to include all identity aliases using the
    /// one-pass alias map. The previous per-ID `sourceIdentityAliases(for:)` loop
    /// ran two SQLite queries per session source and showed up as multi-second
    /// storage work in UI-stall samples during CloudKit remote refreshes.
    private func expandingSourceIdentityAliases(_ sourceIDs: Set<String>) throws -> Set<String> {
        guard !sourceIDs.isEmpty else { return [] }
        let aliasMap = try buildSourceIdentityAliasMap()
        var result = Set<String>()
        for sourceID in sourceIDs {
            result.formUnion(aliasMap[sourceID] ?? [sourceID])
        }
        return result
    }

    func sourceHasLinkedChatSession(_ sourceID: String) throws -> Bool {
        let aliases = try sourceIdentityAliases(for: sourceID)
        let placeholders = aliases.map { _ in "?" }.joined(separator: ",")
        var hasSession = false
        try queryBind("""
            SELECT 1 FROM review_session_sources fss
            JOIN review_sessions fs ON fs.id = fss.session_id
            WHERE fss.source_id IN (\(placeholders))
              AND fs.status IN ('completed', 'external_link')
            LIMIT 1
        """, bind: { stmt in
            for (index, alias) in aliases.enumerated() {
                bind(stmt, index + 1, alias)
            }
        }) { _ in
            hasSession = true
        }
        if !hasSession {
            try query("""
                SELECT source_ids FROM review_sessions
                WHERE status IN ('completed', 'external_link')
            """) { stmt in
                guard !hasSession else { return }
                hasSession = !(Set(self.decodeStringArray(json: self.string(stmt, 0)) ?? []).isDisjoint(with: aliases))
            }
        }
        return hasSession
    }

    func recordReviewDate(_ date: Date, for sourceID: String, into result: inout [String: Date]) throws {
        for id in try sourceIdentityAliases(for: sourceID) {
            if let existing = result[id] {
                result[id] = max(existing, date)
            } else {
                result[id] = date
            }
        }
    }

    func recordReviewDate(
        _ date: Date,
        for sourceID: String,
        aliasMap: [String: Set<String>],
        into result: inout [String: Date]
    ) {
        for id in aliasMap[sourceID] ?? [sourceID] {
            if let existing = result[id] {
                result[id] = max(existing, date)
            } else {
                result[id] = date
            }
        }
    }

    func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func sourceIdentityAliases(for sourceID: String) throws -> Set<String> {
        var aliases: Set<String> = [sourceID]
        var url: String?
        var normalizedURL: String?
        var doi: String?

        try queryBind("""
            SELECT url, normalized_url, doi
            FROM source_projection
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            url = self.string(stmt, 0)
            normalizedURL = self.string(stmt, 1)
            doi = self.string(stmt, 2)
        }

        let trimmedURL = trimmedNonEmpty(url)
        let normalizedFromURL = trimmedURL.map(URLNormalizer.normalize).flatMap { trimmedNonEmpty($0) }
        let normalizedCandidates = Set([
            trimmedNonEmpty(normalizedURL),
            normalizedFromURL
        ].compactMap { $0 })
        let normalizedDOI = trimmedNonEmpty(doi)?.lowercased()

        guard !normalizedCandidates.isEmpty || normalizedDOI != nil || trimmedURL != nil else {
            return aliases
        }

        var clauses = ["id = ?"]
        var params = [sourceID]
        if let trimmedURL {
            clauses.append("url = ?")
            params.append(trimmedURL)
        }
        for normalized in normalizedCandidates.sorted() {
            clauses.append("normalized_url = ?")
            params.append(normalized)
        }
        if let normalizedDOI {
            clauses.append("LOWER(doi) = ?")
            params.append(normalizedDOI)
        }

        try queryBind("""
            SELECT id
            FROM source_projection
            WHERE \(clauses.joined(separator: " OR "))
        """, bind: { stmt in
            for (index, param) in params.enumerated() {
                bind(stmt, index + 1, param)
            }
        }) { stmt in
            if let id = self.string(stmt, 0) {
                aliases.insert(id)
            }
        }

        return aliases
    }

    /// One-pass alias lookup for all sources. Used by `sourceReviewDates()` to
    /// avoid N+1 SQLite queries during startup queue load.
    func buildSourceIdentityAliasMap() throws -> [String: Set<String>] {
        struct Row {
            let id: String
            let url: String?
            let normalizedURL: String?
            let doi: String?
        }

        var rows: [Row] = []
        try query("""
            SELECT id, url, normalized_url, doi
            FROM source_projection
        """) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            rows.append(Row(
                id: id,
                url: self.string(stmt, 1),
                normalizedURL: self.string(stmt, 2),
                doi: self.string(stmt, 3)
            ))
        }

        var parent: [String: String] = [:]
        func find(_ id: String) -> String {
            var current = id
            while parent[current] != current {
                parent[current] = parent[parent[current]!]!
                current = parent[current]!
            }
            return current
        }
        func unite(_ lhs: String, _ rhs: String) {
            let rootLHS = find(lhs)
            let rootRHS = find(rhs)
            guard rootLHS != rootRHS else { return }
            parent[rootRHS] = rootLHS
        }

        var bucketOwner: [String: String] = [:]
        func link(_ id: String, bucket: String) {
            parent[id] = id
            if let owner = bucketOwner[bucket] {
                unite(id, owner)
            } else {
                bucketOwner[bucket] = id
            }
        }

        for row in rows {
            link(row.id, bucket: "id:\(row.id)")
            if let trimmedURL = trimmedNonEmpty(row.url) {
                link(row.id, bucket: "url:\(trimmedURL)")
            }
            let normalizedFromURL = trimmedNonEmpty(row.url)
                .map(URLNormalizer.normalize)
                .flatMap { trimmedNonEmpty($0) }
            let normalizedCandidates = Set([
                trimmedNonEmpty(row.normalizedURL),
                normalizedFromURL
            ].compactMap { $0 })
            for normalized in normalizedCandidates {
                link(row.id, bucket: "norm:\(normalized)")
            }
            if let normalizedDOI = trimmedNonEmpty(row.doi)?.lowercased() {
                link(row.id, bucket: "doi:\(normalizedDOI)")
            }
        }

        var groups: [String: Set<String>] = [:]
        for row in rows {
            groups[find(row.id), default: []].insert(row.id)
        }

        var aliasMap: [String: Set<String>] = [:]
        for row in rows {
            aliasMap[row.id] = groups[find(row.id)] ?? [row.id]
        }
        return aliasMap
    }
}
