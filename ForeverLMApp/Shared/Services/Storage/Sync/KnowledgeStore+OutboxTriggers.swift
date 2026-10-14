import Foundation

// MARK: - The outbox triggers (docs/cloudkit-schema-design.md §6.6 step 1, §5.7)

/// The triggers the projection registry's tables get, as SQL.
///
/// Every write to a projected table outside an inbound apply records itself in the outbox, on every
/// connection to `knowledge.db` (the MCP store's included), so nothing has to remember to mark a
/// change:
/// - an INSERT records the row's existence, the pseudo-column `__row`, at the statement's time; every
///   column of the row takes that time until it changes itself (one field row per inserted row, D9);
/// - an UPDATE records each read column whose value changed (`OLD.c IS NOT NEW.c`), at its own time;
///   a write that changes no read column, or none at all (a same-value full-row save), records nothing;
/// - a DELETE records the removal of the row from its record, with the record's key read from `OLD`,
///   so it is routed after the row is gone;
/// - an UPDATE that changes a column naming the row's record (a key column) records the removal from
///   the old record and the insert into the new one.
///
/// A removal lives in `ck_outbox` under its own key, the row's local key and its record key joined by
/// U+001F, so each (row, record) pair is one removal: a row removed, re-added and removed again never
/// loses the first record's removal. Live rows' changes are `ck_outbox_fields` rows under the row's
/// local key, and the record they belong to is read from the row itself when it is sent. Writing only
/// what is needed keeps a bulk insert cheap: an INSERT touches one small table.
///
/// The parent tables get readiness triggers that mark the records waiting on a new row ready, and the
/// child tables relist triggers that put a record back in `ck_unprojected` when a cascade (local or
/// inbound) removed its row with its parent. Those two fire inside an apply too.
enum OutboxTriggerSQL {
    /// The statement's time in Cocoa seconds, as every time in `knowledge.db` is kept, at SQLite's
    /// millisecond resolution. 2451910.5 is 2001-01-01 00:00 UTC as a Julian day.
    static let now = "((julianday('now') - 2451910.5) * 86400.0)"
    /// True outside an inbound apply: the guard row exists only inside one (§6.6 step 2).
    static let outsideApply = "NOT EXISTS (SELECT 1 FROM ck_apply_guard)"
    /// Every trigger the installer makes starts with this, and replacing them drops every one of them.
    static let namePrefix = "ck_"

    struct Trigger: Equatable, Sendable {
        let name: String
        let sql: String
    }

    static func triggers(for registry: ProjectionRegistry, wireKeyedTables: Set<String>) -> [Trigger] {
        var triggers: [Trigger] = []
        var readiness: [String: LocalParent] = [:]
        for table in registry.mergedTables {
            triggers += outboxTriggers(table)
            for (index, declaration) in table.declarations.enumerated() {
                for parent in declaration.parents {
                    triggers.append(relistTrigger(table: table.name, index: index, declaration: declaration, parent: parent))
                    readiness["\(parent.table).\(parent.parentColumn).\(parent.recordType.rawValue)"] = parent
                }
            }
        }
        for key in readiness.keys.sorted() {
            guard let parent = readiness[key] else { continue }
            triggers.append(readinessTrigger(parent, wireKeyed: wireKeyedTables.contains(parent.table)))
        }
        return triggers
    }

    /// sha256 of every trigger's SQL in order: `ck_activation.trigger_hash`.
    static func hash(_ triggers: [Trigger]) -> String {
        ProjectionRegistry.hash(triggers.map(\.sql).joined(separator: ";\n"))
    }

    // MARK: Pieces

    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The row's identity in the outbox: its primary key, or a JSON array of a composite one.
    static func localKey(_ columns: [String], _ row: String) -> String {
        if columns.count == 1 { return "\(row).\(quoted(columns[0]))" }
        return "json_array(" + columns.map { "\(row).\(quoted($0))" }.joined(separator: ", ") + ")"
    }

    /// `record_key_json`: the routing columns of the row as a JSON object.
    static func routing(_ columns: [String], _ row: String) -> String {
        "json_object(" + columns.map { "\(literal($0)), \(row).\(quoted($0))" }.joined(separator: ", ") + ")"
    }

    /// A removal's own key: the row's local key and its record key, joined by U+001F.
    static func removalKey(_ table: MergedProjectedTable, _ row: String) -> String {
        "\(localKey(table.localKey, row)) || char(31) || \(routing(table.routingColumns, row))"
    }

