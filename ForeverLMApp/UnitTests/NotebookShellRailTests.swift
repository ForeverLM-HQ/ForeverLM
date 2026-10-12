import Foundation
import Testing
@testable import ForeverLM

// Shell stage 4 (docs/notebooks-design.md, "The rail", "Homing"): the rail led
// by the notebooks, Activity from the Now chip, the Space's notebook filter and
// "Not in a notebook", Add to Notebook ▸, courses living in notebooks, and the
// learner's words. The Notebooks home that led the rail until 2026-10-09 is
// gone; the Space is the first row and the window's home.

private func stamp(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_790_000_000 + seconds)
}

/// An active notebook of the library `teamID` names, holding `sources`.
private func notebookRecord(
    _ id: String,
    title: String? = nil,
    sources: [String] = [],
    createdAt: Date = stamp(0),
    archived: Bool = false,
    teamID: String? = nil
) -> LearningGoalRecord {
    LearningGoalRecord(
        id: id,
        title: title ?? id,
        startAt: stamp(0),
        endAt: LearningGoalRecord.openEndedEndAt,
        createdAt: createdAt,
        updatedAt: createdAt,
        status: (archived ? LearningGoalStatus.archived : .active).rawValue,
        items: sources.map { LearningGoalItem(id: "item-\(id)-\($0)", goalID: id, sourceID: $0, addedAt: stamp(0)) },
        kind: LearningGoalRecord.companionKind,
        teamID: teamID
    )
}

/// A window's arrangement writes the template every new window starts from,
/// opening a notebook writes the active Notebook and this Mac's notebook
/// stamps: the unit host's defaults are the real ones, so each test that
/// touches a window puts them back.
@MainActor
private func capturingWindowDefaults() -> () -> Void {
    let keys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
        NotebookRecency.preferenceKey,
    ]
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    let activeNotebookID = ActiveNotebookPreference.notebookID
    return {
        for (key, value) in zip(keys, saved) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        ActiveNotebookPreference.notebookID = activeNotebookID
    }
}

// MARK: - The rail and the Now chip

@Suite("The Now chip's ways on")
struct DayNowMenuRowTests {
    @Test("Activity is reached from the Now chip whatever the calendar's state")
    func activityIsAlwaysOffered() {
        let states: [(on: Bool, blocked: Bool, bout: Bool, event: Bool)] = [
            (true, false, false, false), (true, false, true, false), (true, false, false, true),
            (false, true, false, false), (false, false, false, false),
        ]
        for state in states {
            let rows = DayNowMenuRow.rows(
                calendarOn: state.on,
                calendarBlocked: state.blocked,
                boutRunning: state.bout,
                inEvent: state.event
            )
            #expect(rows.last == .activity, "Activity closes the popover's rows")
            #expect(rows.filter { $0 == .activity }.count == 1)
        }
    }

    @Test("The calendar's own rows are as before")
    func calendarRows() {
        #expect(DayNowMenuRow.rows(calendarOn: true, calendarBlocked: false, boutRunning: false, inEvent: false)
            == [.planDay, .startBout, .openCalendar, .activity])
        // A bout on the clock, or an event (whose Start Pomodoro Timer… is beside its
        // title), leaves the row's Start Pomodoro Timer… out.
        #expect(DayNowMenuRow.rows(calendarOn: true, calendarBlocked: false, boutRunning: true, inEvent: false)
            == [.planDay, .openCalendar, .activity])
        #expect(DayNowMenuRow.rows(calendarOn: true, calendarBlocked: false, boutRunning: false, inEvent: true)
            == [.planDay, .openCalendar, .activity])
        #expect(DayNowMenuRow.rows(calendarOn: false, calendarBlocked: true, boutRunning: false, inEvent: false)
            == [.openPrivacySettings, .activity])
        #expect(DayNowMenuRow.rows(calendarOn: false, calendarBlocked: false, boutRunning: false, inEvent: false)
            == [.turnOnCalendar, .activity])
    }
}

// MARK: - The icon rail and Home's sidebar

@Suite("The icon rail and Home's sidebar")
@MainActor
struct HomeSidebarTests {
    private func layout(_ active: StudioCenterTab) -> StudioCenterTabGroups {
        StudioCenterTabGroups(groups: [.init(tabs: [.artifacts, .courses, .notepad, .sites, .chat, .reader, .goals, .library, .memory], activeTab: active)])
    }

