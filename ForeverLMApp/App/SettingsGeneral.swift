import SwiftUI

/// Settings → General: your name, about you, the day's hours, the quick
/// assistant's shortcut, the daily memory review, and beta releases. Was Appearance and Memory until 2026-09-24, when
/// Settings was cut to what a learner actually changes; the thinking-mark
/// speed and the crown switch went with it and stay reachable through
/// `set_app_setting`.
struct GeneralSettingsDetailView: View {
    /// Synced: the name every client shows, edited as a draft and saved on
    /// Return or when the field loses focus, so typing is not a sync per key.
    @SyncedStorage(wrappedValue: "", MacAccountUser.displayNamePreferenceKey)
    private var savedDisplayName: String
    @State private var displayNameDraft = ""
    @FocusState private var displayNameFocused: Bool
    /// Synced: where the learner is coming from, which every course tailors
    /// to (docs/textbook-readings-design.md). A draft saved when the field
    /// loses focus, like the name.
    @SyncedStorage(wrappedValue: "", LearnerProfile.aboutYouPreferenceKey)
    private var savedAboutYou: String
    @State private var aboutYouDraft = ""
    @FocusState private var aboutYouFocused: Bool
    /// This Mac's: the card and the notification ask on this Mac.
    @AppStorage(PlanTheDay.settingKey)
    private var suggestPlanningTheDay = true
    @AppStorage(PlanTheDay.forcedKey)
    private var forcePlanningTheDay = false
    /// Synced: the learner's day is the same on every Mac.
    @AppStorage(PlannerDayHours.startKey)
    private var dayStartHour: Int = PlannerDayHours.defaultStart
    @AppStorage(PlannerDayHours.endKey)
    private var dayEndHour: Int = PlannerDayHours.defaultEnd

    @SyncedStorage(wrappedValue: MemoryReviewBudget.defaultMinutes, MemoryReviewBudget.preferenceKey)
    private var budgetMinutes: Int
    @SyncedStorage(wrappedValue: false, DailyReviewPreparation.enabledKey)
    private var prepareDaily: Bool
    @AppStorage(DailyReviewPreparation.hourKey)
    private var readyHour: Int = DailyReviewPreparation.defaultHour
    /// Synced: the day's new cards, background drafting, and the corner card.
    @SyncedStorage(wrappedValue: MemoryCardQueue.defaultNewPerDay, MemoryCardSettings.newCardsPerDayKey)
    private var newCardsPerDay: Int
    @SyncedStorage(wrappedValue: true, MemoryCardSettings.autoDraftKey)
    private var autoDraftsCards: Bool
    @SyncedStorage(wrappedValue: true, MemoryCardSettings.draftNudgesKey)
    private var showsDraftNudges: Bool
    @SyncedStorage(wrappedValue: true, MemoryCardSettings.prepareReviewQuestionsKey)
    private var preparesReviewQuestions: Bool
    /// Synced: Think first's level for the library (`ThinkFirst`), so the
    /// picker follows another Mac, the web or MCP.
    @SyncedStorage(wrappedValue: ThinkFirstLevel.off, ThinkFirst.levelKey)
    private var thinkFirstLevel: ThinkFirstLevel
    /// Synced: signed up for beta releases (`BetaReleases`), so the switch
    /// follows another Mac or MCP.
    @SyncedStorage(wrappedValue: false, BetaReleases.preferenceKey)
    private var betaReleasesSignedUp: Bool
    /// macOS's answer about ForeverLM's notifications: read when the pane
    /// appears and each time the app comes forward, since the learner may
    /// have just changed it in System Settings. Nil until it has been read.
    @State private var notificationPermission: NotificationPermission?
    @State private var isRequestingNotifications = false

    /// The one line about notifications, and the card it sits in.
    private var notificationNote: NotificationSettingsNote? {
        NotificationSettingsNote.placement(
            permission: notificationPermission,
            preparesDailyReview: prepareDaily
        )
    }

    /// The end hours the picker offers: after the chosen start, so the two
    /// pickers cannot be set into a day that ends before it begins.
    private var endHourChoices: [Int] {
        Array(max(PlannerDayHours.endHours.lowerBound, PlannerDayHours.clampStart(dayStartHour) + 1)...PlannerDayHours.endHours.upperBound)
    }

    /// "06:00" for a start, "24:00" reads as "Midnight" for the day's end.
    private static func hourLabel(_ hour: Int) -> String {
        hour == 24 ? "Midnight" : DayPlan.clockString(minute: hour * 60)
    }