    private static let fieldUpsert = "ON CONFLICT(source_table, local_key, column) DO UPDATE SET dirty_at = excluded.dirty_at"
    private static let removalUpsert = """
        ON CONFLICT(source_table, local_key) DO UPDATE SET record_key_json = excluded.record_key_json, \
        op = excluded.op, dirty_at = excluded.dirty_at
        """

    private static func removal(_ table: MergedProjectedTable, op: String) -> String {
        let name = literal(table.name)
        let key = removalKey(table, "OLD")
        return """
            INSERT INTO ck_outbox (source_table, local_key, record_key_json, op, dirty_at)
            VALUES (\(name), \(key), \(routing(table.routingColumns, "OLD")), \(literal(op)), \(now)) \(removalUpsert);
            INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at)
            VALUES (\(name), \(key), '__row', \(now)) \(fieldUpsert);
            """
    }

    private static func rowInserted(_ table: MergedProjectedTable) -> String {
        """
        INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at)
        VALUES (\(literal(table.name)), \(localKey(table.localKey, "NEW")), '__row', \(now)) \(fieldUpsert);
        """
    }

    /// The name of the trigger that records a table's inserts: every watched table has one.
    static func insertTriggerName(_ table: String) -> String { "ck_outbox_insert_\(table)" }

    static func outboxTriggers(_ table: MergedProjectedTable) -> [Trigger] {
        let name = table.name
        var triggers = [
            Trigger(name: insertTriggerName(name), sql: """
                CREATE TRIGGER ck_outbox_insert_\(name) AFTER INSERT ON \(quoted(name))
                WHEN \(outsideApply)
                BEGIN
                \(rowInserted(table))
                END
                """),
        ]
        if !table.valueColumns.isEmpty {
            // One statement whatever the column count: the changed columns' names, as JSON, become
            // rows. A same-value write gives an array of NULLs and so no row.
            let changed = table.valueColumns.map { column in
                "CASE WHEN OLD.\(quoted(column)) IS NOT NEW.\(quoted(column)) THEN \(literal(column)) END"
            }
            triggers.append(Trigger(name: "ck_outbox_update_\(name)", sql: """
                CREATE TRIGGER ck_outbox_update_\(name) AFTER UPDATE OF \(table.valueColumns.map(quoted).joined(separator: ", ")) ON \(quoted(name))
                WHEN \(outsideApply)
                BEGIN
                INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at)
                SELECT \(literal(name)), \(localKey(table.localKey, "NEW")), value, \(now)
                FROM json_each(json_array(\(changed.joined(separator: ", ")))) WHERE value IS NOT NULL \(fieldUpsert);
                END
                """))
        }
        // Compiled only into statements that set a key column, so an ordinary save never pays for it.
        let keyChanged = table.keyColumns.map { "OLD.\(quoted($0)) IS NOT NEW.\(quoted($0))" }.joined(separator: " OR ")
        triggers.append(Trigger(name: "ck_outbox_rekey_\(name)", sql: """
            CREATE TRIGGER ck_outbox_rekey_\(name) AFTER UPDATE OF \(table.keyColumns.map(quoted).joined(separator: ", ")) ON \(quoted(name))
            WHEN \(outsideApply) AND (\(keyChanged))
            BEGIN
            \(removal(table, op: "rekey"))
            \(rowInserted(table))
            END
            """))
        triggers.append(Trigger(name: "ck_outbox_delete_\(name)", sql: """
            CREATE TRIGGER ck_outbox_delete_\(name) AFTER DELETE ON \(quoted(name))
            WHEN \(outsideApply)
            BEGIN
            \(removal(table, op: "delete"))
            END
            """))
        return triggers
    }

    /// A logical id from a local id: the mapping `ck_identity` holds for a space copy, else the id
    /// itself (the personal library's rows).
    private static func wireID(types: [SyncRecordType], localID: String, personalID: String) -> String {
        let typeList = types.map { literal($0.rawValue) }.joined(separator: ", ")
        return "COALESCE((SELECT wire_id FROM ck_identity WHERE record_type IN (\(typeList)) AND local_id = \(localID)), \(personalID))"
    }

