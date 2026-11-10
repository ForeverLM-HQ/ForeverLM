// The cross-window Reader and Library list navigation tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

/// The unit tests run inside the app host, whose own Studio window registers
/// itself and — on the default layout — is showing Reader. Take the registry
/// down to just the windows under test, then hand the host's back, so a real
/// window on the machine cannot change what these tests observe.
@MainActor
func capturedStudioWindowRegistry() -> () -> Void {
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
            url: "https://example.com/other-window-source",
            title: "Other Window Source",
            state: .ready,
            id: "other-window-source"
        )
        source.content = "Already loaded."
        vm.articles = [source]
        // This window is all Chat, and the other one is reading. The click
        // still belongs to this window: the Reader is wedged
        // in beside Chat here, and the other window is left alone.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
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
            centerTabGroups: ["reader*|tasks|notepad|notebooks", "chat*"],
            navigationRailVisible: true
        ))
        StudioWindowRegistry.shared.register(here, makeActive: true)
        StudioWindowRegistry.shared.register(there)
        defer {
            StudioWindowRegistry.shared.unregister(there)
            StudioWindowRegistry.shared.unregister(here)
        }
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
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
            .init(tabs: [.chat, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
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
