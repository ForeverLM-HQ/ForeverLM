import Foundation
import Testing
@testable import ForeverLM

/// The Sources sidebar's notebook marks: the membership index the marks read,
/// the window that works in a notebook, the right-click menu's lead, and the
/// press note that keeps a row's + from opening the row.
@Suite("Sources sidebar notebook marks")
@MainActor
struct NotebookSidebarScopeTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func item(
        _ sourceID: String,
        in goalID: String,
        state: LearningGoalItemReviewState = .approved
    ) -> LearningGoalItem {
        LearningGoalItem(
            id: "item-\(goalID)-\(sourceID)",
            goalID: goalID,
            sourceID: sourceID,
            addedAt: now,
            origin: LearningGoalItemOrigin.seed.rawValue,
            reviewState: state.rawValue
        )
    }

    private static func notebook(
        _ id: String,
        title: String? = nil,
        status: LearningGoalStatus = .active,
        endAt: Date = LearningGoalRecord.openEndedEndAt,
        items: [LearningGoalItem] = [],
        teamID: String? = nil
    ) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: title ?? id,
            startAt: now,
            endAt: endAt,
            createdAt: now,
            updatedAt: now,
            status: status.rawValue,
            items: items,
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    // MARK: - The membership index

    @Test("The index holds each active notebook's approved sources, named as the rows name them")
    func indexListsApprovedMembersByRowID() {
        let goals = [
            Self.notebook("bio", title: "Bioenergetics", items: [
                Self.item("own-a", in: "bio"),
                Self.item("team-copy-b", in: "bio"),
                Self.item("pending-c", in: "bio", state: .pending),
                Self.item("rejected-d", in: "bio", state: .rejected),
            ]),
            Self.notebook("old", status: .archived, items: [Self.item("own-a", in: "old")]),
            // A Goal carries a deadline: it is not a notebook.
            Self.notebook("goal", endAt: Self.now.addingTimeInterval(86_400), items: [Self.item("own-a", in: "goal")]),
        ]
        let aliases = ["team-copy-b": "own-b"]
        let index = StudioViewModel.notebookSidebarIndex(goals: goals) { aliases[$0] ?? $0 }

        #expect(index.members == ["bio": ["own-a", "own-b"]])
        #expect(index.titles == ["bio": "Bioenergetics"])
    }

    @Test("A reload that moves nothing republishes nothing; a new member bumps the revision once")
    func indexRepublishesOnlyOnChange() {
        let vm = makeViewModel()
        vm.learningGoals = [Self.notebook("bio", items: [Self.item("a", in: "bio")])]
        let revision = vm.notebookMembershipRevision
        #expect(vm.notebookMemberSourceIDsByNotebook["bio"] == ["a"])

        vm.learningGoals = [Self.notebook("bio", items: [Self.item("a", in: "bio")])]
        #expect(vm.notebookMembershipRevision == revision)

        // A rename changes the title the sidebar reads, not the members.
        vm.learningGoals = [Self.notebook("bio", title: "Bioenergetics", items: [Self.item("a", in: "bio")])]
        #expect(vm.notebookMembershipRevision == revision)
        #expect(vm.notebookTitlesByNotebook["bio"] == "Bioenergetics")

        vm.learningGoals = [Self.notebook("bio", items: [Self.item("a", in: "bio"), Self.item("b", in: "bio")])]
        #expect(vm.notebookMembershipRevision == revision + 1)
        #expect(vm.notebookMemberSourceIDsByNotebook["bio"] == ["a", "b"])
    }

    @Test("A team notebook's copies mark the learner's own rows once the aliases are known")
    func teamCopiesMarkOwnRows() {
        let vm = makeViewModel()
        vm.learningGoals = [Self.notebook("team-nb", items: [Self.item("copy-1", in: "team-nb")])]
        #expect(vm.notebookMembership(of: ["own-1"], in: "team-nb") == .none)

        vm.articlesStore.teamCopyAliases = ["copy-1": "own-1"]
        vm.refreshNotebookSidebarIndex()
        #expect(vm.notebookMembership(of: ["own-1"], in: "team-nb") == .all)
        #expect(vm.notebookMembership(of: ["copy-1"], in: "team-nb") == .none)
    }

    @Test("Membership is none, some or all of a row's sources")
    func membershipStates() {
        let members: Set<String> = ["ch1", "ch2"]
        #expect(NotebookMembershipState(rowIDs: [], members: members) == .none)
        #expect(NotebookMembershipState(rowIDs: ["x"], members: members) == .none)
        #expect(NotebookMembershipState(rowIDs: ["ch1", "ch3"], members: members) == .some)
        #expect(NotebookMembershipState(rowIDs: ["ch1", "ch2"], members: members) == .all)

        let vm = makeViewModel()
        vm.learningGoals = [Self.notebook("bio", items: [Self.item("ch1", in: "bio")])]
        #expect(vm.notebookMembership(of: ["ch1"], in: "bio") == .all)
        #expect(vm.notebookMembership(of: ["ch1"], in: "unknown") == .none)
    }

    @Test("Removing rows from a team notebook removes the team's copies they stand for")
    func removalMapsRowsToTeamCopies() {
        let aliases = ["copy-1": "own-1", "copy-2": "own-2"]
        let ids = StudioViewModel.notebookMemberIDs(
            standingFor: ["own-2", "own-1", "not-a-member"],
            approved: ["copy-1", "copy-2", "team-only"],
            rowID: { aliases[$0] ?? $0 }
        )
        #expect(ids == ["copy-1", "copy-2"], "pool order, members only")
        #expect(StudioViewModel.notebookMemberIDs(standingFor: ["team-only"], approved: ["team-only"], rowID: { $0 }) == ["team-only"])
    }

    // MARK: - The window that works in a notebook

    @Test("A window works in the notebook it holds, whatever another window holds")
    func windowWorksInItsOwnNotebook() {
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", title: "Bioenergetics"),
            Self.notebook("neuro", title: "Neuroscience"),
            Self.notebook("shelved", status: .archived),
        ]
        let window = StudioWindowState()
        let other = StudioWindowState()
        #expect(vm.sidebarNotebook(in: window) == nil, "a window holding no notebook marks nothing")

        window.NotebookID = "bio"
        #expect(vm.sidebarNotebook(in: window) == SidebarNotebook(notebookID: "bio", title: "Bioenergetics"))
        #expect(vm.sidebarNotebook(in: other) == nil, "a window that never opened it stays out")

        // Another notebook opened in the other window: each marks its own.
        other.NotebookID = "neuro"
        #expect(vm.sidebarNotebook(in: window)?.notebookID == "bio")
        #expect(vm.sidebarNotebook(in: other)?.notebookID == "neuro")

        // The gallery, or a second click on the rail's folder.
        window.NotebookID = nil
        #expect(vm.sidebarNotebook(in: window) == nil)
        #expect(vm.sidebarNotebook(in: other)?.notebookID == "neuro")

        window.NotebookID = "shelved"
        #expect(vm.sidebarNotebook(in: window) == nil, "an archived notebook takes no marks")
    }

    @Test("A notebook marks the Sources list only in its own library")
    func notebookMarksOnlyItsOwnLibrary() {
        let vm = makeViewModel()
        // The test host opens My Library; a team's notebook belongs to the team's.
        let library = vm.activeTeamID
        vm.learningGoals = [
            Self.notebook("own", title: "Own notebook", teamID: library),
            Self.notebook("elsewhere", title: "Another library's notebook", teamID: library == nil ? "team-1" : nil),
        ]
        let window = StudioWindowState()
        window.NotebookID = "own"
        #expect(vm.sidebarNotebook(in: window)?.notebookID == "own")

        // A window naming another library's notebook — for the moment before
        // a library switch closes it — marks nothing in this one's list.
        window.NotebookID = "elsewhere"
        #expect(vm.notebookTitlesByNotebook["elsewhere"] != nil)
        #expect(vm.sidebarNotebook(in: window) == nil)
    }

    private static func team(_ id: String, _ permission: TeamPermission) -> TeamRecord {
        TeamRecord(
            id: id, name: id, role: .member, permission: permission, zoneScope: .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id), zoneOwnerRecordName: "_owner-record",
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        )
    }

    /// The open library is a preference the unit host shares with the app:
    /// a test that opens one puts the old one back.
    private func capturingOpenLibrary() -> () -> Void {
        let saved = UserDefaults.standard.object(forKey: StudioViewModel.activeTeamPreferenceKey)
        return {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioViewModel.activeTeamPreferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StudioViewModel.activeTeamPreferenceKey)
            }
        }
    }

    @Test("A read-only team's notebook, or another library's, takes no sources from the marks or the menu")
    func readOnlyTeamNotebookIsNotImportable() {
        let restoreLibrary = capturingOpenLibrary()
        defer { restoreLibrary() }
        let vm = makeViewModel()
        vm.teams = [Self.team("team-ro", .readOnly), Self.team("team-rw", .readWrite)]
        vm.learningGoals = [
            Self.notebook("theirs", teamID: "team-ro"),
            Self.notebook("ours", teamID: "team-rw"),
            Self.notebook("gone", teamID: "team-not-here"),
            Self.notebook("mine"),
            Self.notebook("shelved", status: .archived),
        ]
        // My Library: its own notebook only.
        vm.activeTeamID = nil
        #expect(vm.importableNotebook("mine")?.id == "mine")
        #expect(vm.importableNotebook("ours") == nil, "a team's notebook takes nothing while My Library is open")
        #expect(vm.importableNotebook("shelved") == nil)

        // The writable team's library: its notebook, and not My Library's.
        vm.activeTeamID = "team-rw"
        #expect(vm.importableNotebook("ours")?.id == "ours")
        #expect(vm.importableNotebook("mine") == nil, "My Library's notebook takes no team rows")

        vm.activeTeamID = "team-ro"
        #expect(vm.importableNotebook("theirs") == nil, "read-only")
        vm.activeTeamID = "team-not-here"
        #expect(vm.importableNotebook("gone") == nil, "a team this Mac does not hold")

        // The notebook's ⋯ reads its own team, whichever library is open.
        let byID = Dictionary(uniqueKeysWithValues: vm.learningGoals.map { ($0.id, $0) })
        #expect(vm.isNotebookReadOnly(byID["theirs"]!))
        #expect(vm.isNotebookReadOnly(byID["gone"]!))
        #expect(!vm.isNotebookReadOnly(byID["ours"]!))
        #expect(!vm.isNotebookReadOnly(byID["mine"]!))
    }

    @Test("Once the library has been read, a notebook it does not hold closes in every window — deleted, or another library's")
    func notebooksMissingFromTheLibraryClose() {
        let restoreLibrary = capturingOpenLibrary()
        defer { restoreLibrary() }
        let vm = makeViewModel()
        vm.teams = [Self.team("team-1", .readWrite)]
        vm.activeTeamID = nil
        vm.learningGoals = [
            Self.notebook("mine"),
            Self.notebook("shelved", status: .archived),
            Self.notebook("theirs", teamID: "team-1"),
        ]
        let windows = (0..<4).map { _ in StudioWindowState() }
        for window in windows { StudioWindowRegistry.shared.register(window) }
        defer { for window in windows { StudioWindowRegistry.shared.unregister(window) } }
        let (mine, shelved, theirs, gone) = (windows[0], windows[1], windows[2], windows[3])
        mine.NotebookID = "mine"
        shelved.NotebookID = "shelved"
        theirs.NotebookID = "theirs"
        gone.NotebookID = "gone"

        // Before the first read, a relaunch's notebooks are on their way.
        vm.hasLoadedLearningGoalsOnce = false
        vm.closeNotebooksMissingFromLibrary()
        #expect(windows.map(\.NotebookID) == ["mine", "shelved", "theirs", "gone"])

        vm.hasLoadedLearningGoalsOnce = true
        vm.closeNotebooksMissingFromLibrary()
        #expect(mine.NotebookID == "mine")
        #expect(shelved.NotebookID == "shelved", "an archived notebook opens to be read")
        #expect(theirs.notebook == nil, "another library's")
        #expect(gone.notebook == nil, "deleted")

        // The team's library opens: My Library's notebooks close, the team's stays.
        theirs.NotebookID = "theirs"
        vm.activeTeamID = "team-1"
        vm.closeNotebooksMissingFromLibrary()
        #expect(mine.notebook == nil)
        #expect(shelved.notebook == nil)
        #expect(theirs.NotebookID == "theirs")
    }

    // MARK: - Adding and removing through the shared paths

    @Test("The + adds quietly with one rebuild of the marks, and the check takes the rows out")
    func quietAddThenRemove() async throws {
        // Adding to a notebook makes it the MCP selection, a shared default.
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let vm = makeViewModel()
        vm.notebookChatExclusions = [:]
        let ids = ["src-1", "src-2", "src-3"]
        for id in ids {
            try await vm.storage.saveSource(
                StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, id: id)
            )
        }
        let notebook = try await vm.storage.createCompanionGoal(
            title: "Bioenergetics",
            topic: "bioenergetics",
            startAt: Self.now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        await vm.loadLearningGoals()
        let revision = vm.notebookMembershipRevision
        vm.toastMessage = nil

        await vm.addSourcesToNotebookContext(ids, notebookID: notebook.id, announce: false)
        #expect(vm.notebookMemberSourceIDsByNotebook[notebook.id] == Set(ids))
        #expect(vm.notebookMembershipRevision == revision + 1, "the optimistic rows land at once and the reload matches them")
        #expect(vm.toastMessage == nil)

        await vm.removeSourcesFromNotebook(["src-1", "src-3"], notebookID: notebook.id, announce: false)
        #expect(vm.notebookMemberSourceIDsByNotebook[notebook.id] == ["src-2"])
        #expect(vm.toastMessage == nil)
        #expect(try await vm.storage.loadLearningGoals().first { $0.id == notebook.id }?.approvedSourceIDs == ["src-2"])
    }

    // MARK: - The right-click menu's lead

    @Test("One source is added or removed; a selection says how many")
    func sourceMenuItems() {
        let members: Set<String> = ["in-1", "in-2"]
        let single = NotebookMembershipMenu.items(for: .sources(["out-1"]), members: members, notebookTitle: "Bio")
        #expect(single.map(\.title) == ["Add to Bio"])
        #expect(single.first?.sourceIDs == ["out-1"])

        let singleIn = NotebookMembershipMenu.items(for: .sources(["in-1"]), members: members, notebookTitle: "Bio")
        #expect(singleIn.map(\.title) == ["Remove from Bio"])
        #expect(singleIn.first?.action == .remove)

        let mixed = NotebookMembershipMenu.items(
            for: .sources(["out-1", "in-1", "out-2", "in-2", "out-3"]),
            members: members,
            notebookTitle: "Bio"
        )
        #expect(mixed.map(\.title) == ["Add 3 to Bio", "Remove 2 from Bio"])
        #expect(mixed.map(\.sourceIDs) == [["out-1", "out-2", "out-3"], ["in-1", "in-2"]])

        #expect(NotebookMembershipMenu.items(for: .sources([]), members: members, notebookTitle: "Bio").isEmpty)
    }

    @Test("A partly added book offers both; several covers are counted as books")
    func bookAndCollectionMenuItems() {
        let members: Set<String> = ["a1", "b1", "b2"]
        let partial = NotebookMembershipMenu.items(for: .books([["a1", "a2"]]), members: members, notebookTitle: "Bio")
        #expect(partial.map(\.title) == ["Add to Bio", "Remove from Bio"])
        #expect(partial.map(\.sourceIDs) == [["a2"], ["a1"]])

        let covers = NotebookMembershipMenu.items(
            for: .books([["a1", "a2"], ["b1", "b2"], ["c1"]]),
            members: members,
            notebookTitle: "Bio"
        )
        // a and c miss chapters; a and b hold some.
        #expect(covers.map(\.title) == ["Add 2 Books to Bio", "Remove 2 Books from Bio"])
        #expect(covers.map(\.sourceIDs) == [["a2", "c1"], ["a1", "b1", "b2"]])

        let series = NotebookMembershipMenu.items(for: .collection(["b1", "x"]), members: members, notebookTitle: "Bio")
        #expect(series.map(\.title) == ["Add All to Bio", "Remove All from Bio"])
        let whole = NotebookMembershipMenu.items(for: .collection(["b1", "b2"]), members: members, notebookTitle: "Bio")
        #expect(whole.map(\.title) == ["Remove All from Bio"])
    }

    @Test("New Notebook is offered for a multi-selection only")
    func newNotebookTitles() {
        #expect(NotebookMembershipMenu.newNotebookTitle(sourceCount: 1) == "Open in New Notebook")
        #expect(NotebookMembershipMenu.newNotebookTitle(sourceCount: 3) == "New Notebook with 3 Sources")
        #expect(NotebookMembershipMenu.newNotebookTitle(bookCount: 1) == nil)
        #expect(NotebookMembershipMenu.newNotebookTitle(bookCount: 2) == "New Notebook with 2 Books")
    }

    // MARK: - A row's control does not open the row

    @Test("A press on a row's control claims that row while held and briefly after")
    func rowControlPressClaims() {
        let pressedAt = Self.now
        var press = SidebarRowControlPress(sourceIDs: ["row"], pressedAt: pressedAt)
        #expect(press.claims("row", at: pressedAt.addingTimeInterval(2)), "a long press is still the control's")
        #expect(!press.claims("other", at: pressedAt))
        #expect(!press.claims("row", at: pressedAt.addingTimeInterval(SidebarRowControlPress.longestPress)),
                "a release that never came stops claiming")

        press.releasedAt = pressedAt.addingTimeInterval(3)
        #expect(press.claims("row", at: pressedAt.addingTimeInterval(3.2)))
        #expect(!press.claims("row", at: pressedAt.addingTimeInterval(3 + SidebarRowControlPress.releaseGrace)))
    }

    @Test("The release closes the press it belongs to")
    func rowControlPressNote() {
        let t = Self.now
        SidebarRowControlPress.note(pressed: true, sourceIDs: ["row"], at: t)
        #expect(SidebarRowControlPress.claims("row", at: t.addingTimeInterval(5)))
        // Another control's release leaves this press held.
        SidebarRowControlPress.note(pressed: false, sourceIDs: ["elsewhere"], at: t.addingTimeInterval(1))
        #expect(SidebarRowControlPress.claims("row", at: t.addingTimeInterval(5)))
        SidebarRowControlPress.note(pressed: false, sourceIDs: ["row"], at: t.addingTimeInterval(6))
        #expect(SidebarRowControlPress.claims("row", at: t.addingTimeInterval(6.1)))
        #expect(!SidebarRowControlPress.claims("row", at: t.addingTimeInterval(7)))
    }
}
