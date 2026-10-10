import Foundation
@testable import ForeverLM

/// Records written straight into FakeCloudKit for the maintenance suites (WP17), as another of the
/// learner's devices would have written them: named and salted with the account's personal root, each
/// field stamped at `at` by `device`.
enum MaintenanceFixture {
    static let user = "alice"
    static let otherDevice = "otheraaa"

    /// An envelope of `type` and `id` holding `fields`, its fields stamped at `at` (epoch ms).
    static func envelope(_ type: SyncRecordType, _ id: String, _ fields: [String: RecordPatch.Change], saltID: String,
                         at milliseconds: Int64 = 1_759_400_000_000, device: String = otherDevice) throws -> SyncEnvelope {
        var envelope = SyncEnvelope.new(type, id: id, saltID: saltID)
        var counter = 0
        try envelope.apply(RecordPatch(type, id: id, changes: fields)) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: device)
        }
        return envelope
    }

    /// Writes a record of the personal library (`Library`, `Catalog`) into the server, named with the
    /// salt `device` holds. Returns the server's copy.
    @discardableResult
    static func put(_ device: EngineTestDevice, _ type: SyncRecordType, _ id: String, _ fields: [String: RecordPatch.Change],
                    zone: String = "Library", at milliseconds: Int64 = 1_759_400_000_000, salt: Data? = nil) throws -> CloudRecord {
        let salt = try salt ?? device.personalSalt() ?? Data()
        let envelope = try envelope(type, id, fields, saltID: RecordNaming.saltID(salt), at: milliseconds)
        let record = CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: type, id: id, salt: salt), in: CloudZoneID(zone)),
                                 recordType: type.rawValue, encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())])
        return device.server.put([record], zone: zone, owner: user)[0]
    }

    /// Changes fields of the personal root on the server, as another device's save would.
    static func patchRoot(_ server: FakeCloudKit, _ changes: [String: RecordPatch.Change], at milliseconds: Int64 = 1_759_500_000_000) throws {
        guard let held = server.storedRecord(SyncSchema.rootRecordName, zone: "Library", owner: user), let payload = held.payload else {
            throw CloudError(.unknownItem, message: "no root")
        }
        var envelope = try SyncEnvelope(storedPayload: payload)
        var counter = 0
        try envelope.apply(RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName, changes: changes)) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: otherDevice)
        }
        var record = CloudRecord(id: held.id, recordType: held.recordType)
        record.payload = try envelope.storedPayload()
        server.put([record], zone: "Library", owner: user)
    }

    /// The decoded envelope of a record the server holds by name.
    static func stored(_ server: FakeCloudKit, _ recordName: String, zone: String = "Library") throws -> SyncEnvelope? {
        guard let payload = server.storedRecord(recordName, zone: zone, owner: user)?.payload else { return nil }
        return try SyncEnvelope(storedPayload: payload)
    }

    static let utc = TimeZone(identifier: "UTC")!

    /// A Mac's maintenance service over its engine: `holdsLibrary` stands for its activation, the clock
    /// runs with the engine's, and `fetchToEnd` is the engine's own fetch.
    /// `fetch: false` stands for a fetch that reached the end but brought nothing new.
    static func service(_ device: EngineTestDevice, holdsLibrary: Bool = true, fetch: Bool = true,
                        clock: @escaping @Sendable () -> Date = { Date().addingTimeInterval(EngineTestDevice.ahead) }) -> MaintenanceService {
        let blobs = blobs(device, clock: clock)
        let engine = device.engine
        let server = device.server
        return MaintenanceService(
            transport: device.transport, store: device.local, blobs: blobs, moveMaps: MoveMapIndex(), deviceID: device.deviceID,
            description: MaintenanceDeviceDescription(appVersion: "1.0", appBuild: "180", displayName: device.name), timeZone: utc,
            holdsLibrary: { holdsLibrary },
            fetchToEnd: {
                guard fetch else { return true }
                EngineTestDriver.follow(server)
                try? await engine.fetchChanges()
                return await engine.unfetchedZones.isEmpty
            },
            clock: clock
        )
    }

    static func milliseconds(_ date: Date) -> Int64 { SyncTime.milliseconds(date) }

    /// The lease as the server's root holds it.
    static func lease(_ server: FakeCloudKit) throws -> MaintenanceLease.Holder? {
        try stored(server, SyncSchema.rootRecordName).flatMap(MaintenanceLease.holder(in:))
    }

    static func blobs(_ device: EngineTestDevice, clock: @escaping @Sendable () -> Date) -> BlobStore {
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        return BlobStore(transport: device.transport, store: device.local, deviceID: device.deviceID, pacer: { _ in pacer }, clock: clock)
    }

    /// The FileRef of a body cut into `parts` stored parts, none of them uploaded yet.
    static func body(_ text: String, owner: String, role: String = "body", parts: Int = 1) -> (file: FileRef, parts: [Data]) {
        let data = Data(text.utf8)
        let size = max(1, (data.count + parts - 1) / parts)
        let stored = FileRef.split(data, partSize: size)
        return (FileRef(owner: owner, role: role, hash: SyncIdentity.sha256Hex(data), size: Int64(data.count), mime: "text/markdown",
                        encoding: "identity", storedParts: stored), stored)
    }

    /// The satellite of one part, written straight into the server's `Content` zone (another device's
    /// upload), dated with the server's clock as it stands.
    static func putPart(_ device: EngineTestDevice, _ file: FileRef, _ part: Int, _ bytes: Data, ownerType: SyncRecordType = .artifact) throws {
        let salt = try device.personalSalt() ?? Data()
        let contentID = SyncIdentity.contentID(owner: file.owner, role: file.role, partHash32: file.parts[part])
        let envelope = try envelope(.content, contentID, [
            "ownerType": .value(.string(ownerType.rawValue)), "ownerID": .value(.string(file.owner)), "role": .value(.string(file.role)),
            "hash": .value(.string(file.hash)), "size": .value(SyncJSON(file.size ?? 0)), "mime": .value(.string(file.mime ?? "")),
            "enc": .value(.string("identity")), "part": .value(SyncJSON(part)), "parts": .value(SyncJSON(file.parts.count)),
            "partHash": .value(.string(SyncIdentity.sha256Hex(bytes))), "partBytes": .value(SyncJSON(bytes.count)),
            "personal": .value(.bool(false)), "createdAt": .value(SyncJSON(milliseconds(device.server.now))),
        ], saltID: RecordNaming.saltID(salt))
        let record = CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: .content, id: contentID, salt: salt), in: PrivateSyncZones.content),
                                 recordType: SyncRecordType.content.rawValue,
                                 encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload()), CloudRecord.dataKey: .bytes(bytes)])
        device.server.put([record], zone: "Content", owner: user)
    }

    /// The record names of a FileRef's satellites in the personal library.
    static func names(_ device: EngineTestDevice, _ file: FileRef) throws -> [String] {
        let salt = try device.personalSalt() ?? Data()
        return file.satelliteIDs.map { RecordNaming.recordName(type: .content, id: $0, salt: salt) }
    }

    static func onServer(_ device: EngineTestDevice, _ file: FileRef) throws -> Bool {
        try names(device, file).allSatisfy { device.server.storedRecord($0, zone: "Content", owner: user) != nil }
    }
}
