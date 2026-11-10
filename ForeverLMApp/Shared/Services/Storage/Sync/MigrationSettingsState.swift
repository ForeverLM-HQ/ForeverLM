import Foundation
import SQLite3

// MARK: - What Settings › iCloud shows of the move to the new iCloud store

/// The store's side of Settings › iCloud (docs/cloudkit-schema-design.md §13.3 step 3, §13.4, §13.5):
/// the activation's mode and journal, the rollback copy and the recorded rollback build, the seed's
/// progress as the root reports it, the learner's "This Mac holds my library" confirmation, why the
/// private database stopped, and the bytes each owned space holds. Read in one storage-actor job
/// (`KnowledgeStore.migrationSnapshot`), never on the main actor.
struct ICloudMigrationSnapshot: Equatable, Sendable {
    /// The rollback copy step 1 took (§13.3 step 1), as `ck_activation` and its record on disk say.
    enum RollbackCopyLine: Equatable, Sendable {
        /// `quick_check` passed: "Rollback copy: checked", at library version `userVersion`.
        case checked(userVersion: Int32)
        /// The copy is made and its `quick_check` has not finished.
        case checking(userVersion: Int32)
        case failedCheck(String)
        /// `ck_activation` names a copy that is not in the store's folder.
        case missing
        /// No copy was taken: an empty store has nothing to roll back, or neither a clone nor a backup
        /// was possible. The old container still holds the synced library.
        case none
    }

    struct SeedLine: Equatable, Sendable {
        enum Phase: String, Equatable, Sendable {
            /// No root has been read yet.
            case unknown
            case pending
            case seeding
            /// `seed.metadataCompleteAt` is set and the satellites are still uploading.
            case metadataComplete
            case complete
        }

        var phase: Phase = .unknown
        /// The Mac that holds the claim while it moves the library, by its Device record's name.
        var movingMac: String?
        /// Whether that claim is this Mac's own.
        var claimIsMine = false
        var passesDone = 0
        static let passes = 7
    }

    struct SpaceBytes: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let bytes: Int64
    }

    var isGeneration2 = false
    var journal: ActivationJournal?
    var holdsLibrary = false
    var rollbackCopy: RollbackCopyLine = .none
    var seed = SeedLine()
    var root: HoldsMyLibrary.RootState = .unknown
    var confirmation: HoldsMyLibraryConfirmation?
    /// Why the private database stopped (§2.5), if it did.
    var stop: PurgeHandler.Event?
    /// Bytes this account's satellites hold in its own library, and in each space it owns.
    var libraryBytes: Int64 = 0
    var ownedSpaces: [SpaceBytes] = []

    var isActivated: Bool { journal?.activatedAt != nil }

    var holdsMyLibraryStanding: HoldsMyLibrary.Standing {
        HoldsMyLibrary.standing(HoldsMyLibrary.Inputs(
            mode: journal?.mode, freshReason: journal?.freshReason, holdsLibrary: holdsLibrary, root: root, confirmation: confirmation
        ))
    }
}

extension ICloudMigrationSnapshot.SeedLine {
    /// The seed as the personal root says it (`seed`, `seedClaim`, §3.5.1). `deviceName` names a Mac by
    /// its Device record.
    static func read(root: SyncEnvelope?, myDeviceID: String?, passesDone: Int, deviceName: (String) -> String?, now: Date) -> ICloudMigrationSnapshot.SeedLine {
        guard let root else { return ICloudMigrationSnapshot.SeedLine() }
        let seed = root.fields["seed"]?.objectValue ?? [:]
        var line = ICloudMigrationSnapshot.SeedLine(passesDone: passesDone)
        if seed["state"]?.stringValue == "complete" {
            line.phase = .complete
        } else if seed["metadataCompleteAt"]?.int64Value != nil {
            line.phase = .metadataComplete
        } else if seed["state"]?.stringValue == "seeding" {
            line.phase = .seeding
        } else {
            line.phase = .pending
        }
        if let claim = root.fields["seedClaim"]?.objectValue, let device = claim["device"]?.stringValue,
           (claim["leaseUntil"]?.int64Value ?? 0) > SyncTime.milliseconds(now) {
            line.claimIsMine = device == myDeviceID
            line.movingMac = device == myDeviceID ? nil : (deviceName(device) ?? "another Mac")
        }
        return line
    }
}

extension HoldsMyLibrary.RootState {
    /// What the root in the replica says, for Settings; an absent root is `unknown` there, since only
    /// the old container's lookup tells a brand-new account from one that holds a library (§2.4).
    static func read(root: SyncEnvelope?, now: Date) -> HoldsMyLibrary.RootState {
        guard let root else { return .unknown }
        let seed = root.fields["seed"]?.objectValue ?? [:]
        if seed["metadataCompleteAt"]?.int64Value != nil { return .complete }
        switch seed["state"]?.stringValue {
        case "seeding":
            if let claim = root.fields["seedClaim"]?.objectValue, (claim["leaseUntil"]?.int64Value ?? 0) > SyncTime.milliseconds(now) { return .seeding }
            return .pending
        case "complete": return .complete
        default: return .pending
        }
    }
}

