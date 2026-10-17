import Foundation
import Testing
@testable import ForeverLM

/// A writer that answers with a canned storyboard.
private struct CannedStoryboardBackend: ExplainerVideoStoryboardBackend {
    var storyboard: ExplainerVideoStoryboard
    var recorder: StoryboardCallRecorder? = nil

    func write(
        request: ExplainerVideoRequest,
        sourceTitle: String?,
        sourceText: String?,
        truncated: Bool
    ) async throws -> ExplainerVideoStoryboard {
        recorder?.record(sourceTitle: sourceTitle, sourceText: sourceText, truncated: truncated)
        return storyboard
    }
}

private final class StoryboardCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(sourceTitle: String?, sourceText: String?, truncated: Bool)] = []
    var calls: [(sourceTitle: String?, sourceText: String?, truncated: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func record(sourceTitle: String?, sourceText: String?, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        stored.append((sourceTitle, sourceText, truncated))
    }
}

/// A video model that hands back a few bytes per scene and remembers each prompt.
private final class CannedClipBackend: ExplainerVideoClipBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPrompts: [String] = []
    var failAtCall: Int? = nil

    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedPrompts
    }

    func generateClip(
        prompt: String,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution,
        subject: AIUsageSource?
    ) async throws -> GeneratedVideoClip {
        let call: Int
        lock.lock()
        storedPrompts.append(prompt)
        call = storedPrompts.count
        lock.unlock()
        if let failAtCall, call == failAtCall {
            throw ManagedVideoGeneration.Failure.generationFailed("Prompt blocked.")
        }
        return GeneratedVideoClip(data: Data("clip \(prompt.prefix(8))".utf8), durationSeconds: 8, costUSD: 0.8, requestID: "r\(call)")
    }
}

/// Joins nothing: writes the clip count into the output so the film's contents
/// can be checked, and returns eight seconds a clip.
private struct CountingAssembler: ExplainerVideoAssembling {
    func assemble(clips: [URL], into videoURL: URL, poster posterURL: URL) async throws -> Double {
        try Data("film of \(clips.count)".utf8).write(to: videoURL)
        try Data("poster".utf8).write(to: posterURL)
        return Double(clips.count * 8)
    }
}

private func makeTemporaryStorage() -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExplainerVideoTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

private let fiveScenes = ExplainerVideoStoryboard(
    title: "Why Mitochondria Pump Protons",
    style: "Soft watercolor animation, warm amber palette, slow dolly shots.",
    scenes: (1...5).map {
        ExplainerVideoScene(narration: "Scene \($0) narration, said plainly.", visual: "Scene \($0) visual: a membrane in soft light.")
    }
)

