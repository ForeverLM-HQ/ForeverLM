// The rail row for a chat, the unread dot and the chat activity reporter.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A previous-chat row: opens the chat on click and reveals an ellipsis menu on
/// hover (Claude-style) with rename, Move to Notebook, and delete actions. The
/// same actions are mirrored in a right-click context menu. Dragging one chat
/// onto another in the same section rearranges the list.
struct RailChatRow: View {
    private let dragVisibility = StudioDragVisibility.shared
    let sessionID: String
    let title: String
    /// The row's leading mark: a team's snapshot's pair of figures. Nil for
    /// every other chat.
    let systemImage: String?
    let isSelected: Bool
    let isRunning: Bool
    let indent: CGFloat
    let notebooks: [LearningGoalRecord]
    /// The open Goals a chat can be filed under, listed in their own section
    /// of the Move to Notebook submenu. A chat on a Goal is listed on the
    /// Goal's row and in its editor, and beneath the Goal's Notebook in the
    /// rail when it draws on one.
    let goals: [LearningGoalRecord]
    /// Every chat rendered in this row's own section, this one included. A drop
    /// is a reorder within one list, so a chat from another section is refused
    /// rather than silently refiled.
    let siblingIDs: [String]
    /// The notebook section this row is rendered under, if any. Used to mark the
    /// current location in the Move to Notebook submenu.
    let displayedNotebookID: String?
    /// Whether the session is explicitly linked to a notebook (`goal_id` set), as
    /// opposed to appearing under one through source overlap. Only explicit
    /// links can be removed.
    let hasExplicitNotebook: Bool
    let open: () -> Void
    let openBeside: () -> Void
    let moveToNotebook: (String?) -> Void
    /// Called with the dragged chat's id once a sibling has been dropped here.
    let reorder: (String) -> Void
    /// Whether the chat is in Pinned (`ChatPins`).
    let isPinned: Bool
    /// Pin Chat / Unpin Chat; nil where a chat never pins (a day's review).
    let togglePinned: (() -> Void)?
    /// Whether the chat reads as unread on this Mac (`ChatReadMarks`): the
    /// row's leading column shows Codex's dot.
    let isUnread: Bool
    let toggleUnread: () -> Void
    let rename: () -> Void
    /// Whether the chat is hidden from the sidebar — the row is then
    /// drawn under the Hidden fold and its menu offers Show instead of Hide.
    let isHidden: Bool
    let toggleHidden: () -> Void
    /// Copies the transcript into the chosen team; nil where sharing is not
    /// offered (a team's own snapshot, a memory review).
    let shareWithTeam: ((String) -> Void)?
    /// New Notebook from This Chat…; nil where it is not offered (a team's
    /// snapshot, a memory review, a read-only library).
    let newNotebookFromChat: (() -> Void)?
    let delete: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var isTargeted = false
    /// Once revealed, keep the Menu alive for the row's lifetime so moving the
    /// pointer from its label into the open menu cannot tear down the presenter.
    @State private var hasRevealedActionsMenu = false
    @State private var isPickingNotebook = false

