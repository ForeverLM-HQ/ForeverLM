import Foundation
import Observation

// MARK: - Articles

/// Revision/index mirror for the Studio source list. The canonical `articles`
/// array remains on `StudioViewModel` so in-place element mutations keep working;
/// sidebar views can observe `revision` without coupling to reader/chat state.
@Observable
@MainActor
final class StudioArticlesStore {
    /// Bumped on every publish of `articles`, loaded text included, so a reader
    /// waiting on a transcript re-renders when it lands.
    private(set) var revision = 0
    /// Bumped only when something a list row shows changed — title, state,
    /// membership, order. Sidebar caches key on this one, so hydrating text
    /// for a chat send does not rebuild every window's filtered list. See
    /// `StudioArticle.presentationEquals`.
    private(set) var presentationRevision = 0
    @ObservationIgnored private(set) var articlesById: [String: StudioArticle] = [:]
    /// Built while the catalog is already being indexed. Reading this snapshot
    /// is copy-on-write O(1), so event-driven review refreshes never rescan a
    /// large library on the main actor merely to recover its IDs.
    @ObservationIgnored private(set) var articleIDs: Set<String> = []
    @ObservationIgnored private(set) var articleIDsByParentGroup: [String: [String]] = [:]
    /// Explainer ids by the id of the source each one explains, read off the
    /// `foreverlm://explainer/<sourceID>` URL grammar (explainer-design.md).
    /// An explainer has no row of its own in any list; the sidebar folds it
    /// under the source it explains, and this index is how a row finds it
    /// without scanning the library.
    @ObservationIgnored private(set) var explainerIDsByExplainedSourceID: [String: String] = [:]
    /// The Artifact ids of the audio overviews whose script source this Mac
    /// holds, read off the `foreverlm://audio-overview/<artifactID>` URL
    /// grammar: how a list recognises an overview an older build saved back
    /// without its kind, without reading its body
    /// (`StudioViewModel.isAudioOverview`).
    @ObservationIgnored private(set) var audioOverviewArtifactIDs: Set<String> = []
    /// Team copy id → the learner's own row at the same address, while a team
    /// library is open (`LibrarySourceList`, docs/teams-design.md decision 19).
    /// The list shows the own row only; `articlesById` answers the copy's id
    /// with it, so a team Notebook, Doc card or chat snapshot that names the
    /// copy still opens the source. Set before the `articles` it goes with.
    @ObservationIgnored var teamCopyAliases: [String: String] = [:]

    func sync(from articles: [StudioArticle], presentationChanged: Bool = true) {
        revision &+= 1
        if presentationChanged {
            presentationRevision &+= 1
        }
        var nextArticlesById: [String: StudioArticle] = [:]
        var nextArticleIDs = Set<String>()
        var nextIDsByParentGroup: [String: [String]] = [:]
        var nextExplainerIDs: [String: String] = [:]
        var nextAudioOverviewIDs = Set<String>()
        nextArticlesById.reserveCapacity(articles.count)
        nextArticleIDs.reserveCapacity(articles.count)
        for article in articles {
            nextArticlesById[article.id] = article
            nextArticleIDs.insert(article.id)
            if let parentGroup = article.parentGroup {
                nextIDsByParentGroup[parentGroup, default: []].append(article.id)
            }
            if let explainedID = GeneratedExplainer.explainedSourceID(from: article.url) {
                nextExplainerIDs[explainedID] = article.id
            } else if TextToSpeechPreparationPolicy.isAudioOverviewScript(url: article.url),
                      let overviewID = GeneratedAudioOverview.artifactID(ofCarrier: article) {
                nextAudioOverviewIDs.insert(overviewID)
            }
        }
        for (copyID, ownID) in teamCopyAliases where nextArticlesById[copyID] == nil {
            if let own = nextArticlesById[ownID] { nextArticlesById[copyID] = own }
        }
        articlesById = nextArticlesById
        articleIDs = nextArticleIDs
        articleIDsByParentGroup = nextIDsByParentGroup
        explainerIDsByExplainedSourceID = nextExplainerIDs
        audioOverviewArtifactIDs = nextAudioOverviewIDs
    }
}

// MARK: - Reading progress

