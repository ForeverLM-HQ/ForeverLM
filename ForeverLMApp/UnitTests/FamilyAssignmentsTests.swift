import CloudKit
import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

#if os(macOS)

/// Assignments and family plans (docs/family-design.md). An assignment is a
/// task on a team's one Assignments Notebook, pointing at the team's copy of a
/// source; finishing the source — reading it to the end or reviewing it —
/// closes the learner's own open tasks for it, whichever copy they read. A
/// family plan's code rides the team's record (schema 137) so a member's Mac
/// can join, and a member's OpenRouter key crosses only as HPKE ciphertext.
@Suite("Family assignments")
struct FamilyAssignmentsTests {

    // MARK: Fixtures

    private static func makeTeam(
        _ store: KnowledgeStore,
        id: String = "family-1",
        role: TeamRole = .member,
        permission: TeamPermission = .readWrite,
        familyPlanCode: String? = nil
    ) throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: id,
            name: "Dekker",
            role: role,
            permission: permission,
            zoneScope: role == .owner ? .privateScope : .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: role == .owner ? nil : "_parent",
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now,
            familyPlanCode: familyPlanCode
        )
        try store.saveTeam(team)
        return team
    }

    /// A child's view of a family: the parent owns it, this account is the
    /// child `_kid`, and a sibling `_sib` is there too.
    private static func seedRoster(_ store: KnowledgeStore, teamID: String, me: String = "_kid") throws {
        let now = Date()
        func member(_ name: String, _ display: String, role: TeamRole) -> TeamMemberRecord {
            TeamMemberRecord(
                userRecordName: name, teamID: teamID, displayName: display, email: nil,
                role: role, permission: .readWrite, acceptanceStatus: "accepted",
                isCurrentUser: name == me, updatedAt: now
            )
        }
        try store.replaceTeamMembers(teamID: teamID, members: [
            member("_parent", "Morgan", role: .owner),
            member("_kid", "Elin", role: .member),
            member("_sib", "Sol", role: .member),
        ])
    }

    private static func source(id: String, url: String, title: String, teamID: String? = nil) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        let text = "Readable text of \(title), long enough to count as a source."
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        article.teamID = teamID
        return article
    }

    /// Plants a task on the team's Assignments board the way a parent's Mac
    /// would have sent it.
    @discardableResult
    private static func assignment(
        _ store: KnowledgeStore,
        teamID: String,
        id: String,
        assignee: String,
        sourceID: String,
        status: NotebookTaskStatus = .todo,
        dueAt: Date? = nil
    ) throws -> NotebookTaskRecord {
        let notebook = try store.ensureAssignmentsNotebook(teamID: teamID)
        let task = NotebookTaskRecord(
            id: id, notebookID: notebook.id, teamID: teamID, title: "Read it", status: status,
            assigneeRecordName: assignee, assigneeDisplayName: assignee, dueAt: dueAt, sourceID: sourceID,
            createdByRecordName: "_parent", createdByDisplayName: "Morgan"
        )
        try store.saveNotebookTask(task)
        return try #require(try store.loadNotebookTask(id))
    }

    // MARK: Assignments Notebook

    @Test("A team has one Assignments Notebook, the same id on every device, and it is a team Notebook")
    func assignmentsNotebookIsDeterministic() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store, role: .owner)
        let first = try store.ensureAssignmentsNotebook(teamID: team.id)
        let second = try store.ensureAssignmentsNotebook(teamID: team.id)
        #expect(first.id == second.id)
        #expect(first.id == TeamContentIdentity.assignmentsNotebookID(teamID: team.id))
        #expect(first.id != TeamContentIdentity.assignmentsNotebookID(teamID: "another-team"))
        #expect(first.teamID == team.id)
        #expect(first.isNotebook)
        #expect(first.title == KnowledgeStore.assignmentsNotebookTitle)
        #expect(try store.loadLearningGoals().filter { $0.id == first.id }.count == 1)
    }

    // MARK: Finishing a source finishes its assignment

    @Test("Reading my own copy of an assigned paper closes my open task for the team's copy, and nobody else's")
    func readingOwnCopyClosesTeamTask() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedRoster(store, teamID: team.id)
        let url = "https://example.com/mitochondria"
        let teamCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: url)
        try store.saveSource(Self.source(id: "src-own", url: url, title: "Mitochondria"))
        try store.saveSource(Self.source(id: teamCopyID, url: url, title: "Mitochondria", teamID: team.id))
        try Self.assignment(store, teamID: team.id, id: "mine", assignee: "_kid", sourceID: teamCopyID)
        try Self.assignment(store, teamID: team.id, id: "sibling", assignee: "_sib", sourceID: teamCopyID)

        let readAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try store.updateSourceReadAt(sourceID: "src-own", readAt: readAt)

        let mine = try #require(try store.loadNotebookTask("mine"))
        #expect(mine.status == .done)
        #expect(mine.completedAt == readAt)
        #expect(try store.loadNotebookTask("sibling")?.status == .todo, "a sibling's task is theirs to finish")
    }

    @Test("Reading the team's copy itself closes the task too; marking a source unread leaves it alone")
    func readingTeamCopyClosesTask() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedRoster(store, teamID: team.id)
        let url = "https://example.com/calcium"
        let teamCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: url)
        try store.saveSource(Self.source(id: teamCopyID, url: url, title: "Calcium", teamID: team.id))
        try Self.assignment(store, teamID: team.id, id: "task", assignee: "_kid", sourceID: teamCopyID)

        try store.updateSourceReadAt(sourceID: teamCopyID, readAt: nil)
        #expect(try store.loadNotebookTask("task")?.status == .todo)

        try store.updateSourceReadAt(sourceID: teamCopyID, readAt: Date())
        #expect(try store.loadNotebookTask("task")?.status == .done)
    }

    @Test("A review of the source closes the assignment in the same transaction as the completion")
    func reviewClosesTask() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedRoster(store, teamID: team.id)
        let url = "https://example.com/membranes"
        let teamCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: url)
        try store.saveSource(Self.source(id: "src-own", url: url, title: "Membranes"))
        try Self.assignment(store, teamID: team.id, id: "task", assignee: "_kid", sourceID: teamCopyID)

        let now = Date()
        try store.execForTesting("BEGIN IMMEDIATE")
        try store.recordScheduledSourceReviewRows(sourceID: "src-own", on: now, recordedAt: now)
        try store.execForTesting("COMMIT")

        #expect(try store.loadNotebookTask("task")?.status == .done)
    }

    @Test("Forgetting a review recorded in error reopens the assignment it closed, and leaves one finished another way done")
    func forgettingAReviewReopensItsAssignment() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedRoster(store, teamID: team.id)
        let url = "https://example.com/wrongly-reviewed"
        let teamCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: url)
        try store.saveSource(Self.source(id: "src-own", url: url, title: "Wrongly reviewed"))
        try Self.assignment(store, teamID: team.id, id: "closed-by-review", assignee: "_kid", sourceID: teamCopyID)
        // Finished on the board by hand an hour before the review ran.
        var byHand = try Self.assignment(store, teamID: team.id, id: "done-by-hand", assignee: "_kid", sourceID: teamCopyID, status: .done)
        byHand.completedAt = Date(timeIntervalSinceNow: -3600)
        try store.saveNotebookTask(byHand)

        try store.recordScheduledSourceReview(sourceID: "src-own", on: Date())
        #expect(try store.loadNotebookTask("closed-by-review")?.status == .done)
        let day = try #require(try store.loadSourceActivityDays(sourceID: "src-own").first).dayStart

        let forgotten = try store.forgetAutomaticSourceActivity(sourceIDs: ["src-own"], on: day)
        #expect(forgotten.map(\.reopenedTaskIDs) == [["closed-by-review"]])
        let reopened = try #require(try store.loadNotebookTask("closed-by-review"))
        #expect(reopened.status == .todo)
        #expect(reopened.completedAt == nil)
        #expect(try store.loadNotebookTask("done-by-hand")?.status == .done, "only the review's own completion is taken back")
        #expect(try store.scheduledSourceID(forSource: "src-own") == nil)
    }

    @Test("A read-only family is never written: its board belongs to the owner")
    func readOnlyTeamIsUntouched() throws {
        let store = try KnowledgeStore(inMemory: true)
        var team = try Self.makeTeam(store)
        try Self.seedRoster(store, teamID: team.id)
        let url = "https://example.com/readonly"
        let teamCopyID = TeamContentIdentity.sourceID(teamID: team.id, url: url)
        try store.saveSource(Self.source(id: "src-own", url: url, title: "Read only"))
        try Self.assignment(store, teamID: team.id, id: "task", assignee: "_kid", sourceID: teamCopyID)
        // The owner then gave this member read access only.
        team.permission = .readOnly
        try store.saveTeam(team)

        try store.updateSourceReadAt(sourceID: "src-own", readAt: Date())

        #expect(try store.loadNotebookTask("task")?.status == .todo)
    }

    @Test("Assigned to me lists only my tasks, open ones by due date, and today's finished ones when asked")
    func assignedToMeOrdering() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try Self.makeTeam(store)
        try Self.seedRoster(store, teamID: team.id)
        try store.saveSource(Self.source(id: "src-a", url: "https://example.com/a", title: "Alpha", teamID: team.id))
        try store.saveSource(Self.source(id: "src-b", url: "https://example.com/b", title: "Beta", teamID: team.id))
        try store.saveSource(Self.source(id: "src-c", url: "https://example.com/c", title: "Gamma", teamID: team.id))
        let soon = Date().addingTimeInterval(86_400)
        let later = Date().addingTimeInterval(7 * 86_400)
        try Self.assignment(store, teamID: team.id, id: "later", assignee: "_kid", sourceID: "src-a", dueAt: later)
        try Self.assignment(store, teamID: team.id, id: "soon", assignee: "_kid", sourceID: "src-b", dueAt: soon)
        try Self.assignment(store, teamID: team.id, id: "undated", assignee: "_kid", sourceID: "src-c")
        try Self.assignment(store, teamID: team.id, id: "sibling", assignee: "_sib", sourceID: "src-a")
        try Self.assignment(store, teamID: team.id, id: "done", assignee: "_kid", sourceID: "src-c", status: .done)

        let open = try store.loadAssignedToMe()
        #expect(open.map(\.id) == ["soon", "later", "undated"])
        #expect(open.first?.sourceTitle == "Beta")
        #expect(open.first?.teamName == "Dekker")

        let withToday = try store.loadAssignedToMe(recentlyDoneSince: Calendar.current.startOfDay(for: Date()))
        #expect(withToday.map(\.id) == ["soon", "later", "undated", "done"])
    }

    // MARK: Family plan code (schema 137)

    // MARK: Migration

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalar(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    // MARK: Sealing

    @Test("A key sealed to a child's device opens only with that device's private key")
    func sealingRoundTrip() throws {
        let child = Curve25519.KeyAgreement.PrivateKey()
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try FamilyKeySealing.seal(
            "sk-or-v1-child-key",
            toPublicKeyBase64: child.publicKey.rawRepresentation.base64EncodedString()
        )
        #expect(!sealed.sealedKey.contains("child-key"))
        #expect(Data(base64Encoded: sealed.encapsulation)?.count == 32, "the proxy checks for a 32-byte encapsulation")
        let wire = FamilyPlanClient.SealedKey(sealedKey: sealed.sealedKey, encapsulation: sealed.encapsulation, label: nil, updatedAt: nil)
        #expect(try FamilyKeySealing.open(wire, with: child) == "sk-or-v1-child-key")
        #expect(throws: (any Error).self) {
            _ = try FamilyKeySealing.open(wire, with: stranger)
        }
    }

    @Test("The proxy's family status decodes, a parent's families and a child's sealed key alike")
    func statusDecodes() throws {
        let json = #"""
        {"max_members":5,
         "families":[{"team_id":"t1","family_plan":true,"members":[{"member_id":"m1","display_name":"Elin","cloudkit_user_record_name":"_kid","device_public_key":"AAAA","has_key":true,"key_label":"ForeverLM · Elin","key_updated_at":"2026-09-25 10:00:00","joined_at":"2026-09-25 09:00:00"}]}],
         "membership":{"team_id":"t2","member_id":"m9","covered":true,"device_public_key":"BBBB","key":{"sealed_key":"CCCC","encapsulation":"DDDD","label":null,"updated_at":"2026-09-25 11:00:00"}}}
        """#
        let status = try JSONDecoder().decode(FamilyPlanClient.Status.self, from: Data(json.utf8))
        #expect(status.maxMembers == 5)
        #expect(status.family(teamID: "t1")?.members.first?.hasKey == true)
        #expect(status.family(teamID: "t1")?.members.first?.cloudKitUserRecordName == "_kid")
        #expect(status.membership?.covered == true)
        #expect(status.membership?.key?.sealedKey == "CCCC")
    }
}

/// The MCP twins: assign_to_member copies the source into the team and puts
/// it on the member's Assignments board, and list_assignments reads it back
/// from either side.
@Suite("MCP family tools")
struct MCPFamilyToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_family_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // Generation 1's teams (zones of the old container); a space needs a running sync coordinator.
        let store = MCPDataStore(dbPath: tmpDir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    @Test("The registry advertises the family tools")
    func registryAdvertisesFamilyTools() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for name in ["assign_to_member", "list_assignments", "get_family_plan", "set_family_plan", "connect_family_member_key"] {
            let tool = try #require(byName[name], "\(name) is not registered")
            #expect(tool.inputSchema["type"] as? String == "object")
        }
        #expect(byName["assign_to_member"]?.inputSchema["required"] as? [String] == ["team_id", "member"])
        #expect(byName["set_family_plan"]?.inputSchema["required"] as? [String] == ["team_id", "enabled"])
    }
}

#endif
