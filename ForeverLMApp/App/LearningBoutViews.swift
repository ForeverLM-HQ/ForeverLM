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

/// What the session is for and how long it runs, asked before the clock
/// starts.
///
/// The bout's title is the learner's goal in their own words, so a session
/// is never a bare "Learning": Start stays disabled until the goal says
/// something. The length is the learner's too (product owner, 2026-10-13:
/// "we should be able to set the amount of time in minutes"): a minutes field
/// that opens on what is left of the calendar event, or on the default bout,
/// with the usual lengths one click away beside it and the time the clock
/// will stop under it. A bout run on a calendar event names the event above
/// the question for context, but the goal is still the learner's to write.
struct LearningBoutStartSheet: View {
    let request: BoutStartRequest
    /// Starts the bout with the goal and its minutes, and reports whether it
    /// started.
    let onStart: (String, Int) async -> Bool
    let onCancel: () -> Void

    @Environment(\.uiZoomScale) private var uiZoomScale
    @State private var goal = ""
    @State private var minutesText: String
    @State private var isStarting = false
    @FocusState private var focus: Field?

    private enum Field { case goal, minutes }

    /// The lengths one click away: a short sitting, the Pomodoro's
    /// twenty-five, and up to the ninety-minute block the method asks for.
    nonisolated static let presetMinutes = [15, 25, 45, 60, 90]

    init(
        request: BoutStartRequest,
        onStart: @escaping (String, Int) async -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onStart = onStart
        self.onCancel = onCancel
        _minutesText = State(initialValue: String(LearningBout.clampedMinutes(request.minutes)))
    }

    private var trimmedGoal: String {
        goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var minutes: Int? { Self.minutes(from: minutesText) }

    private var canStart: Bool { !trimmedGoal.isEmpty && minutes != nil && !isStarting }

    /// One height for the minutes field and the lengths beside it.
    private var lengthRowHeight: CGFloat { 30 * uiZoomScale }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
                header
                goalField
            }
            lengthSection
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Timer", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .controlSize(.large)
        }
        .padding(StudioDesign.Spacing.xLarge)
        .frame(width: 360 * uiZoomScale)
        .onAppear { focus = .goal }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.bout.start")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
            if let eventTitle = request.eventTitle {
                Label(Self.eventLine(title: eventTitle, minutesLeft: request.minutes), systemImage: "calendar")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Text("What is this session for?")
                .zoomedSystemFont(size: 15, weight: .semibold)
        }
        .textSelection(.disabled)
    }

    private var goalField: some View {
        TextField("Goal", text: $goal, prompt: Text("e.g. Explain how ATP synthase turns"))
            .textFieldStyle(.plain)
            .zoomedSystemFont(size: 14)
            .focused($focus, equals: .goal)
            .focusEffectDisabled()
            .onSubmit(start)
            .padding(.horizontal, StudioDesign.Spacing.medium)
            .padding(.vertical, 10)
            .boutStartWell(isFocused: focus == .goal)
            .accessibilityLabel("Goal")
    }

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            Text("How long")
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            HStack(spacing: StudioDesign.Spacing.small) {
                minutesField
                Text("min")
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                Spacer(minLength: StudioDesign.Spacing.small)
                HStack(spacing: StudioDesign.Spacing.xSmall) {
                    ForEach(Self.presetMinutes, id: \.self) { preset in
                        presetButton(preset)
                    }
                }
            }
            // The stop time moves with the clock while the sheet is open.
            TimelineView(.everyMinute) { context in
                Text(Self.lengthLine(minutes: minutes, now: context.date))
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .textSelection(.disabled)
        }
    }

    private var minutesField: some View {
        TextField("Minutes", text: $minutesText)
            .textFieldStyle(.plain)
            .zoomedSystemFont(size: 14, weight: .semibold)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .focused($focus, equals: .minutes)
            .focusEffectDisabled()
            .onSubmit(start)
            // Digits only, three at most: a bout tops out at eight hours.
            .onChange(of: minutesText) { _, text in
                let digits = String(text.filter { ("0"..."9").contains($0) }.prefix(3))
                if digits != text { minutesText = digits }
            }
            .frame(width: 48 * uiZoomScale, height: lengthRowHeight)
            .boutStartWell(isFocused: focus == .minutes)
            .accessibilityLabel("Minutes")
    }

    private func presetButton(_ preset: Int) -> some View {
        let isSelected = minutes == preset
        return Button {
            minutesText = String(preset)
        } label: {
            Text("\(preset)")
                .zoomedSystemFont(size: 12, weight: isSelected ? .semibold : .medium)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(minWidth: 30 * uiZoomScale, minHeight: lengthRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.09 : 0))
                )
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.05))
        .help("\(preset) minutes")
        .accessibilityLabel("\(preset) minutes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func start() {
        guard canStart, let minutes else { return }
        isStarting = true
        Task {
            let started = await onStart(trimmedGoal, minutes)
            isStarting = false
            if started { onCancel() }
        }
    }

    // MARK: Wording

    /// The minutes typed, when they make a bout: nil for nothing, and for a
    /// length outside what a bout can be, which keeps Start off rather than
    /// quietly starting a different clock than the one typed.
    nonisolated static func minutes(from text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              (LearningBout.minimumMinutes...LearningBout.maximumMinutes).contains(value) else { return nil }
        return value
    }

    /// "Open Office hours · 25m left": the event the bout runs on.
    nonisolated static func eventLine(title: String, minutesLeft: Int) -> String {
        guard minutesLeft > 1 else { return "\(title) · ending" }
        return "\(title) · \(DayNow.durationText(minutesLeft)) left"
    }

    /// "Ends at 11:25 · earns a 5 min break" under the length, or what a
    /// length can be when the field holds none.
    nonisolated static func lengthLine(minutes: Int?, now: Date, calendar: Calendar = .current) -> String {
        guard let minutes else {
            return "A session runs \(LearningBout.minimumMinutes) to \(LearningBout.maximumMinutes) minutes"
        }
        let ends = DayNow.clockString(now.addingTimeInterval(TimeInterval(minutes * 60)), calendar: calendar)
        let rest = LearningBout.earnedBreakMinutes(forMinutesLearned: minutes)
        return "Ends at \(ends) · earns a \(rest) min break"
    }
}

private extension View {
    /// The start sheet's input look: a soft grey well with no bezel, outlined
    /// while it has the keyboard.
    func boutStartWell(isFocused: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.surface, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused ? 0.22 : 0))
        )
    }
}
