import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum YouTubeURLMetadata {
    static func isYouTubeURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("youtube.com/watch") || lower.contains("youtu.be/")
            || lower.contains("youtube.com/v/") || lower.contains("youtube.com/embed/")
            || lower.contains("youtube.com/shorts/")
    }

    /// The watch address of the YouTube video an address names — a watch link,
    /// youtu.be, Shorts, a livestream, an embed (youtube-nocookie.com's too) —
    /// or nil when it names none. ForeverLM shows YouTube one video at a time,
    /// in the Reader's player, and this is the address it plays it at
    /// (`YouTubeContainment`): the video and the moment a link pointed to, and
    /// no playlist or Mix for YouTube to carry on through.
    static func watchURL(for urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased() else { return nil }
        // The privacy-enhanced embed is YouTube's player under another name.
        if host == "youtube-nocookie.com" || host == "www.youtube-nocookie.com" {
            components.host = "www.youtube.com"
        }
        guard let address = components.string,
              let videoID = ForeverLMCore.youtubeVideoID(from: address) else { return nil }
        var watch = URLComponents()
        watch.scheme = "https"
        watch.host = "www.youtube.com"
        watch.path = "/watch"
        watch.queryItems = [URLQueryItem(name: "v", value: videoID)]
        if let moment = components.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value,
           !moment.isEmpty {
            watch.queryItems?.append(URLQueryItem(name: "t", value: moment))
        }
        return watch.url
    }

    static func sanitizedVideoTitle(_ title: String) -> String? {
        let cleaned = decodeHTMLEntities(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "..."), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let nsResult = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                if let numRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[numRange]),
                   let scalar = Unicode.Scalar(codePoint),
                   let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }

        return result
    }
}

/// Represents a file uploaded to Anthropic's Files API.
struct AnthropicFile: Identifiable, Codable {
    let id: String
    let filename: String
    let sizeBytes: Int
    let createdAt: String
    
    var sizeDescription: String {
        let mb = Double(sizeBytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

enum AIProvider: String, CaseIterable, Codable {
    case anthropic = "Anthropic (Claude)"
    case openai = "OpenAI (GPT)"
    case groq = "Groq (GPT OSS 120B)"
    case cerebras = "Cerebras (GPT OSS 120B)"
    case xai = "xAI (Grok)"
    case gemini = "Google (Gemini)"
    case meta = "Meta (Muse Spark)"
    case together = "Together AI (Inkling)"
    case fireworks = "Fireworks (Inkling)"
    case nvidia = "NVIDIA (Nemotron)"
    case openRouter = "OpenRouter"

    /// The model families the chat surface offers. Every one reaches the model
    /// through OpenRouter; the labs are catalog identities, not transports.
    static let activeChatProviders: [AIProvider] = [
        .anthropic, .openai, .gemini, .xai, .meta, .openRouter,
    ]

    /// A host that no longer appears in the chat surface (its models moved to
    /// OpenRouter). Existing keys and usage history remain readable.
    var isRetiredChatHost: Bool {
        !Self.activeChatProviders.contains(self)
    }

    /// Whether a selection already stored on this device naming this provider
    /// can still be carried out. A retired host — Groq, Cerebras, Together,
    /// Fireworks, NVIDIA — has no transport, and a selection naming one stays
    /// invalid. A stored selection naming a provider this build does not know
    /// does not decode at all, so it reads as invalid the same way.
    var canServeStoredSelection: Bool {
        Self.activeChatProviders.contains(self)
    }

    /// Asset catalog image name for this provider's logo.
    var iconName: String {
        switch self {
        case .anthropic: return "ClaudeIcon"
        case .openai: return "OpenAIIcon"
        case .groq: return "GroqIcon"
        case .cerebras: return "CerebrasIcon"
        case .xai: return "XAIIcon"
        case .gemini: return "GeminiIcon"
        case .meta: return "MetaIcon"
        case .together: return "TogetherAIIcon"
        case .fireworks: return "FireworksIcon"
        case .nvidia: return "NVIDIAIcon"
        case .openRouter: return "OpenRouterIcon"
        }
    }

    /// SF Symbol fallback when no asset-catalog logo is bundled.
    var systemImageFallback: String {
        switch self {
        case .fireworks: return "flame"
        case .nvidia: return "cpu"
        case .openRouter: return "arrow.triangle.branch"
        default: return "sparkles"
        }
    }

    /// Short display name without parenthetical.
    var shortName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .cerebras: return "Cerebras"
        case .xai: return "xAI"
        case .gemini: return "Gemini"
        case .meta: return "Meta"
        case .together: return "Together AI"
        case .fireworks: return "Fireworks"
        case .nvidia: return "NVIDIA"
        case .openRouter: return "OpenRouter"
        }
    }

    /// Lowercase token used by chat slash commands, e.g. `/provider openai`.
    var slashToken: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .groq: return "groq"
        case .cerebras: return "cerebras"
        case .xai: return "xai"
        case .gemini: return "gemini"
        case .meta: return "meta"
        case .together: return "together"
        case .fireworks: return "fireworks"
        case .nvidia: return "nvidia"
        case .openRouter: return "openrouter"
        }
    }

    /// The provider a usage-ledger row names: the short name the recorder
    /// stamps ("OpenRouter"), the slash token the managed proxy's rows carry
    /// ("openrouter") or a stored raw value. Nil for a host the app no longer
    /// knows.
    init?(ledgerName: String) {
        let needle = ledgerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let provider = Self.allCases.first(where: {
            $0.shortName.lowercased() == needle || $0.slashToken == needle || $0.rawValue.lowercased() == needle
        }) else { return nil }
        self = provider
    }
}

/// The lab that trained a model, independent of which API host serves it.
/// The chat catalog and pickers group models by maker — "DeepSeek V4 Flash is
/// a DeepSeek model" — while the entry's `provider` stays the API host that
/// actually serves the request. Open-weight models are served by OpenRouter
/// (never by the Chinese labs' own APIs), Claude by Anthropic's own API.
enum AIModelMaker: String, CaseIterable {
    case anthropic
    case openai
    case google
    case xai
    case deepseek
    case moonshot
    case qwen
    case zai
    case mistral
    case thinkingMachines
    case meta
    case nvidia
    /// Catch-all for user-added OpenRouter models whose author isn't one of
    /// the named labs above (Mistral, Cohere, …). Shows the OpenRouter mark.
    case other

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .xai: return "xAI"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Moonshot AI"
        case .qwen: return "Qwen"
        case .zai: return "Z.ai"
        case .mistral: return "Mistral AI"
        case .thinkingMachines: return "Thinking Machines"
        case .meta: return "Meta"
        case .nvidia: return "NVIDIA"
        case .other: return "Other Models"
        }
    }

    /// Asset catalog image name for this maker's logo.
    var iconName: String {
        switch self {
        case .anthropic: return "ClaudeIcon"
        case .openai: return "OpenAIIcon"
        case .google: return "GeminiIcon"
        case .xai: return "XAIIcon"
        case .deepseek: return "DeepSeekIcon"
        case .moonshot: return "MoonshotIcon"
        case .qwen: return "QwenIcon"
        case .zai: return "ZAIIcon"
        case .mistral: return "MistralIcon"
        case .thinkingMachines: return "ThinkingMachinesIcon"
        case .meta: return "MetaIcon"
        case .nvidia: return "NVIDIAIcon"
        case .other: return "OpenRouterIcon"
        }
    }

    /// SF Symbol fallback when no asset-catalog logo is bundled.
    var systemImageFallback: String {
        switch self {
        case .deepseek: return "fish"
        case .moonshot: return "moon.stars"
        case .qwen: return "q.square"
        case .zai: return "z.square"
        case .mistral: return "wind"
        case .thinkingMachines: return "brain"
        case .nvidia: return "cpu"
        case .other: return "arrow.triangle.branch"
        default: return "sparkles"
        }
    }
}

enum AIModelDisplayName {
    static func textModelName(
        _ modelID: String,
        provider: AIProvider,
        includeProvider: Bool = false,
        compact: Bool = false
    ) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let canonical = strippedDateSuffix(from: trimmed)
        if let known = knownTextModelNames[canonical] ?? knownTextModelNames[trimmed] {
            return adjustedProviderPrefix(known, provider: provider, compact: compact)
        }

        // OpenRouter serves a variant of one model under a ":tag" suffix
        // ("nvidia/nemotron-3-ultra-550b-a55b:free"), and its directory names
        // it "<model> (free)". Name the base model and append the tag the same
        // way; left to the generic path the tag glues onto the last slug
        // token and the model reads "Nemotron 3 Ultra 550B A55b:free".
        if let colon = trimmed.lastIndex(of: ":") {
            let tag = String(trimmed[trimmed.index(after: colon)...])
            if tag.range(of: "^[a-z]+$", options: .regularExpression) != nil {
                let base = textModelName(
                    String(trimmed[..<colon]),
                    provider: provider,
                    includeProvider: includeProvider,
                    compact: compact
                )
                if !base.isEmpty { return "\(base) (\(tag))" }
            }
        }

        // The same model reaches us both bare ("gpt-5.6-luna") and as an
        // OpenRouter slug ("openai/gpt-5.6-luna"); one table entry covers both.
        let bare = withoutMakerPrefix(canonical)
        if bare != canonical, let known = knownTextModelNames[bare] {
            return adjustedProviderPrefix(known, provider: provider, compact: compact)
        }

        if let claudeName = claudeName(from: bare) {
            return adjustedProviderPrefix(claudeName, provider: provider, compact: compact)
        }

        return genericName(from: bare, provider: provider, includeProvider: includeProvider)
    }

    private static let knownTextModelNames: [String: String] = [
        "typesafe/jev-1.13": "TypeSafe Jev 1.13",
        "claude-fable-5": "Fable 5",
        "claude-sonnet-5": "Sonnet 5",
        "claude-haiku-4-5": "Haiku 4.5",
        "claude-sonnet-4": "Sonnet 4.6",
        "claude-sonnet-4-5": "Sonnet 4.5",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-opus-4": "Opus 4.8",
        "claude-opus-5": "Opus 5",
        "claude-opus-4-1": "Opus 4.1",
        "claude-opus-4-5": "Opus 4.5",
        "claude-opus-4-6": "Opus 4.6",
        "claude-opus-4-7": "Opus 4.7",
        "claude-opus-4-8": "Opus 4.8",
        "claude-3-5-haiku": "3.5 Haiku",
        "claude-3-5-sonnet": "3.5 Sonnet",
        "claude-3-7-sonnet": "3.7 Sonnet",
        "gpt-6-astra": "GPT-6 Astra",
        "gpt-5.6": "GPT-5.6 Sol",
        "gpt-5.6-sol": "GPT-5.6 Sol",
        "gpt-5.6-terra": "GPT-5.6 Terra",
        "gpt-5.6-luna": "GPT-5.6 Luna",
        "gpt-5.5": "GPT-5.5",
        "openai/gpt-oss-120b": "GPT OSS 120B",
        "openai/gpt-oss-20b": "GPT OSS 20B",
        "gpt-oss-120b": "GPT OSS 120B",
        "llama3.1-8b": "Llama 3.1 8B",
        "muse-spark-1.2": "Muse Spark 1.2",
        "muse-spark-1.2-contributor": "Muse Spark 1.2 Contributor",
        "muse-spark-1.1": "Muse Spark 1.1",
        "thinkingmachines/Inkling": "Inkling",
        "thinkingmachines/Inkling-NVFP4": "Inkling (NVFP4)",
        "accounts/fireworks/models/inkling": "Inkling",
        "nvidia/nemotron-3-ultra-550b-a55b": "Nemotron 3 Ultra",
        "nvidia/nemotron-3-super-120b-a12b": "Nemotron 3 Super",
        "nvidia/nemotron-3-nano-30b-a3b": "Nemotron 3 Nano",
        "moonshotai/kimi-k3": "Kimi K3",
        "moonshotai/kimi-k2.6": "Kimi K2.6",
        "deepseek/deepseek-v4-flash": "DeepSeek V4 Flash",
        "deepseek/deepseek-v4-pro": "DeepSeek V4 Pro",
        "qwen/qwen3-32b": "Qwen3 32B",
        "qwen-3-235b-a22b-instruct-2507": "Qwen 3 235B Instruct",
        "qwen/qwen3-235b-a22b-2507": "Qwen3 235B",
        "zai-glm-4.7": "Z.ai GLM 4.7",
        "z-ai/glm-5.2": "GLM 5.2",
        "z-ai/glm-5.1": "GLM 5.1",
        "z-ai/glm-4.7": "GLM 4.7",
        "mistralai/mistral-large-2512": "Mistral Large 3",
        "mistralai/mistral-small-2603": "Mistral Small 4",
        "meta/muse-spark-1.2": "Muse Spark 1.2",
        "meta/muse-spark-1.1": "Muse Spark 1.1",
        "meta-llama/llama-4-maverick": "Llama 4 Maverick",
        "grok-4.7": "Grok 4.7",
        "grok-4.6": "Grok 4.6",
        "grok-4.5": "Grok 4.5",
        "grok-4.3": "Grok 4.3",
        "grok-3-mini-fast": "Grok 3 Mini Fast",
        "grok-3-mini": "Grok 3 Mini",
        "grok-3": "Grok 3",
        "gemini-3.5-flash": "Gemini 3.5 Flash",
        "gemini-3-pro-preview": "Gemini 3 Pro Preview",
        "gemini-3-flash-preview": "Gemini 3 Flash Preview",
        "gemini-2.5-flash-lite": "Gemini 2.5 Flash-Lite",
        "gemini-2.5-flash": "Gemini 2.5 Flash",
        // OpenRouter-hosted slug: the default slide reader when Background
        // uses OpenRouter's text-only general default.
        "google/gemini-2.5-flash": "Gemini 2.5 Flash",
        "gemini-2.5-pro": "Gemini 2.5 Pro",
        "gemini-2.0-flash": "Gemini 2.0 Flash",
    ]

    private static func strippedDateSuffix(from modelID: String) -> String {
        var result = modelID
        for pattern in ["-\\d{4}-\\d{2}-\\d{2}$", "-\\d{8}$"] {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result.removeSubrange(range)
            }
        }
        return result
    }

    private static func claudeName(from modelID: String) -> String? {
        let parts = modelID.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return nil }

        if ["haiku", "sonnet", "opus", "fable"].contains(parts[1]) {
            let family = parts[1].capitalized
            let version = claudeVersion(family: parts[1], versionParts: parts.dropFirst(2))
            return version.isEmpty ? family : "\(family) \(version)"
        }

        if parts.count >= 4, ["haiku", "sonnet", "opus"].contains(parts.last ?? "") {
            let family = (parts.last ?? "").capitalized
            let version = claudeVersion(family: parts.last ?? "", versionParts: parts.dropFirst().dropLast())
            return version.isEmpty ? family : "\(version) \(family)"
        }

        return nil
    }

    private static func claudeVersion<S: Sequence>(family: String, versionParts: S) -> String where S.Element == String {
        let version = versionParts.joined(separator: ".")
        if version == "4" {
            switch family {
            case "haiku": return "4.5"
            case "sonnet": return "4.6"
            case "opus": return "4.8"
            default: break
            }
        }
        return version
    }

    private static func adjustedProviderPrefix(
        _ name: String,
        provider: AIProvider,
        compact: Bool
    ) -> String {
        guard compact else { return name }

        switch provider {
        case .anthropic:
            return name.replacingOccurrences(of: "Claude ", with: "")
        case .openai:
            return name.replacingOccurrences(of: "GPT-", with: "")
        default:
            return name
        }
    }

    /// Drops the maker segment of a hosted slug ("openai/gpt-5.6-luna" →
    /// "gpt-5.6-luna"). Names never show the maker: Settings already groups by
    /// it, and a raw slug reads as "Openai / gpt 5.6 Luna".
    private static func withoutMakerPrefix(_ modelID: String) -> String {
        guard let slash = modelID.lastIndex(of: "/") else { return modelID }
        let tail = String(modelID[modelID.index(after: slash)...])
        return tail.isEmpty ? modelID : tail
    }

    private static func genericName(from modelID: String, provider: AIProvider, includeProvider: Bool) -> String {
        let display = withoutMakerPrefix(modelID)
            .split(separator: "-")
            .map { token in prettyToken(String(token)) }
            .joined(separator: " ")

        guard includeProvider else { return display }
        switch provider {
        default:
            return display
        }
    }

    private static func prettyToken(_ token: String) -> String {
        let lower = token.lowercased()
        if lower == "gpt" || lower == "oss" || lower == "ai" {
            return lower.uppercased()
        }
        if lower.hasSuffix("b"), let number = Int(lower.dropLast()) {
            return "\(number)B"
        }
        return token.prefix(1).uppercased() + String(token.dropFirst())
    }
}

enum SpeechToTextProvider: String, CaseIterable, Codable {
    case groq = "Groq"
    case openai = "OpenAI"
    case openRouter = "OpenRouter"

    var label: String { rawValue }

    var iconName: String {
        switch self {
        case .groq: return "GroqIcon"
        case .openai: return "OpenAIIcon"
        case .openRouter: return "OpenRouterIcon"
        }
    }
}

/// Every distinct LLM action in the app. Most are independently configurable;
/// tasks whose product contract says “use Chat” resolve through `.chat`.
extension AITask {
    private static var validatedSettingsCatalog: [AITaskSettingsDescriptor] {
        let descriptors = AITaskSettingsCatalog.tasks
        let descriptorIDs = Set(descriptors.map(\.id))
        let nativeIDs = Set(allCases.map(\.rawValue))
        precondition(
            descriptors.count == descriptorIDs.count && descriptorIDs == nativeIDs,
            "The portable AI task Settings catalog does not match AITask.allCases"
        )
        return descriptors
    }

    private var settingsDescriptor: AITaskSettingsDescriptor {
        guard let descriptor = Self.validatedSettingsCatalog.first(where: { $0.id == rawValue }) else {
            preconditionFailure("Missing portable AI task Settings descriptor for \(rawValue)")
        }
        return descriptor
    }

    var displayName: String {
        settingsDescriptor.displayName
    }

    var description: String {
        settingsDescriptor.description
    }

    /// Whether this task appears in the advanced per-task override list in Settings.
    /// Interactive chat and tasks that deliberately share its model selection
    /// are not shown as separate overrides.
    var showInAdvancedSettings: Bool {
        settingsDescriptor.showInAdvancedSettings
    }

    /// Tasks visible in the advanced settings list.
    static var advancedTasks: [AITask] {
        validatedSettingsCatalog
            .filter(\.showInAdvancedSettings)
            .map { descriptor in
                guard let task = AITask(rawValue: descriptor.id) else {
                    preconditionFailure("Unknown portable AI task Settings descriptor \(descriptor.id)")
                }
                return task
            }
    }

    /// The source type this task operates on, used to group the advanced
    /// per-task list in Settings. Nil for tasks that span source types
    /// (classification, flashcards, chat); they show under "Other".
    /// Exhaustive on purpose: a new task must pick its group here.
    var sourceType: StudioSourceType? {
        switch self {
        case .articleMetadata, .articleChromeFiltering, .articleLinkDiscovery:
            return .article
        case .paperMetadata, .paperAttachmentCheck, .paperBrowserAgent,
             .paperFigureUnderstanding, .paperReferenceExtraction,
             .duplicateDetection,
             // Journal feeds announce papers; the matching call decides which
             // of them a Notebook should be offered.
             .journalArticleMatching:
            return .paper
        case .bookAuthor, .bookChapterSplitting, .scannedPageProofreading:
            return .book
        case .lectureNoteMatching, .lecturePaperDiscovery, .courseOrdering, .courseMetadata,
             .courseLectureNaming, .courseCurriculumPlan, .courseLessonWriting,
             // A textbook's readings are placed in a course's lectures.
             .courseTextbookReadings:
            return .course
        case .meetingSessionDetails, .meetingPaperDiscovery, .meetingActionItems:
            return .meeting
        case .podcastSpeakerIdentification, .podcastYouTubeMatching:
            return .podcast
        // Slide work lives in the talk-video pipeline: classification tells a
        // deck page from a camera shot, extraction reads a video's slides, and
        // the web lookup resolves the papers those slides cite.
        case .transcriptFormatting, .slideFrameClassification, .slideCitationExtraction,
             .citationResolution,
             // A course lecture's quiz is written from its transcript, and
             // a checkpoint or the course test from several.
             .lectureQuizWriting, .courseQuizWriting:
            return .video
        case .chat, .reviewGrading, .deepResearch,
             // Discover looks for any kind of source a notebook is missing.
             .sourceDiscovery,
             // A chat's title and its history summary, and review questions,
             // are written for every kind of source.
             .chatTitle, .chatHistoryCompaction, .realtimeReviewPreparation,
             .embedding, .sourceClassification,
             .paperNarrationPreparation, .paperTextToSpeechPreparation,
             .automaticAudioFiltering, .notebookNotesMerge,
             .mobileReview, .mobileVoiceAgent,
             // Cohort reviews deliberately span source types — that is what a
             // cross-source question is — so they belong under "Other". Idea
             // extraction runs on every consumed source type for the same reason.
             .cohortSessionPlan, .sourceIdeaExtraction,
             // Cards are drafted from every kind of source, and a mnemonic
             // reading reads a book's chapters or any text.
             .cardDrafting, .cardGoDeeper, .mnemonicReadingWriting,
             // A card's answer is checked, and its wording, whatever kind of
             // source it stands on.
             .cardAnswerCheck, .cardWordingCheck,
             // A notebook is named from every kind of source it holds.
             .notebookNaming,
             // A paste into a Page comes from any PDF, in the library or not.
             .pastedLineJoining,
             // The Map summarizes clusters of every kind of source.
             .mapSummaries,
             // Asking the Canvas, an Atlas and a source's reading levels read
             // every kind of source the library holds.
             .canvasAsk, .atlasWriting, .sourceLevels,
             // Speaking to the Canvas moves whatever kind of card is on it.
             .canvasVoice,
             // An explainer is written about a paper or an article alike.
             .explainerWriting,
             // An audio overview reads every kind of source a notebook holds,
             // and so does a report.
             .audioOverviewWriting, .reportWriting:
            return nil
        case .walkthroughWriting, .walkthroughAnimation:
            // A walkthrough is written about a paper and read in its PDF.
            return .paper
        }
    }

    /// Whether this task follows the "Background" model in Settings rather than the
    /// default Chat model. Deep Research and Source Discovery deliberately follow
    /// the same provider, model, effort, and speed as Chat;
    /// everything else here is background work (metadata, classification,
    /// generation, formatting, a chat's title and history summary).
    var usesBackgroundModelDefault: Bool {
        settingsDescriptor.usesBackgroundModelDefault
    }

    /// Whether this task takes the chat's own route (its session pick, else
    /// the Default Model) and has none of its own. A route stored for it
    /// before it followed Chat is ignored rather than left as an override
    /// Settings no longer shows.
    var followsChatRoute: Bool {
        self == .deepResearch || self == .sourceDiscovery
    }

    /// Whether this task shows the model an image rather than only text.
    ///
    /// These tasks follow the separate multimodal Background selection. A
    /// text-only per-task override still fails closed. Keep this in step with
    /// the slide and paper-figure call sites that pass `imageJPEGData`.
    var requiresVision: Bool {
        settingsDescriptor.requiresVision
    }

