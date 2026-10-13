import Foundation
import Observation

// MARK: - Chats as Codex threads
//
// Codex's two marks on a chat (docs/codex-shell-plan.md, Track 3; product
// owner, 2026-10-13: "make sure every feature of foreverlm that is shared with
// codex ... at first it should be a copy of the codex ... functionality"):
// **Pin chat**, which keeps a chat in Home's Pinned section and follows the
// account, and the unread dot, which marks a chat whose reply finished while
// it was on screen nowhere and is this Mac's view alone, as Codex's is that
// app's. Hide stays ForeverLM's put-away action in place of Codex's Archive.

/// The chats the learner pinned, one synced preference row each
/// (`SyncedPreferenceKeys.syncedPrefixes`), as `PagePins` keeps the pages.
///
/// `chat.pinned.<sessionID>`: where the chat sits in Home's Pinned section, as
/// whole seconds since 1970 in a String — the second it was pinned, or the
/// value a drag gave it — the highest first. One row per chat, so two devices
/// pinning two chats at once keep both; no row is an unpinned chat. Per
/// member, keyed by the chat's id and never on its record (teams-design rule
/// 7), so no schema change. Foundation-only, so the web's twin
/// (`library-chat-marks.js`) runs the same cases.
struct ChatPins: Equatable, Sendable {
    static let preferenceKeyPrefix = "chat.pinned."

    /// Each pinned chat's place, by session id: higher lists first.
    private(set) var pinnedAt: [String: Int]

    init(pinnedAt: [String: Int] = [:]) {
        self.pinnedAt = pinnedAt.filter { !$0.key.isEmpty }
    }

    /// The pins in a set of preference rows: every row under the prefix, the
    /// rest ignored. A value that is not a whole number of seconds, as a
    /// String or a number, is no row.
    init(rows: [String: Any]) {
        var pins: [String: Int] = [:]
        for (key, value) in rows {
            guard let sessionID = Self.sessionID(fromKey: key) else { continue }
            if let text = value as? String, let seconds = Int(text.trimmingCharacters(in: .whitespaces)) {
                pins[sessionID] = seconds
            } else if let number = value as? NSNumber {
                pins[sessionID] = number.intValue
            }
        }
        self.init(pinnedAt: pins)
    }

    static func key(sessionID: String) -> String {
        preferenceKeyPrefix + sessionID
    }

