import Foundation

// MARK: - The Source record and its local tables (docs/cloudkit-schema-design.md §3.5.4, §6.6)

/// Where a source's columns live. The `sources` row holds its state and type; one per-type table
/// (`articles`, `papers`, …) holds its address, title and the columns of its kind. Only the columns a
/// Source field reads are listed, so a write to a member-local column (the discovery origin, the like
/// time, a reading position) or to a device-local one (a file path, a transcript check) sends nothing.
enum SourceLocalTables {
    static let subtypeTables = ["articles", "papers", "podcasts", "book_sources", "course_sources", "meeting_sources", "videos", "x_posts"]

    /// The per-type table of a local `source_type` (`StudioSourceType`).
    static func subtypeTable(forLocalType type: String) -> String {
        switch type {
        case "paper": return "papers"
        case "podcast": return "podcasts"
        case "book": return "book_sources"
        case "course": return "course_sources"
        case "meeting": return "meeting_sources"
        case "video": return "videos"
        case "xPost": return "x_posts"
        default: return "articles"
        }
    }

    static let commonColumns = ["url", "title", "domain", "word_count"]

    /// The columns of a per-type table the Source record reads.
    static func syncedColumns(_ table: String) -> [String] {
        switch table {
        case "articles": return commonColumns + ["author"]
        case "papers": return commonColumns + ["author", "doi", "published_doi", "journal", "published_year", "is_paywalled"]
        case "podcasts": return commonColumns + ["show_name"]
        case "meeting_sources": return commonColumns + ["occurred_at", "presenter"]
        case "videos": return commonColumns + ["video_published_at"]
        case "x_posts": return commonColumns + ["author", "author_handle"]
        // A chapter's pages of its book's file (`meta.pageStart`, `meta.pageCount`).
        case "book_sources": return commonColumns + ["page_start", "page_count"]
        default: return commonColumns
        }
    }

    /// The column that holds a source's authors in its per-type table, if it has one.
    static func authorColumn(_ table: String) -> String? {
        switch table {
        case "articles", "papers", "x_posts": return "author"
        case "meeting_sources": return "presenter"
        default: return nil
        }
    }

    /// The `sources` columns the Source record reads; reading positions, the review depth and the
    /// card count are not on the record (they are the member's `ReadingState`).
    static let sourceColumns = ["date_added", "state", "error_message", "source_type", "status"]
    static let wireFieldColumns = [
        "primary_key", "made_by_json", "type_locked", "subtitle", "language", "summary", "content_hash",
        "metrics_json", "copied_from_json", "merged_into", "extra_meta_json", "lossy_json",
    ]
    /// The `meeting_artifacts` columns a meeting's `meta.attachments` reads.
    static let attachmentColumns = ["group_id", "kind", "title", "url", "mime_type", "sort_index"]

    /// The wire type of a local `source_type`: a web page awaiting classification and a manually
    /// added address are articles.
    static func wireType(_ localType: String) -> String {
        switch localType {
        case "paper", "book", "article", "video", "podcast", "meeting", "course", "xPost": return localType
        default: return "article"
        }
    }

    /// The local type a wire type is held as; a type this Mac has no table for (`repo`, `document`)
    /// is held as an article, and the record keeps its wire type (`SourceLossyFields`).
    static func localType(_ wireType: String) -> String {
        switch wireType {
        case "paper", "book", "article", "video", "podcast", "meeting", "course", "xPost": return wireType
        default: return "article"
        }
    }
}

/// A group membership that makes a source a member of a collection: a book's chapter or a meeting
/// series' session (`Source.collectionID`, `collectionOrder`). Playlist memberships are Entries
/// (`PlaylistEntryProjection`), and a course's are its lesson items.
struct SourceCollectionMembership: Equatable, Sendable {
    enum Kind: String, Sendable { case book, meetingSeries }
    let groupID: String
    let sortIndex: Int64?
    let kind: Kind
}

/// The Source fields no generation-1 column holds (`source_wire_fields`).
struct SourceWireFields: Equatable, Sendable {
    var primaryKey: String?
    var madeBy: SyncJSON?
    var typeLocked: Bool?
    var subtitle: String?
    var language: String?
    var summary: String?
    var contentHash: String?
    var metrics: [String: SyncJSON]?
    var copiedFrom: SyncJSON?
    var mergedInto: String?
    /// `meta` keys no column holds.
    var extraMeta: [String: SyncJSON] = [:]
    var lossy = SourceLossyFields()
}

/// The wire value of a field a column holds only approximately, beside the column values it was
/// written as (`source_wire_fields.lossy_json`): authors as one string, a paper's publication date as
/// its year, a wire type this Mac has no table for, the `ingest` object as a state, a collection order
/// as an index. While the columns still hold those values the record keeps the value it came with; once
/// a local write changes them, the field is encoded from the columns.
struct SourceLossyFields: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let wire: SyncJSON
        let local: SyncJSON
    }

    var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    init(json: SyncJSON?) {
        for (field, value) in json?.objectValue ?? [:] {
            guard let wire = value["wire"], let local = value["local"] else { continue }
            entries[field] = Entry(wire: wire, local: local)
        }
    }

    var json: SyncJSON {
        .object(entries.mapValues { .object(["wire": $0.wire, "local": $0.local]) })
    }

    /// The wire value kept for `field`, when the columns still hold `local`.
    func value(_ field: String, local: SyncJSON) -> SyncJSON? {
        guard let entry = entries[field], entry.local == local else { return nil }
        return entry.wire
    }
}

/// A source's local rows, as its Source record is encoded from them.
struct SourceRows: Equatable, Sendable {
    var sourceID: String
    var dateAdded: Double
    var state: String
    var errorMessage: String?
    var sourceType: String
    var status: String
    /// The per-type table the row came from and its columns, by name.
    var subtypeTable: String
    var subtype: [String: SQLiteValue] = [:]
    var membership: SourceCollectionMembership?
    var workKeys: [String] = []
    var files: [String: SyncJSON] = [:]
    var derived: [String: SyncJSON] = [:]
    var wire = SourceWireFields()
    /// A meeting's files and links (`meeting_artifacts`), by artifact id; nil when it has none.
    var attachments: [String: SyncJSON]?
    /// The ids of the groups it is in and their playlists' titles, which a video's `domain` may hold
    /// instead of a channel name.
    var groupNames: [String] = []

