#if os(macOS)
import SwiftUI

// MARK: - A paper's figure legends beside its pages
//
// A journal prints a figure on one page and its legend on another: at the
// end of a preprint, overleaf, or a few pages on. Reading the legend meant
// scrolling away from the figure and back. This is a trailing panel beside the
// PDF, as Levels and Linked References are, that lists every figure's legend
// and follows the page: the figures drawn on the page being read are marked and
// scrolled to, so their legends stand beside them whatever page they are
// printed on. A click on a figure jumps the PDF to it.
//
// It reads the paper's figure index (`PaperFigureIndexer`), which pairs each
// figure's page with the legend words wherever they are printed. A paper not
// indexed yet gets the free structural read (no model, no credits), the one the
// Clip tool does. The panel is opened from the Reader's ⋯ menu
// (`ReaderFigureLegendsMenuItem`).
//
// One of the three at a time: Levels, Linked References and Figure Legends are
// each a column of the same width, and two open would leave the page a strip.

/// Whether the Reader's Figure Legends panel shows: this session's choice, for
/// every Reader, like the Levels panel's.
@MainActor
@Observable
final class ReaderFigureLegendsPanelState {
    static let shared = ReaderFigureLegendsPanelState()

    var isVisible = false {
        didSet {
            // The trailing column is shared with Levels and Linked References.
            guard isVisible else { return }
            if ReaderLevelsPanelState.shared.isVisible { ReaderLevelsPanelState.shared.isVisible = false }
            if ReaderReferencesPanelState.shared.isVisible { ReaderReferencesPanelState.shared.isVisible = false }
        }
    }

    nonisolated init() {}
}

/// What the panel lists and which of it is on the page being read.
enum ReaderFigureLegends {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        /// "Figure 3", as the paper's index names it.
        let label: String
        /// Zero-based page of the figure itself, which is not always the page
        /// its legend is printed on.
        let pageIndex: Int
        /// The legend's words, label off, on one line. Empty when the paper
        /// printed only the label and the index found no words elsewhere.
        let legend: String

        var pageNumber: Int { pageIndex + 1 }
    }

    /// The Reader offers the panel for a paper it shows as a local PDF: the
    /// figure index reads that file.
    static func offers(_ article: StudioArticle) -> Bool {
        article.sourceType == .paper && article.isPDF && article.cachedResolvedPDFPath != nil
    }

    /// One entry a figure, in page order. A caption continued onto the next
    /// page is a second row under one label, and the figure is the earlier
    /// one; Nature's "See next page for caption" stub takes its words from the
    /// continuation row.
    static func entries(from records: [PaperFigureRecord]) -> [Entry] {
        PaperWalkthroughWriting
            .firstPerLabel(records, label: \.figureLabel, pageIndex: \.pageIndex)
            .map { record in
                let shown = PaperWalkthroughGeneratorService.displayRecord(for: record, in: records)
                return Entry(
                    id: record.id,
                    label: record.figureLabel,
                    pageIndex: record.pageIndex,
                    legend: PaperFigureCaptionTitle.words(from: shown.caption)
                )
            }
    }

    /// The entries drawn on `pageIndex`, the page the learner is reading.
    static func entryIDs(onPage pageIndex: Int?, in entries: [Entry]) -> [String] {
        guard let pageIndex else { return [] }
        return entries.filter { $0.pageIndex == pageIndex }.map(\.id)
    }
}

// MARK: - The panel

struct ReaderFigureLegendsPanel: View {
    let article: StudioArticle

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.uiZoomScale) private var uiZoomScale

    enum Phase: Equatable {
        case loading
        case ready
        case unreadable(String)
    }

    @State private var phase: Phase = .loading
    @State private var entries: [ReaderFigureLegends.Entry] = []

    private var state: ReaderFigureLegendsPanelState { ReaderFigureLegendsPanelState.shared }

    /// The page the Reader is on, as it reports it (`updateReadingPosition`),
    /// or the one it opened at before the learner has moved.
    private var currentPage: Int? {
        if case .page(let page)? = ReaderLevelsPositionFeed.shared.position(for: article.id) { return page }
        return vm.readingPositionPage(for: article.id) ?? article.readingPositionPage
    }

    private var focusedIDs: [String] {
        ReaderFigureLegends.entryIDs(onPage: currentPage, in: entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 340 * uiZoomScale)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
        .task(id: article.id) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Figure Legends")
    }

    private func load() async {
        let sourceID = article.id
        phase = .loading
        entries = []
        do {
            // The structural read is free and returns the stored index at once
            // for a paper that has one.
            let records = try await vm.paperFigureIndexer.prepareStructure(sourceID: sourceID)
            guard !Task.isCancelled else { return }
            entries = ReaderFigureLegends.entries(from: records)
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unreadable(error.localizedDescription)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Figure Legends")
                .font(.subheadline.weight(.semibold))
                .textSelection(.disabled)
            if phase == .ready, !entries.isEmpty {
                Text("\(entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
            }
            Spacer()
            Button {
                state.isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help("Hide Figure Legends")
            .accessibilityLabel("Hide Figure Legends")
            .accessibilityIdentifier("reader.figureLegends.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreadable(let message):
            centered(message)
        case .ready:
            if entries.isEmpty {
                centered("No figures found in this paper")
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        row(entry, here: focusedIDs.contains(entry.id))
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            // The legends of the figures on the page being read come into view,
            // on arriving and on every page turn.
            .onChange(of: focusedIDs, initial: true) { _, ids in
                guard let first = ids.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    private func row(_ entry: ReaderFigureLegends.Entry, here: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                vm.requestReaderPassage(nil, page: entry.pageNumber, for: article.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text("p. \(entry.pageNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.07))
            .help("Go to \(entry.label) on page \(entry.pageNumber)")
            .accessibilityIdentifier("reader.figureLegends.figure")

            if entry.legend.isEmpty {
                Text("No legend found")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
            } else {
                Text(entry.legend)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(here ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(here ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func centered(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The ⋯ menu's entry for the panel, beside Linked References.
struct ReaderFigureLegendsMenuItem: View {
    private var state: ReaderFigureLegendsPanelState { ReaderFigureLegendsPanelState.shared }

    var body: some View {
        Button {
            state.isVisible.toggle()
        } label: {
            Label(state.isVisible ? "Hide Figure Legends" : "Figure Legends", systemImage: "text.below.photo")
        }
        .help("Every figure's legend beside the paper, following the page you are on")
    }
}
#endif
