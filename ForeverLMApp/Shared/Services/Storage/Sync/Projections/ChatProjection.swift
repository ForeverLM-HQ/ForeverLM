import Foundation
import OSLog

extension SQLiteValue {
    /// The column read as a number: a real, or an integer widened; nil for null, text and blobs.
    var realValue: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
}

// MARK: - A chat's kind, context mode and evidence (docs/cloudkit-schema-design.md §3.5.13, D50, §10)

/// What `ChatKindClassifier` reads about a chat, gathered from the store by one query: the activation
/// classifies every chat with it, and the encoder classifies a chat no generation-2 creation site
/// stamped (a row written before the activation's derivation, or by a writer that sets no kind).
enum ChatEvidence {
    /// One row per chat: id, generation-1 kind, team snapshot, overall score, card ids, a graded
    /// exchange, a walk's progress naming it, and the text of any exchange that holds a walkthrough step
    /// tag (checked in Swift by `WalkthroughStepTurn.marker(in:)`, which drops a tag missing attributes).
    static let select = """
        SELECT s.id, s.kind,
            COALESCE(s.team_id, '') <> '',
            s.overall_score IS NOT NULL,
            CASE WHEN json_valid(s.card_ids) THEN json_array_length(s.card_ids) ELSE 0 END > 0,
            EXISTS (SELECT 1 FROM review_exchanges e WHERE e.session_id = s.id
                AND (e.score IS NOT NULL OR COALESCE(e.idea_coverage, '') NOT IN ('', '[]'))),
            EXISTS (SELECT 1 FROM walkthrough_progress w WHERE json_valid(w.progress_json)
                AND json_extract(w.progress_json, '$.chat_session_id') = s.id),
            (SELECT group_concat(COALESCE(e.question, '') || char(10) || COALESCE(e.evaluation, ''), char(10))
                FROM review_exchanges e WHERE e.session_id = s.id
                AND (instr(e.question, '<\(WalkthroughStepTurn.tagName)') > 0 OR instr(e.evaluation, '<\(WalkthroughStepTurn.tagName)') > 0))
        FROM review_sessions s
        """

    static func evidence(_ row: SQLiteRow) -> ChatKindClassifier.Evidence {
        ChatKindClassifier.Evidence(
            id: row.text(0) ?? "",
            kind: row.text(1),
            isTeamSnapshot: row.integer(2) == 1,
            isNamedByWalkthroughProgress: row.integer(6) == 1,
            holdsWalkthroughStep: row.text(7).map { WalkthroughStepTurn.marker(in: $0) != nil } ?? false,
            hasOverallScore: row.integer(3) == 1,
            hasCardIDs: row.integer(4) == 1,
            hasGradedExchange: row.integer(5) == 1
        )
    }

    /// One chat's evidence; nil when its row is gone.
    static func load(chatID: String, connection: SQLiteConnection) throws -> ChatKindClassifier.Evidence? {
        var evidence: ChatKindClassifier.Evidence?
        try connection.query(select + " WHERE s.id = ?", [.text(chatID)]) { evidence = Self.evidence($0) }
        return evidence
    }
}

/// `Chat.contextMode` (§3.5.13) from what a chat holds, the rule the web writes by: `explicit`
/// when it holds sources of its own, `notebook` when it is filed in a notebook and holds none, else
/// `none`. The activation derives it for every chat; a generation-2 creation site writes it.
enum ChatContextModeRule {
    static let values = Set(SyncSchema.enums["ChatContextMode"] ?? [])

    static func mode(holdsSources: Bool, filed: Bool) -> String {
        holdsSources ? "explicit" : filed ? "notebook" : "none"
    }

    /// The SQL of the rule over a `review_sessions` row named `s`.
    static let sql = """
        CASE
            WHEN EXISTS (SELECT 1 FROM review_session_sources r WHERE r.session_id = s.id)
                OR (CASE WHEN json_valid(s.source_ids) THEN json_array_length(s.source_ids) ELSE 0 END) > 0 THEN 'explicit'
            WHEN COALESCE(s.goal_id, '') <> '' AND EXISTS (SELECT 1 FROM learning_goals g WHERE g.id = s.goal_id) THEN 'notebook'
            ELSE 'none'
        END
        """
}

