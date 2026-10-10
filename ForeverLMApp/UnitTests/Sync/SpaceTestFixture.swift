import Foundation
import Testing
@testable import ForeverLM

/// Spaces for WP15's suites (docs/cloudkit-schema-design.md §2.4, §4.3, §9, §13.7): a Mac on FakeCloudKit
/// with the app's own projections and triggers, its SpaceSync, ShareService and SpaceService; a space the
/// replica holds as SpaceSync leaves one after a walk; a generation-1 team with its copies; and the
/// records another member's device sends into a space. It reads nothing but the store, the replica, the
/// feeder and the fake server, so the suites built on it also run standalone over the real sources.
enum SpaceTestFixture {
    typealias F = NotebookSyncFixture

    static let spaceSalt = Data(repeating: 7, count: 32)
    static var spaceSaltID: String { RecordNaming.saltID(spaceSalt) }

    /// A Mac of `user` with its spaces.
    final class Mac {
        let device: EngineTestDevice
        let spaces: SpaceSync
        let shares: ShareService
        var service: SpaceService
        let user: String

        init(_ server: FakeCloudKit, name: String, deviceID: String, user: String, holdsLibrary: Bool = true) async throws {
            self.user = user
            device = try EngineTestDevice(server, name: name, deviceID: deviceID, user: user, registry: KnowledgeStore.projectionRegistry)
            var pacing = SyncPacerState.Configuration()
            pacing.capacity = 1_000_000
            pacing.refillPerSecond = 1_000_000
            let pacer = SyncPacer(configuration: pacing)
            spaces = SpaceSync(transport: device.transport, store: device.local, moveMaps: MoveMapIndex(), deviceID: deviceID,
                               pacer: { _ in pacer }, clock: { Date().addingTimeInterval(EngineTestDevice.ahead) })
            shares = ShareService(transport: device.transport, store: device.local, spaces: spaces, accountName: name)
            service = SpaceService(transport: device.transport, store: device.local, spaces: spaces, shares: shares, deviceID: deviceID)
            service.makeSalt = { SpaceTestFixture.spaceSalt }
            try await device.bootstrap(holdsLibrary ? .macHoldingLibrary : .macWithoutLibrary, salt: user == "alice" ? 1 : 2)
        }

        var store: KnowledgeStore { device.store }
        var owner: SyncPerson { SyncPerson(user: user, name: user.capitalized) }

        /// SpaceSync's round: zones, walks, sends.
        func syncSpaces() async throws {
            EngineTestDriver.follow(device.server)
            try await spaces.sync()
        }

