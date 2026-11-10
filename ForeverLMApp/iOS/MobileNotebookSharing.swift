import Foundation

// MARK: - Asking the Mac

/// The phone's way to the learner's Mac: the gateway's `POST /web/call` (one
/// tool call), which the web reaches through its Pages function. It
/// authenticates the managed session as its bearer, the phone's own as much
/// as a page's, and relays only to a Mac that syncs with the iCloud account
/// the caller names: the phone's CloudKit user record name, always in
/// Production (the iPhone's entitlements ask for no other environment).
enum MobileMacRelay {
    static let gateway = URL(string: "https://plugin.foreverlm.com")!
    static let environment = "production"
    /// Longer than the relay's own minute, so its "still working" answer
    /// arrives rather than a timeout.
    static let timeout: TimeInterval = 90

    /// Any one tool the gateway's `/web/call` lets through, with its
    /// arguments (voice mode's reach, `MobileVoiceMac`).
    static func toolRequest(token: String, iCloudUser: String, name: String, arguments: [String: Any], timeout: TimeInterval = timeout) -> URLRequest {
        let body: [String: Any] = [
            "name": name,
            "arguments": arguments,
            "icloud_user": iCloudUser,
            "icloud_environment": environment,
        ]
        var request = URLRequest(url: gateway.appendingPathComponent("web/call"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// What `POST /web/call` answered: the Mac's text, or why nothing was
    /// asked of it, as the line the sheet shows.
    enum CallResult: Equatable, Sendable {
        case answered(String)
        case refused(String)
    }

    static func callResult(status: Int, body: Data) -> CallResult {
        let payload = object(body)
        if status == 200, let payload, let text = payload["text"] as? String {
            guard payload["is_error"] as? Bool == true else { return .answered(text) }
            return .refused(refusal(text))
        }
        if status == 401 { return .refused(MacLine.signedOut) }
        switch payload?["error"] as? String {
        case "mac_offline": return .refused(MacLine.offline)
        case "mac_busy": return .refused(MacLine.busy)
        case "mac_still_working": return .refused("Your Mac is still sharing it. Open Share again in a moment.")
        case "tool_not_allowed": return .refused("Share this notebook from ForeverLM on your Mac.")
        case let account? where status == 409: return .refused(MacLine.account(account))
        default: return .refused("ForeverLM could not reach your Mac.")
        }
    }

    /// A refusal from the Mac's `share_notebook`, written for an assistant,
    /// in the learner's words where one can meet it here: the notebook or
    /// the team has not reached the Mac yet, the notebook is in several
    /// teams, the team is read-only, or the Mac predates the tool (it says
    /// "Unknown tool"). Anything else is the Mac's text without its
    /// "Error:". The web's `shareNotebookRefusal` reads them the same.
    static func refusal(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = trimmed.replacingOccurrences(of: #"^Error:\s*"#, with: "", options: .regularExpression)
        func says(_ pattern: String) -> Bool {
            said.range(of: pattern, options: .regularExpression) != nil
        }
        if says(#"^Unknown tool\b"#) { return "Your Mac's ForeverLM can't do this yet." }
        if says(#"^No Notebook with id\b"#) { return "Your Mac doesn't have this notebook yet. Try again once it has synced." }
        if says(#"^No team with id\b"#) { return "Your Mac doesn't have this team yet. Try again once it has synced." }
        if says(#"\bis in \d+ teams\b"#) { return "This notebook is in more than one team. Choose the team in ForeverLM on your Mac." }
        if says(#"\bis read-only for this account\b"#) { return "Only the team's owner can invite people to it." }
        return said.isEmpty ? "Your Mac could not share this notebook." : said
    }

    /// The sheet's one line for a Mac that cannot be asked.
    enum MacLine {
        static let offline = "Open ForeverLM on your Mac to share this notebook."
        static let busy = "Your Mac did not answer in time. Try again in a moment."
        static let signedOut = "Sign in with Apple again to reach your Mac."

        static func account(_ error: String?) -> String {
            switch error {
            case "account_mismatch": return "Your Mac uses a different iCloud account from this iPhone."
            case "mac_not_in_icloud": return "ForeverLM on your Mac is not syncing with iCloud."
            case "account_pending": return "Your Mac has not heard back from iCloud yet. Try again in a moment."
            default: return "Update ForeverLM on your Mac to share from here."
            }
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
