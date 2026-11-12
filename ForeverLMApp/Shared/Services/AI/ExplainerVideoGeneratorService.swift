import Foundation

// MARK: - Backends

/// The writer side of the pipeline, behind a protocol so the storage and
/// assembly side can be pinned in tests with a canned storyboard.
protocol ExplainerVideoStoryboardBackend: Sendable {
    func write(
        request: ExplainerVideoRequest,
        sourceTitle: String?,
        sourceText: String?,
        truncated: Bool
    ) async throws -> ExplainerVideoStoryboard
}

/// The video-model side: one prompt in, one clip's bytes out.
protocol ExplainerVideoClipBackend: Sendable {
    func generateClip(
        prompt: String,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution,
        subject: AIUsageSource?
    ) async throws -> GeneratedVideoClip
}

/// Joins the clips into one file and draws its poster. Returns the film's
/// duration in seconds.
protocol ExplainerVideoAssembling: Sendable {
    func assemble(clips: [URL], into videoURL: URL, poster posterURL: URL) async throws -> Double
}

/// Writes the storyboard with the learner's Explainer Writing model.
struct LiveExplainerVideoStoryboardBackend: ExplainerVideoStoryboardBackend {
    let aiService: AIService
    var subject: AIUsageSource? = nil

    func write(
        request: ExplainerVideoRequest,
        sourceTitle: String?,
        sourceText: String?,
        truncated: Bool
    ) async throws -> ExplainerVideoStoryboard {
        guard let config = KeychainService.resolveConfig(for: .explainerWriting) else {
            throw ExplainerVideoGenerationError.noModelConfigured
        }
        return try await aiService.writeExplainerVideoStoryboard(
            request: request,
            sourceTitle: sourceTitle,
            sourceText: sourceText,
            truncated: truncated,
            config: config,
            subject: subject
        )
    }
}

/// Draws clips through the managed proxy's job route.
struct LiveExplainerVideoClipBackend: ExplainerVideoClipBackend {
    func generateClip(
        prompt: String,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution,
        subject: AIUsageSource?
    ) async throws -> GeneratedVideoClip {
        try await ManagedVideoGeneration.generateClip(
            prompt: prompt,
            model: model,
            resolution: resolution,
            usageTask: GeneratedExplainerVideo.usageTask,
            source: subject
        )
    }
}

// MARK: - Progress, result, errors

/// Where one video is in its making, for the pane's progress row.
enum ExplainerVideoStage: Equatable, Sendable {
    case writingStoryboard
    /// Scenes finished so far, of how many.
    case drawingScenes(done: Int, total: Int)
    case stitching
    case saving

    var label: String {
        switch self {
        case .writingStoryboard: return "Writing the storyboard"
        case .drawingScenes(let done, let total): return "Drawing scene \(min(done + 1, total)) of \(total)"
        case .stitching: return "Stitching the film"
        case .saving: return "Saving"
        }
    }

    /// 0…1 for a progress bar: the storyboard is the first tenth, the scenes
    /// the next eight, stitching and saving the last.
    var fraction: Double {
        switch self {
        case .writingStoryboard: return 0.05
        case .drawingScenes(let done, let total): return 0.1 + 0.8 * (Double(done) / Double(max(total, 1)))
        case .stitching: return 0.92
        case .saving: return 0.98
        }
    }
}

struct ExplainerVideoGenerationResult: Sendable {
    let video: StudioArticle
    let manifest: ExplainerVideoManifest
}

enum ExplainerVideoGenerationError: LocalizedError, Equatable {
    case emptyConcept
    case sourceNotFound(String)
    case unsupportedSource(String)
    case noModelConfigured
    case emptyStoryboard
    case clipFailed(scene: Int, reason: String)
    case assemblyFailed(String)
    case contentRootUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyConcept:
            return "Say what the video should explain."
        case .sourceNotFound(let id):
            return "No source with id \(id) is in the library."
        case .unsupportedSource(let title):
            return "A video explainer can lean on a paper or an article, not on \"\(title)\"."
        case .noModelConfigured:
            return "No model is configured for Explainer Writing. Sign in and check AI Usage (the sidebar's OpenRouter button)."
        case .emptyStoryboard:
            return "The writer returned no storyboard."
        case .clipFailed(let scene, let reason):
            return "Scene \(scene) could not be drawn: \(reason)"
        case .assemblyFailed(let reason):
            return "The clips could not be joined: \(reason)"
        case .contentRootUnavailable:
            return "The library's content folder is not available, so the video has nowhere to go."
        }
    }
}

