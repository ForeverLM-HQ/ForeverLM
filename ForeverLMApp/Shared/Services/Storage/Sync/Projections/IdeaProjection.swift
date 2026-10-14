import Foundation

// MARK: - Ideas: a thought the learner jotted down, and what it draws on (§3.5.26)

/// The local rows one Idea record is encoded from: its `ideas` row and its `idea_links` rows, the
/// tables that stay the local truth (docs/ideas-design.md). Only an Idea of kind `idea` has rows; a
/// research Direction (`research_directions`) has no projection yet and stays raw in the replica.
struct IdeaRows: Equatable, Sendable {
    struct Link: Equatable, Sendable {
        /// The Mac's `IdeaLinkKind` word.
        var kind: String
        var targetID: String
        var addedAt: Double
    }

    var id: String
    var title: String
    /// nil when never written; an emptied note is stored as nil too.
    var notes: String?
    /// `IdeaStatus`: `open` or `archived`.
    var status: String
    var createdAt: Double
    var updatedAt: Double
    /// In the order they were made.
    var links: [Link] = []
    /// The fields the record already holds that the rows cannot say: its first-writer `kind`, `madeBy`
    /// and `createdAt`, a status the Mac reads as one of its two, and an empty body. Empty for a record
    /// never sent.
    var held: [String: SyncJSON] = [:]
}

/// The Idea record's projection (§3.5.26): the Mac's `ideas` row and its `idea_links` rows, both ways.
///
/// - `body` is the Idea's notes; `status` is `open`, or `dismissed` for the Mac's `archived` (WP25a: the
///   Mac has two statuses, so `dismissed` reads as archived and every other value as open, and a status
///   the record holds that reads as the row's own is kept, so `pursuing` or `done` written elsewhere is
///   never rewritten to `open`).
/// - `links` is a map keyed by the target's ItemRef (one link per target, as the hosted MCP keys them),
///   each `{kind, target: ItemRef, addedAt}` with `kind` the Mac's `IdeaLinkKind` word. A target of a
///   kind the Mac does not link is dropped, as `IdeaLink.Lenient` drops one.
/// - `kind`, `madeBy` and `createdAt` are first-writer: the Mac records no provenance, so an Idea first
///   written here is `{route: "user"}`, every write here being the learner's own; one written elsewhere
///   keeps what its writer said.
/// - `notebookID`, `goalID`, `objection`, `nextStep`, `verdictReason`, `chatID` and `decidedAt` have no
///   column: the Mac never writes them and keeps what another client wrote (§6.5).
struct IdeaProjection: RecordProjection {
    var recordType: SyncRecordType { .idea }

    static let columns = ["title", "notes", "status", "created_at", "updated_at"]

    var tables: [ProjectedTable] {
        [
            .records("ideas", type: .idea, syncedColumns: Self.columns),
            // A link goes with its Idea (a cascade); no foreign key names its target, so a source or a
            // chat that goes leaves the link, as generation 1 left it.
            ProjectedTable(
                "idea_links", localKey: ["idea_id", "kind", "target_id"], keyColumns: ["idea_id"], syncedColumns: ["added_at"],
                parents: [LocalParent("idea_id", references: "ideas", type: .idea, role: .container)],
                elementKey: ProjectedTable.ElementKey(columns: ["kind", "target_id"]) { values in
                    guard let kind = values["kind"]?.textValue, let target = values["target_id"]?.textValue else { return nil }
                    return IdeaProjection.linkKey(kind: kind, targetID: target)
                },
                recordTypes: [.idea],
                record: { values in values["idea_id"]?.textValue.map { RowRecord(type: .idea, localID: $0, personalID: $0) } },
                localIDSQL: { "\($0).idea_id" }, personalIDSQL: { "\($0).idea_id" }
            ),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "ideas", names) }

    var feeds: [String: FieldFeed] {
        [
            "kind": .rowExistence(table: "ideas"),
            "title": Self.column("title"),
            "body": Self.column("notes"),
            "status": Self.column("status"),
            "links": .elementRows(table: "idea_links"),
            "madeBy": .rowExistence(table: "ideas"),
            "createdAt": Self.column("created_at"),
            "editedAt": .anyOf([Self.column("updated_at", "title", "notes", "status"), .columns(table: "idea_links", ["added_at"])]),
        ]
    }

    /// A deleted Idea deletes the record.
    var missingRow: MissingRowOutcome { .delete }

