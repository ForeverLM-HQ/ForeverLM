import Foundation

// MARK: - The member's Marks (docs/cloudkit-schema-design.md §3.5.19)

/// A Mark's id, `mk:<kind>:<target>`, and what its target names: an ItemRef (`src:<id>`,
/// `src:<id>#<key>`, `col:<id>`, `art:<id>`, `cht:<id>`, `exc:<id>`, `nb:<id>`) or a work key
/// (`wk:url:<normalized>`).
struct MarkKey: Hashable, Sendable {
    let kind: String
    let target: String

    init(kind: String, target: String) {
        self.kind = kind
        self.target = target
    }

    init?(id: String) {
        guard id.hasPrefix("mk:") else { return nil }
        let rest = id.dropFirst(3)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        kind = String(rest[..<colon])
        target = String(rest[rest.index(after: colon)...])
        guard !kind.isEmpty, !target.isEmpty else { return nil }
    }

    var id: String { SyncIdentity.markID(kind: kind, target: target) }

    /// The target's ItemRef kind (`src`, `col`, …, or `wk`).
    var targetKind: String { target.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "" }

    /// The target's id, without its kind and without a `#<key>`.
    var targetID: String {
        let id = target.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return id.split(separator: "#", maxSplits: 1).first.map(String.init) ?? id
    }

    /// The `#<key>` part of the target: an idea's or a cited candidate's key.
    var subKey: String? {
        guard let hash = target.firstIndex(of: "#") else { return nil }
        let key = String(target[target.index(after: hash)...])
        return key.isEmpty ? nil : key
    }

    static func source(_ kind: String, _ sourceID: String, sub: String? = nil) -> MarkKey {
        MarkKey(kind: kind, target: "src:" + sourceID + (sub.map { "#" + $0 } ?? ""))
    }
}

/// One Mark as the local tables hold it (§3.5.19): whether it is on, its kind's value, and when it
/// last flipped (Cocoa seconds).
struct MarkRows: Equatable, Sendable {
    var key: MarkKey
    var on: Bool
    var value: SyncJSON?
    var at: Double?
}

/// The Mark record's projection (§3.5.19): one record per (kind, target), never deleted (`on` flips),
/// private to the member and never touched when the content it names goes (D18). Marks project from
/// the tables generation 1 already keeps (§12.7 v160): a hide, a dismissal, a visible override and an
/// import block are rows (`on` while one exists); a wanted idea, a cited-paper decision, a rating, a
/// YouTube like, a followed playlist and a source's discovery origin are columns of the rows they are
/// about (`on` while the column says so).
///
/// A Mark about a show or a channel names its Collection (`col:` + the id `SourceProjection` derives
/// from the name) and carries the name in `value.name`, since the id cannot be read back into one; a
/// dismissal names the URL's work key (`wk:url:<normalized>`) and carries `{url, title}`, the one form
/// the iPhone and the web write too, so whichever client turns it off, the one Mark flips. A like or a
/// discovery origin on a team copy makes no Mark: the personal copy's row holds the member's.
struct MarkProjection: RecordProjection {
    var recordType: SyncRecordType { .mark }

    // MARK: Tables

    /// The tables whose rows are hides of a source, by its wire id.
    static let hiddenSourceTables = ["hidden_sources", "hidden_podcast_episodes", "pending_hidden_sources"]
    static let visibleOverrideTables = ["visible_podcast_episode_overrides", "visible_youtube_video_overrides"]
    /// A source's discovery origin, in the per-type table of its kind.
    static let provenanceTables = SourceLocalTables.subtypeTables

    /// What a row of each table feeds, for the field times.
    private static let existenceTables: [(table: String, time: String)] = [
        ("hidden_sources", "hidden_at"), ("hidden_podcast_episodes", "hidden_at"), ("pending_hidden_sources", "hidden_at"),
        ("hidden_podcast_shows", "hidden_at"), ("hidden_youtube_channels", "hidden_at"), ("hidden_artifacts", "hidden_at"),
        ("hidden_review_sessions", "hidden_at"), ("dismissed_sources", "dismissed_at"),
        ("visible_podcast_episode_overrides", "visible_at"), ("visible_youtube_video_overrides", "visible_at"),
        ("blocked_podcast_shows", "blocked_at"),
    ]

