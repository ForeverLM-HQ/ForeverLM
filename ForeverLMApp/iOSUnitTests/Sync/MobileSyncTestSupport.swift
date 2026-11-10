import CloudKit
import Foundation
@testable import ForeverLM

/// Records as other devices wrote them, for the iPhone's sync suites (docs/cloudkit-schema-design.md
/// §14.2 WP19): payloads stamped by a device that is not the phone, named for a zone's salt.
enum MobileSyncFixture {
    static let librarySalt = Data(repeating: 3, count: 32)
    static let spaceSalt = Data(repeating: 7, count: 32)
    static let stampMilliseconds: Int64 = 1_759_400_000_000

    /// An envelope of `type` and `id` holding `fields`; a map or set field is given as an object, each
    /// key its own element.
    static func envelope(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], salt: Data = librarySalt,
                         at milliseconds: Int64 = stampMilliseconds, device: String = "otheraaa") throws -> SyncEnvelope {
        var envelope = SyncEnvelope.new(type, id: id, saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields {
            switch type.spec.field(field)?.kind {
            case .map?, .set?:
                patch.changes[field] = .elements(value.objectValue ?? [:])
            default:
                patch.changes[field] = .value(value)
            }
        }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: device)
        }
        return envelope
    }

    static func payload(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], salt: Data = librarySalt,
                        at milliseconds: Int64 = stampMilliseconds) throws -> Data {
        try envelope(type, id, fields, salt: salt, at: milliseconds).storedPayload()
    }

    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], in zone: CloudZoneID,
                       salt: Data = librarySalt, at milliseconds: Int64 = stampMilliseconds) throws -> CloudRecord {
        CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: type, id: id, salt: salt), in: zone), recordType: type.rawValue,
                    encryptedFields: [CloudRecord.payloadKey: .bytes(try payload(type, id, fields, salt: salt, at: milliseconds))])
    }

    static func rootRecord(_ fields: [String: SyncJSON], salt: Data, in zone: CloudZoneID) throws -> CloudRecord {
        var all = fields
        all["salt"] = .string(salt.base64EncodedString())
        all["saltID"] = .string(RecordNaming.saltID(salt))
        all["createdAt"] = SyncJSON(stampMilliseconds)
        all["editedAt"] = SyncJSON(stampMilliseconds)
        all["minClientRevision"] = SyncJSON(1)
        let root = try envelope(.zoneRoot, SyncSchema.rootRecordName, all, salt: salt)
        return CloudRecord(id: CloudRecordID(SyncSchema.rootRecordName, in: zone), recordType: SyncRecordType.zoneRoot.rawValue,
                           encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])
    }

    /// `owner`'s private library as a Mac seeded it: the three zones and a root whose seed has its
    /// metadata in (§13.4), so the phone adopts it.
    static func makeLibrary(_ server: FakeCloudKit, owner: String, salt: Data = librarySalt) throws {
        for zone in PrivateSyncZones.all { server.put([], zone: zone.zoneName, owner: owner) }
        let seed: SyncJSON = .object(["state": .string("complete"), "metadataCompleteAt": SyncJSON(stampMilliseconds)])
        server.put([try rootRecord(["kind": .string("personal"), "seed": seed], salt: salt, in: PrivateSyncZones.library)],
                   zone: SyncZone.library.rawValue, owner: owner)
    }

    /// `owner`'s space `zoneName` with its root, as SpaceService makes it (§2.4).
    static func makeSpace(_ server: FakeCloudKit, owner: String, zoneName: String = "Space-s1", kind: String = "team",
                          name: String, primaryID: String? = nil, salt: Data = spaceSalt) throws {
        var fields: [String: SyncJSON] = [
            "kind": .string(kind), "name": .string(name), "owner": SyncPerson(user: owner, name: "Alice Owner").value,
        ]
        if let primaryID { fields["primaryID"] = .string(primaryID) }
        server.put([try rootRecord(fields, salt: salt, in: CloudZoneID(zoneName))], zone: zoneName, owner: owner)
    }

    /// A FileRef to one inline part, as a pointer to a satellite whose bytes the phone never needs to
    /// show the record.
    static func fileRef(owner: String, role: String, bytes: Data) -> FileRef {
        FileRef(owner: owner, role: role, hash: "00", size: Int64(bytes.count), mime: "application/pdf", encoding: "identity", storedParts: [bytes])
    }

    /// Writes records straight into a replica, each applied and projected as an inbound record is.
    static func apply(_ records: [(zoneKey: String, envelope: SyncEnvelope)], to replica: MobileReplica, salt: Data = librarySalt) async throws {
        let rows = try records.map { item in
            ReplicaRecord(zoneKey: item.zoneKey,
                          recordName: RecordNaming.recordName(type: SyncRecordType(rawValue: item.envelope.type)!, id: item.envelope.id, salt: salt),
                          recordType: item.envelope.type, wireID: item.envelope.id, systemFields: nil,
                          payload: try item.envelope.storedPayload(), seenPass: nil)
        }
        try await replica.perform { state in
            try state.replica.apply { replica in
                for row in rows {
                    try replica.upsertRecord(row)
                    try state.project(row)
                }
            }
        }
    }

    /// A space the replica holds, as SpaceSync records it: its zone row and its root.
    static func holdSpace(_ replica: MobileReplica, zoneKey: String, zoneName: String, owned: Bool, name: String, kind: String = "team",
                          permission: String = "readWrite", salt: Data = spaceSalt) async throws {
        let root = try rootRecord(["kind": .string(kind), "name": .string(name), "owner": SyncPerson(user: "alice", name: "Alice Owner").value],
                                  salt: salt, in: CloudZoneID(zoneName))
        try await replica.perform { state in
            try state.replica.upsertZone(ReplicaZone(zoneKey: zoneKey, database: owned ? .private : .shared, zoneName: zoneName,
                                                     ownerRecordName: owned ? nil : "alice", kind: "space", role: owned ? "owner" : "member",
                                                     permission: permission, saltID: RecordNaming.saltID(salt)))
            try state.replica.upsertRecord(ReplicaRecord(root, zoneKey: zoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil))
        }
    }
}

