import CloudKit
import Foundation
import OSLog

// MARK: - Late import (docs/cloudkit-schema-design.md §13.6, WP16b)

/// Who runs a pass. The importer is the seed-claim holder until the seed completes and then the
/// maintenance-lease holder; it alone advances the shared base and the tokens. Any other Mac that takes
/// over the seed, reconciles or rolls forward runs the same pass from the same base and writes the same
/// patches, and leaves the base alone, so the pass is idempotent (§13.5). The refresh (§13.4 step 0) is
/// the same pass over this Mac's own snapshot: it advances that snapshot, never the shared base.
enum MigrationImportRole: Sendable, Equatable {
    case importer
    case other
    case refresh

    /// Moves the base it read (the shared one, or the refresh's own snapshot) once its patches are acknowledged.
    var advancesBase: Bool { self != .other }
    /// Only the importer folds the manifest deltas.
    var foldsDeltas: Bool { self == .importer }
    var pass: MigrationPassKind { self == .refresh ? .refresh : .importPass }
}

/// What one pass did, for the log, Settings and the tests.
struct MigrationPassReport: Equatable, Sendable {
    var passID: String
    /// Old records changed since the tokens, and deleted.
    var changed = 0
    var deleted = 0
    var writes = 0
    var creates = 0
    var removals = 0
    var kept = 0
    var skipped = 0
    var notApplied = 0
    /// Old records that still wait for a record that does not exist yet.
    var waiting = 0
    /// Old records that did not decode or map; they wait and are fetched by name again.
    var failed: [String] = []
    /// Writes whose zone this Mac does not hold yet.
    var unplaced = 0
    var sawOldWrite = false
    /// The importer's base and tokens moved: its patches were acknowledged.
    var advanced = false
    var queuedAssets = 0
}

enum MigrationPassOutcome: Equatable, Sendable {
    /// This Mac's fetch of `Library`, `Catalog` and every space is not complete, or the root holds no base:
    /// a record that has not arrived yet must never be taken for absent (§13.6 "When a pass runs").
    case notReady
    /// Another account is signed in than the one the activation recorded (§2.5).
    case accountChanged
    /// A tripped 5% guard's question waits for the learner: the importer's hourly pass applies nothing and
    /// leaves the base where it was, and a Mac whose pass runs before its reconcile or a takeover does not
    /// reconcile, take over or send (R8-m5).
    case waitingForQuestion
    /// The importer's earlier patches are on their way: the base moves once they are acknowledged.
    case waitingForAcknowledgement
    case guardTripped(MigrationImportGuardQuestion)
    case imported(MigrationPassReport)
}

/// Whether this Mac's change fetch of every zone it holds is complete.
protocol MigrationFetchGate: Sendable {
    func isComplete() async throws -> Bool
}

/// Uploads the bytes of a body a pass writes (the old Doc package itself, or notes as text) before the
/// record's pointer goes out (D10).
protocol MigrationBodyUploader: Sendable {
    func upload(_ body: Data, owner: String, mime: String, encoding: BlobStore.Encoding, spaceID: String?) async throws -> FileRef
}