    @Test("‹ goes back to the place the window showed before and › forward again; a fold is no step")
    func placeHistoryBackAndForward() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.centerTabGroups = layout(.artifacts)
        window.spaceDestinationKey = SpaceDestination.pages.key
        window.notePlaceSettled()
        #expect(!window.canGoBackInPlaces, "the first place settled has nothing behind it")

        window.spaceDestinationKey = SpaceDestination.sites.key
        window.notePlaceSettled()
        window.centerTabGroups = layout(.library)
        window.notePlaceSettled()
        // Settling again where nothing moved adds no step.
        window.notePlaceSettled()
        #expect(window.placeHistory.back.count == 2)

        #expect(window.goBackInPlaces() != nil)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.artifacts])
        #expect(window.spaceDestinationKey == SpaceDestination.sites.key)
        #expect(window.goBackInPlaces() != nil)
        #expect(window.spaceDestinationKey == SpaceDestination.pages.key)
        #expect(!window.canGoBackInPlaces)
        #expect(window.canGoForwardInPlaces)

        #expect(window.goForwardInPlaces() != nil)
        #expect(window.spaceDestinationKey == SpaceDestination.sites.key)
        // Going somewhere new drops what was ahead.
        window.spaceDestinationKey = SpaceDestination.images.key
        window.notePlaceSettled()
        #expect(!window.canGoForwardInPlaces)

        // The Space's place behind another pane is no move: only what is in
        // front counts.
        window.centerTabGroups = layout(.chat)
        window.notePlaceSettled()
        let steps = window.placeHistory.back.count
        window.spaceDestinationKey = SpaceDestination.drive.key
        window.notePlaceSettled()
        #expect(window.placeHistory.back.count == steps)
    }

    @Test("‹ › stand still while a memory review has the window")
    func placeHistoryWaitsOutAReview() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.centerTabGroups = layout(.artifacts)
        window.notePlaceSettled()
        window.centerTabGroups = layout(.library)
        window.notePlaceSettled()
        #expect(window.canGoBackInPlaces)
        window.memoryReviewFocus = .chat("memory-review")
        #expect(!window.canGoBackInPlaces)
        #expect(window.goBackInPlaces() == nil)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.library])
    }

    @Test("The rail is Spaces, Memory and Library, and New chat and the Browser are Home's sidebar")
    func railRowsAndSidebarRows() {
        let nothingHidden = StudioRailHiddenItems()
        // The Canvas left the rail on 2026-10-07: canvases open from the Space.
        // The Notebooks home, which led it, went on 2026-10-09.
        #expect(nothingHidden.railItems() == [.space, .memory, .library])
        #expect(nothingHidden.sidebarItems() == [.newChat, .browser])
        let hidden = StudioRailHiddenItems([.memory, .browser])
        #expect(hidden.railItems() == [.space, .library])
        #expect(hidden.sidebarItems() == [.newChat])
    }

    @Test("Home's sidebar shows on Home: a chat, the Reader, Goals; not on the Space, its Courses list, Library, Memory or Canvas")
    func sidebarFollowsHome() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.navigationRailVisible = true
        for tab in [StudioCenterTab.chat, .reader, .goals] {
            window.centerTabGroups = layout(tab)
            #expect(window.isOnHome, "\(tab) is Home's")
            #expect(window.showsHomeSidebar)
        }
        for tab in [StudioCenterTab.artifacts, .courses, .sites, .notepad, .library, .memory] {
            window.centerTabGroups = layout(tab)
            #expect(!window.isOnHome, "\(tab) is a place of its own")
            #expect(!window.showsHomeSidebar)
        }
        window.centerTabGroups = layout(.artifacts)
        #expect(window.showsSpace)
        window.centerTabGroups = layout(.courses)
        #expect(window.showsSpace, "the Courses list is drawn beside the Space's sidebar")
        window.coursePageID = "aging"
        #expect(!window.showsSpace, "a course's page has no Space sidebar")
        #expect(window.isOnHome)
        window.coursePageID = nil
        window.centerTabGroups = layout(.library)
        #expect(!window.showsSpace)
    }

    @Test("A notebook's own Pages keep their list, a notebook window has no Home sidebar, and a hidden rail hides it")
    func notebooksAndHiddenRail() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.navigationRailVisible = true
        window.centerTabGroups = layout(.notepad)
        window.artifactCanvasNotebookID = "bio"
        #expect(!window.showsSpace)
        #expect(window.isOnHome, "a notebook's Pages are not the Space")
        window.artifactCanvasNotebookID = nil
        window.centerTabGroups = layout(.chat)
        window.NotebookID = "bio"
        #expect(!window.isOnHome)
        #expect(!window.showsHomeSidebar)
        window.NotebookID = nil
        #expect(window.showsHomeSidebar)
        window.navigationRailVisible = false
        #expect(!window.showsHomeSidebar)
    }

    @Test("A Space in either pane is not Home")
    func spaceBesideChat() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.navigationRailVisible = true
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.artifacts], activeTab: .artifacts),
        ])
        #expect(!window.showsHomeSidebar)
    }
}

