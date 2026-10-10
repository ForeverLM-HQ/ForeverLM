#if os(macOS)
import SwiftUI

// MARK: - Notebooks in the Space
//
// What the Space draws for a notebook, now that it is the home (product owner,
// 2026-10-09: "make sure the home page is also gone; it doesn't add anything
// i feel"): its row and card under All, its menu, a source dropped on it,
// and the headings of All's Group by Collection. The Notebooks home that
// listed them first is gone; docs/docs-design.md, "The Space", says where
// each of its jobs went.

/// The glyph a notebook is drawn by where it has no cover or emoji of its
/// own: the grid of notebooks the app has always used for the word.
enum NotebookGlyph {
    static let systemImage = "square.grid.2x2"
}

/// A question a notebook's menu asks, answered by the dialog on the row or
/// card that asked (`SpaceNotebookDialogs`): its Share popover, the merge
/// sheet and the delete confirmation. One value for the whole list, so only
/// one is ever open.
enum SpaceNotebookDialog: Equatable {
    case share(String)
    case merge(String)
    case delete(String)
}

/// A notebook's ⋯ and right-click in the Space, as the Notebooks home's card
/// carried them: Open and Open in Other Window, then Share…, Add to
/// Collection ▸, Pin, Draw Cover With ▸ and Archive, then Merge and Delete.
/// In Trash, where an archived notebook is listed, the same menu leads with
/// Restore Notebook and offers no Share, Collection, Pin or Archive.
struct SpaceNotebookMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let onOpen: () -> Void
    /// New Collection… under Add to Collection ▸: asks for a name, with
    /// this notebook in it.
    let onNewCollection: () -> Void
    @Binding var dialog: SpaceNotebookDialog?

    var body: some View {
        // A team's notebook the owner shared read-only is read here too: the
        // items stay so the menu keeps its shape, and nothing in it changes
        // the team (the notebook's own ⋯ does the same).
        let isReadOnly = vm.isNotebookReadOnly(goal)
        Button("Open", action: onOpen)
        OtherWindowMenuItem(.notebook(goal.id))
        Divider()
        if goal.isArchived {
            Button("Restore Notebook", systemImage: "arrow.uturn.backward") {
                Task { await vm.setGoalStatus(goalID: goal.id, status: .active) }
            }
            .disabled(isReadOnly)
        } else {
            Button("Share…", systemImage: "person.badge.plus") { dialog = .share(goal.id) }
            NotebookCollectionMenu(notebookID: goal.id, onNewCollection: onNewCollection)
            NotebookPinToggleButton(goal: goal)
            NotebookCoverMenuItems(notebookID: goal.id)
            Button("Archive Notebook", systemImage: "archivebox") {
                Task { await vm.setGoalStatus(goalID: goal.id, status: .archived) }
            }
            .disabled(isReadOnly)
        }
        Divider()
        NotebookMergeMenuButton(goal: goal) { dialog = .merge(goal.id) }
        Button("Delete Notebook…", systemImage: "trash", role: .destructive) { dialog = .delete(goal.id) }
            .disabled(isReadOnly)
    }
}

/// The dialogs a notebook's menu opens, attached to the row or card that
/// holds the notebook, so the Share popover points at it: the delete
/// confirmation every notebook surface shares, the merge sheet and the
/// Share popover. Nothing for an item that is no notebook.
struct SpaceNotebookDialogs: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord?
    @Binding var dialog: SpaceNotebookDialog?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let goal {
            content
                .notebookDeleteConfirmation(goal: goal, isPresented: flag(.delete(goal.id)))
                .sheet(isPresented: flag(.merge(goal.id))) {
                    NotebookMergeSheet(goal: goal)
                }
                .popover(isPresented: flag(.share(goal.id)), arrowEdge: .bottom) {
                    NotebookSharePopover(goal: goal, close: { dialog = nil })
                        .environment(vm)
                }
        } else {
            content
        }
    }

    /// Whether `value` is the dialog asked for; closing it clears the ask.
    private func flag(_ value: SpaceNotebookDialog) -> Binding<Bool> {
        Binding(
            get: { dialog == value },
            set: { if !$0, dialog == value { dialog = nil } }
        )
    }
}

