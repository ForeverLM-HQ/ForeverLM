import Foundation
import OSLog

// MARK: - The marker (docs/cloudkit-schema-design.md §3.5.3, §5.9)

/// `images.notebookCoverBackfill.<zoneID>`, the cover backfill's claim and completion record for one
/// zone: a `Setting` record in the personal `Library` (a space's in its owner's `Library`) whose value is
/// `{t: dict, v: {state: running|done, by: deviceID, at}}`. It is no synced preference and no learner
/// Setting: the catalog lists it under `leftOut`, `set_app_setting` refuses it, and only the backfill
/// writes it, by a compare-and-set save beside the engine, so it is never merged.
enum NotebookCoverBackfillMarker {
    static let keyPrefix = "images.notebookCoverBackfill."
    /// A `running` marker older than this may be taken over, as an expired Job lease is.
    static let staleAfter: TimeInterval = 24 * 3_600
    /// The holder renews `at` this often while the pass runs or waits.
    static let renewEvery: TimeInterval = 3_600

    enum State: String, Sendable {
        case running
        case done
    }

    struct Value: Equatable, Sendable {
        var state: State
        var by: String
        /// Epoch milliseconds.
        var at: Int64
    }

    /// The zone is named by its zone name: `Library`, or a space's `Space-<id>`.
    static func key(zoneName: String) -> String {
        keyPrefix + zoneName
    }

    static func typed(_ value: Value) -> SyncJSON {
        .object(["t": .string("dict"), "v": .object([
            "state": .string(value.state.rawValue), "by": .string(value.by), "at": SyncJSON(value.at),
        ])])
    }

    /// The marker a Setting record holds; nil for none, a cleared one or one no build wrote.
    static func value(in envelope: SyncEnvelope?) -> Value? {
        guard let object = envelope?.fields["value"]?.objectValue, object["t"]?.stringValue == "dict",
              let inner = object["v"]?.objectValue,
              let state = inner["state"]?.stringValue.flatMap(State.init(rawValue:)),
              let by = inner["by"]?.stringValue, let at = inner["at"]?.int64Value
        else { return nil }
        return Value(state: state, by: by, at: at)
    }
}

// MARK: - The pass (§5.9)

/// What one pass of the cover backfill did in one zone.
enum NotebookCoverBackfillResult: Equatable, Sendable {
    /// The root does not show `seed.state = complete`, or this Mac does not hold the zone yet.
    case notReady
    /// The marker says `done`: never again, by any Mac.
    case done
    /// Another Mac holds a `running` marker that is not 24 hours old, or won the claim.
    case otherMacRuns
    /// The Setting is off: nothing is drawn, and the pass resumes where it stopped.
    case paused
    /// The zone's root, or this device's server offset, is not here yet; a later round resumes.
    case waiting
    /// This Mac stopped between two notebooks (the lease went, the app quit).
    case stopped(left: Int)
    /// Every notebook of the list was drawn or given up on, and the marker says `done`.
    case finished(drawn: Int, gaveUp: Int)
}

extension NotebookCoverService {
    /// How many times a cover is drawn for one notebook in a pass.
    static let backfillAttempts = NotebookCoverQueue.attemptsMax

    /// After each maintenance round (`MaintenanceService.tick`): the lease holder starts the pass when
    /// none runs; a Mac that does not hold the lease stops a pass that does. The pass runs on its own
    /// task at `.utility`, so it never holds up the round, the lease or the other maintenance.
    func maintenanceRound(holdsLease: Bool) {
        guard holdsLease else {
            // The pass stops between two notebooks and clears itself.
            backfill?.cancel()
            return
        }
        guard backfill == nil else { return }
        backfill = Task(priority: .utility) { [weak self] in
            _ = await self?.runBackfill()
            await self?.backfillEnded()
        }
    }

    private func backfillEnded() {
        backfill = nil
    }

