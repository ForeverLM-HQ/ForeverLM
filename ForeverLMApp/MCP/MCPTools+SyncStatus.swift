#if os(macOS)
import Foundation

// MARK: - get_sync_status under generation 2 (docs/cloudkit-schema-design.md §14.1, R5-m2)

extension MCPDataStore {
    /// What the Mac's generation-2 sync is doing: the coordinator's status, the cutover's, and the account
    /// condition that stops sync without an error of its own.
    func generationTwoSyncStatus() async throws -> String {
        var payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "sync_generation": 2,
            "container": ForeverLMRuntimeIdentity.libraryContainerIdentifier ?? "",
            "container_environment": CloudRuntimeAvailability.containerEnvironment.rawValue,
            "icloud_signed_in": CloudRuntimeAvailability.isSignedIn,
        ]
        // Missing items are often only another Mac answering, or this one
        // narrowed to a take (MCPTools+ICloudAccount.swift).
        payload["answered_by"] = await Self.answeringMac()
        if let note = Self.screenRecordNarrowedNote { payload["narrowed"] = note }
        if let migration = await Self.libraryMoveStatus() { payload["migration"] = migration }
        if let usage = try? await ICloudStorageUsage.measure(storage: StorageService()) {
            payload["icloud_storage"] = [
                "pdf_bytes": usage.documentBytes,
                "text_bytes": usage.textBytes,
                "other_file_bytes": usage.otherBytes,
                "icloud_drive_bytes": usage.driveBytes,
                "total_bytes": usage.totalBytes,
            ]
        }
        guard let session = MacSyncSession.current else {
            payload["phase"] = "not_started"
            payload["message"] = "The new iCloud sync has not started on this Mac yet."
            return try jsonString(payload)
        }
        let snapshot = await session.snapshot()
        payload["phase"] = Self.phaseName(snapshot.phase)
        payload["pending_uploads"] = snapshot.pendingChanges
        payload["holds_library"] = snapshot.holdsLibrary
        payload["cutover"] = Self.cutoverName(snapshot.cutover)
        if let last = snapshot.lastSyncedAt { payload["last_synced_at"] = ISO8601DateFormatter().string(from: last) }
        let status = SyncStatus(phase: snapshot.phase)
        if let notice = status.notice {
            payload["message"] = notice
        } else if case .upToDate = snapshot.phase {
            payload["message"] = snapshot.pendingChanges == 0
                ? "Everything on this Mac has reached iCloud."
                : "\(snapshot.pendingChanges) local changes are still waiting to upload."
        } else {
            payload["message"] = Self.cutoverMessage(snapshot.cutover) ?? "Syncing with iCloud."
        }
        return try jsonString(payload)
    }

    /// The library's move to the new iCloud store, as Settings › iCloud shows it (`ICloudMigrationModel`).
    @MainActor
    private static func libraryMoveStatus() async -> [String: Any]? {
        let model = ICloudMigrationModel.shared
        await model.refresh()
        return model.state?.statusPayload()
    }

    static func phaseName(_ phase: SyncStatus.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .starting: return "starting"
        case .noAccount: return "no_account"
        case .waiting: return "waiting"
        case .updateRequired: return "update_required"
        case .syncing: return "syncing"
        case .upToDate: return "up_to_date"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    static func cutoverName(_ state: CutoverStatus.State) -> String {
        switch state {
        case .idle: return "idle"
        case .waitingForCatchUp: return "waiting_for_catch_up"
        case .waitingForConfirmation: return "waiting_for_confirmation"
        case .seeding: return "seeding"
        case .waitingForSeed: return "waiting_for_seed"
        case .reconciling: return "reconciling"
        case .stopped: return "stopped"
        case .moved: return "moved"
        }
    }

    static func cutoverMessage(_ state: CutoverStatus.State) -> String? {
        switch state {
        case .waitingForCatchUp: return "This Mac is reading the new iCloud store before it sends anything."
        case .waitingForConfirmation: return "This Mac uploads nothing until you confirm it holds your library."
        case .seeding: return "This Mac is moving your library to the new iCloud store."
        case .waitingForSeed(let holder): return "Another Mac (\(holder)) is moving your library to the new iCloud store."
        case .reconciling: return "This Mac is comparing its library with the new iCloud store."
        case .stopped: return "Moving your library stopped; Settings › iCloud says why."
        case .idle, .moved: return nil
        }
    }
}
#endif