// MARK: - Satellites a chat's records name (§3.2 rule 8, §3.5.13 `briefing`)

/// The satellites the chat records point at, laid out from the rows as `BlobStore.upload` lays a body
/// out on a native client (gzip, owned by the record), so their bytes are the rows' at any time and
/// the uploader needs no staged copy: a memory review's or a quiz sitting's `briefing`, and any string
/// field over 32 KiB, spilled into a `field.<name>` satellite with `{"$file": FileRef}` in its place
/// (a pasted chapter in a question, a long reply).
///
/// An inbound FileRef whose bytes this Mac does not hold (another device's new text) is remembered in
/// `ck_backfill_queue` (kind `chatSatellites`, target `<type>:<id>`, the wanted FileRefs by field) for
/// the satellite reader, and the encoder holds that field back meanwhile, so a local edit never
/// sends the old text over the new. `received` writes the fetched text in and forgets the wish.
enum ChatSatellites {
    static let queueKind = "chatSatellites"
    static let briefingRole = "briefing"

    static func fieldRole(_ field: String) -> String { "field.\(field)" }

    static func target(_ type: SyncRecordType, _ id: String) -> String { "\(type.rawValue):\(id)" }

    /// A text body laid out as a gzip satellite of `owner`, and its stored bytes.
    static func layout(owner: String, role: String, mime: String, text: String) -> (file: FileRef, stored: Data)? {
        let satellite = SourceLocalSatellite(map: .files, role: role, mime: mime, encoding: .gzip, body: Data(text.utf8), localPath: nil, input: nil)
        return try? SourceSatelliteLayout.layout(satellite, owner: owner)
    }

    /// A string field's wire value: the text itself, or its spill marker when it is over 32 KiB.
    static func string(_ text: String, field: String, type: SyncRecordType, owner: String) -> SyncJSON {
        guard SyncEnvelope.spills(type: type, field: field, utf8Count: text.utf8.count),
              let file = layout(owner: owner, role: fieldRole(field), mime: "text/plain", text: text)?.file
        else { return .string(text) }
        return SyncEnvelope.spillMarker(file)
    }

    /// A chat's briefing as its FileRef; nil for none.
    static func briefing(chatID: String, text: String?) -> FileRef? {
        guard let text, !text.isEmpty else { return nil }
        return layout(owner: chatID, role: briefingRole, mime: "text/plain", text: text)?.file
    }

    /// The satellites a record's fields name with the bytes to upload, before the record is sent
    /// (bytes before pointer, §3.5.30 rule 2). The texts are the ones the fields were encoded from.
    static func uploads(fields: [String: SyncJSON], texts: [String: String]) -> [(file: FileRef, stored: Data)] {
        fields.keys.sorted().compactMap { field in
            guard let value = fields[field], let text = texts[field] else { return nil }
            let file = SyncEnvelope.spilledFile(value) ?? (field == "briefing" ? FileRef(json: value) : nil)
            guard let file, let laid = layout(owner: file.owner, role: file.role, mime: file.mime ?? "text/plain", text: text),
                  laid.file.hash == file.hash else { return nil }
            return laid
        }
    }

    // MARK: Inbound

    /// What an inbound text field gives a local column.
    enum Take: Equatable {
        /// Write this (nil clears the column).
        case text(String?)
        /// Leave the column as it is: its bytes are the satellite's, or the satellite is waited for.
        case keep
    }

    /// An inbound string field: a plain string or a clear as it is; a spilled one keeps the local text
    /// when its bytes are the satellite's, else it is waited for. `isFile` reads the value as a bare
    /// FileRef (`briefing`) rather than a spill marker.
    static func take(_ value: SyncJSON, field: String, local: String?, isFile: Bool = false, waiting: inout [String: SyncJSON]) -> Take {
        let file = isFile ? FileRef(json: value) : SyncEnvelope.spilledFile(value)
        guard let file else {
            waiting[field] = nil
            if value.isNull { return .text(nil) }
            return value.stringValue.map { .text($0) } ?? .keep
        }
        if let local, SyncIdentity.sha256Hex(Data(local.utf8)) == file.hash {
            waiting[field] = nil
        } else {
            waiting[field] = file.value
        }
        return .keep
    }

