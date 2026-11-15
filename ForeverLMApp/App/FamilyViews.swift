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
