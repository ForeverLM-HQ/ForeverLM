import Foundation

// MARK: - Home's rail on the phone

// The phone has no sidebar, so Home is the Mac's compact rail
// (docs/notebooks-design.md, "A compact rail" and "iPhone"): Pinned, Recent,
// All notebooks, Uncategorized and Collections, the whole catalog one push
// away on the Notebooks screen. The rules are the Mac's own (`NotebookRail`,
// `NotebookPins`, `NotebooksHomeSort`, NotebooksHomeRules.swift); this file
// gives them the phone's records and rows.

/// A notebook on the phone as the home's shared rules read it: its count of
/// approved sources is the Mac's (`approvedSourceIDs`), so a notebook sorts
/// by Sources where it does on the Mac.
extension MobileCloudNotebook: NotebookHomeListing {
    var homeSourceCount: Int { approvedSourceCount }
}

/// What Home's rail is built from on the phone.
enum MobileNotebookRailRules {
    /// The learner's own notebook order, the Mac's `studio.projectOrder`
    /// (`StudioViewModel.orderedNotebooks`): the ids it lists first, in its
    /// order, then the rest as given. Pinned keeps this order on every
    /// device, so a row dragged on the Mac moves here too.
    static func learnerOrdered(_ notebooks: [MobileCloudNotebook], order: [String]) -> [MobileCloudNotebook] {
        let byID = Dictionary(notebooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set<String>()
        var ordered = order.compactMap { id -> MobileCloudNotebook? in
            guard let notebook = byID[id], included.insert(id).inserted else { return nil }
            return notebook
        }
        ordered.append(contentsOf: notebooks.filter { included.insert($0.id).inserted })
        return ordered
    }

    /// When each notebook was last worked in for Recent and the Recent sort:
    /// opened on this phone, or the end of its latest chat on any device,
    /// whichever is later; the record's own change is read beside them
    /// (`NotebookRecency.lastWorkedAt`).
    static func recency(opened: NotebookRecency, lastChatAt: [String: Date]) -> NotebookRecency {
        var merged = opened
        for (notebookID, date) in lastChatAt.sorted(by: { $0.key < $1.key })
        where date > (merged.stamp(notebookID) ?? .distantPast) {
            merged.note(notebookID, at: date)
        }
        return merged
    }

    /// Home's sections: the active notebooks (`notebooks`) in the learner's
    /// order, the pins, Recent by `recency`, the notebook last opened on
    /// this phone when it is neither pinned nor recent, and the collections.
    static func rail(
        notebooks: [MobileCloudNotebook],
        pinnedIDs: [String],
        order: [String],
        recency: NotebookRecency,
        collections: NotebookCollections,
        lastOpenedID: String?
    ) -> NotebookRail {
        NotebookRail(
            notebooks: learnerOrdered(notebooks, order: order),
            pinned: Set(pinnedIDs),
            recency: recency,
            collections: collections,
            openNotebookID: lastOpenedID.flatMap { id in notebooks.contains { $0.id == id } ? id : nil }
        )
    }
}

// MARK: - The rows behind it

/// The pins and the order Home's rail reads, and the notebooks this phone
/// opened.
///
/// - **Pins**: the Mac's synced row `studio.pinnedNotebooks.v1`
///   (`NotebookPins`), read by key with the learner's order
///   (`studio.projectOrder`, read only) in one batch on every load. A pin or
///   an unpin shows at once, then reads the row again, changes that one id
///   and writes the row when it changed; a failed write puts it back. The
///   phone lists only active notebooks, so it drops no id it cannot see: the
///   Mac prunes ids the library no longer has on its next pin. Nothing here
///   reads or writes the retired `studio.unpinnedProjects`.
/// - **Opened**: when this phone last opened each notebook, in its own
///   defaults (`NotebookRecency.preferenceKey`), never a synced row, as the
///   Mac keeps its stamps.
///
/// Loads and pins run one after another in the order they were asked for,
/// so a load that started before a pin can never publish over it.
@MainActor
final class MobileNotebookRailStore: ObservableObject {
    /// The `[String]` rows under some keys, by key; a key with no row is absent.
    typealias ReadRows = @Sendable ([String]) async throws -> [String: [String]]
    /// Writes a `[String]` row by key.
    typealias WriteRow = @Sendable (String, [String]) async throws -> Void

