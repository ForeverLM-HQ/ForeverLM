import CloudKit
import Foundation
@testable import ForeverLM

/// A Mac on FakeCloudKit for the private engine's suites (docs/cloudkit-schema-design.md §14.2 WP5):
/// a generation-2 store with the test course, lesson and entry projections and their triggers
/// (`OutboxTestProjections`), its local half (`MacPrivateSyncStore`), and a `PrivateSyncEngine` over
/// a FakeCloudKit transport. FakeCloudKit stands in for the plain operations, not for CKSyncEngine,
/// so the engine's own transport loop drives it here: the same logic CKSyncEngine's events reach in
/// the app (sent changes, fetched changes, zone deletions).
///
/// The server's clock follows the wall clock (`EngineTestDriver.follow`), so every device's server
/// offset is the same and the local times the outbox triggers record order stamps as they would.
final class EngineTestDevice {
    let server: FakeCloudKit
    let name: String
    let root: URL
    let store: KnowledgeStore
    let local: MacPrivateSyncStore
    let transport: FakeCloudKit.Transport
    let engine: PrivateSyncEngine
    let deviceID: String

    /// The engine's clock runs ahead of the wall clock by more than any debounce, so a change written
    /// just before a send is due.
    static let ahead: TimeInterval = 5

    /// `registry` runs the app's own projections and triggers instead of the test ones (WP14's Job suites).
    init(_ server: FakeCloudKit, name: String, deviceID: String, user: String = "alice", registry: ProjectionRegistry? = nil,
         configuration: PrivateSyncEngine.Configuration = PrivateSyncEngine.Configuration()) throws {
        self.server = server
        self.name = name
        self.deviceID = deviceID
        (root, store) = try OutboxTestProjections.makeStore(name, triggers: registry == nil)
        if let registry { try store.installOutboxTriggers(registry) }
        local = MacPrivateSyncStore.direct(store, registry: registry ?? OutboxTestProjections.registry)
        transport = server.transport(user: user, device: name)
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        engine = PrivateSyncEngine(
            transport: transport, store: local, pacer: SyncPacer(configuration: pacing), deviceID: deviceID,
            configuration: configuration, clock: { Date().addingTimeInterval(EngineTestDevice.ahead) }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func bootstrap(_ client: ZoneBootstrap.Client = .macHoldingLibrary, salt: UInt8 = 1) async throws -> ZoneBootstrap.Outcome {
        EngineTestDriver.follow(server)
        var bootstrap = ZoneBootstrap(transport: transport, store: local, client: client, deviceID: deviceID)
        bootstrap.now = { Date().addingTimeInterval(EngineTestDevice.ahead) }
        bootstrap.makeSalt = { Data(repeating: salt, count: 32) }
        return try await bootstrap.run()
    }

    func sync() async throws {
        EngineTestDriver.follow(server)
        try await engine.sync()
    }

    func send() async throws {
        EngineTestDriver.follow(server)
        try await engine.sendChanges()
    }

    func fetch() async throws {
        EngineTestDriver.follow(server)
        try await engine.fetchChanges()
    }

    func exec(_ sql: String) throws {
        try store.executeScript(sql)
    }

    func text(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        try store.scalarText(sql, parameters)
    }

    func count(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
        try store.scalarInteger(sql, parameters) ?? -1
    }

    /// The record of `type` and `id` as the server holds it in `Library`, decoded.
    func serverEnvelope(_ type: SyncRecordType, _ id: String, zone: String = "Library", user: String = "alice") throws -> SyncEnvelope? {
        guard let salt = try personalSalt() else { return nil }
        let name = RecordNaming.recordName(type: type, id: id, salt: salt)
        guard let payload = server.storedRecord(name, zone: zone, owner: user)?.payload else { return nil }
        return try SyncEnvelope(storedPayload: payload)
    }

    func personalSalt() throws -> Data? {
        try store.replica.personalRoot()?.envelope.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
    }

    func recordName(_ type: SyncRecordType, _ id: String) throws -> String {
        RecordNaming.recordName(type: type, id: id, salt: try personalSalt() ?? Data())
    }

    /// Outbox rows still waiting, pins aside.
    func outboxRows() throws -> Int64 {
        try count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table <> ?", [.text(OutboxFeeder.pinSource)])
            + count("SELECT COUNT(*) FROM ck_outbox")
    }

    /// The stamps pinned for changes handed out and not yet settled.
    func pinCount() throws -> Int64 {
        try count("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(OutboxFeeder.pinSource)])
    }
}

enum EngineTestDriver {
    /// A server whose clock starts at the wall clock.
    static func server() -> FakeCloudKit {
        FakeCloudKit(start: Date())
    }

    /// Moves the server's clock up to the wall clock (it moves one tick per write on its own).
    static func follow(_ server: FakeCloudKit) {
        let behind = Date().timeIntervalSince(server.now)
        if behind > 0 { server.advance(by: behind) }
    }

    /// Lets the wall clock move on, so the next local write is timed after the last.
    static func pause() async {
        try? await Task.sleep(nanoseconds: 15_000_000)
    }
}