    static func sessionID(fromKey key: String) -> String? {
        guard key.hasPrefix(preferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(preferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    func isPinned(_ sessionID: String) -> Bool {
        pinnedAt[sessionID] != nil
    }

    /// The place a chat pinned at `date` takes: that second, or just above
    /// the highest pin when a drag placed one higher, so a new pin always
    /// lists first.
    func newPinValue(at date: Date) -> Int {
        max(Int(date.timeIntervalSince1970), (pinnedAt.values.max() ?? 0) + 1)
    }

    /// The pinned chats' ids, the highest place first (the newest pin, unless
    /// a drag placed it); the id breaks a tie so every device lists the same.
    var orderedSessionIDs: [String] {
        pinnedAt.sorted { left, right in
            left.value != right.value ? left.value > right.value : left.key < right.key
        }.map(\.key)
    }

    /// The pinned chats out of a sidebar's lists: those of `byGroup` (a
    /// notebook's chats, by notebook) and `loose` that are pinned, highest
    /// place first, and the lists without them. A pin whose chat is in
    /// neither list (hidden, deleted, another library's) lists nowhere.
    func splitting<Record>(
        byGroup: [String: [Record]],
        loose: [Record],
        id: (Record) -> String
    ) -> (pinned: [Record], byGroup: [String: [Record]], loose: [Record]) {
        guard !pinnedAt.isEmpty else { return ([], byGroup, loose) }
        var listed: [String: Record] = [:]
        for record in loose where isPinned(id(record)) { listed[id(record)] = record }
        for records in byGroup.values {
            for record in records where isPinned(id(record)) { listed[id(record)] = record }
        }
        guard !listed.isEmpty else { return ([], byGroup, loose) }
        return (
            orderedSessionIDs.compactMap { listed[$0] },
            byGroup.mapValues { $0.filter { listed[id($0)] == nil } },
            loose.filter { listed[id($0)] == nil }
        )
    }

    /// This state after a chat's row is written (nil: removed).
    func setting(_ seconds: Int?, for sessionID: String) -> ChatPins {
        var copy = self
        copy.pinnedAt[sessionID] = seconds
        return copy
    }

    /// The rows a drag in the Pinned section writes: `moved` takes
    /// `destination`'s place among `listed` (the pinned chats as the section
    /// draws them, highest first) and the rows between shift, as a chat
    /// dropped on a chat does in its list (`reorderReviewSession`). Only the
    /// moved chat's row is written while there is room between its new
    /// neighbours; when there is none, the listed chats are numbered again
    /// from the top down and only the rows that change are written. Empty
    /// when nothing moves.
    func rowsMoving(_ moved: String, to destination: String, listed: [String]) -> [(sessionID: String, seconds: Int)] {
        var order = listed.filter { pinnedAt[$0] != nil }
        guard moved != destination,
              let source = order.firstIndex(of: moved),
              let target = order.firstIndex(of: destination) else { return [] }
        order.remove(at: source)
        order.insert(moved, at: target)
        let above = target > 0 ? pinnedAt[order[target - 1]] : nil
        let below = target + 1 < order.count ? pinnedAt[order[target + 1]] : nil
        let current = pinnedAt[moved] ?? 0
        let single: Int?
        switch (above, below) {
        case (nil, let below?):
            single = below + 1
        case (let above?, nil):
            single = above - 1
        case (let above?, let below?):
            single = above - below >= 2 ? below + (above - below) / 2 : nil
        case (nil, nil):
            return []
        }
        if let single {
            return single == current ? [] : [(moved, single)]
        }
        // No room between the neighbours: number the listed chats again,
        // each one below the one above it.
        var rows: [(sessionID: String, seconds: Int)] = []
        var ceiling = Int.max
        for id in order {
            let value = pinnedAt[id] ?? 0
            let kept = value < ceiling ? value : ceiling - 1
            if kept != value { rows.append((id, kept)) }
            ceiling = kept
        }
        return rows
    }
}

// MARK: - Unread chats

/// Which chats read as unread on this Mac, and the rules that mark them: a
/// chat whose reply finished while it was on screen in no window gets
/// Codex's dot, and showing it in a window reads it. The learner's Mark as
/// Read and Mark as Unread set it by hand; a chat marked unread while it is on
/// screen stays unread until it is shown again. This Mac's view, never
/// synced, as a notebook's outputs' seen marks are (`NotebookOutputSeenState`).
/// Foundation-only and pure; `ChatReadMarks` keeps it for the app.
struct ChatUnreadState: Equatable, Sendable {
    /// The unread chats' ids.
    private(set) var unread: Set<String>
    /// The chats on screen, by window.
    private(set) var onScreen: [String: Set<String>] = [:]

    init(unread: Set<String> = []) {
        self.unread = unread
    }

    /// Every chat on screen in some window.
    var visibleSessionIDs: Set<String> {
        onScreen.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    func isUnread(_ sessionID: String) -> Bool {
        unread.contains(sessionID)
    }

    /// A window now shows `sessionIDs`. A chat it did not show a moment ago
    /// is read: opening a chat is what reads it. Answers whether the unread
    /// set changed.
    @discardableResult
    mutating func showing(_ sessionIDs: Set<String>, inWindow window: String) -> Bool {
        let before = onScreen[window] ?? []
        if sessionIDs.isEmpty {
            onScreen[window] = nil
        } else {
            onScreen[window] = sessionIDs
        }
        let opened = sessionIDs.subtracting(before)
        let read = unread.intersection(opened)
        unread.subtract(read)
        return !read.isEmpty
    }

    /// A window closed: its chats are on screen there no longer.
    mutating func closingWindow(_ window: String) {
        onScreen[window] = nil
    }

    /// A chat's reply finished. It is unread unless some window shows it.
    @discardableResult
    mutating func replyFinished(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty, !visibleSessionIDs.contains(sessionID), !unread.contains(sessionID) else { return false }
        unread.insert(sessionID)
        return true
    }

    /// Mark as Read.
    @discardableResult
    mutating func markRead(_ sessionID: String) -> Bool {
        unread.remove(sessionID) != nil
    }

    /// Mark as Unread: it stays unread while it is on screen, until it is
    /// shown again.
    @discardableResult
    mutating func markUnread(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        return unread.insert(sessionID).inserted
    }

    /// Mark All as Read.
    @discardableResult
    mutating func markAllRead() -> Bool {
        guard !unread.isEmpty else { return false }
        unread = []
        return true
    }
}

/// This Mac's unread chats (`ChatUnreadState`), kept in this Mac's defaults
/// so the dots survive a relaunch. Each window's icon strip reports the chats
/// it shows and the ones running in it (`StudioNavigationRail`); the rail's
/// rows, its notebook rows and the strip's bell read the marks.
@MainActor @Observable
final class ChatReadMarks {
    static let shared = ChatReadMarks()

    /// The unread chats' ids, as a String array. This Mac's alone
    /// (`SyncedPreferenceKeys.excluded`).
    static let defaultsKey = "chat.unread.v1"

    /// The unread chats' ids: the one part the rows observe, so a window
    /// switching chats redraws nothing unless a mark changed.
    private(set) var unreadSessionIDs: Set<String>
    /// The marks and what each window shows.
    @ObservationIgnored private var state: ChatUnreadState
    /// Chats deleted while this Mac ran: a running turn a delete ends is not
    /// a reply that finished.
    @ObservationIgnored private var forgotten: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        state = ChatUnreadState(unread: stored)
        unreadSessionIDs = stored
    }

    func isUnread(_ sessionID: String) -> Bool { unreadSessionIDs.contains(sessionID) }

    /// Every chat on screen in some window.
    var visibleSessionIDs: Set<String> { state.visibleSessionIDs }

    func showing(_ sessionIDs: Set<String>, inWindow window: String) {
        apply { $0.showing(sessionIDs, inWindow: window) }
    }

    func closingWindow(_ window: String) {
        state.closingWindow(window)
    }

    func replyFinished(_ sessionID: String) {
        guard !forgotten.contains(sessionID) else { return }
        apply { $0.replyFinished(sessionID) }
    }

    func markRead(_ sessionID: String) {
        apply { $0.markRead(sessionID) }
    }

    func markUnread(_ sessionID: String) {
        apply { $0.markUnread(sessionID) }
    }

    func markAllRead() {
        apply { $0.markAllRead() }
    }

    /// A chat deleted here: its mark goes, and the end of its running turn
    /// marks nothing.
    func forget(_ sessionID: String) {
        forgotten.insert(sessionID)
        markRead(sessionID)
    }

    /// Runs one rule on the state; a changed mark is published and stored.
    private func apply(_ rule: (inout ChatUnreadState) -> Bool) {
        let changed = rule(&state)
        guard changed, unreadSessionIDs != state.unread else { return }
        unreadSessionIDs = state.unread
        defaults.set(state.unread.sorted(), forKey: Self.defaultsKey)
    }
}
