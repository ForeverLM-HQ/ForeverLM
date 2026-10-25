import Foundation
import OSLog

/// Teams become spaces (docs/cloudkit-schema-design.md §13.7), on the owner's Mac: each team this Mac
/// owns gets `Space-<team id>` (the team id when it is a UUID, else a new UUIDv4 the team's row then
/// names), a root of kind `team`, or `family` with its plan code and Assignments notebook, its rows'
/// wire ids and identities in that zone (a team copy of a source goes by its canonical personal id,
/// so the member's own state applies to it at once), and its zone-wide share. Once the zone has its
/// root, the feeder sends what it held for the team's copies: the team notebook with its Entries and
/// their approval states (b2), its chats, which the classifier makes `transcript` (D50), its Docs and
/// its courses.
///
/// WP16's seeder runs it as P6 after the seed manifest is written (R6-m7): every record of the space
/// is listed in `ck_manifest_pending` under `passKey`, so the delta writer lists it once acknowledged.
/// It is resumable: a team whose space exists is adopted again (its root by its kind, its rows
/// idempotently), and a team marked done is skipped. A member's Mac needs no pass of its own: its
/// identities move to the new container's owner name when it joins the space (`SpaceService`).
/// Generation 2 only.
struct TeamToSpace {
    /// `ck_engine_state` scope of a team's step: `done` once its space is shared.
    static func journal(_ teamID: String) -> String { "teamToSpace.\(teamID)" }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "TeamToSpace")

    let service: SpaceService
    /// The manifest delta's key for this pass, `<deviceID>.<passID>` (§3.5.1 `manifestDeltas`).
    let passKey: String
    var makeSpaceID: @Sendable () -> String = { UUID().uuidString.lowercased() }

    struct Team: Equatable, Sendable {
        let id: String
        let name: String
        let familyPlanCode: String?
    }

    /// What a run did, per team: the space it became and how many records it listed.
    struct Outcome: Equatable, Sendable {
        var spaces: [String: String] = [:]
        var listed: [String: Int] = [:]
    }

    /// Whether an owned team still needs its space made: it has no journal, or its journal is of an earlier
    /// library. A space is a zone in the container the library syncs with; when the library moves to a new
    /// container or is uploaded again, its zones are made anew and a team's space is not among them, so
    /// SpaceSync marks it gone and nothing the team holds is ever sent. That is told from a space the learner
    /// deleted by the library's zones being newer than the journal: a delete leaves them as they were.
    static func isOwed(teamID: String, in state: PrivateSyncLocalState) throws -> Bool {
        let replica = state.replica
        guard let journaled = try replica.engineStateUpdatedAt(journal(teamID)) else { return true }
        guard let libraryMadeAt = try replica.personalRoot()?.envelope.fields["createdAt"]?.int64Value,
              libraryMadeAt > SyncTime.milliseconds(journaled)
        else { return false }
        return try SpaceService.summaries(state.connection).contains { $0.localTeamID == teamID && $0.isOwned && $0.gone != nil }
    }

    /// Whether any team this Mac owns is owed its space (`isOwed`), for the round's cheap look.
    static func anyOwed(in state: PrivateSyncLocalState) throws -> Bool {
        try ownedTeams(in: state).contains { try isOwed(teamID: $0.id, in: state) }
    }

    private static func ownedTeams(in state: PrivateSyncLocalState) throws -> [Team] {
        var found: [Team] = []
        try state.connection.query("SELECT id, name, family_plan_code FROM teams WHERE role = 'owner' ORDER BY created_at, id", []) { row in
            if let id = row.text(0) { found.append(Team(id: id, name: row.text(1) ?? "", familyPlanCode: row.text(2))) }
        }
        return found
    }

    /// Runs every owned team that is owed its space (`isOwed`); `owner` is this account as the space roots
    /// name it.
    @discardableResult
    func run(owner: SyncPerson) async throws -> Outcome {
        let store = service.store
        let teams = try await store.perform { state -> [Team] in
            let owed = try Self.ownedTeams(in: state).filter { try Self.isOwed(teamID: $0.id, in: state) }
            // A stale journal goes now, so a run that stops after the zone is made is resumed as an unfinished one.
            for team in owed { try state.replica.setEngineState(Self.journal(team.id), nil) }
            return owed
        }
        var outcome = Outcome()
        for team in teams {
            let (spaceID, listed) = try await migrate(team, owner: owner)
            outcome.spaces[team.id] = spaceID
            outcome.listed[team.id] = listed
        }
        return outcome
    }

    private func migrate(_ team: Team, owner: SyncPerson) async throws -> (String, Int) {
        let store = service.store
        let newSpaceID = makeSpaceID()
        // Step 1: the space's id, and the team's provisional identities moved to its zone.
        let (spaceID, zoneKey, assignments) = try await store.perform { state -> (String, String, String?) in
            let connection = state.connection
            let before = try SpaceRows.teamZoneKeys(connection)[team.id]
            let spaceID = try SpaceRows.spaceID(teamID: team.id, connection: connection) ?? newSpaceID
            let zoneName = SyncSchema.spaceZonePrefix + spaceID
            try connection.execute(
                "UPDATE teams SET zone_scope = 'private', zone_name = ?, zone_owner_record_name = NULL WHERE id = ?",
                [.text(zoneName), .text(team.id)]
            )
            let zoneKey = ReplicaZone.key(database: .private, zoneName: zoneName)
            if let before { try SpaceRows.rehome(from: before, to: zoneKey, connection: connection) }
            let assignments = try connection.scalarText(
                "SELECT id FROM learning_goals WHERE id = ? AND team_id = ?",
                [.text(TeamContentIdentity.assignmentsNotebookID(teamID: team.id)), .text(team.id)]
            )
            return (spaceID, zoneKey, assignments)
        }

        // Step 1 continued: the zone and its root (adopted when an earlier run saved it).
        let isFamily = team.familyPlanCode != nil
        let held = try await service.list().first { $0.zone.zoneKey == zoneKey && $0.gone == nil }
        let space: SpaceSummary
        if let held, held.kind != nil {
            space = held
        } else {
            space = try await service.create(
                kind: isFamily ? "family" : "team", name: team.name, owner: owner,
                family: isFamily ? SpaceService.FamilyFields(planCode: team.familyPlanCode, assignmentsNotebookID: assignments) : nil,
                spaceID: spaceID, share: false
            )
        }

        // Steps 2 and 3: the team's rows under their wire ids in the space, each listed for the delta.
        let passKey = passKey
        let listed = try await store.perform { state -> Int in
            let connection = state.connection
            try SpaceRows.adopt(teamID: team.id, zoneKey: zoneKey, connection: connection)
            try connection.execute("""
                INSERT INTO ck_manifest_pending (pass_key, zone_key, record_type, wire_id)
                SELECT ?, zone_key, record_type, wire_id FROM ck_identity WHERE zone_key = ?
                ON CONFLICT DO NOTHING
            """, [.text(passKey), .text(zoneKey)])
            return Int(try connection.scalarInteger("SELECT COUNT(*) FROM ck_identity WHERE zone_key = ?", [.text(zoneKey)]) ?? 0)
        }

        // Step 4: the share; members accept its link (C14).
        let shared = try await service.shares.share(space.zone, title: team.name, publicPermission: CloudShare.Permission.none)
        try await store.perform { state in
            try state.connection.execute(
                "UPDATE teams SET share_record_name = ?, share_url = ? WHERE id = ?",
                [.text(CloudRecordID.zoneShareRecordName), .text(shared.url?.absoluteString), .text(team.id)]
            )
            try state.replica.setEngineState(Self.journal(team.id), Data("done".utf8))
        }
        try await service.mirrorTeams()
        Self.logger.info("A team became a space with \(listed) records")
        return (spaceID, listed)
    }
}