/// Rows in the shape of OpenRouter's `GET /api/v1/videos/models` (checked
/// 2026-09-27): Veo's audio-priced SKUs, Kling's plain and with-audio pair, a
/// model with only ten-second clips, a token-priced one, a silent one, and an
/// editor with no clip lengths that the catalog leaves out.
private let videoDirectoryFixture = Data("""
{"data":[
  {"id":"google/veo-3.1-fast","name":"Google: Veo 3.1 Fast","created":1790000000,
   "supported_resolutions":["720p","1080p","4K"],"supported_aspect_ratios":["16:9","9:16"],
   "supported_durations":[4,6,8],"generate_audio":true,
   "pricing_skus":{"duration_seconds_with_audio":"0.12","duration_seconds_with_audio_4k":"0.30",
     "duration_seconds_without_audio":"0.10","duration_seconds_with_audio_720p":"0.10",
     "duration_seconds_without_audio_720p":"0.08"}},
  {"id":"google/veo-3.1-lite","name":"Google: Veo 3.1 Lite","created":1789000000,
   "supported_resolutions":["720p","1080p"],"supported_aspect_ratios":["16:9","9:16"],
   "supported_durations":[8,4,6],"generate_audio":true,
   "pricing_skus":{"duration_seconds_with_audio":"0.08","duration_seconds_without_audio":"0.05",
     "duration_seconds_with_audio_720p":"0.05","duration_seconds_without_audio_720p":"0.03"}},
  {"id":"kwaivgi/kling-v3.0-pro","name":"Kling: Video v3.0 Pro","created":1788000000,
   "supported_resolutions":["720p"],"supported_aspect_ratios":["16:9","9:16","1:1"],
   "supported_durations":[3,4,5,6,7,8,9,10],"generate_audio":true,
   "pricing_skus":{"duration_seconds":"0.112","duration_seconds_with_audio":"0.168",
     "text_to_video_duration_seconds_720p":"0.112"}},
  {"id":"kwaivgi/kling-video-o1","name":"Kling: Video O1","created":1787000000,
   "supported_resolutions":["720p"],"supported_aspect_ratios":["16:9"],
   "supported_durations":[5,10],"generate_audio":true,"pricing_skus":{"duration_seconds":"0.1120"}},
  {"id":"bytedance/seedance-2.0","name":"ByteDance: Seedance 2.0","created":1786000000,
   "supported_resolutions":["480p","720p","1080p"],"supported_durations":[4,8,12],"generate_audio":true,
   "pricing_skus":{"video_tokens":"0.000007"}},
  {"id":"minimax/hailuo-3-max","name":"MiniMax: H3 Max","created":1785000000,
   "supported_resolutions":["768p","480p"],"supported_durations":[5,8,10],"generate_audio":false,
   "pricing_skus":{"duration_seconds":"0.08","duration_seconds_480p":"0.05","duration_seconds_768p":"0.08"}},
  {"id":"black-forest-labs/flux-video-edit","name":"Black Forest Labs: FLUX Video Edit","created":1791000000,
   "supported_resolutions":null,"supported_durations":null,"generate_audio":false,
   "pricing_skus":{"cents_per_second_output":"3"}}
]}
""".utf8)

private func fixtureVideoModel(_ id: String) throws -> VideoGenerationModel {
    try #require(try VideoGenerationCatalog.models(fromDirectory: videoDirectoryFixture).first { $0.id == id })
}

@Suite("Video overview import")
struct VideoOverviewImportTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoOverviewImportTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A file name becomes the row's title")
    func titles() {
        #expect(VideoOverviewImporter.title(forFileNamed: "Unlocking_SLC25A34_Switch.mp4") == "Unlocking SLC25A34 Switch")
        #expect(VideoOverviewImporter.title(forFileNamed: "  Two   words.MOV") == "Two words")
        #expect(VideoOverviewImporter.title(forFileNamed: "___.mp4") == "Video overview")
    }

    @Test("MP4, M4V and MOV import; nothing else does")
    func extensions() {
        for name in ["a.mp4", "a.M4V", "a.mov"] {
            #expect(VideoOverviewImporter.canImport(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.pdf", "a.mp3", "a"] {
            #expect(!VideoOverviewImporter.canImport(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test("The id comes from the file's bytes, so the same file is the same video")
    func idFollowsBytes() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.mp4")
        let copy = directory.appendingPathComponent("renamed.mp4")
        let other = directory.appendingPathComponent("b.mp4")
        try Data("film".utf8).write(to: first)
        try Data("film".utf8).write(to: copy)
        try Data("another".utf8).write(to: other)
        let id = try VideoOverviewImporter.videoID(hashing: first)
        #expect(id.count == 32)
        #expect(id == (try VideoOverviewImporter.videoID(hashing: copy)))
        #expect(id != (try VideoOverviewImporter.videoID(hashing: other)))
        #expect(GeneratedExplainerVideo.videoID(from: GeneratedExplainerVideo.url(videoID: id)) == id)
    }

    @Test("A file that is not a video is refused and leaves nothing in the library")
    func refusesWhatItCannotPlay() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        let notVideo = directory.appendingPathComponent("notes.pdf")
        try Data("%PDF".utf8).write(to: notVideo)
        await #expect(throws: VideoOverviewImporter.Failure.notAVideo("notes.pdf")) {
            _ = try await VideoOverviewImporter.importFile(at: notVideo, contentRootPath: root.path)
        }
        let fake = directory.appendingPathComponent("fake.mp4")
        try Data("not a film".utf8).write(to: fake)
        await #expect(throws: VideoOverviewImporter.Failure.notAVideo("fake.mp4")) {
            _ = try await VideoOverviewImporter.importFile(at: fake, contentRootPath: root.path)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Videos").path)) ?? []
        #expect(leftovers.isEmpty)
    }
}