    /// The built-in default system prompt for this task, or nil if not applicable.
    var defaultPrompt: String? {
        switch self {
        case .sourceClassification: return Prompts.sourceClassification
        case .realtimeReviewPreparation: return Prompts.realtimeReviewPreparation
        case .paperMetadata: return Prompts.paperMetadata
        case .paperNarrationPreparation: return Prompts.paperNarrationPreparation
        case .paperTextToSpeechPreparation: return Prompts.paperTextToSpeechPreparation
        case .automaticAudioFiltering: return Prompts.automaticAudioFiltering
        case .paperAttachmentCheck: return Prompts.paperAttachmentCheck
        case .paperBrowserAgent: return Prompts.paperBrowserAgent
        case .deepResearch: return Prompts.deepResearch
        case .sourceDiscovery: return Prompts.sourceDiscovery
        case .articleMetadata: return Prompts.articleMetadata
        case .articleChromeFiltering: return Prompts.articleChromeFiltering
        case .bookAuthor: return Prompts.bookAuthor
        case .duplicateDetection: return Prompts.duplicateDetection
        case .bookChapterSplitting: return Prompts.bookChapterSplitting
        case .scannedPageProofreading: return Prompts.scannedPageProofreading
        case .meetingSessionDetails: return Prompts.meetingSessionDetails
        case .meetingActionItems: return Prompts.meetingActionItems
        case .lectureNoteMatching: return Prompts.lectureNoteMatching
        case .courseOrdering: return Prompts.courseOrdering
        case .courseMetadata: return Prompts.courseMetadata
        case .courseLectureNaming: return Prompts.courseLectureNaming
        case .reviewGrading, .notebookNotesMerge, .mobileReview, .mobileVoiceAgent: return nil
        // Their prompts live beside the chat that asks for them.
        case .chatTitle, .chatHistoryCompaction: return nil
        case .transcriptFormatting: return Prompts.readableYouTubeTranscriptFormatting
        case .podcastSpeakerIdentification: return Prompts.podcastSpeakerIdentification
        case .podcastYouTubeMatching: return Prompts.podcastYouTubeMatching
        case .slideFrameClassification: return Prompts.slideFrameClassification
        case .slideCitationExtraction: return Prompts.slideCitationExtraction
        case .paperFigureUnderstanding: return Prompts.paperFigureUnderstanding
        case .lecturePaperDiscovery: return Prompts.lecturePaperDiscovery
        case .meetingPaperDiscovery: return Prompts.meetingPaperDiscovery
        case .paperReferenceExtraction: return Prompts.paperReferenceExtraction
        case .articleLinkDiscovery: return Prompts.articleLinkDiscovery
        case .journalArticleMatching: return Prompts.journalArticleMatching
        case .citationResolution: return Prompts.citationResolution
        case .sourceIdeaExtraction: return Prompts.sourceIdeaExtraction
        case .cardDrafting: return Prompts.cardDrafter
        case .cardGoDeeper: return Prompts.goDeeperQuestion
        case .cardAnswerCheck: return Prompts.cardAnswerCheck
        case .cardWordingCheck: return Prompts.cardWordingCheck
        case .mnemonicReadingWriting: return Prompts.mnemonicReadingWriter
        case .notebookNaming: return Prompts.notebookNaming
        case .pastedLineJoining: return Prompts.pastedLineJoining
        case .mapSummaries: return Prompts.mapSummaries
        case .canvasAsk: return Prompts.canvasAsk
        case .canvasVoice: return Prompts.canvasVoice
        case .atlasWriting: return Prompts.atlasWriter
        case .sourceLevels: return Prompts.sourceLevels
        case .courseCurriculumPlan: return Prompts.courseCurriculumPlanner
        case .courseLessonWriting: return Prompts.courseLessonWriter
        case .explainerWriting: return Prompts.explainerWriter
        case .audioOverviewWriting: return Prompts.audioOverviewWriter
        case .reportWriting: return Prompts.reportWriter
        case .walkthroughWriting: return Prompts.walkthroughWriter
        case .walkthroughAnimation: return Prompts.walkthroughAnimator
        case .lectureQuizWriting: return Prompts.lectureQuizWriter
        case .courseQuizWriting: return Prompts.courseQuizWriter
        case .courseTextbookReadings: return Prompts.textbookReadingPlanner
        default: return nil
        }
    }

    /// The effective prompt: user's custom override if set, otherwise the built-in default.
    var effectivePrompt: String? {
        KeychainService.taskPrompt(self) ?? defaultPrompt
    }
}

/// Reasoning-depth request for providers that expose an effort control.
/// Raw values are OpenRouter's `reasoning_effort` wire values, every level its
/// catalog lists for any model; which of them a model takes is
/// `AIRequestOptionSupport.supportedEfforts`. Declared fastest first: the
/// effort slider lays a model's levels out in this order.
enum AIEffort: String, CaseIterable, Codable, Identifiable {
    /// No reasoning at all. Not `none`, which would read as `Optional.none`
    /// wherever an effort is optional.
    case noReasoning = "none"
    case minimal
    case low
    case medium
    case high
    case extraHigh = "xhigh"
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .noReasoning: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .extraHigh: return "Extra High"
        case .max: return "Max"
        }
    }
}

/// Output-speed request. On the OpenRouter rail, `fast` routes the request to
/// the lab's separately priced fast endpoint (`openai/fast`, `anthropic/fast`)
/// via `provider.order`; see `OpenRouterSpeedTier`. The direct first-party
/// rails offer no speed until their premium tiers are on the managed rate card.
/// Declared cheapest-and-slowest first: the Speed menu lists cases in this
/// order, so a learner reads it as a price ladder.
enum AISpeed: String, CaseIterable, Codable, Identifiable {
    /// OpenAI's Flex service tier: lower priority, about half the price.
    case flex
    case standard
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flex: return "Flex"
        case .standard: return "Standard"
        case .fast: return "Fast"
        }
    }
}

/// Which effort/speed options a given provider + model combination accepts.
/// Both the picker menu and `KeychainService.resolveConfig` consult this, so a
/// stored preference that the current model can't honor is never sent on the
/// wire (e.g. effort chosen on Opus, then the model switched to Haiku).
enum AIRequestOptionSupport {
    /// Every level OpenRouter's catalog lists for the slug this selection
    /// sends, whatever the lab: every text route reaches OpenRouter, so its
    /// list is what the request can carry. Only before the catalog has been
    /// read for the first time do Claude and GPT fall back on the levels their
    /// labs document, so a stored pick on the default model survives a first
    /// launch; every other model offers nothing until the catalog answers.
    static func supportedEfforts(provider: AIProvider, model: String) -> [AIEffort] {
        if let listed = catalogEfforts(provider: provider, model: model) { return listed }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .anthropic:
            if normalized.hasPrefix("claude-fable-") || normalized.hasPrefix("claude-mythos-")
                || normalized.hasPrefix("claude-sonnet-5") || normalized.hasPrefix("claude-opus-5")
                || normalized.hasPrefix("claude-opus-4-7")
                || normalized.hasPrefix("claude-opus-4-8") {
                return [.low, .medium, .high, .extraHigh, .max]
            }
            if normalized.hasPrefix("claude-opus-4-6") || normalized.hasPrefix("claude-sonnet-4-6") {
                return [.low, .medium, .high, .max]
            }
            if normalized.hasPrefix("claude-opus-4-5") {
                return [.low, .medium, .high]
            }
            return []
        case .openai:
            // Reasoning models accept `reasoning_effort` on chat completions;
            // GPT-6 widens the range to xhigh and max.
            return AIModelDefaults.openAIReasoningEfforts(for: normalized).compactMap(AIEffort.init(rawValue:))
        case .groq:
            return normalized.hasPrefix("openai/gpt-oss-") ? [.low, .medium, .high] : []
        default:
            return []
        }
    }

    /// The levels OpenRouter's catalog lists for the slug this selection
    /// sends, in fastest → smartest order; nil while the catalog has never been
    /// read. A model the catalog lists no effort control for offers nothing,
    /// and so does one it lists a single level for: there is nothing to choose.
    /// A level the app has no case for yet is left out, not mapped to a
    /// neighbour.
    private static func catalogEfforts(provider: AIProvider, model: String) -> [AIEffort]? {
        guard AIModelCatalog.hasReadOpenRouterReasoningEfforts else { return nil }
        let slug = OpenRouterModelID.slug(provider: provider, model: model)
        guard let listed = AIModelCatalog.openRouterReasoningEfforts(slug) else { return [] }
        let offered = Set(listed.efforts.compactMap(AIEffort.init(rawValue:)))
        let ordered = AIEffort.allCases.filter(offered.contains)
        return ordered.count > 1 ? ordered : []
    }

    /// Where the effort slider's thumb sits before the user makes an explicit
    /// pick — the effort the provider effectively runs at when none is sent.
    /// Anthropic documents `high` as its default; otherwise OpenRouter's
    /// catalog names the model's default (GLM 5.3 Flash runs at max), and a
    /// model it names none for shows the middle of the supported range.
    /// Display-only: it is never sent.
    static func displayDefaultEffort(provider: AIProvider, model: String) -> AIEffort? {
        let efforts = supportedEfforts(provider: provider, model: model)
        guard !efforts.isEmpty else { return nil }
        if provider == .anthropic, efforts.contains(.high) { return .high }
        if let listed = AIModelCatalog.openRouterReasoningEfforts(OpenRouterModelID.slug(provider: provider, model: model))?
            .defaultEffort.flatMap(AIEffort.init(rawValue:)),
           efforts.contains(listed) {
            return listed
        }
        return efforts[efforts.count / 2]
    }

    /// All selectable speeds for the combination (including `standard`), in
    /// `AISpeed`'s cheapest-first order; empty means the Speed control should
    /// not be offered at all.
    /// Speed is a property of the route, not of the model alone: the same
    /// GPT-5.6 Sol has Flex and Fast options through OpenRouter, where the
    /// lab's tier endpoints carry their own published prices that the Worker
    /// bills exactly from the generation record, and none through the direct
    /// OpenAI rail, whose tiers are not on the managed rate card. The answer
    /// is therefore which tier endpoints OpenRouter lists for the slug this
    /// selection would send — read from `OpenRouterEndpointTierCatalog`'s
    /// cache, which the picker and the dispatch path fill. Standard is only
    /// offered as the alternative to a real tier: a model with no tier
    /// endpoint has nothing to choose between.
    static func supportedSpeeds(
        provider: AIProvider,
        model: String,
        routingMode: AITextRoutingMode = KeychainService.textRoutingMode
    ) -> [AISpeed] {
        guard let slug = openRouterSpeedSlug(provider: provider, model: model, routingMode: routingMode),
              let tiers = OpenRouterEndpointTierCatalog.cachedTiers(slug: slug)
        else { return [] }
        let speeds = AISpeed.allCases.filter { speed in
            speed == .standard || OpenRouterSpeedTier.tier(for: speed, slug: slug, in: tiers) != nil
        }
        return speeds.count > 1 ? speeds : []
    }

    /// Whether a stored speed pick can travel with this selection at all. This
    /// is the check for keeping or clearing a preference: it asks only whether
    /// the route reaches OpenRouter, not whether the endpoint list has been
    /// fetched yet, so a Fast pick survives a launch with a cold cache. The
    /// dispatch path primes the cache and applies `supportedSpeeds` itself.
    static func routeCanCarrySpeed(
        provider: AIProvider,
        model: String,
        routingMode: AITextRoutingMode = KeychainService.textRoutingMode
    ) -> Bool {
        openRouterSpeedSlug(provider: provider, model: model, routingMode: routingMode) != nil
    }

    /// The OpenRouter slug whose endpoint list decides the speed control. Every
    /// text route is OpenRouter, so every selection has one.
    static func openRouterSpeedSlug(
        provider: AIProvider,
        model: String,
        routingMode: AITextRoutingMode
    ) -> String? {
        OpenRouterModelID.slug(provider: provider, model: model)
    }
}

/// One provider/model route that can serve an AI task. Provider remains part
/// of the selection because it determines slug mapping, request options,
/// display names, and context budgeting for the model that is actually
/// attempted.
struct AITaskModelRoute: Sendable, Equatable {
    let provider: AIProvider
    let model: String
}

/// Resolved provider + API key + model for an AI task.
struct AITaskConfig: Sendable {
    let provider: AIProvider
    let apiKey: String
    let model: String
    /// Reasoning effort to request, already validated against the model; nil = provider default.
    var effort: AIEffort? = nil
    /// Output speed to request, already validated against the model; nil = standard.
    var speed: AISpeed? = nil
    /// Usage-ledger tag for the feature this config serves. Stamped with the
    /// `AITask` rawValue by `KeychainService.resolveConfig(for:)`; call sites
    /// with a more specific purpose ("chat", "chat_title") overwrite it. The
    /// `AIService` entry points bind it as `AIUsageAttribution.task` so every
    /// recorded call lands in the ledger naming the feature that made it.
    var taskLabel: String? = nil
    /// One of the setting's backup models (`AIBackupModels`), standing in for
    /// the model it names. A backup is never sent a request cut to fit it.
    var isBackup = false
}

// AIUsageEvent lives in AIUsageReporting.swift (shared with the mobile targets).

struct AIUsageSummary: Identifiable, Sendable {
    var id: String { "\(provider)|\(model)" }
    let provider: String
    let model: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let cacheCreationInputTokens: Int
    let reasoningTokens: Int
    let audioInputTokens: Int
    let audioOutputTokens: Int
    let imageCount: Int
    let totalTokens: Int
    let characterCount: Int
    let durationSeconds: Double
    let providerReportedCost: Double?
    let estimatedCost: Double?
    /// Events in this group with no known list price (estimatedCost stamped
    /// nil at record time). SQL SUM skips NULLs, so without this count a group
    /// mixing priced and unpriced events would silently show a partial total.
    let unpricedCount: Int
    let currency: String?
}

/// Per-local-day usage rollup for the costs dashboard chart.
struct AIUsageDailyTotal: Identifiable, Sendable {
    var id: String { day }
    /// Local calendar day, formatted YYYY-MM-DD.
    let day: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double?
}

/// One task's spend on one provider/model pair over a period: the row the
/// MCP usage report groups by task and by model. `task` is the ledger's task
/// tag (an `AITask` rawValue or a purpose label such as "chat_title"), empty
/// for calls recorded before task attribution existed. `cost` is the pane's
/// accounted cost (provider-billed amount, else the list-price estimate) and
/// is nil when every call in the group is unpriced; `unpricedCallCount` says
/// how many calls a non-nil total still leaves out.
struct AIUsageTaskModelSummary: Identifiable, Sendable, Equatable {
    var id: String { "\(task)|\(provider)|\(model)" }
    let task: String
    let provider: String
    let model: String
    let callCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let cacheCreationInputTokens: Int
    let reasoningTokens: Int
    let cost: Double?
    let unpricedCallCount: Int
    let latestAt: Date
}

/// Per-operation usage rollup ("what feature spent this") for the costs dashboard.
struct AIUsageOperationSummary: Identifiable, Sendable {
    var id: String { operation }
    let operation: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double?
}

enum UITestConfiguration {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }
}

// MARK: - Reading List Studio

enum StudioArticleState: String, Codable {
    case queued      // in the queue, content not yet fetched
    case fetching    // content is being fetched
    case ready       // content fetched, available via MCP
    case error       // fetch failed
}

/// Durable proof that a paper passed the metadata gate required for ingestion.
/// `legacy` is written only by the one-time schema migration for papers that
/// predate the gate and already have complete metadata. New papers can become
/// ready only after a successful Paper Metadata LLM call writes `llm`.
enum PaperIngestionMethod: String, Codable {
    case legacy
    case llm
    /// The learner supplied the required metadata by hand. Some scholarly
    /// documents simply do not print all of it — a repository thesis often has
    /// no journal and no year anywhere in its front matter — so a human
    /// attestation has to be able to complete ingestion the model could not.
    case manual
    /// Another of the learner's devices finished this paper's ingestion and its Source
    /// record arrived `ready` (generation 2: `Source.ingest`, written only after that
    /// device passed the metadata gate). This Mac took its word and neither calls the
    /// Paper Metadata model nor queues the paper for it. Written only by
    /// `SourceProjection` and `InboundSourceFiles`.
    case synced
}

/// A user-actionable paper problem shown in the "Papers that need attention"
/// list. Deferred cleanup and Listen preparation are intentionally absent: they
/// are background maintenance, not evidence that an intact paper is broken.
enum PaperAttentionReason: String, Equatable {
    case pdfNeeded = "PDF needed"
    case metadataIncomplete = "Metadata incomplete"
}

/// The concrete user action that resolves a persisted paper-ingestion failure.
/// These cases classify only code-owned error messages emitted by the paper
/// pipeline; human-authored source text never participates in this decision.
enum PaperIngestionRecoveryAction: Equatable {
    case configureAI
    case addBalance
    case attachPDF
    /// The extractor ran and simply could not find a field the document never
    /// prints. Retrying it produces the same answer; the learner filling the
    /// field in is the fix.
    case editDetails
    case retry

    var title: String {
        switch self {
        case .configureAI: return "Configure AI"
        case .addBalance: return "Add Key"
        case .attachPDF: return "Choose PDF"
        case .editDetails: return "Edit Details"
        case .retry: return "Retry"
        }
    }
}

/// Typed status flags that were historically stored as sentinel strings in
/// `StudioArticle.errorMessage`. The raw values match those legacy strings so
/// the persisted representation (SQLite `sources.error_message`, and therefore
/// CloudKit sync) is unchanged. These are distinct from genuine free-text error
/// messages: `StudioArticle.statusFlag` is non-nil only when `errorMessage`
/// exactly equals one of these flags.
enum SourceStatusFlag: String {
    case paywall            // source is behind a paywall; needs a PDF attachment
    case confirmPodcast     // a podcast match was found and awaits user confirmation
    case needsTranscript    // podcast match confirmed but no transcript is available yet
}

enum StudioSourceType: String, Codable {
    case article       // web article, blog post, newsletter (LLM-confirmed)
    case paper         // academic paper
    case podcast       // podcast transcript
    case book          // book chapter PDF
    case course        // course material PDF
    case meeting       // recurring meeting session with transcript/notes/chat artifacts
    case video         // YouTube, Zoom recording, read.ai, etc.
    case xPost         // X/Twitter post
    case manual        // manually added URL
    case unclassified  // web URL awaiting LLM classification (article vs paper)

    /// The families a search filter offers. `manual` and `unclassified` are
    /// storage states of a web page, not kinds of source a reader would name,
    /// so they are not listed; `article` covers them. Offering them made an
    /// assistant sweep the library one family at a time to be thorough.
    static let searchFamilyNames: [String] = ["article", "paper", "podcast", "book", "course", "meeting", "video", "xPost"]

    /// The stored `source_type` values one search family covers, or nil when
    /// the name is not a source type at all. The raw storage states are still
    /// accepted and fold into the article family, so an old schema keeps working.
    static func searchFamily(named name: String) -> [String]? {
        guard let type = StudioSourceType(rawValue: name) else { return nil }
        switch type {
        case .article, .manual, .unclassified:
            return [StudioSourceType.article, .manual, .unclassified].map(\.rawValue)
        default:
            return [type.rawValue]
        }
    }

    /// The SF Symbol a row uses for a source of this type, the one the
    /// sidebar's family icons and the chat's context rows share.
    var symbolName: String {
        switch self {
        case .article, .unclassified: return "doc.richtext"
        case .paper: return "doc.text.magnifyingglass"
        case .podcast: return "headphones"
        case .book: return "book.closed"
        case .course: return "graduationcap"
        case .meeting: return "person.2.wave.2"
        case .video: return "play.rectangle"
        case .xPost: return "bubble.left"
        case .manual: return "link"
        }
    }

    /// Metadata fields that can be toggled for this source type in the sidebar.
    var configurableMetadataFields: [SourceMetadataField] {
        switch self {
        case .article, .unclassified: return [.author, .domain, .readTime]
        case .paper:   return [.author, .journal, .year]
        case .podcast: return [.author, .domain, .date, .readTime]
        case .book:    return [.author, .subtitle, .edition, .format, .kind, .readTime]
        case .course:  return [.subtitle]
        case .meeting: return [.domain, .date, .readTime]
        case .video:   return [.author, .domain]
        case .xPost:   return [.author, .domain, .readTime]
        case .manual:  return [.author, .domain, .readTime]
        }
    }
}

// MARK: - Meetings

/// When a meeting series meets: the weekdays, the start on the clock, how
/// long, and the time zone the clock is read in. Structure, not prose —
/// `recurrenceRule` stays the human line under the folder's name; this is
/// what the Planner draws from (planner-design.md, "A meeting series on the
/// clock"). Weekdays follow `Calendar`: 1 is Sunday, 7 is Saturday.
struct MeetingSchedule: Codable, Equatable, Hashable, Sendable {
    var weekdays: [Int]
    var startMinute: Int
    var durationMinutes: Int
    var timezone: String

    static let weekdayRange = 1...7
    static let workdays = [2, 3, 4, 5, 6]

    init(weekdays: [Int], startMinute: Int, durationMinutes: Int, timezone: String) {
        self.weekdays = Array(Set(weekdays.filter { Self.weekdayRange.contains($0) })).sorted()
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.timezone = timezone
    }

    /// A schedule the Planner can draw: at least one weekday, a start on the
    /// clock, a duration of at least the smallest block, and a zone `TimeZone`
    /// knows. A synced record from a client that wrote something else is
    /// held but never drawn.
    var isValid: Bool {
        !weekdays.isEmpty
            && (0..<(24 * 60)).contains(startMinute)
            && durationMinutes >= 5
            && startMinute + durationMinutes <= 24 * 60
            && TimeZone(identifier: timezone) != nil
    }

    var endMinute: Int { startMinute + durationMinutes }

    /// The JSON the `meeting_groups.schedule_json` column and the synced
    /// record carry; keys sorted so the same schedule is the same bytes.
    var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(jsonString: String?) {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MeetingSchedule.self, from: data) else { return nil }
        self = decoded
    }
}

struct MeetingMetadata: Codable, Equatable, Hashable, Sendable {
    var title: String?
    var driveFolderURL: String?
    var localFolderPath: String?
    var recurrenceRule: String?
    var timezone: String?
    var isHidden: Bool = false
    /// A retired provider/group identity that now feeds another meeting group.
    /// The row remains durable so future plugin deliveries can follow the
    /// alias instead of recreating the group the learner merged away.
    var mergedIntoGroupID: String?
    /// When the series meets, so the Planner draws its occurrence on every
    /// day it covers. Nil for a series that has no fixed time.
    var schedule: MeetingSchedule?

    init(
        title: String? = nil,
        driveFolderURL: String? = nil,
        localFolderPath: String? = nil,
        recurrenceRule: String? = nil,
        timezone: String? = nil,
        isHidden: Bool = false,
        mergedIntoGroupID: String? = nil,
        schedule: MeetingSchedule? = nil
    ) {
        self.title = title
        self.driveFolderURL = driveFolderURL
        self.localFolderPath = localFolderPath
        self.recurrenceRule = recurrenceRule
        self.timezone = timezone
        self.isHidden = isHidden
        self.mergedIntoGroupID = mergedIntoGroupID
        self.schedule = schedule
    }
}

extension MeetingMetadata {
    /// `meetingFolder.image.<groupID>` — the sidebar tile the learner picked for
    /// one meeting folder.
    ///
    /// A synced preference rather than a column on `meeting_groups`: this is
    /// display chrome, not a fact about the meeting, and one row per folder keeps
    /// two Macs choosing images for two different folders from overwriting each
    /// other the way a single shared map would.
    static let folderImagePreferenceKeyPrefix = "meetingFolder.image."

    static func folderImagePreferenceKey(for groupID: String) -> String {
        folderImagePreferenceKeyPrefix + groupID
    }
}

enum MeetingArtifactKind: String, Codable, CaseIterable, Sendable {
    case transcript
    case notes
    case chat
    case recording
    case attachment

    var label: String {
        switch self {
        case .transcript: return "Transcript"
        case .notes: return "Notes"
        case .chat: return "Chat"
        case .recording: return "Recording"
        case .attachment: return "Attachment"
        }
    }

    var sortRank: Int {
        switch self {
        case .transcript: return 0
        case .notes: return 1
        case .chat: return 2
        case .recording: return 3
        case .attachment: return 4
        }
    }

    var iconName: String {
        switch self {
        case .transcript: return "text.alignleft"
        case .notes: return "note.text"
        case .chat: return "bubble.left.and.bubble.right"
        case .recording: return "play.rectangle"
        case .attachment: return "paperclip"
        }
    }
}

/// Pure construction of the merged meeting document stored on a source. Both
/// the app and MCP use this one implementation so generating a transcript can
/// never overwrite notes that arrived from Google Drive.
enum MeetingContent {
    nonisolated static func contains(
        section kind: MeetingArtifactKind,
        in content: String?
    ) -> Bool {
        guard let content, !content.isEmpty else { return false }
        return content.range(of: "\n## \(kind.label)\n") != nil
    }

