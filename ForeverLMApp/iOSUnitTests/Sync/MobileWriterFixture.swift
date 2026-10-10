import Foundation
@testable import ForeverLM

/// The phone's writer over a replica that holds the personal library (§14.2 WP20): its three zones and
/// root, a stamp clock that knows the server's time, and optionally a space; records other devices
/// wrote are applied to it as inbound records are.
enum MobileWriterFixture {
    static let deviceID = "phoneaaa"
    static let library = "private/Library"
    static let catalog = "private/Catalog"
    static let space = "private/Space-s1"
    static let joined = "shared/alice/Space-s2"

    static func replica(space spaceName: String? = "Acme Lab") async throws -> MobileReplica {
        let replica = try MobileReplica(path: ":memory:")
        let root = try MobileSyncFixture.rootRecord(["kind": .string("personal")], salt: MobileSyncFixture.librarySalt, in: PrivateSyncZones.library)
        try await replica.perform { state in
            for zone in PrivateSyncZones.all {
                try state.replica.upsertZone(ReplicaZone(zoneKey: PrivateSyncZones.key(zone), database: .private, zoneName: zone.zoneName,
                                                         kind: PrivateSyncZones.kind(zone), saltID: RecordNaming.saltID(MobileSyncFixture.librarySalt)))
            }
            try state.replica.upsertRecord(ReplicaRecord(root, zoneKey: library, wireID: SyncSchema.rootRecordName, seenPass: nil))
            try state.replica.recordServerTime(Date(), sentAt: Date(), deviceID: deviceID)
            try state.replica.setEngineState(ReplicaStore.EngineScope.account, Data("phoneuser".utf8))
        }
        if let spaceName {
            try await MobileSyncFixture.holdSpace(replica, zoneKey: space, zoneName: "Space-s1", owned: true, name: spaceName)
        }
        return replica
    }

    static func writer(_ replica: MobileReplica, at date: Date = Date(), blobs: BlobStore? = nil) -> MobileRecordWriter {
        MobileRecordWriter(replica: replica, deviceID: deviceID, blobs: blobs, clock: { date })
    }

    static func patch(_ replica: MobileReplica, _ type: SyncRecordType, _ id: String, in zoneKey: String) async throws -> PendingPatch? {
        try await replica.read { try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: id, in: $0.connection) }
    }

    static func held(_ replica: MobileReplica, _ type: SyncRecordType, _ id: String, in zoneKey: String) async throws -> SyncEnvelope? {
        try await replica.read { try MobileProjection.held(type, id, zoneKey: zoneKey, in: $0) }
    }

    static func patchCount(_ replica: MobileReplica) async throws -> Int {
        try await replica.read { Int(try $0.connection.scalarInteger("SELECT COUNT(*) FROM ck_patches") ?? -1) }
    }

    /// Every pending patch's (zone, type, id), sorted.
    static func patched(_ replica: MobileReplica) async throws -> [String] {
        try await replica.read { replica in
            var found: [String] = []
            try replica.connection.query("SELECT zone_key, record_type, wire_id FROM ck_patches ORDER BY zone_key, record_type, wire_id", []) {
                found.append("\($0.text(0) ?? "") \($0.text(1) ?? "") \($0.text(2) ?? "")")
            }
            return found
        }
    }

    /// Records other devices wrote, in the zone each names.
    static func apply(_ replica: MobileReplica, _ records: [(String, SyncEnvelope)]) async throws {
        for (zoneKey, envelope) in records {
            let salt = zoneKey.contains("Space-") ? MobileSyncFixture.spaceSalt : MobileSyncFixture.librarySalt
            try await MobileSyncFixture.apply([(zoneKey, envelope)], to: replica, salt: salt)
        }
    }

    /// The changes the phone would send at `now` (60 s from now by default, past every debounce).
    static func changes(_ replica: MobileReplica, scope: OutboxScope = .all, at now: Date = Date().addingTimeInterval(60)) async throws -> [OutboxChange] {
        try await replica.perform { try $0.nextChanges(now: now, limit: 1_000, scope: scope) }
    }

    static func string(_ envelope: SyncEnvelope?, _ field: String) -> String? {
        envelope?.fields[field]?.stringValue
    }
}
