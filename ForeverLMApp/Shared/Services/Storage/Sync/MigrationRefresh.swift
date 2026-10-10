import Foundation

// MARK: - The refresh (docs/cloudkit-schema-design.md §13.4 step 0, WP16b2)

/// A Mac's catch-up can be older than the shared base: its activation was quit after the walk and resumed
/// later, or it and another Mac walked together while the other claimed. The old-world changes made
/// between its walk and the base's reach neither its store nor its import pass, which fetches only after the
/// base's tokens. So before it reconciles (§13.5) or takes over a seed whose root holds a base (§13.4 step 1),
/// a Mac refreshes its catch-up.
///
/// It is late import's pass over this Mac's own snapshot (`ck_legacy_snapshot` and the walk's tokens,
/// `OwnSnapshotBase`) as the base, in the role `.refresh`: it fetches the old zones' changes from those
/// tokens (a payload walk diffed against the snapshot when a token has expired), maps them through
/// `LegacyV2Mapping`, and writes `ck_patches` under late import's rules of ownership for absent and removed
/// records, with three differences that the planner's options carry:
/// - it patches and removes only records the server does not hold: the server already holds every old-world
///   change made before the base, a field its older snapshot calls changed, re-applied with the old record's
///   later date, would revert a build-N edit made since, and the import pass that follows brings the changes
///   made since the base (R7-x1);
/// - its world is this Mac's own rows: a record the server does not hold is held as its rows encode it, and a
///   body this Mac holds no edit of is the one it last synced;
/// - its question, its journal and its waiting list are its own (`MigrationPassKind.refresh`), and its 5%
///   guard counts against the rows its own snapshot names. Apply and Keep answer it as they answer an import
///   pass (R7-m3); while it waits, the Mac does not reconcile, take over or send (R8-m5).
/// Once its patches are acknowledged it advances its own snapshot, so a later refresh, after a relaunch or a
/// takeover, starts from there (R5-m12), and it lists what it created in a manifest delta (R5-3).
///
/// A store with no snapshot has nothing to refresh: a `fresh` one, a deferred one before its catch-up, a
/// `knowledgeMissing` one, which never reads the old zones for itself again (§13.3 step 3).
struct MigrationRefresh: Sendable {
    enum Outcome: Equatable, Sendable {
        /// No snapshot, or a `knowledgeMissing` store: nothing to catch up with.
        case nothingToRefresh
        /// This Mac's fetch of the new container is not complete, so a record that has not arrived yet could
        /// be taken for absent.
        case notReady
        case accountChanged
        /// A tripped 5% guard's question (Apply or Keep) waits for the learner.
        case waitingForQuestion
        /// An earlier refresh's patches are on their way; the snapshot moves once they are acknowledged. Its
        /// patches already stand as pending changes, and what the old world changed since is the import
        /// pass's.
        case waitingForAcknowledgement
        case guardTripped(MigrationImportGuardQuestion)
        case refreshed(MigrationPassReport)
    }

    let oldContainer: any CloudTransport
    let store: PrivateSyncLocalStore
    let ledger: any MigrationManifestLedger
    let gate: any MigrationFetchGate
    let uploader: any MigrationBodyUploader
    let probe: MigrationBodyEditProbe?
    let configuration: MigrationLateImport.Configuration

    /// Whether this Mac has anything to refresh from.
    func hasSnapshot() async throws -> Bool {
        let journal = try await store.perform { state in try (state.connection as? KnowledgeStore)?.activationJournal() }
        if let journal, journal.mode == .fresh, journal.freshReason == .knowledgeMissing { return false }
        return try await OwnSnapshotBase(store: store).hasSnapshot()
    }

    /// One refresh. `guardLifted` is the answer **Apply**, which the question's own stored answer gives too.
    func run(guardLifted: Bool = false) async throws -> Outcome {
        guard try await hasSnapshot() else { return .nothingToRefresh }
        let pass = MigrationLateImport(
            oldContainer: oldContainer, store: store, base: OwnSnapshotBase(store: store), ledger: ledger, gate: gate,
            uploader: uploader, probe: probe, configuration: configuration
        )
        switch try await pass.run(role: .refresh, guardLifted: guardLifted) {
        case .notReady: return .notReady
        case .accountChanged: return .accountChanged
        case .waitingForQuestion: return .waitingForQuestion
        case .waitingForAcknowledgement: return .waitingForAcknowledgement
        case .guardTripped(let question): return .guardTripped(question)
        case .imported(let report): return .refreshed(report)
        }
    }
}
