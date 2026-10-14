import Foundation
import OSLog

/// Why the phone did not make a change under generation 2, in words for the learner.
enum MobileRecordWriterError: LocalizedError, Equatable {
    /// The phone has never had a timestamped answer from the new container, so it cannot stamp (§6.3).
    case noServerTime
    /// The zone the record belongs in is not held yet (its root has not arrived).
    case zoneNotHeld
    case notebookGone
    case sourceGone
    case chatGone
    case emptyTitle
    /// A write `SpaceWriteGuard` or the settings catalog refuses, with why.
    case refused(String)
    case unsupportedFile
    case tooLarge
    /// A link only a Mac can mint an id for (an internationalized host): its Job waits for the Mac.
    case queuedForMac

    var errorDescription: String? {
        switch self {
        case .noServerTime: return "This iPhone has not reached the new iCloud store yet. Try again once it has synced."
        case .zoneNotHeld: return "This library has not finished arriving on this iPhone yet."
        case .notebookGone: return "This notebook is no longer available."
        case .sourceGone: return "This source is no longer available."
        case .chatGone: return "This chat is not in iCloud yet."
        case .emptyTitle: return "Enter a name."
        case .refused(let reason): return reason
        case .unsupportedFile: return "Only a PDF can be added from this iPhone."
        case .tooLarge: return "This request is too large to hand to your Mac."
        case .queuedForMac: return "Your Mac adds this link the next time ForeverLM runs there."
        }
    }
}

/// The phone's write path under generation 2 (docs/cloudkit-schema-design.md §6.5, §6.6, §14.1 iOS/Sync):
/// every change is a `RecordPatch` patched onto the record as the phone holds it, stamped by the
/// replica's `StampClock` at the moment of the write, and folded into the record's `ck_patches` row,
/// which the index shows at once and the private engine or SpaceSync sends (`MobilePatchOutbox`). A
/// value equal to the one held stamps nothing (§3.2 rule 9). A write into a space is checked by
/// `SpaceWriteGuard` before it is queued, so a refused record is never queued (§9.2).
///
/// Every phone write goes through it; `current()` answers nil when the phone's session cannot start.
final class MobileRecordWriter: @unchecked Sendable {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileRecordWriter")

    let replica: MobileReplica
    let deviceID: String
    /// Satellites the phone uploads before it points at them (a captured PDF, D47); nil in suites that
    /// upload none.
    let blobs: BlobStore?
    let clock: @Sendable () -> Date
    let newID: @Sendable () -> String
    /// Hears that a write was queued, with how long its records wait before they are due (§6.6 step 4).
    private let lock = NSLock()
    private var onWrite: (@Sendable (TimeInterval) -> Void)?

    init(replica: MobileReplica, deviceID: String, blobs: BlobStore? = nil, clock: @escaping @Sendable () -> Date = { Date() },
         newID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.replica = replica
        self.deviceID = deviceID
        self.blobs = blobs
        self.clock = clock
        self.newID = newID
    }

    func whenWritten(_ handler: @escaping @Sendable (TimeInterval) -> Void) {
        lock.withLock { onWrite = handler }
    }

    /// Tells the session that records wait to be sent, the newest of them due in `due` seconds.
    func notifyWritten(due: TimeInterval) {
        lock.withLock { onWrite }?(due)
    }

    /// The writer of the session this process runs; nil when the session cannot start.
    static func current() async -> MobileRecordWriter? {
        await MobileSyncSession.startIfEnabled()?.writer
    }

    /// `current()`, or the refusal a screen shows when the session could not start.
    static func required() async throws -> MobileRecordWriter {
        guard let writer = await current() else { throw MobileRecordWriterError.zoneNotHeld }
        return writer
    }

