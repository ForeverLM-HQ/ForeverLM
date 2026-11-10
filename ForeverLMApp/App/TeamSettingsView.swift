import AppKit
import SwiftUI

/// Settings → Data & Privacy › Teams: every team this account belongs to, with its
/// roster, and the lifecycle actions that do not belong in a menu on the rail:
/// create, rename, manage members through Apple's sharing sheet, copy the
/// invitation link, leave, delete. Sharing content into a team happens where
/// the content is; this pane is about the teams themselves. The *open* team
/// also has its own Settings, apart from these (`SettingsScope.team`):
/// `TeamGeneralSettingsDetailView` and `TeamMembersSettingsDetailView`,
/// which follow the active library.
struct TeamSettingsSection: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var newTeamName = ""
    @State private var isCreating = false
    /// Shown under the field. Toasts render in the Studio window, not here.
    @State private var createError: String?
    @State private var teamPendingLeave: TeamRecord?
    @State private var teamPendingDelete: TeamRecord?

    var body: some View {
        SettingsSection(
            title: "Teams",
            description: "A team is a second library, shared through iCloud. Sharing copies into it; My Library stays as it is."
        ) {
            VStack(spacing: 14) {
                ForEach(vm.teams) { team in
                    TeamSettingsCard(
                        team: team,
                        members: vm.members(of: team.id),
                        onLeave: { teamPendingLeave = team },
                        onDelete: { teamPendingDelete = team }
                    )
                }
                SettingsCard {
                    newTeamRow
                }
            }
        }
        .task {
            await vm.loadTeams()
            for team in vm.teams {
                await vm.refreshTeamMembers(teamID: team.id)
            }
        }
        // The sharing sheet and an accepted invitation both change the roster
        // outside this pane; neither is observable through the view model.
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamRosterDidChange)) { note in
            let teamID = note.object as? String
            Task {
                await vm.loadTeams()
                if let teamID { await vm.refreshTeamMembers(teamID: teamID) }
            }
        }
        .alert(
            "Leave \(teamPendingLeave?.name ?? "the team")?",
            isPresented: Binding(
                get: { teamPendingLeave != nil },
                set: { if !$0 { teamPendingLeave = nil } }
            ),
            presenting: teamPendingLeave
        ) { team in
            Button("Leave Team", role: .destructive) {
                Task { await vm.leaveTeam(team.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The team's copies are removed from this Mac. Your own sources, notebooks, Pages and chats stay in My Library.")
        }
        .alert(
            "Delete \(teamPendingDelete?.name ?? "the team")?",
            isPresented: Binding(
                get: { teamPendingDelete != nil },
                set: { if !$0 { teamPendingDelete = nil } }
            ),
            presenting: teamPendingDelete
        ) { team in
            Button("Delete Team", role: .destructive) {
                Task { await vm.deleteTeam(team.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The team and its copies are removed for every member. Everyone's originals stay in their own library.")
        }
    }

    private var trimmedNewTeamName: String {
        newTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var newTeamRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 28)
                TextField("Team name", text: $newTeamName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createTeam)
                    .disabled(isCreating)
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Creating team")
                }
                Button("Create") { createTeam() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedNewTeamName.isEmpty || isCreating)
            }
            if let createError {
                Text(createError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
        }
    }

    private func createTeam() {
        let name = trimmedNewTeamName
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        createError = nil
        Task {
            do {
                _ = try await vm.createTeam(name: name)
                newTeamName = ""
            } catch {
                createError = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// One team: its name and standing, the actions its role allows, and the
/// roster the share's participants notebook to.
private struct TeamSettingsCard: View {
    @Environment(StudioViewModel.self) private var vm
    let team: TeamRecord
    let members: [TeamMemberRecord]
    let onLeave: () -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var isOwner: Bool { team.role == .owner }

    /// Participants who have not left. A removed participant stays in the
    /// share's list until CloudKit prunes it, and is nobody's colleague.
    private var visibleMembers: [TeamMemberRecord] {
        members.filter { $0.acceptanceStatus != "removed" }
    }

    private var standing: String {
        var parts = [isOwner ? "Owner" : "Member"]
        parts.append(team.canEdit ? "Read and write" : "Read only")
        let count = visibleMembers.count
        parts.append(count == 1 ? "1 member" : "\(count) members")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SettingsCard {
            header
            if !visibleMembers.isEmpty {
                Divider()
                    .padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleMembers) { member in
                        TeamMemberRow(member: member)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: team.canEdit ? "person.2.fill" : "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(team.canEdit ? Color.green : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Team name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onAppear { renameFocused = true }
                        .onChange(of: renameFocused) { wasFocused, isFocused in
                            if wasFocused, !isFocused { commitRename() }
                        }
                        .frame(maxWidth: 320)
                } else {
                    Text(team.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(standing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if isOwner {
                Button("Manage Members…") {
                    TeamSharingService.shared.presentMembers(for: team)
                }
                .buttonStyle(.bordered)
                .help("Invite people by name or email, or change what they may do")
            }
            if team.shareURL != nil {
                Button("Copy Link") {
                    TeamSharingService.shared.copyInvitationLink(for: team) { vm.showToast($0) }
                }
                .buttonStyle(.bordered)
                .help(isOwner
                      ? "Copy a link anyone can use to join and edit; the team opens to the link when you copy it"
                      : "Copy the team's invitation link")
            }

            Menu {
                if isOwner {
                    Button("Rename…", systemImage: "pencil", action: beginRename)
                }
                if team.shareURL != nil {
                    Button("Copy Invitation Link", systemImage: "link") {
                        TeamSharingService.shared.copyInvitationLink(for: team) { vm.showToast($0) }
                    }
                }
                if vm.activeTeamID != team.id {
                    Button("Open Library", systemImage: "books.vertical") {
                        Task { await vm.setActiveTeam(team.id) }
                    }
                } else {
                    Button("\(team.name) Settings", systemImage: "person.2.badge.gearshape") {
                        NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.teamGeneral)
                    }
                }
                Divider()
                if isOwner {
                    Button("Delete Team…", systemImage: "trash", role: .destructive, action: onDelete)
                } else {
                    Button("Leave Team…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: onLeave)
                }
            } label: {
                RowMoreActionsLabel(bordered: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Team actions")
        }
    }

    private func beginRename() {
        renameText = team.name
        isRenaming = true
    }

    private func cancelRename() {
        isRenaming = false
        renameFocused = false
    }

    private func commitRename() {
        guard isRenaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        renameFocused = false
        guard !name.isEmpty, name != team.name else { return }
        Task { await vm.renameTeam(team.id, name: name) }
    }
}

/// One person on a team's roster: their initials, name ("you" for this
/// account), email, "Invited" while they have not accepted, and what they
/// may do. Team Settings and a notebook's Share popover draw it.
struct TeamMemberRow: View {
    let member: TeamMemberRecord

    private var isPending: Bool { member.acceptanceStatus == "pending" }

    private var standing: String {
        if member.role == .owner { return "Owner" }
        return member.permission == .readWrite ? "Read and write" : "Read only"
    }

    var body: some View {
        HStack(spacing: 10) {
            TeamMemberAvatar(initials: member.initials, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(member.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    if member.isCurrentUser {
                        Text("you")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let email = member.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if isPending {
                Text("Invited")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            Text(standing)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A member's initials in a tinted circle, shared by the roster and by the
/// task board's assignee controls.
struct TeamMemberAvatar: View {
    let initials: String
    var size: CGFloat = 22

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.14), in: Circle())
            .textSelection(.disabled)
            .accessibilityHidden(true)
    }
}

// MARK: - The open team's settings

/// What the team-scoped panes show when no team library is open — the
/// account menu has no team entry by then, but the team's Settings can still
/// be on screen if the learner switched libraries or left the team while it
/// was open.
private struct NoOpenTeamView: View {
    let onShowAllTeams: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    title: "No team open",
                    description: "Switch to a team library from the account menu to see its settings here."
                ) {
                    SettingsCard {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            Text("Every team you belong to is listed in My Settings › Data & Privacy.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Button("All Teams") { onShowAllTeams() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The eyebrow every team-scoped pane carries, so the page says which team it
/// is about even when the sidebar is scrolled away.
private func teamEyebrow(_ team: TeamRecord) -> String {
    team.canEdit ? "Team" : "Team · Read only"
}

/// <Team> Settings → General: the open team's name and standing, its
/// invitation link, and leaving or deleting it. Scoped to the active library
/// (product owner, 2026-09-08: team settings follow the open library, like Claude's
/// admin settings follow the selected organization) and, since 2026-09-22, a
/// Settings of its own rather than a group in the learner's.
struct TeamGeneralSettingsDetailView: View {
    @Environment(StudioViewModel.self) private var vm
    let onShowAllTeams: () -> Void

    @State private var nameText = ""
    @State private var isConfirmingLeave = false
    @State private var isConfirmingDelete = false

    var body: some View {
        if let team = vm.activeTeam {
            content(for: team)
        } else {
            NoOpenTeamView(onShowAllTeams: onShowAllTeams)
                .navigationTitle("General")
        }
    }

    private func content(for team: TeamRecord) -> some View {
        let isOwner = team.role == .owner
        let members = vm.members(of: team.id).filter { $0.acceptanceStatus != "removed" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    eyebrow: teamEyebrow(team),
                    title: team.name,
                    description: standing(for: team, isOwner: isOwner, memberCount: members.count)
                ) {
                    SettingsCard {
                        nameRow(for: team, isOwner: isOwner)
                    }
                }

                SettingsSection(
                    title: "Invitations",
                    description: "Apple sends the invitation; a person accepts it on a Mac running ForeverLM and the team appears in their library switcher."
                ) {
                    SettingsCard {
                        HStack(spacing: 12) {
                            Image(systemName: "link")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Invitation link")
                                    .font(.headline)
                                Text(team.shareURL == nil
                                     ? "The link appears once iCloud has shared the team."
                                     : isOwner
                                        ? "Copy Link opens the team to anyone who has the link, with editing. Manage Members… invites named people instead."
                                        : "Anyone who has the link can join once the owner has opened it.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            if isOwner {
                                Button("Manage Members…") {
                                    TeamSharingService.shared.presentMembers(for: team)
                                }
                                .buttonStyle(.bordered)
                                .help("Invite people by name or email, or change what they may do")
                            }
                            Button("Copy Link") {
                                TeamSharingService.shared.copyInvitationLink(for: team) { vm.showToast($0) }
                            }
                                .buttonStyle(.bordered)
                                .disabled(team.shareURL.flatMap(URL.init(string:)) == nil)
                        }
                    }
                }

                SettingsSection(
                    title: isOwner ? "Delete this team" : "Leave this team",
                    description: isOwner
                        ? "The team and its copies are removed for every member. Everyone's originals stay in their own library."
                        : "The team's copies are removed from this Mac. Your own sources, notebooks, Pages and chats stay in My Library."
                ) {
                    SettingsCard {
                        HStack(spacing: 12) {
                            Image(systemName: isOwner ? "trash" : "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(width: 28)
                            Text(isOwner ? "Deleting is permanent." : "You can be invited again later.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 16)
                            Button("All Teams") { onShowAllTeams() }
                                .buttonStyle(.bordered)
                            if isOwner {
                                Button("Delete Team…", role: .destructive) { isConfirmingDelete = true }
                                    .buttonStyle(.bordered)
                            } else {
                                Button("Leave Team…", role: .destructive) { isConfirmingLeave = true }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("General")
        .task(id: team.id) {
            nameText = team.name
            await vm.refreshTeamMembers(teamID: team.id)
        }
        .onChange(of: team.name) { _, name in nameText = name }
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamRosterDidChange)) { _ in
            Task {
                await vm.loadTeams()
                await vm.refreshTeamMembers(teamID: team.id)
            }
        }
        .alert("Leave \(team.name)?", isPresented: $isConfirmingLeave) {
            Button("Leave Team", role: .destructive) {
                Task { await vm.leaveTeam(team.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The team's copies are removed from this Mac. Your own sources, notebooks, Pages and chats stay in My Library.")
        }
        .alert("Delete \(team.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete Team", role: .destructive) {
                Task { await vm.deleteTeam(team.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The team and its copies are removed for every member. Everyone's originals stay in their own library.")
        }
    }

    private func standing(for team: TeamRecord, isOwner: Bool, memberCount: Int) -> String {
        var parts = [isOwner ? "You own this team" : "You are a member"]
        parts.append(team.canEdit ? "read and write" : "read only")
        parts.append(memberCount == 1 ? "1 member" : "\(memberCount) members")
        return parts.joined(separator: " · ")
    }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nameRow(for team: TeamRecord, isOwner: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: team.canEdit ? "person.2.fill" : "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(team.canEdit ? Color.green : Color.secondary)
                .frame(width: 28)
            if isOwner {
                TextField("Team name", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(team) }
                Button("Rename") { commitRename(team) }
                    .buttonStyle(.bordered)
                    .disabled(trimmedName.isEmpty || trimmedName == team.name)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name)
                        .font(.headline)
                    Text("Only the owner can rename the team.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func commitRename(_ team: TeamRecord) {
        let name = trimmedName
        guard !name.isEmpty, name != team.name else { return }
        Task { await vm.renameTeam(team.id, name: name) }
    }
}

/// <Team> Settings → Members: the roster Apple's share notebooks, and
/// the sharing sheet that changes it. Who is in the team and what each person
/// may do is read from the share, never from anything ForeverLM stores.
struct TeamMembersSettingsDetailView: View {
    @Environment(StudioViewModel.self) private var vm
    let onShowAllTeams: () -> Void

    var body: some View {
        if let team = vm.activeTeam {
            content(for: team)
        } else {
            NoOpenTeamView(onShowAllTeams: onShowAllTeams)
                .navigationTitle("Members")
        }
    }

    private func content(for team: TeamRecord) -> some View {
        let isOwner = team.role == .owner
        let members = vm.members(of: team.id).filter { $0.acceptanceStatus != "removed" }
        let pending = members.filter { $0.acceptanceStatus == "pending" }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    eyebrow: teamEyebrow(team),
                    title: "Members",
                    description: membersDescription(count: members.count, pending: pending)
                ) {
                    SettingsCard {
                        if members.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                Text("The roster arrives from iCloud once the team has been shared.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(members) { member in
                                    TeamMemberRow(member: member)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                FamilyPlanSettingsSection(team: team, members: members)

                SettingsSection(
                    title: "Inviting and removing",
                    description: isOwner
                        ? "Apple's sharing sheet is where people are invited by name, email or phone number, given edit or view access, or removed."
                        : "Only the owner can invite or remove members. Ask them, or share the invitation link."
                ) {
                    SettingsCard {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(width: 28)
                            Text(isOwner ? "Changes made in the sheet appear here as iCloud delivers them." : "The link is in the team's General settings.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 16)
                            if isOwner {
                                Button("Manage Members…") {
                                    TeamSharingService.shared.presentMembers(for: team)
                                }
                                .buttonStyle(.borderedProminent)
                                .help("Invite people by name or email, or change what they may do")
                            } else {
                                Button("All Teams") { onShowAllTeams() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Members")
        .task(id: team.id) {
            await vm.refreshTeamMembers(teamID: team.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamRosterDidChange)) { _ in
            Task {
                await vm.loadTeams()
                await vm.refreshTeamMembers(teamID: team.id)
            }
        }
    }

    private func membersDescription(count: Int, pending: Int) -> String {
        var text = count == 1 ? "1 member" : "\(count) members"
        if pending > 0 {
            text += pending == 1 ? ", 1 invitation pending" : ", \(pending) invitations pending"
        }
        return text + ". The roster is Apple's participant list for the team's share."
    }
}
