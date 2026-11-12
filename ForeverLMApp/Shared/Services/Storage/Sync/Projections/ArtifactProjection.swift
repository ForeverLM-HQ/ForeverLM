import Foundation

// MARK: - What an Artifact is on the wire (docs/cloudkit-schema-design.md §3.5.15)

/// An Artifact's `kind` against `global_artifacts.kind`. Generation 1 keeps no kind for a Markdown
/// Doc, a linked Google Doc or a site kept in the library; the wire names each. A notebook's audio
/// overview is `audio_overview` locally and `audioOverview` on the wire; every other kind, a wire kind
/// this build keeps no word for (`report`, `explainer`, `skill`) included, is held verbatim, which
/// generation-1 readers read as a kindless Doc (`ArtifactRecord.kind`) and the web reads by its name.
enum ArtifactWireKind {
    static let doc = "doc"
    static let notes = "notes"
    static let site = "site"
    static let linkedDoc = "linkedDoc"
    static let audioOverview = "audioOverview"

    static func wire(localKind: String?, linkedURL: String?, hasSite: Bool) -> String {
        switch localKind {
        case nil, "":
            if let linkedURL, !linkedURL.isEmpty { return linkedDoc }
            return hasSite ? site : doc
        case ArtifactKind.audioOverview.rawValue:
            return audioOverview
        case let kind?:
            return kind
        }
    }

    /// The `global_artifacts.kind` a wire kind is held as; nil for the kinds generation 1 keeps none for.
    static func local(_ wireKind: String) -> String? {
        switch wireKind {
        case doc, site, linkedDoc, notes: return nil
        case audioOverview: return ArtifactKind.audioOverview.rawValue
        default: return wireKind
        }
    }
}

/// A Doc's body satellite (§3.5.15, §13.6): the `ArtifactBodyPackage` bytes as they are, so its
/// FileRef's `hash` is the `bodyRevision` generation 1 gives the same package, laid out as `BlobStore`
/// lays it out on a native client; a Notes Doc's body is its trimmed Markdown, gzip (`NotesDoc`).
enum ArtifactBody {
    static let role = "body"
    static let packageMime = "application/vnd.foreverlm.article"
    static let packageFormat = "markdownPackage"
    /// The `artifact_files` key that holds a Notes Doc's body pointer, which has no `global_artifacts`
    /// row to hold it; JSON `null` once the notes were cleared. A `files` map key never starts with `#`.
    static let notesKey = "#body"

    static func layout(package: Data, owner: String) throws -> (file: FileRef, stored: Data) {
        try SourceSatelliteLayout.layout(SourceLocalSatellite(
            map: .files, role: role, mime: packageMime, encoding: .identity, body: package, localPath: nil, input: nil
        ), owner: owner)
    }

    static func fileRef(_ text: String?) -> FileRef? {
        text.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }.flatMap(FileRef.init(json:))
    }

    static func text(_ file: FileRef) -> String {
        String(decoding: file.value.serialized(), as: UTF8.self)
    }

    /// Lists' preview: the Markdown on one line, at most 280 characters.
    static func preview(_ markdown: String?) -> SyncJSON {
        let line = (markdown ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return line.isEmpty ? .null : .string(String(line.prefix(NotesDoc.previewLimit)))
    }

    /// Whether `id` names a source's draft deck, which generation 2 retires in favour of Card drafts
    /// (§10): never encoded, never projected.
    static func isCardDeck(id: String, kind: String?) -> Bool {
        kind == ArtifactKind.flashcards.rawValue || MemoryCard.isDraftDeckID(id)
    }
}

// MARK: - A Doc in its Doc space (§9.1 `doc`, D5)

