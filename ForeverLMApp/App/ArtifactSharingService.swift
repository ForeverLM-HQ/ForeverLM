import AppKit
import CloudKit
import Foundation
import OSLog

@MainActor
final class ArtifactSharingService: NSObject, @preconcurrency NSCloudSharingServiceDelegate {
    static let shared = ArtifactSharingService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ArtifactSharing")
    private var activeProvider: NSItemProvider?
    private var activeService: NSSharingService?

    func presentShare(artifactID: String, title: String) {
        let provider = NSItemProvider()
        provider.registerCloudKitShare {
            [artifactID, title] completion in
            Task {
                do {
                    let prepared = try await Self.prepareShare(
                        artifactID: artifactID,
                        title: title
                    )
                    completion(prepared.share, prepared.container, nil)
                } catch {
                    completion(nil, nil, error)
                }
            }
        }
        guard let service = NSSharingService(named: .cloudSharing) else { return }
        service.delegate = self
        activeProvider = provider
        activeService = service
        service.perform(withItems: [provider])
    }

    func options(
        for sharingService: NSSharingService,
        share shareProvider: NSItemProvider
    ) -> NSSharingService.CloudKitOptions {
        // `.allowPublic` is what makes the sheet's Copy Link work: a copied
        // link has no invitee, so the service saves the share with a public
        // permission and only then puts the URL on the pasteboard. Without it
        // the save is refused and Share does nothing visible.
        [.allowPublic, .allowPrivate, .allowReadOnly, .allowReadWrite]
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didCompleteForItems items: [Any],
        error: (any Error)?
    ) {
        if let error {
            logger.error("Doc sharing sheet ended with an error: \(error.localizedDescription, privacy: .public)")
        }
        activeProvider = nil
        activeService = nil
    }

    /// A Doc is shared through a Doc space of the library container (§9.1, D5).
    private static func prepareShare(
        artifactID: String,
        title: String
    ) async throws -> (share: CKShare, container: CKContainer) {
        guard let coordinator = SyncCoordinator.current else { throw SpaceServiceError.syncNotRunning }
        let owner = SyncPerson(user: try await coordinator.transport.userRecordName(), name: coordinator.shares.accountName ?? "")
        let space = try await SpaceService(coordinator: coordinator).docSpace(forArtifact: artifactID, title: title, owner: owner)
        return (try await SpaceShareSheet.share(of: space.zone, in: coordinator.container), coordinator.container)
    }
}

/// A space's zone-wide `CKShare`, as Apple's sharing sheet takes it (generation 2): read from the
/// library container's database that holds the space.
enum SpaceShareSheet {
    static func share(of zone: SpaceZone, in container: CKContainer) async throws -> CKShare {
        let zoneID = CKRecordZone.ID(zoneName: zone.zoneID.zoneName, ownerName: zone.isOwned ? CKCurrentUserDefaultName : zone.zoneID.ownerName)
        let database = zone.isOwned ? container.privateCloudDatabase : container.sharedCloudDatabase
        guard let share = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare else {
            throw ShareServiceError.notShared
        }
        return share
    }
}