    /// Runs `body` as one transaction where the replica's connection belongs: every patch it queues and
    /// the clock it stamps with are committed together, or none is.
    func transaction<T>(_ body: @escaping (inout MobileWrite) throws -> T) async throws -> T {
        let now = clock()
        let deviceID = deviceID
        let newID = newID
        let (result, due, shown) = try await replica.read { replica -> (T, TimeInterval?, Bool) in
            try replica.connection.executeScript("BEGIN IMMEDIATE")
            do {
                var write = try MobileWrite(replica: replica, deviceID: deviceID, now: now, newID: newID)
                let result = try body(&write)
                try write.saveClock()
                try replica.connection.executeScript("COMMIT")
                return (result, write.due, write.changesScreens)
            } catch {
                try? replica.connection.executeScript("ROLLBACK")
                throw error
            }
        }
        if let due {
            lock.withLock { onWrite }?(due)
            // The screens' models read the library again only for a change they show (`MobileReplicaChange`):
            // a reading position, a day's activity and a sitting's answer are written every few seconds and
            // appear on no list.
            if shown { await MainActor.run { NotificationCenter.default.post(name: .mobileReplicaDidChange, object: replica) } }
        }
        return result
    }

    /// A read of what the phone holds, its pending patches laid over the replica.
    func read<T>(_ body: @escaping (MobileWrite) throws -> T) async throws -> T {
        let now = clock()
        let deviceID = deviceID
        let newID = newID
        return try await replica.read { replica in
            try body(try MobileWrite(replica: replica, deviceID: deviceID, now: now, newID: newID))
        }
    }
}

/// One transaction of the writer (or a read through it), on the replica's queue.
struct MobileWrite {
    let replica: MobileReplica
    let deviceID: String
    let now: Date
    let newID: () -> String
    private var clock: StampClock?
    private let clockAsLoaded: StampClock?
    /// How long the records queued wait before they are due; nil when nothing was queued.
    private(set) var due: TimeInterval?
    /// Whether something the screens' models show was queued (`MobileReplicaChange`).
    private(set) var changesScreens = false

    init(replica: MobileReplica, deviceID: String, now: Date, newID: @escaping () -> String) throws {
        self.replica = replica
        self.deviceID = deviceID
        self.now = now
        self.newID = newID
        clock = try replica.replica.loadClock()
        clockAsLoaded = clock
    }

    var connection: SQLiteConnection { replica.connection }
    var store: ReplicaStore { replica.replica }
    var milliseconds: Int64 { SyncTime.milliseconds(now) }

    // MARK: - Reading

    /// A record as the phone holds it: the replica's version with the pending patch laid over it; nil
    /// when the phone holds neither, or deletes it.
    func held(_ type: SyncRecordType, _ id: String, in zoneKey: String) throws -> SyncEnvelope? {
        guard try !isDeleting(type, id, in: zoneKey) else { return nil }
        return try MobileProjection.held(type, id, zoneKey: zoneKey, in: replica)
    }

    /// The zone keys that hold a record of `type` and `id`, acknowledged or still a patch.
    func zoneKeys(holding type: SyncRecordType, _ id: String) throws -> [String] {
        var keys: [String] = []
        try connection.query("""
            SELECT zone_key FROM ck_records WHERE record_type = ? AND wire_id = ?
            UNION SELECT zone_key FROM ck_patches WHERE record_type = ? AND wire_id = ?
            ORDER BY zone_key
        """, [.text(type.rawValue), .text(id), .text(type.rawValue), .text(id)]) { keys.append($0.text(0) ?? "") }
        return try keys.filter { try !isDeleting(type, id, in: $0) }
    }

