import SwiftUI

// Assignments and family plans on the Mac (docs/family-design.md).

// MARK: - Assign to ▸

/// "Assign to ▸", beside Share with Team on source rows and Doc menus. Lists
/// every editable team's other members, grouped by team when there is more
/// than one; picking a person copies the item into their team and puts it on
/// the team's Assignments board for them. Draws nothing when no team has
/// anyone to assign to.
struct AssignToMemberMenu: View {
    @Environment(StudioViewModel.self) private var vm
    var precededByDivider = false
    let assign: (TeamMemberRecord) -> Void

    var body: some View {
        let teams = vm.assignableTeams
        if !teams.isEmpty {
            if precededByDivider { Divider() }
            Menu {
                if teams.count == 1, let only = teams.first {
                    memberButtons(only.members)
                } else {
                    ForEach(teams) { entry in
                        Section(entry.team.name) {
                            memberButtons(entry.members)
                        }
                    }
                }
            } label: {
                Label("Assign to", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
    }

    private func memberButtons(_ members: [TeamMemberRecord]) -> some View {
        ForEach(members) { member in
            Button(member.displayName) { assign(member) }
        }
    }
}

// MARK: - Assigned to you (Today panel)

/// What other members assigned to this account, at the top of the Today
/// panel. A row opens the source or Doc; its circle ticks it done by hand,
/// though reading the source to the end or reviewing it does that by itself.
/// Finished today stays listed, checked, until tomorrow.
struct AssignedToYouSection: View {
    @Environment(StudioViewModel.self) private var vm

    var body: some View {
        Group {
            if !vm.assignedToMe.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assigned to you")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(vm.assignedToMe) { assignment in
                        AssignedTaskRow(assignment: assignment)
                    }
                }
            }
        }
        .task { await vm.refreshAssignedToMe() }
        .onReceive(NotificationCenter.default.publisher(for: .cloudKitSyncStoreDidChange)) { _ in
            Task { await vm.refreshAssignedToMe() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.scheduleFamilyPlanSync()
        }
    }
}

private struct AssignedTaskRow: View {
    @Environment(StudioViewModel.self) private var vm
    let assignment: AssignedTask

    private var title: String {
        assignment.sourceTitle ?? assignment.artifactTitle ?? assignment.task.title
    }

    private var detail: String {
        var parts: [String] = []
        if let by = assignment.task.createdByDisplayName, !by.isEmpty {
            parts.append("From \(by)")
        } else {
            parts.append(assignment.teamName)
        }
        if let due = assignment.task.dueAt {
            parts.append("due " + due.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await vm.setAssignment(assignment, done: !assignment.isDone) }
            } label: {
                Image(systemName: assignment.isDone ? "checkmark.circle.fill" : "circle")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(assignment.isDone ? .green : .secondary)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .disabled(!assignment.teamCanEdit)
            .help(assignment.isDone ? "Mark as not done" : "Mark as done")

            Button {
                Task { await vm.openAssignment(assignment) }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .zoomedSystemFont(size: 12)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .strikethrough(assignment.isDone, color: .secondary)
                        Text(detail)
                            .zoomedSystemFont(size: 10)
                            .foregroundStyle(assignment.task.isOverdue ? .red : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Family plan (team Settings → Members)

/// The family plan for the open team. The owner turns it on and connects an
/// OpenRouter key for each member; a member sees whether it covers them.
struct FamilyPlanSettingsSection: View {
    @Environment(StudioViewModel.self) private var vm
    let team: TeamRecord
    let members: [TeamMemberRecord]

    @State private var isChanging = false
    @State private var connectingMemberID: String?

    var body: some View {
        Group {
            if team.role == .owner {
                ownerSection
            } else if team.isFamily {
                memberSection
            }
        }
        .task(id: team.familyPlanCode) { await vm.refreshFamilyPlanStatus() }
    }

    // MARK: Owner

    private var ownerSection: some View {
        SettingsSection(
            title: "Family plan",
            description: "Your plan covers everyone in \(team.name). Each person's AI runs on an OpenRouter key you connect for them, billed to your OpenRouter account."
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { team.isFamily },
                        set: { enabled in
                            isChanging = true
                            Task {
                                await vm.setFamilyPlan(teamID: team.id, enabled: enabled)
                                isChanging = false
                            }
                        }
                    )) {
                        Text("Pay for members' AI")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)
                    .disabled(isChanging)

                    if team.isFamily {
                        Divider()
                        ForEach(coveredMembers, id: \.userRecordName) { member in
                            memberRow(member)
                        }
                        Link("Set a monthly limit for each key at openrouter.ai",
                             destination: URL(string: "https://openrouter.ai/settings/keys")!)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var coveredMembers: [TeamMemberRecord] {
        members.filter { $0.role != .owner && !$0.isCurrentUser }
    }

    private var joined: [FamilyPlanClient.Member] {
        vm.familyPlanStatus?.family(teamID: team.id)?.members ?? []
    }

    private func joinedRecord(for member: TeamMemberRecord) -> FamilyPlanClient.Member? {
        joined.first { $0.cloudKitUserRecordName == member.userRecordName }
    }

    private func memberRow(_ member: TeamMemberRecord) -> some View {
        let record = joinedRecord(for: member)
        return HStack(spacing: 10) {
            TeamMemberAvatar(initials: member.initials, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .font(.subheadline)
                Text(record == nil
                     ? "Joins when their Mac opens ForeverLM"
                     : record?.hasKey == true ? "Key connected" : "Needs a key")
                    .font(.caption)
                    .foregroundStyle(record?.hasKey == true ? .green : .secondary)
            }
            Spacer(minLength: 12)
            if let record {
                Button(record.hasKey ? "Replace Key…" : "Connect Key…") {
                    connectKey(for: record, name: member.displayName)
                }
                .buttonStyle(.bordered)
                .disabled(connectingMemberID != nil)
                .help("Sign in to OpenRouter and make a key for \(member.displayName)")
            }
        }
    }

    private func connectKey(for record: FamilyPlanClient.Member, name: String) {
        connectingMemberID = record.memberID
        Task {
            defer { connectingMemberID = nil }
            do {
                let label = "ForeverLM · \(name)"
                let key = try await OpenRouterConnect.connect(keyLabel: label)
                try await FamilyPlanClient.giveKey(key, to: record, label: label)
                await vm.refreshFamilyPlanStatus()
                vm.showToast("\(name)'s key is connected")
            } catch {
                vm.showToast(error.localizedDescription)
            }
        }
    }

    // MARK: Member

    private var memberSection: some View {
        let membership = vm.familyPlanStatus?.membership
        let owner = members.first { $0.role == .owner }?.displayName ?? "The owner"
        let line: String = {
            guard let membership, membership.teamID == team.id else {
                return "\(owner)'s plan covers this team. Your Mac joins it by itself."
            }
            if !membership.covered { return "\(owner)'s plan has lapsed, so it covers no one right now." }
            return membership.key == nil
                ? "\(owner)'s plan covers you. Your AI starts once they connect a key for you."
                : "\(owner)'s plan covers you, and your AI runs on the key they connected."
        }()
        return SettingsSection(title: "Family plan", description: line) {
            EmptyView()
        }
        .onAppear { vm.scheduleFamilyPlanSync(force: true) }
    }
}