    nonisolated static func text(
        for section: MeetingArtifactKind,
        in content: String?
    ) -> String? {
        guard let content,
              let start = content.range(of: "\n## \(section.label)\n") else { return nil }
        var end = content.endIndex
        for other in MeetingArtifactKind.allCases where other != section {
            if let range = content.range(
                of: "\n## \(other.label)\n",
                range: start.upperBound..<content.endIndex
            ), range.lowerBound < end {
                end = range.lowerBound
            }
        }
        let text = content[start.upperBound..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated static func inserting(
        section kind: MeetingArtifactKind,
        text: String,
        into content: String?,
        title: String
    ) -> String {
        var base = (content?.isEmpty == false) ? content! : "# \(title)"

        if let start = base.range(of: "\n## \(kind.label)\n") {
            var end = base.endIndex
            for other in MeetingArtifactKind.allCases where other != kind {
                if let range = base.range(
                    of: "\n## \(other.label)\n",
                    range: start.upperBound..<base.endIndex
                ), range.lowerBound < end {
                    end = range.lowerBound
                }
            }
            base.replaceSubrange(start.lowerBound..<end, with: "")
        }

        var insertAt = base.endIndex
        for other in MeetingArtifactKind.allCases where other.sortRank > kind.sortRank {
            if let range = base.range(of: "\n## \(other.label)\n"), range.lowerBound < insertAt {
                insertAt = range.lowerBound
            }
        }
        let body = "\n\n## \(kind.label)\n\n\(text)"
        base.insert(contentsOf: insertAt == base.endIndex ? body : body + "\n", at: insertAt)
        return base
    }
}

/// One thing a meeting session's transcript asked someone to do. Extracted
/// once per session by `AITask.meetingActionItems`; the id is the app's
/// (`<source id>#<position>`), never the model's, so a re-run can only ever
/// land on the same rows. `doneAt` is set by the learner and only ever set,
/// which is what lets two Macs' copies union.
struct MeetingActionItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var groupID: String
    var sourceID: String
    var position: Int
    var text: String
    var owner: String?
    var dueHint: String?
    var doneAt: Date?
    var createdAt: Date
    var updatedAt: Date

    static func makeID(sourceID: String, position: Int) -> String {
        "\(sourceID)#\(position)"
    }

    var isDone: Bool { doneAt != nil }

    init(
        groupID: String,
        sourceID: String,
        position: Int,
        text: String,
        owner: String? = nil,
        dueHint: String? = nil,
        doneAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = Self.makeID(sourceID: sourceID, position: position)
        self.groupID = groupID
        self.sourceID = sourceID
        self.position = position
        self.text = text
        self.owner = owner
        self.dueHint = dueHint
        self.doneAt = doneAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MeetingArtifact: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var sourceId: String
    var groupId: String
    var kind: MeetingArtifactKind
    var title: String
    var url: String?
    var localFilePath: String?
    var mimeType: String?
    var modifiedAt: Date?
    var sortIndex: Int

    init(
        id: String = UUID().uuidString,
        sourceId: String,
        groupId: String,
        kind: MeetingArtifactKind,
        title: String,
        url: String? = nil,
        localFilePath: String? = nil,
        mimeType: String? = nil,
        modifiedAt: Date? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.sourceId = sourceId
        self.groupId = groupId
        self.kind = kind
        self.title = title
        self.url = url
        self.localFilePath = localFilePath
        self.mimeType = mimeType
        self.modifiedAt = modifiedAt
        self.sortIndex = sortIndex
    }
}

// MARK: - Courses

struct CourseMetadata: Codable, Equatable, Hashable, Sendable {
    var courseCode: String?
    var title: String?
    var institution: String?
    var instructors: String?
    var playlistURL: String?
    var isHidden: Bool = false
    /// Browser-authored course shell awaiting one native playlist expansion.
    /// Explicit so an intentionally empty course is never re-imported.
    var pendingPlaylistImport: Bool = false

    init(
        courseCode: String? = nil,
        title: String? = nil,
        institution: String? = nil,
        instructors: String? = nil,
        playlistURL: String? = nil,
        isHidden: Bool = false,
        pendingPlaylistImport: Bool = false
    ) {
        self.courseCode = courseCode
        self.title = title
        self.institution = institution
        self.instructors = instructors
        self.playlistURL = playlistURL
        self.isHidden = isHidden
        self.pendingPlaylistImport = pendingPlaylistImport
    }
}

// MARK: - Video Playlists

struct VideoPlaylistMetadata: Codable, Equatable, Hashable, Sendable {
    var title: String
    var playlistURL: String
    var lastRefreshedAt: Date?
    var isHidden: Bool
    /// When true, the YouTube plugin re-checks this playlist in the background
    /// (shortly after launch, then every few hours) and imports any new videos.
    /// False for ordinary, manually-added playlists, which only refresh on demand.
    var autoImport: Bool
    /// How the followed item was added: "liked" for the Liked-videos feed,
    /// "foreverlm" for the owned playlist with that name, "channel"/"playlist"
    /// for legacy follows, or nil for an ordinary manually-added playlist group.
    var connectorKind: String?

    init(
        title: String,
        playlistURL: String,
        lastRefreshedAt: Date? = nil,
        isHidden: Bool = false,
        autoImport: Bool = false,
        connectorKind: String? = nil
    ) {
        self.title = title
        self.playlistURL = playlistURL
        self.lastRefreshedAt = lastRefreshedAt
        self.isHidden = isHidden
        self.autoImport = autoImport
        self.connectorKind = connectorKind
    }
}

/// A numbered pedagogical unit inside a course. Sources are attached through
/// CourseLectureItem records so a lecture can contain arbitrary materials.
struct CourseSession: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var courseName: String
    var number: Int
    var title: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        courseName: String,
        number: Int,
        title: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.courseName = courseName
        self.number = number
        self.title = title
        self.createdAt = createdAt
    }
}

enum CourseLectureItemRole: String, Codable, CaseIterable, Sendable {
    case video
    case notes
    case slides
    case exercise
    case reading
    case article
    case podcast
    case code
    case reference
    case other

    var label: String {
        switch self {
        case .video: return "Video"
        case .notes: return "Notes"
        case .slides: return "Slides"
        case .exercise: return "Exercise"
        case .reading: return "Reading"
        case .article: return "Article"
        case .podcast: return "Podcast"
        case .code: return "Code"
        case .reference: return "Reference"
        case .other: return "Material"
        }
    }
}

/// An addressable unit inside a source, such as a repo subfolder, book chapter,
/// or page range. The initial UI attaches whole sources, but the model supports
/// finer units for exercises/code paths.
struct SourceUnit: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var sourceId: String
    var kind: String
    var locator: String
    var title: String?

    init(
        id: String = UUID().uuidString,
        sourceId: String,
        kind: String,
        locator: String,
        title: String? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.locator = locator
        self.title = title
    }
}

/// A material attached to a course lecture. It can point to a whole source or
/// to a SourceUnit for things like GitHub subfolders.
struct CourseLectureItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var lectureId: String
    var sourceId: String?
    var sourceUnitId: String?
    var role: CourseLectureItemRole
    var label: String?
    var sortIndex: Int
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        lectureId: String,
        sourceId: String? = nil,
        sourceUnitId: String? = nil,
        role: CourseLectureItemRole = .other,
        label: String? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.lectureId = lectureId
        self.sourceId = sourceId
        self.sourceUnitId = sourceUnitId
        self.role = role
        self.label = label
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

// MARK: - Metadata Visibility

/// Individual metadata fields that can be shown or hidden per source type.
enum SourceMetadataField: String, CaseIterable, Codable, Hashable {
    case author
    case domain      // website domain or show name
    case date        // date added
    case readTime    // estimated source length in minutes
    case format      // PDF / EPUB badge
    case journal     // papers only
    case year        // papers only
    case kind        // books: category (textbook, etc.)
    case subtitle    // books: subtitle; courses: code · instructors · institution
    case edition     // books only
    case ttsCache    // legacy persisted key; audio availability is always shown

    var displayName: String {
        switch self {
        case .author:   return "Author"
        case .domain:   return "Source"
        case .date:     return "Date"
        case .readTime: return "Est. Time"
        case .format:   return "Format"
        case .journal:  return "Journal"
        case .year:     return "Year"
        case .kind:     return "Category"
        case .subtitle: return "Details"
        case .edition:  return "Edition"
        case .ttsCache: return "Text to Speech"
        }
    }

    var icon: String {
        switch self {
        case .author:   return "person"
        case .domain:   return "globe"
        case .date:     return "calendar"
        case .readTime: return "clock"
        case .format:   return "doc"
        case .journal:  return "building.columns"
        case .year:     return "number"
        case .kind:     return "tag"
        case .subtitle: return "info.circle"
        case .edition:  return "books.vertical"
        case .ttsCache: return "speaker.wave.2"
        }
    }

    func displayName(for sourceType: StudioSourceType) -> String {
        if self == .subtitle, sourceType == .book {
            return "Subtitle"
        }
        // A meeting's "author" is whoever presented it.
        if self == .author, sourceType == .meeting {
            return "Presenter"
        }
        if self == .domain, sourceType == .video {
            return "Channel"
        }
        return displayName
    }

    func icon(for sourceType: StudioSourceType) -> String {
        if self == .subtitle, sourceType == .book {
            return "text.quote"
        }
        if self == .author, sourceType == .meeting {
            return "person.wave.2"
        }
        return icon
    }
}

/// Persisted per-source-type metadata visibility. All fields visible by default; only hidden
/// fields are stored. Conforms to `RawRepresentable<String>` for use with `@AppStorage`.
struct MetadataVisibilitySettings: RawRepresentable, Equatable {
    private var hidden: [String: Set<String>]

    init() { hidden = [:] }

    init?(rawValue: String) {
        self.hidden = [:]
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        self.hidden = decoded.mapValues { Set($0) }
    }

    var rawValue: String {
        let simplified = hidden.mapValues { Array($0) }
        guard let data = try? JSONEncoder().encode(simplified) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func isVisible(_ field: SourceMetadataField, for sourceType: StudioSourceType) -> Bool {
        !(hidden[sourceType.rawValue]?.contains(field.rawValue) ?? false)
    }

    mutating func toggle(_ field: SourceMetadataField, for sourceType: StudioSourceType) {
        var set = hidden[sourceType.rawValue] ?? []
        if set.contains(field.rawValue) {
            set.remove(field.rawValue)
        } else {
            set.insert(field.rawValue)
        }
        hidden[sourceType.rawValue] = set.isEmpty ? nil : set
    }
}

/// Which browser or service an article was discovered from.
enum DiscoveryOrigin: String, Codable {
    case safari
    case chrome
    case brave
    case applePodcasts
    case localBooks
    case localCourses
    case localMeetings
    case googleDriveMeetings
    case readAI
    /// A Zoom cloud recording, added from its share or play link.
    case zoom
    case localPapers
    case youtubePlaylist
    case xBookmarks
    case manual
    /// Added by a user-built plugin over MCP (an ingest-scoped OAuth
    /// client). The specific plugin is recorded in
    /// `StudioArticle.connectorLabel`, never inferred from tool arguments.
    case plugin = "connector"
}

/// Which service a meeting session arrived from.
///
/// Meetings are one source family with several feeds behind it: a Google Drive
/// folder of Meet recordings, Read AI's ingest plugin, a Zoom cloud
/// recording link, or a folder imported from this Mac. Provider is a fact about
/// the *session*, read off its
/// discovery origin — never off whichever tab happens to be showing. That is
/// what lets one recurring series carry sessions from more than one provider
/// and still be a single row, instead of being listed once per provider.
///
/// Adding a provider should mean one case here plus one ingest entry point, and
/// no new presentation code.
enum MeetingProvider: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case googleDrive
    case readAI
    case zoom
    /// A folder imported from this Mac, and the home for sessions pushed in
    /// over MCP without a provider hint. Naming it honestly matters: these used
    /// to be filed under Google Drive because the split tabs left them with
    /// nowhere else to go, which claimed a Drive connection that did not exist.
    case localFolder

    var id: String { rawValue }

    static func forOrigin(_ origin: DiscoveryOrigin?) -> MeetingProvider {
        switch origin {
        case .readAI: return .readAI
        case .googleDriveMeetings: return .googleDrive
        case .zoom: return .zoom
        default: return .localFolder
        }
    }

    /// Maps an authenticated plugin's registered display name onto a meeting
    /// provider. This is intentionally constrained to the provider catalog: an
    /// arbitrary plugin label can never spoof a discovery origin, while a
    /// branded meeting plugin is no longer misfiled as a local folder.
    static func forPluginLabel(_ label: String) -> MeetingProvider? {
        allCases.first { $0.matches(connectorLabel: label) }
    }

    /// Whether a plugin's registered name claims this provider.
    ///
    /// A plugin names itself, and that name is what every source it adds
    /// carries. The guide's worked example registers as "Read AI Meetings", and
    /// an assistant following the recipe picks something like it, so the claim
    /// is the brand as the name's leading word(s). Exact equality was the bug:
    /// a healthy "Read AI Meetings" plugin counted as no Read AI plugin
    /// at all, so the Meetings tab reported Read AI disconnected while its
    /// meetings were filed under Local Folder. Still bounded to the catalog: a
    /// name has to lead with a provider's brand to claim it, and "Zoomer" or
    /// "Read" claim nothing.
    func matches(connectorLabel label: String) -> Bool {
        guard isPlugin else { return false }
        let labelWords = Self.brandWords(label)
        let brand = Self.brandWords(displayName)
        guard !labelWords.isEmpty, !brand.isEmpty else { return false }
        if labelWords.starts(with: brand) { return true }
        // The brand written as one word: "ReadAI sync".
        return labelWords.first == brand.joined()
    }

    private static func brandWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    var pluginDiscoveryOrigin: DiscoveryOrigin? {
        switch self {
        case .readAI: return .readAI
        case .zoom: return .zoom
        case .googleDrive, .localFolder: return nil
        }
    }

    /// Distinct providers behind a set of origins, in stable presentation order
    /// so a series feeding from two providers badges them identically wherever
    /// it is drawn.
    static func providers(for origins: some Sequence<DiscoveryOrigin?>) -> [MeetingProvider] {
        Set(origins.map(forOrigin)).sorted { $0.sortRank < $1.sortRank }
    }

    var sortRank: Int {
        switch self {
        case .googleDrive: return 0
        case .readAI: return 1
        case .zoom: return 2
        case .localFolder: return 3
        }
    }

    /// The providers a series row wears as marks.
    ///
    /// Local Folder is the home for whatever arrived without a provider — a
    /// recording added from this Mac, a transcript pushed over MCP with no
    /// hint — not a service the series is synced with. Next to a Zoom or Drive
    /// mark it said nothing the brand mark did not already say, and read as a
    /// second, unexplained service. So it is drawn only when it is the only
    /// answer. The provider filter keeps the full list: a series with local
    /// recordings still matches a Local Folder filter.
    static func marks(for providers: [MeetingProvider]) -> [MeetingProvider] {
        let branded = providers.filter { $0 != .localFolder }
        return branded.isEmpty ? providers : branded
    }

    var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .readAI: return "Read AI"
        case .zoom: return "Zoom"
        case .localFolder: return "Local Folder"
        }
    }

    /// Full-color brand logo, rendered in place of the SF Symbol when present.
    /// These are the same assets the split Google Drive and Read AI tabs used
    /// to carry in the tab strip: the brand marks did not go away with the
    /// tabs, they moved down onto the rows where they say something per-item.
    var iconAsset: String? {
        switch self {
        case .googleDrive: return "GoogleDriveIcon"
        case .readAI: return "ReadAIIcon"
        case .zoom: return "ZoomIcon"
        case .localFolder: return nil
        }
    }

    var icon: String {
        switch self {
        case .googleDrive: return "folder"
        case .readAI: return "waveform"
        case .zoom: return "video"
        case .localFolder: return "internaldrive"
        }
    }

    var color: Color {
        switch self {
        case .googleDrive: return .blue
        case .readAI: return .indigo
        case .zoom: return .blue
        case .localFolder: return .secondary
        }
    }

    /// Whether this provider arrives through a registered MCP ingest client
    /// rather than a first-party sign-in or a local folder. Settings uses it to
    /// decide which providers earn a branded card under Your Plugins — a
    /// question that used to be answered by the tab list, which is why merging
    /// the tabs would otherwise have cost Read AI its card.
    var isPlugin: Bool {
        switch self {
        case .readAI, .zoom: return true
        case .googleDrive, .localFolder: return false
        }
    }

    /// One line for the provider's card in Settings.
    var pluginSubtitle: String {
        switch self {
        case .googleDrive: return "Import meeting recordings and transcripts from a folder."
        case .readAI: return "Add meeting transcripts through your plugin."
        case .zoom: return "Transcripts Zoom saves to Documents/Zoom file themselves; cloud recordings arrive through your plugin."
        case .localFolder: return "Import a folder of recordings from this Mac."
        }
    }

    /// What the plugin setup prompt carries when the Meetings tab copies it
    /// for this provider: the part of the guide's worked example an assistant
    /// needs and would otherwise have to discover, including the name that
    /// makes ForeverLM file the plugin's meetings under the provider. Empty
    /// for providers that don't arrive through a plugin.
    var pluginSetupNotes: String {
        switch self {
        case .readAI:
            return """
            Notes for Read AI: register the plugin with a "client_name" that starts with "Read AI" (for example "Read AI Meetings") so ForeverLM files its meetings under Read AI. Read AI's API uses OAuth 2.1 with PKCE and rotating, single-use refresh tokens — persist each new refresh token the instant it is issued and never let two runs overlap. Request the scopes openid email profile offline_access meeting:read mcp:execute; its REST API rejects a token minted from a narrower set with "Invalid audience". My workspace needs Downloads enabled under Workspace Settings → Reports & Sharing. List recent ended meetings, fetch each one's summary and speaker-attributed transcript, and push one source per meeting with source_type "meeting", the organizer as author, https://app.read.ai/analytics/meetings/<meeting id> as its stable url, occurred_at from the meeting's start time (ISO 8601), and parent_group set to the series name — the title with tags like "[EF]" and any trailing date stripped — so each meeting files inside its recurring series. Re-examine the last few days on every run so late-arriving transcripts are picked up, and call report_connector_status at the start and end of every run so ForeverLM can show the plugin's health.
            """
        case .zoom:
            return """
            Notes for Zoom: register the plugin with a "client_name" that starts with "Zoom" so ForeverLM files its recordings under Zoom. List my cloud recordings, fetch each transcript, and push one source per recording with source_type "meeting" and the recording's share link as its stable url. Call report_connector_status at the start and end of every run so ForeverLM can show the plugin's health.
            """
        case .googleDrive, .localFolder:
            return ""
        }
    }
}

enum SourceStatus: String, Codable {
    case active
    case archived
}

enum SourceIdentity {
    static func stableID(for url: String) -> String {
        let key = "source:v1:\(URLNormalizer.normalize(url))"
        let digest = SHA256.hash(data: Data(key.utf8))
        return "src_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A file captured on the iPhone or the web, from the lowercase hex sha256 of its bytes
    /// (docs/cloudkit-schema-design.md D47): the same bytes captured twice are one source. The Mac's
    /// own file imports keep their path-based ids and carry the `file:` work key instead, so a capture
    /// of a PDF this Mac already holds is found by lookup before it is minted.
    static func fileID(sha256 fileHash: String) -> String {
        SyncIdentity.sourceFileID(sha256Hex: fileHash.lowercased())
    }
}

/// A compare-and-swap patch for the fields owned by deterministic paper metadata
/// backfill. Network lookups can overlap PDF attachment and AI metadata
/// extraction, so applying a captured whole `StudioArticle` after an `await`
/// would revert unrelated, newer fields such as URL and `localFilePath`.
struct PaperMetadataBackfillPatch: Sendable {
    let sourceID: String

    private let originalTitle: String
    private let title: String
    private let originalAuthor: String?
    private let author: String?
    private let originalJournal: String?
    private let journal: String?
    private let originalPublishedYear: String?
    private let publishedYear: String?
    private let originalDOI: String?
    private let doi: String?
    private let originalPublishedDOI: String?
    private let publishedDOI: String?

    init(original: StudioArticle, candidate: StudioArticle) {
        sourceID = original.id
        originalTitle = original.title
        title = candidate.title
        originalAuthor = original.author
        author = candidate.author
        originalJournal = original.journal
        journal = candidate.journal
        originalPublishedYear = original.publishedYear
        publishedYear = candidate.publishedYear
        originalDOI = original.doi
        doi = candidate.doi
        originalPublishedDOI = original.publishedDOI
        publishedDOI = candidate.publishedDOI
    }

    /// Apply only fields that still equal the values observed before the network
    /// work began. A concurrent AI result wins field-by-field, while unrelated
    /// source state is never touched.
    @discardableResult
    func apply(to article: inout StudioArticle) -> Bool {
        guard article.id == sourceID, article.sourceType == .paper else { return false }

        var changed = false
        if title != originalTitle, article.title == originalTitle {
            article.title = title
            changed = true
        }
        if author != originalAuthor, article.author == originalAuthor {
            article.author = author
            changed = true
        }
        if journal != originalJournal, article.journal == originalJournal {
            article.journal = journal
            changed = true
        }
        if publishedYear != originalPublishedYear,
           article.publishedYear == originalPublishedYear {
            article.publishedYear = publishedYear
            changed = true
        }
        if doi != originalDOI, article.doi == originalDOI {
            article.doi = doi
            changed = true
        }
        if publishedDOI != originalPublishedDOI, article.publishedDOI == originalPublishedDOI {
            article.publishedDOI = publishedDOI
            changed = true
        }
        return changed
    }
}

struct PaperContentPreparationMetadata: Codable, Equatable, Sendable {
    /// Version 1 is the deterministic migration cleanup. Version 2 returned a
    /// rewritten paper. Version 3 applies a validated paper block-deletion plan.
    /// Version 4 extends that same non-rewriting contract to web articles.
    /// Version 5 feeds the complete raw extraction to the model and applies a
    /// validated deletion-only diff with both block and exact-text hunks.
    /// Version 6 uses smaller stable blocks, bounds inline hunks, disables
    /// reasoning, and validates every uncached diff before persistence. Version
    /// 7 makes extracted physical lines the deletion unit so metadata and prose
    /// can never disappear together in one coarse block. Version 8 makes
    /// bibliography recognition independent of seeing its heading in the same
    /// request chunk. Version 9 adds validated forward relocation of substantive
    /// boxes that physical PDF order placed inside a main-text paragraph.
    /// Version 10 adds a focused Box-heading pass so long consecutive boxes do
    /// not hide the grammatical continuation from a broad cleanup request.
    /// Version 11 normalizes the merged broad/focused plan against the complete
    /// document before reconstruction. Version 12 prefers the complete wider
    /// Box range when broad and focused plans share the same starting heading.
    /// Version 13 uses semantic start/resume/paragraph boundaries and expands
    /// complete Box intervals deterministically in the app. Versions 14–17
    /// tightened the focused boundary contract and structural Box-heading
    /// recognition against live extracted papers. Version 18 keeps the exact
    /// Box move when deletion removes noise inside its range and fails closed
    /// if an interrupted paragraph's required move disappears during final
    /// normalization. Version 19 cleans a paper's complete PDF extraction
    /// rather than a stored copy an older build capped at 50,000 characters,
    /// keeps back-matter statements and every section printed after the
    /// references (STAR★Methods, Methods), and restores any whole-block
    /// deletion that a second, deletions-only model read calls source content.
    static let deterministicVersion = 1
    static let currentVersion = 19

    let cleanerVersion: Int
    let rawSHA256: String
    let cleanSHA256: String?
    let preparedAt: Date?
}

/// Audit and staleness proof for the deletion-only podcast ad cleanup.
///
/// The input is preserved separately from canonical `source_content`, so a
/// later contract can be rerun without re-downloading Apple TTML or replacing
/// the learner's last readable transcript while model work is pending.
struct PodcastTranscriptCleanupMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let cleanerVersion: Int
    let inputSHA256: String
    let cleanSHA256: String
    let preparedAt: Date?
}

struct PodcastTranscriptCleanupCandidate: Sendable {
    let sourceID: String
    let title: String
    let podcastName: String
    let input: String
    let inputSHA256: String
    /// The input is a transcript saved raw, laid out but never formatted, and
    /// is owed the whole formatting pass (speaker names, paragraphs, ad reads)
    /// rather than the ad pass alone (schema 172).
    var formatsTranscript = false
}

/// Who asked for a podcast transcript's formatting pass. A transcript is saved
/// readable first and waits for the pass in `podcast_transcript_cleanup_queue`
/// (schema 172).
enum PodcastTranscriptFormattingRequest: Sendable, Equatable {
    /// Hydration found the transcript on its own: formatted in turn, and not
    /// while the episode is hidden.
    case automatic
    /// The learner asked for this episode: formatted ahead of the rest, hidden
    /// or not.
    case learnerAsked
}