    /// True while a chat from this row's own section is in flight. Drives both
    /// the drop outline and whether the row lights up, so a chat that cannot be
    /// rearranged here never offers a target.
    private var canAcceptCurrentDrag: Bool {
        guard let draggedSessionID = dragVisibility.draggedSessionID,
              draggedSessionID != sessionID else { return false }
        return siblingIDs.contains(draggedSessionID)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 8) {
                    // Keep the leading column even when there is no icon, so
                    // a team's snapshot and the learner's chats keep one left
                    // edge. One colour, selected or not: the row's fill says
                    // which is selected.
                    Group {
                        // Codex's unread dot, in the leading column; a chat
                        // still running shows its spinner instead.
                        if isUnread, !isRunning {
                            RailUnreadDot()
                        } else if let systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        }
                    }
                    .frame(width: 16)
                    .accessibilityHidden(true)
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Opacity does not make a view lazy: the previous hidden Menu still
            // built its full nested notebook list for every chat row. Preserve the
            // row geometry with a cheap placeholder and create the menu only while
            // the pointer can interact with it.
            if hasRevealedActionsMenu {
                actionsMenu
                    .opacity(hovering ? 1 : 0)
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 6)
        .padding(.vertical, StudioDesign.Spacing.xSmall)
        .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .overlay {
            // Same rest-cost rule as RailNotebookRow: no drag in flight that
            // this row could accept means no overlay nodes at all.
            if canAcceptCurrentDrag || isTargeted {
                StudioDropZoneOverlay(
                    isActive: isTargeted && canAcceptCurrentDrag,
                    isVisible: canAcceptCurrentDrag,
                    cornerRadius: 7,
                    inset: 0
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isRunning ? "Running" : isUnread ? "Unread" : "")
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                hasRevealedActionsMenu = true
            }
        }
        .onDrop(of: [.reviewSession], isTargeted: Binding(
            get: { isTargeted },
            set: { isTargeted = $0 && canAcceptCurrentDrag }
        )) { providers in
            handleChatDrop(providers)
        }
        .contextMenu { menuItems }
        .popover(isPresented: $isPickingNotebook, arrowEdge: .trailing) {
            NotebookPickerPopover(
                placeholder: "Search notebooks",
                notebooks: notebooks + goals,
                checkedIDs: displayedNotebookID.map { [$0] } ?? [],
                none: hasExplicitNotebook
                    ? .init(
                        title: goals.contains { $0.id == displayedNotebookID } ? "Remove from Goal" : "Remove from Notebook"
                    ) { moveToNotebook(nil) }
                    : nil,
                pick: { picked in
                    if picked.id != displayedNotebookID { moveToNotebook(picked.id) }
                },
                close: { isPickingNotebook = false }
            )
            .environment(vm)
        }
    }

    /// The section guard runs against the payload rather than `canAcceptCurrentDrag`,
    /// which races the mouse-up monitors that clear drag state as the drop fires
    /// (see the Notebook row). The dropped id is authoritative; the live drag state
    /// may already be gone.
    private func handleChatDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.reviewSession.identifier)
        }) else { return false }
        StudioDragVisibility.shared.endSoon()
        let siblingIDs = siblingIDs
        let ownID = sessionID
        let reorder = reorder
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.reviewSession.identifier
        ) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(ReviewSessionTransfer.self, from: data),
                  transfer.sessionID != ownID,
                  siblingIDs.contains(transfer.sessionID) else { return }
            Task { @MainActor in
                reorder(transfer.sessionID)
            }
        }
        return true
    }

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // A `Menu` is not a `Button`, so `.hoverWash` cannot style it — this is
        // the non-button wash, sized to the same 20x20 square the row's other
        // trailing controls light up.
        .hoverHighlight(cornerRadius: 6, inset: 0, opacity: 0.10)
        .opacity(hovering ? 1 : 0)
        .help("More actions")
    }

    /// The row's menu, in Codex's order (product owner, 2026-10-13: "at first it
    /// should be a copy of the codex ... functionality"): Pin, Rename, Mark as
    /// Unread and Hide — ForeverLM's put-away in place of Codex's Archive —
    /// then where the chat is filed, then where it opens and its address,
    /// then Delete…, which asks first. ForeverLM's own items (Open Beside,
    /// Add to Canvas, New Notebook from This Chat, Share Transcript with Team)
    /// sit in the sections they belong to.
    @ViewBuilder
    private var menuItems: some View {
        if let togglePinned {
            Button(action: togglePinned) {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
        }
        Button(action: rename) {
            Label("Rename…", systemImage: "pencil")
        }
        Button(action: toggleUnread) {
            Label(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "checkmark.circle" : "circle")
        }
        // Hide is the learner's view, where Delete is the record's fate (product owner,
        // 2026-09-12: "please allow me to hide chats as well"). The chat, its
        // transcript and its Notebook link stay; only the row leaves, for the
        // Hidden fold under Chats, where Show on this same menu brings it back.
        Button(action: toggleHidden) {
            Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
        }
        .help(isHidden
            ? "List this chat in the sidebar again"
            : "Take this chat out of the sidebar on every Mac signed into your account; it stays under Hidden, beneath Chats")
        if !notebooks.isEmpty || !goals.isEmpty || newNotebookFromChat != nil || shareWithTeam != nil {
            Divider()
        }
        if !notebooks.isEmpty || !goals.isEmpty {
            // A popover under the row with a search field, not a menu of every
            // notebook and Goal.
            Button {
                isPickingNotebook = true
            } label: {
                Label("Move to Notebook…", systemImage: "folder")
            }
        }
        // An exploring chat becomes a notebook of its own (product owner,
        // 2026-10-03), as the chat's notebook picker and ⋯ offer it too.
        if let newNotebookFromChat {
            Button(action: newNotebookFromChat) {
                Label("New Notebook from This Chat", systemImage: "rectangle.stack.badge.plus")
            }
        }
        if let shareWithTeam {
            // A transcript carries no source, so it asks nothing first.
            ShareWithTeamMenu(title: "Share Transcript with Team", asksSharingRights: false, share: shareWithTeam)
        }
        Divider()
        Button(action: openBeside) {
            Label("Open Beside", systemImage: "rectangle.split.2x1")
        }
        OpenStudioDestinationInOtherWindowMenu(
            destination: .chat(sessionID),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        // The chat's address, `foreverlm://chat/<id>`: it opens the chat in the
        // app, a doc renders it as a link, and every plugin tool that takes a
        // session_id takes it as given — so a chat still running here can be
        // pasted to Codex or Claude, which read its turns so far over MCP.
        Button(action: copyLink) {
            Label("Copy Link", systemImage: "link")
        }
        .help("Copy this chat's address; paste it to a person or to an assistant using the ForeverLM plugin")
        Button {
            Task { await vm.copyChatConversation(sessionID) }
        } label: {
            Label("Copy Conversation", systemImage: "doc.on.doc")
        }
        .help("Copy the whole chat as text")
        KnowledgeMapAddToCanvasMenu(refs: [KnowledgeMapOutside.chatRef(sessionID)])
        Divider()
        Button(role: .destructive, action: delete) {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            StudioEntityLink.chat(sessionID).markdownDestination,
            forType: .string
        )
        vm.showToast("Link copied")
    }

    private func notebookTitle(_ notebook: LearningGoalRecord) -> String {
        notebook.title.isEmpty ? "Untitled notebook" : notebook.title
    }
}

/// Codex's unread dot: on a chat whose reply finished while no window showed
/// it, and on a folded notebook holding one (`ChatReadMarks`).
struct RailUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// Tells `ChatReadMarks` what this window's chats are doing: the ones on
/// screen, which a window showing them reads, and the ones running, which the
/// bell lists and whose reply leaves them unread when it finishes with no
/// window showing them. Its
/// own view, mounted once per window by the icon strip, so a turn's flags
/// flipping redraw this and not the strip.
struct ChatActivityReporter: View {
    let sessionStore: StudioAssistantSessionStore
    let comparisonChats: StudioComparisonChatStores

    @Environment(StudioWindowState.self) private var windowState

    private var shown: Set<String> {
        StudioNavigationRail.highlightedSessionIDs(
            primary: sessionStore.activeSessionID,
            comparison: nil,
            in: windowState
        ).union(comparisonChats.shownSessionIDs(in: windowState))
    }

    private var running: Set<String> {
        sessionStore.runningSessionIDs.union(comparisonChats.runningSessionIDs)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: shown, initial: true) { _, ids in
                ChatReadMarks.shared.showing(ids, inWindow: windowState.id.uuidString)
            }
            .onChange(of: running, initial: true) { before, now in
                for sessionID in before.subtracting(now) {
                    ChatReadMarks.shared.replyFinished(sessionID)
                }
                ChatReadMarks.shared.running(now, inWindow: windowState.id.uuidString)
            }
            .onDisappear {
                ChatReadMarks.shared.closingWindow(windowState.id.uuidString)
            }
    }
}
