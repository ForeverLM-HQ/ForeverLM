import Foundation
import Testing
@testable import ForeverLM

/// A sleep the suite wakes by hand: each call parks until `wake()`, and the requested seconds are kept.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                requested.append(seconds)
                waiting.append(continuation)
            }
        }
    }

    var sleeping: Int { lock.withLock { waiting.count } }

    func wake() {
        let toWake = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }
        for continuation in toWake { continuation.resume() }
    }
}

final class RoundCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func tick() { lock.withLock { value += 1 } }
}

/// Waits until `condition` holds, up to two seconds.
func eventuallyHolds(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@Suite("Sync rounds keep coming (B1)", .serialized)
struct SyncRoundLoopTests {
    @Test("A foreground runs a round at once and the timer runs one every interval after it")
    func timerKeepsRounding() async {
        let sleeper = ManualSleeper()
        let rounds = RoundCounter()
        let loop = SyncRoundLoop(interval: 900, sleep: { await sleeper.sleep($0) }, round: { rounds.tick() })
        await loop.foreground()
        #expect(rounds.count == 1)
        #expect(await eventuallyHolds { sleeper.sleeping == 1 })
        #expect(sleeper.requested.first == 900)
        sleeper.wake()
        #expect(await eventuallyHolds { rounds.count == 2 })
        #expect(await eventuallyHolds { sleeper.sleeping == 1 })
        sleeper.wake()
        #expect(await eventuallyHolds { rounds.count == 3 })
    }

    @Test("A start that already ran its first round asks for no second one, and the timer still runs")
    func foregroundWithoutARound() async {
        let sleeper = ManualSleeper()
        let rounds = RoundCounter()
        let loop = SyncRoundLoop(interval: 900, sleep: { await sleeper.sleep($0) }, round: { rounds.tick() })
        await loop.foreground(roundNow: false)
        #expect(rounds.count == 0)
        #expect(await loop.isTiming)
        #expect(await eventuallyHolds { sleeper.sleeping == 1 })
        sleeper.wake()
        #expect(await eventuallyHolds { rounds.count == 1 })
    }

    @Test("Leaving the foreground stops the timer and a waiting write's round")
    func backgroundStops() async {
        let sleeper = ManualSleeper()
        let rounds = RoundCounter()
        let loop = SyncRoundLoop(interval: 900, sleep: { await sleeper.sleep($0) }, round: { rounds.tick() })
        await loop.foreground(roundNow: false)
        await loop.wrote(dueIn: 3)
        #expect(await eventuallyHolds { sleeper.sleeping == 2 })
        await loop.background()
        #expect(await !loop.isTiming)
        sleeper.wake()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rounds.count == 0)
    }

    @Test("Writes in quick succession share one round, a little past the newest one's debounce")
    func writesShareARound() async {
        let sleeper = ManualSleeper()
        let rounds = RoundCounter()
        let loop = SyncRoundLoop(interval: 900, sleep: { await sleeper.sleep($0) }, round: { rounds.tick() })
        await loop.wrote(dueIn: 2)
        await loop.wrote(dueIn: 2)
        await loop.wrote(dueIn: 2)
        #expect(await eventuallyHolds { sleeper.sleeping == 3 })
        #expect(sleeper.requested == [2.5, 2.5, 2.5])
        sleeper.wake()
        #expect(await eventuallyHolds { rounds.count == 1 })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rounds.count == 1, "the two older sleepers were cancelled")
    }
}

