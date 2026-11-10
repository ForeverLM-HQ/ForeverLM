import CloudKit
import Foundation
import OSLog

// MARK: - Writing beside the engine

/// The records the maintenance Mac writes itself (docs/cloudkit-schema-design.md §3.5.1, §3.5.2, §4.2,
/// §5.7, D8): the lease on the personal root, its own Device record, a duplicate's redirect and the
/// twins of its Entries, an orphan's delete. Each is a plain compare-and-set save or delete beside the
/// engine, as `ZoneBootstrap` saves a root: the patch goes onto the version the replica holds, its
/// fields stamped now (or, for a copied value, with the stamp it was copied with), and the save names
/// that version's change tag. A save the server took is applied as an inbound record, so the local
/// rows and any pending local change meet it through the merge (§6.2); one that met another version
/// applies that version instead and lands nothing. Nothing here is sent through the outbox, so the
/// engine never holds a maintenance write, and a compare-and-set loss is decided by the server alone.
struct MaintenanceWriter {
    struct Write {
        let zone: BlobZone
        var patch: RecordPatch
        /// Stamps copied with their values from another record (an Entry's twin, §4.2), by path. Every
        /// other changed path takes a stamp minted now.
        var verbatim: [StampedPath: SyncStamp] = [:]
        /// Only onto a version the replica holds: a write that would otherwise create the record (a
        /// notebook cover's pointer, when the notebook was deleted meanwhile) sends nothing.
        var onlyIfHeld = false

        init(zone: BlobZone, patch: RecordPatch, verbatim: [StampedPath: SyncStamp] = [:], onlyIfHeld: Bool = false) {
            self.zone = zone
            self.patch = patch
            self.verbatim = verbatim
            self.onlyIfHeld = onlyIfHeld
        }
    }

    enum Outcome: Equatable, Sendable {
        case saved
        /// The server held another version: the replica took it, and nothing of the write landed.
        case lost
        /// Every value was the one held: nothing was sent.
        case unchanged
        case failed(CKError.Code)
    }

    enum WriterError: Error, Equatable {
        /// No stamp is minted before the device knows its server offset (§6.3).
        case noServerOffset
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MaintenanceService")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let moveMaps: MoveMapIndex
    let deviceID: String
    let clock: @Sendable () -> Date

    static func recordName(_ type: SyncRecordType, _ id: String, in zone: BlobZone) -> String {
        type == .zoneRoot ? SyncSchema.rootRecordName : RecordNaming.recordName(type: type, id: id, salt: zone.salt)
    }

    /// Saves each write; the outcomes come back in the writes' order.
    func save(_ writes: [Write]) async throws -> [Outcome] {
        let now = clock()
        let prepared = try await store.perform { state -> [CloudRecord?] in
            guard var stampClock = try state.replica.loadClock(), stampClock.serverOffset != nil else { throw WriterError.noServerOffset }
            let milliseconds = SyncTime.milliseconds(now)
            var records: [CloudRecord?] = []
            for write in writes {
                let name = Self.recordName(write.patch.type, write.patch.id, in: write.zone)
                let held = try state.replica.record(zoneKey: write.zone.zoneKey, recordName: name)
                if write.onlyIfHeld, held == nil {
                    records.append(nil)
                    continue
                }
                var envelope = held.flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
                    ?? SyncEnvelope.new(write.patch.type, id: write.patch.id, saltID: RecordNaming.saltID(write.zone.salt))
                let stamped = try envelope.apply(write.patch) { path, policy, seen in
                    if let copied = write.verbatim[path] { return copied }
                    guard let stamp = stampClock.mint(policy, eventTime: milliseconds, seen: seen, now: milliseconds) else { throw WriterError.noServerOffset }
                    return stamp
                }
                guard !stamped.isEmpty else {
                    records.append(nil)
                    continue
                }
                records.append(CloudRecord(
                    id: CloudRecordID(name, in: write.zone.zoneID), recordType: write.patch.type.rawValue,
                    encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())], systemFields: held?.systemFields
                ))
            }
            try state.replica.saveClock(stampClock, now: now)
            return records
        }

