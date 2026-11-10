import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The MCP surface for Teams: an assistant can list and create teams, copy
/// library items into one, and run a Notebook's task board, with every write
/// going through the same storage layer the app uses. A read-only team refuses
/// every write with an explanation, and Notebook payloads say which library a
/// Notebook is in.
@Suite("MCP Teams tools")
struct MCPTeamsToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_teams_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        // Generation 1's teams (zones of the old container); under generation 2 a team is a space
        // that needs a running sync coordinator, which SpaceTestFixture's suites cover.
        let store = MCPDataStore(dbPath: dbPath)
        // The real schema, exactly as production creates it.
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func readySource(id: String, url: String, title: String) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        let text = "Enough readable text for \(title) to count as a source in the copy."
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        article.readAt = Date(timeIntervalSinceReferenceDate: 1_000)
        return article
    }

    private func makeNotebook(_ store: MCPDataStore, title: String, sourceIDs: [String]) throws -> LearningGoalRecord {
        try store.knowledgeStore().createCompanionGoal(
            title: title,
            description: "Standing instructions",
            topic: title,
            startAt: Calendar.current.startOfDay(for: Date()),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: sourceIDs
        )
    }

    private func createTeam(_ store: MCPDataStore, name: String) async throws -> String {
        let created = try parseJSON(try await store.createTeam(name: name))
        let team = try #require(created["team"] as? [String: Any])
        return try #require(team["id"] as? String)
    }

    private func saveReadOnlyTeam(_ store: MCPDataStore, id: String, name: String) throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: id,
            name: name,
            role: .member,
            permission: .readOnly,
            zoneScope: .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: "_owner-record",
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        )
        try store.knowledgeStore().saveTeam(team)
        return team
    }

    @Test("The registry advertises every team and task tool with the schema the gateway documents")
    func registryAdvertisesTeamTools() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for name in ["list_teams", "create_team", "share_with_team", "share_notebook", "list_notebook_tasks",
                     "create_notebook_task", "update_notebook_task", "delete_notebook_task"] {
            let tool = try #require(byName[name], "\(name) is not registered")
            #expect(!tool.description.isEmpty)
            #expect(tool.inputSchema["type"] as? String == "object")
        }
        let share = try #require(byName["share_with_team"])
        #expect(share.inputSchema["required"] as? [String] == ["team_id", "kind", "ids"])
        let shareProperties = share.inputSchema["properties"] as? [String: Any]
        let kind = shareProperties?["kind"] as? [String: Any]
        #expect(kind?["enum"] as? [String] == MCPDataStore.TeamShareKind.allCases.map(\.rawValue))
        for flag in ["include_sources", "include_docs", "include_chats", "rights_affirmed_by_learner"] {
            #expect((shareProperties?[flag] as? [String: Any])?["type"] as? String == "boolean", "\(flag) is not offered")
        }
        // docs/teams-design.md, decision 22: one call for a notebook, and the
        // question an assistant must ask is in both descriptions.
        let notebook = try #require(byName["share_notebook"])
        #expect(notebook.inputSchema["required"] as? [String] == ["notebook_id"])
        let notebookProperties = notebook.inputSchema["properties"] as? [String: Any]
        #expect((notebookProperties?["rights_affirmed_by_learner"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((notebookProperties?["team_id"] as? [String: Any])?["type"] as? String == "string")
        for tool in [share, notebook] {
            #expect(tool.description.contains(SharingRightsAffirmation.assistantQuestion), "\(tool.name) does not give the question to ask")
        }
        let create = try #require(byName["create_notebook_task"])
        #expect(create.inputSchema["required"] as? [String] == ["notebook_id", "title"])
        let status = (create.inputSchema["properties"] as? [String: Any])?["status"] as? [String: Any]
        #expect(status?["enum"] as? [String] == NotebookTaskStatus.allCases.map(\.rawValue))
    }

    // MARK: - Share… on a notebook (docs/teams-design.md, decision 22)

    /// The test's own defaults for the learner's rights row, so nothing here
    /// reaches the row the learner's devices read.
    private func withOwnRightsRow<R>(_ body: (UserDefaults) async throws -> R) async throws -> R {
        let suite = "MCPTeamsToolsTests.rights.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return try await SharingRightsRow.$overrideDefaults.withValue(SharingRightsRow.DefaultsOverride(defaults: defaults)) {
            try await body(defaults)
        }
    }

    @Test("share_notebook refuses a read-only member, naming the owner, before it asks anything; an unknown notebook is not found")
    func shareNotebookRefusesReadOnly() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let team = try saveReadOnlyTeam(store, id: "team-ro", name: "Theirs")
        try knowledge.replaceTeamMembers(teamID: team.id, members: [
            TeamMemberRecord(
                userRecordName: "_ada", teamID: team.id, displayName: "Ada Lovelace", email: "ada@example.com",
                role: .owner, permission: .readWrite, acceptanceStatus: "accepted",
                isCurrentUser: false, updatedAt: Date()
            ),
        ])
        try knowledge.saveLearningGoalRecord(LearningGoalRecord(
            id: "proj-theirs", title: "Their notebook", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: Date(), updatedAt: Date(), status: "active", items: [],
            kind: LearningGoalRecord.companionKind, teamID: team.id
        ))
        let own = try makeNotebook(store, title: "Mine", sourceIDs: [])
        let registry = MCPToolRegistry(store: store)

        try await withOwnRightsRow { defaults in
            for arguments: [String: Any] in [
                ["notebook_id": "proj-theirs"],
                ["notebook_id": own.id, "team_id": team.id, "rights_affirmed_by_learner": true],
            ] {
                let outcome = await registry.callToolDetailed(name: "share_notebook", arguments: arguments)
                #expect(outcome.isError)
                #expect(outcome.text.contains("read-only"))
                #expect(outcome.text.contains("Theirs"))
                #expect(outcome.text.contains("Ada Lovelace"))
                #expect(!outcome.text.contains(SharingRightsAffirmation.assistantQuestion))
            }
            let missing = await registry.callToolDetailed(name: "share_notebook", arguments: ["notebook_id": "no-such-notebook", "rights_affirmed_by_learner": true])
            #expect(missing.isError)
            #expect(missing.text.contains("list_notebooks"))
            #expect(defaults.object(forKey: SharingRightsAffirmation.preferenceKey) == nil, "a refused share records no answer")
            let teams = try knowledge.loadTeams().map(\.id)
            #expect(teams == [team.id], "no team was made")
        }
    }

    @Test("A read-only team refuses share_with_team and every task write, with an explanation")
    func readOnlyTeamRefusesWrites() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-1", url: "https://example.com/one", title: "One"))
        let team = try saveReadOnlyTeam(store, id: "team-ro", name: "Theirs")

        let registry = MCPToolRegistry(store: store)
        let outcome = await registry.callToolDetailed(
            name: "share_with_team",
            arguments: ["team_id": team.id, "kind": "source", "ids": ["src-1"]]
        )
        #expect(outcome.isError)
        #expect(outcome.text.contains("read-only"))
        #expect(outcome.text.contains("Theirs"))
        #expect(try knowledge.loadActiveSources(teamID: team.id).isEmpty)
        #expect(try knowledge.loadActiveSources().map(\.id) == ["src-1"])

        // A team Notebook that arrived from the owner cannot take a task from a
        // read-only member either.
        try knowledge.saveLearningGoalRecord(LearningGoalRecord(
            id: "proj-team", title: "Theirs", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: Date(), updatedAt: Date(), status: "active", items: [],
            kind: LearningGoalRecord.companionKind, teamID: team.id
        ))
        let taskOutcome = await registry.callToolDetailed(
            name: "create_notebook_task",
            arguments: ["notebook_id": "proj-team", "title": "Nope"]
        )
        #expect(taskOutcome.isError)
        #expect(taskOutcome.text.contains("read-only"))
        #expect(try knowledge.loadNotebookTasks(notebookID: "proj-team").isEmpty)

        // The team still lists, honestly marked.
        let listed = try parseJSON(try await store.listTeams())
        let teams = try #require(listed["teams"] as? [[String: Any]])
        #expect(teams.first?["permission"] as? String == "readOnly")
        #expect(teams.first?["can_edit"] as? Bool == false)
        #expect(teams.first?["role"] as? String == "member")
    }

    /// Share a Notebook through the tool and return the team copy's id.
    private func notebookFileStorageShare(_ store: MCPDataStore, notebookID: String, teamID: String) async throws -> String {
        let shared = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "notebook", ids: [notebookID], includeSources: true, includeDocs: false
        ))
        let copies = try #require(shared["copies"] as? [[String: Any]])
        return try #require(copies.first?["team_copy_id"] as? String)
    }
}

#endif
