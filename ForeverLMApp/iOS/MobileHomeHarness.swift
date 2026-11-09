#if DEBUG
import SwiftUI

// `-foreverlm-uitest-home`: Home (`MobileHomeDashboard`) over a sample library, with no account and
// no iCloud, for a Simulator screenshot of Home. The buttons go nowhere.
//
// - `-foreverlm-uitest-home-caught-up` draws the day with nothing due.
enum MobileHomeHarness {
    static let launchArgument = "-foreverlm-uitest-home"
    static let caughtUpArgument = "-foreverlm-uitest-home-caught-up"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var isCaughtUp: Bool {
        ProcessInfo.processInfo.arguments.contains(caughtUpArgument)
    }

    static let notebooks: [MobileHomeNotebookItem] = {
        let now = Date()
        func item(_ id: String, _ title: String, sources: Int, hoursAgo: Double, overview: Bool = false) -> MobileHomeNotebookItem {
            MobileHomeNotebookItem(
                notebook: MobileCloudNotebook(id: id, title: title, instructions: nil, sourceIDs: [], isArchived: false, updatedAt: now),
                sourceCount: sources,
                lastActivity: now.addingTimeInterval(-hoursAgo * 3600),
                overviewSourceID: overview ? "\(id)-overview" : nil
            )
        }
        return [
            item("harness-mtdna", "⏳ mtDNA mutations and aging", sources: 28, hoursAgo: 13, overview: true),
            item("harness-agency", "🌱 Agency", sources: 3, hoursAgo: 24 * 14),
            item("harness-del", "🧪 DNA-encoded libraries", sources: 22, hoursAgo: 24 * 21),
            item("harness-bioelectricity", "⚡️ Bioelectricity", sources: 14, hoursAgo: 24 * 30),
        ]
    }()
}

/// The harness on screen: Home's list and chrome around the dashboard.
struct MobileHomeHarnessView: View {
    @State private var query = ""

    private var cards: MemoryCardDayCounts {
        MobileHomeHarness.isCaughtUp
            ? MemoryCardDayCounts(due: 0, new: 0, practice: 6, toCheck: 1026)
            : MemoryCardDayCounts(due: 26, new: 4, practice: 0, toCheck: 1026)
    }

    var body: some View {
        NavigationStack {
            List {
                MobileHomeDashboard(
                    cards: cards,
                    notebooks: Array(MobileHomeHarness.notebooks.prefix(3)),
                    hasMoreNotebooks: true,
                    isSyncing: false,
                    showsSpaces: true,
                    actions: MobileHomeActions(
                        open: { _ in },
                        reviewByVoice: {},
                        talk: {},
                        newNotebook: {}
                    )
                ) { _ in EmptyView() }
            }
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .searchable(text: $query, prompt: "Search library and notebooks")
            .modifier(MobileHomeBottomBar())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
#endif
