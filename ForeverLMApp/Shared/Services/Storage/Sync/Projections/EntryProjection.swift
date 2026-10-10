import Foundation

// MARK: - The Entry record: the ordered edge (docs/cloudkit-schema-design.md §3.5.8)

/// The parts of an Entry id, `en:<containerID>:<itemKind>:<itemID>` with `#<n>` for a second span:
/// a container id holds no colon (notebook and Goal UUIDs, `playlist_` group ids, lesson ids), while
/// an item id may (a meeting's source id).
struct EntryID: Equatable, Sendable {
    let containerID: String
    let itemKind: String
    let itemID: String

    init?(_ wireID: String) {
        guard wireID.hasPrefix("en:") else { return nil }
        let rest = wireID.dropFirst(3)
        guard let first = rest.firstIndex(of: ":") else { return nil }
        let afterContainer = rest[rest.index(after: first)...]
        guard let second = afterContainer.firstIndex(of: ":") else { return nil }
        let container = String(rest[..<first])
        let kind = String(afterContainer[..<second])
        let item = String(afterContainer[afterContainer.index(after: second)...])
        guard !container.isEmpty, !kind.isEmpty, !item.isEmpty else { return nil }
        self.containerID = container
        self.itemKind = kind
        self.itemID = item
    }

    init(containerID: String, itemKind: String, itemID: String) {
        self.containerID = containerID
        self.itemKind = itemKind
        self.itemID = itemID
    }

    var wireID: String { SyncIdentity.entryID(containerID: containerID, itemKind: itemKind, itemID: itemID) }
}

/// An Entry's local rows: a source in a notebook's or a Goal's pool (`learning_goal_items`), a course
/// a notebook follows (`notebook_course_links`), a playlist's member (`group_members`), or a lesson's
/// item (`course_lecture_items`).
enum EntryRows: Equatable, Sendable {
    case poolItem(PoolItem)
    case followedCourse(notebookID: String, courseID: String)
    case playlist(PlaylistEntryProjection.Rows)
    case lessonItem(LessonItemRows)

    struct PoolItem: Equatable, Sendable {
        let containerKind: String
        let containerID: String
        let sourceID: String
        let addedAt: Double
        let origin: String?
        let reviewState: String?
        let relevance: Double?
        let orderKey: String?
    }
}

/// The Entry record's projection (§3.5.8) for every container a Mac holds rows for: notebooks and
/// Goals (their pool), a notebook's followed courses, playlists (WP7's `PlaylistEntryProjection`,
/// folded in: one projection per type) and lessons (WP9's `LessonEntryProjection`). A course lives in
/// no notebook: a notebook's followed course is its one tie to it. A space's Entries are WP15's; until
/// then they stay in the replica, unprojected.
///
/// Approval is shared editorial state and travels (bug b2); no per-member field is on the record:
/// the member's chat ticks are `NotebookState.excluded` (§5.6). A removed item is a deleted row,
/// which the outbox sends as `state = removed` while the container lives; a remove and a re-add,
/// which mint two row ids, are one record (`record_key_json` is its container and source).
struct EntryProjection: RecordProjection {
    var recordType: SyncRecordType { .entry }

    static let poolColumns = ["added_at", "origin", "review_state", "relevance", "order_key"]

    static let wireOrigins: Set<String> = ["seed", "added", "discovered", "course", "import", "chat", "mcp", "share", "cutover"]