    /// Saves the draft, or puts the current name back when the draft is blank
    /// or too long: an empty field is not a way to lose the name.
    private func commitDisplayName() {
        let shown = MacAccountUser.resolvedFullName(saved: savedDisplayName) ?? ""
        // Leaving the field untouched writes nothing, so opening Settings
        // never saves the macOS name, or a UI test's "Learner", as a choice.
        guard displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != shown else { return }
        if !MacAccountUser.setDisplayName(displayNameDraft) {
            displayNameDraft = shown
        }
    }

    /// Saves the draft, or puts the saved words back when it is too long.
    private func commitAboutYou() {
        guard aboutYouDraft.trimmingCharacters(in: .whitespacesAndNewlines) != LearnerProfile.aboutYou else { return }
        if !LearnerProfile.setAboutYou(aboutYouDraft) {
            aboutYouDraft = LearnerProfile.aboutYou
        }
    }

    /// Every picker and field on the right edge of a row is this wide, so the
    /// controls line up down the page instead of each ending where it likes.
    private static let controlWidth: CGFloat = 150

    private var rowDivider: some View {
        Divider().padding(.vertical, 12)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection(title: "You") {
                    SettingsCard {
                        SettingsRow("Name") {
                            TextField("Name", text: $displayNameDraft, prompt: Text(MacAccountUser.resolvedFullName(saved: savedDisplayName) ?? "Your name"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .focused($displayNameFocused)
                                .onSubmit(commitDisplayName)
                                .accessibilityIdentifier("settings.general.displayName")
                        }
                        .onAppear { displayNameDraft = MacAccountUser.resolvedFullName(saved: savedDisplayName) ?? "" }
                        .onChange(of: savedDisplayName) { _, saved in
                            // A rename from the web or a chat lands in the field
                            // unless the learner is typing in it.
                            guard !displayNameFocused else { return }
                            displayNameDraft = MacAccountUser.resolvedFullName(saved: saved) ?? ""
                        }
                        .onChange(of: displayNameFocused) { _, focused in
                            if !focused { commitDisplayName() }
                        }
                        .onDisappear(perform: commitDisplayName)

                        rowDivider

                        VStack(alignment: .leading, spacing: 8) {
                            SettingsRow("About you", detail: "Courses are tailored to it.") { EmptyView() }
                            TextField(
                                "About you",
                                text: $aboutYouDraft,
                                prompt: Text("Where you're coming from: your background, what you know well, what's new to you"),
                                axis: .vertical
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...8)
                            .focused($aboutYouFocused)
                            .accessibilityIdentifier("settings.general.aboutYou")
                        }
                        .onAppear { aboutYouDraft = LearnerProfile.aboutYou }
                        .onChange(of: savedAboutYou) { _, _ in
                            // Words written on another Mac or by a chat land here
                            // unless the learner is typing in the field.
                            guard !aboutYouFocused else { return }
                            aboutYouDraft = LearnerProfile.aboutYou
                        }
                        .onChange(of: aboutYouFocused) { _, focused in
                            if !focused { commitAboutYou() }
                        }
                        .onDisappear(perform: commitAboutYou)
                    }
                }

                SettingsSection(title: "Day") {
                    SettingsCard {
                        SettingsRow("Day starts at") {
                            Picker("Day starts at", selection: $dayStartHour) {
                                ForEach(Array(PlannerDayHours.startHours), id: \.self) { hour in
                                    Text(Self.hourLabel(hour)).tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Self.controlWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings.general.dayStart")
                            .onChange(of: dayStartHour) { _, start in
                                // The end follows a start moved past it.
                                if dayEndHour <= start { dayEndHour = min(PlannerDayHours.endHours.upperBound, start + 1) }
                            }
                        }

                        rowDivider

                        SettingsRow("Day ends at") {
                            Picker("Day ends at", selection: $dayEndHour) {
                                ForEach(endHourChoices, id: \.self) { hour in
                                    Text(Self.hourLabel(hour)).tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Self.controlWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings.general.dayEnd")
                        }

                        rowDivider

                        SettingsRow("Ask each morning to plan the day", detail: "When nothing is planned yet.") {
                            Toggle("Ask each morning to plan the day when nothing is planned", isOn: $suggestPlanningTheDay)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("settings.general.suggestPlanningTheDay")
                        }

                        rowDivider

                        SettingsRow("Make me plan", detail: "Open the planning chat, and keep asking until the day is planned.") {
                            Toggle("Make me plan: open the planning chat, and keep asking until the day is planned", isOn: $forcePlanningTheDay)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!suggestPlanningTheDay)
                                .accessibilityIdentifier("settings.general.forcePlanningTheDay")
                        }
                    }
                }

                QuickAssistantSettingsSection()

                SettingsSection(title: "Memory review") {
                    SettingsCard {
                        SettingsRow("Time each day") {
                            Picker("Time each day", selection: $budgetMinutes) {
                                ForEach(Self.budgetChoices(including: budgetMinutes), id: \.self) { minutes in
                                    Text(MemoryReviewBudget.label(minutes)).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Self.controlWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings.memory.budget")
                        }

                        rowDivider

                        SettingsRow("New cards each day") {
                            Picker("New cards each day", selection: newCardsPerDayBinding) {
                                ForEach(Self.newCardChoices(including: newCardsPerDay), id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Self.controlWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings.memory.newCardsPerDay")
                        }

                        rowDivider

                        SettingsRow("Draft cards from what you finish", detail: "Uses AI, within your daily background limit.") {
                            Toggle("Draft cards from what you finish", isOn: autoDraftsCardsBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("settings.memory.autoDraftCards")
                        }
                        .settingsFocusRow(.memoryDraftCards)

                        rowDivider

                        SettingsRow("Say when drafted cards wait") {
                            Toggle("Say when drafted cards wait", isOn: showsDraftNudgesBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("settings.memory.draftNudges")
                        }

                        rowDivider

                        SettingsRow(
                            "Prepare review questions ahead of time",
                            detail: "Uses AI on up to \(StudioViewModel.reviewGuidePrebuildDailyLimit) sources a day, "
                                + "within your daily background limit."
                        ) {
                            Toggle("Prepare review questions ahead of time", isOn: preparesReviewQuestionsBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("settings.memory.prepareReviewQuestions")
                        }
                        .settingsFocusRow(.memoryPrepareReviewQuestions)

                        rowDivider

                        SettingsRow("Have today's review ready") {
                            Toggle("Have today's review ready", isOn: $prepareDaily)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("settings.memory.prepareDaily")
                                .onChange(of: prepareDaily) { _, enabled in
                                    didChangePrepareDaily(to: enabled)
                                }
                        }

                        if let note = notificationNote, note.card == .memoryReview {
                            notificationNoteRow(note.permission)
                        }

                        if prepareDaily {
                            rowDivider

                            SettingsRow("Ready by") {
                                Picker("Ready by", selection: $readyHour) {
                                    ForEach(0..<24, id: \.self) { value in
                                        Text(DailyReviewPreparation.hourLabel(value)).tag(value)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: Self.controlWidth, alignment: .trailing)
                                .accessibilityIdentifier("settings.memory.hour")
                                .onChange(of: readyHour) { _, _ in
                                    MemoryReviewPreparationRunner.shared.scheduleRefresh()
                                    // The reminder moves to the new hour, and
                                    // only while that morning holds a card.
                                    Task { await MemoryReviewPreparationRunner.shared.refreshReminder() }
                                }
                            }
                        }
                    }
                }

                SettingsSection(title: "Think first") {
                    SettingsCard {
                        SettingsRow(
                            "Ask for your own line first",
                            detail: "Before a source's gist, a report or Find directions; Also Chat adds a notebook's chat."
                        ) {
                            Picker("Ask for your own line first", selection: $thinkFirstLevel) {
                                ForEach(ThinkFirstLevel.allCases, id: \.self) { level in
                                    Text(level.title).tag(level)
                                }
                            }
                            .labelsHidden()
                            .frame(width: Self.controlWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings.general.thinkFirst")
                        }
                    }
                }

                SettingsSection(title: "Updates") {
                    SettingsCard {
                        SettingsRow(
                            "Get beta releases",
                            detail: "Early builds and beta features, such as the Canvas, on every Mac you use."
                        ) {
                            Toggle("Get beta releases", isOn: betaReleasesBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityIdentifier("settings.general.betaReleases")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .settingsFocusHost(pane: .general)
        .navigationTitle("General")
        .task { await refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationPermission() }
        }
    }

    /// Written through `MemoryCardSettings`, so the value is clamped and
    /// syncs exactly as `set_memory_review_settings` writes it. The counts
    /// the rail and Memory show are read again.
    private var newCardsPerDayBinding: Binding<Int> {
        Binding(
            get: { MemoryCardQueue.clampNewPerDay(newCardsPerDay) },
            set: { count in
                MemoryCardSettings.setNewCardsPerDay(count)
                Task { await AppModelBridge.studio?.refreshMemoryCardCounts() }
            }
        )
    }

    private var autoDraftsCardsBinding: Binding<Bool> {
        Binding(
            get: { autoDraftsCards },
            set: {
                MemoryCardSettings.setAutoDraftsCards($0)
                Task(priority: .utility) { await AppModelBridge.studio?.refreshCardsToCheckBanner() }
            }
        )
    }

    private var preparesReviewQuestionsBinding: Binding<Bool> {
        Binding(
            get: { preparesReviewQuestions },
            set: { MemoryCardSettings.setPreparesReviewQuestions($0) }
        )
    }

    /// Written through `BetaReleases`, which `set_app_setting` uses too;
    /// `AppUpdateController` sees the change and checks the feed again.
    private var betaReleasesBinding: Binding<Bool> {
        Binding(
            get: { betaReleasesSignedUp },
            set: { BetaReleases.setSignedUp($0) }
        )
    }

    private var showsDraftNudgesBinding: Binding<Bool> {
        Binding(
            get: { showsDraftNudges },
            set: {
                MemoryCardSettings.setShowsDraftNudges($0)
                Task(priority: .utility) { await AppModelBridge.studio?.refreshCardsToCheckBanner() }
            }
        )
    }

    /// The offered allowances, plus whatever is set when MCP chose a value
    /// off the list, so the picker never shows an empty selection.
    private static func newCardChoices(including current: Int) -> [Int] {
        let clamped = MemoryCardQueue.clampNewPerDay(current)
        if MemoryCardQueue.newPerDayChoices.contains(clamped) { return MemoryCardQueue.newPerDayChoices }
        return (MemoryCardQueue.newPerDayChoices + [clamped]).sorted()
    }

    /// A refusal is a state to act on, so it is orange and carries the way
    /// out. A Mac never asked is only offered the question.
    @ViewBuilder
    private func notificationNoteRow(_ permission: NotificationPermission) -> some View {
        switch permission {
        case .refused:
            HStack(spacing: 12) {
                Label("macOS has ForeverLM's notifications turned off.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open System Settings") {
                    NotificationPermission.openSystemSettings()
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings.general.openNotificationSettings")
            }
            .padding(.top, 8)
        case .notAsked:
            Button("Allow Notifications") {
                allowNotifications()
            }
            .controlSize(.small)
            .disabled(isRequestingNotifications)
            .accessibilityIdentifier("settings.general.allowNotifications")
            .padding(.top, 8)
        case .allowed:
            EmptyView()
        }
    }

    /// Reads macOS's answer off the render path.
    private func refreshNotificationPermission() async {
        notificationPermission = await NotificationPermission.current()
    }

    /// Allow Notifications: macOS shows its prompt, and the line follows the
    /// answer, gone when allowed and Open System Settings when refused.
    private func allowNotifications() {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        Task {
            notificationPermission = await NotificationPermission.request()
            isRequestingNotifications = false
        }
    }

    /// The offered budgets, plus whatever is set when another client chose a
    /// value off the list, so the picker never shows an empty selection.
    private static func budgetChoices(including current: Int) -> [Int] {
        let clamped = MemoryReviewBudget.clamp(current)
        if MemoryReviewBudget.choices.contains(clamped) { return MemoryReviewBudget.choices }
        return (MemoryReviewBudget.choices + [clamped]).sorted()
    }

    /// The switch's side effects. Answering here is answering the in-chat
    /// offer too, and the reminder notification follows the same switch;
    /// macOS's answer to its prompt is what the notifications line reads.
    private func didChangePrepareDaily(to enabled: Bool) {
        DailyReviewPreparation.markOfferDecided()
        if enabled {
            Task {
                notificationPermission = await NotificationPermission.request()
                // Scheduled only while the next morning holds a card.
                await MemoryReviewPreparationRunner.shared.refreshReminder()
            }
        } else {
            CohortReviewNotifications.cancel()
        }
        MemoryReviewPreparationRunner.shared.scheduleRefresh()
    }
}

/// One setting in a card: the name (and a quiet line under it) on the left,
/// its control on the right edge. Every General row draws this way, so a
/// switch, a picker and a field all sit in the same column.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

/// One setting a learner can be sent to by name, from outside Settings (AI
/// Usage › Activity's Turn off…). The pane scrolls to the row and washes it.
enum SettingsRowID: String {
    case memoryDraftCards
    case memoryPrepareReviewQuestions
    case imagesQuizPictures
    case imagesNotebookCovers
    case driveTranscribeRecordings
    case youTubeFormatTranscripts

    /// The Settings pane the row is in; nil for a row on a plugin's page.
    var pane: SettingsPane? {
        switch self {
        case .memoryDraftCards, .memoryPrepareReviewQuestions: .general
        case .imagesQuizPictures, .imagesNotebookCovers: .aiImages
        case .driveTranscribeRecordings, .youTubeFormatTranscripts: nil
        }
    }

    /// The plugin page the row is on; nil for a row in Settings.
    var pluginPage: PluginPage? {
        switch self {
        case .driveTranscribeRecordings: .googleDrive
        case .youTubeFormatTranscripts: .youtube
        default: nil
        }
    }

    /// Opens the place that holds the row. The row is staged first so the
    /// page takes it as it appears.
    @MainActor
    func open(settings openSettings: (SettingsPane) -> Void) {
        let staged = SettingsFocusRequest.stage(self)
        if let page = pluginPage {
            PluginsPlace.requestOpen(page)
        } else if let pane = staged {
            openSettings(pane)
        }
    }
}

/// Leaves a row for its pane to take when it appears, the way
/// `ModelPickerSheetRequest` leaves a model slot.
enum SettingsFocusRequest {
    static let didRequest = Notification.Name("ForeverLM.settingsRowFocusRequested")
    @MainActor private static var pending: SettingsRowID?

    /// Stages `row` and names its pane, for a caller that navigates there
    /// itself. An already open pane does not appear again, so it hears the
    /// notification too.
    @MainActor
    @discardableResult
    static func stage(_ row: SettingsRowID) -> SettingsPane? {
        pending = row
        Task { @MainActor in NotificationCenter.default.post(name: didRequest, object: nil) }
        return row.pane
    }

    /// The pending row, if it belongs to `pane`. The pane being left hears
    /// the request too, and must leave it for the one opening.
    @MainActor
    static func take(for pane: SettingsPane?) -> SettingsRowID? {
        guard let row = pending, row.pane == pane else { return nil }
        pending = nil
        return row
    }
}

private struct SettingsHighlightedRowKey: EnvironmentKey {
    static let defaultValue: SettingsRowID? = nil
}

extension EnvironmentValues {
    fileprivate var settingsHighlightedRow: SettingsRowID? {
        get { self[SettingsHighlightedRowKey.self] }
        set { self[SettingsHighlightedRowKey.self] = newValue }
    }
}

extension View {
    /// Wraps a pane's content so a staged `SettingsRowID` scrolls into the
    /// middle of the pane and holds a highlight for a few seconds. A nil pane
    /// is a plugin's page.
    func settingsFocusHost(pane: SettingsPane?) -> some View {
        modifier(SettingsFocusHost(pane: pane))
    }

    /// Marks the row `id` names, so the pane can scroll to it and wash it.
    func settingsFocusRow(_ id: SettingsRowID) -> some View {
        modifier(SettingsFocusRow(id: id))
    }
}

private struct SettingsFocusHost: ViewModifier {
    let pane: SettingsPane?
    @State private var highlighted: SettingsRowID?
    @State private var clearTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.settingsHighlightedRow, highlighted)
                .onAppear { focus(proxy) }
                .onReceive(NotificationCenter.default.publisher(for: SettingsFocusRequest.didRequest)) { _ in
                    focus(proxy)
                }
                .onDisappear { clearTask?.cancel() }
        }
    }

    private func focus(_ proxy: ScrollViewProxy) {
        guard let row = SettingsFocusRequest.take(for: pane) else { return }
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            // The pane's rows load in after it appears; scroll once they exist.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(row, anchor: .center)
            }
            highlighted = row
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { highlighted = nil }
        }
    }
}

private struct SettingsFocusRow: ViewModifier {
    let id: SettingsRowID
    @Environment(\.settingsHighlightedRow) private var highlighted

    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted == id ? 0.14 : 0))
            )
            .padding(-8)
            .id(id)
    }
}

#Preview("General settings") {
    GeneralSettingsDetailView()
        .frame(width: 620, height: 520)
}
