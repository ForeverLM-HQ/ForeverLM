import Foundation

/// A space's local rows on the Mac (docs/cloudkit-schema-design.md §4.3, §9.3, §13.7): which local
/// team id they carry in `team_id`, which wire id and zone each one's record has (`wire_id`,
/// `ck_identity`), and what goes when the space goes. Everything here is synchronous SQL on the
/// store's connection, run where the store belongs, under generation 2 only.
///
/// A space's records keep their logical ids. Their local rows keep theirs too, except where a row of
/// another zone holds the id already: a space's copy of a source is `SpaceLocalID`'s (WP7), and so
/// is a source a team copied under generation 1 (its `TeamContentIdentity` id). An Entry is named by
/// its notebook's and its source's wire ids, so an Entry of a space notebook maps
/// `en:<notebook>:source:<source's local id>` to `en:<notebook>:source:<source's wire id>`.
enum SpaceRows {
    /// The tables a space's local rows live in with the space's local team id in `team_id`, with the
    /// record type each row feeds. A Goal row of a team stays local: Goals are private (§3.5.7).
    static let recordTables: [(table: String, type: SyncRecordType, condition: String)] = [
        ("learning_goals", .notebook, "COALESCE(entity_kind, '') <> 'goal'"),
        ("review_sessions", .chat, "1"),
        ("global_artifacts", .artifact, "1"),
        ("courses", .course, "1"),
    ]

    // MARK: - Local team ids

    /// The id a space's local rows carry in `team_id`: the `teams` row that mirrors a team or family
    /// space (a team from generation 1 keeps its id, §13.7), else the space id itself.
    static func localTeamID(spaceID: String, connection: SQLiteConnection) throws -> String {
        try connection.scalarText(
            "SELECT id FROM teams WHERE zone_name = ? OR id = ? ORDER BY zone_name = ? DESC, id LIMIT 1",
            [.text(SyncSchema.spaceZonePrefix + spaceID), .text(spaceID), .text(SyncSchema.spaceZonePrefix + spaceID)]
        ) ?? spaceID
    }

    /// The zone each team's rows live in, by team id (`KnowledgeStore.teamZoneKeys`, WP7): the space the
    /// `teams` row names once the team is one, else `Space-<team id>` (lowercased when it is a UUID), in
    /// the private database for a team this Mac owns and in its owner's shared one otherwise.
    static func teamZoneKeys(_ connection: SQLiteConnection) throws -> [String: String] {
        var keys: [String: String] = [:]
        try connection.query("SELECT id, role, zone_owner_record_name, zone_name FROM teams", []) { row in
            guard let teamID = row.text(0) else { return }
            let spaceID = UUID(uuidString: teamID).map { $0.uuidString.lowercased() } ?? teamID
            let held = row.text(3).flatMap { $0.hasPrefix(SyncSchema.spaceZonePrefix) ? $0 : nil }
            let zoneName = held ?? SyncSchema.spaceZonePrefix + spaceID
            keys[teamID] = row.text(1) == "owner"
                ? ReplicaZone.key(database: .private, zoneName: zoneName)
                : ReplicaZone.key(database: .shared, zoneName: zoneName, ownerRecordName: row.text(2))
        }
        return keys
    }

    /// The space a generation-1 team becomes (§13.7 step 1): the team id when it is a UUID
    /// (lowercased), else the space the team's `teams` row already names.
    static func spaceID(teamID: String, connection: SQLiteConnection) throws -> String? {
        if let zone = try connection.scalarText("SELECT zone_name FROM teams WHERE id = ?", [.text(teamID)]),
           zone.hasPrefix(SyncSchema.spaceZonePrefix) {
            return String(zone.dropFirst(SyncSchema.spaceZonePrefix.count))
        }
        return UUID(uuidString: teamID).map { $0.uuidString.lowercased() }
    }

