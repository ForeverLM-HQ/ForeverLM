import Foundation
import Testing
@testable import ForeverLM

/// The notebook cover backfill (docs/cloudkit-schema-design.md §5.9, D53, WP31): once per zone, on the
/// maintenance Mac only, after the seed is complete and while the Setting is on, a
/// bounded pass draws a cover for every active notebook that has none. Its marker is a Setting record
/// saved by compare-and-set beside the engine, the first acknowledged create wins, and `done` ends it for
/// every Mac.
@Suite("Notebook cover backfill", .serialized)
struct NotebookCoverBackfillTests {
    private typealias C = NotebookCoverFixture
    private typealias F = MaintenanceFixture
    private static let hour: TimeInterval = 3_600

    private static let on = NotebookCoverGates(automatic: true)

    /// A Mac that holds the library, with `notebooks` made and sent and the seed complete.
    private static func library(_ server: FakeCloudKit, _ name: String, notebooks: [String], deviceID: String = "macaaaaa") async throws -> EngineTestDevice {
        let mac = try await C.mac(server, name, deviceID: deviceID)
        for id in notebooks { try await C.addNotebook(mac, id) }
        try await C.setSeed(mac, "complete")
        return mac
    }

    /// A Mac that joined the account's library afterwards.
    private static func joined(_ server: FakeCloudKit, _ name: String, deviceID: String = "macbbbbb") async throws -> EngineTestDevice {
        let mac = try EngineTestDevice(server, name: name, deviceID: deviceID, registry: KnowledgeStore.projectionRegistry)
        try await mac.bootstrap(.macWithoutLibrary)
        try await mac.sync()
        return mac
    }

    private static func drawnIDs(_ drawer: C.Drawer) -> [String] {
        drawer.requests.map(\.source.id)
    }

    // MARK: Who and when

    @Test("Only the lease holder runs the pass, and only once the root shows seed.state = complete")
    func leaseHolderAfterTheSeed() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-a", notebooks: ["nb-1", "nb-2"])
        try await C.setSeed(a, "seeding")
        let b = try await Self.joined(server, "backfill-b")
        let drawerA = C.Drawer()
        let drawerB = C.Drawer()
        let coversA = C.service(a, drawer: drawerA)
        let coversB = C.service(b, drawer: drawerB)
        let maintenanceA = F.service(a)
        let maintenanceB = F.service(b, holdsLibrary: false)
        await maintenanceA.attachCovers(coversA)
        await maintenanceB.attachCovers(coversB)

        #expect(await maintenanceA.tick(caughtUp: true).holdsLease)
        await coversA.finishBackfill()
        #expect(drawerA.count == 0, "the seed is still under way")
        #expect(try C.serverMarker(a) == nil)

        try await C.setSeed(a, "complete")
        try await b.sync()
        let report = await maintenanceB.tick(caughtUp: true)
        #expect(!report.holdsLease)
        await coversB.finishBackfill()
        #expect(drawerB.count == 0, "a Mac that does not hold the lease draws nothing")

        _ = await maintenanceA.tick(caughtUp: true)
        await coversA.finishBackfill()
        #expect(Set(Self.drawnIDs(drawerA)) == ["nb-1", "nb-2"])
        for id in ["nb-1", "nb-2"] { #expect(try C.serverCover(a, id) != nil) }
        #expect(try C.serverMarker(a)?.state == .done)
        #expect(try C.serverMarker(a)?.by == "macaaaaa")
    }

    @Test("A Mac that lost the lease stops a pass that runs")
    func leaseLostStopsThePass() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-lost", notebooks: ["nb-1", "nb-2", "nb-3"])
        let drawer = C.Drawer()
        let covers = C.service(a, drawer: drawer)
        drawer.during = { await covers.maintenanceRound(holdsLease: false) }

