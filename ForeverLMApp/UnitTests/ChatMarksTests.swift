import Foundation
import Testing
@testable import ForeverLM

// Chats as Codex threads (docs/codex-shell-plan.md, Track 3): the pins'
// synced rows (`ChatPins`) and this Mac's unread marks (`ChatUnreadState`,
// `ChatReadMarks`). Every test that writes binds its own defaults suite,
// never the standard defaults the Dev build and parallel suites share.

private func withChatDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let suiteName = "ChatMarksTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try body(defaults)
}

// MARK: - Pins

@Suite("Pinned chats: the rows")
struct ChatPinsTests {
    @Test("Rows are read under their prefix; a value that is no whole second and an empty id are no row")
    func readsRows() {
        let pins = ChatPins(rows: [
            "chat.pinned.chat-a": "1700000000",
            "chat.pinned.chat-b": NSNumber(value: 1_700_000_100),
            "chat.pinned.chat-c": "soon",
            "chat.pinned.": "1700000000",
            "page.pinned.doc-1": "1700000000",
        ])
        #expect(pins.pinnedAt == ["chat-a": 1_700_000_000, "chat-b": 1_700_000_100])
        #expect(ChatPins.key(sessionID: "chat-a") == "chat.pinned.chat-a")
        #expect(ChatPins.sessionID(fromKey: "chat.pinned.chat-a") == "chat-a")
        #expect(ChatPins.sessionID(fromKey: "page.pinned.chat-a") == nil)
        #expect(ChatPins.sessionID(fromKey: "chat.pinned.") == nil)
    }

    @Test("The highest place lists first, and the id breaks a tie the same way on every device")
    func order() {
        let pins = ChatPins(pinnedAt: ["b": 5, "a": 5, "c": 9, "d": 1])
        #expect(pins.orderedSessionIDs == ["c", "a", "b", "d"])
    }

    @Test("A new pin lists first, above a pin a drag placed higher than the clock")
    func newPinListsFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ChatPins().newPinValue(at: now) == 1_700_000_000)
        #expect(ChatPins(pinnedAt: ["a": 1_600_000_000]).newPinValue(at: now) == 1_700_000_000)
        #expect(ChatPins(pinnedAt: ["a": 1_700_000_050]).newPinValue(at: now) == 1_700_000_051)
    }

    @Test("A pin dropped on another takes its place, writing only its own row while there is room")
    func dragWritesOneRow() {
        let pins = ChatPins(pinnedAt: ["a": 100, "b": 80, "c": 60, "d": 40])
        let listed = pins.orderedSessionIDs
        // To the top: just above the old top.
        let top = pins.rowsMoving("c", to: "a", listed: listed)
        #expect(top.map(\.sessionID) == ["c"] && top.map(\.seconds) == [101])
        // To the bottom: just below the old bottom.
        let bottom = pins.rowsMoving("a", to: "d", listed: listed)
        #expect(bottom.map(\.sessionID) == ["a"] && bottom.map(\.seconds) == [39])
        // Down one, between its new neighbours.
        let down = pins.rowsMoving("a", to: "b", listed: listed)
        #expect(down.map(\.sessionID) == ["a"] && down.map(\.seconds) == [70])
        // Up one, between its new neighbours.
        let up = pins.rowsMoving("d", to: "c", listed: listed)
        #expect(up.map(\.sessionID) == ["d"] && up.map(\.seconds) == [70])
        let after = up.reduce(pins) { $0.setting($1.seconds, for: $1.sessionID) }
        #expect(after.orderedSessionIDs == ["a", "b", "d", "c"])
    }

    @Test("With no room between the new neighbours the listed pins are numbered again, top down, and only changed rows are written")
    func dragRenumbers() {
        let pins = ChatPins(pinnedAt: ["a": 100, "b": 99, "c": 98, "d": 97])
        let rows = pins.rowsMoving("d", to: "b", listed: pins.orderedSessionIDs)
        let after = rows.reduce(pins) { $0.setting($1.seconds, for: $1.sessionID) }
        #expect(after.orderedSessionIDs == ["a", "d", "b", "c"])
        #expect(!rows.contains { $0.sessionID == "a" })
        #expect(Set(after.pinnedAt.values).count == 4)
    }

    @Test("Nothing moves onto itself, from or to a chat that is not pinned, or out of the listed chats")
    func dragNoOps() {
        let pins = ChatPins(pinnedAt: ["a": 100, "b": 80])
        #expect(pins.rowsMoving("a", to: "a", listed: ["a", "b"]).isEmpty)
        #expect(pins.rowsMoving("x", to: "a", listed: ["a", "b", "x"]).isEmpty)
        #expect(pins.rowsMoving("a", to: "x", listed: ["a", "b", "x"]).isEmpty)
        #expect(pins.rowsMoving("a", to: "b", listed: ["b"]).isEmpty)
    }

    @Test("Pinned chats leave their notebook's list and the loose one for Pinned; a pin whose chat is in no list shows nowhere")
    func splitsTheSidebar() {
        let pins = ChatPins(pinnedAt: ["n1-b": 10, "loose-a": 20, "gone": 30])
        let split = pins.splitting(
            byGroup: ["n1": ["n1-a", "n1-b"], "n2": ["n2-a"]],
            loose: ["loose-a", "loose-b"],
            id: { $0 }
        )
        #expect(split.pinned == ["loose-a", "n1-b"])
        #expect(split.byGroup == ["n1": ["n1-a"], "n2": ["n2-a"]])
        #expect(split.loose == ["loose-b"])
        let none = ChatPins().splitting(byGroup: ["n1": ["x"]], loose: ["y"], id: { $0 })
        #expect(none.pinned.isEmpty && none.byGroup == ["n1": ["x"]] && none.loose == ["y"])
    }

    @Test("The pins are a synced preference family the catalog leaves to their own writers")
    func pinsSync() {
        #expect(SyncedPreferenceKeys.syncedPrefixes.contains(ChatPins.preferenceKeyPrefix))
        #expect(SyncedPreferenceKeys.isSynced(ChatPins.key(sessionID: "chat-a")))
        #expect(!SyncedPreferenceKeys.isSynced(ChatReadMarks.defaultsKey))
    }

    @Test("The Mac's rows are one key per chat: written, read back, and removed")
    func macRows() throws {
        try withChatDefaults { defaults in
            PageSpaceRows.$overrideDefaults.withValue(PageSpaceRows.DefaultsOverride(defaults: defaults)) {
                #expect(ChatPinRows.read().pinnedAt.isEmpty)
                ChatPinRows.write("1700000000", sessionID: "chat-a")
                #expect(defaults.string(forKey: "chat.pinned.chat-a") == "1700000000")
                #expect(ChatPinRows.read().isPinned("chat-a"))
                ChatPinRows.write(nil, sessionID: "chat-a")
                #expect(defaults.object(forKey: "chat.pinned.chat-a") == nil)
            }
        }
    }
}