    /// The FileRefs this Mac waits to fetch for a record, by field.
    static func waiting(_ type: SyncRecordType, _ id: String, connection: SQLiteConnection) throws -> [String: SyncJSON] {
        let json = try connection.scalarText(
            "SELECT payload_json FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(target(type, id))]
        )
        return json.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
    }

    static func save(_ waiting: [String: SyncJSON], _ type: SyncRecordType, _ id: String, connection: SQLiteConnection) throws {
        guard !waiting.isEmpty else { return try forget(type, id, connection: connection) }
        try connection.execute("""
            INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET payload_json = excluded.payload_json, attempts = 0, last_error = NULL
        """, [
            .text(queueKind), .text(target(type, id)), .text(String(decoding: SyncJSON.object(waiting).serialized(), as: UTF8.self)),
            .real(Date().timeIntervalSinceReferenceDate),
        ])
    }

    static func forget(_ type: SyncRecordType, _ id: String, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(target(type, id))])
    }

    /// The local column each text field is held in.
    static func column(_ type: SyncRecordType, _ field: String) -> (table: String, column: String)? {
        switch (type, field) {
        case (.chat, "title"): return ("review_sessions", "topic")
        case (.chat, "summary"): return ("review_sessions", "summary")
        case (.chat, "briefing"): return ("review_sessions", "briefing")
        case (.exchange, "question"): return ("review_exchanges", "question")
        case (.exchange, "userAnswer"): return ("review_exchanges", "user_answer")
        case (.exchange, "evaluation"): return ("review_exchanges", "evaluation")
        case (.exchange, "knowledgeNote"): return ("review_exchanges", "knowledge_note")
        case (.exchange, "contextText"): return ("review_exchanges", "context_content")
        default: return nil
        }
    }

    /// The satellite reader's half: the fetched text of `field` written into the record's row, and the
    /// wish forgotten. Runs under the apply guard, like any projection write. A body whose hash is not
    /// the one waited for (an older version) is not written.
    static func received(_ body: Data, field: String, _ type: SyncRecordType, _ id: String, connection: SQLiteConnection) throws {
        var waiting = try self.waiting(type, id, connection: connection)
        guard let wanted = waiting[field].flatMap(FileRef.init(json:)), wanted.hash == SyncIdentity.sha256Hex(body),
              let target = column(type, field) else { return }
        try connection.execute(
            "UPDATE \(target.table) SET \(target.column) = ? WHERE id = ?", [.text(String(decoding: body, as: UTF8.self)), .text(id)]
        )
        waiting[field] = nil
        try save(waiting, type, id, connection: connection)
    }
}

// MARK: - The held record

/// The envelope the replica holds for a record, in whichever zone holds it (the personal library's
/// first): what a field with no local column, or with a lossy one, keeps as the wire has it.
enum HeldRecord {
    static func envelope(_ type: SyncRecordType, _ wireID: String, preferring zoneKey: String, connection: SQLiteConnection) throws -> SyncEnvelope? {
        var payload: Data?
        try connection.query("""
            SELECT payload FROM ck_records WHERE record_type = ? AND wire_id = ?
            ORDER BY CASE WHEN zone_key = ? THEN 0 ELSE 1 END, zone_key LIMIT 1
        """, [.text(type.rawValue), .text(wireID), .text(zoneKey)]) { payload = $0.blob(0) }
        return try payload.map { try SyncEnvelope(storedPayload: $0) }
    }
}

// MARK: - The Chat record

/// A chat's local rows: its `review_sessions` row, its own sources (`review_session_sources`), the Doc
/// passages it was opened on (`artifact_chat_links`) and the time of its last exchange.
struct ChatRows: Equatable, Sendable {
    struct DocLink: Equatable, Sendable {
        let id: String
        let artifactID: String
        let anchorRevision: String
        let start: Int64
        let end: Int64
        let quote: String
        let sectionTitle: String
        let createdAt: Double
    }

    let id: String
    var columns: [String: SQLiteValue]
    var evidence: ChatKindClassifier.Evidence
    /// The notebook the chat is filed in: its `goal_id` when that is a notebook, a Goal's notebook, nil
    /// when it names neither (a dangling id).
    var notebookID: String?
    var contextSourceIDs: [String]
    var docLinks: [DocLink]
    var lastAnsweredAt: Double?
    /// Fields whose satellite this Mac waits for: held back from the encoder.
    var waiting: Set<String>
    /// The status the replica holds, kept while the row's status still reads as it.
    var heldStatus: String?
}

