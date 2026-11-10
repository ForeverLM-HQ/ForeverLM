import Foundation
import XCTest
@testable import ForeverLM

/// The phone's way to the Mac (`MobileMacRelay`): what the gateway's answers
/// to a tool call mean, and the Mac's own words for what a notebook's Share says.
final class MobileNotebookSharingTests: XCTestCase {
    func testTheGatewaysAnswersReadAsOneLine() {
        func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
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
