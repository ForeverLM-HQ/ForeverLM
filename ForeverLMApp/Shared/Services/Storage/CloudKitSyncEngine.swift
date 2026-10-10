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

/// The source records' side of `ICloudStorageUsage`, read from SQLite by
/// `KnowledgeStore.iCloudSyncedSourceStorage()`.
struct ICloudSyncedSourceStorage: Sendable, Equatable {
    /// A source whose record carries its original PDF, as the database
    /// stores its location.
    struct StoredPath: Sendable, Equatable {
        var localFilePath: String?
        var url: String?
    }

    var pdfPaths: [StoredPath]
    /// Each source's text and its prepared versions, which travel as text
    /// assets beside the record.
    var textBytes: Int64
}

/// How much of the learner's iCloud ForeverLM's files take up, as Settings ›
/// Data & Privacy › iCloud and `get_sync_status` show it.
///
/// Apple tells an app nothing about its own CloudKit usage; the exact per-app
/// figure lives only in System Settings › Apple Account › iCloud. So this
/// counts the files the app knows it put there, each at its real size: the
/// original PDFs the source records carry (`sourcePDFAsset`), the source text
/// they carry, and every file in ForeverLM's iCloud Drive container, which
/// today is mostly Listen audio. It leaves out record payloads, thumbnails,
/// covers, and the reader pages of EPUB chapters and saved articles, whose
/// size is only known by building them (docs/backend-storage-sync.md).
struct ICloudStorageUsage: Sendable, Equatable {
    var documentBytes: Int64
    var textBytes: Int64
    var driveBytes: Int64

    var totalBytes: Int64 { documentBytes + textBytes + driveBytes }

    /// ForeverLM's iCloud Drive container, all of it: Apple bills the
    /// container as one, whichever profile's folder a file sits in.
    static var driveContainerRootPath: String {
        // `ubiquityContentRootPath` is `<container>/Documents/<profile folder>`.
        let documents = (StorageService.ubiquityContentRootPath as NSString).deletingLastPathComponent
        return (documents as NSString).deletingLastPathComponent
    }

    /// SQLite on the storage actor, then the file half off it, so the stats and
    /// the directory walk never hold the lane interactive reads queue on.
    static func measure(storage: StorageService) async throws -> ICloudStorageUsage {
        let synced = try await storage.iCloudSyncedSourceStorage()
        return await Task.detached(priority: .utility) {
            ICloudStorageUsage.measure(synced)
        }.value
    }

    /// Stats and a directory walk: never on the main actor.
    static func measure(
        _ synced: ICloudSyncedSourceStorage,
        driveRoot: URL = URL(fileURLWithPath: driveContainerRootPath, isDirectory: true)
    ) -> ICloudStorageUsage {
        ICloudStorageUsage(
            documentBytes: synced.pdfPaths.reduce(0) { $0 + uploadedPDFBytes($1) },
            textBytes: synced.textBytes,
            driveBytes: fileBytes(under: driveRoot)
        )
    }

    /// The bytes `CloudKitRecordMapper` uploads for this source's PDF: the file
    /// itself, resolved the way `resolvedPDFPath` resolves it, or nothing when
    /// it is not on this Mac or is past the asset cap.
    static func uploadedPDFBytes(_ stored: ICloudSyncedSourceStorage.StoredPath) -> Int64 {
        for candidate in [stored.localFilePath, stored.url] {
            guard let candidate, !candidate.isEmpty else { continue }
            let absolute = StorageService.absoluteSourcePath(candidate)
            guard absolute.hasPrefix("/"),
                  let located = StorageService.locateSourceFile(absolute) else { continue }
            guard located.lowercased().hasSuffix(".pdf"),
                  let size = (try? FileManager.default.attributesOfItem(atPath: located))?[.size] as? NSNumber
            else { return 0 }
            let bytes = size.int64Value
            return bytes > 0 && bytes <= Int64(CloudKitRecordMapper.maxPaperPDFAssetBytes) ? bytes : 0
        }
        return 0
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

enum CloudKitInboundWebPDFFailureDisposition: Sendable, Equatable {
    case retryScheduled(CloudKitInboundWebPDFRetry)
    case quarantined
}

enum CloudKitSyncRetryPolicy {
    /// Never retry a throttled send sooner than this, so honouring a very small
    /// server delay cannot turn into a hot loop.
    static let minimumThrottleDelay: TimeInterval = 5

    /// Past this many refusals in a row with nothing sent, the server delay has
    /// stopped describing a drain that is moving.
    static let throttleEscalationGrace = 3

    /// Ceiling for an escalated throttle wait. Long enough to let CloudKit's
    /// limiter refill, short enough that a recovered container resumes without
    /// waiting on a relaunch.
    static let maximumThrottleDelay: TimeInterval = 900

    /// When CloudKit names the moment it will take work again, that answer is
    /// better than any guess this code can make, so it is used as given rather
    /// than as a floor under the local backoff.
    ///
    /// Taking `max` of the two looks safe and is not. A bulk backfill spends
    /// most of its life being throttled — the container rename queued the whole
    /// library at once — and every 429 also counted as a consecutive failure,
    /// so the exponential curve climbed to its 30-minute cap while the server
    /// was asking to be tried again in two seconds. The drain stopped: 7,931
    /// records queued and zero sent over several minutes on 2026-08-30.
    ///
    /// Obeying that answer *forever* is the opposite failure, and it is the one
    /// that actually ran. Because a throttle is deliberately not a consecutive
    /// failure, the delay stayed pinned at whatever the server last asked for,
    /// so the client re-presented the same batch every ~18 seconds and the
    /// server refused every time: 555 consecutive 429s over three hours on
    /// 2026-08-30, 141 records confirmed, 7,929 still queued, zero progress. A
    /// limiter cannot refill while the client keeps re-arming it. So the server
    /// delay is honoured as given while it is still plausibly pacing progress,
    /// and past `throttleEscalationGrace` refusals it is doubled per refusal —
    /// escalating from the server's own number rather than from the local
    /// curve, which is what made the earlier fix necessary.
    static func delaySeconds(
        consecutiveFailures: Int,
        serverRetryAfter: TimeInterval? = nil,
        consecutiveThrottles: Int = 0
    ) -> TimeInterval {
        if let serverDelay = serverRetryAfter, serverDelay.isFinite, serverDelay > 0 {
            let overage = max(0, consecutiveThrottles - throttleEscalationGrace)
            let escalated = serverDelay * pow(2.0, Double(min(overage, 8)))
            return min(max(escalated, minimumThrottleDelay), maximumThrottleDelay)
        }
        let exponent = min(max(consecutiveFailures, 1) - 1, 5)
        return min(60.0 * pow(2.0, Double(exponent)), 1_800.0)
    }

    static func serverRetryAfterSeconds(from error: Error) -> TimeInterval? {
        guard let value = (error as NSError).userInfo[CKErrorRetryAfterKey] as? NSNumber else {
            return nil
        }
        let seconds = value.doubleValue
        return seconds > 0 ? seconds : nil
    }

    /// Backpressure, not breakage. The server is healthy and is pacing us, so
    /// these must not advance the consecutive-failure count that exists to back
    /// away from a genuinely broken sync.
    static func isServerThrottle(_ error: Error) -> Bool {
        guard let code = (error as? CKError)?.code else { return false }
        switch code {
        case .requestRateLimited, .serviceUnavailable, .zoneBusy:
            return true
        default:
            return false
        }
    }
}

/// Separates a drain that is being paced from one that has stopped.
///
/// Backing off is the normal condition of a migration-sized backlog, not an
/// error: a throttled backfill spends most of its life waiting, and single
/// windows that land nothing are seams in one long drain. Reporting each of
/// those as "waiting to retry" told the learner a healthy, steadily draining
/// re-upload had failed — orange clock, retry button and all — while the queue
/// was in fact shrinking every minute.
///
/// Only a streak of attempts the server never took is worth that alarm.
enum CloudKitSyncStallPolicy {
    static let stalledAttemptThreshold = 3

    static func isStalled(consecutiveFailures: Int, consecutiveThrottles: Int) -> Bool {
        max(consecutiveFailures, consecutiveThrottles) >= stalledAttemptThreshold
    }
}

/// Paces a migration-sized backlog so it cannot earn a CloudKit rate limit.
///
/// Sends are already capped at 100 records per batch, so the burst that trips
/// the limiter is not batch size but batch *frequency*: a successful send asks
/// for the next one immediately, and a container rename queues the entire
/// library, so ~80 back-to-back batches leave in a few seconds. CloudKit
/// answers with HTTP 429 and then nothing moves at all — which is exactly what
/// happened on 2026-08-30 with 7,931 records queued.
///
/// Ordinary editing backlogs are far below the threshold and keep their
/// immediate follow-on send; only a backfill pays the gap.
enum CloudKitSyncBackfillPolicy {
    /// Beyond this many queued records the backlog is a migration, not edits.
    static let migrationBacklogThreshold = 500

    /// Gap between backfill batches. At 100 records a batch this drains a
    /// whole-library backfill in minutes while staying far off the limiter.
    static let batchPacingNanoseconds: UInt64 = 3_000_000_000

    /// How long staged asset digests may go unacknowledged before the engine
    /// says so. Generous on purpose: a paced backfill legitimately holds
    /// staging across many batches at `batchPacingNanoseconds` apiece, and an
    /// alarm that fires during normal draining would be turned off and then
    /// mean nothing.
    static let stalledStagingGrace: TimeInterval = 60 * 60

    /// One re-stage is ordinary — a save in flight, or one visible failure that
    /// reset and retried. Repeated re-staging of the same content with no
    /// acknowledgement either way is the shape worth reporting.
    static let stalledStagingMinimumAttempts = 3

    static func shouldPaceNextBatch(pendingCount: Int) -> Bool {
        pendingCount > migrationBacklogThreshold
    }

    /// The same threshold decides whether to ship metadata first. A migration
    /// carries the whole library, and the library's weight is content — papers,
    /// article archives, book and course files — not the records themselves.
    /// Sending the records alone makes every device show the library in
    /// minutes; the content follows in a second pass.
    static func shouldDeferContent(pendingCount: Int) -> Bool {
        pendingCount > migrationBacklogThreshold
    }

    /// Records re-queued for their content per pass once the metadata is
    /// through. Bounded so the content pass never rebuilds the firehose the
    /// pacing above exists to prevent.
    static let contentPassBatchSize = 200
}

struct CloudKitSyncBacklogCheckpoint: Equatable {
    let pendingCount: Int
    let successfulChangeGeneration: UInt64
    let localChangeGeneration: UInt64

    func shouldContinueImmediately(to current: Self) -> Bool {
        current.pendingCount != pendingCount
            || current.successfulChangeGeneration != successfulChangeGeneration
            || current.localChangeGeneration != localChangeGeneration
    }

    /// Whether the *server* took work, as opposed to the queue merely moving.
    /// `shouldContinueImmediately` counts a local edit as a reason to keep
    /// going, which is right for scheduling and wrong for clearing a throttle:
    /// an app that keeps writing rows would otherwise erase the evidence that
    /// CloudKit has refused every batch for hours.
    func didDrain(to current: Self) -> Bool {
        current.successfulChangeGeneration != successfulChangeGeneration
            || current.pendingCount < pendingCount
    }
}

/// CKSyncEngine must not run its own sender alongside this actor's explicit
/// flush/retry coordinator. Automatic sends ignore `retryTask`, so a record
/// conflict can be retried every few seconds while the UI claims the engine is
/// backing off. Those overlapping sends also keep companion records queued
/// behind the conflict instead of letting the actor adopt the server winner and
/// continue the drain.
enum CloudKitSyncSendPolicy {
    static let allowsEngineAutomaticSync = false
}

/// A batch-level CloudKit failure does not identify the record that poisoned an
/// atomic request. Retrying the same batch preserves the ambiguity forever, so
/// the following pass sends one change at a time. A singleton failure is then a
/// real failure of that change and can use the normal bounded quarantine path.
enum CloudKitSyncBatchIsolationPolicy {
    static func batchLimit(defaultLimit: Int, isIsolating: Bool) -> Int {
        isIsolating ? 1 : defaultLimit
    }

    static func isSingletonFailure(failedChangeCount: Int) -> Bool {
        failedChangeCount == 1
    }

    static func requiresImmediateIsolationPass(failedChangeCount: Int) -> Bool {
        failedChangeCount > 1
    }
}

/// CloudKit refuses a request that costs more than its limiter will currently
/// spend, and a 429 does not say which part was too expensive. Re-presenting an
/// identically sized batch therefore buys an identically sized refusal, which is
/// how a whole-library backfill can sit at zero sent for hours. Waiting longer
/// (`CloudKitSyncRetryPolicy`) lets the limiter refill; sending less asks it for
/// less on the way back. The two together are what let a refused drain restart.
enum CloudKitSyncThrottleAdaptation {
    /// Never shrink below this: a batch of one turns a large backlog into one
    /// round trip per record, which is its own kind of never finishing.
    static let minimumBatchLimit = 5

    static func batchLimit(defaultLimit: Int, consecutiveThrottles: Int) -> Int {
        guard consecutiveThrottles > 0, defaultLimit > minimumBatchLimit else { return defaultLimit }
        let shrunk = defaultLimit >> min(consecutiveThrottles, 4)
        return max(shrunk, minimumBatchLimit)
    }
}

/// Generation 1's sync engine, dormant until WP30 deletes it: no build runs generation 1, whose
/// container stayed with the old Apple team, and nothing constructs this actor (`StorageService` no
/// longer makes one, and its initializer is private to this file). The static helpers below it still
/// serve the generation-1 store code and its tests.
actor CloudKitSyncEngine {
    private static let bootstrapModificationDate = CloudKitSyncBootstrapStamp.date
    private static let environmentDefaultsKey = "CloudKitSync.lastContainerEnvironment.v2"
    private static let containerIdentifierDefaultsKey = "CloudKitSync.lastContainerIdentifier.v1"
    private static let artifactBodyRepairDefaultsKey = "CloudKitSync.artifactBodyRepair.v2"
    private static let maxRecordZoneChangesPerBatch = 100

    /// True when this launch talks to a different CloudKit database than the
    /// one whose CKRecord system fields SQLite still holds. An unmarked
    /// Production launch is the original Development → Production promotion;
    /// a container-identifier change is the FeynmanLM → ForeverLM rename.
    static func needsReplicaRebase(
        previousEnvironment: String?,
        currentEnvironment: String,
        previousContainer: String?,
        currentContainer: String
    ) -> Bool {
        let environmentChanged = previousEnvironment == nil
            ? currentEnvironment == CloudRuntimeAvailability.ContainerEnvironment.production.rawValue
            : previousEnvironment != currentEnvironment
        return environmentChanged || previousContainer != currentContainer
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CloudKitSync")
    private let store: KnowledgeStore
    private let container: CKContainer
    /// One CKSyncEngine per database. The private database carries the
    /// learner's own `Knowledge` zone and every team they created; the shared
    /// database carries the teams they were invited to. Both engines share
    /// this actor's delegate code and the one durable queue, which routes each
    /// change by its home's scope.
    private var engines: [CloudKitZoneHome.Scope: CKSyncEngine] = [:]
    /// The private-database engine, under the name most of this file has
    /// always used for it.
    private var syncEngine: CKSyncEngine? { engines[.privateScope] }
    private var sharedSyncEngine: CKSyncEngine? { engines[.shared] }
    /// The private database, for the reconciliation passes that only ever
    /// concern the learner's own zone.
    private var database: CKDatabase { container.privateCloudDatabase }
    private var started = false
    private var isStarting = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var observerTask: Task<Void, Never>?
    /// Re-sends the walks whose pictures changed in the image store.
    private var pictureObserverTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var inboundWebPDFRetryTask: Task<Void, Never>?
    private var isFlushing = false
    private var isRetryingInboundWebPDFs = false
    private var flushAgainRequested = false
    /// True while the outbound queue is migration-sized, in which case records
    /// ship without their content assets and owe them to a later pass.
    private var isDeferringContentForBackfill = false
    private var consecutiveSendFailures = 0

    /// Server throttles refused in a row without anything draining. Kept apart
    /// from `consecutiveSendFailures` because backpressure is not breakage — but
    /// it still has to be counted, or an unending throttle looks like a healthy
    /// pace and is retried at the same interval forever.
    private var consecutiveServerThrottles = 0
    private var requestedServerRetryAfter: TimeInterval?
    private var artifactBodyRepairLastAttemptAt: Date?
    private var successfulChangeGeneration: UInt64 = 0
    private var localChangeGeneration: UInt64 = 0
    private var courseReconciliationNeeded = true
    private var bookCoverReconciliationNeeded = true
    private var sourcePDFReconciliationNeeded = true
    /// Sources `reconcileMissingSourcePDFs` has already read this launch.
    private var sourceDocumentRecoveryAttempted: Set<String> = []
    private var inFlightSaveModificationDates: [String: Date] = [:]
    /// Consecutive failed sends per record, for the two failure branches that
    /// re-queue a record unchanged. Those retries are otherwise unbounded: a
    /// record that fails the same way every pass keeps the pending count above
    /// zero forever and prevents an otherwise healthy library from converging.
    /// Held in memory on purpose — engine start is
    /// already the re-arm point for quarantined saves, so a relaunch gives every
    /// record a clean slate without a schema change.
    private var consecutiveSaveFailuresByRecord: [String: Int] = [:]
    /// After CloudKit reports `.batchRequestFailed`, shrink the next request to
    /// one change. Otherwise the same oldest record can keep poisoning the same
    /// atomic batch while every companion reports only the unhelpful batch error.
    private var isIsolatingFailedBatch = false
    /// Attempts a record gets before it is parked in `sync_conflicts` instead of
    /// re-queued. Generous enough that ordinary conflict churn resolves itself.
    private static let maxConsecutiveRecordSaveFailures = 5
    /// Fetches per parked record per launch before the repair below stops
    /// asking. Three is enough to ride out a transient fetch failure; a record
    /// the server keeps refusing after that is left visible in Settings.
    private static let maxTaglessRepairAttemptsPerLaunch = 3
    private static let taglessRepairBatchSize = 100
    private var taglessRepairAttemptsByRecord: [String: Int] = [:]

    /// Book records are small — an encrypted payload and a downscaled JPEG — so
    /// a recovery read batches like any other bulk fetch.
    private static let bookCoverRecoveryBatchSize = 40

    /// Original PDFs are two orders of magnitude larger than a downscaled cover,
    /// so a recovery pass reads far fewer records and hands control back.
    private static let sourcePDFRecoveryBatchSize = 8

    fileprivate init(
        container: CKContainer,
        storeDirectory: URL,
        contentDirectory: URL,
        legacyContentDirectories: [URL]
    ) throws {
        let store = try KnowledgeStore(
            storeDirectory: storeDirectory,
            contentDirectory: contentDirectory,
            legacyContentDirectories: legacyContentDirectories
        )
        // Inbound text queues a Listen preparation only for the kinds
        // automatic audio covers (`enqueueSourceListenableContentPreparation`).
        store.automaticAudioSourceTypes = { SourceAudioAutomation.enabledSourceTypes() }
        self.store = store
        self.container = container
    }

    private func scope(of engine: CKSyncEngine) -> CloudKitZoneHome.Scope {
        engines.first { $0.value === engine }?.key ?? .privateScope
    }

    private func engine(for scope: CloudKitZoneHome.Scope) -> CKSyncEngine? {
        engines[scope]
    }

    private func cloudDatabase(for scope: CloudKitZoneHome.Scope) -> CKDatabase {
        scope == .shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    /// Queue a zone save for a record's home. Only the private database takes
    /// zone saves from this account: a member cannot create the owner's zone.
    private func ensureZoneExists(for home: CloudKitZoneHome) {
        guard home.scope == .privateScope else { return }
        syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: home.zoneID))])
    }

