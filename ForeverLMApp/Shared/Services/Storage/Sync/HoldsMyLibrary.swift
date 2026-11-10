import Foundation
import OSLog

/// "This Mac holds my library" (docs/cloudkit-schema-design.md §13.5, D37, D46; R4-m7, R5-m6, R5-m7,
/// R6-m9).
///
/// Generation 1 forgets its sync history when a Mac signs out or switches accounts, so a Mac that was
/// signed out at T0 activates `fresh` although it holds the account's library, and a library may
/// also belong to another account. Such a Mac uploads nothing until the learner confirms in
/// Settings › iCloud. Confirming runs the deferred catch-up, then claims the seed (with its snapshot as
/// the base) or, when another Mac has seeded meanwhile, reconciles as a second Mac.
///
/// What a Mac may do is decided here from four facts and nothing else: the activation's mode and
/// `fresh_reason`, whether the store holds a library, what the account's root says, and whether the
/// learner confirmed. WP16's coordinator reads `Standing.mayClaim` to choose `ZoneBootstrap.Client`,
/// and the seeder and the engine send nothing while it is false.
enum HoldsMyLibrary {
    /// What the new container's `Library` root says about the account.
    enum RootState: Equatable, Sendable {
        /// Not fetched yet: nothing is decided.
        case unknown
        /// No root. `accountIsBrandNew` is true when the old container's lookup succeeded and found no
        /// `Knowledge` zone (§2.4).
        case absent(accountIsBrandNew: Bool)
        /// `seed.state = pending`: a Mac with no library made it, and no Mac has claimed.
        case pending
        /// Another Mac holds a live claim and has not finished its metadata.
        case seeding
        /// `seed.metadataCompleteAt` is set.
        case complete
    }

    enum Offer: Equatable, Sendable {
        /// A `fresh` Mac with a library, and a root that waits for the Mac that holds the library (R4-m7).
        case pendingRoot
        /// A `fresh` Mac whose never-synced library meets a complete seed (R5-m7).
        case completeSeed
        /// The old `Knowledge` zone was missing, or the 5% guard was answered "Not this library" (R5-m6, R6-m9).
        case libraryMissing
    }

    enum Standing: Equatable, Sendable {
        /// Not a `fresh` Mac with a library: a `full` or `deferred` activation takes its own path, and a
        /// Mac with no library never claims (§13.5, last paragraph).
        case notApplicable
        case undecided
        /// A never-synced library of a brand-new account (`noHistory`, no root): it seeds at once (§2.4, R5-m6).
        case seedsAtOnce
        /// Nothing is uploaded until the learner confirms.
        case offer(Offer)
        /// Another Mac is moving the library; the offer comes when its metadata is in.
        case waitingForOtherMac
        /// The learner confirmed: the catch-up, the claim and the seed or the reconcile follow, resumed
        /// after a quit from `progress`.
        case confirmed(Progress)

        /// Whether this Mac may claim the seed, take the maintenance lease and send its library.
        var mayClaim: Bool {
            switch self {
            case .seedsAtOnce: return true
            case .confirmed(let progress): return progress.catchUpDone
            default: return false
            }
        }

        var offersTheButton: Bool {
            if case .offer = self { return true }
            return false
        }
    }

    struct Progress: Equatable, Sendable {
        var catchUpDone: Bool
        var outcome: LibraryClaimOutcome?
    }

    struct Inputs: Equatable, Sendable {
        var mode: ActivationMode?
        var freshReason: FreshReason?
        var holdsLibrary: Bool
        var root: RootState
        var confirmation: HoldsMyLibraryConfirmation?
    }

