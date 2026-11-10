import Foundation
import AVFoundation

// MARK: - Settings › Voice, from a chat
//
// Every control in `VoiceSettingsDetailView` (SettingsAIModels.swift) as a
// `set_app_setting` entry: the two Speech-to-Text model groups (dictation is
// transcribed after you stop), the Text-to-Speech card (read aloud) and voice
// mode's voice (voice_mode.voice). Realtime voice and live dictation went on
// 2026-10-01, and with them realtime_voice.model, realtime_voice.voice,
// dictation.realtime and dictation.realtime_model; voice mode came back on
// 2026-11-07 on ForeverLM's own credits, with only its voice to choose. Each `write` calls the setter the pane
// calls, so the side effects match — a model change that resets a voice the
// new model does not offer, a provider change that repairs the stored pick.
//
// Several of the pane's helpers are `private` to its views (the providers'
// model lists, the price captions, the voice-rating store); the few lines
// each needs are replicated here rather than widening the view file, and
// marked where they are.

extension MCPDataStore {

    @MainActor
    static func voiceSettingEntries() -> [AppSettingEntry] {
        // The speech and transcription lists are OpenRouter's directories.
        // An assistant reading them is an event like the pane opening: start
        // a read when the last is stale, and answer from the last read now.
        OpenRouterAudioDirectory.warm(.speech)
        OpenRouterAudioDirectory.warm(.transcription)
        return speechToTextSettingEntries()
            + textToSpeechSettingEntries()
            + [voiceModeVoiceEntry()]
    }

    // MARK: Voice mode

    private static func voiceModeVoiceEntry() -> AppSettingEntry {
        let key = RealtimeVoiceDefaults.voicePreferenceKey
        return AppSettingEntry(
            id: "voice_mode.voice",
            pane: "Voice › Voice mode",
            title: "Voice",
            detail: "The voice ForeverLM speaks in during a voice mode conversation, on the Mac, the iPhone and CarPlay. Applies from the next conversation. Voice mode runs on ForeverLM's own credits, so no voice costs the learner anything.",
            reach: .account,
            kind: .choice,
            preferenceKeys: [key],
            options: {
                RealtimeVoiceDefaults.voices.map { id -> [String: Any] in
                    ["value": id, "label": RealtimeVoiceDefaults.voiceLabel(id)]
                }
            },
            read: {
                RealtimeVoiceDefaults.resolvedVoice(UserDefaults.standard.string(forKey: key))
            },
            write: { value in
                let voice = try AppSettingEntry.string(value, "voice_mode.voice")
                guard RealtimeVoiceDefaults.voices.contains(voice) else {
                    throw MCPError.invalidInput("voice_mode.voice takes one of: \(RealtimeVoiceDefaults.voices.joined(separator: ", ")).")
                }
                PreferenceStore.set(voice, forKey: key)
            }
        )
    }

    // MARK: Speech-to-Text

    /// The pane's transcription list (`DictationSettingsView`): every model
    /// OpenRouter's transcription directory lists, whichever slot the pick is
    /// stored under, since every one of them goes to OpenRouter.
    private static func speechToTextDictationModels(for provider: SpeechToTextProvider) -> [String] {
        ManagedTranscriptionClient.catalog
    }

    /// The slot `KeychainService.setTranscriptionModel` stores a provider's
    /// dictation model under.
    private static func speechToTextModelKey(for provider: SpeechToTextProvider) -> KeychainService.Key {
        switch provider {
        case .groq: .sttModelGroq
        case .openai: .sttModelOpenAI
        case .openRouter: .sttModelOpenRouter
        }
    }

    /// Replicates `DictationSettingsView.priceLabel(for:)` (private). A model
    /// whose price is in a unit ForeverLM has no record of says so rather than
    /// carrying no price, which reads as free.
    private static func speechToTextOptions(_ models: [String]) -> [[String: Any]] {
        models.map { model in
            let entry = TranscriptionModelCatalog.model(id: model)
            var option: [String: Any] = ["value": model, "label": entry?.name ?? model]
            if let maker = entry?.maker { option["maker"] = maker }
            // OpenRouter's price in the unit it bills the model by; an hourly
            // figure only for a model billed by the duration of its audio.
            option["detail"] = OpenRouterAudioPrices.label(
                slug: ManagedTranscriptionClient.canonicalModel(model),
                kind: .transcription
            ) ?? OpenRouterAudioPrices.unknownPriceLabel
            if let rate = AIProviderPricing.sttDisplayRatePerHour(model: model) {
                option["usd_per_hour_of_audio"] = rate
            }
            return option
        }
    }

