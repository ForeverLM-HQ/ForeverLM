import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
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

enum NotebookSourceDropHandler {
    /// A drop on a Notebook: sources join its pool, and a course group links
    /// the course so future lectures follow.
    @MainActor
    static func handle(providers: [NSItemProvider], vm: StudioViewModel, notebookID: String? = nil) -> Bool {
        resolve(
            providers: providers,
            vm: vm,
            linkCourse: { courseID, sourceIDs in
                await vm.linkCourseToNotebookContext(courseID: courseID, sourceIDs: sourceIDs, notebookID: notebookID)
            },
            add: { sourceIDs in
                await vm.addSourcesToNotebookContext(sourceIDs, notebookID: notebookID)
            }
        )
    }

    /// A drop on a Goal's row: the same payloads, put on the Goal's pool. A
    /// course group is its sources today and nothing more — a Goal is
    /// timebound, so it does not subscribe to lectures that are not out yet.
    @MainActor
    static func handle(providers: [NSItemProvider], vm: StudioViewModel, goalID: String) -> Bool {
        resolve(
            providers: providers,
            vm: vm,
            linkCourse: { _, sourceIDs in
                await vm.addSourcesToGoal(goalID: goalID, sourceIDs: sourceIDs)
            },
            add: { sourceIDs in
                await vm.addSourcesToGoal(goalID: goalID, sourceIDs: sourceIDs)
            }
        )
    }

    /// A drop on an Idea's row: the same payloads, linked to the Idea as the
    /// research it draws on. A course group is its sources today, like a Goal.
    @MainActor
    static func handle(providers: [NSItemProvider], vm: StudioViewModel, ideaID: String) -> Bool {
        resolve(
            providers: providers,
            vm: vm,
            linkCourse: { _, sourceIDs in
                await vm.linkIdea(ideaID: ideaID, kind: .source, targetIDs: sourceIDs)
            },
            add: { sourceIDs in
                await vm.linkIdea(ideaID: ideaID, kind: .source, targetIDs: sourceIDs)
            }
        )
    }

    /// Reads every source payload an in-app drag can carry — a group, a
    /// Schedule item, a multi-selection of rows, a bare source id — and hands
    /// the resolved ids to `add`, or a course group to `linkCourse`. Returns
    /// whether any provider was one of ours; the loads finish asynchronously.
    @MainActor
    private static func resolve(
        providers: [NSItemProvider],
        vm: StudioViewModel,
        linkCourse: @escaping @MainActor (_ courseID: String, _ sourceIDs: [String]) async -> Void,
        add: @escaping @MainActor (_ sourceIDs: [String]) async -> Void
    ) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.studioGroup.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioGroup.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioGroupTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        let sourceIDs = transfer.sourceIDs.flatMap { $0.isEmpty ? nil : $0 }
                            ?? vm.sourceIDsForGroupInOrder(transfer.groupName)
                        if vm.allCourseGroupNames.contains(transfer.groupName) {
                            await linkCourse(transfer.groupName, sourceIDs)
                        } else {
                            await add(sourceIDs)
                        }
                    }
                }
                handled = true
                continue
            }

            // A source row registers both representations on one provider. The
            // article transfer is the one that can carry a multi-selection, so
            // it is read first; the bare id is only for providers that have
            // nothing else.
            if provider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        // The payload is the snapshot of what the learner picked
                        // up; the live selection may have moved on by the drop.
                        await add(transfer.draggedSourceIDs)
                    }
                }
                handled = true
                continue
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.studioSourceID.identifier) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.studioSourceID.identifier) { data, _ in
                guard let data,
                      let sourceID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sourceID.isEmpty else { return }
                Task { @MainActor in
                    await add([sourceID])
                }
            }
            handled = true
        }
        return handled
    }
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

// MARK: - PDFs dropped as papers

/// Reading the PDFs a drop carries, for the two places a PDF dropped from
/// Finder or a browser becomes a paper: the Sources list's Papers tab and a
/// notebook's Sources column. Each hands what it reads to the library's one
/// PDF import (`StudioViewModel.importPDF(from:)`); this only gets the files.
enum PaperFileDrop {
    /// What a PDF drop carries: a file, or a PDF's bytes.
    static let types: [UTType] = [.fileURL, .pdf]

    /// The file URL a provider's `.fileURL` item loaded as. Finder hands over
    /// its bookmark data, other apps an `NSURL`, a path or a URL string.
    static func fileURL(fromLoadedItem item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let value = item as? String {
            let parsed = URL(string: value)
            return parsed?.isFileURL == true ? parsed : URL(fileURLWithPath: value)
        }
        return item as? URL
    }

    /// Whether `url` names a PDF on disk, by its extension, as the Papers
    /// tab has always judged a dropped file.
    static func isPDFFile(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.isFileURL && url.pathExtension.lowercased() == "pdf"
    }

