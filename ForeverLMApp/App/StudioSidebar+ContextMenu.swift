import SwiftUI
import AppKit

private enum SidebarExternalApplicationCache {
    /// `urlForApplication` consults Launch Services. SwiftUI constructs source
    /// context menus eagerly with row bodies, so resolving this once avoids one
    /// synchronous lookup per local source on every sidebar refresh.
    static let visualStudioCodeURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.microsoft.VSCodeInsiders"
    ) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
}

/// "Open in Browser" for a source, shared by every list that right-clicks one.
///
/// Papers are the reason it exists. A paywalled paper's reader can only ever
/// show what the publisher released, so the page carrying the sign-in and the
/// institutional link has to sit one gesture away from the source itself —
/// wherever the source appears.
struct OpenSourceInBrowserButton: View {
    let article: StudioArticle

    var body: some View {
        if let destination = BrowserService.sourceWebDestination(for: article) {
            Button {
                BrowserService.open(destination.url, discoveryOrigin: article.discoveryOrigin)
            } label: {
                Label(
                    title(for: destination),
                    systemImage: destination.isSearch ? "magnifyingglass" : "safari"
                )
            }
        }
    }

    private func title(for destination: BrowserService.SourceWebDestination) -> String {
        if destination.isSearch { return "Search on Google Scholar" }
        return article.isPaywalledPaper ? "Open Publisher Page" : "Open in Browser"
    }
}

/// "Reveal in Finder" for a source whose file is on this Mac, shown at the top
/// level of a source's right-click menu. Nothing is drawn for a source with no
/// local file (a podcast episode, a video, a web page).
struct RevealSourceInFinderButton: View {
    let article: StudioArticle