    var tables: [ProjectedTable] {
        let poolSQL: @Sendable (String) -> String = { "'en:' || \($0).goal_id || ':source:' || \($0).source_id" }
        let courseSQL: @Sendable (String) -> String = { "'en:' || \($0).goal_id || ':course:' || \($0).course_id" }
        // A merged notebook's stub holds no Entries: one leaving it is deleted, never left removed (§5.2).
        let container = LocalParent("goal_id", references: "learning_goals", type: .notebook, role: .container,
                                    retiredWhen: NotebookStubs.isStubSQL)
        return [
            ProjectedTable(
                "learning_goal_items", localKey: ["id"], keyColumns: ["goal_id", "source_id"], syncedColumns: Self.poolColumns,
                parents: [container, LocalParent("source_id", references: "sources", type: .source, role: .item)],
                recordTypes: [.entry],
                record: { values in
                    guard let goal = values["goal_id"]?.textValue, let source = values["source_id"]?.textValue else { return nil }
                    let id = SyncIdentity.entryID(containerID: goal, itemKind: "source", itemID: source)
                    return RowRecord(type: .entry, localID: id, personalID: id)
                },
                localIDSQL: poolSQL, personalIDSQL: poolSQL
            ),
            ProjectedTable(
                "notebook_course_links", localKey: ["goal_id", "course_id"], keyColumns: ["goal_id", "course_id"], syncedColumns: [],
                parents: [container, LocalParent("course_id", references: "courses", type: .course, role: .item)],
                recordTypes: [.entry],
                record: { values in
                    guard let goal = values["goal_id"]?.textValue, let course = values["course_id"]?.textValue else { return nil }
                    let id = SyncIdentity.entryID(containerID: goal, itemKind: "course", itemID: course)
                    return RowRecord(type: .entry, localID: id, personalID: id)
                },
                localIDSQL: courseSQL, personalIDSQL: courseSQL
            ),
        ] + PlaylistEntryProjection().tables + LessonEntryProjection().tables
    }

    var feeds: [String: FieldFeed] {
        let existence: FieldFeed = .anyOf([
            .rowExistence(table: "learning_goal_items"), .rowExistence(table: "notebook_course_links"), .rowExistence(table: "group_members"),
            .rowExistence(table: "course_lecture_items"),
        ])
        return [
            "state": existence, "containerKind": existence, "containerID": existence, "itemKind": existence, "itemID": existence,
            "origin": .anyOf([
                .columns(table: "learning_goal_items", ["origin"]), .rowExistence(table: "notebook_course_links"), .rowExistence(table: "group_members"),
                .rowExistence(table: "course_lecture_items"),
            ]),
            "addedAt": .anyOf([
                .columns(table: "learning_goal_items", ["added_at"]), .rowExistence(table: "group_members"), .columns(table: "course_lecture_items", ["created_at"]),
            ]),
            "approval": .columns(table: "learning_goal_items", ["review_state"]),
            "relevance": .columns(table: "learning_goal_items", ["relevance"]),
            "orderKey": .anyOf([
                .columns(table: "learning_goal_items", ["order_key"]), .columns(table: "group_members", ["sort_index"]),
                .columns(table: "course_lecture_items", ["order_key"]),
            ]),
            "role": .columns(table: "course_lecture_items", ["role"]),
            "label": .columns(table: "course_lecture_items", ["label"]),
            "span": .columns(table: "course_lecture_items", ["span_json"]),
        ]
    }

    /// A row removed while its container and item stay is `state = removed`; the record is never
    /// deleted while its container lives (§3.5.8), and a missing item writes nothing (§5.7).
    var missingRow: MissingRowOutcome { .fields(["state": .string("removed")]) }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> EntryRows? {
        guard let id = EntryID(record.wireID) else { return nil }
        if id.containerID.hasPrefix(PlaylistEntryProjection.playlistPrefix) {
            return try PlaylistEntryProjection().loadRows(record, connection: connection).map(EntryRows.playlist)
        }
        // A space's rows are read by their local ids and sent under their wire ids (§4.3).
        let local = record.localID == record.wireID ? id : EntryID(record.localID) ?? id
        if id.itemKind == "source", let item = try LessonEntryProjection().loadRows(local, wire: id, connection: connection) {
            return .lessonItem(item)
        }
        switch id.itemKind {
        case "source":
            var item: EntryRows.PoolItem?
            try connection.query("""
                SELECT g.entity_kind, g.kind, g.parent_notebook_id, g.end_at,
                       i.added_at, i.origin, i.review_state, i.relevance, i.order_key
                FROM learning_goal_items i JOIN learning_goals g ON g.id = i.goal_id
                WHERE i.goal_id = ? AND i.source_id = ?
            """, [.text(local.containerID), .text(local.itemID)]) { row in
                let kind = row.text(0) ?? LearningGoalEntityKind.kind(kind: row.text(1), parentNotebookID: row.text(2), endAt: row.real(3) ?? 0)
                item = EntryRows.PoolItem(
                    containerKind: kind, containerID: id.containerID, sourceID: id.itemID, addedAt: row.real(4) ?? 0,
                    origin: row.text(5), reviewState: row.text(6), relevance: row.real(7), orderKey: row.text(8)
                )
            }
            return item.map(EntryRows.poolItem)
        case "course":
            let held = try connection.scalarInteger(
                "SELECT EXISTS(SELECT 1 FROM notebook_course_links WHERE goal_id = ? AND course_id = ?)", [.text(id.containerID), .text(id.itemID)]
            ) == 1
            return held ? .followedCourse(notebookID: id.containerID, courseID: id.itemID) : nil
        default:
            return nil
        }
    }

