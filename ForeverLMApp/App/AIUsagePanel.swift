import SwiftUI
import AppKit

// The AI Usage surface: the learner's own key, spending and limits, and the
// activity by task. It is no Settings pane any more: it opens from the rail's
// OpenRouter button, under what is running now (`BackgroundWorkButton`).

/// AI Usage above the activity: the learner's own key and
/// spending with its limits, one card each. Paying for ForeverLM is
/// Settings › Billing; the key card only points there when the account may
/// not run the key.
struct AIUsageAccountSections: View {
    let onOpenBilling: () -> Void

    @Environment(ManagedAIAccountModel.self) private var account
    @State private var ownKeyRouter: ManagedAI.OwnKeyRouter = .openRouter
    @State private var ownKeyDraft = ""
    @State private var ownKeySaving = false
    @State private var isReplacingOwnKey = false
    @State private var freeRequests: ManagedAI.FreeModelDailyRequests?
    @State private var freeRequestsFailed = false
    @State private var freeRequestsLoading = false

    var body: some View {
        managedAISection
            .task { await account.refresh() }
    }

    @ViewBuilder
    private var managedAISection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if account.isSignedIn {
                ownKeySection
            } else {
                signedOutSection
            }
            spendingSection

            accountError
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await account.refresh(minimumInterval: 2, silently: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            Task { await account.reloadOwnKey() }
        }
    }

    private var signedOutSection: some View {
        ManagedAISignInSection(title: "API keys", message: "Sign in to add your OpenRouter API key.")
    }

    /// The product owner (2026-09-25): ForeverLM's AI features are bring your own key.
    /// The key is the pane's first card: with one stored, during the free
    /// days or once ForeverLM is paid for, OpenRouter bills the learner at
    /// cost for everything ForeverLM sends through it. OpenRouter is the only router since Ramp was removed on
    /// 2026-09-23. Every line that names the scope reads it off
    /// `ManagedAI.OwnKeyRouter`.
    private var ownKeySection: some View {
        SettingsSection(
            title: "API keys",
            description: "AI features run on your OpenRouter API key, billed at cost."
        ) {
            billingCard {
                VStack(alignment: .leading, spacing: 0) {
                    if let own = account.ownKey {
                        billingRow(
                            title: "\(own.router.label) key ending in \(own.suffix)",
                            detail: "\(own.router.billedScopeCapitalized) are billed to your \(own.router.label) account"
                        ) {
                            Button("Replace") {
                                ownKeyRouter = own.router
                                ownKeyDraft = ""
                                isReplacingOwnKey = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(isReplacingOwnKey || ownKeySaving)

                            Button("Remove", role: .destructive) {
                                Task {
                                    ownKeySaving = true
                                    defer { ownKeySaving = false }
                                    await account.removeOwnKey()
                                    isReplacingOwnKey = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(ownKeySaving)
                            .help("Without a key, AI features stop until you add one again")
                        }
                        if own.router == .openRouter {
                            rowDivider
                            freeRequestsRow
                                .task(id: own) { await loadFreeRequests() }
                        }
                    }

                    if account.ownKey == nil || isReplacingOwnKey {
                        if account.ownKey != nil { rowDivider }
                        ownKeyEntry
                    }
                }
            }
        }
    }

    private var ownKeyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecureField("Paste your \(ownKeyRouter.label) key", text: $ownKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await saveOwnKey() } }
                    .accessibilityIdentifier("billing.ownKey.field")

                Button {
                    Task { await saveOwnKey() }
                } label: {
                    if ownKeySaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownKeySaving)
                .accessibilityIdentifier("billing.ownKey.save")

                if isReplacingOwnKey {
                    Button("Cancel") {
                        isReplacingOwnKey = false
                        ownKeyDraft = ""
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                if ownKeyRouter == .openRouter {
                    Button {
                        Task {
                            if await account.connectOpenRouter() { isReplacingOwnKey = false }
                        }
                    } label: {
                        if account.openRouterConnectInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect OpenRouter")
                        }
                    }
                    .disabled(account.openRouterConnectInFlight || ownKeySaving)
                }
                Link(ownKeyRouter.keysLinkTitle, destination: ownKeyRouter.keysURL)
                    .font(.caption)
            }

            Label(ownKeyRouter.keyPrivacySummary, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(ownKeyRouter.keyPrivacyNote)
                .accessibilityIdentifier("billing.ownKey.privacy")
        }
    }

    /// The product owner (2026-09-28): "any way to track how many openrouter free model
    /// calls we have left for the day?" The count is OpenRouter's own, read
    /// when the key row appears and on Refresh.
    private var freeRequestsRow: some View {
        let spent = freeRequests?.isSpent == true
        return BillingRow(
            title: spent ? "Out of free-model requests" : "Free-model requests today",
            detail: freeRequestsDetail,
            isWarning: spent
        ) {
            Button {
                Task { await loadFreeRequests() }
            } label: {
                if freeRequestsLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(freeRequestsLoading)
            .help("Ask OpenRouter again")
            .accessibilityLabel("Refresh")
        }
        // A group of its own: on a plain row the identifier landed on both
        // texts and on Refresh.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("billing.ownKey.freeRequests")
    }

    private var freeRequestsDetail: String {
        if let freeRequests { return freeRequests.summary() }
        return freeRequestsFailed ? "Couldn't ask OpenRouter" : "Asking OpenRouter…"
    }

    private func loadFreeRequests() async {
        freeRequestsLoading = true
        defer { freeRequestsLoading = false }
        do {
            freeRequests = try await ManagedAI.freeModelDailyRequests()
            freeRequestsFailed = false
        } catch {
            freeRequests = nil
            freeRequestsFailed = true
        }
    }

    private func saveOwnKey() async {
        let key = ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !ownKeySaving else { return }
        ownKeySaving = true
        defer { ownKeySaving = false }
        // A key the router refuses stays in the field, with the reason below.
        guard await account.setOwnKey(key, router: ownKeyRouter) else { return }
        ownKeyDraft = ""
        isReplacingOwnKey = false
    }

    /// Dollars are OpenRouter's to show (product owner, 2026-10-15: "we
    /// shouldn't maintain our own spend stuff"), so the card links to its
    /// monitor. The daily background limit is this Mac's guard and stays.
    private var spendingSection: some View {
        SettingsSection(title: "Spending") {
            billingCard {
                VStack(alignment: .leading, spacing: 0) {
                    billingRow(
                        title: "Spend",
                        detail: "What your key has cost, by model and day, is in OpenRouter"
                    ) {
                        Link("Open OpenRouter", destination: ManagedAI.openRouterActivityURL)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("aiUsage.openRouterActivity")
                    }
                    rowDivider
                    BackgroundAIDailyCapRow()
                }
            }
        }
    }

    @ViewBuilder
    private var accountError: some View {
        if let message = account.errorMessage ?? account.balanceErrorMessage {
            billingCard {
                HStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if account.errorMessage == nil, account.balanceErrorMessage != nil {
                        Button("Retry") {
                            Task { await account.refresh() }
                        }
                        .disabled(account.refreshInFlight)
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        BillingRowDivider()
    }

    private func billingRow<Controls: View>(
        title: String,
        detail: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        BillingRow(title: title, detail: detail, controls: controls)
    }

    private func billingCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        BillingCard(content: content)
    }
}

/// Where the model behind a piece of AI work is chosen: one link for the
/// Activity list's rows and for "Running now", from the work's ledger task.
enum AIModelSetting {
    /// Settings › Chat, or Settings › Background on a model or a task.
    case slot(ModelPickerSlot)
    /// Settings › Voice › Speech to text, on dictation's or recordings' model.
    case transcription(ManagedTranscriptionClient.Purpose)
    /// A pane with one model for the work: Voice's text to speech, Images, Videos.
    case pane(SettingsPane)

    /// Nil for work whose model is no learner's choice (Apple's on-device
    /// embeddings) or that no route records; a link there would open a pane
    /// that changes nothing.
    init?(task: String) {
        if let aiTask = AITask(rawValue: task) {
            if KeychainService.canHaveOwnRoute(aiTask) {
                self = .slot(.task(aiTask))
                return
            }
            // The chat, and the work that runs on the chat's model.
            if aiTask.usesBackgroundModelDefault { return nil }
            self = .slot(.chat)
            return
        }
        switch task {
        // Purposes of a chat the learner waits on, run on the chat's model.
        // Its title and history summary are tasks with Background routes.
        case "deep_research_chat", "chat_quiz_grading":
            self = .slot(.chat)
        case "meeting_transcription", "podcast_transcription", "course_video_transcription":
            self = .transcription(.media)
        case "composer_dictation", "review_dictation", "canvas_voice_dictation":
            self = .transcription(.dictation)
        case "read_aloud", "review_speech":
            self = .pane(.aiTextToSpeech)
        case "notebook_cover", "course_quiz_picture", "course_quiz_icon", "card_picture", "meeting_icon", "doc_image", "chat_image":
            self = .pane(.aiImages)
        case "explainer_video":
            self = .pane(.aiVideos)
        default:
            return nil
        }
    }

    var help: String {
        switch self {
        case .slot(.task(let task)):
            return "Settings › Background › Tasks › \(task.displayName)"
        case .slot:
            return "Runs on your chat's model: Settings › Chat"
        case .transcription(let purpose):
            return "Settings › Voice › Speech to text › \(purpose.settingsLabel)"
        case .pane(.aiTextToSpeech):
            return "Settings › Voice › Text to speech"
        case .pane(.aiVideos):
            return "Settings › Videos"
        case .pane:
            return "Settings › Images"
        }
    }

    func open(_ onOpenSettings: (SettingsPane) -> Void) {
        switch self {
        case .slot(let slot):
            onOpenSettings(ModelPickerSheetRequest.stage(slot))
        case .transcription(let purpose):
            TranscriptionModelRequest.stage(purpose)
            onOpenSettings(.aiTextToSpeech)
        case .pane(let pane):
            onOpenSettings(pane)
        }
    }
}

/// AI Usage › Activity: which tasks used AI, grouped by task, for a range,
/// read from this Mac's usage ledger (`ai_usage_events`). Every row shows what
/// it cost, a free model's as $0.00.
/// Was the Usage pane until 2026-09-24,
/// with a per-call log, facet filters, a prompt-cache line and a CSV export;
/// those were diagnostics, and `get_ai_usage_report` reads the same ledger.
struct AIActivitySettingsSection: View {
    private enum UsageRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case thirtyDays = "30 Days"
        case allTime = "All"

        var id: String { rawValue }

        /// nil means no lower bound — the full ledger back to the first
        /// recorded call.
        var since: Date? {
            switch self {
            case .today: return Calendar.current.startOfDay(for: Date())
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            case .thirtyDays: return Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            case .allTime: return nil
            }
        }
    }

    /// Opens another Settings pane in this window, for a row's off switch.
    let onOpenSettings: (SettingsPane) -> Void
    /// Closes the popover, for a row that opens something in the window
    /// behind it (a source, a notebook, a chat).
    let onClose: () -> Void

    @Environment(StudioViewModel.self) private var vm

    @State private var range: UsageRange = .today
    @State private var isLoading = false
    /// Server reconciliation is deliberately separate from the local load.
    /// A full authoritative-ledger replay can span many network pages, but the
    /// already-cached usage pane must remain immediately useful while it runs.
    @State private var isReconciling = false
    @State private var activityGroups: [AIUsageTaskActivitySummary] = []
    @State private var expandedActivityKeys = Set<String>()
    @State private var subjectsByActivityKey: [String: [AIUsageSubjectActivitySummary]] = [:]
    @State private var subjectOffsetsByActivityKey: [String: Int] = [:]
    @State private var loadingActivityKeys = Set<String>()
    @State private var totalEvents = 0
    /// `AIUsageLedgerHealth`'s counters, read once per reload. Two UserDefaults
    /// lookups, so they stay on the main actor with the rest of the pane state.
    @State private var ledgerFailures = 0
    @State private var ledgerFailureDetail: String?
    @State private var serverReconciliationError: String?
    /// Expanded activity rows participate in the outer settings ScrollView's
    /// AppKit accessibility/focus tree. Keep that tree strictly bounded: a
    /// 410-item activity was enough to stall the main thread for several
    /// seconds even though its SQLite aggregation already ran off-main.
    private static let subjectPageSize = 50

    private var eventFilter: KnowledgeStore.AIUsageEventFilter {
        .init(
            since: range.since,
            provider: nil,
            model: nil,
            operation: nil,
            task: nil,
            clientPlatform: nil
        )
    }

    /// Stable identity for the current range, so a load that finishes after
    /// the range changed is dropped. `eventFilter` itself is not usable for
    /// this: its `since` is derived from `Date()` and so differs on every
    /// evaluation.
    private var filterSelectionKey: String { range.rawValue }

    var body: some View {
        callLogSection
            .task(id: range) { await reload() }
    }

    /// Ledger writes that failed, stated in the pane rather than only counted.
    ///
    /// A failed write is spend that happened and was not recorded, so the whole
    /// pane below reads low without saying so. This went unbuilt once and cost
    /// 486 unrecorded calls over two days: a schema change added
    /// `ai_usage_events.session_id` to the INSERT without the one-time ALTER, so
    /// every write failed with "no such column" into a counter nothing read.
    /// The provider's own message is shown because that is what names the cause.
    @ViewBuilder
    private var ledgerFailureWarning: some View {
        if ledgerFailures > 0 {
            HStack(spacing: 8) {
                Label(
                    "\(Self.exactCountText(ledgerFailures)) usage record\(ledgerFailures == 1 ? "" : "s") not saved",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .help("They are missing from everything below")

                Spacer(minLength: 0)

                SettingsMoreInfoButton {
                    Text("They are missing from everything below.")
                    if let detail = ledgerFailureDetail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Button("Clear Warning") {
                    AIUsageLedgerHealth.reset()
                    ledgerFailures = 0
                    ledgerFailureDetail = nil
                }
                .controlSize(.small)
                .help("Clears the count once the cause is fixed. The calls it counted stay unrecorded.")
            }
        }
    }

    private var callLogSection: some View {
        SettingsSection(title: "Activity") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Range", selection: $range) {
                            ForEach(UsageRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)

                        Spacer()

                        if isLoading || isReconciling {
                            ProgressView().controlSize(.small)
                        }
                    }

                    ledgerFailureWarning

                    if let serverReconciliationError {
                        Label(serverReconciliationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(
                        totalEvents == 0
                            ? "No AI used in this period."
                            : "\(Self.exactCountText(totalEvents)) call\(totalEvents == 1 ? "" : "s")"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The model each task runs on is set under Settings › Background.")

                    if !activityGroups.isEmpty {
                        activityLog
                    }
                }
            }
        }
    }

    private var activityLog: some View {
        // Eager on purpose: nested lazy containers have rendered these rows
        // outside their card on macOS, drawing through the cards above.
        VStack(spacing: 0) {
            ForEach(activityGroups) { summary in
                DisclosureGroup(
                    isExpanded: activityExpansionBinding(for: summary)
                ) {
                    activitySubjects(for: summary)
                        .padding(.leading, 20)
                } label: {
                    activitySummaryRow(summary)
                }
                .padding(.vertical, 4)

                if summary.id != activityGroups.last?.id {
                    Divider()
                }
            }
        }
    }

    private func activityExpansionBinding(
        for summary: AIUsageTaskActivitySummary
    ) -> Binding<Bool> {
        Binding(
            get: { expandedActivityKeys.contains(summary.key) },
            set: { expanded in
                if expanded {
                    expandedActivityKeys.insert(summary.key)
                    guard subjectsByActivityKey[summary.key] == nil else { return }
                    Task { await loadSubjects(for: summary) }
                } else {
                    expandedActivityKeys.remove(summary.key)
                    subjectsByActivityKey.removeValue(forKey: summary.key)
                    subjectOffsetsByActivityKey.removeValue(forKey: summary.key)
                }
            }
        )
    }

    private func activitySummaryRow(_ summary: AIUsageTaskActivitySummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.task.map(Self.taskLabel) ?? "Legacy AI calls")
                    .font(.callout.weight(.medium))
                Text(Self.activityCountSummary(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                modelsLine(
                    summary.models,
                    change: Self.isCharged(summary) ? summary.task.flatMap(AIModelSetting.init(task:)) : nil
                )
            }

            Spacer(minLength: 8)

            if let task = summary.task {
                switch AIUsageTaskNeed.of(taskKey: task) {
                case .needed:
                    Text("Essential")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("This is functionality that is essential for ForeverLM to work, so it cannot be turned off.")
                case .optional:
                    if let control = Self.offSwitch(for: task) {
                        Button("Turn off…") {
                            control.row.open(settings: onOpenSettings)
                        }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(control.help)
                    }
                case .requested:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// Whatever ForeverLM is charged for can have its model changed from its
    /// line (product owner, 2026-10-10: "for things we get charged for; we
    /// need to be able to change the model"). A free line has no link. A
    /// line with unpriced calls may have been charged, so it keeps one.
    private static func isCharged(_ summary: AIUsageTaskActivitySummary) -> Bool {
        (summary.cost ?? 0) > 0 || summary.unpricedCallCount > 0
    }

    private func openModelSetting(_ setting: AIModelSetting) {
        setting.open(onOpenSettings)
    }

    /// Where the learner turns off the background work behind an activity,
    /// for the tasks that have a switch. A task without one shows no link: a
    /// link that only opens a pane would not turn anything off. Adding a
    /// switch for another task is one more case here. The row opens in its
    /// Settings pane or plugin page, scrolled to and highlighted.
    private static func offSwitch(for task: String?) -> (row: SettingsRowID, help: String)? {
        switch task {
        case "card_drafting":
            return (.memoryDraftCards, "Settings › General › Memory › Draft cards from what you finish")
        case "realtime_review_preparation":
            return (.memoryPrepareReviewQuestions, "Settings › General › Memory › Prepare review questions ahead of time")
        case "meeting_transcription":
            return (.driveTranscribeRecordings, "Plugins › Google Drive › Transcribe recordings Google didn't")
        case "notebook_cover":
            return (.imagesNotebookCovers, "Settings › Images › Notebooks › Draw notebook covers")
        case "course_quiz_picture", "course_quiz_icon":
            return (.imagesQuizPictures, "Settings › Images › Course quizzes › Draw pictures for new quizzes")
        case "transcript_formatting":
            return (.youTubeFormatTranscripts, "Plugins › YouTube › Format new transcripts automatically")
        default:
            return nil
        }
    }

    @ViewBuilder
    private func activitySubjects(for summary: AIUsageTaskActivitySummary) -> some View {
        if loadingActivityKeys.contains(summary.key) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else if let subjects = subjectsByActivityKey[summary.key] {
            VStack(spacing: 0) {
                ForEach(subjects) { subject in
                    subjectSummaryRow(subject, task: summary.task)
                    if subject.id != subjects.last?.id {
                        Divider()
                    }
                }

                subjectPageControls(for: summary, loadedCount: subjects.count)
            }
        }
    }

    @ViewBuilder
    private func subjectPageControls(
        for summary: AIUsageTaskActivitySummary,
        loadedCount: Int
    ) -> some View {
        let offset = subjectOffsetsByActivityKey[summary.key] ?? 0
        let remaining = max(0, summary.subjectCount - offset - loadedCount)
        if offset > 0 || remaining > 0 {
            HStack(spacing: 12) {
                Button("Previous") {
                    Task {
                        await loadSubjects(
                            for: summary,
                            offset: max(0, offset - Self.subjectPageSize)
                        )
                    }
                }
                .disabled(offset == 0 || loadingActivityKeys.contains(summary.key))

                Text(
                    "\(Self.exactCountText(offset + 1))–\(Self.exactCountText(offset + loadedCount)) "
                        + "of \(Self.exactCountText(summary.subjectCount))"
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Next \(Self.exactCountText(min(Self.subjectPageSize, remaining)))") {
                    Task {
                        await loadSubjects(
                            for: summary,
                            offset: offset + loadedCount
                        )
                    }
                }
                .disabled(remaining == 0 || loadingActivityKeys.contains(summary.key))
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func subjectSummaryRow(
        _ summary: AIUsageSubjectActivitySummary,
        task: String?
    ) -> some View {
        if let destination = Self.destination(of: summary) {
            Button { open(destination) } label: {
                subjectSummaryContent(summary, task: task)
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -4))
            .contextMenu {
                if case .source(let id) = destination {
                    OtherWindowSourceMenuItem(sourceID: id)
                } else if case .entity(let link) = destination {
                    switch link {
                    case .notebook(let id): OtherWindowMenuItem(.notebook(id))
                    case .chat(let id): OtherWindowMenuItem(.chat(id))
                    default: EmptyView()
                    }
                }
            }
        } else {
            subjectSummaryContent(summary, task: task)
        }
    }

    private func subjectSummaryContent(
        _ summary: AIUsageSubjectActivitySummary,
        task: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.subjectTitle ?? "\(task.map(Self.taskLabel) ?? "Legacy AI") activity")
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Self.subjectDetailSummary(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                modelsLine(summary.models)
            }

            Spacer(minLength: 8)

        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    /// What a click on an item row opens. The ledger stores an id and a type
    /// per item: a source's id under its source type, a notebook's, a chat's.
    /// Anything else (a memory card, a figure, an activity with no record of
    /// its own) is not something the app has a page for, so its row stays
    /// plain text.
    private enum SubjectDestination {
        case source(String)
        case entity(StudioEntityLink)
    }

    private static let sourceSubjectTypes: Set<String> = [
        "article", "paper", "podcast", "podcast_episode", "book", "meeting",
        "video", "xPost", "manual", "unclassified",
    ]

    private static func destination(of summary: AIUsageSubjectActivitySummary) -> SubjectDestination? {
        guard let id = summary.subjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, let type = summary.subjectType else { return nil }
        if sourceSubjectTypes.contains(type) { return .source(id) }
        switch type {
        case "notebook": return .entity(.notebook(id))
        case "chat", "review_session": return .entity(.chat(id))
        default: return nil
        }
    }

    /// Opens the item in this window, behind the popover: it closes so the
    /// Reader, notebook or chat is what the click shows.
    private func open(_ destination: SubjectDestination) {
        onClose()
        Task {
            switch destination {
            case .source(let id): await vm.openLinkedSourceInReader(id)
            case .entity(let link): await vm.open(link)
            }
        }
    }

    /// The model a row ran on, beneath its counts. A row that ran on several
    /// names the two with the most calls and counts the rest; the tooltip
    /// gives every model's share. A charged row adds a link to where its
    /// model is set, beside the model it changes.
    @ViewBuilder
    private func modelsLine(_ models: [AIUsageModelUse], change: AIModelSetting? = nil) -> some View {
        let named = Self.namedModels(models)
        if !named.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.modelsText(named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(
                        named.map { "\($0.name) — \(Self.exactCountText($0.calls)) call\($0.calls == 1 ? "" : "s")" }
                            .joined(separator: "\n")
                    )
                if let change {
                    Button("Change Model…") { openModelSetting(change) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .fixedSize()
                        .help(change.help)
                }
            }
        }
    }

    /// Models by the name the model picker gives them, most calls first. Two
    /// ledger ids can share a name ("openai/gpt-5.6-sol" and "gpt-5.6-sol"),
    /// so their calls are added together under it.
    private static func namedModels(_ models: [AIUsageModelUse]) -> [(name: String, calls: Int)] {
        var calls: [String: Int] = [:]
        for use in models {
            calls[modelName(use), default: 0] += use.callCount
        }
        return calls
            .map { (name: $0.key, calls: $0.value) }
            .sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name }
    }

    /// A ledger row's model as the model picker names it. A host the app no
    /// longer knows keeps the id it recorded.
    private static func modelName(_ use: AIUsageModelUse) -> String {
        guard let provider = AIProvider(ledgerName: use.provider) else { return use.model }
        return AIModelCatalog.pickerName(provider: provider, modelID: use.model)
    }

    private static func modelsText(_ named: [(name: String, calls: Int)]) -> String {
        let shown = named.prefix(2).map(\.name).joined(separator: ", ")
        let rest = named.count - 2
        return rest > 0 ? "\(shown) and \(exactCountText(rest)) more" : shown
    }

    private static func countText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    /// Grouped, unabbreviated count — the call log states exactly how many
    /// calls exist, since "13.9k" would leave the reader unsure whether
    /// anything was being hidden.
    private static func exactCountText(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func activityCountSummary(_ summary: AIUsageTaskActivitySummary) -> String {
        var parts: [String] = []
        if summary.subjectCount > 0 {
            parts.append("\(exactCountText(summary.subjectCount)) \(subjectCountLabel(summary.subjectType, count: summary.subjectCount))")
        } else if summary.activityCount < summary.callCount {
            parts.append("\(exactCountText(summary.activityCount)) activit\(summary.activityCount == 1 ? "y" : "ies")")
        }
        parts.append("\(exactCountText(summary.callCount)) call\(summary.callCount == 1 ? "" : "s")")
        if summary.subjectCount == 0 {
            if summary.inputTokens > 0 { parts.append("\(countText(summary.inputTokens)) in") }
            if summary.outputTokens > 0 { parts.append("\(countText(summary.outputTokens)) out") }
        }
        parts.append(costText(summary.cost, unpriced: summary.unpricedCallCount))
        return parts.joined(separator: " · ")
    }

    /// What a row cost, always: a free model reads "$0.00" rather than
    /// leaving the figure out (product owner, 2026-10-17: "even if it's
    /// free; these things should show a cost"). A row the ledger could not
    /// price says so instead of passing for free.
    private static func costText(_ cost: Double?, unpriced: Int) -> String {
        guard let cost else { return "not priced" }
        let amount: String
        if cost > 0, cost < 0.01 {
            amount = "<$0.01"
        } else {
            amount = cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        }
        return unpriced > 0 ? "\(amount) + \(unpriced) not priced" : amount
    }

    private static func subjectDetailSummary(_ summary: AIUsageSubjectActivitySummary) -> String {
        var parts: [String] = []
        if let type = summary.subjectType { parts.append(subjectTypeLabel(type)) }
        parts.append("\(exactCountText(summary.callCount)) call\(summary.callCount == 1 ? "" : "s")")
        if summary.inputTokens > 0 { parts.append("\(countText(summary.inputTokens)) in") }
        if summary.outputTokens > 0 { parts.append("\(countText(summary.outputTokens)) out") }
        parts.append(costText(summary.cost, unpriced: summary.unpricedCallCount))
        return parts.joined(separator: " · ")
    }

    private static func subjectCountLabel(_ type: String?, count: Int) -> String {
        let singular: String
        switch type {
        case "podcast_episode": singular = "podcast episode"
        case "video": singular = "video"
        case "article": singular = "article"
        case "paper": singular = "paper"
        case "book": singular = "book"
        case "chat": singular = "chat"
        case "activity": return count == 1 ? "activity" : "activities"
        case "review_session": singular = "review"
        default: singular = "item"
        }
        return count == 1 ? singular : singular + "s"
    }

    private static func subjectTypeLabel(_ type: String) -> String {
        switch type {
        case "podcast_episode": return "Podcast episode"
        case "review_session": return "Review"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func taskLabel(_ task: String) -> String {
        AIUsageTaskLabel.text(for: task)
    }

    private func reload() async {
        isLoading = true

        ledgerFailures = AIUsageLedgerHealth.failureCount
        ledgerFailureDetail = AIUsageLedgerHealth.lastFailureDescription

        // StorageService is an actor, so the SQLite scans run on its executor
        // rather than the main actor.
        let storage = StorageService()
        await reloadLocalUsage(from: storage)
        isLoading = false

        guard !Task.isCancelled else { return }

        if ManagedAI.isSignedIn {
            isReconciling = true
            defer { isReconciling = false }
            do {
                let importedEvents = try await reconcileManagedUsage(into: storage)
                serverReconciliationError = nil
                if importedEvents, !Task.isCancelled {
                    await reloadLocalUsage(from: storage)
                }
            } catch {
                guard !Task.isCancelled else { return }
                serverReconciliationError = "Server usage could not be reconciled, so the list below may be incomplete: \(error.localizedDescription)"
            }
        } else {
            serverReconciliationError = nil
        }
    }

    /// Publishes the on-device ledger before making any network request. The
    /// server mirror is incremental and authoritative, but it is a refresh of
    /// this cache rather than a prerequisite for rendering it.
    private func reloadLocalUsage(from storage: StorageService) async {
        // Price what can be priced first, so a line is only treated as free
        // when its calls really cost nothing.
        await AIUsageTracker.repriceLedger(storage: storage)
        await reloadFilteredUsage(from: storage)
    }

    /// Pull every unseen D1 usage row. Opening the Usage pane is one of the
    /// events that refreshes accounting — running out of credit is the other,
    /// see `ManagedAIAccountModel.pullServerUsage`, which owns the pull so both
    /// share one cursor and one import path.
    private func reconcileManagedUsage(into storage: StorageService) async throws -> Bool {
        try await ManagedAIAccountModel.pullServerUsage(into: storage)
    }

    /// Reloads the range's totals and activity groups without reconciling the
    /// server.
    private func reloadFilteredUsage(from storage: StorageService = StorageService()) async {
        let key = filterSelectionKey
        let filter = eventFilter
        let totals = try? await storage.aiUsageEventTotals(filter: filter)
        let loadedActivityGroups = (try? await storage.aiUsageTaskActivities(filter: filter)) ?? []

        // A newer range may have started another load while these
        // actor-isolated SQLite reads were in flight.
        guard key == filterSelectionKey else { return }

        totalEvents = totals?.count ?? 0
        activityGroups = loadedActivityGroups
        expandedActivityKeys.removeAll()
        subjectsByActivityKey.removeAll()
        subjectOffsetsByActivityKey.removeAll()
        loadingActivityKeys.removeAll()
    }

    private func loadSubjects(
        for summary: AIUsageTaskActivitySummary,
        offset: Int = 0
    ) async {
        guard !loadingActivityKeys.contains(summary.key) else { return }
        loadingActivityKeys.insert(summary.key)
        defer { loadingActivityKeys.remove(summary.key) }

        let key = filterSelectionKey
        let filter = eventFilter
        let subjects = (try? await StorageService().aiUsageSubjectActivities(
            task: summary.task,
            filter: filter,
            limit: Self.subjectPageSize,
            offset: offset
        )) ?? []
        guard key == filterSelectionKey,
              expandedActivityKeys.contains(summary.key),
              activityGroups.contains(where: { $0.key == summary.key }) else { return }
        subjectsByActivityKey[summary.key] = subjects
        subjectOffsetsByActivityKey[summary.key] = offset
    }

}

// MARK: - The panel

/// Where AI Usage is opened from anywhere in the app: the active window's
/// Studio takes the Settings request for `.aiUsage` and opens the rail's
/// OpenRouter popover instead (`StudioView.openSettings`).
enum AIUsagePlace {
    @MainActor
    static func requestOpen() {
        NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.aiUsage)
    }
}

/// What the rail's OpenRouter button opens (product owner, 2026-10-15: "ai
/// usage should instead be under that openrouter button … both what is
/// running now and what has run in the past"): the work running now, what has
/// run, then the learner's own key and its limits. It was a Settings pane.
struct AIUsagePanel: View {
    @ObservedObject var monitor: BackgroundWorkMonitor
    let title: (BackgroundWorkItem) -> String
    let onOpenSettings: (SettingsPane) -> Void
    let onClose: () -> Void

    @Environment(ManagedAIAccountModel.self) private var account

    /// Without a key nothing runs, so the key leads.
    private var keyComesFirst: Bool { !account.isSignedIn || account.ownKey == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AIUsageSpentToday()
                if keyComesFirst { accountSections }
                SettingsSection(title: "Running now") {
                    SettingsCard {
                        BackgroundWorkList(monitor: monitor, title: title, onOpenSettings: onOpenSettings)
                    }
                }
                AIActivitySettingsSection(onOpenSettings: onOpenSettings, onClose: onClose)
                if !keyComesFirst { accountSections }
            }
            .padding(20)
        }
        .frame(width: 540, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accountSections: some View {
        AIUsageAccountSections(onOpenBilling: { onOpenSettings(.aiBilling) })
    }
}

/// The pane's headline (product owner, 2026-10-17: "at the top of this whole
/// pane; there should be a total spend for today"): what every AI call since
/// local midnight cost, from the same ledger the activity list below reads.
/// Calls the ledger could not price are counted in the detail, so the figure
/// reads as a floor when there are any.
private struct AIUsageSpentToday: View {
    @State private var totals: AIUsageEventTotals?

    private var amount: String {
        (totals?.cost ?? 0).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private var detail: String {
        guard let totals else { return "Reading today's calls" }
        let calls = totals.count == 1 ? "1 call" : "\(totals.count) calls"
        if totals.unpriced > 0 { return "\(calls) today, \(totals.unpriced) not priced yet" }
        return "\(calls) today, every model and task"
    }

    var body: some View {
        SettingsCard {
            BillingRow(title: "Spent today", detail: detail) {
                Text(totals == nil ? "—" : amount)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aiUsageEventRecorded).receive(on: RunLoop.main)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        let start = Calendar.current.startOfDay(for: Date())
        let filter = KnowledgeStore.AIUsageEventFilter(
            since: start, provider: nil, model: nil, operation: nil, task: nil, clientPlatform: nil
        )
        totals = try? await StorageService().aiUsageEventTotals(filter: filter)
    }
}