/// A Doc shared through a Doc space lives in that space with its Comments and reads as part of My
/// Library: on the owner's Macs and on each member's it is an ordinary `global_artifacts` row under the
/// Doc's own id, with `team_id` null, so the record and the row say the same thing whoever edits. Its
/// body goes into and comes from the space's own zone (`DocBodyTransfer`). The Docs of a team or family
/// space have no rows here: their projection is not built.
enum DocSpaces {
    /// Whether `zoneKey` is the Doc space made for the Doc `artifactID`: a space whose root says `doc`
    /// and names it.
    static func holds(zoneKey: String, artifactID: String, connection: SQLiteConnection) throws -> Bool {
        guard ProjectionZones.zone(ofKey: zoneKey)?.isSpace == true,
              let root = try ReplicaStore(connection: connection).record(zoneKey: zoneKey, recordName: SyncSchema.rootRecordName),
              let envelope = try? SyncEnvelope(storedPayload: root.payload)
        else { return false }
        return envelope.fields["kind"]?.stringValue == "doc" && envelope.fields["primaryID"]?.stringValue == artifactID
    }

    static func libraryHolds(_ type: SyncRecordType, _ wireID: String, connection: SQLiteConnection) throws -> Bool {
        try ReplicaStore(connection: connection).record(zoneKey: PrivateSyncZones.libraryKey, recordType: type.rawValue, wireID: wireID) != nil
    }

    private static func zoneKeys(holding type: SyncRecordType, _ wireID: String, connection: SQLiteConnection) throws -> [String] {
        var keys: [String] = []
        try connection.query(
            "SELECT zone_key FROM ck_records WHERE record_type = ? AND wire_id = ? ORDER BY zone_key", [.text(type.rawValue), .text(wireID)]
        ) { row in
            if let key = row.text(0) { keys.append(key) }
        }
        return keys
    }

    /// The Doc space the replica holds the Doc in; nil while `Library` holds it (a Doc that is not
    /// shared, or one whose move has not finished: the outbox sends to `Library` first, as here).
    /// `besideLibrary` asks whether a Doc space holds it whatever `Library` holds: the question a
    /// deletion in `Library` asks, whose own record the replica still has while it is projected.
    static func zoneKey(holding artifactID: String, besideLibrary: Bool = false, connection: SQLiteConnection) throws -> String? {
        let keys = try zoneKeys(holding: .artifact, artifactID, connection: connection)
        guard besideLibrary || !keys.contains(PrivateSyncZones.libraryKey) else { return nil }
        return try keys.first { try holds(zoneKey: $0, artifactID: artifactID, connection: connection) }
    }

    /// The Doc space that holds a Comment of `artifactID`, whatever `Library` holds.
    static func zoneKey(holdingComment commentID: String, of artifactID: String, connection: SQLiteConnection) throws -> String? {
        try zoneKeys(holding: .comment, commentID, connection: connection)
            .first { try holds(zoneKey: $0, artifactID: artifactID, connection: connection) }
    }

    /// The space a Doc's body lives in: where its record is, and for a Doc no zone holds yet (never
    /// sent) the Doc space made for it, which is where placement sends its record
    /// (`ZonePlacement`, `primaryOfSpace`). Nil for private `Content`.
    static func bodyZoneKey(of artifactID: String, connection: SQLiteConnection) throws -> String? {
        let keys = try zoneKeys(holding: .artifact, artifactID, connection: connection)
        guard !keys.contains(PrivateSyncZones.libraryKey) else { return nil }
        if let held = try keys.first(where: { try holds(zoneKey: $0, artifactID: artifactID, connection: connection) }) { return held }
        guard keys.isEmpty else { return nil }
        var made: [String] = []
        try connection.query("SELECT zone_key FROM ck_zones WHERE primary_id = ? ORDER BY zone_key", [.text(artifactID)]) { row in
            if let key = row.text(0) { made.append(key) }
        }
        return try made.first { try holds(zoneKey: $0, artifactID: artifactID, connection: connection) }
    }

    /// Whether this account may write into the space: its owner, or a member the share lets write.
    static func canWrite(zoneKey: String, connection: SQLiteConnection) throws -> Bool {
        guard let zone = try ReplicaStore(connection: connection).zone(key: zoneKey) else { return false }
        return zone.database == .private || zone.permission == CloudShare.Permission.readWrite.rawValue
    }
}

// MARK: - The rows one Artifact is encoded from

