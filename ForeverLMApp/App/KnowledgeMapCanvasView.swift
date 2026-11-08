import SwiftUI
import UniformTypeIdentifiers
import WebKit

// The Mac's side of the parity build (docs/knowledge-map-design.md, "The
// renderer's design"): the messages the page posts for sizing, arrow styles,
// writing in place, menus, keys and clicks are answered in
// `KnowledgeMapCanvasView+Parity.swift`, and the native menu is built in
// `KnowledgeMapCanvasMenu.swift`.

/// The Map's plane: the renderer in `KnowledgeMapResources/` (built from
/// `Web/KnowledgeMap/`), in a web view. It draws and takes pointer input; every
/// change the learner makes comes back as a message, and the model writes it.
///
/// One message handler, `knowledgeMap`, carries `{type, …}`; the page's
/// `window.knowledgeMap` takes the model's layout, cards, lens and commands.
/// The revisions are passed in so a change to any of them updates the view.
struct KnowledgeMapCanvasView: NSViewRepresentable {
    let model: KnowledgeMapModel
    let layoutRevision: Int
    let contentRevision: Int
    let lensRevision: Int
    let summariesRevision: Int
    let commandCount: Int
    let onOpen: (String) -> Void
    let onNoteRequested: (Double, Double) -> Void
    /// Sources, Docs and notebooks dragged in from the rest of the app,
    /// dropped at a point in the view.
    let onDrop: (KnowledgeMapWebView.Drop) -> Void
    /// Sources or Docs dropped on a placed Idea: link them as its evidence.
    let onLinkEvidence: (_ ideaRef: String, _ refs: [String]) -> Void
    /// A Map pane's canvas, or the window the Map was extended to on another
    /// display, which runs no queued commands and reports no view.
    var role: Role = .pane
    /// Filled with the coordinator, for what addresses this canvas itself.
    var handle: KnowledgeMapCanvasHandle?
    // MARK: Proposals and faces (WP-B1)
    var proposalsRevision = 0
    var facesRevision = 0
    // MARK: Memory (WP-B2)
    /// `KnowledgeMapMemory.syncToken`: the Memory layer and a review in place.
    var memorySync = 0
    /// The window this canvas is in: a review in place runs in its own window's canvas only.
    var windowID: UUID?
    /// The app around the canvas: what opening a card beside the Canvas, a
    /// written Idea and a menu's items reach for beyond the model.
    @Environment(StudioViewModel.self) private var viewModel
    @Environment(StudioWindowState.self) private var windowState

    enum Role {
        case pane
        case extensionWindow
    }

