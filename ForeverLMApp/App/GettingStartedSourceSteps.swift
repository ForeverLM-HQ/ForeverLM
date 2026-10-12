import AppKit
import SwiftUI

// The parts of Setup's Podcasts, Articles and Papers steps that do the work
// end to end (product owner, 2026-09-24): the learner decides what comes in before
// anything is imported, brings a library over from where it lives today, and
// sees the fetching and AI cleanup that follow run to the end. Each view keeps
// its own state, so GettingStartedGuide only places them.

private extension View {
    func sourceSetupCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Podcasts

/// What becomes of one Apple Podcasts show. Keep imports the episodes the
/// learner plays; Hide imports them out of sight (no chat, search, reviews or
/// transcript cleanup, so no AI spend); Don't import never creates them.
enum PodcastShowSetupChoice: String, CaseIterable, Identifiable {
    case keep
    case hide
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep"
        case .hide: return "Hide"
        case .skip: return "Don't import"
        }
    }
}

extension StudioViewModel {
    /// The choice a show currently reads as, from the two lists that already
    /// steer Apple Podcasts: blocked shows are never imported, hidden ones are
    /// imported out of sight.
    func podcastSetupChoice(for show: String) -> PodcastShowSetupChoice {
        _ = blockedPodcastShowsVersion
        if isPodcastShowBlocked(show) { return .skip }
        let key = SourceDiscovery.podcastShowKey(show)
        if hiddenPodcastShows.contains(where: { SourceDiscovery.podcastShowKey($0) == key }) {
            return .hide
        }
        return .keep
    }

    /// Write a choice through the same setters the sidebar's show menu uses,
    /// so Setup cannot mean something different by "hide" or "block".
    func applyPodcastSetupChoice(_ choice: PodcastShowSetupChoice, to show: String) async {
        switch choice {
        case .keep:
            unblockPodcastShow(show, silently: true)
            await setPodcastShowHidden(show, hidden: false)
        case .hide:
            unblockPodcastShow(show, silently: true)
            await setPodcastShowHidden(show, hidden: true)
        case .skip:
            blockPodcastShow(show, silently: true)
            // Anything the show already has in the library leaves sight too.
            await setPodcastShowHidden(show, hidden: true)
        }
    }
}

/// Every show in the learner's Apple Podcasts library, read before the first
/// import, each with Keep, Hide or Don't import. Setup starts the import only
/// when the learner moves on, so nothing is fetched or cleaned up for a show
/// they turned away.
struct PodcastShowChooser: View {
    @Environment(StudioViewModel.self) private var vm
    /// The number of shows found, or nil until Apple Podcasts has been read.
    @Binding var showCount: Int?

