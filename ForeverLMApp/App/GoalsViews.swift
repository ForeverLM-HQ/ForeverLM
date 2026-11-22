import SwiftUI
import UniformTypeIdentifiers

/// Deadline state, drawn only while it asks for something: a Goal overdue,
/// due within three days, or finished. Any other Goal reads by its date
/// alone (product owner, 2026-10-06: "make the app more slick; kind of like the
/// chatgpt app … fewer buttons and bells and whistles"): a "12 days left"
/// capsule would only repeat the date.
/// Overdue is deliberately distinct from done: a passed deadline with the
/// work still open is late, not finished.
struct GoalStatusBadge: View {
    let goal: LearningGoalRecord
    /// Screen record mode (admin only) films no warning labels, so an overdue
    /// Goal reads by its date instead of in red.
    @AppStorage(Prefs.Lifecycle.screenRecordEnabled) private var screenRecordOn
    @AppStorage(Prefs.Lifecycle.screenRecordConfirmedAdmin) private var screenRecordAdmin

    /// What the badge says, or nil when the date says enough.
    /// `filmsNoWarnings` is Screen record mode: an overdue Goal then reads
    /// by its date alone.
    static func descriptor(
        for goal: LearningGoalRecord,
        asOf now: Date = Date(),
        calendar: Calendar = .current,
        filmsNoWarnings: Bool = false
    ) -> (text: String, color: Color, icon: String)? {
        if goal.isArchived { return ("Archived", .secondary, "archivebox") }
        if goal.isDone { return ("Done", .green, "checkmark.circle.fill") }
        guard let days = goal.daysRemaining(asOf: now, calendar: calendar) else { return nil }
        if days < 0 {
            guard !filmsNoWarnings else { return nil }
            let late = abs(days)
            return ("Overdue by \(late) day\(late == 1 ? "" : "s")", .red, "exclamationmark.triangle.fill")
        }
        if days == 0 { return ("Due today", .orange, "clock.fill") }
        if days <= 3 { return ("\(days) day\(days == 1 ? "" : "s") left", .orange, "clock") }
        return nil
    }

    var body: some View {
        if let state = Self.descriptor(
            for: goal,
            filmsNoWarnings: ScreenRecordMode.isForcedByBuild || (screenRecordOn && screenRecordAdmin)
        ) {
            Label(state.text, systemImage: state.icon)
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(state.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(state.color.opacity(0.12))
                )
        }
    }
}

// MARK: - Changing a deadline

/// The popover on a Goal's date (product owner, 2026-09-20: "pls let me change the
/// timeline for each goal"): the answers **Set a goal** offers — the coming
/// Sunday, two weeks out, or a day picked on a calendar — for a Goal that
/// already exists. The deadline is what makes a Goal (goals-design.md), so it
/// is changed on the row where it is read, and an assistant's
/// `update_learning_goal` with `end_date` is the same move.
struct GoalDeadlinePopover: View {
    let goal: LearningGoalRecord
    let onChoose: (Date) -> Void

    @State private var picked: Date

    init(goal: LearningGoalRecord, onChoose: @escaping (Date) -> Void) {
        self.goal = goal
        self.onChoose = onChoose
        // An overdue Goal's date is behind the calendar's first pickable day;
        // start it on tomorrow so the picker and the line under it agree.
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        _picked = State(initialValue: max(calendar.startOfDay(for: goal.endAt), tomorrow))
    }

    /// The coming Sunday, today never counting as it: the end of the week the
    /// learner is in, as the sheet reckons it.
    static func comingSunday(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.nextDate(after: today, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime)
            ?? calendar.date(byAdding: .day, value: 7, to: today) ?? today
    }