// MARK: - The Space's tabs

@Suite("The Space's panes")
@MainActor
struct SpaceTabTests {
    @Test("The Space and Courses are each their own pane")
    func tabsArePanes() {
        #expect(SpaceTab.courses.centerTab == .courses)
        #expect(SpaceTab.space.centerTab == .artifacts)
    }

    @Test("Goals is no pane of the Space: the Space never takes its place")
    func goalsIsNotTheSpaces() {
        // The Space | Goals bar went on 2026-10-10: Goals are the chat's to
        // show, and a Goals pane a link opened is left where it is.
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat, isPinned: true),
            .init(tabs: [.goals, .artifacts], activeTab: .goals),
        ])
        #expect(layout.showingSpaceTab(.space) == nil)
        #expect(layout.showingSpaceTab(.courses, coursesShowsList: true) == nil)
    }

    @Test("The Courses tab swaps with a Space pane, but never replaces a course's page")
    func coursesTabSwaps() throws {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat, isPinned: true),
            .init(tabs: [.artifacts, .courses, .goals], activeTab: .artifacts),
        ])
        let courses = try #require(layout.showingSpaceTab(.courses))
        #expect(courses.groups[1].activeTab == .courses)
        #expect(courses.groups[0] == layout.groups[0])
        let back = try #require(courses.showingSpaceTab(.space, coursesShowsList: true))
        #expect(back.groups[1].activeTab == .artifacts)

        // A course's page is a document: the Space tab does not replace it.
        let page = StudioCenterTabGroups(groups: [.init(tabs: [.courses, .reader], activeTab: .courses)])
        #expect(page.showingSpaceTab(.space) == nil)
        #expect(page.showingSpaceTab(.space, coursesShowsList: true) != nil)
    }

    @Test("A sidebar click swaps the page under the pointer, and leaves every other pane and pin alone")
    func swapsInPlace() throws {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat, isPinned: true),
            .init(tabs: [.courses, .reader, .notepad, .artifacts], activeTab: .courses),
        ])
        let space = try #require(layout.showingSpaceTab(.space, coursesShowsList: true))
        #expect(space.groups[0] == layout.groups[0], "the pinned chat pane is untouched")
        #expect(space.groups[1].activeTab == .artifacts)
        #expect(space.groups.count == 2)

        let back = try #require(space.showingSpaceTab(.courses))
        #expect(back.groups[1].activeTab == .courses)

        // No other pane of the Space is on screen: the caller opens the tab
        // by the ordinary rules.
        let alone = StudioCenterTabGroups(groups: [.init(tabs: [.reader, .artifacts, .courses], activeTab: .reader)])
        #expect(alone.showingSpaceTab(.courses) == nil)
    }

    @Test("A tab parked in another pane moves into the pane under the pointer")
    func movesAParkedTab() throws {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.goals, .chat], activeTab: .goals),
            .init(tabs: [.artifacts], activeTab: .artifacts),
        ])
        // Shown in the second pane already, alone there: it leaves that pane
        // (which closes) for the one the learner clicked in.
        let swapped = try #require(layout.swapping(.goals, for: .artifacts))
        #expect(swapped.groups.count == 1)
        #expect(swapped.groups[0].activeTab == .artifacts)
        #expect(Set(swapped.groups[0].tabs) == [.goals, .chat, .artifacts])

        let parked = StudioCenterTabGroups(groups: [
            .init(tabs: [.reader, .artifacts], activeTab: .reader),
            .init(tabs: [.goals], activeTab: .goals),
        ])
        let moved = try #require(parked.swapping(.goals, for: .artifacts))
        #expect(moved.groups[0].tabs == [.reader])
        #expect(moved.groups[0].activeTab == .reader)
        #expect(moved.groups[1].activeTab == .artifacts)
        #expect(parked.swapping(.goals, for: .goals) == nil)
    }

    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceTabTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    @Test("The view model swaps the Space's tab in the window asked, and a notebook leaves for the Space")
    func viewModelShowsTheTab() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.courses, .chat, .reader, .notepad, .artifacts], activeTab: .courses),
        ])
        vm.showSpaceTab(.space, in: window)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.artifacts])

        // The Courses list asked for: in place, and a course's page the
        // window held gives way to it.
        window.coursePageID = "aging"
        vm.openCoursesInReader(in: window)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.courses])
        #expect(window.coursePageID == nil)

        // The Space asked for from its All list: the window's place is All,
        // and the Space takes the pane.
        window.spaceDestinationKey = SpaceDestination.trash.key
        vm.showSpaceAll(in: window)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.artifacts])
        #expect(window.spaceDestinationKey == SpaceDestination.all.key)
        // A place asked for stays the window's.
        vm.showSpace(.sites, in: window)
        #expect(window.spaceDestinationKey == SpaceDestination.sites.key)

        let inNotebook = StudioWindowState()
        inNotebook.NotebookID = "bio"
        vm.showSpaceTab(.space, in: inNotebook)
        #expect(inNotebook.notebook == nil, "the Space is the library's: it leaves the notebook")
        #expect(inNotebook.centerTabGroups.groups.contains { $0.activeTab == .artifacts })
    }
}

