import Foundation
import OSLog

// MARK: - Collections of notebooks on the phone

/// The learner's collections of notebooks on the iPhone and iPad
/// (`NotebookCollections`, docs/notebooks-design.md "Collections"): the
/// Mac's two kinds of synced Preference row, read and written by key through
/// the phone's preference store.
///
/// The phone holds no Preference row it did not ask for by key, so it finds
/// the collections through the notebooks it knows: one batched read of every
/// notebook's `notebook.collections.<notebookID>` row, then one of the
/// `notebookCollection.<id>` name rows those rows name. A collection this
/// phone has already seen since launch has its name row read too, so one
/// made or emptied here stays on screen until its name row goes; any other
/// collection no notebook here is in is not shown.
///
/// Every act reads again the rows it changes and writes only a change, so a
/// notebook put in a collection on another device since the last load keeps
/// it, and an id with no name row yet (a collection made elsewhere whose name
/// has not arrived) is never pruned. Loads and acts run one after another in
/// the order they were asked for, so a load that started before an act can
/// never publish over it.
@MainActor
final class MobileNotebookCollectionsStore: ObservableObject {
    /// The String rows under some keys, by key; a key with no row is absent.
    typealias ReadNames = @Sendable ([String]) async throws -> [String: String]
    /// The `[String]` rows under some keys, by key; a key with no row is absent.
    typealias ReadMemberships = @Sendable ([String]) async throws -> [String: [String]]
    /// Writes a name row by key; nil removes it.
    typealias WriteName = @Sendable (String, String?) async throws -> Void
    /// Writes a notebook's row by key; an empty value removes it.
    typealias WriteMembership = @Sendable (String, [String]) async throws -> Void

    enum Failure: LocalizedError, Equatable {
        case emptyName
        case deletedElsewhere

        var errorDescription: String? {
            switch self {
            case .emptyName: return "A collection needs a name."
            case .deletedElsewhere: return "It was deleted on another device."
            }
        }
    }

    static let shared = MobileNotebookCollectionsStore()

    /// The collections and the rows of the notebooks last read, with what
    /// this phone has written since.
    @Published private(set) var state = NotebookCollections()

