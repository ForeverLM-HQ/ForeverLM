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

extension StudioViewModel {

    // MARK: - Derived State

    var selectedArticle: StudioArticle? {
        guard let id = selectedArticleId else { return nil }
        guard let article = articlesById[id] else { return nil }
        return articleWithCurrentReadingProgress(article)
    }

    var activeArticles: [StudioArticle] {
        articles
    }

    /// Active articles for the current tab, filtered by search text and paginated.
    /// Grouped collections show all items (no pagination) so their sections stay coherent.
    var activeTabArticles: [StudioArticle] {
        // The Videos tab pages by state the listing key does not carry
        // (transcript fetches in flight), so it is built on each read, as it
        // always was.
        if sidebarTab == .videos { return pagedVideoTabArticles }
        return activeTabListing.articles
    }

    /// The ids of `activeTabArticles`. The Library list reads it at least once
    /// per render, and AppKit asks the List's selection binding built from it
    /// many times more; on a grouped tab it is every row of the tab.
    var visibleSidebarSourceIDs: Set<String> {
        if sidebarTab == .videos { return Set(pagedVideoTabArticles.map(\.id)) }
        return activeTabListing.ids
    }

    /// The current tab's rows and their ids, memoized per window on everything
    /// they are built from (`ActiveTabListingCacheKey`), so the many reads one
    /// render makes cost one build. The key is computed on every read, which is
    /// what keeps a view that hits the memo subscribed to those inputs. Not for
    /// the Videos tab (`activeTabArticles`).
    struct ActiveTabListing {
        let articles: [StudioArticle]
        let ids: Set<String>

        init(_ articles: [StudioArticle]) {
            self.articles = articles
            ids = Set(articles.map(\.id))
        }
    }

    struct ActiveTabListingCacheKey: Equatable {
        let filter: SidebarFilterCacheKey
        /// The Papers tab's partition and the limit of each of its sections;
        /// nil on every other tab, whose rows the filter key settles alone
        /// (it carries the tab, the Meetings order and `displayLimit`).
        let papers: PapersSectionsKey?
    }

    struct PapersSectionsKey: Equatable {
        let partition: PapersPartitionCacheKey
        let withoutPDFLimit: Int
        let withPDFLimit: Int
        let paywalledLimit: Int
    }

    private var activeTabListing: ActiveTabListing {
        let filter = currentSidebarFilterCacheKey
        let key = ActiveTabListingCacheKey(
            filter: filter,
            papers: sidebarTab == .papers
                ? PapersSectionsKey(
                    partition: currentPapersPartitionCacheKey(filter: filter),
                    withoutPDFLimit: papersWithoutPDFDisplayLimit,
                    withPDFLimit: papersWithPDFDisplayLimit,
                    paywalledLimit: paywalledPapersDisplayLimit
                )
                : nil
        )
        let store = sidebarStore
        if let cached = store.activeTabListingCache, store.activeTabListingCacheKey == key {
            return cached
        }
        let listing = ActiveTabListing(computeActiveTabArticles())
        store.activeTabListingCache = listing
        store.activeTabListingCacheKey = key
        return listing
    }

    /// What `activeTabArticles` lists, built afresh: its body before the memo,
    /// and what the memo must always agree with.
    func computeActiveTabArticles() -> [StudioArticle] {
        if sidebarTab == .videos {
            return pagedVideoTabArticles
        }
        if listsMeetingsByDate {
            // One flat, paged list: no group to keep whole.
            return Array(filteredActiveItems.prefix(displayLimit))
        }
        if sidebarTab.isGrouped {
            // Grouped tabs render whole groups; truncating by individual item would
            // split a single book/course across the fold and surface a misleading
            // "Show More". Show every item so each group stays coherent.
            return filteredActiveItems
        }
        if sidebarTab == .papers {
            return activeProcessingPapers + activePapersWithoutPDF + activePapersWithPDF + activePaywalledPapersWithoutPDF
        }
        if sidebarTab == .podcasts {
            return activeProcessingPodcasts
                + activePodcastsNotProcessing
        }
        return Array(filteredActiveItems.prefix(displayLimit))
    }

    /// The Meetings tab is showing every session on its own row, newest first,
    /// rather than one row per series.
    var listsMeetingsByDate: Bool {
        sidebarTab == .meetings && meetingListOrder == .byDate
    }

    /// Drops list-selected sources the current tab or search no longer shows, so a bulk
    /// action can only reach rows the user can actually see.
    ///
    /// Deliberately leaves `selectedArticleId` alone. That one is the reader's source, not a
    /// row in this list. Filtering the sidebar is a question about the sidebar, and answering
    /// it by closing whatever is open — which is what this did on every tab switch and every
    /// keystroke in the source search field — threw away a video mid-watch.
    func pruneSelectionToVisibleSources() {
        // Built once: this runs on the main actor for every tab switch and every keystroke
        // in the source search field, and it walks the whole filtered list.
        let visibleIDs = visibleSidebarSourceIDs
        var next = selectedArticleIds.intersection(visibleIDs)
        // Nothing survived the filter, but the source the reader has open is on this list:
        // mark it. That is what makes returning to the tab a source lives in land on a
        // highlighted row instead of a list with nothing selected under an open reader. It
        // only fills an empty selection, so a multi-selection that survived is left alone.
        if next.isEmpty,
           let openID = activeWindowState.readerSourceID(fallingBackTo: selectedArticleId),
           visibleIDs.contains(openID) {
            next = [openID]
        }
        if next != selectedArticleIds {
            selectedArticleIds = next
        }
    }

    var activePapersWithPDF: [StudioArticle] {
        Array(filteredPapersWithPDF.prefix(papersWithPDFDisplayLimit))
    }

    var activeProcessingPapers: [StudioArticle] {
        filteredProcessingPapers
    }

    /// Queued and active Apple transcript lookups belong under Processing.
    /// Episodes without Apple transcripts leave this queue and wait for the
    /// learner's explicit audio-transcription choice.
    var activeProcessingPodcasts: [StudioArticle] {
        filteredActiveItems.filter {
            $0.sourceType == .podcast
                && ($0.state == .queued || $0.state == .fetching)
        }
    }

    var activePodcastsNotProcessing: [StudioArticle] {
        Array(filteredActiveItems.filter {
            $0.sourceType == .podcast && $0.state != .queued && $0.state != .fetching
        }.prefix(displayLimit))
    }

    var activeProcessingPodcastsTotalCount: Int {
        activeProcessingPodcasts.count
    }

    /// YouTube rows stay in Processing from metadata publication through the
    /// final formatting pass. `fetchYouTubeTranscript` intentionally publishes
    /// raw captions as ready before formatting completes, so the in-memory task
    /// set is part of the predicate rather than relying on persisted state alone.
    var activeProcessingVideos: [StudioArticle] {
        filteredActiveItems.filter(isProcessingVideoRow)
    }

    func isProcessingVideoRow(_ article: StudioArticle) -> Bool {
        article.sourceType == .video
            && YouTubeTranscriptService.isYouTubeURL(article.url)
            && (article.state == .queued
                || article.state == .fetching
                || youtubeTranscriptFetchInFlight.contains(article.id))
    }

    var activeProcessingVideosTotalCount: Int {
        activeProcessingVideos.count
    }

    /// The Videos tab is grouped like Books, but most of a video library is not in
    /// any playlist: hundreds of standalone videos render as flat rows under the
    /// collapsible groups. Rendering every one of them made SwiftUI's List
    /// re-measure the whole set on each click and each tab switch, a one- to
    /// three-second main-thread stall. So the tab keeps every collapsible playlist
    /// whole, as a grouped tab must, and pages only its flat rows — ungrouped
    /// videos and inline playlists — at `displayLimit`, exactly as a flat tab does.
    /// Processing videos sit in their own section and never consume the page.
    private var pagedVideoTabArticles: [StudioArticle] {
        var flatRowsKept = 0
        return filteredActiveItems.filter { article in
            guard isPagedVideoRow(article) else { return true }
            flatRowsKept += 1
            return flatRowsKept <= displayLimit
        }
    }

    /// Flat, non-processing rows in the Videos tab: the ones the page applies to.
    var pagedVideoRows: [StudioArticle] {
        filteredActiveItems.filter(isPagedVideoRow)
    }

    private func isPagedVideoRow(_ article: StudioArticle) -> Bool {
        isFlatVideoRow(article) && !isProcessingVideoRow(article)
    }

    var activePapersWithoutPDF: [StudioArticle] {
        Array(papersNeedingPDFAttention.prefix(papersWithoutPDFDisplayLimit))
    }

    var activePaywalledPapersWithoutPDF: [StudioArticle] {
        Array(filteredPaywalledPapersWithoutPDF.prefix(paywalledPapersDisplayLimit))
    }

    /// Whether there are more items beyond the current display limit
    var hasMoreItems: Bool {
        if sidebarTab == .papers { return false }
        if sidebarTab == .videos { return pagedVideoRows.count > displayLimit }
        if listsMeetingsByDate { return filteredActiveItems.count > displayLimit }
        // Grouped tabs show every item (no pagination), so there is never more.
        if sidebarTab.isGrouped { return false }
        return filteredActiveItems.count > displayLimit
    }

    /// How many individual items remain hidden beyond the current display limit.
    /// Uses item counts (not `totalFilteredCount`, which counts groups on grouped
    /// tabs) so the "Show More" label stays correct and never goes negative.
    var remainingItemCount: Int {
        max(filteredActiveItems.count - activeTabArticles.count, 0)
    }

    var hasMorePapersWithPDF: Bool {
        filteredPapersWithPDF.count > papersWithPDFDisplayLimit
    }

    var hasMorePapersWithoutPDF: Bool {
        papersNeedingPDFAttention.count > papersWithoutPDFDisplayLimit
    }

    var hasMorePaywalledPapersWithoutPDF: Bool {
        filteredPaywalledPapersWithoutPDF.count > paywalledPapersDisplayLimit
    }

    var remainingPapersWithPDFCount: Int {
        max(filteredPapersWithPDF.count - activePapersWithPDF.count, 0)
    }

    var remainingPapersWithoutPDFCount: Int {
        max(papersNeedingPDFAttention.count - activePapersWithoutPDF.count, 0)
    }

    var remainingPaywalledPapersWithoutPDFCount: Int {
        max(filteredPaywalledPapersWithoutPDF.count - activePaywalledPapersWithoutPDF.count, 0)
    }

    var activePapersWithoutPDFTotalCount: Int {
        papersNeedingPDFAttention.count
    }

    var activeProcessingPapersTotalCount: Int {
        filteredProcessingPapers.count
    }

    /// Any paper with active in-memory work belongs in the Processing section,
    /// regardless of whether that work is resolving a PDF, attaching one, or
    /// enriching its metadata. A persisted terminal error wins over an in-memory
    /// task that is still unwinding: showing both states at once leaves a failed
    /// paper under a spinner, and also hides it from the actionable partitions.
    /// These IDs are deliberately not persisted.
    var processingPaperIDs: Set<String> {
        let inFlight = resolvingPaperPDFIds
            .union(attachingPDFIds)
            .union(paperMetadataEnrichmentInFlight)
            .union(extractingPaperMetadataIds)
            .union(pendingPaperProcessingIds)
            .union(queuedPaperPDFResolutionIds)
            .union(queuedPaperMetadataExtractionIds)
        return Set(inFlight.filter { articlesById[$0]?.state != .error })
    }

    var filteredProcessingPapers: [StudioArticle] {
        papersPartition.processing
    }

    /// Whether any in-memory ingestion task still owns this paper. This is the
    /// membership half of `processingPaperIDs` for one row, without building the
    /// union, and it is the only thing that may keep a per-row caption alive.
    func hasActivePaperProcessingWork(_ articleID: String) -> Bool {
        resolvingPaperPDFIds.contains(articleID)
            || attachingPDFIds.contains(articleID)
            || paperMetadataEnrichmentInFlight.contains(articleID)
            || extractingPaperMetadataIds.contains(articleID)
            || pendingPaperProcessingIds.contains(articleID)
            || queuedPaperPDFResolutionIds.contains(articleID)
            || queuedPaperMetadataExtractionIds.contains(articleID)
    }

    /// Drop a per-row caption once nothing owns the paper any more. The phase
    /// reporters save the caption they found at entry and restore it on exit,
    /// which is right while the passes nest and wrong when they overlap: the
    /// attach flow published "Looking up paper metadata…", a direct extraction
    /// started underneath it and saved that caption as its "previous", the
    /// attach flow then found the extraction already running, returned, and
    /// cleared its own caption — and the extraction's exit put the stale one
    /// back with no task left behind it. Callers run this after every restore.
    func dropPaperProcessingStepIfIdle(_ articleID: String) {
        guard !hasActivePaperProcessingWork(articleID) else { return }
        paperProcessingSteps.removeValue(forKey: articleID)
    }

    /// The current per-row paper ingestion phase. Explicit captions are
    /// published at the metadata and cleanup boundaries; the surrounding task
    /// sets provide precise fallbacks for attachment, PDF lookup, and queueing.
    /// A caption is only ever shown for a paper some task still owns: the row's
    /// spinner is driven by this label alone, so a leaked caption would spin a
    /// finished paper forever.
    func paperProcessingStepLabel(for article: StudioArticle) -> String? {
        guard article.sourceType == .paper, article.state != .error,
              hasActivePaperProcessingWork(article.id) else { return nil }
        if let step = paperProcessingSteps[article.id], !step.isEmpty { return step }
        if extractingPaperMetadataIds.contains(article.id) {
            return "Extracting paper metadata…"
        }
        if paperMetadataEnrichmentInFlight.contains(article.id) {
            return "Looking up paper metadata…"
        }
        if attachingPDFIds.contains(article.id) {
            return "Attaching PDF…"
        }
        if resolvingPaperPDFIds.contains(article.id) {
            return article.cachedHasUsablePDF ? "Reading paper text…" : "Finding PDF…"
        }
        if queuedPaperMetadataExtractionIds.contains(article.id) {
            return "Waiting to extract metadata…"
        }
        if queuedPaperPDFResolutionIds.contains(article.id) {
            return article.cachedHasUsablePDF
                ? "Waiting to extract metadata…"
                : "Waiting to find PDF…"
        }
        if pendingPaperProcessingIds.contains(article.id) {
            return article.cachedHasUsablePDF
                ? "Waiting to extract metadata…"
                : "Waiting to find PDF…"
        }
        return nil
    }

    var papersNeedingPDFAttention: [StudioArticle] {
        papersPartition.needingPDFAttention
    }

    /// The Papers tab's four lists over the current window's filtered papers:
    /// Processing, needing attention, with a PDF, paywalled. A render reads
    /// them a dozen times over — each section's rows, its count, "Show More",
    /// the visible ids — so they are built together, once per state.
    struct PapersPartition {
        let processing: [StudioArticle]
        let needingPDFAttention: [StudioArticle]
        let withPDF: [StudioArticle]
        let paywalledWithoutPDF: [StudioArticle]
    }

    /// Everything the partition is built from: the filtered list, the
    /// library's share (`PaperLibraryKey`) and the papers some task owns.
    struct PapersPartitionCacheKey: Equatable {
        let filter: SidebarFilterCacheKey
        let library: PaperLibraryKey
        let processingPaperIDs: Set<String>
    }

    func currentPapersPartitionCacheKey(filter: SidebarFilterCacheKey) -> PapersPartitionCacheKey {
        PapersPartitionCacheKey(
            filter: filter,
            library: currentPaperLibraryKey,
            processingPaperIDs: processingPaperIDs
        )
    }

    /// Memoized per window in `sidebarStore`, which the sidebar invalidation
    /// empties along with the filtered list the partition is cut from.
    var papersPartition: PapersPartition {
        let key = currentPapersPartitionCacheKey(filter: currentSidebarFilterCacheKey)
        let store = sidebarStore
        if let cached = store.papersPartitionCache, store.papersPartitionCacheKey == key {
            return cached
        }
        let partition = computePapersPartition(processingIDs: key.processingPaperIDs)
        store.papersPartitionCache = partition
        store.papersPartitionCacheKey = key
        return partition
    }

    /// The four lists built afresh, each by the filter it always had.
    func computePapersPartition(processingIDs: Set<String>) -> PapersPartition {
        let base = filteredActiveItems
        let missingPDFItems = filteredPaperItems(hasPDF: false)
        let withPDFItems = filteredPaperItems(hasPDF: true)

        let processing = processingIDs.isEmpty ? [] : base.filter {
            $0.sourceType == .paper && processingIDs.contains($0.id)
        }

        let missingPDFIDs = Set(missingPDFItems.map(\.id))
        let partitionedIDs = missingPDFIDs.union(withPDFItems.map(\.id))
        let needingPDFAttention = base.filter {
            $0.sourceType == .paper
                && !$0.hasPaywallMarker
                && !processingIDs.contains($0.id)
                && $0.state != .fetching
                && partitionedIDs.contains($0.id)
                && (missingPDFIDs.contains($0.id)
                    || $0.state == .error
                    || !$0.hasPaperIngestionAttestation)
        }

        let withPDF = withPDFItems.filter {
            !processingIDs.contains($0.id)
                && $0.state != .error
                && $0.hasPaperIngestionAttestation
        }

        let paywalledWithoutPDF = missingPDFItems.filter {
            $0.hasPaywallMarker && !processingIDs.contains($0.id)
        }

        return PapersPartition(
            processing: processing,
            needingPDFAttention: needingPDFAttention,
            withPDF: withPDF,
            paywalledWithoutPDF: paywalledWithoutPDF
        )
    }

    /// Papers stuck in `.fetching` with no PDF — typically left over from a
    /// download that was interrupted (app quit or crashed mid-fetch). They are
    /// deliberately excluded from the visible attention list and the badge,
    /// because a download that is genuinely in flight also sits in `.fetching`
    /// and counting it would make the badge un-clearable. The manual "Try Papers
    /// Needing Attention" pass recovers them: it resets them to `.ready` and
    /// retries, only when no download is currently active.
    var papersStuckFetchingPDF: [StudioArticle] {
        paperItems(hasPDF: false, in: activeArticles.filter {
            $0.sourceType == .paper && !$0.hasPaywallMarker && !isSourceHidden($0)
        }).filter { $0.state == .fetching && $0.url.hasPrefix("http") }
    }

    var activePaywalledPapersWithoutPDFTotalCount: Int {
        filteredPaywalledPapersWithoutPDF.count
    }

    /// Global count for the Papers tab badge. This intentionally ignores the
    /// current sidebar tab and search state so missing PDFs and actionable failures
    /// remain visible after refreshing reading lists from Articles. Paywalled
    /// papers are excluded because the user has already acknowledged that a PDF
    /// is not currently available. The trailing filters mirror
    /// `papersNeedingPDFAttention` so the badge only counts papers that can
    /// actually be acted on in the list.
    ///
    /// Reading this is O(1) and safe inside a view body: it returns the last
    /// published count and, when the inputs have moved on, schedules the scan
    /// that produces the next one off the main actor.
    ///
    /// It used to compute the partition inline, memoized per articles revision.
    /// That memo is worthless during launch — every republish of `articles`
    /// bumps the revision — so a library-sized scan ran inside the sidebar's
    /// view body on each pass. On a 700-paper library a launch profile put it at
    /// 310ms of main-thread time, the largest single app-code term, which is a
    /// beachball the sidebar has no business causing for a badge number.
    var papersWithoutPDFBadgeCount: Int {
        refreshPapersWithoutPDFBadgeIfNeeded()
        return sidebarStore.papersWithoutPDFBadge
    }

