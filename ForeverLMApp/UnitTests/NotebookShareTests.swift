import Foundation
import Testing
@testable import ForeverLM

/// docs/teams-design.md, decision 22: Share… on a notebook in one step. A
/// notebook in no team gets a team named after it, holding the notebook with
/// every approved source and its file; sharing it again finds that team and
/// makes no other; a team's own notebook is its team's; a team this account
/// only reads cannot be invited to; a notebook two teams hold asks which.
@Suite("Notebook share")
struct NotebookShareTests {

    private func makeStorage() throws -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookShareTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Generation 1's teams: zones of the old container, made locally here. Under generation 2 a
        // team is a space and needs a running sync coordinator (SpaceTestFixture covers those).
        return (StorageService(storeRoot: root, syncGeneration: .one), root)
    }

    private static func readySource(id: String, url: String, title: String, file: URL? = nil) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        let text = "Enough readable text for \(title) to count as a source in the copy."
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        article.localFilePath = file?.path
        return article
    }

    /// A notebook of My Library: two sources in it, the first with its file;
    /// a suggestion still waiting; and a source the learner removed.
    private static func notebook(id: String = "proj-mito", title: String = "🧬 Mitochondria", teamID: String? = nil) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: title,
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: Date(),
            updatedAt: Date(),
            status: "active",
            items: [
                LearningGoalItem(id: "\(id)-1", goalID: id, sourceID: "src-1", addedAt: Date(), sequence: 1),
                LearningGoalItem(id: "\(id)-2", goalID: id, sourceID: "src-2", addedAt: Date(), reviewState: LearningGoalItemReviewState.approved.rawValue, sequence: 2),
                LearningGoalItem(id: "\(id)-3", goalID: id, sourceID: "src-3", addedAt: Date(), origin: LearningGoalItemOrigin.discovered.rawValue, reviewState: LearningGoalItemReviewState.pending.rawValue),
                LearningGoalItem(id: "\(id)-4", goalID: id, sourceID: "src-4", addedAt: Date(), origin: LearningGoalItemOrigin.discovered.rawValue, reviewState: LearningGoalItemReviewState.rejected.rawValue),
            ],
            kind: LearningGoalRecord.companionKind,
            description: "Standing instructions",
            teamID: teamID
        )
    }

    private func seed(_ storage: StorageService, root: URL) async throws -> KnowledgeStore {
        let store = try await storage.notebookFilesKnowledgeStore()
        let pdf = root.appendingPathComponent("one.pdf")
        try Data("%PDF-1.4 notebook share fixture".utf8).write(to: pdf)
        try store.saveSource(Self.readySource(id: "src-1", url: "https://example.com/1", title: "One", file: pdf))
        try store.saveSource(Self.readySource(id: "src-2", url: "https://example.com/2", title: "Two"))
        try store.saveSource(Self.readySource(id: "src-3", url: "https://example.com/3", title: "Three"))
        try store.saveSource(Self.readySource(id: "src-4", url: "https://example.com/4", title: "Four"))
        try store.saveLearningGoalRecord(Self.notebook())
        return store
    }

    private static func readOnlyTeam(_ id: String = "team-ro", name: String = "Theirs") -> TeamRecord {
        let now = Date()
        return TeamRecord(
            id: id, name: name, role: .member, permission: .readOnly, zoneScope: .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id), zoneOwnerRecordName: "_owner-record",
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        )
    }

    /// What ran, in order.
    private actor Events {
        private(set) var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    @Test("Shares of one notebook run one at a time, the second once the first has finished; another notebook's does not wait")
    func oneShareAtATimePerNotebook() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = Events()
        // The first share holds its notebook's lane until the gate opens, as
        // iCloud holds it while it makes the team's zone and share.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await storage.inNotebookShareLane("proj-a") {
                await events.add("a1 started")
                for await _ in gate { break }
                await events.add("a1 finished")
                return 1
            }
        }
        while await events.names.isEmpty { await Task.yield() }
        let second = Task {
            try await storage.inNotebookShareLane("proj-a") {
                await events.add("a2")
                return 2
            }
        }
        let other = try await storage.inNotebookShareLane("proj-b") {
            await events.add("b")
            return 3
        }
        #expect(other == 3)
        // Long enough for the second to have run, had it not waited.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await events.names == ["a1 started", "b"])
        open.yield(())
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(await events.names == ["a1 started", "b", "a1 finished", "a2"])
    }

    @Test("Two shares at once of a notebook in no team make one team: the second finds the team the first made")
    func concurrentSharesMakeOneTeam() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed(storage, root: root)
        async let first = storage.shareNotebook("proj-mito")
        async let second = storage.shareNotebook("proj-mito")
        let shares = try await [first, second]
        #expect(Set(shares.map(\.team.id)).count == 1)
        #expect(shares.filter(\.createdTeam).count == 1)
        #expect(try store.loadTeams().count == 1)
    }

    @Test("A notebook in no team gets a team named after it, holding the notebook with every approved source and its file")
    func firstShareMakesTheTeam() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed(storage, root: root)
        #expect(try await storage.teamsHoldingNotebook("proj-mito").isEmpty, "a notebook in no team: the popover offers to share it")

        let share = try await storage.shareNotebook("proj-mito")
        #expect(share.createdTeam)
        #expect(share.team.name == "🧬 Mitochondria", "the team takes the notebook's title, emoji included")
        #expect(share.team.role == .owner)
        #expect(share.team.canEdit)
        #expect(share.teamNotebookID == TeamContentIdentity.notebookID(teamID: share.team.id, originalNotebookID: "proj-mito"))
        #expect(share.sharedSourceCount == 2)
        #expect(try store.loadTeams().map(\.id) == [share.team.id])

        // The notebook is in the team with its approved sources; the
        // suggestion and the source the learner removed stay behind.
        let copy = try #require(try store.loadLearningGoal(share.teamNotebookID))
        #expect(copy.teamID == share.team.id)
        #expect(copy.title == "🧬 Mitochondria")
        #expect(copy.description == "Standing instructions")
        #expect(Set(copy.approvedSourceIDs) == [
            TeamContentIdentity.sourceID(teamID: share.team.id, url: "https://example.com/1"),
            TeamContentIdentity.sourceID(teamID: share.team.id, url: "https://example.com/2"),
        ])
        let teamSources = try store.loadActiveSources(teamID: share.team.id)
        #expect(Set(teamSources.map(\.url)) == ["https://example.com/1", "https://example.com/2"])

        // The file travels: the team's copy has its own file in the team's folder.
        let withFile = try #require(teamSources.first { $0.url == "https://example.com/1" })
        let path = try #require(withFile.localFilePath)
        #expect(path.contains("Teams/\(share.team.id)/"))
        #expect(FileManager.default.fileExists(atPath: StorageService.absoluteSourcePath(path)))

        // The original stays in My Library as it was, and what is filed
        // under it from now on reaches the team (decision 10).
        let original = try #require(try store.loadLearningGoal("proj-mito"))
        #expect(original.teamID == nil)
        #expect(original.items.count == 4)
        #expect(try store.teamsHoldingNotebook("proj-mito").map(\.id) == [share.team.id])

        // Who has it, as the Share popover reads it: the team, from the
        // original and from the team's own copy alike.
        #expect(try await storage.teamsHoldingNotebook("proj-mito").map(\.id) == [share.team.id])
        #expect(try await storage.teamsHoldingNotebook(share.teamNotebookID).map(\.id) == [share.team.id])
    }

    @Test("Sharing the notebook again finds the team that holds it and makes no second one; a team's own notebook is its team's")
    func secondShareUsesTheSameTeam() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed(storage, root: root)

        let first = try await storage.shareNotebook("proj-mito")
        let second = try await storage.shareNotebook("proj-mito")
        #expect(!second.createdTeam)
        #expect(second.team.id == first.team.id)
        #expect(second.teamNotebookID == first.teamNotebookID)
        #expect(second.sharedSourceCount == 2)
        #expect(try store.loadTeams().count == 1)

        let fromTheTeam = try await storage.shareNotebook(first.teamNotebookID)
        #expect(!fromTheTeam.createdTeam)
        #expect(fromTheTeam.team.id == first.team.id)
        #expect(fromTheTeam.teamNotebookID == first.teamNotebookID)
        #expect(try store.loadTeams().count == 1)

        // A teammate took a source out of the team's notebook. Sharing again,
        // the team named, copies nothing and puts nothing back.
        let removed = TeamContentIdentity.sourceID(teamID: first.team.id, url: "https://example.com/2")
        var teamCopy = try #require(try store.loadLearningGoal(first.teamNotebookID))
        teamCopy.items = teamCopy.items.map { item in
            guard item.sourceID == removed else { return item }
            var taken = item
            taken.reviewState = LearningGoalItemReviewState.rejected.rawValue
            return taken
        }
        try store.saveLearningGoalRecord(teamCopy)
        let named = try await storage.shareNotebook("proj-mito", intoTeam: first.team.id)
        #expect(!named.createdTeam)
        #expect(named.teamNotebookID == first.teamNotebookID)
        #expect(named.sharedSourceCount == 1)
        let kept = try #require(try store.loadLearningGoal(first.teamNotebookID))
        #expect(kept.items.first { $0.sourceID == removed }?.reviewState == LearningGoalItemReviewState.rejected.rawValue)
    }

    @Test("A team this account only reads is refused, whether the notebook is the team's or a copy the team holds")
    func readOnlyMemberIsRefused() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed(storage, root: root)
        let theirs = Self.readOnlyTeam()
        try store.saveTeam(theirs, publish: false)
        try store.withoutSyncTracking {
            try store.saveLearningGoalRecord(Self.notebook(id: "proj-theirs", title: "Their notebook", teamID: theirs.id))
            // A copy of the learner's notebook that the team holds, from
            // before the owner made this member read-only.
            try store.saveLearningGoalRecord(Self.notebook(
                id: TeamContentIdentity.notebookID(teamID: theirs.id, originalNotebookID: "proj-mito"),
                teamID: theirs.id
            ))
        }

        for notebookID in ["proj-theirs", "proj-mito"] {
            do {
                _ = try await storage.shareNotebook(notebookID)
                Issue.record("\(notebookID) was shared from a read-only team")
            } catch let NotebookShareError.readOnly(team) {
                #expect(team.id == theirs.id)
            }
        }
        #expect(try store.loadTeams().map(\.id) == [theirs.id], "no team was made")
    }

    @Test("A notebook two teams hold asks which, naming both and making none; naming one shares into it")
    func severalTeamsAskWhich() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed(storage, root: root)
        let nexus = try await storage.createTeam(name: "Nexus")
        let oxphos = try await storage.createTeam(name: "Bench Lab")
        try await storage.shareNotebook("proj-mito", withTeam: nexus.id)
        try await storage.shareNotebook("proj-mito", withTeam: oxphos.id)

        do {
            _ = try await storage.shareNotebook("proj-mito")
            Issue.record("a notebook in two teams was shared without asking which")
        } catch let NotebookShareError.inSeveralTeams(title, teams) {
            #expect(title == "🧬 Mitochondria")
            #expect(Set(teams.map(\.name)) == ["Nexus", "Bench Lab"])
        }
        #expect(try store.loadTeams().count == 2)

        let named = try await storage.shareNotebook("proj-mito", intoTeam: oxphos.id)
        #expect(!named.createdTeam)
        #expect(named.team.id == oxphos.id)
        #expect(named.teamNotebookID == TeamContentIdentity.notebookID(teamID: oxphos.id, originalNotebookID: "proj-mito"))
    }

    @Test("A Goal is not a notebook to share, and an unknown id is refused")
    func onlyNotebooksShare() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await seed(storage, root: root)
        let goal = try await storage.createCompanionGoal(
            title: "Finish the review", topic: "review", startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: []
        )
        for id in [goal.id, "no-such-notebook"] {
            await #expect(throws: NotebookShareError.notANotebook(id)) {
                _ = try await storage.shareNotebook(id)
            }
        }
    }

    @Test("The popover's one step: a notebook in no team gets its team, said in a toast; the next Share finds that team and makes none; a team this Mac does not have is refused")
    @MainActor
    func teamForSharingNotebook() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seed(storage, root: root)
        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)

        let team = try #require(await vm.teamForSharingNotebook("proj-mito", inTeam: nil))
        #expect(team.name == "🧬 Mitochondria")
        #expect(team.role == .owner)
        #expect(vm.team(id: team.id) != nil, "the window's teams have it, for Apple's sheet and the link")
        let made = try #require(vm.toastMessage)
        #expect(made.hasPrefix("Made a team for "))
        #expect(made.hasSuffix(" with its 2 sources"))

        vm.dismissToast()
        let again = try #require(await vm.teamForSharingNotebook("proj-mito", inTeam: nil))
        #expect(again.id == team.id)
        #expect(vm.toastMessage == nil, "nothing was made, so nothing is said")
        #expect(try store.loadTeams().map(\.id) == [team.id])

        // A team named: that team, as it stands, or a refusal when it is gone.
        #expect(await vm.teamForSharingNotebook("proj-mito", inTeam: team.id)?.id == team.id)
        #expect(await vm.teamForSharingNotebook("proj-mito", inTeam: "no-such-team") == nil)
        #expect(vm.toastMessage == "That team is no longer on this Mac")
        #expect(try store.loadTeams().count == 1)
    }

    @Test("The popover says in one line what a share gives, and is titled after the notebook, as the iPhone and the web say it")
    func sharesLine() {
        #expect(NotebookShareLine.text(sourceCount: 0) == "Shares the notebook")
        #expect(NotebookShareLine.text(sourceCount: 1) == "Shares the notebook and its source")
        #expect(NotebookShareLine.text(sourceCount: 43) == "Shares the notebook and its 43 sources")
        #expect(NotebookShareLine.text(sourceCount: 1_200) == "Shares the notebook and its \(1_200.formatted()) sources")
        #expect(NotebookShareLine.title(notebookTitle: "🧬 Mitochondria") == "Share 🧬 Mitochondria")
        #expect(NotebookShareLine.title(notebookTitle: " ") == "Share Notebook")
    }

    @Test("The invitation link: none until iCloud has shared the team, and a member's is the link as it stands")
    func invitationLink() async throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await seed(storage, root: root)
        let share = try await storage.shareNotebook("proj-mito")
        #expect(share.team.shareURL == nil)
        await #expect(throws: TeamError.self) {
            _ = try await storage.invitationLink(for: share.team)
        }
        var member = share.team
        member.role = .member
        member.shareURL = "https://www.icloud.com/share/0abcdefghijklmnopqrstuvwx"
        #expect(try await storage.invitationLink(for: member).absoluteString == "https://www.icloud.com/share/0abcdefghijklmnopqrstuvwx")
    }
}
