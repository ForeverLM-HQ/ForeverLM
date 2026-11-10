import Foundation
import Testing
@testable import ForeverLM

/// The Share popover's rule (`DocSharing`): the rows it lists, the sentence
/// every surface says, and what each change sends to the site.
/// Spec: docs/docs-design.md → Publishing → The Share popover.
@Suite("Doc sharing popover")
struct DocSharingPopoverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(readers: [String] = [], isProtected: Bool? = nil, password: String? = nil) -> PublishedDocStatus {
        PublishedDocStatus(
            docID: "doc-1",
            url: URL(string: "https://foreverlm.com/share/abcdefghjkmn")!,
            slug: "abcdefghjkmn",
            title: "Mitochondrial interventions",
            publishedAt: now,
            updatedAt: now,
            isProtected: isProtected ?? (!readers.isEmpty || password != nil),
            readers: readers,
            password: password
        )
    }

    private func team(_ id: String, _ name: String, permission: TeamPermission = .readWrite) -> TeamRecord {
        TeamRecord(
            id: id, name: name, role: .owner, permission: permission,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: nil, shareRecordName: nil, shareURL: nil,
            createdAt: now, joinedAt: now, updatedAt: now
        )
    }

    private func member(_ name: String, email: String?, accepted: Bool = true, isCurrentUser: Bool = false) -> TeamMemberRecord {
        TeamMemberRecord(
            userRecordName: "_" + name.lowercased(), teamID: "t1", displayName: name, email: email,
            role: .member, permission: .readWrite, acceptanceStatus: accepted ? "accepted" : "pending",
            isCurrentUser: isCurrentUser, updatedAt: now
        )
    }

    // MARK: - Rows

    @Test("An unpublished Doc lists the closed link, every team as No access, and the author")
    func rowsUnpublished() {
        let model = DocSharing.model(
            status: nil,
            teams: [team("t1", "Bench Lab"), team("t2", "Acme Lab", permission: .readOnly)],
            teamsHoldingCopy: [],
            identity: DocSharing.Identity(displayName: "Milo", email: "info@foreverlm.com"),
            showsTeams: true
        )
        #expect(model.rows == [
            .anyoneWithLink(canRead: false),
            .team(DocSharing.Team(id: "t1", name: "Bench Lab", permission: .readWrite, holdsCopy: false)),
            .team(DocSharing.Team(id: "t2", name: "Acme Lab", permission: .readOnly, holdsCopy: false)),
            .author(name: "Milo", email: "info@foreverlm.com"),
        ])
        #expect(!model.isPublished)
        #expect(!model.isOpen)
        #expect(model.url == nil)
        #expect(model.summary == "Only you can open this Page")
    }

    @Test("An open page with a team copy: the link reads, the team is marked as holding a copy")
    func rowsOpenWithTeam() {
        let oxphos = team("t1", "Bench Lab")
        let model = DocSharing.model(
            status: status(),
            teams: [oxphos],
            teamsHoldingCopy: [oxphos],
            identity: DocSharing.Identity(displayName: nil, email: "info@foreverlm.com"),
            showsTeams: true
        )
        #expect(model.rows == [
            .anyoneWithLink(canRead: true),
            .team(DocSharing.Team(id: "t1", name: "Bench Lab", permission: .readWrite, holdsCopy: true)),
            .author(name: "info@foreverlm.com", email: "info@foreverlm.com"),
        ])
        #expect(model.isOpen)
        #expect(model.url?.absoluteString == "https://foreverlm.com/share/abcdefghjkmn")
        #expect(model.summary == "Anyone with the link can open this page · shared with Bench Lab")
    }

    @Test("A restricted page lists each reader between the teams and the author; team rows hide in a team library")
    func rowsRestricted() {
        let model = DocSharing.model(
            status: status(readers: ["ana@example.org", "bo@example.org"]),
            teams: [team("t1", "Bench Lab")],
            teamsHoldingCopy: [],
            identity: DocSharing.Identity(displayName: nil, email: nil),
            showsTeams: false
        )
        #expect(model.rows == [
            .anyoneWithLink(canRead: false),
            .reader("ana@example.org"),
            .reader("bo@example.org"),
            .author(name: "You", email: nil),
        ])
        #expect(model.readers == ["ana@example.org", "bo@example.org"])
        #expect(model.summary == "Only the 2 people listed can open this page")
        #expect(model.rows.map(\.id) == ["link", "reader:ana@example.org", "reader:bo@example.org", "author"])
    }

    @Test("The account's address comes from the roster row that is this account")
    func identityFromRosters() {
        let rosters = [
            [member("Ana", email: "ana@example.org")],
            [member("Milo", email: " Info@ForeverLM.com ", isCurrentUser: true)],
        ]
        #expect(DocSharing.identity(displayName: "Milo", rosters: rosters) == DocSharing.Identity(displayName: "Milo", email: "info@foreverlm.com"))
        #expect(DocSharing.identity(displayName: nil, rosters: [[member("Ana", email: nil, isCurrentUser: true)]]) == DocSharing.Identity(displayName: nil, email: nil))
    }

    // MARK: - The one sentence

    @Test("One sentence per state, with the teams holding a copy appended")
    func summarySentences() {
        #expect(DocSharing.summary(status: nil, teamNames: []) == "Only you can open this Page")
        #expect(DocSharing.summary(status: status(), teamNames: []) == "Anyone with the link can open this page")
        #expect(DocSharing.summary(status: status(readers: ["ana@example.org"]), teamNames: []) == "Only the person listed can open this page")
        #expect(DocSharing.summary(status: status(readers: ["a@x.org", "b@x.org", "c@x.org"]), teamNames: []) == "Only the 3 people listed can open this page")
        #expect(DocSharing.summary(status: status(password: "hunter2"), teamNames: []) == "Only people with its old password can open this page")
        #expect(DocSharing.summary(status: status(isProtected: true), teamNames: []) == "Nobody but you can open this page")
        #expect(DocSharing.summary(status: nil, teamNames: ["Bench Lab"]) == "Only you can open this Page · shared with Bench Lab")
        #expect(DocSharing.summary(status: status(), teamNames: ["Bench Lab", "Acme Lab"]) == "Anyone with the link can open this page · shared with 2 teams")
    }

    // MARK: - What a change sends

    @Test("Invite publishes a new page for those people, closes an open link to them, and grows a list")
    func inviting() {
        #expect(DocSharing.access(inviting: ["ana@example.org"], to: nil) == .readers(["ana@example.org"]))
        #expect(DocSharing.access(inviting: ["ana@example.org"], to: status()) == .readers(["ana@example.org"]))
        #expect(DocSharing.access(inviting: ["bo@example.org", "ana@example.org"], to: status(readers: ["ana@example.org"]))
                == .readers(["ana@example.org", "bo@example.org"]))
        // Nothing to send: nobody typed, or everyone typed is already on the list.
        #expect(DocSharing.access(inviting: [], to: nil) == nil)
        #expect(DocSharing.access(inviting: ["ana@example.org"], to: status(readers: ["ana@example.org"])) == nil)
        // The site's ceiling holds here too.
        let crowd = (0..<DocPublishing.maxReaders).map { "r\($0)@example.org" }
        #expect(DocSharing.access(inviting: ["one-more@example.org"], to: status(readers: crowd)) == nil)
    }

    @Test("A team given the page admits its accepted members only while the page is shared with specific people")
    func admittingTeamMembers() {
        let members = [
            member("Ana", email: "Ana@Example.org"),
            member("Bo", email: "bo@example.org", accepted: false),
            member("Cy", email: nil),
            member("Milo", email: "info@foreverlm.com", isCurrentUser: true),
        ]
        #expect(DocSharing.access(admitting: members, to: status(readers: ["di@example.org"]))
                == .readers(["di@example.org", "ana@example.org", "info@foreverlm.com"]))
        // An open page already admits them; an unpublished Doc has no page.
        #expect(DocSharing.access(admitting: members, to: status()) == nil)
        #expect(DocSharing.access(admitting: members, to: nil) == nil)
        // Everyone already listed: nothing to send.
        #expect(DocSharing.access(admitting: members, to: status(readers: ["ana@example.org", "info@foreverlm.com"])) == nil)
    }

    @Test("Removing a reader shortens the list; the last reader stays, because an empty list is an open page")
    func removing() {
        let two = status(readers: ["ana@example.org", "bo@example.org"])
        #expect(DocSharing.canRemove("ana@example.org", from: two))
        #expect(DocSharing.access(removing: "ana@example.org", from: two) == .readers(["bo@example.org"]))
        let one = status(readers: ["ana@example.org"])
        #expect(!DocSharing.canRemove("ana@example.org", from: one))
        #expect(DocSharing.access(removing: "ana@example.org", from: one) == nil)
        #expect(!DocSharing.canRemove("nobody@example.org", from: two))
    }

    @Test("The link row opens the page, and closes it again to the readers it had; with nobody to keep it closed for, it cannot close")
    func linkRow() {
        #expect(DocSharing.accessOpeningLink() == .open)
        #expect(DocSharing.access(closingLinkKeeping: ["ana@example.org"]) == .readers(["ana@example.org"]))
        #expect(DocSharing.access(closingLinkKeeping: []) == nil)
    }
}

/// `list_docs` says the popover's sentence as `published_access_summary`.
@Suite("Doc sharing over MCP")
struct DocSharingMCPTests {
    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc_sharing_mcp_test_\(UUID().uuidString)")
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
}
