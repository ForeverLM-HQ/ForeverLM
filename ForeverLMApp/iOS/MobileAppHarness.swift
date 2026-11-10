#if DEBUG
import OSLog
import SwiftUI

// `-foreverlm-uitest-app`: the whole app (`MobileAudioReviewView` and every screen it pushes) over a
// library made on the spot, with no account and no iCloud, so Home, Notebooks, a notebook, the Library,
// To Read, the Reader, Memory, the card review and Settings can be looked at in a Simulator. The other
// previews show one screen each; this one is the app as a signed-in learner has it.
//
// The library is the Space preview's (`MobileSpaceHarnessLibrary`: a replica in memory, written through
// the phone's own writer, a server stood in for) with sources, notebooks and cards added the same way.
// While it is installed the catalog, the writer, the satellites and the Space's store read and write
// that replica instead of the sync session's (`backend`), so what a screen changes shows on the next
// screen, and nothing leaves the process.
//
// - `-foreverlm-uitest-app-open <url>` follows a link once the library is made, as a tap on a widget
//   would: `foreverlm://review`, `foreverlm://notebook/<id>`, `foreverlm://source/<id>`. The sample
//   ids are `harness-notebook` and `harness-src-…` below.
enum MobileAppHarness {
    static let launchArgument = "-foreverlm-uitest-app"
    static let openArgument = "-foreverlm-uitest-app-open"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Whether any preview stands in for the app. None of them syncs: the unsigned Simulator build they
    /// run in has no iCloud, and CloudKit traps rather than throws on a container it will not serve.
    static var standsInForTheApp: Bool {
        isEnabled || MobileHomeHarness.isEnabled || MobileSpaceHarness.isEnabled || MobilePageEditorHarness.isEnabled
            || ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-voice-surface")
    }

    /// What the app reads and writes while the preview runs.
    struct Backend: Sendable {
        let projection: MobileProjection
        let writer: MobileRecordWriter
        let satellites: MobileSatellites
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: Backend?

    /// The sample library, once made; nil outside the preview.
    static var backend: Backend? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    /// Makes the sample library and puts it in the session's place.
    @MainActor
    static func install() async throws {
        let library = try await MobileSpaceHarnessLibrary.make()
        try await Samples.write(into: library.writer)
        for sample in Samples.sources {
            if let text = sample.text {
                await MobileCloudSourceTextStore.shared.storeSourceText(text, sourceID: sample.id)
            }
        }
        backend = Backend(projection: library.projection, writer: library.writer, satellites: library.satellites)
    }
}

/// The preview on screen: the shell, once its library is made and loaded.
struct MobileAppHarnessView: View {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "AppHarness")

    @EnvironmentObject private var viewModel: MobileAudioReviewViewModel
    @State private var isReady = false
    @State private var failure: String?

    var body: some View {
        Group {
            if isReady {
                MobileAudioReviewView()
            } else if let failure {
                ContentUnavailableView("The sample library could not be made", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task {
            guard !isReady else { return }
            do {
                try await MobileAppHarness.install()
                // Anything the view model tried before the library existed found no session and said
                // so; that is the preview's own doing, not something to show over the screens.
                viewModel.errorMessage = nil
                await viewModel.load(forceRefresh: true)
                isReady = true
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: MobileAppHarness.openArgument),
                   ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                   let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]),
                   let link = MobileDeepLink.parse(url) {
                    viewModel.pendingDeepLink = link
                }
            } catch {
                Self.logger.error("app harness: \(String(describing: error), privacy: .public)")
                failure = String(describing: error)
            }
        }
        .accessibilityIdentifier("app.harness")
    }
}

// MARK: - The sample library

private extension MobileAppHarness {
    struct Source {
        let id: String
        let type: String
        let title: String
        var authors: [String] = []
        var venue: String?
        var url: String?
        var year: Int?
        var words: Int?
        var minutes: Int?
        /// Days before now it was added.
        let addedDaysAgo: Double
        var isPaywalled = false
        var isRead = false
        var summary: String?
        var text: String?
    }

    struct Notebook {
        let title: String
        var summary: String?
        let sourceIDs: [String]
    }

