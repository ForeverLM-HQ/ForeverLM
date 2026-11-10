import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
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
    /// The partition is not computed inline and memoized per articles revision:
    /// that memo is worthless during launch — every republish of `articles`
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
