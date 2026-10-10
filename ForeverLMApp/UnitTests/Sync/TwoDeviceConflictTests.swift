import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Two FakeCloudKit clients of one account editing the same records (docs/cloudkit-schema-design.md
/// §6.2, §6.3, D9): per-column event times, a far-future clock, and two creates of one deterministic
/// record. Both Macs converge on the same values and the server holds them.
@Suite("Two-device conflicts", .serialized)
struct TwoDeviceConflictTests {
    private typealias Device = EngineTestDevice

    private static func pair() async throws -> (FakeCloudKit, Device, Device) {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "conflict-a", deviceID: "macaaaaa")
        try await a.bootstrap()
        let b = try Device(server, name: "conflict-b", deviceID: "macbbbbb")
        try await b.bootstrap(.macWithoutLibrary)
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        try await b.sync()
        await EngineTestDriver.pause()
        return (server, a, b)
    }

    private static func row(_ device: Device) throws -> String? {
        try device.text("SELECT title || '/' || status FROM test_courses WHERE id = 'c1'")
    }

    @Test("t0/t1/t2: an offline change at t0 keeps t0 although another column of its row changed at t2, so the remote t1 edit wins")
    func perColumnTimes() async throws {
        let (_, a, b) = try await Self.pair()
        try a.exec("UPDATE test_courses SET title = 'Offline at t0' WHERE id = 'c1'")
        await EngineTestDriver.pause()
        try b.exec("UPDATE test_courses SET title = 'Remote at t1' WHERE id = 'c1'")
        try await b.sync()
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        try await a.sync()
        try await b.sync()
        let server = try #require(try a.serverEnvelope(.course, "c1"))
        #expect(server.fields["title"] == .string("Remote at t1"), "a row-level time would have re-dated t0 to t2")
        #expect(server.fields["status"] == .string("archived"))
        #expect(try Self.row(a) == "Remote at t1/archived")
        #expect(try Self.row(b) == "Remote at t1/archived")
        #expect(try a.outboxRows() == 0)
        #expect(try b.outboxRows() == 0)
    }

    @Test("An edit made after seeing a far-future stamp beats it, through a conflict as well, and both Macs converge")
    func farFutureStamp() async throws {
        let (_, a, b) = try await Self.pair()
        // B's clock is ten years ahead of the server.
        try b.store.replica.saveClock(StampClock(deviceID: "macbbbbb", offsetSamples: [10 * 365 * 86_400_000]))
        try b.exec("UPDATE test_courses SET title = 'From the future' WHERE id = 'c1'")
        try await b.sync()
        let future = try #require(try a.serverEnvelope(.course, "c1"))
        guard case .value(let futureStamp)? = future.stamps["title"] else { Issue.record("no stamp"); return }
        #expect(futureStamp.milliseconds > SyncTime.milliseconds(Date()) + 365 * 86_400_000)

        try await a.fetch()
        #expect(try Self.row(a) == "From the future/active")
        await EngineTestDriver.pause()
        // B moves another field before A sends, so A's save meets a newer server record and merges.
        try b.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        try await b.sync()
        try a.exec("UPDATE test_courses SET title = 'Seen it, changed it' WHERE id = 'c1'")
        try await a.send()
        try await b.sync()
        let held = try #require(try a.serverEnvelope(.course, "c1"))
        #expect(held.fields["title"] == .string("Seen it, changed it"))
        #expect(held.fields["status"] == .string("archived"))
        if case .value(let stamp)? = held.stamps["title"] {
            #expect(stamp.milliseconds <= SyncTime.milliseconds(Date()) + Int64(SyncSchema.Limits.receivedStampFutureClampMs) + 60_000,
                    "A's stamp is clamped near now + 1 day, never ten years out")
        }
        #expect(try Self.row(a) == "Seen it, changed it/archived")
        #expect(try Self.row(b) == "Seen it, changed it/archived")
    }

    @Test("Two Macs create the same deterministic record: the second create merges with the first, and both converge on the later edit")
    func concurrentCreates() async throws {
        let (_, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_lessons (id, course_id, title, order_key) VALUES ('l1', 'c1', 'Membranes', 'a0')")
        try await a.sync()
        try await b.sync()
        try a.exec("INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES ('xa', 'l1', 's1', 'approved', 'a0')")
        await EngineTestDriver.pause()
        try b.exec("INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES ('xb', 'l1', 's1', 'pending', 'a5')")
        try await a.send()
        try await b.sync()
        try await a.sync()
        let entryID = OutboxTestProjections.Entries.entryID(lessonID: "l1", itemID: "s1")
        let held = try #require(try a.serverEnvelope(.entry, entryID))
        #expect(held.fields["approval"] == .string("pending"))
        #expect(held.fields["orderKey"] == .string("a5"))
        for device in [a, b] {
            #expect(try device.text("SELECT approval || '/' || order_key FROM test_entries WHERE lesson_id = 'l1' AND item_id = 's1'") == "pending/a5")
            #expect(try device.outboxRows() == 0)
        }
    }
}
