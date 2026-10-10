import Foundation
import OSLog

// MARK: - A notebook's context for this member, under generation 2 (docs/cloudkit-schema-design.md §5.6, D52)

/// What the Mac's notebook surfaces read under generation 2, per notebook id: the sources the member
/// unticked that are still unticked (an untick holds only while the stamps of the Entry it named are
/// unchanged, D16), the context notebooks they ticked (D52), and their Notebook Collections. Generation
/// 1 reads the same three from its preference rows (`NotebookChatSelection`, `NotebookCollectionRows`).
struct NotebookStateSnapshot: Equatable, Sendable {
    var excluded: [String: Set<String>] = [:]
    var contextNotebooks: [String: Set<String>] = [:]
    var collections: [String: Set<String>] = [:]
}

extension KnowledgeStore {
    /// One notebook's context: the Entries of the notebook and of its ticked, listed context notebooks
    /// (`ctx(nb, m)`, both lists resolved before they are intersected), as the chat-tick rule reads them.
    struct NotebookContextEntries {
        let notebookID: String
        let contextNotebookIDs: [String]
        /// Source id → container id → whether that container holds it in context.
        let holders: [String: [String]]
    }

    func notebookContextEntries(_ notebookID: String, row: NotebookStateRow?) throws -> NotebookContextEntries {
        var resolution: [String: String] = [:]
        try query("SELECT id, resolved_id FROM notebook_resolution", []) { row in
            if let id = row.text(0), let resolved = row.text(1) { resolution[id] = resolved }
        }
        let home = resolution[notebookID] ?? notebookID
        var related: [String: SyncJSON] = [:]
        try query("SELECT related_notebook_id FROM notebook_related_notebook_links WHERE notebook_id = ?", [.text(home)]) { row in
            if let id = row.text(0) { related[id] = .bool(true) }
        }
        let ticked = Dictionary((row?.contextNotebooks ?? []).map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })
        let context = SyncNotebookChatContext.contextNotebookIDs(
            notebookID: home, contextNotebooks: ticked, relatedNotebookIDs: related
        ) { resolution[$0] ?? $0 }
        var holders: [String: [String]] = [:]
        for container in [home] + context {
            try query("""
                SELECT source_id FROM learning_goal_items
                WHERE goal_id = ? AND (review_state IS NULL OR review_state = 'approved')
            """, [.text(container)]) { row in
                if let source = row.text(0) { holders[source, default: []].append(container) }
            }
        }
        return NotebookContextEntries(notebookID: home, contextNotebookIDs: context, holders: holders)
    }

    /// `e_s` (§5.6): the Entry an untick of `sourceID` names: the source's own Entry in the notebook,
    /// else its Entry in the context notebook with the smallest id.
    func comparedEntryID(for sourceID: String, in context: NotebookContextEntries) -> String? {
        guard let containers = context.holders[sourceID], !containers.isEmpty else { return nil }
        let container = containers.contains(context.notebookID) ? context.notebookID : containers.min()!
        return SyncIdentity.entryID(containerID: container, itemKind: "source", itemID: sourceID)
    }

    /// The stamp pair an untick stores for `entryID`: its `state` and `approval` stamps as this device
    /// holds them, an unsent change's included. `mint` mints and pins an unsent change's stamp at once
    /// (an untick); nil when the state stamp cannot be named (an unsent change and no clock, or a read
    /// that may not mint).
    func entryStampPair(_ entryID: String, mint: Bool) throws -> String? {
        let paths = [StampedPath("state"), StampedPath("approval")]
        let stamps = try OutboxFeeder(connection: self, registry: Self.projectionRegistry)
            .heldStamps(type: .entry, wireID: entryID, paths: paths, mint: mint)
        guard let state = stamps[paths[0]] else { return nil }
        return state.rawValue + "|" + (stamps[paths[1]]?.rawValue ?? "-")
    }

    /// The member's state for every notebook, the unticks resolved against the Entries' stamps.
    func notebookStateSnapshot() throws -> NotebookStateSnapshot {
        var rows: [NotebookStateRow] = []
        var ids: [String] = []
        try query("SELECT notebook_id FROM notebook_states", []) { row in if let id = row.text(0) { ids.append(id) } }
        for id in ids { if let row = try NotebookStateRow.load(id, connection: self) { rows.append(row) } }
        var snapshot = NotebookStateSnapshot()
        for row in rows {
            if !row.contextNotebooks.isEmpty { snapshot.contextNotebooks[row.notebookID] = row.contextNotebooks }
            if !row.collections.isEmpty { snapshot.collections[row.notebookID] = row.collections }
            guard !row.excluded.isEmpty else { continue }
            let unticked = try effectiveExclusions(row, context: try notebookContextEntries(row.notebookID, row: row))
            if !unticked.isEmpty { snapshot.excluded[row.notebookID] = unticked }
        }
        return snapshot
    }

    /// The sources a row's unticks still leave out: those whose pair names the stamps the compared
    /// Entry holds now, and those still waiting for a stamp.
    func effectiveExclusions(_ row: NotebookStateRow, context: NotebookContextEntries) throws -> Set<String> {
        var unticked: Set<String> = []
        for (source, pair) in row.excluded {
            if pair == NotebookStateRow.pendingPair { unticked.insert(source); continue }
            guard let entry = comparedEntryID(for: source, in: context) else { continue }
            if try entryStampPair(entry, mint: false) == pair { unticked.insert(source) }
        }
        return unticked
    }

    /// Makes `excluded` the sources the notebook's chats leave out (§5.6): a newly unticked source
    /// stores the stamp pair of the Entry it is compared with, minted now for an unsent change; a source
    /// ticked again loses its pair; every other element stays as it is, so a source a re-add or a
    /// re-approval ticked again is ticked with no write here. A source in no Entry of the notebook's
    /// context is not stored. Generation 2 only.
    func setNotebookChatExclusions(notebookID: String, excluded: Set<String>) throws {
        guard syncGeneration == .two else { return }
        try inNotebookStateTransaction(notebookID) { row in
            let context = try self.notebookContextEntries(notebookID, row: row)
            let held = try self.effectiveExclusions(row, context: context)
            for source in held.subtracting(excluded) { row.excluded[source] = nil }
            for source in excluded.subtracting(held).sorted() {
                guard let entry = self.comparedEntryID(for: source, in: context) else { continue }
                row.excluded[source] = try self.entryStampPair(entry, mint: true) ?? NotebookStateRow.pendingPair
            }
        }
    }

    /// The context notebooks the member ticked into this notebook's chats (D52). Generation 2 only.
    func setNotebookContextNotebooks(notebookID: String, contextNotebookIDs: Set<String>) throws {
        guard syncGeneration == .two else { return }
        try inNotebookStateTransaction(notebookID) { $0.contextNotebooks = contextNotebookIDs }
    }

    /// The Notebook Collections this notebook is in, for this member. Generation 2 only.
    func setNotebookCollections(notebookID: String, collectionIDs: Set<String>) throws {
        guard syncGeneration == .two else { return }
        try inNotebookStateTransaction(notebookID) { $0.collections = collectionIDs }
    }

    /// Gives every untick still waiting for its Entry's stamp its pair, once the stamp can be named
    /// (the device has its server offset). Generation 2 only.
    func resolvePendingUnticks() throws {
        guard syncGeneration == .two else { return }
        var ids: [String] = []
        try query("SELECT notebook_id FROM notebook_states WHERE excluded_json LIKE ?", [.text("%\(NotebookStateRow.pendingPair)%")]) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        for id in ids {
            try inNotebookStateTransaction(id) { row in
                let context = try self.notebookContextEntries(id, row: row)
                for (source, pair) in row.excluded where pair == NotebookStateRow.pendingPair {
                    guard let entry = self.comparedEntryID(for: source, in: context) else { row.excluded[source] = nil; continue }
                    if let resolved = try self.entryStampPair(entry, mint: true) { row.excluded[source] = resolved }
                }
            }
        }
    }

    /// Reads, changes and saves one notebook's row in one transaction; a row is made only by a change
    /// (opening a notebook writes nothing, P9).
    private func inNotebookStateTransaction(_ notebookID: String, _ change: (inout NotebookStateRow) throws -> Void) throws {
        try inDerivationTransaction { store in
            let held = try NotebookStateRow.load(notebookID, connection: store)
            var row = held ?? NotebookStateRow(notebookID: notebookID)
            try change(&row)
            guard row != held, held != nil || row != NotebookStateRow(notebookID: notebookID) else { return }
            try row.save(store)
        }
    }
}