    var body: some View {
        // Cached-only lookup: the menu is built eagerly with the row body.
        if let path = article.cachedResolvedLocalPath {
            Button {
                // A chapter of an EPUB book kept as one file shows the book's file.
                Task {
                    let target = await Task.detached(priority: .userInitiated) {
                        FileManager.default.fileExists(atPath: path) ? path : (EPUBBookFiles.location(ofPath: path)?.book ?? path)
                    }.value
                    Self.reveal(target)
                }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    @MainActor
    private static func reveal(_ path: String) {
        let fileURL = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        // Finder's first reveal into an iCloud ubiquity container can land on
        // the container root instead of selecting the file (CloudDocs
        // virtual-path translation race). Re-issuing the same reveal is
        // idempotent when the first one worked and corrects it when it didn't.
        if path.contains("Library/Mobile Documents/") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }
}

/// **Mark as Not Watched** for a video that reads as watched, and **Mark as
/// Watched** for one begun but not finished, shared by the sidebar's
/// right-click menu, the Reader's ⋯ and right-click menus and its Continue
/// reading rows, and a lecture video's row on its course's page. A selection
/// of several marks each video the item names.
/// Nothing is drawn for other sources, and Mark as Watched waits for a video
/// to have played once, which is when its length is known.
struct VideoWatchedMenuItems: View {
    let articles: [StudioArticle]

    @Environment(StudioViewModel.self) private var vm

    init(article: StudioArticle) {
        articles = [article]
    }

    init(articles: [StudioArticle]) {
        self.articles = articles
    }

    var body: some View {
        let toFinish = articles.filter { vm.videoCanBeMarkedWatched($0) }.map(\.id)
        let toUnwatch = articles.filter { vm.videoReadsAsWatched($0) }.map(\.id)
        if !toFinish.isEmpty {
            Button {
                Task { await vm.setVideosWatched(toFinish, watched: true) }
            } label: {
                Label(
                    toFinish.count > 1 ? "Mark \(toFinish.count) as Watched" : "Mark as Watched",
                    systemImage: "checkmark.circle"
                )
            }
        }
        if !toUnwatch.isEmpty {
            Button {
                Task { await vm.setVideosWatched(toUnwatch, watched: false) }
            } label: {
                Label(
                    toUnwatch.count > 1 ? "Mark \(toUnwatch.count) as Not Watched" : "Mark as Not Watched",
                    systemImage: "circle"
                )
            }
        }
    }
}

/// The other Studio windows a source can be sent to, and how they are named.
///
/// `openWindow` can only ever make a new window, so without this the only way
/// to get a source into a window that is already open is to drag its row onto
/// that window's Reader. These are the same windows, in the same left-to-right
/// order, that a saved workspace records.
@MainActor
enum StudioOtherWindowTargets {
    struct Target: Identifiable {
        let state: StudioWindowState
        let label: String

        var id: UUID { state.id }
    }

    static func targets(
        excluding current: StudioWindowState?,
        vm: StudioViewModel
    ) -> [Target] {
        targets(among: StudioWindowRegistry.shared.states, excluding: current, vm: vm)
    }

    /// The numbering is over *all* the windows, not the ones that survive the
    /// exclusion: the learner reads "Window 3" off the screen in front of them,
    /// where the window they are acting in is still one of the windows.
    static func targets(
        among windows: [StudioWindowState],
        excluding current: StudioWindowState?,
        vm: StudioViewModel
    ) -> [Target] {
        let ordered = windows.sorted {
            StudioWindowPlacement.onScreenSortKey($0.workspacePlacement)
                < StudioWindowPlacement.onScreenSortKey($1.workspacePlacement)
        }
        return ordered.enumerated().compactMap { index, state in
            guard state !== current else { return nil }
            return Target(state: state, label: label(position: index + 1, state: state, vm: vm))
        }
    }

    /// Numbered by on-screen position rather than by age, because that is the
    /// only property of a window the learner can see from the menu. The source
    /// it currently shows disambiguates two windows on the same display.
    private static func label(
        position: Int,
        state: StudioWindowState,
        vm: StudioViewModel
    ) -> String {
        let name = "Window \(position)"
        guard let sourceID = state.readerSourceID(fallingBackTo: vm.selectedArticleId),
              let article = vm.articlesById[sourceID] else { return name }
        return "\(name) — \(abbreviated(vm.displayTitle(for: article)))"
    }

    private static func abbreviated(_ title: String) -> String {
        let limit = 42
        guard title.count > limit else { return title }
        return title.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Reveals the destination's Reader, focuses that window, and only then
    /// selects — `selectArticle` can await a content fetch, and the window must
    /// come forward on the click rather than whenever the network answers.
    ///
    /// The source moves rather than copies: if the window being acted in was
    /// reading it, that Reader is emptied — the source one Back away — and,
    /// when it was the pane on screen, the pane closes into its neighbour (or,
    /// alone in the center, gives way to Chat). Sending a source to another
    /// window is done to make room here; a pane left behind on "Continue
    /// reading" is the room not being made. A window reading something else
    /// keeps it — from the sidebar, sending a source elsewhere says nothing
    /// about what this window is reading.
    static func open(
        _ articleID: String,
        in target: StudioWindowState,
        from current: StudioWindowState?,
        vm: StudioViewModel
    ) {
        // A window that has not made a local choice yet still renders the legacy
        // global selection, and selecting into another window moves that. So the
        // window being acted in is pinned to what it is showing first: otherwise
        // sending a source to the *other* window would drag this window's Reader
        // along with it. It is pinned here rather than left to `selectArticle`
        // because `bringToFront` may already have made the destination the
        // active window by then. `selectArticle` captures the same thing for the
        // destination, for the same reason.
        current?.pinReaderSelection(to: vm.selectedArticleId)
        if let current, current.readerArticleID == articleID {
            current.readerArticleID = nil
            // Only the pane that was showing the source goes: a Reader parked
            // behind Docs in some pane is not what the learner is looking at,
            // and closing that pane would take Docs with it.
            let readerPane = current.centerTabGroups.groups.first { $0.tabs.contains(.reader) }
            let readerShows = readerPane?.activeTab == .reader
            if readerShows {
                vm.dismissCenterSurface(.reader, in: current)
            }
        }
        vm.activateCenterTab(.reader, in: target)
        StudioWorkspaceWindowCoordinator.shared.bringToFront(target)
        Task { await vm.selectArticle(articleID, in: target) }
    }

    /// The same, for a window that does not exist yet. `openWindow` makes the
    /// window some time after it is asked for, so the source is handed to the
    /// coordinator to open the moment that window registers.
    static func openInNewWindow(
        _ articleID: String,
        from current: StudioWindowState?,
        vm: StudioViewModel,
        openWindow: () -> Void
    ) {
        StudioWorkspaceWindowCoordinator.shared.performInNextRegisteredWindow { target in
            open(articleID, in: target, from: current, vm: vm)
        }
        openWindow()
    }
}

/// A Studio destination that is not a source: a doc, a Notebook, a chat, or one
/// of the panes itself, the Memory pane among them.
///
/// A source is addressed by id and opened with `selectArticle`; everything else
/// is opened by asking the view model to navigate while scoped to a window.
/// `inWindow` is what makes that work across windows — `activeWindowState` and
/// `chatRequestOriginWindow` both answer with the scope, so a navigation made
/// inside one lands in that window rather than the key one.
enum StudioWindowDestination: Equatable {
    case doc(String)
    /// A team's Doc, Site or Animation listed in My Library, which opens only
    /// once its team is the active library (`openTeamArtifact`).
    case teamArtifact(String)
    case notebook(String)
    case chat(String)
    /// A fresh, blank chat.
    case newChat
    /// The Docs pane itself, showing the whole list.
    case docs
    /// The Day tab: the calendar's day.
    case activity
    /// The Activity tab: the day's log and History.
    case activityLog
    /// The Goals tab, showing every Goal in deadline order.
    case goals
    /// The Courses tab, on whichever page the window last showed.
    case courses
    /// One course's page — in a window holding a notebook, in its document
    /// slot. A team's course opens in its team's library.
    case course(String)
    /// The Ideas tab, showing every Idea newest first.
    case ideas
    /// The Sites pane itself, showing every linked site and artifact.
    case sites
    /// The Browser pane.
    case browser
    /// One explainer film, brought forward in the Videos pane.
    case video(sourceID: String)
    /// The Space: every page, site, picture, idea, canvas, list, notebook and
    /// course in one list.
    case artifacts
    /// The Memory pane, where today's card review is started.
    case memory
    /// The full-window Library.
    case library
    /// The Canvas pane, showing the canvas open on this Mac.
    case knowledgeMap
    /// One canvas, opened: it becomes the canvas open on this Mac.
    case canvas(String)
    /// One list of goals or ideas, shown in the Space.
    case spaceList(String)
    /// The Atlas pane, showing the Atlas on screen.
    case atlas
    /// The Memory pane's To Check, over one notebook (its Notebook id) or,
    /// with nil, every notebook.
    case cardsToCheck(notebookID: String?)
    /// The Memory pane's Review, over one notebook (its Notebook id) or, with
    /// nil, every notebook: the notebook's Studio Cards row when nothing
    /// waits to be checked.
    case memoryReview(notebookID: String?)
    /// The Plugins place where it is: its directory, a plugin's page, the
    /// skills or one skill's page.
    case plugins(PluginsPlaceLocation)

    /// What the menu item is opening, for the toast and for the label.
    var noun: String {
        switch self {
        case .doc, .teamArtifact: return "page"
        case .notebook: return "notebook"
        case .chat, .newChat: return "chat"
        case .docs: return "Pages"
        case .activity: return "Day"
        case .activityLog: return "Activity"
        case .goals: return "Goals"
        case .courses: return "Courses"
        case .course: return "course"
        case .ideas: return "Ideas"
        case .sites: return "Sites"
        case .browser: return "Browser"
        case .video: return "video"
        case .artifacts: return "Space"
        case .memory: return "Memory"
        case .library: return "Library"
        case .knowledgeMap: return "Canvas"
        case .canvas: return "canvas"
        case .spaceList: return "list"
        case .atlas: return "Atlas"
        case .cardsToCheck: return "cards to check"
        case .memoryReview: return "Memory"
        case .plugins(let location):
            switch location {
            case .directory: return "Plugins"
            case .plugin(let page): return page.title
            case .skills: return "Skills"
            case .skill: return "skill"
            case .newSkill: return "new skill"
            }
        }
    }

    @MainActor
    func open(in target: StudioWindowState, vm: StudioViewModel) {
        // Front the window first: navigation can await storage, and the window
        // must come forward on the click rather than whenever that returns.
        StudioWorkspaceWindowCoordinator.shared.bringToFront(target)
        vm.inWindow(target) {
            switch self {
            case .doc(let id): vm.revealArtifact(id)
            case .teamArtifact(let id): Task { await vm.openTeamArtifact(id, in: target) }
            case .notebook(let id): vm.openNotebookInReader(id)
            case .chat(let id): vm.requestResumeReviewSession(id)
            case .newChat: vm.requestNewChat()
            case .docs: vm.openNotepadInReader()
            case .activity: vm.openDayPane()
            case .activityLog: vm.openActivityLog()
            case .sites: vm.openSitesInReader()
            case .browser: vm.openBrowserInReader()
            case .video(let sourceID):
                vm.openVideosInReader()
                vm.explainerVideoRevealRequest = ExplainerVideoRevealRequest(sourceID: sourceID)
            case .artifacts: vm.openArtifactsInReader()
            case .goals: vm.openGoalsInReader()
            case .courses: vm.openCoursesInReader()
            case .course(let id): Task { await vm.openCourseInItsLibrary(id, in: target) }
            case .ideas: vm.openIdeasInReader()
            case .memory: vm.openMemoryPane()
            case .library: vm.openLibraryView()
            // Beta features (`BetaFeatures`): the center-tab routes refuse
            // them where they do not show, so a restored window stays put.
            case .knowledgeMap: vm.openKnowledgeMap()
            case .canvas(let id): vm.openCanvas(id)
            case .spaceList(let id): vm.openSpaceList(id, in: target)
            case .atlas: vm.openAtlasPane(in: target)
            case .cardsToCheck(let notebookID):
                vm.openCardsToCheck(scope: notebookID.map { .notebook($0) } ?? .allNotebooks)
            case .memoryReview(let notebookID):
                vm.requestCardReview(scope: notebookID.map { .notebook($0) } ?? .allNotebooks)
            case .plugins(let location): vm.openPluginsPlace(at: location, in: target)
            }
        }
    }
}

/// "Open in Other Window" for a doc, a Notebook, a chat, or a pane — the same
/// item, the same three shapes, and the same behaviour as the
/// source menu below it. Kept separate from that one because a source is opened
/// by selecting it into the destination's Reader, and these are not.
struct OpenStudioDestinationInOtherWindowMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let destination: StudioWindowDestination
    let currentWindowState: StudioWindowState?
    let openNewWindow: () -> Void

    var body: some View {
        let targets = StudioOtherWindowTargets.targets(excluding: currentWindowState, vm: vm)
        if targets.count > 1 {
            Menu {
                ForEach(targets) { target in
                    Button(target.label) { destination.open(in: target.state, vm: vm) }
                }
            } label: {
                label
            }
        } else {
            Button {
                if let only = targets.first {
                    destination.open(in: only.state, vm: vm)
                } else {
                    // The window does not exist yet, and `openWindow` makes it
                    // some time after it is asked for, so the navigation waits
                    // for that window to register.
                    let destination = destination
                    let vm = vm
                    StudioWorkspaceWindowCoordinator.shared.performInNextRegisteredWindow { target in
                        destination.open(in: target, vm: vm)
                    }
                    openNewWindow()
                }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        Label("Open in Other Window", systemImage: "macwindow.on.rectangle")
    }
}

/// The Open in Other Window item for a destination, reading the window it is
/// shown in and `openWindow` from the environment — the form every pane's
/// right-click menu uses. A menu hosted in a SwiftUI root of its own (the
/// Reader's) passes both to `OpenStudioDestinationInOtherWindowMenu` instead.
///
/// Every click that opens something into a pane has this beside it: the click
/// opens here, and this is the one way to open it in another window (product owner,
/// 2026-09-22).
struct OtherWindowMenuItem: View {
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.openWindow) private var openWindow
    let destination: StudioWindowDestination

    init(_ destination: StudioWindowDestination) {
        self.destination = destination
    }

    var body: some View {
        OpenStudioDestinationInOtherWindowMenu(
            destination: destination,
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
    }
}

/// The same for a source, which is opened by selecting it into the other
/// window's Reader.
struct OtherWindowSourceMenuItem: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.openWindow) private var openWindow
    private let article: StudioArticle?
    private let sourceID: String?

    init(_ article: StudioArticle) {
        self.article = article
        self.sourceID = nil
    }

    /// A source known by id, resolved when the menu is drawn; nothing when
    /// the library no longer holds it.
    init(sourceID: String) {
        self.article = nil
        self.sourceID = sourceID
    }

    var body: some View {
        if let resolved = article ?? sourceID.flatMap({ vm.articlesById[$0] }) {
            OpenSourceInOtherWindowMenu(
                article: resolved,
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
        }
    }
}

/// Open in Other Window for a control that opens one of several sources: a
/// submenu naming each, which sends the chosen one to the other window — the
/// first other window by on-screen order when there are several, or a new one
/// when this is the only window.
struct OtherWindowSourcesMenu: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.openWindow) private var openWindow
    let sourceIDs: [String]
    let title: (String) -> String

    var body: some View {
        let articles = sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty {
            Menu {
                ForEach(articles) { article in
                    Button(title(article.id)) { send(article) }
                }
            } label: {
                Label("Open in Other Window", systemImage: "macwindow.on.rectangle")
            }
        }
    }

    private func send(_ article: StudioArticle) {
        if let target = StudioOtherWindowTargets.targets(excluding: windowState, vm: vm).first {
            StudioOtherWindowTargets.open(article.id, in: target.state, from: windowState, vm: vm)
        } else {
            StudioOtherWindowTargets.openInNewWindow(
                article.id,
                from: windowState,
                vm: vm,
                openWindow: { openWindow(id: "studio") }
            )
        }
    }
}

extension View {
    /// A right-click menu holding only Open in Other Window, for a control
    /// that opens `destination` on click and has no menu of its own. Nil adds
    /// no menu at all, so a menu applied around this one still shows.
    @ViewBuilder
    func opensInOtherWindow(_ destination: StudioWindowDestination?) -> some View {
        if let destination {
            contextMenu { OtherWindowMenuItem(destination) }
        } else {
            self
        }
    }

    /// The same for a control that opens a source.
    @ViewBuilder
    func opensInOtherWindow(_ article: StudioArticle?) -> some View {
        if let article {
            contextMenu { OtherWindowSourceMenuItem(article) }
        } else {
            self
        }
    }

    /// The same for a control that knows its source only by id.
    @ViewBuilder
    func opensInOtherWindow(sourceID: String?) -> some View {
        if let sourceID {
            contextMenu { OtherWindowSourceMenuItem(sourceID: sourceID) }
        } else {
            self
        }
    }
}

/// "Open in Other Window" for a source, shared by the sidebar's right-click menu
/// and the Reader's own actions. One item when there is exactly one other Studio
/// window, a submenu naming each when there are several, and — when this is the
/// only window — one item that opens a second window and puts the source in it.
/// The same action every time: the source ends up reading in the other window,
/// whether or not that window had to be made first.
///
/// `openNewWindow` is the caller's `openWindow(id: "studio")`. It is passed in
/// rather than read from the environment because the Reader's menu is hosted
/// in a SwiftUI root of its own, where the scene's `openWindow` is not present.
struct OpenSourceInOtherWindowMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    let currentWindowState: StudioWindowState?
    let openNewWindow: () -> Void

    var body: some View {
        let targets = StudioOtherWindowTargets.targets(excluding: currentWindowState, vm: vm)
        if targets.isEmpty {
            Button {
                StudioOtherWindowTargets.openInNewWindow(
                    article.id,
                    from: currentWindowState,
                    vm: vm,
                    openWindow: openNewWindow
                )
            } label: {
                Label("Open in Other Window", systemImage: "macwindow.on.rectangle")
            }
        } else if targets.count == 1, let only = targets.first {
            Button {
                StudioOtherWindowTargets.open(
                    article.id,
                    in: only.state,
                    from: currentWindowState,
                    vm: vm
                )
            } label: {
                Label("Open in Other Window", systemImage: "macwindow.on.rectangle")
            }
        } else if targets.count > 1 {
            Menu {
                ForEach(targets) { target in
                    Button(target.label) {
                        StudioOtherWindowTargets.open(
                            article.id,
                            in: target.state,
                            from: currentWindowState,
                            vm: vm
                        )
                    }
                }
            } label: {
                Label("Open in Other Window", systemImage: "macwindow.on.rectangle")
            }
        }
    }
}

extension StudioSidebar {
    // MARK: - Article Context Menu