        var outcomes = prepared.map { $0 == nil ? Outcome.unchanged : Outcome.failed(.internalError) }
        let indexed = prepared.enumerated().compactMap { index, record in record.map { (index, $0) } }
        for database in CloudDatabaseScope.allCases {
            let batch = indexed.filter { writes[$0.0].zone.database == database }
            for start in stride(from: 0, to: batch.count, by: SyncSchema.Limits.batchMaxRecords) {
                let slice = Array(batch[start..<min(start + SyncSchema.Limits.batchMaxRecords, batch.count)])
                let sentAt = clock()
                let results = try await transport.modifyRecords(saving: slice.map(\.1), in: database)
                for (index, record) in slice {
                    outcomes[index] = try await settle(results.saved[record.id], of: writes[index], sentAt: sentAt)
                }
            }
        }
        return outcomes
    }

    private func settle(_ result: Result<CloudRecord, CloudError>?, of write: Write, sentAt: Date) async throws -> Outcome {
        switch result {
        case .success(let saved)?:
            try await absorb(saved, in: write.zone, wireID: write.patch.id, seenAt: sentAt)
            let deviceID = deviceID
            if let serverTime = saved.modificationDate {
                try await store.perform { try $0.replica.recordServerTime(serverTime, sentAt: sentAt, deviceID: deviceID) }
            }
            return .saved
        case .failure(let error)? where error.code == .serverRecordChanged:
            if let server = error.serverRecord { try await absorb(server, in: write.zone, wireID: write.patch.id, seenAt: nil) }
            return .lost
        case .failure(let error)?:
            Self.logger.error("A maintenance write of \(write.patch.type.rawValue, privacy: .public) failed: \(error.description, privacy: .public)")
            return error.code == .unknownItem ? .lost : .failed(error.code)
        case nil:
            return .failed(.internalError)
        }
    }

    /// A record the server holds now, applied as an inbound one (the root straight into the replica,
    /// as the engine applies a root).
    func absorb(_ record: CloudRecord, in zone: BlobZone, wireID: String, seenAt: Date?) async throws {
        let now = clock()
        let moveMaps = moveMaps
        try await store.perform { state in
            if record.recordType == SyncRecordType.zoneRoot.rawValue {
                try state.replica.upsertRecord(ReplicaRecord(record, zoneKey: zone.zoneKey, wireID: wireID,
                                                             seenPass: seenAt?.timeIntervalSinceReferenceDate))
                return
            }
            try state.replica.apply { _ in
                _ = try InboundApply(state: state, now: now, passStart: seenAt, moveMaps: moveMaps).absorb(record, zoneKey: zone.zoneKey)
            }
        }
    }

    /// Deletes records by name and applies each acknowledged delete as an inbound one. Returns the
    /// names the server no longer holds.
    func delete(_ records: [ReplicaRecord], in zone: BlobZone) async throws -> Set<String> {
        var gone = Set<String>()
        for start in stride(from: 0, to: records.count, by: SyncSchema.Limits.batchMaxRecords) {
            let slice = Array(records[start..<min(start + SyncSchema.Limits.batchMaxRecords, records.count)])
            let ids = slice.map { CloudRecordID($0.recordName, in: zone.zoneID) }
            let results = try await transport.modifyRecords(deleting: ids, in: zone.database)
            let deleted = slice.filter { record in
                switch results.deleted[CloudRecordID(record.recordName, in: zone.zoneID)] {
                case .success?: return true
                case .failure(let error)?: return error.code == .unknownItem
                case nil: return false
                }
            }
            let now = clock()
            let moveMaps = moveMaps
            try await store.perform { state in
                try state.replica.apply { _ in
                    let inbound = try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps)
                    for record in deleted {
                        try inbound.absorbDeletion(CloudRecordDeletion(id: CloudRecordID(record.recordName, in: zone.zoneID), recordType: record.recordType),
                                                   zoneKey: zone.zoneKey)
                    }
                }
            }
            gone.formUnion(deleted.map(\.recordName))
        }
        return gone
    }

    /// Reads the personal root as the server holds it now into the replica; its envelope, nil when
    /// the server holds none.
    func refreshRoot(in zone: BlobZone) async throws -> SyncEnvelope? {
        let id = CloudRecordID(SyncSchema.rootRecordName, in: zone.zoneID)
        guard case .success(let root) = try await transport.record(id, in: zone.database, desiredKeys: [CloudRecord.payloadKey]),
              let payload = root.payload, let envelope = try? SyncEnvelope(storedPayload: payload)
        else { return nil }
        try await absorb(root, in: zone, wireID: SyncSchema.rootRecordName, seenAt: nil)
        return envelope
    }
}

