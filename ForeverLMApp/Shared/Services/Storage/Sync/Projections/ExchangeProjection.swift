import Foundation

// MARK: - The Exchange record (docs/cloudkit-schema-design.md §3.5.14)

/// An exchange's local row, with what its record keeps that no column holds.
struct ExchangeRows: Equatable, Sendable {
    let id: String
    var columns: [String: SQLiteValue]
    /// The chat's start, when the exchange has no time of its own.
    var chatStartedAt: Double?
    /// `seq` and `createdAt` as the replica holds them: once acknowledged they stand (S), and a local
    /// renumbering (two devices appended at once, so this Mac moved one of them) is not a change.
    var heldSeq: SyncJSON?
    var heldCreatedAt: SyncJSON?
    /// Fields whose satellite this Mac waits for: held back from the encoder.
    var waiting: Set<String>
    /// Whether its chat is of a private kind: only then are `score` and `grading` encoded (D20).
    var chatIsPrivate: Bool
}

/// The Exchange record's projection (§3.5.14). An exchange is sent once it holds anything: a question
/// (the learner's message, the tutor's prompt, a walk step, an assistant turn kept as a question), an
/// answer or a reply. No row ever holds a fragment: a turn's text is written once, when it has finished
/// streaming (a prompt by `addReviewPrompt`, a reply by `answerPendingReviewExchange`, the Stop path
/// with what had streamed), and the learner's message persisted before the reply is final as it stands.
/// What the turn gains later (the learner's answer to a prompt, the reply, a grade) goes as an update of
/// the fields that changed. Only a truly empty turn (no question, answer or reply) never reaches CloudKit:
/// its rows are dropped until the write that fills it, which sends it whole. Once the replica holds an
/// exchange, its row is encoded as it is. Any string over 32 KiB is spilled through the codec
/// (`ChatSatellites`). Grading and scores are `privateKindsOnly` (D20): encoded only for an exchange of
/// a private chat, and `SpaceWriteGuard` leaves them out of a space besides. The rating is the member's
/// `Mark(rated)` (`MarkProjection`).
struct ExchangeProjection: RecordProjection {
    var recordType: SyncRecordType { .exchange }

    static let columns = [
        "session_id", "sequence_number", "question", "user_answer", "evaluation", "score", "source_refs", "knowledge_note",
        "answered_at", "context_content", "idea_coverage", "question_verdict", "operation", "steer", "anchor_json", "cited_source_ids",
    ]

    static let textFields = [
        ("question", "question"), ("userAnswer", "user_answer"), ("evaluation", "evaluation"), ("knowledgeNote", "knowledge_note"),
        ("contextText", "context_content"),
    ]

    var tables: [ProjectedTable] {
        [
            .records("review_exchanges", type: .exchange, syncedColumns: Array(Self.columns.dropFirst()), parents: [
                LocalParent("session_id", references: "review_sessions", type: .chat, role: .container),
            ]),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "review_exchanges", names) }

    var feeds: [String: FieldFeed] {
        [
            "chatID": Self.column("session_id"), "seq": Self.column("sequence_number"), "createdAt": Self.column("answered_at"),
            "question": Self.column("question"), "userAnswer": Self.column("user_answer"), "evaluation": Self.column("evaluation"),
            "score": Self.column("score"), "sourceRefs": Self.column("source_refs"), "citedSourceIDs": Self.column("cited_source_ids"),
            "knowledgeNote": Self.column("knowledge_note"), "answeredAt": Self.column("answered_at"),
            "contextText": Self.column("context_content"), "contextAnchor": Self.column("anchor_json"),
            "grading": Self.column("idea_coverage", "question_verdict", "operation", "steer"),
        ]
    }

    /// A deleted exchange deletes the record.
    var missingRow: MissingRowOutcome { .delete }
    var priority: OutboxPriority { .other }

