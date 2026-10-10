import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The late import's world (docs/cloudkit-schema-design.md §13.6, WP16b): another Mac's generation-1 store
/// writes the old container (a `FakeCloudKit`, with the records `CloudKitRecordMapper.makeRecord` builds),
/// the Mac under test is a generation-2 store with the registry's triggers and a replica, and the seed is
/// stood in for by mapping the old world through `LegacyV2Mapping` into the replica, the base and the
/// manifest, exactly as the seed would have published them. The base, the manifest and the body uploads are
/// in memory.
final class MigrationImportRig: @unchecked Sendable {
    typealias N = NotebookSyncFixture

    static let learner = "_learner"
    static let zoneName = CloudKitZoneHome.knowledgeZoneName
    static let deviceID = "macaaaaa"

    let server = FakeCloudKit()
    let oldContainer: FakeCloudKit.Transport
    let root: URL
    let store: KnowledgeStore
    let senderRoot: URL
    let sender: KnowledgeStore
    let local: MacPrivateSyncStore
    let base = InMemoryMigrationBase()
    let ledger = InMemoryMigrationLedger()
    let uploader = RecordingBodyUploader()
    let clock = PassClock()

    init() throws {
        senderRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ImportSender-\(UUID().uuidString)", isDirectory: true)
        sender = try KnowledgeStore(
            storeDirectory: senderRoot.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: senderRoot.appendingPathComponent("Content", isDirectory: true), syncGeneration: .one, freeSpace: Schema154Fixture.roomy
        )
        (root, store) = try N.makeStore("import")
        try N.prepareReplica(store)
        for key in [N.libraryZoneKey, N.catalogZoneKey] {
            var zone = try #require(try store.replica.zone(key: key))
            zone.lastCompletePassAt = 1
            try store.replica.upsertZone(zone)
        }
        local = MacPrivateSyncStore.direct(store)
        oldContainer = server.transport(user: Self.learner, container: FakeCloudKit.legacyContainer, device: "mac")
        server.put([], zone: Self.zoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer)
    }