    func isDeleting(_ type: SyncRecordType, _ id: String, in zoneKey: String) throws -> Bool {
        try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_type = ? AND wire_id = ?)",
            [.text(zoneKey), .text(type.rawValue), .text(id)]
        ) == 1
    }

    /// The zone key the phone holds a zone under: the private zones by name, a space from its row
    /// (one this account owns before one it joined).
    func zoneKey(of zone: SyncZoneName) throws -> String? {
        try ReplicaPlacement(connection: connection).zoneKey(of: zone)
    }

    /// Whether the phone has finished a complete pass of `Catalog` in the new container (§4.2): before
    /// it, a capture is a Job only, since a lookup here could miss a source the account already holds.
    var catalogPassed: Bool {
        get throws { try store.zone(key: MobileProjection.catalogKey)?.lastCompletePassAt != nil }
    }

    /// This member as a space knows them (`createdBy`, `addedBy`, `author`): nil in the personal library.
    func person(in zoneKey: String) throws -> SyncPerson? {
        guard ProjectionZones.zone(ofKey: zoneKey)?.isSpace == true else { return nil }
        return SyncPerson(user: try accountUser() ?? "", name: "")
    }

    func accountUser() throws -> String? {
        try store.engineState(ReplicaStore.EngineScope.account).map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The participant writing into the space `zoneKey`, as `SpaceWriteGuard` judges them (§9.2).
    func spaceWriter(_ zoneKey: String) throws -> SpaceWriteGuard.Writer? {
        guard ProjectionZones.zone(ofKey: zoneKey)?.isSpace == true, let row = try store.zone(key: zoneKey) else { return nil }
        return SpaceWriteGuard.Writer(user: try accountUser() ?? "", permission: row.permission == CloudShare.Permission.readOnly.rawValue ? .readOnly : .readWrite,
                                      isOwner: row.database == .private)
    }

    // MARK: - Writing

    /// Queues `patch` for the record in `zoneKey`: patched onto what the phone holds, each changed path
    /// stamped now (a field in `provisional` under the provisional stamp, §5.4), folded into the
    /// record's pending patch and indexed. `editedAt` moves with it when the type keeps one (§3.5) and
    /// `edited` is set. A patch that changes nothing queues nothing.
    mutating func write(_ patch: RecordPatch, in zoneKey: String, provisional: Set<String> = [], edited: Bool = true) throws {
        guard let row = try store.zone(key: zoneKey), let saltID = row.saltID else { throw MobileRecordWriterError.zoneNotHeld }
        let current = try held(patch.type, patch.id, in: zoneKey)
        // A patch that changes nothing held queues nothing, `editedAt` included (§3.2 rule 9).
        var probe = current ?? SyncEnvelope.new(patch.type, id: patch.id, saltID: saltID)
        let deviceID = deviceID
        guard try !probe.apply(patch, stamp: { _, policy, _ in SourceSkeleton.provisionalStamp(policy, deviceID: deviceID) }).isEmpty else { return }
        var patch = patch
        if edited, patch.type.spec.field("editedAt") != nil, patch.changes["editedAt"] == nil {
            patch.changes["editedAt"] = .value(SyncJSON(milliseconds))
        }
        if let writer = try spaceWriter(zoneKey) {
            do {
                try SpaceWriteGuard.check(patch, onto: current, by: writer)
            } catch let refusal as SpaceWriteGuard.Refusal {
                throw MobileRecordWriterError.refused(refusal.description)
            }
        }
        var envelope = current ?? SyncEnvelope.new(patch.type, id: patch.id, saltID: saltID)
        var minting = clock
        let eventTime = milliseconds
        let stamped = try envelope.apply(patch) { path, policy, seen in
            if provisional.contains(path.field) { return SourceSkeleton.provisionalStamp(policy, deviceID: deviceID) }
            guard var clock = minting, let stamp = clock.mint(policy, eventTime: eventTime, seen: seen, now: eventTime) else {
                throw MobileRecordWriterError.noServerTime
            }
            minting = clock
            return stamp
        }
        guard !stamped.isEmpty else { return }
        clock = minting
        let waiting = try PendingPatch.load(zoneKey: zoneKey, type: patch.type.rawValue, wireID: patch.id, in: connection)
        var pending = waiting ?? PendingPatch(changes: [:], stamps: [:], zoneKey: zoneKey, type: patch.type.rawValue, wireID: patch.id)
        for path in stamped {
            if let element = path.element {
                var values = pending.changes[path.field]?.objectValue ?? [:]
                values[element] = envelope.fields[path.field]?.objectValue?[element] ?? .null
                pending.changes[path.field] = .object(values)
                var stamps: [String: SyncStamp] = if case .elements(let held)? = pending.stamps[path.field] { held } else { [:] }
                if case .elements(let written)? = envelope.stamps[path.field] { stamps[element] = written[element] }
                pending.stamps[path.field] = .elements(stamps)
            } else {
                pending.changes[path.field] = envelope.fields[path.field] ?? .null
                pending.stamps[path.field] = envelope.stamps[path.field]
            }
        }
        // A Sitting or an ActivityLog waiting to be sent keeps its first write's time, so it goes out at
        // most every 30 s (5 minutes) while the learner keeps answering (D44), never only once they stop.
        let keepsFirstWrite = waiting != nil && MobilePatchOutbox.keepsFirstWrite(patch.type)
        try MobilePatchOutbox.save(pending, dirtyAt: keepsFirstWrite ? nil : now, in: connection)
        try replica.reindex(zoneKey: zoneKey, type: patch.type, wireID: patch.id)
        queued(patch.type, changing: stamped.map(\.field))
    }

    /// Queues the deletion of a record: the replica's copy goes out as a delete once due, the pending
    /// patch goes now, and the index forgets the record at once. A record made here and not acknowledged
    /// yet is deleted by the name its save goes out under: that save may be on its way (sent, its
    /// acknowledgement not back), which the phone cannot tell, so the delete follows it, and a delete of
    /// one the server never had is acknowledged as done (`unknownItem`). In a space only the owner or the
    /// record's maker deletes a notebook, Doc, course or chat (§9.2).
    mutating func delete(_ type: SyncRecordType, _ id: String, in zoneKey: String) throws {
        let record = try store.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: id)
        if let writer = try spaceWriter(zoneKey) {
            let fields = try held(type, id, in: zoneKey)?.fields ?? [:]
            do {
                try SpaceWriteGuard.check(deleting: type.rawValue, fields: fields, by: writer)
            } catch let refusal as SpaceWriteGuard.Refusal {
                throw MobileRecordWriterError.refused(refusal.description)
            }
        }
        let patched = try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: id, in: connection) != nil
        try PendingPatch.delete(zoneKey: zoneKey, type: type.rawValue, wireID: id, in: connection)
        var recordName = record?.recordName
        if recordName == nil, patched { recordName = try madeRecordName(type, id, in: zoneKey) }
        if let recordName {
            try connection.execute("""
                INSERT INTO ck_pending_deletes (zone_key, record_name, record_type, wire_id, deleted_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(zone_key, record_name) DO UPDATE SET deleted_at = excluded.deleted_at
            """, [.text(zoneKey), .text(recordName), .text(type.rawValue), .text(id), .real(now.timeIntervalSinceReferenceDate)])
            queued(type, changing: [])
        }
        try replica.projectDeletion(zoneKey: zoneKey, recordName: recordName ?? "", type: type, wireID: id)
    }

    /// The name a record made here goes out under (`MobilePatchOutbox`); nil while the zone's salt is not
    /// held, when no save of it can have gone out.
    private func madeRecordName(_ type: SyncRecordType, _ id: String, in zoneKey: String) throws -> String? {
        guard let zone = ProjectionZones.zone(ofKey: zoneKey),
              let salt = try MobilePatchOutbox(replica: replica, moveMaps: nil).salt(zoneKey: zoneKey, zone: zone)
        else { return nil }
        return RecordNaming.recordName(type: type, id: id, salt: salt)
    }

    mutating func saveClock() throws {
        if let clock, clock != clockAsLoaded { try store.saveClock(clock, now: now) }
    }

    private mutating func queued(_ type: SyncRecordType, changing fields: [String]) {
        due = max(due ?? 0, MobilePatchOutbox.debounce(type))
        if MobileReplicaChange.showsOnScreens(type, changing: fields) { changesScreens = true }
    }

    // MARK: - Where things are

    /// A notebook the phone holds, live, where `resolveNotebook()` leads (§5.2), with its zone.
    struct Notebook {
        let id: String
        let zoneKey: String
        let zone: SyncZoneName
        let envelope: SyncEnvelope

        var isPersonal: Bool { !zone.isSpace }
    }

    /// The live notebook an id leads to: merges and moves followed, and an original still moving into a
    /// space taken as its copy there once the phone holds it (§4.4). Refused when it is gone.
    func liveNotebook(_ id: String) throws -> Notebook {
        guard let notebook = try resolvedNotebook(id),
              ["active", "archived"].contains(notebook.envelope.fields["status"]?.stringValue ?? "active")
        else { throw MobileRecordWriterError.notebookGone }
        return notebook
    }

    func resolvedNotebook(_ id: String) throws -> Notebook? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let keys = try zoneKeys(holding: .notebook, trimmed)
        guard let startKey = keys.first(where: { $0 == MobileProjection.libraryKey }) ?? keys.first,
              let startZone = ProjectionZones.zone(ofKey: startKey) else { return nil }
        let redirects: (SyncRecordLocation) -> NotebookRedirects? = { location in
            guard let key = try? self.zoneKey(of: location.zone), let envelope = try? self.held(.notebook, location.id, in: key) else { return nil }
            return NotebookRedirects(mergedInto: envelope.fields["mergedInto"]?.stringValue, movedTo: envelope.fields["movedTo"]?.stringValue,
                                     movingTo: envelope.fields["movingTo"]?.stringValue)
        }
        var location = NotebookResolution.resolve(SyncRecordLocation(zone: startZone, id: trimmed), redirects: redirects)
        if let spaceID = redirects(location)?.movingTo, !spaceID.isEmpty,
           redirects(SyncRecordLocation(zone: .space(spaceID), id: location.id)) != nil {
            location = SyncRecordLocation(zone: .space(spaceID), id: location.id)
        }
        guard let key = try zoneKey(of: location.zone), let envelope = try held(.notebook, location.id, in: key) else { return nil }
        return Notebook(id: location.id, zoneKey: key, zone: location.zone, envelope: envelope)
    }

    /// The zone a record goes into (`zoneFor`, §4.4) given the fields it is written with, as a key the
    /// phone holds.
    func zoneKey(for type: SyncRecordType, id: String, fields: [String: SyncJSON], writtenIn library: SyncZoneName = .library) throws -> String {
        let zone = ZonePlacement.zone(for: type, id: id, fields: fields, writtenIn: library, replica: MobilePlacement(write: self))
        guard let key = try zoneKey(of: zone) else { throw MobileRecordWriterError.zoneNotHeld }
        return key
    }
}

