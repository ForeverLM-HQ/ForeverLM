import Foundation
import Testing
@testable import ForeverLM

/// The orphan janitor and `moveMaps` folding (docs/cloudkit-schema-design.md §5.7, §4.4, D17, D51,
/// R3-m9, R4-m14): never while changes are unfetched; never a stub's children; a late child of a
/// moved record is left for re-homing, also when only a folded entry lists the move; a queued Job
/// never expires. The maintenance Mac's clock is the server's, so days pass by advancing it.
@Suite("Orphan janitor", .serialized)
struct OrphanJanitorTests {
    private typealias F = MaintenanceFixture
    private static let day: TimeInterval = 86_400

    private static func mac(_ server: FakeCloudKit, _ name: String) async throws -> EngineTestDevice {
        let mac = try EngineTestDevice(server, name: name, deviceID: "macaaaaa")
        try await mac.bootstrap()
        try await mac.sync()
        return mac
    }

    private static func entry(_ a: EngineTestDevice, container: String, kind: String = "notebook", item: String = "s1") throws {
        try F.put(a, .entry, "en:\(container):source:\(item)", [
            "containerKind": .value(.string(kind)), "containerID": .value(.string(container)), "itemKind": .value(.string("source")),
            "itemID": .value(.string(item)), "state": .value(.string("active")), "orderKey": .value(.string("a0")),
            "origin": .value(.string("added")), "addedAt": .value(SyncJSON(F.milliseconds(a.server.now))),
        ], at: F.milliseconds(a.server.now))
    }

    private static func exchange(_ a: EngineTestDevice, _ id: String, chat: String) throws {
        try F.put(a, .exchange, id, [
            "chatID": .value(.string(chat)), "seq": .value(SyncJSON(1)), "createdAt": .value(SyncJSON(F.milliseconds(a.server.now))),
            "question": .value(.string("Why?")),
        ], at: F.milliseconds(a.server.now))
    }

    private static func held(_ a: EngineTestDevice, _ type: SyncRecordType, _ id: String, zone: String = "Library") throws -> Bool {
        a.server.storedRecord(RecordNaming.recordName(type: type, id: id, salt: try a.personalSalt() ?? Data()), zone: zone, owner: F.user) != nil
    }

    /// One `moveMaps` entry listing `moves`, uploaded and named on the root as a move job would.
    private static func addMoveMap(_ a: EngineTestDevice, key: String, _ moves: [MoveMapMove]) async throws {
        let server = a.server
        let list = try SyncGzip.decompress(try MoveMapIndex.encodeList(moves), maxBytes: MoveMapIndex.listMaxInflatedBytes)
        let file = try await F.blobs(a, clock: { server.now }).upload(
            list, owner: SyncSchema.rootRecordName, ownerType: .zoneRoot, role: MoveMapIndex.role(forKey: key), mime: "application/json",
            encoding: .gzip, into: .personal(salt: try a.personalSalt() ?? Data()))
        try F.patchRoot(server, ["moveMaps": .elements([key: file.value])], at: F.milliseconds(server.now))
    }