    func start() async {
        guard !started else { return }
        // ForeverLMMacUnitTests runs against the real app as its TEST_HOST, so
        // without this every test run signed in as the developer and began
        // syncing their actual iCloud library. Several sessions running suites
        // through 2026-08-30 kept a container rate limited between them, and
        // the traffic looked like the app misbehaving rather than the tests.
        // LegacyIdentityAdoption already refuses to run under XCTest; sync has
        // far more reason to.
        guard !LegacyIdentityAdoption.isRunningAutomatedTests else {
            logger.info("Skipping CloudKit sync: running under automated tests")
            return
        }
        // The First Run app signs in to the same iCloud account as the Dev app,
        // and CloudKit keys the private database by account, not by bundle.
        // Syncing there would download the whole seeded Dev library into what
        // is meant to be a stranger's first launch.
        guard !ForeverLMRuntimeIdentity.isFirstRun else {
            logger.info("Skipping CloudKit sync: the First Run app never syncs the Dev library")
            return
        }
        if isStarting {
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
            return
        }
        isStarting = true

        prepareForContainerEnvironmentIfNeeded()
        await initializeIfNeeded()
        startObservingLocalChanges()
        await bootstrapIfNeeded()
        await requeueRejectedChanges()
        await fetchRemoteChanges()
        await repairArtifactBodiesIfNeeded()
        await retryDueInboundWebPDFs()
        scheduleInboundWebPDFRetry()
        scheduleFlushSoon()

        started = true
        isStarting = false
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Requeue each locally readable Doc once so its next save includes the
    /// canonical body path and any retired product-scheme links are adopted.
    /// The marker is written only after the durable queue transaction succeeds.
    private func repairArtifactBodiesIfNeeded() async {
        let defaults = UserDefaults.standard
        let markerKey = Self.artifactBodyRepairDefaultsKey
            + "."
            + CloudRuntimeAvailability.containerEnvironment.rawValue
        guard !defaults.bool(forKey: markerKey) else { return }
        let now = Date()
        if let lastAttempt = artifactBodyRepairLastAttemptAt,
           now.timeIntervalSince(lastAttempt) < 30 {
            return
        }
        artifactBodyRepairLastAttemptAt = now
        var lastScannedID: String?
        var totalQueued = 0
        var totalAdoptedLinks = 0
        var totalDeferredDownloads = 0
        var totalDeferredConflicts = 0
        do {
            while !Task.isCancelled {
                let batch = try store.enqueueArtifactBodyRepairBatch(
                    after: lastScannedID,
                    limit: 50
                )
                totalQueued += batch.queuedCount
                totalAdoptedLinks += batch.adoptedLinkCount
                totalDeferredDownloads += batch.deferredDownloadCount
                totalDeferredConflicts += batch.deferredConflictCount
                if batch.queuedCount > 0 {
                    await schedulePendingChangesFromStore()
                }
                if batch.isComplete {
                    if totalDeferredDownloads == 0, totalDeferredConflicts == 0 {
                        defaults.set(true, forKey: markerKey)
                    } else {
                        logger.notice(
                            "Deferred Doc body repair for \(totalDeferredDownloads) downloads and \(totalDeferredConflicts) conflicts"
                        )
                    }
                    if totalQueued > 0 {
                        logger.notice("Queued \(totalQueued) Doc bodies for CloudKit repair")
                    }
                    if totalAdoptedLinks > 0 {
                        logger.notice("Adopted retired product links in \(totalAdoptedLinks) Docs")
                    }
                    return
                }
                guard let nextID = batch.lastScannedID,
                      nextID != lastScannedID else {
                    throw KnowledgeStoreError.invalidData(
                        "Doc body repair could not advance its cursor."
                    )
                }
                lastScannedID = nextID
                await Task.yield()
            }
        } catch {
            logger.error("Failed to queue Doc body repair: \(error.localizedDescription)")
        }
    }

    /// Development and Production are separate CloudKit databases, and the
    /// FeynmanLM → ForeverLM rename also changed the container identifier.
    /// The app keeps one local SQLite library either way. The first launch
    /// against a different environment or container must discard the previous
    /// server metadata and put every locally acknowledged record back on the
    /// durable outbound queue.
    ///
    /// This runs on the sync actor, not the main actor. The SQLite operation is
    /// one transaction made entirely of set-based metadata statements; record
    /// payloads and assets are rebuilt later by CKSyncEngine in bounded sends.
    private func prepareForContainerEnvironmentIfNeeded() {
        let environment = CloudRuntimeAvailability.containerEnvironment
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.environmentDefaultsKey)
        let previousContainer = defaults.string(forKey: Self.containerIdentifierDefaultsKey)
        let currentContainer = container.containerIdentifier ?? ""

        guard Self.needsReplicaRebase(
            previousEnvironment: previous,
            currentEnvironment: environment.rawValue,
            previousContainer: previousContainer,
            currentContainer: currentContainer
        ) else { return }

        do {
            let enqueued = try store.rebaseCloudKitStateForContainerEnvironment()
            defaults.set(environment.rawValue, forKey: Self.environmentDefaultsKey)
            defaults.set(currentContainer, forKey: Self.containerIdentifierDefaultsKey)
            logger.notice(
                "Rebased CloudKit state for \(environment.rawValue, privacy: .public) container \(currentContainer, privacy: .public); queued \(enqueued) local records"
            )
        } catch {
            // Leave the marker untouched so the next launch retries the same
            // idempotent transaction instead of silently accepting a half move.
            logger.error(
                "Failed to rebase CloudKit state for \(environment.rawValue, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    func notifyLocalChangesAvailable(flushSoon: Bool = false) async {
        await start()
        await schedulePendingChangesFromStore()
        scheduleFlushSoon(delayNanoseconds: flushSoon ? 750_000_000 : 3_000_000_000)
    }

    func syncNow() async {
        await start()
        await repairArtifactBodiesIfNeeded()
        flushTask?.cancel()
        flushTask = nil
        // Automatic activation/import syncs still fetch remote work during an
        // outbound backoff, but they do not defeat CloudKit's retry window or
        // re-arm a record that was deliberately parked after a refusal.
        guard retryTask == nil else {
            await fetchRemoteChanges()
            return
        }
        await flushPendingChanges(fetchAfterSend: true)
    }

    func retryNow() async {
        await start()
        await repairArtifactBodiesIfNeeded()
        // This path exists only for the learner's explicit Retry action. It is
        // allowed to override the pending backoff and give refused records one
        // more attempt after an external CloudKit/schema fix.
        await requeueRejectedChanges()
        retryTask?.cancel()
        retryTask = nil
        flushTask?.cancel()
        flushTask = nil
        requestedServerRetryAfter = nil
        await flushPendingChanges(fetchAfterSend: true)
    }

    private func scheduleFlushSoon(delayNanoseconds: UInt64 = 750_000_000) {
        // While a failure backoff is pending, the retry owns the next attempt; new local
        // changes get picked up then instead of hammering a send that keeps failing.
        guard retryTask == nil else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            // Detached from this task's cancellation so a later scheduleFlushSoon can't
            // cancel a send that is already in flight.
            await Task { await self.flushPendingChanges(fetchAfterSend: true) }.value
        }
    }

    private func flushPendingChanges(fetchAfterSend: Bool) async {
        // sendChanges suspends, so overlapping flushes would otherwise run concurrently.
        // Concurrent sends cancel each other's operations and re-upload the same assets.
        if isFlushing {
            flushAgainRequested = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushAgainRequested = false
            await performFlush(fetchAfterSend: fetchAfterSend)
        } while flushAgainRequested
    }

    private func performFlush(fetchAfterSend: Bool) async {
        await schedulePendingChangesFromStore()
        guard !engines.isEmpty else { return }
        let pendingCount = (try? store.pendingSyncChangeCount()) ?? 0
        isDeferringContentForBackfill = CloudKitSyncBackfillPolicy.shouldDeferContent(
            pendingCount: pendingCount
        )
        let checkpoint = CloudKitSyncBacklogCheckpoint(
            pendingCount: pendingCount,
            successfulChangeGeneration: successfulChangeGeneration,
            localChangeGeneration: localChangeGeneration
        )
        do {
            // The private database first: it is where nearly everything lives,
            // and a team the learner owns is created there before members can
            // see it. The shared engine follows with the teams they joined.
            for scope in [CloudKitZoneHome.Scope.privateScope, .shared] {
                guard let engine = engines[scope] else { continue }
                try await engine.sendChanges()
                if fetchAfterSend {
                    try await engine.fetchChanges()
                }
            }
            if fetchAfterSend {
                await repairTaglessQuarantinedSaves()
                if courseReconciliationNeeded {
                    await reconcileCourseRecords()
                }
                await reconcileMissingBookCovers()
                await reconcileMissingSourcePDFs()
            }
            await retryDueInboundWebPDFs()
            await inspectPendingBacklogAfterFlush(checkpoint: checkpoint)
        } catch {
            observeServerRetryAfter(from: error)
            if !(error is CancellationError),
               (error as? CKError)?.code != .operationCancelled {
                if CloudKitSyncRetryPolicy.isServerThrottle(error) {
                    consecutiveServerThrottles += 1
                } else {
                    consecutiveSendFailures += 1
                }
            }
            logger.error(
                "CloudKit sync failed (consecutive failures: \(self.consecutiveSendFailures), throttles: \(self.consecutiveServerThrottles)): \(error.localizedDescription)"
            )
            await scheduleRetry()
        }
    }

    private func fetchRemoteChanges() async {
        guard !engines.isEmpty else { return }
        do {
            for scope in [CloudKitZoneHome.Scope.privateScope, .shared] {
                try await engines[scope]?.fetchChanges()
            }
            if courseReconciliationNeeded {
                await reconcileCourseRecords()
            }
            await reconcileMissingBookCovers()
            await reconcileMissingSourcePDFs()
        } catch {
            logger.error("CloudKit fetch failed: \(error.localizedDescription)")
        }
    }

    /// Classify and persist only failures produced by the Web Studio PDF
    /// materializer. The fetched-event handler calls this synchronously before
    /// returning, so the durable row commits before CKSyncEngine can serialize
    /// an advanced zone token.
    @discardableResult
    static func persistInboundWebPDFFailure(
        _ error: Error,
        record: CKRecord,
        store: KnowledgeStore,
        failedAt: Date = Date()
    ) throws -> CloudKitInboundWebPDFFailureDisposition? {
        guard let storeError = error as? KnowledgeStoreError else { return nil }
        let descriptor = try CloudKitRecordMapper.descriptor(for: record)
        switch storeError {
        case .transientInboundWebPDF(let reason):
            let retry = try store.saveInboundWebPDFRetry(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey,
                recordName: record.recordID.recordName,
                failureReason: reason,
                serverModificationDate: descriptor.userModificationDate,
                serverPayload: CloudKitRecordMapper.encodedPayloadData(from: record),
                serverSystemFields: CloudKitRecordMapper.encodeSystemFields(record),
                failedAt: failedAt
            )
            return .retryScheduled(retry)
        case .permanentInboundWebPDF(let reason):
            let localModificationDate = try store.loadSyncMetadata(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey
            )?.userModificationDate ?? descriptor.userModificationDate
            try store.quarantineSyncConflict(CloudKitSyncConflict(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey,
                recordName: record.recordID.recordName,
                reason: CloudKitInboundWebPDFRetry.quarantineReasonPrefix + reason,
                localModificationDate: localModificationDate,
                serverModificationDate: descriptor.userModificationDate,
                detectedAt: failedAt,
                serverPayload: CloudKitRecordMapper.encodedPayloadData(from: record),
                serverSystemFields: CloudKitRecordMapper.encodeSystemFields(record)
            ))
            return .quarantined
        default:
            return nil
        }
    }

    /// Persistence helpers are also exercised against isolated test stores in
    /// the app-hosted unit-test process. Keep process-global UI notification at
    /// the live engine boundary so a test database cannot alert the running app.
    private static func postSyncConflictNotification(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        reason: String
    ) {
        NotificationCenter.default.post(
            name: .cloudKitSyncConflictDidOccur,
            object: nil,
            userInfo: [
                CloudKitSyncNotificationInfo.conflictEntityKey: entity.rawValue,
                CloudKitSyncNotificationInfo.conflictLogicalKey: logicalKey,
                CloudKitSyncNotificationInfo.conflictReasonKey: reason,
            ]
        )
    }

    /// Apply a freshly direct-fetched record for a retry row. This is the same
    /// recovery primitive used by the production engine and focused tests. A
    /// local edit made after the failed fetch wins normally; otherwise the
    /// source, metadata, retry deletion, and any required republish converge
    /// idempotently even if the prior zone token is long committed.
    @discardableResult
    static func applyInboundWebPDFRetry(
        _ retry: CloudKitInboundWebPDFRetry,
        record: CKRecord,
        store: KnowledgeStore,
        sourceContentRoot: URL? = nil,
        durableImportRoot: URL? = nil
    ) throws -> CloudKitAppliedRecord? {
        let descriptor = try CloudKitRecordMapper.descriptor(for: record)
        guard descriptor.entity == retry.entity,
              descriptor.logicalKey == retry.logicalKey,
              record.recordID.recordName == retry.recordName else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "Direct-fetched CloudKit web PDF identity no longer matches its retry row."
            )
        }

        let localMetadata = try store.loadSyncMetadata(
            entity: descriptor.entity,
            logicalKey: descriptor.logicalKey
        )
        if localMetadata?.isDeleted == true {
            try store.clearSyncConflict(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey
            )
            return nil
        }
        let hasPendingLocalChange = try store.hasPendingSyncChange(
            entity: descriptor.entity,
            logicalKey: descriptor.logicalKey
        )
        if hasPendingLocalChange,
           let localMetadata,
           localMetadata.userModificationDate > descriptor.userModificationDate {
            try store.clearSyncConflict(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey
            )
            return nil
        }