@Suite("The outbox watcher (B1)", .serialized)
struct OutboxWatcherTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func tick() { lock.withLock { value += 1 } }
    }

    @Test("A write after the first look is reported once, and a drained outbox is not")
    func reportsLocalWrites() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "ow-a", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        let calls = Calls()
        let store = a.store
        let watcher = OutboxWatcher(read: { try? OutboxSignature.read(in: store) }, changed: { calls.tick() })

        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c0', 'Before')")
        #expect(await watcher.look() == false, "the first look only learns what is there")
        #expect(calls.count == 0)

        #expect(await watcher.look() == false, "nothing changed")
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        #expect(await watcher.look() == true)
        #expect(await watcher.look() == false, "the same rows are not reported twice")
        try a.exec("UPDATE test_courses SET title = 'Cells II' WHERE id = 'c1'")
        #expect(await watcher.look() == true, "an edit of a row already waiting is a write too")
        #expect(calls.count == 2)

        try await a.sync()
        #expect(await watcher.look() == false, "sending drains the outbox: fewer rows is not a write")
        #expect(calls.count == 2)
    }

    @Test("The outbox's pinned stamps are not rows to send")
    func pinsAreNotWrites() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "ow-b", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        _ = try await a.engine.feed()
        let pins = try a.count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(OutboxFeeder.pinSource)])
        #expect(pins > 0)
        let signature = try OutboxSignature.read(in: a.store)
        let rows = try a.count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table <> ?", [.text(OutboxFeeder.pinSource)])
            + a.count("SELECT COUNT(*) FROM ck_outbox")
        #expect(signature.rows == rows)
    }
}

@Suite("A test host starts no real sync (m9)")
struct TestHostGuardTests {
    @Test("XCTest and Swift Testing hosts are recognised, a normal launch is not")
    func recognisesTestHosts() {
        #expect(ForeverLMRuntimeIdentity.isTestHost(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], arguments: [], bundlePath: "/Applications/ForeverLM.app"))
        #expect(ForeverLMRuntimeIdentity.isTestHost(environment: ["XCTestBundlePath": "/tmp/x.xctest"], arguments: [], bundlePath: "/Applications/ForeverLM.app"))
        #expect(ForeverLMRuntimeIdentity.isTestHost(environment: [:], arguments: ["/usr/bin/xctest"], bundlePath: "/Applications/ForeverLM.app"))
        #expect(ForeverLMRuntimeIdentity.isTestHost(environment: [:], arguments: [], bundlePath: "/tmp/ForeverLMTests.xctest"))
        #expect(ForeverLMRuntimeIdentity.isTestHost(environment: [:], arguments: [], bundlePath: "/Applications/ForeverLM.app", testFrameworkLoaded: true))
        #expect(!ForeverLMRuntimeIdentity.isTestHost(environment: ["HOME": "/home/x"], arguments: ["/Applications/ForeverLM.app/Contents/MacOS/ForeverLM"], bundlePath: "/Applications/ForeverLM.app"))
    }
}