/// Reading locators kept out of `articles` so scroll/page persistence does not
/// rebuild the source list or sidebar indexes.
@Observable
@MainActor
final class StudioReadingProgressStore {
    @ObservationIgnored private var pages: [String: Int] = [:]
    @ObservationIgnored private var locators: [String: String] = [:]
    /// Locator-string-keyed decode memo for `videoWatchProgress(for:fallbackLocator:)`.
    @ObservationIgnored private var videoProgressMemo: [String: (locator: String, progress: VideoWatchProgress?)] = [:]
    /// Bumped on every position write. Observation-ignored so high-frequency
    /// scroll/page persistence never invalidates SwiftUI views; the sidebar's
    /// filtered-list cache key reads it (only while a read filter is active) to
    /// detect stale in-progress results on its next natural render.
    @ObservationIgnored private(set) var revision = 0
    /// Bumped only when a video's progress crosses into watched, or out of it
    /// (Mark as Not Watched). Unlike `revision` it is observed, so a course's
    /// completion mark updates the moment a lecture finishes or is unmarked
    /// without every playhead write re-rendering it.
    private(set) var finishedVideoRevision = 0

    func seed(from articles: [StudioArticle]) {
        for article in articles {
            if let page = article.readingPositionPage {
                pages[article.id] = page
            }
            if let locator = article.readingPositionLocator {
                locators[article.id] = locator
            }
        }
        revision += 1
    }

    func hasProgress(for sourceID: String) -> Bool {
        if pages[sourceID] != nil { return true }
        guard let locator = locators[sourceID], !locator.isEmpty else { return false }
        // A video marked not watched keeps its epoch here and nothing else;
        // only that locator is decoded, and through the memo.
        guard locator.contains(VideoWatchProgress.unwatchedAtKey) else { return true }
        return videoWatchProgress(for: sourceID, fallbackLocator: nil)?.recordsWatching ?? true
    }

    func page(for sourceID: String) -> Int? {
        pages[sourceID]
    }

    func locator(for sourceID: String) -> String? {
        locators[sourceID]
    }

    func setPage(_ page: Int, for sourceID: String) {
        pages[sourceID] = page
        revision += 1
    }

    func setLocator(_ locator: String, for sourceID: String) {
        // Only a video's JSON locator can finish or unfinish it; EPUB locators
        // skip the decode.
        let mayChangeWatched = locator.contains("watchedSeconds")
        let wasWatched = mayChangeWatched
            && videoWatchProgress(for: sourceID, fallbackLocator: nil)?.isEssentiallyWatched == true
        locators[sourceID] = locator
        revision += 1
        if mayChangeWatched,
           wasWatched != (videoWatchProgress(for: sourceID, fallbackLocator: nil)?.isEssentiallyWatched == true) {
            finishedVideoRevision += 1
        }
    }

    /// Decoded video watch progress for a source, memoized per locator string so
    /// row bodies never re-run the JSON decode on every render. Falls back to the
    /// article's persisted locator for sources whose live store entry hasn't been
    /// touched this session.
    func videoWatchProgress(for sourceID: String, fallbackLocator: String?) -> VideoWatchProgress? {
        guard let locator = locators[sourceID] ?? fallbackLocator, !locator.isEmpty else { return nil }
        if let cached = videoProgressMemo[sourceID], cached.locator == locator {
            return cached.progress
        }
        let progress = VideoWatchProgress(encoded: locator)
        videoProgressMemo[sourceID] = (locator, progress)
        return progress
    }

    func articleWithProgress(_ article: StudioArticle) -> StudioArticle {
        var merged = article
        if let page = pages[article.id] {
            merged.readingPositionPage = page
        }
        if let locator = locators[article.id] {
            merged.readingPositionLocator = locator
        }
        return merged
    }
}

// MARK: - Sidebar presentation

