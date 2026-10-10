import Foundation
import OSLog

// MARK: - The deferred catch-up (docs/cloudkit-schema-design.md §13.3 `deferred`, §13.4 step 0, WP16b2)

/// A `deferred` Mac (history, but no iCloud account when it activated, or iCloud unreachable) runs its
/// catch-up later, once the account is reachable and its fetch of the new container is complete. The store is
/// already activated, so this applies through `LegacyV2Mapping` into `ck_patches` (late import's path)
/// instead of into today's tables, and decides each old record with step 0's per-record rule against this
/// Mac's own `sync_metadata` change tags (`MigrationCatchUpPlanner`). Runs after "This Mac holds my library"
/// too (§13.5), where no history makes every old record count as changed and nothing local is removed.
///
/// - A record whose change tag differs and whose local change does not win (`apply`) is mapped and planned by
///   `MigrationImportPlanner` over this Mac's own rows (`Options.ownRows`): with no base to diff against, every
///   v2 field it gives is applied, stamped with the old record's date, and a value the rows already hold is
///   dropped. A record the server holds is patched only while the root holds no base (`Reach`): the importer's
///   pass brings what changed since a base, and a field this view calls changed may have changed before it
///   (R7-1). A record only this Mac's rows hold is patched over what those rows encode.
/// - A record the local change wins (`keepLocal`) is left as it is, and so is one that did not change, but a
///   Doc's or notes' body is still decided by the body rule against this Mac's last-synced body, so an
///   offline edit stays beside one Recovered Doc (R7-3). The kept values themselves are pending changes of
///   §13.5's first kind, which the reconcile captures from the undrained rows.
/// - A name `sync_metadata` holds that the walk did not return was deleted in the old world: its owned
///   records are removal candidates, as are the children a changed record's new mapping no longer gives
///   (`MigrationLocalChildren`), and only those the server does not hold and with no post-activation change
///   in `ck_outbox` are removed, never another Mac's (R5-4, R6-1, R6-2).
/// - A walk that would delete more than 5% of the rows `sync_metadata` names applies nothing and asks
///   (`ActivationQuestion`: Apply, or Not this library); the answer Apply runs it once with the guard lifted
///   (R5-m5, R6-m9).
///
/// It writes each returned notebook's notes base and stages the Doc packages a seed may need (R8-1, R8-m6),
/// this Mac's own snapshot (`OwnSnapshotBase`) with the walk's tokens, and `ck_activation.catch_up_at`. Until
/// it has run, this Mac sends nothing to the new container and takes no seed claim and no lease.
struct MigrationDeferredCatchUp: Sendable {
    enum Outcome: Equatable, Sendable {
        /// This Mac's fetch of the new container is not complete, or a write found no zone to go into yet.
        case notReady
        /// A tripped 5% guard's question waits for the learner.
        case waitingForQuestion
        /// `Knowledge` is not there: no old world, nothing applied, nothing deleted; the Mac records `fresh`
        /// with `knowledgeMissing` and uploads nothing until the learner confirms (R4-m4).
        case noOldWorld(account: String?)
        /// A store that reads nothing from the old zones for itself (`knowledgeMissing`).
        case readsNothing
        case guardTripped(MigrationGuardQuestion)
        case caughtUp(Report)
    }

    struct Report: Equatable, Sendable {
        var returned = 0
        var applied = 0
        var unchanged = 0
        var keptLocal = 0
        var skippedDeletedLocally = 0
        var writes = 0
        var creates = 0
        var removals = 0
        var kept = 0
        var skipped = 0
        var notApplied = 0
        var waiting = 0
        var failed: [String] = []
        /// Names the old world deleted, and those kept because a local change is pending.
        var deletions = 0
        var keptPendingDeletions: [String] = []
        var notesBases = 0
        var stagedPackages = 0
        var queuedAssets = 0
        var snapshotRows = 0
        /// The root held a shared base: records the server holds were left to the import pass.
        var rootHadBase = false
    }

    enum Failure: Error, Equatable {
        case noKnowledgeStore
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")

