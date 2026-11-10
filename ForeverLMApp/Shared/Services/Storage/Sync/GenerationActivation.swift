import CloudKit
import Foundation
import OSLog

/// How a store's generation-2 activation runs (D46, docs/cloudkit-schema-design.md §13.3 step 3).
enum ActivationMode: String, Sendable, Equatable {
    /// Generation-1 sync history and an iCloud account: the legacy catch-up runs inside the activation.
    case full
    /// No generation-1 sync history: no catch-up and no network call; the Mac joins as a new device.
    case fresh
    /// History, but no account or no iCloud: activated at once; the catch-up runs later.
    case deferred
}

/// Why a `fresh` activation is fresh.
enum FreshReason: String, Sendable, Equatable {
    case noHistory
    case knowledgeMissing
}

struct ActivationModeDecision: Equatable, Sendable {
    let mode: ActivationMode
    let freshReason: FreshReason?
    let account: String?

    static let freshNoHistory = ActivationModeDecision(mode: .fresh, freshReason: .noHistory, account: nil)
}

/// The activation's steps in order (§13.3 step 3): a the recorded copy, b the legacy catch-up, c each
/// registered derivation, d the triggers, e `activated_at`. The journal names the step it is in, and a
/// launch after a crash or a quit resumes there.
enum ActivationStep: Equatable, Sendable {
    case recordCopy
    case catchUp
    case derive(String)
    case triggers
    case activated

    var rawValue: String {
        switch self {
        case .recordCopy: return "copy"
        case .catchUp: return "catchUp"
        case .derive(let id): return "derive:" + id
        case .triggers: return "triggers"
        case .activated: return "activated"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "copy": self = .recordCopy
        case "catchUp": self = .catchUp
        case "triggers": self = .triggers
        case "activated": self = .activated
        default:
            guard rawValue.hasPrefix("derive:") else { return nil }
            self = .derive(String(rawValue.dropFirst("derive:".count)))
        }
    }
}

/// `ck_activation`'s one row (id 1).
struct ActivationJournal: Equatable, Sendable {
    var step: ActivationStep?
    var mode: ActivationMode?
    var freshReason: FreshReason?
    /// The old container's user record name (§13.3, §2.5).
    var account: String?
    /// The copy's file name, relative to the store's folder.
    var clonePath: String?
    /// The copy's `user_version`, read from the copy itself.
    var cloneUserVersion: Int32?
    var startedAt: Double?
    var derivedAt: Double?
    var activatedAt: Double?
    var catchUpAt: Double?
    var triggerHash: String?
}

enum GenerationActivationError: Error, LocalizedError, Equatable {
    /// The journal has no mode and the caller gave none.
    case modeUndecided

    var errorDescription: String? {
        switch self {
        case .modeUndecided:
            return "The move to the new iCloud store has not decided how to run."
        }
    }
}

/// One derivation of §13.3 step 3c: fills a v2 table or column from generation-1 truth. Registered by
/// the package that owns the table (`KnowledgeStore.activationDerivations`). Each is idempotent (an
/// upsert, `INSERT … ON CONFLICT DO UPDATE`, or an `UPDATE` from generation-1 truth; never
/// `INSERT OR REPLACE`), bounded and set-based, and runs in its own transaction.
struct ActivationDerivation: Sendable {
    let id: String
    let run: @Sendable (KnowledgeStore) throws -> Void
}

extension KnowledgeStore {
    /// The derivations this build runs at a store's activation, in order. Each projection package adds
    /// its own (WP7 to WP15b).
    static let activationDerivations: [ActivationDerivation] = heldBodyRecoveryDerivations
        + sourceActivationDerivations + notebookActivationDerivations
        + courseActivationDerivations
        + chatActivationDerivations
        + artifactActivationDerivations
        + readingActivationDerivations
        + memoryActivationDerivations
        + tasksActivationDerivations
        + personalStateActivationDerivations
        + heldBodyCleanupDerivations
}

