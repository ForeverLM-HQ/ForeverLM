import Foundation

// MARK: - What the activation keeps and shows (docs/cloudkit-schema-design.md §13.3 step 3, WP16a)

/// A body generation 1 holds for a writer beside a Doc (`document.remote.md`, kept when its three-way
/// merge overlapped) is saved as the Recovered Doc `recovered:<artifactID>:<hash>` before the derivations
/// in every mode, and the file is removed once that Doc is projected: no generation-2 surface reads a
/// held body (§13.3 step 3c, R8-m8). Production holds none today.
enum HeldRemoteBodies {
    /// Every Doc with a held body gets its Recovered Doc, in today's tables. Idempotent: the id is
    /// deterministic.
    static func recover(_ store: KnowledgeStore) throws {
        for artifactID in try store.loadAllArtifactIDs() {
            guard let held = try store.loadArtifactHeldRemoteMarkdown(artifactID), !held.isEmpty else { continue }
            var title = "", notebookID: String?
            try store.query("SELECT title, home_notebook_id FROM global_artifacts WHERE id = ?", [.text(artifactID)]) {
                title = $0.text(0) ?? ""
                notebookID = $0.text(1)
            }
            try RecoveredDoc.keepHeldRemote(held, artifactID: artifactID, title: title, notebookID: notebookID, in: store)
        }
    }

    /// Removes each held body whose Recovered Doc is projected: the derivations laid out its pointer.
    static func removeProjected(_ store: KnowledgeStore) throws {
        for artifactID in try store.loadAllArtifactIDs() {
            guard let held = try store.loadArtifactHeldRemoteMarkdown(artifactID), !held.isEmpty else { continue }
            let recoveredID = RecoveredDoc.id(artifactID: artifactID, hash: SyncIdentity.sha256Hex(Data(held.utf8)))
            guard try store.scalarInteger("SELECT EXISTS(SELECT 1 FROM global_artifacts WHERE id = ? AND body_ref IS NOT NULL)", [.text(recoveredID)]) == 1 else { continue }
            try store.discardArtifactHeldRemoteMarkdown(artifactID)
        }
    }
}

extension KnowledgeStore {
    static let heldBodyRecoveryDerivations = [ActivationDerivation(id: "heldRemoteBodies", run: { try HeldRemoteBodies.recover($0) })]
    static let heldBodyCleanupDerivations = [ActivationDerivation(id: "heldRemoteBodies.remove", run: { try HeldRemoteBodies.removeProjected($0) })]
}

// MARK: - What a store may send, from its journal

extension ActivationJournal {
    /// A `deferred` store whose catch-up has not run yet sends nothing to the new container and takes
    /// no seed claim and no lease (§13.3). WP16b's deferred catch-up sets `catch_up_at`.
    var sendsWaitForCatchUp: Bool { mode == .deferred && catchUpAt == nil }

    /// A `fresh` store whose old `Knowledge` zone was missing, or whose 5% guard was answered "Not this
    /// library", uploads nothing until the learner confirms "This Mac holds my library" (WP16c, §13.5).
    var sendsWaitForConfirmation: Bool { mode == .fresh && freshReason == .knowledgeMissing }
}

// MARK: - The tripped 5% guard's question

/// The question a tripped guard asks (D46, R5-m5, R6-m9), kept in `ck_engine_state` until answered.
/// **Apply** records the answer and the deferred catch-up (WP16b) runs once with the guard lifted, then
/// clears it. **Not this library** applies nothing, keeps the store and records `fresh` with
/// `fresh_reason = knowledgeMissing`.
enum ActivationQuestion {
    static let scope = "activation.guardQuestion"

    struct Stored: Codable, Equatable, Sendable {
        var question: MigrationGuardQuestion
        /// `apply` once the learner chose it; nil while the question waits.
        var answer: String?
    }

    static func load(_ store: KnowledgeStore) throws -> Stored? {
        try store.replica.engineState(scope).flatMap { try? decoder.decode(Stored.self, from: $0) }
    }

    static func ask(_ question: MigrationGuardQuestion, store: KnowledgeStore) throws {
        try save(Stored(question: question, answer: nil), store: store)
    }

    static func answerApply(store: KnowledgeStore) throws {
        guard var stored = try load(store) else { return }
        stored.answer = "apply"
        try save(stored, store: store)
    }

    static func answerNotThisLibrary(store: KnowledgeStore) throws {
        var journal = try store.activationJournal() ?? ActivationJournal()
        journal.mode = .fresh
        journal.freshReason = .knowledgeMissing
        try store.writeActivationJournal(journal)
        try clear(store: store)
    }

    static func clear(store: KnowledgeStore) throws {
        try store.replica.setEngineState(scope, nil)
    }

    private static func save(_ stored: Stored, store: KnowledgeStore) throws {
        try store.replica.setEngineState(scope, try encoder.encode(stored))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

// MARK: - What the window and Settings show

/// The activation's progress, process-wide: the storage actor runs the activation and the window reads
/// it on the main actor, and either may come first (the shape of `LibraryUpgradeSpace`).
final class ActivationStatus: @unchecked Sendable {
    static let shared = ActivationStatus()
    static let didChange = Notification.Name("ForeverLMActivationStatusDidChange")

    enum Phase: Equatable, Sendable {
        case idle
        /// A `full` activation: the library is read-only until it ends. `step` of `total`.
        case moving(step: Int, total: Int, text: String)
        /// A `deferred` or `fresh` activation's quick local steps: nothing is read-only.
        case preparing
        /// The walk would delete more than 5% of the library: waiting for Apply or Not this library.
        case asking(MigrationGuardQuestion)
        case failed(String)
        case done
    }

    static let steps = 5
    private let lock = NSLock()
    private var phase = Phase.idle

    var current: Phase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    /// Whether the library refuses writes for the window's banner.
    var isReadOnly: Bool {
        if case .moving = current { return true }
        return false
    }

    func update(_ new: Phase) {
        lock.lock()
        let changed = phase != new
        phase = new
        lock.unlock()
        guard changed else { return }
        // Posted from the main queue, never from here: the activation runs on the storage actor.
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

/// Starts the things that must wait for `activated_at`: the MCP HTTP server and the relay (§13.3 step 3).
/// Closed from the process's first instant under generation 2 and opened by the launcher once `activated_at`
/// is set (or the activation failed or was cancelled for good), so nothing that starts before the launcher
/// runs can slip through an open gate (F28); open for ever under generation 1.
actor GenerationActivationGate {
    static let shared = GenerationActivationGate(isOpen: ForeverLMRuntimeIdentity.syncGeneration != .two)

    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool = true) {
        self.isOpen = isOpen
    }

    func close() {
        isOpen = false
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