final class ForeverLMApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Record the Studio windows that are open, so the next launch can put them
    /// back. Written at quit rather than continuously: the arrangement only
    /// matters as it stood at the end, and capturing reads every window's frame.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            StudioWorkspaceWindowCoordinator.shared.saveLastSession()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The quick assistant's shortcut is heard in every app from launch,
        // whether or not a Studio window is open (docs/quick-assistant-design.md).
        // A UI test or a unit-test host must not take a key from the whole Mac.
        let isTestRun = UITestConfiguration.isUITesting
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestRun {
            MainActor.assumeIsolated { QuickAssistantController.shared.start() }
        }
        // The sync hears CloudKit pushes for its private database (D36).
        if !isTestRun {
            NSApplication.shared.registerForRemoteNotifications()
        }
        #if DIRECT_DOWNLOAD
        // Installed from the disk image, so offer to throw the installer away.
        // The Dev apps are never installed from one.
        if !isTestRun, !ForeverLMRuntimeIdentity.isDevelopment {
            Task { @MainActor in await InstallerImage.offerToTrashMountedInstaller() }
        }
        #endif
        #if DEBUG
        // WP5's Development spike, only when launched for it (`--schema-v2-spike`).
        if !isTestRun { DevelopmentSpike.runIfRequested() }
        #endif
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--run-podcast-cleanup") else {
            return
        }
        let logger = Logger(subsystem: "com.foreverlm", category: "PodcastCleanupMaintenance")
        // The maintenance model runs only this drain; the task itself stays
        // on Background › Text, since no task has a model of its own.
        let routed = KeychainService.routedTextSelection(
            provider: .openai,
            model: AIModelDefaults.podcastCleanupMaintenance
        )
        guard KeychainService.resolveConfig(
            for: .transcriptFormatting,
            explicitlyAuthorizedBackgroundUsage: true
        ) != nil, let apiKey = KeychainService.apiKey(for: routed.provider) else {
            logger.error("Could not resolve the explicitly authorized podcast cleanup route")
            return
        }
        var maintenanceConfig = AITaskConfig(provider: routed.provider, apiKey: apiKey, model: routed.model)
        maintenanceConfig.taskLabel = AITask.transcriptFormatting.rawValue
        Task.detached(priority: .utility) {
            let storage = StorageService()
            if ProcessInfo.processInfo.arguments.contains("--restore-podcast-cleanup-all") {
                do {
                    let restored = try await storage.restorePodcastTranscriptCleanups(limit: 10_000)
                    logger.notice("Restored \(restored.count, privacy: .public) podcast cleanup result(s) for verified rerun")
                } catch {
                    logger.error("Could not restore podcast cleanup results: \(error.localizedDescription, privacy: .public)")
                    return
                }
            } else if ProcessInfo.processInfo.arguments.contains("--restore-podcast-cleanup-pilot") {
                do {
                    let restored = try await storage.restorePodcastTranscriptCleanups(limit: 2)
                    logger.notice("Restored \(restored.count, privacy: .public) podcast cleanup pilot result(s)")
                } catch {
                    logger.error("Could not restore podcast cleanup pilot: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            let service = PodcastTranscriptCleanupService(
                storage: storage,
                aiService: AIService(),
                explicitlyAuthorizedConfig: maintenanceConfig
            )
            logger.notice("Starting explicit podcast transcript cleanup maintenance drain")
            let pilotOnly = ProcessInfo.processInfo.arguments.contains("--podcast-cleanup-pilot")
            while !Task.isCancelled {
                let result = await service.drain()
                logger.notice(
                    "Podcast cleanup batch processed=\(result.processedCount, privacy: .public) remaining=\(result.remainingCount, privacy: .public) error=\(result.errorMessage ?? "none", privacy: .public)"
                )
                if result.remainingCount == 0 {
                    break
                }
                if let error = result.errorMessage {
                    if PodcastTranscriptCleanupService.isRetryableFailure(error) {
                        try? await Task.sleep(for: .seconds(15))
                        continue
                    }
                    break
                }
                if pilotOnly && result.processedCount > 0 {
                    break
                }
                if result.processedCount == 0 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        #endif
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Logger(subsystem: "com.foreverlm", category: "SyncCoordinator").info("Registered for CloudKit pushes")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger(subsystem: "com.foreverlm", category: "SyncCoordinator")
            .error("Could not register for CloudKit pushes: \(error.localizedDescription, privacy: .public)")
    }

    /// A push goes to the coordinator with the database it came from: the private database's to the
    /// private engine and SpaceSync's owned spaces, the shared database's to the joined spaces. Push
    /// is never relied on, since launch, activation and a 15-minute timer fetch too (§2.3).
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let coordinator = SyncCoordinator.current,
              notification.containerIdentifier == coordinator.container.containerIdentifier,
              let database = CloudKitMapping.database(of: notification)
        else { return }
        Task { await coordinator.handleRemoteNotification(from: database) }
    }

    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        // A space of the library container goes to the coordinator's ShareService (§9.7). An invitation
        // to any other container (a team or Doc shared from the old Apple team's container) is not one
        // this build can open.
        guard let coordinator = SyncCoordinator.current,
              metadata.containerIdentifier == coordinator.container.containerIdentifier,
              let url = metadata.share.url else {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ArtifactSharing")
                .error("An invitation for another iCloud container was not opened: \(metadata.containerIdentifier, privacy: .public)")
            return
        }
        Task {
            do {
                let spaces = SpaceService(coordinator: coordinator)
                try await coordinator.acceptShare(CloudShareInvitation(url: url, systemMetadata: metadata)) { _ in
                    try await spaces.adoptJoinedTeams()
                }
                try await spaces.mirrorTeams()
            } catch {
                _ = await MainActor.run { NSAlert(error: error).runModal() }
            }
        }
    }
}
