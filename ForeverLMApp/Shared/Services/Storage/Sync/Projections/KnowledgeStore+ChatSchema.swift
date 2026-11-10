import Foundation

// MARK: - Schema 158: what the Chat and Exchange records need (§12.7)

extension KnowledgeStore {
    /// The columns schema 158 adds (docs/cloudkit-schema-design.md §12.7), NULL on every row: DDL only,
    /// like every step from 154 on. Generation 1 never reads or writes them; the generation-2 activation
    /// derives the three on `review_sessions` (`chatActivationDerivations`), and from then on the chat
    /// projections and the generation-2 creation sites keep them.
    /// - `review_sessions.chat_kind`: `Chat.kind` (D50). Today's `kind` column keeps its generation-1
    ///   meaning, and every generation-1 reader keeps reading it.
    /// - `review_sessions.marks_reviewed`: whether an `import_review_chat` call with `session_id` and no
    ///   `mark_reviewed` counts the sources it adds as reviewed (`Chat.marksReviewed`).
    /// - `review_sessions.context_mode`: `Chat.contextMode`.
    /// - `review_exchanges.anchor_json`, `cited_source_ids`: `Exchange.contextAnchor` and
    ///   `Exchange.citedSourceIDs` as another device sent them (nothing on this Mac writes them yet).
    static let chatSyncColumns: [(table: String, name: String, definition: String)] = [
        ("review_sessions", "chat_kind", "TEXT"),
        ("review_sessions", "marks_reviewed", "INTEGER"),
        ("review_sessions", "context_mode", "TEXT"),
        ("review_exchanges", "anchor_json", "TEXT"),
        ("review_exchanges", "cited_source_ids", "TEXT"),
    ]

    /// Schema 158's proof before the stamp: every column is there.
    func probeSchema158() throws {
        for column in Self.chatSyncColumns {
            try query("SELECT \(column.name) FROM \(column.table) LIMIT 0") { _ in }
        }
    }
}

// MARK: - The activation's derivations for chats (§13.3 step 3c)

extension KnowledgeStore {
    /// WP10's derivations, after WP8's: each chat's kind, whether its imports' appends mark sources
    /// reviewed, and its context mode. Each fills only rows that have none, so a second run changes
    /// nothing, a chat generation-1 code made after 158 is covered, and a value a generation-2 creation
    /// site wrote is never overwritten. Bounded by the library's chats, each in its own transaction,
    /// reading generation-1 truth only.
    static let chatActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "chatKinds") { store in try store.inDerivationTransaction { try $0.deriveChatKinds() } },
        ActivationDerivation(id: "chatMarksReviewed") { store in try store.inDerivationTransaction { try $0.deriveChatMarksReviewed() } },
        ActivationDerivation(id: "chatContextModes") { store in try store.inDerivationTransaction { try $0.deriveChatContextModes() } },
    ]

    /// `chat_kind` by `ChatKindClassifier` (D50, §10): one query gathers every unclassified chat's
    /// evidence, the classifier decides, and the kinds are written in this transaction.
    @discardableResult
    func deriveChatKinds() throws -> Int {
        var kinds: [(id: String, kind: ChatKind)] = []
        try query(ChatEvidence.select + " WHERE s.chat_kind IS NULL ORDER BY s.id", []) { row in
            let evidence = ChatEvidence.evidence(row)
            kinds.append((evidence.id, ChatKindClassifier.kind(of: evidence)))
        }
        for item in kinds {
            try execute("UPDATE review_sessions SET chat_kind = ? WHERE id = ? AND chat_kind IS NULL", [.text(item.kind.rawValue), .text(item.id)])
        }
        return kinds.count
    }

    /// `marks_reviewed` by today's `appendMarksReviewed` default (§10): a chat whose kind is unset or
    /// `review` marks the sources an append adds as reviewed; a `chat` or a memory review (its kind, or
    /// a `memory-` id with none, as `loadReviewSessionKind` reads it) does not.
    @discardableResult
    func deriveChatMarksReviewed() throws -> Int {
        var rows: [(id: String, marks: Bool)] = []
        try query("SELECT id, kind FROM review_sessions WHERE marks_reviewed IS NULL ORDER BY id", []) { row in
            guard let id = row.text(0) else { return }
            let kind = row.text(1).flatMap(ReviewSessionKind.init(rawValue:)) ?? (MemoryReviewSession.isMemorySession(id) ? .memory : nil)
            rows.append((id, kind == nil || kind == .review))
        }
        for row in rows {
            try execute("UPDATE review_sessions SET marks_reviewed = ? WHERE id = ? AND marks_reviewed IS NULL", [.integer(row.marks ? 1 : 0), .text(row.id)])
        }
        return rows.count
    }

    /// `context_mode` by `ChatContextModeRule`, set-based.
    func deriveChatContextModes() throws {
        try execute("UPDATE review_sessions AS s SET context_mode = \(ChatContextModeRule.sql) WHERE s.context_mode IS NULL", [])
    }
}

