import Foundation

/// The iPhone's query layer over its replica (docs/cloudkit-schema-design.md D33, §9.7, §14.1): what the
/// screens show, read from the index columns `MobileReplica` extracted when each record was applied.
///
/// Only the `Library` structure is held in memory (`LibraryStructure`: notebooks, with the spaces they
/// sit in, chats and cards, as summaries); everything that grows with the library (sources, a
/// notebook's entries, a chat's exchanges) is paged straight from the index, and a payload is decoded
/// only for the records a page or an open screen shows. Spaces appear beside the learner's own
/// notebooks, each notebook carrying its space's name, as soon as their payload walk has run: nothing
/// here needs a satellite's bytes. Reads run on the replica's queue, never on the main actor.
final class MobileProjection: @unchecked Sendable {
    let replica: MobileReplica

    init(replica: MobileReplica) {
        self.replica = replica
    }

    static let libraryKey = PrivateSyncZones.libraryKey
    static let catalogKey = PrivateSyncZones.key(PrivateSyncZones.catalog)

    // MARK: - Shapes

    /// A space this account owns or joined (§9.1), from its zone row and its root.
    struct Space: Equatable, Sendable, Identifiable {
        let zoneKey: String
        let zoneName: String
        let isOwned: Bool
        /// `team`, `family`, `notebook` or `doc` (`ZoneRoot.kind`); nil until the root arrives.
        let kind: String?
        /// The space's name (`ZoneRoot.name`).
        let name: String?
        let ownerName: String?
        /// This member's permission, `readOnly` or `readWrite`.
        let permission: String?
        /// For a notebook or Doc space, the record it was made for.
        let primaryID: String?

        var id: String { zoneKey }
        var spaceID: String { String(zoneName.dropFirst(SyncSchema.spaceZonePrefix.count)) }
        var isReadOnly: Bool { permission == "readOnly" }
    }

    /// A notebook as Home and the Notebooks screen list it.
    struct Notebook: Equatable, Sendable, Identifiable {
        let notebookID: String
        let zoneKey: String
        let title: String
        let status: String?
        let createdAt: Int64?
        let editedAt: Int64?
        let layout: String?
        let primaryCourseID: String?
        let hasCover: Bool
        /// The space it sits in; nil for the learner's own.
        let space: Space?
        /// This member's own state: the order, the pin, the course mode (NotebookState) and the hide (Mark).
        var sidebarKey: String? = nil
        var pinned = false
        var layoutOverride: String? = nil
        var hidden = false

        var id: String { zoneKey + "\u{1F}" + notebookID }
        var isArchived: Bool { status == "archived" }
        /// The space's name the notebook shows beside its title, when it sits in one that has a name.
        var spaceName: String? { space?.name.flatMap { $0.isEmpty ? nil : $0 } }
    }

    struct ChatSummary: Equatable, Sendable, Identifiable {
        let chatID: String
        let zoneKey: String
        let kind: String?
        let notebookID: String?
        let courseID: String?
        let title: String?
        let status: String?
        let createdAt: Int64?
        let editedAt: Int64?

        var id: String { zoneKey + "\u{1F}" + chatID }
    }

    struct CardSummary: Equatable, Sendable, Identifiable {
        let id: String
        let status: String?
        let deckSourceID: String?
        let origin: String?
        let draftedAt: Int64?
        let keptAt: Int64?
    }

    /// Everything the phone keeps in memory: its notebooks, the spaces they sit in, chats and cards.
    struct LibraryStructure: Equatable, Sendable {
        /// The notebooks to show: redirect stubs (merged, moved) and an original whose space copy has
        /// arrived while it moves are left out.
        var notebooks: [Notebook] = []
        var spaces: [Space] = []
        var chats: [ChatSummary] = []
        var cards: [CardSummary] = []
        /// Every notebook's redirects as held, by where it is, for `resolve`.
        var redirects: [SyncRecordLocation: NotebookRedirects] = [:]

        /// Where a notebook id named from `zone` leads after merges, splits and moves (`resolveNotebook()`, §5.2).
        func resolve(_ notebookID: String, in zone: SyncZoneName = .library) -> Notebook? {
            let location = NotebookResolution.resolve(SyncRecordLocation(zone: zone, id: notebookID)) { redirects[$0] }
            return notebooks.first { $0.notebookID == location.id && Self.zoneName(of: $0) == location.zone }
        }