extension KnowledgeStore {
    /// Everything `ICloudMigrationSnapshot` holds, from this store and its replica. `deviceID` is this
    /// Mac's, for telling its own claim from another Mac's.
    func migrationSnapshot(deviceID: String?, now: Date = Date()) throws -> ICloudMigrationSnapshot {
        var snapshot = ICloudMigrationSnapshot()
        snapshot.isGeneration2 = true
        let journal = try activationJournal()
        snapshot.journal = journal
        snapshot.holdsLibrary = (try? rollbackCopyStoreState(userVersion: 0).holdsLibrary) ?? false
        let storeDirectory = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        snapshot.rollbackCopy = Self.rollbackCopyLine(journal: journal, in: storeDirectory, failure: rollbackCopyFailure)
        snapshot.confirmation = try holdsMyLibraryConfirmation()

        let replica = self.replica
        let rootEnvelope = try replica.personalRoot()?.envelope
        let passes = (try? scalarInteger("SELECT COUNT(*) FROM ck_seed_cursor WHERE completed_at IS NOT NULL")).flatMap { $0 } ?? 0
        snapshot.seed = .read(root: rootEnvelope, myDeviceID: deviceID, passesDone: Int(passes), deviceName: { id in
            (try? replica.record(zoneKey: PrivateSyncZones.libraryKey, recordType: SyncRecordType.device.rawValue, wireID: DeviceRecord.id(id)))
                .flatMap { $0 }
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
                .flatMap { $0.fields["displayName"]?.stringValue }
        }, now: now)
        snapshot.root = .read(root: rootEnvelope, now: now)
        snapshot.stop = (try? replica.engineState(ReplicaStore.EngineScope.privateStop)).flatMap { $0 }.flatMap { PurgeHandler.Event(code: String(decoding: $0, as: UTF8.self)) }
        try bytesPerZone(into: &snapshot)
        return snapshot
    }

    static func rollbackCopyLine(journal: ActivationJournal?, in storeDirectory: URL, failure: String?) -> ICloudMigrationSnapshot.RollbackCopyLine {
        guard let clonePath = journal?.clonePath else { return .none }
        let kind = KnowledgeRollbackCopy.Kind.beforeGeneration2
        guard clonePath == kind.fileName, FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent(clonePath).path) else {
            return .missing
        }
        guard let record = KnowledgeRollbackCopy.recorded(kind, in: storeDirectory) else {
            return .checking(userVersion: journal?.cloneUserVersion ?? 0)
        }
        switch record.quickCheck {
        case nil: return .checking(userVersion: record.userVersion)
        case "ok"?: return .checked(userVersion: record.userVersion)
        case let text?: return .failedCheck(text)
        }
    }

    private func bytesPerZone(into snapshot: inout ICloudMigrationSnapshot) throws {
        let spaces = try SpaceService.summaries(self).filter { $0.isOwned && $0.gone == nil }
        var perZone: [String: Int64] = [:]
        try query("SELECT zone_key, COALESCE(SUM(part_bytes), 0) FROM ck_blobs GROUP BY zone_key") { statement in
            if let key = self.string(statement, 0) { perZone[key] = sqlite3_column_int64(statement, 1) }
        }
        snapshot.libraryBytes = perZone[ReplicaZone.key(database: .private, zoneName: SyncZone.content.rawValue)] ?? 0
        snapshot.ownedSpaces = spaces.map {
            ICloudMigrationSnapshot.SpaceBytes(id: $0.spaceID, name: $0.name.isEmpty ? "Untitled space" : $0.name, bytes: perZone[$0.zone.zoneKey] ?? 0)
        }
    }
}

// MARK: - The lines

/// One status line: a headline and, where it helps, one sentence.
struct ICloudMigrationLine: Equatable, Sendable {
    var title: String
    var detail: String?
}

/// Everything Settings › iCloud renders for the move, as plain values: a snapshot of the store and what
/// the coordinator publishes.
struct ICloudMigrationState: Equatable, Sendable {
    var snapshot: ICloudMigrationSnapshot
    var sync: SyncStatus?
    var now: Date

    /// Nothing about the move shows under generation 1, or while the activation itself is running (its
    /// own card shows then, WP16a).
    var isShown: Bool { snapshot.isGeneration2 && snapshot.isActivated }

    var holds: HoldsMyLibrary.Standing { snapshot.holdsMyLibraryStanding }