    /// Loads each PDF the drop carries and hands it to `deliver` on the main
    /// actor: a file as it is, a PDF's bytes staged into a temporary file
    /// first (`PaperDropStager`, whose file `deliver` cleans up after the
    /// import). A file that is no PDF, or a load that fails, goes to `fail`
    /// with the name the provider suggested and why. True when the drop
    /// carried anything to try.
    static func load(
        _ providers: [NSItemProvider],
        deliver: @escaping @MainActor (URL, String, PaperDropStager.StagedFile?) -> Void,
        fail: @escaping @MainActor (String?, String) -> Void
    ) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    let suggestedName = provider.suggestedName
                    if let error {
                        let message = error.localizedDescription
                        Task { @MainActor in fail(suggestedName, message) }
                        return
                    }
                    let url = fileURL(fromLoadedItem: item)
                    guard let url, isPDFFile(url) else {
                        Task { @MainActor in fail(suggestedName, "Finder did not provide a readable PDF file URL.") }
                        return
                    }
                    Task { @MainActor in deliver(url, url.lastPathComponent, nil) }
                }
                continue
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) else { continue }
            handled = true
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                let suggestedName = provider.suggestedName
                if let error {
                    let message = error.localizedDescription
                    Task { @MainActor in fail(suggestedName, message) }
                    return
                }
                guard let data, !data.isEmpty else {
                    Task { @MainActor in fail(suggestedName, "The dropped PDF contained no readable data.") }
                    return
                }
                Task { @MainActor in
                    do {
                        let staged = try await PaperDropStager.stage(data: data, suggestedName: suggestedName)
                        deliver(staged.url, staged.displayName, staged)
                    } catch {
                        fail(suggestedName, error.localizedDescription)
                    }
                }
            }
        }
        return handled
    }
}

/// What a drop on a notebook's Sources column is.
enum NotebookSourcesDrop: Equatable {
    /// The app's own rows — sources, a book, a course — which join the
    /// notebook as they are.
    case sources
    /// PDFs from Finder or a browser, imported as papers and then filed in
    /// the notebook.
    case pdfs
    case none

    /// A drag of the app's own rows is a source drop even when it carries a
    /// PDF file too: a paper's row offers its file to Finder, and must not be
    /// imported a second time. Only files alone import as papers, and only
    /// where the notebook takes new sources.
    static func kind(carriesSources: Bool, carriesFiles: Bool, acceptsPDFs: Bool) -> NotebookSourcesDrop {
        if carriesSources { return .sources }
        if carriesFiles, acceptsPDFs { return .pdfs }
        return .none
    }
}

/// The drop on a Notebook's pool: the app's rows always, and in a notebook's
/// Sources column PDFs from Finder or a browser too, each lighting its own
/// overlay.
private struct NotebookPoolDropDelegate: DropDelegate {
    let acceptsPDFs: Bool
    /// Whether the in-app drag under way could add anything here; drawn, but
    /// never what decides a drop (`NotebookSourcePoolView`'s note).
    let canAcceptSourceDrag: Bool
    @Binding var isTargeted: Bool
    @Binding var isPDFTargeted: Bool
    let dropSources: ([NSItemProvider]) -> Bool
    let dropPDFs: ([NSItemProvider]) -> Bool

    private func kind(_ info: DropInfo) -> NotebookSourcesDrop {
        NotebookSourcesDrop.kind(
            carriesSources: info.hasItemsConforming(to: mcpSourceContextDropTypes),
            carriesFiles: info.hasItemsConforming(to: PaperFileDrop.types),
            acceptsPDFs: acceptsPDFs
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        kind(info) != .none
    }

    func dropEntered(info: DropInfo) {
        switch kind(info) {
        case .sources: isTargeted = canAcceptSourceDrag
        case .pdfs: isPDFTargeted = true
        case .none: break
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        isPDFTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            isTargeted = false
            isPDFTargeted = false
        }
        switch kind(info) {
        case .sources: return dropSources(info.itemProviders(for: mcpSourceContextDropTypes))
        case .pdfs: return dropPDFs(info.itemProviders(for: PaperFileDrop.types))
        case .none: return false
        }
    }
}

// MARK: - Notebook source pool (Sources tab)

/// What the notebook workspace hands its Sources column: where a row opens,
/// and how the Add sources sheet opens.
struct NotebookSourcePoolColumnActions {
    /// Opens a source in the notebook's document slot, in this window.
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
/// its title on one line and a box for whether the notebook's chats read it;
/// "N of M in chat" while not every source is ticked, and Select all sources
/// under the pointer while every one is;
/// under the pointer a row shows its ⋯ with Open, Open in
/// Other Window and Remove from Notebook; a row click opens the Reader in the
/// document slot, the notebook's ⋯ opens the Add sources sheet, and an empty
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

