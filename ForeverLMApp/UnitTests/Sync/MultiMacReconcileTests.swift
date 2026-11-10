import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// A second Mac (docs/cloudkit-schema-design.md §13.5): it waits for the seed's metadata, then reconciles
/// record by record. The server's values win except a pending change; a record the server lacks that the
/// manifest lists is deleted locally, never uploaded; one in neither is uploaded and listed in the Mac's
/// own manifest delta.
@Suite("Multi-Mac reconcile", .serialized)
struct MultiMacReconcileTests {
    typealias C = CutoverSeedFixture

    /// Alice's Mac A has seeded her library; Mac B holds the same library and has not reconciled yet.
    private static func seededPair(_ server: FakeCloudKit, name: String) async throws -> (a: EngineTestDevice, b: EngineTestDevice) {
        let a = try await C.seeder(server, name: "\(name)-a")
        let outcome = try await CutoverSeeder(C.environment(a)).run()
        guard case .complete = outcome else { throw CloudError(.internalError, message: "A did not finish: \(outcome)") }
        let b = try await secondMac(server, name: "\(name)-b")
        return (a, b)
    }

    private static func secondMac(_ server: FakeCloudKit, name: String, library: Bool = true) async throws -> EngineTestDevice {
        let b = try EngineTestDevice(server, name: name, deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(b.store)
        if library { try C.addLibrary(b.store) }
        try await b.bootstrap(.macHoldingLibrary)
        return b
    }

    private static func environment(_ b: EngineTestDevice) -> CutoverSeedEnvironment {
        var environment = C.environment(b)
        environment.fetchAll = {
            try await b.fetch()
            return await b.engine.unfetchedZones.isEmpty
        }
        return environment
    }

    @Test("The second Mac waits for the seed's metadata and sends nothing meanwhile; its own edit made while waiting survives")
    func waitsAndKeepsItsEdit() async throws {
        let server = EngineTestDriver.server()
        let a = try await C.seeder(server, name: "rec-wait-a")
        let b = try await Self.secondMac(server, name: "rec-wait-b")
        #expect(try await CutoverReconcile(Self.environment(b)).run() == .waitingForSeed)

        // B renames a notebook while it waits; the engine holds its sends.
        try b.store.execute("UPDATE learning_goals SET title = 'Renamed by B' WHERE id = 'nb1'")
        try b.store.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, Data("wait".utf8))
        try await b.engine.sendChanges()
        #expect(try a.serverEnvelope(.notebook, "nb1") == nil, "nothing is sent, and A has not seeded yet")
        #expect(try b.outboxRows() > 0, "the edit waits in the outbox")

        // A seeds, edits the instructions and sends them; B's hold is lifted and it reconciles.
        _ = try await CutoverSeeder(C.environment(a)).run()
        try a.store.execute("UPDATE learning_goals SET description = 'A wrote this' WHERE id = 'nb1'")
        try await a.send()
        try b.store.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, nil)
        let outcome = try await CutoverReconcile(Self.environment(b)).run()
        guard case .reconciled = outcome else { Issue.record("did not reconcile: \(outcome)"); return }
        try await b.send()
        let server_nb1 = try #require(try a.serverEnvelope(.notebook, "nb1"))
        #expect(server_nb1.fields["title"] == .string("Renamed by B"), "B's own edit made while waiting survives")
        #expect(server_nb1.fields["instructions"] == .string("A wrote this"), "B's title edit does not revert A's instructions")
    }

    @Test("A record deleted on A after the seed is not resurrected by B: it is listed in the manifest, so B deletes it locally")
    func deletedAfterTheSeed() async throws {
        let server = EngineTestDriver.server()
        let (a, b) = try await Self.seededPair(server, name: "rec-del")
        try a.store.execute("DELETE FROM learning_goals WHERE id = 'nb2'")
        try await a.send()
        #expect(try a.serverEnvelope(.notebook, "nb2") == nil)

        let outcome = try await CutoverReconcile(Self.environment(b)).run()
        guard case .reconciled(let uploaded, let deleted, _) = outcome else { Issue.record("did not reconcile: \(outcome)"); return }
        #expect(uploaded == 0)
        #expect(deleted >= 1)
        #expect(try b.count("SELECT COUNT(*) FROM learning_goals WHERE id = 'nb2'") == 0, "B's copy goes")
        #expect(try a.serverEnvelope(.notebook, "nb2") == nil, "nothing was uploaded")
    }

    @Test("A record in neither the server nor the manifest is uploaded and listed in B's own manifest delta")
    func inNeitherIsUploadedAndListed() async throws {
        let server = EngineTestDriver.server()
        let (a, b) = try await Self.seededPair(server, name: "rec-new")
        try C.quietly(b.store) { try NotebookSyncFixture.addSource(b.store, "s9") }
        let outcome = try await CutoverReconcile(Self.environment(b)).run()
        guard case .reconciled(let uploaded, _, _) = outcome else { Issue.record("did not reconcile: \(outcome)"); return }
        #expect(uploaded >= 1)
        #expect(try a.serverEnvelope(.source, "s9", zone: "Catalog") != nil)
        let deltas = try C.root(server).fields["manifestDeltas"]?.objectValue ?? [:]
        let key = try #require(deltas.keys.first { $0.hasPrefix("macbbbbb.reconcile") })
        let file = try #require(deltas[key].flatMap(FileRef.init(json:)))
        let content = try #require(try await b.local.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        let listed = try SeedManifestCodec.decode(try await C.blobs(b).fetch(file, from: content))
        #expect(listed.contains(SeedManifestEntry(type: "Source", id: "s9")))
        #expect(try b.count("SELECT COUNT(*) FROM ck_manifest_pending") == 0, "the pending rows went with the delta's save")
    }

    @Test("A Mac that holds no library has nothing to reconcile")
    func noLibrary() async throws {
        let server = EngineTestDriver.server()
        _ = try await C.seeder(server, name: "rec-none-a")
        let b = try await Self.secondMac(server, name: "rec-none-b", library: false)
        let environment = C.environment(b, holdsLibrary: false)
        #expect(try await CutoverReconcile(environment).run() == .noLibrary)
    }

    @Test("A fetch that did not reach the end never starts the comparison")
    func fetchGate() async throws {
        let server = EngineTestDriver.server()
        let (_, b) = try await Self.seededPair(server, name: "rec-gate")
        var environment = Self.environment(b)
        environment.fetchAll = { false }
        #expect(try await CutoverReconcile(environment).run() == .fetchIncomplete)
        #expect(try b.count("SELECT COUNT(*) FROM ck_seed_cursor") == 0, "nothing was compared")
    }

    @Test("A Mac waiting for the seed holds its sends: the engine reports waitingForSeed and the edit stays in the outbox")
    func waitingMacSendsNothing() async throws {
        let server = EngineTestDriver.server()
        let mac = try await CutoverSeedFixture.seeder(server, name: "switch-hold", library: false)
        try mac.store.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, Data("wait".utf8))
        try CutoverSeedFixture.quietly(mac.store) { try NotebookSyncFixture.addNotebook(mac.store, "nb-hold") }
        try mac.store.execute("UPDATE learning_goals SET title = 'Edited' WHERE id = 'nb-hold'")
        try await mac.engine.sendChanges()
        #expect(await mac.engine.sendHold == .waitingForSeed)
        #expect(try mac.serverEnvelope(.notebook, "nb-hold") == nil)
        try mac.store.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, nil)
        try await mac.engine.sendChanges()
        #expect(await mac.engine.sendHold == nil)
        #expect(try mac.serverEnvelope(.notebook, "nb-hold")?.fields["title"] == .string("Edited"))
    }
}
