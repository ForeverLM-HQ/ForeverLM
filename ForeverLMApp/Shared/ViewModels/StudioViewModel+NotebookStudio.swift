import Foundation

// MARK: - The notebook's Studio: what can be made
//
// The Studio column's tiles (docs/notebooks-design.md, "Studio"), in Gemini
// Notebook's order, and the Notebook menu's Make ▸ beside them. Each tile asks
// first — the feature's own options, a source, a sentence in a chat — and
// makes on the second press, the way the feature already does elsewhere: the
// audio overview's options sheet and its Make, the Cards menu and its
// Practice or Make Cards' sheet and its Make, a chat
// that waits for its question or its go-ahead, the explainer's source picked
// from a menu. Everything made is homed in the notebook by the feature that
// makes it; the cards Make Cards drafts are the learner's own, on their
// sources' private decks.

/// One of the Studio's tiles.
enum NotebookStudioTile: String, CaseIterable, Identifiable, Sendable {
    case audioOverview
    case videoOverview
    case cards
    case report
    case deepResearch
    case course
    case explainer
    /// A canvas of the notebook, where its sources are laid out and thought
    /// over (docs/knowledge-map-design.md, "Canvases in a notebook"). Beta
    /// with the Canvas: the Studio draws it only where the Canvas shows.
    case canvas
    case note

    var id: String { rawValue }

    /// The tiles drawn now, in order: every tile, the Report while its
    /// generator is offered (`ReportEntry.isAvailable`).
    static var offered: [NotebookStudioTile] {
        allCases.filter { $0 != .report || ReportEntry.isAvailable }
    }

    /// The tiles the Studio column draws in its grid: Note is the column's
    /// floating Add note at its foot, as in Gemini Notebook, not a tile.
    static var gridTiles: [NotebookStudioTile] {
        offered.filter { $0 != .note }
    }

    var title: String {
        switch self {
        case .audioOverview: return "Audio overview"
        case .videoOverview: return "Video overview"
        case .cards: return "Cards"
        case .report: return "Report"
        case .deepResearch: return "Deep research"
        case .course: return "Course"
        case .explainer: return "Explainer"
        case .canvas: return "Canvas"
        case .note: return "Note"
        }
    }

    /// The glyph each tile shows: the mark its feature already uses
    /// elsewhere (an overview's waveform, Memory's, the Deep Research mode's
    /// globe, the Courses rail row's cap, the explainer's lightbulb).
    var symbolName: String {
        switch self {
        case .audioOverview: return ArtifactKind.audioOverview.symbolName
        case .videoOverview: return "play.rectangle"
        case .cards: return MemoryReviewSession.sidebarIcon
        case .report: return "doc.richtext"
        case .deepResearch: return "globe"
        case .course: return "graduationcap"
        case .explainer: return "lightbulb"
        case .canvas: return "square.on.square.dashed"
        case .note: return "square.and.pencil"
        }
    }

    /// Whether the tile picks one of several before making: a menu. Cards
    /// offers Practice, Make Cards… and Open in Memory; the Explainer, the
    /// ticked paper.
    var isMenu: Bool {
        self == .report || self == .explainer || self == .cards || self == .canvas
    }

    /// Whether the tile files something into the notebook, which an archived
    /// notebook, or a read-only team's, does not take. Cards file nothing in
    /// it: practising writes nothing of the notebook's, and the cards made
    /// are the learner's own, on their sources' private decks.
    var makesIntoNotebook: Bool { self != .cards }

    /// The tile's help.
    var help: String {
        switch self {
        case .audioOverview: return "Make an audio overview of the ticked sources"
        case .videoOverview: return "Make a short video of the ticked papers and articles"
        case .cards: return "Make cards from the ticked sources, or practice the notebook's cards"
        case .report: return "Write a report from the ticked sources"
        case .deepResearch: return "Start a Deep Research chat in this notebook"
        case .course: return "Plan a course from the ticked sources"
        case .explainer: return "Write a spoken explainer of a ticked source"
        case .canvas: return "Lay the notebook's sources out on a canvas"
        case .note: return "A new note in this notebook"
        }
    }
}

