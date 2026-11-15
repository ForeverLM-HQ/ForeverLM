import SwiftUI
import AppKit

// MARK: - AI Sub-pages

/// Settings › Chat and Settings › Background: the models themselves, each
/// its own sidebar entry sharing this view (product owner, 2026-09-27: "the
/// background tasks" as "a separate tab from chat voice and images etc").
/// Chat draws its own list (`ChatModelsPane`), and Background the same list
/// (`BackgroundModelsPane`), once for Text-only and once for Multimodal:
/// every background task runs on one of the two unless it has a model of
/// its own (product owner, 2026-10-07: "people should be allowed to set it
/// for each task still somehow"): the Tasks tab lists every task with the
/// model it runs on, and a task opens onto the same model list. Whether meetings may go free is
/// asked in Setup, not here; their rows say when one waits for a paid model
/// (`MeetingModels`). A chosen card's host is opt-in, behind its ⋯.
struct ChatModelsSettingsDetailView: View {
    enum Pane: Sendable { case chat, background }

    let pane: Pane
    /// Pushes the API Keys pane; nil when that pane is hidden (regular
    /// installs get managed billing, not key entry).
    let onRequestAPIKey: (() -> Void)?
    /// Background's tabs: its two models, and the tasks that can have their own.
    enum BackgroundTab: Hashable { case textOnly, multimodal, tasks }
    @State private var tab: BackgroundTab = .textOnly
    /// The task whose model is being chosen, under the Tasks tab.
    @State private var openTask: AITask?
    @State private var freeBlocker = FreeModelsSetup.pickBlocker()

    /// What the model list below the tabs chooses.
    private var slot: ModelPickerSlot {
        if let openTask { return .task(openTask) }
        return tab == .multimodal ? .backgroundImages : .backgroundText
    }

