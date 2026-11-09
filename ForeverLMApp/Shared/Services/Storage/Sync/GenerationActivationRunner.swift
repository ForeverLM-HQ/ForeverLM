import CloudKit
import Foundation
import OSLog

// MARK: - The generation-2 activation, with its network steps (docs/cloudkit-schema-design.md §13.3 step 3, D46)

/// What the old container's account check found.
enum ActivationAccountProbe: Equatable, Sendable {
    case signedIn(userRecordName: String)
    /// Signed out, or iCloud off for ForeverLM: no account to catch up with.
    case noAccount
    /// iCloud could not be asked (no network, a throttle, `couldNotDetermine`): worth waiting for.
    case unreachable
}

struct ActivationEnvironment: Sendable {
    /// The old container's transport, which only a test passes: no build is entitled to the old
    /// container (it stayed with the old Apple team), so in the app a store with history has no account
    /// and activates `deferred`, and its deferred catch-up finds no old world.
    var oldContainerTransport: (any CloudTransport)?
    /// How long an unreachable iCloud is waited for before the activation continues as `deferred`.
    var reachabilityTimeout: TimeInterval = 120
    var retryInterval: TimeInterval = 5
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var catchUp = MigrationCatchUpConfiguration()
    var status = ActivationStatus.shared
    /// A test's own derivations and trigger registry; nil runs the build's.
    var derivations: [ActivationDerivation]?
    var registry: ProjectionRegistry?
}

