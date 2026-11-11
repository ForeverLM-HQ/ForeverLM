#if os(macOS)
import AppKit
import Foundation
import OSLog
import SwiftUI

/// The Mac's Explainer Video action, shared by the Videos pane's composer and
/// the sidebar's context menu: ask the price, storyboard the concept, film the
/// scenes, join them, save the film under Videos and show it.
///
/// The run is the coordinator's own task, not the caller's, so Cancel on the
/// pane's progress row can end it while clips are still out to the model. The
/// pipeline checks for cancellation between stages and discards its directory,
/// so a stopped run leaves nothing behind — except the clips already finished,
/// which OpenRouter has charged for by then.
@MainActor
final class ExplainerVideoGenerationCoordinator: ObservableObject {
    static let shared = ExplainerVideoGenerationCoordinator()
    private static let logger = Logger(subsystem: "com.foreverlm", category: "ExplainerVideo")

    /// One video being made.
    struct Job: Identifiable, Equatable {
        let id: String
        let concept: String
        let sourceID: String?
        let length: ExplainerVideoLength
        let model: VideoGenerationModel
        let resolution: VideoGenerationCatalog.Resolution
        let startedAt: Date
        var stage: ExplainerVideoStage = .writingStoryboard
    }

    /// The videos being made right now, oldest first.
    @Published private(set) var jobs: [Job] = []
    /// The composer's open draft. Held here rather than in the pane's own
    /// state so a pane rebuilt under it — the library finishing its load, a
    /// pane moved to another group — keeps the sheet the learner is typing in.
    @Published var composeDraft: ExplainerVideoComposeDraft?

    /// Opens the composer with these fields filled in.
    func compose(concept: String? = nil, sourceID: String? = nil) {
        composeDraft = ExplainerVideoComposeDraft(concept: concept ?? "", sourceID: sourceID)
    }
    private var tasks: [String: Task<Void, Never>] = [:]

    var isGenerating: Bool { !jobs.isEmpty }

    /// Asks the price, then makes the video. Returns once the run has ended,
    /// however it ended; false when the learner declined the cost.
    @discardableResult
    func generate(_ request: ExplainerVideoRequest, in vm: StudioViewModel) async -> Bool {
        guard let (model, resolution) = await Self.filmingChoice(),
              Self.confirmCost(request: request, model: model, resolution: resolution) else { return false }
        let jobID = UUID().uuidString
        let job = Job(
            id: jobID,
            concept: request.concept.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceID: request.sourceID,
            length: request.length,
            model: model,
            resolution: resolution,
            startedAt: Date()
        )
        jobs.append(job)
        let task = Task { await self.run(job, request: request, in: vm) }
        tasks[jobID] = task
        await task.value
        return true
    }

    /// Asks the price, then starts the video and returns without waiting for
    /// the film: the job once it is under way, nil when the learner
    /// declined the cost or the model is not priced. What a chat tool calls, so
    /// a turn does not sit for minutes while the model films. With `lectureID`
    /// the finished video is filed under that course module as its video;
    /// with `notebookID` it joins that notebook's sources (a video is a source,
    /// so the pool is its home there; docs/notebooks-design.md, "Homing").
    func start(_ request: ExplainerVideoRequest, in vm: StudioViewModel, lectureID: String? = nil, notebookID: String? = nil) async -> Job? {
        guard let (model, resolution) = await Self.filmingChoice(),
              Self.confirmCost(request: request, model: model, resolution: resolution) else { return nil }
        let job = Job(
            id: UUID().uuidString,
            concept: request.concept.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceID: request.sourceID,
            length: request.length,
            model: model,
            resolution: resolution,
            startedAt: Date()
        )
        jobs.append(job)
        tasks[job.id] = Task { await self.run(job, request: request, in: vm, lectureID: lectureID, notebookID: notebookID) }
        return job
    }

    /// Stops making the video. Its directory is discarded; the source row is
    /// never written.
    func cancel(_ jobID: String) {
        tasks[jobID]?.cancel()
    }

