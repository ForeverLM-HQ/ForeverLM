import Foundation

// MARK: - The member's highlights (docs/cloudkit-schema-design.md §3.5.17)

/// One `source_highlights` row as the Highlight record reads it. Its times are Unix seconds, as the
/// table has always kept them (`SourceHighlight`); `source_id` is the source's wire id under generation
/// 2 (team copies' rows are re-keyed at the activation), so a highlight shows on the personal copy and
/// on every space copy of the work.
struct HighlightRow: Equatable, Sendable {
    var id: String
    var sourceID: String
    var pageIndex: Int64
    var geometryJSON: String
    var text: String
    var color: String
    var note: String?
    var createdAt: Double
    var updatedAt: Double
    var anchorPrefix: String?
    var anchorSuffix: String?
    var anchorOffset: Int64?
    var chatSessionID: String?
    var referencesJSON: String?
    var publicationUpdate: String?
    var publicationUpdateAt: Double?

    static let columns = [
        "source_id", "page_index", "quads_json", "text", "color", "note", "created_at", "updated_at", "anchor_prefix",
        "anchor_suffix", "anchor_offset", "chat_session_id", "references_json", "publication_update", "publication_update_at",
    ]

    static func load(_ id: String, connection: SQLiteConnection) throws -> HighlightRow? {
        var row: HighlightRow?
        try connection.query("SELECT \(columns.joined(separator: ", ")) FROM source_highlights WHERE highlight_id = ?", [.text(id)]) { values in
            row = HighlightRow(
                id: id, sourceID: values.text(0) ?? "", pageIndex: values.integer(1) ?? 0, geometryJSON: values.text(2) ?? "[]",
                text: values.text(3) ?? "", color: values.text(4) ?? SourceHighlightColor.default.rawValue, note: values.text(5),
                createdAt: values.real(6) ?? 0, updatedAt: values.real(7) ?? 0, anchorPrefix: values.text(8), anchorSuffix: values.text(9),
                anchorOffset: values.integer(10), chatSessionID: values.text(11), referencesJSON: values.text(12),
                publicationUpdate: values.text(13), publicationUpdateAt: values.real(14)
            )
        }
        return row
    }

    /// Writes the row whole (an upsert, so the outbox records only the columns that changed).
    func save(_ connection: SQLiteConnection) throws {
        let values: [SQLiteValue] = [
            .text(id), .text(sourceID), .integer(pageIndex), .text(geometryJSON), .text(text), .text(color), .text(note), .real(createdAt),
            .real(updatedAt), .text(anchorPrefix), .text(anchorSuffix), .integer(anchorOffset), .text(chatSessionID), .text(referencesJSON),
            .text(publicationUpdate), .real(publicationUpdateAt),
        ]
        try connection.execute("""
            INSERT INTO source_highlights (highlight_id, \(Self.columns.joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))
            ON CONFLICT(highlight_id) DO UPDATE SET \(Self.columns.map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
        """, values)
    }
}

/// The Highlight record's projection (§3.5.17): private to the member, keyed by the existing highlight
/// id, and never deleted because its source went (D18: `source_highlights` has no foreign key since
/// schema 154, and a generation-2 source delete keeps the row).
///
/// The locator is the one the web writes (`library-mutations-v2.js`): `{t: "pdf", page, quads}` for a
/// PDF mark, with the Mac's quads as they are, else `{t: "text"}`; both carry the text anchor
/// (`offset`, `len`, `quote`, `prefix`, `suffix`), and a mark on pictures its `images`. `refs` holds
/// the cited references and the since-publication update (`publicationUpdateAt` in ms). `editedAt` is
/// the row's `updated_at`.
struct HighlightProjection: RecordProjection {
    var recordType: SyncRecordType { .highlight }