@Suite("Sync now and its wait for the outbox (design review 2026-10-09, fix-first 1)", .serialized)
struct OutboxDrainTests {
    /// The sleeps a drain asked for, answered at once.
    private final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TimeInterval] = []
        var requested: [TimeInterval] { lock.withLock { values } }
        func sleep(_ seconds: TimeInterval) async { lock.withLock { values.append(seconds) } }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func tick() { lock.withLock { value += 1 } }
    }

    /// The drain the session runs, with the device's engine over FakeCloudKit as its push, in place of the
    /// Mac's round over CKSyncEngine.
    private static func drain(_ device: EngineTestDevice, pushes: Calls, sleeps: Sleeps) -> OutboxDrain {
        let (engine, server, store) = (device.engine, device.server, device.store)
        return OutboxDrain(
            push: {
                pushes.tick()
                EngineTestDriver.follow(server)
                try? await engine.sendChanges()
            },
            backlog: { try? OutboxBacklog.read(in: store) },
            sleep: { await sleeps.sleep($0) }
        )
    }

    @Test("Sync now pushes a pending outbox row, and its wait returns 0 once the outbox is empty")
    func pushesAPendingRow() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "drain-a", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        #expect(try OutboxBacklog.read(in: a.store).changes == 1)
        #expect(try a.serverEnvelope(.course, "c1") == nil)

        let pushes = Calls()
        let sleeps = Sleeps()
        let remaining = await Self.drain(a, pushes: pushes, sleeps: sleeps).run()

        #expect(remaining == 0)
        #expect(pushes.count == 1)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Cells"))
        #expect(try a.outboxRows() == 0)
        #expect(sleeps.requested.count == 1, "the push waited once, for the row written a moment before to be due")
        #expect(sleeps.requested.allSatisfy { $0 > 0 && $0 <= SyncCoordinator.sendSoonDelay })
    }

    @Test("The wait returns 0 only when the outbox is empty: held sends report what waits, after one push")
    func reportsWhatWaits() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "drain-b", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c2', 'Tissues')")
        // The cutover's hold: this Mac sends nothing, so its edits stay in the outbox.
        try a.store.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, Data("wait".utf8))

        let pushes = Calls()
        let held = await Self.drain(a, pushes: pushes, sleeps: Sleeps()).run(maxAttempts: 4)
        #expect(held == 2)
        #expect(pushes.count == 1, "a push that left as much waiting ends the wait: the pacers own the backoff")
        #expect(try a.serverEnvelope(.course, "c1") == nil)

        try a.store.replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, nil)
        #expect(await Self.drain(a, pushes: pushes, sleeps: Sleeps()).run() == 0)
        #expect(try a.serverEnvelope(.course, "c2") != nil)
        #expect(try OutboxBacklog.read(in: a.store).changes == 0)
    }

    @Test("The wait keeps pushing while each push sends some, and reports the rest when its attempts run out")
    func pushesWhileItProgresses() async throws {
        let server = EngineTestDriver.server()
        var configuration = PrivateSyncEngine.Configuration()
        // One change waits in the engine at a time, so each push sends one course.
        configuration.pendingMax = 1
        let a = try EngineTestDevice(server, name: "drain-c", deviceID: "macaaaaa", configuration: configuration)
        _ = try await a.bootstrap()
        for id in ["c1", "c2", "c3"] {
            try a.exec("INSERT INTO test_courses (id, title) VALUES ('\(id)', 'Course \(id)')")
        }

        let pushes = Calls()
        let sleeps = Sleeps()
        #expect(await Self.drain(a, pushes: pushes, sleeps: sleeps).run(maxAttempts: 2) == 1)
        #expect(pushes.count == 2)
        #expect(sleeps.requested.last == SyncCoordinator.sendSoonDelay, "pushes are spaced past the outbox's debounce")

        #expect(await Self.drain(a, pushes: pushes, sleeps: sleeps).run(maxAttempts: 2) == 0)
        #expect(pushes.count == 3)
        for id in ["c1", "c2", "c3"] { #expect(try a.serverEnvelope(.course, id) != nil) }
    }

    @Test("An empty outbox is nothing to wait for: no push")
    func emptyOutbox() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "drain-d", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        let pushes = Calls()
        #expect(await Self.drain(a, pushes: pushes, sleeps: Sleeps()).run() == 0)
        #expect(pushes.count == 0)
    }

    @Test("The backlog counts each changed row once, a removal and a patch, and never a pinned stamp")
    func backlogCounts() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "drain-e", deviceID: "macaaaaa")
        _ = try await a.bootstrap()
        #expect(try OutboxBacklog.read(in: a.store) == OutboxBacklog(changes: 0, newest: 0))

        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_courses SET title = 'Cells II', status = 'archived' WHERE id = 'c1'")
        #expect(try OutboxBacklog.read(in: a.store).changes == 1, "three changed fields of one row are one change")
        let newest = try OutboxBacklog.read(in: a.store).newest
        #expect(abs(newest - Date().timeIntervalSinceReferenceDate) < 60, "the triggers' time is Cocoa seconds")

        _ = try await a.engine.feed()
        let pins = try a.count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(OutboxFeeder.pinSource)])
        #expect(pins > 0)
        #expect(try OutboxBacklog.read(in: a.store).changes == 1, "pinned stamps are not changes")

        try await a.send()
        #expect(try OutboxBacklog.read(in: a.store).changes == 0)
        try a.exec("DELETE FROM test_courses WHERE id = 'c1'")
        #expect(try OutboxBacklog.read(in: a.store).changes == 1, "a removal waits too")

        try a.exec("""
            INSERT INTO ck_patches (zone_key, record_type, wire_id, patch_json, dirty_at)
            VALUES ('private/Library', 'Course', 'c9', '{}', 1)
        """)
        #expect(try OutboxBacklog.read(in: a.store).changes == 2, "a queued patch waits too")
    }
}
