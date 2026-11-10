import Foundation
import os

// MARK: - Collection (docs/cloudkit-schema-design.md §3.5.5)

/// A collection's local row: a book (`books`), a meeting series (`meeting_groups`), a followed playlist
/// (`video_playlists`), or one no generation-1 table holds (`source_collections`: podcast shows,
/// YouTube channels, a playlist with members and no `video_playlists` row).
enum CollectionRows: Equatable, Sendable {
    case book(id: String, title: String, subtitle: String?, author: String?)
    case meetingSeries(id: String, title: String, driveFolderURL: String?, recurrenceRule: String?, timezone: String?, mergedInto: String?, schedule: [String: SyncJSON]?)
    case playlist(title: String, url: String)
    case derived(kind: String, externalKey: String, title: String, subtitle: String?, author: String?, feed: SyncJSON?, status: String, addedAt: Double?)
}

/// The Collection record's projection (§3.5.5). Following a feed, channel or playlist (whether it
/// refreshes and auto-imports), a hidden show or group, and a meeting folder on this Mac's disk are
/// per member or per device, so `auto_import`, `is_hidden`, `last_refreshed_at` and
/// `local_folder_path` are not on the record (following becomes `Mark(following)`).
/// A Collection in a space is kept in the replica and projected by the space packages, since
/// these tables hold no space copies.
struct CollectionProjection: RecordProjection {
    var recordType: SyncRecordType { .collection }

    static let tableColumns: [String: [String]] = [
        "books": ["title", "subtitle", "author"],
        "meeting_groups": ["title", "drive_folder_url", "recurrence_rule", "timezone", "merged_into_group_id", "schedule_json"],
        "video_playlists": ["title", "playlist_url"],
        "source_collections": ["kind", "external_key", "title", "subtitle", "author", "feed_json", "status", "added_at"],
    ]
    static let tableOrder = ["books", "meeting_groups", "video_playlists", "source_collections"]

    var tables: [ProjectedTable] {
        Self.tableOrder.map { .records($0, type: .collection, syncedColumns: Self.tableColumns[$0] ?? []) }
    }

    private static func each(_ column: String) -> FieldFeed {
        .anyOf(tableOrder.filter { tableColumns[$0]?.contains(column) == true }.map { .columns(table: $0, [column]) })
    }

