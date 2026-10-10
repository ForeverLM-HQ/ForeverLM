import AppKit
import SwiftUI

extension Notification.Name {
    /// Opens the Share popover of the notebook in the window whose id is the
    /// notification's object: the notebook's ⋯ › Share….
    static let showNotebookShare = Notification.Name("showNotebookShare")
}

/// A notebook's Share… (docs/teams-design.md, decision 22; the product owner,
/// 2026-10-03: "also make sure that notebooks are easily shareable with
/// other people" … "including all the sources in them"). One popover, from
/// the Share button at the top right of the notebook, its ⋯, the Notebooks
/// home card's ⋯ and the rail row's menu.
///
/// It says in one line what a share gives — the notebook and its sources —
/// before the notebook is shared and after (`NotebookShareLine`, the iPhone's
/// and the web's words too). Not shared yet, it offers **Invite People…** and
/// **Copy Invitation Link**: either makes a
/// team named after the notebook holding it, in one step
/// (`teamForSharingNotebook`), then opens Apple's sharing sheet or copies the
/// link, as Team Settings does. Shared, it lists who has it — the team's
/// members and invitations — with the same two actions for that team, and
/// Share with Team ▸ for another. A read-only member sees who has it and
/// cannot invite; a notebook of their own still goes to another team with
/// Share with Team ▸. The first share asks "Before you share" in the
/// popover's place.
struct NotebookSharePopover: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let close: () -> Void

    private enum Action: Equatable {
        case invite
        case copyLink
        case shareWithTeam(String)
    }

    /// The teams that have the notebook; nil until read.
    @State private var teams: [TeamRecord]?
    @State private var chosenTeamID: String?
    /// A share chosen before the learner affirmed: the popover asks first.
    @State private var actionAwaitingRights: Action?

    static let width: CGFloat = 360

    /// The team the popover is about: the one chosen, else the first.
    private var shownTeam: TeamRecord? {
        guard let teams, let first = teams.first else { return nil }
        let id = chosenTeamID.flatMap { chosen in teams.contains { $0.id == chosen } ? chosen : nil } ?? first.id
        return vm.team(id: id) ?? teams.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let action = actionAwaitingRights {
                SharingRightsAffirmationView(
                    onShare: {
                        actionAwaitingRights = nil
                        SharingRightsRow.affirm()
                        perform(action)
                    },
                    onCancel: { actionAwaitingRights = nil }
                )
            } else {
                face
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .task(id: goal.id) { await load() }
        // Apple's sheet or another window changed a roster or the teams.
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamRosterDidChange)) { _ in
            Task { await load() }
        }
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            Text(NotebookShareLine.text(sourceCount: goal.approvedSourceIDs.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if teams == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if let team = shownTeam {
                sharedFace(team)
            } else {
                actionButtons(for: nil)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(NotebookShareLine.title(notebookTitle: goal.title))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
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

    // MARK: - Who has it

    @ViewBuilder
    private func sharedFace(_ team: TeamRecord) -> some View {
        if let teams, teams.count > 1 {
            Picker("Team", selection: Binding(get: { team.id }, set: { chosenTeamID = $0 })) {
                ForEach(teams) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which team")
        } else {
            Label(team.name, systemImage: "person.2")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        if !team.canEdit {
            Label("Read only", systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        let members = vm.members(of: team.id).filter { $0.acceptanceStatus != "removed" }
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(members) { member in
                    TeamMemberRow(member: member)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if team.canEdit {
            actionButtons(for: team)
        }
        // The learner's own notebook goes to another team even when the team
        // that has it is one they may only read.
        shareWithAnotherTeam
    }

    /// Share with Team ▸ for a team that does not have the notebook yet; a
    /// notebook of My Library only, as everywhere.
    @ViewBuilder
    private var shareWithAnotherTeam: some View {
        let held = Set((teams ?? []).map(\.id))
        if goal.teamID == nil, vm.teamsAcceptingShares.contains(where: { !held.contains($0.id) }) {
            ShareWithTeamMenu(asksSharingRights: false, excludedTeamIDs: held) { teamID in
                start(.shareWithTeam(teamID))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize()
            .hoverHighlight(cornerRadius: 6)
        }
    }

    // MARK: - Invite

    /// Invite People… opens Apple's sharing sheet, where only a team's owner
    /// adds people; Copy Invitation Link copies the link as Team Settings
    /// does. With no team yet, both make it first.
    private func actionButtons(for team: TeamRecord?) -> some View {
        HStack(spacing: 8) {
            if team == nil || team?.role == .owner {
                Button("Invite People…") { start(.invite) }
                    .buttonStyle(.borderedProminent)
                    .help("Invite people by name or email with Apple's sharing sheet")
            }
            Button {
                start(.copyLink)
            } label: {
                Label("Copy Invitation Link", systemImage: "link")
            }
            .buttonStyle(.bordered)
            .help(team == nil || team?.role == .owner
                  ? "Copy a link anyone can use to join and edit"
                  : "Copy the team's invitation link")
        }
        .controlSize(.regular)
    }

    private func start(_ action: Action) {
        if SharingRightsRow.needsAsking {
            actionAwaitingRights = action
        } else {
            perform(action)
        }
    }

    /// The popover makes way, and the share runs where it no longer depends
    /// on it: Apple's sheet, the copied link and the toasts report it.
    private func perform(_ action: Action) {
        let notebookID = goal.id
        let teamID = shownTeam?.id
        let vm = vm
        close()
        Task { @MainActor in
            switch action {
            case .invite:
                guard let team = await vm.teamForSharingNotebook(notebookID, inTeam: teamID) else { return }
                TeamSharingService.shared.presentMembers(for: team)
            case .copyLink:
                guard let team = await vm.teamForSharingNotebook(notebookID, inTeam: teamID) else { return }
                TeamSharingService.shared.copyInvitationLink(for: team) { vm.showToast($0) }
            case .shareWithTeam(let otherTeamID):
                await vm.shareNotebook(notebookID, withTeam: otherTeamID)
            }
        }
    }

    private func load() async {
        let found = await vm.teamsSharingNotebook(goal.id)
        teams = found
        for team in found {
            await vm.refreshTeamMembers(teamID: team.id)
        }
    }
}

/// **Share** at the top right of the notebook, on the Studio column's chrome
/// line: a titlebar-band control, as everything on that line is, labelled as
/// NotebookLM labels its own. Opens the notebook's Share popover.
struct NotebookShareButton: View {
    @Environment(\.uiZoomScale) private var uiZoomScale
    let action: () -> Void

    private static let title = "Share"
    private static let fontSize: CGFloat = 11.5

    var body: some View {
        TitlebarBandButton(
            help: "Share this notebook",
            accessibilityLabel: "Share",
            accessibilityIdentifier: "notebook.share",
            controlWidth: labelWidth,
            action: action
        ) {
            HStack(spacing: 4) {
                Image(systemName: "person.badge.plus")
                    .zoomedSystemFont(size: 11, weight: .medium)
                Text(Self.title)
                    .zoomedSystemFont(size: Self.fontSize, weight: .medium)
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
        }
    }

    private var labelWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.fontSize * uiZoomScale, weight: .medium)
        let text = (Self.title as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 22 * uiZoomScale
    }
}
