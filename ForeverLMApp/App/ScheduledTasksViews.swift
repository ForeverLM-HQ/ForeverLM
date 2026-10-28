import SwiftUI
import AppKit

/// The Tasks center pane: every recurring instruction, when it next runs, and
/// what its last runs produced.
struct ScheduledTasksReaderPane: View {
    @Environment(StudioViewModel.self) private var vm

    private let runner = ScheduledTaskRunner.shared
    /// Editing an existing task only. Creation goes through chat, where the
    /// assistant writes the instruction and cadence from what the learner says.
    @State private var editingTask: ScheduledTask?
    @State private var expandedTaskIDs: Set<String> = []
    @State private var actionErrorMessage: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand { vm.showTasksInReader = false }
            .studioChromeLineHeader {
                toolbar
                    .padding(.horizontal, 16)
                    .background(WindowDragBlocker())
            }
            .studioCenterTabCloseChrome(for: .tasks)
            .sheet(item: $editingTask) { task in
                ScheduledTaskEditor(task: task) { edited in
                    await perform { try await runner.save(edited) }
                }
            }
            .alert(
                "Scheduled task",
                isPresented: Binding(
                    get: { actionErrorMessage != nil },
                    set: { if !$0 { actionErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { actionErrorMessage = nil }
            } message: {
                Text(actionErrorMessage ?? "")
            }
            .task { await runner.refresh() }
    }

    /// Quiet chrome (docs/ui-design.md, 2026-10-06): **+** (a new task, in
    /// Chat) and the ⋯, which holds Keep This Mac Awake for Tasks, the cup
    /// button on the line until then.
    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                vm.requestNewScheduledTaskChat()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.hoverWash)
            .help("New task in Chat")
            .accessibilityIdentifier("studio.tasks.new")

            Menu {
                // `ScheduledTaskWakePolicy`: a run in progress always holds
                // off idle sleep; this also covers the hours before one, on
                // power.
                Toggle(isOn: Binding(
                    get: { runner.keepsMacAwake },
                    set: { runner.setKeepsMacAwake($0) }
                )) {
                    Label("Keep This Mac Awake for Tasks", systemImage: "cup.and.saucer")
                }
                .help("While plugged in, this Mac stays awake when a task is due within 12 hours")
                .accessibilityIdentifier("studio.tasks.keepAwake")
            } label: {
                RowMoreActionsLabel()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .hoverHighlight()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            .accessibilityIdentifier("studio.tasks.more")
        }
    }

    /// Screen record mode lists only tasks made during the take or filed
    /// under the recording Notebook (`ScreenRecordScope`).
    private var visibleDetails: [ScheduledTaskDetail] {
        guard let scope = vm.screenRecordScope else { return runner.details }
        return runner.details.filter {
            scope.allowsItem(createdAt: $0.task.createdAt, notebookIDs: [$0.task.notebookID])
        }
    }