    private let readNames: ReadNames
    private let readMemberships: ReadMemberships
    private let writeName: WriteName
    private let writeMembership: WriteMembership
    /// The notebooks whose rows this phone holds: the ones the last load
    /// read, and any it has written since.
    private var heldNotebookIDs: Set<String> = []
    /// Every collection this phone has seen with a name since launch.
    private var seenCollectionIDs: Set<String> = []
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "NotebookCollections")
    private let operations = MobileSerialOperations()

    // A notebook's row (§3.5.3, §3.5.20) is its NotebookState's `collections`, and a
    // collection's name the account Setting `notebookCollection.<id>`, which the catalog lists under
    // `leftOut` (R7-m2); both read from the replica and written through the phone's writer. The phone
    // runs no merge or split hand-over: a Mac does (§5.2).

    nonisolated static let cloudReadNames: ReadNames = { keys in
        return try await MobileNotebookRows.strings(keys, writer: MobileRecordWriter.required())
    }

    nonisolated static let cloudReadMemberships: ReadMemberships = { keys in
        return try await MobileNotebookRows.stringArrays(keys, writer: MobileRecordWriter.required())
    }

    nonisolated static let cloudWriteName: WriteName = { key, name in
        try await MobileNotebookRows.write(key, string: name, writer: MobileRecordWriter.required())
    }

    nonisolated static let cloudWriteMembership: WriteMembership = { key, ids in
        try await MobileNotebookRows.write(key, ids: ids, writer: MobileRecordWriter.required())
    }

    init(
        readNames: @escaping ReadNames = MobileNotebookCollectionsStore.cloudReadNames,
        readMemberships: @escaping ReadMemberships = MobileNotebookCollectionsStore.cloudReadMemberships,
        writeName: @escaping WriteName = MobileNotebookCollectionsStore.cloudWriteName,
        writeMembership: @escaping WriteMembership = MobileNotebookCollectionsStore.cloudWriteMembership
    ) {
        self.readNames = readNames
        self.readMemberships = readMemberships
        self.writeName = writeName
        self.writeMembership = writeMembership
    }

    // MARK: Reading

    /// Reads the collections again through `notebookIDs`, the notebooks on
    /// the phone's Home. A failed read throws and leaves what was last read.
    func load(notebookIDs: [String]) async throws {
        try await serialized { try await self.performLoad(notebookIDs: notebookIDs) }
    }

    private func performLoad(notebookIDs: [String]) async throws {
        let memberships = try await readMemberships(notebookIDs.map(NotebookCollections.membershipKey(notebookID:)))
        let listed = Set(memberships.values.joined()).union(seenCollectionIDs)
        let names = try await readNames(listed.sorted().map(NotebookCollections.nameKey(collectionID:)))
        var rows: [String: Any] = [:]
        for (key, ids) in memberships { rows[key] = ids }
        for (key, name) in names { rows[key] = name }
        let loaded = NotebookCollections(rows: rows)
        heldNotebookIDs = Set(notebookIDs)
        // A seen collection whose name row has gone was deleted somewhere.
        seenCollectionIDs = Set(loaded.ordered.map(\.id))
        state = loaded
    }

    // MARK: Acts

    /// Puts the notebook in the collection (`isMember`) or takes it out. The
    /// notebook moves on screen at once; its row is then read again, changed
    /// in that one id and written when it changed. A failed write throws and
    /// puts that id back as it was.
    func setMembership(notebookID: String, collectionID: String, isMember: Bool) async throws {
        let wasMember = state.memberships[notebookID]?.contains(collectionID) == true
        state = state.settingMembership(
            state.membershipRow(notebookID: notebookID, setting: collectionID, isMember: isMember),
            for: notebookID
        )
        do {
            try await serialized {
                try await self.commitMembership(notebookID: notebookID, collectionID: collectionID, isMember: isMember)
            }
        } catch {
            state = state.settingMembership(
                state.membershipRow(notebookID: notebookID, setting: collectionID, isMember: wasMember),
                for: notebookID
            )
            throw error
        }
    }

    /// Makes a collection named `name` (folded, trimmed and cut as every
    /// device keeps a name): its name row first, then each notebook's row
    /// with the new id added. An empty name is refused before anything is
    /// written.
    @discardableResult
    func create(name: String, notebookIDs: [String] = []) async throws -> NotebookCollection {
        guard let cleaned = NotebookCollections.cleanedName(name) else { throw Failure.emptyName }
        return try await serialized {
            let id = NotebookCollections.newCollectionID()
            try await self.writeName(NotebookCollections.nameKey(collectionID: id), cleaned)
            self.seenCollectionIDs.insert(id)
            self.state = self.state.settingName(cleaned, for: id)
            for notebookID in notebookIDs {
                try await self.commitMembership(notebookID: notebookID, collectionID: id, isMember: true)
            }
            return NotebookCollection(id: id, name: cleaned)
        }
    }

    /// Rewrites the collection's name row; the same name writes nothing. The
    /// row is read first, so a collection deleted on another device since
    /// the last load is not brought back by a new name: it leaves the phone
    /// instead.
    func rename(collectionID: String, to name: String) async throws {
        guard let cleaned = NotebookCollections.cleanedName(name) else { throw Failure.emptyName }
        try await serialized {
            let key = NotebookCollections.nameKey(collectionID: collectionID)
            guard let current = try await self.readNames([key])[key] else {
                self.seenCollectionIDs.remove(collectionID)
                self.state = self.state.settingName(nil, for: collectionID)
                throw Failure.deletedElsewhere
            }
            if current != cleaned {
                try await self.writeName(key, cleaned)
            }
            self.state = self.state.settingName(cleaned, for: collectionID)
        }
    }

    /// Deletes the collection: its name row goes, then every notebook row
    /// this phone holds that lists it is read again and written without it
    /// (removed when nothing is left). The notebooks are untouched.
    func delete(collectionID: String) async throws {
        try await serialized {
            try await self.writeName(NotebookCollections.nameKey(collectionID: collectionID), nil)
            self.seenCollectionIDs.remove(collectionID)
            self.state = self.state.settingName(nil, for: collectionID)
            let held = self.heldNotebookIDs.union(self.state.memberships.keys).sorted()
            let fresh = try await self.readMemberships(held.map(NotebookCollections.membershipKey(notebookID:)))
            let rows = NotebookCollections(rows: fresh.mapValues { $0 as Any })
                .membershipRowsAfterDeleting(collectionID)
            for (notebookID, ids) in rows.sorted(by: { $0.key < $1.key }) {
                try await self.writeMembership(NotebookCollections.membershipKey(notebookID: notebookID), ids)
                self.state = self.state.settingMembership(ids, for: notebookID)
            }
        }
    }

    /// One notebook's row read again, changed in that one id, written when
    /// it changed, and published as written.
    private func commitMembership(notebookID: String, collectionID: String, isMember: Bool) async throws {
        let key = NotebookCollections.membershipKey(notebookID: notebookID)
        let current = try await readMemberships([key])[key] ?? []
        let next = NotebookCollections(rows: [key: current])
            .membershipRow(notebookID: notebookID, setting: collectionID, isMember: isMember)
        if next != current.sorted() {
            try await writeMembership(key, next)
        }
        heldNotebookIDs.insert(notebookID)
        state = state.settingMembership(next, for: notebookID)
    }

    /// Runs `operation` after every load and act asked for before it.
    private func serialized<T: Sendable>(
        _ operation: @escaping @Sendable @MainActor () async throws -> T
    ) async throws -> T {
        try await operations.run(operation)
    }
}

