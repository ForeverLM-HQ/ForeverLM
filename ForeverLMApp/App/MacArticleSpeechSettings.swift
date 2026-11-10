#if os(macOS)
import AVFoundation
import Foundation

enum MacArticleSpeechMode: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case groq = "groq"
    case openAI = "openai"
    case togetherAI = "together"
    case elevenLabs = "elevenlabs"
    case xai = "xai"
    case gemini = "gemini"
    case localQwen3 = "local_qwen3"
    case apple = "apple"

    var id: String { rawValue }

    /// Providers offered in the macOS picker.
    ///
    /// The unified catalog remains the only picker surface, and every model in
    /// it, Grok and Gemini included, is served by OpenRouter
    /// (`ArticleSpeechCatalog`). The legacy provider modes are not
    /// independently selectable. Their enum cases remain for the playback
    /// paths that still reference them, and the underlying persisted case name
    /// is retained for manifest and preference compatibility.
    ///
    /// Apple on-device and the local Qwen3 server stay excluded as before.
    /// Older stored providers remain readable so their failure is explicit;
    /// they are never rewritten to OpenRouter behind the listener's back.
    static var selectableCases: [MacArticleSpeechMode] {
        [.openRouter]
    }

    var label: String {
        switch self {
        case .openRouter: return "Model Provider"
        case .groq: return "Groq"
        case .openAI: return "OpenAI"
        case .togetherAI: return "Together AI"
        case .elevenLabs: return "ElevenLabs"
        case .xai: return "xAI"
        case .gemini: return "Gemini"
        case .localQwen3: return "Local"
        case .apple: return "On Device"
        }
    }

    var toolbarLabel: String {
        switch self {
        case .openRouter: return "Provider TTS"
        case .groq: return "Groq TTS"
        case .openAI: return "OpenAI TTS"
        case .togetherAI: return "Together AI TTS"
        case .elevenLabs: return "ElevenLabs TTS"
        case .xai: return "xAI TTS"
        case .gemini: return "Gemini TTS"
        case .localQwen3: return "Local TTS"
        case .apple: return "On Device"
        }
    }

    var menuLabel: String {
        switch self {
        case .openRouter: return "Model Provider"
        case .groq: return "Groq"
        case .openAI: return "OpenAI"
        case .togetherAI: return "Together AI"
        case .elevenLabs: return "ElevenLabs"
        case .xai: return "xAI"
        case .gemini: return "Gemini"
        case .localQwen3: return "Local (free)"
        case .apple: return "On Device (free)"
        }
    }

    var systemImage: String {
        switch self {
        case .openRouter: return "arrow.triangle.branch"
        case .groq: return "bolt.fill"
        case .openAI: return "dollarsign.circle"
        case .togetherAI: return "sparkles"
        case .elevenLabs: return "person.wave.2"
        case .xai: return "x.circle"
        case .gemini: return "sparkle"
        case .localQwen3: return "server.rack"
        case .apple: return "macbook"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .openRouter: return "OpenRouterIcon"
        case .groq: return "GroqIcon"
        case .openAI: return "OpenAIIcon"
        case .togetherAI: return "TogetherAIIcon"
        case .elevenLabs: return "ElevenLabsIcon"
        case .xai: return "XAIIcon"
        case .gemini: return "GeminiIcon"
        case .localQwen3: return nil
        case .apple: return nil
        }
    }

    var isCloudProvider: Bool {
        self != .apple
    }
}

enum MacArticleSpeechSpeed {
    static let options: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let defaultSpeed = 1.0
    static let minimum = 0.25
    static let maximum = 2.0
    private static let defaultsKey = "macos.tts.speed"

    static var stored: Double {
        get {
            let storedSpeed = UserDefaults.standard.object(forKey: defaultsKey) as? Double
            return clamped(storedSpeed ?? defaultSpeed)
        }
        set {
            PreferenceStore.set(clamped(newValue), forKey: defaultsKey)
        }
    }

    static func clamped(_ speed: Double) -> Double {
        min(max(speed, minimum), maximum)
    }

    static func isSelected(_ stored: Double, option: Double) -> Bool {
        abs(stored - clamped(option)) < 0.001
    }

    static func nextOption(after current: Double) -> Double {
        let value = clamped(current)
        guard let index = options.firstIndex(where: { isSelected(value, option: $0) }) else {
            return defaultSpeed
        }
        let nextIndex = (index + 1) % options.count
        return options[nextIndex]
    }

    static func label(for speed: Double) -> String {
        let value = clamped(speed)
        if value.rounded() == value {
            return "\(Int(value))x"
        }
        var formatted = String(format: "%.2f", value)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return "\(formatted)x"
    }
}

enum MacArticleSpeechSleepTimer {
    static let options: [TimeInterval] = [5, 10, 15, 30, 45, 60].map { TimeInterval($0 * 60) }

    static func label(for duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        return "\(minutes) min"
    }

    static func remainingLabel(for seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let minutes = total / 60
        let secs = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, secs)
        }
        return "\(secs)s"
    }
}

enum MacArticleSpeechText {
    static func speakableInput(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsLetterOrDigit(trimmed) else { return nil }
        return trimmed
    }

    static func containsLetterOrDigit(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }

