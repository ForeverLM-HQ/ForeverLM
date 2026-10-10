import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Satellites by name (docs/cloudkit-schema-design.md §3.5.30, D10, D11, D41), on FakeCloudKit and a
/// replica-only store: parts, encodings, collisions, re-verification, hashes and the kept layout.
@Suite("Blob store", .serialized)
struct BlobStoreTests {
    static let salt = Data(repeating: 3, count: 32)
    static let zone = BlobZone.personal(salt: salt)
    static let megabytes120 = 120_000_000

    /// A clock a test moves by hand.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSinceReferenceDate: 812_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }

    /// A device with its own ledger (`ck_blobs`) and a BlobStore over FakeCloudKit.
    struct Device {
        let transport: FakeCloudKit.Transport
        let store: ReplicaOnlySyncStore
        let blobs: BlobStore
        let clock: Clock

        init(_ server: FakeCloudKit, name: String, configuration: BlobStore.Configuration = .native, clock: Clock = Clock()) async throws {
            transport = server.transport(user: "alice", device: name)
            let connection = try SQLiteHandle(path: ":memory:")
            try ReplicaStore(connection: connection).installSharedSchema()
            store = ReplicaOnlySyncStore(connection: connection)
            self.clock = clock
            var pacing = SyncPacerState.Configuration()
            pacing.capacity = 1_000_000
            pacing.refillPerSecond = 1_000_000
            let pacer = SyncPacer(configuration: pacing)
            blobs = BlobStore(transport: transport, store: store, deviceID: "macaaaaa", configuration: configuration,
                              pacer: { _ in pacer }, clock: { clock.now })
            _ = try await transport.modifyZones(saving: [PrivateSyncZones.content], deleting: [], in: .private)
        }

        func upload(_ body: Data, role: String = "pdf", encoding: BlobStore.Encoding = .identity, keeping existing: FileRef? = nil,
                    into zone: BlobZone = BlobStoreTests.zone) async throws -> FileRef {
            try await blobs.upload(body, owner: "src_one", ownerType: .source, role: role, mime: "application/pdf", encoding: encoding,
                                   into: zone, keeping: existing)
        }

        func ledger() async throws -> Int64 {
            try await store.perform { try $0.connection.scalarInteger("SELECT COUNT(*) FROM ck_blobs WHERE acked_at IS NOT NULL") ?? -1 }
        }
    }

    /// Bytes that do not repeat, so no two parts of a body share a name.
    static func body(_ count: Int, seed: UInt64) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            var state = seed
            for offset in stride(from: 0, to: count - count % 8, by: 8) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw.storeBytes(of: state, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }

    static let large = body(megabytes120, seed: 120)

    /// Small parts, so a several-part body costs little.
    static var smallParts: BlobStore.Configuration {
        var configuration = BlobStore.Configuration.native
        configuration.partBytes = 300 * 1024
        return configuration
    }

    static func name(_ contentID: String, salt: Data = salt) -> String {
        RecordNaming.recordName(type: .content, id: contentID, salt: salt)
    }

    static func saves(_ server: FakeCloudKit, by device: String) -> [FakeCloudKit.Call] {
        server.calls.filter { $0.operation == .modifyRecords && $0.device == device }
    }