/// Passes calls through to a transport and keeps the desired keys of every fetch, so a suite can show
/// that no satellite's `data` or `asset` was asked for.
final class MobileRecordingTransport: CloudTransport, @unchecked Sendable {
    let inner: CloudTransport
    private let lock = NSLock()
    private var zoneKeys: [(zone: String, keys: [String]?)] = []
    private var recordKeys: [[String]?] = []
    private var namesFetched: [String] = []

    init(_ inner: CloudTransport) { self.inner = inner }

    /// Each zone-changes request's zone and desired keys.
    var zoneChangeKeys: [(zone: String, keys: [String]?)] { lock.withLock { zoneKeys } }
    var recordFetchKeys: [[String]?] { lock.withLock { recordKeys } }
    var recordNamesFetched: [String] { lock.withLock { namesFetched } }

    var containerIdentifier: String { inner.containerIdentifier }
    func accountStatus() async throws -> CKAccountStatus { try await inner.accountStatus() }
    func userRecordName() async throws -> String { try await inner.userRecordName() }
    func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] { try await inner.allZones(in: database) }
    func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
        try await inner.modifyZones(saving: saving, deleting: deleting, in: database)
    }
    func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
        try await inner.databaseChanges(in: database, since: token, resultsLimit: resultsLimit)
    }
    func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
        lock.withLock { zoneKeys += requests.map { ($0.zoneID.zoneName, $0.desiredKeys) } }
        return try await inner.zoneChanges(requests, in: database)
    }
    func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
        lock.withLock {
            recordKeys.append(desiredKeys)
            namesFetched += ids.map(\.recordName)
        }
        return try await inner.records(ids, in: database, desiredKeys: desiredKeys)
    }
    func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                       savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
        try await inner.modifyRecords(saving: saving, deleting: deleting, in: database, savePolicy: savePolicy, atomically: atomically)
    }
}

/// An iPhone on FakeCloudKit: its replica (in memory unless a path is given), the private engine and
/// SpaceSync over it, as `MobileSyncSession` wires them with the system's CloudKit, and the query
/// layer the screens read.
final class MobileTestDevice {
    let server: FakeCloudKit
    let replica: MobileReplica
    let projection: MobileProjection
    let transport: CloudTransport
    let engine: PrivateSyncEngine
    let spaces: SpaceSync
    let deviceID: String

    init(_ server: FakeCloudKit, user: String, name: String = "phone", deviceID: String = "phoneaaa",
         path: String = ":memory:", transport: CloudTransport? = nil) throws {
        self.server = server
        self.deviceID = deviceID
        replica = try MobileReplica(path: path)
        projection = MobileProjection(replica: replica)
        self.transport = transport ?? server.transport(user: user, device: name)
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let moveMaps = MoveMapIndex()
        engine = PrivateSyncEngine(transport: self.transport, store: replica, pacer: pacer, moveMaps: moveMaps, deviceID: deviceID)
        spaces = SpaceSync(transport: self.transport, store: replica, moveMaps: moveMaps, deviceID: deviceID, pacer: { _ in pacer })
    }

    /// The phone's bootstrap: it adopts the library a Mac seeded.
    @discardableResult
    func bootstrap() async throws -> ZoneBootstrap.Outcome {
        Self.follow(server)
        return try await ZoneBootstrap(transport: transport, store: replica, client: .phone, deviceID: deviceID).run()
    }

    /// One round as the session runs it: the private engine, then the spaces, then the index sweep
    /// when the stop or the gone spaces moved.
    func sync() async throws {
        Self.follow(server)
        try await engine.sync()
        try await spaces.sync()
        _ = try await replica.read { try $0.sweepIndexIfNeeded() }
    }

    func count(_ sql: String, _ parameters: [SQLiteValue] = []) async throws -> Int {
        try await replica.read { Int(try $0.connection.scalarInteger(sql, parameters) ?? -1) }
    }

    func text(_ sql: String, _ parameters: [SQLiteValue] = []) async throws -> String? {
        try await replica.read { try $0.connection.scalarText(sql, parameters) }
    }

    /// Moves the server's clock up to the wall clock, so the phone's server offset is sound.
    static func follow(_ server: FakeCloudKit) {
        let behind = Date().timeIntervalSince(server.now)
        if behind > 0 { server.advance(by: behind) }
    }
}