// MARK: - The Mac's surfaces read it in memory

/// The generation-2 snapshot the Mac's notebook surfaces read synchronously, as generation 1 reads its
/// preference rows from `UserDefaults`: `NotebookChatSelection` and `NotebookCollectionRows` read and
/// write here under generation 2 only. A write lands in memory at once and in `notebook_states` off the
/// main actor, in call order; the snapshot is then reloaded (an untick's pair resolved against the
/// Entries) and the surfaces are told, as for a preference that changed remotely. A test binds its own
/// snapshot (`override`), and while bound nothing reaches the store.
enum NotebookStateStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot = NotebookStateSnapshot()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var tail: Task<Void, Never>?
    private static let storage = StorageService()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "NotebookStateStore")

    /// A test's own snapshot, bound for the task that runs it.
    @TaskLocal static var override: Box? = nil

    final class Box: @unchecked Sendable {
        var snapshot: NotebookStateSnapshot
        init(_ snapshot: NotebookStateSnapshot = NotebookStateSnapshot()) { self.snapshot = snapshot }
    }

    /// Whether the surfaces read this store: generation 2, or a test that bound one.
    static var isActive: Bool { override != nil || ForeverLMRuntimeIdentity.syncGeneration == .two }

    static func current() -> NotebookStateSnapshot {
        if let override { return override.snapshot }
        lock.lock()
        let value = snapshot
        let needsLoad = !loaded
        loaded = true
        lock.unlock()
        if needsLoad { enqueue { _ in } }
        return value
    }

    static func setExcluded(_ ids: Set<String>, notebookID: String) {
        update { $0.excluded[notebookID] = ids.isEmpty ? nil : ids }
        enqueue { try $0.setNotebookChatExclusions(notebookID: notebookID, excluded: ids) }
    }

    static func setContextNotebooks(_ ids: Set<String>, notebookID: String) {
        update { $0.contextNotebooks[notebookID] = ids.isEmpty ? nil : ids }
        enqueue { try $0.setNotebookContextNotebooks(notebookID: notebookID, contextNotebookIDs: ids) }
    }

    static func setCollections(_ ids: Set<String>, notebookID: String) {
        update { $0.collections[notebookID] = ids.isEmpty ? nil : ids }
        enqueue { try $0.setNotebookCollections(notebookID: notebookID, collectionIDs: ids) }
    }

    /// Reloads after an inbound change to a NotebookState or an Entry (WP16 calls it after an apply).
    static func reload() { enqueue { _ in } }

    private static func update(_ change: (inout NotebookStateSnapshot) -> Void) {
        if let override { change(&override.snapshot); return }
        lock.lock()
        change(&snapshot)
        lock.unlock()
    }

    /// Takes a snapshot read back from the store; whether it differs from the one held.
    private static func replace(with fresh: NotebookStateSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = fresh != snapshot
        snapshot = fresh
        return changed
    }

    /// Runs `write`, then reloads the snapshot, after every write enqueued before it.
    private static func enqueue(_ write: @escaping @Sendable (KnowledgeStore) throws -> Void) {
        guard override == nil else { return }
        lock.lock()
        let predecessor = tail
        let next = Task.detached(priority: .utility) {
            await predecessor?.value
            do {
                let fresh = try await storage.writingNotebookState(write)
                if replace(with: fresh) {
                    await MainActor.run {
                        NotificationCenter.default.post(name: PreferenceStore.didChangeRemotely, object: nil, userInfo: [PreferenceStore.changedKeysKey: Set<String>()])
                    }
                }
            } catch {
                logger.error("Could not keep the notebook state: \(error.localizedDescription, privacy: .public)")
            }
        }
        tail = next
        lock.unlock()
    }
}

extension StorageService {
    /// Runs a notebook-state write, then reads the member's state back, on the storage actor.
    func writingNotebookState(_ write: (KnowledgeStore) throws -> Void) throws -> NotebookStateSnapshot {
        var fresh = NotebookStateSnapshot()
        try performSync { store in
            try write(store)
            fresh = try store.notebookStateSnapshot()
        }
        return fresh
    }
}
