import SwiftUI

// MARK: - Board

/// A Notebook's task board: To do, In progress, the learner's own lists and
/// Done as columns of cards, each card a task row. A card is dragged to
/// another column, or to another place in its column; the circle on it still
/// moves it one column on. A card is added at the foot of any column but
/// Done, and New list at the end of the row adds a list. Past three columns
/// the board scrolls sideways. In a team Notebook the tasks can be handed to a
/// member; a read-only team shows the board with every editing control
/// disabled.
struct NotebookTasksBoardView: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    /// Which cards are drawn: all of them, or the day's plan.
    var lens: NotebookTaskBoard.Lens = .all
    /// The head's search, over the cards' titles and notes.
    var query = ""
    /// In a team Notebook, only the signed-in member's cards.
    var mineOnly = false
    /// Bumped to put the cursor in To do's add field (the head's New Card).
    var addFocusRequest = 0
    /// The space left and right of the columns, so the head's margin and the
    /// columns' line up while the columns still scroll to the pane's edge.
    var horizontalPadding: CGFloat = 0

    private static let minimumColumnWidth: CGFloat = 260
    private static let columnGap: CGFloat = 14
    private static let newListWidth: CGFloat = 180

    private var isReadOnly: Bool { vm.isActiveLibraryReadOnly }
    private var isTeamNotebook: Bool { goal.teamID != nil }

    private var members: [TeamMemberRecord] {
        guard let teamID = goal.teamID else { return [] }
        return vm.members(of: teamID).filter { $0.acceptanceStatus != "removed" }
    }

    private var currentMember: TeamMemberRecord? {
        goal.teamID.flatMap { vm.currentMember(of: $0) }
    }

    private var lists: [NotebookTaskList] { vm.taskLists(for: goal.id) }

    private var sections: [NotebookTaskBoard.Section] {
        let shown = NotebookTaskBoard.filtered(
            vm.tasks(for: goal.id),
            mineOnly: mineOnly && isTeamNotebook,
            currentUserRecordName: currentMember?.userRecordName
        )
        return NotebookTaskBoard.sections(
            NotebookTaskBoard.matching(NotebookTaskBoard.lensed(shown, lens, now: Date()), query: query),
            lists: lists
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Three columns and New list fill the width; a fourth column
            // scrolls the row sideways.
            let newListRoom = isReadOnly ? 0 : Self.newListWidth + Self.columnGap
            let gaps = Self.columnGap * 2
            let columnWidth = max(Self.minimumColumnWidth, (proxy.size.width - horizontalPadding * 2 - gaps - newListRoom) / 3)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnGap) {
                    ForEach(sections, id: \.column) { section in
                        NotebookTaskColumn(
                            section: section,
                            goal: goal,
                            lists: lists,
                            members: members,
                            isTeamNotebook: isTeamNotebook,
                            isReadOnly: isReadOnly,
                            lens: lens,
                            addFocusRequest: addFocusRequest,
                            add: { title in addTask(title, in: section.column) }
                        )
                        .frame(width: columnWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    if !isReadOnly {
                        NotebookTaskNewListField(notebookID: goal.id)
                            .frame(width: Self.newListWidth)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
        .task(id: goal.id) {
            await vm.loadNotebookTasks(notebookID: goal.id)
        }
    }

    private func addTask(_ title: String, in column: NotebookTaskBoard.Column) {
        guard !isReadOnly else { return }
        let listIDs = Set(lists.map(\.id))
        let listID: String? = if case .list(let id) = column { id } else { nil }
        var task = NotebookTaskRecord(
            notebookID: goal.id,
            teamID: goal.teamID,
            title: title,
            status: listID == nil ? (column == .status(.doing) ? .doing : .todo) : .todo,
            sortOrder: NotebookTaskBoard.nextSortOrder(
                after: vm.tasks(for: goal.id).filter { NotebookTaskBoard.column(of: $0, listIDs: listIDs) == column }
            ),
            listID: listID
        )
        // A card typed while the board shows only mine is mine, and one typed
        // in Today is due today; otherwise it would vanish from the board
        // the moment it was saved.
        if mineOnly, isTeamNotebook, let me = currentMember {
            task.assigneeRecordName = me.userRecordName
            task.assigneeDisplayName = me.displayName
        }
        if lens == .today, task.status == .todo {
            task.dueAt = NotebookTaskBoard.dueDate(for: .today, now: Date())
        }
        Task { await vm.saveNotebookTask(task) }
    }
}

/// One column of the board: its name and count over its cards, the field that
/// adds one, and the drop target a dragged card lands in.
private struct NotebookTaskColumn: View {
    @Environment(StudioViewModel.self) private var vm
    let section: NotebookTaskBoard.Section
    let goal: LearningGoalRecord
    let lists: [NotebookTaskList]
    let members: [TeamMemberRecord]
    let isTeamNotebook: Bool
    let isReadOnly: Bool
    let lens: NotebookTaskBoard.Lens
    let addFocusRequest: Int
    let add: (String) -> Void

    @State private var newTitle = ""
    @State private var frames: [String: CGRect] = [:]
    @State private var dropTarget: SpaceBoardDropTarget?
    @State private var renaming = false
    @State private var listTitle = ""
    @State private var confirmsDelete = false
    @FocusState private var addFocused: Bool
    @FocusState private var renameFocused: Bool

    private static let coordinateSpaceName = "boardColumn"

    private var status: NotebookTaskStatus { section.status }
    private var canAdd: Bool { section.column != .status(.done) && !isReadOnly }
    private var listIndex: Int? { section.list.flatMap { list in lists.firstIndex { $0.id == list.id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.leading, 4)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.tasks) { task in
                        card(task)
                    }
                    if dropTarget != nil, dropTarget?.beforeID == nil, !section.tasks.isEmpty {
                        SpaceBoardInsertionBar()
                    }
                    if canAdd {
                        addField
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            Color.primary.opacity(dropTarget == nil ? 0.03 : 0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .contentShape(Rectangle())
        // One drop target for the whole column: SwiftUI hands a drag to the
        // outermost target on macOS, so a target on each card would never
        // fire. The card under the pointer is found from the cards' frames.
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onDrop(of: [.boardCard], delegate: SpaceBoardDropDelegate(
            orderedIDs: section.tasks.map(\.id),
            frames: frames,
            isEnabled: !isReadOnly,
            target: $dropTarget,
            move: { taskID, beforeID in
                dropTarget = nil
                // In Today, a card dropped into To do is due today, so it
                // stays in the view it was dropped in.
                let dueTodayBy = lens == .today ? NotebookTaskBoard.dueDate(for: .today, now: Date()) : nil
                Task {
                    await vm.moveNotebookTask(taskID, notebookID: goal.id, into: section.column, before: beforeID, dueTodayBy: dueTodayBy)
                }
            }
        ))
        .onChange(of: addFocusRequest) { _, _ in
            if section.column == .status(.todo), canAdd { addFocused = true }
        }
        .confirmationDialog(
            "Delete “\(section.title)” and its \(listCardCount == 1 ? "card" : "\(listCardCount) cards")?",
            isPresented: $confirmsDelete
        ) {
            Button("Delete List", role: .destructive) { deleteList() }
        }
        // A card arriving or leaving ends any drop line still drawn.
        .onChange(of: section.tasks.map(\.id)) { _, _ in
            dropTarget = nil
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            if renaming, section.list != nil {
                TextField("List name", text: $listTitle)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: renameFocused) { wasFocused, isFocused in
                        if wasFocused, !isFocused { commitRename() }
                    }
            } else {
                Text(section.title)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { if section.list != nil, !isReadOnly { startRename() } }
                if !section.tasks.isEmpty {
                    Text("\(section.tasks.count)")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if section.list != nil, !isReadOnly, !renaming {
                listMenu
            }
        }
        .frame(minHeight: 20)
    }

    /// A list's own menu: rename it, move it among the lists, delete it.
    private var listMenu: some View {
        Menu {
            Button("Rename", systemImage: "pencil") { startRename() }
            Divider()
            Button("Move Left", systemImage: "arrow.left") { moveList(by: -1) }
                .disabled(listIndex == nil || listIndex == 0)
            Button("Move Right", systemImage: "arrow.right") { moveList(by: 1) }
                .disabled(listIndex.map { $0 >= lists.count - 1 } ?? true)
            Divider()
            Button("Delete List", systemImage: "trash", role: .destructive) {
                // A list that still holds cards asks first: its cards go with it.
                if listCardCount == 0 { deleteList() } else { confirmsDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: 0)
        .help("List")
    }

    /// Every card in the list, those the lens, the search or Mine hides included.
    private var listCardCount: Int {
        guard let list = section.list else { return 0 }
        return vm.tasks(for: goal.id).filter { $0.listID == list.id && $0.status != .done }.count
    }

    private func startRename() {
        listTitle = section.title
        renaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard renaming, let list = section.list else { return }
        renaming = false
        let trimmed = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != list.title else { return }
        Task { await vm.renameNotebookTaskList(list.id, notebookID: goal.id, to: trimmed) }
    }

    private func moveList(by offset: Int) {
        guard let list = section.list else { return }
        Task { await vm.moveNotebookTaskList(list.id, notebookID: goal.id, by: offset) }
    }

    private func deleteList() {
        guard let list = section.list else { return }
        Task { await vm.deleteNotebookTaskList(list.id, notebookID: goal.id) }
    }

    private func card(_ task: NotebookTaskRecord) -> some View {
        NotebookTaskRow(
            task: task,
            goal: goal,
            lists: lists,
            members: members,
            isTeamNotebook: isTeamNotebook,
            isReadOnly: isReadOnly,
            save: { changed in Task { await vm.saveNotebookTask(changed) } },
            delete: { Task { await vm.deleteNotebookTask(task.id, notebookID: goal.id) } }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpaceName)) } action: { frame in
            frames[task.id] = frame
        }
        .overlay(alignment: .top) {
            if dropTarget?.beforeID == task.id {
                SpaceBoardInsertionBar().offset(y: -5)
            }
        }
        .onDrag {
            SpaceBoardDropDelegate.dragProvider(taskID: task.id)
        } preview: {
            Text(task.title)
                .zoomedSystemFont(size: 12, weight: .medium)
                .lineLimit(2)
                .padding(10)
                .frame(width: 220, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            TextField("Add a card", text: $newTitle)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12)
                .focused($addFocused)
                .onSubmit(commitNewCard)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(addFocused ? 0.22 : 0.08), lineWidth: 1)
        }
    }

    private func commitNewCard() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTitle = ""
        add(title)
        // Stay in the field, so a list of cards can be typed one after another.
        addFocused = true
    }
}

// MARK: - Row

struct NotebookTaskRow: View {
    @Environment(StudioViewModel.self) private var vm
    let task: NotebookTaskRecord
    let goal: LearningGoalRecord
    /// The board's own lists, offered beside the statuses in the card's menu.
    let lists: [NotebookTaskList]
    let members: [TeamMemberRecord]
    let isTeamNotebook: Bool
    let isReadOnly: Bool
    let save: (NotebookTaskRecord) -> Void
    let delete: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var showsNotes: Bool
    @State private var showsDatePicker = false
    @State private var hovering = false
    @FocusState private var titleFocused: Bool
    @FocusState private var notesFocused: Bool

    init(
        task: NotebookTaskRecord,
        goal: LearningGoalRecord,
        lists: [NotebookTaskList] = [],
        members: [TeamMemberRecord],
        isTeamNotebook: Bool,
        isReadOnly: Bool,
        save: @escaping (NotebookTaskRecord) -> Void,
        delete: @escaping () -> Void
    ) {
        self.task = task
        self.goal = goal
        self.lists = lists
        self.members = members
        self.isTeamNotebook = isTeamNotebook
        self.isReadOnly = isReadOnly
        self.save = save
        self.delete = delete
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes)
        _showsNotes = State(initialValue: !task.notes.isEmpty)
    }

    private var isDone: Bool { task.status == .done }
    private var column: NotebookTaskBoard.Column { NotebookTaskBoard.column(of: task, listIDs: Set(lists.map(\.id))) }
    private var isInList: Bool { if case .list = column { return true } else { return false } }
    private var nextStatus: NotebookTaskStatus { NotebookTaskBoard.next(for: task, inList: isInList) }
    private var isOverdue: Bool { NotebookTaskBoard.isOverdue(task, now: Date()) }
    private var hasDetails: Bool {
        task.dueAt != nil || link != nil || (isTeamNotebook && task.assigneeRecordName != nil)
    }

    private var statusTint: Color {
        switch task.status {
        case .todo: return .secondary
        case .doing: return .accentColor
        case .done: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                save(NotebookTaskBoard.changing(task, to: nextStatus))
            } label: {
                Image(systemName: task.status.symbolName)
                    .zoomedSystemFont(size: 15, weight: .medium)
                    .foregroundStyle(statusTint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
            .disabled(isReadOnly)
            .help(task.status == .done ? "Reopen" : "Move to \(nextStatus.title)")
            .accessibilityLabel("Status: \(task.status.title)")

            VStack(alignment: .leading, spacing: 4) {
                // A long title wraps onto more lines instead of being clipped
                // at the card's edge; Return still commits it.
                TextField("Task", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isDone ? Color.secondary : Color.primary)
                    .strikethrough(isDone, color: .secondary)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: titleFocused) { wasFocused, isFocused in
                        if wasFocused, !isFocused { commitTitle() }
                    }
                    .disabled(isReadOnly)

                // Only what is set shows here; an empty due date, assignee,
                // link or note is added from the card's context menu, so a
                // plain card carries no row of small icons.
                if hasDetails {
                    HStack(spacing: 6) {
                        if task.dueAt != nil { dueMenu }
                        if isTeamNotebook, task.assigneeRecordName != nil { assigneeMenu }
                        if link != nil { linkMenu }
                        Spacer(minLength: 0)
                    }
                }

                if showsNotes {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1...8)
                        .focused($notesFocused)
                        .onChange(of: notesFocused) { wasFocused, isFocused in
                            if wasFocused, !isFocused { commitNotes() }
                        }
                        .disabled(isReadOnly)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(hovering ? 0.045 : 0.025),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .onHover { hovering = $0 }
        .overlay(alignment: .bottomLeading) { datePickerPopover }
        // A synced edit from another member arrives through the record, not
        // the field; mirror it unless this row is being typed in right now.
        .onChange(of: task.title) { _, newTitle in
            if !titleFocused { title = newTitle }
        }
        .onChange(of: task.notes) { _, newNotes in
            if !notesFocused { notes = newNotes }
        }
        .contextMenu {
            ForEach(NotebookTaskStatus.allCases, id: \.self) { status in
                columnItem(.status(status), title: status.title, symbol: status.symbolName)
                if status == .doing {
                    ForEach(lists) { list in
                        columnItem(.list(list.id), title: list.title, symbol: "list.bullet")
                    }
                }
            }
            if !isReadOnly {
                Divider()
                Menu("Due Date", systemImage: "calendar") { dueChoices }
                if isTeamNotebook {
                    Menu("Assign", systemImage: "person.crop.circle.badge.plus") { assigneeChoices }
                }
                Menu("Link", systemImage: "link") { linkChoices }
                Button(showsNotes ? "Hide Notes" : "Notes", systemImage: "text.alignleft") {
                    showsNotes.toggle()
                    if showsNotes { notesFocused = true }
                }
                Divider()
                Button(role: .destructive, action: delete) {
                    Label("Delete Task", systemImage: "trash")
                }
            }
        }
    }

    /// The card's menu item for one column: a checkmark on the one it is in.
    private func columnItem(_ target: NotebookTaskBoard.Column, title: String, symbol: String) -> some View {
        Button {
            save(NotebookTaskBoard.placing(task, in: target))
        } label: {
            Label(title, systemImage: target == column ? "checkmark" : symbol)
        }
        .disabled(isReadOnly || target == column)
    }

    @ViewBuilder
    private var dueChoices: some View {
        ForEach(NotebookTaskBoard.DuePreset.allCases, id: \.self) { preset in
            Button(preset.title) {
                saveDue(NotebookTaskBoard.dueDate(for: preset, now: Date()))
            }
        }
        Button("Pick a Date…") { showsDatePicker = true }
        if task.dueAt != nil {
            Divider()
            Button("Clear Due Date", role: .destructive) { saveDue(nil) }
        }
    }

    private var dueMenu: some View {
        Menu {
            dueChoices
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOverdue ? "calendar.badge.exclamationmark" : "calendar")
                    .zoomedSystemFont(size: 10, weight: .medium)
                if let dueAt = task.dueAt {
                    Text(dueAt.formatted(date: .abbreviated, time: .omitted))
                        .zoomedSystemFont(size: 10, weight: .medium)
                }
            }
            .foregroundStyle(isOverdue ? Color.red : (task.dueAt == nil ? Color.secondary : Color.primary.opacity(0.75)))
            .padding(.horizontal, task.dueAt == nil ? 0 : 5)
            .frame(minWidth: 20, minHeight: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: 0)
        .disabled(isReadOnly)
        .help(task.dueAt == nil ? "Set a due date" : (isOverdue ? "Overdue" : "Due date"))
    }

    /// The date picker hangs off the card, so "Pick a Date…" from the context
    /// menu opens it when no due-date chip exists yet.
    private var datePickerPopover: some View {
        Color.clear.frame(width: 0, height: 0).popover(isPresented: $showsDatePicker, arrowEdge: .bottom) {
            DatePicker(
                "Due",
                selection: Binding(
                    get: { task.dueAt ?? NotebookTaskBoard.dueDate(for: .today, now: Date()) ?? Date() },
                    set: { picked in
                        // Same end-of-day rule as the presets: the day is the
                        // promise, not the minute the picker happened to hold.
                        let calendar = Calendar.current
                        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: picked))?
                            .addingTimeInterval(-60)
                        saveDue(end ?? picked)
                    }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
        }
    }

    @ViewBuilder
    private var assigneeChoices: some View {
        Button {
            saveAssignee(nil)
        } label: {
            if task.assigneeRecordName == nil {
                Label("Unassigned", systemImage: "checkmark")
            } else {
                Text("Unassigned")
            }
        }
        if !members.isEmpty { Divider() }
        ForEach(members) { member in
            Button {
                saveAssignee(member)
            } label: {
                if member.userRecordName == task.assigneeRecordName {
                    Label(member.displayName, systemImage: "checkmark")
                } else {
                    Text(member.displayName)
                }
            }
        }
    }

    private var assigneeMenu: some View {
        Menu {
            assigneeChoices
        } label: {
            HStack(spacing: 4) {
                if let name = task.assigneeDisplayName, task.assigneeRecordName != nil {
                    TeamMemberAvatar(initials: TeamMemberRecord.initials(for: name), size: 16)
                    Text(name)
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, task.assigneeRecordName == nil ? 0 : 5)
            .frame(minWidth: 20, minHeight: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: 0)
        .disabled(isReadOnly)
        .help(task.assigneeDisplayName.map { "Assigned to \($0)" } ?? "Assign")
    }

    // MARK: Source or Doc

    private var link: NotebookTaskBoard.Link? { NotebookTaskBoard.link(of: task) }

    /// The sources a task here can be about: the Notebook's own and those of
    /// the context notebooks its chats read (`notebookChatPool`).
    private var linkableSources: [StudioArticle] {
        vm.notebookChatPool(goal).compactMap { vm.learningGoalSource(for: $0) }
    }

    /// The Notebook's Docs and pages; an audio overview is played, not worked on.
    private var linkableDocs: [ArtifactRecord] {
        vm.linkedArtifacts(notebookID: goal.id).filter { !vm.isAudioOverview($0) }
    }

    /// The linked item's title, or nil when it has left the library.
    private var linkTitle: String? {
        switch link {
        case .source(let id): return vm.learningGoalSource(for: id)?.title
        case .doc(let id): return vm.artifacts.first { $0.id == id }?.title
        case nil: return nil
        }
    }

    private var linkSymbol: String {
        switch link {
        case .source: return "book"
        case .doc: return "doc.text"
        case nil: return "link"
        }
    }

    @ViewBuilder
    private var linkChoices: some View {
        if linkableSources.isEmpty, linkableDocs.isEmpty {
            Text("No sources or Pages in this notebook")
        }
        if !linkableSources.isEmpty {
            Menu("Source", systemImage: "book") {
                ForEach(linkableSources) { source in
                    Button {
                        saveLink(.source(source.id))
                    } label: {
                        if link == .source(source.id) {
                            Label(source.title, systemImage: "checkmark")
                        } else {
                            Text(source.title)
                        }
                    }
                }
            }
        }
        if !linkableDocs.isEmpty {
            Menu("Page", systemImage: "doc.text") {
                ForEach(linkableDocs) { doc in
                    Button {
                        saveLink(.doc(doc.id))
                    } label: {
                        if link == .doc(doc.id) {
                            Label(doc.title, systemImage: "checkmark")
                        } else {
                            Text(doc.title)
                        }
                    }
                }
            }
        }
    }

    /// One control: a chip naming the source or Doc the task is about, or a
    /// link glyph when there is none. The menu opens the linked item, offers
    /// the Notebook's sources and Docs, and removes the link.
    private var linkMenu: some View {
        Menu {
            if let link {
                Button("Open", systemImage: linkSymbol) { open(link) }
                switch link {
                case .source(let id): OtherWindowSourceMenuItem(sourceID: id)
                case .doc(let id): OtherWindowMenuItem(.doc(id))
                }
            }
            // A read-only member gets the Open item and nothing to change.
            if !isReadOnly {
                if link != nil { Divider() }
                linkChoices
                if link != nil {
                    Divider()
                    Button("Remove Link", role: .destructive) { saveLink(nil) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: linkSymbol)
                    .zoomedSystemFont(size: 10, weight: .medium)
                if link != nil {
                    Text(linkTitle ?? "Missing")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
            .foregroundStyle(link == nil ? Color.secondary : Color.primary.opacity(0.75))
            .padding(.horizontal, link == nil ? 0 : 5)
            .frame(minWidth: 20, minHeight: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: 0)
        // Read-only members may still open what the task points at.
        .disabled(isReadOnly && link == nil)
        .help(linkTitle.map { "About \($0)" } ?? "Link a source or Page")
    }

    private func open(_ link: NotebookTaskBoard.Link) {
        switch link {
        case .source(let id):
            Task { await vm.revealSourceInReader(id) }
        case .doc(let id):
            vm.revealArtifact(id)
        }
    }

    private func saveLink(_ link: NotebookTaskBoard.Link?) {
        guard !isReadOnly else { return }
        save(NotebookTaskBoard.linking(task, to: link))
    }

    private func commitTitle() {
        // A wrapping field can take a pasted line break; a title stays one line.
        let trimmed = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            title = task.title
            return
        }
        guard trimmed != task.title else { return }
        var changed = task
        changed.title = trimmed
        changed.updatedAt = Date()
        save(changed)
    }

    private func commitNotes() {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != task.notes else { return }
        var changed = task
        changed.notes = trimmed
        changed.updatedAt = Date()
        save(changed)
    }

    private func saveDue(_ dueAt: Date?) {
        var changed = task
        changed.dueAt = dueAt
        changed.updatedAt = Date()
        save(changed)
    }

    private func saveAssignee(_ member: TeamMemberRecord?) {
        var changed = task
        changed.assigneeRecordName = member?.userRecordName
        changed.assigneeDisplayName = member?.displayName
        changed.updatedAt = Date()
        save(changed)
    }
}

// MARK: - New list

/// The end of the board's row of columns: New list, which opens into a field
/// that names a list and adds it. The field stays open after a list is added,
/// so several can be typed one after another; Escape or an empty field
/// leaving focus closes it.
private struct NotebookTaskNewListField: View {
    @Environment(StudioViewModel.self) private var vm
    let notebookID: String

    @State private var editing = false
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("List name", text: $title)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: close)
                    .onChange(of: focused) { wasFocused, isFocused in
                        if wasFocused, !isFocused, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { close() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(focused ? 0.22 : 0.08), lineWidth: 1)
                    }
            } else {
                Button {
                    editing = true
                    focused = true
                } label: {
                    Label("New list", systemImage: "plus")
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            close()
            return
        }
        title = ""
        focused = true
        Task { await vm.addNotebookTaskList(notebookID: notebookID, title: trimmed) }
    }

    private func close() {
        title = ""
        editing = false
    }
}