// MARK: - What a generation-2 creation site writes (D50)

extension KnowledgeStore {
    /// Under generation 2, a chat just created gets its kind, its context mode and, for an import, its
    /// review default, in the creating transaction. The kind is the creation site's: the course-quiz
    /// chat `quizSitting`, the walk's chat `walkthrough`, a memory review `memory`, a review `review`,
    /// every other chat `chat`; none writes `voice`, which only the classifier gives. A site that names
    /// no kind gets the classifier's over the row (D50).
    func keepChatShapeForGeneration2(sessionID: String, kind: ChatKind?, marksReviewed: Bool? = nil) throws {
        let resolved = try kind ?? ChatEvidence.load(chatID: sessionID, connection: self).map(ChatKindClassifier.kind(of:)) ?? .chat
        try execute(
            "UPDATE review_sessions AS s SET chat_kind = ?, context_mode = \(ChatContextModeRule.sql), marks_reviewed = COALESCE(?, s.marks_reviewed) WHERE s.id = ?",
            [.text(resolved.rawValue), .integer(marksReviewed.map { $0 ? 1 : 0 }), .text(sessionID)]
        )
    }

    /// A chat's kind as the Chat record has it: `chat_kind`, else the classifier's.
    func chatKind(sessionID: String) throws -> ChatKind? {
        if let stored = try scalarText("SELECT chat_kind FROM review_sessions WHERE id = ?", [.text(sessionID)]).flatMap(ChatKind.init(rawValue:)) {
            return stored
        }
        return try ChatEvidence.load(chatID: sessionID, connection: self).map(ChatKindClassifier.kind(of:))
    }

    /// `marks_reviewed` as stored; nil when unset.
    func chatMarksReviewed(sessionID: String) throws -> Bool? {
        try scalarInteger("SELECT marks_reviewed FROM review_sessions WHERE id = ? AND marks_reviewed IS NOT NULL", [.text(sessionID)]).map { $0 != 0 }
    }

    func setChatMarksReviewed(sessionID: String, _ marksReviewed: Bool) throws {
        try execute(
            "UPDATE review_sessions SET marks_reviewed = ? WHERE id = ? AND marks_reviewed IS NOT ?",
            [.integer(marksReviewed ? 1 : 0), .text(sessionID), .integer(marksReviewed ? 1 : 0)]
        )
    }

    /// Generation 2's `appendMarksReviewed` (§3.5.13): the call's own `mark_reviewed` decides when it
    /// is given, and an explicit false is remembered for the calls after it; otherwise the chat's
    /// `marks_reviewed`, which is true by default only for a review.
    func generation2AppendMarksReviewed(requested: Bool?, sessionID: String) throws -> Bool {
        if requested == false { try setChatMarksReviewed(sessionID: sessionID, false) }
        if let requested { return requested }
        return try chatMarksReviewed(sessionID: sessionID) ?? (chatKind(sessionID: sessionID) == .review)
    }
}