struct ArtifactRows: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        /// A `global_artifacts` row.
        case artifact(columns: [String: SQLiteValue], hasSite: Bool, markdown: String?)
        /// A notebook's Notes Doc: the notebook's creation and its notes.
        case notes(notebookID: String, createdAt: Double?, editedAt: Double?, notes: String?)
        /// A notebook's workspace file (`NotebookFileArtifact`).
        case file(NotebookFileArtifact.Row)
    }

    var shape: Shape
    var linkedNotebookIDs: [String] = []
    var sourceIDs: [String] = []
    /// `artifact_files`, by key, the Notes Doc's `#body` included.
    var files: [String: String] = [:]
}

// MARK: - The Artifact record

/// The Artifact record's projection (§3.5.15) into `global_artifacts`, its notebook and source links and
/// `artifact_files`, and a notebook's Notes Doc (`notes:<notebookID>`) from `learning_goals.notes` and its
/// `#body` pointer. The body itself is a satellite: the field reads only the pointer, which the body
/// publisher moves on idle once the bytes are acknowledged (D44, `DocBodyPublisher`), and an inbound
/// pointer queues the fetch that brings the bytes and merges them (`DocBodyMaterializer`). A source's
/// draft deck is never encoded or projected (generation 2 retires decks for Card drafts, §10). A Doc in
/// the Doc space made for it is projected like the learner's own (`DocSpaces`); the Docs of a team or
/// family space stay in the replica.
struct ArtifactProjection: RecordProjection {
    var recordType: SyncRecordType { .artifact }

    static let columns = ["title", "home_notebook_id", "is_draft", "linked_url", "created_at", "archived_at", "kind", "body_ref"]

    private static let artifactsTable = ProjectedTable(
        "global_artifacts", localKey: ["id"], keyColumns: ["id", "kind"], syncedColumns: columns,
        recordTypes: [.artifact],
        record: { values in
            guard let id = values["id"]?.textValue, !ArtifactBody.isCardDeck(id: id, kind: values["kind"]?.textValue) else { return nil }
            return RowRecord(type: .artifact, localID: id, personalID: id)
        },
        localIDSQL: { "\($0).id" }, personalIDSQL: { "\($0).id" }
    )

    /// A table whose rows are elements of the Artifact's set or map field, keyed by `element`.
    private static func elementTable(_ name: String, localKey: [String], element: String, syncedColumns: [String], parent: Bool) -> ProjectedTable {
        ProjectedTable(
            name, localKey: localKey, keyColumns: ["artifact_id"], syncedColumns: syncedColumns,
            parents: parent ? [LocalParent("artifact_id", references: "global_artifacts", type: .artifact, role: .container)] : [],
            elementColumn: element, recordTypes: [.artifact],
            record: { values in
                guard let id = values["artifact_id"]?.textValue, !ArtifactBody.isCardDeck(id: id, kind: nil) else { return nil }
                return RowRecord(type: .artifact, localID: id, personalID: id)
            },
            localIDSQL: { "\($0).artifact_id" }, personalIDSQL: { "\($0).artifact_id" }
        )
    }

    var tables: [ProjectedTable] {
        [
            Self.artifactsTable,
            Self.elementTable("global_artifact_notebook_links", localKey: ["artifact_id", "notebook_id"], element: "notebook_id", syncedColumns: [], parent: true),
            Self.elementTable("global_artifact_source_links", localKey: ["artifact_id", "source_id"], element: "source_id", syncedColumns: [], parent: true),
            // A Doc's files and a Notes Doc's body pointer; a Notes Doc has no row to be the parent.
            Self.elementTable("artifact_files", localKey: ["artifact_id", "file_key"], element: "file_key", syncedColumns: ["file_ref"], parent: false),
            // A notebook's workspace files, each its own Artifact (kind file).
            NotebookFileArtifact.table,
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "global_artifacts", names) }