@Suite("Explainer Video")
struct ExplainerVideoTests {

    @Test("a video's URL grammar carries its id and nothing else")
    func urlGrammar() {
        let id = GeneratedExplainerVideo.newVideoID()
        let url = GeneratedExplainerVideo.url(videoID: id)
        #expect(url == "foreverlm://explainer-video/\(id)")
        #expect(GeneratedExplainerVideo.isVideoURL(url))
        #expect(GeneratedExplainerVideo.videoID(from: url) == id)
        #expect(GeneratedExplainerVideo.videoID(from: "foreverlm://explainer/abc") == nil)
        #expect(GeneratedExplainerVideo.videoID(from: "foreverlm://explainer-video/") == nil)
        #expect(GeneratedExplainerVideo.videoID(from: "foreverlm://explainer-video/a/b") == nil)
        #expect(!GeneratedExplainerVideo.isVideoURL("https://www.youtube.com/watch?v=abc"))
        // The spoken explainer's prefix is not this one, so the two never collide.
        #expect(!GeneratedExplainer.isExplainerURL(url))
        #expect(GeneratedExplainerVideo.sourceID(videoID: id) == SourceIdentity.stableID(for: url))
        #expect(GeneratedExplainerVideo.relativeVideoPath(videoID: id) == "Videos/\(id)/video.mp4")
        #expect(GeneratedExplainerVideo.relativePosterPath(videoID: id) == "Videos/\(id)/poster.jpg")
    }

    @Test("lengths are counts of eight-second scenes, and cost is scenes times the published rate")
    func lengthsAndCost() throws {
        #expect(ExplainerVideoLength.brief.sceneCount == 3)
        #expect(ExplainerVideoLength.standard.sceneCount == 5)
        #expect(ExplainerVideoLength.extended.sceneCount == 8)
        #expect(ExplainerVideoLength.standard.seconds == 40)
        #expect(ExplainerVideoLength.default == .standard)

        let fast = try fixtureVideoModel("google/veo-3.1-fast")
        #expect(GeneratedExplainerVideo.estimatedCostUSD(length: .standard, model: fast, resolution: .hd) == 4.0)
        #expect(abs((GeneratedExplainerVideo.estimatedCostUSD(length: .brief, model: fast, resolution: .fullHD) ?? 0) - 2.88) < 0.000_1)
        let lite = try fixtureVideoModel("google/veo-3.1-lite")
        #expect(abs((GeneratedExplainerVideo.estimatedCostUSD(length: .extended, model: lite, resolution: .hd) ?? 0) - 3.2) < 0.000_1)
        // 4K is never offered, so a stored 4K resolves to one the model films at.
        #expect(!fast.resolutions.contains { $0.isUltraHD })
        #expect(VideoGenerationCatalog.resolvedResolution("4k", for: fast) == .hd)
        #expect(VideoGenerationCatalog.costLabel(4) == "$4.00")
        #expect(VideoGenerationCatalog.rateLabel(0.1) == "$0.10")
        #expect(VideoGenerationCatalog.rateLabel(0.168) == "$0.168")
        #expect(VideoGenerationCatalog.rateLabel(0.0988) == "$0.0988")
    }