// MARK: - The lease

/// `ZoneRoot.maintenanceLease` (§3.5.1): which Mac runs GC, the orphan janitor, duplicate resolution,
/// `moveMaps` folding, the cover backfill and the practices engine, and imports late once the seed is
/// complete (§13.6). A 24-hour lease, S: the first acknowledged save stands. Its holder renews it
/// whenever less than half of it is left, so a Mac that is up renews it about twice a day. Only a Mac
/// that holds the library takes it: the seeder with its claim (`ZoneBootstrap`'s takeover); any
/// other Mac only after the root shows `seed.metadataCompleteAt` and its own first complete fetch of
/// `Library` and `Catalog`; and an expired lease only by a compare-and-set save against the root as
/// the server holds it now.
enum MaintenanceLease {
    static let duration = ZoneBootstrap.maintenanceLease
    static let renewWithin = ZoneBootstrap.maintenanceLease / 2

    struct Holder: Equatable, Sendable {
        let device: String
        let leaseUntil: Int64
    }

    /// Why a Mac may or may not take the lease.
    enum Standing: Equatable, Sendable {
        /// A Mac that holds no library (a `fresh` one, or one waiting for "This Mac holds my library").
        case noLibrary
        /// The root does not show `seed.metadataCompleteAt` yet.
        case seedMetadataPending
        /// This Mac has not fetched `Library` and `Catalog` to the end once.
        case firstFetchPending
        case eligible
    }

    enum Decision: Equatable, Sendable {
        /// This Mac holds a lease with time left.
        case hold
        /// This Mac holds it and renews it now.
        case renew
        /// Nobody holds a live lease and this Mac may take it.
        case take
        /// Another Mac holds it, or this Mac may not take it.
        case wait
    }

    static func holder(in root: SyncEnvelope) -> Holder? {
        guard let lease = root.fields["maintenanceLease"]?.objectValue, let device = lease["device"]?.stringValue,
              let until = lease["leaseUntil"]?.int64Value
        else { return nil }
        return Holder(device: device, leaseUntil: until)
    }

    static func value(device: String, at date: Date) -> SyncJSON {
        .object(["device": .string(device), "leaseUntil": SyncJSON(SyncTime.milliseconds(date.addingTimeInterval(duration)))])
    }

    static func standing(holdsLibrary: Bool, root: SyncEnvelope, library: ReplicaZone?, catalog: ReplicaZone?) -> Standing {
        guard holdsLibrary else { return .noLibrary }
        guard root.fields["seed"]?.objectValue?["metadataCompleteAt"]?.int64Value != nil else { return .seedMetadataPending }
        guard library?.lastCompletePassAt != nil, catalog?.lastCompletePassAt != nil else { return .firstFetchPending }
        return .eligible
    }

    static func decide(holder: Holder?, me: String, standing: Standing, now: Int64) -> Decision {
        if let holder, holder.device == me {
            // The seeder holds it from its claim, before the metadata is in; only a Mac that no longer
            // holds the library lets its own lease run out.
            guard standing != .noLibrary else { return .wait }
            return holder.leaseUntil - now < Int64(renewWithin * 1_000) ? .renew : .hold
        }
        if let holder, holder.leaseUntil > now { return .wait }
        return standing == .eligible ? .take : .wait
    }
}

// MARK: - The Device record

/// What this Mac says about itself in its `Device` record (§3.5.2).
struct MaintenanceDeviceDescription: Sendable, Equatable {
    var platform = "mac"
    var appVersion: String
    var appBuild: String
    var displayName: String?
}

/// The learner's calendar days (§3.2 rule 6), in the time zone of the moment of writing.
enum MaintenanceDays {
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func day(_ date: Date, minus days: Int, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return day(calendar.date(byAdding: .day, value: -days, to: date) ?? date, timeZone: timeZone)
    }
}