    static func fortnight(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 14, to: today) ?? today
    }

    /// Tomorrow: a deadline is a day still to come.
    private var minimumDeadline: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    private var isUnchanged: Bool {
        Calendar.current.isDate(picked, inSameDayAs: goal.endAt)
    }

    /// "Sunday 27 September · 7 days", the day said in full.
    private var pickedDetail: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: picked)).day ?? 0
        let date = picked.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return "\(date) · \(days) day\(days == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
            Text("Due by")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: StudioDesign.Spacing.small) {
                chip("Sunday", Self.comingSunday())
                chip("In two weeks", Self.fortnight())
            }
            DatePicker("Deadline", selection: $picked, in: minimumDeadline..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityIdentifier("studio.goals.deadline.date")
            Text(pickedDetail)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
            HStack {
                Spacer(minLength: 0)
                Button("Set deadline") { onChoose(picked) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUnchanged || picked < minimumDeadline)
                    .accessibilityIdentifier("studio.goals.deadline.set")
            }
        }
        .padding(StudioDesign.Spacing.large)
        .frame(width: 300)
    }

    private func chip(_ label: String, _ date: Date) -> some View {
        let selected = Calendar.current.isDate(picked, inSameDayAs: date)
        return Button {
            picked = date
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
}

// MARK: - The Goals tab

/// The Goals tab: everything the learner wants to be true by a date, in one
/// list, nearest deadline first.
///
/// A Goal is the thing someone says out loud — "I want to understand Zara's
/// thesis work" — so it lives at the top level rather than inside a Notebook.
/// A Notebook is a pool of sources, which a Goal may or may not draw on; here
/// it is a tag on the row and nothing more (goals-design.md). The chat lists
/// and sets Goals (`list_goals`, `create_learning_goal`; product owner,
/// 2026-10-10: "goals can perhaps just be visible via chat"), and this pane
/// opens only where a Goal is linked from: an Idea it grew from (`openIdeaLink`).
struct GoalsPane: View {
    var body: some View {
        GoalsHomeView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .studioCenterTabCloseChrome(for: .goals)
    }
}

struct GoalsHomeView: View {
    @Environment(StudioViewModel.self) private var vm

    /// On a list's page in the Space (`SpaceListPage`): the Space draws the
    /// title, the search and the scrolling, so the goals come without a
    /// scroll view of their own.
    let isEmbedded: Bool
    /// The Space's search: the goals whose words match.
    let query: String
    /// The goals a list holds; nil keeps every one.
    let admits: ((LearningGoalRecord) -> Bool)?

    @State private var isSettingGoal = false
    /// The tab's own search, when the list is not embedded.
    @State private var ownQuery = ""

    init(
        isEmbedded: Bool = false,
        query: String = "",
        admits: ((LearningGoalRecord) -> Bool)? = nil
    ) {
        self.isEmbedded = isEmbedded
        self.query = query
        self.admits = admits
    }

    var body: some View {
        Group {
            if isEmbedded {
                list
            } else {
                ScrollView {
                    list
                        .spacePlaceColumn()
                }
            }
        }
        .task {
            await vm.loadLearningGoals()
            // A row resolves the artifact its Goal is for from the loaded
            // library, which the Docs home may not have asked for yet.
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
            await vm.loadResearchDirections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchDirectionsDidChange)) { _ in
            Task { await vm.loadResearchDirections() }
        }
        .sheet(isPresented: $isSettingGoal) {
            SetGoalSheet { title, deadline, notebookID, artifactID in
                Task {
                    await vm.createGoal(title: title, deadline: deadline, notebookID: notebookID, artifactID: artifactID)
                }
            }
        }
    }

    /// The bands, kept to what the search and the list admit.
    private var bands: (inFlight: [LearningGoalRecord], later: [LearningGoalRecord], done: [LearningGoalRecord]) {
        let bands = vm.goalBands()
        let words = (isEmbedded ? query : ownQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || admits != nil else { return bands }
        let admits = admits
        let keeps: (LearningGoalRecord) -> Bool = {
            (words.isEmpty || $0.title.localizedCaseInsensitiveContains(words)) && (admits?($0) ?? true)
        }
        return (bands.inFlight.filter(keeps), bands.later.filter(keeps), bands.done.filter(keeps))
    }

    private var list: some View {
        let bands = bands

        return VStack(alignment: .leading, spacing: StudioDesign.Spacing.xLarge) {
            if !isEmbedded {
                header
            }

            if bands.inFlight.isEmpty && bands.later.isEmpty && bands.done.isEmpty {
                empty
            } else {
                band("In flight", bands.inFlight)
                band("Later", bands.later)
                doneBand(bands.done)
            }
        }
    }

    /// The Space's head (`SpacePlaceHeader`), as every list of the learner's
    /// things has: the name, the search and the one New Goal pill. On a list's
    /// page the Space draws all three, its pill being Add Goals ▾
    /// (`SpaceListAddMenu`), so the embedded list has no head. No line
    /// says what a Goal is (product owner, 2026-10-06: "cleaner and fewer
    /// buttons and bells and whistles").
    private var header: some View {
        SpacePlaceHeader(searchText: $ownQuery, searchIdentifier: "studio.goals.search") {
            SpacePlaceTitle(title: "Goals")
        } actions: {
            SpaceDarkPillButton(title: "New Goal", systemImage: nil, image: nil) {
                isSettingGoal = true
            }
            .accessibilityIdentifier("studio.goals.set")
        }
    }

    /// The Space's empty line (`SpaceEmptyLine`).
    private var empty: some View {
        let words = (isEmbedded ? query : ownQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        return SpaceEmptyLine(
            systemImage: words.isEmpty ? "target" : "magnifyingglass",
            text: words.isEmpty ? "No goals yet" : "No results for “\(words)”"
        )
        .frame(maxWidth: .infinity)
        .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
        .padding(.bottom, 32)
        .accessibilityIdentifier("studio.goals.empty")
    }

    /// A band of open Goals. The rows reorder by drag (product owner, 2026-09-20:
    /// "allow me to reshuffle these"): a row dropped on a row takes its
    /// place, and the context menu moves a row one step for a keyboard or
    /// an assistant. The way back to deadline order is the row menu's
    /// **Sort Goals by Deadline**.
    @ViewBuilder
    private func band(_ title: String, _ goals: [LearningGoalRecord]) -> some View {
        if !goals.isEmpty {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text(title)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(goals) { goal in
                    GoalRow(goal: goal)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: goals.map(\.id))
        }
    }

    /// Finished work, as one quiet line of titles rather than a third stack of
    /// cards: it is there to be seen, not to be worked on.
    @ViewBuilder
    private func doneBand(_ goals: [LearningGoalRecord]) -> some View {
        if !goals.isEmpty {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text("Done")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(goals.prefix(8)) { goal in
                    HStack(spacing: StudioDesign.Spacing.small) {
                        Image(systemName: goal.isArchived ? "archivebox" : "checkmark.circle")
                            .foregroundStyle(.tertiary)
                        Text(goal.title)
                            .zoomedSystemFont(size: 13)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(goal.endAt.formatted(.dateTime.month(.abbreviated).day()))
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.goals.done")
        }
    }
}

/// The in-process payload of a Goal row drag: the Goal's id under
/// `UTType.studioGoal`, visible to this process only, the shape the rail's
/// Notebook drag uses.
private func goalDragProvider(for transfer: StudioGoalTransfer, title: String) -> NSItemProvider {
    let provider = NSItemProvider()
    if let data = try? JSONEncoder().encode(transfer) {
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioGoal.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = title
    return provider
}

/// One Goal: what it is, how long is left, what it draws on and what it is
/// for. The row shows no week's hours: the day is the Mac's Calendar, not
/// blocks of time drawn toward the Goal.
///
/// The row is clickable (product owner, 2026-09-19: "it might be good if goals are
/// actually clickable") and opens the Goal itself — `GoalEditorSheet`, where
/// everything the row says can be changed. The chips inside open what they
/// name: the Notebook, the sources, the Doc or Site the Goal is for. A
/// click never opens a picker asking what the Goal is for (product owner,
/// 2026-09-20: "very poorly designed"): a click on a thing opens the thing,
/// and most Goals are for no artifact at all.
struct GoalRow: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    /// Delete asks once (product owner, 2026-09-19: "please give me a way to delete
    /// goals also"). Archive is the reversible way to put a Goal away; Delete
    /// removes the record, its schedule tags and its pool, and no more.
    @State private var isConfirmingDelete = false
    /// The Goal, opened: what a click on the row does.
    @State private var isEditing = false
    /// The popover that lists the Goal's sources (product owner, 2026-09-19: "make
    /// sure i can click sources here and they can be listed").
    @State private var isListingSources = false
    /// The popover that lists the chats filed under the Goal (product owner,
    /// 2026-09-20: "if there is already clearly related chats then those
    /// should be linked").
    @State private var isListingChats = false
    /// The popover on the date (product owner, 2026-09-20: "pls let me change the
    /// timeline for each goal").
    @State private var isChangingDeadline = false
    @State private var isHovering = false
    /// The row takes a source drop (product owner, 2026-09-19: "allow me to drag
    /// sources onto goals"): the same payloads a Notebook row takes, put on
    /// the Goal's pool. Lit while a source drag is in flight, the way the
    /// Notebook rows are, so the target is visible before the drop.
    @State private var isTargeted = false
    private let dragVisibility = StudioDragVisibility.shared

    private var notebook: LearningGoalRecord? {
        goal.parentNotebookID.flatMap { vm.notebook(id: $0) }
    }

    /// Finished work takes no sources; an open Goal takes a source it does
    /// not already have.
    private var canAcceptCurrentDrag: Bool {
        !(goal.isDone || goal.isArchived) && notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: dragVisibility)
    }

    private var isOpen: Bool { !(goal.isDone || goal.isArchived) }

    /// Another open row is being dragged over the list, so this row is a
    /// place it can take rather than a pool a source can join.
    private var isGoalDragTarget: Bool {
        guard isOpen, let dragged = dragVisibility.draggedGoalID else { return false }
        return dragged != goal.id
    }

    /// Where the dragged row would land relative to this one: a drag from
    /// above takes this row's place, so the line is drawn under it; a drag
    /// from below lands before it, so the line goes above. The same rule
    /// `StudioViewModel.reorderGoals` applies.
    private var insertionEdge: Edge {
        let ids = vm.allGoals.filter { !$0.isDone && !$0.isArchived }.map(\.id)
        guard let dragged = dragVisibility.draggedGoalID,
              let from = ids.firstIndex(of: dragged),
              let here = ids.firstIndex(of: goal.id) else { return .top }
        return from < here ? .bottom : .top
    }

    /// How many sources are on the Goal, in words; nothing when none, so a
    /// Goal that is an outcome rather than a reading list is not nagged.
    private var sourcesText: String? {
        let count = goal.approvedSourceIDs.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 source" : "\(count) sources"
    }

    /// How many chats are filed under the Goal, in words; nothing when none.
    private var chatsText: String? {
        let count = vm.reviewSessions(forGoal: goal.id).count
        guard count > 0 else { return nil }
        return GoalChatListing.heading(count: count)
    }

    /// The artifact the Goal is for, when it names one that is still here.
    private var artifact: ArtifactRecord? {
        vm.goalArtifact(goal)
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudioDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text(goal.title)
                    .zoomedSystemFont(size: 15)
                    .fixedSize(horizontal: false, vertical: true)

                // Whole chips wrap to a second line when the row is narrow; an
                // HStack squeezed them instead, and "Bioelectricity" broke into
                // one syllable a line.
                FlowLayout(spacing: StudioDesign.Spacing.medium) {
                    if let sourcesText {
                        Button {
                            isListingSources.toggle()
                        } label: {
                            Label(sourcesText, systemImage: "doc.text")
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash)
                        .help("List the sources on this goal")
                        .accessibilityIdentifier("studio.goals.row.sources")
                        .popover(isPresented: $isListingSources, arrowEdge: .bottom) {
                            GoalSourcesPopover(goal: goal) { isListingSources = false }
                        }
                    }
                    if let chatsText {
                        Button {
                            isListingChats.toggle()
                        } label: {
                            Label(chatsText, systemImage: "bubble.left.and.bubble.right")
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash)
                        .help("List the chats about this goal")
                        .accessibilityIdentifier("studio.goals.row.chats")
                        .popover(isPresented: $isListingChats, arrowEdge: .bottom) {
                            GoalChatsPopover(goal: goal) { isListingChats = false }
                        }
                    }
                    DirectionsChip(homeKind: goal.isNotebook ? .notebook : .goal, homeID: goal.id, homeTitle: goal.title) {
                        vm.requestDirectionSearch(forGoal: goal)
                    }
                    if let notebook {
                        Button {
                            vm.openNotebookInReader(notebook.id)
                        } label: {
                            Label(notebook.title, systemImage: "tray.full")
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash)
                        .opensInOtherWindow(.notebook(notebook.id))
                        .help("Open \(notebook.title)")
                    }
                    artifactChip
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: StudioDesign.Spacing.xSmall) {
                // Only while it asks for something: overdue or due within
                // three days. Otherwise the date below says it.
                GoalStatusBadge(goal: goal)
                // The date is the way in to changing it: an open Goal's
                // deadline is its own, not a fact about it.
                Button {
                    isChangingDeadline = true
                } label: {
                    Text(goal.endAt.formatted(.dateTime.month(.abbreviated).day()))
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverWash)
                .disabled(!isOpen)
                .help(isOpen ? "Change the deadline" : "")
                .accessibilityIdentifier("studio.goals.row.deadline")
                .popover(isPresented: $isChangingDeadline, arrowEdge: .bottom) {
                    GoalDeadlinePopover(goal: goal) { date in
                        isChangingDeadline = false
                        Task { await vm.setGoalDeadline(goalID: goal.id, endAt: date) }
                    }
                }
            }
        }
        .padding(StudioDesign.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1)
        )
        .overlay {
            StudioDropZoneOverlay(
                isActive: isTargeted && !isGoalDragTarget,
                isVisible: canAcceptCurrentDrag,
                title: "Add to \(goal.title)",
                systemImage: "target",
                cornerRadius: 12,
                inset: 0
            )
        }
        .overlay(alignment: insertionEdge == .top ? .top : .bottom) {
            // The place a dragged row would take: one accent line on the
            // edge it lands at, drawn while that row is over this one.
            if isTargeted && isGoalDragTarget {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .padding(.horizontal, StudioDesign.Spacing.small)
                    .offset(y: insertionEdge == .top ? -(StudioDesign.Spacing.small / 2) - 1 : (StudioDesign.Spacing.small / 2) + 1)
                    .accessibilityIdentifier("studio.goals.row.insertion")
            }
        }
        .opacity(dragVisibility.draggedGoalID == goal.id ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // The chips inside are Buttons, which win over this gesture, so the
        // Notebook tag still opens the Notebook and the row opens the Goal.
        .onTapGesture { isEditing = true }
        .onDrag {
            // An open row can be picked up and put on another row's place;
            // finished work stays in its quiet line.
            guard isOpen else { return NSItemProvider() }
            StudioDragVisibility.shared.begin(goalID: goal.id)
            return goalDragProvider(for: StudioGoalTransfer(goalID: goal.id), title: goal.title)
        }
        .onDrop(of: mcpSourceContextDropTypes + [.studioGoal], isTargeted: Binding(
            get: { isTargeted },
            set: { isTargeted = $0 && (canAcceptCurrentDrag || isGoalDragTarget) }
        )) { providers in
            // Accept on the payload alone: the drag state `canAcceptCurrentDrag`
            // reads is cleared by the mouse-up monitors as the drop fires.
            StudioDragVisibility.shared.endSoon()
            guard isOpen else { return false }
            if reorderDroppedGoal(providers) { return true }
            return NotebookSourceDropHandler.handle(providers: providers, vm: vm, goalID: goal.id)
        }
        .dropTargetWatchdog($isTargeted)
        .onHover { isHovering = $0 }
        .cursor(.pointingHand)
        .contextMenu {
            Button("Edit Goal…") { isEditing = true }
            if isOpen {
                Button("Find Directions") { vm.requestDirectionSearch(forGoal: goal) }
            }
            if let artifact {
                Button("Open \(artifact.title)") { Task { await vm.openGoalArtifact(goal) } }
                OtherWindowMenuItem(.teamArtifact(artifact.id))
            } else if isOpen {
                // The row's own offer shows only under the pointer.
                Button("Link a Page or Site…") { isEditing = true }
            }
            Divider()
            if isOpen {
                Button("Change Deadline…") { isChangingDeadline = true }
                // The keyboard's and an assistant's route to the order a
                // drag makes: one step at a time, disabled at the ends.
                Button("Move Up") { Task { await vm.moveGoal(goal.id, by: -1) } }
                    .disabled(!vm.canMoveGoal(goal.id, by: -1))
                Button("Move Down") { Task { await vm.moveGoal(goal.id, by: 1) } }
                    .disabled(!vm.canMoveGoal(goal.id, by: 1))
                // The way back to deadline order, once any Goal was placed
                // by hand.
                if vm.hasHandOrderedGoals {
                    Button("Sort Goals by Deadline") { Task { await vm.sortGoalsByDeadline() } }
                        .help("Forget the order you made and read the goals nearest deadline first")
                        .accessibilityIdentifier("studio.goals.sortByDeadline")
                }
                Divider()
            }
            if goal.isDone || goal.isArchived {
                Button("Reopen") { Task { await vm.setGoalStatus(goalID: goal.id, status: .active) } }
            } else {
                Button("Mark done") { Task { await vm.setGoalStatus(goalID: goal.id, status: .done) } }
                Button("Archive") { Task { await vm.setGoalStatus(goalID: goal.id, status: .archived) } }
            }
            Divider()
            Button("Delete…", role: .destructive) { isConfirmingDelete = true }
        }
        .sheet(isPresented: $isEditing) {
            GoalEditorSheet(goal: goal)
        }
        .confirmationDialog("Delete “\(goal.title)”?", isPresented: $isConfirmingDelete) {
            Button("Delete Goal", role: .destructive) {
                Task { await vm.deleteLearningGoal(goal.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sources stay in your library, and a chat started from it stays in Chats.")
        }
        // An element of its own that contains the chips, the way an Idea's row
        // is. On a plain container the label, identifier, help and button
        // trait were stamped on every element inside, the chips included,
        // so each read as a button named for the Goal with its hint
        // ; the help is here, below the group, for that reason.
        // The row's click is its action rather than a button trait, which on
        // the group would make it a button that holds buttons and has no
        // press of its own.
        .accessibilityElement(children: .contain)
        .help("Open the goal")
        .accessibilityIdentifier("studio.goals.row")
        .accessibilityLabel("\(goal.title)\(artifact.map { ", for \($0.title)" } ?? "")")
        .accessibilityAction { isEditing = true }
    }

    /// A row dropped on this row takes its place. True when the payload was
    /// a Goal, whatever the move did, so a source handler never sees it.
    private func reorderDroppedGoal(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.studioGoal.identifier)
        }) else { return false }
        let destinationID = goal.id
        provider.loadDataRepresentation(forTypeIdentifier: UTType.studioGoal.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(StudioGoalTransfer.self, from: data) else { return }
            Task { @MainActor in
                await vm.reorderGoals(from: transfer.goalID, to: destinationID)
            }
        }
        return true
    }

    /// What the Goal is for, on the row: the artifact's title under its kind's
    /// glyph, opening it — or, quiet and tertiary, the offer to name one,
    /// which opens the Goal on the field where that is chosen. The
    /// offer shows only while the pointer is over the row, in
    /// a slot that keeps its size (the product owner: "fewer buttons and bells and
    /// whistles"); the row's menu has **Link a Page or Site…** at all times.
    @ViewBuilder
    private var artifactChip: some View {
        if let artifact {
            Button {
                Task { await vm.openGoalArtifact(goal) }
            } label: {
                Label(artifact.title, systemImage: artifact.goalRowSymbolName)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.hoverWash)
            .opensInOtherWindow(.teamArtifact(artifact.id))
            .help("Open \(artifact.title)")
            .accessibilityIdentifier("studio.goals.row.artifact")
        } else if !(goal.isDone || goal.isArchived) {
            Button {
                isEditing = true
            } label: {
                Label("Link a page or site", systemImage: "link")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.hoverWash)
            .opacity(isHovering ? 1 : 0)
            .help("Open the goal to choose the page or site it is for")
            .accessibilityIdentifier("studio.goals.row.link")
        }
    }
}

// MARK: - A Goal's sources

/// The words for a Goal's chats, on the row's chip and the popover's heading.
enum GoalChatListing {
    static func heading(count: Int) -> String {
        count == 1 ? "1 chat" : "\(count) chats"
    }
}

/// What the "3 chats" chip on a Goal row opens: the chats filed under the
/// Goal, newest first — started from its **Quiz me on it**, moved onto it
/// from the rail's menu, or filed there over MCP — each resuming in the chat
/// panel (product owner, 2026-09-20: "if there is already clearly related chats
/// then those should be linked").
struct GoalChatsPopover: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    /// Closes the popover once a row resumed its chat.
    let dismiss: () -> Void

    private var sessions: [ReviewSessionRecord] { vm.reviewSessions(forGoal: goal.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(GoalChatListing.heading(count: sessions.count))
                    .zoomedSystemFont(size: 12, weight: .semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, StudioDesign.Spacing.medium)
            .padding(.top, StudioDesign.Spacing.medium)
            .padding(.bottom, StudioDesign.Spacing.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions) { session in
                        Button {
                            dismiss()
                            vm.requestResumeReviewSession(session.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.small) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .zoomedSystemFont(size: 12)
                                        .lineLimit(2)
                                    Text(session.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                        .zoomedSystemFont(size: 11)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, StudioDesign.Spacing.small)
                            .padding(.vertical, StudioDesign.Spacing.xSmall)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash)
                        .opensInOtherWindow(.chat(session.id))
                        .help("Resume this chat")
                        .accessibilityIdentifier("studio.goals.row.chats.row")
                    }
                }
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.bottom, StudioDesign.Spacing.small)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
        // A group of its own: on a plain container the identifier landed on
        // the heading and the scroll area, and no one element was the list.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.goals.row.chats.list")
    }
}

