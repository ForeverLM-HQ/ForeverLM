import Foundation
import Testing
@testable import ForeverLM

/// The compaction gate (docs/cloudkit-schema-design.md §3.2 rule 4, D42, PD-16): a device whose own
/// `Device.lastSeenDay` is more than 90 days old re-fetches every zone before it sends, then drops
/// pending set and map element edits older than 90 days whose element the server no longer lists.
@Suite("Compaction gate", .serialized)
struct CompactionGateTests {
    private typealias F = MaintenanceFixture

    private static func device(_ server: FakeCloudKit, name: String, lastSeenDaysAgo: Int) async throws -> EngineTestDevice {
        let a = try EngineTestDevice(server, name: name, deviceID: "macaaaaa")
        try await a.bootstrap()
        let lastSeen = MaintenanceDays.day(Date(), minus: lastSeenDaysAgo, timeZone: F.utc)
        try F.put(a, .device, DeviceRecord.id("macaaaaa"), [
            "deviceID": .value(.string("macaaaaa")), "platform": .value(.string("mac")), "appVersion": .value(.string("1.0")),
            "appBuild": .value(.string("180")), "schemaRevision": .value(SyncJSON(SyncSchema.schemaRevision)),
            "firstSeenAt": .value(SyncJSON(1_750_000_000_000)), "lastSeenDay": .value(.string(lastSeen)), "editedAt": .value(SyncJSON(1_750_000_000_000)),
        ])
        try F.put(a, .source, "s1", ["workKeys": .elements(["doi:kept": .bool(true)]), "title": .value(.string("Cells"))], zone: "Catalog")
        try await a.sync()
        return a
    }

    @Test("Away 100 days: the engine state and tokens go, sends wait for the re-fetch, then stale element adds the server no longer lists are dropped")
    func longAbsence() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.device(server, name: "compaction-a", lastSeenDaysAgo: 100)
        let old = SyncStamp(policy: .lastWriter, milliseconds: F.milliseconds(Date().addingTimeInterval(-100 * 86_400)), counter: 0, deviceID: "macaaaaa")
        let recent = SyncStamp(policy: .lastWriter, milliseconds: F.milliseconds(Date()), counter: 0, deviceID: "macaaaaa")
        let catalog = PrivateSyncZones.key(PrivateSyncZones.catalog)
        try PendingPatch(
            changes: ["workKeys": .object(["doi:gone": .bool(true), "doi:kept": .bool(true), "doi:new": .bool(true)])],
            stamps: ["workKeys": .elements(["doi:gone": old, "doi:kept": old, "doi:new": recent])],
            zoneKey: catalog, type: "Source", wireID: "s1"
        ).save(in: a.store, now: Date())
        try a.store.replica.setEngineState(ReplicaStore.EngineScope.privateEngine, Data("state".utf8))

        let service = F.service(a)
        await service.beforeEngineStarts()
        #expect(try a.store.replica.engineState(ReplicaStore.EngineScope.refetchBeforeSend) != nil)
        #expect(try a.store.replica.engineState(ReplicaStore.EngineScope.privateEngine) == nil, "CKSyncEngine starts over")
        #expect(try a.count("SELECT COUNT(*) FROM ck_zones WHERE change_token IS NOT NULL") == 0)

        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.send()
        #expect(await a.engine.sendHold == .refetchBeforeSend)
        #expect(try a.serverEnvelope(.course, "c1") == nil, "nothing is sent before the re-fetch")

        #expect(await service.tick(caughtUp: false).compactionDropped == nil, "not before the re-fetch reached the end")
        try await a.fetch()
        let report = await service.tick(caughtUp: true)
        #expect(report.compactionDropped == 1)
        let patch = try #require(try PendingPatch.load(zoneKey: catalog, type: "Source", wireID: "s1", in: a.store))
        #expect(Set((patch.changes["workKeys"]?.objectValue ?? [:]).keys) == ["doi:kept", "doi:new"],
                "the old add the server still lists and the recent one stay")
        #expect(try a.store.replica.engineState(ReplicaStore.EngineScope.refetchBeforeSend) == nil)
        let today = MaintenanceDays.day(Date().addingTimeInterval(EngineTestDevice.ahead), timeZone: F.utc)
        #expect(try a.serverEnvelope(.device, DeviceRecord.id("macaaaaa"))?.fields["lastSeenDay"] == .string(today))

        await EngineTestDriver.pause()
        try await a.send()
        #expect(await a.engine.sendHold == nil)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Cells"))
    }

    @Test("A device seen within the horizon starts as it is")
    func recentDevice() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.device(server, name: "compaction-b", lastSeenDaysAgo: 30)
        await F.service(a).beforeEngineStarts()
        #expect(try a.store.replica.engineState(ReplicaStore.EngineScope.refetchBeforeSend) == nil)
        #expect(try a.count("SELECT COUNT(*) FROM ck_zones WHERE change_token IS NOT NULL") > 0)
        #expect(CompactionGate.isDue(lastSeenDay: "2026-01-01", now: Date(timeIntervalSince1970: 1_775_000_000), timeZone: F.utc) == false)
        #expect(CompactionGate.isDue(lastSeenDay: "2025-12-01", now: Date(timeIntervalSince1970: 1_775_000_000), timeZone: F.utc))
        #expect(CompactionGate.isDue(lastSeenDay: nil, now: Date(), timeZone: F.utc) == false, "a device with no record has nothing to compact against")
    }
}