    enum Samples {
        static let sources: [Source] = [
            Source(id: "harness-src-mitchell", type: "paper",
                   title: "Coupling of phosphorylation to electron and hydrogen transfer by a chemi-osmotic type of mechanism",
                   authors: ["Mira Okafor"], venue: "Journal of Bioenergetics", url: "https://example.org/chemiosmotic", year: 2019,
                   words: 6_400, addedDaysAgo: 0.2,
                   summary: "Proposes that a proton gradient across the membrane, not a chemical intermediate, couples respiration to ATP synthesis.",
                   text: Texts.chemiosmosis),
            Source(id: "harness-src-rotary", type: "paper", title: "The rotary mechanism of ATP synthase",
                   authors: ["Jonas Lindqvist", "Aiko Tanabe"], venue: "Annual Review of Cell Machines", url: "https://example.org/rotary",
                   year: 2021, words: 9_100, addedDaysAgo: 1.1, isRead: true, text: Texts.rotary),
            Source(id: "harness-src-cristae", type: "paper", title: "Cristae shape determines respiratory chain supercomplex assembly",
                   authors: ["Leila Haddad", "Tomás Rey", "Ines Vogt"], venue: "Cell Structure", url: "https://example.org/cristae",
                   year: 2023, addedDaysAgo: 3, isPaywalled: true),
            Source(id: "harness-src-essay", type: "article", title: "Why your cells run on a battery",
                   authors: ["Noor Castellanos"], venue: "The Bench Notebook", url: "https://example.org/essays/cell-battery",
                   year: 2025, words: 2_300, addedDaysAgo: 0.6, text: Texts.essay),
            Source(id: "harness-src-power", type: "article", title: "A field guide to statistical power",
                   authors: ["Petra Halloran"], venue: "Methods Weekly", url: "https://example.org/power", year: 2024,
                   words: 3_800, addedDaysAgo: 5, text: Texts.power),
            Source(id: "harness-src-long", type: "article",
                   title: "What we still do not understand about how mitochondria decide when to divide, fuse, move and die, and why it matters for ageing",
                   authors: ["Sven Aaltonen"], venue: "Long Reads in Biology", url: "https://example.org/long", year: 2025,
                   words: 11_200, addedDaysAgo: 9),
            Source(id: "harness-src-podcast-1", type: "podcast", title: "Episode 41: The proton motive force, explained",
                   authors: ["Dana Whitlock"], venue: "Small Machines", url: "https://example.org/podcast/41", year: 2025,
                   minutes: 58, addedDaysAgo: 2, text: Texts.podcast),
            Source(id: "harness-src-podcast-2", type: "podcast", title: "Episode 42: Brown fat and the heat it makes",
                   authors: ["Dana Whitlock"], venue: "Small Machines", url: "https://example.org/podcast/42", year: 2025,
                   minutes: 64, addedDaysAgo: 1.5),
            Source(id: "harness-src-video", type: "video", title: "Lecture 7: Oxidative phosphorylation",
                   authors: ["Ravi Menon"], venue: "Cell Biology 101", url: "https://example.org/lecture-7", year: 2024,
                   minutes: 47, addedDaysAgo: 12, isRead: true),
            Source(id: "harness-src-bioelectric", type: "paper", title: "Bioelectric signalling in regeneration",
                   authors: ["Yuki Brandt"], venue: "Developmental Signals", url: "https://example.org/bioelectric", year: 2022,
                   words: 7_700, addedDaysAgo: 20, text: Texts.bioelectric),
        ]

        static let notebooks: [Notebook] = [
            Notebook(title: "Mitochondria", summary: "How cells turn food and oxygen into ATP.",
                     sourceIDs: ["harness-src-mitchell", "harness-src-rotary", "harness-src-cristae", "harness-src-essay",
                                 "harness-src-podcast-1", "harness-src-video"]),
            Notebook(title: "Power analysis", sourceIDs: ["harness-src-power"]),
            Notebook(title: "Bioelectricity", summary: "Voltage as a signal in development.", sourceIDs: ["harness-src-bioelectric"]),
            Notebook(title: "Reading for the spring seminar on energy metabolism and ageing", sourceIDs: []),
        ]

        /// Cards kept on the chemiosmosis paper and the rotary one: a front, and the idea as the back.
        static let cards: [(id: String, source: String, front: String, back: String, daysAgo: Double)] = [
            ("harness-card-1", "harness-src-mitchell", "What couples electron transport to ATP synthesis?",
             "A proton gradient across the inner membrane.", 6),
            ("harness-card-2", "harness-src-mitchell", "Why must the inner membrane be impermeable to protons?",
             "A leak would spend the gradient as heat instead of ATP.", 6),
            ("harness-card-3", "harness-src-rotary", "What turns the central stalk of ATP synthase?",
             "Protons flowing through the c-ring.", 4),
            ("harness-card-4", "harness-src-rotary", "How many ATP does one full turn of F1 release?", "Three.", 4),
            ("harness-card-5", "harness-src-essay", "What does an uncoupling protein do?",
             "Lets protons back across the membrane without making ATP, releasing heat.", 2),
        ]