    var feeds: [String: FieldFeed] {
        [
            "kind": Self.column("kind", "linked_url"), "title": Self.column("title"), "notebookID": Self.column("home_notebook_id"),
            "linkedNotebookIDs": .elementRows(table: "global_artifact_notebook_links"),
            "sourceIDs": .elementRows(table: "global_artifact_source_links"),
            "body": .anyOf([Self.column("body_ref"), .elementRows(table: "artifact_files")]),
            "bodyFormat": .anyOf([Self.column("body_ref"), .elementRows(table: "artifact_files")]),
            "preview": .anyOf([Self.column("body_ref"), .elementRows(table: "artifact_files")]),
            "files": .elementRows(table: "artifact_files"),
            "linkedURL": Self.column("linked_url"), "isDraft": Self.column("is_draft"), "status": Self.column("archived_at"),
            "createdAt": Self.column("created_at"),
        ]
    }

    /// A deleted Doc deletes its record; its Comments go with it (§5.1).
    var missingRow: MissingRowOutcome { .delete }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ArtifactRows? {
        try Self.loadRows(localID: record.localID, connection: connection)
    }

    static func loadRows(localID: String, connection: SQLiteConnection) throws -> ArtifactRows? {
        var rows: ArtifactRows
        if let notebookID = NotesDoc.notebookID(of: localID) {
            var notebook: (createdAt: Double?, updatedAt: Double?, notes: String?)?
            try connection.query(
                "SELECT created_at, updated_at, notes FROM learning_goals WHERE id = ? AND entity_kind = ?",
                [.text(notebookID), .text(LearningGoalEntityKind.notebook)]
            ) { notebook = ($0.real(0), $0.real(1), $0.text(2)) }
            guard let notebook else { return nil }
            rows = ArtifactRows(shape: .notes(notebookID: notebookID, createdAt: notebook.createdAt, editedAt: notebook.updatedAt, notes: notebook.notes))
        } else if let file = try NotebookFileArtifact.row(for: localID, connection: connection) {
            var rows = ArtifactRows(shape: .file(file))
            rows.files[ArtifactBody.notesKey] = try connection.scalarText(
                "SELECT file_ref FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(file.wireID), .text(ArtifactBody.notesKey)]
            )
            return rows
        } else if NotebookFileArtifact.notebookID(of: localID) != nil {
            return nil
        } else {
            // `updated_at` is read, never watched: it moves with every save, and `editedAt` (X) rides
            // along with the changes that are sent.
            let read = Self.columns + ["updated_at"]
            var columns: [String: SQLiteValue]?
            try connection.query("SELECT \(read.joined(separator: ", ")) FROM global_artifacts WHERE id = ?", [.text(localID)]) { row in
                var values: [String: SQLiteValue] = [:]
                for (index, column) in read.enumerated() { values[column] = OutboxFeeder.value(row, Int32(index)) }
                columns = values
            }
            guard let columns, !ArtifactBody.isCardDeck(id: localID, kind: columns["kind"]?.textValue) else { return nil }
            let store = connection as? KnowledgeStore
            rows = ArtifactRows(shape: .artifact(
                columns: columns, hasSite: store?.hasLocalSite(localID) ?? false,
                markdown: try store?.publishedArtifactMarkdown(localID)
            ))
            try connection.query("SELECT notebook_id FROM global_artifact_notebook_links WHERE artifact_id = ? ORDER BY notebook_id", [.text(localID)]) { row in
                if let id = row.text(0) { rows.linkedNotebookIDs.append(id) }
            }
            try connection.query("SELECT source_id FROM global_artifact_source_links WHERE artifact_id = ? ORDER BY source_id", [.text(localID)]) { row in
                if let id = row.text(0) { rows.sourceIDs.append(id) }
            }
        }
        try connection.query("SELECT file_key, file_ref FROM artifact_files WHERE artifact_id = ?", [.text(localID)]) { row in
            if let key = row.text(0), let ref = row.text(1) { rows.files[key] = ref }
        }
        return rows
    }

    static func encodeRows(_ rows: ArtifactRows) -> [String: SyncJSON] {
        var files: [String: SyncJSON] = [:]
        for (key, text) in rows.files where !key.hasPrefix("#") {
            if let file = ArtifactBody.fileRef(text) { files[key] = file.value }
        }
        func milliseconds(_ seconds: Double?) -> SyncJSON? { seconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } }

        switch rows.shape {
        case .file(let row):
            return NotebookFileArtifact.encode(row, body: ArtifactBody.fileRef(rows.files[ArtifactBody.notesKey]))

        case .notes(let notebookID, let createdAt, let editedAt, let notes):
            // The notes as `NotesDoc` shapes them; the body is the pointer the publisher moved, null once
            // the notes were cleared.
            var fields: [String: SyncJSON] = [
                "kind": .string(ArtifactWireKind.notes), "title": .string(NotesDoc.title), "notebookID": .string(notebookID),
                "status": .string("active"), "bodyFormat": .string(NotesDoc.bodyFormat),
                "body": ArtifactBody.fileRef(rows.files[ArtifactBody.notesKey])?.value ?? .null,
                "preview": ArtifactBody.preview(NotesDoc.text(notes)),
            ]
            fields["createdAt"] = milliseconds(createdAt)
            fields["editedAt"] = milliseconds(editedAt)
            return fields

        case .artifact(let columns, let hasSite, let markdown):
            func text(_ column: String) -> String? { columns[column]?.textValue }
            func seconds(_ column: String) -> Double? { columns[column]?.realValue }
            let linkedURL = text("linked_url").flatMap { $0.isEmpty ? nil : $0 }
            var fields: [String: SyncJSON] = [
                "kind": .string(ArtifactWireKind.wire(localKind: text("kind"), linkedURL: linkedURL, hasSite: hasSite)),
                "title": .string(text("title") ?? ""),
                "notebookID": text("home_notebook_id").flatMap { $0.isEmpty ? nil : SyncJSON.string($0) } ?? .null,
                "linkedNotebookIDs": .object(Dictionary(rows.linkedNotebookIDs.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
                "sourceIDs": .object(Dictionary(rows.sourceIDs.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
                "linkedURL": linkedURL.map(SyncJSON.string) ?? .null,
                "isDraft": .bool((columns["is_draft"].flatMap { if case .integer(let flag) = $0 { return flag } else { return nil } } ?? 0) != 0),
                "status": .string(seconds("archived_at") == nil ? "active" : "archived"),
                "files": .object(files),
            ]
            // A Doc with no pointer yet (not laid out, not published) says nothing about its body:
            // absent, never a clear (§3.2 rule 6).
            if let body = ArtifactBody.fileRef(text("body_ref")) {
                fields["body"] = body.value
                fields["bodyFormat"] = .string(ArtifactBody.packageFormat)
                fields["preview"] = ArtifactBody.preview(markdown)
            }
            fields["createdAt"] = milliseconds(seconds("created_at"))
            fields["editedAt"] = milliseconds(seconds("updated_at"))
            return fields
        }
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // Of a space's Docs, only the one a Doc space was made for has a row here (§9.1 `doc`, D5).
        if record.zone.isSpace, try !DocSpaces.holds(zoneKey: record.zoneKey, artifactID: record.wireID, connection: connection) {
            return .projected
        }
        let fields = envelope.fields
        let id = record.localID
        if let notebookID = NotesDoc.notebookID(of: id) {
            return try applyNotes(fields, artifactID: id, notebookID: notebookID, record: record, connection: connection)
        }
        let wireKind = fields["kind"]?.stringValue
        // Retired under generation 2. A notebook's files have their own rows; standalone pictures, which
        // a later package projects, stay in the replica only.
        if ArtifactBody.isCardDeck(id: id, kind: wireKind.flatMap(ArtifactWireKind.local)) { return .projected }
        if wireKind == NotebookFileArtifact.kind || NotebookFileArtifact.notebookID(of: id) != nil {
            return try NotebookFileArtifact.apply(fields, wireID: record.wireID, zoneKey: record.zoneKey, connection: connection)
        }
        if wireKind == "picture" { return .projected }

        func seconds(_ field: String) -> Double? { fields[field]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } }
        let held = try Self.heldColumns(id: id, connection: connection)
        var values: [String: SQLiteValue] = [:]
        if let title = fields["title"]?.stringValue { values["title"] = .text(title) }
        if let home = fields["notebookID"] { values["home_notebook_id"] = .text(home.stringValue.flatMap { $0.isEmpty ? nil : $0 }) }
        if let draft = fields["isDraft"] { values["is_draft"] = .integer(draft.boolValue == true ? 1 : 0) }
        if let linked = fields["linkedURL"] { values["linked_url"] = .text(linked.stringValue.flatMap { $0.isEmpty ? nil : $0 }) }
        if let wireKind { values["kind"] = .text(ArtifactWireKind.local(wireKind)) }
        if let created = seconds("createdAt") { values["created_at"] = .real(created) }
        let edited = seconds("editedAt")
        if let status = fields["status"]?.stringValue {
            // The record keeps no archive date: an archived Doc keeps the one it has, or takes its edit.
            if status == "archived" {
                if held?.archivedAt == nil { values["archived_at"] = .real(edited ?? Date().timeIntervalSinceReferenceDate) }
            } else {
                values["archived_at"] = .null
            }
        }
        var bodyChanged = false
        if let body = fields["body"] {
            let file = FileRef(json: body)
            let text = file.map(ArtifactBody.text)
            bodyChanged = text != held?.bodyRef
            values["body_ref"] = .text(text)
        }

        if held == nil {
            let createdAt = seconds("createdAt") ?? Date().timeIntervalSinceReferenceDate
            values["title"] = values["title"] ?? .text("")
            values["created_at"] = .real(createdAt)
            values["updated_at"] = .real(edited ?? createdAt)
            values["wire_id"] = .text(record.wireID)
            let names = ["id"] + values.keys.sorted()
            try connection.execute(
                "INSERT INTO global_artifacts (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + values.keys.sorted().compactMap { values[$0] }
            )
        } else if !values.isEmpty {
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE global_artifacts SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(id)]
            )
        }
        if let edited {
            try connection.execute("UPDATE global_artifacts SET updated_at = MAX(updated_at, ?) WHERE id = ?", [.real(edited), .text(id)])
        }
        let linkedAt = edited ?? Date().timeIntervalSinceReferenceDate
        try Self.applySet(fields["linkedNotebookIDs"], table: "global_artifact_notebook_links", column: "notebook_id", artifactID: id, at: linkedAt, connection: connection)
        try Self.applySet(fields["sourceIDs"], table: "global_artifact_source_links", column: "source_id", artifactID: id, at: linkedAt, connection: connection)
        try Self.applyFiles(fields["files"], artifactID: id, connection: connection)
        if bodyChanged { try DocBodyJobs.queueFetch(artifactID: id, zoneKey: record.zoneKey, connection: connection) }
        return .projected
    }