/// What the "11 sources" chip on a Goal row opens: the Goal's pool, one row
/// per source, each opening its source in the Reader beside the Goals tab.
///
/// The rows answer the way the library does (`LibrarySourcePresence`): an archived source keeps its title and a mark,
/// a deleted one says it has left the library, because the pool holds ids and
/// an id outlives its row. Storage is asked once, for the ids the loaded
/// library cannot name, so the list is right for archived sources too.
struct GoalSourcesPopover: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    /// Closes the popover after a row opened its source: the Reader is where
    /// attention goes next, and a popover left over it would cover the tab.
    let dismiss: () -> Void

    /// Title and status for the ids the loaded library does not hold.
    @State private var storedRows: [String: SourceRowSummary] = [:]

    private var rows: [GoalSourceListing.Row] {
        GoalSourceListing.rows(
            sourceIDs: goal.approvedSourceIDs,
            activeTitle: { vm.articlesById[$0].map { vm.displayTitle(for: $0) } },
            activeType: { vm.articlesById[$0]?.sourceType },
            storedRow: { storedRows[$0] }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(GoalSourceListing.heading(count: rows.count))
                    .zoomedSystemFont(size: 12, weight: .semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, StudioDesign.Spacing.medium)
            .padding(.top, StudioDesign.Spacing.medium)
            .padding(.bottom, StudioDesign.Spacing.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        GoalSourceRow(
                            row: row,
                            source: vm.articlesById[row.id],
                            bookCoverPath: bookCoverPath(for: row.id),
                            onOpen: { open(row) }
                        )
                    }
                }
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.bottom, StudioDesign.Spacing.small)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
        .task(id: goal.approvedSourceIDs) { await loadStoredRows() }
        // A group of its own: on a plain container the identifier landed on
        // the heading and the scroll area, and no one element was the list.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.goals.row.sources.list")
    }

    /// Ask storage about every id at once — archived rows are not in the
    /// loaded library, and one query for the pool is cheaper than one per row.
    private func loadStoredRows() async {
        let unnamed = goal.approvedSourceIDs.filter { vm.articlesById[$0] == nil }
        guard !unnamed.isEmpty else {
            storedRows = [:]
            return
        }
        storedRows = await vm.loggedRead("the goal's stored sources") { try await vm.storage.sourceRowSummaries(for: unnamed) } ?? [:]
    }

    private func open(_ row: GoalSourceListing.Row) {
        guard row.presence.canOpen else { return }
        dismiss()
        Task { await vm.openLinkedSourceInReader(row.id, beside: .goals) }
    }

    /// A book chapter on the Goal shows the book's cover, not the first
    /// picture inside the chapter — the same choice every other source list
    /// makes through `bookCoverPaths`.
    private func bookCoverPath(for sourceID: String) -> String? {
        guard let source = vm.articlesById[sourceID], source.sourceType == .book,
              let bookID = source.parentGroup else { return nil }
        return vm.bookCoverPaths[bookID]
    }
}