    @Test("OpenRouter's video directory becomes the catalog, with prices read from its SKUs")
    func videoDirectoryParses() throws {
        let models = try VideoGenerationCatalog.models(fromDirectory: videoDirectoryFixture)
        // The editor has no clip lengths, so it is not a filming model.
        #expect(!models.contains { $0.id == "black-forest-labs/flux-video-edit" })
        #expect(models.first?.id == "google/veo-3.1-fast")

        let kling = try fixtureVideoModel("kwaivgi/kling-v3.0-pro")
        #expect(kling.maker == "Kling")
        #expect(kling.name == "Video v3.0 Pro")
        #expect(kling.takesGenerateAudio)
        #expect(kling.resolutions == [.hd])
        // With sound, the with-audio rate wins over the plain text-to-video one.
        #expect(kling.usdPerSecond(at: .hd) == 0.168)
        #expect(abs((VideoGenerationCatalog.clipCostUSD(model: kling, resolution: .hd) ?? 0) - 1.344) < 0.000_1)

        // A model with no eight-second clip films ten, and is priced for ten.
        let o1 = try fixtureVideoModel("kwaivgi/kling-video-o1")
        #expect(o1.clipSeconds == 10)
        #expect(abs((VideoGenerationCatalog.clipCostUSD(model: o1, resolution: .hd) ?? 0) - 1.12) < 0.000_1)
        #expect(ExplainerVideoLength.standard.seconds(clipSeconds: o1.clipSeconds) == 50)

        // Priced by video tokens: no per-second figure is invented.
        let seedance = try fixtureVideoModel("bytedance/seedance-2.0")
        #expect(seedance.pricedByTokens)
        #expect(seedance.usdPerSecond(at: .hd) == nil)

        // A silent model is offered and says so; one without 720p films at
        // the resolution nearest it.
        let h3 = try fixtureVideoModel("minimax/hailuo-3-max")
        #expect(h3.makesSound == false)
        #expect(!h3.takesGenerateAudio)
        #expect(VideoGenerationCatalog.resolvedResolution("720p", for: h3).rawValue == "768p")
        #expect(h3.usdPerSecond(at: VideoGenerationCatalog.Resolution(rawValue: "480p")!) == 0.05)
    }

    @Test("A stored video choice resolves against the directory, and the old Veo ids keep their model")
    func videoChoiceResolves() throws {
        let models = try VideoGenerationCatalog.models(fromDirectory: videoDirectoryFixture)
        #expect(VideoGenerationCatalog.canonicalID("veo-3.1-fast-generate-preview") == "google/veo-3.1-fast")
        #expect(VideoGenerationCatalog.resolvedModel(id: "veo-3.1-lite-generate-preview", in: models).id == "google/veo-3.1-lite")
        #expect(VideoGenerationCatalog.resolvedModel(id: "veo-2", in: models).id == VideoGenerationCatalog.defaultModelID)
        let pending = VideoGenerationCatalog.resolvedModel(id: nil, in: [])
        #expect(pending.id == VideoGenerationCatalog.defaultModelID)
        #expect(!pending.isResolved)

        // The request carries only what the model lists.
        let kling = try fixtureVideoModel("kwaivgi/kling-v3.0-pro")
        let body = ManagedVideoGeneration.requestBody(prompt: "a cell", model: kling, resolution: .hd, durationSeconds: kling.clipSeconds)
        #expect(body["model"] as? String == "kwaivgi/kling-v3.0-pro")
        #expect(body["duration"] as? Int == 8)
        #expect(body["aspect_ratio"] as? String == "16:9")
        #expect(body["resolution"] as? String == "720p")
        #expect(body["generate_audio"] as? Bool == true)
        let silent = ManagedVideoGeneration.requestBody(prompt: "a cell", model: try fixtureVideoModel("minimax/hailuo-3-max"), resolution: .hd, durationSeconds: 8)
        #expect(silent["generate_audio"] == nil)
        #expect(silent["aspect_ratio"] == nil)
    }

