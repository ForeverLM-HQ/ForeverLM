import Foundation
import OSLog

// MARK: - The cutover seed (docs/cloudkit-schema-design.md §13.4)

/// Where the seed is, for the status Settings › iCloud shows (§13.4 "Your other Mac is moving your
/// library (n of m)").
enum CutoverSeedPhase: Equatable, Sendable {
    case claiming
    case waiting(holder: String)
    case pass(SeedPass)
    case recoveringBytes
    case canary
    case satellites
    case teams
    case finishing
    case complete
}

/// Why the seed stopped before it finished, with the cause shown (§13.4 step 2).
enum CutoverSeedStop: Equatable, Sendable {
    case noRoot
    /// The canary missed names the seeder had saved and had acknowledged: no asset is uploaded.
    case canaryMissing(count: Int)
    /// iCloud storage is full: satellites stop, metadata continues.
    case quotaExceeded
    /// Another Mac holds the claim now.
    case lostClaim
    /// The engine could not send what it held (a purge stopped the database, iCloud refused): the seed
    /// resumes from its cursor on a later round.
    case sendsStalled
    /// Every pass ran, yet records the library's rows feed are still in the outbox and not on the server
    /// (`SeedLeftovers`): the canary and the manifest wait, and a later round sends them and goes on.
    case unsent(count: Int)
}

enum CutoverSeedOutcome: Equatable, Sendable {
    /// This Mac holds no library: it never claims.
    case noLibrary
    /// Another Mac is seeding; look again later.
    case waiting(holder: String)
    /// The metadata is complete (or the seed is): this Mac reconciles instead (§13.5).
    case secondMac
    case complete(records: Int)
    case stopped(CutoverSeedStop)
}

struct CutoverSeedConfiguration: Sendable {
    var batchSize = 200
    var sendAttempts = 8
    /// Between the last record and the canary's walk (§13.4 step 2).
    var canaryPause: TimeInterval = 600
    var claimRenewInterval: TimeInterval = 600
}

/// Everything the seeder reaches. The closures are the engine's: in the app the coordinator's, in the suites
/// `PrivateSyncEngine`'s.
struct CutoverSeedEnvironment: Sendable {
    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let registry: ProjectionRegistry
    let blobs: BlobStore
    let writer: MaintenanceWriter
    let deviceID: String
    /// Sends what the outbox holds through the engine.
    var send: @Sendable () async throws -> Void
    let pendingCount: @Sendable () async -> Int
    /// Whether this Mac holds the library (`ck_activation`): a Mac that holds none never claims.
    let holdsLibrary: @Sendable () async -> Bool
    var clock: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var configuration = CutoverSeedConfiguration()
    /// Why the pacer holds the engine, if it does (quota stops the satellites).
    var pause: @Sendable () async -> SyncPacerState.PauseReason? = { nil }
    /// Runs before a pass's first row, on the store (P1 chooses each Doc's body, §13.4 P5).
    var prepare: @Sendable (SeedPass, PrivateSyncLocalState) throws -> Void = { _, _ in }
    /// A complete fetch of `Library`, `Catalog` and every space; false when it did not reach the end. A
    /// reconcile compares the library with the server's, so it never starts on a partial fetch (§13.5).
    var fetchAll: @Sendable () async throws -> Bool = { true }
    /// P4b and P5: bytes recovered from the old container, then satellites uploaded (`CutoverSatellites`).
    var recoverBytes: (@Sendable () async throws -> Void)?
    var uploadSatellites: (@Sendable () async throws -> CutoverSatelliteTotals)?
    /// P6: `TeamToSpace` (the key names the pass's manifest delta).
    var runTeams: (@Sendable (_ passKey: String) async throws -> Void)?
    var progress: @Sendable (CutoverSeedPhase) -> Void = { _ in }
}

struct CutoverSatelliteTotals: Equatable, Sendable {
    var satellites = 0
    var bytes: Int64 = 0
}