    var tables: [ProjectedTable] {
        var tables: [ProjectedTable] = []
        for table in Self.hiddenSourceTables {
            tables.append(Self.sourceKeyed(table, kind: "hidden", columns: ["hidden_at"]))
        }
        for table in Self.visibleOverrideTables {
            tables.append(Self.sourceKeyed(table, kind: "visibleOverride", columns: ["visible_at"]))
        }
        tables.append(Self.named("hidden_podcast_shows", key: "show_name", columns: ["hidden_at"]) { .hiddenShow($0) })
        tables.append(Self.named("hidden_youtube_channels", key: "channel_name", columns: ["hidden_at"]) { .hiddenChannel($0) })
        tables.append(Self.named("blocked_podcast_shows", key: "show_name", columns: ["blocked_at"]) { .blockedShow($0) })
        tables.append(Self.named("dismissed_sources", key: "url", columns: ["title", "dismissed_at"]) { .dismissed(url: $0) })
        tables.append(Self.idKeyed("hidden_artifacts", key: "artifact_id", kind: "hidden", ref: "art", columns: ["hidden_at"]))
        tables.append(Self.idKeyed("hidden_review_sessions", key: "session_id", kind: "hidden", ref: "cht", columns: ["hidden_at"]))
        // A rating is about its exchange: a chat deleted here takes the exchange's row, never the Mark.
        tables.append(Self.idKeyed(
            "review_exchanges", key: "id", kind: "rated", ref: "exc", columns: ["rating", "rating_reason", "rating_field", "rated_at"],
            parents: [LocalParent("id", references: "review_exchanges", "id", type: .exchange, role: .item)]
        ))
        tables.append(Self.idKeyed("video_playlists", key: "id", kind: "following", ref: "col", columns: ["auto_import"]))
        tables.append(Self.subKeyed("source_ideas", kind: "wantIdea", columns: ["wanted"]))
        tables.append(Self.subKeyed("video_cited_papers", kind: "citedDecision", columns: ["status", "imported_source_id"]))
        // A like and a discovery origin are about their source: a source deleted here takes the row,
        // never the Mark, and its re-import brings the Mark back (§5.7).
        tables.append(Self.sourceKeyed("videos", kind: "liked", columns: ["liked_at"], aboutTheSource: true))
        for table in Self.provenanceTables {
            tables.append(Self.sourceKeyed(table, kind: "provenance", columns: ["discovery_origin"], aboutTheSource: true))
        }
        return tables
    }

    /// A table keyed by a source id, one Mark of `kind` per row.
    private static func sourceKeyed(_ table: String, kind: String, columns: [String], aboutTheSource: Bool = false) -> ProjectedTable {
        let idSQL: @Sendable (String) -> String = { "'mk:\(kind):src:' || \($0).source_id" }
        return ProjectedTable(
            table, localKey: ["source_id"], keyColumns: ["source_id"], syncedColumns: columns,
            parents: aboutTheSource ? [LocalParent("source_id", references: table, "source_id", type: .source, role: .item)] : [],
            recordTypes: [.mark],
            record: { values in
                values["source_id"]?.textValue.map {
                    let id = MarkKey.source(kind, $0).id
                    return RowRecord(type: .mark, localID: id, personalID: id)
                }
            },
            localIDSQL: idSQL, personalIDSQL: idSQL
        )
    }

