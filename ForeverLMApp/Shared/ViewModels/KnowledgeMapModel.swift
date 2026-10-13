import Foundation
import Observation

/// The Mac's reads and writes of the `map.layout.<mapID>` row
/// (`KnowledgeMapLayout`).
enum KnowledgeMapRows {
    /// A test's own defaults, bound for the task that runs it. While bound,
    /// writes go to the suite and never to the sync rail.
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    /// The defaults this Mac's own choices about the Canvas (its display
    /// switches) are kept in: a test's while it binds them.
    static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    static func layout(mapID: String) -> KnowledgeMapLayout {
        storedLayout(mapID: mapID) ?? KnowledgeMapLayout()
    }

    /// The row as stored; nil when there is none, which is no canvas.
    static func storedLayout(mapID: String) -> KnowledgeMapLayout? {
        KnowledgeMapLayout(preferenceValue: defaults.object(forKey: KnowledgeMap.layoutPreferenceKey(mapID: mapID)))
    }

    /// Every canvas the rows hold now. The keys are built at runtime, so one
    /// scan of the defaults finds them.
    static func canvases() -> KnowledgeMapCanvases {
        let rows = defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(KnowledgeMap.layoutKeyPrefix)
        }
        return KnowledgeMapCanvases(rows: rows)
    }

    /// Removes a canvas's row: Delete Forever.
    static func remove(mapID: String) {
        let key = KnowledgeMap.layoutPreferenceKey(mapID: mapID)
        if let override = overrideDefaults {
            override.defaults.removeObject(forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }

    /// Reads the stored row, applies `change`, and writes the result. Reading
    /// first keeps what a remote write brought in since this Mac last read.
    @discardableResult
    static func update(mapID: String, now: Date = Date(), _ change: (inout KnowledgeMapLayout) -> Void) -> KnowledgeMapLayout {
        var layout = layout(mapID: mapID)
        change(&layout)
        layout.pruneTombstones(now: now.timeIntervalSince1970)
        let key = KnowledgeMap.layoutPreferenceKey(mapID: mapID)
        if let override = overrideDefaults {
            override.defaults.set(layout.preferenceValue, forKey: key)
        } else {
            // `PreferenceStore` drops a write that changes nothing.
            PreferenceStore.set(layout.preferenceValue, forKey: key)
        }
        return layout
    }
}

/// Something the Map pane asks its renderer to do, in order: the chat's
/// focus_map, a toolbar button, a search. Each carries an id so the canvas
/// runs it once.
struct KnowledgeMapCommand: Identifiable, Equatable {
    enum Action: Equatable {
        case focus(refs: [String], regionID: String?)
        case select(refs: [String])
        case zoom(Double)
        case fit
        case tool(String)
        case selectRegion(String?)
        case selectEdge(String?)
        /// Place `refs` around a point in the view (a drop from elsewhere in
        /// the app), under a new region named `regionName` when there is one,
        /// the frame of notebook `notebookID` when that is set. A notebook
        /// whose frame is on the plane already is shown there instead.
        case drop(x: Double, y: Double, refs: [String], regionName: String?, notebookID: String? = nil)
        /// Place `refs` beside the selection, else in the middle of the view:
        /// the Library's Place All, and what the add box and the find field set
        /// down when they were not asked for at a point. The renderer reveals
        /// the block and rings it.
        case dropAtCenter(refs: [String], regionName: String?, notebookID: String? = nil)
    }

    let id = UUID()
    let action: Action
}

/// What the renderer last reported about the view, for the chat's context.
struct KnowledgeMapViewport: Equatable {
    /// One region framing the view, for the chrome's path.
    struct PathStep: Equatable {
        var id: String
        var name: String
    }

    var level: String = "regions"
    var center: (x: Double, y: Double) = (0, 0)
    var span: (w: Double, h: Double) = (0, 0)
    var visibleRefs: [String] = []
    var visibleRegionIDs: [String] = []
    /// The regions framing the view, outermost first: the innermost region
    /// holding the view's middle and most of the view, and those around it
    /// (docs/knowledge-map-design.md, "Regions inside regions").
    var path: [PathStep] = []
    /// The camera's zoom: the readout beside the fit button.
    var scale: Double = 1
    /// Whether nothing drawn is in view (no card, region or ghost): the
    /// Back to content pill shows then.
    var empty = false

    /// Changes when what is on screen does: the zoom level or the cards in
    /// view. The view's caption is written again only then.
    var captionKey: Int {
        var hasher = Hasher()
        hasher.combine(level)
        hasher.combine(visibleRegionIDs.sorted())
        hasher.combine(visibleRefs.prefix(80).sorted())
        return hasher.finalize()
    }

    static func == (lhs: KnowledgeMapViewport, rhs: KnowledgeMapViewport) -> Bool {
        lhs.level == rhs.level && lhs.center == rhs.center && lhs.span == rhs.span
            && lhs.visibleRefs == rhs.visibleRefs && lhs.visibleRegionIDs == rhs.visibleRegionIDs
            && lhs.path == rhs.path && lhs.scale == rhs.scale && lhs.empty == rhs.empty
    }
}

/// The open canvas's state on this Mac: the learner's layout (the synced
/// row), the cards the library gives it, the lens showing, and what the
/// learner has selected. One canvas is open at a time on a Mac, and every
/// window showing the Canvas shows it: opening another canvas replaces the
/// view model's model (`StudioViewModel.openCanvas`), so a lens, a selection
/// or an undo step never crosses from one canvas to another.
@MainActor
@Observable
final class KnowledgeMapModel {
    /// The canvas this model shows: its layout row is `map.layout.<mapID>`.
    let mapID: String

    private(set) var layout = KnowledgeMapLayout()
    private(set) var content = KnowledgeMapContent(nodes: [], links: [])
    /// Bumped whenever `layout` changes, so the canvas pushes it once.
    private(set) var layoutRevision = 0
    private(set) var contentRevision = 0
    /// Each source card's picture, by ref: where the canvas renders it from,
    /// as the Library rows do (`SourceArtwork`). Not observed: the canvas
    /// reads it when it pushes new content.
    @ObservationIgnored var artworkOrigins: [String: SourceArtwork.Origin] = [:]
    /// Each figure clip's printed caption by highlight id, read from the
    /// paper's figure index when the cards are rebuilt: a captioned clip's
    /// card is taller (`KnowledgeMap.clipCaptionHeight`).
    @ObservationIgnored var clipCaptions: [String: String] = [:]
    /// The clips on sources the Canvas shows, by highlight id: a clip card's
    /// picture is drawn from its page region, and its inspector edits its note.
    @ObservationIgnored private(set) var clips: [String: SourceHighlight] = [:]
    /// Draws a clip's picture for the page, as a data URL, from the PDF this
    /// Mac holds; nil when it cannot. Set by the view model.
    @ObservationIgnored var clipPicture: (@MainActor (SourceHighlight) async -> String?)?
    private(set) var lens: KnowledgeMapLens?
    private(set) var lensRevision = 0
    private(set) var commands: [KnowledgeMapCommand] = []

    /// The cards the learner selected or circled.
    var selection: [String] = []
    var selectedRegionID: String?
    var selectedEdgeID: String?
    var tool = "select"
    /// Whether the shortcuts popover shows: the keyboard button, or ? on the plane.
    var showsShortcuts = false
    var viewport = KnowledgeMapViewport()
    /// Where a note is being written, in world space, while the composer shows.
    var pendingNote: (x: Double, y: Double)?
    /// The renderer's last error, shown in place of the map.
    var rendererError: String?

    // MARK: Memory (WP-B2)
    /// The Memory layer's marks and a review in place (KnowledgeMapModel+Memory.swift).
    let memory = KnowledgeMapMemory()

    /// The model's summaries of clusters and regions, by cluster key
    /// (`KnowledgeMapSummaries`), read from this Mac's cache off the main actor
    /// when the model is made (`summaryCacheLoaded()`).
    private(set) var summaries: [String: KnowledgeMapSummaries.Summary] = [:]
    private(set) var summariesRevision = 0
    /// The cache read `init` starts.
    @ObservationIgnored private var summaryCacheLoad: Task<Void, Never>?
    /// Whether ForeverLM writes a caption for what is in view as the learner
    /// explores. Off until they turn it on: every caption is a model call.
    var describesView = false {
        didSet { if !describesView { viewCaption = nil } }
    }
    /// The caption for what is on screen now, when `describesView` is on.
    var viewCaption: String?
    @ObservationIgnored private var captionCache: [Int: String] = [:]
    @ObservationIgnored private var summaryRequest = 0

    // MARK: Proposals (WP-B1)

    /// ForeverLM's answer to the learner's last Ask, drawn dotted until each
    /// proposal is kept or dismissed; nil when none shows, and never while a
    /// lens shows. Written only by `KnowledgeMapModel+Proposals.swift`.
    var proposals: KnowledgeMapProposalSet?
    /// Bumped whenever `proposals` changes, so the canvas pushes them once.
    var proposalsRevision = 0
    /// The Ask under way, for the inspector's progress row.
    var asking: CanvasAskTool?
    @ObservationIgnored let askState = KnowledgeMapAskState()

    // MARK: The popup

    /// The card ⌘-click floats over the plane, one at a time
    /// (`StudioViewModel.showKnowledgeMapPopup`, `KnowledgeMapPopupLayer`);
    /// nil when none shows. Never stored.
    var popup: KnowledgeMapPopup?
    // MARK: Display (the parity build)

    /// Whether the minimap shows in the corner of the plane: this Mac's
    /// choice, remembered here and never synced, off until turned on.
    static let minimapPreferenceKey = "knowledgeMap.minimap.v1"

    var showsMinimap = KnowledgeMapRows.defaults.bool(forKey: KnowledgeMapModel.minimapPreferenceKey) {
        didSet {
            guard showsMinimap != oldValue else { return }
            KnowledgeMapRows.defaults.set(showsMinimap, forKey: Self.minimapPreferenceKey)
            displayRevision &+= 1
        }
    }

    /// What the add box and the find field search, lower-cased once per change
    /// of the cards rather than on every keystroke.
    @ObservationIgnored private var cachedAddSearchIndex: (revision: Int, index: KnowledgeMapAddSearch.Index)?

    var addSearchIndex: KnowledgeMapAddSearch.Index {
        if let cached = cachedAddSearchIndex, cached.revision == contentRevision { return cached.index }
        let index = KnowledgeMapAddSearch.Index(content: content)
        cachedAddSearchIndex = (contentRevision, index)
        return index
    }

    /// Whether the Library sidebar shows beside the plane: this Mac's choice,
    /// remembered here and never synced, closed until it is opened. It steps
    /// aside during a review in place without changing the choice.
    static let libraryPreferenceKey = "knowledgeMap.library.v1"

    var showsLibrary = KnowledgeMapRows.defaults.bool(forKey: KnowledgeMapModel.libraryPreferenceKey) {
        didSet {
            guard showsLibrary != oldValue else { return }
            KnowledgeMapRows.defaults.set(showsLibrary, forKey: Self.libraryPreferenceKey)
        }
    }

    /// Where the add box is asked for, in the window it was asked in
    /// (`KnowledgeMapAddBoxRequest`); nil when it is closed. Never stored.
    var addBox: KnowledgeMapAddBoxRequest?

    /// Bumped by ⌘F on the plane, so the pane moves the cursor into its find
    /// field.
    var findFocusRequests = 0

    /// Focus mode: everything but the selection and what is joined to it is
    /// dimmed. Never stored; it ends with the canvas's model.
    var focusMode = false {
        didSet {
            guard focusMode != oldValue else { return }
            displayRevision &+= 1
        }
    }

    /// Bumped when the minimap or Focus is switched, so the canvas pushes
    /// the display once.
    private(set) var displayRevision = 0

    /// Draws the plane to a PNG, at `scale` times its size and, with refs, of
    /// just those cards' bounds. Installed by the pane's canvas while it is
    /// ready and cleared when it goes; nil while no Canvas pane shows. Export
    /// as Image and `screenshot_canvas` use it.
    @ObservationIgnored var imageExporter: (@MainActor (_ scale: Double, _ refs: [String]?) async throws -> Data)?

    /// Each picture card's width over its height by ref (`picture:<id>`), read
    /// from the file when the cards are rebuilt; 0 once looked for and not found.
    @ObservationIgnored var pictureAspects: [String: Double] = [:]
    /// Moves when the Images library does (a picture drawn, saved, renamed,
    /// trashed or arrived from another Mac), so the cards are read again
    /// (`StudioViewModel.knowledgeMapContentSignature`).
    private(set) var picturesRevision = 0
    @ObservationIgnored private var imageObservers: [RemoteRowObserver] = []
    /// The Images library as last read (`StudioViewModel.knowledgeMapPictureCards`):
    /// the folder's stamp and `picturesRevision` it was read at, and the cards.
    @ObservationIgnored var pictureLibrary: (stamp: Int, revision: Int, cards: [KnowledgeMapPictureCard])?

    // MARK: Faces (WP-B1)

    /// The written faces of the drawn source cards, by ref
    /// (`KnowledgeMapModel+Faces.swift`).
    var faces: [String: KnowledgeMapFaces.Face] = [:]
    var facesRevision = 0
    /// Whether source cards show their written faces: per Mac, on by default.
    var showsWrittenFaces = KnowledgeMapFaces.isEnabledOnThisMac {
        didSet {
            KnowledgeMapFaces.isEnabledOnThisMac = showsWrittenFaces
            facesRevision &+= 1
        }
    }
    @ObservationIgnored let facesState = KnowledgeMapFacesState()

    @ObservationIgnored private var remoteObserver: RemoteRowObserver?
    /// Told after each write of the row, so the Space's list of canvases
    /// follows the open one (its name, its last activity).
    /// Passages just made for this canvas (`build_canvas`), shown as cards
    /// before they are placed.
    @ObservationIgnored var pendingPassageIDs: Set<String> = []
    /// The page of a passage marked without page geometry (over MCP, or in
    /// an article), found by searching its paper's PDF once; by highlight id.
    @ObservationIgnored var passagePages: [String: Int] = [:]
    /// Page cards (`page:<sourceID>:<n>`) just made for this canvas, shown
    /// before they are placed, as pending passages are.
    @ObservationIgnored var pendingPageRefs: Set<String> = []
    /// Each page card's width over its height, from the PDF's own page, by
    /// ref; 0 once looked for and not found, so a refresh does not look again.
    @ObservationIgnored var pageAspects: [String: Double] = [:]
    /// Draws one page of a PDF source as a data URL, from the PDF this Mac
    /// holds; nil when it cannot. Set by the view model.
    @ObservationIgnored var pagePicture: (@MainActor (_ sourceID: String, _ page: Int) async -> String?)?
    /// What this Mac has read of the PDF of each source the canvas may draw as
    /// its page (a paper placed with `page`, or one a first placement would
    /// give a page), by source id: how many pages it has and the first one's
    /// shape (`StudioViewModel.loadKnowledgeMapPageFaces`). A page count of 0
    /// means looked at and no PDF.
    @ObservationIgnored var pageFaces: [String: KnowledgeMapPageFace] = [:]
    /// Whether a source placed for the first time shows its page: its type is
    /// paper and its PDF is on this Mac. Set by the view model
    /// (`StudioViewModel.knowledgeMapSourceShowsPage`); without it no card is
    /// given a page.
    @ObservationIgnored var pageFaceDefault: ((String) -> Bool)?

    /// The page cards the canvas draws: those placed on it and those just
    /// made for it. A page is a card only once it is on a canvas.
    var pageRefs: [String] {
        let placed = layout.placements.keys.filter { $0.hasPrefix("page:") }
        return Array(Set(placed).union(pendingPageRefs)).sorted()
    }

    /// Moves whenever a page card is placed or taken off, so the cards are
    /// read again (`StudioViewModel.knowledgeMapContentSignature`).
    var placedPagesStamp: Int {
        layout.placements.keys.reduce(0) { $0 &+ ($1.hasPrefix("page:") ? $1.hashValue : 0) }
    }

    /// A found page; nil while unfound or not searched for.
    func passagePage(_ highlightID: String) -> Int? {
        passagePages[highlightID].flatMap { $0 > 0 ? $0 : nil }
    }
    @ObservationIgnored var onLayoutWritten: ((String, KnowledgeMapLayout) -> Void)?
    /// Sources the learner set down inside a notebook's frame, by notebook:
    /// the frame is the notebook on the plane, so they join it.
    @ObservationIgnored var onSourcesSetDownInFrame: ((_ notebookID: String, _ sourceIDs: [String]) -> Void)?
    /// The same for Docs (and sites, animations: anything a notebook made).
    @ObservationIgnored var onDocsSetDownInFrame: ((_ notebookID: String, _ docIDs: [String]) -> Void)?
    @ObservationIgnored private(set) var nodesByRef: [String: KnowledgeMapNode] = [:]
    /// What the Canvas Summaries model reads about each notebook beside its
    /// cards' titles (`KnowledgeMapModel.notebookContext`), by notebook id.
    @ObservationIgnored private(set) var notebookContexts: [String: String] = [:]

    init(mapID: String) {
        self.mapID = mapID
        reloadLayout()
        let token = NotificationCenter.default.addObserver(
            forName: PreferenceStore.didChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String> ?? []
            MainActor.assumeIsolated {
                guard let self, keys.contains(KnowledgeMap.layoutPreferenceKey(mapID: self.mapID)) else { return }
                self.reloadLayout()
            }
        }
        remoteObserver = RemoteRowObserver(token: token)
        for name in [Notification.Name.generatedImagesChanged, .generatedImagesArrived] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.picturesRevision &+= 1 }
            }
            imageObservers.append(RemoteRowObserver(token: observer))
        }
        summaryCacheLoad = Task { [weak self] in
            let cached = await KnowledgeMapSummaries.loadCache()
            guard let self, !cached.isEmpty else { return }
            // A summary written since the model was made is newer than the cache's.
            self.summaries = cached.merging(self.summaries) { _, written in written }
            self.summariesRevision &+= 1
        }
    }

    /// Waits until the summaries this Mac cached are in `summaries`, so a
    /// caller deciding which clusters need a model call never pays for one the
    /// cache holds.
    func summaryCacheLoaded() async {
        await summaryCacheLoad?.value
    }

    /// Holds the observer of remote rows and lets it go with the model, so a
    /// canvas opened and left leaves nothing listening behind it.
    final class RemoteRowObserver {
        let token: NSObjectProtocol

        init(token: NSObjectProtocol) {
            self.token = token
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: Layout

    func reloadLayout() {
        let stored = KnowledgeMapRows.layout(mapID: mapID)
        guard stored != layout else { return }
        layout = stored
        layoutRevision &+= 1
    }

    /// Writes a change to the learner's row. A change the learner made is
    /// remembered for Undo; one the app makes on its own (linking a notebook's
    /// frame) is not.
    ///
    /// A source the change places for the first time shows its page
    /// (`pageFaceDefault`) when the write is the learner's own, one Undo
    /// takes back (`undoable`, not `sealed`): Undo, Redo, Restore and the app's
    /// own writes never add it, and a card already placed keeps its face.
    /// `pagesForPapers` is false for a write that asked for the usual card.
    func updateLayout(undoable: Bool = true, sealed: Bool = false, pagesForPapers: Bool = true, _ change: (inout KnowledgeMapLayout, Double) -> Void) {
        let now = Date()
        let stamp = now.timeIntervalSince1970
        var before = KnowledgeMapLayout()
        layout = KnowledgeMapRows.update(mapID: mapID, now: now) { row in
            before = row
            change(&row, stamp)
            if undoable, !sealed, pagesForPapers { showPapersAsPages(in: &row, placedSince: before) }
        }
        layoutRevision &+= 1
        if undoable { remember(KnowledgeMapEdit(before: before, after: layout, at: now, sealed: sealed)) }
        onLayoutWritten?(mapID, layout)
    }

    // MARK: Undo

    /// The learner's edits, newest last, and the ones undone since.
    @ObservationIgnored private var undoEdits: [KnowledgeMapEdit] = []
    @ObservationIgnored private var redoEdits: [KnowledgeMapEdit] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// How many edits Undo goes back through.
    static let undoDepth = 100
    /// Writes closer together than this are one edit: a drop and the frame it
    /// reflows, a region moved with its cards, a burst of arrow-key nudges.
    static let editBurst: TimeInterval = 0.6

    private func remember(_ edit: KnowledgeMapEdit) {
        guard edit.changes else { return }
        // A sealed edit (a Restore) is a step of its own, whatever came
        // within the burst before or after it.
        if let last = undoEdits.last, !edit.sealed, !last.sealed, edit.at.timeIntervalSince(last.at) < Self.editBurst, redoEdits.isEmpty {
            undoEdits[undoEdits.count - 1] = KnowledgeMapEdit(before: last.before, after: edit.after, at: edit.at)
        } else {
            undoEdits.append(edit)
            if undoEdits.count > Self.undoDepth { undoEdits.removeFirst(undoEdits.count - Self.undoDepth) }
        }
        redoEdits.removeAll()
        canUndo = true
        canRedo = false
    }

    /// **Restore** a named version (`KnowledgeMapVersions`): the canvas's
    /// cards, regions and arrows become the snapshot's, as one edit that Undo
    /// takes back. What the snapshot lacks is removed with tombstones, so
    /// another Mac follows; the canvas's name, Trash mark, notebook and date
    /// stay the current row's (`KnowledgeMapVersionRestore.apply`). False when
    /// the canvas already held exactly that.
    @discardableResult
    func restoreLayoutSnapshot(_ snapshot: KnowledgeMapLayout) -> Bool {
        var before = KnowledgeMapLayout()
        updateLayout(sealed: true) { layout, at in
            before = layout
            KnowledgeMapVersionRestore.apply(snapshot, to: &layout, at: at)
        }
        return KnowledgeMapEdit(before: before, after: layout, at: Date()).changes
    }

    /// Takes back the learner's last edit: each entry it changed gets its old
    /// value back, written as the newest write so every Mac takes it.
    func undo() {
        guard let edit = undoEdits.popLast() else { return }
        updateLayout(undoable: false) { layout, at in edit.restore(edit.before, into: &layout, at: at) }
        redoEdits.append(edit)
        canUndo = !undoEdits.isEmpty
        canRedo = true
    }

    func redo() {
        guard let edit = redoEdits.popLast() else { return }
        updateLayout(undoable: false) { layout, at in edit.restore(edit.after, into: &layout, at: at) }
        undoEdits.append(edit)
        canUndo = true
        canRedo = !redoEdits.isEmpty
    }

    func place(_ items: [(ref: String, x: Double, y: Double)]) {
        guard !items.isEmpty else { return }
        updateLayout { layout, at in
            for item in items { layout.place(item.ref, x: item.x, y: item.y, at: at) }
        }
        var sourcesByNotebook: [String: [String]] = [:]
        var docsByNotebook: [String: [String]] = [:]
        for item in items {
            guard let ref = KnowledgeMap.ItemRef(item.ref), ref.kind == .source || ref.kind == .doc,
                  let frame = regionID(containing: item.ref),
                  let notebookID = layout.regions[frame]?.notebookID else { continue }
            if ref.kind == .source {
                sourcesByNotebook[notebookID, default: []].append(ref.id)
            } else {
                docsByNotebook[notebookID, default: []].append(ref.id)
            }
        }
        for (notebookID, ids) in sourcesByNotebook { onSourcesSetDownInFrame?(notebookID, ids) }
        for (notebookID, ids) in docsByNotebook { onDocsSetDownInFrame?(notebookID, ids) }
    }

    /// Sends cards back to the shore; their arrows go with them.
    func unplace(_ refs: [String]) {
        let placed = refs.filter { layout.placements[$0] != nil }
        guard !placed.isEmpty else { return }
        updateLayout { layout, at in
            for ref in placed { layout.unplace(ref, at: at) }
        }
        selection.removeAll { placed.contains($0) }
    }

    func saveRegion(id: String, name: String, x: Double, y: Double, w: Double, h: Double, color: String, notebookID: String? = nil) {
        // A move or a resize never unfolds a region the learner folded up, nor
        // unlocks it, nor sets its layout free.
        let existing = layout.regions[id]
        updateLayout { layout, at in
            var region = KnowledgeMapLayout.Region(name: name, x: x, y: y, w: w, h: h, color: color, at: at, notebookID: notebookID, collapsed: existing?.collapsed)
            region.locked = existing?.locked
            region.layout = existing?.layout
            layout.setRegion(id, region)
        }
    }

    /// Folds a region up, or opens it again: while folded it draws as its
    /// name and count and its cards are not drawn, but they stay placed
    /// where they are, and an arrow to one waits for it. One Undo step.
    func setRegionCollapsed(_ id: String, _ collapsed: Bool) {
        guard var region = layout.regions[id], region.isCollapsed != collapsed else { return }
        region.collapsed = collapsed ? true : nil
        updateLayout { layout, at in
            region.at = at
            layout.setRegion(id, region)
        }
        if collapsed { selection.removeAll { refsInRegion(id).contains($0) } }
    }

    /// A region named exactly as one notebook is called, and linked to none,
    /// becomes that notebook's frame: the learner set the notebook down, or
    /// named the region after it. Two notebooks of one name link neither.
    func linkNotebookRegions() {
        var byTitle: [String: [String]] = [:]
        for notebook in content.notebooks {
            byTitle[Self.titleKey(notebook.title), default: []].append(notebook.id)
        }
        let links = layout.regions.compactMap { id, region -> (String, String)? in
            guard region.notebookID == nil, !region.name.isEmpty,
                  let ids = byTitle[Self.titleKey(region.name)], ids.count == 1 else { return nil }
            return (id, ids[0])
        }
        guard !links.isEmpty else { return }
        updateLayout(undoable: false) { layout, at in
            for (id, notebookID) in links {
                guard var region = layout.regions[id] else { continue }
                region.notebookID = notebookID
                region.at = at
                layout.setRegion(id, region)
            }
        }
    }

    /// The unticked sources `takeUntickedOffFrames` last worked from; nil
    /// until the cards are first built on this launch.
    @ObservationIgnored private var framesUnticked: [String: Set<String>]?

    /// A source the learner unticked in a notebook (here, on another device
    /// or over MCP) leaves that notebook's frame: placed in it, it goes back
    /// off the plane, as it is not drawn there unplaced either. Works only
    /// when the ticks changed since it last ran (and once a launch, which
    /// tidies a frame laid out before this rule), so a source the learner
    /// sets down in the frame afterwards stays where they put it. The app's
    /// own write, never an Undo step.
    func takeUntickedOffFrames(_ unticked: [String: Set<String>]) {
        guard unticked != framesUnticked else { return }
        framesUnticked = unticked
        var off: [String] = []
        for (id, region) in layout.regions {
            guard let notebookID = region.notebookID, let left = unticked[notebookID] else { continue }
            for sourceID in left.sorted() {
                let ref = KnowledgeMap.ItemRef(kind: .source, id: sourceID).description
                if regionID(containing: ref) == id { off.append(ref) }
            }
        }
        guard !off.isEmpty else { return }
        updateLayout(undoable: false) { layout, at in
            for ref in off { layout.unplace(ref, at: at) }
        }
        selection.removeAll { off.contains($0) }
    }

    /// The notebook a region is the frame of, when it still exists.
    func notebook(ofRegion id: String) -> KnowledgeMapNotebook? {
        guard let notebookID = layout.regions[id]?.notebookID else { return nil }
        return content.notebooks.first { $0.id == notebookID }
    }

    nonisolated static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func renameRegion(_ id: String, to name: String) {
        guard var region = layout.regions[id] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard region.name != trimmed else { return }
        region.name = trimmed
        updateLayout { layout, at in
            region.at = at
            layout.setRegion(id, region)
        }
    }

    func recolorRegion(_ id: String, to color: String) {
        guard var region = layout.regions[id], region.color != color else { return }
        region.color = color
        updateLayout { layout, at in
            region.at = at
            layout.setRegion(id, region)
        }
    }

    func deleteRegion(_ id: String) {
        updateLayout { layout, at in layout.removeRegion(id, at: at) }
        if selectedRegionID == id { selectedRegionID = nil }
    }

    /// Draws an arrow between two ends: placed cards, or regions
    /// (`region:<regionID>`). A card off the map has nowhere for an arrow to
    /// start, so a card end must be placed. The arrow already drawn between
    /// the two is returned and left as it is.
    @discardableResult
    func addEdge(from: String, to: String) -> String? {
        if let existing = layout.edges.first(where: { $0.value.from == from && $0.value.to == to })?.key {
            return existing
        }
        return addEdge(from: from, to: to, label: "", tree: false)
    }

    func relabelEdge(_ id: String, to label: String) {
        guard var edge = layout.edges[id] else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edge.label != trimmed else { return }
        edge.label = trimmed
        updateLayout { layout, at in
            edge.at = at
            layout.setEdge(id, edge)
        }
    }

    func deleteEdge(_ id: String) {
        updateLayout { layout, at in layout.removeEdge(id, at: at) }
        if selectedEdgeID == id { selectedEdgeID = nil }
    }

    // MARK: Arranging on the learner's word

    // What the learner asks a chat or an assistant to do on the plane
    // (MCPTools+Canvas.swift): each is one write of theirs, an Undo step like
    // a drag. Cards already placed elsewhere move.

    private typealias Spot = KnowledgeMapArranging.Spot
    typealias Rect = KnowledgeMapArranging.Rect

    private func rect(of region: KnowledgeMapLayout.Region) -> Rect {
        Rect(x: region.x, y: region.y, w: region.w, h: region.h)
    }

    /// A card's height on the plane, as the renderer draws it: a folded card's
    /// title line, else the learner's own (`Placement.h`), else the kind's
    /// natural one (`naturalCardHeight(of:)`). The learner's own height holds
    /// the card's annotation too.
    func cardHeight(of ref: String) -> Double {
        if let placement = layout.placements[ref] {
            if placement.isFolded { return KnowledgeMap.foldedCardHeight }
            if let height = placement.h { return height }
        }
        return naturalCardHeight(of: ref)
    }

    /// A card's width on the plane: the learner's own (`Placement.w`), else a
    /// mind-map node's (`isMindMapNode`), else the usual 240.
    func cardWidth(of ref: String) -> Double {
        if let width = layout.placements[ref]?.w { return width }
        return mindMapNodeSize(of: ref)?.w ?? KnowledgeMap.cardWidth
    }

    /// The height a card has before the learner sizes it: a clip is as tall as
    /// its picture, a page as tall as the page, a picture as tall as its
    /// shape, a paper shown as its page (`Placement.page`, its PDF read) as
    /// tall as the page at the card's width over the foot naming it, a
    /// mind-map node as tall as its words, every other card the one size;
    /// and, for any card but an Idea, the room for its annotation under that.
    func naturalCardHeight(of ref: String) -> Double {
        if ref.hasPrefix("idea:") { return mindMapNodeSize(of: ref)?.h ?? KnowledgeMap.cardHeight }
        let width = cardWidth(of: ref)
        return kindCardHeight(of: ref, width: width) + KnowledgeMap.annotationHeight(layout.placements[ref]?.annotation, width: width)
    }

    /// What kind of card `ref` is makes it: the height of its picture, its page
    /// or its page face, else the one size.
    func kindCardHeight(of ref: String, width: Double) -> Double {
        if ref.hasPrefix("page:") {
            return KnowledgeMap.pageHeight(aspect: pageAspects[ref].flatMap { $0 > 0 ? $0 : nil })
        }
        if ref.hasPrefix("picture:") {
            return KnowledgeMap.pictureHeight(aspect: pictureAspects[ref].flatMap { $0 > 0 ? $0 : nil })
        }
        if let item = KnowledgeMap.ItemRef(ref), item.kind == .source,
           layout.placements[ref]?.page != nil, let face = pageFaces[item.id], face.pageCount > 0 {
            return KnowledgeMap.pageFaceHeight(aspect: face.aspect, width: width)
        }
        guard let item = KnowledgeMap.ItemRef(ref), item.kind == .clip, let clip = clips[item.id] else {
            return KnowledgeMap.cardHeight
        }
        if ReaderClip.isPassage(clip) { return KnowledgeMap.passageHeight }
        return KnowledgeMap.clipHeight(aspect: ReaderClip.aspect(of: clip), captioned: clipCaptions[clip.id] != nil)
    }

    /// The placed cards, but for `moving`, each as large as it is drawn.
    private func placedCards(excluding moving: Set<String>) -> [Rect] {
        layout.placements.filter { !moving.contains($0.key) }.map {
            Rect(x: $0.value.x, y: $0.value.y, w: cardWidth(of: $0.key), h: cardHeight(of: $0.key))
        }
    }

    /// What the plane holds, but for `moving`: the placed cards and the regions.
    func occupied(excluding moving: Set<String>) -> [Rect] {
        placedCards(excluding: moving) + layout.regions.values.map(rect(of:))
    }

    /// Where something set down "here" goes: the middle of what the learner
    /// is looking at, or right of everything when the Canvas has not been
    /// shown on this run.
    func arrivalCenter() -> KnowledgeMapArranging.Spot {
        if viewport.span.w > 0 { return Spot(x: viewport.center.x, y: viewport.center.y) }
        let all = occupied(excluding: [])
        guard let right = all.map({ $0.x + $0.w }).max(), let top = all.map(\.y).min() else { return Spot(x: 0, y: 0) }
        return Spot(x: right + 800, y: top + 300)
    }

    /// The card a ref is on the plane as: its top left.
    func spot(of ref: String) -> KnowledgeMapArranging.Spot? {
        layout.placements[ref].map { Spot(x: $0.x, y: $0.y) }
    }

    /// Sets `refs` down in region `id`, in free cells of its grid; the region
    /// grows to hold them. False when there is no such region.
    ///
    /// `style` is the look the cards take on (their size, fold, colour and
    /// page) and `annotations` the words under some of them (by ref), written
    /// with them in the same edit; the cells are laid out for the size they
    /// will have.
    @discardableResult
    func place(_ refs: [String], inRegion id: String, style: KnowledgeMapCardStyle? = nil, annotations: [String: String] = [:]) -> Bool {
        guard var region = layout.regions[id] else { return false }
        guard !refs.isEmpty else { return true }
        let sizes = sizes(of: refs, style: style, annotations: annotations)
        let laid = KnowledgeMapArranging.spots(
            heights: sizes.heights, widths: sizes.widths, in: rect(of: region), taken: placedCards(excluding: Set(refs))
        )
        updateLayout(pagesForPapers: style?.page != 0) { layout, at in
            for (ref, spot) in zip(refs, laid.spots) { layout.place(ref, x: spot.x, y: spot.y, at: at) }
            apply(style, annotations: annotations, to: refs, in: &layout, at: at)
            if laid.height > region.h {
                region.h = laid.height.rounded(.up)
                region.at = at
                layout.setRegion(id, region)
            }
        }
        return true
    }

    /// Sets `refs` down as one block in free space as near `center` as it
    /// can be, with a region around them when `regionName` is given (linked
    /// to `notebookID` as its frame). Returns the new region's id.
    @discardableResult
    func placeBlock(
        _ refs: [String],
        near center: KnowledgeMapArranging.Spot,
        regionName: String? = nil,
        notebookID: String? = nil,
        color: String? = nil,
        style: KnowledgeMapCardStyle? = nil,
        locked: Bool = false,
        annotations: [String: String] = [:]
    ) -> String? {
        let moving = Set(refs)
        let sizes = sizes(of: refs, style: style, annotations: annotations)
        let size = refs.isEmpty
            ? KnowledgeMapArranging.emptyRegionSize
            : { let f = KnowledgeMapArranging.block(heights: sizes.heights, widths: sizes.widths, origin: Spot(x: 0, y: 0)).frame; return (w: f.w, h: f.h) }()
        let origin = KnowledgeMapArranging.freeOrigin(size: size, near: center, occupied: occupied(excluding: moving))
        let laid = KnowledgeMapArranging.block(
            heights: sizes.heights, widths: sizes.widths,
            origin: Spot(x: origin.x + KnowledgeMapArranging.insetX, y: origin.y + KnowledgeMapArranging.insetY)
        )
        let frame = refs.isEmpty ? Rect(x: origin.x, y: origin.y, w: size.w, h: size.h) : laid.frame
        let id = regionName.map { _ in Self.newRegionID() }
        let tint = color ?? nextRegionColor()
        updateLayout(pagesForPapers: style?.page != 0) { layout, at in
            for (ref, spot) in zip(refs, laid.spots) { layout.place(ref, x: spot.x, y: spot.y, at: at) }
            apply(style, annotations: annotations, to: refs, in: &layout, at: at)
            if let id, let regionName {
                layout.setRegion(id, .init(
                    name: regionName,
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    color: tint,
                    at: at,
                    notebookID: notebookID,
                    locked: locked ? true : nil
                ))
            }
        }
        return id
    }

    /// Each card's height and width as it will be drawn once set down with
    /// `style` and `annotations`: the style's own where it names one, else
    /// the card's now, or (a card not placed yet) what it will be given: a
    /// paper's page when it is set down showing one, a note's room under it.
    private func sizes(of refs: [String], style: KnowledgeMapCardStyle?, annotations: [String: String]) -> (heights: [Double], widths: [Double]?) {
        let widths: [Double]? = (style?.w == nil && !refs.contains { layout.placements[$0]?.w != nil }) ? nil : refs.map { ref in
            style?.w.map { min(max($0, KnowledgeMap.cardWidthRange.lowerBound), KnowledgeMap.cardWidthRange.upperBound) } ?? cardWidth(of: ref)
        }
        let heights = refs.enumerated().map { index, ref in
            heightWhenSetDown(ref, width: widths?[index] ?? KnowledgeMap.cardWidth, style: style, annotation: annotations[ref])
        }
        return (heights, widths)
    }

    /// Writes `style` and `annotations` onto the placements of `refs`.
    private func apply(_ style: KnowledgeMapCardStyle?, annotations: [String: String] = [:], to refs: [String], in row: inout KnowledgeMapLayout, at: Double) {
        guard style?.isEmpty == false || !annotations.isEmpty else { return }
        for ref in refs {
            guard var placement = row.placements[ref] else { continue }
            var edit = style?.edit(for: ref) ?? KnowledgeMapPlacementStyle(ref: ref)
            if let words = annotations[ref] { edit.annotation = .set(words) }
            guard !edit.isKeep else { continue }
            placement = placement.styled(by: edit)
            placement.at = at
            row.setPlacement(ref, placement)
        }
    }

    /// Draws a region around cards already placed, moving none of them.
    func makeRegion(around refs: [String], name: String, notebookID: String? = nil, color: String? = nil, locked: Bool = false) -> String? {
        let rects = refs.compactMap { ref in layout.placements[ref].map { Rect(x: $0.x, y: $0.y, w: cardWidth(of: ref), h: cardHeight(of: ref)) } }
        guard rects.count == refs.count, let first = rects.first else { return nil }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        let id = Self.newRegionID()
        let tint = color ?? nextRegionColor()
        updateLayout { layout, at in
            layout.setRegion(id, .init(
                name: name,
                x: bounds.x - KnowledgeMapArranging.insetX, y: bounds.y - KnowledgeMapArranging.insetY,
                w: bounds.w + KnowledgeMapArranging.insetX * 2, h: bounds.h + KnowledgeMapArranging.insetY + KnowledgeMapArranging.insetX,
                color: tint,
                at: at,
                notebookID: notebookID,
                locked: locked ? true : nil
            ))
        }
        return id
    }

    /// Sets the pages of a PDF source down as one row, left to right, in a
    /// region named for the paper, as near `center` (the middle of the view
    /// by default) as free space allows. A page already on the canvas stays
    /// where it is. `aspects` is each page's width over its height, so every
    /// card is as tall as its page. Returns the region and the cards set
    /// down, or nil when every page was on the canvas already.
    @discardableResult
    func layOutPages(
        sourceID: String,
        pages: [Int],
        aspects: [Int: Double],
        regionName: String,
        near center: KnowledgeMapArranging.Spot? = nil,
        color: String? = nil,
        collapsed: Bool = false
    ) -> (regionID: String, refs: [String])? {
        let fresh = pages.filter { layout.placements[KnowledgeMap.pageRef(sourceID: sourceID, page: $0)] == nil }
        guard !fresh.isEmpty else { return nil }
        let refs = fresh.map { KnowledgeMap.pageRef(sourceID: sourceID, page: $0) }
        for (page, ref) in zip(fresh, refs) { pageAspects[ref] = aspects[page] ?? pageAspects[ref] ?? 0 }
        return layOutRow(refs, regionName: regionName, near: center, color: color, collapsed: collapsed)
    }

    /// Sets cards down as one row, left to right, in a region named
    /// `regionName`, as near `center` as free space allows: a paper's pages,
    /// or its figures ("Figures only"). A card on the canvas already stays
    /// where it is. Returns the region and the cards set down, or nil when
    /// every card was on the canvas already.
    @discardableResult
    func layOutRow(
        _ wanted: [String],
        regionName: String,
        near center: KnowledgeMapArranging.Spot? = nil,
        color: String? = nil,
        collapsed: Bool = false
    ) -> (regionID: String, refs: [String])? {
        let refs = wanted.filter { layout.placements[$0] == nil }
        guard !refs.isEmpty else { return nil }
        let heights = refs.map(cardHeight(of:))
        let size = KnowledgeMapArranging.row(heights: heights, origin: Spot(x: 0, y: 0)).frame
        // The row starts at the left of what the learner is looking at when it
        // is wider than the view (so page 1 is in view and the rest runs off
        // to the right), and is centred when it fits.
        let middle = center ?? arrivalCenter()
        let halfView = viewport.span.w > 0 ? viewport.span.w / 2 - 80 : size.w / 2
        let left = (middle.x - min(size.w / 2, halfView)).rounded()
        let origin = KnowledgeMapArranging.freeRowOrigin(
            size: (size.w, size.h), left: left, top: (middle.y - size.h / 2).rounded(), occupied: occupied(excluding: Set(refs))
        )
        let laid = KnowledgeMapArranging.row(
            heights: heights,
            origin: Spot(x: origin.x + KnowledgeMapArranging.insetX, y: origin.y + KnowledgeMapArranging.insetY)
        )
        let id = Self.newRegionID()
        let tint = color ?? nextRegionColor()
        updateLayout { layout, at in
            for (ref, spot) in zip(refs, laid.spots) { layout.place(ref, x: spot.x, y: spot.y, at: at) }
            layout.setRegion(id, .init(
                name: regionName,
                x: laid.frame.x, y: laid.frame.y, w: laid.frame.w, h: laid.frame.h,
                color: tint,
                at: at,
                collapsed: collapsed ? true : nil
            ))
        }
        return (id, refs)
    }

    /// The cards a region carries when it moves: those whose middle its
    /// frame holds, as the renderer's move takes them.
    func refsInRegion(_ id: String) -> [String] {
        guard let region = layout.regions[id] else { return [] }
        return layout.placements.filter { _, spot in
            let middle = Self.regionMiddle(of: spot)
            return middle.x >= region.x && middle.x <= region.x + region.w && middle.y >= region.y && middle.y <= region.y + region.h
        }.keys.sorted()
    }

    /// The point of a placed card a region holds it by: its middle. A card
    /// the learner sized or folded is held by the middle of that size; every
    /// other card by the usual 240 by 120, as the renderer reads it.
    nonisolated static func regionMiddle(of placement: KnowledgeMapLayout.Placement) -> (x: Double, y: Double) {
        let width = placement.w ?? KnowledgeMap.cardWidth
        let height = placement.isFolded ? KnowledgeMap.foldedCardHeight : (placement.h ?? KnowledgeMap.cardHeight)
        return (placement.x + width / 2, placement.y + height / 2)
    }

    /// Moves, resizes, recolours, renames or (un)links a region in one write;
    /// a move carries its cards. Nil leaves that part as it is.
    func editRegion(
        _ id: String,
        name: String? = nil,
        color: String? = nil,
        origin: KnowledgeMapArranging.Spot? = nil,
        size: (w: Double, h: Double)? = nil,
        notebookID: String?? = nil,
        collapsed: Bool? = nil
    ) {
        guard var region = layout.regions[id] else { return }
        let carried = origin == nil ? [] : refsInRegion(id)
        let dx = origin.map { $0.x - region.x } ?? 0, dy = origin.map { $0.y - region.y } ?? 0
        if let name { region.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let color { region.color = color }
        if let origin { region.x = origin.x; region.y = origin.y }
        if let size { region.w = max(size.w, KnowledgeMap.cardWidth + 40); region.h = max(size.h, KnowledgeMap.cardHeight + 40) }
        if let notebookID { region.notebookID = notebookID }
        if let collapsed { region.collapsed = collapsed ? true : nil }
        updateLayout { layout, at in
            for ref in carried {
                guard let spot = layout.placements[ref] else { continue }
                layout.place(ref, x: spot.x + dx, y: spot.y + dy, at: at)
            }
            region.at = at
            layout.setRegion(id, region)
        }
    }

    /// Deletes a region; with `takingCardsOff` everything inside it goes too,
    /// in the same write: its cards leave the plane and the regions drawn
    /// inside it go. One Undo brings the lot back.
    func deleteRegion(_ id: String, takingCardsOff: Bool) {
        let cards = takingCardsOff ? refsInRegion(id) : []
        let inner = takingCardsOff ? layout.regionIDsInside(id) : []
        updateLayout { layout, at in
            for ref in cards { layout.unplace(ref, at: at) }
            for region in inner { layout.removeRegion(region, at: at) }
            layout.removeRegion(id, at: at)
        }
        if let selected = selectedRegionID, selected == id || inner.contains(selected) { selectedRegionID = nil }
        selection.removeAll { cards.contains($0) }
    }

    static func newRegionID() -> String {
        "r" + UUID().uuidString.prefix(8).lowercased()
    }

    /// The tint the renderer gives the next region it draws.
    func nextRegionColor() -> String {
        Self.regionColors[layout.regions.count % Self.regionColors.count]
    }

    // MARK: Renderer commands

    func send(_ action: KnowledgeMapCommand.Action) {
        commands.append(KnowledgeMapCommand(action: action))
    }

    /// The canvas takes the queued commands once it has run them.
    func takeCommands() -> [KnowledgeMapCommand] {
        let taken = commands
        commands.removeAll()
        return taken
    }

    // MARK: Lenses

    enum LensError: LocalizedError, Equatable {
        case empty
        case noKnownItems

        var errorDescription: String? {
            switch self {
            case .empty: return "The lens names no cards."
            case .noKnownItems: return "None of the lens's cards are in the library on the canvas."
            }
        }
    }

    /// Lays the lens out around what the learner is looking at and shows it.
    /// Returns the lens shown; throws when it would show nothing.
    @discardableResult
    func apply(_ request: KnowledgeMapLensRequest) throws -> KnowledgeMapLens {
        guard !request.items.isEmpty else { throw LensError.empty }
        // Before the renderer has reported a view (the Map never shown on this
        // run), the lens lands left of the shore rather than on top of it.
        let center = viewport.span.w > 0 ? viewport.center : (x: -4000.0, y: 0.0)
        let laid = KnowledgeMapLens.laidOut(
            request, center: center, height: { self.cardHeight(of: $0.description) },
            known: { nodesByRef[$0.description] != nil }
        )
        guard !laid.positions.isEmpty else { throw LensError.noKnownItems }
        clearProposals() // Proposals (WP-B1): a lens and proposals never show together.
        lens = laid
        lensRevision &+= 1
        return laid
    }

    func clearLens() {
        guard lens != nil else { return }
        lens = nil
        lensRevision &+= 1
    }

    /// The learner keeps the lens: its spots become their placements and its
    /// groups their regions, and their own map shows again with them in it.
    func keepLens() {
        guard let lens else { return }
        updateLayout { layout, at in
            for (ref, spot) in lens.positions {
                layout.place(ref, x: spot.x, y: spot.y, at: at)
            }
            for (index, frame) in lens.frames.enumerated() {
                let id = "r" + UUID().uuidString.prefix(8).lowercased()
                layout.setRegion(id, .init(
                    name: frame.label,
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    color: Self.regionColors[index % Self.regionColors.count],
                    at: at
                ))
            }
        }
        self.lens = nil
        lensRevision &+= 1
    }

    // MARK: What is on the plane

    /// How many cards the learner has placed that the library still holds.
    var placedCount: Int {
        layout.placements.keys.reduce(0) { $0 + (nodesByRef[$1] != nil ? 1 : 0) }
    }

    /// The open Ideas not on the map yet, newest first: the add box's Recent
    /// ideas and the Library's Ideas.
    var unplacedIdeaRefs: [String] {
        content.nodes.filter { $0.kind == "idea" && layout.placements[$0.ref] == nil }.map(\.ref)
    }

    /// An Idea's evidence: the sources and Docs linked to it.
    func evidence(of ideaRef: String) -> [String] {
        content.links.filter { $0.kind == "idea" && $0.a == ideaRef }.map(\.b)
    }

    /// The renderer's region tints, offered in the region inspector.
    static let regionColors = ["#7F77DD", "#1D9E75", "#D85A30", "#D4537E", "#BA7517", "#378ADD", "#639922", "#888780"]

    // MARK: Content

    /// Rebuilds the cards from the library on this Mac: every active source,
    /// every Doc and other thing a notebook made, and every open Idea, with
    /// what each card says at each zoom level, and
    /// the computed relations the renderer draws from a focused card.
    func rebuildContent(
        articles: [StudioArticle],
        ideas: [IdeaRecord],
        notebooks: [LearningGoalRecord],
        chats: [ReviewSessionRecord],
        artifacts: [ArtifactRecord],
        firstHighlights: [String: String],
        groupTitles: [String: String] = [:],
        unticked: [String: Set<String>] = [:],
        clips: [SourceHighlight] = [],
        passagePages: [String: Int] = [:],
        pages: [KnowledgeMapPageCard] = [],
        captions: [String: String] = [:],
        canvases: [KnowledgeMapCanvas] = [],
        pictures: [KnowledgeMapPictureCard] = []
    ) {
        clipCaptions = captions
        // A canvas holds no shortcut to itself.
        let otherCanvases = canvases.filter { $0.id != mapID }
        pictureAspects = Dictionary(
            pictures.map { ($0.ref, $0.aspect ?? 0) },
            uniquingKeysWith: { first, _ in first }
        )
        let built = Self.content(
            articles: articles,
            ideas: ideas,
            notebooks: notebooks,
            chats: chats,
            artifacts: artifacts,
            firstHighlights: firstHighlights,
            groupTitles: groupTitles,
            unticked: unticked,
            clips: clips,
            passagePages: passagePages,
            pages: pages,
            captions: captions,
            canvases: otherCanvases,
            pictures: pictures,
            pageFaces: pageFaces
        )
        self.clips = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        notebookContexts = Dictionary(
            notebooks.map { ($0.id, Self.notebookContext($0, firstHighlights: firstHighlights)) },
            uniquingKeysWith: { first, _ in first }
        )
        guard built != content else { return }
        content = built
        nodesByRef = Dictionary(built.nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        contentRevision &+= 1
    }

    /// What the Canvas Summaries model reads about a notebook, so a frame's
    /// takeaways come from what the notebook says and what the learner marked
    /// in its sources, never from titles alone: its description, research
    /// questions, the start of its notes, and the first highlight of up to
    /// twelve of its sources. Empty when the notebook has none of these.
    nonisolated static func notebookContext(_ notebook: LearningGoalRecord, firstHighlights: [String: String]) -> String {
        var parts: [String] = []
        if let summary = notebook.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append("Description: " + summary)
        }
        let questions = (notebook.researchQuestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !questions.isEmpty {
            parts.append("Research questions:\n" + questions.prefix(6).map { "- " + $0 }.joined(separator: "\n"))
        }
        if let notes = notebook.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append("Notes (start):\n" + String(notes.prefix(1500)))
        }
        let highlights = notebook.approvedSourceIDs.compactMap { firstHighlights[$0] }.prefix(12)
        if !highlights.isEmpty {
            parts.append("Highlights the learner made in its sources:\n" + highlights.map { "- " + $0 }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Kept apart from the model so a test builds it from plain records.
    /// `unticked` is each notebook's unticked sources by Notebook id
    /// (`NotebookChatSelection`): a notebook's frame holds only what the
    /// notebook reads now.
    nonisolated static func content(
        articles: [StudioArticle],
        ideas: [IdeaRecord],
        notebooks: [LearningGoalRecord],
        chats: [ReviewSessionRecord],
        artifacts: [ArtifactRecord],
        firstHighlights: [String: String],
        groupTitles: [String: String] = [:],
        unticked: [String: Set<String>] = [:],
        clips: [SourceHighlight] = [],
        passagePages: [String: Int] = [:],
        pages: [KnowledgeMapPageCard] = [],
        captions: [String: String] = [:],
        canvases: [KnowledgeMapCanvas] = [],
        pictures: [KnowledgeMapPictureCard] = [],
        pageFaces: [String: KnowledgeMapPageFace] = [:]
    ) -> KnowledgeMapContent {
        let sources = articles.filter { $0.status == .active && !$0.isHidden }
        let sourceIDs = Set(sources.map(\.id))

        var notebooksBySource: [String: [String]] = [:]
        for notebook in notebooks {
            for item in notebook.items where sourceIDs.contains(item.sourceID) {
                let title = NotebookTitle(notebook.title).text
                if notebooksBySource[item.sourceID]?.contains(title) != true {
                    notebooksBySource[item.sourceID, default: []].append(title)
                }
            }
        }
        var chatsBySource: [String: Int] = [:]
        for chat in chats {
            for id in Set(chat.sourceIDs) where sourceIDs.contains(id) { chatsBySource[id, default: 0] += 1 }
        }
        var docsBySource: [String: Int] = [:]
        for artifact in artifacts {
            for id in Set(artifact.sourceIDs) where sourceIDs.contains(id) { docsBySource[id, default: 0] += 1 }
        }

        var nodes: [KnowledgeMapNode] = []
        nodes.reserveCapacity(sources.count + ideas.count + artifacts.count)
        for source in sources {
            let inNotebooks = notebooksBySource[source.id] ?? []
            var detail: [String] = []
            if !inNotebooks.isEmpty { detail.append("In " + inNotebooks.joined(separator: ", ")) }
            if let chats = chatsBySource[source.id] { detail.append(chats == 1 ? "1 chat" : "\(chats) chats") }
            if let docs = docsBySource[source.id] { detail.append(docs == 1 ? "1 page" : "\(docs) pages") }
            if let quote = firstHighlights[source.id] { detail.append("“\(quote)”") }
            // A paper's PDF read on this Mac gives its card the page to draw.
            let face = pageFaces[source.id].flatMap { $0.pageCount > 0 ? $0 : nil }
            nodes.append(KnowledgeMapNode(
                ref: KnowledgeMap.ItemRef(kind: .source, id: source.id).description,
                kind: "source",
                type: mapType(source.sourceType),
                title: source.title,
                sub: subtitle(source, groupTitle: source.parentGroup.flatMap { groupTitles[$0] }),
                detail: detail,
                shore: inNotebooks.first ?? "Not in a notebook",
                group: source.parentGroup,
                groupTitle: source.parentGroup.flatMap { groupTitles[$0] },
                pages: face?.pageCount,
                aspect: face?.aspect,
                read: source.isRead ? true : nil
            ))
        }
        let notebookTitles = Dictionary(notebooks.map { ($0.id, NotebookTitle($0.title).text) }, uniquingKeysWith: { first, _ in first })
        // What notebooks made: Docs, reports, sites, animations, audio
        // overviews and readings. A source's private deck of cards to check is
        // the learner's memory state, never a card here.
        for artifact in mapArtifacts(artifacts) {
            let home = artifact.homeNotebookID.flatMap { notebookTitles[$0] }
                ?? artifact.linkedNotebookIDs.lazy.compactMap { notebookTitles[$0] }.first
            let cited = artifact.sourceIDs.filter { sourceIDs.contains($0) }.count
            var parts = [docTypeName(artifact)]
            if cited > 0 { parts.append(cited == 1 ? "1 source" : "\(cited) sources") }
            nodes.append(KnowledgeMapNode(
                ref: KnowledgeMap.ItemRef(kind: .doc, id: artifact.id).description,
                kind: "doc",
                type: docType(artifact),
                title: artifact.title.isEmpty ? "Untitled" : artifact.title,
                sub: parts.joined(separator: " · "),
                detail: home.map { ["In " + $0] } ?? [],
                shore: home ?? "Pages"
            ))
        }
        for idea in ideas where idea.status == .open {
            let notebook = idea.links.first { $0.kind == .notebook }.flatMap { notebookTitles[$0.targetID] }
            let note = idea.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            nodes.append(KnowledgeMapNode(
                ref: KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description,
                kind: "idea",
                type: "idea",
                title: idea.title,
                sub: note.isEmpty ? KnowledgeMapAddSearch.noteLessIdeaLine : note,
                detail: [],
                shore: notebook ?? "Ideas"
            ))
        }

        nodes += shortcutNodes(chats: chats, canvases: canvases, pictures: pictures, notebookTitles: notebookTitles)

        // Clips cut out of the shown sources' pages: as wide as any card and as
        // tall as the picture, named by the figure they hold, with the
        // learner's note under it.
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var clipLinks: [(clip: String, source: String)] = []
        for clip in clips {
            guard let source = sourcesByID[clip.sourceID] else { continue }
            let ref = KnowledgeMap.ItemRef(kind: .clip, id: clip.id).description
            let sourceRef = KnowledgeMap.ItemRef(kind: .source, id: source.id).description
            let byline = paperByline(source)
            let note = clip.note.trimmingCharacters(in: .whitespacesAndNewlines)
            // A passage: the quoted words, and the paper it came from.
            if ReaderClip.isPassage(clip) {
                let words = clip.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                let page = ReaderClip.passagePage(of: clip) ?? passagePages[clip.id].flatMap { $0 > 0 ? $0 : nil }
                nodes.append(KnowledgeMapNode(
                    ref: ref,
                    kind: "clip",
                    type: "clip",
                    title: page.map { "p. \($0) · \(source.title)" } ?? source.title,
                    sub: page.map { "\(source.title) · p. \($0)" } ?? source.title,
                    detail: note.isEmpty ? [] : [note],
                    shore: notebooksBySource[source.id]?.first ?? "Clips",
                    h: KnowledgeMap.passageHeight,
                    quote: String(words.prefix(600)),
                    src: sourceRef,
                    byline: byline
                ))
                clipLinks.append((ref, KnowledgeMap.ItemRef(kind: .source, id: source.id).description))
                continue
            }
            guard let page = ReaderClip.page(of: clip) else { continue }
            nodes.append(KnowledgeMapNode(
                ref: ref,
                kind: "clip",
                type: "clip",
                title: ReaderClip.title(of: clip),
                sub: "\(source.title) · p. \(page)",
                detail: note.isEmpty ? [] : [note],
                shore: notebooksBySource[source.id]?.first ?? "Clips",
                h: KnowledgeMap.clipHeight(aspect: ReaderClip.aspect(of: clip), captioned: captions[clip.id] != nil),
                caption: captions[clip.id],
                src: sourceRef,
                byline: byline
            ))
            clipLinks.append((ref, KnowledgeMap.ItemRef(kind: .source, id: source.id).description))
        }

        // Pages of PDF sources, one card each, as tall as the page: drawn from
        // the PDF itself, so nothing about them is stored but where they sit.
        for page in pages {
            guard let item = KnowledgeMap.ItemRef(page.ref), let parts = item.pageParts,
                  let source = sourcesByID[parts.sourceID] else { continue }
            nodes.append(KnowledgeMapNode(
                ref: page.ref,
                kind: "page",
                type: "page",
                title: "Page \(parts.page)",
                sub: source.title,
                detail: [],
                shore: notebooksBySource[source.id]?.first ?? "Pages",
                h: KnowledgeMap.pageHeight(aspect: page.aspect),
                src: KnowledgeMap.ItemRef(kind: .source, id: source.id).description,
                byline: paperByline(source)
            ))
            clipLinks.append((page.ref, KnowledgeMap.ItemRef(kind: .source, id: source.id).description))
        }

        // Relations: sources discussed in one chat, cited by one Doc, or
        // linked by one Idea. A chat or Doc over very many sources says little
        // about any pair, so it is left out.
        var seen: Set<String> = []
        var links: [KnowledgeMapLink] = []
        func link(_ a: String, _ b: String, _ kind: String) {
            guard a != b, links.count < 20_000 else { return }
            let key = a < b ? a + "|" + b : b + "|" + a
            guard seen.insert(key).inserted else { return }
            links.append(KnowledgeMapLink(a: a, b: b, kind: kind))
        }
        func pairs(_ ids: [String], kind: String) {
            let refs = Array(Set(ids.filter { sourceIDs.contains($0) })).sorted()
                .map { KnowledgeMap.ItemRef(kind: .source, id: $0).description }
            guard refs.count >= 2, refs.count <= 12 else { return }
            for i in 0..<refs.count { for j in (i + 1)..<refs.count { link(refs[i], refs[j], kind) } }
        }
        for chat in chats { pairs(chat.sourceIDs, kind: "chat") }
        // A clip and the source it was cut from.
        for pair in clipLinks { link(pair.clip, pair.source, "clip") }
        for artifact in mapArtifacts(artifacts) {
            let docRef = KnowledgeMap.ItemRef(kind: .doc, id: artifact.id).description
            for id in Set(artifact.sourceIDs) where sourceIDs.contains(id) {
                link(docRef, KnowledgeMap.ItemRef(kind: .source, id: id).description, "doc")
            }
        }
        // An Idea's sources and Docs: its evidence, which hangs under it.
        let docIDs = Set(mapArtifacts(artifacts).map(\.id))
        for idea in ideas where idea.status == .open {
            let ideaRef = KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description
            for target in idea.links {
                if target.kind == .source, sourceIDs.contains(target.targetID) {
                    link(ideaRef, KnowledgeMap.ItemRef(kind: .source, id: target.targetID).description, "idea")
                } else if target.kind == .artifact, docIDs.contains(target.targetID) {
                    link(ideaRef, KnowledgeMap.ItemRef(kind: .doc, id: target.targetID).description, "idea")
                }
            }
        }
        // Each notebook with the cards it holds, for the regions linked to it:
        // its ticked sources and what it made. A source the learner unticked
        // is not for now, so its frame does not draw it.
        let shown = Set(nodes.map(\.ref))
        let madeThings = mapArtifacts(artifacts)
        let notebookEntries: [KnowledgeMapNotebook] = notebooks.map { notebook in
            let left = unticked[notebook.id] ?? []
            var refs = notebook.approvedSourceIDs.filter { !left.contains($0) }.map { KnowledgeMap.ItemRef(kind: .source, id: $0).description }
            for artifact in madeThings where artifact.homeNotebookID == notebook.id || artifact.linkedNotebookIDs.contains(notebook.id) {
                refs.append(KnowledgeMap.ItemRef(kind: .doc, id: artifact.id).description)
            }
            return KnowledgeMapNotebook(
                id: notebook.id,
                title: NotebookTitle(notebook.title).text,
                summary: notebook.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                refs: refs.filter { shown.contains($0) }
            )
        }
        return KnowledgeMapContent(nodes: nodes, links: links, notebooks: notebookEntries)
    }

    /// The made things the Map shows: not archived, not hidden, never a
    /// card deck.
    nonisolated static func mapArtifacts(_ artifacts: [ArtifactRecord]) -> [ArtifactRecord] {
        artifacts.filter { !$0.isArchived && !$0.isHidden && !$0.isCardDeck }
    }

    nonisolated static func docType(_ artifact: ArtifactRecord) -> String {
        if artifact.isLinked { return "site" }
        switch artifact.kind {
        case .animation: return "animation"
        case .audioOverview: return "audio"
        case .mnemonicReading: return "reading"
        case .flashcards, nil: return "doc"
        }
    }

    nonisolated static func docTypeName(_ artifact: ArtifactRecord) -> String {
        switch docType(artifact) {
        case "site": return "Site"
        case "animation": return "Animation"
        case "audio": return "Audio overview"
        case "reading": return "Reading"
        default: return "Page"
        }
    }

    nonisolated static func mapType(_ type: StudioSourceType) -> String {
        switch type {
        case .paper: return "paper"
        case .podcast: return "podcast"
        case .video: return "video"
        case .book: return "book"
        case .meeting: return "meeting"
        case .course: return "course"
        case .xPost: return "xPost"
        case .article, .manual, .unclassified: return "article"
        }
    }

    /// A paper's banner line as the Library shows it: "de Baat & Levin ·
    /// bioRxiv · 2026". Nil when the paper names none of them.
    nonisolated static func paperByline(_ source: StudioArticle) -> String? {
        let parts = [
            (source.author, StudioArticle.unknownPaperAuthor),
            (source.journal, StudioArticle.unknownPaperJournal),
            (source.publishedYear, StudioArticle.unknownPaperYear),
        ].compactMap { value, unknown -> String? in
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != unknown else { return nil }
            return text
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func subtitle(_ source: StudioArticle, groupTitle: String? = nil) -> String {
        var parts: [String] = []
        // A chapter, an episode or a lecture names what it belongs to first.
        if let groupTitle = groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !groupTitle.isEmpty {
            parts.append(groupTitle)
        }
        if let author = source.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty, author != StudioArticle.unknownPaperAuthor {
            parts.append(author)
        }
        if let year = source.publishedYear?.trimmingCharacters(in: .whitespacesAndNewlines),
           !year.isEmpty, year != StudioArticle.unknownPaperYear {
            parts.append(year)
        }
        if let journal = source.journal?.trimmingCharacters(in: .whitespacesAndNewlines),
           !journal.isEmpty, journal != StudioArticle.unknownPaperJournal {
            parts.append(journal)
        }
        // A local file's "domain" is its path on this Mac: never a subtitle.
        if parts.isEmpty, !source.domain.isEmpty, !source.domain.hasPrefix("/"), !source.domain.hasPrefix("~") {
            parts.append(source.domain)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Levels of abstraction

    /// The clusters the Map shows a summary for: each region the learner drew
    /// holding at least `minimumCards` placed cards. Cards not placed are not
    /// on the plane, so they have nothing to summarise.
    func clusters() -> [KnowledgeMapSummaries.Cluster] {
        var result: [KnowledgeMapSummaries.Cluster] = []
        var byRegion: [String: [String]] = [:]
        for ref in layout.placements.keys where nodesByRef[ref] != nil {
            if let region = regionID(containing: ref) { byRegion[region, default: []].append(ref) }
        }
        for (id, region) in layout.regions {
            var refs = byRegion[id] ?? []
            var name = region.name.isEmpty ? "Untitled region" : region.name
            var context = ""
            // A notebook's frame also draws the notebook's cards not placed
            // anywhere, and its takeaways read what the notebook says.
            if let notebook = notebook(ofRegion: id) {
                let unplaced = notebook.refs.filter { layout.placements[$0] == nil && !refs.contains($0) }
                refs += unplaced
                name = notebook.title
                context = notebookContexts[notebook.id] ?? ""
            }
            guard refs.count >= KnowledgeMapSummaries.minimumCards else { continue }
            result.append(.init(key: "r:" + id, name: name, titles: refs.map(title(of:)), context: context))
        }
        return result.sorted { $0.key < $1.key }
    }

    /// The clusters whose summary is missing or was written from other cards.
    func staleClusters() -> [KnowledgeMapSummaries.Cluster] {
        clusters().filter { summaries[$0.key]?.fingerprint != $0.fingerprint }
    }

    /// A summary request's number; only the latest one goes on to the model,
    /// so a burst of moves asks once.
    func beginSummaryRequest() -> Int {
        summaryRequest &+= 1
        return summaryRequest
    }

    func isLatestSummaryRequest(_ request: Int) -> Bool { request == summaryRequest }

    func storeSummaries(_ written: [String: KnowledgeMapSummaries.Summary]) {
        guard !written.isEmpty else { return }
        summaries.merge(written) { _, new in new }
        KnowledgeMapSummaries.saveCache(summaries)
        summariesRevision &+= 1
    }

    /// What the renderer draws under each name: notebook clusters by name,
    /// regions by id, each with its short and long line.
    struct SummariesPayload: Encodable {
        struct Lines: Encodable { var short: String; var long: String; var takeaways: [String] }
        var clusters: [String: Lines]
        var regions: [String: Lines]
    }

    var summariesPayload: SummariesPayload {
        var clusters: [String: SummariesPayload.Lines] = [:]
        var regions: [String: SummariesPayload.Lines] = [:]
        for (key, summary) in summaries {
            let lines = SummariesPayload.Lines(short: summary.short, long: summary.long, takeaways: summary.takeaways ?? [])
            if key.hasPrefix("nb:") { clusters[String(key.dropFirst(3))] = lines }
            if key.hasPrefix("r:") { regions[String(key.dropFirst(2))] = lines }
        }
        return SummariesPayload(clusters: clusters, regions: regions)
    }

    /// What is on screen, for the caption: up to 40 cards with who and when.
    func captionView() -> KnowledgeMapSummaries.View {
        let cards = viewport.visibleRefs.prefix(40).compactMap { ref -> String? in
            guard let node = nodesByRef[ref] else { return nil }
            return node.sub.isEmpty ? node.title : node.title + " — " + node.sub
        }
        let regions = viewport.visibleRegionIDs.compactMap { layout.regions[$0]?.name }.filter { !$0.isEmpty }
        return .init(level: viewport.level, regions: regions, cards: cards)
    }

    func cachedCaption(for key: Int) -> String? { captionCache[key] }

    func setCaption(_ caption: String, for key: Int) {
        captionCache[key] = caption
        if captionCache.count > 200 { captionCache.removeAll() }
        if viewport.captionKey == key, describesView { viewCaption = caption }
    }

    // MARK: Reading the map, for the chat

    func title(of ref: String) -> String {
        nodesByRef[ref]?.title ?? ref
    }

    /// The region a placed card sits in: the smallest one holding its centre.
    func regionID(containing ref: String) -> String? {
        guard let spot = layout.placements[ref] else { return nil }
        let (cx, cy) = Self.regionMiddle(of: spot)
        return layout.regions
            .filter { cx >= $0.value.x && cx <= $0.value.x + $0.value.w && cy >= $0.value.y && cy <= $0.value.y + $0.value.h }
            .min { $0.value.w * $0.value.h < $1.value.w * $1.value.h }?
            .key
    }
}