    func text(_ column: String) -> String? {
        guard let value = subtype[column]?.textValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func real(_ column: String) -> Double? { subtype[column]?.realValue }

    func integer(_ column: String) -> Int64? {
        switch subtype[column] {
        case .integer(let value)?: return value
        case .real(let value)?: return Int64(exactly: value)
        default: return nil
        }
    }

    var isPaywalled: Bool { integer("is_paywalled") == 1 }

    /// Whether it holds its PDF: the record names one (`files.pdf`), or this Mac has one whose upload
    /// has not been recorded yet.
    var holdsPDF: Bool {
        (files["pdf"].map { !$0.isNull } ?? false)
            || text("local_file_path")?.lowercased().hasSuffix(".pdf") == true
    }
}

/// The Source record's projection (§3.5.4) into `sources`, its per-type table, its collection
/// membership, its meeting attachments and schema 155's tables. Per-member state is not on the record:
/// reading position and progress are the member's `ReadingState`, and when a video was liked,
/// the search that found a source and whether a feed is followed are Marks.
struct SourceProjection: RecordProjection {
    var recordType: SyncRecordType { .source }

    var tables: [ProjectedTable] {
        var tables: [ProjectedTable] = [
            .records("sources", type: .source, syncedColumns: SourceLocalTables.sourceColumns),
        ]
        for table in SourceLocalTables.subtypeTables {
            tables.append(.records(table, type: .source, idColumn: "source_id", syncedColumns: SourceLocalTables.syncedColumns(table)))
        }
        tables += [
            Self.elementTable("source_work_keys", element: "work_key", syncedColumns: []),
            Self.elementTable("source_files", element: "role", syncedColumns: ["file_ref"]),
            Self.elementTable("source_derived", element: "kind", syncedColumns: ["file_ref"]),
            .records("source_wire_fields", type: .source, idColumn: "source_id", syncedColumns: SourceLocalTables.wireFieldColumns),
            // A book chapter's or meeting session's place in its collection. The table also holds
            // playlist memberships, which `PlaylistEntryProjection` reads as Entries.
            Self.sourceRowTable("group_members", localKey: ["source_id", "group_id"], syncedColumns: ["sort_index"]),
            Self.sourceRowTable("meeting_artifacts", localKey: ["id"], syncedColumns: SourceLocalTables.attachmentColumns),
        ]
        return tables
    }

    /// A table whose rows are elements of a source's set or map field, keyed by `element`.
    private static func elementTable(_ name: String, element: String, syncedColumns: [String]) -> ProjectedTable {
        ProjectedTable(
            name, localKey: ["source_id", element], keyColumns: ["source_id"], syncedColumns: syncedColumns,
            elementColumn: element, recordTypes: [.source],
            record: { values in values["source_id"]?.textValue.map { RowRecord(type: .source, localID: $0, personalID: $0) } },
            localIDSQL: { "\($0).source_id" }, personalIDSQL: { "\($0).source_id" }
        )
    }

    /// A table whose rows feed the source their `source_id` names.
    private static func sourceRowTable(_ name: String, localKey: [String], syncedColumns: [String]) -> ProjectedTable {
        ProjectedTable(
            name, localKey: localKey, keyColumns: ["source_id"], syncedColumns: syncedColumns, recordTypes: [.source],
            record: { values in values["source_id"]?.textValue.map { RowRecord(type: .source, localID: $0, personalID: $0) } },
            localIDSQL: { "\($0).source_id" }, personalIDSQL: { "\($0).source_id" }
        )
    }

    private static func subtypeColumns(_ column: String) -> FieldFeed {
        .anyOf(SourceLocalTables.subtypeTables.filter { SourceLocalTables.syncedColumns($0).contains(column) }.map { .columns(table: $0, [column]) })
    }

    private static func wireColumn(_ column: String) -> FieldFeed {
        .columns(table: "source_wire_fields", [column])
    }

    var feeds: [String: FieldFeed] {
        let venue: FieldFeed = .anyOf([
            .columns(table: "papers", ["journal"]), .columns(table: "podcasts", ["show_name", "domain"]),
            .columns(table: "videos", ["domain"]),
        ])
        return [
            "primaryKey": .anyOf([Self.wireColumn("primary_key"), Self.subtypeColumns("url")]),
            "workKeys": .elementRows(table: "source_work_keys"),
            "type": .columns(table: "sources", ["source_type"]),
            "typeLocked": Self.wireColumn("type_locked"),
            "title": Self.subtypeColumns("title"),
            "subtitle": Self.wireColumn("subtitle"),
            "venue": venue,
            "language": Self.wireColumn("language"),
            "authors": .anyOf([
                .columns(table: "articles", ["author"]), .columns(table: "papers", ["author"]),
                .columns(table: "x_posts", ["author"]), .columns(table: "meeting_sources", ["presenter"]),
            ]),
            "url": Self.subtypeColumns("url"),
            "doi": .columns(table: "papers", ["doi"]),
            "publishedAt": .anyOf([.columns(table: "papers", ["published_year"]), .columns(table: "videos", ["video_published_at"])]),
            "collectionID": .anyOf([.columns(table: "group_members", ["sort_index"]), venue]),
            "collectionOrder": .columns(table: "group_members", ["sort_index"]),
            "status": .columns(table: "sources", ["status"]),
            "ingest": .anyOf([.columns(table: "sources", ["state", "error_message"]), .columns(table: "papers", ["is_paywalled"])]),
            "contentHash": Self.wireColumn("content_hash"),
            "summary": Self.wireColumn("summary"),
            "metrics": .anyOf([Self.subtypeColumns("word_count"), Self.wireColumn("metrics_json")]),
            "files": .elementRows(table: "source_files"),
            "derived": .elementRows(table: "source_derived"),
            "meta": .anyOf([
                venue, .columns(table: "articles", ["domain"]), .columns(table: "meeting_sources", ["occurred_at"]),
                .columns(table: "x_posts", ["author_handle"]), .columns(table: "meeting_artifacts", SourceLocalTables.attachmentColumns),
                .columns(table: "group_members", ["sort_index"]), Self.subtypeColumns("url"), Self.wireColumn("extra_meta_json"),
                .columns(table: "book_sources", ["page_start", "page_count"]),
            ]),
            "addedAt": .columns(table: "sources", ["date_added"]),
            "madeBy": .anyOf([Self.wireColumn("made_by_json"), .columns(table: "sources", ["date_added"])]),
            "copiedFrom": Self.wireColumn("copied_from_json"),
            "mergedInto": Self.wireColumn("merged_into"),
        ]
    }

    /// A deleted `sources` row deletes the Source record (§6.6 step 5).
    var missingRow: MissingRowOutcome { .delete }

    // MARK: Reading the rows

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> SourceRows? {
        try Self.loadRows(localID: record.localID, connection: connection)
    }