    init(pane: Pane, onRequestAPIKey: (() -> Void)?) {
        self.pane = pane
        self.onRequestAPIKey = onRequestAPIKey
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Models") {
                    if pane == .chat {
                        ChatModelsPane(onRequestAPIKey: onRequestAPIKey)
                    } else {
                        backgroundBar
                        if tab == .tasks, openTask == nil {
                            BackgroundTasksList(onOpen: { openTask = $0 })
                        } else {
                            BackgroundModelsPane(
                                slot: slot,
                                onRequestAPIKey: onRequestAPIKey
                            )
                            // A fresh pane per slot: its lists and pick are the slot's.
                            .id(slot)
                        }
                    }
                    SettingsCard {
                        BackgroundFreeModelNote(blocker: freeBlocker)
                    }
                }
                // What was Settings › General, under the models it goes with
                // (product owner, 2026-11-08): the day, the quick assistant
                // and Think first are the chat's; the memory review's cards
                // are drafted and its day readied by background work.
                switch pane {
                case .chat:
                    SettingsDaySection()
                    QuickAssistantSettingsSection()
                    SettingsThinkFirstSection()
                case .background:
                    SettingsMemoryReviewSection()
                    SettingsPapersSection()
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .settingsFocusHost(pane: pane == .chat ? .aiChatModels : .aiBackgroundModels)
        .navigationTitle(pane == .chat ? "Chat" : "Background")
        .onAppear {
            adoptPendingRequest()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelPickerSheetRequest.didRequest)
                .receive(on: RunLoop.main)
        ) { _ in
            adoptPendingRequest()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .aiProviderDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            // The Data & Privacy switch posts this when it flips.
            freeBlocker = FreeModelsSetup.pickBlocker()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            freeBlocker = FreeModelsSetup.pickBlocker()
        }
    }

    /// Text-only | Multimodal | Tasks; inside a task, a way back to the list.
    private var backgroundBar: some View {
        HStack(spacing: 12) {
            if let openTask {
                Button {
                    self.openTask = nil
                } label: {
                    Label("Tasks", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.models.background.tasks.back")
                Text(openTask.displayName)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Picker("Background work", selection: $tab) {
                    Text("Text-only").tag(BackgroundTab.textOnly)
                    Text("Multimodal").tag(BackgroundTab.multimodal)
                    Text("Tasks").tag(BackgroundTab.tasks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.models.background.kind")
            }
            Spacer()
        }
    }

    private func adoptPendingRequest() {
        guard let requested = ModelPickerSheetRequest.take(for: pane) else { return }
        switch requested {
        case .chat:
            break
        case .backgroundText:
            tab = .textOnly
            openTask = nil
        case .backgroundImages:
            tab = .multimodal
            openTask = nil
        case .task(let task):
            tab = .tasks
            openTask = task
        }
    }
}

// MARK: - Model slots

/// What can be given a model: the chat (several models, one the default),
/// the two Background models every background task runs on, and one
/// background task that runs on a model of its own.
enum ModelPickerSlot: Hashable, Identifiable, Sendable {
    case chat
    case backgroundText
    case backgroundImages
    case task(AITask)

    /// The test a model must have passed before this slot offers it.
    var qualificationRole: AIModelQualification.Role {
        switch self {
        case .chat: .chat
        case .backgroundText: .background
        case .backgroundImages: .backgroundImages
        case .task(let task): task.qualificationRole
        }
    }

    var id: String {
        switch self {
        case .chat: "chat"
        case .backgroundText: "background.text"
        case .backgroundImages: "background.images"
        case .task(let task): "task.\(task.rawValue)"
        }
    }

    /// The slot that holds this one's backups and host choices: a task's own
    /// pick is backed up, and hosted, as the Background model of its kind is.
    var sharedSlotID: String {
        switch self {
        case .task(let task): AIBackupModels.backgroundSlot(multimodal: task.usesMultimodalBackgroundModelDefault)
        default: id
        }
    }

    /// The task a task slot chooses the model of; nil for the rest.
    var ownTask: AITask? {
        if case .task(let task) = self { return task }
        return nil
    }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .backgroundText: "Text-only"
        case .backgroundImages: "Multimodal"
        case .task(let task): task.displayName
        }
    }

    /// Only models that read images are offered.
    var requiresVision: Bool {
        switch self {
        case .chat, .backgroundText: false
        case .backgroundImages: true
        case .task(let task): task.requiresVision
        }
    }

    /// The Settings pane that chooses this slot's model.
    var pane: ChatModelsSettingsDetailView.Pane {
        self == .chat ? .chat : .background
    }
}

/// Opens Settings › Chat, or Settings › Background on one of its models,
/// from anywhere (the chat's model picker's "Choose Models…").
enum ModelPickerSheetRequest {
    static let didRequest = Notification.Name("ForeverLM.modelPickerSheetRequested")
    @MainActor private static var pending: ModelPickerSlot?

    @MainActor
    static func open(_ slot: ModelPickerSlot) {
        NotificationCenter.default.post(name: .requestOpenStudioSettings, object: stage(slot))
        // An already open pane does not appear again, so it hears this.
        NotificationCenter.default.post(name: didRequest, object: nil)
    }

    /// Leaves `slot` for its pane to take when it appears, and names that
    /// pane, for a caller inside Settings that navigates there itself (AI
    /// Usage › Activity's Change Model).
    @MainActor
    @discardableResult
    static func stage(_ slot: ModelPickerSlot) -> SettingsPane {
        pending = slot
        return slot.pane == .chat ? .aiChatModels : .aiBackgroundModels
    }

    /// The pending slot, if it belongs to `pane`. The pane being left hears
    /// the request too, and must leave it for the one opening.
    @MainActor
    static func take(for pane: ChatModelsSettingsDetailView.Pane) -> ModelPickerSlot? {
        guard let slot = pending, slot.pane == pane else { return nil }
        pending = nil
        return slot
    }
}

/// What a free model gives up, or why none can be picked.
struct BackgroundFreeModelNote: View {
    let blocker: String?
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let blocker {
                Label(blocker, systemImage: "info.circle")
            } else {
                DisclosureGroup("About free models", isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FreeModelsSetup.pickTradeoffs)
                        Link("Open OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings → Voice: the dictation and recordings transcription models, and
/// the text-to-speech model, voice and speed. Nothing else: the cost prompt is
/// set from chat (`set_app_setting`), and the providers that cannot be picked
/// any more (Apple, a local Qwen3 server) have no controls. The recordings
/// model is here because whatever ForeverLM is charged for can have its model
/// changed (product owner, 2026-10-10, at AI Usage › Activity's Meeting
/// Transcription line).
///
/// Both model lists are OpenRouter's own directories (product owner, 2026-09-27:
/// "show all models at https://openrouter.ai/models?output_modalities=speech
/// and https://openrouter.ai/models?output_modalities=transcription"), read
/// off the main actor each time the pane opens once the last read is stale.
/// While a read is out the pane says so above the list it has; a failed read
/// says why and offers another, and never passes a list off as current.
struct VoiceSettingsDetailView: View {
    /// Every stored value this pane opens with, read in one pass off the main
    /// actor.
    ///
    /// None of it may be read from a `@State` initializer: those run during
    /// view construction, and each of these reads reaches
    /// `KeychainService.load`, which on a cold vault reaches
    /// `SecItemCopyMatching` on an ACL-guarded item and blocks on a system
    /// authorization dialog — bounded to 1.5s by `readPromptableVault`, which
    /// is a hang averted, not a read a view body may make.
    private struct Snapshot: Sendable {
        var speechToTextProvider: SpeechToTextProvider
        var speechToTextModel: String
        var recordingsModel: String
        var textToSpeechProvider: MacArticleSpeechMode
        var model: String
        var voice: String

        static func load() -> Snapshot {
            let sttProvider = KeychainService.speechToTextProvider
            // Canonicalize under the id the model's route knows it by, and
            // write the repair back — a pick left behind by a picker that
            // offered bare provider ids has to be fixed in storage, not just
            // on screen.
            let storedSTTModel = KeychainService.transcriptionModel(for: sttProvider)
            let sttModel = ManagedTranscriptionClient.canonicalModel(storedSTTModel)
            if sttModel != storedSTTModel {
                KeychainService.setTranscriptionModel(sttModel, for: sttProvider)
            }
            let storedMediaModel = KeychainService.mediaTranscriptionModel
            let mediaModel = ManagedTranscriptionClient.canonicalModel(storedMediaModel)
            if mediaModel != storedMediaModel {
                KeychainService.mediaTranscriptionModel = mediaModel
            }

            // The pane only offers the one selectable provider; a stored
            // older one moves to it on the first model pick.
            let selection = MacArticleSpeechSettings.repairedSelection(for: .openRouter)
            return Snapshot(
                speechToTextProvider: sttProvider,
                speechToTextModel: sttModel,
                recordingsModel: mediaModel,
                textToSpeechProvider: MacArticleSpeechSettings.provider,
                model: selection.model,
                voice: selection.voice
            )
        }
    }

    // Pure seeds. They are never shown: every card that reads them waits on
    // `hasLoadedStoredValues`.
    @State private var speechToTextProvider: SpeechToTextProvider = .openai
    @State private var speechToTextModel = ""
    @State private var recordingsModel = ""
    @State private var textToSpeechProvider = MacArticleSpeechSettings.defaultProvider
    @State private var model = ""
    @State private var voice = ""
    @State private var hasLoadedStoredValues = false
    @State private var speechDirectory: OpenRouterAudioDirectory.ReadState = .reading
    @State private var transcriptionDirectory: OpenRouterAudioDirectory.ReadState = .reading
    /// Bumped when a background read changes a list or a price, so the cards
    /// redraw from the catalog statics they read.
    @State private var catalogRevision = 0

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                transcriptionSection(
                    .dictation,
                    title: "Dictation",
                    description: "The model that turns what you say in a chat or a review into text.",
                    model: $speechToTextModel
                )

                transcriptionSection(
                    .media,
                    title: "Recordings & podcasts",
                    description: "The model meeting recordings, podcast episodes and course videos are transcribed with.",
                    model: $recordingsModel
                )

                SettingsSection(
                    title: "Text to speech",
                    description: "The model, voice and speed articles, papers and books are read in."
                ) {
                    storedValueCards {
                        TextToSpeechSettingsView(
                            storedProvider: $textToSpeechProvider,
                            modelText: $model,
                            voiceText: $voice,
                            directory: speechDirectory,
                            catalogRevision: catalogRevision,
                            retryDirectory: { Task { await readDirectories(force: true) } }
                        )
                    }
                }

                SettingsSection(
                    title: "Voice mode",
                    description: "The voice ForeverLM speaks in when you talk to it, here, on the iPhone and in CarPlay."
                ) {
                    SettingsCard {
                        VoiceModeVoicePicker()
                    }
                }

                RealtimeVoiceOwnKeySection()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Voice")
        .onReceive(NotificationCenter.default.publisher(for: .openRouterAudioDirectoryDidChange)) { _ in
            catalogRevision &+= 1
        }
        .onAppear {
            if let requested = TranscriptionModelRequest.take() {
                proxy.scrollTo(requested, anchor: .top)
            }
        }
        .task {
            guard !hasLoadedStoredValues else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                Snapshot.load()
            }.value
            speechToTextProvider = snapshot.speechToTextProvider
            speechToTextModel = snapshot.speechToTextModel
            recordingsModel = snapshot.recordingsModel
            textToSpeechProvider = snapshot.textToSpeechProvider
            model = snapshot.model
            voice = snapshot.voice
            hasLoadedStoredValues = true
            await readDirectories(force: false)
        }
        }
    }

    /// One transcription model's section: dictation and recordings each pick
    /// their own, so each has its own list rather than a tab over one.
    private func transcriptionSection(
        _ purpose: ManagedTranscriptionClient.Purpose,
        title: String,
        description: String,
        model: Binding<String>
    ) -> some View {
        SettingsSection(title: title, description: description) {
            storedValueCards {
                TranscriptionSettingsView(
                    purpose: purpose,
                    provider: speechToTextProvider,
                    model: model,
                    directory: transcriptionDirectory,
                    catalogRevision: catalogRevision,
                    retryDirectory: { Task { await readDirectories(force: true) } }
                )
            }
        }
        .id(purpose)
    }

    /// Reads both directories (a fresh read answers at once), then repairs
    /// the stored text-to-speech pick against the list as it now stands: a model
    /// OpenRouter stopped serving moves to one it serves, as the pane always
    /// did, and one a Mac that had not read the list yet left alone is kept.
    @MainActor
    private func readDirectories(force: Bool) async {
        speechDirectory = .reading
        transcriptionDirectory = .reading
        async let speech = Self.readState(.speech, force: force)
        async let transcription = Self.readState(.transcription, force: force)
        let speechState = await speech
        let transcriptionState = await transcription
        speechDirectory = speechState
        transcriptionDirectory = transcriptionState

        let repaired = await Task.detached(priority: .userInitiated) {
            MacArticleSpeechSettings.repairedSelection(for: .openRouter)
        }.value
        if model != repaired.model { model = repaired.model }
        if voice != repaired.voice { voice = repaired.voice }
    }

    private nonisolated static func readState(
        _ kind: OpenRouterAudioDirectory.Kind,
        force: Bool
    ) async -> OpenRouterAudioDirectory.ReadState {
        do {
            try await OpenRouterAudioDirectory.refresh(kind, force: force)
            return .read
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Holds a section's cards back until the snapshot has landed, so no
    /// control is ever rendered against a seeded placeholder. The content
    /// draws its own cards: a model list and its browser are two.
    @ViewBuilder
    private func storedValueCards<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        if hasLoadedStoredValues {
            content()
        } else {
            SettingsCard {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Where a model list stands with OpenRouter's directory: reading, or a read
/// that failed and why, with another try. Nothing once a read is in.
private struct AudioDirectoryStatus: View {
    let state: OpenRouterAudioDirectory.ReadState
    /// "speech models", "transcription models".
    let subject: String
    /// Whether the list below comes from a directory read (this launch's or
    /// an earlier one) rather than from what this build records.
    let listIsFromDirectory: Bool
    let retry: () -> Void

    var body: some View {
        switch state {
        case .read:
            EmptyView()
        case .reading:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Reading OpenRouter's \(subject)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(listIsFromDirectory
                     ? "\(message) Showing the list from the last read."
                     : "\(message) Showing the models this version of ForeverLM knows.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

private extension OpenRouterAudioDirectory.ReadState {
    /// The browser under a model list says only that a read is out: the
    /// list's own status line says why one failed, with another try, and
    /// the list it keeps is the browser's too.
    var browserState: ModelBrowserState {
        self == .reading ? .loading : .loaded
    }
}

/// What Settings › Voice's rows and filters read of a model's price.
private extension OpenRouterAudioPrices {
    static func isFree(slug: String, kind: OpenRouterAudioDirectory.Kind) -> Bool {
        price(for: slug, kind: kind)?.isFree == true
    }

    /// OpenRouter's promotion on the model, from the discount its catalog
    /// row carries; none on a free one, which has no price to cut.
    static func promotion(slug: String, kind: OpenRouterAudioDirectory.Kind) -> RouterModelPromotion? {
        guard let price = price(for: slug, kind: kind), !price.isFree,
              let basisPoints = price.discountBasisPoints else { return nil }
        return RouterModelPromotion(discountBasisPoints: basisPoints)
    }

    static func promotionBadges(slug: String, kind: OpenRouterAudioDirectory.Kind) -> [ModelRowBadge] {
        promotion(slug: slug, kind: kind).map { [ModelRowBadge(text: $0.label, tint: .accent)] } ?? []
    }

    /// The list figure a promotion cuts, in the unit the row quotes: "$0.45"
    /// ahead of "$0.225 / hour of audio". The catalog's price is the one
    /// billed, so the list figure is recovered from it. Nil without a
    /// promotion, or when the two round to the same figure.
    static func listAmount(slug: String, kind: OpenRouterAudioDirectory.Kind) -> String? {
        guard let price = price(for: slug, kind: kind),
              let promotion = Self.promotion(slug: slug, kind: kind) else { return nil }
        let list = amount(of: price, kind: kind, scale: promotion.listRate(fromEffective: 1))
        return list == amount(of: price, kind: kind) ? nil : list
    }
}

/// Opens Settings › Voice on one transcription model, for AI Usage ›
/// Activity's Change Model on a recording's or a dictation's line. The pane
/// takes it when it appears.
enum TranscriptionModelRequest {
    @MainActor private static var pending: ManagedTranscriptionClient.Purpose?

    @MainActor
    static func stage(_ purpose: ManagedTranscriptionClient.Purpose) {
        pending = purpose
    }

    @MainActor
    static func take() -> ManagedTranscriptionClient.Purpose? {
        defer { pending = nil }
        return pending
    }
}

/// A transcription model: dictation's, every recording of which is
/// transcribed after you stop, through OpenRouter (there is no live realtime
/// rail), or the one meeting recordings, podcast episodes and course
/// videos are transcribed with (`ManagedTranscriptionClient.Purpose`). The
/// transcription models are drawn as Settings › Chat draws its own (product
/// owner, 2026-09-28): Suggested, one per maker
/// (`TranscriptionModelCatalog.suggestedModelIDs`), then all of OpenRouter's
/// transcription directory by maker, with a search.
private struct TranscriptionSettingsView: View {
    let purpose: ManagedTranscriptionClient.Purpose
    let provider: SpeechToTextProvider
    @Binding var model: String
    let directory: OpenRouterAudioDirectory.ReadState
    /// Read only so a new list or price redraws the cards.
    let catalogRevision: Int
    let retryDirectory: () -> Void
    /// The model the pane opened on: listed above Suggested for the visit
    /// when Suggested does not show it.
    @State private var openedOnID: String?

    var body: some View {
        let options = TranscriptionModelCatalog.models
        let makers = MediaModelLists.makers(options, slug: \.id, makerName: \.maker)
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    if purpose == .dictation {
                        Text("The recording is transcribed after you stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    AudioDirectoryStatus(
                        state: directory,
                        subject: "transcription models",
                        listIsFromDirectory: TranscriptionModelCatalog.isDirectoryBacked,
                        retry: retryDirectory
                    )
                    suggestedLists(options, makers: makers)
                }
            }
            SettingsCard {
                MediaModelBrowser(
                    models: options,
                    state: directory.browserState,
                    subject: "transcription models",
                    retry: retryDirectory,
                    slug: \.id,
                    makerName: \.maker,
                    searchFields: { [$0.name, $0.id] },
                    isFree: { OpenRouterAudioPrices.isFree(slug: $0.id, kind: .transcription) },
                    isDiscounted: { OpenRouterAudioPrices.promotion(slug: $0.id, kind: .transcription) != nil },
                    row: { option, showsMaker in
                        row(option, makers: makers, showsMaker: showsMaker)
                    }
                )
            }
        }
        // Notes the model the list opened on, and nothing else: every stored
        // value arrives already loaded from `VoiceSettingsDetailView`'s one
        // off-main snapshot. Reading the stored model here would put a
        // Keychain read back on the main actor, on the click that opens
        // Settings.
        .onAppear {
            if openedOnID == nil { openedOnID = ManagedTranscriptionClient.canonicalModel(model) }
        }
    }

    @ViewBuilder
    private func suggestedLists(
        _ options: [TranscriptionModelOption],
        makers: [ModelBrowserMaker<TranscriptionModelOption>]
    ) -> some View {
        let listed = AIModelCatalog.listingDates(
            OpenRouterAudioDirectory.rows(.transcription) ?? [], slug: \.id, listedAt: \.created
        )
        let suggested = MediaModelLists.suggestions(
            TranscriptionModelCatalog.suggestedModelIDs, in: options, slug: \.id,
            listedAt: { listed[$0.id.lowercased()] }
        )
        let pinned = MediaModelLists.pinned(openedOn: openedOnID, in: options, suggested: suggested, slug: \.id)
        if let pinned {
            SettingsModelListSection(title: "Your model") {
                row(pinned, makers: makers, showsMaker: true)
            }
        }
        if !suggested.isEmpty {
            SettingsModelListSection(title: "Suggested") {
                ForEach(suggested) { option in
                    row(option, makers: makers, showsMaker: true)
                }
            }
        }
    }

    /// OpenRouter's price in the unit it bills the model by ("/ hour of
    /// audio", "per 1M tokens").
    private func row(
        _ option: TranscriptionModelOption,
        makers: [ModelBrowserMaker<TranscriptionModelOption>],
        showsMaker: Bool
    ) -> some View {
        MediaModelRow(
            name: option.name,
            slug: option.id,
            maker: MediaModelLists.identity(ofSlug: option.id, in: makers),
            showsMaker: showsMaker,
            detail: option.priceLabel,
            listPrice: OpenRouterAudioPrices.listAmount(slug: option.id, kind: .transcription),
            isSelected: ManagedTranscriptionClient.canonicalModel(model) == option.id,
            badges: OpenRouterAudioPrices.promotionBadges(slug: option.id, kind: .transcription),
            help: option.id
        ) {
            model = option.id
            switch purpose {
            case .dictation: KeychainService.setTranscriptionModel(option.id, for: provider)
            case .media: KeychainService.mediaTranscriptionModel = option.id
            }
        }
    }
}

/// The text-to-speech model, voice and default speed. The models are drawn as
/// Settings › Chat draws its own (product owner, 2026-09-28): Suggested, one per
/// maker (`ArticleSpeechCatalog.suggestedModelIDs`), then all of OpenRouter's
/// speech directory by maker, with a search; the voice and speed follow.
private struct TextToSpeechSettingsView: View {
    /// The provider on file, from the pane's off-main snapshot, so a pick
    /// never reads the Keychain on the main actor to find out.
    @Binding var storedProvider: MacArticleSpeechMode
    @Binding var modelText: String
    @Binding var voiceText: String
    let directory: OpenRouterAudioDirectory.ReadState
    /// Read only so a new list or price redraws the cards.
    let catalogRevision: Int
    let retryDirectory: () -> Void
    @StateObject private var previewService = MacArticleSpeechVoicePreviewService()
    @StateObject private var voiceRatings = MacArticleSpeechVoiceRatingStore()
    /// Seeded to the shipped default and adopted in `.onAppear`. Storage reads
    /// do not belong in a `@State` initializer, which runs during view
    /// construction — see `VoiceSettingsDetailView.Snapshot`.
    @State private var speed = MacArticleSpeechSpeed.defaultSpeed
    /// The model the pane opened on: listed above Suggested for the visit
    /// when Suggested does not show it.
    @State private var openedOnID: String?
    /// A pick under its test run, and the line a refused one leaves.
    @State private var testingPick: TestingPick?
    @State private var pickRefusal: PickRefusal?

    enum PickPlace: Equatable { case model, voice }
    struct TestingPick: Equatable {
        let model: String
        let voice: String
        let place: PickPlace
    }
    struct PickRefusal: Equatable {
        let text: String
        let place: PickPlace
    }

    private let provider = MacArticleSpeechMode.openRouter

    private var providerVoices: [String] {
        MacArticleSpeechSettings.voices(for: provider, model: modelText)
    }

    /// A stored older provider (Apple, a local server) cannot be picked here
    /// any more; choosing a model or voice is choosing the one that can. The
    /// write reaches the Keychain, so it runs off the main actor.
    private func adoptSelectableProvider() {
        guard storedProvider != provider else { return }
        storedProvider = provider
        let provider = provider
        Task.detached(priority: .userInitiated) {
            MacArticleSpeechSettings.provider = provider
        }
    }

    private func selectModel(_ model: String) {
        previewService.stop()
        let voices = MacArticleSpeechSettings.voices(for: provider, model: model)
        // Each model keeps the voice it was last given.
        let voice = ArticleSpeechVoiceMemory.voice(switchingTo: model, offered: voices, current: voiceText)
        let leaving = (model: modelText, voice: voiceText)
        testThen(model: model, voice: voice, refusalBelow: .model) {
            // The model being left keeps the voice it had, picked here or not.
            ArticleSpeechVoiceMemory.remember(leaving.voice, forModel: leaving.model)
            modelText = model
            adoptSelectableProvider()
            MacArticleSpeechSettings.setModel(model, for: provider)
            if voice != voiceText {
                voiceText = voice
                MacArticleSpeechSettings.setVoice(voice, for: provider)
            }
        }
    }

    private func selectVoice(_ voice: String) {
        previewService.stop()
        let model = modelText
        testThen(model: model, voice: voice, refusalBelow: .voice) {
            voiceText = voice
            adoptSelectableProvider()
            MacArticleSpeechSettings.setVoice(voice, for: provider)
            ArticleSpeechVoiceMemory.remember(voice, forModel: model)
        }
    }

    /// Runs `apply` once the model, in this voice, has passed a test run of
    /// one short synthesis: at once when it already has, after the test when
    /// it has not or failed before. A pick that fails is not applied and
    /// stays in the list; the line under the list says why, and choosing it
    /// again tests it again. A free model whose test could not finish is
    /// applied and tested when next used (`testSpeechBeforeSelecting`).
    private func testThen(
        model: String,
        voice: String,
        refusalBelow place: PickPlace,
        apply: @escaping () -> Void
    ) {
        guard testingPick == nil else { return }
        pickRefusal = nil
        if AIModelQualification.speechStatus(model: model, voice: voice) == .passed {
            apply()
            return
        }
        testingPick = TestingPick(model: model, voice: voice, place: place)
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testSpeechBeforeSelecting(model: model, voice: voice)
            }.value
            testingPick = nil
            if verdict == .go {
                apply()
            } else if let text = AIModelQualification.speechRefusalText(
                name: ArticleSpeechCatalog.selectionLabel(model: model, voice: voice),
                verdict: verdict
            ) {
                pickRefusal = PickRefusal(text: text, place: place)
            }
        }
    }

    private func selectSpeed(_ option: Double) {
        speed = option
        MacArticleSpeechSpeed.stored = option
    }

    var body: some View {
        let options = ArticleSpeechCatalog.models
        let makers = MediaModelLists.makers(options, slug: \.id, makerName: \.maker)
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    AudioDirectoryStatus(
                        state: directory,
                        subject: "speech models",
                        listIsFromDirectory: ArticleSpeechCatalog.isDirectoryBacked,
                        retry: retryDirectory
                    )
                    suggestedLists(options, makers: makers)
                    pickStatus(.model)
                }
            }

            SettingsCard {
                MediaModelBrowser(
                    models: options,
                    state: directory.browserState,
                    subject: "speech models",
                    retry: retryDirectory,
                    slug: \.id,
                    makerName: \.maker,
                    searchFields: { [$0.name, $0.id] },
                    isFree: { OpenRouterAudioPrices.isFree(slug: $0.id, kind: .speech) },
                    isDiscounted: { OpenRouterAudioPrices.promotion(slug: $0.id, kind: .speech) != nil },
                    row: { option, showsMaker in
                        row(option, makers: makers, showsMaker: showsMaker)
                    }
                )
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    if !providerVoices.isEmpty {
                        TextToSpeechVoicePreviewList(
                            title: "Voice",
                            voices: providerVoices,
                            selectedVoice: voiceText,
                            previewService: previewService,
                            voiceRatings: voiceRatings,
                            label: { MacArticleSpeechSettings.openRouterVoiceLabel(model: modelText, voice: $0) },
                            onSelect: selectVoice,
                            previewProvider: provider,
                            previewModel: modelText
                        )
                    }

                    pickStatus(.voice)

                    if let error = previewService.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    speedChoices
                }
            }
        }
        .onAppear {
            speed = MacArticleSpeechSpeed.stored
            if openedOnID == nil { openedOnID = modelText }
            previewService.prewarmAllModels(prioritizedModelID: modelText)
        }
        .onDisappear {
            previewService.stop()
        }
        .onChange(of: modelText) { _, newModel in
            previewService.stop()
            previewService.prewarmAllModels(prioritizedModelID: newModel)
        }
        .onChange(of: voiceText) { _, _ in
            previewService.stop()
        }
    }

    /// "Testing …" while a pick's test runs, and the one line a refused
    /// pick leaves, under the list it was chosen from.
    @ViewBuilder
    private func pickStatus(_ place: PickPlace) -> some View {
        if let testingPick, testingPick.place == place {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Testing \(ArticleSpeechCatalog.selectionLabel(model: testingPick.model, voice: testingPick.voice))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let pickRefusal, pickRefusal.place == place {
            Text(pickRefusal.text)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(pickRefusal.text)
        }
    }

    @ViewBuilder
    private func suggestedLists(
        _ options: [ArticleSpeechModelOption],
        makers: [ModelBrowserMaker<ArticleSpeechModelOption>]
    ) -> some View {
        let listed = AIModelCatalog.listingDates(
            OpenRouterAudioDirectory.rows(.speech) ?? [], slug: \.id, listedAt: \.created
        )
        let suggested = MediaModelLists.suggestions(
            ArticleSpeechCatalog.suggestedModelIDs, in: options, slug: \.id,
            listedAt: { listed[$0.id.lowercased()] }
        )
        let pinned = MediaModelLists.pinned(openedOn: openedOnID, in: options, suggested: suggested, slug: \.id)
        if let pinned {
            SettingsModelListSection(title: "Your model") {
                row(pinned, makers: makers, showsMaker: true)
            }
        }
        if !suggested.isEmpty {
            SettingsModelListSection(title: "Suggested") {
                ForEach(suggested) { option in
                    row(option, makers: makers, showsMaker: true)
                }
            }
        }
    }

    /// OpenRouter's price in the unit it bills the model by: "/ 1M
    /// characters", "per 1M tokens", "/ minute of audio".
    private func row(
        _ option: ArticleSpeechModelOption,
        makers: [ModelBrowserMaker<ArticleSpeechModelOption>],
        showsMaker: Bool
    ) -> some View {
        MediaModelRow(
            name: option.name,
            slug: option.id,
            maker: MediaModelLists.identity(ofSlug: option.id, in: makers),
            showsMaker: showsMaker,
            detail: option.priceLabel,
            listPrice: OpenRouterAudioPrices.listAmount(slug: option.id, kind: .speech),
            isSelected: option.id == modelText,
            badges: OpenRouterAudioPrices.promotionBadges(slug: option.id, kind: .speech),
            help: option.summary
        ) {
            selectModel(option.id)
        }
    }

    private var speedChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default speed")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MacArticleSpeechSpeed.options, id: \.self) { option in
                        Button {
                            selectSpeed(option)
                        } label: {
                            Text(MacArticleSpeechSpeed.label(for: option))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    MacArticleSpeechSpeed.isSelected(speed, option: option)
                                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                                        : AnyShapeStyle(.fill.quaternary),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            MacArticleSpeechSpeed.isSelected(speed, option: option)
                                                ? Color.accentColor.opacity(0.4)
                                                : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.hoverWash(in: Capsule()))
                    }
                }
            }
        }
    }
}

