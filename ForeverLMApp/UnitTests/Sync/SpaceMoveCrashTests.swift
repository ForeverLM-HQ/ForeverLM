import Foundation
import Testing
@testable import ForeverLM

/// A move into a space survives a crash at every step (docs/cloudkit-schema-design.md §5.3 "Crash
/// safety", PD-2, R4-m11): the journal resumes it on the next round, the space's copy is the one that
/// stays, a Mac whose journal is lost deletes nothing before it found every child by name in the space,
/// and a light client's `Job(moveToSpace)` makes its space once and runs the same job.
@Suite("Space move crash safety", .serialized)
struct SpaceMoveCrashTests {
    typealias F = SpaceMoveFixture

    private static func movingMac(_ name: String) async throws -> F.Mac {
        let mac = try await F.Mac(EngineTestDriver.server(), name: name, deviceID: "macaaaaa")
        try await F.seed(mac)
        try await mac.makeSpace()
        return mac
    }

    @Test("A move stopped before any step finishes on the next round, and leaves what an unbroken move leaves", arguments: [
        SpaceMoveJob.Step.mark, .copy, .catchUp, .stub, .list, .delete,
    ])
    func resumesAfterACrash(at step: SpaceMoveJob.Step) async throws {
        let mac = try await Self.movingMac("crash-\(step.rawValue)")
        let job = mac.job()
        await job.stop(before: step)
        await #expect(throws: SpaceMoveError.stopped(step)) { try await job.moveNotebook(F.notebook, into: F.spaceID) }
        // Nothing is deleted before the copies are listed and acknowledged.
        if [.mark, .copy, .catchUp, .stub, .list].contains(step) {
            #expect(try F.inLibrary(mac, .chat, F.chat) != nil)
            #expect(try F.inLibrary(mac, .entry, SyncIdentity.entryID(containerID: F.notebook, itemKind: "source", itemID: "src-a")) != nil)
        }
        if step == .list || step == .delete {
            // Both copies stand; the space's is the one this Mac reads and writes.
            #expect(try F.inSpace(mac, .chat, F.chat) != nil)
            #expect(try F.text(mac, "SELECT team_id FROM learning_goals WHERE id = ?", [.text(F.notebook)]) == F.spaceID)
        }

        // The next launch: a new job over the same store resumes from the journal.
        let reports = await mac.job().afterRound()
        #expect(reports.contains { $0.jobID == "nb.\(F.notebook).\(F.spaceID)" })
        try await F.expectMoved(mac)
        #expect(try F.text(mac, "SELECT state FROM ck_move_jobs WHERE id = ?", [.text("nb.\(F.notebook).\(F.spaceID)")]) == "done")
        #expect(try F.count(mac, "SELECT COUNT(*) FROM ck_move_items WHERE state IN ('queued', 'copied', 'listed')") == 0)
    }