/// What the phone holds, patches included, as `ZonePlacement` reads it.
struct MobilePlacement: ZonePlacementReplica {
    let write: MobileWrite

    func zones(holding type: SyncRecordType, id: String) -> [SyncZoneName] {
        ((try? write.zoneKeys(holding: type, id)) ?? []).compactMap(ProjectionZones.zone(ofKey:))
    }

    func notebookRedirects(_ location: SyncRecordLocation) -> NotebookRedirects? {
        guard let key = try? write.zoneKey(of: location.zone), let envelope = try? write.held(.notebook, location.id, in: key) else { return nil }
        return NotebookRedirects(mergedInto: envelope.fields["mergedInto"]?.stringValue, movedTo: envelope.fields["movedTo"]?.stringValue,
                                 movingTo: envelope.fields["movingTo"]?.stringValue)
    }

    func space(kind: String, primaryID: String) -> SyncZoneName? {
        ReplicaPlacement(connection: write.connection).space(kind: kind, primaryID: primaryID)
    }
}

// MARK: - Which writes the screens hear about

/// What a write changes of what the screens' models show (`MobileReadModels.snapshot`). The phone writes
/// some records constantly while the learner reads, listens and answers; none of them is on a list, and
/// the library is read again for everything else.
enum MobileReplicaChange {
    /// Whether a patch of `type` that changed `fields` (none for a deletion) changes a screen's model.
    static func showsOnScreens(_ type: SyncRecordType, changing fields: [String]) -> Bool {
        switch type {
        case .sitting, .activityLog:
            // A sitting's answers and a day's log are read where they are used (the card review, the
            // Memory grid, a candidate's activity), never as part of a list.
            return false
        case .readingState:
            // Only the read mark is a list's: the place, the furthest point, the listen point and
            // when it was last read are not.
            return fields.contains("readAt")
        default:
            return true
        }
    }
}

