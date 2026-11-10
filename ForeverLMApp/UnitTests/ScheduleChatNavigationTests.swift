// The Schedule chat navigation tests: chat starts, Notebook chat checkboxes and the rail.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

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
        vm.isChatTabActive = true

        await vm.openSourceInReader("new-source")

        #expect(vm.contextSourceIds == ["new-source"])
        #expect(vm.isChatTabActive == true)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.selectedArticleId == "new-source")
    }

    @Test("opening a Schedule source preserves a collapsed Chat panel")
    func openSourceInReaderPreservesHiddenChat() async {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://example.com/new", title: "New", id: "new-source").with(content: "New, already read.")]
        vm.contextSourceIds = ["old-source"]
        vm.isChatTabActive = false

        await vm.openSourceInReader("new-source")

        #expect(vm.contextSourceIds == ["new-source"])
        #expect(vm.isChatTabActive == false)
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
        #expect(vm.isChatTabActive == true)
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
        #expect(vm.isChatTabActive == true)
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

    /// Runs `body` on a notebook state of its own (`NotebookStateStore.override`),
    /// so no test writes the learner's (or a neighbour's) ticks, and hands it
    /// the box to seed and assert on.
    private func withNotebookState(_ body: (NotebookStateStore.Box) throws -> Void) throws {
        let box = NotebookStateStore.Box()
        try NotebookStateStore.$override.withValue(box) { try body(box) }
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
        #expect(NotebookChatContext.linkedPool(own: main.approvedSourceIDs, linked: vm.notebookContextNotebooks(main)) == ["source-a", "source-b", "source-r", "source-s", "source-t"],
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
        try withNotebookState { box in
            let vm = makeViewModel()
            vm.notebookChatExclusions = [:]
            vm.notebookChatContextNotebooks = [:]
            let main = notebook("notebook-1", sourceIDs: ["source-a"], related: ["notebook-2"])
            vm.learningGoals = [main, notebook("notebook-2", sourceIDs: ["source-r", "source-s"])]
            vm.articles = readableArticles(["source-a", "source-r", "source-s", "source-later"])

            vm.setNotebookContextNotebooks(["notebook-2"], inChat: true, notebookID: "notebook-1")
            #expect(box.snapshot.contextNotebooks["notebook-1"] == Set(["notebook-2"]))
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-s"])
            #expect(vm.notebookChatTally(main).total == 3)
            #expect(vm.notebookContextNotebookTally("notebook-2", in: main).map { [$0.inChat, $0.total] } == [2, 2])

            vm.setNotebookSources(["source-s"], inChat: false, through: "notebook-2", notebookID: "notebook-1")
            #expect(box.snapshot.excluded["notebook-1"] == Set(["source-s"]))
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r"])
            #expect(vm.notebookContextNotebookTally("notebook-2", in: main).map { [$0.inChat, $0.total] } == [1, 2], "the group reads mixed")

            // The context notebook gains a source on another device: the
            // group's box governs it, with no tick written.
            vm.learningGoals[1] = notebook("notebook-2", sourceIDs: ["source-r", "source-s", "source-later"])
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-later"])
            #expect(vm.notebookChatTally(main).inChat == 3 && vm.notebookChatTally(main).total == 4)

            // Unticked as a group, it leaves the chats and keeps its boxes.
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: false, notebookID: "notebook-1")
            #expect(box.snapshot.contextNotebooks["notebook-1"] == nil)
            #expect(vm.notebookChatSourceIDs(main) == ["source-a"])
            #expect(box.snapshot.excluded["notebook-1"] == Set(["source-s"]))

            // Its box puts it back as it was left, source-s still unticked and
            // the group mixed; the box again, while it is in, ticks all of it.
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: true, notebookID: "notebook-1")
            #expect(box.snapshot.contextNotebooks["notebook-1"] == Set(["notebook-2"]))
            #expect(box.snapshot.excluded["notebook-1"] == Set(["source-s"]))
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-later"])
            #expect(vm.notebookContextNotebookTally("notebook-2", in: main).map { [$0.inChat, $0.total] } == [2, 3])
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: true, notebookID: "notebook-1")
            #expect(box.snapshot.excluded["notebook-1"] == nil)
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-r", "source-s", "source-later"])

            // A source ticked inside the group while it is out puts the group
            // in with that source alone.
            vm.setNotebookContextNotebooks(["notebook-2"], inChat: false, notebookID: "notebook-1")
            vm.setNotebookSources(["source-later"], inChat: true, through: "notebook-2", notebookID: "notebook-1")
            #expect(box.snapshot.contextNotebooks["notebook-1"] == Set(["notebook-2"]))
            #expect(vm.notebookChatSourceIDs(main) == ["source-a", "source-later"])
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
        try withNotebookState { box in
            let vm = makeViewModel()
            vm.notebookChatExclusions = [:]
            vm.learningGoals = [notebook("notebook-1", sourceIDs: ["source-a", "source-b", "source-c"])]

            vm.setNotebookSources(["source-c", "source-a", "not-in-pool"], inChat: false, notebookID: "notebook-1")
            #expect(box.snapshot.excluded["notebook-1"] == Set(["source-a", "source-c"]))
            #expect(vm.notebookChatExclusions["notebook-1"] == ["source-a", "source-c"])
            #expect(!vm.isNotebookSourceInChat("source-a", notebookID: "notebook-1"))
            #expect(vm.isNotebookSourceInChat("source-b", notebookID: "notebook-1"))

            vm.setNotebookSources(["source-a"], inChat: true, notebookID: "notebook-1")
            #expect(box.snapshot.excluded["notebook-1"] == Set(["source-c"]))

            vm.setAllNotebookSourcesInChat(false, notebookID: "notebook-1")
            #expect(box.snapshot.excluded["notebook-1"] == Set(["source-a", "source-b", "source-c"]))

            vm.setAllNotebookSourcesInChat(true, notebookID: "notebook-1")
            #expect(box.snapshot.excluded["notebook-1"] == nil, "everything ticked is the default and has no row")
            #expect(vm.notebookChatExclusions["notebook-1"] == nil)
        }
    }

    /// `withNotebookState` for an async body.
    private func withNotebookStateAsync(_ body: (NotebookStateStore.Box) async throws -> Void) async throws {
        let box = NotebookStateStore.Box()
        try await NotebookStateStore.$override.withValue(box) { try await body(box) }
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
        vm.isChatTabActive = false
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
        #expect(vm.isChatTabActive == false)
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
        vm.isChatTabActive = false

        vm.requestNewScheduledTaskChat()

        #expect(vm.isChatTabActive == true)
        #expect(vm.reviewChatPanelMode == .chat)
        #expect(vm.reviewChatResetRequestID != nil)
        // Typed but unsent, and unlinked: a task is not owned by whichever
        // Notebook happened to be open when the learner pressed "+".
        let draft = vm.pendingReviewChatDraft ?? ""
        #expect(draft.contains("scheduled task"))
        #expect(vm.pendingReviewChatNotebookID == nil)
    }

    @Test("Open Chat (⇧⌘K) expands and focuses docked Chat")
    func assistantShortcutFocusesDockedChat() {
        let restoreLayout = capturedCenterTabLayout()
        defer { restoreLayout() }
        let vm = makeViewModel()
        vm.centerTabGroups = .defaultLayout
        vm.isChatTabActive = false

        vm.handleAssistantShortcut()
        let firstFocusRequest = vm.reviewChatFocusRequestID

        #expect(vm.isChatTabActive == true)
        #expect(firstFocusRequest != nil)

        vm.handleAssistantShortcut()

        #expect(vm.isChatTabActive == true)
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

}