/// One source of a Goal, in the popover: the row opens the source. Taking a
/// source off a Goal is not offered here, because no MCP tool does it yet and
/// every action the app offers has an MCP twin; the Notebook panel's ✕ is the
/// route until one exists.
///
/// The row leads with the source's picture (product owner, 2026-09-20: "show the
/// thumbnails here of the sources") — a podcast's cover, a paper's first page,
/// a video's still — the same `SourceThumbnail` every other source list draws.
/// A source the loaded library does not hold (archived or gone) has no
/// `StudioArticle` to draw from, so its kind's symbol stands in the same square.
private struct GoalSourceRow: View {
    let row: GoalSourceListing.Row
    /// The loaded source, when the library holds it; nil for an archived or
    /// deleted one, whose title and kind come from storage instead.
    let source: StudioArticle?
    let bookCoverPath: String?
    let onOpen: () -> Void

    private static let thumbnailSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: StudioDesign.Spacing.small) {
                    thumbnail
                    Text(row.presence.label)
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(row.presence.canOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        // Two lines, cut at the end if at all (product owner,
                        // 2026-09-22: a title cut in the middle read as
                        // "Targeting Elevated In...ming in Heart Failure").
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.presence.isArchived {
                        Text("Archived")
                            .zoomedSystemFont(size: 10, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0))
            .disabled(!row.presence.canOpen)
            .opensInOtherWindow(source)
            .help(row.presence.isArchived ? "Open in the Reader, which restores it from the archive" : "Open in the Reader")
            .accessibilityIdentifier("studio.goals.row.sources.source")
            .accessibilityValue(row.presence.isArchived ? "Archived" : "")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let source {
            SourceThumbnail(source: source, size: Self.thumbnailSize, bookCoverPath: bookCoverPath)
                .opacity(row.presence.canOpen ? 1 : 0.6)
        } else {
            Image(systemName: row.symbolName)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
        }
    }
}

