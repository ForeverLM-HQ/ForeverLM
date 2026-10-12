import SwiftUI

// MARK: - The bout card

/// The learner's timer, drawn as one card at the top of the Now chip's popover.
///
/// One card covers the whole loop, because at any moment there is exactly one
/// thing the learner is being asked for: the clock while a bout runs, the
/// write-up once it stops, the break once the write-up is saved. See
/// planner-design.md, "A bout on the clock".
struct LearningBoutCard: View {
    let bout: LearningBout
    /// The pane's clock, read so the card redraws on the half-minute tick —
    /// the countdowns draw themselves, but "over" and "break over" do not.
    let now: Date
    let onEnd: () -> Void
    let onWriteUp: () -> Void
    let onStartBreak: () -> Void
    let onEndBreak: () -> Void
    let onAbandon: () -> Void

    private var phase: LearningBoutPhase { bout.phase(now: now) }

    private var tint: Color {
        switch phase {
        case .learning: return bout.isOverrunning(now: now) ? .orange : .accentColor
        case .writing: return .orange
        case .earned, .resting: return .green
        case .complete, .abandoned: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            header
            clock
            controls
        }
        .padding(StudioDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .textSelection(.disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(phase.displayName): \(bout.title)")
        .accessibilityIdentifier("studio.bout")
    }

    private var header: some View {
        Label(headerText, systemImage: headerIcon)
            .zoomedSystemFont(size: 12, weight: .semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private var headerText: String {
        switch phase {
        case .learning: return bout.isOverrunning(now: now) ? "Running over" : "Learning"
        case .writing: return "Write it up"
        case .earned: return "Break earned"
        case .resting: return "Break"
        case .complete: return "Done"
        case .abandoned: return "Let go"
        }
    }

    private var headerIcon: String {
        switch phase {
        case .learning: return "timer"
        case .writing: return "square.and.pencil"
        case .earned, .resting: return "cup.and.saucer"
        case .complete: return "checkmark.circle"
        case .abandoned: return "xmark.circle"
        }
    }

    /// The numbers. A countdown that is still running draws itself — SwiftUI
    /// ticks `Text(timerInterval:)` without the pane republishing once a
    /// second — and a clock that has run out is static text on the pane's own
    /// half-minute tick.
    @ViewBuilder
    private var clock: some View {
        switch phase {
        case .learning:
            VStack(alignment: .leading, spacing: 1) {
                if bout.isOverrunning(now: now) {
                    Text(Self.overrunText(bout: bout, now: now))
                        .zoomedSystemFont(size: 22, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                } else {
                    Text(timerInterval: bout.startedAt...bout.timerEndsAt, countsDown: true)
                        .zoomedSystemFont(size: 22, weight: .semibold)
                        .monospacedDigit()
                }
                Text(bout.title)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(2)
            }
        case .writing, .earned:
            VStack(alignment: .leading, spacing: 1) {
                Text(bout.title)
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                Text(Self.learnedSummary(bout: bout, now: now))
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .resting:
            VStack(alignment: .leading, spacing: 1) {
                if let endsAt = bout.breakEndsAt, now < endsAt {
                    Text(timerInterval: (bout.breakStartedAt ?? bout.startedAt)...endsAt, countsDown: true)
                        .zoomedSystemFont(size: 22, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Color.green)
                } else {
                    Text("Break over")
                        .zoomedSystemFont(size: 18, weight: .semibold)
                        .foregroundStyle(Color.green)
                }
                Text("Earned by “\(bout.title)”")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .complete, .abandoned:
            Text(bout.title)
                .zoomedSystemFont(size: 13, weight: .semibold)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .learning:
            HStack(spacing: StudioDesign.Spacing.small) {
                boutButton("Write it up", icon: "square.and.pencil", action: onWriteUp)
                Menu {
                    Button("Stop the clock", action: onEnd)
                    Button("End without writing up", role: .destructive, action: onAbandon)
                } label: {
                    Image(systemName: "ellipsis")
                        .zoomedSystemFont(size: 11)
                        .padding(.horizontal, StudioDesign.Spacing.xSmall)
                        .padding(.vertical, 2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight(cornerRadius: StudioDesign.Radius.control, opacity: 0.12)
                .accessibilityLabel("More bout actions")
            }
        case .writing:
            HStack(spacing: StudioDesign.Spacing.small) {
                boutButton("Write it up", icon: "square.and.pencil", action: onWriteUp)
                boutButton("Let it go", icon: "xmark", action: onAbandon)
            }
        case .earned:
            HStack(spacing: StudioDesign.Spacing.small) {
                boutButton("Take \(bout.breakMinutes) min", icon: "cup.and.saucer", action: onStartBreak)
                boutButton("Skip it", icon: "arrow.uturn.left", action: onEndBreak)
            }
        case .resting:
            boutButton("Back to work", icon: "arrow.uturn.left", action: onEndBreak)
        case .complete, .abandoned:
            EmptyView()
        }
    }

    private func boutButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .zoomedSystemFont(size: 11, weight: .medium)
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.vertical, StudioDesign.Spacing.xSmall)
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.16))
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .fill(tint.opacity(0.16))
        )
    }

    // MARK: Wording

    /// How far a bout has run past the clock it was given. Pure and pinned by a
    /// test.
    nonisolated static func overrunText(bout: LearningBout, now: Date) -> String {
        let over = max(0, -bout.remainingSeconds(now: now))
        let minutes = over / 60
        if minutes < 60 { return "\(minutes)m over" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h over" : "\(hours)h \(rest)m over"
    }

    /// The line under a stopped bout: how long it ran, and what it has earned.
    nonisolated static func learnedSummary(bout: LearningBout, now: Date = Date()) -> String {
        let minutes = bout.minutesLearned(now: now)
        let earned = bout.writtenAt == nil
            ? LearningBout.earnedBreakMinutes(forMinutesLearned: minutes)
            : bout.breakMinutes
        return "\(minutes) min learned · \(earned) min break waiting"
    }
}

// MARK: - The write-up

/// What the bout produced, and what it did not.
///
/// Two fields, because they are two different things and the second is the one
/// worth having: what you learned is the record, what you still do not
/// understand is the next bout's subject. Saving is what earns the break, so
/// Save is disabled until the first field says something.
struct LearningBoutWriteUpSheet: View {
    let bout: LearningBout
    /// Saves the write-up and returns the bout as it stands afterwards.
    let onSave: (String, String) async -> Bool
    let onCancel: () -> Void

    @State private var learned: String
    @State private var unclear: String
    @State private var isSaving = false
    @FocusState private var focus: Field?

    private enum Field { case learned, unclear }

    init(
        bout: LearningBout,
        onSave: @escaping (String, String) async -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.bout = bout
        self.onSave = onSave
        self.onCancel = onCancel
        _learned = State(initialValue: bout.learned ?? "")
        _unclear = State(initialValue: bout.unclear ?? "")
    }

    private var canSave: Bool {
        LearningBout.isWriteUpComplete(learned: learned) && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bout.title)
                    .zoomedSystemFont(size: 15, weight: .semibold)
                    .lineLimit(2)
                Text(LearningBoutCard.learnedSummary(bout: bout))
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.disabled)
            }
            field("What you learned", text: $learned, focus: .learned)
            field("What you don’t understand yet", text: $unclear, focus: .unclear)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save and earn the break") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(StudioDesign.Spacing.large)
        .frame(width: 440)
        .onAppear { focus = .learned }
        // A group of its own: on a plain container the identifier landed on
        // both fields and both buttons.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.bout.writeup")
    }

    private func field(_ title: String, text: Binding<String>, focus field: Field) -> some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
            Text(title)
                .zoomedSystemFont(size: 12, weight: .medium)
                .textSelection(.disabled)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 84, maxHeight: 140)
                .focused($focus, equals: field)
                .padding(StudioDesign.Spacing.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            let saved = await onSave(learned, unclear)
            isSaving = false
            if saved { onCancel() }
        }
    }
}

