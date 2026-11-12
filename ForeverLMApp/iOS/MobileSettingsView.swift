import AVFoundation
import AuthenticationServices
import SwiftUI

/// The quiet corner behind the home screen's gear: the text-to-speech voice,
/// voice mode's voice, the memory review's day, the data policy, and the
/// account's spending, day by day.
struct MobileSettingsView: View {
    @Environment(MobileAccountGateModel.self) private var account
    @ObservedObject private var offline = MobileOfflineLibrary.shared
    @AppStorage(Prefs.Planner.loadingIndicatorSpeed, default: LoadingIndicatorSpeed.defaultValue)
    private var thinkingMarkSpeed: Double
    @State private var showsDeleteConfirmation = false
    @State private var showsSignOutConfirmation = false
    @State private var showsDeleteAuthorization = false
    // Synced through the account's preference rows; the phone reads it once
    // here and writes through on change. See `DailyReviewPreparation`.
    @State private var prepareDailyReview = false
    @State private var memorySettingsError: String?
    // How many minutes a day the review gets; synced like the switch above and
    // read once here. See `MemoryReviewBudget`.
    @State private var reviewBudgetMinutes = MemoryReviewBudget.defaultMinutes
    // Whether OpenRouter may route to hosts that keep prompts; the account's
    // row, read once here and written through on change. See `AIDataPolicy`.
    @State private var denyDataCollection = false
    @State private var dataPolicyError: String?
    // Voice mode's voice, the account's row (the Mac sets it too); shown from
    // the last pick this phone saw until the row answers.
    @State private var voiceModeVoice = RealtimeVoiceDefaults.resolvedVoice(MobileRealtimeVoicePick.lastSeen)
    @State private var voiceModeError: String?
    @AppStorage(Prefs.Memory.dailyPreparationHour, default: DailyReviewPreparationKeys.defaultHour)
    private var prepareDailyReviewHour: Int
    @ObservedObject private var reviewScheduler = MobileMemoryReviewScheduler.shared
    /// The library's move and sync (`MobileSyncNotice`).
    @ObservedObject private var librarySync = MobileLibrarySyncStatusModel.shared