    static func loadRows(localID: String, connection: SQLiteConnection) throws -> SourceRows? {
        var rows: SourceRows?
        try connection.query(
            "SELECT date_added, state, error_message, source_type, status FROM sources WHERE id = ?", [.text(localID)]
        ) { row in
            let type = row.text(3) ?? "article"
            rows = SourceRows(
                sourceID: localID, dateAdded: row.real(0) ?? 0, state: row.text(1) ?? "queued", errorMessage: row.text(2),
                sourceType: type, status: row.text(4) ?? "active", subtypeTable: SourceLocalTables.subtypeTable(forLocalType: type)
            )
        }
        guard var loaded = rows else { return nil }
        let columns = SourceLocalTables.syncedColumns(loaded.subtypeTable) + ["normalized_url", "local_file_path"]
        try connection.query(
            "SELECT \(columns.joined(separator: ", ")) FROM \(loaded.subtypeTable) WHERE source_id = ?", [.text(localID)]
        ) { row in
            for (index, column) in columns.enumerated() {
                loaded.subtype[column] = OutboxFeeder.value(row, Int32(index))
            }
        }
        loaded.membership = try collectionMembership(sourceID: localID, connection: connection)
        try connection.query("SELECT work_key FROM source_work_keys WHERE source_id = ? ORDER BY work_key", [.text(localID)]) { row in
            if let key = row.text(0) { loaded.workKeys.append(key) }
        }
        loaded.files = try fileRefs("source_files", element: "role", sourceID: localID, connection: connection)
        loaded.derived = try fileRefs("source_derived", element: "kind", sourceID: localID, connection: connection)
        loaded.wire = try wireFields(sourceID: localID, connection: connection)
        loaded.attachments = try attachments(sourceID: localID, connection: connection)
        if loaded.subtypeTable == "videos" {
            try connection.query("""
                SELECT gm.group_id, vp.title FROM group_members gm LEFT JOIN video_playlists vp ON vp.id = gm.group_id
                WHERE gm.source_id = ?
            """, [.text(localID)]) { row in
                loaded.groupNames += [row.text(0), row.text(1)].compactMap { $0 }
            }
        }
        return loaded
    }

    /// The book or meeting series a source belongs to: its `group_members` row naming a `books` or
    /// `meeting_groups` row, a book first.
    static func collectionMembership(sourceID: String, connection: SQLiteConnection) throws -> SourceCollectionMembership? {
        var membership: SourceCollectionMembership?
        try connection.query("""
            SELECT gm.group_id, gm.sort_index,
                   CASE WHEN EXISTS (SELECT 1 FROM books b WHERE b.id = gm.group_id) THEN 'book' ELSE 'meetingSeries' END AS kind
            FROM group_members gm
            WHERE gm.source_id = ?
              AND (EXISTS (SELECT 1 FROM books b WHERE b.id = gm.group_id)
                   OR EXISTS (SELECT 1 FROM meeting_groups m WHERE m.id = gm.group_id))
            ORDER BY kind, gm.group_id
            LIMIT 1
        """, [.text(sourceID)]) { row in
            guard let group = row.text(0), let kind = SourceCollectionMembership.Kind(rawValue: row.text(2) ?? "") else { return }
            membership = SourceCollectionMembership(groupID: group, sortIndex: row.integer(1), kind: kind)
        }
        return membership
    }

    private static func fileRefs(_ table: String, element: String, sourceID: String, connection: SQLiteConnection) throws -> [String: SyncJSON] {
        var refs: [String: SyncJSON] = [:]
        try connection.query("SELECT \(element), file_ref FROM \(table) WHERE source_id = ?", [.text(sourceID)]) { row in
            guard let key = row.text(0), let text = row.text(1), let json = try? SyncJSON(parsing: Data(text.utf8)) else { return }
            refs[key] = json
        }
        return refs
    }

    static func wireFields(sourceID: String, connection: SQLiteConnection) throws -> SourceWireFields {
        var fields = SourceWireFields()
        try connection.query(
            "SELECT \(SourceLocalTables.wireFieldColumns.joined(separator: ", ")) FROM source_wire_fields WHERE source_id = ?",
            [.text(sourceID)]
        ) { row in
            fields.primaryKey = row.text(0)
            fields.madeBy = SyncJSON.stored(row.text(1))
            fields.typeLocked = row.integer(2).map { $0 != 0 }
            fields.subtitle = row.text(3)
            fields.language = row.text(4)
            fields.summary = row.text(5)
            fields.contentHash = row.text(6)
            fields.metrics = SyncJSON.stored(row.text(7))?.objectValue
            fields.copiedFrom = SyncJSON.stored(row.text(8))
            fields.mergedInto = row.text(9)
            fields.extraMeta = SyncJSON.stored(row.text(10))?.objectValue ?? [:]
            fields.lossy = SourceLossyFields(json: SyncJSON.stored(row.text(11)))
        }
        return fields
    }

    /// A meeting's files and links as `meta.attachments`: `{key: {kind, title, url?, mime?, order}}`.
    private static func attachments(sourceID: String, connection: SQLiteConnection) throws -> [String: SyncJSON]? {
        var attachments: [String: SyncJSON] = [:]
        try connection.query(
            "SELECT id, kind, title, url, mime_type, sort_index FROM meeting_artifacts WHERE source_id = ?", [.text(sourceID)]
        ) { row in
            guard let id = row.text(0) else { return }
            var object: [String: SyncJSON] = ["kind": .string(row.text(1) ?? ""), "title": .string(row.text(2) ?? "")]
            if let url = row.text(3) { object["url"] = .string(url) }
            if let mime = row.text(4) { object["mime"] = .string(mime) }
            if let order = row.integer(5) { object["order"] = SyncJSON(order) }
            attachments[id] = .object(object)
        }
        return attachments.isEmpty ? nil : attachments
    }

    // MARK: Encoding (pure)

    static func encodeRows(_ rows: SourceRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [:]
        let lossy = rows.wire.lossy
        let table = rows.subtypeTable
        let url = rows.text("url")

        fields["primaryKey"] = .string(rows.wire.primaryKey ?? SourceWorkKeys.primaryKey(
            sourceID: rows.sourceID, normalizedURL: rows.text("normalized_url"), doi: rows.text("doi")
        ))
        fields["workKeys"] = .object(Dictionary(rows.workKeys.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first }))
        fields["type"] = lossy.value("type", local: typeSignature(rows.sourceType)) ?? .string(SourceLocalTables.wireType(rows.sourceType))
        if let locked = rows.wire.typeLocked { fields["typeLocked"] = .bool(locked) }
        if let title = rows.subtype["title"]?.textValue, !title.isEmpty { fields["title"] = .string(title) }
        if let subtitle = rows.wire.subtitle { fields["subtitle"] = .string(subtitle) }
        if let language = rows.wire.language { fields["language"] = .string(language) }
        if let venue = venue(rows) { fields["venue"] = .string(venue) }

