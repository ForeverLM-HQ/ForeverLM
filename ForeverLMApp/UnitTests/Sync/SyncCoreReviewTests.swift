import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The findings of the schema-v2 sync core review (docs/cloudkit-schema-design.md, "Corrections made while
/// building", COREFIX): each test failed on the code before its fix.
@Suite("Sync core review fixes", .serialized)
struct SyncCoreReviewTests {
    private typealias Device = EngineTestDevice

    private static func pair() async throws -> (server: FakeCloudKit, a: Device, b: Device) {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "core-a", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        let b = try Device(server, name: "core-b", deviceID: "macbbbbb")
        _ = try await b.bootstrap(.macWithoutLibrary)
        return (server, a, b)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    // MARK: B2

    @Test("B2: CKSyncEngine's fetch leaves the engine's zones unfetched until the coordinator marks them, and marking empties the set")
    func unfetchedZonesAreClearedByTheEnginePath() async throws {
        let (server, a, _) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        let c = try Device(server, name: "core-c", deviceID: "maccccca")
        _ = try await c.bootstrap(.macWithoutLibrary)
        for zone in PrivateSyncZones.engineZones {
            guard case .success(let page) = try await c.transport.zoneChanges(zone, in: .private) else { Issue.record("no page"); continue }
            try await c.engine.absorbFetched(page.modified, deleted: [], in: zone, passStart: Date())
        }
        #expect(await c.engine.unfetchedZones.count == 2, "absorbing a delivery does not say the fetch ended")
        await c.engine.markFetched(PrivateSyncZones.engineZones)
        #expect(await c.engine.unfetchedZones.isEmpty)
        await c.engine.markUnfetched([PrivateSyncZones.catalog])
        #expect(await c.engine.unfetchedZones == [PrivateSyncZones.catalog], "a failed or started fetch is not caught up")
    }

    // MARK: M1

    @Test("M1: an engine request the pacer refused does not keep SpaceSync and BlobStore waiting behind it")
    func refusedEngineRequestGivesUpItsPlace() async throws {
        let (server, a, _) = try await Self.pair()
        _ = server
        let clock = TestClock(Date())
        var configuration = SyncPacerState.Configuration()
        configuration.capacity = 2
        configuration.refillPerSecond = 10
        let pacer = SyncPacer(configuration: configuration, clock: { clock.now })
        let engine = PrivateSyncEngine(transport: a.transport, store: a.local, pacer: pacer, deviceID: a.deviceID,
                                       clock: { clock.now.addingTimeInterval(Device.ahead) })
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        _ = try await engine.feed()
        _ = await pacer.request(.engine, writes: true)
        _ = await pacer.request(.engine, writes: true)    // the bucket is empty now
        try await engine.sendChanges()                    // asks, is told to wait, and gives up its place
        clock.advance(3_600)
        #expect(await pacer.request(.spaces, writes: false).isGo, "SpaceSync still waited on the engine an hour later")
        #expect(await pacer.request(.blobs, writes: true).isGo)
    }

    // MARK: M2 and M8

    private func poisonedPage() async throws -> (server: FakeCloudKit, c: Device, page: CloudZoneChanges) {
        let (server, a, _) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('good', 'Fine'); INSERT INTO test_courses (id, title) VALUES ('poison', 'Bad');")
        try await a.sync()
        let c = try Device(server, name: "core-poison", deviceID: "maccccca")
        _ = try await c.bootstrap(.macWithoutLibrary)
        try c.exec("CREATE TRIGGER poison_guard BEFORE INSERT ON test_courses WHEN NEW.title = 'Bad' BEGIN SELECT RAISE(ABORT, 'poison'); END;")
        guard case .success(let page) = try await c.transport.zoneChanges(PrivateSyncZones.library, in: .private) else {
            throw CloudError(.internalError, message: "no page")
        }
        return (server, c, page)
    }

    @Test("M2: a record whose projection throws is parked and the rest of its page is applied")
    func oneThrowingRecordDoesNotLoseThePage() async throws {
        let (_, c, page) = try await poisonedPage()
        try await c.engine.absorbFetched(page.modified, deleted: [], in: PrivateSyncZones.library, passStart: Date())
        #expect(try c.text("SELECT title FROM test_courses WHERE id = 'good'") == "Fine", "the page's good record was lost with the bad one")
        #expect(try c.count("SELECT COUNT(*) FROM test_courses WHERE id = 'poison'") == 0)
        #expect(try c.count("SELECT COUNT(*) FROM ck_records WHERE record_type = 'Course'") == 2, "both records stay in the replica, raw")
        #expect(try c.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = ?", [.text(InboundApply.projectionFailedReason)]) == 1)
    }

    @Test("M8: what a build parked is applied again by the next build, once")
    func upgradeAppliesParkedRecords() async throws {
        let (_, c, page) = try await poisonedPage()
        var first = PrivateSyncEngine.Configuration()
        first.buildRevision = "build-1"
        let engine1 = PrivateSyncEngine(transport: c.transport, store: c.local, pacer: SyncPacer(), deviceID: c.deviceID, configuration: first)
        try await engine1.absorbFetched(page.modified, deleted: [], in: PrivateSyncZones.library, passStart: Date())
        #expect(try await engine1.reapplyAfterUpgrade() == 1, "the first run of a build looks at what is parked")
        #expect(try c.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = ?", [.text(InboundApply.projectionFailedReason)]) == 1, "still failing: parked again")
        #expect(try await engine1.reapplyAfterUpgrade() == 0, "the same build does not look twice")

        try c.exec("DROP TRIGGER poison_guard")
        #expect(try await engine1.reapplyAfterUpgrade() == 0, "nor does a fix to the data count as a new build")
        var second = PrivateSyncEngine.Configuration()
        second.buildRevision = "build-2"
        let engine2 = PrivateSyncEngine(transport: c.transport, store: c.local, pacer: SyncPacer(), deviceID: c.deviceID, configuration: second)
        #expect(try await engine2.reapplyAfterUpgrade() == 1)
        #expect(try c.text("SELECT title FROM test_courses WHERE id = 'poison'") == "Bad", "the parked record is projected by the new build")
        #expect(try c.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = ?", [.text(InboundApply.projectionFailedReason)]) == 0)
        #expect(try c.outboxRows() == 0, "applying again writes nothing back")
    }

    @Test("M8: a record type the last build only held is projected once a build has a projection for it")
    func upgradeNotebooksNewlyKnownTypes() async throws {
        let (server, a, _) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        let c = try Device(server, name: "core-types", deviceID: "maccccca")
        _ = try await c.bootstrap(.macWithoutLibrary)
        // The older build knows no record type: it holds every record raw.
        let oldStore = MacPrivateSyncStore.direct(c.store, registry: ProjectionRegistry([]))
        var old = PrivateSyncEngine.Configuration()
        old.buildRevision = "old"
        let oldEngine = PrivateSyncEngine(transport: c.transport, store: oldStore, pacer: SyncPacer(), deviceID: c.deviceID, configuration: old)
        try await oldEngine.reapplyAfterUpgrade()
        guard case .success(let page) = try await c.transport.zoneChanges(PrivateSyncZones.library, in: .private) else { Issue.record("no page"); return }
        try await oldEngine.absorbFetched(page.modified, deleted: [], in: PrivateSyncZones.library, passStart: Date())
        #expect(try c.count("SELECT COUNT(*) FROM test_courses") == 0)
        #expect(try c.count("SELECT COUNT(*) FROM ck_records WHERE record_type = 'Course'") == 1)

        var current = PrivateSyncEngine.Configuration()
        current.buildRevision = "new"
        let engine = PrivateSyncEngine(transport: c.transport, store: c.local, pacer: SyncPacer(), deviceID: c.deviceID, configuration: current)
        #expect(try await engine.reapplyAfterUpgrade() == 1)
        #expect(try c.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")
        #expect(try c.outboxRows() == 0)
    }

    // MARK: M3

    @Test("M3: five separate conflicts, each resolved and sent again, do not park the record")
    func conflictRoundsResetOnSuccess() async throws {
        let (server, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        try await b.sync()
        await EngineTestDriver.pause()
        let name = try a.recordName(.course, "c1")
        for round in 1...6 {
            let serverCopy = try #require(server.storedRecord(name, zone: "Library", owner: "alice"))
            server.failRecord(name, times: 1, with: CloudError(.serverRecordChanged, serverRecord: serverCopy))
            try a.exec("UPDATE test_courses SET title = 'T\(round)' WHERE id = 'c1'")
            await EngineTestDriver.pause()
            try await a.send()
            #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = 'conflict'") == 0, "parked at round \(round)")
            #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("T\(round)"))
        }
    }

    // MARK: M4

    @Test("M4: a record over the payload cap is parked and the rest of the library still goes out; it goes when it fits")
    func oversizeRecordIsParked() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "core-big", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        var generator = SystemRandomNumberGenerator()
        let big = Data((0..<400_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('big', '\(big)')")
        await EngineTestDriver.pause()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('small', 'Fine')")
        try await a.sync()
        #expect(try a.serverEnvelope(.course, "small") != nil, "one oversize record blocked every send")
        #expect(try a.serverEnvelope(.course, "big") == nil)
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = ?", [.text(OutboxFeeder.payloadTooLargeReason)]) == 1)
        #expect(try a.outboxRows() > 0, "its rows wait for it to shrink")

        await EngineTestDriver.pause()
        try a.exec("UPDATE test_courses SET title = 'Short' WHERE id = 'big'")
        try await a.sync()
        try await a.sync()
        #expect(try a.serverEnvelope(.course, "big")?.fields["title"] == .string("Short"))
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = ?", [.text(OutboxFeeder.payloadTooLargeReason)]) == 0)
        #expect(try a.outboxRows() == 0)
    }

    // MARK: M5

    @Test("M5: an X patch whose value is larger goes out although the server's stamp is later")
    func xPatchWithLargerValueWins() async throws {
        let (_, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'One')")
        try await a.sync()
        try await b.sync()
        await EngineTestDriver.pause()
        let old = Date().addingTimeInterval(-3600)
        let late = SyncStamp(policy: .maximum, milliseconds: SyncTime.milliseconds(Date()) + 1_000, counter: 0, deviceID: "macaaaaa")
        try PendingPatch(changes: ["editedAt": .number(1_000)], stamps: ["editedAt": .value(late)], zoneKey: "private/Library", type: "Course", wireID: "c1")
            .save(in: a.store, now: old)
        try await a.sync()
        #expect(try a.serverEnvelope(.course, "c1")?.fields["editedAt"] == .number(1_000))
        // B was offline: it holds a larger value under an earlier stamp.
        let early = SyncStamp(policy: .maximum, milliseconds: SyncTime.milliseconds(Date()) - 1_000, counter: 0, deviceID: "macbbbbb")
        try PendingPatch(changes: ["editedAt": .number(2_000)], stamps: ["editedAt": .value(early)], zoneKey: "private/Library", type: "Course", wireID: "c1")
            .save(in: b.store, now: old)
        try await b.sync()
        try await b.sync()
        #expect(try b.serverEnvelope(.course, "c1")?.fields["editedAt"] == .number(2_000), "the larger X value never reached the server")
        #expect(try b.count("SELECT COUNT(*) FROM ck_patches") == 0)
        // And the smaller one, stamped later, does not take it back.
        let later = SyncStamp(policy: .maximum, milliseconds: SyncTime.milliseconds(Date()) + 5_000, counter: 0, deviceID: "macaaaaa")
        try PendingPatch(changes: ["editedAt": .number(500)], stamps: ["editedAt": .value(later)], zoneKey: "private/Library", type: "Course", wireID: "c1")
            .save(in: a.store, now: old)
        try await a.sync()
        try await a.sync()
        #expect(try a.serverEnvelope(.course, "c1")?.fields["editedAt"] == .number(2_000))
    }

    // MARK: M6

    @Test("M6: records the server refuses for good are parked after three tries and the rest of the library goes out")
    func refusedRecordsDoNotStarveTheOthers() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "core-poison-send", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        var sql = "BEGIN;"
        for index in 0..<450 { sql += "INSERT INTO test_courses (id, title) VALUES ('c\(index)', 'Course \(index)');" }
        try a.exec(sql + "COMMIT;")
        for index in 0..<250 { server.failRecord(try a.recordName(.course, "c\(index)"), times: 100_000, with: CloudError(.invalidArguments)) }
        try await a.sync()
        let onServer = server.recordNames(zone: "Library", owner: "alice").count
        #expect(onServer >= 201, "only \(onServer - 1) of the 200 good records went out")
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = ?", [.text(PrivateSyncEngine.rejectedReason)]) == 250)
        #expect(try a.outboxRows() > 0, "the refused ones keep their rows for the next launch")
    }

    // MARK: M7

    @Test("M7: a delete handed out before a quit does not block the record the learner brings back")
    func staleHandedOutDeleteIsForgotten() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "core-pending-delete", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'One')")
        try await a.sync()
        await EngineTestDriver.pause()
        try a.exec("DELETE FROM test_courses WHERE id = 'c1'")
        _ = try await a.engine.feed()           // the delete is handed out: a ck_pending_deletes row
        #expect(try a.count("SELECT COUNT(*) FROM ck_pending_deletes") == 1)
        // The process quits before anything went out; the learner adds the record again.
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Back')")
        await EngineTestDriver.pause()
        let relaunched = PrivateSyncEngine(transport: a.transport, store: a.local, pacer: SyncPacer(), deviceID: a.deviceID,
                                           clock: { Date().addingTimeInterval(Device.ahead) })
        try await relaunched.sendChanges()
        try await relaunched.sendChanges()
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Back"))
        #expect(try a.outboxRows() == 0)
    }

    // MARK: m1

    @Test("m1: a save that would overflow the request is left out of its changes too")
    func batchOverflowStopsTheLoop() async throws {
        let server = EngineTestDriver.server()
        var configuration = PrivateSyncEngine.Configuration()
        configuration.batchMaxBytes = 600
        let a = try Device(server, name: "core-batch", deviceID: "macaaaaa", configuration: configuration)
        _ = try await a.bootstrap()
        var sql = "BEGIN;"
        for index in 0..<5 { sql += "INSERT INTO test_courses (id, title) VALUES ('c\(index)', '\(String(repeating: "x", count: 400))');" }
        try a.exec(sql + "COMMIT;")
        _ = try await a.engine.feed()
        let batch = try await a.engine.nextBatch(limit: 200)
        #expect(batch.changes.count == batch.saves.count + batch.deletes.count)
    }

    // MARK: m3

    @Test("m3: a delete's echo guard is dated by the server's clock, whatever this Mac's says")
    func echoGuardUsesServerTime() async throws {
        let server = FakeCloudKit(start: Date().addingTimeInterval(3_600))
        let a = try Device(server, name: "core-echo", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'One')")
        try await a.sync()
        await EngineTestDriver.pause()
        try a.exec("DELETE FROM test_courses WHERE id = 'c1'")
        try await a.sync()
        var until: Double?
        try a.store.query("SELECT until FROM ck_echo", []) { until = $0.real(0) }
        let deletedAt = try #require(until) - Double(SyncSchema.Limits.echoSuppressionDays) * 86_400
        let serverNow = Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate
        #expect(abs(deletedAt - serverNow) < 120, "the guard was dated \(Int(deletedAt - serverNow)) s from the server's clock")
    }

    @Test("m3: an echo guard that ran out is removed when the engine starts")
    func expiredEchoGuardsGo() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "core-echo-gc", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        let now = Date().timeIntervalSinceReferenceDate
        try a.exec("INSERT INTO ck_echo (zone_key, record_name, change_tag, until) VALUES ('private/Library', 'old', NULL, \(now - 10)), ('private/Library', 'live', NULL, \(now + 86_400))")
        _ = try await a.engine.feed()
        #expect(try a.count("SELECT COUNT(*) FROM ck_echo WHERE record_name = 'old'") == 0)
        #expect(try a.count("SELECT COUNT(*) FROM ck_echo WHERE record_name = 'live'") == 1)
    }

    // MARK: m4

    @Test("m4: a device without a server offset knows it, and the next bootstrap learns one")
    func missingServerOffsetIsRetried() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "core-offset-a", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        let b = try Device(server, name: "core-offset-b", deviceID: "macbbbbb")
        _ = try await b.bootstrap(.macWithoutLibrary)
        #expect(try !b.store.replica.lacksServerOffset())
        // A bootstrap whose two probes lost to a busy root leaves the device as one that never had a sample.
        try b.exec("DELETE FROM ck_clock")
        #expect(try b.store.replica.lacksServerOffset(), "a device that cannot mint stamps must say so")
        _ = try await b.bootstrap(.macWithoutLibrary)
        #expect(try !b.store.replica.lacksServerOffset())
    }

    // MARK: m5

    /// A transport that lets the suite act between a fetch's answer and its application.
    private final class AfterZoneChanges: CloudTransport, @unchecked Sendable {
        let base: CloudTransport
        let hook: @Sendable () async throws -> Void
        private let lock = NSLock()
        private var fired = false

        init(_ base: CloudTransport, hook: @escaping @Sendable () async throws -> Void) {
            self.base = base
            self.hook = hook
        }

        var containerIdentifier: String { base.containerIdentifier }
        func accountStatus() async throws -> CKAccountStatus { try await base.accountStatus() }
        func userRecordName() async throws -> String { try await base.userRecordName() }
        func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] { try await base.allZones(in: database) }
        func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
            try await base.modifyZones(saving: saving, deleting: deleting, in: database)
        }
        func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
            try await base.databaseChanges(in: database, since: token, resultsLimit: resultsLimit)
        }
        func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
            let results = try await base.zoneChanges(requests, in: database)
            let first = lock.withLock { () -> Bool in
                defer { fired = true }
                return !fired
            }
            if first { try await hook() }
            return results
        }
        func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
            try await base.records(ids, in: database, desiredKeys: desiredKeys)
        }
        func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                           savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
            try await base.modifyRecords(saving: saving, deleting: deleting, in: database, savePolicy: savePolicy, atomically: atomically)
        }
    }

    @Test("m5: a page the transport fetched before CKSyncEngine delivered a newer version does not take the record back")
    func olderPageDoesNotRegressADeliveredRecord() async throws {
        let (server, a, _) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Old')")
        try await a.sync()
        let c = try Device(server, name: "core-m5", deviceID: "maccccca")
        _ = try await c.bootstrap(.macWithoutLibrary)
        let holder = EngineHolder()
        let hooked = AfterZoneChanges(c.transport) { [a, c, holder] in
            // While the page of "Old" is on its way to be applied, the record changes and CKSyncEngine delivers it.
            await EngineTestDriver.pause()
            try a.exec("UPDATE test_courses SET title = 'New' WHERE id = 'c1'")
            try await a.sync()
            guard case .success(let page) = try await c.transport.zoneChanges(PrivateSyncZones.library, in: .private) else { return }
            try await holder.engine?.absorbFetched(page.modified, deleted: [], in: PrivateSyncZones.library, passStart: Date())
        }
        let engine = PrivateSyncEngine(transport: hooked, store: c.local, pacer: SyncPacer(), deviceID: c.deviceID)
        holder.engine = engine
        try await engine.fetchChanges()
        #expect(try c.text("SELECT title FROM test_courses WHERE id = 'c1'") == "New", "the older page took the record back")
    }

    private final class EngineHolder: @unchecked Sendable {
        var engine: PrivateSyncEngine?
    }

    // MARK: m10

    @Test("m10: a record the server deleted takes its pinned stamps with it, so an edit that was on its way drains")
    func deletedRecordLeavesNoPins() async throws {
        let (_, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'One')")
        try await a.sync()
        try await b.sync()
        await EngineTestDriver.pause()
        try b.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        // Handed out by a feeder pass whose engine is gone (a quit): its stamp is pinned, nothing went out.
        let handedOut = try await b.local.perform { try $0.nextChanges(now: Date().addingTimeInterval(Device.ahead), limit: 100, scope: .privateZones) }
        #expect(!handedOut.isEmpty)
        #expect(try b.count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(OutboxFeeder.pinSource)]) > 0)
        try a.exec("DELETE FROM test_courses WHERE id = 'c1'")
        try await a.sync()
        try await b.sync()
        try await b.sync()
        #expect(try b.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c1'") == 0)
        #expect(try b.count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(OutboxFeeder.pinSource)]) == 0)
        #expect(try b.outboxRows() == 0)
    }
}