struct PreparedPodcastTranscriptCleanup: Sendable {
    let input: String
    let clean: String
    let metadata: PodcastTranscriptCleanupMetadata
}

struct StudioArticle: Identifiable, Codable, Equatable {
    static let unknownPaperAuthor = "Unknown authors"
    static let unknownPaperJournal = "Unknown venue"
    static let unknownPaperYear = "Unknown year"

    /// Whether two source lists would render the same rows.
    ///
    /// Loaded text is not presentation. Hydrating a transcript for a chat send,
    /// or a reader open, must not rebuild every window's filtered sidebar and
    /// re-diff its rows: that rebuild stalled the main thread for seconds per
    /// send on a 4,000-source library. Everything else — state, title, word
    /// count, order, membership — counts as a visible change.
    static func presentationEquals(_ lhs: [StudioArticle], _ rhs: [StudioArticle]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where !left.hasSamePresentation(as: right) {
            return false
        }
        return true
    }

    /// Equality that ignores the text payloads: canonical content and the raw
    /// ingestion inputs carried for persistence. Copying `self` shares those
    /// strings rather than duplicating them.
    func hasSamePresentation(as other: StudioArticle) -> Bool {
        var comparable = self
        comparable.content = other.content
        comparable.rawPaperContentForPersistence = other.rawPaperContentForPersistence
        comparable.rawArticleContentForPersistence = other.rawArticleContentForPersistence
        comparable.podcastTranscriptInputForPersistence = other.podcastTranscriptInputForPersistence
        return comparable == other
    }

    let id: String
    var url: String {
        didSet { if oldValue != url { edits.note(.url) } }
    }
    var title: String {
        didSet {
            let decoded = title.decodingTitleMarkup()
            if decoded != title {
                title = decoded
            }
            if oldValue != title { edits.note(.title) }
        }
    }
    var domain: String {
        didSet { if oldValue != domain { edits.note(.domain) } }
    }
    /// The team whose library this source belongs to, or nil for the learner's
    /// own library. A team copy is a separate row with a team-scoped id; the
    /// column is what routes it to the team's CloudKit zone and keeps it out of
    /// My Library. Travels in the payload for the web client; on the Mac the
    /// zone a record arrives from is the authority.
    var teamID: String? {
        didSet { if oldValue != teamID { edits.note(.teamID) } }
    }
    var dateAdded: Date {
        didSet { if oldValue != dateAdded { edits.note(.dateAdded) } }
    }
    var content: String?
    var wordCount: Int? {
        didSet { if oldValue != wordCount { edits.note(.wordCount) } }
    }
    var state: StudioArticleState {
        didSet { if oldValue != state { edits.note(.state) } }
    }
    var errorMessage: String? {
        didSet { if oldValue != errorMessage { edits.note(.errorMessage) } }
    }
    /// Typed view over `errorMessage` for the sentinel status flags (paywall,
    /// podcast confirmation, transcript needed). Non-nil only when `errorMessage`
    /// exactly matches a known flag; genuine free-text errors read as nil. Setting
    /// it writes the flag's raw string; setting nil clears `errorMessage`.
    var statusFlag: SourceStatusFlag? {
        get { errorMessage.flatMap(SourceStatusFlag.init(rawValue:)) }
        set { errorMessage = newValue?.rawValue }
    }
    var sourceType: StudioSourceType {
        didSet { if oldValue != sourceType { edits.note(.sourceType) } }
    }
    /// Artwork thumbnail URL (e.g. podcast cover art from Apple Podcasts)
    var artworkURL: String? {
        didSet { if oldValue != artworkURL { edits.note(.artworkURL) } }
    }
    /// Which browser or service this article was discovered from
    var discoveryOrigin: DiscoveryOrigin? {
        didSet { if oldValue != discoveryOrigin { edits.note(.discoveryOrigin) } }
    }
    /// Grouping key for hierarchical display (e.g. book name, course name)
    var parentGroup: String? {
        didSet { if oldValue != parentGroup { edits.note(.parentGroup) } }
    }
    /// Local file path for managed documents (articles, books, courses, papers)
    var localFilePath: String? {
        didSet { if oldValue != localFilePath { edits.note(.localFilePath) } }
    }
    /// For a chapter of a PDF book: the pages of the book's file (`localFilePath`)
    /// that are the chapter, from `book_sources.page_start` and `page_count`.
    /// A PDF book is kept as one file, and everything else about a chapter
    /// (highlights, reading position, figures) still counts pages from the
    /// chapter's first page; only code that opens the file adds the start
    /// (`SourcePDFPages`). Nil when the file is the chapter: an EPUB chapter,
    /// or a PDF book still split into chapter files.
    var bookPages: Range<Int>? {
        didSet { if oldValue != bookPages { edits.note(.bookPages) } }
    }
    /// Fallback web page URL for podcast episodes whose TTML isn't cached locally
    var podcastWebPageURL: String? {
        didSet { if oldValue != podcastWebPageURL { edits.note(.podcastWebPageURL) } }
    }
    /// Author name (user-editable, e.g. for books). Always a name or a list
    /// of names: markup, a web address or a "name" longer than any name is
    /// another field misread as one, and is turned away here as it arrives
    /// (`SourceAuthor`), so no reader's mistake reaches a row or the store.
    var author: String? {
        didSet {
            if let author, !SourceAuthor.isPlausible(author) {
                self.author = nil
            }
            if oldValue != author { edits.note(.author) }
        }
    }
    /// Journal name (e.g. "Nature", "Cell") — populated from Crossref for papers
    var journal: String? {
        didSet { if oldValue != journal { edits.note(.journal) } }
    }
    /// Publication year (e.g. "2024") — populated from Crossref for papers
    var publishedYear: String? {
        didSet { if oldValue != publishedYear { edits.note(.publishedYear) } }
    }
    /// Whether this source is active or archived
    var status: SourceStatus = .active {
        didSet { if oldValue != status { edits.note(.status) } }
    }
    /// When this source was archived (nil if still active)
    var archivedAt: Date? {
        didSet { if oldValue != archivedAt { edits.note(.archivedAt) } }
    }
    /// Canonical normalized URL for deduplication
    var normalizedURL: String? {
        didSet { if oldValue != normalizedURL { edits.note(.normalizedURL) } }
    }
    /// Public URL suitable for shared decks and exports.
    var publicURL: String? {
        didSet { if oldValue != publicURL { edits.note(.publicURL) } }
    }
    /// Podcast match found via iTunes Search API (when YouTube transcript is unavailable)
    var podcastMatch: PodcastMatchInfo?
    /// Temporary store track ID for a podcast match awaiting user confirmation (not persisted long-term)
    var podcastMatchTrackId: Int64?
    /// LLM-suggested sort index within a course group (nil = use default title sort)
    var courseSortIndex: Int? {
        didSet { if oldValue != courseSortIndex { edits.note(.courseSortIndex) } }
    }
    /// Groups a lecture video with its matched PDF notes within a course.
    /// Matched items share the same lectureGroupId (typically the lecture's article id).
    var lectureGroupId: String? {
        didSet { if oldValue != lectureGroupId { edits.note(.lectureGroupId) } }
    }
    /// Whether this source is behind a paywall (persisted in SQLite).
    var isPaywalled: Bool = false {
        didSet { if oldValue != isPaywalled { edits.note(.isPaywalled) } }
    }
    /// What the AI browser saw that makes it think this paper is paywalled,
    /// when the explicit purchase or subscription text that lets it mark the
    /// paper paywalled on its own was not on the page. While this is set the
    /// paper's attention row offers a one-click Mark as Paywalled with the
    /// reason behind it; marking, clearing the paywall status, or attaching a
    /// PDF retires it. Persisted in `papers.paywall_suspicion`.
    var paywallSuspicion: String? {
        didSet { if oldValue != paywallSuspicion { edits.note(.paywallSuspicion) } }
    }
    /// Whether this source is hidden from Studio source lists.
    var isHidden: Bool = false {
        didSet { if oldValue != isHidden { edits.note(.isHidden) } }
    }
    /// Digital Object Identifier for papers — canonical deduplication key
    var doi: String? {
        didSet { if oldValue != doi { edits.note(.doi) } }
    }
    /// For a preprint that has since appeared in a peer-reviewed venue: the DOI
    /// of that published version, resolved from bioRxiv/medRxiv, Crossref, or
    /// OpenAlex. It makes the preprint and the journal record one identity for
    /// deduplication even though neither `doi` nor the PDF text can match.
    /// Excluded from `CodingKeys` for the same reason as `paperContentSHA256`:
    /// it lives in `papers`, and CloudKit already carries it in the source's
    /// portable identity payload rather than in the article body.
    var publishedDOI: String? {
        didSet { if oldValue != publishedDOI { edits.note(.publishedDOI) } }
    }
    /// Proof that this paper completed the mandatory metadata extraction gate.
    /// The setter is intentionally private: ingestion code must use
    /// `completePaperMetadataExtractionAfterLLM()` after a real model response.
    private(set) var paperIngestionMethod: PaperIngestionMethod? {
        didSet { if oldValue != paperIngestionMethod { edits.note(.paperIngestionMethod) } }
    }
    /// SHA-256 of the raw text extracted from this paper's PDF, populated only
    /// after the current cleanup contract has produced canonical text. This is
    /// derived from `paper_content_preparations`, whose metadata already syncs
    /// with the source, rather than a second persisted identity field. It stays
    /// out of `CodingKeys`: CloudKit carries the preparation metadata in its
    /// existing dedicated payload.
    var paperContentSHA256: String?
    /// Storage-derived proof that the current canonical text has a durable
    /// Listen derivative. Excluded from Codable because CloudKit carries that
    /// derivative and its metadata as a separate source asset.
    var paperListenableContentReady = false
    /// Zero-based page index to reopen when returning to a PDF-backed reader.
    var readingPositionPage: Int? {
        didSet { if oldValue != readingPositionPage { edits.note(.readingPositionPage) } }
    }
    /// Structured reader locator, such as an EPUB chapter plus scroll fraction.
    var readingPositionLocator: String? {
        didSet { if oldValue != readingPositionLocator { edits.note(.readingPositionLocator) } }
    }
    /// When the learner marked this web article as read (nil = unread).
    var readAt: Date? {
        didSet { if oldValue != readAt { edits.note(.readAt) } }
    }
    /// When this video was added to the YouTube Liked feed. Only populated for
    /// videos seen by the Liked-feed sync — nil for Safari-discovered rows and
    /// for liked rows that predate the first sync carrying this field.
    var likedAt: Date? {
        didSet { if oldValue != likedAt { edits.note(.likedAt) } }
    }
    /// When the video itself was published to YouTube, as distinct from when it
    /// was liked or added to ForeverLM. Same nil caveats as `likedAt`.
    var videoPublishedAt: Date? {
        didSet { if oldValue != videoPublishedAt { edits.note(.videoPublishedAt) } }
    }
    /// Which user-built plugin added this source (`discoveryOrigin ==
    /// .plugin`). Derived from the OAuth client's registered name at ingest
    /// time; ingest-scoped clients may only update sources carrying their own
    /// label, and bulk removal is keyed on it.
    var connectorLabel: String? {
        didSet { if oldValue != connectorLabel { edits.note(.connectorLabel) } }
    }
    /// The fields this copy's holder changed since it was read from the store
    /// (`KnowledgeStore.readSourceRow`), so that a save writes only those (`written(over:)`). Not
    /// tracking for a copy never read from the store. Not encoded, and ignored by equality.
    var edits = SourceEdits()

    /// In-memory handoff from ingestion/CloudKit to KnowledgeStore. The raw
    /// extraction is deliberately excluded from Codable: CloudKit carries it in
    /// a separate asset so normal source payloads and downstream consumers only
    /// ever see the cleaned `content` value.
    var rawPaperContentForPersistence: String?
    var paperContentPreparationForPersistence: PaperContentPreparationMetadata?
    var rawArticleContentForPersistence: String?
    var articleContentPreparationForPersistence: PaperContentPreparationMetadata?
    var podcastTranscriptInputForPersistence: String?
    var podcastTranscriptCleanupForPersistence: PodcastTranscriptCleanupMetadata?

    var isRead: Bool { readAt != nil }

    /// Whether the reader has a saved page or scroll locator to restore. A
    /// video marked not watched keeps a locator for its epoch
    /// (`VideoWatchProgress.isUnwatchedMarker`), and that is not one.
    var hasSavedReadingPosition: Bool {
        guard readingPositionPage == nil else { return true }
        guard let locator = readingPositionLocator, !locator.isEmpty else { return false }
        return !VideoWatchProgress.isUnwatchedMarker(locator)
    }

    /// Whether the Sources sidebar and the Reader offer Mark as Watched and
    /// Mark as Not Watched: a video, or a course lecture that is a YouTube
    /// video (some playlist lectures are stored as `course` sources and still
    /// record watch progress through the YouTube reader).
    var offersWatchedMarks: Bool {
        sourceType == .video || (sourceType == .course && isYouTubeURL)
    }

    /// Web articles from Reading List or pasted URLs — and every paper, whose text
    /// is usually a local PDF — can be marked read in ForeverLM.
    var supportsReadTracking: Bool {
        supportsReadTracking(web: isWebArticle)
    }

    /// `supportsReadTracking` without the stat — see `cachedResolvedLocalPath`. Both
    /// the sidebar row's read badge and every reader's "Mark as Read" menu item gate
    /// on this while rendering, and `isWebArticle` resolves a local path to get there.
    var cachedSupportsReadTracking: Bool {
        supportsReadTracking(web: cachedIsWebArticle)
    }

