import Foundation
import OSLog

// MARK: - The rail's order, pins and folds under generation 2 (docs/cloudkit-schema-design.md §3.5.20, §10)

/// The member's notebook rail as their NotebookStates hold it: the notebooks in `sidebarKey` order (those
/// with a key), the pinned ones and the expanded ones. Generation 1 keeps the three as the preference rows
/// `studio.projectOrder`, `studio.pinnedNotebooks.v1` and `studio.navigation.expandedProjectIDs.v1`.
struct NotebookSidebarState: Equatable, Sendable {
    var order: [String] = []
    var pinned: [String] = []
    var expanded: [String] = []
}

extension KnowledgeStore {
    func notebookSidebarState() throws -> NotebookSidebarState {
        var keyed: [(id: String, key: String)] = []
        var state = NotebookSidebarState()
        try query("SELECT notebook_id, sidebar_key, pinned, expanded FROM notebook_states ORDER BY notebook_id", []) { row in
            guard let id = row.text(0) else { return }
            if let key = row.text(1) { keyed.append((id, key)) }
            if row.integer(2) == 1 { state.pinned.append(id) }
            if row.integer(3) == 1 { state.expanded.append(id) }
        }
        state.order = keyed.sorted { $0.key == $1.key ? $0.id < $1.id : $0.key < $1.key }.map(\.id)
        let rank = Dictionary(state.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        state.pinned.sort { (rank[$0] ?? .max, $0) < (rank[$1] ?? .max, $1) }
        return state
    }

    /// Gives the notebooks of `order` sidebar keys in that order, moving the fewest keys
    /// (`OrderKeyPlanner`), so a drag of one notebook sends one NotebookState. A notebook the list does
    /// not name keeps its key. Generation 2 only.
    func setNotebookSidebarOrder(_ order: [String]) throws {
        try inDerivationTransaction { store in
            var rows: [String: NotebookStateRow] = [:]
            for id in order where rows[id] == nil {
                rows[id] = try NotebookStateRow.load(id, connection: store) ?? NotebookStateRow(notebookID: id)
            }
            var seen = Set<String>()
            let unique = order.filter { seen.insert($0).inserted }
            for (id, key) in OrderKeyPlanner.plan(unique.map { ($0, rows[$0]?.sidebarKey) }) {
                guard var row = rows[id] else { continue }
                row.sidebarKey = key
                try row.save(store)
            }
        }
    }

    /// Pins exactly `pinned`: a notebook it names is `pinned`, one pinned before and not named is not.
    /// Only rows that change are written. Generation 2 only.
    func setNotebookPinned(_ pinned: Set<String>) throws {
        try setNotebookFlag("pinned", members: pinned) { $0.pinned = $1 }
    }

    /// Folds open exactly `expanded` in the rail. Generation 2 only.
    func setNotebookExpanded(_ expanded: Set<String>) throws {
        try setNotebookFlag("expanded", members: expanded) { $0.expanded = $1 }
    }

    private func setNotebookFlag(_ column: String, members: Set<String>, _ set: @escaping (inout NotebookStateRow, Bool) -> Void) throws {
        try inDerivationTransaction { store in
            var held: Set<String> = []
            try store.query("SELECT notebook_id FROM notebook_states WHERE \(column) = 1", []) { row in
                if let id = row.text(0) { held.insert(id) }
            }
            for id in held.symmetricDifference(members).sorted() {
                var row = try NotebookStateRow.load(id, connection: store) ?? NotebookStateRow(notebookID: id)
                set(&row, members.contains(id))
                try row.save(store)
            }
        }
    }
}

/// Generation 2's keeper of the rail's order, pins and folds. The view model and the rail keep reading
/// and writing their three `UserDefaults` keys, which stay this Mac's under generation 2
/// (`SyncedPreferenceKeys.generation2MovedKeys`); each change is written to the member's NotebookStates
/// off the main actor and in call order, and `reload()` takes the NotebookStates back into those keys
/// after an inbound NotebookState (WP16 calls it after an apply), posting the change as a preference
/// that changed remotely, which the view model and the rail already reseed from.
enum NotebookSidebarSync {
    static let orderKey = "studio.projectOrder"
    static let expandedKey = "studio.navigation.expandedProjectIDs.v1"

    private static let storage = StorageService()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tail: Task<Void, Never>?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "NotebookSidebarSync")

    static func setOrder(_ order: [String]) {
        enqueue { try $0.setNotebookSidebarOrder(order) }
    }

    static func setPinned(_ ids: [String]) {
        let pinned = Set(ids)
        enqueue { try $0.setNotebookPinned(pinned) }
    }

    static func setExpanded(_ ids: Set<String>) {
        enqueue { try $0.setNotebookExpanded(ids) }
    }

    static func reload() {
        enqueue { store in
            let state = try store.notebookSidebarState()
            let defaults = UserDefaults.standard
            var changed: Set<String> = []
            for (key, value) in [(orderKey, state.order), (NotebookPins.preferenceKey, state.pinned), (expandedKey, state.expanded.sorted())] {
                guard (defaults.stringArray(forKey: key) ?? []) != value else { continue }
                if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
                changed.insert(key)
            }
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PreferenceStore.didChangeRemotely, object: nil, userInfo: [PreferenceStore.changedKeysKey: changed])
            }
        }
    }

    private static func enqueue(_ work: @escaping @Sendable (KnowledgeStore) throws -> Void) {
        lock.lock()
        let predecessor = tail
        tail = Task.detached(priority: .utility) {
            await predecessor?.value
            do {
                try await storage.performSync(work)
            } catch {
                logger.error("Could not keep the notebook rail: \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.unlock()
    }
}