    /// Marks every zone this Mac holds as fetched to its end: a pass runs only once the fetch of `Library`,
    /// `Catalog` and every space is complete, so a test that adds a space (as an inbound change would) says
    /// that Mac has fetched it.
    func finishFetchOfEveryZone() throws {
        try store.execute("UPDATE ck_zones SET last_complete_pass_at = 1 WHERE last_complete_pass_at IS NULL")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: senderRoot)
    }

    // MARK: The importer

    func importer() -> MigrationLateImport {
        var configuration = MigrationLateImport.Configuration(deviceID: Self.deviceID)
        configuration.clock = { [clock] in clock.now }
        return MigrationLateImport(
            oldContainer: oldContainer, store: local, base: base, ledger: ledger, gate: StoreMigrationFetchGate(store: local),
            uploader: uploader, probe: StoreMigrationBodyEditProbe(store: store), configuration: configuration
        )
    }

    @discardableResult
    func run(_ role: MigrationImportRole = .importer, guardLifted: Bool = false) async throws -> MigrationPassOutcome {
        try await importer().run(role: role, guardLifted: guardLifted)
    }

    /// The report of a pass that imported.
    @discardableResult
    func imported(_ role: MigrationImportRole = .importer, guardLifted: Bool = false) async throws -> MigrationPassReport {
        let outcome = try await run(role, guardLifted: guardLifted)
        guard case .imported(let report) = outcome else {
            Issue.record("the pass did not import: \(outcome)")
            return MigrationPassReport(passID: "")
        }
        return report
    }

    // MARK: The old world

    /// Puts what the sender's pending change for `entity` / `key` would upload into the old container.
    @discardableResult
    func publish(_ entity: CloudKitSyncEntity, _ key: String) throws -> CloudRecord {
        try sender.markRecordChanged(entity: entity, logicalKey: key)
        let change = try #require(try sender.pendingSyncChanges().first { $0.entity == entity && $0.logicalKey == key })
        let ck = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
        let stored = server.put([CloudKitMapping.record(ck)], zone: Self.zoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer)
        try sender.clearPendingSyncChange(entity: entity, logicalKey: key)
        return try #require(stored.first)
    }

    func deleteFromOldWorld(_ name: String) async throws {
        _ = try await oldContainer.modifyRecords(deleting: [CloudRecordID(name, in: CloudZoneID(Self.zoneName))], in: .private)
    }

    func notebook(_ title: String) throws -> String {
        let goal = try sender.createCompanionGoal(
            title: title, topic: title, startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt, dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: []
        )
        try publish(.learningGoal, goal.id)
        return goal.id
    }

    func rename(_ notebookID: String, to title: String) throws {
        var goal = try #require(try sender.loadLearningGoal(notebookID))
        goal.title = title
        try sender.saveLearningGoalRecord(goal)
        try publish(.learningGoal, notebookID)
    }

    func setNotes(_ notebookID: String, _ notes: String) throws {
        var goal = try #require(try sender.loadLearningGoal(notebookID))
        goal.notes = notes
        try sender.saveLearningGoalRecord(goal)
        try publish(.learningGoal, notebookID)
    }

    func source(_ id: String) throws {
        try N.addSource(sender, id)
        try publish(.source, id)
    }

    func file(_ sourceID: String, into notebookID: String) throws {
        try N.file(sender, sourceID, into: notebookID)
        try publish(.learningGoal, notebookID)
    }

    func unfile(_ sourceID: String, from notebookID: String) throws {
        try sender.execute("DELETE FROM learning_goal_items WHERE goal_id = ? AND source_id = ?", [.text(notebookID), .text(sourceID)])
        try publish(.learningGoal, notebookID)
    }

    func chat(_ id: String, in notebookID: String) throws {
        try ChatSyncFixture.addChat(sender, id, kind: .chat, goalID: notebookID)
        try ChatSyncFixture.addExchange(sender, chat: id)
        try publish(.reviewSession, id)
    }

    func addTurn(to chatID: String, question: String) throws {
        try ChatSyncFixture.addExchange(sender, chat: chatID, question: question)
        try publish(.reviewSession, chatID)
    }

    static let docBody = "# Landscape\n\nIntro paragraph.\n\n## Evidence\n\nLine about the evidence.\n"

    func doc(_ id: String, title: String, body: String) throws {
        try sender.saveArtifactRecord(ArtifactRecord(
            id: id, title: title, homeNotebookID: nil, linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 100), updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        ))
        try sender.saveArtifactMarkdownFromSync(body, artifactID: id)
        try publish(.artifact, id)
    }

    // MARK: The seed

    /// What the seed leaves behind: the old world mapped into the replica (as a record from another device,
    /// every field stamped with the old record's date), the base's shards and tokens, and the manifest.
    func seed() async throws {
        let fetcher = MigrationOldChangeFetcher(transport: oldContainer)
        let zone = try #require(MigrationOldZone(name: Self.zoneName))
        let fetched = try await fetcher.fetch(zone, since: nil)
        var walk = OldContainerWalkResult(startedAt: clock.now)
        walk.zones = [OldContainerWalkedZone(zoneID: zone.zoneID, database: .private, records: fetched.modified, token: try #require(fetched.token))]
        // payloadAsset is payload: every Doc's package, and a chat over 512 KiB whose `payload` is empty.
        let artifacts = Set(fetched.modified.filter {
            $0.recordType == CloudKitSyncEntity.artifact.recordType
                || ($0.recordType == CloudKitSyncEntity.reviewSession.recordType && $0.hasEmptyPayload)
        }.map(\.id.recordName))
        try await OldContainerWalk(transport: oldContainer).fetchPayloadAssets([zone.zoneID: artifacts], into: &walk)
        defer { walk.discard() }

        let context = StoreLegacyMappingContext(connection: store)
        var records: [(record: LegacyV2Record, at: Date)] = []
        for cloud in walk.zones[0].records {
            let decoded = try MigrationLateImport.decode(cloud)
            let mapping = try LegacyV2Mapping.map(decoded, context: context)
            base.set(MigrationBaseShards.entryKey(zone: Self.zoneName, recordName: cloud.id.recordName), MigrationBaseEntry(mapping: mapping, changeTag: cloud.changeTag))
            records += mapping.records.filter { $0.giving != .clears }.map { ($0, cloud.oldModifiedAt) }
        }
        let rank: [SyncRecordType: Int] = [.notebook: 0, .chat: 0, .source: 0, .collection: 0, .artifact: 1, .entry: 2, .exchange: 2]
        let ordered = records.sorted { (rank[$0.record.type] ?? 3) < (rank[$1.record.type] ?? 3) }
        try N.apply(store, try ordered.map { try Self.replicaRecord($0.record, at: $0.at) })
        ledger.addToManifest(records.map { MigrationRecordKey($0.record.type, $0.record.id) })
        base.setWatermark(MigrationImportWatermark(container: FakeCloudKit.legacyContainer, zones: [Self.zoneName], tokens: [Self.zoneName: try #require(fetched.tokenText)]))
    }

    /// One v2 record as the seed would have uploaded it: every field the mapping gives, stamped with the
    /// old record's date by the migration's device.
    static func replicaRecord(_ record: LegacyV2Record, at date: Date) throws -> ReplicaRecord {
        var envelope = SyncEnvelope.new(record.type, id: record.id, saltID: OutboxTestProjections.saltID)
        var patch = RecordPatch(record.type, id: record.id)
        for (field, value) in record.fields where !value.isNull {
            guard let spec = record.type.spec.field(field) else { continue }
            if spec.kind == .scalar {
                patch.changes[field] = .value(value)
            } else if let elements = value.objectValue {
                patch.changes[field] = .elements(elements)
            }
        }
        let milliseconds = SyncTime.milliseconds(date)
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: SyncIdentity.legacyDeviceID)
        }
        let zoneKey = record.type == .source || record.type == .collection ? N.catalogZoneKey : N.libraryZoneKey
        return ReplicaRecord(
            zoneKey: zoneKey, recordName: RecordNaming.recordName(type: record.type, id: record.id, salt: N.salt), recordType: record.type.rawValue,
            wireID: record.id, systemFields: Data([1]), payload: try envelope.storedPayload(), seenPass: nil
        )
    }

    // MARK: The new world

    /// A record as another device of the new world writes it, over what the replica holds.
    func newWorldEdit(_ type: SyncRecordType, _ id: String, _ changes: [String: SyncJSON], ms: Int64) throws {
        let zoneKey = type == .source || type == .collection ? N.catalogZoneKey : N.libraryZoneKey
        let held = try #require(try store.replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: id))
        var envelope = try SyncEnvelope(storedPayload: held.payload)
        var counter = 0
        try envelope.apply(RecordPatch(type, id: id, changes: changes.mapValues { .value($0) })) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: ms, counter: counter, deviceID: "otheraaa")
        }
        var record = held
        record.payload = try envelope.storedPayload()
        record.systemFields = Data([2])
        try N.apply(store, [record])
    }

    /// The server takes every patch the Mac holds, as the engine would send them, and the acknowledgements
    /// settle them.
    @discardableResult
    func sendPatches() async throws -> [OutboxChange] {
        let now = clock.now.addingTimeInterval(120)
        return try await local.perform { state in
            let changes = try state.nextChanges(now: now, limit: 1_000, scope: .all)
            for change in changes { try state.acknowledgeSave(change, serverRecord: try OutboxTestProjections.serverRecord(for: change)) }
            return changes
        }
    }

    func patch(_ type: SyncRecordType, _ id: String) throws -> PendingPatch? {
        let zoneKey = type == .source || type == .collection ? N.catalogZoneKey : N.libraryZoneKey
        return try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: id, in: store)
    }

    func patchCount() throws -> Int { Int(try store.scalarInteger("SELECT COUNT(*) FROM ck_patches") ?? 0) }
    func localTitle(_ notebookID: String) throws -> String? { try store.scalarText("SELECT title FROM learning_goals WHERE id = ?", [.text(notebookID)]) }
    func manifestPending() throws -> Int { Int(try store.scalarInteger("SELECT COUNT(*) FROM ck_manifest_pending") ?? 0) }
}

