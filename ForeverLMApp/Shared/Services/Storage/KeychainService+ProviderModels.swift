// AI provider and per-provider model preferences.

import Foundation

extension KeychainService {
    private static let defaultAnthropicModel = AIModelDefaults.defaultAnthropic

    /// The persisted Anthropic default before Sonnet 5. Installs from that era have
    /// this stored in the keychain, which would shadow the new default forever.
    private static let retiredAnthropicDefaultModel = "claude-sonnet-4-6"

    /// Set once the user explicitly picks an Anthropic model, so a deliberate
    /// re-pick of the retired default is honored instead of remapped.
    private static let defaultOpenAIModel = AIModelDefaults.defaultOpenAI

    /// The persisted OpenAI default before GPT-5.6 — same shadowing problem as
    /// the retired Anthropic default above, and no longer offered in pickers.
    private static let retiredOpenAIDefaultModel = "gpt-5.5"

    private static let defaultGroqModel = "openai/gpt-oss-120b"

    private static let defaultCerebrasModel = "gpt-oss-120b"

    private static let defaultXAIModel = "grok-4.3"

    private static let defaultGeminiModel = AIModelDefaults.defaultGemini

    private static let defaultMetaModel = AIModelDefaults.latestMuseSpark

    private static let defaultTogetherModel = AIModelDefaults.defaultTogether

    private static let defaultFireworksModel = AIModelDefaults.defaultFireworks

    private static let defaultNVIDIAModel = AIModelDefaults.defaultNVIDIA

    private static let defaultOpenRouterModel = AIModelDefaults.openRouterFreeRouter

    private static let defaultOpenAITranscriptionModel = AIModelDefaults.batchTranscription

    private static let defaultGroqTranscriptionModel = "whisper-large-v3-turbo"

    private static let defaultOpenRouterTranscriptionModel = "nvidia/parakeet-tdt-0.6b-v3"

    /// Batch media defaults to the same model dictation uses, so an existing
    /// install keeps behaving exactly as it did until the learner picks
    /// something else for recordings.
    private static let defaultMediaTranscriptionModel = AIModelDefaults.batchTranscription

    /// Raw stored string to a provider case, before any retirement filtering.
    private static func decodeProvider(_ raw: String) -> AIProvider {
        switch raw {
        case "anthropic": return .anthropic
        case "openai": return .openai
        case "groq": return .groq
        case "cerebras": return .cerebras
        case "xai": return .xai
        case "gemini": return .gemini
        case "meta": return .meta
        case "together": return .together
        case "fireworks": return .fireworks
        case "nvidia": return .nvidia
        case "openrouter": return .openRouter
        default: return .anthropic
        }
    }

    static var aiProvider: AIProvider {
        get {
            if let route = storedRoute(Prefs.Models.defaultChatRoute),
               let provider = AIProvider(rawValue: route.provider) {
                return provider
            }
            // This is the Chat (review) default. Unset it is OpenRouter's Free
            // Models Router, so a new learner's first chat costs nothing; a
            // stored "appleIntelligence" and unknown values map to Anthropic. Without a managed Apple
            // session, resolveConfig returns nil and the review UI asks the user
            // to sign in instead of silently degrading.
            guard let raw = load(.aiProvider) else {
                return .openRouter
            }
            // Keep the stored identity visible. `resolveConfig` rejects retired
            // providers; changing the value here would silently present and run
            // a provider the learner did not select.
            let decoded = decodeProvider(raw)
            return decoded
        }
        set {
            switch newValue {
            case .anthropic: save("anthropic", for: .aiProvider)
            case .openai: save("openai", for: .aiProvider)
            case .groq: save("groq", for: .aiProvider)
            case .cerebras: save("cerebras", for: .aiProvider)
            case .xai: save("xai", for: .aiProvider)
            case .gemini: save("gemini", for: .aiProvider)
            case .meta: save("meta", for: .aiProvider)
            case .together: save("together", for: .aiProvider)
            case .fireworks: save("fireworks", for: .aiProvider)
            case .nvidia: save("nvidia", for: .aiProvider)
            case .openRouter: save("openrouter", for: .aiProvider)
            }
            // Every writer of the global text provider funnels through here, so this is
            // the one place to notify UI (assistant launcher logo, Settings text-model
            // selector) so displays can never drift out of sync with the stored value.
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    static var anthropicModel: String {
        get {
            guard let stored = load(.anthropicModel) else { return defaultAnthropicModel }
            // Same read-time mapping as `aiProvider` uses for retired values: a stored
            // copy of the retired default follows the current default (Sonnet 5)
            // unless the user explicitly picked it after this build.
            if stored == retiredAnthropicDefaultModel,
               Preferences.value(Prefs.Models.anthropicModelExplicitlyPicked) != true {
                return defaultAnthropicModel
            }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.anthropicModel) }
            else {
                save(trimmed, for: .anthropicModel)
                Preferences.set(true, for: Prefs.Models.anthropicModelExplicitlyPicked)
            }
        }
    }

