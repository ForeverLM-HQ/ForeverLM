import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - Helpers

func makeArticle(
    url: String = "https://example.com",
    title: String = "Test",
    sourceType: StudioSourceType = .article,
    state: StudioArticleState = .queued,
    discoveryOrigin: DiscoveryOrigin? = nil,
    parentGroup: String? = nil,
    sortIndex: Int? = nil,
    id: String? = nil
) -> StudioArticle {
    var a = StudioArticle(url: url, title: title, sourceType: sourceType, discoveryOrigin: discoveryOrigin, parentGroup: parentGroup, id: id)
    a.state = state
    a.courseSortIndex = sortIndex
    return a
}

func makeTempPDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data().write(to: url)
    return url
}

func makeReadableTempPDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    return url
}

/// Captures the synced center-tab layout and returns a restore closure for
/// `defer`, so tests that rearrange tabs don't leak into real preferences.
func capturedCenterTabLayout() -> () -> Void {
    let prior = UserDefaults.standard.stringArray(forKey: "studio.centerTabGroups.v1")
    return {
        if let prior {
            UserDefaults.standard.set(prior, forKey: "studio.centerTabGroups.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "studio.centerTabGroups.v1")
        }
    }
}

/// Captures all preferences used as the template for a newly opened Studio
/// window, so multi-window tests cannot change the developer's real workspace.
func capturedStudioWindowTemplate() -> () -> Void {
    let keys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]
    let prior = keys.reduce(into: [String: Any]()) { result, key in
        result[key] = UserDefaults.standard.object(forKey: key)
    }
    return {
        for key in keys {
            if let value = prior[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// Takes a paper through the same stages a real ingestion does: attestable
/// metadata, a committed canonical derivative, and the durable Listen result.
/// Storage rejects a `.ready` paper that skipped any of them. Pass `content`
/// when the test searches or renders the body; the default stands in for text
/// the test never reads.
func markPaperFullyReady(_ paper: inout StudioArticle, content: String? = nil) {
    paper.author = paper.author ?? "Ada Researcher"
    paper.journal = paper.journal ?? "Journal of Complete Papers"
    paper.publishedYear = paper.publishedYear ?? "2026"
    let clean = content ?? "Canonical text for \(paper.id)."
    let raw = "Header\n\n\(clean)\n\nReferences"
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
    precondition(paper.completePaperMetadataExtractionAfterLLM())
    paper.paperListenableContentReady = true
}

func warmLocalPathCache(_ rawPaths: [String]) async {
    await Task.detached(priority: .utility) {
        for path in rawPaths {
            _ = StudioArticle.resolvedLocalPath(forRawPath: path)
        }
    }.value
}

@Suite("Paper PDF import presentation")
@MainActor
struct PaperPDFImportPresentationTests {
    // Sync clears the resolved-path cache when another Mac's text lands. The
    // reload changes nothing a row shows, so nothing warmed the cache again and
    // the Reader showed a paper's stored text instead of its PDF until relaunch.
    @Test("A cleared path cache is warmed again, so a paper's PDF stays readable")
    func clearedPathCacheIsWarmedAgain() async throws {
        let vm = makeViewModel()
        let pdf = try makeTempPDF()
        defer {
            StudioArticle.invalidateResolvedPathCache(forRawPaths: [pdf.path])
            try? FileManager.default.removeItem(at: pdf)
        }
        var paper = makeArticle(url: "https://example.com/oocyte-paper", title: "Oocytes", sourceType: .paper)
        paper.localFilePath = pdf.path
        StudioArticle.warmResolvedLocalPathCache(forRawPaths: [pdf.path])
        vm.articles = [paper]
        #expect(paper.cachedResolvedPDFPath == pdf.path)
        // Let the warm that assignment scheduled (400 ms debounce) finish, so
        // only the clear's own warm can bring the path back below.
        try await Task.sleep(for: .seconds(1))

        // What `invalidateAllResolvedPathCaches()` does, for this path only:
        // a library-wide clear would race the other suites' cached PDFs.
        StudioArticle.invalidateResolvedPathCache(forRawPaths: [pdf.path])
        #expect(paper.cachedResolvedPDFPath == nil)
        NotificationCenter.default.post(name: .resolvedPathCacheDidClear, object: nil)

        let deadline = ContinuousClock.now + .seconds(5)
        while paper.cachedResolvedPDFPath == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(paper.cachedResolvedPDFPath == pdf.path)
    }

    @Test("A background-style Finder drop does not implicitly open PDFKit")
    func importWithoutReaderSelection() async throws {
        let vm = makeViewModel()
        let alreadyOpen = makeArticle(
            url: "https://example.com/open-paper",
            title: "Already open",
            sourceType: .paper
        )
        vm.articles = [alreadyOpen]
        vm.sidebarTab = .papers
        vm.selectedArticleId = alreadyOpen.id
        vm.selectedArticleIds = [alreadyOpen.id]

        let pdfURL = try makeReadableTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let importedID = try await vm.importPDF(
            from: pdfURL.path,
            processImmediately: false,
            selectInReader: false
        )

        #expect(importedID != alreadyOpen.id)
        #expect(vm.selectedArticleId == alreadyOpen.id)
        #expect(vm.selectedArticleIds == [alreadyOpen.id])
        #expect(vm.articles.contains(where: { $0.id == importedID }))
    }
}

/// A paper's body: long enough, and body text rather than front matter.
let paperBodyText = "## Abstract\n" + String(
    repeating: "The complex adopts a closed conformation upon binding its substrate, "
        + "and the resulting rearrangement propagates through the linker domain. ",
    count: 60
)

/// The page Nature shows for a paper the reader cannot access, after the chrome
/// filter has removed the purchase panel: the abstract, one-line figure titles,
/// and every Extended Data legend in full — what two Nature Neuroscience papers
/// were stored as on 2026-09-06.
let publisherPreviewText: String = {
    var lines = [
        "Mitochondrial calcium influx-driven bioenergetics selectively enable drug addiction",
        "",
        "## Abstract",
        String(repeating: "Addictive substances hijack the reward system and drive dopamine surges that underlie compulsive behavior. ", count: 20),
    ]
    for figure in 1...6 {
        lines.append("Fig. \(figure): A one-line figure title describing what the panels show.")
    }
    lines.append("## Extended data")
    for figure in 1...10 {
        lines.append("### Extended Data Fig. \(figure) A legend title of ordinary length for the figure.")
        lines.append(String(
            repeating: "a, Representative images and traces (n = 25 cells per group; two-tailed paired Student's t-test, P = 0.012). ",
            count: 12
        ))
    }
    return lines.joined(separator: "\n")
}()

extension StudioArticle {
    func with(content: String?) -> StudioArticle {
        var copy = self
        copy.content = content
        return copy
    }
}

func makeScheduledSourceEntry(
    sourceID: String,
    goalID: String,
    plannedAt: Date,
    isCompleted: Bool = false,
    isAutomatic: Bool = false,
    activityKinds: Set<SourceActivityKind> = []
) -> ScheduledSourceEntry {
    ScheduledSourceEntry(
        placement: ScheduledSource(
            id: "placement-\(sourceID)",
            sourceID: sourceID,
            plannedAt: plannedAt,
            addedAt: plannedAt,
            completedAt: isCompleted ? plannedAt : nil,
            createdAt: plannedAt,
            updatedAt: plannedAt
        ),
        goalTags: [],
        goalIDs: [goalID],
        isAutomatic: isAutomatic,
        activityDays: activityKinds.isEmpty ? [] : [
            SourceActivityDay(
                id: "activity-\(sourceID)",
                sourceID: sourceID,
                dayStart: Calendar.current.startOfDay(for: plannedAt),
                firstActivityAt: plannedAt,
                lastActivityAt: plannedAt,
                kinds: activityKinds,
                completedKinds: []
            )
        ]
    )
}

@Suite("Article read completion")
@MainActor
struct ArticleReadCompletionTests {
    @Test("Listening-only completion stays distinct from reading")
    func listeningOnlyStatus() {
        #expect(SourceConsumptionStatus(
            isConsumed: true,
            completedActivityKinds: [.listening]
        ) == .listened)
        #expect(SourceConsumptionStatus(
            isConsumed: true,
            completedActivityKinds: [.reading, .listening]
        ) == .read)
        #expect(SourceConsumptionStatus(
            isConsumed: true,
            completedActivityKinds: []
        ) == .read)
        #expect(SourceConsumptionStatus(
            isConsumed: false,
            completedActivityKinds: [.listening]
        ) == .unread)
    }

    @Test("Reaching the article end marks the source read and persists it")
    func reachingEndMarksArticleRead() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleReadCompletionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        var article = makeArticle(
            url: "https://example.com/long-read",
            title: "Long Read",
            sourceType: .article
        )
        _ = try await service.insertSourceIfNew(&article)
        vm.articles = [article]

        // Reaching the end is a position; the read mark needs the time to go
        // with it. A sitting long enough for a complete read of this article
        // (no word count, so the two-minute floor) is enough.
        vm.noteReaderEngagedTime(article.id, seconds: 600)
        await vm.markArticleReadAfterReachingEnd(article.id)

        #expect(vm.articles.first?.isRead == true)
        #expect(try await service.loadSources().first?.isRead == true)
        let entry = try #require(try await service.loadScheduledSources().first)
        let placement = entry.placement
        #expect(placement.sourceID == article.id)
        #expect(placement.isCompleted)
    }

    @Test("An open reader nobody touches stops counting as reading")
    func untouchedReaderIsNotEngaged() {
        #expect(StudioViewModel.readerIsEngaged(appIsActive: true, secondsSinceInput: 5))
        #expect(StudioViewModel.readerIsEngaged(appIsActive: true, secondsSinceInput: StudioViewModel.readerEngagementIdleGrace))
        // A paper left open in front: no input for ten minutes is not reading.
        #expect(!StudioViewModel.readerIsEngaged(appIsActive: true, secondsSinceInput: 600))
        #expect(!StudioViewModel.readerIsEngaged(appIsActive: false, secondsSinceInput: 1))
        #expect(!StudioViewModel.readerIsEngaged(appIsActive: true, secondsSinceInput: .infinity))
    }

    @Test("A scroll straight to the end, with no time behind it, does not mark the source read")
    func fastScrollToEndDoesNotMarkRead() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleReadCompletionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        var article = makeArticle(
            url: "https://example.com/skimmed",
            title: "Skimmed",
            sourceType: .article
        )
        article.wordCount = 3_000 // twelve minutes at a reading pace; complete needs six
        _ = try await service.insertSourceIfNew(&article)
        vm.articles = [article]

        vm.noteReaderEngagedTime(article.id, seconds: 45)
        await vm.markArticleReadAfterReachingEnd(article.id)
        #expect(vm.articles.first?.isRead == false)
        #expect(try await service.loadSources().first?.isRead == false)

        // Time booked to the ledger on earlier sittings counts as well.
        _ = try await service.recordScheduledSourceActivity(
            sourceID: article.id, on: Date(), kind: .reading, engagedSeconds: 400
        )
        await vm.markArticleReadAfterReachingEnd(article.id)
        #expect(vm.articles.first?.isRead == true)
    }

    @Test("Completion ignores sources that do not support article read tracking")
    func completionIgnoresUntrackableSource() async {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://example.com/paper",
            title: "Paper",
            sourceType: .paper
        )
        vm.articles = [paper]

        await vm.markArticleReadAfterReachingEnd(paper.id)

        #expect(vm.articles.first?.readAt == nil)
    }
}