        /// The changes the feeder would hand SpaceSync now, by `<type>:<wire id>`.
        func pendingInSpaces() throws -> [String: OutboxChange] {
            let changes = try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60))
                .filter { $0.zone.isSpace }
            return Dictionary(changes.map { ("\($0.recordType.rawValue):\($0.wireID)", $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// A space the replica holds as SpaceSync leaves one after a walk: its zone row (owned, or joined
    /// under `owner` with `permission`) and its root with the space salt.
    @discardableResult
    static func holdSpace(_ store: KnowledgeStore, spaceID: String, kind: String = "team", name: String = "Lab", owner: String? = nil,
                          permission: String = "readWrite", primaryID: String? = nil) throws -> String {
        let zoneName = SyncSchema.spaceZonePrefix + spaceID
        let zoneKey = owner.map { ReplicaZone.key(database: .shared, zoneName: zoneName, ownerRecordName: $0) }
            ?? ReplicaZone.key(database: .private, zoneName: zoneName)
        try store.replica.upsertZone(ReplicaZone(
            zoneKey: zoneKey, database: owner == nil ? .private : .shared, zoneName: zoneName, ownerRecordName: owner, kind: "space",
            primaryID: primaryID, role: owner == nil ? "owner" : "member", permission: permission, saltID: spaceSaltID
        ))
        var fields: [String: SyncJSON] = [
            "kind": .string(kind), "salt": .string(spaceSalt.base64EncodedString()), "saltID": .string(spaceSaltID), "name": .string(name),
            "owner": SyncPerson(user: owner ?? "alice", name: "Alice").value,
        ]
        if let primaryID { fields["primaryID"] = .string(primaryID) }
        try store.replica.upsertRecord(try record(.zoneRoot, SyncSchema.rootRecordName, fields, zoneKey: zoneKey))
        return zoneKey
    }

    /// A record of a space as another member's device sends it, every field stamped at `ms`.
    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], zoneKey: String,
                       ms: Int64 = 1_759_400_000_000, device: String = "bobmacaa") throws -> ReplicaRecord {
        var envelope = SyncEnvelope.new(type, id: id, saltID: spaceSaltID)
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields {
            if let kind = type.spec.field(field)?.kind, kind != .scalar, let elements = value.objectValue {
                patch.changes[field] = .elements(elements)
            } else {
                patch.changes[field] = .value(value)
            }
        }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: ms, counter: counter, deviceID: device)
        }
        let name = type == .zoneRoot ? SyncSchema.rootRecordName : RecordNaming.recordName(type: type, id: id, salt: spaceSalt)
        return ReplicaRecord(zoneKey: zoneKey, recordName: name, recordType: type.rawValue, wireID: id, systemFields: Data([1]),
                             payload: try envelope.storedPayload(), seenPass: nil)
    }

    /// A Source record of a space, an article at `url`.
    static func sourceRecord(_ id: String, url: String, zoneKey: String) throws -> ReplicaRecord {
        try record(.source, id, [
            "type": .string("article"), "title": .string("Title \(id)"), "url": .string(url), "status": .string("active"),
            "addedAt": SyncJSON(Int64(1_759_000_000_000)), "ingest": .object(["ord": .array([SyncJSON(0), SyncJSON(1)]), "state": .string("queued")]),
        ], zoneKey: zoneKey)
    }

    /// A generation-1 team as `createTeam` and a share into it leave one: its row, and copies of sources
    /// under team-scoped ids (`TeamContentIdentity.sourceID`'s shape) with `team_id` set.
    static func addTeam(_ store: KnowledgeStore, _ teamID: String, name: String = "Lab", role: String = "owner",
                        ownerRecordName: String? = nil, familyPlanCode: String? = nil) throws {
        try store.execute("""
            INSERT INTO teams (id, name, role, permission, zone_scope, zone_name, zone_owner_record_name, created_at, joined_at, updated_at, family_plan_code)
            VALUES (?, ?, ?, 'readWrite', ?, ?, ?, 1, 1, 1, ?)
        """, [.text(teamID), .text(name), .text(role), .text(role == "owner" ? "private" : "shared"), .text("Team-\(teamID)"),
              .text(ownerRecordName), .text(familyPlanCode)])
    }

    /// A team's copy of an article: its own id, the team's id in `team_id`, and the original's address.
    static func addTeamSource(_ store: KnowledgeStore, _ id: String, teamID: String, url: String) throws {
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status, team_id) VALUES (?, 1, 'ready', 'article', 'active', ?)",
                          [.text(id), .text(teamID)])
        try store.execute("INSERT INTO articles (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, ?, 'example.com')",
                          [.text(id), .text(url), .text(URLNormalizer.normalize(url)), .text("Title \(id)")])
    }

    /// The learner's own article at `url`, under the address's stable id.
    @discardableResult
    static func addPersonalSource(_ store: KnowledgeStore, url: String) throws -> String {
        let id = SyncIdentity.sourceID(normalizedURL: URLNormalizer.normalize(url))
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status, wire_id) VALUES (?, 1, 'ready', 'article', 'active', ?)",
                          [.text(id), .text(id)])
        try store.execute("INSERT INTO articles (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, ?, 'example.com')",
                          [.text(id), .text(url), .text(URLNormalizer.normalize(url)), .text("Mine")])
        return id
    }
}
