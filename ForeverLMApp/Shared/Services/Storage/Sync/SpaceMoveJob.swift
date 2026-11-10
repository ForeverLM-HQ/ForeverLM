import Foundation
import OSLog

enum SpaceMoveError: Error, Equatable, LocalizedError {
    /// No stamp is minted before the device knows its server offset (§6.3).
    case noServerOffset
    /// A zone, a root or a record the move needs is not on this Mac yet.
    case notHeld(String)
    /// A move goes only into a space this account owns (D21); into anyone else's it is a copy.
    case notOwner
    /// The request names no space this Mac can move into.
    case noSpace
    /// A test stopped the job before a step, as a crash would.
    case stopped(SpaceMoveJob.Step)
    /// A record kept changing on the server while it was written.
    case keptChanging(String)
    case cloud(String)

    var errorDescription: String? {
        switch self {
        case .noServerOffset: return "This Mac has not heard the iCloud server's time yet."
        case .notHeld(let what): return "This Mac does not hold \(what) yet."
        case .notOwner: return "Only the space's owner can move a notebook into it."
        case .noSpace: return "The move names no space."
        case .stopped(let step): return "The move stopped before \(step.rawValue)."
        case .keptChanging(let what): return "\(what) kept changing in iCloud while it was moved."
        case .cloud(let reason): return "iCloud refused part of the move: \(reason)"
        }
    }
}

// MARK: - Writing beside the engine

/// The records a move writes itself, beside the engine and SpaceSync (docs/cloudkit-schema-design.md
/// §4.4, §5.3): compare-and-set saves on the version the replica holds (a create when it holds none),
/// where a version the server holds already is merged with the one meant, field by field (§6.2: newer
/// stamps win, the server's first writes stand), and saved again on its change tag; and deletes by
/// name. What the server keeps is absorbed as an inbound record, so a pending local change meets it
/// through the merge and the projections lay down the local rows.
struct SpaceMoveWriter: Sendable {
    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let moveMaps: MoveMapIndex
    let deviceID: String
    let clock: @Sendable () -> Date

    static let rounds = 5
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SpaceMoveJob")

    static func recordName(_ type: SyncRecordType, _ id: String, in zone: BlobZone) -> String {
        type == .zoneRoot ? SyncSchema.rootRecordName : RecordNaming.recordName(type: type, id: id, salt: zone.salt)
    }

    /// `envelope` with `patch` laid over it, every changed path stamped now with this device's clock.
    func stamped(_ envelope: SyncEnvelope, _ patch: RecordPatch) async throws -> SyncEnvelope {
        let now = clock()
        return try await store.perform { state in
            guard var stampClock = try state.replica.loadClock(), stampClock.serverOffset != nil else { throw SpaceMoveError.noServerOffset }
            let milliseconds = SyncTime.milliseconds(now)
            var patched = envelope
            try patched.apply(patch) { _, policy, seen in
                guard let stamp = stampClock.mint(policy, eventTime: milliseconds, seen: seen, now: milliseconds) else { throw SpaceMoveError.noServerOffset }
                return stamp
            }
            try state.replica.saveClock(stampClock, now: now)
            return patched
        }
    }

    /// `local` merged onto `server` (§6.2), with a text body (T) taken from the side whose stamp is the
    /// later one: a move's copy has no three-way base of its own, and its body is a pointer.
    static func merge(server: SyncEnvelope, local: SyncEnvelope, base: SyncEnvelope?) -> SyncEnvelope {
        let outcome = FieldMerge.merge(server: server, local: local, base: base)
        var merged = outcome.merged
        for field in outcome.needsTextMerge {
            guard case .value(let mine)? = local.stamps[field], case .value(let theirs)? = server.stamps[field], mine.isLater(than: theirs) else { continue }
            merged.fields[field] = local.fields[field]
            merged.stamps[field] = .value(mine)
        }
        return merged
    }

    /// Saves each envelope into `zone` and returns what the server holds for each afterwards.
    func put(_ envelopes: [SyncEnvelope], in zone: BlobZone) async throws -> [CloudRecord] {
        struct Pending {
            var envelope: SyncEnvelope
            var base: SyncEnvelope?
            var systemFields: Data?
            let id: CloudRecordID
        }
        guard !envelopes.isEmpty else { return [] }
        let zoneKey = zone.zoneKey
        var pending: [Pending] = try await store.perform { state in
            try envelopes.map { envelope in
                guard let type = envelope.recordType else { throw SpaceMoveError.notHeld("a record type this build writes") }
                let name = Self.recordName(type, envelope.id, in: zone)
                let held = try state.replica.record(zoneKey: zoneKey, recordName: name)
                return Pending(envelope: envelope, base: held.flatMap { try? SyncEnvelope(storedPayload: $0.payload) },
                               systemFields: held?.systemFields, id: CloudRecordID(name, in: zone.zoneID))
            }
        }
        var saved: [CloudRecord] = []
        for _ in 0..<Self.rounds where !pending.isEmpty {
            var next: [Pending] = []
            for batch in try Self.batches(pending.map { ($0, try $0.envelope.storedPayload()) }) {
                let records = batch.map { item, payload in
                    CloudRecord(id: item.id, recordType: item.envelope.type, encryptedFields: [CloudRecord.payloadKey: .bytes(payload)],
                                systemFields: item.systemFields)
                }
                let sentAt = clock()
                let results = try await transport.modifyRecords(saving: records, in: zone.database)
                for (item, _) in batch {
                    if let record = results.savedRecord(item.id) {
                        saved.append(record)
                        continue
                    }
                    guard let error = results.error(for: item.id) else { throw SpaceMoveError.cloud("no answer for \(item.envelope.type)") }
                    guard error.code == .serverRecordChanged, let server = error.serverRecord, let payload = server.payload,
                          let held = try? SyncEnvelope(storedPayload: payload)
                    else { throw SpaceMoveError.cloud(error.description) }
                    let merged = Self.merge(server: held, local: item.envelope, base: item.base)
                    if merged == held {
                        saved.append(server)
                    } else {
                        next.append(Pending(envelope: merged, base: held, systemFields: server.systemFields, id: item.id))
                    }
                }
                if let serverTime = results.saved.values.compactMap({ try? $0.get() }).first?.modificationDate {
                    let deviceID = deviceID
                    try await store.perform { try $0.replica.recordServerTime(serverTime, sentAt: sentAt, deviceID: deviceID) }
                }
            }
            pending = next
        }
        guard pending.isEmpty else { throw SpaceMoveError.keptChanging(pending[0].envelope.type) }
        return saved
    }

