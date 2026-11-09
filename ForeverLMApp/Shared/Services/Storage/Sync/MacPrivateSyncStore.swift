import Foundation

/// The Mac's local half of the private engine (docs/cloudkit-schema-design.md §6.6, D32):
/// `KnowledgeStore`'s connection, its outbox feeder and its projections. Every body runs where the
/// store belongs, through `runner` (the storage actor in the app; the caller, under a lock, in tests),
/// so an apply's transaction never spans an await and no other write lands inside it.
final class MacPrivateSyncStore: PrivateSyncLocalStore, @unchecked Sendable {
    /// Runs one synchronous body on the store, where it belongs.
    typealias Runner = (_ body: @escaping (KnowledgeStore) throws -> Void) async throws -> Void

    let registry: ProjectionRegistry
    private let runner: Runner

    init(registry: ProjectionRegistry = KnowledgeStore.projectionRegistry, runner: @escaping Runner) {
        self.registry = registry
        self.runner = runner
    }

    /// A store the caller owns outright (tests, the Development spike): bodies run on the calling
    /// task, one at a time.
    static func direct(_ store: KnowledgeStore, registry: ProjectionRegistry = KnowledgeStore.projectionRegistry) -> MacPrivateSyncStore {
        let lock = NSRecursiveLock()
        return MacPrivateSyncStore(registry: registry) { body in
            try lock.withLock { try body(store) }
        }
    }

    /// The app's: every body runs on the storage actor, which owns the store.
    static func onStorage(_ storage: StorageService, registry: ProjectionRegistry = KnowledgeStore.projectionRegistry) -> MacPrivateSyncStore {
        MacPrivateSyncStore(registry: registry) { body in
            try await storage.performSync(body)
        }
    }

    func perform<T>(_ body: @escaping (PrivateSyncLocalState) throws -> T) async throws -> T {
        var result: Result<T, Error>?
        let registry = registry
        try await runner { store in
            result = Result { try body(State(store: store, registry: registry)) }
        }
        guard let result else { throw CloudError(.internalError, message: "the store ran nothing") }
        return try result.get()
    }

    /// Runs `body` on the store itself, where it belongs: the Doc body publisher's and materializer's
    /// reads and writes (WP11), which need its files as well as its connection.
    func onStore<T>(_ body: @escaping (KnowledgeStore) throws -> T) async throws -> T {
        var result: Result<T, Error>?
        try await runner { store in
            result = Result { try body(store) }
        }
        guard let result else { throw CloudError(.internalError, message: "the store ran nothing") }
        return try result.get()
    }

    /// One body's view of the store.
    final class State: PrivateSyncLocalState {
        let store: KnowledgeStore
        let registry: ProjectionRegistry
        private lazy var feeder = OutboxFeeder(connection: store, registry: registry)

        init(store: KnowledgeStore, registry: ProjectionRegistry) {
            self.store = store
            self.registry = registry
        }

        var connection: SQLiteConnection { store }

        func nextChanges(now: Date, limit: Int, scope: OutboxScope) throws -> [OutboxChange] {
            let changes = try feeder.nextBatch(now: now, limit: limit, scope: scope)
            return try MacPatchOutbox(connection: store).changes(now: now, limit: limit, scope: scope, alongside: changes)
        }

        func pendingChanges(now: Date) throws -> [OutboxChange] {
            try feeder.pendingChanges(now: now)
        }

        func acknowledgeSave(_ change: OutboxChange, serverRecord: ReplicaRecord) throws {
            try feeder.acknowledgeSave(change, serverRecord: serverRecord)
            try MacPatchOutbox.settle(change, in: store)
        }

        func acknowledgeDelete(_ change: OutboxChange, now: Date) throws {
            try feeder.acknowledgeDelete(change, now: now)
        }

        func release(_ change: OutboxChange) throws {
            try feeder.release(change)
        }

        func discard(_ change: OutboxChange) throws {
            try feeder.discard(change)
        }

        func project(_ record: ReplicaRecord) throws {
            try ProjectionApply(store: store, registry: registry).project(record)
        }

        /// A version the rows hold already is projected again but not announced (`AppliedRemoteChanges`).
        func project(_ record: ReplicaRecord, serverVersionIsNew: Bool) throws {
            try ProjectionApply(store: store, registry: registry).project(record, announces: serverVersionIsNew)
        }

        func projectDeletion(zoneKey: String, recordName: String, type: SyncRecordType, wireID: String) throws {
            try ProjectionApply(store: store, registry: registry).projectDeletion(zoneKey: zoneKey, recordName: recordName, type: type, wireID: wireID)
        }

        /// Also moves on what still names a merged notebook's stub (`keepNotebookStubs`, §5.2), outside
        /// the apply so what it writes goes out, and tells the learner of a fold that lost.
        func drainReady() throws {
            try store.drainReadyProjections(registry)
            try store.inDerivationTransaction { try SpaceRows.recordMissingIdentities(connection: $0) }
            let notices = try store.keepNotebookStubs()
            if !notices.isEmpty {
                let message = notices.joined(separator: " ")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NotebookFoldNotices.didArrive, object: nil, userInfo: [NotebookFoldNotices.messageKey: message])
                }
            }
        }

        func recordLocalWrite(_ patch: RecordPatch) throws {
            try store.recordLocalWrite(patch, registry: registry)
        }

        func unprojectableTypes() -> Set<SyncRecordType> {
            Set(SyncRecordType.allCases.filter { registry.projection(for: $0) == nil })
        }

        /// The outbox's element rows and the patches; the records that lost an edit take the server's
        /// version again, under the guard, so their rows match what the server lists.
        func dropStaleElementEdits(before horizon: Date, now: Date) throws -> Int {
            var dropped = try PendingPatch.dropStaleElements(before: horizon, in: store, now: now)
            let records = try feeder.dropStaleElementEdits(before: horizon)
            dropped += records.count
            guard !records.isEmpty else { return dropped }
            try replica.apply { _ in
                for record in records { try self.project(record) }
            }
            return dropped
        }
    }
}
