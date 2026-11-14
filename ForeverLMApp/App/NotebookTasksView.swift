import SwiftUI

// MARK: - Board

/// A Notebook's task board: To do, In progress and Done as columns of cards,
/// each card a task row. A card is dragged to another column, or to another
/// place in its column; the circle on it still moves it one column on. A card
/// is added at the foot of To do or In progress. In a team Notebook the tasks
/// can be handed to a member; a read-only team shows the board with every
/// editing control disabled.
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

    private var isReadOnly: Bool { vm.isActiveLibraryReadOnly }
    private var isTeamNotebook: Bool { goal.teamID != nil }

    private var members: [TeamMemberRecord] {
        guard let teamID = goal.teamID else { return [] }
        return vm.members(of: teamID).filter { $0.acceptanceStatus != "removed" }
    }

    private var currentMember: TeamMemberRecord? {
        goal.teamID.flatMap { vm.currentMember(of: $0) }
    }

    private var sections: [NotebookTaskBoard.Section] {
        let shown = NotebookTaskBoard.filtered(
            vm.tasks(for: goal.id),
            mineOnly: mineOnly && isTeamNotebook,
            currentUserRecordName: currentMember?.userRecordName
        )
        return NotebookTaskBoard.sections(
            NotebookTaskBoard.matching(NotebookTaskBoard.lensed(shown, lens, now: Date()), query: query)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let gaps = Self.columnGap * 2
            let columnWidth = max(Self.minimumColumnWidth, (proxy.size.width - horizontalPadding * 2 - gaps) / 3)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnGap) {
                    ForEach(sections, id: \.status) { section in
                        NotebookTaskColumn(
                            section: section,
                            goal: goal,
                            members: members,
                            isTeamNotebook: isTeamNotebook,
                            isReadOnly: isReadOnly,
                            lens: lens,
                            addFocusRequest: addFocusRequest,
                            add: { title in addTask(title, status: section.status) }
                        )
                        .frame(width: columnWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
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

    private func addTask(_ title: String, status: NotebookTaskStatus) {
        guard !isReadOnly else { return }
        var task = NotebookTaskRecord(
            notebookID: goal.id,
            teamID: goal.teamID,
            title: title,
            status: status,
            sortOrder: NotebookTaskBoard.nextSortOrder(after: vm.tasks(for: goal.id).filter { $0.status == status })
        )
        // A card typed while the board shows only mine is mine, and one typed
        // in Today is due today; otherwise it would vanish from the board
        // the moment it was saved.
        if mineOnly, isTeamNotebook, let me = currentMember {
            task.assigneeRecordName = me.userRecordName
            task.assigneeDisplayName = me.displayName
        }
        if lens == .today, status == .todo {
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
    let members: [TeamMemberRecord]
    let isTeamNotebook: Bool
    let isReadOnly: Bool
    let lens: NotebookTaskBoard.Lens
    let addFocusRequest: Int
    let add: (String) -> Void

    @State private var newTitle = ""
    @State private var frames: [String: CGRect] = [:]
    @State private var dropTarget: SpaceBoardDropTarget?
    @FocusState private var addFocused: Bool

    private static let coordinateSpaceName = "boardColumn"

    private var status: NotebookTaskStatus { section.status }
    private var canAdd: Bool { status != .done && !isReadOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(status.title)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                if !section.tasks.isEmpty {
                    Text("\(section.tasks.count)")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
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
                    await vm.moveNotebookTask(taskID, notebookID: goal.id, to: status, before: beforeID, dueTodayBy: dueTodayBy)
                }
            }
        ))
        .onChange(of: addFocusRequest) { _, _ in
            if status == .todo, canAdd { addFocused = true }
        }
        // A card arriving or leaving ends any drop line still drawn.
        .onChange(of: section.tasks.map(\.id)) { _, _ in
            dropTarget = nil
        }
    }

    private func card(_ task: NotebookTaskRecord) -> some View {
        NotebookTaskRow(
            task: task,
            goal: goal,
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
        members: [TeamMemberRecord],
        isTeamNotebook: Bool,
        isReadOnly: Bool,
        save: @escaping (NotebookTaskRecord) -> Void,
        delete: @escaping () -> Void
    ) {
        self.task = task
        self.goal = goal
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
    private var isOverdue: Bool { NotebookTaskBoard.isOverdue(task, now: Date()) }

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
                save(NotebookTaskBoard.changing(task, to: NotebookTaskBoard.next(after: task.status)))
            } label: {
                Image(systemName: task.status.symbolName)
                    .zoomedSystemFont(size: 15, weight: .medium)
                    .foregroundStyle(statusTint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
            .disabled(isReadOnly)
            .help(task.status == .done ? "Reopen" : "Move to \(NotebookTaskBoard.next(after: task.status).title)")
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

                HStack(spacing: 6) {
                    dueMenu
                    if isTeamNotebook {
                        assigneeMenu
                    }
                    linkMenu
                    Button {
                        showsNotes.toggle()
                        if showsNotes { notesFocused = true }
                    } label: {
                        Image(systemName: "text.alignleft")
                            .zoomedSystemFont(size: 10, weight: .medium)
                            .foregroundStyle(notes.isEmpty ? Color.secondary : Color.accentColor)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                    .help(showsNotes ? "Hide notes" : "Notes")
                    Spacer(minLength: 0)
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
                Button {
                    save(NotebookTaskBoard.changing(task, to: status))
                } label: {
                    if status == task.status {
                        Label(status.title, systemImage: "checkmark")
                    } else {
                        Label(status.title, systemImage: status.symbolName)
                    }
                }
                .disabled(isReadOnly || status == task.status)
            }
            if !isReadOnly {
                Divider()
                Button(role: .destructive, action: delete) {
                    Label("Delete Task", systemImage: "trash")
                }
            }
        }
    }

    private var dueMenu: some View {
        Menu {
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
        .popover(isPresented: $showsDatePicker, arrowEdge: .bottom) {
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

    private var assigneeMenu: some View {
        Menu {
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
