import Foundation

/// Who can open a Doc — its page on foreverlm.com, and the teams that hold a
/// copy — as the Share popover lists it and as one sentence. The popover, the
/// Docs pane header's chip, the More menu, Web Studio and `list_docs`
/// (`published_access_summary`) all read this one rule, so none of them can
/// say something another does not. Pure: the popover asks here what to send
/// and what to show; the network calls stay in `DocPublishing` and the team
/// share in `StudioViewModel.shareArtifact`.
/// Spec: docs/docs-design.md → Publishing → The Share popover.
enum DocSharing {
    /// The signed-in account, for the popover's author row.
    struct Identity: Equatable, Sendable {
        var displayName: String?
        var email: String?
    }

    /// A team as the popover lists it: whether it already holds a copy of the
    /// Doc, and its standing when it does.
    struct Team: Equatable, Sendable, Identifiable {
        let id: String
        var name: String
        var permission: TeamPermission
        var holdsCopy: Bool
    }

    enum Row: Equatable, Sendable, Identifiable {
        /// The page's link: open to anyone who has it, or not.
        case anyoneWithLink(canRead: Bool)
        /// Anyone at a team: a copy in the team's library, and — while the
        /// page is shared with specific people — the roster on the list.
        case team(Team)
        /// One address the page is shared with.
        case reader(String)
        /// The account that owns the page, last.
        case author(name: String, email: String?)

        var id: String {
            switch self {
            case .anyoneWithLink: return "link"
            case .team(let team): return "team:" + team.id
            case .reader(let address): return "reader:" + address
            case .author: return "author"
            }
        }
    }

    struct Model: Equatable, Sendable {
        var rows: [Row]
        var summary: String
        var url: URL?
        var isPublished: Bool
        /// Anyone with the link can open the page.
        var isOpen: Bool
        var readers: [String]
    }

    // MARK: - Rows

    /// The popover's rows, top to bottom: the link, the teams (only in My
    /// Library — a copy is not shared onward from a team), the readers, the
    /// author. `teamsHoldingCopy` are the teams that already have the Doc.
    static func model(
        status: PublishedDocStatus?,
        teams: [TeamRecord],
        teamsHoldingCopy: [TeamRecord],
        identity: Identity,
        showsTeams: Bool
    ) -> Model {
        var rows: [Row] = [.anyoneWithLink(canRead: isOpen(status))]
        if showsTeams {
            let holding = Set(teamsHoldingCopy.map(\.id))
            rows.append(contentsOf: teams.map { team in
                .team(Team(id: team.id, name: team.name, permission: team.permission, holdsCopy: holding.contains(team.id)))
            })
        }
        let readers = status?.readers ?? []
        rows.append(contentsOf: readers.map(Row.reader))
        rows.append(.author(name: authorName(identity), email: identity.email))
        return Model(
            rows: rows,
            summary: summary(status: status, teamNames: teamsHoldingCopy.map(\.name)),
            url: status?.url,
            isPublished: status != nil,
            isOpen: isOpen(status),
            readers: readers
        )
    }

    /// The author row's name: the account's display name, else its address,
    /// else plainly "You".
    static func authorName(_ identity: Identity) -> String {
        if let name = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { return email }
        return "You"
    }

    /// The account as the popover knows it: the Mac's display name, and the
    /// address a team roster recorded for this account when one has (the
    /// managed session stores no address of its own).
    static func identity(displayName: String?, rosters: [[TeamMemberRecord]]) -> Identity {
        let email = rosters.lazy.flatMap { $0 }
            .first { $0.isCurrentUser && $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }?
            .email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Identity(displayName: displayName, email: email)
    }

    /// A page with no reader list and no legacy password is open to anyone
    /// with the link. An unpublished Doc is not open: nobody has a link.
    static func isOpen(_ status: PublishedDocStatus?) -> Bool {
        guard let status else { return false }
        return !status.isProtected
    }

    // MARK: - The one sentence