        static func write(into writer: MobileRecordWriter) async throws {
            let now = Date()
            let device = writer.deviceID
            try await writer.transaction { write in
                for sample in sources {
                    try write.write(patch(for: sample, now: now, device: device), in: MobileProjection.catalogKey)
                    if sample.isRead {
                        var state = RecordPatch(.readingState, id: SyncIdentity.readingStateID(targetID: sample.id))
                        state.changes["targetKind"] = .value(.string("source"))
                        state.changes["targetID"] = .value(.string(sample.id))
                        state.changes["readAt"] = .value(SyncJSON(SyncTime.milliseconds(now.addingTimeInterval(-3_600))))
                        try write.write(state, in: MobileProjection.libraryKey)
                    }
                }
                for card in cards {
                    let made = now.addingTimeInterval(-card.daysAgo * 86_400)
                    let rubric: SyncJSON = .object([
                        "card": .object(["cardID": .string(card.id), "front": .string(card.front), "back": .string(card.back),
                                         "origin": .string("manual")]),
                        "criteria": .array([]),
                    ])
                    let item = MemoryItem(
                        id: card.id, kind: .concept, target: card.back,
                        rubricJSON: String(decoding: rubric.serialized(), as: UTF8.self),
                        sources: [MemoryItemSource(id: "\(card.id)-a", memoryItemID: card.id, sourceID: card.source,
                                                   excerpt: card.back, sourceSHA256: "harness", sortIndex: 0)],
                        createdAt: made, updatedAt: made
                    )
                    try write.write(MobileMemoryRecords.keptCardPatch(item), in: MobileProjection.libraryKey)
                }
            }
            // Oldest first, so the list reads newest first as a library that grew.
            for notebook in notebooks.reversed() {
                let id = try await writer.createNotebook(title: notebook.title, instructions: nil, summary: notebook.summary)
                if !notebook.sourceIDs.isEmpty {
                    try await writer.transaction { try $0.fileSources(notebook.sourceIDs, into: id) }
                }
            }
        }