    /// Where an inbound record of a space lands locally: the local team id its row carries, and its
    /// local id, recorded in `ck_identity`. The id `ck_identity` holds wins; else the wire id, unless a
    /// row of `table` outside this space holds it, when the copy takes `SpaceLocalID`'s (§4.3). Nil for
    /// a record of the personal library.
    static func placement(of record: ProjectionRecordRef, table: String, connection: SQLiteConnection) throws -> (localID: String, teamID: String)? {
        guard case .space(let spaceID) = record.zone else { return nil }
        let teamID = try localTeamID(spaceID: spaceID, connection: connection)
        var localID = record.localID
        if localID == record.wireID, try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ? AND team_id IS NOT ?)", [.text(localID), .text(teamID)]
        ) == 1, try !SpaceMoveLocal.adopt(table: table, localID: localID, spaceID: spaceID, teamID: teamID, connection: connection) {
            // A notebook moving or moved here from the learner's own library keeps its row (WP15b).
            localID = SpaceLocalID.localID(spaceID: spaceID, type: record.type, wireID: record.wireID)
        }
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(record.zoneKey), .text(record.type.rawValue), .text(record.wireID), .text(localID)])
        return (localID, teamID)
    }

    /// The local id of a record a space holds, as its identity names it; nil when this Mac has none.
    static func localID(zoneKey: String, type: SyncRecordType, wireID: String, connection: SQLiteConnection) throws -> String? {
        try connection.scalarText(
            "SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(zoneKey), .text(type.rawValue), .text(wireID)]
        )
    }

    // MARK: - Wire ids and identities

    /// Gives every local row of the team `teamID` its wire id and its `ck_identity` row in `zoneKey`:
    /// sources (a team copy's wire id is the canonical personal id, §13.7 step 3), notebooks, chats and
    /// their exchanges, Docs and their comments, courses and their children, tasks, and the Entries of
    /// the team's notebooks. Idempotent; run after any write that adds rows to a space outside the
    /// projections (a copy into a space, the team's migration) and by `keepNotebookRowsForGeneration2`.
    static func adopt(teamID: String, zoneKey: String, connection: SQLiteConnection) throws {
        try canonicalizeSourceWireIDs(teamID: teamID, connection: connection)
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
            SELECT ?, 'Source', wire_key, id FROM sources WHERE team_id = ?
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(zoneKey), .text(teamID)])
        for (table, type, condition) in recordTables {
            try connection.execute("UPDATE \(table) SET wire_id = id WHERE team_id = ? AND wire_id IS NULL", [.text(teamID)])
            try connection.execute("""
                INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
                SELECT ?, ?, wire_key, id FROM \(table) WHERE team_id = ? AND \(condition)
                ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
            """, [.text(zoneKey), .text(type.rawValue), .text(teamID)])
        }
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
            SELECT ?, 'Exchange', e.id, e.id FROM review_exchanges e JOIN review_sessions r ON r.id = e.session_id WHERE r.team_id = ?
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(zoneKey), .text(teamID)])
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
            SELECT ?, 'Comment', c.id, c.id FROM artifact_comments c JOIN global_artifacts a ON a.id = c.artifact_id WHERE a.team_id = ?
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(zoneKey), .text(teamID)])
        try recordEntryIdentities(where: "g.team_id = ?", [.text(teamID)], zoneKey: zoneKey, connection: connection)
        let zones = [teamID: zoneKey]
        try TaskUpkeep.recordTeamIdentities(teamZones: zones, connection: connection)
        var courses: [String] = []
        try connection.query("SELECT id FROM courses WHERE team_id = ?", [.text(teamID)]) { row in
            if let id = row.text(0) { courses.append(id) }
        }
        for course in courses {
            try CourseUpkeep.recordTeamIdentities(courseID: course, teamZones: zones, connection: connection)
        }
    }

    /// The Entries of the space notebooks `notebookIDs` (local ids), after a write to their pools: each
    /// pool item's Entry is named by the notebook's and the source's wire ids (§4.3), in the zone the
    /// notebook's identity names, else its team's.
    static func recordEntryIdentities(notebookIDs: [String], teamZones: [String: String], connection: SQLiteConnection) throws {
        for notebookID in Set(notebookIDs).sorted() {
            guard let team = try connection.scalarText("SELECT team_id FROM learning_goals WHERE id = ?", [.text(notebookID)]) else { continue }
            let held = try connection.scalarText(
                "SELECT zone_key FROM ck_identity WHERE record_type = 'Notebook' AND local_id = ? ORDER BY zone_key LIMIT 1", [.text(notebookID)]
            )
            guard let zoneKey = held ?? teamZones[team] else { continue }
            try canonicalizeSourceWireIDs(teamID: team, connection: connection)
            try connection.execute("""
                INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
                SELECT ?, 'Source', s.wire_key, s.id FROM sources s JOIN learning_goal_items i ON i.source_id = s.id
                WHERE i.goal_id = ? AND s.team_id = ?
                ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
            """, [.text(zoneKey), .text(notebookID), .text(team)])
            try recordEntryIdentities(where: "g.id = ?", [.text(notebookID)], zoneKey: zoneKey, connection: connection)
        }
    }

    /// Before each send: a space notebook's pool items written by a path that keeps no identities (a
    /// seed-source add, an import's filing) get their Entry's, and their sources theirs, so no Entry of
    /// a space is ever named by a local id. Bounded by the space notebooks' pools.
    static func recordMissingIdentities(connection: SQLiteConnection) throws {
        var notebooks: [String] = []
        try connection.query("""
            SELECT DISTINCT i.goal_id FROM learning_goal_items i JOIN learning_goals g ON g.id = i.goal_id
            WHERE g.team_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM ck_identity e WHERE e.record_type = 'Entry' AND e.local_id = 'en:' || i.goal_id || ':source:' || i.source_id
            )
        """, []) { row in
            if let id = row.text(0) { notebooks.append(id) }
        }
        guard !notebooks.isEmpty else { return }
        try recordEntryIdentities(notebookIDs: notebooks, teamZones: try teamZoneKeys(connection), connection: connection)
    }

    private static func recordEntryIdentities(where condition: String, _ parameters: [SQLiteValue], zoneKey: String, connection: SQLiteConnection) throws {
        // An Entry named before its source had its wire id keeps one identity, under the wire id it has now.
        try connection.execute("""
            DELETE FROM ck_identity WHERE zone_key = ? AND record_type = 'Entry' AND local_id IN (
                SELECT 'en:' || i.goal_id || ':source:' || i.source_id
                FROM learning_goal_items i JOIN learning_goals g ON g.id = i.goal_id JOIN sources s ON s.id = i.source_id
                WHERE \(condition)
            ) AND wire_id NOT IN (
                SELECT 'en:' || g.wire_key || ':source:' || s.wire_key
                FROM learning_goal_items i JOIN learning_goals g ON g.id = i.goal_id JOIN sources s ON s.id = i.source_id
                WHERE \(condition)
            )
        """, [.text(zoneKey)] + parameters + parameters)
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
            SELECT ?, 'Entry', 'en:' || g.wire_key || ':source:' || s.wire_key, 'en:' || i.goal_id || ':source:' || i.source_id
            FROM learning_goal_items i JOIN learning_goals g ON g.id = i.goal_id JOIN sources s ON s.id = i.source_id
            WHERE \(condition) AND COALESCE(g.entity_kind, '') <> 'goal'
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(zoneKey)] + parameters)
    }

    /// A team copy of a source made since the activation has no wire id yet: it takes the canonical
    /// personal id, the personal source with the same address, else that address's stable id (§13.7
    /// step 3, the rule of `deriveWireIDs`).
    private static func canonicalizeSourceWireIDs(teamID: String, connection: SQLiteConnection) throws {
        var copies: [(id: String, normalized: String?)] = []
        try connection.query("""
            SELECT s.id, \(KnowledgeStore.subtypeCoalesce("normalized_url")) FROM sources s \(KnowledgeStore.subtypeJoins)
            WHERE s.team_id = ? AND s.wire_id IS NULL
        """, [.text(teamID)]) { row in
            if let id = row.text(0) { copies.append((id, row.text(1))) }
        }
        for copy in copies {
            var wireID = copy.id
            if let normalized = copy.normalized, !normalized.isEmpty {
                wireID = try connection.scalarText("""
                    SELECT s.id FROM sources s \(KnowledgeStore.subtypeJoins)
                    WHERE s.team_id IS NULL AND \(KnowledgeStore.subtypeCoalesce("normalized_url")) = ? ORDER BY s.id LIMIT 1
                """, [.text(normalized)]) ?? SyncIdentity.sourceID(normalizedURL: normalized)
            }
            try connection.execute("UPDATE sources SET wire_id = ? WHERE id = ?", [.text(wireID), .text(copy.id)])
        }
    }

    /// Moves every `ck_identity` row of one zone to another: a team's provisional zone (§13.7, WP7) to
    /// the space it became, or a joined team's old-container owner name to the new container's, which
    /// names users differently. A row the target already holds stays as the target holds it.
    static func rehome(from oldZoneKey: String, to newZoneKey: String, connection: SQLiteConnection) throws {
        guard oldZoneKey != newZoneKey else { return }
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id)
            SELECT ?, record_type, wire_id, local_id FROM ck_identity WHERE zone_key = ?
            ON CONFLICT(zone_key, record_type, wire_id) DO NOTHING
        """, [.text(newZoneKey), .text(oldZoneKey)])
        try connection.execute("DELETE FROM ck_identity WHERE zone_key = ?", [.text(oldZoneKey)])
    }

    // MARK: - A space that goes

    /// What deleting a space destroys, for the owner's confirmation (§9.6): its local rows by kind.
    static func counts(teamID: String, connection: SQLiteConnection) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for (key, sql) in [
            ("sources", "SELECT COUNT(*) FROM sources WHERE team_id = ?"),
            ("notebooks", "SELECT COUNT(*) FROM learning_goals WHERE team_id = ? AND COALESCE(entity_kind, '') <> 'goal'"),
            ("chats", "SELECT COUNT(*) FROM review_sessions WHERE team_id = ?"),
            ("docs", "SELECT COUNT(*) FROM global_artifacts WHERE team_id = ?"),
            ("courses", "SELECT COUNT(*) FROM courses WHERE team_id = ?"),
            ("tasks", "SELECT COUNT(*) FROM notebook_tasks WHERE team_id = ?"),
        ] {
            counts[key] = Int(try connection.scalarInteger(sql, [.text(teamID)]) ?? 0)
        }
        return counts
    }

    /// Removes a space's local rows, its identities and its `teams` mirror. Runs under the apply guard
    /// (the caller's `ReplicaStore.apply`), so nothing it deletes is sent: the space is gone on the
    /// server already, and per-member state keyed by wire id (reading, highlights, cards) stays (D18).
    static func purge(teamID: String, zoneKey: String, connection: SQLiteConnection) throws {
        for table in ["sources", "learning_goals", "review_sessions", "global_artifacts", "courses", "notebook_tasks", "share_requests"] {
            try connection.execute("DELETE FROM \(table) WHERE team_id = ?", [.text(teamID)])
        }
        try connection.execute("DELETE FROM ck_identity WHERE zone_key = ?", [.text(zoneKey)])
        try connection.execute("DELETE FROM teams WHERE id = ?", [.text(teamID)])
    }

    // MARK: - Deleting inside a space (§9.2)

    /// Whether this member may delete a space's Notebook, Artifact, Course or Chat: the space's owner
    /// may, and so may the record's `createdBy`; a read-only member never may. Personal rows are always
    /// this learner's to delete. A client rule (CloudKit has no per-record permissions, §9.2), checked
    /// before anything is written, as `SpaceWriteGuard` checks the send.
    static func mayDelete(type: SyncRecordType, localID: String, user: String?, connection: SQLiteConnection) throws -> Bool {
        guard let zoneKey = try connection.scalarText(
            "SELECT zone_key FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key LIMIT 1", [.text(type.rawValue), .text(localID)]
        ), ProjectionZones.zone(ofKey: zoneKey)?.isSpace == true, let zone = try ReplicaStore(connection: connection).zone(key: zoneKey) else {
            return true
        }
        if zone.permission == CloudShare.Permission.readOnly.rawValue { return false }
        if zone.role == "owner" || zone.database == .private { return true }
        guard [.notebook, .artifact, .course, .chat].contains(type) else { return true }
        let wireID = try connection.scalarText(
            "SELECT wire_id FROM ck_identity WHERE zone_key = ? AND record_type = ? AND local_id = ?",
            [.text(zoneKey), .text(type.rawValue), .text(localID)]
        ) ?? localID
        guard let held = try ReplicaStore(connection: connection).record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID) else {
            // Not on the server yet: this member made it here and has not sent it.
            return true
        }
        let createdBy = (try? SyncEnvelope(storedPayload: held.payload))?.fields["createdBy"].flatMap(SyncPerson.init(json:))
        // A store that does not know its account yet cannot tell; CloudKit's own roles still hold.
        guard let user else { return true }
        return createdBy?.user == user
    }
}

extension KnowledgeStore {
    /// Refuses, under generation 2, a delete of a space's Notebook, Artifact or Chat by a member who is
    /// neither the space's owner nor the record's `createdBy` (§9.2); others archive instead.
    func requireSpaceDeletion(_ type: SyncRecordType, _ localID: String) throws {
        let user = try replica.engineState(ReplicaStore.EngineScope.account).map { String(decoding: $0, as: UTF8.self) }
        guard try SpaceRows.mayDelete(type: type, localID: localID, user: user, connection: self) else {
            throw KnowledgeStoreError.invalidData("Only the space's owner, or whoever made it, can delete this. Archive it instead.")
        }
    }
}
