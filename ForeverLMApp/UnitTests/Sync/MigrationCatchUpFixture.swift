import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// A Mac with generation-1 history and an old container written by another Mac, for the migration
/// catch-up's and the activation's suites (docs/cloudkit-schema-design.md §13.3, §13.4 step 0, WP16a).
///
/// `receiver` is the store the activation runs on, opened as generation 2 (the library
/// `Schema154Fixture.makeLibrary` builds). `sender` is another Mac's generation-1 store: it writes a
/// record with today's own writers, and `publish` puts what generation 1 would upload into the old
/// container of a `FakeCloudKit` (the record `CloudKitRecordMapper.makeRecord` builds, which carries the
/// Doc body package as `payloadAsset`). `lastSynced` is the receiver as it was when it last received
/// that record: the record applied and its change tag in `sync_metadata`.
final class MigrationCatchUpRig: @unchecked Sendable {
    static let learner = "_learner"
    static let baseBody = "# Landscape\n\nIntro paragraph.\n\n## Evidence\n\nLine about the evidence.\n"

    let server = FakeCloudKit()
    let oldContainer: FakeCloudKit.Transport
    let receiverRoot: URL
    let receiver: KnowledgeStore
    let senderRoot: URL
    let sender: KnowledgeStore

    var access: DirectStoreAccess { DirectStoreAccess(store: receiver) }

    init() throws {
        senderRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CatchUpSender-\(UUID().uuidString)", isDirectory: true)
        sender = try KnowledgeStore(
            storeDirectory: senderRoot.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: senderRoot.appendingPathComponent("Content", isDirectory: true), syncGeneration: .one, freeSpace: Schema154Fixture.roomy
        )
        receiverRoot = try Schema154Fixture.temporaryRoot("catchup-receiver")
        try Schema154Fixture.makeLibrary(at: receiverRoot, version: nil, generation: .one)
        Schema154Fixture.newLaunch(receiverRoot)
        receiver = try KnowledgeStore(storeDirectory: receiverRoot, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        oldContainer = server.transport(user: Self.learner, container: FakeCloudKit.legacyContainer, device: "mac")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: senderRoot)
        try? FileManager.default.removeItem(at: receiverRoot)
    }

    // MARK: Change tags

    /// Reads the change tag of a blob this rig wrote (`Data(tag.utf8)`) or the fake server handed out.
    static let tagReader: @Sendable (Data) -> String? = { data in
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = object["tag"] as? String { return tag }
        return String(data: data, encoding: .utf8)
    }

    var configuration: MigrationCatchUpConfiguration {
        var configuration = MigrationCatchUpConfiguration()
        configuration.changeTag = Self.tagReader
        return configuration
    }

    func catchUp(guardLifted: Bool = false) async throws -> MigrationCatchUpOutcome {
        var configuration = self.configuration
        configuration.guardLifted = guardLifted
        return try await MigrationCatchUp(transport: oldContainer, access: access, configuration: configuration).run()
    }

    /// A catch-up through `access` in batches of `batchSize`, with this rig's tag reader.
    func catchUp(through access: any MigrationStoreAccess, batchSize: Int) async throws -> MigrationCatchUpOutcome {
        var configuration = self.configuration
        configuration.batchSize = batchSize
        return try await MigrationCatchUp(transport: oldContainer, access: access, configuration: configuration).run()
    }

    /// The Recovered Docs the catch-up still owes (`ck_backfill_queue`).
    func owedRecoveries() throws -> Int {
        try MigrationRecoveryQueue.pending(store: receiver)
    }

    /// The report of a catch-up that applied.
    func applied(guardLifted: Bool = false) async throws -> MigrationCatchUpReport {
        guard case .applied(let report) = try await catchUp(guardLifted: guardLifted) else {
            Issue.record("the catch-up did not apply")
            return MigrationCatchUpReport()
        }
        return report
    }

    // MARK: The old world

    /// The old container's `Knowledge` zone exists, as an account that ever synced has it.
    func createKnowledgeZone() {
        server.put([], zone: CloudKitZoneHome.knowledgeZoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer)
    }

    /// Puts what the sender's pending change for `entity` / `key` would upload into the old container.
    @discardableResult
    func publish(_ entity: CloudKitSyncEntity, _ key: String) throws -> CloudRecord {
        let change = try #require(try sender.pendingSyncChanges().first { $0.entity == entity && $0.logicalKey == key })
        let ck = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
        let stored = server.put([CloudKitMapping.record(ck)], zone: CloudKitZoneHome.knowledgeZoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer)
        try sender.clearPendingSyncChange(entity: entity, logicalKey: key)
        return try #require(stored.first)
    }

    func storedRecord(_ name: String) -> CloudRecord? {
        server.storedRecord(name, zone: CloudKitZoneHome.knowledgeZoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer)
    }

    /// Another Mac deletes the record in the old world.
    func deleteFromOldWorld(_ name: String) async throws {
        _ = try await oldContainer.modifyRecords(deleting: [CloudRecordID(name, in: CloudZoneID(CloudKitZoneHome.knowledgeZoneName))], in: .private)
    }