    static let notebookOrderPreferenceKey = Prefs.Studio.notebookOrder.name

    static let shared = MobileNotebookRailStore()

    /// The pinned notebooks' ids as the row lists them, with what this phone
    /// has written since.
    @Published private(set) var pinnedIDs: [String] = []
    /// The learner's notebook order, as last read.
    @Published private(set) var notebookOrder: [String] = []
    /// When this phone opened each notebook.
    @Published private(set) var opened: NotebookRecency

    private let readRows: ReadRows
    private let writeRow: WriteRow
    private let defaults: UserDefaults?
    private let operations = MobileSerialOperations()

    nonisolated static let cloudReadRows: ReadRows = { keys in
        try await MobileModelPreferenceStore.shared.stringArrays(forKeys: keys)
    }

    nonisolated static let cloudWriteRow: WriteRow = { key, ids in
        try await MobileModelPreferenceStore.shared.setStringArray(ids, forKey: key)
    }

    /// - Parameter defaults: where the opened stamps are kept; nil (a test)
    ///   keeps them in memory.
    init(
        readRows: @escaping ReadRows = MobileNotebookRailStore.cloudReadRows,
        writeRow: @escaping WriteRow = MobileNotebookRailStore.cloudWriteRow,
        defaults: UserDefaults? = .standard
    ) {
        self.readRows = readRows
        self.writeRow = writeRow
        self.defaults = defaults
        opened = NotebookRecency.load(from: defaults)
    }

    func isPinned(_ notebookID: String) -> Bool {
        pinnedIDs.contains(notebookID)
    }

    // MARK: Reading

    /// Reads the pins and the order again. A failed read throws and leaves
    /// what was last read.
    func load() async throws {
        try await serialized {
            let rows = try await self.readRows([NotebookPins.preferenceKey, Self.notebookOrderPreferenceKey])
            self.pinnedIDs = Self.deduplicated(rows[NotebookPins.preferenceKey] ?? [])
            self.notebookOrder = Self.deduplicated(rows[Self.notebookOrderPreferenceKey] ?? [])
        }
    }

    // MARK: Acts

    /// Pins the notebook to Home (last among the pins in the row) or unpins
    /// it.
    func setPinned(_ notebookID: String, _ pinned: Bool) async throws {
        let before = pinnedIDs
        pinnedIDs = Self.setting(notebookID, pinned: pinned, in: pinnedIDs)
        do {
            try await serialized {
                let key = NotebookPins.preferenceKey
                let current = try await self.readRows([key])[key] ?? []
                let next = Self.setting(notebookID, pinned: pinned, in: current)
                if next != current {
                    try await self.writeRow(key, next)
                }
                self.pinnedIDs = next
            }
        } catch {
            pinnedIDs = before
            throw error
        }
    }

    /// Notes that the notebook was opened on this phone now.
    func noteOpened(_ notebookID: String, at date: Date = Date()) {
        var stamps = opened
        stamps.note(notebookID, at: date)
        opened = stamps
        stamps.save(to: defaults)
    }

    /// The Mac's rule over a row this phone holds: every id in it is kept
    /// (the phone cannot tell an archived notebook from a deleted one).
    private static func setting(_ notebookID: String, pinned: Bool, in ids: [String]) -> [String] {
        NotebookPins.setting(notebookID, pinned: pinned, in: ids, knownIDs: Set(ids))
    }

    private static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Runs `operation` after every load and pin asked for before it.
    private func serialized<T: Sendable>(
        _ operation: @escaping @Sendable @MainActor () async throws -> T
    ) async throws -> T {
        try await operations.run(operation)
    }
}

// MARK: - The view model's acts

extension MobileAudioReviewViewModel {
    /// Reads the pins and the notebook order again. A failed read keeps what
    /// was last read: the load's own banner already says when iCloud cannot
    /// be reached.
    func refreshNotebookRail() async {
        try? await MobileNotebookRailStore.shared.load()
    }

    /// Pins the notebook to Home or unpins it, surfacing a failure in the
    /// shell's error bar.
    func setNotebook(_ notebookID: String, pinned: Bool) async {
        do {
            try await MobileNotebookRailStore.shared.setPinned(notebookID, pinned)
        } catch {
            errorMessage = pinned
                ? "The notebook could not be pinned: \(error.localizedDescription)"
                : "The notebook could not be unpinned: \(error.localizedDescription)"
        }
    }
}
