import Foundation
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import Darwin

/// View model for the Reading List Studio — manages the article queue,
/// draft card generation, and card acceptance workflow.
///
/// On load, auto-populates from:
/// 1. Saved reading list (persisted queue from last session)
/// 2. Safari Reading List (macOS only — parses Bookmarks.plist)
/// 3. Apple Podcasts transcripts (TTML cache + metadata lookup)
///
@Observable @MainActor
class StudioViewModel {

    static let bulkYouTubeTranscriptFetchLimit = 3
    /// Apple transcript lookup is intentionally serial because its private
    /// catalog API is sensitive to bursts. Audio transcription is never part of
    /// this automatic queue; it has a separate per-episode opt-in action.
    static let bulkPodcastTranscriptFetchLimit = 1
    /// Chunks of one transcript formatted at a time.
    ///
    /// The per-video limits above bound how many transcripts are in flight, but
    /// each transcript then fans out over its own chunks, so the real ceiling on
    /// concurrent AI requests was `videos × chunks` — a long lecture playlist
    /// could put dozens in flight at once and exhaust the account's hourly
    /// request budget in minutes. Capping the inner loop makes the outer limits
    /// mean what they look like they mean.
    ///
    /// `nonisolated` so the off-main podcast formatter can read it too.
    nonisolated static let transcriptChunkFormatConcurrency = 2
    /// Floor below which transcript formatting is never attempted: a caption
    /// blob this small has nothing to gain from headings, and the formatter's
    /// own usability validation would reject the result anyway.
    nonisolated static let minimumFormattableTranscriptLength = 500
    nonisolated static let supportedBookFileExtensions: Set<String> = ["pdf", "epub", "azw", "azw3", "mobi", "prc"]
    nonisolated static let kindleBookFileExtensions: Set<String> = ["azw", "azw3", "mobi", "prc"]
    nonisolated static let noPodcastTranscriptMessage = "No transcript available from Apple Podcasts for this episode."
    nonisolated static let unavailablePodcastTranscriptMessage = "Transcript access isn’t available from Apple Podcasts for this episode."
    nonisolated static let retryablePodcastTranscriptMessage = "Couldn’t download the transcript. Try again."
    nonisolated static let podcastAudioTranscriptionMessage = "Couldn’t transcribe the episode audio. Try again."
    nonisolated static let youtubePreferredPodcastTranscriptMessage = "Find this episode on YouTube to add its transcript."
    /// A private-feed or web-page episode whose show has no public edition, or
    /// whose public edition carries no episode with this identity. Apple only
    /// transcribes the public catalog, so there is no transcript to ask for.
    nonisolated static let noPublicPodcastEpisodeMessage = "No matching episode found on Apple Podcasts."
    /// The row resolved to an episode the library already holds under its
    /// public identity, and was folded into it.
    nonisolated static let mergedPodcastEpisodeMessage = "This episode is already in your library."

    nonisolated static func isTerminalPodcastTranscriptError(_ message: String?) -> Bool {
        message == noPodcastTranscriptMessage
            || message == unavailablePodcastTranscriptMessage
            || message == podcastAudioTranscriptionMessage
            || message == youtubePreferredPodcastTranscriptMessage
            || message == noPublicPodcastEpisodeMessage
            || message == mergedPodcastEpisodeMessage
    }

    nonisolated static func canOptInToPodcastAudioTranscription(_ message: String?) -> Bool {
        message == noPodcastTranscriptMessage
            || message == unavailablePodcastTranscriptMessage
            || message == podcastAudioTranscriptionMessage
            || message == noPublicPodcastEpisodeMessage
    }

    /// Whether a podcast row can be asked for a transcript: it carries an Apple
    /// episode address, or it was filed under an episode's web page by a feed
    /// that names its show, in which case hydration first resolves the public
    /// episode. A page pasted by hand names only a host and still goes through
    /// the match-and-confirm flow.
    nonisolated static func podcastRowCanHydrate(url: String, showName: String) -> Bool {
        if url.hasPrefix("apple-podcast:") { return url.contains("/episode/") }
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return false }
        return !PodcastPublicEpisodeResolver.isHostLikeShowName(showName)
            && !showName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @ObservationIgnored var sourceIndexingKickTask: Task<Void, Never>?
    @ObservationIgnored var cloudKitRemoteChangeTask: Task<Void, Never>?
    @ObservationIgnored var sharedDocsObservationTask: Task<Void, Never>?
    @ObservationIgnored var iCloudFullObservationTask: Task<Void, Never>?
    @ObservationIgnored var cloudKitBackgroundSyncTask: Task<Void, Never>?
    @ObservationIgnored var cloudKitEventSyncTask: Task<Void, Never>?
    @ObservationIgnored var lastCloudKitEventSyncAt: Date?
    @ObservationIgnored var derivedSourceWorkTask: Task<Void, Never>?
    @ObservationIgnored var derivedSourceWorkDebounceTask: Task<Void, Never>?
    /// The drain itself. Deliberately separate from the debounce task and never
    /// cancelled by it — see `startDerivedSourceWork()`.
    @ObservationIgnored var derivedSourceWorkRunTask: Task<Void, Never>?
    @ObservationIgnored var isRunningDerivedSourceWork = false
    /// An event that arrived while a drain was running. The drain restarts once
    /// rather than being interrupted and restarted for each event.
    @ObservationIgnored var hasPendingDerivedSourceWork = false
    @ObservationIgnored var derivedSourceWorkRetryTask: Task<Void, Never>?
    /// Drains in a row that made no progress and stopped on a failure worth
    /// waiting out; sets how long the next retry waits. Back to zero as soon
    /// as a batch gets anything done.
    @ObservationIgnored var derivedSourceWorkRetryRound = 0
    @ObservationIgnored var managedAICreditsRestoredTask: Task<Void, Never>?
    /// Bulk re-queues into paid background queues waiting for the learner's
    /// choice (schema 135). The sidebar shows one row per job.
    var pendingBackgroundAIBulkJobs: [BackgroundAIBulkJob] = []
    /// The one wake-up at the next local midnight after the daily background
    /// cap paused the drains.
    @ObservationIgnored var backgroundAIDayRolloverTask: Task<Void, Never>?
    @ObservationIgnored var backgroundAISpendObserverTask: Task<Void, Never>?
    @ObservationIgnored var backgroundAICapObserverTask: Task<Void, Never>?
    @ObservationIgnored var readingListAutoSyncTask: Task<Void, Never>?
    @ObservationIgnored var podcastAutoSyncTask: Task<Void, Never>?
    @ObservationIgnored var zoomLocalTranscriptAutoSyncTask: Task<Void, Never>?
    @ObservationIgnored var youtubeAutoImportTask: Task<Void, Never>?
    /// Re-reads `youtubeAccounts` whenever a plugin connection changes.
    @ObservationIgnored var youtubeAccountObserverTask: Task<Void, Never>?
    /// The YouTube accounts, in the order they were connected
    /// (`reloadYouTubeAccounts`). Observed, so the plugin page, the Plugins
    /// place and the Videos sidebar follow connections.
    var youtubeAccounts: [YouTubeAccount] = []
    /// Listed accounts Google revoked (`youtubePluginNeedsReconnect`). A plugin
    /// that quietly stops syncing for days is indistinguishable from "I haven't
    /// added anything lately", which is exactly how a week of missed videos
    /// went unnoticed.
    var youtubeDisconnectedAccountIDs: Set<String> = []
    /// Whether the last YouTube failure was already logged, so a plugin
    /// that stays broken writes one log line per outage instead of one every
    /// 15 minutes for as long as the app stays open.
    @ObservationIgnored var hasLoggedYouTubePluginFailure = false
    /// When each plugin last synced, on any path — an event-triggered sync
    /// (scroll-to-top, app activation, a tab opening) or the learner's own
    /// pull-to-refresh. `syncTabPluginsOnEvent` reads it to decide which
    /// plugins an event is allowed to sync again.
    @ObservationIgnored var lastPluginSyncAt: [EventSyncPlugin: Date] = [:]
    @ObservationIgnored var readingListModificationSnapshot: [String: Date] = [:]
    /// FSEvents watcher that drives event-triggered reading-list syncs.
    @ObservationIgnored var readingListFileWatcher: LocalSourceFileWatcher?
    /// Watches Apple Podcasts' database/WAL so iCloud play-state changes are
    /// discovered while ForeverLM remains open.
    @ObservationIgnored var podcastLibraryFileWatcher: LocalSourceFileWatcher?
    @ObservationIgnored var podcastLibraryModificationSnapshot: [String: PodcastLibraryFileFingerprint] = [:]
    /// Watches Zoom's local recording folder so the caption transcript the
    /// desktop client saves after a meeting files itself into the series.
    @ObservationIgnored var zoomLocalTranscriptFileWatcher: LocalSourceFileWatcher?
    @ObservationIgnored var zoomLocalTranscriptSnapshot: [String: Date] = [:]
    @ObservationIgnored var zoomLocalTranscriptAutoSyncInFlight = false
    @ObservationIgnored var zoomLocalTranscriptAutoSyncNeedsAnotherPass = false
    @ObservationIgnored var zoomLocalTranscriptAutoSyncNeedsForcedPass = false
    /// Transcription attempts per Zoom recording folder this launch, and the
    /// folders whose last attempt failed and are owed another by the backstop.
    @ObservationIgnored var zoomLocalRecordingTranscriptAttempts: [String: Int] = [:]
    @ObservationIgnored var zoomLocalRecordingRetryPending: Set<String> = []
    /// Zoom sessions the watcher has already tried to write who was there
    /// on, this launch (`backfillZoomSessionParticipants`).
    @ObservationIgnored var zoomSessionParticipantBackfillTried: Set<String> = []
    /// The length of each converted Zoom recording a later one could
    /// continue, by folder path, read once per launch (`zoomLocalRecordingHeads`).
    @ObservationIgnored var zoomLocalRecordingDurations: [String: TimeInterval] = [:]
    /// Converted Zoom recordings measured this launch to hold no speech
    /// (`RecordingSpeechLevel`), by folder path, so each is decoded once.
    @ObservationIgnored var zoomLocalRecordingsWithoutSpeech: Set<String> = []
    /// Zoom recordings on this Mac only Zoom can convert, waiting for the
    /// learner's Convert in Zoom or Ignore; and the folders they ignored.
    /// Observed: the Meetings tab and Settings › Sources draw them.
    var zoomLocalUnconvertedRecordings: [ZoomLocalRecordingAwaitingConversion] = []
    var zoomLocalRecordingIgnoredFolders: Set<String> = StudioViewModel.zoomLocalRecordingIgnoredFoldersFromDefaults()
    /// A recording the automatic pass handed Zoom whose unknown-source
    /// dialog ForeverLM is still watching for (`convertZoomLocalRecordingAutomatically`).
    @ObservationIgnored var zoomLocalRecordingAutoConversionInFlight = false
    /// Serializes launch, FSEvents, activation, and backstop podcast scans.
    @ObservationIgnored var podcastAutoSyncInFlight = false
    @ObservationIgnored var podcastAutoSyncNeedsAnotherPass = false
    @ObservationIgnored var podcastAutoSyncNeedsForcedPass = false
    /// Serializes watcher-fired and backstop reading-list sync passes.
    @ObservationIgnored var readingListAutoSyncInFlight = false
    @ObservationIgnored var readingListAutoSyncNeedsAnotherPass = false
    @ObservationIgnored var readingListAutoSyncNeedsForcedPass = false
    /// Papers moving through the complete post-attachment metadata flow. This
    /// stays observable because the Papers sidebar uses it to place a newly
    /// imported PDF in Processing before the first narrower AI phase begins.
    var paperMetadataEnrichmentInFlight: Set<String> = []
    /// Newly inserted papers waiting for their automatic queue ownership to be
    /// established. This closes the UI gap between the optimistic insert and the
    /// first network step so an explicit Add to Sources click appears under
    /// Processing at once.
    var pendingPaperProcessingIds: Set<String> = []
    /// Papers currently waiting their turn in the serial PDF-resolution queue.
    /// Queue storage itself is observation-ignored bookkeeping; this observable
    /// ownership set keeps every waiting row in Processing until its attempt ends.
    var queuedPaperPDFResolutionIds: Set<String> = []
    /// Papers currently waiting their turn in the serial metadata-extraction queue.
    /// Keep this separate from PDF ownership: the two queues can briefly contain
    /// the same paper, and one finishing must not expose the other's work as a
    /// learner-actionable metadata failure.
    var queuedPaperMetadataExtractionIds: Set<String> = []
    /// Per-paper caption for the exact active ingestion phase. The broader ID
    /// sets above decide whether a row belongs under Processing; this transient
    /// map tells that row what the pipeline is doing right now.
    var paperProcessingSteps: [String: String] = [:]
    /// Optional preprint-to-publication identity checks run after required paper
    /// ingestion. They are deliberately not part of Processing: a slow catalog
    /// lookup must not keep an otherwise ready paper under a metadata spinner.
    @ObservationIgnored var publishedVersionResolutionInFlight: Set<String> = []
    /// A learner-supplied PDF supersedes automatic browser discovery. Keep the
    /// real cancellable work, not just its display marker, so a drop can stop
    /// WebKit/AI immediately and prevent a late browser result from overwriting
    /// the uploaded file.
    @ObservationIgnored var activePaperBrowserAttemptIDs: [String: UUID] = [:]
    @ObservationIgnored var activePaperBrowserServices: [String: SourceDiscovery.PaperAIBrowserDownloadService] = [:]
    @ObservationIgnored var activePaperBrowserTasks: [String: Task<SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF, Error>] = [:]
    @ObservationIgnored var zoomMeetingAdoptionInFlight = false
    @ObservationIgnored var sourceTextReferenceRepairInFlight = false
    /// The soft hyphen repair running now (schema 166), which a second caller
    /// waits for rather than skips: the launch starts sync only once it is done.
    @ObservationIgnored var storedSoftHyphenRepairTask: Task<Void, Never>?
    @ObservationIgnored var sourceWordCountRepairInFlight = false
    @ObservationIgnored var paperFigureImageSweepInFlight = false
    @ObservationIgnored var paperFigureIndexBackfillInFlight = false
    @ObservationIgnored var missingPaperPDFDownloadTask: Task<Void, Never>?
    /// Auto-fetch bookkeeping: every paper that needs a PDF gets one silent
    /// background fetch attempt per session, deduplicated through this set so we
    /// never retry the same paper repeatedly within a session.
    @ObservationIgnored var autoFetchAttemptedPaperIDs: Set<String> = []
    @ObservationIgnored var autoFetchPaperQueue: [String] = []
    @ObservationIgnored var isDrainingAutoPaperFetchQueue = false
    /// Sources already put through LLM source-type reclassification this session.
    /// A remote paper without a PDF re-enters `fetchContent` on every sweep but
    /// only ever bails back out, so without this memo the classification call is
    /// spent again on every pass — the same URL and title, indefinitely.
    @ObservationIgnored var sourceClassificationAttemptedIDs: Set<String> = []
    /// Sources already tried for their first content fetch this session, so a
    /// failing one is attempted once per launch rather than on every sweep.
    @ObservationIgnored var autoFetchAttemptedContentIDs: Set<String> = []
    @ObservationIgnored var autoFetchContentQueue: [String] = []
    @ObservationIgnored var isDrainingInitialContentFetchQueue = false
    /// Auto-extract bookkeeping: every paper still showing unknown author/venue/
    /// year gets one silent background AI metadata extraction per session,
    /// deduplicated through this set so we never retry the same paper repeatedly.
    @ObservationIgnored var autoExtractMetadataAttemptedPaperIDs: Set<String> = []
    @ObservationIgnored var autoExtractMetadataQueue: [String] = []
    @ObservationIgnored var isDrainingAutoExtractMetadataQueue = false
    /// Sorted book group names memoized per articles revision + book metadata.
    /// `allBookGroupNames` is read from row bodies, alert closures, and the
    /// search-count path, so it must be cheap on repeat evaluation.
    @ObservationIgnored var allBookGroupNamesCacheKey: BookGroupNamesCacheKey?
    @ObservationIgnored var allBookGroupNamesCache: [String]?
    /// Hidden-item counts per tab, memoized on everything they read
    /// (`memoizedHiddenItemCounts`).
    @ObservationIgnored var hiddenItemCountsCacheKey: HiddenItemCountsCacheKey?
    @ObservationIgnored var hiddenItemCountsCache: [StudioSidebarTab: (groups: Int, items: Int)] = [:]
    /// Deduplicates automatic read writes while a reader's final scroll event is
    /// still being persisted. The status itself remains observed through `articles`.
    @ObservationIgnored var automaticReadCompletionInFlightIDs: Set<String> = []
    /// Depth each open reader started at, so a restored scroll position — which
    /// arrives as an ordinary scroll callback — is not mistaken for the learner
    /// moving through the source. Only progress *past* the baseline counts.
    @ObservationIgnored var readerOpenDepthBaselines: [String: Double] = [:]
    /// Latest-wins debounce for depth writes, keyed by source. Scrolling emits a
    /// position several times a second; the ledger only needs where it settled.
    @ObservationIgnored var readerDepthWriteTasks: [String: Task<Void, Never>] = [:]
    /// Engaged seconds the reader heartbeat has counted for an open source but
    /// not yet written to the ledger. The automatic read mark reads it so a
    /// sitting's time counts before it is flushed.
    @ObservationIgnored var readerEngagedPendingSeconds: [String: Double] = [:]
    let articlesStore = StudioArticlesStore()
    let readingProgressStore = StudioReadingProgressStore()
    /// The Sources panel state of the window being acted in. The stores
    /// themselves live on `StudioWindowState`, one per window, because a tab,
    /// a search, or a filter is a view of the library and two windows browse it
    /// differently. This accessor is the bridge for view-model flows — a menu
    /// command, a citation click, `switchTab` — that act in whichever window is
    /// key, or in the window a `inWindow(_:_:)` scope names. Views never read it
    /// for rendering: they take their own window's store from the environment,
    /// and derived lists through `scoped(to:)`, so a window that is not key
    /// still draws its own list.
    var sidebarStore: StudioSidebarStore {
        activeWindowState.sidebarStore
    }
    /// Reverse course membership is derived from source ownership plus lecture
    /// attachments. Keep it observation-ignored and invalidate it explicitly:
    /// sidebar filtering asks for membership once per source, so rebuilding it
    /// inside each lookup turns a tab switch into O(sources × course items).
    @ObservationIgnored var courseGroupIDsBySourceIDCache: [String: Set<String>]?
    /// Context menus are built eagerly for every visible source row. Keep the
    /// ordered course lists memoized so each row does not repeat the same set
    /// construction, display-name mapping, and localized sort.
    @ObservationIgnored var allCourseGroupNamesCache: [String]?
    @ObservationIgnored var visibleCourseGroupNamesCache: [String]?
    /// The last Docs source picker index. Never read as an answer — each opening
    /// takes a fresh snapshot — only so a source whose fields are unchanged is not
    /// analysed again (`artifactSourcePickerIndex()`).
    @ObservationIgnored var artifactSourcePickerIndexMemo: ArtifactSourcePickerIndex?
    /// The library's share of the Papers lists (`paperLibraryIndex`) and its
    /// storage-degraded set (`unavailableRecordedPaperPDFIDs`), each keyed on
    /// all it reads (`PaperLibraryKey`). One copy serves every window, and the
    /// sidebar's invalidation — a schedule or preference reload, a sync pass —
    /// leaves them be: none of those changes what they hold.
    @ObservationIgnored var paperLibraryIndexCache: PaperLibraryIndex?
    @ObservationIgnored var paperLibraryUnavailableCache: (key: PaperLibraryKey, ids: Set<String>)?
    /// Each paper's listing facts by source id (`paperListingFacts(for:)`),
    /// parsed again only when a field they are read from changes.
    @ObservationIgnored var paperListingFactsByID: [String: PaperListingFacts] = [:]
    /// Each source's fields as a sidebar search reads them, by source id
    /// (`sidebarSearchAnalysis(of:)`), and the query being asked of them
    /// (`sidebarSearchMatcher(for:)`): a search pass compares, it does not
    /// re-fold the library.
    @ObservationIgnored var sidebarSearchAnalyses: [String: SidebarSearchAnalysis] = [:]
    @ObservationIgnored var sidebarSearchMatcherMemo: SidebarSearchMatcher?
    @ObservationIgnored var bookCoverPopulationTask: Task<Void, Never>?
    @ObservationIgnored var cloudKitRemoteRefreshDebounceTask: Task<Void, Never>?
    @ObservationIgnored var cloudKitRemoteRefreshTask: Task<Void, Never>?
    @ObservationIgnored var pendingCloudKitRefreshEntities: Set<CloudKitSyncEntity> = []
    @ObservationIgnored var cloudKitRemoteRefreshRequiresFullReload = false


