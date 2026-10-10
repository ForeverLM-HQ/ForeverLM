import Foundation
import Testing
@testable import ForeverLM

/// `ZoneRoot.maintenanceLease` (docs/cloudkit-schema-design.md §3.5.1, D8, R3-3): only a Mac that holds
/// the library takes it, the seeder from its claim, any other only after `seed.metadataCompleteAt` and
/// its own first complete fetch; the first acknowledged save stands, and its holder renews it.
@Suite("Maintenance lease", .serialized)
struct MaintenanceLeaseTests {
    private typealias F = MaintenanceFixture

    /// The seeder `a` made the root; the metadata is in and `a`'s lease ran out an hour ago.
    private static func lapsedLease(_ server: FakeCloudKit, metadataComplete: Bool = true) throws {
        let now = Date()
        var changes: [String: RecordPatch.Change] = [
            "maintenanceLease": .value(.object(["device": .string("macaaaaa"), "leaseUntil": SyncJSON(F.milliseconds(now.addingTimeInterval(-3_600)))])),
        ]
        if metadataComplete { changes["seed"] = .elements(["metadataCompleteAt": SyncJSON(F.milliseconds(now.addingTimeInterval(-86_400)))]) }
        try F.patchRoot(server, changes)
    }

    @Test("The seeder holds the lease from its claim, before the metadata is in, and says so in its Device record")
    func seederHoldsFromClaim() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "lease-seeder", deviceID: "macaaaaa")
        try await a.bootstrap()
        #expect(try F.lease(server)?.device == "macaaaaa", "the root's create takes it")
        let report = await F.service(a).tick(caughtUp: false)
        #expect(report.lease == .hold)
        #expect(report.holdsLease)
        let device = try #require(try a.serverEnvelope(.device, DeviceRecord.id("macaaaaa")))
        #expect(device.fields["roles"]?.objectValue?["maintenance"] == .bool(true))
        #expect(device.fields["platform"] == .string("mac"))
        #expect(device.fields["schemaRevision"]?.intValue == SyncSchema.schemaRevision)
        #expect(device.fields["lastSeenDay"] == .string(MaintenanceDays.day(Date().addingTimeInterval(EngineTestDevice.ahead), timeZone: F.utc)))
    }

    @Test("A Mac with no library never takes a lapsed lease")
    func noLibraryNeverTakes() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "lease-a", deviceID: "macaaaaa")
        try await a.bootstrap()
        let b = try EngineTestDevice(server, name: "lease-b", deviceID: "macbbbbb")
        try await b.bootstrap(.macWithoutLibrary)
        try Self.lapsedLease(server)
        try await b.sync()
        let report = await F.service(b, holdsLibrary: false).tick(caughtUp: true)
        #expect(report.lease == .wait)
        #expect(!report.holdsLease)
        #expect(try F.lease(server)?.device == "macaaaaa")
    }

    @Test("A Mac that has not finished its first fetch waits; after it, it takes the lapsed lease")
    func firstFetchFirst() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "lease-a2", deviceID: "macaaaaa")
        try await a.bootstrap()
        try Self.lapsedLease(server)
        let b = try EngineTestDevice(server, name: "lease-b2", deviceID: "macbbbbb")
        try await b.bootstrap(.macWithoutLibrary)
        let service = F.service(b)
        #expect(await service.tick(caughtUp: false).lease == .wait, "no complete fetch yet")
        #expect(try F.lease(server)?.device == "macaaaaa")
        try await b.sync()
        let report = await service.tick(caughtUp: true)
        #expect(report.lease == .take)
        #expect(report.holdsLease)
        #expect(try F.lease(server)?.device == "macbbbbb")
        #expect(try b.store.replica.personalRoot().flatMap { MaintenanceLease.holder(in: $0.envelope) }?.device == "macbbbbb", "the replica holds the acknowledged root")
    }

    @Test("Before the metadata is in, nobody but the seeder takes the lease")
    func notBeforeMetadataComplete() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "lease-a3", deviceID: "macaaaaa")
        try await a.bootstrap()
        try Self.lapsedLease(server, metadataComplete: false)
        let b = try EngineTestDevice(server, name: "lease-b3", deviceID: "macbbbbb")
        try await b.bootstrap(.macWithoutLibrary)
        try await b.sync()
        #expect(await F.service(b).tick(caughtUp: true).lease == .wait)
        #expect(try F.lease(server)?.device == "macaaaaa")
    }

    @Test("Two Macs after a lapse: the first acknowledged save stands, and the other waits")
    func firstSaveStands() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "lease-a4", deviceID: "macaaaaa")
        try await a.bootstrap()
        try Self.lapsedLease(server)
        let b = try EngineTestDevice(server, name: "lease-b4", deviceID: "macbbbbb")
        let c = try EngineTestDevice(server, name: "lease-c4", deviceID: "macccccc")
        try await b.bootstrap(.macWithoutLibrary)
        try await c.bootstrap(.macWithoutLibrary)
        try await b.sync()
        try await c.sync()
        // c decided from its replica before b saved; its save is decided again on the server's root.
        #expect(await F.service(b).tick(caughtUp: true).lease == .take)
        let report = await F.service(c).tick(caughtUp: true)
        #expect(report.lease == .wait)
        #expect(!report.holdsLease)
        #expect(try F.lease(server)?.device == "macbbbbb")
    }

    @Test("The holder renews a lease with less than half of it left, and lets it be when more is left")
    func holderRenews() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "lease-a5", deviceID: "macaaaaa")
        try await a.bootstrap()
        let soon = F.milliseconds(Date().addingTimeInterval(3_600))
        try F.patchRoot(server, ["maintenanceLease": .value(.object(["device": .string("macaaaaa"), "leaseUntil": SyncJSON(soon)]))])
        try await a.sync()
        let service = F.service(a)
        #expect(await service.tick(caughtUp: true).lease == .renew)
        let renewed = try #require(try F.lease(server))
        #expect(renewed.device == "macaaaaa")
        #expect(renewed.leaseUntil > soon + 20 * 3_600_000)
        #expect(await service.tick(caughtUp: true).lease == .hold)
    }

    @Test("The decision, case by case")
    func decisions() {
        let now: Int64 = 1_800_000_000_000
        let live = MaintenanceLease.Holder(device: "macbbbbb", leaseUntil: now + 3_600_000)
        let lapsed = MaintenanceLease.Holder(device: "macbbbbb", leaseUntil: now - 1)
        #expect(MaintenanceLease.decide(holder: nil, me: "macaaaaa", standing: .eligible, now: now) == .take)
        #expect(MaintenanceLease.decide(holder: live, me: "macaaaaa", standing: .eligible, now: now) == .wait)
        #expect(MaintenanceLease.decide(holder: lapsed, me: "macaaaaa", standing: .eligible, now: now) == .take)
        #expect(MaintenanceLease.decide(holder: lapsed, me: "macaaaaa", standing: .firstFetchPending, now: now) == .wait)
        #expect(MaintenanceLease.decide(holder: nil, me: "macaaaaa", standing: .noLibrary, now: now) == .wait)
        #expect(MaintenanceLease.decide(holder: live, me: "macbbbbb", standing: .seedMetadataPending, now: now) == .renew, "the seeder keeps its own")
        #expect(MaintenanceLease.decide(holder: live, me: "macbbbbb", standing: .noLibrary, now: now) == .wait)
    }
}