    @State private var shows: [SourceDiscovery.PodcastShowInventoryItem] = []
    @State private var status: PodcastDiscoveryStatus?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your shows in Apple Podcasts")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                if shows.count > 1 {
                    Menu("Set All") {
                        ForEach(PodcastShowSetupChoice.allCases) { choice in
                            Button(choice.title) { setAll(choice) }
                        }
                    }
                    .fixedSize()
                }
                Button("Look Again") { Task { await load() } }
                    .disabled(isLoading)
            }

            if shows.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(shows) { show in
                    row(show)
                }
                Text("Hidden shows stay out of chat, search and reviews, and their transcripts are not cleaned up. Change any of this later from a show's menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sourceSetupCard()
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from Apple Podcasts: a show just followed or played shows up.
            Task { await load() }
        }
    }

    private func row(_ show: SourceDiscovery.PodcastShowInventoryItem) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: show.artworkURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(show.name)
                    .lineLimit(1)
                Text(detail(for: show))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker(show.name, selection: choiceBinding(show.name)) {
                ForEach(PodcastShowSetupChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
        }
    }

    private func detail(for show: SourceDiscovery.PodcastShowInventoryItem) -> String {
        switch show.importableEpisodeCount {
        case 0: return show.isFollowed ? "Followed · nothing played yet" : "Nothing played yet"
        case 1: return "1 episode played"
        default: return "\(show.importableEpisodeCount) episodes played"
        }
    }

    private var emptyMessage: String {
        switch status {
        case nil:
            return "Reading Apple Podcasts…"
        case .appNotInstalled:
            return "Apple Podcasts has no library on this Mac yet. Follow or play a show there, then look again."
        case .permissionDenied:
            return "Full Disk Access is needed to read Apple Podcasts."
        case .ok, .noEpisodesFound:
            return "No shows yet. Follow or play one in Apple Podcasts, then look again."
        case .unsupportedPlatform:
            return "Apple Podcasts can only be read on a Mac."
        case .openFailed(let details), .schemaChanged(let details):
            return "Apple Podcasts could not be read: \(details)"
        }
    }

    private func choiceBinding(_ show: String) -> Binding<PodcastShowSetupChoice> {
        Binding(
            get: { vm.podcastSetupChoice(for: show) },
            set: { choice in Task { await vm.applyPodcastSetupChoice(choice, to: show) } }
        )
    }

    private func setAll(_ choice: PodcastShowSetupChoice) {
        let names = shows.map(\.name)
        Task {
            for name in names {
                await vm.applyPodcastSetupChoice(choice, to: name)
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        let dbPath = StudioViewModel.applePodcastsDatabasePath(homeDir: BookmarkAccessManager.realHomeDirectory)
        let result = await Task.detached(priority: .userInitiated) {
            SourceDiscovery.podcastShowInventory(dbPath: dbPath)
        }.value
        shows = result.shows
        status = result.status
        showCount = result.shows.count
        isLoading = false
    }
}

// MARK: - Reading List

/// Which browsers' Reading Lists come in: one tile per browser, any number
/// ticked, the Mac's default marked Recommended. Nothing else is asked here.
/// How much of the backlog to bring is a Settings › Sources choice that starts
/// on the last 30 days, recorded before any browser can import.
struct ReadingListBrowserChoices: View {
    let isEnabled: (ReadingListBrowser) -> Binding<Bool>

    /// Record the default before any browser can import, so a Reading List
    /// turned on still brings only the last month, not a years-deep backlog to
    /// fetch and clean up.
    static func holdDefaultWindowIfUnchosen() {
        guard SourceDiscovery.ReadingListImportWindow.chosen == nil else { return }
        SourceDiscovery.ReadingListImportWindow.choose(.lastMonth)
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ReadingListBrowser.allCases) { browser in
                tile(browser)
            }
        }
        .task { Self.holdDefaultWindowIfUnchosen() }
    }

    private func tile(_ browser: ReadingListBrowser) -> some View {
        let binding = isEnabled(browser)
        let isSelected = binding.wrappedValue
        return Button {
            binding.wrappedValue.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(browser.logoAssetName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                Text(browser.title)
                    .font(.headline)
                if browser == ReadingListBrowser.systemDefault {
                    RecommendedBadge()
                } else {
                    // Keeps the three tiles one height.
                    RecommendedBadge().hidden()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0))
        .accessibilityLabel(browser.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Zotero

/// Zotero keeps its library in a SQLite file on this Mac, so Setup can find it
/// and bring it over in one click instead of asking for an export. The move is
/// one-time; Zotero is opened read-only and never changed.
struct ZoteroImportCard: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var library: URL?
    @State private var paperCount: Int?
    @State private var pdfCount: Int?
    @State private var hasLooked = false
    @State private var isImporting = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let library {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Zotero", systemImage: "books.vertical")
                            .font(.headline)
                        if let paperCount {
                            Text(countText(papers: paperCount, pdfs: pdfCount ?? 0))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            importLibrary(library)
                        } label: {
                            if isImporting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(result == nil ? "Import from Zotero" : "Import Again")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting || vm.isImportingReferenceLibrary || paperCount == 0)
                    }
                    Text(library.path.replacingOccurrences(of: BookmarkAccessManager.realHomeDirectory, with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isImporting, let status = vm.referenceLibraryImportStatus {
                        Label(status, systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let result {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .sourceSetupCard()
            }
        }
        .task { await locate() }
    }

    private func countText(papers: Int, pdfs: Int) -> String {
        let paperText = papers == 1 ? "1 paper" : "\(papers) papers"
        return pdfs == papers ? paperText : "\(paperText), \(pdfs) with a PDF"
    }

    private func locate() async {
        guard !hasLooked else { return }
        hasLooked = true
        let homeDir = BookmarkAccessManager.realHomeDirectory
        let found = await Task.detached(priority: .utility) { () -> (URL, Int, Int)? in
            guard let directory = ReferenceLibraryImportService.zoteroDataDirectory(homeDir: homeDir),
                  let inventory = try? ReferenceLibraryImportService.inventory(from: [directory]) else {
                return nil
            }
            let pdfs = inventory.entries.filter { $0.pdfPath != nil }.count
            return (directory, inventory.entries.count, pdfs)
        }.value
        guard let found else { return }
        library = found.0
        paperCount = found.1
        pdfCount = found.2
    }

    private func importLibrary(_ directory: URL) {
        isImporting = true
        result = nil
        error = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let report = try await vm.importReferenceLibrary(from: [directory])
                result = report.summary
                if !report.warnings.isEmpty {
                    let shown = report.warnings.prefix(3).joined(separator: "\n")
                    let more = report.warnings.count > 3 ? "\n…and \(report.warnings.count - 3) more" : ""
                    error = shown + more
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Cleanup progress

/// How far the sources a step brought in have got: fetched and cleaned up,
/// still on their way (including cleanup waiting to retry), or failed, and
/// which model does the cleanup and who pays for it. Setup does not wait for
/// it; the learner sees it running before moving on.
struct SourceCleanupProgress: View {
    let types: Set<StudioSourceType>
    let task: AITask

    @Environment(StudioViewModel.self) private var vm
    @Environment(ManagedAIAccountModel.self) private var account

    var body: some View {
        let sources = vm.activeArticles.filter { types.contains($0.sourceType) && !vm.isSourceCollectionHidden($0) }
        if !sources.isEmpty {
            let ready = sources.filter { $0.state == .ready }.count
            let failed = sources.filter { $0.state == .error }.count
            let underway = sources.count - ready - failed
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if underway > 0 {
                        ProgressView(value: Double(ready), total: Double(sources.count))
                            .frame(maxWidth: 180)
                    } else {
                        Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(failed == 0 ? Color.green : Color.orange)
                    }
                    Text(summary(total: sources.count, ready: ready, underway: underway, failed: failed))
                        .font(.caption)
                        .monospacedDigit()
                }
                Text(modelLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sourceSetupCard()
        }
    }

    private func summary(total: Int, ready: Int, underway: Int, failed: Int) -> String {
        if underway == 0 && failed == 0 { return "All \(total) ready" }
        var parts = ["\(ready) of \(total) ready"]
        if underway > 0 { parts.append("\(underway) still coming in, in the background") }
        if failed > 0 { parts.append("\(failed) could not be fetched; retry them from the Library later") }
        return parts.joined(separator: " · ")
    }

    /// Named from the route cleanup will actually take, so a learner on the
    /// free models reads that it costs nothing and anyone else reads which
    /// model their key (or leftover balance) pays for.
    private var modelLine: String {
        guard KeychainService.resolveConfig(for: task) != nil else {
            return "Cleanup waits until AI is set up in Settings › AI Usage."
        }
        let selection = KeychainService.resolvedSelection(for: task)
        let name = AIModelCatalog.displayName(provider: selection.provider, modelID: selection.model)
        if AIFreeModels.isFreeSelection(provider: selection.provider, model: selection.model) {
            return "Cleaned up by \(name), a free model. Busy moments are retried on their own."
        }
        let payer = account.ownKey != nil && account.ownKeyAllowed ? "your OpenRouter key" : "your leftover AI balance"
        return "Cleaned up by \(name), paid from \(payer)."
    }
}
