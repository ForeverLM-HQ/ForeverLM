#if os(macOS)
import Foundation

/// What the Studio column's Audio overview tile opens: the options sheet for
/// one notebook, and — from a caller that already chose them — the sources.
struct AudioOverviewOptionsTarget: Identifiable, Equatable {
    let notebookID: String
    /// The sources to write from; nil reads the notebook's ticked sources
    /// (`AudioOverviewGeneratorService.notebookSourceIDs`).
    var sourceIDs: [String]? = nil

    var id: String { notebookID }
}

/// One audio overview as the notebook's outputs show it: a run still being
/// written, or a saved overview with its carrier.
struct AudioOverviewOutput: Identifiable, Equatable {
    enum State: Equatable {
        case writing(AudioOverviewStage)
        case saved
    }

    /// The Artifact id: the saved record's, or the one a run reserved.
    let id: String
    /// The notebook it is homed on; nil for one whose notebook was deleted.
    let notebookID: String?
    let title: String
    /// The source the script and its audio live on.
    let carrierSourceID: String
    let sourceCount: Int
    /// When it was made, or when its run started.
    let date: Date
    let state: State
    /// The recipe, once read from the body (`audioOverviewSettings(_:)`); a
    /// run carries the options it was started with.
    var settings: AudioOverviewSettings?
    var runOptions: AudioOverviewOptions?

    var isWriting: Bool {
        if case .writing = state { return true }
        return false
    }

    /// "Deep dive · 12 sources · about 12 min" for a saved overview whose
    /// recipe is read, "Writing the script" for a run, else the source count.
    var subtitle: String {
        switch state {
        case .writing(let stage):
            return stage.label
        case .saved:
            if let settings { return settings.headline }
            return sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        }
    }

    /// "Made from 12 sources · why complex I matters · 2 read from their
    /// ideas": the row menu's recipe line.
    var recipe: String? { settings?.recipe }

    /// The overviews by id, for a list that names them by id (the notebook
    /// Studio's outputs). A run and the record it has just saved share the
    /// reserved id until the run is let go; the saved one is kept, as
    /// `NotebookOutputs.outputs` lists it, so its row never shows Stop for
    /// an overview already made.
    static func byID(_ outputs: [AudioOverviewOutput]) -> [String: AudioOverviewOutput] {
        Dictionary(outputs.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            first.isWriting && !second.isWriting ? second : first
        })
    }
}

/// Where an overview's audio is, for its play button.
enum AudioOverviewPlayback: Equatable {
    /// Nothing is playing it or generating it: Play starts it, generating
    /// what is missing under the usual cost question.
    case idle
    case generating
    case playing
    case paused
}

extension StudioViewModel {

    // MARK: Studio tile

    /// The tile's first tap: the options sheet's target, or nil when this is
    /// not a notebook an overview can be made in — a team's notebook keeps
    /// no audio of its own yet.
    func audioOverviewOptionsTarget(notebookID: String, sourceIDs: [String]? = nil) -> AudioOverviewOptionsTarget? {
        guard let notebook = notebook(id: notebookID), notebook.isNotebook, notebook.teamID == nil else { return nil }
        return AudioOverviewOptionsTarget(notebookID: notebookID, sourceIDs: sourceIDs)
    }

    /// The tile's second tap, from the options sheet: write the overview the
    /// quote describes, show it in the notebook, and narrate it under the
    /// same cost question Listen asks. Nil when it was stopped or failed.
    @discardableResult
    func makeAudioOverview(_ quote: AudioOverviewQuote) async -> AudioOverviewResult? {
        await AudioOverviewGenerationCoordinator.shared.make(quote, in: self)
    }

    /// Stops a run still writing. Nothing is saved.
    func cancelAudioOverview(_ runID: String) {
        AudioOverviewGenerationCoordinator.shared.cancel(runID)
    }

    // MARK: Outputs

    /// Whether a record is an audio overview: by its kind, or — for one an
    /// older build saved back without the kind — by the script source its id
    /// names, which this Mac's library index answers without reading a body
    /// (`StudioArticlesStore.audioOverviewArtifactIDs`). Every list that
    /// leaves overviews out, or lists only them, asks this.
    func isAudioOverview(_ artifact: ArtifactRecord) -> Bool {
        GeneratedAudioOverview.isOverview(artifact) { _ in
            articlesStore.audioOverviewArtifactIDs.contains(artifact.id)
        }
    }

    /// The notebook's overviews: runs still writing first, then the saved
    /// ones newest first, archived and hidden ones left out. A view showing
    /// them observes `AudioOverviewGenerationCoordinator.shared` for the runs.
    func audioOverviews(inNotebook notebookID: String) -> [AudioOverviewOutput] {
        audioOverviewOutputs { artifact in
            artifact.homeNotebookID == notebookID || artifact.linkedNotebookIDs.contains(notebookID)
        } runs: { $0.notebookID == notebookID }
    }

