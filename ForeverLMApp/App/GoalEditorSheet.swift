import SwiftUI

// MARK: - What a save changes

/// The fields of a Goal the editor lets a learner change, and the arithmetic
/// of which ones a save touches. Each changed field goes through the write
/// that already exists for it — title, deadline, Notebook tag, artifact — so
/// saving a title never rewrites a deadline, and an untouched field is never
/// written at all (a write would bump `updated_at` and win a sync merge over
/// another device's real change).
struct GoalEdit: Equatable {
    var title: String
    var deadline: Date
    var notebookID: String?
    var artifactID: String?

    init(goal: LearningGoalRecord) {
        title = goal.title
        deadline = goal.endAt
        notebookID = Self.normalized(goal.parentNotebookID)
        artifactID = goal.linkedArtifactID
    }

    /// What differs from the record, field by field. `retagsNotebook` and
    /// `relinksArtifact` say the tag is to be written even when the new value
    /// is nil, which is how an untag or an unlink is told from "left alone".
    struct Changes: Equatable {
        var title: String?
        var deadline: Date?
        var retagsNotebook = false
        var notebookID: String?
        var relinksArtifact = false
        var artifactID: String?

        var isEmpty: Bool {
            title == nil && deadline == nil && !retagsNotebook && !relinksArtifact
        }
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The deadline as it would be stored: the start of the chosen day, the
    /// way **Set a goal** stores one.
    func deadlineDay(calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: deadline)
    }

    func changes(from goal: LearningGoalRecord, calendar: Calendar = .current) -> Changes {
        var changes = Changes()
        if !trimmedTitle.isEmpty, trimmedTitle != goal.title {
            changes.title = trimmedTitle
        }
        let day = deadlineDay(calendar: calendar)
        if !calendar.isDate(day, inSameDayAs: goal.endAt) {
            changes.deadline = day
        }
        let notebook = Self.normalized(notebookID)
        if notebook != Self.normalized(goal.parentNotebookID) {
            changes.retagsNotebook = true
            changes.notebookID = notebook
        }
        let artifact = Self.normalized(artifactID)
        if artifact != goal.linkedArtifactID {
            changes.relinksArtifact = true
            changes.artifactID = artifact
        }
        return changes
    }

    private static func normalized(_ id: String?) -> String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - One Goal, opened

/// What a click on a Goal's row opens: the Goal itself (product owner, 2026-09-20,
/// on the row opening a "What is this goal for?" picker instead: "this seems
/// very poorly designed"). One sheet holds everything the row says and lets
/// the learner change it — the sentence, the deadline, the Notebook it draws
/// on, the Doc, Site or animation it is for — and shows what the row cannot
/// fit: the sources, chats and directions on it, each row drawn only once
/// there is one. Marking done, archiving and deleting sit in the footer's ⋯,
/// so the row's menu is no longer the only route.
///
/// Save writes the changed fields and nothing else (`GoalEdit.changes`);
/// `update_learning_goal` is the same move over MCP.
struct GoalEditorSheet: View {
    let goal: LearningGoalRecord

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var edit: GoalEdit
    @State private var isListingSources = false
    @State private var isListingChats = false
    @State private var isConfirmingDelete = false
    @FocusState private var titleFocused: Bool

    init(goal: LearningGoalRecord) {
        self.goal = goal
        _edit = State(initialValue: GoalEdit(goal: goal))
    }

    private var isOpen: Bool { !(goal.isDone || goal.isArchived) }

    private var changes: GoalEdit.Changes { edit.changes(from: goal) }

    /// Tomorrow: a deadline is a day still to come. The record's own date may
    /// be behind it (an overdue Goal), and that is read, not rejected.
    private var minimumDeadline: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    private var deadlineIsSaveable: Bool {
        guard let moved = changes.deadline else { return true }
        return moved >= minimumDeadline
    }

    private var canSave: Bool {
        !edit.trimmedTitle.isEmpty && !changes.isEmpty && deadlineIsSaveable
    }