        /// The chats filed in a notebook, newest first, whichever zone they sit in (a private review of
        /// a space notebook stays in `Library`, D19).
        func chats(in notebook: Notebook) -> [ChatSummary] {
            chats.filter { chat in
                guard let filed = chat.notebookID else { return false }
                let zone = ProjectionZones.zone(ofKey: chat.zoneKey) ?? .library
                // A `Library` chat may name a space notebook by its id (§3.5.13).
                let home = resolve(filed, in: zone) ?? (zone == .library ? notebooks.first { $0.notebookID == filed && $0.space != nil } : nil)
                return home?.id == notebook.id
            }
            .sorted { ($0.editedAt ?? 0) > ($1.editedAt ?? 0) }
        }

        static func zoneName(of notebook: Notebook) -> SyncZoneName {
            ProjectionZones.zone(ofKey: notebook.zoneKey) ?? .library
        }
    }

    struct Page: Equatable, Sendable {
        var offset: Int
        var limit: Int

        static func first(_ limit: Int = 50) -> Page { Page(offset: 0, limit: limit) }
        var next: Page { Page(offset: offset + limit, limit: limit) }
    }

    struct SourceRow: Equatable, Sendable, Identifiable {
        let id: String
        let zoneKey: String
        let type: String?
        let title: String?
        let authors: String?
        let venue: String?
        let url: String?
        let collectionID: String?
        let status: String?
        let ingestState: String?
        let addedAt: Int64?
        let publishedAt: Int64?
        let hasPDF: Bool
    }

    enum SourceOrder: Sendable {
        /// Date added, newest first (the Mac's default).
        case newest
        /// Title, folded for case and diacritics.
        case title
    }

    /// One item of a notebook (an `Entry`), with its source when it is one.
    struct EntryRow: Equatable, Sendable, Identifiable {
        let id: String
        let zoneKey: String
        let containerID: String
        let itemKind: String?
        let itemID: String?
        let state: String?
        /// Absent means approved (§3.5.8).
        let approval: String?
        let orderKey: String?
        let origin: String?
        let role: String?
        let addedAt: Int64?
        /// The stamps the chat ticks compare (D16, §5.6).
        let stateStamp: String?
        let approvalStamp: String?
        let source: SourceRow?

        var isApproved: Bool { approval == nil || approval == "approved" }
    }

    struct ArtifactRow: Equatable, Sendable, Identifiable {
        let id: String
        let zoneKey: String
        let kind: String?
        let title: String?
        let notebookID: String?
        let status: String?
        let preview: String?
        let editedAt: Int64?
    }

    struct CourseRow: Equatable, Sendable, Identifiable {
        let id: String
        let zoneKey: String
        let title: String?
        let status: String?
    }

    struct LessonRow: Equatable, Sendable, Identifiable {
        let id: String
        let courseID: String?
        let orderKey: String?
        let kind: String?
        let title: String?
    }

    /// Where the library's move to the new container stands (`ZoneRoot.seed`, §13.6).
    struct LibrarySeed: Equatable, Sendable {
        let state: String?
        let metadataCompleteAt: Int64?
    }

    // MARK: - The structure

    /// Reads the structure from the index alone: no record is decoded but each space's root.
    func loadStructure() async throws -> LibraryStructure {
        try await replica.read { replica in try Self.structure(in: replica) }
    }