    private func audioOverviewOutputs(
        where includes: (ArtifactRecord) -> Bool,
        runs includesRun: (AudioOverviewGenerationCoordinator.Run) -> Bool
    ) -> [AudioOverviewOutput] {
        let coordinator = AudioOverviewGenerationCoordinator.shared
        let running = coordinator.runs.filter(includesRun).reversed().map { run in
            AudioOverviewOutput(
                id: run.id,
                notebookID: run.notebookID,
                title: run.notebookTitle,
                carrierSourceID: run.carrierSourceID,
                sourceCount: run.sourceCount,
                date: run.startedAt,
                state: .writing(run.stage),
                runOptions: run.options
            )
        }
        let saved = artifacts
            .filter { artifact in
                !artifact.isArchived && !artifact.isHidden && artifact.teamID == nil
                    && !TeamContentIdentity.isDraftArtifactID(artifact.id)
                    && isAudioOverview(artifact) && includes(artifact)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .map { artifact in
                AudioOverviewOutput(
                    id: artifact.id,
                    notebookID: artifact.homeNotebookID,
                    title: artifact.title,
                    carrierSourceID: GeneratedAudioOverview.carrierSourceID(artifactID: artifact.id),
                    sourceCount: artifact.sourceIDs.count,
                    date: artifact.createdAt,
                    state: .saved,
                    settings: coordinator.cachedSettings(for: artifact)
                )
            }
        return Array(running) + saved
    }

    /// The notebook an overview is homed on, by title, for its row and Now
    /// Playing; nil when it has none.
    func audioOverviewNotebookTitle(_ artifactID: String) -> String? {
        guard let notebookID = artifacts.first(where: { $0.id == artifactID })?.homeNotebookID else { return nil }
        return notebook(id: notebookID)?.title
    }

    /// The sources an overview was written from, in order, that this Mac
    /// still holds: its row's Show Sources menu.
    func audioOverviewSources(_ artifactID: String) -> [StudioArticle] {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }) else { return [] }
        return artifact.sourceIDs.compactMap { articlesById[$0] }
    }

    /// An overview's recipe, read from its body once per revision.
    func audioOverviewSettings(_ artifactID: String) async -> AudioOverviewSettings? {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }) else { return nil }
        return await AudioOverviewGenerationCoordinator.shared.settings(for: artifact, storage: storage)
    }

    /// The carrier, when this Mac has it: an overview made on another Mac
    /// can arrive before its script does.
    func audioOverviewCarrier(_ artifactID: String) -> StudioArticle? {
        articlesById[GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)]
    }

    /// Where the play button stands. A view showing it observes
    /// `ArticleSpeechService.shared` and `SourceAudioGenerationQueue.shared`.
    func audioOverviewPlayback(_ artifactID: String) -> AudioOverviewPlayback {
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        let speech = ArticleSpeechService.shared
        if speech.isNarrating(carrierID) {
            return speech.isPaused ? .paused : .playing
        }
        if speech.backgroundGenerationSourceIDs.contains(carrierID)
            || SourceAudioGenerationQueue.shared.isGenerating(carrierID) {
            return .generating
        }
        return .idle
    }

    /// Play, pause or resume. Playing an overview with no audio yet generates
    /// it the way Listen does, cost question included.
    func toggleAudioOverviewPlayback(_ artifactID: String) {
        guard let carrier = audioOverviewCarrier(artifactID) else {
            showToast("This audio overview's script has not reached this Mac yet")
            return
        }
        let speech = ArticleSpeechService.shared
        if speech.isNarrating(carrier.id) {
            speech.pauseOrResume()
        } else {
            speech.startTextToSpeech(article: carrier)
        }
    }

    /// Opens the overview's script in the Reader, where Listen plays it too.
    func openAudioOverviewScript(_ artifactID: String) async {
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        guard articlesById[carrierID] != nil else {
            showToast("This audio overview's script has not reached this Mac yet")
            return
        }
        await revealSourceInReader(carrierID)
    }

    /// Deletes the overview: its record, its carrier and the carrier's audio
    /// (`AudioOverviewCleanup.deleteOverview`, the path `delete_doc` takes
    /// too). The caller confirms first.
    func deleteAudioOverview(_ artifactID: String) async {
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        do {
            try await AudioOverviewCleanup.deleteOverview(artifactID, storage: storage)
        } catch {
            logger.error("Deleting audio overview \(artifactID) failed: \(error.localizedDescription)")
            showToast("Could not delete the audio overview")
            return
        }
        articles.removeAll { $0.id == carrierID }
        do {
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Reloading the Docs after deleting an audio overview failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