    @Test("a storyboard decodes from the writer's JSON, trims to the asked length, and prompts one scene at a time")
    func storyboardShape() throws {
        let json = """
        {"title":"Proton Pumps","style":"Flat paper cut-outs.","scenes":[
          {"narration":"One.","visual":"A cell."},{"narration":"Two.","visual":"A membrane."},
          {"narration":"Three.","visual":"A gradient."},{"narration":"Four.","visual":"A turbine."}]}
        """
        let storyboard: ExplainerVideoStoryboard = try MemoryReviewPlanning.decodeJSON(json)
        #expect(storyboard.isUsable)
        #expect(storyboard.scenes.count == 4)
        #expect(storyboard.limited(to: .brief).scenes.count == 3)
        #expect(storyboard.limited(to: .standard).scenes.count == 4)
        #expect(storyboard.script == "One.\n\nTwo.\n\nThree.\n\nFour.")

        let opening = storyboard.clipPrompt(sceneIndex: 0)
        #expect(opening.contains("opening shot"))
        #expect(opening.contains("Style: Flat paper cut-outs."))
        #expect(opening.contains("Narrator (voice-over): \"One.\""))
        #expect(opening.contains("No on-screen text"))
        #expect(storyboard.clipPrompt(sceneIndex: 3).contains("closing shot"))
        #expect(storyboard.clipPrompt(sceneIndex: 1).contains("Shot 2 of 4"))

        let empty = ExplainerVideoStoryboard(title: "", style: "x", scenes: [])
        #expect(!empty.isUsable)
        let blank = ExplainerVideoStoryboard(title: "T", style: "x", scenes: [ExplainerVideoScene(narration: " ", visual: "v")])
        #expect(!blank.isUsable)
    }

    @Test("the writer's turn names the concept, the scene count and the source text, or says there is none")
    func writerTurn() {
        let grounded = GeneratedExplainerVideo.storyboardUserMessage(
            concept: "why ATP synthase spins",
            length: .brief,
            sourceTitle: "A paper",
            sourceText: "The rotor turns.",
            truncated: true
        )
        #expect(grounded.contains("Concept to explain: why ATP synthase spins"))
        #expect(grounded.contains("exactly 3"))
        #expect(grounded.contains("Source: A paper"))
        #expect(grounded.contains("the end is missing"))
        #expect(grounded.hasSuffix("The rotor turns."))
        let free = GeneratedExplainerVideo.storyboardUserMessage(concept: "entropy", length: .standard, sourceTitle: nil, sourceText: nil, truncated: false)
        #expect(free.contains("There is no source text"))
    }

    @Test("a notebook's video overview grounds the storyboard on its papers and articles together, each under its title and an equal share, and leaves out what is not a paper or an article")
    func pipelineGroundsOnSeveralSources() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [String] = []
        for (index, name) in ["First Article", "Second Article"].enumerated() {
            var article = StudioArticle(url: "https://example.org/a\(index)", title: name, sourceType: .article, discoveryOrigin: .manual)
            article.content = String(repeating: "Word\(index) ", count: 20_000)
            article.wordCount = 20_000
            article.state = .ready
            try await storage.saveSource(article)
            ids.append(article.id)
        }
        var talk = StudioArticle(url: "https://example.org/talk", title: "A Talk", sourceType: .video, discoveryOrigin: .manual)
        talk.content = "A talk about something else."
        talk.state = .ready
        try await storage.saveSource(talk)
        ids.append(talk.id)

        let recorder = StoryboardCallRecorder()
        let service = ExplainerVideoGeneratorService(
            storage: storage,
            storyboardBackend: CannedStoryboardBackend(storyboard: fiveScenes, recorder: recorder),
            clipBackend: CannedClipBackend(),
            assembler: CountingAssembler(),
            model: try fixtureVideoModel(VideoGenerationCatalog.defaultModelID),
            resolution: .hd,
            contentRootPath: root.appendingPathComponent("Content", isDirectory: true).path
        )
        _ = try await service.run(request: ExplainerVideoRequest(concept: "My Notebook", groundingSourceIDs: ids, length: .standard))

