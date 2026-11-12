import Foundation

// MARK: - Export as Image, and the canvas as Markdown
//
// Heptabase exports a whiteboard as an image and a selection's cards as
// Markdown (docs/heptabase-canvas-parity.md, "Sharing, export, platforms");
// the Canvas does the same from its menu and from a card's right-click
// (docs/knowledge-map-design.md, "Versions, export and publishing"). The
// picture is drawn by the renderer, which only the open canvas in a Canvas
// pane has (`KnowledgeMapModel.imageExporter`); the Markdown is read from the
// layout and the cards' words (`KnowledgeMapMarkdown`).

/// Why a canvas could not be drawn to a picture.
enum CanvasExportError: LocalizedError, Equatable {
    /// Another canvas is the open one.
    case notOpen(name: String)
    /// The canvas is the open one but no Canvas pane is drawing it.
    case notShowing(name: String)
    /// Nothing is placed on it.
    case nothingToDraw(name: String)

    var errorDescription: String? {
        switch self {
        case .notOpen(let name):
            return "‘\(name)’ is not open. A canvas is drawn only while it is open in a Canvas pane: open it and try again."
        case .notShowing(let name):
            return "‘\(name)’ is not showing in a Canvas pane, so there is nothing to draw it from. Open the Canvas and try again."
        case .nothingToDraw(let name):
            return "‘\(name)’ has nothing on it to draw yet."
        }
    }
}

enum CanvasExport {
    /// The scales Export as Image offers: one pixel to a point on the plane,
    /// and twice that.
    static let scales: [Double] = [1, 2]

    /// The picture's suggested file name: the canvas's name, without the
    /// characters a file name cannot hold.
    static func fileName(for canvasName: String) -> String {
        let cleaned = canvasName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? KnowledgeMap.unnamedCanvasName : cleaned).png"
    }

    /// "1×", "2×", "1.5×".
    static func scaleLabel(_ scale: Double) -> String {
        scale == scale.rounded() ? "\(Int(scale))×" : "\(scale)×"
    }
}

extension StudioViewModel {
    /// A canvas's name as the Space lists it; the unnamed canvas's while it
    /// has no row yet.
    func canvasDisplayName(_ canvasID: String) -> String {
        canvases.canvas(canvasID)?.name ?? (canvasID == knowledgeMap.mapID ? openCanvasName : KnowledgeMap.unnamedCanvasName)
    }

    /// The open canvas drawn to a PNG: all of it, or the bounds of `refs`,
    /// at `scale` pixels to a point of the plane (2 is Retina). Throws a
    /// clear reason when the canvas is not the open one, no Canvas pane is
    /// drawing it, or nothing is placed on it.
    func exportCanvasImageData(canvasID: String, scale: Double, refs: [String]? = nil) async throws -> Data {
        let name = canvasDisplayName(canvasID)
        // A window open on the canvas draws it: this one before any other,
        // and one whose pane is up before one whose pane is not.
        guard let open = knowledgeMapModel(showing: canvasID) else { throw CanvasExportError.notOpen(name: name) }
        let drawing = open.imageExporter != nil ? open : knowledgeMaps(showing: canvasID).first { $0.imageExporter != nil }
        guard let exporter = drawing?.imageExporter else { throw CanvasExportError.notShowing(name: name) }
        let layout = open.layout
        guard !layout.placements.isEmpty || !layout.regions.isEmpty else { throw CanvasExportError.nothingToDraw(name: name) }
        return try await exporter(scale, refs)
    }

    /// The open canvas, or `refs` of it, as Markdown: a title line for the
    /// whole canvas, then `KnowledgeMapMarkdown`'s outline. Empty when there
    /// is nothing to write. Waits for the cards' words when the Canvas has
    /// not loaded them yet.
    func canvasMarkdown(refs: [String]) async -> String {
        let model = knowledgeMap
        let name = openCanvasName
        if model.content.nodes.isEmpty { await refreshKnowledgeMapContent(for: model) }
        let body = KnowledgeMapMarkdown.render(
            layout: model.layout,
            nodes: model.nodesByRef,
            refs: refs,
            cardSize: { ref in (KnowledgeMap.cardWidth, model.cardHeight(of: ref)) }
        )
        guard refs.isEmpty, !body.isEmpty else { return body }
        return "# \(KnowledgeMapMarkdown.inline(name))\n\n" + body
    }
}
