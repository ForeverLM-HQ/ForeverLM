import Foundation

// MARK: - Pinned chats
//
// Codex's **Pin chat** (docs/codex-shell-plan.md, Track 3): a pinned chat
// leaves its notebook's chats or the loose ones for Home's Pinned section,
// under the pinned notebooks. The pins are synced preference rows
// (`ChatPins`), written through `PreferenceStore` like the pages' pins, so the
// web and every Mac list the same; nothing touches the chat's record.

/// The Mac's reads and writes of the chat pin rows, as `PagePinRows` is for
/// the pages': `UserDefaults.standard` mirrored into `user_preferences` and
/// synced by `PreferenceStore`; a test binds its own defaults
/// (`PageSpaceRows.overrideDefaults`).
enum ChatPinRows {
    private static var defaults: UserDefaults { PageSpaceRows.overrideDefaults?.defaults ?? .standard }

    static func read() -> ChatPins {
        let rows = defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(ChatPins.preferenceKeyPrefix)
        }
        return ChatPins(rows: rows)
    }

    /// Writes a chat's row; nil removes it.
    static func write(_ value: String?, sessionID: String) {
        let key = ChatPins.key(sessionID: sessionID)
        if let override = PageSpaceRows.overrideDefaults {
            if let value {
                override.defaults.set(value, forKey: key)
            } else {
                override.defaults.removeObject(forKey: key)
            }
            return
        }
        // `PreferenceStore` drops a write that changes nothing, so the same
        // row written again never becomes a CloudKit save.
        if let value {
            PreferenceStore.set(value, forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }
}

extension StudioViewModel {

    /// Whether the learner pinned this chat.
    func isChatPinned(_ sessionID: String) -> Bool {
        chatPins.isPinned(sessionID)
    }

    /// **Pin chat** and **Unpin chat**, on a chat's row, its ⋯ and the chat's
    /// own ⋯. A day's memory review is Memory's and never pins. No network:
    /// the row is local first and syncs after.
    func setChatPinned(_ sessionID: String, pinned: Bool, now: Date = Date()) {
        guard !sessionID.isEmpty, !MemoryReviewSession.isMemorySession(sessionID) else { return }
        refreshChatPinsFromRows()
        if pinned {
            guard !chatPins.isPinned(sessionID) else { return }
            // The newest pin lists first, above a dragged one too.
            let seconds = chatPins.newPinValue(at: now)
            ChatPinRows.write(String(seconds), sessionID: sessionID)
            chatPins = chatPins.setting(seconds, for: sessionID)
        } else {
            guard chatPins.isPinned(sessionID) else { return }
            ChatPinRows.write(nil, sessionID: sessionID)
            chatPins = chatPins.setting(nil, for: sessionID)
        }
    }

    /// A pinned chat dropped on another in Home's Pinned section takes its
    /// place (`ChatPins.rowsMoving`), as Codex's pinned chats reorder by drag.
    /// `listed` is the section's order as drawn.
    func reorderPinnedChat(from sessionID: String, to destinationID: String, listed: [String]) {
        refreshChatPinsFromRows()
        for row in chatPins.rowsMoving(sessionID, to: destinationID, listed: listed) {
            ChatPinRows.write(String(row.seconds), sessionID: row.sessionID)
            chatPins = chatPins.setting(row.seconds, for: row.sessionID)
        }
    }

    /// The rows as stored now, before an act writes over them: a chat
    /// unpinned on another device reaches `UserDefaults` after the refresh
    /// that follows its sync round, so the cache can still hold it.
    func refreshChatPinsFromRows() {
        let stored = ChatPinRows.read()
        if stored != chatPins { chatPins = stored }
    }

    /// Home's Pinned chats out of the lists the rail draws: the pinned ones
    /// among `byNotebookID` and `outsideNotebooks`, highest place first, and
    /// those lists without them. A pinned chat that is hidden, deleted, a
    /// day's review or in another library is in neither list, so it lists
    /// nowhere until it is back.
    func splittingPinnedChats(
        byNotebookID: [String: [ReviewSessionRecord]],
        outsideNotebooks: [ReviewSessionRecord]
    ) -> (pinned: [ReviewSessionRecord], byNotebookID: [String: [ReviewSessionRecord]], outsideNotebooks: [ReviewSessionRecord]) {
        let split = chatPins.splitting(byGroup: byNotebookID, loose: outsideNotebooks, id: \.id)
        return (split.pinned, split.byGroup, split.loose)
    }
}