    /// "Sunday 21 September · 3 days", the chosen day said in full; "6 days
    /// ago" for a date that has passed.
    private var deadlineDetail: String {
        let calendar = Calendar.current
        let day = edit.deadlineDay()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: day).day ?? 0
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if days < 0 {
            let late = -days
            return "\(date) · \(late) day\(late == 1 ? "" : "s") ago"
        }
        return "\(date) · \(days) day\(days == 1 ? "" : "s")"
    }

    /// An audio overview is played from its notebook, not something a Goal is for.
    private var choices: GoalArtifactChoices { GoalArtifactChoices(vm.artifacts.filter { !vm.isAudioOverview($0) }) }

    /// The record the picked artifact names, when the library holds it.
    private var pickedArtifact: ArtifactRecord? {
        edit.artifactID.flatMap { id in vm.artifacts.first(where: { $0.id == id }) }
    }

    private var sourcesText: String? {
        let count = goal.approvedSourceIDs.count
        guard count > 0 else { return nil }
        return GoalSourceListing.heading(count: count)
    }

    /// How many chats are filed under the Goal, and whether it has
    /// directions: their rows are drawn only when there is one.
    private var chatCount: Int { vm.reviewSessions(forGoal: goal.id).count }
    private var hasDirections: Bool { !vm.researchDirections(forHome: goal.id).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            // The sentence is the sheet's title: no "Goal" heading above it
            // (2026-10-06). The deadline badge, when it asks for something,
            // stands beside By.
            TextField("I want to understand\u{2026}", text: $edit.title, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 15)
                .lineLimit(1...3)
                .padding(StudioDesign.Spacing.medium)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .focused($titleFocused)
                .accessibilityIdentifier("studio.goals.editor.title")

            if isOpen {
                workOnIt
            }

            deadlineSection

            Divider()

            // Sources, Chats and Directions are rows only once there is one:
            // an empty row explained where one comes from, which the actions
            // above and a drop on the Goal's row already say (2026-10-06).
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
                row("Draws on") { notebookPicker }
                if !choices.isEmpty || edit.artifactID != nil {
                    row("For") { artifactPicker }
                }
                if let sourcesText {
                    row("Sources") { sources(sourcesText) }
                }
                if chatCount > 0 {
                    row("Chats") { chats }
                }
                if hasDirections {
                    row("Directions") { directions }
                }
            }

