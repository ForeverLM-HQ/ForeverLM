import CryptoKit
import Foundation

// MARK: - Share on the phone
//
// A notebook's Share on the iPhone (docs/web-macos-parity.md, "Share"): who
// has it in each team holding it, and Copy Invitation Link. The phone has no
// team pipeline of its own, and gets none: a notebook already in a team gives
// the link its team's CKShare carries, read from iCloud; a notebook in no team
// is shared by the learner's Mac (`share_notebook`, the Mac's tool), asked
// through the gateway's route for the web (Route A) on the phone's own managed
// session. Before the first link the learner affirms their rights to share,
// once on every client: the Mac's own `SharingRightsAffirmation`, compiled
// into the phone, gives the row's key, value, version and words. These are
// the rules, Foundation-only so they are tested. That sheet was generation 1's
// and is gone with the old Apple team's container; a notebook is shared by
// moving it into a space (`MobileSpaceShareSheet`). The team rules stay
// dormant until WP30, and `MobileMacRelay` is what the phone's search asks.

// MARK: Teams holding a notebook

/// How the phone finds a notebook in a team without a team library of its
/// own: a team is the zone `Team-<id>`, and a team's copy of a notebook has
/// the id the Mac gives it (`TeamContentIdentity.notebookID`), under the
/// record name every `LearningGoal` has
/// (`CloudKitRecordMapper.recordName(for: .learningGoal, ...)`). So whether
/// a team holds the notebook is one record asked for by name in its zone.
enum MobileNotebookTeams {
    static let zoneNamePrefix = "Team-"

    static func teamID(fromZoneName zoneName: String) -> String? {
        guard zoneName.hasPrefix(zoneNamePrefix) else { return nil }
        let id = String(zoneName.dropFirst(zoneNamePrefix.count))
        return id.isEmpty ? nil : id
    }

    static func copyNotebookID(teamID: String, notebookID: String) -> String {
        // Keeps the word the Mac hashes with (`TeamContentIdentity`).
        "proj_" + hex("team:\(teamID):project:\(notebookID)")
    }

    static func learningGoalRecordName(notebookID: String) -> String {
        hex("learningGoal:\(notebookID)")
    }