    /// PDF (and some HTML) extractors emit a hard line break at every visual line
    /// end, so a single sentence arrives split across several lines. Feeding those
    /// breaks straight to the chunker turns each wrapped line into its own utterance,
    /// which the TTS voice reads with an audible stop mid-sentence. Rejoin
    /// soft-wrapped lines into flowing paragraphs — de-hyphenating words that were
    /// broken across a line — while preserving genuine paragraph breaks (a blank
    /// line between blocks of text).
    static func reflowedForSpeech(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"),
                      let previous = current.dropLast().last, previous.isLetter,
                      let first = line.first, first.isLowercase {
                // A word hyphenated across the line break (e.g. "abroga-\ntion"):
                // drop the trailing hyphen and join tight so it reads as one word.
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    /// Split a paragraph into sentences so the chunker can break on sentence
    /// boundaries. Keeps common abbreviations, initials, and decimals from being
    /// mistaken for sentence ends (which would drop a pause into the middle of one).
    static func sentences(in paragraph: String) -> [String] {
        let characters = Array(paragraph)
        let terminators: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»"]

        var result: [String] = []
        var start = 0
        var index = 0

        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }

            var end = index + 1
            while end < characters.count, closers.contains(characters[end]) {
                end += 1
            }

            let atParagraphEnd = end >= characters.count
            let followedByWhitespace = !atParagraphEnd && characters[end].isWhitespace
            guard atParagraphEnd || followedByWhitespace else {
                index += 1
                continue
            }

            if characters[index] == ".", isNonTerminatingPeriod(characters, at: index) {
                index += 1
                continue
            }

            let sentence = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            start = end
            index = end
        }

        let tail = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [paragraph] : result
    }

    private static let sentenceAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "al", "fig", "figs",
        "eq", "eqs", "no", "vol", "pp", "ca", "approx", "cf", "ref", "refs",
        "dept", "inc", "ltd", "jr", "sr", "gen", "col", "sec", "min", "max", "est"
    ]

    /// A period that ends an abbreviation, an initial, or sits inside/after a number
    /// (e.g. "Fig.", "e.g.", "J. Doe", "1." list markers, "3.14") is not a sentence end.
    private static func isNonTerminatingPeriod(_ characters: [Character], at index: Int) -> Bool {
        // A digit immediately before the period covers decimals and list markers.
        if index > 0, characters[index - 1].isNumber { return true }

        var cursor = index - 1
        var token = ""
        while cursor >= 0, characters[cursor].isLetter {
            token.insert(characters[cursor], at: token.startIndex)
            cursor -= 1
        }
        // A single trailing letter is an initial ("J.") or the tail of "e.g."/"i.e.".
        if token.count == 1 { return true }
        return sentenceAbbreviations.contains(token.lowercased())
    }

    // MARK: - Audiobook narration cleanup

    /// Narration is lossless. Meaning-sensitive condensation belongs in a
    /// configurable AI preparation task, not hand-written text rules.
    static func narrationText(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Papers keep substantive figure captions in their canonical content for
    /// knowledge features, but listening should flow through the prose rather
    /// than narrating descriptions of visuals the listener cannot see.
    static func paperNarrationText(from raw: String) -> String {
        narrationText(from: raw)
    }
}

/// Every storage-backed text-to-speech setting, read in one pass so the read can
/// happen off the main thread.
///
/// `MacArticleSpeechSettings.provider` and the per-provider voices resolve
/// through `KeychainService`, and a Keychain read can block indefinitely:
/// `SecItemCopyMatching` on a vault item with a code-signing ACL raises a
/// system authorization dialog, which a launching app has no window to answer.
/// Reading these while SwiftUI evaluates a view body froze the app before its
/// first paint, so `ArticleSpeechService` seeds the product defaults and adopts
/// this snapshot afterwards. Nothing on a render path may read them directly.
struct MacArticleSpeechConfiguration: Sendable {
    var provider: MacArticleSpeechMode
    var voice: String

    /// Can block. Read it from a detached task on any path that must not stall
    /// — launch above all. The one main-actor caller is the refresh at the start
    /// of a listening session, where the vault is already cached in memory and
    /// narrating with a stale provider would be the worse failure.
    static func loadStored() -> MacArticleSpeechConfiguration {
        let provider = MacArticleSpeechSettings.provider
        return MacArticleSpeechConfiguration(
            provider: provider,
            voice: MacArticleSpeechSettings.voice(for: provider)
        )
    }
}