    static func structure(in replica: MobileReplica) throws -> LibraryStructure {
        let connection = replica.connection
        var structure = LibraryStructure()
        structure.spaces = try spaces(in: replica)
        let spacesByKey = Dictionary(uniqueKeysWithValues: structure.spaces.map { ($0.zoneKey, $0) })
        let keys = [libraryKey] + structure.spaces.map(\.zoneKey)
        let held = MobileReadModels.placeholders(keys.count)

        var all: [(notebook: Notebook, mergedInto: String?, movedTo: String?, movingTo: String?)] = []
        try connection.query("""
            SELECT zone_key, id, title, status, created_at, edited_at, layout, primary_course_id, has_cover, merged_into, moved_to, moving_to
            FROM m_notebooks WHERE zone_key IN (\(held))
        """, keys.map { .text($0) }) { row in
            let zoneKey = row.text(0) ?? ""
            all.append((Notebook(
                notebookID: row.text(1) ?? "", zoneKey: zoneKey, title: row.text(2) ?? "", status: row.text(3),
                createdAt: row.integer(4), editedAt: row.integer(5), layout: row.text(6), primaryCourseID: row.text(7),
                hasCover: row.integer(8) == 1, space: spacesByKey[zoneKey]
            ), row.text(9), row.text(10), row.text(11)))
        }
        for item in all {
            let zone = LibraryStructure.zoneName(of: item.notebook)
            structure.redirects[SyncRecordLocation(zone: zone, id: item.notebook.notebookID)] =
                NotebookRedirects(mergedInto: item.mergedInto, movedTo: item.movedTo, movingTo: item.movingTo)
        }

        var states: [String: (sidebarKey: String?, pinned: Bool, layoutOverride: String?)] = [:]
        try connection.query("SELECT notebook_id, sidebar_key, pinned, layout_override FROM m_notebook_states WHERE zone_key = ?", [.text(libraryKey)]) {
            states[$0.text(0) ?? ""] = ($0.text(1), $0.integer(2) == 1, $0.text(3))
        }
        var hidden = Set<String>()
        try connection.query("SELECT target FROM m_marks WHERE zone_key = ? AND kind = 'hidden' AND on_flag = 1 AND substr(target, 1, 3) = 'nb:'",
                             [.text(libraryKey)]) { hidden.insert(String(($0.text(0) ?? "").dropFirst(3))) }

        for item in all {
            var notebook = item.notebook
            if ["merged", "moved"].contains(notebook.status ?? "") { continue }
            if (item.mergedInto ?? "").isEmpty == false || (item.movedTo ?? "").isEmpty == false { continue }
            // An original still moving into a space hides once its copy has arrived there (§5.3).
            if let spaceID = item.movingTo, !spaceID.isEmpty,
               structure.redirects[SyncRecordLocation(zone: .space(spaceID), id: notebook.notebookID)] != nil {
                continue
            }
            if let state = states[notebook.notebookID] {
                notebook.sidebarKey = state.sidebarKey
                notebook.pinned = state.pinned
                notebook.layoutOverride = state.layoutOverride
            }
            notebook.hidden = hidden.contains(notebook.notebookID)
            structure.notebooks.append(notebook)
        }
        structure.notebooks.sort { lhs, rhs in
            if (lhs.editedAt ?? 0) != (rhs.editedAt ?? 0) { return (lhs.editedAt ?? 0) > (rhs.editedAt ?? 0) }
            return lhs.id < rhs.id
        }

        try connection.query("""
            SELECT zone_key, id, kind, notebook_id, course_id, title, status, created_at, edited_at
            FROM m_chats WHERE zone_key IN (\(held)) ORDER BY edited_at DESC, id
        """, keys.map { .text($0) }) { row in
            structure.chats.append(ChatSummary(
                chatID: row.text(1) ?? "", zoneKey: row.text(0) ?? "", kind: row.text(2), notebookID: row.text(3),
                courseID: row.text(4), title: row.text(5), status: row.text(6), createdAt: row.integer(7), editedAt: row.integer(8)
            ))
        }
        try connection.query("SELECT id, status, deck_source_id, origin, drafted_at, kept_at FROM m_cards WHERE zone_key = ? ORDER BY id",
                             [.text(libraryKey)]) { row in
            structure.cards.append(CardSummary(
                id: row.text(0) ?? "", status: row.text(1), deckSourceID: row.text(2), origin: row.text(3),
                draftedAt: row.integer(4), keptAt: row.integer(5)
            ))
        }
        return structure
    }

    /// The spaces this device holds and has not lost, each named by its root.
    func spaces() async throws -> [Space] {
        try await replica.read { try Self.spaces(in: $0) }
    }

    static func spaces(in replica: MobileReplica) throws -> [Space] {
        var rows: [ReplicaZone] = []
        var keys: [String] = []
        try replica.connection.query("SELECT zone_key FROM ck_zones WHERE kind = ? ORDER BY zone_key", [.text(SyncZone.space.rawValue.lowercased())]) {
            keys.append($0.text(0) ?? "")
        }
        for key in keys {
            guard try replica.replica.engineState(SpaceSync.StateScope.gone(key)) == nil else { continue }
            if let row = try replica.replica.zone(key: key) { rows.append(row) }
        }
        return try rows.map { row in
            let root = try replica.replica.record(zoneKey: row.zoneKey, recordName: SyncSchema.rootRecordName).flatMap { replica.decode($0.payload) }
            return Space(
                zoneKey: row.zoneKey, zoneName: row.zoneName, isOwned: row.database == .private,
                kind: root?.fields["kind"]?.stringValue, name: root?.fields["name"]?.stringValue,
                ownerName: root?.fields["owner"].flatMap(SyncPerson.init(json:))?.name,
                permission: row.permission, primaryID: row.primaryID ?? root?.fields["primaryID"]?.stringValue
            )
        }
    }

