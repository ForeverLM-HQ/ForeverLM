import Foundation
import OSLog

// MARK: - Memory on the Canvas: the page's side of it (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// What the canvas tells the renderer (Web/KnowledgeMap) about the Memory
// layer and a review in place, and what it hears back:
//
// - `setMemory({enabled, marks: {ref: {cards, due, fading, solid, dusty,
//   lastReviewedAt?}}})` whenever the layer or the marks change
//   (`KnowledgeMapMemory.revision`); `lastReviewedAt` is milliseconds since
//   1970.
// - `startReview({ref, index, total})` when a review begins, `reviewFocus`
//   with the same shape for each card after (another anchor, another round,
//   or the pane resized), `endReview()` when it ends. `index` counts from 0.
// - `{type: 'reviewAnchor', ref, rect: {x, y, w, h} | null}`: where the page
//   draws the reviewed card, in page CSS px from the canvas's top left.
// - `{type: 'reviewEscape'}`: Escape pressed in the page during a review.

/// What a canvas last told its page, so each change goes across once and a
/// page that loaded again hears everything again.
struct KnowledgeMapMemoryPushes {
    var memory = -1
    /// The review focus the page was last flown to; nil while the page is
    /// not in review mode.
    var reviewKey: String?
}

private let canvasMemoryLogger = Logger(subsystem: "com.foreverlm", category: "KnowledgeMapMemory")

extension KnowledgeMapCanvasView.Coordinator {
    /// Pushes the Memory layer and the review in place, after the cards and
    /// the layout.
    func syncMemory() {
        let memory = model.memory
        if memoryPushes.memory != memory.revision {
            memoryPushes.memory = memory.revision
            callMemory("setMemory", Self.memoryJSONObject(memory.payload))
        }
        // The review runs in the Canvas pane of the window it started in; the
        // window extended to follows that pane's camera, and a Canvas in
        // another window stays as it is.
        guard role == .pane else { return }
        if let review = memory.review, review.windowID == memoryWindowID,
           let focus = review.focus, let key = review.focusKey {
            if memoryPushes.reviewKey == nil {
                callMemory("startReview", focus.object)
            } else if memoryPushes.reviewKey != key {
                callMemory("reviewFocus", focus.object)
            }
            memoryPushes.reviewKey = key
        } else if memoryPushes.reviewKey != nil {
            memoryPushes.reviewKey = nil
            callMemory("endReview", nil)
        }
    }

    /// Calls the page's `window.knowledgeMap.<method>`. A page without the
    /// method (a renderer older than the protocol) is logged and left be: the
    /// Canvas draws on without the layer, and the review's question docks
    /// beside it. An exception the method throws surfaces as the Canvas's
    /// error, as every other call's does.
    private func callMemory(_ method: String, _ argument: Any?) {
        var json = "null"
        if let argument, let data = try? JSONSerialization.data(withJSONObject: argument) {
            json = String(decoding: data, as: UTF8.self)
        }
        let script = """
        (function () {
          var map = window.knowledgeMap;
          if (!map) { return 'nomap'; }
          if (typeof map.\(method) !== 'function') { return 'missing'; }
          map.\(method)(\(json));
          return 'ok';
        })();
        """
        webView?.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                Task { @MainActor in self?.model.rendererError = "The Canvas could not draw: \(error.localizedDescription)" }
            } else if result as? String == "missing" {
                canvasMemoryLogger.error("The Canvas page has no \(method, privacy: .public); its Memory layer and review in place wait for a renderer that has.")
            }
        }
    }

    /// `reviewAnchor` and `reviewEscape`.
    func handleReviewMessage(_ type: String, _ body: [String: Any]) {
        guard role == .pane, let review = model.memory.review, review.windowID == memoryWindowID else { return }
        switch type {
        case "reviewAnchor":
            guard let ref = body["ref"] as? String else { return }
            if let rect = body["rect"] as? [String: Any],
               let x = KnowledgeMapModel.proposalNumber(rect["x"]), let y = KnowledgeMapModel.proposalNumber(rect["y"]),
               let w = KnowledgeMapModel.proposalNumber(rect["w"]), let h = KnowledgeMapModel.proposalNumber(rect["h"]), w > 0, h > 0 {
                review.setAnchor(ref: ref, rect: CGRect(x: x, y: y, width: w, height: h))
            } else {
                review.setAnchor(ref: ref, rect: nil)
            }
        case "reviewEscape":
            model.memory.requestEscape()
        default:
            break
        }
    }

    private static func memoryJSONObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
