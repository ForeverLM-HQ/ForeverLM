import Foundation
import Testing
@testable import ForeverLM

/// The shared base on the personal root (docs/cloudkit-schema-design.md §13.6): the root is saved in
/// `Library`, and the shards it points at are satellites in the private `Content` zone beside it.
@Suite("Migration base store", .serialized)
struct MigrationBaseStoreTests {
    private typealias F = MaintenanceFixture

    @Test("A shard is uploaded into Content and found there again, while the root is saved in Library (F5)")
    func shardsLiveInContent() async throws {
        let server = EngineTestDriver.server()
        let mac = try EngineTestDevice(server, name: "base-root", deviceID: "macaaaaa")
        try await mac.bootstrap(.macHoldingLibrary)
        try await mac.sync()
        func zone(_ key: String) async throws -> BlobZone {
            guard let zone = try await mac.local.perform({ try BlobZone.resolve(zoneKey: key, in: $0) }) else { throw SpaceMoveError.notHeld(key) }
            return zone
        }
        let base = RootMigrationBaseStore(
            store: mac.local, blobs: CutoverSeedFixture.blobs(mac), writer: CutoverSeedFixture.writer(mac),
            library: { try await zone(PrivateSyncZones.libraryKey) }, content: { try await zone(PrivateSyncZones.key(PrivateSyncZones.content)) }
        )

        let key = MigrationBaseShards.entryKey(zone: "Knowledge", recordName: "rec1")
        let entry = MigrationBaseEntry(changeTag: "tag-1", waiting: false, records: [:])
        let landed = try await base.advance(MigrationBaseAdvance(
            entries: [key: entry], watermark: MigrationImportWatermark(container: "old", zones: ["Knowledge"], tokens: ["Knowledge": "AAAA"])
        ))
        #expect(landed)

        let shardName = MigrationBaseShards.name(forRecordName: "rec1")
        #expect(try await base.shard(shardName)[key]?.changeTag == "tag-1", "the shard reads back from where it was uploaded")
        #expect(try await base.watermark()?.zones == ["Knowledge"])

        let root = try #require(try F.stored(server, "root", zone: "Library"))
        let pointer = try #require(root.fields["legacyBase"]?.objectValue?[shardName].flatMap(FileRef.init(json:)))
        #expect(try F.onServer(mac, pointer), "the shard's satellite is in Content")
        #expect(try F.names(mac, pointer).allSatisfy { server.storedRecord($0, zone: "Library", owner: F.user) == nil }, "and none is in Library")
    }
}
