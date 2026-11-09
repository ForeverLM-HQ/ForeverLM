#if DEBUG
import SwiftUI

// `-foreverlm-uitest-home`: Home (`MobileHomeDashboard`) over a sample library, with no account and
// no iCloud, for a Simulator screenshot of Home. The buttons go nowhere; Drive and Gym open their
// picker over sample sources.
//
// - `-foreverlm-uitest-home-caught-up` draws the day with nothing due.
// - `-foreverlm-uitest-home-picker gym|drive` opens that picker at once.
enum MobileHomeHarness {
    static let launchArgument = "-foreverlm-uitest-home"
    static let caughtUpArgument = "-foreverlm-uitest-home-caught-up"
    static let pickerArgument = "-foreverlm-uitest-home-picker"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var isCaughtUp: Bool {
        ProcessInfo.processInfo.arguments.contains(caughtUpArgument)
    }

    static var initialPicker: RealtimeVoiceOpening? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: pickerArgument), arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "gym": return .gym
        case "drive": return .talk
        default: return nil
        }
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

    static let sources: [MobileCloudSource] = {
        let now = Date()
        func source(_ id: String, _ title: String, _ type: String, author: String?, journal: String?, year: String?, daysAgo: Double) -> MobileCloudSource {
            var made = MobileCloudSource(
                id: id, title: title, subtitle: nil, sourceType: type,
                dateAdded: now.addingTimeInterval(-daysAgo * 86_400), hasAudio: false, isArchived: false
            )
            made.author = author
            made.journal = journal
            made.publishedYear = year
            return made
        }
        return [
            source("s1", "Oocytes maintain ROS-free mitochondrial metabolism by suppressing complex I", "paper", author: "Rodríguez-Nuevo et al.", journal: "Nature", year: "2022", daysAgo: 1),
            source("s2", "Clonal expansion of mtDNA deletions in aging muscle", "paper", author: "Herbst et al.", journal: "Aging Cell", year: "2021", daysAgo: 2),
            source("s3", "The Peter Attia Drive: Mitochondria and longevity", "podcast", author: nil, journal: nil, year: nil, daysAgo: 3),
            source("s4", "Bioelectric networks: the cognitive glue of life", "paper", author: "Levin", journal: "Biochim Biophys Acta", year: "2023", daysAgo: 6),
            source("s5", "How DNA-encoded libraries find drugs", "video", author: nil, journal: nil, year: nil, daysAgo: 9),
            source("s6", "The Selfish Gene", "book", author: "Dawkins", journal: nil, year: "1976", daysAgo: 30),
        ]
    }()
}

/// The harness on screen: Home's list and chrome around the dashboard.
struct MobileHomeHarnessView: View {
    @State private var picker: RealtimeVoiceOpening? = MobileHomeHarness.initialPicker
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
                    notebooks: MobileHomeHarness.notebooks,
                    hasMoreNotebooks: true,
                    isSyncing: false,
                    showsSpaces: true,
                    columns: 2,
                    actions: MobileHomeActions(
                        open: { _ in },
                        reviewByVoice: {},
                        talk: {},
                        pickSource: { picker = $0 },
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {} label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "plus") }
                        .accessibilityLabel("New notebook")
                }
            }
            .sheet(item: $picker) { opening in
                MobileVoiceSourcePicker(opening: opening, sources: MobileHomeHarness.sources) { _ in picker = nil }
            }
        }
    }
}
#endif