// MARK: - The Artifacts index's notebook filter

@Suite("Where an Artifacts entry lives")
struct NotebookIndexFilingTests {
    private let notebooks: Set<String> = ["bio", "neuro"]
    private let members: [String: Set<String>] = ["bio": ["paper-1", "paper-2"], "neuro": ["paper-3"]]

    @Test("A filed thing lives where it is filed, a Goal's thing in its Notebook, and citing a source earns nothing")
    func filedThings() {
        let doc = NotebookIndexFiling.filed(["bio", nil])
        #expect(doc.notebooks(among: notebooks, members: members) == ["bio"])
        let underGoal = NotebookIndexFiling.filed(["goal-1"])
        #expect(underGoal.notebooks(among: notebooks, members: members, goalParents: ["goal-1": "neuro"]) == ["neuro"])
        // A home naming a notebook the library no longer holds counts as none.
        #expect(NotebookIndexFiling.filed(["gone"]).notebooks(among: notebooks, members: members).isEmpty)
        #expect(NotebookIndexFiling.filed([nil]).notebooks(among: notebooks, members: members).isEmpty)
    }

    @Test("A derived thing lives in every notebook holding its source")
    func derivedThings() {
        let walk = NotebookIndexFiling.derived(fromSources: ["paper-2"])
        #expect(walk.notebooks(among: notebooks, members: members) == ["bio"])
        let shared = NotebookIndexFiling.derived(fromSources: ["paper-1", "paper-3"])
        #expect(shared.notebooks(among: notebooks, members: members) == ["bio", "neuro"])
        #expect(NotebookIndexFiling.derived(fromSources: ["loose"]).notebooks(among: notebooks, members: members).isEmpty)
    }

    @Test("The filter: every notebook, one, or what lives in none")
    func filter() {
        #expect(ArtifactsNotebookFilter.all.admits(livingIn: []))
        #expect(ArtifactsNotebookFilter.all.admits(livingIn: ["bio"]))
        #expect(ArtifactsNotebookFilter.notInNotebook.admits(livingIn: []))
        #expect(!ArtifactsNotebookFilter.notInNotebook.admits(livingIn: ["bio"]))
        #expect(ArtifactsNotebookFilter.notebook("bio").admits(livingIn: ["bio", "neuro"]))
        #expect(!ArtifactsNotebookFilter.notebook("bio").admits(livingIn: ["neuro"]))
        #expect(!ArtifactsNotebookFilter.notebook("bio").admits(livingIn: []))
        // A notebook gone since it was chosen is every notebook again.
        #expect(ArtifactsNotebookFilter.notebook("gone").effective(notebookIDs: notebooks) == .all)
        #expect(ArtifactsNotebookFilter.notebook("bio").effective(notebookIDs: notebooks) == .notebook("bio"))
        #expect(ArtifactsNotebookFilter.notInNotebook.effective(notebookIDs: []) == .notInNotebook)
    }