/// The Chat record's projection (§3.5.13). Exchanges are their own records; the number of them is
/// counted on read. A score is encoded only for a chat of a private kind (D20, `privateKindsOnly`): a
/// `chat` that holds one (an import's append scored it) keeps it in its local row, and the log names
/// it, so it can never reach a space and no change of it waits in the outbox (R5-m1, R6-m10). Which sources' text a chat loaded into its prompt (`loaded_source_ids`) stays local
/// to this Mac, as today. `kind` is `chat_kind`, which the activation and every generation-2 creation
/// site write; a row with none is classified from its evidence (D50). Today's `kind` column keeps its
/// generation-1 meaning. Ratings are the member's `Mark(rated)` (`MarkProjection`), never here.
struct ChatProjection: RecordProjection {
    var recordType: SyncRecordType { .chat }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ChatProjection")

    static let columns = [
        "topic", "started_at", "ended_at", "status", "overall_score", "summary", "source_ids", "card_ids",
        "model_provider", "model_id", "model_effort", "model_speed", "goal_id", "kind", "briefing", "team_id",
        "chat_kind", "marks_reviewed", "context_mode",
    ]

    /// A table whose rows file something under the chat, by its `session_id`.
    private static func childTable(
        _ name: String, localKey: [String], syncedColumns: [String], parents: [LocalParent] = [], element: String?
    ) -> ProjectedTable {
        ProjectedTable(
            name, localKey: localKey, keyColumns: ["session_id"], syncedColumns: syncedColumns,
            parents: [LocalParent("session_id", references: "review_sessions", type: .chat, role: .container)] + parents,
            elementColumn: element, recordTypes: [.chat],
            record: { values in values["session_id"]?.textValue.map { RowRecord(type: .chat, localID: $0, personalID: $0) } },
            localIDSQL: { "\($0).session_id" }, personalIDSQL: { "\($0).session_id" }
        )
    }

    var tables: [ProjectedTable] {
        [
            .records("review_sessions", type: .chat, syncedColumns: Self.columns),
            // A source's row that goes with the source (a cascade) is not a removal from the set (§5.7).
            Self.childTable("review_session_sources", localKey: ["session_id", "source_id"], syncedColumns: [],
                            parents: [LocalParent("source_id", references: "sources", type: .source, role: .item)], element: "source_id"),
            Self.childTable("artifact_chat_links", localKey: ["id"], syncedColumns: [
                "artifact_id", "anchor_revision", "anchor_start", "anchor_end", "anchor_quote", "section_title", "created_at",
            ], element: "id"),
            // An exchange moves the chat's `editedAt`.
            Self.childTable("review_exchanges", localKey: ["id"], syncedColumns: ["answered_at"], element: nil),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "review_sessions", names) }

    var feeds: [String: FieldFeed] {
        [
            "kind": Self.column("chat_kind", "kind", "team_id", "overall_score", "card_ids"),
            "notebookID": Self.column("goal_id"),
            "quizID": .rowExistence(table: "review_sessions"),
            "title": Self.column("topic"),
            "status": Self.column("status"),
            "model": Self.column("model_provider", "model_id", "model_effort", "model_speed"),
            "contextMode": .anyOf([Self.column("context_mode", "goal_id", "source_ids"), .rowExistence(table: "review_session_sources")]),
            "contextSourceIDs": .elementRows(table: "review_session_sources"),
            "cardIDs": Self.column("card_ids"),
            "docLinks": .elementRows(table: "artifact_chat_links"),
            "briefing": Self.column("briefing"),
            "summary": Self.column("summary"),
            "marksReviewed": Self.column("marks_reviewed"),
            "overallScore": Self.column("overall_score"),
            "readOnly": Self.column("team_id"),
            "createdAt": Self.column("started_at"),
            "editedAt": .anyOf([Self.column("started_at", "ended_at"), .columns(table: "review_exchanges", ["answered_at"])]),
        ]
    }