@Suite("Video watched marks")
@MainActor
struct VideoWatchedMarkTests {
    @Test("Mark as Not Watched clears a watched video in the list, the progress store and the library")
    func notWatchedClearsEverywhere() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoWatchedMarkTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        var video = makeArticle(
            url: "https://www.youtube.com/watch?v=vm-watched",
            title: "Lecture",
            sourceType: .video
        )
        video.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 3500,
            watchedSeconds: 3550,
            durationSeconds: 3600
        ).encoded
        // A finished Schedule item stamped it read as well.
        video.readAt = Date(timeIntervalSinceNow: -3600)
        try await service.saveSource(video)
        vm.articles = [video]
        vm.seedReadingProgressFromArticles()
        #expect(vm.videoReadsAsWatched(video))
        #expect(!vm.videoCanBeMarkedWatched(video))

        await vm.setVideosWatched([video.id], watched: false)

        let shown = try #require(vm.articles.first)
        #expect(!vm.videoReadsAsWatched(shown))
        #expect(shown.readAt == nil)
        #expect(!shown.hasSavedReadingPosition)
        #expect(!vm.readingProgressStore.hasProgress(for: video.id))
        #expect(vm.readingProgressStore.videoWatchProgress(for: video.id, fallbackLocator: nil)?.displayLabel == nil)
        let persisted = try #require(try await service.loadPersistedSources(ids: [video.id]).first)
        #expect(persisted.readAt == nil)
        #expect(VideoWatchProgress.isUnwatchedMarker(persisted.readingPositionLocator))

        // Its length is still known, so it can be marked watched again.
        #expect(vm.videoCanBeMarkedWatched(shown))
        await vm.setVideosWatched([video.id], watched: true)
        #expect(vm.videoReadsAsWatched(try #require(vm.articles.first)))
        #expect(
            vm.readingProgressStore.videoWatchProgress(for: video.id, fallbackLocator: nil)?.displayLabel == "Watched"
        )
    }

    @Test("Articles and papers offer no watched marks")
    func watchedMarksSkipNonVideos() {
        let vm = makeViewModel()
        var article = makeArticle(url: "https://example.com/read", title: "Read", sourceType: .article)
        article.readAt = Date()
        vm.articles = [article]
        #expect(!vm.videoReadsAsWatched(article))
        #expect(!vm.videoCanBeMarkedWatched(article))
    }
}