    private func supportsReadTracking(web: Bool) -> Bool {
        ForeverLMCore.supportsReadTracking(
            sourceType: sourceType.rawValue,
            isWebArticle: web
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, domain, dateAdded, content, wordCount, state
        case errorMessage, sourceType
        case artworkURL, discoveryOrigin, parentGroup, localFilePath, podcastWebPageURL
        case author, journal, publishedYear, podcastMatch, podcastMatchTrackId
        case courseSortIndex, lectureGroupId
        case status, archivedAt, normalizedURL, publicURL
        case isPaywalled, isHidden, doi, readingPositionPage, readingPositionLocator, readAt
        case likedAt, videoPublishedAt, connectorLabel
        case paperIngestionMethod
        case paywallSuspicion
        case teamID
        case bookPages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title).decodingTitleMarkup()
        domain = try c.decode(String.self, forKey: .domain)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount)
        state = try c.decode(StudioArticleState.self, forKey: .state)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        sourceType = try c.decode(StudioSourceType.self, forKey: .sourceType)
        artworkURL = try c.decodeIfPresent(String.self, forKey: .artworkURL)
        discoveryOrigin = try c.decodeIfPresent(DiscoveryOrigin.self, forKey: .discoveryOrigin)
        parentGroup = try c.decodeIfPresent(String.self, forKey: .parentGroup)
        localFilePath = try c.decodeIfPresent(String.self, forKey: .localFilePath)
        podcastWebPageURL = try c.decodeIfPresent(String.self, forKey: .podcastWebPageURL)
        author = SourceAuthor.storable(try c.decodeIfPresent(String.self, forKey: .author))
        journal = try c.decodeIfPresent(String.self, forKey: .journal)
        publishedYear = try c.decodeIfPresent(String.self, forKey: .publishedYear)
        podcastMatch = try c.decodeIfPresent(PodcastMatchInfo.self, forKey: .podcastMatch)
        podcastMatchTrackId = try c.decodeIfPresent(Int64.self, forKey: .podcastMatchTrackId)
        courseSortIndex = try c.decodeIfPresent(Int.self, forKey: .courseSortIndex)
        lectureGroupId = try c.decodeIfPresent(String.self, forKey: .lectureGroupId)
        status = (try? c.decode(SourceStatus.self, forKey: .status)) ?? .active
        archivedAt = try? c.decode(Date.self, forKey: .archivedAt)
        normalizedURL = try? c.decode(String.self, forKey: .normalizedURL)
        publicURL = try? c.decode(String.self, forKey: .publicURL)
        isPaywalled = (try? c.decode(Bool.self, forKey: .isPaywalled)) ?? false
        isHidden = (try? c.decode(Bool.self, forKey: .isHidden)) ?? false
        doi = try c.decodeIfPresent(String.self, forKey: .doi)
        // Unknown future attestations fail closed to nil so this build can
        // demote/reprocess the paper instead of rejecting the whole sync payload.
        paperIngestionMethod = try? c.decodeIfPresent(PaperIngestionMethod.self, forKey: .paperIngestionMethod)
        paywallSuspicion = try? c.decodeIfPresent(String.self, forKey: .paywallSuspicion)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        readingPositionPage = try c.decodeIfPresent(Int.self, forKey: .readingPositionPage)
        readingPositionLocator = try c.decodeIfPresent(String.self, forKey: .readingPositionLocator)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        likedAt = try c.decodeIfPresent(Date.self, forKey: .likedAt)
        videoPublishedAt = try c.decodeIfPresent(Date.self, forKey: .videoPublishedAt)
        connectorLabel = try c.decodeIfPresent(String.self, forKey: .connectorLabel)
        bookPages = try c.decodeIfPresent(Range<Int>.self, forKey: .bookPages)
    }

    private static func normalizedMetadataField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var normalizedAuthor: String? { Self.normalizedMetadataField(author) }

    static func canonicalPaperAuthor(_ value: String?) -> String? {
        normalizedMetadataField(value)
    }

    /// Short author display: "First Author et al." for 3+, "A & B" for 2, full name for 1.
    var shortAuthorDisplay: String? { Self.shortAuthorDisplay(author) }

    /// The same rule over a loose author string, for papers that have no `StudioArticle` yet —
    /// a cited-paper candidate read off a slide should read the way it will once imported.
    static func shortAuthorDisplay(_ value: String?) -> String? {
        guard let raw = canonicalPaperAuthor(value), raw != unknownPaperAuthor else { return nil }
        // Paper metadata stores its author list with a semicolon delimiter. Treat that
        // delimiter as structure; do not attempt to parse names themselves.
        var seen = Set<String>()
        let authors = raw
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
        switch authors.count {
        case 0:
            return nil
        case 1:
            return authors[0]
        case 2:
            return "\(authors[0]) & \(authors[1])"
        default:
            return "\(authors[0]) et al."
        }
    }

    var displayAuthor: String? {
        guard sourceType == .paper else { return normalizedAuthor }
        return shortAuthorDisplay
    }

    /// `domain` as a row may print it: nil when empty or a file path. A source
    /// made with an address that has no host gets that address as its domain
    /// (`init(url:…)`: `URL(string: url)?.host ?? url`); for a book chapter it
    /// is the file's place in the library ("Books/<book id>/Chapters/…"), a
    /// relative path the absolute-path check below does not catch.
    var displayDomain: String? {
        if domain == url, URL(string: url)?.host == nil { return nil }
        return Self.displayDomain(domain)
    }

    /// Book chapters imported before the private container was retired keep
    /// their chapter folder's absolute path in `domain`, and
    /// `rewriteBookFolderReferences` moves it with the folder, so the column
    /// stays. A path is where the file lives, never a byline.
    static func displayDomain(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~/"),
              !trimmed.hasPrefix("file:") else { return nil }
        return trimmed
    }

    var normalizedJournal: String? { Self.normalizedMetadataField(journal) }
    var normalizedPublishedYear: String? { Self.normalizedMetadataField(publishedYear) }

    var paperAuthorNeedsEnrichment: Bool {
        guard sourceType == .paper else { return false }
        guard let value = normalizedAuthor else { return true }
        return value == Self.unknownPaperAuthor
    }

    var paperJournalNeedsEnrichment: Bool {
        guard sourceType == .paper else { return false }
        guard let value = normalizedJournal else { return true }
        return value == Self.unknownPaperJournal
    }

    var paperYearNeedsEnrichment: Bool {
        guard sourceType == .paper else { return false }
        guard let value = normalizedPublishedYear else { return true }
        return value == Self.unknownPaperYear
    }

    /// What the metadata stage actually requires: the extractor came back with
    /// at least one bibliographic field. Requiring all three failed the
    /// documents that simply do not have them — a lab preprint with no venue,
    /// an unsigned editorial, a thesis whose front matter prints no year — and
    /// left readable papers sitting in the attention list behind an error no
    /// retry could clear. A missing field is a blank to fill in later, not a
    /// failed ingestion; an all-blank result still is one, and the extractor
    /// itself already rejects a wholly empty model response.
    var hasAttestablePaperMetadata: Bool {
        guard sourceType == .paper else { return true }
        return !paperAuthorNeedsEnrichment
            || !paperJournalNeedsEnrichment
            || !paperYearNeedsEnrichment
    }

    /// True only after the current Source Content Cleanup contract produced
    /// canonical text. Non-empty content alone is insufficient because older
    /// payloads may contain raw extraction text that is not listen-ready.
    var hasCompletedPaperContentCleanup: Bool {
        guard sourceType == .paper else { return true }
        return paperContentSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    /// A paper whose text is final: metadata attested and the current
    /// clean-up committed. Listen, Explain and text-to-speech gate on this. The
    /// Listen derivative is prepared when the learner presses Listen, or at
    /// once for the kinds automatic audio covers (2026-09-24), so its absence
    /// is not a failed ingestion.
    var isPaperReadyForListenPreparation: Bool {
        guard sourceType == .paper else { return true }
        return state == .ready
            && hasPaperIngestionAttestation
            && hasCompletedPaperContentCleanup
    }

    /// Ingestion is over: metadata is attested, and the text is either clean
    /// or handed to the durable cleanup queue, which moves the row from
    /// `.queued` to `.ready` when the clean text lands (3813fb3). Callers that
    /// ask "did this paper finish?" use this, not
    /// `isPaperReadyForListenPreparation`: a queued cleanup is not a stall, and
    /// recording it as one set the row to `.error`, which the queue's drain
    /// never picks up, so the cleanup could never run.
    var hasFinishedPaperIngestion: Bool {
        guard sourceType == .paper else { return true }
        if isPaperReadyForListenPreparation { return true }
        return state == .queued
            && errorMessage == nil
            && hasPaperIngestionAttestation
    }

    /// Metadata, canonical cleanup, and the durable Listen derivative are all
    /// ready. Since Listen became lazy (2026-09-24) nothing gates a control on
    /// this: a paper without a derivative yet is still fully readable and
    /// listenable, and `isPaperReadyForListenPreparation` is the gate.
    var hasSuccessfulPaperIngestion: Bool {
        guard sourceType == .paper else { return true }
        return isPaperReadyForListenPreparation && paperListenableContentReady
    }

    /// Whether Listen narration applies to this source at all. Preparation
    /// follows the source's canonical text, not its bibliography or its current
    /// lifecycle state: an unsigned editorial fails the metadata gate and still
    /// has a full document to narrate, and a paper cycling back through `queued`
    /// for a metadata retry has not lost the text it was queued against.
    /// Archiving it, or changing it into a type that carries real audio, is what
    /// retires the work.
    var supportsListenableContentPreparation: Bool {
        (sourceType == .article || sourceType == .paper) && status == .active
    }

    /// Gives user-actionable, non-terminal paper states a concise UI explanation.
    /// Versioned cleanup and Listen backfills can cover the entire historical
    /// library after an update; those stay silent and never make healthy papers
    /// appear broken while the durable queues drain in the background.
    /// The caller supplies cached PDF availability so this stays safe in SwiftUI
    /// render paths and never stats an iCloud-backed file on the main actor.
    func paperAttentionReason(hasUsablePDF: Bool) -> PaperAttentionReason? {
        guard sourceType == .paper,
              !hasPaywallMarker,
              state != .error,
              state != .fetching else { return nil }
        guard hasUsablePDF else { return .pdfNeeded }
        guard hasPaperIngestionAttestation else { return .metadataIncomplete }
        return nil
    }

    var hasPaperIngestionAttestation: Bool {
        sourceType == .paper
            && hasAttestablePaperMetadata
            && paperIngestionMethod != nil
    }

    var requiresPaperMetadataAI: Bool {
        sourceType == .paper && paperIngestionMethod == nil
    }

    mutating func prepareForPaperMetadataExtraction() {
        guard sourceType == .paper else { return }
        paperIngestionMethod = nil
        state = .queued
        errorMessage = nil
    }

    /// Leave the paper pipeline for good because the page turned out not to be
    /// a paper: a news story, editorial, or comment piece with no PDF to find.
    /// Clears the paper-only bookkeeping (paywall marker, bibliographic fields,
    /// ingestion attestation) and re-queues the source so the article pipeline
    /// fetches and prepares it like any other web page. Before this existed,
    /// such a page stayed in "Papers that need attention" until a browser-agent
    /// run happened to call it paywalled, which hid it without fixing anything.
    mutating func convertPaperToArticle() {
        guard sourceType == .paper else { return }
        sourceType = .article
        isPaywalled = false
        paywallSuspicion = nil
        paperIngestionMethod = nil
        journal = nil
        publishedYear = nil
        doi = nil
        publishedDOI = nil
        content = nil
        wordCount = nil
        state = .queued
        errorMessage = nil
    }

    /// Persist the successful model-owned metadata boundary before the separate
    /// content-cleanup stage starts. Cleanup can fail or be interrupted without
    /// invalidating metadata the model already returned.
    @discardableResult
    mutating func attestPaperMetadataExtractionAfterLLM() -> Bool {
        guard sourceType == .paper, hasAttestablePaperMetadata else { return false }
        paperIngestionMethod = .llm
        state = .queued
        errorMessage = nil
        return true
    }

    /// Call only after the Paper Metadata task returned successfully and its
    /// result has been applied. Requiring one resolved bibliographic field here
    /// prevents a technically successful but empty model response from attesting
    /// this stage, without failing a document that prints no venue or no year.
    @discardableResult
    mutating func completePaperMetadataExtractionAfterLLM() -> Bool {
        guard attestPaperMetadataExtractionAfterLLM() else { return false }
        state = .ready
        return true
    }

    /// Content cleanup is downstream from metadata extraction. Preserve the
    /// metadata attestation so Retry resumes cleanup instead of charging for a
    /// second metadata call and so the UI reports the stage that actually failed.
    mutating func failPaperContentCleanup(_ message: String) {
        guard sourceType == .paper else { return }
        state = .error
        errorMessage = message
    }

    /// Call after a manual metadata edit filled in what the model could not.
    /// The learner is the authority here, so this attests the metadata stage
    /// and clears the extraction failure; the caller still owns Source Content
    /// Cleanup, which is why this never fabricates a cleanup result. A learner
    /// who leaves a field blank because the paper has no such field is answering
    /// the question, so this asks for no more than the extractor does.
    @discardableResult
    mutating func completePaperMetadataFromManualEntry() -> Bool {
        guard sourceType == .paper, hasAttestablePaperMetadata else { return false }
        // An extraction the pipeline already attested owns its own record, and a
        // failure in a later stage is not this stage's to clear.
        guard paperIngestionMethod == nil || paperIngestionMethod == .manual,
              !isPaperContentCleanupFailure else { return true }
        paperIngestionMethod = .manual
        // The metadata failure is resolved either way, so it must not linger on
        // the row. Cleanup that has not run yet is queued work, not an error.
        errorMessage = nil
        state = hasCompletedPaperContentCleanup ? .ready : .queued
        return true
    }

    /// Names the fields the extractor actually left missing. "did not return
    /// author, venue, and year" reads as a total failure even when only the
    /// year was absent, and it hides how small the manual fix is.
    var missingRequiredPaperMetadataFields: [String] {
        guard sourceType == .paper else { return [] }
        var missing: [String] = []
        if paperAuthorNeedsEnrichment { missing.append("author") }
        if paperJournalNeedsEnrichment { missing.append("venue") }
        if paperYearNeedsEnrichment { missing.append("year") }
        return missing
    }

    /// Recognizes an incomplete-extraction failure, including rows persisted by
    /// the build that phrased it "did not return author, venue, and year".
    static let paperMetadataIncompleteMarker = "Paper Metadata AI could not find the"
    static let legacyPaperMetadataIncompleteMarker =
        "Paper Metadata AI did not return author, venue, and year"

    static func paperMetadataIncompleteMessage(missing: [String]) -> String {
        let fields = missing.isEmpty ? ["author", "venue", "year"] : missing
        let list: String
        switch fields.count {
        case 1: list = fields[0]
        case 2: list = "\(fields[0]) and \(fields[1])"
        default: list = "\(fields.dropLast().joined(separator: ", ")), and \(fields[fields.count - 1])"
        }
        let noun = fields.count == 1 ? "it" : "them"
        return "Paper ingestion failed: \(paperMetadataIncompleteMarker) \(list). "
            + "Edit the details to fill \(noun) in."
    }

    mutating func failPaperIngestionMetadata(_ message: String) {
        guard sourceType == .paper else { return }
        paperIngestionMethod = nil
        state = .error
        errorMessage = message
    }

    /// Recognizes a persisted incomplete-metadata failure, whichever build's
    /// wording wrote it.
    var isPaperMetadataIncompleteFailure: Bool {
        guard sourceType == .paper, state == .error, let errorMessage else { return false }
        return errorMessage.contains(Self.paperMetadataIncompleteMarker)
            || errorMessage.contains(Self.legacyPaperMetadataIncompleteMarker)
    }

    /// A paper an earlier build failed because the extractor left one of the
    /// bibliographic fields blank. That persisted failure is itself the record
    /// that the Paper Metadata call ran and its result was applied, so the stage
    /// is already attested under the current gate; re-running the model would
    /// spend tokens to be told the same "?" again. Rows without canonical text
    /// still have real work left and are deliberately excluded — they go back
    /// through extraction, which owns Source Content Cleanup.
    var canAttestPaperIngestionAfterBlankMetadataFailure: Bool {
        sourceType == .paper
            && paperIngestionMethod == nil
            && isPaperMetadataIncompleteFailure
            && hasAttestablePaperMetadata
            && hasCompletedPaperContentCleanup
    }

    @discardableResult
    mutating func attestPaperIngestionAfterBlankMetadataFailure() -> Bool {
        guard canAttestPaperIngestionAfterBlankMetadataFailure else { return false }
        paperIngestionMethod = .llm
        state = .ready
        errorMessage = nil
        return true
    }

    /// Source Content Cleanup is a named, code-owned pipeline step, so these
    /// markers can recognize both current failures and rows persisted by older
    /// builds without guessing at human-authored text.
    static let paperContentCleanupFailurePrefix = "Paper cleanup couldn't finish."
    static let legacyPaperContentCleanupFailureMarker =
        "Paper ingestion failed during Source Content Cleanup:"

    static func paperContentCleanupFailureMessage(_ detail: String) -> String {
        "\(paperContentCleanupFailurePrefix) This step removes headers, footers, references, and other noise so the paper sounds natural when you listen and later AI work uses fewer tokens. Error: \(detail)"
    }

    var isPaperContentCleanupFailure: Bool {
        guard sourceType == .paper, let errorMessage else { return false }
        return errorMessage.hasPrefix(Self.paperContentCleanupFailurePrefix)
            || errorMessage.contains(Self.legacyPaperContentCleanupFailureMarker)
    }

    /// Whether this source stopped mid-ingestion only because the ForeverLM AI
    /// account had nothing to pay with. Its extraction is already staged and
    /// nothing about it failed, so adding a key makes the remaining work
    /// possible again — the row is
    /// paused, not broken, and is the app's to resume rather than the learner's
    /// to retry.
    var isPausedByEmptyAIBalance: Bool {
        state == .error
            && PaperContentPreparationService.isEmptyBalanceFailure(errorMessage)
    }

    var paperContentCleanupFailureDetail: String? {
        guard isPaperContentCleanupFailure, let errorMessage else { return nil }
        if let range = errorMessage.range(of: "Error: ") {
            return String(errorMessage[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = errorMessage.range(of: Self.legacyPaperContentCleanupFailureMarker) {
            return String(errorMessage[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The complete persisted cause, minus the redundant badge prefix. This is
    /// intentionally suitable for inline display instead of being hidden only
    /// in tooltip/accessibility text.
    var paperIngestionFailureDetail: String? {
        guard sourceType == .paper,
              state == .error,
              !hasPaywallMarker,
              !isPaperContentCleanupFailure else { return nil }
        let trimmed = (errorMessage ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No failure details were recorded." }
        let visibleMessage: String
        if let debugLogRange = trimmed.range(of: "\n\n--- Debug Log ---") {
            visibleMessage = String(trimmed[..<debugLogRange.lowerBound])
        } else {
            visibleMessage = trimmed
        }
        let prefix = "Paper ingestion failed:"
        guard visibleMessage.hasPrefix(prefix) else { return visibleMessage }
        let detail = visibleMessage.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "No failure details were recorded." : detail
    }

    /// Resolve a code-owned failure into a useful next step. PDF availability
    /// is supplied from the cached projection so SwiftUI never stats an iCloud
    /// file while rendering the row.
    func paperIngestionRecoveryAction(hasUsablePDF: Bool) -> PaperIngestionRecoveryAction? {
        guard sourceType == .paper,
              state == .error,
              !hasPaywallMarker else { return nil }
        let message = errorMessage ?? ""
        if message.localizedCaseInsensitiveContains("is not configured") {
            return .configureAI
        }
        // The two configuration blockers that name themselves instead of
        // saying "not configured". Both are fixed in the same place the
        // Configure AI button opens, and neither is a retry.
        if message.contains(KeychainService.invalidModelRouteMessage)
            || message.contains(KeychainService.backgroundAIConsentMessage) {
            return .configureAI
        }
        // Every "add your OpenRouter key" wording: today's, and those from
        // while the key also needed a plan ("… and choose a plan", until
        // 2026-10-10), still stored on older rows. "AI balance is empty" and
        // "top up" are the wordings from before the prepaid balance was
        // retired.
        if message.localizedCaseInsensitiveContains("add your OpenRouter key")
            || (message.localizedCaseInsensitiveContains("your OpenRouter key")
                && message.localizedCaseInsensitiveContains("choose a plan"))
            || message.localizedCaseInsensitiveContains("AI balance is empty")
            || message.localizedCaseInsensitiveContains("top up") {
            return .addBalance
        }
        if !hasUsablePDF
            || message.localizedCaseInsensitiveContains("no readable PDF")
            || message.localizedCaseInsensitiveContains("no readable paper text") {
            return .attachPDF
        }
        // Some documents print none of the three fields, and another extraction
        // pass returns the same answer, so send the learner to the fields instead
        // of to a button that cannot succeed.
        if isPaperMetadataIncompleteFailure {
            return .editDetails
        }
        return .retry
    }

    mutating func installPreparedPaperContent(
        raw: String,
        clean: String,
        metadata: PaperContentPreparationMetadata,
        wordCount preparedWordCount: Int? = nil
    ) {
        guard sourceType == .paper else { return }
        rawPaperContentForPersistence = raw
        paperContentPreparationForPersistence = metadata
        paperContentSHA256 = metadata.cleanerVersion
            >= PaperContentPreparationMetadata.currentVersion
            && metadata.cleanSHA256 != nil
            ? metadata.rawSHA256
            : nil
        paperListenableContentReady = false
        content = clean
        wordCount = preparedWordCount
            ?? clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Install the canonical derivative for an article while carrying the
    /// original extraction to the storage actor for one atomic save. The
    /// transient raw value is intentionally excluded from Codable just like
    /// the paper equivalent above.
    mutating func installPreparedArticleContent(
        raw: String,
        clean: String,
        metadata: PaperContentPreparationMetadata,
        wordCount preparedWordCount: Int? = nil
    ) {
        guard sourceType == .article || sourceType == .manual || sourceType == .unclassified else { return }
        rawArticleContentForPersistence = raw
        articleContentPreparationForPersistence = metadata
        content = clean
        wordCount = preparedWordCount
            ?? clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    mutating func stageArticleContentCleanup(raw: String, rawSHA256: String? = nil) {
        guard sourceType == .article || sourceType == .manual || sourceType == .unclassified else { return }
        rawArticleContentForPersistence = raw
        articleContentPreparationForPersistence = PaperContentPreparationMetadata(
            cleanerVersion: 0,
            rawSHA256: rawSHA256 ?? PaperContentPreparationService.sha256(raw),
            cleanSHA256: nil,
            preparedAt: nil
        )
        content = nil
    }

    mutating func stagePaperContentCleanup(raw: String, rawSHA256: String? = nil) {
        guard sourceType == .paper else { return }
        rawPaperContentForPersistence = raw
        paperContentPreparationForPersistence = PaperContentPreparationMetadata(
            cleanerVersion: 0,
            rawSHA256: rawSHA256 ?? PaperContentPreparationService.sha256(raw),
            cleanSHA256: nil,
            preparedAt: nil
        )
        content = nil
    }

    /// The storage handoff may hold several megabytes. Library rows hydrate
    /// text lazily, so never retain it in published SwiftUI model state after
    /// the atomic save has consumed it.
    mutating func discardPersistedPaperContentFromMemory() {
        guard sourceType == .paper else { return }
        rawPaperContentForPersistence = nil
        paperContentPreparationForPersistence = nil
        content = nil
    }

    mutating func discardPersistedArticleContentHandoff() {
        rawArticleContentForPersistence = nil
        articleContentPreparationForPersistence = nil
    }

    /// Whole-record CloudKit writes from an older Mac can carry a newer reading
    /// position while omitting paper fields that Mac never understood. Required
    /// paper metadata and its attestation are monotonic: an absent/placeholder
    /// inbound value cannot erase a complete local extraction.
    @discardableResult
    /// A team's copy of a paper inherits the attestation the original earned:
    /// the metadata gate was passed once, for this document, and a copy under
    /// another id is the same document. Nothing else may copy an attestation
    /// across ids, which is why the setter stays private.
    mutating func adoptPaperIngestionAttestation(from original: StudioArticle) {
        guard sourceType == .paper, original.sourceType == .paper else { return }
        paperIngestionMethod = original.paperIngestionMethod
    }

    /// Record that a caller has already verified a local file at `rawPath`.
    ///
    /// Paper attachment first checks the destination PDF off-main, then publishes
    /// its path to the article. The same path may already be in the negative cache
    /// from the pre-attachment "needs PDF" check. Promote it synchronously before
    /// publishing the article so the sidebar, reader, and metadata pipeline all see
    /// the verified PDF in the same state change instead of waiting for the
    /// debounced cache revalidation pass.
    static func recordExistingLocalPath(_ rawPath: String) {
        let absolute = StorageService.absoluteSourcePath(rawPath)
        guard absolute.hasPrefix("/") else { return }
        resolvedPathCacheLock.lock()
        let wasMissing = negativeResolvedPathCache.remove(absolute) != nil
        let previous = resolvedPathCache.updateValue(absolute, forKey: absolute)
        if wasMissing || previous != absolute { resolvedPathCacheGenerationValue &+= 1 }
        resolvedPathCacheLock.unlock()
    }

    var paperMetadataCompletenessScore: Int {
        guard sourceType == .paper else { return 0 }
        var score = 0
        if !paperAuthorNeedsEnrichment { score += 1 }
        if !paperJournalNeedsEnrichment { score += 1 }
        if !paperYearNeedsEnrichment { score += 1 }
        return score
    }

    var paperMetadataDisplayParts: [String] {
        guard sourceType == .paper else { return [] }
        let journalDisplay: String = {
            if let j = normalizedJournal, j != Self.unknownPaperJournal { return j }
            let lower = url.lowercased()
            if lower.contains("biorxiv.org") { return "bioRxiv" }
            if lower.contains("medrxiv.org") { return "medRxiv" }
            if lower.contains("arxiv.org") { return "arXiv" }
            if lower.contains("nature.com") {
                // Extract specific Nature sub-journal from the title suffix
                // e.g. "Some paper title | Nature Methods" → "Nature Methods"
                if let pipeRange = title.range(of: " | Nature", options: .backwards),
                   title[pipeRange.upperBound...].allSatisfy({ $0.isLetter || $0.isWhitespace }) {
                    return String(title[title.index(pipeRange.lowerBound, offsetBy: 3)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                return "Nature"
            }
            if lower.contains("cell.com") { return "Cell" }
            if lower.contains("science.org") { return "Science" }
            if lower.contains("pnas.org") { return "PNAS" }
            if lower.contains("plos.org") { return "PLOS" }
            if lower.contains("elifesciences.org") { return "eLife" }
            if lower.contains("pubs.acs.org") { return "ACS" }
            if lower.contains("frontiersin.org") { return "Frontiers" }
            // Detect bioRxiv from DOI-based local filenames
            let filename = (url as NSString).lastPathComponent.lowercased()
            if filename.hasPrefix("10.1101_") || filename.hasPrefix("10.64898_") || filename.hasPrefix("biorxiv") { return "bioRxiv" }
            if filename.hasPrefix("medrxiv") { return "medRxiv" }
            return Self.unknownPaperJournal
        }()
        return [
            shortAuthorDisplay ?? Self.unknownPaperAuthor,
            journalDisplay,
            normalizedPublishedYear ?? Self.unknownPaperYear,
        ]
    }

    /// Whether this source has been marked as paywalled, including legacy error-state markers.
    var hasPaywallMarker: Bool {
        isPaywalled || statusFlag == .paywall
    }

    /// Whether this paper is behind a paywall and needs a user-attached PDF.
    var isPaywalledPaper: Bool {
        sourceType == .paper && hasPaywallMarker
    }

    /// The AI browser's reason for thinking this paper is paywalled, while the
    /// paper still sits in "Papers that need attention" wanting a PDF. Nil once
    /// a PDF is attached or the paper is marked paywalled, so the row's Mark as
    /// Paywalled button never outlives the question it answers. Takes cached PDF
    /// availability like `paperAttentionReason`, for the same render-path reason.
    func suggestedPaywallReason(hasUsablePDF: Bool) -> String? {
        guard paperAttentionReason(hasUsablePDF: hasUsablePDF) == .pdfNeeded,
              let reason = paywallSuspicion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }


    /// Whether this source is a local PDF file.
    /// Falls back to checking the URL itself — for books/courses/papers, the URL IS the local file path.
    var isPDF: Bool {
        if let path = localFilePath, path.lowercased().hasSuffix(".pdf") { return true }
        return url.lowercased().hasSuffix(".pdf") && url.hasPrefix("/")
    }

    /// Resolved local file path: uses explicit `localFilePath`, or the URL if it's a local path.
    /// Automatically resolves known directory renames (e.g. Knowledge → ForeverLM).
    var resolvedLocalPath: String? {
        // This accessor predates the cache-only UI API and still has many
        // call sites. Make the safety boundary intrinsic: an accidental use
        // from a SwiftUI/main-actor path can never issue an iCloud-backed stat.
        if Thread.isMainThread { return cachedResolvedLocalPath }
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/") {
                return Self.resolveLocalPath(absolutePath)
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/") {
            return Self.resolveLocalPath(absoluteURLPath)
        }
        return nil
    }

    /// Resolved local file path for PDFs specifically. Returns nil when the stored
    /// path points at a missing file so papers with stale `localFilePath` values
    /// still appear in the "needs PDF" flows instead of showing "File not found."
    var resolvedPDFPath: String? {
        if Thread.isMainThread { return cachedResolvedPDFPath }
        guard let path = existingResolvedLocalPath, path.lowercased().hasSuffix(".pdf") else { return nil }
        return path
    }

    /// Resolved local path only when the file exists on disk.
    private var existingResolvedLocalPath: String? {
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/"), let existing = Self.existingLocalPath(absolutePath) {
                return existing
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/"), let existing = Self.existingLocalPath(absoluteURLPath) {
            return existing
        }
        return nil
    }

    /// Whether this source is a local EPUB chapter file (extracted as .txt or .html during import).
    var isEPUBChapter: Bool {
        guard let path = resolvedLocalPath else { return false }
        return Self.pathLooksLikeEPUBChapter(path)
    }

    private static func pathLooksLikeEPUBChapter(_ path: String) -> Bool {
        let lower = path.lowercased()
        return (lower.hasSuffix(".txt") || lower.hasSuffix(".htm") || lower.hasSuffix(".html") || lower.hasSuffix(".xhtml"))
            && (path.contains("/Chapters/") || path.contains("_Chapters"))
    }

    /// Whether this source is an archived web article (HTML saved locally with images).
    var isArchivedArticle: Bool {
        guard let path = resolvedLocalPath else { return false }
        return Self.pathLooksLikeArchivedArticle(path)
    }

    private static func pathLooksLikeArchivedArticle(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let lower = normalized.lowercased()
        return lower.hasSuffix(".html")
            && (lower.hasPrefix("articles/") || lower.contains("/articles/"))
    }

    /// Whether this source is a local document (PDF or EPUB chapter) that doesn't need web fetching.
    var isLocalDocument: Bool {
        isPDF || isEPUBChapter || isArchivedArticle
    }

    /// `resolvedLocalPath` answered from the memoization tables alone, never
    /// touching the filesystem. SwiftUI evaluates a row's `.contextMenu` builder
    /// eagerly as part of the row body, so the sidebar menus resolve local paths
    /// on the main actor during render — and a cold `stat()` against an evicted
    /// iCloud file blocks for seconds, which is exactly the beachball captured in
    /// the UI stall samples. A path that has never been statted answers as itself,
    /// the same result `locateLocalPath` gives for a file it can't find; the
    /// debounced background pass in `scheduleResolvedPathRevalidation()` stats it
    /// for real and re-publishes, so the row re-renders against a cache hit.
    var cachedResolvedLocalPath: String? {
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/") {
                return Self.cachedResolveLocalPath(absolutePath)
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/") {
            return Self.cachedResolveLocalPath(absoluteURLPath)
        }
        return nil
    }

    /// `isEPUBChapter` without the stat — see `cachedResolvedLocalPath`.
    var cachedIsEPUBChapter: Bool {
        guard let path = cachedResolvedLocalPath else { return false }
        return Self.pathLooksLikeEPUBChapter(path)
    }

    /// `isArchivedArticle` without the stat — see `cachedResolvedLocalPath`.
    var cachedIsArchivedArticle: Bool {
        guard let path = cachedResolvedLocalPath else { return false }
        return Self.pathLooksLikeArchivedArticle(path)
    }

    /// Main-actor-safe counterpart to `isLocalDocument`. Classification only
    /// needs the stored path shape; whether the file is currently present is
    /// checked later by the off-main local-document loading path. Never use the
    /// filesystem-touching accessors merely to decide whether content is local.
    var cachedIsLocalDocument: Bool {
        isPDF || cachedIsEPUBChapter || cachedIsArchivedArticle
    }

    /// `resolvedPDFPath` without the stat — see `cachedResolvedLocalPath`. Existence
    /// is unknowable without touching disk, so a path that has not been resolved yet
    /// answers `nil` (no thumbnail) instead of blocking; the background warm
    /// re-publishes and the row picks it up.
    var cachedResolvedPDFPath: String? {
        guard let path = cachedExistingResolvedLocalPath,
              path.lowercased().hasSuffix(".pdf") else { return nil }
        return path
    }

    /// Cache-only availability used by render-time paper partitions and badges.
    /// An unvalidated recorded PDF is treated as present until the background
    /// path warmer proves it missing. That keeps a cold cache from both touching
    /// iCloud on the main actor and briefly flashing every recorded paper as
    /// missing during launch. Once warmed, a cached miss returns `false` and the
    /// normal missing-PDF UI appears on the next publication.
    var cachedHasUsablePDF: Bool {
        let rawPaths = [localFilePath, url]
        for rawPath in rawPaths.compactMap({ $0 }) {
            let absolutePath = StorageService.absoluteSourcePath(rawPath)
            guard absolutePath.hasPrefix("/"), absolutePath.lowercased().hasSuffix(".pdf") else {
                continue
            }
            switch Self.cachedLocalPathAvailability(absolutePath) {
            case .present:
                return true
            case .unknown:
                return true
            case .missing:
                continue
            }
        }
        return false
    }

    private var cachedExistingResolvedLocalPath: String? {
        if let path = localFilePath {
            let absolutePath = StorageService.absoluteSourcePath(path)
            if absolutePath.hasPrefix("/"), let existing = Self.cachedExistingLocalPath(absolutePath) {
                return existing
            }
        }
        let absoluteURLPath = StorageService.absoluteSourcePath(url)
        if absoluteURLPath.hasPrefix("/"), let existing = Self.cachedExistingLocalPath(absoluteURLPath) {
            return existing
        }
        return nil
    }

    /// In-memory memoization of local-path resolutions, both polarities. The
    /// existence checks below are synchronous filesystem stats (often against
    /// iCloud-backed, possibly-evicted files), and `resolvedLocalPath`/
    /// `resolvedPDFPath` are read from SwiftUI render paths — the sidebar filters
    /// and the always-evaluated Papers tab badge — once per source per render.
    /// Both hits AND misses are memoized for the whole session, so the main actor
    /// stats any unique path at most once ever (and `warmResolvedLocalPathCache`
    /// usually takes even that first stat off-main). Files that appear later
    /// (iCloud download, background fetch) are picked up by
    /// `revalidateMissingResolvedPaths()`, which re-stats misses off the main
    /// actor; files that are deleted are dropped via
    /// `invalidateResolvedPathCache(forRawPaths:)` by the deletion flows.
    private static let resolvedPathCacheLock = NSLock()
    nonisolated(unsafe) private static var resolvedPathCache: [String: String] = [:]
    /// Negative half of the resolved-path cache: paths that statted as missing.
    nonisolated(unsafe) private static var negativeResolvedPathCache: Set<String> = []
    nonisolated(unsafe) private static var resolvedPathCacheGenerationValue = 0

    /// Moves whenever the tables above change what they hold: a path statted
    /// for the first time, a miss promoted, entries dropped. The cache-only
    /// accessors (`cachedHasUsablePDF` above all) can answer differently
    /// afterwards with no source having changed, so a memo built from them
    /// across the library — the Papers lists' share of it
    /// (`StudioViewModel.paperLibraryIndex`) — keys on this beside the articles
    /// revision. Read under the lock; written only by the mutators below.
    static var resolvedPathCacheGeneration: Int {
        resolvedPathCacheLock.lock()
        defer { resolvedPathCacheLock.unlock() }
        return resolvedPathCacheGenerationValue
    }

    private enum CachedLocalPathAvailability {
        case present(String)
        case missing
        case unknown
    }

    /// Re-stat every cached miss, promoting entries whose file has since appeared
    /// (iCloud download, background fetch, attach). Returns true when at least one
    /// path was promoted so the caller can re-publish UI state. Stats the
    /// filesystem — never call on the main actor.
    static func revalidateMissingResolvedPaths() -> Bool {
        resolvedPathCacheLock.lock()
        let misses = Array(negativeResolvedPathCache)
        resolvedPathCacheLock.unlock()
        guard !misses.isEmpty else { return false }

        var promoted: [String: String] = [:]
        for path in misses {
            let (resolved, found) = locateLocalPath(path)
            if found { promoted[path] = resolved }
        }
        guard !promoted.isEmpty else { return false }

        resolvedPathCacheLock.lock()
        for (path, resolved) in promoted {
            negativeResolvedPathCache.remove(path)
            resolvedPathCache[path] = resolved
        }
        resolvedPathCacheGenerationValue &+= 1
        resolvedPathCacheLock.unlock()
        return true
    }

    /// Drop cached entries (hit and miss) for specific raw stored paths — e.g.
    /// after deleting a source's file — so only the affected sources re-stat on
    /// their next resolution instead of the whole library.
    static func invalidateResolvedPathCache(forRawPaths rawPaths: [String]) {
        let absolutes = rawPaths
            .map { StorageService.absoluteSourcePath($0) }
            .filter { $0.hasPrefix("/") }
        guard !absolutes.isEmpty else { return }
        resolvedPathCacheLock.lock()
        var dropped = false
        for path in absolutes {
            if resolvedPathCache.removeValue(forKey: path) != nil { dropped = true }
            if negativeResolvedPathCache.remove(path) != nil { dropped = true }
        }
        if dropped { resolvedPathCacheGenerationValue &+= 1 }
        resolvedPathCacheLock.unlock()
    }

    /// A legacy-root consolidation can relocate thousands of files while the
    /// app is open. Cached values store the previously located absolute path,
    /// so clear both polarities once the verified batch has changed anything;
    /// subsequent UI reads remain cache-only and the off-main warmer
    /// repopulates them against the canonical root.
    ///
    /// Sync clears it too, whenever another Mac's source files or text land.
    /// Until the warmer runs again, every local PDF answers "unknown", and the
    /// Reader shows a paper's stored text instead of its PDF. The warmer used to
    /// run only on a source change a row can see, and text arriving is not one,
    /// so a paper stayed text for the rest of the session. The clear now says so
    /// (`resolvedPathCacheDidClear`), and the view model warms the cache again.
    static func invalidateAllResolvedPathCaches() {
        resolvedPathCacheLock.lock()
        resolvedPathCache.removeAll(keepingCapacity: true)
        negativeResolvedPathCache.removeAll(keepingCapacity: true)
        resolvedPathCacheGenerationValue &+= 1
        resolvedPathCacheLock.unlock()
        NotificationCenter.default.post(name: .resolvedPathCacheDidClear, object: nil)
    }

    /// Resolve a stored absolute path only when the file exists, memoizing hits
    /// and (per revision) misses.
    private static func existingLocalPath(_ path: String) -> String? {
        resolvedPathCacheLock.lock()
        if let cached = resolvedPathCache[path] {
            resolvedPathCacheLock.unlock()
            return cached
        }
        if negativeResolvedPathCache.contains(path) {
            resolvedPathCacheLock.unlock()
            return nil
        }
        resolvedPathCacheLock.unlock()

        let (resolved, found) = locateLocalPath(path)
        guard found else {
            resolvedPathCacheLock.lock()
            if negativeResolvedPathCache.insert(path).inserted { resolvedPathCacheGenerationValue &+= 1 }
            resolvedPathCacheLock.unlock()
            return nil
        }
        resolvedPathCacheLock.lock()
        if resolvedPathCache.updateValue(resolved, forKey: path) != resolved { resolvedPathCacheGenerationValue &+= 1 }
        resolvedPathCacheLock.unlock()
        return resolved
    }

    /// Resolve a stored absolute path to where the file actually lives, memoizing
    /// both outcomes so the filesystem is touched at most once per unique path per
    /// session. A cached miss resolves to the input path unchanged (matching what
    /// `locateLocalPath` returns for a file it can't find) without touching disk.
    private static func resolveLocalPath(_ path: String) -> String {
        resolvedPathCacheLock.lock()
        if let cached = resolvedPathCache[path] {
            resolvedPathCacheLock.unlock()
            return cached
        }
        if negativeResolvedPathCache.contains(path) {
            resolvedPathCacheLock.unlock()
            return path
        }
        resolvedPathCacheLock.unlock()

        let (resolved, found) = locateLocalPath(path)
        resolvedPathCacheLock.lock()
        if found {
            if resolvedPathCache.updateValue(resolved, forKey: path) != resolved { resolvedPathCacheGenerationValue &+= 1 }
        } else if negativeResolvedPathCache.insert(path).inserted {
            resolvedPathCacheGenerationValue &+= 1
        }
        resolvedPathCacheLock.unlock()
        return resolved
    }

    /// Resolve a stored raw path (a source's `localFilePath` or `url`) to where the
    /// file actually lives, for callers that already run off the main actor. Stats
    /// the filesystem on a cache miss — never call this while rendering.
    static func resolvedLocalPath(forRawPath rawPath: String) -> String? {
        let absolute = StorageService.absoluteSourcePath(rawPath)
        guard absolute.hasPrefix("/") else { return nil }
        return resolveLocalPath(absolute)
    }

    /// Cached-only counterpart to `resolveLocalPath`: answers from the memoization
    /// tables and never stats, so it is safe to call while rendering. Falls back to
    /// the path unchanged when nothing is cached yet.
    private static func cachedResolveLocalPath(_ path: String) -> String {
        resolvedPathCacheLock.lock()
        defer { resolvedPathCacheLock.unlock() }
        return resolvedPathCache[path] ?? path
    }

    /// Cached-only counterpart to `existingLocalPath`: a path that has not been
    /// statted answers `nil`, same as one statted and found missing.
    private static func cachedExistingLocalPath(_ path: String) -> String? {
        guard case .present(let resolved) = cachedLocalPathAvailability(path) else { return nil }
        return resolved
    }

    /// Tri-state cache lookup that never touches the filesystem. Keeping
    /// `unknown` distinct from `missing` lets render-time counts conservatively
    /// trust a recorded PDF until the off-main warmer has checked it.
    private static func cachedLocalPathAvailability(_ path: String) -> CachedLocalPathAvailability {
        resolvedPathCacheLock.lock()
        defer { resolvedPathCacheLock.unlock() }
        if let resolved = resolvedPathCache[path] { return .present(resolved) }
        if negativeResolvedPathCache.contains(path) { return .missing }
        return .unknown
    }

    /// Warm the resolved-path cache off the main actor for a batch of stored raw
    /// paths (a source's `localFilePath` and `url`). Callers snapshot the raw
    /// strings on the main actor and run this on a background task, so the first
    /// Library render is a cache hit — for hits AND misses — instead of a
    /// synchronous stat storm. Returns true when at least one path was statted for
    /// the first time, so the caller can re-publish for rows that rendered against
    /// the cached-only accessors before the cache was populated.
    @discardableResult
    static func warmResolvedLocalPathCache(forRawPaths rawPaths: [String]) -> Bool {
        var statted = false
        for raw in rawPaths {
            let absolute = StorageService.absoluteSourcePath(raw)
            guard absolute.hasPrefix("/") else { continue }
            resolvedPathCacheLock.lock()
            let known = resolvedPathCache[absolute] != nil || negativeResolvedPathCache.contains(absolute)
            resolvedPathCacheLock.unlock()
            guard !known else { continue }
            _ = existingLocalPath(absolute)
            statted = true
        }
        return statted
    }

    /// Where this stored path's file actually lives, and whether one was found.
    ///
    /// Every relocation rule (re-homing across Macs, the simulator prefix, iCloud
    /// container swaps, the Knowledge→ForeverLM rename, conflict forks, iCloud
    /// placeholders) lives in `StorageService.sourceFileCandidatePaths`, which is
    /// the single list the whole app resolves against. This used to carry its own
    /// partial copy of those rules, and the rules it was missing are what let an
    /// iCloud conflict fork read as hundreds of papers losing their PDFs.
    private static func locateLocalPath(_ path: String) -> (path: String, found: Bool) {
        if let located = StorageService.locateSourceFile(path) { return (located, true) }
        return (path, false)  // return original if nothing found
    }

    /// Legacy marker for YouTube lectures that were imported from course folders.
    /// Course membership itself lives in course_lecture_items, not in discoveryOrigin.
    var isCourseLecture: Bool {
        discoveryOrigin == .localCourses && sourceType == .video
    }

    /// Whether this source is a YouTube URL (any source type).
    ///
    /// Every address ForeverLM plays as a YouTube video counts, a livestream's
    /// and an embed's included: the web views hand those to the Reader's
    /// player (`YouTubeContainment`), so a saved one shown as a web page would
    /// be handed straight back to itself.
    var isYouTubeURL: Bool {
        let lower = url.lowercased()
        if lower.contains("youtube.com/watch") || lower.contains("youtu.be/")
            || lower.contains("youtube.com/embed/") || lower.contains("youtube.com/shorts/") {
            return true
        }
        return lower.contains("youtu") && YouTubeURLMetadata.watchURL(for: url) != nil
    }

    /// YouTube video ID extracted from the URL.
    var youtubeVideoId: String? {
        Self.youtubeVideoId(from: url)
    }

    static func youtubeVideoId(from url: String) -> String? {
        ForeverLMCore.youtubeVideoID(from: url)
    }

    /// YouTube thumbnail URL derived from the video ID.
    var youtubeThumbnailURL: String? {
        Self.youtubeThumbnailURL(for: url)
    }

    static func youtubeThumbnailURL(for url: String) -> String? {
        ForeverLMCore.youtubeThumbnailURL(for: url)
    }

    /// Whether this source is a web URL that should be shown in the in-app WebView reader.
    /// Returns true for HTTP(S) URLs that aren't local files or podcasts with local transcripts.
    /// Papers without a local PDF also get the WebView reader so the user can browse + download.
    var isWebArticle: Bool {
        isWebArticle(archived: isArchivedArticle)
    }

    /// `isWebArticle` without the stat — see `cachedResolvedLocalPath`. The reader
    /// bodies branch on this once per render, so it must not resolve local paths.
    var cachedIsWebArticle: Bool {
        isWebArticle(archived: cachedIsArchivedArticle)
    }

    /// Whether an archived web article should render its live page rather than
    /// the document saved at fetch time.
    ///
    /// The archive is the offline snapshot, not the preferred rendering.
    /// `SourceService.readerHTML` keeps no stylesheet and only an allow list of
    /// tags, so the saved file is a reconstruction of the page rather than a
    /// copy of it — nav links lose their layout, hidden elements become visible,
    /// and the site's own typography is gone. Whenever the page is still
    /// reachable, the learner should read the page; the archive answers only
    /// when the live load fails, and keeps carrying the text everything
    /// downstream derives from.
    ///
    /// Two captures keep the saved document as their primary rendering, because
    /// for them it holds text the live URL will not produce: a paywalled
    /// article, and a local HTML import, whose identity is a file path rather
    /// than an HTTP URL. A source whose URL resolves to a publisher PDF keeps
    /// its existing reader too, which is the PDF itself.
    var cachedPrefersLiveWebPage: Bool {
        guard cachedIsArchivedArticle else { return false }
        guard !isPaywalled, !cachedHasRemotePDFURL else { return false }
        return cachedIsWebArticle
    }

    private func isWebArticle(archived: Bool) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
        if isPDF { return false }
        // Archived articles (HTML cached in /Articles/) still have an HTTP URL and should
        // render the live webpage; the cached HTML is only used as an offline fallback.
        if localFilePath != nil && !archived { return false }
        // Podcasts must never be shown in the web reader — only local transcripts are valid
        if sourceType == .podcast { return false }
        // Course lectures get a dedicated YouTube player view, not the generic web reader
        if isCourseLecture { return false }
        return true
    }

    /// Whether this paper has a resolvable direct PDF URL (arXiv, bioRxiv, Nature, etc.).
    var hasRemotePDFURL: Bool {
        hasRemotePDFURL(localPDFPath: resolvedPDFPath)
    }

    /// `hasRemotePDFURL` without the stat — see `cachedResolvedLocalPath`. Until the
    /// background warm has statted the source, an attached local PDF reads as absent
    /// and the reader offers the remote copy; it re-renders against the cache the
    /// moment the warm re-publishes.
    var cachedHasRemotePDFURL: Bool {
        hasRemotePDFURL(localPDFPath: cachedResolvedPDFPath)
    }

    private func hasRemotePDFURL(localPDFPath: String?) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
        guard localPDFPath == nil else { return false }
        return PaperService.paperPDFURL(from: url) != nil
    }

    /// Whether the reader shows this source's stored text rather than the PDF
    /// at its URL.
    ///
    /// A non-paper source only reaches a PDF URL with no file on record when
    /// its text was handed in with it: the app's own fetch of a PDF-URL
    /// article downloads the file (`downloadDocumentPDF` records
    /// `localFilePath`). That text is the source — `add_source` promises it is
    /// shown verbatim — and it is often a part of the file, such as one
    /// abstract from a conference book's page, so streaming the whole PDF
    /// shows something other than what was added. A paper's text is an
    /// extraction of its PDF, so a paper keeps the PDF.
    ///
    /// Judged on `wordCount`, not `content`: a loaded row carries no text until
    /// `hydrateStoredContent` puts it there, and deciding on `content` sent the
    /// reader to the PDF in that gap — whose save then made the source a paper
    /// holding the whole file (2026-09-23).
    var readsStoredTextOverRemotePDF: Bool {
        guard sourceType != .paper, localFilePath == nil, state == .ready else { return false }
        let hasText = (wordCount ?? 0) > 0
            || content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasText else { return false }
        return PaperService.paperPDFURL(from: url) != nil
    }

    /// The resolved direct PDF download URL for this paper, if available.
    var remotePDFURL: URL? {
        guard let pdfURLString = PaperService.paperPDFURL(from: url) else { return nil }
        return URL(string: pdfURLString)
    }

    init(url: String, title: String? = nil, sourceType: StudioSourceType = .manual, artworkURL: String? = nil, discoveryOrigin: DiscoveryOrigin? = nil, parentGroup: String? = nil, localFilePath: String? = nil, publicURL: String? = nil, author: String? = nil, journal: String? = nil, publishedYear: String? = nil, id: String? = nil) {
        self.id = id ?? SourceIdentity.stableID(for: url)
        self.url = url
        self.normalizedURL = URLNormalizer.normalize(url)
        self.title = (title ?? url).decodingTitleMarkup()
        self.domain = URL(string: url)?.host ?? url
        self.dateAdded = Date()
        self.state = .queued
        self.sourceType = sourceType
        self.artworkURL = artworkURL
        self.discoveryOrigin = discoveryOrigin
        self.parentGroup = parentGroup
        self.localFilePath = localFilePath
        self.publicURL = publicURL
        self.author = SourceAuthor.storable(author)
        self.journal = journal
        self.publishedYear = publishedYear
    }
}

/// The fields a copy of a source has changed since it was read from the store, noted by each field's
/// own observer when its value changes. Equal to every other, so two copies of one source still compare
/// by what they hold and the sidebar's change checks are unmoved.
struct SourceEdits: Equatable, Sendable {
    /// What `persistSourceRows` writes from a `StudioArticle`, one bit each.
    enum Field: Int, CaseIterable {
        case url, title, domain, teamID, dateAdded, wordCount
        case state, errorMessage, sourceType, artworkURL, discoveryOrigin, parentGroup
        case localFilePath, podcastWebPageURL, author, journal, publishedYear, status
        case archivedAt, normalizedURL, publicURL, courseSortIndex, lectureGroupId, isPaywalled
        case paywallSuspicion, isHidden, doi, publishedDOI, paperIngestionMethod, readingPositionPage
        case readingPositionLocator, readAt, likedAt, videoPublishedAt, connectorLabel, bookPages
    }

    /// False for a copy never read from the store, which a save writes whole.
    private(set) var isTracking = false
    private var bits: UInt64 = 0

    init() {}

    private init(isTracking: Bool) { self.isTracking = isTracking }

    /// A copy just read: tracking, and nothing changed yet.
    static var read: SourceEdits { SourceEdits(isTracking: true) }

    mutating func note(_ field: Field) {
        guard isTracking else { return }
        bits |= 1 << UInt64(field.rawValue)
    }

    /// Every field, for a copy put back whole by assignment (an earlier copy restored after a step that
    /// saved), which no field's observer sees: its save writes it whole, as every save did before.
    mutating func noteAll() {
        guard isTracking else { return }
        bits = (1 << UInt64(Field.allCases.count)) - 1
    }

    func contains(_ field: Field) -> Bool { bits & (1 << UInt64(field.rawValue)) != 0 }

    static func == (_: SourceEdits, _: SourceEdits) -> Bool { true }
}

extension StudioArticle {
    /// This copy as a save writes it over `stored`, the row as the store holds it now: a field this copy
    /// changed since it was read keeps this copy's value, and every other field takes the stored one.
    /// `PaperMetadataBackfillPatch` is the same rule for its fields. Under generation 2 every column whose
    /// value a save changes is sent with a new stamp and wins on every device, so a copy held across
    /// another device's change (a long ingestion's snapshot, the view model's copy before its reload)
    /// would otherwise send the old value back. A field changed and changed back still counts as
    /// changed, so a retry that puts a state back is written. `keptStored` says the copy lacked a stored
    /// value it had not changed, so whoever shows it is behind. Nil for a copy never read from the store,
    /// or one of another source: that is written whole, as before.
    ///
    /// The fields are the ones `persistSourceRows` writes; one left out is written from the copy, as
    /// before, never dropped. Not merged: `content` and the `…ForPersistence` handoffs, which a save
    /// writes only when the copy carries them, and the derived `paperContentSHA256` and
    /// `paperListenableContentReady`, which no save writes.
    func written(over stored: StudioArticle) -> (article: StudioArticle, keptStored: Bool)? {
        guard edits.isTracking, stored.id == id else { return nil }
        var merged = self
        var keptStored = false
        func keep<Value: Equatable>(_ field: SourceEdits.Field, _ keyPath: WritableKeyPath<StudioArticle, Value>) {
            guard !edits.contains(field) else { return }
            let current = stored[keyPath: keyPath]
            guard current != self[keyPath: keyPath] else { return }
            merged[keyPath: keyPath] = current
            keptStored = true
        }
        keep(.url, \.url)
        keep(.title, \.title)
        keep(.domain, \.domain)
        keep(.teamID, \.teamID)
        keep(.dateAdded, \.dateAdded)
        keep(.wordCount, \.wordCount)
        keep(.state, \.state)
        keep(.errorMessage, \.errorMessage)
        keep(.sourceType, \.sourceType)
        keep(.artworkURL, \.artworkURL)
        keep(.discoveryOrigin, \.discoveryOrigin)
        keep(.parentGroup, \.parentGroup)
        keep(.localFilePath, \.localFilePath)
        keep(.podcastWebPageURL, \.podcastWebPageURL)
        keep(.author, \.author)
        keep(.journal, \.journal)
        keep(.publishedYear, \.publishedYear)
        keep(.status, \.status)
        keep(.archivedAt, \.archivedAt)
        keep(.normalizedURL, \.normalizedURL)
        keep(.publicURL, \.publicURL)
        keep(.courseSortIndex, \.courseSortIndex)
        keep(.lectureGroupId, \.lectureGroupId)
        keep(.isPaywalled, \.isPaywalled)
        keep(.paywallSuspicion, \.paywallSuspicion)
        keep(.isHidden, \.isHidden)
        keep(.doi, \.doi)
        keep(.publishedDOI, \.publishedDOI)
        keep(.paperIngestionMethod, \.paperIngestionMethod)
        keep(.readingPositionPage, \.readingPositionPage)
        keep(.readingPositionLocator, \.readingPositionLocator)
        keep(.readAt, \.readAt)
        keep(.likedAt, \.likedAt)
        keep(.videoPublishedAt, \.videoPublishedAt)
        keep(.connectorLabel, \.connectorLabel)
        keep(.bookPages, \.bookPages)
        return (merged, keptStored)
    }
}

extension AIUsageSource {
    init(source: StudioArticle) {
        self.init(
            id: source.id,
            type: source.sourceType == .podcast ? "podcast_episode" : source.sourceType.rawValue,
            title: source.title
        )
    }

    init(id: String, sourceType: StudioSourceType, title: String) {
        self.init(
            id: id,
            type: sourceType == .podcast ? "podcast_episode" : sourceType.rawValue,
            title: title
        )
    }
}

/// Where the learner left off inside an EPUB: which chapter file, and how far down
/// it. The third encoding of `sources.reading_position_locator`; `relativePath` is
/// required, which is what keeps it from decoding an article or video locator.
/// Turns a reader's saved *resume locator* back into a 0...1 depth, the currency
/// `source_activity_days.max_fraction` is kept in.
///
/// Every reader already persists a position on each scroll or page turn so it can
/// resume where the learner left off. That position is also the cheapest honest
/// answer to "how much of this actually landed", and until this existed the depth
/// ledger simply never heard about reading — only the audio player ever wrote a
/// fraction, so the Schedule had to fall back on "it was opened" and call that
/// done.
///
/// A locator only qualifies when its fraction covers the *whole* source. Book
/// chapters are separate sources whose locator is scoped to that chapter's file,
/// so those count; a PDF page index carries no total and is supplied directly by
/// the reader instead.
enum SourceProgressDepth {
    static func fraction(locator: String?) -> Double? {
        guard let locator, !locator.isEmpty else { return nil }
        if let article = ArticleReadingPositionLocator(encoded: locator) {
            return article.webScrollFraction
        }
        if let video = VideoWatchProgress(encoded: locator) {
            return video.fractionWatched
        }
        if let chapter = EPUBReadingPositionLocator(encoded: locator) {
            return chapter.scrollFraction
        }
        return nil
    }

    /// Depth implied by landing on a zero-based page index. The last page is a
    /// full read: a PDF's final page is its end, however little of it is text.
    static func fraction(pageIndex: Int, pageCount: Int) -> Double? {
        guard pageIndex >= 0, pageCount > 0 else { return nil }
        guard pageCount > 1 else { return 1 }
        return min(max(Double(pageIndex) / Double(pageCount - 1), 0), 1)
    }
}

struct EPUBReadingPositionLocator: Codable, Equatable {
    let relativePath: String
    let scrollFraction: Double

    init(relativePath: String, scrollFraction: Double) {
        self.relativePath = relativePath
        let clamped = min(max(scrollFraction, 0), 1)
        self.scrollFraction = (clamped * 10_000).rounded() / 10_000
    }

    init?(encoded: String?) {
        guard let encoded,
              let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              !decoded.relativePath.isEmpty else { return nil }
        self = decoded
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension String {
    /// The named references every ingestion path decodes. A lookup table rather
    /// than the full HTML5 entity set: these are the names real sources emit —
    /// smart quotes, dashes, the accented Latin letters in author names, and the
    /// typographic and math symbols that survive a web extraction.
    private static let htmlNamedCharacterReferences: [String: String] = [
        // `&nbsp;` deliberately becomes a plain space: extracted text is reflowed
        // for reading, and a no-break space there only produces odd line breaks.
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">",
        // `&shy;` is the soft hyphen, and decodes to it as `&#173;` always has.
        // The text a source keeps drops it where that text is derived
        // (`removingSoftHyphens()`), not here: a decoded attribute or address
        // stays what it says.
        "shy": "\u{00AD}",
        "quot": "\"", "apos": "'",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "minus": "\u{2212}",
        "hellip": "\u{2026}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "sbquo": "\u{201A}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}", "bdquo": "\u{201E}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "bull": "\u{2022}", "middot": "\u{00B7}",
        "prime": "\u{2032}", "Prime": "\u{2033}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}",
        "sect": "\u{00A7}", "para": "\u{00B6}",
        "thinsp": " ", "ensp": " ", "emsp": " ",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "micro": "\u{00B5}",
        "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "sup1": "\u{00B9}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "approx": "\u{2248}", "asymp": "\u{2248}", "equiv": "\u{2261}",
        "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}",
        "tilde": "\u{02DC}", "infin": "\u{221E}", "radic": "\u{221A}",
        "sum": "\u{2211}", "prod": "\u{220F}", "int": "\u{222B}",
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}",
        "darr": "\u{2193}", "harr": "\u{2194}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        "Agrave": "\u{00C0}", "Aacute": "\u{00C1}", "Acirc": "\u{00C2}", "Atilde": "\u{00C3}",
        "Auml": "\u{00C4}", "Aring": "\u{00C5}", "AElig": "\u{00C6}",
        "Ccedil": "\u{00C7}", "Egrave": "\u{00C8}", "Eacute": "\u{00C9}", "Ecirc": "\u{00CA}",
        "Euml": "\u{00CB}", "Igrave": "\u{00CC}", "Iacute": "\u{00CD}", "Icirc": "\u{00CE}",
        "Iuml": "\u{00CF}", "Ntilde": "\u{00D1}",
        "Ograve": "\u{00D2}", "Oacute": "\u{00D3}", "Ocirc": "\u{00D4}", "Otilde": "\u{00D5}",
        "Ouml": "\u{00D6}", "Oslash": "\u{00D8}",
        "Ugrave": "\u{00D9}", "Uacute": "\u{00DA}", "Ucirc": "\u{00DB}", "Uuml": "\u{00DC}",
        "Yacute": "\u{00DD}", "szlig": "\u{00DF}",
        "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}", "atilde": "\u{00E3}",
        "auml": "\u{00E4}", "aring": "\u{00E5}", "aelig": "\u{00E6}",
        "ccedil": "\u{00E7}", "egrave": "\u{00E8}", "eacute": "\u{00E9}", "ecirc": "\u{00EA}",
        "euml": "\u{00EB}", "igrave": "\u{00EC}", "iacute": "\u{00ED}", "icirc": "\u{00EE}",
        "iuml": "\u{00EF}", "ntilde": "\u{00F1}",
        "ograve": "\u{00F2}", "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "otilde": "\u{00F5}",
        "ouml": "\u{00F6}", "oslash": "\u{00F8}",
        "ugrave": "\u{00F9}", "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}",
        "yacute": "\u{00FD}", "yuml": "\u{00FF}",
    ]

    /// The longest reference body this scanner will consider (`#x1F600` and the
    /// longest name both fit well inside it). A bare `&` in prose must not send
    /// the scan hunting for a semicolon through the rest of a 120k-character
    /// article.
    private static let maxHTMLCharacterReferenceBodyLength = 12

    /// Decodes HTML character references — named (`&ldquo;`) and numeric
    /// (`&#8220;`, `&#x201C;`) — into the characters they stand for.
    ///
    /// Exactly one level, in a single left-to-right scan. The pass-per-entity
    /// implementation this replaced substituted `&amp;` before the named table
    /// and then re-read its own output, which got both ends of the problem
    /// wrong: `&amp;ldquo;` — text that means the literal characters `&ldquo;` —
    /// came out as a curly quote, while a doubly escaped `&amp;amp;` was left
    /// holding a visible `&amp;`. A scan cannot re-read what it has written, so
    /// neither is possible. Use `decodingDoubleEscapedHTMLCharacterReferences()`
    /// where the upstream really does escape twice.
    func decodingHTMLCharacterReferences() -> String {
        guard contains("&") else { return self }
        var result = ""
        result.reserveCapacity(count)
        var cursor = startIndex
        while cursor < endIndex {
            guard let ampersand = self[cursor...].firstIndex(of: "&") else {
                result.append(contentsOf: self[cursor...])
                break
            }
            result.append(contentsOf: self[cursor..<ampersand])
            let bodyStart = index(after: ampersand)
            let window = self[bodyStart...].prefix(Self.maxHTMLCharacterReferenceBodyLength)
            if let semicolon = window.firstIndex(of: ";"),
               let decoded = Self.decodedHTMLCharacterReference(self[bodyStart..<semicolon]) {
                result.append(decoded)
                cursor = index(after: semicolon)
            } else {
                // Not a reference — a bare ampersand in prose, or a name this
                // table does not carry. Either way it stays as written.
                result.append("&")
                cursor = bodyStart
            }
        }
        return result
    }

    /// Two decoding levels, for upstreams that escape an already-escaped string.
    /// YouTube's timed-text XML is the app's live example: a literal `&` arrives
    /// as `&amp;amp;` and an apostrophe as `&amp;#39;`.
    func decodingDoubleEscapedHTMLCharacterReferences() -> String {
        decodingHTMLCharacterReferences().decodingHTMLCharacterReferences()
    }

    /// A title as the library keeps and draws it: character references
    /// decoded, then the inline markup a catalog wrote into it folded into
    /// text, so `H<sub>2</sub>O<sub>2</sub>` reads `H₂O₂`, and its soft hyphens
    /// dropped. A title is drawn as text everywhere — rows, the chat's Sources
    /// list, the MCP tools — so it is kept as text. See `foldingInlineMarkup()`
    /// and `removingSoftHyphens()`.
    func decodingTitleMarkup() -> String {
        decodingHTMLCharacterReferences().foldingInlineMarkup().removingSoftHyphens()
    }

    /// The text without U+00AD SOFT HYPHEN.
    ///
    /// A soft hyphen is a hyphenation hint for whatever lays the text out,
    /// never a character a reader sees: a web page writes `&shy;` where a long
    /// word may break, and a publisher's PDF keeps one where its typesetter
    /// could break a word, often right after a real hyphen
    /// ("regeneration-\u{00AD}associated"). Left in the text a source keeps,
    /// it splits the word it sits in — "life\u{00AD}span" is not "lifespan" to
    /// keyword search, embeddings, a chat's quote or Listen — so every path
    /// that derives a source's text drops it, after decoding character
    /// references. Dropping it changes nothing a reader sees. Words are never
    /// joined: a hyphen and any space the layout put after a soft hyphen stay
    /// as they are.
    func removingSoftHyphens() -> String {
        guard unicodeScalars.contains("\u{00AD}") else { return self }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(unicodeScalars.count)
        for scalar in unicodeScalars where scalar != "\u{00AD}" {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func decodedHTMLCharacterReference(_ body: Substring) -> String? {
        guard !body.isEmpty else { return nil }
        guard body.hasPrefix("#") else {
            return htmlNamedCharacterReferences[String(body)]
        }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(Character(scalar))
    }
}

// MARK: - Review Session Links

enum ReviewSessionProvider: String, Codable {
    case claude = "Claude"
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"
    case grok = "Grok"
    case edison = "Edison Scientific"
    case metaAI = "Meta AI"
    case other = "Other"

    var icon: String {
        switch self {
        case .claude: return "sparkles"
        case .chatGPT: return "bubble.left.and.bubble.right"
        case .gemini: return "sparkle"
        case .grok: return "xmark"
        case .edison: return "lightbulb"
        case .metaAI: return "infinity"
        case .other: return "link"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .chatGPT: return "ChatGPTIcon"
        case .gemini: return "GeminiIcon"
        case .grok: return "GrokIcon"
        case .edison: return "EdisonIcon"
        case .metaAI: return "MetaIcon"
        case .other: return nil
        }
    }

    static func infer(from urlString: String) -> ReviewSessionProvider {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return .other }
        if matchesHost(host, domain: "claude.ai") { return .claude }
        if matchesHost(host, domain: "chatgpt.com") || matchesHost(host, domain: "chat.openai.com") { return .chatGPT }
        if matchesHost(host, domain: "gemini.google.com") || matchesHost(host, domain: "aistudio.google.com") { return .gemini }
        if matchesHost(host, domain: "grok.com") || matchesHost(host, domain: "x.ai") { return .grok }
        if matchesHost(host, domain: "platform.edisonscientific.com") { return .edison }
        if matchesHost(host, domain: "meta.ai") { return .metaAI }
        return .other
    }

    private static func matchesHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

struct ReviewSessionRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var url: String?
    var createdAt: Date
    var status: String
    var sourceIDs: [String]
    /// Summary text for completed local MCP sessions. Nil for external links
    /// (external-link rows reuse the `summary` DB column to hold the URL).
    var summary: String?
    /// Overall score (0.0–1.0) for completed local MCP sessions.
    var overallScore: Double?
    /// Number of Q/A exchanges recorded for this session.
    var exchangeCount: Int
    /// Provider/model last used to produce an in-app chat response.
    var modelProvider: String?
    var modelID: String?
    /// Learning Companion / Notebook this session was started under, when known.
    var goalID: String?
    /// The team this chat was shared into as a read-only transcript snapshot;
    /// nil for the learner's own live chats.
    var teamID: String?
    /// When the learner hid this chat from the sidebar. The chat itself is
    /// unchanged — the date lives in `hidden_review_sessions` and syncs as its
    /// own private-zone record (schema 114), so every Mac signed into the
    /// account folds the same chats — and the Hidden fold under Chats is the
    /// one place it is listed again.
    var hiddenAt: Date?

    init(
        id: String,
        title: String,
        url: String? = nil,
        createdAt: Date,
        status: String,
        sourceIDs: [String],
        summary: String? = nil,
        overallScore: Double? = nil,
        exchangeCount: Int = 0,
        modelProvider: String? = nil,
        modelID: String? = nil,
        goalID: String? = nil,
        teamID: String? = nil,
        hiddenAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.status = status
        self.sourceIDs = sourceIDs
        self.summary = summary
        self.overallScore = overallScore
        self.exchangeCount = exchangeCount
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.goalID = goalID
        self.teamID = teamID
        self.hiddenAt = hiddenAt
    }

    /// A team chat is a transcript another member (or this one) shared; it is
    /// read, never continued.
    var isTeamSnapshot: Bool { teamID != nil }

    /// Hidden from the sidebar; see `hiddenAt`.
    var isHidden: Bool { hiddenAt != nil }

    var provider: ReviewSessionProvider {
        ReviewSessionProvider.infer(from: url ?? "")
    }

    var origin: ReviewSessionOrigin {
        ReviewSessionOrigin.infer(from: id)
    }

    var isExternalLink: Bool {
        guard let url else { return false }
        return url.hasPrefix("https://") || url.hasPrefix("http://")
    }

    /// True when this row represents a local review session recorded via MCP
    /// (as opposed to an external chat share link).
    var isLocalMCPSession: Bool {
        status == "active" || status == "completed"
    }

    var modelDisplayName: String? {
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let provider = modelProvider.flatMap(AIProvider.init(rawValue:)) {
            return AIModelDisplayName.textModelName(modelID, provider: provider)
        }
        return modelID
    }
}

/// Device surface that created a chat. Mobile sessions have always used a
/// stable ID prefix, so origin stays available across CloudKit and the web
/// client without adding a database column or rewriting existing libraries.
enum ReviewSessionOrigin: String, Codable, Equatable {
    case other
    case iPhone
    case carPlay

    static func infer(from sessionID: String) -> ReviewSessionOrigin {
        if sessionID.hasPrefix("carplay-") { return .carPlay }
        if sessionID.hasPrefix("ios-") { return .iPhone }
        return .other
    }
}

struct ReviewExchangeRecord: Identifiable, Codable, Equatable {
    let id: String
    let sessionID: String
    let sequenceNumber: Int
    let question: String
    let userAnswer: String?
    let evaluation: String?
    let score: Double?
    let sourceRefs: [String]
    let knowledgeNote: String?
    let answeredAt: Date?
    /// The reference material the learner's message was sent with — a passage
    /// quoted out of a doc or a reader, its section, and the doc it came from.
    /// Reconstituted on resume so a chat opened on a passage still knows which
    /// passage after it is reopened. nil for a message sent with no selection,
    /// and for every message recorded before v84.
    let contextContent: String?
    /// Memory review grading (v89): `[MemoryIdeaCoverage]` JSON, the
    /// question's verdict and operation, and the learner's steer. nil on
    /// every exchange that was not graded against ideas.
    let ideaCoverage: String?
    let questionVerdict: String?
    let operation: String?
    let steer: String?
    /// The learner's thumb on one of this exchange's tutor turns (v93), the
    /// reason they gave, which field it rated, and when. nil when unrated.
    let rating: ReviewTurnRating?
    let ratingReason: String?
    let ratingField: ReviewExchangeMessageField?
    let ratedAt: Date?

    init(
        id: String,
        sessionID: String,
        sequenceNumber: Int,
        question: String,
        userAnswer: String?,
        evaluation: String?,
        score: Double?,
        sourceRefs: [String],
        knowledgeNote: String?,
        answeredAt: Date?,
        contextContent: String?,
        ideaCoverage: String? = nil,
        questionVerdict: String? = nil,
        operation: String? = nil,
        steer: String? = nil,
        rating: ReviewTurnRating? = nil,
        ratingReason: String? = nil,
        ratingField: ReviewExchangeMessageField? = nil,
        ratedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.question = question
        self.userAnswer = userAnswer
        self.evaluation = evaluation
        self.score = score
        self.sourceRefs = sourceRefs
        self.knowledgeNote = knowledgeNote
        self.answeredAt = answeredAt
        self.contextContent = contextContent
        self.ideaCoverage = ideaCoverage
        self.questionVerdict = questionVerdict
        self.operation = operation
        self.steer = steer
        self.rating = rating
        self.ratingReason = ratingReason
        self.ratingField = ratingField
        self.ratedAt = ratedAt
    }
}

/// The rolling model-written summary of a chat's older turns, and the last
/// persisted message it covers.
///
/// Local-only and regenerable: it is a cache of the transcript that every
/// device can rebuild from the exchanges it already syncs, so it never travels
/// through CloudKit. The cursor names a message by `(exchange, field)` rather
/// than by position because the in-memory transcript carries harness rows
/// (tool calls, retries) that the saved one does not, so a message count means
/// something different live and after a reopen.
struct ReviewSessionHistoryDigest: Equatable, Sendable {
    let sessionID: String
    let digest: String
    /// The exchange holding the last message folded into `digest`.
    let throughExchangeID: String
    /// Which of that exchange's messages was the last one folded.
    let throughField: ReviewExchangeMessageField
    let updatedAt: Date
}

/// A chat traced back to the passage that prompted it.
///
/// Written when the first message of a doc-originated conversation is sent —
/// not when Chat is opened, which would leave a link behind for a question
/// never asked. One row per passage a session was opened on: the same chat may
/// be pointed at a second passage later, and both are true.
///
/// The anchor is revision-bound and never re-anchored, the same contract
/// `ArtifactCommentRecord` keeps. `anchorQuote` is the durable identity — the
/// words the learner asked about, still readable after the doc moves on —
/// while `anchorStart`/`anchorEnd` locate them only while `anchorRevision`
/// still matches the doc's current revision.
struct ArtifactChatLinkRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let artifactID: String
    let sessionID: String
    let anchorRevision: String
    let anchorStart: Int
    let anchorEnd: Int
    let anchorQuote: String
    /// The heading the passage sat under, for a row that has to say where in a
    /// long doc the conversation started. Empty when the passage sat under none.
    let sectionTitle: String
    let createdAt: Date

    /// Whether the stored offsets still describe the doc as it is now. A doc
    /// edited since the conversation keeps the quote and loses the position.
    func locatesPassage(inRevision revision: String) -> Bool {
        !anchorRevision.isEmpty && anchorRevision == revision && anchorEnd > anchorStart
    }

    /// Whether this link's passage is what the writer has selected now.
    ///
    /// Offsets are the answer while they still describe the doc on screen: pass
    /// the revision the selection was made in, and the two ranges only have to
    /// touch. Once the doc has moved on — a later revision, or unsaved edits,
    /// signalled by an empty `revision` — the offsets say nothing, and the quote
    /// decides: a selection that contains the asked-about words, or sits inside
    /// them, is the same passage. A short selection inside a long quote is held
    /// to a minimum length so that selecting one common word does not light up
    /// every conversation that ever used it.
    func anchors(selection: Range<Int>, selectedText: String, inRevision revision: String) -> Bool {
        if locatesPassage(inRevision: revision) {
            return anchorStart < selection.upperBound && selection.lowerBound < anchorEnd
        }
        let quote = Self.collapsedWhitespace(anchorQuote)
        let selected = Self.collapsedWhitespace(selectedText)
        guard !quote.isEmpty, !selected.isEmpty else { return false }
        if selected.contains(quote) { return true }
        return selected.count >= Self.minimumSelectionInsideQuote && quote.contains(selected)
    }

    /// Short enough to keep a selected clause, long enough to drop a word.
    static let minimumSelectionInsideQuote = 12

    /// Whitespace runs and letter case both drift when a sentence is rewritten
    /// around the passage; neither makes it a different passage.
    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

enum ReviewExchangeMessageField: String, Codable, Equatable {
    case question
    case userAnswer
    case evaluation
}

// MARK: - Learning Goals

/// Review/approval lifecycle for a discovered Learning Companion source.
enum LearningGoalItemReviewState: String, Codable {
    case approved   // seed sources, or discovered sources the user accepted
    case pending    // discovered by topic search, awaiting approval
    case rejected   // discovered but dismissed; tombstoned so it is never re-proposed
}

/// How a source entered a Learning Companion goal's pool.
enum LearningGoalItemOrigin: String, Codable {
    case seed       // explicitly pinned by the user at creation/add time
    case discovered // surfaced by topic similarity search
}

/// A shared calendar placement: a source sits on the Schedule once (one planned
/// day, one completion state) and is tagged with any number of Goals and
/// Notebooks, or none. Reviewing it once counts toward every goal it is tagged with.
struct ScheduledSource: Identifiable, Codable, Equatable {
    let id: String
    let sourceID: String
    var plannedAt: Date          // start-of-day + order-seconds (see learningGoalItemPlannedDate)
    var addedAt: Date
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var isCompleted: Bool { completedAt != nil }
}

/// Lightweight goal reference for tagging a placement in the UI / MCP output.
struct GoalTag: Identifiable, Codable, Equatable {
    let id: String
    let title: String
}

/// A shared placement together with the goals it's tagged with (for loading the
/// unified Schedule calendar in one pass).
struct ScheduledSourceEntry: Identifiable, Equatable {
    let placement: ScheduledSource
    let goalTags: [GoalTag]
    /// Every goal this placement is tagged with, including companion Notebooks.
    /// `goalTags` is what chips show (Goals, never top-level Notebooks); `goalIDs`
    /// is full membership, used to scope a Notebook/goal's own schedule view.
    var goalIDs: Set<String> = []
    /// True only when the placement was created by learning activity rather
    /// than chosen by the learner or attached to a goal.
    var isAutomatic: Bool = false
    /// Automatic learning history attached to this source-global placement.
    /// Plans remain editable independently; activity is an immutable day record.
    var activityDays: [SourceActivityDay] = []
    var id: String { placement.id }
}

struct LearningGoalItem: Identifiable, Codable, Equatable {
    let id: String
    let goalID: String
    let sourceID: String
    var addedAt: Date
    var completedAt: Date?

    // Learning Companion fields (nil on legacy Schedule items).
    var origin: String?       // LearningGoalItemOrigin raw value
    var reviewState: String?  // LearningGoalItemReviewState raw value
    var relevance: Double?    // discovery's rank score, for ordering suggestions; no meaning on its own
    var lastQuizzedAt: Date?  // last time this item appeared in a daily quiz
    var quizCount: Int?       // number of daily quizzes this item has appeared in
    var lastScore: Double?    // most recent quiz score (0..1), drives spaced resurfacing
    var sequence: Double?     // user-defined study order within the Notebook pool; nil = unsequenced (sorts last, by addedAt)

    init(
        id: String,
        goalID: String,
        sourceID: String,
        addedAt: Date,
        completedAt: Date? = nil,
        origin: String? = nil,
        reviewState: String? = nil,
        relevance: Double? = nil,
        lastQuizzedAt: Date? = nil,
        quizCount: Int? = nil,
        lastScore: Double? = nil,
        sequence: Double? = nil
    ) {
        self.id = id
        self.goalID = goalID
        self.sourceID = sourceID
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.origin = origin
        self.reviewState = reviewState
        self.relevance = relevance
        self.lastQuizzedAt = lastQuizzedAt
        self.quizCount = quizCount
        self.lastScore = lastScore
        self.sequence = sequence
    }

    var isCompleted: Bool { completedAt != nil }

    /// Companion items are eligible for the daily blend only once approved.
    /// Legacy Schedule items (nil reviewState) are treated as approved.
    var isApproved: Bool {
        (reviewState ?? LearningGoalItemReviewState.approved.rawValue) == LearningGoalItemReviewState.approved.rawValue
    }

    var isPendingApproval: Bool {
        reviewState == LearningGoalItemReviewState.pending.rawValue
    }

    enum UnderstandingState: String, Codable, CaseIterable {
        case toRead = "to-read"
        case reading = "reading"
        case understood = "understood"
    }

    /// Derived from retention fields — matches MCP `list_notebook_sources` / `get_notebook_context`.
    var derivedUnderstandingState: UnderstandingState {
        if isCompleted { return .understood }
        if let score = lastScore, score >= 0.7 { return .understood }
        if (quizCount ?? 0) > 0 || lastQuizzedAt != nil { return .reading }
        return .toRead
    }
}

/// A durable "what the learner doesn't understand yet" entry that carries
/// across daily quizzes for a Learning Companion goal.
struct LearningGoalGap: Identifiable, Codable, Equatable {
    let id: String
    let goalID: String
    var summary: String
    var sourceID: String?
    var status: String          // open | improving | resolved
    var severity: Double?       // 0..1, how central to the goal
    var firstSeenAt: Date
    var lastSeenAt: Date
    var resolvedAt: Date?
    var sessionID: String?      // session that surfaced/updated it

    var isOpen: Bool { status != "resolved" }
}

/// Lifecycle state of a Notebook or Goal, stored in `learning_goals.status`.
/// Legacy rows are all `active` (the column default), so `active` is also the
/// parse fallback for any unrecognized value.
enum LearningGoalStatus: String, Codable, CaseIterable, Sendable {
    case active
    case done
    case archived

    /// Tolerant parse for the stored column: nil, empty, or anything
    /// unrecognized reads as `.active`.
    static func parse(_ raw: String?) -> LearningGoalStatus {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let parsed = LearningGoalStatus(rawValue: raw) else { return .active }
        return parsed
    }
}

struct LearningGoalRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var startAt: Date
    var endAt: Date
    var createdAt: Date
    var updatedAt: Date
    var status: String
    var items: [LearningGoalItem]

    // Learning Companion fields (nil on legacy Schedules).
    var kind: String?            // "companion" for proactive daily-quiz goals
    var description: String?     // a Notebook's standing Instructions (guidance for chat); a Goal's plain summary
    /// A Notebook's short description: one or two lines shown on its gallery
    /// card and in the Notebook overview. Display copy for the learner, unlike
    /// `description`, which is guidance for the model. nil when never written.
    var summary: String?
    var topic: String?           // natural-language topic for discovery
    var discoveryEnabled: Bool?  // auto-discover related sources by topic each day
    var dailyTarget: Int?        // items per daily quiz
    var lastQuizDate: String?    // YYYY-MM-DD of the last served quiz
    var lastDiscoveryAt: Date?   // last incremental discovery pass
    var gaps: [LearningGoalGap]? // evolving understanding model
    var notes: String?           // Notebook synthesis notes (markdown)
    var parentNotebookID: String? // when set, this companion goal is a timebound Goal that lives inside the named Notebook
    /// The Notebook's defining research questions, in the learner's priority
    /// order — the questions the Notebook exists to answer, distinct from the
    /// emergent open-question gaps. nil means "never set" (old records and old
    /// devices), which sync must treat as no-opinion rather than clearing; an
    /// explicitly emptied list is `[]`.
    var researchQuestions: [String]?
    /// Directional references to other top-level Notebooks whose sources and
    /// synthesis are available as context here. nil means an older payload has
    /// no opinion; [] is an explicit absence of links.
    var relatedNotebookIDs: [String]?
    /// The GitHub repository this Notebook is about, as canonical `owner/repo`.
    /// Only the name is stored: a chat in the Notebook reads the repository
    /// live through the read-only GitHub tools, nothing from GitHub lands in
    /// the library. Tri-state like `researchQuestions`: nil is "never set" (an
    /// old record or an older device with no opinion, which sync keeps local),
    /// `""` is an explicit unlink that travels and wins, and read through
    /// `linkedRepository` both read as no repository.
    var repository: String?
    /// The artifact a Goal is for — the Doc, Site or animation that *is* the
    /// deliverable ("Make a site of the rare mitochondrial diseases" and the
    /// site itself), by record id. One link: a Goal is one outcome. Tri-state
    /// like `repository`: nil is "never set" (an old record or an older device
    /// with no opinion, which sync keeps local), `""` is an explicit unlink
    /// that travels and wins, and both read as no artifact through
    /// `linkedArtifactID`. Only the id is stored; the row resolves the record
    /// from the loaded library, and a record that is gone reads as unlinked.
    var artifactID: String?
    /// Where the learner put the Goal in the Goals tab (product owner, 2026-09-20:
    /// "allow me to reshuffle these"). nil is a Goal never placed by hand,
    /// which reads by deadline after every placed one (`listOrder`); a
    /// placement is the row's index in the order the learner last made.
    /// Rides the learningGoal payload as a new Codable key an older client
    /// decodes to nil, which the sync upsert reads as no opinion, so a
    /// rearrangement made here survives a save from a build that never
    /// heard of it. Never reset by a status change: a Goal reopened comes
    /// back where it was.
    var sortOrder: Int?
    /// The team whose library this Notebook belongs to; nil for My Library.
    /// Decoded as optional so records from older devices keep decoding.
    var teamID: String?

    init(
        id: String,
        title: String,
        startAt: Date,
        endAt: Date,
        createdAt: Date,
        updatedAt: Date,
        status: String,
        items: [LearningGoalItem],
        kind: String? = nil,
        description: String? = nil,
        summary: String? = nil,
        topic: String? = nil,
        discoveryEnabled: Bool? = nil,
        dailyTarget: Int? = nil,
        lastQuizDate: String? = nil,
        lastDiscoveryAt: Date? = nil,
        gaps: [LearningGoalGap]? = nil,
        notes: String? = nil,
        parentNotebookID: String? = nil,
        researchQuestions: [String]? = nil,
        relatedNotebookIDs: [String]? = nil,
        repository: String? = nil,
        teamID: String? = nil,
        artifactID: String? = nil,
        sortOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.items = items
        self.kind = kind
        self.description = description
        self.summary = summary
        self.topic = topic
        self.discoveryEnabled = discoveryEnabled
        self.dailyTarget = dailyTarget
        self.lastQuizDate = lastQuizDate
        self.lastDiscoveryAt = lastDiscoveryAt
        self.gaps = gaps
        self.notes = notes
        self.parentNotebookID = parentNotebookID
        self.researchQuestions = researchQuestions
        self.relatedNotebookIDs = relatedNotebookIDs
        self.repository = repository
        self.teamID = teamID
        self.artifactID = artifactID
        self.sortOrder = sortOrder
    }

    /// The order the Goals tab, the Planner's Goal picker and `list_goals`
    /// share: the Goals the learner placed first, in the order they were
    /// placed, then the rest by deadline (nearest first) and, within a day,
    /// by when they were set. A placed Goal keeps its place whatever its
    /// deadline does, so an overdue Goal the learner put third stays third;
    /// a Goal never placed reads where the deadline puts it, below the
    /// placed ones. `KnowledgeStore.reorderLearningGoals` writes the
    /// placements this reads.
    static func listOrder(_ lhs: LearningGoalRecord, _ rhs: LearningGoalRecord) -> Bool {
        switch (lhs.sortOrder, rhs.sortOrder) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.endAt != rhs.endAt { return lhs.endAt < rhs.endAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    static let companionKind = LearningGoalShape.companionKind
    /// Longest stored Notebook summary; the Portable rule every client shares.
    static let summaryMaxLength = NotebookSummary.maxLength

    /// Stored `end_at` at or beyond this threshold means the notebook has no
    /// real deadline. Both live in Portable (`LearningGoalShape`), which the
    /// phone reads its payloads through too.
    static let openEndedEndAt = Date(timeIntervalSinceReferenceDate: LearningGoalShape.openEndedEndAtReferenceSeconds) // 2100-01-01 UTC
    static let openEndedThreshold = Date(timeIntervalSinceReferenceDate: LearningGoalShape.openEndedThresholdReferenceSeconds)

    var isCompanion: Bool { kind == LearningGoalRecord.companionKind }

    /// User-written description when set.
    var displayDescription: String? {
        guard let raw = description?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// The Notebook's short description when set — the card and overview copy.
    var displaySummary: String? {
        guard let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// The linked GitHub repository as `owner/repo` when one is set; nil for
    /// both never-set and explicitly unlinked (`""`).
    var linkedRepository: String? {
        Self.normalizedRepository(repository)
    }

    /// The GitHub page of the linked repository, when one is set.
    var linkedRepositoryURL: URL? {
        linkedRepository.flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// The id of the artifact this Goal is for, or nil: both the never-set
    /// NULL and the explicit-unlink `""` read as no artifact.
    var linkedArtifactID: String? {
        guard let trimmed = artifactID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The canonical `owner/repo` for what a learner typed or pasted, or nil
    /// when it does not name a GitHub repository. The rule lives in Portable
    /// (`GitHubRepositoryName`) so the phone reads the identical form.
    static func normalizedRepository(_ raw: String?) -> String? {
        GitHubRepositoryName.normalized(raw)
    }

    var isOpenEnded: Bool {
        LearningGoalShape.isOpenEnded(kind: kind, endAtReferenceSeconds: endAt.timeIntervalSinceReferenceDate)
    }

    /// Whether a parent Notebook is named at all. The discriminator between a
    /// Notebook and a Goal is the *deadline*, not this: a Goal may name a
    /// Notebook or stand on its own.
    var hasParentNotebook: Bool {
        LearningGoalShape.namesParentNotebook(parentNotebookID)
    }

    /// A top-level Notebook: an open-ended companion record with no parent.
    /// Notebooks own a source pool and have no timeline of their own.
    ///
    /// Open-endedness is what says "Notebook", because a Goal without a Notebook
    /// is an ordinary thing to want ("I want to understand Zara's thesis work"
    /// names no source pool) and parentlessness alone can no longer tell the
    /// two apart. Schema 120 promoted every parentless companion record
    /// created before Goals shipped (2026-09-19) to `openEndedEndAt`, so a dated parentless record is a Goal the learner
    /// set and never a Notebook from an older build — including one that an
    /// older build received over sync and has yet to migrate.
    var isNotebook: Bool {
        LearningGoalShape.isNotebook(
            kind: kind,
            parentNotebookID: parentNotebookID,
            endAtReferenceSeconds: endAt.timeIntervalSinceReferenceDate
        )
    }

    /// A timebound Goal: a companion record carrying a real deadline. It may
    /// name a Notebook whose sources it draws on (`parentNotebookID`), or stand
    /// on its own. Goals carry the deadline and the day schedule.
    var isGoal: Bool {
        LearningGoalShape.isGoal(kind: kind, endAtReferenceSeconds: endAt.timeIntervalSinceReferenceDate)
    }

    /// A Goal that names no Notebook. The Goals tab lists these beside the
    /// nested ones; only the tag on the row differs.
    var isStandaloneGoal: Bool {
        isGoal && !hasParentNotebook
    }

    /// A timebound Goal nested inside a Notebook, for the places that mean the
    /// nesting itself — a Notebook's own list of Goals, and the source pool a
    /// nested Goal inherits.
    var isNotebookGoal: Bool {
        isGoal && hasParentNotebook
    }

    /// Lifecycle state. Completion is explicit state, never inferred from the
    /// deadline: an outcome Goal whose deadline passed is *overdue*, not done.
    var lifecycleStatus: LearningGoalStatus { LearningGoalStatus.parse(status) }

    var isDone: Bool { lifecycleStatus == .done }

    var isArchived: Bool { lifecycleStatus == .archived }

    /// Past its deadline with the work still open. Open-ended Notebooks (which
    /// carry the 2100 sentinel) can never be overdue.
    func isOverdue(asOf now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isCompanion, !isOpenEnded, lifecycleStatus == .active else { return false }
        return calendar.startOfDay(for: endAt) < calendar.startOfDay(for: now)
    }

    /// Days until the deadline; negative once overdue. Nil for open-ended Notebooks.
    func daysRemaining(asOf now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard isCompanion, !isOpenEnded else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: endAt)
        ).day
    }

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }

    var totalCount: Int {
        items.count
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    var isComplete: Bool {
        totalCount > 0 && completedCount == totalCount
    }

    /// Source IDs in this Notebook's pool that are approved (seeds + approved discoveries),
    /// in pool order. This is the Notebook's MCP source context. Pending/rejected
    /// discovered suggestions are excluded.
    var approvedSourceIDs: [String] {
        var seen = Set<String>()
        return items
            .filter { $0.isApproved }
            .map(\.sourceID)
            .filter { seen.insert($0).inserted }
    }
}

/// One child notebook produced by splitting a companion goal.
struct CompanionGoalSplitSpec: Equatable, Sendable {
    let title: String
    let topic: String?
    let sourceIDs: [String]
    let gapIDs: [String]
}

/// Outcome of splitting a companion goal into child notebooks. `parentGoalID`
/// is nil when the split removed the emptied parent; `heirGoalID` is then the
/// child that took everything else the parent held (its chats, Goals, tasks,
/// Docs, files and the rest), the one that took the most sources.
struct CompanionGoalSplitResult: Equatable, Sendable {
    let parentGoalID: String?
    let childGoalIDs: [String]
    var heirGoalID: String? = nil
}

/// Outcome of merging Notebooks into one survivor. The counts name what moved
/// so the learner can be told; `filesMoved` is filled in by the caller that
/// owns the workspace folders, since the store only indexes them.
struct CompanionGoalMergeResult: Equatable, Sendable {
    let survivorGoalID: String
    let mergedGoalIDs: [String]
    let sourcesAdded: Int
    let gapsAdded: Int
    var chatsMoved: Int = 0
    var childGoalsMoved: Int = 0
    var tasksMoved: Int = 0
    var docsMoved: Int = 0
    var filesMoved: Int = 0
}

/// Lightweight row describing a completed goal-linked review, for the in-app
/// Learning Companion goal dashboard (history list under the goal hero).
struct CompanionSessionSummary: Identifiable, Codable, Equatable {
    let id: String
    let endedAt: Date
    let overallScore: Double?
    let summary: String?
}


// MARK: - Drag & Drop Transfer

extension UTType {
    /// Custom UTType for dragging StudioArticle references within the app.
    static let studioArticle = UTType(exportedAs: "com.foreverlm.studio-article")
    /// Custom UTType for dragging a Doc (a Markdown artifact) within the app.
    static let studioArtifact = UTType(exportedAs: "com.foreverlm.studio-artifact")
    /// Custom UTType for dragging a source id fallback within the app.
    static let studioSourceID = UTType(exportedAs: "com.foreverlm.studio-source-id")
    /// Custom UTType for dragging a source group (book / course) within the app.
    static let studioGroup = UTType(exportedAs: "com.foreverlm.studio-group")
    /// Custom UTType for dragging source category tabs within the Studio sidebar.
    static let studioSidebarTab = UTType(exportedAs: "com.foreverlm.studio-sidebar-tab")
    /// Custom UTType for dragging saved/in-app review chat sessions within the app.
    static let reviewSession = UTType(exportedAs: "com.foreverlm.review-session")
    /// Custom UTType for reordering Notebook folders in the Studio navigation rail.
    static let studioNotebook = UTType(exportedAs: "com.foreverlm.studio-notebook")
    /// Custom UTType for reordering Goal rows in the Goals tab, distinct from
    /// the source types a row also takes so a row dropped on a row is a move
    /// and never a source drop.
    static let studioGoal = UTType(exportedAs: "com.foreverlm.studio-goal")
    /// Custom UTType for a clip dragged out of the Reader's PDF: a box round
    /// part of a page, with the source and page it came from
    /// (`StudioClipTransfer`).
    static let studioClip = UTType(exportedAs: "com.foreverlm.studio-clip")
    /// Custom UTType for a card dragged out of the Canvas's Library sidebar or
    /// its add box: the refs of the cards, so the plane sets down exactly
    /// those (`KnowledgeMapCardTransfer`). It rides beside the card's own drag
    /// (a source's, a Doc's, a clip's), which a chat or an Idea still takes.
    static let knowledgeMapCard = UTType(exportedAs: "com.foreverlm.canvas-card")
    /// Custom UTType for a Space place dragged onto the icon strip, which
    /// keeps it there as a shortcut (`StudioRailShortcut`): its key.
    static let studioRailShortcut = UTType(exportedAs: "com.foreverlm.studio-rail-shortcut")
    /// Custom UTType for an icon of the strip dragged up or down its group
    /// to reorder it (`StudioStripEntry`): its key.
    static let studioStripEntry = UTType(exportedAs: "com.foreverlm.studio-strip-entry")
    /// Custom UTType for a row of a notebook's Studio column dragged onto a
    /// pane, which opens that output there (`NotebookOutputDragPayload`): a
    /// token naming the output, read back in this process only.
    static let notebookOutput = UTType(exportedAs: "com.foreverlm.notebook-output")
    /// Custom UTType for a row of the Space sidebar's Pinned dragged onto
    /// another to reorder the pins (`PagePins.rowsAfterMoving`): its id.
    static let spacePin = UTType(exportedAs: "com.foreverlm.space-pin")
    /// Custom UTType for a Board card dragged to another column or another
    /// place in its column (`SpaceBoardDrop`): the task's id.
    static let boardCard = UTType(exportedAs: "com.foreverlm.board-card")
    /// Finder-style web location files for dragging URL-only sources to external apps.
    static let webInternetLocation = UTType(filenameExtension: "webloc")
        ?? UTType(importedAs: "com.apple.web-internet-location")
    /// Kindle ebook files imported through the existing EPUB book pipeline after conversion.
    static let kindleAZW = UTType(filenameExtension: "azw") ?? UTType(importedAs: "com.amazon.azw")
    static let kindleAZW3 = UTType(filenameExtension: "azw3") ?? UTType(importedAs: "com.amazon.azw3")
    static let kindleMOBI = UTType(filenameExtension: "mobi") ?? UTType(importedAs: "com.amazon.mobi")
    static let kindlePRC = UTType(filenameExtension: "prc") ?? UTType(importedAs: "com.mobipocket.prc")
}

/// Info about a matching podcast episode found via the iTunes Search API.
struct PodcastMatchInfo: Codable, Equatable {
    let podcastName: String
    let episodeTitle: String
    let applePodcastsURL: String
}

/// Transfer payload for dragging articles within the app and to external apps.
/// The codable representation handles in-app drops (tabs, MCP tray, course groups).
/// The file representation lets users drag sources into browsers (Claude, ChatGPT)
/// as if dragging from Finder — PDFs for papers/books, .txt for text content.
struct StudioArticleTransfer: Codable, Transferable {
    let articleId: String
    var articleIds: [String]?
    let title: String
    let sourceType: String
    /// Source URL for URL-only sources. Excluded from in-app codable transfers.
    var url: String?
    /// Local file path for PDF sources (papers, book chapters). Not included in
    /// the codable representation sent to in-app drop targets.
    var localFilePath: String?
    /// Text content for non-paper sources (transcripts, articles). Excluded from
    /// the codable representation to keep in-app transfers lightweight.
    var content: String?

    enum CodingKeys: String, CodingKey {
        case articleId, articleIds, title, sourceType
    }

    static var transferRepresentation: some TransferRepresentation {
        // In-app drops: lightweight JSON with just id/title/sourceType
        CodableRepresentation(contentType: .studioArticle)
        // External apps: actual PDF file for papers/books with a local PDF
        FileRepresentation(exportedContentType: .pdf) { transfer in
            guard let path = transfer.localFilePath,
                  path.lowercased().hasSuffix(".pdf"),
                  let resolved = SourceService.resolveLocalFileURL(path),
                  FileManager.default.fileExists(atPath: resolved.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SentTransferredFile(resolved)
        }
        // External apps: temp .txt for text content (transcripts, articles)
        FileRepresentation(exportedContentType: .plainText) { transfer in
            guard transfer.localFilePath == nil || !transfer.localFilePath!.lowercased().hasSuffix(".pdf"),
                  transfer.sourceType != "paper",
                  let content = transfer.content, !content.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            let sanitized = String(transfer.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: " -")
                .prefix(80))
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized).txt")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return SentTransferredFile(tempURL)
        }
        // External apps: Finder-style .webloc for URL-only web sources.
        FileRepresentation(exportedContentType: .webInternetLocation) { transfer in
            guard transfer.localFilePath == nil,
                  let url = transfer.url,
                  url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let sanitized = String(transfer.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: " -")
                .prefix(80))
            let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>URL</key>\n\t<string>\(url)</string>\n</dict>\n</plist>"
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized).webloc")
            try plist.write(to: tempURL, atomically: true, encoding: .utf8)
            return SentTransferredFile(tempURL)
        }
    }

    init(from article: StudioArticle) {
        self.articleId = article.id
        self.articleIds = nil
        self.title = article.title
        self.sourceType = article.sourceType.rawValue
        self.url = article.url
        self.localFilePath = article.localFilePath
        self.content = article.content
    }

    init(articleId: String, articleIds: [String], title: String, sourceType: String) {
        self.articleId = articleId
        self.articleIds = articleIds
        self.title = title
        self.sourceType = sourceType
        self.url = nil
        self.localFilePath = nil
        self.content = nil
    }

    /// The payload for a drag that starts on `article` and carries `draggedIDs`.
    ///
    /// One source travels with its file and URL representations so external
    /// apps can take it. Several travel as the id list alone; the row under the
    /// pointer stays `articleId` for destinations that only take one.
    static func dragging(_ article: StudioArticle, draggedIDs: [String]) -> StudioArticleTransfer {
        var ids = draggedIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if ids.isEmpty { ids = [article.id] }
        guard ids.count > 1 else { return StudioArticleTransfer(from: article) }
        return StudioArticleTransfer(
            articleId: article.id,
            articleIds: ids,
            title: "\(ids.count) sources",
            sourceType: "selection"
        )
    }

    /// Every source this drag picked up, in the order the learner saw them.
    ///
    /// This is the snapshot a destination must act on. List selection and
    /// modifier flags can change while AppKit owns the drag, so a destination
    /// that consults their live values silently collapses a multi-source drop
    /// to the row under the pointer.
    var draggedSourceIDs: [String] {
        if let articleIds, !articleIds.isEmpty { return articleIds }
        return [articleId]
    }
}

/// Transfer payload for dragging a source group (book / course) into planning surfaces.
/// Source IDs are captured when the drag starts so a whole group can be dropped without
/// depending on its name still resolving to the same live view-model state.
struct StudioGroupTransfer: Codable, Transferable {
    let groupName: String
    let sourceIDs: [String]?

    init(groupName: String, sourceIDs: [String]? = nil) {
        self.groupName = groupName
        self.sourceIDs = sourceIDs
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioGroup)
    }
}

/// Transfer payload for reordering a Notebook folder in the Studio navigation rail.
/// Identity stays deterministic: the payload carries only the stored Notebook id.
struct StudioNotebookTransfer: Codable, Transferable {
    let notebookID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioNotebook)
    }
}

/// The cards a Canvas Library or add-box row carries to the plane
/// (`UTType.knowledgeMapCard`, own process only): item refs such as
/// `source:<id>` or `idea:<id>`. A Canvas takes the ones its cards know.
struct KnowledgeMapCardTransfer: Codable, Equatable {
    var refs: [String]
}

/// A Goal row on its way to another row's place in the Goals tab.
struct StudioGoalTransfer: Codable, Transferable {
    let goalID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioGoal)
    }
}

/// Transfer payload for dragging a Doc out of the Docs list.
///
/// A chat the doc lands on attaches it by identity, the way the row's "Add to
/// Chat" item does, so the payload carries only the id and the title the drop
/// target names it by — never the body, which `read_doc` reads back from
/// the stored revision.
struct StudioArtifactTransfer: Codable, Transferable, Equatable {
    let artifactID: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioArtifact)
    }
}

/// Transfer payload for dragging a review chat/session into planning surfaces.
struct ReviewSessionTransfer: Codable, Transferable {
    let sessionID: String
    let title: String
    let sourceIDs: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reviewSession)
    }

    init(sessionID: String, title: String, sourceIDs: [String]) {
        self.sessionID = sessionID
        self.title = title
        self.sourceIDs = sourceIDs
    }

    init(from session: ReviewSessionRecord) {
        self.sessionID = session.id
        self.title = session.title
        self.sourceIDs = session.sourceIDs
    }
}