    let oldContainer: any CloudTransport
    let store: PrivateSyncLocalStore
    /// The shared base on the root: whether it holds one decides how far the pass reaches.
    let base: any MigrationBaseStore
    let ledger: any MigrationManifestLedger
    let gate: any MigrationFetchGate
    let uploader: any MigrationBodyUploader
    let configuration: MigrationLateImport.Configuration
    /// The walk's own settings (change-tag reader, asset folder); a test whose transport hands out tags of its
    /// own supplies the reader.
    var walkConfiguration = MigrationCatchUpConfiguration()
    /// Old records mapped and planned in one step on the store.
    var batchSize = 150
    var progress: (@Sendable (String) -> Void)?

    // MARK: One run

    func run(guardLifted: Bool = false) async throws -> Outcome {
        guard try await gate.isComplete() else { return .notReady }
        let now = configuration.clock()
        let journal = try await onStore { store, _ in try store.activationJournal() ?? ActivationJournal() }
        if journal.mode == .fresh, journal.freshReason == .knowledgeMissing {
            // Another library's zone, or none: nothing is read, and the claim waits for the learner (R6-m9).
            return .readsNothing
        }
        let stored = try await onStore { store, _ in try ActivationQuestion.load(store) }
        if let stored, stored.answer == nil, !guardLifted { return .waitingForQuestion }
        let lifted = guardLifted || stored?.answer == "apply"

        progress?("Reading the old iCloud store")
        let walker = OldContainerWalk(transport: oldContainer, now: { now }, assetsRoot: configuration.assetsRoot)
        var walk = try await walker.fetchZones()
        defer { walk.discard() }
        if walk.knowledgeMissing {
            try await onStore { store, _ in
                var journal = try store.activationJournal() ?? ActivationJournal()
                journal.mode = .fresh
                journal.freshReason = .knowledgeMissing
                try store.writeActivationJournal(journal)
                try ActivationQuestion.clear(store: store)
            }
            return .noOldWorld(account: walk.account)
        }

        var settings = walkConfiguration
        settings.guardLifted = lifted
        settings.now = { now }
        let first = walk
        let needs = try await onStore { store, _ in try MigrationCatchUpPlanner.assetNeeds(walk: first, store: store, configuration: settings) }
        try await walker.fetchPayloadAssets(needs, into: &walk)
        let fetched = walk
        let plan = try await onStore { store, _ in try MigrationCatchUpPlanner.plan(walk: fetched, store: store, configuration: settings) }
        if let question = plan.guardQuestion {
            try await onStore { store, _ in try ActivationQuestion.ask(question, store: store) }
            return .guardTripped(question)
        }

        let hasBase = try await base.watermark() != nil
        let hasHistory = try await onStore { store, _ in
            try store.scalarInteger("SELECT EXISTS(SELECT 1 FROM sync_metadata WHERE system_fields IS NOT NULL)") == 1
        }
        var report = Report(returned: fetched.recordCount, rootHadBase: hasBase)
        let passKey = "\(configuration.deviceID).\(String(UUID().uuidString.prefix(8)).lowercased())"
        var snapshot: [String: MigrationBaseEntry] = [:]

        // 1. Every returned record: mapped, decided, and planned in bounded steps.
        let records = plan.records
        for start in stride(from: 0, to: records.count, by: batchSize) {
            try Task.checkCancellation()
            let chunk = Array(records[start..<min(start + batchSize, records.count)])
            progress?("Applying \(start + chunk.count) of \(records.count)")
            let outcome = try await process(chunk, deletions: nil, hasBase: hasBase, hasHistory: hasHistory, now: now, passKey: passKey, fetched: fetched, report: &report)
            guard outcome.placed else { return .notReady }
            snapshot.merge(outcome.snapshot) { _, new in new }
        }
        // Names the walk returned that did not decode are still held by the snapshot, with no records.
        for zone in fetched.zones {
            let name = OldContainerZoneKey.snapshotZone(database: zone.database, zoneID: zone.zoneID)
            for record in zone.records {
                let key = MigrationBaseShards.entryKey(zone: name, recordName: record.id.recordName)
                if snapshot[key] == nil { snapshot[key] = MigrationBaseEntry(changeTag: record.changeTag) }
            }
        }

        // 2. What the old world deleted: its owned records here, where the server holds nothing.
        let deletions = plan.deletions.apply
        report.keptPendingDeletions = plan.deletions.keptPending
        report.deletions = deletions.count
        for start in stride(from: 0, to: deletions.count, by: batchSize) {
            let names = Array(deletions[start..<min(start + batchSize, deletions.count)])
            let outcome = try await process([], deletions: (names, plan.deletionMetadata), hasBase: hasBase, hasHistory: hasHistory, now: now, passKey: passKey, fetched: fetched, report: &report)
            guard outcome.placed else { return .notReady }
        }

        // 3. The notes bases and the packages a seed may need, after the apply (R8-1, R8-m6).
        for start in stride(from: 0, to: records.count, by: batchSize) {
            let chunk = Array(records[start..<min(start + batchSize, records.count)])
            let counts = try await onStore { store, _ in
                let state = MigrationCatchUpRunState()
                for planned in chunk where planned.decision != .skipDeletedLocally {
                    try MigrationBodies.saveNotesBase(planned, store: store, state: state)
                    if planned.entity == .artifact { try MigrationBodies.stagePackage(planned, store: store, state: state) }
                }
                return (state.report.notesBases, state.report.stagedPackages)
            }
            report.notesBases += counts.0
            report.stagedPackages += counts.1
        }

        // 4. This Mac's snapshot and tokens, and when the walk started.
        progress?("Keeping this Mac's view of the old store")
        var tokens: [String: String] = [:]
        for zone in fetched.zones {
            tokens[OldContainerZoneKey.snapshotZone(database: zone.database, zoneID: zone.zoneID)] = zone.token.data.base64EncodedString()
        }
        try await OwnSnapshotBase(store: store).replaceAll(entries: snapshot, tokens: tokens, zones: tokens.keys.sorted())
        report.snapshotRows = snapshot.count
        let startedAt = fetched.startedAt
        let account = fetched.account
        try await onStore { store, _ in
            var journal = try store.activationJournal() ?? ActivationJournal()
            journal.catchUpAt = startedAt.timeIntervalSinceReferenceDate
            // The account whose library this walk read is the one later passes check (§2.5), also after the learner
            // answered Apply to another library's walk.
            if let account { journal.account = account }
            try store.writeActivationJournal(journal)
            try ActivationQuestion.clear(store: store)
        }
        try await MigrationLateImport.flushDeltas(store: store, ledger: ledger, folds: false)
        return .caughtUp(report)
    }