    /// Recompute the Papers badge when its inputs have changed since the stored
    /// count was produced. Cheap enough to call from a render: it builds the
    /// key, compares it, and otherwise returns.
    ///
    /// The scan itself is debounced, because the writes that drive it arrive in
    /// bursts — content fetching writes `articles[idx]` repeatedly — and each
    /// burst should cost one scan, not one per write.
    func refreshPapersWithoutPDFBadgeIfNeeded() {
        let key = PapersWithoutPDFBadgeCacheKey(
            articlesRevision: articlesRevision,
            processingPaperIDs: processingPaperIDs,
            screenRecordScope: screenRecordScope
        )
        // Resolved once, up front: the badge belongs to the window that asked
        // for it, and by the time the scan lands the key window — or the
        // `inWindow` scope this was read in — may be a different one.
        let store = sidebarStore
        guard store.papersWithoutPDFBadgeKey != key else { return }
        store.papersWithoutPDFBadgeKey = key

        let snapshot = activeArticles
        let processingIDs = key.processingPaperIDs
        let scope = key.screenRecordScope
        store.papersWithoutPDFBadgeTask?.cancel()
        store.papersWithoutPDFBadgeTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let count = await Task.detached(priority: .utility) {
                Self.papersWithoutPDFBadgeCount(
                    in: snapshot,
                    processingPaperIDs: processingIDs,
                    screenRecordScope: scope
                )
            }.value
            guard !Task.isCancelled else { return }
            // A newer refresh may have superseded this one while it ran; only the
            // scan for the current inputs may publish.
            guard store.papersWithoutPDFBadgeKey == key else { return }
            store.papersWithoutPDFBadge = count
        }
    }

    /// Recompute and publish the badge, awaiting the result.
    ///
    /// The scheduled path above is what the app uses; this is for callers that
    /// need the settled number rather than the next render's — tests, and any
    /// caller that has just changed the library and wants to assert on it.
    func refreshPapersWithoutPDFBadgeNow() async {
        let key = PapersWithoutPDFBadgeCacheKey(
            articlesRevision: articlesRevision,
            processingPaperIDs: processingPaperIDs,
            screenRecordScope: screenRecordScope
        )
        let store = sidebarStore
        let snapshot = activeArticles
        let processingIDs = key.processingPaperIDs
        let scope = key.screenRecordScope
        store.papersWithoutPDFBadgeTask?.cancel()
        store.papersWithoutPDFBadgeTask = nil
        let count = await Task.detached(priority: .utility) {
            Self.papersWithoutPDFBadgeCount(
                in: snapshot,
                processingPaperIDs: processingIDs,
                screenRecordScope: scope
            )
        }.value
        store.papersWithoutPDFBadgeKey = key
        store.papersWithoutPDFBadge = count
    }

    /// The Papers-tab badge partition, over a snapshot so it never runs during a
    /// render. Mirrors `paperItems(hasPDF:in:)` for both halves.
    ///
    /// A paper is never a podcast or a video, so the hidden test that
    /// `isSourceHidden` performs reduces to `isHidden` for this set — which is
    /// what lets the whole partition leave the main actor.
    ///
    /// Screen record mode counts only the papers the take may show, as the
    /// Papers list under the tab lists them (`isVisibleInRecordingMode`). A
    /// paper is never a meeting session, the one kind a folder lets through,
    /// so it is asked without one and the scope's question needs nothing from
    /// the main actor.
    nonisolated static func papersWithoutPDFBadgeCount(
        in articles: [StudioArticle],
        processingPaperIDs: Set<String>,
        screenRecordScope: ScreenRecordScope?
    ) -> Int {
        let unavailable = cachedUnavailableRecordedPaperPDFIDs(in: articles)
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }

        let superseded = supersededPreprintIDs(in: articles, hasUsablePDF: hasUsablePDF)
        let eligiblePapers = articles.filter { paper in
            paper.sourceType == .paper && !paper.hasPaywallMarker && !paper.isHidden
                && !superseded.contains(paper.id)
                && (screenRecordScope?.allowsSource(
                    id: paper.id, addedAt: paper.dateAdded,
                    kind: paper.sourceType.rawValue, url: paper.url, show: paper.domain,
                    origin: paper.discoveryOrigin
                ) ?? true)
        }

        // Duplicate suppression is a library invariant, so the keys that count as
        // "already held with a PDF" come from the whole library, not from the
        // eligible subset.
        let paperKeysWithPDF = Set(
            articles
                .filter { $0.sourceType == .paper && hasUsablePDF($0) }
                .flatMap { paperDedupDisplayKeys(for: $0) }
        )
        let missingPDFs = eligiblePapers.filter { paper in
            guard !hasUsablePDF(paper) else { return false }
            return paperKeysWithPDF.isDisjoint(with: paperDedupLookupKeys(for: paper))
        }
        let missingPDFIDs = Set(missingPDFs.map(\.id))

        return (missingPDFs + eligiblePapers.filter(hasUsablePDF)).filter {
            $0.state != .fetching
                && !processingPaperIDs.contains($0.id)
                && (missingPDFIDs.contains($0.id)
                    || $0.state == .error
                    || !$0.hasPaperIngestionAttestation)
        }.count
    }

    /// Total number of active items matching the current filter.
    /// For books and meetings, counts top-level groups instead of individual files.
    var totalFilteredCount: Int {
        let key = currentSidebarFilterCacheKey
        if let cached = sidebarStore.totalFilteredCountCache,
           sidebarStore.totalFilteredCountCacheKey == key {
            return cached
        }
        let count: Int
        if listsMeetingsByDate {
            count = filteredActiveItems.count
        } else if sidebarTab == .meetings {
            count = filteredMeetingGroupNames.count
        } else if sidebarTab == .books {
            count = filteredBookGroupNames.count
        } else {
            count = filteredActiveItems.count
        }
        sidebarStore.totalFilteredCountCache = count
        sidebarStore.totalFilteredCountCacheKey = key
        return count
    }

    func filteredReviewSessionLinks(matching search: String = "") -> [ReviewSessionRecord] {
        // Touch every observable input up front so `@Observable` registers the
        // view's dependency even when the cached run below is returned — a
        // cache hit that skipped these reads would leave the rail blind to the
        // next links/order/filter change.
        let links = reviewSessionLinks
        let filter = reviewSessionFilter
        let transcriptMatchIDs = reviewTranscriptMatchIDs
        let screenRecordScope = screenRecordScope
        let key = FilteredReviewSessionsCacheKey(
            linksRevision: reviewSessionLinksRevision,
            chatOrderRevision: chatOrderRevision,
            filter: filter,
            transcriptMatchIDs: transcriptMatchIDs,
            search: search,
            screenRecordScope: screenRecordScope
        )
        // A group filter resolves through the live group→sources mapping,
        // which the key doesn't capture; compute it fresh every time.
        var cacheable = true
        if case .group = filter { cacheable = false }
        if cacheable, let cached = cachedFilteredReviewSessions, cached.key == key {
            return cached.sessions
        }
        let result = rebuildFilteredReviewSessionLinks(
            links,
            filter: filter,
            transcriptMatchIDs: transcriptMatchIDs,
            search: search
        )
        if cacheable {
            cachedFilteredReviewSessions = (key, result)
        }
        return result
    }

    private func rebuildFilteredReviewSessionLinks(
        _ links: [ReviewSessionRecord],
        filter: ReviewSessionFilter?,
        transcriptMatchIDs: Set<String>?,
        search: String
    ) -> [ReviewSessionRecord] {
        // Newest first, then the learner's own arrangement on top of that, so the
        // rail, the sessions panel, and a Notebook's chat list all present chats in
        // one order rather than three.
        // A hidden chat leaves every list this run feeds — the rail, the
        // sessions panel, a Notebook's chat list — and is listed again only by
        // `hiddenReviewSessions`, under the rail's Hidden fold.
        var sorted = orderedReviewSessions(
            links
                .filter { !$0.isHidden && isVisibleInRecordingMode($0) }
                .sorted { $0.createdAt > $1.createdAt }
        )
        switch filter {
        case .source(let sourceId):
            sorted = sorted.filter { $0.sourceIDs.contains(sourceId) }
        case .group(let groupName):
            let groupSourceIds = sourceIdsForGroup(groupName)
            sorted = sorted.filter { !Set($0.sourceIDs).isDisjoint(with: groupSourceIds) }
        case .none:
            break
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sorted }
        let transcriptMatches = transcriptMatchIDs ?? []
        return sorted.filter {
            $0.title.lowercased().contains(query)
                || ($0.url ?? "").lowercased().contains(query)
                || ($0.summary ?? "").lowercased().contains(query)
                || $0.provider.rawValue.lowercased().contains(query)
                || transcriptMatches.contains($0.id)
        }
    }

    /// Review chats scoped to a Notebook. Membership is the explicit goal link and
    /// nothing else: a chat belongs to a Notebook only when it was started from that
    /// Notebook or moved into it. Sharing sources with a Notebook's approved pool
    /// never files a chat under it — unassigned chats stay loose.
    func reviewSessionsForNotebook(_ goal: LearningGoalRecord, matching search: String = "") -> [ReviewSessionRecord] {
        filteredReviewSessionLinks(matching: search).filter { $0.goalID == goal.id }
    }

    /// The chats filed under a timebound Goal, newest first: started from its
    /// **Quiz me on it**, moved onto it from the rail's menu, or filed there
    /// over MCP (product owner, 2026-09-20: "if there is already clearly related
    /// chats then those should be linked"). What the Goal row's chats chip
    /// and the Goal editor list. Hidden chats are not listed, as nowhere else.
    func reviewSessions(forGoal goalID: String) -> [ReviewSessionRecord] {
        filteredReviewSessionLinks()
            .filter { $0.goalID == goalID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Partitions the rail's already-filtered chat run in one pass. A day's
    /// memory review lives under the Memory row that started it, whichever
    /// Notebook it may have been filed in. Of the rest, chats linked to an active
    /// Notebook sit beneath that folder, and so do chats linked to a Goal that
    /// draws on that Notebook (the Goal is the Notebook's, so its chats are
    /// found where the Notebook's are); loose chats, chats on a standalone
    /// Goal and chats linked to archived or deleted Notebooks remain in the
    /// general Chats section so hiding a Notebook can never make its
    /// conversations unreachable. `totalCount` is the Notebooks-plus-Chats
    /// count, so the Chats placeholder still shows when the only
    /// conversations are memory reviews.
    func reviewSessionGroups(
        for visibleNotebooks: [LearningGoalRecord],
        matching search: String = ""
    ) -> (
        memory: [ReviewSessionRecord],
        byNotebookID: [String: [ReviewSessionRecord]],
        outsideNotebooks: [ReviewSessionRecord],
        totalCount: Int
    ) {
        let visibleNotebookIDs = Set(visibleNotebooks.map(\.id))
        // The Notebook a nested Goal draws on, for the chats filed under the Goal.
        var notebookByGoalID: [String: String] = [:]
        for goal in learningGoals where goal.isGoal {
            if let parent = goal.parentNotebookID, !parent.isEmpty { notebookByGoalID[goal.id] = parent }
        }
        let sessions = filteredReviewSessionLinks(matching: search).filter {
            isReviewSessionInActiveLibrary($0, visibleNotebookIDs: visibleNotebookIDs)
        }
        var memory: [ReviewSessionRecord] = []
        var byNotebookID: [String: [ReviewSessionRecord]] = [:]
        var outsideNotebooks: [ReviewSessionRecord] = []
        for session in sessions {
            if MemoryReviewSession.isMemorySession(session.id) {
                memory.append(session)
            } else if let goalID = session.goalID, visibleNotebookIDs.contains(goalID) {
                byNotebookID[goalID, default: []].append(session)
            } else if let goalID = session.goalID, let parent = notebookByGoalID[goalID], visibleNotebookIDs.contains(parent) {
                byNotebookID[parent, default: []].append(session)
            } else {
                outsideNotebooks.append(session)
            }
        }
        return (memory, byNotebookID, outsideNotebooks, sessions.count - memory.count)
    }

    /// One library at a time. My Library shows the learner's own chats; a
    /// team shows the transcripts shared into it and the learner's own chats
    /// about that team's Notebooks, which stay theirs.
    private func isReviewSessionInActiveLibrary(
        _ session: ReviewSessionRecord,
        visibleNotebookIDs: Set<String>
    ) -> Bool {
        if let activeTeamID {
            return session.teamID == activeTeamID
                || (session.teamID == nil && session.goalID.map(visibleNotebookIDs.contains) == true)
        }
        return session.teamID == nil
    }

    /// The chats the learner hid from the sidebar, newest first, in the
    /// active library. `filteredReviewSessionLinks` never lists them, so the
    /// rail's Hidden fold under Chats is the one place to find one again — a
    /// Notebook's folder and the Memory row never show a hidden chat, whichever
    /// Notebook it is filed in.
    func hiddenReviewSessions(for visibleNotebooks: [LearningGoalRecord]) -> [ReviewSessionRecord] {
        let visibleNotebookIDs = Set(visibleNotebooks.map(\.id))
        return reviewSessionLinks
            .filter {
                $0.isHidden
                    && isVisibleInRecordingMode($0)
                    && isReviewSessionInActiveLibrary($0, visibleNotebookIDs: visibleNotebookIDs)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Every chat of the open library, newest first, for Home's list:
    /// those in a notebook and those in none, the hidden ones included (its
    /// Hidden scope lists them), and whatever source the rail's chats are
    /// filtered to, which Home does not show. A day's memory review is
    /// Memory's, as in the rail.
    func spaceChats() -> [ReviewSessionRecord] {
        let visibleNotebookIDs = Set(notebooks.map(\.id))
        return reviewSessionLinks
            .filter {
                !MemoryReviewSession.isMemorySession($0.id)
                    && isVisibleInRecordingMode($0)
                    && isReviewSessionInActiveLibrary($0, visibleNotebookIDs: visibleNotebookIDs)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Refreshes the set of sessions whose transcript content matches the
    /// sessions-panel search. Runs off the main actor through storage so large
    /// transcripts never block rendering.
    func updateReviewTranscriptSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            reviewTranscriptMatchIDs = nil
            return
        }
        do {
            reviewTranscriptMatchIDs = try await storage.searchReviewSessionIDs(matching: trimmed)
        } catch {
            logger.error("Failed to search review transcripts: \(error.localizedDescription)")
        }
    }

    func linkedReviewSessions(for sourceID: String) -> [ReviewSessionRecord] {
        reviewSessionsBySourceID[sourceID] ?? []
    }

    func rebuildReviewSessionIndex() {
        var index: [String: [ReviewSessionRecord]] = [:]
        for session in reviewSessionLinks {
            guard session.status == "completed" || session.status == "external_link" || session.status == "active" else {
                continue
            }
            for sourceID in session.sourceIDs {
                index[sourceID, default: []].append(session)
            }
        }
        for sourceID in index.keys {
            index[sourceID]?.sort { $0.createdAt > $1.createdAt }
        }
        reviewSessionsBySourceID = index
    }

    func matchesReviewFilter(_ article: StudioArticle) -> Bool {
        switch sourceReviewFilter {
        case .all:
            return true
        case .reviewed:
            return sourceReviewedAt[article.id] != nil
        case .notReviewed:
            return sourceReviewedAt[article.id] == nil
        }
    }

    /// Whether the learner has any saved reading position for this source,
    /// checking both the live progress store and the persisted article fields.
    private func hasReadingProgress(_ article: StudioArticle) -> Bool {
        readingProgressStore.hasProgress(for: article.id) || article.hasSavedReadingPosition
    }

    func sourceConsumptionStatus(for article: StudioArticle) -> SourceConsumptionStatus {
        SourceConsumptionStatus(
            isConsumed: article.isRead,
            completedActivityKinds: completedSourceActivityKinds[article.id] ?? []
        )
    }

    func matchesReadFilter(_ article: StudioArticle) -> Bool {
        let consumptionStatus = sourceConsumptionStatus(for: article)
        switch sourceReadFilter {
        case .all:
            return true
        case .read:
            return consumptionStatus == .read
        case .listened:
            return consumptionStatus == .listened
        case .inProgress:
            return consumptionStatus == .unread && hasReadingProgress(article)
        case .unread:
            return consumptionStatus == .unread && !hasReadingProgress(article)
        }
    }

    func matchesContentFilter(_ article: StudioArticle) -> Bool {
        switch sourceContentFilter {
        case .all:
            return true
        case .ready:
            return article.state == .ready
        case .processing:
            return article.state == .queued || article.state == .fetching
        case .failed:
            // Sentinel status flags (paywall, podcast confirmation, transcript
            // needed) are workflow states, not fetch failures.
            return article.state == .error && article.statusFlag == nil
        case .paywalled:
            return article.isPaywalled || article.statusFlag == .paywall
        }
    }

    /// The Library's No Cards pill: with it on, only a source the coverage
    /// lists with no card (`SourceCardCoverage.isWithoutCards`), so a team's
    /// copy, a hidden or paywalled source, one without text and a spoken
    /// script stay out, as `StorageService.sourceCardCoverage` leaves them
    /// out.
    func matchesCardFilter(_ article: StudioArticle) -> Bool {
        sourceCardFilter == .all || sourceCardCoverage.isWithoutCards(article.id)
    }

    /// True when a filter the chips under the search stand for (review, read,
    /// content status, meeting provider) is narrowing the sidebar. No Cards
    /// is not among them: its pill shows its own state.
    var hasChippedSourceListFilters: Bool {
        sourceReviewFilter != .all || sourceReadFilter != .all || sourceContentFilter != .all
            || meetingProviderFilter != nil
    }

    /// True when any of the source-list filters (review, read, content
    /// status, meeting provider, No Cards) is narrowing the sidebar.
    var hasActiveSourceListFilters: Bool {
        hasChippedSourceListFilters || sourceCardFilter != .all
    }

    /// Number of source-list filters currently narrowing the sidebar (0–5). The
    /// meeting provider filter counts: it lives in the same popover as the other
    /// chips, so it has to show in the badge and clear with them.
    var activeSourceListFilterCount: Int {
        [
            sourceReadFilter != .all,
            sourceReviewFilter != .all,
            sourceContentFilter != .all,
            meetingProviderFilter != nil,
            sourceCardFilter != .all,
        ]
        .filter { $0 }
        .count
    }

    func clearSourceListFilters() {
        sourceReviewFilter = .all
        sourceReadFilter = .all
        sourceContentFilter = .all
        meetingProviderFilter = nil
        sourceCardFilter = .all
    }

    /// The No Cards pill's count: the tab's sources no card covers, before
    /// the search and the other filters, so the pill says what it would list.
    /// Memoized per tab, library and coverage read (the tab's membership test
    /// is the only work; the coverage answers from a set).
    var sourcesWithoutCardsCountInTab: Int {
        let key = SourcesWithoutCardsCountCacheKey(
            tab: sidebarTab,
            selectedBookKind: selectedBookKind,
            articlesRevision: articlesRevision,
            coverageRevision: sourceCardCoverageRevision
        )
        if let cached = sidebarStore.sourcesWithoutCardsCountCache,
           sidebarStore.sourcesWithoutCardsCountCacheKey == key {
            return cached
        }
        let coverage = sourceCardCoverage
        let count = coverage.isEmpty ? 0 : activeArticles.reduce(0) { total, article in
            total + (coverage.isWithoutCards(article.id) && matchesCurrentTab(article) ? 1 : 0)
        }
        sidebarStore.sourcesWithoutCardsCountCache = count
        sidebarStore.sourcesWithoutCardsCountCacheKey = key
        return count
    }

    /// Active items for the current tab, filtered by search text (before pagination)
    var filteredActiveItems: [StudioArticle] {
        let key = currentSidebarFilterCacheKey
        if key == filteredSidebarCacheKey, let cached = filteredSidebarCache {
            return cached
        }
        let computed = computeFilteredActiveItems()
        filteredSidebarCacheKey = key
        filteredSidebarCache = computed
        return computed
    }

    /// A sidebar search as typed, split into the field it is scoped to and the
    /// words to find.
    ///
    /// `title:reverse electron transport` reads titles and nothing else — not the
    /// journal, not the abstract the indexed pass would otherwise reach — because a
    /// learner who remembers a phrase from a title does not want every paper whose
    /// body happens to use it. A bare query keeps searching everywhere. The prefix
    /// is recognised only at the very start of the query, so a DOI or a URL pasted
    /// into the field still behaves as an ordinary search.
    struct SidebarSearchQuery: Equatable {
        enum Field: String, CaseIterable {
            case title, author, journal, year, doi, site

            /// Every spelling a learner might type before the colon.
            static func named(_ name: String) -> Field? {
                switch name.lowercased() {
                case "title", "titles", "name": return .title
                case "author", "authors", "by": return .author
                case "journal", "journals", "venue", "publisher": return .journal
                case "year", "published": return .year
                case "doi": return .doi
                case "site", "domain", "url", "host": return .site
                default: return nil
                }
            }

            /// The chip the search row shows while the query is scoped.
            var label: String {
                switch self {
                case .title: return "Title"
                case .author: return "Author"
                case .journal: return "Journal"
                case .year: return "Year"
                case .doi: return "DOI"
                case .site: return "Site"
                }
            }
        }

        /// The field the search is confined to, or nil for an ordinary search.
        let field: Field?
        /// The words to find, trimmed, with any field prefix removed.
        let text: String

        init(parsing raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let colon = trimmed.firstIndex(of: ":"),
               let field = Field.named(String(trimmed[..<colon])) {
                self.field = field
                self.text = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                self.field = nil
                self.text = trimmed
            }
        }

        var isScoped: Bool { field != nil }
        var isEmpty: Bool { text.isEmpty }

        /// The metadata a scoped search reads on one source. An unscoped search reads
        /// all of it; `title:` reads the title alone, `site:` the host and address.
        func searchableValues(of article: StudioArticle) -> [String] {
            searchableValues(
                title: article.title,
                domain: article.domain,
                author: article.author,
                journal: article.journal,
                year: article.publishedYear,
                doi: article.doi,
                url: article.url,
                parentGroup: article.parentGroup
            )
        }

        /// The same choice over values copied out of a source, for the Docs source
        /// picker's index, which reads them off the main actor.
        func searchableValues(
            title: String,
            domain: String,
            author: String?,
            journal: String?,
            year: String?,
            doi: String?,
            url: String,
            parentGroup: String?
        ) -> [String] {
            switch field {
            case nil:
                return [title, domain, author, journal, year, doi, url, parentGroup].compactMap { $0 }
            case .title: return [title]
            case .author: return [author].compactMap { $0 }
            case .journal: return [journal].compactMap { $0 }
            case .year: return [year].compactMap { $0 }
            case .doi: return [doi].compactMap { $0 }
            case .site: return [domain, url]
            }
        }
    }

    /// The current window's search field, parsed.
    var sidebarSearchQuery: SidebarSearchQuery {
        SidebarSearchQuery(parsing: searchText)
    }

    /// Whether a group row (a book, a course, a meeting series, a playlist) answers
    /// a search on its own metadata. `metadata` is what an unscoped search reads;
    /// `titles` is what `title:` reads and `authors` what `author:` reads. Other
    /// scopes have no group-level answer and leave the decision to the group's rows,
    /// which the callers test with `sourceMatchesSearch`.
    static func sidebarGroupMatchesSearch(
        _ query: SidebarSearchQuery,
        metadata: [String],
        titles: [String],
        authors: [String] = []
    ) -> Bool {
        let normalizedQuery = normalizedSidebarSearchString(query.text)
        guard !normalizedQuery.isEmpty else { return true }
        let candidates: [String]
        switch query.field {
        case nil: candidates = metadata
        case .title: candidates = titles
        case .author: candidates = authors
        case .journal, .year, .doi, .site: candidates = []
        }
        let normalized = candidates.map(normalizedSidebarSearchString).filter { !$0.isEmpty }
        if normalized.contains(where: { $0.contains(normalizedQuery) }) {
            return true
        }
        // A shelf named "cf-mtDNA and Mitochondrial Health" answers to "cfmtDNA"
        // too, the same way a source does — see `sourceMatchesSearch`.
        let foldedQuery = foldedSidebarSearchString(normalizedQuery)
        guard !foldedQuery.isEmpty else { return false }
        return normalized.contains { foldedSidebarSearchString($0).contains(foldedQuery) }
    }

    /// Whether a source answers a sidebar search: the whole query in one of its
    /// fields, then its fold, then every term, then every folded term, then a
    /// paper's last author (`sourceMatchesSearchAnalysingFields` spells the
    /// steps out).
    ///
    /// A search pass asks this of every source in the tab, and analysing a
    /// source's fields — ICU folding, a regex and the catenated fold of each —
    /// is what made a pass over a large library take a third of a second on
    /// the main thread (215 samples in build 210's stalls, 2026-10-11). So an
    /// unscoped query compares against each source's analysis, made once per
    /// change to its fields (`sidebarSearchAnalysis(of:)`), and the query is
    /// analysed once per pass (`sidebarSearchMatcher(for:)`). The steps and the
    /// strings compared are the same; only plain ASCII on both sides is
    /// compared as bytes, where a byte search finds exactly what
    /// `String.contains` finds. A field-scoped query (`title:`) reads one or two
    /// fields and is rare; it is analysed per source as before.
    func sourceMatchesSearch(_ article: StudioArticle, query: String) -> Bool {
        let matcher = sidebarSearchMatcher(for: query)
        guard matcher.parsed.field == nil else {
            return Self.sourceMatchesSearchAnalysingFields(article, query: query)
        }
        if matcher.normalizedQuery.value.isEmpty { return true }
        return matcher.matches(sidebarSearchAnalysis(of: article))
    }

    /// `sourceMatchesSearch` computed from scratch: every field normalized and
    /// folded on the spot. The scoped path, and what the analysed path must
    /// always agree with.
    nonisolated static func sourceMatchesSearchAnalysingFields(_ article: StudioArticle, query: String) -> Bool {
        let parsed = SidebarSearchQuery(parsing: query)
        let normalizedQuery = Self.normalizedSidebarSearchString(parsed.text)
        guard !normalizedQuery.isEmpty else { return true }

        let searchableFields = parsed.searchableValues(of: article)
            .map(Self.normalizedSidebarSearchString)
            .filter { !$0.isEmpty }

        if searchableFields.contains(where: { $0.contains(normalizedQuery) }) {
            return true
        }

        // "GDF15" and "GDF-15" are one term written two ways, and a learner types
        // whichever spelling they last read. Folding both sides the same way makes the
        // two directions symmetric — literal containment finds the hyphenated title
        // from a hyphenated query and never the reverse, because splitting "GDF-15"
        // leaves two fragments a bare title still contains while "GDF15" stays one.
        // Per field rather than over the joined text, so a match cannot straddle a
        // title's end and an author's start.
        let foldedQuery = Self.foldedSidebarSearchString(normalizedQuery)
        if !foldedQuery.isEmpty,
           searchableFields.contains(where: {
               Self.foldedSidebarSearchString($0).contains(foldedQuery)
           }) {
            return true
        }

        let queryTerms = Self.sidebarSearchTerms(in: normalizedQuery)
        guard !queryTerms.isEmpty else { return false }

        let searchableText = searchableFields.joined(separator: " ")
        if queryTerms.allSatisfy({ searchableText.contains($0) }) {
            return true
        }

        // Terms are already punctuation-free, so the same fold lets one term of a
        // longer query ("gdf15 biomarker") reach a hyphenated field.
        let foldedText = Self.foldedSidebarSearchString(searchableText)
        if queryTerms.allSatisfy({ foldedText.contains($0) }) {
            return true
        }

        // "torrens mas" finds the paper by its last author term. Only where the
        // author is in scope: a `title:` search must not reach the byline.
        if article.sourceType == .paper, queryTerms.count > 1,
           parsed.field == nil || parsed.field == .author,
           let author = article.author.map(Self.normalizedSidebarSearchString) {
            let authorTerms = Set(Self.sidebarSearchTerms(in: author))
            if let lastName = queryTerms.last, authorTerms.contains(lastName) {
                return true
            }
        }

        return false
    }

    /// A string a sidebar search compares, with whether it is plain ASCII.
    ///
    /// Between two plain-ASCII strings — no byte above 0x7F, no carriage
    /// return, so every character is one byte and one grapheme — a byte search
    /// (`memmem`) finds exactly what `String.contains` finds, at the speed of a
    /// scan rather than Foundation's grapheme-aware search. Anything else is
    /// compared by `String.contains` itself, so the answer never depends on
    /// which path ran.
    struct SidebarSearchText {
        let value: String
        let isPlainASCII: Bool

        init(_ value: String) {
            var contiguous = value
            contiguous.makeContiguousUTF8()
            self.value = contiguous
            isPlainASCII = contiguous.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
        }

        func contains(_ needle: SidebarSearchText) -> Bool {
            if isPlainASCII, needle.isPlainASCII,
               let found = Self.bytes(of: value, contain: needle.value) {
                return found
            }
            return value.contains(needle.value)
        }

        /// Nil when either side has no contiguous UTF-8 to scan.
        private static func bytes(of haystack: String, contain needle: String) -> Bool? {
            haystack.utf8.withContiguousStorageIfAvailable { hay -> Bool? in
                needle.utf8.withContiguousStorageIfAvailable { pin -> Bool in
                    // `String.contains` finds no empty string.
                    guard !pin.isEmpty, hay.count >= pin.count,
                          let hayStart = hay.baseAddress, let pinStart = pin.baseAddress else { return false }
                    return memmem(hayStart, hay.count, pinStart, pin.count) != nil
                }
            } ?? nil
        }
    }

    /// One source's fields as an unscoped sidebar search reads them, analysed
    /// once: the very strings `sourceMatchesSearchAnalysingFields` builds on
    /// every call, kept until one of the fields changes.
    struct SidebarSearchAnalysis {
        /// The fields the analysis was made from.
        let fields: ArtifactSourcePickerIndex.SourceFields
        /// Every field an unscoped search reads, normalized, empties dropped.
        let normalizedFields: [SidebarSearchText]
        /// Each of `normalizedFields` folded (`foldedSidebarSearchString`).
        let foldedFields: [SidebarSearchText]
        /// `normalizedFields` joined by spaces, and that folded.
        let text: SidebarSearchText
        let foldedText: SidebarSearchText
        /// A paper's author terms; nil for any other source and for a paper
        /// without an author.
        let authorTerms: Set<String>?

        init(_ fields: ArtifactSourcePickerIndex.SourceFields) {
            self.fields = fields
            let normalized = fields.values(in: SidebarSearchQuery(parsing: ""))
                .map(StudioViewModel.normalizedSidebarSearchString)
                .filter { !$0.isEmpty }
            normalizedFields = normalized.map(SidebarSearchText.init)
            foldedFields = normalized.map { SidebarSearchText(StudioViewModel.foldedSidebarSearchString($0)) }
            let joined = normalized.joined(separator: " ")
            text = SidebarSearchText(joined)
            foldedText = SidebarSearchText(StudioViewModel.foldedSidebarSearchString(joined))
            if fields.sourceType == .paper, let author = fields.author {
                authorTerms = Set(StudioViewModel.sidebarSearchTerms(
                    in: StudioViewModel.normalizedSidebarSearchString(author)
                ))
            } else {
                authorTerms = nil
            }
        }
    }

    /// A sidebar query analysed once for a whole pass.
    struct SidebarSearchMatcher {
        /// The query as the caller passed it, which is what the memo matches on.
        let query: String
        /// The locale the normalization folded under (`normalizedSidebarSearchString`).
        let localeIdentifier: String
        let parsed: SidebarSearchQuery
        let normalizedQuery: SidebarSearchText
        let foldedQuery: SidebarSearchText
        let terms: [SidebarSearchText]

        init(_ query: String, localeIdentifier: String) {
            self.query = query
            self.localeIdentifier = localeIdentifier
            parsed = SidebarSearchQuery(parsing: query)
            let normalized = StudioViewModel.normalizedSidebarSearchString(parsed.text)
            normalizedQuery = SidebarSearchText(normalized)
            foldedQuery = SidebarSearchText(StudioViewModel.foldedSidebarSearchString(normalized))
            terms = StudioViewModel.sidebarSearchTerms(in: normalized).map(SidebarSearchText.init)
        }

        /// `sourceMatchesSearchAnalysingFields` for an unscoped query, step for
        /// step, over a source's analysis. The caller has answered an empty
        /// query already.
        func matches(_ source: SidebarSearchAnalysis) -> Bool {
            if source.normalizedFields.contains(where: { $0.contains(normalizedQuery) }) {
                return true
            }
            if !foldedQuery.value.isEmpty,
               source.foldedFields.contains(where: { $0.contains(foldedQuery) }) {
                return true
            }
            guard !terms.isEmpty else { return false }
            if terms.allSatisfy({ source.text.contains($0) }) {
                return true
            }
            if terms.allSatisfy({ source.foldedText.contains($0) }) {
                return true
            }
            if let authorTerms = source.authorTerms, terms.count > 1,
               let lastName = terms.last, authorTerms.contains(lastName.value) {
                return true
            }
            return false
        }
    }

    /// The analysed query for `query`, kept while the same query is asked of
    /// source after source. A new query under a new locale drops every source
    /// analysis, since normalization folds under the current locale.
    func sidebarSearchMatcher(for query: String) -> SidebarSearchMatcher {
        if let memo = sidebarSearchMatcherMemo, memo.query == query {
            return memo
        }
        let localeIdentifier = Locale.current.identifier
        if sidebarSearchMatcherMemo?.localeIdentifier != localeIdentifier {
            sidebarSearchAnalyses.removeAll()
        } else if sidebarSearchAnalyses.count > articlesStore.articleIDs.count {
            // Sources removed since they were analysed.
            let held = articlesStore.articleIDs
            sidebarSearchAnalyses = sidebarSearchAnalyses.filter { held.contains($0.key) }
        }
        let matcher = SidebarSearchMatcher(query, localeIdentifier: localeIdentifier)
        sidebarSearchMatcherMemo = matcher
        return matcher
    }

    /// A source's analysis, made again only when a field it reads changed.
    func sidebarSearchAnalysis(of article: StudioArticle) -> SidebarSearchAnalysis {
        let fields = ArtifactSourcePickerIndex.SourceFields(article)
        if let known = sidebarSearchAnalyses[article.id], known.fields == fields {
            return known
        }
        let analysis = SidebarSearchAnalysis(fields)
        sidebarSearchAnalyses[article.id] = analysis
        return analysis
    }

    /// Every source address in a note, in document order.
    ///
    /// Two kinds share the scheme. `foreverlm://grounding/<id>,<id>` is a
    /// grounded passage: sources attached to the prose and invisible in it, which
    /// is why one address carries a list rather than a single id.
    /// `foreverlm://source/<id>` is the retired citation chip — a source the
    /// sentence named, drawn as a titled card. Nothing writes one now; a doc that
    /// still holds one is converted to grounding when the editor opens it, and
    /// until then it counts towards what the note stands on just the same.
    ///
    /// A regex is right here where it would be wrong over prose: these addresses
    /// are written by the editor, not by a person, so identity stays deterministic.
    private static func notepadSourceURLs(in markdown: String) -> [URL] {
        guard let expression = try? NSRegularExpression(
            pattern: #"foreverlm://(?:source|grounding)/[^\)\s\]]+"#
        ) else { return [] }

        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return expression.matches(in: markdown, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: markdown) else { return nil }
            return URL(string: String(markdown[matchRange]))
        }
    }

    /// Whether an address is a grounded passage rather than a titled chip.
    static func isNotepadGroundingURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "grounding"
    }

    /// What a grounded passage carries, in the order it was attached.
    ///
    /// Each entry is either a source id or `book:<book-id>`. A book is one thing a
    /// passage stands on, not thirty chapters, and writing the chapter list into
    /// the address would both bloat the doc and freeze the book as it was the day
    /// it was attached — the same reason a chip carries `?book=` rather than an
    /// expanded list. `expandedGroundingSourceIDs` resolves them against the
    /// library as it is now.
    static func notepadGroundingTokens(from url: URL) -> [String] {
        guard isNotepadGroundingURL(url) else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()
        for part in url.path.dropFirst().split(separator: ",", omittingEmptySubsequences: true) {
            let raw = String(part)
            let token = (raw.removingPercentEncoding ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            ordered.append(token)
        }
        return ordered
    }

    static let notepadGroundingBookPrefix = "book:"

    /// The grounding reference for one picker row: a book stands for its whole
    /// collection, anything else for itself.
    static func notepadGroundingToken(sourceID: String, bookID: String?) -> String {
        guard let bookID, !bookID.isEmpty else { return sourceID }
        return "\(notepadGroundingBookPrefix)\(bookID)"
    }

    /// Resolve grounding references into live source ids, dropping anything the
    /// library no longer holds. A book expands through its current chapters, so a
    /// chapter imported after the passage was written joins what it stands on.
    func expandedGroundingSourceIDs(_ tokens: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for token in tokens {
            let resolved: [String]
            if token.hasPrefix(Self.notepadGroundingBookPrefix) {
                let bookID = String(token.dropFirst(Self.notepadGroundingBookPrefix.count))
                resolved = sourceIDsForGroupInOrder(bookID)
            } else {
                resolved = [token]
            }
            for id in resolved where articlesById[id] != nil && seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    /// Resolve Notepad references into live source IDs. A book-level reference
    /// expands through the current book relationship, so later chapter imports
    /// join the context without rewriting the note.
    func sourceIDsReferencedByNotepadMarkdown(_ markdown: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for url in Self.notepadSourceURLs(in: markdown) {
            // A grounded passage names no source in the prose, but the note stands
            // on what is attached to it just as much as on what it cites, so both
            // reach the shelf and the chat context.
            if Self.isNotepadGroundingURL(url) {
                for id in expandedGroundingSourceIDs(Self.notepadGroundingTokens(from: url))
                where seen.insert(id).inserted {
                    ordered.append(id)
                }
                continue
            }
            guard let sourceID = ChatMarkdownView.sourceID(from: url) else { continue }
            let bookID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "book" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedIDs: [String]
            if let bookID, !bookID.isEmpty {
                let chapterIDs = sourceIDsForGroupInOrder(bookID)
                resolvedIDs = chapterIDs.isEmpty ? [sourceID] : chapterIDs
            } else {
                resolvedIDs = [sourceID]
            }
            for id in resolvedIDs where articlesById[id] != nil && seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    nonisolated static func normalizedSidebarSearchString(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// A normalized string with the punctuation inside each word closed up, so a term
    /// written both ways — "GDF15" and "GDF-15" — reduces to one spelling. Whitespace
    /// between words survives, so a query still cannot match across a boundary it never
    /// crossed.
    ///
    /// This is the analysis the full-text index side runs on the same text
    /// (`SourceSearchEngine.catenatedFold`), shared rather than reimplemented: one
    /// definition of "the same term" for the list filters and for retrieval, or a
    /// learner gets one answer when the term is in a title and another when it is only
    /// in a body. Searches consult it only after literal containment misses, so it
    /// widens what a query finds and never narrows it.
    nonisolated static func foldedSidebarSearchString(_ value: String) -> String {
        SourceSearchEngine.catenatedFold(value)
    }

    nonisolated static func sidebarSearchTerms(in value: String) -> [String] {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    struct FilteredPaperItemsCacheKey: Equatable {
        let filter: SidebarFilterCacheKey
        let library: PaperLibraryKey
    }

    func filteredPaperItems(hasPDF: Bool) -> [StudioArticle] {
        // Memoized per filter revision so the whole cluster of papers-tab
        // properties (active*/hasMore*/remaining*) shares one partition per
        // render. The library's share comes from `paperLibraryIndex`, so a
        // keystroke, a tab switch or Show More filters the window's rows and
        // never re-derives the whole library.
        let key = FilteredPaperItemsCacheKey(filter: currentSidebarFilterCacheKey, library: currentPaperLibraryKey)
        if sidebarStore.filteredPaperItemsCacheKey != key
            || sidebarStore.filteredPaperItemsWithPDFCache == nil
            || sidebarStore.filteredPaperItemsWithoutPDFCache == nil {
            let base = filteredActiveItems
            sidebarStore.filteredPaperItemsWithPDFCache = paperItems(hasPDF: true, in: base)
            sidebarStore.filteredPaperItemsWithoutPDFCache = paperItems(hasPDF: false, in: base)
            sidebarStore.filteredPaperItemsCacheKey = key
        }
        return hasPDF
            ? (sidebarStore.filteredPaperItemsWithPDFCache ?? [])
            : (sidebarStore.filteredPaperItemsWithoutPDFCache ?? [])
    }

    var filteredPaywalledPapersWithoutPDF: [StudioArticle] {
        papersPartition.paywalledWithoutPDF
    }

    /// Whole-catalog candidate set for the explicit paywall recheck command.
    /// This intentionally ignores the current search query and pagination: the
    /// command promises to revisit the catalog, not only the rows on screen. It
    /// uses recorded paths rather than statting iCloud-backed files, so clicking
    /// the action cannot block the main actor while CloudDocs downloads a file.
    var paywalledPapersEligibleForRecheck: [StudioArticle] {
        let processingIDs = processingPaperIDs
        return activeArticles.filter {
            $0.sourceType == .paper
                && $0.hasPaywallMarker
                && ($0.localFilePath ?? "").isEmpty
                && !isSourceHidden($0)
                && !processingIDs.contains($0.id)
                && $0.state != .fetching
                && $0.url.hasPrefix("http")
        }
    }

    var filteredPapersWithPDF: [StudioArticle] {
        papersPartition.withPDF
    }

    func paperItems(hasPDF: Bool, in papers: [StudioArticle]) -> [StudioArticle] {
        let unavailable = unavailableRecordedPaperPDFIDs
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        // Both whole-library sets come from `paperLibraryIndex`, built once per
        // library change rather than on every call.
        let library = paperLibraryIndex
        // A preprint whose journal version is held with its PDF is listed as
        // that version (`supersededPreprintIDs`); it stays in its notebooks.
        let superseded = library.superseded
        if hasPDF {
            return papers.filter { hasUsablePDF($0) && !superseded.contains($0.id) }
        }

        // Duplicate suppression is a library invariant, not a property of the
        // current search/filter result. A search can match an older discovery
        // record by stale author metadata while excluding the already-ingested
        // canonical copy. Building this set from `papers` made that old record
        // reappear as "PDF needed" even though the library already held the same
        // titled/identified paper and its PDF. Use the whole published library;
        // availability remains cache-only so this stays safe in SwiftUI renders.
        let paperKeysWithPDF = library.keysWithPDF
        return papers.filter { paper in
            guard !hasUsablePDF(paper), !superseded.contains(paper.id) else { return false }
            return paperKeysWithPDF.isDisjoint(with: cachedPaperDedupLookupKeys(for: paper))
        }
    }

    // MARK: - The library's share of the Papers lists

    /// What the whole library's share of the Papers lists is built from: the
    /// articles (their presentation revision, which moves on any change to a
    /// field a row or these sets read) and the cached PDF availability that
    /// `cachedHasUsablePDF` reads, which moves on its own when the background
    /// path warm finds a file arrived or gone.
    struct PaperLibraryKey: Equatable {
        let articlesRevision: Int
        let resolvedPathGeneration: Int
    }

    var currentPaperLibraryKey: PaperLibraryKey {
        PaperLibraryKey(
            articlesRevision: articlesRevision,
            resolvedPathGeneration: StudioArticle.resolvedPathCacheGeneration
        )
    }

    /// The two whole-library sets every Papers list consults: which preprints
    /// a journal version with its PDF stands in for, and the identity keys of
    /// every paper with a usable PDF. Neither depends on the window, its tab,
    /// its search or its page, so a keystroke, a tab switch or Show More reuses
    /// them; only a library change (`PaperLibraryKey`) rebuilds them.
    struct PaperLibraryIndex {
        let key: PaperLibraryKey
        let superseded: Set<String>
        let keysWithPDF: Set<String>
        /// The preprints the library holds a journal version of, PDF or not
        /// (`publishedVersion(ofPreprint:)` answers the same for one paper).
        let withPublishedVersion: Set<String>
    }

    /// Built on the main actor, as before, but from `paperListingFacts(for:)`,
    /// so a rebuild after one paper changed re-parses that paper alone. One
    /// copy serves every window.
    var paperLibraryIndex: PaperLibraryIndex {
        let key = currentPaperLibraryKey
        if let cached = paperLibraryIndexCache, cached.key == key {
            return cached
        }
        let unavailable = unavailableRecordedPaperPDFIDs
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        prunePaperListingFacts()
        let library = activeArticles
        let superseded = Self.supersededPreprintIDs(
            in: library,
            hasUsablePDF: hasUsablePDF,
            versionFacts: { self.paperListingFacts(for: $0).version }
        )
        var keysWithPDF = Set<String>()
        for paper in library where paper.sourceType == .paper && hasUsablePDF(paper) {
            keysWithPDF.formUnion(paperListingFacts(for: paper).dedupKeys)
        }
        let withPublishedVersion = Self.supersededPreprintIDs(
            in: library,
            hasUsablePDF: { _ in true },
            versionFacts: { self.paperListingFacts(for: $0).version }
        )
        let index = PaperLibraryIndex(
            key: key,
            superseded: superseded,
            keysWithPDF: keysWithPDF,
            withPublishedVersion: withPublishedVersion
        )
        paperLibraryIndexCache = index
        return index
    }

    /// The fields a paper's listing facts are read from: everything
    /// `paperVersionKind`, `paperDedupDisplayKeys` and the title checks they
    /// make read. Equal inputs mean the facts kept for the paper still hold.
    struct PaperListingInputs: Equatable {
        let sourceType: StudioSourceType
        let url: String
        let title: String
        let domain: String
        let doi: String?
        let publishedDOI: String?
        let journal: String?
        // What `isPaperReadyForListenPreparation` reads, for the content key.
        let state: StudioArticleState
        let author: String?
        let publishedYear: String?
        let paperIngestionMethod: PaperIngestionMethod?
        let paperContentSHA256: String?

        init(_ paper: StudioArticle) {
            sourceType = paper.sourceType
            url = paper.url
            title = paper.title
            domain = paper.domain
            doi = paper.doi
            publishedDOI = paper.publishedDOI
            journal = paper.journal
            state = paper.state
            author = paper.author
            publishedYear = paper.publishedYear
            paperIngestionMethod = paper.paperIngestionMethod
            paperContentSHA256 = paper.paperContentSHA256
        }
    }

    /// What the Papers lists read off one paper — its versions' facts and its
    /// identity keys (`paperDedupDisplayKeys`, `paperDedupLookupKeys`) — each a
    /// parse of its address, DOI and title.
    struct PaperListingFacts {
        let inputs: PaperListingInputs
        let version: PaperVersionFacts
        let dedupKeys: [String]
        let lookupKeys: [String]
    }

    /// One paper's listing facts, kept per source id and parsed again only
    /// when a field they come from changed.
    func paperListingFacts(for paper: StudioArticle) -> PaperListingFacts {
        let inputs = PaperListingInputs(paper)
        if let known = paperListingFactsByID[paper.id], known.inputs == inputs {
            return known
        }
        let facts = PaperListingFacts(
            inputs: inputs,
            version: PaperVersionFacts(paper),
            dedupKeys: Self.paperDedupDisplayKeys(for: paper),
            lookupKeys: Self.paperDedupLookupKeys(for: paper)
        )
        paperListingFactsByID[paper.id] = facts
        return facts
    }

    /// `paperDedupLookupKeys(for:)`, read from the kept facts. Only a paper
    /// has keys, so nothing else is kept.
    func cachedPaperDedupLookupKeys(for article: StudioArticle) -> [String] {
        guard article.sourceType == .paper else { return [] }
        return paperListingFacts(for: article).lookupKeys
    }

    /// Drops the facts of sources the library no longer holds.
    private func prunePaperListingFacts() {
        let held = articlesStore.articleIDs
        guard paperListingFactsByID.keys.contains(where: { !held.contains($0) }) else { return }
        paperListingFactsByID = paperListingFactsByID.filter { held.contains($0.key) }
    }

    /// Papers that `paperItems(hasPDF:)` suppresses as duplicates: no usable PDF
    /// of their own, but dedup keys matching a copy the library already holds
    /// with one.
    func suppressedDuplicatePaperIDs() -> [String] {
        let unavailable = unavailableRecordedPaperPDFIDs
        func hasUsablePDF(_ paper: StudioArticle) -> Bool {
            paper.cachedHasUsablePDF || unavailable.contains(paper.id)
        }
        let papers = activeArticles.filter { $0.sourceType == .paper }
        // Hiding is durable and synced, so a twin only counts inside its own
        // library: the learner's paper never hides a team's row for every
        // member (docs/teams-design.md, decision 19).
        var keysWithPDFByLibrary: [String?: Set<String>] = [:]
        for paper in papers where hasUsablePDF(paper) {
            keysWithPDFByLibrary[paper.teamID, default: []].formUnion(Self.paperDedupDisplayKeys(for: paper))
        }
        guard !keysWithPDFByLibrary.isEmpty else { return [] }
        return papers.filter { paper in
            guard !hasUsablePDF(paper), !isSourceHidden(paper),
                  let keysWithPDF = keysWithPDFByLibrary[paper.teamID] else { return false }
            return !keysWithPDF.isDisjoint(with: Self.paperDedupLookupKeys(for: paper))
        }.map(\.id)
    }

    /// Resolve those duplicates once per launch instead of filtering them forever.
    ///
    /// Suppressing them is right as a display rule and wrong as the whole story.
    /// The row stays active, counted, embedded, and reachable by search while
    /// being invisible in every Papers partition at once: having no PDF keeps it
    /// out of the main list, and the suppression keeps it out of the attention
    /// list. Four papers sat in exactly that gap — no surface that could show
    /// them, no action that could clear them, and no count that revealed them.
    ///
    /// Hiding is the same decision made durable: reversible, still searchable,
    /// visible under the hidden filter, and synced. Only rows the suppression had
    /// already made invisible are touched, so this can never hide a paper the
    /// learner can currently see.
    func resolveSuppressedDuplicatePapers() async {
        guard !didResolveSuppressedDuplicatePapers else { return }
        didResolveSuppressedDuplicatePapers = true
        let ids = suppressedDuplicatePaperIDs()
        guard !ids.isEmpty else { return }
        for id in ids {
            do {
                try await storage.setSourceHidden(id, hidden: true)
                if let idx = articles.firstIndex(where: { $0.id == id }) {
                    articles[idx].isHidden = true
                }
            } catch {
                logger.error("Could not hide duplicate paper \(id): \(error.localizedDescription)")
            }
        }
        logger.info("Hid \(ids.count) duplicate papers the sidebar was suppressing")
    }

    /// Minimum number of recorded-but-unstattable PDFs before the library is
    /// treated as storage-degraded rather than individually stale.
    nonisolated static let unavailableRecordedPDFFloor = 10

    /// IDs of papers whose PDF the library has on record (`localFilePath` set)
    /// but whose file does not currently stat on disk — ONLY when that is true
    /// for so many papers at once that the cause must be storage-level, not
    /// per-paper. A single missing file means a stale path and the paper should
    /// re-enter the needs-attention flows (that semantic is deliberate — see
    /// `resolvedPDFPath`). Hundreds going missing simultaneously means the
    /// files' storage is unavailable: iCloud Drive rebuilding its local replica
    /// after an OS upgrade, files not yet synced to a fresh Mac, or the content
    /// root resolving to the local fallback. Re-downloading from publishers is
    /// the wrong remedy for every one of those, so above the threshold
    /// (≥ `unavailableRecordedPDFFloor` and ≥ 25% of recorded PDFs) these papers
    /// are excluded from attention, the badge, auto-fetch, and bulk downloads,
    /// and surfaced in the sidebar as waiting for their files instead. Below the
    /// threshold this returns the empty set and behavior is unchanged.
    /// `nonisolated` so the stat-heavy scan can run off the main actor over a
    /// snapshot; stats are memoized per unique path per session.
    nonisolated static func unavailableRecordedPaperPDFIDs(in articles: [StudioArticle]) -> Set<String> {
        unavailableRecordedPaperPDFIDs(in: articles) { $0.resolvedPDFPath != nil }
    }

    /// Cache-only form for SwiftUI-derived state. Unknown recorded paths count as
    /// available until the off-main warm establishes their real state, so view
    /// evaluation never performs an iCloud-backed stat or flashes a false outage.
    nonisolated static func cachedUnavailableRecordedPaperPDFIDs(in articles: [StudioArticle]) -> Set<String> {
        unavailableRecordedPaperPDFIDs(in: articles) { $0.cachedHasUsablePDF }
    }

    nonisolated private static func unavailableRecordedPaperPDFIDs(
        in articles: [StudioArticle],
        isAvailable: (StudioArticle) -> Bool
    ) -> Set<String> {
        let recorded = articles.filter {
            $0.sourceType == .paper && !($0.localFilePath ?? "").isEmpty
        }
        let missing = recorded.filter { !isAvailable($0) }
        guard missing.count >= unavailableRecordedPDFFloor,
              missing.count * 4 >= recorded.count else { return [] }
        return Set(missing.map(\.id))
    }

    /// `unavailableRecordedPaperPDFIDs` over the whole active library, memoized
    /// on what it reads: the articles and the cached path availability
    /// (`PaperLibraryKey`). The threshold is a property of the library, not of
    /// whatever subset a view is rendering, so every consumer — in every window —
    /// shares this whole-library answer.
    var unavailableRecordedPaperPDFIDs: Set<String> {
        let key = currentPaperLibraryKey
        if let cached = paperLibraryUnavailableCache, cached.key == key {
            return cached.ids
        }
        let ids = Self.cachedUnavailableRecordedPaperPDFIDs(in: activeArticles)
        paperLibraryUnavailableCache = (key, ids)
        return ids
    }

    /// Whether a source with this normalized URL (`SourceDiscovery.normalizedURL`)
    /// is in the library. One set lookup, against a table built once per
    /// articles revision.
    ///
    /// The chat's web sources footer used to answer this by scanning
    /// `articles` and normalizing every source's URL for each citation it drew,
    /// inside its SwiftUI body. Normalizing a stored file path walks the
    /// content roots, and a lazy transcript rebuilds the row every time it
    /// scrolls back into view, so on 2026-09-07 one reply with web sources over
    /// a large library turned each scroll into a second of main-thread work
    /// (the `ui-stall-2026-09-07T20-19-03` sample). The library changes rarely
    /// next to how often a row is built, so the normalization runs per revision
    /// and the row pays a hash.
    func libraryContainsSource(normalizedURL key: String) -> Bool {
        libraryIdentityKeys[key] != nil
    }

    /// Whether the page a web citation names is in the library, by address or
    /// by the paper it is. A paper is often saved under a different address
    /// than the one a web search cites — its DOI link, its PDF, a publisher
    /// page reached through a recommendation link — so the address alone said
    /// "not saved" for papers that were. The DOI the citation carries (a
    /// doi.org link, a Nature article id, a `/doi/` path, an arXiv id) is
    /// matched against every saved paper's DOI, the identity rule the Doc
    /// reference cards already apply in `activeSourceID(forReferenceURL:)`.
    func libraryContainsSource(url: String) -> Bool {
        librarySourceID(forURL: url) != nil
    }

    /// The library source a web address names, or nil when the page is not in
    /// the library. Three ways an address can name a saved source, tried in
    /// order: the address itself, the DOI written in the address, and the DOI
    /// the page declared about itself once it was loaded
    /// (`notePageDeclaredIdentity`). The third is what identifies an index
    /// page — PubMed, PMC, Semantic Scholar — whose address carries only its
    /// own record number: on 2026-09-20 a chat linked the MitoSpace paper by
    /// its PubMed page, the library held it under its Cell address, and the
    /// Reader offered Add to Sources for a paper already saved.
    func librarySourceID(forURL url: String) -> String? {
        let table = libraryIdentityKeys
        let pageKey = SourceDiscovery.normalizedURL(url)
        if let id = table[pageKey] { return id }
        if let doi = PaperService.extractDOI(from: url) ?? pageDeclaredDOIs[pageKey],
           let id = table[Self.libraryDOIKey(doi)] {
            return id
        }
        return nil
    }

    /// A page finished loading in a Reader or Browser web view and its head
    /// says which paper it is (`citation_doi`, `dc.identifier`, a DOI link).
    /// Recorded under every address the page was reached by — the one asked
    /// for and the one that answered, when a redirect made them differ — so
    /// the toolbar over that page, and a chat link to that address, can find
    /// the saved copy. The head is scanned off the main actor; a page that
    /// declares no DOI leaves no record, and a redeclaration replaces the old.
    func notePageDeclaredIdentity(pageURLs: [URL], headHTML: String) async {
        let keys = Set(pageURLs.compactMap { url -> String? in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return SourceDiscovery.normalizedURL(url.absoluteString)
        })
        guard !keys.isEmpty, !headHTML.isEmpty else { return }
        let finalURL = pageURLs.first?.absoluteString
        let doi = await Task.detached(priority: .utility) {
            PaperService.extractPaperPageMetadata(from: headHTML, url: finalURL)?.doi
        }.value
        guard let doi, !doi.isEmpty else { return }
        for key in keys where pageDeclaredDOIs[key] != doi {
            pageDeclaredDOIs[key] = doi
        }
    }

    /// Every library source's normalized URL plus, for every paper with a DOI,
    /// its `doi:` key — each mapped to the source's id — built once per
    /// articles revision. A preprint's published DOI is not a key: the journal
    /// version is its own paper (`paperDedupDisplayKeys`).
    private var libraryIdentityKeys: [String: String] {
        let revision = articlesRevision
        if sidebarStore.libraryURLKeysCacheKey == revision,
           let cached = sidebarStore.libraryURLKeysCache {
            return cached
        }
        var keys: [String: String] = [:]
        keys.reserveCapacity(articles.count * 2)
        for article in articles {
            let urlKey = SourceDiscovery.normalizedURL(article.url)
            if keys[urlKey] == nil { keys[urlKey] = article.id }
            guard article.sourceType == .paper else { continue }
            if let doi = article.doi ?? PaperService.extractDOI(from: article.url) {
                let doiKey = Self.libraryDOIKey(doi)
                if keys[doiKey] == nil { keys[doiKey] = article.id }
            }
        }
        // A saved preprint's resolved published DOI is deliberately not a key
        // here: the journal version is its own paper, and a link to it must
        // offer Add to Sources rather than answer as the preprint already held.
        sidebarStore.libraryURLKeysCache = keys
        sidebarStore.libraryURLKeysCacheKey = revision
        sidebarStore.libraryURLKeysBuilds &+= 1
        return keys
    }

    /// The key a DOI takes in `libraryIdentityKeys`: the same `doi:` namespace
    /// and normalization as the paper dedup keys, so a preprint's version
    /// suffix and a publisher's letter case never split one paper in two.
    private static func libraryDOIKey(_ doi: String) -> String {
        "doi:\(normalizeDOI(doi))"
    }

    /// Count for the Papers-tab "waiting for iCloud" indicator. Non-zero only
    /// while the storage-degraded threshold is tripped.
    var unavailableRecordedPDFCount: Int {
        unavailableRecordedPaperPDFIDs.count
    }

    /// PDF availability exactly as the paper partitions see it, for the row's own
    /// status label and recovery button.
    ///
    /// A row must not answer this from `cachedHasUsablePDF` alone. While the
    /// library is storage-degraded — a fresh Mac whose files have not arrived
    /// yet — every recorded PDF counts as present, and a row that disagreed
    /// labelled a paper "PDF needed" that the attention list had actually
    /// surfaced for its missing metadata attestation, then offered "Choose PDF"
    /// as the fix for a file sitting on the other Mac.
    func displayHasUsablePDF(_ article: StudioArticle) -> Bool {
        article.cachedHasUsablePDF || unavailableRecordedPaperPDFIDs.contains(article.id)
    }

    /// Dedup keys of every paper in `articles` that already has a resolved PDF,
    /// or whose recorded PDF is temporarily unavailable at storage level.
    /// A no-PDF paper whose keys intersect this set is a duplicate of one we
    /// already have and is hidden from the visible "needs attention" list by
    /// `paperItems(hasPDF:)`. Auto-fetch reuses this so it never counts or tries
    /// to download a paper the user can't see in that list. `nonisolated` so the
    /// stat-heavy `resolvedPDFPath` scan runs off the main actor over a snapshot.
    nonisolated static func paperDedupKeysForPapersWithPDF(in articles: [StudioArticle]) -> Set<String> {
        let unavailable = unavailableRecordedPaperPDFIDs(in: articles)
        return Set(
            articles
                .filter { $0.sourceType == .paper && ($0.resolvedPDFPath != nil || unavailable.contains($0.id)) }
                .flatMap { paperDedupDisplayKeys(for: $0) }
        )
    }

    /// Where a paper stands among its own versions: the preprint a server
    /// posted, the journal's version of record, or a paper that says neither.
    enum PaperVersionKind: Sendable {
        case preprint
        case journal
        case unknown
    }

    /// A paper's place among its versions, from what the row already records. A
    /// resolved published DOI (that is not its own) says the paper is a preprint
    /// that was published; so do a preprint server's address, venue and DOI
    /// prefix. A journal DOI or a real journal name says the version of record.
    nonisolated static func paperVersionKind(of article: StudioArticle) -> PaperVersionKind {
        guard article.sourceType == .paper else { return .unknown }
        let ownDOI = (article.doi ?? PaperService.extractDOI(from: article.url)).map(normalizeDOI)
        if let published = article.publishedDOI?.trimmingCharacters(in: .whitespacesAndNewlines),
           !published.isEmpty, normalizeDOI(published) != ownDOI {
            return .preprint
        }
        if PaperService.isPreprintPaper(url: article.url, journal: article.journal) { return .preprint }
        if let ownDOI {
            return PaperService.isPreprintDOI(ownDOI) ? .preprint : .journal
        }
        if let journal = article.normalizedJournal, journal != StudioArticle.unknownPaperJournal {
            return .journal
        }
        return .unknown
    }

    /// The keys under which two paper rows are one paper.
    ///
    /// A preprint and its journal version are two versions of one work, not one
    /// paper twice: each stays its own row, with the notebooks, highlights and
    /// chats made against its own text. So they share no key — the published DOI
    /// resolved for a preprint is a link between the rows, not an identity, and
    /// the title key is split by version so a preprint never meets the journal
    /// record. A paper that says neither (no journal, no DOI) meets both, as it
    /// always did.
    ///
    /// A title is evidence only while the DOIs do not contradict it. Two papers
    /// with different DOIs are two papers whatever they are called: a Nature
    /// Reviews Methods Primer and its one-page PrimeView share their title
    /// exactly, and the title key once archived the Primer as the PrimeView's
    /// duplicate. So the title keys are asymmetric: these are the keys a paper
    /// is found by, and `paperDedupLookupKeys(for:)` the keys it looks for. A
    /// paper with a DOI is found under `doi:<its DOI>` and `any`, and looks under
    /// `doi:<its DOI>` and `nodoi`; a paper without one is found under `nodoi`
    /// and `any`, and looks under `any`. Same DOI, or a DOI on one side only,
    /// meets; two different DOIs never do. Compare two papers with
    /// `paperDedupKeysMatch`, never by intersecting these keys with each other.
    nonisolated static func paperDedupDisplayKeys(for article: StudioArticle) -> [String] {
        paperIdentityKeys(for: article, lookingUp: false)
    }

    /// The keys a paper looks for among other papers' `paperDedupDisplayKeys`.
    nonisolated static func paperDedupLookupKeys(for article: StudioArticle) -> [String] {
        paperIdentityKeys(for: article, lookingUp: true)
    }

    /// Whether two paper rows are one paper by a deterministic identity key.
    /// Symmetric: the title keys' asymmetry cancels out across the pair.
    nonisolated static func paperDedupKeysMatch(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        !Set(paperDedupLookupKeys(for: lhs)).isDisjoint(with: paperDedupDisplayKeys(for: rhs))
    }

    /// A paper's DOI for identity, from its record or its address, normalized.
    nonisolated static func paperIdentityDOI(of article: StudioArticle) -> String? {
        let recorded = article.doi?.trimmingCharacters(in: .whitespacesAndNewlines)
        let doi = recorded?.isEmpty == false ? recorded : PaperService.extractDOI(from: article.url)
        return doi.map(normalizeDOI).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Two papers whose DOIs are both known and differ are two papers, whatever
    /// their titles say. Title-based matching everywhere asks this first.
    nonisolated static func paperDOIsContradict(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return normalizeDOI(lhs) != normalizeDOI(rhs)
    }

    private nonisolated static func paperIdentityKeys(for article: StudioArticle, lookingUp: Bool) -> [String] {
        guard article.sourceType == .paper else { return [] }
        var keys: [String] = []
        let doi = paperIdentityDOI(of: article)
        if let doi {
            keys.append("doi:\(doi)")
        }
        if let publisherKey = paperPublisherIdentityKey(for: article.url) {
            keys.append(publisherKey)
        }
        if article.isPaperReadyForListenPreparation,
           let contentSHA256 = article.paperContentSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contentSHA256.isEmpty {
            keys.append("content-sha256:\(contentSHA256.lowercased())")
        }
        let normalizedTitle = normalizedPaperTitle(article.title)
        if !normalizedTitle.isEmpty,
           !titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
            let versions: [String]
            switch paperVersionKind(of: article) {
            case .preprint: versions = ["preprint"]
            case .journal: versions = ["journal"]
            case .unknown: versions = ["preprint", "journal"]
            }
            let doiTags: [String]
            switch (doi, lookingUp) {
            case (let doi?, false): doiTags = ["doi:\(doi)", "any"]
            case (let doi?, true): doiTags = ["doi:\(doi)", "nodoi"]
            case (nil, false): doiTags = ["nodoi", "any"]
            case (nil, true): doiTags = ["any"]
            }
            for version in versions {
                for doiTag in doiTags {
                    keys.append("title:\(normalizedTitle)#\(version)#\(doiTag)")
                }
            }
        }
        return keys
    }

    func comparePodcastArticles(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        switch podcastSortMode {
        case .date:
            if lhs.dateAdded != rhs.dateAdded {
                return lhs.dateAdded > rhs.dateAdded
            }
            if lhs.domain != rhs.domain {
                return lhs.domain.localizedStandardCompare(rhs.domain) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .channel:
            if lhs.domain != rhs.domain {
                return lhs.domain.localizedStandardCompare(rhs.domain) == .orderedAscending
            }
            if lhs.dateAdded != rhs.dateAdded {
                return lhs.dateAdded > rhs.dateAdded
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Order the Videos tab. Rows missing the selected date sink to the bottom
    /// rather than being interleaved at the epoch: Safari-discovered videos
    /// never carry Liked-feed dates, and liked rows only gain them once the
    /// feed has re-synced since these columns shipped.
    func compareVideoArticles(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        switch videoSortMode {
        case .liked:
            // Prefer the real liked timestamp, but fall back to the playlist
            // position, which encodes the same order for rows fetched before
            // `liked_at` existed. Mixing the two is safe because both are
            // most-recently-liked-first.
            if let a = lhs.likedAt, let b = rhs.likedAt, a != b {
                return a > b
            }
            if let a = lhs.courseSortIndex, let b = rhs.courseSortIndex, a != b {
                return a < b
            }
            if (lhs.courseSortIndex != nil) != (rhs.courseSortIndex != nil) {
                return lhs.courseSortIndex != nil
            }
            return lhs.dateAdded > rhs.dateAdded
        case .published:
            if let a = lhs.videoPublishedAt, let b = rhs.videoPublishedAt, a != b {
                return a > b
            }
            if (lhs.videoPublishedAt != nil) != (rhs.videoPublishedAt != nil) {
                return lhs.videoPublishedAt != nil
            }
            return lhs.dateAdded > rhs.dateAdded
        }
    }

    /// Show more items in the sidebar
    func showMore() {
        displayLimit += 40
    }

    func showMorePapersWithPDF() {
        papersWithPDFDisplayLimit += 40
    }

    func showMorePapersWithoutPDF() {
        papersWithoutPDFDisplayLimit += 40
    }

    func showMorePaywalledPapersWithoutPDF() {
        paywalledPapersDisplayLimit += 40
    }

    func resetDisplayLimits() {
        displayLimit = 40
        papersWithPDFDisplayLimit = 40
        papersWithoutPDFDisplayLimit = 40
        paywalledPapersDisplayLimit = 40
    }

    func schedulePodcastCatalogSearchForCurrentQuery() {
        podcastCatalogSearchTask?.cancel()
        guard sidebarTab == .podcasts else { return }

        // Apple's catalog is searched by episode title, so a title-scoped query
        // still reaches it; a search scoped to any other field stays in the library.
        let parsed = sidebarSearchQuery
        guard parsed.field == nil || parsed.field == .title else { return }
        let query = parsed.text
        guard query.count >= 3 else { return }

        podcastCatalogSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.materializeApplePodcastCatalogMatches(for: query)
        }
    }

    func materializeApplePodcastCatalogMatches(for rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sidebarTab == .podcasts,
              query == sidebarSearchQuery.text,
              query.count >= 3 else { return }

        let dbPath = (realHomeDirectory as NSString).appendingPathComponent(
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
        )
        // The multi-LIKE scan over Apple's Podcasts SQLite library is ~600ms;
        // run it off the main actor so each keystroke doesn't beachball the sidebar.
        let (matches, status) = await Task.detached(priority: .userInitiated) {
            SourceDiscovery.searchPodcastCatalogEpisodes(dbPath: dbPath, query: query, limit: 25)
        }.value
        // Back on the main actor: the query is stale if the user kept typing or left the tab.
        guard sidebarTab == .podcasts,
              query == sidebarSearchQuery.text,
              status == .ok, !matches.isEmpty else { return }

        let existingURLs = Set(articles.map { SourceDiscovery.normalizedURL($0.url) })
        let existingPodcastTitles = Set(articles.filter { $0.sourceType == .podcast }.map(\.title))
        var imported: [StudioArticle] = []

        for meta in matches {
            guard let url = SourceDiscovery.podcastEpisodeURL(for: meta) else { continue }
            let normalizedURL = SourceDiscovery.normalizedURL(url)
            guard !existingURLs.contains(normalizedURL),
                  !existingPodcastTitles.contains(meta.episodeTitle),
                  !imported.contains(where: { SourceDiscovery.normalizedURL($0.url) == normalizedURL || $0.title == meta.episodeTitle }) else {
                continue
            }

            var article = StudioArticle(
                url: url,
                title: meta.episodeTitle,
                sourceType: .podcast,
                artworkURL: meta.artworkURL,
                discoveryOrigin: .applePodcasts
            )
            article.normalizedURL = normalizedURL
            article.domain = meta.podcastName
            article.dateAdded = meta.lastDatePlayed ?? Date()
            article.podcastWebPageURL = meta.storeTrackId == nil ? nil : meta.webPageURL
            article.state = .queued

            do {
                try await storage.saveSource(article)
                imported.append(article)
            } catch {
                logger.error("Failed to save Apple Podcasts catalog match: \(error.localizedDescription)")
            }
        }

        guard !imported.isEmpty else { return }
        let previousArticles = articles
        articles = preservingLoadedContent(in: previousArticles + imported, preservingFrom: previousArticles)
        resetDisplayLimits()
        let importedIDs = imported.map(\.id)
        Task { [weak self] in
            await self?.fetchPodcastTranscriptsConcurrently(for: importedIDs)
        }
    }

    /// Reset search and pagination when switching tabs
    func switchTab(to tab: StudioSidebarTab) {
        sidebarTab = tab
        searchText = ""
        podcastCatalogSearchTask?.cancel()
        sourceSearchQuery = ""
        sourceSearchResults = []
        readerSearchBestMatches = [:]
        hasSearchedSources = false
        articleOriginFilter = nil
        clearSourceListFilters()
        resetDisplayLimits()
        // Whatever the reader holds open stays open. A tab is a filter over the sources list,
        // not a statement about what is being read: adding a cited paper switches to Papers
        // on its own, and closing the video that cited it would be the opposite of the point.
        // Pruning re-marks the open source when it does belong to the tab being opened.
        pruneSelectionToVisibleSources()
        // Opening a plugin tab is an explicit freshness event. The helper is
        // silent, startup-gated, and cooldown-limited, so tab switches never add
        // polling or block the UI.
        syncTabPluginsOnEvent(tab)
    }

    /// Whether `tab` may leave the tab bar: the bar keeps at least one pinned
    /// source type, so the last one stays put. The Customize list, the tab's
    /// context menu and the Settings switch all read this so they agree.
    func canUnpinTab(_ tab: StudioSidebarTab) -> Bool {
        hiddenTabs.contains(tab) || visibleTabs.count > 1
    }

    /// Hide a tab from the sidebar
    func hideTab(_ tab: StudioSidebarTab) {
        guard canUnpinTab(tab) else { return }
        hiddenTabs.insert(tab)
        // An unpin the learner performed is theirs to keep: Studio must not pin
        // this integration tab back the next time it sees a source arrive.
        autoUnpinnedIntegrationTabs.remove(tab)
        // Hidden tabs are app-wide, but each window has its own tab: any
        // window still showing this one moves to the first visible tab.
        guard let first = visibleTabs.first else { return }
        for state in allWindowStates where state.sidebarStore.sidebarTab == tab {
            inWindow(state) { switchTab(to: first) }
        }
    }

    /// Show a previously hidden tab
    func showTab(_ tab: StudioSidebarTab) {
        hiddenTabs.remove(tab)
        autoUnpinnedIntegrationTabs.remove(tab)
    }

    /// Pin an integration tab as soon as the library shows the integration is in
    /// use — the account is connected, or a source of that family exists. This is
    /// the other half of `applyIntegrationTabUnpinDefaults()`: a tab kept off a
    /// new learner's tab bar has to appear the moment they sign into Google
    /// Drive, or its sources would land somewhere invisible.
    ///
    /// Plugin-pushed sources are deliberately exempt from the source-arrival
    /// half. Zoom and Slack content is pushed by a plugin rather than asked
    /// for, so arriving content is no evidence the learner wants the tab — and
    /// pinning on arrival is what put all three back on the tab bar every time
    /// the pin state was lost. Signing an account in is the learner's own
    /// action, so Meetings and X still pin on that.
    ///
    /// Meetings needs that exemption applied per *session* rather than per tab.
    /// It is no longer plugin-backed as a whole — Drive sign-in and folder
    /// imports are the learner's own actions and should pin it — so exempting
    /// the whole tab would stop those from ever pinning, while exempting none
    /// of it would let a Read AI push pin a tab the learner never asked for.
    ///
    /// Only tabs Studio unpinned on its own are eligible, and `showTab` drops
    /// each one it pins, so this runs at most once per tab and never fights a
    /// later unpin. Cheap to call on every source-list change: it exits on an
    /// empty set, and the scan stops as soon as the remaining families are found.
    func pinIntegrationTabsInUse() {
        var pending = autoUnpinnedIntegrationTabs.intersection(hiddenTabs)
        guard !pending.isEmpty else { return }

        if pending.contains(.meetings), GoogleDriveService.shared.isSignedIn {
            pending.remove(.meetings)
            showTab(.meetings)
        }
        if pending.contains(.xPosts), isXOAuthSignedIn {
            pending.remove(.xPosts)
            showTab(.xPosts)
        }
        pending.subtract(StudioSidebarTab.allCases.filter(\.isPluginBacked))
        guard !pending.isEmpty else { return }

        for article in articles {
            guard let tab = StudioSidebarTab.knowledgeTab(for: article),
                  Self.sourceArrivalPinsTab(tab, discoveryOrigin: article.discoveryOrigin) else { continue }
            guard pending.remove(tab) != nil else { continue }
            showTab(tab)
            if pending.isEmpty { break }
        }
    }

    /// Whether one source arriving is evidence the learner wants its tab pinned.
    ///
    /// Plugin-pushed content is not: it arrives without being asked for, and
    /// pinning on arrival is what put Read AI and Slack back on the tab bar
    /// after every rebuild.
    ///
    /// Meetings needs that judgment per *session* rather than per tab, which is
    /// why this is a function of origin and not just of `isPluginBacked`. The
    /// tab is fed by Google Drive sign-in, folder imports and pasted Zoom links
    /// — the learner's own actions, which should pin it — as well as by Read
    /// AI's plugin, which should not. Exempting the whole tab would break the
    /// first three; exempting none of it would break the fourth.
    nonisolated static func sourceArrivalPinsTab(
        _ tab: StudioSidebarTab,
        discoveryOrigin: DiscoveryOrigin?
    ) -> Bool {
        if tab.isPluginBacked { return false }
        if tab == .meetings { return MeetingProvider.forOrigin(discoveryOrigin) != .readAI }
        return true
    }

    /// Total count for the current sidebar tab.
    var tabTotalCount: Int {
        return activeArticles.filter { matchesCurrentTab($0) }.count
    }

    /// Label for the current tab
    var tabItemLabel: String {
        sidebarTab.itemNoun
    }

    /// Per-browser breakdown of active reading list items (articles tab only).
    var readingListOriginCounts: [(origin: DiscoveryOrigin, count: Int)] {
        let safariEnabled = DefaultsEscapeHatch.bool(forKey: "readingListSafari", default: true)
        let chromeEnabled = DefaultsEscapeHatch.bool(forKey: "readingListChrome", default: true)
        let braveEnabled = DefaultsEscapeHatch.bool(forKey: "readingListBrave", default: true)
        let key = ReadingListOriginCountsCacheKey(
            tab: sidebarTab,
            articlesRevision: articlesRevision,
            safariEnabled: safariEnabled,
            chromeEnabled: chromeEnabled,
            braveEnabled: braveEnabled
        )
        if let cached = sidebarStore.readingListOriginCountsCache,
           sidebarStore.readingListOriginCountsCacheKey == key {
            return cached
        }
        let computed = computeReadingListOriginCounts(
            safariEnabled: safariEnabled,
            chromeEnabled: chromeEnabled,
            braveEnabled: braveEnabled
        )
        sidebarStore.readingListOriginCountsCache = computed
        sidebarStore.readingListOriginCountsCacheKey = key
        return computed
    }

    private func computeReadingListOriginCounts(
        safariEnabled: Bool,
        chromeEnabled: Bool,
        braveEnabled: Bool
    ) -> [(origin: DiscoveryOrigin, count: Int)] {
        // Compute counts from tab items WITHOUT the origin filter applied,
        // so all origins remain visible in the header even when one is selected.
        // Respect disabled browser sources so their chips don't appear.
        let tabItems = activeArticles
            .filter { matchesCurrentTab($0) }
            .filter { article in
                switch article.discoveryOrigin {
                case .safari: return safariEnabled
                case .chrome: return chromeEnabled
                case .brave: return braveEnabled
                default: return true
                }
            }
        var counts: [DiscoveryOrigin: Int] = [:]
        for article in tabItems {
            let origin = article.discoveryOrigin ?? .manual
            counts[origin, default: 0] += 1
        }
        let order: [DiscoveryOrigin] = [.safari, .chrome, .brave, .xBookmarks, .manual]
        return order.compactMap { origin in
            guard let count = counts[origin], count > 0 else { return nil }
            return (origin, count)
        }
    }

    /// The explainer written about a source, when the library has one — the
    /// article-typed row whose URL names this source (explainer-design.md).
    /// The source's context menu reads this to offer Open Explainer, so it
    /// registers the article-list dependency the way `articlesById` does.
    func explainer(explaining sourceID: String) -> StudioArticle? {
        _ = articlesStore.revision
        guard let explainerID = articlesStore.explainerIDsByExplainedSourceID[sourceID] else { return nil }
        return articlesStore.articlesById[explainerID]
    }

    /// The source an explainer explains, when both are in the library.
    func explainedSource(of article: StudioArticle) -> StudioArticle? {
        guard let explainedID = GeneratedExplainer.explainedSourceID(from: article.url) else { return nil }
        return articlesById[explainedID]
    }

    /// The tab whose list carries a row for the source: its own tab, or for an
    /// explainer the tab of the source it is folded under. Nil when no tab
    /// lists it (an explainer whose source is gone, a type with no tab).
    func sidebarTab(listing article: StudioArticle) -> StudioSidebarTab? {
        let listed = explainedSource(of: article) ?? article
        guard !GeneratedExplainer.isSpokenScriptURL(listed.url) else { return nil }
        return StudioSidebarTab.allCases.first { sourceBelongsToTab(listed, tab: $0) }
    }

    func matchesCurrentTab(_ article: StudioArticle) -> Bool {
        guard !isSourceHidden(article) else { return false }
        // Screen record mode lists only the recording Notebook's sources and
        // safe public captures from the take (`ScreenRecordScope`). Every tab, its
        // count and the sidebar search come through here.
        guard isVisibleInRecordingMode(article) else { return false }
        // An explainer never has a row of its own: it is reached from the
        // source it explains (its Explain button and context menu), in
        // whichever tab that source lives. See `explainer(explaining:)`. Nor
        // does an audio overview's carrier: it is reached from its notebook.
        guard !GeneratedExplainer.isSpokenScriptURL(article.url) else { return false }
        switch sidebarTab {
        case .articles: return article.sourceType == .article || article.sourceType == .manual || article.sourceType == .unclassified
        case .papers:   return article.sourceType == .paper
        case .books:
            guard article.sourceType == .book else { return false }
            if let kind = selectedBookKind {
                let articleKind = article.parentGroup.flatMap { bookKinds[$0] }
                return articleKind == kind
            }
            return true
        case .meetings:
            guard article.sourceType == .meeting,
                  let groupName = article.parentGroup,
                  !(meetingMetadata[groupName]?.isHidden ?? false) else { return false }
            guard let provider = meetingProviderFilter else { return true }
            return MeetingProvider.forOrigin(article.discoveryOrigin) == provider
        case .podcasts:
            return article.sourceType == .podcast
        case .videos:
            // Zoom recordings are meetings; the URL check keeps one synced from
            // an older build out of YouTube. See `knowledgeTab`.
            // An explainer film ForeverLM made lives under Videos in the rail,
            // not among the YouTube library.
            guard article.sourceType == .video,
                  !ZoomRecordingService.isZoomRecordingURL(article.url),
                  !GeneratedExplainerVideo.isVideoURL(article.url) else { return false }
            // A course's lecture videos are listed here like any other
            // video (product owner, 2026-09-27: "show videos in both places"); the
            // course's page lists them too (courses-design.md).
            if let groupName = article.parentGroup,
               videoPlaylistMetadata[groupName]?.isHidden == true {
                return false
            }
            return true
        case .xPosts:   return article.sourceType == .xPost
        }
    }

    func loadReviewSessionLinks() async {
        do {
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            logger.error("Failed to load review session links: \(error.localizedDescription)")
        }
    }

    func saveReviewSessionLink(
        title: String,
        url: String,
        sourceIDs: [String]? = nil,
        showSessionsPanel: Bool = true,
        mergeWithExistingSources: Bool = false
    ) async {
        do {
            let resolvedSourceIDs = try await reviewSessionSourceIDsForSave(
                url: url,
                sourceIDs: sourceIDs ?? contextSourceIds,
                mergeWithExistingSources: mergeWithExistingSources
            )
            _ = try await storage.saveReviewSessionLink(
                title: title,
                url: url,
                sourceIDs: resolvedSourceIDs
            )
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
            if showSessionsPanel {
                showAssistantOverlay = true
                revealReviewSessionSidebar()
                searchText = ""
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to save review session link: \(error.localizedDescription)")
        }
    }

    func reviewSessionSourceIDsForSave(url: String, sourceIDs: [String], mergeWithExistingSources: Bool) async throws -> [String] {
        guard mergeWithExistingSources else { return sourceIDs }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = try await storage.loadReviewSessionLinks()
        guard let existing = links.first(where: { ($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == trimmedURL }) else {
            return sourceIDs
        }

        var merged = existing.sourceIDs
        for sourceID in sourceIDs where !merged.contains(sourceID) {
            merged.append(sourceID)
        }
        return merged
    }

    func loadReviewSessionExchanges(_ sessionID: String) async {
        do {
            reviewSessionExchanges[sessionID] = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load review session transcript: \(error.localizedDescription)")
        }
    }

    func linkedSources(for session: ReviewSessionRecord) -> [StudioArticle] {
        // By id, not a scan: the sessions list calls this per visible row, and
        // a linear search of the library per source id made every list render
        // O(rows × sources).
        let byID = articlesById
        return session.sourceIDs.compactMap { byID[$0] }
    }

    var activeLearningGoal: LearningGoalRecord? {
        let now = Date()
        return learningGoals.first { goal in
            goal.lifecycleStatus == .active && goal.startAt <= now && goal.endAt >= now
        } ?? learningGoals.first { $0.lifecycleStatus == .active }
            ?? learningGoals.first
    }

    func learningGoalSource(for sourceID: String) -> StudioArticle? {
        articles.first { $0.id == sourceID }
    }

    func scheduleDays(for goal: LearningGoalRecord, containing date: Date) -> [ScheduleDay] {
        // The schedule reads the shared-placement model (`scheduled_sources`), filtered
        // to the placements tagged with this goal — the same model every schedule write
        // (add, move, mark-done, clear) mutates. `goal.items` (`learning_goal_items`)
        // remains the Notebook's source pool / companion-quiz state, not the schedule.
        unifiedScheduleDays(containing: date, goalID: goal.id)
    }

    /// The planned week containing `date`: every shared placement, tagged or
    /// not, bucketed by its planned day, each item carrying the Goals it serves.
    /// Pure/in-memory — safe to call from view bodies.
    ///
    /// **Only deliberate placements appear here.** A placement the app created
    /// by itself to anchor activity (`isAutomatic`) is consumption history, not
    /// a plan: it belongs to the History pane in Settings, and surfacing it here
    /// once made opening a source for two seconds read as a completed day.
    func unifiedScheduleDays(
        containing date: Date,
        goalID: String? = nil,
        includesFollowingDay: Bool = false
    ) -> [ScheduleDay] {
        // Memoized: the reader's idle view, the chat panel's welcome and the
        // planner all ask for the same week from their bodies, in every open
        // window, whenever any source changes — and opening a video changes a
        // source. Walking the whole schedule for each of those asks was most of
        // a click's main-thread cost. Every input the walk reads is in the key,
        // and reading the key's observable inputs here is what keeps a caller's
        // body subscribed to them on a cache hit.
        let calendar = Calendar.current
        let key = ScheduleDaysCacheKey(
            dayStart: calendar.startOfDay(for: date),
            goalID: goalID,
            includesFollowingDay: includesFollowingDay,
            today: calendar.startOfDay(for: Date()),
            inputsRevision: scheduleInputsRevision,
            articlesRevision: articlesRevision,
            linkedSourceIDs: learningGoalLinkedSourceIds,
            courseMetadataCount: courseMetadata.count,
            bookTitleCount: bookTitles.count,
            videoPlaylistCount: videoPlaylistMetadata.count,
            meetingMetadataCount: meetingMetadata.count
        )
        if let cached = unifiedScheduleDaysCache, cached.key == key {
            return cached.days
        }
        let days = computeUnifiedScheduleDays(
            containing: date,
            goalID: goalID,
            includesFollowingDay: includesFollowingDay,
            calendar: calendar
        )
        unifiedScheduleDaysCache = (key, days)
        return days
    }

    struct ScheduleDaysCacheKey: Equatable {
        let dayStart: Date
        let goalID: String?
        let includesFollowingDay: Bool
        let today: Date
        let inputsRevision: Int
        let articlesRevision: Int
        let linkedSourceIDs: Set<String>
        let courseMetadataCount: Int
        let bookTitleCount: Int
        let videoPlaylistCount: Int
        let meetingMetadataCount: Int
    }

    private func computeUnifiedScheduleDays(
        containing date: Date,
        goalID: String?,
        includesFollowingDay: Bool,
        calendar: Calendar
    ) -> [ScheduleDay] {
        let today = calendar.startOfDay(for: Date())
        let reviewDays = scheduleWeekDayStarts(
            containing: date,
            calendar: calendar,
            includesFollowingDay: includesFollowingDay
        )
        let articlesByID = articlesById
        var entriesByDay: [Date: [(order: Date, item: SchedulePlanItem)]] = [:]
        let goalsByID = Dictionary(uniqueKeysWithValues: learningGoals.map { ($0.id, $0) })
        for entry in scheduledSources {
            // Activity anchors are not plans. See the note above.
            if entry.isAutomatic { continue }
            // When scoped to a goal, only its tagged placements appear.
            if let goalID, !entry.goalIDs.contains(goalID) { continue }
            // Completing or archiving a Goal should stop its unfinished future
            // work from cluttering the active Schedule. Completed history remains,
            // as do placements shared with any active goal or with no known goal.
            if !entry.placement.isCompleted {
                let knownMemberships = entry.goalIDs.compactMap { goalsByID[$0] }
                if !knownMemberships.isEmpty,
                   knownMemberships.allSatisfy({ $0.lifecycleStatus != .active }) {
                    continue
                }
            }
            let plannedDay = calendar.startOfDay(for: entry.placement.plannedAt)
            guard reviewDays.contains(plannedDay) else { continue }
            // A placement whose source is archived or deleted resolves to nil here
            // (only active sources live in `articlesByID`). Such orphans must never
            // surface on the schedule, so drop them rather than render a "Missing
            // source" ghost row.
            guard let article = articlesByID[entry.placement.sourceID] else { continue }
            let groupTitle = sourceGroupTitle(for: article)
            let subtitle: String = {
                if article.sourceType == .book { return "Book chapter" }
                if let groupTitle, !groupTitle.isEmpty { return groupTitle }
                return article.domain
            }()
            // Kept for the "already opened this" hint on a pending row. It is a
            // hint only: completion never follows from it.
            let plannedActivityKinds = entry.activityDays
                .filter { calendar.isDate($0.dayStart, inSameDayAs: plannedDay) }
                .reduce(into: Set<SourceActivityKind>()) { $0.formUnion($1.kinds) }
            let item = SchedulePlanItem(
                id: entry.placement.id,
                sourceID: entry.placement.sourceID,
                title: playlistAwareTitle(for: article),
                subtitle: subtitle,
                groupTitle: groupTitle,
                plannedDate: plannedDay,
                // Completion is a fact the learner or a graded review produced.
                isCompleted: entry.placement.isCompleted,
                canMarkDone: true,
                hasLinkedChat: learningGoalLinkedSourceIds.contains(entry.placement.sourceID),
                isMissingSource: false,
                activityKinds: plannedActivityKinds,
                goalTags: entry.goalTags
            )
            entriesByDay[plannedDay, default: []].append((entry.placement.plannedAt, item))
        }
        return reviewDays.map { day in
            let items = (entriesByDay[day] ?? [])
                .sorted { $0.order < $1.order }
                .map(\.item)
            return ScheduleDay(
                date: day,
                items: items,
                isToday: calendar.isDate(day, inSameDayAs: today),
                isPast: day < today
            )
        }
    }

    /// A human-readable name for a source group, resolved from the group key
    /// alone — for callers that hold a group without holding one of its
    /// sources, such as a drag payload.
    ///
    /// Books, courses, meetings, and video playlists are all keyed by an opaque
    /// ID with the title kept in metadata, so the key itself must never reach
    /// the UI. Nil rather than the raw key when nothing readable resolves: a
    /// caller that has no name to show should say so, not show an identifier.
    ///
    /// Dictionary lookups only, in the order the group kinds are keyed. This is
    /// read during a drag, where a scan of every group per render would show up.
    func groupDisplayTitle(_ groupName: String) -> String? {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let bookTitle = storedBookDisplayTitle(for: trimmed) {
            return bookTitle
        }
        if let courseTitle = courseMetadata[trimmed]?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !courseTitle.isEmpty {
            return courseTitle
        }
        if let meetingTitle = meetingMetadata[canonicalMeetingGroupID(trimmed)]?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !meetingTitle.isEmpty {
            return meetingTitle
        }
        if let playlistTitle = videoPlaylistMetadata[trimmed]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !playlistTitle.isEmpty {
            return playlistTitle
        }
        return Self.humanVisibleGroupTitle(trimmed)
    }

    func sourceGroupTitle(for article: StudioArticle) -> String? {
        guard let groupName = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupName.isEmpty else { return nil }

        if article.sourceType == .book {
            return storedBookDisplayTitle(for: groupName) ?? Self.humanVisibleGroupTitle(groupName)
        }

        if allCourseGroupNames.contains(groupName) {
            return courseDisplayName(groupName)
        }

        if article.sourceType == .video,
           let playlistTitle = videoPlaylistMetadata[groupName]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !playlistTitle.isEmpty {
            return playlistTitle
        }
        return Self.humanVisibleGroupTitle(groupName)
    }

    nonisolated static func humanVisibleGroupTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeOpaqueIdentifier(trimmed) else { return nil }
        return trimmed
    }

    nonisolated static func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil {
            return true
        }
        return value.range(of: #"^(src_)?[A-Fa-f0-9]{24,}$"#, options: .regularExpression) != nil
    }

    /// A source's title as a list shows it: a playlist video carries its place
    /// in the playlist, everything else its stored title.
    func playlistAwareTitle(for article: StudioArticle) -> String {
        guard article.sourceType == .video,
              let groupName = article.parentGroup,
              let playlistTitle = videoPlaylistMetadata[groupName]?.title else {
            return article.title
        }
        return Self.videoPlaylistDisplayTitle(
            storedTitle: article.title,
            playlistTitle: playlistTitle,
            sortIndex: article.courseSortIndex
        )
    }

    func scheduleAssignableDays(goalID: String, containing date: Date = Date()) -> [Date] {
        guard learningGoals.contains(where: { $0.id == goalID }) else { return [] }
        return scheduleWeekDayStarts(containing: date, calendar: Calendar.current)
    }

    func startScheduleItem(_ item: SchedulePlanItem) async {
        guard !item.isMissingSource else { return }
        setContextSources([item.sourceID])
        showReaderPanel = true
        showAssistantOverlay = true
        readerPoppedOut = false
        clearReaderSurfaces()
        await selectArticle(item.sourceID)
    }

    func openSourceInReader(_ sourceID: String) async {
        let shouldRefreshVisibleChat = showAssistantOverlay
        setContextSources([sourceID])
        showReaderPanel = true
        readerPoppedOut = false
        clearReaderSurfaces()
        if shouldRefreshVisibleChat {
            requestResetReviewChat()
        }
        await selectArticle(sourceID)
    }

    /// Opens a source from a planner surface that is itself sitting in the reader
    /// column — a Notebook's source pool. Releasing the surface is the whole point:
    /// `selectArticle` alone moves the selection while Notebooks keeps the column,
    /// so the click looks dead. `workbenchNotebookID` is untouched, so the rail
    /// keeps the notebook active and its chats scoped while you read.
    ///
    /// Unlike `openSourceInReader`, this leaves chat context and the open chat
    /// alone: clicking a source in the pool is reader navigation, not a request to
    /// re-aim the chat at it. Dragging to chat and "Start review" still do that.
    func revealSourceInReader(_ sourceID: String) async {
        showReaderPanel = true
        readerPoppedOut = false
        clearReaderSurfaces()
        await selectArticle(sourceID)
    }

    func readerBestSearchMatch(for sourceId: String) -> SourceSearchBestMatch? {
        readerSearchBestMatches[sourceId]
            ?? sourceSearchResults.first { $0.article.id == sourceId }?.bestMatch
    }

    func scheduleWeekDayStarts(
        containing date: Date,
        calendar: Calendar,
        includesFollowingDay: Bool = false
    ) -> [Date] {
        let weekStart = mondayWeekStart(containing: date, calendar: calendar)
        let dayCount = includesFollowingDay ? 8 : 7
        return (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart)
        }
    }

    func mondayWeekStart(containing date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart) ?? dayStart
    }

    func loadLearningGoals() async {
        do {
            learningGoals = try await storage.loadLearningGoals()
            // Which notebooks follow which course moves with the notebooks.
            if let followers = try? await storage.loadCourseFollowers(), followers != courseFollowerNotebookIDs {
                courseFollowerNotebookIDs = followers
            }
            if !hasLoadedLearningGoalsOnce { hasLoadedLearningGoalsOnce = true }
            if notebookSyncBaseline == nil { notebookSyncBaseline = learningGoals }
            if activeNotebookId == nil || !notebooks.contains(where: { $0.id == activeNotebookId }) {
                activeNotebookId = notebooks.first?.id
            }
            // A notebook deleted on another device, or one a relaunch brought
            // back whose record is gone, is open nowhere.
            closeNotebooksMissingFromLibrary()
            // What a notebook holds may have changed: one made without a name
            // may be ready to be named (`NotebookNaming`).
            nameReadyNotebooks()
            scheduledSources = try await storage.loadScheduledSources()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            logger.error("Failed to load schedule: \(error.localizedDescription)")
        }
    }

    /// Approve or reject discovered sources on a Learning Companion goal, then
    /// refresh so the card reflects the new state. Approved sources enter the daily
    /// quiz rotation; rejected ones are tombstoned and never re-proposed.
    func setCompanionReviewState(goalID: String, sourceIDs: [String], approved: Bool) async {
        guard !sourceIDs.isEmpty else { return }
        do {
            try await storage.setCompanionItemReviewState(
                goalID: goalID,
                sourceIDs: sourceIDs,
                state: approved ? .approved : .rejected
            )
            learningGoals = try await storage.loadLearningGoals()
        } catch {
            logger.error("Failed to update suggestion: \(error.localizedDescription)")
        }
    }

    /// Start an in-app review for a Learning Companion goal: open the Chat
    /// panel and hand it a goal-linked review seeded with the goal's sources and topic,
    /// so completing it links to the goal.
    func startCompanionReview(
        goalID: String?,
        sourceIDs: [String],
        topic: String,
        rationale: String? = nil,
        memoryPlan: MemoryCompanionPlan? = nil
    ) {
        guard !sourceIDs.isEmpty else { return }
        pendingCompanionReview = MemoryCompanionRequest(
            goalID: goalID,
            sourceIDs: sourceIDs,
            topic: topic,
            rationale: rationale,
            memoryPlan: memoryPlan
        )
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        reviewChatAutoStartRequestID = UUID()
    }

    /// Create a Learning Companion goal from the in-app editor — the app-side twin of
    /// the create_learning_goal MCP tool. Seeds are approved immediately; when
    /// discovery is enabled, related sources are searched right away and inserted as
    /// pending suggestions. Throws if the goal itself cannot be created. Returns a
    /// human-readable note when discovery could not run (the goal still exists), or
    /// nil on a clean run.
    /// Most recent completed reviews for a goal, for the goal dashboard's history list.
    func companionRecentSessions(goalID: String, limit: Int = 4) async -> [CompanionSessionSummary] {
        (try? await storage.companionRecentSessions(goalID: goalID, limit: limit)) ?? []
    }

    func startObservingCloudKitRemoteChanges() {
        // A Doc shared or unshared on this Mac (`SharedDocs.share`, `stopSharingDoc`, `leaveSharedDoc`).
        sharedDocsObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .cloudKitSyncStoreDidChange) {
                await self?.refreshSharedDocs()
            }
        }
        cloudKitRemoteChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .cloudKitSyncRemoteStoreDidChange) {
                let entityRawValues = notification.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String]
                let affectedEntities = Set((entityRawValues ?? []).compactMap(CloudKitSyncEntity.init(rawValue:)))
                let requiresFullRefresh = notification.userInfo?[CloudKitSyncNotificationInfo.requiresFullRefreshKey] as? Bool ?? false
                // A Doc someone shared with this account arrives, or one is no longer shared.
                await self?.refreshSharedDocs()
                if let removedTeamID = notification.userInfo?[CloudKitSyncNotificationInfo.removedTeamKey] as? String {
                    await self?.teamWasRemoved(removedTeamID)
                }
                if affectedEntities.contains(.team) || requiresFullRefresh {
                    await self?.loadTeams()
                }
                if affectedEntities.contains(.shareRequest) || affectedEntities.contains(.source) || requiresFullRefresh {
                    await self?.refreshShareRequests()
                }
                // Nothing reloaded a board when its tasks arrived from
                // another Mac; now an open board and the Assigned list do.
                if affectedEntities.contains(.notebookTask) || requiresFullRefresh {
                    await self?.notebookTasksDidChangeRemotely()
                }
                await self?.scheduleCloudKitRemoteRefresh(
                    affectedEntities: affectedEntities,
                    requiresFullRefresh: requiresFullRefresh
                )
            }
        }
    }

    static let iCloudFullToast = "Your iCloud storage is full, so sync has paused. \(ICloudStorage.fullConsequence) Free up space or upgrade your iCloud+ plan (we recommend \(ICloudStorage.recommendedPlan))."

    /// A full iCloud stops uploads without a word: sync retries it like a
    /// network blip. Say so, once per filling.
    func startObservingICloudStorageFull() {
        iCloudFullObservationTask?.cancel()
        iCloudFullObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .cloudKitICloudStorageDidFill) {
                guard !Task.isCancelled else { return }
                self?.showToast(Self.iCloudFullToast)
            }
        }
    }

    func startObservingDerivedSourceWork() {
        derivedSourceWorkTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .derivedSourceWorkNeeded
            ) {
                guard let self else { return }
                // Coalesce a burst of events into one start. Only the waiting is
                // cancelled here — never a drain that has already begun.
                self.derivedSourceWorkDebounceTask?.cancel()
                self.derivedSourceWorkDebounceTask = Task(priority: .utility) { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.startDerivedSourceWork()
                }
            }
        }
    }

    /// Start a drain, or note that another event arrived while one is running.
    ///
    /// The drain lives in a task of its own, outside the debounce, because this
    /// event is posted by every `saveSource` — including the saves the drain
    /// itself makes, and those made concurrently by metadata extraction, artwork
    /// backfill, and incoming sync. Cancelling the debounce task used to cancel
    /// the drain with it, and every source still mid-flight in that batch threw
    /// a cancellation that the queue recorded as the source's own failure. A
    /// batch of imported papers could park itself wholesale that way.
    ///
    /// Coalescing is kept: a second call while a drain runs sets a flag instead
    /// of starting a rival batch, and the drain starts again when it finishes.
    func startDerivedSourceWork() {
        guard !isRunningDerivedSourceWork else {
            hasPendingDerivedSourceWork = true
            return
        }
        isRunningDerivedSourceWork = true
        derivedSourceWorkRunTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCanonicalContentCleanup()
            self.isRunningDerivedSourceWork = false
            guard self.hasPendingDerivedSourceWork else { return }
            self.hasPendingDerivedSourceWork = false
            self.startDerivedSourceWork()
        }
    }

    /// The account being able to pay again is the event that finishes work an
    /// empty balance stopped. Without this the learner adds a key and the
    /// paused source keeps offering them the same Add Key button.
    func startObservingManagedAICreditsRestored() {
        managedAICreditsRestoredTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .managedAICreditsRestored
            ) {
                guard let self else { return }
                // Work that was still `ready` when the balance emptied kept its
                // durable queue row and simply stopped draining. That queue
                // needs no repair, only another drain.
                NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                await self.resumeSourcesPausedByEmptyAIBalance()
            }
        }
    }

    /// Pick every parked source back up from where the empty balance stopped
    /// it. Nothing failed in these sources — the account simply could not pay —
    /// so this resumes the same work rather than retrying anything. A no-op
    /// when nothing is parked, which is the common case.
    @discardableResult
    func resumeSourcesPausedByEmptyAIBalance(
        creditsAreEmpty: Bool = AICreditEntitlement.isOutOfCredits
    ) async -> Int {
        guard !creditsAreEmpty else { return 0 }
        let pausedIDs = articles.filter(\.isPausedByEmptyAIBalance).map(\.id)
        guard !pausedIDs.isEmpty else { return 0 }

        var resumedCount = 0
        for id in pausedIDs {
            if await resumeSourcePausedByEmptyAIBalance(id) { resumedCount += 1 }
        }
        guard resumedCount > 0 else { return 0 }
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        showToast(
            resumedCount == 1
                ? "AI is available again — finishing the paused source"
                : "AI is available again — finishing \(resumedCount) paused sources"
        )
        return resumedCount
    }

    /// Moves cleanup timeouts written by older builds back into durable pending
    /// work. The preserved raw extraction is authoritative; no refetch and no
    /// user action is needed. Saving `.queued` plus the staged preparation
    /// atomically creates the cleanup queue row.
    @discardableResult
    func resumeSourcesAfterTransientCleanupFailures() async -> Int {
        let affectedIDs = articles.filter {
            PaperContentPreparationService.isTransientIngestionFailure($0.errorMessage)
        }.map(\.id)
        guard !affectedIDs.isEmpty else { return 0 }

        var resumedCount = 0
        for id in affectedIDs {
            guard let index = articles.firstIndex(where: { $0.id == id }) else { continue }
            var resumed = articles[index]
            if resumed.state == .ready {
                let cleared = (try? await storage.clearCompletedCanonicalContentCleanupFailure(
                    sourceID: id
                )) ?? false
                if cleared, let currentIndex = articles.firstIndex(where: { $0.id == id }) {
                    articles[currentIndex].errorMessage = nil
                    resumedCount += 1
                }
                continue
            }
            guard resumed.state == .error else { continue }
            guard resumed.sourceType != .paper || resumed.hasPaperIngestionAttestation,
                  let raw = await storage.loadStagedRawContent(id),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let rawSHA256 = await Self.contentSHA256OffMain(raw)
            if resumed.sourceType == .paper {
                resumed.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
            } else {
                resumed.stageArticleContentCleanup(raw: raw, rawSHA256: rawSHA256)
            }
            resumed.state = .queued
            resumed.errorMessage = nil
            guard await persistSource(
                resumed,
                context: "Resume transient source cleanup",
                showErrorToast: false
            ) else { continue }

            if resumed.sourceType == .paper {
                resumed.discardPersistedPaperContentFromMemory()
            } else {
                resumed.discardPersistedArticleContentHandoff()
            }
            if let currentIndex = articles.firstIndex(where: { $0.id == id }) {
                articles[currentIndex] = resumed
            }
            resumedCount += 1
        }
        return resumedCount
    }

    private func resumeSourcePausedByEmptyAIBalance(_ articleId: String) async -> Bool {
        guard let index = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        let article = articles[index]
        guard article.isPausedByEmptyAIBalance else { return false }

        // A paper stopped before its metadata stage resumes there; that stage
        // owns the cleanup that follows it.
        if article.sourceType == .paper, !article.hasPaperIngestionAttestation {
            return await extractPaperMetadataWithAI(id: articleId, showToasts: false)
        }

        // Everything else stopped at Source Content Cleanup with its extraction
        // already staged and no queue row: the save path deliberately declines
        // to enqueue work nothing can pay for. Restore the ordinary
        // cleanup-pending state so the durable drain finishes the ingestion.
        guard article.sourceType == .paper
                || article.sourceType == .article
                || article.sourceType == .manual
                || article.sourceType == .unclassified else { return false }
        guard let raw = await storage.loadStagedRawContent(articleId),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        var resumed = article
        resumed.content = raw
        resumed.state = .ready
        resumed.errorMessage = nil
        guard await persistSource(
            resumed,
            context: "Resume paused source cleanup",
            showErrorToast: false
        ) else { return false }
        // The staged extraction belongs to storage now; library rows hydrate
        // their text lazily and must not retain megabytes of it.
        resumed.content = nil
        if let currentIndex = articles.firstIndex(where: { $0.id == articleId }) {
            articles[currentIndex] = resumed
        }
        return true
    }

    func scheduleCloudKitRemoteRefresh(
        affectedEntities: Set<CloudKitSyncEntity>,
        requiresFullRefresh: Bool
    ) async {
        if requiresFullRefresh {
            cloudKitRemoteRefreshRequiresFullReload = true
            pendingCloudKitRefreshEntities = Set(CloudKitSyncEntity.allCases)
        } else if affectedEntities.isEmpty {
            pendingCloudKitRefreshEntities.formUnion([
                .source, .hiddenSource, .dismissedSource, .learningGoal, .scheduledSource, .reviewSession,
                .memoryItem, .memoryAttempt, .videoCitedPaper,
            ])
        } else {
            pendingCloudKitRefreshEntities.formUnion(affectedEntities)
        }

        cloudKitRemoteRefreshDebounceTask?.cancel()
        cloudKitRemoteRefreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            // Defer off any in-flight SwiftUI observation pass (e.g. text-to-speech
            // toolbar updates) before touching @Observable state.
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    self?.startCloudKitRemoteRefreshIfNeeded()
                }
            }
        }
    }

    /// CloudKit may deliver another event while a large-library refresh is still
    /// reading SQLite. Keep exactly one refresh in flight and fold later events
    /// into its next pass; overlapping refresh tasks multiplied identity scans
    /// and repeatedly invalidated the same SwiftUI list during a sync storm.
    private func startCloudKitRemoteRefreshIfNeeded() {
        guard cloudKitRemoteRefreshTask == nil else { return }
        cloudKitRemoteRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.cloudKitRemoteRefreshTask = nil }

            while self.cloudKitRemoteRefreshRequiresFullReload
                || !self.pendingCloudKitRefreshEntities.isEmpty {
                guard !Task.isCancelled else { return }
                let entities = self.pendingCloudKitRefreshEntities
                let requiresFull = self.cloudKitRemoteRefreshRequiresFullReload
                self.pendingCloudKitRefreshEntities = []
                self.cloudKitRemoteRefreshRequiresFullReload = false
                await Task.yield()
                await self.refreshAfterCloudKitRemoteChange(
                    affectedEntities: entities,
                    requiresFullRefresh: requiresFull
                )
            }
        }
    }

    /// Measure a synchronous main-actor publish step inside the CloudKit remote
    /// refresh and log any step slow enough to threaten a beachball. UI-stall
    /// samples attach ~1s after a stall begins and routinely miss the blocking
    /// step, so this names the culprit directly in the unified log.
    @discardableResult
    private func measureRefreshPublishStep<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            if elapsed > .milliseconds(100) {
                let ms = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
                logger.warning("CloudKit remote refresh step '\(name, privacy: .public)' held the main actor for \(ms, format: .fixed(precision: 0))ms")
            }
        }
        return try body()
    }

    /// Re-seed the preference-backed stored properties from `UserDefaults`.
    ///
    /// These are assigned once from their property initializers and observe
    /// nothing, so a preference that arrives from another Mac is invisible until
    /// the next launch unless it is pushed back in here. Computed-property readers
    /// (`MacArticleSpeechSettings`, `AIModelDefaults`, `KeychainService`) read
    /// `UserDefaults` live and need no equivalent.
    ///
    /// Assigning fires each `didSet`, which calls back into `PreferenceStore.set`.
    /// That does not loop: `set` drops writes whose value already matches what is
    /// in `UserDefaults`, and these values came from `UserDefaults` a line earlier.
    func reloadSyncedPreferences() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: "podcastSortMode"),
           let mode = PodcastSortMode(rawValue: raw), mode != podcastSortMode {
            podcastSortMode = mode
        }
        if let raw = defaults.string(forKey: "videoSortMode"),
           let mode = VideoSortMode(rawValue: raw), mode != videoSortMode {
            videoSortMode = mode
        }
        if let raw = defaults.string(forKey: "meetingListOrder"),
           let order = MeetingListOrder(rawValue: raw), order != meetingListOrder {
            meetingListOrder = order
        }
        let youtubeFallbackShows = Set(
            defaults.stringArray(forKey: Self.podcastYouTubeFallbackShowsKey) ?? []
        )
        if youtubeFallbackShows != podcastYouTubeFallbackShows {
            podcastYouTubeFallbackShows = youtubeFallbackShows
        }
        let meetingFolderImages = Self.meetingFolderImageURLsFromDefaults()
        if meetingFolderImages != meetingFolderImageURLs {
            meetingFolderImageURLs = meetingFolderImages
        }
        let quizScores = LectureQuizScore.scoresFromDefaults()
        if quizScores != lectureQuizScores {
            lectureQuizScores = quizScores
        }
        let storedQuizScores = LectureQuizScore.scoresFromDefaults(prefix: LectureQuizScore.courseQuizPreferenceKeyPrefix)
        if storedQuizScores != courseQuizScores {
            courseQuizScores = storedQuizScores
        }
        // Boxes unticked, and context notebooks put in, on another Mac or by
        // set_notebook_source_selection.
        let notebookExclusions = NotebookChatSelection.exclusionsFromDefaults()
        if notebookExclusions != notebookChatExclusions {
            notebookChatExclusions = notebookExclusions
        }
        let notebookContexts = NotebookChatSelection.contextNotebooksFromDefaults()
        if notebookContexts != notebookChatContextNotebooks {
            notebookChatContextNotebooks = notebookContexts
        }
        // Collections made, renamed or filled on another device, or by
        // update_notebook_collection.
        let collections = NotebookCollectionRows.read()
        if collections != notebookCollections {
            notebookCollections = collections
        }
        // Spaces made, renamed or deleted on another device or by
        // update_space, and pages moved between them there.
        let spaces = PageSpaceRows.read()
        if spaces != pageSpaces {
            pageSpaces = spaces
        }
        // Pages pinned or unpinned on another device.
        let pins = PagePinRows.read()
        if pins != pagePins {
            pagePins = pins
        }
        // Chats pinned, unpinned or reordered on another device.
        refreshChatPinsFromRows()
        // Lists of goals and ideas made, renamed or trashed on another
        // device, and goals and ideas filed in them there.
        refreshSpaceListsFromRows()
        // Canvases made, renamed or trashed on another Mac.
        refreshCanvasesFromRows()
        // Pages nested or moved out from under a page on another device.
        let parents = PageParentRows.read()
        if parents != pageParents {
            pageParents = parents
        }
        // A notebook made unnamed on another device, or named there.
        let namingMarks = NotebookNamingRows.marks()
        if namingMarks != notebookNamingMarks {
            notebookNamingMarks = namingMarks
            nameReadyNotebooks()
        }
        // Machine-local, but written by resolve_unconverted_zoom_recording
        // too, and the Meetings tab's row has to go when an assistant ignores
        // the recording.
        let ignoredZoomRecordings = Self.zoomLocalRecordingIgnoredFoldersFromDefaults()
        if ignoredZoomRecordings != zoomLocalRecordingIgnoredFolders {
            zoomLocalRecordingIgnoredFolders = ignoredZoomRecordings
        }
        if let raw = defaults.stringArray(forKey: "studio.hiddenTabs") {
            let tabs = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
            if tabs != hiddenTabs { hiddenTabs = tabs }
        }
        // Reseeded alongside the pinned set, never after it: this is the record
        // of which of those unpins were Studio's own, and a stale copy lets
        // `pinIntegrationTabsInUse()` undo one the learner performed.
        if let raw = defaults.stringArray(
            forKey: StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey
        ) {
            let tabs = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
            if tabs != autoUnpinnedIntegrationTabs { autoUnpinnedIntegrationTabs = tabs }
        }
        if let raw = defaults.stringArray(forKey: StudioSidebarTab.knowledgeExclusionPreferenceKey) {
            let tabs = Set(raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) })
            if tabs != excludedKnowledgeTabs { excludedKnowledgeTabs = tabs }
        }
        if let raw = defaults.stringArray(forKey: "studio.tabOrder") {
            // Reconcile before comparing: a synced order that names only some of
            // the tabs is an arrangement, not a membership list, and adopting it
            // verbatim would drop the rest of the tab bar.
            let order = StudioSidebarTab.reconciledOrder(
                raw.compactMap { StudioSidebarTab.fromPersistedRawValue($0) }
            )
            if !order.isEmpty, order != tabOrder { tabOrder = order }
        }
        if let raw = defaults.stringArray(forKey: "studio.centerTabGroups.v1"),
           let groups = StudioCenterTabGroups.fromPersisted(raw) {
            applySyncedCenterTabGroupsDefault(groups)
        }
        if let order = defaults.stringArray(forKey: "studio.courseOrder"), order != courseOrder {
            courseOrder = order
        }
        if let order = defaults.stringArray(forKey: "studio.projectOrder"), order != notebookOrder {
            notebookOrder = order
        }
        let pinnedIDs = defaults.stringArray(forKey: NotebookPins.preferenceKey) ?? []
        if pinnedIDs != pinnedNotebookIDs {
            pinnedNotebookIDs = pinnedIDs
        }
        if let order = defaults.stringArray(forKey: StudioViewModel.chatOrderPreferenceKey),
           order != chatOrder {
            chatOrder = order
        }
        let expanded = defaults.string(forKey: "studio.expandedPanel").flatMap(StudioExpandedPanel.init(rawValue:))
        if expanded != expandedPanel { expandedPanel = expanded }
        if let value = defaults.object(forKey: "studio.showSearchPanel") as? Bool, value != showSearchPanel {
            showSearchPanel = value
        }

        invalidateFilteredSidebarCache()
    }

    func refreshAfterCloudKitRemoteChange(
        affectedEntities: Set<CloudKitSyncEntity> = Set(CloudKitSyncEntity.allCases),
        requiresFullRefresh: Bool = true
    ) async {
        let entities = requiresFullRefresh ? Set(CloudKitSyncEntity.allCases) : affectedEntities
        let needsBooks = entities.contains(.book)
        let needsCourses = entities.contains(.course) || entities.contains(.videoPlaylist)
        let needsMeetings = entities.contains(.meetingGroup)
        let needsSources = entities.contains(.source)
            || entities.contains(.hiddenSource)
            || entities.contains(.dismissedSource)
            || entities.contains(.hiddenPodcastShow)
            || entities.contains(.hiddenYouTubeChannel)
            // A cited-paper decision made on the other Mac either adds a paper source
            // (import) or changes what the video's reader should still offer.
            || entities.contains(.videoCitedPaper)
        let needsLearningGoals = entities.contains(.learningGoal) || entities.contains(.scheduledSource)
        let needsIdeas = entities.contains(.idea)
        let needsDirections = entities.contains(.researchDirection)
        let needsArtifacts = entities.contains(.artifact) || entities.contains(.hiddenArtifact)
        let needsReview = entities.contains(.reviewSession) || entities.contains(.hiddenReviewSession)
        let needsMemory = Self.cloudKitEntitiesRequireMemoryRefresh(entities)
        let needsHighlights = entities.contains(.sourceHighlight)
        let needsPodcastVisibility = entities.contains(.hiddenPodcastShow)
            || entities.contains(.source)
            || entities.contains(.hiddenSource)
        let needsYouTubeVisibility = entities.contains(.hiddenYouTubeChannel)
            || entities.contains(.source)
            || entities.contains(.hiddenSource)

        if entities.contains(.preference) {
            await PreferenceStore.hydrateFromStore()
            reloadSyncedPreferences()
        }
        // A walkthrough rides the Source record, so a source change from the
        // other Mac or an MCP write may have brought or replaced one; an open
        // panel reloads its steps.
        if needsSources {
            noteWalkthroughChanged()
        }

        if needsArtifacts {
            await loadArtifacts()
            // An animation's walkthrough rides its Artifact record the same
            // way; a chat walking through the animation reloads its steps.
            noteWalkthroughChanged()
        }

        if needsBooks {
            do {
                let books = try await storage.loadBooks()
                bookTitles = books.titles
                bookSubtitles = books.subtitles
                bookCoverPaths = books.coverPaths
                bookAuthors = books.authors
                bookEditions = books.editions
                bookKinds = books.kinds
                invalidateFilteredSidebarCache()
            } catch {
                logger.error("Failed to refresh synced books: \(error.localizedDescription)")
            }
        }
        if needsCourses {
            do {
                courseMetadata = try await storage.loadCourseMetadata()
                courseTeamIDs = try await storage.loadCourseTeamIDs()
                courseFollowerNotebookIDs = try await storage.loadCourseFollowers()
                invalidateFilteredSidebarCache()
            } catch {
                logger.error("Failed to refresh synced course metadata: \(error.localizedDescription)")
            }
            do {
                videoPlaylistMetadata = try await storage.loadVideoPlaylistMetadata()
            } catch {
                logger.error("Failed to refresh synced video playlist metadata: \(error.localizedDescription)")
            }
            do {
                async let loadedLectures = storage.loadCourseLectures()
                async let loadedItems = storage.loadCourseLectureItems()
                async let loadedArtworkURLs = storage.loadCourseArtworkURLs()
                let lectures = try await loadedLectures
                let items = try await loadedItems
                let artworkURLs = try await loadedArtworkURLs
                measureRefreshPublishStep("courses.outline") {
                    applyCourseOutline(lectures: lectures, items: items)
                    courseCoverArtworkURLs = artworkURLs
                    invalidateFilteredSidebarCache()
                }
            } catch {
                logger.error("Failed to refresh synced course lectures: \(error.localizedDescription)")
            }
            // Quizzes travel inside the Course record.
            await refreshCourseQuizzes()
            Task { [weak self] in
                await self?.drainPendingWebCourseImports()
            }
        }
        if needsMeetings {
            do {
                let metadata = try await storage.loadMeetingMetadata()
                let artifacts = try await storage.loadMeetingArtifacts()
                measureRefreshPublishStep("meetings.publish") {
                    meetingMetadata = metadata
                    applyMeetingArtifacts(artifacts)
                    invalidateFilteredSidebarCache()
                }
            } catch {
                logger.error("Failed to refresh synced meeting metadata: \(error.localizedDescription)")
            }
        }
        if needsSources {
            do {
                let reloaded = try await storage.loadLibrarySources().sources
                // Merge and diff off the main actor: with a large library, the
                // content-preserving merge plus the equality check are far too
                // much work for the main thread. Publishing only on a real change
                // also spares SwiftUI a full sidebar re-render when a sync cycle
                // fetched records that match what we already show.
                let current = articles
                let (merged, changed) = await Task.detached(priority: .userInitiated) {
                    let merged = StudioViewModel.preservingLoadedContent(
                        in: reloaded,
                        preservingFrom: current
                    )
                    return (merged, merged != current)
                }.value
                if changed {
                    await Task.yield()
                    measureRefreshPublishStep("sources.publish") {
                        articles = merged
                        seedReadingProgressFromArticles()
                    }
                    autoFetchNewlyAddedPapers()
                    autoExtractMissingPaperMetadata()
                    autoFetchUnfetchedSources()
                    // A source came in or became readable: the sources no
                    // card covers are counted again for the corner card.
                    Task(priority: .utility) { [weak self] in
                        await self?.refreshCardsToCheckAdditions()
                    }
                }
                await convergePaperIdentityDuplicates()
            } catch {
                logger.error("Failed to refresh synced sources: \(error.localizedDescription)")
            }
            Task { [weak self] in
                await self?.drainPendingWebBookImports()
            }
        }
        if needsIdeas {
            await loadIdeas()
        }
        if needsDirections {
            await loadResearchDirections()
        }
        if needsLearningGoals {
            do {
                let goalsInMemory = learningGoals
                let refreshedLearningGoals = try await storage.loadLearningGoals()
                // The Schedule panel renders from scheduledSources (shared placements),
                // so it must reload alongside the goals or the week stays stale.
                let refreshedScheduledSources = try await storage.loadScheduledSources()
                if refreshedLearningGoals != learningGoals {
                    learningGoals = refreshedLearningGoals
                }
                if refreshedScheduledSources != scheduledSources {
                    scheduledSources = refreshedScheduledSources
                }
                if let activeNotebookId,
                   !notebooks.contains(where: { $0.id == activeNotebookId }) {
                    self.activeNotebookId = notebooks.first?.id
                }
                // A source added to a notebook on the web, the iPhone or
                // another Mac arrives ticked here too.
                await noteInboundNotebooks(refreshedLearningGoals, inMemory: goalsInMemory)
            } catch {
                logger.error("Failed to refresh synced schedule: \(error.localizedDescription)")
            }
        }
        if needsReview {
            do {
                reviewSessionLinks = try await storage.loadReviewSessionLinks()
            } catch {
                logger.error("Failed to refresh synced review sessions: \(error.localizedDescription)")
            }
        }
        if needsReview || needsSources {
            do {
                sourceReviewedAt = try await storage.sourceReviewDates()
                invalidateFilteredSidebarCache()
            } catch {
                logger.error("Failed to refresh synced review dates: \(error.localizedDescription)")
            }
        }
        if needsMemory {
            await refreshMemoryCompanionPlan()
        }
        // Cards to check ride Artifact records (the sources' draft decks) and
        // preference rows (what was kept or skipped); a kept card is a Memory
        // item. A draft, a Keep or a Skip from another device or an assistant
        // reaches the Memory pane, a notebook's Cards row and the counts. A
        // source's own change (reading progress, mostly) does not read them
        // again.
        if needsArtifacts || !entities.isDisjoint(with: [.memoryItem, .memoryAttempt, .preference]) {
            memoryCardRevision &+= 1
            Task(priority: .utility) { [weak self] in
                await self?.refreshMemoryCardCounts()
            }
        }
        if needsLearningGoals || needsReview {
            do {
                learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            } catch {
                logger.error("Failed to refresh synced schedule chat links: \(error.localizedDescription)")
            }
            do {
                learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
            } catch {
                logger.error("Failed to refresh synced schedule eligibility: \(error.localizedDescription)")
            }
        }
        if needsPodcastVisibility {
            do {
                hiddenPodcastShows = try await storage.loadHiddenPodcastShows()
            } catch {
                logger.error("Failed to refresh synced hidden podcast shows: \(error.localizedDescription)")
            }
            do {
                hiddenPodcastEpisodeIDs = try await storage.loadHiddenPodcastEpisodeIDs()
            } catch {
                logger.error("Failed to refresh synced hidden podcast episodes: \(error.localizedDescription)")
            }
            do {
                visiblePodcastEpisodeOverrideIDs = try await storage.loadVisiblePodcastEpisodeOverrideIDs()
            } catch {
                logger.error("Failed to refresh synced visible podcast overrides: \(error.localizedDescription)")
            }
            invalidateFilteredSidebarCache()
            Task(priority: .utility) { [weak self] in
                await self?.processPendingPodcastTranscripts()
            }
        }
        if needsYouTubeVisibility {
            do {
                hiddenYouTubeChannels = try await storage.loadHiddenYouTubeChannels()
            } catch {
                logger.error("Failed to refresh synced hidden YouTube channels: \(error.localizedDescription)")
            }
            do {
                visibleYouTubeVideoOverrideIDs = try await storage.loadVisibleYouTubeVideoOverrideIDs()
            } catch {
                logger.error("Failed to refresh synced visible YouTube overrides: \(error.localizedDescription)")
            }
            invalidateFilteredSidebarCache()
        }

        // A mark made on another device — or by an assistant over MCP — has to
        // reach an open reader, which paints from this cache and otherwise only
        // fills it when a source is first opened. Only sources already loaded are
        // refreshed, so this costs one indexed query per open reader rather than a
        // sweep of the library.
        if needsHighlights {
            for sourceID in Array(readerHighlights.keys) {
                await reloadReaderHighlights(for: sourceID)
            }
            // A clip cut on another Mac belongs on this Canvas too.
            knowledgeMapClipRevision &+= 1
        }

        // Sources that arrived over CloudKit sync never passed through the ingest
        // embed path, and embeddings are local-only derived data that don't sync — so
        // the receiving device must build their vectors itself. Kick the indexer to
        // close that gap in the background.
        if needsSources {
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runCanonicalContentCleanup()
                self.kickSourceEmbeddingIndexing()
            }
        }
    }

    /// Concept events directly change the due projection. Source events change
    /// which grounded targets are available, while legacy review history can
    /// make an on-demand first-review bootstrap candidate due.
    static func cloudKitEntitiesRequireMemoryRefresh(
        _ entities: Set<CloudKitSyncEntity>
    ) -> Bool {
        !entities.isDisjoint(with: [
            .memoryItem,
            .memoryAttempt,
            .source,
            .reviewSession,
        ])
    }

    /// Put sources on the Schedule — the Sources sidebar's Add to Schedule and
    /// Schedule for Today. They join the active Goal or Notebook when there is
    /// one. With none they are placed untagged: the Schedule holds a source
    /// whether or not a Goal claims it. A plain goal an older build created is
    /// never joined; it stays in the library untouched, but nothing plans
    /// against it any more. Either way a source already planned keeps its day
    /// unless `day` names one.
    func scheduleSources(_ sourceIDs: [String], on day: Date? = nil) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        let plannedDay = day.map { Calendar.current.startOfDay(for: $0) }

        if let goal = activeLearningGoal, goal.isCompanion {
            if let plannedDay {
                await addSourcesToLearningGoal(goalID: goal.id, sourceIDs: uniqueIDs, plannedFor: plannedDay)
            } else {
                await addSourcesToLearningGoal(goalID: goal.id, sourceIDs: uniqueIDs)
            }
            return
        }

        let planned = Set(scheduledSources.filter { !$0.isAutomatic }.map(\.placement.sourceID))
        let placing = plannedDay == nil ? uniqueIDs.filter { !planned.contains($0) } : uniqueIDs
        await placeSourcesOnSchedule(placing, on: plannedDay ?? Calendar.current.startOfDay(for: Date()))
    }

    func scheduleGroup(_ groupName: String) async {
        await scheduleSources(learningGoalSourceIDsForGroup(groupName))
    }

    /// Place sources on `day` without tagging them to anything: a placed
    /// source moves there, an unplaced one gets a placement of its own.
    func placeSourcesOnSchedule(_ sourceIDs: [String], on day: Date) async {
        guard !sourceIDs.isEmpty else { return }
        do {
            for sourceID in sourceIDs {
                try await storage.setScheduledSourcePlannedDate(sourceID: sourceID, plannedAt: day)
            }
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to schedule sources: \(error.localizedDescription)")
        }
    }

    func addSourcesToLearningGoal(goalID: String, sourceIDs: [String]) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        do {
            for sourceID in uniqueIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goalID)
            }
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to add sources to schedule: \(error.localizedDescription)")
        }
    }

    func addSourcesToLearningGoal(goalID: String, sourceIDs: [String], plannedFor day: Date) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        do {
            for sourceID in uniqueIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goalID, plannedAt: day)
            }
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to add sources to schedule day: \(error.localizedDescription)")
        }
    }

    /// Add sources to a Notebook pool and schedule them on a calendar day in one step.
    /// Ensures MCP context (`learning_goal_items`) and the shared schedule tag stay aligned.
    func addSourcesToNotebookSchedule(goalID: String, sourceIDs: [String], plannedFor day: Date) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        // The notebook these join: the Notebook itself, or a Goal's Notebook,
        // whose pool takes a Goal's additions too (addCompanionSeedSources).
        let goal = notebook(id: goalID)
        let notebookID = goal?.parentNotebookID ?? goal?.id
        let heldBefore = Set(notebookID.flatMap { notebook(id: $0) }?.approvedSourceIDs ?? [])
        do {
            try await storage.addCompanionSeedSources(goalID: goalID, sourceIDs: uniqueIDs)
            for sourceID in uniqueIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goalID, plannedAt: day)
            }
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
            // What joined the notebook arrives ticked, as every add does.
            if let notebookID {
                tickArrivingNotebookSources(notebookArrivals(in: notebookID, heldBefore: heldBefore))
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to schedule notebook sources: \(error.localizedDescription)")
        }
    }

    func expandedLearningGoalSourceIDs(_ sourceIDs: [String]) -> [String] {
        sourceIDs.flatMap { sourceID -> [String] in
            if articles.contains(where: { $0.id == sourceID }) {
                return [sourceID]
            }
            let groupSourceIDs = learningGoalSourceIDsForGroup(sourceID)
            return groupSourceIDs.isEmpty ? [sourceID] : groupSourceIDs
        }
    }

    func orderedUniqueSourceIDs(_ sourceIDs: [String]) -> [String] {
        var seen = Set<String>()
        return sourceIDs.filter { seen.insert($0).inserted }
    }

    func learningGoalSourceIDsForGroup(_ groupName: String) -> [String] {
        sourceIDsForGroupInOrder(groupName)
    }

    func sourceIDsForGroupInOrder(_ groupName: String) -> [String] {
        var orderedIDs: [String] = []
        var seen = Set<String>()

        if allCourseGroupNames.contains(groupName) {
            for lecture in courseLectures(for: groupName) {
                for item in courseLectureItems(for: lecture.id) {
                    guard let sourceID = item.sourceId, !seen.contains(sourceID) else { continue }
                    orderedIDs.append(sourceID)
                    seen.insert(sourceID)
                }
            }
        }

        let ownedArticles = (articlesStore.articleIDsByParentGroup[groupName] ?? [])
            .compactMap { articlesById[$0] }
            .sorted(by: learningGoalArticleOrder)
        for article in ownedArticles where !seen.contains(article.id) {
            orderedIDs.append(article.id)
            seen.insert(article.id)
        }

        return orderedIDs
    }

    func bookChapterArticlesInOrder(for groupName: String) -> [StudioArticle] {
        sourceIDsForGroupInOrder(groupName).compactMap { articlesById[$0] }
    }

    func bookChaptersWithReadingProgress(for groupName: String) -> [StudioArticle] {
        bookChapterArticlesInOrder(for: groupName).map { articleWithCurrentReadingProgress($0) }
    }

    /// The chapter the reader should reopen for a book: the furthest chapter
    /// with saved progress, or the first chapter when nothing has been read yet.
    func resumeBookChapter(for groupName: String) -> StudioArticle? {
        let chapters = bookChaptersWithReadingProgress(for: groupName)
        guard !chapters.isEmpty else { return nil }
        return chapters.last(where: \.hasSavedReadingPosition) ?? chapters.first
    }

    func learningGoalArticleOrder(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        let lhsGroup = lhs.parentGroup ?? ""
        let rhsGroup = rhs.parentGroup ?? ""
        if lhsGroup != rhsGroup {
            return lhsGroup.localizedStandardCompare(rhsGroup) == .orderedAscending
        }
        if let lhsIndex = lhs.courseSortIndex, let rhsIndex = rhs.courseSortIndex {
            return lhsIndex < rhsIndex
        }
        if lhs.courseSortIndex != nil { return true }
        if rhs.courseSortIndex != nil { return false }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func markScheduleSourceDone(sourceID: String) async {
        // The checkbox reflects the click immediately; the storage actor can be
        // seconds behind during a CloudKit merge, and the write plus four
        // reloads used to gate any visible change.
        applyLocalScheduleCompletion(sourceID: sourceID, completedAt: Date())
        do {
            // Completion is shared across every goal the placement belongs to.
            try await storage.setScheduledSourceCompletion(sourceID: sourceID, isCompleted: true)
            reflectScheduleCompletionReadState(for: [sourceID])
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
            sourceReviewedAt = try await storage.sourceReviewDates()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to mark schedule item done: \(error.localizedDescription)")
            await revertLocalScheduleCompletion()
        }
    }


    /// Optimistic half of mark-done: flip the completion the views read
    /// without waiting on the storage actor.
    private func applyLocalScheduleCompletion(sourceID: String, completedAt: Date?) {
        scheduledSources = scheduledSources.map { entry in
            guard entry.placement.sourceID == sourceID else { return entry }
            var placement = entry.placement
            placement.completedAt = completedAt
            return ScheduledSourceEntry(
                placement: placement,
                goalTags: entry.goalTags,
                goalIDs: entry.goalIDs,
                isAutomatic: entry.isAutomatic,
                activityDays: entry.activityDays
            )
        }
        learningGoals = learningGoals.map { goal in
            var goal = goal
            goal.items = goal.items.map { item in
                guard item.sourceID == sourceID else { return item }
                var item = item
                item.completedAt = completedAt
                return item
            }
            return goal
        }
    }

    /// A failed completion write leaves the optimistic flip wrong; storage is
    /// the truth, so read it back rather than guessing the prior state.
    private func revertLocalScheduleCompletion() async {
        if let goals = try? await storage.loadLearningGoals() {
            learningGoals = goals
        }
        if let sources = try? await storage.loadScheduledSources() {
            scheduledSources = sources
        }
    }

    /// `cascadeChildGoals` deletes a Notebook's nested Goals along with it, and
    /// belongs only to callers that have already told the learner how many
    /// Goals that is.
    func deleteLearningGoal(
        _ goalID: String,
        cascadeChildGoals: Bool = false,
        deleteLinkedChats: Bool = false
    ) async {
        let childGoalIDs = cascadeChildGoals ? goals(inNotebook: goalID).map(\.id) : []
        let deletedGoalIDs = Set([goalID] + childGoalIDs)
        // The same call deletes a Notebook and a Goal, so the toast and the log
        // line take the noun from the record itself rather than assuming one.
        let deletedKind = learningGoals.first(where: { $0.id == goalID })?.isNotebook == true ? "notebook" : "Goal"
        let linkedSessionIDs: Set<String> = Set(reviewSessionLinks.compactMap { session -> String? in
            guard let linkedGoalID = session.goalID,
                  deletedGoalIDs.contains(linkedGoalID) else {
                return nil
            }
            return session.id
        })
        do {
            try await storage.deleteLearningGoal(
                goalID,
                cascadeChildGoals: cascadeChildGoals,
                deleteLinkedChats: deleteLinkedChats
            )
            learningGoals.removeAll { $0.id == goalID || childGoalIDs.contains($0.id) }
            notebookFilesByNotebookID[goalID] = nil
            notebookFilesLastRefreshAt[goalID] = nil
            notebookChatExclusions[goalID] = nil
            notebookChatContextNotebooks[goalID] = nil
            NotebookChatSelection.forget(notebookID: goalID)
            forgetNotebookCollections(of: goalID)
            scheduledSources = try await storage.loadScheduledSources()
            closeNotebookInEveryWindow(goalID)
            if activeNotebookId == goalID {
                activeNotebookId = notebooks.first?.id
            }
            if deleteLinkedChats {
                for sessionID in linkedSessionIDs {
                    reviewSessionExchanges[sessionID] = nil
                }
                reviewTranscriptMatchIDs?.subtract(linkedSessionIDs)
            }
            // A deleted notebook follows no course any more; the courses stay.
            await reloadCourseFollowers()
            await loadReviewSessionLinks()
            showToast("Deleted the \(deletedKind).")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to delete \(deletedKind): \(error.localizedDescription)")
        }
    }

    /// The Notebooks `goal` can be merged into: the other live Notebooks of the
    /// same library. A team's Notebook never merges into My Library or another
    /// team's, because its records live in that team's zone.
    func mergeCandidates(for goal: LearningGoalRecord) -> [LearningGoalRecord] {
        notebooks.filter { $0.id != goal.id && $0.teamID == goal.teamID }
    }

    /// Folds `notebookID` into `survivorID`: its sources, chats, Goals, tasks,
    /// docs, scheduled tasks, Planner blocks, open questions, notes and files
    /// all land on the survivor, and the merged Notebook is deleted. `title`
    /// renames the survivor when given. Returns whether the merge happened.
    @discardableResult
    func mergeNotebook(_ notebookID: String, into survivorID: String, title: String? = nil) async -> Bool {
        let mergedTitle = learningGoals.first { $0.id == notebookID }?.title ?? "the notebook"
        do {
            let result = try await storage.mergeCompanionGoals(
                notebookIDs: [survivorID, notebookID],
                title: title,
                mergeNotes: true
            )
            learningGoals = try await storage.loadLearningGoals()
            for id in [notebookID, survivorID] {
                notebookFilesByNotebookID[id] = nil
                notebookFilesLastRefreshAt[id] = nil
            }
            notebookTasksByNotebookID[notebookID] = nil
            // The merged notebook's unticked boxes go with it; its sources
            // arrive in the survivor ticked. The context notebooks its chats
            // read stay in for the survivor, which took its links, and a
            // notebook whose chats read it read the survivor.
            notebookChatExclusions[notebookID] = nil
            // Generation 2's merge job unioned the member's NotebookState
            // sets into the survivor's in the store (schema v2 §5.2).
            NotebookStateStore.reload()
            await loadNotebookTasks(notebookID: survivorID)
            scheduledSources = try await storage.loadScheduledSources()
            moveNotebookInEveryWindow(notebookID, to: survivorID)
            if activeNotebookId == notebookID {
                activeNotebookId = survivorID
            }
            await loadReviewSessionLinks()
            await loadArtifacts()
            // The survivor follows every course the merged notebooks followed.
            await reloadCourseFollowers()
            let survivorTitle = learningGoals.first { $0.id == survivorID }?.title ?? "the notebook"
            var parts: [String] = []
            if result.sourcesAdded > 0 { parts.append("\(result.sourcesAdded) source\(result.sourcesAdded == 1 ? "" : "s")") }
            if result.chatsMoved > 0 { parts.append("\(result.chatsMoved) chat\(result.chatsMoved == 1 ? "" : "s")") }
            if result.docsMoved > 0 { parts.append("\(result.docsMoved) page\(result.docsMoved == 1 ? "" : "s")") }
            if result.filesMoved > 0 { parts.append("\(result.filesMoved) file\(result.filesMoved == 1 ? "" : "s")") }
            let detail = parts.isEmpty ? "" : " Moved \(parts.joined(separator: ", "))."
            showToast("Merged \"\(mergedTitle)\" into \"\(survivorTitle)\".\(detail)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to merge notebook: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteReviewSessionLink(_ id: String) async -> Bool {
        // Reflect the destructive action immediately. Storage is actor-isolated,
        // and a large inbound CloudKit merge can legitimately be ahead of this
        // write. Keeping the row visible until that queue drains makes the menu
        // look broken and invites repeated clicks.
        let removedSession = reviewSessionLinks.first { $0.id == id }
        let removedExchanges = reviewSessionExchanges[id]
        reviewSessionLinks.removeAll { $0.id == id }
        reviewSessionExchanges[id] = nil

        do {
            try await storage.deleteReviewSession(id)
        } catch {
            // The durable delete did not happen. Put this row back instead of
            // masking the failure with an optimistic UI that lies about state.
            if let removedSession,
               !reviewSessionLinks.contains(where: { $0.id == id }) {
                reviewSessionLinks.append(removedSession)
            }
            if let removedExchanges {
                reviewSessionExchanges[id] = removedExchanges
            }
            errorMessage = "Could not delete the chat. \(error.localizedDescription)"
            showToast(errorMessage ?? "Could not delete the chat.")
            logger.error("Failed to delete review session link: \(error.localizedDescription)")
            return false
        }
        // Its pin and its unread mark go with it, so neither outlives the
        // chat on any device.
        setChatPinned(id, pinned: false)
        ChatReadMarks.shared.forget(id)

        do {
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            // The session is already durably deleted. A derived-state refresh
            // failure must not restore it or report that deletion itself failed.
            errorMessage = "The chat was deleted, but review status could not refresh. \(error.localizedDescription)"
            showToast(errorMessage ?? "The chat was deleted, but review status could not refresh.")
            logger.error("Deleted review session link, but failed to refresh review state: \(error.localizedDescription)")
        }
        return true
    }

    /// Move a chat into a Notebook, or out of any Notebook when `goalID` is nil.
    func moveReviewSession(_ sessionID: String, toNotebook goalID: String?) async {
        // The rail reflects the move immediately; the storage actor can lag
        // behind a CloudKit merge, and the row jumping sections seconds after
        // the menu click read as the action having failed.
        let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID })
        let previous = index.map { reviewSessionLinks[$0].goalID }
        if let index { reviewSessionLinks[index].goalID = goalID }
        do {
            try await storage.updateReviewSessionGoal(sessionID: sessionID, goalID: goalID)
        } catch {
            if let previous, let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].goalID = previous
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to move review session to notebook: \(error.localizedDescription)")
        }
    }

    func renameReviewSession(_ sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID })
        let previous = index.map { reviewSessionLinks[$0].title }
        if let index { reviewSessionLinks[index].title = trimmed }
        do {
            try await storage.updateReviewSessionTitle(sessionID: sessionID, title: trimmed)
        } catch {
            if let previous, let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].title = previous
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to rename review session: \(error.localizedDescription)")
        }
    }

    /// Hide a chat from the sidebar, or show it again. Hide is the learner's
    /// view, where Delete is the record's fate (product owner, 2026-09-12: "please
    /// allow me to hide chats as well"): nothing about the chat moves — not
    /// its transcript, its Notebook, its team copies or its place in search
    /// over MCP. The view is the account's, not one Mac's (product owner,
    /// 2026-09-13: hidden items "should be consistent across multiple
    /// macbooks"), so the hide syncs as a record of its own and every Mac
    /// folds the same chats. An open chat stays open; only its row leaves,
    /// and the Hidden fold under Chats lists it again with Show.
    func setReviewSessionHidden(_ sessionID: String, hidden: Bool) async {
        // The row leaves with the click; the write follows. Waiting on the
        // storage actor first left the row visible for as long as a CloudKit
        // merge kept the actor busy.
        let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID })
        let previous = index.map { reviewSessionLinks[$0].hiddenAt }
        if let index {
            if hidden {
                if reviewSessionLinks[index].hiddenAt == nil { reviewSessionLinks[index].hiddenAt = Date() }
            } else {
                reviewSessionLinks[index].hiddenAt = nil
            }
        }
        let title = index.map { reviewSessionLinks[$0].title }.flatMap { $0.isEmpty ? nil : $0 } ?? "chat"
        showToast(
            hidden ? "Hid \(title)" : "Unhid \(title)",
            undo: hidden ? { [weak self] in await self?.setReviewSessionHidden(sessionID, hidden: false) } : nil
        )
        do {
            let hiddenAt = try await storage.setReviewSessionHidden(sessionID: sessionID, hidden: hidden)
            if let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].hiddenAt = hidden ? (hiddenAt ?? reviewSessionLinks[index].hiddenAt) : nil
            }
        } catch {
            if let previous, let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].hiddenAt = previous
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden chat: \(error.localizedDescription)")
        }
    }

    func updateReviewSessionSources(_ sessionID: String, sourceIDs: [String]) async {
        do {
            try await storage.updateReviewSessionSources(sessionID: sessionID, sourceIDs: sourceIDs)
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update review session sources: \(error.localizedDescription)")
        }
    }

    /// Open the Review Sessions panel filtered to a specific source.
    func showReviewSessionsForSource(_ sourceID: String) {
        reviewSessionFilter = .source(sourceID)
        showAssistantOverlay = true
        revealReviewSessionSidebar()
        Task { await loadReviewSessionLinks() }
    }

    /// Open the Review Sessions panel filtered to an entire parent group
    /// (a book or course), so sessions linked to any of its items are shown.
    func showReviewSessionsForGroup(_ groupName: String) {
        reviewSessionFilter = .group(groupName)
        showAssistantOverlay = true
        revealReviewSessionSidebar()
        Task { await loadReviewSessionLinks() }
    }

    /// Opens a saved chat in the window in scope. Which workspace it opens in
    /// follows the chat (`applyChatHome`): one filed in a notebook opens that
    /// notebook here, a library chat leaves the window's notebook.
    func requestResumeReviewSession(_ sessionID: String) {
        applyChatHome(forSessionID: sessionID, in: chatRequestOriginWindow ?? activeWindowState)
        reviewChatResumeSessionID = sessionID
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
    }

    func requestResetReviewChat() {
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        reviewChatResetRequestID = UUID()
    }

    /// Start a tutor review of a Notebook's approved sources from outside the
    /// chat panel: seeds the context, links the notebook (so completing the
    /// session records against it), and auto-starts the session. The reset
    /// request runs before the auto-start request in the panel's task order,
    /// so the notebook link is in place when the session begins.
    func requestNotebookReview(_ notebookID: String) {
        guard let notebook = notebook(id: notebookID) else { return }
        // Every box unticked: there is nothing to review, and the idle
        // composer's Start review says so in the same words.
        let tally = notebookChatTally(notebook)
        if tally.inChat == 0, tally.total > 0 {
            showToast("Tick a source in \u{201C}\(notebook.title)\u{201D} to review it.")
            return
        }
        pendingReviewChatNotebookID = notebook.id
        setContextSources(notebookChatSourceIDs(notebook))
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        reviewChatResetRequestID = UUID()
        reviewChatAutoStartRequestID = UUID()
    }

    /// Records which window the chat request being made is for, and says so
    /// whenever that is not the window the request was made in.
    ///
    /// The destination is the window in scope — the key Studio window, or the
    /// one an `inWindow` scope names (`chatRequestDestinationWindow`). Only a
    /// request from a window that is no Studio window at all (a popped-out
    /// Reader) lands elsewhere, in the Studio window used last. The chat then
    /// appears on a display the learner may not be looking at, and a click
    /// whose result shows up somewhere else looks like a click that did
    /// nothing — so the toast names where it went. Called from the request
    /// tokens' `didSet`, so every requester is covered.
    func stampChatRequestTargetWindow() {
        let origin = chatRequestOriginWindow
        let destination = chatRequestDestinationWindow(origin: origin)
        reviewChatTargetWindowID = destination.id
        chatRequestElsewhereNotice = chatOpenedElsewhereNotice(origin: origin, destination: destination)
        if let chatRequestElsewhereNotice {
            let replay = ChatRequestReplay(
                resumeSessionID: reviewChatResumeSessionID,
                resetsChat: reviewChatResetRequestID != nil,
                autoStarts: reviewChatAutoStartRequestID != nil,
                notebookID: pendingReviewChatNotebookID,
                draft: pendingReviewChatDraft
            )
            showToast("Opened in \(chatRequestElsewhereNotice)", action: .openHere { [weak self] window in
                self?.replayChatRequest(replay, in: window)
            })
        }
    }

    /// What a chat request asked for, captured while its tokens are still
    /// set, so the toast's Open here can ask again in another window after
    /// the pane over there has consumed and cleared them.
    struct ChatRequestReplay: Equatable {
        var resumeSessionID: String?
        var resetsChat: Bool
        var autoStarts: Bool
        var notebookID: String?
        var draft: String?
    }

    /// Makes the chat request `replay` again, this time for `window`, from
    /// the toast's Open here. The request went elsewhere because it came from
    /// a popped-out Reader, and the button is the learner naming this window
    /// instead: Chat is revealed here first, releasing a pin if it has to, so
    /// the restamped request lands here and raises no second toast. The request is made inside the window's scope
    /// rather than the key window's: the button was pressed in this window,
    /// but the registry's notion of key can lag the click.
    func replayChatRequest(_ replay: ChatRequestReplay, in window: StudioWindowState) {
        activateCenterTab(.chat, in: window)
        inWindow(window) {
            reviewChatPanelMode = .chat
            showAssistantOverlay = true
            if replay.resetsChat {
                pendingReviewChatNotebookID = replay.notebookID
                pendingReviewChatDraft = replay.draft
                reviewChatResetRequestID = UUID()
            }
            if let sessionID = replay.resumeSessionID {
                reviewChatResumeSessionID = sessionID
            }
            if replay.autoStarts {
                reviewChatAutoStartRequestID = UUID()
            }
            reviewChatTargetWindowID = window.id
        }
    }

    /// The window a chat request made in `origin` should show in: always
    /// `origin`, the window the click was made in. It never goes to another
    /// window that happens to show Chat already, since sending it there is
    /// what the context menu's Open in Other Window is for (product owner,
    /// 2026-09-22: "no actual click on anything should ever open the thing in
    /// the other ForeverLM window"). A nil origin (no Studio window is key, as
    /// from a popped-out Reader) starts from the Studio window used last.
    func chatRequestDestinationWindow(origin: StudioWindowState?) -> StudioWindowState {
        origin ?? activeWindowState
    }

    /// Where the chat went, for the learner, when it is not the window the
    /// request was made in; nil when it shows in place. Only Studio windows on
    /// the registry count: the fallback scene tests and launch helpers navigate
    /// through is not a window on anyone's desk. From a window that is no
    /// Studio window the chat has always gone elsewhere, but with one Studio
    /// window open there is nowhere else it could have gone, so that says
    /// nothing; with two or more, it is one of several.
    private func chatOpenedElsewhereNotice(
        origin: StudioWindowState?,
        destination: StudioWindowState
    ) -> String? {
        let registered = StudioWindowRegistry.shared.states
        guard registered.contains(where: { $0 === destination }) else { return nil }
        if let origin {
            guard origin !== destination, registered.contains(where: { $0 === origin }) else { return nil }
            return Self.otherWindowDescription(otherWindowCount: registered.count - 1)
        }
        guard registered.count > 1 else { return nil }
        return Self.otherWindowDescription(otherWindowCount: registered.count)
    }

    /// "The other" is only honest while exactly one other Studio window is
    /// open; a second makes it one of several.
    static func otherWindowDescription(otherWindowCount: Int) -> String {
        otherWindowCount > 1 ? "another ForeverLM window" : "the other ForeverLM window"
    }

    /// Whether a primary Chat pane hosted in the window `ownerWindowID` should
    /// act on the pending global chat requests. A pane that does not know its
    /// window, and a request made before any was stamped, keep the old
    /// behaviour of accepting everything.
    func chatPaneAcceptsGlobalRequests(ownerWindowID: UUID?) -> Bool {
        guard let ownerWindowID, let reviewChatTargetWindowID else { return true }
        return ownerWindowID == reviewChatTargetWindowID
    }

    /// Pass a `notebookID` to start the fresh chat linked to that Notebook with the
    /// sources ticked in its pool as context (`notebookChatSourceIDs`). Nil
    /// asks for a library chat — Plan the Day, Getting Started, a scheduled
    /// task, a Goal chat with no Notebook — and a window holding a notebook
    /// leaves it first, as opening a library chat does (the chat-home rule,
    /// `applyChatHome`). New chat buttons ask through `requestNewChat`, which
    /// names the window's notebook.
    func requestBlankReviewChat(notebookID: String? = nil) {
        if notebookID == nil {
            closeNotebook(in: chatRequestOriginWindow ?? activeWindowState)
        }
        startBlankReviewChat(notebookID: notebookID)
    }

    /// The fresh chat `requestBlankReviewChat` and `requestNewChat` ask for,
    /// in whatever workspace the window is in: linked to `notebookID` with its
    /// ticked sources as context, or fully blank and unlinked.
    func startBlankReviewChat(notebookID: String?) {
        if let notebookID, let notebook = notebook(id: notebookID) {
            pendingReviewChatNotebookID = notebook.id
            setContextSources(notebookChatSourceIDs(notebook))
        } else {
            pendingReviewChatNotebookID = nil
            clearSourceContext()
        }
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// Open a fresh chat with the new-task template already typed but unsent.
    /// A scheduled task is a sentence ("every weekday at 7:30, quiz me on what I
    /// read yesterday"), not a set of fields, so the Tasks pane's "+" hands the
    /// learner to chat: the assistant asks for whatever the instruction and
    /// cadence still need and calls create_scheduled_task itself. The editor
    /// sheet stays for changing a task that already exists.
    func requestNewScheduledTaskChat() {
        pendingReviewChatDraft = "Set up a recurring scheduled task for me. Ask me what it should do and when it should run, then create it."
        requestBlankReviewChat()
    }

    /// Open a fresh chat that makes an animation. With a source, the chat
    /// starts with that source in context and the request typed but unsent —
    /// the source menu's Animate…; without one, the Animations home's button
    /// opens a blank chat with the request typed and the learner adds the
    /// source with /source. The chat draws the animation and saves it with
    /// save_animation, linked to the source (docs/animations-design.md).
    func requestAnimationChat(sourceID: String? = nil) {
        if let sourceID, let article = articles.first(where: { $0.id == sourceID }) {
            pendingReviewChatNotebookID = nil
            setContextSources([sourceID])
            pendingReviewChatDraft = Self.animationChatDraft(sourceTitle: displayTitle(for: article))
            reviewChatPanelMode = .chat
            showAssistantOverlay = true
            reviewChatResetRequestID = UUID()
            reviewChatFocusRequestID = UUID()
        } else {
            pendingReviewChatDraft = Self.animationChatDraft(sourceTitle: nil)
            requestBlankReviewChat()
        }
    }

    /// The unsent opening line for a chat that makes an animation. It names
    /// the source when there is one and leaves the mechanism to the learner:
    /// what to animate is the one thing only they can say.
    static func animationChatDraft(sourceTitle: String?) -> String {
        if let sourceTitle, !sourceTitle.isEmpty {
            return "Make an interactive animation of how the mechanism in \u{201C}\(sourceTitle)\u{201D} works — every step labelled and placed where it happens, with a toggle for each condition the paper compares — and save it with save_animation linked to this source. Animate: "
        }
        return "Make an interactive animation of how something works — every step labelled and placed where it happens, with a toggle for each condition compared — and save it with save_animation linked to the sources you draw it from. Animate: "
    }

    /// Opens the day-planning conversation with `request` unsent in the
    /// composer. The text is `ReviewSlashCommandParser.planDayRequest`, so the
    /// Today menu, the Now chip, "Plan your day?" and `/plan` all open the
    /// same conversation under the same rules rather than near-copies.
    func requestPlanDayChat(request: String) {
        pendingReviewChatDraft = request
        pendingPlanDayDraft = request
        requestBlankReviewChat()
    }

    /// Reveal the previous-sessions list inside the open Chat panel (popover).
    func revealReviewSessionSidebar() {
        reviewSessionsRevealRequestID = UUID()
    }
}