    /// Whether an exchange holds anything to show, a question, an answer or a reply (§3.5.14): only then
    /// is it sent. Every turn's text is final once written, so this is the whole rule.
    static func isComplete(_ columns: [String: SQLiteValue]) -> Bool {
        ["question", "user_answer", "evaluation"].contains { columns[$0]?.textValue.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
    }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ExchangeRows? {
        try Self.loadRows(localID: record.localID, wireID: record.wireID, zoneKey: record.zoneKey, connection: connection)
    }

    static func loadRows(localID: String, wireID: String? = nil, zoneKey: String = ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue),
                         connection: SQLiteConnection) throws -> ExchangeRows? {
        var read: (columns: [String: SQLiteValue], started: Double?)?
        try connection.query("""
            SELECT \(Self.columns.map { "e.\($0)" }.joined(separator: ", ")), s.started_at
            FROM review_exchanges e LEFT JOIN review_sessions s ON s.id = e.session_id WHERE e.id = ?
        """, [.text(localID)]) { row in
            var columns: [String: SQLiteValue] = [:]
            for (index, column) in Self.columns.enumerated() { columns[column] = OutboxFeeder.value(row, Int32(index)) }
            read = (columns, row.real(Int32(Self.columns.count)))
        }
        guard let read else { return nil }
        let id = wireID ?? localID
        let held = try HeldRecord.envelope(.exchange, id, preferring: zoneKey, connection: connection)
        // An empty turn never encodes: until it holds something, its rows read as no record to send.
        guard held != nil || isComplete(read.columns) else { return nil }
        let chatID = read.columns["session_id"]?.textValue ?? ""
        let chatKind = try connection.scalarText("SELECT chat_kind FROM review_sessions WHERE id = ?", [.text(chatID)]).flatMap(ChatKind.init(rawValue:))
            ?? ChatEvidence.load(chatID: chatID, connection: connection).map(ChatKindClassifier.kind(of:))
        let isPrivate = chatKind?.isPrivate ?? false
        if !isPrivate, read.columns["score"].map({ $0 != .null }) == true || read.columns["idea_coverage"].map({ $0 != .null }) == true {
            ChatProjection.logger.info("Exchange \(localID, privacy: .private) keeps its score and grading local: its chat is not a private kind")
        }
        return ExchangeRows(
            id: id, columns: read.columns, chatStartedAt: read.started, heldSeq: held?.fields["seq"], heldCreatedAt: held?.fields["createdAt"],
            waiting: Set(try ChatSatellites.waiting(.exchange, localID, connection: connection).keys), chatIsPrivate: isPrivate
        )
    }