    // MARK: One bounded step

    private struct StepOutcome {
        /// Every write found its zone.
        var placed = true
        /// The next snapshot entry of each old record the step mapped, by `<zone>/<name>`.
        var snapshot: [String: MigrationBaseEntry] = [:]
    }

    /// Maps and plans `chunk` (or the names the old world deleted) and queues the patches.
    private func process(
        _ chunk: [MigrationPlannedRecord], deletions: (names: [String], metadata: [String: CloudKitSyncMetadata])?, hasBase: Bool,
        hasHistory: Bool, now: Date, passKey: String, fetched: OldContainerWalkResult, report: inout Report
    ) async throws -> StepOutcome {
        var outcome = StepOutcome()
        let registry = configuration.registry
        let walkStart = fetched.startedAt

        // The walk of this step: the chunk's records, or no records for a deletion's zone.
        var chunkWalk = OldContainerWalkResult(startedAt: walkStart)
        var byZone: [CloudZoneID: [CloudRecord]] = [:]
        for planned in chunk { byZone[planned.cloud.id.zoneID, default: []].append(planned.cloud) }
        for zone in fetched.zones {
            let records = byZone[zone.zoneID] ?? []
            if deletions != nil || !records.isEmpty {
                chunkWalk.zones.append(OldContainerWalkedZone(zoneID: zone.zoneID, database: zone.database, records: records, token: zone.token))
            }
        }
        var deletedNames: [String: Set<String>] = [:]
        for name in deletions?.names ?? [] {
            guard let held = deletions?.metadata[name] else { continue }
            let zone = held.home.ownerRecordName == nil ? held.home.zoneName : "\(held.home.zoneName)@\(held.home.ownerRecordName ?? "")"
            deletedNames[zone, default: []].insert(name)
        }

        // 1. Decode and map on the store, with what this Mac's rows give each old record as its base.
        let roles = chunk.reduce(into: [String: Role]()) { $0[Self.id(of: $1)] = Role(of: $1) }
        let deletionRows = deletions?.names.compactMap { name in deletions?.metadata[name] } ?? []
        let walked = chunkWalk
        let (prepared, notesEdits) = try await onStore { store, _ in
            var baseEntries: [String: MigrationBaseEntry] = [:]
            var notesEdits = Set<String>()
            if hasHistory {
                for planned in chunk where roles[Self.id(of: planned)] == .apply && !planned.home.isTeamZone {
                    let children = try MigrationLocalChildren.candidates(entity: planned.entity, logicalKey: planned.logicalKey, connection: store, registry: registry)
                    baseEntries[Self.id(of: planned)] = MigrationBaseEntry(changeTag: planned.cloud.changeTag, records: children)
                }
                for held in deletionRows where !held.home.isTeamZone {
                    let children = try MigrationLocalChildren.candidates(entity: held.entity, logicalKey: held.logicalKey, connection: store, registry: registry)
                    let zone = held.home.ownerRecordName == nil ? held.home.zoneName : "\(held.home.zoneName)@\(held.home.ownerRecordName ?? "")"
                    baseEntries[MigrationBaseShards.entryKey(zone: zone, recordName: held.recordName)] = MigrationBaseEntry(records: children)
                }
            }
            for planned in chunk where roles[Self.id(of: planned)] != .other {
                if case .learningGoal(let payload)? = planned.decoded?.payload,
                   let notes = try MigrationBodies.notesOutcome(planned, payload: payload, store: store), notes.0 == .keepLocalAndRecover {
                    notesEdits.insert(payload.goal.id)
                }
            }
            let prepared = MigrationLateImport.prepare(walked, baseEntries: baseEntries, deleted: deletedNames, connection: store)
            return (prepared, notesEdits)
        }
        report.failed += prepared.failed

        // Each returned record's next snapshot entry from its mapping; a planned one is replaced by the
        // planner's own once it is decided.
        var inputs: [MigrationOldRecordInput] = []
        var planned: Set<String> = []
        for input in prepared.inputs {
            let id = input.old.id
            if input.old.isDeleted {
                inputs.append(input)
                continue
            }
            switch roles[id] ?? .other {
            case .apply:
                inputs.append(input)
                planned.insert(id)
            case .bodyOnly:
                if let bodyOnly = Self.bodyOnly(input) { inputs.append(bodyOnly) }
                if let mapping = input.old.mapping { outcome.snapshot[id] = MigrationBaseEntry(mapping: mapping, changeTag: input.old.changeTag) }
            case .other:
                if let mapping = input.old.mapping { outcome.snapshot[id] = MigrationBaseEntry(mapping: mapping, changeTag: input.old.changeTag) }
            }
        }
        for id in prepared.failed { outcome.snapshot[id] = MigrationBaseEntry() }
        for planning in chunk {
            switch roles[Self.id(of: planning)] ?? .other {
            case .apply: report.applied += 1
            case .bodyOnly: report.keptLocal += 1
            case .other: if planning.decision == .skipDeletedLocally { report.skippedDeletedLocally += 1 } else { report.unchanged += 1 }
            }
        }
        guard !inputs.isEmpty else { return outcome }

        // 2. The world, and the plan.
        let keys = MigrationImportStore.keys(for: inputs)
        let listed = try await ledger.listed(keys)
        let probe = DeferredBodyProbe(notesEdits: notesEdits)
        let (world, waitingSince, newWorldSince) = try await onStore { store, state in
            let world = try MigrationImportStore.snapshot(
                keys: keys, listed: listed, probe: probe.over(store), connection: state.connection, registry: registry, ownRows: true
            )
            let since = try MigrationImportState.waitingSince(state.connection, pass: .refresh)
            let seeded = try state.replica.personalRoot()?.envelope.fields["seed"]?.objectValue?["startedAt"]?.int64Value
            return (world, since, seeded.map(SyncTime.date))
        }
        var plan = MigrationImportPlanner.plan(
            inputs, world: world,
            options: .init(now: now, newWorldSince: newWorldSince, waitingSince: waitingSince, reach: hasBase ? .absentOnly : .everything, ownRows: true)
        )
        for old in plan.olds where planned.contains(old.oldRecord) {
            if let next = old.nextEntry { outcome.snapshot[old.oldRecord] = next }
        }

        // 3. Bytes before pointers, then the patches.
        try await MigrationLateImport.uploadBodies(&plan, records: prepared.records, uploader: uploader)
        let (applied, queued) = try await onStore { store, state in
            let applied = try MigrationImportStore.apply(plan, passKey: passKey, state: state, now: now, registry: registry, ownRows: true)
            try MigrationImportState.appendKept(plan.kept, state.connection)
            try MigrationImportState.appendNotApplied(plan.notApplied, state.connection)
            try MigrationImportState.updateWaiting(plan, now: now, state.connection, pass: .refresh)
            if !prepared.failed.isEmpty {
                var since = try MigrationImportState.waitingSince(state.connection, pass: .refresh)
                for id in prepared.failed where since[id] == nil { since[id] = now }
                try MigrationImportState.saveWaitingSince(since, state.connection, pass: .refresh)
            }
            var assets = prepared
            assets.assetRecords = assets.assetRecords.filter { planned.contains(MigrationBaseShards.entryKey(zone: OldContainerZoneKey.snapshotZone(database: $0.zone.database, zoneID: $0.zone.zoneID), recordName: $0.record.id.recordName)) }
            assets.mobileImports = assets.mobileImports.filter { planned.contains($0.oldRecord) }
            MigrationLateImport.queueAssets(assets, connection: state.connection)
            return (applied, assets.assetRecords.count)
        }
        report.writes += plan.writes.count
        report.creates += applied.created.count
        report.removals += plan.removals
        report.kept += plan.kept.count
        report.skipped += plan.skipped.count
        report.notApplied += plan.notApplied.count
        report.waiting += plan.olds.filter(\.waiting).count
        report.queuedAssets += queued
        outcome.placed = applied.unplaced == 0
        for line in plan.skipped { Self.logger.notice("Skipped \(line.type, privacy: .public) \(line.reason.rawValue, privacy: .public)") }
        return outcome
    }

