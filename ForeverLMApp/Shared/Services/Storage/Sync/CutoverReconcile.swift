import Foundation
import OSLog

// MARK: - Other Macs (docs/cloudkit-schema-design.md §13.5)

enum CutoverReconcileOutcome: Equatable, Sendable {
    /// This Mac holds no library: it has nothing to reconcile (it joins as a new device).
    case noLibrary
    /// The seed's metadata is not complete: the Mac sends nothing and waits.
    case waitingForSeed
    /// The fetch did not reach the end, so the library cannot be compared with the server's.
    case fetchIncomplete
    /// The library was compared with the server's: `uploaded` records the server lacked and the manifest did
    /// not list, `deleted` records the manifest lists and the server lacks. `satellites` is false while the
    /// seeder holds the claim and this Mac's own cursor for satellites cannot run yet.
    case reconciled(uploaded: Int, deleted: Int, satellites: Bool)
}

/// A Mac that holds the library and finds the seed's metadata complete reconciles record by record against
/// the server, the seed manifest and the manifest deltas (§13.5). The server's values already took over in
/// the engine's inbound merge, so what is left is exactly:
/// - a record the server holds keeps the server's fields; only a pending change (a kept old-world change, an
///   edit made while waiting, an unacknowledged patch) is still this Mac's, merged by stamps;
/// - a local record the server lacks and the manifest or a delta lists was in the new world and deleted
///   there: deleted locally, never uploaded;
/// - one in neither was never in the new world: uploaded, and listed in this Mac's manifest delta so a later
///   new-world deletion lasts even against a copy of this store;
/// - satellites the server lacks are uploaded after the existence check, once this Mac can take the claim.
actor CutoverReconcile {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CutoverReconcile")
    static let passIDScope = "reconcile.passID"
    static let doneScope = "reconcile.done"
    static let satellitesScope = "reconcile.satellitesDone"

    private let env: CutoverSeedEnvironment

    init(_ environment: CutoverSeedEnvironment) {
        env = environment
    }

    private var manifestWriter: SeedManifestWriter { SeedManifestWriter(store: env.store, blobs: env.blobs, writer: env.writer) }

    func run() async throws -> CutoverReconcileOutcome {
        guard await env.holdsLibrary() else { return .noLibrary }
        guard let library = try await env.store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: $0) }),
              let root = try await env.writer.refreshRoot(in: library),
              CutoverRootState(root: root).metadataCompleteAt != nil
        else { return .waitingForSeed }

        let finished = try await env.store.perform { try $0.replica.engineState(Self.doneScope) != nil }
        var uploaded = 0
        var deleted = 0
        if !finished {
            guard try await env.fetchAll() else { return .fetchIncomplete }
            let tally = try await reconcileRows()
            uploaded = tally.enqueued
            deleted = tally.deleted
        }
        let satellites = try await uploadOwnSatellites(in: library)
        return .reconciled(uploaded: uploaded, deleted: deleted, satellites: satellites)
    }

    /// Compares every row of the library with the server's, one bounded batch at a time, and lists what it
    /// uploaded in this pass's manifest delta.
    private func reconcileRows() async throws -> SeedPassTally {
        let passID = try await passIdentity()
        let passKey = "\(env.deviceID).\(passID)"
        let manifest = try await SeedManifestReader(store: env.store, blobs: env.blobs).load()
        let journal = try await env.store.perform { try CutoverJournal.read($0.connection) }
        let fallback = journal.catchUpAt ?? journal.startedAt ?? env.clock().timeIntervalSinceReferenceDate
        var runner = SeedPassRunner(
            store: env.store, registry: env.registry, send: env.send, pendingCount: env.pendingCount,
            decider: .reconcile(manifest: manifest, deltaPassKey: passKey), cursorPrefix: "reconcile.\(passID)"
        )
        runner.batchSize = env.configuration.batchSize
        runner.sendAttempts = env.configuration.sendAttempts
        runner.clock = env.clock
        var total = SeedPassTally()
        for pass in SeedPass.allCases {
            total.add(try await runner.run(pass, fallbackTime: fallback))
        }
        for _ in 0..<20 {
            switch try await manifestWriter.flushDelta(passKey: passKey) {
            case .nothingPending, .written, .lost:
                let now = env.clock()
                try await env.store.perform { try $0.replica.setEngineState(Self.doneScope, Data("\(now.timeIntervalSinceReferenceDate)".utf8), now: now) }
                return total
            case .waiting:
                try await env.send()
                // With nothing left to send, a listed record the server still lacks was never created (a row
                // feeds a Mark with nothing to say): it is not part of the delta, and waiting would hold it for ever.
                if await env.pendingCount() == 0 { try await manifestWriter.dropUncreated(passKey: passKey) }
            }
        }
        // Not every create was acknowledged yet: the rows stay pending and the next round lists them.
        return total
    }

    /// One pass key per reconcile, kept across a relaunch so a resumed run lists into the same delta.
    private func passIdentity() async throws -> String {
        let now = env.clock()
        return try await env.store.perform { state in
            if let data = try state.replica.engineState(Self.passIDScope), let text = String(data: data, encoding: .utf8) { return text }
            let id = "reconcile\(Int(now.timeIntervalSince1970))"
            try state.replica.setEngineState(Self.passIDScope, Data(id.utf8), now: now)
            return id
        }
    }

    /// This Mac's own cursor for satellites the server lacks runs when it can take the claim (the seeder
    /// holds it until it finishes or lets it lapse), leaving `seed.state` as it is so no banner appears
    /// elsewhere; the claim is released when the uploads are done. False while the claim is another Mac's.
    private func uploadOwnSatellites(in library: BlobZone) async throws -> Bool {
        let done = try await env.store.perform { try $0.replica.engineState(Self.satellitesScope) != nil }
        if done { return true }
        guard let upload = env.uploadSatellites else { return true }
        guard let root = try await env.writer.refreshRoot(in: library) else { return false }
        let state = CutoverRootState(root: root)
        let now = env.clock()
        if let holder = state.claimDevice, holder != env.deviceID, state.claimIsLive(at: SyncTime.milliseconds(now)) { return false }
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        patch.changes["seedClaim"] = .value(CutoverSeeder.claimValue(device: env.deviceID, at: now))
        guard try await env.writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first == .saved else { return false }
        var completed = true
        do {
            _ = try await upload()
        } catch CutoverSeedError.quotaExceeded {
            completed = false
        } catch {
            await release(in: library)
            throw error
        }
        await release(in: library)
        guard completed else { return false }
        try await env.store.perform { try $0.replica.setEngineState(Self.satellitesScope, Data("done".utf8), now: now) }
        return true
    }

    private func release(in library: BlobZone) async {
        let now = env.clock()
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        patch.changes["seedClaim"] = .value(.object(["device": .string(env.deviceID), "leaseUntil": SyncJSON(SyncTime.milliseconds(now))]))
        do {
            _ = try await env.writer.save([MaintenanceWriter.Write(zone: library, patch: patch)])
        } catch {
            Self.logger.error("Releasing the seed claim failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
