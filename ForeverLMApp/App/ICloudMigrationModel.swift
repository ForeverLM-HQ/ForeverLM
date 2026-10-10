import Foundation
import Observation
import OSLog

/// Settings › iCloud's model of the library's move to the new iCloud store (docs/cloudkit-schema-design.md
/// §13.3 to §13.8): what it shows (`ICloudMigrationState`) and what its buttons do. Everything that touches
/// the store, iCloud or the files runs off the main actor; this class only holds the latest values.
/// Generation 1 has none of it: the state stays nil and nothing in the pane shows.
@MainActor
@Observable
final class ICloudMigrationModel {
    static let shared = ICloudMigrationModel()

    enum Work: Equatable {
        case refreshing
        case confirmingLibrary
        case answeringQuestion
        case uploadingAgain
    }

    private(set) var state: ICloudMigrationState?
    private(set) var work: Work?
    /// The last button's outcome, in one sentence; cleared when the next button is pressed.
    private(set) var notice: String?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ICloudMigration")
    /// The parity report walks every old asset's file, so it is measured at most this often.
    private static let parityInterval: TimeInterval = 10 * 60
    @ObservationIgnored private var parity: (report: ByteParityReport, at: Date)?

    private init() {}

    // MARK: - Reading

    /// Reads the store, the coordinator, late import and the removal gate. Cheap enough for each time the
    /// pane appears and after each sync; the parity report is reused for ten minutes unless `forceParity`.
    func refresh(forceParity: Bool = false) async {
        guard ForeverLMRuntimeIdentity.syncGeneration == .two else { return }
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
        let imports = try? await MigrationServices.shared.importer?.facts()
        var report: ByteParityReport?
        if imports != nil, snapshot.isActivated {
            if !forceParity, let parity, Date().timeIntervalSince(parity.at) < Self.parityInterval {
                report = parity.report
            } else {
                report = try? await storage.performStoreWork { try ByteParityReport.compute(in: $0) }
                if let report { parity = (report, Date()) }
            }
        }
        let now = Date()
        state = ICloudMigrationState(
            snapshot: snapshot, sync: sync, imports: imports, parity: report,
            gate: OldContainerRemovalGate.evaluate(facts: imports, parity: report, now: now), now: now
        )
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

    /// Apply or Keep for an import pass's or a refresh's 5% question (§13.6, R7-m3).
    func answerImportQuestion(_ answer: ImportQuestionAnswer) async {
        notice = nil
        guard let question = state?.imports?.question, let importer = MigrationServices.shared.importer else {
            notice = "No question about the old iCloud library is waiting."
            return
        }
        work = .answeringQuestion
        defer { work = nil }
        do {
            try await importer.answer(question, answer)
            notice = answer == .apply ? "Applying the old library's removals." : "Keeping what those removals would have taken."
        } catch {
            notice = "Could not answer: \(error.localizedDescription)"
        }
        await refresh(forceParity: true)
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