/// A store's one-time generation-2 activation (D46, §13.3 step 3), journaled in `ck_activation`.
///
/// This holds the journal and the steps every mode shares: the recorded copy, the registered derivations, the trigger install and `activated_at`. The mode is decided once and
/// recorded: a store with no generation-1 sync history activates `fresh` with no network call; one
/// with history asks the account check (`full` when signed in, else `deferred`). WP16a adds the launch
/// order, the read-only window of a `full` activation and its fallbacks, and the legacy catch-up
/// (`catchUp`, step b, run in `full` mode only). A generation-1 build never runs this, and never opens
/// a store it activated (`KnowledgeStore.init`).
struct GenerationActivation {
    let store: KnowledgeStore
    var registry: ProjectionRegistry = KnowledgeStore.projectionRegistry
    var derivations: [ActivationDerivation] = KnowledgeStore.activationDerivations
    var now: () -> Date = Date.init

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "GenerationActivation")

    init(store: KnowledgeStore) {
        self.store = store
    }

    var storeDirectory: URL {
        URL(fileURLWithPath: store.dbPath).deletingLastPathComponent()
    }

    /// Runs the activation from the step its journal names. `decision` is recorded when the journal has
    /// no mode yet; a journal that has one keeps it. Returns the journal as it ends.
    @discardableResult
    func run(_ decision: ActivationModeDecision?) throws -> ActivationJournal {
        try finish(try start(decision))
    }

    /// The first half (§13.3 step 3, steps before the catch-up): the mode is decided and recorded, and
    /// the copy and the rollback build are recorded (step a). The journal then names step b. The async
    /// catch-up of a `full` activation runs between this and `finish` (`GenerationActivationRunner`).
    func start(_ decision: ActivationModeDecision?) throws -> ActivationJournal {
        var journal = try store.activationJournal() ?? ActivationJournal()
        if journal.activatedAt != nil { return journal }
        if journal.mode == nil {
            guard let decision else { throw GenerationActivationError.modeUndecided }
            journal.mode = decision.mode
            journal.freshReason = decision.freshReason
            journal.account = decision.account
            journal.startedAt = now().timeIntervalSinceReferenceDate
            journal.step = .recordCopy
            try store.writeActivationJournal(journal)
            Self.logger.notice("Activation started, mode \(decision.mode.rawValue, privacy: .public)")
        }
        // Step a recorded the rollback copy a store's first generation-2 launch took. No library is
        // copied any more (every store this build opens is past generation 1), so a journal at it moves on.
        if (journal.step ?? .recordCopy) == .recordCopy {
            try advance(&journal, to: .catchUp)
        }
        return journal
    }

    /// The second half: step b's synchronous hook, the derivations, the triggers and `activated_at`.
    @discardableResult
    func finish(_ started: ActivationJournal) throws -> ActivationJournal {
        var journal = try store.activationJournal() ?? started
        if journal.activatedAt != nil { return journal }
        var step = journal.step ?? .catchUp
        if step == .catchUp {
            step = derivations.first.map { .derive($0.id) } ?? .triggers
            try advance(&journal, to: step)
        }
        if case .derive(let id) = step {
            // A derivation this build no longer registers starts the list over: each is idempotent.
            let start = derivations.firstIndex { $0.id == id } ?? 0
            for (index, derivation) in derivations.enumerated() where index >= start {
                try advance(&journal, to: .derive(derivation.id))
                try derivation.run(store)
            }
            journal.derivedAt = now().timeIntervalSinceReferenceDate
            step = .triggers
            try advance(&journal, to: step)
        }
        if step == .triggers {
            journal.triggerHash = try store.installOutboxTriggers(registry)
            step = .activated
            try advance(&journal, to: step)
        }
        if step == .activated, journal.activatedAt == nil {
            journal.activatedAt = now().timeIntervalSinceReferenceDate
            try store.writeActivationJournal(journal)
            Self.logger.notice("Activation finished: generation 2 runs on this store")
        }
        return journal
    }

    private func advance(_ journal: inout ActivationJournal, to step: ActivationStep) throws {
        journal.step = step
        try store.writeActivationJournal(journal)
    }
}

// MARK: - The journal in the store

extension KnowledgeStore {
    func activationJournal() throws -> ActivationJournal? {
        var journal: ActivationJournal?
        try query("""
            SELECT step, mode, fresh_reason, account, clone_path, clone_user_version,
                   started_at, derived_at, activated_at, catch_up_at, trigger_hash
            FROM ck_activation WHERE id = 1
        """, []) { row in
            journal = ActivationJournal(
                step: row.text(0).flatMap(ActivationStep.init(rawValue:)),
                mode: row.text(1).flatMap(ActivationMode.init(rawValue:)),
                freshReason: row.text(2).flatMap(FreshReason.init(rawValue:)),
                account: row.text(3),
                clonePath: row.text(4),
                cloneUserVersion: row.integer(5).map { Int32(truncatingIfNeeded: $0) },
                startedAt: row.real(6),
                derivedAt: row.real(7),
                activatedAt: row.real(8),
                catchUpAt: row.real(9),
                triggerHash: row.text(10)
            )
        }
        return journal
    }

    func writeActivationJournal(_ journal: ActivationJournal) throws {
        try execute("""
            INSERT INTO ck_activation (id, step, mode, fresh_reason, account, clone_path, clone_user_version,
                started_at, derived_at, activated_at, catch_up_at, trigger_hash)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                step = excluded.step, mode = excluded.mode, fresh_reason = excluded.fresh_reason,
                account = excluded.account, clone_path = excluded.clone_path,
                clone_user_version = excluded.clone_user_version, started_at = excluded.started_at,
                derived_at = excluded.derived_at, activated_at = excluded.activated_at,
                catch_up_at = excluded.catch_up_at, trigger_hash = excluded.trigger_hash
        """, [
            .text(journal.step?.rawValue), .text(journal.mode?.rawValue), .text(journal.freshReason?.rawValue),
            .text(journal.account), .text(journal.clonePath), .integer(journal.cloneUserVersion.map(Int64.init)),
            .real(journal.startedAt),
            .real(journal.derivedAt), .real(journal.activatedAt), .real(journal.catchUpAt), .text(journal.triggerHash),
        ])
    }

    /// Whether generation 2 runs on this store (`ck_activation.activated_at`), read before any
    /// migration. A store below 154 was never activated, since the activation runs after 154, and is not
    /// read; a journal that cannot be read (a table of another shape, which 154's probe refuses) names
    /// no activation.
    func isActivatedForGeneration2() throws -> Bool {
        guard try (scalarInteger("PRAGMA user_version") ?? 0) >= 154,
              try scalarInteger("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ck_activation')") == 1
        else { return false }
        return (try? scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_activation WHERE id = 1 AND activated_at IS NOT NULL)")) == 1
    }
}