    // MARK: - Published State

    /// Podcast episodes found for a source and waiting for the learner, or
    /// resolve_podcast_match, to confirm them, by source id. A match has no
    /// column, so a source's row in `articles` loses it whenever the row is
    /// read back from the store (a CloudKit refresh, a metadata pass); this
    /// keeps it until it is confirmed or rejected, or the app quits.
    var stagedPodcastMatches: [String: StagedPodcastMatch] = [:]

    var articles: [StudioArticle] = [] {
        didSet {
            // Loaded text landing in the array — a chat send hydrating an
            // attached transcript, a reader open — changes nothing any row
            // shows. It still publishes (the reader is waiting on it), but it
            // must not empty every window's filtered sidebar and re-diff its
            // rows: on a 4,000-source library that rebuild is seconds of main
            // thread per send. See `StudioArticle.presentationEquals`.
            let presentationChanged = !StudioArticle.presentationEquals(oldValue, articles)
            articlesStore.sync(from: articles, presentationChanged: presentationChanged)
            guard presentationChanged else { return }
            courseGroupIDsBySourceIDCache = nil
            invalidateSidebarCachesInEveryWindow()
            // A source list change can mean a PDF just arrived. Re-stat the cached
            // misses OFF the main actor (debounced) instead of clearing the
            // negative cache, which made the very next render re-stat every
            // missing iCloud file synchronously on the main actor.
            scheduleResolvedPathRevalidation()
            // A source list change can also be the first source an integration
            // ever delivered — a plugin's meeting or thread arriving over MCP
            // has no other choke point — and its tab is unpinned until then.
            pinIntegrationTabsInUse()
        }
    }

    /// One-shot guard for `resolveSuppressedDuplicatePapers()`.
    @ObservationIgnored var didResolveSuppressedDuplicatePapers = false
    /// Whether this launch has taken preprints' published DOIs out of their work keys.
    @ObservationIgnored var didRepairPublishedDOIWorkKeys = false
    /// Whether this launch has asked for the post address of the sources saved under a Substack app link.
    @ObservationIgnored var didGivePostAddressesToSubstackAppLinkSources = false
    /// Asks Substack which post an app link names (`SubstackAppLink`); a test
    /// answers for it.
    @ObservationIgnored var substackPostAddress: @Sendable (String) async -> String? = {
        await SubstackAppLink.resolvePostAddress($0)
    }

    @ObservationIgnored private var resolvedPathRevalidationTask: Task<Void, Never>?

