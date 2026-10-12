import SwiftUI

// MARK: - One search in a notebook's Sources column
//
// The product owner, 2026-10-02: "sources search across all sources on the left", and
// "should be able to search for sources across our library and across the web
// as well". Gemini Notebook puts a web search at the top of its Sources panel
// and lands its results as a card in the panel; ForeverLM's field reaches the
// notebook, the whole library and the web or PubMed (docs/notebooks-design.md,
// "The Sources column's search"):
// - Library, with no words: the Library itself, its kind tabs and rows, each
//   row's + filing it and each row dragging (`NotebookLibraryBrowser`), while
//   the notebook is empty or the field is in use (product owner, 2026-10-12:
//   "in a notebook i might also want to drag in different sources. but i
//   might also want to do a text based search").
// - Library, as you type: the notebook's matches, then the library's books and
//   sources, each one click from joining. Only the library: Return does
//   nothing here, and a row under the matches takes the words to the web.
// - Web, on Return only: one paid search (`NotebookDiscoverySession`), whose
//   results arrive as a card at the top of the column and expand into the
//   whole list, the column widening for it.
// - PubMed, on Return: the free literature search, the same way.
// Reading never adds: a library row or a result opens in the Reader beside the
// chat without joining the notebook.

/// Where the Sources column's field searches.
enum NotebookSourcesSearchScope: String, Identifiable {
    case library
    case web
    case papers

    var id: String { rawValue }

    /// The scopes under the Sources field while it is in use. Papers remains a
    /// contextual alternative when a web search is unavailable, rather than
    /// taking space in the primary search controls.
    static let primaryScopes: [NotebookSourcesSearchScope] = [.library, .web]

    var title: String {
        switch self {
        case .library: return "Library"
        case .web: return "Web"
        case .papers: return "PubMed"
        }
    }

    /// The discovery list a scope's Return runs; nil for the library, which
    /// answers as the words are typed.
    var discoveryMode: NotebookDiscoverySession.Mode? {
        switch self {
        case .library: return nil
        case .web: return .web
        case .papers: return .papers
        }
    }

    /// What Return does in this scope: in Library nothing, because the
    /// library answers as the words are typed and Library searches only the
    /// library (the "Search the web for …" row under its matches is the way
    /// out, and says so); in Web and PubMed it runs that search, for the
    /// notebook's own subject when no words are typed (what Add sources ›
    /// Discover did with an empty field).
    static func submission(scope: NotebookSourcesSearchScope, query: String) -> NotebookDiscoverySession.Mode? {
        scope.discoveryMode
    }
}

/// What a discovery card says about its list, pure so it can be tested
/// without a view.
enum NotebookDiscoveryCardText {
    /// "10 on the web · 3 in your library", "20 in PubMed", "Nothing found on
    /// the web".
    static func headline(mode: NotebookDiscoverySession.Mode, rows: [NotebookDiscoveryRow]) -> String {
        let place = mode == .web ? "on the web" : "in PubMed"
        guard !rows.isEmpty else { return "Nothing found \(place)" }
        let held = rows.filter { $0.holding != .new }.count
        let found = "\(rows.count) \(place)"
        return held > 0 ? "\(found) · \(held) in your library" : found
    }

    /// The card's button that opens the whole list: "7 more", or "Review"
    /// when the card already shows every row.
    static func moreTitle(rowCount: Int, shown: Int) -> String {
        rowCount > shown ? "\(rowCount - shown) more" : "Review"
    }
}

/// The Sources column's field and its scopes, at the column's top.
struct NotebookSourcesSearchField: View {
    @Binding var text: String
    @Binding var scope: NotebookSourcesSearchScope
    /// The notebook's title, which Web and PubMed search with no words.
    var subject: String = ""
    /// Return: runs the web or PubMed search in those scopes, nothing in Library.
    let submit: () -> Void
    /// The field took or lost keyboard focus.
    var focusChanged: (Bool) -> Void = { _ in }
    /// Escape in the field; nil leaves Escape to the window.
    var escape: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    /// Library | Web show while the field is in use — focused or typed in —
    /// and fold away otherwise (2026-10-06, the product owner: "cleaner and fewer
    /// buttons and bells and whistles"); the glyph and the placeholder still
    /// say a scope other than Library (`settleScopes`).
    @State private var showsScopes = false

