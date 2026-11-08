#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The notebook's **Studio** column, the workspace's right-hand part
/// (docs/notebooks-design.md, "Studio"): its title and fold on the chrome
/// line over what can be made and what was made (`NotebookStudioColumn`);
/// folded, it leaves the window (2026-10-17: no strips beside the chat), and
/// the window's top-left toggle brings it back. Studio has the column to itself since
/// 2026-10-02: the library is the Sources column's search, and About is the
/// notebook's settings sheet.
struct NotebookStudioPanel: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    let notebookID: String

    /// The notebook's Share popover (docs/teams-design.md, decision 22),
    /// from the Share at the top right of the chrome line and from the
    /// notebook's ⋯ (`showNotebookShare`). While Studio is folded the
    /// workspace owns the popover (`NotebookWorkspaceView`).
    @State private var isShowingShare = false

    var body: some View {
        Group {
            if let goal = vm.notebook(id: notebookID) {
                NotebookStudioColumn(goal: goal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .studioChromeLineHeader { header(goal) }
            } else {
                Color.clear
            }
        }
        // Never the leftmost column, and nothing overlays its corner.
        .environment(\.studioCenterPaneHeaderLeadingInset, 0)
        .environment(\.studioChromeLineReservation, StudioChromeLineReservation())
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio")
        .accessibilityIdentifier("notebook.studio")
        .onReceive(NotificationCenter.default.publisher(for: .showNotebookShare)) { note in
            guard (note.object as? UUID) == windowState.id, vm.notebook(id: notebookID) != nil else { return }
            isShowingShare = true
        }
    }

    private func header(_ goal: LearningGoalRecord) -> some View {
        HStack(spacing: 0) {
            Text("Studio")
                .zoomedSystemFont(size: 12.5, weight: .semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            // NotebookLM's place for Share: the top right of the notebook.
            NotebookShareButton { isShowingShare = true }
                .popover(isPresented: $isShowingShare, arrowEdge: .bottom) {
                    NotebookSharePopover(goal: goal, close: { isShowingShare = false })
                        .environment(vm)
                }
                .padding(.trailing, 8)
            // The Studio's own fold, on the Studio's own line (ChatGPT's panel
            // close); folded, the workspace draws the way back at the same
            // corner (`NotebookWorkspaceView.studioRestore`).
            TitlebarBandButton(
                help: "Hide Studio",
                accessibilityIdentifier: "notebook.studio.collapse",
                action: { setCollapsed(true) }
            ) {
                Image(systemName: "sidebar.right")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard windowState.notebook?.studioCollapsed != collapsed else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            windowState.notebook?.studioCollapsed = collapsed
        }
    }
}

/// What can be made from the notebook's ticked sources, as tiles in two
/// columns in Gemini Notebook's order, each in its own hue
/// (`NotebookStudioHue`), then everything the notebook made and its sources
/// gave rise to, newest first, each led by its kind's badge in the hue of the
/// tile that makes it, under no heading and with nothing said while there is
/// none (the tiles say what can be made), and at its foot the floating **Add
/// note** (the Note tile, as Gemini draws it).
///
/// A tile asks first and makes on the second press, the way its feature does
/// elsewhere (`NotebookStudioTile`). An output opens where its kind opens — in
/// a notebook window, a pane beside the chat
/// (`StudioViewModel.openNotebookOutput`).
struct NotebookStudioColumn: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    /// Runs still writing an overview, listed first among the outputs.
    @ObservedObject private var overviewWriter = AudioOverviewGenerationCoordinator.shared
    /// A walkthrough written anywhere changes this notebook's list.
    @ObservedObject private var walkthroughWriter = WalkthroughGenerationCoordinator.shared
    let goal: LearningGoalRecord

    /// The walkthroughs of the notebook's sources and the courses it
    /// follows, read from storage off the main actor.
    @State private var walkthroughs: [PaperWalkthroughSummary] = []
    @State private var linkedCourseIDs: Set<String> = []
    /// The notebook's cards, for the Cards row and the Cards tile: kept, due
    /// and to check (`notebookCardCounts`). Nil until first read.
    @State private var cardCounts: NotebookCardCounts?
    /// The Make Cards runs on its sources and the pictures homed in it,
    /// read off the main actor (`NotebookStudioMadeExtras`).
    @State private var extras = NotebookStudioMadeExtras.Loaded()
    @State private var openedImage: GeneratedImageStore.ImageGroup?

    private var runs: [NotebookOutputs.Run] {
        overviewWriter.runs.map { run in
            NotebookOutputs.Run(id: run.id, notebookID: run.notebookID, title: run.notebookTitle, startedAt: run.startedAt)
        }
    }

    private var walkthroughsKey: String {
        "\(goal.id)#\(vm.readerWalkthroughRevision)#\(walkthroughWriter.runs.count)#\(vm.notebookMembershipRevision)#\(vm.recordingScopeRevision)#\(vm.activeTeamID ?? "")"
    }

    /// Following a course touches the notebook's record, so its date reads
    /// the links again.
    private var coursesKey: String {
        "\(goal.id)#\(goal.updatedAt.timeIntervalSinceReferenceDate)"
    }

    /// A card kept, skipped or answered, a deck grown, a source added to the
    /// notebook, or a new day (a card falls due on reading) reads the counts
    /// again.
    private var cardsKey: String {
        "\(goal.id)#\(goal.updatedAt.timeIntervalSinceReferenceDate)#\(vm.memoryCardRevision)#\(vm.notebookMembershipRevision)#\(vm.recordingScopeRevision)#\(MemoryReviewGoal.dayKey(for: Date()))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tiles
                outputs
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // Room for the floating Add note over the last output. Screen record
            // mode draws no pill, so no room is kept for it either.
            .padding(.bottom, vm.isScreenRecordModeActive ? 12 : 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            // A pill floating over the rows covers the last one on a film.
            if !vm.isScreenRecordModeActive { addNote }
        }
        .task(id: walkthroughsKey) {
            walkthroughs = await vm.notebookWalkthroughs(notebookID: goal.id)
        }
        .task(id: coursesKey) {
            linkedCourseIDs = await vm.notebookLinkedCourseIDs(notebookID: goal.id)
        }
        .task(id: cardsKey) {
            cardCounts = nil
            let counts = await vm.notebookCardCounts(notebookID: goal.id)
            guard !Task.isCancelled else { return }
            cardCounts = counts
        }
        .modifier(NotebookStudioMadeExtras(goal: goal, cardsKey: cardsKey, extras: $extras, openedImage: $openedImage))
        // The records are the view model's; a notebook opened first after a
        // launch reads them once rather than showing nothing made.
        .task(id: goal.id) {
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
        }
        // A record open beside the chat is seen, however it got there: Add
        // note, a finished report, a link, the strip.
        .onChange(of: openRecordKey, initial: true) { _, _ in markOpenRecordSeen() }
    }

    /// The Doc, Site or animation a pane of the window shows, with the
    /// records it was read against, so a record that arrives after it opened
    /// (a report saving) is marked too.
    private var openRecordKey: String {
        let showsRecord = showsRecordPane
        return "\(showsRecord ? windowState.openArtifactID ?? "" : "")#\(vm.artifacts.count)"
    }

    /// Whether a pane of the window shows Pages, Sites or animations.
    private var showsRecordPane: Bool {
        windowState.centerTabGroups.groups.contains { [.notepad, .sites, .animations].contains($0.activeTab) }
    }

    private func markOpenRecordSeen() {
        guard showsRecordPane,
              let openID = windowState.openArtifactID else { return }
        let outputs = vm.notebookOutputs(
            notebookID: goal.id,
            walkthroughs: walkthroughs,
            linkedCourseIDs: linkedCourseIDs,
            runs: runs,
            cardRuns: extras.cardRuns,
            pictures: extras.pictures,
            narrations: extras.narrations
        )
        for output in outputs where output.targetID == openID {
            NotebookOutputSeenTracker.shared.markSeen(output)
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(NotebookStudioTile.gridTiles.filter { $0 != .canvas || vm.listsCanvases }) { tile in
                NotebookStudioTileControl(tile: tile, goal: goal, cardCounts: cardCounts, style: .chip)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Make")
        .accessibilityIdentifier("notebook.studio.tiles")
    }

    /// The Note tile, as Gemini draws it: a floating button at the column's
    /// foot that makes a new Doc homed in the notebook and opens it beside
    /// the chat.
    private var addNote: some View {
        NotebookStudioTileControl(tile: .note, goal: goal, style: .floating)
            .padding(.bottom, 12)
    }

    // MARK: - Outputs

    private var outputs: some View {
        let outputs = vm.notebookOutputs(
            notebookID: goal.id,
            walkthroughs: walkthroughs,
            linkedCourseIDs: linkedCourseIDs,
            runs: runs,
            cardRuns: extras.cardRuns,
            pictures: extras.pictures,
            narrations: extras.narrations
        )
        let overviews = AudioOverviewOutput.byID(vm.audioOverviews(inNotebook: goal.id))
        // Lazy, so a row is built as it scrolls in: opening a notebook
        // builds the outputs on screen, not every walkthrough and explainer
        // its sources gave rise to (why that matters: `NotebookOutputRow`'s
        // ⋯ menu). No "Outputs" heading and no "Nothing made yet" since
        // 2026-10-06 (the product owner: "cleaner and fewer buttons and bells and
        // whistles"): the badged rows read as what was made, and the tiles
        // above say what can be.
        return LazyVStack(alignment: .leading, spacing: 4) {
            // The notebook's cards are not outputs of their own: a card rides
            // the sources it stands on and a source's deck is the learner's
            // private memory state, so they are one row with their counts.
            if let counts = cardCounts, !counts.isEmpty {
                NotebookCardsRow(counts: counts, notebookID: goal.id)
            }
            // The notebook's canvases, one row each (beta with the Canvas):
            // a canvas is something the notebook made, opened where the
            // Canvas tile opens it.
            ForEach(vm.canvases(inNotebook: goal.id)) { canvas in
                NotebookCanvasRow(canvas: canvas)
            }
            // Cards being drafted from the ticked sources, with Stop; once
            // drafted they wait in the Cards row above.
            CardDraftingRunsList(vm: vm, notebookID: goal.id)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            // A report being written, the Report tile's or an assistant's;
            // once saved it is one of the Docs below.
            ReportRunsList(vm: vm, notebookID: goal.id)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            // A reading being written, until its first source lands; then
            // its own row below says how far it has come.
            MnemonicReadingRunsList(vm: vm, notebookID: goal.id)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            ForEach(outputs) { output in
                if output.kind == .audioOverview, let overview = overviews[output.targetID] {
                    AudioOverviewOutputRow(vm: vm, output: overview)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                } else {
                    NotebookOutputRow(
                        output: output,
                        notebookID: goal.id,
                        openPicture: { imageID in
                            openedImage = extras.imageGroups.first { $0.imageID == imageID }
                        },
                        pictureGroup: output.kind == .picture
                            ? extras.imageGroups.first { $0.imageID == output.targetID }
                            : nil,
                        picturesChanged: {
                            let notebookID = goal.id
                            Task {
                                let groups = await NotebookStudioMadeExtras.pictures(inNotebook: notebookID, vm: vm)
                                if groups != extras.imageGroups { extras.imageGroups = groups }
                            }
                        }
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outputs")
        .accessibilityIdentifier("notebook.studio.outputs")
    }
}

/// The kinds of output the Studio reads from outside the view model's
/// records: the Make Cards runs
/// on the notebook's sources (`StudioViewModel.notebookCardRuns`, read again
/// when a card is drafted, kept or skipped, or the notebook's sources
/// change), the standalone pictures homed in it (read again when a picture
/// is saved, redrawn or filed elsewhere), and the narrations made of its
/// sources (read again when the audio cache says one came or went). A
/// picture opens in its sheet, over this window.
struct NotebookStudioMadeExtras: ViewModifier {
    struct Loaded: Equatable {
        var cardRuns: [NotebookOutputs.CardRun] = []
        var imageGroups: [GeneratedImageStore.ImageGroup] = []
        var narrations: [NotebookOutputs.Narration] = []

        /// The notebook's pictures, as the outputs list them.
        @MainActor var pictures: [NotebookOutputs.Picture] {
            imageGroups.map { group in
                NotebookOutputs.Picture(
                    imageID: group.imageID,
                    notebookID: group.notebookID,
                    title: GeneratedImageActions.title(for: group),
                    date: group.updatedAt
                )
            }
        }
    }

    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let cardsKey: String
    @Binding var extras: Loaded
    @Binding var openedImage: GeneratedImageStore.ImageGroup?
    /// Bumped when the audio cache says a narration came or went.
    @State private var narrationRevision = 0

    /// The notebook's sources and the library's, so a source added, or its
    /// narration made, reads the narrations again.
    private var narrationsKey: String {
        "\(goal.id)#\(vm.notebookMembershipRevision)#\(vm.recordingScopeRevision)#\(vm.articles.count)#\(narrationRevision)#\(vm.activeTeamID ?? "")"
    }

    func body(content: Content) -> some View {
        content
            .task(id: cardsKey) {
                let runs = await vm.notebookCardRuns(notebookID: goal.id)
                if runs != extras.cardRuns { extras.cardRuns = runs }
            }
            .task(id: goal.id) { await loadPictures() }
            .task(id: narrationsKey) { await loadNarrations() }
            .onReceive(NotificationCenter.default.publisher(for: ArticleSpeechAudioCache.statusDidChangeNotification)) { _ in
                narrationRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .foreverLMDataDidChange)) { _ in
                Task { await loadPictures() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .generatedImageRedrawn)) { _ in
                Task { await loadPictures() }
            }
            .sheet(item: $openedImage, onDismiss: {
                Task { await loadPictures() }
            }) { group in
                GeneratedImageSheet(group: group) {
                    openedImage = nil
                    Task {
                        _ = await GeneratedImageActions.trash(group)
                        await loadPictures()
                    }
                }
            }
    }

    private func loadPictures() async {
        let groups = await Self.pictures(inNotebook: goal.id, vm: vm)
        if groups != extras.imageGroups { extras.imageGroups = groups }
    }

    /// The pictures homed in a notebook (screen record mode's scope
    /// included), for this modifier and for a row whose action changed one.
    /// None in a team library: a picture is this Mac's file.
    static func pictures(inNotebook notebookID: String, vm: StudioViewModel) async -> [GeneratedImageStore.ImageGroup] {
        guard vm.activeTeamID == nil else { return [] }
        return await GeneratedImageActions.loadDrawn().filter { $0.notebookID == notebookID }
    }

    /// The narrations made of the notebook's sources: one marker file a
    /// source, read off the main actor. A spoken script (an explainer's, an
    /// audio overview's) is the narration of an output that lists itself,
    /// so it is left out. None in a team library: a narration is this Mac's
    /// audio of the learner's own source.
    private func loadNarrations() async {
        guard vm.activeTeamID == nil, let notebook = vm.notebook(id: goal.id) else {
            if !extras.narrations.isEmpty { extras.narrations = [] }
            return
        }
        let candidates = vm.notebookOutputMemberIDs(notebook).filter { sourceID in
            vm.articlesById[sourceID].map { SourceNarration.isListedAsArtifact(sourceURL: $0.url) } ?? false
        }
        let found = await Task.detached(priority: .utility) {
            candidates.compactMap { sourceID -> (String, Date)? in
                ArticleSpeechAudioCache.cachedMarkerDate(sourceID: sourceID).map { (sourceID, $0) }
            }
        }.value
        guard !Task.isCancelled else { return }
        // Screen record mode: only narrations of the recording Notebook's
        // sources, or made during the take.
        let scope = vm.screenRecordScope
        let narrations = found.compactMap { sourceID, madeAt -> NotebookOutputs.Narration? in
            guard let article = vm.articlesById[sourceID],
                  scope?.allowsSourceDerived(createdAt: madeAt, sourceID: sourceID) ?? true else { return nil }
            return NotebookOutputs.Narration(sourceID: sourceID, title: vm.displayTitle(for: article), date: madeAt)
        }
        .sorted { $0.sourceID < $1.sourceID }
        if narrations != extras.narrations { extras.narrations = narrations }
    }
}

/// One Studio tile, drawn as a labelled chip in the column's grid or — for
/// Note — as the column's floating Add note. Both faces do the same thing: a
/// menu tile opens its menu, the others take their first press
/// (`NotebookStudioTile`).
struct NotebookStudioTileControl: View {
    enum Style {
        case chip
        case floating
    }

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    /// Explainers being written, for the Explainer tile.
    @ObservedObject private var explainerWriter = ExplainerGenerationCoordinator.shared
    /// Cards being drafted, for the Cards tile.
    @ObservedObject private var cardWriter = CardDraftingCoordinator.shared
    let tile: NotebookStudioTile
    let goal: LearningGoalRecord
    /// The notebook's cards, for the Cards menu's first line; nil until read.
    var cardCounts: NotebookCardCounts? = nil
    var style: Style = .chip

    private var takesMadeThings: Bool { vm.notebookTakesMadeThings(goal.id) }

    var body: some View {
        let enabled = isEnabled
        switch tile {
        case .report:
            Menu {
                ForEach(ReportEntry.Format.allCases) { format in
                    Button(format.title, systemImage: format.symbolName) {
                        vm.inWindow(windowState) { vm.presentReportOptions(notebookID: goal.id, format: format) }
                    }
                }
            } label: {
                NotebookStudioTileLabel(tile: tile, isEnabled: enabled, style: style)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .hoverHighlight(cornerRadius: cornerRadius, inset: 0)
            .disabled(!enabled)
            .help(tile.help)
            .accessibilityIdentifier(identifier)
        case .cards:
            // The notebook's cards ("42 kept · 6 due · 9 to check"), then
            // Practice — its kept cards and its cards to check, in the
            // window-filling review — and Make Cards…, a chat on the ticked
            // sources that drafts their cards for To Check (the learner says
            // how many there); Open in Memory opens the Memory pane narrowed
            // to the notebook, with its Start Review.
            Menu {
                if let line = cardCounts?.line {
                    Text(line)
                }
                Button("Practice", systemImage: "play") {
                    vm.inWindow(windowState) { vm.startNotebookPractice(notebookID: goal.id) }
                }
                .disabled(cardCounts?.isEmpty == true)
                Button("Write Cards", systemImage: "plus.rectangle.on.rectangle") {
                    vm.inWindow(windowState) { vm.requestNotebookWriteCards(notebookID: goal.id) }
                }
                .disabled(vm.notebookStudioSourceIDs(goal.id).isEmpty)
                Divider()
                Button("Open in Memory", systemImage: MemoryReviewSession.sidebarIcon) {
                    vm.inWindow(windowState) { vm.requestCardReview(scope: .notebook(goal.id)) }
                }
            } label: {
                NotebookStudioTileLabel(
                    tile: tile,
                    isEnabled: enabled,
                    isBusy: !cardWriter.runs(inNotebook: goal.id).isEmpty,
                    style: style
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .hoverHighlight(cornerRadius: cornerRadius, inset: 0)
            .disabled(!enabled)
            .help(tile.help)
            .accessibilityIdentifier(identifier)
        case .canvas:
            // The notebook's canvases, then a new one: where its sources are
            // laid out and thought over (product owner, 2026-10-09).
            let canvases = vm.canvases(inNotebook: goal.id)
            Menu {
                ForEach(canvases) { canvas in
                    Button(canvas.name, systemImage: "square.on.square.dashed") {
                        vm.inWindow(windowState) { vm.openCanvas(canvas.id, in: windowState) }
                    }
                }
                if !canvases.isEmpty { Divider() }
                Button("New Canvas", systemImage: "plus") {
                    vm.inWindow(windowState) { vm.makeAndOpenCanvas(inPageSpace: nil, notebookID: goal.id, in: windowState) }
                }
            } label: {
                NotebookStudioTileLabel(tile: tile, isEnabled: enabled, style: style)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .hoverHighlight(cornerRadius: cornerRadius, inset: 0)
            .disabled(!enabled)
            .help(tile.help)
            .accessibilityIdentifier(identifier)
        case .explainer:
            // Live whenever the notebook takes what it makes, as Cards and
            // Report are: with nothing it can explain ticked the menu says
            // what it needs instead of the tile greying out.
            let candidates = vm.notebookExplainerCandidates(goal.id)
            Menu {
                if candidates.isEmpty {
                    Text(Self.nothingToExplainLine)
                }
                ForEach(candidates) { article in
                    explainerItem(article)
                }
            } label: {
                NotebookStudioTileLabel(
                    tile: tile,
                    isEnabled: enabled,
                    isBusy: candidates.contains { explainerWriter.isWriting($0.id) },
                    style: style
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .hoverHighlight(cornerRadius: cornerRadius, inset: 0)
            .disabled(!enabled)
            .help(tile.help)
            .accessibilityIdentifier(identifier)
        default:
            Button {
                act()
            } label: {
                NotebookStudioTileLabel(
                    tile: tile,
                    isEnabled: enabled,
                    style: style
                )
            }
            .buttonStyle(.hoverWash(cornerRadius: cornerRadius, inset: 0))
            .disabled(!enabled)
            .help(tile.help)
            .accessibilityIdentifier(identifier)
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .chip: return 12
        case .floating: return 17
        }
    }

    private var identifier: String { "notebook.studio.\(tile.rawValue)" }

    /// The Explainer menu's one line when no ticked source is one it can
    /// explain: what to add or tick for it to work on.
    private static let nothingToExplainLine = "Add or tick a paper, article, episode or video first"

    /// One ticked source in the Explainer tile's menu: its explainer opens
    /// when it has one, is written when it has none, and while it is being
    /// written the item stops the write, as the source's own Cancel Writing
    /// Explainer does (`ExplainerMenuItems`).
    @ViewBuilder
    private func explainerItem(_ article: StudioArticle) -> some View {
        let title = vm.displayTitle(for: article)
        if explainerWriter.isWriting(article.id) {
            Button("Cancel Writing \u{201C}\(title)\u{201D}", systemImage: "xmark.circle") {
                explainerWriter.cancel(article.id)
            }
            .help("Stop writing this source's explainer; nothing is saved")
        } else {
            let exists = vm.explainer(explaining: article.id) != nil
            Button(title, systemImage: exists ? "lightbulb.fill" : "lightbulb") {
                NotebookStudioActions.explain(article, in: windowState, vm: vm)
            }
        }
    }

    private var isEnabled: Bool {
        if tile == .audioOverview, vm.audioOverviewOptionsTarget(notebookID: goal.id) == nil { return false }
        return !tile.makesIntoNotebook || takesMadeThings
    }

    private func act() {
        switch tile {
        case .audioOverview:
            NotebookStudioActions.requestAudioOverview(in: windowState)
        case .deepResearch:
            vm.inWindow(windowState) { vm.requestNotebookDeepResearch(notebookID: goal.id) }
        case .course:
            vm.inWindow(windowState) { vm.requestNotebookCourse(notebookID: goal.id) }
        case .note:
            let notebookID = goal.id
            Task { await vm.makeNotebookNote(notebookID: notebookID, in: windowState) }
        case .videoOverview:
            NotebookStudioActions.makeVideoOverview(of: goal, vm: vm)
        case .report, .explainer, .cards, .canvas:
            // Menus, drawn above.
            break
        }
    }
}

/// A Studio tile's face. As a chip, Gemini's tile: its glyph in its hue over
/// a pale wash of it, its word beside it on the same line (product owner,
/// 2026-10-12: the word always under the icon "looks weird"), no chevron on
/// a tile that picks first (product owner, 2026-10-12: a down arrow on half
/// the tiles "looks bad"; the menu opens on the click), a spinner while what
/// it makes is being written; greyed while it cannot make. As the floating
/// Add note, Gemini's dark pill with a shadow.
private struct NotebookStudioTileLabel: View {
    @Environment(\.uiZoomScale) private var zoom
    let tile: NotebookStudioTile
    let isEnabled: Bool
    var isBusy = false
    var style: NotebookStudioTileControl.Style = .chip

    /// The pill paints its own light-up: a wash behind an opaque pill
    /// would not show.
    @State private var isHovering = false

    var body: some View {
        switch style {
        case .chip: chip
        case .floating: floating
        }
    }

    /// The glyph, or the spinner in its place. Decoration: VoiceOver reads
    /// the tile's word, not "waveform" beside it.
    private func glyph(size: CGFloat) -> some View {
        ZStack {
            Image(systemName: tile.symbolName)
                .zoomedSystemFont(size: size, weight: .medium)
                .opacity(isBusy ? 0 : 1)
                .accessibilityHidden(true)
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: (size + 4) * zoom, height: (size + 4) * zoom)
    }

    private var chip: some View {
        HStack(spacing: 5) {
            glyph(size: 14)
                .foregroundStyle(tile.hue.glyph)
            Text(tile.title)
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tile.hue.wash)
        )
        .saturation(isEnabled ? 1 : 0)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var floating: some View {
        HStack(spacing: 6) {
            Image(systemName: tile.symbolName)
                .zoomedSystemFont(size: 12, weight: .medium)
                .accessibilityHidden(true)
            Text("Add note")
                .zoomedSystemFont(size: 12, weight: .medium)
        }
        // Light on dark in a light window, dark on light in a dark one.
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isHovering && isEnabled ? 0.74 : 0.88))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The hue a Studio tile wears and the outputs of its kind lead with, as
/// Gemini Notebook colours its Studio: the glyph in the hue over a pale wash
/// of it. Each hue is a deeper colour in a light window and a lighter one in
/// a dark window, so the glyph reads against its wash in both.
struct NotebookStudioHue {
    let glyph: Color
    let wash: Color

    private init(light: UInt32, dark: UInt32) {
        glyph = Self.color(light: light, dark: dark, lightAlpha: 1, darkAlpha: 1)
        wash = Self.color(light: light, dark: dark, lightAlpha: 0.12, darkAlpha: 0.18)
    }

    static let indigo = Self(light: 0x4C5BD4, dark: 0xA5AEFF)
    static let coral = Self(light: 0xD8483F, dark: 0xFF8A80)
    static let amber = Self(light: 0xB56F00, dark: 0xF2BE5C)
    static let teal = Self(light: 0x0B8A80, dark: 0x5CD3C6)
    static let green = Self(light: 0x2D8A45, dark: 0x7ED493)
    static let magenta = Self(light: 0xB43A8F, dark: 0xF28BD3)
    static let sky = Self(light: 0x1D74C0, dark: 0x7CBDF5)
    static let violet = Self(light: 0x7A4BD0, dark: 0xBB9CFF)
    static let cyan = Self(light: 0x0A7F99, dark: 0x62CBE2)
    /// A book's page, for the mnemonic reading.
    static let sepia = Self(light: 0x8D6E4B, dark: 0xD2B48C)
    /// A standalone picture: no tile makes one, a chat draws it.
    static let rose = Self(light: 0xC2416B, dark: 0xF59AB8)

    private static func color(light: UInt32, dark: UInt32, lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

extension NotebookStudioTile {
    /// The tile's hue, in Gemini's spirit: the audio overview blue, cards
    /// coral, reports amber. Note is amber too: a note is a Doc, and a Doc
    /// is what Report writes.
    var hue: NotebookStudioHue {
        switch self {
        case .audioOverview: return .indigo
        case .videoOverview: return .sky
        case .cards: return .coral
        case .report, .note: return .amber
        case .deepResearch: return .teal
        case .course: return .green
        case .explainer: return .magenta
        case .canvas: return .violet
        }
    }
}

extension NotebookOutput.Kind {
    /// The hue of the tile that makes the kind (a Doc is what Report, Deep
    /// research and Note write), and one of its own for a kind no tile
    /// makes.
    var hue: NotebookStudioHue {
        switch self {
        case .doc: return NotebookStudioTile.report.hue
        case .audioOverview: return NotebookStudioTile.audioOverview.hue
        case .course: return NotebookStudioTile.course.hue
        case .explainer: return NotebookStudioTile.explainer.hue
        case .videoOverview: return NotebookStudioTile.videoOverview.hue
        case .mnemonicReading: return .sepia
        case .cards: return NotebookStudioTile.cards.hue
        case .picture: return .rose
        case .narration: return .teal
        case .walkthrough: return .sky
        case .animation: return .violet
        case .site: return .cyan
        }
    }
}

/// A kind's glyph on a rounded square of its hue: what each row of the
/// Studio's outputs leads with, the Cards row and the rows of things still
/// being made included.
struct NotebookStudioBadge: View {
    @Environment(\.uiZoomScale) private var zoom
    let symbolName: String
    let hue: NotebookStudioHue

    var body: some View {
        Image(systemName: symbolName)
            .zoomedSystemFont(size: 11.5, weight: .medium)
            .foregroundStyle(hue.glyph)
            .frame(width: 26 * zoom, height: 26 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 7 * zoom, style: .continuous)
                    .fill(hue.wash)
            )
            .accessibilityHidden(true)
    }
}

/// The notebook's Cards row, first among its outputs while it has any card:
/// "42 kept · 6 due · 9 to check" (`NotebookCardCounts`), with **Practice**
/// — its kept cards and its cards to check, in the window-filling review —
/// and **Make Cards…** for the ticked sources, shown while the pointer is
/// over the row (2026-10-06; they were always drawn, repeating the Cards
/// tile's menu above). A click opens the Memory pane narrowed to the
/// notebook in a pane of the window: its To Check while cards wait
/// there, else its Review (`openNotebookCards`); the right-click opens it in
/// the other window too and carries Practice and Make Cards…, as the Cards
/// tile's menu does.
/// One of the notebook's canvases among what it made: its name, opened on a
/// click, with the Space's own menu on a right-click.
private struct NotebookCanvasRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let canvas: KnowledgeMapCanvas

    var body: some View {
        Button {
            vm.inWindow(windowState) { vm.openCanvas(canvas.id, in: windowState) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                NotebookStudioBadge(symbolName: "square.on.square.dashed", hue: NotebookStudioTile.canvas.hue)
                Text(canvas.name)
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .help("Open this canvas")
        .accessibilityLabel("Canvas, \(canvas.name)")
        .accessibilityIdentifier("notebook.studio.canvas.\(canvas.id)")
        .contextMenu {
            Button("Open") { vm.inWindow(windowState) { vm.openCanvas(canvas.id, in: windowState) } }
            Button("Take Out of Notebook") { vm.setCanvasNotebook(canvas.id, to: nil) }
            Divider()
            Button("Move to Trash", role: .destructive) { vm.moveCanvasesToTrash([canvas.id]) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

private struct NotebookCardsRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let counts: NotebookCardCounts
    let notebookID: String

    @State private var isHovering = false

    private var opensToCheck: Bool { counts.toCheck > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 10) {
                    NotebookStudioBadge(symbolName: MemoryReviewSession.sidebarIcon, hue: NotebookStudioTile.cards.hue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cards")
                            .zoomedSystemFont(size: 12.5)
                            .foregroundStyle(.primary)
                        if let line = counts.line {
                            Text(line)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
            // Dropped on a pane, the notebook's cards open there in Memory.
            .onDrag {
                NotebookOutputDragPayload.provider(for: NotebookOutput(
                    kind: .cards, targetID: notebookID, title: "Cards", sourceIDs: [], date: nil
                ))
            }
            .help(opensToCheck ? "Go through the cards drafted for this notebook's sources" : "Open this notebook's cards in Memory")
            .accessibilityLabel("Cards, \(counts.line ?? "none")")
            .accessibilityIdentifier("notebook.studio.cards")

            // Built only under the pointer, their place held so the counts
            // line never reflows, as an output row's ⋯ is
            // (`NotebookOutputRow`).
            if isHovering {
                iconButton("play", label: "Practice", help: "Practice this notebook's cards, the ones to check among them", action: practice)
                    .accessibilityIdentifier("notebook.studio.cards.practice")
                iconButton("plus.rectangle.on.rectangle", label: "Write Cards", help: "Write a card for each ticked source, one at a time", action: make)
                    .disabled(vm.notebookStudioSourceIDs(notebookID).isEmpty)
                    .accessibilityIdentifier("notebook.studio.cards.make")
            } else {
                HStack(spacing: 2) {
                    iconFace("play")
                    iconFace("plus.rectangle.on.rectangle")
                }
                .hidden()
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button("Open", action: open)
            if opensToCheck {
                OtherWindowMenuItem(.cardsToCheck(notebookID: notebookID))
            } else {
                OtherWindowMenuItem(.memoryReview(notebookID: notebookID))
            }
            Divider()
            Button("Practice", action: practice)
            Button("Write Cards", action: make)
                .disabled(vm.notebookStudioSourceIDs(notebookID).isEmpty)
        }
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            iconFace(symbol)
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .help(help)
        .accessibilityLabel(label)
    }

    private func iconFace(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .zoomedSystemFont(size: 12)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }

    private func open() {
        vm.inWindow(windowState) { vm.openNotebookCards(notebookID: notebookID, counts: counts) }
    }

    private func practice() {
        vm.inWindow(windowState) { vm.startNotebookPractice(notebookID: notebookID) }
    }

    private func make() {
        vm.inWindow(windowState) { vm.requestNotebookWriteCards(notebookID: notebookID) }
    }
}

/// The unread dots of a notebook's outputs on this Mac
/// (`NotebookOutputSeenState`), kept in this Mac's defaults: an output made
/// after the Studio first listed outputs here reads new until it is opened.
@MainActor @Observable
final class NotebookOutputSeenTracker {
    static let shared = NotebookOutputSeenTracker()

    private static let sinceKey = "notebook.outputs.seenSince.v1"
    private static let idsKey = "notebook.outputs.seenIDs.v1"

    private(set) var state: NotebookOutputSeenState

    private init() {
        let defaults = UserDefaults.standard
        let since: Date
        if let stored = defaults.object(forKey: Self.sinceKey) as? Date {
            since = stored
        } else {
            since = Date()
            defaults.set(since, forKey: Self.sinceKey)
        }
        state = NotebookOutputSeenState(since: since, seenIDs: defaults.stringArray(forKey: Self.idsKey) ?? [])
    }

    func isNew(_ output: NotebookOutput) -> Bool { state.isNew(output) }

    func markSeen(_ output: NotebookOutput) {
        guard state.isNew(output) else { return }
        state.markSeen(output.id)
        UserDefaults.standard.set(state.seenIDs, forKey: Self.idsKey)
    }
}

/// One output of the notebook, as Gemini Notebook lists one: its kind's
/// badge, its title, "Briefing · 6 sources · 1d ago", and a dot while it is
/// new on this Mac. A click opens it in a pane of the window; its menu
/// — on the row's ⋯ while the pointer is over it, and on a right-click —
/// opens it, opens it in the other window, renames a record, shows what it
/// was made from (Prompt and Sources: a report's recipe, its sources), and
/// takes a record out of the notebook. A picture's row carries the picture's
/// own actions, which the Artifacts home held until 2026-10-06 — rename,
/// move to another notebook, copy, Show in Finder, trash — and drags out as
/// its file.
private struct NotebookOutputRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let output: NotebookOutput
    let notebookID: String
    /// Opens a picture's sheet, which the column draws; a picture has no pane.
    var openPicture: (String) -> Void = { _ in }
    /// The picture this row is, for its actions; nil for every other kind.
    var pictureGroup: GeneratedImageStore.ImageGroup? = nil
    /// Reads the notebook's pictures again once a picture's action changed one.
    var picturesChanged: () -> Void = {}

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText = ""
    private let seen = NotebookOutputSeenTracker.shared
    /// A reading being written says how far it has come in its row.
    @ObservedObject private var readingWriter = MnemonicReadingCoordinator.shared
    /// A report's recipe, read from its body once per revision
    /// (`StudioViewModel.reportRecipe(_:)`); nil for any other output.
    @State private var reportRecipe: ReportRecipe?

    private var sourcesLabel: String? {
        NotebookOutputs.sourcesLabel(count: output.sourceIDs.count)
    }

    /// A Doc of the open library and its revision, so its recipe is read
    /// again once it is edited; nil for every other output.
    private var recipeKey: String? {
        guard output.kind == .doc,
              let record = vm.artifacts.first(where: { $0.id == output.targetID }) else { return nil }
        return "\(record.id)#\(record.updatedAt.timeIntervalSinceReferenceDate)"
    }

    /// What the menu says the output was made from: a report's own recipe
    /// line ("Made from 6 sources · Briefing · …"), else its sources and the
    /// words it was made to.
    private var recipeLine: String? {
        reportRecipe?.line
            ?? NotebookOutputs.recipe(sourceCount: output.sourceIDs.count, instruction: output.instruction)
    }

    /// The kind the second line leads with: a report's format, else the
    /// output's kind.
    private var kindWord: String {
        guard let format = reportRecipe?.format else { return output.kindLabel }
        return format == .custom ? "Report" : format.label
    }

    /// A Doc, Site or animation of the open library can be renamed here; a
    /// course, a walkthrough or an explainer is named where it lives.
    private var canRename: Bool {
        switch output.kind {
        case .doc, .site, .animation, .mnemonicReading:
            return !vm.isActiveLibraryReadOnly && (output.teamID == nil || output.teamID == vm.activeTeamID)
        // A picture is renamed from its own items (`pictureItems`).
        case .audioOverview, .course, .walkthrough, .explainer, .videoOverview, .cards, .picture, .narration:
            return false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 10) {
                    NotebookStudioBadge(symbolName: output.symbolName, hue: output.kind.hue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.title)
                            .zoomedSystemFont(size: 12.5)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        subtitle
                    }
                    Spacer(minLength: 0)
                    if seen.isNew(output) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .help("New")
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
            .modifier(NotebookOutputDrag(output: output, group: pictureGroup))
            .accessibilityLabel("\(output.kindLabel): \(output.title)")
            .accessibilityValue([seen.isNew(output) ? "New" : nil, sourcesLabel].compactMap { $0 }.joined(separator: ", "))
            .help("Open")

            // The ⋯ is built only under the pointer, the hidden label
            // holding its place. A menu at opacity 0 is still a live
            // control: while an assistive app reads the screen, SwiftUI
            // walks every control in the window for each control an update
            // builds, so a hidden menu per row doubled what opening a
            // notebook cost (2026-10-03). The right-click has the same items.
            if isHovering {
                Menu {
                    menuItems
                } label: {
                    RowMoreActionsLabel()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight()
                .help("Output actions")
                .accessibilityLabel("Actions for \(output.title)")
            } else {
                RowMoreActionsLabel()
                    .hidden()
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu { menuItems }
        .alert("Rename \(output.kindLabel)", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: commitRename)
        }
        .task(id: recipeKey) {
            guard recipeKey != nil else {
                reportRecipe = nil
                return
            }
            reportRecipe = await vm.reportRecipe(output.targetID)
        }
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            if output.kind == .mnemonicReading, let run = readingWriter.run(output.targetID) {
                // While its questions are written, the row says how far it has come.
                Text(run.progress.label)
            } else if output.kind == .cards, let count = output.cardCount {
                Text(NotebookOutputs.cardRunLine(cardCount: count, sourceCount: output.sourceIDs.count))
            } else {
                Text(NotebookOutputs.subtitle(kind: kindWord, sourceCount: output.sourceIDs.count))
            }
            if let date = output.date, vm.showsDateStamp(date) {
                Text("·")
                Text(date, format: .relative(presentation: .named))
            }
        }
        .zoomedSystemFont(size: 11)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open", action: open)
        otherWindowItem
        if canRename {
            Button("Rename…") {
                renameText = output.title
                isRenaming = true
            }
        }
        if let pictureGroup {
            Divider()
            pictureItems(pictureGroup)
        }
        // Gemini's "View prompt and sources": what it was made to and from,
        // each source one click from the Reader beside the chat.
        let sources = output.sourceIDs.compactMap { vm.articlesById[$0] }
        if !sources.isEmpty || recipeLine != nil {
            Menu("Prompt and Sources") {
                if let recipeLine {
                    Text(recipeLine)
                }
                if !sources.isEmpty {
                    if recipeLine != nil { Divider() }
                    ForEach(sources) { source in
                        Button(vm.displayTitle(for: source)) {
                            Task { await vm.selectArticle(source.id, in: windowState, revealingReader: true) }
                        }
                    }
                }
            }
        }
        if vm.canRemoveFromNotebook(output, notebookID: notebookID) {
            Divider()
            Button("Remove from Notebook", role: .destructive) {
                let targetID = output.targetID
                Task { await vm.setArtifactNotebookMembership(targetID, notebookID: notebookID, isMember: false) }
            }
        }
    }

    /// Open in Other Window: where a click opens it, in the other window.
    @ViewBuilder
    private var otherWindowItem: some View {
        switch output.kind {
        case .doc, .site, .animation, .mnemonicReading:
            if let teamID = output.teamID, teamID != vm.activeTeamID {
                OtherWindowMenuItem(.teamArtifact(output.targetID))
            } else {
                OtherWindowMenuItem(.doc(output.targetID))
            }
        case .course:
            OtherWindowMenuItem(.course(output.targetID))
        case .walkthrough, .explainer, .videoOverview, .audioOverview, .narration:
            OtherWindowSourceMenuItem(sourceID: output.kind == .audioOverview
                ? GeneratedAudioOverview.carrierSourceID(artifactID: output.targetID)
                : output.targetID)
        case .cards:
            OtherWindowMenuItem(.cardsToCheck(notebookID: notebookID))
        case .picture:
            // A picture opens in a sheet over this window, not in a pane.
            EmptyView()
        }
    }

    private func open() {
        let output = output
        seen.markSeen(output)
        if output.kind == .picture {
            openPicture(output.targetID)
            return
        }
        Task { await vm.openNotebookOutput(output, in: windowState) }
    }

    private func commitRename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != output.title else { return }
        if let pictureGroup {
            let changed = picturesChanged
            Task {
                if await GeneratedImageActions.rename(pictureGroup, to: title) { changed() }
            }
            return
        }
        let targetID = output.targetID
        Task { await vm.updateArtifact(artifactID: targetID, title: title) }
    }

    /// A picture's own items: Rename…, Add to Notebook ▸ (a picture lives in
    /// one notebook, so adding moves it), Copy Image, Copy Prompt, Show in
    /// Finder and Move to Trash. No notebook items in a team library, whose
    /// pictures are this Mac's own.
    private func pictureItems(_ group: GeneratedImageStore.ImageGroup) -> some View {
        let changed = picturesChanged
        let filing: GeneratedImageNotebookFiling? = vm.activeTeamID == nil
            ? GeneratedImageNotebookFiling(
                livesIn: { vm.notebooksHolding(.filed([group.notebookID])) },
                set: { notebookID in
                    Task {
                        if await GeneratedImageActions.setNotebook(group, to: notebookID) { changed() }
                    }
                }
            )
            : nil
        return GeneratedImageActions.menuItems(
            for: group,
            onRename: { group in
                renameText = group.title ?? ""
                isRenaming = true
            },
            onTrash: { group in
                Task {
                    if await GeneratedImageActions.trash(group) { changed() }
                }
            },
            notebook: filing
        )
    }
}

/// A picture's row drags out as the picture's latest file, prompt and all,
/// into Finder, a Doc or another app. Any other row drags onto a pane of the
/// window, which opens it there (`NotebookOutputDragPayload`); a run still
/// being written opens nothing, so it does not drag.
private struct NotebookOutputDrag: ViewModifier {
    let output: NotebookOutput
    let group: GeneratedImageStore.ImageGroup?

    func body(content: Content) -> some View {
        if let group {
            content.onDrag { GeneratedImageActions.dragProvider(group.latest) }
        } else if output.isPending || output.kind == .picture {
            content
        } else {
            content.onDrag { NotebookOutputDragPayload.provider(for: output) }
        }
    }
}

/// The Notebook menu's Make ▸: the Studio's tiles, for the key window's
/// notebook, in the tiles' order — the Note tile is the menu's own New Note.
/// Each item does what its tile does, in that window.
struct NotebookMakeMenuItems: View {
    let vm: StudioViewModel
    let windowState: StudioWindowState
    let notebookID: String

    var body: some View {
        let takes = vm.notebookTakesMadeThings(notebookID)
        Button("Audio Overview…") {
            NotebookStudioActions.requestAudioOverview(in: windowState)
        }
        .disabled(!takes || vm.audioOverviewOptionsTarget(notebookID: notebookID) == nil)
        Button("Write Cards") {
            vm.inWindow(windowState) { vm.requestNotebookWriteCards(notebookID: notebookID) }
        }
        .disabled(vm.notebookStudioSourceIDs(notebookID).isEmpty)
        // The tile's Practice: the notebook's kept cards and its cards to
        // check, at once (the menu is the first press).
        Button("Practice Cards") {
            vm.inWindow(windowState) { vm.startNotebookPractice(notebookID: notebookID) }
        }
        if ReportEntry.isAvailable {
            Menu("Report") {
                ForEach(ReportEntry.Format.allCases) { format in
                    Button(format.title) {
                        vm.inWindow(windowState) { vm.presentReportOptions(notebookID: notebookID, format: format) }
                    }
                }
            }
            .disabled(!takes)
        }
        Button("Video Overview…") {
            if let notebook = vm.notebook(id: notebookID) {
                NotebookStudioActions.makeVideoOverview(of: notebook, vm: vm)
            }
        }
        .disabled(!takes)
        Button("Add Video File…") {
            if let notebook = vm.notebook(id: notebookID) {
                NotebookStudioActions.importVideoOverviews(into: notebook, vm: vm)
            }
        }
        .disabled(!takes)
        Button("Deep Research…") {
            vm.inWindow(windowState) { vm.requestNotebookDeepResearch(notebookID: notebookID) }
        }
        .disabled(!takes)
        Button("Course…") {
            vm.inWindow(windowState) { vm.requestNotebookCourse(notebookID: notebookID) }
        }
        .disabled(!takes)
        let candidates = vm.notebookExplainerCandidates(notebookID)
        Menu("Explainer") {
            ForEach(candidates) { article in
                Button(vm.displayTitle(for: article)) {
                    NotebookStudioActions.explain(article, in: windowState, vm: vm)
                }
                .disabled(ExplainerGenerationCoordinator.shared.isWriting(article.id))
            }
        }
        .disabled(!takes || candidates.isEmpty)
        if vm.listsCanvases {
            let canvases = vm.canvases(inNotebook: notebookID)
            Menu("Canvas") {
                ForEach(canvases) { canvas in
                    Button(canvas.name) {
                        vm.inWindow(windowState) { vm.openCanvas(canvas.id, in: windowState) }
                    }
                }
                if !canvases.isEmpty { Divider() }
                Button("New Canvas") {
                    vm.inWindow(windowState) { vm.makeAndOpenCanvas(inPageSpace: nil, notebookID: notebookID, in: windowState) }
                }
            }
            .disabled(!takes)
        }
    }
}

/// What the Studio's tiles and the Notebook menu's Make ▸ share and the view
/// model cannot do alone: the audio overview's options sheet, which the
/// window's notebook workspace presents, and the explainer, which its
/// coordinator writes.
@MainActor
enum NotebookStudioActions {
    /// Audio overview's first press: the options sheet, in the window whose
    /// notebook asked (`NotebookWorkspaceView`).
    static func requestAudioOverview(in windowState: StudioWindowState) {
        NotificationCenter.default.post(name: .showNotebookAudioOverviewOptions, object: windowState.id)
    }

    /// Video overview's press: films a short video of the notebook's ticked
    /// papers and articles, under the price question, and files it among the
    /// notebook's sources when it is done (`ExplainerVideoGenerationCoordinator`).
    /// It runs in the background; Videos shows its progress and Cancel.
    static func makeVideoOverview(of notebook: LearningGoalRecord, vm: StudioViewModel) {
        let grounding = vm.notebookStudioSourceIDs(notebook.id)
            .compactMap { vm.articlesById[$0] }
            .filter { ExplainerVideoGeneratorService.groundingSourceTypes.contains($0.sourceType) && !GeneratedExplainer.isSpokenScriptURL($0.url) }
        guard !grounding.isEmpty else {
            vm.showToast("Tick a paper or an article in \u{201C}\(notebook.title)\u{201D} to make a video overview from")
            return
        }
        let request = ExplainerVideoRequest(
            concept: notebook.title,
            groundingSourceIDs: grounding.map(\.id)
        )
        let notebookID = notebook.id
        Task {
            guard await ExplainerVideoGenerationCoordinator.shared.start(request, in: vm, notebookID: notebookID) != nil else { return }
            vm.showToast("Making a video overview of \u{201C}\(notebook.title)\u{201D}. It joins the sources when it is done.")
        }
    }

    /// Add Video File: the file panel for one or more videos, then the
    /// import (`StudioViewModel.importVideoOverviews`).
    static func importVideoOverviews(into notebook: LearningGoalRecord, vm: StudioViewModel) {
        Task {
            let urls = await FilePanel.open { panel in
                panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
                panel.allowsMultipleSelection = true
                panel.message = "Select video overviews to add to \u{201C}\(notebook.title)\u{201D}"
            }
            guard !urls.isEmpty else { return }
            await vm.importVideoOverviews(at: urls, intoNotebook: notebook.id)
        }
    }

    /// Explainer, for one ticked source: its explainer opens in the Reader
    /// when it has one; otherwise it is written, opened, and offered as
    /// audio under the usual cost question (`ExplainerGenerationCoordinator`).
    static func explain(_ article: StudioArticle, in windowState: StudioWindowState, vm: StudioViewModel) {
        Task {
            if await vm.openNotebookExplainer(of: article.id, in: windowState) { return }
            await ExplainerGenerationCoordinator.shared.explain(article, in: vm)
        }
    }
}
#endif