    /// A deleted chat deletes the record; its Exchanges go with it.
    var missingRow: MissingRowOutcome { .delete }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ChatRows? {
        try Self.loadRows(localID: record.localID, wireID: record.wireID, zoneKey: record.zoneKey, connection: connection)
    }

    static func loadRows(localID: String, wireID: String? = nil, zoneKey: String = ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue),
                         connection: SQLiteConnection) throws -> ChatRows? {
        var columns: [String: SQLiteValue]?
        try connection.query("SELECT \(Self.columns.joined(separator: ", ")) FROM review_sessions WHERE id = ?", [.text(localID)]) { row in
            var read: [String: SQLiteValue] = [:]
            for (index, column) in Self.columns.enumerated() { read[column] = OutboxFeeder.value(row, Int32(index)) }
            columns = read
        }
        guard let columns, let evidence = try ChatEvidence.load(chatID: localID, connection: connection) else { return nil }

        let notebookID = try Self.notebookID(goalID: columns["goal_id"]?.textValue, connection: connection)
        var sources: [String] = []
        try connection.query("SELECT source_id FROM review_session_sources WHERE session_id = ? ORDER BY source_id", [.text(localID)]) { row in
            if let id = row.text(0) { sources.append(id) }
        }
        var links: [ChatRows.DocLink] = []
        try connection.query("""
            SELECT id, artifact_id, anchor_revision, anchor_start, anchor_end, anchor_quote, section_title, created_at
            FROM artifact_chat_links WHERE session_id = ? ORDER BY id
        """, [.text(localID)]) { row in
            links.append(ChatRows.DocLink(
                id: row.text(0) ?? "", artifactID: row.text(1) ?? "", anchorRevision: row.text(2) ?? "", start: row.integer(3) ?? 0,
                end: row.integer(4) ?? 0, quote: row.text(5) ?? "", sectionTitle: row.text(6) ?? "", createdAt: row.real(7) ?? 0
            ))
        }
        var lastAnswered: Double?
        try connection.query("SELECT MAX(answered_at) FROM review_exchanges WHERE session_id = ?", [.text(localID)]) { lastAnswered = $0.real(0) }
        let id = wireID ?? localID
        let held = try HeldRecord.envelope(.chat, id, preferring: zoneKey, connection: connection)
        if columns["overall_score"] != .null, columns["overall_score"] != nil,
           !(columns["chat_kind"]?.textValue.flatMap(ChatKind.init(rawValue:)) ?? ChatKindClassifier.kind(of: evidence)).isPrivate {
            logger.info("Chat \(localID, privacy: .private) keeps its overallScore local: it is not a private kind")
        }
        return ChatRows(
            id: id, columns: columns, evidence: evidence, notebookID: notebookID, contextSourceIDs: sources, docLinks: links,
            lastAnsweredAt: lastAnswered, waiting: Set(try ChatSatellites.waiting(.chat, localID, connection: connection).keys),
            heldStatus: held?.fields["status"]?.stringValue
        )
    }

    /// The notebook a chat filed under `goalID` is in: the notebook itself, a Goal's notebook, nil for
    /// none or a dangling id.
    static func notebookID(goalID: String?, connection: SQLiteConnection) throws -> String? {
        guard let goalID, !goalID.isEmpty else { return nil }
        var notebookID: String?
        try connection.query("SELECT entity_kind, kind, parent_notebook_id, end_at FROM learning_goals WHERE id = ?", [.text(goalID)]) { row in
            let kind = row.text(0) ?? LearningGoalEntityKind.kind(kind: row.text(1), parentNotebookID: row.text(2), endAt: row.real(3) ?? 0)
            notebookID = kind == LearningGoalEntityKind.notebook ? goalID : row.text(2).flatMap { $0.isEmpty ? nil : $0 }
        }
        return notebookID
    }

    /// The wire status of a local one: a chat in progress is `active`, any other `ended`.
    static func wireStatus(_ local: String?) -> String { local == "active" ? "active" : "ended" }

    /// The local status of a wire one.
    static func localStatus(_ wire: String) -> String { wire == "active" ? "active" : "completed" }

    /// The kind a chat's rows give: its `chat_kind`, else the classifier's (D50).
    static func kind(_ rows: ChatRows) -> ChatKind {
        rows.columns["chat_kind"]?.textValue.flatMap(ChatKind.init(rawValue:)) ?? ChatKindClassifier.kind(of: rows.evidence)
    }

    static func encodeRows(_ rows: ChatRows) -> [String: SyncJSON] {
        func text(_ column: String) -> String? { rows.columns[column]?.textValue }
        func real(_ column: String) -> Double? { rows.columns[column]?.realValue }
        func ms(_ seconds: Double) -> SyncJSON { SyncJSON(SyncTime.milliseconds(cocoaSeconds: seconds)) }

        var fields: [String: SyncJSON] = ["kind": .string(kind(rows).rawValue)]
        fields["notebookID"] = rows.notebookID.map { .string($0) } ?? .null
        if let quizID = CourseQuizSitting.quizID(inSessionID: rows.evidence.id) { fields["quizID"] = .string(quizID) }
        if !rows.waiting.contains("title") {
            fields["title"] = ChatSatellites.string(text("topic") ?? "", field: "title", type: .chat, owner: rows.id)
        }
        let status = wireStatus(text("status"))
        // An `archived` the replica holds reads locally as `completed`: it stays until the row moves.
        fields["status"] = .string(rows.heldStatus.map { localStatus($0) == localStatus(status) ? $0 : status } ?? status)
        if let provider = text("model_provider"), !provider.isEmpty, let model = text("model_id"), !model.isEmpty {
            var value: [String: SyncJSON] = ["provider": .string(provider), "id": .string(model)]
            if let effort = text("model_effort"), !effort.isEmpty { value["effort"] = .string(effort) }
            if let speed = text("model_speed"), !speed.isEmpty { value["speed"] = .string(speed) }
            fields["model"] = .object(value)
        } else {
            fields["model"] = .null
        }
        let held = KnowledgeStore.decodeJSONStringArray(text("source_ids"))
        let mode = text("context_mode").flatMap { ChatContextModeRule.values.contains($0) ? $0 : nil }
            ?? ChatContextModeRule.mode(holdsSources: !rows.contextSourceIDs.isEmpty || !held.isEmpty, filed: rows.notebookID != nil)
        fields["contextMode"] = .string(mode)
        fields["contextSourceIDs"] = .object(Dictionary(rows.contextSourceIDs.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first }))
        fields["cardIDs"] = .object(Dictionary(
            KnowledgeStore.decodeJSONStringArray(text("card_ids")).map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first }
        ))
        var links: [String: SyncJSON] = [:]
        for link in rows.docLinks {
            links[link.id] = .object([
                "artifactID": .string(link.artifactID), "anchorRevision": .string(link.anchorRevision), "start": SyncJSON(link.start),
                "end": SyncJSON(link.end), "quote": .string(link.quote), "sectionTitle": .string(link.sectionTitle), "createdAt": ms(link.createdAt),
            ])
        }
        fields["docLinks"] = .object(links)
        if !rows.waiting.contains("briefing") {
            fields["briefing"] = ChatSatellites.briefing(chatID: rows.id, text: text("briefing"))?.value ?? .null
        }
        if !rows.waiting.contains("summary") {
            fields["summary"] = text("summary").map { ChatSatellites.string($0, field: "summary", type: .chat, owner: rows.id) } ?? .null
        }
        if case .integer(let flag)? = rows.columns["marks_reviewed"] { fields["marksReviewed"] = .bool(flag != 0) }
        if kind(rows).isPrivate { fields["overallScore"] = real("overall_score").map { .number($0) } ?? .null }
        if rows.evidence.isTeamSnapshot { fields["readOnly"] = .bool(true) }
        let started = real("started_at") ?? 0
        fields["createdAt"] = ms(started)
        fields["editedAt"] = ms([started, real("ended_at"), rows.lastAnsweredAt].compactMap { $0 }.max() ?? started)
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // A space's chats are the space packages'.
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let id = record.localID
        var local: (goalID: String?, topic: String?, summary: String?, briefing: String?, cardIDs: [String], sourceIDs: [String], endedAt: Double?)?
        try connection.query("SELECT goal_id, topic, summary, briefing, card_ids, source_ids, ended_at FROM review_sessions WHERE id = ?", [.text(id)]) { row in
            local = (row.text(0), row.text(1), row.text(2), row.text(3), KnowledgeStore.decodeJSONStringArray(row.text(4)),
                     KnowledgeStore.decodeJSONStringArray(row.text(5)), row.real(6))
        }
        var waiting = try ChatSatellites.waiting(.chat, id, connection: connection)
        var values: [String: SQLiteValue] = [:]
        func takeText(_ field: String, column: String, current: String?, isFile: Bool = false) {
            guard let value = fields[field] else { return }
            if case .text(let text) = ChatSatellites.take(value, field: field, local: current, isFile: isFile, waiting: &waiting) {
                values[column] = .text(text)
            }
        }
        takeText("title", column: "topic", current: local?.topic)
        takeText("summary", column: "summary", current: local?.summary)
        takeText("briefing", column: "briefing", current: local?.briefing, isFile: true)
        if values["topic"] == .null { values["topic"] = .text("") }

        if let created = fields["createdAt"]?.int64Value { values["started_at"] = .real(SyncTime.cocoaSeconds(milliseconds: created)) }
        let edited = fields["editedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        if let status = fields["status"]?.stringValue {
            let localStatus = Self.localStatus(status)
            values["status"] = .text(localStatus)
            if localStatus == "active" {
                values["ended_at"] = .null
            } else if local?.endedAt == nil {
                values["ended_at"] = .real(edited)
            }
        }
        if let score = fields["overallScore"] { values["overall_score"] = .real(score.numberValue) }
        if let model = fields["model"] {
            let object = model.objectValue
            values["model_provider"] = .text(object?["provider"]?.stringValue)
            values["model_id"] = .text(object?["id"]?.stringValue)
            values["model_effort"] = .text(object?["effort"]?.stringValue)
            values["model_speed"] = .text(object?["speed"]?.stringValue)
        }
        if let notebook = fields["notebookID"] {
            let wanted = notebook.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            // A chat filed under a Goal stays filed there while the Goal's notebook is the record's.
            let current = try Self.notebookID(goalID: local?.goalID, connection: connection)
            if local == nil || current != wanted { values["goal_id"] = .text(wanted) }
        }
        if let kind = fields["kind"]?.stringValue, ChatKind(rawValue: kind) != nil { values["chat_kind"] = .text(kind) }
        if let flag = fields["marksReviewed"] { values["marks_reviewed"] = .integer(flag.boolValue.map { $0 ? 1 : 0 }) }
        if let mode = fields["contextMode"]?.stringValue, ChatContextModeRule.values.contains(mode) { values["context_mode"] = .text(mode) }

        // Card ids keep this Mac's order (a memory review's queue); new ones follow, sorted.
        if let cards = fields["cardIDs"]?.objectValue {
            let kept = (local?.cardIDs ?? []).filter { cards[$0]?.boolValue != false }
            let added = cards.filter { $0.value.boolValue == true && !kept.contains($0.key) }.map(\.key).sorted()
            values["card_ids"] = .text(KnowledgeStore.encodeJSONStringArray(kept + added))
        }
        var sourceIDs = local?.sourceIDs ?? []
        let sourceChanges = fields["contextSourceIDs"]?.objectValue ?? [:]
        sourceIDs.removeAll { sourceChanges[$0]?.boolValue == false }
        sourceIDs += sourceChanges.filter { $0.value.boolValue == true && !sourceIDs.contains($0.key) }.map(\.key).sorted()
        if !sourceChanges.isEmpty || local == nil { values["source_ids"] = .text(KnowledgeStore.encodeJSONStringArray(sourceIDs)) }

        if local == nil {
            values["topic"] = values["topic"] ?? .text("")
            values["started_at"] = values["started_at"] ?? .real(edited ?? Date().timeIntervalSinceReferenceDate)
            values["status"] = values["status"] ?? .text("completed")
            values["card_ids"] = values["card_ids"] ?? .text("[]")
            values["exchange_count"] = .integer(0)
            values["wire_id"] = .text(record.wireID)
            // Generation-1 readers know a chat's kind by this column and the id; a new row gets the
            // kinds they know.
            if let kind = fields["kind"]?.stringValue, ReviewSessionKind(rawValue: kind) != nil { values["kind"] = .text(kind) }
            let names = ["id"] + values.keys.sorted()
            try connection.execute(
                "INSERT INTO review_sessions (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + values.keys.sorted().compactMap { values[$0] }
            )
        } else if !values.isEmpty {
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE review_sessions SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(id)]
            )
        }

        for (sourceID, member) in sourceChanges.sorted(by: { $0.key < $1.key }) {
            if member.boolValue == true {
                // A source this Mac does not hold stays in `source_ids`; its row needs the source.
                try connection.execute(
                    "INSERT INTO review_session_sources (session_id, source_id) SELECT ?, id FROM sources WHERE id = ? ON CONFLICT DO NOTHING",
                    [.text(id), .text(sourceID)]
                )
            } else {
                try connection.execute("DELETE FROM review_session_sources WHERE session_id = ? AND source_id = ?", [.text(id), .text(sourceID)])
            }
        }
        try applyDocLinks(fields["docLinks"], chatID: id, connection: connection)
        try ChatSatellites.save(waiting, .chat, id, connection: connection)
        try Self.recount(chatID: id, connection: connection)
        return .projected
    }

    private func applyDocLinks(_ value: SyncJSON?, chatID: String, connection: SQLiteConnection) throws {
        guard let links = value?.objectValue else { return }
        for (linkID, link) in links.sorted(by: { $0.key < $1.key }) {
            guard let object = link.objectValue, let artifactID = object["artifactID"]?.stringValue else {
                try connection.execute("DELETE FROM artifact_chat_links WHERE id = ? AND session_id = ?", [.text(linkID), .text(chatID)])
                continue
            }
            let row: [SQLiteValue] = [
                .text(artifactID), .text(object["anchorRevision"]?.stringValue ?? ""), .integer(object["start"]?.int64Value ?? 0),
                .integer(object["end"]?.int64Value ?? 0), .text(object["quote"]?.stringValue ?? ""), .text(object["sectionTitle"]?.stringValue ?? ""),
                .real(object["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? Date().timeIntervalSinceReferenceDate),
            ]
            if try connection.scalarInteger("SELECT COUNT(*) FROM artifact_chat_links WHERE id = ?", [.text(linkID)]) == 1 {
                try connection.execute("""
                    UPDATE artifact_chat_links SET artifact_id = ?, anchor_revision = ?, anchor_start = ?, anchor_end = ?,
                        anchor_quote = ?, section_title = ?, created_at = ? WHERE id = ?
                """, row + [.text(linkID)])
            } else {
                // A passage this Mac already links under another id (UNIQUE) keeps its own row.
                try connection.execute("""
                    INSERT INTO artifact_chat_links (artifact_id, anchor_revision, anchor_start, anchor_end, anchor_quote, section_title,
                        created_at, id, session_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, row + [.text(linkID), .text(chatID)])
            }
        }
    }

    /// `exchange_count`, which every generation-1 reader reads, from the exchanges the chat holds.
    static func recount(chatID: String, connection: SQLiteConnection) throws {
        try connection.execute(
            "UPDATE review_sessions SET exchange_count = (SELECT COUNT(*) FROM review_exchanges WHERE session_id = ?) WHERE id = ?",
            [.text(chatID), .text(chatID)]
        )
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        var exchanges: [String] = []
        try connection.query("SELECT id FROM review_exchanges WHERE session_id = ?", [.text(record.localID)]) { row in
            if let id = row.text(0) { exchanges.append(id) }
        }
        for exchange in exchanges { try ChatSatellites.forget(.exchange, exchange, connection: connection) }
        try ChatSatellites.forget(.chat, record.localID, connection: connection)
        try connection.execute("DELETE FROM review_sessions WHERE id = ?", [.text(record.localID)])
    }
}

extension KnowledgeStore {
    /// A JSON array of strings, as the chat columns keep id lists; empty for NULL or anything else.
    static func decodeJSONStringArray(_ json: String?) -> [String] {
        guard let json, let values = (try? SyncJSON(parsing: Data(json.utf8)))?.arrayValue else { return [] }
        return values.compactMap(\.stringValue)
    }

    static func encodeJSONStringArray(_ values: [String]) -> String {
        String(decoding: SyncJSON.array(values.map { .string($0) }).serialized(), as: UTF8.self)
    }
}