// MARK: - The goal

/// What the session is for, asked before the clock starts.
///
/// The bout's title is the learner's goal in their own words, so a session
/// is never a bare "Learning": Start stays disabled until the goal says
/// something. A bout run on a calendar event names the event above the field
/// for context, but the goal is still the learner's to write.
struct LearningBoutStartSheet: View {
    let request: BoutStartRequest
    /// Starts the bout with the goal and reports whether it started.
    let onStart: (String) async -> Bool
    let onCancel: () -> Void

    @State private var goal = ""
    @State private var isStarting = false
    @FocusState private var focused: Bool

    private var trimmedGoal: String {
        goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool { !trimmedGoal.isEmpty && !isStarting }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What is this session for?")
                    .zoomedSystemFont(size: 15, weight: .semibold)
                Text(subtitle)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            .textSelection(.disabled)
            TextField("Goal", text: $goal, prompt: Text("e.g. Explain how ATP synthase turns"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(start)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Timer", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(StudioDesign.Spacing.large)
        .frame(width: 440)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.bout.start")
    }

    private var subtitle: String {
        let length = DayNow.durationText(LearningBout.clampedMinutes(request.minutes))
        if let eventTitle = request.eventTitle { return "\(length) on “\(eventTitle)”" }
        return "\(length) on the clock"
    }

    private func start() {
        guard canStart else { return }
        isStarting = true
        Task {
            let started = await onStart(trimmedGoal)
            isStarting = false
            if started { onCancel() }
        }
    }
}