    /// Who can open the Doc, in one sentence. Web Studio's
    /// `publishedAccessSummary` says the same words; a website test reads
    /// them from this file, so change them here and only here.
    static func summary(status: PublishedDocStatus?, teamNames: [String]) -> String {
        summary(
            isPublished: status != nil,
            isOpen: isOpen(status),
            readerCount: status?.readers.count ?? 0,
            hasLegacyPassword: status?.isProtected == true && status?.readers.isEmpty == true && status?.password != nil,
            teamNames: teamNames
        )
    }

    static func summary(
        isPublished: Bool,
        isOpen: Bool,
        readerCount: Int,
        hasLegacyPassword: Bool,
        teamNames: [String]
    ) -> String {
        let page: String
        if !isPublished {
            page = "Only you can open this Page"
        } else if isOpen {
            page = "Anyone with the link can open this page"
        } else if readerCount == 1 {
            page = "Only the person listed can open this page"
        } else if readerCount > 1 {
            page = "Only the \(readerCount) people listed can open this page"
        } else if hasLegacyPassword {
            page = "Only people with its old password can open this page"
        } else {
            page = "Nobody but you can open this page"
        }
        switch teamNames.count {
        case 0: return page
        case 1: return page + " · shared with \(teamNames[0])"
        default: return page + " · shared with \(teamNames.count) teams"
        }
    }

    // MARK: - What a change sends

    /// The site holds one list, and it is who may open the page while the
    /// link is closed: `readers: []` is an open page, a non-empty list is a
    /// closed one (`publishing/service.ts`, `normalizeReaders`). Every change
    /// below is phrased in those terms, so the popover never asks the site for
    /// a state it cannot keep.

    /// Invite: the typed addresses join the list, and the page is shared with
    /// exactly that list — a first publish restricted to those people, or a
    /// link that was open closing to them. Nil when nothing would change, or
    /// when the list would pass the site's ceiling.
    static func access(inviting typed: [String], to status: PublishedDocStatus?) -> DocPageAccess? {
        var readers = status?.readers ?? []
        for address in typed where !readers.contains(address) { readers.append(address) }
        guard !readers.isEmpty, readers.count <= DocPublishing.maxReaders else { return nil }
        if let status, status.isProtected, readers == status.readers { return nil }
        return .readers(readers)
    }

    /// A team given the page: every accepted member's address joins the
    /// list, but only while the page is shared with specific people — an open
    /// page already admits them, and an unpublished Doc has no page to admit
    /// them to. Nil when nothing changes.
    static func access(admitting members: [TeamMemberRecord], to status: PublishedDocStatus?) -> DocPageAccess? {
        guard let status, status.isProtected, !status.readers.isEmpty else { return nil }
        let addresses = members
            .filter { $0.acceptanceStatus == "accepted" }
            .compactMap { $0.email.flatMap(DocPublishing.normalizeReader) }
        var readers = status.readers
        for address in addresses where !readers.contains(address) { readers.append(address) }
        guard readers != status.readers, readers.count <= DocPublishing.maxReaders else { return nil }
        return .readers(readers)
    }

    /// The last reader cannot be removed: an empty list is an open page, and
    /// shutting one person out must never open the page to everyone. The
    /// link row opens it on purpose; Unpublish takes it down.
    static func canRemove(_ reader: String, from status: PublishedDocStatus) -> Bool {
        status.readers.contains(reader) && status.readers.count > 1
    }

    /// Remove one reader; nil when the list would empty (see `canRemove`).
    static func access(removing reader: String, from status: PublishedDocStatus) -> DocPageAccess? {
        guard canRemove(reader, from: status) else { return nil }
        return .readers(status.readers.filter { $0 != reader })
    }

    /// The link row's **Can read**: the page opens to anyone with the link,
    /// publishing it if it has no page yet. The site drops the reader list;
    /// `retained` is what the popover keeps so **No access** in the same
    /// popover can restore it.
    static func accessOpeningLink() -> DocPageAccess { .open }

    /// The link row's **No access**: the page is shared with `retained`
    /// again. Nil when there is nobody to share it with — the site cannot
    /// hold a closed page with an empty list, so the row offers Invite first.
    static func access(closingLinkKeeping retained: [String]) -> DocPageAccess? {
        guard !retained.isEmpty, retained.count <= DocPublishing.maxReaders else { return nil }
        return .readers(retained)
    }
}
