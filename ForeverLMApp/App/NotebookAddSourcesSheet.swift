import SwiftUI
import UniformTypeIdentifiers

// MARK: - Ticks

/// A notebook source's box — in chat, or picked to add — and the Select all
/// box over many of them.
enum NotebookTickState: Equatable {
    case checked
    case mixed
    case unchecked

    /// All, some or none of `total` ticked. Nothing to tick reads unchecked.
    static func of(ticked: Int, total: Int) -> NotebookTickState {
        guard total > 0, ticked > 0 else { return .unchecked }
        return ticked >= total ? .checked : .mixed
    }

    var symbolName: String {
        switch self {
        case .checked: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .unchecked: return "square"
        }
    }
}

/// The square a notebook's Sources column and its Add sources sheet tick: a
/// hover-washed button, so it lights up under the pointer like every control
/// (AGENTS "Every button lights up").
struct NotebookTickBox: View {
    let state: NotebookTickState
    /// What the box is for, for VoiceOver: "Include in chat", "Select".
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state.symbolName)
                .zoomedSystemFont(size: 13)
                .foregroundStyle(state == .unchecked ? Color.secondary : Color.accentColor)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(state == .checked ? "Checked" : state == .mixed ? "Partly checked" : "Not checked")
        .accessibilityAddTraits(state == .checked ? .isSelected : [])
    }
}

/// Whether a notebook's chats read a source, a book or a group, drawn as an
/// add control rather than a bare square (product owner, 2026-11-07: "it's
/// unclear that these selected things actually go into the context of the
/// chat … maybe you can do a plus"): a ＋ in a circle while it is out, a
/// filled tick while it is in, a filled minus while only some of a group is.
/// The Sources column's chat ticks use it; the Add sources sheet's
/// selection keeps `NotebookTickBox`.
struct NotebookChatToggle: View {
    let state: NotebookTickState
    /// What the control puts into the chat, for its help and VoiceOver:
    /// a source's title, "every source".
    let subject: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbolName(for: state))
                .zoomedSystemFont(size: 14, weight: state == .unchecked ? .regular : .medium)
                .foregroundStyle(state == .unchecked ? Color.secondary : Color.accentColor)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .help(Self.help(for: state))
        .accessibilityLabel("Add \(subject) to chat")
        .accessibilityValue(state == .checked ? "In chat" : state == .mixed ? "Partly in chat" : "Not in chat")
        .accessibilityAddTraits(state == .checked ? .isSelected : [])
    }

    static func symbolName(for state: NotebookTickState) -> String {
        switch state {
        case .checked: return "checkmark.circle.fill"
        case .mixed: return "minus.circle.fill"
        case .unchecked: return "plus.circle"
        }
    }

    static func help(for state: NotebookTickState) -> String {
        switch state {
        case .checked: return "In chat. Click to leave out"
        case .mixed: return "Partly in chat. Click to add all"
        case .unchecked: return "Add to chat"
        }
    }
}

// MARK: - The sheet's pure part

/// What the Add sources sheet's one field holds and which results are ticked.
/// Pure, so the field's reading and the ticks can be tested without a view.
struct NotebookSourcePicking: Equatable {
    /// What the field holds.
    enum FieldIntent: Equatable {
        /// Nothing typed: the sheet suggests from the library.
        case empty
        /// An address to import into the library and the notebook.
        case link(String)
        /// Words to search the library for.
        case search(String)
    }

    /// Results ticked to add, by source id.
    private(set) var selected: Set<String> = []
    /// Results added from this sheet. The list is fetched again only when the
    /// field changes, so without this an added row would offer itself again.
    private(set) var added: Set<String> = []

