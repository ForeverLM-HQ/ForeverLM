import Foundation
import Testing
@testable import ForeverLM

/// A notebook's Studio, asked of a window that holds the notebook: each
/// output opens in the notebook's document slot, each tile's seam goes where
/// it should, and a notebook opens on its Studio.
@Suite("Notebook Studio")
@MainActor
struct NotebookStudioTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A view model on a store of its own, deaf to other tests' change
    /// notices: a reload from its empty store mid-test would drop the
    /// sources and records a test laid out.
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookStudioTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
    }

    /// A notebook of the library the test host has open, holding `sources`.
    private static func notebook(
        _ id: String,
        sources: [String],
        archived: Bool = false,
        teamID: String?
    ) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: id == "bio" ? "Bioenergetics" : id,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: archived ? LearningGoalStatus.archived.rawValue : LearningGoalStatus.active.rawValue,
            items: sources.map { LearningGoalItem(id: "item-\(id)-\($0)", goalID: id, sourceID: $0, addedAt: now) },
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    /// A source with its text, so opening it reads what is stored. An
    /// article, which an explainer can be written about without a paper's
    /// ingestion behind it.
    private static func article(url: String, title: String, type: StudioSourceType = .article) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: type)
        article.content = "The respiratory chain pumps protons across the inner membrane."
        article.state = .ready
        return article
    }

    private static func record(
        _ id: String,
        home: String?,
        linkedURL: String? = nil,
        kind: ArtifactKind? = nil
    ) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            title: id,
            homeNotebookID: home,
            linkedNotebookIDs: home.map { [$0] } ?? [],
            linkedURL: linkedURL,
            kind: kind,
            createdAt: now,
            updatedAt: now
        )
    }

    private static let paperURL = "https://example.com/oxphos-paper"
    private static let otherURL = "https://example.com/other-paper"

    /// A view model whose library holds the "bio" notebook with one paper,
    /// that paper's explainer, a Doc filed in the notebook and one filed
    /// elsewhere, a site and an animation; and a window holding the notebook
    /// over the default panes.
    private func studio() -> (StudioViewModel, StudioWindowState, paperID: String, explainerID: String) {
        let vm = makeViewModel()
        let paper = Self.article(url: Self.paperURL, title: "Oxidative phosphorylation")
        let other = Self.article(url: Self.otherURL, title: "Another paper")
        let explainer = Self.article(
            url: GeneratedExplainer.url(explaining: paper.id),
            title: "Explainer: Oxidative phosphorylation"
        )
        vm.articles = [paper, other, explainer]
        vm.learningGoals = [
            Self.notebook("bio", sources: [paper.id], teamID: vm.activeTeamID),
            Self.notebook("shelved", sources: [paper.id], archived: true, teamID: vm.activeTeamID),
        ]
        vm.artifacts = [
            Self.record("doc-bio", home: "bio"),
            Self.record("doc-elsewhere", home: "neuro"),
            Self.record("site-bio", home: "bio", linkedURL: "https://claude.ai/code/artifact/0b2c1f0e-aaaa-bbbb-cccc-0123456789ab"),
            Self.record("animation-bio", home: "bio", kind: .animation),
        ]
        let window = StudioWindowState()
        window.centerTabGroups = .defaultLayout
        window.notebook = NotebookWorkspace(notebookID: "bio")
        return (vm, window, paper.id, explainer.id)
    }

    private func output(_ kind: NotebookOutput.Kind, _ targetID: String, sources: [String] = []) -> NotebookOutput {
        NotebookOutput(kind: kind, targetID: targetID, title: targetID, sourceIDs: sources, date: Self.now)
    }

    /// Whether a pane of `window` shows `tab`: a notebook's window shows what
    /// it opens in its own panes.
    private func shows(_ tab: StudioCenterTab, in window: StudioWindowState) -> Bool {
        window.centerTabGroups.groups.contains { $0.activeTab == tab }
    }

    // MARK: - The Studio column

    @Test("A notebook opens with its Studio showing, and another notebook in the window starts that way too")
    func notebookOpensOnItsStudio() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, _, _, _) = studio()
        let window = StudioWindowState()
        window.centerTabGroups = .defaultLayout
        vm.openNotebook("bio", in: window, startsNotebookChat: false)
        #expect(window.notebook?.studioCollapsed == false)

        // The fold is the notebook's arrangement: kept when it reopens here.
        window.notebook?.studioCollapsed = true
        vm.openNotebook("bio", in: window, startsNotebookChat: false)
        #expect(window.notebook?.studioCollapsed == true)
        vm.openNotebook("shelved", in: window, startsNotebookChat: false)
        #expect(window.notebook?.studioCollapsed == false)
    }

    // MARK: - Opening outputs

    @Test("A Doc filed in the notebook opens in a pane, in the notebook's own Docs")
    func docOpensScopedInAPane() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        await vm.openNotebookOutput(output(.doc, "doc-bio"), in: window)
        #expect(shows(.notepad, in: window))
        #expect(window.artifactCanvasNotebookID == "bio")
        #expect(vm.artifactRevealRequest?.artifactID == "doc-bio")
        #expect(vm.artifactRevealRequest?.section == .docs)
        #expect(vm.artifactRevealRequest?.windowID == window.id, "only this window's canvas answers")

        // A doc filed elsewhere — a chat's link — opens in every doc's list,
        // never one that would leave it out.
        vm.revealArtifact("doc-elsewhere", in: window)
        #expect(shows(.notepad, in: window))
        #expect(window.artifactCanvasNotebookID == nil)
        #expect(vm.docsCanvasScope(for: "doc-bio", in: window) == "bio")
        #expect(vm.docsCanvasScope(for: "doc-elsewhere", in: window) == nil)

        // Outside a notebook a doc never opens scoped.
        let plain = StudioWindowState()
        plain.centerTabGroups = .defaultLayout
        #expect(vm.docsCanvasScope(for: "doc-bio", in: plain) == nil)
    }

    @Test("A Studio row dropped on a pane of a notebook's window opens in that pane")
    func droppedOutputOpensInItsPane() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
        ])

        await vm.openNotebookOutput(output(.doc, "doc-bio"), inPaneAt: 1, in: window)
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.chat, .notepad])
        #expect(window.centerTabGroups.groups[1].tabs.contains(.reader), "what the pane showed stays a tab")
        #expect(window.focusedGroupID == window.centerTabGroups.groups[1].id)
        #expect(vm.artifactRevealRequest?.artifactID == "doc-bio")
        #expect(vm.paneTab(for: output(.walkthrough, "s")) == .reader)
        #expect(vm.paneTab(for: output(.picture, "p")) == nil)
    }

    @Test("The notebook's Docs scope goes with the notebook: closed or replaced in the window")
    func docsScopeLeavesWithTheNotebook() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        await vm.openNotebookOutput(output(.doc, "doc-bio"), in: window)
        #expect(window.artifactCanvasNotebookID == "bio")
        // Its own arrangement changing keeps it.
        window.notebook?.studioCollapsed = true
        #expect(window.artifactCanvasNotebookID == "bio")
        // The panes underneath come back on every doc, as they were.
        vm.closeNotebook(in: window)
        #expect(window.artifactCanvasNotebookID == nil)

        // Another notebook taking the window does not inherit the list.
        vm.openNotebook("bio", in: window, startsNotebookChat: false)
        await vm.openNotebookOutput(output(.doc, "doc-bio"), in: window)
        #expect(window.artifactCanvasNotebookID == "bio")
        vm.openNotebook("shelved", in: window, startsNotebookChat: false)
        #expect(window.notebook?.notebookID == "shelved")
        #expect(window.artifactCanvasNotebookID == nil)
    }

    @Test("An overview's row reads the saved overview when its run has not been let go yet")
    func overviewRowPrefersTheSavedOverview() {
        let run = AudioOverviewOutput(
            id: "overview-1", notebookID: "bio", title: "Bioenergetics", carrierSourceID: "carrier",
            sourceCount: 2, date: Self.now, state: .writing(.reading(sourceCount: 2))
        )
        let saved = AudioOverviewOutput(
            id: "overview-1", notebookID: "bio", title: "Bioenergetics", carrierSourceID: "carrier",
            sourceCount: 2, date: Self.now, state: .saved
        )
        let other = AudioOverviewOutput(
            id: "run-2", notebookID: "bio", title: "Bioenergetics", carrierSourceID: "carrier-2",
            sourceCount: 1, date: Self.now, state: .writing(.reading(sourceCount: 1))
        )
        let byID = AudioOverviewOutput.byID([run, other, saved])
        #expect(byID["overview-1"]?.isWriting == false)
        #expect(byID["run-2"]?.isWriting == true, "a run alone is its own row")
        #expect(AudioOverviewOutput.byID([saved, run])["overview-1"]?.isWriting == false)
    }

    @Test("A Site and an animation open in their own canvases")
    func siteAndAnimationOpenInTheirCanvases() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        await vm.openNotebookOutput(output(.site, "site-bio"), in: window)
        #expect(shows(.sites, in: window))
        #expect(vm.artifactRevealRequest?.section == .sites)

        await vm.openNotebookOutput(output(.animation, "animation-bio"), in: window)
        #expect(shows(.animations, in: window))
        #expect(vm.artifactRevealRequest?.section == .animations)
    }

    @Test("A course opens its page in a pane; closing the page keeps the notebook")
    func courseOpensItsPage() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        vm.courseMetadata = ["Systems Aging": CourseMetadata(title: "Systems Aging")]

        await vm.openNotebookOutput(output(.course, "Systems Aging"), in: window)
        #expect(window.coursePageID == "Systems Aging")
        #expect(shows(.courses, in: window))

        // The page's way back is the course list, and the notebook stays.
        vm.closeCoursePage(in: window)
        #expect(window.notebook?.notebookID == "bio")
        #expect(window.coursePageID == nil)
    }

    @Test("A walkthrough opens its source in the Reader and plays the walk")
    func walkthroughOpensInTheReader() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, _) = studio()

        await vm.openNotebookOutput(output(.walkthrough, paperID, sources: [paperID]), in: window)
        #expect(shows(.reader, in: window))
        #expect(window.readerArticleID == paperID)
        #expect(vm.readerWalkthroughPlayRequest?.sourceID == paperID)
    }

    @Test("An explainer opens in the Reader, with the source it explains selected")
    func explainerOpensInTheReader() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, explainerID) = studio()

        await vm.openNotebookOutput(output(.explainer, explainerID, sources: [paperID]), in: window)
        #expect(shows(.reader, in: window))
        #expect(window.readerArticleID == explainerID)
        #expect(window.sidebarSelectedSourceIDs == [paperID])

        // The Explainer tile, for a source that has one, opens it the same way.
        vm.activateCenterTab(.artifacts, in: window)
        #expect(await vm.openNotebookExplainer(of: paperID, in: window))
        #expect(shows(.reader, in: window))
        #expect(await vm.openNotebookExplainer(of: "no-explainer", in: window) == false)
    }

    @Test("An audio overview's script opens in the Reader; one still being written, or not here yet, opens nothing")
    func audioOverviewOpensItsScript() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        var pending = output(.audioOverview, "run-1")
        pending.isPending = true
        await vm.openNotebookOutput(pending, in: window)
        #expect(!shows(.reader, in: window))

        await vm.openNotebookOutput(output(.audioOverview, "overview-elsewhere"), in: window)
        #expect(!shows(.reader, in: window), "its script has not reached this Mac")

        let carrier = GeneratedAudioOverview.carrierSource(artifactID: "overview-1", title: "Bioenergetics", script: "A script.")
        vm.articles.append(carrier)
        await vm.openNotebookOutput(output(.audioOverview, "overview-1"), in: window)
        #expect(shows(.reader, in: window))
        #expect(window.readerArticleID == carrier.id)
    }

    @Test("The window's outputs list the notebook's records and its sources' explainers, newest first")
    func outputsFromTheViewModel() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, _, paperID, explainerID) = studio()
        let outputs = vm.notebookOutputs(notebookID: "bio")
        #expect(Set(outputs.map(\.id)) == [
            "doc:doc-bio", "site:site-bio", "animation:animation-bio", "explainer:\(explainerID)",
        ])
        #expect(outputs.first { $0.kind == .explainer }?.sourceIDs == [paperID])
        #expect(vm.notebookOutputs(notebookID: "missing").isEmpty)

        // Remove from Notebook for a record of this library, not for what a
        // source gave the notebook; and nothing leaves an archived notebook.
        var doc = output(.doc, "doc-bio")
        doc.teamID = vm.activeTeamID
        #expect(vm.canRemoveFromNotebook(doc, notebookID: "bio"))
        #expect(!vm.canRemoveFromNotebook(output(.explainer, explainerID), notebookID: "bio"))
        #expect(!vm.canRemoveFromNotebook(doc, notebookID: "shelved"))
    }

    // MARK: - The tiles' seams

    @Test("Cards opens the Memory pane in the notebook's window, narrowed to it; nothing takes the window before Start Review")
    func cardsTileOpensTheCardReview() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        window.memoryPaneSection = .allCards
        vm.inWindow(window) { vm.requestCardReview(scope: .notebook("bio")) }
        #expect(window.notebook?.notebookID == "bio", "the notebook stays as it was")
        #expect(shows(.memory, in: window))
        #expect(window.memoryPaneSection == .review)
        #expect(vm.memoryPaneScope(in: window) == .notebook("bio"))
        #expect(window.memoryReviewFocusSessionID == nil, "the Memory pane asks before the window is given over")

        // Every notebook's, from outside a notebook's own controls.
        let other = StudioWindowState()
        vm.inWindow(other) { vm.requestCardReview(scope: .allNotebooks) }
        #expect(vm.memoryPaneScope(in: other) == .allNotebooks)
        #expect(vm.visibleCenterTabs(in: other).contains(.memory))
        #expect(other.memoryReviewFocusSessionID == nil)
    }

    @Test("The Cards tile's Write Cards opens the notebook's ticked sources to write a card for each, no chat, and Practice starts nothing in a notebook without cards")
    func cardsTileWritesAndPractises() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, _) = studio()
        vm.inWindow(window) { vm.requestNotebookWriteCards(notebookID: "bio") }
        #expect(window.cardWriting?.sourceIDs == [paperID], "the ticked sources the library holds")
        #expect(window.cardWriting?.notebookID == "bio")
        #expect(window.cardWriting?.sourceID == paperID, "the first is the one to write")
        #expect(vm.pendingReviewChatDraft == nil, "no chat drafts them")
        vm.endCardWriting(in: window)
        #expect(window.cardWriting == nil)

        // Practice reads the notebook's cards first: with none it says so and
        // the window stays the notebook's.
        let practice = vm.inWindow(window) { vm.startNotebookPractice(notebookID: "bio") }
        await practice?.value
        #expect(window.memoryCardSession == nil)
        #expect(window.notebook?.notebookID == "bio")
        #expect(vm.toastMessage == "No cards in Bioenergetics to practice yet.")
    }

    // MARK: - The Library's cards

    @Test("The Library's No Cards pill narrows the rows to the sources no card covers, counts them for the tab, and clears with the other filters")
    func noCardsPillNarrowsTheLibrary() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, explainerID) = studio()
        let otherID = vm.articles.first { $0.url == Self.otherURL }!.id
        // The explainer is a source the coverage leaves out (a spoken script),
        // the paper has cards, the other paper none.
        vm.noteSourceCardCoverage(SourceCardCoverage(rows: [
            SourceCardRow(id: paperID, title: "Oxidative phosphorylation", sourceType: .article, dateAdded: Self.now, state: .cards(3)),
            SourceCardRow(id: otherID, title: "Another paper", sourceType: .article, dateAdded: Self.now, state: .none),
        ]))
        #expect(vm.sourceCardCoverage.state(of: paperID) == .cards(3))
        #expect(vm.sourceCardCoverage.statesByID[explainerID] == nil)

        vm.inWindow(window) {
            vm.sidebarTab = .articles
            #expect(vm.sourceCardFilter == .all)
            // The explainer is a notebook output, never a row of the Library's list.
            #expect(Set(vm.filteredActiveItems.map(\.id)) == [paperID, otherID])
            #expect(vm.sourcesWithoutCardsCountInTab == 1, "the pill counts the tab's sources with no card")

            vm.sourceCardFilter = .withoutCards
            #expect(vm.filteredActiveItems.map(\.id) == [otherID], "only the source no card covers; the explainer is not without cards")
            #expect(vm.hasActiveSourceListFilters)
            #expect(!vm.hasChippedSourceListFilters, "the pill shows its own state; no chip")
            #expect(vm.activeSourceListFilterCount == 1)
            #expect(StudioViewModel.sourceCardBatch(vm.filteredActiveItems) == nil, "Make Cards for N needs two or more")

            // Cards made for the last one: the coverage read again empties the list.
            vm.noteSourceCardCoverage(SourceCardCoverage(rows: [
                SourceCardRow(id: paperID, title: "Oxidative phosphorylation", sourceType: .article, dateAdded: Self.now, state: .cards(3)),
                SourceCardRow(id: otherID, title: "Another paper", sourceType: .article, dateAdded: Self.now, state: .toCheck),
            ]))
            #expect(vm.filteredActiveItems.isEmpty)
            #expect(vm.sourcesWithoutCardsCountInTab == 0)

            vm.clearSourceListFilters()
            #expect(vm.sourceCardFilter == .all)
            #expect(vm.filteredActiveItems.count == 2)
        }

        // The batch is the first ten of the list as it stands.
        let many = (0..<12).map { Self.article(url: "https://example.com/\($0)", title: "Source \($0)") }
        #expect(StudioViewModel.sourceCardBatch(many) == many.prefix(10).map(\.id))
        #expect(StudioViewModel.sourceCardBatch(Array(many.prefix(2))) == many.prefix(2).map(\.id))
    }

    @Test("Choose Sources on the corner card opens the Library in its window with the No Cards pill on; Memory has no Sources section")
    func chooseSourcesOpensTheLibraryWithoutCards() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        let other = StudioWindowState()
        other.centerTabGroups = .defaultLayout
        // What `openSourcesWithoutCards` does after answering the card for
        // today (that answer is this Mac's preference, left alone here).
        vm.openLibraryWithoutCards(in: other)
        #expect(other.sidebarStore.sourceCardFilter == .withoutCards)
        #expect(vm.visibleCenterTabs(in: other).contains(.library))
        #expect(window.sidebarStore.sourceCardFilter == .all, "the other windows keep their lists")

        // Opened from a window holding a notebook, the Library is reached the
        // way the rail's row reaches it, with the pill on.
        vm.openLibraryWithoutCards(in: window)
        #expect(window.sidebarStore.sourceCardFilter == .withoutCards)
        #expect(window.notebook == nil || vm.visibleCenterTabs(in: window).contains(.library))
    }

    @Test("The Report tile is offered, and its format opens the report's options in the window it was pressed in, starting no chat")
    func reportTileOpensItsOptions() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        #expect(ReportEntry.isAvailable)
        #expect(NotebookStudioTile.offered.contains(.report))
        #expect(ReportEntry.Format.allCases.map(\.title)
            == ["Briefing", "Study guide", "Questions for a meeting", "Feedback on a document", "Custom…"])

        let (vm, window, _, _) = studio()
        let coordinator = ReportGenerationCoordinator.shared
        defer { coordinator.dismissOptions(in: window.id) }
        vm.inWindow(window) { vm.presentReportOptions(notebookID: "bio", format: .studyGuide) }
        let target = coordinator.optionsTarget(in: window.id)
        #expect(target?.notebookID == "bio")
        #expect(target?.format == .studyGuide)
        #expect(target?.sourceIDs == nil, "the notebook's ticked sources")
        #expect(target?.windowID == window.id)
        // The sheet asks first; nothing else is opened or written.
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(vm.pendingReviewChatDraft == nil)
        #expect(vm.reviewChatResetRequestID == nil)
    }

    @Test("Deep research opens a Deep Research chat in the notebook, waiting for the question or holding Discover's words")
    func deepResearchTileOpensADeepResearchChat() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, _) = studio()
        vm.inWindow(window) { vm.requestNotebookDeepResearch(notebookID: "bio") }
        #expect(vm.pendingReviewChatMode == .deepResearch)
        #expect(vm.pendingReviewChatNotebookID == "bio")
        #expect(vm.pendingReviewChatDraft == nil)
        #expect(vm.contextSourceIds == [paperID])
        #expect(window.notebook?.notebookID == "bio", "a chat of the notebook keeps the window in it")

        vm.inWindow(window) { vm.requestNotebookDeepResearch(notebookID: "bio", question: "  complex I assembly  ") }
        #expect(vm.pendingReviewChatDraft == "complex I assembly")
    }

    @Test("Course opens today's course planning in the notebook, reading its ticked sources")
    func courseTileOpensCoursePlanning() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, _) = studio()
        vm.inWindow(window) { vm.requestNotebookCourse(notebookID: "bio") }
        #expect(vm.pendingCoursePlanningChat)
        #expect(vm.pendingCoursePlanningNotebookID == "bio")
        #expect(vm.contextSourceIds == [paperID])
        #expect(vm.reviewChatTargetWindowID == window.id)
        #expect(CoursePlanningChat.openingDraft(notebookTitle: "Bioenergetics")
            == "I want to make a course from the sources in \u{201C}Bioenergetics\u{201D}")

        // Generate in the Courses tab stays the library's.
        vm.startCoursePlanningChat()
        #expect(vm.pendingCoursePlanningNotebookID == nil)
    }

    @Test("An archived notebook takes nothing its Studio makes, but its cards can still be practised")
    func archivedNotebookTakesNothing() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        window.notebook = NotebookWorkspace(notebookID: "shelved")
        #expect(!vm.notebookTakesMadeThings("shelved"))
        #expect(vm.notebookTakesMadeThings("bio"))

        vm.inWindow(window) {
            vm.requestNotebookDeepResearch(notebookID: "shelved")
            vm.requestNotebookCourse(notebookID: "shelved")
            vm.presentReportOptions(notebookID: "shelved", format: .briefing)
        }
        #expect(vm.pendingReviewChatMode == nil)
        #expect(!vm.pendingCoursePlanningChat)
        #expect(vm.reviewChatResetRequestID == nil)
        #expect(ReportGenerationCoordinator.shared.optionsTarget(in: window.id) == nil, "no report's options open")
        #expect(vm.toastMessage == "A report can\u{2019}t be made in \u{2018}shelved\u{2019}: it is archived.")
        let records = vm.artifacts
        let panes = window.centerTabGroups
        await vm.makeNotebookNote(notebookID: "shelved", in: window)
        #expect(vm.artifacts == records)
        #expect(window.centerTabGroups == panes, "nothing opened")

        #expect(!NotebookStudioTile.cards.makesIntoNotebook)
        vm.inWindow(window) { vm.requestCardReview(scope: .notebook("shelved")) }
        #expect(shows(.memory, in: window))
        #expect(vm.memoryPaneScope(in: window) == .notebook("shelved"), "an archived notebook's cards are still asked")
    }

    @Test("An output's second line leads with its kind, as Gemini writes it")
    func outputSubtitle() {
        #expect(NotebookOutputs.subtitle(kind: "Page", sourceCount: 4) == "Page · 4 sources")
        #expect(NotebookOutputs.subtitle(kind: "Briefing", sourceCount: 1) == "Briefing · 1 source")
        #expect(NotebookOutputs.subtitle(kind: "Course", sourceCount: 0) == "Course")
    }

    @Test("An output is new on this Mac until opened, and nothing made before the dot came reads new")
    func outputUnreadDot() {
        let since = Self.now
        var seen = NotebookOutputSeenState(since: since)
        let older = NotebookOutput(kind: .doc, targetID: "old", title: "Old", sourceIDs: [], date: since.addingTimeInterval(-60))
        let fresh = NotebookOutput(kind: .doc, targetID: "fresh", title: "Fresh", sourceIDs: [], date: since.addingTimeInterval(60))
        var pending = fresh
        pending.isPending = true
        let undated = NotebookOutput(kind: .course, targetID: "course", title: "Course", sourceIDs: [], date: nil)
        #expect(!seen.isNew(older))
        #expect(seen.isNew(fresh))
        #expect(!seen.isNew(pending), "a run still being written has nothing to open")
        #expect(!seen.isNew(undated))
        seen.markSeen(fresh.id)
        #expect(!seen.isNew(fresh))
        seen.markSeen(fresh.id)
        #expect(seen.seenIDs == [fresh.id], "marked once")
        for index in 0..<(NotebookOutputSeenState.limit + 5) { seen.markSeen("doc:\(index)") }
        #expect(seen.seenIDs.count == NotebookOutputSeenState.limit)
        #expect(seen.seenIDs.last == "doc:\(NotebookOutputSeenState.limit + 4)", "the newest kept")
    }

    @Test("The tiles in Gemini Notebook's order, and the Explainer offers ticked papers and articles")
    func tilesAndExplainerCandidates() {
        #expect(NotebookStudioTile.allCases
            == [.audioOverview, .videoOverview, .cards, .report, .deepResearch, .course, .explainer, .canvas, .note])
        #expect(NotebookStudioTile.offered == NotebookStudioTile.allCases, "the Report among them, now its generator is here")
        #expect(NotebookStudioTile.gridTiles == [.audioOverview, .videoOverview, .cards, .report, .deepResearch, .course, .explainer, .canvas],
                "The Studio draws the Canvas tile only where the Canvas shows; Note is the column's floating Add note, not a tile")
        #expect(NotebookStudioTile.allCases.filter(\.isMenu) == [.cards, .report, .explainer, .canvas], "Cards offers Make Cards… and Practice Cards…")

        let (vm, _, paperID, _) = studio()
        #expect(vm.notebookExplainerCandidates("bio").map(\.id) == [paperID])
        #expect(vm.notebookStudioSourceIDs("bio") == [paperID])
    }

    @Test("A notebook of podcast episodes offers them to the Explainer; ForeverLM's own scripts it does not")
    func spokenSourcesAreExplained() {
        let (vm, _, _, _) = studio()
        let episode = Self.article(url: "https://pod.example/ep-4", title: "Ep 4: Bioelectricity", type: .podcast)
        let video = Self.article(url: "https://www.youtube.com/watch?v=abc", title: "Read + Write MRIs", type: .video)
        let book = Self.article(url: "file:///books/bioenergetics.pdf", title: "Bioenergetics, chapter 2", type: .book)
        let script = Self.article(url: GeneratedExplainer.url(explaining: episode.id), title: "Explainer: Ep 4: Bioelectricity")
        vm.articles += [episode, video, book, script]
        vm.learningGoals.append(Self.notebook("pods", sources: [episode.id, video.id, book.id, script.id], teamID: vm.activeTeamID))

        #expect(vm.notebookExplainerCandidates("pods").map(\.id) == [episode.id, video.id])
    }

    @Test("The Studio works from the notebook's own ticked sources: a context notebook reaches nothing until put in, and then its chats alone")
    func studioLeavesContextNotebooksOut() {
        let (vm, _, paperID, _) = studio()
        let lent = Self.article(url: "https://example.com/lent-paper", title: "A context notebook's paper")
        let unticked = Self.article(url: "https://example.com/unticked-paper", title: "An unticked paper")
        vm.articles += [lent, unticked]
        var bio = Self.notebook("bio", sources: [paperID, unticked.id], teamID: vm.activeTeamID)
        bio.relatedNotebookIDs = ["neuro"]
        vm.learningGoals = [bio, Self.notebook("neuro", sources: [lent.id], teamID: vm.activeTeamID)]
        vm.notebookChatExclusions = ["bio": [unticked.id]]
        vm.notebookChatContextNotebooks = [:]

        #expect(vm.notebookChatSourceIDs(bio) == [paperID], "linked alone, the context notebook reaches nothing")
        #expect(vm.notebookStudioSourceIDs("bio") == [paperID])

        vm.notebookChatContextNotebooks = ["bio": ["neuro"]]
        #expect(vm.notebookChatSourceIDs(bio) == [paperID, lent.id], "put in, the chats read it")
        #expect(vm.notebookStudioSourceIDs("bio") == [paperID], "and the Studio still does not")
        #expect(vm.notebookExplainerCandidates("bio").map(\.id) == [paperID])
        #expect(vm.discoverySourceIDs(bio) == [paperID])
    }

    @Test("A course's page opens in the other window by its own destination")
    func courseDestination() {
        #expect(StudioWindowDestination.course("Systems Aging").noun == "course")
        #expect(StudioWindowDestination.course("A") != StudioWindowDestination.courses)
    }
}
