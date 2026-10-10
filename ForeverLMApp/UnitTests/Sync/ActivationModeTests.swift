import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The generation-2 activation's three modes and their fallbacks (D46, docs/cloudkit-schema-design.md
/// §13.3 step 3, WP16a), run through `GenerationActivationRunner` on a store with the old container of a
/// `FakeCloudKit`. The journal's steps are `GenerationActivationTests` (WP4c); the catch-up's decisions
/// are `MigrationCatchUpTests`.
@Suite("Activation modes")
struct ActivationModeTests {
    private typealias Rig = MigrationCatchUpRig
    private typealias Fixture = OutboxTestProjections

    private static func environment(_ rig: Rig, clock: ActivationClock = ActivationClock(), transport: (any CloudTransport)? = nil) -> ActivationEnvironment {
        var environment = ActivationEnvironment()
        environment.oldContainerTransport = transport ?? rig.oldContainer
        environment.now = { clock.now }
        environment.sleep = { clock.advance($0) }
        environment.catchUp = rig.configuration
        environment.status = ActivationStatus()
        environment.derivations = []
        environment.registry = Fixture.registry
        return environment
    }

    private static func rig() throws -> Rig {
        let rig = try Rig()
        try rig.receiver.executeScript(Fixture.tablesSQL)
        return rig
    }

    private static func run(_ rig: Rig, _ environment: ActivationEnvironment) async throws -> ActivationJournal {
        try await GenerationActivationRunner(access: rig.access, environment: environment).run()
    }

    /// A transport that tells a test when the walk reaches the old container, so it can try a write then.
    private final class ProbingTransport: CloudTransport, @unchecked Sendable {
        let inner: any CloudTransport
        let onZones: @Sendable () -> Void
        init(_ inner: any CloudTransport, onZones: @escaping @Sendable () -> Void) {
            self.inner = inner
            self.onZones = onZones
        }