    /// Waits for the pass that runs now, if one does (the suites).
    func finishBackfill() async {
        await backfill?.value
    }

    /// One pass over every zone this Mac may backfill: `Library`, then each space the learner owns (a
    /// member's Mac never backfills a space notebook). Only the lease holder calls it
    /// (`maintenanceRound`), and only once the root shows `seed.state = complete`.
    @discardableResult
    func runBackfill() async -> [String: NotebookCoverBackfillResult] {
        var results: [String: NotebookCoverBackfillResult] = [:]
        do {
            let zones = try await store.perform { state -> (library: BlobZone, ready: Bool, spaces: [String])? in
                guard let library = try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: state) else { return nil }
                let seed = try state.replica.personalRoot()?.envelope.fields["seed"]?["state"]?.stringValue
                var spaces: [String] = []
                try state.connection.query("SELECT zone_key FROM ck_zones WHERE database = 'private' AND kind = 'space' ORDER BY zone_key", []) {
                    spaces.append($0.text(0) ?? "")
                }
                return (library, seed == "complete", spaces)
            }
            guard let zones, zones.ready else { return [PrivateSyncZones.libraryKey: .notReady] }
            for zoneKey in [PrivateSyncZones.libraryKey] + zones.spaces {
                if Task.isCancelled { break }
                let result = try await backfillZone(zoneKey, library: zones.library)
                results[zoneKey] = result
                // The Setting turned off, or no root yet: every zone waits for the same.
                if result == .paused || result == .waiting { break }
            }
        } catch is CancellationError {
        } catch {
            Self.backfillLogger.error("The cover backfill stopped: \(String(describing: error), privacy: .public)")
        }
        return results
    }

    private static let backfillLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "NotebookCoverBackfill")

    private func backfillZone(_ zoneKey: String, library: BlobZone) async throws -> NotebookCoverBackfillResult {
        let zoneName = NotebookCoverTarget(zoneKey: zoneKey, notebookID: "").zoneName
        let markerKey = NotebookCoverBackfillMarker.key(zoneName: zoneName)
        let deviceID = maker.deviceID
        let clock = maker.clock

        // 1. The claim. Nothing is claimed while the Setting says no.
        var marker = try await readMarker(markerKey, in: library)
        switch marker?.state {
        case .done?:
            return .done
        case .running?:
            guard let held = marker else { return .done }
            if held.by != deviceID {
                let age = SyncTime.milliseconds(clock()) - held.at
                guard age > Int64(NotebookCoverBackfillMarker.staleAfter * 1_000) else { return .otherMacRuns }
                guard await gates().automatic else { return .paused }
                // A claim that went quiet for a day: taken over by a save against the version read.
                guard try await saveMarker(.running, key: markerKey, in: library) else { return .otherMacRuns }
                Self.backfillLogger.info("Took over a cover backfill claim that went quiet")
            }
        case nil:
            guard await gates().automatic else { return .paused }
            // Create-if-absent: the first acknowledged create wins, and a Mac that loses does nothing.
            guard try await saveMarker(.running, key: markerKey, in: library) else { return .otherMacRuns }
        }
        marker = try await readMarker(markerKey, in: library)
        guard let claim = marker, claim.state == .running, claim.by == deviceID else { return .otherMacRuns }

        // 2. The list, fixed when the claim is acknowledged (and made once, so a resume never makes it again).
        guard try await listNotebooks(zoneKey, zoneName: zoneName) else { return .waiting }

        // 3. One notebook at a time.
        var drawn = 0
        var renewedAt = claim.at
        while true {
            if Task.isCancelled { return .stopped(left: try await backfillRows(zoneName).count) }
            guard await gates().automatic else {
                try await renewIfDue(markerKey, in: library, lastRenewed: &renewedAt)
                return .paused
            }
            if SyncTime.milliseconds(clock()) - renewedAt >= Int64(NotebookCoverBackfillMarker.renewEvery * 1_000) {
                // The hourly renewal; a save that met another version means another Mac took the pass.
                guard try await saveMarker(.running, key: markerKey, in: library) else { return .otherMacRuns }
                renewedAt = SyncTime.milliseconds(clock())
            }
            guard let row = try await backfillRows(zoneName).first(where: { $0.attempts < Self.backfillAttempts }) else { break }
            let target = NotebookCoverTarget(zoneKey: zoneKey, notebookID: row.notebookID)
            do {
                let outcome = try await draw(target, staged: row.staged, queueRow: row.id)
                if case .drawn = outcome { drawn += 1 }
                try await store.perform { try $0.connection.execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(row.id)]) }
            } catch is NotebookCoverMaker.Wait {
                return .waiting
            } catch where Self.isCancellation(error) {
                // A lease lost mid-draw cancels the call in flight, which surfaces as the URL loader's or
                // CloudKit's own cancellation: not a failed attempt (F17).
                return .stopped(left: try await backfillRows(zoneName).count)
            } catch {
                let message = String(describing: error)
                Self.backfillLogger.error("A notebook cover could not be drawn (attempt \(row.attempts + 1)): \(message, privacy: .public)")
                try await store.perform { state in
                    try state.connection.execute(
                        "UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(row.id)]
                    )
                }
            }
        }

        // 4. Done: the marker says so, and a notebook that failed both attempts keeps its emoji.
        let gaveUp = try await backfillRows(zoneName).count
        guard try await saveMarker(.done, key: markerKey, in: library) else { return .otherMacRuns }
        try await store.perform { state in
            try state.connection.execute("DELETE FROM ck_backfill_queue WHERE kind = ? AND target LIKE ?", [
                .text(NotebookCoverQueue.backfillKind), .text(zoneName + "/%"),
            ])
            try state.replica.setEngineState(Self.listedScope(zoneName), nil, now: Date())
        }
        Self.backfillLogger.info("The cover backfill of \(zoneName, privacy: .public) is done: \(drawn) drawn, \(gaveUp) given up")
        return .finished(drawn: drawn, gaveUp: gaveUp)
    }

    /// Whether `error` is a cancellation, whichever layer raised it.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if let cloud = error as? CloudError, cloud.code == .operationCancelled { return true }
        let bridged = error as NSError
        return bridged.domain == NSURLErrorDomain && bridged.code == NSURLErrorCancelled
    }

    // MARK: The marker

    private func readMarker(_ key: String, in library: BlobZone) async throws -> NotebookCoverBackfillMarker.Value? {
        try await store.perform { state in
            try state.replica.record(zoneKey: library.zoneKey, recordType: SyncRecordType.setting.rawValue, wireID: key)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
                .flatMap { NotebookCoverBackfillMarker.value(in: $0) }
        }
    }

    /// Saves the marker beside the engine: a create when the replica holds none (so a Mac that loses the
    /// create meets the server's marker), else a save against the version it holds. True when the server
    /// took it; false when the save met another version, which the replica now holds.
    private func saveMarker(_ state: NotebookCoverBackfillMarker.State, key: String, in library: BlobZone) async throws -> Bool {
        let now = maker.clock()
        var patch = RecordPatch(.setting, id: key)
        patch.changes["key"] = .value(.string(key))
        patch.changes["value"] = .value(NotebookCoverBackfillMarker.typed(.init(state: state, by: maker.deviceID, at: SyncTime.milliseconds(now))))
        patch.changes["updatedBy"] = .value(.string(maker.deviceID))
        patch.changes["editedAt"] = .value(SyncJSON(SyncTime.milliseconds(now)))
        do {
            return try await maker.writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first == .saved
        } catch MaintenanceWriter.WriterError.noServerOffset {
            throw NotebookCoverMaker.Wait.zoneNotReady
        }
    }

    private func renewIfDue(_ key: String, in library: BlobZone, lastRenewed: inout Int64) async throws {
        guard SyncTime.milliseconds(maker.clock()) - lastRenewed >= Int64(NotebookCoverBackfillMarker.renewEvery * 1_000) else { return }
        if try await saveMarker(.running, key: key, in: library) { lastRenewed = SyncTime.milliseconds(maker.clock()) }
    }

    // MARK: The list

    private static func listedScope(_ zoneName: String) -> String { "maintenance.coverBackfill.listed.\(zoneName)" }

    struct BackfillRow: Sendable {
        let id: Int64
        let notebookID: String
        let attempts: Int
        let staged: NotebookCoverStaged?
    }

    /// Queues every active notebook of the zone that has no cover, once: the list is fixed when the claim is
    /// acknowledged, so a notebook made later follows the creation rule. A notebook already queued for its
    /// creation cover is left to that queue.
    ///
    /// False while the zone's list cannot be trusted: a space this Mac has not yet walked to the end holds
    /// only part of its notebooks in the replica, and a list made from that would end the backfill with
    /// `done`, shared and final, over notebooks it never saw (F16).
    private func listNotebooks(_ zoneKey: String, zoneName: String) async throws -> Bool {
        try await store.perform { state in
            let scope = Self.listedScope(zoneName)
            guard try state.replica.engineState(scope) == nil else { return true }
            if ProjectionZones.zone(ofKey: zoneKey)?.isSpace == true,
               try state.connection.scalarInteger("SELECT COUNT(*) FROM ck_zones WHERE zone_key = ? AND last_complete_pass_at IS NOT NULL", [.text(zoneKey)]) != 1 {
                return false
            }
            var ids: [String] = []
            try state.connection.query(
                "SELECT wire_id, payload FROM ck_records WHERE zone_key = ? AND record_type = ? ORDER BY wire_id",
                [.text(zoneKey), .text(SyncRecordType.notebook.rawValue)]
            ) { row in
                guard let id = row.text(0), let payload = row.blob(1), let envelope = try? SyncEnvelope(storedPayload: payload) else { return }
                let subject = NotebookCoverSubject(envelope)
                if subject.isActive, subject.cover == nil { ids.append(id) }
            }
            let now = Date()
            for id in ids {
                let target = NotebookCoverQueue.target(zoneName: zoneName, notebookID: id)
                if try state.connection.scalarInteger(
                    "SELECT EXISTS(SELECT 1 FROM ck_backfill_queue WHERE kind = ? AND target = ?)", [.text(NotebookCoverQueue.newKind), .text(target)]
                ) == 1 { continue }
                try state.connection.execute("""
                    INSERT INTO ck_backfill_queue (kind, target, enqueued_at) VALUES (?, ?, ?)
                    ON CONFLICT(kind, target) DO NOTHING
                """, [.text(NotebookCoverQueue.backfillKind), .text(target), .real(now.timeIntervalSinceReferenceDate)])
            }
            try state.replica.setEngineState(scope, Data("\(ids.count)".utf8), now: now)
            return true
        }
    }

    private func backfillRows(_ zoneName: String) async throws -> [BackfillRow] {
        try await store.perform { state in
            var rows: [BackfillRow] = []
            try state.connection.query("""
                SELECT id, target, attempts, payload_json FROM ck_backfill_queue WHERE kind = ? AND target LIKE ? ORDER BY id
            """, [.text(NotebookCoverQueue.backfillKind), .text(zoneName + "/%")]) { row in
                guard let id = row.integer(0), let target = row.text(1), let parsed = NotebookCoverQueue.parse(target) else { return }
                let staged = row.text(3).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }.flatMap { NotebookCoverStaged(json: $0) }
                rows.append(BackfillRow(id: id, notebookID: parsed.notebookID, attempts: Int(row.integer(2) ?? 0), staged: staged))
            }
            return rows
        }
    }
}
