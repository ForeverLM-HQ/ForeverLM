// AI providers, model names, routes, effort and speed, moved out of Models.swift.

import Foundation

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
        "claude-fable-5-2": "Fable 5.2",
        "claude-fable-5-1": "Fable 5.1",
        "claude-fable-5": "Fable 5",
        "claude-sonnet-5-5": "Sonnet 5.5",
        "claude-sonnet-5": "Sonnet 5",
        "claude-haiku-5-5": "Haiku 5.5",
        "claude-haiku-4-5": "Haiku 4.5",
        "claude-sonnet-4": "Sonnet 4.6",
        "claude-sonnet-4-5": "Sonnet 4.5",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-opus-4": "Opus 4.8",
        "claude-opus-5-5": "Opus 5.5",
        "claude-opus-5": "Opus 5",
        "claude-opus-4-1": "Opus 4.1",
        "claude-opus-4-5": "Opus 4.5",
        "claude-opus-4-6": "Opus 4.6",
        "claude-opus-4-7": "Opus 4.7",
        "claude-opus-4-8": "Opus 4.8",
        "claude-3-5-haiku": "3.5 Haiku",
        "claude-3-5-sonnet": "3.5 Sonnet",
        "claude-3-7-sonnet": "3.7 Sonnet",
        "gpt-6.2-astra": "GPT-6.2 Astra",
        "gpt-6.2-sol": "GPT-6.2 Sol",
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
        "gemini-3.8-flash": "Gemini 3.8 Flash",
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
/// via `provider.order`, and `ultrafast` to the faster one above it
/// (`openai/ultrafast`, three times the standard price on GPT-6.2 Sol); see
/// `OpenRouterSpeedTier`. The direct first-party
/// rails offer no speed until their premium tiers are on the managed rate card.
/// Declared cheapest-and-slowest first: the Speed menu lists cases in this
/// order, so a learner reads it as a price ladder.
enum AISpeed: String, CaseIterable, Codable, Identifiable {
    /// OpenAI's Flex service tier: lower priority, about half the price.
    case flex
    case standard
    case fast
    case ultrafast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flex: return "Flex"
        case .standard: return "Standard"
        case .fast: return "Fast"
        case .ultrafast: return "Ultrafast"
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