    /// A table keyed by the id of what the Mark names.
    private static func idKeyed(_ table: String, key: String, kind: String, ref: String, columns: [String], parents: [LocalParent] = []) -> ProjectedTable {
        let idSQL: @Sendable (String) -> String = { "'mk:\(kind):\(ref):' || \($0).\(key)" }
        return ProjectedTable(
            table, localKey: [key], keyColumns: [key], syncedColumns: columns, parents: parents, recordTypes: [.mark],
            record: { values in
                values[key]?.textValue.map {
                    let id = MarkKey(kind: kind, target: "\(ref):\($0)").id
                    return RowRecord(type: .mark, localID: id, personalID: id)
                }
            },
            localIDSQL: idSQL, personalIDSQL: idSQL
        )
    }

    /// A table of a source's candidates (ideas, cited papers): `src:<source id>#<row id>`.
    private static func subKeyed(_ table: String, kind: String, columns: [String]) -> ProjectedTable {
        let idSQL: @Sendable (String) -> String = { "'mk:\(kind):src:' || \($0).source_id || '#' || \($0).id" }
        return ProjectedTable(
            table, localKey: ["id"], keyColumns: ["id", "source_id"], syncedColumns: columns, recordTypes: [.mark],
            record: { values in
                guard let id = values["id"]?.textValue, let source = values["source_id"]?.textValue else { return nil }
                let mark = MarkKey.source(kind, source, sub: id).id
                return RowRecord(type: .mark, localID: mark, personalID: mark)
            },
            localIDSQL: idSQL, personalIDSQL: idSQL
        )
    }

    /// A table keyed by a name or a URL whose Mark names a derived id the row cannot be found by. The
    /// record's local id carries the table and the key, so the encoder reads the row it came from.
    private static func named(_ table: String, key: String, columns: [String], mark: @escaping @Sendable (String) -> MarkKey) -> ProjectedTable {
        ProjectedTable(
            table, localKey: [key], keyColumns: [key], syncedColumns: columns, recordTypes: [.mark],
            record: { values in
                values[key]?.textValue.map { name in
                    RowRecord(type: .mark, localID: NamedRow(table: table, key: name).localID, personalID: mark(name).id)
                }
            },
            // No parent, so no trigger names the record by SQL.
            localIDSQL: { _ in "NULL" }, personalIDSQL: { _ in "NULL" }
        )
    }

    /// A named row's record local id: its table and key, joined by U+001F.
    struct NamedRow: Equatable {
        let table: String
        let key: String
        var localID: String { table + "\u{1F}" + key }

        init(table: String, key: String) {
            self.table = table
            self.key = key
        }

        init?(localID: String) {
            let parts = localID.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            table = String(parts[0])
            key = String(parts[1])
        }
    }

    // MARK: Fields and times

    var feeds: [String: FieldFeed] {
        let existence = Self.existenceTables.map { FieldFeed.rowExistence(table: $0.table) }
        let flags: [FieldFeed] = [
            .columns(table: "review_exchanges", ["rating"]), .columns(table: "video_playlists", ["auto_import"]),
            .columns(table: "source_ideas", ["wanted"]), .columns(table: "video_cited_papers", ["status"]),
            .columns(table: "videos", ["liked_at"]),
        ] + Self.provenanceTables.map { .columns(table: $0, ["discovery_origin"]) }
        let values: [FieldFeed] = [
            .columns(table: "dismissed_sources", ["url", "title"]), .rowExistence(table: "hidden_podcast_shows"),
            .rowExistence(table: "hidden_youtube_channels"), .rowExistence(table: "blocked_podcast_shows"),
            .columns(table: "review_exchanges", ["rating", "rating_reason", "rating_field"]),
            .columns(table: "video_playlists", ["auto_import"]), .columns(table: "video_cited_papers", ["status", "imported_source_id"]),
            .columns(table: "videos", ["liked_at"]),
        ] + Self.provenanceTables.map { .columns(table: $0, ["discovery_origin"]) }
        let times: [FieldFeed] = Self.existenceTables.map { FieldFeed.columns(table: $0.table, [$0.time]) } + [
            .columns(table: "review_exchanges", ["rated_at"]), .columns(table: "videos", ["liked_at"]),
            .columns(table: "source_ideas", ["wanted"]), .columns(table: "video_cited_papers", ["status"]),
        ] + Self.provenanceTables.map { .columns(table: $0, ["discovery_origin"]) }
        let identity = FieldFeed.anyOf(existence + flags)
        return ["kind": identity, "target": identity, "on": .anyOf(existence + flags), "value": .anyOf(values), "at": .anyOf(times)]
    }

