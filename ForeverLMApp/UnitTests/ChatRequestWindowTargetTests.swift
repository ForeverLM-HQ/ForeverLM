// The plugin sync, presentation equality and chat request window tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

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
            .browserReadingLists: now.addingTimeInterval(-2),
        ]
        #expect(due(.xPosts, justNow, now: now).isEmpty)
        // Reading Lists have no cooldown: a page just saved in the browser is found at once.
        #expect(due(.articles, justNow, now: now) == [.browserReadingLists])
        #expect(due(.papers, justNow, now: now) == [.browserReadingLists])
        #expect(due(nil, justNow, now: now) == [.youtube, .googleDriveMeetings, .applePodcasts, .browserReadingLists])
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

        #expect(due(.xPosts, vm.lastPluginSyncAt, now: now.addingTimeInterval(3)).isEmpty)
        #expect(due(.videos, vm.lastPluginSyncAt, now: now.addingTimeInterval(3)).isEmpty)
        #expect(due(nil, vm.lastPluginSyncAt, now: now.addingTimeInterval(3)) == [.browserReadingLists])
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
    /// Three panes with Chat parked behind the first.
    private static let threePanesChatParked = [
        "reader*|tasks|chat", "notepad*", "notebooks*",
    ]
    private static let showingChat = ["chat*", "reader*|tasks|notepad|notebooks"]

    private func window(_ layout: [String]) -> StudioWindowState {
        StudioWindowState(snapshot: .init(
            centerTabGroups: layout,
            navigationRailVisible: true
        ))
    }

    @Test("a New chat stays here even when the other window shows Chat")
    func newChatNeverJumpsToTheWindowShowingChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = window(Self.threePanesChatParked)
        let there = window(Self.showingChat)
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        let layoutThere = there.centerTabGroups

        vm.inWindow(here) { vm.requestBlankReviewChat() }

        // The click belongs to this window even though the other window
        // already shows Chat: nothing moves over there.
        #expect(vm.reviewChatTargetWindowID == here.id)
        #expect(vm.chatPaneAcceptsGlobalRequests(ownerWindowID: here.id))
        #expect(!vm.chatPaneAcceptsGlobalRequests(ownerWindowID: there.id))
        #expect(vm.chatRequestElsewhereNotice == nil)
        #expect(vm.toastMessage == nil)
        #expect(here.centerTabGroups.groups.contains { $0.activeTab == .chat })
        #expect(there.centerTabGroups == layoutThere)
    }

    @Test("a New chat in a window that can show Chat stays there, without a word")
    func newChatStaysInItsOwnWindow() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        // Chat parked behind the Reader.
        let here = window(["reader*|tasks|notepad|notebooks|chat"])
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

    @Test("a selection sent from a window with Chat parked stays here")
    func selectionNeverJumpsToTheOtherWindow() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let restoreRegistry = capturedStudioWindowRegistry()
        defer { restoreRegistry() }
        let vm = makeViewModel()
        let here = window(Self.threePanesChatParked)
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
