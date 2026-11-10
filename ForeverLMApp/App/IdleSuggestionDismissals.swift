// The idle welcome suggestions the learner has dismissed.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// Suggestion rows the learner has hidden from the idle chat.
///
/// Keys name *what* a suggestion points at — today's date, a session id, the
/// source in the reader — never just its category, so hiding a row declines that
/// specific nudge instead of switching a whole kind of suggestion off forever.
/// Tomorrow's schedule, a newer session, or a different source each produce a
/// fresh key and surface again.
///
/// UserDefaults only: this is view chrome, not knowledge-base data, so it
/// deliberately stays out of the sync pipeline. Keys are held most-recent-first
/// and trimmed at `capacity` — the per-source keys would otherwise grow with the
/// library, and a dismissal aging out after dozens of newer ones is fine.
@MainActor
@Observable
final class IdleSuggestionDismissals {
    static let shared = IdleSuggestionDismissals()
    private static let defaultsKey = "chat.dismissedIdleSuggestions"
    private static let capacity = 60

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private(set) var keys: [String]

    private init() {
        keys = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Scope component for suggestions about *today's* plan, so hiding one
    /// clears today's nudge rather than every future one.
    static func dayScope(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    func isDismissed(_ key: String) -> Bool {
        keys.contains(key)
    }

    func dismiss(_ key: String) {
        guard !keys.contains(key) else { return }
        var updated = keys
        updated.insert(key, at: 0)
        if updated.count > Self.capacity {
            updated.removeLast(updated.count - Self.capacity)
        }
        persist(updated)
    }

    /// Brings every hidden suggestion back. The idle state's restore link is the
    /// only way out of a fully dismissed stack, so this has to stay reachable
    /// from the UI — otherwise dismissing the last row is a dead end.
    func restoreAll() {
        guard !keys.isEmpty else { return }
        persist([])
    }

    private func persist(_ updated: [String]) {
        keys = updated
        UserDefaults.standard.set(updated, forKey: Self.defaultsKey)
    }
}