/// The rows of a Goal's source list, worked out from the pool's ids, what the
/// loaded library says about each, and what storage says about the rest.
enum GoalSourceListing {
    struct Row: Identifiable, Equatable {
        let id: String
        let presence: LibrarySourcePresence
        /// The SF Symbol for the source's kind; the plain document when the
        /// kind is unknown, which is only so for a source that is gone.
        let symbolName: String
    }

    /// One row per distinct id, in the pool's order. A pool that carries an
    /// id twice is one source, not two lines.
    static func rows(
        sourceIDs: [String],
        activeTitle: (String) -> String?,
        activeType: (String) -> StudioSourceType?,
        storedRow: (String) -> SourceRowSummary?
    ) -> [Row] {
        var seen = Set<String>()
        return sourceIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            let stored = storedRow(id)
            let presence = LibrarySourcePresence.resolve(activeTitle: activeTitle(id), row: stored)
            let type = activeType(id) ?? stored?.type
            return Row(id: id, presence: presence, symbolName: type?.symbolName ?? "doc.text")
        }
    }

    static func heading(count: Int) -> String {
        count == 1 ? "1 source" : "\(count) sources"
    }
}

// MARK: - Setting one

/// The sheet behind every "Set a goal": one sentence, a deadline, and — below
/// a divider, optional — the Notebook whose sources it draws on and the Doc,
/// Site or animation the Goal is for.
///
/// Deliberately two decisions and a tag. The deadline is offered as named days
/// rather than a date picker that opens on today + 7: a default nobody chose is
/// how a deadline becomes fiction, and "Sunday" is what the learner would have
/// said out loud. Creating a Goal makes no AI request; it is a local write.
struct SetGoalSheet: View {
    /// Pre-tagged when the sheet is opened from inside a Notebook.
    var presetNotebookID: String?
    /// The sentence already written, when the Goal is an Idea becoming one
    /// (ideas-design.md): the field opens filled and the deadline is the
    /// decision left.
    var presetTitle: String?
    /// Title, deadline, the Notebook tag and the artifact the Goal is for.
    let create: (String, Date, String?, String?) -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var choice: DeadlineChoice = .soon
    @State private var customDeadline = Date()
    @State private var notebookID: String?
    @State private var isTagging = false
    /// The Doc, Site or animation the Goal is for, when it already exists.
    @State private var artifactID: String?
    @State private var isLinking = false
    @FocusState private var titleFocused: Bool