// MARK: - Podcast Speaker Inference

@Suite("Podcast speaker name inference")
struct PodcastSpeakerNameInferenceTests {
    @Test("Extracts only structural speaker IDs")
    func extractsSpeakerIDs() {
        let transcript = """
        [SPEAKER_1]
        Hi, everyone. This is Aastha, and welcome to another episode of the Live Longer World podcast. My guest today is Dr. Geoffrey West, the author of the bestselling book Scale. Well, hi, Dr. West, and welcome to the Live Longer World podcast.

        [SPEAKER_2]
        Thank you, Aastha, for inviting me. I look forward to our conversation.
        """

        #expect(PodcastSpeakerNameInference.speakerIDs(in: transcript) == Set(["SPEAKER_1", "SPEAKER_2"]))
    }

    @Test("Restores persisted names in raw TTML display segments")
    func restoresPersistedDisplayNames() {
        let raw = [
            podcastSegment(index: 0, id: "SPEAKER_1", label: "Speaker 1", text: "Welcome to the show. Today I am joined by Alex."),
            podcastSegment(index: 1, id: "SPEAKER_2", label: "Speaker 2", text: "Thanks for inviting me. I am excited to talk."),
        ]
        let stored = [
            podcastSegment(index: 0, id: "DANIEL_SHIU", label: "Daniel Shiu", text: "Welcome to the show. Today I am joined by Alex."),
            podcastSegment(index: 1, id: "ALEX_COLVILLE", label: "Alex Colville", text: "Thanks for inviting me. I am excited to talk."),
        ]

        #expect(PodcastSpeakerNameInference.displayNameOverrides(rawSegments: raw, storedSegments: stored) == [
            "SPEAKER_1": "Daniel Shiu",
            "SPEAKER_2": "Alex Colville",
        ])
    }

    @Test("Rejects role labels as person names")
    func rejectsRoleLabels() {
        #expect(!PodcastSpeakerNameInference.isValidPersonName("Host"))
        #expect(!PodcastSpeakerNameInference.isValidPersonName("Speaker 2"))
        #expect(PodcastSpeakerNameInference.isValidPersonName("Eric Dai"))
    }

    private func podcastSegment(index: Int, id: String, label: String, text: String) -> PodcastTranscriptSegment {
        PodcastTranscriptSegment(
            index: index,
            speakerID: id,
            speakerLabel: label,
            startTime: nil,
            endTime: nil,
            text: text
        )
    }
}