    var feeds: [String: FieldFeed] {
        [
            "title": Self.each("title"),
            "subtitle": Self.each("subtitle"),
            "author": Self.each("author"),
            "externalKey": .anyOf([.columns(table: "video_playlists", ["playlist_url"]), .columns(table: "source_collections", ["external_key"])]),
            "feed": .anyOf([.columns(table: "video_playlists", ["playlist_url"]), .columns(table: "source_collections", ["feed_json"])]),
            "schedule": .columns(table: "meeting_groups", ["drive_folder_url", "recurrence_rule", "timezone", "schedule_json"]),
            "mergedInto": .columns(table: "meeting_groups", ["merged_into_group_id"]),
            "status": .columns(table: "source_collections", ["status"]),
            "addedAt": .columns(table: "source_collections", ["added_at"]),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> CollectionRows? {
        try Self.loadRows(id: record.localID, connection: connection)
    }

    static func loadRows(id: String, connection: SQLiteConnection) throws -> CollectionRows? {
        var rows: CollectionRows?
        try connection.query("SELECT title, subtitle, author FROM books WHERE id = ?", [.text(id)]) { row in
            rows = .book(id: id, title: row.text(0) ?? "", subtitle: row.text(1), author: row.text(2))
        }
        if rows != nil { return rows }
        try connection.query("""
            SELECT title, drive_folder_url, recurrence_rule, timezone, merged_into_group_id, schedule_json
            FROM meeting_groups WHERE id = ?
        """, [.text(id)]) { row in
            let schedule = row.text(5).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue
            rows = .meetingSeries(
                id: id, title: row.text(0) ?? "", driveFolderURL: row.text(1), recurrenceRule: row.text(2), timezone: row.text(3),
                mergedInto: row.text(4), schedule: schedule
            )
        }
        if rows != nil { return rows }
        try connection.query("SELECT title, playlist_url FROM video_playlists WHERE id = ?", [.text(id)]) { row in
            rows = .playlist(title: row.text(0) ?? "", url: row.text(1) ?? "")
        }
        if rows != nil { return rows }
        try connection.query("""
            SELECT kind, external_key, title, subtitle, author, feed_json, status, added_at FROM source_collections WHERE id = ?
        """, [.text(id)]) { row in
            rows = .derived(
                kind: row.text(0) ?? "", externalKey: row.text(1) ?? "", title: row.text(2) ?? "", subtitle: row.text(3),
                author: row.text(4), feed: row.text(5).flatMap { try? SyncJSON(parsing: Data($0.utf8)) },
                status: row.text(6) ?? "active", addedAt: row.real(7)
            )
        }
        return rows
    }

    /// A playlist's id in its address (`list=`), what can be followed.
    static func playlistID(_ url: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == "list" }?.value
    }

    /// A book's, a meeting series' and a followed playlist's archive state has no column here, so it is
    /// left as the record holds it; only a derived collection's is encoded.
    static func encodeRows(_ rows: CollectionRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [:]
        func set(_ field: String, _ value: String?) {
            if let value, !value.isEmpty { fields[field] = .string(value) }
        }
        switch rows {
        case .book(let id, let title, let subtitle, let author):
            fields["kind"] = .string("book")
            // A book and a meeting series are keyed by their own id.
            set("externalKey", id)
            set("title", title)
            set("subtitle", subtitle)
            set("author", author)
        case .meetingSeries(let id, let title, let driveFolderURL, let recurrenceRule, let timezone, let mergedInto, let schedule):
            fields["kind"] = .string("meetingSeries")
            set("externalKey", id)
            set("title", title)
            // The plan `set_meeting_schedule` keeps, with the rule, zone and Drive folder beside it.
            var object = schedule ?? [:]
            if let recurrenceRule { object["rrule"] = .string(recurrenceRule) }
            if let timezone { object["timezone"] = .string(timezone) }
            if let driveFolderURL { object["driveFolderURL"] = .string(driveFolderURL) }
            if !object.isEmpty { fields["schedule"] = .object(object) }
            set("mergedInto", mergedInto)
        case .playlist(let title, let url):
            fields["kind"] = .string("playlist")
            set("externalKey", url)
            set("title", title)
            if let list = playlistID(url) { fields["feed"] = .object(["playlistID": .string(list)]) }
        case .derived(let kind, let externalKey, let title, let subtitle, let author, let feed, let status, let addedAt):
            fields["kind"] = .string(kind)
            set("externalKey", externalKey)
            set("title", title)
            set("subtitle", subtitle)
            set("author", author)
            if let feed { fields["feed"] = feed }
            fields["status"] = .string(status == "archived" ? "archived" : "active")
            if let addedAt { fields["addedAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: addedAt)) }
        }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let id = record.localID
        let existing = try Self.loadRows(id: id, connection: connection)
        let kind = fields["kind"]?.stringValue ?? Self.kind(of: existing)
        func text(_ field: String) -> String? { fields[field]?.stringValue }
        func value(_ field: String, _ held: String?) -> SQLiteValue {
            guard let given = fields[field] else { return .text(held) }
            return .text(given.stringValue)
        }

        switch kind {
        case "book":
            var held: (title: String, subtitle: String?, author: String?) = ("", nil, nil)
            if case .book(_, let title, let subtitle, let author)? = existing { held = (title, subtitle, author) }
            try connection.execute("""
                INSERT INTO books (id, title, subtitle, author) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, subtitle = excluded.subtitle, author = excluded.author
            """, [.text(id), .text(text("title") ?? held.title), value("subtitle", held.subtitle), value("author", held.author)])
            try BookCovers.take(bookID: id, fields: fields, connection: connection)

        case "meetingSeries":
            var held: (title: String, drive: String?, rule: String?, zone: String?, merged: String?, schedule: [String: SyncJSON]?) = ("", nil, nil, nil, nil, nil)
            if case .meetingSeries(_, let title, let drive, let rule, let zone, let merged, let schedule)? = existing {
                held = (title, drive, rule, zone, merged, schedule)
            }
            var drive = held.drive, rule = held.rule, zone = held.zone, plan = held.schedule
            if let schedule = fields["schedule"] {
                var object = schedule.objectValue ?? [:]
                drive = object.removeValue(forKey: "driveFolderURL")?.stringValue
                rule = object.removeValue(forKey: "rrule")?.stringValue
                zone = object.removeValue(forKey: "timezone")?.stringValue
                plan = object.isEmpty ? nil : object
            }
            let planText = plan.map { String(decoding: SyncJSON.object($0).serialized(), as: UTF8.self) }
            try connection.execute("""
                INSERT INTO meeting_groups (id, title, drive_folder_url, recurrence_rule, timezone, merged_into_group_id, schedule_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title, drive_folder_url = excluded.drive_folder_url,
                    recurrence_rule = excluded.recurrence_rule, timezone = excluded.timezone,
                    merged_into_group_id = excluded.merged_into_group_id, schedule_json = excluded.schedule_json
            """, [
                .text(id), .text(text("title") ?? held.title), .text(drive), .text(rule), .text(zone),
                value("mergedInto", held.merged), .text(planText),
            ])

        case "playlist" where existing.map({ if case .playlist = $0 { return true } else { return false } }) == true:
            guard case .playlist(let title, let url)? = existing else { break }
            try connection.execute(
                "UPDATE video_playlists SET title = ?, playlist_url = ? WHERE id = ?",
                [.text(text("title") ?? title), .text(text("externalKey") ?? url), .text(id)]
            )

        default:
            // A show, a channel, a playlist this Mac does not follow, or a kind it does not know.
            var held: (key: String, title: String, subtitle: String?, author: String?, feed: SyncJSON?, status: String, addedAt: Double?)
                = (record.wireID, "", nil, nil, nil, "active", nil)
            if case .derived(_, let key, let title, let subtitle, let author, let feed, let status, let addedAt)? = existing {
                held = (key, title, subtitle, author, feed, status, addedAt)
            }
            let feed = fields["feed"].map { $0.isNull ? nil : $0 } ?? held.feed
            let addedAt = fields["addedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? held.addedAt
            try connection.execute("""
                INSERT INTO source_collections (id, kind, external_key, title, subtitle, author, feed_json, status, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, external_key = excluded.external_key, title = excluded.title,
                    subtitle = excluded.subtitle, author = excluded.author, feed_json = excluded.feed_json,
                    status = excluded.status, added_at = excluded.added_at
            """, [
                .text(id), .text(kind), .text(text("externalKey") ?? held.key), .text(text("title") ?? held.title),
                value("subtitle", held.subtitle), value("author", held.author),
                .text(feed.map { String(decoding: $0.serialized(), as: UTF8.self) }),
                .text(text("status") ?? held.status), .real(addedAt),
            ])
        }
        return .projected
    }

    private static func kind(of rows: CollectionRows?) -> String {
        switch rows {
        case .book?: return "book"
        case .meetingSeries?: return "meetingSeries"
        case .playlist?: return "playlist"
        case .derived(let kind, _, _, _, _, _, _, _)?: return kind
        case nil: return ""
        }
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        // Its members keep their `group_members` rows: a book's chapters stay grouped until they go.
        for table in Self.tableOrder {
            try connection.execute("DELETE FROM \(table) WHERE id = ?", [.text(record.localID)])
        }
        try BookCovers.forget(bookID: record.localID, connection: connection)
    }
}

// MARK: - A book's cover (§3.5.5 `files.cover`)

/// A book's cover as `Collection.files.cover`. The Mac that holds a book's `cover.jpg` uploads it as the
/// book's `cover` satellite and points the record at it (`BookCoverPublisher`); a Mac that holds no cover
/// file for the book fetches it (`SatelliteReader`) into `Books/.synced-covers/` and records it as
/// `books.cover_path`, which every cover the Mac draws reads (`StudioViewModel.bookCoverPaths`). Until
/// 2026-10-19 neither half was built under generation 2: the record carried a book's title and author
/// only, so a book added on one Mac showed no cover on the other, though the iPhone reads `files.cover`.
enum BookCovers {
    static let queueKind = "bookCover"
    static let role = "cover"
    static let mime = "image/jpeg"
    static let syncedFolder = "Books/.synced-covers"

    static func cover(in fields: [String: SyncJSON]) -> FileRef? {
        fields["files"]?[role].flatMap(FileRef.init(json:))
    }

    /// Works out whether an applied book record leaves this Mac a cover to fetch, and remembers it as a
    /// wish (`{cover: FileRef}`). Runs inside the apply: one read and one queue write.
    static func take(bookID: String, fields: [String: SyncJSON], connection: SQLiteConnection) throws {
        let held = try connection.scalarText("SELECT cover_path FROM books WHERE id = ?", [.text(bookID)])
        guard let file = cover(in: fields), file.heldBy == nil, needs(file, heldPath: held) else {
            return try forget(bookID: bookID, connection: connection)
        }
        // A payload that changed starts the attempts over; the same one keeps what its failures spent.
        try connection.queueBackfillKeepingAttempts(
            kind: queueKind, target: bookID, payload: String(decoding: SyncJSON.object([role: file.value]).serialized(), as: UTF8.self)
        )
    }

    /// True unless `heldPath` is a cover this Mac can read: its own file, or the fetched copy of this very
    /// cover. A fetched copy of an earlier cover is replaced; a cover file of the Mac's own never is.
    static func needs(_ file: FileRef, heldPath: String?) -> Bool {
        guard let heldPath, !heldPath.isEmpty, CloudKitRecordMapper.readableBookCoverPath(heldPath) != nil else { return true }
        let relative = StorageService.relativeSourcePath(heldPath)
        return relative.hasPrefix(syncedFolder + "/") && relative != installedPath(hash: file.hash)
    }

    static func forget(bookID: String, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(bookID)])
    }

    /// Where a fetched cover lands, relative to the content roots: named by its hash, so it is never stale.
    static func installedPath(hash: String) -> String {
        "\(syncedFolder)/\(hash.prefix(24)).jpg"
    }

    /// Writes a fetched cover under the content root (off the store) and returns its relative path. A file
    /// already there with the same bytes is kept.
    static func install(_ body: Data, hash: String) throws -> String {
        let root = KnowledgeStore.installedSourceFileRootOverride ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true)
        let relative = installedPath(hash: hash)
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: url)).map(SyncIdentity.sha256Hex) != hash { try body.write(to: url, options: .atomic) }
        return relative
    }

    /// Records a fetched cover as the book's and forgets the wish. False when the wish now names other bytes.
    static func received(installedPath: String, hash: String, bookID: String, connection: SQLiteConnection) throws -> Bool {
        let wanted = try connection.scalarText(
            "SELECT payload_json FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(bookID)]
        ).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?[role].flatMap(FileRef.init(json:))
        guard wanted?.hash == hash else { return false }
        try connection.execute("UPDATE books SET cover_path = ? WHERE id = ?", [.text(installedPath), .text(bookID)])
        try forget(bookID: bookID, connection: connection)
        return true
    }

    /// The learner's books whose `cover_path` is set here and whose record in `Catalog` names no cover yet.
    /// A book whose record is not in the replica yet waits for it (the pointer goes onto a held version).
    static func unpublished(connection: SQLiteConnection) throws -> [(bookID: String, coverPath: String)] {
        var rows: [(bookID: String, coverPath: String)] = []
        try connection.query("SELECT id, cover_path FROM books WHERE COALESCE(cover_path, '') != '' ORDER BY id", []) { row in
            if let id = row.text(0), let path = row.text(1) { rows.append((id, path)) }
        }
        let replica = ReplicaStore(connection: connection)
        let catalog = PrivateSyncZones.key(PrivateSyncZones.catalog)
        return try rows.filter { book in
            guard let record = try replica.record(zoneKey: catalog, recordType: SyncRecordType.collection.rawValue, wireID: book.bookID),
                  let envelope = try? SyncEnvelope(storedPayload: record.payload) else { return false }
            return envelope.fields["kind"]?.stringValue == "book" && cover(in: envelope.fields) == nil
        }
    }
}

