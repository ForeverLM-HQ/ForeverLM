// ScheduleChatNavigationTests: workspace layouts, panes, tab drags, splits and opening beside.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

extension ScheduleChatNavigationTests {
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
        #expect(value.groups[1].tabs == [.reader, .tasks, .activity, .activityLog, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .memory, .knowledgeMap, .atlas, .library, .plugins])
        #expect(value.groups[1].activeTab == .reader)

        let persisted = value.persistedRepresentation
        #expect(persisted == ["chat*", "reader*|tasks|activity|activityLog|goals|courses|ideas|notepad|sites|browser|videos|animations|artifacts|memory|knowledgeMap|atlas|library|plugins"])
        let decoded = StudioCenterTabGroups.fromPersisted(persisted)
        #expect(decoded?.groups.count == 2)
        #expect(decoded?.groups[1].activeTab == .reader)

        // Ignore the retired Voice and Goal tokens in old preference values,
        // and fall back to the first live tab.
        let retiredTokens = StudioCenterTabGroups.fromPersisted([
            "voice|chat*",
            "goal*|reader|notebooks",
        ])
        #expect(retiredTokens?.groups[0].tabs == [.chat])
        #expect(retiredTokens?.groups[1].tabs == [.reader, .artifacts, .tasks, .activity, .activityLog, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins])
        #expect(retiredTokens?.groups[1].activeTab == .reader)

