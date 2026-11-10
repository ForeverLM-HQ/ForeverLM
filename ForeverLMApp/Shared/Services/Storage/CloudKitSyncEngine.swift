import CloudKit
import Combine
import Foundation
import OSLog
import Security

enum CloudRuntimeAvailability {
    private static let iCloudContainerEntitlement = "com.apple.developer.icloud-container-identifiers"
    private static let containerEnvironmentEntitlement = "com.apple.developer.icloud-container-environment"

    enum ContainerEnvironment: String, Sendable {
        case development
        case production
    }

    /// Whether this process is signed for the library container
    /// (`ForeverLMRuntimeIdentity.libraryContainerIdentifier`), the one container
    /// every build names: false in an unsigned or ad-hoc build, which has no sync.
    static let hasICloudContainerEntitlement: Bool = {
        // UI tests must never attach to the developer's live iCloud library.
        // They use local storage and deterministic shell state instead.
        if UITestConfiguration.isUITesting { return false }
        guard let container = ForeverLMRuntimeIdentity.libraryContainerIdentifier else { return false }
        return entitlementValues(for: iCloudContainerEntitlement).contains(container)
    }()

    static var isEnabled: Bool {
        guard hasICloudContainerEntitlement else { return false }
        return FileManager.default.ubiquityIdentityToken != nil
    }

    /// CloudKit chooses its server environment from the signed entitlement.
    /// Direct-download builds explicitly request Production; development-only
    /// builds generally omit the entitlement and therefore use Development.
    static var containerEnvironment: ContainerEnvironment {
        let raw = entitlementValues(for: containerEnvironmentEntitlement)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == ContainerEnvironment.production.rawValue ? .production : .development
    }

    private static func entitlementValues(for key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return []
        }
        if let values = value as? [String] {
            return values
        }
        if let value = value as? String {
            return [value]
        }
        return []
    }

    /// Signed in to iCloud on this device. With the entitlement but no account
    /// the library still works, and nothing leaves the Mac.
    static var isSignedIn: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
}

/// Every library syncs through the learner's own iCloud (product owner,
/// 2026-09-24). There is no "this Mac only" mode: the library is on this
/// Mac's disk either way, and iCloud is what brings it to their iPhone, iPad,
/// the web library and teams. A Mac that is not signed in to iCloud keeps
/// working and starts syncing once it is.
enum ICloudStorage {
    /// The iCloud+ plan the guide and Settings recommend. The free 5 GB fills
    /// quickly once papers, books and audio are synced.
    static let recommendedPlan = "200 GB"

    /// What a full iCloud means, said the same way by the Settings notice, the
    /// Studio toast and `get_sync_status`: nothing is lost, because the library
    /// is on this Mac's disk, but nothing new reaches the learner's other
    /// devices — the iPhone app included — until there is room.
    static let fullConsequence = "Your library is safe on this Mac, but your iPhone and other devices won't get anything new until there is room."
}

/// The synced library's side of `ICloudStorageUsage`, read from SQLite by
/// `KnowledgeStore.iCloudSyncedSourceStorage()`: the bytes sync has uploaded
/// to the learner's own iCloud database.
struct ICloudSyncedSourceStorage: Sendable, Equatable {
    /// The original PDFs of papers, books and course material.
    var documentBytes: Int64
    /// Source text and its prepared versions, at their compressed size.
    var textBytes: Int64
    /// Everything else sync stores as a file: covers, pictures, audio, EPUBs
    /// and the bodies of the learner's own documents.
    var otherBytes: Int64
}

/// How much of the learner's iCloud ForeverLM's files take up, as Settings ›
/// Data & Privacy › iCloud shows it.
///
/// Apple tells an app nothing about its own CloudKit usage; the exact per-app
/// figure lives only in System Settings › Apple Account › iCloud. So this
/// counts what the app knows it put there: every part sync has uploaded to
/// the learner's own database, at the size it was uploaded at, and every file
/// in ForeverLM's iCloud Drive container. It leaves out the records
/// themselves, which are small beside the files they point at.
struct ICloudStorageUsage: Sendable, Equatable {
    var documentBytes: Int64
    var textBytes: Int64
    var otherBytes: Int64
    var driveBytes: Int64

    var totalBytes: Int64 { documentBytes + textBytes + otherBytes + driveBytes }

    /// ForeverLM's iCloud Drive container, all of it: Apple bills the
    /// container as one, whichever profile's folder a file sits in.
    static var driveContainerRootPath: String {
        // `ubiquityContentRootPath` is `<container>/Documents/<profile folder>`.
        let documents = (StorageService.ubiquityContentRootPath as NSString).deletingLastPathComponent
        return (documents as NSString).deletingLastPathComponent
    }

    /// SQLite on the storage actor, then the file half off it, so the
    /// directory walk never holds the lane interactive reads queue on.
    static func measure(storage: StorageService) async throws -> ICloudStorageUsage {
        let synced = try await storage.iCloudSyncedSourceStorage()
        return await Task.detached(priority: .utility) {
            ICloudStorageUsage.measure(synced)
        }.value
    }