    private static func batches<T>(_ items: [(T, Data)]) -> [[(T, Data)]] {
        var batches: [[(T, Data)]] = []
        var current: [(T, Data)] = []
        var bytes = 0
        for item in items {
            if !current.isEmpty, current.count >= SyncSchema.Limits.batchMaxRecords || bytes + item.1.count > SyncSchema.Limits.batchMaxBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += item.1.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Applies what the server holds as inbound records, in one apply (§6.2), then projects what their
    /// arrival freed. A root goes into the replica only, as the engine takes a root.
    func absorb(_ records: [CloudRecord], in zoneKey: String) async throws {
        guard !records.isEmpty else { return }
        let now = clock()
        let moveMaps = moveMaps
        try await store.perform { state in
            try state.replica.apply { replica in
                let applied = try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps)
                for record in records {
                    if record.id.recordName == SyncSchema.rootRecordName {
                        try replica.upsertRecord(ReplicaRecord(record, zoneKey: zoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil))
                    } else {
                        try applied.absorb(record, zoneKey: zoneKey)
                    }
                }
            }
            try state.drainReady()
        }
    }

    /// Deletes records from `zone` by name; one the server no longer has counts as deleted. The
    /// replica forgets each one, and nothing is projected: the local rows are the copy's now.
    func delete(_ keys: [SpaceMoveRecordKey], from zone: BlobZone) async throws -> Set<SpaceMoveRecordKey> {
        var gone = Set<SpaceMoveRecordKey>()
        let named = keys.map { ($0, CloudRecordID(Self.recordName($0.type, $0.wireID, in: zone), in: zone.zoneID)) }
        for start in stride(from: 0, to: named.count, by: SyncSchema.Limits.batchMaxRecords) {
            let batch = Array(named[start..<min(start + SyncSchema.Limits.batchMaxRecords, named.count)])
            let results = try await transport.modifyRecords(deleting: batch.map(\.1), in: zone.database)
            for (key, id) in batch {
                switch results.deleted[id] {
                case .success?: gone.insert(key)
                case .failure(let error)? where error.code == .unknownItem: gone.insert(key)
                case .failure(let error)?: Self.logger.error("An original was not deleted: \(error.description, privacy: .public)")
                case nil: continue
                }
            }
        }
        let zoneKey = zone.zoneKey
        let forgotten = named.filter { gone.contains($0.0) }
        try await store.perform { state in
            for (key, id) in forgotten {
                try state.replica.deleteRecord(zoneKey: zoneKey, recordName: id.recordName)
                try state.connection.execute("DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(id.recordName)])
                try state.connection.execute(
                    "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?",
                    [.text(OutboxFeeder.pinSource), .text(OutboxFeeder.pinKey(zoneKey: zoneKey, type: key.type, wireID: key.wireID))]
                )
            }
        }
        return gone
    }
}

// MARK: - The move job

/// `SpaceMoveJob` (docs/cloudkit-schema-design.md §4.4, §5.2, §5.3, §9.2, D17, D21, D51): moves a notebook
/// into a space its owner owns, a Doc into its Doc space, either back to My Library, and re-homes what
/// lands late where a move took its parent. A move is copy, then delete, under the same logical ids, as
/// a durable job with a journal (`ck_move_jobs`, `ck_move_items`):
///
/// 1. the space exists (`SpaceService` makes it when a request asks for a new one);
/// 2. the original Notebook gets `movingTo`;
/// 3. every record of the notebook is copied verbatim (its stamps and the fields this build does not
///    know included), the refusal decided per chat first, so a private chat stays in `Library` whole;
/// 4. every Source a live Entry names is copied with its Collection and its satellites, and every moved
///    record's satellites go into the space before its pointer does;
/// 5. catch-up passes (a fresh fetch, a re-scan of the notebook's children, newer stamps re-applied to
///    the copies) run until one finds nothing;
/// 6. the original Notebook becomes the permanent `movedTo` stub; each pass's (type, id, from, to) goes
///    into its own `ZoneRoot.moveMaps` entry before the pass deletes its first original; and each
///    original is deleted only once its own copy was acknowledged. Nothing is deleted on age.
///
/// Every acknowledged copy is absorbed as an inbound record, so the projections lay the local rows down
/// as for a space's own records, and the notebook keeps its row (`SpaceMoveLocal`). After each round
/// (`afterRound`), any of the owner's Macs resumes an unfinished journal, re-homes late children and
/// grandchildren from `moveMaps`, forwards late edits of a stub to its space copy, and finishes its own
/// move whose journal was lost, only once every child is found by name in the space. A course never
/// moves (§5.5): a notebook's follow Entries travel as Entries.
///
/// Mac only and generation 2 only: nothing constructs it under generation 1.
actor SpaceMoveJob {
    /// The points a crash can fall between, for the suites (`stop(before:)`).
    enum Step: String, Sendable, CaseIterable {
        case mark
        case copy
        case catchUp
        case stub
        case list
        case delete
        case dropSpace
    }

    struct Report: Equatable, Sendable {
        var jobID = ""
        /// Records copied into the target (moved and copies).
        var copied = 0
        /// Records that stay where they are (private chats, refused records).
        var kept = 0
        var reapplied = 0
        var deleted = 0
        var passes = 0
        /// The records a move back found in the space that no pass of the journal carried (a member's chat,
        /// a task, a comment, a setting written in the last moments): the space is then kept, not deleted.
        var spaceKept: [String] = []
    }

    /// What `finishLostMove` found.
    enum LostMove: Equatable, Sendable {
        case finished
        /// Children the space does not hold by name: nothing was deleted, and both copies stay.
        case waiting(missing: Int)
        case nothingToFinish
    }

    static let maximumPasses = 12
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SpaceMoveJob")
    private static let libraryKey = PrivateSyncZones.libraryKey
    private static let catalogKey = PrivateSyncZones.key(PrivateSyncZones.catalog)

    let writer: SpaceMoveWriter
    let blobs: BlobStore
    let spaces: SpaceService?
    /// A fresh fetch of one zone, by its key: the private engine's for `Library` and `Catalog`,
    /// SpaceSync's walk for a space.
    let fetch: @Sendable (String) async throws -> Void
    private var stopBefore: Step?
    private var passing = false

    var transport: CloudTransport { writer.transport }
    var store: PrivateSyncLocalStore { writer.store }
    var moveMaps: MoveMapIndex { writer.moveMaps }

    init(transport: CloudTransport, store: PrivateSyncLocalStore, blobs: BlobStore, moveMaps: MoveMapIndex, spaces: SpaceService?,
         deviceID: String, clock: @escaping @Sendable () -> Date = { Date() }, fetch: @escaping @Sendable (String) async throws -> Void) {
        writer = SpaceMoveWriter(transport: transport, store: store, moveMaps: moveMaps, deviceID: deviceID, clock: clock)
        self.blobs = blobs
        self.spaces = spaces
        self.fetch = fetch
    }

    /// The running coordinator's: its engine fetches `Library` and `Catalog`, its SpaceSync walks spaces,
    /// and the moves it lists are the ones the engine and SpaceSync retarget by.
    init(coordinator: SyncCoordinator) {
        let engine = coordinator.engine
        let sync = coordinator.spaces
        let store = coordinator.store
        self.init(transport: coordinator.transport, store: store, blobs: coordinator.blobs, moveMaps: engine.moveMaps,
                  spaces: SpaceService(coordinator: coordinator), deviceID: coordinator.deviceID) { zoneKey in
            if let row = try await store.perform({ try $0.replica.zone(key: zoneKey) }), let zone = SpaceZone(row) {
                try await sync.walk(zone)
            } else {
                try await engine.fetchChanges()
            }
        }
    }

    /// The suites stop a job before `step`, as a crash would; the next run resumes from the journal.
    func stop(before step: Step?) {
        stopBefore = step
    }

    private func check(_ step: Step) throws {
        if stopBefore == step {
            stopBefore = nil
            throw SpaceMoveError.stopped(step)
        }
    }

    // MARK: Requests

    /// Moves a notebook into a space this account owns (§5.3). A request already in the journal resumes.
    @discardableResult
    func moveNotebook(_ notebookID: String, into spaceID: String, jobID: String? = nil) async throws -> Report {
        let spaceKey = try await ownedSpace(spaceID)
        var id = jobID ?? ""
        if id.isEmpty { id = try await freshID("nb.\(notebookID).\(spaceID)") }
        try await begin(SpaceMoveJobRow(id: id, kind: .notebook, recordType: .notebook, wireID: notebookID, fromZone: Self.libraryKey,
                                        toZone: spaceKey, state: .started, pass: 0))
        return try await run(id)
    }

    /// Moves a Doc and its Comments into its Doc space (§9.1, D5); the Doc keeps its `notebookID`.
    @discardableResult
    func moveDoc(_ artifactID: String, into spaceID: String) async throws -> Report {
        let spaceKey = try await ownedSpace(spaceID)
        let id = try await freshID("doc.\(artifactID).\(spaceID)")
        try await begin(SpaceMoveJobRow(id: id, kind: .doc, recordType: .artifact, wireID: artifactID, fromZone: Self.libraryKey,
                                        toZone: spaceKey, state: .started, pass: 0))
        return try await run(id)
    }

    /// Share's move (§9.1 `doc`): the Doc goes into its Doc space when `Library` holds it. A Doc that
    /// is in its space already has nothing to move, and neither has one never sent: placement sends
    /// its first record straight into the space. Nil when nothing moved.
    @discardableResult
    func moveDocIfInLibrary(_ artifactID: String, into spaceID: String) async throws -> Report? {
        guard try await store.perform({ try SpaceMoveScan.held(.artifact, artifactID, in: Self.libraryKey, $0.connection) }) != nil else {
            return nil
        }
        let report = try await moveDoc(artifactID, into: spaceID)
        // A body published while the move ran reaches the copy as a pointer alone (`reapply` carries
        // fields): its satellites follow now. Copying is idempotent, so a body already there costs a lookup.
        let spaceKey = try await ownedSpace(spaceID)
        if let moved = try await store.perform({ try SpaceMoveScan.held(.artifact, artifactID, in: spaceKey, $0.connection) }) {
            try await copySatellites(of: moved, from: Self.libraryKey, to: try await zone(spaceKey))
        }
        return report
    }

    /// Moves a notebook back to My Library (§5.2): the `Library` stub becomes the live notebook again,
    /// every record of the notebook comes back, sources map to the learner's own by id (made only where
    /// the learner has none), and a space made for the notebook is deleted last.
    @discardableResult
    func moveNotebookBack(_ notebookID: String, from spaceID: String) async throws -> Report {
        let spaceKey = try await ownedSpace(spaceID)
        let id = try await freshID("back.\(notebookID).\(spaceID)")
        try await begin(SpaceMoveJobRow(id: id, kind: .notebookBack, recordType: .notebook, wireID: notebookID, fromZone: spaceKey,
                                        toZone: Self.libraryKey, state: .started, pass: 0))
        return try await run(id)
    }

    /// Moves a Doc back from its Doc space, which is deleted last.
    @discardableResult
    func moveDocBack(_ artifactID: String, from spaceID: String) async throws -> Report {
        let spaceKey = try await ownedSpace(spaceID)
        let id = try await freshID("docBack.\(artifactID).\(spaceID)")
        try await begin(SpaceMoveJobRow(id: id, kind: .docBack, recordType: .artifact, wireID: artifactID, fromZone: spaceKey,
                                        toZone: Self.libraryKey, state: .started, pass: 0))
        return try await run(id)
    }

    /// A light client's `Job(moveToSpace)` (§3.5.28, §5.3, R4-m11): into `params.spaceID`, or into a new
    /// space of `params.newSpace` `{kind, name}`, whose id the Job fixes, so a resumed request makes no
    /// second space. Returns the space's id.
    func runRequest(jobID: String, notebookID: String, params: [String: SyncJSON]) async throws -> String {
        let spaceID: String
        if let named = params["spaceID"]?.stringValue, !named.isEmpty {
            spaceID = named
        } else if let new = params["newSpace"]?.objectValue, let kind = new["kind"]?.stringValue, ["notebook", "team"].contains(kind) {
            spaceID = SpaceMoveIdentity.spaceID(forJob: jobID)
            guard let spaces else { throw SpaceMoveError.noSpace }
            let name = new["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Shared notebook"
            if try await heldSpaceKey(spaceID) == nil {
                try await spaces.create(kind: kind, name: name, owner: try await owner(nil), primaryID: kind == "notebook" ? notebookID : nil,
                                        spaceID: spaceID)
            } else {
                // A resumed request whose first run stopped before the share was saved (F15).
                try await spaces.ensureShared(spaceID: spaceID, title: name)
            }
        } else {
            throw SpaceMoveError.noSpace
        }
        // The journal's id, and so each pass's `moveMaps` key, names this Mac: a Mac that takes the Job over
        // after the lease lapsed runs its own journal, and the two never write one key with different lists
        // (F14). The space's id is the Job's alone, so both reach the same space.
        try await moveNotebook(notebookID, into: spaceID, jobID: "job.\(jobID).\(writer.deviceID)")
        return spaceID
    }

    // MARK: Running a journal

    /// Runs a job from where its journal stands.
    @discardableResult
    func run(_ jobID: String) async throws -> Report {
        // One run of a journal at a time in this process (the runner's request and the after-round pass
        // may both ask), so each pass's `moveMaps` key has one writer.
        while !SpaceMoveRunning.shared.claim(jobID) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        defer { SpaceMoveRunning.shared.release(jobID) }
        guard var job = try await store.perform({ try SpaceMoveJournal.job(jobID, $0.connection) }) else { throw SpaceMoveError.notHeld("move \(jobID)") }
        var report = Report(jobID: jobID)
        do {
            try await advance(&job, &report)
        } catch {
            let now = writer.clock()
            let failed = job
            try? await store.perform { try SpaceMoveJournal.save(failed, now: now, error: String(describing: error), $0.connection) }
            throw error
        }
        return report
    }

    private func advance(_ job: inout SpaceMoveJobRow, _ report: inout Report) async throws {
        if job.state == .started {
            if job.kind == .notebook {
                try check(.mark)
                try await mark(job)
            }
            try await set(&job, .marked)
        }
        if job.state == .marked {
            try check(.copy)
            try await copyAndCatchUp(job, &report)
            try await set(&job, .copied)
        }
        if job.state == .copied {
            if job.kind == .notebook {
                try check(.stub)
                try await writeStub(job)
            }
            try await set(&job, .stubbed)
        }
        if job.state == .stubbed {
            try check(.list)
            report.reapplied += try await reapply(job)
            try await list(&job)
            if [.notebookBack, .docBack].contains(job.kind), try await madeFor(job) {
                try check(.dropSpace)
                // The space stays shared and writable until it is deleted, and deleting it takes every
                // record in it: read it once more, carry what landed since the last pass, and delete it only
                // when nothing is left that the journal did not carry (F10).
                try await fetch(job.fromZone)
                _ = try await plan(job, &report)
                report.copied += try await copyQueued(job)
                report.reapplied += try await reapply(job)
                try await list(&job)
                let strangers = try await recordsOutsideJournal(job)
                if strangers.isEmpty {
                    report.deleted += try await dropSpace(job)
                } else {
                    report.spaceKept = strangers
                    Self.logger.error("A move back keeps its space: \(strangers.count) records in it are not the move's")
                    report.deleted += try await deleteOriginals(job)
                }
            } else {
                try check(.delete)
                report.deleted += try await deleteOriginals(job)
            }
            try await set(&job, .done)
        }
    }

    private func set(_ job: inout SpaceMoveJobRow, _ state: SpaceMoveJobState) async throws {
        job.state = state
        let saved = job
        let now = writer.clock()
        try await store.perform { try SpaceMoveJournal.save(saved, now: now, $0.connection) }
    }

    private func begin(_ job: SpaceMoveJobRow) async throws {
        let now = writer.clock()
        try await store.perform { try SpaceMoveJournal.begin(job, now: now, $0.connection) }
    }

    /// `base` while no job of that id is done, else the next free `base.<n>` (a notebook moved, moved
    /// back and moved again).
    private func freshID(_ base: String) async throws -> String {
        try await store.perform { state in
            var candidate = base
            var counter = 2
            while let held = try SpaceMoveJournal.job(candidate, state.connection), held.state == .done {
                candidate = "\(base).\(counter)"
                counter += 1
            }
            return candidate
        }
    }

    // MARK: Step 2: movingTo

    private func mark(_ job: SpaceMoveJobRow) async throws {
        guard case .space(let spaceID)? = ProjectionZones.zone(ofKey: job.toZone) else { throw SpaceMoveError.noSpace }
        let library = try await zone(job.fromZone)
        guard let held = try await store.perform({ try SpaceMoveScan.held(.notebook, job.wireID, in: job.fromZone, $0.connection) }) else {
            throw SpaceMoveError.notHeld("notebook \(job.wireID)")
        }
        guard held.fields["movingTo"]?.stringValue != spaceID else { return }
        let marked = try await writer.stamped(held.envelope, RecordPatch(.notebook, id: job.wireID, changes: ["movingTo": .value(.string(spaceID))]))
        try await writer.absorb(try await writer.put([marked], in: library), in: library.zoneKey)
    }

    // MARK: Steps 3 to 5: copy, then catch up

    /// Copies, then runs catch-up passes until one finds nothing new: each pass fetches the zone the
    /// move leaves afresh, scans for children written since by devices that had not seen `movingTo`,
    /// copies them, and re-applies to the copies every field of an original whose stamp is newer.
    private func copyAndCatchUp(_ job: SpaceMoveJobRow, _ report: inout Report) async throws {
        var pass = 0
        while pass < Self.maximumPasses {
            if pass > 0 { try check(.catchUp) }
            if job.kind != .rehome { try await fetch(job.fromZone) }
            let added = try await plan(job, &report)
            report.copied += try await copyQueued(job)
            let reapplied = try await reapply(job)
            report.reapplied += reapplied
            pass += 1
            report.passes = pass
            if pass > 1, added == 0, reapplied == 0 { break }
            if job.kind == .rehome { break }
        }
    }

    /// Adds to the journal what the move carries now; returns how many items were new.
    private func plan(_ job: SpaceMoveJobRow, _ report: inout Report) async throws -> Int {
        guard job.kind != .rehome else { return 0 }
        let writerGuard = SpaceWriteGuard.Writer(user: try await transport.userRecordName(), permission: .readWrite, isOwner: true)
        let now = writer.clock()
        let (added, kept) = try await store.perform { state -> (Int, Int) in
            let connection = state.connection
            let records: [SpaceMoveHeld]
            switch job.kind {
            case .notebook, .notebookBack: records = try SpaceMoveScan.notebook(job.wireID, in: job.fromZone, connection)
            case .doc, .docBack: records = try SpaceMoveScan.doc(job.wireID, in: job.fromZone, connection)
            case .rehome: records = []
            }
            let intoSpace = ProjectionZones.zone(ofKey: job.toZone)?.isSpace == true
            let kept = intoSpace ? SpaceMoveScan.kept(records, writer: writerGuard) : []
            var items = records.map { record in
                SpaceMoveItem(type: record.type, wireID: record.wireID, fromZone: job.fromZone, toZone: job.toZone,
                              state: kept.contains(record.key) ? .kept : .queued)
            }
            let travelling = records.filter { !kept.contains($0.key) }
            switch job.kind {
            case .notebook:
                items += try SpaceMoveScan.sources(namedBy: travelling, in: Self.catalogKey, connection).map {
                    SpaceMoveItem(type: $0.type, wireID: $0.wireID, fromZone: Self.catalogKey, toZone: job.toZone, state: .queued)
                }
            case .notebookBack:
                // The learner's own library keeps the sources it has; only the ones it lacks are made.
                items += try SpaceMoveScan.sources(namedBy: travelling, in: job.fromZone, connection).filter {
                    try SpaceMoveScan.held($0.type, $0.wireID, in: Self.catalogKey, connection) == nil
                }.map { SpaceMoveItem(type: $0.type, wireID: $0.wireID, fromZone: job.fromZone, toZone: Self.catalogKey, state: .queued) }
            case .doc, .docBack, .rehome:
                break
            }
            return (try SpaceMoveJournal.add(items, jobID: job.id, now: now, connection), kept.count)
        }
        if kept > report.kept {
            report.kept = kept
            Self.logger.info("A move keeps \(kept) private records where they are")
        }
        return added
    }

    /// Writes every queued item's copy, parents first, satellites before the pointers that name them,
    /// and absorbs what the server keeps. A move back revives the notebook's local rows first (its pool
    /// items take the learner's own sources again), once those sources are there.
    private func copyQueued(_ job: SpaceMoveJobRow) async throws -> Int {
        let queued = try await store.perform { try SpaceMoveJournal.items(job.id, $0.connection) }.filter { $0.state == .queued }
        guard !queued.isEmpty else { return 0 }
        let owner = try await owner(job.toZone)
        var copied = 0
        var unhomed = false
        // A move back makes the learner's missing sources first: its pool items name them before the
        // notebook's records come back.
        let order = job.kind == .notebookBack
            ? SpaceMoveScan.copyOrder.filter(SpaceMoveItem.copiedTypes.contains) + SpaceMoveScan.copyOrder.filter { !SpaceMoveItem.copiedTypes.contains($0) }
            : SpaceMoveScan.copyOrder
        for type in order {
            if job.kind == .notebookBack, !unhomed, !SpaceMoveItem.copiedTypes.contains(type) {
                try await unhome(job)
                unhomed = true
            }
            let group = queued.filter { $0.type == type }
            for toZone in Set(group.map(\.toZone)).sorted() {
                let items = group.filter { $0.toZone == toZone }
                let target = try await zone(toZone)
                var envelopes: [SpaceMoveEnvelope] = []
                var vanished: [SpaceMoveRecordKey] = []
                for item in items {
                    guard let held = try await store.perform({ try SpaceMoveScan.held(item.type, item.wireID, in: item.fromZone, $0.connection) }) else {
                        // Gone before it was copied (deleted meanwhile): nothing to copy, nothing to delete.
                        vanished.append(item.key)
                        continue
                    }
                    try await copySatellites(of: held, from: item.fromZone, to: target)
                    envelopes.append(SpaceMoveEnvelope(item: item, envelope: try await copy(held, job: job, into: target, owner: owner)))
                }
                let saved = try await writer.put(envelopes.map(\.envelope), in: target)
                try await writer.absorb(saved, in: target.zoneKey)
                let now = writer.clock()
                let moved = envelopes.filter { !$0.item.isCopy }.map(\.item.key)
                let copies = envelopes.filter(\.item.isCopy).map(\.item.key)
                try await store.perform { state in
                    try SpaceMoveJournal.set(.copied, moved, jobID: job.id, now: now, state.connection)
                    try SpaceMoveJournal.set(.done, copies, jobID: job.id, now: now, state.connection)
                    try SpaceMoveJournal.set(.deleted, vanished, jobID: job.id, now: now, state.connection)
                }
                copied += envelopes.count
            }
        }
        if job.kind == .notebookBack, !unhomed { try await unhome(job) }
        return copied
    }

    private struct SpaceMoveEnvelope {
        let item: SpaceMoveItem
        let envelope: SyncEnvelope
    }

    /// The copy of `held` that goes into `target`: its envelope verbatim, named with the target's salt,
    /// with what a copy into a space must carry (§5.3 step 3, §9.3): the notebook's `movingTo` cleared
    /// and its `createdBy`, a chat's, a Doc's and a task's `createdBy`, an Exchange's `author`; a copied
    /// source starts `active` and says where it came from. A notebook that comes back is its `Library`
    /// stub made live again: every newer field of the space's copy, `active`, and no redirect (§5.2).
    private func copy(_ held: SpaceMoveHeld, job: SpaceMoveJobRow, into target: BlobZone, owner: SyncPerson) async throws -> SyncEnvelope {
        let type = held.type
        if job.kind == .notebookBack, type == .notebook,
           let stub = try await store.perform({ try SpaceMoveScan.held(.notebook, held.wireID, in: target.zoneKey, $0.connection) }) {
            let revived = Self.newer(held.envelope, onto: stub.envelope, excluding: Self.redirectFields)
            return try await writer.stamped(revived, RecordPatch(.notebook, id: held.wireID, changes: [
                "status": .value(.string(held.fields["status"]?.stringValue == "archived" ? "archived" : "active")),
                "movedTo": .value(.null), "movingTo": .value(.null),
            ]))
        }
        var envelope = held.envelope
        envelope.saltID = RecordNaming.saltID(target.salt)
        var patch = RecordPatch(type, id: held.wireID)
        let intoSpace = target.isSpace
        if type == .notebook { patch.changes["movingTo"] = .value(.null) }
        if intoSpace {
            for field in ["createdBy", "author"] where type.spec.field(field) != nil && (held.fields[field] ?? .null) == .null {
                patch.changes[field] = .value(owner.value)
            }
            if type == .source || type == .collection {
                if held.fields["status"]?.stringValue != "active" { patch.changes["status"] = .value(.string("active")) }
                if type == .source, (held.fields["copiedFrom"] ?? .null) == .null {
                    patch.changes["copiedFrom"] = .value(.object([
                        "zone": .string("personal"), "at": SyncJSON(SyncTime.milliseconds(writer.clock())), "by": owner.value,
                    ]))
                }
            }
        }
        guard !patch.changes.isEmpty else { return envelope }
        return try await writer.stamped(envelope, patch)
    }

    /// The satellites a copied record names go into the target zone first (D10, D41): the FileRef stays
    /// verbatim, owner included. A personal satellite never goes into a space, and bytes only a Mac holds
    /// wait for that Mac (`heldBy`); the pointer is copied either way, as a light client's copy is.
    private func copySatellites(of held: SpaceMoveHeld, from zoneKey: String, to target: BlobZone) async throws {
        let files = SpaceMoveScan.files(in: held.envelope)
        guard !files.isEmpty else { return }
        let source = try await satelliteZone(of: zoneKey)
        guard source.zoneKey != target.zoneKey, target.isSpace || source.isSpace else { return }
        for file in files where !(file.isPersonal && target.isSpace) {
            do {
                try await blobs.copy(file, ownerType: held.type, from: source, to: target.isSpace ? target : try await satelliteZone(of: target.zoneKey))
            } catch BlobStoreError.heldOnlyBy(let mac) {
                Self.logger.info("A satellite only \(mac, privacy: .private) holds waits for that Mac")
            } catch BlobStoreError.missingParts(let ids) {
                // The server holds none of it yet (the seed's bytes pass has not reached it): the pointer is
                // copied as it is, which is no worse than the original's, and the move does not fail on every
                // retry with its notebook stuck mid-move (F21).
                Self.logger.info("\(ids.count, privacy: .public) satellites of a moved record are not on the server yet")
            }
        }
    }

    /// Where the satellites of a record in `zoneKey` live: the space's own zone, or private `Content`.
    private func satelliteZone(of zoneKey: String) async throws -> BlobZone {
        if ProjectionZones.zone(ofKey: zoneKey)?.isSpace == true { return try await zone(zoneKey) }
        let library = try await zone(Self.libraryKey)
        return BlobZone.personal(salt: library.salt)
    }

    /// Re-applies to each copy the fields of its original whose stamps are newer (§4.4, §5.3 step 5):
    /// a write that landed on the original mid-move, by a device that had not seen it, reaches the copy.
    /// Returns how many copies took something.
    private func reapply(_ job: SpaceMoveJobRow) async throws -> Int {
        let items = try await store.perform { try SpaceMoveJournal.items(job.id, $0.connection) }
            .filter { !$0.isCopy && ($0.state == .copied || $0.state == .listed) }
        var changed = 0
        for toZone in Set(items.map(\.toZone)).sorted() {
            let target = try await zone(toZone)
            let merged: [SyncEnvelope] = try await store.perform { state in
                try items.filter { $0.toZone == toZone }.compactMap { item in
                    guard let original = try SpaceMoveScan.held(item.type, item.wireID, in: item.fromZone, state.connection),
                          let copy = try SpaceMoveScan.held(item.type, item.wireID, in: toZone, state.connection)
                    else { return nil }
                    let excluded = item.type == .notebook ? Self.redirectFields : []
                    let merged = Self.newer(original.envelope, onto: copy.envelope, excluding: excluded)
                    return merged == copy.envelope ? nil : merged
                }
            }
            guard !merged.isEmpty else { continue }
            try await writer.absorb(try await writer.put(merged, in: target), in: toZone)
            changed += merged.count
        }
        return changed
    }

    /// A notebook's fields that are its redirect, or no notebook's words: never carried between the
    /// stub and its copy (`NotebookStubForwarding.notForwarded`).
    static let redirectFields = NotebookStubForwarding.notForwarded

    /// `original`'s paths laid onto `copy` where their stamps are newer (L), the larger or smaller value
    /// where the policy is X or N, and never over a first write the copy holds (S): the merge of §6.2
    /// with no base, `copy` as the server side.
    static func newer(_ original: SyncEnvelope, onto copy: SyncEnvelope, excluding: Set<String>) -> SyncEnvelope {
        var local = original
        for field in excluding {
            local.fields[field] = nil
            local.stamps[field] = nil
        }
        return SpaceMoveWriter.merge(server: copy, local: local, base: nil)
    }

    // MARK: Step 6: the stub, the move list, the deletes

    private func writeStub(_ job: SpaceMoveJobRow) async throws {
        guard case .space(let spaceID)? = ProjectionZones.zone(ofKey: job.toZone) else { throw SpaceMoveError.noSpace }
        let library = try await zone(job.fromZone)
        guard let held = try await store.perform({ try SpaceMoveScan.held(.notebook, job.wireID, in: job.fromZone, $0.connection) }) else {
            throw SpaceMoveError.notHeld("notebook \(job.wireID)")
        }
        var stub = held.envelope
        if held.fields["status"]?.stringValue != "moved" || held.fields["movedTo"]?.stringValue != spaceID {
            stub = try await writer.stamped(held.envelope, RecordPatch(.notebook, id: job.wireID, changes: [
                "status": .value(.string("moved")), "movedTo": .value(.string(spaceID)),
            ]))
            try await writer.absorb(try await writer.put([stub], in: library), in: library.zoneKey)
        }
        // What the stub holds now needs no forwarding: its copy carries it (§5.2 "Late edits to a stub").
        let notebookID = job.wireID
        try await store.perform { try NotebookStubForwarding.recordBaseline(notebookID: notebookID, envelope: nil, connection: $0.connection) }
    }

    /// Writes this pass's own `moveMaps` entry, before the pass deletes its first original (D51): the
    /// list of every copied item not listed yet, as a gzip satellite in private `Content`, named by the
    /// personal root under `<job id>.<pass>`.
    private func list(_ job: inout SpaceMoveJobRow) async throws {
        let jobID = job.id
        let items = try await store.perform { try SpaceMoveJournal.items(jobID, $0.connection) }.filter { !$0.isCopy && $0.state == .copied }
        guard !items.isEmpty else { return }
        let at = SyncTime.milliseconds(writer.clock())
        // Every item is listed, so one whose zone cannot be named stops the move before anything is deleted:
        // an original deleted with no `moveMaps` entry could never be followed (F20).
        let moves = try items.map { item -> MoveMapMove in
            guard let from = ProjectionZones.zone(ofKey: item.fromZone), let to = ProjectionZones.zone(ofKey: item.toZone) else {
                throw SpaceMoveError.notHeld("zone \(item.fromZone) or \(item.toZone) of \(item.type.rawValue) \(item.wireID)")
            }
            return MoveMapMove(type: item.type.rawValue, id: item.wireID, from: from.name, to: to.name, at: at)
        }
        try await writeMoveMap(key: "\(job.id).\(job.pass)", moves: moves)
        job.pass += 1
        let saved = job
        let now = writer.clock()
        try await store.perform { state in
            try SpaceMoveJournal.set(.listed, items.map(\.key), jobID: jobID, now: now, state.connection)
            try SpaceMoveJournal.save(saved, now: now, state.connection)
        }
    }

    private func writeMoveMap(key: String, moves: [MoveMapMove]) async throws {
        let stored = try MoveMapIndex.encodeList(moves)
        let library = try await zone(Self.libraryKey)
        let file = try await blobs.upload(stored, owner: SyncSchema.rootRecordName, ownerType: .zoneRoot, role: MoveMapIndex.role(forKey: key),
                                          mime: "application/gzip", encoding: .identity, into: BlobZone.personal(salt: library.salt))
        guard let root = try await store.perform({ try $0.replica.personalRoot()?.envelope }) else { throw SpaceMoveError.notHeld("the library's root") }
        let listed = try await writer.stamped(root, RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName, changes: ["moveMaps": .elements([key: file.value])]))
        try await writer.absorb(try await writer.put([listed], in: library), in: library.zoneKey)
        moveMaps.add(key: key, moves: moves)
    }

    /// Deletes every listed original whose copy was acknowledged. A forward move's own notebook stays:
    /// it is the stub.
    private func deleteOriginals(_ job: SpaceMoveJobRow) async throws -> Int {
        let items = try await store.perform { try SpaceMoveJournal.items(job.id, $0.connection) }.filter { !$0.isCopy && $0.state == .listed }
        let stub = items.filter { job.kind == .notebook && $0.type == .notebook && $0.wireID == job.wireID }.map(\.key)
        let now = writer.clock()
        if !stub.isEmpty { try await store.perform { try SpaceMoveJournal.set(.done, stub, jobID: job.id, now: now, $0.connection) } }
        var deleted = 0
        for fromZone in Set(items.map(\.fromZone)).sorted() {
            let keys = items.filter { $0.fromZone == fromZone && !stub.contains($0.key) }.map(\.key)
            guard !keys.isEmpty else { continue }
            // CloudKit has no conditional delete: an edit a stale device got acknowledged since the last
            // pass is read and carried to the copy right before the original goes (F23).
            if job.kind != .rehome {
                try await fetch(fromZone)
                _ = try await reapply(job)
            }
            let gone = try await writer.delete(keys, from: try await zone(fromZone))
            let done = writer.clock()
            try await store.perform { try SpaceMoveJournal.set(.deleted, Array(gone), jobID: job.id, now: done, $0.connection) }
            deleted += gone.count
        }
        return deleted
    }

    /// Whether the space a move back leaves was made for what moves back (a `notebook` or `doc` space,
    /// `primaryID` the record), so the move deletes the space last (§5.3 "Moving back").
    private func madeFor(_ job: SpaceMoveJobRow) async throws -> Bool {
        try await store.perform { state in
            guard let root = try state.replica.record(zoneKey: job.fromZone, recordName: SyncSchema.rootRecordName)
                .flatMap({ try? SyncEnvelope(storedPayload: $0.payload) })
            else { return false }
            return ["notebook", "doc"].contains(root.fields["kind"]?.stringValue ?? "") && root.fields["primaryID"]?.stringValue == job.wireID
        }
    }

    /// The records the space holds that no item of the journal accounts for (listed, done or kept), apart
    /// from the root and the satellites: what deleting the whole space would destroy unseen.
    private func recordsOutsideJournal(_ job: SpaceMoveJobRow) async throws -> [String] {
        try await store.perform { state in
            var carried = Set(try SpaceMoveJournal.items(job.id, state.connection)
                .filter { [.listed, .done, .kept, .deleted].contains($0.state) }
                .map { "\($0.type.rawValue)/\($0.wireID)" })
            // The Sources and Collections the notebook's Entries name are the move's too, though the journal does not
            // list those the learner's own library already holds: the space's copies of them go with the space.
            if job.kind == .notebookBack {
                let records = try SpaceMoveScan.notebook(job.wireID, in: job.fromZone, state.connection)
                for held in try SpaceMoveScan.sources(namedBy: records, in: job.fromZone, state.connection) {
                    carried.insert("\(held.type.rawValue)/\(held.wireID)")
                }
            }
            var strangers: [String] = []
            try state.connection.query("SELECT record_type, wire_id FROM ck_records WHERE zone_key = ? ORDER BY record_type, wire_id", [.text(job.fromZone)]) { row in
                let type = row.text(0) ?? "", id = row.text(1) ?? ""
                if type == SyncRecordType.zoneRoot.rawValue || type == SyncRecordType.content.rawValue || type.hasPrefix("cloudkit.") { return }
                if !carried.contains("\(type)/\(id)") { strangers.append("\(type)/\(id)") }
            }
            return strangers
        }
    }

    /// Deletes the space a move back emptied, with its rows on this Mac (`SpaceService.delete`). A stale
    /// device's write for it meets `zoneNotFound`, and the move list sends it to `Library` (§4.4).
    private func dropSpace(_ job: SpaceMoveJobRow) async throws -> Int {
        guard let spaces else { throw SpaceMoveError.noSpace }
        let items = try await store.perform { try SpaceMoveJournal.items(job.id, $0.connection) }.filter { !$0.isCopy && $0.state == .listed }
        if let space = try await spaces.list().first(where: { $0.zone.zoneKey == job.fromZone }) {
            try await spaces.delete(space)
        }
        let now = writer.clock()
        try await store.perform { try SpaceMoveJournal.set(.deleted, items.map(\.key), jobID: job.id, now: now, $0.connection) }
        return items.count
    }

    /// The notebook's local rows leave the space before its records come back (§5.2 "Move back"): its
    /// row is the learner's own again and its pool items name the learner's own sources, so the records
    /// that come back land on them.
    private func unhome(_ job: SpaceMoveJobRow) async throws {
        guard job.kind == .notebookBack else { return }
        try await store.perform { state in
            try state.replica.apply { _ in try SpaceMoveLocal.unhome(notebookID: job.wireID, spaceZoneKey: job.fromZone, connection: state.connection) }
        }
    }

    // MARK: After each round

    /// What any of the owner's Macs does after a round: resumes its unfinished moves, re-homes what landed
    /// late where a move took its parent, forwards late edits of a moved stub, and finishes its own move
    /// whose journal was lost. Passes never overlap. Returns the jobs it ran.
    @discardableResult
    func afterRound() async -> [Report] {
        guard !passing else { return [] }
        passing = true
        defer { passing = false }
        var reports: [Report] = []
        do {
            for job in try await store.perform({ try SpaceMoveJournal.unfinished($0.connection) }) {
                do {
                    reports.append(try await run(job.id))
                } catch {
                    Self.logger.error("A move could not go on: \(String(describing: error), privacy: .public)")
                }
            }
            reports += try await rehome()
            try await forwardStubEdits()
            _ = try await finishLostMoves()
        } catch {
            Self.logger.error("A move pass stopped: \(String(describing: error), privacy: .public)")
        }
        return reports
    }

    // MARK: Re-homing (§4.4 "Late children and grandchildren")

    /// Records that still land in a zone a move took their parent out of, or that name a record a move took
    /// out (an Exchange of a moved chat, a Comment of a moved Doc, an Entry, a chat, a Doc or a task of a
    /// moved notebook, or the moved record itself written again by a stale device), go where the parent
    /// is now: copied there (merged into a copy that is there already), listed in a `moveMaps` entry of
    /// their own, then deleted where they landed. No journal is needed: what moved, and where, is read
    /// from `moveMaps`, and each pass writes its own key, so two Macs re-homing at once lose nothing.
    @discardableResult
    func rehome() async throws -> [Report] {
        // Nothing can land late before the root lists a move.
        guard try await store.perform({ try $0.replica.personalRoot().map { !MoveMapIndex.entries(of: $0.envelope).isEmpty } ?? false }) else { return [] }
        var reports: [Report] = []
        let writerGuard = SpaceWriteGuard.Writer(user: try await transport.userRecordName(), permission: .readWrite, isOwner: true)
        // A late chat's Exchanges follow once the chat is listed: grandchildren take a second round.
        for _ in 0..<4 {
            let late = try await lateRecords(writerGuard)
            guard let first = late.first else { break }
            let id = "rehome.\(writer.deviceID).\(UUID().uuidString.lowercased())"
            let now = writer.clock()
            try await store.perform { state in
                try SpaceMoveJournal.begin(SpaceMoveJobRow(id: id, kind: .rehome, recordType: first.type, wireID: first.wireID, fromZone: first.fromZone,
                                                           toZone: first.toZone, state: .marked, pass: 0), now: now, state.connection)
                try SpaceMoveJournal.add(late, jobID: id, now: now, state.connection)
            }
            reports.append(try await run(id))
        }
        return reports
    }

    private func lateRecords(_ writerGuard: SpaceWriteGuard.Writer) async throws -> [SpaceMoveItem] {
        let moveMaps = moveMaps
        return try await store.perform { state in
            let connection = state.connection
            var zones = [Self.libraryKey]
            try connection.query("SELECT zone_key FROM ck_zones WHERE kind = 'space' AND database = 'private' AND salt_id IS NOT NULL ORDER BY zone_key", []) {
                if let key = $0.text(0) { zones.append(key) }
            }
            // What a move on this Mac is carrying, or closed as kept where it is, is not re-homed.
            var pending = Set<String>()
            try connection.query("""
                SELECT i.record_type || char(31) || i.wire_id || char(31) || i.from_zone FROM ck_move_items i JOIN ck_move_jobs j ON j.id = i.job_id
                WHERE i.state = 'kept' OR (j.state <> 'done' AND i.state NOT IN ('deleted', 'done'))
            """, []) { if let key = $0.text(0) { pending.insert(key) } }
            let placement = ReplicaPlacement(connection: connection)
            var late: [SpaceMoveItem] = []
            for zoneKey in zones {
                guard let zoneName = ProjectionZones.zone(ofKey: zoneKey)?.name else { continue }
                let records = try SpaceMoveScan.held(in: zoneKey, types: [.entry, .chat, .exchange, .artifact, .comment, .task], connection)
                // A chat stays whole where it is when the space refuses it or any of its Exchanges (§9.2).
                let kept = SpaceMoveScan.kept(records.filter { $0.type == .chat || $0.type == .exchange }, writer: writerGuard)
                for record in records where !kept.contains(record.key) {
                    // A member's draft of a space Doc is that member's own (§9.5): it never travels, whichever
                    // notebook it names (F22, as `SpaceMoveScan.notebook` keeps it).
                    if record.type == .artifact, let draft = record.fields["draftOf"], draft != .null { continue }
                    var destination = moveMaps.retarget(type: record.type.rawValue, id: record.wireID, from: zoneName)
                    if destination == nil, let parent = Self.parent(of: record) {
                        destination = moveMaps.retarget(type: parent.type.rawValue, id: parent.wireID, from: zoneName)
                    }
                    guard let destination, let target = SyncZoneName(destination), let targetKey = try placement.zoneKey(of: target),
                          targetKey != zoneKey, try state.replica.zone(key: targetKey)?.saltID != nil || !target.isSpace,
                          !pending.contains("\(record.type.rawValue)\u{1F}\(record.wireID)\u{1F}\(zoneKey)")
                    else { continue }
                    // What a space refuses stays where it is, as a private chat stays in `Library` (§9.2).
                    if target.isSpace, !SpaceWriteGuard.refusals(writing: record.type.rawValue, fields: record.fields, by: writerGuard).isEmpty { continue }
                    late.append(SpaceMoveItem(type: record.type, wireID: record.wireID, fromZone: zoneKey, toZone: targetKey, state: .queued))
                }
            }
            return late
        }
    }

    /// The record a child names as its parent: an Entry's notebook, a chat's, a Doc's and a task's
    /// notebook, an Exchange's chat, a Comment's Doc.
    private static func parent(of record: SpaceMoveHeld) -> SpaceMoveRecordKey? {
        let fields = record.fields
        switch record.type {
        case .entry:
            guard fields["containerKind"]?.stringValue == "notebook", let id = fields["containerID"]?.stringValue else { return nil }
            return SpaceMoveRecordKey(type: .notebook, wireID: id)
        case .chat, .task, .artifact:
            return fields["notebookID"]?.stringValue.map { SpaceMoveRecordKey(type: .notebook, wireID: $0) }
        case .exchange:
            return fields["chatID"]?.stringValue.map { SpaceMoveRecordKey(type: .chat, wireID: $0) }
        case .comment:
            return fields["artifactID"]?.stringValue.map { SpaceMoveRecordKey(type: .artifact, wireID: $0) }
        default:
            return nil
        }
    }

    // MARK: Late edits to a stub (§5.2)

    /// A device that had not seen the move may still write the stub's fields (a rename, an Instructions
    /// edit), with stamps of any age. Each such field goes to the space's copy once, verbatim with its
    /// stamp, so the ordinary merge decides (`ck_forwarded` lists what needs no forwarding: what the stub
    /// held when this Mac first knew it as one, and what was forwarded since). Returns how many copies
    /// took a forwarded field.
    @discardableResult
    func forwardStubEdits() async throws -> Int {
        let pending = try await store.perform { state -> [StubEdits] in
            let connection = state.connection
            let placement = ReplicaPlacement(connection: connection)
            var found: [StubEdits] = []
            for stub in try SpaceMoveScan.held(in: Self.libraryKey, types: [.notebook], connection) {
                guard stub.fields["status"]?.stringValue == "moved", let spaceID = stub.fields["movedTo"]?.stringValue,
                      let spaceKey = try placement.zoneKey(of: .space(spaceID)),
                      let copy = try SpaceMoveScan.held(.notebook, stub.wireID, in: spaceKey, connection)
                else { continue }
                var known = Set<String>()
                try connection.query("SELECT field, stamp FROM ck_forwarded WHERE record_name = ?", [.text(stub.recordName)]) {
                    known.insert(($0.text(0) ?? "") + "\u{1F}" + ($0.text(1) ?? ""))
                }
                if known.isEmpty {
                    // First sight of this stub on this Mac: what it holds is what its copy was made from.
                    try NotebookStubForwarding.recordBaseline(notebookID: stub.wireID, envelope: stub.envelope, connection: connection)
                    continue
                }
                let late = Self.stampedPaths(stub.envelope).filter { !known.contains($0.key + "\u{1F}" + $0.stamp.rawValue) }
                guard !late.isEmpty else { continue }
                found.append(StubEdits(copy: copy.envelope, late: Self.only(late, of: stub.envelope), zoneKey: spaceKey, recordName: stub.recordName,
                                       paths: late.map { ($0.key, $0.stamp.rawValue) }))
            }
            return found
        }
        var forwarded = 0
        for item in pending {
            let merged = SpaceMoveWriter.merge(server: item.copy, local: item.late, base: nil)
            if merged != item.copy {
                let target = try await zone(item.zoneKey)
                try await writer.absorb(try await writer.put([merged], in: target), in: item.zoneKey)
                forwarded += 1
            }
            try await store.perform { state in
                for (key, stamp) in item.paths {
                    try state.connection.execute(
                        "INSERT INTO ck_forwarded (record_name, field, stamp) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                        [.text(item.recordName), .text(key), .text(stamp)]
                    )
                }
            }
        }
        return forwarded
    }

    private struct StubEdits {
        let copy: SyncEnvelope
        let late: SyncEnvelope
        let zoneKey: String
        let recordName: String
        let paths: [(key: String, stamp: String)]
    }

    /// Every stamped path of a stub but its redirect, keyed as `ck_forwarded` keys them.
    private static func stampedPaths(_ envelope: SyncEnvelope) -> [(field: String, element: String?, key: String, stamp: SyncStamp)] {
        var paths: [(String, String?, String, SyncStamp)] = []
        for (field, stamps) in envelope.stamps.sorted(by: { $0.key < $1.key }) where !redirectFields.contains(field) {
            switch stamps {
            case .value(let stamp):
                paths.append((field, nil, field, stamp))
            case .elements(let elements):
                for (element, stamp) in elements.sorted(by: { $0.key < $1.key }) {
                    paths.append((field, element, OutboxFeeder.pathKey(StampedPath(field, element: element)), stamp))
                }
            }
        }
        return paths
    }

    /// `envelope` holding only `paths`, with their values and stamps.
    private static func only(_ paths: [(field: String, element: String?, key: String, stamp: SyncStamp)], of envelope: SyncEnvelope) -> SyncEnvelope {
        var late = envelope
        late.fields = [:]
        late.stamps = [:]
        for path in paths {
            if let element = path.element {
                var values = late.fields[path.field]?.objectValue ?? [:]
                var stamps: [String: SyncStamp] = if case .elements(let held)? = late.stamps[path.field] { held } else { [:] }
                values[element] = envelope.fields[path.field]?[element] ?? .null
                stamps[element] = path.stamp
                late.fields[path.field] = .object(values)
                late.stamps[path.field] = .elements(stamps)
            } else {
                late.fields[path.field] = envelope.fields[path.field] ?? .null
                late.stamps[path.field] = .value(path.stamp)
            }
        }
        return late
    }

    // MARK: A lost journal (§5.3 "Crash safety")

    /// This Mac's own moves (its device wrote `movingTo`) that have no journal here any more (a reinstall,
    /// a store restored from a copy) are finished once every child is found by name in the space. A move
    /// another Mac runs is that Mac's: `finishLostMove` finishes one when the learner asks.
    func finishLostMoves() async throws -> [String: LostMove] {
        let deviceID = writer.deviceID
        let orphans = try await store.perform { state -> [String] in
            try SpaceMoveScan.held(in: Self.libraryKey, types: [.notebook], state.connection).compactMap { notebook in
                guard notebook.fields["status"]?.stringValue != "moved", let spaceID = notebook.fields["movingTo"]?.stringValue, !spaceID.isEmpty,
                      case .value(let stamp)? = notebook.envelope.stamps["movingTo"], stamp.deviceID == deviceID,
                      try SpaceMoveJournal.jobs(moving: .notebook, notebook.wireID, state.connection).isEmpty
                else { return nil }
                return notebook.wireID
            }
        }
        var outcomes: [String: LostMove] = [:]
        for notebookID in orphans { outcomes[notebookID] = try await finishLostMove(notebookID) }
        return outcomes
    }

    /// Finishes a move whose journal is gone: after a fresh fetch of `Library` and the space, every child
    /// the back-pointers name (and every source a live Entry names) must be in the space by name; until
    /// then nothing is deleted, and both copies stay. Then a new journal takes over from the catch-up.
    @discardableResult
    func finishLostMove(_ notebookID: String) async throws -> LostMove {
        guard let spaceID = try await store.perform({ try SpaceMoveScan.held(.notebook, notebookID, in: Self.libraryKey, $0.connection) })?
            .fields["movingTo"]?.stringValue, !spaceID.isEmpty
        else { return .nothingToFinish }
        let spaceKey = try await ownedSpace(spaceID)
        try await fetch(Self.libraryKey)
        try await fetch(spaceKey)
        let space = try await zone(spaceKey)
        let writerGuard = SpaceWriteGuard.Writer(user: try await transport.userRecordName(), permission: .readWrite, isOwner: true)
        let travelling = try await store.perform { state -> [SpaceMoveHeld] in
            let records = try SpaceMoveScan.notebook(notebookID, in: Self.libraryKey, state.connection)
            let kept = SpaceMoveScan.kept(records, writer: writerGuard)
            let moving = records.filter { !kept.contains($0.key) }
            return moving + (try SpaceMoveScan.sources(namedBy: moving, in: Self.catalogKey, state.connection))
        }
        let ids = travelling.map { CloudRecordID(SpaceMoveWriter.recordName($0.type, $0.wireID, in: space), in: space.zoneID) }
        var missing = 0
        for start in stride(from: 0, to: ids.count, by: SyncSchema.Limits.batchMaxRecords) {
            let batch = Array(ids[start..<min(start + SyncSchema.Limits.batchMaxRecords, ids.count)])
            let found = try await transport.records(batch, in: space.database, desiredKeys: [])
            missing += batch.filter { if case .success? = found[$0] { return false } else { return true } }.count
        }
        guard missing == 0 else {
            Self.logger.info("A move without its journal waits: \(missing) records are not in the space yet")
            return .waiting(missing: missing)
        }
        let id = "lost.\(notebookID).\(spaceID)"
        let now = writer.clock()
        try await store.perform { state in
            try SpaceMoveJournal.begin(SpaceMoveJobRow(id: id, kind: .notebook, recordType: .notebook, wireID: notebookID, fromZone: Self.libraryKey,
                                                       toZone: spaceKey, state: .marked, pass: 0), now: now, state.connection)
            try SpaceMoveJournal.add(travelling.map {
                SpaceMoveItem(type: $0.type, wireID: $0.wireID, fromZone: SpaceMoveItem.copiedTypes.contains($0.type) ? Self.catalogKey : Self.libraryKey,
                              toZone: spaceKey, state: SpaceMoveItem.copiedTypes.contains($0.type) ? .done : .copied)
            }, jobID: id, now: now, state.connection)
        }
        try await run(id)
        return .finished
    }

    // MARK: Zones

    private func zone(_ zoneKey: String) async throws -> BlobZone {
        guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: zoneKey, in: $0) }) else { throw SpaceMoveError.notHeld("zone \(zoneKey)") }
        return zone
    }

    private func heldSpaceKey(_ spaceID: String) async throws -> String? {
        let key = ReplicaZone.key(database: .private, zoneName: SyncSchema.spaceZonePrefix + spaceID)
        return try await store.perform { try $0.replica.zone(key: key)?.saltID != nil ? key : nil }
    }

    /// The zone key of a space this account owns and this Mac holds with its root.
    private func ownedSpace(_ spaceID: String) async throws -> String {
        guard let key = try await heldSpaceKey(spaceID) else { throw SpaceMoveError.notHeld("space \(spaceID)") }
        return key
    }

    /// Who a copy into a space names as its maker: the space root's owner, this account.
    private func owner(_ zoneKey: String?) async throws -> SyncPerson {
        if let zoneKey, let owner = try await store.perform({ state in
            try state.replica.record(zoneKey: zoneKey, recordName: SyncSchema.rootRecordName)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }?.fields["owner"].flatMap(SyncPerson.init(json:))
        }) {
            return owner
        }
        return SyncPerson(user: try await transport.userRecordName(), name: "")
    }
}

