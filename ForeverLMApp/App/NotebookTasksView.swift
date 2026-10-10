import SwiftUI

// MARK: - Inspector card

/// The Tasks card on a notebook's About: how much is still open, how much of
/// it is the signed-in member's, and the way into the board, which opens in
/// About's place. Sits after Goals, so the notebook's own work reads before
/// its files.
struct NotebookTasksInspectorSection: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let summary = vm.openTaskSummary(for: goal.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Tasks")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                if summary.open > 0 {
                    Text("\(summary.open)")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .zoomedSystemFont(size: 20, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, height: 46)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.open == 1 ? "1 open task" : "\(summary.open) open tasks")
                            .zoomedSystemFont(size: 12, weight: .semibold)
                            .foregroundStyle(.primary)
                        if summary.mine > 0 {
                            Text("\(summary.mine) assigned to you")
                                .zoomedSystemFont(size: 10)
                                .foregroundStyle(.tertiary)
                        }
                        Text("Open board")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                }
            }
            .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0))
        }
        .padding(18)
        .task(id: goal.id) {
            await vm.loadNotebookTasks(notebookID: goal.id)
        }
    }
}

// MARK: - Board

/// A Notebook's task board: one list grouped by status, with an entry field at
/// the top. Every Notebook has one; in a team Notebook the tasks can be handed
/// to a member and the "Mine" filter narrows the board to the signed-in one.
/// A read-only team shows the board with every editing control disabled.
struct NotebookTasksBoardView: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let onBack: () -> Void

    @State private var newTaskTitle = ""
    @State private var mineOnly = false

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
        NotebookTaskBoard.sections(
            NotebookTaskBoard.filtered(
                vm.tasks(for: goal.id),
                mineOnly: mineOnly && isTeamNotebook,
                currentUserRecordName: currentMember?.userRecordName
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if !isReadOnly {
                addField
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.status) { section in
                        // Done and In progress appear once something is in
                        // them; To do is always drawn so an empty board still
                        // has a place the first task will land.
                        if !section.tasks.isEmpty || section.status == .todo {
                            sectionView(section)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, StudioDesign.Metrics.pageMargin)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: goal.id) {
            await vm.loadNotebookTasks(notebookID: goal.id)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 11, weight: .semibold)
            }
            .buttonStyle(.hoverWash)
            .help("Back to About")

            Text("Tasks")
                .zoomedSystemFont(size: 17, weight: .semibold)

            Spacer(minLength: 8)

            if isTeamNotebook {
                Button {
                    mineOnly.toggle()
                } label: {
                    Label("Mine", systemImage: "person.crop.circle")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(mineOnly ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.hoverWash)
                .help(mineOnly ? "Show everyone's tasks" : "Show only tasks assigned to you")
                .accessibilityAddTraits(mineOnly ? .isSelected : [])
            }
        }
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            TextField("New task", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12)
                .onSubmit(addTask)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func sectionView(_ section: NotebookTaskBoard.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.status.title)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                if !section.tasks.isEmpty {
                    Text("\(section.tasks.count)")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 4)

            ForEach(section.tasks) { task in
                NotebookTaskRow(
                    task: task,
                    goal: goal,
                    members: members,
                    isTeamNotebook: isTeamNotebook,
                    isReadOnly: isReadOnly,
                    save: { changed in Task { await vm.saveNotebookTask(changed) } },
                    delete: { Task { await vm.deleteNotebookTask(task.id, notebookID: goal.id) } }
                )
            }
        }
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isReadOnly else { return }
        var task = NotebookTaskRecord(
            notebookID: goal.id,
            teamID: goal.teamID,
            title: title,
            sortOrder: NotebookTaskBoard.nextSortOrder(after: vm.tasks(for: goal.id))
        )
        // A task typed while the board shows only mine is mine; otherwise it
        // would vanish from the filtered board the moment it was saved.
        if mineOnly, isTeamNotebook, let me = currentMember {
            task.assigneeRecordName = me.userRecordName
            task.assigneeDisplayName = me.displayName
        }
        newTaskTitle = ""
        Task { await vm.saveNotebookTask(task) }
    }
}

// MARK: - Row

private struct NotebookTaskRow: View {
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
                TextField("Task", text: $title)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 12, weight: .medium)
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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