        let authorColumn = SourceLocalTables.authorColumn(table)
        let author = authorColumn.flatMap { rows.text($0) }
        if let authors = lossy.value("authors", local: authorsSignature(author)) {
            fields["authors"] = authors
        } else if let author {
            fields["authors"] = .array([.string(author)])
        }
        if let url { fields["url"] = .string(url) }
        if table == "papers", let doi = rows.text("doi") { fields["doi"] = .string(doi) }
        let published = publishedSignature(rows)
        if let publishedAt = lossy.value("publishedAt", local: published) ?? publishedMilliseconds(rows) {
            fields["publishedAt"] = publishedAt
        }

        if let membership = rows.membership {
            fields["collectionID"] = .string(membership.groupID)
            let local = orderSignature(membership.sortIndex)
            if let order = lossy.value("collectionOrder", local: local) ?? membership.sortIndex.flatMap(SourceOrderKeys.key(forIndex:)).map(SyncJSON.string) {
                fields["collectionOrder"] = order
            }
        } else if let collectionID = derivedCollectionID(rows) {
            fields["collectionID"] = .string(collectionID)
        }

        fields["status"] = .string(rows.status == "archived" ? "archived" : "active")
        fields["ingest"] = ingest(rows)
        if let contentHash = rows.wire.contentHash { fields["contentHash"] = .string(contentHash) }
        if let summary = rows.wire.summary { fields["summary"] = .string(summary) }
        var metrics = rows.wire.metrics ?? [:]
        if let words = rows.integer("word_count") { metrics["wordCount"] = SyncJSON(words) }
        if !metrics.isEmpty { fields["metrics"] = .object(metrics) }
        fields["files"] = .object(rows.files)
        fields["derived"] = .object(rows.derived)
        let meta = meta(rows)
        if !meta.isEmpty { fields["meta"] = .object(meta) }
        fields["addedAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.dateAdded))
        // A source made before this Mac knew its device id names no device.
        fields["madeBy"] = rows.wire.madeBy
            ?? .object(["route": .string("app"), "at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.dateAdded))])
        if let copiedFrom = rows.wire.copiedFrom { fields["copiedFrom"] = copiedFrom }
        if let mergedInto = rows.wire.mergedInto { fields["mergedInto"] = .string(mergedInto) }
        return fields
    }

    /// The journal, show or channel line.
    static func venue(_ rows: SourceRows) -> String? {
        switch rows.subtypeTable {
        case "papers": return rows.text("journal")
        case "podcasts": return rows.text("show_name") ?? rows.text("domain")
        case "videos": return rows.text("domain")
        default: return nil
        }
    }

    /// The show's or channel's collection, whose id follows from its name (`source_collections`).
    static func derivedCollectionID(_ rows: SourceRows) -> String? {
        switch rows.sourceType {
        case "podcast":
            return venue(rows).map { SyncIdentity.collectionID(kind: "podcastShow", externalKey: $0) }
        case "video":
            return SourceCollections.channelName(domain: rows.text("domain"), url: rows.text("url"), groupNames: rows.groupNames)
                .map { SyncIdentity.collectionID(kind: "youtubeChannel", externalKey: $0) }
        default:
            return nil
        }
    }

    // The column values each lossy field was written as.
    static func typeSignature(_ localType: String) -> SyncJSON { .string(localType) }
    static func authorsSignature(_ author: String?) -> SyncJSON { author.map(SyncJSON.string) ?? .null }
    static func orderSignature(_ sortIndex: Int64?) -> SyncJSON { sortIndex.map { SyncJSON($0) } ?? .null }

    static func publishedSignature(_ rows: SourceRows) -> SyncJSON {
        switch rows.subtypeTable {
        case "papers": return rows.text("published_year").map(SyncJSON.string) ?? .null
        case "videos": return rows.real("video_published_at").map(SyncJSON.number) ?? .null
        default: return .null
        }
    }

    static func ingestSignature(state: String, paywalled: Bool, error: String?) -> SyncJSON {
        .object(["state": .string(state), "paywalled": .bool(paywalled), "error": error.map(SyncJSON.string) ?? .null])
    }

    /// A paper's year as the first millisecond of that year, UTC; a video's publication time.
    static func publishedMilliseconds(_ rows: SourceRows) -> SyncJSON? {
        switch rows.subtypeTable {
        case "papers":
            guard let text = rows.text("published_year"), text.count == 4, let year = Int(text) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
            return SyncJSON(SyncTime.milliseconds(date))
        case "videos":
            return rows.real("video_published_at").map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) }
        default:
            return nil
        }
    }

    /// The ingest state as the wire ranks it (§3.5.4): queued 1, fetching 2, error and paywalled 3,
    /// ready 4.
    static func ingestRank(_ state: String) -> Int {
        switch state {
        case "ready": return 4
        case "error", "paywalled": return 3
        case "fetching": return 2
        default: return 1
        }
    }

    /// The paper's paywall is its own wire state until the paper holds its PDF: a paper is `ready`
    /// only with a PDF (§3.5.4), and `ingest` is the only place the wire has for the flag. A paper
    /// left `ready` on its abstract and paywalled, sent as `ready`, would have the device applying the
    /// record clear the flag, and the paper would come back as PDF needed.
    static func wireIngestState(_ rows: SourceRows) -> String {
        if rows.isPaywalled, rows.state != "ready" || !rows.holdsPDF { return "paywalled" }
        switch rows.state {
        case "ready", "fetching", "error": return rows.state
        default: return "queued"
        }
    }

    /// `ingest`, monotonic by `ord` (X): the value the record came with while the columns hold what it
    /// was written as; else the local state at the generation it holds, or at the next one when the
    /// local state went back (a deliberate re-fetch on this Mac), so it is never lowered by the merge.
    static func ingest(_ rows: SourceRows) -> SyncJSON {
        let signature = ingestSignature(state: rows.state, paywalled: rows.isPaywalled, error: rows.errorMessage)
        if let kept = rows.wire.lossy.value("ingest", local: signature) { return kept }
        let state = wireIngestState(rows)
        let rank = ingestRank(state)
        let heldIngest = rows.wire.lossy.entries["ingest"]?.wire
        let held = heldIngest?["ord"]?.arrayValue
        var generation = held?.first?.int64Value ?? 0
        if let heldRank = held?.dropFirst().first?.int64Value {
            // `error` and `paywalled` share rank 3, and an equal `ord` keeps the server's value, so marking
            // a failed paper paywalled (or clearing the mark) would never leave this Mac. A different
            // state at the same rank is a new generation too.
            let heldState = heldIngest?["state"]?.stringValue
            if Int64(rank) < heldRank || (Int64(rank) == heldRank && heldState != nil && heldState != state) { generation += 1 }
        }
        var object: [String: SyncJSON] = ["ord": .array([SyncJSON(generation), SyncJSON(rank)]), "state": .string(state)]
        if state == "error", let error = rows.errorMessage { object["error"] = .string(error) }
        return .object(object)
    }