    private static func hex(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One person on a team's share, as the Mac's roster draws them
/// (`TeamMemberRow`): a name, an email under it, Owner, Read and write or
/// Read only, and Invited until they accept.
struct MobileNotebookShareMember: Identifiable, Equatable, Sendable {
    enum Standing: String, Sendable {
        case owner
        case readWrite
        case readOnly

        var title: String {
            switch self {
            case .owner: return "Owner"
            case .readWrite: return "Read and write"
            case .readOnly: return "Read only"
            }
        }
    }

    /// A participant as the share holds them, without CloudKit's types.
    struct Person: Equatable, Sendable {
        var userRecordName: String?
        /// Their name as the share gives it, formatted; empty when it gives none.
        var name: String
        var email: String?
        var isOwner: Bool
        var canWrite: Bool
        var isPending: Bool
        var isRemoved: Bool
        var isCurrentUser: Bool
    }

    let id: String
    let name: String
    let email: String?
    let standing: Standing
    let isInvited: Bool
    let isYou: Bool

    var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// Who has it: the owner first, then by name; someone removed no longer
    /// has it. A name the share does not give is the email, else "You" or
    /// "Member" (the Mac's `memberDisplayName`).
    static func roster(_ people: [Person]) -> [MobileNotebookShareMember] {
        people.filter { !$0.isRemoved }.enumerated().map { index, person in
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let shown = name.nilIfEmpty ?? email ?? (person.isCurrentUser ? "You" : "Member")
            return MobileNotebookShareMember(
                id: person.userRecordName ?? email ?? "person-\(index)",
                name: shown,
                email: email == shown ? nil : email,
                standing: person.isOwner ? .owner : (person.canWrite ? .readWrite : .readOnly),
                isInvited: person.isPending,
                isYou: person.isCurrentUser
            )
        }
        .sorted(by: ownerFirst)
    }

    /// The people `share_notebook` answers with (`role` owner, editor or
    /// viewer; `accepted`), read the same way.
    static func answered(_ members: [[String: Any]]) -> [MobileNotebookShareMember] {
        members.enumerated().map { index, member in
            let email = (member["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let name = (member["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? email ?? "Member"
            let role = member["role"] as? String
            return MobileNotebookShareMember(
                id: "answered-\(index)",
                name: name,
                email: email == name ? nil : email,
                standing: role == "owner" ? .owner : (role == "editor" ? .readWrite : .readOnly),
                isInvited: (member["accepted"] as? Bool) == false,
                isYou: false
            )
        }
        .sorted(by: ownerFirst)
    }

    private static func ownerFirst(_ left: MobileNotebookShareMember, _ right: MobileNotebookShareMember) -> Bool {
        if (left.standing == .owner) != (right.standing == .owner) { return left.standing == .owner }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}

/// A team holding the notebook, read from its zone and its share.
struct MobileNotebookTeam: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        /// Made the team: its zone is in this account's private database.
        case owner
        /// Joined it: the zone arrives through the shared database.
        case member
    }

    let id: String
    let name: String
    let role: Role
    /// What this account may do in it.
    let canWrite: Bool
    /// The share's invitation link (`CKShare.url`), once iCloud has one.
    let link: URL?
    /// Whether the share admits anyone with the link at read and write.
    let opensToAnyone: Bool
    let members: [MobileNotebookShareMember]
}

/// How Copy Invitation Link gets a link, the Mac's rule
/// (`TeamSharingService.copyInvitationLink`): a read-only member cannot
/// invite; a member copies the link as it stands; the owner's link means
/// anyone with it can join and edit, so it is copied here only when the
/// share already admits them; anything else is the Mac's to open and give
/// (`share_notebook` with the team). A notebook in no team is the Mac's.
enum MobileInvitationPlan: Equatable, Sendable {
    case none
    case copy(URL, opensToAnyone: Bool)
    case askMac(teamID: String?)

    static func plan(for team: MobileNotebookTeam) -> MobileInvitationPlan {
        guard team.canWrite else { return .none }
        if team.role == .member, let link = team.link { return .copy(link, opensToAnyone: false) }
        if team.role == .owner, let link = team.link, team.opensToAnyone { return .copy(link, opensToAnyone: true) }
        return .askMac(teamID: team.id)
    }
}

// MARK: Asking the Mac (Route A)

/// The phone's way to the learner's Mac: the gateway's `GET /web/desktop`
/// (whether the Mac can be asked) and `POST /web/call` (one tool call),
/// which the web reaches through its Pages function. Both authenticate the
/// managed session as their bearer, the phone's own as much as a page's, and
/// relay only to a Mac that syncs with the iCloud account the caller names:
/// the phone's CloudKit user record name, always in Production (the iPhone's
/// entitlements ask for no other environment).
enum MobileMacRelay {
    static let gateway = URL(string: "https://plugin.foreverlm.com")!
    static let environment = "production"
    static let accountHeader = "X-ForeverLM-iCloud-User"
    static let environmentHeader = "X-ForeverLM-iCloud-Environment"
    /// Longer than the relay's own minute, so its "still working" answer
    /// arrives rather than a timeout.
    static let timeout: TimeInterval = 90

    static func statusRequest(token: String, iCloudUser: String) -> URLRequest {
        var request = URLRequest(url: gateway.appendingPathComponent("web/desktop"), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(iCloudUser, forHTTPHeaderField: accountHeader)
        request.setValue(environment, forHTTPHeaderField: environmentHeader)
        return request
    }

    /// `share_notebook` with the notebook, its team when it has one, and the
    /// learner's affirmation, given on this phone first.
    static func shareNotebookRequest(token: String, iCloudUser: String, notebookID: String, teamID: String?) -> URLRequest {
        var arguments: [String: Any] = ["notebook_id": notebookID, "rights_affirmed_by_learner": true]
        if let teamID { arguments["team_id"] = teamID }
        let body: [String: Any] = [
            "name": "share_notebook",
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

    /// Whether the Mac can be asked, from `GET /web/desktop`'s answer.
    enum Availability: Equatable, Sendable {
        case online
        case signedOut
        /// The one line the sheet shows instead of asking.
        case unavailable(String)
    }

    static func availability(status: Int, body: Data) -> Availability {
        if status == 401 { return .signedOut }
        guard status == 200, let payload = object(body) else { return .unavailable(MacLine.offline) }
        if payload["reachable"] as? Bool == false {
            return .unavailable(payload["reason"] as? String == "busy" ? MacLine.busy : MacLine.offline)
        }
        let account = payload["account"] as? String
        return account == "match" ? .online : .unavailable(MacLine.account(account))
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
        static let unreachable = "ForeverLM could not reach your Mac. Check the connection and try again."
        static let noICloud = "iCloud could not be reached. Check the connection and try again."

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

/// What `share_notebook` answered: the team the notebook is in now, the link
/// and who has it; nil for anything that is not its JSON. The team was made
/// and the notebook shared even when there is no link yet
/// (`invitationLink` nil: iCloud has not shared the team, or opening its
/// share failed); `linkOpensToAnyone` is the Mac's word that the link lets
/// anyone who has it join and edit.
struct MobileShareNotebookAnswer: Equatable, Sendable {
    let teamID: String
    let teamName: String?
    let createdTeam: Bool
    let sharedSources: Int?
    let invitationLink: URL?
    let linkOpensToAnyone: Bool
    let members: [MobileNotebookShareMember]

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let teamID = (payload["team_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        self.teamID = teamID
        teamName = (payload["team_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        createdTeam = payload["created_team"] as? Bool == true
        sharedSources = (payload["shared_sources"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }
        let raw = (payload["invitation_link"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = raw.flatMap { URL(string: $0) }.flatMap { $0.scheme?.lowercased() == "https" && $0.host != nil ? $0 : nil }
        invitationLink = link
        // Only a JSON true, and only with a link.
        let opens = (payload["link_opens_to_anyone"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        linkOpensToAnyone = link != nil && opens
        members = MobileNotebookShareMember.answered(payload["members"] as? [[String: Any]] ?? [])
    }
}

/// The sheet's words that are the phone's own.
enum MobileNotebookShareWords {
    /// Under a link the Mac has not got yet; Copy Invitation Link stays to be
    /// pressed again, and asks about the team the Mac answered with.
    static let linkPending = "Your Mac shared it. Its link comes once iCloud has shared the team; try again in a moment."
    /// Under a copied link that lets anyone who has it join and edit.
    static let opensToAnyone = "Anyone with the link can join and edit."
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