    /// The live mark at the chosen pace beside its slider, so the setting is
    /// watched rather than read. Quarter steps, 0.25× to 3×.
    private var thinkingMarkSpeedRow: some View {
        let speed = LoadingIndicatorSpeed.clamped(thinkingMarkSpeed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForeverLMLoadingIndicator(
                    width: ForeverLMLoadingIndicator.inlineWidth,
                    style: .flowingGoo,
                    speed: speed
                )
                .accessibilityHidden(true)
                Text("Thinking mark speed")
                Spacer(minLength: 0)
                Text(LoadingIndicatorSpeed.label(for: speed))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.thinkingMarkSpeedValue")
            }
            Slider(
                value: Binding(
                    get: { speed },
                    set: { thinkingMarkSpeed = LoadingIndicatorSpeed.clamped($0) }
                ),
                in: LoadingIndicatorSpeed.range,
                step: LoadingIndicatorSpeed.step
            )
            .accessibilityLabel("Thinking mark speed")
            .accessibilityValue(LoadingIndicatorSpeed.label(for: speed))
            .accessibilityIdentifier("settings.thinkingMarkSpeed")
        }
    }

    var body: some View {
        List {
            Section {
                MobileTextToSpeechSettingsControls()
            } header: {
                Text("Text to Speech")
            } footer: {
                // A section's footer is one clause, kept for a cost, a
                // privacy fact or an action (the Mac's rule: AGENTS.md "Settings
                // holds only what a learner changes"). There is no Speech to
                // Text section: it would be a paragraph with no control.
                Text("Continuing books makes missing chapters, billed to your OpenRouter key.")
            }

            Section {
                Picker("Voice", selection: voiceModeVoiceBinding) {
                    ForEach(RealtimeVoiceDefaults.voices, id: \.self) { id in
                        Text(RealtimeVoiceDefaults.voiceLabel(id)).tag(id)
                    }
                }
                .accessibilityIdentifier("settings.voiceMode.voice")
                if let voiceModeError {
                    Text(voiceModeError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Voice Mode")
            }

            Section {
                Picker("Time each day", selection: reviewBudgetBinding) {
                    ForEach(MemoryReviewBudget.choices, id: \.self) { minutes in
                        Text(MemoryReviewBudget.label(minutes)).tag(minutes)
                    }
                }
                .accessibilityIdentifier("settings.memory.budget")
                Toggle("Have today's review ready", isOn: prepareDailyReviewBinding)
                    .accessibilityIdentifier("settings.memory.prepareDaily")
                if prepareDailyReview {
                    Picker("Ready by", selection: $prepareDailyReviewHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(DailyReviewPreparationTiming.hourLabel(hour)).tag(hour)
                        }
                    }
                    .accessibilityIdentifier("settings.memory.hour")
                    .onChange(of: prepareDailyReviewHour) { _, hour in
                        reviewScheduler.hour = hour
                        reviewScheduler.scheduleNextRefresh()
                        Task { await MobileMemoryReviewScheduler.refreshReminder(hour: hour) }
                    }
                    LabeledContent("Today") {
                        Text(memoryPreparationStatus)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityIdentifier("settings.memory.status")
                    Button {
                        Task { _ = await reviewScheduler.prepareNow() }
                    } label: {
                        if reviewScheduler.isPreparing {
                            HStack(spacing: 8) {
                                ForeverLMLoadingIndicator(width: ForeverLMLoadingIndicator.inlineWidth, style: .flowingGoo)
                                Text("Preparing…")
                            }
                        } else {
                            Text("Prepare now")
                        }
                    }
                    .disabled(reviewScheduler.isPreparing)
                    .accessibilityIdentifier("settings.memory.prepareNow")
                }
                if let memorySettingsError {
                    Text(memorySettingsError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Having it ready uses AI daily, billed to your OpenRouter key.")
            }

            Section {
                Toggle(AIDataPolicy.switchTitle, isOn: denyDataCollectionBinding)
                    .accessibilityIdentifier("settings.ai.denyDataCollection")
                if let dataPolicyError {
                    Text(dataPolicyError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Data & Privacy")
            } footer: {
                Text(MobileDataPrivacyCopy.footer)
            }

            if !librarySync.lines.isEmpty {
                Section {
                    ForEach(librarySync.lines, id: \.self) { line in
                        Text(line)
                    }
                } header: {
                    Text("iCloud")
                }
                .accessibilityIdentifier("settings.librarySync")
            }

            Section {
                thinkingMarkSpeedRow
            } header: {
                Text("Display")
            } footer: {
                Text("The mark holds still while Reduce Motion is on.")
            }

            Section {
                NavigationLink {
                    MobileOfflineDownloadsView()
                } label: {
                    LabeledContent {
                        if let total = offline.formattedTotalBytes {
                            Text(total)
                        }
                    } label: {
                        Label("Offline", systemImage: "arrow.down.circle")
                    }
                }
                .accessibilityIdentifier("settings.offline")
            }

            Section {
                NavigationLink {
                    MobileCreditsView()
                } label: {
                    Label(MobileKeyScreenCopy.title, systemImage: "key")
                }
                .accessibilityIdentifier("settings.credits")

                NavigationLink {
                    MobileUsageHistoryView()
                } label: {
                    Label("Usage", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("settings.usage")
            } header: {
                Text("AI")
            } footer: {
                Text(MobileKeyScreenCopy.aiFooter)
            }

            Section("About") {
                Link(destination: URL(string: "https://foreverlm.com/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("settings.privacyPolicy")

                Link(destination: URL(string: "https://foreverlm.com/support.html")!) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("settings.support")
            }

            Section {
                Button {
                    showsSignOutConfirmation = true
                } label: {
                    Text("Sign Out")
                }
                .accessibilityIdentifier("settings.signOut")
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Text("Delete Account")
                }
                .accessibilityIdentifier("settings.deleteAccount")
            } header: {
                Text("Account")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        // What deleting takes and keeps is said here, where it is decided;
        // it is not a footer under the button.
        .confirmationDialog(
            "Permanently delete your account?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                showsDeleteAuthorization = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your AI account, any leftover balance, usage history and saved billing profile are deleted; your iCloud library is kept. Apple confirms it, and it cannot be undone.")
        }
        .confirmationDialog(
            "Sign out of ForeverLM?",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out") {
                Task { await account.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your library stays in iCloud and your account is kept. Sign in with Apple to come back to it.")
        }
        .sheet(isPresented: $showsDeleteAuthorization) {
            MobileAccountDeletionAuthorizationView {
                account.didDeleteAccount()
            }
        }
        .task {
            do {
                denyDataCollection = try await MobileModelPreferenceStore.shared
                    .valueOrDefault(for: Prefs.AIPolicy.denyDataCollection) ?? false
            } catch {
                dataPolicyError = error.localizedDescription
            }
        }
        .task {
            do {
                prepareDailyReview = try await MobileModelPreferenceStore.shared
                    .valueOrDefault(for: Prefs.Memory.dailyPreparationEnabled)
                if let minutes = try await MobileModelPreferenceStore.shared
                    .valueOrDefault(for: Prefs.Memory.budgetMinutes) {
                    reviewBudgetMinutes = MemoryReviewBudget.clamp(minutes)
                }
            } catch {
                memorySettingsError = error.localizedDescription
            }
        }
        .task {
            do {
                let stored = try await MobileModelPreferenceStore.shared
                    .valueOrDefault(for: Prefs.ReadAloud.voiceModeVoice)
                MobileRealtimeVoicePick.remember(stored)
                voiceModeVoice = RealtimeVoiceDefaults.resolvedVoice(stored)
            } catch {
                voiceModeError = error.localizedDescription
            }
        }
        .task { await offline.refreshUsage() }
    }


    /// What this phone did about today's review.
    private var memoryPreparationStatus: String {
        let today = DailyReviewPreparationTiming.dayKey(for: Date())
        guard reviewScheduler.lastAttemptDay == today else { return "Not prepared on this phone yet" }
        if let message = reviewScheduler.lastAttemptMessage, !message.isEmpty {
            return "Tried today: \(message)"
        }
        return "Prepared today"
    }

    /// Voice mode's voice, written through to the account row; a failed write
    /// puts the pick back and says why.
    private var voiceModeVoiceBinding: Binding<String> {
        Binding(
            get: { voiceModeVoice },
            set: { picked in
                let previous = voiceModeVoice
                voiceModeVoice = picked
                Task {
                    do {
                        try await MobileModelPreferenceStore.shared.set(
                            picked,
                            for: Prefs.ReadAloud.voiceModeVoice
                        )
                        MobileRealtimeVoicePick.remember(picked)
                        voiceModeError = nil
                    } catch {
                        voiceModeVoice = previous
                        voiceModeError = error.localizedDescription
                    }
                }
            }
        )
    }

    /// The data-policy switch, written through to the account row the Mac
    /// reads; a failed write puts the switch back and says why.
    private var denyDataCollectionBinding: Binding<Bool> {
        Binding(
            get: { denyDataCollection },
            set: { enabled in
                denyDataCollection = enabled
                Task {
                    do {
                        try await MobileModelPreferenceStore.shared.set(
                            enabled,
                            for: Prefs.AIPolicy.denyDataCollection
                        )
                        dataPolicyError = nil
                    } catch {
                        denyDataCollection = !enabled
                        dataPolicyError = error.localizedDescription
                    }
                }
            }
        )
    }

    /// Writes through to the synced row; a failed write puts the switch back
    /// and says why, rather than showing a setting the account never received.
    private var prepareDailyReviewBinding: Binding<Bool> {
        Binding(
            get: { prepareDailyReview },
            set: { enabled in
                prepareDailyReview = enabled
                Task {
                    do {
                        try await MobileModelPreferenceStore.shared.set(
                            enabled,
                            for: Prefs.Memory.dailyPreparationEnabled
                        )
                        memorySettingsError = nil
                        // The daily quiz reminder stays on either way
                        // (`MobileMemoryReviewScheduler.ensureDailyReminder`).
                        reviewScheduler.scheduleNextRefresh()
                    } catch {
                        prepareDailyReview = !enabled
                        memorySettingsError = error.localizedDescription
                    }
                }
            }
        )
    }

    /// The daily budget, written through to the synced row the same way; a
    /// failed write puts the previous value back and says why.
    private var reviewBudgetBinding: Binding<Int> {
        Binding(
            get: { reviewBudgetMinutes },
            set: { minutes in
                let previous = reviewBudgetMinutes
                reviewBudgetMinutes = minutes
                Task {
                    do {
                        try await MobileModelPreferenceStore.shared.set(
                            MemoryReviewBudget.clamp(minutes),
                            for: Prefs.Memory.budgetMinutes
                        )
                        memorySettingsError = nil
                        // Today's cards (and the widget's count) follow the
                        // new minutes at once.
                        await MobileAudioReviewViewModel.shared.memoryReviewBudgetDidChange(to: minutes)
                    } catch {
                        reviewBudgetMinutes = previous
                        memorySettingsError = error.localizedDescription
                    }
                }
            }
        )
    }
}

/// The focused destination opened from a reader's Listen button. It keeps the
/// model and exact voice together, without making the learner hunt through the
/// unrelated settings above them.
struct MobileTextToSpeechSettingsView: View {
    var body: some View {
        List {
            Section {
                MobileTextToSpeechSettingsControls()
            } footer: {
                Text("The voice applies to new audio. Automatically continuing books generates missing chapters, billed to your OpenRouter key.")
            }
        }
        .navigationTitle("Text to Speech")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileTextToSpeechSettingsControls: View {
    @ObservedObject private var textToSpeech = ArticleSpeechPreferences.shared
    @AppStorage(Prefs.Mobile.automaticallyContinuesBooks)
    private var automaticallyContinuesBooks: Bool
    @AppStorage(Prefs.Mobile.hasAskedToAutomaticallyContinueBooks)
    private var hasChosenBookContinuation: Bool
    @State private var preferenceSyncError: String?
    @State private var suppressedCostModelIDs: Set<String> = []
    /// The account did not take or give the model pick; shown under the
    /// picker so a pick that never reached the Mac is not mistaken for one.
    @State private var selectionSyncError: String?
    /// Where the model list stands with OpenRouter's speech directory, which
    /// is what it lists: every speech model OpenRouter serves.
    @State private var speechDirectory: OpenRouterAudioDirectory.ReadState = .reading
    @StateObject private var pickTest = MobileTextToSpeechPickTest()

    var body: some View {
        Group {
        NavigationLink {
            MobileTextToSpeechModelListView(
                selectedModelID: textToSpeech.modelID,
                pickTest: pickTest,
                select: { modelBinding.wrappedValue = $0 }
            )
        } label: {
            LabeledContent(
                "Model",
                value: ArticleSpeechCatalog.model(id: textToSpeech.modelID)?.name
                    ?? textToSpeech.modelID
            )
        }
        .accessibilityIdentifier("settings.readAloudModel")

        MobileTextToSpeechPickTestStatus(test: pickTest)

        switch speechDirectory {
        case .read:
            EmptyView()
        case .reading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Reading OpenRouter's speech models…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(ArticleSpeechCatalog.isDirectoryBacked
                     ? "\(message) Showing the list from the last read."
                     : "\(message) Showing the models this version of ForeverLM knows.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task { await readSpeechDirectory(force: true) }
                }
                .font(.footnote)
            }
        }

        if !ArticleSpeechCatalog.voices(forModel: textToSpeech.modelID).isEmpty {
            NavigationLink {
                MobileTextToSpeechVoiceListView(modelID: textToSpeech.modelID)
            } label: {
                LabeledContent("Voice", value: textToSpeech.voiceName(forModel: textToSpeech.modelID))
            }
            .accessibilityIdentifier("settings.readAloudVoice")
        }

        if let selectionSyncError {
            Text(selectionSyncError)
                .font(.footnote)
                .foregroundStyle(.red)
        }

        Toggle("Confirm cost for this model", isOn: confirmsSelectedModelCostBinding)
            .accessibilityIdentifier("settings.confirmReadAloudCost")

        Toggle("Automatically continue books", isOn: $automaticallyContinuesBooks)
            .accessibilityHint("Generates missing audio for the next chapter, then starts it.")
            .accessibilityIdentifier("settings.automaticallyContinueBooks")
            .onChange(of: automaticallyContinuesBooks) { _, _ in
                hasChosenBookContinuation = true
            }

        if let preferenceSyncError {
            Text(preferenceSyncError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
        }
        .task {
            // The list is OpenRouter's speech directory, read again when the
            // last read is stale; the pick is checked against it below.
            await readSpeechDirectory(force: false)
            // The pick follows the account: a model chosen on the Mac shows
            // here, and the pick made here is written back below.
            do {
                try await textToSpeech.refreshFromAccount()
                selectionSyncError = nil
            } catch {
                selectionSyncError = error.localizedDescription
            }
        }
        .task {
            await ArticleSpeechVoicePreviewRepository.shared.startPrewarming(
                prioritizedModelID: textToSpeech.modelID
            )
            do {
                let suppressed = try await MobileModelPreferenceStore.shared
                    .valueOrDefault(for: Prefs.ReadAloud.costConfirmationSuppressedModels) ?? []
                suppressedCostModelIDs = Set(suppressed)
                UserDefaults.standard.set(
                    suppressed.sorted(),
                    forKey: Prefs.ReadAloud.costConfirmationSuppressedModels.name
                )
                preferenceSyncError = nil
            } catch {
                preferenceSyncError = error.localizedDescription
            }
        }
        .onChange(of: textToSpeech.modelID) { _, modelID in
            Task {
                await ArticleSpeechVoicePreviewRepository.shared.startPrewarming(
                    prioritizedModelID: modelID
                )
            }
        }
    }

    /// Reads OpenRouter's speech directory off the main actor (a fresh read
    /// answers at once) and re-reads the stored pick against it.
    private func readSpeechDirectory(force: Bool) async {
        speechDirectory = .reading
        do {
            try await OpenRouterAudioDirectory.refresh(.speech, force: force)
            speechDirectory = .read
        } catch {
            speechDirectory = .failed(error.localizedDescription)
        }
        // A pick the list no longer offers is repaired as opening Settings
        // repairs it on the Mac, and the repair becomes the account's pick.
        let repaired = ArticleSpeechSelection.repairStoredPick() != nil
        textToSpeech.reloadFromStorage()
        if repaired { pushSelectionToAccount() }
    }

    private var confirmsSelectedModelCostBinding: Binding<Bool> {
        Binding(
            get: {
                MobileTextToSpeechPricingPreferences.confirmsEstimatedCost
                    && !suppressedCostModelIDs.contains(textToSpeech.modelID)
            },
            set: { confirms in
                if confirms {
                    Preferences.set(true, for: Prefs.Mobile.readAloudConfirmsEstimatedCost)
                }
                let updated = TextToSpeechCostConfirmationPreferences.updatedSuppressedModelIDs(
                    suppressedCostModelIDs,
                    confirms: confirms,
                    modelID: textToSpeech.modelID
                )
                suppressedCostModelIDs = Set(updated)
                UserDefaults.standard.set(
                    updated,
                    forKey: Prefs.ReadAloud.costConfirmationSuppressedModels.name
                )
                Task {
                    do {
                        try await MobileModelPreferenceStore.shared.set(
                            updated,
                            for: Prefs.ReadAloud.costConfirmationSuppressedModels
                        )
                        preferenceSyncError = nil
                    } catch {
                        preferenceSyncError = error.localizedDescription
                    }
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { textToSpeech.modelID },
            set: { modelID in
                guard modelID != textToSpeech.modelID else { return }
                // The picker shows the old pick until the new one passes.
                pickTest.run(model: modelID, voice: textToSpeech.voiceID(forModel: modelID) ?? "") {
                    textToSpeech.selectModel(modelID)
                    pushSelectionToAccount()
                }
            }
        )
    }

    /// Writes the pick through to the account rows the Mac reads. The local
    /// pick stands either way; a failed write is said, not hidden.
    private func pushSelectionToAccount() {
        Task {
            do {
                try await textToSpeech.pushToAccount()
                selectionSyncError = nil
            } catch {
                selectionSyncError = error.localizedDescription
            }
        }
    }
}

/// A fresh Apple authorization yields the one-time code the server must
/// exchange and revoke before erasing the account. Keeping this as a native
/// Sign in with Apple action makes it both explicit and phishing-resistant.
private struct MobileAccountDeletionAuthorizationView: View {
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.badge.minus")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)

                Text("Confirm with Apple")
                    .font(.title2.bold())

                Text("Apple confirmation revokes ForeverLM’s sign-in access before your account data is erased.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = []
                } onCompletion: { result in
                    authorizeDeletion(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .disabled(isDeleting || !AppleSignInSupport.hasRequiredEntitlement)
                .accessibilityIdentifier("accountDeletion.confirmWithApple")

                if isDeleting {
                    ProgressView("Deleting account…")
                        .controlSize(.small)
                }

                if let errorMessage = errorMessage ?? AppleSignInSupport.preflightMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
    }

    @MainActor
    private func authorizeDeletion(_ result: Result<ASAuthorization, Error>) {
        if let message = AppleSignInSupport.preflightMessage {
            errorMessage = message
            return
        }

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityData = credential.identityToken,
                  let identityToken = String(data: identityData, encoding: .utf8),
                  let codeData = credential.authorizationCode,
                  let authorizationCode = String(data: codeData, encoding: .utf8) else {
                errorMessage = "Apple didn’t return the confirmation needed to delete this account. Try again."
                return
            }
            isDeleting = true
            errorMessage = nil
            Task {
                defer { isDeleting = false }
                do {
                    try await ManagedAI.deleteAccount(
                        identityToken: identityToken,
                        authorizationCode: authorizationCode
                    )
                    onDeleted()
                    dismiss()
                } catch let error as ManagedAI.ServiceError {
                    errorMessage = error.message
                } catch {
                    errorMessage = "Couldn’t delete the account. Check your connection and try again."
                }
            }
        case .failure(let error):
            errorMessage = AppleSignInSupport.userMessage(for: error)
        }
    }
}

/// The phone's key screen (product owner, 2026-09-25): AI features run on the
/// learner's own OpenRouter key, for every account (the app is free; only MCP
/// is paid for, and the phone has none). The phone stores the key and shows
/// any leftover balance. The
/// iPhone app is a free companion to the Mac app (product owner, 2026-10-10; App
/// Review 3.1.3(f)): it sells nothing, and nothing on it names a price, a place
/// to buy, or a link that leads to one, so Stripe's billing pages and buying
/// OpenRouter credits stay on the Mac.
private struct MobileCreditsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var balance: ManagedAI.Balance?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastRefreshAt: Date?
    @State private var ownKey: ManagedAI.OwnKey?
    @State private var ownKeyLoaded = false
    @State private var ownKeyRouter: ManagedAI.OwnKeyRouter = .openRouter
    @State private var ownKeyDraft = ""
    @State private var ownKeySaving = false

    var body: some View {
        List {
            ownKeySection
            MobileRealtimeVoiceOwnKeySection()
            if showsBalanceSection {
                balanceSection
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("credits.error")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(MobileKeyScreenCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task {
            async let balanceLoad: Void = refresh()
            async let ownKeyLoad: Void = loadOwnKey()
            _ = await (balanceLoad, ownKeyLoad)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh(minimumInterval: 2, silently: true) }
        }
    }

    /// The learner's own OpenRouter key: OpenRouter bills them directly, at
    /// cost. The same iCloud Keychain item the Mac writes.
    private var ownKeySection: some View {
        Section {
            if let ownKey {
                LabeledContent("\(ownKey.router.label) key", value: "•••• \(ownKey.suffix)")
                    .accessibilityIdentifier("credits.ownKey.current")
                Button("Remove key", role: .destructive) {
                    Task { await saveOwnKey("", router: ownKey.router) }
                }
                .disabled(ownKeySaving)
                .accessibilityIdentifier("credits.ownKey.remove")
            } else if !ownKeyLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Reading your key")
            }

            SecureField("Paste your \(ownKeyRouter.label) key", text: $ownKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { Task { await saveOwnKey(ownKeyDraft, router: ownKeyRouter) } }
                .accessibilityIdentifier("credits.ownKey.field")

            Button {
                Task { await saveOwnKey(ownKeyDraft, router: ownKeyRouter) }
            } label: {
                HStack {
                    Text(ownKey == nil ? "Save key" : "Replace key")
                    if ownKeySaving {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownKeySaving)
            .accessibilityIdentifier("credits.ownKey.save")

            Link(ownKeyRouter.keysLinkTitle, destination: ownKeyRouter.keysURL)

            Text(ownKeyRouter.aboutNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(ownKeyRouter.trainingNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("credits.ownKey.training")
            Text(AIDataPolicy.openRouterAccountNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Open OpenRouter privacy settings", destination: AIFreeModels.openRouterPrivacyURL)
                .accessibilityIdentifier("credits.ownKey.openRouterPrivacy")

            Label(ownKeyRouter.keyPrivacyNote, systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("credits.ownKey.privacy")
        } header: {
            Text("API keys")
        } footer: {
            Text("AI features run on your OpenRouter API key, billed by OpenRouter at cost. Right now ForeverLM supports OpenRouter. The key covers chat, reviews and background tasks, and every voice, speech-to-text, image and video model OpenRouter serves. The key is kept in your iCloud Keychain and shared with your Mac.")
        }
    }

    private func loadOwnKey() async {
        let stored = await Task.detached(priority: .userInitiated) { ManagedAI.ownKey }.value
        ownKey = stored
        if let stored { ownKeyRouter = stored.router }
        ownKeyLoaded = true
    }

    @MainActor
    private func saveOwnKey(_ key: String, router: ManagedAI.OwnKeyRouter) async {
        guard !ownKeySaving else { return }
        ownKeySaving = true
        errorMessage = nil
        defer { ownKeySaving = false }
        let stored = await Task.detached(priority: .userInitiated) {
            ManagedAI.setOwnKey(key, router: router)
            return ManagedAI.ownKey
        }.value
        ownKey = stored
        ownKeyDraft = ""
        await refresh(silently: true)
    }

    /// Balance is not sold, so the section shows
    /// only while some is left, or for a comped or disabled account.
    private var showsBalanceSection: Bool {
        guard let balance else { return false }
        return balance.microUSD > 0 || balance.billingExempt || balance.disabled
    }

    private var balanceSection: some View {
        Section {
            if let balance {
                LabeledContent("Balance left") {
                    Text(ManagedAI.creditBalanceText(microUSD: balance.microUSD))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("credits.balance")
                }

                if balance.disabled {
                    Label("Account disabled", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if balance.billingExempt {
                    // Otherwise the figure above looks like a balance that stopped
                    // moving for no reason.
                    Label(compLabel, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if balance?.billingExempt != true {
                Text(ownKey == nil
                    ? "Spent on requests sent without your key until it runs out."
                    : "Not spent while your \(ownKeyRouter.label) key is stored: the key pays for every model.")
            }
        }
    }

    /// A comped tester needs to know why the figure above never moves.
    private var compLabel: String {
        "Usage is paid for by ForeverLM on this account"
    }

    @MainActor
    private func refresh(minimumInterval: TimeInterval = 0, silently: Bool = false) async {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < minimumInterval {
            return
        }
        guard !isLoading else { return }

        isLoading = true
        if !silently { errorMessage = nil }
        defer { isLoading = false }

        do {
            balance = try await ManagedAI.balance()
            lastRefreshAt = Date()
        } catch is CancellationError {
            return
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }
}

/// App-level recovery for any managed-AI operation that found nothing to pay
/// with: no own key and no leftover balance. The key is added in Settings; the
/// phone is a free companion, so it names no plan price and no place to buy.
struct MobileCreditsRequiredSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.large) {
            Spacer(minLength: 0)

            Image(systemName: "key.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 58, height: 58)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(spacing: MobileDesign.Spacing.small) {
                Text("Add your OpenRouter key")
                    .font(.title2.weight(.semibold))

                Text(MobileKeyScreenCopy.creditsRequired)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("OK") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("creditsRequired.dismiss")

            Spacer(minLength: 0)
        }
        .padding(MobileDesign.Spacing.xLarge)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// The phone's one-screen Settings has no room for the Mac's Data & Privacy
/// pane, so the switch's section carries the same facts in a footer: the
/// library is in the learner's own iCloud, the proxy's ledger holds no prompt
/// text, an MCP tool call is not logged, and the
/// first-party providers do not train on API traffic. These are privacy
/// consequences, so the one-clause rule for footers keeps them whole
/// (AGENTS.md, "Settings holds only what a learner changes"), and every client
/// says them (settings-data-privacy.test.ts).
enum MobileDataPrivacyCopy {
    static let footer: String =
        "Your sources, chats, reviews and history live in your own iCloud; ForeverLM keeps no copy. "
        + "AI requests pass through ForeverLM's proxy, which bills tokens and cost and never stores the prompt or the answer. "
        + "MCP tool calls are not logged. "
        + "Anthropic, OpenAI, Google's paid API and xAI do not train on API traffic. "
        + AIDataPolicy.switchExplanation
}

/// One text-to-speech model row. The displayed rate is an estimate from the same
/// versioned pricing table used for local usage estimates; the server ledger
/// records the exact managed charge after generation.
private struct MobileTextToSpeechModelOptionRow: View {
    let model: ArticleSpeechModelOption

    var body: some View {
        // Keep name and price in one label so every row is compact and VoiceOver
        // reads the same cost a sighted learner sees.
        Text(optionLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(optionLabel)
            .accessibilityValue(model.summary)
            .accessibilityIdentifier("settings.readAloudModel.\(model.id)")
    }

    /// OpenRouter's price in the unit it bills the model by ("$15 / 1M
    /// characters", "$1 / $20 per 1M tokens"), or "Price unknown": a model
    /// shown without a price reads as free.
    private var optionLabel: String {
        "\(model.name) · \(model.priceLabel)"
    }
}

/// A real scrolling destination for the live speech directory. A compact
/// `Picker` becomes a menu on iPhone; once OpenRouter's list outgrew the
/// screen, that menu stopped accepting a drag before its last models could be
/// reached. `List` owns the scroll gesture and preserves the same grouped
/// maker hierarchy and test-before-selecting contract.
private struct MobileTextToSpeechModelListView: View {
    let selectedModelID: String
    @ObservedObject var pickTest: MobileTextToSpeechPickTest
    let select: (String) -> Void

    var body: some View {
        List {
            ForEach(modelGroups, id: \.maker) { group in
                Section(group.maker) {
                    ForEach(group.models) { model in
                        Button {
                            select(model.id)
                        } label: {
                            HStack(spacing: 12) {
                                MobileTextToSpeechModelOptionRow(model: model)
                                Spacer(minLength: 8)
                                if selectedModelID == model.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(pickTest.testing != nil)
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.readAloudModelList")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            MobileTextToSpeechPickTestStatus(test: pickTest)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private var modelGroups: [(maker: String, models: [ArticleSpeechModelOption])] {
        var order: [String] = []
        var grouped: [String: [ArticleSpeechModelOption]] = [:]
        for model in ArticleSpeechCatalog.models {
            if grouped[model.maker] == nil { order.append(model.maker) }
            grouped[model.maker, default: []].append(model)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

@MainActor
private final class MobileTextToSpeechVoicePreviewService: NSObject, ObservableObject {
    nonisolated static let sampleText = ArticleSpeechVoicePreviewRepository.sampleText

    @Published private(set) var loadingKey: String?
    @Published private(set) var playingKey: String?
    @Published private(set) var lastError: String?

    private var generationTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    func isLoading(modelID: String, voiceID: String) -> Bool {
        loadingKey == Self.selectionKey(modelID: modelID, voiceID: voiceID)
    }

    func isPlaying(modelID: String, voiceID: String) -> Bool {
        playingKey == Self.selectionKey(modelID: modelID, voiceID: voiceID)
    }

    func toggle(modelID: String, voiceID: String) {
        let selectionKey = Self.selectionKey(modelID: modelID, voiceID: voiceID)
        if playingKey == selectionKey {
            stop()
            return
        }

        stop()
        lastError = nil
        loadingKey = selectionKey
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if loadingKey == selectionKey { loadingKey = nil }
                generationTask = nil
            }

            do {
                let audio = try await ArticleSpeechVoicePreviewRepository.shared.audio(
                    modelID: modelID,
                    voiceID: voiceID
                )

                try Task.checkCancellation()
                try play(audio, selectionKey: selectionKey)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        loadingKey = nil
        playingKey = nil
    }

    private func play(_ data: Data, selectionKey: String) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        playingKey = selectionKey
        guard player.play() else {
            audioPlayer = nil
            playingKey = nil
            throw CloudArticleTTS.GenerationError.badResponse("The voice sample could not be played.")
        }
    }

    nonisolated private static func selectionKey(modelID: String, voiceID: String) -> String {
        "\(modelID)|\(voiceID)"
    }
}

/// A text-to-speech pick under its test run, and the line a refused one
/// leaves, as Settings › Voice runs it on the Mac. A model or voice becomes
/// the pick only once the pair has passed `CloudArticleTTS.testBeforeSelecting`:
/// at once when it already has, after one short synthesis otherwise. A
/// refusal keeps the previous pick and says why in place; the model stays in
/// the list, and choosing it again tests it again. A free model whose test
/// could not finish is applied and tested when next used.
@MainActor
private final class MobileTextToSpeechPickTest: ObservableObject {
    struct Pick: Equatable {
        let model: String
        let voice: String
    }

    @Published private(set) var testing: Pick?
    @Published private(set) var refusal: String?

    func run(model: String, voice: String, apply: @escaping () -> Void) {
        guard testing == nil else { return }
        refusal = nil
        if AIModelQualification.speechStatus(model: model, voice: voice) == .passed {
            apply()
            return
        }
        testing = Pick(model: model, voice: voice)
        Task {
            // The test reads the Keychain and waits on the network.
            let verdict = await Task.detached(priority: .userInitiated) {
                await CloudArticleTTS.testBeforeSelecting(model: model, voice: voice)
            }.value
            testing = nil
            if verdict == .go {
                apply()
            } else {
                refusal = AIModelQualification.speechRefusalText(
                    name: ArticleSpeechCatalog.selectionLabel(model: model, voice: voice),
                    verdict: verdict
                )
            }
        }
    }
}

/// "Testing …" while a pick's test runs, and the one line a refused pick
/// leaves, under the list it was chosen from.
private struct MobileTextToSpeechPickTestStatus: View {
    @ObservedObject var test: MobileTextToSpeechPickTest

    var body: some View {
        if let testing = test.testing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing \(ArticleSpeechCatalog.selectionLabel(model: testing.model, voice: testing.voice))…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings.readAloudPickTesting")
        } else if let refusal = test.refusal {
            Text(refusal)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings.readAloudPickRefusal")
        }
    }
}

/// One text-to-speech model's voices, each with a short sample generated through
/// the same managed speech model used for source narration.
private struct MobileTextToSpeechVoiceListView: View {
    let modelID: String

    /// A voice conversation holds the audio; a sample would end it.
    @ObservedObject private var realtime = MobileRealtimeVoice.controller
    @ObservedObject private var textToSpeech = ArticleSpeechPreferences.shared
    @StateObject private var preview = MobileTextToSpeechVoicePreviewService()
    @StateObject private var pickTest = MobileTextToSpeechPickTest()
    @State private var ratings: [String: ArticleSpeechVoiceRating] = [:]
    @State private var ratingError: String?
    @State private var selectionSyncError: String?

    var body: some View {
        List {
            Section {
                ForEach(ArticleSpeechCatalog.voices(forModel: modelID)) { voice in
                    HStack(spacing: 12) {
                        Button {
                            guard textToSpeech.voiceID(forModel: modelID) != voice.id else { return }
                            pickTest.run(model: modelID, voice: voice.id) {
                                textToSpeech.selectVoice(voice.id, forModel: modelID)
                                Task {
                                    do {
                                        try await textToSpeech.pushToAccount()
                                        selectionSyncError = nil
                                    } catch {
                                        selectionSyncError = error.localizedDescription
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(textToSpeech.voiceID(forModel: modelID) == voice.id ? 1 : 0)
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ArticleSpeechCatalog.voiceSettingsLabel(
                                        model: textToSpeech.modelID,
                                        voice: voice.id
                                    ))
                                    if let detail = voice.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            textToSpeech.voiceID(forModel: modelID) == voice.id ? [.isSelected] : []
                        )
                        .accessibilityIdentifier("settings.readAloudVoice.\(voice.id)")

                        ratingButton(.up, voice: voice, systemImage: "hand.thumbsup")
                        ratingButton(.down, voice: voice, systemImage: "hand.thumbsdown")

                        Button {
                            preview.toggle(modelID: modelID, voiceID: voice.id)
                        } label: {
                            if preview.isLoading(modelID: modelID, voiceID: voice.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 22)
                            } else {
                                Image(systemName: preview.isPlaying(modelID: modelID, voiceID: voice.id)
                                    ? "stop.fill"
                                    : "play.fill")
                                    .frame(width: 22)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(realtime.isActive)
                        .accessibilityLabel(
                            preview.isPlaying(modelID: modelID, voiceID: voice.id)
                                ? "Stop sample"
                                : "Play \(voice.name) sample"
                        )
                        .accessibilityIdentifier("settings.previewReadAloudVoice.\(voice.id)")
                    }
                }
            } footer: {
                Text("Voice samples prepare in the background and replay from this device.")
            }

            if pickTest.testing != nil || pickTest.refusal != nil {
                Section {
                    MobileTextToSpeechPickTestStatus(test: pickTest)
                }
            }

            if let error = preview.lastError {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let ratingError {
                Section {
                    Text(ratingError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let selectionSyncError {
                Section {
                    Text(selectionSyncError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(ArticleSpeechCatalog.model(id: modelID)?.name ?? "Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { preview.stop() }
        .task { await loadRatings() }
    }

    private func ratingButton(
        _ rating: ArticleSpeechVoiceRating,
        voice: ArticleSpeechVoice,
        systemImage: String
    ) -> some View {
        Button {
            setRating(rating, voiceID: voice.id)
        } label: {
            Image(systemName: ratings[voice.id] == rating ? "\(systemImage).fill" : systemImage)
                .foregroundStyle(ratings[voice.id] == rating ? Color.accentColor : .secondary)
                .frame(width: 22)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(rating == .up ? "Like \(voice.name)" : "Dislike \(voice.name)")
        .accessibilityAddTraits(ratings[voice.id] == rating ? .isSelected : [])
    }

    @MainActor
    private func setRating(_ rating: ArticleSpeechVoiceRating, voiceID: String) {
        ratings[voiceID] = rating
        ratingError = nil
        let key = Prefs.Families.voiceRating.key("\(modelID)|\(voiceID)")
        UserDefaults.standard.set(rating.rawValue, forKey: key.name)
        Task {
            do {
                try await MobileModelPreferenceStore.shared.set(rating.rawValue, for: key)
            } catch {
                ratingError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadRatings() async {
        let modelID = modelID
        let voiceIDs = ArticleSpeechCatalog.voices(forModel: modelID).map(\.id)
        for voiceID in voiceIDs {
            let key = Prefs.Families.voiceRating.key("\(modelID)|\(voiceID)")
            if let local = UserDefaults.standard.string(forKey: key.name)
                .flatMap(ArticleSpeechVoiceRating.init(rawValue:)) {
                ratings[voiceID] = local
            }
        }
        // One account row per voice, and a model from OpenRouter's directory
        // can list ninety voices: read them a few at a time rather than one
        // after another.
        await withTaskGroup(of: (String, Result<String?, Error>).self) { group in
            var pending = voiceIDs.makeIterator()
            func enqueue() {
                guard let voiceID = pending.next() else { return }
                let key = Prefs.Families.voiceRating.key("\(modelID)|\(voiceID)")
                group.addTask {
                    // Bound before the tuple: see AGENTS.md on tuples around an await in a task.
                    let result: Result<String?, Error>
                    do {
                        let raw = try await MobileModelPreferenceStore.shared.valueOrDefault(for: key)
                        result = .success(raw)
                    } catch {
                        result = .failure(error)
                    }
                    return (voiceID, result)
                }
            }
            for _ in 0..<6 { enqueue() }
            while let (voiceID, result) = await group.next() {
                switch result {
                case .success(let raw):
                    if let raw, let remote = ArticleSpeechVoiceRating(rawValue: raw) {
                        ratings[voiceID] = remote
                        UserDefaults.standard.set(
                            raw,
                            forKey: Prefs.Families.voiceRating.key("\(modelID)|\(voiceID)").name
                        )
                    }
                    enqueue()
                case .failure(let error):
                    ratingError = error.localizedDescription
                    group.cancelAll()
                    return
                }
            }
        }
    }
}

extension MobileTextToSpeechVoicePreviewService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.audioPlayer = nil
            self?.playingKey = nil
        }
    }
}

/// The key screen's words (product owner, 2026-10-10): the screen is "Key"
/// and names no plan.
enum MobileKeyScreenCopy {
    static let title = "Key"

    static let aiFooter = "AI runs on your OpenRouter API key, at OpenRouter's cost. ForeverLM adds nothing."

    static let creditsRequired = "AI features run on your own OpenRouter API key. Add your key in Settings › Key."
}

/// The learner's own OpenAI key for voice mode (product owner, 2026-11-08),
/// the same iCloud Keychain item the Mac writes. With one, voice sessions open
/// straight with OpenAI on it and OpenAI bills the learner; without one, voice
/// runs on ForeverLM's OpenAI account. Checked with OpenAI before it is stored.
struct MobileRealtimeVoiceOwnKeySection: View {
    @State private var suffix: String?
    @State private var loaded = false
    @State private var draft = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if let suffix {
                LabeledContent("OpenAI key", value: "•••• \(suffix)")
                    .accessibilityIdentifier("voice.ownKey.current")
                Button("Remove key", role: .destructive) {
                    Task { await store("") }
                }
                .disabled(saving)
            } else if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Reading your key")
            }

            SecureField("Paste your OpenAI API key", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { Task { await store(draft) } }
                .accessibilityIdentifier("voice.ownKey.field")

            Button {
                Task { await store(draft) }
            } label: {
                HStack {
                    Text(suffix == nil ? "Save key" : "Replace key")
                    if saving {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)

            Link("Get an OpenAI key", destination: ManagedAI.ownOpenAIVoiceKeysURL)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Voice mode")
        } footer: {
            Text("Voice mode runs on ForeverLM's OpenAI account unless you add your own OpenAI API key. With yours, OpenAI bills you for voice, and ForeverLM's daily limit on voice sessions no longer applies. The key is kept in your iCloud Keychain, shared with your Mac, and sent only to OpenAI.")
        }
        .task { await load() }
    }

    private func load() async {
        suffix = await Task.detached(priority: .userInitiated) {
            ManagedAI.reloadOwnOpenAIVoiceKey()
            return ManagedAI.ownOpenAIVoiceKeySuffix
        }.value
        loaded = true
    }

    @MainActor
    private func store(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        if !key.isEmpty {
            do {
                if case .rejected(let reason) = try await ManagedAI.checkOwnOpenAIVoiceKey(key) {
                    errorMessage = reason
                    return
                }
            } catch {
                errorMessage = "Couldn't check the key with OpenAI: \(error.localizedDescription)"
                return
            }
        }
        await Task.detached(priority: .userInitiated) { ManagedAI.setOwnOpenAIVoiceKey(key) }.value
        draft = ""
        await load()
    }
}