enum MacArticleSpeechSettings {
    /// Product default for a provider that has never been chosen. Shared by
    /// `provider`'s fallback and by the value `ArticleSpeechService` seeds
    /// before it can read storage, so the two cannot drift.
    static let defaultProvider: MacArticleSpeechMode = .openRouter
    // Orpheus is expressive on short samples but resets its prosody every ~180
    // characters. Long-form narration defaults to Gemini so several paragraphs
    // can share one synthesis context.
    static let defaultOpenRouterModel = ArticleSpeechCatalog.defaultModelID
    static let defaultOpenRouterVoice = ArticleSpeechCatalog.defaultVoiceID
    static let defaultGroqModel = "canopylabs/orpheus-v1-english"
    static let defaultGroqVoice = "autumn"
    static let defaultOpenAIModel = "gpt-4o-mini-tts"
    static let defaultOpenAIVoice = "sage"
    static let defaultTogetherAIModel = "canopylabs/orpheus-3b-0.1-ft"
    static let defaultTogetherAIVoice = "tara"
    static let defaultElevenLabsModel = "eleven_multilingual_v2"
    static let defaultElevenLabsVoice = "JBFqnCBsd6RMkjVDRZzb"
    static let defaultXAIModel = "xai-tts"
    static let defaultXAIVoice = "eve"
    static let defaultGeminiModel = "gemini-3.1-flash-tts-preview"
    static let defaultGeminiVoice = "Kore"
    static let defaultLocalQwen3Model = "qwen3-tts"
    static let defaultLocalQwen3Voice = "Ryan"
    static let defaultLocalQwen3ServerURL = "http://127.0.0.1:8000"
    static let openAIInstructionsDefaultsKey = "macos.tts.openai.instructions"
    static let localQwen3InstructionsDefaultsKey = "macos.tts.local_qwen3.instructions"
    // Shared with the phone, which reads and writes the same account row.
    private static let openRouterVoiceDefaultsKey = ArticleSpeechSelection.syncedVoiceKey
    private static let confirmCostBeforeListeningDefaultsKey = "macos.tts.confirmCostBeforeListening"
    private static let appleVoiceDefaultsKey = "macos.tts.apple.voiceIdentifier"
    private static let groqVoiceDefaultsKey = "macos.tts.groq.voice"
    private static let openAIVoiceDefaultsKey = "macos.tts.openai.voice"
    private static let togetherAIVoiceDefaultsKey = "macos.tts.together.voice"
    private static let elevenLabsVoiceDefaultsKey = "macos.tts.elevenlabs.voice"
    private static let xaiVoiceDefaultsKey = "macos.tts.xai.voice"
    private static let geminiVoiceDefaultsKey = "macos.tts.gemini.voice"
    private static let localQwen3VoiceDefaultsKey = "macos.tts.local_qwen3.voice"