// MARK: - The pipeline

/// The video explainer pipeline: read the source's text if there is one, have
/// the writer storyboard the concept into eight-second scenes, draw every
/// scene with the video model, join the clips into one film with a poster,
/// and save the film as a video-typed source under Videos.
///
/// Runs off the main actor. Usage for the run is attributed to one activity
/// id, so Settings → AI activity shows the video as one line; the storyboard
/// is billed under Explainer Writing and every clip under `explainer_video`.
/// The cost question is the caller's: the coordinator asks before this runs,
/// with the exact figure the catalog computes from the published rate.
struct ExplainerVideoGeneratorService: Sendable {
    let storage: StorageService
    let storyboardBackend: any ExplainerVideoStoryboardBackend
    let clipBackend: any ExplainerVideoClipBackend
    let assembler: any ExplainerVideoAssembling
    let model: VideoGenerationModel
    let resolution: VideoGenerationCatalog.Resolution
    /// The absolute path of the content root the video's directory is made
    /// under; the row stores paths relative to it.
    let contentRootPath: String
    /// How many scenes are drawn at once. Providers serve a handful of video
    /// operations per account concurrently; three keeps a five-scene film
    /// under two rounds without tripping its rate limit.
    var clipConcurrency = 3
    var progress: @Sendable (ExplainerVideoStage) -> Void = { _ in }

    /// The types a video can lean on: the two whose text is a written argument.
    /// Its own set, not the Explainer's (`GeneratedExplainer.explainableSourceTypes`),
    /// which also explains talks, podcasts and meetings: a film is cut from an
    /// argument laid out in writing, not from a transcript.
    static let groundingSourceTypes: Set<StudioSourceType> = [.paper, .article]

    func run(request: ExplainerVideoRequest) async throws -> ExplainerVideoGenerationResult {
        try await AIUsageAttribution.withWorkflow {
            try await runStages(request: request)
        }
    }

    private func runStages(request: ExplainerVideoRequest) async throws -> ExplainerVideoGenerationResult {
        let concept = request.concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty else { throw ExplainerVideoGenerationError.emptyConcept }

        // 1. Ground. A source is optional; a named one must exist and be
        //    a paper or an article, and its text is cut to the budget.
        var source: StudioArticle?
        var sourceText: String?
        var truncated = false
        if let sourceID = request.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
            guard let found = try await storage.loadSourceWithoutContent(sourceID) else {
                throw ExplainerVideoGenerationError.sourceNotFound(sourceID)
            }
            guard Self.groundingSourceTypes.contains(found.sourceType),
                  !GeneratedExplainer.isSpokenScriptURL(found.url) else {
                throw ExplainerVideoGenerationError.unsupportedSource(found.title)
            }
            source = found
            if let text = await storage.loadSourceContent(found.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                let budgeted = GeneratedExplainerVideo.budgeted(text)
                sourceText = budgeted.text
                truncated = budgeted.truncated
            }
        }
        var sourceTitle = source?.title
        if source == nil, !request.groundingSourceIDs.isEmpty {
            // A notebook's video overview: its papers and articles together.
            var parts: [(title: String, text: String)] = []
            for id in request.groundingSourceIDs {
                guard let found = try await storage.loadSourceWithoutContent(id),
                      Self.groundingSourceTypes.contains(found.sourceType),
                      !GeneratedExplainer.isSpokenScriptURL(found.url),
                      let text = await storage.loadSourceContent(found.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                parts.append((found.title, text))
            }
            if !parts.isEmpty {
                let combined = GeneratedExplainerVideo.combined(parts)
                sourceText = combined.text
                truncated = combined.truncated
                sourceTitle = "\(parts.count) source\(parts.count == 1 ? "" : "s"): \(concept)"
            }
        }
        let subject = source.map { AIUsageSource(source: $0) }

        // 2. Storyboard.
        progress(.writingStoryboard)
        let storyboard = try await storyboardBackend.write(
            request: ExplainerVideoRequest(concept: concept, sourceID: source?.id, groundingSourceIDs: request.groundingSourceIDs, length: request.length),
            sourceTitle: sourceTitle,
            sourceText: sourceText,
            truncated: truncated
        )
        try Task.checkCancellation()
        guard storyboard.isUsable else { throw ExplainerVideoGenerationError.emptyStoryboard }

        // 3. Draw. The directory is made first so a clip lands on disk as it
        //    arrives rather than living in memory until the last one does.
        let videoID = GeneratedExplainerVideo.newVideoID()
        let directory = URL(fileURLWithPath: contentRootPath, isDirectory: true)
            .appendingPathComponent(GeneratedExplainerVideo.relativeDirectory(videoID: videoID), isDirectory: true)
        let clipsDirectory = directory.appendingPathComponent("Clips", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ExplainerVideoGenerationError.contentRootUnavailable
        }
        let total = storyboard.scenes.count
        progress(.drawingScenes(done: 0, total: total))
        let clipURLs: [URL]
        do {
            clipURLs = try await drawScenes(storyboard, into: clipsDirectory, subject: subject, total: total)
        } catch {
            Self.discard(directory)
            throw error
        }
        try Task.checkCancellation()

        // 4. Stitch.
        progress(.stitching)
        let videoURL = directory.appendingPathComponent("video.mp4")
        let posterURL = directory.appendingPathComponent("poster.jpg")
        let duration: Double
        do {
            duration = try await assembler.assemble(clips: clipURLs, into: videoURL, poster: posterURL)
        } catch is CancellationError {
            Self.discard(directory)
            throw CancellationError()
        } catch {
            Self.discard(directory)
            throw ExplainerVideoGenerationError.assemblyFailed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: clipsDirectory)
        try Task.checkCancellation()

        // 5. Save.
        progress(.saving)
        let manifest = ExplainerVideoManifest(
            videoID: videoID,
            concept: concept,
            sourceID: source?.id,
            length: request.length,
            storyboard: storyboard,
            model: model.id,
            resolution: resolution.rawValue,
            durationSeconds: duration,
            costUSD: VideoGenerationCatalog.clipCostUSD(model: model, resolution: resolution).map { $0 * Double(total) },
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)

        let video = Self.videoSource(videoID: videoID, storyboard: storyboard, source: source)
        do {
            try await storage.saveSource(video)
        } catch {
            Self.discard(directory)
            throw error
        }
        return ExplainerVideoGenerationResult(video: video, manifest: manifest)
    }