    @Test("A 120 MB file goes up in parts of exactly 48 MiB, the last smaller, and comes back whole")
    func nativeParts() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac")
        let file = try await mac.upload(Self.large)
        #expect(file.parts.count == 3)
        #expect(!file.isInline)
        let sizes = file.satelliteIDs.compactMap { server.storedRecord(Self.name($0), zone: "Content", owner: "alice") }
            .compactMap { try? SyncEnvelope(storedPayload: $0.payload ?? Data()).fields["partBytes"]?.int64Value }
        #expect(sizes == [50_331_648, 50_331_648, Int64(Self.megabytes120 - 2 * 50_331_648)])
        #expect(Self.saves(server, by: "mac").allSatisfy { $0.recordNames.count <= 4 }, "at most 200 MB of assets in one request")
        let back = try await mac.blobs.fetch(file, from: Self.zone)
        #expect(back == Self.large)
        #expect(try await mac.ledger() == 3)
    }

    @Test("The web's layout cuts the same 120 MB file into 14 MiB parts")
    func webParts() async throws {
        let server = FakeCloudKit()
        let web = try await Device(server, name: "web", configuration: .web)
        let file = try await web.upload(Self.large)
        #expect(file.parts.count == 9)
        let first = try #require(server.storedRecord(Self.name(file.satelliteIDs[0]), zone: "Content", owner: "alice"))
        #expect(try SyncEnvelope(storedPayload: first.payload ?? Data()).fields["partBytes"]?.int64Value == 14_680_064)
        #expect(try await web.blobs.fetch(file, from: Self.zone) == Self.large)
    }

    @Test("A web upload and a Mac upload of the same 120 MB file never share a name, and each reads back its own bytes")
    func webAndMacNeverMix() async throws {
        let server = FakeCloudKit()
        let web = try await Device(server, name: "web", configuration: .web)
        let mac = try await Device(server, name: "mac")
        let fromWeb = try await web.upload(Self.large)
        let fromMac = try await mac.upload(Self.large)
        #expect(Set(fromWeb.satelliteIDs).isDisjoint(with: fromMac.satelliteIDs))
        #expect(server.recordNames(zone: "Content", owner: "alice").count == 12)
        #expect(try await mac.blobs.fetch(fromWeb, from: Self.zone) == Self.large)
        #expect(try await web.blobs.fetch(fromMac, from: Self.zone) == Self.large)
    }

    @Test("The replica's layout is kept when the local file's hash matches it: the Mac uploads nothing over a web upload")
    func replicaLayoutKept() async throws {
        let server = FakeCloudKit()
        let web = try await Device(server, name: "web", configuration: .web)
        let mac = try await Device(server, name: "mac")
        let fromWeb = try await web.upload(Self.large)
        let kept = try await mac.upload(Self.large, keeping: fromWeb)
        #expect(kept == fromWeb)
        #expect(Self.saves(server, by: "mac").isEmpty, "nothing uploaded again")
        #expect(try await mac.ledger() == 9, "the parts were looked up and are in this Mac's ledger")

        // A part the server lost is uploaded again under the same layout, and only that part.
        let other = server.transport(user: "alice", device: "other")
        _ = try await other.modifyRecords(deleting: [CloudRecordID(Self.name(fromWeb.satelliteIDs[4]), in: PrivateSyncZones.content)], in: .private)
        mac.clock.advance(25 * 3_600)
        server.resetCalls()
        let again = try await mac.upload(Self.large, keeping: fromWeb)
        #expect(again == fromWeb)
        #expect(Self.saves(server, by: "mac").flatMap(\.recordNames) == [Self.name(fromWeb.satelliteIDs[4])])

        // A body that changed gets a layout of its own.
        let changed = try await mac.upload(Self.body(400_000, seed: 9), keeping: fromWeb)
        #expect(changed != fromWeb)
    }

    @Test("gzip and identity of the same content are different satellites, and both decode to it")
    func gzipVersusIdentity() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac")
        let text = Data(String(repeating: "Mitochondria import most of their proteins. ", count: 9_000).utf8)
        let identity = try await mac.upload(text, role: "text", encoding: .identity)
        let gzip = try await mac.upload(text, role: "text", encoding: .gzip)
        #expect(identity.encoding == "identity")
        #expect(gzip.encoding == "gzip")
        #expect(gzip.isInline, "the compressed text stores in one inline satellite")
        #expect(!identity.isInline)
        #expect(identity.hash == gzip.hash)
        #expect(Set(identity.satelliteIDs).isDisjoint(with: gzip.satelliteIDs))
        #expect(try await mac.blobs.fetch(identity, from: Self.zone) == text)
        #expect(try await mac.blobs.fetch(gzip, from: Self.zone) == text)
        let stored = try #require(server.storedRecord(Self.name(gzip.satelliteIDs[0]), zone: "Content", owner: "alice"))
        #expect(try SyncEnvelope(storedPayload: stored.payload ?? Data()).fields["enc"] == .string("gzip"))
    }

    @Test("A fetch is by name only, and the existence check names the parts the server lost")
    func byNameAndExistence() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac", configuration: Self.smallParts)
        let body = Self.body(1_000_000, seed: 4)
        let file = try await mac.upload(body)
        #expect(file.parts.count == 4)
        server.resetCalls()
        #expect(try await mac.blobs.fetch(file, from: Self.zone) == body)
        #expect(server.calls.allSatisfy { $0.operation == .records }, "no change feed is ever read")
        #expect(try await mac.blobs.missing(file, in: Self.zone).isEmpty)
        let other = server.transport(user: "alice", device: "other")
        _ = try await other.modifyRecords(deleting: [CloudRecordID(Self.name(file.satelliteIDs[2]), in: PrivateSyncZones.content)], in: .private)
        #expect(try await mac.blobs.missing(file, in: Self.zone) == [file.satelliteIDs[2]])
        await #expect(throws: BlobStoreError.missingParts([file.satelliteIDs[2]])) { try await mac.blobs.fetch(file, from: Self.zone) }
    }

    @Test("A collision counts as success only once the stored satellite's part fields match")
    func collisionNeedsMatchingPayload() async throws {
        let server = FakeCloudKit()
        let first = try await Device(server, name: "first")
        let second = try await Device(server, name: "second")
        let body = Self.body(100_000, seed: 5)
        let file = try await first.upload(body)
        let name = Self.name(file.satelliteIDs[0])
        let tag = server.storedRecord(name, zone: "Content", owner: "alice")?.changeTag
        // Another device meets the same satellite: the payload matches, so it counts, unchanged.
        #expect(try await second.upload(body) == file)
        #expect(server.storedRecord(name, zone: "Content", owner: "alice")?.changeTag == tag)
        #expect(try await second.ledger() == 1)

        // A satellite under the name whose part fields say otherwise is never taken.
        let other = Self.body(100_000, seed: 6)
        let contentID = SyncIdentity.contentID(owner: "src_one", role: "pdf", partHash32: FileRef.partHash32(other))
        var envelope = SyncEnvelope.new(.content, id: contentID, saltID: RecordNaming.saltID(Self.salt))
        var patch = RecordPatch(.content, id: contentID)
        patch.changes["partHash"] = .value(.string(SyncIdentity.sha256Hex(other)))
        patch.changes["partBytes"] = .value(SyncJSON(99_999))
        patch.changes["enc"] = .value(.string("identity"))
        try envelope.apply(patch) { _, policy, _ in SyncStamp.provisional(policy, deviceID: "buggyaaa") }
        server.put([CloudRecord(id: CloudRecordID(Self.name(contentID), in: PrivateSyncZones.content), recordType: "Content",
                                encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload()), CloudRecord.dataKey: .bytes(other)])],
                   zone: "Content", owner: "alice")
        await #expect(throws: BlobStoreError.partMismatch(contentID: contentID)) { try await second.upload(other) }
        let parked = try await second.store.perform {
            try $0.connection.scalarText("SELECT reason FROM ck_quarantine WHERE record_name = ?", [.text(Self.name(contentID))])
        }
        #expect(parked == BlobStore.quarantineReason)
    }

    @Test("Bytes before pointer: an upload whose part fails gives no FileRef, and the retry sends only what is missing")
    func bytesBeforePointer() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac", configuration: Self.smallParts)
        let body = Self.body(700_000, seed: 7)
        let parts = FileRef.split(body, partSize: Self.smallParts.partBytes)
        let names = parts.map { Self.name(SyncIdentity.contentID(owner: "src_one", role: "pdf", partHash32: FileRef.partHash32($0))) }
        server.failRecord(names[1], with: CloudError(.serverRejectedRequest))
        await #expect(throws: BlobStoreError.self) { try await mac.upload(body) }
        #expect(try await mac.ledger() == 2, "the parts that landed are in the ledger, and no FileRef was handed out")
        server.resetCalls()
        let file = try await mac.upload(body)
        #expect(file.parts.count == 3)
        #expect(Self.saves(server, by: "mac").flatMap(\.recordNames) == [names[1]], "only the missing part goes again")
        #expect(try await mac.ledger() == 3)
    }

    @Test("A part acknowledged within 24 hours is trusted; an older one is looked up first and uploaded again when it is gone")
    func reverifyBeforeReuse() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac", configuration: Self.smallParts)
        let body = Self.body(500_000, seed: 8)
        let file = try await mac.upload(body)
        let other = server.transport(user: "alice", device: "other")
        _ = try await other.modifyRecords(deleting: file.satelliteIDs.map { CloudRecordID(Self.name($0), in: PrivateSyncZones.content) }, in: .private)

        mac.clock.advance(3_600)
        server.resetCalls()
        _ = try await mac.upload(body, keeping: file)
        #expect(server.calls.filter { $0.device == "mac" }.isEmpty, "the ledger is trusted within 24 hours")

        mac.clock.advance(24 * 3_600)
        server.resetCalls()
        #expect(try await mac.upload(body, keeping: file) == file)
        let calls = server.calls.filter { $0.device == "mac" }
        #expect(calls.first?.operation == .records, "looked up by name first")
        #expect(calls.contains { $0.operation == .modifyRecords })
        #expect(try await mac.blobs.fetch(file, from: Self.zone) == body)
    }

    @Test("Hash verification: a part with other bytes under its name, or a file that is not the one named, is refused")
    func hashVerification() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac")
        let body = Self.body(10_000, seed: 10)
        let file = try await mac.upload(body)
        var wrongHash = file.value.objectValue ?? [:]
        wrongHash["hash"] = .string(String(repeating: "0", count: 64))
        let renamed = try #require(FileRef(json: .object(wrongHash)))
        await #expect(throws: BlobStoreError.hashMismatch) { try await mac.blobs.fetch(renamed, from: Self.zone) }

        let name = Self.name(file.satelliteIDs[0])
        let held = try #require(server.storedRecord(name, zone: "Content", owner: "alice"))
        var tampered = held
        tampered.encryptedFields[CloudRecord.dataKey] = .bytes(Self.body(10_000, seed: 11))
        server.put([tampered], zone: "Content", owner: "alice")
        await #expect(throws: BlobStoreError.corruptPart(contentID: file.satelliteIDs[0])) { try await mac.blobs.fetch(file, from: Self.zone) }
    }

    @Test("A copy into a space keeps the FileRef and names the satellites with the space's salt; a personal satellite never goes into one")
    func copyIntoSpace() async throws {
        let server = FakeCloudKit()
        let mac = try await Device(server, name: "mac", configuration: Self.smallParts)
        let space = BlobZone(zoneID: CloudZoneID("Space-s1"), database: .private, zoneKey: "private/Space-s1", salt: Data(repeating: 9, count: 32))
        _ = try await mac.transport.modifyZones(saving: [space.zoneID], deleting: [], in: .private)
        let body = Self.body(700_000, seed: 12)
        let file = try await mac.upload(body)
        try await mac.blobs.copy(file, ownerType: .source, from: Self.zone, to: space)
        #expect(server.recordNames(zone: "Space-s1", owner: "alice").sorted() == file.satelliteIDs.map { Self.name($0, salt: space.salt) }.sorted())
        #expect(try await mac.blobs.fetch(file, from: space) == body)

        await #expect(throws: BlobStoreError.personalSatelliteInSpace) {
            try await mac.blobs.upload(Data("mine".utf8), owner: "rs:src_one", ownerType: .readingState, role: "understanding",
                                       mime: "application/json", encoding: .gzip, into: space)
        }
    }
}