    static let openAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "fable", "nova",
        "onyx", "sage", "shimmer", "verse", "marin", "cedar"
    ]
    private static let legacyOpenAIVoices = [
        "alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"
    ]
    static let groqOrpheusEnglishVoices = ["autumn", "diana", "hannah", "austin", "daniel", "troy"]
    static let togetherAIOrpheusVoices = ["tara", "leah", "jess", "leo", "dan", "mia", "zac", "zoe"]
    static let togetherAICartesiaVoices = [
        "laidback woman", "friendly sidekick", "nonfiction man", "reading lady",
        "newsman", "calm lady", "wise man", "helpful woman"
    ]
    static let togetherAIRimeMistVoices = [
        "cove", "lagoon", "mari", "moon", "moraine", "peak",
        "summit", "talon", "thunder", "tundra", "wildflower"
    ]
    static let togetherAIRimeArcanaVoices = [
        "albion", "arcade", "astra", "atrium", "bond", "cupola", "eliphas",
        "estelle", "eucalyptus", "fern", "lintel", "luna", "lyra", "marlu",
        "masonry", "moss", "oculus", "parapet", "pilaster", "sirius",
        "stucco", "transom", "truss", "vashti", "vespera", "walnut"
    ]
    static let togetherAIMinimaxVoices = [
        "English_DeterminedMan", "English_Diligent_Man", "English_expressive_narrator",
        "English_FriendlyNeighbor", "English_Graceful_Lady", "Japanese_GentleButler"
    ]
    static var xaiVoices: [String] { ArticleSpeechCatalog.grokVoices.map(\.id) }

    /// The speech catalog, read from `ArticleSpeechCatalog` so the Mac and the
    /// iPhone offer exactly the same models and voices: every model
    /// OpenRouter's speech directory lists, each requested from OpenRouter.
    /// This enum still owns the Mac's *stored selection*; the catalog owns what
    /// may be selected.
    static var openRouterModels: [String] { ArticleSpeechCatalog.models.map(\.id) }

    static func isRetiredModel(_ model: String) -> Bool {
        ArticleSpeechCatalog.isRetiredModel(model)
    }

    static func openRouterVoices(for model: String) -> [String] {
        ArticleSpeechCatalog.voices(forModel: model).map(\.id)
    }

    /// Locale-aware label for an OpenRouter voice in the settings picker.
    static func openRouterVoiceLabel(model: String, voice: String) -> String {
        ArticleSpeechCatalog.voiceSettingsLabel(model: model, voice: voice)
    }

    /// Gemini TTS prebuilt voices (shared across all Gemini TTS models).
    static var geminiVoices: [String] { ArticleSpeechCatalog.geminiVoices.map(\.id) }

    static func xaiVoiceLabel(for voice: String) -> String {
        switch voice.lowercased() {
        case "eve": return "Eve"
        case "ara": return "Ara"
        case "rex": return "Rex"
        case "sal": return "Sal"
        case "leo": return "Leo"
        default: return voice.capitalized
        }
    }

    static let elevenLabsVoicePresets: [(name: String, id: String)] = [
        ("George", "JBFqnCBsd6RMkjVDRZzb"),
        ("Rachel", "21m00Tcm4TlvDq8ikWAM"),
        ("Domi", "AZnzlk1XvdvUeBnXmlld"),
        ("Bella", "EXAVITQu4vr4xnSDxMaL"),
        ("Antoni", "ErXwobaYiN019PkySvjV"),
        ("Elli", "MF3mGyEYCl7XYWbV9V6O"),
        ("Josh", "TxGEqnHWrfWFTfGW9XjX"),
        ("Arnold", "VR6AewLTigWG4xSOukaG"),
        ("Adam", "pNInz6obpgDQGcFmaJgB"),
        ("Sam", "yoZ06aMxZJJ28mfd3POQ")
    ]

    static func preferredModels(for provider: MacArticleSpeechMode) -> [String] {
        switch provider {
        case .openRouter:
            return openRouterModels
        case .groq:
            return [defaultGroqModel]
        case .openAI:
            return [defaultOpenAIModel, "tts-1", "tts-1-hd"]
        case .togetherAI:
            return [
                defaultTogetherAIModel,
                "cartesia/sonic-3.5",
                "cartesia/sonic-3",
                "cartesia/sonic-2",
                "cartesia/sonic"
            ]
        case .elevenLabs:
            return [
                defaultElevenLabsModel,
                "eleven_flash_v2_5",
                "eleven_turbo_v2_5",
                "eleven_flash_v2",
                "eleven_turbo_v2",
                "eleven_v3"
            ]
        case .xai:
            return [defaultXAIModel]
        case .gemini:
            return [
                defaultGeminiModel,
                "gemini-2.5-flash-preview-tts",
                "gemini-2.5-pro-preview-tts"
            ]
        case .localQwen3:
            return [
                defaultLocalQwen3Model,
                "tts-1",
                "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
                "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
            ]
        case .apple:
            return ["AVSpeech"]
        }
    }

    static func openAIVoices(for model: String) -> [String] {
        if model == "tts-1" || model == "tts-1-hd" {
            return legacyOpenAIVoices
        }
        return openAIVoices
    }

    static func voices(for provider: MacArticleSpeechMode, model: String) -> [String] {
        switch provider {
        case .openRouter:
            return openRouterVoices(for: model)
        case .groq:
            return groqOrpheusEnglishVoices
        case .openAI:
            return openAIVoices(for: model)
        case .togetherAI:
            if model.hasPrefix("cartesia/") {
                return togetherAICartesiaVoices
            }
            if model.hasPrefix("rime-labs/rime-mist") {
                return togetherAIRimeMistVoices
            }
            if model.hasPrefix("rime-labs/rime-arcana") {
                return togetherAIRimeArcanaVoices
            }
            if model.hasPrefix("minimax/") {
                return togetherAIMinimaxVoices
            }
            return togetherAIOrpheusVoices
        case .elevenLabs:
            return elevenLabsVoicePresets.map(\.id)
        case .xai:
            return xaiVoices
        case .gemini:
            return geminiVoices
        case .localQwen3:
            return []
        case .apple:
            return []
        }
    }

    static var provider: MacArticleSpeechMode {
        get {
            if let raw = KeychainService.load(.ttsProvider),
               let mode = MacArticleSpeechMode(rawValue: raw) {
                return mode
            }
            // Product default for a setting that has never been written.
            return defaultProvider
        }
        set {
            KeychainService.save(newValue.rawValue, for: .ttsProvider)
        }
    }

    static var configurationError: String? {
        if let storedRaw = KeychainService.load(.ttsProvider) {
            guard let stored = MacArticleSpeechMode(rawValue: storedRaw) else {
                return "The selected text-to-speech provider is invalid. Choose it again in Settings."
            }
            guard MacArticleSpeechMode.selectableCases.contains(stored) else {
                return "The selected text-to-speech provider is no longer available. Choose a text-to-speech model in Settings › Voice."
            }
        }

        let model = openRouterModel
        guard ArticleSpeechCatalog.model(id: model) != nil,
              !ArticleSpeechCatalog.isRetiredModel(model) else {
            return unavailableModelMessage(model)
        }
        let voices = openRouterVoices(for: model)
        if !voices.isEmpty, !voices.contains(openRouterVoice) {
            let name = ArticleSpeechCatalog.model(id: model)?.name ?? model
            return "The voice chosen for \(name) is no longer offered. Choose one in Settings › Voice."
        }
        return nil
    }

    /// Why a model cannot be sent: OpenRouter's speech list no longer has it,
    /// or this Mac could not read the list to check. A stored pick never
    /// reaches this once the list is read (`repairSelectionForUse`); a model
    /// named explicitly (a language's own model, an older manifest) can.
    static func unavailableModelMessage(_ model: String) -> String {
        ArticleSpeechCatalog.isDirectoryBacked
            ? "\(model) is no longer offered by OpenRouter. Choose a text-to-speech model in Settings › Voice."
            : "OpenRouter's list of speech models could not be read to check \(model). Try again once OpenRouter can be reached."
    }

    static var openRouterModel: String {
        get { KeychainService.load(.ttsModelOpenRouter) ?? defaultOpenRouterModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelOpenRouter) }
            else { KeychainService.save(trimmed, for: .ttsModelOpenRouter) }
        }
    }

    static var openRouterVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: openRouterVoiceDefaultsKey) ?? defaultOpenRouterVoice
            // The selection used to be global while some catalog entries were
            // incorrectly modeled as taking a provider default. Resolve the
            // stored value against the current model so an old voice (or the
            // historical empty value) becomes that model's real default before
            // it can reach the managed endpoint.
            return ArticleSpeechCatalog.resolvedVoiceID(stored, forModel: openRouterModel) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            PreferenceStore.set(trimmed, forKey: openRouterVoiceDefaultsKey)
        }
    }

    static var groqModel: String {
        get {
            let stored = KeychainService.load(.ttsModelGroq) ?? defaultGroqModel
            let migrated = migratedGroqModel(stored)
            if migrated != stored {
                KeychainService.save(migrated, for: .ttsModelGroq)
            }
            return migrated
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelGroq) }
            else { KeychainService.save(trimmed, for: .ttsModelGroq) }
        }
    }

    static var groqVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: groqVoiceDefaultsKey) ?? defaultGroqVoice
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return defaultGroqVoice }
            if trimmed.contains("PlayAI") {
                PreferenceStore.set(defaultGroqVoice, forKey: groqVoiceDefaultsKey)
                return defaultGroqVoice
            }
            let available = voices(for: .groq, model: groqModel)
            if !available.contains(trimmed) {
                PreferenceStore.set(defaultGroqVoice, forKey: groqVoiceDefaultsKey)
                return defaultGroqVoice
            }
            return trimmed
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            PreferenceStore.set(trimmed.isEmpty ? defaultGroqVoice : trimmed, forKey: groqVoiceDefaultsKey)
        }
    }

    /// Groq shut down PlayAI TTS on 2025-12-31, and the Orpheus Arabic model
    /// was removed from the app; map any stored slugs to English Orpheus.
    private static func migratedGroqModel(_ model: String) -> String {
        switch model {
        case "playai-tts", "playai-tts-arabic", "canopylabs/orpheus-arabic-saudi":
            return defaultGroqModel
        default:
            return model
        }
    }

    static var openAIModel: String {
        get { KeychainService.load(.ttsModelOpenAI) ?? defaultOpenAIModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelOpenAI) }
            else { KeychainService.save(trimmed, for: .ttsModelOpenAI) }
        }
    }

    static var openAIVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: openAIVoiceDefaultsKey) ?? defaultOpenAIVoice
            return openAIVoices(for: openAIModel).contains(stored) ? stored : defaultOpenAIVoice
        }
        set {
            let voice = openAIVoices(for: openAIModel).contains(newValue) ? newValue : defaultOpenAIVoice
            PreferenceStore.set(voice, forKey: openAIVoiceDefaultsKey)
        }
    }

    static var togetherAIModel: String {
        get {
            let stored = KeychainService.load(.ttsModelTogetherAI) ?? defaultTogetherAIModel
            if isRetiredModel(stored) {
                KeychainService.save(defaultTogetherAIModel, for: .ttsModelTogetherAI)
                return defaultTogetherAIModel
            }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelTogetherAI) }
            else { KeychainService.save(trimmed, for: .ttsModelTogetherAI) }
        }
    }

    static var togetherAIVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: togetherAIVoiceDefaultsKey) ?? defaultTogetherAIVoice
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            let available = voices(for: .togetherAI, model: togetherAIModel)
            guard !trimmed.isEmpty, available.isEmpty || available.contains(trimmed) else {
                PreferenceStore.set(defaultTogetherAIVoice, forKey: togetherAIVoiceDefaultsKey)
                return defaultTogetherAIVoice
            }
            return trimmed
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            PreferenceStore.set(trimmed.isEmpty ? defaultTogetherAIVoice : trimmed, forKey: togetherAIVoiceDefaultsKey)
        }
    }

    static var elevenLabsModel: String {
        get { KeychainService.load(.ttsModelElevenLabs) ?? defaultElevenLabsModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelElevenLabs) }
            else { KeychainService.save(trimmed, for: .ttsModelElevenLabs) }
        }
    }

    static var elevenLabsVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: elevenLabsVoiceDefaultsKey) ?? defaultElevenLabsVoice
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultElevenLabsVoice : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            PreferenceStore.set(trimmed.isEmpty ? defaultElevenLabsVoice : trimmed, forKey: elevenLabsVoiceDefaultsKey)
        }
    }

    static var xaiModel: String {
        get { KeychainService.load(.ttsModelXAI) ?? defaultXAIModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelXAI) }
            else { KeychainService.save(trimmed, for: .ttsModelXAI) }
        }
    }

    static var xaiVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: xaiVoiceDefaultsKey) ?? defaultXAIVoice
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return defaultXAIVoice }
            return trimmed.lowercased()
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            PreferenceStore.set(trimmed.isEmpty ? defaultXAIVoice : trimmed, forKey: xaiVoiceDefaultsKey)
        }
    }

    static var geminiModel: String {
        get { KeychainService.load(.ttsModelGemini) ?? defaultGeminiModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelGemini) }
            else { KeychainService.save(trimmed, for: .ttsModelGemini) }
        }
    }

    static var geminiVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: geminiVoiceDefaultsKey) ?? defaultGeminiVoice
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return defaultGeminiVoice }
            return geminiVoices.contains(trimmed) ? trimmed : defaultGeminiVoice
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            PreferenceStore.set(trimmed.isEmpty ? defaultGeminiVoice : trimmed, forKey: geminiVoiceDefaultsKey)
        }
    }

    static var localQwen3ServerURL: String {
        get {
            let stored = KeychainService.load(.ttsLocalServerURL) ?? defaultLocalQwen3ServerURL
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultLocalQwen3ServerURL : trimmed
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsLocalServerURL) }
            else { KeychainService.save(trimmed, for: .ttsLocalServerURL) }
        }
    }

    static var localQwen3Model: String {
        get { KeychainService.load(.ttsModelLocalMac) ?? defaultLocalQwen3Model }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelLocalMac) }
            else { KeychainService.save(trimmed, for: .ttsModelLocalMac) }
        }
    }

    static var localQwen3Voice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: localQwen3VoiceDefaultsKey) ?? defaultLocalQwen3Voice
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultLocalQwen3Voice : trimmed
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            PreferenceStore.set(trimmed.isEmpty ? defaultLocalQwen3Voice : trimmed, forKey: localQwen3VoiceDefaultsKey)
        }
    }

    static func model(for provider: MacArticleSpeechMode) -> String {
        switch provider {
        case .openRouter: return openRouterModel
        case .groq: return groqModel
        case .openAI: return openAIModel
        case .togetherAI: return togetherAIModel
        case .elevenLabs: return elevenLabsModel
        case .xai: return xaiModel
        case .gemini: return geminiModel
        case .localQwen3: return localQwen3Model
        case .apple: return KeychainService.load(.ttsModelApple) ?? "AVSpeech"
        }
    }

    static func setModel(_ model: String, for provider: MacArticleSpeechMode) {
        switch provider {
        case .openRouter: openRouterModel = model
        case .groq: groqModel = model
        case .openAI: openAIModel = model
        case .togetherAI: togetherAIModel = model
        case .elevenLabs: elevenLabsModel = model
        case .xai: xaiModel = model
        case .gemini: geminiModel = model
        case .localQwen3: localQwen3Model = model
        case .apple:
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainService.delete(.ttsModelApple) }
            else { KeychainService.save(trimmed, for: .ttsModelApple) }
        }
    }

    static func voice(for provider: MacArticleSpeechMode) -> String {
        switch provider {
        case .openRouter: return openRouterVoice
        case .groq: return groqVoice
        case .openAI: return openAIVoice
        case .togetherAI: return togetherAIVoice
        case .elevenLabs: return elevenLabsVoice
        case .xai: return xaiVoice
        case .gemini: return geminiVoice
        case .localQwen3: return localQwen3Voice
        case .apple: return appleVoiceIdentifier ?? ""
        }
    }

    static func setVoice(_ voice: String, for provider: MacArticleSpeechMode) {
        switch provider {
        case .openRouter: openRouterVoice = voice
        case .groq: groqVoice = voice
        case .openAI: openAIVoice = voice
        case .togetherAI: togetherAIVoice = voice
        case .elevenLabs: elevenLabsVoice = voice
        case .xai: xaiVoice = voice
        case .gemini: geminiVoice = voice
        case .localQwen3: localQwen3Voice = voice
        case .apple: appleVoiceIdentifier = voice.isEmpty ? nil : voice
        }
    }

    /// The model and voice a provider should be presented with: the stored pick
    /// when it is still offered, otherwise the first available one — and the
    /// repair is written back, so opening Settings fixes the stored value
    /// rather than only the display. Apple and the local server keep whatever
    /// is stored; their names are typed in, not chosen from a list.
    ///
    /// Can block, for the same reason `MacArticleSpeechConfiguration.loadStored`
    /// can: every read and write in here goes through `KeychainService`, which
    /// reaches `SecItemCopyMatching` on the ACL-guarded vault. Call it off the
    /// main actor, never from a SwiftUI initializer or view body.
    static func repairedSelection(
        for provider: MacArticleSpeechMode
    ) -> (model: String, voice: String) {
        guard provider != .apple, provider != .localQwen3 else {
            return (model(for: provider), voice(for: provider))
        }

        let models = preferredModels(for: provider)
        let storedModel = model(for: provider)
        // The OpenRouter list is OpenRouter's directory. Before this Mac has
        // read it, the catalog is only what this build records, and a stored
        // model missing from that may be one OpenRouter added since — picked
        // on another device, or here on an earlier launch. Leave it as it is:
        // the request path reads the directory before it checks the pick.
        guard provider != .openRouter || ArticleSpeechCatalog.isDirectoryBacked
                || models.contains(storedModel) else {
            return (storedModel, voice(for: provider))
        }
        let storedVoice = voice(for: provider)
        let selected = ArticleSpeechSelection.resolvedPick(
            storedModel: storedModel,
            storedVoice: storedVoice,
            offered: models,
            voices: { voices(for: provider, model: $0) },
            failed: { model, voice in
                // A model whose test run failed in the voice it would get is
                // passed over for the next one; it stays in the picker.
                provider == .openRouter && AIModelQualification.isSpeechKnownToFail(model: model, voice: voice)
            }
        )
        if selected.model != storedModel {
            setModel(selected.model, for: provider)
        }
        if selected.voice != storedVoice {
            setVoice(selected.voice, for: provider)
        }
        return selected
    }

    // MARK: Repair where used

    /// A stored text-to-speech pick OpenRouter's speech list no longer
    /// offers, and what replaced it: the rule and the sentence are the
    /// phone's too (`ArticleSpeechPickRepair.swift`).
    typealias SelectionRepair = ArticleSpeechSelection.Repair

    private static let pendingRepairLock = NSLock()
    nonisolated(unsafe) private static var pendingRepair: SelectionRepair?

    /// Before a text-to-speech request goes out (Listen, generated audio,
    /// audio overviews, `generate_source_audio`): the stored pick, repaired
    /// as Settings repairs it when OpenRouter stopped offering it, with the
    /// repair written back. Returns what changed so the caller says it once,
    /// including a repair a directory read made since the last use; nil when
    /// nothing did. A failed request is never answered with another model:
    /// this runs before one goes out.
    ///
    /// Can block, as `repairedSelection` can; call it off the main actor.
    static func repairSelectionForUse() -> SelectionRepair? {
        let now = repairStoredSelection()
        let pending: SelectionRepair? = pendingRepairLock.withLock {
            defer { pendingRepair = nil }
            return pendingRepair
        }
        return SelectionRepair.combined(pending, then: now)
    }

    /// After a read of OpenRouter's speech list: the same repair, kept for
    /// the next use to say.
    static func repairAfterDirectoryRead() {
        guard let repair = repairStoredSelection() else { return }
        pendingRepairLock.withLock {
            pendingRepair = SelectionRepair.combined(pendingRepair, then: repair)
        }
    }

    /// The repair itself, for a caller that has no one to tell (the request
    /// path under a listening session that already told them).
    static func repairStoredSelection() -> SelectionRepair? {
        guard provider == .openRouter else { return nil }
        let oldModel = openRouterModel
        let repaired = repairedSelection(for: .openRouter)
        guard repaired.model != oldModel else { return nil }
        return SelectionRepair(oldModel: oldModel, newModel: repaired.model, newVoice: repaired.voice)
    }

    /// What `repairSelectionForUse` would settle on, without writing it: for
    /// a quote, which reads the pick rather than uses it.
    static func selectionForQuote() -> (model: String, voice: String, repair: SelectionRepair?) {
        let storedModel = openRouterModel
        let storedVoice = openRouterVoice
        guard provider == .openRouter, ArticleSpeechCatalog.isDirectoryBacked else {
            return (storedModel, storedVoice, nil)
        }
        let pick = ArticleSpeechSelection.resolvedPick(
            storedModel: storedModel,
            storedVoice: storedVoice,
            offered: openRouterModels,
            voices: { openRouterVoices(for: $0) },
            failed: { AIModelQualification.isSpeechKnownToFail(model: $0, voice: $1) }
        )
        let repair = pick.model == storedModel
            ? nil
            : SelectionRepair(oldModel: storedModel, newModel: pick.model, newVoice: pick.voice)
        return (pick.model, pick.voice, repair)
    }

    /// Legacy/global master switch for cost confirmation. Individual dismissals
    /// live in `TextToSpeechCostConfirmationPreferences`, keyed by model rather
    /// than voice, so changing voices never resurrects or broadens a dismissal.
    static var confirmCostBeforeListening: Bool {
        get {
            (UserDefaults.standard.object(forKey: confirmCostBeforeListeningDefaultsKey) as? Bool) ?? true
        }
        set {
            PreferenceStore.set(newValue, forKey: confirmCostBeforeListeningDefaultsKey)
        }
    }

    static func confirmsCostBeforeListening(for model: String) -> Bool {
        confirmCostBeforeListening
            && TextToSpeechCostConfirmationPreferences.confirmsEstimatedCost(for: model)
    }

    static func setConfirmsCostBeforeListening(_ confirms: Bool, for model: String) {
        // Moving the visible per-model switch back on also retires the old
        // global-off state from builds where suppression was not model-scoped.
        if confirms, !confirmCostBeforeListening {
            confirmCostBeforeListening = true
        }
        PreferenceStore.set(
            TextToSpeechCostConfirmationPreferences.updatedSuppressedModelIDs(
                TextToSpeechCostConfirmationPreferences.suppressedModelIDs,
                confirms: confirms,
                modelID: model
            ),
            forKey: TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey
        )
    }

    /// Whether text-to-speech audio is prepared automatically for one source type.
    /// Keyed by type rather than exposed as one property per type, so adding a
    /// type to `SourceAudioAutomation.automatableSourceTypes` reaches Settings
    /// without a parallel pair of accessors here.
    static func automaticallyGenerates(_ sourceType: String) -> Bool {
        SourceAudioAutomation.isEnabled(for: sourceType)
    }

    static func setAutomaticallyGenerates(_ enabled: Bool, sourceType: String) {
        guard let key = SourceAudioAutomation.preferenceKey(for: sourceType) else { return }
        PreferenceStore.set(enabled, forKey: key)
        NotificationCenter.default.post(name: .automaticSourceAudioPreferencesChanged, object: nil)
    }

    /// Account consent to let automatic audio use a priced voice. Synced, so a
    /// grant here reaches this account's other devices; each still spends at
    /// its own selected rate.
    static var allowsPaidAutomaticVoices: Bool {
        SourceAudioAutomation.allowsPaidVoices()
    }

    static func setAllowsPaidAutomaticVoices(_ allowed: Bool) {
        PreferenceStore.set(allowed, forKey: SourceAudioAutomation.paidVoiceConsentPreferenceKey)
        NotificationCenter.default.post(name: .automaticSourceAudioPreferencesChanged, object: nil)
    }

    /// Whether automatic audio may run with the selected voice at all: an
    /// OpenRouter voice that is free, or priced and behind the account's paid
    /// consent; never an unpriced one and never another provider. The worker
    /// re-reads it between sources, Settings disables the switches on it, and
    /// the MCP setter refuses to arm a switch when it is false.
    static func automaticSelectionIsAllowed(
        _ selection: AutomaticAudioSelection = .current
    ) -> Bool {
        selection.isAllowed
    }

    /// Whether a source of this automation kind, written or arriving now, may
    /// have its audio started at once with the selected voice — without the
    /// per-run cost question. True exactly when the kind's switch is on and the
    /// selection is one automation may spend on: the standing opt-in *is* the
    /// consent, given once in Settings with the library priced in front of it.
    /// The Explain action and `generate_explainer` read this for
    /// `SourceAudioAutomation.explainerKind`.
    static func automaticAudioStartsWithoutConfirmation(
        kind: String,
        selection: AutomaticAudioSelection = .current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        SourceAudioAutomation.isEnabled(for: kind, defaults: defaults) && selection.isAllowed
    }

    static func automaticGenerationConstraint(_ sourceType: String) -> String {
        SourceAudioAutomation.constraint(for: sourceType) ?? ""
    }

    static func setAutomaticGenerationConstraint(_ constraint: String, sourceType: String) {
        guard let key = SourceAudioAutomation.constraintPreferenceKey(for: sourceType) else { return }
        let value = constraint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { PreferenceStore.remove(forKey: key) }
        else { PreferenceStore.set(value, forKey: key) }
        NotificationCenter.default.post(name: .automaticSourceAudioPreferencesChanged, object: nil)
    }

    static var appleVoiceIdentifier: String? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: appleVoiceDefaultsKey),
                  !stored.isEmpty else { return nil }
            return stored
        }
        set {
            if let newValue, !newValue.isEmpty {
                PreferenceStore.set(newValue, forKey: appleVoiceDefaultsKey)
            } else {
                PreferenceStore.remove(forKey: appleVoiceDefaultsKey)
            }
        }
    }

    static var appleVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let lhs = "\($0.language) \($0.name)"
                let rhs = "\($1.language) \($1.name)"
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    static func appleVoiceName(identifier: String?) -> String {
        guard let identifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            return "System Voice"
        }
        return "\(voice.name) (\(voice.language))"
    }
}