/// Uploads the covers of the books this Mac holds a cover file for whose record names none, then points each
/// record at its cover: bytes before pointer (§3.5.30 rule 2), the pointers as compare-and-set saves beside
/// the engine on the version the replica holds (`MaintenanceWriter`), as a notebook's cover moves. A record
/// that gained a cover meanwhile (another Mac's) keeps it. Runs after a round, under the same hold as
/// `SourceFilePublisher`; a book whose cover cannot be read or uploaded is tried three times a launch.
struct BookCoverPublisher {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "BookCovers")
    private static let failures = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    let store: MacPrivateSyncStore
    let blobs: BlobStore
    let writer: MaintenanceWriter

    /// Returns the books whose record now points at their cover.
    @discardableResult
    func run() async -> Int {
        do {
            let zones = try await store.perform { state -> (catalog: BlobZone, content: BlobZone)? in
                guard let catalog = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.catalog), in: state),
                      let content = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: state) else { return nil }
                return (catalog, content)
            }
            guard let zones else { return 0 }
            let failed = Self.failures.withLock { $0 }
            let books = try await store.perform { try BookCovers.unpublished(connection: $0.connection) }
                .filter { (failed[$0.bookID] ?? 0) < 3 }
            guard !books.isEmpty else { return 0 }

            var writes: [MaintenanceWriter.Write] = []
            for book in books {
                guard let path = CloudKitRecordMapper.readableBookCoverPath(book.coverPath),
                      let bytes = CloudKitRecordMapper.bookCoverJPEG(absolutePath: path) else {
                    Self.fail(book.bookID)
                    continue
                }
                do {
                    let file = try await blobs.upload(
                        bytes, owner: book.bookID, ownerType: .collection, role: BookCovers.role, mime: BookCovers.mime,
                        encoding: .identity, into: zones.content
                    )
                    var patch = RecordPatch(.collection, id: book.bookID)
                    patch.changes["files"] = .elements([BookCovers.role: file.value])
                    writes.append(MaintenanceWriter.Write(zone: zones.catalog, patch: patch, onlyIfHeld: true))
                } catch {
                    if SourceFilePublisher.isTransient(error) { throw error }
                    Self.logger.error("A book cover did not upload: \(String(describing: error), privacy: .public)")
                    Self.fail(book.bookID)
                }
            }
            // Read again before the pointers move: a cover another Mac set meanwhile stays.
            let still = Set(try await store.perform { try BookCovers.unpublished(connection: $0.connection) }.map(\.bookID))
            writes = writes.filter { still.contains($0.patch.id) }
            guard !writes.isEmpty else { return 0 }
            let outcomes = try await writer.save(writes)
            return outcomes.filter { $0 == .saved }.count
        } catch {
            Self.logger.notice("Publishing book covers stopped for now: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private static func fail(_ bookID: String) {
        failures.withLock { $0[bookID, default: 0] += 1 }
    }
}

