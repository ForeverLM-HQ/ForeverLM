import SwiftUI

/// Discover, for a notebook's Add sources sheet: search the web (one paid
/// search with the notebook as context) or PubMed (free) for works the
/// notebook is missing, tick them, and import them into the library and the
/// notebook. The list belongs to the notebook's `NotebookDiscoverySession`,
/// so it is still there when the sheet opens again. The notebook's Add
/// sources sheet (`NotebookAddSourcesSheet`) hosts it, and its Research this
/// deeply opens a Deep Research chat in the notebook.
struct NotebookDiscoverView: View {
    @Environment(StudioViewModel.self) private var vm
    let notebook: LearningGoalRecord
    /// Whether the view draws its own Web | Papers switch. A sheet that has a
    /// switch of its own sets the session's `mode` instead.
    var showsModePicker = true
    /// Whether the view draws its own field. The notebook's Sources column
    /// has the one field that searches, so its results list draws none.
    var showsSearchField = true
    /// Whether the list grows to the height it is given, as in the Sources
    /// column, rather than the sheet's fixed band.
    var fillsHeight = false
    /// Opens a Deep Research chat in the notebook about these words. Nil
    /// hides **Research this deeply**.
    var researchDeeply: ((String) -> Void)?
    /// Runs after ↗ opened a page in the window, so a sheet can step aside.
    var onOpenPage: (() -> Void)?

    var body: some View {
        NotebookDiscoverContent(
            session: NotebookDiscoverySession.session(forNotebook: notebook.id, vm: vm),
            notebook: notebook,
            showsModePicker: showsModePicker,
            showsSearchField: showsSearchField,
            fillsHeight: fillsHeight,
            researchDeeply: researchDeeply,
            onOpenPage: onOpenPage
        )
    }
}

