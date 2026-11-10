import Foundation

/// The Comment record's projection (docs/cloudkit-schema-design.md §3.5.16) into `artifact_comments`:
/// a comment on a Doc, in its Doc's zone, threaded by `replyTo`. Its anchor is a `doc` Locator over the
/// body it was made on (`bodyHash`, the package revision generation 1 keeps as `anchor_revision`), so
/// a quote detached by later edits stays reviewable. The author is a `Person`. A comment's Doc and the
/// comment it answers must be here before it is written (their foreign keys); one deleted with its Doc
/// on this device is deleted on the server, one gone with a Doc deleted elsewhere is not (§5.7). The
/// Comments of a Doc in its Doc space are projected like the learner's own (`DocSpaces`).
struct CommentProjection: RecordProjection {
    struct Rows: Equatable, Sendable {
        let columns: [String: SQLiteValue]
    }

    var recordType: SyncRecordType { .comment }

    static let columns = [
        "artifact_id", "parent_comment_id", "author_record_name", "author_display_name", "body", "anchor_revision",
        "anchor_start", "anchor_end", "anchor_quote", "created_at", "updated_at", "resolved_at",
    ]

    var tables: [ProjectedTable] {
        [
            .records("artifact_comments", type: .comment, syncedColumns: Self.columns, parents: [
                LocalParent("artifact_id", references: "global_artifacts", type: .artifact, role: .container),
                LocalParent("parent_comment_id", references: "artifact_comments", type: .comment, role: .container),
            ]),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "artifact_comments", names) }

    var feeds: [String: FieldFeed] {
        [
            "artifactID": Self.column("artifact_id"), "replyTo": Self.column("parent_comment_id"),
            "anchor": Self.column("anchor_revision", "anchor_start", "anchor_end", "anchor_quote"), "body": Self.column("body"),
            "author": Self.column("author_record_name", "author_display_name"), "createdAt": Self.column("created_at"),
            "resolvedAt": Self.column("resolved_at"), "editedAt": Self.column("updated_at"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows? {
        var rows: Rows?
        try connection.query("SELECT \(Self.columns.joined(separator: ", ")) FROM artifact_comments WHERE id = ?", [.text(record.localID)]) { row in
            var read: [String: SQLiteValue] = [:]
            for (index, column) in Self.columns.enumerated() { read[column] = OutboxFeeder.value(row, Int32(index)) }
            rows = Rows(columns: read)
        }
        return rows
    }

    static func encodeRows(_ rows: Rows) -> [String: SyncJSON] {
        func text(_ column: String) -> String? { rows.columns[column]?.textValue }
        func integer(_ column: String) -> Int64? {
            if case .integer(let value)? = rows.columns[column] { return value }
            return nil
        }
        func milliseconds(_ column: String) -> SyncJSON {
            switch rows.columns[column] {
            case .real(let seconds)?: return SyncJSON(SyncTime.milliseconds(cocoaSeconds: seconds))
            case .integer(let seconds)?: return SyncJSON(SyncTime.milliseconds(cocoaSeconds: Double(seconds)))
            default: return .null
            }
        }
        var fields: [String: SyncJSON] = [
            "artifactID": .string(text("artifact_id") ?? ""),
            "body": .string(text("body") ?? ""),
            "author": .object(["user": .string(text("author_record_name") ?? ""), "name": .string(text("author_display_name") ?? "")]),
            "anchor": .object([
                "t": .string("doc"), "bodyHash": .string(text("anchor_revision") ?? ""),
                "start": SyncJSON(integer("anchor_start") ?? 0), "end": SyncJSON(integer("anchor_end") ?? 0),
                "quote": .string(text("anchor_quote") ?? ""),
            ]),
            "createdAt": milliseconds("created_at"),
            "resolvedAt": milliseconds("resolved_at"),
            "editedAt": milliseconds("updated_at"),
        ]
        if let reply = text("parent_comment_id"), !reply.isEmpty { fields["replyTo"] = .string(reply) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        let fields = envelope.fields
        guard let artifactID = fields["artifactID"]?.stringValue else { return .projected }
        // Of a space's Comments, only those of the Doc a Doc space was made for have rows here (`DocSpaces`).
        if record.zone.isSpace, try !DocSpaces.holds(zoneKey: record.zoneKey, artifactID: artifactID, connection: connection) {
            return .projected
        }
        var waiting: [WaitingParent] = []
        if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM global_artifacts WHERE id = ?)", [.text(artifactID)]) != 1 {
            waiting.append(WaitingParent(type: .artifact, wireID: artifactID))
        }
        let reply = fields["replyTo"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let reply, try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM artifact_comments WHERE id = ?)", [.text(reply)]) != 1 {
            waiting.append(WaitingParent(type: .comment, wireID: reply))
        }
        guard waiting.isEmpty else { return .waiting(waiting) }

        func seconds(_ field: String) -> Double? { fields[field]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } }
        let anchor = fields["anchor"]
        let created = seconds("createdAt") ?? Date().timeIntervalSinceReferenceDate
        // A comment is written whole (its fields are created together); one held here keeps what the
        // record leaves out.
        try connection.execute("""
            INSERT INTO artifact_comments (
                id, artifact_id, parent_comment_id, author_record_name, author_display_name, body,
                anchor_revision, anchor_start, anchor_end, anchor_quote, created_at, updated_at, resolved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                body = excluded.body,
                anchor_revision = excluded.anchor_revision, anchor_start = excluded.anchor_start,
                anchor_end = excluded.anchor_end, anchor_quote = excluded.anchor_quote,
                updated_at = MAX(artifact_comments.updated_at, excluded.updated_at),
                resolved_at = excluded.resolved_at
        """, [
            .text(record.localID), .text(artifactID), .text(reply),
            .text(fields["author"]?["user"]?.stringValue ?? ""), .text(fields["author"]?["name"]?.stringValue ?? ""),
            .text(fields["body"]?.stringValue ?? ""),
            .text(anchor?["bodyHash"]?.stringValue ?? ""), .integer(anchor?["start"]?.int64Value ?? 0),
            .integer(anchor?["end"]?.int64Value ?? 0), .text(anchor?["quote"]?.stringValue ?? ""),
            .real(created), .real(seconds("editedAt") ?? created), .real(seconds("resolvedAt")),
        ])
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        // A Comment that moved with its Doc is deleted where it left and lives on where it went
        // (`ArtifactProjection.applyDeletion`).
        let artifactID = try connection.scalarText("SELECT artifact_id FROM artifact_comments WHERE id = ?", [.text(record.localID)]) ?? ""
        if record.zone.isSpace {
            guard try DocSpaces.holds(zoneKey: record.zoneKey, artifactID: artifactID, connection: connection),
                  try !DocSpaces.libraryHolds(.comment, record.wireID, connection: connection) else { return }
        } else if try DocSpaces.zoneKey(holdingComment: record.wireID, of: artifactID, connection: connection) != nil {
            return
        }
        try connection.execute("DELETE FROM artifact_comments WHERE id = ?", [.text(record.localID)])
    }
}