// MARK: - Sending what the phone wrote

/// The phone's outbox (§6.6, light clients): its `ck_patches` rows and pending deletes as the changes
/// the private engine and SpaceSync send, each record patched onto the raw payload the replica holds
/// and sent on its change tag. A record is due once its last write is older than its debounce (2 s;
/// ReadingState 30 s). A pending write to a record a move took into another zone (`ZoneRoot.moveMaps`,
/// D51) is laid over its copy there once the phone holds it, with its stamps, and goes out from there
/// (§4.4, §6.2); the private engine never sends a record to a zone it left.
struct MobilePatchOutbox {
    let replica: MobileReplica
    let moveMaps: MoveMapIndex?

    static func debounce(_ type: SyncRecordType) -> TimeInterval {
        switch type {
        case .readingState, .sitting: return 30
        case .activityLog: return 300
        default: return 2
        }
    }

    /// The single-writer histories (§3.5.23, §3.5.24): a write to one already waiting does not move its
    /// debounce clock, so a sitting that runs is saved every 30 s and a day's log every 5 minutes.
    static func keepsFirstWrite(_ type: SyncRecordType) -> Bool {
        type == .sitting || type == .activityLog
    }

    static func priority(_ type: SyncRecordType) -> OutboxPriority {
        type.spec.isPrivateOnly ? .personal : .structure
    }

