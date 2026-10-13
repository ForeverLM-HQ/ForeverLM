import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - Helpers

private func makeArticle(
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

private func makeTempPDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data().write(to: url)
    return url
}

private func makeReadableTempPDF() throws -> URL {
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
private func capturedCenterTabLayout() -> () -> Void {
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
private func capturedStudioWindowTemplate() -> () -> Void {
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
private func markPaperFullyReady(_ paper: inout StudioArticle, content: String? = nil) {
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

private func warmLocalPathCache(_ rawPaths: [String]) async {
    await Task.detached(priority: .utility) {
        for path in rawPaths {
            _ = StudioArticle.resolvedLocalPath(forRawPath: path)
        }
    }.value
}

@Suite("Paper PDF import presentation")
@MainActor
struct PaperPDFImportPresentationTests {
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

@MainActor
private func makeViewModel() -> StudioViewModel {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMTests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let service = StorageService(storeRoot: tmp)
    return StudioViewModel(storageService: service)
}

/// A paper's body: long enough, and body text rather than front matter.
private let paperBodyText = "## Abstract\n" + String(
    repeating: "The complex adopts a closed conformation upon binding its substrate, "
        + "and the resulting rearrangement propagates through the linker domain. ",
    count: 60
)

/// The page Nature shows for a paper the reader cannot access, after the chrome
/// filter has removed the purchase panel: the abstract, one-line figure titles,
/// and every Extended Data legend in full — what two Nature Neuroscience papers
/// were stored as on 2026-09-06.
private let publisherPreviewText: String = {
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

private extension StudioArticle {
    func with(content: String?) -> StudioArticle {
        var copy = self
        copy.content = content
        return copy
    }
}

private func makeScheduledSourceEntry(
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


@Suite("Course Playlist Import")
@MainActor
struct CoursePlaylistImportTests {

    @Test("Lettered playlist ordinals collapse to the same lecture number")
    func letteredPlaylistOrdinalsUseMajorLectureNumber() {
        #expect(StudioViewModel.playlistLectureNumber(from: "5A) Temporal order, Global Structure, and Memory", fallback: 6) == 5)
        #expect(StudioViewModel.playlistLectureNumber(from: "5B) Temporal order, Global Structure, and Memory", fallback: 7) == 5)
        #expect(StudioViewModel.playlistLectureNumber(from: "Lecture 8B - Robustness using bifunctional components", fallback: 9) == 8)
    }

    @Test("Playlist ordinals fall back to item order when no lecture number is present")
    func playlistOrdinalsFallbackToItemOrder() {
        #expect(StudioViewModel.playlistLectureNumber(from: "Feed Forward Loops", fallback: 3) == 3)
    }

    @Test("Playlist lecture cleanup preserves original title when AI is unavailable")
    func playlistLectureCleanupPreservesOriginalWithoutAI() {
        let title = "Lecture 3: Age - Related Diseases, 17.11.2025 - Systems Aging and Longevity, Autumn 2025"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: nil, courseName: "Systems Aging") == title)
    }

    @Test("Playlist lecture cleanup does not re-parse the configured LLM's result")
    func playlistLectureCleanupTrustsConfiguredLLM() {
        let title = "Lecture 12: Friends, Stress and Wisdom, 19.1.2026 - Systems Aging and Longevity, Autumn 2025"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "1) Friends, Stress and Wisdom", courseName: "Systems Aging") == "1) Friends, Stress and Wisdom")
    }

    @Test("Playlist lecture cleanup trusts LLM title text")
    func playlistLectureCleanupTrustsLLMTitleText() {
        let title = "Lecture 4: Epigenetic Clocks - Systems Aging"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "4) Epigenetic Clocks | YouTube", courseName: "Systems Aging") == "4) Epigenetic Clocks | YouTube")
    }

    @Test("Playlist lecture cleanup preserves slash-separated original titles")
    func playlistLectureCleanupPreservesSlashSeparatedOriginalTitles() {
        let title = "7.05 Biochemistry / 12. /Introduction to Membranes"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: nil, courseName: "Biochemistry") == title)
    }

    @Test("Playlist lecture cleanup trusts separators in AI titles")
    func playlistLectureCleanupTrustsSeparatorsInAITitles() {
        let title = "7.05 Biochemistry / 12. Introduction to Membranes"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "12) /Introduction to Membranes", courseName: "Biochemistry") == "12) /Introduction to Membranes")
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "12) Biochemistry / Introduction to Membranes", courseName: "Biochemistry") == "12) Biochemistry / Introduction to Membranes")
    }

    @Test("Playlist lecture cleanup preserves the batch LLM output verbatim")
    func playlistLectureCleanupPreservesBatchLLMOutput() {
        let cases = [
            ("Lecture 3 Part a - Feed Forward Loops", "3) Feed Forward Loops", "3) Feed Forward Loops"),
            ("Lecture 3 - Part b - Feed Forward Loop", "3) Feed Forward Loop", "3) Feed Forward Loop"),
            ("Lecture 4 a - Temporal order, Global Structure, and Memory", "4) Temporal order, Global Structure, and Memory", "4) Temporal order, Global Structure, and Memory"),
            ("Lecture 4 b - Temporal Order, Global Structure, and Memory", "4B) Temporal Order, Global Structure, and Memory", "4B) Temporal Order, Global Structure, and Memory"),
            ("Lecture 7  part B - Fold Change Detection", "7) Fold Change Detection", "7) Fold Change Detection"),
            ("Lecture 8 C - Dynamic Compensation", "8A) Dynamic Compensation", "8A) Dynamic Compensation")
        ]

        for (original, aiTitle, expected) in cases {
            #expect(StudioViewModel.cleanedPlaylistLectureTitle(
                originalTitle: original,
                aiTitle: aiTitle,
                courseName: "Systems Biology"
            ) == expected)
        }
    }

    @Test("Deterministic playlist cleanup preserves parts when AI cleanup is unavailable")
    func deterministicPlaylistCleanupPreservesParts() {
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(
            originalTitle: "Lecture 5 a - Robustness using bifunctional components",
            aiTitle: nil,
            courseName: "Systems Biology"
        ) == "Lecture 5 a - Robustness using bifunctional components")
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(
            originalTitle: "Lecture 5 - Part 2 - Robustness using bifunctional components",
            aiTitle: nil,
            courseName: "Systems Biology"
        ) == "Lecture 5 - Part 2 - Robustness using bifunctional components")
    }

    @Test("Playlist title cleanup keeps every video title unique")
    func playlistTitleCleanupKeepsEveryVideoTitleUnique() {
        let items = [
            YouTubePlaylistItem(videoId: "part-a", title: "Lecture 3 Part a - Feed Forward Loops", playlistIndex: 3),
            YouTubePlaylistItem(videoId: "part-b", title: "Lecture 3 - Part b - Feed Forward Loops", playlistIndex: 4),
            YouTubePlaylistItem(videoId: "repeat-1", title: "Bonus discussion", playlistIndex: 5),
            YouTubePlaylistItem(videoId: "repeat-2", title: "Bonus discussion", playlistIndex: 6)
        ]
        let titles = StudioViewModel.uniquePlaylistLectureTitles(
            items,
            aiTitles: [
                "part-a": "3) Feed Forward Loops",
                "part-b": "3) Feed Forward Loops",
                "repeat-1": "5) Bonus discussion",
                "repeat-2": "5) Bonus discussion"
            ],
            courseName: "Systems Biology"
        )

        #expect(titles["part-a"] == "3) Feed Forward Loops · Video 3")
        #expect(titles["part-b"] == "3) Feed Forward Loops · Video 4")
        #expect(titles["repeat-1"] == "5) Bonus discussion · Video 5")
        #expect(titles["repeat-2"] == "5) Bonus discussion · Video 6")
        #expect(Set(titles.values).count == items.count)

        let sourceTitles = StudioViewModel.uniquePlaylistSourceTitles(
            items,
            lectureTitles: titles,
            courseName: "Systems Biology"
        )
        #expect(sourceTitles["part-a"] == "3) Feed Forward Loops · Video 3")
        #expect(sourceTitles["part-b"] == "3) Feed Forward Loops · Video 4")
        #expect(Set(sourceTitles.values).count == items.count)
    }

    @Test("Video source titles stay unique when lecture numbers were their only difference")
    func videoSourceTitlesStayUniqueWithoutLectureNumbers() {
        let items = [
            YouTubePlaylistItem(videoId: "first", title: "Lecture 1 - Introduction", playlistIndex: 1),
            YouTubePlaylistItem(videoId: "second", title: "Lecture 2 - Introduction", playlistIndex: 2)
        ]
        let titles = StudioViewModel.uniquePlaylistSourceTitles(
            items,
            lectureTitles: [
                "first": "1) Introduction",
                "second": "2) Introduction"
            ],
            courseName: "Systems Biology"
        )

        #expect(titles["first"] == "1) Introduction")
        #expect(titles["second"] == "2) Introduction")
    }

    @Test("Course refresh repairs only titles previously produced by the importer")
    func courseRefreshRepairsPreviouslyImportedVideoTitles() {
        #expect(!StudioViewModel.shouldRepairCoursePlaylistStoredTitle(
            currentTitle: "Feed Forward Loops",
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: "3A) Feed Forward Loops",
            replacementTitle: "Feed Forward Loops · Part A",
            courseName: "Systems Biology"
        ))
        #expect(!StudioViewModel.shouldRepairCoursePlaylistStoredTitle(
            currentTitle: "Bonus discussion",
            originalTitle: "Bonus discussion",
            cleanedLectureTitle: "5) Bonus discussion · Video 5",
            replacementTitle: "Bonus discussion · Video 5",
            courseName: "Systems Biology"
        ))
        #expect(!StudioViewModel.shouldRepairCoursePlaylistStoredTitle(
            currentTitle: "My renamed feed-forward lecture",
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: "3A) Feed Forward Loops",
            replacementTitle: "Feed Forward Loops · Part A",
            courseName: "Systems Biology"
        ))
    }

    @Test("Playlist lecture cleanup leaves semantic validation to the configured LLM")
    func playlistLectureCleanupLeavesSemanticValidationToLLM() {
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(
            originalTitle: "Lecture 9 - How to build a Biological Oscillator",
            aiTitle: "9A) How to build a Biological Oscillator",
            courseName: "Systems Biology"
        ) == "9A) How to build a Biological Oscillator")
    }

    @Test("Playlist source display titles omit synthetic lecture numbers")
    func playlistSourceDisplayTitlesOmitSyntheticLectureNumbers() {
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Opening Remarks by Michael Dowling",
            cleanedLectureTitle: "1) Opening Remarks by Michael Dowling",
            courseName: "Quantum Biology"
        ) == "1) Opening Remarks by Michael Dowling")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Session 2 - Introduction by Session Leader",
            cleanedLectureTitle: nil,
            courseName: "Quantum Biology"
        ) == "Session 2 - Introduction by Session Leader")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Quantum Biology / 2) Biophotons: Fundamentals",
            cleanedLectureTitle: nil,
            courseName: "Quantum Biology"
        ) == "Quantum Biology / 2) Biophotons: Fundamentals")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "A 30,000 ft Overview",
            cleanedLectureTitle: nil,
            courseName: "Quantum Biology"
        ) == "A 30,000 ft Overview")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: "3A) Feed Forward Loops",
            courseName: "Systems Biology"
        ) == "3A) Feed Forward Loops")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: nil,
            courseName: "Systems Biology"
        ) == "Lecture 3 Part a - Feed Forward Loops")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Lecture 5 Part 2 - Robustness",
            cleanedLectureTitle: "5.2) Robustness",
            courseName: "Systems Biology"
        ) == "5.2) Robustness")
    }

    @Test("Video playlist display title never numbers an already numbered title twice")
    func videoPlaylistDisplayTitleKeepsStoredOrdinal() {
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "1) Quantum Biology: A 30,000 ft Overview",
            playlistTitle: "Quantum Biology",
            sortIndex: 1
        ) == "1) Quantum Biology: A 30,000 ft Overview")
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "1) Quantum Biology: A 30,000 ft Overview",
            playlistTitle: "Quantum Biology",
            sortIndex: nil
        ) == "1) Quantum Biology: A 30,000 ft Overview")
    }

    @Test("Playlist rows number only titles that name no lecture of their own")
    func playlistRowsNumberOnlyUnnumberedTitles() {
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "A 30,000 ft Overview",
            playlistTitle: "Quantum Biology",
            sortIndex: 1
        ) == "2) A 30,000 ft Overview")
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "3 Body Problem",
            playlistTitle: "Quantum Biology",
            sortIndex: 0
        ) == "1) 3 Body Problem")
    }

    @Test("Course lecture rows never repeat the number their title already carries")
    func courseLectureRowsDoNotRepeatTheirNumber() {
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 1,
            lectureTitle: "1) Universal Patterns of Aging",
            itemTitle: "1) Universal Patterns of Aging"
        ) == "1) Universal Patterns of Aging")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "Lecture 3: Age-Related Diseases",
            itemTitle: "Lecture 3: Age-Related Diseases"
        ) == "Lecture 3: Age-Related Diseases")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 4,
            lectureTitle: "Menopause",
            itemTitle: "Menopause"
        ) == "4) Menopause")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 4,
            lectureTitle: nil,
            itemTitle: ""
        ) == "4)")
    }

    @Test("Split lecture rows keep the part their videos are numbered by")
    func splitLectureRowsKeepVideoParts() {
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "3) Feed Forward Loops",
            itemTitle: "3A) Feed Forward Loops"
        ) == "3A) Feed Forward Loops")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "3) Feed Forward Loops",
            itemTitle: "3B) Feed Forward Loops"
        ) == "3B) Feed Forward Loops")
        // A retitled lecture names the row; the video title does not override it.
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "3) Network motifs, continued",
            itemTitle: "3A) Feed Forward Loops"
        ) == "3) Network motifs, continued")
        // A lecture with no title of its own falls back to the video's.
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 8,
            lectureTitle: nil,
            itemTitle: "8C) Dynamic Compensation"
        ) == "8C) Dynamic Compensation")
    }

    @Test("Schedule video playlist rows use playlist metadata titles")
    func scheduleVideoPlaylistRowsUsePlaylistMetadataTitles() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let vm = makeViewModel()
        let video = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "1) Quantum Biology: A 30,000 ft Overview",
            sourceType: .video,
            parentGroup: "playlist",
            sortIndex: 1
        )
        vm.videoPlaylistMetadata = [
            "playlist": VideoPlaylistMetadata(title: "Quantum Biology", playlistURL: "https://www.youtube.com/playlist?list=PL")
        ]
        vm.articles = [video]
        let goal = LearningGoalRecord(
            id: "goal",
            title: "Schedule",
            startAt: monday,
            endAt: calendar.date(byAdding: .day, value: 7, to: monday)!,
            createdAt: monday,
            updatedAt: monday,
            status: "active",
            items: []
        )
        // Schedule rows now come from shared placements (`scheduledSources`),
        // scoped to the goal via `goalIDs`, not from `goal.items`.
        vm.scheduledSources = [
            makeScheduledSourceEntry(sourceID: video.id, goalID: goal.id, plannedAt: monday)
        ]

        let item = vm.scheduleDays(for: goal, containing: monday).first?.items.first
        #expect(item?.groupTitle == "Quantum Biology")
        #expect(item?.subtitle == "Quantum Biology")
        #expect(item?.title == "1) Quantum Biology: A 30,000 ft Overview")
    }

    @Test("opening a source never puts a completed row on the plan")
    func automaticActivityNeverAppearsAsPlannedWork() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let vm = makeViewModel()
        let opened = makeArticle(url: "https://example.com/opened", title: "Opened Once")
        let planned = makeArticle(url: "https://example.com/planned", title: "Actually Planned")
        vm.articles = [opened, planned]

        // What the Reader writes when a source is merely opened: an automatic
        // placement anchoring that day's activity.
        vm.scheduledSources = [
            makeScheduledSourceEntry(
                sourceID: opened.id,
                goalID: "goal",
                plannedAt: monday,
                isAutomatic: true,
                activityKinds: [.reading]
            ),
            makeScheduledSourceEntry(sourceID: planned.id, goalID: "goal", plannedAt: monday),
        ]

        let day = vm.unifiedScheduleDays(containing: monday)
            .first { calendar.isDate($0.date, inSameDayAs: monday) }
        // Only the deliberate placement is on the plan, and it is not complete.
        #expect(day?.items.map(\.sourceID) == [planned.id])
        #expect(day?.completedCount == 0)
        #expect(day?.pendingCount == 1)
        #expect(day?.items.first?.canMarkDone == true)
    }

    @Test("activity on a planned day is a hint, not a completion")
    func activityOnPlannedDayDoesNotCompleteTheItem() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let vm = makeViewModel()
        let article = makeArticle(url: "https://example.com/planned", title: "Planned")
        vm.articles = [article]
        vm.scheduledSources = [
            makeScheduledSourceEntry(
                sourceID: article.id,
                goalID: "goal",
                plannedAt: monday,
                activityKinds: [.reading]
            )
        ]

        let item = vm.unifiedScheduleDays(containing: monday)
            .first { calendar.isDate($0.date, inSameDayAs: monday) }?
            .items.first
        #expect(item?.activityKinds == [.reading])
        #expect(item?.isCompleted == false)
    }

    @Test("Schedule book rows do not show opaque book IDs")
    func scheduleBookRowsDoNotShowOpaqueBookIDs() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let bookID = "82BDACDF-C0FA-4039-BE38-0C49BAB7D91D"
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "file:///Books/Quantum/Chapters/chapter-1.pdf",
            title: "1) Quantum Theory & The New Observables",
            sourceType: .book,
            parentGroup: bookID,
            sortIndex: 0
        )
        vm.articles = [chapter]
        let goal = LearningGoalRecord(
            id: "goal",
            title: "Schedule",
            startAt: monday,
            endAt: calendar.date(byAdding: .day, value: 7, to: monday)!,
            createdAt: monday,
            updatedAt: monday,
            status: "active",
            items: []
        )
        // Schedule rows now come from shared placements (`scheduledSources`),
        // scoped to the goal via `goalIDs`, not from `goal.items`.
        vm.scheduledSources = [
            makeScheduledSourceEntry(sourceID: chapter.id, goalID: goal.id, plannedAt: monday)
        ]

        var item = vm.scheduleDays(for: goal, containing: monday).first?.items.first
        #expect(item?.groupTitle == nil)
        #expect(item?.subtitle == "Book chapter")

        vm.bookTitles[bookID] = "Quantum Theory"
        item = vm.scheduleDays(for: goal, containing: monday).first?.items.first
        #expect(item?.groupTitle == "Quantum Theory")
    }

    @Test("Video playlist items sort by playlist position")
    func videoPlaylistItemsSortByPlaylistPosition() {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "https://www.youtube.com/watch?v=AAAAAAAAAAA",
            title: "First",
            sourceType: .video,
            parentGroup: "playlist",
            sortIndex: 0
        )
        let last = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "Last",
            sourceType: .video,
            parentGroup: "playlist",
            sortIndex: 46
        )
        vm.videoPlaylistMetadata = [
            "playlist": VideoPlaylistMetadata(title: "Playlist", playlistURL: "https://www.youtube.com/playlist?list=PL")
        ]
        vm.articles = [last, first]
        vm.sidebarTab = .videos

        #expect(vm.activeTabArticles.map(\.id) == [first.id, last.id])
    }

    @Test("Liked YouTube plugin videos render inline instead of as a playlist group")
    @MainActor
    func likedYouTubePluginVideosRenderInline() {
        let vm = makeViewModel()
        vm.videoPlaylistMetadata = [
            "liked": VideoPlaylistMetadata(
                title: "Liked videos",
                playlistURL: "https://www.youtube.com/playlist?list=LL",
                connectorKind: "liked"
            ),
            "playlist": VideoPlaylistMetadata(
                title: "Conference Talks",
                playlistURL: "https://www.youtube.com/playlist?list=PL"
            )
        ]

        #expect(vm.inlineVideoPlaylistGroupNames == ["liked"])
        #expect(vm.filteredVideoPlaylistGroupNames == ["playlist"])
    }

    @Test("ForeverLM plugin videos render inline and identify the selected source")
    @MainActor
    func foreverLMPluginVideosRenderInline() {
        let vm = makeViewModel()
        vm.videoPlaylistMetadata = [
            "feynman": VideoPlaylistMetadata(
                title: "ForeverLM",
                playlistURL: "https://www.youtube.com/playlist?list=PL-feynman",
                autoImport: true,
                connectorKind: "foreverlm"
            ),
            "playlist": VideoPlaylistMetadata(
                title: "Conference Talks",
                playlistURL: "https://www.youtube.com/playlist?list=PL-other"
            )
        ]

        #expect(vm.youtubeImportSource == .foreverLMPlaylist)
        #expect(vm.inlineVideoPlaylistGroupNames == ["feynman"])
        #expect(vm.filteredVideoPlaylistGroupNames == ["playlist"])
    }

    @Test("ForeverLM playlist matching is exact but case insensitive")
    func foreverLMPlaylistTitleMatching() {
        #expect(YouTubeService.isForeverLMPlaylistTitle("ForeverLM"))
        #expect(YouTubeService.isForeverLMPlaylistTitle("  foreverlm\n"))
        #expect(!YouTubeService.isForeverLMPlaylistTitle("ForeverLM Queue"))
        #expect(!YouTubeService.isForeverLMPlaylistTitle("My ForeverLM"))
    }

    @Test("Named playlist removal only archives rows owned by that playlist")
    func foreverLMPlaylistRemovalIsGroupScoped() {
        let groupID = "playlist_youtube.com/playlist?list=PL-feynman"
        let removed = makeArticle(
            url: "https://www.youtube.com/watch?v=REMOVED0001",
            title: "Removed",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: groupID
        )
        let retained = makeArticle(
            url: "https://www.youtube.com/watch?v=RETAINED001",
            title: "Retained",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: groupID
        )
        let courseLecture = makeArticle(
            url: "https://www.youtube.com/watch?v=COURSE00001",
            title: "Course lecture",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: groupID
        )
        let current = Set([StudioViewModel.sourceURLIdentityKey(retained.url)])

        #expect(StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
            removed,
            groupID: groupID,
            currentURLKeys: current
        ))
        #expect(!StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
            retained,
            groupID: groupID,
            currentURLKeys: current
        ))
        #expect(!StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
            courseLecture,
            groupID: groupID,
            currentURLKeys: current,
            courseLectureSourceIDs: [courseLecture.id]
        ))
    }

    @Test("Videos sort by publication date, with undated videos last")
    @MainActor
    func videoSortByPublishedDate() {
        let vm = makeViewModel()
        vm.videoSortMode = .published

        var old = makeArticle(url: "https://youtu.be/a", title: "Old", sourceType: .video, sortIndex: 0)
        old.videoPublishedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var recent = makeArticle(url: "https://youtu.be/b", title: "Recent", sourceType: .video, sortIndex: 1)
        recent.videoPublishedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        // No publish date — a Safari-discovered video, or one not yet re-synced.
        let undated = makeArticle(url: "https://youtu.be/c", title: "Undated", sourceType: .video, sortIndex: 2)

        let sorted = [old, undated, recent].sorted { vm.compareVideoArticles($0, $1) }
        #expect(sorted.map(\.title) == ["Recent", "Old", "Undated"])
    }

    @Test("Liked sort prefers the liked timestamp but falls back to playlist position")
    @MainActor
    func videoSortByLikedDateFallsBackToPlaylistPosition() {
        let vm = makeViewModel()
        vm.videoSortMode = .liked

        // Position says first, but the liked timestamp says older — the
        // timestamp wins when both rows have one.
        var first = makeArticle(url: "https://youtu.be/a", title: "First", sourceType: .video, sortIndex: 0)
        first.likedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var second = makeArticle(url: "https://youtu.be/b", title: "Second", sourceType: .video, sortIndex: 1)
        second.likedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        #expect([first, second].sorted { vm.compareVideoArticles($0, $1) }.map(\.title) == ["Second", "First"])

        // Neither has a timestamp yet: position still orders them.
        let a = makeArticle(url: "https://youtu.be/c", title: "A", sourceType: .video, sortIndex: 0)
        let b = makeArticle(url: "https://youtu.be/d", title: "B", sourceType: .video, sortIndex: 1)
        #expect([b, a].sorted { vm.compareVideoArticles($0, $1) }.map(\.title) == ["A", "B"])
    }

    @Test("Browser Reading List YouTube videos and X posts never become sources")
    func browserReadingListPluginURLsNeverBecomeSources() {
        let readingListVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=AAAAAAAAAAA",
            title: "Reading List video",
            sourceType: .video,
            discoveryOrigin: .safari
        )
        let readingListXPost = makeArticle(
            url: "https://x.com/someone/status/1234567890",
            title: "Reading List X post",
            sourceType: .xPost,
            discoveryOrigin: .safari
        )
        let readingListArticle = makeArticle(
            url: "https://example.com/article",
            title: "Reading List article",
            sourceType: .article,
            discoveryOrigin: .safari
        )
        let manualVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "Manual video",
            sourceType: .video,
            discoveryOrigin: .manual
        )
        let sources = [readingListVideo, readingListXPost, readingListArticle, manualVideo]

        #expect(StudioViewModel.filterBrowserReadingListPluginSources(sources)
            .map(\.id) == [readingListArticle.id, manualVideo.id])
    }

    @Test("Videos tab refresh never scans browser Reading Lists")
    func videosTabRefreshNeverScansBrowserReadingLists() {
        #expect(!StudioViewModel.discoveryScanIncludesBrowserReadingLists(.videos))
        #expect(StudioViewModel.discoveryScanIncludesBrowserReadingLists(.articles))
        #expect(StudioViewModel.discoveryScanIncludesBrowserReadingLists(.papers))
        #expect(!StudioViewModel.discoveryScanIncludesBrowserReadingLists(.books))
        #expect(StudioViewModel.discoveryScanIncludesBrowserReadingLists(nil))
    }

    @Test("Videos tab mirrors the liked feed")
    func videosTabMirrorsTheLikedFeed() {
        let syncedVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=SYNCEDVID01",
            title: "A liked video",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )

        let feedWithoutIt = Set([
            StudioViewModel.sourceURLIdentityKey("https://www.youtube.com/watch?v=OTHERVIDEO1"),
        ])
        let feedWithIt = Set([
            StudioViewModel.sourceURLIdentityKey(syncedVideo.url),
        ])

        // Gone from the feed → archive; still liked → keep.
        #expect(StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            syncedVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt
        ))
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            syncedVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithIt
        ))

        // Videos in playlist groups (courses, legacy follows) are left alone.
        let playlistVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=PLAYLIST123",
            title: "Lecture 3",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: "some-course-playlist"
        )
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            playlistVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt
        ))

        // Manually added YouTube URLs are left alone.
        let manualVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=MANUALVID01",
            title: "Manually added talk",
            sourceType: .video,
            discoveryOrigin: .manual
        )
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            manualVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt
        ))

        // Videos discovered in a browser Reading List were never claimed to be
        // liked, so the Liked feed has no standing to archive them.
        for browserOrigin in [DiscoveryOrigin.safari, .chrome, .brave] {
            let browserVideo = makeArticle(
                url: "https://www.youtube.com/watch?v=BROWSERVID1",
                title: "Found while browsing",
                sourceType: .video,
                discoveryOrigin: browserOrigin
            )
            #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
                browserVideo,
                likedGroupID: "liked-group",
                likedURLKeys: feedWithoutIt
            ))
        }

        // Course-lecture videos are scraped from public playlists, so they
        // carry .youtubePlaylist origin and no parentGroup — exactly what the
        // predicate would otherwise archive. Membership in course_lecture_items
        // must exempt them; archiving wipes the lecture transcript.
        let lectureVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=LECTUREVID1",
            title: "1) The insulin-glucose circuit",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )
        #expect(StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            lectureVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt,
            courseLectureSourceIDs: []
        ))
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            lectureVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt,
            courseLectureSourceIDs: [lectureVideo.id]
        ))
    }

    @Test("Manual removal outlives a stale like; only a re-like brings the video back")
    func manualRemovalOutlivesStaleLike() {
        let removedAt = Date(timeIntervalSinceReferenceDate: 5_000)

        // Still liked from before the removal — the sync must not resurrect it.
        #expect(!StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            dismissedAt: removedAt
        ))
        // Liked at the exact removal instant proves nothing fresh either.
        #expect(!StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: removedAt,
            dismissedAt: removedAt
        ))
        // Re-liked after the removal — the fresher intent wins.
        #expect(StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: Date(timeIntervalSinceReferenceDate: 9_000),
            dismissedAt: removedAt
        ))
        // No liked date at all — freshness unprovable, the removal stands.
        #expect(!StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: nil,
            dismissedAt: removedAt
        ))
    }

    @Test("Dismissal dates collapse onto URL identity keys, latest removal winning")
    func dismissalDatesCollapseOntoIdentityKeys() {
        let byKey = StudioViewModel.dismissalDatesByIdentityKey([
            "https://www.youtube.com/watch?v=SYNCEDVID01": Date(timeIntervalSinceReferenceDate: 2_000),
            "https://youtu.be/SYNCEDVID01": Date(timeIntervalSinceReferenceDate: 7_000),
            "https://example.com/article": Date(timeIntervalSinceReferenceDate: 3_000),
        ])

        // Both spellings of the video normalize to one key; the later removal wins.
        let videoKey = StudioViewModel.sourceURLIdentityKey("https://www.youtube.com/watch?v=SYNCEDVID01")
        #expect(byKey[videoKey] == Date(timeIntervalSinceReferenceDate: 7_000))
        let articleKey = StudioViewModel.sourceURLIdentityKey("https://example.com/article")
        #expect(byKey[articleKey] == Date(timeIntervalSinceReferenceDate: 3_000))
        #expect(byKey.count == 2)
    }

    @Test("Course lecture list hides empty placeholder when real lectures start later")
    func courseLectureListHidesEmptyPlaceholderWhenRealLecturesStartLater() {
        let vm = makeViewModel()
        let courseName = "Biochemistry"
        vm.courseLecturesByCourse[courseName] = [
            CourseSession(id: "placeholder", courseName: courseName, number: 1),
            CourseSession(id: "lecture-12", courseName: courseName, number: 12, title: "Introduction to Membranes"),
        ]

        #expect(vm.courseLectures(for: courseName).map(\.number) == [12])
    }

    @Test("Creating a course does not create an assumed lecture one")
    func creatingCourseDoesNotCreateAssumedLectureOne() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CourseCreateNoPlaceholderTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        await vm.createCourse(name: "Biochemistry")

        #expect(vm.courseLecturesByCourse.values.flatMap { $0 }.isEmpty)
        #expect(try await service.loadCourseLectures().isEmpty)
    }

    @Test("Lettered lecture materials attach to the matching major lecture")
    func letteredMaterialsAttachToMajorLecture() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CoursePlaylistImportTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let courseName = "Systems Biology"

        guard let lecture = await vm.createLecture(in: courseName, title: "Temporal order", number: 5) else {
            Issue.record("Expected lecture 5 to be created")
            return
        }

        var partA = StudioArticle(url: "https://www.youtube.com/watch?v=AAAAAAAAAAA", title: "5A) Temporal order", sourceType: .video)
        var partB = StudioArticle(url: "https://www.youtube.com/watch?v=BBBBBBBBBBB", title: "5B) Temporal order", sourceType: .video)
        _ = try await service.insertSourceIfNew(&partA)
        _ = try await service.insertSourceIfNew(&partB)
        vm.articles = [partA, partB]

        await vm.addArticleToCourse(articleId: partA.id, courseName: courseName)
        await vm.addArticleToCourse(articleId: partB.id, courseName: courseName)

        #expect(vm.courseLectures(for: courseName).map(\.number) == [5])
        #expect(vm.courseLectureItems(for: lecture.id).compactMap(\.sourceId) == [partA.id, partB.id])
    }
}

@Suite("YouTube Metadata")
@MainActor
struct YouTubeMetadataTests {

    @Test("oEmbed metadata replaces browser placeholder fields")
    func oEmbedMetadataAppliesToSource() {
        var article = StudioArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "www.com",
            sourceType: .video
        )
        article.domain = "www.youtube.com"

        let metadata = YouTubeTranscriptService.VideoMetadata(
            title: "Discrete Diffusion Models",
            channelName: "MIT 6.S978",
            thumbnailURL: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
        )

        StudioViewModel.applyYouTubeMetadata(metadata, to: &article)

        #expect(article.title == "Discrete Diffusion Models")
        #expect(article.domain == "MIT 6.S978")
        #expect(article.artworkURL == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    @Test("YouTube metadata falls back to deterministic thumbnail")
    func metadataUsesDeterministicThumbnailFallback() {
        var article = StudioArticle(
            url: "https://youtu.be/dQw4w9WgXcQ",
            title: "www.com",
            sourceType: .video
        )

        let metadata = YouTubeTranscriptService.VideoMetadata(
            title: "Discrete Diffusion Models",
            channelName: nil,
            thumbnailURL: nil
        )

        StudioViewModel.applyYouTubeMetadata(metadata, to: &article)

        #expect(article.title == "Discrete Diffusion Models")
        #expect(article.artworkURL == "https://img.youtube.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
    }

    @Test("Placeholder YouTube titles are detected")
    func placeholderYouTubeTitlesAreBad() {
        let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        #expect(StudioViewModel.titleLooksBad("www.com", domain: "www.youtube.com", url: url))
        #expect(StudioViewModel.titleLooksBad("Untitled Video", domain: "www.youtube.com", url: url))
        #expect(!StudioViewModel.titleLooksBad("Discrete Diffusion Models", domain: "www.youtube.com", url: url))
    }

    @Test("URL-shaped titles are bad even when they differ from the stored URL")
    func urlShapedTitlesAreBadWhenMismatched() {
        let storedURL = "https://open.substack.com/pub/couteiral/p/the-antibody-revolution-is-real-the"
        let readingListTitle = "https://couteiral.substack.com/p/the-antibody-revolution-is-real-the?utm_campaign=post"
        #expect(
            StudioViewModel.titleLooksBad(
                readingListTitle,
                domain: "open.substack.com",
                url: storedURL
            )
        )
    }

    @Test("HTML page metadata replaces placeholder article title and author")
    func applyWebArticleMetadataIfNeeded() {
        var article = StudioArticle(
            url: "https://open.substack.com/pub/couteiral/p/example",
            title: "https://couteiral.substack.com/p/example?utm_campaign=post",
            sourceType: .article
        )
        article.domain = "open.substack.com"
        StudioViewModel.applyWebArticleMetadataIfNeeded(
            to: &article,
            pageTitle: "The antibody revolution is real. The business, less so.",
            pageAuthor: "Carlos Outeiral",
            content: "Body text"
        )
        #expect(article.title == "The antibody revolution is real. The business, less so.")
        #expect(article.author == "Carlos Outeiral")
    }
}

@Suite("Tab Management")
@MainActor
struct TabManagementTests {
    @Test("an explainer is listed under the source it explains, never as a row of its own")
    func explainerFoldsUnderItsSource() {
        // The product owner (2026-09-10): "an explainer of an article shouldn't be stored
        // as a separate entity; it should just be linked to that original
        // article somehow". Storage is unchanged — the link is the explainer's
        // URL — and the sidebar folds it under its source (explainer-design.md).
        let vm = makeViewModel()
        let article = makeArticle(url: "https://example.org/a", title: "A", sourceType: .article, state: .ready, id: "art-1")
        let paper = makeArticle(url: "https://doi.org/10.1/x", title: "P", sourceType: .paper, state: .ready, id: "pap-1")
        let explainer = makeArticle(
            url: GeneratedExplainer.url(explaining: article.id),
            title: "Explainer: A",
            sourceType: .article,
            state: .ready,
            id: GeneratedExplainer.sourceID(explaining: article.id)
        )
        let paperExplainer = makeArticle(
            url: GeneratedExplainer.url(explaining: paper.id),
            title: "Explainer: P",
            sourceType: .article,
            state: .ready,
            id: GeneratedExplainer.sourceID(explaining: paper.id)
        )
        vm.articles = [article, paper, explainer, paperExplainer]

        // No tab lists an explainer as a row, though it is an article-typed source.
        for tab in StudioSidebarTab.allCases {
            #expect(!vm.sourceBelongsToTab(explainer, tab: tab), "\(tab)")
            #expect(!vm.sourceBelongsToTab(paperExplainer, tab: tab), "\(tab)")
        }
        vm.sidebarTab = .articles
        #expect(vm.matchesCurrentTab(article))
        #expect(!vm.matchesCurrentTab(explainer))
        #expect(!vm.matchesCurrentTab(paperExplainer))
        #expect(vm.activeTabArticles.map(\.id) == [article.id])

        // The source's row finds its explainer without scanning the library,
        // and the explainer knows its source.
        #expect(vm.explainer(explaining: article.id)?.id == explainer.id)
        #expect(vm.explainer(explaining: paper.id)?.id == paperExplainer.id)
        #expect(vm.explainer(explaining: explainer.id) == nil)
        #expect(vm.explainedSource(of: explainer)?.id == article.id)
        #expect(vm.explainedSource(of: article) == nil)

        // Revealing an explainer goes to the tab of the source it is folded
        // under: a paper's explainer is revealed in Papers, not Articles.
        #expect(vm.sidebarTab(listing: explainer) == .articles)
        #expect(vm.sidebarTab(listing: paperExplainer) == .papers)
        #expect(vm.sidebarTab(listing: paper) == .papers)

        // Deleting the source takes the row's explainer lookup with it.
        vm.articles = [article, paper, paperExplainer]
        #expect(vm.explainer(explaining: article.id) == nil)
        #expect(vm.explainer(explaining: paper.id)?.id == paperExplainer.id)

        // An explainer whose source is gone has no row anywhere to reveal.
        vm.articles = [paperExplainer]
        #expect(vm.sidebarTab(listing: paperExplainer) == nil)
    }


    @Test("switchTab changes sidebarTab")
    func switchTabChanges() {
        let vm = makeViewModel()
        vm.sidebarTab = .articles
        vm.switchTab(to: .papers)
        #expect(vm.sidebarTab == .papers)
    }

    @Test("a Zoom recording is a meeting session, not a video")
    func zoomRecordingsAreMeetings() {
        let vm = makeViewModel()
        vm.meetingMetadata = ["zoom:stanford.zoom.us": MeetingMetadata(title: "stanford.zoom.us")]
        var zoomRecording = makeArticle(
            url: "https://stanford.zoom.us/rec/share/recording-token",
            sourceType: .meeting,
            id: "zoom-recording"
        )
        zoomRecording.parentGroup = "zoom:stanford.zoom.us"
        zoomRecording.discoveryOrigin = .zoom
        let youtubeVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=VIDEO123456",
            sourceType: .video,
            id: "youtube-video"
        )
        vm.articles = [zoomRecording, youtubeVideo]

        #expect(vm.sourceBelongsToTab(zoomRecording, tab: .meetings))
        #expect(!vm.sourceBelongsToTab(zoomRecording, tab: .videos))
        #expect(vm.sourceBelongsToTab(youtubeVideo, tab: .videos))
        #expect(!vm.sourceBelongsToTab(youtubeVideo, tab: .meetings))

        vm.sidebarTab = .meetings
        #expect(vm.matchesCurrentTab(zoomRecording))
        #expect(!vm.matchesCurrentTab(youtubeVideo))

        vm.sidebarTab = .videos
        #expect(!vm.matchesCurrentTab(zoomRecording))
        #expect(vm.matchesCurrentTab(youtubeVideo))

        // Provider is read off the session, so the row wears the Zoom mark and
        // answers the Zoom filter without a tab of its own.
        #expect(MeetingProvider.forOrigin(zoomRecording.discoveryOrigin) == .zoom)
        #expect(vm.meetingGroupProviders("zoom:stanford.zoom.us") == [.zoom])
    }

    @Test("a Zoom recording still stored as a video is not stranded in YouTube")
    func syncedZoomVideoRoutesToMeetings() {
        // Web Studio can only record the broad `video` type, and an older build
        // filed recordings under a Zoom tab. Either way the family is Meetings.
        #expect(
            StudioSidebarTab.knowledgeTab(
                sourceType: .video,
                url: "https://stanford.zoom.us/rec/share/recording-token"
            ) == .meetings
        )
        #expect(
            StudioSidebarTab.knowledgeTab(
                sourceType: .video,
                url: "https://www.youtube.com/watch?v=VIDEO123456"
            ) == .videos
        )
    }

    @Test("a pasted Zoom link joins the series for its Zoom account")
    func zoomRecordingJoinsHostSeries() async {
        let vm = makeViewModel()
        var first = makeArticle(
            url: "https://stanford.zoom.us/rec/share/one",
            sourceType: .meeting,
            id: "zoom-one"
        )
        var second = makeArticle(
            url: "https://stanford.zoom.us/rec/play/two",
            sourceType: .meeting,
            id: "zoom-two"
        )
        await vm.assignZoomMeetingSeries(to: &first, explicit: true)
        await vm.assignZoomMeetingSeries(to: &second, explicit: true)

        // Two occurrences of the same seminar, one row — which is the whole
        // reason a recording had to stop being a video.
        #expect(first.parentGroup == "zoom:stanford.zoom.us")
        #expect(second.parentGroup == first.parentGroup)
        #expect(first.discoveryOrigin == .zoom)
        #expect(vm.meetingMetadata["zoom:stanford.zoom.us"]?.title == "stanford.zoom.us")
    }

    @Test("a Zoom recording joins a series that already answers to its name")
    func zoomRecordingAdoptsExistingSeries() async {
        let vm = makeViewModel()
        // A series already standing under this name takes the session instead of
        // a second row appearing beside it.
        vm.meetingMetadata = ["existing-series": MeetingMetadata(title: "stanford.zoom.us")]
        var recording = makeArticle(
            url: "https://stanford.zoom.us/rec/share/three",
            sourceType: .meeting,
            id: "zoom-three"
        )
        await vm.assignZoomMeetingSeries(to: &recording, explicit: true)
        #expect(recording.parentGroup == "existing-series")
        #expect(vm.meetingMetadata.count == 1)
    }

    @Test("a pasted Zoom link lifts a removed series; an adopted row leaves it removed")
    func zoomRecordingRespectsARemovedSeries() async {
        let identityKey = StudioViewModel.removedMeetingGroupIdentitiesKey
        let titleKey = StudioViewModel.removedMeetingGroupTitlesKey
        let priorIdentities = UserDefaults.standard.stringArray(forKey: identityKey)
        let priorTitles = UserDefaults.standard.stringArray(forKey: titleKey)
        defer {
            if let priorIdentities {
                UserDefaults.standard.set(priorIdentities, forKey: identityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: identityKey)
            }
            if let priorTitles {
                UserDefaults.standard.set(priorTitles, forKey: titleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: titleKey)
            }
        }
        // What removeMeetingGroup leaves behind for a Zoom-account series once
        // the series row itself has been deleted.
        UserDefaults.standard.set(["group:zoom:stanford.zoom.us"], forKey: identityKey)
        UserDefaults.standard.set(["stanford.zoom.us"], forKey: titleKey)
        let vm = makeViewModel()

        // A row adopted from sync or an older build is nobody asking for the
        // series back: it is filed, but the series stays out of sight.
        var adopted = makeArticle(
            url: "https://stanford.zoom.us/rec/share/synced",
            sourceType: .video,
            id: "zoom-synced"
        )
        await vm.assignZoomMeetingSeries(to: &adopted, explicit: false)
        #expect(adopted.parentGroup == "zoom:stanford.zoom.us")
        #expect(vm.meetingMetadata["zoom:stanford.zoom.us"]?.isHidden == true)
        #expect(!vm.visibleMeetingGroupNames.contains("zoom:stanford.zoom.us"))
        #expect(StudioViewModel.isMeetingGroupTitleRemoved("stanford.zoom.us"))

        // A link the learner pastes is the learner asking for the series.
        var pasted = makeArticle(
            url: "https://stanford.zoom.us/rec/share/pasted",
            sourceType: .meeting,
            id: "zoom-pasted"
        )
        await vm.assignZoomMeetingSeries(to: &pasted, explicit: true)
        #expect(pasted.parentGroup == "zoom:stanford.zoom.us")
        #expect(vm.meetingMetadata["zoom:stanford.zoom.us"]?.isHidden == false)
        #expect(!StudioViewModel.isMeetingGroupTitleRemoved("stanford.zoom.us"))
        #expect(!Set(StudioViewModel.loadRemovedMeetingGroupIdentities()).contains("group:zoom:stanford.zoom.us"))
    }

    @Test("switchTab resets searchText")
    func switchTabResetsSearch() {
        let vm = makeViewModel()
        vm.searchText = "some query"
        vm.switchTab(to: .podcasts)
        #expect(vm.searchText == "")
    }

    @Test("switchTab resets displayLimit to 40")
    func switchTabResetsDisplayLimit() {
        let vm = makeViewModel()
        vm.displayLimit = 120
        vm.switchTab(to: .books)
        #expect(vm.displayLimit == 40)
    }

    @Test("switchTab resets articleOriginFilter")
    func switchTabResetsArticleOriginFilter() {
        let vm = makeViewModel()
        vm.articleOriginFilter = .safari
        vm.switchTab(to: .papers)
        #expect(vm.articleOriginFilter == nil)
    }

    /// The sources panel is a filter over the library, not a statement about what is being
    /// read. Switching to Papers — which adding a cited paper does on its own — used to close
    /// the video that cited it.
    @Test("switchTab keeps the source the reader has open")
    func switchTabKeepsOpenSource() {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.selectedArticleId = "video-1"

        vm.switchTab(to: .papers)

        #expect(vm.selectedArticleId == "video-1")
    }

    @Test("switchTab drops a list selection the new tab doesn't show")
    func switchTabPrunesListSelection() {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.selectedArticleIds = ["video-1"]

        vm.switchTab(to: .papers)

        #expect(vm.selectedArticleIds.isEmpty)
    }

    /// Coming back to the tab the open source lives in should land on a highlighted row, not
    /// a list with nothing marked under a reader that is plainly showing one of its items.
    @Test("switchTab re-marks the open source when it belongs to the new tab")
    func switchTabRemarksOpenSource() {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.selectedArticleId = "video-1"
        vm.switchTab(to: .papers)

        vm.switchTab(to: .videos)

        #expect(vm.selectedArticleIds == ["video-1"])
    }

    /// Only fills an empty selection: a multi-selection that survived the filter is the
    /// user's, and collapsing it onto the reader's source would discard it.
    @Test("switchTab leaves a surviving multi-selection alone")
    func switchTabKeepsSurvivingMultiSelection() {
        let vm = makeViewModel()
        vm.articles = [
            makeArticle(url: "https://a.example/paper", sourceType: .paper, id: "paper-1"),
            makeArticle(url: "https://b.example/paper", sourceType: .paper, id: "paper-2"),
            makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1"),
        ]
        vm.switchTab(to: .videos)
        vm.selectedArticleId = "video-1"
        vm.selectedArticleIds = ["paper-1", "paper-2"]

        vm.switchTab(to: .papers)

        #expect(vm.selectedArticleIds == ["paper-1", "paper-2"])
    }

    @Test("hideTab adds to hiddenTabs")
    func hideTabAdds() {
        let vm = makeViewModel()
        vm.hiddenTabs = []
        vm.hideTab(.videos)
        #expect(vm.hiddenTabs.contains(.videos))
    }

    @Test("hideTab switches away if current tab is hidden")
    func hideTabSwitchesAway() {
        let vm = makeViewModel()
        vm.hiddenTabs = []
        vm.tabOrder = StudioSidebarTab.allCases
        vm.sidebarTab = .videos
        vm.hideTab(.videos)
        #expect(vm.sidebarTab != .videos)
    }

    @Test("hideTab keeps the last pinned tab on the bar")
    func hideTabKeepsLastPinnedTab() {
        let vm = makeViewModel()
        vm.tabOrder = StudioSidebarTab.allCases
        vm.hiddenTabs = Set(StudioSidebarTab.allCases).subtracting([.papers])
        #expect(!vm.canUnpinTab(.papers))
        vm.hideTab(.papers)
        #expect(vm.visibleTabs == [.papers])
    }

    @Test("canUnpinTab allows a tab while another stays pinned, and any hidden tab")
    func canUnpinTabWithCompany() {
        let vm = makeViewModel()
        vm.hiddenTabs = []
        #expect(vm.canUnpinTab(.papers))
        vm.hideTab(.papers)
        #expect(vm.hiddenTabs.contains(.papers))
        // A hidden tab is always allowed through: the answer gates unpinning,
        // never pinning back.
        #expect(vm.canUnpinTab(.papers))
    }

    @Test("showTab removes from hiddenTabs")
    func showTabRemoves() {
        let vm = makeViewModel()
        vm.hiddenTabs = [.books, .meetings]
        vm.showTab(.books)
        #expect(!vm.hiddenTabs.contains(.books))
        #expect(vm.hiddenTabs.contains(.meetings))
    }

    @Test("reorderTab moves tab position")
    func reorderTabMoves() {
        let vm = makeViewModel()
        vm.tabOrder = [.articles, .papers, .books, .podcasts, .videos]
        vm.reorderTab(from: .podcasts, to: .articles)
        #expect(vm.tabOrder.first == .podcasts)
    }

    @Test("reconciledOrder completes a partial order without dropping tabs")
    func reconciledOrderCompletesPartialOrder() {
        // The shape that emptied the tab bar: a synced order naming only three
        // tabs. Membership belongs to hiddenTabs, so the rest must come back.
        let order = StudioSidebarTab.reconciledOrder([.podcasts, .books, .articles])
        // The three keep their order; Meetings, missing, slots in after Books.
        #expect(order.filter { [.podcasts, .books, .articles].contains($0) } == [.podcasts, .books, .articles])
        #expect(order.firstIndex(of: .meetings) == order.firstIndex(of: .books).map { $0 + 1 })
        for tab in StudioSidebarTab.allCases {
            #expect(order.contains(tab))
        }
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("reconciledOrder drops duplicates and slots Meetings after Books")
    func reconciledOrderDedupesAndAnchors() {
        let order = StudioSidebarTab.reconciledOrder([.books, .books, .papers])
        #expect(order.filter { $0 == .books }.count == 1)
        if let books = order.firstIndex(of: .books), books + 1 < order.count {
            #expect(order[books + 1] == .meetings)
        } else {
            Issue.record("Books missing from reconciled order")
        }
    }

    @Test("a stored order or hidden set naming the retired Courses tab drops it")
    func persistedCoursesTabIsDropped() {
        // Courses moved to the rail (courses-design.md); "Courses" names no tab.
        #expect(StudioSidebarTab.fromPersistedRawValue("Courses") == nil)
        let order = StudioSidebarTab.reconciledOrder(
            ["Articles", "Courses", "Papers"].compactMap(StudioSidebarTab.fromPersistedRawValue)
        )
        #expect(order.prefix(2) == [.articles, .papers])
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("a saved order naming the retired Zoom tab keeps Meetings' position")
    func persistedZoomTabResolvesToMeetings() {
        #expect(StudioSidebarTab.fromPersistedRawValue("Zoom") == .meetings)
        // Drive, Read AI and Zoom all collapse onto one tab, so an order naming
        // every one of them yields Meetings once rather than three times.
        let order = StudioSidebarTab.reconciledOrder(
            ["Google Drive", "Read AI", "Zoom"].compactMap(StudioSidebarTab.fromPersistedRawValue)
        )
        #expect(order.filter { $0 == .meetings }.count == 1)
        #expect(order.first == .meetings)
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("assigning a partial tabOrder self-heals instead of persisting truncation")
    func tabOrderAssignmentReconciles() {
        let vm = makeViewModel()
        vm.tabOrder = [.podcasts, .books, .articles]
        #expect(vm.tabOrder.count == StudioSidebarTab.allCases.count)
        #expect(vm.tabOrder.contains(.papers))
        #expect(vm.tabOrder.contains(.videos))
        #expect(vm.tabOrder.contains(.meetings))
    }

    @Test("a partial tabOrder still leaves unhidden tabs visible")
    func visibleTabsSurvivePartialOrder() {
        let vm = makeViewModel()
        vm.hiddenTabs = [.xPosts, .meetings]
        vm.tabOrder = [.podcasts, .books, .articles]
        #expect(vm.visibleTabs.contains(.papers))
        #expect(vm.visibleTabs.contains(.videos))
        #expect(!vm.visibleTabs.contains(.xPosts))
    }

    @Test("a series fed by two providers is one row wearing both marks")
    func mixedProviderSeriesListedOnce() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = ["weekly": MeetingMetadata(title: "Weekly Sync", recurrenceRule: "Every Monday")]
        vm.articles = [
            makeArticle(
                url: "https://drive.google.com/file/d/rec",
                title: "Recording",
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings,
                parentGroup: "weekly"
            ),
            makeArticle(
                url: "https://app.read.ai/analytics/meetings/notes",
                title: "Notes",
                sourceType: .meeting,
                discoveryOrigin: .readAI,
                parentGroup: "weekly"
            ),
        ]

        // Under the split Google Drive / Read AI tabs this series was listed
        // twice, once under each tab, because provider decided membership.
        #expect(vm.filteredMeetingGroupNames == ["weekly"])
        #expect(vm.meetingGroupProviders("weekly") == [.googleDrive, .readAI])
        #expect(vm.meetingProvidersInUse == [.googleDrive, .readAI])
        #expect(vm.meetingSessionCountsByProvider[.googleDrive] == 1)
        #expect(vm.meetingSessionCountsByProvider[.readAI] == 1)
    }

    @Test("the provider filter narrows Meetings without deciding membership")
    func meetingProviderFilterNarrows() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = [
            "weekly": MeetingMetadata(title: "Weekly Sync"),
            "readonly": MeetingMetadata(title: "Read AI Only"),
        ]
        let drive = makeArticle(
            url: "https://drive.google.com/file/d/rec",
            title: "Recording",
            sourceType: .meeting,
            discoveryOrigin: .googleDriveMeetings,
            parentGroup: "weekly"
        )
        let readAI = makeArticle(
            url: "https://app.read.ai/analytics/meetings/notes",
            title: "Notes",
            sourceType: .meeting,
            discoveryOrigin: .readAI,
            parentGroup: "readonly"
        )
        vm.articles = [drive, readAI]

        // No filter: every provider's series is present. This is the default.
        #expect(vm.filteredMeetingGroupNames.count == 2)
        #expect(vm.matchesCurrentTab(drive))
        #expect(vm.matchesCurrentTab(readAI))

        vm.meetingProviderFilter = .readAI
        #expect(vm.filteredMeetingGroupNames == ["readonly"])
        #expect(!vm.matchesCurrentTab(drive))
        #expect(vm.matchesCurrentTab(readAI))
        #expect(vm.hasActiveSourceListFilters)

        // Clearing the source-list filters clears the provider with them: the
        // chip lives in that popover, so "Clear" has to reach it.
        vm.clearSourceListFilters()
        #expect(vm.meetingProviderFilter == nil)
        #expect(vm.filteredMeetingGroupNames.count == 2)
    }

    @Test("by date, Meetings lists every session newest first across series, a page at a time")
    func meetingsByDateListsSessionsAcrossSeries() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = [
            "alpha": MeetingMetadata(title: "Alpha Group"),
            "beta": MeetingMetadata(title: "Beta Group"),
        ]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        vm.articles = (0..<45).map { index in
            var session = makeArticle(
                url: "https://example.org/session/\(index)",
                title: "Session \(index)",
                sourceType: .meeting,
                discoveryOrigin: .localMeetings,
                parentGroup: index.isMultiple(of: 2) ? "alpha" : "beta",
                id: "session-\(index)"
            )
            session.dateAdded = start.addingTimeInterval(Double(index) * 86_400)
            return session
        }

        // By series, the tab renders whole groups and never pages.
        #expect(vm.meetingListOrder == .bySeries)
        #expect(vm.activeTabArticles.count == 45)
        #expect(!vm.hasMoreItems)
        #expect(vm.totalFilteredCount == 2)

        vm.meetingListOrder = .byDate
        defer { vm.meetingListOrder = .bySeries }

        let page = vm.activeTabArticles
        #expect(page.count == 40)
        #expect(page.first?.id == "session-44")
        #expect(page.map(\.dateAdded) == page.map(\.dateAdded).sorted(by: >))
        // Neighbouring rows come from different series: the list is not grouped.
        #expect(Set(page.prefix(2).compactMap(\.parentGroup)) == ["alpha", "beta"])
        #expect(vm.hasMoreItems)
        #expect(vm.remainingItemCount == 5)
        #expect(vm.totalFilteredCount == 45)

        vm.showMore()
        #expect(vm.activeTabArticles.count == 45)
        #expect(!vm.hasMoreItems)
    }

    @Test("a session row names its series and its day when listed among other series")
    func meetingSeriesRowTitleNamesTheSeries() {
        let vm = makeViewModel()
        vm.meetingMetadata = ["alpha": MeetingMetadata(title: "Alpha Group")]
        let dated = makeArticle(title: "2026/05/10 08:00 PDT", sourceType: .meeting, parentGroup: "alpha")
        let named = makeArticle(title: "Journal club on ion channels", sourceType: .meeting, parentGroup: "alpha")

        #expect(vm.meetingSeriesRowTitle(for: dated) == "Alpha Group")
        #expect(vm.meetingSeriesRowTitle(for: named) == "Alpha Group — Journal club on ion channels")
        #expect(!vm.meetingSessionWhen(for: dated).isEmpty)
    }

    @Test("a folder imported from this Mac is visible in Meetings")
    func locallyImportedMeetingIsVisible() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = ["offsite": MeetingMetadata(title: "Offsite", localFolderPath: "/Users/me/Recordings")]
        let local = makeArticle(
            url: "file:///Users/me/Recordings/day1.txt",
            title: "Day 1",
            sourceType: .meeting,
            discoveryOrigin: .localMeetings,
            parentGroup: "offsite"
        )
        vm.articles = [local]

        // The split tabs left `localMeetings` with no home: Read AI did not claim
        // it and Google Drive only did after a repair, so a folder imported from
        // disk was briefly invisible everywhere.
        #expect(vm.filteredMeetingGroupNames == ["offsite"])
        #expect(vm.matchesCurrentTab(local))
        #expect(vm.meetingGroupProviders("offsite") == [.localFolder])
    }

    @Test("a linked Drive folder still names its provider with no active sessions")
    func archivedSeriesKeepsItsProvider() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = [
            "weekly": MeetingMetadata(
                title: "Weekly Sync",
                driveFolderURL: "https://drive.google.com/drive/folders/abc"
            )
        ]
        vm.articles = []

        // A connected folder whose sessions had all been archived belonged to no
        // tab at all, so the Drive tab rendered its never-connected empty state
        // over a folder that was in fact connected.
        #expect(vm.filteredMeetingGroupNames == ["weekly"])
        #expect(vm.meetingGroupProviders("weekly") == [.googleDrive])
    }

    @Test("re-importing a meeting folder preserves its user-renamed title")
    func meetingFolderReimportPreservesRenamedTitle() async throws {
        let vm = makeViewModel()
        let groupID = "weekly"
        let folderURL = "https://drive.google.com/drive/folders/folder-123"
        let renamedTitle = "Biostasis Working Group Sync"
        vm.meetingMetadata = [
            groupID: MeetingMetadata(title: renamedTitle, driveFolderURL: folderURL)
        ]
        try await vm.storage.saveMeetingGroup(
            name: groupID,
            metadata: try #require(vm.meetingMetadata[groupID])
        )

        // A later plugin refresh reports the provider-owned folder name
        // again. That discovery title must not replace the learner's rename.
        try await vm.importMeetingArtifacts(
            [],
            groupTitle: "[EF] Biostasis Working Group Sync (15 mins)",
            driveFolderURL: folderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found",
            silent: true
        )

        #expect(vm.meetingMetadata[groupID]?.title == renamedTitle)
        #expect(try await vm.storage.loadMeetingMetadata()[groupID]?.title == renamedTitle)
    }

    @Test("a multi-session meeting refresh publishes one article snapshot")
    func meetingRefreshPublishesOneSnapshot() async throws {
        let priorGroups = UserDefaults.standard.stringArray(forKey: "userMeetingGroupNames")
        defer {
            if let priorGroups {
                UserDefaults.standard.set(priorGroups, forKey: "userMeetingGroupNames")
            } else {
                UserDefaults.standard.removeObject(forKey: "userMeetingGroupNames")
            }
        }

        let vm = makeViewModel()
        let groupID = "stable-group"
        vm.meetingMetadata = [groupID: MeetingMetadata(title: "Weekly Meetings")]

        let sessions = ["Session One", "Session Two"]
        vm.articles = sessions.map { session in
            StudioArticle(
                url: "meeting://\(groupID)/\(StudioViewModel.percentEncodedMeetingPathComponent(session))",
                title: session,
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings,
                parentGroup: groupID
            )
        }
        let artifacts = sessions.enumerated().map { index, session in
            StudioViewModel.ParsedMeetingArtifact(
                url: URL(string: "https://drive.google.com/file/d/transcript-\(index)")!,
                title: "\(session) Transcript",
                sessionKey: session,
                kind: .transcript,
                text: "Speaker: Material for \(session).",
                externalURL: nil,
                localFilePath: nil,
                mimeType: "text/plain",
                modifiedAt: nil
            )
        }

        let revisionBeforeRefresh = vm.articlesRevision
        try await vm.importMeetingArtifacts(
            artifacts,
            groupTitle: "Weekly Meetings",
            driveFolderURL: nil,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No meetings",
            silent: true
        )

        #expect(vm.articlesRevision == revisionBeforeRefresh + 1)

        let revisionBeforeNoOpRefresh = vm.articlesRevision
        try await vm.importMeetingArtifacts(
            artifacts,
            groupTitle: "Weekly Meetings",
            driveFolderURL: nil,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No meetings",
            silent: true
        )

        #expect(vm.articlesRevision == revisionBeforeNoOpRefresh)
    }

    @Test("merging meeting groups moves the row and routes later Read AI sessions")
    func meetingMergeRoutesFutureReadAISessions() async throws {
        let priorGroups = UserDefaults.standard.stringArray(forKey: "userMeetingGroupNames")
        defer {
            if let priorGroups {
                UserDefaults.standard.set(priorGroups, forKey: "userMeetingGroupNames")
            } else {
                UserDefaults.standard.removeObject(forKey: "userMeetingGroupNames")
            }
        }

        let vm = makeViewModel()
        let readAIGroup = "read-ai-weekly"
        let destination = "weekly"
        vm.meetingMetadata = [
            readAIGroup: MeetingMetadata(title: "Weekly Sync from Read AI"),
            destination: MeetingMetadata(title: "Weekly Sync"),
        ]
        try await vm.storage.saveMeetingGroup(
            name: readAIGroup,
            metadata: vm.meetingMetadata[readAIGroup]!
        )
        try await vm.storage.saveMeetingGroup(
            name: destination,
            metadata: vm.meetingMetadata[destination]!
        )
        var existing = StudioArticle(
            url: "meeting://\(readAIGroup)/old-session",
            title: "Old session",
            sourceType: .meeting,
            discoveryOrigin: .readAI,
            parentGroup: readAIGroup
        )
        existing.content = "# Old session\n\n## Transcript\n\nOld material"
        existing.state = .ready
        try await vm.storage.saveSource(existing)
        vm.articles = [existing]

        await vm.mergeMeetingGroup(readAIGroup, into: destination)

        #expect(vm.visibleMeetingGroupNames == [destination])
        #expect(vm.articles.first?.parentGroup == destination)
        #expect(vm.meetingMetadata[readAIGroup]?.mergedIntoGroupID == destination)

        // Both the app importer and the Read AI MCP importer resolve this old
        // title before constructing the next session's stable meeting URL.
        #expect(vm.existingMeetingID(forTitle: "Weekly Sync from Read AI") == destination)
    }

    @Test("a background folder refresh cannot bring back a session the learner removed")
    func removedSessionStaysRemovedAcrossFolderRefresh() async throws {
        let vm = makeViewModel()
        let groupID = "acme-nexus"
        let folderURL = "https://drive.google.com/drive/folders/folder-acme"
        let metadata = MeetingMetadata(title: "Acme Lab Nexus", driveFolderURL: folderURL)
        vm.meetingMetadata = [groupID: metadata]
        try await vm.storage.saveMeetingGroup(name: groupID, metadata: metadata)
        let sessionKey = "2026/08/30"
        let notes = StudioViewModel.ParsedMeetingArtifact(
            url: URL(string: "https://drive.google.com/file/d/notes-0830")!,
            title: "2026-08-30 - [Notes] - Journal Club",
            sessionKey: sessionKey,
            kind: .notes,
            text: "* Somatic mutations in Hashimoto's thyroiditis, discussed.",
            externalURL: nil,
            localFilePath: nil,
            mimeType: nil,
            modifiedAt: nil
        )
        let sessionURL = "meeting://\(groupID)/\(StudioViewModel.percentEncodedMeetingPathComponent(sessionKey))"
        func refresh(silent: Bool) async throws {
            try await vm.importMeetingArtifacts(
                [notes],
                groupTitle: "Acme Lab Nexus",
                driveFolderURL: folderURL,
                localFolderPath: nil,
                discoveryOrigin: .googleDriveMeetings,
                emptyMessage: "No supported meeting files found",
                silent: silent
            )
        }

        try await refresh(silent: true)
        let session = try #require(vm.articles.first { $0.url == sessionURL })

        // The learner removes the session. `removeSelected` hides it, then once
        // the Undo window closes dismisses the URL and archives the row, which
        // also drops it from the active rows the view model holds.
        try await vm.storage.dismissSources([session])
        vm.articles.removeAll { $0.id == session.id }
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).first?.status == .archived)

        // The next refresh walks the same folder and finds the same file. It
        // used to see a session the folder had just gained and upsert the
        // archived row back to active.
        try await refresh(silent: true)
        #expect(!vm.articles.contains { $0.url == sessionURL })
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).first?.status == .archived)
        #expect(await vm.storage.isSourceDismissed(url: sessionURL))

        // Choosing the folder again is the learner asking for it back: the
        // tombstone is lifted and the session returns.
        try await refresh(silent: false)
        #expect(vm.articles.contains { $0.url == sessionURL })
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).first?.status == .active)
        #expect(!(await vm.storage.isSourceDismissed(url: sessionURL)))
    }

    @Test("a background Drive import cannot resurrect a removed folder under a new title")
    func removedDriveFolderStaysHiddenAcrossProviderRename() async throws {
        let identityKey = StudioViewModel.removedMeetingGroupIdentitiesKey
        let titleKey = StudioViewModel.removedMeetingGroupTitlesKey
        let priorIdentities = UserDefaults.standard.stringArray(forKey: identityKey)
        let priorTitles = UserDefaults.standard.stringArray(forKey: titleKey)
        defer {
            if let priorIdentities {
                UserDefaults.standard.set(priorIdentities, forKey: identityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: identityKey)
            }
            if let priorTitles {
                UserDefaults.standard.set(priorTitles, forKey: titleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: titleKey)
            }
        }

        let vm = makeViewModel()
        let groupID = "acme-nexus"
        let folderURL = "https://drive.google.com/drive/folders/folder-acme"
        let metadata = MeetingMetadata(title: "Acme Nexus – Member Drive", driveFolderURL: folderURL)
        vm.meetingMetadata = [groupID: metadata]
        try await vm.storage.saveMeetingGroup(name: groupID, metadata: metadata)
        UserDefaults.standard.set(["google-drive-folder:folder-acme"], forKey: identityKey)
        UserDefaults.standard.set([], forKey: titleKey)

        try await vm.importMeetingArtifacts(
            [],
            groupTitle: "Acme Nexus renamed upstream",
            driveFolderURL: folderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found",
            silent: true
        )

        #expect(vm.meetingMetadata[groupID]?.isHidden == true)
        #expect(try await vm.storage.loadMeetingMetadata()[groupID]?.isHidden == true)

        // Choosing the folder again is explicit restoration and may lift the
        // exact tombstone; only a background/event refresh is forbidden.
        try await vm.importMeetingArtifacts(
            [],
            groupTitle: "Acme Nexus renamed upstream",
            driveFolderURL: folderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found",
            silent: false
        )

        #expect(vm.meetingMetadata[groupID]?.isHidden == false)
        #expect(!StudioViewModel.loadRemovedMeetingGroupIdentities().contains("google-drive-folder:folder-acme"))
    }

    @Test("a plugin tab is not pinned back by content the plugin pushed")
    func pluginTabStaysUnpinnedOnSourceArrival() {
        let vm = makeViewModel()
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
        }
        vm.hiddenTabs = [.meetings, .xPosts]
        vm.autoUnpinnedIntegrationTabs = [.meetings, .xPosts]

        vm.articles = [
            StudioArticle(
                url: "https://app.read.ai/analytics/meetings/abc",
                title: "Standup",
                sourceType: .meeting,
                discoveryOrigin: .readAI
            )
        ]

        // A Read AI meeting arriving is the plugin's doing, not a request for
        // the tab. Pinning on arrival is what put Read AI back on the tab bar
        // after every rebuild.
        //
        // Nothing about a Read AI meeting speaks for X, so X stays off the tab
        // bar either way. That half is machine-independent.
        #expect(!vm.visibleTabs.contains(.xPosts))
        #expect(vm.autoUnpinnedIntegrationTabs.contains(.xPosts))

        // Meetings is not plugin-backed as a whole: being signed into Google
        // Drive pins it on its own, correctly and regardless of this article. So
        // the end-to-end assertion is only meaningful on a machine with no Drive
        // account attached — `sourceArrivalPinsTabIgnoresPluginPushes` covers
        // the rule itself with no such dependency.
        if !GoogleDriveService.shared.isSignedIn {
            #expect(!vm.visibleTabs.contains(.meetings))
            #expect(vm.autoUnpinnedIntegrationTabs.contains(.meetings))
        }
    }

    @Test("a source only pins its tab when its arrival is the learner's own doing")
    func sourceArrivalPinsTabIgnoresPluginPushes() {
        // Read AI pushes meetings in; Drive sync and folder imports are asked
        // for. One tab now covers all three, so the rule reads the session's
        // provider rather than the tab's classification.
        #expect(!StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .readAI))
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .googleDriveMeetings))
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .localMeetings))
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: nil))
        // A pasted Zoom link is the learner's own doing too, so it pins.
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .zoom))
        // Everything else pins on its first source.
        #expect(StudioViewModel.sourceArrivalPinsTab(.papers, discoveryOrigin: .localPapers))
        #expect(StudioViewModel.sourceArrivalPinsTab(.xPosts, discoveryOrigin: .xBookmarks))
    }

    @Test("a non-plugin integration tab is pinned back once its first source arrives")
    func integrationTabPinsOnFirstSource() {
        let vm = makeViewModel()
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
        }
        vm.hiddenTabs = [.meetings, .xPosts]
        vm.autoUnpinnedIntegrationTabs = [.meetings, .xPosts]

        vm.articles = [
            StudioArticle(
                url: "https://drive.google.com/file/d/abc",
                title: "Weekly sync",
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings
            )
        ]

        #expect(vm.visibleTabs.contains(.meetings))
        // Nothing points at X being in use, so it stays off the tab bar.
        #expect(!vm.visibleTabs.contains(.xPosts))
        #expect(!vm.autoUnpinnedIntegrationTabs.contains(.meetings))
    }

    @Test("a tab the learner unpinned is not pinned back by its own sources")
    func userUnpinnedIntegrationTabStaysUnpinned() {
        let vm = makeViewModel()
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
        }
        vm.hiddenTabs = []
        vm.autoUnpinnedIntegrationTabs = [.meetings]
        // Unpinning by hand drops Studio's claim over the tab, even though the
        // tab was unpinned by default earlier.
        vm.hideTab(.meetings)
        #expect(!vm.autoUnpinnedIntegrationTabs.contains(.meetings))

        vm.articles = [
            StudioArticle(
                url: "https://drive.google.com/file/d/def",
                title: "Retro",
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings
            )
        ]

        #expect(!vm.visibleTabs.contains(.meetings))
    }

    @Test("a recorded integration unpin never re-applies over a stored pin choice")
    func integrationUnpinDefaultsRespectStoredChoice() {
        let vm = makeViewModel()
        let appliedKey = StudioSidebarTab.integrationUnpinAppliedPreferenceKey
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        let savedApplied = UserDefaults.standard.stringArray(forKey: appliedKey)
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
            if let savedApplied {
                PreferenceStore.set(savedApplied, forKey: appliedKey)
            } else {
                PreferenceStore.remove(forKey: appliedKey)
            }
        }
        // The shape a rebuild produces once the marker is durable: hydration has
        // restored both the applied marker and the pin state the learner chose —
        // Meetings pinned by hand, X unpinned by hand.
        PreferenceStore.set(
            StudioSidebarTab.allCases.filter(\.requiresIntegrationSetup).map(\.rawValue).sorted(),
            forKey: appliedKey
        )
        vm.hiddenTabs = [.xPosts]
        vm.autoUnpinnedIntegrationTabs = []

        vm.applyIntegrationTabUnpinDefaults()

        // A tab the learner pinned stays pinned...
        #expect(!vm.hiddenTabs.contains(.meetings))
        // ...and one they unpinned is not handed back to Studio to pin later.
        #expect(vm.hiddenTabs.contains(.xPosts))
        #expect(vm.autoUnpinnedIntegrationTabs.isEmpty)
    }

    @Test("an unrecorded integration unpin hides the plugin tabs once")
    func integrationUnpinDefaultsApplyOnce() {
        let vm = makeViewModel()
        let appliedKey = StudioSidebarTab.integrationUnpinAppliedPreferenceKey
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        let savedApplied = UserDefaults.standard.stringArray(forKey: appliedKey)
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
            if let savedApplied {
                PreferenceStore.set(savedApplied, forKey: appliedKey)
            } else {
                PreferenceStore.remove(forKey: appliedKey)
            }
        }
        PreferenceStore.set([String](), forKey: appliedKey)
        vm.hiddenTabs = []
        vm.autoUnpinnedIntegrationTabs = []

        vm.applyIntegrationTabUnpinDefaults()

        #expect(vm.hiddenTabs.contains(.meetings))
        #expect(vm.hiddenTabs.contains(.xPosts))
        // Recorded, so the next launch — or the next rebuild, now that the marker
        // is on the sync rail — leaves the learner's pins alone.
        let applied = Set(UserDefaults.standard.stringArray(forKey: appliedKey) ?? [])
        for tab in StudioSidebarTab.allCases where tab.requiresIntegrationSetup {
            #expect(applied.contains(tab.rawValue))
        }
        #expect(StudioViewModel.integrationTabUnpinState().pending.isEmpty)
    }

    @Test("reorderTab no-op for same source and destination")
    func reorderTabSamePosition() {
        let vm = makeViewModel()
        let original = Array(vm.tabOrder)
        vm.reorderTab(from: .articles, to: .articles)
        #expect(vm.tabOrder == original)
    }

    @Test("showMore increments displayLimit by 40")
    func showMoreIncrements() {
        let vm = makeViewModel()
        vm.displayLimit = 40
        vm.showMore()
        #expect(vm.displayLimit == 80)
        vm.showMore()
        #expect(vm.displayLimit == 120)
    }

    @Test("visibleTabs filters out hiddenTabs")
    func visibleTabsFilters() {
        let vm = makeViewModel()
        vm.tabOrder = [.articles, .papers, .books, .podcasts, .videos]
        vm.hiddenTabs = [.books, .videos]
        let visible = vm.visibleTabs
        #expect(!visible.contains(.books))
        #expect(!visible.contains(.videos))
        #expect(visible.contains(.articles))
        #expect(visible.contains(.papers))
    }

    @Test("visibleTabs respects tabOrder")
    func visibleTabsOrder() {
        let vm = makeViewModel()
        vm.tabOrder = [.podcasts, .books, .articles]
        vm.hiddenTabs = []
        let visible = vm.visibleTabs
        // The three keep the specified order (Meetings, which the order does
        // not name, slots in after Books).
        #expect(visible.filter { [.podcasts, .books, .articles].contains($0) } == [.podcasts, .books, .articles])
        #expect(visible.first == .podcasts)
    }
}

@Suite("Cross-window Studio Drops")
@MainActor
struct CrossWindowStudioDropTests {
    @Test("A pane drop changes the destination window only")
    func paneDropUsesDestinationWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .chat
            ),
        ])
        let sourceLayout = vm.centerTabGroups
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat|reader*|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))

        vm.placeCenterTabAtEdge(.notepad, leading: false, in: destination)

        #expect(vm.centerTabGroups == sourceLayout)
        #expect(destination.centerTabGroups.groups.count == 2)
        #expect(destination.centerTabGroups.groups.last == .init(tabs: [.notepad], activeTab: .notepad))
    }

    @Test("Dragging the Library, which fills the window, to an edge docks it and gives the rest to Chat")
    func libraryFillingTheWindowDocksAtAnEdge() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let window = StudioWindowState(snapshot: .init(
            centerTabGroups: StudioCenterTabGroups(groups: [
                .init(tabs: StudioCenterTab.permanentTabs, activeTab: .library),
            ]).persistedRepresentation,
            navigationRailVisible: true
        ))

        vm.placeCenterTabAtEdge(.library, leading: false, in: window)

        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.chat, .library])
        #expect(window.centerTabGroups.groups.last?.tabs == [.library])

        // Dropped on the other edge, the docked pane moves across.
        vm.placeCenterTabAtEdge(.library, leading: true, in: window)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.library, .chat])
    }

    @Test("A source drop changes the destination Reader only")
    func sourceDropUsesDestinationReader() async {
        let source = StudioWindowState()
        source.readerArticleID = "source-on-right-display"
        let destination = StudioWindowState()
        let vm = makeViewModel()

        await vm.selectArticle("source-on-left-display", in: destination)

        #expect(source.readerArticleID == "source-on-right-display")
        #expect(destination.readerArticleID == "source-on-left-display")
    }

    @Test("The Docs index and a doc reveal name the window they were asked in, so another window's Doc stays open")
    func docsIndexAndRevealStayInTheirWindow() {
        let leftDisplay = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat|reader|tasks|activity|notepad*|sites|browser|videos|notebooks"],
            navigationRailVisible: true
        ))
        let rightDisplay = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|activity|notepad|sites|browser|videos|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()

        // Docs clicked in the right-hand window: that window shows the index,
        // and the request says so; the left window's canvas is not addressed.
        vm.openNotepadInReader(in: rightDisplay)
        #expect(vm.artifactIndexRequest?.windowID == rightDisplay.id)
        #expect(vm.artifactIndexRequest?.windowID != leftDisplay.id)
        #expect(rightDisplay.centerTabGroups.groups.contains { $0.activeTab == .notepad })

        vm.openSitesInReader(in: leftDisplay)
        #expect(vm.artifactIndexRequest?.section == .sites)
        #expect(vm.artifactIndexRequest?.windowID == leftDisplay.id)

        // A doc revealed for one window carries that window; a second reveal is
        // a distinct request even for the same doc and window.
        vm.revealArtifact("doc-1", in: rightDisplay)
        let first = vm.artifactRevealRequest
        #expect(first?.windowID == rightDisplay.id)
        #expect(first?.artifactID == "doc-1")
        vm.revealArtifact("doc-1", in: rightDisplay)
        #expect(vm.artifactRevealRequest != first)

        // With no window named, the request is for the window the click was
        // made in — the active one — never for every window.
        vm.openNotepadInReader()
        #expect(vm.artifactIndexRequest?.windowID == vm.activeWindowState.id)
    }

    @Test("a web citation opens beside Chat without entering the library")
    func webCitationIsTransientUntilSaved() async throws {
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()
        let initialSourceIDs = vm.articles.map(\.id)
        let url = try #require(URL(string: "https://example.com/paper.pdf?utm_source=research"))

        vm.openWebCitationInReader(url, title: "Primary research", in: destination)

        let page = try #require(destination.externalReaderPage)
        #expect(page.url == url)
        #expect(page.title == "Primary research")
        #expect(page.article.sourceType == .paper)
        #expect(vm.articles.map(\.id) == initialSourceIDs)
        #expect(destination.centerTabGroups.groups.count == 2)
        #expect(destination.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])

        await vm.selectArticle("saved-source", in: destination)
        #expect(destination.externalReaderPage == nil)
        #expect(destination.readerArticleID == "saved-source")
    }

    @Test("reader history returns from an unsaved web citation to its saved source")
    func externalCitationBackState() throws {
        let window = StudioWindowState()
        window.readerArticleID = "saved-source"
        let url = try #require(URL(string: "https://example.com/research"))
        window.externalReaderPage = StudioExternalReaderPage(url: url, title: "Research")

        #expect(window.readerArticleID == "saved-source")
        #expect(window.readerBackStack.isEmpty)
        window.externalReaderPage = nil
        #expect(window.readerArticleID == "saved-source")
    }

    @Test("Reader source history belongs to its Studio window")
    func readerHistoryIsPerWindow() {
        let first = StudioWindowState()
        let second = StudioWindowState()

        first.readerArticleID = "article-a"
        first.readerArticleID = "paper-b"
        second.readerArticleID = "transcript-c"

        #expect(first.readerBackStack == ["article-a"])
        #expect(second.readerBackStack.isEmpty)
        #expect(first.navigateReaderBack(where: { _ in true }) == "article-a")
        #expect(first.readerArticleID == "article-a")
        #expect(first.readerBackStack.isEmpty)
        #expect(second.readerArticleID == "transcript-c")
    }

    @Test("Reader Back retires missing sources and does not loop")
    func readerHistorySkipsUnavailableSources() {
        let window = StudioWindowState()
        window.readerArticleID = "article-a"
        window.readerArticleID = "removed-paper"
        window.readerArticleID = "chapter-c"

        #expect(window.readerBackStack == ["article-a", "removed-paper"])
        #expect(window.navigateReaderBack(where: { $0 == "article-a" }) == "article-a")
        #expect(window.readerArticleID == "article-a")
        #expect(window.readerBackStack.isEmpty)
        #expect(window.navigateReaderBack(where: { _ in true }) == nil)
    }

    @Test("Sending a source to another window reveals only that window's Reader")
    func activatingATabTargetsTheDestinationWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        let sourceLayout = vm.centerTabGroups
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))

        vm.activateCenterTab(.reader, in: destination)

        #expect(vm.centerTabGroups == sourceLayout)
        #expect(destination.centerTabGroups.groups.map(\.activeTab) == [.reader])
    }

    @Test("Sending a source elsewhere leaves this window on what it was reading")
    func openingInAnotherWindowPinsTheActingWindow() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let reading = makeArticle(url: "https://example.com/reading", title: "Being read")
        // Content on the row keeps selectArticle from fetching
        // https://example.com for real: this test is about where the
        // selection lands, not about fetching.
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [reading, sent]
        // The acting window shows its source the legacy way: no local choice of
        // its own, so it renders whatever the global selection points at.
        let acting = StudioWindowState()
        vm.selectedArticleId = reading.id
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerArticleID == reading.id)
        #expect(other.readerArticleID == sent.id)
    }

    @Test("Sending the source this window is reading empties its Reader, one Back away")
    func openingInAnotherWindowClosesTheSourceHere() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [sent]
        // The acting window has never navigated on its own, so what it shows is
        // the global selection — the case the Reader's own menu is opened from.
        let acting = StudioWindowState()
        vm.selectedArticleId = sent.id
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerSourceID(fallingBackTo: vm.selectedArticleId) == nil)
        #expect(acting.readerBackStack == [sent.id])
        #expect(other.readerArticleID == sent.id)
    }

    @Test("Sending the source this window is reading closes its Reader pane")
    func openingInAnotherWindowClosesTheReaderPaneHere() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [sent]
        let acting = StudioWindowState()
        acting.readerArticleID = sent.id
        // The Reader is a split pane beside Chat, the layout in which "make
        // room" means something: the pane folds into its neighbour rather than
        // staying behind on "Continue reading".
        acting.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerArticleID == nil)
        #expect(acting.centerTabGroups.groups.count == 1)
        #expect(acting.centerTabGroups.groups[0].activeTab == .chat)
        #expect(acting.centerTabGroups.groups[0].tabs.contains(.reader))
        #expect(other.readerArticleID == sent.id)
    }

    @Test("Sending a source from the sidebar leaves a pane that was not showing the Reader alone")
    func openingInAnotherWindowKeepsAPaneShowingSomethingElse() async {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let sent = makeArticle(url: "https://example.com/sent", title: "Sent away").with(content: "Sent away, already read.")
        vm.articles = [sent]
        let acting = StudioWindowState()
        acting.readerArticleID = sent.id
        // The Reader holds the source but Docs is on screen in its pane; the
        // learner is looking at Docs, so that pane stays.
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library],
                activeTab: .notepad
            ),
        ])
        acting.centerTabGroups = layout
        let other = StudioWindowState()

        StudioOtherWindowTargets.open(sent.id, in: other, from: acting, vm: vm)
        await vm.selectArticle(sent.id, in: other)

        #expect(acting.readerArticleID == nil)
        #expect(acting.centerTabGroups == layout)
    }

    @Test("Other-window targets exclude this window and are named by screen position")
    func otherWindowTargetsAreOrderedAndLabelled() {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://example.com/mitochondrial-transplantation",
            title: "Mitochondrial Transplantation",
            sourceType: .paper
        )
        vm.articles = [paper]

        let current = StudioWindowState()
        current.workspacePlacement = placement(displayIndex: 0, x: 0.5)
        let left = StudioWindowState()
        left.workspacePlacement = placement(displayIndex: 0, x: 0.0)
        let secondDisplay = StudioWindowState()
        secondDisplay.workspacePlacement = placement(displayIndex: 1, x: 0.0)
        secondDisplay.readerArticleID = paper.id

        let targets = StudioOtherWindowTargets.targets(
            among: [secondDisplay, current, left],
            excluding: current,
            vm: vm
        )

        // Window 2 is missing by design: it is the window the menu was opened
        // in, and its number still reflects where it sits on screen.
        #expect(targets.map(\.label) == ["Window 1", "Window 3 — Mitochondrial Transplantation"])
        #expect(targets.map(\.state.id) == [left.id, secondDisplay.id])
    }

    @Test("A doc sent to another window opens Docs there, not here")
    func docOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()

        StudioWindowDestination.doc("doc-1").open(in: other, vm: vm)

        #expect(other.centerTabGroups.groups.contains { $0.activeTab == .notepad })
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .notepad } == false)
        #expect(vm.artifactRevealRequest?.artifactID == "doc-1")
    }

    @Test("A site comes forward in Sites, a doc in Docs, and each rail row asks its own index")
    func sitesAndDocsAreSeparateSections() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let now = Date()
        vm.artifacts = [
            ArtifactRecord(id: "doc-1", title: "Notes", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: now, updatedAt: now),
            ArtifactRecord(
                id: "gdoc-1", title: "Shared plan", homeNotebookID: nil, linkedNotebookIDs: [],
                linkedURL: "https://docs.google.com/document/d/1abcDEFghiJKLmnoPQRstuVWxyz0123456789/edit",
                createdAt: now, updatedAt: now
            ),
            ArtifactRecord(
                id: "site-1", title: "TechBio", homeNotebookID: nil, linkedNotebookIDs: [],
                linkedURL: "https://techbio.learner-1234.chatgpt.site/",
                createdAt: now, updatedAt: now
            ),
        ]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])

        // The rail's Sites row lands on the Sites index and leaves Docs alone.
        vm.openSitesInReader()
        #expect(vm.activeCenterTabs.contains(.sites))
        #expect(!vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactIndexRequest?.section == .sites)
        vm.openNotepadInReader()
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactIndexRequest?.section == .docs)

        // A record comes forward in the section its link puts it in.
        #expect(vm.artifactSection(of: "doc-1") == .docs)
        #expect(vm.artifactSection(of: "gdoc-1") == .docs)
        #expect(vm.artifactSection(of: "site-1") == .sites)
        #expect(vm.artifactSection(of: "unknown") == .docs)

        vm.revealArtifact("site-1")
        #expect(vm.activeCenterTabs.contains(.sites))
        #expect(vm.artifactRevealRequest?.artifactID == "site-1")
        #expect(vm.artifactRevealRequest?.section == .sites)

        vm.revealArtifact("gdoc-1")
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactRevealRequest?.artifactID == "gdoc-1")
        #expect(vm.artifactRevealRequest?.section == .docs)

        // A Markdown doc stays a Doc while it has a page on foreverlm.com
        // (product owner, 2026-09-10: "published docs stay in docs"); the published
        // projection never moves a record between sections.
        let page = PublishedDocStatus(
            docID: "doc-1", url: URL(string: "https://foreverlm.com/share/notes")!, slug: "notes",
            title: "Notes", publishedAt: now, updatedAt: now, isProtected: false, password: nil
        )
        vm.publishedDocStatuses["doc-1"] = page
        #expect(vm.artifactSection(of: "doc-1") == .docs)
        vm.revealArtifact("doc-1")
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.artifactRevealRequest?.section == .docs)
        vm.publishedDocStatuses["gdoc-1"] = page
        #expect(vm.artifactSection(of: "gdoc-1") == .docs)
        vm.publishedDocStatuses.removeValue(forKey: "doc-1")
        #expect(vm.artifactSection(of: "doc-1") == .docs)
    }

    @Test("Sites sent to another window opens there, not here")
    func sitesOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()

        StudioWindowDestination.sites.open(in: other, vm: vm)

        #expect(other.centerTabGroups.groups.contains { $0.activeTab == .sites })
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .sites } == false)
        #expect(StudioWindowDestination.sites.noun == "Sites")
    }

    @Test("A Notebook sent to another window opens its notebook there, over panes left as they were")
    func notebookOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()
        let otherPanes = other.centerTabGroups

        StudioWindowDestination.notebook("notebook-1").open(in: other, vm: vm)

        // The notebook belongs to the window it was sent to, and the open
        // notebook read in that window is it; the acting window holds none.
        // Its workspace draws that window, so the panes underneath are not
        // rearranged.
        #expect(vm.inWindow(other) { vm.workbenchNotebookID } == "notebook-1")
        #expect(other.NotebookID == "notebook-1")
        #expect(acting.NotebookID == nil)
        #expect(other.centerTabGroups == otherPanes)
        #expect(vm.visibleCenterTabs(in: other) == [.chat])
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .artifacts } == false)
    }

    @Test("A chat sent to another window is that window's chat request")
    func chatOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let other = StudioWindowState()

        StudioWindowDestination.chat("session-1").open(in: other, vm: vm)

        // The request token is stamped with the window it was made in, which is
        // what `inWindow` scoping is for: without it the chat would land in
        // whichever window happened to be key.
        #expect(vm.reviewChatTargetWindowID == other.id)
    }

    @Test("A new chat sent to another window is a blank chat request for that window")
    func newChatOpensInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let other = StudioWindowState()

        StudioWindowDestination.newChat.open(in: other, vm: vm)

        #expect(vm.reviewChatTargetWindowID == other.id)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(StudioWindowDestination.newChat.noun == "chat")
    }

    @Test("The Docs and Notebooks panes open in the target window without an id")
    func paneDestinationsOpenInTheTargetWindow() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        let acting = StudioWindowState()
        let other = StudioWindowState()

        StudioWindowDestination.docs.open(in: other, vm: vm)
        StudioWindowDestination.artifacts.open(in: other, vm: vm)

        #expect(other.centerTabGroups.groups.contains { $0.activeTab == .artifacts })
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .notepad } == false)
        #expect(acting.centerTabGroups.groups.contains { $0.activeTab == .artifacts } == false)
    }

    private func placement(displayIndex: Int, x: Double) -> StudioWindowPlacement {
        StudioWindowPlacement(
            displayIndex: displayIndex,
            normalizedX: x,
            normalizedY: 0,
            normalizedWidth: 0.5,
            normalizedHeight: 1
        )
    }

    @Test("A window's first local selection preserves its displayed legacy source")
    func firstWindowSelectionCapturesLegacySource() async {
        let destination = StudioWindowState()
        let vm = makeViewModel()
        vm.selectedArticleId = "previously-visible-source"

        await vm.selectArticle("new-local-source", in: destination)

        #expect(destination.readerArticleID == "new-local-source")
        #expect(destination.readerBackStack == ["previously-visible-source"])
    }

    @Test("A Sources row click reads in its own window, not the registry's key window")
    func sidebarRowClickReadsInItsOwnWindow() async {
        let clicked = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()
        let keyWindow = vm.activeWindowState
        let keyWindowLayout = keyWindow.centerTabGroups
        vm.selectedArticleId = "post-already-open"

        await vm.selectArticle("post-clicked-here", in: clicked, revealingReader: true)

        #expect(clicked.readerArticleID == "post-clicked-here")
        #expect(clicked.sidebarSelectedSourceIDs == ["post-clicked-here"])
        #expect(clicked.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        // The window the registry still called key keeps what it was showing.
        #expect(keyWindow.readerArticleID == "post-already-open")
        #expect(keyWindow.centerTabGroups == keyWindowLayout)
    }
}

@Suite("Docs Fresh Chat Navigation")
@MainActor
struct DocsFreshChatNavigationTests {
    @Test("Notepad selection opens a fresh Chat beside Docs")
    func notepadSelectionOpensFreshSplitChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.notepad], activeTab: .notepad),
            .init(tabs: [.chat, .reader, .tasks, .artifacts], activeTab: .artifacts),
        ])
        vm.requestNotepadChat(
            noteTitle: "Mitochondria",
            selectedText: "  selected note passage  ",
            sourceIDs: ["source-a", "source-b"],
            artifactID: "artifact-a",
            artifactRevision: "revision-a",
            artifactNotebookID: "notebook-a",
            selectionRange: 4..<25,
            contextExcerpt: "A little context around selected note passage.",
            artifactAttachment: ChatDocAttachment(
                id: "artifact-a",
                title: "Mitochondria",
                revision: "revision-a",
                outline: ["Mitochondria"]
            )
        )

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .chat])
        #expect(vm.reviewChatResetRequestID != nil)
        // The doc's home Notebook frames the chat, and the doc itself rides along.
        #expect(vm.pendingReviewChatNotebookID == "notebook-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactAttachment?.id == "artifact-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactAttachment?.revision == "revision-a")
        #expect(vm.readerSelectionExplanationRequest?.sourceIDs == ["source-a", "source-b"])
        #expect(vm.readerSelectionExplanationRequest?.selectedText == "selected note passage")
        #expect(vm.readerSelectionExplanationRequest?.contextTitle == "Note: Mitochondria")
        #expect(vm.readerSelectionExplanationRequest?.artifactID == "artifact-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactRevision == "revision-a")
        #expect(vm.readerSelectionExplanationRequest?.artifactNotebookID == "notebook-a")
        #expect(vm.readerSelectionExplanationRequest?.selectionRange == 4..<25)
        #expect(
            vm.readerSelectionExplanationRequest?.contextualContent()
                .contains("Exact surrounding excerpt:\n<article_excerpt>") == true
        )
        #expect(vm.readerSelectionExplanationRequest?.contextualContent().contains("Article ID: artifact-a") == true)
        #expect(vm.readerSelectionExplanationRequest?.contextualContent().contains("Full note document") == false)
        #expect(vm.reviewChatFocusRequestID != nil)
    }

    @Test("Docs keeps its pane and an open Chat keeps its side, as beside the Reader")
    func notepadSelectionRevealsChatOnDocsRight() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        // Chat already open on the doc's left: both panes stay where the
        // learner put them. Handing a passage over must not swap them.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks], activeTab: .tasks),
            .init(tabs: [.notepad, .sites, .reader, .activity, .goals, .ideas, .browser, .videos, .animations, .artifacts], activeTab: .notepad),
        ])
        handOffPassage(in: vm)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .tasks], activeTab: .chat),
            .init(tabs: [.notepad, .sites, .reader, .activity, .goals, .ideas, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library], activeTab: .notepad),
        ])

        // Docs as the sole pane: Chat peels out into a new pane on its right
        // and asks the window for room, the way the Reader's handoff does.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts], activeTab: .notepad),
        ])
        handOffPassage(in: vm)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.reader, .tasks, .activity, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library], activeTab: .notepad),
            .init(tabs: [.chat], activeTab: .chat),
        ])
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.readerChatSpaceRequestID != nil)
    }

    @Test("Add to Chat brings an open Chat forward in place without starting a fresh conversation")
    func addToChatRevealsChatOnDocsRight() async throws {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let snapshot = try await vm.createArtifact(
            title: "Mitochondria",
            homeNotebookID: nil,
            linkedNotebookIDs: []
        )
        let resetBefore = vm.reviewChatResetRequestID

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts], activeTab: .notepad),
        ])
        await vm.attachDocToChat(snapshot.artifact.id)

        // Both panes were already open, so neither moves.
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .goals, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .courses, .memory, .knowledgeMap, .atlas, .library], activeTab: .notepad),
        ])
        #expect(vm.pendingChatDocAttachment?.id == snapshot.artifact.id)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatFocusRequestID != nil)
        // Additive, like a dropped source: the open conversation is kept.
        #expect(vm.reviewChatResetRequestID == resetBefore)
    }

    private func handOffPassage(in vm: StudioViewModel) {
        vm.requestNotepadChat(
            noteTitle: "Mitochondria",
            selectedText: "selected note passage",
            sourceIDs: ["source-a"],
            artifactID: "artifact-a",
            artifactRevision: "revision-a",
            artifactNotebookID: nil,
            selectionRange: nil,
            contextExcerpt: nil
        )
    }
}

@Suite("Schedule Chat Navigation")
@MainActor
struct ScheduleChatNavigationTests {

    @Test("starting today's review reuses the preloaded daily plan")
    func startDailyReviewChatUsesPreloadedPlan() async {
        let vm = makeViewModel()
        let now = Date()
        let goal = LearningGoalRecord(
            id: "notebook-1",
            title: "Systems Biology",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [
                LearningGoalItem(
                    id: "item-a",
                    goalID: "notebook-1",
                    sourceID: "source-a",
                    addedAt: now,
                    completedAt: nil,
                    reviewState: LearningGoalItemReviewState.approved.rawValue
                ),
                LearningGoalItem(
                    id: "item-b",
                    goalID: "notebook-1",
                    sourceID: "source-b",
                    addedAt: now,
                    completedAt: nil,
                    reviewState: LearningGoalItemReviewState.approved.rawValue
                )
            ],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [goal]
        vm.activeNotebookId = goal.id

        _ = await vm.refreshDailyReviewPlan(for: goal.id)
        vm.preloadedDailyReviewPlans[goal.id] = DailyReviewPlan(
            goalID: goal.id,
            sourceIDs: ["source-b"],
            items: [DailyReviewPlanItem(sourceID: "source-b", role: .memory)],
            topic: "Cached review",
            rationale: "Cached rationale",
            doneToday: false
        )

        await vm.startDailyReviewChat(goalID: goal.id)

        #expect(vm.pendingCompanionReview?.goalID == goal.id)
        #expect(vm.pendingCompanionReview?.sourceIDs == ["source-b"])
        #expect(vm.pendingCompanionReview?.topic == "Cached review")
        #expect(vm.pendingCompanionReview?.rationale == "Cached rationale")
    }

    @Test("opening a Schedule source refreshes the expanded Chat panel")
    func openSourceInReaderRefreshesVisibleChat() async {
        let vm = makeViewModel()
        // Content on the row keeps selectArticle from fetching
        // https://example.com for real: this test is about where the
        // selection lands, not about fetching.
        vm.articles = [makeArticle(url: "https://example.com/new", title: "New", id: "new-source").with(content: "New, already read.")]
        vm.contextSourceIds = ["old-source"]
        vm.showAssistantOverlay = true

        await vm.openSourceInReader("new-source")

        #expect(vm.contextSourceIds == ["new-source"])
        #expect(vm.showAssistantOverlay == true)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.selectedArticleId == "new-source")
    }

    @Test("opening a Schedule source preserves a collapsed Chat panel")
    func openSourceInReaderPreservesHiddenChat() async {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://example.com/new", title: "New", id: "new-source").with(content: "New, already read.")]
        vm.contextSourceIds = ["old-source"]
        vm.showAssistantOverlay = false

        await vm.openSourceInReader("new-source")

        #expect(vm.contextSourceIds == ["new-source"])
        #expect(vm.showAssistantOverlay == false)
        #expect(vm.reviewChatResetRequestID == nil)
        #expect(vm.selectedArticleId == "new-source")
    }

    @Test("starting a blank Review Chat clears existing context")
    func requestBlankReviewChatClearsExistingContext() {
        let vm = makeViewModel()
        vm.contextSourceIds = ["old-source"]

        vm.requestBlankReviewChat()

        #expect(vm.contextSourceIds.isEmpty)
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(vm.showAssistantOverlay == true)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.reviewChatFocusRequestID != nil)
    }

    @Test("starting a new chat in a Notebook seeds its approved sources and notebook link")
    func requestBlankReviewChatInNotebookSeedsNotebookContext() {
        let now = Date()
        let vm = makeViewModel()
        vm.contextSourceIds = ["old-source"]
        let notebook = LearningGoalRecord(
            id: "notebook-1",
            title: "Systems Biology",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [
                LearningGoalItem(id: "item-1", goalID: "notebook-1", sourceID: "source-a", addedAt: now),
                LearningGoalItem(
                    id: "item-2",
                    goalID: "notebook-1",
                    sourceID: "source-b",
                    addedAt: now,
                    reviewState: LearningGoalItemReviewState.rejected.rawValue
                )
            ],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [notebook]
        vm.articles = [makeArticle(url: "https://example.com/source-a", title: "Source A", id: "source-a")]

        vm.requestBlankReviewChat(notebookID: notebook.id)

        #expect(vm.contextSourceIds == ["source-a"])
        #expect(vm.pendingReviewChatNotebookID == notebook.id)
        #expect(vm.showAssistantOverlay == true)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.reviewChatFocusRequestID != nil)
    }

    // MARK: Notebook chat checkboxes

    /// A notebook (open-ended Notebook) whose approved pool is `sourceIDs`.
    private func notebook(
        _ id: String,
        sourceIDs: [String],
        related: [String]? = nil
    ) -> LearningGoalRecord {
        let now = Date()
        return LearningGoalRecord(
            id: id,
            title: "Notebook \(id)",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: sourceIDs.map {
                LearningGoalItem(id: "item-\(id)-\($0)", goalID: id, sourceID: $0, addedAt: now)
            },
            kind: LearningGoalRecord.companionKind,
            relatedNotebookIDs: related
        )
    }

    /// Library rows with text already in hand, so seeding the chat context
    /// starts no fetch.
    private func readableArticles(_ ids: [String]) -> [StudioArticle] {
        ids.map { id in
            var article = makeArticle(url: "https://example.com/\(id)", title: "Source \(id)", id: id)
            article.content = "Text of \(id)."
            return article
        }
    }

    /// Runs `body` with the notebook rows in a throwaway defaults suite, so no
    /// test writes the learner's (or a neighbour's) `UserDefaults.standard`,
    /// and under generation 1, whose rows these are (the test host runs
    /// generation 2, where the ticks are the member's NotebookState).
    private func withNotebookDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "NotebookChatSelectionVM.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try ForeverLMRuntimeIdentity.$pinnedSyncGeneration.withValue(.one) {
            try NotebookChatSelection.$overrideDefaults.withValue(NotebookChatSelection.DefaultsOverride(defaults: defaults)) {
                try body(defaults)
            }
        }
    }

    @Test("a new chat in a notebook reads only its ticked sources")
    func newNotebookChatSeedsTickedSources() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        vm.learningGoals = [notebook("notebook-1", sourceIDs: ["source-a", "source-b", "source-c"])]
        vm.articles = readableArticles(["source-a", "source-b", "source-c"])
        vm.notebookChatExclusions["notebook-1"] = ["source-b"]

        vm.requestBlankReviewChat(notebookID: "notebook-1")

        #expect(vm.contextSourceIds == ["source-a", "source-c"])
        #expect(vm.pendingReviewChatNotebookID == "notebook-1")
    }

    @Test("a context notebook's source can be unticked in this notebook alone once the notebook is put in")
    func contextNotebookSourceCanBeUnticked() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        vm.notebookChatContextNotebooks = ["notebook-1": ["notebook-2"]]
        let main = notebook("notebook-1", sourceIDs: ["source-a"], related: ["notebook-2"])
        let related = notebook("notebook-2", sourceIDs: ["source-r"])
        vm.learningGoals = [main, related]
        vm.articles = readableArticles(["source-a", "source-r"])
        #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r"], "put in, its sources come ticked")

        vm.notebookChatExclusions["notebook-1"] = ["source-r"]

        #expect(vm.notebookChatSourceIDs(main) == ["source-a"])
        #expect(vm.notebookChatSourceIDs(related) == ["source-r"], "the context notebook keeps its own box")
        vm.requestBlankReviewChat(notebookID: "notebook-1")
        #expect(vm.contextSourceIds == ["source-a"])
    }

    @Test("a notebook's chats and count read only its own ticked sources while its context notebooks are linked but not put in; a stale id in the row reads nothing")
    func linkedContextNotebooksReachNothing() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        // Mito Phenotyping's shape: its own sources, three context notebooks.
        let main = notebook("notebook-1", sourceIDs: ["source-a", "source-b"], related: ["notebook-2", "notebook-3", "notebook-4"])
        vm.learningGoals = [
            main,
            notebook("notebook-2", sourceIDs: ["source-r", "source-a"]),
            notebook("notebook-3", sourceIDs: ["source-s"]),
            notebook("notebook-4", sourceIDs: ["source-t"]),
        ]
        vm.articles = readableArticles(["source-a", "source-b", "source-r", "source-s", "source-t"])
        vm.notebookChatExclusions = ["notebook-1": ["source-b"]]
        // An id the notebook no longer links to, left in the row.
        vm.notebookChatContextNotebooks = ["notebook-1": ["unlinked"]]

        #expect(vm.notebookChatPool(main) == ["source-a", "source-b"])
        #expect(vm.notebookChatSourceIDs(main) == ["source-a"])
        let tally = vm.notebookChatTally(main)
        #expect(tally.inChat == 1 && tally.total == 2, "\(tally)")
        #expect(vm.notebookContextSourceIDs(main) == ["source-a", "source-b", "source-r", "source-s", "source-t"],
                "every box the column can draw")
        // What a group's rows read: a context notebook out of the chats is
        // unticked, and the notebook's own source it holds too is ticked.
        let chat = Set(vm.notebookChatSourceIDs(main))
        #expect(!chat.contains("source-r"))
        #expect(chat.contains("source-a"))
        #expect(vm.notebookContextNotebookTally("notebook-2", in: main) == nil)
        vm.requestBlankReviewChat(notebookID: "notebook-1")
        #expect(vm.contextSourceIds == ["source-a"])
    }

    @Test("ticking a context notebook puts its sources, and those it gains later, into the chats and the count; unticking one of them leaves it out alone")
    func tickingAContextNotebookReadsItsSources() throws {
        try withNotebookDefaults { defaults in
            let vm = makeViewModel()
            vm.notebookChatExclusions = [:]
            vm.notebookChatContextNotebooks = [:]
            let main = notebook("notebook-1", sourceIDs: ["source-a"], related: ["notebook-2"])
            vm.learningGoals = [main, notebook("notebook-2", sourceIDs: ["source-r", "source-s"])]
            vm.articles = readableArticles(["source-a", "source-r", "source-s", "source-later"])
            let contextKey = NotebookChatContext.preferenceKey(notebookID: "notebook-1")

            vm.setNotebookContextNotebooks(["notebook-2"], inChat: true, notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: contextKey) == ["notebook-2"])
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-s"])
            #expect(vm.notebookChatTally(main).total == 3)
            #expect(vm.notebookContextNotebookTally("notebook-2", in: main).map { [$0.inChat, $0.total] } == [2, 2])

            vm.setNotebookSources(["source-s"], inChat: false, through: "notebook-2", notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: "notebook-1")) == ["source-s"])
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r"])
            #expect(vm.notebookContextNotebookTally("notebook-2", in: main).map { [$0.inChat, $0.total] } == [1, 2], "the group reads mixed")

            // The context notebook gains a source on another device: the
            // group's box governs it, with no tick written.
            vm.learningGoals[1] = notebook("notebook-2", sourceIDs: ["source-r", "source-s", "source-later"])
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-later"])
            #expect(vm.notebookChatTally(main).inChat == 3 && vm.notebookChatTally(main).total == 4)

            // Unticked as a group, it leaves the chats and keeps its boxes.
            let exclusionKey = NotebookChatSelection.preferenceKey(notebookID: "notebook-1")
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: false, notebookID: "notebook-1")
            #expect(defaults.object(forKey: contextKey) == nil)
            #expect(vm.notebookChatSourceIDs(main) == ["source-a"])
            #expect(defaults.stringArray(forKey: exclusionKey) == ["source-s"])

            // Its box puts it back as it was left, source-s still unticked and
            // the group mixed; the box again, while it is in, ticks all of it.
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: true, notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: contextKey) == ["notebook-2"])
            #expect(defaults.stringArray(forKey: exclusionKey) == ["source-s"])
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-later"])
            #expect(vm.notebookContextNotebookTally("notebook-2", in: main).map { [$0.inChat, $0.total] } == [2, 3])
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: true, notebookID: "notebook-1")
            #expect(defaults.object(forKey: exclusionKey) == nil)
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-s", "source-later"])

            // A source ticked inside the group while it is out puts the group
            // in with that source alone.
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: false, notebookID: "notebook-1")
            vm.setNotebookSources(["source-later"], inChat: true, through: "notebook-2", notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: contextKey) == ["notebook-2"])
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-later"])
        }
    }

    @Test("Add a Notebook to Context links and puts it in at once, as it was left; Take Out of Context unlinks it and drops it alone from the row")
    func addAndTakeOutContextNotebook() async throws {
        try await withNotebookDefaultsAsync { defaults in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookContext_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let service = StorageService(storeRoot: tmp)
            let vm = StudioViewModel(storageService: service)
            vm.notebookChatExclusions = [:]
            vm.notebookChatContextNotebooks = [:]
            var sources: [StudioArticle] = []
            for name in ["own", "lent"] {
                var source = makeArticle(url: "https://example.com/\(name)", title: name, state: .ready)
                source.content = "Text of \(name)."
                try await service.saveSource(source)
                sources.append(source)
            }
            vm.articles = sources
            let monday = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 4))!
            func make(_ title: String, _ ids: [String]) async throws -> LearningGoalRecord {
                try await service.createCompanionGoal(
                    title: title, topic: title, startAt: monday, endAt: LearningGoalRecord.openEndedEndAt,
                    dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ids
                )
            }
            let main = try await make("Main", [sources[0].id])
            let other = try await make("Other", [sources[1].id])
            await vm.loadLearningGoals()
            let contextKey = NotebookChatContext.preferenceKey(notebookID: main.id)
            let exclusionKey = NotebookChatSelection.preferenceKey(notebookID: main.id)
            // A notebook another device linked and put in, whose link this
            // Mac has not heard of yet.
            defaults.set(["elsewhere"], forKey: contextKey)
            vm.notebookChatContextNotebooks = [main.id: ["elsewhere"]]

            await vm.addContextNotebook(other.id, to: main.id)
            #expect(vm.notebook(id: main.id)?.relatedNotebookIDs == [other.id])
            #expect(defaults.stringArray(forKey: contextKey) == ["elsewhere", other.id].sorted(), "the other device's choice stays")
            #expect(vm.notebookChatSourceIDs(try #require(vm.notebook(id: main.id))) == [sources[0].id, sources[1].id])

            // Unticked while in, taken out by its box and added again: Add puts
            // it in as it was left.
            vm.setNotebookSources([sources[1].id], inChat: false, through: other.id, notebookID: main.id)
            vm.setNotebookContextNotebooks([other.id], inChat: false, notebookID: main.id)
            await vm.addContextNotebook(other.id, to: main.id)
            #expect(defaults.stringArray(forKey: contextKey) == ["elsewhere", other.id].sorted())
            #expect(defaults.stringArray(forKey: exclusionKey) == [sources[1].id])
            let linkedMain = try #require(vm.notebook(id: main.id))
            #expect(vm.notebookChatSourceIDs(linkedMain) == [sources[0].id])
            #expect(vm.notebookContextNotebookTally(other.id, in: linkedMain).map { [$0.inChat, $0.total] } == [0, 1])

            await vm.takeContextNotebookOut(other.id, of: main.id)
            #expect(vm.notebook(id: main.id)?.relatedNotebookIDs?.isEmpty != false)
            #expect(defaults.stringArray(forKey: contextKey) == ["elsewhere"], "only the notebook unlinked here leaves the row")
            #expect(vm.notebookChatContextNotebooks[main.id] == ["elsewhere"])
            #expect(defaults.object(forKey: exclusionKey) == nil, "the unticks only it held go with it")
            #expect(vm.notebookChatSourceIDs(try #require(vm.notebook(id: main.id))) == [sources[0].id])

            // Linked again from the inspector's list of every notebook, or by
            // an assistant: linking alone puts nothing in.
            #expect(await vm.setRelatedNotebooks([other.id], notebookID: main.id))
            #expect(defaults.stringArray(forKey: contextKey) == ["elsewhere"])
            #expect(vm.notebookChatSourceIDs(try #require(vm.notebook(id: main.id))) == [sources[0].id])
        }
    }

    @Test("a notebook review reads the ticked sources")
    func notebookReviewUsesTickedSources() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        vm.learningGoals = [notebook("notebook-1", sourceIDs: ["source-a", "source-b"])]
        vm.articles = readableArticles(["source-a", "source-b"])
        vm.notebookChatExclusions["notebook-1"] = ["source-a"]

        vm.requestNotebookReview("notebook-1")

        #expect(vm.contextSourceIds == ["source-b"])
        #expect(vm.pendingReviewChatNotebookID == "notebook-1")
        #expect(vm.reviewChatAutoStartRequestID != nil)
    }

    @Test("a notebook review with every box unticked asks for a tick and starts nothing")
    func notebookReviewWithNothingTicked() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        vm.learningGoals = [notebook("notebook-1", sourceIDs: ["source-a", "source-b"])]
        vm.articles = readableArticles(["source-a", "source-b"])
        vm.notebookChatExclusions["notebook-1"] = ["source-a", "source-b"]
        vm.toastMessage = nil
        let autoStart = vm.reviewChatAutoStartRequestID

        vm.requestNotebookReview("notebook-1")

        #expect(vm.toastMessage == "Tick a source in \u{201C}Notebook notebook-1\u{201D} to review it.")
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(vm.reviewChatAutoStartRequestID == autoStart)
    }

    @Test("ticking every box again drops the notebook's row; ids outside the pool are never stored")
    func setNotebookSourcesWritesAndDropsTheRow() throws {
        try withNotebookDefaults { defaults in
            let vm = makeViewModel()
            vm.notebookChatExclusions = [:]
            vm.learningGoals = [notebook("notebook-1", sourceIDs: ["source-a", "source-b", "source-c"])]
            let key = NotebookChatSelection.preferenceKey(notebookID: "notebook-1")

            vm.setNotebookSources(["source-c", "source-a", "not-in-pool"], inChat: false, notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: key) == ["source-a", "source-c"])
            #expect(vm.notebookChatExclusions["notebook-1"] == ["source-a", "source-c"])
            #expect(!vm.isNotebookSourceInChat("source-a", notebookID: "notebook-1"))
            #expect(vm.isNotebookSourceInChat("source-b", notebookID: "notebook-1"))

            vm.setNotebookSources(["source-a"], inChat: true, notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: key) == ["source-c"])

            vm.setAllNotebookSourcesInChat(false, notebookID: "notebook-1")
            #expect(defaults.stringArray(forKey: key) == ["source-a", "source-b", "source-c"])

            vm.setAllNotebookSourcesInChat(true, notebookID: "notebook-1")
            #expect(defaults.object(forKey: key) == nil, "everything ticked is the default and has no row")
            #expect(vm.notebookChatExclusions["notebook-1"] == nil)
        }
    }

    /// `withNotebookDefaults` for an async body.
    private func withNotebookDefaultsAsync(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "NotebookChatSelectionVM.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await ForeverLMRuntimeIdentity.$pinnedSyncGeneration.withValue(.one) {
            try await NotebookChatSelection.$overrideDefaults.withValue(NotebookChatSelection.DefaultsOverride(defaults: defaults)) {
                try await body(defaults)
            }
        }
    }

    @Test("a source added back to a notebook on another device arrives ticked; an untick made after its add, or arriving alone, stands")
    func inboundNotebookArrivalsAreTicked() async throws {
        try await withNotebookDefaultsAsync { defaults in
            let vm = makeViewModel()
            let now = Date()
            let rejected = LearningGoalItemReviewState.rejected.rawValue
            // notebook-1: the phone (an older build) added b back, after it had
            // been unticked and then removed; its row still unticks b. This
            // Mac saw the removal, which came after the row was written.
            var p1Before = notebook("notebook-1", sourceIDs: ["source-a", "source-b"])
            p1Before.items[1].reviewState = rejected
            p1Before.updatedAt = now.addingTimeInterval(600)
            var p1After = notebook("notebook-1", sourceIDs: ["source-a", "source-b"])
            p1After.updatedAt = now.addingTimeInterval(3_600)
            // notebook-2: the phone added d an hour ago and then unticked it,
            // before this Mac heard of either.
            let p2Before = notebook("notebook-2", sourceIDs: ["source-c"])
            var p2After = notebook("notebook-2", sourceIDs: ["source-c", "source-d"])
            p2After.items[1].addedAt = now.addingTimeInterval(-3_600)
            // notebook-3: renamed, and f unticked on another device; nothing joined.
            let p3Before = notebook("notebook-3", sourceIDs: ["source-e", "source-f"])
            var p3After = p3Before
            p3After.title = "Renamed"
            p3After.updatedAt = now.addingTimeInterval(3_600)
            // notebook-4: this Mac last saw h removed, an hour ago; then, with
            // the Mac asleep, the phone added h back, unticked it (the row,
            // written now), and edited the notebook again an hour from now.
            var p4Before = notebook("notebook-4", sourceIDs: ["source-g", "source-h"])
            p4Before.items[1].reviewState = rejected
            p4Before.updatedAt = now.addingTimeInterval(-3_600)
            var p4After = notebook("notebook-4", sourceIDs: ["source-g", "source-h"])
            p4After.updatedAt = now.addingTimeInterval(3_600)

            let rows = ["notebook-1": ["source-b"], "notebook-2": ["source-d"], "notebook-3": ["source-f"], "notebook-4": ["source-h"]]
            for (notebookID, excluded) in rows {
                let key = NotebookChatSelection.preferenceKey(notebookID: notebookID)
                defaults.set(excluded, forKey: key)
                // The store's copy, dated now, as the row's last write.
                try await vm.storage.writePreference(key: key, valuePlistXML: try #require(PreferenceStore.encodePlist(excluded)))
            }
            vm.notebookChatExclusions = [:]
            vm.learningGoals = [p1After, p2After, p3After, p4After]

            await vm.tickNotebookArrivalsFromSync(before: [p1Before, p2Before, p3Before, p4Before])

            #expect(defaults.object(forKey: NotebookChatSelection.preferenceKey(notebookID: "notebook-1")) == nil,
                    "b's untick was older than its return, so b arrives ticked")
            #expect(vm.isNotebookSourceInChat("source-b", notebookID: "notebook-1"))
            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: "notebook-2")) == ["source-d"],
                    "d was unticked after it joined")
            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: "notebook-3")) == ["source-f"],
                    "an untick that arrives with no new member is never undone")
            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: "notebook-4")) == ["source-h"],
                    "h was unticked after it came back; the later edit does not make the untick look older than the add")
            #expect(vm.notebookChatExclusions == ["notebook-2": ["source-d"], "notebook-3": ["source-f"], "notebook-4": ["source-h"]])
        }
    }

    @Test("an inbound add is found even when a local reload read it from the store before the sync refresh ran")
    func inboundNotebookArrivalsSurviveAnEarlierLocalReload() async throws {
        try await withNotebookDefaultsAsync { defaults in
            let vm = makeViewModel()
            let now = Date()
            let key = NotebookChatSelection.preferenceKey(notebookID: "notebook-1")
            // b was unticked, then removed on an older phone; the removal is
            // what this Mac's last inbound refresh left.
            defaults.set(["source-b"], forKey: key)
            try await vm.storage.writePreference(key: key, valuePlistXML: try #require(PreferenceStore.encodePlist(["source-b"])))
            var before = notebook("notebook-1", sourceIDs: ["source-a", "source-b"])
            before.items[1].reviewState = LearningGoalItemReviewState.rejected.rawValue
            before.updatedAt = now.addingTimeInterval(600)
            var after = notebook("notebook-1", sourceIDs: ["source-a", "source-b"])
            after.updatedAt = now.addingTimeInterval(3_600)
            vm.notebookChatExclusions = ["notebook-1": ["source-b"]]
            vm.notebookSyncBaseline = [before]
            // The phone added b back, and one of the local reloads read the
            // new membership from the store before the sync refresh did.
            vm.learningGoals = [after]

            await vm.noteInboundNotebooks([after], inMemory: vm.learningGoals)

            #expect(defaults.object(forKey: key) == nil, "diffed against the last inbound refresh, b is new, and arrives ticked")
            #expect(vm.notebookSyncBaseline == [after], "the next inbound change is diffed against this one")

            // The same refresh again brings nothing.
            vm.notebookChatExclusions = ["notebook-1": ["source-b"]]
            defaults.set(["source-b"], forKey: key)
            await vm.noteInboundNotebooks([after], inMemory: vm.learningGoals)
            #expect(defaults.stringArray(forKey: key) == ["source-b"])
        }
    }

    @Test("a source scheduled into a notebook from its Sources arrives ticked")
    func scheduledNotebookSourceArrivesTicked() async throws {
        try await withNotebookDefaultsAsync { defaults in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookScheduleTick_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let service = StorageService(storeRoot: tmp)
            let vm = StudioViewModel(storageService: service)
            var source = makeArticle(url: "https://example.com/scheduled-back", title: "Scheduled Back", state: .ready)
            source.content = "Durable notebook source text."
            try await service.saveSource(source)
            vm.articles = [source]
            let monday = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 4))!
            let notebook = try await service.createCompanionGoal(
                title: "Notebook",
                topic: "Notebook",
                startAt: monday,
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            )
            await vm.loadLearningGoals()
            // Left unticked from when it last left the notebook.
            let key = NotebookChatSelection.preferenceKey(notebookID: notebook.id)
            defaults.set([source.id], forKey: key)
            vm.notebookChatExclusions = [notebook.id: [source.id]]

            await vm.addSourcesToNotebookSchedule(goalID: notebook.id, sourceIDs: [source.id], plannedFor: monday)

            #expect(vm.notebook(id: notebook.id)?.approvedSourceIDs == [source.id])
            #expect(defaults.object(forKey: key) == nil)
            #expect(vm.isNotebookSourceInChat(source.id, notebookID: notebook.id))
        }
    }

    @Test("an unsent chat follows the boxes and keeps what else it holds, unless its context was replaced")
    func unsentChatFollowsNotebookSelection() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        vm.learningGoals = [notebook("notebook-1", sourceIDs: ["source-a", "source-b", "source-c"])]
        vm.articles = readableArticles(["source-a", "source-b", "source-c", "dropped"])
        vm.requestBlankReviewChat(notebookID: "notebook-1")
        vm.addSourceToContext("dropped")
        #expect(vm.contextSourceIds == ["source-a", "source-b", "source-c", "dropped"])

        // Unticking b.
        #expect(vm.followNotebookSelection(
            from: ["source-a", "source-b", "source-c"],
            to: ["source-a", "source-c"]
        ))
        #expect(vm.contextSourceIds == ["source-a", "source-c", "dropped"])

        // Ticking b again.
        #expect(vm.followNotebookSelection(
            from: ["source-a", "source-c"],
            to: ["source-a", "source-b", "source-c"]
        ))
        #expect(vm.contextSourceIds == ["source-a", "source-b", "source-c", "dropped"])

        // The Reader put one source in the context since: that choice stands.
        vm.setContextSources(["source-b"])
        #expect(!vm.followNotebookSelection(
            from: ["source-a", "source-b", "source-c"],
            to: ["source-a"]
        ))
        #expect(vm.contextSourceIds == ["source-b"])
    }

    @Test("the tally counts only sources a chat could read")
    func notebookChatTallyCountsReadableSources() {
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        let tallied = notebook("notebook-1", sourceIDs: ["source-a", "source-b", "episode", "missing"])
        vm.learningGoals = [tallied]
        var episode = makeArticle(
            url: "apple-podcast://episode/1",
            title: "Episode",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "episode"
        )
        episode.domain = "Hidden Show"
        vm.articles = readableArticles(["source-a", "source-b"]) + [episode]
        vm.hiddenPodcastShows = ["Hidden Show"]

        let untouched = vm.notebookChatTally(tallied)
        #expect(untouched.inChat == 2)
        #expect(untouched.total == 2)

        vm.notebookChatExclusions["notebook-1"] = ["source-b", "episode"]
        let tally = vm.notebookChatTally(tallied)
        #expect(tally.inChat == 1)
        #expect(tally.total == 2)
    }

    @Test("creating a Goal from Notebook detail saves it directly under that Notebook")
    func createGoalInNotebookPersistsWithoutOpeningChat() async throws {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        vm.showAssistantOverlay = false
        let notebook = try #require(await vm.createNotebookContext(title: "Systems Biology"))
        let deadline = try #require(Calendar.current.date(byAdding: .day, value: 10, to: Date()))

        let created = try #require(
            await vm.createGoal(
                title: "Write the literature review",
                deadline: deadline,
                notebookID: notebook.id
            )
        )

        #expect(created.title == "Write the literature review")
        #expect(created.parentNotebookID == notebook.id)
        #expect(created.discoveryEnabled == false)
        #expect(vm.goals(inNotebook: notebook.id).map(\.id) == [created.id])
        #expect(vm.allGoals.map(\.id) == [created.id], "a tagged Goal is in the Goals tab's list too")
        #expect(vm.showAssistantOverlay == false)
        #expect(vm.pendingReviewChatDraft == nil)
        #expect(vm.reviewChatResetRequestID == nil)
    }

    /// The drop of sources onto a Goal's row (product owner, 2026-09-19: "allow me
    /// to drag sources onto goals"): the Goal's pool takes them, the Notebook
    /// it is tagged to takes them too, repeats are skipped, and the active
    /// Notebook is left alone — a Goal is not a source context.
    @Test("dropping sources on a Goal fills its pool and its Notebook's, skips repeats, and never moves the active Notebook")
    func addSourcesToGoalFillsGoalAndNotebookPools() async throws {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        let notebook = try #require(await vm.createNotebookContext(title: "Systems Biology"))
        let other = try #require(await vm.createNotebookContext(title: "Other"))
        vm.activeNotebookId = other.id
        let deadline = try #require(Calendar.current.date(byAdding: .day, value: 10, to: Date()))
        let goal = try #require(await vm.createGoal(title: "Understand the method", deadline: deadline, notebookID: notebook.id))
        let alone = try #require(await vm.createGoal(title: "Write the article", deadline: deadline))
        for id in ["source-a", "source-b"] {
            var article = makeArticle(url: "https://example.com/\(id)", title: id, id: id)
            article.content = "Readable text for \(id)."
            article.state = .ready
            try await vm.storage.saveSource(article)
        }

        let updated = try #require(await vm.addSourcesToGoal(goalID: goal.id, sourceIDs: ["source-a", "source-b", "source-a"]))
        #expect(updated.approvedSourceIDs == ["source-a", "source-b"])
        #expect(vm.notebook(id: notebook.id)?.approvedSourceIDs == ["source-a", "source-b"], "a tagged Goal hands its sources on to the Notebook")
        #expect(vm.activeNotebookId == other.id, "putting a source on a Goal does not move the chat's scope")

        let again = try #require(await vm.addSourcesToGoal(goalID: goal.id, sourceIDs: ["source-a"]))
        #expect(again.approvedSourceIDs == ["source-a", "source-b"], "a repeat is skipped, not doubled")

        let standalone = try #require(await vm.addSourcesToGoal(goalID: alone.id, sourceIDs: ["source-b"]))
        #expect(standalone.approvedSourceIDs == ["source-b"])
        #expect(vm.notebook(id: other.id)?.approvedSourceIDs.isEmpty == true, "a standalone Goal fills no Notebook")
        #expect(await vm.addSourcesToGoal(goalID: notebook.id, sourceIDs: ["source-a"]) == nil, "a Notebook is not a Goal")
    }

    @Test("a Goal set with no Notebook stands on its own: in Goals, never among the Notebooks")
    func createGoalWithoutNotebookStandsAlone() async throws {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        let notebook = try #require(await vm.createNotebookContext(title: "Systems Biology"))
        let soon = try #require(Calendar.current.date(byAdding: .day, value: 3, to: Date()))
        let later = try #require(Calendar.current.date(byAdding: .day, value: 60, to: Date()))

        let goal = try #require(await vm.createGoal(title: "Understand Zara's thesis work", deadline: soon))
        let farOff = try #require(await vm.createGoal(title: "Give the lab talk", deadline: later))

        #expect(goal.parentNotebookID == nil)
        #expect(goal.isGoal && goal.isStandaloneGoal && !goal.isNotebook)
        // The Notebook is still the only Notebook: a dated parentless record is a Goal, not a Notebook.
        #expect(vm.notebooks.map(\.id) == [notebook.id])
        #expect(vm.goals(inNotebook: notebook.id).isEmpty)
        #expect(vm.allGoals.map(\.id) == [goal.id, farOff.id], "nearest deadline first")

        let bands = vm.goalBands()
        #expect(bands.inFlight.map(\.id) == [goal.id])
        #expect(bands.later.map(\.id) == [farOff.id])
        #expect(bands.done.isEmpty)

        await vm.setGoalStatus(goalID: goal.id, status: .done)
        #expect(vm.goalBands().done.map(\.id) == [goal.id])
        #expect(vm.notebooks.map(\.id) == [notebook.id], "finishing a Goal touches no Notebook")

        // A blank Notebook is no Notebook; an unknown one refuses the Goal.
        #expect(await vm.createGoal(title: "Untagged", deadline: soon, notebookID: "  ")?.parentNotebookID == nil)
        #expect(await vm.createGoal(title: "Orphan", deadline: soon, notebookID: "no-such-notebook") == nil)
    }

    @Test("The Tasks pane's new-task action opens Chat with the request typed, not a form")
    func newScheduledTaskChatSeedsTheComposer() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        vm.showAssistantOverlay = false

        vm.requestNewScheduledTaskChat()

        #expect(vm.showAssistantOverlay == true)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatResetRequestID != nil)
        // Typed but unsent, and unlinked: a task is not owned by whichever
        // Notebook happened to be open when the learner pressed "+".
        let draft = vm.pendingReviewChatDraft ?? ""
        #expect(draft.contains("scheduled task"))
        #expect(vm.pendingReviewChatNotebookID == nil)
    }

    @Test("⌘K expands and focuses docked Chat")
    func assistantShortcutFocusesDockedChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        vm.showAssistantOverlay = false

        vm.handleAssistantShortcut()
        let firstFocusRequest = vm.reviewChatFocusRequestID

        #expect(vm.showAssistantOverlay == true)
        #expect(firstFocusRequest != nil)

        vm.handleAssistantShortcut()

        #expect(vm.showAssistantOverlay == true)
        #expect(vm.reviewChatFocusRequestID != firstFocusRequest)
    }

    @Test("rail Notebook scope remains navigation state")
    func railNotebookScopeFollowsOpenNotebook() {
        let now = Date()
        let vm = makeViewModel()
        let notebook = LearningGoalRecord(
            id: "notebook-1",
            title: "Systems Biology",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [notebook]

        // Nothing is scoped while the gallery is showing.
        #expect(vm.railScopedNotebook == nil)

        // Opening a notebook scopes the rail, and the navigation scope is sticky
        // while the learner reads a source. Chat context is passed only by an
        // explicit Notebook-origin action.
        vm.showSpaceAll()
        vm.workbenchNotebookID = notebook.id
        #expect(vm.railScopedNotebook?.id == notebook.id)

        vm.clearReaderSurfaces()
        #expect(vm.railScopedNotebook?.id == notebook.id)

        vm.workbenchNotebookID = nil
        #expect(vm.railScopedNotebook == nil)
    }

    @Test("clicking the open notebook's rail folder again closes it; the active Notebook follows the opening only")
    func railNotebookSelectionTogglesOff() {
        let restoreLayout = capturedCenterTabLayout()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreLayout()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let now = Date()
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        let notebook = LearningGoalRecord(
            id: "notebook-1",
            title: "GDF15",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [notebook]

        let activeBefore = vm.activeNotebookId
        // The active Notebook, a preference on this Mac only, follows a
        // notebook of the open library as it opens.
        let expectedActive = vm.importableNotebook(notebook.id) != nil ? notebook.id : activeBefore
        vm.toggleNotebookInReader(notebook.id)
        #expect(vm.railScopedNotebook?.id == notebook.id)
        // The notebook's workspace shows it.
        #expect(vm.activeNotebookId == expectedActive)
        #expect(vm.workbenchNotebookID == notebook.id)

        // Closing it leaves the active Notebook where the opening put it.
        vm.toggleNotebookInReader(notebook.id)
        #expect(vm.railScopedNotebook == nil)
        #expect(vm.workbenchNotebookID == nil)
        #expect(vm.activeNotebookId == expectedActive)
    }

    @Test("rail groups notebook chats and keeps loose chats separate")
    func railGroupsChatsByNotebook() {
        let now = Date()
        let vm = makeViewModel()
        let notebook = LearningGoalRecord(
            id: "notebook-1",
            title: "GDF15",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [notebook]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(
                id: "in-notebook",
                title: "GDF15 as a biomarker",
                createdAt: now,
                status: "completed",
                sourceIDs: [],
                goalID: notebook.id
            ),
            ReviewSessionRecord(
                id: "loose",
                title: "Unrelated chat",
                createdAt: now.addingTimeInterval(-60),
                status: "completed",
                sourceIDs: []
            ),
            ReviewSessionRecord(
                id: "hidden-notebook",
                title: "Chat from an archived notebook",
                createdAt: now.addingTimeInterval(-120),
                status: "completed",
                sourceIDs: [],
                goalID: "archived-notebook"
            ),
            // A day's memory review, filed in the Notebook by a move: the rail
            // still lists it under Memory, never beneath the folder.
            ReviewSessionRecord(
                id: MemoryReviewSession.sessionID(for: now),
                title: MemoryReviewSession.title(for: now),
                createdAt: now.addingTimeInterval(-180),
                status: "completed",
                sourceIDs: [],
                goalID: notebook.id
            )
        ]
        let memoryID = MemoryReviewSession.sessionID(for: now)

        // The complete session run remains available to other chat surfaces.
        #expect(vm.filteredReviewSessionLinks().map(\.id) == ["in-notebook", "loose", "hidden-notebook", memoryID])

        // The navigation rail files explicit Notebook chats beneath the folder
        // and leaves unassigned or currently hidden Notebook chats in its general section.
        let chatGroups = vm.reviewSessionGroups(for: vm.notebooks)
        #expect(vm.reviewSessionsForNotebook(notebook).map(\.id) == ["in-notebook", memoryID])
        #expect(chatGroups.memory.map(\.id) == [memoryID])
        #expect(chatGroups.byNotebookID[notebook.id]?.map(\.id) == ["in-notebook"])
        #expect(chatGroups.outsideNotebooks.map(\.id) == ["loose", "hidden-notebook"])
        // The Chats placeholder counts only what Notebooks and Chats show.
        #expect(chatGroups.totalCount == 3)
    }

    @Test("A chat filed under a Goal is the Goal's, and sits beneath the Goal's Notebook in the rail when it draws on one")
    func railFilesGoalChatsUnderTheirNotebook() {
        let now = Date()
        let vm = makeViewModel()
        func record(_ id: String, _ title: String, endAt: Date, parent: String? = nil) -> LearningGoalRecord {
            var record = LearningGoalRecord(
                id: id, title: title, startAt: now, endAt: endAt, createdAt: now, updatedAt: now,
                status: "active", items: [], kind: LearningGoalRecord.companionKind
            )
            record.parentNotebookID = parent
            return record
        }
        let notebook = record("notebook-1", "Mitochondria", endAt: LearningGoalRecord.openEndedEndAt)
        let nested = record("goal-nested", "Understand the sleep paper", endAt: now.addingTimeInterval(7 * 86_400), parent: notebook.id)
        let standalone = record("goal-alone", "Pooled in vivo screening", endAt: now.addingTimeInterval(7 * 86_400))
        vm.learningGoals = [notebook, nested, standalone]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "on-nested", title: "Miesenböck part 1", createdAt: now, status: "completed", sourceIDs: [], goalID: nested.id),
            ReviewSessionRecord(id: "on-alone-older", title: "Waypoint Bio", createdAt: now.addingTimeInterval(-120), status: "completed", sourceIDs: [], goalID: standalone.id),
            ReviewSessionRecord(id: "on-alone", title: "The Missing Dimension in Pooled Screens", createdAt: now.addingTimeInterval(-60), status: "completed", sourceIDs: [], goalID: standalone.id),
            ReviewSessionRecord(id: "loose", title: "Unrelated", createdAt: now.addingTimeInterval(-180), status: "completed", sourceIDs: []),
        ]

        // The Goal lists its own chats, newest first.
        #expect(vm.reviewSessions(forGoal: standalone.id).map(\.id) == ["on-alone", "on-alone-older"])
        #expect(vm.reviewSessions(forGoal: nested.id).map(\.id) == ["on-nested"])
        #expect(vm.reviewSessions(forGoal: notebook.id).isEmpty)

        // The rail: a nested Goal's chat sits beneath the Notebook it draws on;
        // a standalone Goal's chats stay in Chats. A Goal is never a folder.
        #expect(vm.notebooks.map(\.id) == [notebook.id])
        let groups = vm.reviewSessionGroups(for: vm.notebooks)
        #expect(groups.byNotebookID[notebook.id]?.map(\.id) == ["on-nested"])
        // Which chats, not their order: the rail's own ordering rules decide that.
        #expect(Set(groups.outsideNotebooks.map(\.id)) == ["on-alone-older", "on-alone", "loose"])
        #expect(groups.totalCount == 4)
    }

    @Test("Memory reviews alone leave the Chats section empty")
    func memoryReviewsAloneLeaveChatsEmpty() {
        let vm = makeViewModel()
        let now = Date()
        vm.reviewSessionLinks = [
            ReviewSessionRecord(
                id: MemoryReviewSession.sessionID(for: now),
                title: MemoryReviewSession.title(for: now),
                createdAt: now,
                status: "completed",
                sourceIDs: []
            ),
            ReviewSessionRecord(
                id: MemoryReviewSession.sessionID(for: now.addingTimeInterval(-86_400)),
                title: MemoryReviewSession.title(for: now.addingTimeInterval(-86_400)),
                createdAt: now.addingTimeInterval(-86_400),
                status: "completed",
                sourceIDs: []
            )
        ]

        let groups = vm.reviewSessionGroups(for: vm.notebooks)
        #expect(groups.memory.count == 2)
        #expect(groups.outsideNotebooks.isEmpty)
        #expect(groups.byNotebookID.isEmpty)
        #expect(groups.totalCount == 0)
    }

    @Test("Hidden chats leave every chat list and are listed only under Hidden")
    func hiddenChatsLeaveEveryListButHidden() {
        let vm = makeViewModel()
        let now = Date()
        let notebook = LearningGoalRecord(
            id: "notebook-hidden-chats",
            title: "Mitochondria",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [notebook]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "shown", title: "Shown chat", createdAt: now, status: "completed", sourceIDs: ["src-1"]),
            ReviewSessionRecord(
                id: "hidden-loose", title: "Hidden loose chat", createdAt: now.addingTimeInterval(-60),
                status: "completed", sourceIDs: ["src-1"], hiddenAt: now
            ),
            // Filed in a Notebook and hidden: the folder never shows it either.
            ReviewSessionRecord(
                id: "hidden-in-notebook", title: "Hidden Notebook chat", createdAt: now.addingTimeInterval(-120),
                status: "completed", sourceIDs: [], goalID: notebook.id, hiddenAt: now
            ),
            ReviewSessionRecord(
                id: "shown-in-notebook", title: "Shown Notebook chat", createdAt: now.addingTimeInterval(-180),
                status: "completed", sourceIDs: [], goalID: notebook.id
            ),
            // Another library's snapshot: hidden or not, My Library never lists it.
            ReviewSessionRecord(
                id: "hidden-team", title: "Team snapshot", createdAt: now.addingTimeInterval(-240),
                status: "completed", sourceIDs: [], teamID: "team-1", hiddenAt: now
            ),
        ]

        // The shared chat run — rail, sessions panel, Notebook chat lists —
        // never carries a hidden chat.
        #expect(vm.filteredReviewSessionLinks().map(\.id) == ["shown", "shown-in-notebook"])
        #expect(vm.reviewSessionsForNotebook(notebook).map(\.id) == ["shown-in-notebook"])
        let groups = vm.reviewSessionGroups(for: vm.notebooks)
        #expect(groups.outsideNotebooks.map(\.id) == ["shown"])
        #expect(groups.byNotebookID[notebook.id]?.map(\.id) == ["shown-in-notebook"])
        #expect(groups.totalCount == 2)

        // The Hidden fold is the one place they are listed again, newest
        // first, whichever Notebook they are filed in.
        #expect(vm.hiddenReviewSessions(for: vm.notebooks).map(\.id) == ["hidden-loose", "hidden-in-notebook"])

        // Showing one again puts it back where it was filed, in the folder's
        // own order (newest first).
        vm.reviewSessionLinks[2].hiddenAt = nil
        #expect(vm.reviewSessionGroups(for: vm.notebooks).byNotebookID[notebook.id]?.map(\.id) == ["hidden-in-notebook", "shown-in-notebook"])
        #expect(vm.hiddenReviewSessions(for: vm.notebooks).map(\.id) == ["hidden-loose"])
    }

    @Test("Notebook folders respect manual reorder and retain new Notebooks")
    func notebookFoldersRespectManualReorder() {
        let vm = makeViewModel()
        vm.notebookOrder = []
        let now = Date()
        func notebook(_ id: String, offset: TimeInterval) -> LearningGoalRecord {
            LearningGoalRecord(
                id: id,
                title: id,
                startAt: now.addingTimeInterval(offset),
                endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: now.addingTimeInterval(offset),
                updatedAt: now.addingTimeInterval(offset),
                status: "active",
                items: [],
                kind: LearningGoalRecord.companionKind
            )
        }
        vm.learningGoals = [
            notebook("newest", offset: 2),
            notebook("middle", offset: 1),
            notebook("oldest", offset: 0),
        ]

        vm.reorderNotebook(from: "oldest", to: "newest")
        #expect(vm.notebooks.map(\.id) == ["oldest", "newest", "middle"])
        #expect(vm.notebookOrder == ["oldest", "newest", "middle"])

        vm.reorderNotebook(from: "oldest", to: "middle")
        #expect(vm.notebooks.map(\.id) == ["newest", "middle", "oldest"])

        vm.learningGoals.append(notebook("added-later", offset: 3))
        #expect(vm.notebooks.map(\.id) == ["newest", "middle", "oldest", "added-later"])
    }

    @Test("The Memory row opens the Memory pane over the intact workspace; a focused review leaves only for its own id")
    func memoryRowOpensTheMemoryPane() {
        // Opening a pane writes the layout template into the host's real
        // defaults: put it back.
        let templateKey = "studio.centerTabGroups.v1"
        let template = UserDefaults.standard.object(forKey: templateKey)
        defer {
            if let template {
                UserDefaults.standard.set(template, forKey: templateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: templateKey)
            }
        }
        let vm = makeViewModel()
        let window = vm.activeWindowState

        // The click opens the pane over every notebook; nothing has been
        // given over yet.
        vm.openMemoryPane()
        #expect(vm.activeCenterTabs.contains(.memory))
        #expect(window.memoryPaneScope == .allNotebooks)
        #expect(window.memoryReviewFocusSessionID == nil)

        // A focused review is left only by its own id. (Ended without
        // writing an end for the day: this is not the learner leaving.)
        vm.enterMemoryReviewFocus(sessionID: "memory-2026-09-08")
        #expect(window.memoryReviewFocusSessionID == "memory-2026-09-08")
        vm.leaveMemoryReviewFocus(sessionID: "another-chat", endingSession: false)
        #expect(window.memoryReviewFocusSessionID == "memory-2026-09-08")
        vm.leaveMemoryReviewFocus(sessionID: "memory-2026-09-08", endingSession: false)
        #expect(window.memoryReviewFocusSessionID == nil)
    }

    @Test("Pinning is the learner's choice: nothing is pinned until pinned, and unpinning never archives")
    func pinnedNotebooksAreChosenAndStayActive() {
        let vm = makeViewModel()
        vm.notebookOrder = []
        vm.pinnedNotebookIDs = []
        defer { vm.pinnedNotebookIDs = [] }
        let now = Date()
        func notebook(_ id: String, status: String = "active") -> LearningGoalRecord {
            LearningGoalRecord(
                id: id,
                title: id,
                startAt: now,
                endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: now,
                updatedAt: now,
                status: status,
                items: [],
                kind: LearningGoalRecord.companionKind
            )
        }
        vm.learningGoals = [notebook("mhs"), notebook("alzheimers"), notebook("gdf15")]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "chat-a", title: "a", createdAt: now, status: "completed", sourceIDs: [], goalID: "alzheimers"),
            ReviewSessionRecord(id: "chat-m", title: "m", createdAt: now, status: "completed", sourceIDs: [], goalID: "mhs"),
        ]

        // Since the rail went compact (2026-10-03) a pin is the exception.
        #expect(vm.pinnedNotebooks.isEmpty)
        #expect(!vm.isNotebookPinned("alzheimers"))

        vm.setNotebookPinned("gdf15", true)
        vm.setNotebookPinned("mhs", true)
        // Listed in the learner's own order, whatever order they were pinned in.
        #expect(vm.pinnedNotebooks.map(\.id) == ["mhs", "gdf15"])
        #expect(vm.pinnedNotebookIDs == ["gdf15", "mhs"])
        #expect(vm.isNotebookPinned("mhs"))

        // Unpinned, still an active notebook everywhere else.
        vm.setNotebookPinned("mhs", false)
        #expect(vm.pinnedNotebooks.map(\.id) == ["gdf15"])
        #expect(vm.notebooks.map(\.id) == ["mhs", "alzheimers", "gdf15"])
        #expect(vm.archivedNotebooks.isEmpty)

        // A notebook with no rail row has its chats in the general Chats
        // section, so no conversation becomes unreachable.
        let groups = vm.reviewSessionGroups(for: vm.pinnedNotebooks)
        #expect(groups.byNotebookID["mhs"] == nil)
        #expect(Set(groups.outsideNotebooks.map(\.id)) == ["chat-a", "chat-m"])

        // Pinning twice writes nothing new.
        vm.setNotebookPinned("gdf15", true)
        #expect(vm.pinnedNotebookIDs == ["gdf15"])

        // Ids of notebooks that no longer exist are pruned on the next write,
        // so a deleted notebook does not stay in the synced list forever.
        vm.pinnedNotebookIDs = ["deleted-long-ago", "gdf15"]
        vm.setNotebookPinned("alzheimers", true)
        #expect(vm.pinnedNotebookIDs == ["gdf15", "alzheimers"])
        #expect(vm.pinnedNotebooks.map(\.id) == ["alzheimers", "gdf15"])
    }

    @Test("Rail chats respect manual reorder and keep new chats on top")
    func railChatsRespectManualReorder() {
        let vm = makeViewModel()
        vm.chatOrder = []
        let now = Date()
        func chat(_ id: String, offset: TimeInterval, goalID: String? = nil) -> ReviewSessionRecord {
            ReviewSessionRecord(
                id: id,
                title: id,
                createdAt: now.addingTimeInterval(offset),
                status: "completed",
                sourceIDs: [],
                goalID: goalID
            )
        }
        vm.reviewSessionLinks = [
            chat("newest", offset: 2),
            chat("middle", offset: 1),
            chat("oldest", offset: 0),
        ]

        // Newest first until the learner says otherwise.
        #expect(vm.filteredReviewSessionLinks().map(\.id) == ["newest", "middle", "oldest"])

        // Dropping a row on another takes that row's slot, the way Notebook
        // folders and the Courses panel already behave.
        vm.reorderReviewSession(from: "oldest", to: "newest")
        #expect(vm.filteredReviewSessionLinks().map(\.id) == ["oldest", "newest", "middle"])
        #expect(vm.chatOrder == ["oldest", "newest", "middle"])

        vm.reorderReviewSession(from: "oldest", to: "middle")
        #expect(vm.filteredReviewSessionLinks().map(\.id) == ["newest", "middle", "oldest"])

        // A chat started after the arrangement belongs at the top, not appended
        // below a hand-made order.
        vm.reviewSessionLinks.append(chat("added-later", offset: 3))
        #expect(vm.filteredReviewSessionLinks().map(\.id) == ["added-later", "newest", "middle", "oldest"])

        // Deleted chats drop out of the stored order rather than accumulating.
        vm.reviewSessionLinks.removeAll { $0.id == "middle" }
        vm.reorderReviewSession(from: "oldest", to: "newest")
        #expect(vm.chatOrder == ["added-later", "oldest", "newest"])

        // A missing row is not a reorder: nothing is written for an unknown id.
        let unchanged = vm.chatOrder
        vm.reorderReviewSession(from: "gone", to: "newest")
        vm.reorderReviewSession(from: "newest", to: "newest")
        #expect(vm.chatOrder == unchanged)
    }

    @Test("Manual chat order applies inside Notebook folders independently")
    func railChatOrderAppliesWithinNotebookFolders() {
        let vm = makeViewModel()
        vm.chatOrder = []
        vm.notebookOrder = []
        let now = Date()
        let notebook = LearningGoalRecord(
            id: "notebook",
            title: "Acme Nexus",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [],
            kind: LearningGoalRecord.companionKind
        )
        vm.learningGoals = [notebook]
        func chat(_ id: String, offset: TimeInterval, goalID: String?) -> ReviewSessionRecord {
            ReviewSessionRecord(
                id: id,
                title: id,
                createdAt: now.addingTimeInterval(offset),
                status: "completed",
                sourceIDs: [],
                goalID: goalID
            )
        }
        vm.reviewSessionLinks = [
            chat("filed-new", offset: 4, goalID: "notebook"),
            chat("filed-old", offset: 3, goalID: "notebook"),
            chat("loose-new", offset: 2, goalID: nil),
            chat("loose-old", offset: 1, goalID: nil),
        ]

        vm.reorderReviewSession(from: "filed-old", to: "filed-new")

        let groups = vm.reviewSessionGroups(for: vm.notebooks)
        #expect(groups.byNotebookID["notebook"]?.map(\.id) == ["filed-old", "filed-new"])
        // Rearranging inside the folder leaves the general Chats section alone.
        #expect(groups.outsideNotebooks.map(\.id) == ["loose-new", "loose-old"])
    }

    @Test("screen record scope shows only the recording Notebook, safe captures, and new work")
    func screenRecordScopeFiltersNotebooksChatsSourcesAndArtifacts() {
        let cutoff = Date()
        let oldDate = cutoff.addingTimeInterval(-60)
        let newDate = cutoff.addingTimeInterval(60)
        let vm = makeViewModel()
        defer { vm.screenRecordScope = nil }

        func notebook(id: String, createdAt: Date, sourceIDs: [String] = []) -> LearningGoalRecord {
            LearningGoalRecord(
                id: id,
                title: id,
                startAt: createdAt,
                endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: createdAt,
                updatedAt: createdAt,
                status: "active",
                items: sourceIDs.map {
                    LearningGoalItem(id: "item-\($0)", goalID: id, sourceID: $0, addedAt: createdAt)
                },
                kind: LearningGoalRecord.companionKind
            )
        }
        func source(_ id: String, addedAt: Date, origin: DiscoveryOrigin? = nil) -> StudioArticle {
            var article = makeArticle(title: id, state: .ready, discoveryOrigin: origin, id: id)
            article.dateAdded = addedAt
            return article
        }
        func chat(_ id: String, createdAt: Date, goalID: String? = nil, sourceIDs: [String] = []) -> ReviewSessionRecord {
            var record = ReviewSessionRecord(
                id: id,
                title: id,
                createdAt: createdAt,
                status: "completed",
                sourceIDs: sourceIDs
            )
            record.goalID = goalID
            return record
        }

        vm.articles = [
            source("filmed-source", addedAt: oldDate),
            source("private-source", addedAt: oldDate),
            source("new-source", addedAt: newDate, origin: .safari),
        ]
        vm.learningGoals = [
            notebook(id: "recording-notebook", createdAt: oldDate, sourceIDs: ["filmed-source"]),
            notebook(id: "private-notebook", createdAt: oldDate),
            notebook(id: "new-notebook", createdAt: newDate),
        ]
        vm.reviewSessionLinks = [
            chat("private-chat", createdAt: oldDate),
            chat("filed-chat", createdAt: oldDate, goalID: "recording-notebook"),
            chat("source-chat", createdAt: oldDate, sourceIDs: ["filmed-source"]),
            chat("new-chat", createdAt: newDate),
        ]
        var linkedDoc = ArtifactRecord(id: "linked-doc", title: "linked", homeNotebookID: "recording-notebook", linkedNotebookIDs: [], createdAt: oldDate, updatedAt: oldDate)
        linkedDoc.sourceIDs = []
        var citingDoc = ArtifactRecord(id: "citing-doc", title: "citing", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: oldDate, updatedAt: oldDate)
        citingDoc.sourceIDs = ["filmed-source"]
        let privateDoc = ArtifactRecord(id: "private-doc", title: "private", homeNotebookID: "private-notebook", linkedNotebookIDs: [], createdAt: oldDate, updatedAt: oldDate)
        let newDoc = ArtifactRecord(id: "new-doc", title: "new", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: newDate, updatedAt: newDate)

        // Off (every learner but the admin): nothing narrows.
        #expect(vm.screenRecordScope == nil)
        #expect(Set(vm.notebooks.map(\.id)) == ["recording-notebook", "private-notebook", "new-notebook"])
        #expect(vm.filteredReviewSessionLinks().count == 4)
        #expect(vm.isVisibleInRecordingMode(privateDoc))

        vm.screenRecordScope = ScreenRecordScope(
            notebookID: "recording-notebook",
            allowedSourceIDs: ["filmed-source"],
            cutoff: cutoff
        )

        // The source arrays stay whole (discovery dedups against them); only
        // what the lists show narrows.
        #expect(vm.articles.count == 3)
        vm.sidebarTab = .articles
        #expect(Set(vm.filteredActiveItems.map(\.id)) == ["filmed-source", "new-source"])
        #expect(vm.isSourceIDVisibleInRecordingMode("filmed-source"))
        #expect(!vm.isSourceIDVisibleInRecordingMode("private-source"))
        #expect(!vm.isSourceIDVisibleInRecordingMode("unknown-source"))
        #expect(Set(vm.notebooks.map(\.id)) == ["recording-notebook", "new-notebook"])
        // Being about a filmed source is not enough (b0fac858c): that chat
        // and that Doc are the learner's own. Nor is being filed under the
        // recording Notebook (560f8a8): only work made during the take shows.
        #expect(Set(vm.filteredReviewSessionLinks().map(\.id)) == ["new-chat"])
        #expect(!vm.isVisibleInRecordingMode(linkedDoc))
        #expect(!vm.isVisibleInRecordingMode(citingDoc))
        #expect(vm.isVisibleInRecordingMode(newDoc))
        #expect(!vm.isVisibleInRecordingMode(privateDoc))

        vm.screenRecordScope = nil
        vm.invalidateSidebarCachesInEveryWindow()
        #expect(Set(vm.notebooks.map(\.id)) == ["recording-notebook", "private-notebook", "new-notebook"])
        #expect(vm.filteredReviewSessionLinks().count == 4)
        #expect(vm.filteredActiveItems.count == 3)
    }

    @Test("a from-scratch take shows its own Notebook, the public sources filed into it and its date stamps, and nothing older")
    func screenRecordScopeShowsAFromScratchTake() {
        let cutoff = Date()
        let oldDate = cutoff.addingTimeInterval(-86_400 * 21)
        let newDate = cutoff.addingTimeInterval(60)
        let vm = makeViewModel()
        defer { vm.screenRecordScope = nil }

        func source(_ id: String, addedAt: Date, type: StudioSourceType = .article, url: String) -> StudioArticle {
            var article = makeArticle(url: url, title: id, sourceType: type, state: .ready, discoveryOrigin: .manual, id: id)
            article.dateAdded = addedAt
            return article
        }
        func notebook(id: String, createdAt: Date, sourceIDs: [String]) -> LearningGoalRecord {
            LearningGoalRecord(
                id: id, title: id, startAt: createdAt, endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: createdAt, updatedAt: createdAt, status: "active",
                items: sourceIDs.map { LearningGoalItem(id: "item-\($0)", goalID: id, sourceID: $0, addedAt: createdAt) },
                kind: LearningGoalRecord.companionKind
            )
        }

        vm.articles = [
            source("talk", addedAt: newDate, type: .video, url: "https://www.youtube.com/watch?v=abc"),
            source("article", addedAt: newDate, url: "https://example.org/field-notes"),
            source("already-in-library", addedAt: oldDate, url: "https://example.org/read-last-year"),
            source("older-notebook-source", addedAt: oldDate, url: "https://example.org/private-reading"),
            source("not-filed", addedAt: newDate, url: "https://example.org/stray"),
        ]
        vm.learningGoals = [
            notebook(id: "started-in-take", createdAt: newDate, sourceIDs: ["talk", "article", "already-in-library"]),
            notebook(id: "older-notebook", createdAt: oldDate, sourceIDs: ["older-notebook-source"]),
        ]

        // The scope a Studio window resolves: no recording Notebook, the take's own Notebook's sources.
        vm.screenRecordScope = ScreenRecordScope(
            notebookID: nil,
            allowedSourceIDs: [],
            takeSourceIDs: ["talk", "article", "already-in-library"],
            cutoff: cutoff
        )
        vm.invalidateSidebarCachesInEveryWindow()

        #expect(Set(vm.notebooks.map(\.id)) == ["started-in-take"])
        #expect(vm.isSourceIDVisibleInRecordingMode("article"))
        #expect(vm.isSourceIDVisibleInRecordingMode("talk"))
        #expect(!vm.isSourceIDVisibleInRecordingMode("already-in-library"), "an old library source filed into the Notebook stays off screen")
        #expect(!vm.isSourceIDVisibleInRecordingMode("older-notebook-source"))
        #expect(!vm.isSourceIDVisibleInRecordingMode("not-filed"), "a new source in no take Notebook earns nothing without a Reading List origin")
        #expect(vm.articles.count == 5, "the source array stays whole")

        // Date stamps: the take's own rows keep them; anything older reads as abandoned and is not drawn.
        #expect(vm.showsDateStamp(newDate))
        #expect(!vm.showsDateStamp(oldDate))
        vm.screenRecordScope = nil
        #expect(vm.showsDateStamp(oldDate))
    }

    @Test("research questions column codec round-trips")
    func researchQuestionsCodec() {
        // NULL means never-set (sync treats it as no-opinion); "[]" is an
        // explicit clear and must decode as an empty list, not nil.
        #expect(KnowledgeStore.decodeResearchQuestions(nil) == nil)
        #expect(KnowledgeStore.decodeResearchQuestions("[]") == [])
        let questions = ["How does GDF15 signal satiety?", "What limits mitochondrial uptake?"]
        let encoded = KnowledgeStore.encodeResearchQuestions(questions)
        #expect(KnowledgeStore.decodeResearchQuestions(encoded) == questions)
    }

    @Test("center tab groups reconcile to a full partition")
    func centerTabGroupsReconcile() {
        // Duplicates collapse to first appearance, empty groups dissolve, and
        // missing permanent tabs append to the final group.
        let raw = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .chat], activeTab: .chat),
            .init(tabs: [], activeTab: .reader),
            .init(tabs: [.reader, .chat], activeTab: .reader),
        ])
        let value = StudioCenterTabGroups.reconciled(raw)
        #expect(value.groups.count == 2)
        #expect(value.groups[0].tabs == [.chat])
        #expect(value.groups[1].tabs == [.reader, .tasks, .activity, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .memory, .knowledgeMap, .atlas, .library, .plugins])
        #expect(value.groups[1].activeTab == .reader)

        let persisted = value.persistedRepresentation
        #expect(persisted == ["chat*", "reader*|tasks|activity|goals|courses|ideas|notepad|sites|browser|videos|animations|artifacts|memory|knowledgeMap|atlas|library|plugins"])
        let decoded = StudioCenterTabGroups.fromPersisted(persisted)
        #expect(decoded?.groups.count == 2)
        #expect(decoded?.groups[1].activeTab == .reader)

        // Ignore the retired Voice and Goal tokens in old preference values,
        // and fall back to the first live tab.
        let legacy = StudioCenterTabGroups.fromPersisted([
            "voice|chat*",
            "goal*|reader|notebooks",
        ])
        #expect(legacy?.groups[0].tabs == [.chat])
        #expect(legacy?.groups[1].tabs == [.reader, .artifacts, .tasks, .activity, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .memory, .knowledgeMap, .atlas, .library])
        #expect(legacy?.groups[1].activeTab == .reader)

        // Older builds allowed four panes. Loading that arrangement folds the
        // extras into the overflow cap without losing any permanent tabs.
        let crowded = StudioCenterTabGroups.reconciled(.init(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
            .init(tabs: [.tasks], activeTab: .tasks),
            .init(tabs: [.notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
        ]))
        #expect(crowded.groups.count == StudioCenterTabGroups.overflowGroupCount)
        #expect(Set(crowded.groups.flatMap(\.tabs)) == Set(StudioCenterTab.permanentTabs))
    }

    @Test("Studio windows keep independent workspace layouts")
    func studioWindowsKeepIndependentWorkspaceLayouts() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }

        let first = StudioWindowState(snapshot: .init(
            centerTabGroups: StudioCenterTabGroups.defaultLayout.persistedRepresentation,
            navigationRailVisible: true
        ))
        let second = StudioWindowState(snapshot: .init(
            centerTabGroups: StudioCenterTabGroups.defaultLayout.persistedRepresentation,
            navigationRailVisible: true
        ))
        // The default layout is one pane since the Notebooks home leads it;
        // each window changes its own last pane.
        var firstLayout = first.centerTabGroups
        firstLayout.groups[firstLayout.groups.count - 1].activeTab = .tasks
        first.centerTabGroups = firstLayout
        first.navigationRailVisible = false

        var secondLayout = second.centerTabGroups
        secondLayout.groups[secondLayout.groups.count - 1].activeTab = .notepad
        second.centerTabGroups = secondLayout

        #expect(first.centerTabGroups.groups.contains { $0.activeTab == .tasks })
        #expect(!first.centerTabGroups.groups.contains { $0.activeTab == .notepad })
        #expect(first.navigationRailVisible == false)

        #expect(second.centerTabGroups.groups.contains { $0.activeTab == .notepad })
        #expect(!second.centerTabGroups.groups.contains { $0.activeTab == .tasks })
        #expect(second.navigationRailVisible == true)
    }

    @Test("Studio window snapshots round-trip scene presentation")
    func studioWindowSnapshotsRoundTrip() {
        let original = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat", "reader|tasks|notepad*|notebooks"],
            navigationRailVisible: false
        ))
        let encoded = original.encodedSnapshot()
        let restored = StudioWindowState()
        restored.restore(from: encoded)

        #expect(restored.snapshot == original.snapshot)
        #expect(restored.centerTabGroups.groups.contains { $0.activeTab == .notepad })
        #expect(restored.navigationRailVisible == false)
    }

    @Test("Source drag payloads remain loadable by Schedule across Studio windows")
    func sourceDragPayloadSupportsCrossWindowScheduleDrop() async {
        let article = makeArticle(id: "cross-window-source")
        let provider = articleDragProvider(for: article)
        defer { StudioDragVisibility.shared.endSoon() }

        #expect(mcpSourceContextDropTypes.contains(.studioSourceID))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.studioSourceID.identifier))

        let loaded: (Data?, Error?) = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.studioSourceID.identifier
            ) { data, error in
                continuation.resume(returning: (data, error))
            }
        }
        #expect(loaded.1 == nil)
        #expect(loaded.0.flatMap { String(data: $0, encoding: .utf8) } == article.id)
    }

    @Test("a stored workspace is restored on launch")
    func launchRestoresStoredWorkspace() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let stored = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
        ]).persistedRepresentation
        UserDefaults.standard.set(stored, forKey: "studio.centerTabGroups.v1")

        let vm = makeViewModel()

        #expect(vm.centerTabGroups.groups.count == 2)
        #expect(vm.activeCenterTabs == [.chat, .notepad])
        #expect(UserDefaults.standard.stringArray(forKey: "studio.centerTabGroups.v1") == stored)
    }

    @Test("preference hydration restores the complete synced workspace")
    func preferenceHydrationRestoresCompleteWorkspace() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }

        UserDefaults.standard.set(StudioCenterTabGroups.defaultLayout.persistedRepresentation, forKey: "studio.centerTabGroups.v1")
        let vm = makeViewModel()
        let stored = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks], activeTab: .reader),
            .init(tabs: [.artifacts], activeTab: .artifacts),
            .init(tabs: [.notepad], activeTab: .notepad),
        ]).persistedRepresentation
        UserDefaults.standard.set(stored, forKey: "studio.centerTabGroups.v1")

        vm.reloadSyncedPreferences()

        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.overflowGroupCount)
        #expect(vm.activeCenterTabs == [.chat, .reader, .artifacts])
        #expect(Set(vm.centerTabGroups.groups.flatMap(\.tabs)) == Set(StudioCenterTab.permanentTabs))
        #expect(UserDefaults.standard.stringArray(forKey: "studio.centerTabGroups.v1") == stored)
    }

    @Test("pane dividers preserve usable widths")
    func paneDividerConstraint() {
        #expect(StudioPaneDividerConstraint.clamp(
            0.05,
            hardLower: 0,
            hardUpper: 1,
            leadingMinimumWidth: 200,
            trailingMinimumWidth: 200,
            usableWidth: 1_000
        ) == 0.2)
        #expect(StudioPaneDividerConstraint.clamp(
            0.95,
            hardLower: 0,
            hardUpper: 1,
            leadingMinimumWidth: 200,
            trailingMinimumWidth: 200,
            usableWidth: 1_000
        ) == 0.8)
        // An actually narrow window keeps hard divider behavior because both
        // minimums cannot fit; clipping remains preferable to a stuck handle.
        #expect(StudioPaneDividerConstraint.clamp(
            0.25,
            hardLower: 0,
            hardUpper: 1,
            leadingMinimumWidth: 360,
            trailingMinimumWidth: 200,
            usableWidth: 500
        ) == 0.25)
    }

    @Test("every center pane opens the golden ratio wider than the sidebar")
    func goldenSideWidthKeepsCenterPanesPhiTimesTheSides() {
        let windowWidth: CGFloat = 2_560
        let divider = StudioOuterPanelSizing.dividerWidth
        let phi = StudioPanelDefaultSizing.goldenRatio

        // The row is sized as if a second, equal side shared the window; one
        // divider falls between each pair of center panes and one after the
        // sidebar.
        for panes in 1...3 {
            let side = StudioPanelDefaultSizing.goldenSideWidth(
                windowWidth: windowWidth,
                centerPaneCount: panes
            )
            let center = windowWidth - 2 * side - CGFloat(panes) * divider
            let pane = center / CGFloat(panes)
            #expect(abs(pane / side - phi) < 0.01)
        }

        // Splitting the center makes the row owe φ one more time, so the
        // sidebar narrows rather than the panes growing past the ratio.
        let one = StudioPanelDefaultSizing.goldenSideWidth(windowWidth: windowWidth, centerPaneCount: 1)
        let two = StudioPanelDefaultSizing.goldenSideWidth(windowWidth: windowWidth, centerPaneCount: 2)
        #expect(two < one)

        // A narrow window cannot honor the ratio and give the rail a usable
        // width; the minimum wins there.
        #expect(StudioPanelDefaultSizing.goldenSideWidth(windowWidth: 900, centerPaneCount: 2)
            == StudioNavigationRail.minRailWidth)
    }

    @Test("opening a source from the launch pane keeps the greeting beside it")
    func openingSourceRevealsReaderBesideChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .chat),
        ])

        vm.clearReaderSurfaces()
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .tasks, .activity, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .memory, .knowledgeMap, .atlas, .library], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
        ])

        // With Chat no longer the Reader pane's surface, a source takes that
        // surface back as it always did — the other pane keeps its own surface.
        vm.activateCenterTab(.tasks)
        vm.clearReaderSurfaces()
        #expect(vm.activeCenterTabs == [.tasks, .reader])

        // And in a single pane showing a list surface, the source replaces
        // it rather than splitting the window.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.clearReaderSurfaces()
        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.activeCenterTabs == [.reader])
    }

    @Test("sidebar sources open on one click in every center layout")
    func sidebarSourceClickPolicy() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])
        #expect(vm.opensSidebarSourcesOnSingleClick)

        vm.activateCenterTab(.artifacts)
        #expect(vm.opensSidebarSourcesOnSingleClick)

        // A first launch leads with the Notebooks home.
        vm.centerTabGroups = .defaultLayout
        #expect(vm.activeCenterTabs == [.artifacts])
        #expect(vm.opensSidebarSourcesOnSingleClick)
    }

    @Test("a pinned Docs pane survives sidebar navigation")
    func pinnedPaneRoutesNavigationElsewhere() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .notepad
            ),
        ])

        vm.toggleCenterPanePinned(containing: .notepad)
        vm.activateCenterTab(.artifacts)

        #expect(vm.centerTabGroups.groups == [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library],
                activeTab: .notepad,
                isPinned: true
            ),
            .init(tabs: [.artifacts], activeTab: .artifacts),
        ])

        // At capacity, the same contract reuses the unpinned pane instead of
        // replacing the Doc that the learner protected.
        vm.activateCenterTab(.tasks)
        #expect(vm.centerTabGroups.groups[0].activeTab == .notepad)
        #expect(vm.centerTabGroups.groups[0].isPinned)
        #expect(vm.centerTabGroups.groups[1].activeTab == .tasks)
        #expect(!vm.centerTabGroups.groups[1].isPinned)

        vm.toggleCenterPanePinned(containing: .tasks)
        #expect(vm.centerTabGroups.groups[0].isPinned)
        #expect(vm.centerTabGroups.groups[1].isPinned)
    }

    @Test("pinning both panes opens the next destination as a third pane")
    func pinnedPanesOpenOverflowDestination() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.artifacts, .chat, .reader],
                activeTab: .artifacts,
                isPinned: true
            ),
            .init(
                tabs: [.notepad, .sites, .tasks],
                activeTab: .notepad,
                isPinned: true
            ),
        ])

        vm.activateCenterTab(.chat)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.artifacts, .reader], activeTab: .artifacts, isPinned: true),
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.notepad, .sites, .tasks, .activity, .goals, .courses, .ideas, .browser, .videos, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .notepad, isPinned: true),
        ])

        vm.toggleCenterPanePinned(containing: .chat)
        let pinnedOverflow = vm.centerTabGroups
        vm.activateCenterTab(.tasks)
        #expect(vm.centerTabGroups == pinnedOverflow)
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [true, true, true])
        #expect(!vm.activeCenterTabs.contains(.tasks))
    }

    @Test("New chat opens beside the source being read, not over it")
    func newChatOpensBesideTheOpenSource() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let source = makeArticle(url: "https://example.com/read-here", title: "Read here", state: .ready, id: "read-here")
            .with(content: "Already loaded.")
        vm.articles = [source]
        // One pane holding every tab, the Activity pane showing.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .activity
            ),
        ])

        await vm.selectArticle(source.id)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader])
        #expect(vm.centerTabGroups.groups[0].isPinned)

        vm.requestBlankReviewChat()

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [true, false])
        #expect(vm.selectedArticleId == source.id)
    }

    @Test("the next rail destination opens over Chat while a source is being read")
    func railDestinationLeavesTheOpenSource() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let source = makeArticle(url: "https://example.com/keep-reading", title: "Keep reading", state: .ready, id: "keep-reading")
            .with(content: "Already loaded.")
        vm.articles = [source]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .notepad
            ),
        ])

        await vm.selectArticle(source.id)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [false, true])

        vm.openActivityInReader()

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.activity, .reader])
    }

    @Test("a Reader pane the learner unpinned is not pinned again by the next source")
    func unpinnedReaderPaneKeepsTheLearnersChoice() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First", state: .ready, id: "first")
            .with(content: "Already loaded.")
        let second = makeArticle(url: "https://example.com/second", title: "Second", state: .ready, id: "second")
            .with(content: "Already loaded.")
        vm.articles = [first, second]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])

        await vm.selectArticle(first.id)
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [false, true])

        vm.toggleCenterPanePinned(containing: .reader)
        await vm.selectArticle(second.id)

        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [false, false])
        // Unpinned, the pane is the learner's to replace again.
        vm.openActivityInReader()
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .activity])

        // The Reader coming back into that pane keeps the choice...
        await vm.selectArticle(first.id)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [false, false])

        // ...and a pane made afresh for the Reader starts pinned again.
        vm.dismissCenterSurface(.reader)
        await vm.selectArticle(second.id)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [false, true])
    }

    @Test("pinned pane state round-trips without hiding tabs from older layouts")
    func pinnedPanePersistence() {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library],
                activeTab: .notepad,
                isPinned: true
            ),
        ])

        #expect(layout.persistedRepresentation == [
            "chat*",
            "!|reader|tasks|activity|notepad*|sites|browser|videos|animations|artifacts|goals|ideas|courses|memory|knowledgeMap|atlas|library",
        ])
        #expect(StudioCenterTabGroups.fromPersisted(layout.persistedRepresentation) == layout)
        #expect(
            StudioCenterTabGroups.fromPersisted(["chat*", "reader|notepad*"])?
                .groups.contains(where: \.isPinned) == false
        )

        let bothPinned = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts], activeTab: .artifacts, isPinned: true),
            .init(tabs: [.notepad], activeTab: .notepad, isPinned: true),
            .init(tabs: [.chat, .reader, .tasks, .activity, .sites, .browser, .videos, .animations, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library], activeTab: .chat),
        ])
        #expect(bothPinned.persistedRepresentation == [
            "!|artifacts*",
            "!|notepad*",
            "chat*|reader|tasks|activity|sites|browser|videos|animations|goals|ideas|courses|memory|knowledgeMap|atlas|library",
        ])
        #expect(StudioCenterTabGroups.fromPersisted(bothPinned.persistedRepresentation) == bothPinned)
    }

    @Test("saved workspace views round-trip every window independently")
    func savedWorkspaceViewsRoundTripEveryWindow() {
        let left = StudioWindowState(snapshot: .init(
            centerTabGroups: ["notebooks*", "reader*"],
            navigationRailVisible: false
        ))
        let right = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*", "!|notepad*"],
            navigationRailVisible: true
        ))
        let leftPlacement = StudioWindowPlacement(
            displayUUID: "LEFT-UUID",
            displayID: "101",
            displayName: "Left Display",
            displayIndex: 0,
            normalizedX: 0.05,
            normalizedY: 0.08,
            normalizedWidth: 0.9,
            normalizedHeight: 0.84
        )
        let rightPlacement = StudioWindowPlacement(
            displayUUID: "RIGHT-UUID",
            displayID: "202",
            displayName: "Right Display",
            displayIndex: 1,
            normalizedX: 0.1,
            normalizedY: 0.12,
            normalizedWidth: 0.82,
            normalizedHeight: 0.8
        )
        let saved = StudioSavedWorkspaceView(
            id: "research-workspace",
            name: "Research Workspace",
            createdAt: 42,
            windows: [
                .init(snapshot: left.snapshot, placement: leftPlacement),
                .init(snapshot: right.snapshot, placement: rightPlacement),
            ]
        )

        let decoded = StudioSavedWorkspaceView(
            preferenceKey: saved.preferenceKey,
            value: saved.propertyList
        )
        #expect(decoded == saved)
        #expect(decoded?.windows.count == 2)
        #expect(decoded?.windows.map(\.placement) == [leftPlacement, rightPlacement])

        let rightBefore = right.snapshot
        left.applyWorkspaceSnapshot(right.snapshot)
        #expect(left.snapshot == rightBefore)
        #expect(right.snapshot == rightBefore)

        // Changing the restored left window does not reach the right window's
        // scene state, including its pane pin.
        left.navigationRailVisible = false
        #expect(!left.navigationRailVisible)
        #expect(right.navigationRailVisible)
        #expect(right.centerTabGroups.groups.contains { $0.isPinned })
    }

    @Test("workspace restore keeps each live window on its saved physical display")
    func workspaceRestoreMatchesPhysicalDisplaysBeforeInvokingWindow() {
        let left = StudioWindowPlacement(
            displayID: "101",
            displayName: "Matching Monitor",
            displayIndex: 0,
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 1,
            normalizedHeight: 1
        )
        let right = StudioWindowPlacement(
            displayID: "202",
            displayName: "Matching Monitor",
            displayIndex: 1,
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 1,
            normalizedHeight: 1
        )

        // The right-hand window opened the menu, while the coordinator's
        // spatial ordering puts it before the left-hand window. Invoker-first
        // restore used to swap these two windows across displays.
        let assignments = StudioWorkspaceWindowMatcher.assignments(
            saved: [left, right],
            existing: [right, left],
            preferredExistingIndex: 0
        )

        #expect(assignments == [1, 0])
    }

    @Test("workspace display resolution disambiguates identical monitor names")
    func workspaceDisplayResolutionUsesStableIdentityThenSpatialFallback() {
        let displays = [
            StudioDisplayDescriptor(uuid: "LEFT-UUID", id: "11", name: "Same Monitor", index: 0),
            StudioDisplayDescriptor(uuid: "RIGHT-UUID", id: "22", name: "Same Monitor", index: 1),
        ]
        let stableIdentity = StudioWindowPlacement(
            displayUUID: "RIGHT-UUID",
            displayID: "stale-id",
            displayName: "Same Monitor",
            displayIndex: 0,
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 1,
            normalizedHeight: 1
        )
        let legacyPlacement = StudioWindowPlacement(
            displayID: "stale-id",
            displayName: "Same Monitor",
            displayIndex: 1,
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 1,
            normalizedHeight: 1
        )

        #expect(StudioWorkspaceDisplayResolver.index(for: stableIdentity, among: displays) == 1)
        #expect(StudioWorkspaceDisplayResolver.index(for: legacyPlacement, among: displays) == 1)
    }

    @Test("whole workspace restore reapplies existing windows and queues missing ones")
    func wholeWorkspaceRestoreRecreatesWindowSet() {
        let coordinator = StudioWorkspaceWindowCoordinator()
        let firstState = StudioWindowState()
        let secondState = StudioWindowState()
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 130, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            coordinator.unregister(state: firstState)
            coordinator.unregister(state: secondState)
        }

        coordinator.register(state: firstState, window: firstWindow)
        let firstSnapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["notebooks*", "!|reader*"],
            navigationRailVisible: false
        )
        let secondSnapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["chat*", "!|notepad*"],
            navigationRailVisible: true
        )
        let firstPlacement = StudioWindowPlacement(
            displayID: nil,
            displayName: NSScreen.main?.localizedName,
            displayIndex: 0,
            normalizedX: 0.08,
            normalizedY: 0.1,
            normalizedWidth: 0.6,
            normalizedHeight: 0.7
        )
        let secondPlacement = StudioWindowPlacement(
            displayID: nil,
            displayName: NSScreen.main?.localizedName,
            displayIndex: 0,
            normalizedX: 0.68,
            normalizedY: 0.1,
            normalizedWidth: 0.3,
            normalizedHeight: 0.7
        )
        let saved = StudioSavedWorkspaceView(
            id: "two-window-workspace",
            name: "Two Window Workspace",
            createdAt: 42,
            windows: [
                .init(snapshot: firstSnapshot, placement: firstPlacement),
                .init(snapshot: secondSnapshot, placement: secondPlacement),
            ]
        )
        let expectedFirstSnapshot = StudioWindowState(snapshot: firstSnapshot).snapshot
        let expectedSecondSnapshot = StudioWindowState(snapshot: secondSnapshot).snapshot

        #expect(coordinator.restore(saved, invokedBy: firstState) == 1)
        #expect(firstState.snapshot == expectedFirstSnapshot)
        #expect(firstState.workspaceRestoreOverridesSceneSnapshot)

        coordinator.register(state: secondState, window: secondWindow)
        #expect(secondState.snapshot == expectedSecondSnapshot)
        #expect(secondState.workspaceRestoreOverridesSceneSnapshot)

        let recaptured = coordinator.captureWorkspace()
        #expect(recaptured.count == 2)
        #expect(recaptured.allSatisfy { $0.placement != nil })
    }

    @Test("center tabs move and dissolve without exceeding two panes")
    func centerTabMoves() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        // Chat beside the reading surfaces: two panes, at the cap.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .notepad, .sites, .browser, .artifacts], activeTab: .reader),
        ])

        let atCapacity = vm.centerTabGroups
        vm.moveCenterTabToNewGroup(.artifacts, at: 2)
        #expect(vm.centerTabGroups == atCapacity)

        vm.moveCenterTab(.artifacts, toGroup: 0, at: 1)
        #expect(vm.centerTabGroups.groups.count == 2)
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat, .artifacts])
        #expect(vm.centerTabGroups.groups[0].activeTab == .artifacts)

        // Moving the final tab out of a group dissolves that group.
        vm.moveCenterTab(.artifacts, toGroup: 1, at: 0)
        vm.moveCenterTab(.chat, toGroup: 1, at: 0)
        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)

        // A tab alone in its group parks in the neighbor when "closed".
        vm.moveCenterTabToNewGroup(.reader, at: 1)
        #expect(vm.centerTabGroups.groups.count == 2)
        vm.deactivateCenterTab(.reader)
        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.centerTabGroups.groups[0].tabs.contains(.reader))
    }

    @Test("closing a center pane moves all of its tabs into its neighbor")
    func closeCenterPane() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])

        // Closing the left pane (including from its hidden-tab-bar close
        // affordance) leaves the right pane and its active surface intact.
        vm.closeCenterPane(containing: .chat)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .artifacts),
        ])

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])

        // Closing the final pane moves its tabs left, preserving the
        // destination pane's active surface.
        vm.closeCenterPane(containing: .artifacts)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .chat),
        ])

        // The last remaining pane has nowhere to move its tabs.
        let onlyPane = vm.centerTabGroups
        vm.closeCenterPane(containing: .reader)
        #expect(vm.centerTabGroups == onlyPane)
    }

    @Test("dismissing Reader remains actionable in the sole center pane")
    func dismissReaderFromSoleCenterPane() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])

        vm.dismissCenterSurface(.reader)

        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.centerTabGroups.groups[0].activeTab == .artifacts, "the Notebooks home")
        #expect(vm.centerTabGroups.groups[0].tabs.contains(.reader))
    }

    @Test("every sole center pane closes onto the Notebooks home")
    func dismissSoleCenterPaneRevealsTheHome() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        // Docs, Tasks and Chat close onto the home: an empty Reader is a
        // second empty surface rather than a way out of the one being
        // closed, and since 2026-10-01 the home is what a window holding no
        // notebook shows.
        for tab in [StudioCenterTab.notepad, .tasks, .chat, .library] {
            vm.centerTabGroups = StudioCenterTabGroups(groups: [
                .init(
                    tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                    activeTab: tab,
                    isPinned: true
                ),
            ])

            vm.dismissCenterSurface(tab)

            #expect(vm.centerTabGroups.groups.count == 1)
            #expect(vm.centerTabGroups.groups[0].activeTab == .artifacts, "\(tab)")
            // Closing a pinned pane is itself a request to release the pin.
            #expect(!vm.centerTabGroups.groups[0].isPinned)
        }

        // The home is the one surface that cannot close onto itself; it
        // reveals Chat instead.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.dismissCenterSurface(.artifacts)
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)
    }

    @Test("pane close mutates the window that rendered the titlebar control")
    func closePaneUsesExplicitWindowState() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let activeLayout = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library],
                activeTab: .tasks
            ),
        ])
        vm.centerTabGroups = activeLayout

        let clickedWindow = StudioWindowState()
        clickedWindow.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])

        // A titlebar button accepts first mouse and may run before its window
        // becomes key. Its own scene state must still be the mutation target.
        vm.dismissCenterSurface(.reader, in: clickedWindow)

        #expect(vm.centerTabGroups == activeLayout)
        #expect(clickedWindow.centerTabGroups.groups == [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library],
                activeTab: .chat
            ),
        ])
    }

    @Test("center tab drag payload accepts only center tabs")
    func centerTabDragPayload() {
        for tab in StudioCenterTab.allCases {
            let payload = StudioCenterTabDragPayload.string(for: tab)
            #expect(StudioCenterTabDragPayload.tab(from: payload) == tab)

            let pasteboardItem = StudioCenterTabDragPayload.pasteboardItem(for: tab)
            #expect(
                pasteboardItem.string(forType: StudioCenterTabDragPayload.pasteboardType) == payload
            )
            #expect(pasteboardItem.string(forType: .string) == payload)
        }
        #expect(StudioCenterTabDragPayload.dropTypes.first == StudioCenterTabDragPayload.contentType)
        #expect(StudioCenterTabDragPayload.tab(from: "reader") == nil)
        #expect(StudioCenterTabDragPayload.tab(from: "centerTab:voice") == nil)
        #expect(StudioCenterTabDragPayload.tab(from: "centerTab:not-a-tab") == nil)
        #expect(StudioCenterTabDragPayload.tab(from: "centerTab:reader:extra") == nil)
    }

    @Test("the New chat row's payload asks its new pane for a blank conversation")
    func centerTabDragPayloadCarriesBlankChatRequest() {
        let payload = StudioCenterTabDragPayload.string(for: .chat, startsBlankChat: true)
        let decoded = StudioCenterTabDragPayload.payload(from: payload)
        #expect(decoded == StudioCenterTabDragPayload.Payload(tab: .chat, startsBlankChat: true))
        #expect(StudioCenterTabDragPayload.tab(from: payload) == .chat)

        // An ordinary Chat tab drag carries the loaded conversation.
        let plain = StudioCenterTabDragPayload.payload(from: StudioCenterTabDragPayload.string(for: .chat))
        #expect(plain == StudioCenterTabDragPayload.Payload(tab: .chat, startsBlankChat: false))
        #expect(StudioCenterTabDragPayload.payload(from: "centerTab:not-a-tab?new") == nil)
    }

    @Test("dragging a whole pane never lights up content drop zones")
    @MainActor
    func paneDragHidesContentDropZones() {
        let visibility = StudioDragVisibility.shared
        defer { visibility.endNow() }

        let goal = LearningGoalRecord(
            id: "pane-drag-goal",
            title: "Mitochondria",
            startAt: Date(),
            endAt: Date(),
            createdAt: Date(),
            updatedAt: Date(),
            status: "active",
            items: []
        )

        visibility.begin(centerTab: .tasks)
        #expect(visibility.isPaneDrag)
        #expect(notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: visibility) == false)

        // A source drag still offers the notebook as a destination.
        visibility.begin(articleIDs: ["source-1"])
        #expect(visibility.isPaneDrag == false)
        #expect(notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: visibility))
    }

    @Test("a Docs row's drag carries the Docs pane and the doc itself")
    func docRowDragCarriesPaneAndDoc() async throws {
        let artifact = ArtifactRecord(
            id: "doc-drag-1",
            title: "Can you repair mitochondrial DNA?",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        let provider = studioArtifactDragProvider(for: artifact)

        // The edge split reads the pane; the chat reads the doc.
        #expect(provider.hasItemConformingToTypeIdentifier(StudioCenterTabDragPayload.contentType.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.studioArtifact.identifier))

        func load(_ type: UTType) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        let loadedPane = await load(StudioCenterTabDragPayload.contentType)
        let paneData = try #require(loadedPane)
        let pane = String(decoding: paneData, as: UTF8.self)
        #expect(StudioCenterTabDragPayload.payload(from: pane) == .init(tab: .notepad))

        let loadedDoc = await load(.studioArtifact)
        let docData = try #require(loadedDoc)
        let transfer = try JSONDecoder().decode(StudioArtifactTransfer.self, from: docData)
        #expect(transfer == StudioArtifactTransfer(artifactID: artifact.id, title: artifact.title))
    }

    @Test("dragging a Doc offers the chat and not the Notebooks")
    @MainActor
    func docDragOffersChatNotNotebooks() {
        let visibility = StudioDragVisibility.shared
        defer { visibility.endNow() }

        let goal = LearningGoalRecord(
            id: "doc-drag-goal",
            title: "Mitochondria",
            startAt: Date(),
            endAt: Date(),
            createdAt: Date(),
            updatedAt: Date(),
            status: "active",
            items: []
        )

        visibility.begin(centerTab: .notepad, artifactID: "doc-1")
        #expect(visibility.isDragging)
        #expect(visibility.draggedCenterTab == .notepad)
        #expect(visibility.draggedArtifactID == "doc-1")
        // Not a pane drag: the chat's drop target must show for it.
        #expect(visibility.isPaneDrag == false)
        // But not a source either: no Notebook can take a doc.
        #expect(notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: visibility) == false)

        visibility.endNow()
        #expect(visibility.draggedArtifactID == nil)
        #expect(visibility.draggedCenterTab == nil)

        // The rail's Docs row still drags only the pane.
        visibility.begin(centerTab: .notepad)
        #expect(visibility.isPaneDrag)
    }

    @Test("the chat's AppKit drop catcher hands a doc, a source, or a file to the .onDrop handler")
    func chatDropCatcherHandsPayloadsToTheOnDropHandler() async throws {
        let types: [UTType] = [.studioArticle, .studioArtifact, .studioSourceID, .studioGroup, .fileURL]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        // A Docs row's drag: the pane for the edge split, the doc for the chat.
        let doc = NSPasteboardItem()
        doc.setString(StudioCenterTabDragPayload.string(for: .notepad), forType: StudioCenterTabDragPayload.pasteboardType)
        let transfer = StudioArtifactTransfer(artifactID: "doc-1", title: "Can you repair mitochondrial DNA?")
        doc.setData(try JSONEncoder().encode(transfer), forType: NSPasteboard.PasteboardType(UTType.studioArtifact.identifier))
        // A source row's drag: its transfer and its bare id on one item.
        let source = NSPasteboardItem()
        source.setData(Data("{}".utf8), forType: NSPasteboard.PasteboardType(UTType.studioArticle.identifier))
        source.setString("src_1", forType: NSPasteboard.PasteboardType(UTType.studioSourceID.identifier))
        // A file from the Finder.
        let file = NSPasteboardItem()
        file.setString("file:///tmp/paper.pdf", forType: .fileURL)
        // A dragged string, and a bare pane drag, are not the catcher's.
        let text = NSPasteboardItem()
        text.setString("hello", forType: .string)
        let pane = NSPasteboardItem()
        pane.setString(StudioCenterTabDragPayload.string(for: .artifacts), forType: StudioCenterTabDragPayload.pasteboardType)
        #expect(pasteboard.writeObjects([doc, source, file, text, pane]))

        let providers = studioDropItemProviders(from: pasteboard, types: types)
        #expect(providers.count == 3)

        func load(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        let docProvider = try #require(providers.first)
        #expect(docProvider.hasItemConformingToTypeIdentifier(UTType.studioArtifact.identifier))
        // The pane rides along for the edge split only; the chat never sees it.
        #expect(!docProvider.hasItemConformingToTypeIdentifier(StudioCenterTabDragPayload.contentType.identifier))
        let docData = try #require(await load(docProvider, .studioArtifact))
        let decoded = try JSONDecoder().decode(StudioArtifactTransfer.self, from: docData)
        #expect(decoded == transfer)

        let sourceProvider = try #require(providers.dropFirst().first)
        #expect(sourceProvider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier))
        #expect(sourceProvider.hasItemConformingToTypeIdentifier(UTType.studioSourceID.identifier))
        let idData = try #require(await load(sourceProvider, .studioSourceID))
        #expect(String(decoding: idData, as: UTF8.self) == "src_1")

        // `handleDrop` reads a file the way `.onDrop` delivers one: `loadItem`,
        // then `URL(dataRepresentation:)`.
        let fileProvider = try #require(providers.last)
        let item: NSSecureCoding? = await withCheckedContinuation { continuation in
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                continuation.resume(returning: item)
            }
        }
        let fileData = try #require(item as? Data)
        #expect(URL(dataRepresentation: fileData, relativeTo: nil) == URL(string: "file:///tmp/paper.pdf"))
    }

    @Test("the drop catcher registers exactly its types and never takes a click")
    @MainActor
    func chatDropCatcherRegistersExactTypes() {
        let types: [UTType] = [.studioArticle, .studioArtifact, .fileURL]
        let view = StudioDropCatcherView(types: types)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        // Exact identifiers, so it is the deepest match for these drags and
        // for nothing else — a dragged string still reaches the composer.
        // AppKit hands the set back in its own order.
        #expect(Set(view.registeredDraggedTypes.map(\.rawValue)) == Set(types.map(\.identifier)))
        #expect(view.hitTest(NSPoint(x: 50, y: 50)) == nil)
    }

    @Test("center tab split preview matches the final equal-width pane")
    func centerTabSplitPreviewSizing() {
        #expect(
            StudioCenterTabSplitPreviewSizing.newPaneWidth(
                totalWidth: 1_010,
                currentGroupCount: 1,
                dividerWidth: 10
            ) == 500
        )
        #expect(
            StudioCenterTabSplitPreviewSizing.newPaneWidth(
                totalWidth: 1_000,
                currentGroupCount: StudioCenterTabGroups.maximumGroupCount,
                dividerWidth: 10
            ) == 0
        )
    }

    @Test("a source drag leaves the pane under the pointer its own center band")
    func sourceEdgeSplitZonesLeaveACenterBand() {
        // The edge zones and the previews they draw read the same width, and
        // whatever they claim is what accepts the drop. Sized to the pane a
        // split would create, both zones together covered the whole center area
        // at one group, so a source dropped on Chat opened a Reader beside it
        // instead of joining the conversation.
        for totalWidth in [400, 720, 1_010, 1_600, 2_400].map(CGFloat.init) {
            let zone = StudioCenterTabSplitPreviewSizing.sourceEdgeZoneWidth(totalWidth: totalWidth)
            #expect(zone >= StudioCenterTabSplitPreviewSizing.minimumSourceEdgeZoneWidth)
            #expect(zone <= StudioCenterTabSplitPreviewSizing.maximumSourceEdgeZoneWidth)
            // Both gutters together stay well clear of the pane's own area.
            #expect(2 * zone < totalWidth * 0.5)
            // And they stay narrower than the pane a split would create, which
            // is the width the zones used to take.
            #expect(
                zone < StudioCenterTabSplitPreviewSizing.newPaneWidth(
                    totalWidth: totalWidth,
                    currentGroupCount: 1,
                    dividerWidth: 10
                )
            )
        }
    }

    @Test("a Docs or Sites row's drag keeps the edge split to a gutter like a source")
    func artifactDragKeepsEdgeSplitZonesToAGutter() {
        // A Docs or Sites row's drag names its pane as well as its record. Read
        // as a pane drag, the edge zone was sized to the pane it would move,
        // and with Sites already open beside Chat that was the whole chat pane:
        // a site dropped on the chat swapped the two panes instead of joining
        // the conversation. The record makes it content the pane takes itself.
        typealias Sizing = StudioCenterTabSplitPreviewSizing
        #expect(Sizing.dragCarriesPaneContent(
            draggedArticleCount: 0,
            draggedArtifactID: true, draggedSessionID: false, draggingTab: false
        ))
        // A source, as before.
        #expect(Sizing.dragCarriesPaneContent(
            draggedArticleCount: 1,
            draggedArtifactID: false, draggedSessionID: false, draggingTab: false
        ))
        // A bare pane drag has nowhere to land but the edge; a chat drag and a
        // tab-strip drag keep the full-width zone they always had.
        #expect(Sizing.dragCarriesPaneContent(
            draggedArticleCount: 0,
            draggedArtifactID: false, draggedSessionID: false, draggingTab: false
        ) == false)
        #expect(Sizing.dragCarriesPaneContent(
            draggedArticleCount: 0,
            draggedArtifactID: false, draggedSessionID: true, draggingTab: false
        ) == false)
        #expect(Sizing.dragCarriesPaneContent(
            draggedArticleCount: 1,
            draggedArtifactID: true, draggedSessionID: false, draggingTab: true
        ) == false)
    }

    @Test("split commands move both lone and grouped tabs")
    func centerGroupMoves() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .reader),
        ])
        // [chat] | [reader, tasks, notepad, notebooks]
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat])

        vm.moveCenterGroup(containing: .chat, by: 1)
        #expect(vm.centerTabGroups.groups[0].tabs == [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library])
        #expect(vm.centerTabGroups.groups[1].tabs == [.chat])

        vm.moveCenterGroup(containing: .chat, by: -1)
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat])

        // The user-facing Split commands slide a lone group instead of passing
        // an adjacent insertion index that resolves straight back to itself.
        vm.splitCenterTab(.chat, towardRight: true)
        #expect(vm.centerTabGroups.groups[1].tabs == [.chat])
        vm.splitCenterTab(.chat, towardRight: false)
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat])

        // Past either end is ignored rather than clamped onto a neighbor.
        let before = vm.centerTabGroups
        vm.splitCenterTab(.chat, towardRight: false)
        #expect(vm.centerTabGroups == before)

        // A grouped tab cannot create a third pane at capacity.
        let atCapacity = vm.centerTabGroups
        vm.splitCenterTab(.reader, towardRight: true)
        #expect(vm.centerTabGroups == atCapacity)

        // Far-edge drops still move a lone group without changing pane count.
        vm.moveCenterTabToNewGroup(.chat, at: vm.centerTabGroups.groups.count)
        #expect(vm.centerTabGroups.groups.last?.tabs == [.chat])
    }

    @Test("the divider swaps adjacent panes in its own window")
    func centerDividerSwapsDestinationWindowPanes() {
        let vm = makeViewModel()
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*", "reader|tasks*|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let sourceLayout = vm.centerTabGroups

        vm.swapCenterGroups(adjacentToDividerAt: 0, in: destination)

        #expect(vm.centerTabGroups == sourceLayout)
        #expect(destination.centerTabGroups.groups[0].activeTab == .tasks)
        #expect(destination.centerTabGroups.groups[1].activeTab == .chat)

        let swapped = destination.centerTabGroups
        vm.swapCenterGroups(adjacentToDividerAt: 1, in: destination)
        #expect(destination.centerTabGroups == swapped)
    }

    /// What made the swap control take seconds was never the model work — it is
    /// one `swapAt` — but SwiftUI rebuilding both panes because the columns were
    /// keyed by slot rather than by pane. A rebuilt reader recreates its web
    /// view and reloads the page over the network. So assert the thing the view
    /// keys on: a pane that survives an operation keeps its identity, and only
    /// its position changes.
    @Test("panes keep their identity across a swap and a reconciled write")
    func centerPaneIdentitiesSurviveSwapAndReconciliation() {
        let vm = makeViewModel()
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*", "reader|tasks*|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let chatPane = destination.centerTabGroups.groups[0].id
        let readerPane = destination.centerTabGroups.groups[1].id

        vm.swapCenterGroups(adjacentToDividerAt: 0, in: destination)

        #expect(destination.centerTabGroups.groups[0].id == readerPane)
        #expect(destination.centerTabGroups.groups[1].id == chatPane)

        // Reconciliation runs on every assignment, including the ones it has to
        // correct. Rebuilding groups there would hand both panes a new identity
        // on a write that only restored a dropped tab.
        var missingNotepad = destination.centerTabGroups
        missingNotepad.groups[0].tabs.removeAll { $0 == .notepad }
        destination.centerTabGroups = missingNotepad

        #expect(destination.centerTabGroups.groups.count == 2)
        #expect(destination.centerTabGroups.groups[0].id == readerPane)
        #expect(destination.centerTabGroups.groups[1].id == chatPane)
        #expect(Set(destination.centerTabGroups.groups.flatMap(\.tabs)) == Set(StudioCenterTab.permanentTabs))
    }

    /// Identity is a view-layer concern, so it must stay out of `==`. Every
    /// comparison around this type asks whether the arrangement changed, and
    /// `reconciled` builds a fresh value on each assignment — an identity that
    /// counted would make each of those look like a change.
    @Test("pane identity does not participate in layout equality")
    func centerPaneIdentityIsOutsideEquality() {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library], activeTab: .reader),
        ])
        let sameArrangement = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library], activeTab: .reader),
        ])

        #expect(layout == sameArrangement)
        #expect(layout.groups[0].id != sameArrangement.groups[0].id)
        #expect(StudioCenterTabGroups.reconciled(layout) == layout)
    }

    @Test("Chat can be revealed beside the active Reader")
    func revealChatBesideReader() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .reader),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups.count == 2)
        #expect(vm.centerTabGroups.groups[0].tabs == [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library])
        #expect(vm.centerTabGroups.groups[0].activeTab == .reader)
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.chat], activeTab: .chat))
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatFocusRequestID != nil)
        #expect(vm.readerChatSpaceRequestID != nil)

        // Chat already open to the Reader's left: both panes stay where the
        // learner put them, each with its tab brought forward. Selecting a
        // passage must never swap the two.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks], activeTab: .tasks),
            .init(tabs: [.reader, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups[0] == .init(tabs: [.chat, .tasks], activeTab: .chat))
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.reader, .notepad, .sites, .browser, .videos, .artifacts, .activity, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .reader))

        // Chat already open to the Reader's right stays there too.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader, .notepad, .sites], activeTab: .notepad),
            .init(tabs: [.chat, .tasks, .artifacts], activeTab: .artifacts),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups[0] == .init(tabs: [.reader, .notepad, .sites], activeTab: .reader))
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.chat, .tasks, .artifacts, .activity, .goals, .courses, .ideas, .browser, .videos, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .chat))
    }

    @Test("Navigation destinations can open beside the visible pane")
    func openCenterTabBeside() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.openCenterTabBeside(.notepad)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .chat),
            .init(tabs: [.notepad], activeTab: .notepad),
        ])

        // Repeating the command focuses the existing pane without moving it.
        let openLayout = vm.centerTabGroups
        vm.openCenterTabBeside(.notepad)
        #expect(vm.centerTabGroups == openLayout)

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
        ])
        vm.openCenterTabBeside(.artifacts)
        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.maximumGroupCount)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .artifacts])
    }

    @Test("A second kind of the Docs tab opens beside the first, never over it")
    func artifactKindOpensBesideAnother() {
        // The product owner, 2026-09-29: "make sure we can also open 2 different
        // artifact panes side by side; e.g. docs and ideas".
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        // Ideas parked behind Docs takes Chat's pane; Docs stays.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader], activeTab: .chat),
            .init(tabs: [.notepad, .ideas, .artifacts], activeTab: .notepad),
        ])
        vm.openArtifactKindBeside(.ideas)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.ideas, .notepad])

        // Asked from the Docs tab with Docs beside it, the other kind is
        // what stays: the tab gives way.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.notepad, .chat], activeTab: .notepad),
            .init(tabs: [.artifacts, .ideas, .reader], activeTab: .artifacts),
        ])
        vm.openArtifactKindBeside(.ideas)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .ideas])

        // Again, with the kind already on screen, nothing moves.
        let sideBySide = vm.centerTabGroups
        vm.openArtifactKindBeside(.ideas)
        #expect(vm.centerTabGroups == sideBySide)

        // With the tab the only one of its panes on screen, the tab stays.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader], activeTab: .chat),
            .init(tabs: [.artifacts, .notepad], activeTab: .artifacts),
        ])
        vm.openArtifactKindBeside(.notepad)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .artifacts])

        // With none on screen, it opens beside as a rail row does.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .sites], activeTab: .chat),
        ])
        vm.openArtifactKindBeside(.sites)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .sites])

        // A Reader pinned on a paper is never covered: Ideas, parked behind
        // it, peels into a third pane beside Docs.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader, .ideas], activeTab: .reader, isPinned: true),
            .init(tabs: [.notepad, .chat], activeTab: .notepad),
        ])
        vm.openArtifactKindBeside(.ideas)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .notepad, .ideas])
        #expect(vm.centerTabGroups.groups[0].isPinned)
    }

    @Test("The Space's sidebar opens Pages and Sites each in its own pane")
    func artifactKindsMatchTheirPanes() {
        // The product owner, 2026-10-06: "perhaps docs and sites can be. the other
        // things are more one off per notebook" — the one-off kinds are
        // listed in their notebook's Studio. Ideas left the sidebar on
        // 2026-10-10 for the chat; their pane still opens beside a Doc whose
        // idea link is followed, so it stays one of the kinds' panes.
        #expect(ArtifactsHomeKind.allCases == [.docs, .sites])
        #expect(Set(ArtifactsHomeKind.allCases.map(\.centerTab)) == StudioCenterTab.artifactKinds.subtracting([.ideas]))
        #expect(StudioCenterTab.artifactKinds.contains(.ideas))
        #expect(ArtifactsHomeKind.docs.otherWindowDestination == .docs)
        #expect(ArtifactsHomeKind.sites.otherWindowDestination == .sites)
    }

    @Test("workspace destinations replace a pane after the two-pane cap")
    func coreWorkspaceCombination() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.openCenterTabBeside(.notepad)
        vm.openCenterTabBeside(.artifacts)

        // Chat, Docs, and Notebooks are the core destinations: with both panes
        // already showing one, a third opens in place rather than splitting.
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .notepad])
        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.maximumGroupCount)

        vm.placeCenterTabAtEdge(.artifacts, leading: true)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .notepad])

        vm.placeCenterTabAtEdge(.notepad, leading: false)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .notepad])
        #expect(vm.centerTabGroups.groups.count == 2)
    }

    @Test("A dragged chat creates a transient independent pane at either edge")
    func secondaryChatPanePlacement() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.openSecondaryChatPane(atLeadingEdge: false)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .secondaryChat])
        #expect(!vm.centerTabGroups.persistedRepresentation.joined().contains("secondaryChat"))
        #expect(
            StudioCenterTabGroups.fromPersisted(["secondaryChat*", "chat*"])?
                .groups.flatMap(\.tabs).contains(.secondaryChat) == false
        )

        vm.openSecondaryChatPane(atLeadingEdge: true)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.secondaryChat, .chat])

        vm.dismissSecondaryChatPane()
        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(!vm.centerTabGroups.groups[0].tabs.contains(.secondaryChat))

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
        ])
        vm.openSecondaryChatPane(atLeadingEdge: false)
        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.maximumGroupCount)
        #expect(vm.centerTabGroups.groups.last?.activeTab == .secondaryChat)
        #expect(vm.centerTabGroups.groups.last?.tabs.contains(.artifacts) == true)
    }

    @Test("Docs scoped to a Notebook open beside what is on screen, and the rail's Docs row clears the scope")
    func notebookArtifactsOpenBeside() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.openArtifactsBeside(notebookID: "notebook-1")

        #expect(vm.artifactCanvasNotebookID == "notebook-1")
        #expect(vm.activeWindowState.artifactCanvasNotebookID == "notebook-1", "the scope is the window's")
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library], activeTab: .artifacts),
            .init(tabs: [.notepad], activeTab: .notepad),
        ])

        vm.openNotepadInReader()
        #expect(vm.artifactCanvasNotebookID == nil)
        #expect(vm.activeCenterTabs.contains(.notepad))
        // The rail's Docs row lands on the index of every doc, and does so
        // on every click, not only when the pane was closed.
        let firstIndexRequest = vm.artifactIndexRequest
        #expect(firstIndexRequest != nil)
        vm.openNotepadInReader()
        #expect(vm.artifactIndexRequest != nil)
        #expect(vm.artifactIndexRequest != firstIndexRequest)
        // A doc reached from a chat opens itself; it does not ask for the index.
        vm.artifactIndexRequest = nil
        vm.revealArtifact("doc-1")
        #expect(vm.artifactIndexRequest == nil)
        #expect(vm.artifactRevealRequest?.artifactID == "doc-1")
        vm.artifactRevealRequest = nil

        // Docs already on screen stay where they are: the Notebook page that
        // placed them right of itself went with the notebook's Studio.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.notepad], activeTab: .notepad),
            .init(tabs: [.chat, .reader, .tasks, .artifacts], activeTab: .artifacts),
        ])
        vm.openArtifactsBeside(notebookID: "notebook-2")
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .artifacts])
        #expect(vm.artifactCanvasNotebookID == "notebook-2")

        // At the cap, Docs open in the pane they are parked in, as a rail
        // row's Open Beside does.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.openArtifactsBeside(notebookID: "notebook-3")
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .notepad])
    }

    @Test("Reader selection opens Chat to Reader's right")
    func readerSelectionOpensSplitChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .reader),
        ])
        vm.requestReaderSelectionExplanation(sourceID: "selected-source", selectedText: "  selected passage  ")

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat])
        #expect(vm.readerSelectionExplanationRequest?.sourceIDs == ["selected-source"])
        #expect(vm.readerSelectionExplanationRequest?.selectedText == "selected passage")
        #expect(vm.readerChatSpaceRequestID != nil)
    }

    @Test("Notepad chat names the section the writer is standing in")
    func notepadChatCarriesSectionTitle() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.requestNotepadChat(
            noteTitle: "Mitochondria",
            sectionTitle: "How do people picture energy?",
            selectedText: "the paragraph under that heading",
            sourceIDs: ["source-a"],
            artifactID: "artifact-a",
            artifactRevision: "revision-a",
            artifactNotebookID: nil,
            selectionRange: nil,
            contextExcerpt: nil
        )

        #expect(
            vm.readerSelectionExplanationRequest?.contextTitle
                == "Note: Mitochondria — How do people picture energy?"
        )
    }

    @Test("A chat opening a figure's paper beside itself refuses a source the library has not loaded, and leaves the panes alone")
    func openSourceBesideChatNeedsALoadedSource() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let window = vm.activeWindowState
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks], activeTab: .chat),
        ])
        let before = window.centerTabGroups
        #expect(await vm.openSourceBesideChat("src-not-loaded", beside: .chat, in: window) == false)
        #expect(window.centerTabGroups == before)
    }

    @Test("Reader can be revealed beside Chat without replacing the conversation")
    func revealReaderBesideChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.revealReaderBesideChat()
        #expect(vm.centerTabGroups.groups.count == 2)
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library])
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.reader], activeTab: .reader))

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks], activeTab: .tasks),
            .init(tabs: [.reader, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.revealReaderBesideChat()
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)
        #expect(vm.centerTabGroups.groups[1].activeTab == .reader)
    }

    @Test("A citation opens the Reader beside Chat without covering a pinned pane")
    func revealReaderLeavesAPinnedPane() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.notepad, .reader, .tasks], activeTab: .notepad, isPinned: true),
        ])
        vm.revealReaderBesideChat()

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader, .notepad])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [false, false, true])
    }

    @Test("A passage opens Chat beside the Reader without covering a pinned pane, and takes one's pin only when there is no room")
    func revealChatLeavesAPinnedPane() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader], activeTab: .reader, isPinned: true),
            .init(tabs: [.notepad, .chat, .tasks], activeTab: .notepad, isPinned: true),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat, .notepad])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [true, false, true])

        // Three pinned panes: the chat still comes on screen, in the pane it
        // was parked in, and that pane stops claiming to be pinned.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader], activeTab: .reader, isPinned: true),
            .init(tabs: [.notepad, .chat], activeTab: .notepad, isPinned: true),
            .init(tabs: [.tasks], activeTab: .tasks, isPinned: true),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat, .tasks])
        #expect(vm.centerTabGroups.groups.map(\.isPinned) == [true, false, true])
    }

    @Test("opening a Chat citation opens the Reader beside the chat")
    func linkedSourceOpensReaderBesideChat() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        var source = makeArticle(
            url: "https://example.com/cited-source",
            title: "Cited Source",
            state: .ready,
            id: "cited-source"
        )
        source.content = "Already loaded."
        vm.articles = [source]
        vm.centerTabGroups = .defaultLayout

        await vm.openLinkedSourceInReader(source.id)

        #expect(vm.selectedArticleId == source.id)
        #expect(vm.activeCenterTabs.contains(.chat))
        #expect(vm.activeCenterTabs.contains(.reader))
    }

    @Test("A source opened from a doc keeps the doc beside the Reader")
    func linkedSourceFromDocKeepsNotepadVisible() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        var source = makeArticle(
            url: "https://example.com/doc-source",
            title: "Doc Source",
            state: .ready,
            id: "doc-source"
        )
        source.content = "Already loaded."
        vm.articles = [source]

        // The workspace a learner writing in Docs is looking at after closing
        // the chat pane: every tab merged into one group, Docs showing.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
        ])

        await vm.openLinkedSourceInReader(source.id, beside: .notepad)

        #expect(vm.selectedArticleId == source.id)
        #expect(vm.activeCenterTabs.contains(.notepad))
        #expect(vm.activeCenterTabs.contains(.reader))
        // Following a doc's source chip is not a request to open the chat.
        #expect(!vm.activeCenterTabs.contains(.chat))
    }

    @Test("A source opened from a Site keeps the Site beside the Reader")
    func linkedSourceFromSiteKeepsSitesVisible() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        var source = makeArticle(
            url: "https://example.com/site-source",
            title: "Site Source",
            state: .ready,
            id: "site-source"
        )
        source.content = "Already loaded."
        vm.articles = [source]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .sites
            ),
        ])

        await vm.openLinkedSourceInReader(source.id, beside: .sites)

        #expect(vm.selectedArticleId == source.id)
        #expect(vm.activeCenterTabs.contains(.sites))
        #expect(vm.activeCenterTabs.contains(.reader))
        #expect(!vm.activeCenterTabs.contains(.chat))
    }

    @Test("selecting a source brings Reader forward over the Space")
    func selectingSourceActivatesReaderTab() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        vm.showSpaceAll()

        await vm.selectArticle("book-chapter")

        #expect(vm.selectedArticleId == "book-chapter")
        #expect(vm.showReaderPanel)
        #expect(vm.activeCenterTabs.contains(.reader))
        #expect(!vm.activeCenterTabs.contains(.artifacts))
    }

    @Test("scheduling a source into a Notebook adds it to the pool and week")
    func notebookScheduleDropAddsSourceToPoolAndWeek() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookScheduleDropTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4))!
        let wednesday = calendar.date(byAdding: .day, value: 2, to: monday)!
        var source = makeArticle(
            url: "https://example.com/notebook-source",
            title: "Notebook Source",
            state: .ready
        )
        source.content = "Durable notebook source text."
        try await service.saveSource(source)
        vm.articles = [source]
        let goal = try await service.createCompanionGoal(
            title: "Learning Notebook",
            topic: "Learning Notebook",
            startAt: monday,
            endAt: calendar.date(byAdding: .day, value: 30, to: monday)!,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        vm.activeNotebookId = goal.id
        await vm.loadLearningGoals()

        await vm.addSourcesToNotebookSchedule(goalID: goal.id, sourceIDs: [source.id], plannedFor: wednesday)

        let updatedGoal = try #require(vm.notebook(id: goal.id))
        #expect(updatedGoal.approvedSourceIDs == [source.id])
        let weekDays = vm.scheduleDays(for: updatedGoal, containing: monday)
        let wednesdaySourceIDs = weekDays.first {
            calendar.isDate($0.date, inSameDayAs: wednesday)
        }?.items.map(\.sourceID)
        #expect(wednesdaySourceIDs == [source.id])
    }
}

// MARK: - Source Reloads

@Suite("Source Reloads")
@MainActor
struct SourceReloadTests {

    @Test("refreshArticles preserves loaded transcript content")
    func refreshArticlesPreservesLoadedTranscriptContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMReloadTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        var stored = makeArticle(
            url: "apple-podcast://episode/1000751939405",
            title: "Podcast Episode",
            sourceType: .podcast,
            state: .ready,
            discoveryOrigin: .applePodcasts
        )
        stored.domain = "Example Podcast"
        stored.content = "Stored transcript text."
        stored.wordCount = 3
        try await service.saveSource(stored)

        var opened = stored
        opened.content = "This transcript was already loaded in the reader."
        opened.wordCount = 8
        vm.articles = [opened]

        await vm.refreshArticles()

        #expect(vm.articles.first?.content == opened.content)
        #expect(vm.articles.first?.wordCount == opened.wordCount)
    }
}

// MARK: - Podcast Transcript Hydration

@Suite("Podcast Transcript Formatting Annotations")
struct PodcastTranscriptFormattingAnnotationTests {

    @Test("ad-read annotations remove only the exact sponsored span")
    func removesExactAdReadSpan() {
        let transcript = """
        [SPEAKER_1]
        Welcome to the show. Today we are tracing how cells turn nutrients into usable energy and why that process changes under stress. This episode is brought to you by Accenture. Accenture helps businesses reinvent how they work. Visit accenture.com to learn more. Now let's discuss how cells generate energy, how mitochondria respond to demand, and what the experimental evidence actually shows.
        """
        let response = """
        [
          {"after":"Welcome to the show.","speaker":"Host"},
          {
            "ad_start":"This episode is brought to you by Accenture.",
            "ad_end":"Visit accenture.com to learn more."
          }
        ]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(!formatted.contains("brought to you by Accenture"))
        #expect(!formatted.contains("accenture.com"))
        // The transcript names its speaker on a label line, so the break goes
        // in and the model's speaker does not.
        #expect(formatted.contains("Welcome to the show.\n\n Today we are tracing"))
        #expect(!formatted.contains("**Host:**"))
        #expect(formatted.contains("Now let's discuss how cells generate energy,"))
    }

    @Test("a diarized transcript keeps its own speaker lines: no marker above a label, no blank-line runs")
    func diarizedTranscriptTakesBreaksWithoutSpeakers() {
        let transcript = """
        [Ada Lovelace]
        The engine weaves algebraic patterns. It could compose music of any complexity.

        [Charles Babbage]
        That was never my intention for the machine.
        """
        // The shapes stored transcripts showed on 2026-10-06: a speaker break
        // right before the next turn's label (a `**Name:**` above `[Name]`),
        // the same break twice (blank lines stacked), and a speaker mid-turn
        // that the label lines contradict.
        let response = """
        [
          {"after":"music of any complexity.","speaker":"Charles Babbage"},
          {"after":"music of any complexity."},
          {"after":"weaves algebraic patterns.","speaker":"Charles Babbage"}
        ]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == """
        [Ada Lovelace]
        The engine weaves algebraic patterns.

         It could compose music of any complexity.

        [Charles Babbage]
        That was never my intention for the machine.
        """)
        // A chunk inside one long turn holds no label line; the caller says
        // the transcript is diarized, and the speaker is still left out.
        let insideATurn = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: "The engine weaves algebraic patterns. It could compose music of any complexity.",
            from: #"[{"after":"weaves algebraic patterns.","speaker":"Charles Babbage"}]"#,
            transcriptIsDiarized: true
        )
        #expect(insideATurn == "The engine weaves algebraic patterns.\n\n It could compose music of any complexity.")
    }

    @Test("a break where the text already breaks adds nothing, and a speaker named there opens the next paragraph")
    func existingBreaksAreNotStacked() {
        // Where an ad was taken out, the text already breaks.
        let diarized = "[SPEAKER_1]\nWe start with the question of energy. This episode is brought to you by Example Corp, the makers of examples. Visit example.com today for a discount. Now back to the mitochondria and the membrane potential they hold across the inner membrane. It is the potential the dyes in these experiments read, and it falls when the cell is stressed."
        let afterAd = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: diarized,
            from: """
            [{"ad_start":"This episode is brought to you by Example Corp,","ad_end":"Visit example.com today for a discount."},
             {"after":"the question of energy."}]
            """
        )
        #expect(afterAd == "[SPEAKER_1]\nWe start with the question of energy.\n\nNow back to the mitochondria and the membrane potential they hold across the inner membrane. It is the potential the dyes in these experiments read, and it falls when the cell is stressed.")

        // A transcript with no speaker lines keeps the model's speakers, and
        // one named at an existing break opens the paragraph after it.
        let plain = "The host finishes the introduction.\n\nThe guest begins the explanation. And goes on at length."
        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: plain,
            from: """
            [{"after":"finishes the introduction.","speaker":"Guest"},
             {"after":"begins the explanation.","speaker":"Host"}]
            """
        )
        #expect(formatted == "The host finishes the introduction.\n\n**Guest:** The guest begins the explanation.\n\n**Host:**  And goes on at length.")
        #expect(!formatted.contains("\n\n\n"))
    }

    @Test("ambiguous ad boundaries preserve the transcript")
    func ambiguousBoundaryIsNotDeleted() {
        let transcript = """
        This episode is brought to you by Example. First editorial section.
        This episode is brought to you by Example. Second editorial section.
        """
        let response = """
        [{
          "ad_start":"This episode is brought to you by Example.",
          "ad_end":"Second editorial section."
        }]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == transcript)
    }

    @Test("over-broad ad annotations cannot erase most of a transcript")
    func overBroadRemovalIsRejected() {
        let transcript = "Opening editorial sentence. "
            + String(repeating: "sponsored message ", count: 80)
            + "Closing editorial sentence."
        let response = """
        [{
          "ad_start":"Opening editorial sentence.",
          "ad_end":"Closing editorial sentence."
        }]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == transcript)
    }

    @Test("legacy breakpoint-only responses remain supported")
    func legacyBreakPointResponseStillWorks() {
        let transcript = "The host finishes the introduction. The guest begins the explanation."
        let response = """
        ```json
        [{"after":"The host finishes the introduction.","speaker":"Guest"}]
        ```
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == "The host finishes the introduction.\n\n**Guest:**  The guest begins the explanation.")
    }
}

/// A value a `@Sendable` closure can record into from any thread.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mutate(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}

@Suite("Podcast Transcript Hydration")
@MainActor
struct PodcastTranscriptHydrationCandidateTests {

    private func makeEpisode(id: String, show: String) -> StudioArticle {
        var article = makeArticle(
            url: "apple-podcast://episode/1000751939405",
            title: "Episode \(id)",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: id
        )
        article.domain = show
        return article
    }

    @Test("visible episodes allow transcript formatting")
    func visibleEpisodeAllowsFormatting() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "visible", show: "Example Podcast")]

        let candidate = vm.podcastHydrationCandidate(for: "visible")
        #expect(candidate?.allowsFormatting == true)
    }

    @Test("episodes on a hidden show skip transcript formatting")
    func hiddenShowSkipsFormatting() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "hidden-show", show: "Example Podcast")]
        vm.hiddenPodcastShows = ["Example Podcast"]

        let candidate = vm.podcastHydrationCandidate(for: "hidden-show")
        #expect(candidate?.allowsFormatting == false)
    }

    @Test("individually hidden episodes skip transcript formatting")
    func hiddenEpisodeSkipsFormatting() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "hidden-episode", show: "Example Podcast")]
        vm.hiddenPodcastEpisodeIDs = ["hidden-episode"]

        let candidate = vm.podcastHydrationCandidate(for: "hidden-episode")
        #expect(candidate?.allowsFormatting == false)
    }

    @Test("a visible episode on a hidden show still formats")
    func visibleOverrideOnHiddenShowFormats() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "override", show: "Example Podcast")]
        vm.hiddenPodcastShows = ["Example Podcast"]
        vm.visiblePodcastEpisodeOverrideIDs = ["override"]

        let candidate = vm.podcastHydrationCandidate(for: "override")
        #expect(candidate?.allowsFormatting == true)
    }

    @Test("a show hidden while a bulk drain waits stops formatting its queued episodes")
    func showHiddenMidDrainSkipsFormattingAtDispatch() throws {
        let vm = makeViewModel()
        vm.articles = [
            makeEpisode(id: "queued", show: "Example Podcast"),
            makeEpisode(id: "other", show: "Other Podcast"),
        ]
        let queued = try #require(vm.podcastHydrationCandidate(for: "queued"))
        let other = try #require(vm.podcastHydrationCandidate(for: "other"))
        #expect(queued.allowsFormatting)

        vm.hiddenPodcastShows = ["Example Podcast"]

        #expect(vm.bulkHydrationCandidateAtDispatch(queued).allowsFormatting == false)
        #expect(vm.bulkHydrationCandidateAtDispatch(other).allowsFormatting)
    }

    @Test("a show hidden in the installed library is never formatted automatically by a Dev build")
    func installedLibraryHiddenShowSkipsFormatting() {
        let vm = makeViewModel()
        let hiddenThere = makeEpisode(id: "hidden-there", show: "TBPN")
        let override = makeEpisode(id: "override", show: "TBPN")
        let visible = makeEpisode(id: "visible", show: "Example Podcast")
        vm.articles = [hiddenThere, override, visible]
        vm.visiblePodcastEpisodeOverrideIDs = [override.id]
        let installed: Set<String> = ["TBPN"]

        #expect(!vm.allowsTranscriptFormatting(
            for: hiddenThere, userInitiated: false, installedLibraryHiddenShows: installed
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: hiddenThere, userInitiated: true, installedLibraryHiddenShows: installed
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: override, userInitiated: false, installedLibraryHiddenShows: installed
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: visible, userInitiated: false, installedLibraryHiddenShows: installed
        ))
        // The Dev library still lists the episode as a stranger would see it.
        #expect(!vm.isSourceHidden(hiddenThere))
    }

    @Test("the installed library's hidden shows are read only by a Dev build")
    func installedLibraryHiddenShowsLoad() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            CREATE TABLE hidden_podcast_shows (show_name TEXT PRIMARY KEY, hidden_at REAL NOT NULL);
            INSERT INTO hidden_podcast_shows VALUES ('TBPN', 0), ('All-In', 0);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(InstalledLibraryHiddenPodcastShows.load(isDevelopment: true, databaseURL: url)
            == ["TBPN", "All-In"])
        #expect(InstalledLibraryHiddenPodcastShows.load(isDevelopment: false, databaseURL: url)
            .isEmpty)
        #expect(InstalledLibraryHiddenPodcastShows.load(
            isDevelopment: true,
            databaseURL: folder.appendingPathComponent("missing.db")
        ).isEmpty)
    }

    @Test("automatic podcast work excludes hidden episodes but honors a visible override")
    func automaticPodcastWorkExcludesHiddenSources() {
        let vm = makeViewModel()
        let visible = makeEpisode(id: "visible", show: "Visible Show")
        let hiddenShow = makeEpisode(id: "hidden-show", show: "Hidden Show")
        var hiddenEpisode = makeEpisode(id: "hidden-episode", show: "Visible Show")
        hiddenEpisode.isHidden = true
        let override = makeEpisode(id: "override", show: "Hidden Show")
        var staleCached = makeEpisode(id: "stale-cached", show: "Visible Show")
        staleCached.content = "Already stored transcript"
        vm.articles = [visible, hiddenShow, hiddenEpisode, override, staleCached]
        vm.hiddenPodcastShows = ["Hidden Show"]
        vm.hiddenPodcastEpisodeIDs = [hiddenEpisode.id]
        vm.visiblePodcastEpisodeOverrideIDs = [override.id]

        #expect(
            vm.pendingAutomaticPodcastTranscriptArticles().map(\.id)
                == [visible.id, override.id, staleCached.id]
        )
    }

    @Test("stored podcast transcripts are repaired before slow transcript fetches")
    func storedPodcastTranscriptsTakeQueuePriority() {
        let firstSlow = makeEpisode(id: "first-slow", show: "Example Podcast")
        let cached = makeEpisode(id: "cached", show: "Example Podcast")
        let secondSlow = makeEpisode(id: "second-slow", show: "Example Podcast")

        #expect(
            StudioViewModel.prioritizedPodcastTranscriptIDs(
                [firstSlow, cached, secondSlow],
                storedContentLengths: [cached.id: 42_000]
            ) == [cached.id, firstSlow.id, secondSlow.id]
        )
    }

    @Test("a library reload preserves the active podcast transcript state")
    func reloadPreservesActivePodcastState() {
        var active = makeEpisode(id: "active", show: "Example Podcast")
        active.state = .fetching
        var reloaded = active
        reloaded.state = .queued

        let merged = StudioViewModel.preservingLoadedContent(
            in: [reloaded],
            preservingFrom: [active]
        )

        #expect(merged.first?.state == .fetching)
    }

    @Test("user-confirmed hydration formats even on a hidden show")
    func userInitiatedOverridesHidden() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "confirmed", show: "Example Podcast")]
        vm.hiddenPodcastShows = ["Example Podcast"]

        let candidate = vm.podcastHydrationCandidate(for: "confirmed", userInitiated: true)
        #expect(candidate?.allowsFormatting == true)
    }

    @Test("a show-level YouTube preference reaches transcript hydration")
    func youtubePreferenceReachesHydration() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "youtube-show", show: "Mind & Matter")]
        vm.podcastYouTubeFallbackShows = ["mind & matter"]

        let candidate = vm.podcastHydrationCandidate(for: "youtube-show")
        #expect(candidate?.prefersYouTube == true)

        let audioOptIn = vm.podcastHydrationCandidate(
            for: "youtube-show",
            userInitiated: true,
            honorYouTubePreference: false
        )
        #expect(audioOptIn?.prefersYouTube == false)
    }

    @Test("Apple transcript HTTP status distinguishes unavailable access from retryable failures")
    func transcriptHTTPStatusClassification() {
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 200) == .success)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 401) == .authenticationExpired)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 403) == .failed)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 404) == .unavailable)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 429) == .failed)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 503) == .failed)
    }

    @Test("only terminal transcript errors suppress retries")
    func terminalTranscriptErrors() {
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.noPodcastTranscriptMessage))
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.unavailablePodcastTranscriptMessage))
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.podcastAudioTranscriptionMessage))
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.youtubePreferredPodcastTranscriptMessage))
        #expect(!StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.retryablePodcastTranscriptMessage))
        #expect(!StudioViewModel.isTerminalPodcastTranscriptError(nil))
        #expect(StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.noPodcastTranscriptMessage))
        #expect(StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.unavailablePodcastTranscriptMessage))
        #expect(StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.podcastAudioTranscriptionMessage))
        #expect(!StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.retryablePodcastTranscriptMessage))
        #expect(!StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.youtubePreferredPodcastTranscriptMessage))
    }

    @Test("missing Apple TTML does not transcribe audio without opt-in")
    func missingAppleTranscriptRequiresAudioOptIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAudioOptInTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "audio-opt-in-required", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in .unavailable },
            resolveEpisodeAudioURL: { _, _, _ in
                Issue.record("Automatic hydration tried to resolve episode audio.")
                return URL(string: "https://example.com/episode.mp3")
            },
            transcribeEpisodeAudio: { _ in
                Issue.record("Automatic hydration started paid audio transcription.")
                return "This must not be used."
            }
        )

        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.unavailablePodcastTranscriptMessage)
        case .ready:
            Issue.record("Audio transcription ran without explicit opt-in.")
        }
        #expect(await storage.loadSourceContent(episode.id) == nil)
    }

    @Test("explicit opt-in transcribes exact episode audio")
    func optedInMissingAppleTranscriptUsesEpisodeAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAudioFallbackTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "audio-fallback", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            allowAudioTranscription: true,
            fetchAppleTranscript: { _, _ in .unavailable },
            resolveEpisodeAudioURL: { _, _, _ in URL(string: "https://example.com/episode.mp3") },
            transcribeEpisodeAudio: { _ in "Transcript produced from the exact episode audio." }
        )

        switch result.outcome {
        case .ready(let content, let persistedReadyState):
            #expect(content == "Transcript produced from the exact episode audio.")
            #expect(persistedReadyState)
        case .failed(let message):
            Issue.record("Expected audio fallback to succeed, got: \(message)")
        }
        #expect(await storage.loadSourceContent(episode.id) == "Transcript produced from the exact episode audio.")
    }

    @Test("retryable Apple transcript failures never start paid audio transcription")
    func retryableAppleTranscriptFailureDoesNotUseAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAppleRetryTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "apple-retry", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            allowAudioTranscription: true,
            fetchAppleTranscript: { _, _ in .failed },
            resolveEpisodeAudioURL: { _, _, _ in URL(string: "https://example.com/episode.mp3") },
            transcribeEpisodeAudio: { _ in "This must not be used." }
        )

        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.retryablePodcastTranscriptMessage)
        case .ready:
            Issue.record("A retryable Apple failure incorrectly started paid audio transcription.")
        }
        #expect(await storage.loadSourceContent(episode.id) == nil)
    }

    @Test("a show set to find YouTube leaves an episode that already has its transcript alone")
    func youtubePreferenceKeepsStoredTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastYouTubePreferenceTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "youtube-preferred-done", show: "Example Podcast")
        try await storage.saveSource(episode)
        try await storage.savePodcastYouTubeTranscript(
            episode.id,
            "Transcript taken from the confirmed YouTube upload.",
            youtubeURL: "https://www.youtube.com/watch?v=abc123"
        )
        vm.articles = [episode]
        let base = try #require(vm.podcastHydrationCandidate(for: episode.id))
        let candidate = StudioViewModel.PodcastTranscriptHydrationCandidate(
            id: base.id,
            url: base.url,
            title: base.title,
            podcastName: base.podcastName,
            webPageURL: base.webPageURL,
            prefersYouTube: true,
            allowsFormatting: base.allowsFormatting
        )

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("A finished episode asked Apple for its transcript again.")
                return .unavailable
            }
        )

        switch result.outcome {
        case .ready(let content, _):
            #expect(content == "Transcript taken from the confirmed YouTube upload.")
        case .failed(let message):
            Issue.record("A finished episode was sent back to find YouTube: \(message)")
        }
    }

    // MARK: - Rows without a public identity

    private static let privateFeedName = "The Peter Attia Drive - Private Subscriber Feed (🔓 for Robin Vale)"

    private static let publicTwin = PodcastPublicEpisode(
        trackID: 1000415911177,
        title: "Dom D'Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
        episodeNumber: 5,
        webPageURL: "https://peterattiamd.com/domdagostino/"
    )

    private static let appleTTML = """
    <tt xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
      <body><div>
        <p begin='0.0' end='1.0' ttm:agent='SPEAKER_1'>Dom, welcome to the show.</p>
        <p begin='1.0' end='2.0' ttm:agent='SPEAKER_2'>Thanks for having me, Peter.</p>
      </div></body>
    </tt>
    """

    /// The reported shape: an episode a named private feed filed under its web
    /// page, holding the page as content. Rows like it hydrate now — the row
    /// is eligible, its page text is not content, and the public twin's Apple
    /// transcript replaces it under the public identity.
    private func makeWebPageEpisode(id: String, show: String = privateFeedName) -> StudioArticle {
        var article = makeArticle(
            url: "https://peterattiamd.com/domdagostino/",
            title: "#05 – Dom D’Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
            sourceType: .podcast,
            discoveryOrigin: .manual,
            id: id
        )
        article.domain = show
        return article
    }

    @Test("a web-page row from a named feed is eligible, a pasted page is not")
    func webPageRowEligibility() {
        let vm = makeViewModel()
        let fromFeed = makeWebPageEpisode(id: "feed-page")
        var pasted = makeWebPageEpisode(id: "pasted-page")
        pasted.domain = "peterattiamd.com"
        vm.articles = [fromFeed, pasted]

        #expect(vm.podcastHydrationCandidate(for: "feed-page")?.url == fromFeed.url)
        #expect(vm.podcastHydrationCandidate(for: "pasted-page") == nil)
        #expect(vm.pendingAutomaticPodcastTranscriptArticles().map(\.id) == ["feed-page"])
    }

    @Test("a web-page row resolves to its public twin, takes its identity, and gets Apple's transcript")
    func webPageRowResolvesToPublicEpisode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPublicIdentityTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var episode = makeWebPageEpisode(id: "page-row")
        try await storage.saveSource(episode)
        // The page text an older build wrote is what this repairs.
        try await storage.saveTranscript(episode.id, "# Topics Discussed\n- Dom's early training [7:00]")
        episode.state = .queued
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let fetchedTrackIDs = LockedBox<[Int64]>([])
        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { trackID, _ in
                fetchedTrackIDs.mutate { $0.append(trackID) }
                return .available(Self.appleTTML)
            },
            resolvePublicEpisode: { showName, title, _ in
                #expect(showName == Self.privateFeedName)
                #expect(title.hasPrefix("#05"))
                return .matched(Self.publicTwin, showName: "The Peter Attia Drive")
            }
        )

        #expect(fetchedTrackIDs.value == [1000415911177])
        #expect(result.resolvedIdentity == StudioViewModel.PodcastResolvedEpisodeIdentity(
            url: "apple-podcast://episode/1000415911177",
            webPageURL: "https://peterattiamd.com/domdagostino/"
        ))
        switch result.outcome {
        case .ready(let content, _):
            #expect(content.contains("Dom, welcome to the show."))
            #expect(!content.contains("Topics Discussed"))
        case .failed(let message):
            Issue.record("Expected the public twin's transcript, got: \(message)")
        }

        await vm.applyPodcastHydrationResult(result)
        let inMemory = try #require(vm.articles.first(where: { $0.id == episode.id }))
        #expect(inMemory.url == "apple-podcast://episode/1000415911177")
        #expect(inMemory.podcastWebPageURL == "https://peterattiamd.com/domdagostino/")
        #expect(inMemory.state == .ready)

        let stored = try #require(try await storage.loadActiveSources().first(where: { $0.id == episode.id }))
        #expect(stored.url == "apple-podcast://episode/1000415911177")
        #expect(stored.podcastWebPageURL == "https://peterattiamd.com/domdagostino/")
        #expect(stored.state == .ready)
        #expect(await storage.loadSourceContent(episode.id)?.contains("Thanks for having me, Peter.") == true)
        #expect(try await storage.loadPodcastRawTTML(episode.id) == Self.appleTTML)
    }

    @Test("page text under a web-page address is never returned as the episode's content")
    func webPageTextIsNotContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPageTextTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var episode = makeWebPageEpisode(id: "notes-only")
        try await storage.saveSource(episode)
        try await storage.saveTranscript(episode.id, "# Show Notes\nA page, not a transcript.")
        episode.state = .queued
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("No public twin, so Apple must not be asked.")
                return .unavailable
            },
            resolvePublicEpisode: { _, _, _ in .noMatchingEpisode }
        )

        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.noPublicPodcastEpisodeMessage)
            #expect(StudioViewModel.isTerminalPodcastTranscriptError(message))
            #expect(StudioViewModel.canOptInToPodcastAudioTranscription(message))
        case .ready:
            Issue.record("Show notes were returned as a podcast's content.")
        }
        #expect(result.resolvedIdentity == nil)
    }

    @Test("a private-feed placeholder with no public twin keeps the audio opt-in route")
    func privatePlaceholderWithoutTwin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPrivateTwinTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var episode = makeArticle(
            url: "apple-podcast://episode/private/6566f059f9b527e0ebe15c8679582a61b6567c869842f161a67fac68ac4746b6",
            title: "#400 ‒ AMA #87: Environmental pollution and longevity",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "private-row"
        )
        episode.domain = Self.privateFeedName
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let automatic = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("A private placeholder has no track id to ask Apple about.")
                return .unavailable
            },
            resolvePublicEpisode: { _, _, _ in .noMatchingEpisode }
        )
        switch automatic.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.noPublicPodcastEpisodeMessage)
        case .ready:
            Issue.record("Nothing here can produce a transcript automatically.")
        }

        // The explicit Transcribe Audio action still reaches the exact enclosure.
        let optedIn = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            allowAudioTranscription: true,
            fetchAppleTranscript: { _, _ in .unavailable },
            resolveEpisodeAudioURL: { _, _, _ in URL(string: "https://example.com/private-episode.mp3") },
            transcribeEpisodeAudio: { _ in "Transcript from the private feed's own audio." },
            resolvePublicEpisode: { _, _, _ in .noMatchingEpisode }
        )
        switch optedIn.outcome {
        case .ready(let content, _):
            #expect(content == "Transcript from the private feed's own audio.")
        case .failed(let message):
            Issue.record("Expected the opt-in audio route to run, got: \(message)")
        }
    }

    @Test("a resolver outage keeps the row retryable")
    func resolverOutageIsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastResolverOutageTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeWebPageEpisode(id: "outage-row")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in .available(Self.appleTTML) },
            resolvePublicEpisode: { _, _, _ in .failed }
        )
        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.retryablePodcastTranscriptMessage)
            #expect(!StudioViewModel.isTerminalPodcastTranscriptError(message))
        case .ready:
            Issue.record("A resolver outage must not produce a transcript.")
        }
        let stored = try #require(try await storage.loadActiveSources().first(where: { $0.id == episode.id }))
        #expect(stored.url == episode.url)
    }

    @Test("a row whose public twin is already in the library is folded into it")
    func duplicateRowIsMergedIntoExistingEpisode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastDuplicateMergeTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)

        var existing = makeArticle(
            url: "apple-podcast://episode/1000415911177",
            title: "Dom D'Agostino, Ph.D.: ketosis",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "public-row"
        )
        existing.domain = "The Peter Attia Drive"
        try await storage.saveSource(existing)
        try await storage.saveTranscript(existing.id, "Peter Attia: Dom, welcome.", rawTTML: Self.appleTTML)
        existing.state = .ready

        let duplicate = makeWebPageEpisode(id: "page-duplicate")
        try await storage.saveSource(duplicate)
        vm.articles = [existing, duplicate]
        vm.selectedArticleId = duplicate.id
        let candidate = try #require(vm.podcastHydrationCandidate(for: duplicate.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("A merged row must not fetch a second copy of the transcript.")
                return .unavailable
            },
            resolvePublicEpisode: { _, _, _ in .matched(Self.publicTwin, showName: "The Peter Attia Drive") }
        )
        #expect(result.mergedIntoSourceID == existing.id)

        await vm.applyPodcastHydrationResult(result)
        #expect(vm.articles.map(\.id) == [existing.id])
        #expect(vm.selectedArticleId == existing.id)

        let active = try await storage.loadActiveSources().map(\.id)
        #expect(active == [existing.id])
        #expect(await storage.loadSourceContent(existing.id) == "Peter Attia: Dom, welcome.")
    }

    // MARK: - Readable before formatting

    /// A long run of speech from SPEAKER_1 across twelve of Apple's paragraphs,
    /// then a short answer from SPEAKER_2.
    nonisolated private static let longEpisodeTTML: String = {
        let host = (0..<12).map {
            "<p begin='\($0).0' end='\($0 + 1).0' ttm:agent='SPEAKER_1'>Replay during slow-wave sleep is what moves a memory from fragile to durable. Here is point \($0).</p>"
        }.joined(separator: "\n")
        return """
        <tt xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
        \(host)
            <p begin='20.0' end='21.0' ttm:agent='SPEAKER_2'>Thanks for having me, Zara.</p>
          </div></body>
        </tt>
        """
    }()

    private static let formattingConfig = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "example/formatter")

    @Test("an Apple transcript is saved ready at once, in paragraphs, and its formatting waits in the queue")
    func appleTranscriptReadsBeforeFormatting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastReadsAtOnceTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "reads-at-once", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))
        let extracted = try SourceService.extractTextFromTTMLContent(Self.longEpisodeTTML)

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: Self.formattingConfig,
            fetchAppleTranscript: { _, _ in .available(Self.longEpisodeTTML) }
        )

        guard case .ready(let content, let persistedReadyState) = result.outcome else {
            Issue.record("Expected the transcript to be ready at once, got \(result.outcome)")
            return
        }
        #expect(persistedReadyState)
        // No model ran: the speakers are still Apple's, and the long turn is cut
        // into paragraphs by code alone.
        #expect(content == StudioViewModel.readablePodcastTranscriptLayout(extracted))
        #expect(content.hasPrefix("[SPEAKER_1]\nReplay during slow-wave sleep"))
        #expect(content.components(separatedBy: "\n\n").count > 2)
        #expect(content.hasSuffix("\n\n[SPEAKER_2]\nThanks for having me, Zara."))
        #expect(StudioViewModel.podcastTranscriptWithoutLayout(content) == extracted)
        #expect(await storage.loadSourceContent(episode.id) == content)
        #expect(try await storage.loadPodcastRawTTML(episode.id) == Self.longEpisodeTTML)

        let queued = try await storage.podcastTranscriptCleanupCandidates(limit: 5)
        #expect(queued.map(\.sourceID) == [episode.id])
        #expect(queued.first?.formatsTranscript == true)
        #expect(queued.first?.input == content)

        await vm.applyPodcastHydrationResult(result)
        let loaded = try #require(vm.articles.first { $0.id == episode.id })
        #expect(loaded.state == .ready)
        #expect(loaded.content == content)
    }

    @Test("an episode that may not pay for formatting is saved readable and never queued for it")
    func unformattableEpisodeIsNotQueued() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastHiddenReadableTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "hidden-readable", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let base = try #require(vm.podcastHydrationCandidate(for: episode.id))
        let hidden = StudioViewModel.PodcastTranscriptHydrationCandidate(
            id: base.id,
            url: base.url,
            title: base.title,
            podcastName: base.podcastName,
            webPageURL: base.webPageURL,
            prefersYouTube: false,
            allowsFormatting: false
        )

        for (candidate, config) in [(hidden, Self.formattingConfig), (base, nil)] as [(StudioViewModel.PodcastTranscriptHydrationCandidate, AITaskConfig?)] {
            let result = await StudioViewModel.hydratePodcastTranscript(
                candidate,
                storage: storage,
                homeDir: "/tmp",
                config: config,
                forceRefresh: true,
                fetchAppleTranscript: { _, _ in .available(Self.longEpisodeTTML) }
            )
            guard case .ready(let content, _) = result.outcome else {
                Issue.record("Expected a readable transcript, got \(result.outcome)")
                continue
            }
            #expect(content.hasPrefix("[SPEAKER_1]\n"))
            #expect(await storage.loadSourceContent(episode.id) == content)
            #expect(try await storage.podcastTranscriptCleanupCandidates(limit: 5).allSatisfy { !$0.formatsTranscript })
        }
    }

    @Test("an episode the learner asked for is queued ahead of the rest")
    func learnerAskedEpisodeGoesFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastLearnerAskedTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var bulk = makeArticle(
            url: "apple-podcast://episode/1000751939406",
            title: "Episode bulk-episode",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "bulk-episode"
        )
        bulk.domain = "Example Podcast"
        let asked = makeEpisode(id: "asked-episode", show: "Example Podcast")
        try await storage.saveSource(bulk)
        try await storage.saveSource(asked)
        vm.articles = [bulk, asked]
        let bulkCandidate = try #require(vm.podcastHydrationCandidate(for: bulk.id))
        let askedCandidate = try #require(vm.podcastHydrationCandidate(for: asked.id, userInitiated: true))
        #expect(!bulkCandidate.userInitiated && askedCandidate.userInitiated)

        for candidate in [bulkCandidate, askedCandidate] {
            _ = await StudioViewModel.hydratePodcastTranscript(
                candidate,
                storage: storage,
                homeDir: "/tmp",
                config: Self.formattingConfig,
                fetchAppleTranscript: { _, _ in .available(Self.longEpisodeTTML) }
            )
        }

        let queued = try await storage.podcastTranscriptCleanupCandidates(limit: 5)
        #expect(queued.map(\.sourceID) == [asked.id, bulk.id])
        #expect(queued.allSatisfy { $0.formatsTranscript })
    }

    @Test("podcast YouTube fallback show keys ignore case and whitespace")
    func podcastYouTubeFallbackShowKey() {
        #expect(StudioViewModel.podcastShowPreferenceKey("  Mind & Matter  ") == "mind & matter")
    }

    @Test("YouTube recovery search includes the episode and podcast names")
    func youtubeRecoverySearchQuery() {
        var episode = makeEpisode(id: "youtube-search", show: "Mind & Matter")
        episode.title = "Neuro-Immune Interactions"

        #expect(
            StudioViewModel.podcastYouTubeSearchQuery(for: episode)
                == "Neuro-Immune Interactions Mind & Matter"
        )
    }

    @Test("YouTube recovery accepts semantic queries for differently titled uploads")
    func youtubeRecoverySemanticQueries() throws {
        let response = """
        {"queries":["Alex Colville Core Memory","Core Memory longevity Alex Colville"]}
        """

        #expect(
            try AIService.decodePodcastYouTubeSearchQueries(response)
                == ["Alex Colville Core Memory", "Core Memory longevity Alex Colville"]
        )
    }

    @Test("YouTube recovery ranking keeps every candidate and can prefer a different title")
    func youtubeRecoverySemanticRanking() throws {
        let response = """
        {"ranked_video_ids":["same-episode","literal-title"]}
        """

        #expect(
            try AIService.decodePodcastYouTubeRanking(
                response,
                expectedVideoIDs: ["literal-title", "same-episode"]
            ) == ["same-episode", "literal-title"]
        )
    }

    @Test("YouTube recovery rejects rankings that drop a candidate")
    func youtubeRecoveryRejectsPartialRanking() {
        #expect(throws: AIError.self) {
            try AIService.decodePodcastYouTubeRanking(
                "{\"ranked_video_ids\":[\"same-episode\"]}",
                expectedVideoIDs: ["same-episode", "another-video"]
            )
        }
    }

    @Test("YouTube recovery merges query results once and applies semantic order")
    func youtubeRecoveryMergesAndRanksCandidates() {
        let literal = YouTubeVideoSearchResult(
            videoId: "literal-title",
            title: "The Realest Longevity Guru - EP 85 Alex Colville",
            channelTitle: "Other Channel",
            description: nil,
            publishedAt: nil
        )
        let semantic = YouTubeVideoSearchResult(
            videoId: "same-episode",
            title: "The Longevity Expert Who Takes Nothing",
            channelTitle: "Core Memory Podcast",
            description: "Alex Colville is the longevity investor we call when someone claims to have found the fountain of youth.",
            publishedAt: nil
        )
        let merged = StudioViewModel.mergedPodcastYouTubeSearchResults([
            (1, [semantic]),
            (0, [literal, semantic]),
        ])

        #expect(merged.map(\.videoId) == ["literal-title", "same-episode"])
        #expect(
            StudioViewModel.rankedPodcastYouTubeSearchResults(
                merged,
                videoIDs: ["same-episode", "literal-title"]
            ).map(\.videoId) == ["same-episode", "literal-title"]
        )
    }

    @Test("YouTube recovery finds the upload an episode's page links most, in markup and JSON")
    func youtubeRecoveryReadsEpisodePageLinks() {
        // Core Memory's EP 90 page (2026-09-30): the upload linked once plainly
        // and again at every chapter time, and one other video in the notes.
        let html = """
        <a href="https://www.youtube.com/watch?v=Cqer4ApweVM">Watch</a>
        <a href="https://youtu.be/OsaIqiLnzRo">An earlier talk</a>
        <li><a href="https://www.youtube.com/watch?v=Cqer4ApweVM&amp;t=308s">5:08</a> Intro</li>
        <li><a href="https://www.youtube.com/watch?v=Cqer4ApweVM&amp;t=1179s">19:39</a> Ice</li>
        <script>{"embed":"https:\\/\\/www.youtube-nocookie.com\\/embed\\/Cqer4ApweVM"}</script>
        <a href="https://www.youtube.com/@CoreMemorypodcast">Channel</a>
        """

        #expect(StudioViewModel.youtubeVideoIDsLinked(inEpisodePage: html) == ["Cqer4ApweVM", "OsaIqiLnzRo"])
        #expect(StudioViewModel.youtubeVideoIDsLinked(inEpisodePage: "<p>No video here.</p>").isEmpty)
        #expect(
            StudioViewModel.youtubeVideoIDsLinked(
                inEpisodePage: #"<a href="https://www.youtube.com/watch?feature=share&v=dQw4w9WgXcQ">x</a>"#
            ) == ["dQw4w9WgXcQ"]
        )
    }

    @Test("YouTube recovery offers the show's uploads nearest the day the episode arrived")
    func youtubeRecoveryPicksChannelUploadsNearTheEpisode() {
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        func upload(_ id: String, daysFromEpisode days: Double?) -> YouTubePlaylistItem {
            YouTubePlaylistItem(
                videoId: id,
                title: id,
                playlistIndex: nil,
                channelTitle: "Core Memory Podcast",
                likedAt: nil,
                videoPublishedAt: days.map { added.addingTimeInterval($0 * 86_400) }
            )
        }
        let uploads = [
            upload("same-day", daysFromEpisode: -0.2),
            upload("next-week", daysFromEpisode: 6),
            upload("last-month", daysFromEpisode: -30),
            upload("undated", daysFromEpisode: nil),
            upload("two-days-on", daysFromEpisode: 2),
            upload("nine-days-back", daysFromEpisode: -9),
        ]

        #expect(
            StudioViewModel.uploadsNearEpisode(uploads, addedAt: added)
                == ["same-day", "two-days-on", "next-week"]
        )
        #expect(StudioViewModel.uploadsNearEpisode(uploads, addedAt: added, limit: 10).count == 4)
    }

    @Test("YouTube video lookups keep the order asked and the uploader's channel")
    func youtubeVideoListKeepsRequestedOrder() throws {
        let json = """
        {"items":[
          {"id":"second","snippet":{"title":"Can We Put Death On Hold?","channelId":"UCabcdefghijklmnopqrstuv","channelTitle":"Core Memory Podcast","publishedAt":"2026-09-30T12:00:06Z"}},
          {"id":"first","snippet":{"title":"Tom &amp; Jerry","channelTitle":"Other"}}
        ]}
        """
        let response = try JSONDecoder().decode(VideoListResponse.self, from: Data(json.utf8))
        let results = YouTubeService.videoListResults(from: response, orderedBy: ["first", "missing", "second"])

        #expect(results.map(\.videoId) == ["first", "second"])
        #expect(results.first?.title == "Tom & Jerry")
        #expect(results.last?.channelId == "UCabcdefghijklmnopqrstuv")
        #expect(results.last?.publishedAt != nil)
    }

    @Test("An assistant names the YouTube video by its address or its id")
    func podcastYouTubeImportReadsTheVideoArgument() {
        #expect(MCPDataStore.youtubeVideoID(fromArgument: " Cqer4ApweVM ") == "Cqer4ApweVM")
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "https://www.youtube.com/watch?v=Cqer4ApweVM&t=308s") == "Cqer4ApweVM")
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "youtu.be/Cqer4ApweVM") == "Cqer4ApweVM")
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "https://www.corememory.com/p/hes-here-to-end-death") == nil)
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "not a video") == nil)
    }

    @Test("YouTube recovery starts automatically only for terminal podcast failures")
    func automaticYouTubeRecoveryPolicy() {
        var episode = makeEpisode(id: "youtube-auto", show: "Mind & Matter")
        episode.errorMessage = StudioViewModel.unavailablePodcastTranscriptMessage

        #expect(StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(episode, isYouTubeSignedIn: true))
        #expect(!StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(episode, isYouTubeSignedIn: false))

        episode.errorMessage = StudioViewModel.retryablePodcastTranscriptMessage
        #expect(!StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(episode, isYouTubeSignedIn: true))

        var article = makeArticle(
            url: "https://example.com/story",
            title: "Story",
            sourceType: .article
        )
        article.errorMessage = StudioViewModel.unavailablePodcastTranscriptMessage
        #expect(!StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(article, isYouTubeSignedIn: true))
    }
}

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

    @Test("Reading List does not re-add a ScienceDirect paper stored under Elsevier's PDF filename")
    func readingListSkipsScienceDirectPIIDuplicateOfLocalPDF() {
        let existing = makeArticle(
            url: "Papers/1-s2.0-S0167488924001496-main.pdf",
            title: "Artificial mitochondrial transplantation (AMT) reverses aging of mesenchymal stromal cells",
            sourceType: .paper
        )
        let discovered = makeArticle(
            url: "https://www.sciencedirect.com/science/article/pii/S0167488924001496",
            title: "Artificial mitochondrial transplantation (AMT) reverses aging of mesenchymal stromal cells - ScienceDirect",
            sourceType: .paper
        )

        let result = StudioViewModel.computeMergeResultOffMain(
            discovered: StudioViewModel.makeMergeDiscoveredSnapshot(from: [discovered]),
            dismissedURLs: [],
            existing: StudioViewModel.makeMergeExistingSnapshot(from: [existing])
        )

        #expect(result.newArticleIndexes.isEmpty)
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

    @Test("papers without PDF badge ignores legacy paywall error marker")
    func papersWithoutPDFBadgeIgnoresLegacyPaywallErrorMarker() async {
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

    @Test("paper cleanup failures explain the purpose and preserve legacy details")
    func paperCleanupFailureMessageIsActionable() {
        var paper = makeArticle(
            url: "https://paper.com/cleanup-message",
            title: "Cleanup message",
            sourceType: .paper
        )
        paper.failPaperIngestionMetadata(
            "Paper ingestion failed during Source Content Cleanup: The network connection was lost."
        )

        #expect(paper.isPaperContentCleanupFailure)
        #expect(paper.paperContentCleanupFailureDetail == "The network connection was lost.")

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

    @Test("processing podcasts stay above the available episode list")
    func processingPodcastsArePublishedFirst() {
        let vm = makeViewModel()
        let queued = makeArticle(
            url: "apple-podcast://episode/1001",
            title: "Waiting episode",
            sourceType: .podcast,
            state: .queued
        )
        let fetching = makeArticle(
            url: "apple-podcast://episode/1002",
            title: "Active episode",
            sourceType: .podcast,
            state: .fetching
        )
        let queuedNonApple = makeArticle(
            url: "https://example.com/podcast/episode",
            title: "Queued external episode",
            sourceType: .podcast,
            state: .queued
        )
        let ready = makeArticle(
            url: "apple-podcast://episode/1003",
            title: "Ready episode",
            sourceType: .podcast,
            state: .ready
        )
        var failed = makeArticle(
            url: "apple-podcast://episode/1004",
            title: "Failed episode",
            sourceType: .podcast,
            state: .error
        )
        failed.errorMessage = "Transcript failed"

        vm.articles = [ready, failed, fetching, queuedNonApple, queued]
        vm.sidebarTab = .podcasts

        #expect(Set(vm.activeProcessingPodcasts.map(\.id)) == [fetching.id, queuedNonApple.id, queued.id])
        #expect(Set(vm.activePodcastsNotProcessing.map(\.id)) == [ready.id, failed.id])
        #expect(vm.activeProcessingPodcastsTotalCount == 3)
        #expect(Set(vm.activeTabArticles.prefix(3).map(\.id)) == [fetching.id, queuedNonApple.id, queued.id])
    }

    @Test("processing videos include queued, fetching, and formatting work")
    func processingVideosTrackTheWholeTranscriptPipeline() {
        let vm = makeViewModel()
        let queued = makeArticle(
            url: "https://www.youtube.com/watch?v=queued12345",
            title: "Waiting video",
            sourceType: .video,
            state: .queued
        )
        let fetching = makeArticle(
            url: "https://www.youtube.com/watch?v=fetching123",
            title: "Fetching video",
            sourceType: .video,
            state: .fetching
        )
        let formatting = makeArticle(
            url: "https://www.youtube.com/watch?v=format12345",
            title: "Formatting video",
            sourceType: .video,
            state: .ready
        )
        let ready = makeArticle(
            url: "https://www.youtube.com/watch?v=ready123456",
            title: "Ready video",
            sourceType: .video,
            state: .ready
        )

        vm.articles = [ready, formatting, fetching, queued]
        vm.sidebarTab = .videos
        vm.youtubeTranscriptFetchInFlight.insert(formatting.id)

        #expect(Set(vm.activeProcessingVideos.map(\.id)) == [queued.id, fetching.id, formatting.id])
        #expect(vm.activeProcessingVideosTotalCount == 3)
        #expect(!vm.activeProcessingVideos.contains(where: { $0.id == ready.id }))
    }

    @Test("filteredActiveItems respects search text")
    func filteredBySearch() {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://example.com/alpha", title: "Alpha Post", sourceType: .article)
        let a2 = makeArticle(url: "https://example.com/beta", title: "Beta Post", sourceType: .article)
        vm.articles = [a1, a2]
        vm.sidebarTab = .articles
        vm.searchText = "alpha"
        let results = vm.activeTabArticles
        #expect(results.count == 1)
        #expect(results[0].title == "Alpha Post")
    }

    @Test("pruning selection clears book chapter hidden by search")
    func pruneSelectionClearsBookChapterHiddenBySearch() {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/DNA/Chapters/02.xhtml",
            title: "2) Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "dna-book"
        )
        vm.bookTitles = ["dna-book": "DNA"]
        vm.articles = [chapter]
        vm.sidebarTab = .books
        vm.selectedArticleId = chapter.id
        vm.selectedArticleIds = [chapter.id]
        vm.searchText = "gwas"

        vm.pruneSelectionToVisibleSources()

        #expect(vm.visibleSidebarSourceIDs.isEmpty)
        #expect(vm.selectedArticleId == chapter.id)
        #expect(vm.selectedArticleIds.isEmpty)
    }

    @Test("Source search includes persisted book chapter content")
    func sourceSearchIncludesPersistedBookChapterContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BookSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var chapter = makeArticle(
            url: "Books/Aging/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            state: .ready,
            parentGroup: "aging-book"
        )
        chapter.content = "This chapter explains the free radical theory of aging in mitochondrial damage."
        try await service.saveSource(chapter)

        var displayedChapter = chapter
        displayedChapter.content = nil
        let other = makeArticle(url: "https://example.com/unrelated", title: "Unrelated", sourceType: .article)

        let vm = StudioViewModel(storageService: service)
        vm.articles = [other, displayedChapter]
        vm.sourceSearchQuery = "free radical theory of aging"

        await vm.searchSources()

        #expect(vm.sourceSearchResults.map(\.article.id).contains(displayedChapter.id))
    }

    /// The sidebar's own filter reads metadata only, so before this pass existed a
    /// term living in a transcript or a PDF body was unfindable from the one search
    /// field the app has — the learner had to already remember words from the title.
    @Test("Sidebar search surfaces a term that appears only inside a source")
    func sidebarSearchSurfacesBodyOnlyMatch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var paper = makeArticle(
            url: "https://example.com/isr",
            title: "Integrated stress response in human cells and tissues",
            sourceType: .paper
        )
        markPaperFullyReady(
            &paper,
            content: "The cytokine GDF15 rises with mitochondrial stress across human tissues."
        )
        try await service.saveSource(paper)

        var unrelated = makeArticle(
            url: "https://example.com/unrelated",
            title: "Unrelated Paper",
            sourceType: .paper
        )
        markPaperFullyReady(
            &unrelated,
            content: "A paper about protein folding kinetics and nothing else."
        )
        try await service.saveSource(unrelated)

        // The sidebar list holds metadata without bodies, exactly as it renders.
        var displayed = paper
        displayed.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.articles = [unrelated, displayed]
        vm.sidebarTab = .papers
        vm.searchText = "GDF15"

        // Synchronous pass: the term is in neither title, author, journal, nor DOI.
        #expect(!vm.filteredActiveItems.map(\.id).contains(displayed.id))

        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.filteredActiveItems.map(\.id).contains(displayed.id))
        #expect(!vm.filteredActiveItems.map(\.id).contains(unrelated.id))

        // Clearing the field drops the matches rather than stranding them, which
        // would leave the list narrowed to a search that is no longer running.
        vm.searchText = ""
        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs.isEmpty)
        #expect(Set(vm.filteredActiveItems.map(\.id)) == [displayed.id, unrelated.id])
    }

    @Test("Sidebar content search never widens to partial or merely similar matches")
    func sidebarContentSearchStrictlyMatchesEveryTerm() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarStrictSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var exact = makeArticle(
            url: "https://example.com/picard",
            title: "Mitochondrial health",
            sourceType: .podcast
        )
        exact.content = "The guest is Martin Picard, discussing mitochondrial psychobiology."
        try await service.saveSource(exact)

        var partial = makeArticle(
            url: "https://example.com/fowler",
            title: "Software architecture",
            sourceType: .podcast
        )
        partial.content = "The guest is Martin Fowler, discussing software architecture."
        try await service.saveSource(partial)

        var unrelated = makeArticle(
            url: "https://example.com/longevity",
            title: "Longevity roundtable",
            sourceType: .podcast
        )
        unrelated.content = "A conversation about nutrition, sleep, and healthy aging."
        try await service.saveSource(unrelated)

        exact.content = nil
        partial.content = nil
        unrelated.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.articles = [unrelated, partial, exact]
        vm.sidebarTab = .podcasts
        vm.searchText = "martin picard"

        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs == [exact.id])
        #expect(vm.filteredActiveItems.map(\.id) == [exact.id])
    }

    /// The metadata pass draws the list as the learner types; the body pass lands a
    /// debounce and a database query later. Sorting both by the tab's order let the
    /// second pass push hundreds of body matches above the exact title match that
    /// was already on screen. Later matches append below; what was drawn never moves.
    @Test("Sidebar body matches append below metadata matches instead of reordering them")
    func sidebarBodyMatchesAppendBelowMetadataMatches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSearchTierTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var titled = makeArticle(
            url: "https://example.com/hypermetabolism",
            title: "Context-Specific Hypermetabolism in Mitochondrial Energy Defects",
            sourceType: .paper
        )
        markPaperFullyReady(&titled, content: "Energy expenditure rises in some tissues and not others.")
        titled.dateAdded = Date(timeIntervalSince1970: 1_000_000)
        try await service.saveSource(titled)

        // Newer, so the Papers tab's own order (date added, newest first) would put
        // both of these above the title match once their bodies are found to match.
        var mention = makeArticle(
            url: "https://example.com/biomarkers",
            title: "Biomarkers of aging for longevity interventions",
            sourceType: .paper
        )
        markPaperFullyReady(&mention, content: "Clocks must be validated in a context specific manner.")
        mention.dateAdded = Date(timeIntervalSince1970: 3_000_000)
        try await service.saveSource(mention)

        var laterMention = makeArticle(
            url: "https://example.com/clocks",
            title: "Proteomic aging clocks in a clinical trial",
            sourceType: .paper
        )
        markPaperFullyReady(&laterMention, content: "Effects were context specific across the cohort.")
        laterMention.dateAdded = Date(timeIntervalSince1970: 2_000_000)
        try await service.saveSource(laterMention)

        // The sidebar list holds metadata without bodies, exactly as it renders.
        titled.content = nil
        mention.content = nil
        laterMention.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.articles = [titled, mention, laterMention]
        vm.sidebarTab = .papers
        vm.searchText = "context-specific"

        // Synchronous pass: the title match, and only it.
        #expect(vm.filteredActiveItems.map(\.id) == [titled.id])

        await vm.refreshSidebarContentSearchMatches()

        // The body matches join below it, in the tab's own order among themselves.
        #expect(vm.filteredActiveItems.map(\.id) == [titled.id, mention.id, laterMention.id])
    }

    @Test("Papers tab search matches paper author metadata")
    func papersTabSearchMatchesPaperAuthorMetadata() {
        let vm = makeViewModel()
        var picardPaper = makeArticle(
            url: "https://example.com/mitochondria",
            title: "Mitochondrial Psychobiology",
            sourceType: .paper
        )
        picardPaper.author = "Picard et al."
        let otherPaper = makeArticle(
            url: "https://example.com/other",
            title: "Unrelated Paper",
            sourceType: .paper
        )

        vm.articles = [otherPaper, picardPaper]
        vm.sidebarTab = .papers
        vm.searchText = "Martin Picard"

        #expect(vm.activeTabArticles.map(\.id) == [picardPaper.id])
    }

    @Test("Paper search does not resurrect a duplicate already ingested elsewhere in the library")
    func paperSearchKeepsLibraryWideDuplicateSuppression() async throws {
        let vm = makeViewModel()
        let tempPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        await warmLocalPathCache([tempPDF.path])

        var ingested = makeArticle(
            url: tempPDF.path,
            title: "The significance of bioelectricity on all levels of organization",
            sourceType: .paper
        )
        ingested.localFilePath = tempPDF.path
        ingested.author = "Richard Funk; Felix Scholkmann"
        ingested.doi = "10.1016/j.pbiomolbio.2022.12.002"
        markPaperFullyReady(&ingested)

        var staleDiscovery = makeArticle(
            url: "https://example.com/discovered-paper",
            title: ingested.title,
            sourceType: .paper
        )
        staleDiscovery.author = "Jane Smith; Martin Picard; Alex Doe"
        staleDiscovery.doi = "10.1101/2022.07.27.492200"

        vm.articles = [staleDiscovery, ingested]
        vm.sidebarTab = .papers
        vm.searchText = "picard"

        #expect(vm.filteredActiveItems.map(\.id) == [staleDiscovery.id])
        #expect(vm.papersNeedingPDFAttention.isEmpty)
        #expect(vm.activePapersWithoutPDF.isEmpty)
    }

    @Test("course search matches metadata")
    func courseSearchMatchesMetadata() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "Algorithms": CourseMetadata(courseCode: "6.006", title: "Introduction to Algorithms", institution: "MIT", instructors: "Erik Demaine", playlistURL: nil),
            "Machine Learning": CourseMetadata(courseCode: "CS229", title: nil, institution: "Stanford", instructors: "Andrew Ng", playlistURL: nil),
        ]

        #expect(vm.courseGroupNames(matching: "cs229") == ["Machine Learning"])
        #expect(vm.courseGroupNames(matching: "mit") == ["Algorithms"])
        #expect(vm.courseGroupNames(matching: "") == ["Algorithms", "Machine Learning"])
    }

    @Test("hidden courses are omitted from the Courses home")
    func hiddenCoursesAreOmitted() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "Visible": CourseMetadata(title: "Visible Course"),
            "Hidden": CourseMetadata(title: "Hidden Course", isHidden: true),
        ]

        #expect(vm.courseGroupNames(matching: "") == ["Visible"])
        #expect(vm.hiddenCourseGroupNames == ["Hidden"])
    }

    @Test("course groups respect manual reorder")
    func courseGroupsRespectManualReorder() {
        let vm = makeViewModel()
        vm.courseOrder = []
        vm.courseMetadata = [
            "algorithms": CourseMetadata(title: "Algorithms"),
            "biology": CourseMetadata(title: "Biology"),
            "calculus": CourseMetadata(title: "Calculus"),
        ]

        vm.reorderCourse(from: "calculus", to: "algorithms")

        #expect(vm.courseGroupNames(matching: "") == ["calculus", "algorithms", "biology"])
    }

    @Test("sortCoursesByTitle resets manual course order")
    func sortCoursesByTitleResetsManualOrder() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "algorithms": CourseMetadata(title: "Algorithms"),
            "biology": CourseMetadata(title: "Biology"),
            "calculus": CourseMetadata(title: "Calculus"),
        ]
        vm.courseOrder = ["calculus", "biology", "algorithms"]

        vm.sortCoursesByTitle()

        #expect(vm.courseGroupNames(matching: "") == ["algorithms", "biology", "calculus"])
    }

    @Test("hidden sources are omitted from source tabs")
    func hiddenSourcesAreOmittedFromTabs() {
        let vm = makeViewModel()
        var hidden = makeArticle(url: "https://example.com/hidden", title: "Hidden", sourceType: .article)
        hidden.isHidden = true
        vm.articles = [
            makeArticle(url: "https://example.com/visible", title: "Visible", sourceType: .article),
            hidden,
        ]
        vm.sidebarTab = .articles

        #expect(vm.activeTabArticles.map(\.title) == ["Visible"])
        #expect(vm.hiddenSourceArticles(for: .articles).map(\.title) == ["Hidden"])
    }

    @Test("fully hidden books are tracked as hidden book groups")
    func hiddenBookGroupsAreTracked() {
        let vm = makeViewModel()
        var chapter1 = makeArticle(url: "/books/example/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Example Book")
        var chapter2 = makeArticle(url: "/books/example/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "Example Book")
        let visibleChapter = makeArticle(url: "/books/other/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Other Book")
        chapter1.isHidden = true
        chapter2.isHidden = true
        vm.articles = [chapter1, chapter2, visibleChapter]

        #expect(vm.visibleBookGroupNames == ["Other Book"])
        #expect(vm.hiddenBookGroupNames == ["Example Book"])
        #expect(vm.hasHiddenBookItems)
        #expect(vm.hiddenBookChapterArticles.isEmpty)
    }

    @Test("A hidden book and its chapters open from Hidden Items in the Reader, and stay hidden")
    func hiddenBookOpensFromHiddenItems() async throws {
        let vm = makeViewModel()
        var chapter1 = makeArticle(url: "/books/example/ch1.pdf", title: "Chapter 1", sourceType: .book, state: .ready, parentGroup: "Example Book", sortIndex: 0)
        var chapter2 = makeArticle(url: "/books/example/ch2.pdf", title: "Chapter 2", sourceType: .book, state: .ready, parentGroup: "Example Book", sortIndex: 1)
        var stray = makeArticle(url: "/books/other/ch2.pdf", title: "A Hidden Chapter", sourceType: .book, state: .ready, parentGroup: "Other Book", sortIndex: 1)
        var shown = makeArticle(url: "/books/other/ch1.pdf", title: "Chapter 1", sourceType: .book, state: .ready, parentGroup: "Other Book", sortIndex: 0)
        chapter1.isHidden = true
        chapter2.isHidden = true
        stray.isHidden = true
        chapter1.content = "The first chapter."
        chapter2.content = "The second chapter."
        stray.content = "A chapter hidden on its own."
        shown.content = "A chapter in the list."
        vm.articles = [chapter1, chapter2, stray, shown]
        let window = StudioWindowState()

        let model = HiddenItemsModel.build(for: .books, vm: vm, in: window)
        let book = try #require(model.groups.first)
        #expect(model.groups.map(\.id) == ["Example Book"])
        #expect(book.hiddenEpisodes.map(\.id) == [chapter1.id, chapter2.id], "a hidden book lists its chapters in order")
        #expect(model.items.map(\.id) == [stray.id])
        #expect(book.unhide != nil, "Unhide is still offered")

        // The book opens as a book opens from the Books list: nothing read yet, so its first chapter.
        await book.open?()
        #expect(window.readerArticleID == chapter1.id)
        #expect(vm.selectedArticleId == chapter1.id)
        await book.hiddenEpisodes[1].open?()
        #expect(window.readerArticleID == chapter2.id)
        await model.items[0].open?()
        #expect(window.readerArticleID == stray.id)

        // Reading it changed nothing about what is hidden.
        #expect(vm.hiddenBookGroupNames == ["Example Book"])
        #expect(vm.visibleBookGroupNames == ["Other Book"])
        #expect(vm.hiddenBookChapterArticles.map(\.id) == [stray.id])
        #expect([chapter1.id, chapter2.id, stray.id].allSatisfy { id in vm.articlesById[id]?.isHidden == true })
    }

    @Test("book metadata without chapters is not shown as a book group")
    func orphanBookMetadataIsNotShownAsBookGroup() {
        let vm = makeViewModel()
        vm.bookTitles = [
            "Orphan Book": "Orphan Book",
            "Real Book": "Real Book",
        ]
        vm.bookCoverPaths = ["Orphan Book": "/books/orphan/cover.jpg"]
        vm.bookAuthors = ["Orphan Book": "Someone"]
        vm.bookKinds = ["Orphan Book": "Textbook"]
        vm.articles = [
            makeArticle(url: "/books/real/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Real Book"),
        ]

        #expect(vm.allBookGroupNames == ["Real Book"])
        #expect(vm.visibleBookGroupNames == ["Real Book"])
        #expect(vm.allBookKinds.isEmpty)
    }

    @Test("book group source IDs preserve chapter sort order")
    func bookGroupSourceIDsPreserveChapterSortOrder() {
        let vm = makeViewModel()
        let chapter3 = makeArticle(
            url: "Books/Test/Chapters/03.pdf",
            title: "Chapter 3",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 2
        )
        let chapter1 = makeArticle(
            url: "Books/Test/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 0
        )
        let chapter2 = makeArticle(
            url: "Books/Test/Chapters/02.pdf",
            title: "Chapter 2",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 1
        )
        vm.articles = [chapter3, chapter1, chapter2]

        #expect(vm.sourceIDsForGroupInOrder("book") == [chapter1.id, chapter2.id, chapter3.id])
        #expect(vm.sourceIdsForGroup("book") == Set([chapter1.id, chapter2.id, chapter3.id]))
    }

    @Test("course group source IDs include the whole outline in lecture order")
    func courseGroupSourceIDsIncludeWholeOutlineInLectureOrder() {
        let vm = makeViewModel()
        let firstLecture = CourseSession(id: "lecture-1", courseName: "course", number: 1)
        let secondLecture = CourseSession(id: "lecture-2", courseName: "course", number: 2)
        let firstVideo = makeArticle(
            title: "Lecture 1",
            sourceType: .video,
            parentGroup: "course",
            id: "video-1"
        )
        let firstSlides = makeArticle(
            title: "Lecture 1 slides",
            sourceType: .course,
            parentGroup: "course",
            id: "slides-1"
        )
        let secondVideo = makeArticle(
            title: "Lecture 2",
            sourceType: .video,
            parentGroup: "course",
            id: "video-2"
        )
        let unassignedReading = makeArticle(
            title: "Further reading",
            sourceType: .course,
            parentGroup: "course",
            id: "reading"
        )
        vm.articles = [unassignedReading, secondVideo, firstSlides, firstVideo]
        vm.courseLecturesByCourse["course"] = [secondLecture, firstLecture]
        vm.courseLectureItemsByLectureId[firstLecture.id] = [
            CourseLectureItem(
                id: "slides-item",
                lectureId: firstLecture.id,
                sourceId: firstSlides.id,
                role: .slides,
                sortIndex: 1
            ),
            CourseLectureItem(
                id: "video-1-item",
                lectureId: firstLecture.id,
                sourceId: firstVideo.id,
                role: .video,
                sortIndex: 0
            ),
        ]
        vm.courseLectureItemsByLectureId[secondLecture.id] = [
            CourseLectureItem(
                id: "video-2-item",
                lectureId: secondLecture.id,
                sourceId: secondVideo.id,
                role: .video,
                sortIndex: 0
            ),
        ]

        #expect(vm.sourceIDsForGroupInOrder("course") == [
            firstVideo.id,
            firstSlides.id,
            secondVideo.id,
            unassignedReading.id,
        ])
    }

    @Test("group drag transfer preserves source IDs and decodes legacy name-only payloads")
    func groupDragTransferPreservesSourceIDsAndDecodesLegacyNameOnlyPayloads() throws {
        let transfer = StudioGroupTransfer(groupName: "course", sourceIDs: ["lecture-1", "lecture-2"])
        let decoded = try JSONDecoder().decode(
            StudioGroupTransfer.self,
            from: JSONEncoder().encode(transfer)
        )
        let legacy = try JSONDecoder().decode(
            StudioGroupTransfer.self,
            from: Data(#"{"groupName":"course"}"#.utf8)
        )

        #expect(decoded.groupName == "course")
        #expect(decoded.sourceIDs == ["lecture-1", "lecture-2"])
        #expect(legacy.groupName == "course")
        #expect(legacy.sourceIDs == nil)
    }

    @Test("group display title names a book by its title, never by its group key")
    func groupDisplayTitleNamesGroupsByTitleNotKey() {
        let vm = makeViewModel()
        let bookID = UUID().uuidString
        vm.bookTitles = [bookID: "Thinking in Systems"]
        vm.courseMetadata = ["course-id": CourseMetadata(title: "Linear Algebra")]
        vm.videoPlaylistMetadata = [
            "playlist-id": VideoPlaylistMetadata(
                title: "3Blue1Brown",
                playlistURL: "https://www.youtube.com/playlist?list=PL"
            )
        ]

        // The drag payload carries the group key, so a book's opaque ID must
        // resolve to its title rather than reach the drop target as-is.
        #expect(vm.groupDisplayTitle(bookID) == "Thinking in Systems")
        #expect(vm.groupDisplayTitle("course-id") == "Linear Algebra")
        #expect(vm.groupDisplayTitle("playlist-id") == "3Blue1Brown")
        // A title-keyed group (an untitled folder of sources) is its own name.
        #expect(vm.groupDisplayTitle("Reading list") == "Reading list")
        // Nothing readable: nil, so callers say nothing instead of showing a UUID.
        #expect(vm.groupDisplayTitle(UUID().uuidString) == nil)
        #expect(vm.groupDisplayTitle("   ") == nil)
    }

    @Test("book display preserves stored title instead of deriving from folder path")
    func bookDisplayPreservesStoredTitleInsteadOfDerivingFromFolderPath() {
        let vm = makeViewModel()
        vm.bookTitles = ["book": "Build LLMfrom Scratch"]
        vm.bookCoverPaths = ["book": "Books/BuildLLMfromScratch/cover.jpg"]

        #expect(vm.bookDisplayName("book") == "Build LLMfrom Scratch")
    }

    @Test("book display preserves AI-provided title metadata")
    func bookDisplayPreservesTitleMetadata() {
        let vm = makeViewModel()
        vm.bookTitles = ["book": "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition"]
        vm.bookSubtitles = ["book": "Design Principles of Biological Circuits"]
        vm.bookEditions = ["book": "Second Edition"]

        #expect(vm.bookDisplayName("book") == "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition")
        #expect(StudioViewModel.cleanBookTitle(
            "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition",
            subtitle: "Design Principles of Biological Circuits",
            edition: "Second Edition"
        ) == "An Introduction to Systems Biology; Design Principles of Biological Circuits; Second Edition")
    }

    @Test("book display trusts AI-provided author metadata")
    func bookDisplayTrustsAuthorMetadata() {
        let vm = makeViewModel()
        vm.bookTitles = ["book": "Power Sex Suicide"]
        vm.bookAuthors = ["book": "Power, Sex, Suicide"]

        #expect(vm.bookDisplayAuthor("book") == "Power, Sex, Suicide")
    }

    @Test("book search by metadata keeps matching book chapters")
    func bookSearchByMetadataKeepsMatchingBookChapters() {
        let vm = makeViewModel()
        let powerChapter1 = makeArticle(
            url: "Books/PowerSexSuicide/Chapters/01.pdf",
            title: "Mitochondria",
            sourceType: .book,
            parentGroup: "power-book",
            sortIndex: 0
        )
        let powerChapter2 = makeArticle(
            url: "Books/PowerSexSuicide/Chapters/02.pdf",
            title: "The Meaning of Life",
            sourceType: .book,
            parentGroup: "power-book",
            sortIndex: 1
        )
        let otherChapter = makeArticle(
            url: "Books/Other/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "other-book",
            sortIndex: 0
        )
        vm.bookTitles = [
            "power-book": "Power, Sex, Suicide",
            "other-book": "Other Book",
        ]
        vm.articles = [powerChapter1, powerChapter2, otherChapter]
        vm.sidebarTab = .books
        vm.searchText = "power, sex"

        #expect(vm.filteredBookGroupNames == ["power-book"])
        #expect(vm.totalFilteredCount == 1)
        #expect(vm.activeTabArticles.map(\.id) == [powerChapter1.id, powerChapter2.id])
    }

    @Test("Books tab search reaches chapter text through the indexed content pass")
    func booksTabSearchFindsChapterBodyMatches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BooksContentSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        var intro = makeArticle(
            url: "Books/Transformer/Chapters/01.pdf",
            title: "Introduction: Life itself",
            sourceType: .book,
            parentGroup: "transformer",
            sortIndex: 0
        )
        intro.content = "We cannot hope to understand what goes wrong in cancer or Alzheimer’s disease without the Krebs cycle."
        try await service.saveSource(intro)

        var carbon = makeArticle(
            url: "Books/Transformer/Chapters/03.pdf",
            title: "The path of carbon",
            sourceType: .book,
            parentGroup: "transformer",
            sortIndex: 1
        )
        carbon.content = "Carbon flows through the cycle in both directions."
        try await service.saveSource(carbon)

        var other = makeArticle(
            url: "Books/Other/Chapters/01.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "other-book",
            sortIndex: 0
        )
        other.content = "A chapter about something else entirely."
        try await service.saveSource(other)

        // The sidebar list holds metadata without bodies, exactly as it renders.
        intro.content = nil
        carbon.content = nil
        other.content = nil

        let vm = StudioViewModel(storageService: service)
        vm.bookTitles = ["transformer": "Transformer", "other-book": "Other Book"]
        vm.articles = [other, carbon, intro]
        vm.sidebarTab = .books
        vm.searchText = "Alzheimer"

        // The synchronous metadata pass finds nothing: the term is in a chapter body only.
        #expect(vm.filteredBookGroupNames.isEmpty)
        #expect(vm.totalFilteredCount == 0)
        #expect(vm.activeTabArticles.isEmpty)

        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs == [intro.id])
        #expect(vm.filteredBookGroupNames == ["transformer"])
        #expect(vm.totalFilteredCount == 1)
        // The whole book renders, not only the matching chapter, so the group stays coherent.
        #expect(vm.activeTabArticles.map(\.id) == [intro.id, carbon.id])

        vm.searchText = ""
        await vm.refreshSidebarContentSearchMatches()

        #expect(vm.contentSearchMatchIDs.isEmpty)
        #expect(Set(vm.filteredBookGroupNames) == ["other-book", "transformer"])
    }

    @Test("Books tab group list and chapters follow the category filter")
    func booksTabFollowsCategoryFilter() {
        let vm = makeViewModel()
        let biology = makeArticle(
            url: "Books/Biology/Chapters/01.pdf",
            title: "Cells",
            sourceType: .book,
            parentGroup: "biology-book",
            sortIndex: 0
        )
        let history = makeArticle(
            url: "Books/History/Chapters/01.pdf",
            title: "Empires",
            sourceType: .book,
            parentGroup: "history-book",
            sortIndex: 0
        )
        vm.bookTitles = ["biology-book": "Biology", "history-book": "History"]
        vm.bookKinds = ["biology-book": "Science", "history-book": "Humanities"]
        vm.articles = [biology, history]
        vm.sidebarTab = .books

        #expect(Set(vm.filteredBookGroupNames) == ["biology-book", "history-book"])
        #expect(vm.totalFilteredCount == 2)

        // The cached list and count must not outlive the category choice.
        vm.selectedBookKind = "Science"
        #expect(vm.filteredBookGroupNames == ["biology-book"])
        #expect(vm.totalFilteredCount == 1)
        #expect(vm.activeTabArticles.map(\.id) == [biology.id])

        vm.selectedBookKind = nil
        #expect(Set(vm.filteredBookGroupNames) == ["biology-book", "history-book"])
        #expect(vm.activeTabArticles.count == 2)
    }

    @Test("the Docs source picker finds a book's chapters by the book's title and author")
    func citationSourceSearchFindsBookMetadata() async {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/HowLifeWorks/Chapters/01.xhtml",
            title: "The Cell as an Agent",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [chapter]

        let index = await vm.artifactSourcePickerIndex()
        #expect(index.rows(matching: "how life works").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "Philip Ball").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "unrelated book").isEmpty)
    }

    @Test("a field prefix confines the search to that field")
    func sourceSearchFieldScope() {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "https://example.com/ret",
            title: "Reverse electron transport at complex I",
            sourceType: .paper
        )
        paper.author = "Martin Picard"
        paper.journal = "Nature Metabolism"
        paper.publishedYear = "2024"
        var other = makeArticle(
            url: "https://example.com/methods",
            title: "Overview of methods that determine mitochondrial function",
            sourceType: .paper
        )
        other.author = "Eashan Sharma"
        other.journal = "Reverse Transport Quarterly"
        other.publishedYear = "2025"
        vm.articles = [paper, other]

        // The bare query reads everything; the prefixed one reads titles only.
        #expect(vm.sourceMatchesSearch(other, query: "reverse transport"))
        #expect(!vm.sourceMatchesSearch(other, query: "title:reverse transport"))
        #expect(vm.sourceMatchesSearch(paper, query: "title:reverse electron transport"))
        #expect(vm.sourceMatchesSearch(paper, query: "Title: Reverse Electron"))
        #expect(vm.sourceMatchesSearch(other, query: "journal:reverse transport"))
        #expect(vm.sourceMatchesSearch(paper, query: "author:picard"))
        #expect(vm.sourceMatchesSearch(paper, query: "by: picard"))
        #expect(!vm.sourceMatchesSearch(paper, query: "title:picard"))
        #expect(vm.sourceMatchesSearch(other, query: "year:2025"))
        #expect(!vm.sourceMatchesSearch(paper, query: "year:2025"))
        #expect(vm.sourceMatchesSearch(paper, query: "site:example.com"))

        // The author's-last-name shortcut belongs to the byline, not to a title search.
        #expect(vm.sourceMatchesSearch(paper, query: "mitochondria picard"))
        #expect(!vm.sourceMatchesSearch(paper, query: "title:mitochondria picard"))

        // A prefix with nothing after it is a search still being typed.
        #expect(vm.sourceMatchesSearch(paper, query: "title:"))
        // A pasted address is an ordinary search, not a scope.
        #expect(vm.sourceMatchesSearch(paper, query: "https://example.com/ret"))
        #expect(!vm.sourceMatchesSearch(other, query: "https://example.com/ret"))

        let parsed = StudioViewModel.SidebarSearchQuery(parsing: "  Title:  Reverse  ")
        #expect(parsed.field == .title)
        #expect(parsed.text == "Reverse")
        #expect(StudioViewModel.SidebarSearchQuery(parsing: "doi:10.1038/x").field == .doi)
        #expect(StudioViewModel.SidebarSearchQuery(parsing: "https://doi.org/10.1038/x").field == nil)
        #expect(StudioViewModel.SidebarSearchQuery(parsing: "reverse").isScoped == false)
    }

    @Test("a title-scoped search reads a book's title but not its author")
    func bookSearchHonorsFieldScope() {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/HowLifeWorks/Chapters/01.xhtml",
            title: "The Cell as an Agent",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [chapter]

        vm.searchText = "philip ball"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
        vm.searchText = "author:philip ball"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
        vm.searchText = "title:philip ball"
        #expect(!vm.bookMatchesSearch("book-how-life-works"))
        vm.searchText = "title:how life"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
        // A chapter title answers for its book under the same scope.
        vm.searchText = "title:cell as an agent"
        #expect(vm.bookMatchesSearch("book-how-life-works"))
    }

    @Test("source search reads a hyphenated term and its bare spelling as one")
    func sourceSearchIgnoresHyphenation() async {
        let vm = makeViewModel()
        var hyphenated = makeArticle(
            url: "https://example.com/gdf-15-aging",
            title: "GDF-15 as a Biomarker of Aging",
            sourceType: .paper
        )
        hyphenated.author = "Margalida Torrens-Mas"
        var bare = makeArticle(
            url: "https://example.com/mystery-hormone",
            title: "GDF15 is still a mystery hormone",
            sourceType: .paper
        )
        bare.author = "Casper M. Sigvardsen"
        vm.articles = [hyphenated, bare]

        // The direction that used to fail: nothing in the hyphenated title
        // literally contains "gdf15".
        #expect(vm.sourceMatchesSearch(hyphenated, query: "GDF15"))
        #expect(vm.sourceMatchesSearch(bare, query: "GDF-15"))
        #expect(vm.sourceMatchesSearch(hyphenated, query: "GDF15 biomarker"))
        #expect(vm.sourceMatchesSearch(hyphenated, query: "torrens mas"))
        // Folding punctuation must not fold the term itself.
        #expect(!vm.sourceMatchesSearch(hyphenated, query: "GDF16"))
        #expect(!vm.sourceMatchesSearch(bare, query: "FGF-21"))

        // The fold closes up punctuation inside a word and keeps whitespace between
        // words, so a whole-query match cannot straddle a boundary the learner typed.
        #expect(StudioViewModel.foldedSidebarSearchString("GDF-15 as a Biomarker of Aging")
            == "gdf15 as a biomarker of aging")

        // Both spellings therefore land in the Docs picker under either query.
        let index = await vm.artifactSourcePickerIndex()
        let bareQuery = Set(index.rows(matching: "GDF15").map(\.sourceID))
        let hyphenQuery = Set(index.rows(matching: "GDF-15").map(\.sourceID))
        // The last-author rule reaches the picker too, and a typo still finds nothing.
        #expect(index.rows(matching: "torrens mas").map(\.sourceID) == [hyphenated.id])
        #expect(index.rows(matching: "GDF16").isEmpty)
        #expect(bareQuery == [hyphenated.id, bare.id])
        #expect(hyphenQuery == [hyphenated.id, bare.id])
    }

    @Test("book metadata search ignores hyphenation too")
    func citationSourceSearchIgnoresBookHyphenation() async {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/CfMtDNA/Chapters/01.xhtml",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "book-cf-mtdna",
            sortIndex: 0
        )
        vm.bookTitles = ["book-cf-mtdna": "cf-mtDNA and Mitochondrial Health"]
        vm.articles = [chapter]

        let index = await vm.artifactSourcePickerIndex()
        #expect(index.rows(matching: "cfmtDNA").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "cf-mtDNA").map(\.sourceID) == [chapter.id])
        #expect(index.rows(matching: "mtRNA").isEmpty)
    }

    @Test("Notepad citation picker collapses a matching book and expands its reference")
    func notepadCitationPickerUsesWholeBook() async {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        let second = makeArticle(
            url: "Books/HowLifeWorks/02.xhtml",
            title: "Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 1
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [second, first]

        let index = await vm.artifactSourcePickerIndex()
        let rows = index.rows(matching: "Philip Ball")
        #expect(rows.count == 1)
        #expect(rows.first?.title == "How Life Works")
        #expect(rows.first?.sourceID == first.id)
        #expect(rows.first?.bookID == "book-how-life-works")
        #expect(index.entries.first?.sources.map(\.fields.id) == [first.id, second.id])

        let markdown = "[How Life Works](foreverlm://source/\(first.id)?book=book-how-life-works)"
        #expect(vm.sourceIDsReferencedByNotepadMarkdown(markdown) == [first.id, second.id])
    }

    @Test("A grounded passage puts its attached sources in the doc's context")
    func groundedPassageContributesItsSources() {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://example.com/a", title: "Aging as Adaptation", id: "src-a")
        let b = makeArticle(url: "https://example.com/b", title: "Energy Constraints", id: "src-b")
        let c = makeArticle(url: "https://example.com/c", title: "Cellular Senescence", id: "src-c")
        vm.articles = [a, b, c]

        // Sentence one stands on A and B; sentence two on C. A question about both
        // sentences has to arrive carrying all three, in reading order.
        let markdown = "[Sentence one.](foreverlm://grounding/src-a,src-b) [Sentence two.](foreverlm://grounding/src-c)"
        #expect(vm.sourceIDsReferencedByNotepadMarkdown(markdown) == ["src-a", "src-b", "src-c"])
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown("[Sentence two.](foreverlm://grounding/src-c)")
                == ["src-c"]
        )

        // A doc old enough to still carry a citation chip stands on both kinds.
        // The editor converts the chip to grounding when it opens the doc; until
        // then the source it named is context just the same.
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown(
                "[Named](foreverlm://source/src-a) and [attached.](foreverlm://grounding/src-c)"
            ) == ["src-a", "src-c"]
        )

        // An id the library no longer holds cannot become context.
        #expect(vm.sourceIDsReferencedByNotepadMarkdown("[Gone.](foreverlm://grounding/src-gone)").isEmpty)
    }

    @Test("A grounding address parses its whole list once")
    func groundingAddressParsesItsList() throws {
        let url = try #require(URL(string: "foreverlm://grounding/src-a,src%20b,src-a,src-c"))
        #expect(StudioViewModel.isNotepadGroundingURL(url))
        #expect(
            StudioViewModel.notepadGroundingTokens(from: url) == ["src-a", "src b", "src-c"]
        )

        let chip = try #require(URL(string: "foreverlm://source/src-a"))
        #expect(!StudioViewModel.isNotepadGroundingURL(chip))
        #expect(StudioViewModel.notepadGroundingTokens(from: chip).isEmpty)
    }

    @Test("A passage attached to a book stands on the book's current chapters")
    func groundedPassageExpandsABook() {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        let second = makeArticle(
            url: "Books/HowLifeWorks/02.xhtml",
            title: "Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 1
        )
        let paper = makeArticle(url: "https://example.com/a", title: "Aging as Adaptation", id: "src-a")
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.articles = [second, first, paper]

        // A book is one thing a passage stands on, and it expands through the
        // chapters the library holds now — not the ones it held when attached.
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown(
                "[Passage.](foreverlm://grounding/book:book-how-life-works,src-a)"
            ) == [first.id, second.id, "src-a"]
        )
        #expect(
            vm.sourceIDsReferencedByNotepadMarkdown(
                "[Passage.](foreverlm://grounding/book:book-gone)"
            ).isEmpty
        )

        // The picker commits a book row as the collection, not as the chapter
        // that happens to represent it in the list.
        #expect(
            StudioViewModel.notepadGroundingToken(sourceID: first.id, bookID: "book-how-life-works")
                == "book:book-how-life-works"
        )
        #expect(StudioViewModel.notepadGroundingToken(sourceID: "src-a", bookID: nil) == "src-a")
    }

    @Test("Docs source picker rows carry the drawn strings, not the source")
    func docsSourcePickerRowsAreFlat() async {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        let second = makeArticle(
            url: "Books/HowLifeWorks/02.xhtml",
            title: "Genes: What DNA Really Does",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 1
        )
        let article = makeArticle(
            url: "https://www.nytimes.com/chinese-peptides",
            title: "Chinese Peptides",
            sourceType: .article
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [second, first, article]

        let rows = await vm.artifactSourcePickerIndex().rows(matching: "")

        // One row per book plus one per ordinary source, and everything the row
        // draws is already a String — nothing here should have to reach back into
        // a StudioArticle while the list is being laid out.
        #expect(rows.count == 2)
        let book = rows.first { $0.bookID == "book-how-life-works" }
        #expect(book?.title == "How Life Works")
        #expect(book?.sourceID == first.id)
        #expect(book?.sourceType == StudioSourceType.book.rawValue)
        #expect(book?.subtitle == "Book · Philip Ball · 2 chapters")
        let plain = rows.first { $0.bookID == nil }
        #expect(plain?.sourceID == article.id)
        #expect(plain?.sourceType == StudioSourceType.article.rawValue)
        #expect(plain?.subtitle == "Article · www.nytimes.com")
    }

    @Test("The Docs source picker never offers a hidden source and finds a page by its own text")
    func sourcePickerSkipsHiddenAndMatchesContent() async {
        let vm = makeViewModel()
        var episode = makeArticle(
            url: "apple-podcast://episode/1000751939405",
            title: "AI Viruses, OpenAI's First Device",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts
        )
        episode.domain = "TBPN"
        var hidden = makeArticle(url: "https://example.com/hidden", title: "OpenAI hidden article", sourceType: .article)
        hidden.isHidden = true
        let shown = makeArticle(url: "https://example.com/shown", title: "OpenAI shown article", sourceType: .article)
        // An unscoped search reads the address and domain too, as the sidebar's
        // does, so this page's address names neither query.
        let byText = makeArticle(url: "https://health.example.org/public", title: "Public Data for Health", sourceType: .article)
        vm.articles = [episode, hidden, shown, byText]
        vm.hiddenPodcastShows = ["TBPN"]

        let index = await vm.artifactSourcePickerIndex()
        #expect(Set(index.rows(matching: "openai").map(\.sourceID)) == [shown.id])
        #expect(index.rows(matching: "direct data").isEmpty)
        let withContent = index.rows(matching: "direct data", contentMatchIDs: [byText.id, hidden.id])
        #expect(withContent.map(\.sourceID) == [byText.id])
    }

    @Test("Docs source type filters group unfinished URLs with articles")
    func docsSourceTypeFiltersUsePickerKinds() {
        #expect(ArtifactSourcePickerFilter.article.includes(sourceType: StudioSourceType.article.rawValue))
        #expect(ArtifactSourcePickerFilter.article.includes(sourceType: StudioSourceType.unclassified.rawValue))
        #expect(!ArtifactSourcePickerFilter.article.includes(sourceType: StudioSourceType.paper.rawValue))
        #expect(ArtifactSourcePickerFilter.link.includes(sourceType: StudioSourceType.manual.rawValue))
        #expect(ArtifactSourcePickerFilter.all.includes(sourceType: StudioSourceType.xPost.rawValue))
    }

    @Test("The Docs source picker index answers in title order and reuses unchanged analysis")
    func sourcePickerIndexIsTitleOrderedAndReused() async {
        let vm = makeViewModel()
        // Addresses that hold neither title: an unscoped search reads the address too.
        let zebra = makeArticle(url: "https://example.com/z-1", title: "Zebra", sourceType: .article)
        var apple = makeArticle(url: "https://example.com/a-2", title: "Apple", sourceType: .article)
        vm.articles = [zebra, apple]

        let first = await vm.artifactSourcePickerIndex()
        #expect(first.rows(matching: "").map(\.title) == ["Apple", "Zebra"])
        #expect(first.rows(matching: "example").map(\.title) == ["Apple", "Zebra"])

        // A renamed source is analysed afresh; the next opening finds the new title.
        apple.title = "Avocado"
        vm.articles = [zebra, apple]
        let second = await vm.artifactSourcePickerIndex()
        #expect(second.rows(matching: "avocado").map(\.sourceID) == [apple.id])
        #expect(second.rows(matching: "apple").isEmpty)
        #expect(second.rows(matching: "").map(\.title) == ["Avocado", "Zebra"])
    }

    @Test("The Docs source picker lists the title that is the query first and a source that only mentions it last")
    func sourcePickerRanksTitleMatchesFirst() async {
        let vm = makeViewModel()
        let exact = makeArticle(url: "https://example.com/1", title: "Revolution Postponed")
        let start = makeArticle(url: "https://example.com/2", title: "Revolution Postponed: Why the Genome Waited")
        let phrase = makeArticle(url: "https://example.com/3", title: "The Revolution Postponed Again")
        let terms = makeArticle(url: "https://example.com/4", title: "Postponed, a Revolution")
        // Named by its publication, not its title.
        var byDetails = makeArticle(url: "https://example.com/5", title: "Aardvark Notes")
        byDetails.domain = "Revolution Postponed Weekly"
        // Holds the words only in its own text.
        let byText = makeArticle(url: "https://example.com/6", title: "Abacus Hour")
        vm.articles = [byText, terms, byDetails, phrase, start, exact]

        let index = await vm.artifactSourcePickerIndex()
        let ranked = index.rows(matching: "revolution postponed", contentMatchIDs: [byText.id])
        #expect(ranked.map(\.sourceID) == [exact.id, start.id, phrase.id, terms.id, byDetails.id, byText.id])
        // Punctuation and case in the title do not cost it its place.
        #expect(index.rows(matching: "REVOLUTION postponed:").first?.sourceID == exact.id)
        // A query confined to the site is not ranked by the title it never asked about.
        #expect(index.rows(matching: "site:revolution postponed").map(\.sourceID) == [byDetails.id])
        // No query keeps the whole library in title order.
        #expect(index.rows(matching: "").first?.sourceID == byDetails.id)
    }

    @Test("The Docs source picker filters whole books by title and author")
    func notepadSourceSearchFiltersWholeBookMetadata() async {
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "Books/HowLifeWorks/01.xhtml",
            title: "The End of the Machine",
            sourceType: .book,
            parentGroup: "book-how-life-works",
            sortIndex: 0
        )
        vm.bookTitles = ["book-how-life-works": "How Life Works"]
        vm.bookAuthors = ["book-how-life-works": "Philip Ball"]
        vm.articles = [chapter]

        let index = await vm.artifactSourcePickerIndex()
        let byTitle = index.rows(matching: "life how works")
        let byAuthor = index.rows(matching: "ball philip")

        #expect(byTitle.map(\.title) == ["How Life Works"])
        #expect(byAuthor.map(\.title) == ["How Life Works"])
        #expect(byTitle.first?.sourceID == chapter.id)
        #expect(byTitle.first?.bookID == "book-how-life-works")
    }

    @Test("The Docs source picker only returns rows matching every typed term")
    func notepadSourceSearchStrictlyNarrowsResults() async {
        let vm = makeViewModel()
        var matching = makeArticle(title: "How Life Works")
        matching.author = "Philip Ball"
        var partial = makeArticle(title: "How Cells Work")
        partial.author = "Another Author"
        var unrelated = makeArticle(title: "The Gene")
        unrelated.author = "Siddhartha Mukherjee"
        vm.articles = [unrelated, partial, matching]

        let results = await vm.artifactSourcePickerIndex().rows(matching: "life ball")

        #expect(results.map(\.sourceID) == [matching.id])
    }

    @Test("partially hidden books still expose hidden chapters")
    func partiallyHiddenBooksExposeHiddenChapters() {
        let vm = makeViewModel()
        var hiddenChapter = makeArticle(url: "/books/example/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "Example Book")
        let visibleChapter = makeArticle(url: "/books/example/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "Example Book")
        hiddenChapter.isHidden = true
        vm.articles = [hiddenChapter, visibleChapter]

        #expect(vm.visibleBookGroupNames == ["Example Book"])
        #expect(vm.hiddenBookGroupNames.isEmpty)
        #expect(vm.hiddenBookChapterArticles.map(\.title) == ["Chapter 1"])
    }

    @Test("hasMoreItems returns true when items exceed displayLimit")
    func hasMoreItems() {
        let vm = makeViewModel()
        var arts: [StudioArticle] = []
        for i in 0..<50 {
            arts.append(makeArticle(url: "https://example.com/\(i)", title: "Art \(i)", sourceType: .article))
        }
        vm.articles = arts
        vm.sidebarTab = .articles
        vm.displayLimit = 40
        #expect(vm.hasMoreItems)
        #expect(vm.activeTabArticles.count == 40)
    }
}

@Suite("YouTube Transcript Caching")
@MainActor
struct YouTubeTranscriptCachingTests {

    @Test("opening a YouTube source treats blank content as a missing transcript")
    func blankContentAutomaticallyFetchesOnOpen() {
        var video = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Blank synced video",
            sourceType: .video,
            state: .ready
        )
        video.content = " \n\t "

        #expect(!StudioViewModel.sourceHasReadableContent(video))
        #expect(StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(video))

        video.content = "[0:00] Transcript text"
        #expect(StudioViewModel.sourceHasReadableContent(video))
        #expect(!StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(video))
    }

    @Test("opening a failed YouTube source waits for an explicit retry")
    func failedTranscriptDoesNotRetryOnEveryOpen() {
        var video = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Unavailable video",
            sourceType: .video,
            state: .error
        )
        video.content = ""
        video.errorMessage = "YouTube transcript unavailable."

        #expect(!StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(video))
    }

    @Test("a failed YouTube transcript fetch is stored, so a reload shows the error and not the queue")
    func failedTranscriptFetchIsPersisted() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMYouTubeFailureTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = StorageService(storeRoot: tmp)

        // A watch URL with no video id fails before any network request, so
        // the fetch takes the same failure path as a video without captions.
        let video = makeArticle(
            url: "https://www.youtube.com/watch",
            title: "Video without captions",
            sourceType: .video,
            state: .queued
        )
        try await service.saveSource(video)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()

        await vm.fetchYouTubeTranscript(for: video.id)

        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].errorMessage?.hasPrefix("YouTube transcript unavailable") == true)

        let reloaded = try await service.loadSources()
        #expect(reloaded.count == 1)
        #expect(reloaded[0].state == .error)
        #expect(reloaded[0].errorMessage?.hasPrefix("YouTube transcript unavailable") == true)
    }

    @Test("fetchYouTubeTranscript reuses persisted transcript from SQLite")
    func reusesPersistedTranscript() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMYouTubeCacheTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)

        let stored = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Cached Video",
            sourceType: .video,
            state: .ready
        )
        var persisted = stored
        persisted.content = "cached transcript text"
        persisted.wordCount = 3
        try await service.saveSource(persisted)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].content == nil)

        await vm.fetchYouTubeTranscript(for: stored.id)

        #expect(vm.articles[0].content == "cached transcript text")
        #expect(vm.articles[0].wordCount == 3)
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
    }

    @Test("a failed reformat keeps the transcript that was already stored")
    func failedReformatKeepsStoredTranscript() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMReformatTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)

        // A video ID that resolves to nothing, so the forced re-download fails
        // whether or not this machine is online.
        let stored = makeArticle(
            url: "https://www.youtube.com/watch?v=zzzzzzzzzzz",
            title: "Raw Captions",
            sourceType: .video,
            state: .ready
        )
        var persisted = stored
        persisted.content = "unformatted caption text"
        persisted.wordCount = 3
        try await service.saveSource(persisted)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()

        await vm.reformatYouTubeTranscript(for: stored.id)

        #expect(vm.articles[0].content == "unformatted caption text")
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
        let onDisk = await service.loadSourceContent(stored.id)
        #expect(onDisk == "unformatted caption text")
    }

    @Test("reformat ignores sources that are not YouTube videos")
    func reformatIgnoresNonYouTubeSources() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMReformatSkipTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        var article = makeArticle(url: "https://example.com/post", title: "Article", state: .ready)
        article.content = "body text"
        vm.articles = [article]

        await vm.reformatYouTubeTranscript(for: article.id)

        #expect(vm.articles[0].content == "body text")
        #expect(vm.articles[0].state == .ready)
    }

    @Test("fetchContent reuses persisted source content from SQLite before network fetch")
    func fetchContentUsesPersistedSourceContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMContentCacheTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)

        let stored = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Cached Video",
            sourceType: .video,
            state: .queued
        )
        var persisted = stored
        persisted.content = "sqlite cached transcript"
        persisted.wordCount = 3
        try await service.saveSource(persisted)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .queued)

        await vm.fetchContent(for: stored.id)

        #expect(vm.articles[0].content == "sqlite cached transcript")
        #expect(vm.articles[0].wordCount == 3)
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
    }
}

// MARK: - Source Context Management

@Suite("Source Context Management")
@MainActor
struct SourceContextManagementTests {

    @Test("addSourceToContext adds article ID")
    func addSourceToContext() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.addSourceToContext(a.id)
        #expect(vm.contextSourceIds.contains(a.id))
    }

    @Test("addSourceToContext does not duplicate")
    func addSourceNoDuplicate() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.addSourceToContext(a.id)
        vm.addSourceToContext(a.id)
        #expect(vm.contextSourceIds.filter { $0 == a.id }.count == 1)
    }

    @Test("removeSourceFromContext removes article ID")
    func removeSourceFromContext() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.contextSourceIds = [a.id]
        vm.removeSourceFromContext(a.id)
        #expect(!vm.contextSourceIds.contains(a.id))
    }

    @Test("toggleSourceContext toggles in")
    func toggleIn() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.toggleSourceContext(a.id)
        #expect(vm.contextSourceIds.contains(a.id))
    }

    @Test("toggleSourceContext toggles out")
    func toggleOut() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.contextSourceIds = [a.id]
        vm.toggleSourceContext(a.id)
        #expect(!vm.contextSourceIds.contains(a.id))
    }

    @Test("selectAllSources adds all visible article IDs")
    func selectAllSources() {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://1.com", title: "One", sourceType: .article)
        let a2 = makeArticle(url: "https://2.com", title: "Two", sourceType: .article)
        let paper = makeArticle(url: "https://p.com", title: "Paper", sourceType: .paper)
        vm.articles = [a1, a2, paper]
        vm.sidebarTab = .articles
        vm.selectAllSources()
        #expect(vm.contextSourceIds.contains(a1.id))
        #expect(vm.contextSourceIds.contains(a2.id))
        // Paper should not be included since it's not on the articles tab
        #expect(!vm.contextSourceIds.contains(paper.id))
    }

    @Test("clearSourceContext empties the array")
    func clearSourceContext() {
        let vm = makeViewModel()
        vm.contextSourceIds = ["a", "b", "c"]
        vm.clearSourceContext()
        #expect(vm.contextSourceIds.isEmpty)
    }

    @Test("contextSourceArticles resolves articles from IDs")
    func contextSourceArticles() {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://1.com", title: "One")
        let a2 = makeArticle(url: "https://2.com", title: "Two")
        vm.articles = [a1, a2]
        vm.contextSourceIds = [a1.id, a2.id]
        let resolved = vm.contextSourceArticles
        #expect(resolved.count == 2)
        #expect(resolved[0].id == a1.id)
        #expect(resolved[1].id == a2.id)
    }

    @Test("contextSourceArticles ignores IDs not in articles")
    func contextSourceArticlesIgnoresInvalid() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.contextSourceIds = [a.id, "nonexistent-id"]
        #expect(vm.contextSourceArticles.count == 1)
    }

    @Test("selected source IDs follow current display order")
    func selectedSourceIDsFollowCurrentDisplayOrder() {
        let vm = makeViewModel()
        let chapter8 = makeArticle(
            url: "Books/Test/Chapters/08.pdf",
            title: "8) Why Mitochondria Make Complexity Possible",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 8
        )
        let chapter7 = makeArticle(
            url: "Books/Test/Chapters/07.pdf",
            title: "7) Why Bacteria are Simple",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 7
        )
        let part3 = makeArticle(
            url: "Books/Test/Chapters/part-3.pdf",
            title: "Part 3 Insider Deal: The Foundations of Complexity",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 6
        )
        vm.articles = [chapter8, chapter7, part3]
        vm.sidebarTab = .books

        let ordered = vm.sourceIDsInCurrentDisplayOrder(Set([chapter8.id, chapter7.id, part3.id]))

        #expect(ordered == [part3.id, chapter7.id, chapter8.id])
    }

    @Test("addSourceToContext does not auto-fetch remote paper PDFs")
    func addRemotePaperToContextStaysPassive() {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://www.nature.com/articles/test-paper", title: "Nature paper", sourceType: .paper)
        vm.articles = [paper]

        vm.addSourceToContext(paper.id)

        #expect(vm.contextSourceIds.contains(paper.id))
        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].content == nil)
    }
}

@Suite("Paper Download Behavior")
@MainActor
struct PaperDownloadBehaviorTests {

    @Test("fetchContent does not auto-download remote paper PDFs")
    func fetchContentLeavesRemotePaperQueued() async {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://www.nature.com/articles/test-paper", title: "Nature paper", sourceType: .paper)
        vm.articles = [paper]

        await vm.fetchContent(for: paper.id)

        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].content == nil)
        #expect(vm.paperDownloadStep.isEmpty)
    }

    @Test("selectArticle does not auto-download remote paper PDFs")
    func selectArticleLeavesRemotePaperQueued() async {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://www.nature.com/articles/test-paper", title: "Nature paper", sourceType: .paper)
        vm.articles = [paper]

        await vm.selectArticle(paper.id)

        #expect(vm.selectedArticleId == paper.id)
        #expect(vm.contextSourceIds.isEmpty)
        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].content == nil)
    }

    @Test("processing local paper opens its original PDF without waiting for cleanup")
    func selectProcessingPaperOpensOriginalPDF() async throws {
        let pdfURL = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let vm = makeViewModel()
        var paper = makeArticle(
            url: pdfURL.path,
            title: "Paper being cleaned",
            sourceType: .paper,
            state: .fetching
        )
        paper.localFilePath = pdfURL.path
        vm.articles = [paper]
        vm.pendingPaperProcessingIds.insert(paper.id)
        vm.showReaderPanel = false

        await vm.selectArticle(paper.id)

        #expect(vm.selectedArticleId == paper.id)
        #expect(vm.showReaderPanel)
        #expect(vm.activeCenterTabs.contains(.reader))
        #expect(vm.selectedArticle?.isPDF == true)
        #expect(vm.selectedArticle?.localFilePath == pdfURL.path)
        #expect(vm.pendingPaperProcessingIds.contains(paper.id))
        #expect(vm.articles[0].state == .fetching)
    }

    @Test("selectArticle leaves existing context unchanged by default")
    func selectArticleLeavesContextUnchanged() async {
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First")
        // Content on the row keeps selectArticle from fetching
        // https://example.com for real: this test is about where the
        // selection lands, not about fetching.
        let second = makeArticle(url: "https://example.com/second", title: "Second").with(content: "Second, already read.")
        vm.articles = [first, second]
        vm.addSourceToContext(first.id)

        await vm.selectArticle(second.id)

        #expect(vm.selectedArticleId == second.id)
        #expect(vm.contextSourceIds == [first.id])
    }

    @Test("selectArticle issues a fresh reader navigation when reselecting the same source")
    func selectArticleRefreshesReaderNavigationOnReselection() async {
        let vm = makeViewModel()
        var article = makeArticle(url: "https://example.com/article", title: "Article")
        article.content = "Already loaded content"
        vm.articles = [article]

        #expect(vm.readerNavigationRevision(for: article.id) == 0)

        await vm.selectArticle(article.id)
        let firstRevision = vm.readerNavigationRevision(for: article.id)

        await vm.selectArticle(article.id)

        #expect(firstRevision == 1)
        #expect(vm.readerNavigationRevision(for: article.id) == 2)
        #expect(vm.selectedArticleId == article.id)
    }

    @Test("selectArticle can replace context when requested explicitly")
    func selectArticleExplicitlyReplacesContext() async {
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First")
        let second = makeArticle(url: "https://example.com/second", title: "Second").with(content: "Second, already read.")
        vm.articles = [first, second]
        vm.addSourceToContext(first.id)

        await vm.selectArticle(second.id, updateContext: true)

        #expect(vm.selectedArticleId == second.id)
        #expect(vm.contextSourceIds == [second.id])
    }

    @Test("paper download result carries metadata completeness")
    func paperDownloadResultCarriesMetadataCompleteness() {
        let result = StudioViewModel.PaperDownloadResult(
            success: true,
            lastError: nil,
            metadataComplete: false,
            debugLog: ["downloaded"]
        )

        #expect(result.success)
        #expect(result.metadataComplete == false)
    }
}

// MARK: - Chat Messages

// MARK: - Source Type and Metadata

@Suite("Source Type and Metadata")
@MainActor
struct SourceTypeMetadataTests {

    @Test("Moving a source between tabs via sourceType change")
    func moveSourceBetweenTabs() {
        let vm = makeViewModel()
        let article = makeArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        vm.articles = [article]

        // Initially on articles tab
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 1)
        vm.sidebarTab = .papers
        #expect(vm.activeTabArticles.count == 0)

        // Change source type to paper
        if let idx = vm.articles.firstIndex(where: { $0.id == article.id }) {
            vm.articles[idx].sourceType = .paper
        }

        vm.sidebarTab = .papers
        #expect(vm.activeTabArticles.count == 1)
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 0)
    }

    @Test("Paper metadata fields")
    func paperMetadataFields() {
        var article = makeArticle(url: "https://nature.com/article", sourceType: .paper)
        #expect(article.author == nil)
        #expect(article.journal == nil)
        #expect(article.publishedYear == nil)

        article.author = "Smith et al."
        article.journal = "Nature"
        article.publishedYear = "2024"

        #expect(article.author == "Smith et al.")
        #expect(article.journal == "Nature")
        #expect(article.publishedYear == "2024")
    }

    @Test("Manual sourceType appears under articles tab")
    func manualSourceTypeUnderArticles() {
        let vm = makeViewModel()
        let a = makeArticle(sourceType: .manual)
        vm.articles = [a]
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 1)
    }

    @Test("Podcast sourceType appears under podcasts tab")
    func podcastSourceType() {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://pod.com/ep1", sourceType: .podcast)
        vm.articles = [a]
        vm.sidebarTab = .podcasts
        #expect(vm.activeTabArticles.count == 1)
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 0)
    }

    @Test("Book sourceType appears under books tab")
    func bookSourceType() {
        let vm = makeViewModel()
        let a = makeArticle(url: "/path/to/chapter.pdf", sourceType: .book)
        vm.articles = [a]
        vm.sidebarTab = .books
        #expect(vm.activeTabArticles.count == 1)
    }
}

// MARK: - Search State

@Suite("Search State")
@MainActor
struct SearchStateTests {

    @Test("sourceSearchQuery default is empty")
    func sourceSearchQueryDefault() {
        let vm = makeViewModel()
        #expect(vm.sourceSearchQuery == "")
    }

    @Test("sourceSearchQuery can be set")
    func sourceSearchQuerySet() {
        let vm = makeViewModel()
        vm.sourceSearchQuery = "transformers"
        #expect(vm.sourceSearchQuery == "transformers")
    }

    @Test("sourceSearchResults default is empty")
    func sourceSearchResultsDefault() {
        let vm = makeViewModel()
        #expect(vm.sourceSearchResults.isEmpty)
    }

    @Test("hasSearchedSources default is false")
    func hasSearchedSourcesDefault() {
        let vm = makeViewModel()
        #expect(!vm.hasSearchedSources)
    }

    @Test("isSearchingSources default is false")
    func isSearchingSourcesDefault() {
        let vm = makeViewModel()
        #expect(!vm.isSearchingSources)
    }

    @Test("isSearchingSources can be toggled")
    func isSearchingSourcesToggle() {
        let vm = makeViewModel()
        vm.isSearchingSources = true
        #expect(vm.isSearchingSources)
        vm.isSearchingSources = false
        #expect(!vm.isSearchingSources)
    }
}

// MARK: - Panel Visibility

@Suite("Panel Visibility")
@MainActor
struct PanelVisibilityTests {

    @Test("reader starts docked and closed until a source is opened")
    func readerStartsDockedAndClosed() async {
        let vm = makeViewModel()
        #expect(!vm.showReaderPanel)
        #expect(!vm.readerPoppedOut)

        await vm.selectArticle("any-source-id")
        #expect(vm.showReaderPanel)
    }

    @Test("showReaderPanel toggle")
    func showReaderPanelToggle() {
        let vm = makeViewModel()
        let original = vm.showReaderPanel
        vm.showReaderPanel = !original
        #expect(vm.showReaderPanel == !original)
    }

    @Test("showSearchPanel toggle")
    func showSearchPanelToggle() {
        let vm = makeViewModel()
        let original = vm.showSearchPanel
        vm.showSearchPanel = !original
        #expect(vm.showSearchPanel == !original)
    }

    @Test("readerPoppedOut flag")
    func readerPoppedOut() {
        let vm = makeViewModel()
        vm.readerPoppedOut = true
        #expect(vm.readerPoppedOut)
        vm.readerPoppedOut = false
        #expect(!vm.readerPoppedOut)
    }

}

// MARK: - Derived State

@Suite("Derived State")
@MainActor
struct DerivedStateTests {

    @Test("selectedArticle resolves from selectedArticleId")
    func selectedArticleResolves() {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://sel.com", title: "Selected")
        vm.articles = [a]
        vm.selectedArticleId = a.id
        #expect(vm.selectedArticle?.title == "Selected")
    }

    @Test("selectedArticle is nil when no ID set")
    func selectedArticleNilNoId() {
        let vm = makeViewModel()
        vm.selectedArticleId = nil
        #expect(vm.selectedArticle == nil)
    }

    @Test("totalFilteredCount matches filtered items")
    func totalFilteredCount() {
        let vm = makeViewModel()
        var arts: [StudioArticle] = []
        for i in 0..<25 {
            arts.append(makeArticle(url: "https://example.com/\(i)", title: "Art \(i)", sourceType: .article))
        }
        vm.articles = arts
        vm.sidebarTab = .articles
        #expect(vm.totalFilteredCount == 25)
    }

    @Test("tabItemLabel returns lowercase tab name")
    func tabItemLabel() {
        let vm = makeViewModel()
        vm.sidebarTab = .articles
        #expect(vm.tabItemLabel == "articles")
        vm.sidebarTab = .papers
        #expect(vm.tabItemLabel == "papers")
    }

    @Test("tabItemLabel preserves brand casing")
    func tabItemLabelBrandCasing() {
        let vm = makeViewModel()
        vm.sidebarTab = .videos
        #expect(vm.tabItemLabel == "videos from YouTube")
        vm.sidebarTab = .xPosts
        #expect(vm.tabItemLabel == "X posts")
    }

    @Test("resumeBookChapter opens the first chapter when nothing has been read")
    func resumeBookChapterStartsAtFirstChapter() {
        let vm = makeViewModel()
        let ch1 = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "My Book", sortIndex: 1)
        let ch2 = makeArticle(url: "/books/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "My Book", sortIndex: 2)
        vm.articles = [ch1, ch2]

        #expect(vm.resumeBookChapter(for: "My Book")?.id == ch1.id)
    }

    @Test("resumeBookChapter opens the furthest chapter with saved progress")
    func resumeBookChapterUsesSavedProgress() {
        let vm = makeViewModel()
        var ch1 = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "My Book", sortIndex: 1)
        let ch2 = makeArticle(url: "/books/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "My Book", sortIndex: 2)
        var ch3 = makeArticle(url: "/books/ch3.pdf", title: "Chapter 3", sourceType: .book, parentGroup: "My Book", sortIndex: 3)
        ch1.readingPositionPage = 12
        ch3.readingPositionPage = 4
        vm.articles = [ch1, ch2, ch3]
        vm.seedReadingProgressFromArticles()

        #expect(vm.resumeBookChapter(for: "My Book")?.id == ch3.id)
    }

    @Test("resumeBookChapter prefers in-memory reading progress over stale article state")
    func resumeBookChapterUsesReadingProgressStore() {
        let vm = makeViewModel()
        let ch1 = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "My Book", sortIndex: 1)
        let ch2 = makeArticle(url: "/books/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "My Book", sortIndex: 2)
        vm.articles = [ch1, ch2]
        vm.updateReadingPosition(for: ch2.id, page: 7)

        #expect(vm.resumeBookChapter(for: "My Book")?.id == ch2.id)
        #expect(vm.resumeBookChapter(for: "My Book")?.readingPositionPage == 7)
    }

    @Test("selectBookGroup opens its resume chapter in Reader")
    func selectBookGroupOpensResumeChapterInReader() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let ch1 = makeArticle(
            url: "/books/ch1.pdf",
            title: "Chapter 1",
            sourceType: .book,
            parentGroup: "My Book",
            sortIndex: 1
        )
        let ch2 = makeArticle(
            url: "/books/ch2.pdf",
            title: "Chapter 2",
            sourceType: .book,
            parentGroup: "My Book",
            sortIndex: 2
        )
        vm.articles = [ch1, ch2]
        vm.updateReadingPosition(for: ch2.id, page: 7)
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .chat),
        ])

        await vm.selectBookGroup("My Book")

        #expect(vm.selectedArticleId == ch2.id)
        #expect(vm.selectedArticleIds == [ch2.id])
        #expect(vm.activeCenterTabs.contains(.reader))
    }
}

// MARK: - Error and Loading State

@Suite("Error and Loading State")
@MainActor
struct ErrorLoadingStateTests {

    @Test("errorMessage can be set and cleared")
    func errorMessage() {
        let vm = makeViewModel()
        #expect(vm.errorMessage == nil)
        vm.errorMessage = "Something went wrong"
        #expect(vm.errorMessage == "Something went wrong")
        vm.errorMessage = nil
        #expect(vm.errorMessage == nil)
    }

    @Test("isLoadingQueue defaults to false")
    func isLoadingQueueDefault() {
        let vm = makeViewModel()
        #expect(!vm.isLoadingQueue)
    }

    @Test("isGenerating defaults to false")
    func isGeneratingDefault() {
        let vm = makeViewModel()
        #expect(!vm.isGenerating)
    }

    @Test("isFetchingContent defaults to false")
    func isFetchingContentDefault() {
        let vm = makeViewModel()
        #expect(!vm.isFetchingContent)
    }

    @Test("missing paper PDF resolver defaults to idle")
    func missingPaperPDFResolverDefault() {
        let vm = makeViewModel()
        #expect(!vm.isResolvingMissingPaperPDFs)
    }

    @Test("missing paper PDF resolver stays idle without candidates")
    func missingPaperPDFResolverNoCandidates() {
        let vm = makeViewModel()
        vm.downloadMissingPaperPDFs()

        #expect(!vm.isResolvingMissingPaperPDFs)
        #expect(vm.toastMessage == "No papers need PDF attention")
    }

    @Test("stopping a paper batch does nothing when none is running")
    func stopPaperPDFResolutionWhenIdle() {
        let vm = makeViewModel()
        vm.stopPaperPDFResolution()

        #expect(!vm.isStoppingPaperPDFResolution)
    }

    @Test("a cancelled paywall recheck skips its remaining papers")
    func paywallRecheckStopsBeforeNextPaper() async {
        let vm = makeViewModel()
        // Stand in for a batch that is already running: the loop checks the stop
        // flag before each paper, so a pass started here does no paper work.
        vm.isResolvingMissingPaperPDFs = true
        vm.paperPDFResolutionKind = .paywallRecheck
        vm.stopPaperPDFResolution()
        #expect(vm.isStoppingPaperPDFResolution)

        await vm.runPaywalledPaperRecheck(for: ["paper-1", "paper-2"])

        #expect(vm.toastMessage?.contains("stopped after 0 of 2 papers") == true)
        #expect(!vm.isResolvingMissingPaperPDFs)
        #expect(vm.paperPDFResolutionKind == nil)
        #expect(!vm.isStoppingPaperPDFResolution)
        #expect(vm.paperDownloadStep.isEmpty)
    }

    @Test("toastMessage can be set")
    func toastMessage() {
        let vm = makeViewModel()
        #expect(vm.toastMessage == nil)
        vm.toastMessage = "PDF downloaded"
        #expect(vm.toastMessage == "PDF downloaded")
    }

    @Test("A short confirmation keeps the original three seconds")
    func shortToastKeepsFloor() {
        #expect(StudioViewModel.toastDuration(for: "Copied source ID") == .seconds(3))
    }

    /// The case that prompted the dwell change: a provider refusal names the model
    /// and the setting to change, and three seconds is not long enough to find the
    /// second sentence, let alone act on it.
    @Test("A provider refusal stays up long enough to read")
    func errorToastStaysReadable() {
        let message = """
        Couldn't read slides: deepseek/deepseek-v4-flash can't read images, and slides \
        are read from the image itself.

        Pick a vision-capable model under Settings → AI Models → Background → \
        Advanced → Slide Citation Extraction.

        The provider said: No endpoints found that support image input
        """
        #expect(StudioViewModel.toastDuration(for: message) > .seconds(12))
    }

    @Test("Dwell is capped so nothing sits on screen indefinitely")
    func longToastIsCapped() {
        let message = String(repeating: "diagnostic detail ", count: 200)
        #expect(StudioViewModel.toastDuration(for: message) == .seconds(20))
    }

    @Test("Dismissing clears the message")
    func dismissToastClearsMessage() {
        let vm = makeViewModel()
        vm.showToast("Something went wrong")
        #expect(vm.toastMessage == "Something went wrong")

        vm.dismissToast()
        #expect(vm.toastMessage == nil)
    }

    @Test("A plain toast offers no Undo, and dismissing drops a pending one")
    func toastUndoFollowsTheMessage() async {
        let vm = makeViewModel()
        vm.showToast("Link copied")
        #expect(vm.toastUndo == nil)
        await vm.undoToast()
        #expect(vm.toastMessage == "Link copied", "Undo with nothing to undo leaves the toast alone")

        var undone = false
        vm.showToast("Hid Paper", undo: { undone = true })
        #expect(vm.toastUndo != nil)
        vm.dismissToast()
        #expect(vm.toastUndo == nil)
        await vm.undoToast()
        #expect(!undone, "A dismissed toast's Undo is gone with it")

        vm.showToast("Hid Paper", undo: { undone = true })
        await vm.undoToast()
        #expect(undone)
        #expect(vm.toastMessage == nil)
    }

    /// Three seconds reads "Hid <title>" but leaves no time to regret it.
    @Test("A toast offering Undo stays up at least six seconds")
    func undoableToastDwellsLonger() {
        #expect(StudioViewModel.toastDuration(for: "Hid Paper") == .seconds(3))
        #expect(StudioViewModel.toastDuration(for: "Hid Paper", undoable: true) == .seconds(6))
        let long = String(repeating: "diagnostic detail ", count: 200)
        #expect(StudioViewModel.toastDuration(for: long, undoable: true) == .seconds(20))
    }

    /// A toast the pointer is resting on must not vanish mid-sentence, so hovering
    /// cancels the pending dismissal outright rather than shortening it.
    @Test("Hovering holds the toast open")
    func hoverHoldsToastOpen() {
        let vm = makeViewModel()
        vm.showToast("Something went wrong")

        vm.setToastHovered(true)
        #expect(vm.toastDismissTask == nil)
        #expect(vm.toastMessage == "Something went wrong")

        vm.setToastHovered(false)
        #expect(vm.toastDismissTask != nil)
    }
}

// MARK: - URL Input

@Suite("URL Input")
@MainActor
struct URLInputTests {

    @Test("urlInput defaults to empty")
    func urlInputDefault() {
        let vm = makeViewModel()
        #expect(vm.urlInput == "")
    }

    @Test("urlInput can be set")
    func urlInputSet() {
        let vm = makeViewModel()
        vm.urlInput = "https://new-article.com"
        #expect(vm.urlInput == "https://new-article.com")
    }
}

// MARK: - Source Type Conversion

@Suite("Source Type Conversion")
@MainActor
struct SourceTypeConversionTests {
    @Test("Changing sourceType updates article in array")
    func changeSourceType() async {
        let vm = makeViewModel()
        var article = StudioArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        article.normalizedURL = URLNormalizer.normalize(article.url)
        vm.articles = [article]

        vm.moveArticle(id:article.id, to: .paper)
        #expect(vm.articles[0].sourceType == .paper)
    }

    @Test("Changing sourceType to paper shows under papers tab")
    func convertedPaperInPapersTab() async {
        let vm = makeViewModel()
        var article = StudioArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        article.normalizedURL = URLNormalizer.normalize(article.url)
        vm.articles = [article]

        vm.moveArticle(id:article.id, to: .paper)
        vm.sidebarTab = .papers
        #expect(vm.activeTabArticles.contains(where: { $0.id == article.id }))
    }

    @Test("Changing sourceType to article shows under articles tab")
    func convertedArticleInArticlesTab() async {
        let vm = makeViewModel()
        var paper = StudioArticle(url: "https://example.com/paper", title: "A Paper", sourceType: .paper)
        paper.normalizedURL = URLNormalizer.normalize(paper.url)
        vm.articles = [paper]

        vm.moveArticle(id:paper.id, to: .article)
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.contains(where: { $0.id == paper.id }))
    }
}

@Suite("Initial content fetch")
struct InitialContentFetchTests {

    private func queuedArticle(id: String = "a1", url: String = "https://example.com/a") -> StudioArticle {
        var article = StudioArticle(url: url, title: "An article", sourceType: .article, id: id)
        article.state = .queued
        return article
    }

    /// The gap this exists to close: a source nobody opened was never fetched,
    /// never embedded, and so invisible to search and the assistant while still
    /// sitting in the library looking like part of the knowledge base.
    @Test("a queued web source with no content is picked up")
    func queuedWebSourceIsCandidate() {
        #expect(StudioViewModel.sourceNeedsInitialContentFetch(queuedArticle(), alreadyAttempted: []))
    }

    @Test("a source that already has content or has been fetched is left alone")
    func fetchedSourcesAreNotCandidates() {
        var ready = queuedArticle()
        ready.state = .ready
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(ready, alreadyAttempted: []))

        var withContent = queuedArticle()
        withContent.content = "already here"
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(withContent, alreadyAttempted: []))

        // A failed fetch sets .error, which drops it from the candidate set for
        // good rather than retrying forever.
        var failed = queuedArticle()
        failed.state = .error
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(failed, alreadyAttempted: []))
    }

    @Test("a Figshare source failed by the old empty WAF response is repaired")
    func failedFigshareSourceIsCandidate() {
        var failed = queuedArticle(
            id: "figshare",
            url: "https://plus.figshare.com/collections/Human_Biofluid_Image_Inventory/8260588/1"
        )
        failed.title = "plus.figshare.com"
        failed.state = .error

        #expect(StudioViewModel.sourceNeedsInitialContentFetch(failed, alreadyAttempted: []))
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(failed, alreadyAttempted: ["figshare"]))
    }

    /// Papers have their own sweep, which understands PDF resolution, paywalls,
    /// and duplicate detection. The generic content path understands none of
    /// that, so it must not race it.
    @Test("papers are left to their own sweep")
    func papersAreExcluded() {
        var paper = queuedArticle(id: "p1", url: "https://example.com/p.pdf")
        paper.sourceType = .paper
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(paper, alreadyAttempted: []))
    }

    @Test("remote course PDFs are proactively fetched as course materials")
    func coursePDFsAreCandidates() {
        var material = queuedArticle(
            id: "assignment",
            url: "https://example.com/assignment.pdf"
        )
        material.sourceType = .course
        #expect(StudioViewModel.sourceNeedsInitialContentFetch(material, alreadyAttempted: []))
    }

    @Test("local documents have nothing to fetch")
    func localDocumentsAreExcluded() {
        let local = queuedArticle(id: "l1", url: "/Users/someone/Documents/note.md")
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(local, alreadyAttempted: []))
    }

    /// The per-session guard is what keeps a source that fails or hangs from
    /// being retried on every sweep for the rest of the session.
    @Test("a source already attempted this session is not retried")
    func attemptedSourcesAreSkipped() {
        let article = queuedArticle()
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(article, alreadyAttempted: ["a1"]))
    }
}

@Suite("Paper metadata ingestion candidates")
struct PaperMetadataIngestionCandidateTests {
    @Test("Paper content without an LLM attestation is queued for metadata extraction")
    func unattestedPaperContentIsCandidate() {
        var paper = StudioArticle(
            url: "https://example.com/paper",
            title: "A Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026",
            id: "paper-candidate"
        )
        paper.content = "The first page of the scholarly paper, including its abstract."

        #expect(
            StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: []
            )
        )
        #expect(
            !StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: [paper.id]
            )
        )

        let attested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        #expect(
            !StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: []
            )
        )
    }

    @Test("A title without paper content cannot enter the LLM ingestion queue")
    func titleAloneIsNotPaperContent() {
        let paper = StudioArticle(
            url: "https://example.com/paper",
            title: "A Very Informative Paper Title",
            sourceType: .paper,
            id: "title-only-paper"
        )

        #expect(
            !StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: []
            )
        )
    }
}


/// The unit tests run inside the app host, whose own Studio window registers
/// itself and — on the default layout — is showing Reader. Take the registry
/// down to just the windows under test, then hand the host's back, so a real
/// window on the machine cannot change what these tests observe.
@MainActor
private func capturedStudioWindowRegistry() -> () -> Void {
    let existing = StudioWindowRegistry.shared.states
    let active = StudioWindowRegistry.shared.activeState
    existing.forEach { StudioWindowRegistry.shared.unregister($0) }
    return {
        existing.forEach { StudioWindowRegistry.shared.register($0) }
        if let active { StudioWindowRegistry.shared.activate(active) }
    }
}

@Suite("Cross-window Reader Navigation", .serialized)
@MainActor
struct CrossWindowReaderNavigationTests {
    @Test("a citation opens here even when the other window has the Reader up")
    func linkedSourceNeverJumpsToTheOtherWindow() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState(snapshot: .init(
            centerTabGroups: ["!|reader*|tasks|notepad|notebooks", "chat*"],
            navigationRailVisible: true
        ))
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        var source = makeArticle(
            url: "https://example.com/other-window-source",
            title: "Other Window Source",
            state: .ready,
            id: "other-window-source"
        )
        source.content = "Already loaded."
        vm.articles = [source]
        // This window is all Chat, and the other one is reading — pinned, at
        // that. The click still belongs to this window: the Reader is wedged
        // in beside Chat here, and the other window is left alone.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        let layoutThere = there.centerTabGroups

        await vm.openLinkedSourceInReader(source.id)

        #expect(here.readerArticleID == source.id)
        #expect(here.centerTabGroups.groups.contains { $0.activeTab == .reader })
        #expect(here.centerTabGroups.groups.contains { $0.activeTab == .chat })
        #expect(there.readerArticleID == nil)
        #expect(there.centerTabGroups == layoutThere)
        #expect(vm.toastAction == nil)
    }

    @Test("a web citation opens here even when the other window has the Reader up")
    func webCitationNeverJumpsToTheOtherWindow() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState(snapshot: .init(
            centerTabGroups: ["!|reader*|tasks|notepad|notebooks", "chat*"],
            navigationRailVisible: true
        ))
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        let url = URL(string: "https://example.com/a-web-citation")!

        vm.openWebCitationInReader(url, title: "A web citation")

        #expect(here.externalReaderPage?.url == url)
        #expect(there.externalReaderPage == nil)
        #expect(vm.toastAction == nil)
    }

    @Test("a citation stays in this window when it is the one reading")
    func linkedSourceKeepsAWindowThatIsAlreadyReading() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState(snapshot: .init(
            centerTabGroups: ["reader*|tasks|notepad|notebooks", "chat*"],
            navigationRailVisible: true
        ))
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        var source = makeArticle(
            url: "https://example.com/this-window-source",
            title: "This Window Source",
            state: .ready,
            id: "this-window-source"
        )
        source.content = "Already loaded."
        vm.articles = [source]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks, .activity, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
        ])

        await vm.openLinkedSourceInReader(source.id)

        // A Reader already on screen here is the nearest one; sending the
        // source to another display would be the surprise.
        #expect(here.readerArticleID == source.id)
        #expect(there.readerArticleID == nil)
        #expect(vm.toastMessage == nil)
    }

    @Test("a click here leaves the source the other window was already reading")
    func selectionDoesNotFollowIntoAWindowOpenedWhileReading() async {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        StudioWindowRegistry.shared.register(here, makeActive: true)
        defer { StudioWindowRegistry.shared.unregister(here) }

        await vm.selectArticle("first-source")

        // A second window opened while the first one was reading. It has made no
        // choice of its own yet, so it shows what the app-wide selection points
        // at — the source over here.
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(there)
        defer { StudioWindowRegistry.shared.unregister(there) }
        #expect(there.readerSourceID(fallingBackTo: vm.selectedArticleId) == "first-source")

        await vm.selectArticle("second-source")

        // The next click belongs to this window alone. Before the fix, the other
        // window followed the global selection and opened the same source too.
        #expect(here.readerArticleID == "second-source")
        #expect(there.readerSourceID(fallingBackTo: vm.selectedArticleId) == "first-source")
    }

    @Test("a click here does not fill the other window's empty Reader")
    func selectionDoesNotFillAnEmptyReaderElsewhere() async {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }

        await vm.selectArticle("only-source")

        #expect(here.readerArticleID == "only-source")
        #expect(there.readerSourceID(fallingBackTo: vm.selectedArticleId) == nil)
    }

    @Test("sending a source to another window leaves this one where it was")
    func sendingASourceElsewhereKeepsThisWindowReading() async {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        // This window is reading the legacy way: no local choice of its own, so
        // it renders whatever the app-wide selection points at.
        vm.selectedArticleId = "reading-here"

        await vm.selectArticle("sent-there", in: there)

        #expect(here.readerSourceID(fallingBackTo: vm.selectedArticleId) == "reading-here")
        #expect(there.readerArticleID == "sent-there")
    }

    @Test("a click here does not highlight the row in the other window's list")
    func sidebarSelectionStaysInItsOwnWindow() async {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        there.sidebarSelectedSourceIDs = ["reading-there"]

        // The sidebar's List binding writes the clicked row through the view
        // model's bridge, which reaches the key window and nothing else.
        vm.selectedArticleIds = ["clicked-here"]
        await vm.selectArticle("clicked-here")

        #expect(here.sidebarSelectedSourceIDs == ["clicked-here"])
        // Before the fix this row went grey over there too: one app-wide set fed
        // every window's list.
        #expect(there.sidebarSelectedSourceIDs == ["reading-there"])
    }

    @Test("sending a source to another window highlights it in that window's list")
    func sendingASourceElsewhereSelectsItsRowThere() async {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        here.sidebarSelectedSourceIDs = ["reading-here"]

        await vm.selectArticle("sent-there", in: there)

        #expect(there.sidebarSelectedSourceIDs == ["sent-there"])
        #expect(here.sidebarSelectedSourceIDs == ["reading-here"])
    }

    @Test("a source leaving the library leaves every window's selection")
    func removedSourcesAreDeselectedInEveryWindow() {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        here.sidebarSelectedSourceIDs = ["removed", "kept-here"]
        there.sidebarSelectedSourceIDs = ["removed", "kept-there"]

        vm.deselectSourcesInEveryWindow(["removed"])

        #expect(here.sidebarSelectedSourceIDs == ["kept-here"])
        #expect(there.sidebarSelectedSourceIDs == ["kept-there"])
    }

    @Test("clicking past every row closes this window's Reader and no other")
    func closingTheReaderHereLeavesTheOtherWindowReading() {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = vm.activeWindowState
        StudioWindowRegistry.shared.register(here, makeActive: true)
        defer { StudioWindowRegistry.shared.unregister(here) }
        vm.selectedArticleId = "shared-source"
        here.sidebarSelectedSourceIDs = ["shared-source"]
        // A second window opened while this one was reading. It has made no
        // choice of its own, so it shows the app-wide selection too.
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(there)
        defer { StudioWindowRegistry.shared.unregister(there) }
        #expect(there.readerSourceID(fallingBackTo: vm.selectedArticleId) == "shared-source")

        vm.closeReader(in: here)

        #expect(here.readerSourceID(fallingBackTo: vm.selectedArticleId) == nil)
        #expect(here.sidebarSelectedSourceIDs.isEmpty)
        #expect(there.readerSourceID(fallingBackTo: vm.selectedArticleId) == "shared-source")
    }
}

/// Two Studio windows browse the same library through two Library panes.
/// The tab, the search, the filters and the page each window is on are its
/// own; only the library underneath is shared.
@Suite("Cross-window Library list", .serialized)
@MainActor
struct CrossWindowSidebarStateTests {
    /// The view model's own accessors answer for the key window — the fallback
    /// state under test — so `here` is always the window being acted in and
    /// `there` is the one that must be left alone.
    private func makeTwoWindows() -> (vm: StudioViewModel, here: StudioWindowState, there: StudioWindowState, restore: () -> Void) {
        let restoreRegistry = capturedStudioWindowRegistry()
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        return (vm, here, there, {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
            restoreRegistry()
        })
    }

    @Test("switching tabs here leaves the other window on its tab")
    func switchingTabsHereLeavesTheOtherWindowsTab() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        vm.inWindow(there) { vm.switchTab(to: .podcasts) }

        vm.switchTab(to: .papers)

        #expect(here.sidebarStore.sidebarTab == .papers)
        #expect(there.sidebarStore.sidebarTab == .podcasts)
        #expect(vm.sidebarTab == .papers)
        #expect(vm.scoped(to: there).sidebarTab == .podcasts)
    }

    @Test("a search and a filter typed here stay out of the other window")
    func searchAndFiltersStayInTheirWindow() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        vm.scoped(to: there).articleOriginFilter = .safari
        vm.scoped(to: there).displayLimit = 120

        vm.searchText = "quantum"
        vm.sourceReadFilter = .unread

        #expect(here.sidebarStore.searchText == "quantum")
        #expect(here.sidebarStore.sourceReadFilter == .unread)
        #expect(here.sidebarStore.articleOriginFilter == nil)
        #expect(here.sidebarStore.displayLimit == 40)
        #expect(there.sidebarStore.searchText == "")
        #expect(there.sidebarStore.sourceReadFilter == .all)
        #expect(there.sidebarStore.articleOriginFilter == .safari)
        #expect(there.sidebarStore.displayLimit == 120)
    }

    @Test("each window lists the sources of its own tab")
    func eachWindowListsItsOwnTab() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        vm.articles = [
            makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1"),
            makeArticle(url: "https://a.example/paper", sourceType: .paper, id: "paper-1"),
        ]
        vm.switchTab(to: .videos)
        vm.inWindow(there) { vm.switchTab(to: .papers) }

        #expect(vm.visibleSidebarSourceIDs == ["video-1"])
        #expect(vm.scoped(to: here).visibleSidebarSourceIDs == ["video-1"])
        #expect(vm.scoped(to: there).visibleSidebarSourceIDs == ["paper-1"])
        #expect(vm.scoped(to: there).activeTabArticles.map(\.id) == ["paper-1"])
        // Reading the other window's list did not move this one's tab.
        #expect(here.sidebarStore.sidebarTab == .videos)
        #expect(vm.activeWindowState === here)
    }

    @Test("a search here prunes this window's selection and no other")
    func searchPrunesOnlyItsOwnWindowsSelection() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        vm.articles = [
            makeArticle(url: "https://youtu.be/abc", title: "Alpha", sourceType: .video, id: "video-1"),
            makeArticle(url: "https://youtu.be/def", title: "Beta", sourceType: .video, id: "video-2"),
        ]
        vm.switchTab(to: .videos)
        vm.inWindow(there) { vm.switchTab(to: .videos) }
        here.sidebarSelectedSourceIDs = ["video-1"]
        there.sidebarSelectedSourceIDs = ["video-1"]

        vm.inWindow(there) {
            vm.searchText = "Beta"
            vm.pruneSelectionToVisibleSources()
        }

        #expect(there.sidebarSelectedSourceIDs.isEmpty)
        #expect(vm.scoped(to: there).visibleSidebarSourceIDs == ["video-2"])
        #expect(here.sidebarSelectedSourceIDs == ["video-1"])
        #expect(vm.visibleSidebarSourceIDs == ["video-1", "video-2"])
    }

    @Test("a library change empties every window's list cache")
    func libraryChangeInvalidatesEveryWindowsCache() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.inWindow(there) { vm.switchTab(to: .videos) }
        _ = vm.scoped(to: here).activeTabArticles
        _ = vm.scoped(to: there).activeTabArticles
        #expect(here.sidebarStore.filteredSidebarCache != nil)
        #expect(there.sidebarStore.filteredSidebarCache != nil)

        vm.invalidateFilteredSidebarCache()

        #expect(here.sidebarStore.filteredSidebarCache == nil)
        #expect(there.sidebarStore.filteredSidebarCache == nil)

        vm.articles.append(makeArticle(url: "https://youtu.be/def", sourceType: .video, id: "video-2"))

        #expect(vm.scoped(to: there).visibleSidebarSourceIDs == ["video-1", "video-2"])
        #expect(vm.scoped(to: here).visibleSidebarSourceIDs == ["video-1", "video-2"])
    }

    @Test("unpinning a tab moves every window that was showing it")
    func hidingATabMovesEveryWindowOffIt() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        let priorHiddenTabs = vm.hiddenTabs
        defer { vm.hiddenTabs = priorHiddenTabs }
        vm.hiddenTabs = []
        vm.switchTab(to: .videos)
        vm.inWindow(there) { vm.switchTab(to: .videos) }

        vm.hideTab(.videos)

        #expect(vm.hiddenTabs.contains(.videos))
        #expect(here.sidebarStore.sidebarTab != .videos)
        #expect(there.sidebarStore.sidebarTab != .videos)
        #expect(vm.activeWindowState === here)
    }

    @Test("a window scope is restored after the call, even a nested one")
    func windowScopeIsRestored() {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }

        vm.inWindow(there) {
            #expect(vm.activeWindowState === there)
            vm.inWindow(here) {
                #expect(vm.activeWindowState === here)
            }
            #expect(vm.activeWindowState === there)
        }

        #expect(vm.activeWindowState === here)
        #expect(vm.sidebarStore === here.sidebarStore)
    }

    @Test("content-search matches are cleared in the window that searched")
    func contentSearchClearsInItsOwnWindow() async {
        let (vm, here, there, restore) = makeTwoWindows()
        defer { restore() }
        here.sidebarStore.contentSearchMatchIDs = ["kept-here"]
        there.sidebarStore.contentSearchMatchIDs = ["stale-there"]
        there.sidebarStore.searchText = ""

        await vm.refreshSidebarContentSearchMatches(in: there)

        #expect(there.sidebarStore.contentSearchMatchIDs.isEmpty)
        #expect(here.sidebarStore.contentSearchMatchIDs == ["kept-here"])
    }
}

// MARK: - Event-triggered plugin sync

@MainActor
private func makePluginSyncViewModel() -> StudioViewModel {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginSyncTests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return StudioViewModel(storageService: StorageService(storeRoot: tmp))
}

/// The cooldown that keeps an app activation or a scroll to the top from
/// re-running every remote sync and its backfills. On 2026-09-02 the production
/// log showed the X bookmark sync, the Liked-videos sync, and both backfills
/// repeating every 50 to 70 seconds, because the gate was 30 seconds per event
/// scope and an activation ("all") and a tab switch ("X") had separate clocks.
@Suite("Event-triggered plugin sync")
@MainActor
struct EventPluginSyncTests {
    private typealias Plugin = StudioViewModel.EventSyncPlugin

    private func due(
        _ tab: StudioSidebarTab?,
        _ lastSyncedAt: [Plugin: Date],
        now: Date,
        screenRecordMode: Bool = false
    ) -> Set<Plugin> {
        StudioViewModel.dueEventPlugins(
            for: tab,
            lastSyncedAt: lastSyncedAt,
            now: now,
            screenRecordMode: screenRecordMode
        )
    }

    @Test("A plugin that never synced is due; one that just did is not")
    func neverSyncedIsDue() {
        let now = Date()
        #expect(due(nil, [:], now: now) == Set(Plugin.allCases))
        #expect(due(.xPosts, [:], now: now) == [.xBookmarks])

        let justNow: [Plugin: Date] = [
            .xBookmarks: now.addingTimeInterval(-10),
            .browserReadingLists: now.addingTimeInterval(-10),
        ]
        #expect(due(.xPosts, justNow, now: now).isEmpty)
        #expect(due(.articles, justNow, now: now).isEmpty)
        #expect(due(.papers, justNow, now: now).isEmpty)
        #expect(due(nil, justNow, now: now) == [.youtube, .googleDriveMeetings, .applePodcasts])
    }

    @Test("A remote plugin waits minutes between event syncs; a local store waits seconds")
    func remoteAndLocalCooldownsDiffer() {
        let now = Date()
        let aMinuteAgo = Dictionary(
            uniqueKeysWithValues: Plugin.allCases.map { ($0, now.addingTimeInterval(-60)) }
        )
        #expect(due(nil, aMinuteAgo, now: now) == [.browserReadingLists, .applePodcasts])

        let sixMinutesAgo = Dictionary(
            uniqueKeysWithValues: Plugin.allCases.map { ($0, now.addingTimeInterval(-6 * 60)) }
        )
        #expect(due(nil, sixMinutesAgo, now: now) == Set(Plugin.allCases))
    }

    @Test("An activation followed by opening the X tab is one X sync, not two")
    func activationAndTabSwitchShareOneClock() {
        let vm = makePluginSyncViewModel()
        let now = Date()
        let activation = due(nil, vm.lastPluginSyncAt, now: now)
        #expect(activation.contains(.xBookmarks))
        vm.markPluginsSyncing(activation, at: now)

        #expect(due(.xPosts, vm.lastPluginSyncAt, now: now.addingTimeInterval(20)).isEmpty)
        #expect(due(.videos, vm.lastPluginSyncAt, now: now.addingTimeInterval(20)).isEmpty)
        #expect(due(nil, vm.lastPluginSyncAt, now: now.addingTimeInterval(20)).isEmpty)
    }

    @Test("Screen Record mode checks X and Reading Lists again on returning from the browser")
    func recordingBrowserCaptureSyncsImmediately() {
        let now = Date()
        let justNow = Dictionary(
            uniqueKeysWithValues: Plugin.allCases.map { ($0, now) }
        )

        #expect(due(nil, justNow, now: now, screenRecordMode: true) == [.xBookmarks, .browserReadingLists])
        #expect(due(.xPosts, justNow, now: now, screenRecordMode: true) == [.xBookmarks])
        #expect(due(.articles, justNow, now: now, screenRecordMode: true) == [.browserReadingLists])
    }

    @Test("Tabs with nothing upstream sync nothing")
    func tabsWithoutPlugins() {
        let now = Date()
        #expect(due(.books, [:], now: now).isEmpty)
    }

    @Test("A video YouTube refused to describe is not asked about again")
    func unavailableVideosLeaveTheChannelBackfill() {
        let vm = makePluginSyncViewModel()
        var unnamed = StudioArticle(
            url: "https://www.youtube.com/watch?v=PrivateVid1",
            title: "A private lecture",
            sourceType: .video
        )
        unnamed.domain = "www.youtube.com"
        unnamed.state = .ready
        var named = StudioArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "A public lecture",
            sourceType: .video
        )
        named.domain = "Alon Lab"
        named.state = .ready
        vm.articles = [unnamed, named]

        #expect(vm.videoChannelBackfillCandidates().map(\.videoId) == ["PrivateVid1"])

        // What the backfill records when YouTube's player has no public video
        // there either. oEmbed's 401 alone is not enough: it answers that for a
        // public video whose embedding is off too (`YouTubeVideoMetadataLookupTests`).
        vm.videoChannelBackfillUnavailableVideoIDs.insert("PrivateVid1")
        #expect(vm.videoChannelBackfillCandidates().isEmpty)
    }
}

// MARK: - Presentation equality

/// `articles.didSet` rebuilds every window's sidebar only when this says the
/// rows changed. Loaded text must not count, or a chat send hydrating one
/// transcript costs a library-wide re-filter on the main thread.
@Suite("Studio article presentation equality")
struct StudioArticlePresentationEqualityTests {
    @Test func loadingTextIsNotAPresentationChange() {
        let before = makeArticle(title: "Lecture", sourceType: .video, state: .ready, id: "v1")
        var after = before
        after.content = String(repeating: "transcript ", count: 2_000)
        after.rawArticleContentForPersistence = "raw"
        #expect(StudioArticle.presentationEquals([before], [after]))
        #expect(before.hasSamePresentation(as: after))
    }

    @Test func visibleFieldsAndMembershipAre() {
        let article = makeArticle(title: "Lecture", sourceType: .video, state: .ready, id: "v1")
        var renamed = article
        renamed.title = "Renamed"
        var fetching = article
        fetching.state = .fetching
        var counted = article
        counted.wordCount = 18_406
        #expect(!StudioArticle.presentationEquals([article], [renamed]))
        #expect(!StudioArticle.presentationEquals([article], [fetching]))
        #expect(!StudioArticle.presentationEquals([article], [counted]))
        #expect(!StudioArticle.presentationEquals([article], [article, article]))
        #expect(!StudioArticle.presentationEquals([article], []))
        #expect(StudioArticle.presentationEquals([], []))
    }

    @Test func sourceDownloadDetailNamesTheSource() {
        #expect(StudioViewModel.sourceDownloadDetail(title: " PSW 2538 Mitochondria ") == "Downloading PSW 2538 Mitochondria")
        #expect(StudioViewModel.sourceDownloadDetail(title: "") == "Downloading a source")
        #expect(StudioViewModel.sourceDownloadDetail(title: nil) == "Downloading a source")
    }
}

@Suite("Chat requests target the window they were made in")
@MainActor
struct ChatRequestWindowTargetTests {
    @Test("a New chat made in one window is not for the other window's pane")
    func newChatRequestIsScopedToItsWindow() {
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        vm.inWindow(there) { vm.requestBlankReviewChat() }
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.reviewChatTargetWindowID == there.id)
        #expect(vm.chatPaneAcceptsGlobalRequests(ownerWindowID: there.id))
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: here.id))
        // A pane that does not know its window keeps accepting, as before.
        #expect(vm.chatPaneAcceptsGlobalRequests(ownerWindowID: nil))
    }

    @Test("opening a chat row stamps its window too, and the key window is the default")
    func openChatRequestDefaultsToTheKeyWindow() {
        let vm = makeViewModel()
        let here = vm.activeWindowState
        vm.requestResumeReviewSession("session-1")
        #expect(vm.reviewChatTargetWindowID == here.id)
        let there = StudioWindowState()
        vm.inWindow(there) { vm.requestResumeReviewSession("session-2") }
        #expect(vm.reviewChatResumeSessionID == "session-2")
        #expect(vm.reviewChatTargetWindowID == there.id)
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: here.id))
    }

    @Test("a request made before any window was stamped is accepted everywhere")
    func unstampedRequestIsAcceptedEverywhere() {
        let vm = makeViewModel()
        #expect(vm.reviewChatTargetWindowID == nil)
        #expect(vm.chatPaneAcceptsGlobalRequests(ownerWindowID: StudioWindowState().id))
    }

    @Test("a reader selection and a doc attachment stamp their window like the request tokens")
    func selectionAndAttachmentRequestsAreScopedToTheirWindow() {
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()
        vm.inWindow(there) {
            vm.requestReaderSelectionExplanation(sourceID: "source-1", selectedText: "A passage worth asking about.")
        }
        #expect(vm.readerSelectionExplanationRequest?.selectedText == "A passage worth asking about.")
        #expect(vm.reviewChatTargetWindowID == there.id)
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: here.id))
        #expect(vm.toastMessage == "Selection added to Chat")

        vm.inWindow(here) { vm.revealReviewSessionSidebar() }
        #expect(vm.reviewChatTargetWindowID == here.id)
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: there.id))
    }

    @Test("Walk Through is for the window it was pressed in, not whichever pane runs first")
    func walkthroughPlaybackRequestIsScopedToItsWindow() {
        let vm = makeViewModel()
        let here = vm.activeWindowState
        let there = StudioWindowState()

        vm.inWindow(there) { vm.requestWalkthroughPlayback(for: "paper-1") }
        #expect(vm.readerWalkthroughPlayRequest?.sourceID == "paper-1")
        #expect(vm.reviewChatTargetWindowID == there.id)
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: here.id))

        vm.inWindow(here) { vm.requestWalkthroughPlayback(forAnimation: "artifact-1") }
        #expect(vm.readerWalkthroughPlayRequest?.isAnimation == true)
        #expect(vm.reviewChatTargetWindowID == here.id)
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: there.id))
    }
}

/// Where a chat request shows when the window it was made in cannot show it, or
/// when it was made in no Studio window at all — and that the learner is told.
@Suite("Chat requests say where they went", .serialized)
@MainActor
struct ChatRequestElsewhereNoticeTests {
    /// Three pinned panes with Chat parked behind the first: the one layout in
    /// which `activateCenterTab(.chat)` refuses rather than replaces.
    private static let everyPanePinnedChatParked = [
        "!|reader*|tasks|chat", "!|notepad*", "!|notebooks*",
    ]
    private static let showingChat = ["chat*", "reader*|tasks|notepad|notebooks"]

    private func window(_ layout: [String]) -> StudioWindowState {
        StudioWindowState(snapshot: .init(
            centerTabGroups: layout,
            navigationRailVisible: true
        ))
    }

    @Test("a New chat in a window that cannot show Chat stays here and releases Chat's pin")
    func newChatNeverJumpsToTheWindowShowingChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = window(Self.everyPanePinnedChatParked)
        let there = window(Self.showingChat)
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        let layoutThere = there.centerTabGroups

        #expect(!vm.canRevealCenterTab(.chat, in: here))
        vm.inWindow(here) { vm.requestBlankReviewChat() }

        // The click belongs to this window even though every pane here is
        // pinned and the other window already shows Chat: Chat's pane gives
        // up its pin, and nothing moves over there.
        #expect(vm.reviewChatTargetWindowID == here.id)
        #expect(vm.chatPaneAcceptsGlobalRequests(ownerWindowID: here.id))
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: there.id))
        #expect(vm.chatRequestElsewhereNotice == nil)
        #expect(vm.toastMessage == nil)
        #expect(vm.canRevealCenterTab(.chat, in: here))
        #expect(here.centerTabGroups.groups.contains { $0.tabs.contains(.chat) && !$0.isPinned })
        #expect(there.centerTabGroups == layoutThere)
    }

    @Test("a New chat in a window that can show Chat stays there, without a word")
    func newChatStaysInItsOwnWindow() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        // Chat parked behind a pinned Reader, but with room for a second pane.
        let here = window(["!|reader*|tasks|notepad|notebooks|chat"])
        let there = window(Self.showingChat)
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }

        vm.inWindow(here) { vm.requestBlankReviewChat() }

        #expect(vm.reviewChatTargetWindowID == here.id)
        #expect(vm.chatRequestElsewhereNotice == nil)
        #expect(vm.toastMessage == nil)
        #expect(here.centerTabGroups.groups.contains { $0.activeTab == .chat })
    }

    @Test("a selection sent from a window that cannot show Chat stays here")
    func selectionNeverJumpsToTheOtherWindow() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = window(Self.everyPanePinnedChatParked)
        let there = window(Self.showingChat)
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }

        vm.inWindow(here) {
            vm.requestReaderSelectionExplanation(sourceID: "source-1", selectedText: "A passage.")
        }

        #expect(vm.reviewChatTargetWindowID == here.id)
        #expect(vm.toastMessage == "Selection added to Chat")
    }

    @Test("a request from a popped-out Reader lands in the Studio window used last and says so")
    func detachedWindowRequestIsAnnounced() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVMTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let vm = StudioViewModel(storageService: StorageService(storeRoot: tmp), usesStudioWindowRegistry: true)
        let usedLast = window(Self.showingChat)
        let other = window(Self.showingChat)
        StudioWindowRegistry.shared.register(other)
        StudioWindowRegistry.shared.register(usedLast, makeActive: true)
        defer {
            StudioWindowRegistry.shared.unregister(other)
            StudioWindowRegistry.shared.unregister(usedLast)
            StudioWindowRegistry.shared.noteDetachedWindowIsKey(false)
        }
        StudioWindowRegistry.shared.noteDetachedWindowIsKey(true)
        #expect(vm.chatRequestOriginWindow == nil)

        vm.requestResumeReviewSession("session-1")

        #expect(vm.reviewChatTargetWindowID == usedLast.id)
        #expect(vm.toastMessage == "Opened in another ForeverLM window")

        // Open here, pressed in the other window after the pane over there
        // consumed the request, asks again for that window.
        vm.reviewChatResumeSessionID = nil
        #expect(vm.toastAction?.title == "Open here")
        await vm.runToastAction(in: other)
        #expect(vm.reviewChatResumeSessionID == "session-1")
        #expect(vm.reviewChatTargetWindowID == other.id)
        #expect(vm.toastMessage == nil)

        // With one Studio window left there is nowhere else it could have gone.
        StudioWindowRegistry.shared.unregister(other)
        vm.dismissToast()
        vm.requestResumeReviewSession("session-2")
        #expect(vm.reviewChatTargetWindowID == usedLast.id)
        #expect(vm.chatRequestElsewhereNotice == nil)
        #expect(vm.toastMessage == nil)

        // A Studio window taking focus back ends the detached state.
        StudioWindowRegistry.shared.activate(usedLast)
        #expect(!StudioWindowRegistry.shared.detachedWindowIsKey)
        #expect(vm.chatRequestOriginWindow === usedLast)
    }

    @Test("the chat popped out of a window stands for that window, not for one that has closed")
    func popOutStandsForItsWindow() {
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let owner = window(Self.showingChat)
        let other = window(Self.showingChat)
        StudioWindowRegistry.shared.register(owner)
        StudioWindowRegistry.shared.register(other, makeActive: true)
        defer {
            StudioWindowRegistry.shared.unregister(other)
            StudioWindowRegistry.shared.unregister(owner)
        }

        StudioWindowRegistry.shared.activateIfRegistered(owner)
        #expect(StudioWindowRegistry.shared.activeState === owner)

        StudioWindowRegistry.shared.unregister(owner)
        StudioWindowRegistry.shared.activateIfRegistered(owner)
        #expect(StudioWindowRegistry.shared.activeState === other)
        #expect(!StudioWindowRegistry.shared.states.contains { $0 === owner })
    }
}

// MARK: - Stored Content Hydration

/// A remote paper's row loads without its text, and the reader renders from
/// the loaded model, so opening one has to teach the model what storage holds.
@Suite("Stored Content Hydration")
@MainActor
struct StoredContentHydrationTests {
    private func storeAndViewModel() throws -> (StorageService, StudioViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredContentHydrationTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        return (service, StudioViewModel(storageService: service), tmp)
    }

    @Test("A paper whose text is in the store gets it on open")
    func storedPaperTextIsHydrated() async throws {
        let (service, vm, tmp) = try storeAndViewModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Canonical text only reaches `source_content` for a paper the store
        // accepts as ready, which means an attested metadata stage — the same
        // shape the live library has for a paper whose text arrived without a
        // PDF. A paper short of that stages its text as raw instead.
        var paper = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02421-x",
            sourceType: .paper,
            state: .error
        )
        paper.author = "Chen, L."
        paper.journal = "Nature Neuroscience"
        paper.publishedYear = "2026"
        let attested = paper.completePaperMetadataFromManualEntry()
        #expect(attested)
        let text = "Addictive substances hijack the brain's reward system, driving dopamine surges."
        paper.installPreparedPaperContent(
            raw: text,
            clean: text,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(text),
                cleanSHA256: PaperContentPreparationService.sha256(text),
                preparedAt: Date()
            )
        )
        paper.state = .ready
        try await service.saveSource(paper)

        // The library loads a paper's row without its text.
        paper.content = nil
        vm.articles = [paper]
        await vm.hydrateStoredContent(for: paper.id)

        #expect(vm.articles[0].content == text)
        #expect((vm.articles[0].wordCount ?? 0) > 0)
    }

    @Test("Text already loaded is left alone, and a stored bot check is refused")
    func loadedTextWinsAndWallsAreRefused() async throws {
        let (service, vm, tmp) = try storeAndViewModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var paper = makeArticle(url: "https://example.org/paper", sourceType: .paper, state: .error)
        paper.content = "Stored text."
        try await service.saveSource(paper)
        paper.content = "The text the reader already has."
        vm.articles = [paper]
        await vm.hydrateStoredContent(for: paper.id)
        #expect(vm.articles[0].content == "The text the reader already has.")

        var walled = makeArticle(
            url: "https://www.science.org/doi/10.1126/science.abc1234",
            sourceType: .paper,
            state: .error
        )
        walled.content = """
        www.science.org
        Verify you are human by completing the action below.
        Performance & security by Cloudflare
        """
        try await service.saveSource(walled)
        walled.content = nil
        vm.articles = [walled]
        await vm.hydrateStoredContent(for: walled.id)
        #expect(vm.articles[0].content == nil)
    }
}

// MARK: - Reader Page Identity

@Suite("Reader Page Identity")
struct ReaderPageIdentityTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A sign-in round trip returning with added query is still the article")
    func addedQueryIsTheSameDocument() {
        let source = url("https://www.nature.com/articles/s41593-026-02421-x")
        #expect(ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://www.nature.com/articles/s41593-026-02421-x?proof=t"),
            sourceURL: source
        ))
        #expect(ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://www.nature.com/articles/s41593-026-02421-x/"),
            sourceURL: source
        ))
    }

    @Test("Another article, host, or the publisher's login is not the article")
    func otherPagesAreNotTheSameDocument() {
        let source = url("https://www.nature.com/articles/s41593-026-02421-x")
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://www.nature.com/articles/s41586-023-06600-9"),
            sourceURL: source
        ))
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://idp.nature.com/authorize?response_type=code"),
            sourceURL: source
        ))
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("file:///Users/someone/Library/ForeverLM/Articles/a/article.html"),
            sourceURL: source
        ))
    }

    @Test("A source whose query identifies the document keeps query significant")
    func queryBearingSourceIsCompared() {
        let source = url("https://openreview.net/forum?id=abc123")
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://openreview.net/forum?id=different"),
            sourceURL: source
        ))
    }
}

// MARK: - Reader Remote PDF Abandonment

/// A publisher that refuses the PDF leaves the reader with either text
/// ForeverLM already holds or the publisher's own page. Both beat a lock
/// screen, and this decides which the reader shows.
@Suite("Reader Remote PDF Abandonment")
@MainActor
struct ReaderRemotePDFAbandonmentTests {
    private func paper() -> StudioArticle {
        makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02421-x",
            title: "Mitochondrial calcium influx-driven bioenergetics",
            sourceType: .paper,
            state: .error
        )
    }

    @Test("A paper with no PDF and a publisher page gives up on the PDF")
    func paperWithPublisherPageQualifies() {
        let vm = makeViewModel()
        let article = paper()
        vm.articles = [article]
        #expect(vm.readerShouldAbandonRemotePDF(article.id))
    }

    @Test("A paper whose text is stored gives up even with no page to show")
    func paperWithStoredTextQualifies() {
        let vm = makeViewModel()
        var direct = makeArticle(
            url: "https://example.org/paper.pdf",
            sourceType: .paper,
            state: .ready
        )
        direct.content = paperBodyText
        vm.articles = [direct]
        #expect(vm.readerShouldAbandonRemotePDF(direct.id))
    }

    @Test("The publisher's preview stored as a paper's text is not text to show")
    func previewTextIsNotReadableText() {
        let vm = makeViewModel()
        var withPage = paper()
        withPage.content = publisherPreviewText
        var direct = makeArticle(url: "https://example.org/paper.pdf", sourceType: .paper, state: .ready)
        direct.content = publisherPreviewText
        vm.articles = [withPage, direct]

        #expect(!StudioViewModel.sourceHoldsReadableText(withPage))
        #expect(StudioViewModel.sourceHoldsReadableText(paper().with(content: paperBodyText)))
        // The page is still there to show, and it is where signing in happens.
        #expect(vm.readerShouldAbandonRemotePDF(withPage.id))
        // No page and no text worth showing: the failure view, where a PDF is attached.
        #expect(!vm.readerShouldAbandonRemotePDF(direct.id))
    }

    @Test("A paper with its own PDF, a non-paper, and one already given up on do not")
    func otherSourcesDoNotQualify() {
        let vm = makeViewModel()
        var withPDF = paper()
        withPDF.localFilePath = "/Users/someone/Library/ForeverLM/Papers/s41593.pdf"
        let articleType = makeArticle(url: "https://example.org/post", state: .error)
        let bare = makeArticle(url: "https://example.org/paper.pdf", sourceType: .paper, state: .error)
        let given = paper()
        vm.articles = [withPDF, articleType, bare, given]
        vm.abandonRemotePDFInReader(given.id)

        #expect(!vm.readerShouldAbandonRemotePDF(withPDF.id))
        #expect(!vm.readerShouldAbandonRemotePDF(articleType.id))
        // No text and no page: the failure view, where attaching a PDF lives.
        #expect(!vm.readerShouldAbandonRemotePDF(bare.id))
        #expect(!vm.readerShouldAbandonRemotePDF(given.id))
        #expect(vm.readerAbandonedRemotePDF(given.id))
    }
}

// MARK: - Stored Publisher Preview Repair

/// Builds before 70 could store a publisher's preview as a paper's text. The
/// repair drops it so the paper asks for its PDF again and the reader shows the
/// publisher's page.
@Suite("Stored Publisher Preview Repair")
@MainActor
struct StoredPublisherPreviewRepairTests {
    /// A paper the page already supplied metadata and text for, taken through
    /// the stages storage requires of a `ready` paper.
    private func paper(content: String) -> StudioArticle {
        var paper = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02421-x",
            title: "Mitochondrial calcium influx-driven bioenergetics",
            sourceType: .paper,
            state: .ready
        )
        paper.author = "Jun Gao; Xin Pan"
        paper.journal = "Nature Neuroscience"
        markPaperFullyReady(&paper, content: content)
        return paper
    }

    @Test("A paper without a PDF drops stored preview text and asks for the PDF again")
    func previewTextIsDiscarded() async throws {
        let vm = makeViewModel()
        let stored = paper(content: publisherPreviewText)
        try await vm.storage.saveSource(stored)
        #expect(await vm.storage.loadSourceContent(stored.id) != nil)
        vm.articles = [stored]

        #expect(await vm.discardStoredPublisherWallTextIfNeeded(for: stored.id))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].wordCount == nil)
        #expect(vm.articles[0].state == .queued)
        #expect(await vm.storage.loadSourceContent(stored.id) == nil)
        // A second pass finds nothing to drop.
        #expect(!(await vm.discardStoredPublisherWallTextIfNeeded(for: stored.id)))
    }

    @Test("A paper's full text is kept")
    func fullTextIsKept() async throws {
        let vm = makeViewModel()
        let full = paper(content: paperBodyText)
        try await vm.storage.saveSource(full)
        vm.articles = [full]

        #expect(!(await vm.discardStoredPublisherWallTextIfNeeded(for: full.id)))
        #expect(vm.articles[0].content == paperBodyText)
        #expect(vm.articles[0].state == .ready)
        #expect(await vm.storage.loadSourceContent(full.id) != nil)
    }

    @Test("A paper whose PDF is on disk keeps whatever text it has")
    func pdfBackedPaperIsLeftAlone() async throws {
        let vm = makeViewModel()
        let pdfURL = try makeReadableTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        var withPDF = paper(content: publisherPreviewText)
        withPDF.localFilePath = pdfURL.path
        StudioArticle.recordExistingLocalPath(pdfURL.path)
        try await vm.storage.saveSource(withPDF)
        vm.articles = [withPDF]

        #expect(!(await vm.discardStoredPublisherWallTextIfNeeded(for: withPDF.id)))
        #expect(vm.articles[0].content == publisherPreviewText)
        #expect(StudioViewModel.sourceHoldsReadableText(withPDF))
    }
}

// MARK: - Discovered Paper Promotion

/// Source discovery promotes an existing article to a paper when it finds the
/// same link typed as a paper. An article whose own URL already reads as a
/// paper's was typed on more than the URL, so that promotion is not offered.
@Suite("Discovered Paper Promotion")
struct DiscoveredPaperPromotionTests {
    @Test("An article at a paper-shaped URL keeps its type when discovery finds the same link as a paper")
    func reclassifiedArticleIsNotPromoted() {
        let newsAndViews = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02264-6",
            title: "Mitochondrial stress response drives microglial senescence",
            sourceType: .article,
            state: .ready
        )
        let candidate = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02264-6",
            sourceType: .paper
        )
        let updates = StudioViewModel.paperPromotionUpdates(from: [candidate], existingArticles: [newsAndViews])
        #expect(updates.isEmpty)
    }

    @Test("An article at an ordinary URL, and an unclassified source, are still promoted")
    func plainArticleAndUnclassifiedArePromoted() {
        let blog = makeArticle(url: "https://example.org/posts/a-study", sourceType: .article, state: .ready)
        let blogCandidate = makeArticle(url: "https://example.org/posts/a-study", sourceType: .paper)
        let unclassified = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .unclassified
        )
        let unclassifiedCandidate = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .paper
        )
        let updates = StudioViewModel.paperPromotionUpdates(
            from: [blogCandidate, unclassifiedCandidate],
            existingArticles: [blog, unclassified]
        )
        #expect(updates.map { $0.article.id }.sorted() == [blog.id, unclassified.id].sorted())
        #expect(updates.allSatisfy { $0.article.sourceType == .paper })
    }
}

// MARK: - Rendered Reader Page Adoption

/// The reader's own web view clears publisher bot checks that the hidden
/// ingestion fetch does not, so a source parked as blocked can take its
/// content from the page the learner is reading.
@Suite("Rendered Reader Page Adoption")
@MainActor
struct RenderedReaderPageAdoptionTests {
    private static let blockedMessage = StudioViewModel.securityChallengeFailureMessage

    private func blockedArticle() -> StudioArticle {
        var article = makeArticle(
            url: "https://www.science.org/content/blog-post/reaction-alzheimer-s-fraud",
            title: "A Reaction to Alzheimer's Fraud",
            state: .error
        )
        article.errorMessage = Self.blockedMessage
        return article
    }

    private func removeArchive(for article: StudioArticle) {
        let directory = (StorageService.libraryRootPath as NSString)
            .appendingPathComponent("Articles/\(article.id)")
        try? FileManager.default.removeItem(atPath: directory)
    }

    @Test("A blocked or unfetched web article can take its content from the reader's page")
    func webArticleWithoutContentQualifies() {
        #expect(StudioViewModel.canAdoptRenderedReaderPage(blockedArticle()))
        let queued = makeArticle(url: "https://example.org/post", state: .queued)
        #expect(StudioViewModel.canAdoptRenderedReaderPage(queued))
        let unclassified = makeArticle(url: "https://example.org/post", sourceType: .unclassified, state: .queued)
        #expect(StudioViewModel.canAdoptRenderedReaderPage(unclassified))
    }

    @Test("A paper with no PDF on record takes its text from the reader's page only when the learner asks")
    func paperWithoutPDFQualifiesWhenAsked() {
        let paper = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .paper,
            state: .error
        )
        // A paper is a PDF: the page is never taken for it on the app's own
        // initiative, only through Save Paper from Page.
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paper))
        #expect(StudioViewModel.canAdoptRenderedReaderPage(paper, learnerAsked: true))

        // The marker says no PDF could be found, which is exactly the case
        // the reader's page answers.
        var paywalled = paper
        paywalled.isPaywalled = true
        #expect(StudioViewModel.canAdoptRenderedReaderPage(paywalled, learnerAsked: true))

        var withText = paper
        withText.content = paperBodyText
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(withText, learnerAsked: true))

        // The publisher's preview stored as the paper's text does not stand in
        // the page's way: the page is what replaces it.
        var withPreview = paper
        withPreview.content = publisherPreviewText
        #expect(StudioViewModel.canAdoptRenderedReaderPage(withPreview, learnerAsked: true))

        // Asking does not make a web article's rules any looser.
        var paywalledArticle = blockedArticle()
        paywalledArticle.isPaywalled = true
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paywalledArticle, learnerAsked: true))
    }

    @Test("The reader offers Save Paper from Page for a paper without a PDF, and for nothing else")
    func readerOffersSavePaperFromPage() throws {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .paper,
            state: .error
        )
        let pdfURL = try makeReadableTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        var withPDF = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06601-0",
            sourceType: .paper,
            state: .ready
        )
        withPDF.localFilePath = pdfURL.path
        StudioArticle.recordExistingLocalPath(pdfURL.path)
        let article = blockedArticle()
        vm.articles = [paper, withPDF, article]

        #expect(vm.readerCanSavePaperFromPage(paper.id))
        #expect(!vm.readerCanSavePaperFromPage(withPDF.id))
        #expect(!vm.readerCanSavePaperFromPage(article.id))
        // The automatic route never offers a paper's page.
        #expect(!vm.readerPageCanSupplySourceContent(paper.id))
        #expect(vm.readerPageCanSupplySourceContent(article.id))
    }

    @Test("Sources with content, papers with a PDF, PDFs, videos, paywalls and fetches in flight do not")
    func otherSourcesDoNotQualify() {
        var ready = blockedArticle()
        ready.content = "Stored body"
        ready.state = .ready
        ready.errorMessage = nil
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(ready))

        var paperWithPDF = makeArticle(
            url: "https://www.science.org/doi/10.1126/science.abc1234",
            sourceType: .paper,
            state: .ready
        )
        paperWithPDF.localFilePath = "/Users/someone/Library/ForeverLM/Papers/science.abc1234.pdf"
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paperWithPDF))

        let pdf = makeArticle(url: "https://example.org/paper.pdf", state: .error)
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(pdf))

        let youtube = makeArticle(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", state: .queued)
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(youtube))

        var paywalled = blockedArticle()
        paywalled.isPaywalled = true
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paywalled))

        var fetching = blockedArticle()
        fetching.state = .fetching
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(fetching))

        let local = makeArticle(url: "/Users/someone/Documents/notes.pdf", state: .queued)
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(local))
    }

    @Test("A bot-check page is not adopted, and the source stays blocked")
    func wallIsNotAdopted() async {
        let vm = makeViewModel()
        let article = blockedArticle()
        vm.articles = [article]
        defer { removeArchive(for: article) }

        await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: """
            <html><head><title>Just a moment...</title></head>
            <body><p>www.science.org</p><p>Verify you are human by completing the action below.</p>
            <p>Performance &amp; security by Cloudflare</p></body></html>
            """,
            pageTitle: "Just a moment...",
            visibleText: "www.science.org\nVerify you are human by completing the action below.\nPerformance & security by Cloudflare"
        )

        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].errorMessage == Self.blockedMessage)
        #expect(vm.articles[0].localFilePath == nil)
    }

    @Test("The rendered article is archived, stored, and the block is lifted")
    func renderedPageBecomesContent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedReaderPageAdoptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let article = blockedArticle()
        try await service.saveSource(article)
        vm.articles = [article]
        defer { removeArchive(for: article) }

        let paragraph = String(
            repeating: "Amyloid has been the prime suspect in the pathology of Alzheimer's for decades. ",
            count: 12
        )
        let html = """
        <html><head><title>A Reaction to Alzheimer's Fraud | Science</title></head>
        <body><nav>Home Commentary Blogs</nav>
        <article><h1>A Reaction to Alzheimer's Fraud</h1><p>\(paragraph)</p><p>\(paragraph)</p></article>
        </body></html>
        """

        await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: html,
            pageTitle: "A Reaction to Alzheimer's Fraud | Science",
            visibleText: paragraph
        )

        let adopted = vm.articles[0]
        // With Source Content Cleanup configured the clean text is the content;
        // without it (this test host) the raw text is staged for cleanup and
        // the body stays empty until then. Either way the block is gone and
        // the archive is on disk.
        if let content = adopted.content {
            #expect(content.contains("prime suspect"))
        }
        #expect(adopted.state != .fetching)
        #expect(adopted.errorMessage != Self.blockedMessage)
        let archivePath = try #require(adopted.localFilePath)
        #expect(archivePath.hasSuffix("article.html"))
        let absoluteArchivePath = StorageService.absoluteSourcePath(archivePath)
        let archivedHTML = try String(contentsOfFile: absoluteArchivePath, encoding: .utf8)
        #expect(archivedHTML.contains("prime suspect"))

        let persisted = try await service.loadSources().first { $0.id == article.id }
        #expect(persisted?.errorMessage != Self.blockedMessage)
        #expect(persisted?.localFilePath == adopted.localFilePath)
    }

    @Test("A blocked source whose only document is the archived wall still takes the reader's page")
    func blockedSourceWithArchivedWallQualifies() {
        // Builds before 99 archived the bot check's page before judging its
        // text, so a blocked row carried the wall as its reader document.
        var article = blockedArticle()
        article.localFilePath = "Articles/\(article.id)/article.html"
        #expect(article.cachedIsArchivedArticle)
        #expect(StudioViewModel.canAdoptRenderedReaderPage(article))

        // The same archive on a row that is not blocked is the row's document.
        var queued = article
        queued.state = .queued
        queued.errorMessage = nil
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(queued))
        var otherError = article
        otherError.errorMessage = "Could not fetch content"
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(otherError))
    }

    @Test("Parking a source as blocked drops the wall the fetch archived")
    func blockDropsArchivedWall() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedReaderPageAdoptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        var article = makeArticle(
            url: "https://www.linkedin.com/pulse/wrong-benchmark-ai-drug-discovery-chris-gibson-xa1lc/",
            title: "The Wrong Benchmark for AI Drug Discovery",
            state: .fetching
        )
        let relativePath = "Articles/\(article.id)/article.html"
        let absolutePath = StorageService.absoluteSourcePath(relativePath)
        try FileManager.default.createDirectory(
            atPath: (absolutePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "<html><body>Performing security verification</body></html>"
            .write(toFile: absolutePath, atomically: true, encoding: .utf8)
        defer { removeArchive(for: article) }
        article.localFilePath = relativePath
        try await service.saveSource(article)
        vm.articles = [article]

        await vm.recordSecurityChallengeBlock(articleId: article.id)

        let blocked = vm.articles[0]
        #expect(blocked.state == .error)
        #expect(blocked.errorMessage == Self.blockedMessage)
        #expect(blocked.localFilePath == nil)
        #expect(!FileManager.default.fileExists(atPath: absolutePath))
        #expect(StudioViewModel.canAdoptRenderedReaderPage(blocked))
        let persisted = try await service.loadSources().first { $0.id == article.id }
        #expect(persisted?.localFilePath == nil)
        #expect(persisted?.errorMessage == Self.blockedMessage)
    }

    private func paperWithoutPDF() -> StudioArticle {
        var paper = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            title: "Structure of the complex in its closed state",
            sourceType: .paper,
            state: .error
        )
        paper.isPaywalled = true
        paper.errorMessage = "PDF download failed: access denied"
        return paper
    }

    private static let paperParagraph = String(
        repeating: "The complex adopts a closed conformation upon binding its substrate, "
            + "and the resulting rearrangement propagates through the linker domain "
            + "to the catalytic site, where two conserved residues coordinate the metal ion. ",
        count: 6
    )

    @Test("A publisher's access wall is not adopted as a paper's text")
    func accessWallIsNotAdoptedForPaper() async {
        let vm = makeViewModel()
        let paper = paperWithoutPDF()
        vm.articles = [paper]

        let references = (1...40).map {
            "\($0). Author, A. & Author, B. A reference title of ordinary length for a journal. J. Sci. 12, 345–678 (2020)."
        }.joined(separator: "\n")
        let wall = """
        Abstract
        We report a finding of some consequence, described here in the few hundred words a landing page shows.
        Access options
        Access through your institution
        Buy this article
        Prices may be subject to local taxes which are calculated during checkout
        References
        \(references)
        """

        let adoption = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: "<html><head><title>Structure of the complex | Nature</title></head><body><main>\(wall)</main></body></html>",
            pageTitle: "Structure of the complex | Nature",
            visibleText: wall,
            learnerAsked: true
        )

        #expect(adoption == .notAdopted(.accessWall))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].errorMessage == "PDF download failed: access denied")
        #expect(vm.articles[0].isPaywalled)
        #expect(vm.articles[0].localFilePath == nil)
    }

    @Test("A page too short to be the paper is not adopted")
    func shortPageIsNotAdoptedForPaper() async {
        let vm = makeViewModel()
        let paper = paperWithoutPDF()
        vm.articles = [paper]

        let abstract = "We report a finding of some consequence, described here in the few hundred words a landing page shows."
        let adoption = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: "<html><body><article><h1>Structure of the complex</h1><p>\(abstract)</p></article></body></html>",
            pageTitle: "Structure of the complex | Nature",
            visibleText: abstract,
            learnerAsked: true
        )

        #expect(adoption == .notAdopted(.tooShort))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].localFilePath == nil)
    }

    @Test("A paper's full text from the reader's page is stored, with no PDF claimed")
    func paperFullTextBecomesContent() async throws {
        // Adoption hands the text to Paper Metadata extraction. Unpinned, the
        // hosted test reads the developer's own sign-in: signed in, it bills a
        // real model call on this made-up page, the model finds no author,
        // venue or year, and the paper waits in `.error` for Edit Details
        // with its text behind the metadata gate, so this test failed on
        // every run from a signed-in Dev host. Signed out, extraction stops
        // before any request and the page's text stays on the source.
        let savedSignIn = ManagedAI.signedInOverrideForTesting
        ManagedAI.signedInOverrideForTesting = false
        defer { ManagedAI.signedInOverrideForTesting = savedSignIn }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedReaderPageAdoptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let paper = paperWithoutPDF()
        try await service.saveSource(paper)
        vm.articles = [paper]
        defer { removeArchive(for: paper) }

        let body = (1...6).map { _ in "<p>\(Self.paperParagraph)</p>" }.joined()
        let html = """
        <html><head><title>Structure of the complex in its closed state | Nature</title></head>
        <body><nav>Nature Log in Subscribe</nav>
        <article><h1>Structure of the complex in its closed state</h1>\(body)</article>
        </body></html>
        """

        // Without the learner asking, the page is not the paper's.
        let unasked = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: html,
            pageTitle: "Structure of the complex in its closed state | Nature",
            visibleText: String(repeating: Self.paperParagraph, count: 6)
        )
        #expect(unasked == .notAdopted(.ineligible))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)

        let adoption = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: html,
            pageTitle: "Structure of the complex in its closed state | Nature",
            visibleText: String(repeating: Self.paperParagraph, count: 6),
            learnerAsked: true
        )
        #expect(adoption == .adoptedPaperText(needsPDF: true))

        let adopted = vm.articles[0]
        #expect(adopted.sourceType == .paper)
        #expect(adopted.state != .fetching)
        #expect(adopted.errorMessage != "PDF download failed: access denied")
        // The text is in the library — in memory until the cleanup save, and
        // in storage after it — the PDF is still missing, and no reader
        // document was archived in its place.
        let storedContent = await service.loadSourceContent(paper.id)
        #expect((adopted.content ?? storedContent ?? "").contains("closed conformation"))
        #expect(adopted.isPaywalled)
        #expect(adopted.localFilePath == nil)
        let persistedRaw = try #require(await service.loadRawPaperContent(paper.id))
        #expect(persistedRaw.contains("closed conformation"))
        let archiveDirectory = (StorageService.libraryRootPath as NSString)
            .appendingPathComponent("Articles/\(paper.id)")
        #expect(!FileManager.default.fileExists(atPath: archiveDirectory))
    }

    @Test("A page arriving for a source that already has content is ignored")
    func readySourceKeepsItsContent() async {
        let vm = makeViewModel()
        var article = blockedArticle()
        article.content = "The body the fetch stored."
        article.state = .ready
        article.errorMessage = nil
        vm.articles = [article]

        await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: "<html><body><article><p>A different rendering of the page.</p></article></body></html>",
            pageTitle: "Different",
            visibleText: "A different rendering of the page."
        )

        #expect(vm.articles[0].content == "The body the fetch stored.")
        #expect(vm.articles[0].localFilePath == nil)
    }
}

// MARK: - Library URL index

/// The chat's web sources footer asks whether each citation is already in the
/// library, once per citation per build of its row, and a lazy transcript
/// rebuilds that row every time it scrolls back into view. Before 2026-09-07 the
/// answer was a scan of `articles` that normalized every stored URL on the main
/// thread; the 1.05 s stall the product owner reported that afternoon was that scan
/// (`ui-stall-2026-09-07T20-19-03`). It is now one set lookup against a table
/// built once per articles revision.
@Suite("Library URL index")
@MainActor
struct LibraryURLIndexTests {
    @Test("Two hundred lookups over a library cost one normalization pass")
    func lookupsShareOnePass() {
        let vm = makeViewModel()
        let paper = makeArticle(url: "/Users/someone/Library/Papers/attention.pdf", title: "Paper", sourceType: .paper)
        let page = makeArticle(url: "https://www.Example.com/story/?utm_source=x", title: "Page")
        let episode = makeArticle(url: "apple-podcast:/episode/1000758651501", title: "Episode", sourceType: .podcast)
        vm.articles = [paper, page, episode]

        for index in 0..<200 {
            #expect(vm.libraryContainsSource(normalizedURL: SourceDiscovery.normalizedURL(page.url)))
            #expect(vm.libraryContainsSource(normalizedURL: SourceDiscovery.normalizedURL(episode.url)))
            #expect(vm.libraryContainsSource(normalizedURL: SourceDiscovery.normalizedURL(paper.url)))
            #expect(!vm.libraryContainsSource(normalizedURL: "example.com/not-saved-\(index)"))
        }
        // One scan for 800 answers, however many rows the transcript rebuilt.
        #expect(vm.sidebarStore.libraryURLKeysBuilds == 1)
    }

    @Test("The index follows the library through adds and removes")
    func indexFollowsTheLibrary() {
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First")
        vm.articles = [first]
        let firstKey = SourceDiscovery.normalizedURL(first.url)
        let secondKey = SourceDiscovery.normalizedURL("https://example.com/second")
        #expect(vm.libraryContainsSource(normalizedURL: firstKey))
        #expect(!vm.libraryContainsSource(normalizedURL: secondKey))

        vm.articles.append(makeArticle(url: "https://example.com/second/", title: "Second"))
        #expect(vm.libraryContainsSource(normalizedURL: secondKey))

        vm.articles.removeAll { $0.id == first.id }
        #expect(!vm.libraryContainsSource(normalizedURL: firstKey))
        #expect(vm.libraryContainsSource(normalizedURL: secondKey))
        // One rebuild per change to the library, none for the repeated reads.
        #expect(vm.sidebarStore.libraryURLKeysBuilds == 3)
    }

    /// The product owner, 2026-09-12: a reply's Web sources offered "Add to Sources" for
    /// a Nature paper already in the library. The paper had been saved from a
    /// recommendation link, `…?fromPaywallRec=false`, and the footer matched on
    /// the address alone. A citation is now also matched by the paper it names.
    @Test("A citation is recognised by the paper's DOI, whatever address the paper was saved under")
    func citationMatchesSavedPaperByDOI() {
        let vm = makeViewModel()
        var fromDOILink = makeArticle(url: "https://doi.org/10.1038/s41586-024-07000-1", title: "By DOI", sourceType: .paper)
        fromDOILink.doi = "10.1038/s41586-024-07000-1"
        var fromPDF = makeArticle(url: "/Users/someone/Library/Papers/preprint.pdf", title: "From PDF", sourceType: .paper)
        fromPDF.doi = "10.1101/2024.11.04.615786v3"
        // A publisher page whose DOI is only in its address, and a page that is not a paper.
        let fromPublisher = makeArticle(url: "https://www.nature.com/articles/s42003-022-04303-x?fromPaywallRec=false", title: "Publisher", sourceType: .paper)
        let page = makeArticle(url: "https://example.com/story", title: "Page")
        vm.articles = [fromDOILink, fromPDF, fromPublisher, page]

        // The bare publisher address a web search cites, for each saved paper.
        #expect(vm.libraryContainsSource(url: "https://www.nature.com/articles/s41586-024-07000-1"))
        #expect(vm.libraryContainsSource(url: "https://www.biorxiv.org/content/10.1101/2024.11.04.615786v1"))
        #expect(vm.libraryContainsSource(url: "https://www.nature.com/articles/s42003-022-04303-x"))
        // The address still matches on its own, DOI or not.
        #expect(vm.libraryContainsSource(url: "https://example.com/story/"))
        // An unrelated paper and an unrelated page are not in the library.
        #expect(!vm.libraryContainsSource(url: "https://www.nature.com/articles/s41586-024-07000-2"))
        #expect(!vm.libraryContainsSource(url: "https://doi.org/10.1000/other"))
        #expect(!vm.libraryContainsSource(url: "https://example.com/other"))
        // One pass built both the address and the DOI keys.
        #expect(vm.sidebarStore.libraryURLKeysBuilds == 1)
    }

    /// The product owner, 2026-09-20: a chat linked the MitoSpace paper by its PubMed
    /// page. The library held the paper under its Cell address, so the Reader
    /// opened PubMed as a live page and offered Add to Sources for a paper
    /// already saved. A PubMed address names only its own record; the page
    /// itself declares the DOI in its head, and once the Reader has read that,
    /// the address resolves to the saved source.
    @Test("A page that declares its DOI resolves to the saved paper, and the address it redirected from does too")
    func pageDeclaredDOIResolvesToSavedPaper() async throws {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "https://www.cell.com/cell/fulltext/S0092-8674(26)01001-9",
            title: "MitoSpace",
            sourceType: .paper,
            id: "mitospace"
        )
        paper.doi = "10.1016/j.cell.2026.08.028"
        var preprint = makeArticle(url: "/Users/someone/Papers/preprint.pdf", title: "Preprint", sourceType: .paper, id: "preprint")
        preprint.doi = "10.1101/2025.01.01.000001"
        preprint.publishedDOI = "10.1038/s41586-026-00001-1"
        vm.articles = [paper, preprint]

        let pubmed = try #require(URL(string: "https://pubmed.ncbi.nlm.nih.gov/42721963/"))
        let doiLink = try #require(URL(string: "https://doi.org/10.1016/j.cell.2026.08.028"))
        #expect(vm.librarySourceID(forURL: pubmed.absoluteString) == nil)
        #expect(vm.librarySourceID(forURL: doiLink.absoluteString) == "mitospace")
        #expect(vm.librarySourceID(forURL: paper.url) == "mitospace")
        // A preprint's published DOI is a link to the journal version, not the version itself: a
        // link to it is not in the library until that version is (docs/paper-versions.md).
        #expect(vm.librarySourceID(forURL: "https://www.nature.com/articles/s41586-026-00001-1") == nil)

        // The PubMed page loads and its head says which paper it is.
        await vm.notePageDeclaredIdentity(
            pageURLs: [pubmed],
            headHTML: """
            <head><title>4D spatiotemporal landscape - PubMed</title>
            <meta name="citation_doi" content="10.1016/j.cell.2026.08.028">
            <meta name="citation_title" content="4D spatiotemporal landscape"></head>
            """
        )
        #expect(vm.librarySourceID(forURL: pubmed.absoluteString) == "mitospace")
        #expect(vm.libraryContainsSource(url: "https://pubmed.ncbi.nlm.nih.gov/42721963"))

        // A page that names no paper leaves no record and matches nothing.
        let blog = try #require(URL(string: "https://example.com/post"))
        await vm.notePageDeclaredIdentity(pageURLs: [blog], headHTML: "<head><title>Post</title></head>")
        #expect(vm.librarySourceID(forURL: blog.absoluteString) == nil)
        #expect(vm.pageDeclaredDOIs.count == 1)

        // A redirect records the page under both the address asked for and the one that answered.
        let asked = try #require(URL(string: "https://europepmc.org/abstract/MED/99"))
        let answered = try #require(URL(string: "https://europepmc.org/article/MED/99"))
        await vm.notePageDeclaredIdentity(
            pageURLs: [answered, asked],
            headHTML: #"<head><meta name="dc.identifier" content="doi:10.1101/2025.01.01.000001"></head>"#
        )
        #expect(vm.librarySourceID(forURL: asked.absoluteString) == "preprint")
        #expect(vm.librarySourceID(forURL: answered.absoluteString) == "preprint")
    }

    @Test("A web citation the library holds opens as the saved source, not as a live page")
    func webCitationOfSavedPaperOpensTheSource() async throws {
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()
        var paper = makeArticle(url: "https://www.cell.com/cell/fulltext/S0092-8674(26)01001-9", title: "MitoSpace", sourceType: .paper, id: "mitospace")
        paper.doi = "10.1016/j.cell.2026.08.028"
        vm.articles = [paper]

        // The DOI link a chat cites, for a paper saved under its publisher's address: recognised at the click.
        let doiLink = try #require(URL(string: "https://doi.org/10.1016/j.cell.2026.08.028"))
        vm.openWebCitationInReader(doiLink, title: "MitoSpace", in: destination)
        for _ in 0..<200 where destination.readerArticleID != "mitospace" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(destination.externalReaderPage == nil)
        #expect(destination.readerArticleID == "mitospace")

        // An unknown page still opens live, untouched.
        let other = try #require(URL(string: "https://example.com/story"))
        vm.openWebCitationInReader(other, title: "Story", in: destination)
        #expect(destination.externalReaderPage?.url == other)
    }
}

@Suite("Navigation rail chat list truncation")
struct NavigationRailChatListTruncationTests {
    @Test("A fresh list shows one page of twenty and no more")
    func freshListShowsOnePage() {
        #expect(StudioNavigationRail.chatListPageSize == 20)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: nil, requiredIndex: nil) == 20)
        #expect(StudioNavigationRail.visibleChatCount(total: 4, revealed: nil, requiredIndex: nil) == 4)
        #expect(StudioNavigationRail.visibleChatCount(total: 0, revealed: nil, requiredIndex: nil) == 0)
    }

    @Test("Scrolling to the end reveals a page at a time and never past the end")
    func scrollingRevealsPages() {
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 40, requiredIndex: nil) == 40)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 60, requiredIndex: nil) == 45)
        // A stale revealed count below a page never shrinks the list.
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 3, requiredIndex: nil) == 20)
    }

    @Test("The open chat stays visible wherever it sits")
    func openChatStaysVisible() {
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: nil, requiredIndex: 27) == 28)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: nil, requiredIndex: 2) == 20)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 40, requiredIndex: 44) == 45)
    }
}

@Suite("Course import banner")
@MainActor
struct CourseImportBannerTests {
    @Test("Hiding the banner keeps it hidden through the import's later phases")
    func hideLastsForTheWholeImport() {
        let vm = makeViewModel()
        vm.playlistImportStatus = "Importing “Thermodynamics”…"
        #expect(vm.visiblePlaylistImportStatus == "Importing “Thermodynamics”…")

        vm.playlistImportBannerHidden = true
        #expect(vm.visiblePlaylistImportStatus == nil)

        // The next phase of the same import must not bring the banner back.
        vm.playlistImportStatus = "Fetching lecture transcripts…"
        #expect(vm.visiblePlaylistImportStatus == nil)
        vm.playlistImportStatus = nil
        #expect(vm.visiblePlaylistImportStatus == nil)
    }

    @Test("A hide is not a setting: an unhidden import shows its banner")
    func unhiddenImportShows() {
        let vm = makeViewModel()
        vm.playlistImportBannerHidden = false
        vm.playlistImportStatus = "Adding course…"
        #expect(vm.visiblePlaylistImportStatus == "Adding course…")
    }
}

@Suite("Readable transcript chunking")
@MainActor
struct ReadableTranscriptChunkingTests {
    @Test("A long caption stream is cut into a handful of chunks, each ending at the last sentence before the limit")
    func chunksFillToTheLimit() {
        let vm = makeViewModel()
        let sentence = "[0:12] the pump moves three sodium ions out and two potassium ions in. "
        let raw = String(repeating: sentence, count: 800)
        let chunks = vm.chunkTranscriptForReadableFormatting(raw)

        // ~56,800 characters at 12,000 a chunk: five chunks, not one per sentence.
        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 12_000 })
        #expect(chunks.dropLast().allSatisfy { $0.count > 11_000 })
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix(".") })
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        let chunkWords = chunks.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        #expect(chunkWords == rawWords)
    }

    @Test("A stream without punctuation still fills each chunk to a word boundary")
    func unpunctuatedStreamBreaksAtWords() {
        let vm = makeViewModel()
        let raw = String(repeating: "sodium calcium exchanger ", count: 2_000)
        let chunks = vm.chunkTranscriptForReadableFormatting(raw)

        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 12_000 && !$0.isEmpty })
        #expect(chunks.dropLast().allSatisfy { $0.count > 11_000 })
        #expect(chunks.allSatisfy { $0.hasSuffix("exchanger") || $0.hasSuffix("sodium") || $0.hasSuffix("calcium") })
    }

    @Test("A short transcript is one chunk")
    func shortTranscriptIsOneChunk() {
        let vm = makeViewModel()
        let raw = "[0:00] one short lecture."
        #expect(vm.chunkTranscriptForReadableFormatting(raw) == [raw])
    }
}

// MARK: - New chat and the chat-home rule in a notebook window

extension ScheduleChatNavigationTests {
    private static let notebookNow = Date(timeIntervalSince1970: 1_790_000_000)

    /// A notebook of the library the test host has open.
    private static func notebook(_ id: String, teamID: String?, archived: Bool = false) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: "Notebook \(id)",
            startAt: notebookNow,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: notebookNow,
            updatedAt: notebookNow,
            status: archived ? LearningGoalStatus.archived.rawValue : LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    /// A timebound Goal drawing on `notebookID`.
    private static func goal(_ id: String, in notebookID: String, teamID: String?) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: "Goal \(id)",
            startAt: notebookNow,
            endAt: notebookNow.addingTimeInterval(7 * 86_400),
            createdAt: notebookNow,
            updatedAt: notebookNow,
            status: LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            parentNotebookID: notebookID,
            teamID: teamID
        )
    }

    private static func chat(_ id: String, filedUnder goalID: String?) -> ReviewSessionRecord {
        ReviewSessionRecord(
            id: id,
            title: "Chat \(id)",
            createdAt: notebookNow,
            status: "completed",
            sourceIDs: [],
            goalID: goalID
        )
    }

    @Test("New chat in a notebook window is the notebook's; a library chat leaves the notebook; an archived one's stays put")
    func newChatInANotebookWindowIsTheNotebooks() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("shelved", teamID: vm.activeTeamID, archived: true),
        ]
        let notebookWindow = StudioWindowState()
        notebookWindow.notebook = NotebookWorkspace(notebookID: "bio", showsChat: false)
        let panes = notebookWindow.centerTabGroups
        let libraryWindow = StudioWindowState()

        // New chat — the rail, /new, a walk's leave — names the window's notebook.
        vm.inWindow(notebookWindow) { vm.requestNewChat() }
        #expect(vm.pendingReviewChatNotebookID == "bio")
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.pendingNotebookChatRequestID == nil, "an explicit New chat seeds its context at once")
        // The chat comes on screen in the notebook; the panes underneath stay.
        #expect(notebookWindow.notebook?.showsChat == true)
        #expect(notebookWindow.centerTabGroups == panes)
        #expect(vm.newChatNotebookID(in: notebookWindow) == "bio")

        vm.inWindow(libraryWindow) { vm.requestNewChat() }
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(vm.newChatNotebookID(in: libraryWindow) == nil)

        // A chat asked for with no Notebook — Plan the Day, Getting Started,
        // a scheduled task — is a library chat, and leaves the notebook as
        // opening a library chat does.
        vm.inWindow(notebookWindow) { vm.requestBlankReviewChat() }
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(notebookWindow.notebook == nil)
        #expect(notebookWindow.centerTabGroups == panes)

        // In an archived notebook New chat is unfiled, and the window stays.
        notebookWindow.notebook = NotebookWorkspace(notebookID: "shelved")
        vm.inWindow(notebookWindow) { vm.requestNewChat() }
        #expect(vm.pendingReviewChatNotebookID == nil, "an archived notebook's chats are the library's")
        #expect(notebookWindow.NotebookID == "shelved")
        #expect(vm.newChatNotebookID(in: notebookWindow) == nil)

        // A notebook named outright still wins over the window's.
        vm.inWindow(libraryWindow) { vm.requestBlankReviewChat(notebookID: "bio") }
        #expect(vm.pendingReviewChatNotebookID == "bio")
    }

    @Test("A chat filed in a notebook opens that notebook in this window; a library chat leaves it")
    func savedChatOpensInItsHome() {
        let restoreTemplate = capturedStudioWindowTemplate()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreTemplate()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("neuro", teamID: vm.activeTeamID),
            Self.notebook("shelved", teamID: vm.activeTeamID, archived: true),
            Self.goal("goal-in-bio", in: "bio", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            Self.chat("bio-chat", filedUnder: "bio"),
            Self.chat("goal-chat", filedUnder: "goal-in-bio"),
            Self.chat("loose-chat", filedUnder: nil),
            Self.chat("shelved-chat", filedUnder: "shelved"),
            Self.chat(MemoryReviewSession.sessionID(for: Self.notebookNow), filedUnder: "bio"),
        ]
        let window = StudioWindowState()
        let panes = window.centerTabGroups

        // From the library: the chat's notebook opens here, with this chat in
        // it rather than a fresh one.
        vm.inWindow(window) { vm.requestResumeReviewSession("bio-chat") }
        #expect(window.NotebookID == "bio")
        #expect(vm.reviewChatResumeSessionID == "bio-chat")
        #expect(vm.pendingNotebookChatRequestID == nil)
        #expect(window.notebook?.showsChat == true)
        #expect(window.centerTabGroups == panes)

        // A chat on a Goal belongs to the notebook the Goal draws on.
        window.notebook = NotebookWorkspace(notebookID: "neuro")
        vm.inWindow(window) { vm.requestResumeReviewSession("goal-chat") }
        #expect(window.NotebookID == "bio")

        // A library chat leaves the notebook; so do an archived notebook's
        // chats and a day's memory review, which the rail lists outside
        // every notebook.
        for libraryChat in ["loose-chat", "shelved-chat", MemoryReviewSession.sessionID(for: Self.notebookNow)] {
            window.notebook = NotebookWorkspace(notebookID: "neuro")
            vm.inWindow(window) { vm.requestResumeReviewSession(libraryChat) }
            #expect(window.notebook == nil, "\(libraryChat)")
            #expect(vm.reviewChatResumeSessionID == libraryChat)
        }

        // A chat whose record is not loaded leaves the window as it is.
        window.notebook = NotebookWorkspace(notebookID: "neuro")
        vm.inWindow(window) { vm.requestResumeReviewSession("not-loaded") }
        #expect(window.NotebookID == "neuro")
    }

    @Test("Opening a notebook over a library chat asks for a fresh notebook chat and writes nothing synced")
    func openingANotebookStartsItsChatWithoutWriting() {
        let restoreTemplate = capturedStudioWindowTemplate()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreTemplate()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("neuro", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            Self.chat("loose-chat", filedUnder: nil),
            Self.chat("bio-chat", filedUnder: "bio"),
        ]
        let contextBefore = vm.contextSourceIds
        let window = StudioWindowState()

        // An empty chat: the pane files it in the notebook itself, so no
        // request goes out.
        vm.reviewChatResetRequestID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.NotebookID == "bio")
        #expect(vm.reviewChatResetRequestID == nil)

        // The notebook's own chat stays.
        window.notebook = nil
        window.chatSessionID = "bio-chat"
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(vm.reviewChatResetRequestID == nil)

        // A library chat gives way to a fresh notebook chat that reads the
        // ticks live: the request names it, and the context is untouched.
        window.notebook = nil
        window.chatSessionID = "loose-chat"
        vm.inWindow(window) { vm.openNotebookInReader("neuro") }
        #expect(window.NotebookID == "neuro")
        #expect(vm.pendingReviewChatNotebookID == "neuro")
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.pendingNotebookChatRequestID == vm.reviewChatResetRequestID)
        #expect(vm.contextSourceIds == contextBefore)
        // The active Notebook, a preference on this Mac only, names the
        // notebook last opened.
        #expect(vm.activeNotebookId == "neuro")

        // Opening the notebook the window already holds asks for nothing.
        let request = vm.reviewChatResetRequestID
        vm.inWindow(window) { vm.openNotebookInReader("neuro") }
        #expect(vm.reviewChatResetRequestID == request)
    }

    @Test("Coming back to a notebook in a window reopens the chat it last had open there; a deleted one starts over")
    func reopeningANotebookReopensItsLastChat() {
        let restoreTemplate = capturedStudioWindowTemplate()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreTemplate()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("neuro", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            Self.chat("bio-chat", filedUnder: "bio"),
            Self.chat("neuro-chat", filedUnder: "neuro"),
            Self.chat("loose-chat", filedUnder: nil),
        ]
        let window = StudioWindowState()

        // The window notes the notebook's chat while it holds the notebook;
        // a library chat is never noted.
        window.notebook = NotebookWorkspace(notebookID: "bio")
        window.chatSessionID = "loose-chat"
        vm.rememberNotebookChat(in: window)
        #expect(window.notebookChats.isEmpty)
        window.chatSessionID = "bio-chat"
        vm.rememberNotebookChat(in: window)
        #expect(window.notebookChats == ["bio": "bio-chat"])
        // Kept in the window's scene snapshot only.
        #expect(StudioWindowState(snapshot: window.snapshot).notebookChats == ["bio": "bio-chat"])

        // Away to a library chat, then back: the notebook's chat reopens,
        // and no fresh chat is asked for.
        window.notebook = nil
        window.chatSessionID = "loose-chat"
        vm.reviewChatResetRequestID = nil
        vm.reviewChatResumeSessionID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.NotebookID == "bio")
        #expect(vm.reviewChatResumeSessionID == "bio-chat")
        #expect(vm.reviewChatResetRequestID == nil)

        // An empty chat gives way to it too.
        window.notebook = nil
        window.chatSessionID = nil
        vm.reviewChatResumeSessionID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(vm.reviewChatResumeSessionID == "bio-chat")

        // Deleted since: forgotten, and the notebook starts over.
        window.notebook = nil
        window.chatSessionID = "loose-chat"
        vm.reviewSessionLinks.removeAll { $0.id == "bio-chat" }
        vm.reviewChatResumeSessionID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.notebookChats["bio"] == nil)
        #expect(vm.reviewChatResumeSessionID == nil)
        #expect(vm.pendingNotebookChatRequestID == vm.reviewChatResetRequestID)
        #expect(vm.reviewChatResetRequestID != nil)
    }
}