/// Metadata for a podcast episode looked up from the Apple Podcasts SQLite database.
struct PodcastEpisodeMetadata {
    /// Apple Podcasts public store episode ID. Private RSS feed episodes often store 0 here.
    let storeTrackId: Int64?
    /// Apple Podcasts local episode UUID, used as a stable non-secret ID for private RSS feed episodes.
    let episodeUUID: String?
    /// RSS item GUID. May contain private-feed tokens, so it should not be persisted directly.
    let episodeGUID: String?
    let episodeTitle: String
    let podcastName: String
    let artworkURL: String?
    /// Web page URL for the episode (e.g. Substack post, show notes page)
    let webPageURL: String?
    /// Plain-text or HTML episode notes from Apple Podcasts.
    let episodeDescription: String?
    /// Episode audio/enclosure URL. Private feeds may contain signed URLs, so persist only hashed forms.
    let enclosureURL: String?
    /// Relative TTML transcript path within the Apple Podcasts cache
    let ttmlIdentifier: String?
    /// Core Data timestamp of when the episode was last played
    let lastDatePlayed: Date?
    /// Apple Podcasts store collection ID for the parent podcast (used to construct Apple Podcasts URLs)
    let podcastCollectionId: Int64?
    /// When the episode was published, from the feed. An episode the learner
    /// never played takes this as its date in the library, so a back catalog
    /// sorts in episode order rather than by the minute it was imported.
    var publishedAt: Date? = nil
}

