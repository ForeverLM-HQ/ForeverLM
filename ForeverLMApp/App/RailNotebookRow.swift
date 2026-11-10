// The rail row for a notebook.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One notebook, listed under the Notebooks section header. Two states, deliberately
/// distinct: `isSelected` is "the reader column is showing this notebook" and gets
/// the usual row highlight, while `isActive` is the weaker "this notebook is open"
/// — a bolder title, no background. The rail keeps showing the
/// active notebook after the column moves on to a source, so a new chat still gets
/// filed beneath it; without the split, that would read as a second selected row
/// competing with the open chat. On hover the row reveals a plus that starts a
/// chat in this notebook. Notebook management actions live on the notebook page.
struct RailNotebookRow: View {
    @Environment(StudioViewModel.self) private var vm
    private let dragVisibility = StudioDragVisibility.shared
    let goal: LearningGoalRecord
    /// Its emoji is the row's icon, as in the Space's list.
    let notebookTitle: NotebookTitle
    let isActive: Bool
    let isSelected: Bool
    let isExpanded: Bool
    /// Its chats that read as unread on this Mac (`ChatReadMarks`): folded,
    /// the row carries Codex's dot for them, and its menu Mark All as Read.
    let unreadChatIDs: [String]
    let open: () -> Void
    let toggleExpanded: () -> Void
    let newChat: () -> Void

    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var isTargeted = false
    @State private var showDeleteConfirm = false
    /// The notebook's Share popover, from Share… on the row's menu.
    @State private var isShowingShare = false