/// Sidebar tab, search, pagination, and filter cache — decoupled from reader
/// and chat workflow state.
@Observable
@MainActor
final class StudioSidebarStore {
    var sidebarTab: StudioSidebarTab = .articles
    /// The Library shows Recent — every kind in one list, newest added first
    /// (`StudioViewModel.recentlyAddedSources`) — in place of `sidebarTab`'s
    /// list. Picking a kind's tab turns it off. Remembered on this Mac, so a
    /// Library left on Recent opens on it again.
    var showsRecent: Bool = UserDefaults.standard.bool(forKey: StudioSidebarStore.showsRecentPreferenceKey) {
        didSet {
            guard showsRecent != oldValue else { return }
            UserDefaults.standard.set(showsRecent, forKey: Self.showsRecentPreferenceKey)
        }
    }
    static let showsRecentPreferenceKey = "library.showsRecent.v1"
    /// How many rows Recent draws before its Show More.
    var recentDisplayLimit: Int = 60
    /// The query every source list filters on. While the learner types it trails
    /// `searchFieldText` by a short pause (`SourceSearchField` commits it),
    /// so the whole-library filter runs once per pause rather than once per
    /// keystroke. Writing it directly — a tab switch clearing it — puts the
    /// field in step at once.
    var searchText: String = "" {
        didSet {
            if searchFieldText != searchText { searchFieldText = searchText }
        }
    }
    /// What the search field shows, keystroke by keystroke. Nothing filters on
    /// it; only the field, its scope chip and its clear button read it.
    var searchFieldText: String = ""
    var displayLimit: Int = 40
    /// Papers-tab pagination, one limit per section, because the tab renders
    /// three lists ("Show More" on one must not grow the others).
    var papersWithPDFDisplayLimit: Int = 40
    var papersWithoutPDFDisplayLimit: Int = 40
    var paywalledPapersDisplayLimit: Int = 40
    var sourceReviewFilter: SourceReviewFilter = .all
    var sourceReadFilter: SourceReadFilter = .all
    var sourceContentFilter: SourceContentFilter = .all
    /// The Library's No Cards pill (`SourceCardScope.withoutCards`): only the
    /// sources no card covers, read from `StudioViewModel.sourceCardCoverage`.
    var sourceCardFilter: SourceCardScope = .all
    var articleOriginFilter: DiscoveryOrigin?
    /// Narrows the Meetings tab to one provider (nil = every provider).
    ///
    /// A filter, not a membership rule: this is the whole difference between
    /// one Meetings tab and the split Google Drive / Read AI tabs it replaced.
    /// Provider used to decide which tab a session could appear in, which left
    /// folder imports homeless and listed mixed-provider series twice. Now it
    /// narrows a list the learner is already looking at, and defaults to off.
    var meetingProviderFilter: MeetingProvider?

    /// Sources whose canonical content contains every term in the current `searchText`,
    /// rather than matching the metadata `sourceMatchesSearch` scans. Filled by
    /// `refreshSidebarContentSearchMatches` a moment after typing stops and unioned into
    /// the rendered list; empty whenever no search is running.
    var contentSearchMatchIDs: Set<String> = []

    /// Bumped whenever `contentSearchMatchIDs` changes. Carried in the sidebar filter
    /// cache key so the list recomputes when the asynchronous pass lands — the key
    /// cannot hold the id set itself without hashing it on every render.
    var contentSearchRevision: Int = 0

    /// Expanded sidebar disclosure groups (meeting series, video playlists,
    /// courses). Lives here rather than as view `@State` so collapsing the
    /// sources panel to a rail — which destroys the sidebar view — doesn't
    /// reset expansion and drop the selected row out of the list when the
    /// panel is expanded again.
    var expandedGroups: Set<String> = []

    @ObservationIgnored var filteredSidebarCacheKey: StudioViewModel.SidebarFilterCacheKey?
    @ObservationIgnored var filteredSidebarCache: [StudioArticle]?

    /// Papers-tab badge count. Stored, not memoized-on-read: the count is a
    /// whole-library partition whose per-paper work parses URLs and normalizes
    /// titles, and a lazy memo still pays that scan on the main actor the first
    /// time a render misses it. Launch misses it repeatedly — every republish of
    /// `articles` bumps the revision — which put a library-sized scan inside the
    /// sidebar's view body. It is now computed off the main actor and published
    /// here; the sidebar only reads this value.
    ///
    /// `papersWithoutPDFBadgeKey` records the inputs the stored count was
    /// computed for, so a stale value schedules exactly one refresh.
    var papersWithoutPDFBadge: Int = 0
    @ObservationIgnored var papersWithoutPDFBadgeKey: StudioViewModel.PapersWithoutPDFBadgeCacheKey?
    @ObservationIgnored var papersWithoutPDFBadgeTask: Task<Void, Never>?