private struct NotebookDiscoverContent: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Bindable var session: NotebookDiscoverySession
    let notebook: LearningGoalRecord
    let showsModePicker: Bool
    let showsSearchField: Bool
    let fillsHeight: Bool
    let researchDeeply: ((String) -> Void)?
    let onOpenPage: (() -> Void)?

    @FocusState private var fieldFocused: Bool

    private var listing: NotebookDiscoverySession.Listing { session.listing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsModePicker {
                Picker("", selection: $session.mode) {
                    ForEach(NotebookDiscoverySession.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(session.isImporting)
                .accessibilityIdentifier("notebook.discover.mode")
            }
            if showsSearchField {
                searchField
            }
            content
        }
        .onAppear {
            session.refreshHoldings(vm: vm)
            if showsSearchField { fieldFocused = true }
        }
    }

    // MARK: The field

    private var placeholder: String {
        switch session.mode {
        case .web: return "Search the web for \u{201C}\(notebook.title)\u{201D}"
        case .papers: return "Search PubMed for \u{201C}\(notebook.title)\u{201D}"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: session.mode == .web ? "globe" : "text.book.closed")
                .foregroundStyle(.secondary)
            // Return searches; typing does not, because a web search costs money.
            TextField(placeholder, text: $session.query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { session.search(vm: vm) }
                .accessibilityIdentifier("notebook.discover.query")
            if session.isSearching {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { session.cancelSearch() }
                    .buttonStyle(.hoverWash)
                    .accessibilityIdentifier("notebook.discover.cancelSearch")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: What the search found

    @ViewBuilder
    private var content: some View {
        switch listing.phase {
        case .idle:
            EmptyView()
        case .searching:
            statusLine(session.mode == .web ? "Searching the web…" : "Searching PubMed…")
        case .refused(let message):
            refusedLine(message)
        case .failed(let message):
            Text(message)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .results:
            results
        }
    }

    private func refusedLine(_ message: String) -> some View {
        HStack(spacing: 8) {
            statusLine(message)
            Button("Search Papers") { session.searchPapersInstead(vm: vm) }
                .buttonStyle(.hoverWash(tint: .accentColor))
                .accessibilityIdentifier("notebook.discover.searchPapers")
        }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .zoomedSystemFont(size: 11)
            .foregroundStyle(.secondary)
            .textSelection(.disabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var results: some View {
        if let summary = listing.summary {
            Text(summary)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if listing.rows.isEmpty {
            statusLine(session.mode == .web ? "Nothing found that could be opened." : "Nothing matched.")
        } else {
            selectionRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(listing.rows) { row in
                        NotebookDiscoverRowView(
                            row: row,
                            isSelected: session.isSelected(row),
                            toggle: { session.setSelected(!session.isSelected(row), rowID: row.id) },
                            open: { open(row) }
                        )
                    }
                }
                // Overlay scrollers take no width; keep the trailing marks clear.
                .padding(.trailing, 12)
            }
            .frame(minHeight: fillsHeight ? 120 : 240, maxHeight: fillsHeight ? .infinity : 440)
        }
        footer
    }

    private var selectionRow: some View {
        HStack(spacing: 8) {
            Button { session.toggleSelectAll() } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.allTickableSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(session.allTickableSelected ? Color.accentColor : .secondary)
                    Text("Select all")
                        .zoomedSystemFont(size: 12)
                }
            }
            .buttonStyle(.hoverWash)
            .disabled(session.tickableRows.isEmpty || session.isImporting)
            .accessibilityIdentifier("notebook.discover.selectAll")
            Spacer(minLength: 0)
            Text(session.selectedCount == 1 ? "1 source selected" : "\(session.selectedCount) sources selected")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.disabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.mode == .web, listing.leftOut > 0 {
                statusLine(listing.leftOut == 1
                    ? "1 left out because it could not be opened"
                    : "\(listing.leftOut) left out because they could not be opened")
            }
            if session.mode == .web, let cost = listing.costUSD {
                Text(chatCostText(cost))
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .textSelection(.disabled)
                    .help("What this search cost")
            }
            Spacer(minLength: 0)
            if let researchDeeply {
                Button("Research this deeply") {
                    let words = (listing.query ?? session.query).trimmingCharacters(in: .whitespacesAndNewlines)
                    researchDeeply(words.isEmpty ? notebook.title : words)
                }
                .buttonStyle(.hoverWash(tint: .accentColor))
                .disabled(session.isImporting)
                .accessibilityIdentifier("notebook.discover.researchDeeply")
            }
            if session.isImporting {
                Button("Stop") { session.cancelImport() }
                    .buttonStyle(.hoverWash)
                    .accessibilityIdentifier("notebook.discover.stopImport")
            }
            Button(addTitle) { session.importSelected(vm: vm) }
                .buttonStyle(.borderedProminent)
                .disabled(session.selectedCount == 0 || session.isImporting || !canImport)
                .help(canImport ? "Add the selected sources to Sources and to this notebook" : "This notebook is read-only for you")
                .accessibilityIdentifier("notebook.discover.import")
        }
    }

    /// "Add 3" for three ticked rows, "Adding…" while they go in.
    private var addTitle: String {
        if session.isImporting { return "Adding…" }
        let count = session.selectedCount
        return count == 0 ? "Add" : "Add \(count)"
    }

    private var canImport: Bool {
        vm.discoveryCanImport(into: vm.notebook(id: notebook.id) ?? notebook)
    }

    /// Opens the page in this window without importing it; a page the library
    /// holds opens as the saved source.
    private func open(_ row: NotebookDiscoveryRow) {
        guard let url = URL(string: row.url) else { return }
        vm.openWebCitation(url, title: row.title, in: windowState)
        onOpenPage?()
    }
}

/// One work in the list: its box, the site's icon, title and ↗, what kind of
/// work it is and where from, the line on why it fits (web) or the abstract
/// (PubMed), and on the right what the library and the notebook hold or how
/// its import went.
private struct NotebookDiscoverRowView: View {
    @Environment(StudioViewModel.self) private var vm
    let row: NotebookDiscoveryRow
    let isSelected: Bool
    let toggle: () -> Void
    let open: () -> Void

    @State private var preview: ReferenceLinkPreview?

    /// The page's own title, from its head, unless Crossref named the work:
    /// a row whose page was opened to check it carries that title already,
    /// so only a cited row takes it from the preview. A PubMed row keeps
    /// PubMed's.
    private var title: String {
        if row.confirmedBy == .citation,
           let pageTitle = preview?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pageTitle.isEmpty {
            return pageTitle
        }
        return row.title
    }

    private var detail: String {
        if let byline = row.byline { return byline }
        return [row.kind.label, row.site, row.published]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            checkbox
            siteIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Button(action: open) {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
                    .help("Open")
                    .accessibilityIdentifier("notebook.discover.open")
                }
                Text(detail)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if row.isReview || row.isPreprint || row.isFreeFullText {
                    HStack(spacing: 4) {
                        if row.isReview { chip("Review") }
                        if row.isPreprint { chip("Preprint") }
                        if row.isFreeFullText { chip("Free full text") }
                    }
                }
                if let why = row.why {
                    Text(why)
                        .zoomedSystemFont(size: 11)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let abstract = row.abstract {
                    Text(abstract)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if case .done(.failed(let reason)) = row.importState {
                    Text(reason)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.disabled)
                }
            }
            Spacer(minLength: 0)
            mark
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .task(id: row.url) {
            // The site's icon, and a cited row's title. A row the open check
            // confirmed is read once more here, for the icon alone: that check
            // reads the status and title, not the head's icon links. Each
            // address is fetched once for the life of the app.
            preview = await ReferenceLinkPreviews.shared.preview(for: row.url)
        }
    }

    @ViewBuilder
    private var checkbox: some View {
        if row.isTickable {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            .accessibilityIdentifier("notebook.discover.tick")
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private var siteIcon: some View {
        Group {
            if let icon = preview?.iconURL.flatMap(URL.init(string:)) {
                AsyncImage(url: icon) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        kindGlyph
                    }
                }
            } else {
                kindGlyph
            }
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
    }

    private var kindGlyph: some View {
        Image(systemName: Self.symbol(for: row.kind))
            .foregroundStyle(.secondary)
    }

    static func symbol(for kind: VideoCitedPaper.Kind) -> String {
        switch kind {
        case .paper: return "doc.text"
        case .article: return "newspaper"
        case .video: return "play.rectangle"
        case .podcast: return "waveform"
        case .xPost: return "text.bubble"
        }
    }

    // MARK: The trailing mark

    @ViewBuilder
    private var mark: some View {
        switch row.importState {
        case .importing:
            ProgressView().controlSize(.small)
        case .waiting:
            EmptyView()
        case .done(let outcome):
            outcomeMark(outcome)
        case nil:
            holdingMark
        }
    }

    @ViewBuilder
    private func outcomeMark(_ outcome: DiscoveredImport) -> some View {
        switch outcome {
        case .added(let id), .filed(let id):
            // A paper the pipeline found behind a paywall waits for its PDF;
            // it is never read off the publisher's page.
            if vm.articlesById[id]?.isPaywalledPaper == true {
                badge("PDF needed", tint: .orange)
            } else {
                Label("Added", systemImage: "checkmark")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
        case .alreadyInNotebook:
            badge("In notebook", tint: .secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var holdingMark: some View {
        switch row.holding {
        case .new: EmptyView()
        case .inLibrary: badge("In library", tint: .secondary)
        case .inNotebook: badge("In notebook", tint: .secondary)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .zoomedSystemFont(size: 10, weight: .medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .textSelection(.disabled)
            .fixedSize()
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .zoomedSystemFont(size: 10)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .textSelection(.disabled)
    }
}