    var tables: [ProjectedTable] {
        [.records("source_highlights", type: .highlight, idColumn: "highlight_id", syncedColumns: HighlightRow.columns)]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "source_highlights", names) }

    var feeds: [String: FieldFeed] {
        [
            "sourceID": Self.column("source_id"),
            "locator": Self.column("page_index", "quads_json", "text", "anchor_prefix", "anchor_suffix", "anchor_offset"),
            "text": Self.column("text"), "color": Self.column("color"), "note": Self.column("note"),
            "chatID": Self.column("chat_session_id"),
            "refs": Self.column("references_json", "publication_update", "publication_update_at"),
            "createdAt": Self.column("created_at"), "editedAt": Self.column("updated_at"),
        ]
    }

    /// A highlight the learner deleted here is deleted; a source deleted here never takes it (the row stays).
    var missingRow: MissingRowOutcome { .delete }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> HighlightRow? {
        try HighlightRow.load(record.wireID, connection: connection)
    }

    static func milliseconds(unixSeconds: Double) -> Int64 {
        Int64((unixSeconds * 1000).rounded(.toNearestOrAwayFromZero))
    }

    static func unixSeconds(milliseconds: Int64) -> Double {
        Double(milliseconds) / 1000
    }

    static func encodeRows(_ row: HighlightRow) -> [String: SyncJSON] {
        let geometry = (try? SyncJSON(parsing: Data(row.geometryJSON.utf8))) ?? .array([])
        var locator: [String: SyncJSON] = [
            "offset": SyncJSON(row.anchorOffset ?? 0),
            "len": SyncJSON(Int64(row.text.utf16.count)),
            "quote": .string(row.text),
            "prefix": .string(row.anchorPrefix ?? ""),
            "suffix": .string(row.anchorSuffix ?? ""),
        ]
        if let quads = geometry.arrayValue, !quads.isEmpty {
            locator["t"] = .string("pdf")
            locator["page"] = SyncJSON(row.pageIndex)
            locator["quads"] = .array(quads)
        } else {
            locator["t"] = .string("text")
            if let images = geometry.objectValue?["images"]?.arrayValue, !images.isEmpty { locator["images"] = .array(images) }
        }
        var refs: [String: SyncJSON] = [:]
        if let references = row.referencesJSON.flatMap({ try? SyncJSON(parsing: Data($0.utf8)) })?.arrayValue, !references.isEmpty {
            refs["references"] = .array(references)
        }
        if let update = row.publicationUpdate, !update.isEmpty {
            refs["publicationUpdate"] = .string(update)
            if let at = row.publicationUpdateAt { refs["publicationUpdateAt"] = SyncJSON(milliseconds(unixSeconds: at)) }
        }
        return [
            "sourceID": .string(row.sourceID),
            "locator": .object(locator),
            "text": .string(row.text),
            "color": .string(row.color),
            "note": .string(row.note ?? ""),
            "chatID": row.chatSessionID.map(SyncJSON.string) ?? .null,
            "refs": refs.isEmpty ? .null : .object(refs),
            "createdAt": SyncJSON(milliseconds(unixSeconds: row.createdAt)),
            "editedAt": SyncJSON(milliseconds(unixSeconds: row.updatedAt)),
        ]
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let held = try HighlightRow.load(record.wireID, connection: connection)
        let now = Date().timeIntervalSince1970
        var row = held ?? HighlightRow(
            id: record.wireID, sourceID: "", pageIndex: 0, geometryJSON: "[]", text: "", color: SourceHighlightColor.default.rawValue,
            note: nil, createdAt: now, updatedAt: now
        )
        if let source = fields["sourceID"]?.stringValue { row.sourceID = source }
        // A highlight needs no source (D18): its row waits for the source to arrive.
        guard !row.sourceID.isEmpty else { return .projected }
        if let text = fields["text"]?.stringValue { row.text = text }
        if let locator = fields["locator"]?.objectValue {
            if locator["t"]?.stringValue == "pdf", let quads = locator["quads"]?.arrayValue, !quads.isEmpty {
                row.pageIndex = locator["page"]?.int64Value ?? 0
                row.geometryJSON = String(decoding: SyncJSON.array(quads).serialized(), as: UTF8.self)
            } else if let images = locator["images"]?.arrayValue, !images.isEmpty {
                row.pageIndex = 0
                row.geometryJSON = String(decoding: SyncJSON.object(["images": .array(images)]).serialized(), as: UTF8.self)
            } else {
                row.pageIndex = 0
                row.geometryJSON = "[]"
            }
            row.anchorOffset = locator["offset"]?.int64Value
            row.anchorPrefix = locator["prefix"]?.stringValue
            row.anchorSuffix = locator["suffix"]?.stringValue
            if row.text.isEmpty, let quote = locator["quote"]?.stringValue { row.text = quote }
        }
        if let color = fields["color"]?.stringValue { row.color = color }
        if let note = fields["note"] { row.note = note.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        if let chat = fields["chatID"] { row.chatSessionID = chat.stringValue }
        if let refs = fields["refs"] {
            let object = refs.objectValue ?? [:]
            row.referencesJSON = object["references"]?.arrayValue.flatMap { $0.isEmpty ? nil : String(decoding: SyncJSON.array($0).serialized(), as: UTF8.self) }
            let update = object["publicationUpdate"]?.stringValue ?? ""
            row.publicationUpdate = update.isEmpty ? nil : update
            row.publicationUpdateAt = update.isEmpty ? nil : object["publicationUpdateAt"]?.int64Value.map(Self.unixSeconds(milliseconds:))
        }
        if let created = fields["createdAt"]?.int64Value { row.createdAt = Self.unixSeconds(milliseconds: created) }
        if let edited = fields["editedAt"]?.int64Value { row.updatedAt = Self.unixSeconds(milliseconds: edited) }
        try row.save(connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM source_highlights WHERE highlight_id = ?", [.text(record.wireID)])
    }
}