    static func standing(_ inputs: Inputs) -> Standing {
        guard inputs.mode == .fresh, inputs.holdsLibrary else { return .notApplicable }
        if let confirmation = inputs.confirmation {
            return .confirmed(Progress(catchUpDone: confirmation.catchUpAt != nil, outcome: confirmation.outcome))
        }
        if inputs.freshReason == .knowledgeMissing { return .offer(.libraryMissing) }
        switch inputs.root {
        case .unknown:
            return .undecided
        case .absent(let brandNew):
            // A brand-new account has no library anywhere else, so this one seeds at once. Otherwise the
            // Mac makes a pending root as a client with no library does, and waits for the learner.
            return brandNew ? .seedsAtOnce : .offer(.pendingRoot)
        case .pending:
            return .offer(.pendingRoot)
        case .seeding:
            return .waitingForOtherMac
        case .complete:
            return .offer(.completeSeed)
        }
    }

    /// What the dialog says before the learner confirms. A `knowledgeMissing` store reads nothing from
    /// the old zones; with no history every old record counts as changed, so old-world deletions made since
    /// the sign-out come back (§13.5).
    static func confirmationText(_ offer: Offer) -> String {
        switch offer {
        case .libraryMissing:
            return "This Mac uploads its own library to your iCloud and reads nothing from the old iCloud library. Do this only if this Mac's library is the one to keep."
        case .pendingRoot, .completeSeed:
            return "This Mac's library is uploaded to your iCloud. Anything you deleted on your other devices while this Mac was signed out comes back."
        }
    }
}

/// The learner's confirmation, kept in `ck_engine_state` (scope `library.holdsConfirmed`) so a quit
/// after confirming resumes at the step it reached.
struct HoldsMyLibraryConfirmation: Codable, Equatable, Sendable {
    var confirmedAt: Date
    var catchUpAt: Date?
    var outcome: LibraryClaimOutcome?

    static let scope = "library.holdsConfirmed"
}

extension KnowledgeStore {
    func holdsMyLibraryConfirmation() throws -> HoldsMyLibraryConfirmation? {
        try replica.engineState(HoldsMyLibraryConfirmation.scope).flatMap { try? Self.confirmationDecoder.decode(HoldsMyLibraryConfirmation.self, from: $0) }
    }

    func writeHoldsMyLibraryConfirmation(_ confirmation: HoldsMyLibraryConfirmation?) throws {
        try replica.setEngineState(HoldsMyLibraryConfirmation.scope, try confirmation.map(Self.confirmationEncoder.encode))
    }

    private static let confirmationEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let confirmationDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// What the flow reads and writes of the confirmation; the store's `ck_engine_state` in the app.
protocol HoldsMyLibraryRecord: Sendable {
    func load() async throws -> HoldsMyLibraryConfirmation?
    func save(_ confirmation: HoldsMyLibraryConfirmation) async throws
}

/// Confirming "This Mac holds my library": the confirmation is kept first, then the deferred catch-up
/// runs (a `knowledgeMissing` store reads nothing from the old zones, R6-m9), then the claim. A quit between steps resumes at the step reached; a claim that cannot
/// be made yet (the root is being made, the claim was lost) leaves the confirmation standing and is
/// tried again.
struct HoldsMyLibraryFlow: Sendable {
    let record: any HoldsMyLibraryRecord
    let claimer: any LibraryClaiming
    var now: @Sendable () -> Date = { Date() }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "HoldsMyLibrary")

    /// The learner pressed the button, or a relaunch resumes. Returns where the flow stands.
    @discardableResult
    func confirm(freshReason: FreshReason?) async throws -> HoldsMyLibrary.Progress {
        var confirmation = try await record.load() ?? HoldsMyLibraryConfirmation(confirmedAt: now())
        try await record.save(confirmation)
        let readsOldZones = freshReason != .knowledgeMissing

        if confirmation.catchUpAt == nil {
            try await claimer.runDeferredCatchUp(readsOldZones: readsOldZones)
            confirmation.catchUpAt = now()
            try await record.save(confirmation)
        }
        if confirmation.outcome == nil || confirmation.outcome == .notYet {
            let outcome = try await claimer.claimOrReconcile()
            confirmation.outcome = outcome
            try await record.save(confirmation)
            Self.logger.notice("This Mac holds my library: \(String(describing: outcome), privacy: .public)")
        }
        return HoldsMyLibrary.Progress(catchUpDone: true, outcome: confirmation.outcome)
    }
}