// MARK: - To Read and Recent

extension StudioViewModel {
    /// What the learner saved and has not finished, newest saved first: the
    /// rule `ToReadList` keeps for the iPhone's To Read screen, read from the
    /// Mac's sources. Home's empty chat lists it (product owner, 2026-11-09: "it
    /// just opens cleanly and it shows basically a list of recent things we
    /// added to the reading list"), whatever the kind: an article, a paper, an
    /// X post or pasted text ("Doesn't matter if it's article, paper, etc.").
    func toReadSources() -> [StudioArticle] {
        // The kind test first: it is a set lookup, and it drops the feeds'
        // thousands of episodes before the hidden-show and recording tests.
        let visible = articles.filter {
            ToReadList.savedSourceTypes.contains($0.sourceType.rawValue) && isVisibleInRecordingMode($0)
        }
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = visible.map { article in
            ToReadCandidate(
                id: article.id,
                sourceType: article.sourceType.rawValue,
                dateAdded: article.dateAdded,
                isFinished: article.readAt != nil,
                isPutAway: article.status == .archived || isSourceHidden(article),
                isPaywalled: article.isPaywalled,
                belongsToGroup: article.parentGroup != nil,
                isSpokenScript: GeneratedExplainer.isSpokenScriptURL(article.url)
            )
        }
        return ToReadList.waiting(candidates).compactMap { byID[$0.id] }
    }

    /// The Library's Recent view: every kind in one list, newest added first,
    /// not split into podcasts, books and the rest (product owner, 2026-11-09:
    /// "not grouped by podcast, book, etc., but basically by date added").
    /// Hidden and archived sources stay off it, as they do off every tab. A
    /// book's chapters and a course's lessons stand under their book or course,
    /// which have rows of their own in their tabs, so they are left out rather
    /// than listed thirty at a time. `query` is the Library's search.
    func recentlyAddedSources(matching query: String) -> [StudioArticle] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return articles
            .filter { article in
                article.status == .active
                    && !isSourceHidden(article)
                    && isVisibleInRecordingMode(article)
                    && !GeneratedExplainer.isSpokenScriptURL(article.url)
                    && article.sourceType != .course
                    && !(article.sourceType == .book && article.parentGroup != nil)
                    && (trimmed.isEmpty || sourceMatchesSearch(article, query: trimmed))
            }
            .sorted { lhs, rhs in
                if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
                return lhs.id < rhs.id
            }
    }
}