    // MARK: What each returned record does

    private enum Role {
        /// The old world's change is applied.
        case apply
        /// This Mac's local change wins the record, but a Doc's or notes' body is still decided by the body
        /// rule (R7-3).
        case bodyOnly
        case other

        init(of planned: MigrationPlannedRecord) {
            switch planned.decision {
            case .apply:
                self = .apply
            case .keepLocal:
                self = planned.entity == .artifact || planned.entity == .learningGoal ? .bodyOnly : .other
            case .unchanged, .skipDeletedLocally:
                self = .other
            }
        }
    }

    private static func id(of planned: MigrationPlannedRecord) -> String {
        MigrationBaseShards.entryKey(zone: planned.snapshotZone, recordName: planned.recordName)
    }

    /// The old record, planned for its bodies alone: every field but `body` is given to a creation (a Recovered
    /// Doc copies the title and the notebook) and never patched, and nothing is removed.
    private static func bodyOnly(_ input: MigrationOldRecordInput) -> MigrationOldRecordInput? {
        guard var mapping = input.old.mapping else { return nil }
        mapping.records = mapping.records.filter { $0.type == .artifact && $0.fields["body"] != nil }.map { record in
            var record = record
            record.createOnlyFields = Set(record.fields.keys).subtracting(["body"])
            return record
        }
        guard !mapping.records.isEmpty else { return nil }
        var old = input.old
        old.mapping = mapping
        return MigrationOldRecordInput(old: old, base: nil)
    }