    @Test("Add to Notebook ▸ offers the suggested notebooks first, then the rest by title, never one it lives in")
    func menuChoices() {
        let notebooks: [(id: String, title: String)] = [
            (id: "c", title: "🧬 Cells"), (id: "a", title: "Aging"), (id: "m", title: "Mitochondria"), (id: "z", title: "Zinc"),
        ]
        let suggestions = [
            NotebookSuggestion(notebookID: "m", heldSourceCount: 3),
            NotebookSuggestion(notebookID: "gone", heldSourceCount: 2),
            NotebookSuggestion(notebookID: "z", heldSourceCount: 1),
        ]
        let choices = NotebookMenuChoices.ordered(notebooks: notebooks, suggestions: suggestions, excluding: ["a"])
        #expect(choices.map(\.notebookID) == ["m", "z", "c"])
        #expect(choices.map(\.isSuggested) == [true, true, false])
        #expect(NotebookMenuChoices.ordered(notebooks: notebooks, suggestions: []).map(\.notebookID) == ["a", "c", "m", "z"],
                "a leading emoji does not move a title")
    }
}

// MARK: - A course's refusals, in the learner's words

@Suite("Course notebook refusals")
@MainActor
struct CourseNotebookRefusalCopyTests {
    @Test("The app says notebook in lower case; MCP's callers keep reading Notebook")
    func twoWordings() {
        let refusals: [CourseNotebookError] = [
            .courseNotFound(courseID: "c"),
            .readOnlyTeamCourse(courseTitle: "Bio"),
            .notebookNotFound(notebookID: "p"),
            .differentLibraries(courseTitle: "Bio", notebookTitle: "🧬 Cells"),
            .notebookTakesNoCourse(notebookTitle: "Cells", reason: "it is archived"),
        ]
        for refusal in refusals {
            // The learner's word is the lower-case one; the capitalised noun is the MCP error's.
            #expect(!refusal.learnerMessage.contains("Notebook"), "\(refusal.learnerMessage)")
        }
        #expect(CourseNotebookError.notebookNotFound(notebookID: "p").learnerMessage == "That notebook is no longer in your library.")
        #expect(CourseNotebookError.notebookNotFound(notebookID: "p").errorDescription == "Notebook not found: p")
        #expect(CourseNotebookError.differentLibraries(courseTitle: "Bio", notebookTitle: "Cells").errorDescription
            == "‘Bio’ and ‘Cells’ are in different libraries: a Notebook follows only a course of its own library.")
        #expect(CourseNotebookError.differentLibraries(courseTitle: "Bio", notebookTitle: "🧬 Cells").learnerMessage
            == "‘Bio’ and ‘Cells’ are in different libraries: a notebook follows only a course of its own library.")
        struct Other: LocalizedError { var errorDescription: String? { "disk full" } }
        #expect(CourseNotebookError.learnerMessage(for: Other()) == "disk full")
    }

    @Test("Link to Notebook ▸ refused tells the learner why, saying notebook")
    func refusedLinkSaysNotebook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseNotebookRefusalCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let store = try await storage.notebookFilesKnowledgeStore()
        try store.saveCourseGroup(name: "bio", metadata: CourseMetadata(title: "Bioenergetics"))

        await vm.followCourseFromMenu("bio", inNotebook: "no-such-notebook")
        let message = try #require(vm.errorMessage)
        #expect(message == "That notebook is no longer in your library.")

        // The store's own refusal stays typed, for MCP's wording.
        #expect(throws: CourseNotebookError.notebookNotFound(notebookID: "missing")) {
            try store.followCourse(courseID: "bio", notebookID: "missing")
        }
    }
}

// MARK: - Routing: a course opens where the learner is