    /// A row removed while its parent is missing (a cascade from the parent, local or inbound) puts
    /// its record, when the replica holds it, back in `ck_unprojected`, waiting for the parent.
    static func relistTrigger(table: String, index: Int, declaration: ProjectedTable, parent: LocalParent) -> Trigger {
        let name = "ck_relist_\(table)_\(index)_\(parent.column)"
        let parentID = "OLD.\(quoted(parent.column))"
        let types = declaration.recordTypes.map { literal($0.rawValue) }.joined(separator: ", ")
        let recordID = wireID(types: declaration.recordTypes, localID: declaration.localIDSQL("OLD"), personalID: declaration.personalIDSQL("OLD"))
        return Trigger(name: name, sql: """
            CREATE TRIGGER \(name) AFTER DELETE ON \(quoted(table))
            WHEN \(parentID) IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM \(quoted(parent.table)) WHERE \(quoted(parent.parentColumn)) = \(parentID))
            BEGIN
            INSERT INTO ck_unprojected (zone_key, record_name, waiting_on_type, waiting_on_id, ready)
            SELECT record.zone_key, record.record_name, \(literal(parent.recordType.rawValue)),
                \(wireID(types: [parent.recordType], localID: parentID, personalID: parentID)), 0
            FROM ck_records AS record
            WHERE record.zone_key IN (SELECT zone_key FROM ck_zones)
                AND record.record_type IN (\(types)) AND record.wire_id = \(recordID)
            ON CONFLICT(zone_key, record_name, waiting_on_type, waiting_on_id) DO UPDATE SET ready = 0;
            END
            """)
    }

    /// A new parent row marks the records waiting on it ready, by a local write or an apply alike.
    static func readinessTrigger(_ parent: LocalParent, wireKeyed: Bool) -> Trigger {
        let name = "ck_ready_\(parent.table)_\(parent.parentColumn)_\(parent.recordType.rawValue)"
        let newID = "NEW.\(quoted(parent.parentColumn))"
        let wire = wireKeyed && parent.parentColumn == "id"
            ? "NEW.wire_key"
            : wireID(types: [parent.recordType], localID: newID, personalID: newID)
        return Trigger(name: name, sql: """
            CREATE TRIGGER \(name) AFTER INSERT ON \(quoted(parent.table))
            BEGIN
            UPDATE ck_unprojected SET ready = 1
            WHERE waiting_on_type = \(literal(parent.recordType.rawValue)) AND waiting_on_id = \(wire) AND ready = 0;
            END
            """)
    }
}

// MARK: - Installing them

enum OutboxTriggerError: Error, LocalizedError, Equatable {
    /// Generation 1 never has an outbox trigger (D40): nothing would ever drain what it records.
    case generation1

    var errorDescription: String? {
        switch self {
        case .generation1: return "The outbox triggers are generation 2's; a generation-1 store never gets them."
        }
    }
}

extension KnowledgeStore {
    /// The projections this build runs. Each projection package adds its own here (WP7 onwards).
    static let projectionRegistry = ProjectionRegistry([
        SourceProjection(),
        CollectionProjection(),
        NotebookProjection(),
        GoalProjection(),
        // Notebook, Goal, playlist and lesson Entries (WP8; it holds WP7's playlist Entries and WP9's
        // lesson items).
        EntryProjection(),
        NotebookStateProjection(),
        // A course and what it holds, and the member's Enrollment (WP9).
        CourseProjection(),
        LessonProjection(),
        QuizProjection(),
        EnrollmentProjection(),
        // Chats and their Exchanges (WP10); a rating is a Mark, below.
        ChatProjection(),
        ExchangeProjection(),
        // Docs, Notes Docs and their Comments (WP11).
        ArtifactProjection(),
        CommentProjection(),
        // The member's reading state (WP12).
        ReadingStateProjection(),
        // Cards, Sittings, activity logs and practices (WP13).
        CardProjection(),
        SittingProjection(),
        ActivityLogProjection(),
        PracticeProjection(),
        // The member's Ideas and their links (§3.5.26; registered after the activation, so an activated
        // store's existing rows are sent by the trigger refresh, `installOutboxTriggers`).
        IdeaProjection(),
        // A notebook's tasks, a team's share requests and a meeting's action items, the member's
        // Jobs and Automations (WP14).
        TaskProjection(),
        JobProjection(),
        AutomationProjection(),
        // The member's Marks, highlights, Schedule placements, Settings and devices (WP12b).
        MarkProjection(),
        HighlightProjection(),
        PlacementProjection(),
        SettingProjection(),
        DeviceProjection(),
    ])

    /// The `ck_` triggers the store holds now, by name.
    func installedOutboxTriggers() throws -> [String: String] {
        var triggers: [String: String] = [:]
        try query("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND substr(name, 1, 3) = 'ck_'") { statement in
            if let name = self.string(statement, 0) { triggers[name] = self.string(statement, 1) ?? "" }
        }
        return triggers
    }

