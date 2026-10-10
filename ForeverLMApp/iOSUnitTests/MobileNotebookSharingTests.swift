import Foundation
import XCTest
@testable import ForeverLM

/// The rules behind a notebook's Share on the phone: how a team holding the
/// notebook is found (the Mac's copy id and record name), who has it, how
/// Copy Invitation Link gets its link, and the gateway request that asks the
/// Mac (Route A) with what its answers mean.
final class MobileNotebookSharingTests: XCTestCase {
    private let teamID = "5d2c9a3e-0f1b-4c6d-8e7f-a1b2c3d4e5f6"
    private let notebookID = "A1B2C3D4-0000-4000-8000-000000000001"
    /// `TeamContentIdentity.notebookID(teamID:originalNotebookID:)` on the Mac,
    /// run on these two ids; the web's library-sharing.test.ts pins it too.
    private let copyID = "proj_0e881635644334380c69d3485a044ad7d861c958e816773fdb85f719d0edc76e"

    func testATeamsCopyHasTheMacsIdAndRecordName() {
        XCTAssertEqual(MobileNotebookTeams.copyNotebookID(teamID: teamID, notebookID: notebookID), copyID)
        // `CloudKitRecordMapper.recordName(for: .learningGoal, logicalKey:)`.
        XCTAssertEqual(
            MobileNotebookTeams.learningGoalRecordName(notebookID: copyID),
            "89ab569316324c039b86fedcf302631af8a23a24de157efc29969309f1ee8311"
        )
        XCTAssertEqual(MobileNotebookTeams.teamID(fromZoneName: "Team-\(teamID)"), teamID)
        XCTAssertNil(MobileNotebookTeams.teamID(fromZoneName: "Team-"))
        XCTAssertNil(MobileNotebookTeams.teamID(fromZoneName: "Knowledge"))
    }

    func testWhoHasItIsTheMacsRoster() {
        typealias Person = MobileNotebookShareMember.Person
        let members = MobileNotebookShareMember.roster([
            Person(userRecordName: "_zara", name: "Zara Ng", email: "zara@example.org", isOwner: false, canWrite: false, isPending: false, isRemoved: false, isCurrentUser: false),
            Person(userRecordName: "_bob", name: "", email: "bob@example.org", isOwner: false, canWrite: true, isPending: true, isRemoved: false, isCurrentUser: false),
            Person(userRecordName: "_gone", name: "Gone", email: nil, isOwner: false, canWrite: true, isPending: false, isRemoved: true, isCurrentUser: false),
            Person(userRecordName: "_me", name: "", email: nil, isOwner: true, canWrite: true, isPending: false, isRemoved: false, isCurrentUser: true),
        ])
        XCTAssertEqual(members.map(\.name), ["You", "bob@example.org", "Zara Ng"])
        XCTAssertEqual(members.map(\.standing.title), ["Owner", "Read and write", "Read only"])
        XCTAssertEqual(members.map(\.isInvited), [false, true, false])
        XCTAssertEqual(members.map(\.isYou), [true, false, false])
        XCTAssertEqual(members.map(\.email), [nil, nil, "zara@example.org"])
    }

    func testCopyInvitationLinkFollowsTheMac() throws {
        let link = try XCTUnwrap(URL(string: "https://www.icloud.com/share/0a1B2c3D4e5F6g7H8i9J0kLmN"))
        func team(_ role: MobileNotebookTeam.Role, canWrite: Bool = true, link: URL?, open: Bool) -> MobileNotebookTeam {
            MobileNotebookTeam(id: teamID, name: "🧬 Mito", role: role, canWrite: canWrite, link: link, opensToAnyone: open, members: [])
        }
        // A read-only member cannot invite.
        XCTAssertEqual(MobileInvitationPlan.plan(for: team(.member, canWrite: false, link: link, open: true)), .none)
        // A member copies the link as it stands.
        XCTAssertEqual(MobileInvitationPlan.plan(for: team(.member, link: link, open: false)), .copy(link, opensToAnyone: false))
        // The owner's link is copied here only once anyone with it can join.
        XCTAssertEqual(MobileInvitationPlan.plan(for: team(.owner, link: link, open: true)), .copy(link, opensToAnyone: true))
        XCTAssertEqual(MobileInvitationPlan.plan(for: team(.owner, link: link, open: false)), .askMac(teamID: teamID))
        // No link yet: the Mac's.
        XCTAssertEqual(MobileInvitationPlan.plan(for: team(.member, link: nil, open: false)), .askMac(teamID: teamID))
    }