    /// The named deadlines, and the one that opens a date picker.
    private enum DeadlineChoice: Hashable {
        case soon
        case fortnight
        case custom
    }

    init(
        presetNotebookID: String? = nil,
        presetTitle: String? = nil,
        presetDeadline: Date? = nil,
        create: @escaping (String, Date, String?, String?) -> Void
    ) {
        self.presetNotebookID = presetNotebookID
        self.presetTitle = presetTitle
        self.create = create
        _title = State(initialValue: presetTitle ?? "")
        if let presetDeadline {
            _choice = State(initialValue: .custom)
            _customDeadline = State(initialValue: presetDeadline)
        }
        _notebookID = State(initialValue: presetNotebookID)
        _isTagging = State(initialValue: presetNotebookID != nil)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The coming Sunday — the end of the week the learner is in. Today never
    /// counts as it: a Goal set on Sunday morning means *next* Sunday.
    private var comingSunday: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let next = calendar.nextDate(
            after: today,
            matching: DateComponents(weekday: 1),
            matchingPolicy: .nextTime
        )
        return next ?? calendar.date(byAdding: .day, value: 7, to: today) ?? today
    }

    private var fortnight: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 14, to: today) ?? today
    }

    private var minimumDeadline: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    private var deadline: Date {
        switch choice {
        case .soon: return comingSunday
        case .fortnight: return fortnight
        case .custom: return Calendar.current.startOfDay(for: customDeadline)
        }
    }

    /// "Sunday 21 September · 3 days" — the chosen day said back in full, so a
    /// named day is never ambiguous about which one it meant.
    private var deadlineDetail: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: deadline
        ).day ?? 0
        let date = deadline.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return "\(date) · \(days) day\(days == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
                Text("Set a goal")
                    .zoomedSystemFont(size: 21, weight: .bold)
                Text("Something you want to be true by a date.")
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
            }

            TextField("I want to understand\u{2026}", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 15)
                .lineLimit(1...3)
                .padding(StudioDesign.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .focused($titleFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("studio.goals.sheet.title")

            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text("By")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                HStack(spacing: StudioDesign.Spacing.small) {
                    deadlineChip("Sunday", .soon)
                    deadlineChip("In two weeks", .fortnight)
                    deadlineChip("Pick a date", .custom)
                    if choice == .custom {
                        DatePicker(
                            "Deadline",
                            selection: $customDeadline,
                            in: minimumDeadline...,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("studio.goals.sheet.date")
                    }
                }
                Text(deadlineDetail)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Divider()

            notebookTag
            artifactLink

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set goal", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
                    .accessibilityIdentifier("studio.goals.sheet.create")
            }
        }
        .padding(StudioDesign.Spacing.xLarge)
        .frame(width: 460)
        .onAppear {
            customDeadline = comingSunday
            titleFocused = true
        }
        .task {
            // The link picker lists the loaded library, which a Notebook may
            // open this sheet before the Docs home has asked for.
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
        }
    }

    private func deadlineChip(_ label: String, _ value: DeadlineChoice) -> some View {
        Button {
            choice = value
        } label: {
            Text(label)
                .zoomedSystemFont(size: 12, weight: choice == value ? .medium : .regular)
                .foregroundStyle(choice == value ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .padding(.horizontal, StudioDesign.Spacing.medium)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(choice == value ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0))
    }

    /// The Notebook, below the fold and unweighted: a Goal that names none is
    /// the ordinary case, not an unfinished one.
    @ViewBuilder
    private var notebookTag: some View {
        if isTagging {
            HStack(spacing: StudioDesign.Spacing.small) {
                NotebookPickerField(label: "Notebook", notebookID: $notebookID)
                    .frame(maxWidth: 240, alignment: .leading)
                .accessibilityIdentifier("studio.goals.sheet.notebook")
                Text("Its sources come along.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Button {
                isTagging = true
            } label: {
                Label("Tag a notebook", systemImage: "plus")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash)
        }
    }

    /// The artifact the Goal is for, below the fold like the Notebook: most
    /// Goals are set before the thing exists, and the row offers the link
    /// later. Offered when there is something to choose from.
    @ViewBuilder
    private var artifactLink: some View {
        let choices = GoalArtifactChoices(vm.artifacts.filter { !vm.isAudioOverview($0) })
        if isLinking {
            HStack(spacing: StudioDesign.Spacing.small) {
                Picker("For", selection: $artifactID) {
                    Text("Nothing yet").tag(String?.none)
                    ForEach(choices.sections, id: \.section) { group in
                        Section(group.section.title) {
                            ForEach(group.records) { record in
                                Text(record.title).tag(String?.some(record.id))
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .accessibilityIdentifier("studio.goals.sheet.artifact")
                Text("The row opens it.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        } else if !choices.isEmpty {
            Button {
                isLinking = true
            } label: {
                Label("Link a page or site", systemImage: "link")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash)
            .accessibilityIdentifier("studio.goals.sheet.link")
        }
    }

    private func submit() {
        guard !trimmedTitle.isEmpty else { return }
        create(trimmedTitle, deadline, notebookID, isLinking ? artifactID : nil)
        dismiss()
    }
}

// MARK: - What a Goal is for

/// The library's Docs, Sites and animations as a Goal may be for them:
/// current records only (nothing hidden or archived), by section in the
/// rail's order, newest first within one, so the site just published is at
/// the top.
struct GoalArtifactChoices {
    struct Group {
        let section: ArtifactSection
        let records: [ArtifactRecord]
    }

    let sections: [Group]

    init(_ artifacts: [ArtifactRecord]) {
        let current = artifacts.filter { !$0.isHidden && !$0.isArchived }
        sections = ArtifactSection.allCases.compactMap { section in
            let records = current
                .filter { $0.section == section }
                .sorted { $0.updatedAt > $1.updatedAt }
            return records.isEmpty ? nil : Group(section: section, records: records)
        }
    }

    var isEmpty: Bool { sections.isEmpty }

    /// The groups with only the records whose title contains `query`,
    /// case-insensitively; every group when the query is blank.
    func matching(_ query: String) -> [Group] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { group in
            let records = group.records.filter { $0.title.localizedCaseInsensitiveContains(needle) }
            return records.isEmpty ? nil : Group(section: group.section, records: records)
        }
    }
}

extension ArtifactRecord {
    /// The glyph a Goal row uses for the artifact it is for: the linked
    /// page's own, the Animations glyph, or a document for a Markdown doc.
    var goalRowSymbolName: String {
        if kind == .animation { return ArtifactKind.animation.symbolName }
        return linkedKind?.symbolName ?? "doc.text"
    }
}
