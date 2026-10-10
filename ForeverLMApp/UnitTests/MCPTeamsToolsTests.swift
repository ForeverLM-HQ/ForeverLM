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
        let store = MCPDataStore(dbPath: dbPath, syncGeneration: .one)
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

    @Test("list_teams is empty until create_team makes a team this account owns")
    func listAndCreateTeams() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let empty = try parseJSON(try await store.listTeams())
        #expect(empty["count"] as? Int == 0)
        #expect((empty["teams"] as? [[String: Any]])?.isEmpty == true)
        #expect((empty["guidance"] as? String)?.contains("create_team") == true)

        await #expect(throws: MCPError.self) {
            _ = try await store.createTeam(name: "   ")
        }

        let created = try parseJSON(try await store.createTeam(name: "  Nexus  "))
        let team = try #require(created["team"] as? [String: Any])
        let teamID = try #require(team["id"] as? String)
        #expect(team["name"] as? String == "Nexus")
        #expect(team["role"] as? String == "owner")
        #expect(team["permission"] as? String == "readWrite")
        #expect(team["can_edit"] as? Bool == true)
        #expect(team["member_count"] as? Int == 0)
        // No iCloud under test, so no invitation link yet; the key is absent
        // rather than a made-up value.
        #expect(team["share_url"] == nil)
        #expect((created["message"] as? String)?.contains("Nexus") == true)

        // The team is a real row the storage layer sees, not just a payload.
        let stored = try #require(try store.knowledgeStore().loadTeam(teamID))
        #expect(stored.name == "Nexus")
        #expect(stored.role == .owner)
        #expect(stored.zoneName == "Team-\(teamID)")

        // The roster travels with the team, and marks this account.
        try store.knowledgeStore().replaceTeamMembers(teamID: teamID, members: [
            TeamMemberRecord(
                userRecordName: "_me", teamID: teamID, displayName: "Robin", email: nil,
                role: .owner, permission: .readWrite, acceptanceStatus: "accepted",
                isCurrentUser: true, updatedAt: Date()
            ),
            TeamMemberRecord(
                userRecordName: "_ada", teamID: teamID, displayName: "Ada", email: "ada@example.com",
                role: .member, permission: .readWrite, acceptanceStatus: "accepted",
                isCurrentUser: false, updatedAt: Date()
            ),
        ])
        let listed = try parseJSON(try await store.listTeams())
        #expect(listed["count"] as? Int == 1)
        let teams = try #require(listed["teams"] as? [[String: Any]])
        let first = try #require(teams.first)
        #expect(first["id"] as? String == teamID)
        #expect(first["member_count"] as? Int == 2)
        let members = try #require(first["members"] as? [[String: Any]])
        let me = try #require(members.first { $0["user_record_name"] as? String == "_me" })
        #expect(me["is_current_user"] as? Bool == true)
        #expect(me["display_name"] as? String == "Robin")
        let ada = try #require(members.first { $0["user_record_name"] as? String == "_ada" })
        #expect(ada["is_current_user"] as? Bool == false)
        #expect(ada["email"] as? String == "ada@example.com")
        #expect(ada["permission"] as? String == "readWrite")
    }

    @Test("share_with_team copies sources and a Notebook into the team and leaves the originals alone")
    func shareSourcesAndNotebook() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-1", url: "https://example.com/one", title: "One"))
        try knowledge.saveSource(readySource(id: "src-2", url: "https://example.com/two", title: "Two"))
        let notebook = try makeNotebook(store, title: "Mitochondria", sourceIDs: ["src-1", "src-2"])
        let teamID = try await createTeam(store, name: "Nexus")

        // Sources.
        let shared = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "source", ids: ["src-1"], includeSources: nil, includeDocs: nil
        ))
        #expect(shared["team_id"] as? String == teamID)
        #expect(shared["team_name"] as? String == "Nexus")
        #expect(shared["kind"] as? String == "source")
        #expect(shared["count"] as? Int == 1)
        let copies = try #require(shared["copies"] as? [[String: Any]])
        let sourceCopyID = try #require(copies.first?["team_copy_id"] as? String)
        #expect(copies.first?["original_id"] as? String == "src-1")
        #expect(sourceCopyID == TeamContentIdentity.sourceID(teamID: teamID, url: "https://example.com/one"))
        #expect((shared["message"] as? String)?.contains("originals stay") == true)

        let own = try knowledge.loadActiveSources()
        #expect(own.map(\.id).sorted() == ["src-1", "src-2"])
        #expect(own.allSatisfy { $0.teamID == nil })
        let teamSources = try knowledge.loadActiveSources(teamID: teamID)
        #expect(teamSources.map(\.id) == [sourceCopyID])
        #expect(teamSources.first?.teamID == teamID)
        #expect(teamSources.first?.title == "One")

        // Sharing again is an update, not a second copy.
        let again = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "source", ids: ["src-1"], includeSources: nil, includeDocs: nil
        ))
        #expect((again["copies"] as? [[String: Any]])?.first?["team_copy_id"] as? String == sourceCopyID)
        #expect(try knowledge.loadActiveSources(teamID: teamID).count == 1)

        // A Notebook, with its sources.
        let sharedNotebook = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "notebook", ids: [notebook.id], includeSources: true, includeDocs: false
        ))
        let notebookCopies = try #require(sharedNotebook["copies"] as? [[String: Any]])
        let notebookCopyID = try #require(notebookCopies.first?["team_copy_id"] as? String)
        #expect(notebookCopyID == TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: notebook.id))
        let copy = try #require(try knowledge.loadLearningGoal(notebookCopyID))
        #expect(copy.teamID == teamID)
        #expect(copy.title == "Mitochondria")
        #expect(copy.description == "Standing instructions")
        #expect(Set(copy.items.map(\.sourceID)) == Set([
            sourceCopyID,
            TeamContentIdentity.sourceID(teamID: teamID, url: "https://example.com/two"),
        ]))
        let original = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(original.teamID == nil)
        #expect(Set(original.items.map(\.sourceID)) == ["src-1", "src-2"])
        #expect(try knowledge.loadActiveSources(teamID: teamID).count == 2)

        // list_notebooks and get_notebook say which library each Notebook is in.
        let listed = try parseJSON(try await MCPToolRegistry(store: store)
            .callToolDetailed(name: "list_notebooks", arguments: [:]).text)
        let goals = try #require(listed["goals"] as? [[String: Any]])
        let ownRow = try #require(goals.first { $0["id"] as? String == notebook.id })
        #expect(ownRow["team_id"] is NSNull)
        #expect(ownRow["team_name"] == nil)
        let teamRow = try #require(goals.first { $0["id"] as? String == notebookCopyID })
        #expect(teamRow["team_id"] as? String == teamID)
        #expect(teamRow["team_name"] as? String == "Nexus")
        let detail = try parseJSON(try store.getNotebookDetail(notebookID: notebookCopyID))
        #expect(detail["team_id"] as? String == teamID)
        #expect(detail["team_name"] as? String == "Nexus")

        // Unknown ids are errors before anything is copied.
        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(
                teamID: teamID, kind: "source", ids: ["src-2", "src-missing"], includeSources: nil, includeDocs: nil
            )
        }
        #expect(try knowledge.loadActiveSources(teamID: teamID).count == 2)
        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(
                teamID: teamID, kind: "folder", ids: ["src-2"], includeSources: nil, includeDocs: nil
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(
                teamID: "no-such-team", kind: "source", ids: ["src-2"], includeSources: nil, includeDocs: nil
            )
        }
    }

    /// docs/teams-design.md, decision 21: a course shares whole, its sources
    /// with it, and list_courses / get_course say which copy is the team's.
    @Test("share_with_team kind course copies the course and the sources on its path into the team")
    func shareCourse() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-video", url: "https://www.youtube.com/watch?v=abc123", title: "Lecture 1"))
        try knowledge.saveCourseGroup(name: "course-own", metadata: CourseMetadata(title: "Bioelectricity"))
        try knowledge.saveCourseOutline(
            courseName: "course-own",
            lectures: [CourseSession(id: "lec-1", courseName: "course-own", number: 1, title: "Voltage")],
            items: [CourseLectureItem(id: "item-1", lectureId: "lec-1", sourceId: "src-video", role: .video)]
        )
        let teamID = try await createTeam(store, name: "Nexus")

        let shared = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "course", ids: ["course-own"], includeSources: nil, includeDocs: nil
        ))
        #expect(shared["kind"] as? String == "course")
        let copies = try #require(shared["copies"] as? [[String: Any]])
        let courseCopyID = try #require(copies.first?["team_copy_id"] as? String)
        #expect(courseCopyID == TeamContentIdentity.courseID(teamID: teamID, originalCourseID: "course-own"))
        let travelled = try #require(shared["course_sources_shared"] as? [[String: Any]])
        let teamVideo = TeamContentIdentity.sourceID(teamID: teamID, url: "https://www.youtube.com/watch?v=abc123")
        #expect(travelled.map { $0["team_copy_id"] as? String } == [teamVideo])
        #expect((shared["message"] as? String)?.contains("own progress") == true)

        #expect(try knowledge.courseTeamID(courseCopyID) == teamID)
        #expect(try knowledge.loadActiveSources(teamID: teamID).map(\.id) == [teamVideo])
        #expect(try knowledge.courseTeamID("course-own") == nil)

        // Both listings say which course is the team's.
        let listed = try store.listCourses()
        #expect(listed.contains("id: \(courseCopyID)"))
        #expect(listed.contains("team_id: \(teamID)"))
        #expect(try store.getCourse(courseIdentifier: courseCopyID).contains("team_id: \(teamID)"))
        #expect(!(try store.getCourse(courseIdentifier: "course-own").contains("team_id:")))

        // An unknown course is an error before anything is copied.
        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(
                teamID: teamID, kind: "course", ids: ["no-such-course"], includeSources: nil, includeDocs: nil
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(
                teamID: teamID, kind: "course", ids: ["course-own"], includeSources: true, includeDocs: nil
            )
        }
    }

    @Test("Tasks round-trip through create, list, update and delete on a team Notebook")
    func notebookTaskRoundTrip() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-1", url: "https://example.com/one", title: "One"))
        let notebook = try makeNotebook(store, title: "Calcium", sourceIDs: ["src-1"])
        let teamID = try await createTeam(store, name: "Nexus")
        try knowledge.replaceTeamMembers(teamID: teamID, members: [
            TeamMemberRecord(
                userRecordName: "_me", teamID: teamID, displayName: "Robin", email: nil,
                role: .owner, permission: .readWrite, acceptanceStatus: "accepted",
                isCurrentUser: true, updatedAt: Date()
            ),
            TeamMemberRecord(
                userRecordName: "_ada", teamID: teamID, displayName: "Ada", email: nil,
                role: .member, permission: .readWrite, acceptanceStatus: "accepted",
                isCurrentUser: false, updatedAt: Date()
            ),
        ])
        let teamNotebookID = try await notebookFileStorageShare(store, notebookID: notebook.id, teamID: teamID)
        let teamSourceID = TeamContentIdentity.sourceID(teamID: teamID, url: "https://example.com/one")

        // Empty board, with the roster beside it.
        let emptyBoard = try parseJSON(try await store.listNotebookTasks(notebookID: teamNotebookID, status: nil, assignee: nil))
        #expect(emptyBoard["count"] as? Int == 0)
        let boardTeam = try #require(emptyBoard["team"] as? [String: Any])
        #expect(boardTeam["id"] as? String == teamID)
        #expect((boardTeam["members"] as? [[String: Any]])?.count == 2)

        // Create.
        let created = try parseJSON(try await store.createNotebookTask(
            notebookID: teamNotebookID,
            title: "Read the influx paper",
            notes: "Figure 3 first",
            status: nil,
            assigneeRecordName: "me",
            dueDate: "2026-09-30",
            sourceID: teamSourceID,
            docID: nil
        ))
        let task = try #require(created["task"] as? [String: Any])
        let taskID = try #require(task["id"] as? String)
        #expect(task["notebook_id"] as? String == teamNotebookID)
        #expect(task["team_id"] as? String == teamID)
        #expect(task["title"] as? String == "Read the influx paper")
        #expect(task["notes"] as? String == "Figure 3 first")
        #expect(task["status"] as? String == "todo")
        #expect(task["assignee_record_name"] as? String == "_me")
        #expect(task["assignee_display_name"] as? String == "Robin")
        #expect(task["due_date"] as? String == "2026-09-30")
        #expect(task["source_id"] as? String == teamSourceID)
        #expect(task["doc_id"] is NSNull)
        #expect(task["completed_at"] is NSNull)
        #expect((created["message"] as? String)?.contains("Nexus") == true)

        // The store stamped the Notebook's team on the row itself.
        let stored = try #require(try knowledge.loadNotebookTask(taskID))
        #expect(stored.teamID == teamID)
        #expect(stored.assigneeRecordName == "_me")

        // List, with filters.
        let all = try parseJSON(try await store.listNotebookTasks(notebookID: teamNotebookID, status: nil, assignee: nil))
        #expect(all["count"] as? Int == 1)
        let mine = try parseJSON(try await store.listNotebookTasks(notebookID: teamNotebookID, status: "todo", assignee: "me"))
        #expect(mine["count"] as? Int == 1)
        let adas = try parseJSON(try await store.listNotebookTasks(notebookID: teamNotebookID, status: nil, assignee: "_ada"))
        #expect(adas["count"] as? Int == 0)
        let done = try parseJSON(try await store.listNotebookTasks(notebookID: teamNotebookID, status: "done", assignee: nil))
        #expect(done["count"] as? Int == 0)
        await #expect(throws: MCPError.self) {
            _ = try await store.listNotebookTasks(notebookID: teamNotebookID, status: "blocked", assignee: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.listNotebookTasks(notebookID: teamNotebookID, status: nil, assignee: "_nobody")
        }

        // Update: status, assignee, due date.
        let updated = try parseJSON(try await store.updateNotebookTask(
            taskID: taskID,
            title: nil,
            notes: nil,
            status: "done",
            assigneeRecordName: "_ada",
            dueDate: "",
            sourceID: nil,
            docID: nil
        ))
        let updatedTask = try #require(updated["task"] as? [String: Any])
        #expect(updatedTask["status"] as? String == "done")
        #expect(updatedTask["assignee_record_name"] as? String == "_ada")
        #expect(updatedTask["assignee_display_name"] as? String == "Ada")
        #expect(updatedTask["due_date"] is NSNull)
        #expect(updatedTask["completed_at"] is String)
        #expect(updatedTask["title"] as? String == "Read the influx paper")
        #expect(updatedTask["source_id"] as? String == teamSourceID)

        // Reopening clears the completion; "" unassigns.
        let reopened = try parseJSON(try await store.updateNotebookTask(
            taskID: taskID, title: nil, notes: nil, status: "doing",
            assigneeRecordName: "", dueDate: nil, sourceID: nil, docID: nil
        ))
        let reopenedTask = try #require(reopened["task"] as? [String: Any])
        #expect(reopenedTask["status"] as? String == "doing")
        #expect(reopenedTask["completed_at"] is NSNull)
        #expect(reopenedTask["assignee_record_name"] is NSNull)
        #expect(reopenedTask["assignee_display_name"] is NSNull)

        // Refusals: blank title, unknown member, unknown source, unknown task.
        await #expect(throws: MCPError.self) {
            _ = try await store.updateNotebookTask(
                taskID: taskID, title: "  ", notes: nil, status: nil,
                assigneeRecordName: nil, dueDate: nil, sourceID: nil, docID: nil
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.updateNotebookTask(
                taskID: taskID, title: nil, notes: nil, status: nil,
                assigneeRecordName: "_nobody", dueDate: nil, sourceID: nil, docID: nil
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.createNotebookTask(
                notebookID: teamNotebookID, title: "Bad source", notes: nil, status: nil,
                assigneeRecordName: nil, dueDate: nil, sourceID: "src-missing", docID: nil
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.updateNotebookTask(
                taskID: "no-such-task", title: "x", notes: nil, status: nil,
                assigneeRecordName: nil, dueDate: nil, sourceID: nil, docID: nil
            )
        }
        // A personal Notebook takes no assignee.
        await #expect(throws: MCPError.self) {
            _ = try await store.createNotebookTask(
                notebookID: notebook.id, title: "Mine", notes: nil, status: nil,
                assigneeRecordName: "_ada", dueDate: nil, sourceID: nil, docID: nil
            )
        }
        let personal = try parseJSON(try await store.createNotebookTask(
            notebookID: notebook.id, title: "Mine", notes: nil, status: "doing",
            assigneeRecordName: nil, dueDate: nil, sourceID: nil, docID: nil
        ))
        let personalTask = try #require(personal["task"] as? [String: Any])
        #expect(personalTask["team_id"] is NSNull)
        #expect(personalTask["status"] as? String == "doing")
        let personalBoard = try parseJSON(try await store.listNotebookTasks(notebookID: notebook.id, status: nil, assignee: nil))
        #expect(personalBoard["team"] is NSNull)
        #expect(personalBoard["count"] as? Int == 1)

        // Delete, through the registry so dispatch is covered too.
        let registry = MCPToolRegistry(store: store)
        let outcome = await registry.callToolDetailed(name: "delete_notebook_task", arguments: ["task_id": taskID])
        #expect(!outcome.isError, Comment(rawValue: outcome.text))
        let deleted = try parseJSON(outcome.text)
        #expect(deleted["deleted"] as? Bool == true)
        #expect(deleted["task_id"] as? String == taskID)
        #expect(try knowledge.loadNotebookTask(taskID) == nil)
        let afterDelete = try parseJSON(try await store.listNotebookTasks(notebookID: teamNotebookID, status: nil, assignee: nil))
        #expect(afterDelete["count"] as? Int == 0)
        let missing = await registry.callToolDetailed(name: "delete_notebook_task", arguments: ["task_id": taskID])
        #expect(missing.isError)
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

    @Test("share_notebook refuses until the learner affirms, then makes a team named after the notebook, holding it with its sources")
    func shareNotebookAsksThenShares() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-1", url: "https://example.com/one", title: "One"))
        try knowledge.saveSource(readySource(id: "src-2", url: "https://example.com/two", title: "Two"))
        let notebook = try makeNotebook(store, title: "🧬 Mitochondria", sourceIDs: ["src-1", "src-2"])
        let registry = MCPToolRegistry(store: store)

        try await withOwnRightsRow { defaults in
            // Not affirmed: refused with the question to ask, and nothing is
            // made. Only a JSON true is the learner's yes.
            for answer: Any? in [nil, false, 1, "true"] {
                var arguments: [String: Any] = ["notebook_id": notebook.id]
                if let answer { arguments["rights_affirmed_by_learner"] = answer }
                let refused = await registry.callToolDetailed(name: "share_notebook", arguments: arguments)
                #expect(refused.isError)
                #expect(refused.text.contains(SharingRightsAffirmation.assistantRefusal), "\(refused.text)")
            }
            #expect(try knowledge.loadTeams().isEmpty)
            #expect(defaults.object(forKey: SharingRightsAffirmation.preferenceKey) == nil)

            // The learner said yes: the answer is recorded, and the team is
            // made, named after the notebook, holding it with its sources.
            let outcome = await registry.callToolDetailed(
                name: "share_notebook",
                arguments: ["notebook_id": notebook.id, "rights_affirmed_by_learner": true]
            )
            #expect(!outcome.isError, "\(outcome.text)")
            let shared = try parseJSON(outcome.text)
            let teamID = try #require(shared["team_id"] as? String)
            #expect(shared["team_name"] as? String == "🧬 Mitochondria")
            #expect(shared["created_team"] as? Bool == true)
            #expect(shared["shared_sources"] as? Int == 2)
            #expect(shared["team_notebook_id"] as? String == TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: notebook.id))
            // No iCloud under test, so no link yet, and the answer says so.
            #expect(shared["invitation_link"] is NSNull)
            #expect(shared["link_opens_to_anyone"] as? Bool == false)
            #expect((shared["message"] as? String)?.contains("call share_notebook again") == true)
            #expect((shared["members"] as? [[String: Any]])?.isEmpty == true)
            #expect(try knowledge.loadTeams().map(\.id) == [teamID])
            #expect(Set(try knowledge.loadActiveSources(teamID: teamID).map(\.url)) == ["https://example.com/one", "https://example.com/two"])
            let row = try #require(defaults.string(forKey: SharingRightsAffirmation.preferenceKey))
            #expect(SharingRightsAffirmation(rowValue: row)?.version == SharingRightsAffirmation.currentVersion)

            // Asked once: the next call needs no answer, finds the same team,
            // makes no other, and returns the link Copy Invitation Link makes.
            try knowledge.replaceTeamMembers(teamID: teamID, members: [
                TeamMemberRecord(
                    userRecordName: "_me", teamID: teamID, displayName: "Robin", email: nil,
                    role: .owner, permission: .readWrite, acceptanceStatus: "accepted",
                    isCurrentUser: true, updatedAt: Date()
                ),
                TeamMemberRecord(
                    userRecordName: "_ada", teamID: teamID, displayName: "Ada", email: "ada@example.com",
                    role: .member, permission: .readOnly, acceptanceStatus: "pending",
                    isCurrentUser: false, updatedAt: Date()
                ),
            ])
            let again = try parseJSON(try await store.shareNotebook(
                notebookID: notebook.id,
                rightsAnswer: MCPDataStore.SharingRightsAnswer(nil),
                teamID: nil,
                invitationLink: { _ in URL(string: "https://www.icloud.com/share/0abcdefghijklmnop")! }
            ))
            #expect(again["created_team"] as? Bool == false)
            #expect(again["team_id"] as? String == teamID)
            #expect(again["invitation_link"] as? String == "https://www.icloud.com/share/0abcdefghijklmnop")
            // The owner's link opens the team to anyone with it, and says so.
            #expect(again["link_opens_to_anyone"] as? Bool == true)
            #expect((again["message"] as? String)?.contains("Anyone with invitation_link") == true)
            let members = try #require(again["members"] as? [[String: Any]])
            let me = try #require(members.first { $0["name"] as? String == "Robin" })
            #expect(me["role"] as? String == "owner")
            #expect(me["accepted"] as? Bool == true)
            #expect(me["email"] is NSNull)
            let ada = try #require(members.first { $0["name"] as? String == "Ada" })
            #expect(ada["role"] as? String == "viewer")
            #expect(ada["accepted"] as? Bool == false)
            #expect(ada["email"] as? String == "ada@example.com")
            #expect(try knowledge.loadTeams().count == 1)
        }
    }

    @Test("share_notebook writes the learner's answer only over no row or an older one: the current version's row and a later version's stay as they are")
    func shareNotebookKeepsARowThatAnswers() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let notebook = try makeNotebook(store, title: "Calcium", sourceIDs: [])
        let registry = MCPToolRegistry(store: store)

        try await withOwnRightsRow { defaults in
            let key = SharingRightsAffirmation.preferenceKey
            // The web and the iPhone write the row and then pass true; a
            // newer client's row answers this Mac's question as well.
            let current = SharingRightsAffirmation(affirmedAt: Date(timeIntervalSince1970: 1_791_028_800)).rowValue
            let later = #"{"version":2,"affirmedAt":"2026-10-04T08:00:00Z"}"#
            for row in [current, later] {
                defaults.set(row, forKey: key)
                for answer: Any? in [true, nil] {
                    var arguments: [String: Any] = ["notebook_id": notebook.id]
                    if let answer { arguments["rights_affirmed_by_learner"] = answer }
                    let outcome = await registry.callToolDetailed(name: "share_notebook", arguments: arguments)
                    #expect(!outcome.isError, "\(outcome.text)")
                    #expect(defaults.string(forKey: key) == row, "the answer was written over \(row)")
                }
            }
            // An older statement's row is answered again, at this version.
            defaults.set(#"{"version":0,"affirmedAt":"2026-10-01T08:00:00Z"}"#, forKey: key)
            let outcome = await registry.callToolDetailed(
                name: "share_notebook",
                arguments: ["notebook_id": notebook.id, "rights_affirmed_by_learner": true]
            )
            #expect(!outcome.isError, "\(outcome.text)")
            let row = try #require(defaults.string(forKey: key))
            #expect(SharingRightsAffirmation(rowValue: row)?.version == SharingRightsAffirmation.currentVersion)
            #expect(try store.knowledgeStore().loadTeams().count == 1)
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
        try knowledge.withoutSyncTracking {
            try knowledge.saveLearningGoalRecord(LearningGoalRecord(
                id: "proj-theirs", title: "Their notebook", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: Date(), updatedAt: Date(), status: "active", items: [],
                kind: LearningGoalRecord.companionKind, teamID: team.id
            ))
        }
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

    @Test("share_with_team asks the rights question for everything but a chat's transcript, after its own checks, and once")
    func shareWithTeamAsksOnce() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-1", url: "https://example.com/one", title: "One"))
        let notebook = try makeNotebook(store, title: "Calcium", sourceIDs: ["src-1"])
        try knowledge.saveReviewSessionRecord(CloudKitReviewSessionPayload(
            id: "chat-1", topic: "Chat", startedAt: Date(timeIntervalSinceReferenceDate: 50), endedAt: nil,
            status: "active", overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 1,
            goalID: nil,
            exchanges: [CloudKitReviewExchangePayload(
                id: "chat-1-ex-1", sessionID: "chat-1", sequenceNumber: 1, question: "Question", userAnswer: "Answer",
                evaluation: "Reply", score: nil, sourceRefs: [], knowledgeNote: nil,
                answeredAt: Date(timeIntervalSinceReferenceDate: 100), contextContent: nil
            )],
            kind: nil
        ))
        let registry = MCPToolRegistry(store: store)

        try await withOwnRightsRow { defaults in
            let teamID = try await createTeam(store, name: "Nexus")
            // A chat's transcript carries no source: shared without asking.
            let chat = await registry.callToolDetailed(name: "share_with_team", arguments: ["team_id": teamID, "kind": "chat", "ids": ["chat-1"]])
            #expect(!chat.isError, "\(chat.text)")
            // A source is refused until the learner affirms, after an unknown
            // id has been refused on its own terms.
            let unknown = await registry.callToolDetailed(name: "share_with_team", arguments: ["team_id": teamID, "kind": "source", "ids": ["src-missing"]])
            #expect(unknown.isError)
            #expect(!unknown.text.contains(SharingRightsAffirmation.assistantQuestion))
            let refused = await registry.callToolDetailed(name: "share_with_team", arguments: ["team_id": teamID, "kind": "source", "ids": ["src-1"]])
            #expect(refused.isError)
            #expect(refused.text.contains(SharingRightsAffirmation.assistantRefusal))
            #expect(try knowledge.loadActiveSources(teamID: teamID).isEmpty)
            #expect(defaults.object(forKey: SharingRightsAffirmation.preferenceKey) == nil)

            let shared = await registry.callToolDetailed(
                name: "share_with_team",
                arguments: ["team_id": teamID, "kind": "source", "ids": ["src-1"], "rights_affirmed_by_learner": true]
            )
            #expect(!shared.isError, "\(shared.text)")
            #expect(try knowledge.loadActiveSources(teamID: teamID).count == 1)
            #expect(!SharingRightsRow.needsAsking)

            // Asked once: a notebook goes next with no answer at all.
            let next = await registry.callToolDetailed(name: "share_with_team", arguments: ["team_id": teamID, "kind": "notebook", "ids": [notebook.id]])
            #expect(!next.isError, "\(next.text)")
        }
    }

    @Test("fulfil_share_request asks the rights question before it copies a source into the team, after the request's own checks")
    func fulfilShareRequestAsks() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveSource(readySource(id: "src-held", url: "https://example.com/held", title: "Held"))
        let registry = MCPToolRegistry(store: store)

        try await withOwnRightsRow { defaults in
            let teamID = try await createTeam(store, name: "Bench Lab")
            func request(_ url: String) async throws -> String {
                let made = try parseJSON(try await store.requestShare(teamID: teamID, url: url, title: nil, docID: nil))
                return try #require((made["request"] as? [String: Any])?["id"] as? String)
            }
            // A request this Mac cannot answer is refused on its own terms.
            let notHeld = try await request("https://example.com/not-held")
            let unanswerable = await registry.callToolDetailed(name: "fulfil_share_request", arguments: ["request_id": notHeld])
            #expect(unanswerable.isError)
            #expect(!unanswerable.text.contains(SharingRightsAffirmation.assistantQuestion))

            // One it can: refused with the question until the learner affirms.
            let held = try await request("https://example.com/held")
            let refused = await registry.callToolDetailed(name: "fulfil_share_request", arguments: ["request_id": held])
            #expect(refused.isError)
            #expect(refused.text.contains(SharingRightsAffirmation.assistantRefusal), "\(refused.text)")
            #expect(try knowledge.loadActiveSources(teamID: teamID).isEmpty)
            #expect(try knowledge.loadOpenShareRequests().map(\.id).contains(held))
            #expect(defaults.object(forKey: SharingRightsAffirmation.preferenceKey) == nil)

            let answered = await registry.callToolDetailed(
                name: "fulfil_share_request",
                arguments: ["request_id": held, "rights_affirmed_by_learner": true]
            )
            #expect(!answered.isError, "\(answered.text)")
            #expect(try knowledge.loadActiveSources(teamID: teamID).count == 1)
            #expect(!SharingRightsRow.needsAsking)
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
        try knowledge.withoutSyncTracking {
            try knowledge.saveLearningGoalRecord(LearningGoalRecord(
                id: "proj-team", title: "Theirs", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: Date(), updatedAt: Date(), status: "active", items: [],
                kind: LearningGoalRecord.companionKind, teamID: team.id
            ))
        }
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

    @Test("share_with_team kind doc carries the Doc's linked and cited sources by default; include_cited_sources false keeps the cited ones behind")
    func shareDocCarriesItsSources() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let teamID = try await createTeam(store, name: "Bench Lab")
        var book = readySource(id: "src-book", url: "https://doi.org/10.1000/closed-book", title: "Closed book")
        book.sourceType = .book
        book.normalizedURL = URLNormalizer.normalize(book.url)
        try knowledge.saveSource(book)
        try knowledge.saveSource(readySource(id: "src-grounding", url: "https://example.com/grounding", title: "Grounding"))
        let markdown = "# Landscape\n\nThe result is in [the book](https://doi.org/10.1000/closed-book)."

        // Two Docs citing the book, each grounded on a source and on an id no
        // library holds.
        var docIDs: [String] = []
        for title in ["First", "Second"] {
            let created = try parseJSON(try await store.createArtifact(title: title, homeNotebookID: nil, notebookIDs: [], markdown: markdown))
            let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
            var record = try #require(try knowledge.loadArtifact(docID))
            record.sourceIDs = ["src-grounding", "src-gone"]
            try knowledge.saveArtifactRecord(record)
            docIDs.append(docID)
        }
        let groundingCopyID = TeamContentIdentity.sourceID(teamID: teamID, url: "https://example.com/grounding")
        let bookCopyID = TeamContentIdentity.sourceID(teamID: teamID, url: book.url)

        // Nothing asked: both routes travel.
        let shared = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "doc", ids: [docIDs[0]], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: nil
        ))
        let linked = try #require(shared["linked_sources_shared"] as? [[String: Any]])
        #expect(linked.count == 1)
        #expect(linked.first?["original_id"] as? String == "src-grounding")
        #expect(linked.first?["team_copy_id"] as? String == groundingCopyID)
        #expect(linked.first?["doc_id"] as? String == docIDs[0])
        let cited = try #require(shared["cited_sources_shared"] as? [[String: Any]])
        #expect(cited.map { $0["team_copy_id"] as? String } == [bookCopyID])
        let notShared = try #require(shared["sources_not_shared"] as? [[String: Any]])
        #expect(notShared.map { $0["original_id"] as? String } == ["src-gone"])
        #expect((notShared.first?["reason"] as? String)?.isEmpty == false)
        #expect((shared["message"] as? String)?.contains("2 sources the team lacked travelled with it (1 linked, 1 cited)") == true)
        #expect((shared["message"] as? String)?.contains("1 source could not be copied") == true)
        #expect((shared["guidance"] as? String)?.contains("travel with it by default") == true)
        let copyID = try #require((shared["copies"] as? [[String: Any]])?.first?["team_copy_id"] as? String)
        let copy = try #require(try knowledge.loadArtifact(copyID))
        #expect(copy.teamID == teamID)
        #expect(copy.sourceIDs == [groundingCopyID], "the copy names the team's copy and drops the id nobody holds")
        #expect(Set(try knowledge.loadActiveSources(teamID: teamID).map(\.id)) == [groundingCopyID, bookCopyID])
        #expect(try knowledge.loadActiveSources().map(\.id).sorted() == ["src-book", "src-grounding"], "My Library is untouched")

        // Opting out keeps the cited book behind; the linked source still
        // travels, because the copy has to resolve. Here the team already
        // holds both, so nothing new is copied either way.
        let optedOut = try parseJSON(try await store.shareWithTeam(
            teamID: teamID, kind: "doc", ids: [docIDs[1]], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: false
        ))
        #expect((optedOut["linked_sources_shared"] as? [[String: Any]])?.isEmpty == true, "the team already held the grounding source")
        #expect((optedOut["cited_sources_shared"] as? [[String: Any]])?.isEmpty == true)
        #expect((optedOut["message"] as? String)?.contains("left behind as asked") == true)
        let secondCopyID = try #require((optedOut["copies"] as? [[String: Any]])?.first?["team_copy_id"] as? String)
        #expect(try knowledge.loadArtifact(secondCopyID)?.sourceIDs == [groundingCopyID])
        #expect(try knowledge.loadActiveSources(teamID: teamID).count == 2)

        // A fresh team and an opt-out: the cited book stays behind for real.
        let otherTeamID = try await createTeam(store, name: "Nexus")
        let fresh = try parseJSON(try await store.shareWithTeam(
            teamID: otherTeamID, kind: "doc", ids: [docIDs[1]], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: false
        ))
        #expect((fresh["linked_sources_shared"] as? [[String: Any]])?.count == 1)
        #expect((fresh["cited_sources_shared"] as? [[String: Any]])?.isEmpty == true)
        #expect(try knowledge.loadActiveSources(teamID: otherTeamID).map(\.id) == [TeamContentIdentity.sourceID(teamID: otherTeamID, url: "https://example.com/grounding")])
        #expect(knowledge.activeSourceID(forReferenceURL: book.url, teamID: otherTeamID) == nil)

        // The opt-in flag is still a doc-only argument.
        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(teamID: teamID, kind: "source", ids: ["src-book"], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: false)
        }
    }

    /// A publisher stub for the site tools: records the access each publish
    /// sent and answers like the host, with a fixed address for a new site.
    actor AccessRecorder {
        var access: [SitePublishingAccess?] = []
        var held: [String: PublishedSiteStatus] = [:]
        func record(_ value: SitePublishingAccess?) { access.append(value) }
        func hold(_ status: PublishedSiteStatus) { held[status.siteID] = status }
        func status(_ id: String) -> PublishedSiteStatus? { held[id] }
    }

    private func siteHosting(recordingAccessInto recorder: AccessRecorder, signedIn: Bool = true) -> MCPDataStore.SiteHosting {
        MCPDataStore.SiteHosting(
            isSignedIn: signedIn,
            publish: { siteID, title, files, slug, source, access in
                await recorder.record(access)
                let address = slug ?? "atlas"
                let status = PublishedSiteStatus(
                    siteID: siteID, url: URL(string: "https://sites.foreverlm.com/\(address)/")!, slug: address, title: title,
                    publishedAt: Date(), updatedAt: Date(), bytes: files.reduce(0) { $0 + $1.data.count },
                    filePaths: files.map(\.path), isCustomSlug: slug != nil, source: source, access: access
                )
                await recorder.hold(status)
                return status
            },
            status: { await recorder.status($0) },
            readFile: { _, _ in throw DocPublishingError.malformedResponse },
            unpublish: { _ in true }
        )
    }

    /// docs/teams-design.md, decision 17 (product owner, 2026-09-18: "if a doc or
    /// site is shared with the team; it should still show up under my library
    /// too"). A site saved into a team Notebook is the learner's own entry with
    /// a copy — files and all — in the team.
    @Test("save_site into a team Notebook keeps the learner's own entry and files a copy, with its own files, in the team; publishing opens it to the team")
    func saveSiteIntoTeamNotebookKeepsOwnEntry() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let notebook = try makeNotebook(store, title: "Bench Lab", sourceIDs: [])
        let teamID = try await createTeam(store, name: "Bench Lab")
        let teamNotebookID = try await notebookFileStorageShare(store, notebookID: notebook.id, teamID: teamID)
        let recorder = AccessRecorder()

        let saved = try parseJSON(try await store.saveSite(
            site: nil, title: "Atlas", html: "<h1>Atlas</h1><p>Forty compounds.</p>", files: nil,
            repository: nil, repositoryPath: nil, ref: nil,
            homeNotebookID: teamNotebookID, notebookIDs: [],
            hosting: siteHosting(recordingAccessInto: recorder, signedIn: false)
        ))

        let rows = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).filter { $0.linkedKind == .foreverlmSite }
        let own = try #require(rows.first { $0.teamID == nil }, "the learner's own entry, in My Library")
        let copy = try #require(rows.first { $0.teamID == teamID }, "the team's copy of the site")
        #expect(rows.count == 2)
        #expect(saved["site_id"] as? String == own.id)
        #expect(own.linkedURL == "foreverlm-site://\(own.id)/")
        #expect(copy.linkedURL == "foreverlm-site://\(copy.id)/", "the copy is served from its own files")
        #expect(copy.id == TeamContentIdentity.artifactCopyID(teamID: teamID, original: own))
        #expect(own.homeNotebookID == nil && own.linkedNotebookIDs.isEmpty, "the team Notebook files the copy, not the own entry")
        #expect(copy.homeNotebookID == teamNotebookID)
        #expect(copy.kind == own.kind)
        #expect(copy.title == "Atlas")
        #expect(saved["team_ids_holding_copy"] as? [String] == [teamID])
        #expect(try await store.notebookFileStorage.localSiteFilePaths(artifactID: copy.id) == ["index.html"])
        #expect(try await store.notebookFileStorage.teamsHoldingArtifact(own.id).map(\.id) == [teamID])
        #expect(await recorder.access.isEmpty, "saving publishes nothing")

        // An update keeps one row per library and refreshes the copy's files and text.
        _ = try await store.saveSite(
            site: own.id, title: nil, html: "<h1>Atlas</h1><p>Forty-one compounds.</p>", files: nil,
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [],
            hosting: siteHosting(recordingAccessInto: recorder, signedIn: false)
        )
        let after = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).filter { $0.linkedKind == .foreverlmSite }
        #expect(after.map(\.id).sorted() == [own.id, copy.id].sorted())
        let copyText = try parseJSON(try await store.readArtifact(artifactID: copy.id))["markdown"] as? String
        #expect(copyText?.contains("Forty-one") == true)
        let copyPage = try await store.notebookFileStorage.readLocalSiteFile(artifactID: copy.id, path: "index.html")
        #expect(copyPage.flatMap { String(data: $0, encoding: .utf8) }?.contains("Forty-one") == true)

        // Publishing the site opens the copy to the team's roster; a team copy
        // names its original when handed to the site tools.
        let published = try parseJSON(try await store.publishSite(
            site: copy.id, title: nil, html: nil, files: nil, repository: nil, repositoryPath: nil, ref: nil, slug: nil,
            homeNotebookID: nil, notebookIDs: [], hosting: siteHosting(recordingAccessInto: recorder)
        ))
        #expect(published["team_id"] as? String == teamID)
        #expect(await recorder.access.first??.teamID == teamID)
        #expect(await recorder.held[own.id] != nil, "the copy is published under the learner's own record")
    }

    /// A team row made before build 114 — a page published straight into a
    /// team Notebook, no own entry — whose files are still on the host under
    /// this account is brought home in place when the site tools change it.
    /// Until 2026-09-25 every such row was refused, and a chat asked to add
    /// one compound to the Mitochondrial Therapeutics Atlas retried the
    /// refusal some sixty times.
    @Test("a team row made before build 114 that this account published is brought home in place by save_site, and publish_site keeps its address")
    func teamRowPublishedByThisAccountIsBroughtHome() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let notebook = try makeNotebook(store, title: "Bench Lab", sourceIDs: [])
        let teamID = try await createTeam(store, name: "Bench Lab")
        let teamNotebookID = try await notebookFileStorageShare(store, notebookID: notebook.id, teamID: teamID)
        let url = URL(string: "https://sites.foreverlm.com/atlas/")!
        let teamRow = try await store.notebookFileStorage.createLinkedArtifact(
            url: url, title: "Atlas", homeNotebookID: teamNotebookID, linkedNotebookIDs: [], teamID: teamID
        )
        let host = MCPDataStoreTests.SiteHostRecorder()
        let hosted = [SiteFile(path: "index.html", data: Data("<h1>Atlas</h1><p>Forty compounds.</p>".utf8))]
        await host.hold(
            PublishedSiteStatus(
                siteID: teamRow.id, url: url, slug: "atlas", title: "Atlas",
                publishedAt: Date(), updatedAt: Date(), bytes: 0, filePaths: hosted.map(\.path)
            ),
            files: hosted,
            under: "atlas"
        )
        #expect(!HostedSiteAdoption.needsAdoption(teamRow), "the launch pass still leaves team rows to the site tools")

        let saved = try parseJSON(try await store.saveSite(
            site: "atlas", title: nil, html: nil, files: [["path": "about.html", "content": "<p>TPP-thiazole</p>"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [],
            hosting: host.hosting()
        ))
        #expect(saved["brought_home"] as? Bool == true)
        #expect(saved["site_id"] as? String == teamRow.id, "brought home in place: still the team's record")
        #expect(saved["team_ids_holding_copy"] == nil, "the team's own record is not a copy in it")
        #expect((saved["message"] as? String)?.contains("slug \"atlas\"") == true, "the model is told how to put it back at its address")
        let files = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: teamRow.id))
        #expect(files.map(\.path) == ["about.html", "index.html"])
        let rows = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).filter { $0.linkedKind == .foreverlmSite }
        #expect(rows.map(\.id) == [teamRow.id], "no second entry and no copy of the team's own record")
        let record = try #require(rows.first)
        #expect(record.teamID == teamID)
        #expect(record.linkedURL == "foreverlm-site://\(teamRow.id)/")
        let strayCopyID = TeamContentIdentity.artifactCopyID(teamID: teamID, original: record)
        #expect(try await store.notebookFileStorage.localSiteFilePaths(artifactID: strayCopyID) == nil, "saving a team row writes no files for a copy of itself")
        #expect(await host.unpublished == (HostedSiteAdoption.takesDownHostedCopy ? ["atlas"] : []))

        // publish_site as the first change brings the row home and puts the
        // published copy back at the address it had.
        let panelURL = URL(string: "https://sites.foreverlm.com/panel/")!
        let panelRow = try await store.notebookFileStorage.createLinkedArtifact(
            url: panelURL, title: "Panel", homeNotebookID: teamNotebookID, linkedNotebookIDs: [], teamID: teamID
        )
        let panelFiles = [SiteFile(path: "index.html", data: Data("<h1>Panel</h1>".utf8))]
        await host.hold(
            PublishedSiteStatus(
                siteID: panelRow.id, url: panelURL, slug: "panel", title: "Panel",
                publishedAt: Date(), updatedAt: Date(), bytes: 0, filePaths: panelFiles.map(\.path)
            ),
            files: panelFiles,
            under: "panel"
        )
        _ = try await store.publishSite(
            site: "panel", title: nil, html: nil, files: nil, repository: nil, repositoryPath: nil, ref: nil, slug: nil,
            homeNotebookID: nil, notebookIDs: [], hosting: host.hosting()
        )
        let publish = try #require(await host.publishes.last)
        #expect(publish.siteID == panelRow.id)
        #expect(publish.slug == "panel")
        #expect(try await store.notebookFileStorage.localSiteFilePaths(artifactID: panelRow.id) == ["index.html"])
    }

    /// A team row whose hosted copy belongs to a teammate cannot be read from
    /// this account; the refusal names who can move it and asks the chat not
    /// to retry.
    @Test("a team row made before build 114 whose files are hosted under a teammate's account is left as a link, and save_site says who can move it")
    func teamRowHostedByTeammateIsLeftAsLink() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let notebook = try makeNotebook(store, title: "Bench Lab", sourceIDs: [])
        let teamID = try await createTeam(store, name: "Bench Lab")
        let teamNotebookID = try await notebookFileStorageShare(store, notebookID: notebook.id, teamID: teamID)
        let url = URL(string: "https://sites.foreverlm.com/atlas/")!
        let teamRow = try await store.notebookFileStorage.createLinkedArtifact(
            url: url, title: "Atlas", homeNotebookID: teamNotebookID, linkedNotebookIDs: [], teamID: teamID
        )
        #expect(!HostedSiteAdoption.needsAdoption(teamRow), "the host's automatic pass skips team rows")
        do {
            _ = try await store.saveSite(
                site: "atlas", title: nil, html: "<h1>Atlas</h1>", files: nil,
                repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [],
                hosting: siteHosting(recordingAccessInto: AccessRecorder())
            )
            Issue.record("a teammate's hosted team row was changed")
        } catch {
            #expect(error.localizedDescription.contains("under the account of the teammate who published it"))
            #expect(error.localizedDescription.contains("Do not retry"))
        }
        let rows = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).filter { $0.linkedURL == url.absoluteString }
        #expect(rows.map(\.id) == [teamRow.id])
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