    func testRouteAAsksShareNotebookWithTheNotebookTheTeamAndTheAffirmation() throws {
        let call = MobileMacRelay.shareNotebookRequest(token: "v1.session", iCloudUser: "_abc123", notebookID: notebookID, teamID: nil)
        XCTAssertEqual(call.url?.absoluteString, "https://plugin.foreverlm.com/web/call")
        XCTAssertEqual(call.httpMethod, "POST")
        XCTAssertEqual(call.value(forHTTPHeaderField: "Authorization"), "Bearer v1.session")
        XCTAssertEqual(call.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(call.httpBody)) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "share_notebook")
        XCTAssertEqual(body["icloud_user"] as? String, "_abc123")
        XCTAssertEqual(body["icloud_environment"] as? String, "production")
        let arguments = try XCTUnwrap(body["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["notebook_id"] as? String, notebookID)
        XCTAssertEqual(arguments["rights_affirmed_by_learner"] as? Bool, true)
        XCTAssertNil(arguments["team_id"])

        let intoTeam = MobileMacRelay.shareNotebookRequest(token: "v1.session", iCloudUser: "_abc123", notebookID: notebookID, teamID: teamID)
        let teamBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(intoTeam.httpBody)) as? [String: Any])
        XCTAssertEqual((teamBody["arguments"] as? [String: Any])?["team_id"] as? String, teamID)

