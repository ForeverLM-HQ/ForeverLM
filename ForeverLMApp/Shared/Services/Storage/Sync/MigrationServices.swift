import Foundation

// MARK: - What Settings › iCloud's buttons ask of the cutover

/// What "This Mac holds my library" asks of the seeder and the catch-up (§13.5, WP16 and WP16b).
protocol LibraryClaiming: Sendable {
    /// The deferred catch-up, once. A `knowledgeMissing` store reads nothing from the old zones, so
    /// `readsOldZones` is false (R6-m9).
    func runDeferredCatchUp(readsOldZones: Bool) async throws
    /// Fetches the new container's root and claims the seed, or reconciles as a second Mac when another
    /// Mac has seeded meanwhile (§13.4 step 1).
    func claimOrReconcile() async throws -> LibraryClaimOutcome
}

enum LibraryClaimOutcome: Equatable, Sendable, Codable {
    /// This Mac claimed the seed and seeds.
    case seeding
    /// Another Mac has seeded: this Mac reconciles as a second Mac.
    case reconciling
    /// The root is not there yet (another device is making it) or the claim was lost: try again later.
    case notYet
}

/// What Settings › iCloud asks of the running sync session, registered when the session starts.
final class MigrationServices: @unchecked Sendable {
    static let shared = MigrationServices()

    private let lock = NSLock()
    private var claimerStorage: (any LibraryClaiming)?

    var claimer: (any LibraryClaiming)? {
        get { lock.lock(); defer { lock.unlock() }; return claimerStorage }
        set { lock.lock(); claimerStorage = newValue; lock.unlock() }
    }
}