        var containerIdentifier: String { inner.containerIdentifier }
        func accountStatus() async throws -> CKAccountStatus { try await inner.accountStatus() }
        func userRecordName() async throws -> String { try await inner.userRecordName() }
        func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] {
            onZones()
            return try await inner.allZones(in: database)
        }
        func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
            try await inner.modifyZones(saving: saving, deleting: deleting, in: database)
        }
        func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
            try await inner.databaseChanges(in: database, since: token, resultsLimit: resultsLimit)
        }
        func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
            try await inner.zoneChanges(requests, in: database)
        }
        func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
            try await inner.records(ids, in: database, desiredKeys: desiredKeys)
        }
        func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope, savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
            try await inner.modifyRecords(saving: saving, deleting: deleting, in: database, savePolicy: savePolicy, atomically: atomically)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// The activation's store access with what the app does beside it: in every step another store opens on the
    /// library and takes the open's hold, as each `StorageService` does when it first opens its store while the
    /// catch-up runs (`StorageService.knowledgeStore()` calls `holdIfActivationMayBeFull`). While the window is
    /// held it also tries a write on that store, which the window must refuse.
    private final class OpeningStoreAccess: MigrationStoreAccess, @unchecked Sendable {
        private let inner: DirectStoreAccess
        private let root: URL
        private let lock = NSLock()
        private var opened: [KnowledgeStore] = []
        private var heldOpens = 0
        private var refused = 0

        init(store: KnowledgeStore, root: URL) {
            inner = DirectStoreAccess(store: store)
            self.root = root
        }

        /// Stores opened while the window was held, and how many of them refused their write.
        var opensInTheWindow: Int { lock.withLock { heldOpens } }
        var refusedWrites: Int { lock.withLock { refused } }

        func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T {
            try await inner.perform { store in
                let other = try KnowledgeStore(storeDirectory: self.root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
                GenerationActivationRunner.holdIfActivationMayBeFull(other)
                let held = KnowledgeStoreWriteGate.isHeld(databaseAt: other.dbPath)
                let refusedWrite = held && (try? other.exec("CREATE TABLE IF NOT EXISTS app_write_probe (x INTEGER)")) == nil
                self.lock.withLock {
                    self.opened.append(other)
                    if held { self.heldOpens += 1 }
                    if refusedWrite { self.refused += 1 }
                }
                return try body(store)
            }
        }
    }

    // MARK: full

    @Test("A store with history and an account activates full and refuses writes until activated_at")
    func fullRefusesWritesUntilActivated() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        // History the old zone still holds: a lone sync_metadata row with no record there would be one of one
        // deleted, and the 5% guard would stop the walk and continue deferred.
        try rig.lastSynced(try rig.senderDoc("doc-history", title: "History", body: Rig.baseBody))
        let refused = Flag()
        let probing = ProbingTransport(rig.oldContainer) {
            do { try rig.receiver.exec("CREATE TABLE IF NOT EXISTS gate_probe (x INTEGER)") } catch { refused.set() }
        }

        let environment = Self.environment(rig, transport: probing)
        let journal = try await Self.run(rig, environment)
        #expect(journal.mode == .full && journal.freshReason == nil && journal.account == Rig.learner)
        #expect(refused.isSet, "the library refused a write while the catch-up walked")
        #expect(journal.activatedAt != nil && journal.catchUpAt != nil, "the walk's start is recorded")
        #expect(!KnowledgeStoreWriteGate.isHeld(databaseAt: rig.receiver.dbPath))
        try rig.receiver.exec("CREATE TABLE IF NOT EXISTS gate_probe_after (x INTEGER)")
        #expect(environment.status.current == .done)
    }

    @Test("A full activation whose walk trips the 5% guard continues as deferred, writable and sending nothing, while the question waits (R5-m5)")
    func guardContinuesDeferred() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        var names: [String] = []
        for index in 0..<4 {
            let record = try rig.senderDoc("doc-\(index)", title: "doc-\(index)", body: Rig.baseBody)
            try rig.lastSynced(record)
            names.append(record.id.recordName)
        }
        try await rig.deleteFromOldWorld(names[2])
        try await rig.deleteFromOldWorld(names[3])

        let environment = Self.environment(rig)
        let journal = try await Self.run(rig, environment)
        #expect(journal.mode == .deferred && journal.activatedAt != nil)
        #expect(journal.sendsWaitForCatchUp, "nothing is sent, and no claim is taken, until the deferred catch-up has run")
        let stored = try #require(try ActivationQuestion.load(rig.receiver))
        #expect(stored.question.deleting == 2 && stored.question.of == 4 && stored.answer == nil)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id IN ('doc-2', 'doc-3')") == 2, "nothing was deleted")
        try rig.receiver.exec("CREATE TABLE IF NOT EXISTS gate_probe (x INTEGER)")
        if case .asking(let question) = environment.status.current { #expect(question == stored.question) } else { Issue.record("the window asks") }

        // A relaunch of the activated store with the question still unanswered asks again (F30).
        let relaunched = Self.environment(rig)
        _ = try await Self.run(rig, relaunched)
        if case .asking(let question) = relaunched.status.current { #expect(question == stored.question) } else { Issue.record("the relaunched window asks again: \(relaunched.status.current)") }

        // Apply is recorded for the deferred catch-up to run once with the guard lifted.
        try ActivationQuestion.answerApply(store: rig.receiver)
        #expect(try ActivationQuestion.load(rig.receiver)?.answer == "apply")
    }

    @Test("Not this library applies nothing, keeps the store and records fresh with knowledgeMissing, so nothing is uploaded until the learner confirms (R6-m9)")
    func notThisLibrary() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        for index in 0..<4 {
            try rig.lastSynced(try rig.senderDoc("doc-\(index)", title: "doc-\(index)", body: Rig.baseBody))
        }
        try await rig.deleteFromOldWorld(try #require(rig.server.recordNames(zone: CloudKitZoneHome.knowledgeZoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer).first))
        try await rig.deleteFromOldWorld(try #require(rig.server.recordNames(zone: CloudKitZoneHome.knowledgeZoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer).first))
        _ = try await Self.run(rig, Self.environment(rig))

        try ActivationQuestion.answerNotThisLibrary(store: rig.receiver)
        let journal = try #require(try rig.receiver.activationJournal())
        #expect(journal.mode == .fresh && journal.freshReason == .knowledgeMissing && journal.sendsWaitForConfirmation)
        #expect(try ActivationQuestion.load(rig.receiver) == nil)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id LIKE 'doc-%'") == 4, "the store is kept")
    }

    @Test("A missing Knowledge zone activates the store fresh with its library, deletes nothing and uploads nothing until the learner confirms")
    func knowledgeMissing() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        try rig.giveHistory()
        let sources = try rig.receiver.scalarInteger("SELECT COUNT(*) FROM sources")

        let journal = try await Self.run(rig, Self.environment(rig))
        #expect(journal.mode == .fresh && journal.freshReason == .knowledgeMissing && journal.account == Rig.learner)
        #expect(journal.activatedAt != nil && journal.sendsWaitForConfirmation)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM sources") == sources)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot") == 0, "no old world to keep a view of")
    }

    // MARK: fresh and deferred

    @Test("An empty store, and one whose history generation 1 cleared at sign-out, activate fresh with no network call and are never read-only")
    func freshMakesNoCall() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        let journal = try await Self.run(rig, Self.environment(rig))
        #expect(journal.mode == .fresh && journal.freshReason == .noHistory)
        #expect(journal.activatedAt != nil)
        #expect(rig.server.calls.isEmpty, "no call reached the server: \(rig.server.calls.map(\.operation))")
        #expect(!KnowledgeStoreWriteGate.isHeld(databaseAt: rig.receiver.dbPath))

        // History cleared at sign-out leaves sync_metadata rows with no system fields: the same.
        let signedOut = try Self.rig()
        defer { signedOut.cleanUp() }
        try signedOut.receiver.exec("INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at, is_deleted) VALUES ('preference', 'x', 'Preference-x', NULL, 1, 0)")
        let cleared = try await Self.run(signedOut, Self.environment(signedOut))
        #expect(cleared.mode == .fresh && cleared.freshReason == .noHistory)
        #expect(signedOut.server.calls.isEmpty)
    }

    @Test("A full activation finishes its catch-up while the app opens other stores on the library in every step, and only those refuse writes")
    func fullCatchUpPassesTheHoldOfALaterOpen() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-held", title: "Held", body: Rig.baseBody))
        try rig.senderDoc("doc-held", title: "Held, renamed in the old world", body: Rig.baseBody)
        // The store opens as StorageService opens it: held, since its history may make the activation full.
        GenerationActivationRunner.holdIfActivationMayBeFull(rig.receiver)
        #expect(KnowledgeStoreWriteGate.isHeld(databaseAt: rig.receiver.dbPath))
        let access = OpeningStoreAccess(store: rig.receiver, root: rig.receiverRoot)

        let environment = Self.environment(rig)
        let journal = try await GenerationActivationRunner(access: access, environment: environment).run()
        #expect(journal.mode == .full && journal.catchUpAt != nil && journal.activatedAt != nil,
                "the catch-up's own writes passed the hold a later open took: \(journal)")
        #expect(try rig.title("doc-held") == "Held, renamed in the old world")
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot") ?? 0 > 0, "the snapshot is kept")
        #expect(access.opensInTheWindow > 0 && access.refusedWrites == access.opensInTheWindow,
                "every store the app opened during the window refused its write")
        #expect(!KnowledgeStoreWriteGate.isHeld(databaseAt: rig.receiver.dbPath))
        try rig.receiver.exec("CREATE TABLE IF NOT EXISTS gate_probe_after (x INTEGER)")
    }

    @Test("A hold taken while an activation step runs leaves that step's store writable to its end, and the other stores refuse writes")
    func holdDuringAStep() throws {
        let root = try Schema154Fixture.temporaryRoot("write-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        Schema154Fixture.newLaunch(root)
        let activation = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        let app = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        let path = activation.dbPath
        KnowledgeStoreWriteGate.hold(databaseAt: path)
        defer { KnowledgeStoreWriteGate.release(databaseAt: path) }

        try KnowledgeStoreWriteGate.allowingWrites(on: activation) {
            try activation.exec("CREATE TABLE step_first (x INTEGER)")
            // A store the app opens now holds the path again.
            let late = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
            KnowledgeStoreWriteGate.hold(databaseAt: path)
            try activation.exec("CREATE TABLE step_after_hold (x INTEGER)")
            #expect(throws: (any Error).self) { try app.exec("CREATE TABLE app_write (x INTEGER)") }
            #expect(throws: (any Error).self) { try late.exec("CREATE TABLE late_write (x INTEGER)") }
            // A step nested in the step does not end the outer one's lift.
            try KnowledgeStoreWriteGate.allowingWrites(on: activation) { try activation.exec("CREATE TABLE step_nested (x INTEGER)") }
            try activation.exec("CREATE TABLE step_last (x INTEGER)")
        }
        #expect(throws: (any Error).self) { try activation.exec("CREATE TABLE after_step (x INTEGER)") }
    }

    @Test("Once the runner has decided, a store opened later is not held again from its open, so a failed activation leaves the library writable")
    func openAfterTheDecisionIsNotHeld() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        try rig.giveHistory()
        GenerationActivationRunner.holdIfActivationMayBeFull(rig.receiver)
        #expect(KnowledgeStoreWriteGate.isHeld(databaseAt: rig.receiver.dbPath))
        // The runner decides (here it fails at once, as an activation that throws does) and releases the path.
        KnowledgeStoreWriteGate.release(databaseAt: rig.receiver.dbPath)

        let later = try KnowledgeStore(storeDirectory: rig.receiverRoot, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        GenerationActivationRunner.holdIfActivationMayBeFull(later)
        #expect(!KnowledgeStoreWriteGate.isHeld(databaseAt: rig.receiver.dbPath))
        try later.exec("CREATE TABLE IF NOT EXISTS written_after_the_decision (x INTEGER)")
        try rig.receiver.exec("CREATE TABLE IF NOT EXISTS written_after_the_decision_too (x INTEGER)")
    }

    @Test("A store with history and no iCloud account activates deferred and stays writable, sending nothing and claiming nothing until its deferred catch-up has run")
    func deferredWithoutAccount() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        try rig.giveHistory()
        rig.server.signIn(rig.oldContainer, as: nil)

        let journal = try await Self.run(rig, Self.environment(rig))
        #expect(journal.mode == .deferred && journal.activatedAt != nil && journal.catchUpAt == nil)
        #expect(journal.sendsWaitForCatchUp)
        #expect(rig.server.calls.map(\.operation) == [.accountStatus], "only the account was asked")
        try rig.receiver.exec("CREATE TABLE IF NOT EXISTS gate_probe (x INTEGER)")
    }

    @Test("iCloud unreachable for 2 minutes falls back to deferred, and so does a catch-up that keeps failing for that long")
    func unreachableFallsBack() async throws {
        let unreachable = CloudError(.networkUnavailable, message: "offline")
        let account = try Self.rig()
        defer { account.cleanUp() }
        try account.giveHistory()
        account.server.failNext(.accountStatus, container: FakeCloudKit.legacyContainer, times: 10_000, with: unreachable)
        let clock = ActivationClock()
        let started = clock.now
        let first = try await Self.run(account, Self.environment(account, clock: clock))
        #expect(first.mode == .deferred && first.activatedAt != nil)
        #expect(clock.now.timeIntervalSince(started) >= 120, "it waited the two minutes")

        let walk = try Self.rig()
        defer { walk.cleanUp() }
        try walk.giveHistory()
        walk.createKnowledgeZone()
        walk.server.failNext(.allZones, container: FakeCloudKit.legacyContainer, times: 10_000, with: unreachable)
        let walkClock = ActivationClock()
        let walkStarted = walkClock.now
        let second = try await Self.run(walk, Self.environment(walk, clock: walkClock))
        #expect(second.mode == .deferred && second.activatedAt != nil && second.catchUpAt == nil)
        #expect(walkClock.now.timeIntervalSince(walkStarted) >= 120)
        try walk.receiver.exec("CREATE TABLE IF NOT EXISTS gate_probe (x INTEGER)")
    }

    // MARK: Start order

    @Test("The MCP server and the relay start only after activated_at: the gate holds them until the activation opens it")
    func gateHoldsTheServer() async throws {
        let gate = GenerationActivationGate()
        await gate.close()
        let reached = Flag()
        let waiter = Task {
            await gate.waitUntilOpen()
            reached.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reached.isSet)
        await gate.open()
        await waiter.value
        #expect(reached.isSet)
        let open = GenerationActivationGate()
        await open.waitUntilOpen()
    }

    @Test("A gate made closed holds from the first instant, with no close() call to be late for (F28)")
    func gateBornClosedHolds() async throws {
        let gate = GenerationActivationGate(isOpen: false)
        let reached = Flag()
        let waiter = Task {
            await gate.waitUntilOpen()
            reached.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reached.isSet, "a writer that starts before the launcher closes anything is held")
        await gate.open()
        await waiter.value
        #expect(reached.isSet)
    }

    // MARK: Held bodies (R8-m8)

    @Test("A document.remote.md becomes one Recovered Doc before the derivations in every mode, and the file is gone once that Doc is projected",
          arguments: [false, true])
    func heldRemoteBodyBecomesARecoveredDoc(hasHistory: Bool) async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        try rig.receiver.saveArtifactRecord(Rig.artifact("doc-h", title: "Held"))
        try rig.receiver.saveArtifactMarkdownFromSync("# Mine\n", artifactID: "doc-h")
        try rig.receiver.saveArtifactHeldRemoteMarkdown("# The other writer's\n", artifactID: "doc-h")
        var environment = Self.environment(rig)
        environment.derivations = KnowledgeStore.activationDerivations
        if hasHistory {
            try rig.giveHistory()
            rig.server.signIn(rig.oldContainer, as: nil)
        }

        let journal = try await Self.run(rig, environment)
        #expect(journal.mode == (hasHistory ? .deferred : .fresh))
        let recoveredID = RecoveredDoc.id(artifactID: "doc-h", hash: SyncIdentity.sha256Hex(Data("# The other writer's\n".utf8)))
        #expect(try rig.recoveredDocs() == [recoveredID])
        #expect(try rig.receiverBody(recoveredID) == "# The other writer's\n")
        #expect(try rig.receiver.loadArtifactHeldRemoteMarkdown("doc-h") == nil, "the held body is removed once its Doc is projected")
        #expect(try rig.receiverBody("doc-h") == "# Mine\n")
    }
}