    /// Search-field count memoized per sidebar filter revision.
    @ObservationIgnored var totalFilteredCountCacheKey: StudioViewModel.SidebarFilterCacheKey?
    @ObservationIgnored var totalFilteredCountCache: Int?

    /// The No Cards pill's count — the tab's sources no card covers —
    /// memoized per tab, library and coverage read; one set test a source.
    @ObservationIgnored var sourcesWithoutCardsCountCacheKey: StudioViewModel.SourcesWithoutCardsCountCacheKey?
    @ObservationIgnored var sourcesWithoutCardsCountCache: Int?

    /// Books-tab group list memoized per filter revision and book metadata. The
    /// sidebar body reads it several times per render and the chapter filter once
    /// more; each read used to re-run every book's metadata and chapter scan.
    @ObservationIgnored var filteredBookGroupNamesCacheKey: StudioViewModel.FilteredBookGroupNamesCacheKey?
    @ObservationIgnored var filteredBookGroupNamesCache: [String]?

    /// Papers-tab partitioned lists memoized per sidebar filter revision and
    /// the library's share (`StudioViewModel.PaperLibraryKey`). Every
    /// `active*`/`hasMore*`/`remaining*` papers property funnels through
    /// `filteredPaperItems(hasPDF:)`; the whole-library sets it consults live on
    /// the view model (`paperLibraryIndex`), which this invalidation leaves be.
    @ObservationIgnored var filteredPaperItemsCacheKey: StudioViewModel.FilteredPaperItemsCacheKey?
    @ObservationIgnored var filteredPaperItemsWithPDFCache: [StudioArticle]?
    @ObservationIgnored var filteredPaperItemsWithoutPDFCache: [StudioArticle]?

    /// The Papers tab's four lists (`StudioViewModel.papersPartition`).
    @ObservationIgnored var papersPartitionCacheKey: StudioViewModel.PapersPartitionCacheKey?
    @ObservationIgnored var papersPartitionCache: StudioViewModel.PapersPartition?

    /// The current tab's rows and their ids (`StudioViewModel.activeTabArticles`,
    /// `visibleSidebarSourceIDs`).
    @ObservationIgnored var activeTabListingCacheKey: StudioViewModel.ActiveTabListingCacheKey?
    @ObservationIgnored var activeTabListingCache: StudioViewModel.ActiveTabListing?

    /// Articles-tab origin chips memoized per tab/articles revision.
    @ObservationIgnored var readingListOriginCountsCacheKey: StudioViewModel.ReadingListOriginCountsCacheKey?
    @ObservationIgnored var readingListOriginCountsCache: [(origin: DiscoveryOrigin, count: Int)]?

    /// Every library source's normalized URL and paper DOI, each mapped to its
    /// source id, memoized per articles revision; see
    /// `StudioViewModel.librarySourceID(forURL:)`. A chat's web sources footer
    /// asks once per citation per row build, and a scrolling lazy transcript
    /// rebuilds its rows constantly. `libraryURLKeysBuilds` counts the scans,
    /// so a test can show a hundred lookups cost one.
    @ObservationIgnored var libraryURLKeysCacheKey: Int?
    @ObservationIgnored var libraryURLKeysCache: [String: String]?
    @ObservationIgnored var libraryURLKeysBuilds = 0

    func invalidateFilteredCache() {
        filteredSidebarCache = nil
        filteredSidebarCacheKey = nil
        totalFilteredCountCache = nil
        totalFilteredCountCacheKey = nil
        sourcesWithoutCardsCountCache = nil
        sourcesWithoutCardsCountCacheKey = nil
        filteredBookGroupNamesCache = nil
        filteredBookGroupNamesCacheKey = nil
        readingListOriginCountsCache = nil
        readingListOriginCountsCacheKey = nil
        filteredPaperItemsCacheKey = nil
        filteredPaperItemsWithPDFCache = nil
        filteredPaperItemsWithoutPDFCache = nil
        papersPartitionCacheKey = nil
        papersPartitionCache = nil
        activeTabListingCacheKey = nil
        activeTabListingCache = nil
    }
}
