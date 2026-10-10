import Foundation
import Observation

// MARK: - Back and forward over canvases (docs/heptabase-canvas-parity.md, "Nested whiteboards")
//
// Heptabase's ⌘[ and ⌘] walk back and forth over the whiteboards a window
// opened. A window here keeps the canvases it opened in a stack with a place
// in it: opening one pushes it (and drops what was ahead), Back and Forward
// move along the stack without pushing. One lives on each `StudioWindowState`,
// never stored: a relaunch starts every window with no history.

/// Which way ⌘[ (back) or ⌘] (forward) walks.
enum KnowledgeMapHistoryDirection: String, Equatable, Sendable {
    case back
    case forward
}

/// The canvases one window opened, oldest first, and where it stands among them.
@MainActor
@Observable
final class KnowledgeMapCanvasHistory {
    /// The most canvases remembered; the oldest go first.
    static let capacity = 50

    private(set) var stack: [String] = []
    private(set) var index = -1

    /// Whether there is anywhere to go: two canvases or more were opened.
    var hasHistory: Bool { stack.count > 1 }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < stack.count - 1 }

    /// The canvas the window opened, pushed after `current`, the canvas open
    /// before it (so the first canvas opened is the first step back). What was
    /// ahead of the place the learner stood is dropped, as a browser does. The
    /// same canvas twice in a row is no new step.
    func visit(_ id: String, from current: String?) {
        if let current, !current.isEmpty, stack.isEmpty || stack[index] != current {
            push(current)
        }
        push(id)
    }

    /// The canvas one step `direction` away, with the place left where it is;
    /// nil at the end of the stack. A caller that cannot show it (the canvas is
    /// gone) calls `forget` and asks again.
    func candidate(_ direction: KnowledgeMapHistoryDirection) -> String? {
        switch direction {
        case .back: return canGoBack ? stack[index - 1] : nil
        case .forward: return canGoForward ? stack[index + 1] : nil
        }
    }

    /// Moves the place one step `direction`, to the canvas `candidate` named;
    /// nil at the end of the stack.
    @discardableResult
    func step(_ direction: KnowledgeMapHistoryDirection) -> String? {
        guard candidate(direction) != nil else { return nil }
        index += direction == .back ? -1 : 1
        return stack[index]
    }

    /// Takes a canvas that cannot be shown (deleted, or in no list now) out of
    /// the stack, keeping the place on the entry it was on or, when that was
    /// the canvas taken out, on the one before it.
    func forget(_ id: String) {
        guard stack.contains(id) else { return }
        var kept: [String] = []
        var place = -1
        for (position, entry) in stack.enumerated() where entry != id {
            // The same canvas twice in a row after a removal is one step.
            if kept.last == entry {
                if position <= index { place = kept.count - 1 }
                continue
            }
            kept.append(entry)
            if position <= index { place = kept.count - 1 }
        }
        stack = kept
        index = kept.isEmpty ? -1 : max(0, min(place, kept.count - 1))
    }

    private func push(_ id: String) {
        if index >= 0, index < stack.count, stack[index] == id { return }
        if index < stack.count - 1 { stack.removeSubrange((index + 1)...) }
        stack.append(id)
        if stack.count > Self.capacity { stack.removeFirst(stack.count - Self.capacity) }
        index = stack.count - 1
    }
}

extension StudioViewModel {
    /// ⌘[ and ⌘] over the canvases `windowState` (the window in scope when
    /// nil) opened: shows the one before or after the canvas open now, as the
    /// canvas open on this Mac, without pushing a step. A canvas deleted since
    /// is skipped. Nothing happens at either end of the history.
    func navigateCanvasHistory(_ direction: KnowledgeMapHistoryDirection, in windowState: StudioWindowState? = nil) {
        let destination = windowState ?? activeWindowState
        let history = destination.canvasHistory
        // Opened some other way (an assistant, a launch), the canvas open may
        // not be where the history stands: it is placed first.
        history.visit(knowledgeMap.mapID, from: nil)
        while let id = history.candidate(direction) {
            guard canvasIsOpenable(id) else {
                history.forget(id)
                continue
            }
            history.step(direction)
            showCanvas(id)
            openKnowledgeMap(in: destination)
            return
        }
    }

    /// Whether a canvas in a history can be shown: its row is still there.
    /// The open canvas may have no row yet, so it counts.
    private func canvasIsOpenable(_ id: String) -> Bool {
        id == knowledgeMap.mapID || canvases.canvas(id) != nil
    }
}