    /// True while a source drag is in flight that this notebook doesn't already
    /// hold. Drives both the drop highlight and whether a drop is accepted, so a
    /// notebook you can't add to never lights up.
    private var canAcceptCurrentDrag: Bool {
        notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: dragVisibility)
    }

    private var supportedDropTypes: [UTType] {
        mcpSourceContextDropTypes + [.reviewSession, .studioNotebook]
    }

    private var canAcceptNotebookDrag: Bool {
        guard let draggedNotebookID = dragVisibility.draggedNotebookID else { return false }
        return draggedNotebookID != goal.id
    }

    private var title: String {
        notebookTitle.text.isEmpty ? "Untitled notebook" : notebookTitle.text
    }

    private var newChatGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    private var foldGlyph: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 8) {
                    NotebookIconView(notebookID: goal.id, size: 16, cornerRadius: 4) {
                        Text(notebookTitle.displayIcon)
                            .font(.system(size: 12))
                    }
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Opens the notebook in this window")

            // The + and the chevron are built only while they show, a hidden
            // glyph holding each one's place. A button at opacity 0 is still
            // a live control, and while an assistive app reads the screen
            // SwiftUI walks every control in the window for each one an
            // update builds (2026-10-03). The row's actions below reach both
            // with no pointer.
            if hovering {
                Button(action: newChat) {
                    newChatGlyph
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help("New chat in this notebook")
            } else if !isExpanded, !unreadChatIDs.isEmpty {
                // A folded notebook holding an unread chat shows Codex's dot,
                // as a Codex project does; unfolded, the chat's own row has it.
                RailUnreadDot()
                    .frame(width: 20, height: 20)
            } else {
                newChatGlyph
                    .hidden()
            }

            // The chats' fold, apart from opening: the row's click opens the
            // notebook, this shows or hides its chats beneath it.
            if hovering || isExpanded {
                Button(action: toggleExpanded) {
                    foldGlyph
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help(isExpanded ? "Hide chats" : "Show chats")
                .accessibilityLabel(isExpanded ? "Hide chats in \(title)" : "Show chats in \(title)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                foldGlyph
                    .hidden()
            }

        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, StudioDesign.Spacing.xSmall)
        .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .overlay {
            // Mounted only while a drag could land here: at rest this overlay
            // put an animatable stroke + fill node on every rail row, which
            // multiplied into visible AttributeGraph cost on each render pass.
            if canAcceptCurrentDrag || canAcceptNotebookDrag || isTargeted {
                StudioDropZoneOverlay(
                    isActive: isTargeted && (canAcceptCurrentDrag || canAcceptNotebookDrag),
                    isVisible: canAcceptCurrentDrag || canAcceptNotebookDrag,
                    cornerRadius: 7,
                    inset: 0
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(unreadChatIDs.isEmpty ? "" : "Unread chats")
        // The + and the chevron, for VoiceOver: it has no pointer to bring
        // them out, and neither is on the right-click menu.
        .accessibilityAction(named: Text("New Chat in Notebook"), newChat)
        .accessibilityAction(named: Text(isExpanded ? "Hide Chats" : "Show Chats"), toggleExpanded)
        // Pin keeps a notebook in the rail whatever Recent does; Unpin and
        // Archive take it off. Without these the only routes were the Space's
        // row and the open notebook's own page.
        .contextMenu {
            OpenStudioDestinationInOtherWindowMenu(
                destination: .notebook(goal.id),
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
            Divider()
            // Codex's Mark all as read on a project.
            if !unreadChatIDs.isEmpty {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    for id in unreadChatIDs { ChatReadMarks.shared.markRead(id) }
                }
            }
            // Pinning is this learner's own rail, not the team's Notebook, so
            // a read-only library does not disable it.
            NotebookPinToggleButton(goal: goal)
            NotebookCoverMenuItems(notebookID: goal.id)
                .disabled(vm.isActiveLibraryReadOnly)
            Button("Archive Notebook", systemImage: "archivebox") {
                Task { await vm.setGoalStatus(goalID: goal.id, status: .archived) }
            }
            .disabled(vm.isActiveLibraryReadOnly)
            Divider()
            Button("Share…", systemImage: "person.badge.plus") { isShowingShare = true }
            ShareWithTeamMenu { teamID in
                Task { await vm.shareNotebook(goal.id, withTeam: teamID) }
            }
            Divider()
            Button("Delete Notebook…", systemImage: "trash", role: .destructive) {
                showDeleteConfirm = true
            }
            .disabled(vm.isActiveLibraryReadOnly)
        }
        .notebookDeleteConfirmation(goal: goal, isPresented: $showDeleteConfirm)
        .popover(isPresented: $isShowingShare, arrowEdge: .trailing) {
            NotebookSharePopover(goal: goal, close: { isShowingShare = false })
                .environment(vm)
        }
        .onHover { hovering = $0 }
        .onDrag {
            dragVisibility.begin(notebookID: goal.id)
            return notebookDragProvider(for: StudioNotebookTransfer(notebookID: goal.id), title: title)
        } preview: {
            Label {
                Text(title)
            } icon: {
                NotebookIconView(notebookID: goal.id, size: 16, cornerRadius: 4) {
                    Text(notebookTitle.displayIcon)
                }
            }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        // Drop a source straight onto the row to add it to that notebook, or
        // drop a chat to move the conversation into the notebook. Notebook payloads
        // use the same destination without interfering with either existing type.
        .onDrop(of: supportedDropTypes, isTargeted: Binding(
            get: { isTargeted },
            set: { isTargeted = $0 && (canAcceptCurrentDrag || canAcceptNotebookDrag) }
        )) { providers in
            // Accept on the payload alone — `canAcceptCurrentDrag` races the mouse-up
            // monitors that clear drag state as the drop fires (see the Notebook pill).
            StudioDragVisibility.shared.endSoon()
            if reorderDroppedNotebook(providers) {
                return true
            }
            if moveDroppedChat(providers) {
                return true
            }
            return NotebookSourceDropHandler.handle(providers: providers, vm: vm, notebookID: goal.id)
        }
    }

    private func reorderDroppedNotebook(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.studioNotebook.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.studioNotebook.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(StudioNotebookTransfer.self, from: data) else { return }
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.16)) {
                    vm.reorderNotebook(from: transfer.notebookID, to: goal.id)
                }
            }
        }
        return true
    }

    private func moveDroppedChat(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.reviewSession.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.reviewSession.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(ReviewSessionTransfer.self, from: data) else { return }
            Task { @MainActor in
                await vm.moveReviewSession(transfer.sessionID, toNotebook: goal.id)
            }
        }
        return true
    }
}

/// A notebook's drag: the rail's rows, and the Canvas Library's notebooks.
func notebookDragProvider(for transfer: StudioNotebookTransfer, title: String) -> NSItemProvider {
    let provider = NSItemProvider()
    if let data = try? JSONEncoder().encode(transfer) {
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioNotebook.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = title
    return provider
}