// MARK: - A playlist's members (§3.5.5, §3.5.8)

/// A playlist's members as `Entry` records (`containerKind = playlist`) in `Catalog`, one per
/// `group_members` row whose group is a playlist (`playlist_` + its address, the id
/// `videoPlaylistID(for:)` and the MCP's `youtubePlaylistGroupID` mint). A book's or meeting series'
/// membership is its Source's `collectionID`; a course's is its lesson item.
///
/// The registry holds one projection per record type: `EntryProjection` is the Entry projection
/// and reads a playlist's Entries through this one.
struct PlaylistEntryProjection: RecordProjection {
    struct Rows: Equatable, Sendable {
        let playlistID: String
        let sourceID: String
        let sortIndex: Int64?
        let addedAt: Double?
    }

    static let playlistPrefix = "playlist_"

    var recordType: SyncRecordType { .entry }

    static func entryID(playlistID: String, sourceID: String) -> String {
        SyncIdentity.entryID(containerID: playlistID, itemKind: "source", itemID: sourceID)
    }

    /// The playlist and source an Entry id names, when its container is a playlist.
    static func parts(_ wireID: String) -> (playlistID: String, sourceID: String)? {
        guard wireID.hasPrefix("en:" + playlistPrefix), let marker = wireID.range(of: ":source:", options: .backwards) else { return nil }
        let container = String(wireID[wireID.index(wireID.startIndex, offsetBy: 3)..<marker.lowerBound])
        let item = String(wireID[marker.upperBound...])
        guard !container.isEmpty, !item.isEmpty, !item.contains("#") else { return nil }
        return (container, item)
    }

