import CloudKit
import OSLog
import SwiftUI
import UIKit

// Spaces on the iPhone (docs/cloudkit-schema-design.md §5.3, §9.1, §9.7, D21): a share of
// the library container the system hands over is accepted into ShareService and walked at once; a
// notebook of the personal library is shared by asking a Mac to move it into a space
// (`Job(moveToSpace)`); a notebook in a space shows the system's sharing controller for that space.
// A share of any other container, or a build with no library container, is not accepted.

/// The share invitations the system hands the phone.
enum MobileShareAcceptance {
    enum Route: Equatable {
        /// A space of the library container: ShareService's.
        case space
        /// Not a share this build accepts (another container's, or a build that syncs nothing).
        case notOurs
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileShareAcceptance")

    static func route(shareContainer: String, libraryContainer: String?, enabled: Bool) -> Route {
        guard enabled, let libraryContainer, shareContainer == libraryContainer else { return .notOurs }
        return .space
    }

    /// The system's metadata of an accepted invitation, from the scene delegate.
    @MainActor
    static func accept(_ metadata: CKShare.Metadata) {
        guard route(shareContainer: metadata.containerIdentifier, libraryContainer: ForeverLMRuntimeIdentity.libraryContainerIdentifier,
                    enabled: MobileSyncSession.isEnabled) == .space,
              let url = metadata.share.url else { return }
        Task {
            guard let session = await MobileSyncSession.startIfEnabled() else { return }
            do {
                try await session.coordinator.acceptShare(CloudShareInvitation(url: url, systemMetadata: metadata))
                await MainActor.run { NotificationCenter.default.post(name: .mobileReplicaDidChange, object: nil) }
            } catch {
                logger.error("A space's invitation could not be accepted: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The invitation accepted into this device's spaces, then the spaces walked, as the
    /// coordinator's `acceptShare` does.
    @discardableResult
    static func accept(_ invitation: CloudShareInvitation, shares: ShareService, spaces: SpaceSync) async throws -> SpaceZone {
        let zone = try await shares.accept(invitation)
        try await spaces.sync()
        return zone
    }
}

/// The phone's window scenes, for the one thing SwiftUI's own delegate does not do: take an accepted
/// CloudKit share (`CKSharingSupported`). Set only on a build that syncs (`MobileAppDelegate`).
final class MobileWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in MobileShareAcceptance.accept(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in MobileShareAcceptance.accept(cloudKitShareMetadata) }
    }
}

extension MobileWrite {
    /// The learner's word that they may share (`SharingRightsAffirmation`, the account Setting
    /// `sharing.rightsAffirmation`), as it stands here.
    func sharingAffirmation() throws -> SharingRightsAffirmation? {
        try stringSetting(SharingRightsAffirmation.preferenceKey).flatMap { SharingRightsAffirmation(rowValue: $0) }
    }

    /// Records the learner's word, given on this screen.
    mutating func writeSharingAffirmation(_ affirmation: SharingRightsAffirmation) throws {
        var patch = RecordPatch(.setting, id: SharingRightsAffirmation.preferenceKey)
        patch.changes["key"] = .value(.string(SharingRightsAffirmation.preferenceKey))
        patch.changes["value"] = .value(.object(["t": .string("string"), "v": .string(affirmation.rowValue)]))
        patch.changes["updatedBy"] = .value(.string(deviceID))
        try write(patch, in: Self.libraryKey)
    }
}

// MARK: - A notebook's Share

@MainActor
final class MobileSpaceShareModel: ObservableObject {
    enum Place: Equatable {
        case looking
        /// In the personal library; `moving` once a Mac has been asked to move it.
        case personal(moving: Bool)
        /// In a space: its zone key, name, and whether this member owns it.
        case space(zoneKey: String, name: String?, owned: Bool, readOnly: Bool)
        case gone
    }

    struct Controller: Identifiable {
        let id = UUID()
        let share: CKShare
        let container: CKContainer
    }

    let notebookID: String
    let title: String
    @Published private(set) var place: Place = .looking
    @Published private(set) var line: String?
    @Published private(set) var working = false
    @Published var asksAffirmation = false
    @Published var controller: Controller?

    private static let presentedKey = "share.presentedMoveJobs"

    init(notebookID: String, title: String) {
        self.notebookID = notebookID
        self.title = title
    }

    func load() async {
        guard let writer = await MobileRecordWriter.current() else {
            place = .gone
            return
        }
        let notebookID = notebookID
        let found = try? await writer.read { write -> (Place, String?) in
            guard let notebook = try? write.liveNotebook(notebookID) else { return (.gone, nil) }
            let jobs = try write.jobs().filter { $0.fields["kind"]?.stringValue == "moveToSpace" && $0.fields["target"]?.stringValue == "nb:\(notebookID)" }
            guard notebook.zone.isSpace, let row = try write.store.zone(key: notebook.zoneKey) else {
                let moving = jobs.contains { ["queued", "running"].contains($0.fields["status"]?.stringValue ?? "") }
                return (.personal(moving: moving), nil)
            }
            let root = try write.store.record(zoneKey: notebook.zoneKey, recordName: SyncSchema.rootRecordName).flatMap { write.replica.decode($0.payload) }
            // The move this phone asked for is done: the space's share sheet is shown once (§5.3).
            let done = jobs.first { $0.fields["status"]?.stringValue == "done" && $0.fields["requestedBy"]?["device"]?.stringValue == write.deviceID }
            return (.space(zoneKey: notebook.zoneKey, name: root?.fields["name"]?.stringValue, owned: row.database == .private,
                           readOnly: row.permission == CloudShare.Permission.readOnly.rawValue), done?.id)
        }
        place = found?.0 ?? .gone
        if let jobID = found?.1, case .space(_, _, true, _) = place, !presentedJobs.contains(jobID) {
            presentedJobs.insert(jobID)
            await manageSharing()
        }
    }

    /// Share with others: a notebook of the personal library is moved by a Mac into a new space made
    /// for it (§5.3), once the learner has said they may share its sources.
    func shareWithOthers() async {
        guard case .personal(false) = place, !working else { return }
        working = true
        defer { working = false }
        do {
            let writer = try await MobileRecordWriter.required()
            guard try await writer.read({ try $0.sharingAffirmation() })?.isCurrent() == true else {
                asksAffirmation = true
                return
            }
            _ = try await writer.requestMoveToSpace(notebookID, to: .newSpace(kind: "notebook", name: title))
            line = "Your Mac moves this notebook into a shared space the next time ForeverLM runs there. Share it from here after that."
            place = .personal(moving: true)
        } catch {
            line = error.localizedDescription
        }
    }

    func affirmAndShare() async {
        asksAffirmation = false
        do {
            let writer = try await MobileRecordWriter.required()
            try await writer.transaction { try $0.writeSharingAffirmation(SharingRightsAffirmation(affirmedAt: Date())) }
        } catch {
            line = error.localizedDescription
            return
        }
        await shareWithOthers()
    }

    /// The space's sharing controller: its zone-wide share, made first for an owned space with none.
    func manageSharing() async {
        guard case .space(let zoneKey, _, let owned, _) = place, !working,
              let session = await MobileSyncSession.startIfEnabled() else { return }
        working = true
        defer { working = false }
        do {
            let row = try await session.replica.read { try $0.replica.zone(key: zoneKey) }
            guard let row, let space = SpaceZone(row) else { throw MobileRecordWriterError.zoneNotHeld }
            let container = CKContainer(identifier: session.containerIdentifier)
            let database = owned ? container.privateCloudDatabase : container.sharedCloudDatabase
            let zoneID = CKRecordZone.ID(zoneName: space.zoneID.zoneName, ownerName: owned ? CKCurrentUserDefaultName : space.zoneID.ownerName)
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            var record: CKRecord?
            do {
                record = try await database.record(for: shareID)
            } catch let error as CKError where error.code == .unknownItem && owned {
                try await session.coordinator.shares.share(space, title: title)
                record = try await database.record(for: shareID)
            }
            guard let share = record as? CKShare else { throw MobileRecordWriterError.zoneNotHeld }
            controller = Controller(share: share, container: container)
        } catch {
            line = "This space's sharing could not be opened: \(error.localizedDescription)"
        }
    }

    /// The moves whose space this phone already showed the sharing controller for: device-local.
    private var presentedJobs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.presentedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.presentedKey) }
    }
}

