import Foundation

// MARK: - Teams
//
// A Team is a second library that several people share. It lives in one
// CloudKit custom zone (`Team-<id>`) in the creator's private database and is
// shared zone-wide with the members, who receive it in their shared database.
// Nothing about a team touches a server ForeverLM runs: the roster is the
// CKShare's participant list, and the content is CloudKit records.
//
// Sharing copies. A source, Notebook, Doc or chat that a member shares with a
// team is duplicated into the team's namespace under a team-scoped identity;
// the member's own copy stays exactly where it was. Two members who share the
// same paper therefore produce one team record, and leaving a team never takes
// anything out of anyone's own library. See docs/teams-design.md.

enum TeamRole: String, Codable, Sendable, Equatable {
    /// Created the team; the zone lives in this account's private database.
    case owner
    /// Accepted an invitation; the zone arrives through the shared database.
    case member
}

enum TeamPermission: String, Codable, Sendable, Equatable {
    case readOnly
    case readWrite
}

struct TeamRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var role: TeamRole
    var permission: TeamPermission
    /// `private` on the owner's devices, `shared` on a member's.
    var zoneScope: CloudKitZoneHome.Scope
    var zoneName: String
    /// The owner's CloudKit user record name as seen by a member; nil on the
    /// owner's own devices, where the zone belongs to the current user.
    var zoneOwnerRecordName: String?
    var shareRecordName: String?
    /// The share's invitation link once CloudKit has minted one.
    var shareURL: String?
    var createdAt: Date
    var joinedAt: Date
    var updatedAt: Date
    /// Set while the owner's plan covers the team as a family: the code each
    /// member's Mac presents to the proxy to join it (`/v1/family/join`). It
    /// travels in the team's own record, so only the team's members see it,
    /// and the owner renewing or clearing it ends what the old one opened.
    /// docs/family-design.md.
    var familyPlanCode: String? = nil

    static let zoneNamePrefix = "Team-"

    static func zoneName(forTeamID teamID: String) -> String {
        zoneNamePrefix + teamID
    }

    /// The team id a zone name carries, or nil for any other zone.
    static func teamID(fromZoneName zoneName: String) -> String? {
        guard zoneName.hasPrefix(zoneNamePrefix) else { return nil }
        let id = String(zoneName.dropFirst(zoneNamePrefix.count))
        return id.isEmpty ? nil : id
    }

    var home: CloudKitZoneHome {
        CloudKitZoneHome(scope: zoneScope, zoneName: zoneName, ownerRecordName: zoneOwnerRecordName)
    }

    var canEdit: Bool { permission == .readWrite }

    /// Whether the owner's plan pays for this team's members.
    var isFamily: Bool { familyPlanCode != nil }
}

/// One participant of a team, projected from the CKShare so the app can show
/// a roster and assign tasks without a network round trip. Refreshed whenever
/// the share record arrives or the owner manages members.
struct TeamMemberRecord: Identifiable, Codable, Equatable, Sendable {
    /// The participant's CloudKit user record name — stable per account and
    /// the value a task's assignee carries.
    let userRecordName: String
    let teamID: String
    var displayName: String
    var email: String?
    var role: TeamRole
    var permission: TeamPermission
    var acceptanceStatus: String
    var isCurrentUser: Bool
    var updatedAt: Date

    var id: String { teamID + ":" + userRecordName }

    var initials: String { Self.initials(for: displayName) }

    /// The same initials for a name kept on a task after its member left the
    /// roster, so an assignee avatar never changes shape with the roster.
    static func initials(for displayName: String) -> String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }
        if letters.isEmpty { return "?" }
        return letters.joined()
    }
}

// MARK: - Team-scoped identities

/// Deterministic identities for the copies a team holds. Two members sharing
/// the same thing must land on the same team record, and sharing the same
/// item twice must update rather than duplicate, so every copy's id is a
/// function of the team and of what it copies — never of who shared it.
enum TeamContentIdentity {
    /// A team's copy of a web-addressed source. Same shape as
    /// `SourceIdentity.stableID(for:)` with the team folded into the key, so a
    /// paper two members both share is one team record and the `src_` prefix
    /// every consumer keys on is preserved.
    static func sourceID(teamID: String, url: String) -> String {
        let key = "source:v1:team:\(teamID):\(URLNormalizer.normalize(url))"
        return "src_" + hex(key)
    }