        await covers.maintenanceRound(holdsLease: true)
        await covers.finishBackfill()
        #expect(drawer.count < 3, "stopped between two notebooks")
        #expect(try C.serverMarker(a)?.state == .running, "and never says done")
    }

    // MARK: Once per zone

    @Test("A lost create does nothing, a fresher running marker is left alone, and one older than 24 hours is taken over")
    func claimsAndTakeover() async throws {
        let server = EngineTestDriver.server()
        let clock = C.Clock()
        let a = try await Self.library(server, "backfill-claim", notebooks: ["nb-1", "nb-2"])
        let drawer = C.Drawer()
        let covers = C.service(a, drawer: drawer, clock: { clock.now })
        let now = SyncTime.milliseconds(clock.now)

        // Another Mac's create is on the server, which this Mac has not fetched: its create loses.
        try C.putMarker(a, .running, by: "macbbbbb", at: now)
        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .otherMacRuns)
        #expect(drawer.count == 0)
        #expect(try C.serverMarker(a)?.by == "macbbbbb")

        // 23 hours on: still fresher than a day.
        clock.advance(23 * Self.hour)
        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .otherMacRuns)
        #expect(drawer.count == 0)

        // 25 hours: the claim went quiet, and a save against the version read takes it over.
        clock.advance(2 * Self.hour)
        let result = await covers.runBackfill()[PrivateSyncZones.libraryKey]
        #expect(result == .finished(drawn: 2, gaveUp: 0))
        #expect(try C.serverMarker(a)?.by == "macaaaaa" && C.serverMarker(a)?.state == .done)
    }

    @Test("A done marker stops a later lease holder, and a notebook made in bulk afterwards gets no cover")
    func doneIsFinal() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-done-a", notebooks: ["nb-1"])
        let drawerA = C.Drawer()
        #expect(await C.service(a, drawer: drawerA).runBackfill()[PrivateSyncZones.libraryKey] == .finished(drawn: 1, gaveUp: 0))

        // Notebooks made in bulk later (an import, a split's children): the pass is over.
        try await C.addNotebook(a, "nb-bulk")
        let b = try await Self.joined(server, "backfill-done-b")
        let drawerB = C.Drawer()
        let coversB = C.service(b, drawer: drawerB)
        #expect(await coversB.runBackfill()[PrivateSyncZones.libraryKey] == .done)
        #expect(await C.service(a, drawer: drawerA).runBackfill()[PrivateSyncZones.libraryKey] == .done)
        #expect(drawerB.count == 0 && drawerA.count == 1)
        #expect(try C.serverCover(a, "nb-bulk") == nil)
    }

    @Test("The holder renews the marker's time every hour while the pass waits")
    func hourlyRenewal() async throws {
        let server = EngineTestDriver.server()
        let clock = C.Clock()
        let a = try await Self.library(server, "backfill-renew", notebooks: ["nb-1", "nb-2"])
        let gates = C.Gates()
        let drawer = C.Drawer()
        drawer.during = { gates.value = NotebookCoverGates(automatic: false) }
        let covers = C.service(a, drawer: drawer, gates: gates, clock: { clock.now })

        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .paused)
        let claimed = try #require(try C.serverMarker(a)?.at)
        #expect(drawer.count == 1)
        clock.advance(30 * 60)
        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .paused)
        #expect(try C.serverMarker(a)?.at == claimed, "not before the hour")
        clock.advance(40 * 60)
        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .paused)
        let renewed = try #require(try C.serverMarker(a)?.at)
        #expect(renewed >= claimed + 70 * 60 * 1_000 - 1_000, "renewed while it waited")
        #expect(try C.serverMarker(a)?.state == .running)
    }

    // MARK: Which notebooks

    @Test("It skips notebooks that have a cover or are not active, and still draws a learner-typed emoji title")
    func whichNotebooks() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-which", notebooks: ["nb-plain", "nb-covered", "nb-archived"])
        try await C.addNotebook(a, "nb-typed", title: "🔭 Exoplanet atmospheres")
        try C.patchServer(a, .notebook, "nb-covered", ["files": .elements(["cover": C.otherCover("nb-covered").value])])
        try C.patchServer(a, .notebook, "nb-archived", ["status": .value(.string("archived"))])
        try await a.sync()
        let drawer = C.Drawer()

        let result = await C.service(a, drawer: drawer).runBackfill()[PrivateSyncZones.libraryKey]
        #expect(result == .finished(drawn: 2, gaveUp: 0))
        #expect(Set(Self.drawnIDs(drawer)) == ["nb-plain", "nb-typed"])
        let typed = try #require(drawer.requests.first { $0.source.id == "nb-typed" })
        #expect(typed.prompt.contains("Subject: Exoplanet atmospheres") && typed.prompt.contains("🔭"), "the emoji is only a hint")
        #expect(try C.serverCover(a, "nb-covered") == C.otherCover("nb-covered"))
        #expect(try C.serverCover(a, "nb-archived") == nil)
    }

    @Test("A cover another writer set before the pointer moves is kept, and the notebook leaves the queue")
    func anotherWriterBeforeThePointer() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-race", notebooks: ["nb-1"])
        let other = C.otherCover("nb-1")
        let drawer = C.Drawer()
        drawer.during = { try C.patchServer(a, .notebook, "nb-1", ["files": .elements(["cover": other.value])]) }

        #expect(await C.service(a, drawer: drawer).runBackfill()[PrivateSyncZones.libraryKey] == .finished(drawn: 0, gaveUp: 0))
        #expect(drawer.count == 1)
        #expect(try C.serverCover(a, "nb-1") == other)
        #expect(try C.queued(a, kind: NotebookCoverQueue.backfillKind) == 0)
    }

    @Test("A notebook queued for its creation cover is left to that queue, and one made after the claim follows the creation rule")
    func creationQueueAndLateNotebooks() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-creation", notebooks: ["nb-1", "nb-new"])
        try a.store.queueNotebookCover("nb-new", gates: Self.on)
        let drawer = C.Drawer()
        let covers = C.service(a, drawer: drawer)

        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .finished(drawn: 1, gaveUp: 0))
        #expect(Self.drawnIDs(drawer) == ["nb-1"])
        #expect(try C.queued(a) == 1, "nb-new waits in the creation queue")
        await covers.drainQueued()
        #expect(Set(Self.drawnIDs(drawer)) == ["nb-1", "nb-new"])
    }

    // MARK: Failure, pausing and resuming

    @Test("A notebook that fails both attempts keeps its emoji, and the pass moves on and finishes")
    func givesUpAfterTwoAttempts() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-attempts", notebooks: ["nb-bad", "nb-ok"])
        let drawer = C.Drawer()
        drawer.failing = ["nb-bad"]

        let result = await C.service(a, drawer: drawer).runBackfill()[PrivateSyncZones.libraryKey]
        #expect(result == .finished(drawn: 1, gaveUp: 1))
        #expect(Self.drawnIDs(drawer).filter { $0 == "nb-bad" }.count == 2, "two attempts, as the spec says")
        #expect(try C.serverCover(a, "nb-bad") == nil && C.serverCover(a, "nb-ok") != nil)
        #expect(try C.serverMarker(a)?.state == .done)
        #expect(try C.queued(a, kind: NotebookCoverQueue.backfillKind) == 0)
    }

    @Test("It pauses for the Setting, claims nothing meanwhile, and resumes where it stopped from the queue after a quit")
    func pausesAndResumes() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-pause", notebooks: ["nb-1", "nb-2", "nb-3"])
        let gates = C.Gates(automatic: false)
        let drawer = C.Drawer()
        let covers = C.service(a, drawer: drawer, gates: gates)

        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .paused)
        #expect(try C.serverMarker(a) == nil, "nothing is claimed while the Setting is off")
        #expect(drawer.count == 0)

        // On again; the Setting goes off after the first notebook.
        gates.value = Self.on
        drawer.during = { gates.value = NotebookCoverGates(automatic: false) }
        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .paused)
        #expect(drawer.count == 1)
        #expect(try C.queued(a, kind: NotebookCoverQueue.backfillKind) == 2)
        let first = Self.drawnIDs(drawer)[0]

        // The app quits; the next launch builds a new service over the same store.
        let again = C.Drawer()
        gates.value = Self.on
        let relaunched = C.service(a, drawer: again, gates: gates)
        #expect(await relaunched.runBackfill()[PrivateSyncZones.libraryKey] == .finished(drawn: 2, gaveUp: 0))
        #expect(Set(Self.drawnIDs(again)) == Set(["nb-1", "nb-2", "nb-3"]).subtracting([first]), "where it stopped, never over a cover it drew")
        for id in ["nb-1", "nb-2", "nb-3"] { #expect(try C.serverCover(a, id) != nil) }
        #expect(try C.serverMarker(a)?.state == .done)
    }

    @Test("Before the seed is complete the pass claims nothing and draws nothing")
    func seedNotComplete() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.library(server, "backfill-notready", notebooks: ["nb-1"])
        let drawer = C.Drawer()
        let covers = C.service(a, drawer: drawer)
        try await C.setSeed(a, "pending")
        #expect(await covers.runBackfill()[PrivateSyncZones.libraryKey] == .notReady)
        let marker = try C.serverMarker(a)
        #expect(drawer.count == 0 && marker == nil)
    }

    // MARK: Spaces

    @Test("In a space, only the owner's Mac draws: the marker is in the owner's Library, and a member's Mac never backfills")
    func spaceOwnerOnly() async throws {
        let (server, alice, bob) = try await SpaceSyncTests.team()
        let zone = CloudZoneID("Space-s1")
        server.put([try SpaceSyncTests.record(.notebook, "nb-s", [
            "title": .string("Cells"), "status": .string("active"), "instructions": .string("Read the reviews"),
        ], in: zone)], zone: "Space-s1", owner: "alice")
        try await alice.sync()
        try await bob.sync()
        try await C.setSeed(alice.mac, "complete")
        try await C.setSeed(bob.mac, "complete")
        let spaceKey = SpaceSyncTests.ownedKey

        let bobDrawer = C.Drawer()
        let bobResults = await C.service(bob.mac, drawer: bobDrawer).runBackfill()
        #expect(bobResults.keys.sorted() == [PrivateSyncZones.libraryKey], "a joined space is in the shared database, which no backfill reads")
        #expect(bobDrawer.count == 0)
        #expect(try C.serverMarker(alice.mac, zone: "Space-s1") == nil)

        let drawer = C.Drawer()
        let results = await C.service(alice.mac, drawer: drawer).runBackfill()
        #expect(results[PrivateSyncZones.libraryKey] == .finished(drawn: 0, gaveUp: 0))
        #expect(results[spaceKey] == .finished(drawn: 1, gaveUp: 0))
        #expect(Self.drawnIDs(drawer) == ["nb-s"])
        let marker = try #require(try C.serverMarker(alice.mac, zone: "Space-s1"))
        #expect(marker.state == .done && marker.by == "macaaaaa", "written in the owner's Library")
        let name = RecordNaming.recordName(type: .notebook, id: "nb-s", salt: SpaceSyncTests.spaceSalt)
        let stored = try SyncEnvelope(storedPayload: try #require(server.storedRecord(name, zone: "Space-s1", owner: "alice")?.payload))
        let cover = try #require(NotebookCoverSubject.cover(in: stored))
        #expect(cover.owner == "nb-s" && cover.role == "cover", "the satellite is in the space's own zone and follows the notebook")
    }

    @Test("A space this Mac has not walked to the end is not listed, so the backfill never says done over notebooks it never saw (F16)")
    func unwalkedSpaceIsNotListed() async throws {
        let (server, alice, _) = try await SpaceSyncTests.team()
        server.put([try SpaceSyncTests.record(.notebook, "nb-s", [
            "title": .string("Cells"), "status": .string("active"), "instructions": .string("Read the reviews"),
        ], in: CloudZoneID("Space-s1"))], zone: "Space-s1", owner: "alice")
        try await alice.sync()
        try await C.setSeed(alice.mac, "complete")
        let spaceKey = SpaceSyncTests.ownedKey
        try alice.mac.exec("UPDATE ck_zones SET last_complete_pass_at = NULL WHERE zone_key = '\(spaceKey)'")

        let drawer = C.Drawer()
        let results = await C.service(alice.mac, drawer: drawer).runBackfill()
        #expect(results[spaceKey] == .waiting, "\(results)")
        #expect(drawer.count == 0)
        #expect(try C.serverMarker(alice.mac, zone: "Space-s1")?.state != .done)
    }

    @Test("A cancelled URL load or CloudKit call is a cancellation, not a failed attempt (F17)")
    func cancellationsOfEveryLayer() {
        #expect(NotebookCoverService.isCancellation(CancellationError()))
        #expect(NotebookCoverService.isCancellation(URLError(.cancelled)))
        #expect(NotebookCoverService.isCancellation(CloudError(.operationCancelled, message: "cancelled")))
        #expect(!NotebookCoverService.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!NotebookCoverService.isCancellation(CloudError(.networkUnavailable, message: "offline")))
    }
}