    @Test("Orphans go after 7 days; a NotebookState after 30; none while a zone has unfetched changes")
    func orphansGo() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "janitor-orphans")
        try Self.entry(a, container: "nb-gone")
        try Self.exchange(a, "ex-1", chat: "chat-gone")
        try F.put(a, .notebookState, "ns:nb-gone", ["notebookID": .value(.string("nb-gone"))], at: F.milliseconds(server.now))
        try F.put(a, .notebook, "nb-here", ["title": .value(.string("Cells")), "status": .value(.string("active"))], at: F.milliseconds(server.now))
        try Self.entry(a, container: "nb-here")
        try await a.sync()
        let service = F.service(a, clock: { server.now })

        #expect(try await service.runJanitor() == 0, "found, not yet old")
        server.advance(by: 8 * Self.day)
        // A round that did not reach the end of a zone runs no janitor.
        let skipped = await service.tick(caughtUp: false)
        #expect(skipped.holdsLease)
        #expect(skipped.janitorDeleted == 0)
        #expect(try Self.held(a, .entry, "en:nb-gone:source:s1"))
        #expect(try await service.runJanitor() == 2)
        #expect(try !Self.held(a, .entry, "en:nb-gone:source:s1"))
        #expect(try !Self.held(a, .exchange, "ex-1"))
        #expect(try Self.held(a, .entry, "en:nb-here:source:s1"))
        #expect(try Self.held(a, .notebookState, "ns:nb-gone"), "per-member state waits 30 days")
        #expect(try a.count("SELECT COUNT(*) FROM ck_records WHERE record_type = 'Entry'") == 1, "the replica forgot the deleted ones")
        server.advance(by: 23 * Self.day)
        #expect(try await service.runJanitor() == 1)
        #expect(try !Self.held(a, .notebookState, "ns:nb-gone"))
    }

    @Test("A merged or moved notebook's stub is never gone, so its Entries stay")
    func stubsAreNotGone() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "janitor-stubs")
        try F.put(a, .notebook, "nb-merged", ["title": .value(.string("A")), "status": .value(.string("merged")), "mergedInto": .value(.string("nb-b"))],
                  at: F.milliseconds(server.now))
        try F.put(a, .notebook, "nb-moved", ["title": .value(.string("C")), "status": .value(.string("moved")), "movedTo": .value(.string("Space-1"))],
                  at: F.milliseconds(server.now))
        try Self.entry(a, container: "nb-merged")
        try Self.entry(a, container: "nb-moved")
        try await a.sync()
        let service = F.service(a, clock: { server.now })
        _ = try await service.runJanitor()
        server.advance(by: 40 * Self.day)
        #expect(try await service.runJanitor() == 0)
        #expect(try Self.held(a, .entry, "en:nb-merged:source:s1"))
        #expect(try Self.held(a, .entry, "en:nb-moved:source:s1"))
    }

    @Test("A Library Exchange of a moved chat and a Lesson of a homed course are left for re-homing, never collected")
    func movedParentsArePresent() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "janitor-moved")
        let at = F.milliseconds(server.now)
        try await Self.addMoveMap(a, key: "job1.1", [
            MoveMapMove(type: "Chat", id: "chat-moved", from: "Library", to: "Space-1", at: at),
            MoveMapMove(type: "Course", id: "crs-homed", from: "Library", to: "Space-1", at: at),
        ])
        try Self.exchange(a, "ex-late", chat: "chat-moved")
        try F.put(a, .lesson, "les-late", ["courseID": .value(.string("crs-homed")), "title": .value(.string("Membranes")),
                                           "orderKey": .value(.string("a0")), "kind": .value(.string("lecture"))], at: at)
        try await a.sync()
        let service = F.service(a, clock: { server.now })
        _ = try await service.runJanitor()
        server.advance(by: 40 * Self.day)
        #expect(try await service.runJanitor() == 0)
        #expect(try Self.held(a, .exchange, "ex-late"))
        #expect(try Self.held(a, .lesson, "les-late"))
    }

    @Test("Past 32 entries moveMaps folds into one, and a parent listed only in the folded entry counts as present")
    func foldedEntriesStillCount() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "janitor-fold")
        let at = F.milliseconds(server.now)
        for pass in 1...33 {
            try await Self.addMoveMap(a, key: "job\(pass).1", [MoveMapMove(type: "Chat", id: "chat-\(pass)", from: "Library", to: "Space-\(pass)", at: at + Int64(pass))])
        }
        try Self.exchange(a, "ex-5", chat: "chat-5")
        try await a.sync()
        let service = F.service(a, clock: { server.now })
        let library = try #require(try await service.zone(PrivateSyncZones.libraryKey))
        #expect(try await service.foldMoveMaps(in: library))
        let root = try #require(try F.stored(server, SyncSchema.rootRecordName))
        let entries = MoveMapIndex.entries(of: root)
        #expect(entries.map(\.key) == ["folded.1"])
        #expect(root.fields["moveMaps"]?.objectValue?["job5.1"] == .null, "the folded keys are cleared in the same save")
        #expect(try await service.foldMoveMaps(in: library) == false, "one entry is not folded again")

        // A Mac that never read the old entries learns the move from the folded one.
        let fresh = MoveMapIndex()
        let salt = try #require(try a.personalSalt())
        #expect(await fresh.refresh(from: root, fetch: MoveMapIndex.transportFetch(a.transport, salt: salt)).isEmpty)
        #expect(fresh.retarget(type: "Chat", id: "chat-5", from: "Library") == "Space-5")
        let other = try EngineTestDevice(server, name: "janitor-fold-b", deviceID: "macbbbbb")
        try await other.bootstrap(.macWithoutLibrary)
        try await other.sync()
        let otherService = F.service(other, clock: { server.now })
        _ = try await otherService.runJanitor()
        server.advance(by: 40 * Self.day)
        #expect(try await otherService.runJanitor() == 0)
        #expect(try Self.held(a, .exchange, "ex-5"))
    }

    @Test("A queued Job past expiresAt that no Mac claimed is kept, with its pdf satellites; a finished one goes")
    func queuedJobsNeverExpire() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "janitor-jobs")
        let file = try await F.blobs(a, clock: { server.now }).upload(
            Data("a scan from the phone".utf8), owner: "src_scan", ownerType: .source,
            role: "pdf", mime: "application/pdf", encoding: .identity, into: .personal(salt: try a.personalSalt() ?? Data()))
        let expired = F.milliseconds(server.now) + Int64(7 * Self.day * 1_000)
        func job(_ id: String, _ status: String, params: [String: SyncJSON] = [:]) throws {
            try F.put(a, .job, id, [
                "kind": .value(.string("ingestFile")), "params": .value(.object(params)), "status": .value(.string(status)),
                "requestedBy": .value(.object(["device": .string("iphonaaa"), "platform": .string("ios")])),
                "requestedAt": .value(SyncJSON(F.milliseconds(server.now))), "expiresAt": .value(SyncJSON(expired)),
            ], at: F.milliseconds(server.now))
        }
        try job("job-queued", "queued", params: ["file": file.value, "capture": .string("scan")])
        try job("job-done", "done")
        try job("job-failed", "failed")
        try await a.sync()
        let service = F.service(a, clock: { server.now })
        #expect(try await service.runJanitor() == 0, "not expired yet")
        server.advance(by: 8 * Self.day)
        #expect(try await service.runJanitor() == 2)
        #expect(try Self.held(a, .job, "job-queued"))
        #expect(try !Self.held(a, .job, "job-done"))
        #expect(try !Self.held(a, .job, "job-failed"))
        _ = try await service.collectSatellites(in: "private/Content")
        server.advance(by: 61 * Self.day)
        #expect(try await service.collectSatellites(in: "private/Content").deleted == 0)
        #expect(try F.onServer(a, file), "the waiting Job still names its pdf")
    }

    @Test("A record named with another salt is parked on arrival and deleted by the janitor")
    func foreignSaltRecords() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "janitor-salt")
        let stale = try F.put(a, .notebook, "nb-stale", ["title": .value(.string("Old salt")), "status": .value(.string("active"))],
                              salt: Data(repeating: 9, count: 32))
        try await a.sync()
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = 'foreignSalt'") == 1)
        #expect(try a.count("SELECT COUNT(*) FROM ck_records WHERE record_type = 'Notebook'") == 0, "never applied")
        #expect(try await F.service(a, clock: { server.now }).runJanitor() == 1)
        #expect(server.storedRecord(stale.id.recordName, zone: "Library", owner: F.user) == nil)
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine") == 0)
    }
}
