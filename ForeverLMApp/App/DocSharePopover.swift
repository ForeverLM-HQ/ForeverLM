import AppKit
import SwiftUI

/// Who can open a Doc, in one popover from the header's **Share** button
/// (product owner, 2026-09-19, looking at Claude's artifact Share popover: "this
/// kind of sharing functionality for artifacts should also be implemented in
/// foreverlm"). Top to bottom: the Doc's title; a field that invites people
/// by email; **Who has access** — the link, anyone at each team, each reader,
/// the author; and a footer with the one sentence that says who can open it,
/// a gear to the publish sheet (the custom address, pages guarded by a password) and
/// **Copy link**. Every row acts at once and shows its own progress; the
/// rows come from `DocSharing`, which is also what the header chip, the More
/// menu, Web Studio and `list_docs` read.
/// Spec: docs/docs-design.md → Publishing → The Share popover.
struct DocSharePopover: View {
    @Environment(StudioViewModel.self) private var vm
    let artifact: ArtifactRecord
    /// The teams already holding a copy of this Doc.
    let teamsHoldingCopy: [TeamRecord]
    /// Flush the editor's draft and publish the current text with the access
    /// asked for; the page is created when the Doc has none.
    let publish: (DocPageAccess) async throws -> PublishedDocStatus
    /// A team was just given a copy; the header re-reads who holds one.
    let teamShared: () async -> Void
    /// The gear: the publish sheet, for the address and pages guarded by a password.
    let openSettings: () -> Void
    let close: () -> Void

    @State private var inviteDraft = ""
    /// The row whose change is in flight, showing a spinner in place of its control.
    @State private var busyRowID: String?
    @State private var errorMessage: String?
    /// The readers a page had when its link was opened here, so **No access**
    /// in the same popover shares it with them again; the site keeps no list
    /// for an open page.
    @State private var retainedReaders: [String] = []
    @State private var didCopy = false
    /// A team the learner gave the Doc to before they had affirmed they may
    /// share its sources: the popover asks "Before you share" in place of its
    /// rows, and the share runs once they do (docs/teams-design.md, decision 22).
    @State private var teamAwaitingRights: DocSharing.Team?

    static let width: CGFloat = 400

    private var status: PublishedDocStatus? { vm.publishedDocStatuses[artifact.id] }
    private var isSignedIn: Bool { ManagedAI.isSignedIn }

    private var model: DocSharing.Model {
        DocSharing.model(
            status: status,
            teams: vm.teams,
            teamsHoldingCopy: teamsHoldingCopy,
            identity: DocSharing.identity(displayName: MacAccountUser.fullName, rosters: Array(vm.teamMembersByTeamID.values)),
            showsTeams: vm.activeTeamID == nil
        )
    }

    /// The addresses typed so far, or nil while one of them is not an address.
    private var typedReaders: [String]? {
        DocPublishing.normalizeReaders(inviteDraft)
    }

    private var canInvite: Bool {
        guard isSignedIn, busyRowID == nil, let typedReaders, !typedReaders.isEmpty else { return false }
        return DocSharing.access(inviting: typedReaders, to: status) != nil
    }

    private var inviteIsInvalid: Bool {
        !inviteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && typedReaders == nil
    }

    var body: some View {
        Group {
            if let team = teamAwaitingRights {
                SharingRightsAffirmationView(
                    onShare: {
                        teamAwaitingRights = nil
                        SharingRightsRow.affirm()
                        shareWithTeam(team)
                    },
                    onCancel: { teamAwaitingRights = nil }
                )
                .padding(16)
                .frame(width: Self.width)
            } else {
                sharingFace
            }
        }
        .onChange(of: status?.readers) { old, new in
            // A list the site just held is what No access brings back.
            if let old, !old.isEmpty, new?.isEmpty != false { retainedReaders = old }
        }
    }