        // Older builds allowed four panes. Loading that arrangement folds the
        // extras into the overflow cap without losing any permanent tabs.
        let crowded = StudioCenterTabGroups.reconciled(.init(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
            .init(tabs: [.tasks], activeTab: .tasks),
            .init(tabs: [.notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
        ]))
        #expect(crowded.groups.count == StudioCenterTabGroups.draggedGroupCount)
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
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
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
            .init(tabs: [.library], activeTab: .library),
        ]).persistedRepresentation
        UserDefaults.standard.set(stored, forKey: "studio.centerTabGroups.v1")

        vm.reloadSyncedPreferences()

        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.draggedGroupCount)
        #expect(vm.activeCenterTabs == [.chat, .reader, .artifacts, .notepad])
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
            .init(tabs: [.chat, .tasks, .activity, .activityLog, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .chat),
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
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
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
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
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

    @Test("a sidebar destination opens as a tab beside what the pane showed")
    func sidebarDestinationOpensAsTab() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .notepad
            ),
        ])
        // Every pane draws its strip, a lone tab's included.
        #expect(vm.centerTabGroups.groups[0].showsTabStrip)

        vm.activateCenterTab(.artifacts)

        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.centerTabGroups.groups[0].activeTab == .artifacts)
        #expect(vm.centerTabGroups.groups[0].openTabs == [.notepad, .artifacts])
        #expect(vm.centerTabGroups.groups[0].showsTabStrip)

        // A tab already open comes to the front; nothing new opens.
        vm.activateCenterTab(.notepad)
        #expect(vm.centerTabGroups.groups[0].activeTab == .notepad)
        #expect(vm.centerTabGroups.groups[0].openTabs == [.notepad, .artifacts])
    }

    @Test("a sidebar click opens in the pane clicked last")
    func sidebarClickOpensInFocusedPane() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.notepad, .tasks, .artifacts], activeTab: .notepad),
        ])
        vm.activeWindowState.focusedGroupID = vm.centerTabGroups.groups[0].id

        vm.activateCenterTab(.tasks)

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.tasks, .notepad])
        #expect(vm.centerTabGroups.groups[0].openTabs == [.chat, .tasks])
        #expect(!vm.centerTabGroups.groups[1].tabs.contains(.tasks))

        // Open in the other pane, the Docs tab is focused there.
        vm.activateCenterTab(.notepad)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.tasks, .notepad])
    }

    @Test("closing a tab shows its neighbour and keeps the pane")
    func closingTabShowsNeighbour() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat, .library, .memory], activeTab: .chat, openTabs: [.artifacts, .chat, .library]),
        ])

        vm.closeCenterTab(.chat)
        #expect(vm.centerTabGroups.groups[0].activeTab == .library)
        #expect(vm.centerTabGroups.groups[0].openTabs == [.artifacts, .library])

        // A background tab closes without changing what the pane shows.
        vm.closeCenterTab(.artifacts)
        #expect(vm.centerTabGroups.groups[0].activeTab == .library)
        #expect(vm.centerTabGroups.groups[0].openTabs == [.library])

        // The last tab closes the way the pane's × does: onto the Space.
        vm.closeCenterTab(.library)
        #expect(vm.centerTabGroups.groups[0].activeTab == .artifacts)
        #expect(vm.centerTabGroups.groups[0].openTabs == [.artifacts])
    }

    @Test("Pages can stand in two panes, once in each, and round-trips")
    func pagesStandInTwoPanes() {
        let raw = StudioCenterTabGroups(groups: [
            .init(tabs: [.notepad, .chat, .notepad], activeTab: .notepad),
            .init(tabs: [.notepad, .library, .chat], activeTab: .notepad),
        ])
        let value = StudioCenterTabGroups.reconciled(raw)
        #expect(value.groups.count == 2)
        // Once per pane; a place that cannot be copied stays once per window.
        #expect(value.groups[0].tabs.filter { $0 == .notepad }.count == 1)
        #expect(value.groups[1].tabs.prefix(2) == [.notepad, .library])
        #expect(!value.groups[1].tabs.contains(.chat))
        #expect(value.groups.map(\.activeTab) == [.notepad, .notepad])

        let decoded = StudioCenterTabGroups.fromPersisted(value.persistedRepresentation)
        #expect(decoded == value)
    }

    @Test("a split copies Pages beside its pane and nothing that cannot be copied")
    func splittingCopiesOnlyCopyablePlaces() {
        let layout = StudioCenterTabGroups.reconciled(.init(groups: [
            .init(tabs: [.notepad, .chat], activeTab: .notepad),
        ]))
        let split = layout.splitting(.notepad, besidePaneAt: 0, towardRight: true)
        #expect(split?.groups.map(\.activeTab) == [.notepad, .notepad])
        #expect(split?.groups[1].tabs == [.notepad])
        #expect(layout.splitting(.library, besidePaneAt: 0, towardRight: true) == nil)

        // No pane past the limit.
        let full = StudioCenterTabGroups.reconciled(.init(groups: [
            .init(tabs: [.notepad], activeTab: .notepad),
            .init(tabs: [.notepad], activeTab: .notepad),
            .init(tabs: [.notepad], activeTab: .notepad),
            .init(tabs: [.notepad, .chat], activeTab: .notepad),
        ]))
        #expect(full.groups.count == StudioCenterTabGroups.draggedGroupCount)
        #expect(full.splitting(.notepad, besidePaneAt: 0, towardRight: true) == nil)
    }

    @Test("the split button opens a Pages copy on the list, and its tab closes only that copy")
    func splitPaneOpensPagesCopy() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let window = vm.activeWindowState
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat, .notepad], activeTab: .notepad, openTabs: [.chat, .notepad]),
        ])
        let originalID = vm.centerTabGroups.groups[0].id

        vm.splitPane(at: 0, showing: .notepad, in: window)

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .notepad])
        let copyID = vm.centerTabGroups.groups[1].id
        #expect(window.focusedGroupID == copyID)
        // The copy shows the list of pages, and only the copy answers.
        #expect(vm.artifactIndexRequest?.groupID == copyID)
        // A page opened now goes to the pane last clicked in.
        #expect(vm.paneShowing(.notepad, in: window) == copyID)
        window.focusedGroupID = originalID
        #expect(vm.paneShowing(.notepad, in: window) == originalID)

        // A strip click in the copy shows the copy's tab, not the first one.
        vm.replaceCenterPane(at: 1, with: .memory, in: window)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .memory])
        window.focusedGroupID = copyID
        vm.activateCenterTab(.notepad)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .notepad])

        // The copy's × closes the copy; the first Pages stays as it was.
        vm.closeCenterTab(.memory, fromGroup: copyID)
        vm.closeCenterTab(.notepad, fromGroup: copyID)
        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.centerTabGroups.groups[0].id == originalID)
        #expect(vm.centerTabGroups.groups[0].activeTab == .notepad)
        #expect(vm.centerTabGroups.groups[0].tabs.filter { $0 == .notepad }.count == 1)
    }

    @Test("the split button moves a place that cannot be copied into a new pane")
    func splitPaneMovesOtherPlaces() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat, .library], activeTab: .chat, openTabs: [.chat]),
        ])

        vm.splitPane(at: 0, showing: .library, in: vm.activeWindowState)

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .library])
        #expect(!vm.centerTabGroups.groups[0].tabs.contains(.library))
    }

    @Test("a tab dragged to an edge opens beside the rest")
    func tabDraggedToEdgeSplits() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat, .reader], activeTab: .reader, openTabs: [.artifacts, .chat, .reader]),
        ])

        vm.placeCenterTabAtEdge(.chat, leading: false)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat])
        #expect(vm.centerTabGroups.groups[0].openTabs == [.artifacts, .reader])

        // A third pane, since the learner dragged it there.
        vm.placeCenterTabAtEdge(.artifacts, leading: true)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .reader, .chat])

        // A fourth pane too (product owner, 2026-11-07: "Yes, allow four").
        vm.activateCenterTab(.memory)
        vm.placeCenterTabAtEdge(.memory, leading: false)
        #expect(vm.centerTabGroups.groups.count == 4)
        #expect(vm.centerTabGroups.groups[3].activeTab == .memory)

        // At four panes a tab sharing a pane joins the edge pane as a tab.
        vm.activateCenterTab(.library)
        let library = vm.centerTabGroups.groups.firstIndex { $0.activeTab == .library }
        #expect(library != nil)
        vm.placeCenterTabAtEdge(.library, leading: false)
        #expect(vm.centerTabGroups.groups.count == 4)
        #expect(vm.centerTabGroups.groups[3].activeTab == .library)
        #expect(vm.centerTabGroups.groups[3].openTabs == [.memory, .library])
    }

    @Test("a tab dropped on another pane's strip moves there")
    func tabDroppedOnStripMoves() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks], activeTab: .chat, openTabs: [.chat, .tasks]),
            .init(tabs: [.reader, .notepad], activeTab: .reader, openTabs: [.reader, .notepad]),
        ])

        vm.moveCenterTab(.tasks, toGroup: 1, at: 1)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .tasks])
        #expect(vm.centerTabGroups.groups[1].openTabs == [.reader, .tasks, .notepad])

        // A pane's only tab leaves the pane with it.
        vm.moveCenterTab(.chat, toGroup: 1, at: .max)
        #expect(vm.centerTabGroups.groups.count == 1)
        #expect(vm.centerTabGroups.groups[0].openTabs == [.reader, .tasks, .notepad, .chat])
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)
    }

    @Test("New chat opens as a tab, the source being read kept as one")
    func newChatKeepsTheOpenSourceAsATab() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let source = makeArticle(url: "https://example.com/read-here", title: "Read here", state: .ready, id: "read-here")
            .with(content: "Already loaded.")
        vm.articles = [source]
        // One pane holding every tab, the Activity pane showing.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .activity
            ),
        ])

        await vm.selectArticle(source.id)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader])

        vm.requestBlankReviewChat()

        #expect(vm.activeCenterTabs.contains(.chat))
        #expect(vm.centerTabGroups.groups.contains { $0.openTabs.contains(.reader) })
        #expect(vm.selectedArticleId == source.id)
    }

    @Test("the next rail destination opens as a tab over the Reader")
    func railDestinationKeepsTheOpenSourceAsATab() async {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        let source = makeArticle(url: "https://example.com/keep-reading", title: "Keep reading", state: .ready, id: "keep-reading")
            .with(content: "Already loaded.")
        vm.articles = [source]
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .notepad
            ),
        ])

        await vm.selectArticle(source.id)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])

        vm.openDayPane()

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .activity])
        #expect(vm.centerTabGroups.groups[1].openTabs.contains(.reader))
    }

    @Test("open tabs round-trip, and a retired pane pin is ignored")
    func openTabsPersistence() {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins],
                activeTab: .notepad,
                openTabs: [.reader, .notepad]
            ),
        ])

        #expect(layout.persistedRepresentation == [
            "chat*",
            "reader+|tasks|activity|activityLog|notepad*|sites|browser|videos|animations|artifacts|goals|ideas|courses|memory|knowledgeMap|atlas|library|plugins",
        ])
        let decoded = StudioCenterTabGroups.fromPersisted(layout.persistedRepresentation)
        #expect(decoded == layout)
        #expect(decoded?.groups[1].openTabs == [.reader, .notepad])

        let retired = StudioCenterTabGroups.fromPersisted(["artifacts*", "notepad*"])
        #expect(retired?.groups.map(\.activeTab) == [.artifacts, .notepad])
        #expect(retired?.groups.map(\.openTabs) == [[.artifacts], [.notepad]])
    }

    @Test("saved workspace views round-trip every window independently")
    func savedWorkspaceViewsRoundTripEveryWindow() {
        let left = StudioWindowState(snapshot: .init(
            centerTabGroups: ["notebooks*", "reader*"],
            navigationRailVisible: false
        ))
        let right = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*", "notepad*"],
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
        // scene state.
        left.navigationRailVisible = false
        #expect(!left.navigationRailVisible)
        #expect(right.navigationRailVisible)
        #expect(right.centerTabGroups.groups.map(\.activeTab) == [.chat, .notepad])
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
        let stalePlacement = StudioWindowPlacement(
            displayID: "stale-id",
            displayName: "Same Monitor",
            displayIndex: 1,
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 1,
            normalizedHeight: 1
        )

        #expect(StudioWorkspaceDisplayResolver.index(for: stableIdentity, among: displays) == 1)
        #expect(StudioWorkspaceDisplayResolver.index(for: stalePlacement, among: displays) == 1)
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
            centerTabGroups: ["notebooks*", "reader*"],
            navigationRailVisible: false
        )
        let secondSnapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["chat*", "notepad*"],
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

    @Test("center tabs move and dissolve without exceeding four panes")
    func centerTabMoves() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        // Chat beside the reading surfaces: two panes.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .notepad, .sites, .browser, .artifacts], activeTab: .reader),
        ])

        // Split Right from a strip may make a third and a fourth pane, as a
        // drag may, and no fifth.
        vm.moveCenterTabToNewGroup(.artifacts, at: 2)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader, .artifacts])
        vm.moveCenterTabToNewGroup(.sites, at: 3)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader, .artifacts, .sites])
        let atCapacity = vm.centerTabGroups
        vm.moveCenterTabToNewGroup(.tasks, at: 4)
        #expect(vm.centerTabGroups == atCapacity)

        vm.moveCenterTab(.sites, toGroup: 1, at: 1)
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
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])

        // Closing the left pane (including from its hidden-tab-bar close
        // affordance) leaves the right pane and its active surface intact.
        vm.closeCenterPane(containing: .chat)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .artifacts),
        ])

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])

        // Closing the final pane moves its tabs left, preserving the
        // destination pane's active surface.
        vm.closeCenterPane(containing: .artifacts)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .chat),
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
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
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
                    tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                    activeTab: tab
                ),
            ])

            vm.dismissCenterSurface(tab)

            #expect(vm.centerTabGroups.groups.count == 1)
            #expect(vm.centerTabGroups.groups[0].activeTab == .artifacts, "\(tab)")
            // The closed surface is no tab behind the home.
            #expect(vm.centerTabGroups.groups[0].openTabs == [.artifacts], "\(tab)")
        }

        // The home is the one surface that cannot close onto itself; it
        // reveals Chat instead.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
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
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins],
                activeTab: .tasks
            ),
        ])
        vm.centerTabGroups = activeLayout

        let clickedWindow = StudioWindowState()
        clickedWindow.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(
                tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
                activeTab: .reader
            ),
        ])

        // A titlebar button accepts first mouse and may run before its window
        // becomes key. Its own scene state must still be the mutation target.
        vm.dismissCenterSurface(.reader, in: clickedWindow)

        #expect(vm.centerTabGroups == activeLayout)
        #expect(clickedWindow.centerTabGroups.groups == [
            .init(
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins],
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
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .reader),
        ])
        // [chat] | [reader, tasks, notepad, notebooks]
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat])

        vm.moveCenterGroup(containing: .chat, by: 1)
        #expect(vm.centerTabGroups.groups[0].tabs == [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins])
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

        // The Reader is its pane's only tab, and that pane is rightmost.
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
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .reader),
        ])
        let sameArrangement = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .animations, .artifacts, .goals, .ideas, .courses, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .reader),
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
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .reader),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups.count == 2)
        #expect(vm.centerTabGroups.groups[0].tabs == [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins])
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
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.reader, .notepad, .sites, .browser, .videos, .artifacts, .activity, .activityLog, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .reader))

        // Chat already open to the Reader's right stays there too.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader, .notepad, .sites], activeTab: .notepad),
            .init(tabs: [.chat, .tasks, .artifacts], activeTab: .artifacts),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups[0] == .init(tabs: [.reader, .notepad, .sites], activeTab: .reader))
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.chat, .tasks, .artifacts, .activity, .activityLog, .goals, .courses, .ideas, .browser, .videos, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .chat))
    }

    @Test("Navigation destinations can open beside the visible pane")
    func openCenterTabBeside() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.openCenterTabBeside(.notepad)
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .chat),
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

        // Ideas parked behind the Reader shows beside Docs in the Reader's
        // pane, the Reader kept there as a tab.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader, .ideas], activeTab: .reader),
            .init(tabs: [.notepad, .chat], activeTab: .notepad),
        ])
        vm.openArtifactKindBeside(.ideas)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.ideas, .notepad])
        #expect(vm.centerTabGroups.groups[0].openTabs == [.reader, .ideas])
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

    @Test("workspace destinations replace a pane after the two-pane cap; a drag may make a third")
    func coreWorkspaceCombination() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.openCenterTabBeside(.notepad)
        vm.openCenterTabBeside(.artifacts)

        // Chat, Docs, and Notebooks are the core destinations: with both panes
        // already showing one, a third opens in place rather than splitting.
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .notepad])
        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.maximumGroupCount)

        // The Space shares its pane with Chat as a tab: dragged to a side it
        // splits out, a third pane since the learner chose it.
        vm.placeCenterTabAtEdge(.artifacts, leading: true)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .chat, .notepad])

        // Docs is its pane's only tab: the pane moves, and none is added.
        vm.placeCenterTabAtEdge(.notepad, leading: false)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .chat, .notepad])
        #expect(vm.centerTabGroups.groups.count == 3)
    }

    @Test("A dragged chat creates a transient independent pane at either edge")
    func secondaryChatPanePlacement() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
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
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
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
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.activeWindowState.artifactCanvasNotebookID = "notebook-1"
        vm.openCenterTabBeside(.notepad)

        #expect(vm.artifactCanvasNotebookID == "notebook-1")
        #expect(vm.activeWindowState.artifactCanvasNotebookID == "notebook-1", "the scope is the window's")
        #expect(vm.centerTabGroups.groups == [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins], activeTab: .artifacts),
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
        vm.activeWindowState.artifactCanvasNotebookID = "notebook-2"
        vm.openCenterTabBeside(.notepad)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.notepad, .artifacts])
        #expect(vm.artifactCanvasNotebookID == "notebook-2")

        // At the cap, Docs open in the pane they are parked in, as a rail
        // row's Open Beside does.
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.activeWindowState.artifactCanvasNotebookID = "notebook-3"
        vm.openCenterTabBeside(.notepad)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .notepad])
    }

    @Test("Reader selection opens Chat to Reader's right")
    func readerSelectionOpensSplitChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .reader),
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
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .chat),
        ])
        vm.revealReader(beside: .chat)
        #expect(vm.centerTabGroups.groups.count == 2)
        #expect(vm.centerTabGroups.groups[0].tabs == [.chat, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts, .goals, .courses, .ideas, .animations, .memory, .knowledgeMap, .atlas, .library, .plugins])
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)
        #expect(vm.centerTabGroups.groups[1] == .init(tabs: [.reader], activeTab: .reader))

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .tasks], activeTab: .tasks),
            .init(tabs: [.reader, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .artifacts),
        ])
        vm.revealReader(beside: .chat)
        #expect(vm.centerTabGroups.groups[0].activeTab == .chat)
        #expect(vm.centerTabGroups.groups[1].activeTab == .reader)
    }

    @Test("A citation opens the Reader beside Chat, what its pane showed kept as a tab")
    func revealReaderKeepsTheCoveredSurfaceAsATab() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.notepad, .reader, .tasks], activeTab: .notepad),
        ])
        vm.revealReader(beside: .chat)

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .reader])
        #expect(vm.centerTabGroups.groups[1].openTabs == [.notepad, .reader])
    }

    @Test("A passage opens Chat beside the Reader, what its pane showed kept as a tab")
    func revealChatKeepsTheCoveredSurfaceAsATab() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader], activeTab: .reader),
            .init(tabs: [.notepad, .chat, .tasks], activeTab: .notepad),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat])
        #expect(vm.centerTabGroups.groups[1].openTabs == [.notepad, .chat])

        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader], activeTab: .reader),
            .init(tabs: [.notepad, .chat], activeTab: .notepad),
            .init(tabs: [.tasks], activeTab: .tasks),
        ])
        vm.revealChatBesideReader()
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .chat, .tasks])
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
            .init(tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts], activeTab: .notepad),
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
                tabs: [.chat, .reader, .tasks, .activity, .activityLog, .notepad, .sites, .browser, .videos, .artifacts],
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
