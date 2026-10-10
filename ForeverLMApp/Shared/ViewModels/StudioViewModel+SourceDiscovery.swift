import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

/// Per-key debounced, latest-wins writers for reading-progress persistence.
/// Keyed by "<kind>:<sourceID>" so page and locator writes for the same source
/// stay independent; scheduling a new write cancels the prior task for that key.
@MainActor
private final class ReadingProgressWriteCoordinator {
    static let shared = ReadingProgressWriteCoordinator()
    var tasks: [String: Task<Void, Never>] = [:]
}

extension StudioViewModel {

    // MARK: - Source Discovery

    nonisolated static let browserAccessPromptDismissedKey = "discovery.browserAccessPromptDismissed"
    nonisolated static let podcastAccessPromptDismissedKey = "discovery.podcastAccessPromptDismissed"

    func startProtectedSourceAutoSyncIfReady() {
        guard hasCompletedInitialQueueLoad else { return }
        startReadingListAutoSync()
        startPodcastAutoSync()
        #if os(macOS)
        startZoomLocalTranscriptAutoSync()
        #endif
    }

    /// Discover new sources from local files and network.
    /// Refresh only the sources relevant to the given tab (or all if nil).
    func refreshTab(_ tab: StudioSidebarTab? = nil) async {
        guard !isLoadingQueue else { return }
        isLoadingQueue = true
        loadingStepScope = tab
        defer {
            isLoadingQueue = false
            loadingStep = nil
            loadingStepScope = nil
            invalidateFilteredSidebarCache()
        }
        let articlesSnapshot = articles

        syncCloudKitInBackground()
        await refreshTabUpstreamPlugins(for: tab)

        loadingStep = "Refreshing local \(refreshScopeLabel(for: tab))…"
        var discovered = await discoverNewSourcesOffMain(onlyTab: tab)
        let scannedSources = discovered
        let promotedIds = await promoteExistingPaperSourcesFromDiscovered(discovered)

        discovered = await filterAlreadyPersistedSources(discovered)
        guard !discovered.isEmpty else {
            loadingStep = "Loading library…"
            do {
                articles = preservingLoadedContent(
                    in: try await storage.loadLibrarySources(teamID: activeTeamID).sources,
                    preservingFrom: articlesSnapshot
                )
                autoFetchNewlyAddedPapers()
                autoFetchUnfetchedSources()
                if tab == nil || tab == .podcasts {
                    Task(priority: .utility) { [weak self] in
                        await self?.processPendingPodcastTranscripts()
                    }
                }
            } catch {
                logger.error("Failed to reload sources after refresh: \(error)")
            }
            if tab == nil || tab == .meetings {
                await refreshMeetingMetadata()
            }
            if !promotedIds.isEmpty {
                showPaperSyncSummaryIfNeeded(newPaperIds: promotedIds)
                syncCloudKitInBackground()
            }
            reportReadingListImport(
                trigger: "manual refresh",
                scope: tab,
                warnings: discoveryWarnings(for: tab),
                scannedSources: scannedSources,
                candidateSources: [],
                insertedSources: [],
                promotedCount: promotedIds.count,
                showUserToast: true
            )
            return
        }

        loadingStep = "Classifying new sources…"
        await classifyDiscoveredSourceTypesBeforePersistence(&discovered)
        await enrichYouTubeMetadataBeforePersistence(&discovered)

        // Extract DOIs for papers before persistence (enables DOI-based dedup)
        for i in discovered.indices where discovered[i].sourceType == .paper && discovered[i].doi == nil {
            discovered[i].doi = PaperService.extractDOI(from: discovered[i].url)
        }

        // Insert new sources into the database; the DB handles dedup.
        let readingListCandidateCount = discovered.filter(Self.isBrowserReadingListSource).count
        if readingListCandidateCount > 0 {
            loadingStep = "Reading List: adding \(readingListCandidateCount) new \(readingListCandidateCount == 1 ? "source" : "sources")…"
        } else {
            loadingStep = "Saving new sources…"
        }
        var insertedCount = 0
        var insertedPaperIds = Set<String>()
        var insertedSources: [StudioArticle] = []
        for i in discovered.indices {
            do {
                let inserted = try await storage.insertSourceIfNew(&discovered[i])
                if inserted {
                    insertedCount += 1
                    insertedSources.append(discovered[i])
                    if discovered[i].sourceType == .book {
                        await persistWholeBookMetadataIfNeeded(for: discovered[i])
                    }
                    if discovered[i].sourceType == .paper {
                        insertedPaperIds.insert(discovered[i].id)
                    }
                }
            } catch {
                logger.warning("Failed to persist discovered source \(discovered[i].url): \(error)")
            }
        }
        reportReadingListImport(
            trigger: "manual refresh",
            scope: tab,
            warnings: discoveryWarnings(for: tab),
            scannedSources: scannedSources,
            candidateSources: discovered,
            insertedSources: insertedSources,
            promotedCount: promotedIds.count,
            showUserToast: true
        )
        let changedPaperIds = insertedPaperIds.union(promotedIds)
        if insertedCount > 0 || !promotedIds.isEmpty {
            let changedCount = insertedCount + promotedIds.count
            logger.info("Refresh changed \(changedCount) \(tab?.rawValue ?? "") source(s): \(insertedCount) inserted, \(promotedIds.count) promoted")
            loadingStep = "Saving \(changedCount) \(changedCount == 1 ? "source" : "sources")…"
            syncCloudKitInBackground()
        }

        // Reload from the database — the single source of truth.
        loadingStep = "Loading library…"
        do {
            articles = preservingLoadedContent(
                in: try await storage.loadLibrarySources(teamID: activeTeamID).sources,
                preservingFrom: articlesSnapshot
            )
            autoFetchNewlyAddedPapers()
            autoFetchUnfetchedSources()
        } catch {
            logger.error("Failed to reload sources after refresh: \(error)")
        }
        if tab == nil || tab == .meetings {
            await refreshMeetingMetadata()
        }
        let updatedYouTubeMetadataCount = await updateExistingYouTubeMetadataFromDiscovered(discovered)
        if updatedYouTubeMetadataCount > 0 {
            logger.info("Refresh updated YouTube metadata for \(updatedYouTubeMetadataCount) existing source(s)")
            syncCloudKitInBackground()
        }
        Task { await classifyUnclassifiedSources() }
        showPaperSyncSummaryIfNeeded(newPaperIds: changedPaperIds)
        // Podcast discovery publishes placeholders first. Transcript retrieval
        // and AI formatting continue independently so the refresh can finish
        // and the rows can remain visible under Processing.
        if tab == nil || tab == .podcasts {
            Task(priority: .utility) { [weak self] in
                await self?.processPendingPodcastTranscripts()
            }
        }
    }

    /// The upstream stores a sidebar refresh or a plugin event can pull from,
    /// each with its own cooldown on the event path.
    enum EventSyncPlugin: Hashable, CaseIterable, Sendable {
        case xBookmarks
        case youtube
        case googleDriveMeetings
        case browserReadingLists
        case applePodcasts

        /// How long an event leaves this plugin alone after it last synced,
        /// on any path. A remote sync is a round of API calls (X pages its
        /// bookmarks, YouTube lists the whole Liked feed) followed by the
        /// backfills that run behind it, all through the one storage actor; an
        /// activation every time the learner glances at another window must not
        /// repeat that, and nothing upstream changes minute to minute. A local
        /// store is a file-snapshot check that no-ops when nothing changed, so
        /// it only needs to be kept from stacking behind a bouncy scroll.
        var eventSyncCooldown: TimeInterval {
            switch self {
            case .xBookmarks, .youtube, .googleDriveMeetings: return 5 * 60
            case .browserReadingLists, .applePodcasts: return 30
            }
        }

        /// The plugins a tab's refresh reaches; every plugin for the
        /// all-sources scope.
        static func plugins(for tab: StudioSidebarTab?) -> Set<EventSyncPlugin> {
            switch tab {
            case nil: return Set(allCases)
            case .xPosts?: return [.xBookmarks]
            case .videos?: return [.youtube]
            // Google Drive is the only meeting provider with anything to pull.
            // Read AI and local folder imports are pushed in, so refreshing
            // Meetings syncs Drive and leaves the rest alone.
            case .meetings?: return [.googleDriveMeetings]
            case .articles?, .papers?: return [.browserReadingLists]
            case .podcasts?: return [.applePodcasts]
            case .books?: return []
            }
        }
    }

    /// Which of a tab's plugins an event at `now` may sync: those never
    /// synced, and those whose last sync is older than their cooldown. A
    /// plugin is keyed by what it is, not by the scope that asked, so an
    /// activation (all sources) followed by opening the X tab counts as one X
    /// sync, not two.
    nonisolated static func dueEventPlugins(
        for tab: StudioSidebarTab?,
        lastSyncedAt: [EventSyncPlugin: Date],
        now: Date
    ) -> Set<EventSyncPlugin> {
        EventSyncPlugin.plugins(for: tab).filter { plugin in
            guard let last = lastSyncedAt[plugin] else { return true }
            return now.timeIntervalSince(last) >= plugin.eventSyncCooldown
        }
    }

    /// Records that these plugins are syncing now, so the next event leaves
    /// them alone for their cooldown. Stamped when a sync starts rather than
    /// when it ends: a slow sync must not be followed straight away by another.
    func markPluginsSyncing(_ plugins: Set<EventSyncPlugin>, at now: Date = Date()) {
        for plugin in plugins {
            lastPluginSyncAt[plugin] = now
        }
    }

    /// Sync upstream plugins for the tab being refreshed. Overscroll refresh in
    /// the sidebar should feel like a real sync, not just a SQLite reload. Pass
    /// `silent: true` for event-triggered syncs that must not surface loading UI,
    /// and `only` to sync a subset of the tab's plugins (the event path passes
    /// the ones whose cooldown has lapsed).
    func refreshTabUpstreamPlugins(
        for tab: StudioSidebarTab?,
        silent: Bool = false,
        only plugins: Set<EventSyncPlugin>? = nil
    ) async {
        let wanted = plugins ?? EventSyncPlugin.plugins(for: tab)

        // While X's rate limit is in force every sync is a refused request;
        // the resume task runs the one that will succeed. Spent credits have no
        // such end, so only a sync the learner asked for tries again.
        if wanted.contains(.xBookmarks), isXOAuthSignedIn, !isXSyncPaused,
           !(silent && xCreditsDepleted) {
            markPluginsSyncing([.xBookmarks])
            if !silent { loadingStep = "Syncing X bookmarks…" }
            await syncXBookmarks()
        }

        if wanted.contains(.youtube) {
            markPluginsSyncing([.youtube])
            if !silent { loadingStep = "Syncing YouTube…" }
            await refreshYouTubeVideosOnSidebarRefresh()
        }

        if wanted.contains(.googleDriveMeetings) {
            markPluginsSyncing([.googleDriveMeetings])
            if !silent, GoogleDriveService.shared.isSignedIn {
                loadingStep = "Syncing Google Drive meetings…"
            }
            await refreshConnectedGoogleDriveMeetings(silent: silent)
        }
    }

    /// Event-triggered plugin sync: pull the latest from the tab's upstream
    /// plugins immediately when the user signals interest (momentum
    /// scroll-to-top, app activation, a tab opening) instead of waiting for a
    /// background poll. Plugin syncs are silent and publish list changes only
    /// when something actually changed upstream, so firing this on every event
    /// is churn-free for the UI. What it is not free of is the work itself, so
    /// each plugin carries its own cooldown (`EventSyncPlugin`) and an
    /// event syncs only the plugins whose cooldown has lapsed — however
    /// often the learner switches windows or scrolls to the top.
    func syncTabPluginsOnEvent(_ tab: StudioSidebarTab?) {
        // Never at startup: the activation event fires at launch too, and app
        // startup must stay read-only and fast.
        guard hasCompletedInitialQueueLoad, !isLoadingQueue else { return }
        let due = Self.dueEventPlugins(for: tab, lastSyncedAt: lastPluginSyncAt, now: Date())
        guard !due.isEmpty else { return }
        // Claim them before the task starts, so two events on one runloop turn
        // do not both find the same plugins due.
        markPluginsSyncing(due)
        Task { [weak self] in
            guard let self else { return }
            // Local databases must never wait behind remote plugins. A slow
            // or signed-out network integration previously held Apple Podcasts
            // discovery for minutes during the all-sources activation path.
            async let upstream: Void = self.refreshTabUpstreamPlugins(for: tab, silent: true, only: due)
            async let local: Void = self.syncLocalDiscoveryOnEvent(for: tab, only: due)
            _ = await (upstream, local)
        }
    }

