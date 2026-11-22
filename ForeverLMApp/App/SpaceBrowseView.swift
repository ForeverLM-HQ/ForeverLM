#if os(macOS)
import AppKit
import SwiftUI

/// One thing the Space lists: a page, a linked Google Doc, a site, a mnemonic
/// reading in no notebook, a canvas, a list, a picture, a
/// notebook or a course, listed under All (docs/docs-design.md, "The Space");
/// or a chat, which Home's list alone shows; or one of the learner's spaces
/// while it is in Trash, which Trash alone lists.
struct SpaceItem: Identifiable {
    enum Kind: Equatable {
        case page, googleDoc, site, animation, reading, canvas, goalList, ideaList, image, notebook, course, chat, space
    }

    /// The record's id, or `image:<image id>` for a picture.
    let id: String
    let kind: Kind
    let title: String
    let createdAt: Date
    let updatedAt: Date
    /// The record, for everything but a picture.
    var artifact: ArtifactRecord?
    /// The picture, for a picture.
    var image: GeneratedImageStore.ImageGroup?
    /// The canvas, for a canvas.
    var canvas: KnowledgeMapCanvas?
    /// The list, for a list of goals or ideas.
    var spaceList: SpaceList?
    /// The notebook, for a notebook.
    var notebook: LearningGoalRecord?
    /// The course's id (its group name), for a course.
    var courseID: String?
    /// The chat, for a chat.
    var chat: ReviewSessionRecord?
    /// The space, for one of the learner's spaces in Trash.
    var pageSpace: PageSpace?
    /// Where it lives, for the list's second column: its notebooks, or for a
    /// team's record the team.
    var location: String?
    /// The team whose record this is when it is listed in My Library
    /// (docs/teams-design.md, decision 18); nil for the learner's own.
    var teamName: String?
    /// Every team holding it: the team whose record it is, or the teams
    /// holding a copy of a personal original.
    var teamIDs: Set<String> = []
    var isPublished = false
    /// Where it lives (`NotebookIndexFiling`), for the notebook filter and
    /// Add to Notebook ▸.
    var filing = NotebookIndexFiling()
    /// Whether the open library owns it, so its menu may rename and trash it.
    var isOwnedHere = true

    var isShared: Bool { teamName != nil || !teamIDs.isEmpty }
    /// In Trash: a record archived, a canvas or a list trashed, or a notebook
    /// archived (Trash is the notebooks' archive).
    var isArchived: Bool {
        artifact?.isArchived == true || canvas?.isTrashed == true || spaceList?.isTrashed == true
            || notebook?.isArchived == true || pageSpace != nil
    }
    var isHidden: Bool { artifact?.isHidden == true || chat?.isHidden == true }
    /// What Trash lists: everything archived or trashed. A picture is deleted
    /// from its sheet and never trashed.
    var isInTrash: Bool { isArchived && kind != .image }

    /// Where Open in Other Window takes it: the same place a click does.
    var otherWindowDestination: StudioWindowDestination? {
        if let canvas { return .canvas(canvas.id) }
        if let spaceList { return .spaceList(spaceList.id) }
        if let notebook { return .notebook(notebook.id) }
        if let courseID { return .course(courseID) }
        if let chat { return .chat(chat.id) }
        guard let artifact else { return nil }
        return teamName != nil ? .teamArtifact(artifact.id) : .doc(artifact.id)
    }
}

/// How the Space's lists are cut: every item, the learner's own, what a team
/// has, what is published on foreverlm.com, and what was hidden — ChatGPT's
/// All / Your items / Shared with you, with ForeverLM's two states beside.
enum SpaceScope: String, CaseIterable, Identifiable {
    case all, yours, shared, published, hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .yours: return "Yours"
        case .shared: return "Shared"
        case .published: return "Published"
        case .hidden: return "Hidden"
        }
    }
}

/// The Space list's order. Last activity is the default, as Codex's Space
/// lists by it (product owner, 2026-10-13: "at first it should be a copy of
/// the codex ... functionality"). Date Created (product owner, 2026-09-29: "just
/// do it by creation date and time") stays one choice away; opening a
/// page is a read and never moves it (docs/ui-design.md, "Opening is a read").
enum SpaceSort: String, CaseIterable, Identifiable {
    case created, activity, name

    static let preferenceKey = Prefs.Space.sort.name
    /// The order a Mac that never chose one lists in.
    static let standard: SpaceSort = .activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return "Date Created"
        case .activity: return "Last Activity"
        case .name: return "Name"
        }
    }

    /// The list's date column, named for the order it shows.
    var dateColumnTitle: String {
        switch self {
        case .created, .name: return "Created"
        case .activity: return "Last activity"
        }
    }
}

/// List or grid, as ChatGPT's All offers; this Mac's choice.
enum SpaceLayout: String {
    case list, grid

    static let preferenceKey = Prefs.Space.layout.name
    /// All grouped under its collections' headings (the sort and filter
    /// menu's Group by Collection): this Mac's choice, like the layout.
    static let groupsByCollectionKey = Prefs.Space.groupByCollection.name
}

/// The rows chosen in a Space list, as Codex's Space selects several pages
/// ("Select all", "These # selected pages"; docs/codex-parity-audit.md, item
/// 35): ⌘-click adds or takes away one, ⇧-click takes in the run from the last
/// one chosen, and while anything is chosen a plain click does the same as
/// ⌘-click, so the learner is choosing until they clear it. What is chosen is
/// this list's, never stored.
struct SpaceSelection: Equatable {
    private(set) var ids: Set<String> = []
    /// The row a ⇧-click's run starts from: the last one chosen alone.
    private(set) var anchor: String?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// ⌘-click: chooses `id`, or lets it go; either way it anchors the next run.
    mutating func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
    }

    /// ⇧-click: every row from the anchor to `id` in `order` (the list as it is
    /// drawn) is chosen, beside what was chosen already, as Finder adds a run.
    /// With no anchor in the list, `id` is chosen and anchors the next run.
    mutating func extend(to id: String, in order: [String]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            ids.insert(id)
            anchor = id
            return
        }
        ids.formUnion(order[min(from, to)...max(from, to)])
    }

    /// Select All: every row of the list.
    mutating func selectAll(_ order: [String]) {
        ids = Set(order)
        anchor = order.first
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// What is still on the list: a row gone (trashed, filtered out, moved
    /// elsewhere) is no longer chosen.
    mutating func keep(only shown: Set<String>) {
        ids.formIntersection(shown)
        if let anchor, !shown.contains(anchor) { self.anchor = nil }
    }

    /// The chosen rows in the list's order.
    func ordered(in order: [String]) -> [String] {
        order.filter { ids.contains($0) }
    }
}

/// Every Space item the open library holds, built once a pass.
@MainActor
enum SpaceCatalog {
    static func items(vm: StudioViewModel, images: [GeneratedImageStore.ImageGroup]) -> [SpaceItem] {
        var items: [SpaceItem] = []
        items.reserveCapacity(vm.artifacts.count + images.count)
        for artifact in vm.artifacts {
            // A member's draft opens through Edit on the team copy; an audio
            // overview is its notebook's; a card deck is a source's private
            // drafts. An animation is listed, in a place of its own
            // (`SpaceDestination.animations`).
            guard !TeamContentIdentity.isDraftArtifactID(artifact.id),
                  !vm.isAudioOverview(artifact),
                  !artifact.isCardDeck else { continue }
            // A reading a notebook holds is listed there alone; in Trash it
            // is listed so it can be restored.
            if !artifact.isArchived, vm.isListedOnlyInItsNotebook(artifact) { continue }
            let kind: SpaceItem.Kind
            if artifact.linkedKind == .googleDoc {
                kind = .googleDoc
            } else if artifact.section == .animations {
                kind = .animation
            } else if artifact.section == .sites {
                kind = .site
            } else if artifact.isMnemonicReading {
                kind = .reading
            } else {
                kind = .page
            }
            let teamName = artifact.teamID.map { id in vm.teams.first { $0.id == id }?.name ?? "a team" }
            let filingIDs = NotebookMembership.filingNotebookIDs(of: artifact)
            let notebookNames = filingIDs.compactMap { $0 }.compactMap { vm.notebook(id: $0)?.title }
            items.append(SpaceItem(
                id: artifact.id,
                kind: kind,
                title: artifact.title,
                createdAt: artifact.createdAt,
                updatedAt: artifact.updatedAt,
                artifact: artifact,
                location: teamName ?? (notebookNames.isEmpty ? nil : notebookNames.map { NotebookTitle($0).text }.joined(separator: ", ")),
                teamName: vm.activeTeamID == nil ? teamName : nil,
                teamIDs: vm.artifactTeamIDs[artifact.id] ?? artifact.teamID.map { Set([$0]) } ?? [],
                isPublished: vm.publishedDocStatuses[artifact.id] != nil,
                filing: .filed(filingIDs),
                isOwnedHere: vm.activeTeamID != nil || artifact.teamID == nil
            ))
        }
        // The learner's canvases, where the Space lists them: each its own
        // name and dates, in no notebook and no team.
        for canvas in vm.listedCanvases {
            items.append(SpaceItem(
                id: canvas.id,
                kind: .canvas,
                title: canvas.name,
                createdAt: canvas.createdAt,
                updatedAt: canvas.updatedAt,
                canvas: canvas
            ))
        }
        // The learner's lists of goals and ideas, in no notebook (the
        // column under Notebook stays empty), with the latest change to one
        // of what they hold as their activity.
        for list in vm.listedSpaceLists {
            items.append(SpaceItem(
                id: list.id,
                kind: list.kind == .goals ? .goalList : .ideaList,
                title: list.name,
                createdAt: list.createdAt,
                updatedAt: vm.spaceListContents(list).updatedAt,
                spaceList: list
            ))
        }
        // The notebooks and the courses of the open library (product owner,
        // 2026-10-09: "we need one kind of page with all the notebooks; but
        // perhaps that can just be in spaces"), so All lists them beside the
        // pages. A notebook is dated by the last time the learner worked in
        // it, a course by its first lecture. An archived notebook is listed
        // too, in Trash alone, dated by its last change.
        for goal in vm.notebooks {
            items.append(notebookItem(goal, updatedAt: vm.notebookRecency.lastWorkedAt(goal.id, updatedAt: goal.updatedAt), vm: vm))
        }
        for goal in vm.archivedNotebooks {
            items.append(notebookItem(goal, updatedAt: goal.updatedAt, vm: vm))
        }
        for courseID in vm.shownCourseGroupNames {
            let began = vm.courseLectures(for: courseID).map(\.createdAt).min() ?? Date()
            items.append(SpaceItem(
                id: "course:\(courseID)",
                kind: .course,
                title: vm.courseDisplayName(courseID),
                createdAt: began,
                updatedAt: began,
                courseID: courseID
            ))
        }
        // The learner's spaces in Trash (Codex's Trash holds spaces as
        // pages), dated by when they went there.
        for space in vm.trashedPageSpaces {
            let trashed = vm.pageSpaces.trashedDate(space.id) ?? Date()
            items.append(SpaceItem(
                id: space.id,
                kind: .space,
                title: NotebookTitle(space.name).text,
                createdAt: trashed,
                updatedAt: trashed,
                pageSpace: space
            ))
        }
        for group in images {
            items.append(SpaceItem(
                id: "image:\(group.imageID)",
                kind: .image,
                title: GeneratedImageActions.title(for: group),
                createdAt: group.versions.last?.createdAt ?? group.updatedAt,
                updatedAt: group.updatedAt,
                image: group,
                location: group.notebookID.flatMap { vm.notebook(id: $0) }.map { NotebookTitle($0.title).text },
                filing: .filed([group.notebookID])
            ))
        }
        return items
    }

