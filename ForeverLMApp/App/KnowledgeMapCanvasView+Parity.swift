import AppKit
import Foundation
import Observation

// MARK: - The Canvas's side of the Heptabase parity build
//
// docs/knowledge-map-design.md, "Heptabase parity build (2026-10-09): the
// contract" and "The renderer's design". The page (Web/KnowledgeMap) posts what
// the learner does on the plane; this answers it with the model's and the view
// model's calls, and tells the page what the Mac keeps (the display switches)
// and what it can draw (the picture of the plane).
//
// Messages answered here, besides the ones `KnowledgeMapCanvasView` has always
// answered:
//
// - `placementChanged {items: [{ref, w?, h?, folded?, color?, page?, annotation?,
//   plain?, answered?}]}`: a card's size, fold, colour, page (a paper shown as
//   its page), words, and an Idea's plain and answered marks; a missing key
//   leaves the field, `null` clears it.
// - `edgeChanged {id, route?, dashed?, heads?, color?, label?, stance?}`: an
//   arrow's style, label and stance (`supports`, `contradicts`).
// - `chatContextRequested {refs}`: Add to Chat on cards.
// - `regionRenamed {id, name}` and `regionLocked {id, locked}`.
// - `ideaEdited {ref, title, note}` and `ideaRequested {x, y, title?, note?,
//   parentRef?, regionID?, after?, copyOf?, edit?}`: an Idea written in place.
// - `contextMenu {kind, refs?, id?, x, y, wx, wy}`: shows the native menu.
// - `openBeside {ref}`, `popup {ref, rect}`, `navigate {direction}`,
//   `deleteRequested {refs}`: the keys and clicks.

/// The app around a canvas: its view model (for what the model does not own: an
/// Idea's words, opening a card beside the Canvas, the Ask tools) and the
/// window it is in.
@MainActor
struct KnowledgeMapCanvasActions {
    let vm: StudioViewModel
    let windowState: StudioWindowState
}

enum KnowledgeMapExportError: LocalizedError {
    case notReady
    case nothingToDraw

    var errorDescription: String? {
        switch self {
        case .notReady: return "The Canvas is not showing."
        case .nothingToDraw: return "There is nothing on the Canvas to draw."
        }
    }
}

extension KnowledgeMapCanvasView.Coordinator {
    // MARK: Messages