enum DeviceRecord {
    static func id(_ deviceID: String) -> String { "dev:\(deviceID)" }
    /// `lastSeenDay` moves on a build change and at most once a week, never on open (§3.5.2).
    static let lastSeenInterval = 7

    /// What this Mac's Device record needs written, nil when it says everything already. `roles`
    /// names only the roles this Mac decides here (`maintenance`); others it holds stay as they are.
    static func patch(held: SyncEnvelope?, deviceID: String, description: MaintenanceDeviceDescription,
                      roles: [String: Bool], now: Date, timeZone: TimeZone = .current, forceLastSeen: Bool = false) -> RecordPatch? {
        var patch = RecordPatch(.device, id: id(deviceID))
        let today = MaintenanceDays.day(now, timeZone: timeZone)
        let milliseconds = SyncJSON(SyncTime.milliseconds(now))
        guard let held else {
            patch.changes = [
                "deviceID": .value(.string(deviceID)), "platform": .value(.string(description.platform)),
                "appVersion": .value(.string(description.appVersion)), "appBuild": .value(.string(description.appBuild)),
                "schemaRevision": .value(SyncJSON(SyncSchema.schemaRevision)), "firstSeenAt": .value(milliseconds),
                "lastSeenDay": .value(.string(today)), "editedAt": .value(milliseconds),
                "roles": .elements(roles.mapValues(SyncJSON.bool)),
            ]
            if let name = description.displayName { patch.changes["displayName"] = .value(.string(name)) }
            return patch
        }
        // A record the connector-health projection made first holds no first sighting yet.
        if held.fields["firstSeenAt"] == nil { patch.changes["firstSeenAt"] = .value(milliseconds) }
        var buildChanged = false
        for (field, value) in [("appVersion", description.appVersion), ("appBuild", description.appBuild)] where held.fields[field]?.stringValue != value {
            patch.changes[field] = .value(.string(value))
            buildChanged = true
        }
        if held.fields["schemaRevision"]?.intValue != SyncSchema.schemaRevision {
            patch.changes["schemaRevision"] = .value(SyncJSON(SyncSchema.schemaRevision))
            buildChanged = true
        }
        if let name = description.displayName, held.fields["displayName"]?.stringValue != name {
            patch.changes["displayName"] = .value(.string(name))
        }
        let weekAgo = MaintenanceDays.day(now, minus: lastSeenInterval, timeZone: timeZone)
        let lastSeen = held.fields["lastSeenDay"]?.stringValue ?? ""
        if lastSeen != today, buildChanged || forceLastSeen || lastSeen <= weekAgo {
            patch.changes["lastSeenDay"] = .value(.string(today))
        }
        let heldRoles = held.fields["roles"]?.objectValue ?? [:]
        let changedRoles = roles.filter { (heldRoles[$0.key]?.boolValue ?? false) != $0.value }
        if !changedRoles.isEmpty { patch.changes["roles"] = .elements(changedRoles.mapValues(SyncJSON.bool)) }
        guard !patch.changes.isEmpty else { return nil }
        patch.changes["editedAt"] = .value(milliseconds)
        return patch
    }
}

// MARK: - Gates

/// §12.5: a change that alters meaning for older clients may be switched on only when every Device
/// seen in the last 30 days reports `schemaRevision` at least N, or after `minClientRevision` was
/// raised to N.
enum SchemaRevisionGate {
    static let activeDays = 30

    static func allows(_ revision: Int, devices: [SyncEnvelope], minClientRevision: Int?, now: Date, timeZone: TimeZone = .current) -> Bool {
        if let minClientRevision, minClientRevision >= revision { return true }
        let since = MaintenanceDays.day(now, minus: activeDays, timeZone: timeZone)
        return devices.allSatisfy { device in
            guard let day = device.fields["lastSeenDay"]?.stringValue, day >= since else { return true }
            return (device.fields["schemaRevision"]?.intValue ?? 0) >= revision
        }
    }