    static func encodeRows(_ rows: EntryRows) -> [String: SyncJSON] {
        switch rows {
        case .playlist(let playlist):
            return PlaylistEntryProjection.encodeRows(playlist)
        case .lessonItem(let item):
            return LessonEntryProjection.encodeRows(item)
        case .followedCourse(let notebookID, let courseID):
            return [
                "containerKind": .string("notebook"), "containerID": .string(notebookID), "itemKind": .string("course"),
                "itemID": .string(courseID), "state": .string("active"), "origin": .string("course"),
                "orderKey": .string(SourceOrderKeys.key(forIndex: 0) ?? "a0"),
            ]
        case .poolItem(let item):
            var fields: [String: SyncJSON] = [
                "containerKind": .string(item.containerKind == LearningGoalEntityKind.goal ? "goal" : "notebook"),
                "containerID": .string(item.containerID), "itemKind": .string("source"), "itemID": .string(item.sourceID),
                "state": .string("active"),
                "origin": .string(item.origin.flatMap { wireOrigins.contains($0) ? $0 : nil } ?? (item.origin == nil ? "seed" : "added")),
                "addedAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: item.addedAt)),
                "relevance": item.relevance.map(SyncJSON.number) ?? .null,
            ]
            // Absent approval means approved: a row that never held one sends none, so an untick that
            // named no approval stamp keeps matching (§5.6). A Goal's items carry no approval.
            if item.containerKind != LearningGoalEntityKind.goal, let state = item.reviewState,
               ["approved", "pending", "rejected"].contains(state) {
                fields["approval"] = .string(state)
            }
            if let key = item.orderKey { fields["orderKey"] = .string(key) }
            return fields
        }
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        let fields = envelope.fields
        guard let wire = EntryID(record.wireID) else { return .projected }
        if record.zone.isSpace, fields["containerKind"]?.stringValue != "notebook" || wire.itemKind != "source" {
            // A space holds notebook pools only: a space's lessons and playlists are not projected here.
            return .projected
        }
        let id: EntryID
        switch try Self.localIDs(of: wire, in: record, connection: connection) {
        case .local(let local): id = local
        case .waiting(let parent): return .waiting([parent])
        }
        switch fields["containerKind"]?.stringValue {
        case "playlist":
            return try PlaylistEntryProjection().apply(envelope, to: record, connection: connection)
        case "notebook", "goal":
            break
        case "lesson":
            return try LessonEntryProjection().apply(envelope, to: record, connection: connection)
        default:
            return .projected
        }
        let containerType: SyncRecordType = fields["containerKind"]?.stringValue == "goal" ? .goal : .notebook
        let removed = fields["state"]?.stringValue == "removed"
        let containerHeld = try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ?)", [.text(id.containerID)]) == 1