    /// Debounced background pass over the resolved-path cache. It stats sources
    /// that have never been resolved (imported or synced in after launch, so the
    /// load-time warm never saw them) and re-stats cached misses whose file has
    /// since appeared (iCloud download, background fetch, attach). Both run off
    /// the main actor, then the article list is re-published once so rows — which
    /// render through the cached-only `cachedResolvedLocalPath` accessors and
    /// never stat themselves — re-evaluate against pure cache hits.
    private func scheduleResolvedPathRevalidation() {
        resolvedPathRevalidationTask?.cancel()
        resolvedPathRevalidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Snapshot after the debounce so the rapid `articles[idx]` writes that
            // content fetching does don't each rebuild this list.
            guard let rawPaths = self?.resolvedPathWarmupSnapshot() else { return }
            let changed = await Task.detached(priority: .utility) {
                let warmed = StudioArticle.warmResolvedLocalPathCache(forRawPaths: rawPaths)
                let promoted = StudioArticle.revalidateMissingResolvedPaths()
                return warmed || promoted
            }.value
            guard changed, !Task.isCancelled, let self else { return }
            // Drop book groups that resolved to "no EPUB". That answer may have
            // been recorded before the group's cover path or chapters landed, and
            // re-resolution is lazy — only a menu that asks again pays for it.
            // Successful resolutions are kept, so this doesn't re-enumerate the
            // whole library.
            self.bookEPUBURLs = self.bookEPUBURLs.filter { $0.value != nil }
            // Re-publish to refresh rows; the follow-on didSet pass finds nothing
            // new to stat or promote, so this terminates after one extra pass.
            self.articles = self.articles
        }
    }

    @ObservationIgnored private var resolvedPathCacheClearTask: Task<Void, Never>?

    /// Sync clears the whole resolved-path cache when another Mac's files or
    /// text land (`invalidateAllResolvedPathCaches`). The reload that follows
    /// often changes nothing a row shows, so `articles`' didSet never warms it
    /// again, and every local PDF answered "unknown": the Reader showed a
    /// paper's stored text instead of its PDF until relaunch. Warm on the clear.
    func startObservingResolvedPathCacheClears() {
        resolvedPathCacheClearTask?.cancel()
        resolvedPathCacheClearTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .resolvedPathCacheDidClear) {
                guard !Task.isCancelled else { return }
                self?.scheduleResolvedPathRevalidation()
            }
        }
    }

    /// Raw stored path strings for every source, for off-main path resolution.
    /// `StudioArticle` is not Sendable; these strings are.
    private func resolvedPathWarmupSnapshot() -> [String] {
        articles.flatMap { article -> [String] in
            var paths: [String] = [article.url]
            if let localFilePath = article.localFilePath { paths.append(localFilePath) }
            return paths
        }
    }

    var articlesById: [String: StudioArticle] {
        // The store's dictionary is @ObservationIgnored, so a view that resolves
        // a source by id (reader via `selectedArticle`, planner rows, overlays)
        // would otherwise register no dependency on the article list and never
        // re-render when a fetch fills in content — the reader's "Fetching
        // transcript…" spinner stayed up until the selection changed. Reading
        // `revision` registers that dependency without observing per-key writes.
        _ = articlesStore.revision
        return articlesStore.articlesById
    }

    /// The revision every derived-list cache keys on. Presentation only: text
    /// arriving for a source does not invalidate a filtered sidebar, a papers
    /// partition, or a meeting index, none of which read content.
    var articlesRevision: Int {
        articlesStore.presentationRevision
    }
    var selectedArticleId: String? {
        didSet {
            // Moving to nothing empties the fallback windows anyway, and pinning
            // them to a source that is usually being deleted would only leave a
            // dead id behind.
            guard selectedArticleId != oldValue, selectedArticleId != nil else { return }
            pinWindowsFollowingTheGlobalSelection(to: oldValue)
        }
    }
    /// The rows highlighted in the key window's Sources list. The set itself lives
    /// on `StudioWindowState`, because a highlight is presentation and two windows
    /// browsing the same library select different rows; this accessor is the bridge
    /// for view-model flows that act in whichever window is key. Views render their
    /// own window's `sidebarSelectedSourceIDs` directly, and a source leaving the
    /// library goes through `deselectSourcesInEveryWindow`, which this cannot reach.
    var selectedArticleIds: Set<String> {
        get { activeWindowState.sidebarSelectedSourceIDs }
        set { activeWindowState.sidebarSelectedSourceIDs = newValue }
    }
    /// Monotonic navigation requests by source. A source row can be clicked
    /// while it is already selected, which leaves `selectedArticleId` unchanged;
    /// the reader uses this revision to distinguish that explicit request from
    /// an unrelated view update and return from an in-article link to the
    /// source's original document.
    var readerNavigationRevisionsBySourceID: [String: UInt] = [:]

    func readerNavigationRevision(for sourceID: String) -> UInt {
        readerNavigationRevisionsBySourceID[sourceID] ?? 0
    }
    /// Section of a meeting session's document the reader should scroll to, set
    /// by a click on one of the session's Transcript/Notes/Chat rows and
    /// consumed by the transcript reader. See `MeetingSectionReaderTarget`.
    var meetingSectionReaderTarget: MeetingSectionReaderTarget?
    /// Monotonic, so clicking the same row twice asks twice.
    var meetingSectionReaderRevision: UInt = 0
    /// Moment a chat citation or deep link asked the reader to open at, set
    /// after the source is selected and consumed by the reader showing it. See
    /// `ReaderTimeTarget`.
    var readerTimeTarget: ReaderTimeTarget?
    /// Monotonic, so citing the same moment twice seeks twice.
    var readerTimeTargetRevision: UInt = 0
    /// A chat asking the video Reader showing a source to pause while the
    /// learner types a question about it. See `ReaderVideoPauseRequest`.
    var readerVideoPauseRequest: ReaderVideoPauseRequest?
    /// Monotonic, so each question pauses again.
    var readerVideoPauseRevision: UInt = 0
    /// Passage a chat citation asked the reader to show, set after the source is
    /// selected and consumed by the reader showing it. See `ReaderPassageTarget`.
    var readerPassageTarget: ReaderPassageTarget?
    /// Monotonic, so citing the same passage twice flashes twice.
    var readerPassageTargetRevision: UInt = 0
    /// Source the sidebar list should scroll to (set when a chat citation or other
    /// cross-panel jump selects a source). Consumed by the sidebar.
    var sidebarRevealRequest: SidebarRevealRequest?
    /// Every top-level Notebook that is visible in the current presentation mode,
    /// including archived Notebooks. Most UI should use `notebooks`; the gallery uses
    /// this complete set to provide the explicit Archived view.
    var allNotebooks: [LearningGoalRecord] {
        notebookLists.all
    }

    /// Active Notebooks are the normal app navigation/context surface. Archived
    /// Notebooks remain fully persisted and synced, but disappear from selectors,
    /// Today, drag destinations, and the navigation rail until restored.
    var notebooks: [LearningGoalRecord] {
        var lists = notebookLists
        if let active = lists.active { return active }
        let active = orderedNotebooks(lists.all.filter { !$0.isArchived })
        lists.active = active
        notebookListsCache = lists
        return active
    }

    var archivedNotebooks: [LearningGoalRecord] {
        var lists = notebookLists
        if let archived = lists.archived { return archived }
        let archived = orderedNotebooks(lists.all.filter(\.isArchived))
        lists.archived = archived
        notebookListsCache = lists
        return archived
    }

    /// Everything the notebook lists are cut from. `learningGoalsRevision`
    /// stands for the goals themselves; the library, the Screen record scope
    /// and the order compare by value, a single check while they are the same
    /// value.
    struct NotebookListsKey: Equatable {
        let learningGoalsRevision: Int
        let activeTeamID: String?
        let screenRecordScope: ScreenRecordScope?
        let notebookOrder: [String]
    }

    /// `allNotebooks`, and `notebooks` and `archivedNotebooks` once asked for.
    struct NotebookLists {
        let key: NotebookListsKey
        let all: [LearningGoalRecord]
        var active: [LearningGoalRecord]?
        var archived: [LearningGoalRecord]?
    }

    var currentNotebookListsKey: NotebookListsKey {
        // Read for the dependency: a view that hits the memo still re-renders
        // when the goals change, though the key holds only their revision.
        _ = learningGoals
        return NotebookListsKey(
            learningGoalsRevision: learningGoalsRevision,
            activeTeamID: activeTeamID,
            screenRecordScope: screenRecordScope,
            notebookOrder: notebookOrder
        )
    }

    /// The notebook lists, built once per change to what they read. Rows read
    /// them by the hundred — every chat row in the rail, every item the Space
    /// lists — and an uncached read filters every goal and rebuilds the order.
    private var notebookLists: NotebookLists {
        let key = currentNotebookListsKey
        if let cached = notebookListsCache, cached.key == key {
            return cached
        }
        let all = learningGoals.filter { goal in
            goal.isNotebook && goal.teamID == activeTeamID
                && (screenRecordScope?.allowsNotebook(id: goal.id, createdAt: goal.createdAt) ?? true)
        }
        let lists = NotebookLists(key: key, all: all)
        notebookListsCache = lists
        return lists
    }

    // MARK: - The notebook last worked in

    /// When this Mac last worked in each notebook — opened it in a window,
    /// sent a message in its chat, added a source to it — for the notebook a
    /// new window opens in and the rail's Recent order
    /// (`NotebookRecency`, `StudioViewModel+NotebooksHome.swift`). Written by
    /// `noteNotebookWork` alone.
    var notebookRecency = NotebookRecency()
    /// Where `notebookRecency` is kept: the app's own defaults, device-local;
    /// nil for a view model a test makes, which then keeps it in memory and
    /// writes nothing the learner's next window would read.
    @ObservationIgnored let notebookRecencyDefaults: UserDefaults?

    // MARK: - Pinned notebooks

    /// The row of the retired exceptions list: every notebook was on the
    /// rail unless the learner took it off. Read by nothing (the rail shows
    /// `NotebookPins`), and not synced
    /// (`SyncedPreferenceKeys.excluded`).
    static let unpinnedNotebooksPreferenceKey = Prefs.Studio.retiredUnpinnedNotebooks.name

    /// The notebooks the learner pinned to the rail's Pinned section, in the
    /// order they were pinned (`NotebookPins`). Pinning is presentation, not
    /// lifecycle: a notebook stays active everywhere — selectors, Today, drag
    /// destinations, the home — pinned or not. Archiving is the heavier step
    /// that takes it out of navigation altogether.
    ///
    /// Synced as its own preference row so the rail reaches the learner's
    /// other Macs. A preference rather than a column on the record because a
    /// team member's pins must not be everyone else's.
    var pinnedNotebookIDs: [String] = {
        StudioViewModel.deduplicated(
            Preferences.value(Prefs.Studio.pinnedNotebooks) ?? []
        )
    }() {
        didSet {
            Preferences.set(
                StudioViewModel.deduplicated(pinnedNotebookIDs),
                for: Prefs.Studio.pinnedNotebooks
            )
            // Generation 2: the pins are the member's NotebookStates.
            NotebookSidebarSync.setPinned(pinnedNotebookIDs)
        }
    }

    // MARK: - Notebook chat selection

    /// The sources each notebook's chats leave out, by Notebook id: the boxes
    /// the learner unticked beside its sources. Mirrors the
    /// `notebook.chatExcluded.*` rows (`NotebookChatSelection`) and is reseeded
    /// in `reloadSyncedPreferences`. No didSet: `setNotebookSources(_:inChat:notebookID:)`
    /// is the one writer, so a test can seed it without touching the
    /// learner's defaults.
    var notebookChatExclusions: [String: Set<String>] = NotebookChatSelection.exclusionsFromDefaults()

    /// The context notebooks each notebook's chats read, by Notebook id: the
    /// linked notebooks the learner put in (`NotebookChatContext`). Mirrors
    /// the `notebook.chatContextNotebooks.*` rows and is reseeded beside
    /// `notebookChatExclusions`, which `setNotebookSources` and
    /// `setNotebookContextNotebooks` write with it.
    var notebookChatContextNotebooks: [String: Set<String>] = NotebookChatSelection.contextNotebooksFromDefaults()

    /// The learner's collections of notebooks, as the Space groups All by
    /// them (Group by Collection): mirrors the `notebookCollection.*` and `notebook.collections.*`
    /// rows (`NotebookCollections`) and is reseeded in
    /// `reloadSyncedPreferences`. The `StudioViewModel+NotebookCollections`
    /// actions are its only writers.
    var notebookCollections = NotebookCollectionRows.read()

    /// The learner's spaces of pages, as the Space sidebar lists them:
    /// mirrors the `pageSpace.*` and `page.space.*` rows (`PageSpaces`) and is
    /// reseeded in `reloadSyncedPreferences`. The `StudioViewModel+PageSpaces`
    /// actions are its only writers.
    var pageSpaces = PageSpaceRows.read()

    /// The pages the learner pinned: mirrors the `page.pinned.*` rows
    /// (`PagePins`), reseeded in `reloadSyncedPreferences`. `setPagePinned`
    /// is its one writer.
    var pagePins = PagePinRows.read()

    /// The chats the learner pinned: mirrors the `chat.pinned.*` rows
    /// (`ChatPins`), reseeded in `reloadSyncedPreferences`. `setChatPinned`
    /// and `reorderPinnedChat` are its writers.
    var chatPins = ChatPinRows.read()

    /// The learner's lists of goals and of ideas in the Space: mirrors the
    /// `spaceList.*` and `spaceListItem.*` rows (`SpaceLists`), reseeded in
    /// `reloadSyncedPreferences`. The `StudioViewModel+SpaceLists` actions
    /// are its only writers.
    var spaceLists = SpaceListRows.read()

    /// Which page each nested page is under: mirrors the `page.parent.*` rows
    /// (`PageParents`), reseeded in `reloadSyncedPreferences`. `setPageParent`
    /// is its one writer.
    var pageParents = PageParentRows.read()

    /// The notebooks ForeverLM may still name, by Notebook id: mirrors the
    /// `notebook.naming.*` rows (`NotebookNaming`) and is reseeded in
    /// `reloadSyncedPreferences`. `setNotebookNamingMark` is its one writer.
    var notebookNamingMarks: [String: NotebookNaming.Mark] = NotebookNamingRows.marks()
    /// Why ForeverLM could not name a notebook, by Notebook id, for its header:
    /// no AI model set up, or a call that failed. Cleared by the next name.
    var notebookNamingErrors: [String: String] = [:]
    /// Notebooks being named right now.
    @ObservationIgnored var notebookNamingIDs: Set<String> = []
    /// A test's canned namer; nil asks the Notebook Naming model.
    @ObservationIgnored var notebookNamerOverride: NotebookNamingService.Namer?

    /// The notebooks as the last inbound CloudKit refresh (or the first load)
    /// left them: what `noteInboundNotebooks` diffs the next inbound change
    /// against, so a source another device added is found even when one of
    /// the many local reloads of `learningGoals` read it from the store first.
    /// Only those two places move it. A local change it has not seen can only
    /// make an arrival's join date earlier (`NotebookChatSelection.inboundArrivals`),
    /// which ticks less, never more.
    @ObservationIgnored var notebookSyncBaseline: [LearningGoalRecord]?

    /// The notebooks made from calendar blocks since launch, by the block's
    /// occurrence (`AppleCalendarEvent.occurrenceKey`). The block is never
    /// written (the calendar is the learner's), so this is how a bout started
    /// on it later knows the notebook it was made into. Read only by actions.
    @ObservationIgnored var notebooksMadeFromBlocks: [String: String] = [:]

    /// User-defined Notebook ordering. The preference is persisted in SQLite and
    /// synced as its own CloudKit preference record, so the rail and gallery keep
    /// the same order after relaunch and across Macs.
    var notebookOrder: [String] = {
        let raw = Preferences.value(Prefs.Studio.notebookOrder) ?? []
        return raw.reduce(into: [String]()) { result, notebookID in
            if !result.contains(notebookID) {
                result.append(notebookID)
            }
        }
    }() {
        didSet {
            let deduplicated = notebookOrder.reduce(into: [String]()) { result, notebookID in
                if !result.contains(notebookID) {
                    result.append(notebookID)
                }
            }
            Preferences.set(deduplicated, for: Prefs.Studio.notebookOrder)
            // Generation 2: the order is the member's NotebookStates' sidebar keys.
            NotebookSidebarSync.setOrder(deduplicated)
        }
    }

    // MARK: - Chat order

    static let chatOrderPreferenceKey = Prefs.Studio.chatOrder.name

    /// User-defined chat ordering for the navigation rail, persisted in SQLite and
    /// synced as its own CloudKit preference record so a rearranged rail survives
    /// relaunch and reaches the learner's other Macs.
    ///
    /// Unlike `notebookOrder` this list is *sparse in the other direction*: a chat it
    /// does not name sorts **before** every chat it does, because chats arrive newest
    /// first and a conversation started ten seconds ago belongs at the top rather than
    /// at the bottom of a hand-made arrangement. `reorderReviewSession` seeds the list
    /// from the whole visible run on the first drag, so "unnamed" thereafter means
    /// "created since the last rearrangement".
    var chatOrder: [String] = {
        StudioViewModel.deduplicated(
            Preferences.value(Prefs.Studio.chatOrder) ?? []
        )
    }() {
        didSet {
            chatOrderRevision &+= 1
            Preferences.set(
                StudioViewModel.deduplicated(chatOrder),
                for: Prefs.Studio.chatOrder
            )
        }
    }

    /// Screen record mode's scope (`ScreenRecordMode`, admin only): nil when
    /// the mode is off, which is every learner but the admin. While it is set,
    /// the lists this view model feeds show only the recording Notebook, its
    /// sources, safe public captures and work made after the mode went on.
    /// Everything stays persisted and synced; only presentation narrows.
    /// Resolved at init with no Notebook sources yet (fail closed), and again
    /// whenever the Notebooks load or the setting changes.
    var screenRecordScope: ScreenRecordScope? = ScreenRecordScope.resolve { _ in [] } {
        didSet {
            if screenRecordScope != oldValue {
                recordingScopeRevision &+= 1
                memoryCardCounts = .zero
                memoryCardsToCheckBySource = [:]
                refreshScreenRecordShownCourses()
                Task { [weak self] in await self?.refreshMemoryCardCounts() }
            }
        }
    }

    /// Invalidates presentation reads whenever the recording boundary or permissions change.
    var recordingScopeRevision = 0

    /// The courses Screen record mode lets on screen (`ScreenRecordScope.allowsCourse`), read off the
    /// main actor by `refreshScreenRecordShownCourses`; nil while the mode is off. The lists that
    /// name courses narrow to it (`shownCourseGroupNames`) and show none until the read lands.
    var screenRecordShownCourseIDs: Set<String>?
    @ObservationIgnored var screenRecordShownCoursesTask: Task<Void, Never>?

    /// How far ahead a deadline can be and still count as work in flight. Four
    /// weeks: far enough that a month-long piece of work is on the list from
    /// the day it is set, near enough that a Goal for the autumn is not sitting
    /// at the top of the tab all summer.
    static let goalHorizonDays = 28
    /// The notebook last opened or filed into on this Mac: what an in-app
    /// choice with no notebook of its own falls back to (the review a fresh
    /// chat suggests, Add to Notebook's tick). Device-local
    /// (`ActiveNotebookPreference`). MCP never reads it: `get_app_context`
    /// names each window's own notebook (`MCPAppWindows`).
    var activeNotebookId: String? = ActiveNotebookPreference.notebookID {
        didSet {
            ActiveNotebookPreference.notebookID = activeNotebookId
        }
    }
    var currentCardIndex: Int = 0
    var isLoadingQueue = false
    /// A source-store failure is not an empty library. Keep it separate from
    /// transient import errors so launch can present a retryable blocking state.
    var libraryLoadErrorMessage: String?
    /// Human-readable step label shown during loadQueue (e.g. "Syncing Safari Reading List…")
    var loadingStep: String?
    /// Sidebar tab the in-flight refresh is scoped to; nil means the refresh covers all tabs.
    /// The sidebar only shows `loadingStep` when this matches the visible tab.
    var loadingStepScope: StudioSidebarTab?
    var isGenerating = false
    var isFetchingContent = false
    var isResolvingMissingPaperPDFs = false
    /// Which batch owns the in-flight PDF-resolution pass, so each section header
    /// can offer Cancel on the button that started it instead of guessing.
    var paperPDFResolutionKind: PaperPDFResolutionKind?
    /// Set by Cancel. The batch loops stop before the *next* paper rather than
    /// tearing down the current one: a paper cancelled mid-download would leave
    /// half-written ingestion state behind, so a graceful stop is worth the wait.
    var isStoppingPaperPDFResolution = false
    /// Papers currently moving through the PDF-resolution pipeline. This is
    /// transient UI state only: persisting it would strand interrupted work in a
    /// permanent processing state after relaunch.
    var resolvingPaperPDFIds: Set<String> = []
    var extractingPaperMetadataIds: Set<String> = []
    /// Sources with a PDF attachment in flight (drop, file picker, or URL download),
    /// so their rows can show a loading indicator while the file is copied and persisted.
    var attachingPDFIds: Set<String> = []
    /// Current step label shown during paper PDF download (e.g. "Trying Nature auth…")
    var paperDownloadStep: String = ""
    /// Progress message shown during book import (e.g. "Splitting chapter 3/8…")
    var bookImportStatus: String = ""
    /// Book imports asked for and not yet finished, the running one included.
    /// The Add Book button stays while they run; each new book waits its turn.
    var bookImportsPending = 0
    /// The last book import in line; the next one starts when it ends.
    @ObservationIgnored var bookImportTail: Task<Void, Never>?
    var showBookImportError = false {
        didSet { if showBookImportError { bookImportAlertWindowID = activeWindowState.id } }
    }
    /// The window that shows a book import's alert: the one that was key
    /// when it was raised.
    @ObservationIgnored var bookImportAlertWindowID: UUID?
    /// Said after a book import that succeeded with parts missing, such as a
    /// damaged EPUB whose lost chapters the learner should replace, or a book
    /// the source classifier reads as a paper.
    var bookImportNotice: String?
    var bookImportNoticeTitle = "Book Imported With Parts Missing"
    var showBookImportNotice = false {
        didSet { if showBookImportNotice { bookImportAlertWindowID = activeWindowState.id } }
    }
    /// What each book added on this Mac is doing while it reads as one
    /// entry, by book id, for its row: its details, a scan's text, its
    /// chapters (`finishBookImport`). Absent once the book is finished.
    var finishingBookStatus: [String: String] = [:]
    /// The run finishing books in the background, while one goes.
    @ObservationIgnored var bookImportFinishRun: Task<Void, Never>?
    /// A book joined the queue while the run went: it looks again at the end.
    @ObservationIgnored var bookImportFinishRequested = false
    /// Bulk Zotero/Paperpile import is catalog-first: this progress covers the
    /// fast inventory/copy pass while the normal serial paper queue handles the
    /// expensive ingestion work afterward.
    var isImportingReferenceLibrary = false
    var referenceLibraryImportStatus: String?
    /// The same catalog-first shape for a read-later app's export (Readwise
    /// Reader, Instapaper, Pocket, Raindrop, Omnivore): rows land at once, and
    /// the serial initial-fetch queue reads them afterwards.
    var isImportingReadLaterExport = false
    var readLaterImportStatus: String?
    var errorMessage: String?
    /// Local discovery warnings stay scoped to the integration that produced
    /// them. A successful browser scan must not erase a Podcasts access error
    /// (or vice versa) merely because the other integration refreshed later.
    var browserDiscoveryWarnings: [String] = []
    var podcastDiscoveryWarnings: [String] = []
    var discoveryWarnings: [String] {
        browserDiscoveryWarnings + podcastDiscoveryWarnings
    }
    /// Whether Apple Podcasts discovery failed due to missing folder access.
    var needsPodcastAccess = false
    var hiddenPodcastShows: Set<String> = []
    /// Bumped when the followed-show list changes, so views reading
    /// `isPodcastShowFollowed` re-render; the list itself lives in the
    /// preference store.
    var followedPodcastShowsVersion = 0
    /// The same, for the blocked-show list: bumped when a show is blocked or
    /// let back in, so `isPodcastShowBlocked` readers re-render.
    var blockedPodcastShowsVersion = 0
    var hiddenPodcastEpisodeIDs: Set<String> = []
    var visiblePodcastEpisodeOverrideIDs: Set<String> = []
    /// Canonical show names whose future transcript recovery should begin on
    /// YouTube instead of repeating an Apple lookup the learner knows will fail.
    var podcastYouTubeFallbackShows: Set<String> = Set(
        Preferences.value(Prefs.Discovery.youtubeFallbackShows) ?? []
    )
    /// YouTube uploader names hidden by the learner. Loaded from the synced
    /// `hidden_youtube_channels` table so future imports stay hidden too.
    var hiddenYouTubeChannels: Set<String> = []
    var visibleYouTubeVideoOverrideIDs: Set<String> = []
    /// Whether browser reading list discovery failed due to missing folder access.
    var needsBrowserAccess = false
    /// Access grants are local to one signed app copy. Keep dismissal local too:
    /// syncing it would hide a real warning on another Mac with different TCC
    /// state. Dismissal is durable because intermittent local reads must not
    /// resurrect a warning the learner already chose to hide.
    var browserAccessPromptDismissed = (Preferences.value(Prefs.Discovery.browserAccessPromptDismissed) as? Bool) ?? false
    var podcastAccessPromptDismissed = (Preferences.value(Prefs.Discovery.podcastAccessPromptDismissed) as? Bool) ?? false
    /// Groups of biorxiv papers with multiple versions saved (same DOI base, different vN).
    /// Each element is (title, newerID, olderIDs) — user can tap "Fix" to keep only the latest.
    var paperVersionConflicts: [(title: String, newerID: String, olderIDs: [String])] = []

    /// Latest review date per source. A source is reviewed after a completed
    /// review session, a linked external review session, or a completed
    /// Schedule item.
    var sourceReviewedAt: [String: Date] = [:]
    var sourceReviewFilter: SourceReviewFilter {
        get { sidebarStore.sourceReviewFilter }
        set { sidebarStore.sourceReviewFilter = newValue }
    }
    var sourceReadFilter: SourceReadFilter {
        get { sidebarStore.sourceReadFilter }
        set { sidebarStore.sourceReadFilter = newValue }
    }
    var sourceContentFilter: SourceContentFilter {
        get { sidebarStore.sourceContentFilter }
        set { sidebarStore.sourceContentFilter = newValue }
    }
    var sourceCardFilter: SourceCardScope {
        get { sidebarStore.sourceCardFilter }
        set { sidebarStore.sourceCardFilter = newValue }
    }
    var podcastSortMode: PodcastSortMode = PodcastSortMode(rawValue: Preferences.value(Prefs.Studio.podcastSortMode) ?? "") ?? .date {
        didSet {
            Preferences.set(podcastSortMode.rawValue, for: Prefs.Studio.podcastSortMode)
            resetDisplayLimits()
        }
    }
    var videoSortMode: VideoSortMode = VideoSortMode(rawValue: Preferences.value(Prefs.Studio.videoSortMode) ?? "") ?? .liked {
        didSet {
            Preferences.set(videoSortMode.rawValue, for: Prefs.Studio.videoSortMode)
            resetDisplayLimits()
        }
    }
    /// By series or by date, in the window in scope (`StudioSidebarStore`):
    /// one window's Meetings list re-ordered leaves another's as it was.
    var meetingListOrder: MeetingListOrder {
        get { sidebarStore.meetingListOrder }
        set {
            guard newValue != sidebarStore.meetingListOrder else { return }
            sidebarStore.meetingListOrder = newValue
            resetDisplayLimits()
        }
    }
    var reviewSessionLinks: [ReviewSessionRecord] = [] {
        didSet {
            reviewSessionLinksRevision &+= 1
            rebuildReviewSessionIndex()
        }
    }
    /// Cache keys for the filtered/grouped chat runs below. The rail's body
    /// re-evaluates on every chat click and every generation-state flip, and
    /// re-sorting the full history each time was measurable click latency.
    @ObservationIgnored var reviewSessionLinksRevision: UInt = 0
    @ObservationIgnored var chatOrderRevision: UInt = 0
    @ObservationIgnored var cachedFilteredReviewSessions:
        (key: FilteredReviewSessionsCacheKey, sessions: [ReviewSessionRecord])?

    struct FilteredReviewSessionsCacheKey: Equatable {
        let linksRevision: UInt
        let chatOrderRevision: UInt
        let filter: ReviewSessionFilter?
        let transcriptMatchIDs: Set<String>?
        let search: String
        /// Screen record mode hides everything outside its scope, and it is
        /// neither a link change nor an order change — so leaving the mode
        /// moved nothing this key was watching and the rail kept serving the
        /// filtered run, still hiding every chat from before the recording.
        let screenRecordScope: ScreenRecordScope?
    }
    @ObservationIgnored var reviewSessionsBySourceID: [String: [ReviewSessionRecord]] = [:]
    var reviewSessionExchanges: [String: [ReviewExchangeRecord]] = [:]
    /// Session IDs whose transcript content matches the current sessions-panel
    /// search. Nil when the query is too short to search transcript text.
    var reviewTranscriptMatchIDs: Set<String>?
    var preloadedDailyReviewPlans: [String: DailyReviewPlan] = [:]
    @ObservationIgnored var preloadedDailyReviewPlanDay: String?
    /// Preloaded global retention queue for the Review Chat empty state. The
    /// storage actor computes it; views only read this small immutable snapshot.
    var memoryCompanionPlan: MemoryCompanionPlan?
    @ObservationIgnored var memoryCompanionPlanDay: String?
    var learningGoals: [LearningGoalRecord] = [] {
        didSet {
            learningGoalsRevision &+= 1
            preloadedDailyReviewPlans = [:]
            preloadedDailyReviewPlanDay = nil
            scheduleInputsRevision &+= 1
            // The recording Notebook's sources are the scope's allow-list.
            refreshScreenRecordScope()
            // The Sources sidebar's notebook marks.
            refreshNotebookSidebarIndex()
        }
    }
    /// Whether `learningGoals` has been read from the store once. Until then
    /// an empty list means "still reading", and a window that came back from
    /// a relaunch holding a notebook keeps it (`closeNotebooksMissingFromLibrary`).
    var hasLoadedLearningGoalsOnce = false
    /// Bumped on every change to `learningGoals`, so the notebook lists
    /// derived from it (`notebookLists`) tell in one comparison whether they
    /// still hold. Not observed: a view depends on `learningGoals` itself,
    /// which `currentNotebookListsKey` still reads.
    @ObservationIgnored private(set) var learningGoalsRevision = 0
    @ObservationIgnored var notebookListsCache: NotebookLists?
    @ObservationIgnored var notebookHoldingContextCache: NotebookHoldingContext?
    /// The Ideas tab's list, newest first, archived included: the learner's
    /// own thoughts and what each is linked to (docs/ideas-design.md).
    var ideas: [IdeaRecord] = []
    /// Whether the Ideas list has been read once, so a row that resolves a
    /// link can ask for it before drawing nothing.
    @ObservationIgnored var hasLoadedIdeasOnce = false
    /// Every Direction a search proposed, with the learner's answers
    /// (docs/directions-design.md). Read whole and filtered per home: a
    /// library holds tens of them, not thousands.
    var researchDirections: [ResearchDirection] = []
    @ObservationIgnored var hasLoadedResearchDirectionsOnce = false
    /// Bumped whenever the schedule or the goals change. Observable on purpose:
    /// a view that hits the `unifiedScheduleDays` memo reads this instead
    /// of walking `scheduledSources`, and it is this read that keeps the view
    /// subscribed to schedule changes.
    private(set) var scheduleInputsRevision = 0
    /// Memo for `unifiedScheduleDays`, keyed on everything it reads. Not
    /// observed: it is written from view bodies.
    @ObservationIgnored var unifiedScheduleDaysCache: (key: ScheduleDaysCacheKey, days: [ScheduleDay])?
    /// Local projections over each Notebook's iCloud Drive workspace, keyed by
    /// Notebook id. The StorageService actor performs every scan and file read.
    var notebookFilesByNotebookID: [String: [NotebookFileRecord]] = [:]
    var notebookFileRefreshesInFlight: Set<String> = []
    @ObservationIgnored var notebookFilesLastRefreshAt: [String: Date] = [:]
    /// Canonical Markdown artifacts are global; Notebook membership is carried
    /// on each record and never creates per-Notebook copies.
    var artifacts: [ArtifactRecord] = []
    /// The pages being written, as the Planner's log last heard of them: a
    /// save tells the log at most once a minute (`saveArtifactMarkdown`).
    @ObservationIgnored var pageWritingMinutes = DayActivityMinuteGate()
    /// The teams each My Library artifact is in, keyed by artifact id — a
    /// team's own record, or a personal original a team holds a copy of —
    /// for the Docs tab's team filter. Empty in a team library.
    var artifactTeamIDs: [String: Set<String>] = [:]

    /// The Canvas of the window in scope, else of the key window: the whole
    /// library on one zoomable plane, the learner's layout of it, and the
    /// lens a chat may show over it (docs/knowledge-map-design.md). Each
    /// window has its own (`StudioWindowState.canvasIfMade`), so a canvas
    /// opened or a view changed in one window leaves the others as they were;
    /// a command, the voice assistant and MCP act on the key window's. A view
    /// reads its own window's with `knowledgeMap(in:)`.
    var knowledgeMap: KnowledgeMapModel {
        get { knowledgeMap(in: activeWindowState) }
        set { setKnowledgeMap(newValue, in: activeWindowState) }
    }

    /// Every canvas the learner has, as the Space lists them
    /// (`KnowledgeMapCanvases`), reseeded from the rows after each act and
    /// each remote change.
    var canvases = KnowledgeMapRows.canvases()

    /// The Atlas pane of the window in scope, else of the key window: the
    /// Atlas on screen, its focus, level and what is being written
    /// (docs/atlas-design.md). Each window has its own
    /// (`StudioWindowState.atlas`); a view reads its own window's.
    var atlas: AtlasModel { activeWindowState.atlas }

    // MARK: - Teams

    /// The library the Studio shows: nil is My Library, otherwise a team's id.
    /// One library at a time; switching reloads sources, Notebooks, Docs and
    /// chats for that namespace. Persisted so a relaunch reopens the same one.
    var activeTeamID: String? = {
        let raw = Preferences.value(Prefs.Studio.activeTeamID)
        return raw?.isEmpty == false ? raw : nil
    }() {
        didSet {
            Preferences.set(activeTeamID ?? "", for: Prefs.Studio.activeTeamID)
            // Which team's courses the Courses home lists depends on it.
            allCourseGroupNamesCache = nil
            visibleCourseGroupNamesCache = nil
        }
    }
    static let activeTeamPreferenceKey = Prefs.Studio.activeTeamID.name
    /// Every team this account owns or joined, for the switcher and the menus.
    var teams: [TeamRecord] = []
    /// The Docs shared through a Doc space, by Doc id: the ones this account shares and the ones
    /// shared with it (`refreshSharedDocs`). A menu reads it; nothing here touches iCloud.
    var sharedDocs: [String: SharedDocState] = [:]
    /// The roster of each team, keyed by team id, as last read from its share.
    var teamMembersByTeamID: [String: [TeamMemberRecord]] = [:]
    /// Task boards, keyed by Notebook id, loaded when a Notebook page opens.
    var notebookTasksByNotebookID: [String: [NotebookTaskRecord]] = [:]
    /// Each board's own lists, keyed by Notebook id, loaded with its tasks.
    var notebookTaskListsByNotebookID: [String: [NotebookTaskList]] = [:]
    /// What other members have assigned to this account, in every team
    /// (docs/family-design.md), for the Today panel's Assigned section.
    var assignedToMe: [AssignedTask] = []
    /// Each editable team's members other than this account, read from the
    /// stored roster, for the Assign to menu in any library.
    var assignableMembersByTeamID: [String: [TeamMemberRecord]] = [:]
    /// Open requests for sources this Mac can answer: an editable team asked
    /// for something My Library holds (docs/teams-design.md, decision 14).
    var fulfillableShareRequests: [StorageService.FulfillableShareRequest] = []
    /// Every open request, by team, for the cards on a team Doc to show as
    /// Requested.
    var openShareRequestsByTeamID: [String: [ShareRequestRecord]] = [:]
    var isLoadingArtifacts = false
    /// Whether the first artifacts read has finished, so an empty list means
    /// "no docs" rather than "not loaded yet" and views can hold their empty
    /// states until they'd be telling the truth.
    var hasLoadedArtifactsOnce = false
    /// Every page this account has published on foreverlm.com, by doc id.
    /// Server state, refreshed by `refreshPublishedDocStatuses` when a Docs or
    /// Sites canvas appears and updated in place by a publish or unpublish, so
    /// the Docs list's Published badges and filter are one answer for every
    /// canvas. Empty while signed out or offline, which shows every doc as
    /// unpublished. It never decides a section: a published doc is a Doc.
    var publishedDocStatuses: [String: PublishedDocStatus] = [:]
    /// Today's cards and the cards to check across every notebook
    /// (`refreshMemoryCardState`): what the Memory row's help says (`.line`,
    /// "6 due · 4 new · 9 to check") and the reminder follows. Zero once read means nothing is
    /// waiting.
    var memoryCardCounts: MemoryCardDayCounts = .zero
    /// The cards waiting in To Check on each source, by source id, from the
    /// same read: what the Reader's toolbar says ("Cards · 9 to check").
    var memoryCardsToCheckBySource: [String: Int] = [:]
    /// Advances when a card review ends, a card is kept, skipped, edited,
    /// retired or started over, and when another device or an assistant
    /// changed the library, so the Memory pane and a notebook's Cards row read
    /// their numbers again.
    var memoryCardRevision = 0
    /// The cards drafted in the background that wait in To Check, from the
    /// counts' one read (`CardsToCheckNudge.pile`): what the "Cards to check"
    /// corner card says. Nil when none wait.
    var cardsToCheckPile: CardsToCheckNudge.Pile?
    /// Every source that can have cards and how many it has, from one
    /// set-based read (`StorageService.sourceCardCoverage`): the Library
    /// rows' card counts, their verdicts and the No Cards pill
    /// (`refreshSourceCardCoverage`). Empty until the Library first asks.
    var sourceCardCoverage = SourceCardCoverage()
    /// Advances with each change to `sourceCardCoverage`, for the sidebar
    /// filter cache's key while the No Cards pill is on.
    var sourceCardCoverageRevision = 0
    /// The inputs the coverage was last read for (`refreshSourceCardCoverage`).
    @ObservationIgnored var sourceCardCoverageKey: String?
    /// Candidates this Mac's last background run left for another day,
    /// named on the corner card ("2 more sources to come").
    var cardsToCheckWaiting = 0
    /// This Mac put the corner card off today (×, or Go Through Them).
    /// Read again with the counts, so a new day, which every activation
    /// reads them on, brings the card back.
    var cardsToCheckIsPutOff = CardsToCheckNudge.putOffDay() == MemoryReviewGoal.dayKey(for: Date())
    /// Sources finished on this Mac whose ideas and cards wait for the one
    /// drain that drafts them (`sourcesWereFinished`): a bulk Mark as Read
    /// or a second window's notice of the same finish joins the batch rather
    /// than starting a read of its own.
    @ObservationIgnored var finishedSourceIDsAwaitingDrafting: Set<String> = []
    @ObservationIgnored var finishedSourcesDrainTask: Task<Void, Never>?
    /// Windows whose card review is being read before it takes them, so a
    /// second click does not start a second one.
    @ObservationIgnored var startingCardSittingWindowIDs: Set<UUID> = []

    /// Shared calendar placements (one per scheduled source) with their goal tags.
    /// Drives the unified Schedule calendar across all plain goals.
    var scheduledSources: [ScheduledSourceEntry] = [] {
        didSet {
            completedSourceActivityKinds = scheduledSources.reduce(into: [:]) { result, entry in
                result[entry.placement.sourceID] = entry.activityDays.reduce(into: Set<SourceActivityKind>()) {
                    $0.formUnion($1.completedKinds)
                }
            }
            scheduleInputsRevision &+= 1
            invalidateSidebarCachesInEveryWindow()
        }
    }
    /// Render-path lookup for consumed modality. Rebuilt once when the Schedule
    /// snapshot changes so source rows never scan the entire Schedule in `body`.
    @ObservationIgnored var completedSourceActivityKinds: [String: Set<SourceActivityKind>] = [:]
    var learningGoalLinkedSourceIds: Set<String> = []
    var learningGoalEligibleSourceIds: Set<String> = []
    /// When non-nil, the Review Sessions panel only shows sessions linked to this filter.
    var reviewSessionFilter: ReviewSessionFilter?
    /// Session ID requested by another panel to resume in the Chat window.
    var reviewChatResumeSessionID: String? {
        didSet { if reviewChatResumeSessionID != nil { stampChatRequestTargetWindow() } }
    }
    /// Token used to ask the Chat panel to discard the visible conversation and show a fresh draft.
    var reviewChatResetRequestID: UUID? {
        didSet { if reviewChatResetRequestID != nil { stampChatRequestTargetWindow() } }
    }
    /// The Studio window whose Chat pane the pending chat requests are for.
    /// Every window's primary Chat pane watches the same request tokens, so
    /// without this the first pane to run its task consumed a New chat or an
    /// open-chat request made in another window: the fresh chat appeared over
    /// there and the window the click was made in showed nothing. Stamped
    /// whenever a request token is set, by `stampChatRequestTargetWindow()`,
    /// which starts from the window in scope — the key window, or the one an
    /// `inWindow` scope names — and read by
    /// `chatPaneAcceptsGlobalRequests(ownerWindowID:)`.
    var reviewChatTargetWindowID: UUID?
    /// Where the chat request just stamped will show when that is not the
    /// window it was made in — "the other ForeverLM window" or "another
    /// ForeverLM window" — and nil when it shows in place. The stamp raises the
    /// generic toast from it; a requester with a toast of its own ("Selection
    /// added to Chat") folds it into that message instead, so the learner is
    /// never told where the chat went by a banner that is immediately replaced.
    @ObservationIgnored var chatRequestElsewhereNotice: String?
    /// Notebook the next fresh chat should link to (set by the rail's per-notebook
    /// new-chat button). Consumed alongside `reviewChatResetRequestID`; nil means
    /// the fresh chat starts unlinked.
    @ObservationIgnored var pendingReviewChatNotebookID: String?
    /// The `reviewChatResetRequestID` of a fresh chat that reads its notebook's
    /// ticked sources as they stand, with nothing written until the learner
    /// acts in it: a notebook opening in a window starts its chat this way,
    /// because opening is a read and seeding the chat's context
    /// (`setContextSources`) is a synced write. Matched against the token, so
    /// any later chat request — a new token — is an ordinary one.
    @ObservationIgnored var pendingNotebookChatRequestID: UUID?
    /// Text the next fresh chat should open with in its composer, unsent (set by the
    /// Notebook inspector's new-goal button). Consumed alongside `reviewChatResetRequestID`;
    /// nil means the fresh chat starts with an empty composer.
    @ObservationIgnored var pendingReviewChatDraft: String?
    /// The Board card the fresh chat was started from; the chat links itself to
    /// it on the first send (`requestBoardCardChat`). Consumed with the draft.
    @ObservationIgnored var pendingReviewChatTaskID: String?
    /// The day-planning line, when that is the draft waiting: its rules go with
    /// the send as a hidden skill (`ReviewSlashCommandParser.planDaySkill`). A
    /// draft that is anything else leaves it unmatched and unarmed.
    @ObservationIgnored var pendingPlanDayDraft: String?
    /// The questions the next fresh chat offers in its empty state, set when
    /// the chat is opened from the Canvas (`openChatBesideKnowledgeMap`) and
    /// consumed alongside `reviewChatResetRequestID`; empty for every other
    /// chat.
    @ObservationIgnored var pendingReviewChatCanvasQuestions: [String] = []
    /// The flashcard the next fresh chat is about (Ask in Chat on a card to
    /// check), consumed alongside `reviewChatResetRequestID`; nil for every
    /// other chat.
    @ObservationIgnored var pendingReviewChatCard: ChatContextAdditions.CardOnScreen?
    /// The mode the next fresh chat opens in, when the request names one: a
    /// notebook Studio's Deep research opens a Deep Research chat
    /// (`requestNotebookDeepResearch`). Consumed alongside
    /// `reviewChatResetRequestID`; nil keeps the fresh chat's own mode.
    @ObservationIgnored var pendingReviewChatMode: ReviewSessionManager.InitialPromptMode?
    /// Token used to ask the Chat panel to immediately start from current context.
    var reviewChatAutoStartRequestID: UUID? {
        didSet { if reviewChatAutoStartRequestID != nil { stampChatRequestTargetWindow() } }
    }
    /// Token used by ⇧⌘K to focus the docked Chat composer without stealing focus at launch.
    var reviewChatFocusRequestID: UUID? {
        didSet { if reviewChatFocusRequestID != nil { reviewChatFocusWindowID = activeWindowState.id } }
    }
    /// The window whose chat box that token focuses: the one it was asked in.
    @ObservationIgnored var reviewChatFocusWindowID: UUID?
    /// Token used by Reader "Chat about this" actions to let the Studio shell
    /// reclaim side-panel width after the Reader and Chat panes are visible.
    /// Width belongs to the view, so the view model only publishes the intent.
    var readerChatSpaceRequestID: UUID? {
        didSet { if readerChatSpaceRequestID != nil { readerChatSpaceWindowID = activeWindowState.id } }
    }
    /// The window that makes that room: the one the chat was asked for in.
    @ObservationIgnored var readerChatSpaceWindowID: UUID?
    /// Token used to ask the Chat panel to reveal the previous-sessions browser
    /// (opens the popover in `.popover` layout). Consumed by the Chat panel.
    var reviewSessionsRevealRequestID: UUID? {
        didSet { if reviewSessionsRevealRequestID != nil { stampChatRequestTargetWindow() } }
    }
    /// A review the Chat panel should start instead of the default context. `goalID`
    /// is set for a Learning Companion review (links the session to the goal) and nil
    /// for a goal-agnostic global memory refresh. Optional `rationale` seeds the tutor
    /// with today's daily-review focus.
    @ObservationIgnored var pendingCompanionReview: MemoryCompanionRequest?
    /// The Memory row asked for today's review and it does not exist yet: the
    /// day's session id and its assembled material, consumed by the Chat
    /// panel's auto-start.
    @ObservationIgnored var pendingMemoryReview: MemoryReviewRequest?
    /// A course quiz row asked to take its quiz: the quiz and its grader,
    /// consumed by the Chat panel's auto-start (`takeCourseQuiz`).
    @ObservationIgnored var pendingCourseQuiz: CourseQuizChatRequest?
    /// Generate in the Courses tab asked for a course-planning chat
    /// (`CoursePlanningChat`), consumed by the Chat panel's auto-start.
    @ObservationIgnored var pendingCoursePlanningChat = false
    /// The notebook a course-planning chat was asked from (its Studio's
    /// Course tile): the chat is filed there and reads its ticked sources,
    /// so the course it makes lives there (docs/notebooks-design.md,
    /// "Homing"). Nil for Generate in the Courses tab, which plans in no
    /// notebook. Consumed with `pendingCoursePlanningChat`.
    @ObservationIgnored var pendingCoursePlanningNotebookID: String?
    /// Reader or Docs selection requested as the next focus in Chat. Docs
    /// requests are paired with a reset token so they always enter a fresh chat.
    /// Stamped like the request tokens: the panes gate on the stamped window,
    /// so a selection left unstamped would go to whichever window made the
    /// previous request rather than the one the text was selected in.
    var readerSelectionExplanationRequest: ReaderSelectionExplanationRequest? {
        didSet { if readerSelectionExplanationRequest != nil { stampChatRequestTargetWindow() } }
    }
    /// Bumped when a chat records the doc passage it started on, so a Doc open
    /// beside that chat redraws its Discussion sidebar the moment the question
    /// is sent. An event rather than a poll: nothing else writes these links.
    var artifactChatLinksRevision = UUID()
    /// A doc the Notepad canvas should select, so a chat can walk back to the
    /// doc it came from. Carries a token so asking twice for the same doc is
    /// two requests and the canvas re-runs the selection.
    var artifactRevealRequest: ArtifactRevealRequest?
    /// A page the Browser pane should open in a new tab. Set by
    /// `openInBrowser(_:)`; the pane consumes it once it is showing.
    var browserOpenRequest: BrowserOpenRequest?
    /// The DOI a loaded web page declared about itself, by the page's
    /// normalized address; written by `notePageDeclaredIdentity`. What lets
    /// `librarySourceID(forURL:)` recognise a saved paper behind an index
    /// page whose address names only its own record. Observable, so a Reader
    /// or Browser toolbar over the page flips to View in Sources when the
    /// page has finished saying which paper it is.
    var pageDeclaredDOIs: [String: String] = [:]

    /// Set by the rail's Docs row: the canvas answers by listing every doc,
    /// with none open. Consumed by the global Docs canvas.
    var artifactIndexRequest: ArtifactIndexRequest?
    /// The Videos pane should select this film — set when one finishes.
    var explainerVideoRevealRequest: ExplainerVideoRevealRequest?
    /// The Videos pane should open its composer with these fields — a source's
    /// menu asking for a video about the source.
    var explainerVideoComposeRequest: ExplainerVideoComposeRequest?
    /// The Ideas pane should open this Idea in its editor: a link to it was
    /// followed (`openIdea`). Consumed by the pane of the window it names.
    var ideaRevealRequest: IdeaRevealRequest?
    /// A whole Doc the Chat panel should attach to the conversation it is
    /// already showing. Unlike a selection handoff this is additive and never
    /// resets the chat, so it carries no reset token. Consumed by the panel
    /// that accepts global requests, which is why it is stamped like the
    /// request tokens.
    var pendingChatDocAttachment: ChatDocAttachment? {
        didSet { if pendingChatDocAttachment != nil { stampChatRequestTargetWindow() } }
    }
    /// Cards of the open canvas the Chat panel should take into its canvas
    /// context (Add to Chat, Ask in Chat; `KnowledgeMapChatCards`). Consumed as
    /// `pendingChatDocAttachment` is: by the panel that accepts global requests
    /// in the window they name, additively to the conversation it shows, or,
    /// when a fresh chat was asked for with them, as that chat starts.
    var pendingChatCanvasCards: KnowledgeMapChatCards? {
        didSet { if pendingChatCanvasCards != nil { stampChatRequestTargetWindow() } }
    }
    /// The current reader text selection, if any. Read imperatively by the ⇧⌘K
    /// handler; no view observes it, so it stays observation-ignored to avoid
    /// invalidating views on every selection change.
    @ObservationIgnored var activeReaderSelection: ReaderChatSelection?
    /// The passage highlighted on a Page, which a chat beside that Page shows
    /// as its quote (`PageSelectionQuote`). Observed only by the chat panel's
    /// small mirror view, so a moving highlight never re-renders the pane.
    var livePageSelection: LivePageSelection?

    /// A Page's editor reporting its highlight; an empty one clears that
    /// Page's, never another Page's.
    func notePageSelection(_ text: String, artifactID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if livePageSelection?.artifactID == artifactID { livePageSelection = nil }
            return
        }
        let next = LivePageSelection(artifactID: artifactID, text: trimmed)
        if livePageSelection != next { livePageSelection = next }
    }
    /// The pictures each web reader last reported inside its selection, by
    /// source ID. Readers report their words through a text binding that
    /// predates pictures and re-reports on every change; keeping the pictures
    /// here lets that text-only report keep them rather than clear them.
    /// Observed: the reader's context menu and Chat pill read it.
    var readerSelectionImages: [String: [ReaderSelectionImage]] = [:]

    /// Highlights and notes for every source the reader has opened this
    /// session, keyed by source ID. Loaded lazily when a source opens; readers
    /// observe their own entry to know what to paint.
    var readerHighlights: [String: [SourceHighlight]] = [:]
    /// Every mark in the library set aside to follow up or doubt, as the
    /// Library's Follow up list reads them (`FollowUpList`). Loaded when the
    /// Library opens, then kept in step with color changes and removals made
    /// in the Reader; `followUpMarksLoaded` is false until the first read.
    var followUpMarkStore: [FollowUpMark] = []
    var followUpMarksLoaded = false
    /// Whether the Reader's Clip tool is on in a PDF, so the ⋯ menu's item
    /// reads Stop Clipping (`ReaderClipTool`).
    var readerClipToolIsOn = false
    /// Moves when a clip is saved, changed or removed here, so the Canvas
    /// reads its cards again (`knowledgeMapContentSignature`).
    var knowledgeMapClipRevision = 0
    /// The mark whose card is open, if any. Set by a reader when the Highlight
    /// pill marks a passage or an existing mark is clicked, and by the notes
    /// list when a row is opened for editing.
    var readerHighlightCard: ReaderHighlightCard?
    /// The side chat open over words selected in the Reader, if any. Set by
    /// the selection bar's Side chat; only the popover's X, or the next side
    /// chat, takes it down.
    var readerSideChat: ReaderSideChat?
    /// Whether the reader is showing its notes list alongside the source.
    var readerNotesListVisible = false
    /// Walk Through was pressed on a source: the chat pane beside the Reader
    /// takes the request and plays the source's walkthrough
    /// (walkthrough-design.md, "the panel becomes a chat"). Stamped like every
    /// other chat request: every window's primary Chat pane watches this
    /// revision, so without the stamp the pane in the other window could take
    /// the walk — the window the button was pressed in then merely revealed
    /// whatever conversation it already had, which is the one thing Walk
    /// Through must never join.
    var readerWalkthroughPlayRequest: ReaderWalkthroughPlayRequest? {
        didSet { if readerWalkthroughPlayRequest != nil { stampChatRequestTargetWindow() } }
    }
    var readerWalkthroughPlayRequestRevision: UInt = 0
    /// The animation step a playing walkthrough is on: every pane showing
    /// that animation pins its page to it (walkthrough-design.md,
    /// "Animations are walked through"). Nil when no step shows one.
    var animationWalkFocus: AnimationWalkFocus?
    var animationWalkFocusRevision: UInt = 0
    /// The animations that have a walkthrough, current or stale, so their
    /// menus can offer Walk Through; refreshed with the artifacts.
    var artifactIDsWithWalkthroughs: Set<String> = []
    /// Bumped whenever a walkthrough is written, redrawn or removed, so a chat
    /// playing it reloads its steps without holding a copy of every walkthrough.
    var readerWalkthroughRevision: UInt = 0
    /// What the walkthrough's current step points at in the PDF: a figure to
    /// outline, a passage to mark, a page to show. Held while the step is
    /// current, unlike a citation's one-shot flash, and cleared when the chat
    /// playing the walk ends. See `ReaderWalkthroughFocus`.
    var readerWalkthroughFocus: ReaderWalkthroughFocus?
    var readerWalkthroughFocusRevision: UInt = 0
    /// Bumped whenever a mnemonic reading's questions change (a source's
    /// landed, a reading was removed), so the PDF Reader draws the questions
    /// of the readings grounded on its source again.
    var readerQuestionsRevision: UInt = 0
    /// Where a click on a Find it panel in the Reader goes: the chat playing
    /// the walk whose question it answers (walkthrough-design.md, "one
    /// point a card"). Set when a Find it card points the page.
    @ObservationIgnored var readerPanelPickHandler: (@MainActor (_ sourceID: String, _ panel: String) -> Void)?
    /// Bumped whenever a source's cited-paper candidates change — a scan
    /// finished, a candidate was imported, dismissed or restored — so a reader
    /// control showing them reloads without holding a copy of every list.
    var citedPapersRevision = 0
    /// What the last read of a paper's reference list is doing or did, keyed by
    /// source id. The cited-papers panel shows this in its header, where the
    /// learner who asked for the read is looking; a read started from the
    /// sidebar, with no panel open, reports the same words as a toast instead.
    var citedPaperScanReports: [String: CitedPaperScanReport] = [:]

    // URL input
    var urlInput: String = ""

    /// How many items to show in the sidebar (incremented by "Show More")
    var displayLimit: Int {
        get { sidebarStore.displayLimit }
        set { sidebarStore.displayLimit = newValue }
    }
    var papersWithPDFDisplayLimit: Int {
        get { sidebarStore.papersWithPDFDisplayLimit }
        set { sidebarStore.papersWithPDFDisplayLimit = newValue }
    }
    var papersWithoutPDFDisplayLimit: Int {
        get { sidebarStore.papersWithoutPDFDisplayLimit }
        set { sidebarStore.papersWithoutPDFDisplayLimit = newValue }
    }
    var paywalledPapersDisplayLimit: Int {
        get { sidebarStore.paywalledPapersDisplayLimit }
        set { sidebarStore.paywalledPapersDisplayLimit = newValue }
    }

    /// Search/filter text for the sidebar
    var searchText: String {
        get { sidebarStore.searchText }
        set { sidebarStore.searchText = newValue }
    }

    /// Sources the strict indexed-content pass matched for the current `searchText`
    /// rather than by their metadata. Written by
    /// `refreshSidebarContentSearchMatches` and unioned into the rendered list.
    var contentSearchMatchIDs: Set<String> {
        sidebarStore.contentSearchMatchIDs
    }

    /// Filter articles by discovery origin (nil = show all)
    var articleOriginFilter: DiscoveryOrigin? {
        get { sidebarStore.articleOriginFilter }
        set { sidebarStore.articleOriginFilter = newValue }
    }

    /// Filter meetings by which provider they came from (nil = show all)
    var meetingProviderFilter: MeetingProvider? {
        get { sidebarStore.meetingProviderFilter }
        set { sidebarStore.meetingProviderFilter = newValue }
    }

    /// Which sidebar tab is selected
    var sidebarTab: StudioSidebarTab {
        get { sidebarStore.sidebarTab }
        set { sidebarStore.sidebarTab = newValue }
    }

    /// Tabs hidden by the user (synced across devices via iCloud KVS, with
    /// UserDefaults fallback), plus the integration tabs Studio unpins once for
    /// a library that shows no sign of using them.
    ///
    /// Seeded before `PreferenceStore.hydrateFromStore()` runs, so on a rebuild
    /// that lands in a fresh preferences container the stored value is not
    /// readable yet. Until it is, treat the integration tabs whose one-time
    /// unpin this container has no record of as unpinned: erring toward hidden
    /// costs a tab that reappears a moment later, while erring toward visible
    /// claims an integration is connected when nothing says so. Nothing is
    /// persisted from here — `didSet` does not run for a property initializer —
    /// so the learner's durable choice survives to be hydrated over this.
    var hiddenTabs: Set<StudioSidebarTab> = {
        let raw = Preferences.value(Prefs.Studio.hiddenTabs) ?? []
        let stored = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
        return stored.union(StudioViewModel.integrationTabUnpinState().pending)
    }() {
        didSet {
            let raw = Array(hiddenTabs.map(\.rawValue))
            Preferences.set(raw, for: Prefs.Studio.hiddenTabs)
        }
    }

    /// The integration tabs Studio unpinned on its own and the learner hasn't
    /// touched since. Only these are pinned back by `pinIntegrationTabsInUse()`,
    /// so an unpin the learner performed is never undone; both `showTab` and
    /// `hideTab` drop a tab from here, because either one makes the tab the
    /// learner's call from then on.
    ///
    /// Synced, like the applied marker it accompanies. It records *whose*
    /// decision each pinned tab was, and that has to travel with
    /// `studio.hiddenTabs` itself: kept device-local, a rebuild into a fresh
    /// preferences container forgot that the learner had unpinned Read AI or
    /// Zoom by hand and pinned both back as soon as their sources loaded.
    var autoUnpinnedIntegrationTabs: Set<StudioSidebarTab> = {
        let raw = (Preferences.value(Prefs.Studio.integrationTabsUnpinnedByDefault) as? [String]) ?? []
        return Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
    }() {
        didSet {
            Preferences.set(
                autoUnpinnedIntegrationTabs.map(\.rawValue).sorted(),
                for: Prefs.Studio.integrationTabsUnpinnedByDefault
            )
        }
    }

    /// Which integration tabs have already had their one-time unpin, and which
    /// are still owed one. Pure read, safe from a property initializer.
    static func integrationTabUnpinState() -> (applied: Set<String>, pending: [StudioSidebarTab]) {
        let applied = Set(
            Preferences.value(Prefs.Studio.integrationTabUnpinDefaultsApplied) ?? []
        )
        let pending = StudioSidebarTab.allCases.filter {
            $0.requiresIntegrationSetup && !applied.contains($0.rawValue)
        }
        return (applied, pending)
    }

    /// Unpins each integration tab exactly once per account.
    ///
    /// A brand-new library does not open with Google Drive, Read AI, Zoom and X
    /// already pinned, which would read as "these apps are set up" to someone who has
    /// connected nothing. Sources for those tabs can only arrive through an
    /// account sign-in or a registered ingest plugin, so the tab waits for
    /// evidence the integration is in use: `pinIntegrationTabsInUse()` pins one
    /// back as soon as the account connects, which is also what restores the tab
    /// bar for an existing library on the single launch this runs.
    ///
    /// Must run *after* `PreferenceStore.hydrateFromStore()`, never from a
    /// property initializer. The applied marker and the durable pin state both
    /// live in preferences, and a rebuild reaches this code with an empty
    /// `UserDefaults`: applying the default before hydration wrote a fresh
    /// container's guess straight over the learner's stored choice, in the same
    /// launch that then pinned the plugin tabs back.
    ///
    /// The applied marker is written whether or not the tab was actually
    /// unpinned, so no tab is unpinned twice and a learner who pins one back
    /// keeps it. Idempotent, and cheap to call again.
    func applyIntegrationTabUnpinDefaults() {
        let state = Self.integrationTabUnpinState()
        guard !state.pending.isEmpty else { return }

        var applied = state.applied
        var hidden = hiddenTabs
        var autoUnpinned = autoUnpinnedIntegrationTabs
        for tab in state.pending {
            applied.insert(tab.rawValue)
            guard !hidden.contains(tab) else { continue }
            hidden.insert(tab)
            autoUnpinned.insert(tab)
        }
        Preferences.set(
            applied.sorted(),
            for: Prefs.Studio.integrationTabUnpinDefaultsApplied
        )
        if autoUnpinned != autoUnpinnedIntegrationTabs {
            autoUnpinnedIntegrationTabs = autoUnpinned
        }
        if hidden != hiddenTabs {
            hiddenTabs = hidden
        }
    }

    /// User-defined tab ordering (synced across devices via iCloud KVS).
    /// Contains all tabs; new tabs added to the enum are placed automatically.
    var tabOrder: [StudioSidebarTab] = {
        let raw = Preferences.value(Prefs.Studio.tabOrder) ?? []
        return StudioSidebarTab.reconciledOrder(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
    }() {
        didSet {
            // Reconcile on assignment, not just at load. An inbound synced value
            // that names only a subset of the tabs would otherwise be adopted
            // verbatim and persisted here, permanently dropping the tabs it
            // omitted from the tab bar and from the overflow menu alike.
            // Persist the reconciled value rather than `tabOrder` itself: Swift
            // does not re-run an observer for an assignment made inside it, so
            // the write below must not depend on that assignment landing first.
            let reconciled = StudioSidebarTab.reconciledOrder(tabOrder)
            if reconciled != tabOrder { tabOrder = reconciled }
            Preferences.set(reconciled.map(\.rawValue), for: Prefs.Studio.tabOrder)
        }
    }

    /// Tabs visible in the sidebar, in the user's custom order.
    var visibleTabs: [StudioSidebarTab] {
        tabOrder.filter { !hiddenTabs.contains($0) }
    }

    /// Source families excluded from library-wide search and AI discovery.
    /// Records stay stored and their tabs remain independently pinnable, so a
    /// learner can keep a manually browsable plugin archive out of ambient
    /// knowledge results without losing it or changing the Sources panel.
    var excludedKnowledgeTabs: Set<StudioSidebarTab> = StudioSidebarTab.excludedKnowledgeTabs() {
        didSet {
            Preferences.set(
                Array(excludedKnowledgeTabs.map(\.rawValue)).sorted(),
                for: Prefs.Studio.excludedKnowledgeSourceTabs
            )
            sourceSearchResults.removeAll()
            readerSearchBestMatches.removeAll()
            hasSearchedSources = false
            let retainedContextIDs = contextSourceIds.filter { id in
                guard let article = articlesById[id] else { return false }
                return isSourceIncludedInKnowledge(article)
            }
            if retainedContextIDs != contextSourceIds {
                contextSourceIds = retainedContextIDs
            }
        }
    }

    /// Whether a source is part of what chat, search and reviews may draw on.
    /// Two things decide it: the per-tab knowledge exclusion, and a hidden
    /// podcast show or YouTube channel, which mutes its episodes for the AI as
    /// well as the list unless one is unhidden on its own. Hiding a single
    /// source is purely visual (product owner, 2026-09-11): a hidden episode, paper
    /// or book leaves the sources list and nothing else, so `isSourceHidden`
    /// is deliberately not consulted here — the sidebar applies it on its own.
    func isSourceIncludedInKnowledge(_ article: StudioArticle) -> Bool {
        isSourceIncludedInKnowledge(article, excludedTabs: excludedKnowledgeTabs)
    }

    /// The same answer for a given exclusion set, so a caller can ask what a
    /// family switch would do without writing the persisted preference that
    /// `excludedKnowledgeTabs` keeps in UserDefaults and the synced store.
    func isSourceIncludedInKnowledge(_ article: StudioArticle, excludedTabs: Set<StudioSidebarTab>) -> Bool {
        !isSourceCollectionHidden(article)
            && StudioSidebarTab.knowledgeTab(for: article).map(excludedTabs.contains) != true
    }

    /// Move a tab from one position to another in the tab bar.
    func reorderTab(from source: StudioSidebarTab, to destination: StudioSidebarTab) {
        guard source != destination,
              let fromIdx = tabOrder.firstIndex(of: source),
              let toIdx = tabOrder.firstIndex(of: destination) else { return }
        tabOrder.remove(at: fromIdx)
        tabOrder.insert(source, at: toIdx)
    }

    /// Book display titles keyed by stable book ID.
    var bookTitles: [String: String] = [:]

    /// Book subtitles keyed by stable book ID (persisted to books table in SQLite)
    var bookSubtitles: [String: String] = [:]

    /// Maps stable book ID → path to the full book PDF (for cover thumbnails)
    var bookCoverPaths: [String: String] = [:]

    /// Memoized "original EPUB for this book" results, keyed by stable book ID.
    /// The lookup enumerates the book's directory inside the iCloud container, and
    /// the sidebar's context menus ask for it while building rows, which beachballed
    /// on cold CloudDocs metadata. Renders read this through
    /// `cachedOriginalEPUBURL(forBookGroup:)`; misses resolve off-main and publish
    /// back here. The inner optional is the answer, so a group that genuinely has
    /// no EPUB is distinguishable from one not yet resolved.
    var bookEPUBURLs: [String: URL?] = [:]

    /// Book groups with an EPUB lookup already running, so a re-render mid-flight
    /// doesn't spawn a second one. Deliberately not observed: `cachedOriginalEPUBURL`
    /// touches it from a view body, and mutating observed state during a render is
    /// what SwiftUI warns about.
    @ObservationIgnored var epubURLResolutionsInFlight: Set<String> = []

    /// Book authors keyed by stable book ID (persisted to books table in SQLite)
    var bookAuthors: [String: String] = [:]

    /// Book editions keyed by stable book ID (persisted to books table in SQLite)
    var bookEditions: [String: String] = [:]

    /// Book kind/category keyed by stable book ID (e.g. "Textbook", "Personal Development")
    var bookKinds: [String: String] = [:]

    /// Currently selected book kind filter (nil = show all books)
    var selectedBookKind: String?

    /// User-defined course ordering for the Courses home (synced across devices via iCloud KVS).
    var courseOrder: [String] = {
        let raw = Preferences.value(Prefs.Studio.courseOrder) ?? []
        return raw.reduce(into: [String]()) { result, courseName in
            if !result.contains(courseName) {
                result.append(courseName)
            }
        }
    }() {
        didSet {
            allCourseGroupNamesCache = nil
            visibleCourseGroupNamesCache = nil
            let raw = courseOrder.reduce(into: [String]()) { result, courseName in
                if !result.contains(courseName) {
                    result.append(courseName)
                }
            }
            Preferences.set(raw, for: Prefs.Studio.courseOrder)
        }
    }

    /// User-created course IDs (persisted in UserDefaults). Auto-discovered courses
    /// don't need to be here — they're identified by sourceType/discoveryOrigin.
    var userCourseNames: Set<String> = {
        let arr = Preferences.value(Prefs.Studio.userCourseNames) ?? []
        return Set(arr)
    }()

    /// Course metadata keyed by stable course ID (persisted to SQLite in knowledge.db)
    var courseMetadata: [String: CourseMetadata] = [:] {
        didSet {
            invalidateCourseDerivedState()
        }
    }

    /// The team of each course that is a team's copy (`courses.team_id`,
    /// docs/teams-design.md, decision 21); a course of My Library has no
    /// entry. Which courses the Courses home lists depends on it.
    var courseTeamIDs: [String: String] = [:] {
        didSet {
            invalidateCourseDerivedState()
        }
    }

    /// The notebooks that follow each course (`notebook_course_links`), keyed by
    /// course; a course no notebook follows has no entry. A course lives in no
    /// notebook: following is the one optional tie between the two
    /// (docs/courses-design.md, "A course is its own thing"). Read with the
    /// course metadata and again after a link changes.
    var courseFollowerNotebookIDs: [String: [String]] = [:] {
        didSet {
            refreshScreenRecordShownCourses()
        }
    }

    /// Video playlist group metadata keyed by stable playlist group ID.
    var videoPlaylistMetadata: [String: VideoPlaylistMetadata] = [:]
    var refreshingVideoPlaylistIDs: Set<String> = []

    /// Each course's stored quizzes (schema 138), keyed by course ID, loaded
    /// with the outline (`refreshCourseOutline`).
    var courseQuizzesByCourse: [String: [CourseQuiz]] = [:]
    /// The latest sitting of each stored quiz, keyed by quiz ID, mirrored from
    /// the `courseQuiz.score.*` preference rows.
    var courseQuizScores: [String: LectureQuizScore] = LectureQuizScore.scoresFromDefaults(
        prefix: LectureQuizScore.courseQuizPreferenceKeyPrefix
    )
    /// Each quiz's latest sitting in a chat, keyed by quiz ID: which chat,
    /// and how far it got. A row with one under way reads "In progress"
    /// and Take Quiz picks that chat back up.
    var courseQuizSittings: [String: CourseQuizSittingProgress] = [:]
    /// Each quiz's newest finished sitting, keyed by quiz ID: the chat a
    /// click on a finished quiz opens to show its results.
    var courseQuizFinishedSittings: [String: CourseQuizSittingProgress] = [:]
    /// Courses whose quizzes are being written right now, with how far along.
    var courseQuizWritingProgress: [String: CourseQuizWritingProgress] = [:]
    /// Quizzes whose pictures are being drawn right now, by quiz ID.
    var courseQuizDrawingIDs: Set<String> = []
    /// The page units textbook readings name, by unit ID
    /// (docs/textbook-readings-design.md), reloaded with the outline.
    var courseSourceUnitsByID: [String: SourceUnit] = [:]
    /// Courses a textbook is being planned into right now, with the stage.
    var textbookReadingStages: [String: TextbookReadingStage] = [:]
    /// Courses whose lectures are being named from their content right now.
    var courseLectureNamingIDs: Set<String> = []
    @ObservationIgnored var courseSourceUnitsRefreshTask: Task<Void, Never>?

    /// Numbered lectures keyed by stable course ID. Course materials are attached
    /// through `courseLectureItemsByLectureId` rather than owned by the course.
    var courseLecturesByCourse: [String: [CourseSession]] = [:] {
        didSet {
            invalidateCourseDerivedState()
        }
    }
    var courseLectureItemsByLectureId: [String: [CourseLectureItem]] = [:] {
        didSet {
            invalidateCourseDerivedState()
        }
    }
    /// First-video artwork keyed by course ID, loaded from the persisted outline
    /// so archived lectures can still supply their course's cover.
    var courseCoverArtworkURLs: [String: String] = [:]

    /// Course names currently being organized by the LLM.
    var organizingCourseNames: Set<String> = []

    /// User-created meeting group IDs (persisted in UserDefaults).
    var userMeetingGroupNames: Set<String> = {
        let arr = Preferences.value(Prefs.Meetings.userGroupNames) ?? []
        return Set(arr)
    }()

    /// Recurring meeting metadata keyed by stable meeting group ID.
    var meetingMetadata: [String: MeetingMetadata] = [:]

    /// Sidebar tiles chosen per meeting folder, keyed by meeting group ID.
    ///
    /// Mirrors the `meetingFolder.image.*` preference rows into observable state:
    /// `UserDefaults` publishes nothing SwiftUI tracks, so a header reading it
    /// directly would keep the old icon until something else redrew the row.
    var meetingFolderImageURLs: [String: String] = StudioViewModel.meetingFolderImageURLsFromDefaults()
    var meetingArtifactsBySourceId: [String: [MeetingArtifact]] = [:] {
        didSet {
            MeetingRecordingAvailability.update(from: meetingArtifactsBySourceId)
        }
    }
    /// One on-device transcript job per meeting. The reader, paper discovery,
    /// and deep links can all request it; every caller joins the same task.
    @ObservationIgnored var meetingTranscriptTasks: [String: Task<Bool, Error>] = [:]

    /// Meeting sessions whose transcript is being generated right now. Observed,
    /// unlike `meetingTranscriptTasks`, because the sidebar rows and the reader
    /// both label the job while it runs — transcribing an hour of recording is
    /// long enough that a silent menu looks like nothing happened.
    var transcribingMeetingSourceIDs: Set<String> = []

    /// Meeting groups running a whole-folder transcript pass, so the group row
    /// can show one spinner for a run that spans many sessions.
    var transcribingMeetingGroupNames: Set<String> = []

    // MARK: - Panel Layout (persisted)

    /// Which Studio column is temporarily expanded to take over the layout.
    var expandedPanel: StudioExpandedPanel? = {
        guard let raw = Preferences.value(Prefs.Studio.expandedPanel) else { return nil }
        return StudioExpandedPanel(rawValue: raw)
    }() {
        didSet {
            if let expandedPanel {
                Preferences.set(expandedPanel.rawValue, for: Prefs.Studio.expandedPanel)
            } else {
                Preferences.reset(Prefs.Studio.expandedPanel)
            }
        }
    }

    /// Transient presentation state owned by the docked reader. Immersive video
    /// modes take a notebook's Studio column off screen rather than leaving a
    /// strip of it beside the player; exiting the mode puts it back as it was.
    var isDockedReaderImmersive: Bool {
        get { activeWindowState.isDockedReaderImmersive }
        set { activeWindowState.isDockedReaderImmersive = newValue }
    }
    /// The reader column stays closed until something is actually opened to
    /// read: every explicit open path (`selectArticle`, planned-item starts,
    /// search results) reveals it, and its toolbar/idle close button hides it
    /// again. Transient — a fresh launch always starts without it.
    var showReaderPanel = false
    var showSearchPanel: Bool = Preferences.value(Prefs.Studio.showSearchPanel) ?? true {
        didSet { Preferences.set(showSearchPanel, for: Prefs.Studio.showSearchPanel) }
    }

    /// Whether the docked Chat surface is on screen — i.e. the Chat tab is the
    /// active tab of its center group. Setting it reveals or leaves Chat.
    var isChatTabActive: Bool {
        get { activeCenterTabs.contains(.chat) }
        set {
            if newValue {
                activateCenterTab(.chat)
            } else {
                deactivateCenterTab(.chat)
            }
        }
    }

    /// The Mac's realtime voice workspace occupied the center while it was
    /// presented. Nothing sets this: the window clears it wherever it clears
    /// transient presentation.
    var isVoiceWorkspacePresented: Bool {
        get { activeWindowState.isVoiceWorkspacePresented }
        set { activeWindowState.isVoiceWorkspacePresented = newValue }
    }

    /// A Notebook whose source pool should open next, set by the journals
    /// banner and consumed by the notebook workspace once it shows that
    /// notebook, which unfolds its Sources column. Nil otherwise.
    var pendingNotebookSourcesRequestID: String?

    /// Each active Notebook's approved sources, named as the Sources list names
    /// them (`canonicalSourceID`): what the sidebar's notebook marks read.
    /// Reassigned only when it changes, so a goal reload that moves nothing
    /// republishes nothing (`refreshNotebookSidebarIndex`).
    var notebookMemberSourceIDsByNotebook: [String: Set<String>] = [:]
    /// Active Notebooks' titles, kept apart from their members: the Sources
    /// sidebar's body reads only this and its window's notebook id, so adding
    /// a row re-runs that row's mark and never re-diffs the List.
    var notebookTitlesByNotebook: [String: String] = [:]
    /// The team of each active team Notebook, apart from the titles for the
    /// same reason: the sidebar marks a notebook only in its own library
    /// (`sidebarNotebook(in:)`), without reading `learningGoals`.
    var notebookTeamIDsByNotebook: [String: String] = [:]
    /// Bumped each time any notebook's members change.
    var notebookMembershipRevision = 0

    /// Article shown in the second reader panel. Nil = shows same as primary.
    var secondaryReaderArticleId: String?

    /// Which subview is shown inside the docked Chat surface.
    var reviewChatPanelMode: ReviewChatPanelMode = .chat

    /// Whether the Reader is currently hosted by a separate window. This is
    /// transient window state: persisting it can hide the inline Reader after a
    /// quit or crash even though no separate Reader window is restored.
    var readerPoppedOut = false

    // MARK: - Per-Article Pending Card State

    /// Temporary toast message shown after actions like PDF download
    var toastMessage: String?
    /// The window the toast was raised in, which alone shows it
    /// (`isRequestTarget`). Set with the message, so not observed on its own.
    @ObservationIgnored var toastWindowID: UUID?

    /// What the toast's Undo button does, when the message reports something
    /// that can be taken back. Hiding a paper says "Hid <title>" and the same
    /// banner undoes it (product owner, 2026-09-18: "when i hide a paper and i get a
    /// popup message; that popup needs to allow me to undo it"). Nil for a
    /// plain notice, which renders no button. Cleared with the message.
    var toastUndo: (() async -> Void)?

    /// A second thing the toast can offer, when the message reports that
    /// something happened in a window other than the one the banner is read
    /// in: "Opened in the other ForeverLM window" carries Open here, which
    /// redoes the opening in whichever window the button was pressed in
    /// (product owner, 2026-09-19: "i need a button to show up to open it in this
    /// window instead"). Nil for a plain notice. Cleared with the message.
    var toastAction: StudioToastAction?

    /// Deferred destructive removals. The newest notice is rendered with an
    /// Undo button while its grace period is still open.
    var pendingDeletionNotices: [PendingDeletionNotice] = []

    @ObservationIgnored var pendingDeletionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingDeletionUndoActions: [UUID: () async -> Void] = [:]
    /// Observed, not ignored: the hidden-items footer reads them to leave a
    /// removal out of its count, and has to follow the window opening and
    /// closing. See `isSourceBeingRemoved`.
    var pendingDeletionSourceIDs: [UUID: Set<String>] = [:]
    var pendingDeletionKeys: [UUID: String] = [:]
    /// Sources a removal has taken off the sidebar whose Undo window has not
    /// opened yet: `removeSelected` hides every row with the click and drains
    /// the writes behind it, and only then registers the deferred deletion.
    /// Without this the footer read them as hidden items for that stretch.
    var sourceIDsBeingRemoved: Set<String> = []
    @ObservationIgnored var deletionGracePeriod: Duration = .seconds(10)

    /// Non-nil while a YouTube playlist/course import is in flight, driving the
    /// import's line in the Mac strip's work icon (`StudioWorkButton`). The import (playlist scrape → AI title
    /// cleanup → per-lecture insert) can run ~a minute before the course first
    /// appears in the sidebar, and would give the user no feedback at all without it.
    var playlistImportStatus: String?
    /// True once the learner has hidden the import's line for the import that
    /// is running (product owner, 2026-09-21: the "Fetching lecture transcripts…"
    /// pill sat over the chat he was reading; "this should be hidable"). It
    /// stays hidden through every later phase of that same import — a banner
    /// that came back at each phase would be worse than the one dismissed —
    /// and the next import starts with it showing again. Nothing is lost by
    /// hiding it: the course's own sidebar row spins until the import is done.
    var playlistImportBannerHidden = false
    /// Bumped to open the rail's AI popover (what is running now, what has
    /// run, the key and its limits): the button watches it.
    var aiUsageOpenRequest = 0 {
        didSet { aiUsageOpenWindowID = activeWindowState.id }
    }
    /// The window whose popover that opens: the one it was asked in.
    @ObservationIgnored var aiUsageOpenWindowID: UUID?
    /// The import banner's text, or nil when there is no import or the
    /// learner hid the banner for this one.
    var visiblePlaylistImportStatus: String? {
        playlistImportBannerHidden ? nil : playlistImportStatus
    }
    /// Courses whose lectures are being imported right now, by group name, so
    /// the course's own row spins where its item count will be (product owner,
    /// 2026-09-11: "when this is importing; it should show a spinning wheel
    /// on here"). The banner says what the import is doing; the row says
    /// which course it is doing it to.
    var importingCourseNames: Set<String> = []
    /// Course shells authored by Web Studio currently being expanded. Kept
    /// outside observation because only the drain's deduplication reads it.
    @ObservationIgnored var pendingWebCourseImportsInFlight: Set<String> = []
    @ObservationIgnored var pendingWebBookImportsInFlight: Set<String> = []
    @ObservationIgnored var pendingWebBookImportsAttempted: Set<String> = []

    /// Pending auto-dismissal for `toastMessage`, held so a new toast, the
    /// pointer resting on the current one, or the close button can cancel it.
    /// Ignored by observation: nothing renders from the handle itself.
    @ObservationIgnored var toastDismissTask: Task<Void, Never>?

    /// Debug alert for download diagnostics
    var showDebugAlert = false
    var debugAlertMessage = ""

    // MARK: - Domain Routing Rules (persisted)


    // MARK: - X Bookmarks State

    // Keychain lookup can block while macOS resolves an access prompt or an
    // unavailable vault. Publish a neutral launch snapshot, then refresh it
    // off-main from `checkXSignInStatus()`; model construction must stay fast.

    /// The connected X accounts, in the order they were connected. Every other
    /// piece of X state below is keyed by an account's id.
    var xAccounts: [XAccount] = []
    var isSyncingXBookmarks: Bool = false
    /// The accounts the running sync pass has yet to finish, for the card
    /// spinners; empty between passes.
    var xSyncingAccountIDs: Set<String> = []
    /// True from a Connect or Reconnect click until the browser sign-in has
    /// returned. macOS hosts that sign-in in a system agent it launches on
    /// demand, and on a loaded Mac the launch can take a long while; a button
    /// that showed nothing meanwhile read as dead, and the second click it
    /// invited would have started another session on top of the first.
    var isConnectingX: Bool = false
    var xLastSyncDates: [String: Date] = [:]

    /// Accounts whose session is expired and can't be refreshed — their card
    /// shows "Reconnect needed" instead of the sync time.
    var xAccountsNeedingReauth: Set<String> = []

    /// What went wrong at each account's last sync, shown on its card and —
    /// through `xPluginAttention` — as the red dot on the X tab in the Sources
    /// pane. Cleared by that account's next successful sync.
    var xAccountFailures: [String: XAccountFailure] = [:]

    /// Accounts whose failed syncs the learner dismissed. X blocked on purpose
    /// (Screen Time, a filter) fails every sync the same way, so a dismissed
    /// account raises no banner or red dot again until one of its syncs goes
    /// through.
    var xDismissedFailureAccounts: Set<String> = []

    /// Why the last sign-in failed, shown on the plugin page. A failed
    /// sign-in belongs to no account yet.
    var xConnectError: String?

    /// When X said each account's rate-limit window reopens, after a sync it
    /// refused with a 429. Until then every sync of that account is a
    /// guaranteed failure against the same limit, so the event-triggered syncs
    /// skip it, its Sync button waits, and `xSyncResumeTasks` runs the sync X
    /// asked us to wait for. An account with no entry has no limit in force; a
    /// successful sync removes it.
    var xSyncPausedUntil: [String: Date] = [:]

    /// True after X answered a sync with 402: ForeverLM's API credits are
    /// spent, and every request fails until someone tops them up. The
    /// event-triggered syncs stop asking; Try Again, the Settings button and a
    /// pull-to-refresh still do, and the first sync that succeeds clears it.
    var xCreditsDepleted = false

    /// The sync scheduled for each `xSyncPausedUntil`; replaced by each new
    /// pause and cancelled by a successful sync or a disconnect.
    @ObservationIgnored var xSyncResumeTasks: [String: Task<Void, Never>] = [:]

    /// Profile pictures for X handles, keyed by lowercased handle, as resolved
    /// this launch. A library holds far more posts than authors, so a handle is
    /// looked up once and answers for every post it wrote — including the ones
    /// saved later.
    @ObservationIgnored var xAuthorAvatarURLs: [String: String] = [:]

    /// X posts whose thread capture was tried this launch
    /// (`captureThreadOfSavedXPost`), whether or not it wrote a document.
    @ObservationIgnored var xPostThreadCaptureAttemptedIDs: Set<String> = []

    /// X posts `fillCutXPosts` captured again this launch and X still answered
    /// cut short. They wait for the next launch instead of being asked for on
    /// every bookmark sync.
    @ObservationIgnored var xPostsLeftCutThisLaunch: Set<String> = []

    /// The single in-flight pass of `backfillXPostArtwork`. Every X row asks for
    /// its thumbnail as it appears, and they all appear at once; without this
    /// they would each start their own sweep of the same library.
    @ObservationIgnored var xPostArtworkBackfillTask: Task<Int, Never>?

    /// The sources the chat reads: one app-wide list, kept in memory only.
    var contextSourceIds: [String] = [] {
        didSet {
            contextSourcesWrite = ContextSourcesWrite(
                windowID: (chatRequestOriginWindow ?? activeWindowState).id,
                revision: contextSourcesWrite.revision &+ 1
            )
        }
    }

    /// Which window the last change to `contextSourceIds` was made in — the
    /// window in scope, as for a chat request — and a count of changes.
    struct ContextSourcesWrite: Equatable {
        var windowID: UUID?
        var revision: Int
    }

    /// The context is one app-wide list, but a fresh notebook chat that reads
    /// its notebook's ticks live gives way only to a change made in its own
    /// window: another window's New chat seeding the context is not this
    /// chat's learner acting (`InternalReviewPanel.readsNotebookTicksLive`).
    private(set) var contextSourcesWrite = ContextSourcesWrite(windowID: nil, revision: 0)

    // MARK: - Source Search State

    /// Query text for semantic source search.
    var sourceSearchQuery: String = ""
    /// Results from the last semantic search, sorted by descending similarity.
    var sourceSearchResults: [SourceSearchResult] = []
    /// Best semantic chunk surfaced in the reader after opening a search result.
    var readerSearchBestMatches: [String: SourceSearchBestMatch] = [:]
    /// Whether the user has submitted an All-tab source search.
    var hasSearchedSources: Bool = false
    /// Whether a semantic search is in progress.
    var isSearchingSources: Bool = false
    /// Monotonic token that prevents stale async search phases from overwriting newer results.
    var sourceSearchGeneration = 0
    /// Task handle for debounced Apple Podcasts catalog search.
    var podcastCatalogSearchTask: Task<Void, Never>?
    /// Article IDs currently being backfilled for artwork.
    @ObservationIgnored var artworkBackfillInFlight: Set<String> = []
    /// Pictures found by `backfillArtworkIfNeeded`, by source id, waiting to
    /// land in `articles` together (`queueBackfilledArtwork`).
    @ObservationIgnored var pendingBackfilledArtwork: [String: String] = [:]
    /// The one scheduled write of `pendingBackfilledArtwork`.
    @ObservationIgnored var backfilledArtworkFlushTask: Task<Void, Never>?
    /// Source IDs currently running a generic content fetch.
    var contentFetchInFlight: Set<String> = []
    /// Papers whose reader has given up on a PDF the publisher refuses to
    /// serve, and shows the text or the publisher's page instead. Read by the
    /// reader's routing, so it is observed rather than ignored, and it lives
    /// for the session: the next launch tries the PDF again, which is right,
    /// because a paper's PDF can become available later.
    var readerAbandonedRemotePDFSourceIDs: Set<String> = []
    /// The podcast drain is globally serial, not merely serial within one caller.
    /// Event-triggered refreshes can arrive while a long Whisper job is running;
    /// coalesce them into one follow-up pass instead of starting a second worker.
    @ObservationIgnored var podcastTranscriptDrainInProgress = false
    @ObservationIgnored var podcastTranscriptDrainRequested = false
    /// Source IDs currently running a direct YouTube transcript fetch.
    var youtubeTranscriptFetchInFlight: Set<String> = []
    /// Teachable lecture source IDs whose audio is being downloaded and transcribed.
    var teachableTranscriptFetchInFlight: Set<String> = []
    /// Podcast source IDs currently importing captions from a learner-confirmed
    /// YouTube video. Separate from direct video fetches because the source must
    /// keep its Apple podcast identity throughout this operation.
    var podcastYouTubeTranscriptImportInFlight: Set<String> = []
    /// Source IDs the reader has already refreshed against YouTube's official
    /// chapter markers this app session. One `/next` fetch per source per launch
    /// is enough to migrate an existing transcript's headings to the real
    /// chapters; the applied result is idempotent, so re-runs never rewrite.
    var youtubeChapterRefreshAttempted: Set<String> = []
    /// Source IDs currently fetching a Zoom recording transcript.
    var zoomTranscriptFetchInFlight: Set<String> = []
    /// The quarter-hourly check for Zoom transcripts still waiting
    /// (`startZoomTranscriptChecks`); nil until launch starts it.
    @ObservationIgnored var zoomTranscriptCheckTask: Task<Void, Never>?
    /// Whether a sweep backfilling missing video channel names is running.
    var videoChannelBackfillInFlight = false
    /// YouTube video IDs oEmbed refused to describe this launch (private or
    /// deleted videos). They have no channel to find, so the channel backfill
    /// leaves them alone instead of asking again on every plugin event.
    @ObservationIgnored var videoChannelBackfillUnavailableVideoIDs: Set<String> = []

    /// Resolved articles for all context source IDs.
    var contextSourceArticles: [StudioArticle] {
        contextSourceIds.compactMap { id in
            articlesById[id]
        }
    }

    /// The Notebook or Goal with this id.
    func notebook(id: String) -> LearningGoalRecord? {
        learningGoals.first { $0.id == id }
    }

    // MARK: - Private

    /// Tests and non-window helpers still need a presentation target. In the app,
    /// imperative navigation is routed to the key window by the registry.
    @ObservationIgnored private let fallbackWindowState = StudioWindowState()
    @ObservationIgnored private let usesStudioWindowRegistry: Bool
    /// The window an `inWindow(_:_:)` scope is evaluating for. Observation-
    /// ignored on purpose: a scope is opened and closed inside one synchronous
    /// read, often from a view body, and republishing the view model for it
    /// would re-render every window on every row.
    @ObservationIgnored private var scopedWindowState: StudioWindowState?
    /// The window a `withWindow(_:_:)` scope is running for: the same stand-in
    /// for the key window, carried by the task, so it spans an `await` and
    /// the tasks started inside it.
    @TaskLocal static var taskWindowState: StudioWindowState?

    /// Whether `window` is the one a request, a toast or a notice stamped with
    /// `targetID` is for. Each belongs to the window it was raised in, so a
    /// click in one window never opens, focuses or announces anything in
    /// another (product owner, 2026-11-12: "Those two windows have to be
    /// independent"). One stamped with no window, or with a window that is
    /// not open (the fallback state, a window since closed), is for all.
    func isRequestTarget(_ targetID: UUID?, _ window: StudioWindowState?) -> Bool {
        guard let targetID, let window, targetID != window.id else { return true }
        return !StudioWindowRegistry.shared.states.contains { $0.id == targetID }
    }

    /// The chat box focus token as `window` sees it: nil in a window the
    /// focus was not asked for in.
    func reviewChatFocusRequestID(in window: StudioWindowState?) -> UUID? {
        isRequestTarget(reviewChatFocusWindowID, window) ? reviewChatFocusRequestID : nil
    }

    var activeWindowState: StudioWindowState {
        if let scopedWindowState { return scopedWindowState }
        if let taskWindowState = Self.taskWindowState { return taskWindowState }
        guard usesStudioWindowRegistry else { return fallbackWindowState }
        return StudioWindowRegistry.shared.activeState ?? fallbackWindowState
    }

    /// The Studio window a chat request being made now was made in: the
    /// `inWindow` scope when one is open, else the key window. Nil while one
    /// of the app's windows that is no Studio window — a popped-out Reader —
    /// is key: a request from there was made in none of them, and lands in
    /// the Studio window used last, which `activeWindowState` still names.
    var chatRequestOriginWindow: StudioWindowState? {
        if let scopedWindowState { return scopedWindowState }
        if let taskWindowState = Self.taskWindowState { return taskWindowState }
        if StudioWindowRegistry.shared.detachedWindowIsKey { return nil }
        return activeWindowState
    }

    /// Every window's state, including the non-window fallback used by tests
    /// and launch helpers, for changes that must reach all of them.
    var allWindowStates: [StudioWindowState] {
        StudioWindowRegistry.shared.states + [fallbackWindowState]
    }

    /// Evaluates `body` with `windowState` standing in for the key window, so
    /// every per-window accessor — `sidebarStore`, `sidebarTab`, `searchText`,
    /// `selectedArticleIds`, the derived source lists — answers for that window.
    ///
    /// Synchronous by design. The scope is a plain save-and-restore around the
    /// call, so it nests, but it cannot span an `await`: other main-actor work
    /// would run inside it and read the wrong window. Async flows take the
    /// window as a parameter instead, as `refreshSidebarContentSearchMatches`
    /// does.
    @discardableResult
    func inWindow<T>(_ windowState: StudioWindowState, _ body: () throws -> T) rethrows -> T {
        let previous = scopedWindowState
        scopedWindowState = windowState
        defer { scopedWindowState = previous }
        return try body()
    }

    /// `inWindow` for work that awaits: `windowState` stands in for the key
    /// window for the whole of `body` and for every task started inside it,
    /// so an act begun in a window that is not key (a drop, a pane's own
    /// refresh) reads and writes that window's Canvas, Atlas and panes all
    /// the way through. The scope rides the task, never the view model, so
    /// other main-actor work running between its awaits does not see it.
    @discardableResult
    func withWindow<T>(_ windowState: StudioWindowState, _ body: () async throws -> T) async rethrows -> T {
        try await Self.$taskWindowState.withValue(windowState) { try await body() }
    }

    /// Starts `work` as a task acting in `windowState` (`withWindow`): what a
    /// view's button or drop does for work that awaits, so it stays with the
    /// window it was made in.
    @discardableResult
    func task(in windowState: StudioWindowState?, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            guard let windowState else { return await work() }
            await self.withWindow(windowState) { await work() }
        }
    }

    /// `inWindow` for a view that may be drawn outside any Studio window (a
    /// menu, a sheet's own host): with no window it answers for the key one.
    @discardableResult
    func inWindow<T>(_ windowState: StudioWindowState?, _ body: () throws -> T) rethrows -> T {
        guard let windowState else { return try body() }
        return try inWindow(windowState, body)
    }

    /// A view of this view model that answers for one window. Sidebar views
    /// read their derived lists through it — `vm.scoped(to: windowState)
    /// .activeTabArticles` — so a window that is not key still renders the tab
    /// and search it is showing rather than the key window's.
    func scoped(to windowState: StudioWindowState) -> StudioWindowScopedViewModel {
        StudioWindowScopedViewModel(viewModel: self, windowState: windowState)
    }

    /// The filtered-list caches are per window, but their inputs — the library,
    /// the Schedule, course structure — are app-wide, so a change to those
    /// has to empty every window's cache, not just the key window's.
    func invalidateSidebarCachesInEveryWindow() {
        for state in allWindowStates {
            state.sidebarStore.invalidateFilteredCache()
        }
    }

    /// A Studio window that has never navigated its own Reader renders the
    /// app-wide selection, so a click in one window would change what every
    /// other open window was reading — the same source, opened in two places.
    /// Before that selection moves, hand each of the other windows the source it
    /// is showing right now, so only the window being acted in follows.
    private func pinWindowsFollowingTheGlobalSelection(to previousSelection: String?) {
        let active = activeWindowState
        for state in StudioWindowRegistry.shared.states where state !== active {
            state.pinReaderSelection(to: previousSelection)
        }
    }

    /// A source that is removed, hidden, or archived leaves every window's Sources
    /// list, so it leaves every window's selection too — not only the key window's,
    /// which is all `selectedArticleIds` reaches.
    func deselectSourcesInEveryWindow(_ sourceIDs: some Sequence<String>) {
        let ids = Set(sourceIDs)
        guard !ids.isEmpty else { return }
        for state in allWindowStates
        where !state.sidebarSelectedSourceIDs.isDisjoint(with: ids) {
            state.sidebarSelectedSourceIDs.subtract(ids)
        }
    }

    /// The learner clicked past every row in one window's Sources list, which
    /// closes that window's Reader. Every other window keeps what it shows,
    /// whether it owns its source or was still following the app-wide selection.
    func closeReader(in windowState: StudioWindowState) {
        let previous = selectedArticleId
        for state in StudioWindowRegistry.shared.states where state !== windowState {
            state.pinReaderSelection(to: previous)
        }
        windowState.sidebarSelectedSourceIDs = []
        windowState.readerArticleID = nil
        selectedArticleId = nil
    }

    /// Synced workspace preferences are defaults for a new scene. They can
    /// hydrate the non-window fallback used by tests and launch helpers, but an
    /// incoming preference must never rearrange a Studio window already open on
    /// another display.
    func applySyncedCenterTabGroupsDefault(_ groups: StudioCenterTabGroups) {
        guard !usesStudioWindowRegistry || StudioWindowRegistry.shared.activeState == nil else { return }
        fallbackWindowState.replaceCenterTabGroupsFromDefault(groups)
    }

    let storage: StorageService
    let aiService: AIService
    let sourceService = SourceService.shared
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")

    /// Suspends until no fetch is running for this source (or `stopWhen` turns true), the
    /// timeout passes, or the calling task is cancelled. True only when the wait ended
    /// because the fetch is no longer in flight. It re-checks on every change to the state
    /// `sourceFetchIsInFlight` reads, so it never polls.
    func waitForSourceFetch(
        _ articleId: String,
        timeout: Duration,
        stopWhen: () -> Bool = { false }
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        // One wake-up channel for changes, the timeout and cancellation. A change that lands
        // before the wait suspends stays buffered, so no wake-up is lost.
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let deadlineTask = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            wake.yield()
        }
        defer {
            deadlineTask.cancel()
            wake.finish()
        }
        var iterator = wakes.makeAsyncIterator()
        while true {
            // The check runs inside the tracking closure, so the change that ends the wait
            // is registered by the same read that found it still running.
            let stillWaiting = withObservationTracking {
                sourceFetchIsInFlight(articleId) && !stopWhen()
            } onChange: {
                wake.yield()
            }
            if !stillWaiting { return true }
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            // A cancelled task's `next()` returns nil, which ends the wait.
            guard await iterator.next() != nil else { return false }
        }
    }

    /// Runs a read whose failure the caller treats as "nothing there": the failure is
    /// logged (cancellation is not) and the result is nil, so callers keep their own
    /// empty value.
    func loggedRead<T>(_ what: String, _ read: () async throws -> T) async -> T? {
        await loggedLookup(what) { try await read() }
    }

    /// `loggedRead` for a read that may itself find nothing: both a failure and a
    /// miss come back as nil, and only the failure is logged.
    func loggedLookup<T>(_ what: String, _ read: () async throws -> T?) async -> T? {
        do {
            return try await read()
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("Reading \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Keeps every source's chunk embedding present so semantic search can't silently
    /// miss a source. Fills the historical backlog and covers sources that arrive over
    /// CloudKit sync (which never pass through the ingest embed path). Triggered off the
    /// launch path, never at startup.
    ///
    /// A plain `let` built in `init`, deliberately not `lazy`: `@Observable` cannot
    /// synthesize an init accessor for a lazy property, because its backing storage is
    /// not a plain stored property.
    let sourceEmbeddingIndexer: SourceEmbeddingIndexer
    let canonicalContentCleanupService: CanonicalContentCleanupService
    let podcastTranscriptCleanupService: PodcastTranscriptCleanupService
    let podcastTranscriptDetruncationService: PodcastTranscriptDetruncationService
    let articleChromeRefilterService: ArticleChromeRefilterService
    /// Schema 144's one pass over the library: each paper's title against the
    /// one its DOI is registered under.
    let registeredPaperTitleCheckService: RegisteredPaperTitleCheckService
    /// Schema 174's read of each paper's reference list and the link of each entry
    /// (`StudioViewModel+PaperReferenceLinks`): free catalogs, no model.
    let paperReferenceLinkService: PaperReferenceLinkService
    let youTubeTranscriptCheckService: YouTubeTranscriptCheckService
    let sourceListenableContentPreparationService: SourceListenableContentPreparationService
    /// The learner's daily cap on background AI (`BackgroundAIDailyCap`).
    let backgroundAIBudget: BackgroundAIBudget
    let sourceReviewGuidePreparationService: SourceReviewGuidePreparationService
    /// Extracts a finished source's ideas once, so tomorrow's memory review
    /// opens without waiting on a cold extraction.
    let sourceIdeaExtractionService: SourceIdeaExtractionService
    let paperFigureIndexer: PaperFigureIndexer

    // MARK: - Cluster-backing stored state
    // Stored properties for logic that now lives in StudioViewModel+Queue.swift
    // and StudioViewModel+Meetings.swift. Stored properties must be declared in
    // the primary class declaration, not in extensions.

    /// Set once the queue has loaded at least once this session.
    var hasLoadedOnce = false

    /// The Dev build says once per session that it is not spending a model on
    /// source clean-up (`PaidSourceCleanupPolicy`), not on every drain.
    var hasLoggedPaidCleanupSkip = false
    var hasCompletedInitialQueueLoad = false

    /// In-flight title-fix operations, keyed by article id.
    var fixingTitleIds: Set<String> = []

    /// Result message from the last manual duplicate check.
    var duplicateCheckResult: String?

    init(
        storageService: StorageService,
        observeCloudKitChanges: Bool = true,
        usesStudioWindowRegistry: Bool = false,
        notebookRecencyDefaults: UserDefaults? = nil
    ) {
        // Bind through a local so the indexer's embed closure captures `ai` rather than
        // `self` — `self` is not available until every stored property is initialized.
        let ai = AIService()
        self.usesStudioWindowRegistry = usesStudioWindowRegistry
        self.notebookRecencyDefaults = notebookRecencyDefaults
        self.storage = storageService
        self.aiService = ai
        self.sourceEmbeddingIndexer = SourceEmbeddingIndexer(
            storage: storageService,
            embed: { text in try await ai.embedText(text) }
        )
        self.canonicalContentCleanupService = CanonicalContentCleanupService(
            storage: storageService,
            aiService: ai
        )
        self.podcastTranscriptCleanupService = PodcastTranscriptCleanupService(
            storage: storageService,
            aiService: ai
        )
        self.podcastTranscriptDetruncationService = PodcastTranscriptDetruncationService(
            storage: storageService,
            aiService: ai
        )
        self.articleChromeRefilterService = ArticleChromeRefilterService(storage: storageService)
        self.registeredPaperTitleCheckService = RegisteredPaperTitleCheckService(storage: storageService)
        let backgroundBudget = BackgroundAIBudget(storage: storageService)
        self.paperReferenceLinkService = PaperReferenceLinkService(
            storage: storageService,
            readEntries: PaperReferenceModelReading.reader(aiService: ai, budget: backgroundBudget)
        )
        self.youTubeTranscriptCheckService = YouTubeTranscriptCheckService(storage: storageService)
        self.sourceListenableContentPreparationService = SourceListenableContentPreparationService(
            storage: storageService,
            aiService: ai
        )
        self.backgroundAIBudget = backgroundBudget
        self.sourceReviewGuidePreparationService = SourceReviewGuidePreparationService(
            storage: storageService,
            aiService: ai
        )
        self.sourceIdeaExtractionService = SourceIdeaExtractionService(storage: storageService, aiService: ai)
        self.paperFigureIndexer = PaperFigureIndexer(storage: storageService, aiService: ai)
        if observeCloudKitChanges {
            startObservingCloudKitRemoteChanges()
            startObservingResolvedPathCacheClears()
            startObservingICloudStorageFull()
            startObservingDerivedSourceWork()
            startObservingManagedAICreditsRestored()
            startObservingBackgroundAISpendControls()
        }
        checkXSignInStatus()
        // A plain defaults read of a small dictionary, before any window
        // registers and asks which notebook it opens in.
        notebookRecency = NotebookRecency.load(from: notebookRecencyDefaults)
    }

}

// MARK: - Errors

/// Where `StudioViewModel.activeNotebookId` is kept: this Mac's own defaults,
/// never synced. The key predates windows holding their own notebooks, when
/// it was also what MCP read; it is kept so the choice survives.
enum ActiveNotebookPreference {
    static var notebookID: String? {
        get {
            guard let value = Preferences.value(Prefs.MCP.activeNotebookID)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        set {
            if let clean = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                Preferences.set(clean, for: Prefs.MCP.activeNotebookID)
            } else {
                Preferences.reset(Prefs.MCP.activeNotebookID)
            }
        }
    }
}

enum StudioError: LocalizedError {
    case noApiKey
    case contentNotAvailable
    /// No `sources` row carries the id an action named.
    case sourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "Sign in with Apple to use AI."
        case .contentNotAvailable: return "Article content could not be fetched."
        case .sourceNotFound: return "Source no longer in the library."
        }
    }
}

