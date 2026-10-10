import Foundation

// MARK: - Explainer videos

/// How long a video explainer runs, as a count of eight-second scenes. The
/// storyboard is asked for exactly this many scenes, and the cost the learner
/// confirms is this many clips.
enum ExplainerVideoLength: String, CaseIterable, Codable, Identifiable, Sendable {
    case brief
    case standard
    case extended

    static let `default`: ExplainerVideoLength = .standard

    var id: String { rawValue }

    var sceneCount: Int {
        switch self {
        case .brief: return 3
        case .standard: return 5
        case .extended: return 8
        }
    }

    var seconds: Int { seconds(clipSeconds: VideoGenerationCatalog.clipSeconds) }

    /// The film's length on a model whose clips run `clipSeconds`: a scene is
    /// one clip, and a few models make ten-second clips rather than eight.
    func seconds(clipSeconds: Int) -> Int { sceneCount * clipSeconds }

    var displayName: String {
        switch self {
        case .brief: return "Brief"
        case .standard: return "Standard"
        case .extended: return "Extended"
        }
    }

    /// "3 scenes · 24 s".
    var detail: String { detail(clipSeconds: VideoGenerationCatalog.clipSeconds) }

    func detail(clipSeconds: Int) -> String {
        "\(sceneCount) scenes · \(seconds(clipSeconds: clipSeconds)) s"
    }
}

/// One eight-second scene: what the narrator says over it and what is shown.
struct ExplainerVideoScene: Codable, Equatable, Sendable {
    /// One or two spoken sentences, at most about twenty words: what fits in
    /// eight seconds of speech.
    var narration: String
    /// What the camera sees, written for the video model: subject, motion,
    /// setting, light. No text on screen — a video model misspells it.
    var visual: String
}