/// The move journals running in this process, by job id.
final class SpaceMoveRunning: @unchecked Sendable {
    static let shared = SpaceMoveRunning()
    private let lock = NSLock()
    private var ids = Set<String>()

    func claim(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
    func release(_ id: String) { lock.withLock { _ = ids.remove(id) } }
}

// MARK: - The local rows of a move

/// The Mac's local rows across a move (docs/cloudkit-schema-design.md §4.3, §5.3): a notebook keeps its
/// row and its id. Moving into a space, the space's copy of the notebook lands on the learner's own row
/// (WP15's `SpaceRows.placement` would otherwise give it a row of its own beside the personal one), and
/// each pool item of it comes to name the space's copy of its source. Moving back, the row is the
/// learner's own again and its pool items name the learner's own sources. Synchronous SQL on the store's
/// connection, inside an apply, so nothing it writes is sent.
enum SpaceMoveLocal {
    /// Whether the notebook row `localID` belongs to a notebook moving or moved into `spaceID`, as the
    /// personal library's record of it says; if so, the row takes the space's team id and true is returned.
    static func adopt(table: String, localID: String, spaceID: String, teamID: String, connection: SQLiteConnection) throws -> Bool {
        guard table == "learning_goals",
              try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ? AND team_id IS NULL)", [.text(localID)]) == 1,
              let record = try ReplicaStore(connection: connection).record(zoneKey: PrivateSyncZones.libraryKey, recordType: SyncRecordType.notebook.rawValue,
                                                                         wireID: localID),
              let envelope = try? SyncEnvelope(storedPayload: record.payload),
              envelope.fields["movingTo"]?.stringValue == spaceID || envelope.fields["movedTo"]?.stringValue == spaceID
        else { return false }
        try connection.execute("UPDATE learning_goals SET team_id = ? WHERE id = ?", [.text(teamID), .text(localID)])
        return true
    }