/// A pass of late import: the old zones' changes since the shared base's tokens, mapped by
/// `LegacyV2Mapping` and decided by `MigrationImportPlanner`, written as patches. It reads the old
/// container and the replica and writes `ck_patches`; it never writes the old container and the old
/// engine never starts. WP16b2's refresh and deferred catch-up reuse the planner and `MigrationImportStore`
/// with their own snapshot as the base.
actor MigrationLateImport {
    struct Configuration: Sendable {
        var deviceID: String
        var clock: @Sendable () -> Date = { Date() }
        var assetsRoot: URL = FileManager.default.temporaryDirectory
        var registry: ProjectionRegistry = KnowledgeStore.projectionRegistry
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationImport")

    private let oldContainer: any CloudTransport
    private let store: PrivateSyncLocalStore
    private let base: any MigrationBaseStore
    private let ledger: any MigrationManifestLedger
    private let gate: any MigrationFetchGate
    private let uploader: any MigrationBodyUploader
    private let probe: MigrationBodyEditProbe?
    private let configuration: Configuration

    init(
        oldContainer: any CloudTransport, store: PrivateSyncLocalStore, base: any MigrationBaseStore, ledger: any MigrationManifestLedger,
        gate: any MigrationFetchGate, uploader: any MigrationBodyUploader, probe: MigrationBodyEditProbe?, configuration: Configuration
    ) {
        self.oldContainer = oldContainer
        self.store = store
        self.base = base
        self.ledger = ledger
        self.gate = gate
        self.uploader = uploader
        self.probe = probe
        self.configuration = configuration
    }

    // MARK: One pass

    /// Runs one pass. `guardLifted` runs it with the 5% guard off, once: the answer **Apply** (R5-m5,
    /// R6-m9, R7-m3). The question's own answer, stored by `MigrationImportState.answer`, does the same.
    func run(role: MigrationImportRole, guardLifted: Bool = false) async throws -> MigrationPassOutcome {
        guard try await gate.isComplete(), var watermark = try await base.watermark() else { return .notReady }
        let now = configuration.clock()

        // Creates an earlier pass queued and the server has since acknowledged are listed first, so a
        // record deleted in the new world stays deleted whichever pass made it (R5-3).
        try await flushDeltas(role: role)

        let pass = role.pass
        let question = try await store.perform { try MigrationImportState.guardQuestion($0.connection, pass: pass) }
        if let question, question.answer == nil, !guardLifted { return .waitingForQuestion }

        if role.advancesBase, let journal = try await store.perform({ try MigrationImportState.journal($0.connection, pass: pass) }) {
            guard try await finish(journal, pass: pass) else { return .waitingForAcknowledgement }
            watermark = try await base.watermark() ?? watermark
        }
        if try await accountChanged() { return .accountChanged }

        var report = MigrationPassReport(passID: String(UUID().uuidString.prefix(8)).lowercased())
        let zones = watermark.zones.compactMap(MigrationOldZone.init(name:))
        guard !zones.isEmpty else { return .imported(report) }

        // 1. What changed in the old zones since the base's tokens, and the old records that wait.
        let fetcher = MigrationOldChangeFetcher(transport: oldContainer)
        let reader = MigrationBaseReader(store: base)
        var fetched: [MigrationFetchedZone] = []
        for zone in zones {
            fetched.append(try await fetcher.fetch(zone, since: watermark.tokens[zone.name].flatMap(CloudChangeToken.init(base64:))))
        }
        let waitingIDs = try await store.perform { try MigrationImportState.waitingRecords($0.connection, pass: pass) }
        var deletedNames: [String: Set<String>] = [:]
        for index in fetched.indices where !fetched[index].isMissing {
            let zone = fetched[index].zone
            deletedNames[zone.name] = Set(fetched[index].deleted)
            if fetched[index].fullWalk {
                // A walk from nil never reports the deletions it missed: the base names what the zone lost.
                let returned = Set(fetched[index].modified.map(\.id.recordName))
                for (key, _) in try await reader.all() where MigrationBaseShards.zone(ofEntryKey: key) == zone.name {
                    if let name = MigrationBaseShards.recordName(ofEntryKey: key), !returned.contains(name) { deletedNames[zone.name, default: []].insert(name) }
                }
            }
            let seen = Set(fetched[index].modified.map(\.id.recordName)).union(deletedNames[zone.name] ?? [])
            let waitingHere = waitingIDs.compactMap { id -> String? in
                guard MigrationBaseShards.zone(ofEntryKey: id) == zone.name, let name = MigrationBaseShards.recordName(ofEntryKey: id), !seen.contains(name) else { return nil }
                return name
            }
            if !waitingHere.isEmpty {
                let (found, missing) = try await fetcher.fetch(names: waitingHere, in: zone)
                fetched[index].modified += found
                deletedNames[zone.name, default: []].formUnion(missing)
            }
        }
        // A full walk returns every record: those the base already holds at the same change tag are no change.
        var baseEntries: [String: MigrationBaseEntry] = [:]
        for zone in fetched where !zone.isMissing {
            var changed: [CloudRecord] = []
            for record in zone.modified {
                let id = MigrationBaseShards.entryKey(zone: zone.zone.name, recordName: record.id.recordName)
                let entry = try await reader.entry(zone: zone.zone.name, recordName: record.id.recordName)
                if let entry { baseEntries[id] = entry }
                if zone.fullWalk, let entry, !entry.waiting, entry.changeTag != nil, entry.changeTag == record.changeTag { continue }
                changed.append(record)
            }
            if let index = fetched.firstIndex(where: { $0.zone == zone.zone }) { fetched[index].modified = changed }
            for name in deletedNames[zone.zone.name] ?? [] {
                let id = MigrationBaseShards.entryKey(zone: zone.zone.name, recordName: name)
                if baseEntries[id] == nil, let entry = try await reader.entry(zone: zone.zone.name, recordName: name) { baseEntries[id] = entry }
            }
        }

        // 2. payloadAsset is payload: a changed Doc's body package, a chat over 512 KiB.
        var walk = OldContainerWalkResult(startedAt: now)
        for zone in fetched where !zone.isMissing {
            walk.zones.append(OldContainerWalkedZone(zoneID: zone.zone.zoneID, database: zone.zone.database, records: zone.modified, token: zone.token ?? CloudChangeToken(data: Data())))
        }
        defer { walk.discard() }
        var needs: [CloudZoneID: Set<String>] = [:]
        for zone in walk.zones {
            for record in zone.records {
                switch CloudKitSyncEntity.from(recordType: record.recordType) {
                case .artifact?: needs[zone.zoneID, default: []].insert(record.id.recordName)
                case .reviewSession? where record.hasEmptyPayload: needs[zone.zoneID, default: []].insert(record.id.recordName)
                default: break
                }
            }
        }
        var oldWalk = OldContainerWalk(transport: oldContainer)
        oldWalk.assetsRoot = configuration.assetsRoot
        try await oldWalk.fetchPayloadAssets(needs, into: &walk)

        // 3. Decode and map, on the store.
        let walked = walk
        let prepared = try await store.perform { state in
            Self.prepare(walked, baseEntries: baseEntries, deleted: deletedNames, connection: state.connection)
        }
        report.failed = prepared.failed
        report.changed = prepared.inputs.filter { !$0.old.isDeleted }.count
        report.deleted = prepared.inputs.filter(\.old.isDeleted).count
        // An old write is a record whose change tag the base has not seen, or a deletion: an old record
        // fetched again only because it waits is no write, or the quiet period could never end.
        report.sawOldWrite = prepared.inputs.contains { $0.old.isDeleted || $0.base == nil || $0.base?.changeTag != $0.old.changeTag }

        // 4. The world, and the plan.
        let keys = MigrationImportStore.keys(for: prepared.inputs)
        let listed = try await ledger.listed(keys)
        let probe = probe
        let registry = configuration.registry
        let ownRows = role == .refresh
        let (world, waitingSince, newWorldSince) = try await store.perform { state in
            let world = try MigrationImportStore.snapshot(
                keys: keys, listed: listed, probe: probe, connection: state.connection, registry: registry, ownRows: ownRows
            )
            let since = try MigrationImportState.waitingSince(state.connection, pass: pass)
            let seeded = try state.replica.personalRoot()?.envelope.fields["seed"]?.objectValue?["startedAt"]?.int64Value
            return (world, since, seeded.map(SyncTime.date))
        }
        let reach: MigrationImportPlanner.Reach = ownRows ? .absentOnly : .everything
        var plan = MigrationImportPlanner.plan(
            prepared.inputs, world: world, options: .init(now: now, newWorldSince: newWorldSince, waitingSince: waitingSince, reach: reach, ownRows: ownRows)
        )

        // 5. More than 5% of what the base covers would go: ask, never apply (§13.6, R7-m3).
        let lifted = guardLifted || question?.answer == .apply
        if question?.answer == .keep {
            plan = MigrationImportPlanner.plan(
                prepared.inputs, world: world,
                options: .init(now: now, keepRemovals: true, newWorldSince: newWorldSince, waitingSince: waitingSince, reach: reach, ownRows: ownRows)
            )
        } else if !lifted, plan.removals > 0 {
            let covered = try await reader.all().values.reduce(0) { $0 + $1.records.values.filter(\.owned).count }
            if MigrationCatchUpRules.tripsGuard(deleting: plan.removals, of: covered) {
                let asked = MigrationImportGuardQuestion(removing: plan.removals, of: covered, askedAt: now, answer: nil)
                try await store.perform { try MigrationImportState.ask(asked, $0.connection, pass: pass) }
                return .guardTripped(asked)
            }
        }

        // 6. Bytes before pointers, then the patches.
        try await uploadBodies(&plan, records: prepared.records)
        let passKey = "\(configuration.deviceID).\(report.passID)"
        let applied = try await store.perform { state in
            let applied = try MigrationImportStore.apply(plan, passKey: passKey, state: state, now: now, registry: registry, ownRows: ownRows)
            try MigrationImportState.appendKept(plan.kept, state.connection)
            try MigrationImportState.appendNotApplied(plan.notApplied, state.connection)
            try MigrationImportState.updateWaiting(plan, now: now, state.connection, pass: pass)
            // A record that did not decode or map waits, and is fetched by name on every pass.
            if !prepared.failed.isEmpty {
                var since = try MigrationImportState.waitingSince(state.connection, pass: pass)
                for id in prepared.failed where since[id] == nil { since[id] = now }
                try MigrationImportState.saveWaitingSince(since, state.connection, pass: pass)
            }
            Self.queueAssets(prepared, connection: state.connection)
            try MigrationImportState.clearQuestion(state.connection, pass: pass)
            return applied
        }
        report.writes = plan.writes.count
        report.creates = applied.created.count
        report.removals = plan.removals
        report.kept = plan.kept.count
        report.skipped = plan.skipped.count
        report.notApplied = plan.notApplied.count
        report.waiting = plan.olds.filter(\.waiting).count
        report.unplaced = applied.unplaced
        report.queuedAssets = prepared.assetRecords.count
        for line in plan.skipped {
            Self.logger.notice("Skipped \(line.type, privacy: .public) \(line.reason.rawValue, privacy: .public)")
        }

        // 7. The importer moves the base once its patches are acknowledged; any other Mac leaves it.
        try await flushDeltas(role: role)
        guard role.advancesBase else { return .imported(report) }
        var next = watermark
        for zone in fetched {
            if zone.isMissing {
                next.zones.removeAll { $0 == zone.zone.name }
                next.tokens[zone.zone.name] = nil
            } else if let token = zone.tokenText {
                next.tokens[zone.zone.name] = token
            }
        }
        next.recordPass(at: now, sawOldWrite: report.sawOldWrite)
        var entries: [String: String?] = [:]
        for old in plan.olds {
            entries.updateValue(old.nextEntry.map { String(decoding: $0.jsonWithTag.serialized(), as: UTF8.self) }, forKey: old.oldRecord)
        }
        let journal = MigrationAdvanceJournal(
            passID: report.passID, entries: entries, watermark: String(decoding: next.json.serialized(), as: UTF8.self),
            patched: applied.patched, deleted: applied.deleted, startedAt: now
        )
        if entries.isEmpty && next == watermark { return .imported(report) }
        try await store.perform { try MigrationImportState.saveJournal(journal, $0.connection, pass: pass) }
        report.advanced = try await finish(journal, pass: pass)
        if report.advanced, role.foldsDeltas, try await ledger.deltaCount() > migrationManifestFoldAbove { try await ledger.fold() }
        return .imported(report)
    }

    // MARK: The importer's journal

    /// Moves the base and the tokens once every patch of the pass is acknowledged and every deletion has
    /// gone; false while any is on its way, or when the root changed meanwhile (the next pass tries again).
    private func finish(_ journal: MigrationAdvanceJournal, pass: MigrationPassKind) async throws -> Bool {
        let acknowledged = try await store.perform { state in
            try journal.patched.allSatisfy { try MigrationImportStore.isAcknowledged($0, state.connection) }
                && journal.deleted.allSatisfy { try MigrationImportStore.isGone($0, state.connection) }
        }
        guard acknowledged, let watermark = (try? SyncJSON(parsing: Data(journal.watermark.utf8))).flatMap(MigrationImportWatermark.init(json:)) else { return false }
        var entries: [String: MigrationBaseEntry?] = [:]
        for (key, text) in journal.entries {
            let entry = text.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }.flatMap { MigrationBaseEntry(json: $0) }
            entries.updateValue(entry, forKey: key)
        }
        guard try await base.advance(MigrationBaseAdvance(entries: entries, watermark: watermark)) else { return false }
        try await store.perform { try MigrationImportState.clearJournal($0.connection, pass: pass) }
        return true
    }

    // MARK: Manifest deltas

    /// Writes the delta of every pass whose creates are all acknowledged (`<deviceID>.<passID>`), and, for
    /// the importer, folds the deltas into the manifest past 32.
    private func flushDeltas(role: MigrationImportRole) async throws {
        try await Self.flushDeltas(store: store, ledger: ledger, folds: role.foldsDeltas)
    }

    /// The same listing for a pass that is not this actor's (the deferred catch-up's creates).
    static func flushDeltas(store: PrivateSyncLocalStore, ledger: any MigrationManifestLedger, folds: Bool) async throws {
        let completed = try await store.perform { try MigrationImportStore.completedDeltas($0.connection) }
        for delta in completed {
            if !delta.records.isEmpty { try await ledger.writeDelta(key: delta.passKey, records: delta.records) }
            try await store.perform { try MigrationImportStore.clearPending(passKey: delta.passKey, $0.connection) }
        }
        if folds, try await ledger.deltaCount() > migrationManifestFoldAbove { try await ledger.fold() }
    }

    // MARK: Account

    /// Another account signed in than the one the activation recorded: a pass stops (§2.5).
    private func accountChanged() async throws -> Bool {
        guard let account = try? await oldContainer.userRecordName() else { return false }
        let recorded = try await store.perform { state in
            try (state.connection as? KnowledgeStore)?.activationJournal()?.account
        }
        guard let recorded else { return false }
        return recorded != account
    }

    // MARK: Bodies

    /// Uploads the bytes of every body the plan writes, so its pointer never goes out before them; a body
    /// the old record cannot give is dropped from the write.
    private func uploadBodies(_ plan: inout MigrationPassPlan, records: [String: LegacyRecord]) async throws {
        try await Self.uploadBodies(&plan, records: records, uploader: uploader)
    }

    static func uploadBodies(_ plan: inout MigrationPassPlan, records: [String: LegacyRecord], uploader: any MigrationBodyUploader) async throws {
        for index in plan.writes.indices {
            guard let source = plan.writes[index].bodySource else { continue }
            let write = plan.writes[index]
            var file: FileRef?
            switch source {
            case .docPackage(let oldRecord):
                if let package = records[oldRecord]?.bodyPackage {
                    file = try await uploader.upload(package, owner: write.key.id, mime: ArtifactBody.packageMime, encoding: .identity, spaceID: write.key.spaceID)
                }
            case .notes(let oldRecord):
                if case .learningGoal(let payload)? = records[oldRecord]?.payload {
                    let text = NotesDoc.text(payload.goal.notes)
                    if write.isRecoveredDoc {
                        // A Recovered Doc is an ordinary Doc: its body is a Markdown package.
                        let encoded = try ArtifactBodyPackage.encode(markdown: text, attachmentDirectory: nil)
                        file = try await uploader.upload(encoded.data, owner: write.key.id, mime: ArtifactBody.packageMime, encoding: .identity, spaceID: write.key.spaceID)
                    } else {
                        file = try await uploader.upload(Data(text.utf8), owner: write.key.id, mime: "text/markdown", encoding: .gzip, spaceID: write.key.spaceID)
                    }
                }
            }
            if let file {
                plan.writes[index].changes["body"] = .value(file.value)
            } else {
                plan.writes[index].changes["body"] = nil
                plan.writes[index].stamps[StampedPath("body")] = nil
            }
        }
    }

    // MARK: Decoding and mapping, on the store

    struct Prepared {
        var inputs: [MigrationOldRecordInput] = []
        /// Decoded old records by `MigrationOldRecord.id`, for their bodies.
        var records: [String: LegacyRecord] = [:]
        var failed: [String] = []
        /// The changed records whose file assets wait for the asset pass.
        var assetRecords: [(zone: OldContainerWalkedZone, record: CloudRecord, entity: CloudKitSyncEntity)] = []
        /// The Sources an old iPhone captured into iCloud Drive `Mobile Imports/`: their file waits for its
        /// download and upload (`MigrationAssetPass`), by the Source's wire id and the path the capture named.
        var mobileImports: [(oldRecord: String, sourceID: String, path: String)] = []
    }

    /// Old assets the pass queues: a changed record's file fields (§13.6 "Assets"), as the activation queues
    /// them for the records it found changed.
    private static let assetEntities: Set<CloudKitSyncEntity> = [.source, .book, .meetingGroup, .course]

    static func prepare(
        _ walk: OldContainerWalkResult, baseEntries: [String: MigrationBaseEntry], deleted: [String: Set<String>], connection: SQLiteConnection
    ) -> Prepared {
        var prepared = Prepared()
        let context = StoreLegacyMappingContext(connection: connection)
        for zone in walk.zones {
            let name = OldContainerZoneKey.snapshotZone(database: zone.database, zoneID: zone.zoneID)
            for cloud in zone.records {
                let id = MigrationBaseShards.entryKey(zone: name, recordName: cloud.id.recordName)
                guard let entity = CloudKitSyncEntity.from(recordType: cloud.recordType), !LegacyOwnership.dropped.contains(entity) else { continue }
                do {
                    let decoded = try decode(cloud)
                    let mapping = try LegacyV2Mapping.map(decoded, context: context)
                    let old = MigrationOldRecord(
                        zone: name, name: cloud.id.recordName, changeTag: cloud.changeTag, modifiedAt: cloud.oldModifiedAt, mapping: mapping,
                        spaceID: context.spaceID(teamID: decoded.teamID)
                    )
                    prepared.inputs.append(MigrationOldRecordInput(old: old, base: baseEntries[id]))
                    prepared.records[id] = decoded
                    if assetEntities.contains(entity) { prepared.assetRecords.append((zone, cloud, entity)) }
                    if case .source(let source) = decoded.payload, let path = source.article.localFilePath, MigrationAssetQueue.isMobileImport(path),
                       let given = mapping.records.first(where: { $0.type == .source && $0.giving == .owns }) {
                        prepared.mobileImports.append((id, given.id, path))
                    }
                } catch {
                    logger.error("An old record does not map: \(cloud.id.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    prepared.failed.append(id)
                }
            }
            for recordName in (deleted[name] ?? []).sorted() {
                let id = MigrationBaseShards.entryKey(zone: name, recordName: recordName)
                guard let base = baseEntries[id] else { continue }
                let spaceID = TeamRecord.teamID(fromZoneName: zone.zoneID.zoneName).flatMap { context.spaceID(teamID: $0) }
                var old = MigrationOldRecord(zone: name, name: recordName, changeTag: nil, modifiedAt: walk.startedAt, mapping: nil, spaceID: spaceID)
                old.deletionRecords = LegacyV2Mapping.deletionRecords(base: base)
                prepared.inputs.append(MigrationOldRecordInput(old: old, base: base))
            }
        }
        return prepared
    }

    /// An old record as today's decoder reads it, with the dates the server gave. `CloudKit` objects built
    /// from the transport's values carry no modification date or change tag of their own.
    static func decode(_ cloud: CloudRecord) throws -> LegacyRecord {
        let decoded = try LegacyRecordDecoder.decode(OldContainerWalk.ckRecord(cloud))
        return LegacyRecord(
            entity: decoded.entity, logicalKey: decoded.logicalKey, recordName: decoded.recordName, zoneName: decoded.zoneName,
            changeTag: cloud.changeTag, modifiedAt: cloud.oldModifiedAt, payload: decoded.payload, bodyPackage: decoded.bodyPackage
        )
    }

    /// Queues the file assets of the changed records and the upload of each `Mobile Imports` capture, as the
    /// activation queues them for the records it found changed (§13.3 step 4, §13.6 "Assets").
    static func queueAssets(_ prepared: Prepared, connection: SQLiteConnection) {
        for (zone, record, entity) in prepared.assetRecords {
            let payload: [String: Any] = [
                "database": zone.database.rawValue, "zone": zone.zoneID.zoneName, "owner": zone.zoneID.ownerName,
                "recordName": record.id.recordName, "entity": entity.rawValue, "fields": MigrationCatchUpApplier.assetFields,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
            let target = "\(OldContainerZoneKey.snapshotZone(database: zone.database, zoneID: zone.zoneID))/\(record.id.recordName)"
            try? connection.execute("""
                INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, target) DO UPDATE SET payload_json = excluded.payload_json, attempts = 0
            """, [.text(MigrationCatchUpApplier.assetQueueKind), .text(target), .text(json), .real(Date().timeIntervalSinceReferenceDate)])
        }
        for (_, sourceID, path) in prepared.mobileImports {
            let json = (try? JSONSerialization.data(withJSONObject: ["path": path], options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
            try? connection.execute("""
                INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, target) DO UPDATE SET payload_json = excluded.payload_json
            """, [.text(MigrationAssetQueue.mobileImportKind), .text(sourceID), .text(json), .real(Date().timeIntervalSinceReferenceDate)])
        }
    }
}

// MARK: - The Mac's seams

/// Whether this Mac's change fetch is complete: `Library` and `Catalog` have each had a fetch from nil
/// that reached the end, and so has every space it holds (`ck_zones.last_complete_pass_at`, set by the
/// engine's fetch and by SpaceSync's walk, §5.7).
struct StoreMigrationFetchGate: MigrationFetchGate {
    let store: PrivateSyncLocalStore

    func isComplete() async throws -> Bool {
        try await store.perform { state in
            let personal = try state.connection.scalarInteger(
                "SELECT COUNT(*) FROM ck_zones WHERE kind IN ('library', 'catalog') AND last_complete_pass_at IS NOT NULL"
            ) ?? 0
            let unfinishedSpaces = try state.connection.scalarInteger(
                "SELECT COUNT(*) FROM ck_zones WHERE kind = 'space' AND last_complete_pass_at IS NULL"
            ) ?? 0
            return personal == 2 && unfinishedSpaces == 0
        }
    }
}

/// `MigrationBodyUploader` through `BlobStore`: a private owner's satellites go to the personal `Content`
/// zone, a space owner's to that space's own zone (§3.5.30).
struct BlobMigrationBodyUploader: MigrationBodyUploader {
    let store: PrivateSyncLocalStore
    let blobs: BlobStore

    func upload(_ body: Data, owner: String, mime: String, encoding: BlobStore.Encoding, spaceID: String?) async throws -> FileRef {
        let zone = try await store.perform { state -> BlobZone? in
            if let spaceID {
                guard let key = try ReplicaPlacement(connection: state.connection).zoneKey(of: .space(spaceID)) else { return nil }
                return try BlobZone.resolve(zoneKey: key, in: state)
            }
            return try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: state).map { BlobZone.personal(salt: $0.salt) }
        }
        guard let zone else { throw CloudError(.zoneNotFound, message: "no zone holds \(owner)") }
        return try await blobs.upload(body, owner: owner, ownerType: .artifact, role: ArtifactBody.role, mime: mime, encoding: encoding, into: zone)
    }
}