    /// Draws the scenes a few at a time and returns their files in scene order.
    private func drawScenes(
        _ storyboard: ExplainerVideoStoryboard,
        into clipsDirectory: URL,
        subject: AIUsageSource?,
        total: Int
    ) async throws -> [URL] {
        var urls = [URL?](repeating: nil, count: total)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var next = 0
            func enqueue() {
                guard next < total else { return }
                let index = next
                next += 1
                group.addTask {
                    let clip = try await clipBackend.generateClip(
                        prompt: storyboard.clipPrompt(sceneIndex: index),
                        model: model,
                        resolution: resolution,
                        subject: subject
                    )
                    let url = clipsDirectory.appendingPathComponent(String(format: "clip-%04d.mp4", index + 1))
                    try clip.data.write(to: url, options: .atomic)
                    return (index, url)
                }
            }
            for _ in 0..<min(clipConcurrency, total) { enqueue() }
            do {
                while let (index, url) = try await group.next() {
                    urls[index] = url
                    done += 1
                    progress(.drawingScenes(done: done, total: total))
                    enqueue()
                }
            } catch let error as ManagedVideoGeneration.Failure {
                group.cancelAll()
                throw ExplainerVideoGenerationError.clipFailed(scene: done + 1, reason: error.localizedDescription)
            } catch {
                group.cancelAll()
                throw error
            }
        }
        return urls.compactMap { $0 }
    }

    private static func discard(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The film as a video-typed source with its narration attached, ready to
    /// list, search, review and sync. The row points at the file by a path
    /// relative to the content root, the way every local source does.
    static func videoSource(
        videoID: String,
        storyboard: ExplainerVideoStoryboard,
        source: StudioArticle?
    ) -> StudioArticle {
        var video = StudioArticle(
            url: GeneratedExplainerVideo.url(videoID: videoID),
            title: storyboard.title.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceType: .video,
            artworkURL: GeneratedExplainerVideo.relativePosterPath(videoID: videoID),
            discoveryOrigin: .manual,
            localFilePath: GeneratedExplainerVideo.relativeVideoPath(videoID: videoID),
            author: source?.author,
            journal: source?.journal,
            publishedYear: source?.publishedYear
        )
        video.domain = GeneratedExplainerVideo.domain
        let script = storyboard.script
        video.content = script
        video.wordCount = ExplainerScript.wordCount(of: script)
        video.state = .ready
        return video
    }
}
