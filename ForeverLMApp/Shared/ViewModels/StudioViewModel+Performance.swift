import Foundation
import AppKit

extension StudioViewModel {

    // MARK: - Sidebar filter cache

    struct SidebarFilterCacheKey: Equatable {
        let tab: StudioSidebarTab
        let searchText: String
        let reviewFilter: SourceReviewFilter
        let readFilter: SourceReadFilter
        let contentFilter: SourceContentFilter
        let notebookFilter: SourceNotebookFilter
        /// Notebook membership revision, sampled only while the notebook
        /// filter is on (0 otherwise), so a source filed or taken out
        /// re-runs the list only when the filter reads membership.
        let notebookMembershipRevision: Int
        /// Reading-progress store revision, sampled only while a read filter is
        /// active (0 otherwise) so page-turn persistence doesn't churn the cache.
        let readingProgressRevision: Int
        let articleOriginFilter: DiscoveryOrigin?
        let meetingProviderFilter: MeetingProvider?
        /// The Books tab's category chip. `matchesCurrentTab` reads it, so a list
        /// cached without it kept showing the previous category.
        let selectedBookKind: String?
        /// Revision of the asynchronous content-search pass, so the list recomputes
        /// once matches from inside sources land.
        let contentSearchRevision: Int
        /// Sort modes belong in the key directly. Relying on `resetDisplayLimits()`
        /// to perturb `displayLimit` instead is a no-op when the limit is already
        /// at its default, which serves a stale array to an unscrolled list.
        let podcastSortMode: PodcastSortMode
        let videoSortMode: VideoSortMode
        let meetingListOrder: MeetingListOrder
        let articlesRevision: Int
        let displayLimit: Int
        let courseMetadataCount: Int
        let meetingMetadataCount: Int
        let bookTitleCount: Int
    }

    struct ReadingListOriginCountsCacheKey: Equatable {
        let tab: StudioSidebarTab
        let articlesRevision: Int
        let safariEnabled: Bool
        let chromeEnabled: Bool
        let braveEnabled: Bool
    }

    struct PapersWithoutPDFBadgeCacheKey: Equatable {
        let articlesRevision: Int
        let processingPaperIDs: Set<String>
        /// The badge counts only what Screen record mode lets on screen, so
        /// turning the mode on or off asks for a new count.
        let screenRecordScope: ScreenRecordScope?
    }

    func invalidateFilteredSidebarCache() {
        invalidateSidebarCachesInEveryWindow()
    }

    var filteredSidebarCacheKey: SidebarFilterCacheKey? {
        get { sidebarStore.filteredSidebarCacheKey }
        set { sidebarStore.filteredSidebarCacheKey = newValue }
    }

    var filteredSidebarCache: [StudioArticle]? {
        get { sidebarStore.filteredSidebarCache }
        set { sidebarStore.filteredSidebarCache = newValue }
    }