// MARK: - The base, the manifest and the uploads, in memory

/// The shared base and its watermark, as `RootMigrationBaseStore` keeps them on the root.
final class InMemoryMigrationBase: MigrationBaseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: MigrationBaseEntry] = [:]
    private var mark: MigrationImportWatermark?
    private(set) var advances = 0
    /// The next `advance` meets a root that changed meanwhile.
    var losesNextAdvance = false

    func set(_ key: String, _ entry: MigrationBaseEntry) { lock.withLock { entries[key] = entry } }
    func setWatermark(_ watermark: MigrationImportWatermark) { lock.withLock { mark = watermark } }
    func entry(_ key: String) -> MigrationBaseEntry? { lock.withLock { entries[key] } }
    var all: [String: MigrationBaseEntry] { lock.withLock { entries } }
    var current: MigrationImportWatermark? { lock.withLock { mark } }

    func watermark() async throws -> MigrationImportWatermark? { lock.withLock { mark } }

    func shard(_ name: String) async throws -> [String: MigrationBaseEntry] {
        lock.withLock {
            entries.filter { key, _ in
                MigrationBaseShards.recordName(ofEntryKey: key).map(MigrationBaseShards.name(forRecordName:)) == name
            }
        }
    }

    func advance(_ update: MigrationBaseAdvance) async throws -> Bool {
        lock.withLock {
            if losesNextAdvance {
                losesNextAdvance = false
                return false
            }
            for (key, entry) in update.entries { entries[key] = entry }
            mark = update.watermark
            advances += 1
            return true
        }
    }
}