    var priority: OutboxPriority { .personal }

    // MARK: Links as the record keys them

    /// The ItemRef kind a link of the Mac's `IdeaLinkKind` word names.
    static func itemKind(ofLinkKind kind: String) -> ItemRef.Kind? {
        switch IdeaLinkKind(rawValue: kind) {
        case .source?: return .source
        case .artifact?: return .artifact
        case .chat?: return .chat
        case .goal?: return .goal
        case .notebook?: return .notebook
        case nil: return nil
        }
    }

    /// The Mac's link kind for a target of an ItemRef kind; nil for a kind an Idea does not link here.
    static func linkKind(of kind: ItemRef.Kind) -> IdeaLinkKind? {
        switch kind {
        case .source: return .source
        case .artifact: return .artifact
        case .chat: return .chat
        case .goal: return .goal
        case .notebook: return .notebook
        default: return nil
        }
    }

    /// A link's key in `links`: its target's ItemRef.
    static func linkKey(kind: String, targetID: String) -> String? {
        itemKind(ofLinkKind: kind).map { ItemRef($0, targetID).rawValue }
    }

    /// The link a key or target names: the Mac's kind and the target's id, whole.
    static func linkTarget(_ text: String) -> (kind: IdeaLinkKind, targetID: String)? {
        guard let ref = ItemRef(text), let kind = linkKind(of: ref.kind) else { return nil }
        return (kind, ref.subKey.map { ref.id + "#" + $0 } ?? ref.id)
    }

    /// The wire status of a local one.
    static func wireStatus(_ local: String) -> String {
        local == IdeaStatus.archived.rawValue ? "dismissed" : "open"
    }

    /// The local status of a wire one: `dismissed` is archived, anything else open.
    static func localStatus(_ wire: String) -> String {
        wire == "dismissed" ? IdeaStatus.archived.rawValue : IdeaStatus.open.rawValue
    }

    // MARK: Reading the rows

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> IdeaRows? {
        try Self.loadRows(id: record.localID, wireID: record.wireID, zoneKey: record.zoneKey, connection: connection)
    }

    static func loadRows(id: String, wireID: String? = nil, zoneKey: String = PrivateSyncZones.libraryKey,
                         connection: SQLiteConnection) throws -> IdeaRows? {
        var rows: IdeaRows?
        try connection.query("SELECT title, notes, status, created_at, updated_at FROM ideas WHERE id = ?", [.text(id)]) { row in
            rows = IdeaRows(
                id: id, title: row.text(0) ?? "", notes: row.text(1), status: row.text(2) ?? IdeaStatus.open.rawValue,
                createdAt: row.real(3) ?? 0, updatedAt: row.real(4) ?? 0
            )
        }
        guard var found = rows else { return nil }
        try connection.query(
            "SELECT kind, target_id, added_at FROM idea_links WHERE idea_id = ? ORDER BY added_at, kind, target_id", [.text(id)]
        ) { row in
            guard let kind = row.text(0), let target = row.text(1) else { return }
            found.links.append(IdeaRows.Link(kind: kind, targetID: target, addedAt: row.real(2) ?? found.createdAt))
        }
        found.held = try HeldRecord.envelope(.idea, wireID ?? id, preferring: zoneKey, connection: connection)?.fields ?? [:]
        return found
    }

    // MARK: Encoding

    static func encodeRows(_ rows: IdeaRows) -> [String: SyncJSON] {
        var links: [String: SyncJSON] = [:]
        for link in rows.links {
            guard let key = linkKey(kind: link.kind, targetID: link.targetID), links[key] == nil else { continue }
            links[key] = .object(["kind": .string(link.kind), "target": .string(key), "addedAt": milliseconds(link.addedAt)])
        }
        let status = wireStatus(rows.status)
        let heldStatus = rows.held["status"]?.stringValue.flatMap { localStatus($0) == localStatus(status) ? $0 : nil }
        var body = rows.notes.map(SyncJSON.string) ?? .null
        if body.isNull, rows.held["body"] == .string("") { body = .string("") }
        return [
            "kind": rows.held["kind"].flatMap { $0.isNull ? nil : $0 } ?? .string("idea"),
            "title": .string(rows.title),
            "body": body,
            "status": .string(heldStatus ?? status),
            "links": .object(links),
            "madeBy": rows.held["madeBy"].flatMap { $0.isNull ? nil : $0 } ?? .object(["route": .string("user")]),
            "createdAt": rows.held["createdAt"].flatMap { $0.isNull ? nil : $0 } ?? milliseconds(rows.createdAt),
            "editedAt": milliseconds(rows.updatedAt),
        ]
    }