    private var sharingFace: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            inviteRow
            Text("Who has access")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(model.rows) { row in
                    rowView(row)
                }
            }
            if inviteIsInvalid {
                Text("One of these is not an email address.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if !isSignedIn {
                Text("Publishing is tied to your ForeverLM account. Sign in with Apple in Settings › API Keys first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: Self.width)
    }

    // MARK: - Title, invite, footer

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(artifact.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    private var inviteRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Add people by email", text: $inviteDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                    .disabled(busyRowID != nil)
                    .onSubmit { invite() }
                    .accessibilityLabel("Add people by email")
                // Published pages read the same for everyone but the author,
                // so there is one role and it is not a choice.
                Text("Reader")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(inviteIsInvalid ? 0.35 : 0.08))
            )
            Button("Invite") { invite() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canInvite)
                .help(model.isOpen
                      ? "Share the page with these people only; the link stops working for anyone else"
                      : "Share the page with these people")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
            .help("The page's address, and republishing its text")
            .accessibilityLabel("Page settings")
            Button {
                copyLink()
            } label: {
                Label(didCopy ? "Copied" : "Copy link", systemImage: "link")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(model.url == nil)
            .help(model.url == nil ? "This Page is not published yet" : "Copy the page's address")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: DocSharing.Row) -> some View {
        HStack(spacing: 10) {
            avatar(for: row)
            rowText(row)
                .frame(maxWidth: .infinity, alignment: .leading)
            if busyRowID == row.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 22)
            } else {
                rowControl(row)
            }
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func avatar(for row: DocSharing.Row) -> some View {
        switch row {
        case .anyoneWithLink:
            symbolAvatar("globe")
        case .team:
            symbolAvatar("building.2")
        case .reader(let address):
            letterAvatar(String(address.prefix(1)).uppercased(), tint: Color.accentColor.opacity(0.75))
        case .author(let name, _):
            letterAvatar(TeamMemberRecord.initials(for: name), tint: Color(nsColor: .systemPink).opacity(0.8))
        }
    }

    private func symbolAvatar(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.primary.opacity(0.06)))
    }

    private func letterAvatar(_ letters: String, tint: Color) -> some View {
        Text(letters)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(tint))
            .textSelection(.disabled)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rowText(_ row: DocSharing.Row) -> some View {
        switch row {
        case .anyoneWithLink:
            Text("Anyone with the link")
                .font(.system(size: 12))
        case .team(let team):
            Text("Anyone at \(team.name)")
                .font(.system(size: 12))
                .lineLimit(1)
        case .reader(let address):
            Text(address)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        case .author(let name, let email):
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("(you)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let email {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func rowControl(_ row: DocSharing.Row) -> some View {
        switch row {
        case .anyoneWithLink(let canRead):
            accessMenu(
                current: canRead ? "Can read" : "No access",
                canRead: canRead,
                setCanRead: { setAnyoneCanRead(true) },
                setNoAccess: { setAnyoneCanRead(false) },
                noAccessDisabled: !canRead || DocSharing.access(closingLinkKeeping: retainedReaders) == nil,
                noAccessHelp: "Invite the people who may open the page first"
            )
            .disabled(!isSignedIn || busyRowID != nil)
        case .team(let team):
            if team.holdsCopy {
                // A copy cannot be recalled from here: it is the team's now.
                Text(team.permission == .readWrite ? "Shared · read and write" : "Shared · read only")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("\(team.name) holds a copy of this Page; open it from the header's \(team.name) chip")
            } else {
                accessMenu(
                    current: "No access",
                    canRead: false,
                    setCanRead: { shareWithTeamAfterAsking(team) },
                    setNoAccess: {},
                    noAccessDisabled: true,
                    noAccessHelp: nil
                )
                .disabled(busyRowID != nil || team.permission != .readWrite)
                .help(team.permission == .readWrite
                      ? "Give \(team.name) a copy of this Page; its members can also open its page"
                      : "\(team.name) is read-only for you")
            }
        case .reader(let address):
            HStack(spacing: 4) {
                Text("Reader")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                let removable = status.map { DocSharing.canRemove(address, from: $0) } ?? false
                Button {
                    removeReader(address)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                .disabled(!removable || !isSignedIn || busyRowID != nil)
                .help(removable
                      ? "Remove \(address); they are shut out at once"
                      : "The last reader stays: open the link to anyone, or unpublish the page")
                .accessibilityLabel("Remove \(address)")
            }
        case .author:
            Text("Author")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    /// **Can read** / **No access** as a menu that reads its current answer;
    /// check-marked items, the way every access menu on macOS reads.
    private func accessMenu(
        current: String,
        canRead: Bool,
        setCanRead: @escaping () -> Void,
        setNoAccess: @escaping () -> Void,
        noAccessDisabled: Bool,
        noAccessHelp: String?
    ) -> some View {
        Menu {
            Toggle("Can read", isOn: Binding(get: { canRead }, set: { if $0 { setCanRead() } }))
            Toggle("No access", isOn: Binding(get: { !canRead }, set: { if $0 { setNoAccess() } }))
                .disabled(noAccessDisabled)
                .help(noAccessHelp ?? "")
        } label: {
            HStack(spacing: 4) {
                Text(current)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .fixedSize()
    }

    // MARK: - Actions

    private func invite() {
        guard canInvite, let typedReaders,
              let access = DocSharing.access(inviting: typedReaders, to: status) else { return }
        run(rowID: "invite") {
            try await publishAndRecord(access)
            inviteDraft = ""
        }
    }

    private func removeReader(_ address: String) {
        guard let status, let access = DocSharing.access(removing: address, from: status) else { return }
        run(rowID: DocSharing.Row.reader(address).id) {
            try await publishAndRecord(access)
        }
    }

    private func setAnyoneCanRead(_ canRead: Bool) {
        let access: DocPageAccess
        if canRead {
            if let readers = status?.readers, !readers.isEmpty { retainedReaders = readers }
            access = DocSharing.accessOpeningLink()
        } else {
            guard let closing = DocSharing.access(closingLinkKeeping: retainedReaders) else { return }
            access = closing
        }
        run(rowID: DocSharing.Row.anyoneWithLink(canRead: canRead).id) {
            try await publishAndRecord(access)
        }
    }

    /// A team copy carries the Doc's sources to its members, so the first
    /// one asks "Before you share" here first.
    private func shareWithTeamAfterAsking(_ team: DocSharing.Team) {
        if SharingRightsRow.needsAsking {
            teamAwaitingRights = team
        } else {
            shareWithTeam(team)
        }
    }

    /// Share the Doc into the team — the copy-travels rule, the same share
    /// the More menu makes — and, while the page is shared with specific
    /// people, admit the team's accepted members to it as well.
    private func shareWithTeam(_ team: DocSharing.Team) {
        run(rowID: DocSharing.Row.team(team).id) {
            await vm.shareArtifact(artifact.id, withTeam: team.id)
            await teamShared()
            if status?.isProtected == true {
                await vm.refreshTeamMembers(teamID: team.id)
                if let access = DocSharing.access(admitting: vm.members(of: team.id), to: status) {
                    try await publishAndRecord(access)
                }
            }
        }
    }

    private func publishAndRecord(_ access: DocPageAccess) async throws {
        let result = try await publish(access)
        vm.publishedDocStatuses[artifact.id] = result
        await vm.refreshPublishedDocStatuses()
    }

    private func copyLink() {
        guard let url = model.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        didCopy = true
        vm.showToast("Link copied")
    }

    /// One change at a time: the row shows a spinner while its network call
    /// runs, and a failure is said here, under the rows, in the site's own words.
    private func run(rowID: String, _ work: @escaping () async throws -> Void) {
        guard busyRowID == nil else { return }
        busyRowID = rowID
        errorMessage = nil
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            busyRowID = nil
        }
    }
}
