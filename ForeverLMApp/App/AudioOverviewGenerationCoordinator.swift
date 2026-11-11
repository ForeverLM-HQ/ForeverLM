#if os(macOS)
import Foundation
import SwiftUI

/// What making an overview will cost, before anything is spent: the writing
/// (the script and any condensing) on the Audio Overview Writing route, and
/// the narration with the learner's text-to-speech voice, quoted the way Listen
/// quotes a source (`ArticleSpeechCostEstimate`). The options sheet shows it
/// beside Make; `generate_audio_overview` answers with it.
struct AudioOverviewQuote: Sendable {
    let plan: AudioOverviewPlan
    /// The narration of a script at the plan's upper length.
    let audio: ArticleSpeechCostEstimate
    let speechProvider: String
    let speechModel: String
    let voice: String
    /// "Gemini 3.1 Flash TTS · Kore"
    let voiceLabel: String
    /// Automatic audio is on for explainers and the voice is one automation
    /// may spend on: that standing opt-in is the consent, and the audio
    /// starts without the cost question, as an explainer's does.
    let audioStartsAutomatically: Bool
    /// Why the learner's text-to-speech setting cannot narrate right now — a
    /// voice or model no longer offered (`MacArticleSpeechSettings.configurationError`)
    /// — or nil when it can. The sheet says so in place of the audio price
    /// and offers no Make; `generate_audio_overview` refuses to narrate.
    let speechConfigurationError: String?
    /// "<old model> is no longer offered; using <new model>." when the
    /// stored pick is one OpenRouter stopped offering and the narration will
    /// use its repair; said beside the price and in the MCP answer.
    var speechSelectionNotice: String? = nil

    var audioIsFree: Bool { audio.usd == 0 }

    /// "about 12 min · $0.40", "about 12 min · free", "about 12 min · price unknown"
    var audioLabel: String { "\(audio.durationLabel) · \(audio.costLabel)" }

    /// Writing plus audio at the expected figures; nil when either is unpriced.
    var expectedTotalUSD: Double? {
        guard let writing = plan.writingCost.expectedUSD, let audio = audio.usd else { return nil }
        return writing + audio
    }

    /// Prices `plan` with the learner's current text-to-speech selection. Reads
    /// OpenRouter's speech list first, as Listen's quote does, so a model
    /// this Mac has not priced yet is not quoted as unknown.
    static func current(for plan: AudioOverviewPlan) async -> AudioOverviewQuote {
        await OpenRouterAudioDirectory.prepare(.speech)
        let provider = MacArticleSpeechSettings.provider
        // A pick OpenRouter stopped offering is quoted as the narration will
        // repair it (`MacArticleSpeechSettings.repairSelectionForUse`); the
        // quote itself writes nothing.
        let selection: (model: String, voice: String, repair: MacArticleSpeechSettings.SelectionRepair?) =
            provider == .openRouter
                ? MacArticleSpeechSettings.selectionForQuote()
                : (MacArticleSpeechSettings.model(for: provider), MacArticleSpeechSettings.voice(for: provider), nil)
        let model = selection.model
        let voice = selection.voice
        let modelName = ArticleSpeechCatalog.model(id: model)?.name ?? model
        return AudioOverviewQuote(
            plan: plan,
            audio: ArticleSpeechCostEstimate(
                characters: plan.expectedScriptCharacters,
                provider: provider.rawValue,
                model: model
            ),
            speechProvider: provider.rawValue,
            speechModel: model,
            voice: voice,
            voiceLabel: "\(modelName) · \(ArticleSpeechCatalog.voiceLabel(model: model, voice: voice))",
            audioStartsAutomatically: MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(
                kind: SourceAudioAutomation.explainerKind
            ),
            speechConfigurationError: selection.repair == nil ? MacArticleSpeechSettings.configurationError : nil,
            speechSelectionNotice: selection.repair?.message
        )
    }

    /// Whether this quote already approved narrating the script as written,
    /// which costs `actualUSD` with `provider`'s `model`: the learner agreed
    /// to the audio's price when they made the overview, so a script that
    /// costs no more with the same voice is narrated without asking again.
    /// A dearer script than quoted, a voice changed since, or a price this
    /// Mac cannot read is asked about as Listen asks.
    func approvesNarration(costing actualUSD: Double?, provider: String, model: String) -> Bool {
        guard provider == speechProvider, model == speechModel,
              let quoted = audio.usd, let actualUSD else { return false }
        return actualUSD <= quoted
    }
}