private struct TextToSpeechVoicePreviewList: View {
    let title: String
    let voices: [String]
    let selectedVoice: String
    @ObservedObject var previewService: MacArticleSpeechVoicePreviewService
    @ObservedObject var voiceRatings: MacArticleSpeechVoiceRatingStore
    let label: (String) -> String
    let onSelect: (String) -> Void
    let previewProvider: MacArticleSpeechMode
    let previewModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(voices, id: \.self) { voice in
                        TextToSpeechVoicePreviewRow(
                            title: label(voice),
                            isSelected: selectedVoice == voice,
                            isLoading: previewService.isLoading(voice),
                            isPlaying: previewService.isPlaying(voice),
                            rating: voiceRatings.rating(modelID: previewModel, voiceID: voice),
                            onSelect: { onSelect(voice) },
                            onRate: { rating in
                                voiceRatings.toggle(rating, modelID: previewModel, voiceID: voice)
                            },
                            onPreview: {
                                previewService.togglePreview(
                                    provider: previewProvider,
                                    model: previewModel,
                                    voice: voice
                                )
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }
}

private struct TextToSpeechVoicePreviewRow: View {
    let title: String
    let isSelected: Bool
    let isLoading: Bool
    let isPlaying: Bool
    let rating: ArticleSpeechVoiceRating?
    let onSelect: () -> Void
    let onRate: (ArticleSpeechVoiceRating) -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))

