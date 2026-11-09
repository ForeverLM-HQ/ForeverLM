#if DEBUG
import SwiftUI

// `-foreverlm-uitest-home`: Home (`MobileHomeDashboard`) with sample counts, with no account and no
// iCloud, for a Simulator screenshot of Home. The buttons go nowhere.
//
// - `-foreverlm-uitest-home-caught-up` draws the day with no cards waiting.
enum MobileHomeHarness {
    static let launchArgument = "-foreverlm-uitest-home"
    static let caughtUpArgument = "-foreverlm-uitest-home-caught-up"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var isCaughtUp: Bool {
        ProcessInfo.processInfo.arguments.contains(caughtUpArgument)
    }
}

/// The harness on screen: Home as the shell draws it, with no navigation bar.
struct MobileHomeHarnessView: View {
    private var cards: MemoryCardDayCounts {
        MobileHomeHarness.isCaughtUp
            ? MemoryCardDayCounts(due: 0, new: 0, practice: 6, toCheck: 1026)
            : MemoryCardDayCounts(due: 26, new: 4, practice: 0, toCheck: 1026)
    }

    var body: some View {
        NavigationStack {
            MobileHomeDashboard(
                cards: cards,
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