    static let messageHandlerName = "knowledgeMap"

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, role: role, onOpen: onOpen, onNoteRequested: onNoteRequested, onLinkEvidence: onLinkEvidence)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.websiteDataStore = .nonPersistent()
        SharedWebKit.applySharedProcessPool(to: configuration)
        SharedWebKit.disableSystemWritingTools(on: configuration)
        let webView = KnowledgeMapWebView(frame: .zero, configuration: configuration)
        webView.onDrop = onDrop
        webView.setValue(false, forKey: "drawsBackground")
        // The page zooms its own plane: WebKit's page zoom stays off, and the
        // trackpad's pinch and two-finger double tap are handed to the page
        // (`KnowledgeMapWebView.magnify(with:)`).
        webView.allowsMagnification = false
        let coordinator = context.coordinator
        webView.onPinch = { [weak coordinator] factor, point in coordinator?.pinch(factor, at: point) }
        webView.onSmartZoom = { [weak coordinator] point in coordinator?.smartZoom(at: point) }
        webView.allowsBackForwardNavigationGestures = false
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(context.coordinator),
            name: Self.messageHandlerName
        )
        context.coordinator.webView = webView
        context.coordinator.actions = KnowledgeMapCanvasActions(vm: viewModel, windowState: windowState)
        handle?.coordinator = context.coordinator
        guard let page = Bundle.main.url(
            forResource: "knowledge-map",
            withExtension: "html",
            subdirectory: "KnowledgeMapResources"
        ) else {
            let model = model
            Task { @MainActor in model.rendererError = "The Canvas page is missing from this build." }
            return webView
        }
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.onNoteRequested = onNoteRequested
        context.coordinator.onLinkEvidence = onLinkEvidence
        context.coordinator.actions = KnowledgeMapCanvasActions(vm: viewModel, windowState: windowState)
        context.coordinator.memoryWindowID = windowID // Memory (WP-B2)
        (webView as? KnowledgeMapWebView)?.onDrop = onDrop
        // Pushing drains the model's command queue, a change to observed
        // state; it runs after this update rather than inside it.
        let coordinator = context.coordinator
        Task { @MainActor in coordinator.sync() }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        if coordinator.role == .pane, let window = coordinator.actions?.windowState.id {
            coordinator.model.showingWindowIDs.remove(window)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        coordinator.removeRendererHooks()
        coordinator.webView = nil
        KnowledgeMapDisplayExtension.shared.canvasWentAway(coordinator)
    }

    /// The page holds the handler; this keeps it from holding the coordinator.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?

        init(_ target: WKScriptMessageHandler) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let model: KnowledgeMapModel
        let role: Role
        var onOpen: (String) -> Void
        var onNoteRequested: (Double, Double) -> Void
        var onLinkEvidence: (String, [String]) -> Void
        weak var webView: WKWebView?
        /// The app around the canvas, set when it is made and on every update.
        var actions: KnowledgeMapCanvasActions?
        /// The display switches last told to the page (nil: not yet), and
        /// whether this canvas put its image exporter on the model.
        var displayPush: String?
        var installedExporter = false
        /// Whose exporter on the model is this pane's (`installImageExporter`).
        let exporterID = UUID()
        var observingDisplay = false
        private(set) var isReady = false
        private var pushedLayout = -1
        private var pushedContent = -1
        private var pushedLens = -1
        private var pushedSummaries = -1
        // MARK: Proposals and faces (WP-B1)
        private var pushedProposals = -1
        private var pushedFaces = -1
        // MARK: Memory (WP-B2)
        var memoryPushes = KnowledgeMapMemoryPushes()
        var memoryWindowID: UUID?

        init(
            model: KnowledgeMapModel,
            role: Role,
            onOpen: @escaping (String) -> Void,
            onNoteRequested: @escaping (Double, Double) -> Void,
            onLinkEvidence: @escaping (String, [String]) -> Void
        ) {
            self.model = model
            self.role = role
            self.onOpen = onOpen
            self.onNoteRequested = onNoteRequested
            self.onLinkEvidence = onLinkEvidence
        }

        /// Pushes whatever the page has not seen yet: the cards, then the
        /// layout, then the lens, then the queued commands.
        func sync() {
            guard isReady else { return }
            if pushedContent != model.contentRevision {
                pushedContent = model.contentRevision
                call("setContent", json(model.content))
                sendThumbnails()
            }
            if pushedLayout != model.layoutRevision {
                pushedLayout = model.layoutRevision
                call("setLayout", json(model.layout))
                // A region's cards change with the layout, and with them
                // whether it still has a summary to show (`summariesPayload`).
                call("setSummaries", json(model.summariesPayload))
                pushedSummaries = model.summariesRevision
                // A page turned asks for the next page's picture, and a
                // picture just placed for its own.
                sendPagePictures()
                sendPlacedPictures()
            }
            if pushedLens != model.lensRevision {
                pushedLens = model.lensRevision
                if let lens = model.lens {
                    call("applyLens", json(lens))
                } else {
                    call("clearLens")
                }
            }
            if pushedSummaries != model.summariesRevision {
                pushedSummaries = model.summariesRevision
                call("setSummaries", json(model.summariesPayload))
            }
            // MARK: Proposals and faces (WP-B1)
            if pushedProposals != model.proposalsRevision {
                pushedProposals = model.proposalsRevision
                call("setProposals", model.proposals.map { json($0) } ?? "null")
            }
            if pushedFaces != model.facesRevision {
                pushedFaces = model.facesRevision
                call("setFaces", json(model.facesPayload))
            }
            // A kept question's Idea, selected without flying to it.
            if role == .pane, let refs = model.askState.takePendingSelection() {
                call("mirror", json(["selection": refs]))
                // The page selects without saying so; the inspector follows,
                // a turn later (this runs while the view updates).
                DispatchQueue.main.async { [model] in
                    model.selection = refs
                    model.selectedRegionID = nil
                    model.selectedEdgeID = nil
                }
                KnowledgeMapDisplayExtension.shared.relay(from: self, method: "mirror", ["selection": refs])
            }
            // MARK: Memory (WP-B2)
            syncMemory()
            // The queue is the pane's: the window extended to follows the
            // pane's camera and selection instead.
            guard role == .pane else { return }
            let window = actions?.windowState.id
            if let window { model.showingWindowIDs.insert(window) }
            for command in model.takeCommands(for: window) {
                perform(command.action)
            }
        }

        /// The pictures the page has not been given yet, the placed cards'
        /// first, rendered off the main actor through the Library's cache and
        /// sent in batches as data URLs (a web view can only be given bytes).
        private var sentThumbnails: Set<String> = []
        private var thumbnailTask: Task<Void, Never>?

        private func sendThumbnails() {
            sendClipPictures()
            sendPlacedPictures()
            let placed = Set(model.layout.placements.keys)
            let pending = model.artworkOrigins
                .filter { !sentThumbnails.contains($0.key) && sentPictures[$0.key] == nil }
                .sorted { (placed.contains($0.key) ? 0 : 1, $0.key) < (placed.contains($1.key) ? 0 : 1, $1.key) }
            guard !pending.isEmpty else { return }
            thumbnailTask?.cancel()
            thumbnailTask = Task { [weak self] in
                var batch: [String: String] = [:]
                for (ref, origin) in pending {
                    if Task.isCancelled { return }
                    guard let image = await SourceArtwork.thumbnail(for: origin, maxPixelSize: 192),
                          let dataURL = SourceArtwork.jpegDataURL(from: image) else { continue }
                    batch[ref] = dataURL
                    if batch.count >= 24 {
                        self?.pushArtwork(batch)
                        batch = [:]
                    }
                }
                if !batch.isEmpty { self?.pushArtwork(batch) }
            }
        }

        /// The small pictures above, less any picture placed and sent whole
        /// since they were asked for: a late thumbnail must not cover it.
        private func pushArtwork(_ batch: [String: String]) {
            let kept = batch.filter { sentPictures[$0.key] == nil }
            if !kept.isEmpty { pushThumbnails(kept) }
        }

        /// Each placed picture of the Images library, drawn as large as
        /// `pictureSize` rather than as the Library's 192-pixel thumbnail: a
        /// picture is the card itself, read zoomed in, and a slide's words
        /// blur at 192 pixels. Only the placed ones, since the Library may hold
        /// hundreds; one placed later is sent when the layout changes, and one
        /// redrawn (its file changed) is sent again.
        private var sentPictures: [String: SourceArtwork.Origin] = [:]
        private var pictureTask: Task<Void, Never>?
        private static let pictureSize: CGFloat = 1600

        private func sendPlacedPictures() {
            var pending: [(ref: String, origin: SourceArtwork.Origin)] = []
            for ref in model.layout.placements.keys where KnowledgeMap.ItemRef(ref)?.kind == .picture {
                guard let origin = model.artworkOrigins[ref], sentPictures[ref] != origin else { continue }
                pending.append((ref, origin))
            }
            pending.sort { $0.ref < $1.ref }
            guard !pending.isEmpty else { return }
            for item in pending { sentPictures[item.ref] = item.origin }
            pictureTask = Task { [weak self] in
                var batch: [String: String] = [:]
                for item in pending {
                    if Task.isCancelled { return }
                    guard let image = await SourceArtwork.thumbnail(for: item.origin, maxPixelSize: Self.pictureSize),
                          let dataURL = SourceArtwork.jpegDataURL(from: image, quality: 0.9) else { continue }
                    batch[item.ref] = dataURL
                    if batch.count >= 4 {
                        self?.pushThumbnails(batch)
                        batch = [:]
                    }
                }
                if !batch.isEmpty { self?.pushThumbnails(batch) }
            }
        }

        /// Each clip's picture, drawn from its page region once and kept by
        /// ref: a note written on a clip changes its card, never its picture.
        private var clipTask: Task<Void, Never>?

        /// Each page card's picture, and each page face's, drawn from its PDF's
        /// page once and kept by ref (`page:<sourceID>:<n>`: a page face of that
        /// page and a page card of it are the one picture), four to a push, the
        /// page cards in the order they run and then the page faces.
        private var pageTask: Task<Void, Never>?

        private func sendPagePictures() {
            var pending: [(ref: String, sourceID: String, page: Int)] = []
            for node in model.content.nodes where node.kind == "page" && !sentThumbnails.contains(node.ref) {
                guard let parts = KnowledgeMap.ItemRef(node.ref)?.pageParts else { continue }
                pending.append((node.ref, parts.sourceID, parts.page))
            }
            pending.sort { $0.ref.localizedStandardCompare($1.ref) == .orderedAscending }
            // A page face shows the page its placement names, within the PDF.
            var faces: [(ref: String, sourceID: String, page: Int)] = []
            for (ref, placement) in model.layout.placements {
                guard let page = placement.page, let node = model.nodesByRef[ref], node.kind == "source",
                      let pageCount = node.pages, pageCount > 0, let item = KnowledgeMap.ItemRef(ref) else { continue }
                let shown = KnowledgeMap.pageRef(sourceID: item.id, page: min(max(page, 1), pageCount))
                if !sentThumbnails.contains(shown), !pending.contains(where: { $0.ref == shown }) {
                    faces.append((shown, item.id, min(max(page, 1), pageCount)))
                }
            }
            faces.sort { $0.ref.localizedStandardCompare($1.ref) == .orderedAscending }
            pending += faces
            guard !pending.isEmpty, let draw = model.pagePicture else { return }
            sentThumbnails.formUnion(pending.map(\.ref))
            pageTask = Task { [weak self] in
                var batch: [String: String] = [:]
                for item in pending {
                    if Task.isCancelled { return }
                    guard let dataURL = await draw(item.sourceID, item.page) else { continue }
                    batch[item.ref] = dataURL
                    if batch.count >= 4 {
                        self?.pushThumbnails(batch)
                        batch = [:]
                    }
                }
                if !batch.isEmpty { self?.pushThumbnails(batch) }
            }
        }

        private func sendClipPictures() {
            sendPagePictures()
            let pending = model.clips.values
                .map { (ref: KnowledgeMap.ItemRef(kind: .clip, id: $0.id).description, clip: $0) }
                .filter { !sentThumbnails.contains($0.ref) }
            guard !pending.isEmpty, let draw = model.clipPicture else { return }
            sentThumbnails.formUnion(pending.map(\.ref))
            clipTask = Task { [weak self] in
                var batch: [String: String] = [:]
                for (ref, clip) in pending {
                    if Task.isCancelled { return }
                    guard let dataURL = await draw(clip) else { continue }
                    batch[ref] = dataURL
                    if batch.count >= 6 {
                        self?.pushThumbnails(batch)
                        batch = [:]
                    }
                }
                if !batch.isEmpty { self?.pushThumbnails(batch) }
            }
        }

        private func pushThumbnails(_ batch: [String: String]) {
            sentThumbnails.formUnion(batch.keys)
            call("setThumbnails", json(batch))
        }

        /// Asks the renderer to do one thing now.
        func perform(_ action: KnowledgeMapCommand.Action) {
            switch action {
            case .focus(let refs, let regionID):
                call("focus", json(refs), regionID.map { json($0) } ?? "null")
            case .select(let refs):
                call("select", json(refs))
            case .zoom(let factor):
                call("zoom", String(factor))
            case .fit:
                call("fit")
            case .tool(let tool):
                call("setTool", json(tool))
            case .selectRegion(let id):
                call("selectRegion", id.map { json($0) } ?? "null")
            case .selectEdge(let id):
                call("selectEdge", id.map { json($0) } ?? "null")
            case .drop(let x, let y, let refs, let regionName, let notebookID):
                call("dropAt", String(x), String(y), json(refs), regionName.map { json($0) } ?? "null", notebookID.map { json($0) } ?? "null")
            case .dropAtCenter(let refs, let regionName, let notebookID):
                call("dropAtCenter", json(refs), regionName.map { json($0) } ?? "null", notebookID.map { json($0) } ?? "null")
            case .voiceShowing(let on):
                call("setVoiceShowing", on ? "true" : "false")
            }
        }

        /// A trackpad pinch: the plane zooms about the pointer by `factor`.
        func pinch(_ factor: Double, at point: CGPoint) {
            call("pinch", String(factor), String(Double(point.x)), String(Double(point.y)))
        }

        /// A two-finger double tap: close in on what is under the pointer, or
        /// back out to everything.
        func smartZoom(at point: CGPoint) {
            call("smartZoom", String(Double(point.x)), String(Double(point.y)))
        }

        /// Calls the page's `window.knowledgeMap` with a JSON argument, for
        /// the display extension's link, camera, drag and mirror.
        func callRenderer(_ method: String, jsonObject: Any?) {
            guard let jsonObject else { return call(method, "null") }
            guard let data = try? JSONSerialization.data(withJSONObject: jsonObject) else { return }
            call(method, String(decoding: data, as: UTF8.self))
        }

        func json<T: Encodable>(_ value: T) -> String {
            guard let data = try? JSONEncoder().encode(value) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }

        func call(_ method: String, _ arguments: String...) {
            let script = "window.knowledgeMap && window.knowledgeMap.\(method)(\(arguments.joined(separator: ",")));"
            webView?.evaluateJavaScript(script) { [weak self] _, error in
                if let error {
                    Task { @MainActor in self?.model.rendererError = "The Canvas could not draw: \(error.localizedDescription)" }
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the Canvas page itself (`ScriptMessageSender`).
            guard message.isFrom(.appFile),
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                pushedContent = -1
                pushedLayout = -1
                pushedLens = -1
                pushedSummaries = -1
                pushedProposals = -1 // Proposals and faces (WP-B1)
                pushedFaces = -1
                memoryPushes = KnowledgeMapMemoryPushes() // Memory (WP-B2)
                displayPush = nil
                model.rendererError = nil
                // Linked first, so the window extended to never fits to the
                // whole map on its own.
                KnowledgeMapDisplayExtension.shared.canvasReady(self)
                sync()
                installRendererHooks()
            case "camera":
                guard let scale = Self.number(body["scale"]), let ox = Self.number(body["ox"]), let oy = Self.number(body["oy"]) else { return }
                KnowledgeMapDisplayExtension.shared.cameraMoved(by: self, to: .init(scale: scale, ox: ox, oy: oy))
            case "dragPreview":
                var preview = body
                preview.removeValue(forKey: "type")
                KnowledgeMapDisplayExtension.shared.relay(from: self, method: "previewDrag", preview)
            case "placed":
                let items = (body["items"] as? [[String: Any]] ?? []).compactMap { item -> (ref: String, x: Double, y: Double)? in
                    guard let ref = item["ref"] as? String, let x = Self.number(item["x"]), let y = Self.number(item["y"]) else { return nil }
                    return (ref, x, y)
                }
                model.place(items)
            case "unplace":
                model.unplace(body["refs"] as? [String] ?? [])
            case "regionCreated", "regionChanged":
                guard let region = body["region"] as? [String: Any], let id = region["id"] as? String,
                      let x = Self.number(region["x"]), let y = Self.number(region["y"]),
                      let w = Self.number(region["w"]), let h = Self.number(region["h"]) else { return }
                let existing = model.layout.regions[id]
                model.saveRegion(
                    id: id,
                    name: existing?.name ?? (region["name"] as? String ?? ""),
                    x: x, y: y, w: w, h: h,
                    color: existing?.color ?? (region["color"] as? String ?? KnowledgeMapModel.regionColors[0]),
                    notebookID: existing.map(\.notebookID) ?? (region["notebookID"] as? String)
                )
                if type == "regionCreated" {
                    model.selectedRegionID = id
                    model.selection = []
                    model.selectedEdgeID = nil
                    KnowledgeMapDisplayExtension.shared.relay(from: self, method: "mirror", ["region": id])
                }
            case "regionCollapsed":
                // The chevron on a region's name: fold it up, or open it again.
                if let id = body["id"] as? String, let collapsed = body["collapsed"] as? Bool {
                    model.setRegionCollapsed(id, collapsed)
                }
            case "regionDeleted":
                // Delete on a selected region: it goes with everything inside it.
                if let id = body["id"] as? String { model.deleteRegion(id, takingCardsOff: true) }
            case "regionSelected":
                model.selectedRegionID = body["id"] as? String
                if model.selectedRegionID != nil { model.selection = []; model.selectedEdgeID = nil }
                KnowledgeMapDisplayExtension.shared.relay(from: self, method: "mirror", ["region": model.selectedRegionID ?? NSNull()])
            case "edgeRequested":
                // An end may be a region (`region:<id>`); a branch of a mind map is `tree`.
                guard let from = body["from"] as? String, let to = body["to"] as? String else { return }
                if let id = model.addEdge(from: from, to: to, label: "", tree: body["tree"] as? Bool ?? false) {
                    model.selectedEdgeID = id
                    model.send(.selectEdge(id))
                }
            case "edgeSelected":
                model.selectedEdgeID = body["id"] as? String
                if model.selectedEdgeID != nil { model.selection = []; model.selectedRegionID = nil }
                KnowledgeMapDisplayExtension.shared.relay(from: self, method: "mirror", ["edge": model.selectedEdgeID ?? NSNull()])
            case "edgeDeleted":
                if let id = body["id"] as? String { model.deleteEdge(id) }
            case "selection":
                model.selection = body["refs"] as? [String] ?? []
                if !model.selection.isEmpty { model.selectedRegionID = nil; model.selectedEdgeID = nil }
                KnowledgeMapDisplayExtension.shared.relay(from: self, method: "mirror", ["selection": model.selection])
            case "view":
                // What the chat reads as the learner's view is the pane's.
                guard role == .pane else { return }
                var view = KnowledgeMapViewport()
                view.level = body["level"] as? String ?? "regions"
                if let center = body["center"] as? [String: Any], let x = Self.number(center["x"]), let y = Self.number(center["y"]) {
                    view.center = (x, y)
                }
                if let span = body["span"] as? [String: Any], let w = Self.number(span["w"]), let h = Self.number(span["h"]) {
                    view.span = (w, h)
                }
                view.visibleRefs = body["visibleRefs"] as? [String] ?? []
                view.visibleRegionIDs = body["visibleRegionIDs"] as? [String] ?? []
                // The zoom readout, and whether anything is in view (Back to content).
                view.scale = Self.number(body["scale"]) ?? 1
                view.empty = body["empty"] as? Bool ?? false
                view.path = (body["path"] as? [[String: Any]] ?? []).compactMap { step in
                    guard let id = step["id"] as? String, let name = step["name"] as? String else { return nil }
                    return .init(id: id, name: name)
                }
                if view != model.viewport { model.viewport = view }
            case "tool":
                model.tool = body["tool"] as? String ?? "select"
                KnowledgeMapDisplayExtension.shared.relay(from: self, method: "mirror", ["tool": model.tool])
            case "open":
                if let ref = body["ref"] as? String { onOpen(ref) }
            case "linkEvidence":
                if let idea = body["idea"] as? String, let refs = body["refs"] as? [String], !refs.isEmpty {
                    onLinkEvidence(idea, refs)
                }
            case "noteRequested":
                if let x = Self.number(body["x"]), let y = Self.number(body["y"]) { onNoteRequested(x, y) }
            case "shortcuts":
                // The pane's own window shows them; the window extended to has no toolbar.
                if role == .pane { model.showsShortcuts.toggle() }
            // MARK: Adding to the canvas (docs/knowledge-map-design.md, "Adding to the canvas")
            case "addRequested":
                // /: the add box, at the pointer when it is over the plane (the
                // message is empty when it is not), in this canvas's window.
                guard role == .pane, let windowID = actions?.windowState.id else { return }
                var spot: CGPoint?
                if let x = Self.number(body["x"]), let y = Self.number(body["y"]) { spot = CGPoint(x: x, y: y) }
                model.addBox = KnowledgeMapAddBoxRequest(
                    view: spot,
                    worldX: Self.number(body["wx"]),
                    worldY: Self.number(body["wy"]),
                    windowID: windowID
                )
            case "libraryToggled":
                // L: the Library sidebar, shown or hidden on this Mac.
                if role == .pane { model.showsLibrary.toggle() }
            case "voiceKey":
                // S held or tapped: speaking to the canvas (`KnowledgeMapVoice`).
                guard role == .pane else { return }
                if body["down"] as? Bool == true { KnowledgeMapVoice.shared.keyDown() } else { KnowledgeMapVoice.shared.keyUp() }
            case "voiceEscape":
                // Esc on the plane stops speaking to the canvas, if it is.
                guard role == .pane, KnowledgeMapVoice.shared.isShowing else { return }
                KnowledgeMapVoice.shared.stop()
            case "findRequested":
                // ⌘F: the cursor goes to the find field.
                if role == .pane { model.findFocusRequests += 1 }
            case "undo":
                model.undo()
            case "redo":
                model.redo()
            // MARK: Proposals (WP-B1): the ghosts laid out, one kept or dismissed.
            case "proposalLayout", "proposalKeep", "proposalDismiss":
                model.receiveProposalMessage(type, body)
            case "error":
                model.rendererError = body["message"] as? String ?? "The Canvas could not draw."
            // MARK: Review (WP-B2)
            case "reviewAnchor", "reviewEscape":
                handleReviewMessage(type, body)
            default:
                // Sizing, arrow styles, writing in place, menus, keys and clicks.
                handleParityMessage(type, body)
            }
        }

        static func number(_ value: Any?) -> Double? {
            switch value {
            case let number as NSNumber: return number.doubleValue
            case let double as Double: return double
            case let int as Int: return Double(int)
            default: return nil
            }
        }
    }
}

