import Foundation
import Testing
@testable import ForeverLM

/// What Settings › iCloud shows of the move (docs/cloudkit-schema-design.md §13.3 to §13.8): the lines
/// follow the activation's journal, the root's seed and claim, the pacer's pause and the rollback copy,
/// and the store's own snapshot reads them from a real activated store.
@Suite("iCloud migration state", .serialized)
struct ICloudMigrationStateTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private static func journal(mode: ActivationMode = .full, reason: FreshReason? = nil, activated: Bool = true, catchUp: Bool = true) -> ActivationJournal {
        ActivationJournal(
            step: activated ? .activated : .triggers, mode: mode, freshReason: reason, clonePath: "knowledge.pre-v2.db", cloneUserVersion: 153,
            activatedAt: activated ? now.timeIntervalSinceReferenceDate : nil,
            catchUpAt: ranAt(catchUp)
        )
    }

    private static func ranAt(_ ran: Bool) -> Double? { ran ? now.timeIntervalSinceReferenceDate : nil }

    private static func state(
        journal: ActivationJournal? = journal(), seed: ICloudMigrationSnapshot.SeedLine = .init(phase: .complete),
        root: HoldsMyLibrary.RootState = .complete, library: Bool = true, sync: SyncStatus? = nil,
        stop: PurgeHandler.Event? = nil, copy: ICloudMigrationSnapshot.RollbackCopyLine = .checked(userVersion: 153)
    ) -> ICloudMigrationState {
        var snapshot = ICloudMigrationSnapshot()
        snapshot.isGeneration2 = true
        snapshot.journal = journal
        snapshot.seed = seed
        snapshot.root = root
        snapshot.holdsLibrary = library
        snapshot.stop = stop
        snapshot.rollbackCopy = copy
        return ICloudMigrationState(snapshot: snapshot, sync: sync, now: now)
    }

    // MARK: The move

    @Test("Nothing shows under generation 1, or before the activation has finished")
    func hiddenUntilActivated() {
        var gen1 = Self.state()
        gen1.snapshot.isGeneration2 = false
        #expect(!gen1.isShown && gen1.moveLine == nil)
        let activating = Self.state(journal: Self.journal(activated: false))
        #expect(!activating.isShown && activating.moveLine == nil)
    }

    @Test("While another Mac moves the library, Settings names it and the step; while this one does, it says so")
    func seedingLines() {
        let other = Self.state(seed: .init(phase: .seeding, movingMac: "Studio", claimIsMine: false, passesDone: 2), root: .seeding)
        #expect(other.moveLine == ICloudMigrationLine(title: "Your other Mac Studio is moving your library", detail: "Step 3 of 7"))
        let mine = Self.state(seed: .init(phase: .seeding, movingMac: nil, claimIsMine: true, passesDone: 6), root: .seeding)
        #expect(mine.moveLine == ICloudMigrationLine(title: "Moving your library to the new iCloud store", detail: "Step 7 of 7"))
        let past = Self.state(seed: .init(phase: .seeding, movingMac: nil, claimIsMine: true, passesDone: 9), root: .seeding)
        #expect(past.moveLine?.detail == "Step 7 of 7", "never beyond the last step")
    }

    @Test("Metadata in but satellites still going reads 'Library moved; files uploading', with the pause reason")
    func uploadingFilesAndPauses() {
        let uploading = Self.state(seed: .init(phase: .metadataComplete))
        #expect(uploading.moveLine == ICloudMigrationLine(title: "Library moved; files uploading", detail: nil))
        var sync = SyncStatus()
        sync.pause = .smallRecordsFirst
        #expect(Self.state(seed: .init(phase: .metadataComplete), sync: sync).moveLine?.detail == "Files wait while your changes upload.")
        sync.pause = .repeatedRefusals
        #expect(Self.state(seed: .init(phase: .complete), sync: sync).moveLine == ICloudMigrationLine(title: "Library moved", detail: "iCloud refused 20 uploads in a row; ForeverLM tries again in 15 minutes."))
        #expect(Self.state(seed: .init(phase: .complete)).moveLine == nil, "a finished move with no pause says nothing")
    }

    @Test("A stopped private database shows the notice with its way out")
    func stoppedShowsTheNotice() {
        var sync = SyncStatus()
        sync.phase = .stopped(.zoneDeleted(reason: .purged))
        let state = Self.state(sync: sync, stop: .zoneDeleted(reason: .purged))
        #expect(state.moveLine?.title.contains("Upload my library to iCloud again") == true)
        #expect(state.snapshot.stop != nil)
    }

    @Test("A pending root waits for the Mac that holds the library, unless this Mac is offered the button")
    func pendingRoot() {
        let waiting = Self.state(journal: Self.journal(mode: .fresh, reason: .noHistory), seed: .init(phase: .pending), root: .pending, library: false)
        #expect(waiting.moveLine?.title == "Waiting for the Mac that holds your library")
        let offered = Self.state(journal: Self.journal(mode: .fresh, reason: .noHistory), seed: .init(phase: .pending), root: .pending, library: true)
        #expect(offered.holds == .offer(.pendingRoot))
        #expect(offered.moveLine == nil, "the button's row says it")
    }

    @Test("The activation's mode reads as a sentence, and a deferred Mac says it still waits for its catch-up")
    func modeLines() {
        #expect(Self.state().modeLine == "Moved from the old iCloud library on this Mac")
        #expect(Self.state(journal: Self.journal(mode: .deferred, catchUp: false)).modeLine == "Waiting for iCloud to catch up with the old library")
        #expect(Self.state(journal: Self.journal(mode: .deferred, catchUp: true)).modeLine == "Caught up with the old library after the move")
        #expect(Self.state(journal: Self.journal(mode: .fresh, reason: .noHistory)).modeLine == "Joined the new iCloud store as a new device")
        #expect(Self.state(journal: Self.journal(mode: .fresh, reason: .knowledgeMissing)).modeLine == "The old iCloud library was not found; this Mac keeps its own")
    }

    // MARK: Rollback

    @Test("The rollback copy is shown")
    func rollbackLines() {
        #expect(Self.state().rollbackCopyLine == "Rollback copy: checked (library version 153)")
        #expect(Self.state(copy: .checking(userVersion: 153)).rollbackCopyLine == "Rollback copy: checking")
        #expect(Self.state(copy: .failedCheck("row 4 missing")).rollbackCopyLine == "Rollback copy: failed its check (row 4 missing)")
        #expect(Self.state(copy: .missing).rollbackCopyLine == "Rollback copy: missing")
        #expect(Self.state(copy: .none).rollbackCopyLine.hasPrefix("Rollback copy: none"))
    }

    // MARK: The root

    @Test("The seed and the claim are read from the personal root, and an expired claim names no Mac")
    func seedFromTheRoot() throws {
        func root(_ seed: [String: SyncJSON], claim: [String: SyncJSON]? = nil) throws -> SyncEnvelope {
            var envelope = SyncEnvelope.new(.zoneRoot, id: SyncSchema.rootRecordName, saltID: "salt")
            envelope.fields["seed"] = .object(seed)
            if let claim { envelope.fields["seedClaim"] = .object(claim) }
            return envelope
        }
        let live = SyncJSON(SyncTime.milliseconds(Self.now.addingTimeInterval(600)))
        let lapsed = SyncJSON(SyncTime.milliseconds(Self.now.addingTimeInterval(-600)))
        let name: (String) -> String? = { $0 == "macbbbbb" ? "Studio" : nil }

        let other = ICloudMigrationSnapshot.SeedLine.read(
            root: try root(["state": .string("seeding")], claim: ["device": .string("macbbbbb"), "leaseUntil": live]),
            myDeviceID: "macaaaaa", passesDone: 3, deviceName: name, now: Self.now
        )
        #expect(other.phase == .seeding && other.movingMac == "Studio" && !other.claimIsMine && other.passesDone == 3)

        let mine = ICloudMigrationSnapshot.SeedLine.read(
            root: try root(["state": .string("seeding")], claim: ["device": .string("macaaaaa"), "leaseUntil": live]),
            myDeviceID: "macaaaaa", passesDone: 0, deviceName: name, now: Self.now
        )
        #expect(mine.claimIsMine && mine.movingMac == nil)

        let expired = ICloudMigrationSnapshot.SeedLine.read(
            root: try root(["state": .string("seeding")], claim: ["device": .string("macbbbbb"), "leaseUntil": lapsed]),
            myDeviceID: "macaaaaa", passesDone: 0, deviceName: name, now: Self.now
        )
        #expect(expired.movingMac == nil, "the seeder slept: nobody is moving it")

        let metadata = ICloudMigrationSnapshot.SeedLine.read(
            root: try root(["state": .string("seeding"), "metadataCompleteAt": SyncJSON(1_000)]), myDeviceID: nil, passesDone: 0, deviceName: name, now: Self.now)
        #expect(metadata.phase == .metadataComplete)
        #expect(ICloudMigrationSnapshot.SeedLine.read(root: try root(["state": .string("complete"), "metadataCompleteAt": SyncJSON(1_000)]), myDeviceID: nil, passesDone: 7, deviceName: name, now: Self.now).phase == .complete)
        #expect(ICloudMigrationSnapshot.SeedLine.read(root: try root(["state": .string("pending")]), myDeviceID: nil, passesDone: 0, deviceName: name, now: Self.now).phase == .pending)
        #expect(ICloudMigrationSnapshot.SeedLine.read(root: nil, myDeviceID: nil, passesDone: 0, deviceName: name, now: Self.now).phase == .unknown)

        #expect(HoldsMyLibrary.RootState.read(root: nil, now: Self.now) == .unknown)
        #expect(HoldsMyLibrary.RootState.read(root: try root(["state": .string("pending")]), now: Self.now) == .pending)
        #expect(HoldsMyLibrary.RootState.read(root: try root(["state": .string("seeding")], claim: ["device": .string("macbbbbb"), "leaseUntil": live]), now: Self.now) == .seeding)
        #expect(HoldsMyLibrary.RootState.read(root: try root(["state": .string("seeding")], claim: ["device": .string("macbbbbb"), "leaseUntil": lapsed]), now: Self.now) == .pending, "a lapsed claim waits for a Mac that holds the library")
        #expect(HoldsMyLibrary.RootState.read(root: try root(["state": .string("seeding"), "metadataCompleteAt": SyncJSON(1_000)]), now: Self.now) == .complete)
    }

    // MARK: get_sync_status

    @Test("get_sync_status carries the move: mode, seed and rollback")
    func statusPayload() throws {
        let payload = try #require(Self.state(seed: .init(phase: .metadataComplete)).statusPayload())
        #expect(payload["activated"] as? Bool == true)
        #expect(payload["activation_mode"] as? String == "full")
        #expect((payload["seed"] as? [String: Any])?["phase"] as? String == "metadataComplete")
        // The rollback is the local copy alone: no build of the old team can reach any container now.
        #expect((payload["rollback"] as? [String: Any])?["copy"] as? String == "Rollback copy: checked (library version 153)")
        #expect((payload["rollback"] as? [String: Any])?["build"] == nil)
        // The old library's import, byte parity and its removal are gone with generation 1.
        for key in ["old_icloud_library", "byte_parity", "remove_old_icloud_data"] {
            #expect(payload[key] == nil, "\(key)")
        }
        #expect(JSONSerialization.isValidJSONObject(payload), "the payload serializes")
    }

    @Test("get_sync_status says when this Mac is offered 'This Mac holds my library', and names the action and its cost")
    func statusPayloadOffer() throws {
        let offered = Self.state(journal: Self.journal(mode: .fresh, reason: .noHistory), seed: .init(phase: .pending), root: .pending)
        let offeredPayload = try #require(offered.statusPayload())
        let holds = try #require(offeredPayload["this_mac_holds_my_library"] as? [String: Any])
        #expect(holds["state"] as? String == "offered")
        #expect((holds["action"] as? String)?.contains("confirm_this_mac_holds_my_library") == true)
        #expect((holds["consequence"] as? String)?.contains("comes back") == true)
        let plain = try #require(Self.state().statusPayload())
        #expect((plain["this_mac_holds_my_library"] as? [String: Any])?["state"] as? String == "not_applicable")
        var gen1 = Self.state()
        gen1.snapshot.isGeneration2 = false
        #expect(gen1.statusPayload() == nil, "generation 1 has no move to report")
    }

    // MARK: From a real store

    private static func activatedStore(_ name: String) async throws -> (root: URL, store: KnowledgeStore) {
        let root = try Schema154Fixture.temporaryRoot(name)
        try Schema154Fixture.makeLibrary(at: root, version: 174)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try store.executeScript(OutboxTestProjections.tablesSQL)
        await KnowledgeRollbackCopy.queuedChecksForTesting()
        var activation = GenerationActivation(store: store)
        activation.registry = OutboxTestProjections.registry
        try activation.run(.freshNoHistory)
        return (root, store)
    }

    @Test("A store's snapshot reads its journal, its rollback copy and the bytes its satellites hold")
    func snapshotFromAStore() async throws {
        let (root, store) = try await Self.activatedStore("migration-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.execute("""
            INSERT INTO ck_blobs (zone_key, record_name, content_id, owner_id, role, part_hash, part_bytes, acked_at)
            VALUES (?, 'r1', 'ct:a:pdf:1', 'a', 'pdf', 'h1', 1000, 1), (?, 'r2', 'ct:b:text:2', 'b', 'text', 'h2', 234, 1)
        """, [.text(ReplicaZone.key(database: .private, zoneName: SyncZone.content.rawValue)), .text(ReplicaZone.key(database: .private, zoneName: SyncZone.content.rawValue))])

        let snapshot = try store.migrationSnapshot(deviceID: "macaaaaa", now: Self.now)
        #expect(snapshot.isGeneration2 && snapshot.isActivated)
        #expect(snapshot.journal?.mode == .fresh && snapshot.journal?.freshReason == .noHistory)
        #expect(snapshot.holdsLibrary, "the fixture store holds a library")
        #expect(snapshot.rollbackCopy == .checked(userVersion: 153), "the copy's quick_check passed: \(snapshot.rollbackCopy)")
        #expect(snapshot.libraryBytes == 1_234)
        #expect(snapshot.ownedSpaces.isEmpty)
        #expect(snapshot.seed.phase == .unknown && snapshot.root == .unknown, "no root has been read")
        #expect(snapshot.confirmation == nil && snapshot.stop == nil)

        // The confirmation the learner gave, and the private database's stop, are read back.
        try store.writeHoldsMyLibraryConfirmation(HoldsMyLibraryConfirmation(confirmedAt: Self.now, catchUpAt: nil, outcome: nil))
        try store.replica.setEngineState(ReplicaStore.EngineScope.privateStop, Data(PurgeHandler.Event.rootMissing.code.utf8))
        let later = try store.migrationSnapshot(deviceID: nil, now: Self.now)
        #expect(later.confirmation?.confirmedAt == Self.now)
        #expect(later.stop == .rootMissing)

        // A copy that is not on disk, and a store that took none.
        try FileManager.default.removeItem(at: root.appendingPathComponent("knowledge.pre-v2.db"))
        #expect(try store.migrationSnapshot(deviceID: nil).rollbackCopy == .missing)
        var journal = try #require(try store.activationJournal())
        journal.clonePath = nil
        try store.writeActivationJournal(journal)
        #expect(try store.migrationSnapshot(deviceID: nil).rollbackCopy == .none)
    }
}