    private var connection: SQLiteConnection { replica.connection }
    private var store: ReplicaStore { replica.replica }

    func changes(now: Date, limit: Int, scope: OutboxScope) throws -> [OutboxChange] {
        let nowSeconds = now.timeIntervalSinceReferenceDate
        var rows: [(zoneKey: String, type: SyncRecordType, wireID: String, dirtyAt: Double)] = []
        try connection.query("SELECT zone_key, record_type, wire_id, dirty_at FROM ck_patches ORDER BY dirty_at, zone_key, wire_id", []) { row in
            guard let type = SyncRecordType(rawValue: row.text(1) ?? "") else { return }
            rows.append((row.text(0) ?? "", type, row.text(2) ?? "", row.real(3) ?? 0))
        }
        var saves: [OutboxChange] = []
        var salts: [String: Data?] = [:]
        for row in rows where row.dirtyAt <= nowSeconds - Self.debounce(row.type) {
            guard let zone = ProjectionZones.zone(ofKey: row.zoneKey) else { continue }
            if let destination = moveMaps?.retarget(type: row.type.rawValue, id: row.wireID, from: zone.name) {
                try relay(row.type, row.wireID, from: row.zoneKey, to: destination)
                continue
            }
            guard scope.admits(zone), let change = try save(row.type, row.wireID, in: row.zoneKey, zone: zone, salts: &salts) else { continue }
            saves.append(change)
        }
        var deletes: [OutboxChange] = []
        try connection.query("SELECT zone_key, record_name, record_type, wire_id, deleted_at FROM ck_pending_deletes ORDER BY deleted_at", []) { row in
            guard let zoneKey = row.text(0), let zone = ProjectionZones.zone(ofKey: zoneKey), scope.admits(zone),
                  let type = SyncRecordType(rawValue: row.text(2) ?? ""), (row.real(4) ?? 0) <= nowSeconds - Self.debounce(type)
            else { return }
            deletes.append(OutboxChange(zoneKey: zoneKey, zone: zone, recordType: type, wireID: row.text(3) ?? "", recordName: row.text(1) ?? "",
                                        systemFields: nil, action: .delete, priority: Self.priority(type), stamps: [:], mintedAgainst: [:], rows: []))
        }
        for index in deletes.indices {
            let delete = deletes[index]
            let held = try store.record(zoneKey: delete.zoneKey, recordName: delete.recordName)
            deletes[index] = OutboxChange(zoneKey: delete.zoneKey, zone: delete.zone, recordType: delete.recordType, wireID: delete.wireID,
                                          recordName: delete.recordName, systemFields: held?.systemFields, action: .delete,
                                          priority: delete.priority, stamps: [:], mintedAgainst: [:], rows: [])
        }
        let ordered = (saves + deletes).enumerated().sorted { lhs, rhs in
            lhs.element.priority != rhs.element.priority ? lhs.element.priority < rhs.element.priority : lhs.offset < rhs.offset
        }.map(\.element)
        return Array(ordered.prefix(limit))
    }