// MARK: - Unread

@Suite("Unread chats: this Mac's dots")
struct ChatUnreadStateTests {
    // Each rule answers whether the marks changed; the answer is bound
    // before it is checked, since `#expect` cannot call a mutating method.

    @Test("A reply that finishes while no window shows its chat leaves it unread; one on screen does not")
    func replyFinished() {
        var state = ChatUnreadState()
        state.showing(["chat-a"], inWindow: "w1")
        let onScreen = state.replyFinished("chat-a")
        #expect(!onScreen && !state.isUnread("chat-a"))
        let offScreen = state.replyFinished("chat-b")
        #expect(offScreen && state.isUnread("chat-b"))
        // On screen in another window counts too.
        state.showing(["chat-c"], inWindow: "w2")
        let otherWindow = state.replyFinished("chat-c")
        #expect(!otherWindow && !state.isUnread("chat-c"))
        // Finishing twice changes nothing.
        let again = state.replyFinished("chat-b")
        #expect(!again)
    }

    @Test("Showing a chat reads it")
    func showingReads() {
        var state = ChatUnreadState(unread: ["chat-a", "chat-b"])
        let changed = state.showing(["chat-a"], inWindow: "w1")
        #expect(changed)
        #expect(!state.isUnread("chat-a"))
        #expect(state.isUnread("chat-b"))
    }

    @Test("Marked unread while on screen, a chat stays unread until a window shows it again")
    func markUnreadOnScreen() {
        var state = ChatUnreadState()
        state.showing(["chat-a"], inWindow: "w1")
        let marked = state.markUnread("chat-a")
        #expect(marked)
        // The window showing another chat beside it does not read it.
        let beside = state.showing(["chat-a", "chat-b"], inWindow: "w1")
        #expect(!beside && state.isUnread("chat-a"))
        // Leaving it and coming back does.
        state.showing(["chat-b"], inWindow: "w1")
        let back = state.showing(["chat-a"], inWindow: "w1")
        #expect(back && !state.isUnread("chat-a"))
    }

    @Test("A closed window shows nothing, so a reply finishing then leaves its chat unread")
    func closedWindow() {
        var state = ChatUnreadState()
        state.showing(["chat-a"], inWindow: "w1")
        state.closingWindow("w1")
        #expect(state.visibleSessionIDs.isEmpty)
        let finished = state.replyFinished("chat-a")
        #expect(finished && state.isUnread("chat-a"))
    }

    @Test("Mark as Read, Mark All as Read")
    func marks() {
        var state = ChatUnreadState(unread: ["a", "b"])
        let first = state.markRead("a")
        let second = state.markRead("a")
        #expect(first && !second)
        let all = state.markAllRead()
        let allAgain = state.markAllRead()
        #expect(all && !allAgain && state.unread.isEmpty)
        let blank = state.markUnread("")
        #expect(!blank)
    }

    @Test("The marks survive a relaunch in this Mac's defaults, and a deleted chat's running turn marks nothing")
    @MainActor
    func persistsAndForgets() throws {
        try withChatDefaults { defaults in
            let marks = ChatReadMarks(defaults: defaults)
            marks.replyFinished("chat-a")
            marks.replyFinished("chat-b")
            #expect(marks.unreadSessionIDs == ["chat-a", "chat-b"])
            #expect(defaults.stringArray(forKey: ChatReadMarks.defaultsKey) == ["chat-a", "chat-b"])
            let relaunched = ChatReadMarks(defaults: defaults)
            #expect(relaunched.unreadSessionIDs == ["chat-a", "chat-b"])
            relaunched.forget("chat-b")
            relaunched.replyFinished("chat-b")
            #expect(relaunched.unreadSessionIDs == ["chat-a"])
            relaunched.showing(["chat-a"], inWindow: "w1")
            #expect(relaunched.unreadSessionIDs.isEmpty)
            #expect(defaults.stringArray(forKey: ChatReadMarks.defaultsKey) == [])
        }
    }
}