    /// A pool item of `notebook` that still names the learner's own copy of a source (a notebook that
    /// moved here) comes to name the space's copy `source` of the same work, keeping its row.
    static func adoptPoolItem(notebook: String, source: String, sourceWireID: String, connection: SQLiteConnection) throws {
        try connection.execute("""
            UPDATE learning_goal_items SET source_id = ?1
            WHERE goal_id = ?2 AND source_id IN (SELECT id FROM sources WHERE wire_key = ?3 AND team_id IS NULL AND id <> ?1)
              AND NOT EXISTS (SELECT 1 FROM learning_goal_items WHERE goal_id = ?2 AND source_id = ?1)
        """, [.text(source), .text(notebook), .text(sourceWireID)])
    }

    /// A notebook whose `Library` record is live again (a move back, §5.2) while this Mac's row still
    /// stands in the space the notebook left: the row leaves that space (`unhome`), so the record lands
    /// on the learner's own row. A record that still says `movingTo` belongs to a move under way.
    static func comeBack(_ record: ProjectionRecordRef, fields: [String: SyncJSON], connection: SQLiteConnection) throws {
        let redirects = ["movingTo", "movedTo", "mergedInto"].compactMap { fields[$0]?.stringValue }.filter { !$0.isEmpty }
        guard !record.zone.isSpace, record.type == .notebook, redirects.isEmpty,
              try connection.scalarInteger(
                  "SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ? AND team_id IS NOT NULL)", [.text(record.localID)]
              ) == 1,
              let spaceZone = try connection.scalarText("""
                  SELECT zone_key FROM ck_identity WHERE record_type = ? AND wire_id = ? AND local_id = ? AND zone_key <> ?
                  ORDER BY zone_key LIMIT 1
              """, [.text(SyncRecordType.notebook.rawValue), .text(record.wireID), .text(record.localID), .text(record.zoneKey)])
        else { return }
        try unhome(notebookID: record.wireID, spaceZoneKey: spaceZone, connection: connection)
    }