    var tables: [ProjectedTable] {
        let entrySQL: @Sendable (String) -> String = { "'en:' || \($0).group_id || ':source:' || \($0).source_id" }
        return [ProjectedTable(
            "group_members", localKey: ["source_id", "group_id"], keyColumns: ["source_id", "group_id"], syncedColumns: ["sort_index"],
            parents: [LocalParent("source_id", references: "sources", type: .source, role: .item)],
            recordTypes: [.entry],
            record: { values in
                guard let group = values["group_id"]?.textValue, group.hasPrefix(Self.playlistPrefix),
                      let source = values["source_id"]?.textValue else { return nil }
                let id = Self.entryID(playlistID: group, sourceID: source)
                return RowRecord(type: .entry, localID: id, personalID: id)
            },
            localIDSQL: entrySQL, personalIDSQL: entrySQL
        )]
    }

    var feeds: [String: FieldFeed] {
        let existence: FieldFeed = .rowExistence(table: "group_members")
        return [
            "state": existence, "containerKind": existence, "containerID": existence, "itemKind": existence,
            "itemID": existence, "origin": existence, "addedAt": existence,
            "orderKey": .columns(table: "group_members", ["sort_index"]),
        ]
    }

    /// A member removed from the playlist while its source stays is `state = removed`; a source that
    /// went leaves the Entry as it is on the server, hidden until the source comes back (§3.5.8).
    var missingRow: MissingRowOutcome { .fields(["state": .string("removed")]) }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows? {
        guard let parts = Self.parts(record.wireID) else { return nil }
        var rows: Rows?
        try connection.query("""
            SELECT gm.sort_index, s.date_added FROM group_members gm LEFT JOIN sources s ON s.id = gm.source_id
            WHERE gm.source_id = ? AND gm.group_id = ?
        """, [.text(parts.sourceID), .text(parts.playlistID)]) { row in
            rows = Rows(playlistID: parts.playlistID, sourceID: parts.sourceID, sortIndex: row.integer(0), addedAt: row.real(1))
        }
        return rows
    }