// MARK: - Tab Management

@Suite("Studio discovery scope")
struct StudioDiscoveryScopeTests {
    @Test("Nil refresh scope discovers every source type")
    func nilRefreshUsesUnscopedDiscovery() {
        #expect(StudioViewModel.discoveryScope(for: nil) == nil)
    }

    @Test("Specific tab refresh stays scoped")
    func specificTabRefreshStaysScoped() {
        #expect(StudioViewModel.discoveryScope(for: .articles) == .articles)
        #expect(StudioViewModel.discoveryScope(for: .papers) == .papers)
        #expect(StudioViewModel.discoveryScope(for: .books) == .books)
    }

    @Test("An unrelated successful scan preserves the other access warning")
    @MainActor
    func accessWarningsRemainScopedToTheirIntegration() {
        let vm = makeViewModel()
        let podcastWarning = "Apple Podcasts access is blocked."
        let browserWarning = "Chrome Reading List access is blocked."
        let presentedBrowserWarning = "Chrome Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."

        vm.updateDiscoveryWarnings(podcast: [podcastWarning])
        vm.updateDiscoveryWarnings(browser: [])

        #expect(vm.needsPodcastAccess)
        #expect(!vm.needsBrowserAccess)
        #expect(vm.discoveryWarnings(for: .podcasts) == [podcastWarning])

        vm.updateDiscoveryWarnings(browser: [browserWarning])
        vm.updateDiscoveryWarnings(podcast: [])

        #expect(vm.needsBrowserAccess)
        #expect(!vm.needsPodcastAccess)
        #expect(vm.discoveryWarnings(for: .articles) == [presentedBrowserWarning])
    }