/// What an audio overview's audio leaves on this Mac, and how it goes when
/// the overview does — shared by the row's Delete, `delete_doc`, and
/// `delete_source` on the script, so no path leaves narration playing, a
/// generation running, or files behind.
@MainActor
enum AudioOverviewCleanup {
    /// Stops what plays or makes the script's audio: the narration, the
    /// app's own generation, and the text-to-speech queue's.
    static func stopAudio(ofCarrier carrierID: String) {
        let speech = ArticleSpeechService.shared
        if speech.isNarrating(carrierID) { speech.stop() }
        speech.cancelBackgroundGeneration(sourceID: carrierID)
        _ = SourceAudioGenerationQueue.shared.cancel(sourceIDs: [carrierID])
    }

    /// Removes the script's audio files: its folder in the iCloud Audio tree,
    /// which iCloud then removes from every device, and this Mac's
    /// per-request cache. Blocking file work, off the main actor.
    nonisolated static func removeAudioFiles(ofCarrier carrierID: String) async {
        await Task.detached(priority: .utility) {
            ArticleSpeechAudioCache.deleteCachedAudio(sourceID: carrierID)
        }.value
    }

    /// Deletes an overview — its record and, in the store's own transaction,
    /// its script source — with its audio. `removeAudioFiles` is the file
    /// step, which a test hands in.
    static func deleteOverview(
        _ artifactID: String,
        storage: StorageService,
        removeAudioFiles: @Sendable (String) async -> Void = { await AudioOverviewCleanup.removeAudioFiles(ofCarrier: $0) }
    ) async throws {
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        stopAudio(ofCarrier: carrierID)
        try await storage.deleteArtifact(artifactID)
        await removeAudioFiles(carrierID)
    }

    /// Deletes an overview by its script source, which takes the record with
    /// it (`StorageService.deleteSource`), with its audio.
    static func deleteCarrier(
        _ carrierID: String,
        storage: StorageService,
        removeAudioFiles: @Sendable (String) async -> Void = { await AudioOverviewCleanup.removeAudioFiles(ofCarrier: $0) }
    ) async throws {
        stopAudio(ofCarrier: carrierID)
        try await storage.deleteSource(carrierID)
        await removeAudioFiles(carrierID)
    }
}

/// The Mac's audio overviews in the making, shared by the Studio column's
/// tile and outputs row and by `generate_audio_overview`: write the script,
/// save it, then hand the carrier to the same audio path Listen and the
/// explainer use, so the cost question, the language check and the progress
/// are the ones the learner already knows.
///
/// A run is the coordinator's own task, not the caller's, so Cancel — on the
/// pending row, or `cancel_ai_work` — ends it from anywhere while a request
/// is still out. The service checks for cancellation before it saves, so a
/// stopped run leaves nothing behind.
@MainActor
final class AudioOverviewGenerationCoordinator: ObservableObject {
    static let shared = AudioOverviewGenerationCoordinator()

    /// One overview being written: the id it will be saved under, its
    /// notebook, what was asked for, and where it is.
    struct Run: Identifiable, Equatable {
        /// The Artifact id reserved for the overview.
        let id: String
        let notebookID: String
        let notebookTitle: String
        let options: AudioOverviewOptions
        let sourceCount: Int
        let startedAt: Date
        var stage: AudioOverviewStage

        /// The carrier the script and audio will live on.
        var carrierSourceID: String { GeneratedAudioOverview.carrierSourceID(artifactID: id) }

        /// "Deep dive · 12 sources"
        var headline: String {
            "\(options.format.label) · \(sourceCount == 1 ? "1 source" : "\(sourceCount) sources")"
        }
    }

    /// What became of an overview whose script source a caller may ask
    /// about once its run has ended: the writing failed or was stopped, so
    /// there is no script, or the script was saved and its audio could not
    /// start. `get_source_audio_status` answers with it.
    struct Note: Equatable {
        enum Kind: Equatable {
            case writingFailed
            case writingStopped
            case audioNotStarted
        }

        let overviewID: String
        let kind: Kind
        let message: String
    }

    /// Overviews being written right now, oldest first.
    @Published private(set) var runs: [Run] = []
    /// The last note for each script source, by its id. Kept for the
    /// session; a new run for the same overview replaces it.
    private var notes: [String: Note] = [:]
    private var tasks: [String: Task<Result<AudioOverviewResult, Error>, Never>] = [:]
    /// Recipes read from overview bodies, by record id and revision, so a
    /// row asks the disk once per change.
    private var settingsCache: [String: (updatedAt: Date, settings: AudioOverviewSettings)] = [:]

