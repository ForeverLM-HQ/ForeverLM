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

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.showSourcesPanel",
        "studio.collapsedPanelIds",
        "studio.navigationRailVisible",
    ]

    /// The unit host's defaults are the real ones: the layout template a pane
    /// change writes, and the active Notebook an open moves. Each test puts
    /// them back.
    private func capturingSharedDefaults() -> () -> Void {
        let template = Self.templateKeys.map { UserDefaults.standard.object(forKey: $0) }
        let activeNotebookID = ActiveNotebookPreference.notebookID
        return {
            for (key, value) in zip(Self.templateKeys, template) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            ActiveNotebookPreference.notebookID = activeNotebookID
        }
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

    @Test("A Doc filed in the notebook opens in its document slot, in the notebook's own Docs")
    func docOpensScopedInTheSlot() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        let panes = window.centerTabGroups

        await vm.openNotebookOutput(output(.doc, "doc-bio"), in: window)
        #expect(window.notebook?.document == .docs)
        #expect(window.artifactCanvasNotebookID == "bio")
        #expect(vm.artifactRevealRequest?.artifactID == "doc-bio")
        #expect(vm.artifactRevealRequest?.section == .docs)
        #expect(vm.artifactRevealRequest?.windowID == window.id, "only this window's canvas answers")
        #expect(window.centerTabGroups == panes, "the panes underneath stay as they were")

        // A doc filed elsewhere — a chat's link — opens in every doc's list,
        // never one that would leave it out.
        vm.revealArtifact("doc-elsewhere", in: window)
        #expect(window.notebook?.document == .docs)
        #expect(window.artifactCanvasNotebookID == nil)
        #expect(vm.docsCanvasScope(for: "doc-bio", in: window) == "bio")
        #expect(vm.docsCanvasScope(for: "doc-elsewhere", in: window) == nil)

        // Outside a notebook a doc never opens scoped.
        let plain = StudioWindowState()
        plain.centerTabGroups = .defaultLayout
        #expect(vm.docsCanvasScope(for: "doc-bio", in: plain) == nil)
    }

    @Test("The notebook's Docs scope goes with the notebook: closed, left or replaced in the window")
    func docsScopeLeavesWithTheNotebook() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        await vm.openNotebookOutput(output(.doc, "doc-bio"), in: window)
        #expect(window.artifactCanvasNotebookID == "bio")
        // Its own arrangement changing keeps it.
        window.notebook?.showsChat = false
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

        // Nor does a surface that leaves the notebook.
        vm.openNotebook("bio", in: window, startsNotebookChat: false)
        await vm.openNotebookOutput(output(.doc, "doc-bio"), in: window)
        vm.revealCenterTab(.goals, beside: .chat, in: window)
        #expect(window.notebook == nil)
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

    @Test("A Site and an animation open in the slot in their own canvases")
    func siteAndAnimationOpenInTheSlot() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        await vm.openNotebookOutput(output(.site, "site-bio"), in: window)
        #expect(window.notebook?.document == .sites)
        #expect(vm.artifactRevealRequest?.section == .sites)

        await vm.openNotebookOutput(output(.animation, "animation-bio"), in: window)
        #expect(window.notebook?.document == .animations)
        #expect(vm.artifactRevealRequest?.section == .animations)
        #expect(window.notebook?.showsChat == true, "the chat stays beside it")
    }

    @Test("A course opens its page in the slot; closing the page empties the slot and keeps the notebook")
    func courseOpensItsPageInTheSlot() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        vm.courseMetadata = ["Systems Aging": CourseMetadata(title: "Systems Aging")]

        await vm.openNotebookOutput(output(.course, "Systems Aging"), in: window)
        #expect(window.coursePageID == "Systems Aging")
        #expect(window.notebook?.document == .coursePage)

        // A lecture takes the slot in the Reader, with the page behind its Back to.
        vm.revealCenterTab(.reader, beside: .courses, in: window)
        #expect(window.notebook?.document == .reader)
        #expect(window.notebook?.returnDocument == .coursePage)
        vm.returnInNotebook(in: window)
        #expect(window.notebook?.document == .coursePage)

        // The page's own way back has no course list to go to in a notebook.
        vm.closeCoursePage(in: window)
        #expect(window.notebook?.notebookID == "bio")
        #expect(window.notebook?.document == nil)
        #expect(window.coursePageID == nil)
    }

    @Test("A walkthrough opens its source in the slot and plays the walk in the chat beside it")
    func walkthroughOpensInTheReader() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, _) = studio()
        window.notebook?.showsChat = false

        await vm.openNotebookOutput(output(.walkthrough, paperID, sources: [paperID]), in: window)
        #expect(window.notebook?.document == .reader)
        #expect(window.readerArticleID == paperID)
        #expect(window.notebook?.showsChat == true, "the walk plays in the notebook's chat")
        #expect(vm.readerWalkthroughPlayRequest?.sourceID == paperID)
    }

    @Test("An explainer opens in the Reader in the slot, with the source it explains selected")
    func explainerOpensInTheReader() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, explainerID) = studio()

        await vm.openNotebookOutput(output(.explainer, explainerID, sources: [paperID]), in: window)
        #expect(window.notebook?.document == .reader)
        #expect(window.readerArticleID == explainerID)
        #expect(window.sidebarSelectedSourceIDs == [paperID])

        // The Explainer tile, for a source that has one, opens it the same way.
        window.notebook?.document = nil
        #expect(await vm.openNotebookExplainer(of: paperID, in: window))
        #expect(window.notebook?.document == .reader)
        #expect(await vm.openNotebookExplainer(of: "no-explainer", in: window) == false)
    }

    @Test("An audio overview's script opens in the slot; one still being written, or not here yet, opens nothing")
    func audioOverviewOpensItsScript() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()

        var pending = output(.audioOverview, "run-1")
        pending.isPending = true
        await vm.openNotebookOutput(pending, in: window)
        #expect(window.notebook?.document == nil)

        await vm.openNotebookOutput(output(.audioOverview, "overview-elsewhere"), in: window)
        #expect(window.notebook?.document == nil, "its script has not reached this Mac")

        let carrier = GeneratedAudioOverview.carrierSource(artifactID: "overview-1", title: "Bioenergetics", script: "A script.")
        vm.articles.append(carrier)
        await vm.openNotebookOutput(output(.audioOverview, "overview-1"), in: window)
        #expect(window.notebook?.document == .reader)
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

    @Test("Cards opens the notebook's Memory pane in its document slot, narrowed to it; nothing takes the window before Start Review")
    func cardsTileOpensTheCardReview() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, _, _) = studio()
        window.memoryPaneSection = .allCards
        vm.inWindow(window) { vm.requestCardReview(scope: .notebook("bio")) }
        #expect(window.notebook?.notebookID == "bio", "the notebook stays as it was")
        #expect(window.notebook?.document == .memory)
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

    @Test("The Cards tile's Make Cards… opens its sheet for the notebook's ticked sources in the window it was pressed in, and Practice starts nothing in a notebook without cards")
    func cardsTileMakesAndPractises() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, window, paperID, _) = studio()
        vm.inWindow(window) { vm.presentNotebookMakeCards(notebookID: "bio") }
        let target = CardDraftingCoordinator.shared.target(in: window.id)
        #expect(target?.notebookID == "bio", "the notebook's decided cards guide the drafting")
        #expect(target?.sourceIDs == [paperID], "the ticked sources the library holds")
        #expect(target?.windowID == window.id)
        CardDraftingCoordinator.shared.dismiss(in: window.id)
        #expect(StudioViewModel.makeCardsSourcesLine(sourceCount: 15, notOpened: 11) == "15 sources · 11 not opened here")
        // The price says what Auto comes to over the sources.
        #expect(MakeCardsSheet.priceLine(cardCount: 24, isFree: false, cost: "$0.04") == "24 cards · $0.04")
        #expect(MakeCardsSheet.priceLine(cardCount: 1, isFree: true, cost: "$0.00") == "1 card · free")

        // Practice reads the notebook's cards first: with none it says so and
        // the window stays the notebook's.
        let practice = vm.inWindow(window) { vm.startNotebookPractice(notebookID: "bio", commitment: .open) }
        await practice?.value
        #expect(window.memoryCardSession == nil)
        #expect(window.notebook?.notebookID == "bio")
        #expect(vm.toastMessage == "No cards in Bioenergetics to practice yet.")
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
        await vm.makeNotebookNote(notebookID: "shelved", in: window)
        #expect(vm.artifacts == records)
        #expect(window.notebook?.document == nil)

        #expect(!NotebookStudioTile.cards.makesIntoNotebook)
        vm.inWindow(window) { vm.requestCardReview(scope: .notebook("shelved")) }
        #expect(window.notebook?.document == .memory)
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
            == [.audioOverview, .videoOverview, .cards, .mnemonicReading, .report, .deepResearch, .course, .explainer, .canvas, .note])
        #expect(NotebookStudioTile.offered == NotebookStudioTile.allCases, "the Report among them, now its generator is here")
        #expect(NotebookStudioTile.gridTiles == [.audioOverview, .videoOverview, .cards, .mnemonicReading, .report, .deepResearch, .course, .explainer, .canvas],
                "The Studio draws the Canvas tile only where the Canvas shows; Note is the column's floating Add note, not a tile")
        #expect(NotebookStudioTile.allCases.filter(\.isMenu) == [.cards, .report, .explainer, .canvas], "Cards offers Make Cards… and Practice Cards…")

        let (vm, _, paperID, _) = studio()
        #expect(vm.notebookExplainerCandidates("bio").map(\.id) == [paperID])
        #expect(vm.notebookStudioSourceIDs("bio") == [paperID])
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
