import Foundation

// MARK: - What Settings › iCloud reads from the migration, and what its buttons ask of it

/// What the import from the old container (late import, the refresh and the import pass before a
/// reconcile, docs/cloudkit-schema-design.md §13.6) knows, as Settings › iCloud and the removal gate
/// read it. The import owns every value; nothing here is stored by Settings.
struct OldContainerImportFacts: Equatable, Sendable {
    /// An old record whose value waits for a record the new world has not created yet (§13.6).
    struct WaitingRecord: Equatable, Sendable {
        let recordName: String
        let title: String?
        let since: Date?
    }

    /// A removal an old build made that the import did not apply, and kept (§13.6 "Kept, and listed").
    struct KeptRemoval: Equatable, Sendable, Identifiable {
        let id: String
        let what: String
        let at: Date?
    }

    /// A value dropped after 30 days of waiting (R6-m12).
    struct NotAppliedValue: Equatable, Sendable, Identifiable {
        let id: String
        let what: String
        let at: Date?
    }

    /// The 5% guard's question for an import pass or a refresh (§13.6, R7-m3): Apply or Keep.
    struct Question: Equatable, Sendable {
        enum Pass: String, Sendable { case importPass, refresh }
        let pass: Pass
        let deleting: Int
        let of: Int
    }

    /// The import watermark's `lastOldWriteAt`: the last time anything wrote an old zone.
    var lastOldZoneWriteAt: Date?
    /// The watermark's `quietSince`: the start of the current stretch without an old-zone write.
    var quietSince: Date?
    /// The watermark's `finishedAt`: set after 7 consecutive quiet days; any old-zone write clears it.
    var finishedAt: Date?
    /// The watermark's `removedAt`: when "Remove old iCloud data" ran.
    var removedAt: Date?
    var waiting: [WaitingRecord] = []
    var keptRemovals: [KeptRemoval] = []
    var notApplied: [NotAppliedValue] = []
    var question: Question?
}

/// What one final import pass found (§13.8).
enum OldContainerFinalPass: Equatable, Sendable {
    /// No old-zone write since the last pass.
    case quiet
    /// The pass found writes and imported them: the removal is aborted and the wait starts again.
    case foundWrites(count: Int)
    /// The pass would delete more than 5% and asks the learner first.
    case asksQuestion
}

/// The importer's side of the removal gate and of Settings (WP16b): late import with its base and
/// tokens. A Mac that is not the importer runs the same passes without advancing the base.
protocol OldContainerImporting: Sendable {
    func facts() async throws -> OldContainerImportFacts
    /// One late-import pass from the shared base, now, whatever the hourly schedule says.
    func runFinalPass() async throws -> OldContainerFinalPass
    /// An old-zone write ends the quiet stretch: `finishedAt` is cleared and `quietSince` restarts at `date`.
    func restartQuietWait(at date: Date) async throws
    /// "Remove old iCloud data" ran: the importer stops polling daily and keeps its weekly zone check.
    func recordRemoval(at date: Date) async throws
    /// The answer to an import pass's or a refresh's question (§13.6, R7-m3).
    func answer(_ question: OldContainerImportFacts.Question, _ answer: ImportQuestionAnswer) async throws
}

enum ImportQuestionAnswer: String, Sendable, Equatable {
    /// The pass runs once with the guard lifted.
    case apply
    /// The pass applies everything else and lists those removals as kept.
    case keep
}

/// What "This Mac holds my library" asks of the seeder and the catch-up (§13.5, WP16 and WP16b).
protocol LibraryClaiming: Sendable {
    /// The deferred catch-up, once. A `knowledgeMissing` store reads nothing from the old zones, so
    /// `readsOldZones` is false and the base it publishes names none (R6-m9).
    func runDeferredCatchUp(readsOldZones: Bool) async throws
    /// Fetches the new container's root and claims the seed with this Mac's snapshot as the base, or
    /// reconciles as a second Mac when another Mac has seeded meanwhile (§13.4 step 1).
    func claimOrReconcile(baseNamesOldZones: Bool) async throws -> LibraryClaimOutcome
}

enum LibraryClaimOutcome: Equatable, Sendable, Codable {
    /// This Mac claimed the seed and seeds.
    case seeding
    /// Another Mac has seeded: this Mac reconciles as a second Mac.
    case reconciling
    /// The root is not there yet (another device is making it) or the claim was lost: try again later.
    case notYet
}

/// The registry the packages that own the other halves fill in at launch; Settings and the removal
/// read it. Nothing is registered until WP16 (the seeder, `LibraryClaiming`) and WP16b (late import,
/// `OldContainerImporting`) wire themselves, and every control that needs one stays off until then.
final class MigrationServices: @unchecked Sendable {
    static let shared = MigrationServices()

    private let lock = NSLock()
    private var importerStorage: (any OldContainerImporting)?
    private var claimerStorage: (any LibraryClaiming)?

    var importer: (any OldContainerImporting)? {
        get { lock.lock(); defer { lock.unlock() }; return importerStorage }
        set { lock.lock(); importerStorage = newValue; lock.unlock() }
    }

    var claimer: (any LibraryClaiming)? {
        get { lock.lock(); defer { lock.unlock() }; return claimerStorage }
        set { lock.lock(); claimerStorage = newValue; lock.unlock() }
    }
}