extension StudioViewModel {
    /// Whether the notebook takes what its Studio makes: an active notebook
    /// of the open library this account can edit (`importableNotebook`).
    func notebookTakesMadeThings(_ notebookID: String) -> Bool {
        importableNotebook(notebookID) != nil
    }

    /// The ticked sources a tile works from, as the library holds them: the
    /// notebook's own — its Sources column's own rows — never a context
    /// notebook's, put into its chats or not (`NotebookSourceLoader.notebookSourceIDs`).
    func notebookStudioSourceIDs(_ notebookID: String) -> [String] {
        guard let notebook = notebook(id: notebookID) else { return [] }
        return NotebookChatSelection.chatSourceIDs(
            pool: notebook.approvedSourceIDs,
            excluded: notebookChatExclusions[notebookID] ?? []
        ).filter { articlesById[$0] != nil }
    }

    /// The notebook's ticked sources an explainer can be written about —
    /// papers, articles, podcast episodes, videos and meetings
    /// (`GeneratedExplainer.canExplain`) — for the Explainer tile's menu, in
    /// the notebook's order.
    func notebookExplainerCandidates(_ notebookID: String) -> [StudioArticle] {
        notebookStudioSourceIDs(notebookID)
            .compactMap { articlesById[$0] }
            .filter(GeneratedExplainer.canExplain)
    }

    /// Deep research: a fresh chat in the notebook, in Deep Research mode,
    /// with its ticked sources, waiting for the question — or with
    /// `question` typed and unsent, as Discover's Research this deeply asks.
    /// The chat writes its report as a Doc (docs/chat-design.md). Nothing
    /// for a notebook that takes nothing.
    func requestNotebookDeepResearch(notebookID: String, question: String? = nil) {
        guard let notebook = importableNotebook(notebookID) else { return }
        let words = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pendingReviewChatDraft = words.isEmpty ? nil : words
        pendingReviewChatMode = .deepResearch
        requestBlankReviewChat(notebookID: notebook.id)
    }

    /// Course: today's course generation — a chat that plans the course with
    /// the learner and makes it on their go-ahead — in the notebook, reading
    /// its own ticked sources (`startCoursePlanningChat(inNotebook:)`).
    func requestNotebookCourse(notebookID: String) {
        guard let notebook = importableNotebook(notebookID) else { return }
        startCoursePlanningChat(inNotebook: notebook.id)
    }

    /// Note: a new Doc homed in the notebook, opened in its document slot in
    /// `windowState` — the window the tile was pressed in, named because the
    /// write awaits and an `inWindow` scope would not outlast it.
    func makeNotebookNote(notebookID: String, in windowState: StudioWindowState) async {
        guard let notebook = importableNotebook(notebookID) else { return }
        do {
            let snapshot = try await createArtifact(
                title: ArtifactPlaceholderTitle.current,
                homeNotebookID: notebook.id,
                linkedNotebookIDs: [notebook.id]
            )
            revealArtifact(snapshot.artifact.id, in: windowState)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Video overview: one or more video files from disk — a Gemini
    /// Notebook video overview, say — each brought in as a source and filed
    /// in the notebook, where it is listed among its outputs and plays in the
    /// Reader (`VideoOverviewImporter`). One toast says how it went.
    func importVideoOverviews(at urls: [URL], intoNotebook notebookID: String) async {
        guard let notebook = importableNotebook(notebookID) else { return }
        var outcomes: [NotebookImportOutcome] = []
        for url in urls {
            outcomes.append(await importVideoOverview(at: url, intoNotebook: notebook.id))
        }
        if let toast = NotebookSourcePicking.uploadToast(outcomes, notebookTitle: notebook.title, noun: "videos") {
            showToast(toast)
        }
    }

    /// Explainer, for a source whose explainer exists: it opens in the
    /// Reader — the document slot — in `windowState`, with the source's row
    /// selected as its list's account of what the Reader shows, as the
    /// source's own Open Explainer does. False when there is none to open,
    /// and the caller writes one (`ExplainerGenerationCoordinator`).
    @discardableResult
    func openNotebookExplainer(of sourceID: String, in windowState: StudioWindowState) async -> Bool {
        guard let explainer = explainer(explaining: sourceID) else { return false }
        await openExplainer(explainer.id, explaining: sourceID, in: windowState)
        return true
    }
}