/// The text-to-speech selection automatic audio is judged against: the provider,
/// the model it would generate with, its voice, and the account's paid-voice
/// consent. `.current` reads the live settings; tests build one by hand, so
/// the rule can be pinned without writing this Mac's Keychain.
struct AutomaticAudioSelection: Equatable, Sendable {
    var provider: MacArticleSpeechMode
    var model: String
    var voice: String
    var allowsPaidVoices: Bool

    static var current: AutomaticAudioSelection {
        let provider = MacArticleSpeechSettings.provider
        return AutomaticAudioSelection(
            provider: provider,
            model: MacArticleSpeechSettings.model(for: provider),
            voice: MacArticleSpeechSettings.voice(for: provider),
            allowsPaidVoices: MacArticleSpeechSettings.allowsPaidAutomaticVoices
        )
    }

    /// The selected model's speech rate, or nil when the rate card does not
    /// price it — the same lookup Settings prices its estimates with.
    var ratePerMillionCharacters: Double? {
        AIProviderPricing.ttsDisplayRatePerMillionCharacters(
            provider: provider.rawValue,
            model: model
        )
    }

    /// Free always, priced only behind consent, unpriced never, and only on
    /// an OpenRouter voice — `SourceAudioAutomation.allowsAutomaticGeneration`
    /// with the provider gate the worker and Settings both apply.
    var isAllowed: Bool {
        guard provider == .openRouter else { return false }
        return SourceAudioAutomation.allowsAutomaticGeneration(
            provider: ArticleSpeechCatalog.provider,
            model: model,
            allowsPaidVoices: allowsPaidVoices
        )
    }

    /// True when the selection runs only because paid consent was granted.
    var requiresPaidVoiceConsent: Bool {
        provider == .openRouter
            && SourceAudioAutomation.requiresPaidVoiceConsent(
                provider: ArticleSpeechCatalog.provider,
                model: model
            )
    }

    /// Why automation cannot run on this selection, or nil when it can. The
    /// pane's standing disclosure for an OpenRouter voice; a sentence naming
    /// the provider otherwise, because the disclosure assumes OpenRouter.
    var unavailableReason: String? {
        guard !isAllowed else { return nil }
        guard provider == .openRouter else {
            return "Text to Speech is set to \(provider.rawValue); automatic audio runs only on an OpenRouter voice. Choose one in Settings › Text to Speech."
        }
        return SourceAudioAutomation.costDisclosure(
            ratePerMillionCharacters: ratePerMillionCharacters,
            allowsPaidVoices: allowsPaidVoices
        )
    }
}
#endif