    @ViewBuilder
    func articleContextMenu(
        _ article: StudioArticle,
        selectedArticleIDs: Set<String>? = nil
    ) -> some View {
        // When multiple sources are selected and this source is in the selection,
        // apply collection actions to the whole selection.
        let effectiveSelection = selectedArticleIDs ?? windowState.sidebarSelectedSourceIDs
        let usesMultiSelection = effectiveSelection.contains(article.id)
            && effectiveSelection.count > 1
        let selectedArticles: [StudioArticle] = if usesMultiSelection {
            windowVM.inWindow { $0.sourceIDsInCurrentDisplayOrder(effectiveSelection) }.compactMap { id in
                vm.articlesById[id]
            }
        } else {
            [article]
        }
        let selectedIds = selectedArticles.map(\.id)
        let selectedPaywalledIds = selectedArticles.filter(\.hasPaywallMarker).map(\.id)
        let selectedReadTrackable = selectedArticles.filter(\.cachedSupportsReadTracking)
        let selectedReadTrackableIds = selectedReadTrackable.map(\.id)
        let selectedUnreadIds = selectedReadTrackable.filter { !$0.isRead }.map(\.id)
        let supportsPaywall = article.sourceType == .article
            || article.sourceType == .paper
            || article.sourceType == .unclassified
        let canRefreshFromWebsite = StudioViewModel.canRefreshArticleFromWebsite(article)

        // The notebook this window works in leads, for the row or the whole
        // selection; a multi-selection can also start a notebook of its own.
        NotebookMenuSection(
            notebook: sidebarNotebook,
            target: .sources(selectedIds),
            newNotebookTitle: NotebookMembershipMenu.newNotebookTitle(sourceCount: selectedIds.count)
        ) {
            createNotebook(with: selectedIds)
        }

        // Two sources or more: one canvas of them, with a chat beside it.
        if usesMultiSelection, vm.listsCanvases {
            Button {
                vm.makeCanvasFromSources(sourceIDs: selectedIds, in: windowState)
            } label: {
                Label("New Canvas from Selection", systemImage: KnowledgeMap.symbolName)
            }
            .help("Set these sources down on a new canvas and open a chat about them beside it")
        }
        // Onto a canvas: the row, or the whole selection.
        KnowledgeMapAddToCanvasMenu(refs: selectedIds.map { "source:\($0)" })

        OpenSourceInOtherWindowMenu(
            article: article,
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )

        OpenSourceInBrowserButton(article: article)

        if !usesMultiSelection {
            RevealSourceInFinderButton(article: article)
        }

        // A lecture or reading listed here opens its course's page too: the
        // course lists it in its place (courses-design.md).
        if !usesMultiSelection {
            let courseIDs = vm.courseIDs(containing: article)
            ForEach(courseIDs, id: \.self) { courseID in
                Button {
                    vm.openCourse(courseID, in: windowState)
                } label: {
                    Label(
                        courseIDs.count == 1 ? "Show in Course" : "Show in \(vm.courseDisplayName(courseID))",
                        systemImage: "graduationcap"
                    )
                }
            }
        }

        // Every notebook holding this source, a click opening it in this
        // window: the Library's rows no longer name them (product owner, 2026-10-03:
        // "that can be upon right click maybe (show all notebooks that this
        // source is used in)").
        if !usesMultiSelection {
            SourceNotebooksMenuSection(rowID: article.id, windowState: windowState)
            // And every canvas holding it, a click opening that canvas at the card.
            KnowledgeMapOnCanvasesSection(ref: "source:\(article.id)", windowState: windowState)
        }

        if canRefreshFromWebsite {
            Button {
                Task { await vm.refreshArticleFromWebsite(article.id) }
            } label: {
                Label(
                    vm.contentFetchInFlight.contains(article.id)
                        ? "Refreshing from Website…"
                        : "Refresh from Website",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(vm.contentFetchInFlight.contains(article.id))
        }

        // Meeting sessions that have a recording but no transcript. Same job the
        // reader's "Get transcript" button starts, reachable without opening the
        // recording first — and it follows a multi-selection, so a run of
        // sessions can be queued in one gesture.
        let untranscribedMeetingIds = selectedIds.filter { vm.meetingSessionNeedsTranscript($0) }
        // A session in flight still has no transcript artifact, so it is in the
        // list above too — the running ones come out here, leaving only what a
        // click would actually start.
        let startableMeetingIds = untranscribedMeetingIds.filter {
            !vm.transcribingMeetingSourceIDs.contains($0)
        }
        if !untranscribedMeetingIds.isEmpty {
            Button {
                Task { await vm.transcribeMeetingSessions(startableMeetingIds) }
            } label: {
                Label(
                    startableMeetingIds.isEmpty
                        ? "Getting Transcript…"
                        : (startableMeetingIds.count > 1
                            ? "Get Transcripts (\(startableMeetingIds.count))"
                            : "Get Transcript"),
                    systemImage: "text.bubble"
                )
            }
            .disabled(startableMeetingIds.isEmpty)
            .help("Transcribe this recording on-device")
        }

        if ArticleSpeechContent.canAttemptRead(article) {
            Button {
                Task {
                    let result = await articleSpeech.generateAudio(article: article)
                    switch result {
                    case .started:
                        vm.showToast("Generating audio for \(vm.displayTitle(for: article))")
                    case .alreadyGenerating:
                        vm.showToast("Audio generation is already in progress")
                    case .alreadyReady:
                        vm.showToast("Audio is already ready")
                    case .cancelled:
                        break
                    case .failed(let message):
                        vm.showToast(message)
                    case .needsCostApproval, .unsupportedLanguage:
                        // Interactive requests answer both questions with alerts
                        // inside generateAudio; these only come back headless.
                        break
                    }
                }
            } label: {
                Label(
                    articleSpeech.backgroundGenerationSourceIDs.contains(article.id)
                        ? "Generating Audio…"
                        : "Generate Audio",
                    systemImage: "waveform.badge.plus"
                )
            }
            .disabled(articleSpeech.backgroundGenerationSourceIDs.contains(article.id))

            // The row's trash shows only under the pointer (2026-10-06), so
            // its action is here too, as in the Reader's ⋯. One file stat,
            // made when the menu opens: this menu is built on request, not
            // with the rows.
            if ArticleSpeechAudioCache.hasCachedMarker(sourceID: article.id) {
                Button(role: .destructive) {
                    ArticleSpeechCacheDeletion.confirm(sourceID: article.id, speech: articleSpeech)
                } label: {
                    Label("Delete Cached Audio", systemImage: "trash")
                }
            }
        }

        // The source's card verdicts (docs/memory-design.md, "Cards for
        // every source"), the same two the wide row shows under the pointer:
        // Write Card for the row, or Write Cards for the whole selection one
        // source after another (`requestWriteCards`) — and Not
        // Worth Keeping for the row, which removes it with Undo. Only for
        // sources that can have cards.
        let cardStates = selectedIds.compactMap { vm.sourceCardCoverage.statesByID[$0] }
        if cardStates.count == selectedIds.count, !cardStates.isEmpty {
            Button {
                let ids = selectedIds
                let notebookID = sidebarNotebook?.notebookID
                windowVM.inWindow { $0.requestWriteCards(notebookID: notebookID, sourceIDs: ids) }
            } label: {
                Label(
                    selectedIds.count > 1 ? "Write Cards" : (cardStates.first?.makeCardsTitle ?? "Write Card"),
                    systemImage: MemoryReviewSession.sidebarIcon
                )
            }
            .help(selectedIds.count > 1 ? "Write a card for each of these sources, one at a time" : "Write this source's card beside it")
            if !usesMultiSelection {
                Button(role: .destructive) {
                    Task { await vm.removeArticle(id: article.id) }
                } label: {
                    Label("Not Worth Keeping", systemImage: "xmark.bin")
                }
                .help("Remove this source from the library, with Undo")
            }
        }

        // Walk Through / Write Walkthrough / Remove Walkthrough, shared with
        // the reader's ⋯ menu. Gated on its own: a book chapter has no
        // explainer and still has a walkthrough.
        WalkthroughMenuItems(article: article)
        if GeneratedExplainer.canExplain(article) {
            // Open / Generate / Rewrite / Cancel Writing, shared with the
            // reader's ⋯ menu.
            ExplainerMenuItems(article: article, windowState: windowState)
            // Opens the Videos pane's composer with this source filled in; the
            // price is asked there, and the film lands under Videos.
            Button {
                vm.openVideosInReader()
                vm.explainerVideoComposeRequest = ExplainerVideoComposeRequest(
                    concept: GeneratedExplainerVideo.concept(forSourceTitled: vm.displayTitle(for: article)),
                    sourceID: article.id
                )
            } label: {
                Label("Generate Explainer Video…", systemImage: "film")
            }
            .help("Storyboard and film a short explainer video about this source")
            // Opens a chat with this source in context and the request typed:
            // the chat draws the mechanism as code that plays and saves it
            // under Animations, linked to the source (docs/animations-design.md).
            Button {
                vm.requestAnimationChat(sourceID: article.id)
            } label: {
                Label("Animate…", systemImage: ArtifactKind.animation.symbolName)
            }
            .help("Ask the chat for an animation of how something in this source works")
            // The animations already drawn from this source, each opening in
            // the Animations pane.
            let animations = vm.artifacts.filter { $0.isAnimation && !$0.isHidden && $0.sourceIDs.contains(article.id) }
            if !animations.isEmpty {
                Menu {
                    ForEach(animations.sorted { $0.updatedAt > $1.updatedAt }) { animation in
                        Button(animation.title) { vm.revealArtifact(animation.id) }
                    }
                } label: {
                    Label("Animations (\(animations.count))", systemImage: ArtifactKind.animation.symbolName)
                }
            }
        }

        // The artifacts this source is linked to — Docs grounded on it or
        // citing it, sites and animations naming it — each opening on
        // selection; absent when nothing links to it.
        LinkedInMenuItems(article: article, windowState: windowState)

        Divider()

        if !selectedReadTrackableIds.isEmpty {
            let marksRead = !selectedUnreadIds.isEmpty
            let targetIDs = marksRead ? selectedUnreadIds : selectedReadTrackableIds
            let statusLabel = marksRead ? "Read" : "Unread"
            Button {
                Task {
                    for id in targetIDs {
                        await vm.setArticleRead(id, read: marksRead)
                    }
                }
            } label: {
                Label(
                    targetIDs.count > 1
                        ? "Mark \(targetIDs.count) as \(statusLabel)"
                        : "Mark as \(statusLabel)",
                    systemImage: marksRead ? "checkmark.circle" : "circle"
                )
            }
        }

        VideoWatchedMenuItems(articles: selectedArticles)

        Button {
            Task {
                await vm.recordExternalSourceCompletions(
                    sourceIDs: selectedIds,
                    kind: .listening
                )
            }
        } label: {
            Label(
                selectedIds.count > 1
                    ? "Log \(selectedIds.count) as Listened"
                    : "Log as Listened",
                systemImage: "headphones"
            )
        }

        if supportsPaywall {
            if selectedPaywalledIds.isEmpty {
                Button {
                    Task {
                        for selected in selectedArticles {
                            await vm.markPaywalled(selected)
                        }
                    }
                } label: {
                    Label(selectedIds.count > 1
                          ? "Mark \(selectedIds.count) as Paywalled"
                          : "Mark as Paywalled",
                          systemImage: "lock.doc")
                }
            } else {
                Button {
                    Task { await vm.clearPaywalledStatus(for: selectedPaywalledIds) }
                } label: {
                    Label(selectedPaywalledIds.count > 1
                          ? "Clear Paywall Status for \(selectedPaywalledIds.count)"
                          : "Clear Paywall Status",
                          systemImage: "lock.open")
                }
            }
        }

        // Paper content-acquisition steps live at the top level, not under "More":
        // for a paper without a PDF these are the primary actions on the source.
        let canTryPaperDownload = article.sourceType == .paper
            && article.cachedResolvedPDFPath == nil
            && article.url.hasPrefix("http")
        let canRetryPaperIngestion = article.sourceType == .paper
            && article.state == .error
            && article.requiresPaperMetadataAI
            && article.cachedResolvedPDFPath != nil
        if canTryPaperDownload {
            Button {
                Task { await vm.tryPaperPDFDownload(for: article.id) }
            } label: {
                Label("Try PDF Download", systemImage: "arrow.down.doc")
            }
            Button {
                Task { await vm.tryPaperPDFDownloadWithAIBrowser(for: article.id) }
            } label: {
                Label("Try with AI Browser", systemImage: "sparkles")
            }
        }
        if canRetryPaperIngestion {
            Button {
                Task { await vm.extractPaperMetadataWithAI(id: article.id) }
            } label: {
                Label("Retry Paper Ingestion", systemImage: "arrow.clockwise")
            }
        }

        if !selectedReadTrackableIds.isEmpty || supportsPaywall || canTryPaperDownload || canRetryPaperIngestion {
            Divider()
        }

        Button {
            Task { await vm.scheduleSources(selectedIds, on: Date()) }
        } label: {
            Label(selectedIds.count > 1
                  ? "Schedule \(selectedIds.count) for Today"
                  : "Schedule for Today",
                  systemImage: "calendar.badge.plus")
        }

        Menu {
            sourceAddMenu(selectedIds: selectedIds)
        } label: {
            Label(selectedIds.count > 1
                  ? "Add \(selectedIds.count) to…"
                  : "Add to…",
                  systemImage: "folder.badge.plus")
        }

        let sessionCount = vm.linkedReviewSessions(for: article.id).count
        if sessionCount > 0 {
            Button {
                vm.showReviewSessionsForSource(article.id)
            } label: {
                Label("Review Sessions (\(sessionCount))", systemImage: "brain.head.profile")
            }
        }

        Divider()

        // One title per line when several rows are selected, in display order.
        Button {
            let titles = selectedArticles.map { vm.displayTitle(for: $0) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(titles.joined(separator: "\n"), forType: .string)
            vm.showToast(titles.count > 1 ? "Copied \(titles.count) titles" : "Copied title")
        } label: {
            Label(selectedIds.count > 1 ? "Copy \(selectedIds.count) Titles" : "Copy Title",
                  systemImage: "doc.on.doc")
        }

        Button {
            SourceDetailsEditRequest.post(sourceID: article.id, windowID: windowState.id)
        } label: {
            Label("Edit Details…", systemImage: "pencil")
        }

        Menu {
            sourceMoreMenu(article)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }

        Divider()

        // Hide is its own item, for any source: an episode, a paper, an article,
        // a video. It used to sit only behind Remove…'s confirmation, which reads
        // as deletion, so hiding one episode looked impossible from the row.
        Button {
            Task { await vm.hideSources(selectedIds) }
        } label: {
            Label(selectedIds.count > 1 ? "Hide \(selectedIds.count) Sources" : "Hide",
                  systemImage: "eye.slash")
        }
        .help("Take this off the sources list. It stays in your knowledge for chat, search and reviews, and in Hidden Items.")

        Button(role: .destructive) {
            requestSourceRemoval(Set(selectedIds))
        } label: {
            Label(selectedIds.count > 1 ? "Remove \(selectedIds.count) Sources…" : "Remove…",
                  systemImage: "trash")
        }
    }

    @ViewBuilder
    private func sourceAddMenu(selectedIds: [String]) -> some View {
        Button {
            Task { await vm.scheduleSources(selectedIds) }
        } label: {
            Label("Schedule", systemImage: "calendar")
        }

        let notebooks = vm.notebooks
        Menu {
            ForEach(notebooks) { notebook in
                Button {
                    Task {
                        _ = await vm.addSourcesToNotebookContext(selectedIds, notebookID: notebook.id)
                    }
                } label: {
                    if notebook.id == vm.activeNotebookId {
                        Label(notebook.title, systemImage: "checkmark")
                    } else {
                        Text(notebook.title)
                    }
                }
            }
            if !notebooks.isEmpty { Divider() }
            Button {
                createNotebook(with: selectedIds)
            } label: {
                Label("New Notebook", systemImage: "plus")
            }
        } label: {
            Label("Add to Notebook", systemImage: "folder.badge.plus")
        }

        // Copies the selection into a team; the rows here stay where they are.
        // A team library lists the learner's own sources too, and those can
        // still be shared from there.
        ShareWithTeamMenu(
            title: "Team",
            systemImage: "person.2",
            offeredInTeamLibrary: selectedIds.contains { vm.articlesById[$0]?.teamID == nil }
        ) { teamID in
            Task { await vm.shareSources(selectedIds, withTeam: teamID) }
        }

        // Puts the selection on a teammate's Assignments board — a child's,
        // in a family (docs/family-design.md).
        AssignToMemberMenu { member in
            Task { await vm.assign(sourceIDs: Array(selectedIds), to: member) }
        }

        // New courses come from YouTube playlist import; this menu only files
        // the selected sources into an existing course.
        let courseNames = vm.shownCourseGroupNames
        if !courseNames.isEmpty {
            Menu {
                ForEach(courseNames, id: \.self) { name in
                    Button(vm.courseDisplayName(name)) {
                        Task {
                            for id in selectedIds {
                                await vm.addArticleToCourse(articleId: id, courseName: name)
                            }
                        }
                    }
                }
            } label: {
                Label("Course", systemImage: "graduationcap")
            }
        }
    }

    @ViewBuilder
    private func sourceMoreMenu(_ article: StudioArticle) -> some View {
        let st = article.sourceType
        let hasExternalOpenActions = vm.cachedOriginalEPUBURL(for: article) != nil
            || article.cachedResolvedLocalPath != nil
        // Try PDF Download / Try with AI Browser are promoted to the top level of
        // the context menu, so they intentionally do not appear here.
        let canAttachArticleText = (st == .article || st == .unclassified)
            && (article.hasPaywallMarker || article.state == .error)
        let canAttachPaperPDF = st == .paper
            && (article.hasPaywallMarker || article.state == .error)
        // A paper with its own PDF can take the journal's supplementary file
        // after its pages. Read off the stored path, never the disk: this menu
        // is built with the row.
        let canAddSupplement = st == .paper && !canAttachPaperPDF
            && (article.localFilePath?.lowercased().hasSuffix(".pdf") ?? false)
        let hasSourceActions = canAttachArticleText
            || canAttachPaperPDF
            || canAddSupplement
            || st == .video
            || st == .meeting
            || st == .podcast

        // Cached-only lookups: SwiftUI builds this menu eagerly with the row body,
        // so anything that stats an iCloud-backed file here beachballs the app.
        if let epubURL = vm.cachedOriginalEPUBURL(for: article) {
            Button {
                if assistantIntegrationsEnabled, let groupName = article.parentGroup {
                    vm.addSourcesToContext(vm.sourceIDsForGroupInOrder(groupName))
                } else if assistantIntegrationsEnabled {
                    vm.addSourceToContext(article.id)
                }
                openEPUBInAppleBooks(epubURL)
            } label: {
                Label("Open EPUB in Apple Books", systemImage: "book.pages")
            }
        }

        if let path = article.cachedResolvedLocalPath {
            if let vscodeURL = SidebarExternalApplicationCache.visualStudioCodeURL {
                Button {
                    let fileURL = URL(fileURLWithPath: path)
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([fileURL], withApplicationAt: vscodeURL, configuration: config)
                } label: {
                    Label("Open in VS Code", systemImage: "chevronleft.forwardslash.chevronright")
                }
            }
        }

        if hasExternalOpenActions && hasSourceActions {
            Divider()
        }

        // Meetings have slides too, now that a recording's frames can be read: the entry
        // follows what the action actually supports rather than naming one provider.
        if StudioViewModel.supportsSlideExtraction(article) {
            Button {
                Task { await vm.extractPapersFromSlides(for: article.id) }
            } label: {
                Label("Extract Papers from Slides", systemImage: "doc.text.magnifyingglass")
            }
        }

        if st == .meeting {
            Button {
                Task { await vm.extractMentionedPapersFromMeeting(for: article.id) }
            } label: {
                Label("Find Mentioned Papers", systemImage: "doc.text.magnifyingglass")
            }
        }

        if StudioViewModel.supportsReferenceExtraction(article) {
            Button {
                Task { await vm.extractCitedPapersFromReferences(for: article.id) }
            } label: {
                Label("Find Cited Papers", systemImage: "text.quote")
            }
        }

        // An article's counterpart to a paper's reference list: the pages, papers, videos
        // and episodes its links point at, read from the archived page.
        if StudioViewModel.supportsLinkDiscovery(article) {
            Button {
                Task { await vm.discoverLinkedSources(for: article.id) }
            } label: {
                Label("Find Linked Sources", systemImage: "link")
            }
        }

        if canAttachArticleText {
            Button {
                Task {
                    let urls = await FilePanel.open { panel in
                        panel.allowedContentTypes = [.plainText, .html]
                        panel.message = "Select a text file with the article content"
                    }
                    guard let url = urls.first else { return }
                    await vm.attachTextFile(to: article.id, filePath: url.path)
                }
            } label: {
                Label("Attach Text File…", systemImage: "doc.badge.plus")
            }
            // The PDF the learner downloaded past the publisher's check: it
            // becomes the article's document, and the article stays one.
            Button {
                Task {
                    let urls = await FilePanel.open { panel in
                        panel.allowedContentTypes = [.pdf]
                        panel.message = "Select the PDF of this article"
                    }
                    guard let url = urls.first else { return }
                    do {
                        try await vm.attachDocumentPDF(to: article.id, pdfURL: url)
                        vm.showToast("PDF attached")
                    } catch {
                        vm.showToast("Could not attach PDF: \(error.localizedDescription)")
                    }
                }
            } label: {
                Label("Attach PDF File…", systemImage: "doc.badge.plus")
            }
        }

        if canAttachPaperPDF {
            Button {
                Task {
                    let urls = await FilePanel.open { panel in
                        panel.allowedContentTypes = [.pdf]
                        panel.message = "Select the PDF for this paper"
                    }
                    guard let url = urls.first else { return }
                    do {
                        try await vm.attachPDF(to: article.id, pdfURL: url)
                    } catch {
                        vm.showToast("Could not attach PDF: \(error.localizedDescription)")
                    }
                }
            } label: {
                Label("Attach PDF File…", systemImage: "doc.badge.plus")
            }
            Button {
                alertText = ""
                activeAlert = .pdfURL(article.id)
            } label: {
                Label("Attach PDF from URL…", systemImage: "link.badge.plus")
            }
        }

        if canAddSupplement {
            Button {
                Task {
                    let urls = await FilePanel.open { panel in
                        panel.allowedContentTypes = [.pdf]
                        panel.message = "Select the journal's supplementary PDF for this paper"
                    }
                    guard let url = urls.first else { return }
                    do {
                        let outcome = try await vm.attachSupplementaryPDF(to: article.id, pdfURL: url)
                        vm.showToast("Supplement added as pages \(outcome.articlePageCount + 1)–\(outcome.articlePageCount + outcome.addedPageCount)")
                    } catch {
                        vm.showToast("Could not add supplement: \(error.localizedDescription)")
                    }
                }
            } label: {
                Label("Add Supplementary PDF…", systemImage: "doc.on.doc")
            }
            .help("Appends the journal's supplementary file after this paper's pages, so its figures can be shown and explained.")
        }

        // Keyed off the recording link rather than the source type: a Zoom
        // recording is a meeting session now, and these three actions are the
        // ones that reach Zoom for it.
        if ZoomRecordingService.isZoomRecordingURL(article.url) {
            Button {
                Task { await vm.fetchZoomTranscript(for: article.id) }
            } label: {
                Label("Get Transcript", systemImage: "captions.bubble")
            }
            Button {
                alertText = ""
                activeAlert = .zoomPasscode(article.id)
            } label: {
                Label("Enter Zoom Passcode…", systemImage: "key")
            }
            Button {
                Task { await vm.forgetZoomPasscode(for: article.id) }
            } label: {
                Label("Forget Saved Passcode", systemImage: "key.slash")
            }
        } else if st == .video {
            Button {
                Task { await vm.fetchYouTubeTranscript(for: article.id, userInitiated: true) }
            } label: {
                Label("Get Transcript", systemImage: "captions.bubble")
            }
            if (article.wordCount ?? 0) > 0 {
                Button {
                    Task { await vm.reformatYouTubeTranscript(for: article.id) }
                } label: {
                    Label("Reformat Transcript", systemImage: "text.alignleft")
                }
            }
            if let channel = vm.videoChannelName(for: article) {
                Button {
                    Task { await vm.setYouTubeChannelHidden(channel, hidden: true) }
                } label: {
                    Label("Hide \(channel)", systemImage: "eye.slash")
                }
                .help("Hides every video from this channel and keeps them out of chat, search and reviews. Unhide one video from Hidden Items to bring it back.")
            }
        }

        if st == .podcast {
            if article.discoveryOrigin == .applePodcasts {
                let _ = vm.followedPodcastShowsVersion
                if vm.isPodcastShowFollowed(article.domain) {
                    Button {
                        vm.unfollowPodcastShow(article.domain)
                    } label: {
                        Label("Unfollow \(article.domain)", systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        let showName = article.domain
                        Task {
                            guard let count = await vm.followPodcastShow(showName) else {
                                vm.showToast("Following \(showName); couldn’t read the Apple Podcasts library yet")
                                return
                            }
                            vm.showToast(
                                count == 0
                                    ? "Following \(showName); every episode is already in your library"
                                    : "Following \(showName): importing \(count) more episodes"
                            )
                        }
                    } label: {
                        Label("Follow \(article.domain): Import All Episodes", systemImage: "plus.circle")
                    }
                }
                // Blocking steers the same Apple Podcasts import that following
                // does, so it belongs beside it rather than next to Hide, which
                // acts on rows that already exist.
                let _ = vm.blockedPodcastShowsVersion
                if vm.isPodcastShowBlocked(article.domain) {
                    Button {
                        vm.unblockPodcastShow(article.domain)
                    } label: {
                        Label("Import \(article.domain) Again", systemImage: "arrow.clockwise.circle")
                    }
                    .help("Imports this show again from the next pass on. Episodes you removed stay removed.")
                } else {
                    Button {
                        vm.blockPodcastShow(article.domain)
                    } label: {
                        Label("Never Import \(article.domain)", systemImage: "nosign")
                    }
                    .help("Stops episodes of this show from being imported when you play them in Apple Podcasts. Episodes already in your library stay; Remove All takes those too.")
                }
            }
            Button {
                Task { await vm.setPodcastShowHidden(article.domain, hidden: true) }
            } label: {
                Label("Hide \(article.domain)", systemImage: "eye.slash")
            }
            .help("Hides every episode of this show and keeps them out of chat, search and reviews. Unhide one episode from Hidden Items to bring it back.")
            Button(role: .destructive) {
                Task { await vm.removeAllFromPodcast(article.domain) }
            } label: {
                Label("Remove All from \(article.domain)", systemImage: "trash")
            }
            .help("Removes every episode of this show and stops importing it. Undo restores both.")
        }

        if hasExternalOpenActions || hasSourceActions {
            Divider()
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(article.id, forType: .string)
            vm.showToast("Copied source ID")
        } label: {
            Label("Copy Source ID", systemImage: "doc.on.doc")
        }
    }
}
