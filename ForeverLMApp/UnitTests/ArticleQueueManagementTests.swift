// The YouTube transcript formatting gate and the article queue management tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - YouTube Transcript Formatting Gate

@Suite("YouTube Transcript Formatting Gate")
@MainActor
struct YouTubeTranscriptFormattingGateTests {

    private func makeVideo(id: String, channel: String) -> StudioArticle {
        var article = makeArticle(
            url: "https://www.youtube.com/watch?v=\(id)",
            title: "Video \(id)",
            sourceType: .video,
            id: id
        )
        article.domain = channel
        return article
    }

    @Test("videos on a visible channel allow transcript formatting")
    func visibleChannelAllowsFormatting() {
        let vm = makeViewModel()
        let video = makeVideo(id: "visible", channel: "Example Channel")
        vm.articles = [video]

        #expect(vm.allowsTranscriptFormatting(for: video, userInitiated: false))
    }

    @Test("videos on a hidden channel skip transcript formatting")
    func hiddenChannelSkipsFormatting() {
        let vm = makeViewModel()
        let video = makeVideo(id: "hidden", channel: "Example Channel")
        vm.articles = [video]
        vm.hiddenYouTubeChannels = ["Example Channel"]

        #expect(!vm.allowsTranscriptFormatting(for: video, userInitiated: false))
    }

    @Test("a visible video on a hidden channel still formats")
    func visibleOverrideOnHiddenChannelFormats() {
        let vm = makeViewModel()
        let video = makeVideo(id: "override", channel: "Example Channel")
        vm.articles = [video]
        vm.hiddenYouTubeChannels = ["Example Channel"]
        vm.visibleYouTubeVideoOverrideIDs = ["override"]

        #expect(vm.allowsTranscriptFormatting(for: video, userInitiated: false))
    }

    @Test("an explicit fetch formats even on a hidden channel")
    func userInitiatedOverridesHiddenChannel() {
        let vm = makeViewModel()
        let video = makeVideo(id: "requested", channel: "Example Channel")
        vm.articles = [video]
        vm.hiddenYouTubeChannels = ["Example Channel"]

        #expect(vm.allowsTranscriptFormatting(for: video, userInitiated: true))
    }

    @Test("automatic liked-video imports require their own formatting consent")
    func likedVideoImportConsentBlocksAutomaticFormatting() {
        let vm = makeViewModel()
        var video = makeVideo(id: "bulk-liked", channel: "Example Channel")
        video.likedAt = Date()
        vm.articles = [video]

        #expect(!StudioViewModel.permitsAutomaticTranscriptFormatting(
            for: video,
            likedFormattingEnabled: false
        ))
        #expect(StudioViewModel.permitsAutomaticTranscriptFormatting(
            for: video,
            likedFormattingEnabled: true
        ))
        #expect(!vm.allowsTranscriptFormatting(
            for: video,
            userInitiated: false,
            automaticFormattingAllowed: false
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: video,
            userInitiated: true,
            automaticFormattingAllowed: false
        ))
    }

    @Test("non-liked videos do not inherit the liked-history formatting gate")
    func nonLikedVideosIgnoreLikedHistoryConsent() {
        let video = makeVideo(id: "ordinary", channel: "Example Channel")

        #expect(StudioViewModel.permitsAutomaticTranscriptFormatting(
            for: video,
            likedFormattingEnabled: false
        ))
    }
}

// MARK: - Article Queue Management

@Suite("Article Queue Management")
@MainActor
struct ArticleQueueManagementTests {