    @Test("An accessible browser profile without bookmarks does not request Full Disk Access")
    func emptyBrowserProfileIsNotAPermissionFailure() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyChromeProfile-\(UUID().uuidString)", isDirectory: true)
        let chromeRoot = home
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: chromeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = StudioViewModel.discoverChromeReadingListOffMain(
            browser: "Google/Chrome",
            homeDir: home.path
        )

        #expect(result.articles.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("Dismissed access prompt stays quiet across later scans")
    @MainActor
    func dismissedAccessPromptRemainsDurable() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: StudioViewModel.browserAccessPromptDismissedKey)
        defer {
            defaults.removeObject(forKey: StudioViewModel.browserAccessPromptDismissedKey)
        }

        let vm = makeViewModel()
        let warning = "Chrome Reading List access is blocked."

        vm.updateDiscoveryWarnings(browser: [warning])
        #expect(vm.needsBrowserAccess)
        #expect(!vm.browserAccessPromptDismissed)

        vm.dismissBrowserAccessPrompt()
        #expect(vm.browserAccessPromptDismissed)
        #expect(defaults.bool(forKey: StudioViewModel.browserAccessPromptDismissedKey))
        #expect(makeViewModel().browserAccessPromptDismissed)

        vm.updateDiscoveryWarnings(browser: [warning])
        #expect(vm.needsBrowserAccess)
        #expect(vm.browserAccessPromptDismissed)

        vm.updateDiscoveryWarnings(browser: [])
        #expect(!vm.needsBrowserAccess)
        #expect(vm.browserAccessPromptDismissed)
        #expect(defaults.bool(forKey: StudioViewModel.browserAccessPromptDismissedKey))

        vm.updateDiscoveryWarnings(browser: [warning])
        #expect(vm.needsBrowserAccess)
        #expect(vm.browserAccessPromptDismissed)
    }

    @Test("Safari permission failures request Full Disk Access")
    @MainActor
    func safariPermissionFailureIsPresented() {
        let vm = makeViewModel()
        let safariWarning = "Safari Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM. Last read error: denied"
        let chromeWarning = "Chrome Reading List access is blocked."
        let presentedSafariWarning = "Safari Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."
        let presentedChromeWarning = "Chrome Reading List access is blocked. Enable Full Disk Access and relaunch ForeverLM."

        vm.updateDiscoveryWarnings(browser: [safariWarning])
        #expect(vm.browserDiscoveryWarnings == [presentedSafariWarning])
        #expect(vm.needsBrowserAccess)

        vm.updateDiscoveryWarnings(browser: [safariWarning, chromeWarning])
        #expect(vm.browserDiscoveryWarnings == [presentedSafariWarning, presentedChromeWarning])
        #expect(vm.needsBrowserAccess)
    }

    @Test("Launch reconciliation scans even when the visible snapshot is empty")
    func launchReconciliationForcesReadingListScan() {
        #expect(StudioViewModel.readingListSnapshotRequiresSync(
            current: [:],
            lastSynced: [:],
            force: true
        ))
        #expect(!StudioViewModel.readingListSnapshotRequiresSync(
            current: [:],
            lastSynced: [:],
            force: false
        ))
    }

    @Test("Only permission error codes are classified as access denial")
    func permissionErrorClassification() {
        #expect(StudioViewModel.fileReadWasPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        ))
        #expect(StudioViewModel.fileReadWasPermissionDenied(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        ))
        #expect(!StudioViewModel.fileReadWasPermissionDenied(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        ))
    }
}