    @Test("A move back stopped before it drops the space finishes on the next round: the space is read once more and then deleted (F10, F23)")
    func moveBackResumesBeforeDroppingTheSpace() async throws {
        let mac = try await Self.movingMac("crash-back")
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        let job = mac.job()
        await job.stop(before: .dropSpace)
        await #expect(throws: SpaceMoveError.stopped(.dropSpace)) { _ = try await job.moveNotebookBack(F.notebook, from: F.spaceID) }
        #expect(mac.server.zoneNames(owner: F.user).contains("Space-s1"), "nothing has dropped the space yet")

        _ = await mac.job().afterRound()
        #expect(!mac.server.zoneNames(owner: F.user).contains("Space-s1"), "the resumed move deletes the space it emptied")
        #expect(try F.inLibrary(mac, .chat, F.chat) != nil, "and what the space held is back in Library")
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["status"] == .string("active"))
    }

    @Test("A journal runs once at a time in this process: a second run waits for the first, and a Mac that moved nothing journals nothing")
    func oneRunOfAJournalAtATime() async throws {
        let mac = try await Self.movingMac("one-at-a-time")
        let job = mac.job()
        await job.stop(before: .copy)
        await #expect(throws: SpaceMoveError.stopped(.copy)) { try await job.moveNotebook(F.notebook, into: F.spaceID) }
        let id = "nb.\(F.notebook).\(F.spaceID)"
        let journal = "SELECT state FROM ck_move_jobs WHERE id = ?"
        #expect(try F.text(mac, journal, [.text(id)]) == "marked")

        // Another run of the journal holds it: the after-round pass waits instead of writing beside it.
        #expect(SpaceMoveRunning.shared.claim(id))
        let waiting = Task { await mac.job().afterRound() }
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(try F.text(mac, journal, [.text(id)]) == "marked", "nothing runs while another run holds the journal")
        SpaceMoveRunning.shared.release(id)
        let reports = await waiting.value
        #expect(reports.contains { $0.jobID == id })
        #expect(try F.text(mac, journal, [.text(id)]) == "done")
        #expect(SpaceMoveRunning.shared.claim(id), "a finished run lets go")
        SpaceMoveRunning.shared.release(id)

        // A Mac whose root lists no move has nothing to re-home: no journal.
        let idle = try await F.Mac(EngineTestDriver.server(), name: "idle", deviceID: "macbbbbb")
        let none = try await idle.job().rehome()
        #expect(none.isEmpty)
        #expect(try F.count(idle, "SELECT COUNT(*) FROM ck_move_jobs") == 0)
    }

    @Test("A Mac that lost its journal finishes its own move only once every child is in the space by name")
    func lostJournalChecksByName() async throws {
        let mac = try await Self.movingMac("lost")
        let job = mac.job()
        await job.stop(before: .stub)
        await #expect(throws: SpaceMoveError.stopped(.stub)) { try await job.moveNotebook(F.notebook, into: F.spaceID) }
        // A reinstall: the journal is gone, the copies and `movingTo` are on the server.
        try mac.device.exec("DELETE FROM ck_move_items; DELETE FROM ck_move_jobs;")
        // One child's copy is not in the space.
        let salt = try F.spaceSalt(mac)
        _ = try await mac.device.transport.modifyRecords(
            deleting: [CloudRecordID(RecordNaming.recordName(type: .task, id: F.task, salt: salt), in: CloudZoneID("Space-s1"))], in: .private
        )

        let waiting = try await mac.job().finishLostMoves()
        #expect(waiting == [F.notebook: .waiting(missing: 1)])
        for (type, id) in [(SyncRecordType.chat, F.chat), (.task, F.task), (.artifact, F.doc)] {
            #expect(try F.inLibrary(mac, type, id) != nil, "nothing is deleted while a child is missing")
        }
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["status"] == .string("active"))
        #expect(try F.count(mac, "SELECT COUNT(*) FROM ck_move_jobs") == 0)

        // The child's copy arrives (another of the owner's Macs copied it): now the move is finished.
        let original = try #require(try F.inLibrary(mac, .task, F.task))
        var copy = original
        copy.saltID = RecordNaming.saltID(salt)
        mac.server.put([CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: .task, id: F.task, salt: salt), in: CloudZoneID("Space-s1")),
                                    recordType: SyncRecordType.task.rawValue, encryptedFields: [CloudRecord.payloadKey: .bytes(try copy.storedPayload())])],
                       zone: "Space-s1", owner: F.user)
        let finished = try await mac.job().finishLostMoves()
        #expect(finished == [F.notebook: .finished])
        try await F.expectMoved(mac)
    }

    @Test("Another Mac's move without a journal here is never finished on its own")
    func anotherMacsMoveIsLeftToIt() async throws {
        let mac = try await Self.movingMac("lost-other")
        let job = mac.job()
        await job.stop(before: .stub)
        await #expect(throws: SpaceMoveError.stopped(.stub)) { try await job.moveNotebook(F.notebook, into: F.spaceID) }
        try mac.device.exec("DELETE FROM ck_move_items; DELETE FROM ck_move_jobs;")
        // Seen from another of the owner's Macs: movingTo's stamp names the Mac that runs the move.
        #expect(try await mac.job(deviceID: "macbbbbb").finishLostMoves().isEmpty)
        #expect(try F.inLibrary(mac, .chat, F.chat) != nil)
    }

    @Test("A light client's Job(moveToSpace) makes the new space once, under an id the Job fixes, and runs the same move after a crash")
    func jobMakesItsSpaceOnce() async throws {
        let mac = try await F.Mac(EngineTestDriver.server(), name: "job-move", deviceID: "macaaaaa")
        try await F.seed(mac)
        let params: [String: SyncJSON] = ["newSpace": .object(["kind": "notebook", "name": "Cells with Bob"])]
        let expected = SpaceMoveIdentity.spaceID(forJob: "job-1")
        #expect(UUID(uuidString: expected) != nil && expected == expected.lowercased())

        let first = mac.job()
        await first.stop(before: .copy)
        await #expect(throws: SpaceMoveError.stopped(.copy)) { try await first.runRequest(jobID: "job-1", notebookID: F.notebook, params: params) }
        #expect(try F.count(mac, "SELECT COUNT(*) FROM ck_zones WHERE kind = 'space'") == 1)
        #expect(try F.text(mac, "SELECT primary_id FROM ck_zones WHERE zone_key = ?", [.text("private/Space-\(expected)")]) == F.notebook)

        let spaceID = try await mac.job().runRequest(jobID: "job-1", notebookID: F.notebook, params: params)
        #expect(spaceID == expected)
        #expect(try F.count(mac, "SELECT COUNT(*) FROM ck_zones WHERE kind = 'space'") == 1, "no second space")
        #expect(try F.inSpace(mac, .chat, F.chat, zone: "Space-\(expected)") != nil)
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["movedTo"] == .string(expected))
        // The journal's id names the Mac that ran it, so a Mac taking the Job over writes keys of its own (F14).
        #expect(try F.text(mac, "SELECT state FROM ck_move_jobs WHERE id = 'job.job-1.macaaaaa'") == "done")
        #expect(try F.count(mac, "SELECT COUNT(*) FROM ck_move_jobs WHERE id = 'job.job-1'") == 0)
    }

    @Test("Two Macs that run one Job write journals and move-map keys of their own, and reach the one space (F14)")
    func twoMacsRunningOneJobDoNotShareAKey() async throws {
        let mac = try await F.Mac(EngineTestDriver.server(), name: "job-two-macs", deviceID: "macaaaaa")
        try await F.seed(mac)
        let params: [String: SyncJSON] = ["newSpace": .object(["kind": "notebook", "name": "Cells with Bob"])]
        let first = mac.job()
        await first.stop(before: .copy)
        await #expect(throws: SpaceMoveError.stopped(.copy)) { try await first.runRequest(jobID: "job-2", notebookID: F.notebook, params: params) }

        // The lease lapsed and a second Mac took the Job over: it runs the move from scratch under its own id.
        let second = try await mac.job(deviceID: "macbbbbb").runRequest(jobID: "job-2", notebookID: F.notebook, params: params)
        #expect(second == SpaceMoveIdentity.spaceID(forJob: "job-2"), "the space is the Job's, whichever Mac runs it")
        #expect(try F.count(mac, "SELECT COUNT(*) FROM ck_zones WHERE kind = 'space'") == 1, "one space")
        let ids = try F.count(mac, "SELECT COUNT(*) FROM ck_move_jobs WHERE id IN ('job.job-2.macaaaaa', 'job.job-2.macbbbbb')")
        #expect(ids == 2, "each Mac's journal is its own")
        #expect(try F.text(mac, "SELECT state FROM ck_move_jobs WHERE id = 'job.job-2.macbbbbb'") == "done")
    }

    @Test("The runner claims a move it can run, and a move a quit interrupted starts again instead of failing")
    func runnerClaimsAndResumesAMove() throws {
        typealias N = NotebookSyncFixture
        let (root, store) = try N.makeStore("move-runner")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.addNotebook(store, "nb-1")
        try N.sendAll(store)
        let move = try JobSyncFixture.jobRecord("job-move", kind: "moveToSpace", target: "nb:nb-1", params: [
            "newSpace": .object(["kind": "notebook", "name": "Shared"]),
        ])
        try N.apply(store, [move])
        let job = try #require(try JobRow.load("job-move", connection: store))
        #expect(try MacJobRunner.canRun(job, store: store, device: "macaaaaa"))
        var elsewhere = job
        elsewhere.params = ["spaceID": "not-here"]
        #expect(try !MacJobRunner.canRun(elsewhere, store: store, device: "macaaaaa"), "a space this Mac does not hold waits")
        var unknown = job
        unknown.target = "nb:nb-missing"
        #expect(try !MacJobRunner.canRun(unknown, store: store, device: "macaaaaa"))

        // This Mac claimed and started it, and then quit: the next pass starts it again.
        let claim = SyncJSON.object(["device": "macaaaaa", "at": SyncJSON(SyncTime.milliseconds(Date().addingTimeInterval(-60)))])
        var claimed = try JobSyncFixture.jobRecord("job-move", kind: "moveToSpace", target: "nb:nb-1", params: job.params)
        var envelope = try SyncEnvelope(storedPayload: claimed.payload)
        try envelope.apply(RecordPatch(.job, id: "job-move", changes: ["claim": .value(claim)])) { _, policy, _ in
            SyncStamp(policy: policy, milliseconds: SyncTime.milliseconds(Date()), counter: 1, deviceID: "macaaaaa")
        }
        claimed.payload = try envelope.storedPayload()
        try N.apply(store, [claimed])
        try store.execute("UPDATE jobs SET status = 'running', lease_until = ? WHERE id = 'job-move'", [.real(Date().addingTimeInterval(600).timeIntervalSinceReferenceDate)])
        #expect(try MacJobRunner.plan(store: store, now: Date(), running: []) == [.start("job-move")])
        #expect(try MacJobRunner.plan(store: store, now: Date(), running: ["job-move"]).isEmpty)
    }
}