    private var placeholder: String {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        switch scope {
        case .library: return "Search your library"
        case .web: return subject.isEmpty ? "Search the web" : "Search the web for \u{201C}\(subject)\u{201D}"
        case .papers: return subject.isEmpty ? "Search PubMed" : "Search PubMed for \u{201C}\(subject)\u{201D}"
        }
    }

    /// One box, as Gemini Notebook's: the field, and the scopes inside it
    /// under the words while the field is in use.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onKeyPress(.escape) {
                        guard let escape else { return .ignored }
                        escape()
                        return .handled
                    }
                    .accessibilityIdentifier("notebook.sources.search")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverWash)
                    .help("Clear")
                    .accessibilityLabel("Clear search")
                }
            }
            .zoomedSystemFont(size: 13)
            if showsScopes {
                HStack(spacing: 4) {
                    ForEach(NotebookSourcesSearchScope.primaryScopes) { candidate in
                        scopeChip(candidate)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, showsScopes ? 7 : 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onHover { isHovering = $0 }
        .onAppear { settleScopes(inUse: isInUse) }
        .onChange(of: isInUse) { _, inUse in settleScopes(inUse: inUse) }
        .onChange(of: isFocused) { _, focused in focusChanged(focused) }
        .onChange(of: isHovering) { _, _ in settleScopes(inUse: isInUse) }
        .animation(.easeOut(duration: 0.15), value: showsScopes)
    }

    /// The field is focused or holds words.
    private var isInUse: Bool { isFocused || !text.isEmpty }

    /// The chips come with the field's use and stay while the pointer is in
    /// the box, so one clicked is still there when the click lands, whatever
    /// the click does to the field's focus; the pointer alone never opens
    /// them, so passing over the box moves nothing under it.
    private func settleScopes(inUse: Bool) {
        let shown = inUse || (showsScopes && isHovering)
        if showsScopes != shown { showsScopes = shown }
    }

    private var symbolName: String {
        switch scope {
        case .library: return "magnifyingglass"
        case .web: return "globe"
        case .papers: return "text.book.closed"
        }
    }

    private func scopeChip(_ candidate: NotebookSourcesSearchScope) -> some View {
        let isSelected = candidate == scope
        return Button { scope = candidate } label: {
            Text(candidate.title)
                .zoomedSystemFont(size: 11, weight: isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.hoverWash(in: Capsule(style: .continuous)))
        .help(help(for: candidate))
        .accessibilityLabel("Search \(candidate.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("notebook.sources.scope.\(candidate.rawValue)")
    }

    private func help(for candidate: NotebookSourcesSearchScope) -> String {
        switch candidate {
        case .library: return "Search this notebook and your library as you type; nothing leaves your Mac"
        case .web: return "Search the web on Return; priced like a chat turn"
        case .papers: return "Search PubMed on Return, free"
        }
    }
}

/// The library's matches for the column's words, under the notebook's own:
/// library sources the notebook does not hold, by the same hybrid search Add
/// sources uses (`notebookSourceCandidates`), each with a + that adds it to
/// the notebook and a click that opens it in the Reader without adding it.
/// Then the rows that take the words to the web and to PubMed.
struct NotebookLibraryMatches: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let goal: LearningGoalRecord
    let query: String
    /// Takes the words to the web or PubMed: the scope switches and the
    /// search runs.
    let searchElsewhere: (NotebookDiscoverySession.Mode) -> Void

    @State private var matches: [StudioArticle] = []
    @State private var bookMatches: [StudioViewModel.NotebookBookCandidate] = []
    @State private var isSearching = false
    /// The notebook and words `matches` answer, so "No other sources match"
    /// waits for a search that has run.
    @State private var searchedKey: String?
    @State private var addingIDs: Set<String> = []
    @State private var showsAll = false

    private var searchKey: String { "\(goal.id)|\(query)" }

    /// Whether the notebook holds `article` now: read from the notebook, so a
    /// source removed from it again offers its + again.
    private func isMember(_ article: StudioArticle) -> Bool {
        guard let items = vm.notebook(id: goal.id)?.items else { return false }
        return items.contains { $0.sourceID == article.id || vm.canonicalSourceID($0.sourceID) == article.id }
    }

    /// Matches shown before "Show N more".
    private static let firstPage = 8

    private var canAdd: Bool { vm.importableNotebook(goal.id) != nil }

    var body: some View {
        let shown = showsAll ? matches : Array(matches.prefix(Self.firstPage))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text("In your library")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                if !matches.isEmpty || !bookMatches.isEmpty {
                    Text("\(matches.count + bookMatches.count)")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if isSearching {
                    ProgressView().controlSize(.mini)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
            }
            if matches.isEmpty, bookMatches.isEmpty, !isSearching, searchedKey == searchKey {
                Text("No other sources match")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            ForEach(bookMatches) { book in
                bookRow(book)
            }
            ForEach(shown) { article in
                row(article)
            }
            if !showsAll, matches.count > Self.firstPage {
                Button("Show \(matches.count - Self.firstPage) more") { showsAll = true }
                    .buttonStyle(.hoverWash)
                    .zoomedSystemFont(size: 11)
                    .padding(.horizontal, 2)
            }
            elsewhereRow(.web)
            elsewhereRow(.papers)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("In your library")
        .accessibilityIdentifier("notebook.sources.libraryMatches")
        // Debounced: each keystroke otherwise costs an embed call and a full
        // ranking pass; `task(id:)` cancels the search the words moved past.
        .task(id: searchKey) {
            let key = searchKey
            if searchedKey?.hasPrefix("\(goal.id)|") != true {
                // Another notebook: its matches are not this one's.
                matches = []
                bookMatches = []
            }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await vm.notebookSourceCandidates(goalID: goal.id, query: query)
            guard !Task.isCancelled, key == searchKey else { return }
            matches = found.map(\.article)
            bookMatches = vm.notebookBookCandidates(goalID: goal.id, query: query)
            searchedKey = key
            isSearching = false
            showsAll = false
        }
    }

    private func row(_ article: StudioArticle) -> some View {
        let title = vm.displayTitle(for: article)
        let isAdded = isMember(article)
        return HStack(alignment: .top, spacing: 6) {
            Button {
                if let windowState {
                    Task { await vm.selectArticle(article.id, in: windowState, revealingReader: true) }
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: article.sourceType.symbolName)
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .zoomedSystemFont(size: 12.5)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let byline = byline(article) {
                            Text(byline)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
            .help("Open beside the chat")
            .accessibilityLabel(title)
            .opensInOtherWindow(article)

            Button {
                add(article)
            } label: {
                Group {
                    if addingIDs.contains(article.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(isAdded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                }
                .zoomedSystemFont(size: 13)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .disabled(isAdded || !canAdd || addingIDs.contains(article.id))
            .padding(.top, 2)
            .help(isAdded ? "In \(goal.title)" : "Add to \(goal.title)")
            .accessibilityLabel(isAdded ? "In \(goal.title)" : "Add \(title) to \(goal.title)")
        }
    }

    /// A book the words name: opens at its first chapter in the Reader, and
    /// its + adds every chapter the notebook does not hold, as the sidebar's
    /// Books tab files a whole book.
    private func bookRow(_ book: StudioViewModel.NotebookBookCandidate) -> some View {
        let isAdding = book.chapterIDs.contains { addingIDs.contains($0) }
        let chapterCount = "\(book.chapterIDs.count) chapter\(book.chapterIDs.count == 1 ? "" : "s")"
        let partly = book.missingChapterIDs.count < book.chapterIDs.count
        return HStack(alignment: .top, spacing: 6) {
            Button {
                if let windowState, let first = book.chapterIDs.first {
                    Task { await vm.selectArticle(first, in: windowState, revealingReader: true) }
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "books.vertical")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(book.title)
                            .zoomedSystemFont(size: 12.5)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text([book.author, "Book", chapterCount].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
            .help("Open the book beside the chat")
            .accessibilityLabel(book.title)

            Button {
                addBook(book)
            } label: {
                Group {
                    if isAdding {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .zoomedSystemFont(size: 13)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .disabled(!canAdd || isAdding)
            .padding(.top, 2)
            .help(partly ? "Add the other \(book.missingChapterIDs.count) chapters to \(goal.title)" : "Add the whole book to \(goal.title)")
            .accessibilityLabel("Add \(book.title) to \(goal.title)")
            .accessibilityIdentifier("notebook.sources.libraryBook.add")
        }
        .accessibilityIdentifier("notebook.sources.libraryBook")
    }

    private func addBook(_ book: StudioViewModel.NotebookBookCandidate) {
        let ids = book.missingChapterIDs
        guard canAdd, !ids.isEmpty, !ids.contains(where: { addingIDs.contains($0) }) else { return }
        addingIDs.formUnion(ids)
        Task {
            _ = await vm.addSourcesToNotebookContext(ids, notebookID: goal.id)
            addingIDs.subtract(ids)
            bookMatches = vm.notebookBookCandidates(goalID: goal.id, query: query)
        }
    }

    /// A chapter or lecture names its book or course where other sources name
    /// their site, as the library row does.
    private func byline(_ article: StudioArticle) -> String? {
        let collection = article.sourceType == .book || article.sourceType == .course
            ? vm.sourceGroupTitle(for: article)
            : nil
        let parts = [article.displayAuthor, collection ?? article.displayDomain]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func elsewhereRow(_ mode: NotebookDiscoverySession.Mode) -> some View {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = mode == .web
            ? "Search the web for \u{201C}\(words)\u{201D}"
            : "Search PubMed for \u{201C}\(words)\u{201D}"
        return Button { searchElsewhere(mode) } label: {
            HStack(spacing: 8) {
                Image(systemName: mode == .web ? "globe" : "text.book.closed")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(label)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .help(mode == .web ? "Search the web with your model; priced like a chat turn" : "Search PubMed, free")
        .accessibilityIdentifier("notebook.sources.searchElsewhere.\(mode.rawValue)")
    }

    private func add(_ article: StudioArticle) {
        guard canAdd, !addingIDs.contains(article.id) else { return }
        addingIDs.insert(article.id)
        Task {
            _ = await vm.addSourcesToNotebookContext([article.id], notebookID: goal.id)
            addingIDs.remove(article.id)
        }
    }
}

/// A web or PubMed search's results as a card at the top of the Sources
/// column, Gemini's "Fast Research completed!": the headline, the first three
/// works with why each fits, and the ways on — the whole list (the column
/// widens for it), Add for what is ticked, and × to put the card away.
struct NotebookDiscoveryCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Bindable var session: NotebookDiscoverySession
    let notebook: LearningGoalRecord
    /// Opens the whole list in the widened column.
    let showAll: () -> Void

    private static let shown = 3

    private var listing: NotebookDiscoverySession.Listing { session.listing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headline)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if session.isSearching {
                    ProgressView().controlSize(.small)
                }
                Button {
                    session.dismissListing()
                } label: {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .disabled(session.isImporting)
                .help(session.isSearching ? "Stop and put the search away" : "Put these results away")
                .accessibilityLabel("Close results")
                .accessibilityIdentifier("notebook.sources.discovery.close")
            }
            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
        .accessibilityIdentifier("notebook.sources.discovery")
    }

    private var headline: String {
        switch listing.phase {
        case .idle, .searching:
            return session.mode == .web ? "Searching the web…" : "Searching PubMed…"
        case .refused:
            return "The web search is off"
        case .failed:
            return session.mode == .web ? "The web search didn't finish" : "PubMed didn't answer"
        case .results:
            return NotebookDiscoveryCardText.headline(mode: session.mode, rows: listing.rows)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch listing.phase {
        case .idle, .searching:
            if let query = session.query.nilIfBlank {
                line("\u{201C}\(query)\u{201D}")
            }
        case .refused(let message):
            line(message)
            Button("Search PubMed Instead") { session.searchPapersInstead(vm: vm) }
                .buttonStyle(.hoverWash(tint: .accentColor))
                .accessibilityIdentifier("notebook.sources.discovery.searchPapers")
        case .failed(let message):
            line(message)
        case .results:
            ForEach(listing.rows.prefix(Self.shown)) { row in
                preview(row)
            }
            footer
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .zoomedSystemFont(size: 11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }

    private func preview(_ row: NotebookDiscoveryRow) -> some View {
        Button { open(row) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.title)
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if row.holding != .new {
                        Image(systemName: "checkmark.circle.fill")
                            .zoomedSystemFont(size: 10)
                            .foregroundStyle(Color.accentColor)
                            .help("In your library")
                            .accessibilityLabel("In your library")
                    }
                }
                if let why = row.why ?? row.byline {
                    Text(why)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .help("Open \(row.site) beside the chat")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !listing.rows.isEmpty {
                Button(NotebookDiscoveryCardText.moreTitle(rowCount: listing.rows.count, shown: Self.shown)) {
                    showAll()
                }
                .buttonStyle(.hoverWash(tint: .accentColor))
                .accessibilityIdentifier("notebook.sources.discovery.more")
            }
            if session.mode == .web, let cost = listing.costUSD {
                Text(chatCostText(cost))
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .textSelection(.disabled)
                    .help("What this search cost")
            }
            Spacer(minLength: 0)
            if session.isImporting {
                ProgressView().controlSize(.small)
            }
            Button(addTitle) { session.importSelected(vm: vm) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(session.selectedCount == 0 || session.isImporting || !canImport)
                .help(addHelp)
                .accessibilityIdentifier("notebook.sources.discovery.add")
        }
    }

    private var addTitle: String {
        if session.isImporting { return "Adding…" }
        let count = session.selectedCount
        return count == 0 ? "Add" : "Add \(count)"
    }

    private var addHelp: String {
        guard canImport else { return "This notebook is read-only for you" }
        return session.selectedCount == 0
            ? "Tick results in the whole list to add them"
            : "Add the ticked results to Sources and to this notebook; one your library holds is filed, not imported again"
    }

    private var canImport: Bool {
        vm.discoveryCanImport(into: vm.notebook(id: notebook.id) ?? notebook)
    }

    /// Opens the page beside the chat without importing it; a page the
    /// library holds opens as the saved source.
    private func open(_ row: NotebookDiscoveryRow) {
        guard let url = URL(string: row.url), let windowState else { return }
        vm.openWebCitationInReader(url, title: row.title, in: windowState)
    }
}

/// The whole results list in the widened Sources column, Gemini's "Sources ›
/// Source Discovery": the way back to the column, then Discover's list with
/// its ticks, ↗, Select all, Add and Research this deeply.
struct NotebookDiscoveryResults: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let notebook: LearningGoalRecord
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .zoomedSystemFont(size: 10, weight: .semibold)
                        Text("Sources")
                            .zoomedSystemFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Back to the notebook's sources")
                .accessibilityIdentifier("notebook.sources.discovery.back")
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 8, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Results")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                Spacer(minLength: 0)
            }
            NotebookDiscoverView(
                notebook: notebook,
                showsModePicker: false,
                showsSearchField: false,
                fillsHeight: true,
                researchDeeply: researchDeeply
            )
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Research this deeply: a Deep Research chat in the notebook with the
    /// search's words typed, in this window; not offered for a notebook that
    /// takes nothing.
    private var researchDeeply: ((String) -> Void)? {
        guard let windowState, vm.notebookTakesMadeThings(notebook.id) else { return nil }
        let notebookID = notebook.id
        return { words in
            vm.inWindow(windowState) { vm.requestNotebookDeepResearch(notebookID: notebookID, question: words) }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
