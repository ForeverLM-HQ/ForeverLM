#if DEBUG
import SwiftUI

// `-foreverlm-uitest-home`: Home (`MobileHomeDashboard`) with no account and no iCloud, for a
// Simulator screenshot of Home. The menu's items push a stand-in screen naming the route Home
// would open, through a NavigationStack path as the shell's (`MobileAudioReviewView`), so a tap
// shows the menu works; voice goes nowhere.
enum MobileHomeHarness {
    static let launchArgument = "-foreverlm-uitest-home"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

/// The harness on screen: Home as the shell draws it, with no navigation bar.
struct MobileHomeHarnessView: View {
    @State private var path: [MobileShellRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            MobileHomeDashboard(
                showsSpaces: true,
                recents: [
                    MobileHomeRecent(id: "n1", title: "Mitochondrial disease programs"),
                    MobileHomeRecent(id: "n2", title: "Power analysis"),
                    MobileHomeRecent(id: "n3", title: "Bioelectricity"),
                ],
                actions: MobileHomeActions(open: { path.append($0) }, talk: {}, send: { _ in })
            ) {
                EmptyView()
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MobileShellRoute.self) { route in
                ContentUnavailableView(
                    "Opened",
                    systemImage: "checkmark.circle",
                    description: Text(String(describing: route))
                )
                .navigationTitle("Stand-in")
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("home.harness.destination")
            }
        }
    }
}
#endif