    @SyncedStorage("metadataVisibility") private var metadataVisibility = MetadataVisibilitySettings()
    @State private var sourceSearchText = ""
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
                // No "Sources" heading over the field since 2026-10-06: the
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

    /// Gemini Notebook's "Select all sources" and the box that ticks or
    /// clears them all; "8 of 12 in chat" in its place while not every
    /// source is ticked. The count is the notebook's whole chat pool
    /// (`notebookChatTally`), as the chat and the guide count it.
    ///
    /// While every source is ticked, which is how a notebook starts, the row
    /// is drawn only while the pointer is over the column (2026-10-06,
    /// the product owner: "cleaner and fewer buttons and bells and whistles"), its
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
                    Text(state == .checked ? "Select all sources" : "\(tally.inChat) of \(tally.total) in chat")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.disabled)
                    Spacer(minLength: 0)
                    NotebookTickBox(
                        state: state,
                        label: "Select all for chat",
                        help: state == .checked ? "Leave every source out of chat" : "Include every source in chat",
                        action: { vm.setAllNotebookSourcesInChat(state != .checked, notebookID: goal.id) }
                    )
                    .accessibilityIdentifier("notebook.sources.selectAll")
                } else {
                    // The box built only under the pointer, as a row's ⋯
                    // is; a hidden face keeps the row's height.
                    Text("Select all sources")
                        .zoomedSystemFont(size: 12)
                        .hidden()
                    Spacer(minLength: 0)
                    Color.clear
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 6)
        }
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

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var poolContent: some View {
        // Approved sources are shown grouped by source type — Papers, Articles,
        // Podcasts, Books… in the canonical sidebar order — and sorted alphabetically
        // by title within each type. Suggestions (which need approve/reject controls)
        // and paywalled sources keep their own sections.
        let approvedItems = plan.toRead + plan.reading + plan.understood
        let typeSections = notebookTypeSections(
            from: filteredArticles(for: approvedItems, includesPaywalled: false)
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if searchesLibrary, !typeSections.isEmpty {
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
                        ForEach(typeSections.flatMap(\.groups)) { group in
                            poolGroupView(group, goalItems: approvedItems, showApproval: false)
                        }
                    }
                } else {
                    ForEach(typeSections) { section in
                        typeSection(section, goalItems: approvedItems)
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
                isInChat: showApproval || column == nil
                    ? nil
                    : vm.isNotebookSourceInChat(article.id, notebookID: goal.id),
                onToggleChat: { toggleChat([article.id]) },
                onOpen: column.map { column in { column.openSource(article) } }
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
                NotebookTickBox(
                    state: state,
                    label: "Include \(title) in chat",
                    help: state == .checked ? "Leave \(title) out of chat" : "Include \(title) in chat",
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

/// Add a Notebook to Context: the notebooks of the library this one does not
/// link to yet, each linking it and putting it into this notebook's chats in
/// one step (`addContextNotebook`). In the notebook's ⋯ menu
/// and the inspector's "Uses context from".
struct AddContextNotebookMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord

    private var candidates: [LearningGoalRecord] {
        let linked = Set(goal.relatedNotebookIDs ?? [])
        return vm.notebooks.filter { $0.id != goal.id && !linked.contains($0.id) }
    }

    var body: some View {
        Menu {
            ForEach(candidates) { notebook in
                Button(NotebookTitle(notebook.title).text) {
                    let notebookID = notebook.id
                    let goalID = goal.id
                    Task { await vm.addContextNotebook(notebookID, to: goalID) }
                }
            }
        } label: {
            Label("Add a Notebook to Context", systemImage: "books.vertical")
        }
        .disabled(candidates.isEmpty || vm.importableNotebook(goal.id) == nil)
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
            // column reads (2026-10-12).
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

    @SyncedStorage("metadataVisibility") private var metadataVisibility = MetadataVisibilitySettings()
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
                NotebookTickBox(
                    state: chatState,
                    label: "Include \(name) in chat",
                    help: chatState == .checked ? "Leave out of chat" : "Include in chat",
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
    /// Where a click opens the source — the notebook's document slot, in the
    /// row's own window. Nil opens it the Notebook page's way. Set, the row's
    /// hover control is a ⋯ menu rather than a one-click ×, which sat beside
    /// the box and invited a mis-click.
    var onOpen: (() -> Void)? = nil
    /// False for a context notebook's source, shown in its group: the row
    /// opens it and ticks it, and nothing removes, schedules or reviews it
    /// as the notebook's own.
    var isOwnSource = true

    @State private var isHovering = false

    private var isNotebookRow: Bool { onOpen != nil }

    /// Whether this is a preprint the library now holds the journal version of. Read where the
    /// menus are built (a right-click, a hover), never in the row's body.
    private var hasPublishedVersion: Bool {
        article.sourceType == .paper && vm.publishedVersion(ofPreprint: article.id) != nil
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
            Text(chapter.text)
                .zoomedSystemFont(size: showsChapterNumber ? 12 : 13)
                // A filmed title is read, not hovered: it gets a second line
                // (screen record mode).
                .lineLimit(vm.isScreenRecordModeActive ? 2 : 1)
                .truncationMode(.tail)
                .help(title)
            Spacer(minLength: 0)
            // The ⋯ is built only under the pointer, the hidden label
            // holding its width. A menu at opacity 0 is still a live
            // control: while an assistive app reads the screen, SwiftUI
            // walks every control in the window for each control an
            // update builds, so a hidden menu per row doubled what
            // opening a notebook cost (2026-10-03). The right-click has
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
                    NotebookTickBox(
                        state: isInChat ? .checked : .unchecked,
                        label: "Include \(article.title) in chat",
                        help: isInChat ? "Leave out of chat" : "Include in chat",
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
        if vm.paperProcessingStepLabel(for: article) == nil,
           let reason = article.paperAttentionReason(hasUsablePDF: vm.displayHasUsablePDF(article)) {
            return reason.rawValue
        }
        guard article.state == .error else { return nil }
        let message = article.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Couldn\u{2019}t load this source" : message
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
/// every control in the window for each one an update builds (2026-10-03).
private struct RowRemoveGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Canonical pool ordering for source types, mirroring the sidebar tab order so the
/// Notebook pool reads the same way the library does.
private let notebookPoolTypeRank: [StudioSourceType: Int] = [
    .article: 0, .unclassified: 0, .manual: 0,
    .paper: 1,
    .book: 2,
    .course: 3,
    .meeting: 4,
    .podcast: 5,
    .video: 6,
    .xPost: 7,
]

/// The plural section header shown for each source type in the Notebook pool. Article,
/// manual, and still-unclassified web sources share the "Articles" bucket, mirroring
/// their shared rank above.
private func notebookTypeSectionTitle(for type: StudioSourceType) -> String {
    switch type {
    case .article, .unclassified, .manual: return "Articles"
    case .paper: return "Papers"
    case .book: return "Books"
    case .course: return "Courses"
    case .meeting: return "Meetings"
    case .podcast: return "Podcasts"
    case .video: return "Videos"
    case .xPost: return "Posts"
    }
}

/// One type-grouped section of the Notebook pool (e.g. all Papers), its groups already
/// sorted alphabetically. `rank` orders the sections themselves by `notebookPoolTypeRank`.
private struct NotebookTypeSection: Identifiable {
    let title: String
    let rank: Int
    let groups: [NotebookContextSourceGroup]
    var id: String { "\(rank)-\(title)" }
}

/// Groups a Notebook pool's sources into contiguous type runs — all papers together, then
/// books, and so on — with the stored (MCP-reorderable) study order preserved *within*
/// each type. Used for the flat Suggested and paywalled sections; the main approved list
/// groups these into per-type sections via `notebookTypeSections`.
func notebookContextGroups(from articles: [StudioArticle]) -> [NotebookContextSourceGroup] {
    let articles = articles
        .enumerated()
        .sorted { lhs, rhs in
            let lhsRank = notebookPoolTypeRank[lhs.element.sourceType] ?? Int.max
            let rhsRank = notebookPoolTypeRank[rhs.element.sourceType] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.offset < rhs.offset
        }
        .map(\.element)

    let bookSourcesByGroup = Dictionary(
        grouping: articles.filter { article in
            article.sourceType == .book
                && article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        },
        by: { $0.parentGroup ?? "" }
    )
    var emittedBookGroups = Set<String>()
    var groups: [NotebookContextSourceGroup] = []

    for article in articles {
        guard article.sourceType == .book,
              let groupName = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupName.isEmpty else {
            groups.append(.source(article))
            continue
        }
        guard emittedBookGroups.insert(groupName).inserted else { continue }
        groups.append(.book(groupName: groupName, sources: notebookSortedBookChapters(bookSourcesByGroup[groupName] ?? [article])))
    }

    return groups
}

private func notebookSortedBookChapters(_ sources: [StudioArticle]) -> [StudioArticle] {
    sources.sorted {
        if let lhs = $0.courseSortIndex, let rhs = $1.courseSortIndex, lhs != rhs {
            return lhs < rhs
        }
        if $0.courseSortIndex != nil { return true }
        if $1.courseSortIndex != nil { return false }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
}

/// A book's chapters arrive as the flattened EPUB table of contents, so structural part
/// dividers ("Part 3 Insider Deal: …") sit in the same flat list as real chapters
/// ("7) Why Bacteria are Simple"). Telling the two apart lets the chapter list show a
/// number gutter and render dividers as section breaks instead of look-alike rows.
enum BookChapterTitle {
    /// Splits the leading chapter number out of a normalized title.
    /// `"7) Why Bacteria are Simple"` → `("7", "Why Bacteria are Simple")`.
    static func split(_ title: String) -> (number: String?, text: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = trimmed.range(of: #"^\d+\)\s+"#, options: .regularExpression),
              let digits = trimmed.range(of: #"^\d+"#, options: .regularExpression) else {
            return (nil, trimmed)
        }
        return (String(trimmed[digits]), String(trimmed[prefix.upperBound...]))
    }

    /// True for TOC entries that name a structural division rather than a chapter.
    /// These contentless nodes are kept out of the chapter list and the chapter count.
    static func isPartDivider(_ article: StudioArticle) -> Bool {
        article.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(part|section|book)\s+(\d+|[ivxlc]+)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "6 chapters" counting only real chapters — part dividers aren't chapters.
    static func countLabel(for sources: [StudioArticle]) -> String {
        let chapters = sources.filter { !isPartDivider($0) }.count
        guard chapters > 0 else {
            return "\(sources.count) section\(sources.count == 1 ? "" : "s")"
        }
        return "\(chapters) chapter\(chapters == 1 ? "" : "s")"
    }
}

/// Indents an expanded book's chapters under their group header and hangs a hairline
/// rail down the left so the chapters read as belonging to the book above them.
private struct BookChapterStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 1) {
            content
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .padding(.leading, 8)
    }
}

private enum MCPSetupAssistant: String, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case grok
    case muse
    /// Any other client that adds a remote MCP server with OAuth. Its prompt
    /// names no product, so the assistant it is pasted into maps the steps
    /// onto its own setup.
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .muse: return "Meta Muse"
        case .other: return "Other assistant"
        }
    }

    /// How the setup prompt refers to the client it is pasted into.
    var promptClientName: String {
        switch self {
        case .other: return "assistant"
        default: return "\(displayName) client"
        }
    }

    /// Nil for the generic row, which draws an SF Symbol instead.
    var logoAssetName: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .codex: return "OpenAIIcon"
        case .gemini: return "GeminiIcon"
        case .grok: return "GrokIcon"
        case .muse: return "MetaIcon"
        case .other: return nil
        }
    }

    var usesTemplateLogo: Bool {
        self == .codex || self == .grok
    }

    /// The hosted gateway serves every web agent and any client ForeverLM
    /// has no row for: it answers OAuth discovery and registration, and its
    /// consent page names where the sign-in returns. Muse's callback was
    /// admitted there and verified live (ca5e21831).
    var usesPublicMCPURL: Bool {
        self == .gemini || self == .muse || self == .other
    }

    var copyLabel: String {
        "\(displayName) setup prompt"
    }

    /// One line saying where this assistant takes the connection.
    var setupHint: String {
        switch self {
        case .claude:
            return "Claude.ai: Customize → Connectors → Add custom connector. Not in the Claude Directory yet."
        case .codex:
            return "Paste the prompt into Codex, or add a custom connector on chatgpt.com."
        case .gemini:
            return "Settings & help → Connected Apps → Add a custom app. Works in Gemini Spark tasks only."
        case .grok:
            return "Paste the prompt into Grok Build, or add a custom connector on grok.com."
        case .muse:
            return "Paste the prompt into a Muse chat on muse.ai. Muse builds the connector and asks you to sign in."
        case .other:
            return "Any assistant or agent that adds a remote MCP server with OAuth, such as Cursor."
        }
    }

    var openURL: URL? {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/connectors")
        case .codex: return URL(string: "https://chatgpt.com/#settings/Connectors")
        case .gemini: return URL(string: "https://gemini.google.com")
        case .grok: return URL(string: "https://grok.com/connectors")
        case .muse: return URL(string: "https://muse.ai")
        case .other: return nil
        }
    }
}

/// The purple "Open Billing" label. `.borderedProminent` paints no hover, and a
/// `.hoverWash` grey sits behind a filled label, so the fill darkens itself.
private struct MCPOpenBillingLabel: View {
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text("Open Billing")
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(shape.fill(Color.purple))
            .overlay(shape.fill(Color.black.opacity(isHovering ? 0.18 : 0)))
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Prompt-first setup for connecting external AI clients to the hosted relay.
struct MCPSettingsDetailView: View {
    private static let publicMCPURL = "https://plugin.foreverlm.com/mcp"

    @State private var launcher = MCPServerLauncher.shared
    @State private var statusChecker = MCPStatusChecker.shared
    @State private var copied: String?
    @State private var hostedStartInProgress = false
    @State private var stopInProgress = false
    @SyncedStorage(AssistantIntegrationSettings.enabledKey) private var assistantIntegrationsEnabled = true
    @SyncedStorage(AssistantIntegrationSettings.statusLightVisibleKey) private var showsMCPStatusLight = true

    @Environment(ManagedAIAccountModel.self) private var account

    let showsPairingCode: Bool
    /// Opens Settings › Billing, where MCP is unlocked.
    let onOpenBilling: () -> Void

    // Keychain reads are securityd IPC round-trips; load them once off-main in
    // `.task` rather than on every render.
    @State private var storedTunnelURL: String?
    @State private var ownerPairingCode: String?

    init(showsPairingCode: Bool = false, onOpenBilling: @escaping () -> Void) {
        self.showsPairingCode = showsPairingCode
        self.onOpenBilling = onOpenBilling
    }

    private var hostedMCPURL: String? {
        launcher.mcpURL ?? storedTunnelURL.map { "\($0)/mcp" }
    }
    private var hostedTunnelIsReachable: Bool {
        guard statusChecker.status == .running,
              statusChecker.successfulURL != nil else {
            return false
        }
        return true
    }

    private func startHostedTunnelFromSettings(takingOver: Bool = false) {
        guard !hostedStartInProgress else { return }
        hostedStartInProgress = true
        Task {
            await MCPRuntimeCoordinator.startHostedTunnel(takingOver: takingOver)
            _ = await statusChecker.waitForHostedTunnel()
            await MainActor.run {
                hostedStartInProgress = false
            }
        }
    }

    private func stopMCPFromSettings() {
        guard !stopInProgress else { return }
        stopInProgress = true
        hostedStartInProgress = false
        assistantIntegrationsEnabled = false
        Task {
            await MCPRuntimeCoordinator.stopAll()
            await MainActor.run {
                stopInProgress = false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header
                VStack(spacing: 12) {
                    AssistantLogoCluster(logoSize: 24)
                    Text("External AI Assistants")
                        .font(.title.weight(.semibold))
                    Text("Connect Claude, ChatGPT, Gemini, Grok, Meta Muse, or any MCP assistant")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                if account.isMCPLocked {
                    // The connection is stopped until MCP is paid for; nothing
                    // else in the app is held back.
                    GroupBox {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                            Text(EarlyUserDealOffer.lockedTitle)
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Button(action: onOpenBilling) {
                                MCPOpenBillingLabel()
                            }
                            .buttonStyle(.hoverWash(in: RoundedRectangle(cornerRadius: 6, style: .continuous), inset: 0, opacity: 0))
                            .accessibilityIdentifier("settings.mcp.openBilling")
                        }
                        .padding(6)
                    }
                } else if assistantIntegrationsEnabled {
                    mcpConnectionPanel
                } else {
                    GroupBox {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(.secondary.opacity(0.5))
                                .frame(width: 10, height: 10)
                            Text("Disconnected")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Button("Connect") {
                                assistantIntegrationsEnabled = true
                                startHostedTunnelFromSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(stopInProgress)
                        }
                        .padding(6)
                    }
                }

                // The account button's dot, bottom left of the main window.
                // Its switch lives here, beside the connection it reports on.
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show the status light in the account button", isOn: $showsMCPStatusLight)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.mcp.showStatusLight")
                        Text("A dot by your name, bottom left, while assistants cannot reach your library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("MCP")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            let shouldLoadPairingCode = showsPairingCode
            let loaded = await Task.detached(priority: .utility) {
                (
                    KeychainService.load(.mcpTunnelURL),
                    shouldLoadPairingCode ? MCPOAuthProvider.ownerPairingCode : nil
                )
            }.value
            storedTunnelURL = loaded.0
            ownerPairingCode = loaded.1
        }
        .onAppear {
            guard assistantIntegrationsEnabled else { return }
            Task {
                _ = await statusChecker.checkHostedTunnel()
            }
        }
    }

    @ViewBuilder
    private var mcpConnectionPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isMCPReachable ? .green : .red.opacity(0.6))
                        .frame(width: 10, height: 10)
                    Text(serverStatusLabel)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isMCPReachable ? .primary : .secondary)
                    Spacer()
                    if launcher.isInProgress || hostedStartInProgress || stopInProgress {
                        ProgressView().controlSize(.small)
                    }

                    if launcher.state == .servedElsewhere && !hostedStartInProgress && !stopInProgress {
                        Button("Use This Mac") {
                            startHostedTunnelFromSettings(takingOver: true)
                        }
                        .buttonStyle(.bordered)
                        .help("Answer assistants from this Mac. The other ForeverLM steps aside until this one stops.")
                    }

                    if isMCPReachable {
                        Button("Disconnect") {
                            stopMCPFromSettings()
                        }
                        .buttonStyle(.bordered)
                        .disabled(stopInProgress)
                    } else if !launcher.isInProgress && !hostedStartInProgress && !stopInProgress {
                        Button("Connect") {
                            startHostedTunnelFromSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                }

                if launcher.state == .servedElsewhere {
                    Text("Another ForeverLM signed in to your Apple ID is answering assistants. This Mac takes over when it quits or sleeps.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .failed(let reason) = launcher.state {
                    Divider()
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsPairingCode, let ownerPairingCode, !ownerPairingCode.isEmpty {
                    Divider()
                    pairingCodeRow(ownerPairingCode)
                } else if isMCPReachable, let hostedMCPURL, !hostedMCPURL.isEmpty {
                    Divider()
                    assistantSetupPanel(personalMCPURL: hostedMCPURL)
                }
            }
            .padding(6)
        }
    }

    private func assistantSetupPanel(personalMCPURL: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            serverURLRow

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Connect an assistant")
                    .font(.headline)
                Text("Copy the prompt and paste it into the assistant. It sets up the connection and asks you to approve it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(MCPSetupAssistant.allCases.enumerated()), id: \.element) { index, assistant in
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    assistantRow(
                        assistant,
                        mcpURL: assistant.usesPublicMCPURL ? Self.publicMCPURL : personalMCPURL
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private var serverURLRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Server URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.publicMCPURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                copy(Self.publicMCPURL, label: "MCP URL")
            } label: {
                Label(
                    copied == "MCP URL" ? "Copied" : "Copy URL",
                    systemImage: copied == "MCP URL" ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private func assistantRow(
        _ assistant: MCPSetupAssistant,
        mcpURL: String
    ) -> some View {
        let isCopied = copied == assistant.copyLabel
        return HStack(alignment: .center, spacing: 12) {
            Group {
                if let logoAssetName = assistant.logoAssetName {
                    Image(logoAssetName)
                        .resizable()
                        .renderingMode(assistant.usesTemplateLogo ? .template : .original)
                        .scaledToFit()
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(assistant.displayName)
                    .font(.headline)
                Text(assistant.setupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let openURL = assistant.openURL {
                Link(destination: openURL) {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .help("Open \(assistant.displayName)")
            }

            Button {
                copy(
                    Self.setupPrompt(for: assistant, mcpURL: mcpURL),
                    label: assistant.copyLabel
                )
            } label: {
                Label(
                    isCopied ? "Copied" : "Copy prompt",
                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                )
                .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(isCopied ? .green : .purple)
            .help("Copy the \(assistant.displayName) setup prompt")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Short, client-specific prompts based on each assistant's current remote
    /// HTTP MCP flow, plus one generic prompt for clients without a row. The
    /// URL is necessary; OAuth credentials are deliberately omitted because
    /// every client registers itself at the gateway.
    private static func setupPrompt(
        for assistant: MCPSetupAssistant,
        mcpURL: String
    ) -> String {
        let clientSteps: String
        switch assistant {
        case .claude:
            clientSteps = """
            If this is Claude Code:
            1. Run `claude mcp get foreverlm`. If it is missing, run `claude mcp add --transport http --scope user foreverlm "\(mcpURL)"`.
            2. If the saved server uses a different URL, remove it and add it again with the command above.
            3. Have me open `/mcp` if OAuth does not begin automatically.

            If this is Claude.ai or a Claude mobile app:
            ForeverLM is not in the Claude Directory yet, so add it as a custom connector:
            1. On the web, open https://claude.ai/settings/connectors (Customize → Connectors) and choose Add custom connector.
            2. Name it ForeverLM, enter "\(Self.publicMCPURL)", and choose Continue.
            3. Under Authentication choose Always required; under OAuth client choose No client ID — register one automatically.
            4. Choose Add, open the ForeverLM entry, choose Connect, and complete Sign in with Apple. It then works in Claude Desktop and mobile too.
            5. Verify the connection with get_mcp_status.
            """
        case .codex:
            clientSteps = """
            1. Run `codex mcp list`.
            2. If `foreverlm` is missing, run `codex mcp add foreverlm --url "\(mcpURL)"`. If it exists with a different URL, remove it and add it again with that command.
            3. Run `codex mcp login foreverlm` and complete OAuth.
            4. If this task cannot load the new tools, tell me to restart Codex or open a new task.
            """
        case .gemini:
            clientSteps = """
            If this is Gemini on the web:
            1. Open Settings & help → Connected Apps.
            2. Under Custom apps for Spark, choose Add a custom app.
            3. Enter "\(mcpURL)", leave advanced OAuth credentials blank, and choose Next.
            4. Complete Sign in with Apple, then enable ForeverLM in a Spark task.
            5. Verify the connection by calling `get_mcp_status`.

            Google currently requires custom apps to be added on the web. They work in Gemini Spark, not regular Gemini chats. If Custom apps for Spark is missing, explain that Google has not enabled the feature for this account; do not claim the MCP server is unavailable.

            If this is Gemini CLI instead:
            1. Run `gemini mcp list`.
            2. If `foreverlm` is missing, run `gemini mcp add foreverlm "\(mcpURL)" --transport http --scope user`.
            3. If OAuth does not begin automatically, have me run `/mcp auth foreverlm`.
            4. Run `/mcp list` and confirm that `foreverlm` is connected.
            """
        case .grok:
            clientSteps = """
            If this is Grok Build or Grok CLI:
            1. Run `grok mcp list`.
            2. If `foreverlm` is missing, run `grok mcp add --transport http foreverlm "\(mcpURL)"`.
            3. Complete the automatic OAuth flow on first use.

            If this is Grok web and you cannot edit Plugins yourself, give me only the remaining clicks: open https://grok.com/connectors, choose New Connector → Custom, name it ForeverLM, and use the URL above.
            """
        case .muse:
            clientSteps = """
            1. Create a Custom Connector named ForeverLM for the MCP server above. It is a hosted, public HTTPS endpoint that speaks Streamable HTTP, so connect to it as an MCP server; do not wrap it in an API client or scrape it.
            2. Start its OAuth sign-in. ForeverLM accepts Muse's registration automatically, so do not ask me for credentials. Hand me the sign-in page and let me finish Sign in with Apple there.
            3. When Muse asks me to approve the connector's access, tell me in one line what I am approving.
            4. Save the connector as a reusable skill so later Muse tasks can use ForeverLM without setting it up again.
            """
        case .other:
            clientSteps = """
            Use your own way of adding a remote MCP server. Products call it a custom connector, app, integration, extension, plugin, or MCP server.
            1. If you run in a terminal and have an MCP command (such as `<cli> mcp add`), add a server named `foreverlm` with HTTP transport and the URL above.
            2. If you are configured by a JSON file (such as `mcp.json`), add a `foreverlm` entry with the URL above in that file's format for remote HTTP servers.
            3. If you run in a web or desktop app, find where it adds a custom MCP server, name it ForeverLM, enter the URL above, choose OAuth, and leave client ID and secret blank.
            4. Complete OAuth. The ForeverLM page names the app I will be sent back to and says when it does not recognise it; I continue there with Sign in with Apple.
            5. If you cannot reach remote MCP servers at all, say so plainly. Do not improvise a workaround.
            """
        }

        return """
        Connect this \(assistant.promptClientName) to my existing ForeverLM MCP server.

        Name: ForeverLM
        Transport: Streamable HTTP
        URL: \(mcpURL)
        Authentication: OAuth 2.1 with PKCE, discovery, and dynamic client registration

        \(clientSteps)

        Important:
        - This is an existing remote MCP server. Do not build a plugin or write a new MCP server.
        - Use OAuth discovery and dynamic client registration. Do not ask me for a client ID, client secret, or API key. If an authorization page explicitly requires a pairing code, have me use its ForeverLM link and enter the code directly there; never ask me to paste it into chat.
        - ForeverLM must stay open on my Mac. Have me approve the connection when ForeverLM or my browser asks.
        - After setup, verify that the ForeverLM tools are listed and call `get_mcp_status`. Do not claim success until verification passes.
        - If permissions or workspace policy block custom MCP servers, state the exact blocker and the shortest action I need to take.

        Set it up now if you can. Otherwise, guide me through only what you cannot perform yourself.
        """
    }

    private var serverStatusLabel: String {
        if stopInProgress {
            return "Stopping..."
        }
        if hostedStartInProgress {
            return "Connecting..."
        }
        switch launcher.state {
        case .idle:
            if hostedTunnelIsReachable {
                return "Connected"
            }
            if statusChecker.status == .checking {
                return "Checking..."
            }
            return "Offline"
        case .starting:
            return "Starting..."
        case .settingUp:
            return "Connecting..."
        case .running:
            return "Connected"
        case .servedElsewhere:
            return "Served by another Mac"
        case .failed:
            return "Connection failed"
        }
    }

    private var isMCPReachable: Bool {
        launcher.state == .running || hostedTunnelIsReachable
    }

    @ViewBuilder
    private func pairingCodeRow(_ value: String) -> some View {
        HStack(spacing: 12) {
            Text("Pairing code")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                copy(value, label: "Pairing code")
            } label: {
                Image(systemName: copied == "Pairing code" ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(copied == "Pairing code" ? .green : .secondary)
            }
            .buttonStyle(.hoverWash)
        }
    }

    private func copy(_ value: String, label: String) {
        copyToClipboard(value)
        copied = label
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == label { copied = nil }
        }
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Compact chip for a source in the MCP context tray.
struct MCPContextChip: View {
    let article: StudioArticle
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 8, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash)

            Text(article.title)
                .zoomedSystemFont(size: 10)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.purple.opacity(0.12), in: Capsule())
    }
}