    static func notebookID(teamID: String, originalNotebookID: String) -> String {
        // The hash input keeps the word it was first written with: the id is
        // derived, so changing it would give every team copy a new id.
        "proj_" + hex("team:\(teamID):project:\(originalNotebookID)")
    }

    static func artifactID(teamID: String, originalArtifactID: String) -> String {
        "doc_" + hex("team:\(teamID):doc:\(originalArtifactID)")
    }

    /// A team's copy of a linked page — a ForeverLM site, a Claude artifact,
    /// a Codex site, a Google Doc. Keyed by the page's address rather than
    /// the record's id: a site rebuilt under the same address gets a new
    /// record each time (three "Mitochondrial Therapeutics Atlas" copies, one
    /// per rebuild), so the id has to name the page, not the
    /// row that happened to point at it. Same normalization as `sourceID`.
    static func linkedPageArtifactID(teamID: String, url: String) -> String {
        "doc_" + hex("team:\(teamID):page:\(URLNormalizer.normalize(url))")
    }

    /// The id a team's copy of `original` takes: by address for a linked
    /// page, by record id for a Markdown Doc. Every reader of a team copy —
    /// the share, "who holds this", the open-in-team route — asks here.
    static func artifactCopyID(teamID: String, original: ArtifactRecord) -> String {
        if let url = original.linkedURL {
            return linkedPageArtifactID(teamID: teamID, url: url)
        }
        return artifactID(teamID: teamID, originalArtifactID: original.id)
    }

    /// A member's private draft of a team Doc (docs/teams-design.md, decision
    /// 11). It lives in the member's own library, hidden from its Docs list,
    /// and publishes back over the team copy. The id names the team copy it
    /// drafts, not its author: every member's draft has the same id, and their
    /// libraries never meet. The prefix is what hides drafts from My Library
    /// without a lookup.
    static func draftArtifactID(teamID: String, teamArtifactID: String) -> String {
        "draft_" + hex("team:\(teamID):draft:\(teamArtifactID)")
    }

    /// The Notebook a team's assignments live in (docs/family-design.md). One
    /// per team, the same id on every device, so two Macs of the same parent
    /// assigning at once make one Notebook rather than two.
    static func assignmentsNotebookID(teamID: String) -> String {
        "proj_" + hex("team:\(teamID):assignments")
    }

    /// The Notebook the learner's own Board lives in (docs-site/board.md): a
    /// Board card is an ordinary Notebook task, so the Board is one Notebook
    /// whose tasks it draws as columns. The same id on every device, so two
    /// Macs opening the Board at once make one Notebook, not two. Not a
    /// team's: a team's tasks stay on the Notebook they belong to.
    static let personalBoardNotebookID = "proj_" + hex("personal:board:v1")

    /// The notebook "Make Study Notebook" makes for a course
    /// (`KnowledgeStore.makeStudyNotebook`). Not a team copy, but the same
    /// need as the Assignments Notebook: two Macs asking at once make one
    /// notebook, not two. A team's course id is
    /// already the team's, so its notebook's id is too.
    static func courseNotebookID(courseID: String) -> String {
        "proj_" + hex("course-home:v1:\(courseID)")
    }

    static func isDraftArtifactID(_ artifactID: String) -> Bool {
        artifactID.hasPrefix("draft_")
    }

    /// A team's copy of a course (docs/teams-design.md, decision 21).
    static func courseID(teamID: String, originalCourseID: String) -> String {
        "course_" + hex("team:\(teamID):course:\(originalCourseID)")
    }

    /// One part of a team's course copy — a lecture, a lecture item, a quiz
    /// or a page unit — keyed by the team and the part it copies, so sharing
    /// the course again rewrites each part instead of adding a second.
    /// Parts whose ids are named by what they are (a generated quiz, a
    /// textbook reading) are renamed by their own rule over the team's ids
    /// instead, so a teammate's later Write Missing Quizzes converges on them.
    static func coursePartID(teamID: String, part: String, originalID: String) -> String {
        "\(part)_" + hex("team:\(teamID):course-\(part):\(originalID)")
    }

    /// A read-only transcript snapshot of a chat. The prefix keeps it apart
    /// from the id shapes `ReviewSessionOrigin` and memory reviews recognize.
    static func chatSnapshotID(teamID: String, originalSessionID: String) -> String {
        "teamchat-" + hex("team:\(teamID):chat:\(originalSessionID)")
    }

    private static func hex(_ key: String) -> String {
        key.sha256Hex
    }
}