    // MARK: The store

    private func onStore<T>(_ body: @escaping (KnowledgeStore, PrivateSyncLocalState) throws -> T) async throws -> T {
        try await store.perform { state in
            guard let knowledge = state.connection as? KnowledgeStore else { throw Failure.noKnowledgeStore }
            return try body(knowledge, state)
        }
    }
}

// MARK: - The body-edit probe of a catch-up

/// A Doc's own edit is the store's test (`MigrationBodies.docOwnEdit`); a notebook's notes are decided by
/// the catch-up's own rule for notes, which compares with what this Mac last synced and not with the notes
/// base the walk is about to write (§13.6): the notebooks whose notes differ from the walk's and count as
/// this Mac's edit.
struct DeferredBodyProbe: Sendable {
    let notesEdits: Set<String>

    func over(_ store: KnowledgeStore) -> MigrationBodyEditProbe {
        Bound(store: StoreMigrationBodyEditProbe(store: store), notesEdits: notesEdits)
    }

    private struct Bound: MigrationBodyEditProbe {
        let store: StoreMigrationBodyEditProbe
        let notesEdits: Set<String>

        func docHoldsOwnEdit(artifactID: String) throws -> Bool { try store.docHoldsOwnEdit(artifactID: artifactID) }
        func notesHoldOwnEdit(notebookID: String) throws -> Bool { notesEdits.contains(notebookID) }
    }
}