    /// The same over the replica: the personal library's Device records and its root.
    static func allows(_ revision: Int, in state: PrivateSyncLocalState, now: Date, timeZone: TimeZone = .current) throws -> Bool {
        var devices: [SyncEnvelope] = []
        try state.connection.query(
            "SELECT payload FROM ck_records WHERE zone_key = ? AND record_type = ?",
            [.text(PrivateSyncZones.libraryKey), .text(SyncRecordType.device.rawValue)]
        ) { row in
            if let payload = row.blob(0), let envelope = try? SyncEnvelope(storedPayload: payload) { devices.append(envelope) }
        }
        let minimum = try state.replica.personalRoot()?.envelope.fields["minClientRevision"]?.intValue
        return allows(revision, devices: devices, minClientRevision: minimum, now: now, timeZone: timeZone)
    }
}

/// §3.2 rule 4: removal markers older than 90 days are dropped by the next writer, so a device whose
/// own `Device.lastSeenDay` is older than that discards its engine state and change tokens, and
/// re-fetches every zone before it sends (the engine holds sends while the marker is set); once the
/// re-fetch reached the end it drops, and logs, the pending element edits whose element the server no
/// longer lists, writes its `lastSeenDay` and sends again.
enum CompactionGate {
    static let horizonDays = SyncSchema.Limits.removalMarkerCompactionDays

    static func isDue(lastSeenDay: String?, now: Date, timeZone: TimeZone = .current) -> Bool {
        guard let lastSeenDay else { return false }
        return lastSeenDay < MaintenanceDays.day(now, minus: horizonDays, timeZone: timeZone)
    }

    /// Before the engine starts. Returns whether the gate tripped (or had tripped and still holds).
    @discardableResult
    static func check(in state: PrivateSyncLocalState, deviceID: String, now: Date, timeZone: TimeZone = .current) throws -> Bool {
        let replica = state.replica
        if try replica.engineState(ReplicaStore.EngineScope.refetchBeforeSend) != nil { return true }
        let own = try replica.record(zoneKey: PrivateSyncZones.libraryKey, recordType: SyncRecordType.device.rawValue, wireID: DeviceRecord.id(deviceID))
        let lastSeen = own.flatMap { try? SyncEnvelope(storedPayload: $0.payload) }?.fields["lastSeenDay"]?.stringValue
        guard isDue(lastSeenDay: lastSeen, now: now, timeZone: timeZone) else { return false }
        try state.connection.execute("UPDATE ck_zones SET change_token = NULL")
        try replica.setEngineState(ReplicaStore.EngineScope.privateEngine, nil, now: now)
        try replica.setEngineState(ReplicaStore.EngineScope.refetchBeforeSend, Data("\(now.timeIntervalSinceReferenceDate)".utf8), now: now)
        return true
    }

    static func isHolding(in state: PrivateSyncLocalState) throws -> Bool {
        try state.replica.engineState(ReplicaStore.EngineScope.refetchBeforeSend) != nil
    }

    /// After the re-fetch reached the end. Returns how many edits it dropped.
    static func finish(in state: PrivateSyncLocalState, now: Date) throws -> Int {
        let horizon = now.addingTimeInterval(-Double(horizonDays) * MemoryTutorScheduler.secondsPerDay)
        let dropped = try state.dropStaleElementEdits(before: horizon, now: now)
        try state.replica.setEngineState(ReplicaStore.EngineScope.refetchBeforeSend, nil, now: now)
        return dropped
    }
}

// MARK: - The service