    static var openAIModel: String {
        get {
            guard let stored = load(.openAIModel) else { return defaultOpenAIModel }
            // Same read-time mapping as `anthropicModel`: a stored copy of the
            // retired default follows the current default (GPT-5.6 Sol) unless
            // the user explicitly picked it after this build.
            if stored == retiredOpenAIDefaultModel,
               Preferences.value(Prefs.Models.openAIModelExplicitlyPicked) != true {
                return defaultOpenAIModel
            }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.openAIModel) }
            else {
                save(trimmed, for: .openAIModel)
                Preferences.set(true, for: Prefs.Models.openAIModelExplicitlyPicked)
            }
        }
    }

    static var groqModel: String {
        get { load(.groqModel) ?? defaultGroqModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.groqModel) }
            else { save(trimmed, for: .groqModel) }
        }
    }

    static var cerebrasModel: String {
        get { load(.cerebrasModel) ?? defaultCerebrasModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.cerebrasModel) }
            else { save(trimmed, for: .cerebrasModel) }
        }
    }

    static var xaiModel: String {
        get { load(.xaiModel) ?? defaultXAIModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.xaiModel) }
            else { save(trimmed, for: .xaiModel) }
        }
    }

    static var metaModel: String {
        get { load(.metaModel) ?? defaultMetaModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.metaModel) }
            else { save(trimmed, for: .metaModel) }
        }
    }

    static var geminiTextModel: String {
        get { load(.geminiModel) ?? defaultGeminiModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.geminiModel) }
            else { save(trimmed, for: .geminiModel) }
        }
    }

    static var togetherModel: String {
        get { load(.togetherModel) ?? defaultTogetherModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.togetherModel) }
            else { save(trimmed, for: .togetherModel) }
        }
    }

    static var fireworksModel: String {
        get { load(.fireworksModel) ?? defaultFireworksModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.fireworksModel) }
            else { save(trimmed, for: .fireworksModel) }
        }
    }

    static var nvidiaModel: String {
        get { load(.nvidiaModel) ?? defaultNVIDIAModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.nvidiaModel) }
            else { save(trimmed, for: .nvidiaModel) }
        }
    }

    static var openRouterModel: String {
        get { load(.openRouterModel) ?? defaultOpenRouterModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.openRouterModel) }
            else { save(trimmed, for: .openRouterModel) }
        }
    }

    static func model(for provider: AIProvider) -> String {
        if let route = storedRoute(Prefs.Models.defaultChatRoute),
           route.provider == provider.rawValue {
            return route.model
        }
        switch provider {
        case .anthropic: return anthropicModel
        case .openai: return openAIModel
        case .groq: return groqModel
        case .cerebras: return cerebrasModel
        case .xai: return xaiModel
        case .gemini: return geminiTextModel
        case .meta: return metaModel
        case .together: return togetherModel
        case .fireworks: return fireworksModel
        case .nvidia: return nvidiaModel
        case .openRouter: return openRouterModel
        }
    }

    static func setModel(_ model: String, for provider: AIProvider) {
        switch provider {
        case .anthropic: anthropicModel = model
        case .openai: openAIModel = model
        case .groq: groqModel = model
        case .cerebras: cerebrasModel = model
        case .xai: xaiModel = model
        case .gemini: geminiTextModel = model
        case .meta: metaModel = model
        case .together: togetherModel = model
        case .fireworks: fireworksModel = model
        case .nvidia: nvidiaModel = model
        case .openRouter: openRouterModel = model
        }
    }

    static var openAITranscriptionModel: String {
        get { load(.sttModelOpenAI) ?? defaultOpenAITranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelOpenAI) }
            else { save(trimmed, for: .sttModelOpenAI) }
        }
    }

    /// Model for batch media transcription — meeting recordings and podcast
    /// episodes — kept separate from dictation on purpose. Dictation is a few
    /// seconds of one clear voice and wants the fastest model; a recording is
    /// an hour of several people, crosstalk, and domain vocabulary, and is
    /// worth paying more per minute to get right. One setting could not serve
    /// both without making one of them wrong.
    static var mediaTranscriptionModel: String {
        get {
            load(.sttModelMedia) ?? defaultMediaTranscriptionModel
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelMedia) }
            else { save(trimmed, for: .sttModelMedia) }
        }
    }

    static var groqTranscriptionModel: String {
        get { load(.sttModelGroq) ?? defaultGroqTranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelGroq) }
            else { save(trimmed, for: .sttModelGroq) }
        }
    }

    static var openRouterTranscriptionModel: String {
        get { load(.sttModelOpenRouter) ?? defaultOpenRouterTranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelOpenRouter) }
            else { save(trimmed, for: .sttModelOpenRouter) }
        }
    }

    /// The slot batch speech-to-text is stored under (`stt_model_openai`, a
    /// name kept for the stored rows). Whatever it holds is an OpenRouter
    /// model and goes to OpenRouter (`ManagedTranscriptionClient.route`).
    static var speechToTextProvider: SpeechToTextProvider { .openai }

    static func transcriptionModel(for provider: SpeechToTextProvider) -> String {
        let stored: String
        switch provider {
        case .groq: stored = groqTranscriptionModel
        case .openai: stored = openAITranscriptionModel
        case .openRouter: stored = openRouterTranscriptionModel
        }
        return stored
    }

    static func setTranscriptionModel(_ model: String, for provider: SpeechToTextProvider) {
        switch provider {
        case .groq: groqTranscriptionModel = model
        case .openai: openAITranscriptionModel = model
        case .openRouter: openRouterTranscriptionModel = model
        }
    }

    /// True when requests to this provider can succeed through managed AI.
    static func hasUsableTextProviderCredentials(for provider: AIProvider) -> Bool {
        return ManagedAI.isSignedIn && AIProvider.activeChatProviders.contains(provider)
    }

    /// API key for a specific provider.
    static func apiKey(for provider: AIProvider) -> String? {
        return ManagedAI.isSignedIn && AIProvider.activeChatProviders.contains(provider) ? "" : nil
    }
}