    /// A link when the text is an address (`StudioViewModel.importableLink`,
    /// the rule every link field and `import_paper_from_url` share: an
    /// http(s) address with a host, or a DOI), words otherwise.
    static func intent(of text: String) -> FieldIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let link = StudioViewModel.importableLink(in: trimmed) { return .link(link) }
        return .search(trimmed)
    }

    /// The results still on offer, in their order.
    func offered(_ resultIDs: [String]) -> [String] {
        resultIDs.filter { !added.contains($0) }
    }

    /// The ticked results still on offer, in their order: a tick on a row a
    /// new search no longer lists does not count.
    func selection(in resultIDs: [String]) -> [String] {
        offered(resultIDs).filter(selected.contains)
    }

    func isSelected(_ id: String) -> Bool { selected.contains(id) }

    mutating func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    /// The Select all box over the rows on offer.
    func selectAllState(in resultIDs: [String]) -> NotebookTickState {
        let offered = offered(resultIDs)
        return .of(ticked: offered.filter(selected.contains).count, total: offered.count)
    }

    /// Ticks every row on offer, or clears them when all were ticked.
    mutating func toggleAll(in resultIDs: [String]) {
        let offered = offered(resultIDs)
        if selectAllState(in: resultIDs) == .checked {
            selected.subtract(offered)
        } else {
            selected.formUnion(offered)
        }
    }

    /// Rows that went into the notebook leave the list and their ticks.
    mutating func markAdded(_ ids: [String]) {
        added.formUnion(ids)
        selected.subtract(ids)
    }

    /// "Add 3" for three ticked rows, "Add" with none.
    static func addTitle(count: Int) -> String {
        count == 0 ? "Add" : "Add \(count)"
    }

    /// "Add all 23": how many rows Add all takes, said on the button.
    static func addAllTitle(count: Int) -> String {
        "Add all \(count)"
    }

    /// More rows than this at once, and Add all asks first: a search over
    /// title, author, text and meaning can return forty.
    static let addAllConfirmationThreshold = 10

    /// Whether adding `count` rows at once asks first.
    static func addAllNeedsConfirmation(count: Int) -> Bool {
        count > addAllConfirmationThreshold
    }

    /// The question Add all asks above the threshold.
    static func addAllConfirmationTitle(count: Int, notebookTitle: String) -> String {
        "Add \(count) sources to \u{201C}\(notebookTitle)\u{201D}?"
    }

    /// What Upload PDF… says once its files are in: one file's outcome as an
    /// import made in a notebook says it (`notebookImportToast`); several as
    /// how many landed, with the first reason one did not.
    static func uploadToast(
        _ outcomes: [StudioViewModel.NotebookImportOutcome],
        notebookTitle: String,
        noun: String = "PDFs"
    ) -> String? {
        guard let first = outcomes.first else { return nil }
        guard outcomes.count > 1 else {
            return StudioViewModel.notebookImportToast(first, notebookTitle: notebookTitle)
        }
        let landed = outcomes.filter(\.landed).count
        let notebook = "\u{201C}\(notebookTitle)\u{201D}"
        guard landed < outcomes.count else { return "Added \(landed) \(noun) to \(notebook)" }
        let reason = outcomes.first { !$0.landed }
            .map { StudioViewModel.notebookImportToast($0, notebookTitle: notebookTitle) }
        let head = "Added \(landed) of \(outcomes.count) \(noun) to \(notebook)"
        return reason.map { "\(head). \($0)" } ?? head
    }
}

// MARK: - The sheet