    /// A directory walk: never on the main actor.
    static func measure(
        _ synced: ICloudSyncedSourceStorage,
        driveRoot: URL = URL(fileURLWithPath: driveContainerRootPath, isDirectory: true)
    ) -> ICloudStorageUsage {
        ICloudStorageUsage(
            documentBytes: synced.documentBytes,
            textBytes: synced.textBytes,
            otherBytes: synced.otherBytes,
            driveBytes: fileBytes(under: driveRoot)
        )
    }

    /// Logical size, which is what iCloud counts: a file evicted from this Mac
    /// still reports its full size and still takes up the learner's storage.
    static func fileBytes(under root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

extension Notification.Name {
    static let cloudKitSyncStoreDidChange = Notification.Name("CloudKitSyncStoreDidChange")
    static let cloudKitSyncRemoteStoreDidChange = Notification.Name("CloudKitSyncRemoteStoreDidChange")
    /// The learner's iCloud storage just filled up and uploads stopped.
    static let cloudKitICloudStorageDidFill = Notification.Name("CloudKitICloudStorageDidFill")
    /// A picture recovered from CloudKit landed at the very path a row already
    /// drew as a placeholder — a book cover, or a meeting icon. The thumbnail's
    /// cache key is unchanged, so nothing would re-read it without being told.
    /// Named for that shape rather than for books, because meeting icons hit it
    /// for exactly the same reason.
    static let syncedArtworkDidInstall = Notification.Name("SyncedArtworkDidInstall")
    /// Original source documents were recovered from CloudKit and now exist on
    /// disk. Their recorded paths did not change, so the negative results the
    /// path cache memoized are the only thing standing between a restored file
    /// and the row that reports it missing.
    static let sourceDocumentsDidInstall = Notification.Name("SourceDocumentsDidInstall")
}

enum CloudKitSyncNotificationInfo {
    static let affectedEntitiesKey = "CloudKitSyncAffectedEntities"
    static let requiresFullRefreshKey = "CloudKitSyncRequiresFullRefresh"
    /// A team whose zone left this account: deleted by its owner, or this
    /// account was removed. The team's copies are already gone locally.
    static let removedTeamKey = "CloudKitSyncRemovedTeam"
    /// Docs whose body on disk changed in this pass: applied from the server,
    /// or merged with a newer local body. An open editor re-reads at once.
    static let changedArtifactIDsKey = "CloudKitSyncChangedArtifactIDs"
}

/// Main-actor mirror of the sync engine's progress for Settings. The engine
/// pushes into this from its own CKSyncEngine event seams — nothing here polls,
/// and nothing here touches SQLite on a render path.
@MainActor
final class CloudKitSyncStatusCenter: ObservableObject {
    static let shared = CloudKitSyncStatusCenter()

    enum Phase: Equatable {
        case idle
        /// Draining the durable outbound queue. `total` grows when more local
        /// work joins the active drain, while the measured fraction never moves
        /// backward.
        case sending(remaining: Int, total: Int)
        /// CKSyncEngine never reports how many records are still inbound, so the
        /// pull direction gets a running tally and no denominator. Anything
        /// shaped like a percentage here would be invented.
        case receiving(received: Int)
        /// Between attempts of a drain that is still moving. A large backlog is
        /// paced and routinely throttled, so single windows that land nothing
        /// are ordinary; this reads as uploading, because it is.
        case backingOff(remaining: Int, total: Int)
        /// Repeated attempts the server never took. The queue remains durable,
        /// but nothing is getting through and the learner should know.
        case waitingToRetry(remaining: Int, total: Int)
    }

    /// CKSyncEngine ends one send window before beginning its paired fetch and
    /// may immediately open another send window for the same durable drain. A
    /// short event-driven settle treats those implementation seams as one
    /// logical sync for diagnostics and status reporting.
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fractionComplete: Double?
    @Published private(set) var uploadedThisPass = 0
    @Published private(set) var receivedThisPass = 0
    @Published private(set) var lastCompleted: Date?
    @Published private(set) var conflictCount = 0
    @Published private(set) var pendingItems: [CloudKitSyncPendingItem] = []
    @Published private(set) var issueItems: [CloudKitSyncIssueItem] = []
    /// CloudKit refused the last uploads because the learner's iCloud storage
    /// is full. Changes stay queued; nothing uploads until there is room.
    @Published private(set) var isICloudFull = false

    private var completionTask: Task<Void, Never>?
    private var isReceiving = false
    private let completionSettleDelay: Duration

    init(completionSettleDelay: Duration = .milliseconds(500)) {
        self.completionSettleDelay = completionSettleDelay
    }

    var remainingCount: Int {
        switch phase {
        case .idle, .receiving:
            return 0
        case .sending(let remaining, _),
             .backingOff(let remaining, _),
             .waitingToRetry(let remaining, _):
            return remaining
        }
    }

    func beginSending(remaining: Int, items: [CloudKitSyncPendingItem] = []) {
        guard remaining > 0 else { return }
        cancelPendingCompletion()
        pendingItems = items
        switch phase {
        case .sending(_, let total), .backingOff(_, let total), .waitingToRetry(_, let total):
            // A new CK window is still the same logical drain. Local edits can
            // add work to it, but must never make already recorded progress run
            // backward.
            phase = .sending(
                remaining: remaining,
                total: max(total, uploadedThisPass + remaining)
            )
        case .idle, .receiving:
            uploadedThisPass = 0
            fractionComplete = 0
            phase = .sending(remaining: remaining, total: remaining)
        }
    }

    func advanceSending(
        remaining: Int,
        sentInBatch: Int,
        items: [CloudKitSyncPendingItem] = []
    ) {
        cancelPendingCompletion()
        pendingItems = items
        uploadedThisPass += max(sentInBatch, 0)
        guard case .sending(_, let existingTotal) = phase else { return }
        let total = max(existingTotal, uploadedThisPass + remaining)
        phase = .sending(remaining: remaining, total: total)
        let measuredFraction = total > 0
            ? Double(uploadedThisPass) / Double(total)
            : 0
        fractionComplete = max(fractionComplete ?? 0, min(measuredFraction, 0.995))
    }

    func finishSending(remaining: Int, items: [CloudKitSyncPendingItem] = []) {
        // CKSyncEngine emits no-op send windows too. Without a matching active
        // upload, `didSendChanges` must not manufacture almost-complete progress.
        guard case .sending(_, let existingTotal) = phase else { return }
        let total = max(existingTotal, uploadedThisPass + remaining)
        phase = .sending(remaining: remaining, total: total)
        pendingItems = items

        guard remaining == 0 else {
            cancelPendingCompletion()
            return
        }

        // Hold just shy of completion until the paired fetch and any immediately
        // scheduled follow-up batch have had a chance to join this drain. The
        // final transition is the done state rather than completion that falls
        // back to empty for the next CK window.
        fractionComplete = max(fractionComplete ?? 0, 0.995)
        if !isReceiving {
            scheduleCompletion()
        }
    }

    /// `stalled` decides which of the two waiting states this is: a paced pause
    /// inside a drain that is still moving, or a drain CloudKit has refused
    /// often enough to be worth alarming about. See `CloudKitSyncStallPolicy`.
    func waitToRetry(
        remaining: Int,
        items: [CloudKitSyncPendingItem] = [],
        stalled: Bool
    ) {
        guard remaining > 0 else { return }
        cancelPendingCompletion()
        pendingItems = items
        let total: Int
        switch phase {
        case .sending(_, let existingTotal),
             .backingOff(_, let existingTotal),
             .waitingToRetry(_, let existingTotal):
            total = max(existingTotal, uploadedThisPass + remaining)
        case .idle, .receiving:
            total = max(remaining, uploadedThisPass + remaining)
        }
        phase = stalled
            ? .waitingToRetry(remaining: remaining, total: total)
            : .backingOff(remaining: remaining, total: total)
    }

    /// A fetch never displaces a send in the readout: upload progress carries a
    /// real fraction and the download direction cannot.
    func beginReceiving() {
        isReceiving = true
        cancelPendingCompletion()
        receivedThisPass = 0
        guard phase == .idle else { return }
        fractionComplete = nil
        phase = .receiving(received: 0)
    }

    func finishReceiving() {
        isReceiving = false
        switch phase {
        case .receiving:
            lastCompleted = Date()
            fractionComplete = nil
            phase = .idle
            pendingItems = []
        case .sending(let remaining, _):
            if remaining == 0 {
                scheduleCompletion()
            }
        case .idle, .backingOff, .waitingToRetry:
            break
        }
    }

    func setICloudFull(_ full: Bool) {
        guard isICloudFull != full else { return }
        isICloudFull = full
        // Once per filling, not per refused batch: the Studio says it as a
        // toast, and the iCloud pane keeps saying it while it lasts.
        if full {
            NotificationCenter.default.post(name: .cloudKitICloudStorageDidFill, object: nil)
        }
    }

    private func cancelPendingCompletion() {
        completionTask?.cancel()
        completionTask = nil
    }

    private func scheduleCompletion() {
        cancelPendingCompletion()
        let delay = completionSettleDelay
        completionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !self.isReceiving,
                  case .sending(let remaining, _) = self.phase,
                  remaining == 0 else { return }
            self.lastCompleted = Date()
            self.fractionComplete = nil
            self.phase = .idle
            self.pendingItems = []
            self.completionTask = nil
        }
    }

    /// Hop from the sync actor onto the main actor in event order. The mutation
    /// is only a few scalar assignments; awaiting it prevents independent tasks
    /// from replaying begin/advance/finish out of sequence.
    nonisolated static func publish(
        _ body: @escaping @MainActor (CloudKitSyncStatusCenter) -> Void
    ) async {
        await MainActor.run {
            body(CloudKitSyncStatusCenter.shared)
        }
    }
}