        private static func patch(for sample: Source, now: Date, device: String) -> RecordPatch {
            let added = SyncTime.milliseconds(now.addingTimeInterval(-sample.addedDaysAgo * 86_400))
            let key = "native:\(sample.id)"
            var patch = RecordPatch(.source, id: sample.id)
            patch.changes["primaryKey"] = .value(.string(key))
            patch.changes["workKeys"] = .elements([key: .bool(true)])
            patch.changes["type"] = .value(.string(sample.type))
            patch.changes["title"] = .value(.string(sample.title))
            patch.changes["status"] = .value(.string("active"))
            patch.changes["addedAt"] = .value(SyncJSON(added))
            patch.changes["madeBy"] = .value(MadeBy(route: "ios", device: device, at: added).value)
            patch.changes["ingest"] = .value(.object([
                "ord": .array([0, SyncJSON(sample.isPaywalled ? 3 : 4)]), "state": .string(sample.isPaywalled ? "paywalled" : "ready"),
                "at": SyncJSON(added), "device": .string(device),
            ]))
            if !sample.authors.isEmpty { patch.changes["authors"] = .value(.array(sample.authors.map(SyncJSON.string))) }
            if let venue = sample.venue { patch.changes["venue"] = .value(.string(venue)) }
            if let url = sample.url { patch.changes["url"] = .value(.string(url)) }
            if let summary = sample.summary { patch.changes["summary"] = .value(.string(summary)) }
            if let year = sample.year,
               let date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: year, month: 6, day: 1)) {
                patch.changes["publishedAt"] = .value(SyncJSON(SyncTime.milliseconds(date)))
            }
            var metrics: [String: SyncJSON] = [:]
            if let words = sample.words { metrics["wordCount"] = SyncJSON(Int64(words)) }
            if let minutes = sample.minutes { metrics["durationSeconds"] = SyncJSON(Int64(minutes * 60)) }
            if let text = sample.text { metrics["textChars"] = SyncJSON(Int64(text.count)) }
            if !metrics.isEmpty { patch.changes["metrics"] = .value(.object(metrics)) }
            return patch
        }
    }

    enum Texts {
        static let chemiosmosis = """
        # Coupling of phosphorylation to electron and hydrogen transfer

        ## Summary

        Respiration and ATP synthesis are coupled, but no chemical intermediate that carries the energy between them has been found. This paper proposes that the intermediate is not a molecule at all. It is a gradient of protons across the membrane.

        ## The proposal

        The respiratory chain is arranged across the inner membrane so that, as electrons pass along it, protons are carried from the inside to the outside. The membrane itself does not let protons back. The result is a difference in both pH and electrical potential across the membrane, which together we call the proton motive force.

        The ATP synthase sits in the same membrane. It lets protons return, and uses their passage to drive the synthesis of ATP from ADP and phosphate.

        ## What the proposal predicts

        1. The membrane must be closed and impermeable to protons. A leak would spend the gradient as heat.
        2. Compounds that carry protons across the membrane should uncouple respiration from phosphorylation.
        3. An artificial gradient, imposed from outside, should make ATP with no respiration at all.

        Each of these was later observed. The third is the most striking: vesicles moved from an acid bath to an alkaline one make ATP in the dark.

        ## Discussion

        The idea was resisted for a decade, largely because it replaced a chemical question with a spatial one. What matters is not which molecule holds the energy but which side of the membrane the protons are on.
        """

        static let rotary = """
        # The rotary mechanism of ATP synthase

        ATP synthase is a motor. Its membrane part, Fo, holds a ring of c subunits that turns as protons pass through it. The ring is attached to a central stalk, and the stalk turns inside the catalytic head, F1.

        ## Binding change

        F1 has three catalytic sites. At any moment one is open, one holds ADP and phosphate loosely, and one holds them tightly enough that ATP forms. The stalk is asymmetric, so each third of a turn pushes every site into the next state. One full turn releases three ATP.

        ## Seeing it turn

        The rotation was shown directly by fixing F1 to a glass slide and attaching a fluorescent filament to the stalk. Fed ATP, the filament turned, in steps of 120 degrees.
        """

        static let essay = """
        # Why your cells run on a battery

        Every cell in your body keeps a voltage across a membrane a few nanometres thick. Scaled up, the field is as strong as a bolt of lightning.

        The voltage is made by pumping protons. Burning food releases electrons, and as they fall toward oxygen the cell uses the energy to push protons out of the mitochondrion's inner compartment. The protons want back in. The only door is a turbine.

        ## The turbine

        That turbine is ATP synthase. Each proton that passes turns it a notch, and every third of a turn snaps a phosphate onto ADP. You make roughly your own body weight in ATP every day this way.

        ## Wasting it on purpose

        Brown fat has a second door, an uncoupling protein, that lets protons back without turning anything. The energy becomes heat. It is how a newborn stays warm.
        """

        static let power = """
        # A field guide to statistical power

        Power is the chance that a study finds an effect that is really there. It depends on four things: the size of the effect, the noise, the sample size and the threshold you set for calling a result significant.

        ## Why it matters

        An underpowered study that finds something has probably overestimated it. Only the lucky draws cross the threshold, and the lucky draws are the large ones.

        ## Before you collect data

        Decide the smallest effect you would care about. Estimate the noise from earlier work. Then solve for the sample size that gives you an 80 or 90 per cent chance of seeing it.
        """

        static let podcast = """
        Welcome back to Small Machines. Today: the proton motive force.

        So here is the picture. You have a membrane, and you have more protons on one side than the other. That is a store of energy, exactly as water behind a dam is.

        And the thing people miss is that there are two parts to it. There is the concentration difference, the pH, and there is the charge. In mitochondria most of it is charge. In chloroplasts most of it is pH.

        Right, and the membrane has to be tight. If it leaks you get heat. Which, as we will get to next week, is sometimes the point.
        """

        static let bioelectric = """
        # Bioelectric signalling in regeneration

        Cells that are not neurons also keep a resting potential, and groups of cells joined by gap junctions share it. The pattern of voltage across a tissue changes before the anatomy does.

        ## Evidence

        In flatworms, briefly changing the voltage pattern of a cut fragment changes what it regrows: a head where a tail was due. The genome is unchanged. The pattern, once set, is remembered through later rounds of regeneration.

        ## Open questions

        How a voltage pattern is read out into gene expression is only partly known. Calcium entry and the movement of small signalling molecules through gap junctions are both involved.
        """
    }
}
#endif