/// `StudioViewModel` as seen from one Studio window.
///
/// Reading a property through it — `scoped.activeTabArticles`,
/// `scoped.sidebarTab` — evaluates the view model's own accessor inside
/// `inWindow(_:_:)`, so everything that normally follows the key window
/// (`sidebarStore`, `selectedArticleIds`, and the derived lists computed off
/// them) answers for this window instead. Observation still tracks the
/// underlying reads, so a view that renders through it re-renders when its
/// window's store changes and not when another window's does. Methods go
/// through `inWindow` explicitly: `scoped.inWindow { $0.switchTab(to: .papers) }`.
@dynamicMemberLookup
@MainActor
struct StudioWindowScopedViewModel {
    let viewModel: StudioViewModel
    let windowState: StudioWindowState

    subscript<T>(dynamicMember keyPath: KeyPath<StudioViewModel, T>) -> T {
        viewModel.inWindow(windowState) { viewModel[keyPath: keyPath] }
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<StudioViewModel, T>) -> T {
        get { viewModel.inWindow(windowState) { viewModel[keyPath: keyPath] } }
        nonmutating set { viewModel.inWindow(windowState) { viewModel[keyPath: keyPath] = newValue } }
    }

    /// Runs a synchronous view-model call for this window. See
    /// `StudioViewModel.inWindow(_:_:)` for why it cannot span an `await`.
    @discardableResult
    func inWindow<T>(_ body: (StudioViewModel) throws -> T) rethrows -> T {
        try viewModel.inWindow(windowState) { try body(viewModel) }
    }
}