/// A play Apple Podcasts saw, as podcast discovery hands it to the store to
/// record as listening (`KnowledgeStore.recordExternalListening`).
struct ExternalListen: Equatable, Sendable {
    /// The episode's library URL, as discovery mints it (`SourceDiscovery.podcastEpisodeURL`).
    let url: String
    let title: String
    let showName: String
    /// Apple's `ZLASTDATEPLAYED`: the moment of the episode's last play.
    let playedAt: Date
}

/// Describes why Apple Podcasts discovery returned no results,
/// so the UI can guide the user instead of showing a silent empty state.
enum PodcastDiscoveryStatus: Equatable {
    /// Discovery succeeded (may still have zero episodes if none are played)
    case ok
    /// Not running on macOS — Apple Podcasts DB is macOS-only
    case unsupportedPlatform
    /// Apple Podcasts is not installed (database file missing)
    case appNotInstalled
    /// Database exists but macOS denied access to it.
    case permissionDenied
    /// Database exists but SQLite could not open it for a non-permission reason.
    case openFailed(details: String)
    /// Database opened but expected tables/columns are missing (Apple changed the schema)
    case schemaChanged(details: String)
    /// Query executed but returned zero rows
    case noEpisodesFound
}

extension Notification.Name {
    /// Posted by `StudioArticle.invalidateAllResolvedPathCaches()`, on whatever
    /// thread cleared the cache. The view model answers by warming it again.
    static let resolvedPathCacheDidClear = Notification.Name("ForeverLM.resolvedPathCacheDidClear")
}