/// A source dragged onto a notebook's row or card joins that notebook, as it
/// did on the Notebooks home's cards: sources and a course's lectures from
/// the Sources list, the dashed outline lit while a drag that can be taken is
/// under way. An archived notebook takes nothing, and neither does anything
/// that is no notebook.
struct SpaceNotebookDropTarget: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    private let dragVisibility = StudioDragVisibility.shared
    let goal: LearningGoalRecord?
    let cornerRadius: CGFloat
    @State private var isTargeted = false

    private var canAcceptCurrentDrag: Bool {
        guard let goal, !goal.isArchived else { return false }
        return notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: dragVisibility)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let goal, !goal.isArchived {
            content
                .overlay {
                    if canAcceptCurrentDrag || isTargeted {
                        StudioDropZoneOverlay(
                            isActive: isTargeted && canAcceptCurrentDrag,
                            isVisible: canAcceptCurrentDrag,
                            cornerRadius: cornerRadius,
                            inset: 0
                        )
                    }
                }
                .onDrop(of: mcpSourceContextDropTypes, isTargeted: Binding(
                    get: { isTargeted },
                    set: { isTargeted = $0 && canAcceptCurrentDrag }
                )) { providers in
                    // On the payload alone: the drag state the outline reads is
                    // cleared as the drop fires, so gating on it would drop
                    // payloads at random.
                    StudioDragVisibility.shared.endSoon()
                    return NotebookSourceDropHandler.handle(providers: providers, vm: vm, notebookID: goal.id)
                }
        } else {
            content
        }
    }
}

extension View {
    /// The dialogs of `goal`'s menu, while `dialog` asks for one.
    func spaceNotebookDialogs(goal: LearningGoalRecord?, dialog: Binding<SpaceNotebookDialog?>) -> some View {
        modifier(SpaceNotebookDialogs(goal: goal, dialog: dialog))
    }

    /// A source dropped here joins `goal`; nothing when it is nil or archived.
    func spaceNotebookDropTarget(goal: LearningGoalRecord?, cornerRadius: CGFloat) -> some View {
        modifier(SpaceNotebookDropTarget(goal: goal, cornerRadius: cornerRadius))
    }
}

// MARK: - Group by Collection

/// One run of All when it is grouped by collection: a collection's heading
/// and the notebooks in it, or — with no collection — everything else. A
/// notebook in two collections is in both runs.
struct SpaceCollectionSection: Identifiable {
    /// nil for the run of everything no collection holds.
    let collection: NotebookCollection?
    let items: [SpaceItem]

    var id: String { collection?.id ?? "none" }
}

extension SpaceCatalog {
    /// `items` under each collection's heading, in `ordered`'s order, then
    /// everything else — the other kinds, and the notebooks in no collection
    /// — in one last run. A collection holding none of the items still has
    /// its heading while `keepsEmpty`, so a learner who has not filed
    /// anything in it yet can rename or delete it; with a search, a scope or
    /// a notebook filter narrowing the list it does not.
    static func groupedByCollection(
        _ items: [SpaceItem],
        ordered: [NotebookCollection],
        collections: NotebookCollections,
        keepsEmpty: Bool
    ) -> [SpaceCollectionSection] {
        var sections: [SpaceCollectionSection] = []
        var grouped = Set<String>()
        for collection in ordered {
            let members = items.filter { $0.kind == .notebook && collections.contains($0.id, in: collection.id) }
            guard !members.isEmpty || keepsEmpty else { continue }
            sections.append(SpaceCollectionSection(collection: collection, items: members))
            grouped.formUnion(members.map(\.id))
        }
        let rest = items.filter { !grouped.contains($0.id) }
        if !rest.isEmpty {
            sections.append(SpaceCollectionSection(collection: nil, items: rest))
        }
        return sections
    }

    /// Trash's order: what the Space put in the Trash — pages, sites, canvases
    /// and lists — first, then the archived notebooks, each run in the order
    /// the list was sorted in.
    static func trashOrder(_ items: [SpaceItem]) -> [SpaceItem] {
        items.filter { $0.kind != .notebook } + items.filter { $0.kind == .notebook }
    }
}

/// A collection's heading over its notebooks in All: its emoji, its name and
/// how many it holds. The right-click, and the ⋯ under the pointer, rename
/// or delete it; the notebooks stay where they are. "Everything else", the
/// run no collection holds, has neither.
struct SpaceCollectionHeading: View {
    let title: String
    let icon: String?
    let count: Int
    /// Rename and delete, for a collection; nil for the last run.
    var actions: (rename: () -> Void, delete: () -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Text(icon)
                    .zoomedSystemFont(size: 13)
                    .accessibilityHidden(true)
            }
            Text(title)
                .zoomedSystemFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(count)")
                .zoomedSystemFont(size: 12)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let actions {
                SwiftUI.Menu {
                    Button("Rename Collection…", systemImage: "pencil", action: actions.rename)
                    Button("Delete Collection…", systemImage: "trash", role: .destructive, action: actions.delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .fixedSize()
                .opacity(isHovering ? 1 : 0)
                .help("Collection actions")
                .accessibilityLabel("Actions for \(title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let actions {
                Button("Rename Collection…", systemImage: "pencil", action: actions.rename)
                Button("Delete Collection…", systemImage: "trash", role: .destructive, action: actions.delete)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityIdentifier("space.collection.heading")
    }
}
#endif
