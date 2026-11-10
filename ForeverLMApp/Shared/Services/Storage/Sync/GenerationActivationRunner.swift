import CloudKit
import Foundation
import OSLog

// MARK: - The generation-2 activation, with its network steps (docs/cloudkit-schema-design.md §13.3 step 3, D46)

struct ActivationEnvironment: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var status = ActivationStatus.shared
    /// A test's own derivations and trigger registry; nil runs the build's.
    var derivations: [ActivationDerivation]?
    var registry: ProjectionRegistry?
}

/// Runs a store's one-time activation (§13.3 step 3): decide the mode, take the recorded copy, then the
/// derivations, the triggers and `activated_at`. The steps are the journal's (`GenerationActivation`).
/// No build can reach the old container (it stayed with the old Apple team). Schema 175 wrote
/// `deferred` into the journal of a store with generation-1 history, and turned a `full` journal an
/// earlier build left before its catch-up into `deferred`, so a journal with no mode activates `fresh`.
/// It resumes from the journal after a quit or a crash.
struct GenerationActivationRunner: Sendable {
    let access: any MigrationStoreAccess
    var environment: ActivationEnvironment

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "GenerationActivation")

    init(access: any MigrationStoreAccess, environment: ActivationEnvironment) {
        self.access = access
        self.environment = environment
    }

    /// The mode of a journal that has none (§13.3): `fresh`, since schema 175 recorded `deferred` for
    /// every store with generation-1 history.
    func decideMode() -> ActivationModeDecision {
        .freshNoHistory
    }

    /// Runs the activation to `activated_at`. Returns the journal as it ends.
    @discardableResult
    func run() async throws -> ActivationJournal {
        let status = environment.status
        let existing = try await access.perform { try $0.activationJournal() }
        if let existing, existing.activatedAt != nil {
            // The triggers this build's registry generates (§6.6 step 1): nothing when they match, else
            // replaced, and the rows of a table watched for the first time queued (the Ideas, 2026-10-13).
            // Until then only the activation installed them, so a projection a later build registered
            // never saw a write. A failure rolls back to the triggers the store had, which keep working for
            // everything they watched, so it is logged and the launch goes on.
            let registry = environment.registry ?? KnowledgeStore.projectionRegistry
            do {
                _ = try await access.perform { try $0.installOutboxTriggers(registry) }
            } catch {
                Self.logger.error("The outbox triggers could not be refreshed: \(error.localizedDescription, privacy: .public)")
            }
            status.update(.done)
            return existing
        }
        let decision = existing?.mode == nil ? decideMode() : nil
        status.update(.preparing)
        do {
            let journal = try await runSteps(decision: decision)
            status.update(.done)
            return journal
        } catch is CancellationError {
            // Not finished, and not failed: the journal stays where it was and the next launch resumes.
            status.update(.preparing)
            throw CancellationError()
        } catch {
            // Not activated: its writes need no trigger, since the next activation derives everything
            // from the store's rows.
            status.update(.failed(error.localizedDescription))
            throw error
        }
    }

    private func runSteps(decision: ActivationModeDecision?) async throws -> ActivationJournal {
        let environment = self.environment
        let journal = try await access.perform { store in try GenerationActivation(store: store).configured(environment).start(decision) }
        return try await access.perform { store in try GenerationActivation(store: store).configured(environment).finish(journal) }
    }
}

extension GenerationActivation {
    /// This activation with the runner's environment: the clock, and a test's derivations and registry.
    func configured(_ environment: ActivationEnvironment) -> GenerationActivation {
        var copy = self
        copy.now = environment.now
        if let derivations = environment.derivations { copy.derivations = derivations }
        if let registry = environment.registry { copy.registry = registry }
        return copy
    }
}