    /// The chats of the open library, for Home's list (`spaceChats`):
    /// those in a notebook beside those in none, and the hidden ones, which
    /// only its Hidden scope shows. Built only while Chats is on screen, so a
    /// long history is never walked for the other places.
    static func chatItems(vm: StudioViewModel) -> [SpaceItem] {
        // A chat on a Goal is listed under the notebook the Goal draws on,
        // as the rail files it.
        var titles: [String: String] = [:]
        for goal in vm.notebooks + vm.archivedNotebooks {
            titles[goal.id] = NotebookTitle(goal.title).text
        }
        var notebookOfGoal: [String: String] = [:]
        for goal in vm.learningGoals where goal.isGoal {
            if let parent = goal.parentNotebookID, !parent.isEmpty { notebookOfGoal[goal.id] = parent }
        }
        return vm.spaceChats().map { session in
            let notebookID = session.goalID.flatMap { titles[$0] != nil ? $0 : notebookOfGoal[$0] }
            return SpaceItem(
                id: session.id,
                kind: .chat,
                title: session.title.isEmpty ? "Untitled chat" : session.title,
                // A chat keeps no date of its last turn, so it is dated by
                // when it began.
                createdAt: session.createdAt,
                updatedAt: session.createdAt,
                chat: session,
                location: notebookID.flatMap { titles[$0] }.flatMap { $0.isEmpty ? nil : $0 },
                teamIDs: session.teamID.map { Set([$0]) } ?? [],
                filing: .filed([session.goalID]),
                // A team's snapshot is read, never renamed, refiled or deleted.
                isOwnedHere: !session.isTeamSnapshot
            )
        }
    }

    /// A notebook as the Space lists it: its cover or emoji on its colour,
    /// owned here unless its team shared it read-only.
    private static func notebookItem(_ goal: LearningGoalRecord, updatedAt: Date, vm: StudioViewModel) -> SpaceItem {
        let title = NotebookTitle(goal.title).text
        return SpaceItem(
            id: goal.id,
            kind: .notebook,
            title: title.isEmpty ? "Untitled notebook" : title,
            createdAt: goal.createdAt,
            updatedAt: updatedAt,
            notebook: goal,
            filing: .filed([goal.id]),
            isOwnedHere: !vm.isNotebookReadOnly(goal)
        )
    }
}

/// What beside the Space sidebar shows for a place: the place's name, the
/// search and New on one line, the filters and the view controls under it,
/// then the items as a list (ChatGPT's default: Name | Notebook | Created) or
/// a grid of pictures; Images as a grid of pictures always, Trash with
/// Restore and Delete Forever.
struct SpaceBrowseView: View {
    @Environment(StudioViewModel.self) private var vm
    /// The window the list is in, where a canvas opens.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let destination: SpaceDestination
    /// Draws the place's name as a menu of every place: the pane is too
    /// narrow for the sidebar, which has stepped aside.
    let showsPlaceMenu: Bool
    @Binding var searchText: String
    /// Bumped by the sidebar's search: the field takes the focus.
    let searchFocusRequest: Int
    let onSelectPlace: (SpaceDestination) -> Void
    /// Opens a record; pictures open here, in their sheet.
    let onOpen: (ArtifactRecord) -> Void
    let onNewPage: () -> Void
    let onLink: (ArtifactSection) -> Void
    let onNewSpace: () -> Void

    @WindowStorage(Prefs.Space.layout, default: SpaceLayout.list) private var layout: SpaceLayout
    @WindowStorage(Prefs.Space.sort, default: SpaceSort.standard) private var sort: SpaceSort
    @State private var scope: SpaceScope = .all
    @State private var notebookFilter: ArtifactsNotebookFilter = .all
    @State private var images: [GeneratedImageStore.ImageGroup] = []
    @State private var openedImage: GeneratedImageStore.ImageGroup?
    @State private var renaming: SpaceItem?
    @State private var renameDraft = ""
    /// The page Move to Page… is asking a parent for.
    @State private var movingToPage: ArtifactRecord?
    /// The chat Move to Notebook… is asking a notebook for.
    @State private var movingChat: ReviewSessionRecord?
    /// The pages whose subpages the list shows, as their ids joined by commas:
    /// this Mac's own arrangement, like Recents' fold (`space.pagesExpanded`).
    @WindowStorage(Prefs.Space.pagesExpanded) private var expandedPagesRaw
    /// The records Delete Forever or Empty Trash asks about.
    @State private var deletingForever: [String] = []
    /// The list whose Rename… its own name's menu asked for.
    @State private var renamingList: SpaceList?
    @State private var listWidth: CGFloat = 0
    /// All under its collections' headings (`SpaceLayout.groupsByCollectionKey`).
    @WindowStorage(Prefs.Space.groupByCollection) private var groupsByCollection
    /// The question a notebook's menu asked, answered on its row or card.
    @State private var notebookDialog: SpaceNotebookDialog?
    /// The chat Delete… asks about.
    @State private var deletingChat: SpaceItem?
    /// The name a collection is asked for: New Collection… under a notebook's
    /// Add to Collection ▸, or a heading's Rename Collection….
    @State private var collectionNameRequest: NotebookCollectionNameRequest?
    /// The collection a heading's Delete Collection… asks about.
    @State private var collectionToDelete: NotebookCollection?
    /// The rows chosen for the selection bar (`SpaceSelection`).
    @State private var selection = SpaceSelection()
    /// The pages whose text holds the search's words (`pageIDsMatchingText`),
    /// and the search they answer, so a stale answer finds nothing.
    @State private var textMatches: Set<String> = []
    @State private var textMatchesQuery = ""
    private let previews = ArtifactPreviewStore.shared

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Pictures are this Mac's files, read only where they are listed: in
    /// Images alone. All leaves them out, as a space does, since a talk's
    /// slides saved for a canvas are dozens of pictures that buried the
    /// learner's pages (product owner, 2026-10-13: "why do all these things
    /// show up like this?", then "yes please do that").
    private var listsImages: Bool {
        vm.activeTeamID == nil && destination == .images
    }

    var body: some View {
        // The Board is columns of cards, wider than a place's column, with a
        // head of its own (`SpaceBoardPage`); the Plan is a list of quarters
        // or weeks, not of items (`SpacePlanPage`); every other place is a
        // list of items.
        if destination == .board {
            SpaceBoardPage(searchText: $searchText, searchFocusRequest: searchFocusRequest)
                .environment(\.spacePlaceNamedBySidebar, !showsPlaceMenu)
        } else if destination == .plan {
            SpacePlanPage()
                .environment(\.spacePlaceNamedBySidebar, !showsPlaceMenu)
        } else {
            placeList
        }
    }