    @MainActor
    private static func speechToTextSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "speech_to_text.dictation_model",
                pane: "Voice › Dictation",
                title: "Dictation model",
                detail: "The model Chat and Review dictation is transcribed with, once the learner stops speaking. Spoken live, so speed matters most. Changes what dictation is billed at; each option carries its price. Like the pane's text field, a model id outside the list is stored as given.",
                reach: .account,
                kind: .text,
                preferenceKeys: [speechToTextModelKey(for: KeychainService.speechToTextProvider).rawValue],
                options: { speechToTextOptions(speechToTextDictationModels(for: KeychainService.speechToTextProvider)) },
                read: {
                    ManagedTranscriptionClient.canonicalModel(
                        KeychainService.transcriptionModel(for: KeychainService.speechToTextProvider)
                    )
                },
                write: { value in
                    let model = try AppSettingEntry.string(value, "speech_to_text.dictation_model")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !model.isEmpty else {
                        throw MCPError.invalidInput("speech_to_text.dictation_model takes a model id, e.g. one of: \(speechToTextDictationModels(for: KeychainService.speechToTextProvider).joined(separator: ", ")).")
                    }
                    KeychainService.setTranscriptionModel(model, for: KeychainService.speechToTextProvider)
                }
            ),
            AppSettingEntry(
                id: "speech_to_text.recordings_model",
                pane: "Voice › Recordings & Podcasts",
                title: "Recordings & Podcasts model",
                detail: "The model meeting recordings and podcast episodes are transcribed with, in the background, where accuracy beats latency. Changes what every transcribed hour is billed at; each option carries its price. Like the pane's text field, a model id outside the list is stored as given.",
                // `stt_model_media` is absent from `SyncedPreferenceKeys.synced`,
                // so this pick stays on the Mac it was made on.
                reach: .thisMac,
                kind: .text,
                preferenceKeys: [KeychainService.Key.sttModelMedia.rawValue],
                options: { speechToTextOptions(ManagedTranscriptionClient.catalog) },
                read: { ManagedTranscriptionClient.canonicalModel(KeychainService.mediaTranscriptionModel) },
                write: { value in
                    let model = try AppSettingEntry.string(value, "speech_to_text.recordings_model")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !model.isEmpty else {
                        throw MCPError.invalidInput("speech_to_text.recordings_model takes a model id, e.g. one of: \(ManagedTranscriptionClient.catalog.joined(separator: ", ")).")
                    }
                    KeychainService.mediaTranscriptionModel = model
                }
            ),
        ]
    }

    // MARK: Text to speech (Text-to-Speech)

    /// Replicates `TextToSpeechSettingsView.priceLabel(for:)` (private).
    private static func textToSpeechPrice(provider: MacArticleSpeechMode, model: String) -> (label: String, usd: Double)? {
        switch provider {
        case .localQwen3, .apple:
            return ("Free", 0)
        default:
            guard let rate = AIProviderPricing.ttsDisplayRatePerMillionCharacters(
                provider: provider.rawValue,
                model: model
            ) else { return nil }
            if rate == 0 { return ("Free", 0) }
            return ("\(AIModelListPrice.dollars(rate)) / 1M characters", rate)
        }
    }

    /// Replicates `TextToSpeechSettingsView.label(for:)` (private), for the
    /// providers that show a voice list.
    private static func textToSpeechVoiceLabel(provider: MacArticleSpeechMode, model: String, voice: String) -> String {
        switch provider {
        case .openRouter:
            return MacArticleSpeechSettings.openRouterVoiceLabel(model: model, voice: voice)
        case .elevenLabs:
            return MacArticleSpeechSettings.elevenLabsVoicePresets.first(where: { $0.id == voice })?.name ?? voice
        case .togetherAI:
            return voice.replacingOccurrences(of: "_", with: " ").capitalized
        case .groq, .openAI:
            return voice.capitalized
        case .xai:
            return MacArticleSpeechSettings.xaiVoiceLabel(for: voice)
        case .gemini:
            return voice
        case .localQwen3:
            return voice.replacingOccurrences(of: "_", with: " ")
        case .apple:
            return MacArticleSpeechSettings.appleVoiceName(identifier: voice.isEmpty ? nil : voice)
        }
    }

    /// The model id the pane's voice list and cost switch are keyed by: the
    /// stored model, or "AVSpeech" for the on-device engine (its preview model).
    private static func textToSpeechModelID(for provider: MacArticleSpeechMode) -> String {
        provider == .apple ? "AVSpeech" : MacArticleSpeechSettings.model(for: provider)
    }

    @MainActor
    private static func textToSpeechSettingEntries() -> [AppSettingEntry] {
        // The card's layout depends on the stored provider, like the pane's
        // `switch provider`; `tts_provider` is preference-backed, so this is a
        // `UserDefaults` read rather than a vault one.
        let provider = MacArticleSpeechSettings.provider
        var entries: [AppSettingEntry] = []

        // The pane shows the provider row only when there is a choice to make.
        if MacArticleSpeechMode.selectableCases.count > 1 {
            entries.append(AppSettingEntry(
                id: "read_aloud.provider",
                pane: "Text to speech provider (no pane)",
                title: "Provider",
                detail: "Who generates text-to-speech audio. Changing it repairs the model and voice to ones the new provider offers, and changes what listening is billed at.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [KeychainService.Key.ttsProvider.rawValue],
                options: {
                    MacArticleSpeechMode.selectableCases.map { mode -> [String: Any] in ["value": mode.rawValue, "label": mode.label] }
                },
                read: { MacArticleSpeechSettings.provider.rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "read_aloud.provider")
                    guard let mode = MacArticleSpeechMode(rawValue: raw),
                          MacArticleSpeechMode.selectableCases.contains(mode) else {
                        throw MCPError.invalidInput("read_aloud.provider takes one of: \(MacArticleSpeechMode.selectableCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    // The same two steps as picking a provider in Settings: set it, then repair the voice it implies.
                    MacArticleSpeechSettings.provider = mode
                    _ = MacArticleSpeechSettings.repairedSelection(for: mode)
                }
            ))
        }

        switch provider {
        case .localQwen3:
            entries += textToSpeechLocalEntries()
        case .apple:
            entries.append(textToSpeechAppleVoiceEntry())
        default:
            entries.append(textToSpeechModelEntry(provider: provider))
            if !MacArticleSpeechSettings.voices(for: provider, model: MacArticleSpeechSettings.model(for: provider)).isEmpty {
                entries.append(textToSpeechVoiceEntry(provider: provider))
            }
        }

        entries.append(AppSettingEntry(
            id: "read_aloud.speed",
            pane: "Voice › Text to Speech",
            title: "Default speed",
            detail: "The speed text-to-speech starts at, as a multiple of normal. One of the pane's speeds.",
            reach: .account,
            kind: .number(min: MacArticleSpeechSpeed.options.first ?? MacArticleSpeechSpeed.minimum,
                          max: MacArticleSpeechSpeed.options.last ?? MacArticleSpeechSpeed.maximum,
                          step: 0.25),
            // `MacArticleSpeechSpeed`'s key is private to it.
            preferenceKeys: ["macos.tts.speed"],
            options: {
                MacArticleSpeechSpeed.options.map { speed -> [String: Any] in ["value": speed, "label": MacArticleSpeechSpeed.label(for: speed)] }
            },
            read: { MacArticleSpeechSpeed.stored },
            write: { value in
                let speed = try AppSettingEntry.number(value, "read_aloud.speed")
                guard let option = MacArticleSpeechSpeed.options.first(where: { MacArticleSpeechSpeed.isSelected(speed, option: $0) }) else {
                    throw MCPError.invalidInput("read_aloud.speed takes one of: \(MacArticleSpeechSpeed.options.map { String($0) }.joined(separator: ", ")).")
                }
                MacArticleSpeechSpeed.stored = option
            }
        ))

        entries.append(AppSettingEntry(
            id: "read_aloud.confirm_cost",
            pane: "Text to speech cost prompt (no pane)",
            title: "Confirm estimated cost for this model",
            detail: "Whether listening with the selected text-to-speech model first asks the learner to confirm its estimated cost. Applies to every voice of that model; cached audio always plays without asking.",
            reach: .account,
            kind: .boolean,
            // The global switch's key is private to `MacArticleSpeechSettings`.
            preferenceKeys: ["macos.tts.confirmCostBeforeListening", TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey],
            read: {
                let provider = MacArticleSpeechSettings.provider
                return MacArticleSpeechSettings.confirmsCostBeforeListening(for: textToSpeechModelID(for: provider))
            },
            write: { value in
                let confirms = try AppSettingEntry.bool(value, "read_aloud.confirm_cost")
                let provider = MacArticleSpeechSettings.provider
                MacArticleSpeechSettings.setConfirmsCostBeforeListening(confirms, for: textToSpeechModelID(for: provider))
            }
        ))

        // The thumbs sit on each row of the voice list, which the local
        // server's card does not have.
        if provider != .localQwen3 {
            entries.append(textToSpeechVoiceRatingEntry())
        }

        return entries
    }

    @MainActor
    private static func textToSpeechModelEntry(provider: MacArticleSpeechMode) -> AppSettingEntry {
        AppSettingEntry(
            id: "read_aloud.model",
            pane: "Voice › Text to Speech",
            title: "\(provider.label) TTS model",
            detail: "The model text-to-speech audio is generated with: every speech model OpenRouter's directory lists, each served through OpenRouter. Changes what listening is billed at; each option carries OpenRouter's price in the unit it bills the model by (per 1M characters, per 1M tokens, per minute of audio; \"Price unknown\" when OpenRouter has not priced it), with usd_per_million_characters only for a model billed by the character, its maker, its voice count and the languages it is documented to read (\"unstated\" when nothing says). If the current voice is not offered by the new model, the voice moves to the model's first one, as in the pane; a model with no voices speaks in its provider's default voice. A model is applied only once one short test synthesis in that voice passes; a refusal answers with OpenRouter's reason and changes nothing.",
            reach: .account,
            kind: .choice,
            // Every provider this entry is built for (not the local server or
            // the on-device engine, which have their own).
            preferenceKeys: [
                KeychainService.Key.ttsModelOpenRouter, .ttsModelGroq, .ttsModelOpenAI, .ttsModelTogetherAI,
                .ttsModelElevenLabs, .ttsModelXAI, .ttsModelGemini,
            ].map(\.rawValue),
            options: {
                let provider = MacArticleSpeechSettings.provider
                return MacArticleSpeechSettings.preferredModels(for: provider).map { model in
                    let entry = ArticleSpeechCatalog.model(id: model)
                    var option: [String: Any] = [
                        "value": model,
                        "label": entry?.name ?? model,
                    ]
                    if let entry {
                        option["maker"] = entry.maker
                        option["voices"] = entry.voices.count
                        // What the language check can lean on: a model
                        // OpenRouter publishes no languages for, and ForeverLM
                        // has no record of, is "unstated" — never assumed to
                        // be English.
                        switch entry.languages {
                        case .multilingual: option["languages"] = "multilingual"
                        case .languages(let codes): option["languages"] = codes.sorted()
                        case .unstated: option["languages"] = "unstated"
                        }
                    }
                    // OpenRouter's price in the unit it bills the model by;
                    // a per-character figure only for a model billed by the
                    // character.
                    option["detail"] = provider == .openRouter
                        ? ArticleSpeechCatalog.priceLabel(forModel: model)
                        : (textToSpeechPrice(provider: provider, model: model)?.label ?? OpenRouterAudioPrices.unknownPriceLabel)
                    if let price = textToSpeechPrice(provider: provider, model: model) {
                        option["usd_per_million_characters"] = price.usd
                    }
                    return option
                }
            },
            read: { MacArticleSpeechSettings.model(for: MacArticleSpeechSettings.provider) },
            write: { value in
                let provider = MacArticleSpeechSettings.provider
                let models = MacArticleSpeechSettings.preferredModels(for: provider)
                let model = try AppSettingEntry.string(value, "read_aloud.model")
                guard models.contains(model) else {
                    throw MCPError.invalidInput("read_aloud.model takes one of: \(models.joined(separator: ", ")).")
                }
                // `TextToSpeechSettingsView.selectModel`, whose `voiceText` is
                // the stored voice: tested in the voice it would get first.
                let currentVoice = MacArticleSpeechSettings.voice(for: provider)
                let voices = provider == .localQwen3 ? [] : MacArticleSpeechSettings.voices(for: provider, model: model)
                let voice = voices.isEmpty || voices.contains(currentVoice) ? currentVoice : voices[0]
                try await requireSpeechQualified(provider: provider, model: model, voice: voice)
                MacArticleSpeechSettings.setModel(model, for: provider)
                if voice != currentVoice {
                    MacArticleSpeechSettings.setVoice(voice, for: provider)
                }
            }
        )
    }

    @MainActor
    private static func textToSpeechVoiceEntry(provider: MacArticleSpeechMode) -> AppSettingEntry {
        AppSettingEntry(
            id: "read_aloud.voice",
            pane: "Voice › Text to Speech",
            title: provider == .elevenLabs ? "Voice ID" : "Voice",
            detail: "The voice text-to-speech speaks in; the options are the voices the selected model (read_aloud.model) offers. Audio already generated in another voice is regenerated, and billed, when listened to in this one. A voice is applied only once one short test synthesis in it passes.",
            reach: .account,
            kind: .choice,
            // The providers `read_aloud.model` covers; the voice keys are
            // private to `MacArticleSpeechSettings`.
            preferenceKeys: ["openrouter", "groq", "openai", "together", "elevenlabs", "xai", "gemini"].map { "macos.tts.\($0).voice" },
            options: {
                let provider = MacArticleSpeechSettings.provider
                let model = MacArticleSpeechSettings.model(for: provider)
                return MacArticleSpeechSettings.voices(for: provider, model: model).map { voice -> [String: Any] in
                    ["value": voice, "label": textToSpeechVoiceLabel(provider: provider, model: model, voice: voice)]
                }
            },
            read: { MacArticleSpeechSettings.voice(for: MacArticleSpeechSettings.provider) },
            write: { value in
                let provider = MacArticleSpeechSettings.provider
                let model = MacArticleSpeechSettings.model(for: provider)
                let voices = MacArticleSpeechSettings.voices(for: provider, model: model)
                let voice = try AppSettingEntry.string(value, "read_aloud.voice")
                guard voices.contains(voice) else {
                    throw MCPError.invalidInput("\(model) offers: \(voices.joined(separator: ", ")).")
                }
                // `TextToSpeechSettingsView.selectVoice`.
                try await requireSpeechQualified(provider: provider, model: model, voice: voice)
                MacArticleSpeechSettings.setVoice(voice, for: provider)
            }
        )
    }

    /// A text-to-speech pick is applied only once the model, in this voice,
    /// passed a test run, as in Settings › Voice
    /// (`AIModelQualification.testSpeechBeforeSelecting`); a refusal throws
    /// OpenRouter's reason and leaves the setting as it was.
    private static func requireSpeechQualified(provider: MacArticleSpeechMode, model: String, voice: String) async throws {
        guard provider == .openRouter else { return }
        let verdict = await AIModelQualification.testSpeechBeforeSelecting(model: model, voice: voice)
        if let text = AIModelQualification.speechSettingRefusalText(
            name: ArticleSpeechCatalog.selectionLabel(model: model, voice: voice),
            verdict: verdict
        ) {
            throw MCPError.invalidInput(text)
        }
    }

    @MainActor
    private static func textToSpeechAppleVoiceEntry() -> AppSettingEntry {
        AppSettingEntry(
            id: "read_aloud.apple_voice",
            pane: "Text to speech macOS voice (no pane)",
            title: "macOS Voice",
            detail: "The on-device voice text-to-speech speaks in (free). An empty string is the System Voice.",
            reach: .account,
            kind: .choice,
            preferenceKeys: ["macos.tts.apple.voiceIdentifier"],
            options: {
                [["value": "", "label": "System Voice"] as [String: Any]]
                    + MacArticleSpeechSettings.appleVoices.map { voice -> [String: Any] in
                        ["value": voice.identifier, "label": MacArticleSpeechSettings.appleVoiceName(identifier: voice.identifier)]
                    }
            },
            read: { MacArticleSpeechSettings.appleVoiceIdentifier ?? "" },
            write: { value in
                let identifier = try AppSettingEntry.string(value, "read_aloud.apple_voice")
                guard identifier.isEmpty
                        || MacArticleSpeechSettings.appleVoices.contains(where: { $0.identifier == identifier }) else {
                    throw MCPError.invalidInput("\(identifier) is not a voice installed on this Mac; get_app_settings setting=read_aloud.apple_voice lists them.")
                }
                MacArticleSpeechSettings.appleVoiceIdentifier = identifier.isEmpty ? nil : identifier
            }
        )
    }

    @MainActor
    private static func textToSpeechLocalEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "read_aloud.local_server_url",
                pane: "Text to speech local server (no pane)",
                title: "Server URL",
                detail: "The OpenAI-compatible local text-to-speech server text-to-speech calls (free). An empty string goes back to \(MacArticleSpeechSettings.defaultLocalQwen3ServerURL).",
                reach: .account,
                kind: .text,
                preferenceKeys: [KeychainService.Key.ttsLocalServerURL.rawValue],
                read: { MacArticleSpeechSettings.localQwen3ServerURL },
                write: { value in
                    MacArticleSpeechSettings.localQwen3ServerURL = try AppSettingEntry.string(value, "read_aloud.local_server_url")
                }
            ),
            AppSettingEntry(
                id: "read_aloud.local_model",
                pane: "Text to speech local server (no pane)",
                title: "Local TTS model",
                detail: "The model name the local server expects (free). Any name, as the pane's text field takes; the options are the pane's suggestions. An empty string goes back to \(MacArticleSpeechSettings.defaultLocalQwen3Model).",
                reach: .account,
                kind: .text,
                preferenceKeys: [KeychainService.Key.ttsModelLocalMac.rawValue],
                options: {
                    MacArticleSpeechSettings.preferredModels(for: .localQwen3).map { model -> [String: Any] in ["value": model, "label": model, "detail": "Free"] }
                },
                read: { MacArticleSpeechSettings.localQwen3Model },
                write: { value in
                    MacArticleSpeechSettings.setModel(try AppSettingEntry.string(value, "read_aloud.local_model"), for: .localQwen3)
                }
            ),
            AppSettingEntry(
                id: "read_aloud.local_voice",
                pane: "Text to speech local server (no pane)",
                title: "Voice",
                detail: "The voice name the local server expects (free). An empty string goes back to \(MacArticleSpeechSettings.defaultLocalQwen3Voice).",
                reach: .account,
                kind: .text,
                preferenceKeys: ["macos.tts.local_qwen3.voice"],
                read: { MacArticleSpeechSettings.localQwen3Voice },
                write: { value in
                    MacArticleSpeechSettings.setVoice(try AppSettingEntry.string(value, "read_aloud.local_voice"), for: .localQwen3)
                }
            ),
        ]
    }

    /// The thumbs on the selected voice's row. Replicates the private
    /// `MacArticleSpeechVoiceRatingStore` in SettingsAIModels.swift: one
    /// synced preference per model/voice pair, removed for no rating.
    @MainActor
    private static func textToSpeechVoiceRatingEntry() -> AppSettingEntry {
        func ratingKey() -> String {
            let provider = MacArticleSpeechSettings.provider
            return ArticleSpeechVoiceRating.preferenceKey(
                modelID: textToSpeechModelID(for: provider),
                voiceID: MacArticleSpeechSettings.voice(for: provider)
            )
        }
        return AppSettingEntry(
            id: "read_aloud.voice_rating",
            pane: "Voice › Text to Speech",
            title: "Voice rating",
            detail: "The learner's thumbs up or down on the currently selected text-to-speech voice with the selected model, or none. Only the learner's own taste; it changes nothing that is billed.",
            reach: .account,
            kind: .choice,
            preferenceKeys: [ratingKey()],
            options: {
                [
                    ["value": "up", "label": "Thumbs up"],
                    ["value": "down", "label": "Thumbs down"],
                    ["value": "none", "label": "No rating"],
                ]
            },
            read: {
                UserDefaults.standard.string(forKey: ratingKey())
                    .flatMap(ArticleSpeechVoiceRating.init(rawValue:))?.rawValue ?? "none"
            },
            write: { value in
                let raw = try AppSettingEntry.string(value, "read_aloud.voice_rating")
                let key = ratingKey()
                if raw == "none" {
                    PreferenceStore.remove(forKey: key)
                } else if let rating = ArticleSpeechVoiceRating(rawValue: raw) {
                    PreferenceStore.set(rating.rawValue, forKey: key)
                } else {
                    throw MCPError.invalidInput("read_aloud.voice_rating takes one of: up, down, none.")
                }
            }
        )
    }
}
