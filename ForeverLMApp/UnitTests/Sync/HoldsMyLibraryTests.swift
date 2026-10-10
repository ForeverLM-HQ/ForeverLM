import Foundation
import Testing
@testable import ForeverLM

/// The seeder's and the catch-up's side of "This Mac holds my library" (WP16 and WP16b own the real
/// ones): every call the flow makes, in order, and what a claim answers.
actor FakeLibraryClaimer: LibraryClaiming {
    enum Call: Equatable { case catchUp(readsOldZones: Bool), claim(baseNamesOldZones: Bool) }

    private(set) var calls: [Call] = []
    var claimAnswers: [LibraryClaimOutcome] = [.seeding]
    var catchUpFails = false

    struct Offline: Error {}

    func answer(_ answers: [LibraryClaimOutcome]) { claimAnswers = answers }
    func failCatchUp(_ fails: Bool) { catchUpFails = fails }

    func runDeferredCatchUp(readsOldZones: Bool) async throws {
        calls.append(.catchUp(readsOldZones: readsOldZones))
        if catchUpFails { throw Offline() }
    }

    func claimOrReconcile(baseNamesOldZones: Bool) async throws -> LibraryClaimOutcome {
        calls.append(.claim(baseNamesOldZones: baseNamesOldZones))
        return claimAnswers.isEmpty ? .notYet : claimAnswers.removeFirst()
    }
}

actor InMemoryHoldsMyLibraryRecord: HoldsMyLibraryRecord {
    private(set) var stored: HoldsMyLibraryConfirmation?
    func load() async throws -> HoldsMyLibraryConfirmation? { stored }
    func save(_ confirmation: HoldsMyLibraryConfirmation) async throws { stored = confirmation }
}

/// "This Mac holds my library" (docs/cloudkit-schema-design.md §13.5, D37, D46; R4-m7, R5-m6, R5-m7,
/// R6-m9): a `fresh` Mac with a library (its sync history cleared at sign-out) and a `pending` root, or
/// one that found its `Knowledge` zone missing, uploads nothing until the learner confirms; after
/// confirming it catches up, claims and seeds, or reconciles when a seed is complete.
@Suite("Holds my library", .serialized)
struct HoldsMyLibraryTests {
    private typealias Standing = HoldsMyLibrary.Standing

    private static func inputs(mode: ActivationMode? = .fresh, reason: FreshReason? = .noHistory, library: Bool = true,
                               root: HoldsMyLibrary.RootState, confirmation: HoldsMyLibraryConfirmation? = nil) -> HoldsMyLibrary.Inputs {
        HoldsMyLibrary.Inputs(mode: mode, freshReason: reason, holdsLibrary: library, root: root, confirmation: confirmation)
    }

    private static let at = Date(timeIntervalSinceReferenceDate: 812_000_000)

    // MARK: What is offered, and what may be sent

    @Test("A fresh Mac with a library and a pending root uploads nothing until the learner confirms")
    func pendingRootWaitsForTheLearner() async throws {
        let standing = HoldsMyLibrary.standing(Self.inputs(root: .pending))
        #expect(standing == .offer(.pendingRoot))
        #expect(standing.offersTheButton)
        #expect(!standing.mayClaim, "it takes no claim, sends nothing")

        // Nothing has asked the seeder or the catch-up for anything.
        let claimer = FakeLibraryClaimer()
        #expect(await claimer.calls.isEmpty)
    }

    @Test("After confirming, it runs the catch-up, then claims, and may then send")
    func confirmingCatchesUpThenClaims() async throws {
        let claimer = FakeLibraryClaimer()
        let record = InMemoryHoldsMyLibraryRecord()
        let flow = HoldsMyLibraryFlow(record: record, claimer: claimer, now: { Self.at })
        let progress = try await flow.confirm(freshReason: .noHistory)
        #expect(await claimer.calls == [.catchUp(readsOldZones: true), .claim(baseNamesOldZones: true)])
        #expect(progress == HoldsMyLibrary.Progress(catchUpDone: true, outcome: .seeding))

        let stored = try #require(await record.stored)
        let standing = HoldsMyLibrary.standing(Self.inputs(root: .pending, confirmation: stored))
        #expect(standing == .confirmed(HoldsMyLibrary.Progress(catchUpDone: true, outcome: .seeding)))
        #expect(standing.mayClaim)
        #expect(!standing.offersTheButton)
    }