        let applied = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: sourceContentRoot,
            durableImportRoot: durableImportRoot
        )
        guard applied.entity == retry.entity, applied.logicalKey == retry.logicalKey else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "Applied CloudKit web PDF identity no longer matches its retry row."
            )
        }
        try store.saveSyncMetadata(CloudKitSyncMetadata(
            entity: applied.entity,
            logicalKey: applied.logicalKey,
            recordName: record.recordID.recordName,
            systemFieldsData: CloudKitRecordMapper.encodeSystemFields(record),
            userModificationDate: applied.userModificationDate,
            isDeleted: false
        ))
        try store.clearSyncConflict(entity: applied.entity, logicalKey: applied.logicalKey)
        try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
        if applied.requiresRepublish {
            try store.markRecordChanged(
                entity: applied.entity,
                logicalKey: applied.logicalKey,
                at: max(Date(), applied.userModificationDate.addingTimeInterval(0.001))
            )
        }
        return applied
    }

    private func scheduleInboundWebPDFRetry() {
        inboundWebPDFRetryTask?.cancel()
        inboundWebPDFRetryTask = nil
        let nextAttemptAt: Date
        do {
            guard let storedDate = try store.nextInboundWebPDFRetryDate() else { return }
            nextAttemptAt = storedDate
        } catch {
            logger.error(
                "Could not schedule durable inbound PDF retry: \(error.localizedDescription)"
            )
            return
        }
        let delay = max(0, nextAttemptAt.timeIntervalSinceNow)
        let nanoseconds = UInt64(min(delay, 60 * 60) * 1_000_000_000)
        inboundWebPDFRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            await self.retryDueInboundWebPDFs()
        }
    }

    private func retryDueInboundWebPDFs(now: Date = Date()) async {
        guard !isRetryingInboundWebPDFs else { return }
        isRetryingInboundWebPDFs = true
        defer {
            isRetryingInboundWebPDFs = false
            scheduleInboundWebPDFRetry()
        }

        let retries: [CloudKitInboundWebPDFRetry]
        do {
            retries = try store.loadInboundWebPDFRetries(dueAt: now)
        } catch {
            logger.error("Could not load durable inbound PDF retries: \(error.localizedDescription)")
            return
        }
        guard !retries.isEmpty else { return }

        let retriesByRecordID = Dictionary(uniqueKeysWithValues: retries.map { retry in
            (
                CKRecord.ID(recordName: retry.recordName, zoneID: CloudKitRecordMapper.zoneID),
                retry
            )
        })
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database.records(for: Array(retriesByRecordID.keys))
        } catch {
            for retry in retries {
                rescheduleInboundWebPDFFetchFailure(retry, error: error, failedAt: now)
            }
            return
        }

        var affectedEntities = Set<CloudKitSyncEntity>()
        for (recordID, retry) in retriesByRecordID {
            guard let result = results[recordID] else {
                rescheduleInboundWebPDFFetchFailure(
                    retry,
                    error: CKError(.networkFailure),
                    failedAt: now
                )
                continue
            }
            switch result {
            case .success(let record):
                do {
                    if let applied = try Self.applyInboundWebPDFRetry(
                        retry,
                        record: record,
                        store: store
                    ) {
                        affectedEntities.insert(applied.entity)
                    }
                } catch {
                    do {
                        if let disposition = try Self.persistInboundWebPDFFailure(
                            error,
                            record: record,
                            store: store,
                            failedAt: now
                        ) {
                            switch disposition {
                            case .retryScheduled:
                                logger.info(
                                    "Deferred CloudKit web PDF retry for \(retry.recordName, privacy: .public): \(error.localizedDescription)"
                                )
                            case .quarantined:
                                Self.postSyncConflictNotification(
                                    entity: retry.entity,
                                    logicalKey: retry.logicalKey,
                                    reason: error.localizedDescription
                                )
                                logger.error(
                                    "Quarantined malformed CloudKit web PDF \(retry.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        } else {
                            try quarantineUnexpectedInboundWebPDFFailure(
                                retry,
                                record: record,
                                error: error,
                                failedAt: now
                            )
                        }
                    } catch {
                        logger.error(
                            "Could not persist CloudKit web PDF retry outcome for \(retry.recordName, privacy: .public): \(error.localizedDescription)"
                        )
                    }
                }
            case .failure(let error):
                if (error as? CKError)?.code == .unknownItem {
                    do {
                        let metadata = CloudKitSyncMetadata(
                            entity: retry.entity,
                            logicalKey: retry.logicalKey,
                            recordName: retry.recordName,
                            systemFieldsData: nil,
                            userModificationDate: now,
                            isDeleted: false
                        )
                        try applyDeletion(for: metadata, deletedAt: now)
                        try store.clearSyncConflict(
                            entity: retry.entity,
                            logicalKey: retry.logicalKey
                        )
                        affectedEntities.insert(retry.entity)
                    } catch {
                        logger.error(
                            "Could not settle deleted CloudKit web PDF retry \(retry.recordName, privacy: .public): \(error.localizedDescription)"
                        )
                    }
                } else {
                    rescheduleInboundWebPDFFetchFailure(retry, error: error, failedAt: now)
                }
            }
        }

        if !affectedEntities.isEmpty {
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange,
                object: nil,
                userInfo: [
                    CloudKitSyncNotificationInfo.affectedEntitiesKey: affectedEntities.map(\.rawValue),
                ]
            )
        }
        await schedulePendingChangesFromStore()
    }

    private func rescheduleInboundWebPDFFetchFailure(
        _ retry: CloudKitInboundWebPDFRetry,
        error: Error,
        failedAt: Date
    ) {
        do {
            _ = try store.saveInboundWebPDFRetry(
                entity: retry.entity,
                logicalKey: retry.logicalKey,
                recordName: retry.recordName,
                failureReason: "CloudKit direct fetch failed: " + error.localizedDescription,
                serverModificationDate: retry.serverModificationDate,
                serverPayload: retry.serverPayload,
                serverSystemFields: retry.serverSystemFields,
                failedAt: failedAt
            )
        } catch {
            logger.error(
                "Could not reschedule inbound PDF fetch for \(retry.recordName, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    private func quarantineUnexpectedInboundWebPDFFailure(
        _ retry: CloudKitInboundWebPDFRetry,
        record: CKRecord,
        error: Error,
        failedAt: Date
    ) throws {
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: retry.entity,
            logicalKey: retry.logicalKey,
            recordName: retry.recordName,
            reason: CloudKitInboundWebPDFRetry.quarantineReasonPrefix
                + "Retry failed permanently: " + error.localizedDescription,
            localModificationDate: retry.serverModificationDate,
            serverModificationDate: retry.serverModificationDate,
            detectedAt: failedAt,
            serverPayload: CloudKitRecordMapper.encodedPayloadData(from: record),
            serverSystemFields: CloudKitRecordMapper.encodeSystemFields(record)
        ))
        Self.postSyncConflictNotification(
            entity: retry.entity,
            logicalKey: retry.logicalKey,
            reason: error.localizedDescription
        )
    }

    /// Re-fetch course records after the change stream has drained.
    ///
    /// Older builds applied fetched records in CloudKit's arbitrary delivery
    /// order. When a course arrived before one of its source records,
    /// `saveCourseGroup` committed the metadata but `saveCourseOutline` failed
    /// its source foreign-key check. CKSyncEngine still advanced its zone token,
    /// so that course was never offered again and appeared permanently empty on
    /// the receiving Mac. Directly reading the small set of known course records
    /// repairs those already-advanced records after their sources are present.
    /// Re-acquire a change tag for the saves the sent-changes handler parked
    /// as oplock misses without a server record, then send them again.
    ///
    /// The handler quarantines rather than fetching so that the failure is
    /// visible and bounded the moment it happens; this is the repair it
    /// defers to, run once the send window has closed. Each parked record is
    /// fetched by name:
    ///
    /// - the server holds it and the local copy is at least as new: the local
    ///   row adopts the server's tag and its save is queued again, so the next
    ///   send is a conditional write that lands;
    /// - the server holds a newer copy: the server wins, exactly as it would
    ///   have had the refusal carried the record in the first place;
    /// - the local row is gone: it was deleted while parked, which the
    ///   quarantine guard could not tombstone, so the delete is queued now;
    /// - the server does not hold it: the create is simply re-armed.
    ///
    /// Attempts are counted per record per launch so a record the server keeps
    /// refusing costs a bounded number of fetches and stays in Settings.
    private func repairTaglessQuarantinedSaves() async {
        let parked: [CloudKitTaglessSaveQuarantine]
        do {
            parked = try store.loadTaglessRejectedSaveQuarantines()
        } catch {
            logger.error("Could not load parked tagless saves: \(error.localizedDescription, privacy: .public)")
            return
        }
        let eligible = parked.filter {
            (taglessRepairAttemptsByRecord[$0.recordName] ?? 0) < Self.maxTaglessRepairAttemptsPerLaunch
        }
        guard !eligible.isEmpty else { return }

        var adopted = 0
        var serverWon = 0
        var tombstoned = 0
        var released = 0
        var affectedEntities = Set<CloudKitSyncEntity>()

        for start in stride(from: 0, to: eligible.count, by: Self.taglessRepairBatchSize) {
            let batch = Array(eligible[start..<min(start + Self.taglessRepairBatchSize, eligible.count)])
            let quarantinesByRecordID = Dictionary(uniqueKeysWithValues: batch.map { quarantine in
                (CKRecord.ID(recordName: quarantine.recordName, zoneID: CloudKitRecordMapper.zoneID), quarantine)
            })
            let results: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                results = try await database.records(for: Array(quarantinesByRecordID.keys))
            } catch {
                logger.error("Fetching parked tagless saves failed: \(error.localizedDescription, privacy: .public)")
                break
            }

            for (recordID, quarantine) in quarantinesByRecordID {
                taglessRepairAttemptsByRecord[quarantine.recordName, default: 0] += 1
                guard let result = results[recordID] else { continue }
                do {
                    switch result {
                    case .success(let record):
                        let serverModificationDate = (try? CloudKitRecordMapper.descriptor(for: record))?.userModificationDate
                            ?? record.modificationDate
                            ?? .distantPast
                        let localRowExists = try store.hasLocalSyncRecord(
                            entity: quarantine.entity,
                            logicalKey: quarantine.logicalKey
                        )
                        if localRowExists, serverModificationDate > quarantine.localModificationDate {
                            let applied = try CloudKitRecordMapper.mergeTutorServerConflict(
                                record: record,
                                to: store,
                                preferLocalEditorial: false
                            ) ?? CloudKitRecordMapper.apply(record: record, to: store)
                            try saveMetadata(
                                for: record,
                                descriptor: CloudKitRecordDescriptor(
                                    entity: applied.entity,
                                    logicalKey: applied.logicalKey,
                                    userModificationDate: applied.userModificationDate
                                ),
                                isDeleted: false
                            )
                            try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
                            try republishMergedFieldsIfNeeded(applied)
                            affectedEntities.insert(applied.entity)
                            serverWon += 1
                        } else {
                            switch try store.adoptServerChangeTag(
                                for: quarantine,
                                systemFields: CloudKitRecordMapper.encodeSystemFields(record)
                            ) {
                            case .requeuedSave: adopted += 1
                            case .tombstoned: tombstoned += 1
                            }
                        }
                    case .failure(let error):
                        guard (error as? CKError)?.code == .unknownItem else {
                            logger.info(
                                "Could not fetch parked record \(quarantine.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                            continue
                        }
                        switch try store.releaseTaglessSaveQuarantine(for: quarantine) {
                        case .requeuedSave: released += 1
                        case .tombstoned: tombstoned += 1
                        }
                    }
                } catch {
                    logger.error(
                        "Tagless save repair failed for \(quarantine.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        let requeued = adopted + tombstoned + released
        if requeued > 0 {
            await schedulePendingChangesFromStore()
            flushAgainRequested = true
        }
        if !affectedEntities.isEmpty {
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange,
                object: nil,
                userInfo: [
                    CloudKitSyncNotificationInfo.affectedEntitiesKey: affectedEntities.map(\.rawValue),
                ]
            )
        }
        if requeued + serverWon > 0 {
            logger.notice(
                "Repaired \(requeued + serverWon) parked CloudKit save(s): \(adopted) adopted the server's change tag, \(serverWon) took the newer server copy, \(tombstoned) became deletes, \(released) were re-armed as creates"
            )
        }
    }

    private func reconcileCourseRecords() async {
        courseReconciliationNeeded = false
        do {
            // The direct read below asks the Knowledge zone. A team's course
            // lives in the team's zone (teams-design.md, decision 21), where
            // it would only ever come back unknown.
            let teamCourseIDs = try store.loadCourseTeamIDs()
            let courseNames = try store.loadCourseGroups().keys.sorted().filter { teamCourseIDs[$0] == nil }
            let eligibleNames = try courseNames.filter { courseName in
                guard try !store.hasPendingSyncChange(entity: .course, logicalKey: courseName) else {
                    return false
                }
                return try store.loadSyncMetadata(entity: .course, logicalKey: courseName)?.isDeleted != true
            }
            guard !eligibleNames.isEmpty else { return }

            let namesByRecordID = Dictionary(uniqueKeysWithValues: eligibleNames.map { courseName in
                (CloudKitRecordMapper.recordID(for: .course, logicalKey: courseName), courseName)
            })
            let results = try await database.records(for: Array(namesByRecordID.keys))
            var repairedAnyCourse = false

            for (recordID, result) in results {
                guard let courseName = namesByRecordID[recordID] else { continue }
                switch result {
                case .success(let record):
                    do {
                        let localLectures = try store.loadCourseLectures().filter {
                            $0.courseName == courseName
                        }
                        let remotePayload = try CloudKitRecordMapper.coursePayload(from: record)
                        let applied = try CloudKitRecordMapper.apply(record: record, to: store)
                        let descriptor = CloudKitRecordDescriptor(
                            entity: applied.entity,
                            logicalKey: applied.logicalKey,
                            userModificationDate: applied.userModificationDate
                        )
                        try saveMetadata(for: record, descriptor: descriptor, isDeleted: false)
                        try republishMergedFieldsIfNeeded(applied)
                        if !localLectures.isEmpty, remotePayload?.lectures.isEmpty == true {
                            // The in-flight completion race in older builds could
                            // leave CloudKit with the course's initial metadata-only
                            // snapshot while this Mac retained the completed outline.
                            // An empty inbound outline is already treated as legacy
                            // metadata by the mapper (it never clears local lectures),
                            // so publish the surviving local outline back to CloudKit.
                            try store.markRecordChanged(entity: .course, logicalKey: courseName)
                            await schedulePendingChangesFromStore()
                            scheduleFlushSoon()
                            logger.info(
                                "Queued surviving local outline for course \(courseName, privacy: .public)"
                            )
                        }
                        repairedAnyCourse = true
                    } catch {
                        // A source may still be in a later CloudKit fetch page.
                        // Leave the local metadata intact; the next sync retries
                        // this direct read after more source records arrive.
                        courseReconciliationNeeded = true
                        logger.info(
                            "Course reconciliation deferred for \(courseName, privacy: .public): \(error.localizedDescription)"
                        )
                    }
                case .failure(let error):
                    if (error as? CKError)?.code != .unknownItem {
                        logger.info(
                            "Could not reconcile course \(courseName, privacy: .public): \(error.localizedDescription)"
                        )
                    }
                }
            }

            if repairedAnyCourse {
                NotificationCenter.default.post(
                    name: .cloudKitSyncRemoteStoreDidChange,
                    object: nil,
                    userInfo: [
                        CloudKitSyncNotificationInfo.affectedEntitiesKey: [CloudKitSyncEntity.course.rawValue],
                    ]
                )
            }
        } catch {
            courseReconciliationNeeded = true
            logger.error("Failed to reconcile CloudKit course records: \(error.localizedDescription)")
        }
    }

    /// Install book covers whose bytes never reached this Mac.
    ///
    /// A Book record carries its cover as `bookCoverAsset`, but a Mac that
    /// synced the book before that asset was consumed here kept only the
    /// sender's `cover_path` — a file that exists on the other Mac and nowhere
    /// under any root this one knows. Nothing re-offers that record on its own:
    /// a finished book never changes again, so the row keeps the green
    /// placeholder forever while the cover sits in CloudKit. Reading those few
    /// records directly hands them back to the ordinary inbound path, which
    /// installs the asset and rewrites `cover_path` to the local file.
    ///
    /// Once per launch, and only for the books whose cover is missing right
    /// now, so a repaired library stops paying for this entirely. A book still
    /// coverless afterwards is one whose record genuinely has no asset yet —
    /// the sending Mac's `republishBookCoversIfNeeded` is the other half.
    private func reconcileMissingBookCovers() async {
        guard bookCoverReconciliationNeeded else { return }
        bookCoverReconciliationNeeded = false
        do {
            let coverPaths = try store.loadBooks().coverPaths
            let coverless = try store.loadAllBookNames().filter { bookID in
                if let coverPath = coverPaths[bookID],
                   StorageService.locateSourceFile(coverPath) != nil {
                    return false
                }
                // Never let a repair fetch overwrite an edit this Mac has not
                // sent yet — the same rule the course reconciliation follows.
                guard try !store.hasPendingSyncChange(entity: .book, logicalKey: bookID) else {
                    return false
                }
                return try store.loadSyncMetadata(entity: .book, logicalKey: bookID)?.isDeleted != true
            }
            guard !coverless.isEmpty else { return }

            var repairedAnyCover = false
            for batch in stride(from: 0, to: coverless.count, by: Self.bookCoverRecoveryBatchSize) {
                let names = Array(coverless[batch..<min(batch + Self.bookCoverRecoveryBatchSize, coverless.count)])
                let namesByRecordID = Dictionary(uniqueKeysWithValues: names.map { bookID in
                    (CloudKitRecordMapper.recordID(for: .book, logicalKey: bookID), bookID)
                })
                let results = try await database.records(for: Array(namesByRecordID.keys))

                for (recordID, result) in results {
                    guard let bookID = namesByRecordID[recordID] else { continue }
                    switch result {
                    case .success(let record):
                        guard record[.bookCoverAsset] as? CKAsset != nil else { continue }
                        do {
                            let applied = try CloudKitRecordMapper.apply(record: record, to: store)
                            try saveMetadata(
                                for: record,
                                descriptor: CloudKitRecordDescriptor(
                                    entity: applied.entity,
                                    logicalKey: applied.logicalKey,
                                    userModificationDate: applied.userModificationDate
                                ),
                                isDeleted: false
                            )
                            try republishMergedFieldsIfNeeded(applied)
                            repairedAnyCover = true
                        } catch {
                            logger.info(
                                "Book cover recovery skipped \(bookID, privacy: .public): \(error.localizedDescription)"
                            )
                        }
                    case .failure(let error):
                        if (error as? CKError)?.code != .unknownItem {
                            logger.info(
                                "Could not read book record \(bookID, privacy: .public): \(error.localizedDescription)"
                            )
                        }
                    }
                }
            }

            if repairedAnyCover {
                logger.info("Installed missing book covers from CloudKit")
                NotificationCenter.default.post(
                    name: .cloudKitSyncRemoteStoreDidChange,
                    object: nil,
                    userInfo: [
                        CloudKitSyncNotificationInfo.affectedEntitiesKey: [CloudKitSyncEntity.book.rawValue],
                    ]
                )
                // A recovered cover usually lands at the very path a row already
                // rendered as a placeholder, so its thumbnail cache key does not
                // change and no view would re-read it. Tell the thumbnails.
                NotificationCenter.default.post(name: .syncedArtworkDidInstall, object: nil)
            }
        } catch {
            // Re-arm: a failed read here is nearly always the network, and the
            // next fetch is the natural place to try the same small set again.
            bookCoverReconciliationNeeded = true
            logger.error("Failed to recover missing book covers: \(error.localizedDescription)")
        }
    }

    /// One recovery candidate: a source, the path its document is recorded at,
    /// and the record field that carries that document.
    private struct MissingSourceDocument {
        let sourceID: String
        let storedPath: String
        let field: String
    }

    /// Reinstall original documents whose bytes are on no disk this Mac can see.
    ///
    /// `sourcePDFAsset` carries every paper, book chapter, and course lecture's
    /// original PDF (`sourceReaderHTMLAsset` an EPUB chapter's markup), and the
    /// inbound apply path already installs it — but only
    /// when a record is *delivered*, and CKSyncEngine never redelivers a record
    /// this Mac itself last wrote. So a Mac that published a library's PDFs and
    /// then lost the local files (a retired iCloud fork, a content root that
    /// moved, a restored-from-metadata Mac) keeps the paths, keeps the extracted
    /// text, and has no way back to the documents that are sitting in its own
    /// CloudKit zone. Reading those records directly is that way back.
    ///
    /// Only the asset field is requested. The payload and the text assets are
    /// already correct locally — this repair is about bytes on disk, nothing
    /// else — and asking for the whole record would drag every source's content
    /// down again for no reason.
    ///
    /// Bounded per pass and self-rescheduling: a large library is gigabytes of
    /// PDFs, and draining it inside one flush would stall ordinary sync for as
    /// long as that takes. Each pass installs a batch, then asks for another
    /// flush, so recovery interleaves with everything else and survives a quit
    /// (the candidate set is recomputed from what is still missing).
    private func reconcileMissingSourcePDFs() async {
        guard sourcePDFReconciliationNeeded else { return }
        do {
            // EPUB chapters ride the same read: their document is the reader
            // document rather than a PDF, and without this a Mac that did not
            // import an EPUB book never had any way to its chapters.
            let recorded = try store.loadRecordedSourcePDFPaths().map {
                MissingSourceDocument(sourceID: $0.sourceID, storedPath: $0.storedPath, field: CKRecord.FieldKey.sourcePDFAsset)
            } + store.loadRecordedBookChapterDocumentPaths().map {
                MissingSourceDocument(sourceID: $0.sourceID, storedPath: $0.storedPath, field: CKRecord.FieldKey.sourceReaderHTMLAsset)
            }
            let candidates = try recorded.filter { row in
                // Read once per launch. One the server cannot supply would
                // otherwise sit at the head of every batch and starve the rest.
                guard !sourceDocumentRecoveryAttempted.contains(row.sourceID) else { return false }
                guard StorageService.locateSourceFile(row.storedPath) == nil else { return false }
                // Never let a repair read overwrite an edit this Mac has not
                // sent yet — the same rule the book-cover recovery follows.
                guard try !store.hasPendingSyncChange(entity: .source, logicalKey: row.sourceID) else {
                    return false
                }
                return try store.loadSyncMetadata(entity: .source, logicalKey: row.sourceID)?.isDeleted != true
            }
            guard !candidates.isEmpty else {
                sourcePDFReconciliationNeeded = false
                return
            }

            let batch = Array(candidates.prefix(Self.sourcePDFRecoveryBatchSize))
            let pathsByRecordID = Dictionary(batch.map { row in
                (CloudKitRecordMapper.recordID(for: .source, logicalKey: row.sourceID), row)
            }, uniquingKeysWith: { first, _ in first })
            let results = try await database.records(
                for: Array(pathsByRecordID.keys),
                desiredKeys: Array(Set(batch.map(\.field)))
            )

            var installed = 0
            for (recordID, result) in results {
                guard let row = pathsByRecordID[recordID] else { continue }
                sourceDocumentRecoveryAttempted.insert(row.sourceID)
                switch result {
                case .success(let record):
                    let path: String?
                    let digest: (String) -> String
                    if row.field == CKRecord.FieldKey.sourceReaderHTMLAsset {
                        path = CloudKitRecordMapper.installRecordedBookChapterDocument(
                            from: record,
                            storedPath: row.storedPath,
                            sourceContentRoot: nil,
                            logicalKey: row.sourceID
                        )
                        digest = CloudKitRecordMapper.recoveredReaderDocumentAssetDigest(atPath:)
                    } else {
                        path = CloudKitRecordMapper.installRecordedSourcePDFAsset(
                            from: record,
                            storedPath: row.storedPath,
                            sourceContentRoot: nil,
                            logicalKey: row.sourceID
                        )
                        digest = CloudKitRecordMapper.recoveredSourcePDFAssetDigest(atPath:)
                    }
                    guard let path else { continue }
                    // These bytes came from the server copy, so the digest they
                    // now produce is what CloudKit already holds. Recording it
                    // keeps the next unrelated save from re-uploading the whole
                    // restored library.
                    try? store.recordCommittedAssetDigest(
                        recordName: recordID.recordName,
                        field: row.field,
                        digest: digest(path)
                    )
                    installed += 1
                case .failure(let error):
                    if (error as? CKError)?.code != .unknownItem {
                        logger.info(
                            "Could not read source record \(row.sourceID, privacy: .public): \(error.localizedDescription)"
                        )
                    }
                }
            }

            if installed > 0 {
                let remaining = candidates.count - installed
                logger.info(
                    "Recovered \(installed) original document(s) from CloudKit; \(remaining) still missing"
                )
                StudioArticle.invalidateAllResolvedPathCaches()
                NotificationCenter.default.post(name: .sourceDocumentsDidInstall, object: nil)
                NotificationCenter.default.post(
                    name: .cloudKitSyncRemoteStoreDidChange,
                    object: nil,
                    userInfo: [
                        CloudKitSyncNotificationInfo.affectedEntitiesKey: [CloudKitSyncEntity.source.rawValue],
                    ]
                )
            }

            if candidates.count <= batch.count {
                // Every candidate has now been read once. Whatever is still
                // missing has no asset on the server either, and re-reading it
                // every sync would cost the same and answer the same.
                sourcePDFReconciliationNeeded = false
            } else {
                scheduleFlushSoon()
            }
        } catch {
            // Re-arm: a failed read here is nearly always the network, and the
            // next fetch is the natural place to try the same batch again.
            logger.error("Failed to recover missing source documents: \(error.localizedDescription)")
        }
    }

    private func initializeIfNeeded() async {
        guard engines.isEmpty else { return }
        for scope in [CloudKitZoneHome.Scope.privateScope, .shared] {
            do {
                let stateSerialization = try store.loadSyncEngineState(scope: scope)
                var configuration = CKSyncEngine.Configuration(
                    database: cloudDatabase(for: scope),
                    stateSerialization: stateSerialization,
                    delegate: self
                )
                // All sends are initiated by `scheduleFlushSoon`, `syncNow`, or the
                // bounded retry task below. Leaving CKSyncEngine's automatic sender
                // enabled bypasses that coordination and its exponential backoff.
                configuration.automaticallySync = CloudKitSyncSendPolicy.allowsEngineAutomaticSync
                engines[scope] = CKSyncEngine(configuration)
            } catch {
                logger.error("Failed to initialize the \(scope.rawValue, privacy: .public) CloudKit sync engine: \(error.localizedDescription)")
            }
        }
    }

    private func bootstrapIfNeeded() async {
        do {
            let enqueued = try store.enqueueMissingSyncableRecords(at: Self.bootstrapModificationDate)
            if try store.loadSyncEngineState() == nil {
                syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitRecordMapper.zoneID))])
            }
            // A team this account created lives in a zone of its own; saving
            // it again is idempotent and covers a Mac that learned of the team
            // from the local row before the zone existed here.
            for team in try store.loadTeams() where team.role == .owner {
                ensureZoneExists(for: team.home)
            }
            if enqueued > 0 {
                logger.info("Enqueued \(enqueued) existing records for CloudKit bootstrap")
            }
        } catch {
            logger.error("Failed to bootstrap CloudKit sync state: \(error.localizedDescription)")
        }
        // Independent of the reconciliation above: on a library with thousands
        // of records that step can throw and skip everything after it, which
        // silently starved this one-time nudge on its very first chance to run.
        republishBookCoversIfNeeded()
        republishPaperThumbnailsIfNeeded()
        republishMeetingIconsIfNeeded()
        republishBookChapterDocumentsIfNeeded()
        republishArchivedArticleDocumentsIfNeeded()
        republishWalkthroughPicturesIfNeeded()
        await schedulePendingChangesFromStore()
    }

    /// Books synced before covers shipped as record assets stay coverless
    /// forever on their own: a finished book's record never changes again, so
    /// it never republishes. One-time nudge per Mac — mark every book changed
    /// so the next flush re-uploads them with `bookCoverAsset` attached.
    ///
    /// Versioned key: the first shipped `makeBookCoverAsset` never resolved
    /// `cover_path`'s ForeverLM-root-relative form, so every book that "already
    /// republished" under the v1 key actually sent a nil cover. Bumping the key
    /// forces exactly the Macs that already ran v1 to redo it now that the path
    /// resolves — a genuinely new Mac only ever sees the current key and pays
    /// this once.
    ///
    /// v4 exists because v3 could not deliver: it marked every book changed but
    /// left `sync_asset_digests` asserting the server already held the cover, so
    /// `makeRecord` skipped the upload on the very Mac whose covers were the only
    /// surviving copy. A coverless Mac had already erased them server-side under
    /// v2, so the covers stayed gone. Invalidating the digest below is what makes
    /// a republish actually republish; the key bump re-runs it now that it works.
    private static let bookCoverRepublishDefaultsKey = "CloudKitSync.didRepublishBookCovers.v4"

    private func republishBookCoversIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bookCoverRepublishDefaultsKey) else { return }
        do {
            let bookNames = try store.loadAllBookNames()
            for name in bookNames {
                try store.invalidateAssetDigests(
                    recordName: CloudKitRecordMapper.recordName(for: .book, logicalKey: name),
                    fields: [CKRecord.FieldKey.bookCoverAsset]
                )
                try store.markRecordChanged(entity: .book, logicalKey: name)
            }
            UserDefaults.standard.set(true, forKey: Self.bookCoverRepublishDefaultsKey)
            if !bookNames.isEmpty {
                logger.info("Enqueued \(bookNames.count) books to republish with cover assets")
            }
        } catch {
            // Not marked done: the next launch retries the whole batch.
            logger.error("Failed to enqueue book-cover republish: \(error.localizedDescription)")
        }
    }

    /// Source records created before paper thumbnails shipped will otherwise
    /// remain unchanged forever. Requeue them once so the Mac renders and adds
    /// `paperThumbnailAsset`; future paper saves carry it normally.
    private static let paperThumbnailRepublishDefaultsKey = "CloudKitSync.didRepublishPaperThumbnails.v1"

    private func republishPaperThumbnailsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.paperThumbnailRepublishDefaultsKey) else { return }
        do {
            let sourceIDs = try store.loadAllPaperSourceIDs()
            for sourceID in sourceIDs {
                // Only the field this nudge exists to restore: clearing the whole
                // record's digests would re-upload every paper's full PDF too.
                try store.invalidateAssetDigests(
                    recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID),
                    fields: [CKRecord.FieldKey.paperThumbnailAsset]
                )
                try store.markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            UserDefaults.standard.set(true, forKey: Self.paperThumbnailRepublishDefaultsKey)
            if !sourceIDs.isEmpty {
                logger.info("Enqueued \(sourceIDs.count) papers to republish with first-page thumbnails")
            }
        } catch {
            // Not marked done: the next launch retries the whole batch.
            logger.error("Failed to enqueue paper-thumbnail republish: \(error.localizedDescription)")
        }
    }

    /// A meeting whose icon was captured or drawn before `meetingIconAsset`
    /// existed has a finished record that will never change again on its own, so
    /// the picture would stay on the one Mac that made it forever. One-time
    /// nudge per Mac: mark every meeting whose artwork is a file of ours changed,
    /// so the next flush uploads the icon.
    ///
    /// Marking alone would not have been enough — `sync_asset_digests` would
    /// still assert the server holds this field, and `makeRecord` would skip the
    /// upload on the very Mac whose icons are the only copy. That is exactly how
    /// the book-cover nudge silently did nothing three times; invalidating the
    /// field's digest is what makes a republish republish.
    private static let meetingIconRepublishDefaultsKey = "CloudKitSync.didRepublishMeetingIcons.v1"

    private func republishMeetingIconsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.meetingIconRepublishDefaultsKey) else { return }
        do {
            let sourceIDs = try store.loadAllStoredMeetingIconSourceIDs()
            for sourceID in sourceIDs {
                // Only this field. Clearing the record's digests would re-upload
                // every meeting's transcript and prepared text alongside it.
                try store.invalidateAssetDigests(
                    recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID),
                    fields: [CKRecord.FieldKey.meetingIconAsset]
                )
                try store.markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            UserDefaults.standard.set(true, forKey: Self.meetingIconRepublishDefaultsKey)
            if !sourceIDs.isEmpty {
                logger.info("Enqueued \(sourceIDs.count) meetings to republish with icon assets")
            }
        } catch {
            // Not marked done: the next launch retries the whole batch.
            logger.error("Failed to enqueue meeting-icon republish: \(error.localizedDescription)")
        }
    }

    /// Book chapters imported before chapter documents shipped carry only
    /// stripped text on the server, so every figure in an already-imported book
    /// stays invisible on the phone — and a finished book's chapters never change
    /// again on their own. One-time nudge per Mac: mark every book chapter changed
    /// so the next flush attaches its illustrated reader document (EPUB) or its
    /// chapter PDF (PDF-split books). Later chapter saves carry them normally.
    private static let bookChapterDocumentRepublishDefaultsKey =
        "CloudKitSync.didRepublishBookChapterDocuments.v1"

    private func republishBookChapterDocumentsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bookChapterDocumentRepublishDefaultsKey) else { return }
        do {
            let sourceIDs = try store.loadAllBookChapterSourceIDs()
            for sourceID in sourceIDs {
                try store.invalidateAssetDigests(
                    recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID),
                    fields: [
                        CKRecord.FieldKey.sourceReaderHTMLAsset,
                        CKRecord.FieldKey.sourcePDFAsset,
                    ]
                )
                try store.markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            UserDefaults.standard.set(true, forKey: Self.bookChapterDocumentRepublishDefaultsKey)
            if !sourceIDs.isEmpty {
                logger.info("Enqueued \(sourceIDs.count) book chapters to republish with reader documents")
            }
        } catch {
            // Not marked done: the next launch retries the whole batch.
            logger.error("Failed to enqueue book-chapter document republish: \(error.localizedDescription)")
        }
    }

    /// Archived articles created after local content replaced CloudDocs have no
    /// `sourceReaderHTMLAsset` unless their source record happens to change.
    /// Requeue that bounded cutover set once so a Mac with the canonical archive
    /// or its durable ArticleArchives cache can seed every other device.
    private static let archivedArticleDocumentRepublishDefaultsKey =
        "CloudKitSync.didRepublishArchivedArticleDocuments.v1"

    private func republishArchivedArticleDocumentsIfNeeded() {
        guard !UserDefaults.standard.bool(
            forKey: Self.archivedArticleDocumentRepublishDefaultsKey
        ) else { return }
        do {
            let sourceIDs = try store.loadLocalStorageCutoverArchivedArticleSourceIDs()
            for sourceID in sourceIDs {
                try store.invalidateAssetDigests(
                    recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID),
                    fields: [CKRecord.FieldKey.sourceReaderHTMLAsset]
                )
                try store.markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            UserDefaults.standard.set(
                true,
                forKey: Self.archivedArticleDocumentRepublishDefaultsKey
            )
            if !sourceIDs.isEmpty {
                logger.info(
                    "Enqueued \(sourceIDs.count) archived articles to republish reader documents"
                )
            }
        } catch {
            logger.error(
                "Failed to enqueue archived-article document republish: \(error.localizedDescription)"
            )
        }
    }

    /// A walk whose steps named drawn pictures before those pictures rode the
    /// Source record (`walkthroughPicturesAsset`) has a record that will not
    /// change again on its own, so its cards would stay bare on every device
    /// but the Mac that holds the pictures. One-time nudge per Mac: mark each
    /// such source changed so the next flush packs what this Mac holds. A Mac
    /// that holds none of them sends the record without the field, which
    /// leaves the server's copy alone.
    private static let walkthroughPictureRepublishDefaultsKey = "CloudKitSync.didRepublishWalkthroughPictures.v1"

    private func republishWalkthroughPicturesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.walkthroughPictureRepublishDefaultsKey) else { return }
        do {
            let sourceIDs = try store.walkthroughSourceIDsNamingDrawnPictures()
            for sourceID in sourceIDs {
                // Only this field; the record's text and PDF stay as sent.
                try store.invalidateAssetDigests(
                    recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID),
                    fields: [CKRecord.FieldKey.walkthroughPicturesAsset]
                )
                try store.markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            UserDefaults.standard.set(true, forKey: Self.walkthroughPictureRepublishDefaultsKey)
            if !sourceIDs.isEmpty {
                logger.info("Enqueued \(sourceIDs.count) walkthroughs to republish with their drawn pictures")
            }
        } catch {
            // Not marked done: the next launch retries the whole batch.
            logger.error("Failed to enqueue walkthrough-picture republish: \(error.localizedDescription)")
        }
    }

    private func startObservingLocalChanges() {
        guard observerTask == nil else { return }
        observerTask = Task {
            for await _ in NotificationCenter.default.notifications(named: .cloudKitSyncStoreDidChange) {
                self.localChangeGeneration &+= 1
                await self.schedulePendingChangesFromStore()
                self.scheduleFlushSoon(delayNanoseconds: 3_000_000_000)
            }
        }
        // A picture a walk shows changed in this Mac's store — revised,
        // redrawn, renamed or trashed — with no change to the walk itself, so
        // nothing else would re-send the Source record that carries it.
        pictureObserverTask = Task {
            for await note in NotificationCenter.default.notifications(named: .generatedImagesChanged) {
                let ids = note.userInfo?[GeneratedImageStore.changedIDsKey] as? [String] ?? []
                do {
                    let sourceIDs = try self.store.markWalkthroughSourcesChanged(namingAnyOf: ids)
                    guard !sourceIDs.isEmpty else { continue }
                    self.localChangeGeneration &+= 1
                    await self.schedulePendingChangesFromStore()
                    self.scheduleFlushSoon(delayNanoseconds: 3_000_000_000)
                } catch {
                    self.logger.error("Failed to queue the walks showing a changed picture: \(error.localizedDescription)")
                }
            }
        }
    }

    private func inspectPendingBacklogAfterFlush(
        checkpoint: CloudKitSyncBacklogCheckpoint
    ) async {
        do {
            let pending = try store.pendingSyncChanges()
            guard !pending.isEmpty else {
                retryTask?.cancel()
                retryTask = nil
                consecutiveSendFailures = 0
                consecutiveServerThrottles = 0
                requestedServerRetryAfter = nil
                // The metadata is through and the library is visible on every
                // device. Bring the held-back content across now, a bounded
                // slice at a time so this pass cannot rebuild the burst that
                // the pacing above exists to prevent.
                if let enqueued = try? store.enqueueDeferredContentRecords(
                    limit: CloudKitSyncBackfillPolicy.contentPassBatchSize
                ), enqueued > 0 {
                    logger.info("Queued \(enqueued) record(s) for their deferred CloudKit content")
                    await schedulePendingChangesFromStore()
                    scheduleFlushSoon(
                        delayNanoseconds: CloudKitSyncBackfillPolicy.batchPacingNanoseconds
                    )
                }
                return
            }

            // The backlog count says work remains; it cannot say the work is
            // making progress. A save that comes back as neither a saved record
            // nor a failed one leaves its staged digests behind and gets rebuilt
            // on the next pass forever, which reads as a healthy non-empty queue
            // no matter how long it lasts. Report the age instead of the count,
            // once per flush, so a stall has to announce itself.
            if let stalled = try? store.stalledAssetStagingSummary(
                stagedBefore: Date().addingTimeInterval(-CloudKitSyncBackfillPolicy.stalledStagingGrace),
                minimumAttempts: CloudKitSyncBackfillPolicy.stalledStagingMinimumAttempts
            ), !stalled.isEmpty {
                let sinceDescription = stalled.oldestStagedAt.map {
                    ISO8601DateFormatter().string(from: $0)
                } ?? "unknown"
                logger.warning(
                    """
                    CloudKit asset staging is not draining: \(stalled.recordCount) record(s), \
                    \(stalled.fieldCount) field(s), oldest staged \(sinceDescription), \
                    up to \(stalled.maxAttempts) attempts with no acknowledgement
                    """
                )
            }

            let current = CloudKitSyncBacklogCheckpoint(
                pendingCount: pending.count,
                successfulChangeGeneration: successfulChangeGeneration,
                localChangeGeneration: localChangeGeneration
            )
            let madeProgress = checkpoint.shouldContinueImmediately(to: current)

            // A successful partial send is progress, not a failure. The former
            // code imposed the failure backoff here, making a healthy 1,000-row
            // migration backlog advance only once per minute. Count successful
            // acknowledgements and local edits too: queue size can stay flat
            // when one record lands while another edit joins the drain.
            if madeProgress, requestedServerRetryAfter == nil {
                retryTask?.cancel()
                retryTask = nil
                consecutiveSendFailures = 0
                consecutiveServerThrottles = 0
                await schedulePendingChangesFromStore()
                if CloudKitSyncBackfillPolicy.shouldPaceNextBatch(pendingCount: pending.count) {
                    scheduleFlushSoon(
                        delayNanoseconds: CloudKitSyncBackfillPolicy.batchPacingNanoseconds
                    )
                } else {
                    flushAgainRequested = true
                }
                return
            }

            if madeProgress {
                consecutiveSendFailures = 0
            } else {
                consecutiveSendFailures += 1
            }

            // Only a send the server actually took clears the throttle count.
            if checkpoint.didDrain(to: current) {
                consecutiveServerThrottles = 0
            }

            // Age only rows that carry a real edit time. A bulk re-enqueue
            // stamps a sort key, so including it made this warning fire on
            // every flush of a healthy backfill, claiming a 25-year-old change.
            let datedChanges = pending
                .map(\.changedAt)
                .filter { !CloudKitSyncBootstrapStamp.isBootstrap($0) }
            if let oldest = datedChanges.min(), Date().timeIntervalSince(oldest) > 300 {
                let grouped = Dictionary(grouping: pending, by: \.entity).mapValues(\.count)
                let summary = grouped
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: ", ")
                logger.warning(
                    "CloudKit pending backlog remains after flush: count=\(pending.count), oldest=\(oldest, privacy: .public), \(summary, privacy: .public)"
                )
            }

            await scheduleRetry()
        } catch {
            logger.error("Failed to inspect CloudKit pending backlog: \(error.localizedDescription)")
            consecutiveSendFailures += 1
            await scheduleRetry()
        }
    }

    private func scheduleRetry() async {
        guard retryTask == nil else { return }
        // Exponential backoff starts at 60 seconds and caps at 30 minutes.
        // CloudKit's retry-after is a lower bound when the server supplies one.
        let delaySeconds = CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: consecutiveSendFailures,
            serverRetryAfter: requestedServerRetryAfter,
            consecutiveThrottles: consecutiveServerThrottles
        )
        requestedServerRetryAfter = nil
        let remaining = (try? store.pendingSyncChangeCount()) ?? 0
        let pendingItems = (try? store.pendingSyncItemSummaries()) ?? []
        if consecutiveSendFailures > 1 || consecutiveServerThrottles > 1 || delaySeconds > 60 {
            logger.notice(
                "CloudKit sync backing off; next attempt in \(Int(delaySeconds))s (failures: \(self.consecutiveSendFailures), throttles: \(self.consecutiveServerThrottles), pending: \(remaining))"
            )
        }
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            await Task { await self.clearRetryTaskAndFlush() }.value
        }
        let stalled = CloudKitSyncStallPolicy.isStalled(
            consecutiveFailures: consecutiveSendFailures,
            consecutiveThrottles: consecutiveServerThrottles
        )
        await CloudKitSyncStatusCenter.publish {
            $0.waitToRetry(remaining: remaining, items: pendingItems, stalled: stalled)
        }
    }

    private func observeServerRetryAfter(from error: Error) {
        guard let delay = CloudKitSyncRetryPolicy.serverRetryAfterSeconds(from: error) else {
            return
        }
        requestedServerRetryAfter = max(requestedServerRetryAfter ?? 0, delay)
    }

    private func clearRetryTaskAndFlush() async {
        retryTask = nil
        await flushPendingChanges(fetchAfterSend: true)
    }

    private func schedulePendingChangesFromStore() async {
        guard !engines.isEmpty else { return }
        do {
            let discarded = try store.discardPendingSavesMissingLocalRecords()
            if !discarded.isEmpty {
                for (scope, engine) in engines {
                    let discardedChanges = discarded
                        .filter { $0.home.scope == scope }
                        .map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID) }
                    if !discardedChanges.isEmpty {
                        engine.state.remove(pendingRecordZoneChanges: discardedChanges)
                    }
                }
                logger.info("Discarded \(discarded.count) pending CloudKit saves for missing local records")
            }

            let changes = try store.pendingSyncChanges()
            for (scope, engine) in engines {
                let scoped = changes.filter { $0.home.scope == scope }
                let pendingRecordNames = Set(scoped.map(\.recordName))
                let staleStateChanges = engine.state.pendingRecordZoneChanges.filter { change in
                    guard let recordName = recordName(for: change) else { return false }
                    return !pendingRecordNames.contains(recordName)
                }
                if !staleStateChanges.isEmpty {
                    engine.state.remove(pendingRecordZoneChanges: staleStateChanges)
                }
                guard !scoped.isEmpty else { continue }
                let pending = scoped.map { change -> CKSyncEngine.PendingRecordZoneChange in
                    switch change.operation {
                    case .save:
                        return .saveRecord(change.recordID)
                    case .delete:
                        return .deleteRecord(change.recordID)
                    }
                }
                engine.state.add(pendingRecordZoneChanges: pending)
            }
        } catch {
            logger.error("Failed to schedule pending CloudKit changes: \(error.localizedDescription)")
        }
    }

    private func recordName(for change: CKSyncEngine.PendingRecordZoneChange) -> String? {
        switch change {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            return recordID.recordName
        @unknown default:
            return nil
        }
    }

    private func saveMetadata(
        for record: CKRecord,
        descriptor: CloudKitRecordDescriptor,
        isDeleted: Bool,
        scope: CloudKitZoneHome.Scope = .privateScope
    ) throws {
        try store.saveSyncMetadata(
            CloudKitSyncMetadata(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey,
                recordName: record.recordID.recordName,
                systemFieldsData: isDeleted ? nil : CloudKitRecordMapper.encodeSystemFields(record),
                userModificationDate: descriptor.userModificationDate,
                isDeleted: isDeleted,
                home: CloudKitZoneHome(zoneID: record.recordID.zoneID, scope: scope)
            )
        )
        try store.clearSyncConflict(
            entity: descriptor.entity,
            logicalKey: descriptor.logicalKey
        )
    }

    /// A pre-v2 random ScheduledSource can arrive after the same portable source
    /// already owns its deterministic placement ID. In that one alias case the
    /// inbound record must become a tombstone, not live metadata pointing at the
    /// canonical local row under the wrong CloudKit record name.
    private func saveMetadata(
        for record: CKRecord,
        originalDescriptor: CloudKitRecordDescriptor,
        applied: CloudKitAppliedRecord,
        userModificationDate: Date? = nil,
        scope: CloudKitZoneHome.Scope = .privateScope
    ) throws {
        if originalDescriptor.logicalKey == applied.logicalKey {
            let descriptor = CloudKitRecordDescriptor(
                entity: applied.entity,
                logicalKey: applied.logicalKey,
                userModificationDate: userModificationDate ?? applied.userModificationDate
            )
            try saveMetadata(for: record, descriptor: descriptor, isDeleted: false, scope: scope)
        } else {
            try store.enqueueCascadingRecordDeletion(
                entity: originalDescriptor.entity,
                logicalKey: originalDescriptor.logicalKey,
                at: max(
                    Date(),
                    (userModificationDate ?? applied.userModificationDate)
                        .addingTimeInterval(0.001)
                )
            )
        }
    }

    /// If inbound conflict resolution retained a monotonic local field (currently
    /// the video watched high-water mark), publish the merged source after the
    /// server snapshot has become our sync base. This makes the merge converge
    /// for devices that did not already have the local value.
    private func republishMergedFieldsIfNeeded(
        _ applied: CloudKitAppliedRecord,
        tutorOnly: Bool = false
    ) throws {
        guard applied.requiresRepublish else { return }
        let nextModificationDate = max(
            Date(),
            applied.userModificationDate.addingTimeInterval(0.001)
        )
        if tutorOnly
            && (applied.entity == .learningGoal
                || applied.entity == .scheduledSource) {
            try store.markTutorStateChanged(
                entity: applied.entity,
                logicalKey: applied.logicalKey,
                at: nextModificationDate
            )
        } else {
            try store.markRecordChanged(
                entity: applied.entity,
                logicalKey: applied.logicalKey,
                at: nextModificationDate
            )
        }
    }

    private func quarantineImmutableConflict(
        serverRecord: CKRecord,
        descriptor: CloudKitRecordDescriptor,
        localModificationDate: Date,
        reason: String
    ) throws {
        let detectedAt = Date()
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: descriptor.entity,
            logicalKey: descriptor.logicalKey,
            recordName: serverRecord.recordID.recordName,
            reason: reason,
            localModificationDate: localModificationDate,
            serverModificationDate: descriptor.userModificationDate,
            detectedAt: detectedAt,
            serverPayload: CloudKitRecordMapper.encodedPayloadData(from: serverRecord),
            serverSystemFields: CloudKitRecordMapper.encodeSystemFields(serverRecord),
            home: conflictHome(entity: descriptor.entity, logicalKey: descriptor.logicalKey)
        ))
        Self.postSyncConflictNotification(
            entity: descriptor.entity,
            logicalKey: descriptor.logicalKey,
            reason: reason
        )
    }

    /// Re-queue a record that failed in a way normally worth retrying, unless it
    /// has now failed that way too many times in a row. Returns the quarantine
    /// reason when the record was parked instead, so the caller can report the
    /// refusal exactly as it reports a server refusal.
    ///
    /// Without the bound, `.serverRecordChanged` and `.unknownItem` re-queue at
    /// the record's *existing* modification date, so a record that keeps failing
    /// is re-sent unchanged on every pass, forever, and the backlog never reaches
    /// zero. Three ReviewSession records sat in this loop with a zero
    /// modification date and no system fields, which is what kept the sync badge
    /// showing its warning while the rest of the library was fully synced.
    private func handleRetryableSaveFailureUnlessExhausted(
        descriptor: CloudKitRecordDescriptor,
        recordName: String,
        localModificationDate: Date,
        error: CKError,
        resetServerMetadata: Bool = true
    ) throws -> String? {
        let failures = (consecutiveSaveFailuresByRecord[recordName] ?? 0) + 1
        guard failures >= Self.maxConsecutiveRecordSaveFailures else {
            consecutiveSaveFailuresByRecord[recordName] = failures
            if resetServerMetadata {
                try store.saveSyncMetadata(
                    CloudKitSyncMetadata(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey,
                        recordName: recordName,
                        systemFieldsData: nil,
                        userModificationDate: localModificationDate,
                        isDeleted: false
                    )
                )
            }
            try store.requeueSyncChange(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey,
                operation: .save,
                at: localModificationDate
            )
            return nil
        }
        consecutiveSaveFailuresByRecord.removeValue(forKey: recordName)
        logger.error(
            "CloudKit save for \(recordName, privacy: .public) failed \(failures) times in a row (code \(error.code.rawValue)); quarantining: \(error.localizedDescription)"
        )
        return try quarantineRejectedSave(
            descriptor: descriptor,
            recordName: recordName,
            localModificationDate: localModificationDate,
            error: error
        )
    }

    /// Park a save the server refused outright. Unlike a divergence conflict
    /// there is no server record to keep — the record never landed — so the
    /// envelope carries only what identifies the refusal.
    @discardableResult
    private func quarantineRejectedSave(
        descriptor: CloudKitRecordDescriptor,
        recordName: String,
        localModificationDate: Date,
        error: CKError
    ) throws -> String {
        let detectedAt = Date()
        let reason = CloudKitRejectedSaveQuarantine.encodedReason(
            errorCode: error.code.rawValue,
            message: error.localizedDescription
        )
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: descriptor.entity,
            logicalKey: descriptor.logicalKey,
            recordName: recordName,
            reason: reason,
            localModificationDate: localModificationDate,
            serverModificationDate: descriptor.userModificationDate,
            detectedAt: detectedAt,
            serverPayload: nil,
            serverSystemFields: nil,
            home: conflictHome(entity: descriptor.entity, logicalKey: descriptor.logicalKey)
        ))
        return reason
    }

    /// Park a save/delete failure that the save-only V1 envelope cannot
    /// represent. The operation is durable so Retry now never resurrects a
    /// rejected tombstone as a save.
    @discardableResult
    private func quarantineRejectedChange(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        recordName: String,
        operation: CloudKitSyncOperation,
        localModificationDate: Date,
        serverModificationDate: Date,
        errorCode: Int?,
        message: String
    ) throws -> String {
        let reason = CloudKitRejectedChangeQuarantine.encodedReason(
            operation: operation,
            errorCode: errorCode,
            message: message
        )
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: entity,
            logicalKey: logicalKey,
            recordName: recordName,
            reason: reason,
            localModificationDate: localModificationDate,
            serverModificationDate: serverModificationDate,
            detectedAt: Date(),
            serverPayload: nil,
            serverSystemFields: nil,
            home: conflictHome(entity: entity, logicalKey: logicalKey)
        ))
        return reason
    }

    /// Give every refused save one more attempt. Called where a fix outside the
    /// app plausibly landed since the refusal: engine start, and the learner
    /// explicitly asking for a sync.
    private func requeueRejectedChanges() async {
        do {
            let rearmed = try store.requeueRejectedChangeQuarantines()
            guard !rearmed.isEmpty else { return }
            let summary = rearmed
                .map { "\($0.key.rawValue)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            logger.notice("Retrying CloudKit changes iCloud previously refused (\(summary, privacy: .public))")
            await schedulePendingChangesFromStore()
        } catch {
            logger.error("Failed to re-arm refused CloudKit changes: \(error.localizedDescription)")
        }
    }

    private func applyDeletion(for metadata: CloudKitSyncMetadata, deletedAt: Date = Date()) throws {
        try Self.applyRemoteDeletion(for: metadata, deletedAt: deletedAt, store: store)
    }

    /// An old record's deletion applied to the store. The legacy catch-up applies the old world's
    /// deletions with it too (docs/cloudkit-schema-design.md §13.4 step 0, WP16a).
    static func applyRemoteDeletion(for metadata: CloudKitSyncMetadata, deletedAt: Date = Date(), store: KnowledgeStore) throws {
        try store.withoutSyncTracking {
            switch metadata.entity {
            case .source:
                try store.deleteSource(metadata.logicalKey)
            case .book:
                try store.deleteBookRecord(name: metadata.logicalKey)
            case .course:
                try store.deleteCourseGroup(name: metadata.logicalKey)
            case .videoPlaylist:
                try store.deleteVideoPlaylistGroup(id: metadata.logicalKey)
            case .meetingGroup:
                try store.deleteMeetingGroup(name: metadata.logicalKey)
            case .hiddenSource:
                try store.deleteHiddenSourceRecord(sourceID: metadata.logicalKey)
            case .hiddenPodcastShow:
                try store.deleteHiddenPodcastShowRecord(showName: metadata.logicalKey)
            case .hiddenYouTubeChannel:
                try store.deleteHiddenYouTubeChannelRecord(channelName: metadata.logicalKey)
            case .hiddenArtifact:
                try store.deleteHiddenArtifactRecord(artifactID: metadata.logicalKey)
            case .hiddenReviewSession:
                try store.deleteHiddenReviewSessionRecord(sessionID: metadata.logicalKey)
            case .dismissedSource:
                try store.deleteDismissedSource(url: metadata.logicalKey)
            case .chatContext:
                try store.deleteContextSourceIds()
            case .reviewSession:
                try store.deleteReviewSession(metadata.logicalKey)
            case .memoryItem:
                try store.deleteMemoryItemRecord(id: metadata.logicalKey)
            case .memoryAttempt:
                try store.deleteMemoryAttemptRecord(id: metadata.logicalKey)
            case .sourceHighlight:
                try store.deleteSourceHighlightRecord(id: metadata.logicalKey)
            case .learningGoal:
                // A remote deletion is authoritative: the learner already
                // confirmed it on the deleting device, nested Goals included.
                // Without the cascade a Notebook that still held Goals threw
                // here, the throw was swallowed by the deletions loop, and the
                // Notebook survived on this Mac with live metadata and no
                // tombstone — which is how a deleted Notebook came back, and
                // then republished itself to every other device.
                try store.deleteLearningGoal(metadata.logicalKey, cascadeChildGoals: true)
            case .artifact:
                try store.deleteArtifactRecord(metadata.logicalKey)
            case .artifactComment:
                try store.deleteArtifactCommentRecord(metadata.logicalKey)
            case .scheduledSource:
                try store.deleteScheduledSourceRecord(id: metadata.logicalKey)
            case .scheduledTask:
                try store.deleteScheduledTaskRecord(metadata.logicalKey)
            case .dayPlan:
                try store.deleteDayPlanRecord(metadata.logicalKey)
            case .idea:
                try store.deleteIdeaRecord(metadata.logicalKey)
            case .walkthroughProgress:
                try store.deleteWalkthroughProgressRecord(metadata.logicalKey)
            case .skill:
                try store.deleteSkillRecord(metadata.logicalKey)
            case .researchDirection:
                try store.deleteResearchDirectionRecord(metadata.logicalKey)
            case .sourceIdea:
                try store.deleteSourceIdeaRecord(metadata.logicalKey)
            case .memoryReviewActivity:
                try store.deleteMemoryReviewActivityRecord(metadata.logicalKey)
            case .videoCitedPaper:
                try store.deleteVideoCitedPaperRecord(id: metadata.logicalKey)
            case .researchCanvas:
                // Tombstoned: ResearchCanvas feature removed; nothing to delete locally.
                break
            case .aiUsageEvent:
                try store.deleteAIUsageEventRecord(metadata.logicalKey)
            case .preference:
                try store.deletePreference(key: metadata.logicalKey)
                // Also clear the local UserDefaults copy. Dropping only the SQLite
                // row would leave the cleared setting still in effect on this Mac,
                // and `hydrateFromStore` cannot infer the removal — an absent row
                // is indistinguishable from one that has not synced yet.
                PreferenceStore.applyInboundRemoval(forKey: metadata.logicalKey)
            case .team:
                // The team's record went, which only the owner can do; the zone
                // deletion that follows removes the team's content. Nothing to
                // do for the row itself here.
                break
            case .notebookTask:
                try store.deleteNotebookTaskRecord(metadata.logicalKey)
            case .shareRequest:
                try store.deleteShareRequestRecord(metadata.logicalKey)
            }
        }
        try store.saveSyncMetadata(
            CloudKitSyncMetadata(
                entity: metadata.entity,
                logicalKey: metadata.logicalKey,
                recordName: metadata.recordName,
                systemFieldsData: nil,
                userModificationDate: deletedAt,
                isDeleted: true,
                home: metadata.home
            )
        )
    }

    /// The zone a quarantined record belongs to, so the parked row can be
    /// retried against the right database. A record never seen before is the
    /// learner's own.
    private func conflictHome(entity: CloudKitSyncEntity, logicalKey: String) -> CloudKitZoneHome {
        (try? store.loadSyncMetadata(entity: entity, logicalKey: logicalKey))?.home
            ?? (try? store.resolveRecordHome(entity: entity, logicalKey: logicalKey))
            ?? .knowledge
    }

    /// The share that carries a team's roster arrived with its zone. The share
    /// is the roster's source of truth: who is in, what each may do, and the
    /// permission this account holds.
    private func applyInboundTeamShare(_ share: CKShare, home: CloudKitZoneHome) throws {
        guard let teamID = home.teamID else { return }
        let currentUser = share.currentUserParticipant
        let permission: TeamPermission
        if home.scope == .privateScope {
            permission = .readWrite
        } else {
            permission = currentUser?.permission == .readWrite ? .readWrite : .readOnly
        }
        try store.updateTeamShare(
            teamID: teamID,
            shareRecordName: share.recordID.recordName,
            shareURL: share.url?.absoluteString,
            permission: permission
        )
        let members = share.participants.map { participant in
            Self.teamMember(from: participant, teamID: teamID, isCurrentUser: participant == currentUser)
        }
        try store.replaceTeamMembers(teamID: teamID, members: members)
    }

    /// The name a roster row carries, and with it the name teammates read on
    /// every task this account stamps.
    ///
    /// CloudKit fills `nameComponents` in only for participants the server
    /// resolved from an emailed invitation, and never for the signed-in account
    /// itself: user discoverability is retired, and the owner's own participant
    /// arrives as the `__defaultOwner__` placeholder with no identity attached
    /// at all. So the account name the rest of the app greets the learner by
    /// stands in before the "You" placeholder, which is all the roster could
    /// show otherwise.
    static func memberDisplayName(
        nameComponents: PersonNameComponents?,
        email: String?,
        isCurrentUser: Bool,
        accountName: String?
    ) -> String {
        let formatter = PersonNameComponentsFormatter()
        let shared = nameComponents.map { formatter.string(from: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !shared.isEmpty { return shared }
        if isCurrentUser {
            let account = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !account.isEmpty { return account }
        }
        if let email, !email.isEmpty { return email }
        return isCurrentUser ? "You" : "Member"
    }

    static func teamMember(from participant: CKShare.Participant, teamID: String, isCurrentUser: Bool) -> TeamMemberRecord {
        let identity = participant.userIdentity
        let email = identity.lookupInfo?.emailAddress
        let displayName = memberDisplayName(
            nameComponents: identity.nameComponents,
            email: email,
            isCurrentUser: isCurrentUser,
            accountName: MacAccountUser.fullName
        )
        let role: TeamRole = participant.role == .owner ? .owner : .member
        let permission: TeamPermission = (role == .owner || participant.permission == .readWrite) ? .readWrite : .readOnly
        let acceptance: String
        switch participant.acceptanceStatus {
        case .accepted: acceptance = "accepted"
        case .pending: acceptance = "pending"
        case .removed: acceptance = "removed"
        default: acceptance = "unknown"
        }
        return TeamMemberRecord(
            userRecordName: identity.userRecordID?.recordName ?? (email ?? UUID().uuidString),
            teamID: teamID,
            displayName: displayName,
            email: email,
            role: role,
            permission: permission,
            acceptanceStatus: acceptance,
            isCurrentUser: isCurrentUser,
            updatedAt: Date()
        )
    }

    /// A team zone disappeared from the database: the owner deleted the team,
    /// or this account was removed from it. Everything the team put here goes,
    /// and the app is told to reload from scratch.
    private func removeTeamZoneLocally(home: CloudKitZoneHome) {
        guard let teamID = home.teamID else { return }
        do {
            try store.removeTeamLocally(teamID)
            logger.notice("Removed team \(teamID, privacy: .public) after its zone left the \(home.scope.rawValue, privacy: .public) database")
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange,
                object: nil,
                userInfo: [
                    CloudKitSyncNotificationInfo.requiresFullRefreshKey: true,
                    CloudKitSyncNotificationInfo.removedTeamKey: teamID,
                ]
            )
        } catch {
            logger.error("Failed to remove team \(teamID, privacy: .public) after its zone was deleted: \(error.localizedDescription)")
        }
    }

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        scope: CloudKitZoneHome.Scope = .privateScope
    ) async {
        var appliedRemoteChange = false
        var affectedEntities = Set<CloudKitSyncEntity>()
        // Docs whose body on disk changed, so an open editor can re-read at
        // once instead of waiting for the list to reload.
        var changedArtifactIDs = Set<String>()

        // A running tally is all the pull direction can honestly offer.
        let inboundCount = event.modifications.count + event.deletions.count
        await CloudKitSyncStatusCenter.publish { $0.recordReceived(inboundCount) }

        let orderedModifications = event.modifications.enumerated().sorted { lhs, rhs in
            let lhsPriority = CloudKitRecordMapper.inboundApplicationPriority(for: lhs.element.record)
            let rhsPriority = CloudKitRecordMapper.inboundApplicationPriority(for: rhs.element.record)
            if lhsPriority == rhsPriority {
                return lhs.offset < rhs.offset
            }
            return lhsPriority < rhsPriority
        }.map(\.element)

        for modification in orderedModifications {
            let inboundHome = CloudKitZoneHome(zoneID: modification.record.recordID.zoneID, scope: scope)
            // A zone-wide share travels with its zone's records. It is not a
            // ForeverLM record; it is the team's roster.
            if let share = modification.record as? CKShare {
                do {
                    try applyInboundTeamShare(share, home: inboundHome)
                    affectedEntities.insert(.team)
                    appliedRemoteChange = true
                } catch {
                    logger.error("Failed to apply a team share: \(error.localizedDescription, privacy: .public)")
                }
                continue
            }
            do {
                let descriptor = try CloudKitRecordMapper.descriptor(for: modification.record)
                if descriptor.entity == .team,
                   let payloadData = CloudKitRecordMapper.encodedPayloadData(from: modification.record),
                   let payload = try? JSONDecoder().decode(CloudKitTeamPayload.self, from: payloadData) {
                    // The team's own record names the zone. On the owner's other
                    // Macs it is how the team first appears locally.
                    try store.upsertTeamFromZone(payload, home: inboundHome, permission: nil)
                }
                let parentItemID = try CloudKitRecordMapper.memoryAttemptParentItemID(
                    from: modification.record
                )
                let parentCurriculumFingerprint: String?
                do {
                    parentCurriculumFingerprint = try CloudKitRecordMapper
                        .memoryAttemptParentCurriculumFingerprint(
                            from: modification.record
                        )
                } catch {
                    try quarantineImmutableConflict(
                        serverRecord: modification.record,
                        descriptor: descriptor,
                        localModificationDate: descriptor.userModificationDate,
                        reason: error.localizedDescription
                    )
                    logger.error(
                        "Quarantined malformed fetched MemoryAttempt \(descriptor.logicalKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                if let parentItemID,
                   let expectedFingerprint = parentCurriculumFingerprint,
                   let localFingerprint = try store.memoryItemCurriculumFingerprint(
                    id: parentItemID
                   ),
                   expectedFingerprint != localFingerprint {
                    let localMetadata = try store.loadSyncMetadata(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey
                    )
                    try quarantineImmutableConflict(
                        serverRecord: modification.record,
                        descriptor: descriptor,
                        localModificationDate: localMetadata?.userModificationDate
                            ?? descriptor.userModificationDate,
                        reason: "MemoryAttempt parent curriculum fingerprint does not match MemoryItem \(parentItemID)."
                    )
                    logger.error(
                        "Quarantined fetched MemoryAttempt \(descriptor.logicalKey, privacy: .public) because its parent curriculum fingerprint differs from MemoryItem \(parentItemID, privacy: .public)."
                    )
                    continue
                }
                if let parentItemID, try store.hasSyncConflict(
                    entity: .memoryItem,
                    logicalKey: parentItemID
                ) {
                    let localMetadata = try store.loadSyncMetadata(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey
                    )
                    try quarantineImmutableConflict(
                        serverRecord: modification.record,
                        descriptor: descriptor,
                        localModificationDate: localMetadata?.userModificationDate
                            ?? descriptor.userModificationDate,
                        reason: "Blocked by unresolved parent MemoryItem \(parentItemID) curriculum conflict."
                    )
                    logger.error(
                        "Quarantined fetched MemoryAttempt \(descriptor.logicalKey, privacy: .public) because parent MemoryItem \(parentItemID, privacy: .public) is conflicted."
                    )
                    continue
                }
                if try store.hasSyncConflict(
                    entity: descriptor.entity,
                    logicalKey: descriptor.logicalKey
                ) {
                    logger.error(
                        "Skipping fetched CloudKit record with quarantined immutable conflict: \(modification.record.recordID.recordName, privacy: .public)"
                    )
                    continue
                }
                // Don't resurrect records that were locally deleted
                let localMetadata = try store.loadSyncMetadata(
                    entity: descriptor.entity,
                    logicalKey: descriptor.logicalKey
                )
                if localMetadata?.isDeleted == true {
                    logger.info("Skipping CloudKit modification for locally-deleted \(descriptor.entity.rawValue): \(descriptor.logicalKey)")
                    continue
                }
                let hasPendingLocalChange = try store.hasPendingSyncChange(
                    entity: descriptor.entity,
                    logicalKey: descriptor.logicalKey
                )
                // CKSyncEngine can deliver the server version produced by this
                // very client after `handleSentRecordZoneChanges` has already
                // acknowledged it. Reapplying that exact etag is not a remote
                // change. Besides wasting work, normalization/monotonic merge
                // code may correctly request a one-time republish and turn the
                // acknowledgement into an endless fetch -> save echo. The
                // acknowledged system fields are an exact durable receipt, so
                // skip only when there is no newer local write waiting.
                if !hasPendingLocalChange,
                   Self.isAlreadyAppliedServerVersion(
                       modification.record,
                       metadata: localMetadata
                   ) {
                    continue
                }
                let pendingTutorOnly: Bool
                if hasPendingLocalChange {
                    pendingTutorOnly = try store.hasPendingTutorOnlySyncChange(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey
                    )
                } else {
                    pendingTutorOnly = false
                }
                let localIsNewer = hasPendingLocalChange && localMetadata.map {
                    $0.userModificationDate > descriptor.userModificationDate
                } == true
                let isImmutableMemoryEntity = descriptor.entity == .memoryItem
                    || descriptor.entity == .memoryAttempt
                let hasLocalImmutableRecord: Bool
                if isImmutableMemoryEntity {
                    hasLocalImmutableRecord = try store.hasLocalSyncRecord(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey
                    )
                } else {
                    hasLocalImmutableRecord = false
                }

                if hasLocalImmutableRecord {
                    do {
                        try CloudKitRecordMapper.validateLocalNewerImmutableConflict(
                            record: modification.record,
                            to: store
                        )
                    } catch {
                        if let applied = try CloudKitRecordMapper.adoptDivergentMemoryItemServerWinner(
                            record: modification.record,
                            to: store
                        ) {
                            try saveMetadata(
                                for: modification.record,
                                originalDescriptor: descriptor,
                                applied: applied
                            )
                            try store.clearPendingSyncChange(
                                entity: .memoryItem,
                                logicalKey: descriptor.logicalKey
                            )
                            affectedEntities.insert(.memoryItem)
                            appliedRemoteChange = true
                            logger.info(
                                "Adopted CloudKit MemoryItem winner and archived divergent local curriculum for \(descriptor.logicalKey, privacy: .public)."
                            )
                            continue
                        }
                        try quarantineImmutableConflict(
                            serverRecord: modification.record,
                            descriptor: descriptor,
                            localModificationDate: localMetadata?.userModificationDate
                                ?? descriptor.userModificationDate,
                            reason: error.localizedDescription
                        )
                        logger.error(
                            "Quarantined fetched CloudKit immutable conflict for \(modification.record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        continue
                    }
                }

                let hasLocalEditorialTutorRecord = hasPendingLocalChange
                    && !pendingTutorOnly
                    && (descriptor.entity == .learningGoal
                        || descriptor.entity == .scheduledSource)
                if localIsNewer || hasLocalEditorialTutorRecord {
                    if let applied = try CloudKitRecordMapper.mergeTutorServerConflict(
                        record: modification.record,
                        to: store,
                        preferLocalEditorial: !pendingTutorOnly
                    ) {
                        try saveMetadata(
                            for: modification.record,
                            originalDescriptor: descriptor,
                            applied: applied,
                            userModificationDate: localMetadata?.userModificationDate,
                            scope: scope
                        )
                        if descriptor.logicalKey != applied.logicalKey {
                            try store.clearPendingSyncChange(
                                entity: descriptor.entity,
                                logicalKey: descriptor.logicalKey
                            )
                        }
                        try store.requeueSyncChange(
                            entity: applied.entity,
                            logicalKey: applied.logicalKey,
                            operation: .save,
                            at: max(
                                Date(),
                                localMetadata?.userModificationDate
                                    ?? descriptor.userModificationDate
                            )
                        )
                        affectedEntities.insert(applied.entity)
                        appliedRemoteChange = true
                    } else if descriptor.entity == .source,
                              pendingTutorOnly,
                              let applied = try CloudKitRecordMapper
                                .mergeSourceProgressServerConflict(
                                    record: modification.record,
                                    to: store
                                ) {
                        // A scroll offset or a read stamp is the only thing this
                        // device has waiting, and that must not outrank an edit
                        // the learner actually made on another Mac. Adopt the
                        // server record and keep local progress instead of
                        // skipping — a skipped record never comes back.
                        try saveMetadata(
                            for: modification.record,
                            originalDescriptor: descriptor,
                            applied: applied,
                            userModificationDate: localMetadata?.userModificationDate,
                            scope: scope
                        )
                        try store.requeueSyncChange(
                            entity: applied.entity,
                            logicalKey: applied.logicalKey,
                            operation: .save,
                            at: max(
                                Date(),
                                localMetadata?.userModificationDate
                                    ?? descriptor.userModificationDate
                            )
                        )
                        affectedEntities.insert(applied.entity)
                        appliedRemoteChange = true
                    } else if descriptor.entity == .memoryItem
                                || descriptor.entity == .memoryAttempt {
                        // Exact-equal immutable identity is safe to rebase. A
                        // MemoryItem may still have a newer local mutable status
                        // or context, so preserve it and retry with the server tag.
                        try saveMetadata(
                            for: modification.record,
                            descriptor: CloudKitRecordDescriptor(
                                entity: descriptor.entity,
                                logicalKey: descriptor.logicalKey,
                                userModificationDate: localMetadata?.userModificationDate
                                    ?? descriptor.userModificationDate
                            ),
                            isDeleted: false,
                            scope: scope
                        )
                        try store.requeueSyncChange(
                            entity: descriptor.entity,
                            logicalKey: descriptor.logicalKey,
                            operation: .save,
                            at: localMetadata?.userModificationDate
                                ?? descriptor.userModificationDate
                        )
                    } else if descriptor.entity == .artifact,
                              let merge = try CloudKitRecordMapper.mergeArtifactServerConflict(
                                record: modification.record,
                                to: store
                              ) {
                        // Two writers on one Doc. The bodies are merged (or the
                        // server's held for a choice) and the local body stays
                        // queued; adopting the server change tag is what lets
                        // that upload land instead of losing the same race again.
                        let editDate = max(
                            Date(),
                            localMetadata?.userModificationDate ?? descriptor.userModificationDate
                        )
                        try saveMetadata(
                            for: modification.record,
                            originalDescriptor: descriptor,
                            applied: merge.applied,
                            userModificationDate: editDate,
                            scope: scope
                        )
                        try store.requeueSyncChange(
                            entity: .artifact,
                            logicalKey: descriptor.logicalKey,
                            operation: .save,
                            at: editDate
                        )
                        if merge.outcome != .identical {
                            changedArtifactIDs.insert(descriptor.logicalKey)
                            affectedEntities.insert(.artifact)
                            appliedRemoteChange = true
                        }
                        logger.info(
                            "Merged CloudKit Doc body over a newer local body for \(descriptor.logicalKey, privacy: .public): \(String(describing: merge.outcome), privacy: .public)"
                        )
                        continue
                    }
                    // Generic mutable records retain their existing LWW skip.
                    continue
                }

                // A team record carries the team's copy; what this member has
                // done with it stays theirs and is put back after the apply.
                let applied = try CloudKitRecordMapper.applyFetched(
                    record: modification.record,
                    descriptor: descriptor,
                    home: inboundHome,
                    to: store
                )
                try saveMetadata(
                    for: modification.record,
                    originalDescriptor: descriptor,
                    applied: applied,
                    scope: scope
                )
                if descriptor.logicalKey == applied.logicalKey {
                    try store.clearPendingSyncChange(entity: descriptor.entity, logicalKey: descriptor.logicalKey)
                } else {
                    try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
                }
                // A team copy never republishes a member's merged progress.
                if !inboundHome.isTeamZone {
                    try republishMergedFieldsIfNeeded(applied, tutorOnly: pendingTutorOnly)
                }
                if applied.entity == .artifact { changedArtifactIDs.insert(applied.logicalKey) }
                affectedEntities.insert(applied.entity)
                appliedRemoteChange = true
            } catch {
                if CloudKitSyncEntity.from(recordType: modification.record.recordType) == .course {
                    courseReconciliationNeeded = true
                }
                do {
                    if let disposition = try Self.persistInboundWebPDFFailure(
                        error,
                        record: modification.record,
                        store: store
                    ) {
                        switch disposition {
                        case .retryScheduled(let retry):
                            logger.info(
                                "Durably queued CloudKit web PDF \(retry.recordName, privacy: .public) after transient apply failure"
                            )
                            scheduleInboundWebPDFRetry()
                        case .quarantined:
                            if let descriptor = try? CloudKitRecordMapper.descriptor(
                                for: modification.record
                            ) {
                                Self.postSyncConflictNotification(
                                    entity: descriptor.entity,
                                    logicalKey: descriptor.logicalKey,
                                    reason: error.localizedDescription
                                )
                            }
                            logger.error(
                                "Quarantined malformed CloudKit web PDF \(modification.record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                } catch {
                    logger.error(
                        "Failed to persist inbound CloudKit web PDF failure for \(modification.record.recordID.recordName, privacy: .public): \(error.localizedDescription)"
                    )
                }
                logger.error("Failed to apply fetched CloudKit record \(modification.record.recordID.recordName, privacy: .public): \(error.localizedDescription)")
            }
        }

        for deletion in event.deletions {
            do {
                let recordName = deletion.recordID.recordName
                let deletedAt = Date()
                if try store.resolveQuarantinedMemoryAttemptServerDeletion(
                    recordName: recordName,
                    deletedAt: deletedAt
                ) {
                    affectedEntities.insert(.memoryAttempt)
                    appliedRemoteChange = true
                    continue
                }
                let storedMetadata = try store.loadSyncMetadata(recordName: recordName)
                let quarantinedConflict: CloudKitSyncConflict?
                if storedMetadata == nil {
                    quarantinedConflict = try store.loadSyncConflict(recordName: recordName)
                } else {
                    quarantinedConflict = nil
                }
                guard let metadata = storedMetadata ?? quarantinedConflict.map({ conflict in
                    CloudKitSyncMetadata(
                        entity: conflict.entity,
                        logicalKey: conflict.logicalKey,
                        recordName: conflict.recordName,
                        systemFieldsData: nil,
                        userModificationDate: conflict.serverModificationDate,
                        isDeleted: false
                    )
                }) else { continue }

                let dependentAttemptIDs = metadata.entity == .memoryItem
                    ? try dependentQuarantinedAttemptIDs(memoryItemID: metadata.logicalKey)
                    : []
                let dependentHighlightIDs = metadata.entity == .source
                    ? try store.sourceHighlightIDs(sourceID: metadata.logicalKey)
                    : []
                try applyDeletion(for: metadata, deletedAt: deletedAt)
                try store.clearPendingSyncChange(
                    entity: metadata.entity,
                    logicalKey: metadata.logicalKey
                )
                try store.clearSyncConflict(
                    entity: metadata.entity,
                    logicalKey: metadata.logicalKey
                )

                // A server-deleted canonical curriculum cannot retain orphaned
                // immutable attempts. Clear their quarantines before enqueuing
                // explicit child tombstones; otherwise the fail-closed conflict
                // filter would suppress those deletes forever.
                for attemptID in dependentAttemptIDs {
                    try store.clearSyncConflict(
                        entity: .memoryAttempt,
                        logicalKey: attemptID
                    )
                    try store.enqueueCascadingRecordDeletion(
                        entity: .memoryAttempt,
                        logicalKey: attemptID,
                        at: deletedAt
                    )
                    affectedEntities.insert(.memoryAttempt)
                }
                for highlightID in dependentHighlightIDs {
                    try store.enqueueCascadingRecordDeletion(
                        entity: .sourceHighlight,
                        logicalKey: highlightID,
                        at: deletedAt
                    )
                    affectedEntities.insert(.sourceHighlight)
                }

                affectedEntities.insert(metadata.entity)
                appliedRemoteChange = true
            } catch {
                logger.error("Failed to apply fetched CloudKit deletion \(deletion.recordID.recordName, privacy: .public): \(error.localizedDescription)")
            }
        }

        if appliedRemoteChange {
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange,
                object: nil,
                userInfo: [
                    CloudKitSyncNotificationInfo.affectedEntitiesKey: affectedEntities.map(\.rawValue),
                    CloudKitSyncNotificationInfo.changedArtifactIDsKey: Array(changedArtifactIDs),
                ]
            )
        }
    }

    static func isAlreadyAppliedServerVersion(
        _ record: CKRecord,
        metadata: CloudKitSyncMetadata?
    ) -> Bool {
        guard let incomingChangeTag = record.recordChangeTag,
              let systemFields = metadata?.systemFieldsData,
              let acknowledgedRecord = CloudKitRecordMapper.decodeSystemFields(systemFields),
              let acknowledgedChangeTag = acknowledgedRecord.recordChangeTag else {
            return false
        }
        return serverVersionsMatch(
            incomingRecordID: record.recordID,
            incomingChangeTag: incomingChangeTag,
            acknowledgedRecordID: acknowledgedRecord.recordID,
            acknowledgedChangeTag: acknowledgedChangeTag
        )
    }

    static func serverVersionsMatch(
        incomingRecordID: CKRecord.ID,
        incomingChangeTag: String,
        acknowledgedRecordID: CKRecord.ID,
        acknowledgedChangeTag: String
    ) -> Bool {
        incomingRecordID == acknowledgedRecordID
            && incomingChangeTag == acknowledgedChangeTag
    }

    /// Resolve both locally-present and server-only child quarantines before an
    /// authoritative parent deletion removes the local rows that identify their
    /// relationship.
    private func dependentQuarantinedAttemptIDs(memoryItemID: String) throws -> [String] {
        var result: [String] = []
        for conflict in try store.loadSyncConflicts() where conflict.entity == .memoryAttempt {
            if try store.loadMemoryAttempt(conflict.logicalKey)?.memoryItemID == memoryItemID {
                result.append(conflict.logicalKey)
                continue
            }
            guard let payloadData = conflict.serverPayload,
                  let payload = try? JSONDecoder().decode(
                    CloudKitMemoryAttemptPayload.self,
                    from: payloadData
                  ),
                  payload.attempt.memoryItemID == memoryItemID else {
                continue
            }
            result.append(conflict.logicalKey)
        }
        return Array(Set(result)).sorted()
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        scope: CloudKitZoneHome.Scope = .privateScope
    ) async {
        // A team zone that left either database takes its team with it: the
        // owner deleted the team, or removed this account from it.
        for deletion in event.deletions where TeamRecord.teamID(fromZoneName: deletion.zoneID.zoneName) != nil {
            removeTeamZoneLocally(home: CloudKitZoneHome(zoneID: deletion.zoneID, scope: scope))
        }
        guard scope == .privateScope else { return }
        do {
            let zoneDeleted = event.deletions.contains { $0.zoneID == CloudKitRecordMapper.zoneID }
            guard zoneDeleted else { return }
            try store.clearAllSyncMetadata()
            try store.clearAllPendingSyncChanges()
            try store.enqueueAllSyncableRecords()
            syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitRecordMapper.zoneID))])
            await schedulePendingChangesFromStore()
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange,
                object: nil,
                userInfo: [CloudKitSyncNotificationInfo.requiresFullRefreshKey: true]
            )
        } catch {
            logger.error("Failed to handle database-level CloudKit changes: \(error.localizedDescription)")
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        scope: CloudKitZoneHome.Scope = .privateScope
    ) async {
        do {
            var appliedServerChange = false
            var affectedEntities = Set<CloudKitSyncEntity>()
            var changedArtifactIDs = Set<String>()
            let failedChangeCount = event.failedRecordSaves.count + event.failedRecordDeletes.count
            let sawBatchRequestFailure = event.failedRecordSaves.contains {
                $0.error.code == .batchRequestFailed
            } || event.failedRecordDeletes.contains {
                $0.value.code == .batchRequestFailed
            }
            isIsolatingFailedBatch = sawBatchRequestFailure
            // This is a different request shape, not a blind retry of the
            // failed batch. Run it immediately so the actual culprit is
            // identified before the ordinary no-progress backoff begins.
            if sawBatchRequestFailure,
               CloudKitSyncBatchIsolationPolicy.requiresImmediateIsolationPass(
                failedChangeCount: failedChangeCount
               ) {
                flushAgainRequested = true
            }

            for record in event.savedRecords {
                do {
                    let descriptor = try CloudKitRecordMapper.descriptorForSentRecord(record, store: store)
                    let sentAt = inFlightSaveModificationDates.removeValue(
                        forKey: record.recordID.recordName
                    ) ?? descriptor.userModificationDate
                    consecutiveSaveFailuresByRecord.removeValue(forKey: record.recordID.recordName)
                    let currentMetadata = try store.loadSyncMetadata(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey
                    )
                    let metadataDate = max(
                        sentAt,
                        currentMetadata?.userModificationDate ?? sentAt
                    )
                    try saveMetadata(
                        for: record,
                        descriptor: CloudKitRecordDescriptor(
                            entity: descriptor.entity,
                            logicalKey: descriptor.logicalKey,
                            userModificationDate: metadataDate
                        ),
                        isDeleted: false,
                        scope: scope
                    )
                    // CloudKit now holds the assets this save carried, so the
                    // digests staged while building the record become the baseline
                    // that later saves compare against.
                    try store.commitStagedAssetDigests(recordName: record.recordID.recordName)
                    // The server now holds this Doc body; it is the base the next
                    // merge with another writer's edit compares against.
                    if descriptor.entity == .artifact {
                        try store.adoptArtifactBaseIfCurrent(descriptor.logicalKey)
                    }
                    // The record was snapshotted before the network request. A newer
                    // local edit may have replaced the same sync_changes row while
                    // this upload was in flight; only acknowledge work at or before
                    // the modification date actually carried by the sent record.
                    try store.clearPendingSyncChange(
                        entity: descriptor.entity,
                        logicalKey: descriptor.logicalKey,
                        changedAt: sentAt
                    )
                } catch {
                    // One record's bookkeeping must not abandon the batch's.
                    // This handler used to be a single do/catch, so a throw here
                    // skipped every remaining record: their staged digests were
                    // never committed or cleared and their queue rows never
                    // dequeued, which is how 63 records retried forever while the
                    // asset cache regrew on every pass. Losing one record's
                    // bookkeeping costs a retry; losing the batch's costs a stall.
                    logger.error("Failed to record a CloudKit acknowledged save for \(record.recordID.recordName, privacy: .public); continuing with the rest of the batch: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            for recordID in event.deletedRecordIDs {
                do {
                    consecutiveSaveFailuresByRecord.removeValue(forKey: recordID.recordName)
                    // The server took the delete, so the queue row must go whether or
                    // not local metadata is still around to name it. It often is not:
                    // deleting the row drops its `sync_metadata` while deliberately
                    // leaving the `sync_changes` row so the delete still gets sent.
                    // Skipping the dequeue here left those deletes queued forever and
                    // stalled every save behind them — 7,929 records, zero drained.
                    guard let metadata = try store.loadSyncMetadata(recordName: recordID.recordName) else {
                        try store.clearPendingSyncChange(recordName: recordID.recordName)
                        continue
                    }
                    try store.saveSyncMetadata(
                        CloudKitSyncMetadata(
                            entity: metadata.entity,
                            logicalKey: metadata.logicalKey,
                            recordName: metadata.recordName,
                            systemFieldsData: nil,
                            userModificationDate: Date(),
                            isDeleted: true,
                            home: metadata.home
                        )
                    )
                    try store.clearSyncConflict(
                        entity: metadata.entity,
                        logicalKey: metadata.logicalKey
                    )
                    try store.clearPendingSyncChange(entity: metadata.entity, logicalKey: metadata.logicalKey)
                } catch {
                    // One record's bookkeeping must not abandon the batch's.
                    // This handler used to be a single do/catch, so a throw here
                    // skipped every remaining record: their staged digests were
                    // never committed or cleared and their queue rows never
                    // dequeued, which is how 63 records retried forever while the
                    // asset cache regrew on every pass. Losing one record's
                    // bookkeeping costs a retry; losing the batch's costs a stall.
                    logger.error("Failed to record a CloudKit acknowledged delete for \(recordID.recordName, privacy: .public); continuing with the rest of the batch: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            // One send window covers many bounded batches, so a large backlog
            // would otherwise sit at its opening fraction until the whole window
            // closed. Count successful saves and deletes after both have cleared
            // their durable queue rows, then report the one coherent remainder.
            let sent = event.savedRecords.count + event.deletedRecordIDs.count
            if sent > 0 {
                successfulChangeGeneration &+= UInt64(sent)
                let remaining = (try? store.pendingSyncChangeCount()) ?? 0
                let pendingItems = (try? store.pendingSyncItemSummaries()) ?? []
                await CloudKitSyncStatusCenter.publish {
                    $0.advanceSending(remaining: remaining, sentInBatch: sent, items: pendingItems)
                }
            }

            // One refusal is usually many: a record type the deployed schema
            // lacks fails for every record of that type in the same batch. Tell
            // the learner once, not once per record.
            var firstRejectedChange: (entity: CloudKitSyncEntity, logicalKey: String, reason: String)?
            // A full iCloud is retried like any transient refusal, but the
            // learner has to hear about it: it never clears on its own.
            var sawQuotaExceeded = false
            for failed in event.failedRecordSaves {
                // Known once the record has been read, so a failure further down
                // can still park the change it belongs to.
                var parkableDescriptor: CloudKitRecordDescriptor?
                do {
                    inFlightSaveModificationDates.removeValue(forKey: failed.record.recordID.recordName)
                    // Nothing landed on the server, so keep the previous baseline
                    // and let the retry re-send whatever it needs to.
                    try store.clearStagedAssetDigests(recordName: failed.record.recordID.recordName)
                    let descriptor = try CloudKitRecordMapper.descriptor(for: failed.record)
                    parkableDescriptor = descriptor
                    let localMetadata = try store.loadSyncMetadata(entity: descriptor.entity, logicalKey: descriptor.logicalKey)

                    switch failed.error.code {
                    case .serverRecordChanged:
                        // An oplock miss normally arrives with the server's copy,
                        // and every resolution below needs it. Without one there
                        // is nothing to merge, adopt or compare against, and
                        // `continue` left the record queued with no conflict row
                        // — invisible, and retried on every flush forever.
                        //
                        // That is not hypothetical: it is what the 63 records
                        // stranded by the container rebase were doing. The rebase
                        // clears `system_fields` wholesale, so each of those saves
                        // goes up with no change tag as an unconditional create.
                        // It anticipated the recordName the server does not hold,
                        // which answers `.unknownItem` and settles as done; it did
                        // not anticipate the one the server does hold, where an
                        // unconditional create against an existing record is
                        // exactly an optimistic-lock miss reported without a
                        // server record. Park it so it is visible and bounded.
                        // Re-acquiring a change tag by fetching the record is the
                        // repair, and it belongs somewhere it can be tested
                        // against a parked, enumerable cohort rather than here.
                        // The metadata's date is not always the row's. A wholesale
                        // re-enqueue stamps the sort key that reads as 2001, and the
                        // container rebase left this Mac's rows carrying it; taken as
                        // the local edit time it made every one of them older than
                        // any server copy, so the server won each oplock miss even
                        // where the local edit was the newer one. The record just
                        // sent carries the row's own date, so take the later of the
                        // two, and carry it into the metadata the parked conflict and the requeue below
                        // rather than writing the sort key back as a timestamp.
                        let localEditDate = max(
                            localMetadata?.userModificationDate ?? .distantPast,
                            descriptor.userModificationDate
                        )
                        guard let serverRecord = failed.error.serverRecord else {
                            logger.error(
                                "CloudKit reported a changed server record without sending it for \(failed.record.recordID.recordName, privacy: .public); quarantining: \(failed.error.localizedDescription)"
                            )
                            let reason = try quarantineRejectedSave(
                                descriptor: descriptor,
                                recordName: failed.record.recordID.recordName,
                                localModificationDate: localEditDate,
                                error: failed.error
                            )
                            if firstRejectedChange == nil {
                                firstRejectedChange = (descriptor.entity, descriptor.logicalKey, reason)
                            }
                            continue
                        }
                        let serverDescriptor = try CloudKitRecordMapper.descriptor(for: serverRecord)
                        let localIsNewer = localMetadata != nil
                            && localEditDate > serverDescriptor.userModificationDate
                        let pendingTutorOnly = try store.hasPendingTutorOnlySyncChange(
                            entity: descriptor.entity,
                            logicalKey: descriptor.logicalKey
                        )

                        // A deterministic MemoryItem conflict adopts the server
                        // winner and archives the divergent local curriculum and
                        // evidence. A wholly immutable MemoryAttempt divergence has
                        // no safe field merge and remains durably quarantined.
                        if descriptor.entity == .memoryItem || descriptor.entity == .memoryAttempt {
                            do {
                                try CloudKitRecordMapper.validateLocalNewerImmutableConflict(
                                    record: serverRecord,
                                    to: store
                                )
                            } catch {
                                if let applied = try CloudKitRecordMapper.adoptDivergentMemoryItemServerWinner(
                                    record: serverRecord,
                                    to: store
                                ) {
                                    try saveMetadata(
                                        for: serverRecord,
                                        originalDescriptor: serverDescriptor,
                                        applied: applied,
                                        scope: scope
                                    )
                                    try store.clearPendingSyncChange(
                                        entity: .memoryItem,
                                        logicalKey: descriptor.logicalKey
                                    )
                                    affectedEntities.insert(.memoryItem)
                                    appliedServerChange = true
                                    logger.info(
                                        "Adopted CloudKit MemoryItem winner and archived divergent local curriculum for \(descriptor.logicalKey, privacy: .public)."
                                    )
                                    continue
                                }
                                logger.error(
                                    "Durable CloudKit immutable conflict for \(failed.record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                                )
                                try quarantineImmutableConflict(
                                    serverRecord: serverRecord,
                                    descriptor: serverDescriptor,
                                    localModificationDate: localEditDate,
                                    reason: error.localizedDescription
                                )
                                continue
                            }
                        }

                        let hasLocalEditorialTutorRecord = !pendingTutorOnly
                            && (descriptor.entity == .learningGoal
                                || descriptor.entity == .scheduledSource)
                        if (localIsNewer || hasLocalEditorialTutorRecord), let localMetadata {
                            if let applied = try CloudKitRecordMapper.mergeTutorServerConflict(
                                record: serverRecord,
                                to: store,
                                preferLocalEditorial: !pendingTutorOnly
                            ) {
                                try saveMetadata(
                                    for: serverRecord,
                                    originalDescriptor: serverDescriptor,
                                    applied: applied,
                                    userModificationDate: localEditDate,
                                    scope: scope
                                )
                                if descriptor.logicalKey != applied.logicalKey {
                                    try store.clearPendingSyncChange(
                                        entity: descriptor.entity,
                                        logicalKey: descriptor.logicalKey
                                    )
                                }
                                try store.requeueSyncChange(
                                    entity: applied.entity,
                                    logicalKey: applied.logicalKey,
                                    operation: .save,
                                    at: max(Date(), localEditDate)
                                )
                                affectedEntities.insert(applied.entity)
                                appliedServerChange = true
                            } else if descriptor.entity == .artifact,
                                      let merge = try CloudKitRecordMapper.mergeArtifactServerConflict(
                                        record: serverRecord,
                                        to: store
                                      ) {
                                // The server body this save lost to is merged into
                                // (or held beside) the local one; the requeued save
                                // then carries the result under the server's tag.
                                let editDate = max(Date(), localEditDate)
                                try saveMetadata(
                                    for: serverRecord,
                                    originalDescriptor: serverDescriptor,
                                    applied: merge.applied,
                                    userModificationDate: editDate,
                                    scope: scope
                                )
                                try store.requeueSyncChange(
                                    entity: .artifact,
                                    logicalKey: descriptor.logicalKey,
                                    operation: .save,
                                    at: editDate
                                )
                                if merge.outcome != .identical {
                                    changedArtifactIDs.insert(descriptor.logicalKey)
                                    affectedEntities.insert(.artifact)
                                    appliedServerChange = true
                                }
                            } else {
                                // Adopting the server's change tag is real progress —
                                // the next send is no longer the same stale request —
                                // so keep it whether or not this record is exhausted.
                                try store.saveSyncMetadata(
                                    CloudKitSyncMetadata(
                                        entity: descriptor.entity,
                                        logicalKey: descriptor.logicalKey,
                                        recordName: failed.record.recordID.recordName,
                                        systemFieldsData: CloudKitRecordMapper.encodeSystemFields(serverRecord),
                                        userModificationDate: localEditDate,
                                        isDeleted: false,
                                        home: CloudKitZoneHome(zoneID: failed.record.recordID.zoneID, scope: scope)
                                    )
                                )
                                let recordName = failed.record.recordID.recordName
                                let failures = (consecutiveSaveFailuresByRecord[recordName] ?? 0) + 1
                                if failures < Self.maxConsecutiveRecordSaveFailures {
                                    consecutiveSaveFailuresByRecord[recordName] = failures
                                    try store.requeueSyncChange(
                                        entity: descriptor.entity,
                                        logicalKey: descriptor.logicalKey,
                                        operation: .save,
                                        at: localEditDate
                                    )
                                } else {
                                    // A local record that loses this merge every pass
                                    // never converges on its own, and re-queueing it
                                    // unchanged is what keeps the backlog off zero.
                                    consecutiveSaveFailuresByRecord.removeValue(forKey: recordName)
                                    logger.error(
                                        "CloudKit save for \(recordName, privacy: .public) lost to the server record \(failures) times in a row; quarantining"
                                    )
                                    let reason = try quarantineRejectedSave(
                                        descriptor: descriptor,
                                        recordName: recordName,
                                        localModificationDate: localEditDate,
                                        error: failed.error
                                    )
                                    if firstRejectedChange == nil {
                                        firstRejectedChange = (descriptor.entity, descriptor.logicalKey, reason)
                                    }
                                }
                            }
                        } else {
                            // The server's copy wins exactly as a fetched one
                            // does: a team record is stamped with its team and
                            // this member's own progress is put back after it.
                            let applied = try CloudKitRecordMapper.applyFetched(
                                record: serverRecord,
                                descriptor: serverDescriptor,
                                home: CloudKitZoneHome(zoneID: serverRecord.recordID.zoneID, scope: scope),
                                to: store
                            )
                            try saveMetadata(
                                for: serverRecord,
                                originalDescriptor: serverDescriptor,
                                applied: applied,
                                scope: scope
                            )
                            if descriptor.logicalKey == applied.logicalKey {
                                try store.clearPendingSyncChange(entity: descriptor.entity, logicalKey: descriptor.logicalKey)
                            } else {
                                try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
                            }
                            // Unlike a fetch, a lost send may still hold what
                            // the server lacks (a retained file path or paper
                            // ingestion); a team record goes out stripped of
                            // member progress, so republishing it is safe.
                            try republishMergedFieldsIfNeeded(applied, tutorOnly: pendingTutorOnly)
                            if applied.entity == .artifact { changedArtifactIDs.insert(applied.logicalKey) }
                            affectedEntities.insert(applied.entity)
                            appliedServerChange = true
                        }
                    case .zoneNotFound:
                        let home = CloudKitZoneHome(zoneID: failed.record.recordID.zoneID, scope: scope)
                        ensureZoneExists(for: home)
                        try store.saveSyncMetadata(
                            CloudKitSyncMetadata(
                                entity: descriptor.entity,
                                logicalKey: descriptor.logicalKey,
                                recordName: failed.record.recordID.recordName,
                                systemFieldsData: nil,
                                userModificationDate: localMetadata?.userModificationDate ?? descriptor.userModificationDate,
                                isDeleted: false,
                                home: home
                            )
                        )
                        try store.requeueSyncChange(
                            entity: descriptor.entity,
                            logicalKey: descriptor.logicalKey,
                            operation: .save,
                            at: localMetadata?.userModificationDate ?? descriptor.userModificationDate
                        )
                    case .unknownItem:
                        if let reason = try handleRetryableSaveFailureUnlessExhausted(
                            descriptor: descriptor,
                            recordName: failed.record.recordID.recordName,
                            localModificationDate: localMetadata?.userModificationDate
                                ?? descriptor.userModificationDate,
                            error: failed.error
                        ), firstRejectedChange == nil {
                            firstRejectedChange = (descriptor.entity, descriptor.logicalKey, reason)
                        }
                    case .assetFileModified:
                        // The temp file backing a CKAsset changed while CloudKit was
                        // registering it. The sync_changes row is still pending; the next
                        // flush rebuilds the record with a fresh asset file and retries.
                        // This should be self-healing because asset paths are unique,
                        // but a filesystem/provider fault can repeat forever. Bound it
                        // like the other unchanged-record retries without discarding the
                        // valid server change tag.
                        logger.info("CloudKit asset changed during upload for \(failed.record.recordID.recordName, privacy: .public); will rebuild and retry")
                        if let reason = try handleRetryableSaveFailureUnlessExhausted(
                            descriptor: descriptor,
                            recordName: failed.record.recordID.recordName,
                            localModificationDate: localMetadata?.userModificationDate
                                ?? descriptor.userModificationDate,
                            error: failed.error,
                            resetServerMetadata: false
                        ), firstRejectedChange == nil {
                            firstRejectedChange = (descriptor.entity, descriptor.logicalKey, reason)
                        }
                    case .batchRequestFailed:
                        // In a multi-record request this is only a companion failure;
                        // leave it untouched and isolate the following send. If an
                        // already-isolated singleton still gets the same error, the
                        // error belongs to this change and must not remain unbounded.
                        guard CloudKitSyncBatchIsolationPolicy.isSingletonFailure(
                            failedChangeCount: failedChangeCount
                        ) else { continue }
                        if let reason = try handleRetryableSaveFailureUnlessExhausted(
                            descriptor: descriptor,
                            recordName: failed.record.recordID.recordName,
                            localModificationDate: localMetadata?.userModificationDate
                                ?? descriptor.userModificationDate,
                            error: failed.error,
                            resetServerMetadata: false
                        ), firstRejectedChange == nil {
                            firstRejectedChange = (descriptor.entity, descriptor.logicalKey, reason)
                        }
                    case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy, .notAuthenticated, .operationCancelled,
                         .requestRateLimited, .serverResponseLost, .quotaExceeded:
                        if failed.error.code == .quotaExceeded { sawQuotaExceeded = true }
                        observeServerRetryAfter(from: failed.error)
                        continue
                    default:
                        // Everything left is a refusal retrying cannot clear: a
                        // record type missing from the deployed schema, a rejected
                        // request, a failed server-side validation. Leaving it
                        // pending is what turned two undeployed Artifact records
                        // into a permanent warning badge and an endless retry
                        // loop that also skipped the fetch paired with each send.
                        // Park it instead — the local row keeps its content, and
                        // engine start and "Retry now" re-arm it so an environmental
                        // fix takes effect without database surgery.
                        logger.error("CloudKit refused save (code \(failed.error.code.rawValue)) for \(failed.record.recordID.recordName, privacy: .public); quarantining: \(failed.error.localizedDescription)")
                        let reason = try quarantineRejectedSave(
                            descriptor: descriptor,
                            recordName: failed.record.recordID.recordName,
                            localModificationDate: localMetadata?.userModificationDate
                                ?? descriptor.userModificationDate,
                            error: failed.error
                        )
                        if firstRejectedChange == nil {
                            firstRejectedChange = (descriptor.entity, descriptor.logicalKey, reason)
                        }
                    }
                } catch {
                    // One record's bookkeeping must not abandon the batch's.
                    // This handler used to be a single do/catch, so a throw here
                    // skipped every remaining record: their staged digests were
                    // never committed or cleared and their queue rows never
                    // dequeued, which is how 63 records retried forever while the
                    // asset cache regrew on every pass. Losing one record's
                    // bookkeeping costs a retry; losing the batch's costs a stall.
                    //
                    // But a retry only helps when the next pass can go differently.
                    // A failure the store reports as bad data is the same on every
                    // pass, and on 2026-09-01 three of them — a narration record
                    // without its asset, a placement whose source is gone, a
                    // duplicate activity-day id — held 49 changes in the queue and
                    // drove the whole engine into a 30-minute back-off. Park those
                    // at once, and park anything else after the same number of
                    // passes a refused save gets, so the record becomes a visible,
                    // bounded conflict that "Retry now" can re-arm.
                    let recordName = failed.record.recordID.recordName
                    let failures = (consecutiveSaveFailuresByRecord[recordName] ?? 0) + 1
                    let deterministic = (error as? KnowledgeStoreError).map { storeError -> Bool in
                        if case .invalidData = storeError { return true }
                        return false
                    } ?? false
                    if let parkableDescriptor,
                       deterministic || failures >= Self.maxConsecutiveRecordSaveFailures {
                        consecutiveSaveFailuresByRecord.removeValue(forKey: recordName)
                        do {
                            let reason = try quarantineRejectedSave(
                                descriptor: parkableDescriptor,
                                recordName: recordName,
                                localModificationDate: parkableDescriptor.userModificationDate,
                                error: failed.error
                            )
                            if firstRejectedChange == nil {
                                firstRejectedChange = (parkableDescriptor.entity, parkableDescriptor.logicalKey, reason)
                            }
                            logger.error("Parked the CloudKit refused save for \(recordName, privacy: .public) after its bookkeeping failed \(failures) time(s): \(error.localizedDescription, privacy: .public)")
                        } catch {
                            logger.error("Failed to park the CloudKit refused save for \(recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                        continue
                    }
                    consecutiveSaveFailuresByRecord[recordName] = failures
                    logger.error("Failed to record a CloudKit refused save for \(recordName, privacy: .public); continuing with the rest of the batch: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            for failed in event.failedRecordDeletes {
                do {
                    let recordID = failed.key
                    let error = failed.value
                    guard let metadata = try store.loadSyncMetadata(recordName: recordID.recordName) else { continue }
                    switch error.code {
                    case .unknownItem:
                        try store.clearPendingSyncChange(entity: metadata.entity, logicalKey: metadata.logicalKey)
                        try store.saveSyncMetadata(
                            CloudKitSyncMetadata(
                                entity: metadata.entity,
                                logicalKey: metadata.logicalKey,
                                recordName: metadata.recordName,
                                systemFieldsData: nil,
                                userModificationDate: metadata.userModificationDate,
                                isDeleted: true,
                                home: metadata.home
                            )
                        )
                    case .zoneNotFound:
                        ensureZoneExists(for: metadata.home)
                        try store.requeueSyncChange(
                            entity: metadata.entity,
                            logicalKey: metadata.logicalKey,
                            operation: .delete,
                            at: metadata.userModificationDate
                        )
                    case .batchRequestFailed:
                        guard CloudKitSyncBatchIsolationPolicy.isSingletonFailure(
                            failedChangeCount: failedChangeCount
                        ) else { continue }
                        let failures = (consecutiveSaveFailuresByRecord[recordID.recordName] ?? 0) + 1
                        if failures < Self.maxConsecutiveRecordSaveFailures {
                            consecutiveSaveFailuresByRecord[recordID.recordName] = failures
                            try store.requeueSyncChange(
                                entity: metadata.entity,
                                logicalKey: metadata.logicalKey,
                                operation: .delete,
                                at: metadata.userModificationDate
                            )
                        } else {
                            consecutiveSaveFailuresByRecord.removeValue(forKey: recordID.recordName)
                            let reason = try quarantineRejectedChange(
                                entity: metadata.entity,
                                logicalKey: metadata.logicalKey,
                                recordName: recordID.recordName,
                                operation: .delete,
                                localModificationDate: metadata.userModificationDate,
                                serverModificationDate: metadata.userModificationDate,
                                errorCode: error.code.rawValue,
                                message: error.localizedDescription
                            )
                            if firstRejectedChange == nil {
                                firstRejectedChange = (metadata.entity, metadata.logicalKey, reason)
                            }
                        }
                    case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy, .notAuthenticated, .operationCancelled,
                         .requestRateLimited, .serverResponseLost, .quotaExceeded:
                        if error.code == .quotaExceeded { sawQuotaExceeded = true }
                        observeServerRetryAfter(from: error)
                        continue
                    default:
                        // A permanent delete refusal is just as capable of pinning
                        // the queue as a permanent save refusal. Park the tombstone
                        // with its operation intact so Retry now retries a delete,
                        // never recreates the locally deleted record.
                        logger.error("CloudKit refused delete (code \(error.code.rawValue)) for \(recordID.recordName, privacy: .public); quarantining: \(error.localizedDescription)")
                        let reason = try quarantineRejectedChange(
                            entity: metadata.entity,
                            logicalKey: metadata.logicalKey,
                            recordName: recordID.recordName,
                            operation: .delete,
                            localModificationDate: metadata.userModificationDate,
                            serverModificationDate: metadata.userModificationDate,
                            errorCode: error.code.rawValue,
                            message: error.localizedDescription
                        )
                        if firstRejectedChange == nil {
                            firstRejectedChange = (metadata.entity, metadata.logicalKey, reason)
                        }
                    }
                } catch {
                    // One record's bookkeeping must not abandon the batch's.
                    // This handler used to be a single do/catch, so a throw here
                    // skipped every remaining record: their staged digests were
                    // never committed or cleared and their queue rows never
                    // dequeued, which is how 63 records retried forever while the
                    // asset cache regrew on every pass. Losing one record's
                    // bookkeeping costs a retry; losing the batch's costs a stall.
                    logger.error("Failed to record a CloudKit refused delete for \(failed.key.recordName, privacy: .public); continuing with the rest of the batch: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            // Any record that got through means there was room for it; a
            // batch that only hit the quota leaves the flag up.
            if sawQuotaExceeded || sent > 0 {
                let iCloudFull = sawQuotaExceeded
                await CloudKitSyncStatusCenter.publish { $0.setICloudFull(iCloudFull) }
            }

            if let firstRejectedChange {
                Self.postSyncConflictNotification(
                    entity: firstRejectedChange.entity,
                    logicalKey: firstRejectedChange.logicalKey,
                    reason: firstRejectedChange.reason
                )
            }

            if appliedServerChange {
                // Name the applied entities so the app refreshes only what the
                // conflict resolution actually touched. An entity-less post is
                // treated downstream as "refresh sources, goals, and sessions",
                // which turns every hourly conflict-resolving sync into the most
                // expensive refresh the app has.
                NotificationCenter.default.post(
                    name: .cloudKitSyncRemoteStoreDidChange,
                    object: nil,
                    userInfo: [
                        CloudKitSyncNotificationInfo.affectedEntitiesKey: affectedEntities.map(\.rawValue),
                        CloudKitSyncNotificationInfo.changedArtifactIDsKey: Array(changedArtifactIDs),
                    ]
                )
            }
            await schedulePendingChangesFromStore()
        } catch {
            // A CKError description names a framework condition, not library
            // content, and logging it privately is what made this handler
            // opaque: the failure that stalled 63 records for two days read
            // only as "<private>" in every log line it produced.
            logger.error("Failed to process sent CloudKit record changes: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension CloudKitSyncEngine: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let scope = scope(of: syncEngine)
        switch event {
        case .stateUpdate(let event):
            do {
                try store.saveSyncEngineState(event.stateSerialization, scope: scope)
            } catch {
                logger.error("Failed to persist CloudKit sync state: \(error.localizedDescription)")
            }
        case .accountChange(let event):
            // Both engines report the same account change; the bookkeeping
            // below is store-wide, so the private engine does it once.
            guard scope == .privateScope else { break }
            switch event.changeType {
            case .signIn:
                do {
                    try store.clearAllSyncMetadata()
                    try store.enqueueAllSyncableRecords(at: Self.bootstrapModificationDate)
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitRecordMapper.zoneID))])
                    for team in try store.loadTeams() where team.role == .owner {
                        ensureZoneExists(for: team.home)
                    }
                    await schedulePendingChangesFromStore()
                } catch {
                    logger.error("Failed to handle CloudKit sign-in: \(error.localizedDescription)")
                }
            case .switchAccounts, .signOut:
                do {
                    // Teams this account was invited to belong to the account,
                    // not the Mac; another Apple ID has no business seeing them.
                    for team in try store.loadTeams() where team.role == .member {
                        try store.removeTeamLocally(team.id)
                    }
                    try store.clearAllSyncMetadata()
                    try store.clearAllPendingSyncChanges()
                    try store.saveSyncEngineState(nil, scope: .privateScope)
                    try store.saveSyncEngineState(nil, scope: .shared)
                } catch {
                    logger.error("Failed to clear CloudKit state after account change: \(error.localizedDescription)")
                }
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let event):
            await handleFetchedDatabaseChanges(event, scope: scope)
        case .fetchedRecordZoneChanges(let event):
            await handleFetchedRecordZoneChanges(event, scope: scope)
        case .sentRecordZoneChanges(let event):
            await handleSentRecordZoneChanges(event, scope: scope)
        case .sentDatabaseChanges:
            break
        // The send/fetch window boundaries are the app's only honest progress
        // signal, so they drive the rail's status indicator instead of being ignored.
        case .willSendChanges:
            let remaining = (try? store.pendingSyncChangeCount()) ?? 0
            let pendingItems = (try? store.pendingSyncItemSummaries()) ?? []
            await CloudKitSyncStatusCenter.publish {
                $0.beginSending(remaining: remaining, items: pendingItems)
            }
        case .didSendChanges:
            let remaining = (try? store.pendingSyncChangeCount()) ?? 0
            let pendingItems = (try? store.pendingSyncItemSummaries()) ?? []
            let conflicts = (try? store.syncConflictCount()) ?? 0
            let issues = (try? store.syncIssueItemSummaries()) ?? []
            await CloudKitSyncStatusCenter.publish {
                $0.updateConflicts(count: conflicts, items: issues)
                $0.finishSending(remaining: remaining, items: pendingItems)
            }
        case .willFetchChanges:
            await CloudKitSyncStatusCenter.publish { $0.beginReceiving() }
        case .didFetchChanges:
            let conflicts = (try? store.syncConflictCount()) ?? 0
            let issues = (try? store.syncIssueItemSummaries()) ?? []
            await CloudKitSyncStatusCenter.publish {
                $0.updateConflicts(count: conflicts, items: issues)
                $0.finishReceiving()
            }
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            let scope = scope(of: syncEngine)
            let pending = try store.pendingSyncChanges().filter { $0.home.scope == scope }
            let pendingRecordNames = Set(pending.map(\.recordName))
            let staleStateChanges = syncEngine.state.pendingRecordZoneChanges.filter { change in
                guard context.options.scope.contains(change), let recordName = recordName(for: change) else {
                    return false
                }
                return !pendingRecordNames.contains(recordName)
            }
            if !staleStateChanges.isEmpty {
                syncEngine.state.remove(pendingRecordZoneChanges: staleStateChanges)
            }

            // Reconcile the other direction too. Only the engine's own state is
            // eligible for a batch, so a durable queue row with no state entry is
            // never built, never sent, and never resolved — it just sits, which
            // looks identical to a healthy backlog from every angle except the
            // clock. The removal above already treats the inverse mismatch as
            // repairable here rather than waiting for the next
            // `schedulePendingChangesFromStore`; this is the same repair for the
            // direction that actually loses work.
            let statefulRecordNames = Set(
                syncEngine.state.pendingRecordZoneChanges.compactMap(recordName(for:))
            )
            let unscheduled = pending.filter { !statefulRecordNames.contains($0.recordName) }
            if !unscheduled.isEmpty {
                syncEngine.state.add(pendingRecordZoneChanges: unscheduled.map { change in
                    change.operation == .delete
                        ? .deleteRecord(change.recordID)
                        : .saveRecord(change.recordID)
                })
                logger.warning(
                    "Rescheduled \(unscheduled.count) queued CloudKit change(s) missing from engine state"
                )
            }

            let pendingRanks = Dictionary(uniqueKeysWithValues: pending.enumerated().map {
                ($0.element.recordName, $0.offset)
            })
            let eligibleBatchChanges = syncEngine.state.pendingRecordZoneChanges.filter { change in
                guard context.options.scope.contains(change), let recordName = recordName(for: change) else {
                    return false
                }
                return pendingRecordNames.contains(recordName)
            }.sorted { lhs, rhs in
                let lhsRank = recordName(for: lhs).flatMap { pendingRanks[$0] } ?? Int.max
                let rhsRank = recordName(for: rhs).flatMap { pendingRanks[$0] } ?? Int.max
                return lhsRank < rhsRank
            }
            // A first Production publish can contain thousands of records and
            // paper records may need background iCloud file downloads to build
            // optional compatibility assets. Never make CloudKit wait for the
            // whole library before it can send the first useful records.
            // A refused batch is also an over-priced one, so come back smaller
            // as well as later. Isolation still wins when it applies: it is
            // hunting one poisoned record, not negotiating with a limiter.
            let batchLimit = CloudKitSyncBatchIsolationPolicy.batchLimit(
                defaultLimit: CloudKitSyncThrottleAdaptation.batchLimit(
                    defaultLimit: Self.maxRecordZoneChangesPerBatch,
                    consecutiveThrottles: consecutiveServerThrottles
                ),
                isIsolating: isIsolatingFailedBatch
            )
            let batchChanges = Array(eligibleBatchChanges.prefix(batchLimit))
            guard !batchChanges.isEmpty else { return nil }

            let saveLookup = Dictionary(uniqueKeysWithValues: pending.map { ($0.recordName, $0) })
            var readyChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            var recordsByName: [String: CKRecord] = [:]
            var firstBuildFailure: (
                entity: CloudKitSyncEntity,
                logicalKey: String,
                reason: String
            )?

            // Build before handing the batch to CKSyncEngine. Returning nil from
            // its provider silently leaves a durable save pending, which is an
            // unobservable permanent loop when local encoding keeps failing.
            for batchChange in batchChanges {
                guard case .saveRecord(let recordID) = batchChange else {
                    readyChanges.append(batchChange)
                    continue
                }
                guard let change = saveLookup[recordID.recordName], change.operation == .save else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [batchChange])
                    continue
                }

                do {
                    if let record = try CloudKitRecordMapper.makeRecord(
                        for: change,
                        store: store,
                        deferContent: isDeferringContentForBackfill
                    ) {
                        recordsByName[recordID.recordName] = record
                        inFlightSaveModificationDates[recordID.recordName] = change.changedAt
                        readyChanges.append(batchChange)
                        continue
                    }

                    // A row deleted between queue reconciliation and record
                    // construction is stale work, not a sync failure. Clear only
                    // the old save generation; a newer tombstone remains queued.
                    if try !store.hasLocalSyncRecord(
                        entity: change.entity,
                        logicalKey: change.logicalKey
                    ) {
                        try store.clearPendingSyncChange(
                            entity: change.entity,
                            logicalKey: change.logicalKey,
                            changedAt: change.changedAt
                        )
                        syncEngine.state.remove(pendingRecordZoneChanges: [batchChange])
                        logger.info("Discarded stale CloudKit save after its local record disappeared: \(recordID.recordName, privacy: .public)")
                        continue
                    }

                    let message = "ForeverLM could not prepare this local record for iCloud."
                    let reason = try quarantineRejectedChange(
                        entity: change.entity,
                        logicalKey: change.logicalKey,
                        recordName: recordID.recordName,
                        operation: .save,
                        localModificationDate: change.changedAt,
                        serverModificationDate: change.changedAt,
                        errorCode: nil,
                        message: message
                    )
                    syncEngine.state.remove(pendingRecordZoneChanges: [batchChange])
                    firstBuildFailure = firstBuildFailure
                        ?? (change.entity, change.logicalKey, reason)
                    logger.error("CloudKit record mapper returned no record for pending save \(recordID.recordName, privacy: .public); quarantined")
                } catch {
                    let reason = try quarantineRejectedChange(
                        entity: change.entity,
                        logicalKey: change.logicalKey,
                        recordName: recordID.recordName,
                        operation: .save,
                        localModificationDate: change.changedAt,
                        serverModificationDate: change.changedAt,
                        errorCode: nil,
                        message: error.localizedDescription
                    )
                    syncEngine.state.remove(pendingRecordZoneChanges: [batchChange])
                    firstBuildFailure = firstBuildFailure
                        ?? (change.entity, change.logicalKey, reason)
                    logger.error("Failed to build CloudKit record \(recordID.recordName, privacy: .public); quarantined: \(error.localizedDescription)")
                }
            }

            if let firstBuildFailure {
                Self.postSyncConflictNotification(
                    entity: firstBuildFailure.entity,
                    logicalKey: firstBuildFailure.logicalKey,
                    reason: firstBuildFailure.reason
                )
                let conflicts = (try? store.syncConflictCount()) ?? 0
                let issues = (try? store.syncIssueItemSummaries()) ?? []
                await CloudKitSyncStatusCenter.publish {
                    $0.updateConflicts(count: conflicts, items: issues)
                }
            }
            guard !readyChanges.isEmpty else { return nil }
            let builtRecordsByName = recordsByName
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: readyChanges) { recordID in
                builtRecordsByName[recordID.recordName]
            }
        } catch {
            logger.error("Failed to build CloudKit change batch: \(error.localizedDescription)")
            return nil
        }
    }
}

extension Notification.Name {
    static let cloudKitSyncStoreDidChange = Notification.Name("CloudKitSyncStoreDidChange")
    static let cloudKitSyncRemoteStoreDidChange = Notification.Name("CloudKitSyncRemoteStoreDidChange")
    static let cloudKitSyncConflictDidOccur = Notification.Name("CloudKitSyncConflictDidOccur")
    /// The learner's iCloud storage just filled up and uploads stopped.
    static let cloudKitICloudStorageDidFill = Notification.Name("CloudKitICloudStorageDidFill")
    /// A book cover arrived from CloudKit and now exists on disk. Rendered
    /// thumbnails key off the cover's path, which a recovery does not change,
    /// so a placeholder needs this to know there is finally something to read.
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
    static let conflictEntityKey = "CloudKitSyncConflictEntity"
    static let conflictLogicalKey = "CloudKitSyncConflictLogicalKey"
    static let conflictReasonKey = "CloudKitSyncConflictReason"
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

    func recordReceived(_ count: Int) {
        guard count > 0 else { return }
        receivedThisPass += count
        guard case .receiving = phase else { return }
        phase = .receiving(received: receivedThisPass)
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

    func updateConflicts(count: Int, items: [CloudKitSyncIssueItem] = []) {
        conflictCount = max(count, 0)
        issueItems = items
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
