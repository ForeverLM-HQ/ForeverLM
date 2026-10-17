import SwiftUI

/// "Share with Team ▸", rendered the same way at every site that offers it:
/// source rows, Notebook rows and pages, Doc menus and chat rows. The list is
/// the teams this account may write into; a site only says what to copy once
/// a team is picked.
///
/// Sharing goes from My Library into a team, never the other way, so the menu
/// draws nothing while a team is the active library — except where the item
/// is still the learner's own: a team library lists the learner's own sources
/// (docs/teams-design.md, decision 19), and those rows pass
/// `offeredInTeamLibrary`. Sites that follow it with a divider pass
/// `precededByDivider` so the divider disappears with it.
///
/// The menu only offers teams that exist. Creating one is the library
/// switcher's or Team Settings' job, so a share never turns into a naming
/// prompt; with no teams yet the menu points at Team Settings instead.
///
/// A share that copies sources to other people asks "Before you share" the
/// first time (`SharingRightsPrompt`, docs/teams-design.md decision 22), and
/// runs once the learner affirms. A chat's transcript carries no source, so
/// its site passes `asksSharingRights` false, and so does a notebook's Share
/// popover, which asks in its own place.
struct ShareWithTeamMenu: View {
    @Environment(StudioViewModel.self) private var vm
    var title = "Share with Team"
    var systemImage = "person.2"
    var precededByDivider = false
    /// The item is the learner's own even while a team library is open.
    var offeredInTeamLibrary = false
    /// Whether choosing a team asks "Before you share" first: a source, a
    /// notebook, a Doc or a course copies sources into the team.
    var asksSharingRights = true
    /// Teams left off the list: those that already hold the item.
    var excludedTeamIDs: Set<String> = []
    /// Called with the chosen team's id.
    let share: (String) -> Void

    var body: some View {
        if vm.activeTeamID == nil || offeredInTeamLibrary {
            if precededByDivider { Divider() }
            Menu {
                let teams = vm.teamsAcceptingShares.filter { !excludedTeamIDs.contains($0.id) }
                if teams.isEmpty {
                    Text("No teams yet")
                    Button("Team Settings…", systemImage: "gearshape") {
                        NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.dataPrivacy)
                    }
                } else {
                    ForEach(teams) { team in
                        Button(team.name) {
                            if asksSharingRights {
                                SharingRightsPrompt.shared.askIfNeeded { share(team.id) }
                            } else {
                                share(team.id)
                            }
                        }
                    }
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }
}