    /// Answers a message the page posts for the parity build. Anything else is ignored.
    func handleParityMessage(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ideaHeights":
            // The heights the page draws Ideas at on their own, measured with its fonts.
            if let heights = body["heights"] as? [String: Any] {
                for (ref, raw) in heights { if let h = Self.number(raw), h > 0 { model.measuredIdeaHeights[ref] = h } }
            }
        case "placementChanged":
            let items = (body["items"] as? [[String: Any]] ?? []).compactMap(Self.placementStyle(from:))
            if !items.isEmpty { model.setPlacementStyle(items) }
        case "edgeChanged":
            guard let id = body["id"] as? String else { return }
            if let label = body["label"] as? String { model.relabelEdge(id, to: label) }
            let route = Self.change(body, "route", String.self)
            let dashed = Self.change(body, "dashed", Bool.self)
            let heads = Self.change(body, "heads", String.self)
            let color = Self.change(body, "color", String.self)
            let stance = Self.change(body, "stance", String.self)
            if route != .keep || dashed != .keep || heads != .keep || color != .keep || stance != .keep {
                // The model takes a value or nil (keep); its own defaults clear a field.
                model.updateEdgeStyle(
                    id,
                    route: route.edgeValue(clearedBy: KnowledgeMapEdgeRoute.curve.rawValue),
                    dashed: dashed.edgeValue(clearedBy: false),
                    heads: heads.edgeValue(clearedBy: KnowledgeMapEdgeHeads.end.rawValue),
                    color: color.edgeValue(clearedBy: ""),
                    stance: stance.edgeValue(clearedBy: "")
                )
            }
        case "regionRenamed":
            if let id = body["id"] as? String, let name = body["name"] as? String { model.renameRegion(id, to: name) }
        case "regionLocked":
            if let id = body["id"] as? String, let locked = body["locked"] as? Bool { model.setRegionLocked(id, locked) }
        case "ideaEdited":
            guard let actions, let ref = body["ref"] as? String, let idea = KnowledgeMap.ItemRef(ref), idea.kind == .idea,
                  let title = body["title"] as? String else { return }
            let note = body["note"] as? String ?? ""
            Task { @MainActor in
                await actions.vm.updateIdea(ideaID: idea.id, title: title, notes: note)
                await actions.vm.refreshKnowledgeMapContent()
            }
        case "ideaRequested":
            requestIdea(body)
        case "contextMenu":
            showContextMenu(body)
        case "openBeside":
            guard let actions, let ref = body["ref"] as? String else { return }
            Task { @MainActor in await actions.vm.openKnowledgeMapItemBeside(ref, in: actions.windowState) }
        case "popup":
            guard let actions, let ref = body["ref"] as? String, let rect = body["rect"] as? [String: Any],
                  let x = Self.number(rect["x"]), let y = Self.number(rect["y"]),
                  let w = Self.number(rect["w"]), let h = Self.number(rect["h"]) else { return }
            actions.vm.showKnowledgeMapPopup(ref, near: CGRect(x: x, y: y, width: w, height: h))
        case "navigate":
            guard let actions, let direction = body["direction"] as? String else { return }
            actions.vm.navigateCanvasHistory(direction == "back" ? .back : .forward)
        case "deleteRequested":
            guard let actions, let refs = body["refs"] as? [String], !refs.isEmpty else { return }
            Task { @MainActor in await actions.vm.deleteKnowledgeMapItems(refs) }
        case "chatContextRequested":
            // ⌘L, or the toolbar's Add to Chat: the cards join the chat beside the Canvas.
            guard let actions, let refs = body["refs"] as? [String], !refs.isEmpty else { return }
            actions.vm.addKnowledgeMapCardsToChat(refs, in: actions.windowState)
        default:
            break
        }
    }

    /// A new Idea from the page's editor, a mind map's Return or Tab, or an
    /// option-drag copy: made, placed (beside its parent in a mind map, with
    /// the branch drawn), selected without flying to it, and, when the page
    /// asked, opened for writing in place.
    private func requestIdea(_ body: [String: Any]) {
        guard let actions else { return }
        let spot = (x: Self.number(body["x"]) ?? 0, y: Self.number(body["y"]) ?? 0)
        let edit = body["edit"] as? Bool ?? false
        Task { @MainActor in
            guard let made = await actions.vm.createKnowledgeMapIdea(
                title: body["title"] as? String ?? "",
                note: body["note"] as? String,
                at: spot,
                parentRef: body["parentRef"] as? String,
                after: body["after"] as? String,
                regionID: body["regionID"] as? String,
                copyOf: body["copyOf"] as? String
            ) else { return }
            // The cards and the layout go across first, so the page has the Idea.
            sync()
            if edit {
                call("editIdea", Self.jsString(made.ref), made.fresh ? "{fresh:true}" : "null")
            } else {
                callRenderer("mirror", jsonObject: ["selection": [made.ref]])
                // `mirror` selects on the page without the page saying so: the
                // inspector follows from here.
                model.selection = [made.ref]
                model.selectedRegionID = nil
                model.selectedEdgeID = nil
            }
        }
    }

    // MARK: The page's JSON

    /// A field of a message: absent leaves it, `null` clears it, a value sets it.
    static func change<Value: Equatable>(_ body: [String: Any], _ key: String, _ type: Value.Type) -> KnowledgeMapFieldChange<Value> {
        guard let raw = body[key] else { return .keep }
        if raw is NSNull { return .clear }
        if let value = raw as? Value { return .set(value) }
        return .keep
    }

    static func placementStyle(from item: [String: Any]) -> KnowledgeMapPlacementStyle? {
        guard let ref = item["ref"] as? String else { return nil }
        var style = KnowledgeMapPlacementStyle(ref: ref)
        style.w = change(item, "w", Double.self)
        style.h = change(item, "h", Double.self)
        style.folded = change(item, "folded", Bool.self)
        style.color = change(item, "color", String.self)
        style.page = pageChange(item["page"])
        style.annotation = change(item, "annotation", String.self)
        style.plain = change(item, "plain", Bool.self)
        style.answered = change(item, "answered", Bool.self)
        return style
    }

    /// A page from the page: absent leaves it, `null` shows the usual card, a
    /// whole number of one or more sets it; anything else leaves it.
    static func pageChange(_ raw: Any?) -> KnowledgeMapFieldChange<Int> {
        guard let raw else { return .keep }
        if raw is NSNull { return .clear }
        guard let number = number(raw), number.isFinite, number >= 1, number.rounded() == number else { return .keep }
        return .set(Int(number))
    }

    /// A string as a JavaScript literal.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: What the native menu asks of the page

    /// Opens the annotation editor on a card, under its foot (an empty one when
    /// it has no words yet): the native menu's Annotate… and Edit Annotation….
    /// The page answers with `placementChanged {annotation}`.
    func editAnnotation(_ ref: String) {
        call("editAnnotation", Self.jsString(ref))
    }

    /// Turns a page face's page by `delta` (the native menu's Next Page and
    /// Previous Page). The page answers with `placementChanged {page}`.
    func turnPage(_ ref: String, by delta: Int) {
        call("turnPage", Self.jsString(ref), String(delta))
    }

    // MARK: The native menu

    /// Shows the menu for what the page says was right-clicked, at that point.
    func showContextMenu(_ body: [String: Any]) {
        guard let webView, let actions, let kind = body["kind"] as? String,
              let x = Self.number(body["x"]), let y = Self.number(body["y"]) else { return }
        let menu = KnowledgeMapCanvasMenu(
            canvas: self,
            model: model,
            vm: actions.vm,
            windowState: actions.windowState,
            view: CGPoint(x: x, y: y),
            world: (Self.number(body["wx"]) ?? 0, Self.number(body["wy"]) ?? 0)
        )
        guard let built = menu.menu(kind: kind, refs: body["refs"] as? [String] ?? [], id: body["id"] as? String) else { return }
        // The page's y runs down from its top; the view's may run up from its bottom.
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        built.popUp(positioning: nil, at: point, in: webView)
    }

    // MARK: What the Mac keeps and can draw

    /// Put on the model when the page is ready: the picture of the plane (Export
    /// as Image, `screenshot_canvas`) and the display switches, kept in step.
    func installRendererHooks() {
        guard role == .pane else { return }
        model.installImageExporter(exporterID) { [weak self] scale, refs in
            guard let self else { throw KnowledgeMapExportError.notReady }
            return try await self.exportImage(scale: scale, refs: refs)
        }
        installedExporter = true
        syncDisplay()
        if !observingDisplay {
            observingDisplay = true
            observeDisplay()
        }
    }

    /// Taken off the model when the canvas goes.
    func removeRendererHooks() {
        guard installedExporter else { return }
        installedExporter = false
        model.removeImageExporter(exporterID)
    }

    /// The plane drawn once by the page: a PNG of everything, or of the bounds
    /// of `refs`, at `scale` (lowered to keep a side under 8,192 points).
    func exportImage(scale: Double, refs: [String]?) async throws -> Data {
        guard let webView, isReady else { throw KnowledgeMapExportError.notReady }
        var refsArgument = "null"
        if let refs, let data = try? JSONSerialization.data(withJSONObject: refs) {
            refsArgument = String(decoding: data, as: UTF8.self)
        }
        let script = "window.knowledgeMap ? window.knowledgeMap.exportImage(\(scale), \(refsArgument)) : null"
        let result = try await webView.evaluateJavaScript(script)
        let prefix = "data:image/png;base64,"
        guard let url = result as? String, url.hasPrefix(prefix),
              let data = Data(base64Encoded: String(url.dropFirst(prefix.count))) else {
            throw KnowledgeMapExportError.nothingToDraw
        }
        return data
    }

    /// Tells the page the minimap and Focus switches when they differ from what
    /// it was last told.
    func syncDisplay() {
        guard isReady, role == .pane else { return }
        let state = "\(model.showsMinimap)|\(model.focusMode)"
        guard displayPush != state else { return }
        displayPush = state
        callRenderer("setDisplay", jsonObject: ["minimap": model.showsMinimap, "focus": model.focusMode])
    }

    /// Follows the switches on the model for as long as the canvas lives.
    private func observeDisplay() {
        withObservationTracking {
            _ = model.showsMinimap
            _ = model.focusMode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.webView != nil else { return }
                self.syncDisplay()
                self.observeDisplay()
            }
        }
    }
}

extension KnowledgeMapFieldChange {
    /// The value `KnowledgeMapModel.updateEdgeStyle` takes for this change:
    /// nil keeps the field, `clearedBy` is the default that clears it.
    func edgeValue(clearedBy cleared: Value) -> Value? {
        switch self {
        case .keep: return nil
        case .clear: return cleared
        case .set(let value): return value
        }
    }
}