        let status = MobileMacRelay.statusRequest(token: "v1.session", iCloudUser: "_abc123")
        XCTAssertEqual(status.url?.absoluteString, "https://plugin.foreverlm.com/web/desktop")
        XCTAssertEqual(status.httpMethod, "GET")
        XCTAssertEqual(status.value(forHTTPHeaderField: "X-ForeverLM-iCloud-User"), "_abc123")
        XCTAssertEqual(status.value(forHTTPHeaderField: "X-ForeverLM-iCloud-Environment"), "production")
    }

    func testTheGatewaysAnswersReadAsOneLine() {
        func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
        XCTAssertEqual(MobileMacRelay.availability(status: 200, body: json(["reachable": true, "account": "match", "tools": []])), .online)
        XCTAssertEqual(
            MobileMacRelay.availability(status: 200, body: json(["reachable": false, "reason": "offline", "message": "x"])),
            .unavailable("Open ForeverLM on your Mac to share this notebook.")
        )
        XCTAssertEqual(
            MobileMacRelay.availability(status: 200, body: json(["reachable": true, "account": "account_mismatch", "message": "x"])),
            .unavailable("Your Mac uses a different iCloud account from this iPhone.")
        )
        XCTAssertEqual(MobileMacRelay.availability(status: 401, body: Data()), .signedOut)
        XCTAssertEqual(MobileMacRelay.availability(status: 502, body: Data()), .unavailable("Open ForeverLM on your Mac to share this notebook."))

        XCTAssertEqual(MobileMacRelay.callResult(status: 200, body: json(["name": "share_notebook", "is_error": false, "text": "{}"])), .answered("{}"))
        XCTAssertEqual(
            MobileMacRelay.callResult(status: 200, body: json(["is_error": true, "text": "Unknown tool: share_notebook"])),
            .refused("Your Mac's ForeverLM can't do this yet.")
        )
        // The Mac's refusals a learner can meet here, in their words; any
        // other is the Mac's own text without its "Error:".
        let refusals: [(String, String)] = [
            ("Error: No Notebook with id proj-x. Use list_notebooks.", "Your Mac doesn't have this notebook yet. Try again once it has synced."),
            ("Error: No team with id team-x on this Mac. Use list_teams.", "Your Mac doesn't have this team yet. Try again once it has synced."),
            ("Error: ‘🧬 Mito’ is in 2 teams: ‘Lab’ (team_id a), ‘Mito’ (team_id b). Pass team_id to say which team to invite people to.", "This notebook is in more than one team. Choose the team in ForeverLM on your Mac."),
            ("Error: Team ‘Theirs’ is read-only for this account, so you cannot invite people to it. Its owner, Ada Lovelace, gave this member read access only; ask them to change the permission in the team's sharing settings.", "Only the team's owner can invite people to it."),
            ("Error: Something else went wrong.", "Something else went wrong."),
            ("Error: ", "Your Mac could not share this notebook."),
        ]
        for (said, line) in refusals {
            XCTAssertEqual(MobileMacRelay.callResult(status: 200, body: json(["is_error": true, "text": said])), .refused(line), said)
        }
        XCTAssertEqual(MobileMacRelay.callResult(status: 503, body: json(["error": "mac_offline"])), .refused("Open ForeverLM on your Mac to share this notebook."))
        XCTAssertEqual(MobileMacRelay.callResult(status: 403, body: json(["error": "tool_not_allowed"])), .refused("Share this notebook from ForeverLM on your Mac."))
        XCTAssertEqual(MobileMacRelay.callResult(status: 409, body: json(["error": "account_pending"])), .refused("Your Mac has not heard back from iCloud yet. Try again in a moment."))
        XCTAssertEqual(MobileMacRelay.callResult(status: 401, body: Data()), .refused("Sign in with Apple again to reach your Mac."))
    }

    func testTheMacsAnswerGivesTheLinkAndWhoHasIt() throws {
        let text = """
        {"team_id":"\(teamID)","team_name":"🧬 Mito","created_team":true,"shared_sources":43,"invitation_link":"https://www.icloud.com/share/0a1B2c3D4e5F6g7H8i9J0kLmN","members":[{"name":"Alan Young","email":"alan@example.org","role":"owner","accepted":true},{"name":"","email":"ana@example.org","role":"viewer","accepted":false}]}
        """
        let answer = try XCTUnwrap(MobileShareNotebookAnswer(text: text))
        XCTAssertEqual(answer.teamID, teamID)
        XCTAssertEqual(answer.teamName, "🧬 Mito")
        XCTAssertTrue(answer.createdTeam)
        XCTAssertEqual(answer.sharedSources, 43)
        XCTAssertEqual(answer.invitationLink?.absoluteString, "https://www.icloud.com/share/0a1B2c3D4e5F6g7H8i9J0kLmN")
        XCTAssertFalse(answer.linkOpensToAnyone, "only the Mac's word says the link opens the team to anyone")
        XCTAssertEqual(answer.members.map(\.name), ["Alan Young", "ana@example.org"])
        XCTAssertEqual(answer.members.map(\.standing), [.owner, .readOnly])
        XCTAssertEqual(answer.members.map(\.isInvited), [false, true])
        XCTAssertNil(MobileShareNotebookAnswer(text: #"Before sharing, ask the learner: "Do you have the rights …?""#))
        XCTAssertNil(MobileShareNotebookAnswer(text: #"{"invitation_link":"https://www.icloud.com/share/0a1B2c3D4e5F6g7H8i9J0kLmN"}"#), "no team, no answer")
        XCTAssertNil(MobileShareNotebookAnswer(text: "{"))
    }

    /// share_notebook's answers as the Mac writes them (MCPTools+Teams,
    /// pretty JSON with sorted keys; MCPTeamsToolsTests pins both shapes,
    /// and library-sharing.test.ts reads the same bytes): before iCloud has
    /// shared the team, and with the owner's link.
    static let macAnswerNoLinkYet = """
        {
          "created_team" : true,
          "invitation_link" : null,
          "link_opens_to_anyone" : false,
          "members" : [

          ],
          "message" : "Made the team ‘🧬 Mito’ and shared ‘🧬 Mito’ into it with its 2 sources; what is filed in the notebook from now on follows it into the team. There is no invitation link yet (The invitation link for 🧬 Mito could not be read from iCloud.); it appears once iCloud has shared the team, so call share_notebook again in a moment.",
          "shared_sources" : 2,
          "team_id" : "5d2c9a3e-0f1b-4c6d-8e7f-a1b2c3d4e5f6",
          "team_name" : "🧬 Mito",
          "team_notebook_id" : "proj_0e881635644334380c69d3485a044ad7d861c958e816773fdb85f719d0edc76e"
        }
        """
    static let macAnswerOwnersLink = """
        {
          "created_team" : false,
          "invitation_link" : "https:\\/\\/www.icloud.com\\/share\\/0a1B2c3D4e5F6g7H8i9J0kLmN",
          "link_opens_to_anyone" : true,
          "members" : [
            {
              "accepted" : true,
              "email" : null,
              "name" : "Alan Young",
              "role" : "owner"
            }
          ],
          "message" : "‘🧬 Mito’ is in the team ‘🧬 Mito’, with 2 sources. Anyone with invitation_link can join the team and edit its library: give it to the learner to pass on.",
          "shared_sources" : 2,
          "team_id" : "5d2c9a3e-0f1b-4c6d-8e7f-a1b2c3d4e5f6",
          "team_name" : "🧬 Mito",
          "team_notebook_id" : "proj_0e881635644334380c69d3485a044ad7d861c958e816773fdb85f719d0edc76e"
        }
        """

    func testTheMacsAnswerWithNoLinkYetIsStillItsAnswer() throws {
        let pending = try XCTUnwrap(MobileShareNotebookAnswer(text: Self.macAnswerNoLinkYet))
        XCTAssertEqual(pending.teamID, teamID)
        XCTAssertEqual(pending.teamName, "🧬 Mito")
        XCTAssertTrue(pending.createdTeam)
        XCTAssertEqual(pending.sharedSources, 2)
        XCTAssertNil(pending.invitationLink)
        XCTAssertFalse(pending.linkOpensToAnyone)
        XCTAssertTrue(pending.members.isEmpty)

        let linked = try XCTUnwrap(MobileShareNotebookAnswer(text: Self.macAnswerOwnersLink))
        XCTAssertEqual(linked.invitationLink?.absoluteString, "https://www.icloud.com/share/0a1B2c3D4e5F6g7H8i9J0kLmN")
        XCTAssertTrue(linked.linkOpensToAnyone)
        XCTAssertEqual(linked.members.map(\.standing), [.owner])
    }

    /// The Mac's own words (`NotebookShareLine`, compiled into the phone),
    /// which the web says too.
    func testTheLineSaysWhatIsSharedAndTheTitleNamesTheNotebook() {
        XCTAssertEqual(NotebookShareLine.text(sourceCount: 43), "Shares the notebook and its 43 sources")
        XCTAssertEqual(NotebookShareLine.text(sourceCount: 1), "Shares the notebook and its source")
        XCTAssertEqual(NotebookShareLine.text(sourceCount: 0), "Shares the notebook")
        XCTAssertEqual(NotebookShareLine.title(notebookTitle: "🧬 Mito"), "Share 🧬 Mito")
        XCTAssertEqual(NotebookShareLine.title(notebookTitle: ""), "Share Notebook")
    }
}