    /// Event-path counterpart of `refreshTabUpstreamPlugins` for the sources
    /// whose upstream is a local store rather than a remote API: browser Reading
    /// Lists (Articles/Papers) and the Apple Podcasts library (Podcasts). The
    /// full refreshTab pipeline already scans both via `discoverNewSourcesOffMain`,
    /// so this runs only on the silent event path. Both scans are snapshot-gated
    /// or off-main and publish UI state only when something actually changed.
    func syncLocalDiscoveryOnEvent(
        for tab: StudioSidebarTab?,
        only plugins: Set<EventSyncPlugin>? = nil
    ) async {
        let wanted = plugins ?? EventSyncPlugin.plugins(for: tab)

        if wanted.contains(.browserReadingLists) {
            markPluginsSyncing([.browserReadingLists])
            await syncBrowserReadingListsIfChanged()
        }

        if wanted.contains(.applePodcasts) {
            markPluginsSyncing([.applePodcasts])
            await syncPodcastLibraryIfChanged()
            // Discovery's modification snapshot may correctly no-op while an
            // existing source still has durable queued transcript work. Opening
            // or refreshing Podcasts is itself the retry event; do not make
            // transcript progress depend on Apple inserting another row first.
            await processPendingPodcastTranscripts()
        }
    }

    /// Check all active sources against their upstream origins.
    /// Archive sources whose upstream has been removed.
    func reconcileUpstreamDeletions() async {
        // Local files (PDFs, EPUBs, books, course materials)
        do {
            let archivedFiles = try await storage.reconcileLocalFiles()
            if archivedFiles > 0 {
                logger.info("Reconciliation: archived \(archivedFiles) source(s) with missing files")
            }
        } catch {
            logger.error("Reconciliation failed for local files: \(error)")
        }

        // Safari Reading List, API-synced sources can be added here later
    }

    /// Run all discovery sources. New sources are written directly to SQLite.
    /// Returns the IDs of newly inserted sources.
    func discoverAndPersist(onlyTab: StudioSidebarTab? = nil) async -> Set<String> {
        var discovered = await discoverNewSourcesOffMain(onlyTab: onlyTab, showProgress: false)
        let scannedSources = discovered
        var insertedIds = Set<String>()
        let promotedIds = await promoteExistingPaperSourcesFromDiscovered(discovered)

        discovered = await filterAlreadyPersistedSources(discovered)
        guard !discovered.isEmpty else {
            reportReadingListImport(
                trigger: "background sync",
                scope: onlyTab,
                warnings: discoveryWarnings(for: onlyTab),
                scannedSources: scannedSources,
                candidateSources: [],
                insertedSources: [],
                promotedCount: promotedIds.count,
                showUserToast: false
            )
            return promotedIds
        }

        await classifyDiscoveredSourceTypesBeforePersistence(&discovered)
        await enrichYouTubeMetadataBeforePersistence(&discovered)

        // Extract DOIs for papers before persistence (enables DOI-based dedup)
        for i in discovered.indices where discovered[i].sourceType == .paper && discovered[i].doi == nil {
            discovered[i].doi = PaperService.extractDOI(from: discovered[i].url)
        }

        var insertedSources: [StudioArticle] = []
        for i in discovered.indices {
            do {
                let inserted = try await storage.insertSourceIfNew(&discovered[i])
                if inserted {
                    insertedIds.insert(discovered[i].id)
                    insertedSources.append(discovered[i])
                    if discovered[i].sourceType == .book {
                        await persistWholeBookMetadataIfNeeded(for: discovered[i])
                    }
                }
            } catch {
                logger.warning("Failed to persist discovered source \(discovered[i].url): \(error)")
            }
        }

        reportReadingListImport(
            trigger: "background sync",
            scope: onlyTab,
            warnings: discoveryWarnings(for: onlyTab),
            scannedSources: scannedSources,
            candidateSources: discovered,
            insertedSources: insertedSources,
            promotedCount: promotedIds.count,
            showUserToast: false
        )

        return insertedIds.union(promotedIds)
    }

    func startReadingListAutoSync() {
        guard readingListAutoSyncTask == nil else { return }
        readingListAutoSyncTask = Task { [weak self] in
            await self?.runReadingListAutoSync()
        }
    }

    /// A browser was turned on or off in setup. Re-aim the watcher at the
    /// chosen browsers and scan now, so a newly chosen Reading List arrives
    /// without waiting for a file event or the 20-minute backstop.
    func readingListBrowsersDidChange() {
        guard hasCompletedInitialQueueLoad else { return }
        guard readingListAutoSyncTask != nil else {
            startReadingListAutoSync()
            return
        }
        let watcher = readingListFileWatcher
        Task.detached(priority: .userInitiated) { [weak self] in
            watcher?.setWatchedRoots(Self.readingListWatchRoots())
            await self?.syncBrowserReadingListsIfChanged(force: true)
        }
    }

    nonisolated func runReadingListAutoSync() async {
        // File-system events are the primary freshness mechanism: watch the
        // browser bookmark storage roots and sync only when a relevant file
        // actually changes. The watcher debounces bursts and cooldown-limits
        // fires; the modification snapshot stays the final no-op gate, so a
        // file touch that doesn't change any mtime we track never churns.
        let watcher = LocalSourceFileWatcher(content: .browserReadingLists) { [weak self] in
            guard let self else { return }
            Task.detached(priority: .utility) {
                await self.syncBrowserReadingListsIfChanged()
            }
        }
        await MainActor.run {
            // Reconcile once after the persisted library is already visible.
            // Capturing the current mtimes here would incorrectly treat Reading
            // List changes made while ForeverLM was closed as already synced.
            self.readingListModificationSnapshot = [:]
            self.readingListFileWatcher = watcher
        }
        watcher.setWatchedRoots(Self.readingListWatchRoots())
        await syncBrowserReadingListsIfChanged(force: true)

        // Low-frequency backstop behind the events: FSEvents can be silent
        // when sandbox/TCC hides a path, and browser roots can appear
        // mid-session (browser installed, setting toggled). Each tick
        // re-resolves the watched roots and runs one snapshot-gated sync.
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(20 * 60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            watcher.setWatchedRoots(Self.readingListWatchRoots())
            await syncBrowserReadingListsIfChanged()
        }
    }

    /// Arm Apple Podcasts discovery after the persisted library is already on
    /// screen. The first pass reconciles play state that arrived before launch;
    /// later passes are driven by SQLite/WAL file changes.
    func startPodcastAutoSync() {
        guard podcastAutoSyncTask == nil else { return }
        podcastAutoSyncTask = Task { [weak self] in
            await self?.runPodcastAutoSync()
        }
    }

    nonisolated func runPodcastAutoSync() async {
        let homeDir = BookmarkAccessManager.realHomeDirectory
        let initialSnapshot = Self.podcastLibraryModificationSnapshot(homeDir: homeDir)
        let watcher = LocalSourceFileWatcher(content: .applePodcasts) { [weak self] in
            guard let self else { return }
            Task.detached(priority: .utility) {
                await self.syncPodcastLibraryIfChanged()
            }
        }
        defer { watcher.cancel() }

        await MainActor.run {
            self.podcastLibraryModificationSnapshot = initialSnapshot
            self.podcastLibraryFileWatcher = watcher
        }
        watcher.setWatchedRoots(Self.podcastLibraryWatchRoots(homeDir: homeDir))

        // Startup itself remains a read-only fast path. This reconciliation is
        // launched only after loadQueue has published the existing library.
        await syncPodcastLibraryIfChanged(force: true)

        // Low-frequency backstop behind FSEvents. The snapshot gate makes this
        // a no-op unless Apple's database or WAL actually changed.
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(20 * 60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            watcher.setWatchedRoots(Self.podcastLibraryWatchRoots(homeDir: homeDir))
            await syncPodcastLibraryIfChanged()
        }
    }

    nonisolated static func podcastLibraryWatchRoots(homeDir: String) -> [String] {
        let documents = (homeDir as NSString).appendingPathComponent(
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents"
        )
        // FSEvents setup itself must not become an implicit permission request.
        return FileManager.default.isReadableFile(atPath: documents) ? [documents] : []
    }

    nonisolated static func podcastLibraryModificationSnapshot(
        homeDir: String
    ) -> [String: PodcastLibraryFileFingerprint] {
        let database = (homeDir as NSString).appendingPathComponent(
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
        )
        let paths = ["database": database, "wal": database + "-wal"]
        let fm = FileManager.default
        var snapshot: [String: PodcastLibraryFileFingerprint] = [:]
        for (key, path) in paths {
            guard fm.isReadableFile(atPath: path),
                  let attributes = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else { continue }
            snapshot[key] = PodcastLibraryFileFingerprint(
                modifiedAt: modifiedAt,
                size: size.uint64Value
            )
        }
        return snapshot
    }

    /// Serialize launch, FSEvents, activation, and backstop requests. An event
    /// that arrives during a scan records one trailing pass instead of being
    /// dropped, closing the narrow race between the file snapshot and SQLite read.
    nonisolated func syncPodcastLibraryIfChanged(force: Bool = false) async {
        let started = await MainActor.run { () -> Bool in
            if self.podcastAutoSyncInFlight {
                self.podcastAutoSyncNeedsAnotherPass = true
                self.podcastAutoSyncNeedsForcedPass = self.podcastAutoSyncNeedsForcedPass || force
                return false
            }
            self.podcastAutoSyncInFlight = true
            return true
        }
        guard started else { return }

        var forceNextPass = force
        while true {
            await performPodcastLibrarySyncIfChanged(force: forceNextPass)
            let nextPass = await MainActor.run { () -> (shouldContinue: Bool, force: Bool) in
                if self.podcastAutoSyncNeedsAnotherPass {
                    let shouldForce = self.podcastAutoSyncNeedsForcedPass
                    self.podcastAutoSyncNeedsAnotherPass = false
                    self.podcastAutoSyncNeedsForcedPass = false
                    return (true, shouldForce)
                }
                self.podcastAutoSyncInFlight = false
                return (false, false)
            }
            guard nextPass.shouldContinue else { return }
            forceNextPass = nextPass.force
        }
    }

    nonisolated func performPodcastLibrarySyncIfChanged(force: Bool) async {
        let homeDir = BookmarkAccessManager.realHomeDirectory
        let fileSnapshot = Self.podcastLibraryModificationSnapshot(homeDir: homeDir)
        let base = await MainActor.run { () -> PodcastAutoSyncBase? in
            guard !self.isLoadingQueue,
                  force || fileSnapshot != self.podcastLibraryModificationSnapshot else {
                return nil
            }
            return PodcastAutoSyncBase(storage: self.storage, previousArticles: self.articles, activeTeamID: self.activeTeamID)
        }
        guard let base else { return }

        let discoverySnapshot = Self.podcastDiscoveryFileSnapshotOffMain(homeDir: homeDir)
        let discovery = Self.podcastDiscoveryResult(from: discoverySnapshot)
        await MainActor.run {
            self.updateDiscoveryWarnings(podcast: discovery.warnings)
            switch discoverySnapshot.status {
            case .ok, .noEpisodesFound, .unsupportedPlatform, .appNotInstalled, .schemaChanged:
                self.podcastLibraryModificationSnapshot = fileSnapshot
            case .permissionDenied, .openFailed:
                // Keep the previous fingerprint so activation/backstop retries
                // after access is granted or a transient SQLite lock clears.
                break
            }
        }

        let persistence = await Self.persistPodcastAutoSync(
            scannedSources: discovery.articles,
            storage: base.storage
        )
        await self.alignUnplayedPodcastDates(with: discoverySnapshot.episodeMetadata)
        guard !persistence.insertedIDs.isEmpty else { return }

        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        log.info("Podcast library auto-sync inserted \(persistence.insertedIDs.count) source(s)")

        let reloaded: [StudioArticle]
        do {
            reloaded = try await base.storage.loadLibrarySources(teamID: base.activeTeamID).sources
        } catch {
            log.error("Failed to reload sources after podcast auto-sync: \(error.localizedDescription)")
            return
        }
        let merged = await Task.detached(priority: .userInitiated) {
            Self.preservingLoadedContent(in: reloaded, preservingFrom: base.previousArticles)
        }.value

        await MainActor.run {
            self.articles = merged
            self.syncCloudKitInBackground()
            Task(priority: .utility) { [weak self] in
                await self?.processPendingPodcastTranscripts()
            }
        }
    }