    @ViewBuilder
    private var content: some View {
        if let message = runner.lastLoadErrorMessage {
            ContentUnavailableView {
                Label("Tasks could not be loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        } else if visibleDetails.isEmpty {
            ContentUnavailableView {
                Label("No scheduled tasks", systemImage: "clock.arrow.circlepath")
            } actions: {
                Button("New Task in Chat") {
                    vm.requestNewScheduledTaskChat()
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleDetails) { detail in
                        ScheduledTaskRow(
                            detail: detail,
                            notebookTitle: detail.task.notebookID.flatMap { vm.notebook(id: $0)?.title },
                            isRunning: runner.isRunning(taskID: detail.task.id),
                            isExpanded: expandedTaskIDs.contains(detail.task.id),
                            onToggleExpanded: { toggleExpanded(detail.task.id) },
                            onEdit: { editingTask = detail.task },
                            onRunNow: { await perform { try await runner.runNow(taskID: detail.task.id) } },
                            onSetEnabled: { enabled in
                                await perform { try await runner.setEnabled(enabled, taskID: detail.task.id) }
                            },
                            onDelete: { await perform { try await runner.delete(taskID: detail.task.id) } },
                            onOpenChat: { vm.requestResumeReviewSession($0) }
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func toggleExpanded(_ taskID: String) {
        if expandedTaskIDs.contains(taskID) {
            expandedTaskIDs.remove(taskID)
        } else {
            expandedTaskIDs.insert(taskID)
        }
    }

    /// Storage and AI failures are shown, never swallowed. A task the learner
    /// believes they disabled and which then runs anyway is the exact failure
    /// this surface exists to prevent.
    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct ScheduledTaskRow: View {
    let detail: ScheduledTaskDetail
    let notebookTitle: String?
    let isRunning: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onEdit: () -> Void
    let onRunNow: () async -> Void
    let onSetEnabled: (Bool) async -> Void
    let onDelete: () async -> Void
    let onOpenChat: (String) -> Void

    @State private var isHovered = false
    @State private var isConfirmingDelete = false

    private var task: ScheduledTask { detail.task }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, 12)
                runList
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous)
                .fill(StudioDesign.selectionFill(isSelected: false, isHovered: isHovered))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Run Now") { Task { await onRunNow() } }
            Button("Edit…") { onEdit() }
            Button(task.isEnabled ? "Pause" : "Resume") {
                Task { await onSetEnabled(!task.isEnabled) }
            }
            Divider()
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
        }
        .confirmationDialog(
            "Delete “\(task.title)”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await onDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats it already produced are kept.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .accessibilityLabel(isExpanded ? "Hide runs" : "Show runs")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .zoomedSystemFont(size: 13, weight: .semibold)
                        .lineLimit(1)
                    if let notebookTitle {
                        Text(notebookTitle)
                            .zoomedSystemFont(size: 10, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.07))
                            )
                    }
                }
                Text(subtitle)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isRunning {
                ProgressView().controlSize(.small)
            } else if let latest = detail.runs.first, latest.status != .succeeded {
                if task.isEnabled, latest.isAwaitingRetry, let retryAt = latest.retryAt {
                    Text("Retrying at \(Self.clock.string(from: retryAt))")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(Color.orange)
                        .monospacedDigit()
                } else {
                    Text(latest.status.displayName)
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(latest.status == .failed ? Color.red : Color.secondary)
                }
            }

            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { newValue in Task { await onSetEnabled(newValue) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(task.isEnabled ? "Pause this task" : "Resume this task")
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
    }

    /// Cadence plus the one fact the learner actually looks for: when next.
    private var subtitle: String {
        var parts = [task.scheduleSummary]
        if !task.isEnabled {
            parts.append("paused")
        } else if let next = task.upcomingOccurrence() {
            parts.append("next \(Self.relative.localizedString(for: next, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var runList: some View {
        if detail.runs.isEmpty {
            Text("No runs yet.")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.runs) { run in
                    HStack(spacing: 8) {
                        Text(Self.timestamp.string(from: run.occurrenceAt))
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(run.status.displayName)
                            .zoomedSystemFont(size: 11, weight: .medium)
                            .foregroundStyle(run.status == .failed ? Color.red : Color.secondary)
                        if let tries = tryDetail(run) {
                            Text(tries)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let message = run.message, !message.isEmpty {
                            Text(message)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                // The tooltip is the whole message; a
                                // platform-hosted selectable Text must not
                                // also carry accessibility help (AGENTS.md).
                                .textSelection(.disabled)
                                .help(message)
                        }
                        Spacer(minLength: 4)
                        if let sessionID = run.sessionID {
                            Button("Open chat") { onOpenChat(sessionID) }
                                .buttonStyle(.hoverWash(tint: Color(nsColor: .linkColor)))
                                .zoomedSystemFont(size: 11)
                                .opensInOtherWindow(.chat(sessionID))
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// "3rd try", and when the next one is due while it waits.
    private func tryDetail(_ run: ScheduledTaskRun) -> String? {
        var parts: [String] = []
        if run.attempt > 1 { parts.append(ScheduledTaskRetry.ordinalTry(run.attempt)) }
        if task.isEnabled, run.isAwaitingRetry, let retryAt = run.retryAt {
            parts.append("again at \(Self.clock.string(from: retryAt))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Editor

private struct ScheduledTaskEditor: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScheduledTask
    @State private var runTime: Date
    @State private var sourceQuery = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    let onSave: (ScheduledTask) async -> Void

    init(task: ScheduledTask, onSave: @escaping (ScheduledTask) async -> Void) {
        _draft = State(initialValue: task)
        _runTime = State(
            initialValue: Calendar.current.date(
                bySettingHour: task.hour,
                minute: task.minute,
                second: 0,
                of: Date()
            ) ?? Date()
        )
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .zoomedSystemFont(size: 13)

            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.instruction)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                            .stroke(Color.primary.opacity(0.15))
                    )
            }

            scheduleControls
            notebookPicker
            sourcePicker

            if let errorMessage {
                Text(errorMessage)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scheduleControls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $draft.cadence) {
                ForEach(ScheduledTaskCadence.allCases, id: \.self) { cadence in
                    Text(cadence.displayName).tag(cadence)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            if draft.cadence.usesWeekday {
                Picker("", selection: Binding(
                    get: { draft.weekday ?? 2 },
                    set: { draft.weekday = $0 }
                )) {
                    ForEach(1...7, id: \.self) { index in
                        Text(Calendar.current.weekdaySymbols[index - 1]).tag(index)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            if draft.cadence.usesDayOfMonth {
                Picker("", selection: Binding(
                    get: { draft.dayOfMonth ?? 1 },
                    set: { draft.dayOfMonth = $0 }
                )) {
                    ForEach(1...31, id: \.self) { day in
                        Text("Day \(day)").tag(day)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            if draft.cadence == .once {
                DatePicker("", selection: Binding(
                    get: { draft.startDate ?? Date() },
                    set: { draft.startDate = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
            }

            DatePicker("", selection: $runTime, displayedComponents: .hourAndMinute)
                .labelsHidden()

            Spacer()
        }
    }

    private var notebookPicker: some View {
        NotebookPickerField(label: "Notebook", notebookID: $draft.notebookID)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Sources")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                TextField("Search to attach", text: $sourceQuery)
                    .textFieldStyle(.roundedBorder)
                    .zoomedSystemFont(size: 11)
                    .frame(maxWidth: 240)
            }

            if !attachedArticles.isEmpty {
                AttachedSourceChips(titles: attachedArticles.map(\.title)) { index in
                    draft.sourceIDs.remove(at: index)
                }
            }

            // Capped on purpose: a full library in a menu is a beachball, and a
            // learner attaching sources is looking for a specific one anyway.
            ForEach(searchResults) { article in
                Button {
                    draft.sourceIDs.append(article.id)
                    sourceQuery = ""
                } label: {
                    Text(article.title)
                        .zoomedSystemFont(size: 11)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
            }
        }
    }

    private var attachedArticles: [StudioArticle] {
        draft.sourceIDs.compactMap { vm.articlesById[$0] }
    }

    private var searchResults: [StudioArticle] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let attached = Set(draft.sourceIDs)
        return vm.activeArticles
            .filter { !attached.contains($0.id) && $0.title.localizedCaseInsensitiveContains(query) }
            .prefix(6)
            .map { $0 }
    }

    private func save() {
        var edited = draft
        let components = Calendar.current.dateComponents([.hour, .minute], from: runTime)
        edited.hour = components.hour ?? 8
        edited.minute = components.minute ?? 0
        edited.updatedAt = Date()
        isSaving = true
        Task {
            await onSave(edited)
            isSaving = false
            dismiss()
        }
    }
}

/// Removable chips for attached sources, stacked rather than wrapped: source
/// titles are long enough that one per line stays readable in a sheet.
private struct AttachedSourceChips: View {
    let titles: [String]
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 4) {
                    Text(title)
                        .zoomedSystemFont(size: 11)
                        .lineLimit(1)
                    Button {
                        onRemove(index)
                    } label: {
                        Image(systemName: "xmark")
                            .zoomedSystemFont(size: 8, weight: .semibold)
                    }
                    .buttonStyle(.hoverWash(inset: -3))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }
}