    @Test("Adding article to articles array")
    func addArticle() {
        let vm = makeViewModel()
        let article = makeArticle(url: "https://test.com/post", title: "Test Post")
        vm.articles.append(article)
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].title == "Test Post")
    }

    @Test("removeArticle removes by id")
    func removeArticle() async throws {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        try await vm.storage.saveSource(a1)
        try await vm.storage.saveSource(a2)
        vm.articles = [a1, a2]
        await vm.removeArticle(id: a1.id)
        #expect(vm.articles.first(where: { $0.id == a1.id })?.isHidden == true)
        #expect(vm.articles.first(where: { $0.id == a2.id })?.isHidden == false)
    }

    @Test("removeArticle clears selection if removed article was selected")
    func removeArticleClearsSelection() async throws {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        try await vm.storage.saveSource(a1)
        vm.articles = [a1]
        vm.selectedArticleId = a1.id
        await vm.removeArticle(id: a1.id)
        #expect(vm.selectedArticleId == nil)
    }

    @Test("filteredActiveItems returns articles matching current tab")
    func filteredByTab() {
        let vm = makeViewModel()
        let article = makeArticle(sourceType: .article)
        let paper = makeArticle(url: "https://paper.com", title: "Paper", sourceType: .paper)
        let podcast = makeArticle(url: "https://pod.com", title: "Pod", sourceType: .podcast)
        vm.articles = [article, paper, podcast]

        vm.sidebarTab = .articles
        let articleTab = vm.activeTabArticles
        #expect(articleTab.allSatisfy { $0.sourceType == .article || $0.sourceType == .manual || $0.sourceType == .unclassified })

        vm.sidebarTab = .papers
        let paperTab = vm.activeTabArticles
        #expect(paperTab.count == 1)
        #expect(paperTab[0].sourceType == .paper)

        vm.sidebarTab = .podcasts
        let podTab = vm.activeTabArticles
        #expect(podTab.count == 1)
        #expect(podTab[0].sourceType == .podcast)
    }

    @Test("videos tab lists course videos too")
    func videosTabListsCourseVideos() {
        // The product owner, 2026-09-27: "show videos in both places": a lecture video is
        // listed under YouTube like any other, and on its course's page.
        let vm = makeViewModel()
        let standalone = makeArticle(url: "https://www.youtube.com/watch?v=AAAAAAAAAAA", title: "Standalone", sourceType: .video)
        let courseVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "Lecture 1",
            sourceType: .video,
            parentGroup: "Systems Biology"
        )
        vm.articles = [standalone, courseVideo]
        vm.courseMetadata = ["Systems Biology": CourseMetadata(title: "Systems Biology")]
        vm.sidebarTab = .videos

        #expect(Set(vm.activeTabArticles.map(\.id)) == Set([standalone.id, courseVideo.id]))
        #expect(vm.tabTotalCount == 2)
        // Filed under its course rather than a playlist, it is a flat row.
        #expect(vm.isFlatVideoRow(courseVideo))
        #expect(vm.sidebarTab(listing: courseVideo) == .videos)
    }

    @Test("course material has no Sources tab and no knowledge family")
    func courseMaterialHasNoTab() {
        let vm = makeViewModel()
        let lesson = makeArticle(url: "foreverlm://course/c1/lesson/1", title: "Lesson 1", sourceType: .course, parentGroup: "c1")
        vm.articles = [lesson]
        vm.courseMetadata = ["c1": CourseMetadata(title: "Course One")]

        #expect(vm.sidebarTab(listing: lesson) == nil)
        #expect(StudioSidebarTab.knowledgeTab(for: lesson) == nil)
        // No family can keep it from search and chat. Asked for the set
        // rather than set on the view model: `excludedKnowledgeTabs` persists
        // to UserDefaults.standard, which every MCP suite running beside this
        // one reads, and "every family excluded" failed 59 of their tests.
        #expect(vm.isSourceIncludedInKnowledge(lesson, excludedTabs: Set(StudioSidebarTab.allCases)))
    }

    private func makeReadyVideo(_ index: Int, parentGroup: String? = nil) -> StudioArticle {
        makeArticle(
            url: "https://www.youtube.com/watch?v=\(String(format: "%011d", index))",
            title: "Video \(index)",
            sourceType: .video,
            state: .ready,
            parentGroup: parentGroup
        )
    }

    @Test("videos tab pages its flat rows and keeps playlists whole")
    func videosTabPagesFlatRowsAndKeepsPlaylistsWhole() {
        let vm = makeViewModel()
        let standalone = (0..<45).map { makeReadyVideo($0) }
        let playlist = (100..<106).map { makeReadyVideo($0, parentGroup: "PL1") }
        vm.videoPlaylistMetadata["PL1"] = VideoPlaylistMetadata(title: "Lectures", playlistURL: "https://www.youtube.com/playlist?list=PL1")
        vm.articles = standalone + playlist
        vm.sidebarTab = .videos
        vm.displayLimit = 40

        let shown = vm.activeTabArticles
        #expect(shown.count == 46)
        #expect(shown.filter { $0.parentGroup == "PL1" }.count == 6)
        #expect(shown.filter { $0.parentGroup == nil }.count == 40)
        #expect(vm.hasMoreItems)
        #expect(vm.remainingItemCount == 5)
        #expect(vm.visibleSidebarSourceIDs.count == 46)

        vm.showMore()
        #expect(vm.activeTabArticles.count == 51)
        #expect(!vm.hasMoreItems)
    }

    @Test("inline playlist videos page with the flat rows")
    func inlinePlaylistVideosPageWithFlatRows() {
        let vm = makeViewModel()
        let liked = (0..<50).map { makeReadyVideo($0, parentGroup: "Liked") }
        vm.videoPlaylistMetadata["Liked"] = VideoPlaylistMetadata(
            title: "Liked videos",
            playlistURL: "https://www.youtube.com/playlist?list=LL",
            connectorKind: YouTubeImportSource.likedVideos.connectorKind
        )
        vm.articles = liked
        vm.sidebarTab = .videos
        vm.displayLimit = 40

        #expect(liked.allSatisfy { vm.isFlatVideoRow($0) })
        #expect(vm.activeTabArticles.count == 40)
        #expect(vm.hasMoreItems)
        #expect(vm.remainingItemCount == 10)
    }

    @Test("processing videos never consume the video page")
    func processingVideosNeverConsumeTheVideoPage() {
        let vm = makeViewModel()
        let ready = (0..<40).map { makeReadyVideo($0) }
        let processing = (200..<203).map { index in
            makeArticle(
                url: "https://www.youtube.com/watch?v=\(String(format: "%011d", index))",
                title: "Queued \(index)",
                sourceType: .video,
                state: .queued
            )
        }
        vm.articles = processing + ready
        vm.sidebarTab = .videos
        vm.displayLimit = 40

        #expect(vm.activeProcessingVideos.count == 3)
        #expect(vm.activeTabArticles.count == 43)
        #expect(!vm.hasMoreItems)
    }

    @Test("revealing a video beyond the page grows the page to reach it")
    func revealingVideoBeyondPageGrowsIt() {
        let vm = makeViewModel()
        vm.articles = (0..<50).map { makeReadyVideo($0) }
        vm.sidebarTab = .videos
        vm.displayLimit = 40
        let hidden = vm.pagedVideoRows[47]
        #expect(!vm.activeTabArticles.contains { $0.id == hidden.id })

        vm.revealSourceInSidebar(hidden)

        #expect(vm.displayLimit == 48)
        #expect(vm.activeTabArticles.contains { $0.id == hidden.id })
        #expect(vm.sidebarRevealRequest?.sourceID == hidden.id)
    }

    @Test("papers tab shows all papers regardless of PDF or metadata status")
    func papersTabShowsAll() {
        let vm = makeViewModel()
        var withPDF = makeArticle(url: "https://paper.com/complete", title: "Complete", sourceType: .paper)
        withPDF.localFilePath = "/tmp/complete.pdf"
        withPDF.author = "Doe"
        withPDF.journal = "Nature"
        withPDF.publishedYear = "2024"
        markPaperFullyReady(&withPDF)
        let withoutPDF = makeArticle(url: "https://paper.com/incomplete", title: "Incomplete", sourceType: .paper)

        vm.articles = [withPDF, withoutPDF]
        vm.sidebarTab = .papers

        #expect(vm.activeTabArticles.count == 2)
        #expect(vm.tabTotalCount == 2)
    }

    @Test("papers without PDF hides duplicate when PDF copy exists")
    func papersWithoutPDFHidesDuplicateWhenPDFCopyExists() throws {
        let vm = makeViewModel()
        let tempPDF = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: tempPDF) }

        var withPDF = makeArticle(
            url: "https://www.nature.com/articles/35016601",
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )
        withPDF.localFilePath = tempPDF.path
        withPDF.doi = "10.1038/35016601"
        markPaperFullyReady(&withPDF)

        var withoutPDF = makeArticle(
            url: "https://doi.org/10.1038/35016601",
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )
        withoutPDF.doi = "10.1038/35016601"

        vm.articles = [withoutPDF, withPDF]
        vm.sidebarTab = .papers

        #expect(vm.activePapersWithPDF.map(\.id) == [withPDF.id])
        #expect(vm.activePapersWithoutPDF.isEmpty)
    }

    @Test("papers without PDF hides ScienceDirect PII duplicate when PDF copy exists")
    func papersWithoutPDFHidesScienceDirectPIIDuplicateWhenPDFCopyExists() throws {
        let vm = makeViewModel()
        let tempPDF = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: tempPDF) }

        var withPDF = makeArticle(
            url: "Papers/1-s2.0-S0167488924001496-main.pdf",
            title: "Artificial mitochondrial transplantation (AMT) reverses aging of mesenchymal stromal cells",
            sourceType: .paper
        )
        withPDF.localFilePath = tempPDF.path
        withPDF.doi = "10.1016/j.bbamcr.2024.119806"
        markPaperFullyReady(&withPDF)

        let withoutPDF = makeArticle(
            url: "https://www.sciencedirect.com/science/article/pii/S0167488924001496",
            title: "Artificial mitochondrial transplantation (AMT) reverses aging of mesenchymal stromal cells - ScienceDirect",
            sourceType: .paper
        )

        vm.articles = [withoutPDF, withPDF]
        vm.sidebarTab = .papers

        #expect(
            StudioViewModel.paperPublisherIdentityKey(for: withPDF.url)
                == StudioViewModel.paperPublisherIdentityKey(for: withoutPDF.url)
        )
        #expect(vm.activePapersWithPDF.map(\.id) == [withPDF.id])
        #expect(vm.activePapersWithoutPDF.isEmpty)
    }

    @Test("paper duplicate review identifies exact extracted-content hashes")
    func paperDuplicateReviewUsesContentHashes() {
        var first = makeArticle(
            url: "Papers/local-copy.pdf",
            title: "Publisher title",
            sourceType: .paper
        )
        first.author = "Ada Researcher"
        first.journal = "Journal"
        first.publishedYear = "2026"
        let firstCompleted = first.completePaperMetadataExtractionAfterLLM()
        #expect(firstCompleted)
        first.paperContentSHA256 = String(repeating: "a", count: 64)
        var second = makeArticle(
            url: "https://repository.example.edu/unrelated-name.pdf",
            title: "Repository title with different metadata",
            sourceType: .paper
        )
        second.author = "Ada Researcher"
        second.journal = "Journal"
        second.publishedYear = "2026"
        let secondCompleted = second.completePaperMetadataExtractionAfterLLM()
        #expect(secondCompleted)
        second.paperContentSHA256 = first.paperContentSHA256
        var distinct = makeArticle(
            url: "Papers/distinct.pdf",
            title: "Distinct paper",
            sourceType: .paper
        )
        distinct.author = "Other Researcher"
        distinct.journal = "Other Journal"
        distinct.publishedYear = "2025"
        let distinctCompleted = distinct.completePaperMetadataExtractionAfterLLM()
        #expect(distinctCompleted)
        distinct.paperContentSHA256 = String(repeating: "b", count: 64)

        let group = StudioViewModel.firstPaperIdentityDuplicateGroup(in: [first, second, distinct])

        #expect(group?.map(\.id) == [first.id, second.id])
    }

    @Test("persisted paper preparation hydrates its duplicate fingerprint")
    func persistedPaperHydratesContentHash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFingerprintTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let raw = "Publisher header\n\nCanonical paper text"
        let clean = "Canonical paper text"
        let rawSHA256 = PaperContentPreparationService.sha256(raw)
        var paper = StudioArticle(
            url: "Papers/fingerprinted.pdf",
            title: "Fingerprinted paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let completed = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completed)
        try await storage.saveSource(paper)

        let sources = try await storage.loadSources()
        let reloaded = try #require(sources.first { $0.id == paper.id })
        #expect(reloaded.paperContentSHA256 == rawSHA256)
    }

    @Test("papers without PDF badge ignores current tab")
    func papersWithoutPDFBadgeIgnoresCurrentTab() async throws {
        let vm = makeViewModel()
        let tempPDF = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: tempPDF) }

        let article = makeArticle(url: "https://example.com/post", title: "Post", sourceType: .article)
        var withPDF = makeArticle(url: "https://paper.com/complete", title: "Complete", sourceType: .paper)
        withPDF.localFilePath = tempPDF.path
        markPaperFullyReady(&withPDF)
        let withoutPDF = makeArticle(url: "https://paper.com/incomplete", title: "Incomplete", sourceType: .paper)

        vm.articles = [article, withPDF, withoutPDF]
        vm.sidebarTab = .articles

        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 1)
    }

    @Test("papers without PDF badge ignores paywalled papers")
    func papersWithoutPDFBadgeIgnoresPaywalledPapers() async {
        let vm = makeViewModel()
        var paywalled = makeArticle(url: "https://paper.com/paywalled", title: "Paywalled", sourceType: .paper)
        paywalled.isPaywalled = true
        let missingPDF = makeArticle(url: "https://paper.com/missing", title: "Missing PDF", sourceType: .paper)

        vm.articles = [paywalled, missingPDF]
        vm.sidebarTab = .papers

        #expect(vm.activePapersWithoutPDF.map(\.id) == [missingPDF.id])
        #expect(vm.activePaywalledPapersWithoutPDF.map(\.id) == [paywalled.id])
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 1)
    }

    @Test("papers without PDF badge ignores a paper marked paywalled by its error message")
    func papersWithoutPDFBadgeIgnoresPaywallErrorMessage() async {
        let vm = makeViewModel()
        var paywalled = makeArticle(url: "https://paper.com/paywall-error", title: "Paywall Error", sourceType: .paper)
        paywalled.errorMessage = "paywall"
        let missingPDF = makeArticle(url: "https://paper.com/missing", title: "Missing PDF", sourceType: .paper)

        vm.articles = [paywalled, missingPDF]
        vm.sidebarTab = .papers

        #expect(vm.activePapersWithoutPDF.map(\.id) == [missingPDF.id])
        #expect(vm.activePaywalledPapersWithoutPDF.map(\.id) == [paywalled.id])
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 1)
    }

    @Test("paywall recheck candidates cover the whole catalog but only fetchable paywalled papers")
    func paywallRecheckCandidatesCoverCatalog() {
        let vm = makeViewModel()
        var first = makeArticle(url: "https://paper.com/first", title: "First", sourceType: .paper)
        first.isPaywalled = true
        var outsideSearch = makeArticle(url: "https://paper.com/outside", title: "Outside Search", sourceType: .paper)
        outsideSearch.isPaywalled = true
        var fetching = makeArticle(url: "https://paper.com/fetching-paywall", title: "Fetching", sourceType: .paper)
        fetching.isPaywalled = true
        fetching.state = .fetching
        var localOnly = makeArticle(url: "/tmp/paywalled.pdf", title: "Local", sourceType: .paper)
        localOnly.isPaywalled = true
        let ordinary = makeArticle(url: "https://paper.com/ordinary", title: "Ordinary", sourceType: .paper)

        vm.articles = [first, outsideSearch, fetching, localOnly, ordinary]
        vm.sidebarTab = .papers
        vm.searchText = "First"

        #expect(vm.filteredPaywalledPapersWithoutPDF.map(\.id) == [first.id])
        #expect(Set(vm.paywalledPapersEligibleForRecheck.map(\.id)) == Set([first.id, outsideSearch.id]))
    }

    @Test("papers needing PDF attention count matches bulk download candidates")
    func papersNeedingAttentionCountMatchesBulkDownloadCandidates() async throws {
        let vm = makeViewModel()
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        await warmLocalPathCache([tempPDF.path])

        var withPDF = makeArticle(
            url: "https://www.nature.com/articles/35016601",
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )
        withPDF.localFilePath = tempPDF.path
        withPDF.doi = "10.1038/35016601"
        markPaperFullyReady(&withPDF)

        var duplicateWithoutPDF = makeArticle(
            url: "https://doi.org/10.1038/35016601",
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )
        duplicateWithoutPDF.doi = "10.1038/35016601"

        let missingPDF = makeArticle(url: "https://paper.com/missing", title: "Missing PDF", sourceType: .paper)
        var fetching = makeArticle(url: "https://paper.com/fetching", title: "Fetching", sourceType: .paper)
        fetching.state = .fetching
        var paywalled = makeArticle(url: "https://paper.com/paywalled", title: "Paywalled", sourceType: .paper)
        paywalled.isPaywalled = true
        let localOnly = makeArticle(url: "/tmp/local-paper.pdf", title: "Local Only", sourceType: .paper)

        vm.articles = [duplicateWithoutPDF, withPDF, missingPDF, fetching, paywalled, localOnly]
        vm.sidebarTab = .papers

        // A stale local-only PDF also remains actionable: it cannot be fetched
        // from a publisher, but the row must stay visible so the learner can
        // reattach it. The DOI duplicate is hidden by the complete PDF copy.
        #expect(Set(vm.papersNeedingPDFAttention.map(\.id)) == [missingPDF.id, localOnly.id])
        #expect(Set(vm.activePapersWithoutPDF.map(\.id)) == [missingPDF.id, localOnly.id])
        #expect(vm.activePapersWithoutPDFTotalCount == vm.papersNeedingPDFAttention.count)

        // The auto paper check must apply the same duplicate dedup as the visible
        // list: a no-PDF paper that duplicates one we already have a PDF for is
        // hidden from the list, so auto-fetch must not count or retry it either.
        let snapshot = vm.articles
        let dedupKeysWithPDF = await Task.detached(priority: .utility) {
            StudioViewModel.paperDedupKeysForPapersWithPDF(in: snapshot)
        }.value
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                duplicateWithoutPDF,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: []
            ) == false
        )
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                missingPDF,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: []
            ) == true
        )
        var queuedTextlessWithPDF = withPDF
        queuedTextlessWithPDF.state = .queued
        queuedTextlessWithPDF.content = nil
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                queuedTextlessWithPDF,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: []
            ) == true,
            "A migrated textless paper must recover from its saved PDF even though its own dedup key is in the PDF set."
        )
        var queuedLocalPaper = makeArticle(
            url: tempPDF.path,
            title: "Local queued paper",
            sourceType: .paper
        )
        queuedLocalPaper.localFilePath = tempPDF.path
        queuedLocalPaper.state = .queued
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                queuedLocalPaper,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: []
            ) == true,
            "A local queued paper with a saved PDF must recover text without an HTTP URL."
        )
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                paywalled,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: []
            ) == true,
            "A queued textless paywall record gets one automatic readable-text repair pass."
        )
        paywalled.state = .error
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                paywalled,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: []
            ) == false,
            "A terminal paywall failure must not be retried every session."
        )
    }

    @Test("papers with a missing local PDF path still need PDF attention")
    func papersWithMissingLocalPDFNeedAttention() {
        let vm = makeViewModel()
        var stalePDF = makeArticle(
            url: "https://www.nature.com/articles/s43587-025-00999-9",
            title: "Replacement as an Aging Intervention",
            sourceType: .paper
        )
        stalePDF.localFilePath = "/tmp/missing-paper.pdf"
        stalePDF.errorMessage = "File not found."
        stalePDF.state = .error

        vm.articles = [stalePDF]
        vm.sidebarTab = .papers

        #expect(stalePDF.resolvedPDFPath == nil)
        #expect(vm.papersNeedingPDFAttention.map(\.id) == [stalePDF.id])
        // One stale path is not a storage outage, so nothing is suppressed.
        #expect(vm.unavailableRecordedPDFCount == 0)
    }

    /// Regression: after the macOS 27.0 upgrade, iCloud Drive rebuilt its local
    /// replica and hundreds of recorded paper PDFs stopped statting at once. The
    /// Papers tab reported 222 papers "needing attention" that already had PDFs,
    /// and pressing the download button (or an assistant calling
    /// download_papers_needing_attention) would have re-fetched them all from
    /// publishers, marking transient failures paywalled along the way.
    @Test("a mass recorded-PDF outage is not treated as papers needing attention")
    func massUnavailableRecordedPDFsAreNotAttention() async throws {
        let vm = makeViewModel()
        let presentPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: presentPDF)
        defer { try? FileManager.default.removeItem(at: presentPDF) }

        // 20 papers whose PDFs are recorded but whose files don't exist.
        var evicted: [StudioArticle] = []
        for i in 0..<20 {
            var paper = makeArticle(
                url: "https://paper.com/evicted-\(i)",
                title: "Evicted Paper \(i)",
                sourceType: .paper
            )
            paper.localFilePath = "/tmp/foreverlm-not-downloaded-\(UUID().uuidString).pdf"
            markPaperFullyReady(&paper)
            evicted.append(paper)
        }
        // One paper whose PDF really is on disk, and one that never had a PDF at all.
        var onDisk = makeArticle(url: "https://paper.com/on-disk", title: "On Disk", sourceType: .paper)
        onDisk.localFilePath = presentPDF.path
        markPaperFullyReady(&onDisk)
        let neverHadPDF = makeArticle(url: "https://paper.com/never", title: "Never Had PDF", sourceType: .paper)

        // Production warms these paths off-main before republishing the sidebar.
        // Make that completed background state explicit for this synchronous test.
        StudioArticle.warmResolvedLocalPathCache(
            forRawPaths: (evicted + [onDisk]).compactMap(\.localFilePath)
        )

        vm.articles = evicted + [onDisk, neverHadPDF]
        vm.sidebarTab = .papers

        // The evicted papers are held back, not queued for re-download…
        #expect(vm.unavailableRecordedPDFCount == evicted.count)
        #expect(vm.papersNeedingPDFAttention.map(\.id) == [neverHadPDF.id])
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 1)
        // …and they stay listed with the papers that have PDFs, not hidden entirely.
        #expect(vm.activePapersWithPDF.count == evicted.count + 1)

        let dedupKeysWithPDF = StudioViewModel.paperDedupKeysForPapersWithPDF(in: vm.articles)
        let unavailableIDs = StudioViewModel.unavailableRecordedPaperPDFIDs(in: vm.articles)
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                evicted[0],
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: unavailableIDs
            ) == false
        )
        #expect(
            StudioViewModel.paperNeedsAutoFetch(
                neverHadPDF,
                alreadyAttempted: [],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: unavailableIDs
            ) == true
        )
    }

    /// Regression: on a second Mac whose paper files had not arrived, one paper
    /// with a recorded (non-PDF) path and no ingestion attestation was surfaced
    /// by the attention list for its metadata, but the row labelled it
    /// "PDF needed" and offered "Choose PDF" — because the row asked
    /// `cachedHasUsablePDF` directly while every list consumer used the
    /// storage-degraded answer. Downloading was the wrong remedy: the file was
    /// on the other Mac.
    @Test("row labels use the same PDF availability as the paper lists")
    func rowAvailabilityMatchesListAvailability() throws {
        let vm = makeViewModel()

        // Enough missing recorded paths to put the library in the degraded state.
        var evicted: [StudioArticle] = []
        for i in 0..<20 {
            var paper = makeArticle(
                url: "https://paper.com/evicted-\(i)",
                title: "Evicted Paper \(i)",
                sourceType: .paper
            )
            paper.localFilePath = "/tmp/foreverlm-not-downloaded-\(UUID().uuidString).pdf"
            markPaperFullyReady(&paper)
            evicted.append(paper)
        }
        // A paper whose recorded path is an archived HTML capture, with complete
        // metadata but no attestation to prove it passed the ingestion gate.
        var unattested = makeArticle(
            url: "https://pmc.ncbi.nlm.nih.gov/articles/PMC12918445/",
            title: "Programmed mitophagy at the oocyte-to-zygote transition - PMC",
            sourceType: .paper
        )
        unattested.localFilePath = "/tmp/foreverlm-archive-\(UUID().uuidString)/article.html"
        unattested.author = "Ada Researcher"
        unattested.journal = "Nature cell biology"
        unattested.publishedYear = "2026"

        StudioArticle.warmResolvedLocalPathCache(
            forRawPaths: (evicted + [unattested]).compactMap(\.localFilePath)
        )

        vm.articles = evicted + [unattested]
        vm.sidebarTab = .papers

        #expect(!unattested.hasPaperIngestionAttestation)
        #expect(vm.papersNeedingPDFAttention.map(\.id) == [unattested.id])
        // The list holds it back from the download flows, so the row must not
        // tell the learner its PDF is what is missing.
        #expect(vm.displayHasUsablePDF(unattested))
        #expect(
            unattested.paperAttentionReason(hasUsablePDF: vm.displayHasUsablePDF(unattested))
                == .metadataIncomplete
        )
    }

    @Test("a few stale PDF paths stay in the attention flow")
    func fewStalePDFPathsStayInAttention() async throws {
        let vm = makeViewModel()
        let presentPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: presentPDF)
        defer { try? FileManager.default.removeItem(at: presentPDF) }

        // Below the floor: a handful of genuinely stale paths among many good
        // ones must keep their existing "re-resolve me" behavior.
        var stale: [StudioArticle] = []
        for i in 0..<3 {
            var paper = makeArticle(
                url: "https://paper.com/stale-\(i)",
                title: "Stale Paper \(i)",
                sourceType: .paper
            )
            paper.localFilePath = "/tmp/foreverlm-stale-\(UUID().uuidString).pdf"
            markPaperFullyReady(&paper)
            stale.append(paper)
        }
        var good: [StudioArticle] = []
        for i in 0..<12 {
            var paper = makeArticle(
                url: "https://paper.com/good-\(i)",
                title: "Good Paper \(i)",
                sourceType: .paper
            )
            paper.localFilePath = presentPDF.path
            markPaperFullyReady(&paper)
            good.append(paper)
        }

        await warmLocalPathCache(stale.compactMap(\.localFilePath) + [presentPDF.path])

        vm.articles = stale + good
        vm.sidebarTab = .papers

        #expect(vm.unavailableRecordedPDFCount == 0)
        #expect(Set(vm.papersNeedingPDFAttention.map(\.id)) == Set(stale.map(\.id)))
    }

    @Test("processing papers are separate from papers needing attention")
    func processingPapersAreSeparateFromAttention() async {
        let vm = makeViewModel()
        let processing = makeArticle(
            url: "https://paper.com/processing",
            title: "Processing",
            sourceType: .paper
        )
        let enriching = makeArticle(
            url: "https://paper.com/enriching",
            title: "Metadata lookup",
            sourceType: .paper
        )
        let needsAttention = makeArticle(
            url: "https://paper.com/missing",
            title: "Missing PDF",
            sourceType: .paper
        )
        var failed = makeArticle(
            url: "https://paper.com/failed",
            title: "Failed ingestion",
            sourceType: .paper
        )
        failed.failPaperIngestionMetadata("Paper ingestion failed: test")

        vm.articles = [processing, enriching, needsAttention, failed]
        vm.sidebarTab = .papers
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 4)

        vm.resolvingPaperPDFIds.insert(processing.id)
        // A newly imported PDF enters the broad enrichment flow before title
        // lookup, deterministic metadata APIs, or the narrower AI extractor.
        vm.paperMetadataEnrichmentInFlight.insert(enriching.id)
        // A task may still be unwinding after it publishes a terminal error.
        // That paper belongs in attention, never under a processing spinner.
        vm.extractingPaperMetadataIds.insert(failed.id)

        #expect(vm.processingPaperIDs == [processing.id, enriching.id])
        #expect(Set(vm.activeProcessingPapers.map(\.id)) == [processing.id, enriching.id])
        #expect(Set(vm.papersNeedingPDFAttention.map(\.id)) == [needsAttention.id, failed.id])
        #expect(vm.activePapersWithoutPDFTotalCount == 2)
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 2)
        #expect(Set(vm.activeTabArticles.map(\.id)) == [processing.id, enriching.id, needsAttention.id, failed.id])
    }

    @Test("published-version identity lookup does not keep a ready paper processing")
    func publishedVersionIdentityLookupIsNotPaperIngestion() {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://preprints.org/manuscript/ready-paper",
            title: "Ready preprint",
            sourceType: .paper
        )
        vm.articles = [paper]

        // This optional catalog lookup can continue after the PDF-derived
        // metadata is complete. It must not resurrect the ingestion spinner or
        // move the ready row back into the Processing section.
        vm.publishedVersionResolutionInFlight.insert(paper.id)

        #expect(vm.processingPaperIDs.isEmpty)
        #expect(vm.activeProcessingPapers.isEmpty)
        #expect(vm.paperProcessingStepLabel(for: paper) == nil)
    }

    @Test("a newly added paper is processing before its first network step starts")
    func pendingPaperIsProcessingImmediately() {
        let vm = makeViewModel()
        let pending = makeArticle(
            url: "https://paper.com/newly-added",
            title: "Newly added paper",
            sourceType: .paper
        )
        vm.articles = [pending]
        vm.sidebarTab = .papers
        vm.pendingPaperProcessingIds.insert(pending.id)

        #expect(vm.activeProcessingPapers.map(\.id) == [pending.id])
        #expect(vm.papersNeedingPDFAttention.isEmpty)
        #expect(vm.activePapersWithPDF.isEmpty)
    }

    @Test("processing paper labels name the active ingestion step")
    func processingPaperLabelsNameActiveStep() {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "https://paper.com/processing-step",
            title: "Processing step",
            sourceType: .paper
        )
        vm.articles = [paper]

        vm.pendingPaperProcessingIds.insert(paper.id)
        #expect(vm.paperProcessingStepLabel(for: paper) == "Waiting to find PDF…")

        vm.pendingPaperProcessingIds.remove(paper.id)
        vm.resolvingPaperPDFIds.insert(paper.id)
        #expect(vm.paperProcessingStepLabel(for: paper) == "Finding PDF…")

        vm.paperProcessingSteps[paper.id] = "Cleaning up paper text 2/4…"
        #expect(vm.paperProcessingStepLabel(for: paper) == "Cleaning up paper text 2/4…")

        vm.paperProcessingSteps.removeValue(forKey: paper.id)
        vm.resolvingPaperPDFIds.remove(paper.id)
        vm.extractingPaperMetadataIds.insert(paper.id)
        #expect(vm.paperProcessingStepLabel(for: paper) == "Extracting paper metadata…")

        paper.failPaperIngestionMetadata("Paper ingestion failed: test")
        #expect(vm.paperProcessingStepLabel(for: paper) == nil)
    }

    @Test("a caption left behind by an overlapping pass never spins a finished paper")
    func orphanedProcessingCaptionDoesNotSpinFinishedPaper() {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://www.nature.com/articles/orphaned-caption",
            title: "Sleep pressure accumulates in a voltage-gated lipid peroxidation memory",
            sourceType: .paper
        )
        vm.articles = [paper]

        // The attach flow published this caption, a direct extraction started
        // underneath it and restored it on exit after the attach flow had
        // already left. Nothing owns the row any more: the label must be nil,
        // the row must stay out of Processing, and the idle sweep must drop it.
        vm.paperProcessingSteps[paper.id] = "Looking up paper metadata…"

        #expect(vm.paperProcessingStepLabel(for: paper) == nil)
        #expect(vm.processingPaperIDs.isEmpty)
        #expect(!vm.hasActivePaperProcessingWork(paper.id))

        vm.dropPaperProcessingStepIfIdle(paper.id)
        #expect(vm.paperProcessingSteps[paper.id] == nil)

        // While a pass still owns the paper the caption stays and is shown.
        vm.paperProcessingSteps[paper.id] = "Extracting paper metadata…"
        vm.extractingPaperMetadataIds.insert(paper.id)
        vm.dropPaperProcessingStepIfIdle(paper.id)
        #expect(vm.paperProcessingSteps[paper.id] == "Extracting paper metadata…")
        #expect(vm.paperProcessingStepLabel(for: paper) == "Extracting paper metadata…")

        vm.extractingPaperMetadataIds.remove(paper.id)
        vm.dropPaperProcessingStepIfIdle(paper.id)
        #expect(vm.paperProcessingSteps[paper.id] == nil)
        #expect(vm.paperProcessingStepLabel(for: paper) == nil)
    }

    @Test("a failed ingestion with an attached PDF needs attention")
    func failedPaperWithPDFNeedsAttention() async throws {
        let vm = makeViewModel()
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-paper-\(UUID().uuidString).pdf")
        try Data().write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }

        var failed = makeArticle(
            url: "https://paper.com/cleanup-failed",
            title: "Cleanup failed",
            sourceType: .paper
        )
        failed.localFilePath = pdf.path
        failed.failPaperIngestionMetadata(
            "Paper ingestion failed during Source Content Cleanup: The network connection was lost."
        )
        StudioArticle.warmResolvedLocalPathCache(forRawPaths: [pdf.path])

        vm.articles = [failed]
        vm.sidebarTab = .papers
        // The extraction task may still be unwinding when it publishes the
        // error. Terminal state must win over every transient processing set.
        vm.extractingPaperMetadataIds.insert(failed.id)

        #expect(vm.activeProcessingPapers.isEmpty)
        #expect(vm.activePapersWithPDF.isEmpty)
        #expect(vm.papersNeedingPDFAttention.map(\.id) == [failed.id])
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 1)
        #expect(vm.activeTabArticles.map(\.id) == [failed.id])
    }

    @Test("deferred paper preparation does not require user attention")
    func deferredPaperPreparationDoesNotRequireUserAttention() async throws {
        let vm = makeViewModel()
        let pdf = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: pdf) }

        var metadataOnly = makeArticle(
            url: "https://paper.com/metadata-only",
            title: "Metadata only",
            sourceType: .paper
        )
        metadataOnly.localFilePath = pdf.path
        metadataOnly.author = "Ada Researcher"
        metadataOnly.journal = "Nature Aging"
        metadataOnly.publishedYear = "2026"
        let metadataAttested = metadataOnly.completePaperMetadataExtractionAfterLLM()
        #expect(metadataAttested)

        var cleanupOnly = makeArticle(
            url: "https://paper.com/cleanup-only",
            title: "Cleanup only",
            sourceType: .paper
        )
        cleanupOnly.localFilePath = pdf.path
        let raw = "Header\n\nCleaned body.\n\nReferences"
        let clean = "Cleaned body."
        cleanupOnly.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        cleanupOnly.state = .ready

        var awaitingListen = makeArticle(
            url: "https://paper.com/awaiting-listen",
            title: "Awaiting Listen preparation",
            sourceType: .paper
        )
        awaitingListen.localFilePath = pdf.path
        markPaperFullyReady(&awaitingListen)
        awaitingListen.paperListenableContentReady = false

        var fullyReady = makeArticle(
            url: "https://paper.com/fully-ready",
            title: "Fully ready",
            sourceType: .paper
        )
        fullyReady.localFilePath = pdf.path
        markPaperFullyReady(&fullyReady)

        StudioArticle.warmResolvedLocalPathCache(forRawPaths: [pdf.path])
        vm.articles = [metadataOnly, cleanupOnly, awaitingListen, fullyReady]
        vm.sidebarTab = .papers

        #expect(!metadataOnly.hasSuccessfulPaperIngestion)
        #expect(!cleanupOnly.hasSuccessfulPaperIngestion)
        #expect(awaitingListen.isPaperReadyForListenPreparation)
        #expect(!awaitingListen.hasSuccessfulPaperIngestion)
        #expect(fullyReady.hasSuccessfulPaperIngestion)
        #expect(vm.papersNeedingPDFAttention.map(\.id) == [cleanupOnly.id])
        #expect(Set(vm.activePapersWithPDF.map(\.id)) == [
            metadataOnly.id,
            awaitingListen.id,
            fullyReady.id,
        ])
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 1)
        #expect(!ArticleSpeechContent.canAttemptRead(metadataOnly))
        #expect(!ArticleSpeechContent.canAttemptRead(cleanupOnly))
        // Listen prepares on demand (2026-09-24): a paper whose text is final
        // offers Listen before any narration derivative exists.
        #expect(ArticleSpeechContent.canAttemptRead(awaitingListen))
        #expect(ArticleSpeechContent.canAttemptRead(fullyReady))
    }

    @Test("paper cleanup failures explain the purpose and keep the failure detail")
    func paperCleanupFailureMessageIsActionable() {
        var paper = makeArticle(
            url: "https://paper.com/cleanup-message",
            title: "Cleanup message",
            sourceType: .paper
        )
        let currentMessage = StudioArticle.paperContentCleanupFailureMessage("Service unavailable.")
        #expect(currentMessage.contains("sounds natural when you listen"))
        #expect(currentMessage.contains("uses fewer tokens"))
        paper.failPaperIngestionMetadata(currentMessage)
        #expect(paper.isPaperContentCleanupFailure)
        #expect(paper.paperContentCleanupFailureDetail == "Service unavailable.")
    }

    @Test("An empty balance parks a source; a real failure does not")
    func emptyBalancePauseIsDistinguishedFromFailure() {
        var pausedPaper = makeArticle(
            url: "https://paper.com/paused",
            title: "Paused",
            sourceType: .paper
        )
        pausedPaper.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage(
                PaperContentPreparationService.contentCleanupCreditsPausedMessage
            )
        )
        #expect(pausedPaper.isPausedByEmptyAIBalance)

        var brokenPaper = makeArticle(
            url: "https://paper.com/broken",
            title: "Broken",
            sourceType: .paper
        )
        brokenPaper.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage("The network connection was lost.")
        )
        #expect(!brokenPaper.isPausedByEmptyAIBalance)

        // The article pipeline wraps the service's own wording in its stage
        // prefix; the paused state is the same fact either way.
        var pausedArticle = makeArticle(url: "https://blog.com/paused", title: "Paused article")
        pausedArticle.state = .error
        pausedArticle.errorMessage = "Article ingestion failed during Source Content Cleanup: "
            + "Your ForeverLM AI balance is empty — top up in Settings to continue."
        #expect(pausedArticle.isPausedByEmptyAIBalance)

        // A source that never stopped is not waiting on a top-up, whatever an
        // older message says.
        var readyArticle = pausedArticle
        readyArticle.state = .ready
        #expect(!readyArticle.isPausedByEmptyAIBalance)
    }

    /// The reported bug: cleanup stopped for want of balance, the learner topped
    /// up, and the row kept offering the same Top Up button. The staged
    /// extraction is intact, so the balance returning must put the source back
    /// on the durable cleanup queue instead of waiting to be clicked.
    @Test("A restored balance resumes the paper whose cleanup it paused")
    func restoredBalanceResumesPausedPaperCleanup() async throws {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "https://www.nature.com/articles/paused-cleanup",
            title: "Paused cleanup",
            sourceType: .paper
        )
        paper.author = "Ada Researcher"
        paper.journal = "Nature"
        paper.publishedYear = "2026"
        let raw = "Running head\n\nThe result and its mechanism.\n\nReferences"
        paper.stagePaperContentCleanup(raw: raw)
        let didExtract = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didExtract)
        // Exactly how the pipeline parks a paper when the proxy refuses the
        // cleanup call: attested metadata, staged raw, no queue row.
        paper.state = .error
        paper.errorMessage = StudioArticle.paperContentCleanupFailureMessage(
            PaperContentPreparationService.contentCleanupCreditsPausedMessage
        )
        try await vm.storage.saveSource(paper)
        paper.discardPersistedPaperContentFromMemory()
        vm.articles = [paper]

        let queuedWhileParked = try await vm.storage.canonicalContentCleanupQueueCount()
        #expect(queuedWhileParked == 0)

        // Still empty: nothing to resume with, so nothing moves.
        let resumedWhileEmpty = await vm.resumeSourcesPausedByEmptyAIBalance(creditsAreEmpty: true)
        #expect(resumedWhileEmpty == 0)
        #expect(vm.articles[0].state == .error)

        let resumedAfterTopUp = await vm.resumeSourcesPausedByEmptyAIBalance(creditsAreEmpty: false)
        #expect(resumedAfterTopUp == 1)
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
        #expect(!vm.articles[0].isPausedByEmptyAIBalance)
        // The whole point: the drain can see it again.
        let nextCandidate = try await vm.storage.nextCanonicalContentCleanupCandidate()
        let candidate = try #require(nextCandidate)
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.raw == raw)
        // Cleanup has not run yet, so nothing may claim the ingestion finished.
        #expect(!vm.articles[0].hasCompletedPaperContentCleanup)
    }

    @Test("A persisted article cleanup timeout repairs itself without a click")
    func persistedArticleCleanupTimeoutResumesAutomatically() async throws {
        let vm = makeViewModel()
        let raw = "Navigation\n\nA complete article body.\n\nPublisher footer"
        var article = makeArticle(
            url: "https://example.com/timed-out-cleanup",
            title: "Timed-out cleanup"
        )
        article.stageArticleContentCleanup(raw: raw)
        article.state = .error
        article.errorMessage =
            "Article ingestion failed during Source Content Cleanup: The request timed out."
        try await vm.storage.saveSource(article)
        article.discardPersistedArticleContentHandoff()
        vm.articles = [article]

        let resumed = await vm.resumeSourcesAfterTransientCleanupFailures()

        #expect(resumed == 1)
        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].errorMessage == nil)
        let candidate = try #require(try await vm.storage.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        #expect(candidate.raw == raw)
        #expect(candidate.isPendingIngestion)
    }

    /// The relaxed metadata gate has to reach the backlog too: papers an earlier
    /// build failed over a blank venue already carry a completed extraction and
    /// canonical text, so they are promoted with no model call — which is the only
    /// way they can recover at all while the AI balance is empty.
    @Test("Papers failed over a blank venue are attested without spending AI credits")
    func blankVenueBacklogIsAttestedWithoutExtraction() async throws {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "/Users/me/binder-design.pdf",
            title: "Autonomous de novo protein binder design",
            sourceType: .paper
        )
        paper.author = "Claude Science; Amir Shanehsazzadeh"
        paper.journal = StudioArticle.unknownPaperJournal
        paper.publishedYear = "2026"
        let raw = "Header\n\nCanonical binder text.\n\nReferences"
        let clean = "Canonical binder text."
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        paper.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["venue"])
        )
        vm.articles = [paper]
        vm.sidebarTab = .papers

        await vm.attestPapersFailedOnBlankMetadata([paper.id])

        let healed = try #require(vm.articles.first)
        #expect(healed.paperIngestionMethod == .llm)
        #expect(healed.state == .ready)
        #expect(healed.errorMessage == nil)
        #expect(healed.isPaperReadyForListenPreparation)
        #expect(healed.paperAttentionReason(hasUsablePDF: true) == nil)
        // The blank stays a blank: the venue is still editable, just not an error.
        #expect(healed.missingRequiredPaperMetadataFields == ["venue"])
    }

    @Test("Filling in the missing metadata by hand clears the extraction failure")
    func manualMetadataClearsPaperIngestionFailure() async throws {
        let vm = makeViewModel()
        var thesis = makeArticle(
            url: "/Users/me/ForeverLM-Dropped-thesis.pdf",
            title: "ForeverLM-Dropped-thesis",
            sourceType: .paper
        )
        // Cleanup already produced canonical text; only the required metadata is
        // outstanding, so the manual save finishes ingestion without any AI call.
        let raw = "Cover sheet\n\nThesis text.\n\nReferences"
        let clean = "Thesis text."
        thesis.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        thesis.author = "Zara Holt"
        thesis.journal = StudioArticle.unknownPaperJournal
        thesis.publishedYear = StudioArticle.unknownPaperYear
        thesis.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["venue", "year"])
        )
        vm.articles = [thesis]
        vm.sidebarTab = .papers

        let saved = await vm.updateSourceDetails(
            id: thesis.id,
            title: "Targeting Elevated Intracellular Sodium",
            author: "Zara Holt",
            journal: "PhD thesis, University of Edinburgh",
            publishedYear: "2025"
        )
        #expect(saved)

        let updated = try #require(vm.articles.first)
        #expect(updated.paperIngestionMethod == .manual)
        #expect(updated.hasPaperIngestionAttestation)
        #expect(updated.state == .ready)
        #expect(updated.errorMessage == nil)
        #expect(updated.paperAttentionReason(hasUsablePDF: true) == nil)
    }

    /// The reported bug: pressing Save in Edit Details sat on a disabled button
    /// for the whole "Cleaning up paper text…" pass. The metadata is on disk in
    /// two SQLite writes; the model pass belongs to the sidebar's Processing
    /// section, not to the dialog.
    @Test("Saving manual metadata returns before the paper text cleanup runs")
    func manualMetadataSaveDoesNotWaitForCleanup() async throws {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "/Users/me/ForeverLM-Dropped-uncleaned.pdf",
            title: "ForeverLM-Dropped-uncleaned",
            sourceType: .paper
        )
        // Raw text only: cleanup has never produced canonical content.
        paper.content = "Cover sheet\n\nPaper text.\n\nReferences"
        paper.author = StudioArticle.unknownPaperAuthor
        paper.journal = StudioArticle.unknownPaperJournal
        paper.publishedYear = StudioArticle.unknownPaperYear
        paper.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["author", "venue", "year"])
        )
        vm.articles = [paper]
        vm.sidebarTab = .papers

        vm.articles[0].author = "Jun Gao"
        vm.articles[0].journal = "Nature Neuroscience"
        vm.articles[0].publishedYear = "2026"
        let cleanup = await vm.completePaperIngestionAfterManualMetadata(id: paper.id)

        // Back already, with the attestation saved and the cleanup still owed.
        let attested = try #require(vm.articles.first)
        #expect(attested.paperIngestionMethod == .manual)
        #expect(attested.errorMessage == nil)
        #expect(!attested.hasCompletedPaperContentCleanup)
        let stored = try #require(try await vm.storage.loadPersistedSources(ids: [paper.id]).first)
        #expect(stored.paperIngestionMethod == .manual)

        // The pass itself shows up where every other in-flight paper does.
        let task = try #require(cleanup)
        #expect(vm.pendingPaperProcessingIds.contains(paper.id))
        #expect(vm.activeProcessingPapers.map(\.id) == [paper.id])
        #expect(vm.paperProcessingStepLabel(for: attested) == "Cleaning up paper text…")

        // A second Save while the first is cleaning does not start a second pass.
        let duplicate = await vm.completePaperIngestionAfterManualMetadata(id: paper.id)
        #expect(duplicate == nil)

        // Keep the test offline: the model pass is covered by ingestion tests.
        task.cancel()
        await task.value
        #expect(!vm.pendingPaperProcessingIds.contains(paper.id))
        #expect(vm.paperProcessingStepLabel(for: vm.articles[0]) == nil)
        #expect(vm.articles[0].paperIngestionMethod == .manual)
    }

    @Test("Fix moves a cleanup failure back to Processing immediately")
    func fixingPaperCleanupStartsProcessing() async {
        let vm = makeViewModel()
        var failed = makeArticle(
            url: "https://paper.com/fix-cleanup",
            title: "Fix cleanup",
            sourceType: .paper
        )
        failed.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage("Temporary failure.")
        )
        vm.articles = [failed]
        vm.sidebarTab = .papers

        let repairTask = vm.fixPaperContentCleanup(for: failed.id)

        #expect(vm.articles[0].state == .queued)
        #expect(vm.pendingPaperProcessingIds.contains(failed.id))
        #expect(vm.activeProcessingPapers.map(\.id) == [failed.id])
        #expect(vm.papersNeedingPDFAttention.isEmpty)

        // Keep this state-transition test deterministic and offline. The repair
        // pipeline itself is covered by paper ingestion tests.
        if let repairTask {
            repairTask.cancel()
            await repairTask.value
        }
        #expect(vm.articles[0].state == .error)
        #expect(!vm.pendingPaperProcessingIds.contains(failed.id))
    }

    @Test("Attachment failures report the persisted ingestion stage")
    func attachmentFailureReportsPersistedStage() {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper
        )
        paper.author = "Ada Researcher"
        // Hoisted: `attestPaperMetadataExtractionAfterLLM` mutates, and the
        // #expect macro evaluates its argument through an immutable binding.
        let didAttest = paper.attestPaperMetadataExtractionAfterLLM()
        #expect(didAttest)
        let message = StudioArticle.paperContentCleanupFailureMessage("Temporary failure.")
        paper.failPaperContentCleanup(message)
        vm.articles = [paper]

        #expect(vm.stalledPaperIngestionError(for: paper.id).localizedDescription == message)
    }

    @Test("Manual PDF attachment cancels browser discovery ownership")
    func manualAttachmentCancelsBrowserDiscovery() async {
        let vm = makeViewModel()
        let articleID = "paper-under-browser-discovery"
        let browserTask = Task<SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF, Error> {
            try await Task.sleep(for: .seconds(30))
            return .init(file: URL(fileURLWithPath: "/tmp/late-browser.pdf"), sourceURL: nil)
        }
        vm.activePaperBrowserAttemptIDs[articleID] = UUID()
        vm.activePaperBrowserTasks[articleID] = browserTask
        vm.resolvingPaperPDFIds.insert(articleID)
        vm.pendingPaperProcessingIds.insert(articleID)
        vm.autoFetchPaperQueue.append(articleID)
        vm.paperProcessingSteps[articleID] = "Opening paper page…"
        vm.paperDownloadStep = "Opening paper page..."

        vm.cancelPaperPDFDiscovery(for: articleID)

        #expect(vm.activePaperBrowserAttemptIDs[articleID] == nil)
        #expect(vm.activePaperBrowserTasks[articleID] == nil)
        #expect(!vm.resolvingPaperPDFIds.contains(articleID))
        #expect(!vm.pendingPaperProcessingIds.contains(articleID))
        #expect(!vm.autoFetchPaperQueue.contains(articleID))
        #expect(vm.paperProcessingSteps[articleID] == nil)
        #expect(vm.paperDownloadStep.isEmpty)
        do {
            _ = try await browserTask.value
            Issue.record("Expected browser task cancellation")
        } catch is CancellationError {
            // Expected: a late browser result cannot race the uploaded PDF.
        } catch {
            Issue.record("Unexpected browser cancellation error: \(error)")
        }
    }

    // MARK: Waiting for a source's fetch

    @Test("Waiting for a source fetch returns at once when none is running")
    func waitForSourceFetchWhenIdle() async {
        let vm = makeViewModel()
        #expect(await vm.waitForSourceFetch("idle-source", timeout: .seconds(5)))
    }

    @Test("Waiting for a source fetch returns true when the fetch ends")
    func waitForSourceFetchEnds() async {
        let vm = makeViewModel()
        vm.contentFetchInFlight.insert("fetching-source")
        let waiter = Task { @MainActor in
            await vm.waitForSourceFetch("fetching-source", timeout: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(100))
        vm.contentFetchInFlight.remove("fetching-source")
        #expect(await waiter.value)
    }

    @Test("Waiting for a source fetch returns false at the timeout")
    func waitForSourceFetchTimesOut() async {
        let vm = makeViewModel()
        vm.contentFetchInFlight.insert("stuck-source")
        let ended = await vm.waitForSourceFetch("stuck-source", timeout: .milliseconds(150))
        #expect(!ended)
    }

    @Test("Waiting for a source fetch ends promptly when the task is cancelled")
    func waitForSourceFetchCancels() async {
        let vm = makeViewModel()
        vm.contentFetchInFlight.insert("cancelled-source")
        let waiter = Task { @MainActor in
            await vm.waitForSourceFetch("cancelled-source", timeout: .seconds(60))
        }
        try? await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        #expect(!(await waiter.value))
    }

}