            ratingButton(.up, systemImage: "hand.thumbsup")
            ratingButton(.down, systemImage: "hand.thumbsdown")

            Button(action: onPreview) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.hoverWash)
            .help(isPlaying ? "Stop preview" : "Preview voice")
            .disabled(isLoading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func ratingButton(
        _ value: ArticleSpeechVoiceRating,
        systemImage: String
    ) -> some View {
        Button { onRate(value) } label: {
            Image(systemName: rating == value ? "\(systemImage).fill" : systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(rating == value ? Color.accentColor : .secondary)
                .frame(width: 24, height: 28)
        }
        .buttonStyle(.hoverWash)
        .help(value == .up ? "Like voice" : "Dislike voice")
        .accessibilityLabel(value == .up ? "Like voice" : "Dislike voice")
        .accessibilityAddTraits(rating == value ? .isSelected : [])
    }
}

@MainActor
private final class MacArticleSpeechVoiceRatingStore: ObservableObject {
    @Published private var revision = 0
    private var remoteObserver: NSObjectProtocol?

    init() {
        remoteObserver = NotificationCenter.default.addObserver(
            forName: PreferenceStore.didChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let keys = notification.userInfo?[PreferenceStore.changedKeysKey] as? Set<String>,
                  keys.contains(where: { $0.hasPrefix(ArticleSpeechVoiceRating.preferencePrefix) }) else {
                return
            }
            // `queue: .main` already guarantees main-thread delivery, but the
            // observer block is `@Sendable`, so the isolation has to be stated
            // rather than inferred. Asserting it keeps the republish synchronous
            // instead of deferring a one-integer bump to a later hop.
            MainActor.assumeIsolated { self?.revision &+= 1 }
        }
    }

    deinit {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
    }

    /// The row of one voice's rating: the family's prefix, then the model and the voice.
    private static func key(modelID: String, voiceID: String) -> AccountKey<String?> {
        Prefs.Families.voiceRating.key("\(modelID)|\(voiceID)")
    }

    func rating(modelID: String, voiceID: String) -> ArticleSpeechVoiceRating? {
        _ = revision
        return Preferences.value(Self.key(modelID: modelID, voiceID: voiceID)).flatMap(ArticleSpeechVoiceRating.init(rawValue:))
    }

    func toggle(_ rating: ArticleSpeechVoiceRating, modelID: String, voiceID: String) {
        let key = Self.key(modelID: modelID, voiceID: voiceID)
        if self.rating(modelID: modelID, voiceID: voiceID) == rating {
            Preferences.reset(key)
        } else {
            Preferences.set(rating.rawValue, for: key)
        }
        revision &+= 1
    }
}

struct SettingsSection<Content: View>: View {
    /// A small capital line above the title. Only a team's
    /// panes use it, where it says "Team · Read only"; a pane's own name
    /// above its first section repeated the sidebar.
    let eyebrow: String?
    let title: String
    let description: String?
    let content: Content

    init(eyebrow: String? = nil, title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // The stack is load-bearing: a multi-view `content` arrives as a
        // TupleView, and modifiers on a TupleView apply to every child. Without
        // it a card of `row / Divider / row` paints three cards, the middle one
        // an empty box around the divider.
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Host per slot

/// Which of a model's OpenRouter hosts serves one slot of Settings › Chat or
/// Settings › Background (product owner, 2026-09-26: "let me choose the inference
/// provider … per task"; the slots are the chat and the two
/// Background models). Automatic is today's route: the fastest host that
/// caches the prompt. Cheapest ranks the hosts by price; a pinned host names
/// one, optionally letting another take over when it refuses. The choice is
/// stored per slot and per model (`OpenRouterHostPreference`), so a slot
/// keeps its host when it moves to another model and back.
struct ModelHostPanel: View {
    let slotID: String
    let provider: AIProvider
    let model: String
    /// The choice changed, so the sheet's sidebar reloads.
    var onHostChange: () -> Void = {}

    @State private var hosts: [OpenRouterEndpointTier]?
    @State private var tokensPerSecond: [String: Double] = [:]
    @State private var loadFailed = false
    @State private var preference: OpenRouterHostPreference?
    @State private var showsAllHosts = false
    /// The model's endpoints OpenRouter lists as running in the US, lowercased;
    /// nil until read, or when the read failed.
    @State private var regionTags: Set<String>?
    /// Where each provider says it is, by provider slug; nil until read, or
    /// when the read failed, and then no row shows a flag.
    @State private var providerLocations: [String: OpenRouterProviderLocation]?

    private static let collapsedHostCount = 6
    private static let region = OpenRouterHostPreference.Region.us

    private var slug: String { OpenRouterModelID.slug(provider: provider, model: model) }
    private var modelName: String { AIModelCatalog.displayName(provider: provider, modelID: model) }
    private var region: OpenRouterHostPreference.Region? { preference?.region }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            choices
            regionToggle
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            hostList
            if let preference, preference.mode == .host {
                Toggle(
                    "If \(preference.label) can't answer, use another provider",
                    isOn: Binding(
                        get: { preference.allowsFallback },
                        set: { allows in
                            save(OpenRouterHostPreference(
                                mode: .host,
                                tag: preference.tag,
                                hostName: preference.hostName,
                                allowsFallback: allows,
                                region: preference.region
                            ))
                        }
                    )
                )
                .font(.caption)
                .accessibilityIdentifier("settings.models.host.fallback")
                if AIDataPolicy.deniesDataCollection {
                    Label(
                        "“\(AIDataPolicy.switchTitle)” is on, so a provider that keeps prompts refuses this work.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: slug) {
            await load()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)
                .receive(on: RunLoop.main)
        ) { _ in
            preference = OpenRouterHostPreference.stored(slot: slotID, slug: slug)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Provider for \(modelName)")
                .font(.headline)
            Spacer()
            if let hosts = hosts.map(listedHosts) {
                Text("\(hosts.count) \(hosts.count == 1 ? "provider" : "providers")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var choices: some View {
        HStack(spacing: 6) {
            choiceButton("Automatic", isSelected: preference == nil || preference?.mode == .automatic) {
                save(OpenRouterHostPreference(mode: .automatic).inRegion(region))
            }
            choiceButton("Cheapest", isSelected: preference?.mode == .cheapest) {
                save(OpenRouterHostPreference(mode: .cheapest, region: region))
            }
            if let preference, preference.mode == .host {
                choiceButton(preference.label, isSelected: true) {}
            }
        }
    }

    /// Keeps whichever host choice is made to the hosts OpenRouter lists as
    /// running in the US (`OpenRouterHostPreference.region`). Offered only
    /// when the model has such a host; once on, it stays switchable off.
    @ViewBuilder
    private var regionToggle: some View {
        let hasRegionHost = !(regionTags ?? []).isEmpty
        if hasRegionHost || region != nil {
            Toggle(
                "Only providers in \(Self.region.name)",
                isOn: Binding(
                    get: { region != nil },
                    set: { on in
                        let current = preference ?? OpenRouterHostPreference(mode: .automatic)
                        let wanted = on ? Self.region : nil
                        // A pinned host outside the region gives way to Automatic.
                        if on, current.mode == .host,
                           let tag = current.tag?.lowercased(), regionTags?.contains(tag) != true {
                            save(OpenRouterHostPreference(mode: .automatic, region: wanted))
                        } else {
                            save(current.inRegion(wanted))
                        }
                    }
                )
            )
            .font(.caption)
            .accessibilityIdentifier("settings.models.host.region")
        }
    }

    private func choiceButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ProviderCapsuleLabel(title: title, systemImage: nil, isSelected: isSelected)
        }
        .buttonStyle(.hoverWash(in: Capsule()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.models.host.\(title.lowercased())")
    }

    private var explanation: String {
        let text: String
        switch preference?.mode {
        case nil, .automatic?:
            text = "The fastest provider that caches your prompts, and another if it can't answer."
        case .cheapest?:
            text = "The cheapest provider first, and the next cheapest if it can't answer."
        case .host?:
            let name = preference?.label ?? "This provider"
            let fallback = preference?.allowsFallback == true
                ? " If it can't answer, another provider does."
                : " If it can't answer, the work fails."
            text = "Only \(name) runs this work on \(modelName).\(fallback) A pinned provider replaces the Speed choice."
        }
        guard let region else { return text }
        return text + " Only providers OpenRouter lists as running in \(region.name) may take it; with none up, the work fails."
    }

    @ViewBuilder
    private var hostList: some View {
        if let hosts = hosts.map(listedHosts) {
            if hosts.isEmpty {
                Text(region.map { "OpenRouter lists no provider in \($0.name) for \(modelName)." }
                    ?? "OpenRouter lists no providers for \(modelName).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                let shown = shownHosts(hosts)
                VStack(alignment: .leading, spacing: 0) {
                    hostHeaderRow
                    ForEach(shown, id: \.tag) { host in
                        hostRow(host)
                    }
                    if hosts.count > Self.collapsedHostCount {
                        Button(showsAllHosts ? "Fewer providers" : "\(hosts.count - shown.count) more providers…") {
                            showsAllHosts.toggle()
                        }
                        .buttonStyle(.hoverWash)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    }
                }
            }
        } else if loadFailed {
            Text("OpenRouter's provider list could not be read. Automatic and Cheapest still work.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading providers…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Every host, or with the region on, only those running in it: a host
    /// outside it can be neither seen nor pinned.
    private func listedHosts(_ hosts: [OpenRouterEndpointTier]) -> [OpenRouterEndpointTier] {
        guard region != nil else { return hosts }
        guard let regionTags else { return [] }
        return hosts.filter { regionTags.contains($0.tag.lowercased()) }
    }

    /// The cheapest few, with the pinned host always among them.
    private func shownHosts(_ hosts: [OpenRouterEndpointTier]) -> [OpenRouterEndpointTier] {
        guard !showsAllHosts else { return hosts }
        var shown = Array(hosts.prefix(Self.collapsedHostCount))
        if let tag = preference?.tag?.lowercased(),
           !shown.contains(where: { $0.tag.lowercased() == tag }),
           let pinned = hosts.first(where: { $0.tag.lowercased() == tag }) {
            shown.append(pinned)
        }
        return shown
    }

    private var hostHeaderRow: some View {
        HStack(spacing: 8) {
            Text("Provider").frame(maxWidth: .infinity, alignment: .leading)
            Text("In / out").frame(width: 110, alignment: .leading)
            Text("Speed").frame(width: 64, alignment: .leading)
            Text("Precision").frame(width: 62, alignment: .leading)
            Text("Uptime").frame(width: 56, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }

    private func hostRow(_ host: OpenRouterEndpointTier) -> some View {
        let isPinned = preference?.mode == .host && preference?.tag?.lowercased() == host.tag.lowercased()
        let detail = hostDetail(host)
        let location = providerLocation(of: host)
        return Button {
            save(OpenRouterHostPreference(
                mode: .host,
                tag: host.tag,
                hostName: host.providerName,
                allowsFallback: preference?.allowsFallback ?? true,
                region: region
            ))
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isPinned ? 1 : 0)
                    // The slot is kept on a row whose country is unknown, so
                    // every name starts in one column.
                    if providerLocations != nil {
                        Text(location?.flag ?? "")
                            .frame(width: 16)
                    }
                    Text(host.providerName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(AIModelListPrice.pairLabel(input: host.inputUSDPerMTokens, output: host.outputUSDPerMTokens))
                    .frame(width: 110, alignment: .leading)
                Text(tokensPerSecond[host.tag.lowercased()].map { OpenRouterModelSpeed.label(tokensPerSecond: $0) } ?? "–")
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(host.quantization ?? "–")
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(host.uptimePercent.map { Self.uptimeLabel($0) } ?? "–")
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPinned ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: isPinned ? 0.10 : 0.08))
        .help(hostHelp(host, location: location))
        .accessibilityLabel("\(host.providerName)\(detail.map { ", \($0)" } ?? "")\(location?.headquarters.map { ", headquarters \(OpenRouterProviderLocation.countryName($0))" } ?? ""), \(AIModelListPrice.pairLabel(input: host.inputUSDPerMTokens, output: host.outputUSDPerMTokens))\(isPinned ? ", selected" : "")")
        .accessibilityIdentifier("settings.models.host.row.\(host.tag)")
    }

    /// What tells two endpoints of one host apart: the tag's region or
    /// variant ("us", "fp4"), when it is not just the precision column again.
    private func hostDetail(_ host: OpenRouterEndpointTier) -> String? {
        let parts = host.tag.split(separator: "/").dropFirst().map(String.init)
        let extra = parts.filter { $0.lowercased() != host.quantization?.lowercased() }
        return extra.isEmpty ? nil : extra.joined(separator: " ")
    }

    /// Where the endpoint's provider says it is; nil when OpenRouter's list
    /// has not been read or does not say.
    private func providerLocation(of host: OpenRouterEndpointTier) -> OpenRouterProviderLocation? {
        providerLocations?[OpenRouterProviderDirectory.providerSlug(ofTag: host.tag)]
    }

    private func hostHelp(_ host: OpenRouterEndpointTier, location: OpenRouterProviderLocation?) -> String {
        var lines = ["\(host.providerName) (\(host.tag))"]
        if let context = host.contextLength, context > 0 {
            lines.append(context >= 1_000_000 ? "\(context / 1_000_000)M context" : "\(context / 1_000)k context")
        }
        if host.cachesPrompts { lines.append("caches prompts") }
        if let headquarters = location?.headquarters {
            lines.append("headquarters: \(OpenRouterProviderLocation.countryName(headquarters))")
        }
        if let datacenters = location?.datacenters, !datacenters.isEmpty {
            let names = datacenters.map(OpenRouterProviderLocation.countryName)
            lines.append("data centers: \(ListFormatter.localizedString(byJoining: names))")
        }
        return lines.joined(separator: " · ")
    }

    private static func uptimeLabel(_ percent: Double) -> String {
        percent >= 99.95 ? "100%" : String(format: "%.1f%%", percent)
    }

    private func save(_ newValue: OpenRouterHostPreference?) {
        preference = newValue
        OpenRouterHostPreference.set(newValue, slot: slotID, slug: slug)
        onHostChange()
    }

    /// The model's standard hosts, cheapest first, one row per endpoint tag.
    /// A lab's service tiers (fast, flex, priority) stay with the composer's
    /// Speed choice.
    private func load() async {
        let slug = slug
        preference = OpenRouterHostPreference.stored(slot: slotID, slug: slug)
        loadFailed = false
        async let locations = try? OpenRouterProviderDirectory.shared.locations()
        regionTags = (try? await OpenRouterRegionalEndpoints.shared.endpoints(for: slug, region: Self.region))
            .map { Set($0.map { $0.tag.lowercased() }) }
        do {
            let tiers = try await OpenRouterEndpointTierCatalog.shared.tiers(for: slug)
            var seen = Set<String>()
            hosts = tiers
                .filter { !OpenRouterSpeedTier.isServiceTier($0.tag) }
                .filter { seen.insert($0.tag.lowercased()).inserted }
                .sorted {
                    ($0.inputUSDPerMTokens + $0.outputUSDPerMTokens, $0.providerName)
                        < ($1.inputUSDPerMTokens + $1.outputUSDPerMTokens, $1.providerName)
                }
        } catch {
            hosts = nil
            loadFailed = true
        }
        providerLocations = await locations
        if let speeds = try? await OpenRouterModelSpeedCatalog.shared.speeds(for: slug) {
            tokensPerSecond = Dictionary(
                speeds
                    .filter { $0.requestCount >= OpenRouterModelSpeed.minimumRequests }
                    .map { ($0.tag.lowercased(), $0.medianTokensPerSecond) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
}

/// A maker's logo with SF Symbol fallback: what `OpenRouterMakerLogo` draws
/// for a maker the app bundles a logo for.
struct MakerLogo: View {
    let maker: AIModelMaker

    var body: some View {
        let iconName = maker.iconName
        if NSImage(named: iconName) != nil {
            Image(iconName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: maker.systemImageFallback)
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shared provider chip style used by settings model/provider selectors.
private struct ProviderCapsuleLabel: View {
    let title: String
    var iconName: String? = nil
    var systemImage: String? = nil
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let iconName, NSImage(named: iconName) != nil {
                Image(iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipped()
            } else if let systemImage {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .frame(width: 14, height: 14)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                : AnyShapeStyle(.clear),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(Capsule())
    }
}

/// Settings › Voice › Voice mode: the voice a conversation speaks in
/// (`Prefs.ReadAloud.voiceModeVoice`, synced, so the iPhone and
/// CarPlay speak in it too). A change applies to the next conversation; one
/// under way keeps its voice, as OpenAI holds a session's voice once it has spoken.
struct VoiceModeVoicePicker: View {
    @State private var voice = Self.stored

    private static var stored: String {
        RealtimeVoiceDefaults.resolvedVoice(Preferences.value(Prefs.ReadAloud.voiceModeVoice))
    }

    var body: some View {
        Picker("Voice", selection: Binding(
            get: { voice },
            set: { picked in
                voice = picked
                Preferences.set(picked, for: Prefs.ReadAloud.voiceModeVoice)
            }
        )) {
            ForEach(RealtimeVoiceDefaults.voices, id: \.self) { id in
                Text(RealtimeVoiceDefaults.voiceLabel(id)).tag(id)
            }
        }
        .fixedSize()
        .accessibilityIdentifier("settings.voice.voiceMode.voice")
        .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
            guard let keys = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String>,
                  keys.contains(Prefs.ReadAloud.voiceModeVoice.name) else { return }
            voice = Self.stored
        }
        // set_app_setting writes the same key on this Mac.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            let stored = Self.stored
            if stored != voice { voice = stored }
        }
    }
}