    /// Where the move stands.
    var moveLine: ICloudMigrationLine? {
        guard isShown else { return nil }
        if let notice = sync?.notice { return ICloudMigrationLine(title: notice) }
        let seed = snapshot.seed
        switch seed.phase {
        case .unknown:
            return nil
        case .pending:
            if holds.offersTheButton { return nil }
            return ICloudMigrationLine(title: "Waiting for the Mac that holds your library", detail: "It moves the library to the new iCloud store.")
        case .seeding:
            let progress = "Step \(min(seed.passesDone + 1, ICloudMigrationSnapshot.SeedLine.passes)) of \(ICloudMigrationSnapshot.SeedLine.passes)"
            if seed.claimIsMine { return ICloudMigrationLine(title: "Moving your library to the new iCloud store", detail: progress) }
            if let mac = seed.movingMac { return ICloudMigrationLine(title: "Your other Mac \(mac) is moving your library", detail: progress) }
            return ICloudMigrationLine(title: "Moving your library to the new iCloud store", detail: progress)
        case .metadataComplete:
            return ICloudMigrationLine(title: "Library moved; files uploading", detail: pauseText)
        case .complete:
            return pauseText.map { ICloudMigrationLine(title: "Library moved", detail: $0) }
        }
    }

    /// Why the pacer holds uploads, if it does (D43).
    var pauseText: String? {
        switch sync?.pause {
        case nil: return nil
        case .retryAfter?: return "iCloud asked ForeverLM to wait; uploads go on shortly."
        case .repeatedRefusals?: return "iCloud refused 20 uploads in a row; ForeverLM tries again in 15 minutes."
        case .quotaExceeded?: return "Paused: iCloud storage is full."
        case .smallRecordsFirst?: return "Files wait while your changes upload."
        }
    }

    /// How this Mac joined the new store (the activation's mode, D46).
    var modeLine: String? {
        guard let journal = snapshot.journal, let mode = journal.mode else { return nil }
        switch mode {
        case .full: return "Moved from the old iCloud library on this Mac"
        case .deferred: return journal.catchUpAt == nil ? "Waiting for iCloud to catch up with the old library" : "Caught up with the old library after the move"
        case .fresh:
            return journal.freshReason == .knowledgeMissing ? "The old iCloud library was not found; this Mac keeps its own" : "Joined the new iCloud store as a new device"
        }
    }

    var rollbackCopyLine: String {
        switch snapshot.rollbackCopy {
        case .checked(let version): return "Rollback copy: checked (library version \(version))"
        case .checking: return "Rollback copy: checking"
        case .failedCheck(let text): return "Rollback copy: failed its check (\(text))"
        case .missing: return "Rollback copy: missing"
        case .none: return "Rollback copy: none; the old iCloud library still holds your synced library"
        }
    }
}

// MARK: - The same state for `get_sync_status`

extension ICloudMigrationState {
    /// `get_sync_status`'s `migration` object: everything Settings › iCloud shows of the move, as plain
    /// JSON, so an assistant can answer "did my library move?" without the window.
    func statusPayload() -> [String: Any]? {
        guard snapshot.isGeneration2 else { return nil }
        let journal = snapshot.journal
        var payload: [String: Any] = [
            "activated": snapshot.isActivated,
            "activation_mode": journal?.mode?.rawValue ?? NSNull(),
            "fresh_reason": journal?.freshReason?.rawValue ?? NSNull(),
            "activation_step": journal?.step?.rawValue ?? NSNull(),
            "mode": modeLine ?? NSNull(),
            "move": moveLine.map { ["title": $0.title, "detail": $0.detail ?? NSNull()] as [String: Any] } ?? NSNull(),
            "seed": [
                "phase": snapshot.seed.phase.rawValue,
                "steps_done": snapshot.seed.passesDone,
                "steps_total": ICloudMigrationSnapshot.SeedLine.passes,
                "moving_mac": snapshot.seed.movingMac ?? NSNull(),
                "this_mac_holds_the_claim": snapshot.seed.claimIsMine,
            ] as [String: Any],
            "pause": pauseText ?? NSNull(),
            "private_database_stopped": snapshot.stop?.code ?? NSNull(),
            "rollback": [
                "copy": rollbackCopyLine,
                "copy_library_version": journal?.cloneUserVersion.map { Int($0) } ?? NSNull(),
            ] as [String: Any],
            "bytes": [
                "library": snapshot.libraryBytes,
                "owned_spaces": snapshot.ownedSpaces.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] },
            ] as [String: Any],
        ]

        switch holds {
        case .notApplicable: payload["this_mac_holds_my_library"] = ["state": "not_applicable"]
        case .undecided: payload["this_mac_holds_my_library"] = ["state": "undecided"]
        case .seedsAtOnce: payload["this_mac_holds_my_library"] = ["state": "seeds_at_once"]
        case .waitingForOtherMac: payload["this_mac_holds_my_library"] = ["state": "waiting_for_other_mac"]
        case .offer(let offer):
            payload["this_mac_holds_my_library"] = [
                "state": "offered", "why": "\(offer)",
                "action": "run_settings_action confirm_this_mac_holds_my_library, only once the learner has said this Mac's library is the one to keep",
                "consequence": HoldsMyLibrary.confirmationText(offer),
            ] as [String: Any]
        case .confirmed(let progress):
            payload["this_mac_holds_my_library"] = [
                "state": "confirmed", "caught_up": progress.catchUpDone,
                "outcome": progress.outcome.map { "\($0)" } ?? NSNull(),
            ] as [String: Any]
        }
        return payload
    }
}