// MARK: - Notebook tasks

/// The sources that travelled into a team with an artifact (docs/teams-design.md,
/// decision 16): the record's own sources (`linked`, its `sourceIDs`), the web
/// references its body cites that only this library held (`cited`), and the
/// ones that could not be copied (`failed`). A source the team already held is
/// mapped to the team's copy and listed nowhere: nothing travelled for it.
struct CarriedTeamSources: Sendable, Equatable {
    struct Copy: Sendable, Equatable {
        let originalID: String
        let teamCopyID: String
        let title: String
        let url: String
    }

    struct Failure: Sendable, Equatable {
        let originalID: String
        let reason: String
    }

    var linked: [Copy] = []
    var cited: [Copy] = []
    var failed: [Failure] = []

    /// How many sources travelled by either route.
    var count: Int { linked.count + cited.count }

    mutating func merge(_ other: CarriedTeamSources) {
        linked.append(contentsOf: other.linked)
        cited.append(contentsOf: other.cited)
        failed.append(contentsOf: other.failed)
    }
}

/// What copying an artifact into a team produced: the team copy's id and the
/// sources that travelled with it.
struct ArtifactTeamCopy: Sendable, Equatable {
    let id: String
    var carriedSources: CarriedTeamSources
}

/// What Share… on a notebook did (docs/teams-design.md, decision 22): the
/// team that holds the notebook, whether it was made for it, the team's
/// notebook, and how many sources that notebook holds.
struct NotebookTeamShare: Sendable, Equatable {
    let team: TeamRecord
    let createdTeam: Bool
    let teamNotebookID: String
    let sharedSourceCount: Int
}

/// What copying a course into a team produced: the team's course id, the
/// sources that travelled with it (`linked`: every source its path names),
/// the ones that could not be copied, and how many of its lecture items were
/// left out because their source stayed behind.
struct CourseTeamCopy: Sendable, Equatable {
    let id: String
    var carriedSources: CarriedTeamSources
    var itemsLeftOut: Int
}

enum NotebookTaskStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case todo
    case doing
    case done

    var title: String {
        switch self {
        case .todo: return "To do"
        case .doing: return "In progress"
        case .done: return "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// A list a learner added to a Notebook's task Board, beside To do, In
/// progress and Done (product owner, 2026-11-14: make a new list as well). It
/// is an open list: its cards are not done, and the Board draws it between In
/// progress and Done, in `orderKey` order. The lists travel on the Notebook's
/// record (`boardLists`), so every member of a team sees the same columns.
struct NotebookTaskList: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let notebookID: String
    var title: String
    /// Fractional key (`FractionalIndex`): the lists' order on the Board.
    var orderKey: String
    let createdAt: Date

    init(
        id: String = "bl_" + UUID().uuidString.lowercased(),
        notebookID: String,
        title: String,
        orderKey: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.notebookID = notebookID
        self.title = title
        self.orderKey = orderKey
        self.createdAt = createdAt
    }
}

/// One unit of work inside a Notebook. Tasks exist on every Notebook; in a team
/// Notebook they can be assigned to a member, and they travel in the Notebook's
/// zone so every member sees the same board.
struct NotebookTaskRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let notebookID: String
    var teamID: String?
    var title: String
    var notes: String
    var status: NotebookTaskStatus
    /// The assignee's CloudKit user record name, matching `TeamMemberRecord`.
    var assigneeRecordName: String?
    /// Kept beside the record name so a task still reads well after a member
    /// left and dropped out of the roster.
    var assigneeDisplayName: String?
    var dueAt: Date?
    /// A source or Doc the task is about, when it is about one.
    var sourceID: String?
    var artifactID: String?
    var sortOrder: Double
    var createdByRecordName: String?
    var createdByDisplayName: String?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    /// One of the Notebook's own Board lists (`NotebookTaskList`), when the
    /// card sits in one: an open card, drawn in that list instead of its
    /// status's column. A list the Notebook no longer holds reads as none.
    var listID: String?
    /// The chat this card was taken into (product owner, 2026-11-18: launch a
    /// chat from a Board card and keep the link), by its review session id.
    /// A chat that is not in this library reads as none.
    var chatID: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        notebookID: String,
        teamID: String? = nil,
        title: String,
        notes: String = "",
        status: NotebookTaskStatus = .todo,
        assigneeRecordName: String? = nil,
        assigneeDisplayName: String? = nil,
        dueAt: Date? = nil,
        sourceID: String? = nil,
        artifactID: String? = nil,
        sortOrder: Double = 0,
        createdByRecordName: String? = nil,
        createdByDisplayName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        listID: String? = nil,
        chatID: String? = nil
    ) {
        self.id = id
        self.notebookID = notebookID
        self.teamID = teamID
        self.title = title
        self.notes = notes
        self.status = status
        self.assigneeRecordName = assigneeRecordName
        self.assigneeDisplayName = assigneeDisplayName
        self.dueAt = dueAt
        self.sourceID = sourceID
        self.artifactID = artifactID
        self.sortOrder = sortOrder
        self.createdByRecordName = createdByRecordName
        self.createdByDisplayName = createdByDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.listID = listID
        self.chatID = chatID
    }

    var isOverdue: Bool {
        guard status != .done, let dueAt else { return false }
        return dueAt < Date()
    }
}

