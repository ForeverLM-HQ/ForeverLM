#if os(macOS)
import SwiftUI

// MARK: - Lists in the Space
//
// What the Space draws for a list of goals or of ideas (`SpaceList`,
// docs/docs-design.md, "Lists in the Space"): the list's own page, its menu
// wherever it is listed, Move to List ▸ on a goal's and an idea's row, and
// the Create strip that makes one, as ChatGPT's Space makes a To-do list.

/// A list opened in the Space: what it holds, with the way to add to it —
/// the jot field for ideas; the Add pill over the page (`SpaceListAddMenu`)
/// sets a goal or brings in one already made. Drawn beside the Space sidebar
/// in place of a list of items.
struct SpaceListPage: View {
    @Environment(StudioViewModel.self) private var vm
    let list: SpaceList
    /// The Space's search, over what the list holds.
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if list.isTrashed {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                    Text("This list is in Trash")
                        .zoomedSystemFont(size: 12.5, weight: .medium)
                        .textSelection(.disabled)
                    Button("Restore") { vm.restoreSpaceLists([list.id]) }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .accessibilityIdentifier("space.list.trashBanner")
            }
            switch list.kind {
            case .goals:
                GoalsHomeView(
                    isEmbedded: true,
                    query: query,
                    admits: { [listID = list.id, lists = vm.spaceLists] goal in lists.listID(of: goal.id) == listID }
                )
            case .ideas:
                IdeasHomeView(
                    isEmbedded: true,
                    query: query,
                    admits: { [listID = list.id, lists = vm.spaceLists] idea in lists.listID(of: idea.id) == listID },
                    onJotted: { idea in vm.fileRecords([idea.id], inSpaceList: list.id) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.list.\(list.id)")
    }
}

/// **Add Goals ▾** or **Add Ideas ▾** on a list's page, the place's one dark
/// pill: for goals New Goal… first, filed in the list once set; then the goals
/// or ideas already made that are not in it yet, newest first, each moved
/// into it as it is chosen. A new idea is jotted in the field on the page.
struct SpaceListAddMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let list: SpaceList
    @State private var isSettingGoal = false
    /// How many a menu offers; the rest are found by the Goals tab or Ideas.
    static let offered = 40

    private var candidates: [(id: String, title: String, listName: String?)] {
        switch list.kind {
        case .goals:
            return vm.allGoals
                .filter { !$0.isDone && !$0.isArchived && vm.spaceLists.listID(of: $0.id) != list.id }
                .prefix(Self.offered)
                .map { ($0.id, $0.title, vm.spaceList(ofRecord: $0.id)?.name) }
        case .ideas:
            return vm.ideas
                .filter { $0.isOpen && vm.spaceLists.listID(of: $0.id) != list.id }
                .sorted(by: IdeaRecord.listOrder)
                .prefix(Self.offered)
                .map { ($0.id, $0.title, vm.spaceList(ofRecord: $0.id)?.name) }
        }
    }

    /// New Goal… on a list of goals, then the goals or ideas to put in it,
    /// each named with the list it is in now.
    private func sections(_ candidates: [(id: String, title: String, listName: String?)]) -> [[SpaceMenuItem]] {
        let new: [SpaceMenuItem] = list.kind == .goals
            ? [SpaceMenuItem(id: "studio.goals.set", title: "New Goal\u{2026}", systemImage: "plus") { isSettingGoal = true }]
            : []
        let existing: [SpaceMenuItem] = candidates.isEmpty
            ? [SpaceMenuItem(id: "space.list.add.none", title: "Every \(list.kind.noun) is in this list", systemImage: "checkmark", isEnabled: false) {}]
            : candidates.map { candidate in
                SpaceMenuItem(
                    id: "space.list.add.\(candidate.id)",
                    title: candidate.title,
                    systemImage: list.kind.symbolName,
                    trailing: candidate.listName.map { "in \($0)" }
                ) { vm.moveRecords([candidate.id], toSpaceList: list.id) }
            }
        return [new, existing]
    }

    var body: some View {
        let candidates = candidates
        SpaceDarkPillMenu(title: "Add \(list.kind.pluralNoun.capitalized)", sections: sections(candidates))
        .help(list.kind == .goals ? "Set a goal in this list, or put one you already have in it" : "Put an idea you already have in this list")
        .accessibilityIdentifier("space.list.add")
        .sheet(isPresented: $isSettingGoal) {
            SetGoalSheet { title, deadline, notebookID, artifactID in
                Task {
                    if let goal = await vm.createGoal(title: title, deadline: deadline, notebookID: notebookID, artifactID: artifactID) {
                        vm.fileRecords([goal.id], inSpaceList: list.id)
                    }
                }
            }
        }
    }
}

/// A list's ⋯ and right-click, and the menu on its name over its page: the
/// Space's page menu, for a list. In Trash, Restore; Delete Forever is the
/// list's own, which asks first.
struct SpaceListMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let list: SpaceList
    /// Shows it; nil where it is already showing (its own page).
    var onOpen: (() -> Void)?
    let onRename: () -> Void

