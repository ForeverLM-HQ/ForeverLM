import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Who seeds (docs/cloudkit-schema-design.md §13.4 step 1): a Mac with no library never claims, a live
/// claim is waited for, an expired one is taken over by a compare-and-set save (before the base save the new
/// holder publishes its own snapshot, after it the new holder becomes the importer), and a root a Mac with
/// no library left `pending` is claimed and seeded in reconcile mode.
@Suite("Seed takeover", .serialized)
struct SeedTakeoverTests {
    typealias C = CutoverSeedFixture

    private static func expireClaim(_ server: FakeCloudKit, device: String = "macaaaaa") throws {
        let past = SyncJSON(SyncTime.milliseconds(Date().addingTimeInterval(-3_600)))
        try MaintenanceFixture.patchRoot(server, ["seedClaim": .value(.object(["device": .string(device), "leaseUntil": past]))])
    }

    @Test("A Mac that holds no library never claims, even when the seed waits for a seeder")
    func noLibraryNeverClaims() async throws {
        let server = EngineTestDriver.server()
        _ = try await C.seeder(server, name: "take-a", library: false)
        try Self.expireClaim(server)
        let b = try EngineTestDevice(server, name: "take-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try await b.bootstrap(.macWithoutLibrary)
        let before = try C.root(server)
        let outcome = try await CutoverSeeder(C.environment(b, holdsLibrary: false)).run()
        #expect(outcome == .noLibrary)
        #expect(try C.root(server).fields["seedClaim"] == before.fields["seedClaim"], "nothing was written")
    }

    @Test("Another Mac's live claim is waited for")
    func liveClaimWaits() async throws {
        let server = EngineTestDriver.server()
        _ = try await C.seeder(server, name: "wait-a")
        let b = try EngineTestDevice(server, name: "wait-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(b.store)
        try await b.bootstrap(.macHoldingLibrary)
        var phases: [CutoverSeedPhase] = []
        let lock = NSLock()
        var environment = C.environment(b)
        environment.progress = { phase in lock.withLock { phases.append(phase) } }
        let outcome = try await CutoverSeeder(environment).run()
        #expect(outcome == .waiting(holder: "macaaaaa"))
        #expect(lock.withLock { phases.contains(.waiting(holder: "macaaaaa")) })
        #expect(try C.root(server).fields["seedClaim"]?.objectValue?["device"] == .string("macaaaaa"))
    }

    @Test("A takeover before the base save publishes its own snapshot, and seeds")
    func takeoverBeforeTheBase() async throws {
        let server = EngineTestDriver.server()
        _ = try await C.seeder(server, name: "tb-a")   // made the root and the claim, then slept before P0
        try Self.expireClaim(server)
        let b = try EngineTestDevice(server, name: "tb-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(b.store)
        try C.addLibrary(b.store)
        try b.store.execute("INSERT INTO ck_legacy_snapshot (old_zone, record_name, change_tag, field_hashes) VALUES ('Knowledge', 'src-b', 'tagB', '{\"r\":{},\"w\":false}')")
        try await b.bootstrap(.macHoldingLibrary)
        #expect(try C.root(server).fields["legacyBase"] == nil)

        let outcome = try await CutoverSeeder(C.environment(b)).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        let root = try C.root(server)
        #expect(root.fields["seedClaim"]?.objectValue?["device"] == .string("macbbbbb"))
        #expect(Array(try await C.baseEntries(b).keys) == ["Knowledge/src-b"], "its own snapshot is the base")
        #expect(try b.serverEnvelope(.notebook, "nb1") != nil)
    }

    @Test("After the base save the new holder refreshes and imports first, then reconciles what is there and finishes the seed once")
    func takeoverAfterTheBase() async throws {
        let server = EngineTestDriver.server()
        let a = try await C.seeder(server, name: "ta-a")
        // A publishes its base and sends part of P1, then is killed.
        var killed = C.environment(a)
        killed.configuration.batchSize = 1
        let engine = a.engine
        let sent = CutoverSeederTests.Counter()
        killed.send = {
            if sent.next() == 3 { throw CloudError(.networkUnavailable, message: "killed") }
            EngineTestDriver.follow(server)
            try await engine.sendChanges()
        }
        await #expect(throws: CloudError.self) { _ = try await CutoverSeeder(killed).run() }
        #expect(try C.root(server).fields["legacyBase"]?.objectValue?.count == 64)
        try Self.expireClaim(server)
        let heldByA = server.recordNames(zone: "Library", owner: C.user).count + server.recordNames(zone: "Catalog", owner: C.user).count

        let b = try EngineTestDevice(server, name: "ta-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(b.store)
        try C.addLibrary(b.store)
        try await b.bootstrap(.macHoldingLibrary)
        try await b.sync()
        var environment = C.environment(b)
        let imported = CutoverSeederTests.Counter()
        environment.afterTakeover = {
            _ = imported.next()
            return true
        }
        let outcome = try await CutoverSeeder(environment).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        #expect(imported.next() == 2, "the refresh and the import pass ran once, before B reconciled")
        let root = try C.root(server)
        #expect(root.fields["seedClaim"]?.objectValue?["device"] == .string("macbbbbb"), "the new holder is the importer")
        #expect(MaintenanceLease.holder(in: root)?.device == "macbbbbb")
        #expect(try C.seedMap(server)["state"] == .string("complete"))
        for id in ["s1", "s2", "s3"] { #expect(try b.serverEnvelope(.source, id, zone: "Catalog") != nil) }
        let total = server.recordNames(zone: "Library", owner: C.user).count + server.recordNames(zone: "Catalog", owner: C.user).count
        #expect(total > heldByA, "B uploaded what A had not reached")
    }

    @Test("A root a Mac with no library left pending is claimed by the library's Mac, which seeds against what is already there")
    func pendingRootIsClaimed() async throws {
        let server = EngineTestDriver.server()
        _ = server.put([], zone: "Knowledge", owner: C.user, container: FakeCloudKit.legacyContainer)
        let empty = try EngineTestDevice(server, name: "pend-empty", deviceID: "macaaaaa", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try await empty.bootstrap(.macWithoutLibrary)
        #expect(try C.seedMap(server)["state"] == .string("pending"))

        let b = try EngineTestDevice(server, name: "pend-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(b.store)
        try C.addLibrary(b.store)
        try await b.bootstrap(.macHoldingLibrary)
        try await b.sync()
        let outcome = try await CutoverSeeder(C.environment(b)).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        let seed = try C.seedMap(server)
        #expect(seed["state"] == .string("complete"))
        #expect(seed["startedAt"]?.int64Value != nil)
        #expect(try C.root(server).fields["seedClaim"]?.objectValue?["device"] == .string("macbbbbb"))
        #expect(try b.serverEnvelope(.notebook, "nb2") != nil)
    }
}
