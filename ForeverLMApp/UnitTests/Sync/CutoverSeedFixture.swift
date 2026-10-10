import Foundation
@testable import ForeverLM

/// A Mac with a library and the seeder's environment over FakeCloudKit, for WP16's suites
/// (docs/cloudkit-schema-design.md §13.4, §13.5): the app's own projections and triggers, a root made by a
/// Mac that holds the library (so it already holds the seed claim), rows written as generation 1 left them
/// (no outbox row: the activation's derivations write under no trigger), and the engine as the sender.
enum CutoverSeedFixture {
    typealias F = NotebookSyncFixture

    static let user = "alice"
    static let clock: @Sendable () -> Date = { Date().addingTimeInterval(EngineTestDevice.ahead) }

    /// Writes as the activation does, under the apply guard, so no trigger enqueues the rows.
    static func quietly(_ store: KnowledgeStore, _ body: () throws -> Void) throws {
        try store.execute("INSERT INTO ck_apply_guard (id) VALUES (1)")
        defer { try? store.execute("DELETE FROM ck_apply_guard") }
        try body()
    }

    /// Two notebooks, three sources, one of them filed into the first, as a generation-1 library holds them.
    static func addLibrary(_ store: KnowledgeStore) throws {
        try quietly(store) {
            try F.addNotebook(store, "nb1", title: "One")
            try F.addNotebook(store, "nb2", title: "Two")
            for id in ["s1", "s2", "s3"] { try F.addSource(store, id) }
            try F.file(store, "s1", into: "nb1")
        }
    }

    /// `ck_activation` as the activation leaves it, with the walk's start time.
    static func activate(_ store: KnowledgeStore, mode: String = "full", freshReason: String? = nil, catchUpAt: Double = 700_000_000) throws {
        try store.execute("""
            INSERT INTO ck_activation (id, mode, fresh_reason, started_at, catch_up_at, activated_at, step) VALUES (1, ?, ?, ?, ?, ?, 'activated')
            ON CONFLICT(id) DO UPDATE SET mode = excluded.mode, fresh_reason = excluded.fresh_reason, started_at = excluded.started_at,
                catch_up_at = excluded.catch_up_at, activated_at = excluded.activated_at
        """, [.text(mode), .text(freshReason), .real(catchUpAt), .real(catchUpAt), .real(catchUpAt)])
    }

    static func writer(_ mac: EngineTestDevice) -> MaintenanceWriter {
        MaintenanceWriter(transport: mac.transport, store: mac.local, moveMaps: MoveMapIndex(), deviceID: mac.deviceID, clock: clock)
    }

    static func blobs(_ mac: EngineTestDevice) -> BlobStore {
        MaintenanceFixture.blobs(mac, clock: clock)
    }

    /// The seeder's environment on `mac`: the engine sends, the canary does not pause, nothing sleeps.
    static func environment(_ mac: EngineTestDevice, holdsLibrary: Bool = true) -> CutoverSeedEnvironment {
        let engine = mac.engine
        let server = mac.server
        var environment = CutoverSeedEnvironment(
            transport: mac.transport, store: mac.local, registry: KnowledgeStore.projectionRegistry, blobs: blobs(mac), writer: writer(mac),
            deviceID: mac.deviceID, oldContainer: "iCloud.com.foreverlm",
            send: {
                EngineTestDriver.follow(server)
                try await engine.sendChanges()
            },
            pendingCount: { await engine.pendingCount },
            holdsLibrary: { holdsLibrary }
        )
        environment.clock = clock
        environment.sleep = { _ in }
        environment.configuration.canaryPause = 0
        return environment
    }

    /// A Mac that made the root and holds the library (so it is the seeder), with the sample library.
    static func seeder(_ server: FakeCloudKit, name: String, deviceID: String = "macaaaaa", library: Bool = true) async throws -> EngineTestDevice {
        let mac = try EngineTestDevice(server, name: name, deviceID: deviceID, user: user, registry: KnowledgeStore.projectionRegistry)
        try activate(mac.store)
        if library { try addLibrary(mac.store) }
        try await mac.bootstrap(.macHoldingLibrary)
        return mac
    }

    /// The shared base as the root names it, read the way the importer reads it.
    static func baseEntries(_ mac: EngineTestDevice) async throws -> [String: MigrationBaseEntry] {
        let local = mac.local
        func zone(_ key: String) async throws -> BlobZone {
            guard let zone = try await local.perform({ try BlobZone.resolve(zoneKey: key, in: $0) }) else { throw CloudError(.zoneNotFound, message: key) }
            return zone
        }
        let store = RootMigrationBaseStore(
            store: local, blobs: blobs(mac), writer: writer(mac),
            library: { try await zone(PrivateSyncZones.libraryKey) }, content: { try await zone(PrivateSyncZones.key(PrivateSyncZones.content)) }
        )
        return try await MigrationBaseReader(store: store).all()
    }

    /// The root as the server holds it.
    static func root(_ server: FakeCloudKit) throws -> SyncEnvelope {
        guard let root = try MaintenanceFixture.stored(server, SyncSchema.rootRecordName) else { throw CloudError(.unknownItem, message: "no root") }
        return root
    }

    static func seedMap(_ server: FakeCloudKit) throws -> [String: SyncJSON] {
        try root(server).fields["seed"]?.objectValue ?? [:]
    }

    /// A stamp's milliseconds of one field.
    static func stampMilliseconds(_ envelope: SyncEnvelope?, _ field: String) -> Int64? {
        if case .value(let stamp)? = envelope?.stamps[field] { return stamp.milliseconds }
        return nil
    }
}