    static func encodeRows(_ rows: ExchangeRows) -> [String: SyncJSON] {
        func text(_ column: String) -> String? { rows.columns[column]?.textValue }
        func real(_ column: String) -> Double? { rows.columns[column]?.realValue }
        func parsed(_ column: String) -> SyncJSON? { text(column).flatMap { try? SyncJSON(parsing: Data($0.utf8)) } }

        var fields: [String: SyncJSON] = ["chatID": .string(text("session_id") ?? "")]
        if case .integer(let sequence)? = rows.columns["sequence_number"] { fields["seq"] = rows.heldSeq ?? SyncJSON(sequence) }
        if let created = rows.heldCreatedAt ?? (real("answered_at") ?? rows.chatStartedAt).map({ SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) }) {
            fields["createdAt"] = created
        }
        for (field, column) in textFields where !rows.waiting.contains(field) {
            if let value = text(column) {
                fields[field] = ChatSatellites.string(value, field: field, type: .exchange, owner: rows.id)
            } else {
                fields[field] = field == "question" ? .string("") : .null
            }
        }
        if rows.chatIsPrivate { fields["score"] = real("score").map { .number($0) } ?? .null }
        fields["sourceRefs"] = parsed("source_refs").flatMap { $0.arrayValue.map { .array($0.filter { $0.stringValue != nil }) } } ?? .null
        if let cited = parsed("cited_source_ids"), cited.arrayValue != nil { fields["citedSourceIDs"] = cited }
        fields["answeredAt"] = real("answered_at").map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } ?? .null
        if let anchor = parsed("anchor_json"), anchor.objectValue != nil { fields["contextAnchor"] = anchor }
        if rows.chatIsPrivate {
            fields["grading"] = grading(coverage: text("idea_coverage"), verdict: text("question_verdict"), operation: text("operation"), steer: text("steer")) ?? .null
        }
        return fields
    }

    /// `Exchange.grading` from the memory review's columns: the idea coverage (`[{ideaID, status}]`; the
    /// column keeps `idea_id`), the verdict, the operation and the steer. Nil when none is set.
    static func grading(coverage: String?, verdict: String?, operation: String?, steer: String?) -> SyncJSON? {
        var object: [String: SyncJSON] = [:]
        if let coverage, !coverage.isEmpty {
            let entries = MemoryIdeaCoverage.decode(coverage)
            object["ideaCoverage"] = .array(entries.map { .object(["ideaID": .string($0.ideaID), "status": .string($0.status.rawValue)]) })
        }
        if let verdict { object["questionVerdict"] = .string(verdict) }
        if let operation { object["operation"] = .string(operation) }
        if let steer { object["steer"] = .string(steer) }
        return object.isEmpty ? nil : .object(object)
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // A space's exchanges are the space packages'.
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let id = record.localID
        var local: [String: String?]?
        try connection.query("SELECT session_id, question, user_answer, evaluation, knowledge_note, context_content FROM review_exchanges WHERE id = ?", [.text(id)]) { row in
            local = ["session_id": row.text(0), "question": row.text(1), "user_answer": row.text(2), "evaluation": row.text(3),
                     "knowledge_note": row.text(4), "context_content": row.text(5)]
        }
        let chatID = (local?["session_id"] ?? nil) ?? fields["chatID"]?.stringValue ?? ""
        let chatLocalID = try connection.scalarText(
            "SELECT local_id FROM ck_identity WHERE record_type = ? AND wire_id = ? AND zone_key = ?",
            [.text(SyncRecordType.chat.rawValue), .text(chatID), .text(record.zoneKey)]
        ) ?? chatID
        guard try connection.scalarInteger("SELECT COUNT(*) FROM review_sessions WHERE id = ?", [.text(chatLocalID)]) == 1 else {
            return .waiting([WaitingParent(type: .chat, wireID: chatID)])
        }

        var waiting = try ChatSatellites.waiting(.exchange, id, connection: connection)
        var values: [String: SQLiteValue] = [:]
        for (field, column) in Self.textFields {
            guard let value = fields[field] else { continue }
            if case .text(let text) = ChatSatellites.take(value, field: field, local: local?[column] ?? nil, waiting: &waiting) {
                values[column] = .text(text)
            }
        }
        if values["question"] == .null { values["question"] = .text("") }
        if let score = fields["score"] { values["score"] = .real(score.numberValue) }
        if let refs = fields["sourceRefs"] {
            values["source_refs"] = refs.arrayValue.map { .text(String(decoding: SyncJSON.array($0).serialized(), as: UTF8.self)) } ?? .null
        }
        if let cited = fields["citedSourceIDs"] {
            values["cited_source_ids"] = cited.arrayValue.map { .text(String(decoding: SyncJSON.array($0).serialized(), as: UTF8.self)) } ?? .null
        }
        if let answered = fields["answeredAt"] { values["answered_at"] = .real(answered.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }) }
        if let anchor = fields["contextAnchor"] {
            values["anchor_json"] = anchor.objectValue != nil ? .text(String(decoding: anchor.serialized(), as: UTF8.self)) : .null
        }
        if let grading = fields["grading"] {
            let object = grading.objectValue
            let coverage = object?["ideaCoverage"]?.arrayValue?.compactMap { entry -> MemoryIdeaCoverage? in
                guard let idea = entry["ideaID"]?.stringValue, let status = entry["status"]?.stringValue.flatMap(MemoryIdeaCoverage.Status.init(rawValue:)) else { return nil }
                return MemoryIdeaCoverage(ideaID: idea, status: status)
            }
            values["idea_coverage"] = .text(coverage.flatMap(MemoryIdeaCoverage.encode))
            values["question_verdict"] = .text(object?["questionVerdict"]?.stringValue)
            values["operation"] = .text(object?["operation"]?.stringValue)
            values["steer"] = .text(object?["steer"]?.stringValue)
        }

        if local == nil {
            // Two devices appending at once both choose the next number: the later one here takes the
            // next free one, and its record keeps the seq it was sent with.
            let wanted = fields["seq"]?.int64Value ?? 0
            let taken = try connection.scalarInteger(
                "SELECT COUNT(*) FROM review_exchanges WHERE session_id = ? AND sequence_number = ?", [.text(chatLocalID), .integer(wanted)]
            ) ?? 0
            let sequence = wanted > 0 && taken == 0 ? wanted : (try connection.scalarInteger(
                "SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM review_exchanges WHERE session_id = ?", [.text(chatLocalID)]
            ) ?? 1)
            values["question"] = values["question"] ?? .text("")
            values["sequence_number"] = .integer(sequence)
            values["session_id"] = .text(chatLocalID)
            let names = ["id"] + values.keys.sorted()
            try connection.execute(
                "INSERT INTO review_exchanges (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + values.keys.sorted().compactMap { values[$0] }
            )
        } else if !values.isEmpty {
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE review_exchanges SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(id)]
            )
        }
        try ChatSatellites.save(waiting, .exchange, id, connection: connection)
        try ChatProjection.recount(chatID: chatLocalID, connection: connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        let chatID = try connection.scalarText("SELECT session_id FROM review_exchanges WHERE id = ?", [.text(record.localID)])
        try ChatSatellites.forget(.exchange, record.localID, connection: connection)
        try connection.execute("DELETE FROM review_exchanges WHERE id = ?", [.text(record.localID)])
        if let chatID { try ChatProjection.recount(chatID: chatID, connection: connection) }
    }
}
