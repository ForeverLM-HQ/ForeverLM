import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

func notebookCanAcceptCurrentDrag(goal: LearningGoalRecord, dragVisibility: StudioDragVisibility) -> Bool {
    // Notebook-folder drags reorder the rail; they are never source payloads for
    // Notebook panels or the row's existing add-to-Notebook drop affordance.
    if dragVisibility.draggedNotebookID != nil {
        return false
    }
    // Nor is a pane: dragging Schedule or Docs across the window must not light
    // up every notebook as if it were about to swallow the whole surface.
    if dragVisibility.isPaneDrag {
        return false
    }
    // Nor is a Doc a source: a chat takes it, a Notebook's source pool cannot.
    if dragVisibility.draggedArtifactID != nil {
        return false
    }
    if dragVisibility.draggedGroupName != nil {
        return true
    }
    let draggedIDs = dragVisibility.draggedArticleIds
    guard !draggedIDs.isEmpty else { return dragVisibility.isDragging }
    let existingIDs = Set(goal.items.map(\.sourceID))
    return draggedIDs.contains { !existingIDs.contains($0) }
}

/// The one shared cover for a grouped book. Chapter XHTML/PDF previews never stand in
/// for the cover: until the real cover resolves, the row shows a neutral book glyph.
private struct NotebookBookCoverThumbnail: View {
    @Environment(StudioViewModel.self) private var vm
    let groupName: String
    let sources: [StudioArticle]
    let size: CGSize

    @State private var coverPath: String?

    var body: some View {
        Group {
            if let coverPath {
                BookCoverThumbnail(
                    pdfPath: coverPath,
                    size: size,
                    placeholderSystemImage: "book.closed",
                    tint: .green
                )
            } else {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: size.width, height: size.height)
            }
        }
        .task(id: coverResolutionKey) {
            coverPath = await resolveCoverPath()
        }
    }

    // Re-resolve only when the group or its cached cover entry changes, so a negatively
    // cached (nil) result doesn't re-probe the filesystem on every render.
    private var coverResolutionKey: String {
        "\(groupName)|\(vm.bookCoverPaths[groupName] ?? "")"
    }

    private func resolveCoverPath() async -> String? {
        // vm.bookCoverPaths is cheap in-memory main-actor state; read it here, then hop
        // off-main only for the filesystem probe.
        if let coverPath = vm.bookCoverPaths[groupName] {
            return coverPath
        }
        let normalizedKeys = Set([
            groupName,
            vm.bookDisplayName(groupName),
        ].map(Self.normalizedNotebookBookKey))
        if let matchedPath = vm.bookCoverPaths.first(where: { entry in
            normalizedKeys.contains(Self.normalizedNotebookBookKey(entry.key))
        })?.value {
            return matchedPath
        }

        let sources = sources
        return await Task.detached(priority: .utility) {
            for source in sources {
                if let coverPath = Self.inferredBookCoverPath(for: source) {
                    return coverPath
                }
            }
            return nil
        }.value
    }

    nonisolated private static func inferredBookCoverPath(for source: StudioArticle) -> String? {
        let sourcePath = source.resolvedLocalPath
            ?? source.resolvedPDFPath
            ?? (source.url.hasPrefix("/") ? source.url : nil)
        guard let sourcePath else { return nil }

        var bookDir = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        if bookDir.lastPathComponent == "Chapters" {
            bookDir.deleteLastPathComponent()
        }

        for filename in ["cover.jpg", "cover.jpeg", "cover.png"] {
            let coverURL = bookDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: coverURL.path) {
                return coverURL.path
            }
        }
        return nil
    }

    nonisolated private static func normalizedNotebookBookKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum NotebookContextSourceGroup: Identifiable {
    case source(StudioArticle)
    case book(groupName: String, sources: [StudioArticle])

    var id: String {
        switch self {
        case .source(let source):
            return "source-\(source.id)"
        case .book(let groupName, _):
            return "book-\(groupName)"
        }
    }
}