@Suite("Courses open where the learner is")
@MainActor
struct CourseRoutingTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseRoutingTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func window(_ tabs: [StudioCenterTab] = [.reader, .chat, .courses, .artifacts]) -> StudioWindowState {
        let window = StudioWindowState()
        window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: tabs, activeTab: tabs[0])])
        return window
    }

    @Test("A course opens in the window's Courses pane, even when a notebook follows it")
    func opensInThePane() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.learningGoals = [notebookRecord("landscape", teamID: vm.activeTeamID)]
        vm.courseFollowerNotebookIDs = ["aging": ["landscape"]]

        let home = window()
        vm.openCourse("aging", in: home)
        #expect(home.notebook == nil, "a course lives in no notebook, so opening it never opens one")
        #expect(home.coursePageID == "aging")
        #expect(home.centerTabGroups.groups.map(\.activeTab) == [.courses])
    }

    @Test("A window holding a notebook keeps it, and shows the course's page in its document slot")
    func staysInTheNotebook() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.learningGoals = [notebookRecord("follower", teamID: vm.activeTeamID)]

        let following = window()
        following.NotebookID = "follower"
        vm.openCourse("aging", in: following)
        #expect(following.NotebookID == "follower", "the notebook the learner works in keeps the page")
        #expect(following.notebook?.visibleDocuments.contains(.coursePage) == true)
    }

    @Test("A course page's ‹ Courses gives its pane to the Courses list, in place")
    func backGoesToTheList() {
        let restore = capturingWindowDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let page = window([.courses, .reader, .artifacts, .chat])
        page.coursePageID = "aging"
        vm.closeCoursePage(in: page)
        #expect(page.coursePageID == nil)
        #expect(page.centerTabGroups.groups.map(\.activeTab) == [.courses], "the pane shows the list now")
    }
}

// MARK: - Add to Notebook ▸

@Suite("Add to Notebook choices")
@MainActor
struct NotebookChoicesViewModelTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookChoicesViewModelTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    @Test("The notebooks holding most of a thing's sources come first; an archived notebook takes nothing")
    func suggestedFirst() {
        let vm = makeViewModel()
        let team = vm.activeTeamID
        vm.learningGoals = [
            notebookRecord("aging", title: "Aging", sources: ["p1"], teamID: team),
            notebookRecord("mito", title: "Mitochondria", sources: ["p1", "p2"], teamID: team),
            notebookRecord("zinc", title: "Zinc", teamID: team),
            notebookRecord("old", title: "Old", sources: ["p1", "p2"], archived: true, teamID: team),
        ]
        let choices = vm.notebookChoices(forSourceIDs: ["p1", "p2"])
        #expect(choices.map(\.notebookID) == ["mito", "aging", "zinc"])
        #expect(choices.filter(\.isSuggested).map(\.notebookID) == ["mito", "aging"])
        #expect(vm.notebookChoices(forSourceIDs: ["p1"], livesIn: ["mito"]).map(\.notebookID) == ["aging", "zinc"])
    }

    @Test("The index asks the sidebar's membership index and each Goal's Notebook")
    func notebooksHolding() {
        let vm = makeViewModel()
        let team = vm.activeTeamID
        // A Goal: a companion record with a deadline, nested in a notebook.
        var goal = notebookRecord("goal-1", teamID: team)
        goal.endAt = stamp(86_400)
        goal.parentNotebookID = "mito"
        vm.learningGoals = [
            notebookRecord("mito", sources: ["p1"], teamID: team),
            notebookRecord("aging", sources: ["p2"], teamID: team),
            goal,
        ]
        #expect(vm.notebooksHolding(.derived(fromSources: ["p2"])) == ["aging"])
        #expect(vm.notebooksHolding(.filed(["goal-1"])) == ["mito"])
        #expect(vm.notebooksHolding(.filed([nil])).isEmpty)
    }

    @Test("A mnemonic reading a notebook holds is listed only there; one in no notebook stays on the Docs tab")
    func readingsListedOnlyInTheirNotebook() {
        let vm = makeViewModel()
        vm.learningGoals = [notebookRecord("mito", sources: ["p1"], teamID: vm.activeTeamID)]
        func record(_ id: String, home: String?, linked: [String] = [], kind: ArtifactKind? = .mnemonicReading) -> ArtifactRecord {
            ArtifactRecord(id: id, title: id, homeNotebookID: home, linkedNotebookIDs: linked, kind: kind, createdAt: stamp(0), updatedAt: stamp(0))
        }
        #expect(vm.isListedOnlyInItsNotebook(record("homed", home: "mito")))
        #expect(vm.isListedOnlyInItsNotebook(record("linked", home: nil, linked: ["mito"])))
        #expect(!vm.isListedOnlyInItsNotebook(record("loose", home: nil)), "made from a Reader outside a notebook")
        #expect(!vm.isListedOnlyInItsNotebook(record("orphan", home: "gone")), "its notebook was deleted")
        #expect(!vm.isListedOnlyInItsNotebook(record("page", home: "mito", kind: nil)), "a Doc is listed above the notebooks too")
    }
}
