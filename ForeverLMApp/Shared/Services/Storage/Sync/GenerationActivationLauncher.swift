import Foundation
import OSLog

/// How the activation and the seed reach the store: one bounded step at a time.
protocol MigrationStoreAccess: Sendable {
    func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T
}

/// A store used directly (tests, and a store no actor owns).
struct DirectStoreAccess: MigrationStoreAccess {
    let store: KnowledgeStore

    func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T {
        try body(store)
    }
}

/// The activation's steps reach the store on the storage actor, one bounded step at a time.
struct StorageStoreAccess: MigrationStoreAccess {
    let storage: StorageService

    func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T {
        try await storage.performStoreWork { store in try body(store) }
    }
}

/// Runs a store's generation-2 activation at launch, before the MCP server, the relay and the background
/// writers start (§13.3 step 3). Under generation 1 it does nothing, and the gate stays open.
enum GenerationActivationLauncher {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "GenerationActivation")

    private static let lock = AppLock()
    nonisolated(unsafe) private static var started = false

    /// Closes the gate, runs the activation and opens the gate once `activated_at` is set. A failed
    /// activation leaves the gate closed and the status `failed`; the next launch resumes it. Once per
    /// process: every window's first task calls it.
    static func runAtLaunch(storage: StorageService) async {
        // A unit-test host does not activate the shared Development store (the gate stays closed, so nothing
        // that waits on it starts either).
        guard !ForeverLMRuntimeIdentity.isTestHost else { return }
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        await GenerationActivationGate.shared.close()
        // No old container: generation 1's stayed with the old Apple team, and no build is entitled to it.
        let environment = ActivationEnvironment()
        do {
            try await GenerationActivationRunner(access: StorageStoreAccess(storage: storage), environment: environment).run()
            await GenerationActivationGate.shared.open()
        } catch is CancellationError {
            // The window whose task ran it closed: the journal is where it was, and the next window's task
            // runs it again instead of leaving the gate closed until a relaunch.
            lock.lock()
            started = false
            lock.unlock()
        } catch {
            logger.error("The activation did not finish: \(String(describing: error), privacy: .public)")
        }
    }
}
