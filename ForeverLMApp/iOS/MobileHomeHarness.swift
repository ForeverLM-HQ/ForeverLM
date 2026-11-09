#if DEBUG
import SwiftUI

// `-foreverlm-uitest-home`: Home (`MobileHomeDashboard`) with no account and no iCloud, for a
// Simulator screenshot of Home. The buttons go nowhere.
enum MobileHomeHarness {
    static let launchArgument = "-foreverlm-uitest-home"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

/// The harness on screen: Home as the shell draws it, with no navigation bar.
struct MobileHomeHarnessView: View {
    var body: some View {
        NavigationStack {
            MobileHomeDashboard(
                showsSpaces: true,
                actions: MobileHomeActions(open: { _ in }, talk: {})
            ) {
                EmptyView()
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
#endif
