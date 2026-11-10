// Sidebar tabs, show-more limits and podcast catalog search.

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

}
