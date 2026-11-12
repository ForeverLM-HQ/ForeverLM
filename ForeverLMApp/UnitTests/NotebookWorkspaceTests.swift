import Foundation
import Testing
@testable import ForeverLM

/// The notebook a Studio window holds: the pure model (`NotebookWorkspace`)
/// and its decoding across builds.
@Suite("Notebook workspace")
struct NotebookWorkspaceTests {

    @Test("A chat's home is its notebook, or the notebook its Goal draws on, or the library")
    func chatHome() {
        let notebooks: Set<String> = ["bio", "neuro"]
        let parents = ["goal-1": "bio", "goal-orphan": "archived"]
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "bio", notebookIDs: notebooks, parentNotebookByGoalID: parents) == "bio")
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "goal-1", notebookIDs: notebooks, parentNotebookByGoalID: parents) == "bio")
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "goal-orphan", notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "archived", notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
        #expect(NotebookWorkspace.home(ofChatFiledUnder: nil, notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
        #expect(NotebookWorkspace.home(ofChatFiledUnder: "", notebookIDs: notebooks, parentNotebookByGoalID: parents) == nil)
    }

    // MARK: - Opening and persisting

    @Test("Reopening the open notebook keeps its arrangement; another notebook starts fresh")
    func openingKeepsOnlyTheSameNotebook() {
        let arranged = NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true, studioCollapsed: true)
        #expect(NotebookWorkspace.opening("bio", over: arranged) == arranged)
        #expect(NotebookWorkspace.opening("neuro", over: arranged) == NotebookWorkspace(notebookID: "neuro"))
        #expect(NotebookWorkspace.opening("bio", over: nil) == NotebookWorkspace(notebookID: "bio"))
    }

    @Test("A fresh notebook opens with both columns open")
    func freshWorkspace() {
        let fresh = NotebookWorkspace(notebookID: "bio")
        #expect(!fresh.sourcesCollapsed)
        #expect(!fresh.sourcesExpanded)
        #expect(!fresh.studioCollapsed)
    }

    @Test("A window builds 175 and 176 kept on Library or About reopens on the Studio, folded as it was")
    func olderFacesDecode() throws {
        for face in ["studio", "library", "about", "audio"] {
            let decoded = try JSONDecoder().decode(
                NotebookWorkspace.self,
                from: Data(#"{"notebookID":"bio","trailing":"\#(face)","trailingCollapsed":true}"#.utf8)
            )
            #expect(decoded == NotebookWorkspace(notebookID: "bio", studioCollapsed: true), "the fold is the Studio's; the face is not read")
        }
        // The fold keeps the key those builds wrote, so going back to one
        // still reads it; the face they no longer need is not written.
        let encoded = try JSONEncoder().encode(NotebookWorkspace(notebookID: "bio", studioCollapsed: true))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["trailingCollapsed"] as? Bool == true)
        #expect(object["trailing"] == nil)
        #expect(object["studioCollapsed"] == nil)
    }

    @Test("What is kept leaves out a search's widened list, and nothing else")
    func persistedDropsOnlyTheMoments() {
        var arranged = NotebookWorkspace(notebookID: "bio", studioCollapsed: true)
        arranged.sourcesExpanded = true
        var expected = arranged
        expected.sourcesExpanded = false
        #expect(arranged.persisted == expected)
        #expect(arranged.persisted.persisted == expected)
    }

    // MARK: - Decoding across builds

    @Test("A workspace round-trips through JSON")
    func roundTrip() throws {
        let arranged = NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true, studioCollapsed: true)
        let data = try JSONEncoder().encode(arranged)
        #expect(try JSONDecoder().decode(NotebookWorkspace.self, from: data) == arranged)
    }

    @Test("Keys an older build did not write take a fresh workspace's values")
    func missingKeysDecodeFresh() throws {
        let decoded = try JSONDecoder().decode(
            NotebookWorkspace.self,
            from: Data(#"{"notebookID":"bio"}"#.utf8)
        )
        #expect(decoded == NotebookWorkspace(notebookID: "bio"))

        let partial = try JSONDecoder().decode(
            NotebookWorkspace.self,
            from: Data(#"{"notebookID":"bio","sourcesCollapsed":true}"#.utf8)
        )
        #expect(partial == NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true))
    }

    @Test("A snapshot from the chat-and-slot layout reopens the notebook with its folds, and writes none of it back")
    func slotLayoutSnapshotDecodes() throws {
        let older = Data(#"""
        {"notebookID":"bio","document":"reader","leadingDocument":"docs","showsChat":false,
         "documentLeads":false,"tabbed":false,"sourcesCollapsed":true,"trailingCollapsed":true}
        """#.utf8)
        let decoded = try JSONDecoder().decode(NotebookWorkspace.self, from: older)
        #expect(decoded == NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true, studioCollapsed: true))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(Set(object.keys) == ["notebookID", "sourcesCollapsed", "trailingCollapsed"])
    }

    @Test("A workspace that names no notebook is not a workspace")
    func notebookIDIsRequired() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NotebookWorkspace.self, from: Data(#"{"showsChat":true}"#.utf8))
        }
    }
}

/// The notebook belongs to the window: two windows hold two notebooks, a
/// change reaches only that window's scene snapshot, and the app-wide
/// `workbenchNotebookID` reads whichever window it acts in.
@Suite("Window-owned notebooks")
@MainActor
struct WindowNotebookTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// An active notebook of the library `teamID` names (nil: My Library).
    private static func notebook(_ id: String, title: String, teamID: String?) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: title,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]

    private func templateValues() -> [String] {
        Self.templateKeys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
    }

    @Test("A notebook's chats, for its Chats menus and guide, are those filed in it, in the rail's order, and never another's")
    func notebookChatsListsItsOwn() {
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", title: "Bioenergetics", teamID: vm.activeTeamID),
            Self.notebook("neuro", title: "Neuroscience", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "bio-new", title: "Complex I", createdAt: Self.now, status: "completed", sourceIDs: [], goalID: "bio"),
            ReviewSessionRecord(id: "neuro-1", title: "Synapses", createdAt: Self.now, status: "completed", sourceIDs: [], goalID: "neuro"),
            ReviewSessionRecord(id: "loose", title: "Unfiled", createdAt: Self.now, status: "completed", sourceIDs: []),
            ReviewSessionRecord(id: "bio-old", title: "ATP synthase", createdAt: Self.now.addingTimeInterval(-60), status: "completed", sourceIDs: [], goalID: "bio"),
        ]
        let chats = vm.notebookChats(notebookID: "bio")
        #expect(Set(chats.map(\.id)) == ["bio-new", "bio-old"])
        #expect(chats.map(\.id) == vm.reviewSessionGroups(for: [vm.notebook(id: "bio")!]).byNotebookID["bio"]?.map(\.id),
                "the rail's own order")
        #expect(vm.notebookChats(notebookID: "missing").isEmpty)
    }

    @Test("The guide's All chats search narrows by title, ignoring case and accents, and keeps the order")
    func allChatsSearchNarrowsByTitle() {
        let chats = [
            NotebookChatGuide.RecentChat(id: "a", title: "Alzheimer’s and Blood Flow", date: Self.now),
            NotebookChatGuide.RecentChat(id: "b", title: "Ontogeny of microglia", date: Self.now),
            NotebookChatGuide.RecentChat(id: "c", title: "Reprogramming Microglia", date: Self.now),
        ]
        #expect(NotebookChatGuide.chats(chats, matching: "").map(\.id) == ["a", "b", "c"])
        #expect(NotebookChatGuide.chats(chats, matching: "  ").map(\.id) == ["a", "b", "c"])
        #expect(NotebookChatGuide.chats(chats, matching: "MICROGLIA").map(\.id) == ["b", "c"])
        #expect(NotebookChatGuide.chats(chats, matching: " alzheimer ").map(\.id) == ["a"])
        #expect(NotebookChatGuide.chats(chats, matching: "ontogény").map(\.id) == ["b"])
        #expect(NotebookChatGuide.chats(chats, matching: "thyroid").isEmpty)
    }

    @Test("Two windows hold two notebooks, and each reads and closes its own")
    func twoWindowsHoldTwoNotebooks() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        // Both in whichever library the test host has open, so the marks count.
        vm.learningGoals = [
            Self.notebook("bio", title: "Bioenergetics", teamID: vm.activeTeamID),
            Self.notebook("neuro", title: "Neuroscience", teamID: vm.activeTeamID),
        ]
        let left = StudioWindowState()
        let right = StudioWindowState()

        StudioWindowDestination.notebook("bio").open(in: left, vm: vm)
        #expect(vm.activeNotebookId == "bio", "the active Notebook, a preference on this Mac, follows the notebook opened")
        StudioWindowDestination.notebook("neuro").open(in: right, vm: vm)
        #expect(vm.activeNotebookId == "neuro")

        #expect(left.NotebookID == "bio")
        #expect(right.NotebookID == "neuro")
        #expect(vm.inWindow(left) { vm.workbenchNotebookID } == "bio")
        #expect(vm.inWindow(right) { vm.workbenchNotebookID } == "neuro")
        #expect(vm.inWindow(left) { vm.railScopedNotebook?.id } == "bio")
        #expect(vm.railScopedNotebook(in: right)?.id == "neuro")
        #expect(vm.sidebarNotebook(in: left)?.title == "Bioenergetics")
        #expect(vm.sidebarNotebook(in: right)?.title == "Neuroscience")
        // The view model's own fallback window opened nothing.
        #expect(vm.workbenchNotebookID == nil)

        // Closing the open notebook closes it in that window only.
        vm.inWindow(left) { vm.closeNotebook() }
        #expect(left.NotebookID == nil)
        #expect(right.NotebookID == "neuro")

        // Each window keeps its own notebook through its scene snapshot.
        #expect(StudioWindowState(snapshot: right.snapshot).NotebookID == "neuro")
        #expect(StudioWindowState(snapshot: left.snapshot).NotebookID == nil)
    }

    @Test("Opening a notebook advances only the window's scene snapshot, never the template")
    func openingWritesOnlyTheSceneSnapshot() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let window = StudioWindowState()
        let template = templateValues()
        let revision = window.persistenceRevision

        window.NotebookID = "bio"
        #expect(window.persistenceRevision == revision + 1)
        #expect(templateValues() == template)

        // Reopening it is no change; neither is a search's widened list,
        // which is a moment the snapshot does not keep.
        window.NotebookID = "bio"
        window.notebook?.sourcesExpanded = true
        #expect(window.persistenceRevision == revision + 1)
        #expect(window.snapshot.notebook == NotebookWorkspace(notebookID: "bio"))

        // The arrangement is kept, so changing it is a change.
        window.notebook?.sourcesCollapsed = true
        #expect(window.persistenceRevision == revision + 2)

        window.NotebookID = nil
        #expect(window.persistenceRevision == revision + 3)
        #expect(templateValues() == template)

        // A brand-new window starts from the template, which never holds a
        // notebook.
        window.NotebookID = "bio"
        #expect(StudioWindowState().notebook == nil)
    }

    @Test("Archiving or merging a notebook reaches every window that holds it")
    func everyWindowFollowsArchiveAndMerge() {
        let vm = makeViewModel()
        let registered = StudioWindowState()
        let unrelated = StudioWindowState()
        StudioWindowRegistry.shared.register(registered)
        StudioWindowRegistry.shared.register(unrelated)
        defer {
            StudioWindowRegistry.shared.unregister(registered)
            StudioWindowRegistry.shared.unregister(unrelated)
        }

        registered.NotebookID = "old"
        unrelated.NotebookID = "other"
        vm.workbenchNotebookID = "old"
        vm.moveNotebookInEveryWindow("old", to: "survivor")
        #expect(registered.NotebookID == "survivor")
        #expect(vm.workbenchNotebookID == "survivor")
        #expect(unrelated.NotebookID == "other")

        vm.closeNotebookInEveryWindow("survivor")
        #expect(registered.notebook == nil)
        #expect(vm.workbenchNotebookID == nil)
        #expect(unrelated.NotebookID == "other")
    }

    @Test("MCP is told each window's notebook and which window is frontmost, as they change")
    func windowsPublishTheirNotebooksToMCP() {
        // Other suites register windows too, so this reads only its own.
        let first = StudioWindowState()
        let second = StudioWindowState()
        let firstID = "nb-\(UUID().uuidString)"
        let secondID = "nb-\(UUID().uuidString)"
        func published(_ notebookID: String) -> MCPAppWindows.Window? {
            MCPAppWindows.current.first { $0.notebookID == notebookID }
        }
        StudioWindowRegistry.shared.register(first)
        StudioWindowRegistry.shared.register(second)
        defer {
            StudioWindowRegistry.shared.unregister(first)
            StudioWindowRegistry.shared.unregister(second)
        }

        first.NotebookID = firstID
        second.NotebookID = secondID
        StudioWindowRegistry.shared.activate(second)
        #expect(published(secondID)?.isFrontmost == true)
        #expect(published(firstID)?.isFrontmost == false)
        #expect(MCPAppWindows.current.first?.notebookID == secondID)

        StudioWindowRegistry.shared.activate(first)
        #expect(published(firstID)?.isFrontmost == true)
        #expect(published(secondID)?.isFrontmost == false)

        // Leaving the notebook, and closing the window, both reach MCP.
        second.NotebookID = nil
        #expect(published(secondID) == nil)
        StudioWindowRegistry.shared.unregister(first)
        #expect(published(firstID) == nil)

        // A window no registry holds publishes nothing.
        let loose = StudioWindowState()
        let looseID = "nb-\(UUID().uuidString)"
        loose.NotebookID = looseID
        #expect(published(looseID) == nil)
    }

    @Test("In a notebook the window's sidebar toggle folds and shows the Sources column, and touches nothing else")
    func sidebarToggleFoldsSources() {
        let window = StudioWindowState()
        window.NotebookID = "bio"
        #expect(window.sidebarToggleReadsShown)
        let spaceSidebarHidden = window.spaceSidebarHidden

        window.setSidebarShownFromToggle(false)
        #expect(window.spaceSidebarHidden == spaceSidebarHidden, "the Space sidebar stays as it is")
        #expect(window.notebook?.sourcesCollapsed == true)
        #expect(!window.sidebarToggleReadsShown)

        window.notebook?.sourcesCollapsed = false
        window.notebook?.sourcesExpanded = true
        window.setSidebarShownFromToggle(false)
        #expect(window.notebook?.sourcesExpanded == false, "folded, the column keeps no search's list")

        window.setSidebarShownFromToggle(true)
        #expect(window.notebook?.sourcesCollapsed == false)
    }
}

/// A window holding a notebook: its center is the window's own tabs, which
/// take every center-tab request as a window with no notebook does.
@Suite("Notebook in the window's tabs")
@MainActor
struct NotebookRoutingTests {

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]

    /// The unit host's defaults are the real ones: a pane change in the
    /// library underneath writes the template, so each test puts it back.
    private func capturingTemplate() -> () -> Void {
        let template = Self.templateKeys.map { UserDefaults.standard.object(forKey: $0) }
        return {
            for (key, value) in zip(Self.templateKeys, template) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    @Test("A notebook opens on its chat in the window's own tabs, and closing it restores the tabs")
    func closingTheNotebookRestoresTheTabs() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = StudioWindowState()
        window.centerTabGroups = .defaultLayout
        let tabs = window.centerTabGroups.groups.map(\.tabs)
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.NotebookID == "bio")
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.chat], "the Space stays one of the pane's tabs")
        vm.inWindow(window) { vm.closeNotebook() }
        #expect(window.notebook == nil)
        #expect(window.centerTabGroups.groups.map(\.tabs) == tabs)
    }

    @Test("A notebook opened in a window of two panes keeps them as arranged")
    func notebookKeepsTwoPanes() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts], activeTab: .artifacts),
            .init(tabs: [.reader], activeTab: .reader),
        ])
        let panes = window.centerTabGroups
        vm.openNotebook("bio", in: window, startsNotebookChat: false)
        #expect(window.NotebookID == "bio")
        #expect(window.centerTabGroups == panes)
    }

    @Test("Full Screen draws one pane alone, and ends when a hidden pane is asked for")
    func fullScreenPane() {
        let restore = capturingTemplate()
        defer { restore() }
        let vm = makeViewModel()
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.library, .artifacts], activeTab: .library),
            .init(tabs: [.reader], activeTab: .reader),
        ])
        let reader = window.centerTabGroups.groups[1].id

        window.toggleFullScreen(ofGroup: reader)
        #expect(window.drawnCenterGroups.map(\.id) == [reader])
        #expect(!window.drawsNavigationRail, "Home's sidebar steps aside with the other panes")

        // The Reader asked for again is the pane already on screen.
        vm.activateCenterTab(.reader, in: window)
        #expect(window.fullScreenGroupID == reader)

        // The same button brings every pane back.
        window.toggleFullScreen(ofGroup: reader)
        #expect(window.fullScreenGroupID == nil)
        #expect(window.drawnCenterGroups.count == 2)

        // A place in front of a hidden pane, asked for, ends it.
        window.toggleFullScreen(ofGroup: reader)
        vm.activateCenterTab(.library, in: window)
        #expect(window.fullScreenGroupID == nil)

        // So does a hidden pane changing what it shows.
        window.toggleFullScreen(ofGroup: reader)
        window.centerTabGroups.groups[0].activeTab = .artifacts
        #expect(window.fullScreenGroupID == nil)

        // And the full-screen pane closing.
        window.toggleFullScreen(ofGroup: window.centerTabGroups.groups[0].id)
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [.reader], activeTab: .reader)])
        #expect(window.fullScreenGroup == nil)
        #expect(window.fullScreenGroupID == nil)
    }
}

/// The Add sources sheet's field, its ticks, Add all and Upload PDF, the
/// boxes, the Sources column's drops, and the workspace's layout and sizing.
@Suite("Notebook Add sources and layout helpers")
struct NotebookAddSourcesTests {
    @Test("The Sources field offers Library and Web; Return runs the selected search")
    func sourcesSearchSubmission() {
        #expect(NotebookSourcesSearchScope.submission(scope: .library, query: "") == nil)
        #expect(NotebookSourcesSearchScope.submission(scope: .library, query: "   ") == nil)
        #expect(NotebookSourcesSearchScope.submission(scope: .web, query: "   ") == .web, "Web with no words searches the notebook's subject")
        #expect(NotebookSourcesSearchScope.submission(scope: .papers, query: "") == .papers)
        #expect(NotebookSourcesSearchScope.submission(scope: .library, query: "mootha") == nil, "Library searches only the library; Return never reaches the web from it")
        #expect(NotebookSourcesSearchScope.submission(scope: .web, query: "mootha") == .web)
        #expect(NotebookSourcesSearchScope.submission(scope: .papers, query: "mootha") == .papers)
        #expect(NotebookSourcesSearchScope.primaryScopes.map(\.title) == ["Library", "Web"])
        #expect(NotebookSourcesSearchScope.library.discoveryMode == nil, "the library answers as you type")
    }

    @Test("A results card says what it found and how much the library already holds")
    func discoveryCardText() {
        func row(_ id: String, _ holding: NotebookDiscoveryRow.Holding = .new) -> NotebookDiscoveryRow {
            NotebookDiscoveryRow(id: id, url: "https://\(id).org/", title: id, kind: .paper, site: "\(id).org", holding: holding)
        }
        let rows = [row("a"), row("b", .inLibrary(sourceID: "b")), row("c", .inNotebook(sourceID: "c")), row("d")]
        #expect(NotebookDiscoveryCardText.headline(mode: .web, rows: rows) == "4 on the web · 2 in your library")
        #expect(NotebookDiscoveryCardText.headline(mode: .papers, rows: [row("a")]) == "1 in PubMed")
        #expect(NotebookDiscoveryCardText.headline(mode: .web, rows: []) == "Nothing found on the web")
        #expect(NotebookDiscoveryCardText.moreTitle(rowCount: 10, shown: 3) == "7 more")
        #expect(NotebookDiscoveryCardText.moreTitle(rowCount: 3, shown: 3) == "Review")
    }

    @Test("A search's whole list widens Sources and narrows Studio, and is a moment no snapshot keeps")
    func expandedSourcesColumn() throws {
        typealias Sizing = NotebookWorkspaceSizing
        let expanded = NotebookWorkspace(notebookID: "bio", sourcesExpanded: true)
        let widths = Sizing.columnWidths(for: expanded, totalWidth: 1_250)
        #expect(widths.sources == Sizing.expandedSourcesWidth)
        #expect(widths.studio == Sizing.sideMinimumWidth)
        #expect(widths.center >= Sizing.centerMinimumWidth(for: expanded))
        #expect(Sizing.minimumWidth(for: expanded) == Sizing.minimumWidth(for: NotebookWorkspace(notebookID: "bio")),
                "the list asks for room, never for a fold")

        // Folded, the column shows no list, whatever the flag says.
        var folded = expanded
        folded.sourcesCollapsed = true
        #expect(Sizing.columnWidths(for: folded, totalWidth: 1_250).sources == 0, "a folded Sources column leaves the window")

        #expect(!expanded.persisted.sourcesExpanded)
        let decoded = try JSONDecoder().decode(NotebookWorkspace.self, from: JSONEncoder().encode(expanded))
        #expect(!decoded.sourcesExpanded)
    }

    @Test("The field reads an address as a link and anything else as words to search")
    func fieldIntent() {
        #expect(NotebookSourcePicking.intent(of: "") == .empty)
        #expect(NotebookSourcePicking.intent(of: "   ") == .empty)
        #expect(NotebookSourcePicking.intent(of: "https://example.com/paper") == .link("https://example.com/paper"))
        #expect(NotebookSourcePicking.intent(of: "  http://example.org/a  ") == .link("http://example.org/a"))
        #expect(NotebookSourcePicking.intent(of: "10.1038/s41586-020-2649-2") == .link("https://doi.org/10.1038/s41586-020-2649-2"))
        #expect(NotebookSourcePicking.intent(of: "doi:10.1126/science.abc1234") == .link("https://doi.org/10.1126/science.abc1234"))
        #expect(NotebookSourcePicking.intent(of: "mitochondrial transplantation") == .search("mitochondrial transplantation"))
        #expect(NotebookSourcePicking.intent(of: "https://example.com two words") == .search("https://example.com two words"))
        #expect(NotebookSourcePicking.intent(of: "localhost") == .search("localhost"))
    }

    @Test("Ticks count only rows still on offer, and added rows leave the list")
    func picking() {
        var picking = NotebookSourcePicking()
        let results = ["a", "b", "c"]
        #expect(picking.selectAllState(in: results) == .unchecked)
        picking.toggle("b")
        #expect(picking.selection(in: results) == ["b"])
        #expect(picking.selectAllState(in: results) == .mixed)
        picking.toggleAll(in: results)
        #expect(picking.selection(in: results) == ["a", "b", "c"])
        #expect(picking.selectAllState(in: results) == .checked)
        picking.toggleAll(in: results)
        #expect(picking.selection(in: results).isEmpty)

        picking.toggle("a")
        picking.toggle("c")
        picking.markAdded(["a"])
        #expect(picking.offered(results) == ["b", "c"])
        #expect(picking.selection(in: results) == ["c"])
        // A new search that no longer lists a ticked row does not count it.
        #expect(picking.selection(in: ["b"]).isEmpty)
        #expect(NotebookSourcePicking.addTitle(count: 0) == "Add")
        #expect(NotebookSourcePicking.addTitle(count: 3) == "Add 3")
    }

    @Test("A box is checked, partly checked or not, and nothing to tick reads unchecked")
    func tickState() {
        #expect(NotebookTickState.of(ticked: 0, total: 0) == .unchecked)
        #expect(NotebookTickState.of(ticked: 0, total: 4) == .unchecked)
        #expect(NotebookTickState.of(ticked: 2, total: 4) == .mixed)
        #expect(NotebookTickState.of(ticked: 4, total: 4) == .checked)
        #expect(NotebookTickState.checked.symbolName == "checkmark.square.fill")
        #expect(NotebookTickState.mixed.symbolName == "minus.square.fill")
        #expect(NotebookTickState.unchecked.symbolName == "square")
    }

    @Test("Add all says how many it takes, and asks first above ten")
    func addAll() {
        #expect(NotebookSourcePicking.addAllTitle(count: 23) == "Add all 23")
        #expect(!NotebookSourcePicking.addAllNeedsConfirmation(count: 10))
        #expect(NotebookSourcePicking.addAllNeedsConfirmation(count: 11))
        #expect(NotebookSourcePicking.addAllConfirmationTitle(count: 23, notebookTitle: "Bio")
            == "Add 23 sources to \u{201C}Bio\u{201D}?")
    }

    @Test("Upload PDF says one file's outcome, or how many of several landed")
    func uploadToast() {
        typealias Outcome = StudioViewModel.NotebookImportOutcome
        let added = Outcome(sourceID: "a", library: .added, membership: .added)
        let held = Outcome(sourceID: "b", library: .alreadyHeld, membership: .added)
        let failed = Outcome(library: .failed("x.pdf: unreadable"), membership: .none)
        #expect(NotebookSourcePicking.uploadToast([], notebookTitle: "Bio") == nil)
        #expect(NotebookSourcePicking.uploadToast([added], notebookTitle: "Bio")
            == StudioViewModel.notebookImportToast(added, notebookTitle: "Bio"))
        #expect(NotebookSourcePicking.uploadToast([added, held], notebookTitle: "Bio")
            == "Added 2 PDFs to \u{201C}Bio\u{201D}")
        #expect(NotebookSourcePicking.uploadToast([added, failed], notebookTitle: "Bio")
            == "Added 1 of 2 PDFs to \u{201C}Bio\u{201D}. x.pdf: unreadable")
    }

    @Test("A drop on the Sources column: the app's rows join, files alone import as papers where the notebook takes them")
    func sourcesColumnDrop() {
        // A paper's row offers its file to Finder too; it is still a row.
        #expect(NotebookSourcesDrop.kind(carriesSources: true, carriesFiles: true, acceptsPDFs: true) == .sources)
        #expect(NotebookSourcesDrop.kind(carriesSources: false, carriesFiles: true, acceptsPDFs: true) == .pdfs)
        #expect(NotebookSourcesDrop.kind(carriesSources: false, carriesFiles: true, acceptsPDFs: false) == .none)
        #expect(NotebookSourcesDrop.kind(carriesSources: false, carriesFiles: false, acceptsPDFs: true) == .none)
    }

    @Test("A dropped file's URL is read from what Finder and other apps hand over, and only a PDF is taken")
    func droppedFileURLs() {
        let pdf = URL(fileURLWithPath: "/tmp/Paper One.pdf")
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf.dataRepresentation) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf as NSURL) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf.absoluteString) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: "/tmp/Paper One.pdf") == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: pdf) == pdf)
        #expect(PaperFileDrop.fileURL(fromLoadedItem: nil) == nil)
        #expect(PaperFileDrop.isPDFFile(pdf))
        #expect(PaperFileDrop.isPDFFile(URL(fileURLWithPath: "/tmp/SCAN.PDF")))
        #expect(!PaperFileDrop.isPDFFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!PaperFileDrop.isPDFFile(URL(string: "https://example.com/paper.pdf")))
        #expect(!PaperFileDrop.isPDFFile(nil))
    }

    /// The panes of a chat beside a paper: what the center needs in the
    /// sizing tests below, as `StudioWindowState.notebookPanesMinimum` reads it.
    private static let pairMinimum = StudioCenterTabGroupSizing.minimumChatContentWidth + 1 + 420

    @Test("The workspace's minimum width is its two side columns and its center's panes")
    func sizing() {
        typealias Sizing = NotebookWorkspaceSizing
        let chatOnly = NotebookWorkspace(notebookID: "bio")
        let folded = NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true)
        let panes = Self.pairMinimum
        let chatWidth = StudioCenterTabGroupSizing.minimumChatContentWidth
        let side = Sizing.sideMinimumWidth + Sizing.separatorWidth
        #expect(Sizing.minimumWidth(for: chatOnly) == side + chatWidth + side)
        #expect(Sizing.minimumWidth(for: chatOnly, studioShows: false) == side + chatWidth, "an immersive video has Studio step aside")
        #expect(Sizing.centerMinimumWidth(for: chatOnly, panesMinimum: panes) == panes, "the center needs what its panes need")
        #expect(Sizing.minimumWidth(for: folded, panesMinimum: panes) == panes + side,
                "a folded Sources column takes no strip and no separator")
        let foldedWidths = Sizing.columnWidths(for: folded, totalWidth: 1_250)
        #expect(foldedWidths.sources == 0)

        // Studio folded leaves the window too: no strip, no separator.
        var bothFolded = folded
        bothFolded.studioCollapsed = true
        let bare = Sizing.columnWidths(for: bothFolded, totalWidth: 1_250)
        #expect(bare.sources == 0 && bare.studio == 0 && bare.center == 1_250)
        #expect(Sizing.minimumWidth(for: bothFolded, panesMinimum: panes) == panes)
        #expect(foldedWidths.center + foldedWidths.studio + Sizing.separatorWidth == 1_250)

        #expect(Sizing.sideWidth(totalWidth: 400) == Sizing.sideMinimumWidth)
        #expect(Sizing.sideWidth(totalWidth: 4_000) == Sizing.sideMaximumWidth)
        #expect(Sizing.sideWidth(totalWidth: 1_250) == 300, "a quarter, less a little, at the product owner's window beside the rail's strip")
    }

    @Test("Sources and Studio take their shares, a folded one nothing, and the center the rest")
    func columnWidths() {
        typealias Sizing = NotebookWorkspaceSizing
        let separators = Sizing.separatorWidth * 2

        // Chat alone, 1,250 points: Gemini's quarter · half · quarter.
        let chatOnly = Sizing.columnWidths(for: NotebookWorkspace(notebookID: "bio"), totalWidth: 1_250)
        #expect(chatOnly.sources == 300 && chatOnly.studio == 300)
        #expect(chatOnly.sources + chatOnly.center + chatOnly.studio + separators == 1_250)

        // A paper open beside the chat with Sources folded: no column,
        // Studio stays, and the center holds both panes.
        let reading = NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true)
        let panes = Self.pairMinimum
        let readingWidths = Sizing.columnWidths(for: reading, totalWidth: 1_250, panesMinimum: panes)
        #expect(readingWidths.sources == 0)
        #expect(readingWidths.studio == 300)
        #expect(readingWidths.center >= panes)

        // Where the shares would leave the center short, the open columns
        // give it back down to their minimum, Studio first.
        let tight = Sizing.minimumWidth(for: reading, panesMinimum: panes) + 4
        let tightWidths = Sizing.columnWidths(for: reading, totalWidth: tight, panesMinimum: panes)
        #expect(tightWidths.center >= panes, "never clipped at the shares' widths")
        #expect(tightWidths.studio >= Sizing.sideMinimumWidth)
        // Folded Sources leaves with its separator: only Studio's remains.
        #expect(abs(tightWidths.sources + tightWidths.center + tightWidths.studio + Sizing.separatorWidth - tight) < 0.001)

        // Studio stepping aside for an immersive video takes no width.
        let immersive = Sizing.columnWidths(for: NotebookWorkspace(notebookID: "bio"), totalWidth: 1_250, studioShows: false)
        #expect(immersive.studio == 0)
        #expect(abs(immersive.sources + immersive.center + Sizing.separatorWidth - 1_250) < 0.001)
    }

    @Test("A dragged Sources column keeps its width within bounds, narrows Studio before the chat, and stays on this Mac")
    func draggedSourcesColumn() {
        typealias Sizing = NotebookWorkspaceSizing
        let separators = Sizing.separatorWidth * 2
        let notebook = NotebookWorkspace(notebookID: "bio")

        // A drag moves the edge by the pointer, within 260…560.
        #expect(Sizing.draggedSourcesWidth(startWidth: 300, translation: 80) == 380)
        #expect(Sizing.draggedSourcesWidth(startWidth: 300, translation: 1_000) == Sizing.sourcesMaximumWidth)
        #expect(Sizing.draggedSourcesWidth(startWidth: 300, translation: -1_000) == Sizing.sideMinimumWidth)
        #expect(Sizing.sourcesMaximumWidth > Sizing.sideMaximumWidth, "a drag reaches past the share's cap")

        // Never dragged, the column takes its share; dragged, its own width,
        // and the Studio keeps its share while the center has room.
        #expect(Sizing.columnWidths(for: notebook, totalWidth: 1_250, sourcesPreferredWidth: nil).sources == 300)
        let dragged = Sizing.columnWidths(for: notebook, totalWidth: 1_250, sourcesPreferredWidth: 420)
        #expect(dragged.sources == 420 && dragged.studio == 300)
        #expect(dragged.sources + dragged.center + dragged.studio + separators == 1_250)
        // A kept width out of bounds (another display, an older build) is
        // brought back within them.
        #expect(Sizing.columnWidths(for: notebook, totalWidth: 1_250, sourcesPreferredWidth: 90).sources == Sizing.sideMinimumWidth)
        #expect(Sizing.columnWidths(for: notebook, totalWidth: 2_400, sourcesPreferredWidth: 900).sources == Sizing.sourcesMaximumWidth)

        // Dragged wide in a window too narrow for it: Studio gives its room
        // first, then Sources, and the chat keeps its minimum.
        let tight = Sizing.minimumWidth(for: notebook) + 100
        let wide = Sizing.columnWidths(for: notebook, totalWidth: tight, sourcesPreferredWidth: Sizing.sourcesMaximumWidth)
        #expect(wide.studio == Sizing.sideMinimumWidth)
        #expect(wide.center >= Sizing.centerMinimumWidth(for: notebook))
        #expect(wide.sources == Sizing.sideMinimumWidth + 100)
        #expect(abs(wide.sources + wide.center + wide.studio + separators - tight) < 0.001)

        // Folded, Sources has no width; a search's whole list still gets
        // its widened width, or the learner's when that is wider.
        var folded = notebook
        folded.sourcesCollapsed = true
        #expect(Sizing.columnWidths(for: folded, totalWidth: 1_250, sourcesPreferredWidth: 420).sources == 0)
        let searching = NotebookWorkspace(notebookID: "bio", sourcesExpanded: true)
        #expect(Sizing.columnWidths(for: searching, totalWidth: 1_400, sourcesPreferredWidth: 300).sources == Sizing.expandedSourcesWidth)
        #expect(Sizing.columnWidths(for: searching, totalWidth: 1_400, sourcesPreferredWidth: 520).sources == 520)

        // What a drag keeps is the column as it shows once the center has its
        // room, never the search's widened list.
        #expect(Sizing.settledSourcesWidth(for: notebook, totalWidth: 1_250, draggedWidth: 420) == 420)
        #expect(Sizing.settledSourcesWidth(for: searching, totalWidth: 1_400, draggedWidth: 300) == 300)
        #expect(Sizing.settledSourcesWidth(for: notebook, totalWidth: tight, draggedWidth: Sizing.sourcesMaximumWidth)
            == Sizing.sideMinimumWidth + 100)

        // The minimum the folds and the rail judge by is the column's own,
        // whatever width was dragged.
        #expect(Sizing.sourcesFootprint(for: notebook) == Sizing.sideMinimumWidth + Sizing.separatorWidth)

        // Absolute points, so this Mac's alone, declared with a reason.
        #expect(!SyncedPreferenceKeys.isSynced(Sizing.sourcesWidthPreferenceKey))
        #expect(SyncedPreferenceKeys.excluded[Sizing.sourcesWidthPreferenceKey] != nil)
    }

    @Test("A narrow window folds Sources away, then Studio to its strip, for the center's sake alone, and never the rail")
    func roomMaking() {
        typealias Sizing = NotebookWorkspaceSizing
        let pair = NotebookWorkspace(notebookID: "bio")
        let panes = Self.pairMinimum
        let needed = Sizing.minimumWidth(for: pair, panesMinimum: panes)
        let sourcesSaving = Sizing.sideMinimumWidth + Sizing.separatorWidth

        let roomy = Sizing.folds(for: pair, totalWidth: needed + 50, panesMinimum: panes)
        #expect(!roomy.sources && !roomy.studio)

        let tight = Sizing.folds(for: pair, totalWidth: needed - 10, panesMinimum: panes)
        #expect(tight.sources && !tight.studio, "Sources goes first; Studio stays on screen")

        let narrow = Sizing.folds(for: pair, totalWidth: needed - sourcesSaving - 10, panesMinimum: panes)
        #expect(narrow.sources && narrow.studio)

        // The product owner's 1,302-point window with the rail as its 52-point strip:
        // a paper beside the chat folds Sources and keeps Studio.
        let wide = Sizing.folds(for: pair, totalWidth: 1_302 - 52, panesMinimum: panes)
        #expect(wide.sources && !wide.studio)

        // Folded already, nothing more to fold: the pass never reaches for
        // the rail, whose visibility is a synced preference.
        var folded = pair
        folded.sourcesCollapsed = true
        folded.studioCollapsed = true
        let none = Sizing.folds(for: folded, totalWidth: 300, panesMinimum: panes)
        #expect(!none.sources && !none.studio)

        // Studio stepping aside for an immersive video is not folded.
        let immersive = Sizing.folds(for: pair, totalWidth: 300, studioShows: false, panesMinimum: panes)
        #expect(immersive.sources && !immersive.studio)
    }
}
