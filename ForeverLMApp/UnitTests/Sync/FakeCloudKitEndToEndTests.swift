import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The cutover end to end on FakeCloudKit (docs/cloudkit-schema-design.md §13.4, §13.5; WP16): a
/// production-shaped library seeds, a second device syncs it, a purge stops the sends, an expired token
/// leaves no ghost, and a Mac that joins after the seed never fetches the old container. The spaces round
/// trip (P6) is in `CutoverSpaceSeedTests`, which needs the app's space services.
@Suite("FakeCloudKit end to end", .serialized)
struct FakeCloudKitEndToEndTests {
    typealias C = CutoverSeedFixture
    typealias F = NotebookSyncFixture

    /// Twelve notebooks and sixty sources, each source filed into the notebook its number names and every
    /// fifth also into the next one: a few hundred records, in batches of fifty.
    private static func productionShaped(_ store: KnowledgeStore) throws {
        try C.quietly(store) {
            for n in 0..<12 { try F.addNotebook(store, "nb\(n)", title: "Notebook \(n)") }
            for s in 0..<60 {
                try F.addSource(store, "src\(s)")
                try F.file(store, "src\(s)", into: "nb\(s % 12)")
                if s % 5 == 0 { try F.file(store, "src\(s)", into: "nb\((s + 1) % 12)") }
            }
        }
    }

    private static func seededLibrary(_ server: FakeCloudKit, name: String) async throws -> EngineTestDevice {
        let mac = try await C.seeder(server, name: name, library: false)
        try productionShaped(mac.store)
        var environment = C.environment(mac)
        environment.configuration.batchSize = 50
        let outcome = try await CutoverSeeder(environment).run()
        guard case .complete(let records) = outcome, records >= 60 + 12 + 72 else { throw CloudError(.internalError, message: "the seed did not finish: \(outcome)") }
        return mac
    }

    @Test("A production-shaped library seeds, and a second device that syncs holds every notebook, source and Entry")
    func seedsAndASecondDeviceSyncs() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.seededLibrary(server, name: "e2e-seed")
        #expect(try a.outboxRows() == 0)

        let b = try EngineTestDevice(server, name: "e2e-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try await b.bootstrap(.macWithoutLibrary)
        try await b.sync()
        #expect(try b.count("SELECT COUNT(*) FROM learning_goals WHERE entity_kind = 'notebook'") == 12)
        #expect(try b.count("SELECT COUNT(*) FROM sources") == 60)
        #expect(try b.count("SELECT COUNT(*) FROM learning_goal_items") == 72)
        #expect(try b.text("SELECT title FROM learning_goals WHERE id = 'nb7'") == "Notebook 7")
    }

    @Test("A purge stops the sends: the zone the seed was writing to goes, the seed stops with its cause and writes nothing more")
    func purgeStopsTheSeed() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "e2e-purge", library: false)
        try Self.productionShaped(mac.store)
        var environment = C.environment(mac)
        environment.configuration.batchSize = 10
        environment.configuration.sendAttempts = 2
        let engine = mac.engine
        let sent = CutoverSeederTests.Counter()
        environment.send = {
            // After the third batch the learner removes ForeverLM's data in iCloud settings.
            if sent.next() == 3 { server.deleteZone("Library", owner: C.user, reason: .purged) }
            EngineTestDriver.follow(server)
            try await engine.sendChanges()
        }
        let outcome: CutoverSeedOutcome
        do {
            outcome = try await CutoverSeeder(environment).run()
        } catch {
            // A purge may also surface as the error of the send that met it: either way the seed stopped.
            #expect(await engine.stopped != nil)
            return
        }
        #expect(outcome != .complete(records: 0))
        if case .complete = outcome { Issue.record("a purged library does not finish its seed") }
        #expect(await engine.stopped != nil || outcome == .stopped(.sendsStalled))
        // The purge took the zone and its root with it, so a root that is gone also says no seed finished.
        #expect((try? C.seedMap(server))?["metadataCompleteAt"] == nil)
    }

    @Test("An expired change token leaves no ghost: a deleted notebook a device never heard of is gone after its re-fetch")
    func expiredTokenLeavesNoGhost() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.seededLibrary(server, name: "e2e-token")
        let b = try EngineTestDevice(server, name: "e2e-token-b", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try await b.bootstrap(.macWithoutLibrary)
        try await b.sync()
        #expect(try b.count("SELECT COUNT(*) FROM learning_goals WHERE id = 'nb3'") == 1)

        try a.store.execute("DELETE FROM learning_goals WHERE id = 'nb3'")
        try await a.send()
        server.expireZoneChangeTokens(zone: "Library", owner: C.user)
        try await b.sync()
        #expect(try b.count("SELECT COUNT(*) FROM learning_goals WHERE id = 'nb3'") == 0, "the audit after the expired token finds the deletion")
    }

    @Test("A fresh Mac joins after the seed as a new device and never fetches the old container; it holds no library, so it never claims")
    func freshMacJoinsAfterTheSeed() async throws {
        let server = EngineTestDriver.server()
        _ = try await Self.seededLibrary(server, name: "e2e-join")
        let fresh = try EngineTestDevice(server, name: "e2e-fresh", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(fresh.store, mode: "fresh", freshReason: "noHistory")
        try await fresh.bootstrap(.macWithoutLibrary)
        try await fresh.sync()
        #expect(fresh.legacy.calls.isEmpty, "the old container was never asked")
        #expect(try fresh.count("SELECT COUNT(*) FROM sources") == 60)
        let environment = C.environment(fresh, holdsLibrary: false)
        #expect(try await CutoverSeeder(environment).run() == .noLibrary)
        #expect(try await CutoverReconcile(environment).run() == .noLibrary)
        #expect(try C.root(server).fields["seedClaim"]?.objectValue?["device"] != .string("macbbbbb"))
    }

    @Test("A fresh Mac that starts before the seed creates a pending root, and the library's Mac claims it and seeds")
    func freshMacBeforeTheSeed() async throws {
        let server = EngineTestDriver.server()
        _ = server.put([], zone: "Knowledge", owner: C.user, container: FakeCloudKit.legacyContainer)
        let fresh = try EngineTestDevice(server, name: "e2e-early", deviceID: "macaaaaa", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try await fresh.bootstrap(.macWithoutLibrary)
        #expect(try C.seedMap(server)["state"] == .string("pending"))

        let library = try EngineTestDevice(server, name: "e2e-library", deviceID: "macbbbbb", user: C.user, registry: KnowledgeStore.projectionRegistry)
        try C.activate(library.store)
        try Self.productionShaped(library.store)
        try await library.bootstrap(.macHoldingLibrary)
        try await library.sync()
        var environment = C.environment(library)
        environment.configuration.batchSize = 50
        guard case .complete = try await CutoverSeeder(environment).run() else { Issue.record("the library's Mac did not seed"); return }
        try await fresh.sync()
        #expect(try fresh.count("SELECT COUNT(*) FROM sources") == 60, "the early Mac gets the library by syncing")
    }
}