    func computeFilteredActiveItems() -> [StudioArticle] {
        let filed = sourceNotebookFilter == .all ? nil : sourceIDsInAnyNotebook()
        var tabItems = activeArticles
            .filter { matchesCurrentTab($0) }
            .filter { matchesReviewFilter($0) }
            .filter { matchesReadFilter($0) }
            .filter { matchesContentFilter($0) }
            .filter { article in filed.map { !$0.contains(canonicalSourceID(article.id)) } ?? true }
            .sorted { lhs, rhs in
                if sidebarTab == .videos {
                    return compareVideoArticles(lhs, rhs)
                }
                if sidebarTab == .meetings {
                    if meetingListOrder == .byDate {
                        // The meeting's own day, across every series; the id
                        // keeps two sessions at one moment in a fixed order.
                        if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
                        return lhs.id < rhs.id
                    }
                    if let a = lhs.courseSortIndex, let b = rhs.courseSortIndex {
                        return a < b
                    }
                    if lhs.courseSortIndex != nil { return true }
                    if rhs.courseSortIndex != nil { return false }
                    return lhs.dateAdded > rhs.dateAdded
                }
                if sidebarTab == .books {
                    if let a = lhs.courseSortIndex, let b = rhs.courseSortIndex {
                        return a < b
                    }
                    if lhs.courseSortIndex != nil { return true }
                    if rhs.courseSortIndex != nil { return false }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                if sidebarTab == .podcasts {
                    return comparePodcastArticles(lhs, rhs)
                }
                return lhs.dateAdded > rhs.dateAdded
            }
        if sidebarTab == .articles {
            let safariEnabled = DefaultsEscapeHatch.bool(forKey: "readingListSafari", default: true)
            let chromeEnabled = DefaultsEscapeHatch.bool(forKey: "readingListChrome", default: true)
            let braveEnabled = DefaultsEscapeHatch.bool(forKey: "readingListBrave", default: true)
            tabItems = tabItems.filter { article in
                switch article.discoveryOrigin {
                case .safari: return safariEnabled
                case .chrome: return chromeEnabled
                case .brave: return braveEnabled
                default: return true
                }
            }
        }
        if sidebarTab == .meetings {
            tabItems = tabItems.filter { article in
                guard article.sourceType == .meeting,
                      let groupName = article.parentGroup else { return false }
                return !(meetingMetadata[groupName]?.isHidden ?? false)
                    && meetingMatchesSearch(groupName)
            }
        }
        if sidebarTab == .articles, let filter = articleOriginFilter {
            tabItems = tabItems.filter { ($0.discoveryOrigin ?? .manual) == filter }
        }
        if sidebarTab == .meetings, let provider = meetingProviderFilter {
            tabItems = tabItems.filter { MeetingProvider.forOrigin($0.discoveryOrigin) == provider }
        }
        if sidebarTab == .books {
            // One membership test per chapter. Asking `bookGroupMatchesCurrentFilters`
            // per chapter re-ran the book's whole metadata and chapter scan once for
            // every chapter it owns, on every keystroke — a 600-chapter library stalled
            // the main thread for as long as it took to type the word.
            let matchingGroups = Set(filteredBookGroupNames)
            let contentMatches = sidebarContentSearchMatchIDsForCurrentQuery
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return tabItems.filter { article in
                guard let groupName = article.parentGroup else {
                    guard !query.isEmpty else { return true }
                    return sourceMatchesSearch(article, query: query) || contentMatches.contains(article.id)
                }
                return matchingGroups.contains(groupName)
            }
        }
        if sidebarTab == .meetings {
            return tabItems
        }
        guard !searchText.isEmpty else { return tabItems }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Metadata matches plus canonical bodies containing every typed term. Purely
        // additive: an indexed body match can join the filtered list without merely
        // similar sources widening it later.
        //
        // Two tiers, each in the tab's own order. The metadata pass is synchronous and
        // draws the list as the learner types; the body pass lands a debounce and a
        // database query later. Sorting both tiers together by the tab's order let
        // that second pass slot hundreds of body matches *above* the rows already on
        // screen — a paper whose title was the query dropped out of view under every
        // paper that merely mentions the words — so the later pass only ever appends
        // below what the first one showed, and nothing already drawn moves.
        let contentMatches = sidebarContentSearchMatchIDsForCurrentQuery
        var metadataMatches: [StudioArticle] = []
        var bodyOnlyMatches: [StudioArticle] = []
        for article in tabItems {
            if sourceMatchesSearch(article, query: query) {
                metadataMatches.append(article)
            } else if contentMatches.contains(article.id) {
                bodyOnlyMatches.append(article)
            }
        }
        return metadataMatches + bodyOnlyMatches
    }

    /// The indexed body matches the list may union in. Empty for a field-scoped
    /// search: the pass clears them a debounce later, and until then they belong to
    /// the unscoped query the learner just narrowed away from.
    var sidebarContentSearchMatchIDsForCurrentQuery: Set<String> {
        sidebarSearchQuery.isScoped ? [] : sidebarStore.contentSearchMatchIDs
    }

    var currentSidebarFilterCacheKey: SidebarFilterCacheKey {
        SidebarFilterCacheKey(
            tab: sidebarTab,
            searchText: searchText,
            reviewFilter: sourceReviewFilter,
            readFilter: sourceReadFilter,
            contentFilter: sourceContentFilter,
            notebookFilter: sourceNotebookFilter,
            notebookMembershipRevision: sourceNotebookFilter == .all ? 0 : notebookMembershipRevision,
            readingProgressRevision: sourceReadFilter == .all ? 0 : readingProgressStore.revision,
            articleOriginFilter: articleOriginFilter,
            meetingProviderFilter: meetingProviderFilter,
            selectedBookKind: selectedBookKind,
            contentSearchRevision: sidebarStore.contentSearchRevision,
            podcastSortMode: podcastSortMode,
            videoSortMode: videoSortMode,
            meetingListOrder: meetingListOrder,
            articlesRevision: articlesRevision,
            displayLimit: displayLimit,
            courseMetadataCount: courseMetadata.count,
            meetingMetadataCount: meetingMetadata.count,
            bookTitleCount: bookTitles.count
        )
    }

    // MARK: - Reading progress (decoupled from `articles` mutations)

    func seedReadingProgressFromArticles() {
        readingProgressStore.seed(from: articles)
    }

    func articleWithCurrentReadingProgress(_ article: StudioArticle) -> StudioArticle {
        readingProgressStore.articleWithProgress(article)
    }

    func readingPositionPage(for sourceID: String) -> Int? {
        readingProgressStore.page(for: sourceID)
    }

    func readingPositionLocator(for sourceID: String) -> String? {
        readingProgressStore.locator(for: sourceID)
    }

    // MARK: - Book cover scanning (off main actor)

    struct BookCoverScanSnapshot: Sendable {
        let groupName: String
        let coverPath: String
    }

    nonisolated static func scanBookCoverPaths(
        bookArticles: [StudioArticle],
        booksDirectory: String
    ) -> [BookCoverScanSnapshot] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: booksDirectory) else { return [] }

