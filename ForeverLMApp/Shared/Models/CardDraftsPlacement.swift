import Foundation

/// Where the cards a Make Cards drafted open once they are ready, in the
/// window it was pressed in (decisions 2026-09-30, "Entry points and the
/// session": the drafts open beside the Reader when ready, never over another
/// chat or the source). Memory's To Check takes a place that covers neither a
/// chat nor a Reader — the source the cards were made from is in one; with
/// no such place the drafts wait in To Check, the
/// Reader's toolbar and the notebook's Studio say how many, and a toast
/// offers them. Pure, so the routing is tested without a window.
enum CardDraftsPlacement: Equatable {
    /// The Memory pane is on screen already: it turns to To Check.
    case memoryOnScreen
    /// The notebook's workspace with Memory placed: in its empty document
    /// slot, in a slot that showed neither the Reader nor a second chat, or
    /// — with its chat hidden — in the chat's place beside the slot.
    case notebook(NotebookWorkspace)
    /// The window's panes with Memory in a pane of its own beside the others,
    /// or in a pane that showed neither a chat nor the Reader.
    case panes(StudioCenterTabGroups)
    /// No place covers nothing the learner works in.
    case none

    /// What a placement may never cover.
    static let protectedTabs: Set<StudioCenterTab> = [.chat, .secondaryChat, .reader]
    static let protectedDocuments: Set<NotebookDocument> = [.reader, .secondChat]

    static func place(
        notebook: NotebookWorkspace?,
        panes: StudioCenterTabGroups,
        isInMemoryFocus: Bool
    ) -> CardDraftsPlacement {
        // A memory review owns its window: the drafts wait.
        guard !isInMemoryFocus else { return .none }
        if let notebook {
            return place(in: notebook)
        }
        return place(in: panes)
    }

    private static func place(in notebook: NotebookWorkspace) -> CardDraftsPlacement {
        if notebook.document == .memory || notebook.leadingDocument == .memory { return .memoryOnScreen }
        if notebook.document.map({ !protectedDocuments.contains($0) }) ?? true,
           let next = notebook.following(.document(.memory)) {
            return .notebook(next)
        }
        // The slot shows the source or a second chat: beside it, in the
        // chat's place, only while the chat is hidden.
        guard !notebook.showsChat,
              notebook.leadingDocument.map({ !protectedDocuments.contains($0) }) ?? true else { return .none }
        var next = notebook
        next.leadingDocument = .memory
        return .notebook(next)
    }

    private static func place(in panes: StudioCenterTabGroups) -> CardDraftsPlacement {
        if panes.groups.contains(where: { $0.activeTab == .memory }) { return .memoryOnScreen }
        guard let parked = panes.groups.firstIndex(where: { $0.tabs.contains(.memory) }) else { return .none }
        var layout = panes
        layout.groups[parked].tabs.removeAll { $0 == .memory }
        if layout.canCreateGroup, !layout.groups[parked].tabs.isEmpty {
            // A pane of its own, right of the Reader's when the Reader shows,
            // else at the right edge.
            let reader = layout.groups.firstIndex { $0.activeTab == .reader }
            let at = reader.map { $0 + 1 } ?? layout.groups.count
            layout.groups.insert(.init(tabs: [.memory], activeTab: .memory), at: at)
            return .panes(layout)
        }
        guard let free = panes.groups.indices.first(where: { index in
            !protectedTabs.contains(panes.groups[index].activeTab)
        }) else { return .none }
        var replaced = panes
        if free != parked {
            replaced.groups[parked].tabs.removeAll { $0 == .memory }
            guard !replaced.groups[parked].tabs.isEmpty else { return .none }
            replaced.groups[free].tabs.insert(.memory, at: 0)
        }
        replaced.groups[free].activeTab = .memory
        return .panes(replaced)
    }
}