struct MobileSpaceShareSheet: View {
    let notebook: MobileCloudNotebook
    let sourceCount: Int

    @StateObject private var model: MobileSpaceShareModel
    @State private var affirmed = false
    @Environment(\.dismiss) private var dismiss

    init(notebook: MobileCloudNotebook, sourceCount: Int) {
        self.notebook = notebook
        self.sourceCount = sourceCount
        _model = StateObject(wrappedValue: MobileSpaceShareModel(notebookID: notebook.id, title: notebook.title))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(NotebookShareLine.text(sourceCount: sourceCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let line = model.line {
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { placeRows }
                if model.asksAffirmation {
                    Section(SharingRightsAffirmation.title) {
                        Text(SharingRightsAffirmation.statement).font(.subheadline)
                        Toggle(SharingRightsAffirmation.checkboxLabel, isOn: $affirmed)
                        Button(SharingRightsAffirmation.shareButtonTitle) { Task { await model.affirmAndShare() } }
                            .disabled(!affirmed)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NotebookShareLine.title(notebookTitle: notebook.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $model.controller) { controller in
                MobileCloudSharingController(share: controller.share, container: controller.container, title: notebook.title)
                    .ignoresSafeArea()
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder private var placeRows: some View {
        switch model.place {
        case .looking:
            ProgressView().frame(maxWidth: .infinity)
        case .gone:
            Text("This notebook is no longer available.").foregroundStyle(.secondary)
        case .personal(let moving):
            if moving {
                Text("Moving to a shared space when your Mac is online.").foregroundStyle(.secondary)
            } else {
                Button("Share with Others…") { Task { await model.shareWithOthers() } }
                    .disabled(model.working)
            }
        case .space(_, let name, _, let readOnly):
            Text("Shared in \(name.flatMap { $0.isEmpty ? nil : $0 } ?? "a space")")
            if !readOnly {
                Button("Manage Sharing…") { Task { await model.manageSharing() } }
                    .disabled(model.working)
            }
        }
    }
}

/// The system's sharing controller for a space's zone-wide share (§9.7).
struct MobileCloudSharingController: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator(title: title) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadWrite, .allowReadOnly]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let title: String

        init(title: String) { self.title = title }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileShareAcceptance")
                .error("The space's share was not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