/// The seed manifest and the manifest deltas.
final class InMemoryMigrationLedger: MigrationManifestLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: Set<MigrationRecordKey> = []
    private(set) var deltas: [String: [MigrationRecordKey]] = [:]
    private(set) var folds = 0

    func addToManifest(_ keys: [MigrationRecordKey]) { lock.withLock { manifest.formUnion(keys) } }

    func listed(_ keys: Set<MigrationRecordKey>) async throws -> Set<MigrationRecordKey> {
        lock.withLock { keys.filter { key in manifest.contains(key) || deltas.values.contains { $0.contains(key) } } }
    }

    func writeDelta(key: String, records: [MigrationRecordKey]) async throws { lock.withLock { deltas[key] = records } }
    func deltaCount() async throws -> Int { lock.withLock { deltas.count } }

    func fold() async throws {
        lock.withLock {
            for records in deltas.values { manifest.formUnion(records) }
            deltas = [:]
            folds += 1
        }
    }
}

/// Uploads nothing; remembers what it was asked to, and answers with the FileRef the bytes lay out as.
final class RecordingBodyUploader: MigrationBodyUploader, @unchecked Sendable {
    struct Upload: Equatable {
        var owner: String
        var mime: String
        var bytes: Int
        var spaceID: String?
    }

    private let lock = NSLock()
    private(set) var uploads: [Upload] = []

    func upload(_ body: Data, owner: String, mime: String, encoding: BlobStore.Encoding, spaceID: String?) async throws -> FileRef {
        lock.withLock { uploads.append(Upload(owner: owner, mime: mime, bytes: body.count, spaceID: spaceID)) }
        let stored = encoding == .gzip ? try SyncGzip.compress(body) : body
        return FileRef(
            owner: owner, role: "body", hash: SyncIdentity.sha256Hex(body), size: Int64(body.count), mime: mime, encoding: encoding.rawValue, storedParts: [stored]
        )
    }

    func owners() -> [String] { lock.withLock { uploads.map(\.owner) } }
}

/// A clock a test moves.
final class PassClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}