// MARK: - Share requests

/// Where a request for a source stands. `open` waits for a member who holds
/// the source; `fulfilled` names the team copy that answered it; `declined`
/// closes it without a copy.
enum ShareRequestStatus: String, Codable, Sendable, CaseIterable {
    case open
    case fulfilled
    case declined
}

/// A member's request that a source cited on a team Doc be shared into the
/// team — the route for a paper or a book that a card cannot add because it is
/// not open on the web, while a teammate holds it privately. The request lives
/// in the team zone like a task (docs/teams-design.md, decision 14), so every
/// member sees it and any editor who holds the source can answer it. The URL
/// is the card's address as written; the holder's library is asked through the
/// same matching the card uses, so a DOI, an arXiv id or a tracking parameter
/// does not hide the match.
struct ShareRequestRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let teamID: String
    /// The reference as the Doc wrote it.
    let url: String
    /// What the card called the source, when it had a name.
    var title: String?
    /// The team Doc the request was made from, when it was made from one.
    var artifactID: String?
    var requestedByRecordName: String?
    var requestedByDisplayName: String?
    var status: ShareRequestStatus
    var resolvedByRecordName: String?
    var resolvedByDisplayName: String?
    /// The team copy that answered the request.
    var fulfilledSourceID: String?
    let createdAt: Date
    var updatedAt: Date
    var resolvedAt: Date?

    init(
        id: String = UUID().uuidString.lowercased(),
        teamID: String,
        url: String,
        title: String? = nil,
        artifactID: String? = nil,
        requestedByRecordName: String? = nil,
        requestedByDisplayName: String? = nil,
        status: ShareRequestStatus = .open,
        resolvedByRecordName: String? = nil,
        resolvedByDisplayName: String? = nil,
        fulfilledSourceID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.teamID = teamID
        self.url = url
        self.title = title
        self.artifactID = artifactID
        self.requestedByRecordName = requestedByRecordName
        self.requestedByDisplayName = requestedByDisplayName
        self.status = status
        self.resolvedByRecordName = resolvedByRecordName
        self.resolvedByDisplayName = resolvedByDisplayName
        self.fulfilledSourceID = fulfilledSourceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }

    var isOpen: Bool { status == .open }
}

// MARK: - Zone homes

/// Where a synced record lives in CloudKit. Every record has exactly one home:
/// the learner's own `Knowledge` zone, or a team zone reached either through
/// the private database (the team's owner) or the shared database (a member).
/// Record names stay a pure function of entity and logical key; the home is
/// what turns a name into a `CKRecord.ID`.
struct CloudKitZoneHome: Hashable, Sendable, Codable {
    enum Scope: String, Sendable, Codable {
        case privateScope = "private"
        case shared
    }

    let scope: Scope
    let zoneName: String
    /// nil means the current user owns the zone.
    let ownerRecordName: String?

    init(scope: Scope, zoneName: String, ownerRecordName: String?) {
        self.scope = scope
        self.zoneName = zoneName
        // The private database only ever holds the current user's zones, so a
        // stored owner there is noise that would break equality with `.knowledge`.
        self.ownerRecordName = scope == .privateScope ? nil : ownerRecordName
    }

    static let knowledgeZoneName = "Knowledge"

    static let knowledge = CloudKitZoneHome(
        scope: .privateScope,
        zoneName: knowledgeZoneName,
        ownerRecordName: nil
    )

    var teamID: String? { TeamRecord.teamID(fromZoneName: zoneName) }
}
