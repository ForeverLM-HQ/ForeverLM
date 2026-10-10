import SwiftUI

/// The sources a paper or article cites, in a popover off the reader's overflow menu.
///
/// The same list the video readers show for the papers read off their slides, minus the
/// slide evidence: a reference entry or a link needs no frame beside it to be judged. Two
/// reads feed it, chosen by the source: a paper's reference list is read for the papers it
/// cites, and a web article's page is read for the sources its links point at — other
/// articles, papers, videos, podcasts. The list carries the one action that fills it, so a
/// source whose citations were never read is one click from having them, and a source
/// whose citations were read shows how many are still on offer.
///
/// The candidates and the scan flag belong to the reader panel, not to this view: the
/// overflow menu titles its item from them (Find Cited Papers or Find Linked Sources
/// before a read, the same name with the waiting count after), and the panel reloads them
/// whenever the view model says the set changed, which is how a scan started from the
/// sidebar shows up here.
///
/// The read reports into the panel's header — reading, then how many it found or why it
/// failed — rather than as a toast at the bottom of the window: the learner who clicked is
/// looking here. The report is cleared when the panel closes, so reopening it later does
/// not show a stale outcome; a read still running keeps its line.
struct CitedSourcesPopover: View {
    let article: StudioArticle
    @Binding var papers: [VideoCitedPaper]
    @Binding var isScanning: Bool

    @Environment(StudioViewModel.self) private var vm

    private var readsLinks: Bool { StudioViewModel.supportsLinkDiscovery(article) }

    var body: some View {
        VideoCitedPapersList(
            papers: papers,
            onImport: { paper in
                Task { papers = await vm.importCitedPaper(paper) }
            },
            onDismiss: { paper in
                Task { papers = await vm.dismissCitedPaper(paper) }
            },
            onRestore: { paper in
                Task { papers = await vm.restoreCitedPaper(paper) }
            },
            onFind: { paper in
                papers = await vm.findCitedPaper(paper)
            },
            title: readsLinks ? "Sources linked from this article" : "Papers cited in this paper",
            emptyMessage: readsLinks
                ? "This article's links haven't been read yet."
                : "This paper's references haven't been read yet.",
            showsSlideEvidence: false,
            pendingSectionTitle: readsLinks ? "Linked sources" : "Cited papers",
            scanAction: CitedPaperScanAction(
                title: Self.scanTitle(for: article, hasCandidates: !papers.isEmpty),
                isRunning: isScanning,
                action: {
                    Task {
                        await CitedSourcesPopover.scan(
                            article, vm: vm, papers: $papers, isScanning: $isScanning
                        )
                    }
                }
            ),
            report: vm.citedPaperScanReports[article.id]
        )
        .onDisappear {
            if vm.citedPaperScanReports[article.id]?.isRunning == false {
                vm.citedPaperScanReports[article.id] = nil
            }
        }
    }

    /// The panel's own read button: what it reads, and whether this is the first read.
    static func scanTitle(for article: StudioArticle, hasCandidates: Bool) -> String {
        if StudioViewModel.supportsLinkDiscovery(article) {
            return hasCandidates ? "Read links again" : "Find linked sources"
        }
        return hasCandidates ? "Read references again" : "Find cited papers"
    }

    /// The overflow menu's item for this source: what it reads before a read, and the
    /// waiting count once candidates exist.
    static func menuTitle(for article: StudioArticle, papers: [VideoCitedPaper]) -> String {
        let readsLinks = StudioViewModel.supportsLinkDiscovery(article)
        if papers.isEmpty { return readsLinks ? "Find Linked Sources" : "Find Cited Papers" }
        let pending = papers.filter { $0.status == .pending }.count
        let noun = readsLinks ? "Linked Sources" : "Cited Papers"
        return pending > 0 ? "\(noun) (\(pending) to add)" : noun
    }

    static func menuHelp(for article: StudioArticle, papers: [VideoCitedPaper]) -> String {
        if StudioViewModel.supportsLinkDiscovery(article) {
            return papers.isEmpty
                ? "Read this article's links for the sources it points at"
                : "The sources linked from this article, with Add to Library and Dismiss"
        }
        return papers.isEmpty
            ? "Read this paper's reference list for the papers it cites"
            : "The papers cited in this paper, with Add to Library and Dismiss"
    }

    /// Reads the source's citations — reference list or links — and refreshes the list. One
    /// read at a time: a second request while one runs is dropped rather than queued.
    @MainActor
    static func scan(
        _ article: StudioArticle,
        vm: StudioViewModel,
        papers: Binding<[VideoCitedPaper]>,
        isScanning: Binding<Bool>
    ) async {
        guard !isScanning.wrappedValue else { return }
        isScanning.wrappedValue = true
        if StudioViewModel.supportsLinkDiscovery(article) {
            await vm.discoverLinkedSources(for: article.id, reportsInline: true)
        } else {
            await vm.extractCitedPapersFromReferences(for: article.id, reportsInline: true)
        }
        papers.wrappedValue = await vm.loadCitedPapers(forSourceID: article.id)
        isScanning.wrappedValue = false
    }
}