        switch id.itemKind {
        case "course":
            if removed {
                try connection.execute("DELETE FROM notebook_course_links WHERE goal_id = ? AND course_id = ?", [.text(id.containerID), .text(id.itemID)])
                return .projected
            }
            guard containerHeld else { return .waiting([WaitingParent(type: containerType, wireID: id.containerID)]) }
            try connection.execute(
                "INSERT INTO notebook_course_links (goal_id, course_id) VALUES (?, ?) ON CONFLICT(goal_id, course_id) DO NOTHING",
                [.text(id.containerID), .text(id.itemID)]
            )
            return .projected
        case "source":
            break
        default:
            return .projected
        }

        if removed {
            try connection.execute("DELETE FROM learning_goal_items WHERE goal_id = ? AND source_id = ?", [.text(id.containerID), .text(id.itemID)])
            return .projected
        }
        // The item may arrive later (`source_id` has no foreign key); the container must be here.
        guard containerHeld else { return .waiting([WaitingParent(type: containerType, wireID: id.containerID)]) }
        let addedAt = fields["addedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        let approval = fields["approval"].map { $0.isNull ? SQLiteValue.null : .text($0.stringValue) }
        let relevance = fields["relevance"].map { SQLiteValue.real($0.numberValue) }
        let orderKey = fields["orderKey"]?.stringValue
        let origin = fields["origin"]?.stringValue
        let exists = try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM learning_goal_items WHERE goal_id = ? AND source_id = ?)", [.text(id.containerID), .text(id.itemID)]
        ) == 1
        if exists {
            var assignments: [String] = []
            var values: [SQLiteValue] = []
            if let addedAt { assignments.append("added_at = MIN(added_at, ?)"); values.append(.real(addedAt)) }
            if let approval { assignments.append("review_state = ?"); values.append(approval) }
            if let relevance { assignments.append("relevance = ?"); values.append(relevance) }
            if let orderKey { assignments.append("order_key = ?"); values.append(.text(orderKey)) }
            if let origin { assignments.append("origin = ?"); values.append(.text(origin)) }
            if !assignments.isEmpty {
                try connection.execute(
                    "UPDATE learning_goal_items SET \(assignments.joined(separator: ", ")) WHERE goal_id = ? AND source_id = ?",
                    values + [.text(id.containerID), .text(id.itemID)]
                )
            }
        } else {
            try connection.execute("""
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, origin, review_state, relevance, order_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(UUID().uuidString), .text(id.containerID), .text(id.itemID), .real(addedAt ?? Date().timeIntervalSinceReferenceDate),
                .text(origin), approval ?? .null, relevance ?? .null, .text(orderKey),
            ])
        }
        try EntryOrderKeys.deriveSequence(goalID: id.containerID, connection: connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard let wire = EntryID(record.wireID) else { return }
        if record.zone.isSpace {
            if let local = EntryID(record.localID), local.itemKind == "source" {
                try connection.execute("DELETE FROM learning_goal_items WHERE goal_id = ? AND source_id = ?", [.text(local.containerID), .text(local.itemID)])
            }
            try connection.execute("DELETE FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
                                   [.text(record.zoneKey), .text(SyncRecordType.entry.rawValue), .text(record.wireID)])
            return
        }
        let id = wire
        if id.containerID.hasPrefix(PlaylistEntryProjection.playlistPrefix) {
            try PlaylistEntryProjection().applyDeletion(record, connection: connection)
        } else if id.itemKind == "source", try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM course_lectures WHERE id = ?)", [.text(id.containerID)]) == 1 {
            try LessonEntryProjection().applyDeletion(id, connection: connection)
        } else if id.itemKind == "course" {
            try connection.execute("DELETE FROM notebook_course_links WHERE goal_id = ? AND course_id = ?", [.text(id.containerID), .text(id.itemID)])
        } else if id.itemKind == "source" {
            try connection.execute("DELETE FROM learning_goal_items WHERE goal_id = ? AND source_id = ?", [.text(id.containerID), .text(id.itemID)])
        }
    }
}

extension EntryProjection {
    enum LocalEntry {
        case local(EntryID)
        case waiting(WaitingParent)
    }

    /// The local ids an inbound Entry's rows go by. The personal library's are its wire ids; a space
    /// notebook's pool item names the space's local rows of its notebook and its source, which arrive
    /// first (a space's copy of a source has a local id of its own, §4.3), and its identity is recorded.
    static func localIDs(of wire: EntryID, in record: ProjectionRecordRef, connection: SQLiteConnection) throws -> LocalEntry {
        guard record.zone.isSpace else { return .local(wire) }
        guard let notebook = try SpaceRows.localID(zoneKey: record.zoneKey, type: .notebook, wireID: wire.containerID, connection: connection) else {
            return .waiting(WaitingParent(type: .notebook, wireID: wire.containerID))
        }
        guard let source = try SpaceRows.localID(zoneKey: record.zoneKey, type: .source, wireID: wire.itemID, connection: connection) else {
            return .waiting(WaitingParent(type: .source, wireID: wire.itemID))
        }
        let local = EntryID(containerID: notebook, itemKind: wire.itemKind, itemID: source)
        // A pool item of a notebook that moved here keeps its row, naming the space's copy of its source (WP15b).
        try SpaceMoveLocal.adoptPoolItem(notebook: notebook, source: source, sourceWireID: wire.itemID, connection: connection)
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(record.zoneKey), .text(SyncRecordType.entry.rawValue), .text(record.wireID), .text(local.wireID)])
        return .local(local)
    }
}

// MARK: - Study order under generation 2

/// A pool's study order as generation 1 reads it (`sequence`, then `added_at`) and as the Entries
/// carry it (`order_key`, §3.5.8). Under generation 2 `order_key` is what syncs: a local write keys the
/// rows it moved with as few new keys as it can (`replan`), and an inbound order rewrites `sequence`
/// so every generation-1 reader shows it (`deriveSequence`). Neither runs under generation 1.
enum EntryOrderKeys {
    /// Keys the pool in the order its rows read now, changing only the keys out of that order.
    static func replan(goalID: String, connection: SQLiteConnection) throws {
        var ordered: [(id: String, key: String?)] = []
        try connection.query("""
            SELECT source_id, order_key FROM learning_goal_items WHERE goal_id = ?
            ORDER BY (sequence IS NULL) ASC, sequence ASC, added_at ASC, source_id ASC
        """, [.text(goalID)]) { row in
            if let source = row.text(0) { ordered.append((source, row.text(1))) }
        }
        for (source, key) in OrderKeyPlanner.plan(ordered).sorted(by: { $0.key < $1.key }) {
            try connection.execute(
                "UPDATE learning_goal_items SET order_key = ? WHERE goal_id = ? AND source_id = ?",
                [.text(key), .text(goalID), .text(source)]
            )
        }
    }

    /// `sequence` as each row's rank in key order, so generation-1 readers show the synced order. One
    /// ranking pass (O(n log n)), writing only the rows whose rank moved: it runs after every inbound pool
    /// Entry, so a notebook of 1,500 sources arriving one Entry at a time must not rank each row by
    /// counting every other (about 3.4 billion row visits across the bootstrap).
    static func deriveSequence(goalID: String, connection: SQLiteConnection) throws {
        try connection.execute("""
            UPDATE learning_goal_items SET sequence = ranked.rank
            FROM (
                SELECT source_id, ROW_NUMBER() OVER (ORDER BY order_key, source_id) - 1 AS rank
                FROM learning_goal_items WHERE goal_id = ?1 AND order_key IS NOT NULL
            ) AS ranked
            WHERE learning_goal_items.goal_id = ?1 AND learning_goal_items.source_id = ranked.source_id
              AND learning_goal_items.sequence IS NOT ranked.rank
        """, [.text(goalID)])
    }

    /// The key a row added at the end of the pool takes: after the last key held.
    static func appendedKey(goalID: String, connection: SQLiteConnection) throws -> String? {
        let last = try connection.scalarText("SELECT MAX(order_key) FROM learning_goal_items WHERE goal_id = ?", [.text(goalID)])
        return try? FractionalIndex.key(between: last.flatMap { FractionalIndex.isValid($0) ? $0 : nil }, and: nil)
    }
}