/// The Map's web view. It takes the app's own drags itself, a source from the
/// Sources list or the Library, a Doc from Docs or the home's Docs tab, a
/// notebook from the rail or the home, as the Docs editor's page does
/// (`ArtifactEditorWebView`), and hands every other drag to WebKit.
final class KnowledgeMapWebView: WKWebView {
    struct Drop {
        /// Where it was dropped, in the page's coordinates.
        var point: CGPoint
        var sourceIDs: [String]
        var docIDs: [String]
        var notebookIDs: [String]
        /// Clips cut out of a page in the Reader (`ReaderClipTool`).
        var clips: [StudioClipTransfer] = []
        /// What came from outside the app's own cards: the Finder's files,
        /// pictures, chats from a list, addresses and words pasted
        /// (`KnowledgeMapOutsideDrop`).
        var outside = KnowledgeMapOutsideDrop()
        /// The cards a Library or add-box row carried (`KnowledgeMapCardTransfer`):
        /// the only thing such a drag is taken for.
        var cardRefs: [String] = []
    }

    var onDrop: ((Drop) -> Void)?
    /// A pinch, as a zoom factor about a point in the page.
    var onPinch: ((Double, CGPoint) -> Void)?

    /// No Apple Intelligence badge on a selection (`SharedWebKit.allowsWritingToolsAffordance(in:)`).
    @objc(allowsWritingToolsAffordance)
    var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }
    /// macOS 27.0.1 shows the badge without asking the property above; an empty
    /// selection rect keeps it hidden (`SharedWebKit.unionRectInVisibleSelectedRange(in:)`).
    @objc(unionRectInVisibleSelectedRange)
    var unionRectInVisibleSelectedRange: NSRect { SharedWebKit.unionRectInVisibleSelectedRange(in: self) }
    /// A two-finger double tap at a point in the page.
    var onSmartZoom: ((CGPoint) -> Void)?
    private var ownsCurrentDrag = false

    private static let cardType = NSPasteboard.PasteboardType(UTType.knowledgeMapCard.identifier)

    private static let carriedTypes = [
        cardType,
        ArtifactEditorWebView.sourceTransferType,
        ArtifactEditorWebView.artifactTransferType,
        ArtifactEditorWebView.notebookTransferType,
        NSPasteboard.PasteboardType(UTType.studioClip.identifier),
    ] + KnowledgeMapOutsideDrop.draggedTypes

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes(registeredDraggedTypes + Self.carriedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(registeredDraggedTypes + Self.carriedTypes)
    }

    private func carries(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: Self.carriedTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ownsCurrentDrag = onDrop != nil && carries(sender)
        return ownsCurrentDrag ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ownsCurrentDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard ownsCurrentDrag else { return super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ownsCurrentDrag ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ownsCurrentDrag, let onDrop else { return super.performDragOperation(sender) }
        let pasteboard = sender.draggingPasteboard
        // A row of the Library or the add box carries the cards themselves, and
        // its kind's own drag besides, for a chat or an Idea to take: here the
        // cards are all it is.
        let cardRefs = (pasteboard.pasteboardItems ?? []).flatMap { item in
            item.data(forType: Self.cardType)
                .flatMap { try? JSONDecoder().decode(KnowledgeMapCardTransfer.self, from: $0) }?.refs ?? []
        }
        if !cardRefs.isEmpty {
            onDrop(Drop(point: pagePoint(sender.draggingLocation), sourceIDs: [], docIDs: [], notebookIDs: [], cardRefs: cardRefs))
            return true
        }
        var sourceIDs: [String] = []
        for transfer in ArtifactEditorWebView.sourceTransfers(on: pasteboard) {
            sourceIDs.append(contentsOf: transfer.articleIds ?? [transfer.articleId])
        }
        var docIDs: [String] = []
        var notebookIDs: [String] = []
        for transfer in ArtifactEditorWebView.linkTransfers(on: pasteboard) {
            switch transfer.link {
            case .doc(let id): docIDs.append(id)
            case .notebook(let id): notebookIDs.append(id)
            case .chat, .quiz, .idea: break
            }
        }
        let clipType = NSPasteboard.PasteboardType(UTType.studioClip.identifier)
        let clips = (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: clipType).flatMap { try? JSONDecoder().decode(StudioClipTransfer.self, from: $0) }
        }
        let point = pagePoint(sender.draggingLocation)
        let isApps = !sourceIDs.isEmpty || !docIDs.isEmpty || !notebookIDs.isEmpty || !clips.isEmpty
        let outside = KnowledgeMapOutsideDrop(dragging: pasteboard, includingFiles: !isApps)
        // Files an app promises (the Screenshots thumbnail, Photos, a picture
        // dragged from a browser) arrive in a folder of ours first.
        let promised = isApps || !outside.isEmpty ? [] : pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if !promised.isEmpty {
            receive(promised) { urls, folder in
                var delivered = KnowledgeMapOutsideDrop()
                delivered.fileURLs = urls
                delivered.stagingDirectory = folder
                onDrop(Drop(point: point, sourceIDs: [], docIDs: [], notebookIDs: [], outside: delivered))
            }
            return true
        }
        guard isApps || !outside.isEmpty else { return false }
        onDrop(Drop(point: point, sourceIDs: sourceIDs, docIDs: docIDs, notebookIDs: notebookIDs, clips: clips, outside: outside))
        return true
    }

    /// Takes the files an app promised into a folder of ours, and hands over
    /// the files that arrived with the folder, which the import removes when
    /// it is done.
    private func receive(_ receivers: [NSFilePromiseReceiver], then finish: @escaping ([URL], URL) -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLM-CanvasDrop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let group = DispatchGroup()
        var arrived: [URL] = []
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                if error == nil { arrived.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { finish(arrived, folder) }
    }

    /// ⌘V: set down in the middle of the view, as a drop there would be. A clip
    /// the Reader's Clip tool copied; files copied in the Finder; a picture; a
    /// web address or DOI (imported as a source); a `foreverlm://` address (the
    /// card it names, a notebook as its sources in a frame); or a few words (an
    /// Idea). The page is one canvas with no field of its own, so a paste is
    /// never text typed into it.
    @objc func paste(_ sender: Any?) {
        guard let onDrop else { return }
        let clipType = NSPasteboard.PasteboardType(UTType.studioClip.identifier)
        let clips = (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            item.data(forType: clipType).flatMap { try? JSONDecoder().decode(StudioClipTransfer.self, from: $0) }
        }
        var outside = clips.isEmpty ? KnowledgeMapOutsideDrop(pasting: NSPasteboard.general) : KnowledgeMapOutsideDrop()
        let notebookIDs = outside.takeNotebookIDs()
        guard !clips.isEmpty || !notebookIDs.isEmpty || !outside.isEmpty else { return }
        onDrop(Drop(point: CGPoint(x: bounds.midX, y: bounds.midY), sourceIDs: [], docIDs: [], notebookIDs: notebookIDs, clips: clips, outside: outside))
    }

    /// A point in the window as the page measures it: from the view's top left.
    private func pagePoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }

    /// The page zooms its own plane. With WebKit's page zoom off a pinch would
    /// reach the page, if at all, as WebKit's gesture events; it is handed
    /// over directly instead, so it zooms the plane in every WebKit.
    /// `locationInWindow` is undefined for gesture events; the live pointer is
    /// where the pinch is, as the readers route it (`gesturePointerLocation`).
    override func magnify(with event: NSEvent) {
        guard let onPinch, let window else { return super.magnify(with: event) }
        let factor = 1 + Double(event.magnification)
        guard factor > 0 else { return }
        onPinch(factor, pagePoint(window.gesturePointerLocation))
    }

    override func smartMagnify(with event: NSEvent) {
        guard let onSmartZoom, let window else { return super.smartMagnify(with: event) }
        onSmartZoom(pagePoint(window.gesturePointerLocation))
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard ownsCurrentDrag else { return super.concludeDragOperation(sender) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard ownsCurrentDrag else { return super.draggingEnded(sender) }
        ownsCurrentDrag = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The canvas a Map view hosts, so what addresses that renderer itself (Extend
/// to Other Display, a drop on the window extended to) can reach it.
@MainActor
final class KnowledgeMapCanvasHandle {
    weak var coordinator: KnowledgeMapCanvasView.Coordinator?
}

/// The Map extended to a second display (docs/knowledge-map-design.md,
/// "Extending to another display"). A second Map window fills the other
/// screen's visible frame and shows the region of the plane next to the
/// first window's, on the side the displays are arranged, so the two read as
/// one wide canvas. One camera: whichever window a pan or zoom happens in
/// leads, and the other's camera is derived from it
/// (`KnowledgeMapDisplays`). Both canvases draw the one `KnowledgeMapModel`,
/// so a card placed in either shows in both, and a card dragged past the
/// shared edge goes on into the other window.
///
/// Closing either window, closing the Map pane, a display going away, or
/// Stop Extending ends it. Nothing about it is remembered across launches.
@MainActor
@Observable
final class KnowledgeMapDisplayExtension {
    static let shared = KnowledgeMapDisplayExtension()

    private(set) var isActive = false
    /// How many displays are connected; Extend to Other Display needs two.
    private(set) var displayCount = NSScreen.screens.count

    @ObservationIgnored private weak var primary: KnowledgeMapCanvasView.Coordinator?
    @ObservationIgnored private weak var secondary: KnowledgeMapCanvasView.Coordinator?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var side: KnowledgeMapDisplays.Side = .right
    /// The first window's camera, the one both are derived from.
    @ObservationIgnored private var camera: KnowledgeMapDisplays.Camera?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isStopping = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Whether `canvas` is the window the Map is extended from.
    func isExtending(from canvas: KnowledgeMapCanvasView.Coordinator?) -> Bool {
        isActive && canvas != nil && primary === canvas
    }

    /// Opens the second Map window on the other display, continuing the plane
    /// from `canvas`'s window. Opens, Docs and notes from it go to
    /// `windowState`, the window extended from.
    func start(from canvas: KnowledgeMapCanvasView.Coordinator, viewModel: StudioViewModel, windowState: StudioWindowState) {
        stop()
        guard let primaryWindow = canvas.webView?.window,
              let primaryScreen = primaryWindow.screen ?? NSScreen.main else { return }
        let screens = NSScreen.screens
        guard let otherFrame = KnowledgeMapDisplays.otherScreen(from: primaryScreen.frame, among: screens.map(\.frame)),
              let other = screens.first(where: { $0.frame == otherFrame }) else {
            viewModel.showToast("Connect another display to extend the Canvas")
            return
        }
        side = KnowledgeMapDisplays.side(of: other.frame, from: primaryScreen.frame)
        primary = canvas
        camera = nil

        let handle = KnowledgeMapCanvasHandle()
        let root = KnowledgeMapExtensionView(handle: handle, primaryWindow: primaryWindow)
            .environment(viewModel)
            .environment(windowState)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: other.visibleFrame.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: other
        )
        window.title = "Canvas"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(other.visibleFrame, display: true)
        window.orderFront(nil)
        self.window = window
        isActive = true

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: primaryWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
        for observed in [window, primaryWindow] {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                observers.append(center.addObserver(forName: name, object: observed, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryChanged() }
                })
            }
        }
        // The pane resizing inside its window (the rail, a pane beside it).
        if let webView = canvas.webView {
            webView.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: webView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryChanged() }
            })
        }
        // The first window sends its camera now; the second takes it once
        // its page is ready.
        link(canvas, facing: side, announce: true)
    }

    func stop() {
        guard isActive, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        primary?.callRenderer("setLink", jsonObject: nil)
        primary = nil
        secondary = nil
        camera = nil
        let closing = window
        window = nil
        isActive = false
        closing?.close()
    }

    // MARK: From the canvases

    func canvasReady(_ canvas: KnowledgeMapCanvasView.Coordinator) {
        guard isActive else { return }
        if canvas.role == .extensionWindow {
            secondary = canvas
            // Both frames are known now, so both pages get the gap between them.
            if let primary { link(primary, facing: side, announce: false) }
            link(canvas, facing: side.opposite, announce: false)
            pushSecondaryCamera()
        } else if canvas === primary {
            // The pane's page loaded again (its web content restarted).
            link(canvas, facing: side, announce: true)
        }
    }

    func canvasWentAway(_ canvas: KnowledgeMapCanvasView.Coordinator) {
        guard isActive, canvas === primary || canvas === secondary else { return }
        stop()
    }

    /// A pan or zoom in one window: it leads, and the other follows.
    func cameraMoved(by canvas: KnowledgeMapCanvasView.Coordinator, to moved: KnowledgeMapDisplays.Camera) {
        guard isActive else { return }
        if canvas === primary {
            camera = moved
            pushSecondaryCamera()
        } else if canvas === secondary, let frames = frames() {
            let derived = KnowledgeMapDisplays.primaryCamera(following: moved, side: side, primary: frames.primary, secondary: frames.secondary)
            camera = derived
            primary?.callRenderer("setCamera", jsonObject: cameraObject(derived))
        }
    }

    /// Hands what one window's page reported (its drag in progress, what it
    /// selected, its tool) to the other's.
    func relay(from canvas: KnowledgeMapCanvasView.Coordinator, method: String, _ payload: [String: Any]) {
        guard isActive else { return }
        let peer = canvas === primary ? secondary : canvas === secondary ? primary : nil
        peer?.callRenderer(method, jsonObject: payload)
    }

    // MARK: Geometry

    /// Each canvas's frame in global screen space, in points.
    private func frames() -> (primary: CGRect, secondary: CGRect)? {
        guard let first = primary?.webView, let second = secondary?.webView,
              let a = Self.screenFrame(of: first), let b = Self.screenFrame(of: second) else { return nil }
        return (a, b)
    }

    private static func screenFrame(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func link(_ canvas: KnowledgeMapCanvasView.Coordinator, facing: KnowledgeMapDisplays.Side, announce: Bool) {
        let gap = frames().map { KnowledgeMapDisplays.gap(side: side, primary: $0.primary, secondary: $0.secondary) } ?? 0
        canvas.callRenderer("setLink", jsonObject: [
            "edge": facing.rendererEdge,
            "gap": gap,
            "announce": announce,
            "follows": canvas.role == .extensionWindow,
        ] as [String: Any])
    }

    private func pushSecondaryCamera() {
        guard let camera, let frames = frames() else { return }
        let derived = KnowledgeMapDisplays.secondaryCamera(following: camera, side: side, primary: frames.primary, secondary: frames.secondary)
        secondary?.callRenderer("setCamera", jsonObject: cameraObject(derived))
    }

    private func cameraObject(_ camera: KnowledgeMapDisplays.Camera) -> [String: Any] {
        ["scale": camera.scale, "ox": camera.ox, "oy": camera.oy]
    }

    /// A window moved or resized: the first window stays where it is on the
    /// plane, and the second is derived again; the drag gap is measured again.
    private func geometryChanged() {
        guard isActive else { return }
        if let first = primary?.webView?.window?.screen, let second = window?.screen, first == second {
            // Both windows on one display: there is nothing to extend onto.
            stop()
            return
        }
        if let primary { link(primary, facing: side, announce: false) }
        if let secondary { link(secondary, facing: side.opposite, announce: false) }
        pushSecondaryCamera()
    }

    private func screensChanged() {
        displayCount = NSScreen.screens.count
        guard isActive else { return }
        if displayCount < 2 || window?.screen == nil {
            stop()
        } else {
            geometryChanged()
        }
    }
}