    nonisolated static func persistPodcastAutoSync(
        scannedSources: [StudioArticle],
        storage: StorageService
    ) async -> PodcastAutoSyncPersistenceResult {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        let candidates: [StudioArticle]
        do {
            candidates = try await storage.newSourceCandidates(from: scannedSources)
        } catch {
            log.warning("Failed to prefilter discovered podcasts: \(error.localizedDescription)")
            return PodcastAutoSyncPersistenceResult(insertedIDs: [], insertedSources: [])
        }

        var mutableCandidates = candidates
        var insertedIDs = Set<String>()
        var insertedSources: [StudioArticle] = []
        for index in mutableCandidates.indices {
            do {
                guard try await storage.insertSourceIfNew(&mutableCandidates[index]) else { continue }
                insertedIDs.insert(mutableCandidates[index].id)
                insertedSources.append(mutableCandidates[index])
            } catch {
                log.warning("Failed to persist discovered podcast \(mutableCandidates[index].url): \(error.localizedDescription)")
            }
        }
        return PodcastAutoSyncPersistenceResult(
            insertedIDs: insertedIDs,
            insertedSources: insertedSources
        )
    }

    /// Browser storage roots the reading-list watcher should observe, based on
    /// the current per-browser settings. Does filesystem existence checks —
    /// call off the main actor.
    nonisolated static func readingListWatchRoots() -> [String] {
        let safariEnabled = DefaultsEscapeHatch.bool(forKey: "readingListSafari", default: true)
        let chromeEnabled = DefaultsEscapeHatch.bool(forKey: "readingListChrome", default: true)
        let braveEnabled = DefaultsEscapeHatch.bool(forKey: "readingListBrave", default: true)
        let homeDir = BookmarkAccessManager.realHomeDirectory

        var candidates: [String] = []
        if safariEnabled {
            candidates.append((homeDir as NSString).appendingPathComponent("Library/Safari"))
        }
        if chromeEnabled {
            candidates.append((homeDir as NSString).appendingPathComponent("Library/Application Support/Google/Chrome"))
        }
        if braveEnabled {
            candidates.append((homeDir as NSString).appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser"))
        }

        let fm = FileManager.default
        return candidates.filter { fm.isReadableFile(atPath: $0) }
    }

    /// Entry point for watcher, backstop, and access-grant rescans. An event
    /// arriving during a scan records one trailing pass instead of being
    /// dropped. In particular, a forced post-grant pass must not lose a race
    /// with the permission-denied scan that caused the banner.
    nonisolated func syncBrowserReadingListsIfChanged(force: Bool = false) async {
        let started = await MainActor.run { () -> Bool in
            if self.readingListAutoSyncInFlight {
                self.readingListAutoSyncNeedsAnotherPass = true
                self.readingListAutoSyncNeedsForcedPass = self.readingListAutoSyncNeedsForcedPass || force
                return false
            }
            self.readingListAutoSyncInFlight = true
            return true
        }
        guard started else { return }

        var forceNextPass = force
        while true {
            await performBrowserReadingListSyncIfChanged(force: forceNextPass)
            let nextPass = await MainActor.run { () -> (shouldContinue: Bool, force: Bool) in
                if self.readingListAutoSyncNeedsAnotherPass {
                    let shouldForce = self.readingListAutoSyncNeedsForcedPass
                    self.readingListAutoSyncNeedsAnotherPass = false
                    self.readingListAutoSyncNeedsForcedPass = false
                    return (true, shouldForce)
                }
                self.readingListAutoSyncInFlight = false
                return (false, false)
            }
            guard nextPass.shouldContinue else { return }
            forceNextPass = nextPass.force
        }
    }

    nonisolated func performBrowserReadingListSyncIfChanged(force: Bool = false) async {
        guard let base = await MainActor.run(body: { self.makeReadingListAutoSyncBase() }) else { return }

        // Resolve the Safari security-scoped bookmark off the main actor — the
        // resolution does blocking filesystem / TCC work that would beachball.
        let safariFolderURL: URL? = base.safariEnabled
            ? BookmarkAccessManager.shared.resolveBookmark(for: .safariBookmarks)
            : nil
        let input = ReadingListAutoSyncInput(
            request: BrowserReadingListWorkerRequest(
                homeDir: base.homeDir,
                safariEnabled: base.safariEnabled,
                chromeEnabled: base.chromeEnabled,
                braveEnabled: base.braveEnabled,
                safariFolderPath: safariFolderURL?.path
            ),
            articles: base.articles,
            storage: base.storage,
            shouldStopSafariFolderAccess: safariFolderURL != nil,
            activeTeamID: base.activeTeamID
        )

        let snapshot = Self.browserReadingListModificationSnapshot(
            homeDir: input.request.homeDir,
            safariEnabled: input.request.safariEnabled,
            chromeEnabled: input.request.chromeEnabled,
            braveEnabled: input.request.braveEnabled
        )
        let shouldSync = await MainActor.run { () -> Bool in
            guard !self.isLoadingQueue,
                  Self.readingListSnapshotRequiresSync(
                    current: snapshot,
                    lastSynced: self.readingListModificationSnapshot,
                    force: force
                  ) else {
                return false
            }
            return true
        }
        guard shouldSync else {
            await stopReadingListSafariFolderAccessIfNeeded(input)
            return
        }

        let browserResult = await Self.discoverBrowserReadingListsOutsideMainProcess(request: input.request)
        await stopReadingListSafariFolderAccessIfNeeded(input)

        // A failed or suspicious read must remain retryable. Safari replaces
        // Bookmarks.plist atomically, and committing its mtime before a
        // successful read could suppress the only event for the new file.
        if browserResult.warnings.isEmpty {
            await MainActor.run {
                self.readingListModificationSnapshot = snapshot
            }
        }

        let result = await Self.persistReadingListAutoSync(
            browserResult: browserResult,
            existingArticles: input.articles,
            storage: input.storage
        )

        await MainActor.run {
            self.updateDiscoveryWarnings(browser: result.warnings)
            self.reportReadingListImport(
                trigger: "background sync",
                scope: .articles,
                warnings: result.warnings,
                scannedSources: result.scannedSources,
                candidateSources: result.candidateSources,
                insertedSources: result.insertedSources,
                promotedCount: result.promotedIDs.count,
                showUserToast: false
            )
        }

        guard !result.changedIDs.isEmpty else { return }

        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        logger.info("Reading list auto-sync changed \(result.changedIDs.count) source(s)")
        let reloaded: [StudioArticle]
        do {
            reloaded = try await input.storage.loadLibrarySources(teamID: input.activeTeamID).sources
        } catch {
            logger.error("Failed to reload articles after reading list auto-sync: \(error.localizedDescription)")
            return
        }

        await MainActor.run {
            let previousArticles = self.articles
            self.articles = self.preservingLoadedContent(in: reloaded, preservingFrom: previousArticles)
            self.autoFetchNewlyAddedPapers()
            self.autoFetchUnfetchedSources()
            self.syncCloudKitInBackground()
            Task { await self.backfillMissingArtwork(onlyIds: result.changedIDs) }
        }
    }

    /// Cheap main-actor snapshot for reading-list auto-sync. The Safari
    /// security-scoped bookmark is resolved off the main actor by the caller.
    func makeReadingListAutoSyncBase() -> ReadingListAutoSyncBase? {
        guard !isLoadingQueue else { return nil }

        return ReadingListAutoSyncBase(
            safariEnabled: DefaultsEscapeHatch.bool(forKey: "readingListSafari", default: true),
            chromeEnabled: DefaultsEscapeHatch.bool(forKey: "readingListChrome", default: true),
            braveEnabled: DefaultsEscapeHatch.bool(forKey: "readingListBrave", default: true),
            homeDir: realHomeDirectory,
            articles: articles,
            storage: storage,
            activeTeamID: activeTeamID
        )
    }

    nonisolated func stopReadingListSafariFolderAccessIfNeeded(_ input: ReadingListAutoSyncInput) async {
        guard input.shouldStopSafariFolderAccess else { return }
        BookmarkAccessManager.shared.stopAccessing(for: .safariBookmarks)
    }

    func browserReadingListModificationSnapshotOffMain() async -> [String: Date] {
        let safariEnabled = DefaultsEscapeHatch.bool(forKey: "readingListSafari", default: true)
        let chromeEnabled = DefaultsEscapeHatch.bool(forKey: "readingListChrome", default: true)
        let braveEnabled = DefaultsEscapeHatch.bool(forKey: "readingListBrave", default: true)
        let homeDir = realHomeDirectory

        return await Task.detached(priority: .utility) {
            Self.browserReadingListModificationSnapshot(
                homeDir: homeDir,
                safariEnabled: safariEnabled,
                chromeEnabled: chromeEnabled,
                braveEnabled: braveEnabled
            )
        }.value
    }

    nonisolated static func browserReadingListModificationSnapshot(
        homeDir: String,
        safariEnabled: Bool,
        chromeEnabled: Bool,
        braveEnabled: Bool
    ) -> [String: Date] {
        let fm = FileManager.default
        var snapshot: [String: Date] = [:]

        func recordFile(_ path: String, key: String) {
            guard fm.isReadableFile(atPath: path),
                  let values = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = values[.modificationDate] as? Date else { return }
            snapshot[key] = modifiedAt
        }

        func recordDirectory(_ path: String, key: String) {
            guard fm.isReadableFile(atPath: path),
                  let files = try? fm.contentsOfDirectory(atPath: path) else { return }
            var newest: Date?
            for file in files {
                let filePath = (path as NSString).appendingPathComponent(file)
                guard let values = try? fm.attributesOfItem(atPath: filePath),
                      let modifiedAt = values[.modificationDate] as? Date else { continue }
                if newest.map({ modifiedAt > $0 }) ?? true {
                    newest = modifiedAt
                }
            }
            if let newest {
                snapshot[key] = newest
            }
        }

        if safariEnabled {
            let path = (homeDir as NSString).appendingPathComponent("Library/Safari/Bookmarks.plist")
            recordFile(path, key: "safari-bookmarks")
        }

        if chromeEnabled {
            let root = (homeDir as NSString).appendingPathComponent("Library/Application Support/Google/Chrome")
            for path in (try? chromiumBookmarksPathsOffMain(browserRoot: root)) ?? [] {
                recordFile(path, key: "chrome-bookmarks-\(path)")
            }
            for syncDir in (try? chromiumSyncDirectoriesOffMain(browserRoot: root)) ?? [] {
                recordDirectory(syncDir, key: "chrome-sync-leveldb-\(syncDir)")
            }
        }

        if braveEnabled {
            let root = (homeDir as NSString).appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser")
            for syncDir in (try? chromiumSyncDirectoriesOffMain(browserRoot: root)) ?? [] {
                recordDirectory(syncDir, key: "brave-sync-leveldb-\(syncDir)")
            }
        }

        return snapshot
    }

    nonisolated static func readingListSnapshotRequiresSync(
        current: [String: Date],
        lastSynced: [String: Date],
        force: Bool
    ) -> Bool {
        force || current != lastSynced
    }

    func filterAlreadyPersistedSources(_ discovered: [StudioArticle]) async -> [StudioArticle] {
        do {
            return try await storage.newSourceCandidates(from: discovered)
        } catch {
            logger.warning("Failed to prefilter discovered sources: \(error.localizedDescription)")
            return discovered
        }
    }

    nonisolated static func persistReadingListAutoSync(
        browserResult: BrowserReadingListScanResult,
        existingArticles: [StudioArticle],
        storage: StorageService
    ) async -> ReadingListAutoSyncPersistenceResult {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        var seenURLs = Set<String>()
        let scannedSources = filterBrowserReadingListPluginSources(browserResult.articles.filter {
            seenURLs.insert(SourceDiscovery.normalizedURL($0.url)).inserted
        })

        let promotedUpdates = paperPromotionUpdates(from: scannedSources, existingArticles: existingArticles)
        var promotedIDs = Set<String>()
        for update in promotedUpdates {
            do {
                try await storage.saveSource(update.article)
                promotedIDs.insert(update.article.id)
            } catch {
                logger.warning("Failed to promote discovered paper \(update.article.url): \(error.localizedDescription)")
            }
        }

        var candidates: [StudioArticle]
        do {
            candidates = try await storage.newSourceCandidates(from: scannedSources)
        } catch {
            logger.warning("Failed to prefilter discovered sources: \(error.localizedDescription)")
            candidates = scannedSources
        }

        // The backlog Setup chose to leave behind stays behind: a page saved
        // before the cutoff is never added, however often the list is read.
        candidates = SourceDiscovery.ReadingListImportWindow.admitting(
            candidates,
            cutoff: SourceDiscovery.ReadingListImportWindow.storedCutoff,
            savedAt: \.dateAdded
        )

        guard !candidates.isEmpty else {
            return ReadingListAutoSyncPersistenceResult(
                changedIDs: promotedIDs,
                promotedIDs: promotedIDs,
                scannedSources: scannedSources,
                candidateSources: [],
                insertedSources: [],
                warnings: browserResult.warnings
            )
        }

        await classifyDiscoveredSourceTypesBeforePersistence(&candidates)
        await enrichYouTubeMetadataBeforePersistence(&candidates)

        for i in candidates.indices where candidates[i].sourceType == .paper && candidates[i].doi == nil {
            candidates[i].doi = PaperService.extractDOI(from: candidates[i].url)
        }

        // A browser's read timestamp seeds a newly imported source. Once the
        // source exists, ForeverLM owns its durable read state: Safari exposes
        // no supported API for mirroring changes back, and refreshing from its
        // plist would undo an explicit in-app "Mark Unread" choice.
        var insertedSources: [StudioArticle] = []
        var insertedIDs = Set<String>()

        for i in candidates.indices {
            do {
                let inserted = try await storage.insertSourceIfNew(&candidates[i])
                guard inserted else { continue }
                insertedIDs.insert(candidates[i].id)
                insertedSources.append(candidates[i])
                if candidates[i].sourceType == .book,
                   let groupName = candidates[i].parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !groupName.isEmpty {
                    try? await storage.saveBookMetadata(
                        groupName: groupName,
                        title: candidates[i].title,
                        author: candidates[i].author,
                        coverPath: nil
                    )
                }
            } catch {
                logger.warning("Failed to persist discovered source \(candidates[i].url): \(error.localizedDescription)")
            }
        }

        return ReadingListAutoSyncPersistenceResult(
            changedIDs: insertedIDs.union(promotedIDs),
            promotedIDs: promotedIDs,
            scannedSources: scannedSources,
            candidateSources: candidates,
            insertedSources: insertedSources,
            warnings: browserResult.warnings
        )
    }

    func promoteExistingPaperSourcesFromDiscovered(_ discovered: [StudioArticle]) async -> Set<String> {
        var promotedIds = Set<String>()
        let existingArticles = articles
        let updates = await Self.detachedPaperPromotionUpdates(
            from: discovered,
            existingArticles: existingArticles
        )

        for update in updates {
            let latestIndex: Int
            if articles.indices.contains(update.index),
               articles[update.index].id == update.article.id {
                latestIndex = update.index
            } else if let index = articles.firstIndex(where: { $0.id == update.article.id }) {
                latestIndex = index
            } else {
                continue
            }

            // The detached scan used a snapshot. Merge only the promotion fields
            // into the latest main-actor value so a concurrent metadata refresh
            // cannot be overwritten by that older snapshot.
            var updated = articles[latestIndex]
            guard [.paper, .article, .manual, .unclassified].contains(updated.sourceType) else {
                continue
            }
            updated.sourceType = .paper
            updated.prepareForPaperMetadataExtraction()
            if updated.doi == nil {
                updated.doi = update.article.doi
            }
            if updated.artworkURL == nil {
                updated.artworkURL = update.article.artworkURL
            }

            if await persistSource(updated, context: "Promote discovered paper", showErrorToast: false) {
                if articles.indices.contains(latestIndex), articles[latestIndex].id == updated.id {
                    articles[latestIndex] = updated
                } else if let idx = articles.firstIndex(where: { $0.id == updated.id }) {
                    articles[idx] = updated
                }
                promotedIds.insert(updated.id)
            }
        }

        return promotedIds
    }

    /// Paper refresh compares every stored source identity. Keep the full scan
    /// off the main actor: local-path normalization is intentionally lexical,
    /// but an O(library) identity pass still does not belong on the UI thread.
    nonisolated static func detachedPaperPromotionUpdates(
        from discovered: [StudioArticle],
        existingArticles: [StudioArticle]
    ) async -> [(index: Int, article: StudioArticle)] {
        await Task.detached(priority: .userInitiated) {
            Self.paperPromotionUpdates(from: discovered, existingArticles: existingArticles)
        }.value
    }

    nonisolated static func paperPromotionUpdates(
        from discovered: [StudioArticle],
        existingArticles: [StudioArticle]
    ) -> [(index: Int, article: StudioArticle)] {
        let identityIndex = sourceIdentityIndex(from: existingArticles)
        var updates: [(index: Int, article: StudioArticle)] = []
        var promotedIDs = Set<String>()

        for candidate in discovered where candidate.sourceType == .paper {
            let targetKey = sourceURLIdentityKey(candidate.url)
            guard let idx = identityIndex[targetKey],
                  existingArticles.indices.contains(idx),
                  [.article, .manual, .unclassified].contains(existingArticles[idx].sourceType) else {
                continue
            }
            // An article whose own URL already reads as a paper's was typed on
            // more than the URL: the source-type model read the page and called
            // it commentary (a Nature Neuroscience News & Views piece shares the
            // journal's article URL shape), or the learner filed it. The
            // candidate is typed by that same URL, so it brings nothing new, and
            // promoting it undid the reclassification on every discovery pass.
            if existingArticles[idx].sourceType == .article,
               looksLikeScholarlyPaper(url: existingArticles[idx].url) {
                continue
            }

            var updated = existingArticles[idx]
            guard promotedIDs.insert(updated.id).inserted else { continue }
            updated.sourceType = .paper
            updated.prepareForPaperMetadataExtraction()
            if updated.doi == nil {
                updated.doi = PaperService.extractDOI(from: updated.url)
                    ?? PaperService.extractDOI(from: candidate.url)
            }
            if updated.artworkURL == nil {
                updated.artworkURL = candidate.artworkURL
            }
            updates.append((idx, updated))
        }

        return updates
    }

    func enrichYouTubeMetadataBeforePersistence(_ discovered: inout [StudioArticle]) async {
        await Self.enrichYouTubeMetadataBeforePersistence(&discovered)
    }

    nonisolated static func enrichYouTubeMetadataBeforePersistence(_ discovered: inout [StudioArticle]) async {
        var metadataByVideoId: [String: YouTubeTranscriptService.VideoMetadata?] = [:]

        for i in discovered.indices where YouTubeTranscriptService.isYouTubeURL(discovered[i].url) {
            discovered[i].sourceType = .video
            if discovered[i].artworkURL == nil {
                discovered[i].artworkURL = discovered[i].youtubeThumbnailURL
            }

            guard let videoId = YouTubeTranscriptService.extractVideoId(from: discovered[i].url) else {
                continue
            }

            let metadata: YouTubeTranscriptService.VideoMetadata?
            if let cached = metadataByVideoId[videoId] {
                metadata = cached
            } else {
                metadata = await YouTubeTranscriptService.shared.fetchVideoMetadata(videoId: videoId)
                metadataByVideoId[videoId] = metadata
            }

            if let metadata {
                StudioYouTubeMetadataApplicator.apply(metadata, to: &discovered[i])
            }
        }
    }

    nonisolated static func applyYouTubeMetadata(_ metadata: YouTubeTranscriptService.VideoMetadata, to article: inout StudioArticle) {
        StudioYouTubeMetadataApplicator.apply(metadata, to: &article)
    }

    func refreshYouTubeMetadata(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard YouTubeTranscriptService.isYouTubeURL(articles[idx].url),
              let videoId = YouTubeTranscriptService.extractVideoId(from: articles[idx].url),
              let metadata = await YouTubeTranscriptService.shared.fetchVideoMetadata(videoId: videoId),
              let latestIndex = articles.firstIndex(where: { $0.id == articleId }) else {
            return
        }

        var article = articles[latestIndex]
        var didUpdate = false
        if Self.titleLooksBad(article.title, domain: article.domain, url: article.url) {
            article.title = metadata.title
            didUpdate = true
        }
        let host = URL(string: article.url)?.host?.lowercased()
        if let channelName = metadata.channelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channelName.isEmpty,
           (article.domain.isEmpty || host.map { article.domain.lowercased() == $0 } == true) {
            article.domain = channelName
            didUpdate = true
        }
        if let thumbnailURL = metadata.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thumbnailURL.isEmpty,
           article.artworkURL != thumbnailURL {
            let hasRemoteArtwork = article.artworkURL?.hasPrefix("http") == true
            if !hasRemoteArtwork {
                article.artworkURL = thumbnailURL
                didUpdate = true
            }
        }

        guard didUpdate else { return }
        if await persistSource(article, context: "Save YouTube metadata", showErrorToast: false) {
            articles[latestIndex] = article
        }
    }

    func updateExistingYouTubeMetadataFromDiscovered(_ discovered: [StudioArticle]) async -> Int {
        var updatedCount = 0
        var seen = Set<String>()
        // Collect persisted updates and apply them to the published `articles`
        // in one synchronous pass at the end — per-item mutations between the
        // persist awaits each re-render (and can re-sort) the sidebar.
        var updatedByID: [String: StudioArticle] = [:]
        let candidates = discovered.filter { YouTubeTranscriptService.isYouTubeURL($0.url) }

        for candidate in candidates {
            let key = Self.sourceURLIdentityKey(candidate.url)
            guard seen.insert(key).inserted else { continue }
            guard let idx = articles.firstIndex(where: { Self.sourceURLIdentityKey($0.url) == key }) else { continue }

            var article = articles[idx]
            var didUpdate = false
            if Self.titleLooksBad(article.title, domain: article.domain, url: article.url),
               !candidate.title.isEmpty,
               article.title != candidate.title {
                article.title = candidate.title
                didUpdate = true
            }

            let host = URL(string: article.url)?.host?.lowercased()
            if !candidate.domain.isEmpty,
               host.map({ candidate.domain.lowercased() != $0 }) ?? true,
               (article.domain.isEmpty || host.map { article.domain.lowercased() == $0 } == true) {
                article.domain = candidate.domain
                didUpdate = true
            }

            if let artworkURL = candidate.artworkURL,
               !artworkURL.isEmpty,
               article.artworkURL != artworkURL {
                let hasRemoteArtwork = article.artworkURL?.hasPrefix("http") == true
                if !hasRemoteArtwork {
                    article.artworkURL = artworkURL
                    didUpdate = true
                }
            }

            guard didUpdate else { continue }
            if await persistSource(article, context: "Save YouTube metadata", showErrorToast: false) {
                updatedByID[article.id] = article
                updatedCount += 1
            }
        }

        if !updatedByID.isEmpty {
            for i in articles.indices {
                if let updated = updatedByID[articles[i].id] {
                    articles[i] = updated
                }
            }
        }

        return updatedCount
    }

    func showPaperSyncSummaryIfNeeded(newPaperIds: Set<String>) {
        guard !newPaperIds.isEmpty else { return }
        let missingPDFCount = articles.filter { article in
            newPaperIds.contains(article.id)
            && article.sourceType == .paper
            && article.resolvedPDFPath == nil
        }.count

        let foundText = "Found \(newPaperIds.count) new paper\(newPaperIds.count == 1 ? "" : "s")"
        if missingPDFCount > 0 {
            showToast("\(foundText). \(missingPDFCount) need PDF attention.")
        } else {
            showToast("\(foundText). PDFs are ready.")
        }
    }

    /// `pageCount` is the document's length, supplied by the PDF reader so the
    /// page index can be turned into a depth. It is optional only because the
    /// resume position itself is useful without it.
    func updateReadingPosition(for sourceID: String, page: Int, pageCount: Int? = nil) {
        guard page >= 0 else { return }
        // The Reader's Levels panel follows the page (docs/sensemaking-design.md).
        ReaderLevelsPositionFeed.shared.note(.page(page), for: sourceID)
        if let pageCount, let depth = SourceProgressDepth.fraction(pageIndex: page, pageCount: pageCount) {
            noteReaderDepth(sourceID, fraction: depth)
        }
        guard readingProgressStore.page(for: sourceID) != page else { return }
        readingProgressStore.setPage(page, for: sourceID)

        scheduleReadingProgressWrite(key: "page:\(sourceID)") { storage in
            try await storage.updateSourceReadingPosition(sourceID: sourceID, page: page)
        } describeFailure: {
            "reading position for \(sourceID)"
        }
    }

    func updateReadingLocator(for sourceID: String, locator: String) {
        guard !locator.isEmpty else { return }
        if let depth = SourceProgressDepth.fraction(locator: locator) {
            // How far down a web page or EPUB chapter, for the Levels panel.
            ReaderLevelsPositionFeed.shared.note(.fraction(depth), for: sourceID)
            noteReaderDepth(sourceID, fraction: depth, kind: readerActivityKind(for: sourceID))
        }
        guard readingProgressStore.locator(for: sourceID) != locator else { return }
        readingProgressStore.setLocator(locator, for: sourceID)

        scheduleReadingProgressWrite(key: "locator:\(sourceID)") { storage in
            try await storage.updateSourceReadingLocator(sourceID: sourceID, locator: locator)
        } describeFailure: {
            "reading locator for \(sourceID)"
        }
    }

    // MARK: - Mark as Watched / Mark as Not Watched

    /// Whether a video reads as watched: played to the end
    /// (`isEssentiallyWatched`) or carrying a read stamp, which a finished
    /// Schedule item or Log as Listened leaves. Either one is what makes its
    /// row say Watched or draw a read mark, and a course lecture count as done.
    func videoReadsAsWatched(_ article: StudioArticle) -> Bool {
        guard article.offersWatchedMarks else { return false }
        return article.isRead || readingProgressStore.videoWatchProgress(
            for: article.id,
            fallbackLocator: article.readingPositionLocator
        )?.isEssentiallyWatched == true
    }

    /// Whether Mark as Watched can finish this video: not watched yet, and its
    /// length known, which the player reports the first time it plays.
    func videoCanBeMarkedWatched(_ article: StudioArticle) -> Bool {
        guard article.offersWatchedMarks, !videoReadsAsWatched(article) else { return false }
        return readingProgressStore.videoWatchProgress(
            for: article.id,
            fallbackLocator: article.readingPositionLocator
        )?.markedWatched() != nil
    }

    /// Mark as Watched and Mark as Not Watched, from `VideoWatchedMenuItems`
    /// (product owner, 2026-09-27: a watched video "should have a 'mark as not
    /// watched' flag"). The storage write is the synced one
    /// (`KnowledgeStore.setVideoWatched`); this publishes what it stored to the
    /// progress store, the source list and an open reader, so the row, the
    /// Reader and a course's completion mark all change at once.
    func setVideosWatched(_ sourceIDs: [String], watched: Bool) async {
        let state = watched ? "watched" : "not watched"
        var marked = 0
        var finished: [String] = []
        for sourceID in sourceIDs {
            do {
                let mark = try await storage.setVideoWatched(sourceID: sourceID, watched: watched)
                guard mark.changed else { continue }
                marked += 1
                if watched { finished.append(sourceID) }
                if let locator = mark.locator {
                    readingProgressStore.setLocator(locator, for: sourceID)
                    // An open reader measures new watching from here: after
                    // Not Watched, playing it again is progress again.
                    if readerOpenDepthBaselines[sourceID] != nil {
                        readerOpenDepthBaselines[sourceID] = SourceProgressDepth.fraction(locator: locator) ?? 0
                    }
                }
                if let index = articles.firstIndex(where: { $0.id == sourceID }) {
                    var updated = articles[index]
                    updated.readingPositionLocator = mark.locator
                    updated.readAt = mark.readAt
                    if updated != articles[index] {
                        articles[index] = updated
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Failed to mark \(sourceID) \(state): \(error.localizedDescription)")
            }
        }
        guard marked > 0 else { return }
        // Marked watched: a deliberate finish, whose ideas are extracted and
        // cards drafted in the background.
        sourcesWereFinished(finished)
        showToast(marked == 1 ? "Marked as \(state)" : "Marked \(marked) videos as \(state)")
    }

    /// The activity kind a position update should be filed under. A video's
    /// playhead is watching, not reading; everything else the position funnels
    /// see is read in a reader.
    private func readerActivityKind(for sourceID: String) -> SourceActivityKind {
        guard let article = articles.first(where: { $0.id == sourceID }) else { return .reading }
        return automaticActivityKind(for: article)
    }

    /// Schedule a debounced, latest-wins reading-progress write. Rapid scroll/page
    /// callbacks for the same key cancel the prior pending write, so a stale
    /// position can never land out of order after a newer one. The persist itself
    /// runs off the main actor through the storage API (`StorageService` is an
    /// actor), keeping CloudKit sync metadata consistent without beachballs.
    private func scheduleReadingProgressWrite(
        key: String,
        write: @escaping @Sendable (StorageService) async throws -> Void,
        describeFailure: @escaping @Sendable () -> String
    ) {
        let coordinator = ReadingProgressWriteCoordinator.shared
        coordinator.tasks[key]?.cancel()

        let storage = self.storage
        let logger = self.logger
        coordinator.tasks[key] = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return // Cancelled by a newer write for this key.
            }
            guard !Task.isCancelled else { return }
            do {
                try await write(storage)
            } catch {
                logger.warning("Failed to save \(describeFailure()): \(error.localizedDescription)")
            }
        }
    }

    func discoverNewSourcesOffMain(onlyTab: StudioSidebarTab? = nil, showProgress: Bool = true) async -> [StudioArticle] {
        // Gather main-actor UI/preferences state up front, then run blocking
        // browser file scans on a detached utility task.
        func setStep(_ step: String) { if showProgress { loadingStep = step } }

        var fileDiscovered: [StudioArticle] = []
        var browserWarnings: [String]?
        var podcastWarnings: [String]?

        let tab = Self.discoveryScope(for: onlyTab)

        // Browser reading lists → articles (and papers detected from URLs)
        if Self.discoveryScanIncludesBrowserReadingLists(tab) {
            let safariEnabled = DefaultsEscapeHatch.bool(forKey: "readingListSafari", default: true)
            let chromeEnabled = DefaultsEscapeHatch.bool(forKey: "readingListChrome", default: true)
            let braveEnabled = DefaultsEscapeHatch.bool(forKey: "readingListBrave", default: true)
            let homeDir = realHomeDirectory

            setStep("Syncing browser Reading Lists…")
            // Resolve the Safari security-scoped bookmark off the main actor — the
            // resolution does blocking filesystem / TCC work that would beachball.
            // The scope is held open for the duration of the detached scan and
            // released before the task returns, mirroring the auto-sync path.
            let browserResult = await Task.detached(priority: .utility) { () -> BrowserReadingListScanResult in
                let safariFolderURL: URL? = safariEnabled
                    ? BookmarkAccessManager.shared.resolveBookmark(for: .safariBookmarks)
                    : nil
                defer {
                    if safariFolderURL != nil {
                        BookmarkAccessManager.shared.stopAccessing(for: .safariBookmarks)
                    }
                }
                let workerRequest = BrowserReadingListWorkerRequest(
                    homeDir: homeDir,
                    safariEnabled: safariEnabled,
                    chromeEnabled: chromeEnabled,
                    braveEnabled: braveEnabled,
                    safariFolderPath: safariFolderURL?.path
                )
                return await Self.discoverBrowserReadingListsOutsideMainProcess(request: workerRequest)
            }.value
            fileDiscovered += Self.filterBrowserReadingListPluginSources(browserResult.articles)
            browserWarnings = browserResult.warnings
        }


        if tab == nil || tab == .podcasts {
            await Task.yield()
            setStep("Discovering Apple Podcasts…")
            let podcastResult = await discoverApplePodcastsTTML()
            fileDiscovered += podcastResult.articles
            podcastWarnings = podcastResult.warnings
        }

        updateDiscoveryWarnings(browser: browserWarnings, podcast: podcastWarnings)
        let discovered = fileDiscovered


        var seenURLs = Set<String>()
        return discovered.filter { seenURLs.insert(SourceDiscovery.normalizedURL($0.url)).inserted }
    }

    nonisolated static func discoveryScope(for tab: StudioSidebarTab?) -> StudioSidebarTab? {
        tab
    }

    nonisolated static func discoveryScanIncludesBrowserReadingLists(_ tab: StudioSidebarTab?) -> Bool {
        guard let tab else { return true }
        switch tab {
        case .articles, .papers:
            return true
        default:
            return false
        }
    }

    nonisolated static func discoveryScopeIncludesBrowserReadingLists(_ tab: StudioSidebarTab?) -> Bool {
        discoveryScanIncludesBrowserReadingLists(discoveryScope(for: tab))
    }

    /// Publish only the discovery domains that were actually scanned. Passing
    /// `nil` means that integration was not checked, so its last known access
    /// result remains authoritative until its own next scan.
    func updateDiscoveryWarnings(
        browser browserWarnings: [String]? = nil,
        podcast podcastWarnings: [String]? = nil
    ) {
        if let browserWarnings {
            let presentedWarnings = Self.browserDiscoveryWarningsForPresentation(browserWarnings)
            browserDiscoveryWarnings = presentedWarnings
            let accessIsBlocked = presentedWarnings.contains { warning in
                warning.contains("access is blocked") || warning.contains("access required")
            }
            needsBrowserAccess = accessIsBlocked
        }
        if let podcastWarnings {
            podcastDiscoveryWarnings = podcastWarnings
            let accessIsBlocked = podcastWarnings.contains { warning in
                warning.contains("access is blocked") || warning.contains("access required")
            }
            needsPodcastAccess = accessIsBlocked
            if !accessIsBlocked {
                podcastAccessPromptDismissed = false
                UserDefaults.standard.removeObject(forKey: Self.podcastAccessPromptDismissedKey)
            }
        }
    }

    /// Keep permission failures visible and actionable without exposing a raw
    /// file-system error as the primary UI. The complete warning is still logged
    /// by `reportReadingListImport` for diagnostics.
    nonisolated static func browserDiscoveryWarningsForPresentation(_ warnings: [String]) -> [String] {
        warnings.map { warning in
            for browser in ["Safari", "Chrome", "Brave"]
                where warning.hasPrefix("\(browser) Reading List access is blocked.") {
                return "\(browser) Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
            }
            return warning
        }
    }

    func dismissBrowserAccessPrompt() {
        browserAccessPromptDismissed = true
        UserDefaults.standard.set(true, forKey: Self.browserAccessPromptDismissedKey)
    }

    func dismissPodcastAccessPrompt() {
        podcastAccessPromptDismissed = true
        UserDefaults.standard.set(true, forKey: Self.podcastAccessPromptDismissedKey)
    }

    func discoveryWarnings(for tab: StudioSidebarTab?) -> [String] {
        let scope = Self.discoveryScope(for: tab)
        if scope == nil {
            return discoveryWarnings
        }
        if Self.discoveryScanIncludesBrowserReadingLists(scope) {
            return browserDiscoveryWarnings
        }
        if scope == .podcasts {
            return podcastDiscoveryWarnings
        }
        return []
    }

    nonisolated static func isBrowserReadingListSource(_ article: StudioArticle) -> Bool {
        guard let origin = article.discoveryOrigin else { return false }
        return origin == .safari || origin == .chrome || origin == .brave
    }

    nonisolated static func sourceTypeLabel(_ type: StudioSourceType) -> String {
        switch type {
        case .article, .unclassified: return "articles"
        case .paper: return "papers"
        case .podcast: return "podcasts"
        case .book: return "books"
        case .course: return "courses"
        case .meeting: return "meetings"
        case .video: return "YouTube"
        case .xPost: return "X posts"
        case .manual: return "manual sources"
        }
    }

    nonisolated static func readingListOriginBreakdown(_ sources: [StudioArticle]) -> String {
        let safari = sources.filter { $0.discoveryOrigin == .safari }.count
        let chrome = sources.filter { $0.discoveryOrigin == .chrome }.count
        let brave = sources.filter { $0.discoveryOrigin == .brave }.count
        let parts = [
            safari > 0 ? "Safari \(safari)" : nil,
            chrome > 0 ? "Chrome \(chrome)" : nil,
            brave > 0 ? "Brave \(brave)" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    nonisolated static func readingListOriginLabel(_ sources: [StudioArticle]) -> String {
        let originNames = [
            sources.contains { $0.discoveryOrigin == .safari } ? "Safari" : nil,
            sources.contains { $0.discoveryOrigin == .chrome } ? "Chrome" : nil,
            sources.contains { $0.discoveryOrigin == .brave } ? "Brave" : nil
        ].compactMap { $0 }

        switch originNames.count {
        case 0:
            return "browser Reading Lists"
        case 1:
            return "\(originNames[0]) Reading List"
        case 2:
            return "\(originNames[0]) and \(originNames[1]) Reading Lists"
        default:
            return "\(originNames.dropLast().joined(separator: ", ")), and \(originNames.last!) Reading Lists"
        }
    }

    nonisolated static func sourceTypeBreakdown(_ sources: [StudioArticle]) -> String {
        let orderedTypes: [StudioSourceType] = [
            .paper, .article, .unclassified, .video, .podcast, .book, .course, .meeting, .xPost, .manual
        ]
        var parts: [String] = []
        for type in orderedTypes {
            let count = sources.filter { $0.sourceType == type }.count
            guard count > 0 else { continue }
            parts.append("\(count) \(sourceTypeLabel(type))")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    nonisolated static func readingListImportReport(
        scannedSources: [StudioArticle],
        candidateSources: [StudioArticle],
        insertedSources: [StudioArticle],
        promotedCount: Int
    ) -> ReadingListImportReport {
        let scannedReadingListSources = scannedSources.filter(isBrowserReadingListSource)
        let candidateReadingListSources = candidateSources.filter(isBrowserReadingListSource)
        let insertedReadingListSources = insertedSources.filter(isBrowserReadingListSource)
        return ReadingListImportReport(
            scannedCount: scannedReadingListSources.count,
            candidateCount: candidateReadingListSources.count,
            insertedCount: insertedReadingListSources.count,
            promotedCount: promotedCount,
            scannedByOrigin: readingListOriginBreakdown(scannedReadingListSources),
            scannedOriginLabel: readingListOriginLabel(scannedReadingListSources),
            candidatesByType: sourceTypeBreakdown(candidateReadingListSources),
            insertedByType: sourceTypeBreakdown(insertedReadingListSources)
        )
    }

    func reportReadingListImport(
        trigger: String,
        scope: StudioSidebarTab?,
        warnings: [String],
        scannedSources: [StudioArticle],
        candidateSources: [StudioArticle],
        insertedSources: [StudioArticle],
        promotedCount: Int,
        showUserToast: Bool
    ) {
        guard Self.discoveryScopeIncludesBrowserReadingLists(scope) else { return }
        let report = Self.readingListImportReport(
            scannedSources: scannedSources,
            candidateSources: candidateSources,
            insertedSources: insertedSources,
            promotedCount: promotedCount
        )
        let scopeLabel = refreshScopeLabel(for: Self.discoveryScope(for: scope))
        let readingListWarnings = warnings.filter { warning in
            warning.contains("Safari") || warning.contains("Chrome") || warning.contains("Brave")
        }
        logger.info(
            "Reading List \(trigger) (\(scopeLabel)): found \(report.scannedCount) item(s) (\(report.scannedByOrigin)); \(report.candidateCount) new candidate(s) assigned as \(report.candidatesByType); inserted \(report.insertedCount) source(s) as \(report.insertedByType); promoted \(report.promotedCount) existing source(s); warnings: \(readingListWarnings.joined(separator: " | "))"
        )

        guard showUserToast else { return }
        let presentedWarnings = Self.browserDiscoveryWarningsForPresentation(readingListWarnings)
        if let warning = presentedWarnings.first {
            showToast(warning)
            return
        }
        if report.insertedCount > 0 {
            showToast("Found \(report.scannedCount) items in \(report.scannedOriginLabel); added \(report.insertedCount) new \(report.insertedCount == 1 ? "source" : "sources").")
        } else if report.promotedCount > 0 {
            showToast("Found \(report.scannedCount) items in \(report.scannedOriginLabel); updated \(report.promotedCount) already in ForeverLM.")
        }
        // Nothing changed (all already imported, or nothing found) — stay silent.
        // The scan result is still recorded in the log line above.
    }

    nonisolated static var browserReadingListWorkerArgument: String {
        "--foreverlm-browser-reading-list-worker"
    }

    nonisolated static func exitIfBrowserReadingListWorkerRequested() {
        let arguments = CommandLine.arguments
        guard let workerIndex = arguments.firstIndex(of: browserReadingListWorkerArgument) else { return }
        let requestIndex = arguments.index(after: workerIndex)
        let responseIndex = arguments.index(requestIndex, offsetBy: 1)
        guard arguments.indices.contains(requestIndex),
              arguments.indices.contains(responseIndex) else {
            fputs("Missing browser Reading List worker paths\n", stderr)
            exit(64)
        }
        _ = setpriority(PRIO_PROCESS, 0, 10)

        let requestURL = URL(fileURLWithPath: arguments[requestIndex])
        let responseURL = URL(fileURLWithPath: arguments[responseIndex])

        do {
            let requestData = try Data(contentsOf: requestURL)
            let request = try JSONDecoder().decode(BrowserReadingListWorkerRequest.self, from: requestData)
            let result = discoverBrowserReadingListsOffMain(
                homeDir: request.homeDir,
                safariEnabled: request.safariEnabled,
                chromeEnabled: request.chromeEnabled,
                braveEnabled: request.braveEnabled,
                safariFolderURL: request.safariFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
            let response = BrowserReadingListWorkerResponse(
                articles: result.articles,
                warnings: result.warnings
            )
            let responseData = try JSONEncoder().encode(response)
            try responseData.write(to: responseURL, options: .atomic)
            exit(0)
        } catch {
            fputs("Browser Reading List worker failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    nonisolated static func discoverBrowserReadingListsViaWorker(
        request: BrowserReadingListWorkerRequest
    ) -> BrowserReadingListScanResult? {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        guard let executableURL = Bundle.main.executableURL else { return nil }

        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ForeverLMBrowserRefresh-\(UUID().uuidString)", isDirectory: true)
        let requestURL = tempDir.appendingPathComponent("request.json")
        let responseURL = tempDir.appendingPathComponent("response.json")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }

            let requestData = try JSONEncoder().encode(request)
            try requestData.write(to: requestURL, options: .atomic)

            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                browserReadingListWorkerArgument,
                requestURL.path,
                responseURL.path
            ]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8) ?? ""
                logger.warning("Browser Reading List worker exited \(process.terminationStatus): \(errorText.prefix(300))")
                return nil
            }

            let responseData = try Data(contentsOf: responseURL)
            let response = try JSONDecoder().decode(BrowserReadingListWorkerResponse.self, from: responseData)
            return BrowserReadingListScanResult(
                articles: response.articles,
                warnings: response.warnings
            )
        } catch {
            logger.warning("Browser Reading List worker failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func discoverBrowserReadingListsOutsideMainProcess(
        request: BrowserReadingListWorkerRequest
    ) async -> BrowserReadingListScanResult {
        await Task.detached(priority: .utility) {
            // The worker is a separate process launched by path (not via
            // LaunchServices), so it does NOT inherit the GUI app's Full Disk
            // Access, and it cannot use the main process's security-scoped
            // bookmark (those are per-process). If it reports any blocked read,
            // retry in-process — the main app holds the FDA grant and the active
            // security scope, so it's the authoritative reader.
            if let workerResult = discoverBrowserReadingListsViaWorker(request: request),
               !workerResult.warnings.contains(where: { $0.contains("Reading List access is blocked") }) {
                return workerResult
            }

            return discoverBrowserReadingListsOffMain(
                homeDir: request.homeDir,
                safariEnabled: request.safariEnabled,
                chromeEnabled: request.chromeEnabled,
                braveEnabled: request.braveEnabled,
                safariFolderURL: request.safariFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
        }.value
    }

    nonisolated static func discoverBrowserReadingListsOffMain(
        homeDir: String,
        safariEnabled: Bool,
        chromeEnabled: Bool,
        braveEnabled: Bool,
        safariFolderURL: URL?
    ) -> BrowserReadingListScanResult {
        var discovered: [StudioArticle] = []
        var warnings: [String] = []

        if safariEnabled {
            let result = discoverSafariReadingListOffMain(homeDir: homeDir, safariFolderURL: safariFolderURL)
            discovered += result.articles
            warnings += result.warnings
        }

        if chromeEnabled {
            let result = discoverChromeReadingListOffMain(browser: "Google/Chrome", homeDir: homeDir)
            discovered += result.articles
            warnings += result.warnings
        }

        if braveEnabled {
            let result = discoverBraveReadingListOffMain(homeDir: homeDir)
            discovered += result.articles
            warnings += result.warnings
        }

        return BrowserReadingListScanResult(articles: excludingLinkedPages(discovered), warnings: warnings)
    }

    /// Reading-list entries that are pages ForeverLM links rather than scrapes
    /// — a Codex site, a Claude artifact, a Google Doc, a ForeverLM site — are
    /// left out of discovery. A discovered row is inserted as an article with
    /// nobody asked, and a Codex site read that way is its sign-in page; linking
    /// a page is a deliberate act, from Sites' Link a Site… or `link_page`.
    /// Applied where the three browsers' lists join, so the worker and the
    /// in-process fallback agree. Addresses that are never sources at all
    /// (`sourceRefusal`, today Convoke's endpoint) are left out the same way,
    /// and so is a Gemini Notebook, which is imported as a Notebook only when
    /// the learner pastes it.
    nonisolated static func excludingLinkedPages(_ articles: [StudioArticle]) -> [StudioArticle] {
        articles.filter {
            linkedPageKind(forSourceURL: $0.url) == nil
                && sourceRefusal(forSourceURL: $0.url) == nil
                && !GeminiNotebookService.isNotebookURL($0.url)
        }
    }

    nonisolated static func discoverSafariReadingListOffMain(
        homeDir: String,
        safariFolderURL: URL?
    ) -> (articles: [StudioArticle], warnings: [String]) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        let plistPath = (homeDir as NSString).appendingPathComponent("Library/Safari/Bookmarks.plist")

        struct SafariReadResult {
            let articles: [StudioArticle]
            let label: String
            let byteCount: Int
        }

        var readFailures: [NSError] = []
        var emptyReads: [SafariReadResult] = []

        func read(_ url: URL, label: String) -> SafariReadResult? {
            // `isReadableFile` reports a TCC denial without causing the system
            // app-data modal. Only the explicit folder-picker action may ask.
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                let error = CocoaError(.fileReadNoPermission) as NSError
                readFailures.append(error)
                logger.warning("Safari Bookmarks.plist isn't readable\(label)")
                return nil
            }
            do {
                let data = try Data(contentsOf: url)
                let articles = safariReadingListArticlesOffMain(from: data)
                logger.info("Discovered \(articles.count) Safari Reading List items\(label); plist bytes=\(data.count)")
                let result = SafariReadResult(articles: articles, label: label, byteCount: data.count)
                if articles.isEmpty {
                    emptyReads.append(result)
                }
                return result
            } catch let error as NSError {
                readFailures.append(error)
                logger.warning("Safari Bookmarks.plist read failed\(label): \(error.localizedDescription)")
                return nil
            }
        }

        if let safariFolderURL,
           let result = read(safariFolderURL.appendingPathComponent("Bookmarks.plist"), label: " via saved folder access"),
           !result.articles.isEmpty {
            return (result.articles, [])
        }

        if let result = read(URL(fileURLWithPath: plistPath), label: " via direct home path"),
           !result.articles.isEmpty {
            return (result.articles, [])
        }

        if let suspicious = emptyReads.first(where: { $0.byteCount > 1024 }) {
            return ([], [
                "Safari Reading List parsing returned 0 items from \(suspicious.label.isEmpty ? "Bookmarks.plist" : suspicious.label) even though the plist was \(suspicious.byteCount) bytes. Relaunch ForeverLM with Full Disk Access, then refresh."
            ])
        }

        if let permissionError = readFailures.last(where: Self.fileReadWasPermissionDenied) {
            return ([], [
                "Safari Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM. Last read error: \(permissionError.localizedDescription)"
            ])
        }
        if let readError = readFailures.last {
            return ([], [
                "Safari Reading List couldn't be read. \(readError.localizedDescription) Try refreshing."
            ])
        }
        return ([], [])
    }

    nonisolated static func fileReadWasPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(EACCES) || error.code == Int(EPERM) {
            return true
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoPermissionError {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== error {
            return fileReadWasPermissionDenied(underlying)
        }
        return false
    }

    nonisolated static func safariReadingListArticlesOffMain(from data: Data) -> [StudioArticle] {
        SourceDiscovery.parseSafariReadingList(data: data).map { entry in
            let sourceType = detectSourceType(url: entry.url)
            var article = StudioArticle(url: entry.url, title: entry.title, sourceType: sourceType, artworkURL: entry.imageURL, discoveryOrigin: .safari)
            article.domain = URL(string: entry.url)?.host ?? "Safari"
            if let dateAdded = entry.dateAdded {
                article.dateAdded = dateAdded
            }
            if entry.isRead {
                article.readAt = entry.dateLastViewed ?? Date()
            }
            return article
        }
    }

    nonisolated static func discoverChromeReadingListOffMain(
        browser: String,
        homeDir: String
    ) -> (articles: [StudioArticle], warnings: [String]) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        let fm = FileManager.default
        let browserRoot = (homeDir as NSString).appendingPathComponent(
            "Library/Application Support/\(browser)"
        )

        guard fm.fileExists(atPath: browserRoot) else {
            return ([], [])
        }

        guard fm.isReadableFile(atPath: browserRoot) else {
            let browserName = browser.components(separatedBy: "/").last ?? "Chrome"
            return ([], [
                "\(browserName) Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
            ])
        }

        var articles: [StudioArticle] = []
        let browserName = browser.components(separatedBy: "/").last ?? "Chrome"
        let origin: DiscoveryOrigin = browser.contains("Brave") ? .brave : .chrome

        let bookmarksPaths: [String]
        do {
            bookmarksPaths = try chromiumBookmarksPathsOffMain(browserRoot: browserRoot)
        } catch let error as NSError {
            if fileReadWasPermissionDenied(error) {
                return ([], [
                    "\(browserName) Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
                ])
            }
            return ([], [
                "\(browserName) Reading List couldn't be inspected. \(error.localizedDescription) Try refreshing."
            ])
        }

        var bookmarkReadFailures: [NSError] = []
        for path in bookmarksPaths {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch let error as NSError {
                bookmarkReadFailures.append(error)
                continue
            }
            let entries = SourceDiscovery.parseChromeBookmarks(data: data)
            for entry in entries {
                let sourceType = detectSourceType(url: entry.url)
                var article = StudioArticle(url: entry.url, title: entry.title, sourceType: sourceType, discoveryOrigin: origin)
                article.domain = URL(string: entry.url)?.host ?? browserName
                if let dateAdded = entry.dateAdded {
                    article.dateAdded = dateAdded
                }
                articles.append(article)
            }
        }

        let syncDirs = (try? chromiumSyncDirectoriesOffMain(browserRoot: browserRoot)) ?? []
        for syncDir in syncDirs {
            let syncEntries = SourceDiscovery.parseChromiumSyncReadingList(syncDir: syncDir)
            for entry in syncEntries {
                let sourceType = detectSourceType(url: entry.url)
                var article = StudioArticle(url: entry.url, title: entry.title, sourceType: sourceType, discoveryOrigin: origin)
                article.domain = URL(string: entry.url)?.host ?? browserName
                if let dateAdded = entry.dateAdded {
                    article.dateAdded = dateAdded
                }
                if entry.isRead {
                    article.readAt = entry.dateLastViewed ?? Date()
                }
                articles.append(article)
            }
        }

        if bookmarkReadFailures.contains(where: fileReadWasPermissionDenied) {
            return ([], [
                "\(browserName) Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
            ])
        }
        if let readError = bookmarkReadFailures.last {
            return ([], [
                "\(browserName) Reading List couldn't be read. \(readError.localizedDescription) Try refreshing."
            ])
        }

        let deduped = deduplicateDiscoveredByURL(articles)
        if !deduped.isEmpty {
            logger.info("Discovered \(deduped.count) \(browserName) Reading List items from \(bookmarksPaths.count) Bookmarks file(s) and \(syncDirs.count) profile store(s)")
        }
        return (deduped, [])
    }

    nonisolated static func discoverBraveReadingListOffMain(
        homeDir: String
    ) -> (articles: [StudioArticle], warnings: [String]) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        let fm = FileManager.default
        let browserRoot = (homeDir as NSString).appendingPathComponent(
            "Library/Application Support/BraveSoftware/Brave-Browser"
        )
        let braveParent = (homeDir as NSString).appendingPathComponent(
            "Library/Application Support/BraveSoftware"
        )
        let syncDirs = (try? chromiumSyncDirectoriesOffMain(browserRoot: browserRoot)) ?? []

        guard !syncDirs.isEmpty else {
            let probeRoot = fm.fileExists(atPath: browserRoot) ? browserRoot : braveParent
            guard fm.fileExists(atPath: probeRoot) else { return ([], []) }
            guard fm.isReadableFile(atPath: probeRoot) else {
                return ([], [
                    "Brave Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
                ])
            }
            do {
                _ = try fm.contentsOfDirectory(atPath: probeRoot)
            } catch let error as NSError {
                if fileReadWasPermissionDenied(error) {
                    return ([], [
                        "Brave Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
                    ])
                }
                return ([], [
                    "Brave Reading List couldn't be inspected. \(error.localizedDescription) Try refreshing."
                ])
            }
            return ([], [])
        }

        for syncDir in syncDirs {
            guard fm.isReadableFile(atPath: syncDir) else {
                return ([], [
                    "Brave Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
                ])
            }

            do {
                _ = try fm.contentsOfDirectory(atPath: syncDir)
            } catch let error as NSError {
                if fileReadWasPermissionDenied(error) {
                    return ([], [
                        "Brave Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
                    ])
                }
                return ([], [
                    "Brave Reading List couldn't be read. \(error.localizedDescription) Try refreshing."
                ])
            }
        }

        let articles = syncDirs.flatMap(SourceDiscovery.parseChromiumSyncReadingList(syncDir:)).map { entry in
            let sourceType = detectSourceType(url: entry.url)
            var article = StudioArticle(url: entry.url, title: entry.title, sourceType: sourceType, discoveryOrigin: .brave)
            article.domain = URL(string: entry.url)?.host ?? "Brave"
            if let dateAdded = entry.dateAdded {
                article.dateAdded = dateAdded
            }
            if entry.isRead {
                article.readAt = entry.dateLastViewed ?? Date()
            }
            return article
        }

        let deduped = deduplicateDiscoveredByURL(articles)
        if !deduped.isEmpty {
            logger.info("Discovered \(deduped.count) Brave Reading List items from \(syncDirs.count) profile store(s)")
        }
        return (deduped, [])
    }

    nonisolated static func deduplicateDiscoveredByURL(_ articles: [StudioArticle]) -> [StudioArticle] {
        var deduped: [StudioArticle] = []
        var seenURLs = Set<String>()
        for article in articles {
            if seenURLs.insert(SourceDiscovery.normalizedURL(article.url)).inserted {
                deduped.append(article)
            }
        }
        return deduped
    }

    nonisolated static func chromiumBookmarksPathsOffMain(browserRoot: String) throws -> [String] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: browserRoot)

        var paths: [String] = []
        let defaultPath = (browserRoot as NSString).appendingPathComponent("Default/Bookmarks")
        if fm.fileExists(atPath: defaultPath) {
            paths.append(defaultPath)
        }

        for entry in entries.sorted() where entry != "Default" {
            let profileBookmarksPath = (browserRoot as NSString).appendingPathComponent("\(entry)/Bookmarks")
            guard fm.fileExists(atPath: profileBookmarksPath) else { continue }
            paths.append(profileBookmarksPath)
        }

        return paths
    }

    /// Each profile's reading-list store under a Chromium browser root,
    /// `Default` first. Chrome signs one Google account in per profile, so a
    /// second account's list is only in `Profile 1`, `Profile 2`… The guest
    /// profile is whoever borrowed the browser and the system profile is the
    /// profile picker's, so neither is read.
    nonisolated static func chromiumSyncDirectoriesOffMain(browserRoot: String) throws -> [String] {
        let fm = FileManager.default
        let skipped: Set<String> = ["Default", "Guest Profile", "System Profile"]
        let profiles = ["Default"] + (try fm.contentsOfDirectory(atPath: browserRoot)).sorted().filter { !skipped.contains($0) }
        return profiles
            .map { (browserRoot as NSString).appendingPathComponent("\($0)/Sync Data/LevelDB") }
            .filter { fm.fileExists(atPath: $0) }
    }

    /// Discover Apple Podcasts episodes from the SQLite database.
    /// Queries played episodes directly and returns metadata-only placeholders.
    /// Episodes listened to on iPhone sync their metadata to the Mac DB via iCloud,
    /// even though TTML transcript files are only cached when viewed on that device.
    /// Transcript hydration starts only after these placeholders are persisted and visible.
    /// Returns articles and any warnings (for background-thread safety).
    func discoverApplePodcastsTTML() async -> (articles: [StudioArticle], warnings: [String]) {
        let homeDir = realHomeDirectory
        let snapshot = await Task.detached(priority: .utility) {
            Self.podcastDiscoveryFileSnapshotOffMain(homeDir: homeDir)
        }.value
        return Self.podcastDiscoveryResult(from: snapshot)
    }

    /// Import every episode Apple Podcasts holds for `showName`, not only the
    /// listened ones discovery picks up. Episodes already in the library are
    /// left alone; the new rows queue for transcripts the way discovered
    /// episodes do. Returns how many episodes were added, or nil when the
    /// Podcasts library could not be read.
    func importAllEpisodes(ofShow showName: String) async -> Int? {
        let homeDir = realHomeDirectory
        let storage = self.storage
        let previousArticles = self.articles
        let discovered = await Task.detached(priority: .utility) {
            SourceDiscovery.discoverAllEpisodes(
                dbPath: Self.applePodcastsDatabasePath(homeDir: homeDir),
                showName: showName
            )
        }.value
        switch discovered.status {
        case .ok, .noEpisodesFound:
            break
        case .permissionDenied, .openFailed, .schemaChanged, .appNotInstalled, .unsupportedPlatform:
            return nil
        }
        let articles = Self.podcastArticles(from: discovered.episodes)
        let persistence = await Self.persistPodcastAutoSync(scannedSources: articles, storage: storage)
        await alignUnplayedPodcastDates(with: discovered.episodes)
        guard !persistence.insertedIDs.isEmpty else { return 0 }

        let reloaded: [StudioArticle]
        do {
            reloaded = try await storage.loadLibrarySources(teamID: activeTeamID).sources
        } catch {
            logger.error("Failed to reload sources after importing \(showName): \(error.localizedDescription)")
            return persistence.insertedIDs.count
        }
        let merged = await Task.detached(priority: .userInitiated) {
            Self.preservingLoadedContent(in: reloaded, preservingFrom: previousArticles)
        }.value
        self.articles = merged
        syncCloudKitInBackground()
        Task(priority: .utility) { [weak self] in
            await self?.processPendingPodcastTranscripts()
        }
        return persistence.insertedIDs.count
    }

    /// Convert the off-main SQLite result into lightweight source rows. Keeping
    /// this pure lets launch/FSEvents reconciliation avoid the main actor from
    /// database open through candidate persistence.
    nonisolated static func podcastDiscoveryResult(
        from snapshot: PodcastDiscoveryFileSnapshot
    ) -> (articles: [StudioArticle], warnings: [String]) {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        log.info("Podcasts: DB path = \(snapshot.dbPath), exists = \(snapshot.databaseExists)")
        log.info(
            "Podcasts: discovery status = \(String(describing: snapshot.status)), episodes = \(snapshot.episodeMetadata.count)"
        )

        switch snapshot.status {
        case .ok:
            break
        case .unsupportedPlatform:
            log.debug("Apple Podcasts discovery is only available on macOS")
            return ([], [])
        case .appNotInstalled:
            log.info("Apple Podcasts is not installed (database not found)")
            return ([], [])
        case .permissionDenied:
            log.warning("Cannot read Apple Podcasts database")
            return ([], [
                "Apple Podcasts access is blocked. Enable Full Disk Access for ForeverLM in System Settings > Privacy & Security, then relaunch ForeverLM."
            ])
        case .openFailed(let details):
            log.warning("Cannot open Apple Podcasts database: \(details)")
            return ([], [
                "Apple Podcasts library couldn't be opened. \(details) Try refreshing."
            ])
        case .schemaChanged(let details):
            log.warning("Apple Podcasts database schema changed: \(details)")
            return ([], [
                "Apple Podcasts database format has changed and podcast discovery is temporarily unavailable. "
                + "Please check for an app update."
            ])
        case .noEpisodesFound:
            log.debug("No played episodes found in Apple Podcasts")
            return ([], [])
        }

        let articles = podcastArticles(from: snapshot.episodeMetadata)
        if !articles.isEmpty {
            log.info("Discovered metadata for \(articles.count) Apple Podcasts episodes")
        }
        return (articles, [])
    }

    /// Lightweight source rows for discovered episodes. Transcript retrieval,
    /// extraction, speaker identification, and formatting begin after
    /// persistence.
    nonisolated static func podcastArticles(from metadata: [PodcastEpisodeMetadata]) -> [StudioArticle] {
        var articles = metadata.compactMap { meta -> StudioArticle? in
            guard let primaryURL = SourceDiscovery.podcastEpisodeURL(for: meta) else { return nil }
            var article = StudioArticle(
                url: primaryURL,
                title: meta.episodeTitle,
                sourceType: .podcast,
                artworkURL: meta.artworkURL,
                discoveryOrigin: .applePodcasts
            )
            article.normalizedURL = URLNormalizer.normalize(primaryURL)
            article.domain = meta.podcastName
            // Played: the last listen. Never played: the publish date, so a
            // catalog imported in one go lands in episode order instead of
            // stacking at the top of the list as if it were new.
            article.dateAdded = meta.lastDatePlayed ?? meta.publishedAt ?? Date()
            article.podcastWebPageURL = meta.storeTrackId == nil ? nil : meta.webPageURL
            // A missing public track id or DB transcript identifier does not
            // make the episode unreadable. Public episodes try Apple TTML first;
            // every exact enclosure can fall back to managed transcription.
            article.state = .queued
            return article
        }
        articles.sort { $0.dateAdded > $1.dateAdded }
        return articles
    }

    nonisolated static func applePodcastsDatabasePath(homeDir: String) -> String {
        (homeDir as NSString).appendingPathComponent(
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
        )
    }

    nonisolated static func podcastDiscoveryFileSnapshotOffMain(homeDir: String) -> PodcastDiscoveryFileSnapshot {
        let fm = FileManager.default
        let dbPath = applePodcastsDatabasePath(homeDir: homeDir)
        let (listened, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath)

        // A followed show contributes every episode Apple Podcasts holds for
        // it, played or not, on every pass: that is what following means.
        var followed: [PodcastEpisodeMetadata] = []
        if status == .ok || status == .noEpisodesFound {
            for showName in followedPodcastShowNames() {
                followed.append(contentsOf: SourceDiscovery.discoverAllEpisodes(dbPath: dbPath, showName: showName).episodes)
            }
        }
        // A blocked show never reaches the library at all. Filtering after the
        // merge rather than inside either pass means there is one place where
        // an episode can be refused, and no arrangement of listened and
        // followed can slip one past it.
        let episodeMetadata = SourceDiscovery.removingBlockedShows(
            from: SourceDiscovery.mergeEpisodes(listened: listened, followed: followed),
            blockedShows: SourceDiscovery.blockedPodcastShowNames()
        )
        let mergedStatus: PodcastDiscoveryStatus = (status == .noEpisodesFound && !episodeMetadata.isEmpty) ? .ok : status

        return PodcastDiscoveryFileSnapshot(
            dbPath: dbPath,
            episodeMetadata: episodeMetadata,
            status: mergedStatus,
            databaseExists: fm.fileExists(atPath: dbPath)
        )
    }

    /// The date an episode already in the library should carry given what
    /// Apple Podcasts says about it now, or nil when it is right as it is:
    /// only an episode that was never played and whose stored date is not its
    /// publish date moves. Rows imported before publish dates were read carry
    /// the minute of their import, which is what this repairs.
    nonisolated static func alignedDateAdded(existing: StudioArticle, episode: PodcastEpisodeMetadata) -> Date? {
        guard episode.lastDatePlayed == nil, let publishedAt = episode.publishedAt else { return nil }
        guard abs(existing.dateAdded.timeIntervalSince(publishedAt)) > 60 else { return nil }
        return publishedAt
    }

    /// Re-date the library's unplayed episodes among `episodes` to their
    /// publish dates. Bounded by the discovered set (one show for a follow, the
    /// listened and followed episodes for a sync), so it never walks the whole
    /// library; a row that is already right costs nothing.
    func alignUnplayedPodcastDates(with episodes: [PodcastEpisodeMetadata]) async {
        var indexByKey: [String: Int] = [:]
        for (index, article) in articles.enumerated() where article.sourceType == .podcast {
            indexByKey[Self.sourceURLIdentityKey(article.url)] = index
        }
        var moved = 0
        for episode in episodes {
            guard let url = SourceDiscovery.podcastEpisodeURL(for: episode),
                  let index = indexByKey[Self.sourceURLIdentityKey(url)],
                  let date = Self.alignedDateAdded(existing: articles[index], episode: episode) else { continue }
            articles[index].dateAdded = date
            do {
                try await storage.saveSource(articles[index])
                moved += 1
            } catch {
                logger.warning("Could not re-date \(episode.episodeTitle): \(error.localizedDescription)")
            }
        }
        if moved > 0 {
            logger.info("Re-dated \(moved) unplayed podcast episode(s) to their publish dates")
            invalidateFilteredSidebarCache()
        }
    }

    // MARK: - Followed shows

    /// Shows the learner follows whole: discovery brings in every episode
    /// Apple Podcasts holds for them, not only the listened ones. Kept in the
    /// preference store like the discovery scope, since it steers a Mac-only
    /// import rather than describing a source.
    nonisolated static let followedPodcastShowsKey = "podcasts.followedShows"

    nonisolated static func followedPodcastShowNames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: followedPodcastShowsKey) ?? [])
    }

    var followedPodcastShows: Set<String> {
        Self.followedPodcastShowNames()
    }

    func isPodcastShowFollowed(_ showName: String) -> Bool {
        followedPodcastShows.contains(showName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Follow a show: import everything Apple Podcasts holds for it now, and
    /// let discovery keep bringing in every new episode from here on. Returns
    /// how many episodes the first import added, or nil when the Podcasts
    /// library could not be read (the show is still marked followed).
    func followPodcastShow(_ showName: String) async -> Int? {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Following a show is the loudest possible statement that its episodes
        // are wanted, so it overrides an earlier block rather than fighting it:
        // otherwise the import below would run and discovery would drop every
        // row it just made.
        unblockPodcastShow(trimmed, silently: true)
        var names = followedPodcastShows
        names.insert(trimmed)
        PreferenceStore.set(names.sorted(), forKey: Self.followedPodcastShowsKey)
        followedPodcastShowsVersion &+= 1
        return await importAllEpisodes(ofShow: trimmed)
    }

    /// Stop following a show. Episodes already imported stay.
    ///
    /// `silently` is for the case where unfollowing is a consequence of
    /// something else the learner asked for — blocking the show — and its own
    /// toast would talk over the one that describes what they actually did.
    func unfollowPodcastShow(_ showName: String, silently: Bool = false) {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = followedPodcastShows
        guard names.remove(trimmed) != nil else { return }
        if names.isEmpty {
            PreferenceStore.remove(forKey: Self.followedPodcastShowsKey)
        } else {
            PreferenceStore.set(names.sorted(), forKey: Self.followedPodcastShowsKey)
        }
        followedPodcastShowsVersion &+= 1
        if !silently {
            showToast("Stopped following \(trimmed)")
        }
    }

    // MARK: - Blocked shows

    /// Shows whose episodes discovery refuses to import at all — the inverse of
    /// the follow list above. `SourceDiscovery` owns the list and the matching;
    /// what these add is the part only the app has: a toast, the re-render
    /// nudge, and the pass that acts on the change.
    var blockedPodcastShows: Set<String> {
        SourceDiscovery.blockedPodcastShowNames()
    }

    func isPodcastShowBlocked(_ showName: String) -> Bool {
        SourceDiscovery.isPodcastShowBlocked(showName)
    }

    /// Stop importing this show. Episodes already in the library stay where they
    /// are — blocking answers "do not bring me any more of this", and removing
    /// what is already here is a separate act the menu offers next to it.
    ///
    /// Following the show is the opposite statement, so it is dropped.
    /// `silently` is for `removeAllFromPodcast`, which blocks as part of a
    /// removal that posts its own undoable notice.
    func blockPodcastShow(_ showName: String, silently: Bool = false) {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SourceDiscovery.setPodcastShowBlocked(trimmed, blocked: true) else { return }
        blockedPodcastShowsVersion &+= 1
        if isPodcastShowFollowed(trimmed) {
            unfollowPodcastShow(trimmed, silently: true)
        }
        if !silently {
            showToast("No longer importing \(trimmed)")
        }
    }

    /// Let the show be imported again, starting from the next discovery pass.
    ///
    /// This does not undo a removal. Episodes removed from the show carry a
    /// `dismissed_sources` tombstone, which is the learner's own refusal and
    /// outranks this — so what comes back is what Apple Podcasts holds and the
    /// library never tombstoned.
    func unblockPodcastShow(_ showName: String, silently: Bool = false) {
        guard SourceDiscovery.setPodcastShowBlocked(showName, blocked: false) else { return }
        blockedPodcastShowsVersion &+= 1
        if !silently {
            showToast("Importing \(showName.trimmingCharacters(in: .whitespacesAndNewlines)) again")
            Task { [weak self] in
                await self?.syncPodcastLibraryIfChanged(force: true)
            }
        }
    }

    // MARK: - Local Knowledge Folder Discovery

    /// The ForeverLM root directory, resolved via the iCloud ubiquity container.
    var knowledgeBasePath: String {
        StorageService.libraryRootPath
    }
}