    /// Creates the registry's triggers (§13.3 step 3d), replacing every earlier `ck_` trigger in one
    /// transaction, and records `ck_activation.trigger_hash`. A store whose recorded hash and triggers
    /// already match is left alone, so a launch with an unchanged registry writes nothing. Generation 2
    /// only: no migration creates these, and generation 1 never runs this (D40).
    ///
    /// The activation installs them first; every later launch of an activated store refreshes them
    /// (`GenerationActivationRunner`), so a build whose registry changed watches what it now reads. A
    /// table the refresh watches for the first time (a projection registered after the activation, such
    /// as the Idea's) has rows no trigger ever saw and no seed walked: each is handed to the outbox in the
    /// same transaction, as the seed hands one, dated with its own time (`SeedRowReader.enqueueAll`).
    @discardableResult
    func installOutboxTriggers(_ registry: ProjectionRegistry = KnowledgeStore.projectionRegistry) throws -> String {
        guard syncGeneration == .two else { throw OutboxTriggerError.generation1 }
        let triggers = OutboxTriggerSQL.triggers(for: registry, wireKeyedTables: Set(Self.wireKeyedTables))
        let hash = OutboxTriggerSQL.hash(triggers)
        try exec("BEGIN IMMEDIATE")
        do {
            let installed = try installedOutboxTriggers()
            let recorded = try scalarText("SELECT trigger_hash FROM ck_activation WHERE id = 1")
            let current = recorded == hash
                && Set(installed.keys) == Set(triggers.map(\.name))
            if !current {
                // Only a refresh has tables that were not watched before: the activation's first install
                // leaves every existing row to the seed or the reconcile.
                let unwatched = installed.isEmpty ? [] : SeedTable.tables(in: registry).filter {
                    installed[OutboxTriggerSQL.insertTriggerName($0.name)] == nil
                }
                for name in installed.keys.sorted() {
                    try exec("DROP TRIGGER IF EXISTS \(OutboxTriggerSQL.quoted(name))")
                }
                for trigger in triggers {
                    try exec(trigger.sql)
                }
                let reader = SeedRowReader(connection: self, registry: registry, fallbackTime: Date().timeIntervalSinceReferenceDate)
                for table in unwatched {
                    let rows = try reader.enqueueAll(of: table)
                    logger.notice("Outbox now watches \(table.name, privacy: .public): \(rows) existing rows queued")
                }
                try execute("""
                    INSERT INTO ck_activation (id, trigger_hash) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET trigger_hash = excluded.trigger_hash
                """, [.text(hash)])
            }
            try exec("COMMIT")
            if !current {
                logger.notice("Installed \(triggers.count) outbox triggers (hash \(hash.prefix(12), privacy: .public))")
            }
            return hash
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

// MARK: - Inbound records into their projections, and the re-projection (§5.7)

/// What an inbound apply does with each record the replica takes, inside its transaction and under
/// the guard: the record's projection writes its local rows, or, when a local parent is missing, the
/// record waits in `ck_unprojected` until the parent's row arrives. The readiness triggers mark waiting
/// records ready, whether the parent came by an apply or by a local write (a re-import of the same
/// id), and `drainReady` projects them again under the guard. Nothing here depends on the order
/// records arrive in.
struct ProjectionApply {
    let store: KnowledgeStore
    let registry: ProjectionRegistry

    enum Failure: Error, Equatable {
        /// Projections write under the guard only, or what they write would be sent back.
        case outsideApply
        case unknownZone(String)
    }

    /// The zone a zone key names (`private/Library`, `shared/<owner>/Space-x`).
    static func zone(ofKey zoneKey: String) throws -> SyncZoneName {
        guard let zone = ProjectionZones.zone(ofKey: zoneKey) else { throw Failure.unknownZone(zoneKey) }
        return zone
    }

    func reference(zoneKey: String, type: SyncRecordType, wireID: String) throws -> ProjectionRecordRef {
        ProjectionRecordRef(
            zoneKey: zoneKey, zone: try Self.zone(ofKey: zoneKey), type: type, wireID: wireID,
            localID: try store.localID(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID) ?? wireID
        )
    }

    /// Notebooks one record the replica holds. Nil for a type no projection reads: it stays raw in the
    /// replica and is projected after an upgrade that knows it (§6.5 rule 2). A record written into its
    /// rows is noted for the surfaces that hold them in memory (`AppliedRemoteChanges`), unless
    /// `announces` is false: a version the rows held already (`InboundApply`'s own save coming back).
    @discardableResult
    func project(_ record: ReplicaRecord, announces: Bool = true) throws -> ProjectionApplyOutcome? {
        guard try store.replica.isApplying else { throw Failure.outsideApply }
        guard let type = SyncRecordType(rawValue: record.recordType), let projection = registry.projection(for: type) else {
            try clearWaits(zoneKey: record.zoneKey, recordName: record.recordName)
            return nil
        }
        let envelope = try SyncEnvelope(storedPayload: record.payload)
        let reference = try reference(zoneKey: record.zoneKey, type: type, wireID: record.wireID)
        let outcome = try projection.apply(envelope, to: reference, connection: store)
        switch outcome {
        case .projected:
            if announces { store.appliedRemoteChanges.note(type, localID: reference.localID) }
            try clearWaits(zoneKey: record.zoneKey, recordName: record.recordName)
            // A record of a type the readiness triggers cannot name by local id (a space copy whose
            // identity was recorded after its row) still frees what waits on it.
            try store.execute(
                "UPDATE ck_unprojected SET ready = 1 WHERE waiting_on_type = ? AND waiting_on_id = ? AND ready = 0",
                [.text(type.rawValue), .text(record.wireID)]
            )
        case .waiting(let parents):
            try clearWaits(zoneKey: record.zoneKey, recordName: record.recordName)
            for parent in Set(parents) {
                try store.execute("""
                    INSERT INTO ck_unprojected (zone_key, record_name, waiting_on_type, waiting_on_id, ready)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(zone_key, record_name, waiting_on_type, waiting_on_id) DO UPDATE SET ready = 0
                """, [.text(record.zoneKey), .text(record.recordName), .text(parent.type.rawValue), .text(parent.wireID)])
            }
        }
        return outcome
    }

    /// Removes the local rows of a record the server deleted; the caller removes its replica row.
    func projectDeletion(zoneKey: String, recordName: String, type: SyncRecordType, wireID: String) throws {
        guard try store.replica.isApplying else { throw Failure.outsideApply }
        try clearWaits(zoneKey: zoneKey, recordName: recordName)
        guard let projection = registry.projection(for: type) else { return }
        let reference = try reference(zoneKey: zoneKey, type: type, wireID: wireID)
        try projection.applyDeletion(reference, connection: store)
        store.appliedRemoteChanges.note(type, localID: reference.localID)
    }

    /// Notebooks again, under the guard, the records whose parents have arrived; at most `limit`.
    @discardableResult
    func drainReady(limit: Int = 500) throws -> Int {
        guard try store.replica.isApplying else { throw Failure.outsideApply }
        var projected = 0
        while projected < limit {
            var ready: [(zoneKey: String, recordName: String)] = []
            try store.query(
                "SELECT DISTINCT zone_key, record_name FROM ck_unprojected WHERE ready = 1 LIMIT ?",
                [.integer(Int64(limit - projected))]
            ) { row in
                ready.append((zoneKey: row.text(0) ?? "", recordName: row.text(1) ?? ""))
            }
            guard !ready.isEmpty else { break }
            for item in ready {
                // One record that cannot be projected (a payload its projection refuses) must not
                // hold the others back: its writes are undone, and it waits for its parent to change
                // again.
                try store.exec("SAVEPOINT ck_reproject")
                do {
                    if let record = try store.replica.record(zoneKey: item.zoneKey, recordName: item.recordName) {
                        try project(record)
                    } else {
                        try clearWaits(zoneKey: item.zoneKey, recordName: item.recordName)
                    }
                    try store.exec("RELEASE ck_reproject")
                } catch {
                    try store.exec("ROLLBACK TO ck_reproject")
                    try store.exec("RELEASE ck_reproject")
                    try store.execute(
                        "UPDATE ck_unprojected SET ready = 0 WHERE zone_key = ? AND record_name = ?",
                        [.text(item.zoneKey), .text(item.recordName)]
                    )
                    store.logger.error("Could not project \(item.recordName, privacy: .public) again: \(error.localizedDescription, privacy: .public)")
                }
            }
            projected += ready.count
        }
        return projected
    }

    private func clearWaits(zoneKey: String, recordName: String) throws {
        try store.execute(
            "DELETE FROM ck_unprojected WHERE zone_key = ? AND record_name = ?",
            [.text(zoneKey), .text(recordName)]
        )
    }
}

extension KnowledgeStore {
    /// Notebooks the records whose parents arrived since, in an apply transaction of its own: run before
    /// each feeder pass, so a parent that came back by a local write (a re-import) brings its children
    /// back too (§5.7).
    @discardableResult
    func drainReadyProjections(_ registry: ProjectionRegistry = KnowledgeStore.projectionRegistry, limit: Int = 500) throws -> Int {
        guard syncGeneration == .two else { return 0 }
        guard try (scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_unprojected WHERE ready = 1)") ?? 0) != 0 else { return 0 }
        return try replica.apply { _ in
            try ProjectionApply(store: self, registry: registry).drainReady(limit: limit)
        }
    }
}

// MARK: - What an inbound apply changed, for the models that hold it in memory

/// What the inbound applies of one transaction wrote into the local rows or removed from them: the
/// record types, and the local ids of the Artifacts among them.
///
/// The view model, the day's model and the snapshot stores hold rows in memory and read them again only
/// when told. Generation 1's engine told them after each fetch (`cloudKitSyncRemoteStoreDidChange`, with
/// the entities it applied); under generation 2 nothing did until 2026-10-06, so a source's title and
/// author fixed on another device stayed wrong in the Mac's lists and over MCP until a relaunch, and the
/// next whole-source save of the stale copy (Refresh from Website, a read mark) would have written them
/// back and sent them out again. `ProjectionApply` notes each record it writes or removes, the store
/// hands the note on once the apply commits (`replicaApplyDidEnd`), and `AppliedRemoteChangesAnnouncer`
/// tells the surfaces, whichever path applied the records.
struct AppliedRemoteChanges: Equatable, Sendable {
    private(set) var types: Set<SyncRecordType> = []
    /// The Artifacts written or removed, by local id: an open Page reads its body again.
    private(set) var artifactIDs: Set<String> = []

    var isEmpty: Bool { types.isEmpty }

    mutating func note(_ type: SyncRecordType, localID: String) {
        types.insert(type)
        if type == .artifact { artifactIDs.insert(localID) }
    }

    mutating func formUnion(_ other: AppliedRemoteChanges) {
        types.formUnion(other.types)
        artifactIDs.formUnion(other.artifactIDs)
    }

    /// The entities the surfaces reload on, named as generation 1's engine names them.
    var entities: Set<CloudKitSyncEntity> {
        types.reduce(into: []) { $0.formUnion(Self.entities(for: $1)) }
    }

    /// Every entity whose rows a record type's projection writes, and every one a surface reads together
    /// with them: the source list reads the reading state, the hidden and following marks, and the title
    /// of the book, course, playlist or meeting a source is filed in. What generation 1 kept as
    /// preferences and generation 2 keeps as records (a notebook's sidebar state and ticks, a course's
    /// focus, a card's state) also names `.preference`, which reseeds the view model's copies. A type
    /// nothing on the Mac holds in memory names none. No `default`: a new record type decides here.
    static func entities(for type: SyncRecordType) -> Set<CloudKitSyncEntity> {
        switch type {
        case .source: return [.source, .meetingGroup]
        case .collection: return [.source, .book, .videoPlaylist, .meetingGroup]
        case .notebook, .goal: return [.learningGoal]
        case .entry: return [.learningGoal, .course, .source]
        case .course, .lesson: return [.course, .source]
        case .quiz: return [.course]
        case .enrollment: return [.course, .preference]
        case .chat, .exchange: return [.reviewSession]
        case .artifact: return [.artifact]
        case .comment: return [.artifactComment, .artifact]
        case .highlight: return [.sourceHighlight]
        case .readingState: return [.source, .walkthroughProgress]
        case .mark:
            return [.source, .hiddenSource, .hiddenPodcastShow, .hiddenYouTubeChannel, .hiddenArtifact, .hiddenReviewSession,
                    .dismissedSource, .sourceIdea, .videoCitedPaper, .videoPlaylist, .reviewSession]
        case .notebookState: return [.preference]
        case .placement: return [.scheduledSource]
        case .card: return [.memoryItem, .preference]
        case .sitting: return [.memoryAttempt, .dayPlan]
        case .activityLog: return [.memoryReviewActivity, .scheduledSource]
        case .idea: return [.idea]
        case .task: return [.notebookTask, .shareRequest]
        case .automation: return [.scheduledTask]
        case .setting: return [.preference]
        case .zoneRoot: return [.team]
        case .practice, .job, .device, .content: return []
        }
    }
}
