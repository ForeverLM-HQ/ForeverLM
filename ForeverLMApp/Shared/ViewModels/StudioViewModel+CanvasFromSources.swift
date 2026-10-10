import Foundation

// MARK: - A canvas made from sources (docs/heptabase-canvas-parity.md, "Getting things onto the plane")
//
// Heptabase's "research a topic" opens a whiteboard with the materials on it
// and a chat beside it. Here: select sources in the Sources list or the
// Library, choose New Canvas from Selection (or New ▸ Canvas from Selected
// Sources in the Space), and one canvas is made, the sources set down as one
// block in a region, the canvas opened, and a chat opened beside it with the
// sources as its context and the first question typed, unsent. Nothing is
// asked of a model until the learner sends it.

extension StudioViewModel {
    /// What the chat beside a canvas made from sources has typed in its composer.
    static func canvasFromSourcesDraft(count: Int) -> String {
        count == 1
            ? "Help me make sense of this source on my Canvas: what are the main ideas and how do they connect?"
            : "Help me make sense of these \(count) sources on my Canvas: what are the main ideas and how do they connect?"
    }

    /// The region the sources are set down in.
    static let canvasFromSourcesRegionName = "Sources"

    /// Makes a canvas of `sourceIDs` (those the library holds, once each, in
    /// the order given), named `name` or after the first source, opens it in
    /// `destinationWindowState` (the window in scope when nil), and opens a
    /// chat beside it with the sources as context and
    /// `canvasFromSourcesDraft` typed, unsent. Returns the canvas, or nil when
    /// none of the sources is in the library (the toast says so).
    @discardableResult
    func makeCanvasFromSources(sourceIDs: [String], name: String? = nil, in destinationWindowState: StudioWindowState? = nil) -> KnowledgeMapCanvas? {
        var seen: Set<String> = []
        let ids = sourceIDs.map(canonicalSourceID).filter { articlesById[$0] != nil && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            showToast("Select the sources to put on a canvas")
            return nil
        }
        let destination = destinationWindowState ?? activeWindowState
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = given.isEmpty ? (articlesById[ids[0]].map { displayTitle(for: $0) } ?? KnowledgeMap.newCanvasName) : given
        let canvas = createCanvas(named: title)
        inWindow(destination) {
            openCanvas(canvas.id, in: destination)
            let map = knowledgeMap
            let refs = ids.map { KnowledgeMap.ItemRef(kind: .source, id: $0).description }
            map.placeBlock(refs, near: map.arrivalCenter(), regionName: Self.canvasFromSourcesRegionName)
            map.send(.fit)
            // The canvas has no Ideas yet, so the chat has no questions of its own to offer.
            openChatBesideKnowledgeMap(draft: Self.canvasFromSourcesDraft(count: ids.count), sourceIDs: ids, offersQuestions: false)
        }
        return canvas
    }
}
