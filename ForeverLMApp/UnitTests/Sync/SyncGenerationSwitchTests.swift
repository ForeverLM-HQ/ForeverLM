import Foundation
import Testing
@testable import ForeverLM

/// The generation switch on the Mac (docs/cloudkit-schema-design.md §13.2, §13.3, §13.5, §14.1; WP16): what
/// the sync generation changes in the store's write path, who may start syncing and what it holds, and how
/// the cutover is reported.
@Suite("Sync generation switch", .serialized)
struct SyncGenerationSwitchTests {
    private static func store(_ name: String, generation: SyncGeneration, activated: Bool = false) throws -> (URL, KnowledgeStore) {
        let root = try Schema154Fixture.temporaryRoot(name)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: generation, freeSpace: Schema154Fixture.roomy)
        if activated {
            try store.execute("""
                INSERT INTO ck_activation (id, mode, activated_at) VALUES (1, 'full', 1)
                ON CONFLICT(id) DO UPDATE SET activated_at = 1
            """)
        }
        return (root, store)
    }

    @Test("Under generation 1 a change is queued as on build 177; a generation-2 store not yet activated queues too, for its catch-up")
    func generationOneQueuesAsEver() throws {
        for (generation, activated) in [(SyncGeneration.one, false), (.two, false)] {
            let (root, store) = try Self.store("switch-queue-\(generation.rawValue)", generation: generation, activated: activated)
            defer { try? FileManager.default.removeItem(at: root) }
            try store.markRecordChanged(entity: .learningGoal, logicalKey: "nb-1")
            try store.markTutorStateChanged(entity: .learningGoal, logicalKey: "nb-2")
            try store.markSourceProgressChanged(sourceID: "s-1")
            try store.markRecordDeleted(entity: .learningGoal, logicalKey: "nb-3")
            #expect(try store.pendingSyncChanges().count == 4, "generation \(generation.rawValue)")
        }
    }

    @Test("Once a generation-2 store is activated its changes are the triggers' alone: nothing reaches generation 1's queue")
    func activatedStoreWritesNoQueue() throws {
        let (root, store) = try Self.store("switch-activated", generation: .two, activated: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.markRecordChanged(entity: .learningGoal, logicalKey: "nb-1")
        try store.markTutorStateChanged(entity: .learningGoal, logicalKey: "nb-2")
        try store.markSourceProgressChanged(sourceID: "s-1")
        try store.markRecordDeleted(entity: .learningGoal, logicalKey: "nb-3")
        try store.enqueueCascadingRecordDeletion(entity: .learningGoal, logicalKey: "nb-4")
        #expect(try store.pendingSyncChanges().isEmpty)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM sync_changes") == 0)
    }

    private static func journal(_ mode: String, reason: String? = nil, catchUp: Double? = nil, activated: Double? = 1) -> CutoverJournal.Read {
        CutoverJournal.Read(mode: mode, freshReason: reason, startedAt: 1, catchUpAt: catchUp, account: nil, activatedAt: activated)
    }

    @Test("Who may start syncing and what it holds: a full or caught-up store holds its library, a deferred one waits for its catch-up, a fresh one with a library waits for the learner or the account's lookup")
    func readiness() {
        func decide(_ journal: CutoverJournal.Read, library: Bool = true, confirmed: Bool = false, started: Bool = false, rehearsal: Bool = false) -> CutoverReadiness {
            CutoverReadiness.decide(journal, hasLibrary: library, confirmedHoldsLibrary: confirmed, confirmationStarted: started, rehearsalSeedLocal: rehearsal)
        }
        #expect(decide(Self.journal("full", activated: nil)) == .notActivated)
        #expect(decide(Self.journal("full")) == .ready(.library))
        #expect(decide(Self.journal("full"), library: false) == .ready(.none))
        #expect(decide(Self.journal("deferred")) == .waitingForCatchUp)
        #expect(decide(Self.journal("deferred", catchUp: 5)) == .ready(.library))
        #expect(decide(Self.journal("fresh", reason: "noHistory")) == .ready(.libraryIfNewAccount))
        #expect(decide(Self.journal("fresh", reason: "noHistory"), library: false) == .ready(.none), "an empty store joins as a new device")
        #expect(decide(Self.journal("fresh", reason: "noHistory"), confirmed: true) == .ready(.library))
        #expect(decide(Self.journal("fresh", reason: "noHistory"), started: true) == .waitingForConfirmation, "a confirmation whose catch-up has not finished waits for the flow, not for a new account's lookup")
        #expect(decide(Self.journal("fresh", reason: "knowledgeMissing")) == .waitingForConfirmation)
        #expect(decide(Self.journal("fresh", reason: "knowledgeMissing"), confirmed: true) == .ready(.library))
        #expect(decide(Self.journal("fresh", reason: "noHistory"), rehearsal: true) == .ready(.library), "the Dev rehearsal override seeds a fresh library")
    }

    @Test("What \"This Mac holds my library\" reports from the root: its own seed, a complete seed to reconcile with, another Mac's live claim to wait for")
    func claimOutcomeFromTheRoot() {
        let now: Int64 = 1_000_000
        #expect(LibraryClaimOutcome.forRoot(CutoverRootState(state: "pending"), me: "aaaaaaaa", now: now) == .seeding)
        #expect(LibraryClaimOutcome.forRoot(CutoverRootState(state: "seeding", claimDevice: "aaaaaaaa", claimLeaseUntil: now + 5), me: "aaaaaaaa", now: now) == .seeding)
        #expect(LibraryClaimOutcome.forRoot(CutoverRootState(state: "seeding", claimDevice: "bbbbbbbb", claimLeaseUntil: now - 5), me: "aaaaaaaa", now: now) == .seeding, "an expired claim is taken over")
        #expect(LibraryClaimOutcome.forRoot(CutoverRootState(state: "seeding", claimDevice: "bbbbbbbb", claimLeaseUntil: now + 5), me: "aaaaaaaa", now: now) == .notYet)
        #expect(LibraryClaimOutcome.forRoot(CutoverRootState(state: "seeding", metadataCompleteAt: 5, claimDevice: "bbbbbbbb", claimLeaseUntil: now + 5), me: "aaaaaaaa", now: now) == .reconciling)
        #expect(LibraryClaimOutcome.forRoot(CutoverRootState(state: "complete"), me: "aaaaaaaa", now: now) == .reconciling)
    }

    @Test("A fresh library seeds at once only for a brand-new account; with an old library it waits as a Mac with no library would")
    func clientChoice() {
        #expect(CutoverReadiness.client(for: .library, oldLibraryExists: nil) == .macHoldingLibrary)
        #expect(CutoverReadiness.client(for: .none, oldLibraryExists: nil) == .macWithoutLibrary)
        #expect(CutoverReadiness.client(for: .libraryIfNewAccount, oldLibraryExists: false) == .macHoldingLibrary)
        #expect(CutoverReadiness.client(for: .libraryIfNewAccount, oldLibraryExists: true) == .macWithoutLibrary)
        #expect(CutoverReadiness.client(for: .libraryIfNewAccount, oldLibraryExists: nil) == nil, "a failed lookup decides nothing")
    }

    @Test("The store holds a library when any of the five library tables has a row")
    func holdsLibrary() throws {
        let (root, store) = try Self.store("switch-library", generation: .two)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try !CutoverJournal.holdsLibrary(store))
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES ('s1', 1, 'ready', 'article', 'active')")
        #expect(try CutoverJournal.holdsLibrary(store))
    }

    @Test("The hosted MCP's v2Ready report is the gateway's POST /web/cloudkit/moved with the learner's managed session, no body")
    func movedReportRequest() {
        let request = LibraryMovedReport.request(sessionToken: "session-token")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/web/cloudkit/moved")
        #expect(request.url?.host == "plugin.\(MCPBrandDomains.current)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(request.httpBody == nil)
    }

    @Test("A sync device id is eight base32 characters and never the reserved migrated-history id")
    func deviceID() {
        for _ in 0..<50 {
            let id = MacSyncDeviceID.draw()
            #expect(SyncStamp.isValidDeviceID(id) && id != MacSyncDeviceID.reserved)
        }
        #expect(!MacSyncDeviceID.isUsable(MacSyncDeviceID.reserved))
        #expect(!MacSyncDeviceID.isUsable("short"))
    }

    @Test("The status the MCP and Settings read names every phase and the cutover's state")
    func statusNames() {
        let phases: [SyncStatus.Phase] = [.idle, .starting, .noAccount, .waiting(.zonesWithoutRoot), .staysOnGeneration1, .updateRequired(minClientRevision: 2), .syncing, .upToDate, .stopped(.rootMissing), .failed("The network connection was lost.")]
        #expect(Set(phases.map(MCPDataStore.phaseName)).count == phases.count)
        // A failed round says so and why, in Settings and over MCP; it never reads as idle or up to date.
        #expect(SyncStatus(phase: .failed("The network connection was lost.")).notice?.contains("The network connection was lost.") == true)
        #expect(SyncStatus(phase: .upToDate).notice == nil)
        #expect(MCPDataStore.cutoverMessage(.waitingForSeed(holder: "macaaaaa"))?.contains("macaaaaa") == true)
        #expect(MCPDataStore.cutoverMessage(.moved) == nil)
    }
}

/// The rehearsal's isolated instance (WP28): a Development build may run on a data folder of its own, and only one.
@Suite("Isolated data folder")
struct IsolatedDataFolderTests {
    @Test("A Development build takes FOREVERLM_DATA_FOLDER_NAME as its own folder; a profile's folder, a path or a Release build never do")
    func onlyAnOwnFolderInADevelopmentBuild() {
        let name = { (value: String?, development: Bool) in
            ForeverLMRuntimeIdentity.isolatedFolderName(
                environment: value.map { ["FOREVERLM_DATA_FOLDER_NAME": $0] } ?? [:], isDevelopmentBuild: development
            )
        }
        #expect(name("ForeverLM Rehearsal", true) == "ForeverLM Rehearsal")
        #expect(name(" ForeverLM Rehearsal \n", true) == "ForeverLM Rehearsal")
        #expect(name("ForeverLM Rehearsal", false) == nil)
        #expect(name(nil, true) == nil)
        #expect(name("", true) == nil)
        #expect(name("ForeverLM Dev", true) == nil)
        #expect(name("ForeverLM", true) == nil)
        #expect(name("ForeverLM First Run", true) == nil)
        #expect(name("a/b", true) == nil)
        #expect(name(".hidden", true) == nil)
    }
}