    /// A Mark whose rows are gone is off, never deleted (§3.5.19).
    var missingRow: MissingRowOutcome { .fields(["on": .bool(false)]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }

    // MARK: Reading the rows

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> MarkRows? {
        guard let key = MarkKey(id: record.wireID) else { return nil }
        return try Self.load(key, localID: record.localID, connection: connection)
    }

    static func load(_ key: MarkKey, localID: String? = nil, connection: SQLiteConnection) throws -> MarkRows? {
        let named = localID.flatMap(NamedRow.init(localID:))
        switch (key.kind, key.targetKind) {
        case ("hidden", "src"):
            return try latest(key, connection: connection, hiddenSourceTables.map { ($0, "source_id", "hidden_at") }, id: key.targetID)
        case ("visibleOverride", "src"):
            return try latest(key, connection: connection, visibleOverrideTables.map { ($0, "source_id", "visible_at") }, id: key.targetID)
        case ("hidden", "art"):
            return try latest(key, connection: connection, [("hidden_artifacts", "artifact_id", "hidden_at")], id: key.targetID)
        case ("hidden", "cht"):
            return try latest(key, connection: connection, [("hidden_review_sessions", "session_id", "hidden_at")], id: key.targetID)
        case ("hidden", "col"):
            for (table, column, mark) in [("hidden_podcast_shows", "show_name", MarkKey.hiddenShow), ("hidden_youtube_channels", "channel_name", MarkKey.hiddenChannel)] {
                if let rows = try namedRow(key, table: table, column: column, time: "hidden_at", named: named, mark: mark, connection: connection) {
                    return rows
                }
            }
            return nil
        case ("importBlocked", "col"):
            return try namedRow(key, table: "blocked_podcast_shows", column: "show_name", time: "blocked_at", named: named, mark: MarkKey.blockedShow, connection: connection)
        case ("dismissed", "wk"):
            return try dismissed(key, named: named, connection: connection)
        case ("rated", "exc"):
            var rows: MarkRows?
            try connection.query("SELECT rating, rating_reason, rating_field, rated_at FROM review_exchanges WHERE id = ?", [.text(key.targetID)]) { row in
                guard let rating = row.text(0) else { return }
                var value: [String: SyncJSON] = ["rating": .string(rating), "field": .string(row.text(2) ?? "evaluation")]
                if let reason = row.text(1) { value["reason"] = .string(reason) }
                rows = MarkRows(key: key, on: true, value: .object(value), at: row.real(3))
            }
            return rows
        case ("following", "col"):
            var rows: MarkRows?
            try connection.query("SELECT auto_import FROM video_playlists WHERE id = ?", [.text(key.targetID)]) { row in
                guard (row.integer(0) ?? 0) != 0 else { return }
                rows = MarkRows(key: key, on: true, value: .object(["autoImport": .bool(true)]), at: nil)
            }
            return rows
        case ("wantIdea", "src"):
            guard let idea = key.subKey else { return nil }
            var rows: MarkRows?
            try connection.query("SELECT wanted, updated_at FROM source_ideas WHERE id = ? AND source_id = ?", [.text(idea), .text(key.targetID)]) { row in
                guard (row.integer(0) ?? 0) != 0 else { return }
                rows = MarkRows(key: key, on: true, value: nil, at: row.real(1))
            }
            return rows
        case ("citedDecision", "src"):
            guard let candidate = key.subKey else { return nil }
            var rows: MarkRows?
            try connection.query(
                "SELECT status, imported_source_id, updated_at FROM video_cited_papers WHERE id = ? AND source_id = ?",
                [.text(candidate), .text(key.targetID)]
            ) { row in
                guard let status = row.text(0), let decided = CitedDecision(localStatus: status) else { return }
                var value: [String: SyncJSON] = ["status": .string(decided.rawValue)]
                if let imported = row.text(1) { value["importedSourceID"] = .string(imported) }
                rows = MarkRows(key: key, on: true, value: .object(value), at: row.real(2))
            }
            return rows
        case ("liked", "src"):
            var rows: MarkRows?
            try connection.query("""
                SELECT v.liked_at FROM videos v JOIN sources s ON s.id = v.source_id
                WHERE v.source_id = ? AND v.liked_at IS NOT NULL AND s.team_id IS NULL
            """, [.text(key.targetID)]) { row in
                guard let at = row.real(0) else { return }
                rows = MarkRows(key: key, on: true, value: .object(["at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: at))]), at: at)
            }
            return rows
        case ("provenance", "src"):
            var type: String?
            var added: Double?
            try connection.query("SELECT source_type, date_added FROM sources WHERE id = ? AND team_id IS NULL", [.text(key.targetID)]) { row in
                type = row.text(0)
                added = row.real(1)
            }
            guard let type else { return nil }
            let table = SourceLocalTables.subtypeTable(forLocalType: type)
            var rows: MarkRows?
            try connection.query("SELECT discovery_origin FROM \(OutboxFeeder.quoted(table)) WHERE source_id = ?", [.text(key.targetID)]) { row in
                guard let origin = row.text(0), !origin.isEmpty else { return }
                var value: [String: SyncJSON] = ["origin": .string(origin)]
                if let added { value["at"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: added)) }
                rows = MarkRows(key: key, on: true, value: .object(value), at: added)
            }
            return rows
        default:
            // A kind or target this Mac keeps no row for (`hidden nb:`, a newer kind): left as the record holds it.
            return nil
        }
    }

    /// The Mark of whichever of `tables` holds a row for `id`, at the latest of their times.
    private static func latest(_ key: MarkKey, connection: SQLiteConnection, _ tables: [(table: String, column: String, time: String)], id: String) throws -> MarkRows? {
        var at: Double?
        var found = false
        for entry in tables {
            try connection.query("SELECT \(entry.time) FROM \(entry.table) WHERE \(entry.column) = ?", [.text(id)]) { row in
                found = true
                if let time = row.real(0) { at = max(at ?? time, time) }
            }
        }
        return found ? MarkRows(key: key, on: true, value: nil, at: at) : nil
    }

    /// A show's or a channel's row, read by the name the record's local id carries, or else by finding
    /// the name whose derived id is the target (the tables hold tens of rows).
    private static func namedRow(
        _ key: MarkKey, table: String, column: String, time: String, named: NamedRow?, mark: (String) -> MarkKey, connection: SQLiteConnection
    ) throws -> MarkRows? {
        var candidates: [(name: String, at: Double?)] = []
        if let named, named.table == table {
            try connection.query("SELECT \(column), \(time) FROM \(table) WHERE \(column) = ?", [.text(named.key)]) { row in
                if let name = row.text(0) { candidates.append((name, row.real(1))) }
            }
        } else {
            try connection.query("SELECT \(column), \(time) FROM \(table)", []) { row in
                if let name = row.text(0) { candidates.append((name, row.real(1))) }
            }
        }
        guard let hit = candidates.first(where: { mark($0.name) == key }) else { return nil }
        return MarkRows(key: key, on: true, value: .object(["name": .string(hit.name)]), at: hit.at)
    }

    private static func dismissed(_ key: MarkKey, named: NamedRow?, connection: SQLiteConnection) throws -> MarkRows? {
        var rows: [(url: String, title: String?, at: Double?)] = []
        if let named, named.table == "dismissed_sources" {
            try connection.query("SELECT url, title, dismissed_at FROM dismissed_sources WHERE url = ?", [.text(named.key)]) { row in
                if let url = row.text(0) { rows.append((url, row.text(1), row.real(2))) }
            }
        } else {
            try connection.query("SELECT url, title, dismissed_at FROM dismissed_sources", []) { row in
                if let url = row.text(0) { rows.append((url, row.text(1), row.real(2))) }
            }
        }
        guard let hit = rows.first(where: { MarkKey.dismissed(url: $0.url) == key }) else { return nil }
        var value: [String: SyncJSON] = ["url": .string(hit.url)]
        if let title = hit.title { value["title"] = .string(title) }
        return MarkRows(key: key, on: true, value: .object(value), at: hit.at)
    }

    static func encodeRows(_ rows: MarkRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "kind": .string(rows.key.kind),
            "target": .string(rows.key.target),
            "on": .bool(rows.on),
        ]
        if let value = rows.value { fields["value"] = value }
        if let at = rows.at { fields["at"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: at)) }
        return fields
    }

    // MARK: Writing an inbound Mark

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace, let key = MarkKey(id: record.wireID) else { return .projected }
        let fields = envelope.fields
        let on = fields["on"]?.boolValue ?? false
        let value = fields["value"]?.objectValue ?? [:]
        let at = fields["at"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? Date().timeIntervalSinceReferenceDate
        return try Self.write(key, on: on, value: value, at: at, connection: connection)
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        // Marks are never deleted; a server delete (an account purge's echo) reads as off.
        guard let key = MarkKey(id: record.wireID) else { return }
        _ = try Self.write(key, on: false, value: [:], at: Date().timeIntervalSinceReferenceDate, connection: connection)
    }

    /// Writes a Mark into its local rows, under the apply guard.
    static func write(_ key: MarkKey, on: Bool, value: [String: SyncJSON], at: Double, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        let id = key.targetID
        switch (key.kind, key.targetKind) {
        case ("hidden", "src"):
            if on {
                // A hide needs no source (D18): the row waits for it, and a podcast's also lists the episode.
                try upsert("hidden_sources", key: "source_id", id: id, time: "hidden_at", at: at, connection: connection)
                if try sourceType(id, connection: connection) == "podcast" {
                    try upsert("hidden_podcast_episodes", key: "source_id", id: id, time: "hidden_at", at: at, connection: connection)
                }
            } else {
                for table in hiddenSourceTables { try connection.execute("DELETE FROM \(table) WHERE source_id = ?", [.text(id)]) }
            }
        case ("visibleOverride", "src"):
            if on {
                guard let type = try sourceType(id, connection: connection) else {
                    return .waiting([WaitingParent(type: .source, wireID: id)])
                }
                let table = type == "podcast" ? "visible_podcast_episode_overrides" : "visible_youtube_video_overrides"
                try upsert(table, key: "source_id", id: id, time: "visible_at", at: at, connection: connection)
            } else {
                for table in visibleOverrideTables { try connection.execute("DELETE FROM \(table) WHERE source_id = ?", [.text(id)]) }
            }
        case ("hidden", "art"):
            try flip("hidden_artifacts", key: "artifact_id", id: id, time: "hidden_at", on: on, at: at, connection: connection)
        case ("hidden", "cht"):
            try flip("hidden_review_sessions", key: "session_id", id: id, time: "hidden_at", on: on, at: at, connection: connection)
        case ("hidden", "col"):
            guard let name = try collectionName(key, value: value, connection: connection) else { return .projected }
            // A show or a channel, by which kind's id the name gives, else by the collection this Mac holds.
            let kind: String?
            if MarkKey.hiddenShow(name) == key {
                kind = "podcastShow"
            } else if MarkKey.hiddenChannel(name) == key {
                kind = "youtubeChannel"
            } else {
                kind = try connection.scalarText("SELECT kind FROM source_collections WHERE id = ?", [.text(id)])
            }
            switch kind {
            case "podcastShow"?:
                try flip("hidden_podcast_shows", key: "show_name", id: name, time: "hidden_at", on: on, at: at, connection: connection)
            case "youtubeChannel"?:
                try flip("hidden_youtube_channels", key: "channel_name", id: name, time: "hidden_at", on: on, at: at, connection: connection)
            default:
                break
            }
        case ("importBlocked", "col"):
            guard let name = try collectionName(key, value: value, connection: connection) else { return .projected }
            try flip("blocked_podcast_shows", key: "show_name", id: name, time: "blocked_at", on: on, at: at, connection: connection)
        case ("dismissed", "wk"):
            // The address is the Mark's `value.url`, else what its work key names. Another client's off
            // Mark clears every spelling this Mac holds of the address, as the Mac's own un-dismiss does.
            let named = value["url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            guard let url = named ?? Self.dismissedURL(of: key) else { return .projected }
            if on {
                try connection.execute("""
                    INSERT INTO dismissed_sources (url, title, dismissed_at) VALUES (?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET title = excluded.title, dismissed_at = excluded.dismissed_at
                """, [.text(url), .text(value["title"]?.stringValue), .real(at)])
            } else {
                var spellings: Set<String> = [url]
                try connection.query("SELECT url FROM dismissed_sources", []) { row in
                    if let held = row.text(0), MarkKey.dismissed(url: held) == key { spellings.insert(held) }
                }
                for spelling in spellings { try connection.execute("DELETE FROM dismissed_sources WHERE url = ?", [.text(spelling)]) }
            }
        case ("rated", "exc"):
            guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM review_exchanges WHERE id = ?)", [.text(id)]) == 1 else {
                return .waiting([WaitingParent(type: .exchange, wireID: id)])
            }
            try connection.execute(
                "UPDATE review_exchanges SET rating = ?, rating_reason = ?, rating_field = ?, rated_at = ? WHERE id = ?",
                on
                    ? [.text(value["rating"]?.stringValue), .text(value["reason"]?.stringValue), .text(value["field"]?.stringValue), .real(at), .text(id)]
                    : [.null, .null, .null, .null, .text(id)]
            )
        case ("following", "col"):
            guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM video_playlists WHERE id = ?)", [.text(id)]) == 1 else {
                return on ? .waiting([WaitingParent(type: .collection, wireID: id)]) : .projected
            }
            try connection.execute("UPDATE video_playlists SET auto_import = ? WHERE id = ?", [.integer(on ? 1 : 0), .text(id)])
        case ("wantIdea", "src"):
            // The idea's row comes with the source's ideas; a Mark for one this Mac has not extracted stays in the replica.
            guard let idea = key.subKey else { return .projected }
            try connection.execute("UPDATE source_ideas SET wanted = ? WHERE id = ? AND source_id = ?", [.integer(on ? 1 : 0), .text(idea), .text(id)])
        case ("citedDecision", "src"):
            guard let candidate = key.subKey else { return .projected }
            let status = on ? (CitedDecision(rawValue: value["status"]?.stringValue ?? "")?.localStatus ?? "pending") : "pending"
            try connection.execute("""
                UPDATE video_cited_papers SET status = ?, imported_source_id = COALESCE(?, imported_source_id)
                WHERE id = ? AND source_id = ? AND status <> 'unresolved'
            """, [.text(status), .text(on ? value["importedSourceID"]?.stringValue : nil), .text(candidate), .text(id)])
        case ("liked", "src"):
            guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM videos WHERE source_id = ?)", [.text(id)]) == 1 else {
                return on ? .waiting([WaitingParent(type: .source, wireID: id)]) : .projected
            }
            let liked = value["at"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? at
            try connection.execute("UPDATE videos SET liked_at = ? WHERE source_id = ?", [on ? .real(liked) : .null, .text(id)])
        case ("provenance", "src"):
            guard let type = try sourceType(id, connection: connection) else {
                return on ? .waiting([WaitingParent(type: .source, wireID: id)]) : .projected
            }
            let table = SourceLocalTables.subtypeTable(forLocalType: type)
            try connection.execute(
                "UPDATE \(OutboxFeeder.quoted(table)) SET discovery_origin = ? WHERE source_id = ?",
                [on ? .text(value["origin"]?.stringValue) : .null, .text(id)]
            )
        default:
            // `hidden nb:` and kinds this build does not know stay in the replica as they are.
            break
        }
        return .projected
    }

    private static func upsert(_ table: String, key: String, id: String, time: String, at: Double, connection: SQLiteConnection) throws {
        try connection.execute(
            "INSERT INTO \(table) (\(key), \(time)) VALUES (?, ?) ON CONFLICT(\(key)) DO UPDATE SET \(time) = excluded.\(time)",
            [.text(id), .real(at)]
        )
    }

    private static func flip(_ table: String, key: String, id: String, time: String, on: Bool, at: Double, connection: SQLiteConnection) throws {
        if on {
            try upsert(table, key: key, id: id, time: time, at: at, connection: connection)
        } else {
            try connection.execute("DELETE FROM \(table) WHERE \(key) = ?", [.text(id)])
        }
    }

    /// The local source type of a source by its wire id (the personal copy's row, else a team copy's).
    private static func sourceType(_ wireID: String, connection: SQLiteConnection) throws -> String? {
        try connection.scalarText("SELECT source_type FROM sources WHERE id = ?", [.text(wireID)])
            ?? connection.scalarText("SELECT source_type FROM sources WHERE wire_key = ? LIMIT 1", [.text(wireID)])
    }

    /// The address a dismissal's work key names (`wk:url:<normalized>`), for a Mark that carries no value.
    private static func dismissedURL(of key: MarkKey) -> String? {
        let prefix = "wk:url:"
        guard key.target.hasPrefix(prefix), key.target.count > prefix.count else { return nil }
        return String(key.target.dropFirst(prefix.count))
    }

    /// The show's or channel's name a `col:` Mark names: its `value.name`, else the collection this Mac
    /// derived under that id.
    private static func collectionName(_ key: MarkKey, value: [String: SyncJSON], connection: SQLiteConnection) throws -> String? {
        if let name = value["name"]?.stringValue, !name.isEmpty { return name }
        return try connection.scalarText("SELECT external_key FROM source_collections WHERE id = ?", [.text(key.targetID)])
    }
}

