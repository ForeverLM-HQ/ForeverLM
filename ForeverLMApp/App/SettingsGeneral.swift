import AppKit
import SwiftUI

// Settings has no General pane (product owner, 2026-11-08: "these
// 'general' settings don't make much sense to me", "please distribute that
// among other settings", "the main page that should open is an ai models
// page"). Its sections live where they belong instead:
// - Your name: Data & Privacy, the account's pane (`SettingsNameSection`).
// - Day, Quick assistant, Think first: Chat (`SettingsDaySection`,
//   `QuickAssistantSettingsSection`, `SettingsThinkFirstSection`).
// - Memory review: Background, whose AI drafts the cards and readies the
//   day's review (`SettingsMemoryReviewSection`).
// - Beta releases: the Settings sidebar's footer, under the version
//   (`SettingsBetaReleasesToggle`).
// About you left Settings the same day ("remove this 'about you'"); Add
// Textbook asks for it where it is used, and `account.about_you` sets it over MCP.

/// Every picker and field on the right edge of a row is this wide, so the
/// controls line up down a pane instead of each ending where it likes.
enum SettingsLayout {
    static let controlWidth: CGFloat = 150

    static var rowDivider: some View {
        Divider().padding(.vertical, 12)
    }
}

/// Your name, the one every client shows: edited as a draft and saved on
/// Return or when the field loses focus, so typing is not a sync per key.
struct SettingsNameSection: View {
    @PreferenceStorage(Prefs.Account.displayName)
    private var savedDisplayName: String
    @State private var displayNameDraft = ""
    @FocusState private var displayNameFocused: Bool

    var body: some View {
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
            }
        }
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
}

/// The day's hours and the morning's ask to plan it, which opens the
/// planning chat.
struct SettingsDaySection: View {
    /// This Mac's: the card and the notification ask on this Mac.
    @AppStorage(Prefs.Planner.suggestPlanningTheDay)
    private var suggestPlanningTheDay: Bool
    @AppStorage(Prefs.Planner.forcePlanningTheDay)
    private var forcePlanningTheDay: Bool
    /// This Mac's: it watches this Mac's screen.
    @AppStorage(Prefs.Planner.nudgeBackOnTrack)
    private var nudgesBackOnTrack: Bool
    @AppStorage(Prefs.Planner.focusReadsScreen)
    private var readsWindowToo: Bool
    private var focusWatcher: FocusWatcher { FocusWatcher.shared }
    /// Synced: the learner's day is the same on every Mac.
    @PreferenceStorage(Prefs.Planner.dayStart, default: PlannerDayHours.defaultStart)
    private var dayStartHour: Int
    @PreferenceStorage(Prefs.Planner.dayEnd, default: PlannerDayHours.defaultEnd)
    private var dayEndHour: Int

    /// The end hours the picker offers: after the chosen start, so the two
    /// pickers cannot be set into a day that ends before it begins.
    private var endHourChoices: [Int] {
        Array(max(PlannerDayHours.endHours.lowerBound, PlannerDayHours.clampStart(dayStartHour) + 1)...PlannerDayHours.endHours.upperBound)
    }

    /// "06:00" for a start, "24:00" reads as "Midnight" for the day's end.
    private static func hourLabel(_ hour: Int) -> String {
        hour == 24 ? "Midnight" : DayPlan.clockString(minute: hour * 60)
    }