    @Test("Confirmed but before the catch-up has run, the Mac still sends nothing")
    func confirmedIsNotYetCaughtUp() {
        let confirmation = HoldsMyLibraryConfirmation(confirmedAt: Self.at, catchUpAt: nil, outcome: nil)
        let standing = HoldsMyLibrary.standing(Self.inputs(root: .pending, confirmation: confirmation))
        #expect(standing == .confirmed(HoldsMyLibrary.Progress(catchUpDone: false, outcome: nil)))
        #expect(!standing.mayClaim)
    }

    @Test("A full activation that found its Knowledge zone missing asks first, with any root")
    func knowledgeMissingAsksFirst() {
        for root: HoldsMyLibrary.RootState in [.pending, .complete, .seeding, .absent(accountIsBrandNew: false), .absent(accountIsBrandNew: true), .unknown] {
            let standing = HoldsMyLibrary.standing(Self.inputs(reason: .knowledgeMissing, root: root))
            #expect(standing == .offer(.libraryMissing), "root \(root)")
            #expect(!standing.mayClaim)
        }
    }

    @Test("With a seed already complete, confirming reconciles as a second Mac")
    func completeSeedReconciles() async throws {
        let standing = HoldsMyLibrary.standing(Self.inputs(root: .complete))
        #expect(standing == .offer(.completeSeed), "R5-m7: a never-synced library that finds a complete seed uploads nothing until the learner confirms")
        let claimer = FakeLibraryClaimer()
        await claimer.answer([.reconciling])
        let flow = HoldsMyLibraryFlow(record: InMemoryHoldsMyLibraryRecord(), claimer: claimer, now: { Self.at })
        let progress = try await flow.confirm(freshReason: .noHistory)
        #expect(progress.outcome == .reconciling)
    }

    @Test("R5-m6: a never-synced library of a brand-new account seeds at once, one whose Knowledge zone went missing asks")
    func brandNewAccountSeedsAtOnce() {
        let brandNew = HoldsMyLibrary.standing(Self.inputs(reason: .noHistory, root: .absent(accountIsBrandNew: true)))
        #expect(brandNew == .seedsAtOnce)
        #expect(brandNew.mayClaim)
        #expect(!brandNew.offersTheButton)

        let notBrandNew = HoldsMyLibrary.standing(Self.inputs(reason: .noHistory, root: .absent(accountIsBrandNew: false)))
        #expect(notBrandNew == .offer(.pendingRoot), "the old container holds a library: the root will be pending")
        #expect(!notBrandNew.mayClaim)

        let missing = HoldsMyLibrary.standing(Self.inputs(reason: .knowledgeMissing, root: .absent(accountIsBrandNew: true)))
        #expect(missing == .offer(.libraryMissing))
        #expect(!missing.mayClaim)
    }

    @Test("Another Mac that is still moving the library is waited for, and an unfetched root decides nothing")
    func otherMacAndUnknownRoot() {
        #expect(HoldsMyLibrary.standing(Self.inputs(root: .seeding)) == .waitingForOtherMac)
        #expect(HoldsMyLibrary.standing(Self.inputs(root: .unknown)) == .undecided)
        #expect(!HoldsMyLibrary.standing(Self.inputs(root: .seeding)).mayClaim)
        #expect(!HoldsMyLibrary.standing(Self.inputs(root: .unknown)).mayClaim)
    }