    /// The runs writing into one notebook, oldest first.
    func runs(inNotebook notebookID: String) -> [Run] {
        runs.filter { $0.notebookID == notebookID }
    }

    func run(_ id: String) -> Run? {
        runs.first { $0.id == id }
    }

    /// The run writing a carrier that does not exist yet, for
    /// `get_source_audio_status`.
    func run(writingCarrier sourceID: String) -> Run? {
        runs.first { $0.carrierSourceID == sourceID }
    }

    /// What became of the overview a script source belongs to, once its run
    /// ended without a script or its audio could not start.
    func note(forCarrier sourceID: String) -> Note? {
        notes[sourceID]
    }

    /// The script was saved but its audio did not start, and why.
    func noteAudioNotStarted(overviewID: String, message: String) {
        notes[GeneratedAudioOverview.carrierSourceID(artifactID: overviewID)] = Note(
            overviewID: overviewID,
            kind: .audioNotStarted,
            message: message
        )
    }

    // MARK: Quote

    /// Reads the notebook once for an options sheet: every selected source's
    /// text and ideas. `sourceIDs` nil reads the notebook's ticked sources
    /// (`AudioOverviewGeneratorService.notebookSourceIDs`).
    nonisolated static func loadNotebook(
        notebookID: String,
        sourceIDs: [String]? = nil,
        storage: StorageService
    ) async throws -> AudioOverviewNotebook {
        try await AudioOverviewGeneratorService(
            storage: storage,
            backend: LiveAudioOverviewModelBackend(aiService: AIService())
        ).load(notebookID: notebookID, sourceIDs: sourceIDs)
    }

    /// Fits a loaded notebook to the learner's writing route and prices it.
    /// Cheap: the sheet re-quotes on every change of option.
    nonisolated static func quote(
        _ notebook: AudioOverviewNotebook,
        request: AudioOverviewRequest
    ) async throws -> AudioOverviewQuote {
        guard let route = LiveAudioOverviewModelBackend.currentRoute() else {
            throw AudioOverviewGenerationError.noModelConfigured
        }
        let plan = try AudioOverviewGeneratorService.plan(notebook, request: request, route: route)
        return await AudioOverviewQuote.current(for: plan)
    }

    // MARK: Make

    /// The Studio tile's second tap: write the overview the quote describes,
    /// then narrate it. Make on the sheet agreed to the quoted audio price,
    /// so a script that costs no more with the same voice is narrated without
    /// asking twice; so is one the Explainers automatic-audio switch covers.
    /// A script that came out dearer than quoted, or a voice changed since,
    /// gets the interactive cost question, exactly as Listen asks it.
    /// Returns the saved overview, or nil when it was stopped or failed
    /// (said in a toast).
    @discardableResult
    func make(_ quote: AudioOverviewQuote, in vm: StudioViewModel) async -> AudioOverviewResult? {
        let plan = quote.plan
        let title = plan.notebookTitle
        let result = await write(plan, storage: vm.storage)
        switch result {
        case .failure(let error):
            if error is CancellationError {
                vm.showToast("Stopped writing the audio overview of \(title)")
            } else {
                vm.showToast(error.localizedDescription)
            }
            return nil
        case .success(let overview):
            await show(overview, in: vm)
            if let error = quote.speechConfigurationError {
                vm.showToast("Audio overview written. \(error)")
                return overview
            }
            let provider = MacArticleSpeechSettings.provider
            // The model the narration will use: a vanished pick as the quote
            // priced its repair, which the narration then writes back.
            let model = provider == .openRouter
                ? MacArticleSpeechSettings.selectionForQuote().model
                : MacArticleSpeechSettings.model(for: provider)
            let actual = ArticleSpeechCostEstimate(
                characters: overview.carrier.content?.count ?? 0,
                provider: provider.rawValue,
                model: model
            )
            let approved = quote.audioStartsAutomatically
                || quote.approvesNarration(costing: actual.usd, provider: provider.rawValue, model: model)
            let interaction: ArticleSpeechGenerationInteraction = approved
                ? .headless(costApproved: true, allowsUnsupportedLanguage: false)
                : .interactive
            switch await ArticleSpeechService.shared.generateAudio(article: overview.carrier, interaction: interaction) {
            case .started:
                vm.showToast("Audio overview written; generating its audio")
            case .alreadyReady, .alreadyGenerating, .cancelled:
                vm.showToast("Audio overview written")
            case .failed(let message), .unsupportedLanguage(let message):
                vm.showToast("Audio overview written. \(message)")
            case .needsCostApproval:
                // The interactive request asks inside generateAudio, and the
                // headless one above approved the spend.
                break
            }
            return overview
        }
    }