    var body: some View {
        SettingsSection(title: "Day") {
            SettingsCard {
                SettingsRow("Day starts at") {
                    Picker("Day starts at", selection: $dayStartHour) {
                        ForEach(Array(PlannerDayHours.startHours), id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
                    .accessibilityIdentifier("settings.general.dayStart")
                    .onChange(of: dayStartHour) { _, start in
                        // The end follows a start moved past it.
                        if dayEndHour <= start { dayEndHour = min(PlannerDayHours.endHours.upperBound, start + 1) }
                    }
                }

                SettingsLayout.rowDivider

                SettingsRow("Day ends at") {
                    Picker("Day ends at", selection: $dayEndHour) {
                        ForEach(endHourChoices, id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
                    .accessibilityIdentifier("settings.general.dayEnd")
                }

                SettingsLayout.rowDivider

                SettingsRow("Ask each morning to plan the day", detail: "When nothing is planned yet.") {
                    Toggle("Ask each morning to plan the day when nothing is planned", isOn: $suggestPlanningTheDay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.general.suggestPlanningTheDay")
                }

                SettingsLayout.rowDivider

                SettingsRow("Make me plan", detail: "Open the planning chat, and keep asking until the day is planned.") {
                    Toggle("Make me plan: open the planning chat, and keep asking until the day is planned", isOn: $forcePlanningTheDay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!suggestPlanningTheDay)
                        .accessibilityIdentifier("settings.general.forcePlanningTheDay")
                }

                SettingsLayout.rowDivider

                SettingsRow("Nudge me back on track", detail: focusDetail) {
                    Toggle("Nudge me back on track during a bout or a calendar block", isOn: Binding(
                        get: { nudgesBackOnTrack },
                        set: { on in
                            FocusWatch.setEnabled(on)
                            // macOS's prompt, which offers System Settings.
                            if on { FrontWindowReader.requestTrust() }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.general.nudgeBackOnTrack")
                }
                if nudgesBackOnTrack, focusWatcher.status == .needsAccessibility, let url = FrontWindowReader.systemSettingsURL {
                    Button("Allow Accessibility…") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.hoverWash)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("settings.general.nudgeBackOnTrack.accessibility")
                }

                SettingsLayout.rowDivider

                SettingsRow("Read the window too", detail: "Its words are read on this Mac and kept nowhere; needs Screen Recording.") {
                    Toggle("Read the words in the window in front too", isOn: Binding(
                        get: { readsWindowToo },
                        set: { on in
                            FocusWatch.setReadsScreen(on)
                            // macOS's prompt, shown once.
                            if on, !FocusScreenReader.isAllowed { FocusScreenReader.requestAccess() }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!nudgesBackOnTrack)
                    .accessibilityIdentifier("settings.general.nudgeReadsScreen")
                }
                if nudgesBackOnTrack, readsWindowToo, focusWatcher.screenReadingBlocked, let url = FocusScreenReader.systemSettingsURL {
                    Button("Allow Screen Recording…") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.hoverWash)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("settings.general.nudgeReadsScreen.screenRecording")
                }
            }
        }
        // Accessibility is granted in System Settings, away from this window.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            focusWatcher.look()
        }
    }

    private static let focusPromise = "During a bout or a calendar block; Apple Intelligence judges on this Mac."

    /// Off, the promise; on, what stands in its way, if anything.
    private var focusDetail: String {
        guard nudgesBackOnTrack else { return Self.focusPromise }
        switch focusWatcher.status {
        case .needsAccessibility, .judgeUnavailable: return focusWatcher.status.summary
        case .off, .waiting, .watching: return Self.focusPromise
        }
    }
}

/// Think first's level for the library (`ThinkFirst`), synced so the picker
/// follows another Mac, the web or MCP.
struct SettingsThinkFirstSection: View {
    @PreferenceStorage(Prefs.Planner.thinkFirstLevel, default: ThinkFirstLevel.off)
    private var thinkFirstLevel: ThinkFirstLevel
    @PreferenceStorage(Prefs.Studio.chatSeesWhatIsOpen)
    private var chatSeesWhatIsOpen: Bool

    var body: some View {
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
                    .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
                    .accessibilityIdentifier("settings.general.thinkFirst")
                }
            }
        }
        SettingsSection(title: "Context") {
            SettingsCard {
                SettingsRow(
                    "Chat sees what's open",
                    detail: "Off, nothing open beside the chat reaches it until you press Add What's Open by the composer."
                ) {
                    Toggle("Chat sees what's open", isOn: $chatSeesWhatIsOpen)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.chat.seesWhatIsOpen")
                }
            }
        }
    }
}

/// Signed up for beta releases (`BetaReleases`), synced so the switch follows
/// another Mac or MCP; `AppUpdateController` sees the change and checks the
/// feed again. Its own line under the version in Settings' sidebar: the label
/// leading, a small switch trailing.
struct SettingsBetaReleasesToggle: View {
    @PreferenceStorage(Prefs.Lifecycle.betaReleases)
    private var betaReleasesSignedUp: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Beta releases")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Toggle("Beta releases", isOn: Binding(
                get: { betaReleasesSignedUp },
                set: { BetaReleases.setSignedUp($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityIdentifier("settings.general.betaReleases")
        }
        .help("Early builds and beta features, such as the Canvas, on every Mac you use")
    }
}

/// The daily memory review: its length, the day's new cards, background card
/// drafting and today's review readied ahead.
struct SettingsMemoryReviewSection: View {
    @PreferenceStorage(Prefs.Memory.budgetMinutes, default: MemoryReviewBudget.defaultMinutes)
    private var budgetMinutes: Int
    @PreferenceStorage(Prefs.Memory.dailyPreparationEnabled)
    private var prepareDaily: Bool
    @AppStorage(Prefs.Memory.dailyPreparationHour, default: DailyReviewPreparation.defaultHour)
    private var readyHour: Int
    /// Synced: the day's new cards, background drafting, and the corner card.
    @PreferenceStorage(Prefs.Memory.newCardsPerDay, default: MemoryCardQueue.defaultNewPerDay)
    private var newCardsPerDay: Int
    @PreferenceStorage(Prefs.Memory.autoDraftCards)
    private var autoDraftsCards: Bool
    @PreferenceStorage(Prefs.Memory.draftNudges)
    private var showsDraftNudges: Bool
    @PreferenceStorage(Prefs.Memory.morningExplanation)
    private var startsMorningWithExplanation: Bool
    /// macOS's answer about ForeverLM's notifications: read when the section
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

    var body: some View {
        SettingsSection(title: "Memory review") {
            SettingsCard {
                SettingsRow("Time each day") {
                    Picker("Time each day", selection: $budgetMinutes) {
                        ForEach(Self.budgetChoices(including: budgetMinutes), id: \.self) { minutes in
                            Text(MemoryReviewBudget.label(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
                    .accessibilityIdentifier("settings.memory.budget")
                }

                SettingsLayout.rowDivider

                SettingsRow("New cards each day") {
                    Picker("New cards each day", selection: newCardsPerDayBinding) {
                        ForEach(Self.newCardChoices(including: newCardsPerDay), id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
                    .accessibilityIdentifier("settings.memory.newCardsPerDay")
                }

                SettingsLayout.rowDivider

                SettingsRow("Draft cards from what you finish", detail: "Uses AI, within your daily background limit.") {
                    Toggle("Draft cards from what you finish", isOn: autoDraftsCardsBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.memory.autoDraftCards")
                }
                .settingsFocusRow(.memoryDraftCards)

                SettingsLayout.rowDivider

                SettingsRow("Say when drafted cards wait") {
                    Toggle("Say when drafted cards wait", isOn: showsDraftNudgesBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.memory.draftNudges")
                }

                SettingsLayout.rowDivider

                SettingsRow("Start the morning with an explanation", detail: "Memory opens one thing to explain from memory, then today's cards.") {
                    Toggle("Start the morning with an explanation", isOn: $startsMorningWithExplanation)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.memory.morningExplanation")
                }

                SettingsLayout.rowDivider

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
                    SettingsLayout.rowDivider

                    SettingsRow("Ready by") {
                        Picker("Ready by", selection: $readyHour) {
                            ForEach(0..<24, id: \.self) { value in
                                Text(DailyReviewPreparation.hourLabel(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
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
/// its control on the right edge. Every such row draws this way, so a
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

/// Settings › Background › Papers: what background work does for a paper as it is added.
struct SettingsPapersSection: View {
    @PreferenceStorage(Prefs.Discovery.paperReferenceModelReading)
    private var readsReferencesWithModel: Bool

    var body: some View {
        SettingsSection(title: "Papers") {
            SettingsCard {
                SettingsRow("Find unlinked references with AI", detail: "When a paper is added. Uses AI, within your daily background limit.") {
                    Toggle("Find unlinked references with AI", isOn: $readsReferencesWithModel)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.papers.readReferencesWithModel")
                }
                .settingsFocusRow(.papersReadReferences)
            }
        }
    }
}

/// One setting a learner can be sent to by name, from outside Settings (AI
/// Usage › Activity's Turn off…). The pane scrolls to the row and washes it.
enum SettingsRowID: String {
    case memoryDraftCards
    case papersReadReferences
    case imagesQuizPictures
    case imagesNotebookCovers
    case driveTranscribeRecordings
    case youTubeFormatTranscripts

    /// The Settings pane the row is in; nil for a row on a plugin's page.
    var pane: SettingsPane? {
        switch self {
        case .memoryDraftCards, .papersReadReferences: .aiBackgroundModels
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

#Preview("Memory review settings") {
    ScrollView { SettingsMemoryReviewSection().padding(24) }
        .frame(width: 620, height: 520)
}