enum NotebookContextSourceSearch {
    static func terms(in query: String) -> [String] {
        query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func matches(_ article: StudioArticle, terms: [String], extraHaystack: [String?] = []) -> Bool {
        let haystack = ([
            article.title,
            article.author,
            article.domain,
            article.url,
            article.publicURL,
            article.parentGroup,
            article.journal,
            article.publishedYear,
            article.sourceType.rawValue,
        ] + extraHaystack)
        .compactMap { $0 }
        .joined(separator: " ")

        return matchesText(haystack, terms: terms)
    }

    static func matchesText(_ text: String, terms: [String]) -> Bool {
        let haystack = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        return terms.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Notebook source pool (Sources tab)

/// What the notebook workspace hands its Sources column: where a row opens,
/// and how the Add sources sheet opens.
struct NotebookSourcePoolColumnActions {
    /// Opens a source in a pane of the notebook's window, in this window.
    let openSource: (StudioArticle) -> Void
    /// Opens the notebook's Add sources sheet.
    let addSources: () -> Void
    /// Whether the column shows a web or PubMed search's whole list, widened
    /// for it (`NotebookWorkspace.sourcesExpanded`).
    var isShowingResults = false
    /// Opens or closes that list.
    var showResults: (Bool) -> Void = { _ in }
}

/// Searchable, droppable notebook source pool grouped by understanding state.
///
/// In the notebook workspace (`column` set) it is the notebook's Sources
/// column, drawn as Gemini Notebook's: one list, each row the source's thumbnail,
/// its title on one line and a ＋ that adds it to the notebook's chats, a tick
/// once it is in (`NotebookChatToggle`); "N of M in chat" (or "None in chat")
/// while not every source is in, and "All N in chat" under the pointer while
/// every one is;
/// under the pointer a row shows its ⋯ with Open, Open in
/// Other Window and Remove from Notebook; a row click opens the Reader in the
/// pane, the notebook's ⋯ opens the Add sources sheet, and an empty
/// notebook, or one whose field is in use with no words, shows the Library
/// itself in the column (`NotebookLibraryBrowser`). Under the notebook's
/// own sources, each context notebook is a group of its own with a box that
/// puts it into the chats
/// (`NotebookContextNotebookGroup`). Its one field searches the notebook,
/// the whole library and the web or PubMed (`NotebookSourcesSearchField`,
/// docs/notebooks-design.md, "The Sources column's search").
struct NotebookSourcePoolView: View {
    @Environment(StudioViewModel.self) private var vm
    private let dragVisibility = StudioDragVisibility.shared
    let goal: LearningGoalRecord
    /// The notebook workspace's actions; nil for the Notebook page's pool.
    var column: NotebookSourcePoolColumnActions? = nil

    @PreferenceStorage(Prefs.Studio.metadataVisibility, default: MetadataVisibilitySettings()) private var metadataVisibility
    @State private var sourceSearchText = ""
    /// How the sources are ordered (`NotebookSourceSort`), this Mac's choice.
    @WindowStorage(Prefs.Readers.notebookSourcesSort, default: NotebookSourceSort.standard) private var sourceSort
    /// Where the notebook column's field searches: the notebook and the
    /// library as you type, or the web or PubMed on Return.
    @State private var searchScope: NotebookSourcesSearchScope = .library
    @State private var collapsedBookGroups: Set<String> = []
    /// The books whose chapters the notebook column shows; a book's row is
    /// closed until its chevron opens it.
    @State private var expandedBookGroups: Set<String> = []
    @State private var isTargeted = false
    /// PDFs from Finder or a browser are over the notebook's column.
    @State private var isPDFTargeted = false
    @State private var isAddingSources = false
    @State private var isPaywalledExpanded = false
    /// The context notebooks whose group is open; each starts folded.
    @State private var expandedContextNotebooks: Set<String> = []
    /// The pointer is over the notebook's column, which shows Select all
    /// while every source is ticked (`selectAllRow`).
    @State private var isPointerOverColumn = false
    /// The learner went into the field of a notebook that holds sources: the
    /// column shows the Library until Done or Escape, so a click in the
    /// Library's list, which takes the focus, never puts it away mid-browse.
    @State private var isBrowsingLibrary = false

    private var plan: NotebookWorkbenchPlan {
        NotebookWorkbenchPlan(goal: goal)
    }

    private var supportedDropTypes: [UTType] { mcpSourceContextDropTypes }

    private var canAcceptCurrentDrag: Bool {
        notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: dragVisibility)
    }

    /// Whether this notebook's sources can change from here: a live notebook
    /// of the open library this account can edit (`importableNotebook`). A
    /// read-only team's notebook, or an archived one, is read: its rows keep
    /// their boxes for what a chat reads, which is the learner's own, but
    /// nothing adds, approves or removes.
    private var canChangeNotebook: Bool {
        vm.importableNotebook(goal.id) != nil
    }

    /// Whether the notebook has no sources and nothing waiting to join it.
    private var isEmptyNotebook: Bool {
        plan.approvedCount == 0 && plan.pendingSuggestions.isEmpty
            && JournalWatchRunner.shared.pendingCount(for: goal.id) == 0
    }

    /// The notebook's web and PubMed lists, kept for the life of the app so
    /// putting the column away never throws a paid search away.
    private var discoverySession: NotebookDiscoverySession {
        NotebookDiscoverySession.session(forNotebook: goal.id, vm: vm)
    }

    /// Whether the column shows the Library (`NotebookLibraryBrowser`):
    /// Library scope with no words, while the notebook is empty or the
    /// learner went into the field.
    private var showsLibraryBrowser: Bool {
        guard let column, !column.isShowingResults, searchScope == .library,
              typedSearchQuery.isEmpty else { return false }
        return isBrowsingLibrary || (isEmptyNotebook && contextNotebooks.isEmpty)
    }

    /// Whether the column's words are searching the notebook and the
    /// library: Library scope, with something typed.
    private var searchesLibrary: Bool {
        column != nil && searchScope == .library && !typedSearchQuery.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let column {
                // No "Sources" heading over the field: the
                // notebook's name heads the column above it
                // (`NotebookWorkspaceView.notebookTitle`), and the field says
                // what it searches.
                NotebookSourcesSearchField(
                    text: $sourceSearchText,
                    scope: $searchScope,
                    subject: goal.title,
                    submit: submitSearch,
                    focusChanged: { focused in
                        if focused, searchScope == .library { isBrowsingLibrary = true }
                    },
                    escape: escapeSearch
                )
                if column.isShowingResults {
                    NotebookDiscoveryResults(notebook: goal, close: { column.showResults(false) })
                } else {
                    if discoverySession.listing.phase != .idle {
                        NotebookDiscoveryCard(
                            session: discoverySession,
                            notebook: goal,
                            showAll: { column.showResults(true) }
                        )
                    }
                    if !showsLibraryBrowser, !isEmptyNotebook || !contextNotebooks.isEmpty {
                        selectAllRow
                    }
                }
            } else {
                toolbar
                if isAddingSources {
                    NotebookAddSourcesPicker(goal: goal, onDismiss: { isAddingSources = false })
                }
            }
            if showsLibraryBrowser {
                NotebookLibraryBrowser(
                    done: isEmptyNotebook && contextNotebooks.isEmpty ? nil : { isBrowsingLibrary = false }
                )
            } else if column?.isShowingResults != true {
                poolContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: goal.id) { _, _ in isBrowsingLibrary = false }
        .onHover { hovering in
            guard column != nil, isPointerOverColumn != hovering else { return }
            isPointerOverColumn = hovering
        }
        // A scope with a list of its own shows that list in the card; the
        // library's answers as the words are typed.
        .onChange(of: searchScope) { _, scope in
            guard let mode = scope.discoveryMode, !discoverySession.isImporting else { return }
            discoverySession.mode = mode
        }
        // The chip follows the list on screen when something else moves it —
        // Search PubMed Instead on a refused web search, another window.
        .onChange(of: discoverySession.mode) { _, mode in
            guard searchScope != .library else { return }
            let scope: NotebookSourcesSearchScope = mode == .web ? .web : .papers
            if searchScope != scope { searchScope = scope }
        }
        // A list put away while the column shows it gives the column back.
        .onChange(of: discoverySession.listing.phase == .idle) { _, isIdle in
            if isIdle, column?.isShowingResults == true { column?.showResults(false) }
        }
        .overlay {
            StudioDropZoneOverlay(
                isActive: isTargeted,
                isVisible: canAcceptCurrentDrag,
                title: "Add to Notebook",
                systemImage: "folder.badge.plus",
                cornerRadius: 8,
                inset: 4
            )
        }
        .overlay {
            if isPDFTargeted {
                StudioDropZoneOverlay(
                    isActive: true,
                    isVisible: true,
                    title: "Import as paper into Notebook",
                    systemImage: "doc.badge.plus",
                    cornerRadius: 8,
                    inset: 4
                )
            }
        }
        // In a notebook's column, PDFs from Finder or a browser are taken
        // too: imported as papers, then filed in the notebook.
        .onDrop(
            of: column == nil ? supportedDropTypes : supportedDropTypes + PaperFileDrop.types,
            delegate: NotebookPoolDropDelegate(
                acceptsPDFs: column != nil && canChangeNotebook,
                canAcceptSourceDrag: canAcceptCurrentDrag,
                isTargeted: $isTargeted,
                isPDFTargeted: $isPDFTargeted,
                dropSources: { providers in
                    // Accept on the dropped payload alone. `canAcceptCurrentDrag` reads transient
                    // drag-visibility state the mouse-up monitors clear on release — i.e. exactly
                    // when the drop fires — so gating the drop on it dropped payloads at random.
                    // The handler ignores non-source providers and the add path skips members.
                    StudioDragVisibility.shared.endSoon()
                    return NotebookSourceDropHandler.handle(providers: providers, vm: vm, notebookID: goal.id)
                },
                dropPDFs: importDroppedPDFs
            )
        )
    }

    /// PDFs dropped on the notebook's column: each imported as a paper and
    /// filed in the notebook, and a toast for each saying what happened.
    private func importDroppedPDFs(_ providers: [NSItemProvider]) -> Bool {
        let notebookID = goal.id
        let notebookTitle = goal.title
        return PaperFileDrop.load(
            providers,
            deliver: { url, displayName, staged in
                PaperIngestionDiagnostics.recordDropAccepted(filename: displayName)
                Task {
                    let outcome = await vm.importPaperPDF(at: url, intoNotebook: notebookID)
                    if let staged { PaperDropStager.cleanup(staged) }
                    if let sourceID = outcome.sourceID {
                        PaperIngestionDiagnostics.recordDropImported(filename: displayName, sourceID: sourceID)
                    }
                    vm.showToast(StudioViewModel.notebookImportToast(outcome, notebookTitle: notebookTitle))
                }
            },
            fail: { filename, message in
                let displayName = PaperDropStager.safePDFFilename(filename)
                PaperIngestionDiagnostics.recordDropFailure(filename: displayName, message: message)
                vm.showToast("Couldn\u{2019}t import \(displayName): \(message)")
            }
        )
    }

    /// Escape in the column's field: the words first, then the Library back
    /// to the notebook's sources.
    private func escapeSearch() {
        if !sourceSearchText.isEmpty {
            sourceSearchText = ""
        } else {
            isBrowsingLibrary = false
        }
    }

    /// Return in the column's field: in Web or PubMed, that search; in Library
    /// nothing, which searches only the library
    /// (`NotebookSourcesSearchScope.submission`).
    private func submitSearch() {
        guard let mode = NotebookSourcesSearchScope.submission(scope: searchScope, query: sourceSearchText) else { return }
        // No words and a notebook that says nothing of itself — a placeholder
        // name, no instructions, no sources — leaves a paid search nothing to
        // look for but "New notebook 2".
        if typedSearchQuery.isEmpty, isEmptyNotebook, NotebookNaming.isPlaceholder(goal.title),
           (goal.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        runDiscovery(mode)
    }

    /// Takes the column's words to the web or PubMed: the scope follows, and
    /// the search replaces that list, its card at the top of the column.
    private func runDiscovery(_ mode: NotebookDiscoverySession.Mode) {
        let session = discoverySession
        guard !session.isImporting else { return }
        searchScope = mode == .web ? .web : .papers
        session.mode = mode
        session.query = typedSearchQuery
        session.search(vm: vm)
    }

    /// Search and its one action, kept as a cluster at the leading edge. Letting
    /// the field stretch the full column width left the button stranded a
    /// thousand points away from the thing it acts on.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sources", text: $sourceSearchText)
                .textFieldStyle(.plain)
            if !sourceSearchText.isEmpty {
                Button { sourceSearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .zoomedSystemFont(size: 13)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .frame(maxWidth: 380)
    }

    /// What the chats read, behind a chat bubble, and the ＋ that adds every
    /// source or takes them all out: "All 12 in chat", "8 of 12 in chat",
    /// "None in chat". The count is the notebook's whole chat pool
    /// (`notebookChatTally`), as the chat and the guide count it.
    ///
    /// While every source is ticked, which is how a notebook starts, the row
    /// is drawn only while the pointer is over the column (product owner,
    /// 2026-10-06: "cleaner and fewer buttons and bells and whistles"), its
    /// place held so the list never jumps; "8 of 12 in chat" is state and
    /// always shows.
    @ViewBuilder
    private var selectAllRow: some View {
        let tally = vm.notebookChatTally(goal)
        let state = NotebookTickState.of(ticked: tally.inChat, total: tally.total)
        // Every source in chat is the resting state: a filmed column draws no
        // row for it, not even the invisible one that held its place and left a
        // gap under the search field (screen record mode).
        if tally.total > 0, !(vm.isScreenRecordModeActive && state == .checked) {
            HStack(spacing: 6) {
                if state != .checked || isPointerOverColumn {
                    Label {
                        Text(Self.chatTallyLine(inChat: tally.inChat, total: tally.total))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "bubble.left")
                    }
                    .labelStyle(.titleAndIcon)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    Spacer(minLength: 0)
                    sortMenu
                    NotebookChatToggle(
                        state: state,
                        subject: "every source",
                        action: { vm.setAllNotebookSourcesInChat(state != .checked, notebookID: goal.id) }
                    )
                    .accessibilityIdentifier("notebook.sources.selectAll")
                } else {
                    // The box built only under the pointer, as a row's ⋯
                    // is; a hidden face keeps the row's height.
                    Text(Self.chatTallyLine(inChat: tally.inChat, total: tally.total))
                        .zoomedSystemFont(size: 12)
                        .hidden()
                    Spacer(minLength: 0)
                    // An order the learner chose stays in view, so a list
                    // that is not in its usual order says how it is.
                    if sourceSort == .type {
                        Color.clear
                            .frame(width: 24, height: 22)
                    } else {
                        sortMenu
                    }
                    Color.clear
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    /// The head of the Sources column's chat ticks, saying what the chats
    /// read: "None in chat", "8 of 12 in chat", "All 12 in chat".
    static func chatTallyLine(inChat: Int, total: Int) -> String {
        if inChat <= 0 { return "None in chat" }
        if inChat >= total { return "All \(total) in chat" }
        return "\(inChat) of \(total) in chat"
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField

            Button {
                isAddingSources.toggle()
            } label: {
                Label("Add sources", systemImage: isAddingSources ? "chevron.up" : "plus")
                    .zoomedSystemFont(size: 12, weight: .medium)
            }
            .buttonStyle(.bordered)
            .help("Find library sources to add that aren't already in this notebook")

            sortMenu

            Spacer(minLength: 0)
        }
    }

    /// What the sort reads off this notebook beyond the sources themselves.
    private func sortInputs(items: [LearningGoalItem]) -> NotebookSourceSortInputs {
        var statusBySource: [String: Int] = [:]
        for item in plan.toRead { statusBySource[item.sourceID] = 0 }
        for item in plan.reading { statusBySource[item.sourceID] = 1 }
        for item in plan.understood { statusBySource[item.sourceID] = 2 }
        return NotebookSourceSortInputs(
            items: items,
            bookTitle: { vm.bookDisplayName($0) },
            statusRank: { statusBySource[$0] ?? 0 },
            chatState: { chatState(of: $0) }
        )
    }

    /// The order's menu, as the Space list's Sort By: a check on the
    /// chosen one, grey while the list is in its own type order and the
    /// accent once it is not, so a list that reads oddly says why.
    private var sortMenu: some View {
        Menu {
            ForEach(NotebookSourceSort.menuGroups) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Button {
                            sourceSort = option
                        } label: {
                            if sourceSort == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(sourceSort == .type ? Color.secondary : Color.accentColor)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .fixedSize()
        .help("Sort sources: \(sourceSort.title)")
        .accessibilityLabel("Sort sources")
        .accessibilityIdentifier("notebook.sources.sort")
    }

    @ViewBuilder
    private var poolContent: some View {
        // Approved sources are shown grouped by source type — Papers, Articles,
        // Podcasts, Books… in the canonical sidebar order — and sorted alphabetically
        // by title within each type. Suggestions (which need approve/reject controls)
        // and paywalled sources keep their own sections.
        let approvedItems = plan.toRead + plan.reading + plan.understood
        let approvedArticles = filteredArticles(for: approvedItems, includesPaywalled: false)
        let typeSections = sourceSort == .type ? notebookTypeSections(from: approvedArticles) : []
        let sortedGroups = sourceSort == .type ? [] : notebookSortedGroups(
            from: approvedArticles,
            sort: sourceSort,
            inputs: sortInputs(items: approvedItems)
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if searchesLibrary, !(typeSections.isEmpty && sortedGroups.isEmpty) {
                    Text("In this notebook")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, -6)
                }
                NotebookJournalSuggestionsSection(goal: goal, searchTerms: NotebookContextSourceSearch.terms(in: trimmedSearchQuery))
                if !plan.pendingSuggestions.isEmpty {
                    understandingSection(title: "Suggested", state: .suggested, items: plan.pendingSuggestions, showApproval: true, hidesPapersByDefault: true)
                }
                if column != nil {
                    // Gemini Notebook's one list: no type headings, the
                    // row's glyph says the kind, the type order kept.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sourceSort == .type ? typeSections.flatMap(\.groups) : sortedGroups) { group in
                            poolGroupView(group, goalItems: approvedItems, showApproval: false)
                        }
                    }
                } else if sourceSort == .type {
                    ForEach(typeSections) { section in
                        typeSection(section, goalItems: approvedItems)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sortedGroups) { group in
                            poolGroupView(group, goalItems: approvedItems, showApproval: false)
                        }
                    }
                }
                paywalledSection
                if let column {
                    contextNotebookSections(column)
                }
                if searchesLibrary {
                    // The library's matches for the words, under the
                    // notebook's own, and the way to the web and PubMed.
                    NotebookLibraryMatches(goal: goal, query: typedSearchQuery, searchElsewhere: runDiscovery)
                } else if isEmptyNotebook {
                    emptyNotebookLine
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// What an empty notebook's column says under its field, by what the
    /// field searches. It was "Drop sources from the sidebar to add them."
    /// in every scope, inside the column that is that sidebar, and in Web,
    /// where nothing was listed to drop (product owner, 2026-10-12: "this
    /// drop sources from the sidebar doesn't make sense; this IS the
    /// sidebar"). Library with no words shows the Library itself
    /// (`NotebookLibraryBrowser`), so its line is only for the Notebook page.
    @ViewBuilder
    private var emptyNotebookLine: some View {
        switch (column != nil, searchScope) {
        case (true, .web):
            SpaceEmptyLine(systemImage: "globe", text: "Search the web, then add what you want")
        case (true, .papers):
            SpaceEmptyLine(systemImage: "text.book.closed", text: "Search PubMed, then add the papers you want")
        default:
            SpaceEmptyLine(systemImage: "tray.and.arrow.down", text: "Drop sources or PDFs here")
        }
    }

    /// Approved sources marked paywalled, collapsed into one section at the
    /// bottom. They can't be read, so they shouldn't pad "To read" ahead of the
    /// sources you can actually study. Suggestions stay put — a paywalled
    /// suggestion is exactly the one you want to see while triaging.
    private var paywalledItems: [LearningGoalItem] {
        (plan.toRead + plan.reading + plan.understood).filter { isPaywalled($0) }
    }

    private func isPaywalled(_ item: LearningGoalItem) -> Bool {
        vm.articlesById[item.sourceID]?.hasPaywallMarker == true
    }

    @ViewBuilder
    private var paywalledSection: some View {
        let items = paywalledItems
        let articles = filteredArticles(for: items, includesPaywalled: true)
        if !articles.isEmpty {
            // A search should reach into the collapsed section rather than
            // silently hiding matches.
            let isExpanded = isPaywalledExpanded || !trimmedSearchQuery.isEmpty
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isPaywalledExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .zoomedSystemFont(size: 9, weight: .semibold)
                            .frame(width: 10)
                        Text("Marked paywalled")
                            .zoomedSystemFont(size: 11, weight: .semibold)
                        Text("\(articles.count)")
                            .zoomedSystemFont(size: 10, weight: .medium)
                            .foregroundStyle(.tertiary)
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
                if isExpanded {
                    LazyVStack(alignment: .leading, spacing: column == nil ? 6 : 0) {
                        ForEach(notebookContextGroups(from: articles)) { group in
                            poolGroupView(group, goalItems: items, showApproval: false)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func understandingSection(
        title: String,
        state: NotebookPoolState,
        items: [LearningGoalItem],
        showApproval: Bool = false,
        hidesPapersByDefault: Bool = false
    ) -> some View {
        let articles = filteredArticles(for: items, includesPaywalled: showApproval)
        // Discovery drops papers into the approve/reject Suggested list alongside
        // articles, videos and podcasts, where they read as noise. Keep them out of
        // the default view — but let a search reach them (mirroring the paywalled
        // section) so a specific suggested paper can still be found and approved.
        let visibleArticles = hidesPapersByDefault && trimmedSearchQuery.isEmpty
            ? articles.filter { $0.sourceType != .paper }
            : articles
        if !visibleArticles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    // Same tint the header's progress bar gives this state, so a
                    // section and its share of the bar are recognisably the same thing.
                    Circle()
                        .fill(state.tint)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text("\(visibleArticles.count)")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.tertiary)
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)
                }
                // Lazy, as the notebook's own rows are: a section is one
                // child of the column's LazyVStack, so a plain stack here
                // would build every suggestion and its ✓ and × at once.
                LazyVStack(alignment: .leading, spacing: column == nil ? 6 : 0) {
                    ForEach(notebookContextGroups(from: visibleArticles)) { group in
                        poolGroupView(group, goalItems: items, showApproval: showApproval)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func typeSection(_ section: NotebookTypeSection, goalItems: [LearningGoalItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(section.title)
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text("\(section.groups.count)")
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
            }
            ForEach(section.groups) { group in
                poolGroupView(group, goalItems: goalItems, showApproval: false)
            }
        }
    }

    /// Buckets the pool's approved sources into type sections — Papers, Articles,
    /// Podcasts, Books… ordered by the canonical sidebar rank — with book chapters
    /// collapsed into their book group and the groups sorted alphabetically by title
    /// (book groups by their display name) within each section.
    private func notebookTypeSections(from articles: [StudioArticle]) -> [NotebookTypeSection] {
        let bookSourcesByGroup = Dictionary(
            grouping: articles.filter { article in
                article.sourceType == .book
                    && article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            },
            by: { $0.parentGroup ?? "" }
        )

        var emittedBookGroups = Set<String>()
        var entries: [(title: String, rank: Int, sortKey: String, group: NotebookContextSourceGroup)] = []
        for article in articles {
            let rank = notebookPoolTypeRank[article.sourceType] ?? Int.max
            let title = notebookTypeSectionTitle(for: article.sourceType)
            if article.sourceType == .book,
               let groupName = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
               !groupName.isEmpty {
                guard emittedBookGroups.insert(groupName).inserted else { continue }
                entries.append((
                    title: title,
                    rank: rank,
                    sortKey: vm.bookDisplayName(groupName),
                    group: .book(groupName: groupName, sources: notebookSortedBookChapters(bookSourcesByGroup[groupName] ?? [article]))
                ))
            } else {
                entries.append((title: title, rank: rank, sortKey: article.title, group: .source(article)))
            }
        }

        return Dictionary(grouping: entries, by: { $0.title })
            .map { title, sectionEntries in
                NotebookTypeSection(
                    title: title,
                    rank: sectionEntries.first?.rank ?? Int.max,
                    groups: sectionEntries
                        .sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
                        .map { $0.group }
                )
            }
            .sorted { lhs, rhs in
                lhs.rank != rhs.rank
                    ? lhs.rank < rhs.rank
                    : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    @ViewBuilder
    private func poolGroupView(_ group: NotebookContextSourceGroup, goalItems: [LearningGoalItem], showApproval: Bool) -> some View {
        switch group {
        case .source(let article):
            if let item = goalItems.first(where: { $0.sourceID == article.id }) {
                poolItemRow(article: article, item: item, showApproval: showApproval)
            }
        case .book(let groupName, let sources):
            if column != nil {
                // The notebook's one list: the book is a row like the
                // others, its chevron opening the chapters under it, closed
                // until asked — a book's forty chapters would bury the list.
                VStack(alignment: .leading, spacing: 0) {
                    NotebookPoolBookGroupLabel(
                        goal: goal,
                        groupName: groupName,
                        sources: sources,
                        chatState: showApproval ? nil : chatState(of: sources.map(\.id)),
                        onToggleChat: { toggleChat(sources.map(\.id)) },
                        isExpanded: Binding(
                            get: { expandedBookGroups.contains(groupName) },
                            set: { isExpanded in
                                if isExpanded { expandedBookGroups.insert(groupName) }
                                else { expandedBookGroups.remove(groupName) }
                            }
                        )
                    )
                    if expandedBookGroups.contains(groupName) {
                        BookChapterStack {
                            bookChapterRows(sources, goalItems: goalItems, showApproval: showApproval)
                        }
                    }
                }
            } else {
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedBookGroups.contains(groupName) },
                    set: { isExpanded in
                        if isExpanded { collapsedBookGroups.remove(groupName) }
                        else { collapsedBookGroups.insert(groupName) }
                    }
                )) {
                    BookChapterStack {
                        bookChapterRows(sources, goalItems: goalItems, showApproval: showApproval)
                    }
                } label: {
                    NotebookPoolBookGroupLabel(
                        goal: goal,
                        groupName: groupName,
                        sources: sources
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func bookChapterRows(_ sources: [StudioArticle], goalItems: [LearningGoalItem], showApproval: Bool) -> some View {
        ForEach(sources) { article in
            if let item = goalItems.first(where: { $0.sourceID == article.id }) {
                // Structural "Part N" TOC nodes carry no readable content, so they
                // drop out of the settled chapter list — but while approving they
                // still need their approve/reject buttons, so they stay a row then.
                if BookChapterTitle.isPartDivider(article), !showApproval {
                    EmptyView()
                } else {
                    poolItemRow(
                        article: article,
                        item: item,
                        showApproval: showApproval,
                        hidesBookContext: true,
                        showsChapterNumber: true
                    )
                }
            }
        }
    }

    // MARK: Context notebooks

    /// The notebooks this one links to that this Mac has a record of, in
    /// link order: each a group under the notebook's own sources.
    private var contextNotebooks: [LearningGoalRecord] {
        (goal.relatedNotebookIDs ?? []).compactMap { id in
            guard id != goal.id, let notebook = vm.notebook(id: id), notebook.isNotebook else { return nil }
            return notebook
        }
    }

    /// Each context notebook as a group: its sources the library holds, in
    /// its own order. The column's words narrow them as they narrow the
    /// notebook's own, opening a group that matches and leaving out one
    /// that does not.
    @ViewBuilder
    private func contextNotebookSections(_ column: NotebookSourcePoolColumnActions) -> some View {
        let terms = NotebookContextSourceSearch.terms(in: trimmedSearchQuery)
        ForEach(contextNotebooks) { notebook in
            let sources = notebook.approvedSourceIDs.compactMap { vm.articlesById[$0] }
            let shown = terms.isEmpty ? sources : sources.filter { NotebookContextSourceSearch.matches($0, terms: terms) }
            if terms.isEmpty || !shown.isEmpty {
                NotebookContextNotebookGroup(
                    goal: goal,
                    notebook: notebook,
                    sourceCount: sources.count,
                    sources: shown,
                    metadataVisibility: metadataVisibility,
                    isExpanded: Binding(
                        get: { !terms.isEmpty || expandedContextNotebooks.contains(notebook.id) },
                        set: { isExpanded in
                            if isExpanded { expandedContextNotebooks.insert(notebook.id) }
                            else { expandedContextNotebooks.remove(notebook.id) }
                        }
                    ),
                    canTakeOut: canChangeNotebook,
                    openSource: column.openSource
                )
            }
        }
    }

    /// Whether the notebook's chats read these sources: all, some or none.
    private func chatState(of sourceIDs: [String]) -> NotebookTickState {
        let ticked = sourceIDs.filter { vm.isNotebookSourceInChat($0, notebookID: goal.id) }.count
        return .of(ticked: ticked, total: sourceIDs.count)
    }

    /// Ticks the sources for chat, or clears them when every one was ticked.
    private func toggleChat(_ sourceIDs: [String]) {
        let include = chatState(of: sourceIDs) != .checked
        vm.setNotebookSources(sourceIDs, inChat: include, notebookID: goal.id)
    }

    @ViewBuilder
    private func poolItemRow(
        article: StudioArticle,
        item: LearningGoalItem,
        showApproval: Bool,
        hidesBookContext: Bool = false,
        showsChapterNumber: Bool = false
    ) -> some View {
        // An approved source marked paywalled only ever lists under "Marked
        // paywalled" (the other sections leave it out), and that header says
        // it all: its row is the glyph and the title, no warning, no "paywall"
        // line, no box, since it holds no text a chat could read (product
        // owner, 2026-11-08, of the shelf with a ! and a + on every row:
        // "this looks bad").
        let isOnPaywallShelf = !showApproval && isPaywalled(item)
        HStack(spacing: 6) {
            NotebookPoolSourceRow(
                article: article,
                goal: goal,
                metadataVisibility: metadataVisibility,
                hidesBookContext: hidesBookContext,
                showsChapterNumber: showsChapterNumber,
                scheduleDays: vm.scheduleAssignableDays(goalID: goal.id),
                // A waiting suggestion is not in the notebook yet, so it has
                // no box; it gets its ✓ and × instead.
                isInChat: showApproval || column == nil || isOnPaywallShelf
                    ? nil
                    : vm.isNotebookSourceInChat(article.id, notebookID: goal.id),
                onToggleChat: { toggleChat([article.id]) },
                onOpen: column.map { column in { column.openSource(article) } },
                isOnPaywallShelf: isOnPaywallShelf
            )
            if showApproval {
                Button {
                    Task { await vm.setCompanionReviewState(goalID: goal.id, sourceIDs: [item.sourceID], approved: true) }
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.hoverWash)
                .disabled(!canChangeNotebook)
                .help("Add to Notebook")
                Button {
                    Task { await vm.setCompanionReviewState(goalID: goal.id, sourceIDs: [item.sourceID], approved: false) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.hoverWash)
                .disabled(!canChangeNotebook)
                .help("Not for this notebook")
            }
        }
    }

    /// What the field holds, trimmed.
    private var typedSearchQuery: String {
        sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words the notebook's own sources are filtered by: in the notebook
    /// column only while the field searches the library — words typed for
    /// the web or PubMed leave the notebook's list whole.
    private var trimmedSearchQuery: String {
        if column != nil, searchScope != .library { return "" }
        return typedSearchQuery
    }

    /// A page just added that still wears the address, or a stub like
    /// "| bioRxiv", for a title: it joins the list once its real title lands,
    /// which a link added from a chat's Web sources has from the first frame
    /// (`addCitedPageToSources`). A failed fetch stays listed, to be removed.
    private static func awaitsItsTitle(_ article: StudioArticle) -> Bool {
        guard article.sourceType == .article || article.sourceType == .paper,
              article.state == .queued || article.state == .fetching else { return false }
        return article.title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("|")
            || StudioViewModel.titleNeedsResolution(article.title, domain: article.domain, url: article.url)
    }

    private func filteredArticles(
        for items: [LearningGoalItem],
        includesPaywalled: Bool
    ) -> [StudioArticle] {
        let articles = items
            .filter { includesPaywalled || !isPaywalled($0) }
            .compactMap { vm.articlesById[$0.sourceID] }
            .filter { !Self.awaitsItsTitle($0) }
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return articles }
        let terms = NotebookContextSourceSearch.terms(in: query)
        guard !terms.isEmpty else { return articles }
        return articles.filter { NotebookContextSourceSearch.matches($0, terms: terms) }
    }

}

/// One context notebook in a notebook's Sources column
/// (docs/notebooks-design.md, "Context notebooks"): "From <title> · N
/// sources", folded at first; its box puts the notebook into this one's
/// chats as the learner left it, ticks every source of it once it is in,
/// or takes it out (`setNotebookContextNotebooks`), and reads mixed while
/// some of its sources are unticked; its × takes it out of context,
/// unlinked (`takeContextNotebookOut`). Open, its sources are rows with
/// their own boxes; ticking one while the group is out puts the group in
/// with that source alone (`NotebookChatContext.settingSources`). The rows
/// are the context notebook's, so none of them is removed from here.
private struct NotebookContextNotebookGroup: View {
    @Environment(StudioViewModel.self) private var vm
    /// The notebook whose column this is.
    let goal: LearningGoalRecord
    /// The context notebook.
    let notebook: LearningGoalRecord
    /// Its sources the library holds, whatever the column's words.
    let sourceCount: Int
    /// The rows shown when the group is open.
    let sources: [StudioArticle]
    let metadataVisibility: MetadataVisibilitySettings
    @Binding var isExpanded: Bool
    /// Unlinking writes the notebook, which a read-only team's or an
    /// archived notebook does not take; the box is the learner's own.
    let canTakeOut: Bool
    let openSource: (StudioArticle) -> Void

    @State private var isHovering = false

    private var title: String { NotebookTitle(notebook.title).text }

    /// Out of the chats: unticked. In: checked, mixed while some of its
    /// sources are unticked, unticked when all are; a group with nothing a
    /// chat could read reads checked while it is in.
    private var state: NotebookTickState {
        guard let tally = vm.notebookContextNotebookTally(notebook.id, in: goal) else { return .unchecked }
        return tally.total == 0 ? .checked : .of(ticked: tally.inChat, total: tally.total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .zoomedSystemFont(size: 9, weight: .semibold)
                            .frame(width: 10)
                        // The name wins the width; the rule takes what is left.
                        Text("From \(title) \u{00B7} \(sourceCount) source\(sourceCount == 1 ? "" : "s")")
                            .zoomedSystemFont(size: 11, weight: .semibold)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(minWidth: 8, maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
                .accessibilityLabel(isExpanded ? "Hide \(title)'s sources" : "Show \(title)'s sources")
                // Built only under the pointer, the hidden glyph holding its
                // place: a button at opacity 0 is still a live control
                // (`NotebookPoolSourceRow`'s ⋯). The action below reaches it
                // with no pointer.
                if isHovering {
                    Button {
                        Task { await vm.takeContextNotebookOut(notebook.id, of: goal.id) }
                    } label: {
                        RowRemoveGlyph()
                    }
                    .buttonStyle(.hoverWash)
                    .disabled(!canTakeOut)
                    .help("Take Out of Context")
                    .accessibilityLabel("Take \(title) out of context")
                } else {
                    RowRemoveGlyph()
                        .hidden()
                }
                NotebookChatToggle(
                    state: state,
                    subject: title,
                    action: { vm.setNotebookContextNotebooks([notebook.id], inChat: state != .checked, notebookID: goal.id) }
                )
                .accessibilityIdentifier("notebook.sources.contextNotebook")
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .accessibilityAction(named: Text("Take Out of Context")) {
                guard canTakeOut else { return }
                Task { await vm.takeContextNotebookOut(notebook.id, of: goal.id) }
            }
            if isExpanded {
                // What a new chat reads, once per draw, so a row asks a set.
                let chatSourceIDs = Set(vm.notebookChatSourceIDs(goal))
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sources) { article in
                        let isInChat = chatSourceIDs.contains(article.id)
                        NotebookPoolSourceRow(
                            article: article,
                            goal: goal,
                            metadataVisibility: metadataVisibility,
                            scheduleDays: [],
                            isInChat: isInChat,
                            onToggleChat: {
                                vm.setNotebookSources([article.id], inChat: !isInChat, through: notebook.id, notebookID: goal.id)
                            },
                            onOpen: { openSource(article) },
                            isOwnSource: false
                        )
                    }
                }
            }
        }
    }
}

/// Add a Notebook to Context: the popover under the notebook's name, from its
/// ⋯ menu's "Add a Notebook to Context…" (`NotebookPickerPopover`, never a
/// menu of every notebook). A pick links the notebook and puts it into this
/// notebook's chats in one step (`addContextNotebook`); one already linked
/// wears a tick, and a pick on it takes it out again
/// (`takeContextNotebookOut`). The popover stays open for the next.
struct NotebookContextPicker: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let close: () -> Void

    var body: some View {
        let live = vm.notebook(id: goal.id) ?? goal
        let linked = Set(live.relatedNotebookIDs ?? [])
        NotebookPickerPopover(
            placeholder: "Search notebooks",
            notebooks: vm.notebooks.filter { $0.id != goal.id },
            checkedIDs: linked,
            staysOpenOnPick: true,
            pick: { notebook in
                let notebookID = notebook.id
                let goalID = goal.id
                if linked.contains(notebookID) {
                    Task { await vm.takeContextNotebookOut(notebookID, of: goalID) }
                } else {
                    Task { await vm.addContextNotebook(notebookID, to: goalID) }
                }
            },
            close: close
        )
    }
}

/// The Library inside a notebook's Sources column: its own list, the same
/// kind tabs, rows, menus and attention rows as the Library pane
/// (`StudioSidebar`), under the column's field, which does the searching
/// (`sourcesListHidesIdleSearch`). The window works in the notebook, so each
/// row carries the notebook's mark: a check on what it holds, a + under the
/// pointer on the rest, and rows drag into the chat or a canvas. Done (or
/// Escape in the field) gives the column back to the notebook's sources; an
/// empty notebook has nothing to go back to and draws no Done.
private struct NotebookLibraryBrowser: View {
    /// Back to the notebook's sources; nil while the notebook has none.
    let done: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let done {
                HStack(spacing: 8) {
                    Text("Your library")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                    Spacer(minLength: 0)
                    Button("Done", action: done)
                        .buttonStyle(.hoverWash(tint: .accentColor))
                        .help("Show this notebook's sources")
                        .accessibilityIdentifier("notebook.sources.libraryDone")
                }
                .padding(.horizontal, 6)
            }
            NavigationStack {
                StudioSidebar()
                    .equatable()
            }
            // The kind tabs draw in flow, as in the docked Library.
            .environment(\.studioTitlebarBandHeight, nil)
            // One line a source and the kinds as words, as NotebookLM's
            // column reads.
            .environment(\.sourcesListLayout, .compact)
            .environment(\.sourcesListHidesIdleSearch, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your library")
        .accessibilityIdentifier("notebook.sources.library")
    }
}

/// "Add sources" picker for a Notebook's pool.
///
/// The pool's own search field searches *inward*, over what the Notebook already has. This
/// searches outward, over the rest of the library, and never shows a source already in the
/// pool — with a hundred sources attached, a picker that listed them back would be mostly
/// noise. With no query it recommends: nearest neighbours to what the Notebook is about.
private struct NotebookAddSourcesPicker: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let onDismiss: () -> Void

    @PreferenceStorage(Prefs.Studio.metadataVisibility, default: MetadataVisibilitySettings()) private var metadataVisibility
    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var isSearching = false
    /// Rows added in this session. The candidate list is only refetched when the query
    /// changes, so without this an added source would sit there re-offering itself.
    @State private var addedIDs: Set<String> = []

    private var isRecommending: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            content
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        // Debounced: every keystroke otherwise costs an embed call plus a full ranking
        // pass. `task(id:)` cancels the in-flight search when the query moves on.
        .task(id: query) {
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(isRecommending ? "Suggested to add" : "Search results")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your library for sources to add", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
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

    @ViewBuilder
    private var content: some View {
        let pending = results.filter { !addedIDs.contains($0.article.id) }
        if pending.isEmpty {
            Text(emptyMessage)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(pending, id: \.article.id) { result in
                        candidateRow(result.article)
                    }
                }
                // macOS overlay scroll indicators do not reserve layout width. Keep the
                // trailing add controls clear of the thumb while it is visible.
                .padding(.trailing, 12)
            }
            // The pool's list below is a greedy ScrollView with no minimum, so without
            // a floor here the enclosing VStack sizes the suggestions down to a single
            // clipped row whenever the column is short.
            .frame(minHeight: 300, maxHeight: 460)
        }
    }

    private var emptyMessage: String {
        if isSearching { return "Searching…" }
        if !isRecommending { return "No sources match that aren't already in this notebook." }
        if goal.items.isEmpty { return "Add a source or two first, then suggestions will appear here." }
        return "Nothing left to suggest — the closest sources in your library are already in this notebook."
    }

    private func candidateRow(_ article: StudioArticle) -> some View {
        HStack(spacing: 6) {
            ArticleRow(article: article, metadataVisibility: metadataVisibility)
            Spacer(minLength: 0)
            Button {
                addedIDs.insert(article.id)
                Task { await vm.addSourcesToNotebookContext([article.id], notebookID: goal.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.hoverWash)
            .help("Add to this notebook")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct NotebookPoolBookGroupLabel: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let groupName: String
    let sources: [StudioArticle]
    /// Whether the notebook's chats read the book's chapters, in the notebook
    /// workspace; nil draws no box: the Notebook page, which keeps the hover
    /// ×, or a book still waiting as a suggestion.
    var chatState: NotebookTickState? = nil
    var onToggleChat: () -> Void = {}
    /// Whether the book's chapters show under it, in the notebook column,
    /// which draws the book as one of its rows with a chevron; nil for the
    /// Notebook page's disclosure label.
    var isExpanded: Binding<Bool>? = nil

    @State private var isHovering = false

    /// A read-only team's or an archived notebook loses nothing from here.
    private var canRemove: Bool { vm.importableNotebook(goal.id) != nil }

    var body: some View {
        if let isExpanded {
            notebookRow(isExpanded: isExpanded)
        } else {
            pageLabel
        }
    }

    /// The book as the notebook column's other rows: its glyph, giving its
    /// place to the ⋯ under the pointer, its name on one line, the chevron
    /// that shows its chapters, and the box over all of them.
    private func notebookRow(isExpanded: Binding<Bool>) -> some View {
        let name = vm.bookDisplayName(groupName)
        return HStack(spacing: 8) {
            NotebookBookCoverThumbnail(
                groupName: groupName,
                sources: sources,
                size: CGSize(width: 24, height: 30)
            )
            .frame(width: 30)
            .accessibilityHidden(true)
            Text(name)
                .zoomedSystemFont(size: 13)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(name), \(BookChapterTitle.countLabel(for: sources))")
            Spacer(minLength: 0)
            // A ⋯ rather than a one-click × beside the box, which a
            // click meant for the box could hit. Built only under the
            // pointer, as a source row's is (`NotebookPoolSourceRow`); the
            // right-click has the same item.
            if isHovering {
                bookMenu
            } else {
                RowMoreActionsLabel()
                    .hidden()
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
            } label: {
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help(isExpanded.wrappedValue ? "Hide chapters" : "Show \(BookChapterTitle.countLabel(for: sources))")
            .accessibilityLabel(isExpanded.wrappedValue ? "Hide chapters of \(name)" : "Show chapters of \(name)")
            if let chatState {
                NotebookChatToggle(
                    state: chatState,
                    subject: name,
                    action: onToggleChat
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onDrag(dragProvider)
        .contextMenu { removeMenuItem }
    }

    private var bookMenu: some View {
        Menu {
            removeMenuItem
        } label: {
            RowMoreActionsLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .help("Book actions")
    }

    private var removeMenuItem: some View {
        Button("Remove Book from Notebook", role: .destructive) {
            Task { await vm.removeSourcesFromNotebookContext(sources.map(\.id), notebookID: goal.id) }
        }
        .disabled(!canRemove)
    }

    private func dragProvider() -> NSItemProvider {
        let sourceIDs = sources.map(\.id)
        StudioDragVisibility.shared.begin(articleIDs: sourceIDs, groupName: groupName)
        return groupDragProvider(
            for: StudioGroupTransfer(groupName: groupName, sourceIDs: sourceIDs)
        )
    }

    private var pageLabel: some View {
        HStack(spacing: 10) {
            NotebookBookCoverThumbnail(
                groupName: groupName,
                sources: sources,
                size: CGSize(width: 32, height: 40)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.bookDisplayName(groupName))
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(1)
                Text(BookChapterTitle.countLabel(for: sources))
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Built only under the pointer, the hidden glyph holding its
            // place; the right-click removes the book too.
            if isHovering {
                removeButton
            } else {
                RowRemoveGlyph()
                    .hidden()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onDrag(dragProvider)
        .contextMenu {
            Button("Remove from Notebook", role: .destructive) {
                Task { await vm.removeSourcesFromNotebookContext(sources.map(\.id), notebookID: goal.id) }
            }
            .disabled(!canRemove)
        }
    }

    /// Removes the whole book — every chapter in the group — so it says so, since the row
    /// stands in for more sources than the one line suggests.
    private var removeButton: some View {
        Button {
            Task { await vm.removeSourcesFromNotebookContext(sources.map(\.id), notebookID: goal.id) }
        } label: {
            RowRemoveGlyph()
        }
        .buttonStyle(.hoverWash)
        .disabled(!canRemove)
        .help("Remove book and its \(BookChapterTitle.countLabel(for: sources)) from the notebook")
    }
}

struct NotebookPoolSourceRow: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    let goal: LearningGoalRecord
    let metadataVisibility: MetadataVisibilitySettings
    var hidesBookContext = false
    var showsChapterNumber = false
    let scheduleDays: [Date]
    /// Whether the notebook's chats read this source, in the notebook
    /// workspace. Nil draws no box: the Notebook page, or a suggestion not yet
    /// in the notebook.
    var isInChat: Bool? = nil
    var onToggleChat: () -> Void = {}
    /// Where a click opens the source — a pane of the notebook's window, in the
    /// row's own window. Nil opens it the Notebook page's way. Set, the row's
    /// hover control is a ⋯ menu rather than a one-click ×, which sat beside
    /// the box and invited a mis-click.
    var onOpen: (() -> Void)? = nil
    /// False for a context notebook's source, shown in its group: the row
    /// opens it and ticks it, and nothing removes, schedules or reviews it
    /// as the notebook's own.
    var isOwnSource = true
    /// True under the notebook's "Marked paywalled" header, which already
    /// says why the source can't be read: the row draws no warning of its own.
    var isOnPaywallShelf = false

    @State private var isHovering = false

    private var isNotebookRow: Bool { onOpen != nil }

    /// Whether this is a preprint the library now holds the journal version of. `.contextMenu`
    /// builds its items while the row's body runs, so this is the kept index's set lookup, never
    /// a walk of the library (that walk, once per row, beachballed opening a notebook).
    private var hasPublishedVersion: Bool {
        article.sourceType == .paper && vm.hasPublishedVersion(ofPreprint: article.id)
    }

    @ViewBuilder
    private var usePublishedVersionItem: some View {
        if isOwnSource, canRemove, hasPublishedVersion {
            Button("Use Published Version") {
                Task { await vm.switchNotebookToPublishedVersion(ofPreprint: article.id, notebookID: goal.id) }
            }
        }
    }

    /// A read-only team's or an archived notebook loses nothing from here.
    private var canRemove: Bool { vm.importableNotebook(goal.id) != nil }

    var body: some View {
        Group {
            if isNotebookRow {
                notebookRowContent
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ArticleRow(
                        article: article,
                        metadataVisibility: metadataVisibility,
                        hidesBookContext: hidesBookContext,
                        showsThumbnail: !showsChapterNumber,
                        showsChapterNumber: showsChapterNumber,
                        dragProvider: { articleDragProvider(for: article) }
                    )
                    Spacer(minLength: 0)
                    // Built only under the pointer, the hidden glyph holding
                    // its place, as the notebook row's ⋯ is; the right-click
                    // removes it too.
                    Group {
                        if isHovering {
                            removeButton
                        } else {
                            RowRemoveGlyph()
                                .hidden()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 6)
        // The wash has to cover the whole row — the badge and the more-actions menu
        // are part of what the pointer is over — so this one wins and `ArticleRow`
        // stands down. Same neutral grey as every other hover surface in the app.
        .ownsRowHoverWash()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button("Open", action: open)
            retryMenuItem
            OtherWindowSourceMenuItem(article)
            if isOwnSource {
                Menu("Schedule for…") {
                    ForEach(scheduleDays, id: \.self) { day in
                        Button(dayScheduleLabel(day)) {
                            Task {
                                await vm.addSourcesToNotebookSchedule(goalID: goal.id, sourceIDs: [article.id], plannedFor: day)
                            }
                        }
                    }
                }
                Button("Start review") {
                    vm.startCompanionReview(goalID: goal.id, sourceIDs: [article.id], topic: goal.topic ?? goal.title)
                }
                usePublishedVersionItem
                Divider()
                Button("Remove from Notebook", role: .destructive) {
                    Task { await vm.removeSourceFromNotebookContext(article.id, notebookID: goal.id) }
                }
                .disabled(!canRemove)
            }
        }
    }

    /// The notebook's row, as Gemini Notebook draws one: the source's glyph,
    /// its title on one line, the box. Under the pointer the glyph gives its
    /// place to the row's ⋯; a spinner or a warning takes it while the source
    /// loads or needs a look, its words in the help.
    private var notebookRowContent: some View {
        let title = vm.sourceRowTitle(for: article)
        let chapter: (number: String?, text: String) = showsChapterNumber
            ? BookChapterTitle.split(title)
            : (nil, title)
        return HStack(spacing: 8) {
            leadingGlyph(chapterNumber: chapter.number)
            VStack(alignment: .leading, spacing: 1) {
                Text(chapter.text)
                    .zoomedSystemFont(size: showsChapterNumber ? 12 : 13)
                    // A filmed title is read, not hovered: it gets a second line
                    // (screen record mode).
                    .lineLimit(vm.isScreenRecordModeActive ? 2 : 1)
                    .truncationMode(.tail)
                    .help(title)
                // The warning's words, under the title where they can be read,
                // not only in the glyph's help.
                if let attentionLine {
                    Text(attentionLine)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(attentionLine)
                }
            }
            Spacer(minLength: 0)
            if canRetryFailedSource {
                Button("Retry", action: retryFailedSource)
                    .buttonStyle(.hoverWash)
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(Color.accentColor)
                    .help("Try this source again")
                    .accessibilityLabel("Retry \(article.title)")
            }
            // The ⋯ is built only under the pointer, the hidden label
            // holding its width. A menu at opacity 0 is still a live
            // control: while an assistive app reads the screen, SwiftUI
            // walks every control in the window for each control an
            // update builds, so a hidden menu per row doubled what
            // opening a notebook cost. The right-click has
            // the same items.
            if isHovering {
                moreMenu
            } else {
                RowMoreActionsLabel()
                    .hidden()
            }
            if let isInChat {
                if vm.isScreenRecordModeActive, isInChat, !isHovering {
                    // A column of bright ticks is the default state, not a story:
                    // a filmed row draws its box under the pointer, or when the
                    // learner left the source out (screen record mode).
                    Color.clear.frame(width: 18, height: 18)
                } else {
                    NotebookChatToggle(
                        state: isInChat ? .checked : .unchecked,
                        subject: article.title,
                        action: onToggleChat
                    )
                }
            }
        }
        .padding(.vertical, 3)
        .modifier(SourceRowDragModifier(
            itemProvider: { articleDragProvider(for: article) },
            preview: {
                SourceDragPreview(
                    title: title,
                    subtitle: nil,
                    sourceType: article.sourceType,
                    isMissing: article.state == .error
                )
            }
        ))
        .siriSourceAnnotation(article.id)
    }

    /// Why the source needs a look, said on its glyph: the paper's attention
    /// reason the library row shows, or a fetch that failed.
    private var attentionNote: String? {
        if isOnPaywallShelf { return nil }
        if vm.paperProcessingStepLabel(for: article) == nil,
           let reason = article.paperAttentionReason(hasUsablePDF: vm.displayHasUsablePDF(article)) {
            return reason.rawValue
        }
        guard article.state == .error else { return nil }
        // A stored status flag is a code word, not a sentence: a paywalled
        // suggestion said "paywall" under its title.
        switch article.statusFlag {
        case .paywall: return "Paywalled"
        case .confirmPodcast: return "Podcast match to confirm"
        case .needsTranscript: return "Needs a transcript"
        case nil: break
        }
        let message = article.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Couldn\u{2019}t load this source" : message
    }

    /// `attentionNote` in the words a row has room for: a cleanup failure's own
    /// error rather than the sentence that explains the step, a paper's stored
    /// ingestion failure without its stage prefix. Nothing while the source is
    /// still being worked on.
    private var attentionLine: String? {
        guard vm.notebookRowActivityLabel(for: article) == nil,
              attentionNote != nil else { return nil }
        if article.isPaperContentCleanupFailure {
            return article.paperContentCleanupFailureDetail.map { "Cleanup failed: \($0)" }
                ?? "Cleanup failed"
        }
        return article.paperIngestionFailureDetail ?? attentionNote
    }

    /// Whether the row's warning is one a second try can clear: a paper whose
    /// cleanup or ingestion stopped and whose fix is just to run it again. A
    /// failure that needs the learner (a PDF to attach, a key to add) says so
    /// in its own words instead.
    private var canRetryFailedSource: Bool {
        // The cheap tests first: this runs in every row's body, and only a
        // failed paper pays for the rest.
        guard article.sourceType == .paper,
              article.state == .error,
              isOwnSource,
              vm.notebookRowActivityLabel(for: article) == nil,
              canRemove else { return false }
        let action = article.paperIngestionRecoveryAction(hasUsablePDF: vm.displayHasUsablePDF(article))
        if article.isPaperContentCleanupFailure {
            return action == nil || action == .retry
        }
        return action == .retry
    }

    /// The same retries the Library row's button runs, so the warning goes
    /// away from here too: the row turns back to a spinner while it works.
    private func retryFailedSource() {
        if article.isPaperContentCleanupFailure {
            vm.fixPaperContentCleanup(for: article.id)
        } else {
            Task { await vm.extractPaperMetadataWithAI(id: article.id) }
        }
    }

    @ViewBuilder
    private var retryMenuItem: some View {
        if canRetryFailedSource {
            Button("Retry", action: retryFailedSource)
        }
    }

    /// The source's thumbnail (its cover, first page or artwork, else its
    /// type's icon), a chapter's number instead for a book's chapters. A
    /// spinner while the source loads, or an orange warning when it needs a
    /// look, sits on the thumbnail's corner, its words in the help.
    @ViewBuilder
    private func leadingGlyph(chapterNumber: String?) -> some View {
        if showsChapterNumber {
            // Reserved even when a chapter has no number, so unnumbered
            // front matter still lines up with the numbered chapters.
            Text(chapterNumber ?? "")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.disabled)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            SourceThumbnail(source: article, size: 30)
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    if let activity = vm.notebookRowActivityLabel(for: article) {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(3)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 4, y: 4)
                            .help(activity)
                            .accessibilityLabel(activity)
                    } else if let attentionNote {
                        Image(systemName: "exclamationmark.circle.fill")
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.orange)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 4, y: 4)
                            .help(attentionNote)
                            .accessibilityLabel(attentionNote)
                    }
                }
        }
    }

    private func open() {
        if let onOpen {
            onOpen()
        } else {
            Task { await vm.revealSourceInReader(article.id) }
        }
    }

    /// The notebook row's actions, on hover: Open, Open in Other Window, and
    /// Remove from Notebook for one of the notebook's own sources.
    private var moreMenu: some View {
        Menu {
            Button("Open", action: open)
            retryMenuItem
            OtherWindowSourceMenuItem(article)
            usePublishedVersionItem
            if isOwnSource {
                Divider()
                Button("Remove from Notebook", role: .destructive) {
                    Task { await vm.removeSourceFromNotebookContext(article.id, notebookID: goal.id) }
                }
                .disabled(!canRemove)
            }
        } label: {
            RowMoreActionsLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .help("Source actions")
        .accessibilityLabel("Actions for \(article.title)")
    }

    /// Removal is the only per-row action the pool offers, so it hangs directly off the row
    /// as an "x" rather than hiding behind a one-item overflow menu.
    private var removeButton: some View {
        Button {
            Task { await vm.removeSourceFromNotebookContext(article.id, notebookID: goal.id) }
        } label: {
            RowRemoveGlyph()
        }
        .buttonStyle(.hoverWash)
        .disabled(!canRemove)
        .help("Remove from Notebook")
    }

    private func dayScheduleLabel(_ day: Date) -> String {
        Self.weekdayMonthDayFormatter.string(from: day)
    }

    /// Held rather than built per row: DateFormatter construction is expensive
    /// enough to show up in a list this size.
    private static let weekdayMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()
}

/// The × a pool row shows under the pointer, and, hidden, what holds its
/// place while the button is not built: a button at opacity 0 is still a
/// live control, and while an assistive app reads the screen SwiftUI walks
/// every control in the window for each one an update builds.
private struct RowRemoveGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