    /// The notebook's row leaves the space `spaceZoneKey`: it is the learner's own again, each pool item
    /// names the learner's own source of the same work (where the learner has one), and the identities of
    /// the notebook and its Entries in the space go.
    static func unhome(notebookID: String, spaceZoneKey: String, connection: SQLiteConnection) throws {
        let local = try connection.scalarText(
            "SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(spaceZoneKey), .text(SyncRecordType.notebook.rawValue), .text(notebookID)]
        ) ?? notebookID
        try connection.execute("UPDATE learning_goals SET team_id = NULL WHERE id = ?", [.text(local)])
        var items: [(id: String, wire: String)] = []
        try connection.query("""
            SELECT i.id, s.wire_key FROM learning_goal_items i JOIN sources s ON s.id = i.source_id
            WHERE i.goal_id = ? AND s.team_id IS NOT NULL
        """, [.text(local)]) { row in
            if let id = row.text(0), let wire = row.text(1) { items.append((id, wire)) }
        }
        for item in items {
            guard let personal = try connection.scalarText(
                "SELECT id FROM sources WHERE wire_key = ? AND team_id IS NULL ORDER BY id LIMIT 1", [.text(item.wire)]
            ) else { continue }
            if try connection.scalarInteger(
                "SELECT EXISTS(SELECT 1 FROM learning_goal_items WHERE goal_id = ? AND source_id = ?)", [.text(local), .text(personal)]
            ) == 1 {
                try connection.execute("DELETE FROM learning_goal_items WHERE id = ?", [.text(item.id)])
            } else {
                try connection.execute("UPDATE learning_goal_items SET source_id = ? WHERE id = ?", [.text(personal), .text(item.id)])
            }
        }
        try connection.execute("""
            DELETE FROM ck_identity WHERE zone_key = ? AND ((record_type = 'Notebook' AND wire_id = ?) OR (record_type = 'Entry' AND substr(wire_id, 1, ?) = ?))
        """, [.text(spaceZoneKey), .text(notebookID), .integer(Int64(("en:" + notebookID + ":").count)), .text("en:" + notebookID + ":")])
    }
}