    /// The documented `meta` keys per type (§3.5.4) the columns hold, over the keys no column holds.
    static func meta(_ rows: SourceRows) -> [String: SyncJSON] {
        var meta = rows.wire.extraMeta
        func set(_ key: String, _ value: String?) {
            if let value { meta[key] = .string(value) }
        }
        switch rows.subtypeTable {
        case "papers":
            set("journal", rows.text("journal"))
        case "podcasts":
            set("showName", rows.text("show_name") ?? rows.text("domain"))
        case "videos":
            set("youtubeID", rows.text("url").flatMap(ForeverLMCore.youtubeVideoID(from:)))
            set("channelName", rows.text("domain"))
        case "meeting_sources":
            if let startAt = rows.real("occurred_at") { meta["startAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: startAt)) }
            if rows.membership?.kind == .meetingSeries { set("groupKey", rows.membership?.groupID) }
            if let attachments = rows.attachments { meta["attachments"] = .object(attachments) }
        case "book_sources":
            if rows.membership?.kind == .book { set("bookID", rows.membership?.groupID) }
            // A chapter of a book kept as one file: its pages of the book's file, which `files.pdf` names.
            if let start = rows.integer("page_start"), let count = rows.integer("page_count"), start >= 0, count > 0 {
                meta["pageStart"] = SyncJSON(start)
                meta["pageCount"] = SyncJSON(count)
            }
        case "x_posts":
            set("postID", rows.text("url").flatMap { WorkKey.normalizeRemote("x:" + $0) }.map { String($0.dropFirst(2)) })
            set("handle", rows.text("author_handle"))
        case "articles":
            set("siteName", rows.text("domain"))
        default:
            break
        }
        return meta
    }

    /// The `meta` keys the columns hold or derive, per per-type table: an inbound value of one of
    /// these goes to its column (or is derived again), never into `extra_meta_json`.
    static func columnMetaKeys(_ table: String) -> Set<String> {
        switch table {
        case "papers": return ["journal"]
        case "podcasts": return ["showName"]
        case "videos": return ["youtubeID", "channelName"]
        case "meeting_sources": return ["startAt", "groupKey"]
        case "book_sources": return ["bookID", "pageStart", "pageCount"]
        case "x_posts": return ["postID", "handle"]
        case "articles": return ["siteName"]
        default: return []
        }
    }
}

// MARK: - Applying an inbound Source

extension SourceProjection {
    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        let fields = envelope.fields
        var localID = record.localID
        var teamID: String?
        if case .space(let spaceID) = record.zone {
            // A space's copy has a local id of its own beside the personal copy (§4.3) and carries the
            // space in `team_id`, as a team copy does today: a team's own id when the space was a team.
            teamID = try SpaceRows.localTeamID(spaceID: spaceID, connection: connection)
            if localID == record.wireID {
                localID = SpaceLocalID.localID(spaceID: spaceID, type: .source, wireID: record.wireID)
                try connection.recordIdentity(
                    zoneKey: record.zoneKey, recordType: SyncRecordType.source.rawValue, wireID: record.wireID, localID: localID
                )
            }
        }
        let existing = try Self.loadRows(localID: localID, connection: connection)
        var lossy = existing?.wire.lossy ?? SourceLossyFields()
        // The text the source's pointer named before this record: a local text equal to it is an untouched
        // copy, which a newer pointer may replace (`InboundSourceFiles`).
        let previousText = existing?.files[InboundSourceFiles.textRole].flatMap(FileRef.init(json:))?.hash

        // The type and the per-type table.
        var localType = existing?.sourceType ?? "article"
        if let wireType = fields["type"]?.stringValue {
            if SourceLocalTables.wireType(localType) != wireType || existing == nil {
                localType = SourceLocalTables.localType(wireType)
            }
            lossy.entries["type"] = .init(wire: .string(wireType), local: Self.typeSignature(localType))
        }
        let table = SourceLocalTables.subtypeTable(forLocalType: localType)

        // Ingest: the local state, error and paywall the wire state is held as.
        var state = existing?.state ?? "queued"
        var errorMessage = existing?.errorMessage
        var paywalled = existing?.isPaywalled ?? false
        if let ingest = fields["ingest"], let wireState = ingest["state"]?.stringValue {
            switch wireState {
            case "ready":
                state = "ready"
                errorMessage = nil
            case "fetching", "queued":
                state = wireState
                errorMessage = nil
            case "paywalled":
                state = "error"
                paywalled = true
            default:
                state = "error"
                if let error = ingest["error"]?.stringValue { errorMessage = error }
            }
            // A paywalled paper always goes out as `paywalled` (`wireIngestState`), so any other state
            // says the mark is off: a mark cleared on a failed paper arrives as `error` and clears it here.
            paywalled = wireState == "paywalled" && table == "papers"
            lossy.entries["ingest"] = .init(
                wire: ingest,
                local: Self.ingestSignature(state: state, paywalled: paywalled, error: errorMessage)
            )
        }

        let addedAt = fields["addedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
            ?? existing?.dateAdded
            ?? (fields["madeBy"]?["at"]?.int64Value ?? fields["editedAt"]?.int64Value).map { SyncTime.cocoaSeconds(milliseconds: $0) }
            ?? 0
        let status = fields["status"]?.stringValue.map { $0 == "archived" ? "archived" : "active" } ?? existing?.status ?? "active"
        try connection.execute("""
            INSERT INTO sources (id, date_added, state, error_message, source_type, status, archived_at, team_id, wire_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                date_added = excluded.date_added, state = excluded.state, error_message = excluded.error_message,
                source_type = excluded.source_type, status = excluded.status,
                archived_at = CASE WHEN excluded.status = 'archived' THEN COALESCE(sources.archived_at, excluded.archived_at) END,
                team_id = COALESCE(excluded.team_id, sources.team_id), wire_id = excluded.wire_id
        """, [
            .text(localID), .real(addedAt), .text(state), .text(errorMessage), .text(localType), .text(status),
            .text(status == "archived" ? KnowledgeStore.iso8601Formatter.string(from: Date()) : nil), .text(teamID), .text(record.wireID),
        ])

        try applySubtype(fields, table: table, localID: localID, existing: existing, paywalled: paywalled, lossy: &lossy, connection: connection)
        try applyMembership(fields, localID: localID, existing: existing, lossy: &lossy, connection: connection)
        try applyElements(fields["workKeys"], table: "source_work_keys", element: "work_key", localID: localID, connection: connection) { _, value in
            value.boolValue == true ? "" : nil
        }
        try applyElements(fields["files"], table: "source_files", element: "role", localID: localID, connection: connection) { _, value in
            value.isNull ? nil : String(decoding: value.serialized(), as: UTF8.self)
        }
        try applyElements(fields["derived"], table: "source_derived", element: "kind", localID: localID, connection: connection) { _, value in
            value.isNull ? nil : String(decoding: value.serialized(), as: UTF8.self)
        }
        try applyWireFields(fields, table: table, localID: localID, existing: existing, lossy: lossy, connection: connection)

        // A source another device finished ingesting is finished here: the paper is attested, and the text and
        // PDF its pointers name are queued for the satellite reader, so no sweep runs the ingestion again.
        if table == "papers", fields["ingest"]?["state"]?.stringValue == "ready" {
            try InboundSourceFiles.attestFromRecord(sourceID: localID, connection: connection)
        }
        try InboundSourceFiles.take(
            sourceID: localID, localType: localType, table: table, zone: record.zone, zoneKey: record.zoneKey,
            previousText: previousText, connection: connection
        )
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        // Its per-type row, keys, files, memberships and attachments go with it; per-member rows stay
        // (D18: since schema 154 they have no foreign key to `sources`).
        try connection.execute("DELETE FROM sources WHERE id = ?", [.text(record.localID)])
        // What the satellite reader or the publisher still owed the source goes with it.
        try connection.execute(
            "DELETE FROM ck_backfill_queue WHERE target = ? AND kind IN (?, ?)",
            [.text(record.localID), .text(InboundSourceFiles.queueKind), .text(KnowledgeStore.sourcePublishKind)]
        )
        if record.zone.isSpace {
            try connection.execute(
                "DELETE FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
                [.text(record.zoneKey), .text(SyncRecordType.source.rawValue), .text(record.wireID)]
            )
        }
    }

    /// The per-type row: what it held (or, after a change of type, what the old table's row held),
    /// with the fields the record carries written over it. Absent fields keep their columns (§3.2 rule 6).
    private func applySubtype(
        _ fields: [String: SyncJSON], table: String, localID: String, existing: SourceRows?, paywalled: Bool,
        lossy: inout SourceLossyFields, connection: SQLiteConnection
    ) throws {
        var row: [String: SQLiteValue] = [:]
        var carried: [String: SQLiteValue] = [:]
        var releasesLocalFile = false
        if let existing {
            for column in SourceLocalTables.commonColumns + ["local_file_path"] {
                if let value = existing.subtype[column] { row[column] = value }
            }
            if existing.subtypeTable == table {
                for (column, value) in existing.subtype where column != "normalized_url" { row[column] = value }
            } else {
                // A change of type moves the row to its new table, with what both tables hold.
                try connection.query(
                    "SELECT artwork_url, discovery_origin FROM \(existing.subtypeTable) WHERE source_id = ?", [.text(localID)]
                ) { old in
                    carried["artwork_url"] = OutboxFeeder.value(old, 0)
                    carried["discovery_origin"] = OutboxFeeder.value(old, 1)
                }
                carried["local_file_path"] = existing.subtype["local_file_path"] ?? .null
            }
        }
        func string(_ field: String) -> SQLiteValue? {
            guard let value = fields[field] else { return nil }
            return value.isNull ? .null : value.stringValue.map(SQLiteValue.text)
        }
        if let title = string("title") { row["title"] = title }
        if let url = string("url") { row["url"] = url }
        if let words = fields["metrics"]?["wordCount"] { row["word_count"] = words.int64Value.map(SQLiteValue.integer) ?? .null }

        let meta = fields["meta"]?.objectValue ?? [:]
        let venue = string("venue")
        switch table {
        case "papers":
            if let doi = string("doi") { row["doi"] = doi }
            if let journal = meta["journal"].map({ $0.stringValue.map(SQLiteValue.text) ?? .null }) ?? venue { row["journal"] = journal }
            row["is_paywalled"] = .integer(paywalled ? 1 : 0)
        case "podcasts":
            if let show = meta["showName"].map({ $0.stringValue.map(SQLiteValue.text) ?? .null }) ?? venue {
                row["show_name"] = show
                row["domain"] = show == .null ? .text("") : show
            }
        case "videos":
            if let channel = meta["channelName"].map({ $0.stringValue.map(SQLiteValue.text) ?? .null }) ?? venue {
                row["domain"] = channel == .null ? .text("") : channel
            }
        case "meeting_sources":
            if let startAt = meta["startAt"] {
                row["occurred_at"] = startAt.int64Value.map { .real(SyncTime.cocoaSeconds(milliseconds: $0)) } ?? .null
            }
        case "x_posts":
            if let handle = meta["handle"] { row["author_handle"] = handle.stringValue.map(SQLiteValue.text) ?? .null }
        case "articles":
            if let site = meta["siteName"] { row["domain"] = .text(site.stringValue ?? "") }
        case "book_sources":
            if fields["meta"] != nil {
                // A chapter of a book kept as one file. A file this Mac held as the chapter's
                // own is not the book's: once the record names other pages, it is let go and
                // the book's file is fetched in its place (`InboundSourceFiles.take`).
                let pages = Self.bookPages(meta)
                row["page_start"] = pages.map { .integer(Int64($0.lowerBound)) } ?? .null
                row["page_count"] = pages.map { .integer(Int64($0.count)) } ?? .null
                if pages != nil,
                   existing?.subtype["page_start"] != row["page_start"] || existing?.subtype["page_count"] != row["page_count"] {
                    releasesLocalFile = true
                }
            }
        default:
            break
        }

        if let authors = fields["authors"], let column = SourceLocalTables.authorColumn(table) {
            let joined = authors.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty }.joined(separator: ", ")
            let local: String? = joined?.isEmpty == false ? joined : nil
            row[column] = .text(local)
            lossy.entries["authors"] = .init(wire: authors, local: Self.authorsSignature(local))
        }
        if let published = fields["publishedAt"] {
            let date = published.int64Value.map { SyncTime.date(milliseconds: $0) }
            switch table {
            case "papers":
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                let year = date.map { String(calendar.component(.year, from: $0)) }
                row["published_year"] = .text(year)
                lossy.entries["publishedAt"] = .init(wire: published, local: year.map(SyncJSON.string) ?? .null)
            case "videos":
                let seconds = date?.timeIntervalSinceReferenceDate
                row["video_published_at"] = .real(seconds)
                lossy.entries["publishedAt"] = .init(wire: published, local: seconds.map(SyncJSON.number) ?? .null)
            default:
                break
            }
        }

        if row["url"] == nil || row["url"] == .null { row["url"] = .text("") }
        if row["domain"] == nil || row["domain"] == .null { row["domain"] = .text("") }
        if let url = row["url"]?.textValue, !url.isEmpty {
            row["normalized_url"] = .text(URLNormalizer.normalize(url))
        }
        // Only the table's own columns, and what a change of type carries into it.
        let tableColumns = Set(SourceLocalTables.syncedColumns(table) + ["normalized_url", "local_file_path"])
        var write = row.filter { tableColumns.contains($0.key) }
        for (column, value) in carried where write[column] == nil { write[column] = value }
        let columns = write.keys.sorted()
        let updates = columns.filter { $0 != "local_file_path" && $0 != "artwork_url" && $0 != "discovery_origin" }
        let conflict = updates.isEmpty
            ? "DO NOTHING"
            : "DO UPDATE SET " + updates.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try connection.execute("""
            INSERT INTO \(table) (source_id, \(columns.joined(separator: ", ")))
            VALUES (?\(String(repeating: ", ?", count: columns.count)))
            ON CONFLICT(source_id) \(conflict)
        """, [.text(localID)] + columns.map { write[$0] ?? .null })
        if releasesLocalFile {
            try connection.execute("UPDATE book_sources SET local_file_path = NULL WHERE source_id = ?", [.text(localID)])
        }
        for other in SourceLocalTables.subtypeTables where other != table {
            try connection.execute("DELETE FROM \(other) WHERE source_id = ?", [.text(localID)])
        }
    }

    /// A book chapter's pages of its book's file from `meta`: nil unless both are whole numbers making
    /// a run.
    static func bookPages(_ meta: [String: SyncJSON]) -> Range<Int>? {
        guard let start = meta["pageStart"]?.int64Value, let count = meta["pageCount"]?.int64Value,
              start >= 0, count > 0 else { return nil }
        return Int(start)..<Int(start + count)
    }

    /// `collectionID` and `collectionOrder` as the source's book or meeting-series membership. A
    /// show's or channel's collection follows from the venue and needs no row; a playlist's and a
    /// course's memberships are other records' and are left alone.
    private func applyMembership(
        _ fields: [String: SyncJSON], localID: String, existing: SourceRows?, lossy: inout SourceLossyFields,
        connection: SQLiteConnection
    ) throws {
        guard let collection = fields["collectionID"] else { return }
        let groupID = collection.stringValue.flatMap { $0.hasPrefix("col_") ? nil : $0 }
        // Memberships that are neither a playlist's nor a course's: the source's collection.
        try connection.execute("""
            DELETE FROM group_members
            WHERE source_id = ? AND group_id IS NOT ?
              AND group_id NOT LIKE 'playlist\\_%' ESCAPE '\\' AND group_id <> source_id
              AND NOT EXISTS (SELECT 1 FROM courses c WHERE c.id = group_members.group_id)
        """, [.text(localID), .text(groupID)])
        guard let groupID else { return }
        var sortIndex = existing?.membership?.groupID == groupID ? existing?.membership?.sortIndex : nil
        if let order = fields["collectionOrder"] {
            if let key = order.stringValue, let index = SourceOrderKeys.index(ofKey: key) {
                sortIndex = index
            } else if order.isNull {
                sortIndex = nil
            }
            lossy.entries["collectionOrder"] = .init(wire: order, local: Self.orderSignature(sortIndex))
        }
        try connection.execute("""
            INSERT INTO group_members (source_id, group_id, sort_index) VALUES (?, ?, ?)
            ON CONFLICT(source_id, group_id) DO UPDATE SET sort_index = excluded.sort_index
        """, [.text(localID), .text(groupID), .integer(sortIndex)])
    }

    /// A set's or map's elements as rows: a present element written, a removed one (`false`, `null`)
    /// deleted, an element the record does not name left alone (absent is not empty, §3.2 rule 6).
    private func applyElements(
        _ value: SyncJSON?, table: String, element: String, localID: String, connection: SQLiteConnection,
        stored: (String, SyncJSON) -> String?
    ) throws {
        guard let elements = value?.objectValue else { return }
        for (key, item) in elements.sorted(by: { $0.key < $1.key }) {
            guard let text = stored(key, item) else {
                try connection.execute("DELETE FROM \(table) WHERE source_id = ? AND \(element) = ?", [.text(localID), .text(key)])
                continue
            }
            if table == "source_work_keys" {
                try connection.execute(
                    "INSERT INTO source_work_keys (source_id, work_key) VALUES (?, ?) ON CONFLICT(source_id, work_key) DO NOTHING",
                    [.text(localID), .text(key)]
                )
            } else {
                // A new FileRef for the role forgets where this Mac held the old bytes.
                try connection.execute("""
                    INSERT INTO \(table) (source_id, \(element), file_ref) VALUES (?, ?, ?)
                    ON CONFLICT(source_id, \(element)) DO UPDATE SET
                        local_path = CASE WHEN \(table).file_ref = excluded.file_ref THEN \(table).local_path END,
                        file_ref = excluded.file_ref
                """, [.text(localID), .text(key), .text(text)])
            }
        }
    }

    private func applyWireFields(
        _ fields: [String: SyncJSON], table: String, localID: String, existing: SourceRows?, lossy: SourceLossyFields,
        connection: SQLiteConnection
    ) throws {
        var wire = existing?.wire ?? SourceWireFields()
        func text(_ field: String, _ keyPath: WritableKeyPath<SourceWireFields, String?>) {
            if let value = fields[field] { wire[keyPath: keyPath] = value.stringValue }
        }
        text("primaryKey", \.primaryKey)
        text("subtitle", \.subtitle)
        text("language", \.language)
        text("summary", \.summary)
        text("contentHash", \.contentHash)
        text("mergedInto", \.mergedInto)
        if let madeBy = fields["madeBy"] { wire.madeBy = madeBy.isNull ? nil : madeBy }
        if let copiedFrom = fields["copiedFrom"] { wire.copiedFrom = copiedFrom.isNull ? nil : copiedFrom }
        if let locked = fields["typeLocked"] { wire.typeLocked = locked.boolValue }
        if let metrics = fields["metrics"] { wire.metrics = metrics.objectValue }
        if let meta = fields["meta"]?.objectValue {
            let owned = Self.columnMetaKeys(table)
            for (key, value) in meta where !owned.contains(key) {
                wire.extraMeta[key] = value.isNull ? nil : value
            }
        }
        wire.lossy = lossy

        func json(_ value: SyncJSON?) -> SQLiteValue {
            .text(value.map { String(decoding: $0.serialized(), as: UTF8.self) })
        }
        let values: [SQLiteValue] = [
            .text(wire.primaryKey), json(wire.madeBy), .integer(wire.typeLocked.map { $0 ? 1 : 0 }), .text(wire.subtitle),
            .text(wire.language), .text(wire.summary), .text(wire.contentHash), json(wire.metrics.map(SyncJSON.object)),
            json(wire.copiedFrom), .text(wire.mergedInto), json(wire.extraMeta.isEmpty ? nil : .object(wire.extraMeta)),
            json(wire.lossy.entries.isEmpty ? nil : wire.lossy.json),
        ]
        let columns = SourceLocalTables.wireFieldColumns
        try connection.execute("""
            INSERT INTO source_wire_fields (source_id, \(columns.joined(separator: ", ")))
            VALUES (?\(String(repeating: ", ?", count: columns.count)))
            ON CONFLICT(source_id) DO UPDATE SET \(columns.map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
        """, [.text(localID)] + values)
    }
}

// MARK: - Order keys for a group's sort index

/// A chapter's or session's `collectionOrder` from its `group_members.sort_index`: the fractional key of
/// that position among consecutive integers (`a0`, `a1`, …), so every Mac derives the same key.
enum SourceOrderKeys {
    private static let precomputed: [String] = (try? FractionalIndex.keys(between: nil, and: nil, count: 4_096)) ?? []
    private static let indexes: [String: Int64] = Dictionary(
        precomputed.enumerated().map { ($0.element, Int64($0.offset)) }, uniquingKeysWith: { first, _ in first }
    )