/// Pins held the rows of a record that had nothing left to send for ever (2026-10-25: three Catalog sources,
/// the oldest since 10-12). A pin is the stamp a handed-out change will be sent with; the feeder settles a
/// record whose rows already equal the server's only when its pins are current, and compared a pin of a path
/// no pending row feeds with the record's `latest`, which moves whenever any other row of the record does.
@Suite("A pin no pending row feeds does not hold a settled record", .serialized)
struct StalePinTests {
    private static let pinKey = OutboxFeeder.pinKey(zoneKey: OutboxTestProjections.libraryZoneKey, type: .course, wireID: "c1")

    /// A course the server holds as the device has it: nothing pending, no pin.
    private static func syncedCourse() async throws -> EngineTestDevice {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "stale-pin", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        #expect(try a.outboxRows() == 0)
        #expect(try a.pinCount() == 0)
        return a
    }

    @Test("A pin on a path with no row of its own is settled with a record whose rows equal the server's")
    func pinOfAPathNoRowFeedsSettles() async throws {
        let a = try await Self.syncedCourse()
        // The title was edited and put back: its row waits, the record equals what the server holds. The
        // status has no row, only a pin an earlier hand-out left (the live case: `ingest`, `madeBy`).
        try a.exec("UPDATE test_courses SET title = 'Cells II' WHERE id = 'c1'")
        try a.exec("UPDATE test_courses SET title = 'Cells' WHERE id = 'c1'")
        try a.exec("""
            INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at, stamp, seen)
            VALUES ('\(OutboxFeeder.pinSource)', '\(Self.pinKey)', 'status', \(Date().timeIntervalSinceReferenceDate - 600), NULL, NULL)
        """)
        #expect(try a.outboxRows() == 1)
        #expect(try a.pinCount() == 1)

        await EngineTestDriver.pause()
        try await a.engine.feed()
        #expect(try a.outboxRows() == 0, "nothing is left to send, so the rows go")
        #expect(try a.pinCount() == 0, "and the pin with them")
    }

    @Test("A pin older than a later edit of its own path still waits for its change, as before")
    func revertedEditStillWaits() async throws {
        let a = try await Self.syncedCourse()
        try a.exec("UPDATE test_courses SET title = 'Cells II' WHERE id = 'c1'")
        await EngineTestDriver.pause()
        try await a.engine.feed()
        #expect(try a.pinCount() >= 1, "the change is handed out with a pinned stamp")

        // The edit is put back while that change is on its way: the record equals the server's again, but
        // the change may still land, so its rows and pin stay until its acknowledgement settles them.
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_courses SET title = 'Cells' WHERE id = 'c1'")
        await EngineTestDriver.pause()
        try await a.engine.feed()
        #expect(try a.outboxRows() >= 1)
        #expect(try a.pinCount() >= 1)
    }
}
