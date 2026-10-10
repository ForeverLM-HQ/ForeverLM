import Foundation

// MARK: - Chats and Exchanges (docs/cloudkit-schema-design.md §10, the `ReviewSession` row; D50)

/// What this Mac holds of a chat that an old payload does not carry: the generation-2 values a
/// creation site or the activation wrote, which stand (`chat_kind` is S; `marks_reviewed` keeps an
/// explicit false), and the notebook it is filed under when the payload predates `goalID`.
struct LegacyHeldChat: Equatable, Sendable {
    var chatKind: String?
    var marksReviewed: Bool?
    var contextMode: String?
    var goalID: String?
    /// The status the replica holds (an `archived` reads locally as `completed`).
    var replicaStatus: String?
    /// Generation 1's `kind` and `briefing`, which a payload from before schema 89 does not carry.
    var legacyKind: String?
    var briefing: String?
}

/// An exchange's `seq` and `createdAt` as the replica holds them: once acknowledged they stand.
struct LegacyHeldExchange: Equatable, Sendable {
    var seq: SyncJSON?
    var createdAt: SyncJSON?
}

extension LegacyV2Mapping {
    /// An old ReviewSession, whole or from `payloadAsset` (a chat over 512 KiB, R5-2): its Chat, kind by
    /// `ChatKindClassifier` over the same evidence the activation reads (D50), `marksReviewed` by today's
    /// default (`kind IS NULL OR kind = 'review'`, R4-m8), and each complete Exchange. A turn the old
    /// record gained is a new Exchange, given whole; ratings are the member's Marks.
    static func mapReviewSession(_ payload: CloudKitReviewSessionPayload, record: LegacyRecord, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        let chatID = try context.wireID(.chat, oldID: payload.id, teamID: record.teamID)
        let held = try context.heldChat(payload.id)
        let exchanges = payload.exchanges.filter { $0.sessionID == payload.id }
        let evidence = ChatKindClassifier.Evidence(
            id: payload.id, kind: payload.kind ?? held?.legacyKind,
            isTeamSnapshot: !(payload.teamID ?? "").isEmpty,
            isNamedByWalkthroughProgress: try context.walkNamesChat(payload.id),
            holdsWalkthroughStep: exchanges.contains { exchange in
                let text = exchange.question + "\n" + (exchange.evaluation ?? "")
                return text.contains("<\(WalkthroughStepTurn.tagName)") && WalkthroughStepTurn.marker(in: text) != nil
            },
            hasOverallScore: payload.overallScore != nil,
            hasCardIDs: !payload.cardIDs.isEmpty,
            hasGradedExchange: exchanges.contains { $0.score != nil || !["", "[]"].contains($0.ideaCoverage ?? "") }
        )
        let kind = held?.chatKind.flatMap(ChatKind.init(rawValue:)) ?? ChatKindClassifier.kind(of: evidence)
        let legacyKind = evidence.kind.flatMap(ReviewSessionKind.init(rawValue:))
            ?? (MemoryReviewSession.isMemorySession(payload.id) ? .memory : nil)
        let marksReviewed = held?.marksReviewed ?? (legacyKind == nil || legacyKind == .review)
        let goalID = payload.goalIDFieldIsPresent ? payload.goalID : held?.goalID
        let notebookID = try context.chatNotebookID(goalID: goalID)
        let contextSources = try payload.sourceIDs.filter { try context.sourceExists($0) }
        let filed = try !(goalID ?? "").isEmpty && context.learningGoalExists(goalID ?? "")
        let contextMode = held?.contextMode
            ?? ChatContextModeRule.mode(holdsSources: !contextSources.isEmpty || !payload.sourceIDs.isEmpty, filed: filed)

        var columns: [String: SQLiteValue] = [
            "topic": .text(payload.topic), "started_at": .real(payload.startedAt.timeIntervalSinceReferenceDate),
            "ended_at": .real(payload.endedAt?.timeIntervalSinceReferenceDate), "status": .text(payload.status),
            "overall_score": .real(payload.overallScore), "summary": .text(payload.summary),
            "source_ids": .text(jsonArrayText(payload.sourceIDs)), "card_ids": .text(jsonArrayText(payload.cardIDs)),
            "model_provider": .text(payload.modelProvider), "model_id": .text(payload.modelID),
            "model_effort": .text(payload.modelEffort), "model_speed": .text(payload.modelSpeed), "goal_id": .text(goalID),
            "kind": .text(evidence.kind), "briefing": .text(payload.briefing), "team_id": .text(payload.teamID),
            "chat_kind": .text(kind.rawValue), "marks_reviewed": .integer(marksReviewed ? 1 : 0), "context_mode": .text(contextMode),
        ]
        if payload.briefing == nil, let heldBriefing = held?.briefing { columns["briefing"] = .text(heldBriefing) }
        let links = (payload.docLinks ?? []).map {
            ChatRows.DocLink(
                id: $0.id, artifactID: $0.artifactID, anchorRevision: $0.anchorRevision, start: Int64($0.anchorStart), end: Int64($0.anchorEnd),
                quote: $0.anchorQuote, sectionTitle: $0.sectionTitle, createdAt: $0.createdAt.timeIntervalSinceReferenceDate
            )
        }.sorted { $0.id < $1.id }
        let rows = ChatRows(
            id: chatID, columns: columns, evidence: evidence, notebookID: notebookID, contextSourceIDs: contextSources.sorted(),
            docLinks: links, lastAnsweredAt: exchanges.compactMap { $0.answeredAt?.timeIntervalSinceReferenceDate }.max(),
            waiting: [], heldStatus: held?.replicaStatus
        )
        var fields = ChatProjection.encodeRows(rows)
        if !payload.goalIDFieldIsPresent, held == nil { fields.removeValue(forKey: "notebookID") }
        if payload.docLinks == nil { fields.removeValue(forKey: "docLinks") }
        var chat = LegacyV2Record(type: .chat, id: chatID, fields: fields, giving: .owns)
        chat.wholeFields = Set(["contextSourceIDs", "cardIDs", "docLinks"].filter { chat.fields[$0] != nil })
        mapping.records.append(chat)

        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            let heldExchange = try context.heldExchange(exchange.id)
            let exchangeColumns: [String: SQLiteValue] = [
                "session_id": .text(chatID), "sequence_number": .integer(Int64(exchange.sequenceNumber)),
                "question": .text(exchange.question), "user_answer": .text(exchange.userAnswer), "evaluation": .text(exchange.evaluation),
                "score": .real(exchange.score), "source_refs": .text(jsonArrayText(exchange.sourceRefs)),
                "knowledge_note": .text(exchange.knowledgeNote), "answered_at": .real(exchange.answeredAt?.timeIntervalSinceReferenceDate),
                "context_content": .text(exchange.contextContent), "idea_coverage": .text(exchange.ideaCoverage),
                "question_verdict": .text(exchange.questionVerdict), "operation": .text(exchange.operation), "steer": .text(exchange.steer),
                "anchor_json": .null, "cited_source_ids": .null,
            ]
            // An empty turn (no question, answer or reply) is never sent, unless the replica already holds it.
            guard heldExchange != nil || ExchangeProjection.isComplete(exchangeColumns) else { continue }
            let rows = ExchangeRows(
                id: exchange.id, columns: exchangeColumns, chatStartedAt: payload.startedAt.timeIntervalSinceReferenceDate,
                heldSeq: heldExchange?.seq, heldCreatedAt: heldExchange?.createdAt, waiting: [], chatIsPrivate: kind.isPrivate
            )
            mapping.records.append(LegacyV2Record(type: .exchange, id: exchange.id, fields: ExchangeProjection.encodeRows(rows), giving: .owns))
        }
        mapping.records += ratingMarks(exchanges)
    }

    /// A list of ids as generation 1 stores it in a JSON column (`jsonString(from:)`).
    static func jsonArrayText(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