@Suite("Removed meeting group tombstones")
struct RemovedMeetingGroupTombstoneTests {
    @Test("Recording dedups case-insensitively and lifting clears the title")
    func recordingAndLiftingTitles() {
        var titles: [String] = []
        titles = StudioViewModel.removedMeetingGroupTitles(titles, recording: "  Weekly Sync  ")
        #expect(titles == ["Weekly Sync"])
        titles = StudioViewModel.removedMeetingGroupTitles(titles, recording: "weekly sync")
        #expect(titles == ["weekly sync"])
        #expect(StudioViewModel.removedMeetingGroupTitles(titles, include: "WEEKLY SYNC"))
        #expect(!StudioViewModel.removedMeetingGroupTitles(titles, include: "Design Review"))
        #expect(StudioViewModel.removedMeetingGroupTitles(titles, recording: "   ") == titles)
        #expect(StudioViewModel.removedMeetingGroupTitles(titles, lifting: "Weekly SYNC").isEmpty)
    }

    @Test("Cap keeps the newest removals")
    func capKeepsNewestTitles() {
        var titles: [String] = []
        for index in 0..<250 {
            titles = StudioViewModel.removedMeetingGroupTitles(titles, recording: "Group \(index)")
        }
        #expect(titles.count == 200)
        #expect(titles.first == "Group 50")
        #expect(titles.last == "Group 249")
    }

    @Test("Stable Drive identity survives renames and distinguishes folders with the same title")
    func stableDriveIdentity() {
        let removed = StudioViewModel.meetingGroupRemovalIdentities(
            groupID: "group-a",
            metadata: MeetingMetadata(
                title: "Weekly Sync",
                driveFolderURL: "https://drive.google.com/drive/folders/folder-a"
            )
        )
        let renamed = StudioViewModel.meetingGroupRemovalIdentities(
            groupID: "group-a",
            metadata: MeetingMetadata(
                title: "Renamed by the learner",
                driveFolderURL: "https://drive.google.com/open?id=folder-a"
            )
        )
        let differentFolder = StudioViewModel.meetingGroupRemovalIdentities(
            groupID: "group-b",
            metadata: MeetingMetadata(
                title: "Weekly Sync",
                driveFolderURL: "https://drive.google.com/drive/folders/folder-b"
            )
        )

        #expect(!removed.isDisjoint(with: renamed))
        #expect(removed.isDisjoint(with: differentFolder))
    }

    @Test("Recording and lifting stable identities is bounded and exact")
    func recordingAndLiftingIdentities() {
        let removal: Set<String> = ["group:weekly", "google-drive-folder:folder-123"]
        let recorded = StudioViewModel.removedMeetingGroupIdentities(
            ["group:other", "group:weekly"],
            recording: removal
        )
        #expect(Set(recorded) == ["group:other", "group:weekly", "google-drive-folder:folder-123"])
        #expect(StudioViewModel.removedMeetingGroupIdentities(recorded, lifting: removal) == ["group:other"])
    }

    @Test("Removed-title lookup reads the stored list")
    func removedTitleLookupReadsDefaults() {
        let key = StudioViewModel.removedMeetingGroupTitlesKey
        let prior = UserDefaults.standard.stringArray(forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(["Weekly Sync"], forKey: key)
        #expect(StudioViewModel.isMeetingGroupTitleRemoved("weekly sync"))
        #expect(!StudioViewModel.isMeetingGroupTitleRemoved("Standup"))
    }
}
