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

    struct PendingDeletionNotice: Identifiable, Equatable {
        let id: UUID
        let message: String
    }

    struct ArtworkBackfillCandidate: Sendable {
        let id: String
        let url: URL
    }

    struct ArtworkBackfillResult: Sendable {
        let id: String
        let artworkURL: String
    }

    struct MergeExistingSnapshot: Sendable {
        let urls: Set<String>
        let relativeURLs: Set<String>
        let localPaths: Set<String>
        let podcastWebURLs: Set<String>
        /// Each paper title held, with the DOIs of the papers holding it
        /// (nil for a paper without one).
        let paperTitleDOIs: [String: [String?]]
        let localPaperFilenames: Set<String>
        let paperPublisherKeys: Set<String>
    }

    struct MergeDiscoveredSnapshot: Sendable {
        let index: Int
        let url: String
        let normalizedURL: String
        let relativeURL: String
        let sourceType: String
        let title: String
        let normalizedPaperTitle: String
        let paperDOI: String?
        let localFilePath: String?
        let podcastWebPageURL: String?
        let normalizedPaperFilename: String?
        let paperPublisherKey: String?
    }

    struct MergeComputationResult: Sendable {
        let newArticleIndexes: [Int]
        let discoveredByURLIndexes: [String: Int]
    }

    struct ReadingListImportReport: Sendable {
        let scannedCount: Int
        let candidateCount: Int
        let insertedCount: Int
        let promotedCount: Int
        let scannedByOrigin: String
        let scannedOriginLabel: String
        let candidatesByType: String
        let insertedByType: String
    }

    struct ReadingListAutoSyncInput: @unchecked Sendable {
        let request: BrowserReadingListWorkerRequest
        let articles: [StudioArticle]
        let storage: StorageService
        let shouldStopSafariFolderAccess: Bool
    }

    /// Main-actor snapshot for reading-list auto-sync. Excludes the resolved Safari
    /// security-scoped bookmark, which is resolved off the main actor (file I/O / TCC).
    struct ReadingListAutoSyncBase: @unchecked Sendable {
        let safariEnabled: Bool
        let chromeEnabled: Bool
        let braveEnabled: Bool
        let homeDir: String
        let articles: [StudioArticle]
        let storage: StorageService
    }

    struct ReadingListAutoSyncPersistenceResult: @unchecked Sendable {
        let changedIDs: Set<String>
        let promotedIDs: Set<String>
        let scannedSources: [StudioArticle]
        let candidateSources: [StudioArticle]
        let insertedSources: [StudioArticle]
        let warnings: [String]
    }

    struct LocalPDFAttachmentPlan: @unchecked Sendable {
        let sourcePath: String
        let destinationPath: String
        let doi: String?
    }

    struct AttachedTextFileResult: @unchecked Sendable {
        let attachedPath: String
        let relativePath: String
        let text: String
        let wordCount: Int
    }

    struct BrowserReadingListScanResult: @unchecked Sendable {
        let articles: [StudioArticle]
        let warnings: [String]
    }

    struct BrowserReadingListWorkerRequest: Codable, Sendable {
        let homeDir: String
        let safariEnabled: Bool
        let chromeEnabled: Bool
        let braveEnabled: Bool
        let safariFolderPath: String?
    }

    struct BrowserReadingListWorkerResponse: Codable {
        let articles: [StudioArticle]
        let warnings: [String]
    }

    struct PodcastDiscoveryFileSnapshot: @unchecked Sendable {
        let dbPath: String
        let episodeMetadata: [PodcastEpisodeMetadata]
        let status: PodcastDiscoveryStatus
        let databaseExists: Bool
    }

    struct PodcastLibraryFileFingerprint: Equatable, Sendable {
        let modifiedAt: Date
        let size: UInt64
    }

    struct PodcastAutoSyncPersistenceResult: @unchecked Sendable {
        let insertedIDs: Set<String>
        let insertedSources: [StudioArticle]
    }

    struct PodcastAutoSyncBase: @unchecked Sendable {
        let storage: StorageService
        let previousArticles: [StudioArticle]
    }

    struct PodcastTranscriptHydrationCandidate: Sendable {
        let id: String
        let url: String
        let title: String
        let podcastName: String
        let webPageURL: String?
        /// The learner chose YouTube as this show's transcript source. Identity
        /// still requires confirmation; this only skips a known-useless Apple call.
        let prefersYouTube: Bool
        /// Episodes on a hidden show (or hidden individually) still get their
        /// transcript downloaded so search keeps working, but they skip the
        /// billed formatting pass — nobody is reading them.
        let allowsFormatting: Bool
        /// The learner asked for this episode's transcript, so its formatting
        /// goes ahead of the queue (`PodcastTranscriptFormattingRequest`).
        var userInitiated = false
    }

    /// The public Apple Podcasts identity hydration gave a row that had none:
    /// what the in-memory article must now say about itself so a later save
    /// does not write the old address back over the durable one.
    struct PodcastResolvedEpisodeIdentity: Sendable, Equatable {
        let url: String
        let webPageURL: String?
    }

    struct PodcastTranscriptHydrationResult: Sendable {
        enum Outcome: Sendable {
            case ready(content: String, persistedReadyState: Bool)
            case failed(message: String)
        }

        let id: String
        let outcome: Outcome
        /// Set when hydration moved the row onto a public episode identity.
        let resolvedIdentity: PodcastResolvedEpisodeIdentity?
        /// Set when the row resolved to an identity another row already holds
        /// and was archived into it; the surviving row's id.
        let mergedIntoSourceID: String?

        init(
            id: String,
            outcome: Outcome,
            resolvedIdentity: PodcastResolvedEpisodeIdentity? = nil,
            mergedIntoSourceID: String? = nil
        ) {
            self.id = id
            self.outcome = outcome
            self.resolvedIdentity = resolvedIdentity
            self.mergedIntoSourceID = mergedIntoSourceID
        }
    }

    enum PodcastTranscriptFetchOutcome: Sendable, Equatable {
        case available(String)
        /// Apple knows the episode but does not expose a transcript to this
        /// account. Paid/private feeds and publisher-disabled episodes commonly
        /// land here; retrying the same catalog request cannot change access.
        case unavailable
        /// Transport, authentication-helper, or server failure. These remain
        /// retryable because Apple may expose the same transcript later.
        case failed
    }

    enum PodcastTranscriptHTTPDisposition: Equatable {
        case success
        case authenticationExpired
        case unavailable
        case failed
    }

    struct ImportedBookFile: Sendable {
        /// The book the file already is, or nil for a new book (`BookFilePlacement`).
        let bookID: String?
        let baseName: String
        let bookDir: String
        let destPath: String
        let chaptersDir: String
        let importedTitle: String?
        let importedSubtitle: String?
        let importedAuthor: String?
        let importedEdition: String?
    }

    struct KindleConversionResult: Sendable {
        let epubPath: String
        let tempDir: String
    }

    struct BookChapterImportDraft: Sendable {
        let path: String
        let title: String
        let sortIndex: Int
        let plainText: String
        let wordCount: Int
        /// A PDF book's chapter: its pages of the book's file, which `path`
        /// names. Nil for an EPUB chapter, whose file is the chapter.
        var pages: Range<Int>? = nil
    }

    struct PDFBookSnapshot: Sendable {
        let pageCount: Int
        let outlineEntries: [PDFOutlineChapterEntry]
        let tocEntries: [PDFTOCChapterEntry]
        let detectedChapterEntries: [PDFOutlineChapterEntry]
        let pageEntries: [PDFPageChapterEntry]
        let frontMatterPages: [PDFPageChapterEntry]
    }

    struct PDFPageChapterEntry: Sendable {
        let pageIndex: Int
        let text: String
    }

    struct PDFTOCChapterEntry: Sendable {
        let title: String
        let printedPage: Int?
        let text: String
    }

    final class BookImportProgress: @unchecked Sendable {
        weak var viewModel: StudioViewModel?
        /// The book being finished in the background, whose row the line
        /// goes to (`finishingBookStatus`); nil for the import the learner
        /// waits on under Add Book.
        let bookID: String?

        init(_ viewModel: StudioViewModel, bookID: String? = nil) {
            self.viewModel = viewModel
            self.bookID = bookID
        }

        func update(_ message: String) {
            Task { @MainActor in
                guard let viewModel = self.viewModel else { return }
                if let bookID = self.bookID {
                    // A line that arrives after the book finished is dropped.
                    guard viewModel.finishingBookStatus[bookID] != nil else { return }
                    viewModel.finishingBookStatus[bookID] = message
                } else {
                    viewModel.bookImportStatus = message
                }
            }
        }
    }

    struct CourseMaterialOrdinal: Hashable {
        let kind: String
        let major: Int
        let detail: String?
    }

    struct ParsedMeetingArtifact: Sendable {
        let url: URL
        let title: String
        let sessionKey: String
        let kind: MeetingArtifactKind
        let text: String?
        let externalURL: String?
        let localFilePath: String?
        let mimeType: String?
        let modifiedAt: Date?
    }

    static let queueLoadYieldStride = 25
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
    @ObservationIgnored var paperFigureMarkdownRepairInFlight = false
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
    /// lists — and each read used to filter every goal and rebuild the order
    /// (build 210's stalls, 2026-10-11: `notebooks` in 9 of them).
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
    /// rail unless the learner took it off. Read by nothing since the rail
    /// went compact (2026-10-03, `NotebookPins`), and no longer synced
    /// (`SyncedPreferenceKeys.excluded`).
    static let unpinnedNotebooksPreferenceKey = "studio.unpinnedProjects"

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
            UserDefaults.standard.stringArray(forKey: NotebookPins.preferenceKey) ?? []
        )
    }() {
        didSet {
            PreferenceStore.set(
                StudioViewModel.deduplicated(pinnedNotebookIDs),
                forKey: NotebookPins.preferenceKey
            )
            // Generation 2: the pins are the member's NotebookStates.
            NotebookSidebarSync.setPinned(pinnedNotebookIDs)
        }
    }

    /// The rail's Pinned notebooks: the active ones the learner pinned, in
    /// `notebookOrder`, so a row dragged over another moves as it always did.
    var pinnedNotebooks: [LearningGoalRecord] {
        let pinned = Set(pinnedNotebookIDs)
        return notebooks.filter { pinned.contains($0.id) }
    }

    func isNotebookPinned(_ notebookID: String) -> Bool {
        pinnedNotebookIDs.contains(notebookID)
    }

    /// Pin or unpin one notebook. Ids of notebooks that no longer exist are
    /// dropped on the way through, so a deleted notebook does not leave its
    /// id in the synced list forever.
    func setNotebookPinned(_ notebookID: String, _ pinned: Bool) {
        let ids = NotebookPins.setting(
            notebookID,
            pinned: pinned,
            in: pinnedNotebookIDs,
            knownIDs: Set(learningGoals.map(\.id))
        )
        guard ids != pinnedNotebookIDs else { return }
        pinnedNotebookIDs = ids
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
        let raw = UserDefaults.standard.stringArray(forKey: "studio.projectOrder") ?? []
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
            PreferenceStore.set(deduplicated, forKey: "studio.projectOrder")
            // Generation 2: the order is the member's NotebookStates' sidebar keys.
            NotebookSidebarSync.setOrder(deduplicated)
        }
    }

    func orderedNotebooks(_ unordered: [LearningGoalRecord]) -> [LearningGoalRecord] {
        let byID = Dictionary(uniqueKeysWithValues: unordered.map { ($0.id, $0) })
        var included = Set<String>()
        var ordered = notebookOrder.compactMap { notebookID -> LearningGoalRecord? in
            guard let notebook = byID[notebookID], included.insert(notebookID).inserted else { return nil }
            return notebook
        }
        ordered.append(contentsOf: unordered.filter { included.insert($0.id).inserted })
        return ordered
    }

    /// Move one visible Notebook to another row's position, matching the Courses
    /// panel's established drop-target behavior. Hidden archived ids follow active ids so
    /// restoring a Notebook never loses it from the persisted order entirely.
    func reorderNotebook(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID else { return }
        var activeIDs = notebooks.map(\.id)
        guard let sourceIndex = activeIDs.firstIndex(of: sourceID),
              let destinationIndex = activeIDs.firstIndex(of: destinationID) else { return }
        activeIDs.remove(at: sourceIndex)
        activeIDs.insert(sourceID, at: destinationIndex)
        let archivedIDs = archivedNotebooks.map(\.id).filter { !activeIDs.contains($0) }
        notebookOrder = activeIDs + archivedIDs
    }

    // MARK: - Chat order

    static let chatOrderPreferenceKey = "studio.chatOrder"

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
            UserDefaults.standard.stringArray(forKey: StudioViewModel.chatOrderPreferenceKey) ?? []
        )
    }() {
        didSet {
            chatOrderRevision &+= 1
            PreferenceStore.set(
                StudioViewModel.deduplicated(chatOrder),
                forKey: StudioViewModel.chatOrderPreferenceKey
            )
        }
    }

    static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Applies `chatOrder` to an already-sorted run of chats. Chats the order does
    /// not name keep their incoming (newest-first) position ahead of the arranged
    /// ones; the rest follow in the arranged sequence.
    func orderedReviewSessions(_ unordered: [ReviewSessionRecord]) -> [ReviewSessionRecord] {
        guard !chatOrder.isEmpty else { return unordered }
        let rank = Dictionary(
            uniqueKeysWithValues: chatOrder.enumerated().map { ($0.element, $0.offset) }
        )
        // Only the arranged tail is rebuilt: pulling the named chats out in
        // `chatOrder` sequence keeps the unnamed ones in the caller's order
        // without a comparison sort over the whole run.
        var unnamed: [ReviewSessionRecord] = []
        var named: [(rank: Int, session: ReviewSessionRecord)] = []
        for session in unordered {
            if let position = rank[session.id] {
                named.append((position, session))
            } else {
                unnamed.append(session)
            }
        }
        guard !named.isEmpty else { return unordered }
        named.sort { $0.rank < $1.rank }
        return unnamed + named.map(\.session)
    }

    /// Move one chat to another chat's row in the navigation rail, matching the
    /// Notebook folders' established drop-target behavior: the dragged chat takes the
    /// destination row's slot and everything between shifts down.
    ///
    /// The arrangement is recorded over *every* loaded chat rather than over the
    /// section the drop happened in, so reordering inside one Notebook folder cannot
    /// disturb another folder's order, and a search-filtered rail cannot discard the
    /// position of a chat it is currently hiding. Ids of chats that no longer exist
    /// are dropped on the way through, which is what keeps this preference from
    /// growing forever.
    func reorderReviewSession(from sessionID: String, to destinationID: String) {
        guard sessionID != destinationID else { return }
        var ids = orderedReviewSessions(
            reviewSessionLinks.sorted { $0.createdAt > $1.createdAt }
        ).map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sessionID),
              let destinationIndex = ids.firstIndex(of: destinationID) else { return }
        ids.remove(at: sourceIndex)
        ids.insert(sessionID, at: destinationIndex)
        chatOrder = ids
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

    var isScreenRecordModeActive: Bool {
        screenRecordScope != nil
    }

    /// Re-derives `screenRecordScope` from the setting and the loaded
    /// Notebooks. Called on `ScreenRecordMode.didChangeNotification` (Studio
    /// windows subscribe) and after every Notebooks load.
    func refreshScreenRecordScope() {
        let goals = learningGoals
        let next = ScreenRecordScope.resolve(
            notebookSourceIDs: { notebookID in
                goals.first { $0.id == notebookID }?.approvedSourceIDs ?? []
            },
            takeSourceIDs: { cutoff in
                goals.filter { $0.createdAt >= cutoff }.flatMap(\.approvedSourceIDs)
            }
        )
        guard next != screenRecordScope else {
            // A Notebooks load can change which courses the recording Notebook follows.
            refreshScreenRecordShownCourses()
            return
        }
        screenRecordScope = next
        invalidateSidebarCachesInEveryWindow()
        // Docs, Sites and Animations are filtered as they load, so the list
        // in memory has to be read again under the new scope.
        guard hasLoadedArtifactsOnce else { return }
        Task { [weak self] in
            guard let self, let reloaded = try? await self.loadScopedArtifacts() else { return }
            self.artifacts = reloaded
        }
    }

    /// Whether a row draws its relative date while recording: only a date from
    /// the take (`ScreenRecordScope.showsDateStamp`); every date when the mode is off.
    func showsDateStamp(_ date: Date) -> Bool {
        screenRecordScope?.showsDateStamp(date) ?? true
    }

    func isVisibleInRecordingMode(createdAt: Date) -> Bool {
        screenRecordScope?.allowsItem(createdAt: createdAt) ?? true
    }

    /// A chat shows while recording only when it was started during the take
    /// (`ScreenRecordScope.allowsItem`, 560f8a8): being filed under the
    /// recording Notebook or about a filmed source is not enough.
    func isVisibleInRecordingMode(_ session: ReviewSessionRecord) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: session.createdAt,
            notebookIDs: recordingNotebookIDs(linkedTo: [session.goalID])
        ) ?? true
    }

    /// A Doc, Site or Animation shows while recording only when it was made
    /// during the take: being filed under or linked to the recording Notebook,
    /// or citing a filmed source, is not enough.
    func isVisibleInRecordingMode(_ artifact: ArtifactRecord) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: artifact.createdAt,
            notebookIDs: NotebookMembership.filingNotebookIDs(of: artifact)
        ) ?? true
    }

    /// An Idea shows while recording only when it was jotted during the take.
    func isVisibleInRecordingMode(_ idea: IdeaRecord) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: idea.createdAt,
            notebookIDs: recordingNotebookIDs(linkedTo: NotebookMembership.filingNotebookIDs(of: idea))
        ) ?? true
    }

    /// A canvas shows while recording only when it was made during the take,
    /// whatever Notebook it belongs to or is placed on it: its name and
    /// layout are the learner's.
    func isVisibleInRecordingMode(_ canvas: KnowledgeMapCanvas) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: canvas.createdAt,
            notebookIDs: recordingNotebookIDs(linkedTo: [canvas.notebookID])
        ) ?? true
    }

    /// A list of goals or ideas shows while recording only when it was made
    /// during the take: it is filed under no Notebook, and its name is the
    /// learner's own whatever it holds.
    func isVisibleInRecordingMode(_ list: SpaceList) -> Bool {
        isVisibleInRecordingMode(createdAt: list.createdAt)
    }

    /// The Notebook ids an item linked to `goalIDs` is filed under: the ids
    /// themselves and each Goal's parent Notebook, so work filed under a Goal
    /// nested in the recording Notebook counts as filed under the Notebook —
    /// the notebook rule (`NotebookMembership.filingNotebookIDs`), which
    /// `MCPDataStore.screenRecordNotebookIDs` answers for MCP too.
    private func recordingNotebookIDs(linkedTo goalIDs: [String?]) -> [String?] {
        var parents: [String: String] = [:]
        for goalID in goalIDs.compactMap({ $0 }) where parents[goalID] == nil {
            if let parent = learningGoals.first(where: { $0.id == goalID })?.parentNotebookID {
                parents[goalID] = parent
            }
        }
        return NotebookMembership.filingNotebookIDs(goalIDs, goalParents: parents)
    }

    /// A source shows while recording when it belongs to the recording
    /// Notebook, was safely captured during the take, or is public with library
    /// sources on (`ScreenRecordScope.isPublicLibrarySource`).
    func isVisibleInRecordingMode(_ article: StudioArticle) -> Bool {
        screenRecordScope?.allowsSource(
            id: article.id, addedAt: article.dateAdded,
            kind: article.sourceType.rawValue, url: article.url,
            group: article.parentGroup.map(canonicalMeetingGroupID),
            show: article.domain,
            origin: article.discoveryOrigin
        ) ?? true
    }

    /// The same question by id, for rows that carry only a source id (the
    /// Today card, Planner blocks). An id the library does not hold is kept
    /// off screen: there is no date to let it through.
    func isSourceIDVisibleInRecordingMode(_ sourceID: String) -> Bool {
        guard let scope = screenRecordScope else { return true }
        if scope.allowedSourceIDs.contains(sourceID) { return true }
        guard let article = articlesById[sourceID] else { return false }
        return isVisibleInRecordingMode(article)
    }

    /// The timebound Goals belonging to a given Notebook, nearest deadline first.
    func goals(inNotebook notebookID: String) -> [LearningGoalRecord] {
        learningGoals
            .filter { $0.isNotebookGoal && $0.parentNotebookID == notebookID }
            .sorted { $0.endAt < $1.endAt }
    }

    /// Every Goal the learner has set, nearest deadline first — the ones tagged
    /// to a Notebook and the ones standing alone alike. This is what the Goals
    /// tab lists; a Notebook's inspector still asks for its own with
    /// `goals(inNotebook:)`.
    ///
    /// Team-scoped the way `notebooks` is: a Goal tagged to a team's Notebook
    /// belongs to that library. An untagged Goal carries no team and is the
    /// learner's own, so it shows in My Library only.
    ///
    /// In the order the learner made (`LearningGoalRecord.listOrder`): the
    /// Goals placed by hand first, then the rest by deadline.
    var allGoals: [LearningGoalRecord] {
        learningGoals
            .filter { goal in
                guard goal.isGoal,
                      screenRecordScope?.allowsItem(createdAt: goal.createdAt, notebookIDs: [goal.parentNotebookID]) ?? true
                else { return false }
                return goal.teamID == activeTeamID
            }
            .sorted(by: LearningGoalRecord.listOrder)
    }

    /// The active Goals, split into the ones close enough to be working on and
    /// the ones still over the horizon. Within a band the learner's order
    /// stands; where none was made, an overdue Goal leads the first band,
    /// because a deadline that has passed is the most urgent thing on the
    /// list and `allGoals`' deadline ordering already puts it first.
    func goalBands(now: Date = Date(), calendar: Calendar = .current) -> (inFlight: [LearningGoalRecord], later: [LearningGoalRecord], done: [LearningGoalRecord]) {
        var inFlight: [LearningGoalRecord] = []
        var later: [LearningGoalRecord] = []
        var done: [LearningGoalRecord] = []
        for goal in allGoals {
            if goal.isDone || goal.isArchived {
                done.append(goal)
            } else if (goal.daysRemaining(asOf: now, calendar: calendar) ?? 0) > Self.goalHorizonDays {
                later.append(goal)
            } else {
                inFlight.append(goal)
            }
        }
        // Finished work reads newest first; what is still open reads by deadline.
        done.sort { $0.updatedAt > $1.updatedAt }
        return (inFlight, later, done)
    }

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
    var showBookImportError = false
    /// Said after a book import that succeeded with parts missing, such as a
    /// damaged EPUB whose lost chapters the learner should replace, or a book
    /// the source classifier reads as a paper.
    var bookImportNotice: String?
    var bookImportNoticeTitle = "Book Imported With Parts Missing"
    var showBookImportNotice = false
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
    var isAccepting = false
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
        UserDefaults.standard.stringArray(forKey: "podcasts.youtubeFallbackShows") ?? []
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
    var browserAccessPromptDismissed = UserDefaults.standard.bool(
        forKey: StudioViewModel.browserAccessPromptDismissedKey
    )
    var podcastAccessPromptDismissed = UserDefaults.standard.bool(
        forKey: StudioViewModel.podcastAccessPromptDismissedKey
    )
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
    var podcastSortMode: PodcastSortMode = PodcastSortMode(rawValue: UserDefaults.standard.string(forKey: "podcastSortMode") ?? "") ?? .date {
        didSet {
            PreferenceStore.set(podcastSortMode.rawValue, forKey: "podcastSortMode")
            resetDisplayLimits()
        }
    }
    var videoSortMode: VideoSortMode = VideoSortMode(rawValue: UserDefaults.standard.string(forKey: "videoSortMode") ?? "") ?? .liked {
        didSet {
            PreferenceStore.set(videoSortMode.rawValue, forKey: "videoSortMode")
            resetDisplayLimits()
        }
    }
    var meetingListOrder: MeetingListOrder = MeetingListOrder(rawValue: UserDefaults.standard.string(forKey: "meetingListOrder") ?? "") ?? .bySeries {
        didSet {
            PreferenceStore.set(meetingListOrder.rawValue, forKey: "meetingListOrder")
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

    /// The canvas open on this Mac: the whole library on one zoomable plane,
    /// the learner's layout of it, and the lens a chat may show over it
    /// (docs/knowledge-map-design.md). Replaced, never turned into another
    /// canvas, by `showCanvas` (StudioViewModel+Canvases.swift).
    var knowledgeMap = KnowledgeMapModel(mapID: KnowledgeMapOpenCanvas.initialID(
        stored: KnowledgeMapOpenCanvas.storedID,
        canvases: KnowledgeMapRows.canvases()
    ))

    /// Every canvas the learner has, as the Space lists them
    /// (`KnowledgeMapCanvases`), reseeded from the rows after each act and
    /// each remote change.
    var canvases = KnowledgeMapRows.canvases()

    /// The Atlas on screen, its focus, level and what is being written
    /// (docs/atlas-design.md).
    let atlas = AtlasModel()

    // MARK: - Teams

    /// The library the Studio shows: nil is My Library, otherwise a team's id.
    /// One library at a time; switching reloads sources, Notebooks, Docs and
    /// chats for that namespace. Persisted so a relaunch reopens the same one.
    var activeTeamID: String? = {
        let raw = UserDefaults.standard.string(forKey: StudioViewModel.activeTeamPreferenceKey)
        return raw?.isEmpty == false ? raw : nil
    }() {
        didSet {
            UserDefaults.standard.set(activeTeamID ?? "", forKey: StudioViewModel.activeTeamPreferenceKey)
            // Which team's courses the Courses home lists depends on it.
            allCourseGroupNamesCache = nil
            visibleCourseGroupNamesCache = nil
        }
    }
    static let activeTeamPreferenceKey = "studio.activeTeamID"
    /// Every team this account owns or joined, for the switcher and the menus.
    var teams: [TeamRecord] = []
    /// The Docs shared through a Doc space, by Doc id: the ones this account shares and the ones
    /// shared with it (`refreshSharedDocs`). A menu reads it; nothing here touches iCloud.
    var sharedDocs: [String: SharedDocState] = [:]
    /// The roster of each team, keyed by team id, as last read from its share.
    var teamMembersByTeamID: [String: [TeamMemberRecord]] = [:]
    /// Task boards, keyed by Notebook id, loaded when a Notebook page opens.
    var notebookTasksByNotebookID: [String: [NotebookTaskRecord]] = [:]
    /// What other members have assigned to this account, in every team
    /// (docs/family-design.md), for the Today panel's Assigned section.
    var assignedToMe: [AssignedTask] = []
    /// Each editable team's members other than this account, read from the
    /// stored roster, for the Assign to menu in any library.
    var assignableMembersByTeamID: [String: [TeamMemberRecord]] = [:]
    /// The proxy's view of this account's families, as last fetched.
    var familyPlanStatus: FamilyPlanClient.Status?
    /// When the member side of family plans last ran, for its cooldown.
    @ObservationIgnored var familyPlanSyncedAt: Date?
    @ObservationIgnored var familyPlanSyncTask: Task<Void, Never>?
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
    var reviewChatFocusRequestID: UUID?
    /// Token used by Reader "Chat about this" actions to let the Studio shell
    /// reclaim side-panel width after the Reader and Chat panes are visible.
    /// Width belongs to the view, so the view model only publishes the intent.
    var readerChatSpaceRequestID: UUID?
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

    // Inline editing
    var editingCardId: String?

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
        let raw = UserDefaults.standard.stringArray(forKey: "studio.hiddenTabs") ?? []
        let stored = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
        return stored.union(StudioViewModel.integrationTabUnpinState().pending)
    }() {
        didSet {
            let raw = Array(hiddenTabs.map(\.rawValue))
            PreferenceStore.set(raw, forKey: "studio.hiddenTabs")
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
        let raw = UserDefaults.standard.stringArray(
            forKey: StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey
        ) ?? []
        return Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
    }() {
        didSet {
            PreferenceStore.set(
                autoUnpinnedIntegrationTabs.map(\.rawValue).sorted(),
                forKey: StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey
            )
        }
    }

    /// Which integration tabs have already had their one-time unpin, and which
    /// are still owed one. Pure read, safe from a property initializer.
    static func integrationTabUnpinState() -> (applied: Set<String>, pending: [StudioSidebarTab]) {
        let defaults = UserDefaults.standard
        let applied = Set(
            defaults.stringArray(forKey: StudioSidebarTab.integrationUnpinAppliedPreferenceKey) ?? []
        )
        let pending = StudioSidebarTab.allCases.filter {
            $0.requiresIntegrationSetup && !applied.contains($0.rawValue)
        }
        return (applied, pending)
    }

    /// Unpins each integration tab exactly once per account.
    ///
    /// A brand-new library used to open with Google Drive, Read AI, Zoom and X
    /// already pinned, which reads as "these apps are set up" to someone who has
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
        PreferenceStore.set(
            applied.sorted(),
            forKey: StudioSidebarTab.integrationUnpinAppliedPreferenceKey
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
        let raw = UserDefaults.standard.stringArray(forKey: "studio.tabOrder") ?? []
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
            PreferenceStore.set(reconciled.map(\.rawValue), forKey: "studio.tabOrder")
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
            PreferenceStore.set(
                Array(excludedKnowledgeTabs.map(\.rawValue)).sorted(),
                forKey: StudioSidebarTab.knowledgeExclusionPreferenceKey
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
        let raw = UserDefaults.standard.stringArray(forKey: "studio.courseOrder") ?? []
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
            PreferenceStore.set(raw, forKey: "studio.courseOrder")
        }
    }

    /// User-created course IDs (persisted in UserDefaults). Auto-discovered courses
    /// don't need to be here — they're identified by sourceType/discoveryOrigin.
    var userCourseNames: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: "userCourseNames") ?? []
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

    /// The latest finished sitting of each lecture's quiz, keyed by the
    /// lecture video's source id; the quiz row under the lecture shows it
    /// (docs/lecture-quiz-design.md). Mirrors the `lectureQuiz.score.*`
    /// preference rows into observable state, reseeded when another Mac's
    /// sitting arrives (`reloadSyncedPreferences`).
    var lectureQuizScores: [String: LectureQuizScore] = LectureQuizScore.scoresFromDefaults()

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
        let arr = UserDefaults.standard.stringArray(forKey: "userMeetingGroupNames") ?? []
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
        guard let raw = UserDefaults.standard.string(forKey: "studio.expandedPanel") else { return nil }
        return StudioExpandedPanel(rawValue: raw)
    }() {
        didSet {
            if let expandedPanel {
                PreferenceStore.set(expandedPanel.rawValue, forKey: "studio.expandedPanel")
            } else {
                PreferenceStore.remove(forKey: "studio.expandedPanel")
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
    var showSearchPanel: Bool = UserDefaults.standard.object(forKey: "studio.showSearchPanel") as? Bool ?? true {
        didSet { PreferenceStore.set(showSearchPanel, forKey: "studio.showSearchPanel") }
    }

    /// Whether the docked Chat surface is on screen — i.e. the Chat tab is the
    /// active tab of its center group. The legacy name remains so the existing
    /// review-navigation call sites continue to reveal Chat consistently.
    var showAssistantOverlay: Bool {
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
    /// presented. The Mac has had no voice conversation since 2026-10-01, so
    /// nothing sets this any more; the window still clears it wherever it
    /// clears transient presentation, until those resets go too.
    var isVoiceWorkspacePresented: Bool {
        get { activeWindowState.isVoiceWorkspacePresented }
        set { activeWindowState.isVoiceWorkspacePresented = newValue }
    }

    // MARK: - Memory review focus

    /// The review the active window is giving itself over to, if any.
    var memoryReviewFocusSessionID: String? {
        get { activeWindowState.memoryReviewFocusSessionID }
        set { activeWindowState.memoryReviewFocusSessionID = newValue }
    }

    /// The window becomes the review: rail, Sources, and every other center tab
    /// step aside for it. Nothing underneath is changed, so leaving puts the
    /// workspace back exactly as it was.
    ///
    /// Taking the window is the commitment the review promised before it
    /// started: from here, leaving before the goal ends today's session
    /// (`MemoryReviewEngagementTracker.beginCommittedSession`). A day's
    /// review chat from before cards; the card review enters through
    /// `enterMemoryCardFocus`.
    func enterMemoryReviewFocus(sessionID: String, in windowState: StudioWindowState? = nil) {
        let target = windowState ?? activeWindowState
        target.isVoiceWorkspacePresented = false
        target.memoryReviewFocusSessionID = sessionID
        MemoryReviewEngagementTracker.shared.beginCommittedSession()
    }

    /// Leaves the review. `sessionID` leaves only that review, so a chat that
    /// moved on cannot end a review the learner is still in.
    ///
    /// Leaving is ending: whichever door the learner takes — the × by the
    /// clock, a shortcut to another surface, the pane moved on to another
    /// chat — today's session is over unless its goal is already met. The one
    /// exception is `endingSession: false`, for a review that never began.
    /// A card review asks its sitting too: one whose first deal is answered
    /// through, or that made no commitment (practice, a day already done),
    /// is not left early, so leaving it ends nothing
    /// (`MemoryCardSessionModel.leavingEndsSession`).
    func leaveMemoryReviewFocus(
        sessionID: String? = nil,
        in windowState: StudioWindowState? = nil,
        endingSession: Bool = true
    ) {
        let target = windowState ?? activeWindowState
        guard let focused = target.memoryReviewFocusSessionID else { return }
        if let sessionID, sessionID != focused { return }
        let cardSession = target.memoryCardSession
        target.memoryReviewFocus = nil
        if endingSession, cardSession?.leavingEndsSession ?? true {
            MemoryReviewEngagementTracker.shared.endSession()
        } else {
            MemoryReviewEngagementTracker.shared.abandonCommitment()
        }
        if let cardSession { cardSessionDidEnd(cardSession) }
    }

    // MARK: - Center tab groups

    /// The center area's VS Code-style arrangement: one or two side-by-side groups of
    /// tabs over the five singleton surfaces (Chat, Reader, Schedule, Notepad,
    /// Notebooks).
    /// Tabs rather than modal overlays so the
    /// Sources panel stays visible and hit-testable — sources can be dragged
    /// straight into schedule days or onto a notebook card. The arrangement is
    /// restored independently for each window. The most recently edited layout
    /// is also synced as the template for a newly opened window.
    ///
    /// The complete arrangement is restored on launch. Pane layout is working
    /// state, not a transient modal, so silently replacing it with Chat made the
    /// persistence affordance dishonest and repeatedly discarded the learner's
    /// chosen context.
    var centerTabGroups: StudioCenterTabGroups {
        get { activeWindowState.centerTabGroups }
        set { activeWindowState.centerTabGroups = newValue }
    }

    /// One visible surface per group — or, in a window holding a notebook,
    /// what the notebook's center shows (`visibleCenterTabs(in:)`).
    var activeCenterTabs: Set<StudioCenterTab> {
        visibleCenterTabs(in: activeWindowState)
    }

    /// A source row is navigation on its first click, regardless of the current
    /// center layout. Shift-click remains the explicit multi-selection gesture;
    /// rows remain draggable through their existing drag recognizer.
    var opensSidebarSourcesOnSingleClick: Bool {
        true
    }

    /// Closes `tab`'s tab — the × on it in a strip. With other tabs
    /// open in its pane, the pane shows the neighbouring one and `tab` stays
    /// parked there; as the pane's only tab it closes the way the pane's ×
    /// does (`dismissCenterSurface`).
    ///
    /// `groupID` names the pane whose strip was clicked, which matters for a
    /// place with a copy in several panes (`StudioCenterTab.copyablePlaces`).
    func closeCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        guard let index = layout.index(holding: tab, preferring: groupID, openOnly: true) else { return }
        guard layout.groups[index].closeTab(tab) else {
            dismissCenterSurface(tab, fromGroup: layout.groups[index].id, in: destination)
            return
        }
        // Assigned even when only the strip changed: `==` compares what the
        // panes show, and a background tab closing changes none of that.
        destination.centerTabGroups = layout
    }

    /// Brings `tab` on screen by making it its group's active tab.
    ///
    /// A command can target a window other than the key one — sending a source
    /// to a second Studio window has to reveal that window's Reader, not the
    /// one belonging to the window the menu was opened in.
    func activateCenterTab(
        _ tab: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        // A beta feature's pane opens only where the feature shows
        // (`BetaFeatures`); anywhere else the call changes nothing.
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented {
            destination.isVoiceWorkspacePresented = false
        }
        // Asking for another surface — from a menu, a shortcut, or a source
        // opened out of the review's own strip — is leaving the review. The
        // rail and the tabs are already gone while it runs, so this is the
        // learner choosing to go, and the workspace comes back with them
        // rather than the request landing somewhere they cannot see. A card
        // review yields to Chat too: no chat is on screen in it.
        if destination.memoryReviewFocusYields(to: tab) {
            leaveMemoryReviewFocus(in: destination)
        }
        // A tab already open comes to the front where it is; anything else
        // opens as a new tab in the pane the learner last clicked in, and
        // what that pane showed stays one of its tabs.
        guard let layout = destination.centerTabGroups.activating(
            tab,
            focusedGroupID: destination.focusedGroupID
        ) else { return }
        // Guarded rather than self-assigning: @Observable routes every
        // assignment through withMutation and would invalidate observers (and
        // enqueue a preference save) on a no-op.
        if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
    }

    /// Hides `tab`, which closes its tab. With other tabs open in its pane,
    /// the neighbouring one shows (`Group.closeTab`). As the pane's only tab
    /// it reveals a groupmate instead — the Space, the shell's home surface
    /// (the Notebooks home was until 2026-10-09, docs/notebooks-design.md):
    /// closing the last thing in the center lands on it, not on an empty
    /// Reader. Dismissing the Space itself reveals Chat, since a surface
    /// cannot be replaced by itself. A tab alone in its group dissolves the
    /// group and parks, inactive, at the end of the neighboring one (VS Code's
    /// close-last-editor-closes-the-group); with a single group there is
    /// nowhere to park and the request is ignored.
    func deactivateCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        guard let index = layout.index(holding: tab, preferring: groupID),
              layout.groups[index].activeTab == tab else { return }
        if layout.groups[index].closeTab(tab) {
            destination.centerTabGroups = layout
            return
        }
        if layout.groups[index].tabs.count == 1 {
            guard layout.groups.count > 1 else { return }
            layout.groups.remove(at: index)
            let neighbor = min(index, layout.groups.count - 1)
            layout.groups[neighbor].tabs.append(tab)
            destination.centerTabGroups = layout
            return
        }
        let tabs = layout.groups[index].tabs
        // Closing a surface in a pane shows the Space, the window's home, or
        // Chat when it is the Space that closes.
        let home: StudioCenterTab = tab == .artifacts ? .chat : .artifacts
        if tabs.contains(home) {
            layout.groups[index].activeTab = home
        } else {
            let position = tabs.firstIndex(of: tab) ?? 0
            layout.groups[index].activeTab = tabs[position == 0 ? 1 : position - 1]
        }
        // The closed surface is parked, not a tab behind its home.
        layout.groups[index].openTabs.removeAll { $0 == tab }
        destination.centerTabGroups = layout
    }

    /// Closes the pane containing `tab` by moving all of its tabs into the
    /// adjacent pane. Tabs keep their order and the surviving pane keeps its
    /// current selection. A lone pane cannot be closed because there is no
    /// destination for its permanent tabs.
    func closeCenterPane(
        containing tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let windowState = destinationWindowState ?? activeWindowState
        var layout = windowState.centerTabGroups
        guard layout.groups.count > 1,
              let source = layout.index(holding: tab, preferring: groupID) else { return }

        let closingTabs = layout.groups.remove(at: source).tabs
        let destination = min(source, layout.groups.count - 1)
        if source < layout.groups.count {
            layout.groups[destination].tabs.insert(contentsOf: closingTabs, at: 0)
        } else {
            layout.groups[destination].tabs.append(contentsOf: closingTabs)
        }
        windowState.centerTabGroups = layout
    }

    /// Dismisses the visible center surface without allowing a one-pane
    /// workspace to become a dead end. A split pane closes into its neighbor;
    /// in the sole remaining pane, dismissal reveals one of that pane's other
    /// destinations instead — except a chat playing a walk, which ends the
    /// walk and opens New chat there (`leaveWalkthroughForNewChat`).
    func dismissCenterSurface(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        // The Reader a card's source opened beside the card review closes
        // back to the review alone; the panes underneath are not on screen.
        if tab == .reader, let session = destination.memoryCardSession {
            session.besideSourceID = nil
            return
        }
        if destination.centerTabGroups.groups.count > 1 {
            closeCenterPane(containing: tab, fromGroup: groupID, in: destination)
        } else if tab == .chat, leaveWalkthroughForNewChat(in: destination) {
            // The walk was the chat's content; the pane stays on Chat.
        } else {
            deactivateCenterTab(tab, fromGroup: groupID, in: destination)
        }
    }

    /// Moves a tab into the pane at `groupIndex`, as its strip's tab at
    /// `position` (out-of-range values clamp), and shows it there: a tab
    /// dropped on a strip. A pane left with no tab dissolves, VS Code style.
    func moveCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        toGroup groupIndex: Int,
        at position: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        var layout = window.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        var destination = max(0, min(groupIndex, layout.groups.count - 1))
        var insertAt = position
        if source == destination {
            let open = layout.groups[source].openTabs
            if let current = open.firstIndex(of: tab), current < insertAt { insertAt -= 1 }
        } else {
            let sourceWasAlone = layout.groups[source].openTabs == [tab]
            layout.groups[source].remove(tab)
            if sourceWasAlone {
                // Its parked surfaces go with the pane they are dropped on.
                let parked = layout.groups.remove(at: source).tabs
                if source < destination { destination -= 1 }
                layout.groups[destination].tabs.append(contentsOf: parked)
            }
            layout.groups[destination].tabs.append(tab)
        }
        var open = layout.groups[destination].openTabs.filter { $0 != tab }
        open.insert(tab, at: max(0, min(insertAt, open.count)))
        layout.groups[destination].openTabs = open
        layout.groups[destination].activeTab = tab
        window.centerTabGroups = layout
    }

    /// Slides the whole group containing `tab` one slot left or right. This is
    /// the meaningful move for a tab alone in its group, where a "split" has
    /// nothing to separate: asking to split such a tab to an adjacent slot
    /// resolves to the position it already occupies, so it would do nothing.
    /// A request past either end is ignored.
    func moveCenterGroup(
        containing tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        by offset: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        var layout = window.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        let destination = source + offset
        guard layout.groups.indices.contains(destination) else { return }
        layout.groups.swapAt(source, destination)
        window.centerTabGroups = layout
    }

    /// Exchanges the two panes that meet at a divider. The destination window
    /// is explicit because a click in a secondary Studio window must never
    /// reorder whichever window happened to be key most recently.
    func swapCenterGroups(
        adjacentToDividerAt dividerIndex: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        let trailingIndex = dividerIndex + 1
        guard layout.groups.indices.contains(dividerIndex),
              layout.groups.indices.contains(trailingIndex) else { return }
        layout.groups.swapAt(dividerIndex, trailingIndex)
        destination.centerTabGroups = layout
    }

    /// Context-menu split semantics relative to the tab's current group. A tab
    /// with other tabs open beside it peels into a new adjacent group. A tab
    /// alone in its strip slides that group one slot in the requested
    /// direction; keeping the same Split Left/Right commands makes the action
    /// predictable regardless of the current partition and avoids the
    /// adjacent-index no-op.
    func splitCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        towardRight: Bool,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        guard let source = window.centerTabGroups.index(holding: tab, preferring: groupID) else { return }
        let sourceID = window.centerTabGroups.groups[source].id
        if window.centerTabGroups.groups[source].openTabs == [tab] {
            moveCenterGroup(containing: tab, fromGroup: sourceID, by: towardRight ? 1 : -1, in: window)
        } else {
            moveCenterTabToNewGroup(tab, fromGroup: sourceID, at: source + (towardRight ? 1 : 0), in: window)
        }
    }

    /// The split button at the end of a pane's strip, and ⌘\: a new pane
    /// beside the pane at `groupIndex` showing `tab` — a fresh copy of it when
    /// the place can stand in several panes (Pages: its list, to pick another
    /// page), else the place itself moved out of the pane that has it, as
    /// Split Right on its tab does. Nothing happens at the pane limit.
    func splitPane(
        at groupIndex: Int,
        showing tab: StudioCenterTab,
        towardRight: Bool = true,
        in window: StudioWindowState
    ) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab),
              window.centerTabGroups.groups.indices.contains(groupIndex),
              window.centerTabGroups.canCreateDraggedGroup else { return }
        if window.isVoiceWorkspacePresented { window.isVoiceWorkspacePresented = false }
        if window.memoryReviewFocusYields(to: tab) { leaveMemoryReviewFocus(in: window) }
        // Chat beside a Chat already open is a new side chat, and the Reader
        // beside a Reader a side reader; open nowhere, the window's own chat
        // or Reader moves beside.
        var tab = tab
        if StudioCenterTab.windowPlaces.contains(tab),
           window.centerTabGroups.groups.contains(where: { $0.openTabs.contains(tab) }),
           let copy = tab.splitCopy {
            tab = copy
        }
        // A side reader starts on what the pane it was split from reads, or
        // else on the window's Reader's source.
        let splitFrom = window.centerTabGroups.groups[groupIndex]
        let sideReaderSource = splitFrom.activeTab == .secondaryReader
            ? window.sideReaderSources[splitFrom.id]
            : window.readerSourceID(fallingBackTo: selectedArticleId)
        if let layout = window.centerTabGroups.splitting(tab, besidePaneAt: groupIndex, towardRight: towardRight) {
            let newIndex = towardRight ? groupIndex + 1 : groupIndex
            let newID = layout.groups[newIndex].id
            window.centerTabGroups = layout
            window.focusedGroupID = newID
            window.splitFromPane[newID] = splitFrom.id
            if tab == .secondaryReader, let sideReaderSource {
                window.sideReaderSources[newID] = sideReaderSource
            }
            // The copy opens on the list of pages, not on the page beside it.
            if tab == .notepad {
                artifactIndexRequest = ArtifactIndexRequest(section: .docs, windowID: window.id, groupID: newID)
            }
            return
        }
        guard let source = window.centerTabGroups.index(holding: tab, preferring: nil) else { return }
        let sourceID = window.centerTabGroups.groups[source].id
        if source == groupIndex {
            // The pane's own tab: it peels off beside, or a lone one moves.
            splitCenterTab(tab, fromGroup: sourceID, towardRight: towardRight, in: window)
        } else {
            moveCenterTabToNewGroup(tab, fromGroup: sourceID, at: towardRight ? groupIndex + 1 : groupIndex, in: window)
        }
    }

    /// ⌘\: a copy of what the pane last clicked in shows, beside it, when
    /// that place can stand in several panes — a new side chat for a chat.
    func splitFocusedPane(in window: StudioWindowState? = nil) {
        let window = window ?? activeWindowState
        let groups = window.centerTabGroups.groups
        let index = groups.firstIndex(where: { $0.id == window.focusedGroupID }) ?? 0
        guard groups.indices.contains(index), let copy = groups[index].activeTab.splitCopy else { return }
        splitPane(at: index, showing: copy, in: window)
    }

    /// Opens a hidden destination without replacing the surface currently
    /// visible in its group. Navigation rows expose this as "Open Beside" now
    /// that the permanent center tab strip is hidden. An already-visible tab
    /// is simply brought forward. At the two-pane limit, the destination is
    /// activated in the group where it is already parked, replacing that
    /// pane's visible surface so a third pane is never created.
    func openCenterTabBeside(_ tab: StudioCenterTab) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        if isVoiceWorkspacePresented { isVoiceWorkspacePresented = false }
        if activeWindowState.memoryCardSession != nil { leaveMemoryReviewFocus(in: activeWindowState) }
        guard let source = centerTabGroups.groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return }

        if centerTabGroups.groups[source].activeTab == tab {
            activateCenterTab(tab)
            return
        }
        guard centerTabGroups.canCreateGroup else {
            let coreTabs: Set<StudioCenterTab> = [.chat, .notepad, .sites, .animations, .artifacts, .browser]
            if coreTabs.contains(tab),
               let replacement = centerTabGroups.groups.firstIndex(where: {
                   !coreTabs.contains($0.activeTab)
               }),
               replacement != source {
                var layout = centerTabGroups
                layout.groups[source].remove(tab)
                layout.groups[replacement].tabs.append(tab)
                layout.groups[replacement].activeTab = tab
                centerTabGroups = layout
                return
            }
            activateCenterTab(tab)
            return
        }
        moveCenterTabToNewGroup(tab, at: source + 1)
    }

    /// Shows `tab` in the pane at `groupIndex` of `destination`, in place of
    /// what that pane showed: a destination from the sidebar dropped on a
    /// pane. A window holding a notebook has no panes to pick from, so there
    /// the tab opens in a pane of the window.
    ///
    /// `startsBlankChat` is the rail's "New chat" row, which means a fresh
    /// conversation in the pane it lands on. `destination` is explicit for the
    /// reason `placeCenterTabAtEdge` takes one: the drop names its own window.
    func replaceCenterPane(
        at groupIndex: Int,
        with tab: StudioCenterTab,
        startsBlankChat: Bool = false,
        in destination: StudioWindowState
    ) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        if destination.memoryReviewFocusYields(to: tab) { leaveMemoryReviewFocus(in: destination) }
        let hadTab = destination.centerTabGroups.groups.indices.contains(groupIndex)
            && destination.centerTabGroups.groups[groupIndex].tabs.contains(tab)
        guard let layout = destination.centerTabGroups.replacingPane(at: groupIndex, with: tab) else { return }
        if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
        if startsBlankChat { inWindow(destination) { requestNewChat() } }
        // A Pages copy made here opens on the list of pages, as a split's does.
        // (`paneShowing` is non-nil only while two panes show Pages.)
        if tab == .notepad, !hadTab, paneShowing(.notepad, in: destination) != nil,
           destination.centerTabGroups.groups.indices.contains(groupIndex) {
            artifactIndexRequest = ArtifactIndexRequest(
                section: .docs,
                windowID: destination.id,
                groupID: destination.centerTabGroups.groups[groupIndex].id
            )
        }
    }

    // MARK: Tabs between windows

    /// Where a tab dragged out of another window lands in this one.
    enum CenterTabArrival: Equatable {
        /// On the strip of the pane at `group`, before its tab at `position`
        /// (`.max` is the end). A drop on the pane's body lands at the end.
        case strip(group: Int, position: Int)
        /// At the far edge of the center area, a pane of its own there.
        case edge(leading: Bool)
    }

    /// A tab dragged from one window's strip onto another window (product
    /// owner, 2026-11-08: "If I have two windows open on two screens side by
    /// side, make it easy to move a tab from one window to the next"). The
    /// place opens where it was dropped, showing what it showed there — the
    /// Reader its source, a side reader its source, Pages its page — and
    /// closes in the window it left, as its × would. A Browser arrives on this
    /// window's own pages. A chat moves through the windows' chat stores,
    /// which are view state (`StudioCenterTabGroupsView`), not through here.
    func moveCenterTab(
        _ tab: StudioCenterTab,
        fromGroup originGroupID: UUID,
        of origin: StudioWindowState,
        arriving arrival: CenterTabArrival,
        in destination: StudioWindowState
    ) {
        guard origin !== destination else { return }
        // What it shows, read before the window it leaves lets go of it.
        let sourceID: String?
        switch tab {
        case .reader: sourceID = origin.readerArticleID
        case .secondaryReader: sourceID = origin.sideReaderSources[originGroupID]
        default: sourceID = nil
        }
        let artifactID = tab == .notepad ? origin.openArtifactID : nil
        let place = destination.centerTabGroups.arrivingPlace(for: tab)
        guard let paneID = receiveCenterTab(place, arriving: arrival, in: destination) else { return }
        closeCenterTab(tab, fromGroup: originGroupID, in: origin)
        if let sourceID, articlesById[sourceID] != nil {
            if place == .secondaryReader {
                destination.sideReaderSources[paneID] = sourceID
            } else {
                Task { await selectArticle(sourceID, in: destination) }
            }
        }
        if let artifactID {
            artifactRevealRequest = ArtifactRevealRequest(artifactID: artifactID, section: .docs, windowID: destination.id)
        }
    }

    /// Puts `place`, come in from another window, where `arrival` says, in
    /// front there and in the pane a sidebar click next opens into. Returns
    /// that pane's id; nil when there was nowhere to put it.
    @discardableResult
    func receiveCenterTab(
        _ place: StudioCenterTab,
        arriving arrival: CenterTabArrival,
        in destination: StudioWindowState
    ) -> UUID? {
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        if destination.memoryCardSession != nil { leaveMemoryReviewFocus(in: destination) }
        let paneID: UUID?
        switch arrival {
        case .strip(let group, let position):
            let groups = destination.centerTabGroups.groups
            guard !groups.isEmpty else { return nil }
            let index = max(0, min(group, groups.count - 1))
            let target = groups[index].id
            guard let layout = destination.centerTabGroups.receiving(place, inPaneAt: index, at: position) else { return nil }
            destination.centerTabGroups = layout
            paneID = target
        case .edge(let leading):
            if place.canStandInSeveralPanes {
                // A copy: a new pane of its own at the edge, or at the pane
                // limit a tab of the edge pane.
                var layout = destination.centerTabGroups
                guard layout.canCreateDraggedGroup else {
                    let edgePane = leading ? 0 : layout.groups.count - 1
                    return receiveCenterTab(place, arriving: .strip(group: edgePane, position: .max), in: destination)
                }
                layout.groups.insert(.init(tabs: [place], activeTab: place), at: leading ? 0 : layout.groups.count)
                destination.centerTabGroups = layout
            } else {
                placeCenterTabAtEdge(place, leading: leading, in: destination)
            }
            let groups = destination.centerTabGroups.groups
            paneID = (leading ? groups.first : groups.last).flatMap { $0.activeTab == place ? $0.id : nil }
        }
        // The pane may have been dissolved and rebuilt by reconciliation;
        // answer only for one that still shows the place.
        guard let paneID,
              destination.centerTabGroups.groups.contains(where: { $0.id == paneID && $0.activeTab == place }) else { return nil }
        destination.focusedGroupID = paneID
        return paneID
    }

    /// Places a workspace destination at the requested outer edge: a tab
    /// dragged to the side to view it beside the rest. A tab sharing its pane
    /// with other tabs, or a parked one, splits into a new pane there — a third
    /// one too, since the learner chose it (`canCreateDraggedGroup`). A tab
    /// that is its pane's only tab moves the whole pane to that edge. At three
    /// panes the tab joins the edge pane as a tab of its own.
    func placeCenterTabAtEdge(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        leading: Bool,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        // A cross-window drag does not necessarily make the window under the
        // pointer key. The drop target therefore supplies its own scene state;
        // menu commands and legacy call sites continue to resolve through the
        // key-window registry when no explicit destination is provided.
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented {
            destination.isVoiceWorkspacePresented = false
        }
        if destination.memoryCardSession != nil { leaveMemoryReviewFocus(in: destination) }
        var layout = destination.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        let edge = leading ? 0 : layout.groups.count
        let isPaneOfItsOwn = layout.groups[source].openTabs == [tab]

        if isPaneOfItsOwn, layout.groups.count > 1 || layout.groups[source].tabs == [tab] {
            let group = layout.groups.remove(at: source)
            layout.groups.insert(group, at: leading ? 0 : layout.groups.count)
        } else if layout.canCreateDraggedGroup {
            // The only pane's only tab (the Library clicked in the rail fills
            // the window) docks at the edge too, and Chat, else the Reader,
            // takes the rest of the window.
            if isPaneOfItsOwn {
                let remaining = layout.groups[source].tabs.filter { $0 != tab }
                layout.groups[source].activeTab = remaining.contains(.chat)
                    ? .chat
                    : (remaining.contains(.reader) ? .reader : remaining[0])
            }
            layout.groups[source].remove(tab)
            layout.groups.insert(.init(tabs: [tab], activeTab: tab), at: edge)
        } else {
            let target = leading ? 0 : layout.groups.count - 1
            guard target != source else {
                layout.groups[source].activeTab = tab
                destination.centerTabGroups = layout
                return
            }
            layout.groups[source].remove(tab)
            layout.groups[target].tabs.append(tab)
            layout.groups[target].activeTab = tab
        }
        destination.centerTabGroups = layout
    }

    /// Creates or moves the optional comparison Chat pane to a workspace edge.
    /// The pane owns a separate session manager in `StudioView`, so activating
    /// it never replaces the conversation in the primary Chat destination.
    func openSecondaryChatPane(atLeadingEdge: Bool) {
        if isVoiceWorkspacePresented { isVoiceWorkspacePresented = false }
        // A card review shows no chat: a second one opened under it would
        // land where the learner cannot see it.
        if activeWindowState.memoryCardSession != nil { leaveMemoryReviewFocus(in: activeWindowState) }
        var layout = centerTabGroups

        if let source = layout.groups.firstIndex(where: { $0.tabs.contains(.secondaryChat) }) {
            if layout.groups[source].tabs == [.secondaryChat] {
                let group = layout.groups.remove(at: source)
                layout.groups.insert(group, at: atLeadingEdge ? 0 : layout.groups.count)
            } else if layout.canCreateGroup {
                layout.groups[source].remove(.secondaryChat)
                layout.groups.insert(
                    .init(tabs: [.secondaryChat], activeTab: .secondaryChat),
                    at: atLeadingEdge ? 0 : layout.groups.count
                )
            } else {
                layout.groups[source].activeTab = .secondaryChat
                let group = layout.groups.remove(at: source)
                layout.groups.insert(group, at: atLeadingEdge ? 0 : layout.groups.count)
            }
        } else if layout.canCreateGroup {
            layout.groups.insert(
                .init(tabs: [.secondaryChat], activeTab: .secondaryChat),
                at: atLeadingEdge ? 0 : layout.groups.count
            )
        } else {
            let target = atLeadingEdge ? 0 : layout.groups.count - 1
            layout.groups[target].tabs.append(.secondaryChat)
            layout.groups[target].activeTab = .secondaryChat
        }

        centerTabGroups = layout
    }

    /// Closes a side chat's pane: `groupID`'s, the pane whose × was pressed,
    /// when several panes hold one.
    func dismissSecondaryChatPane(
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        guard let groupIndex = layout.index(holding: .secondaryChat, preferring: groupID) else { return }
        layout.groups[groupIndex].remove(.secondaryChat)
        if layout.groups[groupIndex].tabs.isEmpty {
            layout.groups.remove(at: groupIndex)
        }
        destination.centerTabGroups = layout
    }

    /// Keep the current Reader visible while revealing Chat immediately to its
    /// right. This is the one-click path used by media readers, where merely
    /// activating Chat could otherwise replace the video the user wants to
    /// discuss.
    func revealChatBesideReader() {
        revealChat(beside: .reader)
    }

    /// Keep `companion` visible while revealing Chat beside it.
    ///
    /// A passage is handed to Chat from the surface it was selected in — the
    /// Reader, a Doc — and that surface is the one thing the handoff must
    /// neither replace nor move: the words stay where they are. If the two
    /// tabs share a group, peel Chat into a new group on the companion's
    /// right, the side the eye reads toward. If they already occupy separate
    /// groups, both panes are already on screen where the learner put them:
    /// bring each tab forward and leave the arrangement alone. Reordering the
    /// panes here swapped a chat-left, reader-right window on every Chat
    /// press, which reads as the layout jumping rather than as an answer
    /// arriving.
    func revealChat(beside companion: StudioCenterTab) {
        if isVoiceWorkspacePresented { isVoiceWorkspacePresented = false }
        let window = activeWindowState
        // A card review shows no chat: asking for one is the learner going.
        if window.memoryCardSession != nil { leaveMemoryReviewFocus(in: window) }
        var layout = centerTabGroups
        guard companion != .chat,
              let chatGroup = layout.groups.firstIndex(where: { $0.tabs.contains(.chat) }),
              let companionGroup = layout.groups.firstIndex(where: { $0.tabs.contains(companion) })
        else { return }

        if chatGroup == companionGroup {
            layout.groups[companionGroup].activeTab = companion
            layout.groups[companionGroup].remove(.chat)

            if layout.canCreateGroup {
                layout.groups.insert(.init(tabs: [.chat], activeTab: .chat), at: companionGroup + 1)
            } else {
                // At the pane limit, reuse the nearest neighbor rather than
                // replacing the companion. If it was rightmost, swap the two
                // groups so Chat still lands on its right.
                let destination = companionGroup < layout.groups.count - 1
                    ? companionGroup + 1
                    : companionGroup - 1
                layout.groups[destination].tabs.insert(.chat, at: 0)
                layout.groups[destination].activeTab = .chat
                if destination < companionGroup {
                    layout.groups.swapAt(destination, companionGroup)
                }
            }
        } else {
            layout.groups[chatGroup].activeTab = .chat
            layout.groups[companionGroup].activeTab = companion
        }

        if layout != centerTabGroups { centerTabGroups = layout }
        reviewChatPanelMode = .chat
        reviewChatFocusRequestID = UUID()
        readerChatSpaceRequestID = UUID()
    }

    /// Keep Chat visible while revealing the Reader beside it. Assistant
    /// citations use this path so opening a source never replaces the
    /// conversation the learner was reading.
    func revealReaderBesideChat() {
        revealReader(beside: .chat)
    }

    /// Keep `companion` visible while revealing the Reader beside it. A source
    /// link is followed from wherever it was written — a chat citation, a
    /// doc's source chip — and the surface it was clicked in is the one thing
    /// the click must not replace. At the two-pane limit there is no room to
    /// create another group, so Reader joins the nearest existing neighbor
    /// while `companion` stays in place.
    func revealReader(
        beside companion: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        revealCenterTab(.reader, beside: companion, in: destinationWindowState)
    }

    /// Keep `companion` visible while revealing `tab` beside it. With both in
    /// one pane, `tab` peels into a new pane next to it; at the two-pane limit
    /// it joins the nearest neighbor as a tab while `companion` stays in place.
    func revealCenterTab(
        _ tab: StudioCenterTab,
        beside companion: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        // A card review is all its window shows: a surface revealed under it
        // would land where the learner cannot see it. A link followed in the
        // Reader beside it stays in that Reader (`memoryReviewFocusYields`).
        if destination.memoryCardSession != nil, destination.memoryReviewFocusYields(to: tab) {
            leaveMemoryReviewFocus(in: destination)
        }
        guard companion != tab else {
            var layout = destination.centerTabGroups
            guard let group = layout.groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return }
            layout.groups[group].activeTab = tab
            if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
            return
        }
        var layout = destination.centerTabGroups
        guard let companionGroup = layout.groups.firstIndex(where: { $0.tabs.contains(companion) }),
              let tabGroup = layout.groups.firstIndex(where: { $0.tabs.contains(tab) })
        else { return }

        if companionGroup == tabGroup {
            layout.groups[companionGroup].activeTab = companion
            layout.groups[companionGroup].remove(tab)

            if layout.canCreateGroup {
                layout.groups.insert(
                    .init(tabs: [tab], activeTab: tab),
                    at: companionGroup + 1
                )
            } else {
                let neighbor = companionGroup < layout.groups.count - 1
                    ? companionGroup + 1
                    : companionGroup - 1
                layout.groups[neighbor].tabs.insert(tab, at: 0)
                layout.groups[neighbor].activeTab = tab
            }
        } else {
            layout.groups[companionGroup].activeTab = companion
            layout.groups[tabGroup].activeTab = tab
        }

        if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
    }

    /// Splits `tab` out into a new group at `groupIndex` (0 = far left,
    /// `groups.count` = far right). A tab already alone reorders its whole
    /// group instead — correct for the far-edge drops that pass an index past
    /// its own position, while adjacent menu actions go through
    /// `splitCenterTab(_:towardRight:)` so they do not land back where they
    /// started.
    /// At the pane limit (`draggedGroupCount`) the split request is ignored.
    func moveCenterTabToNewGroup(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        at groupIndex: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        var layout = window.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        if layout.groups[source].tabs == [tab] {
            let group = layout.groups.remove(at: source)
            let destination = max(0, min(source < groupIndex ? groupIndex - 1 : groupIndex, layout.groups.count))
            layout.groups.insert(group, at: destination)
            if layout != window.centerTabGroups { window.centerTabGroups = layout }
            return
        }
        guard layout.canCreateDraggedGroup else { return }
        layout.groups[source].remove(tab)
        let destination = max(0, min(groupIndex, layout.groups.count))
        layout.groups.insert(.init(tabs: [tab], activeTab: tab), at: destination)
        window.centerTabGroups = layout
    }

    // MARK: - Legacy surface accessors

    // Setting one of these to `false` hides only that surface — it never
    // touches what a sibling group is showing.
    var showTasksInReader: Bool {
        get { activeCenterTabs.contains(.tasks) }
        set {
            if newValue {
                activateCenterTab(.tasks)
            } else {
                deactivateCenterTab(.tasks)
            }
        }
    }

    var showNotepadInReader: Bool {
        get { activeCenterTabs.contains(.notepad) }
        set {
            if newValue {
                activateCenterTab(.notepad)
            } else {
                deactivateCenterTab(.notepad)
            }
        }
    }

    /// Brings the source reader forward in its group — the old "a source takes
    /// the slot back". Sibling groups keep whatever they are showing.
    ///
    /// One exception: when `companion` is the visible surface of the Reader's
    /// own pane — Chat, the focused state every launch starts in, or the Docs
    /// pane a source chip was clicked in — the Reader opens *beside* it
    /// instead of over it.
    /// Reading a source and talking or writing about it is the pair this app
    /// is for, and opening a source is no reason to close the conversation or
    /// the doc. The full-window Library is kept the same way: a source
    /// clicked there opens in the Reader beside it, so the list the learner
    /// is working through stays (docs/notebooks-design.md, "The full-window
    /// Library"). With the Reader's pane showing anything else, that surface
    /// is what the source takes back, exactly as before.
    func clearReaderSurfaces(
        keeping companion: StudioCenterTab = .chat,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        if let readerPane = destination.centerTabGroups.groups.first(where: { $0.tabs.contains(.reader) }),
           readerPane.activeTab == companion || readerPane.activeTab == .library {
            revealReader(beside: readerPane.activeTab, in: destination)
            return
        }
        activateCenterTab(.reader, in: destination)
    }

    /// The rail's Goals row. A place, like Docs: the list of what the
    /// learner is working toward, in deadline order.
    func openGoalsInReader(in destinationWindowState: StudioWindowState? = nil) {
        activateCenterTab(.goals, in: destinationWindowState ?? activeWindowState)
    }

    /// The rail's Ideas row. A place, like Goals: every thought jotted down,
    /// newest first, and the field to jot the next one.
    func openIdeasInReader(in destinationWindowState: StudioWindowState? = nil) {
        activateCenterTab(.ideas, in: destinationWindowState ?? activeWindowState)
    }

    /// The rail's Docs row. Docs is a place, not a document: clicking it
    /// lands on the index of every doc, the same view each time, rather than
    /// on whichever doc happened to be open when the pane was last shown. A
    /// doc reached from a chat or a Notebook still opens itself, through
    /// `revealArtifact`. The index shows in the window the row was clicked in
    /// (or the one named); a doc open in another Studio window stays open.
    func openNotepadInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        destination.artifactCanvasNotebookID = nil
        activateCenterTab(.notepad, in: destination)
        artifactIndexRequest = ArtifactIndexRequest(
            section: .docs,
            windowID: destination.id,
            groupID: paneShowing(.notepad, in: destination)
        )
    }

    /// The rail's Sites row: the same place-not-a-page rule as Docs, for the
    /// section that holds Claude artifacts and Codex sites.
    func openSitesInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        activateCenterTab(.sites, in: destination)
        artifactIndexRequest = ArtifactIndexRequest(section: .sites, windowID: destination.id)
    }

    /// The Videos pane, where an explainer film is made and played: the pane
    /// with its list and the last film selected. A film is listed in its
    /// notebook's Studio; this pane is where one opens.
    func openVideosInReader() {
        activateCenterTab(.videos)
    }

    /// The Space: every page, site, picture, idea, canvas, list, notebook and
    /// course, on the place the window last showed (`showSpace` chooses one).
    func openArtifactsInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        activateCenterTab(.artifacts, in: destination)
    }

    /// Opens one of the Space's kinds in a column beside what is on screen
    /// (product owner, 2026-09-29: "make sure we can also open 2 different
    /// artifact panes side by side; e.g. docs and ideas"). The pane kept is
    /// one of those kinds already showing — another kind's first, so asking
    /// for Ideas with Docs on screen gives Docs beside Ideas, then the Docs
    /// tab the request came from. With neither on screen it opens beside
    /// the way a rail row does. A kind already on screen stays where it is.
    func openArtifactKindBeside(_ tab: StudioCenterTab) {
        let visible = centerTabGroups.groups.map(\.activeTab)
        guard !visible.contains(tab) else { return }
        let companion = visible.first { $0 != tab && StudioCenterTab.artifactKinds.contains($0) }
            ?? visible.first { $0 == .artifacts }
        if let companion {
            revealCenterTab(tab, beside: companion)
        } else {
            openCenterTabBeside(tab)
        }
    }

    /// The rail's Browser row: the pane with whatever tabs it had.
    func openBrowserInReader() {
        activateCenterTab(.browser)
    }

    /// Opens a page in the Browser pane, in a new tab. The Library profile
    /// unless a profile is named, so a page saved from the tab lands where
    /// the readers can use its cookies.
    func openInBrowser(_ url: URL, profileID: UUID? = nil) {
        activateCenterTab(.browser)
        browserOpenRequest = BrowserOpenRequest(url: url, profileID: profileID)
    }

    /// Brings a specific doc forward — the way back from a chat to the passage
    /// it started on, an output of a notebook's Studio, a doc's link. A doc
    /// filed in the notebook the window holds opens in the notebook's own
    /// Docs (`docsCanvasScope`); any other doc in the global canvas, never in
    /// one scoped to a Notebook it is not filed under, which would silently
    /// show nothing. A Claude artifact or a Codex site comes forward in
    /// Sites, a Markdown doc or a Google Doc in Docs; a record this window
    /// has not loaded is taken for a Doc.
    /// The doc comes forward in the window the request was made in (or the
    /// one named), and in no other: a second Studio window keeps what it shows.
    ///
    /// With `companion` the pane comes forward *beside* that surface, which
    /// stays where it is (the Canvas's Open Beside).
    func revealArtifact(_ artifactID: String, in destinationWindowState: StudioWindowState? = nil, beside companion: StudioCenterTab? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        let section = artifactSection(of: artifactID)
        if section == .docs {
            let scope = docsCanvasScope(for: artifactID, in: destination)
            if destination.artifactCanvasNotebookID != scope { destination.artifactCanvasNotebookID = scope }
        }
        if let companion {
            revealCenterTab(section.centerTab, beside: companion, in: destination)
        } else {
            activateCenterTab(section.centerTab, in: destination)
        }
        artifactRevealRequest = ArtifactRevealRequest(
            artifactID: artifactID,
            section: section,
            windowID: destination.id,
            groupID: paneShowing(section.centerTab, in: destination)
        )
    }

    /// The pane a request for `tab`'s content goes to when the window shows
    /// `tab` in more than one pane (`StudioCenterTab.copyablePlaces`): the
    /// one last clicked in, else the first showing it. Nil when only one pane
    /// can answer, so every canvas of the window may.
    func paneShowing(_ tab: StudioCenterTab, in window: StudioWindowState) -> UUID? {
        let showing = window.centerTabGroups.groups.filter { $0.activeTab == tab }
        guard showing.count > 1 else { return nil }
        return (showing.first { $0.id == window.focusedGroupID } ?? showing[0]).id
    }

    /// The Notebook a doc opens scoped to in `windowState`: the notebook the
    /// window holds when the doc is filed there, so its list and its New Doc
    /// are the notebook's; nil — every doc — otherwise.
    func docsCanvasScope(for artifactID: String, in windowState: StudioWindowState) -> String? {
        guard let notebookID = windowState.NotebookID,
              let record = artifacts.first(where: { $0.id == artifactID }),
              NotebookOutputs.isFiled(record, in: notebookID) else { return nil }
        return notebookID
    }

    /// Docs or Sites for a record id, read from the loaded library.
    func artifactSection(of artifactID: String) -> ArtifactSection {
        artifacts.first(where: { $0.id == artifactID }).map(section(of:)) ?? .docs
    }

    /// Docs or Sites for a record: the record's own answer, by its link. A
    /// Google Doc and every Markdown doc are Docs, published or not; a Claude
    /// artifact, a Codex site or a ForeverLM site is a Site. From 2026-09-08
    /// to 2026-09-10 a Markdown doc moved to Sites while it had a page on
    /// foreverlm.com; the product owner reversed that ("sites should only hold actual
    /// sites, published docs stay in docs"), so publication no longer moves
    /// anything. Kept as the one place every canvas and `revealArtifact` ask.
    func section(of artifact: ArtifactRecord) -> ArtifactSection {
        artifact.section
    }

    /// Opens Docs scoped to a Notebook — its list and its New Doc are the
    /// Notebook's — or, with nil, every doc. It opens beside what is on
    /// screen, as a rail row's Open Beside does. (The
    /// Notebook page that placed it right of itself went with the notebook's
    /// Studio, which lists the notebook's Docs among its outputs.)
    func openArtifactsBeside(notebookID: String? = nil) {
        let destination = activeWindowState
        if destination.artifactCanvasNotebookID != notebookID { destination.artifactCanvasNotebookID = notebookID }
        openCenterTabBeside(.notepad)
    }

    /// Opens one notebook in the window in scope — the single definition of
    /// "open a notebook", shared by the rail's folder rows, the Space's rows,
    /// links and Siri. The notebook workspace then draws the window
    /// (`openNotebook(_:in:startsNotebookChat:)`). Opening writes nothing
    /// synced: that window's scene snapshot, which `get_app_context` names,
    /// and the active Notebook (`activeNotebookId`), a preference on this Mac
    /// only. An archived Notebook opens to be read as well, and does not move
    /// the active one.
    func openNotebookInReader(_ notebookID: String) {
        openNotebook(notebookID)
    }

    /// The navigation rail's folder-row interaction. A second click on the
    /// notebook the window holds closes it, and the panes underneath come
    /// back as they were.
    func toggleNotebookInReader(_ notebookID: String) {
        if workbenchNotebookID == notebookID {
            closeNotebook()
        } else {
            openNotebookInReader(notebookID)
        }
    }

    /// A Notebook whose source pool should open next, set by the journals
    /// banner and consumed by the notebook workspace once it shows that
    /// notebook, which unfolds its Sources column. Nil otherwise.
    var pendingNotebookSourcesRequestID: String?

    /// The notebook open in the key window (nil while it holds none and its
    /// Space shows). The notebook belongs to the window
    /// (`StudioWindowState.notebook`); this forwards to `activeWindowState`
    /// the way `centerTabGroups` does, so imperative navigation — and an
    /// `inWindow` scope — opens and reads the notebook of the window it acts
    /// in. Views that render one window read their own window's notebook.
    var workbenchNotebookID: String? {
        get { activeWindowState.NotebookID }
        set { activeWindowState.NotebookID = newValue }
    }

    /// Closes `notebookID` in every window that holds it: an archived or
    /// deleted notebook is open nowhere, and each of those windows shows the
    /// Space (`leaveNotebookForSpace`).
    func closeNotebookInEveryWindow(_ notebookID: String) {
        for state in allWindowStates where state.NotebookID == notebookID {
            leaveNotebookForSpace(in: state)
        }
    }

    /// Every window that holds `notebookID` holds `survivorID` instead: a
    /// merged notebook lives on in the one it was folded into, and so does
    /// the last time it was worked in on this Mac.
    func moveNotebookInEveryWindow(_ notebookID: String, to survivorID: String) {
        for state in allWindowStates where state.NotebookID == notebookID {
            state.NotebookID = survivorID
        }
        var recency = notebookRecency
        recency.merge(notebookID, into: survivorID)
        if recency != notebookRecency {
            notebookRecency = recency
            recency.save(to: notebookRecencyDefaults)
        }
    }

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

    /// Optional Notebook scope for the Docs pane of the window in scope
    /// (`StudioWindowState.artifactCanvasNotebookID`), forwarded the way
    /// `workbenchNotebookID` is so an `inWindow` scope reads and sets its own
    /// window's. Transient UI state rather than persisted navigation: opening
    /// Docs from the rail always clears it and returns to the learner's
    /// complete list.
    var artifactCanvasNotebookID: String? {
        get { activeWindowState.artifactCanvasNotebookID }
        set { activeWindowState.artifactCanvasNotebookID = newValue }
    }

    /// Notebook currently emphasized in the key window's navigation rail.
    /// Opening a notebook makes its folder active. Sticky on purpose — it
    /// survives switching to Schedule or opening a source, so the rail keeps
    /// showing which notebook the learner is working in. Cleared by going back
    /// to the notebook gallery.
    var railScopedNotebook: LearningGoalRecord? {
        railScopedNotebook(in: activeWindowState)
    }

    /// The active Notebook `windowState` holds as its notebook, for that
    /// window's own rail and voice scope.
    func railScopedNotebook(in windowState: StudioWindowState) -> LearningGoalRecord? {
        guard let notebookID = windowState.NotebookID else { return nil }
        return notebooks.first { $0.id == notebookID }
    }

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
    /// import's line in the Mac strip's work icon (a banner of its own until
    /// 2026-10-06, `StudioWorkButton`). The import (playlist scrape → AI title
    /// cleanup → per-lecture insert) can run ~a minute before the course first
    /// appears in the sidebar, and used to give the user no feedback at all.
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
    var aiUsageOpenRequest = 0
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

    /// Whether any X account is connected: the sidebar, the corner overlays and
    /// source discovery ask only this.
    var isXOAuthSignedIn: Bool { !xAccounts.isEmpty }

    /// Whether any account's session needs signing in again.
    var xPluginNeedsReauth: Bool { !xAccountsNeedingReauth.isEmpty }

    /// True when a failed sync is one a reconnect might clear, so the X tab
    /// and the plugin page offer Reconnect beside the retry.
    var xPluginOffersReconnect: Bool { xAccountFailures.values.contains { $0.offersReconnect } }

    /// True while X has told us to wait on this account. A retry the learner
    /// presses inside this window cannot succeed, so the button is disabled and
    /// the message beside it names the time instead.
    func isXSyncPaused(accountID: String) -> Bool {
        Self.isXSyncPaused(until: xSyncPausedUntil[accountID], now: Date())
    }

    /// True while every account that could sync is waiting out a limit.
    var isXSyncPaused: Bool {
        let syncable = xAccounts.filter { !xAccountsNeedingReauth.contains($0.id) }
        return !syncable.isEmpty && syncable.allSatisfy { isXSyncPaused(accountID: $0.id) }
    }

    nonisolated static func isXSyncPaused(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// The pause a failed sync earns: the reset time of a 429 that carried
    /// one, and nothing for every other failure — an offline error or a 500
    /// is worth retrying as soon as the learner asks. A usage cap is a 429
    /// without a window (X resets it monthly, on a date it does not send), so
    /// it pauses nothing; the message already says a retry will not help.
    nonisolated static func xSyncPause(after error: Error, now: Date) -> Date? {
        guard case .rateLimited(let resetAt)? = error as? XBookmarkError,
              let resetAt, resetAt > now else { return nil }
        return resetAt
    }

    /// What the X tab's red attention dot stands for, or nil when there is
    /// nothing to flag. A sync that failed on its own — at launch, on
    /// activation, on the timer — is not news the learner asked for, so it is
    /// not announced with a toast that goes away unread; it waits on the tab
    /// until the learner looks, and the X list explains it with a retry
    /// beside it. An expired session counts too: it is the one failure a
    /// retry cannot fix, so the dot stays up until the learner reconnects.
    var xPluginAttention: String? {
        Self.xPluginAttention(
            accounts: xAccounts,
            failures: xAccountFailures,
            needsReauth: xAccountsNeedingReauth
        )
    }

    nonisolated static func xPluginAttention(
        accounts: [XAccount],
        failures: [String: XAccountFailure],
        needsReauth: Set<String>
    ) -> String? {
        // A disconnected X has its own "Connect to X" row; a dot on top of that
        // would nag about an integration the learner never set up.
        let lines: [String] = accounts.compactMap { account in
            let line: String
            if let message = failures[account.id]?.message, !message.isEmpty {
                line = message
            } else if needsReauth.contains(account.id) {
                line = "Reconnect to X to keep syncing bookmarks."
            } else {
                return nil
            }
            // With several accounts the line must say whose it is.
            return accounts.count > 1 ? "\(account.displayLabel): \(line)" : line
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Profile pictures for X handles, keyed by lowercased handle, as resolved
    /// this launch. A library holds far more posts than authors, so a handle is
    /// looked up once and answers for every post it wrote — including the ones
    /// saved later.
    @ObservationIgnored var xAuthorAvatarURLs: [String: String] = [:]

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
    /// Whether source embeddings are being generated.
    var isEnsuringEmbeddings: Bool = false
    /// Progress label shown while embedding sources.
    var sourceEmbeddingProgress: String?
    /// Monotonic token that prevents stale async search phases from overwriting newer results.
    var sourceSearchGeneration = 0
    /// Task handle for debounced search.
    var sourceSearchTask: Task<Void, Never>?
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

    var activeWindowState: StudioWindowState {
        if let scopedWindowState { return scopedWindowState }
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
    /// app-wide selection, so a click in one window used to change what every
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

    /// Ask the background indexer to bring embedding coverage up to date. Cheap and
    /// coalesced — safe to call from any change-triggered path.
    ///
    /// Utility priority, explicitly. A plain `Task` inherits the priority of the
    /// main-actor code that spawned it, which made a library-wide re-index rank as
    /// user-interactive work on the storage actor's queue and hold a chat send at
    /// "Getting your sources ready" behind every batch of embedding rows. Actor
    /// queues are priority-ordered, so naming the priority is what lets the send
    /// go first.
    func kickSourceEmbeddingIndexing() {
        Task(priority: .utility) { await sourceEmbeddingIndexer.requestIndexing() }
    }

    /// `kickSourceEmbeddingIndexing` after a short quiet, for the paths that run once per
    /// source: a source saved or fetched is searchable by its title and text within
    /// seconds, not at the next launch, while an import saving hundreds of them asks
    /// for one pass rather than one per save.
    func kickSourceEmbeddingIndexingSoon() {
        sourceIndexingKickTask?.cancel()
        sourceIndexingKickTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.kickSourceEmbeddingIndexing()
        }
    }

    /// Adopt historical Zoom video rows only after the source list is visible.
    /// Bounded batches keep the storage actor available; the final reload
    /// publishes type, series relationship, and provider together.
    func runDeferredZoomMeetingAdoption() async {
        guard !zoomMeetingAdoptionInFlight else { return }
        zoomMeetingAdoptionInFlight = true
        defer { zoomMeetingAdoptionInFlight = false }
        var adoptedIDs: [String] = []
        do {
            while !Task.isCancelled {
                let batch = try await storage.drainZoomMeetingAdoptionBatch(limit: 50)
                guard !batch.isEmpty else { break }
                adoptedIDs.append(contentsOf: batch)
                await Task.yield()
            }
        } catch {
            logger.error("Deferred Zoom meeting adoption paused: \(error.localizedDescription)")
        }
        guard !adoptedIDs.isEmpty else { return }
        let refreshed = (try? await storage.loadPersistedSources(ids: adoptedIDs)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        var updated = articles
        var changed = false
        for index in updated.indices {
            guard let replacement = byID[updated[index].id] else { continue }
            updated[index] = replacement
            changed = true
        }
        if changed { articles = updated }
    }

    /// Decode the HTML character references that older ingestion left in stored
    /// source text. Small batches keep SQLite available and make the work
    /// resumable if the app closes midway through an upgrade.
    func runDeferredSourceTextReferenceRepair() async {
        guard !sourceTextReferenceRepairInFlight else { return }
        sourceTextReferenceRepairInFlight = true
        defer { sourceTextReferenceRepairInFlight = false }
        var repairedIDs: Set<String> = []
        do {
            while !Task.isCancelled {
                let repaired = try await storage.drainSourceTextReferenceRepairBatch(limit: 50)
                guard !repaired.isEmpty else { break }
                repairedIDs.formUnion(repaired)
                await Task.yield()
            }
        } catch {
            logger.error("Deferred source text repair paused: \(error.localizedDescription)")
        }
        guard !repairedIDs.isEmpty else { return }
        // A loaded article still holds the pre-repair extraction. Assign once:
        // mutating `articles[index]` runs the array's didSet and rebuilds the
        // sidebar indexes for every element touched.
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices
        where repairedIDs.contains(updatedArticles[index].id) && updatedArticles[index].content != nil {
            updatedArticles[index].content = nil
            didChange = true
        }
        if didChange { articles = updatedArticles }
    }

    /// Drop the soft hyphens older builds left in stored source text (schema
    /// 166), keeping what was derived from the old text with the repaired text's
    /// hash. Waits for the library to load: the launch runs it then, before sync
    /// starts, so this Mac repairs its own copy — and keeps its Listen text,
    /// review guides and ideas — before another Mac's repaired text arrives as a
    /// new text for them. App activation runs it again for a source a paid pass
    /// held back, or text an older build on another Mac published since. A call
    /// while it runs waits for that run.
    func runDeferredStoredSoftHyphenRepair() async {
        guard hasCompletedInitialQueueLoad else { return }
        if let running = storedSoftHyphenRepairTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainStoredSoftHyphenRepairQueue()
        }
        storedSoftHyphenRepairTask = task
        await task.value
        storedSoftHyphenRepairTask = nil
    }

    private func drainStoredSoftHyphenRepairQueue() async {
        var repairedIDs: Set<String> = []
        do {
            while !Task.isCancelled {
                let batch = try await storage.drainStoredSoftHyphenRepairBatch(limit: 50)
                repairedIDs.formUnion(batch.repairedSourceIDs)
                // A batch of clean sources is progress too; only an empty one ends it.
                guard batch.processedCount > 0 else { break }
                await Task.yield()
            }
        } catch {
            logger.error("Deferred soft hyphen repair paused: \(error.localizedDescription)")
        }
        guard !repairedIDs.isEmpty else { return }
        logger.notice("Removed soft hyphens from the stored text of \(repairedIDs.count) source(s)")
        // A loaded source still holds the old text, and a paper the hash of its old
        // extraction (`paperContentSHA256`, one of its identity keys). Assign once:
        // mutating `articles[index]` runs the array's didSet and rebuilds the
        // sidebar indexes for every element touched.
        let refreshed = (try? await storage.loadPersistedSources(ids: Array(repairedIDs))) ?? []
        let byID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices where repairedIDs.contains(updatedArticles[index].id) {
            if updatedArticles[index].content != nil {
                updatedArticles[index].content = nil
                didChange = true
            }
            guard let source = byID[updatedArticles[index].id] else { continue }
            if updatedArticles[index].title != source.title {
                updatedArticles[index].title = source.title
                didChange = true
            }
            if updatedArticles[index].paperContentSHA256 != source.paperContentSHA256 {
                updatedArticles[index].paperContentSHA256 = source.paperContentSHA256
                didChange = true
            }
        }
        if didChange { articles = updatedArticles }
        // The repaired sources lost their full-text rows and embeddings.
        kickSourceEmbeddingIndexing()
    }

    /// Count the words of every source whose text is stored but whose count is
    /// missing (`drainSourceWordCountRepairBatch`): 637 podcast transcripts
    /// read as "no text yet" to the chat catalog and `filter_sources`
    /// (2026-10-12). A no-op once nothing is missing, so launch and activation
    /// both run it; activation also counts text another device sent uncounted.
    func runDeferredSourceWordCountRepair() async {
        guard !sourceWordCountRepairInFlight else { return }
        sourceWordCountRepairInFlight = true
        defer { sourceWordCountRepairInFlight = false }
        var counts: [String: Int] = [:]
        var cursor: String?
        do {
            while !Task.isCancelled {
                let batch = try await storage.drainSourceWordCountRepairBatch(after: cursor, limit: 50)
                guard let last = batch.lastSourceID else { break }
                counts.merge(batch.counts) { _, new in new }
                cursor = last
                await Task.yield()
            }
        } catch {
            logger.error("Deferred word count repair paused: \(error.localizedDescription)")
        }
        guard !counts.isEmpty else { return }
        logger.notice("Counted the words of \(counts.count) source(s) whose stored text had no count")
        // A loaded row still holds the missing count, and a later save of it
        // would write that back. Assign once: mutating `articles[index]` runs
        // the array's didSet and rebuilds the sidebar indexes for every
        // element touched.
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices {
            guard let count = counts[updatedArticles[index].id],
                  updatedArticles[index].wordCount != count else { continue }
            updatedArticles[index].wordCount = count
            didChange = true
        }
        if didChange { articles = updatedArticles }
    }

    /// Strip the stale figure image links older PDF extraction left in stored
    /// source text. Small batches keep SQLite available and make the work
    /// resumable if the app closes midway through an upgrade.
    func runDeferredPaperFigureMarkdownRepair() async {
        guard !paperFigureMarkdownRepairInFlight else { return }
        paperFigureMarkdownRepairInFlight = true
        defer { paperFigureMarkdownRepairInFlight = false }
        var repairedIDs: Set<String> = []
        do {
            while !Task.isCancelled {
                let repaired = try await storage.drainPaperFigureMarkdownRepairBatch(limit: 50)
                guard !repaired.isEmpty else { break }
                repairedIDs.formUnion(repaired)
                await Task.yield()
            }
        } catch {
            logger.error("Deferred figure link repair paused: \(error.localizedDescription)")
        }
        guard !repairedIDs.isEmpty else { return }
        // A loaded paper still holds the pre-repair extraction. Assign once:
        // mutating `articles[index]` runs the array's didSet and rebuilds the
        // sidebar indexes for every element touched.
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices
        where repairedIDs.contains(updatedArticles[index].id) && updatedArticles[index].content != nil {
            updatedArticles[index].content = nil
            didChange = true
        }
        if didChange { articles = updatedArticles }
    }

    /// Check staged papers' titles against the titles their DOIs are
    /// registered under (schema 144) and show a restored title at once: the
    /// store already holds it, the loaded row still has the damaged copy.
    /// Assign once, like the other deferred repairs, so the sidebar indexes
    /// rebuild a single time.
    func runRegisteredPaperTitleCheck() async {
        let result = await registeredPaperTitleCheckService.drain()
        guard !result.restored.isEmpty else { return }
        var titles: [String: String] = [:]
        for restored in result.restored {
            titles[restored.sourceID] = restored.title
        }
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices {
            guard let title = titles[updatedArticles[index].id],
                  updatedArticles[index].title != title else { continue }
            updatedArticles[index].title = title
            didChange = true
        }
        if didChange { articles = updatedArticles }
        // The restored rows lost their full-text state; rewrite them.
        kickSourceEmbeddingIndexing()
    }

    /// Hold staged YouTube transcripts to their captions (schema 148) and
    /// show a rewritten one at once: the store already holds it, the loaded
    /// row still has the old text. Assign once, like the other deferred
    /// repairs, so the sidebar indexes rebuild a single time.
    func runYouTubeTranscriptCheck() async {
        let result = await youTubeTranscriptCheckService.drain()
        guard !result.rewritten.isEmpty else { return }
        var contents: [String: String] = [:]
        for transcript in result.rewritten {
            contents[transcript.sourceID] = transcript.content
        }
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices {
            // A row whose text was never loaded reads the new one when it is.
            guard let content = contents[updatedArticles[index].id],
                  let loaded = updatedArticles[index].content, loaded != content else { continue }
            updatedArticles[index].content = content
            updatedArticles[index].wordCount = content.split(separator: " ").count
            didChange = true
        }
        if didChange { articles = updatedArticles }
        // The rewritten rows lost their full-text and embedding state.
        kickSourceEmbeddingIndexing()
    }

    /// Remove the rendered figure JPEGs that PDF indexing wrote before schema 75.
    ///
    /// One traversal of the content roots, once per device, entirely off the main
    /// actor. It is gated on a local flag rather than a synced preference because
    /// the files are this Mac's — the other Mac has its own copies to clear.
    func runDeferredPaperFigureImageSweep() async {
        guard !paperFigureImageSweepInFlight else { return }
        paperFigureImageSweepInFlight = true
        defer { paperFigureImageSweepInFlight = false }
        do {
            guard try await storage.paperFigureImageSweepIsPending() else { return }
            let removed = await PaperFigureImageSweeper.sweep()
            guard !Task.isCancelled else { return }
            try await storage.completePaperFigureImageSweep(removedDirectoryCount: removed)
            if removed > 0 {
                logger.notice("Removed \(removed) stale figure image directory(ies)")
            }
        } catch {
            logger.error("Figure image sweep paused: \(error.localizedDescription)")
            try? await storage.recordPaperFigureImageSweepFailure(
                message: error.localizedDescription
            )
        }
    }

    /// Build the figure index of every paper that has none, or one built under
    /// older rules, so a figure mention in any paper's text opens its figure
    /// (product owner, 2026-11-08: "make that the case for all figures in the
    /// library", "backfill that in our library of papers"). The structural
    /// read only: the PDF's caption lines, no model and no credits. One paper
    /// at a time, at the launch's utility priority; a paper finished is
    /// current and is not read again, so the sweep ends itself and resumes
    /// where a quit left it.
    func runDeferredPaperFigureIndexBackfill() async {
        guard !paperFigureIndexBackfillInFlight else { return }
        paperFigureIndexBackfillInFlight = true
        defer { paperFigureIndexBackfillInFlight = false }
        let ids: [String]
        do {
            ids = try await storage.papersNeedingFigureIndex()
        } catch {
            logger.error("Figure index backfill could not list papers: \(error.localizedDescription)")
            return
        }
        guard !ids.isEmpty else { return }
        var indexed = 0
        var failed = 0
        for id in ids {
            guard !Task.isCancelled else { break }
            do {
                _ = try await paperFigureIndexer.prepareStructure(sourceID: id)
                indexed += 1
            } catch {
                // The indexer files the failure against the paper; three and
                // the backfill leaves it alone.
                failed += 1
            }
            await Task.yield()
        }
        logger.notice("Figure index backfill read \(indexed) paper(s); \(failed) could not be read")
    }

    /// Drain canonical cleanup and prepare already-eligible Listen derivatives
    /// concurrently. The listenable candidate query excludes anything still in
    /// canonical cleanup, so the two bounded stages never race on one source.
    func runCanonicalContentCleanup() async {
        #if DEBUG
        // An explicit maintenance process owns the podcast queue directly;
        // suppress the ordinary Studio observer so it cannot duplicate paid
        // requests for the same first batch.
        if ProcessInfo.processInfo.arguments.contains("--run-podcast-cleanup") {
            return
        }
        #endif
        if !PaidSourceCleanupPolicy.runsPaidCleanup, !hasLoggedPaidCleanupSkip {
            hasLoggedPaidCleanupSkip = true
            logger.notice(
                """
                Dev build: paid source clean-up is off. New sources are published with their \
                raw text and historical clean-up rows stay queued. Launch with \
                \(PaidSourceCleanupPolicy.optInEnvironmentKey, privacy: .public)=1 to run it.
                """
            )
        }
        // Older builds persisted transient cleanup failures as terminal source
        // errors. Re-stage them before every event-driven drain so an update,
        // relaunch, activation, or remote change repairs the row automatically.
        await resumeSourcesAfterTransientCleanupFailures()
        // The one-time chrome refilter rides the same trigger points but is
        // independent of both: it rewrites reader documents and never touches
        // canonical text, so it cannot race the two content stages.
        Task(priority: .utility) { _ = await self.articleChromeRefilterService.drain() }
        // So does schema 144's registered-title check: catalog requests and a
        // title write, no model and no text.
        Task(priority: .utility) { await self.runRegisteredPaperTitleCheck() }
        // And schema 174's read of each paper's references: the PDF's text and free
        // catalog requests, no model, so it needs no spend control and no opt-in.
        Task(priority: .utility) { await self.runPaperReferenceLinking() }
        // And schema 148's transcript check: caption requests and a text
        // write, no model.
        Task(priority: .utility) { await self.runYouTubeTranscriptCheck() }
        // Ahead of the two content stages, and awaited rather than detached: an
        // episode still holding the part of itself that survived the retired
        // 50,000-character cap must be restored before the ad pass runs, or
        // that pass spends a model on text that is about to be replaced.
        let detruncationResult = await runPodcastTranscriptAudit()
        // Spend control (2026-09-24): a bulk re-queue waits for the learner,
        // and past the daily background cap only a source the learner added
        // is still cleaned; the rest waits for the next local day.
        await refreshPendingBackgroundAIBulkJobs()
        let backgroundSpendAllowed = await backgroundAISpendAllowed()
        async let cleanupDrain = canonicalContentCleanupService.drain(
            backgroundSpendAllowed: backgroundSpendAllowed
        )
        async let podcastCleanupDrain = podcastTranscriptCleanupService.drain(
            backgroundSpendAllowed: backgroundSpendAllowed
        )
        async let listenableDrain = sourceListenableContentPreparationService.drain(
            backgroundSpendAllowed: backgroundSpendAllowed
        )
        let (result, podcastResult, listenableResult) = await (
            cleanupDrain,
            podcastCleanupDrain,
            listenableDrain
        )
        await refreshLoadedSourcesAfterDerivedWrites(
            Set(
                result.processedSourceIDs
                    + podcastResult.processedSourceIDs
                    + listenableResult.processedSourceIDs
            ),
            rewrittenText: Set(result.processedSourceIDs + podcastResult.processedSourceIDs)
        )
        if let error = result.errorMessage {
            logger.error("Source cleanup failed: \(error)")
        }

        if let error = podcastResult.errorMessage {
            logger.error("Podcast transcript clean-up failed: \(error)")
        }

        if let error = listenableResult.errorMessage {
            logger.error("Listenable-content preparation failed: \(error)")
        }

        let cleanupHasAnotherBatch = result.processedCount > 0
            && result.remainingCount > 0
        let podcastCleanupHasAnotherBatch = podcastResult.processedCount > 0
            && podcastResult.remainingCount > 0
        // Canonical cleanup enqueues Listen work after the concurrent Listen
        // drain has already selected its candidates. A completed cleanup batch
        // is therefore also a concrete next-work event for that second stage.
        let listenableHasAnotherBatch = listenableResult.remainingCount > 0
            && (listenableResult.processedCount > 0 || result.processedCount > 0)
        // The completeness audit settles a few episodes a batch; a batch that
        // settled any is the event for the next, until none is due (a failed
        // fetch waits for its retry time, so it never keeps this going).
        let auditHasAnotherBatch = detruncationResult.auditedCount > 0
            && detruncationResult.remainingCount > 0
        if result.processedCount > 0 || podcastResult.processedCount > 0 || listenableResult.processedCount > 0 {
            derivedSourceWorkRetryRound = 0
        }
        if cleanupHasAnotherBatch || podcastCleanupHasAnotherBatch || listenableHasAnotherBatch
            || auditHasAnotherBatch {
            derivedSourceWorkRetryTask?.cancel()
            // Batch completion is the next-work event. The existing observer
            // coalesces it before starting another bounded off-main batch.
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        } else {
            let transientFailure = result.failedTransiently
                || podcastResult.failedTransiently
                || [result.errorMessage, podcastResult.errorMessage, listenableResult.errorMessage]
                    .compactMap { $0 }
                    .contains { AITransientErrorClassifier.isTransient(AIError.apiError($0)) }
            let hasRemainingWork = result.remainingCount > 0
                || podcastResult.remainingCount > 0
                || listenableResult.remainingCount > 0
            if transientFailure && hasRemainingWork {
                // A provider limit or timeout is a future-work event, not a
                // reason to strand the durable tail. One coalesced retry
                // resumes the drain without turning the feature into polling;
                // it backs off while nothing gets through, and never comes
                // sooner than the provider said it would take requests again.
                let serverWait = [result.retryAfterSeconds, podcastResult.retryAfterSeconds]
                    .compactMap { $0 }
                    .max()
                let delay = Self.derivedSourceWorkRetryDelay(
                    round: derivedSourceWorkRetryRound,
                    serverWait: serverWait
                )
                derivedSourceWorkRetryRound += 1
                logger.notice("Source cleanup waits \(Int(delay), privacy: .public)s before retrying (round \(self.derivedSourceWorkRetryRound, privacy: .public))")
                derivedSourceWorkRetryTask?.cancel()
                derivedSourceWorkRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, self != nil else { return }
                    NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                }
            } else if let wait = result.nextRetryInSeconds {
                // A source waiting out its cleanup retry delay
                // (`CanonicalContentCleanupRetry`) is due then; nothing else
                // may ask for a drain before it is.
                logger.notice("Source cleanup's next retry is due in \(Int(wait), privacy: .public)s")
                derivedSourceWorkRetryTask?.cancel()
                derivedSourceWorkRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(1, wait)))
                    guard !Task.isCancelled, self != nil else { return }
                    NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                }
            }
        }
    }

    /// The podcast transcript completeness audit's next batch (schema 167),
    /// with every row it restored brought back to what storage holds.
    ///
    /// The loaded copy of a restored episode still holds the cut transcript,
    /// and `saveSource` writes a loaded podcast's `content` into
    /// `source_content` whole, so any later save of that row — a rename, a
    /// hide, a reading mark — would have written the cut text back over the
    /// restore. Clearing it sends every reader back to storage, as the
    /// clean-up stages do, and the word count is taken from storage for the
    /// same reason.
    @discardableResult
    func runPodcastTranscriptAudit() async -> PodcastTranscriptDetruncationDrainResult {
        let result = await podcastTranscriptDetruncationService.drain()
        guard !result.restoredSourceIDs.isEmpty else { return result }
        let restored = Set(result.restoredSourceIDs)
        await refreshLoadedSourcesAfterDerivedWrites(restored, rewrittenText: restored)
        logger.notice(
            """
            Restored \(result.restoredCount) podcast transcript(s) the retired cap had cut; \
            \(result.remainingCount) left to audit
            """
        )
        // The restored rows lost their full-text and embedding state.
        kickSourceEmbeddingIndexing()
        return result
    }

    /// Brings loaded rows a background stage rewrote in storage back in line
    /// with it: state, error, the paper hashes and Listen's readiness, and for
    /// `rewrittenText`, the text itself (cleared, so consumers read storage)
    /// and the word count beside it.
    func refreshLoadedSourcesAfterDerivedWrites(
        _ sourceIDs: Set<String>,
        rewrittenText: Set<String>
    ) async {
        guard !sourceIDs.isEmpty else { return }
        let refreshedSources = (try? await storage.loadPersistedSources(ids: Array(sourceIDs))) ?? []
        let refreshedByID = Dictionary(refreshedSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices where sourceIDs.contains(updatedArticles[index].id) {
            let sourceID = updatedArticles[index].id
            if rewrittenText.contains(sourceID), updatedArticles[index].content != nil {
                // Force every ordinary consumer back through canonical storage;
                // a loaded article may still hold the text from before.
                updatedArticles[index].content = nil
                didChange = true
            }
            if let refreshed = refreshedByID[sourceID] {
                if rewrittenText.contains(sourceID),
                   updatedArticles[index].wordCount != refreshed.wordCount {
                    updatedArticles[index].wordCount = refreshed.wordCount
                    didChange = true
                }
                if updatedArticles[index].state != refreshed.state {
                    updatedArticles[index].state = refreshed.state
                    didChange = true
                }
                if updatedArticles[index].errorMessage != refreshed.errorMessage {
                    updatedArticles[index].errorMessage = refreshed.errorMessage
                    didChange = true
                }
                if updatedArticles[index].paperContentSHA256 != refreshed.paperContentSHA256 {
                    updatedArticles[index].paperContentSHA256 = refreshed.paperContentSHA256
                    didChange = true
                }
                if updatedArticles[index].paperListenableContentReady
                    != refreshed.paperListenableContentReady {
                    updatedArticles[index].paperListenableContentReady = refreshed.paperListenableContentReady
                    didChange = true
                }
            }
        }
        if didChange {
            // Assign once: mutating `articles[index]` invokes the array's
            // didSet, rebuilds sidebar indexes, and invalidates SwiftUI. A
            // cleanup batch used to repeat that O(library) main-actor work
            // for every processed source.
            articles = updatedArticles
        }
    }

    /// How long the drain waits before retrying after a batch that got nothing
    /// done: a minute, doubling each round up to half an hour, and at least as
    /// long as the provider named (a daily free-model quota can name hours).
    nonisolated static func derivedSourceWorkRetryDelay(round: Int, serverWait: Double?) -> Double {
        let backoff = min(30 * 60, 60 * pow(2, Double(min(max(0, round), 10))))
        return max(backoff, serverWait ?? 0)
    }

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

    /// Background auto-refresh task. Runs independently of the view lifecycle
    /// so switching tabs (e.g. Studio → Review) doesn't stop periodic syncs.
    var autoRefreshTask: Task<Void, Never>?

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
        self.paperReferenceLinkService = PaperReferenceLinkService(storage: storageService)
        self.youTubeTranscriptCheckService = YouTubeTranscriptCheckService(storage: storageService)
        self.sourceListenableContentPreparationService = SourceListenableContentPreparationService(
            storage: storageService,
            aiService: ai
        )
        self.backgroundAIBudget = BackgroundAIBudget(storage: storageService)
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
        wireCanvasModel(knowledgeMap)
    }

}

// MARK: - Errors

/// Where `StudioViewModel.activeNotebookId` is kept: this Mac's own defaults,
/// never synced. The key predates windows holding their own notebooks, when
/// it was also what MCP read; it is kept so the choice survives.
enum ActiveNotebookPreference {
    static let defaultsKey = "studio.activeMCPNotebookID"

    static var notebookID: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: defaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        set {
            if let clean = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                UserDefaults.standard.set(clean, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
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
