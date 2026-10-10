import Foundation

/// The read-only window of a `full` activation (docs/cloudkit-schema-design.md §13.3 step 3): while the
/// migration catch-up walks and applies, the library stays readable and refuses writes. Every
/// `KnowledgeStore` this process holds on the database (the app opens several on one file) has
/// `PRAGMA query_only` on, except while the activation runs its own steps, which lift it for the span of
/// one step (`allowingWrites`). A lifted store stays writable until its step ends, whatever else holds
/// the database meanwhile: another `StorageService` that opens its store during the step holds the path
/// again (`holdIfActivationMayBeFull`), and that hold reaches every other store but never the step's
/// own. Process-local on purpose: a relaunch after a crash decides again from `ck_activation`, and a gate
/// that outlived the process would refuse writes to a library nothing was moving.
///
/// Every pragma is set under the gate's lock, so a hold and a step's lift never interleave on one
/// connection. A step never waits on the lock while it holds its connection: the lift is taken before
/// the step's first statement and given back after its last.
enum KnowledgeStoreWriteGate {
    private final class Entry {
        weak var store: KnowledgeStore?
        init(_ store: KnowledgeStore) { self.store = store }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: Set<String> = []
    /// Paths whose activation runner has decided in this process (it released them once): a store opened
    /// later is not held again from its open, though the runner itself may hold the path again.
    nonisolated(unsafe) private static var decided: Set<String> = []
    nonisolated(unsafe) private static var registry: [String: [Entry]] = [:]
    /// Stores inside an activation step, by identity, with how many steps are nested on each.
    nonisolated(unsafe) private static var lifted: [ObjectIdentifier: Int] = [:]

    /// Called by every on-disk store once it is open, so one opened during the window is read-only too.
    static func register(_ store: KnowledgeStore) {
        lock.lock()
        defer { lock.unlock() }
        var entries = (registry[store.dbPath] ?? []).filter { $0.store != nil }
        entries.append(Entry(store))
        registry[store.dbPath] = entries
        if held.contains(store.dbPath) { setQueryOnly(true, on: store) }
    }

    static func isHeld(databaseAt path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains(path)
    }

    /// Makes every store on the database refuse writes until `release`, except a store inside an
    /// activation step, which refuses them once its step ends.
    static func hold(databaseAt path: String) {
        lock.lock()
        defer { lock.unlock() }
        held.insert(path)
        for store in stores(at: path) where lifted[ObjectIdentifier(store)] == nil {
            setQueryOnly(true, on: store)
        }
    }

    /// The hold a store's open takes while its activation may run `full` (§13.3): none once this process's
    /// runner has decided the path, so a store opened after a failed or a finished activation is writable.
    static func holdAtOpen(databaseAt path: String) {
        lock.lock()
        let isDecided = decided.contains(path)
        lock.unlock()
        guard !isDecided else { return }
        hold(databaseAt: path)
    }

    static func release(databaseAt path: String) {
        lock.lock()
        defer { lock.unlock() }
        held.remove(path)
        decided.insert(path)
        for store in stores(at: path) { setQueryOnly(false, on: store) }
    }

    /// Runs `body` with writes allowed on `store`, and the gate back on after it when it is still held.
    /// The activation's own steps run on the storage actor, so nothing else writes on this store meanwhile;
    /// a hold taken during the step (a second store's open) leaves this store alone until the step ends.
    static func allowingWrites<T>(on store: KnowledgeStore, _ body: () throws -> T) rethrows -> T {
        let id = ObjectIdentifier(store)
        lock.lock()
        lifted[id, default: 0] += 1
        if held.contains(store.dbPath) { setQueryOnly(false, on: store) }
        lock.unlock()
        defer {
            lock.lock()
            let remaining = (lifted[id] ?? 1) - 1
            lifted[id] = remaining > 0 ? remaining : nil
            if remaining <= 0, held.contains(store.dbPath) { setQueryOnly(true, on: store) }
            lock.unlock()
        }
        return try body()
    }

    /// The live stores registered on `path`. Called under `lock`.
    private static func stores(at path: String) -> [KnowledgeStore] {
        (registry[path] ?? []).compactMap(\.store)
    }

    private static func setQueryOnly(_ on: Bool, on store: KnowledgeStore) {
        try? store.exec("PRAGMA query_only = \(on ? "ON" : "OFF")")
    }
}