    // MARK: - Paged lists

    /// One SQL statement and its parameters, as a paged list runs it (and its tests explain it).
    struct Statement {
        let sql: String
        let parameters: [SQLiteValue]
    }

    func sources(in zoneKey: String = catalogKey, type: String? = nil, status: String? = "active",
                 order: SourceOrder = .newest, page: Page = .first()) async throws -> [SourceRow] {
        let statement = Self.sourcesStatement(in: zoneKey, type: type, status: status, order: order, page: page)
        return try await replica.read { replica in
            var rows: [SourceRow] = []
            try replica.connection.query(statement.sql, statement.parameters) { rows.append(Self.sourceRow($0, at: 0)) }
            return rows
        }
    }

    static func sourcesStatement(in zoneKey: String, type: String?, status: String?, order: SourceOrder, page: Page) -> Statement {
        var conditions = ["zone_key = ?"]
        var parameters: [SQLiteValue] = [.text(zoneKey)]
        if let status { conditions.append("status = ?"); parameters.append(.text(status)) }
        if let type { conditions.append("type = ?"); parameters.append(.text(type)) }
        let sort = order == .newest ? "added_at DESC, id" : "title_key, id"
        return Statement(sql: """
            SELECT \(sourceColumns) FROM m_sources WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(sort) LIMIT ? OFFSET ?
        """, parameters: parameters + [.integer(Int64(page.limit)), .integer(Int64(page.offset))])
    }

    func sourceCount(in zoneKey: String = catalogKey, type: String? = nil, status: String? = "active") async throws -> Int {
        try await replica.read { replica in
            var conditions = ["zone_key = ?"]
            var parameters: [SQLiteValue] = [.text(zoneKey)]
            if let status { conditions.append("status = ?"); parameters.append(.text(status)) }
            if let type { conditions.append("type = ?"); parameters.append(.text(type)) }
            return Int(try replica.connection.scalarInteger("SELECT COUNT(*) FROM m_sources WHERE \(conditions.joined(separator: " AND "))", parameters) ?? 0)
        }
    }

    /// A book's chapters, a show's episodes, a series' meetings, in their order.
    func sources(inCollection collectionID: String, zoneKey: String = catalogKey, page: Page = .first()) async throws -> [SourceRow] {
        try await replica.read { replica in
            var rows: [SourceRow] = []
            try replica.connection.query("""
                SELECT \(Self.sourceColumns) FROM m_sources WHERE collection_id = ? AND zone_key = ?
                ORDER BY collection_order, added_at, id LIMIT ? OFFSET ?
            """, [.text(collectionID), .text(zoneKey), .integer(Int64(page.limit)), .integer(Int64(page.offset))]) { rows.append(Self.sourceRow($0, at: 0)) }
            return rows
        }
    }

    /// A notebook's items in study order. An item the phone does not hold (a deleted source, a Doc not
    /// arrived yet) is left out until it comes back (§3.5.8); a removed one only when asked for.
    func entries(of notebook: Notebook, includeRemoved: Bool = false, page: Page = .first()) async throws -> [EntryRow] {
        let statement = Self.entriesStatement(of: notebook, includeRemoved: includeRemoved, page: page)
        return try await replica.read { replica in
            var rows: [EntryRow] = []
            try replica.connection.query(statement.sql, statement.parameters) { row in
                rows.append(EntryRow(
                    id: row.text(0) ?? "", zoneKey: row.text(1) ?? "", containerID: row.text(2) ?? "", itemKind: row.text(3),
                    itemID: row.text(4), state: row.text(5), approval: row.text(6), orderKey: row.text(7), origin: row.text(8),
                    role: row.text(9), addedAt: row.integer(10), stateStamp: row.text(11), approvalStamp: row.text(12),
                    source: row.isNull(13) ? nil : Self.sourceRow(row, at: 13)
                ))
            }
            return rows
        }
    }