            footer
        }
        .padding(StudioDesign.Spacing.xLarge)
        .frame(width: 500)
        .onAppear { titleFocused = true }
        .task {
            // The artifact picker lists the loaded library, which the Goals
            // tab asks for on appearance; a sheet opened before that answers
            // still needs it.
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
        }
        .confirmationDialog("Delete “\(goal.title)”?", isPresented: $isConfirmingDelete) {
            Button("Delete Goal", role: .destructive) {
                dismiss()
                Task { await vm.deleteLearningGoal(goal.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sources stay in your library, and a chat started from it stays in Chats.")
        }
    }

    // MARK: Making progress

    /// The ways to start on the Goal now (product owner, 2026-09-20: "if I click a
    /// goal, I basically want a way to like start making progress on it.
    /// Like maybe start a chat that has the sources, or start a quiz"). Two
    /// routes: a chat with the Goal's
    /// sources in context, and a review — being questioned on them — that
    /// is stamped with the Goal and counts toward it. Both keep what was
    /// typed in the sheet before leaving it. All three stay in view, as he
    /// asked for them; since 2026-10-06 Chat is the one prominent button and
    /// Quiz me and Find directions are plain beside it, where three bordered
    /// buttons read as three equal choices.
    private var workOnIt: some View {
        HStack(spacing: StudioDesign.Spacing.medium) {
            Button {
                leave { vm.requestGoalChat(goal) }
            } label: {
                Label("Chat about it", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderedProminent)
            .help(goal.approvedSourceIDs.isEmpty
                  ? "Open a chat about this goal"
                  : "Open a chat with the goal's sources in context")
            .accessibilityIdentifier("studio.goals.editor.chat")

            Button {
                leave {
                    vm.startCompanionReview(
                        goalID: goal.id,
                        sourceIDs: goal.approvedSourceIDs,
                        topic: goal.topic ?? goal.title
                    )
                }
            } label: {
                // A chromeless label reads as disabled only by its colour.
                Label("Quiz me on it", systemImage: "questionmark.bubble")
                    .foregroundStyle(goal.approvedSourceIDs.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.hoverWash)
            .disabled(goal.approvedSourceIDs.isEmpty)
            .help(goal.approvedSourceIDs.isEmpty
                  ? "A review needs sources on the goal; drop some on its row first"
                  : "Be questioned on the goal's sources; finishing counts toward the goal")
            .accessibilityIdentifier("studio.goals.editor.review")

            // Directions (docs/directions-design.md): a Deep Research chat
            // that searches the literature and the web for ways forward,
            // starting from the goal's sources and every answer given before.
            Button {
                leave { vm.requestDirectionSearch(forGoal: goal) }
            } label: {
                Label("Find directions", systemImage: "signpost.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash)
            .help("Search the literature and the web for directions worth pursuing toward this goal")
            .accessibilityIdentifier("studio.goals.editor.directions")

            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    // MARK: Deadline

    /// By, with the Goal's badge beside it while that asks for something
    /// (overdue, due within three days, done or archived). The day said in
    /// full shows only when the chosen one cannot be saved (2026-10-06): the
    /// date field already reads the day.
    private var deadlineSection: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.small) {
                Text("By")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                GoalStatusBadge(goal: goal)
            }
            HStack(spacing: StudioDesign.Spacing.small) {
                deadlineChip("Sunday", GoalDeadlinePopover.comingSunday())
                deadlineChip("In two weeks", GoalDeadlinePopover.fortnight())
                DatePicker("Deadline", selection: $edit.deadline, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityIdentifier("studio.goals.editor.deadline")
            }
            if !deadlineIsSaveable {
                Text("\(deadlineDetail) — a deadline is a day still to come.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(Color.orange)
                    .accessibilityIdentifier("studio.goals.editor.deadlineDetail")
            }
        }
    }

    private func deadlineChip(_ label: String, _ date: Date) -> some View {
        let selected = Calendar.current.isDate(edit.deadline, inSameDayAs: date)
        return Button {
            edit.deadline = date
        } label: {
            Text(label)
                .zoomedSystemFont(size: 12, weight: selected ? .medium : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .padding(.horizontal, StudioDesign.Spacing.medium)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0))
    }

    // MARK: Rows

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.medium) {
            Text(label)
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// The Notebook the Goal draws on. A tag to a Notebook that is archived or
    /// gone stays choosable under its own name, so opening the editor never
    /// silently changes it. The caption beside it, "Its sources come along.",
    /// went on 2026-10-06.
    private var notebookPicker: some View {
        HStack(spacing: StudioDesign.Spacing.small) {
            NotebookPickerField(label: "Notebook", notebookID: $edit.notebookID)
                .frame(maxWidth: 260, alignment: .leading)
            .accessibilityIdentifier("studio.goals.editor.notebook")
        }
    }

    /// The Doc, Site or animation the Goal is for, with the way to open it
    /// beside the choice. Most Goals are for nothing yet, and that is the
    /// ordinary case rather than a question to answer first.
    private var artifactPicker: some View {
        HStack(spacing: StudioDesign.Spacing.small) {
            Picker("For", selection: $edit.artifactID) {
                Text("Nothing yet").tag(String?.none)
                ForEach(choices.sections, id: \.section) { group in
                    Section(group.section.title) {
                        ForEach(group.records) { record in
                            Text(record.title).tag(String?.some(record.id))
                        }
                    }
                }
                if let current = edit.artifactID, !choices.sections.contains(where: { $0.records.contains { $0.id == current } }) {
                    Text(vm.artifacts.first(where: { $0.id == current })?.title ?? "A page or site no longer here")
                        .tag(String?.some(current))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .accessibilityIdentifier("studio.goals.editor.artifact")
            if let pickedArtifact {
                Button {
                    dismiss()
                    Task { await vm.openTeamArtifact(pickedArtifact.id) }
                } label: {
                    Label("Open", systemImage: pickedArtifact.goalRowSymbolName)
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Open \(pickedArtifact.title)")
                .accessibilityIdentifier("studio.goals.editor.openArtifact")
            }
        }
    }

    /// The sources on the Goal: the count, opening the same list the row's
    /// chip opens. Sources are added by a drop on the Goal's row.
    private func sources(_ sourcesText: String) -> some View {
        Button {
            isListingSources.toggle()
        } label: {
            Label(sourcesText, systemImage: "doc.text")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash)
        .help("List the sources on this goal")
        .accessibilityIdentifier("studio.goals.editor.sources")
        .popover(isPresented: $isListingSources, arrowEdge: .bottom) {
            GoalSourcesPopover(goal: goal) {
                isListingSources = false
                dismiss()
            }
        }
    }

    /// The chats filed under the Goal (`StudioViewModel.reviewSessions(forGoal:)`):
    /// the count, opening the same list the row's chip opens. One comes from
    /// Chat about it above, or from a chat's Move to Notebook in the sidebar.
    private var chats: some View {
        Button {
            isListingChats.toggle()
        } label: {
            Label(GoalChatListing.heading(count: chatCount), systemImage: "bubble.left.and.bubble.right")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash)
        .help("List the chats about this goal")
        .accessibilityIdentifier("studio.goals.editor.chats")
        .popover(isPresented: $isListingChats, arrowEdge: .bottom) {
            GoalChatsPopover(goal: goal) {
                isListingChats = false
                dismiss()
            }
        }
    }

    /// What was proposed toward the Goal: the same chip the row carries.
    /// Find directions above searches for more.
    private var directions: some View {
        DirectionsChip(homeKind: goal.isNotebook ? .notebook : .goal, homeID: goal.id, homeTitle: goal.title) {
            leave { vm.requestDirectionSearch(forGoal: goal) }
        }
    }

    // MARK: Footer

    /// Cancel and Save, with the Goal's status changes in a ⋯ beside them:
    /// Mark done and Archive (or Reopen), then Delete…. They were three more
    /// bordered buttons on the footer's left until 2026-10-06.
    private var footer: some View {
        HStack(spacing: StudioDesign.Spacing.small) {
            Spacer(minLength: StudioDesign.Spacing.medium)
            Menu {
                if isOpen {
                    Button("Mark done") { finish(with: .done) }
                        .accessibilityIdentifier("studio.goals.editor.done")
                    Button("Archive") { finish(with: .archived) }
                        .accessibilityIdentifier("studio.goals.editor.archive")
                } else {
                    Button("Reopen") { finish(with: .active) }
                        .accessibilityIdentifier("studio.goals.editor.reopen")
                }
                Divider()
                Button("Delete\u{2026}", role: .destructive) { isConfirmingDelete = true }
                    .accessibilityIdentifier("studio.goals.editor.delete")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mark done, archive or delete")
            .accessibilityLabel("More")
            .accessibilityIdentifier("studio.goals.editor.more")
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("studio.goals.editor.save")
        }
    }

    private func save() {
        guard canSave else { return }
        let changes = changes
        dismiss()
        Task { await vm.updateGoal(goalID: goal.id, changes) }
    }

    /// A status button keeps what was typed: the edits are saved first, so
    /// marking a Goal done after fixing its title loses neither.
    private func finish(with status: LearningGoalStatus) {
        leave { await vm.setGoalStatus(goalID: goal.id, status: status) }
    }

    /// Close the sheet for an action elsewhere — a chat, a review, a status
    /// change — saving pending edits first so nothing typed here is lost.
    private func leave(then action: @escaping @MainActor () async -> Void) {
        let changes = changes
        let saveFirst = canSave
        dismiss()
        Task {
            if saveFirst { await vm.updateGoal(goalID: goal.id, changes) }
            await action()
        }
    }
}