/// A notebook's Add sources sheet (docs/notebooks-design.md, "Add sources"):
/// one field that searches the whole library — the hybrid search the
/// notebook's suggestions use (`notebookSourceCandidates`) — or takes a pasted
/// link, which comes into the library and the notebook through the one
/// import (`importLink(_:intoNotebook:)`). With nothing typed it suggests from
/// the library. Rows tick for **Add N**, or **Add all N** takes the whole
/// list, asking first above ten. **Upload PDF…** imports PDFs as papers and
/// files them in the notebook (`importPaperPDF(at:intoNotebook:)`). The web
/// and PubMed are searched from the Sources column's own field since
/// 2026-10-02, where Gemini Notebook searches them too
/// (`NotebookSourcesSearchField`).
struct NotebookAddSourcesSheet: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let goal: LearningGoalRecord

    @SyncedStorage("metadataVisibility") private var metadataVisibility = MetadataVisibilitySettings()
    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var isSearching = false
    @State private var picking = NotebookSourcePicking()
    @State private var isAdding = false
    @State private var isImportingLink = false
    @State private var isUploading = false
    /// The rows Add all is asking about, above the threshold.
    @State private var pendingAddAll: [String]?
    @FocusState private var fieldFocused: Bool

    private var intent: NotebookSourcePicking.FieldIntent {
        NotebookSourcePicking.intent(of: query)
    }

    private var resultIDs: [String] { results.map(\.article.id) }

    /// A read-only team's notebook, or an archived one, takes no new sources.
    private var canAdd: Bool {
        vm.importableNotebook(goal.id) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Add Sources")
                    .zoomedSystemFont(size: 16, weight: .semibold)
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Close")
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            libraryContent
        }
        .padding(20)
        .frame(width: 600, height: 620, alignment: .topLeading)
        // Debounced: each keystroke otherwise costs an embed call and a full
        // ranking pass. `task(id:)` cancels the search the field moved past.
        .task(id: query) {
            await refreshResults()
        }
        .confirmationDialog(
            NotebookSourcePicking.addAllConfirmationTitle(
                count: pendingAddAll?.count ?? 0,
                notebookTitle: goal.title
            ),
            isPresented: Binding(
                get: { pendingAddAll != nil },
                set: { if !$0 { pendingAddAll = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NotebookSourcePicking.addAllTitle(count: pendingAddAll?.count ?? 0)) {
                if let ids = pendingAddAll { add(ids) }
                pendingAddAll = nil
            }
            Button("Cancel", role: .cancel) { pendingAddAll = nil }
        }
    }

    // MARK: Library

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                field
                uploadButton
            }
            HStack(spacing: 8) {
                Text(sectionTitle)
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            switch intent {
            case .link(let address):
                linkRow(address)
                Spacer(minLength: 0)
            case .empty, .search:
                resultsList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sectionTitle: String {
        switch intent {
        case .empty: return "Suggested from your library"
        case .link: return "Link"
        case .search: return "Results"
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: intent.isLink ? "link" : "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your library or paste a link", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    if case .link(let address) = intent { importLink(address) }
                }
                .accessibilityIdentifier("notebook.addSources.field")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Clear")
                .accessibilityLabel("Clear")
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
        .onAppear { fieldFocused = true }
    }

    /// Upload PDF…: one or more PDFs from disk, each imported as a paper and
    /// filed in the notebook.
    private var uploadButton: some View {
        Button {
            uploadPDFs()
        } label: {
            if isUploading {
                ProgressView().controlSize(.small)
            } else {
                Label("Upload PDF…", systemImage: "doc.badge.plus")
            }
        }
        .buttonStyle(.bordered)
        .disabled(isUploading || !canAdd)
        .help(canAdd ? "Import PDFs as papers into Sources and this notebook" : "This notebook takes no new sources")
        .accessibilityIdentifier("notebook.addSources.uploadPDF")
    }

    private func linkRow(_ address: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text(address)
                .zoomedSystemFont(size: 12)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.disabled)
            Spacer(minLength: 0)
            if isImportingLink {
                ProgressView().controlSize(.small)
            }
            Button(isImportingLink ? "Adding…" : "Add link") { importLink(address) }
                .buttonStyle(.borderedProminent)
                .disabled(isImportingLink || !canAdd)
                .help(canAdd ? "Add this page to Sources and to this notebook" : "This notebook takes no new sources")
                .accessibilityIdentifier("notebook.addSources.addLink")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var resultsList: some View {
        let offered = picking.offered(resultIDs)
        if offered.isEmpty {
            Text(emptyMessage)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            Spacer(minLength: 0)
        } else {
            selectAllRow(offered: offered)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(results.filter { offered.contains($0.article.id) }, id: \.article.id) { result in
                        candidateRow(result.article)
                    }
                }
                // Overlay scrollers take no width; keep the boxes clear of them.
                .padding(.trailing, 12)
            }
            .frame(maxHeight: .infinity)
            footer(offered: offered)
        }
    }

    private func selectAllRow(offered: [String]) -> some View {
        let state = picking.selectAllState(in: resultIDs)
        let count = picking.selection(in: resultIDs).count
        return HStack(spacing: 8) {
            NotebookTickBox(
                state: state,
                label: "Select all",
                help: state == .checked ? "Clear the selection" : "Select every result",
                action: { picking.toggleAll(in: resultIDs) }
            )
            .disabled(isAdding)
            Text("Select all")
                .zoomedSystemFont(size: 12)
            Spacer(minLength: 0)
            Text(count == 1 ? "1 selected" : "\(count) selected")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.disabled)
        }
        .padding(.horizontal, 6)
        .accessibilityIdentifier("notebook.addSources.selectAll")
    }

    private func candidateRow(_ article: StudioArticle) -> some View {
        let isSelected = picking.isSelected(article.id)
        return HStack(spacing: 8) {
            NotebookTickBox(
                state: isSelected ? .checked : .unchecked,
                label: "Select \(article.title)",
                help: isSelected ? "Leave out" : "Select to add",
                action: { picking.toggle(article.id) }
            )
            .disabled(isAdding)
            ArticleRow(article: article, metadataVisibility: metadataVisibility)
            Spacer(minLength: 0)
            Button {
                add([article.id])
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.hoverWash)
            .disabled(isAdding || !canAdd)
            .help("Add to this notebook")
            .accessibilityLabel("Add \(article.title) to this notebook")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func footer(offered: [String]) -> some View {
        let selection = picking.selection(in: resultIDs)
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            if isAdding {
                ProgressView().controlSize(.small)
            }
            if offered.count > 1 {
                Button(NotebookSourcePicking.addAllTitle(count: offered.count)) { addAll(offered) }
                    .buttonStyle(.bordered)
                    .disabled(isAdding || !canAdd)
                    .help("Add every result to this notebook")
                    .accessibilityIdentifier("notebook.addSources.addAll")
            }
            Button(NotebookSourcePicking.addTitle(count: selection.count)) { add(selection) }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || isAdding || !canAdd)
                .help(canAdd ? "Add the selected sources to this notebook" : "This notebook takes no new sources")
                .accessibilityIdentifier("notebook.addSources.add")
        }
    }

    private var emptyMessage: String {
        if isSearching { return "Searching…" }
        switch intent {
        case .search: return "No sources match"
        case .empty, .link:
            return goal.items.isEmpty
                ? "Add a source or two, and suggestions will appear here"
                : "Nothing left to suggest"
        }
    }

    // MARK: Actions

    private func refreshResults() async {
        guard !intent.isLink else {
            results = []
            return
        }
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        isSearching = true
        defer { isSearching = false }
        let candidates = await vm.notebookSourceCandidates(goalID: goal.id, query: query)
        guard !Task.isCancelled else { return }
        results = candidates
    }

    private func add(_ ids: [String]) {
        guard !ids.isEmpty, !isAdding else { return }
        isAdding = true
        Task {
            let filed = await vm.addSourcesToNotebookContext(ids, notebookID: goal.id)
            if filed != nil { picking.markAdded(ids) }
            isAdding = false
        }
    }

    /// Add all: at once up to the threshold, after a question above it.
    private func addAll(_ ids: [String]) {
        if NotebookSourcePicking.addAllNeedsConfirmation(count: ids.count) {
            pendingAddAll = ids
        } else {
            add(ids)
        }
    }

    private func uploadPDFs() {
        guard !isUploading, canAdd else { return }
        Task {
            let urls = await FilePanel.open { panel in
                panel.allowedContentTypes = [.pdf]
                panel.allowsMultipleSelection = true
                panel.message = "Select PDFs to add to \u{201C}\(goal.title)\u{201D}"
            }
            guard !urls.isEmpty else { return }
            isUploading = true
            var outcomes: [StudioViewModel.NotebookImportOutcome] = []
            for url in urls {
                outcomes.append(await vm.importPaperPDF(at: url, intoNotebook: goal.id))
            }
            isUploading = false
            if let toast = NotebookSourcePicking.uploadToast(outcomes, notebookTitle: goal.title) {
                vm.showToast(toast)
            }
        }
    }

    private func importLink(_ address: String) {
        guard !isImportingLink, canAdd else { return }
        isImportingLink = true
        Task {
            let outcome = await vm.importLink(address, intoNotebook: goal.id)
            isImportingLink = false
            vm.showToast(StudioViewModel.notebookImportToast(outcome, notebookTitle: goal.title))
            if outcome.landed { query = "" }
        }
    }
}

private extension NotebookSourcePicking.FieldIntent {
    var isLink: Bool {
        if case .link = self { return true }
        return false
    }
}