        let call = try #require(recorder.calls.first)
        let text = try #require(call.sourceText)
        #expect(text.contains("## First Article\n"))
        #expect(text.contains("## Second Article\n"))
        #expect(!text.contains("A Talk"))
        #expect(call.truncated == true)
        #expect(call.sourceTitle == "2 sources: My Notebook")
        #expect(text.count <= GeneratedExplainerVideo.sourceCharacterBudget + 200)
    }

    @Test("the pipeline films every scene, joins them, and saves a video source under Videos with the script as its text")
    func pipelineSavesVideoSource() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        // An article rather than a paper: a ready paper needs the metadata
        // attestation its ingestion makes, which is not what this test is about.
        var paper = StudioArticle(url: "https://example.org/paper", title: "The Paper", sourceType: .article, discoveryOrigin: .manual)
        paper.author = "A. Author"
        paper.content = String(repeating: "Protons cross the membrane. ", count: 3_000)
        paper.wordCount = 12_000
        paper.state = .ready
        try await storage.saveSource(paper)

        let recorder = StoryboardCallRecorder()
        let clips = CannedClipBackend()
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        var stages: [ExplainerVideoStage] = []
        let stageLock = NSLock()
        let service = ExplainerVideoGeneratorService(
            storage: storage,
            storyboardBackend: CannedStoryboardBackend(storyboard: fiveScenes, recorder: recorder),
            clipBackend: clips,
            assembler: CountingAssembler(),
            model: try fixtureVideoModel(VideoGenerationCatalog.defaultModelID),
            resolution: .hd,
            contentRootPath: contentRoot.path,
            clipConcurrency: 2,
            progress: { stage in
                stageLock.lock(); stages.append(stage); stageLock.unlock()
            }
        )
        let result = try await service.run(request: ExplainerVideoRequest(concept: "why mitochondria pump protons", sourceID: paper.id, length: .standard))

        // The writer saw the paper's text, cut to the budget and flagged.
        let call = try #require(recorder.calls.first)
        #expect(call.sourceTitle == "The Paper")
        #expect(call.truncated == true)
        #expect(call.sourceText?.count == GeneratedExplainerVideo.sourceCharacterBudget)

        // Five clips, in scene order, each from its own prompt.
        #expect(clips.prompts.count == 5)
        #expect(Set(clips.prompts).count == 5)

        // The film, the poster and the manifest are in the video's directory;
        // the clips are not kept.
        let videoID = try #require(GeneratedExplainerVideo.videoID(from: result.video.url))
        let directory = contentRoot.appendingPathComponent("Videos/\(videoID)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("video.mp4").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.jpg").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Clips").path))
        #expect(try String(contentsOf: directory.appendingPathComponent("video.mp4"), encoding: .utf8) == "film of 5")

        // The row: a ready video source, filed under ForeverLM, pointing at the
        // file by a root-relative path, carrying the narration as its text.
        let saved = try #require(try await storage.loadSourceWithoutContent(result.video.id))
        #expect(saved.sourceType == .video)
        #expect(saved.title == "Why Mitochondria Pump Protons")
        #expect(saved.domain == "ForeverLM")
        // The store hands a local path back resolved against the content root.
        #expect(saved.localFilePath?.hasSuffix("/Videos/\(videoID)/video.mp4") == true)
        #expect(saved.artworkURL == "Videos/\(videoID)/poster.jpg")
        #expect(saved.state == .ready)
        let text = await storage.loadSourceContent(result.video.id)
        #expect(text == fiveScenes.script)
        #expect(saved.wordCount == ExplainerScript.wordCount(of: fiveScenes.script))

        // The manifest remembers how the film was made.
        #expect(result.manifest.sourceID == paper.id)
        #expect(result.manifest.durationSeconds == 40)
        #expect(result.manifest.model == VideoGenerationCatalog.defaultModelID)
        #expect(abs((result.manifest.costUSD ?? 0) - 4.0) < 0.000_1)
        #expect(result.manifest.storyboard == fiveScenes)

        // Progress ran from the storyboard through every scene to saving.
        stageLock.lock(); let seen = stages; stageLock.unlock()
        #expect(seen.first == .writingStoryboard)
        #expect(seen.contains(.drawingScenes(done: 5, total: 5)))
        #expect(seen.contains(.stitching))
        #expect(seen.last == .saving)
    }

    @Test("a concept with no source is filmed from what is well established")
    func pipelineWithoutSource() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = StoryboardCallRecorder()
        let service = ExplainerVideoGeneratorService(
            storage: storage,
            storyboardBackend: CannedStoryboardBackend(storyboard: fiveScenes.limited(to: .brief), recorder: recorder),
            clipBackend: CannedClipBackend(),
            assembler: CountingAssembler(),
            model: try fixtureVideoModel(VideoGenerationCatalog.defaultModelID),
            resolution: .hd,
            contentRootPath: root.appendingPathComponent("Content").path
        )
        let result = try await service.run(request: ExplainerVideoRequest(concept: "entropy", length: .brief))
        #expect(recorder.calls.first?.sourceText == nil)
        #expect(result.manifest.sourceID == nil)
        #expect(result.manifest.durationSeconds == 24)
        #expect(abs((result.manifest.costUSD ?? 0) - 2.4) < 0.000_1)
    }

    @Test("a failed scene stops the film, discards its directory and saves no row")
    func failedSceneLeavesNothing() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let clips = CannedClipBackend()
        clips.failAtCall = 2
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let service = ExplainerVideoGeneratorService(
            storage: storage,
            storyboardBackend: CannedStoryboardBackend(storyboard: fiveScenes),
            clipBackend: clips,
            assembler: CountingAssembler(),
            model: try fixtureVideoModel(VideoGenerationCatalog.defaultModelID),
            resolution: .hd,
            contentRootPath: contentRoot.path,
            clipConcurrency: 1
        )
        await #expect(throws: ExplainerVideoGenerationError.self) {
            try await service.run(request: ExplainerVideoRequest(concept: "entropy", length: .standard))
        }
        let videosDirectory = contentRoot.appendingPathComponent("Videos", isDirectory: true)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: videosDirectory.path)) ?? []
        #expect(remaining.isEmpty)
        let sources = try await storage.loadSources()
        #expect(sources.isEmpty)
    }

    @Test("an empty concept, a missing source and a source of the wrong kind are refused before anything is spent")
    func refusals() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        // Episodes ground explainers now; a book still does not.
        var book = StudioArticle(url: "file:///book.pdf", title: "A Book", sourceType: .book, discoveryOrigin: .manual)
        book.content = "Words."
        book.wordCount = 1
        book.state = .ready
        try await storage.saveSource(book)
        let clips = CannedClipBackend()
        let service = ExplainerVideoGeneratorService(
            storage: storage,
            storyboardBackend: CannedStoryboardBackend(storyboard: fiveScenes),
            clipBackend: clips,
            assembler: CountingAssembler(),
            model: try fixtureVideoModel(VideoGenerationCatalog.defaultModelID),
            resolution: .hd,
            contentRootPath: root.appendingPathComponent("Content").path
        )
        await #expect(throws: ExplainerVideoGenerationError.emptyConcept) {
            try await service.run(request: ExplainerVideoRequest(concept: "  "))
        }
        await #expect(throws: ExplainerVideoGenerationError.sourceNotFound("missing")) {
            try await service.run(request: ExplainerVideoRequest(concept: "x", sourceID: "missing"))
        }
        await #expect(throws: ExplainerVideoGenerationError.unsupportedSource("A Book")) {
            try await service.run(request: ExplainerVideoRequest(concept: "x", sourceID: book.id))
        }
        #expect(clips.prompts.isEmpty)
    }

    @Test("the Videos tab is a permanent center destination with its own glyph and title")
    func centerTab() {
        #expect(StudioCenterTab.permanentTabs.contains(.videos))
        #expect(StudioCenterTab.videos.title == "Videos")
        #expect(StudioCenterTab(rawValue: "videos") == .videos)
    }
}