/// What the writer returns: a title, a look every scene shares, and the scenes.
struct ExplainerVideoStoryboard: Codable, Equatable, Sendable {
    var title: String
    /// The visual style carried into every clip's prompt, so eight clips drawn
    /// separately read as one film: palette, medium, camera, mood.
    var style: String
    var scenes: [ExplainerVideoScene]

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scenes.isEmpty
            && scenes.allSatisfy {
                !$0.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.visual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// The narration alone, one paragraph a scene: the video's transcript,
    /// which is what its source row carries as text so it can be searched,
    /// read and quoted like any other source.
    var script: String {
        scenes.map { $0.narration.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n")
    }

    /// The prompt one scene is drawn from. A video model that makes sound
    /// (Veo, Kling, Wan…) speaks quoted dialogue in the prompt, so the
    /// narration rides inside it as a voice-over line; the style keeps the
    /// clips of one film alike.
    func clipPrompt(sceneIndex: Int) -> String {
        let scene = scenes[sceneIndex]
        let position: String
        switch (sceneIndex, scenes.count) {
        case (0, 1): position = "The whole film in one shot."
        case (0, _): position = "The opening shot of a short explainer film."
        case (let index, let count) where index == count - 1: position = "The closing shot of a short explainer film."
        default: position = "Shot \(sceneIndex + 1) of \(scenes.count) in a short explainer film."
        }
        let narration = scene.narration.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(position)
        Style: \(style.trimmingCharacters(in: .whitespacesAndNewlines))
        Visual: \(scene.visual.trimmingCharacters(in: .whitespacesAndNewlines))
        A calm, clear narrator speaks over the picture, unhurried, in a warm voice. Narrator (voice-over): "\(narration)"
        No on-screen text, captions, subtitles, titles, logos or watermarks. No people speaking to camera.
        """
    }

    /// The scenes cut to the count the learner chose: a writer that returns
    /// more is trimmed, one that returns fewer is used as it stands.
    func limited(to length: ExplainerVideoLength) -> ExplainerVideoStoryboard {
        var copy = self
        if copy.scenes.count > length.sceneCount {
            copy.scenes = Array(copy.scenes.prefix(length.sceneCount))
        }
        return copy
    }
}

/// What the learner asked for: the concept, the source it should lean on if
/// any, and how long the film runs.
struct ExplainerVideoRequest: Equatable, Sendable {
    /// The idea to explain, in the learner's words — "why the electron
    /// transport chain pumps protons", or a paper's title when it came from a
    /// source's menu.
    var concept: String
    /// A paper or article whose text grounds the storyboard, when there is one.
    var sourceID: String?
    var length: ExplainerVideoLength = .default
}

/// The record kept beside a finished video: what it is, how it was made and
/// what it cost, in `Videos/<id>/manifest.json`. The source row carries the
/// title and the script; everything the row cannot hold is here.
struct ExplainerVideoManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var videoID: String
    var concept: String
    var sourceID: String?
    var length: ExplainerVideoLength
    var storyboard: ExplainerVideoStoryboard
    var model: String
    var resolution: String
    var durationSeconds: Double
    var costUSD: Double?
    var createdAt: Date
}

/// The URL grammar, titles and file layout of the source a video explainer is
/// saved as.
///
/// A video explainer is an ordinary source: a `video`-typed row with a
/// `foreverlm://explainer-video/<id>` URL and its file at a relative path under
/// the synced content root, so search, review, scheduling, sync, the Reader's
/// dispatch and deletion all work on it with no second code path — the same
/// choice `GeneratedExplainer` made for spoken explainers. Unlike a spoken
/// explainer, a source may have any number of videos (one per concept), so the
/// id is minted, not derived from the source.
enum GeneratedExplainerVideo {
    static let scheme = "foreverlm"
    static let host = "explainer-video"
    static let urlPrefix = "\(scheme)://\(host)/"
    /// Shown where a web source would show its host; the same word spoken
    /// explainers and course lessons use.
    static let domain = ExplainerScript.domain
    /// The ledger task every clip of a video explainer is billed under.
    static let usageTask = "explainer_video"
    /// Characters of source text the storyboard writer sees — the same budget
    /// the spoken explainer cuts at.
    static let sourceCharacterBudget = ExplainerScript.sourceCharacterBudget
    /// The directory under the synced content root every video lives in.
    static let directoryName = "Videos"

    static func newVideoID() -> String {
        UUID().uuidString.lowercased()
    }

    static func url(videoID: String) -> String {
        urlPrefix + videoID
    }

    static func isVideoURL(_ urlString: String) -> Bool {
        videoID(from: urlString) != nil
    }

    /// The video's id, or nil for any other URL.
    static func videoID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(urlPrefix) else { return nil }
        let id = String(trimmed.dropFirst(urlPrefix.count))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    /// The source row's id: derived from the URL by the same normalizer and
    /// hash every source uses, so two Macs agree on it.
    static func sourceID(videoID: String) -> String {
        SourceIdentity.stableID(for: url(videoID: videoID))
    }

    /// Paths relative to the content root, the form `local_file_path` stores
    /// so a library survives moving between roots.
    static func relativeDirectory(videoID: String) -> String {
        "\(directoryName)/\(videoID)"
    }

    static func relativeVideoPath(videoID: String) -> String {
        "\(relativeDirectory(videoID: videoID))/video.mp4"
    }

    static func relativePosterPath(videoID: String) -> String {
        "\(relativeDirectory(videoID: videoID))/poster.jpg"
    }

    static func relativeManifestPath(videoID: String) -> String {
        "\(relativeDirectory(videoID: videoID))/manifest.json"
    }

    /// What a paper's menu asks for when the learner has not typed a concept:
    /// the paper itself, explained.
    static func concept(forSourceTitled title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this paper" : trimmed
    }

    /// The whole film's charge from the published rate: scenes × the model's
    /// clip length × its per-second price. Nil when the model has no
    /// per-second price at the resolution.
    static func estimatedCostUSD(
        length: ExplainerVideoLength,
        model: VideoGenerationModel,
        resolution: VideoGenerationCatalog.Resolution
    ) -> Double? {
        guard let clip = VideoGenerationCatalog.clipCostUSD(model: model, resolution: resolution) else { return nil }
        return clip * Double(length.sceneCount)
    }

    /// "40 s · 5 scenes", for lists and the masthead.
    static func lengthLabel(durationSeconds: Double, sceneCount: Int) -> String {
        let seconds = Int(durationSeconds.rounded())
        let time = seconds >= 60
            ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : "\(seconds) s"
        return "\(time) · \(sceneCount) scene\(sceneCount == 1 ? "" : "s")"
    }

    // MARK: The writer's turn

    /// The storyboard writer's user message: the concept, the film's shape,
    /// and the source's text when there is one.
    static func storyboardUserMessage(
        concept: String,
        length: ExplainerVideoLength,
        sourceTitle: String?,
        sourceText: String?,
        truncated: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("Concept to explain: \(concept.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("Scenes: exactly \(length.sceneCount), each \(VideoGenerationCatalog.clipSeconds) seconds — about \(length.seconds) seconds in all.")
        if let sourceTitle, !sourceTitle.isEmpty {
            lines.append("Source: \(sourceTitle)")
        }
        if let sourceText, !sourceText.isEmpty {
            lines.append("")
            lines.append(truncated
                ? "Source text (the opening only — the end is missing, so say nothing about what may follow):"
                : "Source text:")
            lines.append(sourceText)
        } else {
            lines.append("")
            lines.append("There is no source text; explain the concept from what is well established, and say nothing you are not sure of.")
        }
        return lines.joined(separator: "\n")
    }

    /// The text the writer sees: whole when it fits, else the opening budget.
    static func budgeted(_ text: String) -> (text: String, truncated: Bool) {
        ExplainerScript.budgeted(text)
    }
}