    /// Writes and saves `plan` under `artifactID` as a run of this
    /// coordinator, listed until it ends, and returns when it has ended.
    /// `generate_audio_overview` calls this from its background work, so an
    /// overview an assistant started shows as a pending row in the notebook
    /// and its Cancel stops it.
    func write(
        _ plan: AudioOverviewPlan,
        artifactID: String = UUID().uuidString.lowercased(),
        storage: StorageService,
        backend: (any AudioOverviewModelBackend)? = nil,
        onStage: (@Sendable (AudioOverviewStage) async -> Void)? = nil
    ) async -> Result<AudioOverviewResult, Error> {
        guard tasks[artifactID] == nil else { return .failure(CancellationError()) }
        let service = AudioOverviewGeneratorService(
            storage: storage,
            backend: backend ?? LiveAudioOverviewModelBackend(aiService: AIService())
        )
        let initial = AudioOverviewStage.reading(sourceCount: plan.sources.count)
        runs.append(Run(
            id: artifactID,
            notebookID: plan.request.notebookID,
            notebookTitle: plan.notebookTitle,
            options: plan.options,
            sourceCount: plan.sources.count,
            startedAt: Date(),
            stage: initial
        ))
        // Inherits the caller's task-locals, among them an MCP call's
        // running-work id, so the usage ledger counts this run against the
        // spend the assistant was approved for.
        let task = Task<Result<AudioOverviewResult, Error>, Never> {
            do {
                let result = try await service.run(plan, artifactID: artifactID) { stage in
                    await self.setStage(stage, for: artifactID)
                    await onStage?(stage)
                }
                return .success(result)
            } catch {
                // A cancelled request can surface as its own CancellationError
                // or as the transport's cancelled error wrapped by the
                // provider; either way someone asked for it.
                if error is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
                return .failure(error)
            }
        }
        tasks[artifactID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[artifactID] = nil
        runs.removeAll { $0.id == artifactID }
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        switch result {
        case .success(let overview):
            settingsCache[overview.artifact.id] = (overview.artifact.updatedAt, overview.settings)
            notes[carrierID] = nil
        case .failure(let error) where error is CancellationError:
            notes[carrierID] = Note(
                overviewID: artifactID,
                kind: .writingStopped,
                message: "The writing was stopped before the overview was saved; nothing was kept."
            )
        case .failure(let error):
            notes[carrierID] = Note(overviewID: artifactID, kind: .writingFailed, message: error.localizedDescription)
        }
        return result
    }

    /// Stops the run. Nothing is saved.
    func cancel(_ runID: String) {
        tasks[runID]?.cancel()
    }

    private func setStage(_ stage: AudioOverviewStage, for id: String) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].stage = stage
    }

    /// The saved overview in the open window's lists: its carrier in the
    /// library the Reader resolves from (hidden from every list), and its
    /// record among the artifacts.
    func show(_ overview: AudioOverviewResult, in vm: StudioViewModel) async {
        await vm.refreshAfterCloudKitRemoteChange(affectedEntities: [.source], requiresFullRefresh: false)
        // The partial refresh can return before the new row is in the list;
        // the saved record is in hand, so the list takes it directly, as the
        // explainer's does.
        if let index = vm.articles.firstIndex(where: { $0.id == overview.carrier.id }) {
            vm.articles[index] = overview.carrier
        } else {
            vm.articles.insert(overview.carrier, at: 0)
        }
        let reloaded = await vm.loggedRead("the Docs") { try await vm.loadScopedArtifacts() }
        if let reloaded {
            vm.artifacts = reloaded
        }
    }

    // MARK: Recipe

    /// The recipe an overview's body carries, read once per revision. Nil
    /// for a record whose body this build cannot read.
    func settings(for artifact: ArtifactRecord, storage: StorageService) async -> AudioOverviewSettings? {
        if let cached = settingsCache[artifact.id], cached.updatedAt == artifact.updatedAt {
            return cached.settings
        }
        guard let snapshot = try? await storage.artifactMarkdown(artifact.id),
              let settings = AudioOverviewScript.settings(fromMarkdown: snapshot.markdown) else { return nil }
        settingsCache[artifact.id] = (artifact.updatedAt, settings)
        return settings
    }

    /// A recipe already read, without touching the disk.
    func cachedSettings(for artifact: ArtifactRecord) -> AudioOverviewSettings? {
        guard let cached = settingsCache[artifact.id], cached.updatedAt == artifact.updatedAt else { return nil }
        return cached.settings
    }
}
#endif