/// Runs a store's one-time activation (§13.3 step 3): decide the mode, take the recorded copy, run the
/// full mode's catch-up with its fallbacks, then the derivations, the triggers and `activated_at`. The
/// steps are the journal's (`GenerationActivation`); this adds what needs the network and the window:
/// the account check, the 2-minute wait, the read-only window of a `full` activation, a missing
/// `Knowledge` zone (`fresh`, nothing deleted), a tripped 5% guard (`deferred` while the question
/// waits). It resumes from the journal after a quit or a crash.
struct GenerationActivationRunner: Sendable {
    let access: any MigrationStoreAccess
    var environment: ActivationEnvironment

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "GenerationActivation")

    enum CatchUpResolution: Equatable, Sendable {
        case applied(MigrationCatchUpReport)
        case noOldWorld(account: String?)
        case guardTripped(MigrationGuardQuestion)
        /// iCloud stayed unreachable for the whole wait.
        case unreachable
    }

    init(access: any MigrationStoreAccess, environment: ActivationEnvironment) {
        self.access = access
        self.environment = environment
    }

    /// Called as a store opens: one that is not activated and holds generation-1 history, or whose journal
    /// says `full`, is read-only until the runner has decided and finished (it lifts the hold at once when
    /// the mode is not `full`), so nothing writes between the open and the decision (§13.3). Once this
    /// process's runner has decided, an open holds nothing: a store opened after a failed activation is
    /// writable, as the runner left the library. The runner's own steps pass the hold
    /// (`KnowledgeStoreWriteGate.allowingWrites`), even while another store's open holds the path again.
    static func holdIfActivationMayBeFull(_ store: KnowledgeStore) {
        guard store.dbPath != ":memory:", (try? store.isActivatedForGeneration2()) == false else { return }
        let journal = try? store.activationJournal()
        let mayBeFull: Bool
        if let mode = journal?.mode {
            mayBeFull = mode == .full
        } else {
            mayBeFull = (try? GenerationActivation.hasGeneration1History(store)) == true
        }
        if mayBeFull { KnowledgeStoreWriteGate.holdAtOpen(databaseAt: store.dbPath) }
    }

    /// The account check of §13.3: signed in, no account, or unreachable.
    static func probe(_ transport: any CloudTransport) async -> ActivationAccountProbe {
        do {
            switch try await transport.accountStatus() {
            case .available: return .signedIn(userRecordName: try await transport.userRecordName())
            case .noAccount, .restricted: return .noAccount
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    /// The mode (§13.3): no history is `fresh` at once with no network call; history with an account is
    /// `full`; history with none, or an iCloud that stays unreachable for the wait, is `deferred`.
    func decideMode(hasHistory: Bool) async -> ActivationModeDecision {
        guard hasHistory else { return .freshNoHistory }
        let deferred = ActivationModeDecision(mode: .deferred, freshReason: nil, account: nil)
        guard let transport = environment.oldContainerTransport else { return deferred }
        let deadline = environment.now().addingTimeInterval(environment.reachabilityTimeout)
        while true {
            switch await Self.probe(transport) {
            case .signedIn(let name): return ActivationModeDecision(mode: .full, freshReason: nil, account: name)
            case .noAccount: return deferred
            case .unreachable:
                if environment.now() >= deadline { return deferred }
                await environment.sleep(environment.retryInterval)
            }
        }
    }

    /// Runs the activation to `activated_at`. Returns the journal as it ends.
    @discardableResult
    func run() async throws -> ActivationJournal {
        let status = environment.status
        let existing = try await access.perform { try $0.activationJournal() }
        if let existing, existing.activatedAt != nil {
            // A relaunch of an activated store: the copy the first launch's check has since passed replaces
            // the generation-1 one, which stays only until then (F30).
            let folder = try await access.perform { URL(fileURLWithPath: $0.dbPath).deletingLastPathComponent() }
            GenerationActivation.removeStalePre154Copy(in: folder)
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
            if let question = try await access.perform({ try ActivationQuestion.load($0) }), question.answer == nil {
                // The 5% question is still unanswered: the window asks again (F30).
                status.update(.asking(question.question))
            } else {
                status.update(.done)
            }
            return existing
        }
        var decision: ActivationModeDecision?
        if existing?.mode == nil {
            let hasHistory = try await access.perform { try GenerationActivation.hasGeneration1History($0) }
            decision = await decideMode(hasHistory: hasHistory)
        }
        let mode = existing?.mode ?? decision?.mode ?? .fresh
        let path = try await access.perform { $0.dbPath }
        if mode == .full {
            KnowledgeStoreWriteGate.hold(databaseAt: path)
            status.update(.moving(step: 1, total: ActivationStatus.steps, text: "Saving a copy of your library"))
        } else {
            KnowledgeStoreWriteGate.release(databaseAt: path)
            status.update(.preparing)
        }
        do {
            let journal = try await runSteps(decision: decision, path: path)
            KnowledgeStoreWriteGate.release(databaseAt: path)
            if let question = try await access.perform({ try ActivationQuestion.load($0) }), question.answer == nil {
                status.update(.asking(question.question))
            } else {
                status.update(.done)
            }
            return journal
        } catch is CancellationError {
            // Not finished, and not failed: the journal stays where it was and the next launch resumes.
            KnowledgeStoreWriteGate.release(databaseAt: path)
            status.update(.preparing)
            throw CancellationError()
        } catch {
            // The store is writable again, though not activated: its writes need no trigger, since the
            // next activation derives everything from generation-1 truth.
            KnowledgeStoreWriteGate.release(databaseAt: path)
            status.update(.failed(error.localizedDescription))
            throw error
        }
    }

    private func runSteps(decision: ActivationModeDecision?, path: String) async throws -> ActivationJournal {
        let environment = self.environment
        let status = environment.status
        var journal = try await access.perform { store in try GenerationActivation(store: store).configured(environment).start(decision) }
        if journal.mode == .full, (journal.step ?? .catchUp) == .catchUp {
            status.update(.moving(step: 2, total: ActivationStatus.steps, text: "Reading your library in the old iCloud store"))
            let resolution = try await runCatchUp()
            switch resolution {
            case .applied(let report):
                // A record that did not apply keeps its old tag and has no snapshot row: it is named here so a
                // failed catch-up is never silent (F9).
                if !report.failed.isEmpty {
                    Self.logger.error("The migration catch-up left \(report.failed.count, privacy: .public) old records unapplied")
                }
            case .noOldWorld(let account):
                // No old world: nothing is deleted, and nothing is uploaded until the learner confirms.
                try await access.perform { store in
                    var journal = try store.activationJournal() ?? ActivationJournal()
                    journal.mode = .fresh
                    journal.freshReason = .knowledgeMissing
                    journal.account = journal.account ?? account
                    try store.writeActivationJournal(journal)
                }
                KnowledgeStoreWriteGate.release(databaseAt: path)
            case .guardTripped(let question):
                try await access.perform { store in
                    try ActivationQuestion.ask(question, store: store)
                    var journal = try store.activationJournal() ?? ActivationJournal()
                    journal.mode = .deferred
                    try store.writeActivationJournal(journal)
                }
                KnowledgeStoreWriteGate.release(databaseAt: path)
            case .unreachable:
                try await access.perform { store in
                    var journal = try store.activationJournal() ?? ActivationJournal()
                    journal.mode = .deferred
                    try store.writeActivationJournal(journal)
                }
                KnowledgeStoreWriteGate.release(databaseAt: path)
            }
        }
        status.update(KnowledgeStoreWriteGate.isHeld(databaseAt: path)
            ? .moving(step: 4, total: ActivationStatus.steps, text: "Preparing your library for the new iCloud store") : .preparing)
        journal = try await access.perform { store in try GenerationActivation(store: store).configured(environment).finish(journal) }
        return journal
    }

    /// The full catch-up with its fallbacks: a walk that fails for the network's sake is tried again until
    /// the wait is over, and then the activation continues as `deferred` (§13.3). A cancelled run (the
    /// window closed, a quit) is not finished and is not `deferred`: it rethrows, the journal stays at the
    /// catch-up and the next launch runs it again.
    func runCatchUp() async throws -> CatchUpResolution {
        guard let transport = environment.oldContainerTransport else { return .unreachable }
        let deadline = environment.now().addingTimeInterval(environment.reachabilityTimeout)
        let status = environment.status
        var catchUp = MigrationCatchUp(transport: transport, access: access, configuration: environment.catchUp)
        catchUp.progress = { text in status.update(.moving(step: 3, total: ActivationStatus.steps, text: text)) }
        while true {
            try Task.checkCancellation()
            do {
                switch try await catchUp.run() {
                case .applied(let report): return .applied(report)
                case .noOldWorld(let account): return .noOldWorld(account: account)
                case .guardTripped(let question): return .guardTripped(question)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.error("The migration catch-up could not finish: \(String(describing: error), privacy: .public)")
                if environment.now() >= deadline { return .unreachable }
                let wait = (error as? CloudError)?.retryAfter ?? environment.retryInterval
                await environment.sleep(max(wait, environment.retryInterval))
            }
        }
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