    @Test("Only a fresh Mac that holds a library is offered the button")
    func notApplicable() {
        #expect(HoldsMyLibrary.standing(Self.inputs(mode: .full, reason: nil, root: .pending)) == .notApplicable)
        #expect(HoldsMyLibrary.standing(Self.inputs(mode: .deferred, reason: nil, root: .complete)) == .notApplicable)
        #expect(HoldsMyLibrary.standing(Self.inputs(mode: nil, reason: nil, root: .pending)) == .notApplicable)
        #expect(HoldsMyLibrary.standing(Self.inputs(library: false, root: .pending)) == .notApplicable, "a Mac with no library never claims")
        #expect(HoldsMyLibrary.standing(Self.inputs(reason: .knowledgeMissing, library: false, root: .complete)) == .notApplicable)
    }

    // MARK: R6-m9

    @Test("After Not this library, confirming reads nothing from the old zones and the base it publishes names none")
    func notThisLibraryReadsNothing() async throws {
        let claimer = FakeLibraryClaimer()
        let flow = HoldsMyLibraryFlow(record: InMemoryHoldsMyLibraryRecord(), claimer: claimer, now: { Self.at })
        try await flow.confirm(freshReason: .knowledgeMissing)
        #expect(await claimer.calls == [.catchUp(readsOldZones: false), .claim(baseNamesOldZones: false)])
    }

    // MARK: Quits and retries

    @Test("A quit after confirming resumes at the step reached: a failed catch-up is run again, a done one is not")
    func resumes() async throws {
        let claimer = FakeLibraryClaimer()
        let record = InMemoryHoldsMyLibraryRecord()
        let flow = HoldsMyLibraryFlow(record: record, claimer: claimer, now: { Self.at })

        await claimer.failCatchUp(true)
        await #expect(throws: FakeLibraryClaimer.Offline.self) { try await flow.confirm(freshReason: .noHistory) }
        let afterFailure = try #require(await record.stored)
        #expect(afterFailure.catchUpAt == nil && afterFailure.outcome == nil, "the confirmation stands, the catch-up is still owed")
        #expect(!HoldsMyLibrary.standing(Self.inputs(root: .pending, confirmation: afterFailure)).mayClaim)

        await claimer.failCatchUp(false)
        await claimer.answer([.notYet, .seeding])
        let first = try await flow.confirm(freshReason: .noHistory)
        #expect(first.outcome == .notYet, "the root is not there yet: tried again later")
        let afterFirst = try #require(await record.stored)
        #expect(HoldsMyLibrary.standing(Self.inputs(root: .pending, confirmation: afterFirst)).mayClaim, "caught up: it may try the claim again")
        let second = try await flow.confirm(freshReason: .noHistory)
        #expect(second.outcome == .seeding)
        #expect(await claimer.calls == [
            .catchUp(readsOldZones: true), .catchUp(readsOldZones: true), .claim(baseNamesOldZones: true), .claim(baseNamesOldZones: true),
        ], "the catch-up that finished is not run a third time")

        // A third call after the claim holds changes nothing.
        _ = try await flow.confirm(freshReason: .noHistory)
        #expect(await claimer.calls.count == 4)
    }

    @Test("The confirmation survives in the store's engine state, which a relaunch reads")
    func confirmationIsDurable() throws {
        let root = try Schema154Fixture.temporaryRoot("holds-library")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153, generation: .one)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(try store.holdsMyLibraryConfirmation() == nil)
        let confirmation = HoldsMyLibraryConfirmation(confirmedAt: Self.at, catchUpAt: Self.at.addingTimeInterval(60), outcome: .reconciling)
        try store.writeHoldsMyLibraryConfirmation(confirmation)
        #expect(try store.holdsMyLibraryConfirmation() == confirmation)
        try store.writeHoldsMyLibraryConfirmation(nil)
        #expect(try store.holdsMyLibraryConfirmation() == nil)
    }

    @Test("The dialog says what confirming does, and that a signed-out Mac's old deletions come back")
    func confirmationText() {
        #expect(HoldsMyLibrary.confirmationText(.pendingRoot).contains("comes back"))
        #expect(HoldsMyLibrary.confirmationText(.completeSeed) == HoldsMyLibrary.confirmationText(.pendingRoot))
        #expect(HoldsMyLibrary.confirmationText(.libraryMissing).contains("reads nothing from the old iCloud library"))
    }
}