/// The maintenance Mac (docs/cloudkit-schema-design.md §3.5.1, §5.7, §5.8, §4.2, §12.5, §3.2 rule 4),
/// generation 2 only. After each sync round it writes this Mac's Device record when a build change or
/// a week asks for it, keeps or takes the maintenance lease, and, while it holds the lease, folds the
/// root's `moveMaps` past 32 entries, resolves duplicate sources, runs the orphan janitor and collects
/// unreachable satellites, the last three only after a round that fetched every zone to the end. Before
/// the engine starts it runs the compaction gate. Nothing runs on the main actor; the work runs where
/// the coordinator's round runs, at `.utility` when the app schedules it.
actor MaintenanceService: SyncMaintenanceHooks {
    /// How often the janitor, duplicate resolution and GC run on the lease holder.
    static let dailyInterval: TimeInterval = MemoryTutorScheduler.secondsPerDay

    struct Report: Equatable, Sendable {
        var lease: MaintenanceLease.Decision?
        var holdsLease = false
        var deviceWritten = false
        var compactionDropped: Int?
        var folded = false
        var resolvedDuplicates = 0
        var janitorDeleted = 0
        var satellitesDeleted = 0
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MaintenanceService")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let blobs: BlobStore
    let moveMaps: MoveMapIndex
    let deviceID: String
    let description: MaintenanceDeviceDescription
    let timeZone: TimeZone
    private let holdsLibrary: @Sendable () async -> Bool
    /// Fetches every change-fed zone (the engine's and every space) until the server reports no more;
    /// true when every one reached its end (§5.8 step 5).
    private let fetchToEnd: @Sendable () async -> Bool
    private let clock: @Sendable () -> Date
    private var onChange: (@Sendable () async -> Void)?
    private var running = false
    /// The notebook cover service: woken after each round, and told whether this Mac holds the lease,
    /// which is what lets its backfill run (§5.9).
    private var covers: NotebookCoverService?

    init(transport: CloudTransport, store: PrivateSyncLocalStore, blobs: BlobStore, moveMaps: MoveMapIndex, deviceID: String,
         description: MaintenanceDeviceDescription, timeZone: TimeZone = .current,
         holdsLibrary: @escaping @Sendable () async -> Bool, fetchToEnd: @escaping @Sendable () async -> Bool,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.store = store
        self.blobs = blobs
        self.moveMaps = moveMaps
        self.deviceID = deviceID
        self.description = description
        self.timeZone = timeZone
        self.holdsLibrary = holdsLibrary
        self.fetchToEnd = fetchToEnd
        self.clock = clock
    }

    var writer: MaintenanceWriter {
        MaintenanceWriter(transport: transport, store: store, moveMaps: moveMaps, deviceID: deviceID, clock: clock)
    }

    /// Wires the service into the coordinator's rounds.
    func attach(to coordinator: SyncCoordinator) async {
        onChange = { Task { await coordinator.sendSoon() } }
        await coordinator.setMaintenance(self)
    }

    // MARK: SyncMaintenanceHooks

    func beforeEngineStarts() async {
        let now = clock()
        let deviceID = deviceID
        let timeZone = timeZone
        do {
            if try await store.perform({ try CompactionGate.check(in: $0, deviceID: deviceID, now: now, timeZone: timeZone) }) {
                Self.logger.info("Away longer than the compaction horizon: every zone is fetched again before anything is sent")
            }
        } catch {
            Self.logger.error("The compaction gate could not run: \(String(describing: error), privacy: .public)")
        }
    }

    /// Wires the notebook cover service in.
    func attachCovers(_ service: NotebookCoverService) {
        covers = service
    }

    func afterRound(caughtUp: Bool) async {
        // The covers a notebook is waiting for (its record sent, its name set) are drawn on any Mac.
        covers?.wake()
        _ = await tick(caughtUp: caughtUp)
    }

    // MARK: One pass

    /// One pass after a round. Passes never overlap; one asked for while another runs is skipped.
    @discardableResult
    func tick(caughtUp: Bool) async -> Report {
        guard !running else { return Report() }
        running = true
        defer { running = false }
        var report = Report()
        do {
            guard let library = try await zone(PrivateSyncZones.libraryKey) else { return report }
            if try await store.perform({ try CompactionGate.isHolding(in: $0) }) {
                guard caughtUp else { return report }
                let now = clock()
                report.compactionDropped = try await store.perform { try CompactionGate.finish(in: $0, now: now) }
                report.deviceWritten = try await writeDevice(in: library, holdsLease: nil, forceLastSeen: true)
                await onChange?()
            }
            let (decision, holds) = try await keepLease(in: library)
            report.lease = decision
            report.holdsLease = holds
            if try await writeDevice(in: library, holdsLease: holds) { report.deviceWritten = true }
            guard holds else {
                await covers?.maintenanceRound(holdsLease: false)
                return report
            }
            report.folded = try await foldMoveMaps(in: library)
            // A round that did not take every zone to the end starts nothing that lists the replica (F16).
            guard caughtUp else { return report }
            // The cover backfill runs on its own task, so it never holds up the rest of the round (§5.9).
            await covers?.maintenanceRound(holdsLease: true)
            if try await isDue("maintenance.duplicates") {
                report.resolvedDuplicates = try await resolveDuplicates()
                try await markRun("maintenance.duplicates")
            }
            if try await isDue("maintenance.janitor") {
                report.janitorDeleted = try await runJanitor()
                try await markRun("maintenance.janitor")
            }
            for zoneKey in try await collectedZones() {
                guard try await isDue("maintenance.gc.\(zoneKey)") else { continue }
                report.satellitesDeleted += try await collectSatellites(in: zoneKey).deleted
                try await markRun("maintenance.gc.\(zoneKey)")
            }
        } catch {
            Self.logger.error("A maintenance pass stopped: \(String(describing: error), privacy: .public)")
        }
        return report
    }

    func zone(_ zoneKey: String) async throws -> BlobZone? {
        try await store.perform { try BlobZone.resolve(zoneKey: zoneKey, in: $0) }
    }

    func clockNow() -> Date { clock() }

    /// Every change-fed zone fetched to the end, as the janitor and GC need before they delete.
    func fetchEverything() async -> Bool { await fetchToEnd() }

    private func isDue(_ scope: String) async throws -> Bool {
        let now = clock()
        return try await store.perform { state in
            guard let data = try state.replica.engineState(scope), let text = String(data: data, encoding: .utf8), let last = Double(text) else { return true }
            return now.timeIntervalSinceReferenceDate - last >= Self.dailyInterval
        }
    }

    private func markRun(_ scope: String) async throws {
        let now = clock()
        try await store.perform { try $0.replica.setEngineState(scope, Data("\(now.timeIntervalSinceReferenceDate)".utf8), now: now) }
    }

    // MARK: The lease

    /// Keeps, renews or takes the lease. Returns the decision and whether this Mac holds a live lease
    /// the server acknowledged.
    func keepLease(in library: BlobZone) async throws -> (MaintenanceLease.Decision, Bool) {
        let holdsLibrary = await holdsLibrary()
        let deviceID = deviceID
        let decide = { (root: SyncEnvelope, now: Date) async throws -> MaintenanceLease.Decision in
            let standing = try await self.store.perform { state in
                MaintenanceLease.standing(holdsLibrary: holdsLibrary, root: root,
                                          library: try state.replica.zone(key: PrivateSyncZones.libraryKey),
                                          catalog: try state.replica.zone(key: PrivateSyncZones.key(PrivateSyncZones.catalog)))
            }
            return MaintenanceLease.decide(holder: MaintenanceLease.holder(in: root), me: deviceID, standing: standing, now: SyncTime.milliseconds(now))
        }
        guard let held = try await store.perform({ try $0.replica.personalRoot()?.envelope }) else { return (.wait, false) }
        let now = clock()
        var decision = try await decide(held, now)
        switch decision {
        case .hold:
            return (.hold, true)
        case .wait:
            return (.wait, false)
        case .renew, .take:
            // Decided again on the root as the server holds it now, and saved against that version.
            guard let current = try await writer.refreshRoot(in: library) else { return (.wait, false) }
            decision = try await decide(current, now)
            guard decision == .renew || decision == .take else { return (decision, decision == .hold) }
            var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
            patch.changes["maintenanceLease"] = .value(MaintenanceLease.value(device: deviceID, at: now))
            let outcome = try await writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first
            if outcome == .saved {
                Self.logger.info("\(decision == .take ? "Took" : "Renewed", privacy: .public) the maintenance lease")
                return (decision, true)
            }
            return (.wait, false)
        }
    }

    // MARK: The Device record

    /// Writes this Mac's Device record when it says something new. `holdsLease` nil leaves the
    /// `maintenance` role as it is.
    @discardableResult
    func writeDevice(in library: BlobZone, holdsLease: Bool?, forceLastSeen: Bool = false) async throws -> Bool {
        let id = DeviceRecord.id(deviceID)
        let held = try await store.perform { state in
            try state.replica.record(zoneKey: library.zoneKey, recordType: SyncRecordType.device.rawValue, wireID: id)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
        }
        let roles = holdsLease.map { ["maintenance": $0] } ?? [:]
        guard let patch = DeviceRecord.patch(held: held, deviceID: deviceID, description: description, roles: roles, now: clock(),
                                             timeZone: timeZone, forceLastSeen: forceLastSeen)
        else { return false }
        return try await writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first == .saved
    }
}
