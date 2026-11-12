// The model choices page of Getting Started.
import AppKit
import SwiftUI

/// Setup's models page (product owner, 2026-09-28, then 2026-10-11): the whole
/// set in one step (`RecommendedModels`) on one card, with the rest behind
/// "Choose my own". What it would take is read when the page appears and said
/// before it is taken. Free models run only once OpenRouter's privacy settings
/// allow them, so a refusal is the one thing the page raises, and Continue
/// waits for it.
struct GettingStartedModelsPage: View {
    @Binding var isReady: Bool

    @State private var choice: RecommendedModels.Choice?
    @State private var loadError: String?
    @State private var isApplied = false
    @State private var working = false
    @State private var applyError: String?
    /// Nil until checked, or while a check runs.
    @State private var access: FreeModelAccess.Verdict?
    @State private var isChecking = false
    @State private var choosingMyself = false
    /// The Background rows' word, for the learner who chooses their own.
    @State private var ownChoiceReady = true

    var body: some View {
        VStack(spacing: 24) {
            // "We chose these" names the recommended set, so it goes once the
            // learner is choosing their own.
            SetupStepHeading(
                icon: "sparkles",
                title: "Pick your models",
                detail: choosingMyself
                    ? "One for chat, one for the work ForeverLM does on its own. Change them any time in Settings."
                    : "We chose these for you. Change them any time in Settings."
            )

            if choosingMyself {
                ownChoice
            } else {
                recommended
            }

            VStack(spacing: 6) {
                if !choosingMyself {
                    Text("ForeverLM also runs AI on its own, on transcripts, read-aloud and titles.")
                }
                Link(ManagedAI.OwnKeyRouter.openRouter.creditsLinkTitle, destination: ManagedAI.OwnKeyRouter.openRouter.creditsURL)
                    .accessibilityIdentifier("gettingStarted.openRouterCredits")
                    .help("Free models answer 50 requests a day until you have bought $10 of credits in total, then 1,000.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .task {
            await load()
            updateReadiness()
        }
        .onChange(of: isApplied) { _, _ in
            access = nil
            updateReadiness()
            Task { await checkAccess() }
        }
        .onChange(of: choosingMyself) { _, _ in updateReadiness() }
        .onChange(of: ownChoiceReady) { _, _ in updateReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            Task { await readApplied() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            // The key decides whether background work can start free.
            Task { await load() }
        }
        // Back from OpenRouter's privacy page in the browser.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard isApplied, access != .allowed else { return }
            Task { await checkAccess() }
        }
    }

    // MARK: The recommended set

    @ViewBuilder
    private var recommended: some View {
        if let choice {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    row("Chat", choice.chat.model.name)
                    Divider()
                    row("Background", backgroundName(choice))
                }
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 400)

                if isApplied {
                    appliedStatus
                } else {
                    Button {
                        apply(choice)
                    } label: {
                        Group {
                            if working {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Use these models")
                            }
                        }
                        .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working)
                    .accessibilityIdentifier("gettingStarted.recommendedModels")
                }

                if let applyError {
                    Label(applyError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Choose my own") { choosingMyself = true }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let loadError {
            VStack(spacing: 10) {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Try Again") { Task { await load() } }
                    Button("Choose my own") { choosingMyself = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ role: String, _ name: String) -> some View {
        HStack {
            Text(role)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(name)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func backgroundName(_ choice: RecommendedModels.Choice) -> String {
        choice.freeText == nil ? choice.backup.model.name : "Free, then \(choice.backup.model.name)"
    }

    @ViewBuilder
    private var appliedStatus: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if isChecking {
                    ProgressView().controlSize(.small)
                }
            }
            if access == .refused {
                Text(FreeModelAccess.refusedExplanation)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                HStack(spacing: 14) {
                    Link("Open OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                    Button("Check Again") { Task { await checkAccess() } }
                        .disabled(isChecking)
                }
                .font(.caption)
            } else if case .unknown(let message)? = access {
                Text("Could not check whether OpenRouter allows free models: \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
        }
    }

    // MARK: Choosing their own

    private var ownChoice: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat").font(.headline)
                GettingStartedChatModelChoice()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Background work").font(.headline)
                GettingStartedBackgroundModelChoice(isReady: $ownChoiceReady)
            }
            Button("Use the recommended models") { choosingMyself = false }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    // MARK: Readiness

    /// Continue waits for the set to be taken, and, while background work is
    /// free, for OpenRouter to allow free models. A check that failed for
    /// another reason says so and lets the learner go on.
    private func updateReadiness() {
        if choosingMyself { isReady = ownChoiceReady; return }
        guard isApplied, let choice else { isReady = false; return }
        guard choice.freeText != nil else { isReady = true; return }
        switch access {
        case nil, .refused?: isReady = false
        default: isReady = true
        }
    }

    private func checkAccess() async {
        guard isApplied, !isChecking, let free = choice?.freeText else { return }
        isChecking = true
        access = nil
        updateReadiness()
        let verdict = await Task.detached(priority: .userInitiated) {
            await FreeModelAccess.check(model: free.id)
        }.value
        isChecking = false
        guard isApplied else { return }
        access = verdict
        updateReadiness()
    }

    /// Off the main actor: the directory, the US lists and the free models'
    /// test runs are all network reads.
    private func load() async {
        loadError = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try await RecommendedModels.load()
            }.value
            choice = loaded
            await readApplied()
        } catch {
            choice = nil
            loadError = error.localizedDescription
        }
        updateReadiness()
    }

    /// Keychain reads, so off the main actor.
    private func readApplied() async {
        guard let choice else { return }
        isApplied = await Task.detached(priority: .userInitiated) {
            RecommendedModels.isApplied(choice)
        }.value
    }

    /// The chat model is tested first, as the Chat row tests a pick
    /// (`AIModelQualification`); the set is taken only if it passes.
    private func apply(_ choice: RecommendedModels.Choice) {
        guard !working else { return }
        working = true
        applyError = nil
        Task { @MainActor in
            defer { working = false }
            let chatID = choice.chat.model.id
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: .openRouter, model: chatID, role: .chat)
            }.value
            guard verdict == .go else {
                applyError = AIModelQualification.refusalText(name: choice.chat.model.name, role: .chat, verdict: verdict)
                return
            }
            do {
                try await RecommendedModels.apply(choice)
                await readApplied()
            } catch {
                applyError = error.localizedDescription
            }
        }
    }
}

/// Setup's Chat row (product owner, 2026-09-26): the model new chats start on,
/// from the same catalog as Settings › Chat › Models. Choosing one also
/// offers it in the chat's model picker, as starring a card there does.
private struct GettingStartedChatModelChoice: View {
    @State private var groups: [AIModelCatalog.MakerGroup] = []
    @State private var defaultEntry: AIModelCatalogEntry?
    @State private var testingModelName: String?
    @State private var pickRefusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The model new chats start with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Menu {
                    ForEach(groups, id: \.maker) { group in
                        Menu(group.maker.displayName) {
                            ForEach(group.entries) { entry in
                                Button {
                                    choose(entry)
                                } label: {
                                    HStack {
                                        Text(entry.displayName)
                                        if entry.id == defaultEntry?.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    // The pick shows at once while it is tested; no word
                    // about the test (product owner, 2026-09-27).
                    Text(testingModelName ?? defaultEntry?.displayName ?? "Choose a model")
                        .lineLimit(1)
                }
                .fixedSize()
                .disabled(testingModelName != nil)
                .accessibilityIdentifier("gettingStarted.chatModel")

                if let defaultEntry, let price = AIModelListPrice.label(for: defaultEntry) {
                    Text("\(price) per 1M tokens in / out")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let pickRefusal {
                Label(pickRefusal, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            Task { await load() }
        }
    }

    /// Off the main actor: the stored chat route can reach `KeychainService.load`.
    private func load() async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            let defaultEntry = AIModelCatalog.defaultEntry
            let groups = AIModelCatalog.makerGroups
            return (groups, defaultEntry)
        }.value
        groups = snapshot.0
        defaultEntry = snapshot.1
    }

    /// A model not yet tried for chat is tested first and chosen only if it
    /// passes (`AIModelQualification`).
    private func choose(_ entry: AIModelCatalogEntry) {
        pickRefusal = nil
        guard !AIModelQualification.isPassed(provider: entry.provider, model: entry.modelID, role: .chat) else {
            AIModelCatalog.setDefault(entry)
            defaultEntry = AIModelCatalog.defaultEntry
            return
        }
        testingModelName = entry.displayName
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: entry.provider, model: entry.modelID, role: .chat)
            }.value
            testingModelName = nil
            if verdict == .go {
                AIModelCatalog.setDefault(entry)
                defaultEntry = AIModelCatalog.defaultEntry
            } else {
                pickRefusal = AIModelQualification.refusalText(name: entry.displayName, role: .chat, verdict: verdict)
            }
        }
    }
}

/// Setup's Background work row (product owner, 2026-09-25): what the work ForeverLM
/// does on its own runs on, which is most of what the learner's OpenRouter key
/// pays for. OpenRouter's best free model that can do the work, or the paid
/// one ForeverLM ships with; the same choice sits under Settings › Background.
///
/// Free is the default (product owner, 2026-09-26): background work waits for no
/// one, so a free model's queues and rate limits cost it little. Until the
/// learner picks, the free model is chosen as soon as one can run, which is
/// once the key above is in; a pick made before, here or in Settings, stands.
///
/// A free model runs only once the learner allows free endpoints in their
/// OpenRouter privacy settings, so choosing it is choosing that too: the row
/// checks with one free request (`FreeModelAccess`), says what to turn on when
/// OpenRouter refuses, checks again when the learner comes back to the app,
/// and holds the step until it passes or the paid model is picked.
///
/// With the free model, the row asks about meetings too (product owner,
/// 2026-09-27: "maybe during onboarding when the user sets all the settings;
/// they can choose"). A meeting's transcript holds private conversations, so
/// meetings keep a paid model unless the learner lets them use the free one
/// (`MeetingModels`): the answer is stored, and a meeting task whose
/// Background model is free runs on that model's first paid backup, or the
/// paid model below.
private struct GettingStartedBackgroundModelChoice: View {
    @Binding var isReady: Bool

    private enum Choice: Hashable {
        case free
        case paid
        case other
    }

    /// Seeded from the shipped route; the stored one is read off the main
    /// actor, since it can reach `KeychainService.load`.
    @State private var route = KeychainService.defaultBackgroundTaskRoute
    @State private var freeText: OpenRouterDirectoryModel?
    @State private var freeVision: OpenRouterDirectoryModel?
    /// The next free models for the same work, which become the free
    /// pick's backup models.
    @State private var freeTextBackups: [OpenRouterDirectoryModel] = []
    @State private var freeVisionBackups: [OpenRouterDirectoryModel] = []
    @State private var directoryLoaded = false
    @State private var blocker = FreeModelsSetup.pickBlocker()
    /// Nil until checked, or while a check runs.
    @State private var access: FreeModelAccess.Verdict?
    @State private var isChecking = false
    /// The Meetings answer (`MeetingModels.mayUseFree`, read back): true
    /// keeps the meeting tasks on a paid model while background work is
    /// free, as recommended.
    @State private var meetingsStayPaid = !MeetingModels.mayUseFree
    /// Counts the reads of the settings, so only the newest one is shown.
    @State private var readCount = 0

    private let paid = KeychainService.defaultBackgroundTaskRoute

    private var choice: Choice {
        if AIFreeModels.isFreeSelection(provider: route.provider, model: route.model) { return .free }
        if route.provider == paid.provider, route.model == paid.model { return .paid }
        return .other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kept, in one sentence: Continue on this step is the consent to
            // background work (`aiBackground.usageConsented`), and this is
            // the line that says what is being agreed to.
            Text("ForeverLM also runs AI on its own, on transcripts, read-aloud and titles; a free model is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            option(
                .free,
                title: freeText.map { "Free: \($0.name)" } ?? "Free model",
                detail: freeDetail,
                isEnabled: freeText != nil && blocker == nil
            )

            option(
                .paid,
                title: AIModelCatalog.displayName(provider: paid.provider, modelID: paid.model),
                detail: AIModelListPrice.label(provider: paid.provider, modelID: paid.model)
                    .map { "Faster and more dependable. Paid through your OpenRouter key, \($0)" }
                    ?? "Faster and more dependable. Paid through your OpenRouter key",
                isEnabled: true
            )

            if choice == .other {
                option(
                    .other,
                    title: "Keep \(AIModelCatalog.displayName(provider: route.provider, modelID: route.model))",
                    detail: "Chosen earlier",
                    isEnabled: true
                )
            }

            if choice == .free {
                freeAccessStatus
                meetingsChoice
            }
        }
        .task {
            await readSettings()
            if let directory = try? await OpenRouterCatalogAvailability.shared.models() {
                await AIModelQualification.qualifyFreeCandidates(from: directory, wanted: 1)
                let text = FreeModelsSetup.candidates(needsVision: false, from: directory)
                let vision = FreeModelsSetup.candidates(needsVision: true, from: directory)
                freeText = text.first
                freeVision = vision.first
                freeTextBackups = Array(text.dropFirst())
                freeVisionBackups = Array(vision.dropFirst())
            }
            directoryLoaded = true
            await chooseFreeUnlessPicked()
            await checkAccessIfFree()
        }
        .onChange(of: choice) { _, _ in
            access = nil
            updateReadiness()
            Task { await checkAccessIfFree() }
        }
        // Back from OpenRouter's privacy page in the browser.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard choice == .free, access != .allowed else { return }
            Task { await checkAccessIfFree() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            blocker = FreeModelsSetup.pickBlocker()
            Task { await chooseFreeUnlessPicked() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            blocker = FreeModelsSetup.pickBlocker()
            Task {
                await readSettings()
                // "Your data" above turned on the switch that leaves a free
                // model no host: the free pick would only be refused.
                if AIDataPolicy.deniesDataCollection, choice == .free { choose(.paid) }
            }
        }
    }

    /// Reads the Background model off the main actor, since it can reach
    /// `KeychainService.load`, and the Meetings answer. Every settings change
    /// reads again, so only the newest read is shown.
    private func readSettings() async {
        readCount += 1
        let read = readCount
        let stored = await Task.detached(priority: .userInitiated) {
            KeychainService.displayedBackgroundTaskRoute
        }.value
        guard read == readCount else { return }
        route = stored
        meetingsStayPaid = !MeetingModels.mayUseFree
    }

    /// Whether meetings go free with the rest of background work.
    private var meetingsChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 2)
            Text("Meetings")
                .font(.subheadline.weight(.semibold))
            meetingsOption(
                stayPaid: true,
                title: "Keep meetings on a paid model",
                detail: MeetingModels.privacyReason
            )
            meetingsOption(
                stayPaid: false,
                title: "Let meetings use the free model too",
                detail: nil
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gettingStarted.background.meetings")
    }

    private func meetingsOption(stayPaid: Bool, title: String, detail: String?) -> some View {
        let isSelected = meetingsStayPaid == stayPaid
        return Button {
            chooseMeetings(stayPaid: stayPaid)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline)
                        if stayPaid {
                            RecommendedBadge()
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The Meetings answer, stored at once. It changes no model: a meeting
    /// task reads it each time it runs (`MeetingModels.staysOffFree`).
    private func chooseMeetings(stayPaid: Bool) {
        meetingsStayPaid = stayPaid
        MeetingModels.setMayUseFree(!stayPaid)
    }

    @ViewBuilder
    private var freeAccessStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch access {
            case .allowed?:
                Label("Your OpenRouter account allows free models.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .refused?:
                Label(FreeModelAccess.refusedExplanation, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .unknown(let message)?:
                Label("Could not check whether OpenRouter allows free models: \(message)", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking that your OpenRouter account allows free models…")
                }
                .foregroundStyle(.secondary)
            }
            if access != .allowed {
                HStack(spacing: 12) {
                    Link("Open OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                    Button("Check Again") {
                        Task { await checkAccessIfFree() }
                    }
                    .disabled(isChecking)
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func checkAccessIfFree() async {
        guard choice == .free, !isChecking else { return }
        isChecking = true
        access = nil
        updateReadiness()
        let model = route.model
        let verdict = await Task.detached(priority: .userInitiated) {
            await FreeModelAccess.check(model: model)
        }.value
        isChecking = false
        // The learner may have picked the paid model while it ran.
        guard choice == .free, route.model == model else { return }
        access = verdict
        updateReadiness()
    }

    /// Only a refusal, or a check still running, holds the step: a check
    /// that failed for another reason says so and lets the learner go on.
    private func updateReadiness() {
        switch (choice, access) {
        case (.free, nil), (.free, .refused?): isReady = false
        default: isReady = true
        }
    }

    private var freeDetail: String {
        if let blocker { return blocker }
        if !directoryLoaded { return "Looking for OpenRouter's free models…" }
        if freeText == nil { return "OpenRouter lists no free model that can do this today." }
        return FreeModelsSetup.pickTradeoffs
    }

    /// The free default, applied only while no Background model has ever
    /// been stored: a learner who picked one keeps it.
    private func chooseFreeUnlessPicked() async {
        guard freeText != nil, blocker == nil else { return }
        let unpicked = await Task.detached(priority: .userInitiated) {
            KeychainService.backgroundTaskProvider == nil
        }.value
        if unpicked { choose(.free) }
    }

    private func option(_ value: Choice, title: String, detail: String, isEnabled: Bool) -> some View {
        Button {
            choose(value)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // The wash below dims nothing on its own.
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
        .disabled(!isEnabled)
        .accessibilityAddTraits(choice == value ? .isSelected : [])
    }

    private func choose(_ value: Choice) {
        switch value {
        case .paid:
            let multimodal = KeychainService.defaultBackgroundMultimodalTaskRoute
            KeychainService.setBackgroundTaskRoute(provider: paid.provider, model: paid.model)
            KeychainService.setBackgroundMultimodalTaskRoute(provider: multimodal.provider, model: multimodal.model)
            // The free backups the free choice brought go with it; their
            // providers may keep what is sent, which the paid pick declined.
            for (slot, given) in [("background.text", freeTextBackups), ("background.images", freeVisionBackups)] {
                let stored = AIBackupModels.stored(slot: slot).map { $0.model.lowercased() }
                let brought = given.prefix(FreeModelsSetup.freeBackupCount).map { $0.id.lowercased() }
                if !stored.isEmpty, stored == Array(brought) { AIBackupModels.set([], slot: slot) }
            }
            route = paid
        case .free:
            guard let freeText, blocker == nil else { return }
            FreeModelsSetup.setFreeBackground(freeText, multimodal: false, backups: freeTextBackups)
            // With no free model that reads images, those tasks keep theirs.
            if let freeVision {
                FreeModelsSetup.setFreeBackground(freeVision, multimodal: true, backups: freeVisionBackups)
            }
            route = AITaskModelRoute(provider: .openRouter, model: freeText.id)
        case .other:
            break
        }
    }
}