    // MARK: The receiver

    /// This Mac as it was when it last received `record`: applied, with its tag in `sync_metadata`.
    func lastSynced(_ record: CloudRecord) throws {
        let applied = try CloudKitRecordMapper.apply(record: OldContainerWalk.ckRecord(record), to: receiver)
        try receiver.saveSyncMetadata(CloudKitSyncMetadata(
            entity: applied.entity, logicalKey: applied.logicalKey, recordName: record.id.recordName,
            systemFieldsData: Data((record.changeTag ?? "").utf8), userModificationDate: applied.userModificationDate, isDeleted: false
        ))
        try receiver.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
    }

    /// A pending change this Mac's drain has not sent, at `date`.
    func pending(_ entity: CloudKitSyncEntity, _ key: String, at date: Date) throws {
        try receiver.clearPendingSyncChange(entity: entity, logicalKey: key)
        try receiver.markRecordChanged(entity: entity, logicalKey: key, at: date)
    }

    // MARK: Docs

    static func artifact(_ id: String, title: String) -> ArtifactRecord {
        ArtifactRecord(
            id: id, title: title, homeNotebookID: nil, linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 100), updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }

    /// The sender writes a Doc (or rewrites one) and publishes it.
    @discardableResult
    func senderDoc(_ id: String, title: String, body: String) throws -> CloudRecord {
        try sender.saveArtifactRecord(Self.artifact(id, title: title))
        try sender.saveArtifactMarkdownFromSync(body, artifactID: id)
        try sender.markRecordChanged(entity: .artifact, logicalKey: id)
        return try publish(.artifact, id)
    }

    /// The receiver holds the Doc as last synced (`base`), and then `mine` on top of it as its own edit.
    func receiverDoc(_ id: String, title: String, base: String, mine: String? = nil) throws {
        try receiver.saveArtifactRecord(Self.artifact(id, title: title))
        try receiver.saveArtifactMarkdownFromSync(base, artifactID: id)
        if let mine { try receiver.saveArtifactMarkdownAfterMerge(mine, artifactID: id) }
    }

    func receiverBody(_ id: String) throws -> String? { try receiver.loadArtifactMarkdownForSync(id) }

    func title(_ id: String) throws -> String? { try receiver.scalarText("SELECT title FROM global_artifacts WHERE id = ?", [.text(id)]) }

    func recoveredDocs() throws -> [String] {
        var ids: [String] = []
        try receiver.query("SELECT id FROM global_artifacts WHERE id LIKE 'recovered:%' ORDER BY id", []) { ids.append($0.text(0) ?? "") }
        return ids
    }

    // MARK: Notebooks

    /// A notebook the sender made, published, and applied here as the Mac's last sync.
    func sharedNotebook(notes: String?) throws -> String {
        let notebook = try sender.createCompanionGoal(
            title: "Notes", topic: "Notes", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: []
        )
        if let notes { try setSenderNotes(notebook.id, notes) }
        try lastSynced(try publish(.learningGoal, notebook.id))
        return notebook.id
    }

    func setSenderNotes(_ id: String, _ notes: String) throws {
        var goal = try #require(try sender.loadLearningGoal(id))
        goal.notes = notes
        try sender.saveLearningGoalRecord(goal)
        try sender.markRecordChanged(entity: .learningGoal, logicalKey: id)
    }

    func setReceiverNotes(_ id: String, _ notes: String) throws {
        var goal = try #require(try receiver.loadLearningGoal(id))
        goal.notes = notes
        try receiver.saveLearningGoalRecord(goal)
    }

    func receiverNotes(_ id: String) throws -> String? {
        try receiver.scalarText("SELECT notes FROM learning_goals WHERE id = ?", [.text(id)])
    }

    func notesBase(_ id: String) throws -> String? {
        try receiver.scalarText("SELECT base_text FROM ck_legacy_bodies WHERE record_type = 'Notebook' AND wire_id = ? AND field = 'notes'", [.text(id)])
    }

    /// One row of the receiver's `sync_metadata` with a system-fields blob, so the store has history.
    func giveHistory() throws {
        try receiver.exec("INSERT OR IGNORE INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at, is_deleted) VALUES ('preference', 'history.marker', 'Preference-history', X'00', 1, 0)")
    }
}

/// A Mac's clock that sleeping moves, for the activation's 2-minute wait.
final class ActivationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A store access whose step number `cancelAt` raises the cancellation a closed window raises, and every
/// later one too: the run stops where a quit or a closed window would stop it.
final class CancellingStoreAccess: MigrationStoreAccess, @unchecked Sendable {
    private let inner: DirectStoreAccess
    private let cancelAt: Int
    private let lock = NSLock()
    private var steps = 0

    init(store: KnowledgeStore, cancelAt: Int) {
        inner = DirectStoreAccess(store: store)
        self.cancelAt = cancelAt
    }

    func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T {
        let step = lock.withLock { () -> Int in steps += 1; return steps }
        if step >= cancelAt { throw CancellationError() }
        return try await inner.perform(body)
    }
}