    var body: some View {
        if list.isTrashed {
            Button("Restore", systemImage: "arrow.uturn.backward") { vm.restoreSpaceLists([list.id]) }
        } else {
            if let onOpen {
                Button("Open", action: onOpen)
            }
            OtherWindowMenuItem(.spaceList(list.id))
            Divider()
            Button("Rename…", systemImage: "pencil", action: onRename)
            let pinned = vm.isPagePinned(list.id)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                vm.setPagePinned(list.id, pinned: !pinned)
            }
            PageSpaceMenu(itemIDs: [list.id])
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                vm.moveSpaceListsToTrash([list.id])
            }
        }
    }
}

/// **Move to List ▸** on a goal's or an idea's row: each list of its kind,
/// ticked where it is; None, out of every list; then New List, which makes
/// one holding it. A goal or an idea is in one list at a time.
struct SpaceListMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let recordID: String
    let kind: SpaceList.Kind

    var body: some View {
        if vm.activeTeamID == nil {
            let current = vm.spaceLists.listID(of: recordID)
            Menu {
                ForEach(vm.spaceListsAccepting(kind)) { list in
                    Toggle(list.name, isOn: Binding(
                        get: { current == list.id },
                        set: { _ in vm.moveRecords([recordID], toSpaceList: list.id) }
                    ))
                }
                Toggle("None", isOn: Binding(
                    get: { current == nil },
                    set: { _ in vm.moveRecords([recordID], toSpaceList: nil) }
                ))
                Divider()
                Button("New List") {
                    let list = vm.createSpaceList(kind, holding: [recordID])
                    vm.showToast("Moved to \(list.name)")
                }
            } label: {
                Label("Move to List", systemImage: "checklist")
            }
        }
    }
}

/// **Rename List**: the name field over whatever asked, filled with the
/// list's name.
private struct SpaceListRenameAlert: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Binding var list: SpaceList?
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename List",
                isPresented: Binding(
                    get: { list != nil },
                    set: { if !$0 { list = nil } }
                ),
                presenting: list
            ) { list in
                TextField("Name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { vm.renameSpaceList(list.id, to: draft) }
                    .disabled(SpaceLists.cleanedName(draft) == nil)
            }
            .onChange(of: list?.id, initial: true) { _, _ in
                if let list { draft = list.name }
            }
    }
}

extension View {
    /// Asks for a new name for `list` while it is set.
    func spaceListRenameAlert(_ list: Binding<SpaceList?>) -> some View {
        modifier(SpaceListRenameAlert(list: list))
    }
}

/// ChatGPT's **Create pages in Space**: a row of what can be started here —
/// a page, a list of goals, a list of ideas, a canvas — over All and over a
/// space, made in the space on screen and opened. Its × puts it away on this
/// Mac; New ▾ makes the same things.
struct SpaceCreateStrip: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The space on screen, which what is made here is filed in.
    let spaceID: String?
    let onNewPage: () -> Void
    @AppStorage(Self.hiddenKey) private var isHidden = false

    static let hiddenKey = "space.createStripHidden"

    private struct Template: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let tint: Color
        let make: () -> Void
    }

    private var templates: [Template] {
        var templates = [
            Template(id: "page", title: "Page", systemImage: "doc.text", tint: SpaceKindStyle.tint(.page), make: onNewPage),
            Template(id: "goals", title: "Goals", systemImage: SpaceList.Kind.goals.symbolName, tint: SpaceKindStyle.tint(.goalList)) {
                vm.makeAndOpenSpaceList(.goals, inPageSpace: spaceID, in: windowState)
            },
            Template(id: "ideas", title: "Ideas", systemImage: SpaceList.Kind.ideas.symbolName, tint: SpaceKindStyle.tint(.ideaList)) {
                vm.makeAndOpenSpaceList(.ideas, inPageSpace: spaceID, in: windowState)
            },
        ]
        if vm.listsCanvases {
            templates.append(Template(id: "canvas", title: "Canvas", systemImage: KnowledgeMap.symbolName, tint: SpaceKindStyle.tint(.canvas)) {
                vm.makeAndOpenCanvas(inPageSpace: spaceID, in: windowState)
            })
        }
        return templates
    }

    var body: some View {
        if !isHidden {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Create in Space")
                        .zoomedSystemFont(size: 14, weight: .semibold)
                        .textSelection(.disabled)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isHidden = true }
                    } label: {
                        Image(systemName: "xmark")
                            .zoomedSystemFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.10))
                    .help("Hide; New ▾ makes the same things")
                    .accessibilityLabel("Hide Create in Space")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(templates) { template in
                            SpaceCreateCard(title: template.title, systemImage: template.systemImage, tint: template.tint, action: template.make)
                                .accessibilityIdentifier("space.create.\(template.id)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .transition(.opacity)
        }
    }
}

/// One card of the Create strip: the kind's glyph in its colour over its name.
private struct SpaceCreateCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 17, weight: .medium)
                    .foregroundStyle(tint)
                Text(title)
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .foregroundStyle(.primary)
            }
            .frame(width: 168, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.075 : 0.045))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("New \(title)")
    }
}
#endif