/// The one Mac that moves the library into the new container: claims the seed,
/// walks the library's rows family by family, runs the canary, and uploads satellites (§13.4). It holds the
/// claim and the maintenance lease while it works and renews both; a Mac that finds another's live claim
/// waits, and one that finds the metadata complete reconciles instead (`CutoverReconcile`, §13.5).
actor CutoverSeeder {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CutoverSeed")
    static let teamsPassID = "p6"

    private let env: CutoverSeedEnvironment
    private var lastRenew: Date?

    init(_ environment: CutoverSeedEnvironment) {
        env = environment
    }

    private var seedKey: String { SeedManifestPending.seedPassKey(env.deviceID) }
    private var manifestWriter: SeedManifestWriter { SeedManifestWriter(store: env.store, blobs: env.blobs, writer: env.writer) }

    func run() async throws -> CutoverSeedOutcome {
        env.progress(.claiming)
        guard let library = try await libraryZone() else { return .stopped(.noRoot) }
        var claimed: CutoverClaimDecision?
        for _ in 0..<3 {
            guard let root = try await env.writer.refreshRoot(in: library) else { return .stopped(.noRoot) }
            let decision = CutoverClaimDecision.decide(
                CutoverRootState(root: root), me: env.deviceID, holdsLibrary: await env.holdsLibrary(), now: SyncTime.milliseconds(env.clock())
            )
            switch decision {
            case .noLibrary:
                return .noLibrary
            case .wait(let holder, _):
                env.progress(.waiting(holder: holder))
                return .waiting(holder: holder)
            case .secondMac:
                return .secondMac
            case .resume:
                guard try await renewClaim(in: library, force: true) else { return .stopped(.lostClaim) }
                claimed = decision
            case .claim, .takeOver:
                if try await claim(decision, in: library) { claimed = decision }
            }
            if claimed != nil { break }
        }
        guard let decision = claimed else { return .waiting(holder: "") }
        let outcome = try await seed(decision, in: library)
        // The held families go once the seed is over or no longer this Mac's; a stop that resumes keeps them.
        switch outcome {
        case .complete, .stopped(.lostClaim), .stopped(.noRoot): await releaseGate()
        default: break
        }
        return outcome
    }

    // MARK: Claim

    private func libraryZone() async throws -> BlobZone? {
        try await env.store.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: $0) }
    }

    /// Claims the seed and the maintenance lease in one compare-and-set save of the root (§13.4 step 1).
    private func claim(_ decision: CutoverClaimDecision, in library: BlobZone) async throws -> Bool {
        let now = env.clock()
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        patch.changes["seedClaim"] = .value(Self.claimValue(device: env.deviceID, at: now))
        patch.changes["maintenanceLease"] = .value(MaintenanceLease.value(device: env.deviceID, at: now))
        var seed: [String: SyncJSON] = ["state": .string("seeding")]
        if decision == .claim { seed["startedAt"] = SyncJSON(SyncTime.milliseconds(now)) }
        patch.changes["seed"] = .elements(seed)
        let outcome = try await env.writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first
        if outcome == .saved || outcome == .unchanged {
            lastRenew = now
            Self.logger.info("This Mac holds the seed claim")
            return true
        }
        return false
    }

    static func claimValue(device: String, at date: Date) -> SyncJSON {
        .object(["device": .string(device), "leaseUntil": SyncJSON(SyncTime.milliseconds(date.addingTimeInterval(ZoneBootstrap.seedLease)))])
    }

    /// Renews the claim (30-minute lease, every 10 minutes by the holder) and, when less than half of it is
    /// left, the maintenance lease with it. False when the root names another Mac as the seeder.
    private func renewClaim(in library: BlobZone, force: Bool = false) async throws -> Bool {
        let now = env.clock()
        if !force, let lastRenew, now.timeIntervalSince(lastRenew) < env.configuration.claimRenewInterval { return true }
        for _ in 0..<3 {
            guard let root = try await env.writer.refreshRoot(in: library) else { return false }
            let state = CutoverRootState(root: root)
            guard state.claimDevice == env.deviceID else { return false }
            var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
            patch.changes["seedClaim"] = .value(Self.claimValue(device: env.deviceID, at: now))
            if let lease = MaintenanceLease.holder(in: root), lease.device == env.deviceID,
               lease.leaseUntil - SyncTime.milliseconds(now) >= Int64(MaintenanceLease.renewWithin * 1_000) {
                // The lease has time left.
            } else {
                patch.changes["maintenanceLease"] = .value(MaintenanceLease.value(device: env.deviceID, at: now))
            }
            // Unchanged: the claim already says this, to the millisecond.
            let outcome = try await env.writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first
            if outcome == .saved || outcome == .unchanged {
                lastRenew = now
                return true
            }
        }
        return false
    }

    /// Saves root fields by compare-and-set, deciding again on the root as the server holds it when a
    /// save loses (the maintenance lease's renewal writes the same record).
    private func saveRoot(_ changes: [String: RecordPatch.Change], in library: BlobZone) async throws -> Bool {
        for attempt in 0..<4 {
            var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
            patch.changes = changes
            let outcome = try await env.writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first
            if outcome == .saved || outcome == .unchanged { return true }
            guard attempt < 3, try await env.writer.refreshRoot(in: library) != nil else { break }
        }
        return false
    }

    // MARK: The seed

    private func seed(_ decision: CutoverClaimDecision, in library: BlobZone) async throws -> CutoverSeedOutcome {
        let runStartedAt = env.clock().timeIntervalSinceReferenceDate
        let root = try await env.store.perform { try $0.replica.personalRoot()?.envelope }
        let takingOver: Bool
        if case .takeOver = decision { takingOver = true } else { takingOver = false }
        let journal = try await env.store.perform { try CutoverJournal.read($0.connection) }

        let fallback = journal.catchUpAt ?? journal.startedAt ?? env.clock().timeIntervalSinceReferenceDate
        let decider = try await makeDecider(takeover: takingOver)
        // An edit made while the seed runs waits for its family's pass to begin (§13.4 step 5).
        try await holdUnbegunPasses(except: nil)
        do {
            for pass in SeedPass.allCases {
                guard try await renewClaim(in: library) else { return .stopped(.lostClaim) }
                env.progress(.pass(pass))
                try await holdUnbegunPasses(except: pass)
                try await runPass(pass, decider: decider, fallbackTime: fallback, library: library)
            }
        } catch CutoverSeedError.lostClaim {
            return .stopped(.lostClaim)
        } catch SeedPassError.engineStalled {
            return .stopped(.sendsStalled)
        }
        // The metadata is complete only when nothing the passes handed the outbox is left behind.
        if let stop = try await leftovers(runStartedAt: runStartedAt) { return .stopped(stop) }

        // P4b, then the canary: no asset is uploaded before it passes (§13.4 step 2).
        let manifestWritten = root.map { CutoverRootState(root: $0).metadataCompleteAt != nil } ?? false
        if !manifestWritten {
            env.progress(.recoveringBytes)
            try await env.recoverBytes?()
            if let stop = try await canary() { return .stopped(stop) }
            guard try await publishMetadataComplete(in: library) else { return .stopped(.lostClaim) }
        }

        env.progress(.satellites)
        var totals = CutoverSatelliteTotals()
        if let upload = env.uploadSatellites {
            if await isQuotaStopped() { return .stopped(.quotaExceeded) }
            do {
                totals = try await upload()
            } catch CutoverSeedError.quotaExceeded {
                return .stopped(.quotaExceeded)
            }
        }

        // P6 runs after the manifest was written, so it lists the space records in a delta of its own.
        if let teams = env.runTeams {
            env.progress(.teams)
            let passKey = "\(env.deviceID).\(Self.teamsPassID)"
            try await teams(passKey)
            try await runSpacePass(fallbackTime: fallback, library: library)
            try await flushDelta(passKey)
        }
        return try await finish(totals, in: library)
    }

    /// First seeding on an empty server sends everything; a seed resumed on records the server already
    /// holds, or taken over, reconciles (§13.5): a held record keeps the server's value.
    private func makeDecider(takeover: Bool) async throws -> SeedRowDecider {
        let holds = try await env.store.perform { state in
            try state.connection.scalarInteger("""
                SELECT EXISTS(SELECT 1 FROM ck_records WHERE zone_key IN (?, ?) AND record_type NOT IN ('ZoneRoot', 'Device', 'Setting'))
            """, [.text(PrivateSyncZones.libraryKey), .text(PrivateSyncZones.key(PrivateSyncZones.catalog))]) == 1
        }
        guard holds || takeover else { return .seed }
        let manifest: Set<SeedManifestEntry>
        do {
            manifest = try await SeedManifestReader(store: env.store, blobs: env.blobs).load()
        } catch {
            Self.logger.error("Reading the seed manifest failed, reconciling without it: \(error.localizedDescription, privacy: .public)")
            manifest = []
        }
        return .reconcile(manifest: manifest, deltaPassKey: nil)
    }

    private func runPass(_ pass: SeedPass, decider: SeedRowDecider, fallbackTime: Double, library: BlobZone) async throws {
        let done = try await env.store.perform { state in
            try SeedCursors.isDone("seed.\(pass.rawValue)", in: state.connection)
        }
        if done { return }
        try await env.store.perform { state in try self.env.prepare(pass, state) }
        let runner = passRunner(decider: decider, prefix: "seed")
        try await runner.run(pass, fallbackTime: fallbackTime) { [self] _ in
            guard try await renewClaim(in: library) else { throw CutoverSeedError.lostClaim }
        }
        let now = env.clock()
        try await env.store.perform { try SeedCursors.save("seed.\(pass.rawValue)", cursor: nil, completedAt: now.timeIntervalSinceReferenceDate, now: now, in: $0.connection) }
    }

    /// Holds the families whose pass has not begun: no cursor row of theirs exists, and `running` is about to.
    private func holdUnbegunPasses(except running: SeedPass?) async throws {
        let now = env.clock()
        try await env.store.perform { state in
            var unbegun: [SeedPass] = []
            for pass in SeedPass.allCases where pass != running {
                let begun = try state.connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_seed_cursor WHERE pass LIKE ?)", [.text("seed.\(pass.rawValue).%")]) == 1
                if !begun { unbegun.append(pass) }
            }
            try CutoverSeedGate.hold(unbegun, in: state.connection, now: now)
        }
    }

    private func releaseGate() async {
        do {
            _ = try await env.store.perform { try CutoverSeedGate.hold([], in: $0.connection) }
        } catch {
            Self.logger.error("The seed gate was not released: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func passRunner(decider: SeedRowDecider, prefix: String) -> SeedPassRunner {
        var runner = SeedPassRunner(
            store: env.store, registry: env.registry, send: env.send, pendingCount: env.pendingCount, decider: decider, cursorPrefix: prefix
        )
        runner.batchSize = env.configuration.batchSize
        runner.sendAttempts = env.configuration.sendAttempts
        runner.clock = env.clock
        return runner
    }

    /// P6's rows: what the teams' spaces hold copies of, sent by SpaceSync once the zone has its root.
    private func runSpacePass(fallbackTime: Double, library: BlobZone) async throws {
        let runner = passRunner(decider: .spaces, prefix: "spaces")
        for pass in SeedPass.allCases {
            try await runner.run(pass, fallbackTime: fallbackTime)
        }
    }

    private func flushDelta(_ passKey: String) async throws {
        for _ in 0..<20 {
            switch try await manifestWriter.flushDelta(passKey: passKey) {
            case .nothingPending, .written, .lost:
                return
            case .waiting:
                try await env.send()
                await env.sleep(1)
            }
        }
    }

    /// Sends what the outbox holds once more, then looks for records the passes left unsent.
    private func leftovers(runStartedAt: Double) async throws -> CutoverSeedStop? {
        try await env.send()
        let now = env.clock().timeIntervalSinceReferenceDate
        let registry = env.registry
        let found = try await env.store.perform { state in
            try SeedLeftovers.unsent(registry: registry, connection: state.connection, runStartedAt: runStartedAt, now: now)
        }
        guard found.count > 0 else { return nil }
        let sample = found.sample.map { "\($0.type.rawValue) \($0.wireID)" }.joined(separator: ", ")
        Self.logger.error("The passes left \(found.count) records unsent: \(sample, privacy: .private)")
        return .unsent(count: found.count)
    }

    // MARK: The canary

    /// Pauses, then walks `Library` and `Catalog` from a nil change token with no desired keys and checks
    /// sets, not counts: every record name this Mac saved and had acknowledged must be there, except
    /// records deleted locally during the seed. Extra names (a Device record, another Mac's writes) are
    /// logged by type and never fatal (§13.4 step 2).
    func canary() async throws -> CutoverSeedStop? {
        env.progress(.canary)
        if env.configuration.canaryPause > 0 { await env.sleep(env.configuration.canaryPause) }
        try await env.send()
        var onServer = Set<String>()
        for zone in [PrivateSyncZones.library, PrivateSyncZones.catalog] {
            var token: CloudChangeToken?
            var more = true
            while more {
                let walked: Result<CloudZoneChanges, CloudError>
                do {
                    walked = try await env.transport.zoneChanges(zone, in: .private, since: token, desiredKeys: [])
                } catch let error as CloudError where error.code == .quotaExceeded {
                    return .quotaExceeded
                }
                switch walked {
                case .success(let changes):
                    onServer.formUnion(changes.modified.map(\.id.recordName))
                    token = changes.changeToken
                    more = changes.moreComing
                case .failure(let error):
                    if error.code == .quotaExceeded { return .quotaExceeded }
                    throw error
                }
            }
        }
        let missing = try await env.store.perform { state -> Int in
            var missing = 0
            try state.connection.query("""
                SELECT record_name FROM ck_records WHERE zone_key IN (?, ?) AND record_name NOT IN
                    (SELECT record_name FROM ck_pending_deletes)
            """, [.text(PrivateSyncZones.libraryKey), .text(PrivateSyncZones.key(PrivateSyncZones.catalog))]) { row in
                if let name = row.text(0), !onServer.contains(name) { missing += 1 }
            }
            return missing
        }
        if missing > 0 {
            Self.logger.error("The canary found \(missing) saved records missing on the server")
            return .canaryMissing(count: missing)
        }
        return nil
    }

    private func isQuotaStopped() async -> Bool {
        if case .quotaExceeded? = await env.pause() { return true }
        return false
    }

    /// Passing writes the manifest and sets `seed.canaryPassedAt`, `seed.metadataCompleteAt` and
    /// `seed.manifest` in one save: from then on other Macs reconcile metadata and the web and the hosted
    /// MCP switch for this account while satellites upload.
    private func publishMetadataComplete(in library: BlobZone) async throws -> Bool {
        let (file, _) = try await manifestWriter.uploadSeedManifest(passKey: seedKey)
        let milliseconds = SyncJSON(SyncTime.milliseconds(env.clock()))
        return try await saveRoot(["seed": .elements([
            "canaryPassedAt": milliseconds, "metadataCompleteAt": milliseconds, "manifest": file.value,
        ])], in: library)
    }

    // MARK: Finish

    /// `seed.state = complete`, `completedAt` and `counts`: three keys of the `seed` map, so
    /// `metadataCompleteAt`, `canaryPassedAt` and `manifest` stay. The claim lapses.
    private func finish(_ totals: CutoverSatelliteTotals, in library: BlobZone) async throws -> CutoverSeedOutcome {
        env.progress(.finishing)
        let records = try await env.store.perform { state -> Int in
            Int(try state.connection.scalarInteger(
                "SELECT COUNT(*) FROM ck_records WHERE zone_key IN (?, ?) AND record_type <> 'ZoneRoot'",
                [.text(PrivateSyncZones.libraryKey), .text(PrivateSyncZones.key(PrivateSyncZones.catalog))]
            ) ?? 0)
        }
        let now = env.clock()
        let counts = SyncJSON.object(["records": SyncJSON(records), "satellites": SyncJSON(totals.satellites), "bytes": SyncJSON(totals.bytes)])
        let saved = try await saveRoot([
            "seed": .elements(["state": .string("complete"), "completedAt": SyncJSON(SyncTime.milliseconds(now)), "counts": counts]),
            "seedClaim": .value(.object(["device": .string(env.deviceID), "leaseUntil": SyncJSON(SyncTime.milliseconds(now))])),
        ], in: library)
        guard saved else { return .stopped(.lostClaim) }
        env.progress(.complete)
        return .complete(records: records)
    }
}

enum CutoverSeedError: Error, Equatable {
    case lostClaim
    case quotaExceeded
}

/// The parts of `ck_activation` the seed reads.
enum CutoverJournal {
    struct Read: Equatable, Sendable {
        var mode: String?
        var freshReason: String?
        var startedAt: Double?
        var catchUpAt: Double?
        var account: String?
        var activatedAt: Double?
    }

    static func read(_ connection: SQLiteConnection) throws -> Read {
        var found = Read()
        try connection.query("SELECT mode, fresh_reason, started_at, catch_up_at, account, activated_at FROM ck_activation WHERE id = 1", []) { row in
            found = Read(mode: row.text(0), freshReason: row.text(1), startedAt: row.real(2), catchUpAt: row.real(3), account: row.text(4), activatedAt: row.real(5))
        }
        return found
    }
}
