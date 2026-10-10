import Foundation

// MARK: - What runs before a reconcile or a takeover (docs/cloudkit-schema-design.md §13.4 steps 0 and 1, §13.5, WP16b2)

/// The passes a Mac runs before it reconciles (§13.5) or takes over a seed whose root holds a base (§13.4
/// step 1): its **refresh**, so its store is at least as new as any base whichever Mac walked first, and then
/// **one import pass from the shared base** (§13.6), whose patches carry every old-world change made since the
/// base's tokens. After a takeover the Mac is the importer, so the base and the tokens advance once those
/// patches are acknowledged; a Mac that reconciles is a non-importer, which writes the same patches and
/// leaves the base alone, so the pass is idempotent.
///
/// While the question of either pass (Apply or Keep, §13.6) waits, nothing proceeds: the Mac neither
/// reconciles, takes over nor sends (R8-m5). WP16's `CutoverSeedEnvironment.afterTakeover` and
/// `beforeReconcile` are these two entry points, which answer false while a question waits.
struct MigrationCutoverPasses: Sendable {
    enum Failure: Error, Equatable {
        /// This Mac's fetch of `Library`, `Catalog` and every space is not complete: a record that has not
        /// arrived yet must never be taken for absent, so nothing runs and the caller tries again.
        case fetchIncomplete
        /// Another account is signed in than the one the activation recorded (§2.5).
        case accountChanged
    }

    /// What the two passes did.
    struct Result: Equatable, Sendable {
        /// The Mac may go on to reconcile, claim and send.
        var proceeds: Bool
        var refresh: MigrationRefresh.Outcome?
        var imported: MigrationPassOutcome?
    }

    let store: PrivateSyncLocalStore
    let gate: any MigrationFetchGate
    let refresh: MigrationRefresh
    /// The import pass over the shared base.
    let importPass: MigrationLateImport

    /// Before a second Mac reconciles (§13.5): false while a question waits.
    func beforeReconcile() async throws -> Bool {
        try await run(role: .other).proceeds
    }

    /// After a takeover's claim (§13.4 step 1): the Mac is the importer. False while a question waits.
    func afterTakeover() async throws -> Bool {
        try await run(role: .importer).proceeds
    }

    func run(role: MigrationImportRole) async throws -> Result {
        if try await store.perform({ try MigrationImportState.waitingQuestion($0.connection) }) != nil {
            return Result(proceeds: false)
        }
        guard try await gate.isComplete() else { throw Failure.fetchIncomplete }

        let refreshed = try await refresh.run()
        switch refreshed {
        case .accountChanged: throw Failure.accountChanged
        case .notReady: throw Failure.fetchIncomplete
        case .waitingForQuestion, .guardTripped: return Result(proceeds: false, refresh: refreshed)
        // An earlier refresh's patches are on their way: they already stand as pending changes, and what the
        // old world changed since is the import pass's.
        case .nothingToRefresh, .waitingForAcknowledgement, .refreshed: break
        }

        let imported = try await importPass.run(role: role)
        switch imported {
        case .accountChanged: throw Failure.accountChanged
        case .waitingForQuestion, .guardTripped: return Result(proceeds: false, refresh: refreshed, imported: imported)
        // No base on the root (nothing to import from), or the importer's earlier patches still on their way
        // (the next pass finishes the advance): the Mac goes on.
        case .notReady, .waitingForAcknowledgement, .imported: return Result(proceeds: true, refresh: refreshed, imported: imported)
        }
    }
}
