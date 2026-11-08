import Foundation
import os

enum MCPRuntimePreferences {
    static var assistantIntegrationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "studio.assistantIntegrationsEnabled") as? Bool ?? true
    }
}

/// Which notebook each open Studio window holds, and which window is frontmost
/// (the key Studio window, or the one used last while another app or a
/// popped-out Reader is in front), as the app last published them. Only
/// `get_app_context` reads it, to answer what is open in ForeverLM: what a
/// window holds is the learner's view, never an implicit MCP default, so every
/// notebook-scoped tool still takes its notebook_id from the caller.
///
/// Published on the main actor by `StudioWindowRegistry` whenever a window
/// opens, closes, becomes key or opens or leaves a notebook; read by tool
/// calls on their own tasks, so the list sits behind a lock. Nothing is
/// written to disk: with no window open there is nothing to name.
enum MCPAppWindows {
    struct Window: Equatable, Sendable {
        /// Nil while the window shows the Space, the Library or
        /// panes outside any notebook.
        let notebookID: String?
        let isFrontmost: Bool
    }

    private static let published = OSAllocatedUnfairLock<[Window]>(initialState: [])

    /// Frontmost first, then the others in the order they opened.
    static var current: [Window] {
        published.withLock { $0 }
    }

    static func publish(_ windows: [Window]) {
        published.withLock { $0 = windows }
    }

    /// `notebookIDs` in the order the windows opened; `frontmost` the index of
    /// the frontmost one. The frontmost leads, the rest keep their order.
    static func ordered(notebookIDs: [String?], frontmost: Int?) -> [Window] {
        var windows = notebookIDs.enumerated().map { index, id in
            Window(notebookID: id, isFrontmost: index == frontmost)
        }
        if let index = windows.firstIndex(where: \.isFrontmost) {
            windows.insert(windows.remove(at: index), at: 0)
        }
        return windows
    }
}