    private static func milliseconds(_ cocoaSeconds: Double) -> SyncJSON {
        SyncJSON(SyncTime.milliseconds(cocoaSeconds: cocoaSeconds))
    }

    private static func seconds(_ value: SyncJSON?) -> Double? {
        value?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
    }

    // MARK: Applying

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // An Idea lives in the member's own Library (D18). A Direction has no rows here yet: it stays raw
        // in the replica, where a later projection finds it.
        guard !record.zone.isSpace, (envelope.fields["kind"]?.stringValue ?? "idea") == "idea" else { return .projected }
        let fields = envelope.fields
        let id = record.localID
        var held: (createdAt: Double, updatedAt: Double)?
        try connection.query("SELECT created_at, updated_at FROM ideas WHERE id = ?", [.text(id)]) { row in
            held = (row.real(0) ?? 0, row.real(1) ?? 0)
        }
        let created = Self.seconds(fields["createdAt"])
        let edited = Self.seconds(fields["editedAt"])
        var values: [String: SQLiteValue] = [:]
        if let title = fields["title"] { values["title"] = .text(title.stringValue ?? "") }
        if let body = fields["body"] { values["notes"] = .text(body.stringValue.flatMap { $0.isEmpty ? nil : $0 }) }
        if let status = fields["status"]?.stringValue { values["status"] = .text(Self.localStatus(status)) }
        if let created { values["created_at"] = .real(created) }

        if let held {
            if let edited, edited > held.updatedAt { values["updated_at"] = .real(edited) }
            if !values.isEmpty {
                let names = values.keys.sorted()
                try connection.execute(
                    "UPDATE ideas SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                    names.compactMap { values[$0] } + [.text(id)]
                )
            }
        } else {
            // A record without its required times takes the time it says it was edited, else its arrival.
            let arrived = Date().timeIntervalSinceReferenceDate
            values["title"] = values["title"] ?? .text("")
            values["status"] = values["status"] ?? .text(IdeaStatus.open.rawValue)
            values["created_at"] = values["created_at"] ?? .real(edited ?? arrived)
            values["updated_at"] = .real(edited ?? created ?? arrived)
            let names = ["id"] + values.keys.sorted()
            try connection.execute(
                "INSERT INTO ideas (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + values.keys.sorted().compactMap { values[$0] }
            )
        }
        try Self.applyLinks(fields["links"], ideaID: id, madeAt: edited ?? created ?? held?.updatedAt, connection: connection)
        return .projected
    }

    /// Each element of `links`: a live link is written with its own date, a removed one deleted. An element
    /// the record no longer lists (a removal marker compacted away) leaves the row alone, as every map fed
    /// by rows does.
    private static func applyLinks(_ value: SyncJSON?, ideaID: String, madeAt: Double?, connection: SQLiteConnection) throws {
        guard let elements = value?.objectValue else { return }
        for (key, element) in elements.sorted(by: { $0.key < $1.key }) {
            let object = element.objectValue
            guard let target = linkTarget(key) ?? object?["target"]?.stringValue.flatMap(linkTarget) else { continue }
            guard let object else {
                try connection.execute(
                    "DELETE FROM idea_links WHERE idea_id = ? AND kind = ? AND target_id = ?",
                    [.text(ideaID), .text(target.kind.rawValue), .text(target.targetID)]
                )
                continue
            }
            let addedAt = seconds(object["addedAt"]) ?? madeAt ?? Date().timeIntervalSinceReferenceDate
            try connection.execute("""
                INSERT INTO idea_links (idea_id, kind, target_id, added_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(idea_id, kind, target_id) DO UPDATE SET added_at = excluded.added_at
            """, [.text(ideaID), .text(target.kind.rawValue), .text(target.targetID), .real(addedAt)])
        }
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        // Links first, while their Idea is there, so no cascade lists the record as waiting on itself.
        try connection.execute("DELETE FROM idea_links WHERE idea_id = ?", [.text(record.localID)])
        try connection.execute("DELETE FROM ideas WHERE id = ?", [.text(record.localID)])
    }
}