    /// A private notebook's sources are in `Catalog` and its Docs in `Library`; a space notebook's are
    /// the space's own.
    static func entriesStatement(of notebook: Notebook, includeRemoved: Bool, page: Page) -> Statement {
        let zoneKey = notebook.zoneKey
        let sourceZone = LibraryStructure.zoneName(of: notebook).isSpace ? zoneKey : catalogKey
        return Statement(sql: """
            SELECT e.id, e.zone_key, e.container_id, e.item_kind, e.item_id, e.state, e.approval, e.order_key, e.origin, e.role,
                   e.added_at, e.state_stamp, e.approval_stamp, s.\(sourceColumns.replacingOccurrences(of: ", ", with: ", s."))
            FROM m_entries e
            LEFT JOIN m_sources s ON e.item_kind = 'source' AND s.zone_key = ? AND s.id = e.item_id
            WHERE e.zone_key = ? AND e.container_id = ? AND e.container_kind = 'notebook'\(includeRemoved ? "" : " AND e.state = 'active'")
              AND CASE e.item_kind
                    WHEN 'source' THEN s.id IS NOT NULL
                    WHEN 'artifact' THEN EXISTS (SELECT 1 FROM m_artifacts a WHERE a.zone_key = e.zone_key AND a.id = e.item_id)
                    ELSE 1 END
            ORDER BY e.order_key, e.id LIMIT ? OFFSET ?
        """, parameters: [.text(sourceZone), .text(zoneKey), .text(notebook.notebookID), .integer(Int64(page.limit)), .integer(Int64(page.offset))])
    }

    /// The Docs and other outputs filed in a notebook, newest first.
    func artifacts(of notebook: Notebook, page: Page = .first()) async throws -> [ArtifactRow] {
        try await replica.read { replica in
            var rows: [ArtifactRow] = []
            try replica.connection.query("""
                SELECT id, zone_key, kind, title, notebook_id, status, preview, edited_at FROM m_artifacts
                WHERE zone_key = ? AND notebook_id = ? ORDER BY edited_at DESC, id LIMIT ? OFFSET ?
            """, [.text(notebook.zoneKey), .text(notebook.notebookID), .integer(Int64(page.limit)), .integer(Int64(page.offset))]) { row in
                rows.append(ArtifactRow(id: row.text(0) ?? "", zoneKey: row.text(1) ?? "", kind: row.text(2), title: row.text(3),
                                        notebookID: row.text(4), status: row.text(5), preview: row.text(6), editedAt: row.integer(7)))
            }
            return rows
        }
    }

    /// The courses in the library and the spaces, or those one notebook follows in its order. A course
    /// lives in no notebook: a notebook's one tie to it is its active follow Entry, and it follows only
    /// a course of its own library (§3.5.9, §5.5).
    func courses(of notebook: Notebook? = nil) async throws -> [CourseRow] {
        try await replica.read { replica in
            var rows: [CourseRow] = []
            let sql = notebook == nil
                ? "SELECT id, zone_key, title, status FROM m_courses ORDER BY created_at DESC, id"
                : """
                    SELECT c.id, c.zone_key, c.title, c.status FROM m_entries e
                    JOIN m_courses c ON c.zone_key = e.zone_key AND c.id = e.item_id
                    WHERE e.zone_key = ? AND e.container_kind = 'notebook' AND e.container_id = ?
                      AND e.item_kind = 'course' AND e.state = 'active'
                    ORDER BY e.order_key, e.id
                """
            let parameters: [SQLiteValue] = notebook.map { [.text($0.zoneKey), .text($0.notebookID)] } ?? []
            try replica.connection.query(sql, parameters) { row in
                rows.append(CourseRow(id: row.text(0) ?? "", zoneKey: row.text(1) ?? "", title: row.text(2), status: row.text(3)))
            }
            return rows
        }
    }

    /// A course's lessons in path order.
    func lessons(ofCourse courseID: String, zoneKey: String = libraryKey) async throws -> [LessonRow] {
        try await replica.read { replica in
            var rows: [LessonRow] = []
            try replica.connection.query("SELECT id, course_id, order_key, kind, title FROM m_lessons WHERE zone_key = ? AND course_id = ? ORDER BY order_key, id",
                                         [.text(zoneKey), .text(courseID)]) { row in
                rows.append(LessonRow(id: row.text(0) ?? "", courseID: row.text(1), orderKey: row.text(2), kind: row.text(3), title: row.text(4)))
            }
            return rows
        }
    }