    /// A Notes Doc: its notebook must be here first; a new body pointer queues the fetch that brings the
    /// notes and merges them (§6.2 step 4).
    private func applyNotes(_ fields: [String: SyncJSON], artifactID: String, notebookID: String, record: ProjectionRecordRef,
                            connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ? AND entity_kind = ?)",
            [.text(notebookID), .text(LearningGoalEntityKind.notebook)]
        ) == 1 else {
            return .waiting([WaitingParent(type: .notebook, wireID: notebookID)])
        }
        guard let body = fields["body"] else { return .projected }
        let held = try connection.scalarText(
            "SELECT file_ref FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(artifactID), .text(ArtifactBody.notesKey)]
        )
        // Cleared notes are a row holding JSON null, so the Notes Doc keeps a row to go with its notebook.
        let text = FileRef(json: body).map(ArtifactBody.text) ?? "null"
        guard text != held else { return .projected }
        try connection.execute("""
            INSERT INTO artifact_files (artifact_id, file_key, file_ref, local_path) VALUES (?, ?, ?, NULL)
            ON CONFLICT(artifact_id, file_key) DO UPDATE SET file_ref = excluded.file_ref, local_path = NULL
        """, [.text(artifactID), .text(ArtifactBody.notesKey), .text(text)])
        try DocBodyJobs.queueFetch(artifactID: artifactID, zoneKey: record.zoneKey, connection: connection)
        return .projected
    }

    private static func heldColumns(id: String, connection: SQLiteConnection) throws -> (archivedAt: Double?, bodyRef: String?)? {
        var held: (archivedAt: Double?, bodyRef: String?)?
        try connection.query("SELECT archived_at, body_ref FROM global_artifacts WHERE id = ?", [.text(id)]) { held = ($0.real(0), $0.text(1)) }
        return held
    }

    private static func applySet(_ value: SyncJSON?, table: String, column: String, artifactID: String, at time: Double, connection: SQLiteConnection) throws {
        guard let elements = value?.objectValue else { return }
        for (element, member) in elements.sorted(by: { $0.key < $1.key }) {
            if member.boolValue == true {
                try connection.execute("""
                    INSERT INTO \(table) (artifact_id, \(column), linked_at) VALUES (?, ?, ?)
                    ON CONFLICT(artifact_id, \(column)) DO NOTHING
                """, [.text(artifactID), .text(element), .real(time)])
            } else {
                try connection.execute("DELETE FROM \(table) WHERE artifact_id = ? AND \(column) = ?", [.text(artifactID), .text(element)])
            }
        }
    }

    private static func applyFiles(_ value: SyncJSON?, artifactID: String, connection: SQLiteConnection) throws {
        guard let elements = value?.objectValue else { return }
        for (key, element) in elements.sorted(by: { $0.key < $1.key }) where !key.hasPrefix("#") {
            guard let file = FileRef(json: element) else {
                try connection.execute("DELETE FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(artifactID), .text(key)])
                continue
            }
            // A new FileRef for the key forgets where this Mac held the old bytes.
            try connection.execute("""
                INSERT INTO artifact_files (artifact_id, file_key, file_ref) VALUES (?, ?, ?)
                ON CONFLICT(artifact_id, file_key) DO UPDATE SET
                    local_path = CASE WHEN artifact_files.file_ref = excluded.file_ref THEN artifact_files.local_path END,
                    file_ref = excluded.file_ref
            """, [.text(artifactID), .text(key), .text(ArtifactBody.text(file))])
        }
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        // A Doc that moved between `Library` and its Doc space is deleted where it left and lives on
        // where it went: its row stays while the replica holds the other copy (the move list says the
        // same, but may reach a second Mac after the deletion does).
        if record.zone.isSpace {
            guard try DocSpaces.holds(zoneKey: record.zoneKey, artifactID: record.wireID, connection: connection),
                  try !DocSpaces.libraryHolds(.artifact, record.wireID, connection: connection) else { return }
        } else if try DocSpaces.zoneKey(holding: record.wireID, besideLibrary: true, connection: connection) != nil {
            return
        }
        if NotebookFileArtifact.notebookID(of: record.localID) != nil {
            try NotebookFileArtifact.applyDeletion(record.localID, connection: connection)
            return
        }
        // A body edited here and not yet on the server is kept as a Recovered Doc first (§6.2), unless
        // the Doc was someone else's, shared with this account: it goes whole when the share does.
        if try ReplicaStore(connection: connection).zone(key: record.zoneKey)?.database != .shared {
            try RecoveredDoc.keepPendingBody(of: record, connection: connection)
        }
        let id = record.localID
        try connection.execute("DELETE FROM artifact_files WHERE artifact_id = ?", [.text(id)])
        try DocBodyJobs.forget(artifactID: id, connection: connection)
        guard NotesDoc.notebookID(of: id) == nil else { return }
        // Its links, comments and walkthrough go with the row; a chat link has no key to cascade on.
        // The learner's hide stays: per-member state outlives the content it is about (D18).
        try connection.execute("DELETE FROM artifact_chat_links WHERE artifact_id = ?", [.text(id)])
        try connection.execute("DELETE FROM global_artifacts WHERE id = ?", [.text(id)])
        (connection as? KnowledgeStore)?.removeArtifactFolder(id)
    }
}