    /// One record's save: the replica's raw payload (a new envelope for a record made here) with the
    /// pending patch laid over it. Waits while the zone's root is not held, or a delete of the record is
    /// still on its way.
    private func save(_ type: SyncRecordType, _ wireID: String, in zoneKey: String, zone: SyncZoneName,
                      salts: inout [String: Data?]) throws -> OutboxChange? {
        guard let patch = try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: wireID, in: connection),
              !patch.stamps.isEmpty else { return nil }
        if salts[zoneKey] == nil { salts[zoneKey] = try salt(zoneKey: zoneKey, zone: zone) }
        guard let salt = salts[zoneKey] ?? nil else { return nil }
        let held = try store.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID)
        let recordName = held?.recordName ?? RecordNaming.recordName(type: type, id: wireID, salt: salt)
        if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?)",
                                        [.text(zoneKey), .text(recordName)]) == 1 {
            return nil
        }
        let base: SyncEnvelope
        if let held {
            guard let decoded = replica.decode(held.payload) else { return nil }
            base = decoded
        } else {
            base = SyncEnvelope.new(type, id: wireID, saltID: RecordNaming.saltID(salt))
        }
        var envelope = patch.applied(to: base)
        envelope.rev = SyncSchema.schemaRevision
        return OutboxChange(zoneKey: zoneKey, zone: zone, recordType: type, wireID: wireID, recordName: recordName,
                            systemFields: held?.systemFields, action: .save(envelope), priority: Self.priority(type),
                            stamps: Self.flattened(patch.stamps), mintedAgainst: [:], rows: [])
    }

    /// The salt names are made with: the personal root's for the private zones, a space's own root's.
    func salt(zoneKey: String, zone: SyncZoneName) throws -> Data? {
        let rootKey = zone.isSpace ? zoneKey : MobileProjection.libraryKey
        guard let root = try store.record(zoneKey: rootKey, recordName: SyncSchema.rootRecordName) else { return nil }
        return replica.decode(root.payload)?.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
    }

    /// A pending write to a record a move took to `destination`, laid over the copy there, field by field
    /// by stamp, once the phone holds the copy; the old zone's replica row goes, since the move took it.
    private func relay(_ type: SyncRecordType, _ wireID: String, from zoneKey: String, to destination: String) throws {
        guard let zone = SyncZoneName(destination), let targetKey = try ReplicaPlacement(connection: connection).zoneKey(of: zone),
              try store.record(zoneKey: targetKey, recordType: type.rawValue, wireID: wireID) != nil,
              let moving = try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: wireID, in: connection)
        else { return }
        var target = try PendingPatch.load(zoneKey: targetKey, type: type.rawValue, wireID: wireID, in: connection)
            ?? PendingPatch(changes: [:], stamps: [:], zoneKey: targetKey, type: type.rawValue, wireID: wireID)
        for (field, stamp) in moving.stamps {
            switch (stamp, target.stamps[field]) {
            case (.value(let mine), .value(let theirs)?) where SyncStamp.compare(mine, theirs) <= 0:
                continue
            case (.value, _):
                target.changes[field] = moving.changes[field] ?? .null
                target.stamps[field] = stamp
            case (.elements(let mine), let theirs):
                var stamps: [String: SyncStamp] = if case .elements(let held)? = theirs { held } else { [:] }
                var values = target.changes[field]?.objectValue ?? [:]
                for (element, elementStamp) in mine {
                    if let held = stamps[element], SyncStamp.compare(elementStamp, held) <= 0 { continue }
                    stamps[element] = elementStamp
                    values[element] = moving.changes[field]?.objectValue?[element] ?? .null
                }
                target.changes[field] = .object(values)
                target.stamps[field] = .elements(stamps)
            }
        }
        try Self.save(target, dirtyAt: Date(timeIntervalSinceReferenceDate: 0), in: connection)
        try PendingPatch.delete(zoneKey: zoneKey, type: type.rawValue, wireID: wireID, in: connection)
        if let old = try store.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID) {
            try store.deleteRecord(zoneKey: zoneKey, recordName: old.recordName)
        }
        try replica.reindex(zoneKey: zoneKey, type: type, wireID: wireID)
        try replica.reindex(zoneKey: targetKey, type: type, wireID: wireID)
        MobileRecordWriter.logger.info("A pending write went to the copy of a moved \(type.rawValue, privacy: .public)")
    }

    // MARK: - Settling

    /// A save landed: the paths it carried leave the pending patch, unless written again since.
    static func settle(_ change: OutboxChange, in connection: SQLiteConnection) throws {
        guard case .save = change.action,
              var patch = try PendingPatch.load(zoneKey: change.zoneKey, type: change.recordType.rawValue, wireID: change.wireID, in: connection)
        else { return }
        for (path, sent) in change.stamps {
            switch patch.stamps[path.field] {
            case .value(let held)? where path.element == nil && held == sent:
                patch.stamps[path.field] = nil
                patch.changes[path.field] = nil
            case .elements(var held)? where path.element.map({ held[$0] == sent }) == true:
                held[path.element!] = nil
                var values = patch.changes[path.field]?.objectValue ?? [:]
                values[path.element!] = nil
                patch.stamps[path.field] = held.isEmpty ? nil : .elements(held)
                patch.changes[path.field] = held.isEmpty ? nil : .object(values)
            default:
                continue
            }
        }
        if patch.stamps.isEmpty {
            try PendingPatch.delete(zoneKey: patch.zoneKey, type: patch.type, wireID: patch.wireID, in: connection)
        } else {
            try save(patch, dirtyAt: nil, in: connection)
        }
    }

    /// One record's pending patch; `dirtyAt` moves the debounce clock (nil keeps it).
    static func save(_ patch: PendingPatch, dirtyAt: Date?, in connection: SQLiteConnection) throws {
        let json = String(decoding: patch.json.serialized(), as: UTF8.self)
        let dirty = (dirtyAt ?? Date()).timeIntervalSinceReferenceDate
        try connection.execute("""
            INSERT INTO ck_patches (zone_key, record_type, wire_id, patch_json, dirty_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET patch_json = excluded.patch_json\(dirtyAt == nil ? "" : ", dirty_at = excluded.dirty_at")
        """, [.text(patch.zoneKey), .text(patch.type), .text(patch.wireID), .text(json), .real(dirty)])
    }

    static func flattened(_ stamps: [String: SyncFieldStamp]) -> [StampedPath: SyncStamp] {
        var paths: [StampedPath: SyncStamp] = [:]
        for (field, stamp) in stamps {
            switch stamp {
            case .value(let stamp): paths[StampedPath(field)] = stamp
            case .elements(let elements): for (element, stamp) in elements { paths[StampedPath(field, element: element)] = stamp }
            }
        }
        return paths
    }
}