// MARK: - The view model's acts

/// Home's collection acts, each surfacing a failure in the shell's error bar
/// as the view model's other iCloud writes do.
extension MobileAudioReviewViewModel {
    /// Reads the collections again through the notebooks now on Home. A
    /// failed read keeps the collections last read: the load's own banner
    /// already says when iCloud cannot be reached.
    func refreshNotebookCollections() async {
        try? await MobileNotebookCollectionsStore.shared.load(notebookIDs: notebooks.map(\.id))
    }

    func setNotebook(_ notebookID: String, inCollection collectionID: String, isMember: Bool) async {
        do {
            try await MobileNotebookCollectionsStore.shared.setMembership(
                notebookID: notebookID,
                collectionID: collectionID,
                isMember: isMember
            )
        } catch {
            errorMessage = "The notebook's collections could not be saved: \(error.localizedDescription)"
        }
    }

    /// Makes a collection, with `notebookID`'s notebook in it when one is
    /// given; nil when it could not be made.
    @discardableResult
    func createNotebookCollection(named name: String, withNotebook notebookID: String? = nil) async -> NotebookCollection? {
        do {
            return try await MobileNotebookCollectionsStore.shared.create(
                name: name,
                notebookIDs: notebookID.map { [$0] } ?? []
            )
        } catch {
            errorMessage = "The collection could not be made: \(error.localizedDescription)"
            return nil
        }
    }

    func renameNotebookCollection(_ collectionID: String, to name: String) async {
        do {
            try await MobileNotebookCollectionsStore.shared.rename(collectionID: collectionID, to: name)
        } catch {
            errorMessage = "The collection could not be renamed: \(error.localizedDescription)"
        }
    }

    func deleteNotebookCollection(_ collectionID: String) async {
        do {
            try await MobileNotebookCollectionsStore.shared.delete(collectionID: collectionID)
        } catch {
            errorMessage = "The collection could not be deleted: \(error.localizedDescription)"
        }
    }
}

/// Runs operations one after another, in the order they were asked for.
@MainActor
final class MobileSerialOperations {
    private var chain: Task<Void, Never>?

    /// Runs `operation` after every operation asked for before it, whether that one finished or threw.
    func run<T: Sendable>(_ operation: @escaping @Sendable @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        chain = Task { _ = await task.result }
        return try await task.value
    }
}