    static func key(forIndex index: Int64) -> String? {
        guard index >= 0 else { return precomputed.first }
        if index < precomputed.count { return precomputed[Int(index)] }
        return try? FractionalIndex.keys(between: nil, and: nil, count: Int(index) + 1).last
    }

    /// The sort index a key names, when it is one of those keys.
    static func index(ofKey key: String) -> Int64? {
        indexes[key]
    }
}

// MARK: - A space copy's local id (§4.3)

/// The local id a record's copy in a space takes, beside the personal copy that already has the wire id:
/// `<prefix of the record type> + hex(sha256("space:v1:" + spaceID + ":" + wireID))`. The prefix comes
/// from the record type, never from the wire id, since many personal source ids are bare UUIDs.
enum SpaceLocalID {
    static func localID(spaceID: String, type: SyncRecordType, wireID: String) -> String {
        let prefix: String
        switch type {
        case .source: prefix = "src_"
        case .notebook: prefix = "proj_"
        case .artifact: prefix = "doc_"
        case .chat: prefix = "chat_"
        case .course: prefix = "course_"
        default: prefix = "sp_"
        }
        return prefix + SyncIdentity.sha256Hex(Data("space:v1:\(spaceID):\(wireID)".utf8))
    }
}

// MARK: - Work keys (§4.2)

/// A source's work keys from what its rows say about it: its address as URLNormalizer v1 gives it,
/// the iPhone's historical form of that address where it differs (`MobileURLNormalizer`, the form the
/// phone minted ids with, §4.1), the DOI, arXiv id, YouTube video, X post or GitHub repository the
/// address or the DOI columns name, and the `file:` hash of its original bytes when known. Every key
/// is normalized by `WorkKey`, except the iPhone's form, which is kept as the phone wrote it so a source
/// it minted is found by it.
///
/// A preprint's published DOI is not a work key. The journal version is a second version of the
/// work, its own source with its own highlights and notebooks, and a key it shared with the preprint
/// would find the preprint when the journal version is imported and have duplicate resolution fold
/// the two together.
enum SourceWorkKeys {
    static func keys(url: String?, normalizedURL: String?, doi: String? = nil, fileHash: String? = nil) -> [String] {
        var keys = Set<String>()
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            let normalized = normalizedURL?.isEmpty == false ? normalizedURL! : URLNormalizer.normalize(url)
            keys.insert("url:" + normalized)
            let lowered = url.lowercased()
            if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
                let phone = MobileURLNormalizer.normalize(url)
                if !phone.isEmpty, phone != normalized { keys.insert("url:" + phone) }
                if let host = URLComponents(string: url)?.host?.lowercased() {
                    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                    if bare == "x.com" || bare == "twitter.com", let key = WorkKey.normalizeRemote("x:" + url) { keys.insert(key) }
                    if bare == "github.com", let key = WorkKey.normalizeRemote("gh:" + url) { keys.insert(key) }
                }
            }
            for kind in ["doi", "arxiv"] {
                if let key = WorkKey.normalizeRemote(kind + ":" + url) { keys.insert(key) }
            }
            if let video = ForeverLMCore.youtubeVideoID(from: url) { keys.insert("yt:" + video) }
        }
        if let doi, !doi.isEmpty, let key = WorkKey.normalizeRemote("doi:" + doi) { keys.insert(key) }
        if let fileHash, let key = WorkKey.normalizeRemote("file:" + fileHash) { keys.insert(key) }
        return keys.sorted()
    }