extension MarkKey {
    static func hiddenShow(_ name: String) -> MarkKey {
        MarkKey(kind: "hidden", target: "col:" + SyncIdentity.collectionID(kind: "podcastShow", externalKey: name))
    }

    static func hiddenChannel(_ name: String) -> MarkKey {
        MarkKey(kind: "hidden", target: "col:" + SyncIdentity.collectionID(kind: "youtubeChannel", externalKey: name))
    }

    static func blockedShow(_ name: String) -> MarkKey {
        MarkKey(kind: "importBlocked", target: "col:" + SyncIdentity.collectionID(kind: "podcastShow", externalKey: name))
    }

    /// A dismissed URL's Mark: its work key, `wk:url:<normalized>` (the URL as it is when it has none),
    /// the one target every client writes and reads for a dismissal (`WorkKey.dismissalTarget`).
    static func dismissed(url: String) -> MarkKey {
        MarkKey(kind: "dismissed", target: WorkKey.dismissalTarget(url: url))
    }
}

/// A cited candidate's decision as the wire names it (§3.5.19): the Mac keeps `imported` and `dismissed`
/// on the row; `pending` and `unresolved` are no decision. `later` (another client's) reads as pending.
enum CitedDecision: String, Sendable {
    case imported
    case dismissed
    case later

    init?(localStatus: String) {
        switch localStatus {
        case "imported": self = .imported
        case "dismissed": self = .dismissed
        default: return nil
        }
    }

    var localStatus: String {
        switch self {
        case .imported: return "imported"
        case .dismissed: return "dismissed"
        case .later: return "pending"
        }
    }
}