    private func run(_ job: Job, request: ExplainerVideoRequest, in vm: StudioViewModel, lectureID: String? = nil, notebookID: String? = nil) async {
        defer {
            tasks[job.id] = nil
            jobs.removeAll { $0.id == job.id }
        }
        var subject: AIUsageSource?
        if let sourceID = request.sourceID, let source = vm.articles.first(where: { $0.id == sourceID }) {
            subject = AIUsageSource(source: source)
        }
        let service = ExplainerVideoGeneratorService(
            storage: vm.storage,
            storyboardBackend: LiveExplainerVideoStoryboardBackend(aiService: AIService(), subject: subject),
            clipBackend: LiveExplainerVideoClipBackend(),
            assembler: ExplainerVideoAssembler(),
            model: job.model,
            resolution: job.resolution,
            // The local content root, where every other local source's file
            // lives and where a stored relative path resolves without a search.
            // Carrying the film through iCloud like Audio is a target change.
            contentRootPath: StorageService.libraryRootPath,
            progress: { [weak self] stage in
                Task { @MainActor in self?.update(job.id, stage: stage) }
            }
        )
        let result: ExplainerVideoGenerationResult
        do {
            result = try await service.run(request: request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                Self.logger.notice("Video about \(job.concept, privacy: .public) cancelled at \(job.stage.label, privacy: .public)")
                vm.showToast("Stopped making the video about \(job.concept)")
            } else {
                // The toast is fleeting; the failure stays in the log with the
                // stage it happened at, which is what a report needs.
                Self.logger.error("Video about \(job.concept, privacy: .public) failed at \(self.jobs.first { $0.id == job.id }?.stage.label ?? job.stage.label, privacy: .public): \(String(describing: error), privacy: .public)")
                vm.showToast(error.localizedDescription)
            }
            return
        }
        Self.logger.notice("Video about \(job.concept, privacy: .public) saved as \(result.video.id, privacy: .public) after \(Int(Date().timeIntervalSince(job.startedAt)), privacy: .public) s")
        let seconds = Int(result.manifest.durationSeconds.rounded())
        // The notebook's pool is read again with the sources when the video
        // joined one, so its Sources column shows it.
        var refreshed: Set<CloudKitSyncEntity> = [.source]
        if let notebookID {
            // The notebook it was made for holds it. A notebook that went in
            // the minutes of filming leaves the video under Videos alone.
            do {
                _ = try await vm.storage.addCompanionSeedSources(goalID: notebookID, sourceIDs: [result.video.id])
                refreshed.insert(.learningGoal)
            } catch {
                Self.logger.error("Video \(result.video.id, privacy: .public) could not join Notebook \(notebookID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let lectureID {
            // A course's video: filed under its module, where the learner
            // meets it, rather than pulling the window over to Videos.
            do {
                let lecture = try await Self.attach(videoID: result.video.id, toLecture: lectureID, storage: vm.storage)
                await vm.refreshAfterCloudKitRemoteChange(affectedEntities: refreshed.union([.course]), requiresFullRefresh: false)
                vm.showToast("Video ready in \(lecture): \(result.video.title) (\(seconds) s)")
            } catch {
                Self.logger.error("Video \(result.video.id, privacy: .public) could not be filed under lecture \(lectureID, privacy: .public): \(String(describing: error), privacy: .public)")
                await vm.refreshAfterCloudKitRemoteChange(affectedEntities: refreshed, requiresFullRefresh: false)
                vm.showToast("Video ready under Videos, but its module is gone: \(result.video.title)")
            }
            return
        }
        await vm.refreshAfterCloudKitRemoteChange(affectedEntities: refreshed, requiresFullRefresh: false)
        vm.openVideosInReader()
        vm.explainerVideoRevealRequest = ExplainerVideoRevealRequest(sourceID: result.video.id)
        vm.showToast("Video ready: \(result.video.title) (\(seconds) s)")
    }

    enum LectureAttachError: Error { case lectureGone }

    /// Adds the video to the module as its `video` material, after what the
    /// module already holds. Returns the module's title for the toast.
    static func attach(videoID: String, toLecture lectureID: String, storage: StorageService) async throws -> String {
        guard let lecture = try await storage.loadCourseLectures().first(where: { $0.id == lectureID }) else {
            throw LectureAttachError.lectureGone
        }
        let items = try await storage.loadCourseLectureItems().filter { $0.lectureId == lectureID }
        if !items.contains(where: { $0.sourceId == videoID }) {
            let next = (items.map(\.sortIndex).max() ?? -1) + 1
            _ = try await storage.saveCourseLectureItem(
                CourseLectureItem(lectureId: lectureID, sourceId: videoID, role: .video, sortIndex: next)
            )
        }
        return lecture.title ?? "Lecture \(lecture.number)"
    }

    private func update(_ jobID: String, stage: ExplainerVideoStage) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].stage = stage
    }

    /// The Settings choice resolved against OpenRouter's video directory, and
    /// the resolution it films at. Nil after saying why, when the directory
    /// cannot be read or no longer lists the model: nothing is filmed on a
    /// model the learner did not pick.
    static func filmingChoice() async -> (VideoGenerationModel, VideoGenerationCatalog.Resolution)? {
        do {
            let model = try await VideoGenerationDirectory.resolve(MacVideoGenerationSettings.model)
            let stored = Preferences.value(Prefs.Imaging.videoResolution)
            return (model, VideoGenerationCatalog.resolvedResolution(stored, for: model))
        } catch {
            let alert = NSAlert()
            alert.messageText = "The video model is not available"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
    }

    /// The cost question, asked every time: a video costs dollars, so unlike a
    /// voice there is no "don't ask again". The figure is exact — scenes ×
    /// the model's clip length × its published rate — and the storyboard's
    /// text call is named beside it so nothing about the bill is a surprise. A
    /// model OpenRouter prices by video tokens has no figure before it films,
    /// and the question says so instead of guessing one.
    static func confirmCost(
        request: ExplainerVideoRequest,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Make a video explainer?"
        let detail = request.length.detail(clipSeconds: model.clipSeconds)
        if let cost = GeneratedExplainerVideo.estimatedCostUSD(length: request.length, model: model, resolution: resolution) {
            alert.informativeText = """
                \(model.name) at \(resolution.displayName) · \(detail)
                \(VideoGenerationCatalog.costLabel(cost)) for the video, plus one Explainer Writing call for the storyboard.
                """
        } else if model.pricedByTokens {
            alert.informativeText = """
                \(model.name) at \(resolution.displayName) · \(detail)
                OpenRouter prices this model by video tokens, so the cost of its \(request.length.sceneCount) clips is known only once they are made; it is charged at OpenRouter's price. Plus one Explainer Writing call for the storyboard.
                """
        } else {
            alert.informativeText = "\(model.name) is not priced at \(resolution.displayName). Choose another resolution in Settings › Videos."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        alert.addButton(withTitle: "Make Video")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