    /// The key the id was minted from (`Source.primaryKey`): a web source's address when its id is that
    /// address's stable id, else the id itself as a native key.
    static func primaryKey(sourceID: String, normalizedURL: String?, doi: String?) -> String {
        if let normalizedURL, !normalizedURL.isEmpty, SyncIdentity.sourceID(normalizedURL: normalizedURL) == sourceID {
            return "url:" + normalizedURL
        }
        return "native:" + sourceID
    }
}

// MARK: - Collections a source's columns name (§3.5.5)

/// A podcast's show and a YouTube video's channel are collections no table holds: their records are
/// derived from the episodes and videos (`source_collections`), by kind and name. The Mac holds no
/// feed URL or channel id for today's rows, so the show or channel name is their external key (a
/// correction of §3.5.5).
enum SourceCollections {
    /// A YouTube video's channel from its `domain`, which rows imported before channel capture may fill
    /// with something else: the playlist title ("Liked videos", "ForeverLM"), its group, or the address's
    /// host. The rule of `StudioViewModel.videoChannelName(for:)`.
    static func channelName(domain: String?, url: String?, groupNames: [String]) -> String? {
        guard let url, ForeverLMCore.youtubeVideoID(from: url) != nil,
              let domain = domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty
        else { return nil }
        let refused = ["Liked videos", YouTubeService.foreverLMPlaylistName] + groupNames + [URL(string: url)?.host].compactMap { $0 }
        guard !refused.contains(where: { domain.compare($0, options: .caseInsensitive) == .orderedSame }) else { return nil }
        return domain
    }
}
