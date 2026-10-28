import SwiftUI
import UniformTypeIdentifiers

/// Thin progress track used in notebook cards and the Notebooks overlay.
struct NotebookProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.20))
                if value > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * min(1, max(0, value)))
                }
            }
        }
        .frame(height: 4)
    }
}

/// Menu item that pins one active notebook to the rail's Pinned section or
/// takes it off (`NotebookPins`). Pinning is the learner's own presentation
/// preference (synced across their Macs), so unlike Archive it never asks
/// whether the library is read-only.
struct NotebookPinToggleButton: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord

    var body: some View {
        if vm.isNotebookPinned(goal.id) {
            Button("Unpin from Sidebar", systemImage: "pin.slash") {
                vm.setNotebookPinned(goal.id, false)
            }
        } else {
            Button("Pin to Sidebar", systemImage: "pin") {
                vm.setNotebookPinned(goal.id, true)
            }
        }
    }
}

extension NotebookTint {
    /// The notebook's tint as a colour that follows the window's appearance.
    static func color(for notebookID: String) -> Color {
        let index = index(for: notebookID)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark[index] : light[index]
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// The one way to pick among notebooks: a small popover, a search field on
/// top and a short list under it, never a menu of every notebook (product
/// owner, 2026-10-28, of the ⋯ menu's "Add a Notebook to Context" list: "don't
/// do these kind of apple long laundry list"). Type to filter; ↑ ↓ move and
/// Return picks; Escape closes. A notebook in `checkedIDs` wears a tick, and
/// a picker that `staysOpenOnPick` lets the learner tick several in a row.
/// Most recently changed first; one grey row, as the sidebar selects.
struct NotebookPickerPopover: View {
    /// A row above the notebooks that picks none of them ("No notebook",
    /// "Remove from Notebook"), shown while the field is empty.
    struct NoneRow {
        let title: String
        var isChecked = false
        let action: () -> Void
    }

    let placeholder: String
    let notebooks: [LearningGoalRecord]
    var checkedIDs: Set<String> = []
    var staysOpenOnPick = false
    var none: NoneRow?
    let pick: (LearningGoalRecord) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var searchFocused: Bool

    static let width: CGFloat = 300
    private static let rowHeight: CGFloat = 28
    private static let visibleRows = 8
    private static let noneID = "notebook.picker.none"

    private var shown: [LearningGoalRecord] {
        let ordered = notebooks.sorted { $0.updatedAt > $1.updatedAt }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { NotebookTitle($0.title).text.localizedStandardContains(needle) }
    }

    /// The ids the arrow keys walk: the none row first, then the notebooks.
    private func walkable(_ rows: [LearningGoalRecord]) -> [String] {
        (showsNone ? [Self.noneID] : []) + rows.map(\.id)
    }

    private var showsNone: Bool {
        none != nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let rows = shown
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit {
                            if highlightedID == Self.noneID {
                                chooseNone()
                            } else if let notebook = rows.first(where: { $0.id == highlightedID }) {
                                choose(notebook)
                            }
                        }
                        .onKeyPress(.upArrow) { move(-1, in: rows, proxy: proxy); return .handled }
                        .onKeyPress(.downArrow) { move(1, in: rows, proxy: proxy); return .handled }
                        .accessibilityIdentifier("notebook.picker.search")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                if rows.isEmpty, !showsNone {
                    Text("No notebooks match")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight * 2)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if showsNone, let none {
                                noneRow(none)
                            }
                            ForEach(rows) { notebook in
                                row(notebook)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(walkable(rows).count), CGFloat(Self.visibleRows)) * Self.rowHeight + 12)
                }
            }
        }
        .frame(width: Self.width)
        .onAppear {
            searchFocused = true
            highlightedID = walkable(shown).first
        }
        .onChange(of: query) { _, _ in highlightedID = walkable(shown).first }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook.picker")
    }

    private func row(_ notebook: LearningGoalRecord) -> some View {
        let title = NotebookTitle(notebook.title)
        return Button { choose(notebook) } label: {
            HStack(spacing: 8) {
                if let icon = title.icon { Text(icon) }
                Text(title.text)
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !notebook.isNotebook {
                    Text("Goal")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if checkedIDs.contains(notebook.id) {
                    Image(systemName: "checkmark")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioSelectionBackground(isSelected: highlightedID == notebook.id, isHovered: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlightedID = notebook.id } }
        .id(notebook.id)
        .accessibilityAddTraits(checkedIDs.contains(notebook.id) ? .isSelected : [])
        .accessibilityIdentifier("notebook.picker.row")
    }

    private func noneRow(_ none: NoneRow) -> some View {
        Button { chooseNone() } label: {
            HStack(spacing: 8) {
                Text(none.title)
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if none.isChecked {
                    Image(systemName: "checkmark")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioSelectionBackground(isSelected: highlightedID == Self.noneID, isHovered: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlightedID = Self.noneID } }
        .id(Self.noneID)
        .accessibilityIdentifier("notebook.picker.none")
    }

    private func chooseNone() {
        none?.action()
        if !staysOpenOnPick { close() }
    }

    private func choose(_ notebook: LearningGoalRecord) {
        pick(notebook)
        if !staysOpenOnPick { close() }
    }

    private func move(_ delta: Int, in rows: [LearningGoalRecord], proxy: ScrollViewProxy) {
        let ids = walkable(rows)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == highlightedID } ?? (delta > 0 ? -1 : ids.count)
        let next = min(max(current + delta, 0), ids.count - 1)
        highlightedID = ids[next]
        proxy.scrollTo(ids[next])
    }
}

/// A form's notebook choice: the chosen title in a field that opens
/// `NotebookPickerPopover`, where a form used a `Picker` listing every
/// notebook. `notebookID` nil reads `noneTitle` ("No notebook").
struct NotebookPickerField: View {
    @Environment(StudioViewModel.self) private var vm
    let label: String
    var noneTitle = "No notebook"
    @Binding var notebookID: String?
    @State private var isChoosing = false

    var body: some View {
        let chosen = notebookID.flatMap { vm.notebook(id: $0) }
        Button { isChoosing = true } label: {
            HStack(spacing: 6) {
                Text(chosen.map { NotebookTitle($0.title).text } ?? noneTitle)
                    .foregroundStyle(chosen == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
            NotebookPickerPopover(
                placeholder: "Search notebooks",
                notebooks: vm.notebooks,
                checkedIDs: notebookID.map { [$0] } ?? [],
                none: .init(title: noneTitle, isChecked: notebookID == nil) { notebookID = nil },
                pick: { notebookID = $0.id },
                close: { isChoosing = false }
            )
            .environment(vm)
        }
        .accessibilityLabel(label)
        .accessibilityValue(chosen?.title ?? noneTitle)
    }
}

/// The menu entry every Notebook surface offers for merging. It stays visible
/// with nothing to merge into, disabled, so the action is discoverable from a
/// library with one Notebook as well as from one with twenty.
struct NotebookMergeMenuButton: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let action: () -> Void

    var body: some View {
        Button("Merge into Notebook…", systemImage: "arrow.triangle.merge", action: action)
            .disabled(vm.isActiveLibraryReadOnly || vm.mergeCandidates(for: goal).isEmpty)
    }
}

/// Folds one Notebook into another. The Notebook the sheet was opened from is
/// the one that goes: the learner picks where everything in it lands and what
/// the merged Notebook is called, and sees what will move before agreeing.
struct NotebookMergeSheet: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let goal: LearningGoalRecord
    @State private var survivorID: String?
    @State private var title = ""
    @State private var isMerging = false
    @State private var isChoosingSurvivor = false

    private var candidates: [LearningGoalRecord] {
        vm.mergeCandidates(for: goal)
    }

    private var survivor: LearningGoalRecord? {
        candidates.first { $0.id == survivorID }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var linkedChatCount: Int {
        vm.reviewSessionLinks.filter { $0.goalID == goal.id }.count
    }

    private var message: String {
        let sourceCount = goal.approvedSourceIDs.count
        var moving: [String] = []
        moving.append(sourceCount == 1 ? "its source" : "its \(sourceCount) sources")
        if linkedChatCount > 0 {
            moving.append(linkedChatCount == 1 ? "its chat" : "its \(linkedChatCount) chats")
        }
        moving.append("its open questions, notes, Goals, tasks, pages, scheduled tasks and files")
        let destination = survivor.map { "\"\($0.title)\"" } ?? "the notebook you choose"
        return "Everything in \"\(goal.title)\" moves to \(destination): \(moving.joined(separator: ", ")). \"\(goal.title)\" is then deleted. A source already in both is kept once."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge \"\(goal.title)\" into another notebook")
                .zoomedSystemFont(size: 16, weight: .semibold)

            VStack(alignment: .leading, spacing: 6) {
                Text("Into")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                Button { isChoosingSurvivor = true } label: {
                    HStack(spacing: 8) {
                        Text(survivor?.title ?? "Choose a notebook")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .zoomedSystemFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isChoosingSurvivor, arrowEdge: .bottom) {
                    NotebookPickerPopover(
                        placeholder: "Search notebooks",
                        notebooks: candidates,
                        checkedIDs: survivorID.map { [$0] } ?? [],
                        pick: { survivorID = $0.id },
                        close: { isChoosingSurvivor = false }
                    )
                    .environment(vm)
                }
                .accessibilityLabel("Into")
                .accessibilityValue(survivor?.title ?? "None chosen")
                .accessibilityIdentifier("notebook.merge.into")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name of the merged notebook")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                TextField(survivor?.title ?? "Name", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(merge)
            }

            Text(message)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge notebooks", action: merge)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(survivorID == nil || isMerging)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if survivorID == nil, let first = candidates.first {
                survivorID = first.id
                title = first.title
            }
        }
        .onChange(of: survivorID) { previous, current in
            // The name follows the chosen survivor until the learner edits it.
            let previousTitle = candidates.first { $0.id == previous }?.title ?? ""
            if trimmedTitle.isEmpty || trimmedTitle == previousTitle {
                title = candidates.first { $0.id == current }?.title ?? ""
            }
        }
    }

    private func merge() {
        guard let survivorID, !isMerging else { return }
        isMerging = true
        let newTitle = trimmedTitle
        Task {
            let merged = await vm.mergeNotebook(
                goal.id,
                into: survivorID,
                title: newTitle.isEmpty ? nil : newTitle
            )
            isMerging = false
            if merged { dismiss() }
        }
    }
}

/// The one place a Notebook deletion is confirmed, so every entry point states
/// the same consequences, including the explicit choice to keep linked chats
/// ungrouped (the default path) or delete them with the Notebook.
struct NotebookDeleteConfirmation: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    @Binding var isPresented: Bool

    private var linkedChatCount: Int {
        let deletedGoalIDs = Set([goal.id] + vm.goals(inNotebook: goal.id).map(\.id))
        return vm.reviewSessionLinks.filter { session in
            session.goalID.map(deletedGoalIDs.contains) == true
        }.count
    }

    private var message: String {
        let childGoalCount = vm.goals(inNotebook: goal.id).count
        var sentences: [String] = []
        if linkedChatCount > 0 {
            sentences.append("\"\(goal.title)\" will be deleted.")
        }
        if childGoalCount > 0 {
            sentences.append(
                childGoalCount == 1
                    ? "Its 1 Goal is deleted too."
                    : "Its \(childGoalCount) Goals are deleted too."
            )
        }
        if linkedChatCount > 0 {
            sentences.append(
                linkedChatCount == 1
                    ? "Keep its chat in Chats, or delete it too."
                    : "Keep its \(linkedChatCount) chats in Chats, or delete them too."
            )
        }
        sentences.append("Files in the notebook\u{2019}s folder move to the Trash.")
        sentences.append("Sources stay in your library.")
        return sentences.joined(separator: " ")
    }

    private var title: String {
        linkedChatCount > 0 ? "Delete its chats too?" : "Delete \"\(goal.title)\"?"
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $isPresented) {
            Button(linkedChatCount > 0 ? "Delete Notebook, Keep Chats" : "Delete Notebook", role: .destructive) {
                Task {
                    await vm.deleteLearningGoal(
                        goal.id,
                        cascadeChildGoals: true,
                        deleteLinkedChats: false
                    )
                }
            }
            if linkedChatCount > 0 {
                Button("Delete Notebook and Chats", role: .destructive) {
                    Task {
                        await vm.deleteLearningGoal(
                            goal.id,
                            cascadeChildGoals: true,
                            deleteLinkedChats: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

extension View {
    func notebookDeleteConfirmation(goal: LearningGoalRecord, isPresented: Binding<Bool>) -> some View {
        modifier(NotebookDeleteConfirmation(goal: goal, isPresented: isPresented))
    }
}

/// The three states a Notebook's approved sources move through, plus the pool's
/// pre-approval bucket. One tint per state, used by the Context pool's section
/// headings to group a long source list. Deliberately not aggregated into a
/// notebook-level progress figure: these are quiz-retention states, so summing
/// them measures source consumption, which is not what a Notebook is for.
enum NotebookPoolState {
    case suggested
    case toRead
    case reading
    case understood

    var tint: Color {
        switch self {
        case .suggested: return .accentColor
        case .toRead: return Color.secondary.opacity(0.45)
        case .reading: return .orange
        case .understood: return .green
        }
    }
}