        let bookGroups = Set(bookArticles.compactMap(\.parentGroup))
        guard !bookGroups.isEmpty else { return [] }

        var results: [BookCoverScanSnapshot] = []
        for groupName in bookGroups {
            let bookDir: String? = {
                if let first = bookArticles.first(where: { $0.parentGroup == groupName }),
                   let path = first.localFilePath ?? (first.url.hasPrefix("/") ? first.url : nil) {
                    let parent = (path as NSString).deletingLastPathComponent
                    if (parent as NSString).lastPathComponent == "Chapters" {
                        return (parent as NSString).deletingLastPathComponent
                    }
                    return parent
                }
                return nil
            }()

            guard let bookDir else { continue }
            let coverPath = (bookDir as NSString).appendingPathComponent("cover.jpg")
            if fm.fileExists(atPath: coverPath) {
                results.append(BookCoverScanSnapshot(groupName: groupName, coverPath: coverPath))
            }
        }
        return results
    }

    nonisolated static func prewarmBookCoverThumbnailOffMain(coverPath: String) {
        let size = CGSize(width: 36, height: 48)
        let cacheKey = "book-cover:\(coverPath):\(Int(size.width))x\(Int(size.height))"
        guard ImageCache.shared.image(for: cacheKey) == nil else { return }
        guard let image = PlatformImage(contentsOfFile: coverPath) else { return }
        ImageCache.shared.set(image, for: cacheKey, toDisk: true)
    }

    func scheduleBookCoverPathPopulation() {
        bookCoverPopulationTask?.cancel()
        // Must use detached — a plain Task inherits @MainActor and turns cover file
        // reads into launch beachballs (see UIResponsivenessMonitor stall samples).
        bookCoverPopulationTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = await MainActor.run { [weak self] in
                guard let self else {
                    return ([StudioArticle](), "")
                }
                return (
                    self.articles.filter { $0.sourceType == .book },
                    (self.knowledgeBasePath as NSString).appendingPathComponent("Books")
                )
            }
            let covers = Self.scanBookCoverPaths(
                bookArticles: snapshot.0,
                booksDirectory: snapshot.1
            )
            for cover in covers {
                guard !Task.isCancelled else { return }
                Self.prewarmBookCoverThumbnailOffMain(coverPath: cover.coverPath)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self, covers] in
                guard let self else { return }
                for cover in covers {
                    self.bookCoverPaths[cover.groupName] = cover.coverPath
                }
            }
        }
    }

    // MARK: - Source search index

    struct SourceSearchMetadataEntry: Sendable {
        let id: String
        let title: String
        let domain: String
        let author: String
        let parentGroup: String
        let contentPrefix: String
    }

    nonisolated static func metadataSearchScores(
        entries: [SourceSearchMetadataEntry],
        normalizedQuery: String,
        queryTerms: [String]
    ) -> [String: Float] {
        // Folded once, not per entry: the query is the same for all of them.
        let foldedQuery = SourceSearchEngine.catenatedFold(normalizedQuery)
        var textScores: [String: Float] = [:]
        for entry in entries {
            let fields = [
                entry.title,
                entry.domain,
                entry.author,
                entry.parentGroup,
                entry.contentPrefix,
            ].joined(separator: " ").lowercased()
            // Metadata is folded so this pass agrees with the index lookup that replaces
            // it — "GDF15" and "GDF-15" must mean the same thing in both, or a source
            // flickers out of the list and back in. Only the short fields: folding a
            // 2,000-character body for every source in the library is what makes a
            // keystroke feel slow, and the body is the full-text branch's job, which
            // now analyzes both spellings itself.
            let foldedMetadata = SourceSearchEngine.catenatedFold(
                [entry.title, entry.domain, entry.author, entry.parentGroup]
                    .joined(separator: " ")
                    .lowercased()
            )

            var score: Float = 0
            if fields.contains(normalizedQuery) || foldedMetadata.contains(foldedQuery) {
                score = 1.25
            }
            let matchCount = queryTerms.filter {
                fields.contains($0) || foldedMetadata.contains($0)
            }.count
            if !queryTerms.isEmpty {
                score += Float(matchCount) / Float(queryTerms.count)
            }
            if score > 0 {
                textScores[entry.id] = score
            }
        }
        return textScores
    }
}