    static func encodeRows(_ rows: Rows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "containerKind": .string("playlist"), "containerID": .string(rows.playlistID),
            "itemKind": .string("source"), "itemID": .string(rows.sourceID), "state": .string("active"),
            "origin": .string("import"),
        ]
        // A member with no position sorts first, by id, as the playlist lists it today.
        if let key = SourceOrderKeys.key(forIndex: rows.sortIndex ?? 0) { fields["orderKey"] = .string(key) }
        if let addedAt = rows.addedAt { fields["addedAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: addedAt)) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // Another container's Entry, or a playlist in a space, waits for the package that projects it.
        guard !record.zone.isSpace, envelope.fields["containerKind"]?.stringValue == "playlist",
              let parts = Self.parts(record.wireID)
        else { return .projected }
        guard envelope.fields["state"]?.stringValue != "removed" else {
            try connection.execute(
                "DELETE FROM group_members WHERE source_id = ? AND group_id = ?", [.text(parts.sourceID), .text(parts.playlistID)]
            )
            return .projected
        }
        guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(parts.sourceID)]) == 1 else {
            return .waiting([WaitingParent(type: .source, wireID: parts.sourceID)])
        }
        let sortIndex = envelope.fields["orderKey"]?.stringValue.flatMap(SourceOrderKeys.index(ofKey:))
        try connection.execute("""
            INSERT INTO group_members (source_id, group_id, sort_index) VALUES (?, ?, ?)
            ON CONFLICT(source_id, group_id) DO UPDATE SET sort_index = COALESCE(excluded.sort_index, group_members.sort_index)
        """, [.text(parts.sourceID), .text(parts.playlistID), .integer(sortIndex)])
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace, let parts = Self.parts(record.wireID) else { return }
        try connection.execute(
            "DELETE FROM group_members WHERE source_id = ? AND group_id = ?", [.text(parts.sourceID), .text(parts.playlistID)]
        )
    }
}