    @ViewBuilder
    private var placeList: some View {
        // Chats lists the chats and nothing else, and no other place lists one.
        let all = destination == .chats
            ? SpaceCatalog.chatItems(vm: vm)
            : SpaceCatalog.items(vm: vm, images: listsImages ? images : [])
        let inPlace = all.filter { lists($0) }
        // Read once for the whole list: the notebook filter asks for every
        // notebook's id, and asking per item rebuilt the notebook list for
        // each row on every redraw.
        let filters = SpaceItemFilters(
            scope: effectiveScope,
            notebookFilter: effectiveNotebookFilter,
            query: query,
            textMatches: textMatchesQuery == query ? textMatches : []
        )
        let filtered = sorted(inPlace.filter { passesFilters($0, filters) })
        // Trash lists what was trashed first, then the archived notebooks.
        let shown = destination == .trash ? SpaceCatalog.trashOrder(filtered) : filtered
        let sections = collectionSections(shown)
        let runs = sections ?? [SpaceCollectionSection(collection: nil, items: shown)]
        // The rows as they are drawn, for a ⇧-click's run and Select All.
        let drawn = selectsRows ? drawnOrder(runs) : []
        let selected = selection.isEmpty ? [] : shown.filter { selection.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(inPlace: inPlace, shown: shown)
                if showsCreateStrip {
                    SpaceCreateStrip(spaceID: destination.pageSpaceID, onNewPage: onNewPage)
                        .padding(.top, 18)
                }
                if let list = openList {
                    SpaceListPage(list: list, query: searchText)
                        .padding(.top, 16)
                } else if shown.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, SpacePlaceMetrics.emptyTopPadding)
                        .padding(.bottom, 32)
                } else if destination == .images || (layout == .grid && destination != .chats) {
                    grid(runs, headings: sections != nil, order: drawn, selected: selected)
                        .padding(.top, 18)
                } else {
                    list(runs, headings: sections != nil, order: drawn, selected: selected)
                        .padding(.top, 14)
                }
            }
            .spacePlaceColumn()
            // Room under the last row for the selection bar.
            .padding(.bottom, selected.isEmpty ? 0 : 64)
        }
        .scrollIndicators(.automatic)
        .overlay(alignment: .bottom) {
            if !selected.isEmpty {
                selectionBar(selected, drawn: drawn)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected.isEmpty)
        .task(id: listsImages) { await loadImages() }
        // What pages say, searched off the main actor once the typing rests.
        .task(id: searchesPageText ? query : "") {
            let asked = searchesPageText ? query : ""
            guard !asked.isEmpty else {
                textMatches = []
                textMatchesQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await vm.pageIDsMatchingText(asked)
            guard !Task.isCancelled else { return }
            textMatches = found
            textMatchesQuery = asked
        }
        .onChange(of: destination) { _, _ in
            scope = .all
            selection.clear()
        }
        .onChange(of: drawn) { _, drawn in
            selection.keep(only: Set(drawn))
        }
        .onChange(of: isMissingPlace, initial: true) { _, isMissing in
            if isMissing { onSelectPlace(.all) }
        }
        // A list shown is a Recents entry, as a page opened is; one gone
        // since (deleted here or elsewhere) shows All instead.
        .onChange(of: destination.spaceListID, initial: true) { _, id in
            guard let id else { return }
            if vm.spaceLists.list(id) == nil {
                onSelectPlace(.all)
            } else {
                SpaceRecents.shared.note(.list, id: id)
            }
        }
        .spaceListRenameAlert($renamingList)
        .notebookCollectionNamePrompt($collectionNameRequest)
        .notebookCollectionDeleteConfirmation($collectionToDelete)
        .sheet(item: $movingToPage) { page in
            PageParentPickerSheet(page: page)
        }
        .sheet(item: $movingChat) { chat in
            VStack(alignment: .leading, spacing: 0) {
                Text("Move \u{2018}\(chat.title)\u{2019} to a notebook")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                NotebookPickerPopover(
                    placeholder: "Search notebooks",
                    notebooks: vm.notebooks,
                    checkedIDs: chat.goalID.map { [$0] } ?? [],
                    none: chat.goalID.map { goalID in
                        .init(title: vm.notebook(id: goalID)?.isGoal == true ? "Remove from Goal" : "Remove from Notebook") {
                            Task { await vm.moveReviewSession(chat.id, toNotebook: nil) }
                        }
                    },
                    pick: { picked in
                        if picked.id != chat.goalID {
                            Task { await vm.moveReviewSession(chat.id, toNotebook: picked.id) }
                        }
                    },
                    close: { movingChat = nil }
                )
            }
            .environment(vm)
        }
        .confirmationDialog(
            "Delete ‘\(deletingChat?.title ?? "this chat")’?",
            isPresented: Binding(
                get: { deletingChat != nil },
                set: { if !$0 { deletingChat = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingChat
        ) { item in
            Button("Delete", role: .destructive) {
                StudioAssistantSessionStore.deleteSessionEverywhere(item.id)
                Task { await vm.deleteReviewSessionLink(item.id) }
            }
        } message: { _ in
            Text("The chat and its transcript are deleted. This can’t be undone; Hide keeps it out of the list instead.")
        }
        .sheet(item: $openedImage, onDismiss: {
            Task { await loadImages() }
        }) { group in
            GeneratedImageSheet(group: group) {
                openedImage = nil
                Task {
                    if await GeneratedImageActions.trash(group) {
                        SpaceRecents.shared.forget(.image, id: group.imageID)
                    }
                    await loadImages()
                }
            }
        }
        .alert(
            renaming?.kind == .image ? "Rename Image" : "Rename",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )
        ) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            deletingForever.count == 1
                ? "Delete ‘\(title(ofArtifact: deletingForever[0]))’ forever?"
                : "Delete \(deletingForever.count) items forever?",
            isPresented: Binding(
                get: { !deletingForever.isEmpty },
                set: { if !$0 { deletingForever = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletingForever.count == 1 ? "Delete Forever" : "Delete All Forever", role: .destructive) {
                let ids = deletingForever
                deletingForever = []
                // A canvas and a list are rows, not records: each goes on its
                // own route.
                let canvasIDs = ids.filter { vm.canvases.canvas($0) != nil }
                let listIDs = ids.filter { vm.spaceLists.list($0) != nil }
                let spaceIDs = ids.filter { vm.pageSpaces.isTrashed($0) }
                let artifactIDs = ids.filter { !canvasIDs.contains($0) && !listIDs.contains($0) && !spaceIDs.contains($0) }
                if !canvasIDs.isEmpty { vm.deleteCanvasesForever(canvasIDs) }
                if !listIDs.isEmpty { vm.deleteSpaceListsForever(listIDs) }
                for spaceID in spaceIDs { vm.deletePageSpace(spaceID) }
                guard !artifactIDs.isEmpty else { return }
                Task {
                    await vm.deleteArtifactsForever(artifactIDs)
                    for id in artifactIDs { SpaceRecents.shared.forget(.artifact, id: id) }
                }
            }
        } message: {
            Text("This can’t be undone. A linked Google Doc or site is only unlinked; the page itself is not touched. A list’s goals and ideas are kept, and a space’s pages stay in All.")
        }
    }

    // MARK: Which items

    /// Whether the place lists the item at all, before the filters.
    private func lists(_ item: SpaceItem) -> Bool {
        if destination == .trash { return item.isInTrash }
        guard !item.isArchived else { return false }
        switch destination {
        case .all: return item.kind != .image
        case .notebooks: return item.kind == .notebook
        case .chats: return item.kind == .chat
        case .pages: return item.kind == .page || item.kind == .reading
        case .sites: return item.kind == .site
        case .animations: return item.kind == .animation
        case .canvases: return item.kind == .canvas
        case .images: return item.kind == .image
        case .drive: return item.kind == .googleDoc
        // A list's page draws what it holds (`SpaceListPage`), not items.
        case .trash, .list, .board, .plan: return false
        case .team(let id): return item.teamIDs.contains(id)
        case .space(let id): return item.kind != .image && vm.pageSpaces.spaceID(ofPage: item.id) == id
        }
    }

    /// A space gone since it was chosen — deleted here or on another device —
    /// or chosen before a team's library opened, which has none of the
    /// learner's spaces; or, in Screen record mode, a space, team or list the
    /// take may not show, left chosen from before the mode went on, whose
    /// name the header would say: the list shows All instead.
    private var isMissingPlace: Bool {
        if let id = destination.pageSpaceID {
            if vm.activeTeamID != nil || vm.pageSpaces.space(id) == nil || vm.pageSpaces.isTrashed(id) { return true }
            return vm.isScreenRecordModeActive && !vm.orderedPageSpaces.contains { $0.id == id }
        }
        guard vm.isScreenRecordModeActive else { return false }
        if case .team(let id) = destination {
            return !vm.shownTeams.contains { $0.id == id }
        }
        if let id = destination.spaceListID {
            return !vm.listedSpaceLists.contains { $0.id == id }
        }
        return false
    }

    /// What `passesFilters` asks of every item, read once per pass.
    private struct SpaceItemFilters {
        let scope: SpaceScope
        let notebookFilter: ArtifactsNotebookFilter
        let query: String
        /// The pages whose text holds the search's words.
        var textMatches: Set<String> = []
    }

    /// Whether the place's search reads what pages say as well as names:
    /// wherever pages are listed (Codex's "Search spaces and content").
    private var searchesPageText: Bool {
        switch destination {
        case .all, .pages, .space, .team: return true
        default: return false
        }
    }

    /// The scope, the notebook filter, the hidden rule, the daily-note rule
    /// and the search.
    private func passesFilters(_ item: SpaceItem, _ filters: SpaceItemFilters) -> Bool {
        let effectiveScope = filters.scope
        let effectiveNotebookFilter = filters.notebookFilter
        let query = filters.query
        // A hidden record is off every list but Hidden's; in Trash it is
        // listed so it can be restored or deleted.
        if destination != .trash, item.isHidden != (effectiveScope == .hidden) { return false }
        switch effectiveScope {
        case .all, .hidden: break
        case .yours: if item.teamName != nil { return false }
        case .shared: if !item.isShared { return false }
        case .published: if !item.isPublished { return false }
        }
        if effectiveNotebookFilter != .all,
           !effectiveNotebookFilter.admits(livingIn: vm.notebooksHolding(item.filing)) { return false }
        // An empty daily note is reached by its day; one with writing is listed, and a search finds any.
        if item.kind == .page,
           !NotesGraphDocListing.isListed(id: item.id, title: item.title, createdAt: item.createdAt,
                                          updatedAt: item.updatedAt, searchQuery: query) { return false }
        guard !query.isEmpty else { return true }
        if item.title.localizedCaseInsensitiveContains(query) { return true }
        if item.location?.localizedCaseInsensitiveContains(query) == true { return true }
        // A page is also found by what it says.
        if item.artifact != nil, filters.textMatches.contains(item.id) { return true }
        if let prompt = item.image?.latest.details?.text, prompt.localizedCaseInsensitiveContains(query) { return true }
        // A notebook is also found by what it says about itself, as the
        // Notebooks home's search found it.
        if let goal = item.notebook,
           [goal.summary, goal.description, goal.topic].contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        return false
    }

    /// Whether the Space offers Group by Collection: on All, once the learner
    /// has a collection (which they make from a notebook's Add to Collection ▸).
    private var offersCollectionGrouping: Bool {
        destination == .all && !vm.orderedNotebookCollections.isEmpty
    }

    /// Whether All is drawn under its collections' headings: the choice made,
    /// and no search, which finds a match wherever it sits.
    private var groupsListByCollection: Bool {
        offersCollectionGrouping && groupsByCollection && query.isEmpty
    }

    /// `shown` under each collection's heading while the list is grouped, nil
    /// while it is not.
    private func collectionSections(_ shown: [SpaceItem]) -> [SpaceCollectionSection]? {
        guard groupsListByCollection else { return nil }
        return SpaceCatalog.groupedByCollection(
            shown,
            ordered: vm.orderedNotebookCollections,
            collections: vm.notebookCollections,
            // An empty collection keeps its heading while nothing narrows the list.
            keepsEmpty: effectiveScope == .all && effectiveNotebookFilter == .all
        )
    }

    /// The order as it applies here: a chat keeps no date of its last turn,
    /// so Chats offers Date Created and Name, and Last Activity is Date Created.
    private var effectiveSort: SpaceSort {
        destination == .chats && sort == .activity ? .created : sort
    }

    private var sortOptions: [SpaceSort] {
        destination == .chats ? [.created, .name] : SpaceSort.allCases
    }

    private func sorted(_ items: [SpaceItem]) -> [SpaceItem] {
        items.sorted { lhs, rhs in
            switch effectiveSort {
            case .created where lhs.createdAt != rhs.createdAt:
                return lhs.createdAt > rhs.createdAt
            case .activity where lhs.updatedAt != rhs.updatedAt:
                return lhs.updatedAt > rhs.updatedAt
            case .name:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            default:
                break
            }
            return lhs.id < rhs.id
        }
    }

    /// The scopes the place offers, All always: Yours and Shared only in My
    /// Library with a team to share into; Published only where a page can be;
    /// Hidden only while something is hidden there.
    private func scopes(inPlace: [SpaceItem]) -> [SpaceScope] {
        // A canvas is the learner's own, never shared, published or hidden.
        guard destination != .trash, destination != .images, destination != .canvases,
              destination.spaceListID == nil else { return [.all] }
        var scopes: [SpaceScope] = [.all]
        // The learner's chats are their own; a team's transcripts are in its library.
        if vm.activeTeamID == nil, !vm.teams.isEmpty, !isTeamPlace, destination != .chats {
            scopes += [.yours, .shared]
        }
        if destination == .all || destination == .pages || isTeamPlace || destination.pageSpaceID != nil {
            scopes.append(.published)
        }
        if inPlace.contains(where: \.isHidden) {
            scopes.append(.hidden)
        }
        // All alone too: every place draws the same row, so each list starts
        // at the same height (product owner, 2026-10-12: "this needs to look
        // much more consistent").
        return scopes
    }

    private var isTeamPlace: Bool {
        if case .team = destination { return true }
        return false
    }

    /// The scope as it applies now: one the place does not offer is All.
    private var effectiveScope: SpaceScope {
        switch scope {
        case .yours, .shared:
            return vm.activeTeamID == nil && !vm.teams.isEmpty && !isTeamPlace ? scope : .all
        default:
            return scope
        }
    }

    /// A notebook gone since it was chosen is every notebook again.
    private var effectiveNotebookFilter: ArtifactsNotebookFilter {
        notebookFilter.effective(notebookIDs: Set(vm.notebooks.map(\.id)))
    }

    private func loadImages() async {
        guard listsImages else {
            if !images.isEmpty { images = [] }
            return
        }
        let groups = await GeneratedImageActions.loadDrawn()
        guard !Task.isCancelled else { return }
        if groups != images { images = groups }
    }

    // MARK: Selection

    /// Whether the place's rows can be chosen: every list of things but
    /// Chats (a chat's menu acts on one) and Images (a picture's sheet is
    /// where it is renamed or trashed), and never a list's own page.
    private var selectsRows: Bool {
        destination != .chats && destination != .images && openList == nil
    }

    /// The ids of the rows as they are drawn: a list's rows with their open
    /// subpages, or a grid's cards, section by section.
    private func drawnOrder(_ runs: [SpaceCollectionSection]) -> [String] {
        var seen: Set<String> = []
        let ids = layout == .list
            ? runs.flatMap { listEntries($0.items).map(\.id) }
            : runs.flatMap { $0.items.map(\.id) }
        return ids.filter { seen.insert($0).inserted }
    }

    /// What the chosen rows can have done to them, each act holding only the
    /// rows it applies to: Codex's Move to Space, Pin and Move to Trash, or in
    /// Trash its Restore and Delete Forever.
    private struct SelectionTargets {
        var pages: [ArtifactRecord] = []
        var filedIDs: [String] = []
        var pinIDs: [String] = []
        var trashArtifactIDs: [String] = []
        var trashCanvasIDs: [String] = []
        var trashListIDs: [String] = []
        var archiveNotebookIDs: [String] = []
        var restorable: [SpaceItem] = []
        var deletableIDs: [String] = []

        var trashCount: Int { trashArtifactIDs.count + trashCanvasIDs.count + trashListIDs.count + archiveNotebookIDs.count }
    }

    private func selectionTargets(_ items: [SpaceItem]) -> SelectionTargets {
        var targets = SelectionTargets()
        let ownLibrary = vm.activeTeamID == nil
        for item in items {
            if destination == .trash {
                guard item.isOwnedHere else { continue }
                if restoreAction(for: item) != nil { targets.restorable.append(item) }
                if let id = item.artifact?.id ?? item.canvas?.id ?? item.spaceList?.id ?? item.pageSpace?.id { targets.deletableIDs.append(id) }
                continue
            }
            if let artifact = item.artifact {
                if vm.canFileInPageSpace(artifact) { targets.pages.append(artifact) }
                if ownLibrary, artifact.teamID == nil { targets.pinIDs.append(artifact.id) }
                if item.isOwnedHere { targets.trashArtifactIDs.append(artifact.id) }
            } else if let canvas = item.canvas {
                targets.filedIDs.append(canvas.id)
                targets.pinIDs.append(canvas.id)
                targets.trashCanvasIDs.append(canvas.id)
            } else if let list = item.spaceList {
                targets.filedIDs.append(list.id)
                targets.pinIDs.append(list.id)
                targets.trashListIDs.append(list.id)
            } else if let goal = item.notebook, item.isOwnedHere, !goal.isArchived {
                // Trash is the notebooks' archive.
                targets.archiveNotebookIDs.append(goal.id)
            }
        }
        return targets
    }

    /// The selection's acts, as menu items: on the selection bar and on the
    /// right-click of any chosen row.
    @ViewBuilder
    private func selectionActions(_ items: [SpaceItem]) -> some View {
        let targets = selectionTargets(items)
        if destination == .trash {
            if !targets.restorable.isEmpty {
                Button("Restore \(Self.countLabel(targets.restorable.count))", systemImage: "arrow.uturn.backward") {
                    restore(targets.restorable)
                }
            }
            if !targets.deletableIDs.isEmpty {
                Button("Delete \(Self.countLabel(targets.deletableIDs.count)) Forever…", systemImage: "trash", role: .destructive) {
                    deletingForever = targets.deletableIDs
                }
            }
        } else {
            if !targets.pages.isEmpty || !targets.filedIDs.isEmpty {
                PageSpaceMenu(pages: targets.pages, itemIDs: targets.filedIDs)
            }
            if !targets.pinIDs.isEmpty {
                let allPinned = targets.pinIDs.allSatisfy { vm.isPagePinned($0) }
                Button(allPinned ? "Unpin" : "Pin", systemImage: allPinned ? "pin.slash" : "pin") {
                    for id in targets.pinIDs { vm.setPagePinned(id, pinned: !allPinned) }
                }
            }
            if targets.trashCount > 0 {
                Button("Move \(Self.countLabel(targets.trashCount)) to Trash", systemImage: "trash", role: .destructive) {
                    moveToTrash(targets)
                }
            }
        }
    }

    /// "1 Item", "3 Items": what a bulk act's name counts.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 Item" : "\(count) Items"
    }

    private func moveToTrash(_ targets: SelectionTargets) {
        selection.clear()
        if !targets.trashCanvasIDs.isEmpty { vm.moveCanvasesToTrash(targets.trashCanvasIDs) }
        if !targets.trashListIDs.isEmpty { vm.moveSpaceListsToTrash(targets.trashListIDs) }
        let artifactIDs = targets.trashArtifactIDs
        let notebookIDs = targets.archiveNotebookIDs
        Task {
            if !artifactIDs.isEmpty { await vm.moveArtifactsToTrash(artifactIDs) }
            for id in notebookIDs { await vm.setGoalStatus(goalID: id, status: .archived) }
        }
    }

    private func restore(_ items: [SpaceItem]) {
        selection.clear()
        let canvasIDs = items.compactMap { $0.canvas?.id }
        let listIDs = items.compactMap { $0.spaceList?.id }
        let artifactIDs = items.compactMap { $0.artifact?.id }
        let notebookIDs = items.compactMap { $0.notebook?.id }
        let spaceIDs = items.compactMap { $0.pageSpace?.id }
        if !canvasIDs.isEmpty { vm.restoreCanvases(canvasIDs) }
        if !listIDs.isEmpty { vm.restoreSpaceLists(listIDs) }
        if !spaceIDs.isEmpty { vm.restorePageSpaces(spaceIDs) }
        Task {
            if !artifactIDs.isEmpty { await vm.restoreArtifactsFromTrash(artifactIDs) }
            for id in notebookIDs { await vm.setGoalStatus(goalID: id, status: .active) }
        }
    }

    /// Codex's bar over a list with rows chosen: how many, the acts, Select
    /// All, and × to let them all go.
    private func selectionBar(_ selected: [SpaceItem], drawn: [String]) -> some View {
        HStack(spacing: 4) {
            Text("\(selected.count) selected")
                .zoomedSystemFont(size: 12.5, weight: .semibold)
                .monospacedDigit()
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .textSelection(.disabled)
            Divider().frame(height: 16)
            HStack(spacing: 2) {
                selectionActions(selected)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -4))
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .zoomedSystemFont(size: 12.5, weight: .medium)
            .fixedSize()
            .padding(.horizontal, 6)
            Divider().frame(height: 16)
            if selected.count < drawn.count {
                Button("Select All") { selection.selectAll(drawn) }
                    .buttonStyle(.hoverWash(cornerRadius: 7, inset: -4))
                    .zoomedSystemFont(size: 12.5, weight: .medium)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("space.selection.selectAll")
            }
            Button {
                selection.clear()
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0))
            .help("Clear selection")
            .accessibilityLabel("Clear selection")
            .accessibilityIdentifier("space.selection.clear")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(selected.count) selected")
        .accessibilityIdentifier("space.selection.bar")
    }

    // MARK: Header

    private var placeTitle: String { vm.spacePlaceTitle(destination) }

    /// The list this place shows, while it is there.
    private var openList: SpaceList? {
        destination.spaceListID.flatMap { vm.spaceLists.list($0) }
    }

    /// ChatGPT's Create strip, over All and over a space, where the open
    /// library is the learner's own and nothing is searched for.
    private var showsCreateStrip: Bool {
        (destination == .all || destination.pageSpaceID != nil)
            && vm.activeTeamID == nil && !vm.isActiveLibraryReadOnly && query.isEmpty
    }

    /// Whether the head names the place. Beside the sidebar its lit row
    /// already does, and the tab over the pane says Space or Pages, so All,
    /// Notebooks, Pages and the rest start with their scopes (product owner,
    /// 2026-11-07, of "All" over an All pill under the Space tab). Without the
    /// sidebar the name is the place menu, the way to the other places. A
    /// list, a space and a team keep their names, and Chats, which has no row.
    private var namesPlace: Bool {
        if showsPlaceMenu || openList != nil { return true }
        switch destination {
        case .space, .team, .chats: return true
        default: return false
        }
    }

    private var searchPrompt: String {
        searchesPageText ? "Search names and text" : "Search by name"
    }

    private func header(inPlace: [SpaceItem], shown: [SpaceItem]) -> some View {
        let scopes = scopes(inPlace: inPlace)
        return VStack(alignment: .leading, spacing: 14) {
            if namesPlace {
                SpacePlaceHeader(
                    searchText: $searchText,
                    searchFocusRequest: searchFocusRequest,
                    searchPrompt: searchPrompt
                ) {
                    titleView
                } actions: {
                    primaryActions(shown: shown)
                }
                // The same row on every place, empty or not: the scopes, then
                // sort and filter. A list's page has its own.
                if openList == nil {
                    HStack(spacing: 8) {
                        scopePills(scopes)
                        Spacer(minLength: 8)
                        viewControls
                    }
                }
            } else {
                unnamedHead(scopes: scopes, shown: shown)
            }
            // How long Trash keeps things: until it is emptied, since Trash
            // is the archive (docs/docs-design.md, "The Space as Codex's").
            if destination == .trash {
                Text(SpaceTrashWording.retention)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .accessibilityIdentifier("space.trash.retention")
            }
        }
    }

    /// A head with no name: one row of the scopes, then the search, sort and
    /// filter, and the one action; in a column too narrow for it, the search
    /// and the action over the scopes and the view controls.
    private func unnamedHead(scopes: [SpaceScope], shown: [SpaceItem]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                scopePills(scopes)
                    .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 12)
                placeSearch
                    .frame(width: SpacePlaceMetrics.searchWidth)
                viewControls
                primaryActions(shown: shown)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    placeSearch
                    primaryActions(shown: shown)
                }
                HStack(spacing: 8) {
                    scopePills(scopes)
                    Spacer(minLength: 8)
                    viewControls
                }
            }
        }
    }

    private var placeSearch: some View {
        SpaceSearchField(text: $searchText, prompt: searchPrompt, focusRequest: searchFocusRequest)
    }

    @ViewBuilder
    private var titleView: some View {
        if let list = openList {
            // A list's name is its menu, as a page's is over the page.
            Menu {
                SpaceListMenuItems(list: list, onRename: { renamingList = list })
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: list.kind.symbolName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(SpaceKindStyle.tint(list.kind == .goals ? .goalList : .ideaList))
                    Text(list.name)
                        .font(SpacePlaceMetrics.titleFont)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -2))
            .fixedSize()
            .accessibilityLabel("\(list.name), list options")
            .accessibilityIdentifier("space.list.menu")
        } else if showsPlaceMenu {
            Menu {
                ForEach(SpaceDestination.places(listsCanvases: vm.listsCanvases) + [.trash], id: \.self) { place in
                    Button(place.title, systemImage: place.symbolName) { onSelectPlace(place) }
                }
                if vm.activeTeamID == nil, !vm.orderedPageSpaces.isEmpty || !vm.shownTeams.isEmpty {
                    Section("Spaces") {
                        ForEach(vm.orderedPageSpaces) { space in
                            Button(space.name) { onSelectPlace(.space(space.id)) }
                        }
                        ForEach(vm.shownTeams) { team in
                            Button(team.name) { onSelectPlace(.team(team.id)) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(placeTitle)
                        .font(SpacePlaceMetrics.titleFont)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -2))
            .fixedSize()
            .accessibilityLabel("\(placeTitle), choose a place")
        } else {
            SpacePlaceTitle(title: placeTitle)
        }
    }

    /// The place's one next step, a dark pill named for what the place lists
    /// and with no glyph, as Codex's New is: New ▾ on All and a space, New
    /// Page, Link a Site…, New Notebook, New Chat, New Canvas, Link a Google
    /// Doc… on theirs, Empty Trash in Trash, Invite on a team's space. An
    /// empty place offers the same pill under its line.
    @ViewBuilder
    private func primaryActions(shown: [SpaceItem]) -> some View {
        switch destination {
        case .trash:
            let deletable = shown.filter(\.isOwnedHere).compactMap { $0.artifact?.id ?? $0.canvas?.id ?? $0.spaceList?.id ?? $0.pageSpace?.id }
            if !deletable.isEmpty {
                Button("Empty Trash", role: .destructive) { deletingForever = deletable }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("space.emptyTrash")
            }
        case .drive:
            SpaceDarkPillButton(title: ArtifactSection.docs.linkActionTitle, systemImage: nil, image: nil) {
                onLink(.docs)
            }
            .accessibilityIdentifier("space.linkGoogleDoc")
        case .images, .board, .plan:
            EmptyView()
        case .notebooks:
            // The place lists only notebooks, so its one next step makes
            // one: a page, a list or a canvas made here would not show in it.
            if !vm.isActiveLibraryReadOnly {
                SpaceDarkPillButton(title: "New Notebook", systemImage: nil, image: nil) { newNotebook() }
                    .accessibilityIdentifier("space.newNotebook")
            }
        case .canvases:
            SpaceDarkPillButton(title: "New Canvas", systemImage: nil, image: nil) { newCanvas() }
                .accessibilityIdentifier("space.newCanvas")
        case .chats:
            SpaceDarkPillButton(title: "New Chat", systemImage: nil, image: nil) { newChat() }
                .accessibilityIdentifier("space.newChat")
        case .list:
            if let list = openList, !list.isTrashed {
                SpaceListAddMenu(list: list)
            }
        case .team(let id):
            if let team = vm.teams.first(where: { $0.id == id }) {
                Button("Open Library") { Task { await vm.setActiveTeam(team.id) } }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Switch to \(team.name)’s library")
                SpaceDarkPillButton(title: "Invite", systemImage: nil, image: nil) {
                    TeamSharingService.shared.presentMembers(for: team)
                }
            }
        // Pages and Sites list only pages and sites, so their one next step
        // makes one, as Notebooks' does; New ▾ with every kind stays where
        // every kind is listed.
        case .pages:
            if !vm.isActiveLibraryReadOnly {
                SpaceDarkPillButton(title: "New Page", systemImage: nil, image: nil, action: onNewPage)
                    .accessibilityIdentifier("space.newPage")
            }
        case .sites:
            if !vm.isActiveLibraryReadOnly {
                SpaceDarkPillButton(title: ArtifactSection.sites.linkActionTitle, systemImage: nil, image: nil) { onLink(.sites) }
                    .accessibilityIdentifier("space.linkSite")
            }
        // An animation is drawn in a chat, so the one next step opens one
        // with the request typed, as the Animations pane's button does.
        case .animations:
            if !vm.isActiveLibraryReadOnly {
                SpaceDarkPillButton(title: ArtifactSection.animations.linkActionTitle, systemImage: nil, image: nil) {
                    vm.requestAnimationChat()
                }
                .accessibilityIdentifier("space.animate")
            }
        case .all, .space:
            if !vm.isActiveLibraryReadOnly {
                newMenu
            }
        }
    }

    private var newMenu: some View {
        SpaceDarkPillMenu(title: "New", sections: newMenuSections)
            .accessibilityIdentifier("space.new")
    }

    /// New's rows, in Codex's groups: what you make (Page, then Codex's Create
    /// image), then a space, then a page from a template (Codex's "Start from
    /// template"), then what you link from elsewhere.
    private var newMenuSections: [[SpaceMenuItem]] {
        var make: [SpaceMenuItem] = [
            SpaceMenuItem(id: "space.new.page", title: "Page", systemImage: "doc.text", action: onNewPage),
            SpaceMenuItem(id: "space.new.image", title: "Image", systemImage: "photo") {
                vm.requestImageChat(in: windowState)
            },
        ]
        // The Notebooks home's New notebook, which the Space took over:
        // made at once, named by ForeverLM, and opened in this window.
        if destination == .all {
            make.append(SpaceMenuItem(id: "space.new.notebook", title: "Notebook", systemImage: NotebookGlyph.systemImage) { newNotebook() })
        }
        if vm.listsCanvases {
            make.append(SpaceMenuItem(id: "space.new.canvas", title: "Canvas", systemImage: KnowledgeMap.symbolName) { newCanvas() })
            // The sources selected in the Sources list, on a canvas of their own.
            if let windowState {
                let selected = vm.inWindow(windowState) { vm.sourceIDsInCurrentDisplayOrder(windowState.sidebarSelectedSourceIDs) }
                if !selected.isEmpty {
                    make.append(SpaceMenuItem(id: "space.new.canvasFromSources", title: "Canvas from Selected Sources", systemImage: "square.on.square.dashed") {
                        vm.makeCanvasFromSources(sourceIDs: selected, in: windowState)
                    })
                }
            }
        }
        let space: [SpaceMenuItem] = vm.activeTeamID == nil
            ? [SpaceMenuItem(id: "space.new.space", title: "Space\u{2026}", systemImage: "square.stack", action: onNewSpace)]
            : []
        let spaceID = destination.pageSpaceID
        let templates: [SpaceMenuItem] = SpacePageTemplate.all.map { template in
            SpaceMenuItem(id: "space.new.template.\(template.id)", title: template.title, systemImage: template.systemImage, trailing: "Template") {
                Task { await vm.createPage(from: template, inPageSpace: spaceID, in: windowState) }
            }
        }
        let link: [SpaceMenuItem] = [
            SpaceMenuItem(id: "space.new.linkDoc", title: ArtifactSection.docs.linkActionTitle, systemImage: "link") { onLink(.docs) },
            SpaceMenuItem(id: "space.new.linkSite", title: ArtifactSection.sites.linkActionTitle, systemImage: "globe") { onLink(.sites) },
        ]
        return [make, space, templates, link]
    }

    /// **New ▸ Notebook** on All and **New Notebook** on Notebooks: made at
    /// once, named by ForeverLM, and opened in this window, where an empty
    /// notebook leads with Add sources.
    private func newNotebook() {
        vm.makeAndOpenNotebook(in: windowState)
    }

    /// **New Chat** on Chats: as the sidebar's New chat, in the window's
    /// notebook while it holds one, else a chat in none.
    private func newChat() {
        vm.inWindow(windowState ?? vm.activeWindowState) { vm.requestNewChat() }
    }

    /// **New ▸ Canvas**: made in the space on screen, when it is one, and
    /// opened in this window.
    private func newCanvas() {
        vm.makeAndOpenCanvas(inPageSpace: destination.pageSpaceID, in: windowState)
    }

    private func scopePills(_ scopes: [SpaceScope]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(scopes) { pill in
                    SpaceScopePill(title: pill.title, isSelected: effectiveScope == pill) {
                        scope = pill
                    }
                    .accessibilityIdentifier("space.scope.\(pill.rawValue)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The order and the notebook filter in one menu, then List | Grid.
    private var viewControls: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Sort By", selection: Binding(get: { effectiveSort }, set: { sort = $0 })) {
                    ForEach(sortOptions) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                let notebooks = vm.notebooks.sorted(by: NotebooksHomeSort.titleOrder)
                if !notebooks.isEmpty {
                    Picker("Notebook", selection: $notebookFilter) {
                        Text("All Notebooks").tag(ArtifactsNotebookFilter.all)
                        Text("Not in a Notebook").tag(ArtifactsNotebookFilter.notInNotebook)
                        ForEach(notebooks) { notebook in
                            Text(NotebookTitle(notebook.title).text).tag(ArtifactsNotebookFilter.notebook(notebook.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
                // The Notebooks home's collections, as headings over their
                // notebooks in All (Group by Collection).
                if offersCollectionGrouping {
                    Divider()
                    Toggle("Group by Collection", isOn: $groupsByCollection)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(effectiveNotebookFilter == .all && !groupsListByCollection ? Color.secondary : Color.accentColor)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
            .fixedSize()
            .help("Sort and filter")
            .accessibilityLabel("Sort and filter")
            .accessibilityIdentifier("space.sortFilter")

            // A chat has no preview to draw on a card: Chats is a list; the
            // Images are pictures: always a grid.
            if destination != .chats, destination != .images {
                layoutButton(.list, systemImage: "list.bullet", help: "List")
                layoutButton(.grid, systemImage: "square.grid.2x2", help: "Grid")
            }
        }
    }

    private func layoutButton(_ option: SpaceLayout, systemImage: String, help: String) -> some View {
        Button {
            layout = option
        } label: {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(layout == option ? Color.primary : Color.secondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(layout == option ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(layout == option ? [.isSelected] : [])
    }

    // MARK: List

    /// The Notebook column, while the list is wide enough; Notebooks has
    /// none, since a notebook lives in no notebook (every row read "—").
    private var showsLocationColumn: Bool {
        destination != .notebooks && (listWidth <= 0 || listWidth >= 560)
    }
    private var locationColumnWidth: CGFloat { min(240, max(120, listWidth * 0.24)) }
    private static let dateColumnWidth: CGFloat = 104

    /// One row of the list: an item, how far in it is drawn, and whether it
    /// holds subpages (`PageParents`).
    private struct ListEntry: Identifiable {
        let item: SpaceItem
        var level = 0
        var hasChildren = false
        var isExpanded = false

        var id: String { item.id }
    }

    /// Whether the list draws a page's subpages under it. In All, Pages and a
    /// space, as a list: a search or a filter flattens it (a match is shown
    /// wherever it sits), Grid stays flat, grouping by collection flattens it,
    /// and a team's library has no subpages.
    private var nestsList: Bool {
        vm.activeTeamID == nil
            && layout == .list
            && !groupsListByCollection
            && (destination == .all || destination == .pages || destination.pageSpaceID != nil)
            && query.isEmpty
            && effectiveScope == .all
            && effectiveNotebookFilter == .all
            && !vm.pageParents.isEmpty
    }

    private var expandedPageIDs: Set<String> {
        Set(expandedPagesRaw.split(separator: ",").map(String.init))
    }

    private func toggleExpanded(_ pageID: String) {
        var ids = expandedPageIDs
        if ids.remove(pageID) == nil { ids.insert(pageID) }
        expandedPagesRaw = ids.sorted().joined(separator: ",")
    }

    private func expand(_ pageID: String) {
        var ids = expandedPageIDs
        guard ids.insert(pageID).inserted else { return }
        expandedPagesRaw = ids.sorted().joined(separator: ",")
    }

    /// The items as the list's rows. Nested, a page that sits under another
    /// page of this list is drawn under it, only while its parent is open;
    /// otherwise each item is a row of its own, in the list's order.
    private func listEntries(_ shown: [SpaceItem]) -> [ListEntry] {
        let flat = shown.map { ListEntry(item: $0) }
        guard nestsList else { return flat }
        let nestableIDs = Set(shown.compactMap { item -> String? in
            guard item.kind == .page, let artifact = item.artifact, vm.canNestPage(artifact) else { return nil }
            return item.id
        })
        guard !nestableIDs.isEmpty else { return flat }
        let tree = vm.pageParents.tree(among: shown.map(\.id).filter { nestableIDs.contains($0) })
        guard shown.contains(where: { tree.hasChildren($0.id) }) else { return flat }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Each top-level page's rows: itself, then what is open under it.
        var segments: [String: [PageParents.Tree.ListRow]] = [:]
        var root: String?
        for row in tree.listRows(expanded: expandedPageIDs) {
            if row.level == 0 { root = row.id }
            if let root { segments[root, default: []].append(row) }
        }
        var entries: [ListEntry] = []
        entries.reserveCapacity(shown.count)
        for item in shown {
            guard nestableIDs.contains(item.id) else {
                entries.append(ListEntry(item: item))
                continue
            }
            // A subpage is drawn under its parent, not on its own.
            guard tree.parentID(ofPage: item.id) == nil else { continue }
            for row in segments[item.id] ?? [] {
                guard let member = byID[row.id] else { continue }
                entries.append(ListEntry(item: member, level: row.level, hasChildren: row.hasChildren, isExpanded: row.isExpanded))
            }
        }
        return entries
    }

    /// One run of the list: a collection's heading (while grouped) and its rows.
    private struct ListRun: Identifiable {
        let section: SpaceCollectionSection
        let entries: [ListEntry]

        var id: String { section.id }
    }

    /// The collection's heading over its notebooks, or the last run's.
    @ViewBuilder
    private func collectionHeading(for section: SpaceCollectionSection) -> some View {
        if let collection = section.collection {
            let title = NotebookTitle(collection.name)
            SpaceCollectionHeading(
                title: title.text.isEmpty ? collection.name : title.text,
                icon: title.icon,
                count: section.items.count,
                actions: (
                    rename: { collectionNameRequest = .rename(collection) },
                    delete: { collectionToDelete = collection }
                )
            )
        } else {
            SpaceCollectionHeading(title: "Everything else", icon: nil, count: section.items.count)
        }
    }

    private func list(_ sections: [SpaceCollectionSection], headings: Bool, order: [String], selected: [SpaceItem]) -> some View {
        let runs = sections.map { ListRun(section: $0, entries: listEntries($0.items)) }
        // A chevron's column is kept in every row once any row has one, so the
        // tiles line up.
        let reservesDisclosure = runs.contains { run in run.entries.contains { $0.hasChildren || $0.level > 0 } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, reservesDisclosure ? 40 + SpaceListMetrics.disclosureColumnWidth : 40)
                if showsLocationColumn {
                    Text(isTeamPlace ? "In" : "Notebook")
                        .frame(width: locationColumnWidth, alignment: .leading)
                }
                Text(destination == .trash ? "Trashed" : effectiveSort.dateColumnTitle)
                    .frame(width: Self.dateColumnWidth, alignment: .leading)
                Color.clear.frame(width: 26, height: 1)
            }
            .zoomedSystemFont(size: 11.5, weight: .medium)
            .foregroundStyle(.tertiary)
            .textSelection(.disabled)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(runs) { run in
                    if headings {
                        collectionHeading(for: run.section)
                    }
                    ForEach(run.entries) { entry in
                        let item = entry.item
                        SpaceListRow(
                            item: item,
                            isSelected: selection.contains(item.id),
                            tile: { tile(for: item, size: 28) },
                            showsLocation: showsLocationColumn,
                            locationWidth: locationColumnWidth,
                            dateWidth: Self.dateColumnWidth,
                            dateText: SpaceDateText.short(date(for: item)),
                            restore: restoreAction(for: item),
                            level: entry.level,
                            reservesDisclosure: reservesDisclosure,
                            disclosure: entry.hasChildren
                                ? SpaceRowDisclosure(isExpanded: entry.isExpanded) { toggleExpanded(item.id) }
                                : nil,
                            open: { activate(item, order: order) },
                            menu: { menuItems(for: item, selected: selected) }
                        )
                        .onDrag { dragProvider(for: item) }
                        // A source dropped on a notebook's row joins it.
                        .spaceNotebookDropTarget(goal: item.notebook, cornerRadius: 8)
                        .spaceNotebookDialogs(goal: item.notebook, dialog: $notebookDialog)
                        Divider().opacity(0.6)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { listWidth = $0 }
    }

    /// Trash's Restore, on a row the open library owns.
    private func restoreAction(for item: SpaceItem) -> (() -> Void)? {
        guard destination == .trash, item.isOwnedHere else { return nil }
        if let space = item.pageSpace {
            return { vm.restorePageSpaces([space.id]) }
        }
        if let canvas = item.canvas {
            return { vm.restoreCanvases([canvas.id]) }
        }
        if let list = item.spaceList {
            return { vm.restoreSpaceLists([list.id]) }
        }
        // An archived notebook comes back active, into All.
        if let goal = item.notebook {
            return { Task { await vm.setGoalStatus(goalID: goal.id, status: .active) } }
        }
        guard let id = item.artifact?.id else { return nil }
        return { Task { await vm.restoreArtifactFromTrash(id) } }
    }

    /// The date column: when it was trashed, in Trash — an archived notebook
    /// by its last change, which archiving is — else the sort's.
    private func date(for item: SpaceItem) -> Date {
        if destination == .trash,
           let archivedAt = item.artifact?.archivedAt ?? item.canvas?.trashedAt ?? item.spaceList?.trashedAt
            ?? item.notebook?.updatedAt ?? (item.pageSpace == nil ? nil : item.updatedAt) {
            return archivedAt
        }
        return effectiveSort == .activity ? item.updatedAt : item.createdAt
    }

    // MARK: Grid

    private func grid(_ sections: [SpaceCollectionSection], headings: Bool, order: [String], selected: [SpaceItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                if headings {
                    collectionHeading(for: section)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: destination == .images ? 170 : 210, maximum: 300), spacing: 16)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(section.items) { item in
                        SpaceGridCard(
                            item: item,
                            isSelected: selection.contains(item.id),
                            previews: previews,
                            loadExcerpt: { id in try await vm.artifactMarkdown(id).markdown },
                            dateText: SpaceDateText.short(date(for: item)),
                            open: { activate(item, order: order) },
                            menu: { menuItems(for: item, selected: selected) }
                        )
                        .onDrag { dragProvider(for: item) }
                        // A source dropped on a notebook's card joins it.
                        .spaceNotebookDropTarget(goal: item.notebook, cornerRadius: 12)
                        .spaceNotebookDialogs(goal: item.notebook, dialog: $notebookDialog)
                    }
                }
            }
        }
    }

    // MARK: Tiles

    /// The item's tile: a picture's own thumbnail, else its kind's glyph in its
    /// colour on a soft square, as ChatGPT's list draws a page or an image.
    @ViewBuilder
    private func tile(for item: SpaceItem, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Group {
            if let listing = item.image?.latest {
                SpaceImageThumbnail(path: listing.path, cacheKey: SpaceImageThumbnail.cacheKey(listing), previews: previews)
            } else if let goal = item.notebook {
                // A notebook is drawn as the rest of the app draws it: its
                // cover, else its emoji on its colour.
                NotebookIconView(notebookID: goal.id, size: size, cornerRadius: size * 0.3, plate: NotebookTint.color(for: goal.id)) {
                    Text(NotebookTitle(goal.title).displayIcon)
                        .font(.system(size: size * 0.5))
                }
            } else {
                ZStack {
                    SpaceKindStyle.tint(item.kind).opacity(0.10)
                    if let linkedKind = item.artifact?.linkedKind {
                        LinkedPageIcon(kind: linkedKind, height: size * 0.5)
                    } else {
                        Image(systemName: SpaceKindStyle.symbol(item.kind))
                            .font(.system(size: size * 0.42, weight: .medium))
                            .foregroundStyle(SpaceKindStyle.tint(item.kind))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    // MARK: Actions

    /// A click on a row or a card: ⌘ chooses it or lets it go, ⇧ takes in the
    /// run from the last one chosen, and while anything is chosen a plain
    /// click chooses too (`SpaceSelection`); otherwise it opens.
    private func activate(_ item: SpaceItem, order: [String]) {
        guard selectsRows else { return open(item) }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selection.toggle(item.id)
        } else if flags.contains(.shift) {
            selection.extend(to: item.id, in: order)
        } else if !selection.isEmpty {
            selection.toggle(item.id)
        } else {
            open(item)
        }
    }

    private func open(_ item: SpaceItem) {
        if let canvas = item.canvas {
            vm.openCanvas(canvas.id, in: windowState)
        } else if let goal = item.notebook {
            if let windowState {
                vm.inWindow(windowState) { vm.openNotebookInReader(goal.id) }
            } else {
                vm.openNotebookInReader(goal.id)
            }
        } else if let courseID = item.courseID {
            vm.openCourse(courseID, in: windowState)
        } else if let chat = item.chat {
            // In its notebook when it is filed in one, as the rail opens it.
            vm.inWindow(windowState ?? vm.activeWindowState) { vm.requestResumeReviewSession(chat.id) }
        } else if let list = item.spaceList {
            onSelectPlace(.list(list.id))
        } else if let group = item.image {
            SpaceRecents.shared.note(.image, id: group.imageID, title: GeneratedImageActions.title(for: group), createdAt: group.updatedAt)
            openedImage = group
        } else if let artifact = item.artifact {
            onOpen(artifact)
        }
    }

    private func dragProvider(for item: SpaceItem) -> NSItemProvider {
        // A canvas or a list is no record a pane or a space row takes by
        // dragging.
        if item.canvas != nil || item.spaceList != nil || item.notebook != nil || item.courseID != nil || item.pageSpace != nil {
            return NSItemProvider()
        }
        // A chat drags as the rail's row does: to a pane's edge, or onto a notebook.
        if let chat = item.chat {
            StudioDragVisibility.shared.begin(sessionID: chat.id)
            return reviewSessionDragProvider(for: ReviewSessionTransfer(from: chat))
        }
        if let listing = item.image?.latest {
            return GeneratedImageActions.dragProvider(listing)
        }
        guard let artifact = item.artifact else { return NSItemProvider() }
        StudioDragVisibility.shared.begin(centerTab: artifact.section.centerTab, artifactID: artifact.id)
        return studioArtifactDragProvider(for: artifact)
    }

    /// A row's or card's ⋯ and right-click; on one of several chosen rows,
    /// what the selection bar does, for all of them.
    @ViewBuilder
    private func menuItems(for item: SpaceItem, selected: [SpaceItem] = []) -> some View {
        if selected.count > 1, selected.contains(where: { $0.id == item.id }) {
            selectionActions(selected)
        } else if let goal = item.notebook {
            SpaceNotebookMenuItems(
                goal: goal,
                onOpen: { open(item) },
                onNewCollection: { collectionNameRequest = .create(adding: [goal.id]) },
                dialog: $notebookDialog
            )
        } else if let space = item.pageSpace {
            // A space in Trash: back to the sidebar, or gone for good.
            Button("Restore", systemImage: "arrow.uturn.backward") { vm.restorePageSpaces([space.id]) }
            Divider()
            Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                deletingForever = [space.id]
            }
        } else if item.courseID != nil {
            Button("Open") { open(item) }
            if let destination = item.otherWindowDestination {
                OtherWindowMenuItem(destination)
            }
        } else if let chat = item.chat {
            chatMenuItems(chat, item: item)
        } else if let canvas = item.canvas {
            SpaceCanvasMenuItems(
                canvas: canvas,
                onOpen: { open(item) },
                onRename: {
                    renameDraft = item.title
                    renaming = item
                }
            )
            if canvas.isTrashed {
                Divider()
                Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                    deletingForever = [canvas.id]
                }
            }
        } else if let list = item.spaceList {
            SpaceListMenuItems(
                list: list,
                onOpen: { open(item) },
                onRename: {
                    renameDraft = item.title
                    renaming = item
                }
            )
            if list.isTrashed {
                Divider()
                Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                    deletingForever = [list.id]
                }
            }
        } else if let group = item.image {
            Button("Open") { open(item) }
            Divider()
            GeneratedImageActions.menuItems(
                for: group,
                onRename: { _ in
                    renameDraft = item.title
                    renaming = item
                },
                onTrash: { group in
                    Task {
                        if await GeneratedImageActions.trash(group) {
                            SpaceRecents.shared.forget(.image, id: group.imageID)
                        }
                        await loadImages()
                    }
                },
                notebook: GeneratedImageNotebookFiling(
                    livesIn: { Set([group.notebookID].compactMap { $0 }) },
                    set: { notebookID in
                        Task {
                            _ = await GeneratedImageActions.setNotebook(group, to: notebookID)
                            await loadImages()
                        }
                    }
                )
            )
        } else if let artifact = item.artifact {
            if item.isArchived {
                if item.isOwnedHere {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        Task { await vm.restoreArtifactFromTrash(artifact.id) }
                    }
                    Divider()
                    Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                        deletingForever = [artifact.id]
                    }
                }
            } else {
                // Codex's page row menu first, in its order: Rename · Pin ·
                // Delete (Move to Trash, since Trash is the archive) │ Share ·
                // Copy ▸ · Download │ Open in new window. ForeverLM's own
                // follow under one divider (docs/codex-parity-audit.md, item 36).
                if item.isOwnedHere {
                    if !artifact.namesItself {
                        Button("Rename…", systemImage: "pencil") {
                            renameDraft = item.title
                            renaming = item
                        }
                    }
                    SpacePagePinItem(artifact: artifact)
                    if item.kind == .animation {
                        // An animation has no Trash, as in the Animations
                        // pane: it is deleted, after the question.
                        Button("Delete…", systemImage: "trash", role: .destructive) {
                            deletingForever = [artifact.id]
                        }
                    } else {
                        Button(vm.trashTitle(for: artifact.id), systemImage: "trash", role: .destructive) {
                            Task { await vm.moveArtifactToTrash(artifact.id) }
                        }
                    }
                }
                if SpacePageSharingItems.applies(to: artifact) {
                    Divider()
                    SpacePageSharingItems(artifact: artifact)
                }
                if let destination = item.otherWindowDestination {
                    Divider()
                    OtherWindowMenuItem(destination)
                }
                Divider()
                Button("Add to Chat", systemImage: "message") {
                    Task { await vm.attachDocToChat(artifact.id) }
                }
                KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
                if let linkedURL = artifact.linkedURL, let url = URL(string: linkedURL), url.scheme?.hasPrefix("http") == true {
                    Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                }
                if item.isOwnedHere {
                    NotebookFilingMenuItems(
                        sourceIDs: artifact.sourceIDs,
                        livesIn: { vm.notebooksHolding(item.filing) },
                        add: { notebookID in Task { await vm.addArtifact(artifact.id, toNotebook: notebookID) } },
                        remove: { notebookID in Task { await vm.removeArtifact(artifact.id, fromNotebook: notebookID) } }
                    )
                    PageSpaceMenu(page: artifact)
                    KnowledgeMapOnCanvasesSection(ref: "doc:\(artifact.id)", windowState: nil)
                    if item.kind == .page {
                        PageNestMenuItems(
                            page: artifact,
                            onMoveToPage: { movingToPage = artifact },
                            onCreatedSubpage: { subpage in
                                expand(artifact.id)
                                onOpen(subpage)
                            }
                        )
                    }
                    if item.kind == .page, artifact.teamID == nil {
                        ShareWithTeamMenu(excludedTeamIDs: item.teamIDs) { teamID in
                            Task { await vm.shareArtifact(artifact.id, withTeam: teamID) }
                        }
                    }
                }
                Button(item.isHidden ? "Show in Lists" : "Hide", systemImage: item.isHidden ? "eye" : "eye.slash") {
                    Task { await vm.setArtifactHidden(artifactID: artifact.id, isHidden: !item.isHidden) }
                }
            }
        }
    }

    /// A chat's ⋯ and right-click: the rail's, with Rename… and Delete… asking
    /// as the Space's other menus do.
    @ViewBuilder
    private func chatMenuItems(_ chat: ReviewSessionRecord, item: SpaceItem) -> some View {
        Button("Open") { open(item) }
        if let destination = item.otherWindowDestination {
            OtherWindowMenuItem(destination)
        }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(StudioEntityLink.chat(chat.id).markdownDestination, forType: .string)
            vm.showToast("Link copied")
        }
        KnowledgeMapAddToCanvasMenu(refs: [KnowledgeMapOutside.chatRef(chat.id)])
        Divider()
        // Codex's marks on a chat, as the sidebar row has them: its pin, which
        // follows the account, and this Mac's unread dot.
        let isPinned = vm.isChatPinned(chat.id)
        Button(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin") {
            vm.setChatPinned(chat.id, pinned: !isPinned)
        }
        let isUnread = ChatReadMarks.shared.isUnread(chat.id)
        Button(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "checkmark.circle" : "circle") {
            if isUnread {
                ChatReadMarks.shared.markRead(chat.id)
            } else {
                ChatReadMarks.shared.markUnread(chat.id)
            }
        }
        if item.isOwnedHere {
            Button("Rename…", systemImage: "pencil") {
                renameDraft = item.title
                renaming = item
            }
            if !vm.notebooks.isEmpty {
                // A sheet with a search field, not a menu of every notebook.
                Button("Move to Notebook…", systemImage: "folder") { movingChat = chat }
            }
        }
        Divider()
        Button(item.isHidden ? "Show in Lists" : "Hide", systemImage: item.isHidden ? "eye" : "eye.slash") {
            Task { await vm.setReviewSessionHidden(chat.id, hidden: !item.isHidden) }
        }
        if item.isOwnedHere {
            Button("Delete…", systemImage: "trash", role: .destructive) {
                deletingChat = item
            }
        }
    }

    private func commitRename() {
        guard let item = renaming else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !title.isEmpty, title != item.title else { return }
        if let canvas = item.canvas {
            vm.renameCanvas(canvas.id, to: title)
        } else if let list = item.spaceList {
            vm.renameSpaceList(list.id, to: title)
        } else if let chat = item.chat {
            Task { await vm.renameReviewSession(chat.id, title: title) }
        } else if let group = item.image {
            Task {
                if await GeneratedImageActions.rename(group, to: title) {
                    SpaceRecents.shared.note(.image, id: group.imageID, title: title, createdAt: group.updatedAt)
                }
                await loadImages()
            }
        } else if let artifact = item.artifact {
            Task { await vm.updateArtifact(artifactID: artifact.id, title: title) }
        }
    }

    private func title(ofArtifact id: String) -> String {
        vm.artifacts.first { $0.id == id }?.title ?? vm.canvases.canvas(id)?.name ?? vm.spaceLists.list(id)?.name
            ?? vm.pageSpaces.space(id).map { NotebookTitle($0.name).text } ?? "this item"
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if !query.isEmpty {
                emptyLine(systemImage: "magnifyingglass", "No results for “\(query)”")
            } else if effectiveScope != .all || effectiveNotebookFilter != .all {
                emptyLine(systemImage: "line.3.horizontal.decrease", "Nothing here")
                Button("Show Everything") {
                    scope = .all
                    notebookFilter = .all
                }
                .buttonStyle(.link)
            } else {
                switch destination {
                case .trash:
                    emptyLine(systemImage: "trash", "Trash is empty")
                case .images:
                    emptyLine(systemImage: "photo", "No images yet")
                case .drive:
                    emptyLine(systemImage: SpaceDestination.drive.symbolName, "No Google Docs linked")
                    SpaceDarkPillButton(title: ArtifactSection.docs.linkActionTitle, systemImage: nil, image: nil) { onLink(.docs) }
                case .sites:
                    emptyLine(systemImage: SpaceDestination.sites.symbolName, "No sites yet")
                    if !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillButton(title: ArtifactSection.sites.linkActionTitle, systemImage: nil, image: nil) { onLink(.sites) }
                    }
                case .animations:
                    emptyLine(systemImage: SpaceDestination.animations.symbolName, "No animations yet")
                    if !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillButton(title: ArtifactSection.animations.linkActionTitle, systemImage: nil, image: nil) {
                            vm.requestAnimationChat()
                        }
                    }
                case .canvases:
                    emptyLine(systemImage: KnowledgeMap.symbolName, "No canvases yet")
                    SpaceDarkPillButton(title: "New Canvas", systemImage: nil, image: nil) { newCanvas() }
                case .team(let id):
                    emptyLine(systemImage: "person.2", "Nothing shared with \(vm.teams.first { $0.id == id }?.name ?? "this space") yet")
                case .space:
                    emptyLine(systemImage: "square.stack", "No pages yet")
                    if !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillButton(title: "New Page", systemImage: nil, image: nil, action: onNewPage)
                    }
                case .chats:
                    emptyLine(systemImage: "bubble.left.and.bubble.right", "No chats yet")
                    SpaceDarkPillButton(title: "New Chat", systemImage: nil, image: nil) { newChat() }
                case .notebooks:
                    emptyLine(systemImage: NotebookGlyph.systemImage, "No notebooks yet")
                    if !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillButton(title: "New Notebook", systemImage: nil, image: nil) { newNotebook() }
                    }
                case .all, .pages:
                    emptyLine(systemImage: SpaceDestination.pages.symbolName, destination == .pages ? "No pages yet" : "Nothing here yet")
                    if !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillButton(title: "New Page", systemImage: nil, image: nil, action: onNewPage)
                    }
                case .list, .board, .plan:
                    EmptyView()
                }
            }
        }
    }

    private func emptyLine(systemImage: String, _ text: String) -> some View {
        SpaceEmptyLine(systemImage: systemImage, text: text)
    }
}

#endif
