import Foundation
import Observation
import OSLog

/// Settings › iCloud's model of the library's move to the new iCloud store (docs/cloudkit-schema-design.md
/// §13.3 to §13.8): what it shows (`ICloudMigrationState`) and what its buttons do. Everything that touches
/// the store, iCloud or the files runs off the main actor; this class only holds the latest values.
@MainActor
@Observable
final class ICloudMigrationModel {
    static let shared = ICloudMigrationModel()

    enum Work: Equatable {
        case refreshing
        case confirmingLibrary
        case uploadingAgain
    }

    private(set) var state: ICloudMigrationState?
    private(set) var work: Work?
    /// The last button's outcome, in one sentence; cleared when the next button is pressed.
    private(set) var notice: String?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ICloudMigration")

    private init() {}

    // MARK: - Reading

    /// Reads the store and the coordinator. Cheap enough for each time the pane appears and after each sync.
    func refresh() async {
        if work == nil { work = .refreshing }
        defer { if work == .refreshing { work = nil } }
        let storage = StorageService()
        let coordinator = SyncCoordinator.current
        let deviceID = await coordinator?.deviceID
        let snapshot: ICloudMigrationSnapshot
        do {
            snapshot = try await storage.performStoreWork { try $0.migrationSnapshot(deviceID: deviceID) }
        } catch {
            Self.logger.error("Could not read the move's state: \(error.localizedDescription, privacy: .public)")
            return
        }
        let sync = await coordinator?.status
        state = ICloudMigrationState(snapshot: snapshot, sync: sync, now: Date())
    }

    // MARK: - Buttons

    /// "This Mac holds my library", after the learner confirmed the dialog (§13.5).
    func confirmHoldsMyLibrary() async {
        notice = nil
        guard let state, state.holds.offersTheButton else {
            notice = "This Mac is not offered \"This Mac holds my library\" right now."
            return
        }
        guard let claimer = MigrationServices.shared.claimer else {
            notice = "Moving the library is not available in this build yet."
            return
        }
        work = .confirmingLibrary
        defer { work = nil }
        let flow = HoldsMyLibraryFlow(record: StoreHoldsMyLibraryRecord(), claimer: claimer)
        do {
            let progress = try await flow.confirm(freshReason: state.snapshot.journal?.freshReason)
            switch progress.outcome {
            case .seeding?: notice = "This Mac is moving your library to iCloud."
            case .reconciling?: notice = "This Mac is joining the library already in iCloud."
            case .notYet?, nil: notice = "ForeverLM will start as soon as iCloud has your library's root."
            }
        } catch {
            notice = "Could not start: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Replaces what iCloud holds of this Mac's library with this Mac's copy: the zones go, then the
    /// library uploads from the start. Has no button; MCP `replace_icloud_library` presses it.
    func replaceICloudLibrary() async {
        notice = nil
        guard let coordinator = SyncCoordinator.current else {
            notice = "iCloud sync is not running on this Mac."
            return
        }
        work = .uploadingAgain
        defer { work = nil }
        do {
            try await coordinator.replaceICloudLibrary()
            notice = "iCloud's copy was removed and this Mac is uploading its library again."
        } catch {
            notice = "Could not replace the iCloud library: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// "Upload my library to iCloud again" after iCloud lost the library (§2.5).
    func uploadAgain() async {
        notice = nil
        guard let coordinator = SyncCoordinator.current, state?.snapshot.stop != nil else {
            notice = "iCloud still holds this library, so there is nothing to upload again."
            return
        }
        work = .uploadingAgain
        defer { work = nil }
        do {
            try await coordinator.uploadAgain()
            notice = "This Mac is uploading its library to iCloud again."
        } catch {
            notice = "Could not upload again: \(error.localizedDescription)"
        }
        await refresh()
    }
}

/// The confirmation of "This Mac holds my library", kept in the store's engine state.
struct StoreHoldsMyLibraryRecord: HoldsMyLibraryRecord {
    func load() async throws -> HoldsMyLibraryConfirmation? {
        try await StorageService().performStoreWork { try $0.holdsMyLibraryConfirmation() }
    }

    func save(_ confirmation: HoldsMyLibraryConfirmation) async throws {
        try await StorageService().performStoreWork { try $0.writeHoldsMyLibraryConfirmation(confirmation) }
    }
}