    /// One page of a chat's exchanges in display order (seq, createdAt, id; §3.5.14), decoded: the
    /// only payloads a chat screen reads.
    func exchanges(ofChat chatID: String, zoneKey: String, page: Page = .first()) async throws -> [SyncEnvelope] {
        let statement = Self.exchangesStatement(ofChat: chatID, zoneKey: zoneKey, page: page)
        return try await replica.read { replica in
            var ids: [String] = []
            try replica.connection.query(statement.sql, statement.parameters) { ids.append($0.text(0) ?? "") }
            return try ids.compactMap { try Self.held(.exchange, $0, zoneKey: zoneKey, in: replica) }
        }
    }

    static func exchangesStatement(ofChat chatID: String, zoneKey: String, page: Page) -> Statement {
        Statement(sql: "SELECT id FROM m_exchanges WHERE zone_key = ? AND chat_id = ? ORDER BY seq, created_at, id LIMIT ? OFFSET ?",
                  parameters: [.text(zoneKey), .text(chatID), .integer(Int64(page.limit)), .integer(Int64(page.offset))])
    }

    // MARK: - One record

    /// A record as the phone holds it: the server's version with the phone's pending patch laid over
    /// it (§6.6), decoded. Nil when the phone holds neither.
    func envelope(_ type: SyncRecordType, id: String, zoneKey: String) async throws -> SyncEnvelope? {
        try await replica.read { try Self.held(type, id, zoneKey: zoneKey, in: $0) }
    }

    static func held(_ type: SyncRecordType, _ id: String, zoneKey: String, in replica: MobileReplica) throws -> SyncEnvelope? {
        var record = try replica.replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: id)
        // A record the phone deletes is gone from what it holds while the delete is on its way, as the index
        // has it (`MobileReplica.reindex`): its satellites are not fetched, and an id captured again is new.
        if let held = record, try replica.connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?)", [.text(zoneKey), .text(held.recordName)]
        ) == 1 {
            record = nil
        }
        var envelope = record.flatMap { replica.decode($0.payload) }
        if let patch = try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: id, in: replica.connection) {
            let saltID = try replica.replica.zone(key: zoneKey)?.saltID ?? ""
            envelope = patch.applied(to: envelope ?? SyncEnvelope.new(type, id: id, saltID: saltID))
        }
        return envelope
    }

    /// A Setting's value (§3.5.3): the account's in `Library`, a space's in its zone.
    func setting(_ key: String, zoneKey: String = libraryKey) async throws -> SyncJSON? {
        try await replica.read { replica in
            guard let text = try replica.connection.scalarText("SELECT value_json FROM m_settings WHERE zone_key = ? AND key = ?", [.text(zoneKey), .text(key)])
            else { return nil }
            return try? SyncJSON(parsing: Data(text.utf8))
        }
    }

    /// The personal root's seed, which tells the phone whether its library has moved (§13.6).
    func librarySeed() async throws -> LibrarySeed? {
        try await replica.read { replica in
            guard let root = try replica.replica.record(zoneKey: Self.libraryKey, recordName: SyncSchema.rootRecordName),
                  let envelope = replica.decode(root.payload)
            else { return nil }
            let seed = envelope.fields["seed"]
            return LibrarySeed(state: seed?["state"]?.stringValue, metadataCompleteAt: seed?["metadataCompleteAt"]?.int64Value)
        }
    }

    // MARK: - Helpers

    private static let sourceColumns =
        "id, zone_key, type, title, authors, venue, url, collection_id, status, ingest_state, added_at, published_at, has_pdf"

    private static func sourceRow(_ row: SQLiteRow, at start: Int32) -> SourceRow {
        SourceRow(
            id: row.text(start) ?? "", zoneKey: row.text(start + 1) ?? "", type: row.text(start + 2), title: row.text(start + 3),
            authors: row.text(start + 4), venue: row.text(start + 5), url: row.text(start + 6), collectionID: row.text(start + 7),
            status: row.text(start + 8), ingestState: row.text(start + 9), addedAt: row.integer(start + 10),
            publishedAt: row.integer(start + 11), hasPDF: row.integer(start + 12) == 1
        )
    }
}
