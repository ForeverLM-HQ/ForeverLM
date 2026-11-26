// Article speech tests: narration chunking, text-to-speech catalog, routes and estimates.

import AVFoundation
import Foundation
import Testing
@testable import ForeverLM

extension ArticleSpeechContentTests {
    // MARK: - Narration chunking

    /// Collapses all whitespace so chunk contents can be compared against the
    /// input regardless of how the chunker joined paragraphs and sentences.
    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("lead chunk packs sentences after a heading instead of shipping the heading alone")
    func leadChunkPacksSentencesAfterHeading() {
        // A chapter heading followed by a paragraph too long for the lead
        // limit used to flush the heading alone as chunk 0 — two seconds of
        // audio, after which playback ran dry waiting for chunk 1.
        let heading = "9. Healthy Choices"
        let sentence = "Living a healthy life will improve your chances of being saved by future technology."
        let paragraph = Array(repeating: sentence, count: 20).joined(separator: " ")
        let text = "\(heading)\n\n\(paragraph)"

        let chunks = ArticleSpeechService.narrationChunks(
            from: text,
            maxLength: 2_000,
            firstChunkMaxLength: 500
        )

        #expect(chunks.count > 1)
        #expect(chunks[0].hasPrefix(heading))
        #expect(chunks[0].contains(sentence))
        #expect(chunks[0].count <= 500)
        #expect(chunks.dropFirst().allSatisfy { $0.count <= 2_000 })
        #expect(normalized(chunks.joined(separator: " ")) == normalized(text))
    }

    @Test("the opening chunks stay short before full-size chunks take over")
    func leadRampKeepsTheFirstChunksShort() {
        let sentence = "Living a healthy life will improve your chances of being saved by future technology."
        let paragraph = Array(repeating: sentence, count: 60).joined(separator: " ")
        let text = Array(repeating: paragraph, count: 4).joined(separator: "\n\n")

        let chunks = ArticleSpeechService.narrationChunks(
            from: text,
            maxLength: 2_000,
            firstChunkMaxLength: 500,
            leadChunkCount: 3
        )

        #expect(chunks.count > 4)
        // Three quick requests, then the full-size chunks playback has time for.
        #expect(chunks.prefix(3).allSatisfy { $0.count <= 500 })
        #expect(chunks.dropFirst(3).contains { $0.count > 500 })
        #expect(chunks.allSatisfy { $0.count <= 2_000 })
        #expect(normalized(chunks.joined(separator: " ")) == normalized(text))
    }

    @Test("heading and paragraph that fit the lead limit together stay one chunk")
    func leadChunkKeepsFittingParagraphIntact() {
        let text = "9. Healthy Choices\n\nA short opening paragraph."

        let chunks = ArticleSpeechService.narrationChunks(
            from: text,
            maxLength: 2_000,
            firstChunkMaxLength: 500
        )

        #expect(chunks == ["9. Healthy Choices\n\nA short opening paragraph."])
    }

    @Test("a first sentence too long for the lead chunk still flushes the heading alone")
    func oversizedFirstSentenceFallsBackToBareLeadChunk() {
        let heading = "9. Healthy Choices"
        let longSentence = "This single sentence keeps going without any terminator so it cannot be packed into the remaining lead-chunk room "
            + String(repeating: "and keeps adding words ", count: 25)
            + "until it finally ends."
        let text = "\(heading)\n\n\(longSentence)"

        let chunks = ArticleSpeechService.narrationChunks(
            from: text,
            maxLength: 2_000,
            firstChunkMaxLength: 500
        )

        #expect(chunks.first == heading)
        #expect(normalized(chunks.joined(separator: " ")) == normalized(text))
    }

    @Test("chunks after the lead still break on paragraph boundaries")
    func laterChunksKeepParagraphBoundaries() {
        let first = String(repeating: "Lead sentence padding here. ", count: 30).trimmingCharacters(in: .whitespaces)
        let second = String(repeating: "Second paragraph content sentence. ", count: 40).trimmingCharacters(in: .whitespaces)
        let text = "\(first)\n\n\(second)"

        let chunks = ArticleSpeechService.narrationChunks(
            from: text,
            maxLength: 2_000,
            firstChunkMaxLength: 500
        )

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 2_000 })
        #expect(normalized(chunks.joined(separator: " ")) == normalized(text))
    }

    @Test("body paragraphs are packed together without splitting either paragraph")
    func bodyParagraphsShareSynthesisContext() {
        // Paragraph packing is independent from the separately tested fast
        // lead. Both paragraphs fit intact and should share one request.
        let bodyA = "The first body paragraph makes a single self-contained point."
        let bodyB = "The second body paragraph makes an entirely separate point."
        let text = "\(bodyA)\n\n\(bodyB)"

        let chunks = ArticleSpeechService.narrationChunks(
            from: text,
            maxLength: 2_000
        )

        #expect(chunks == ["\(bodyA)\n\n\(bodyB)"])
        #expect(normalized(chunks.joined(separator: " ")) == normalized(text))
    }

    /// The product owner (2026-09-27): "it can just be done via openrouter". Gemini went
    /// to Google's own API until then; it is an OpenRouter model now, under
    /// the same slug, on OpenRouter's speech endpoint, on the learner's key.
    @Test("Gemini narration goes to OpenRouter's speech endpoint")
    func mobileCloudNarrationUsesOpenRouterSpeechRoute() throws {
        // The learner's own OpenRouter key: the request goes straight to OpenRouter.
        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let selection = CloudArticleTTS.Selection(
            model: "google/gemini-3.1-flash-tts-preview",
            voice: "Kore"
        )
        let request = try AIUsageAttribution.$sourceTitle.withValue("Learning — 100%") {
            try AIUsageAttribution.$task.withValue("read_aloud") {
                try CloudArticleTTS.speechRequest(
                    text: "A short narration probe.",
                    selection: selection
                )
            }
        }

        #expect(request.url?.host == "openrouter.ai")
        #expect(request.url?.path == "/api/v1/audio/speech")
        // Attribution is for ForeverLM's local ledger; none of it is sent to OpenRouter.
        #expect(request.value(forHTTPHeaderField: "X-ForeverLM-Task") == nil)
        #expect(request.value(forHTTPHeaderField: "X-ForeverLM-Source-Title") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test-key")

        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "google/gemini-3.1-flash-tts-preview")
        #expect(payload["voice"] as? String == "Kore")
        #expect(payload["input"] as? String == "A short narration probe.")
        // Google's 24 kHz PCM, transcoded on arrival.
        #expect(payload["response_format"] as? String == "pcm")
        #expect(payload["contents"] == nil)
    }

    @Test("Grok narration goes to OpenRouter's speech endpoint, not xAI's")
    func grokNarrationUsesOpenRouterSpeechRoute() throws {
        // The learner's own OpenRouter key: the request goes straight to OpenRouter.
        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let request = try AIUsageAttribution.$task.withValue("read_aloud") {
            try CloudArticleTTS.speechRequest(
                text: "A short narration probe.",
                selection: CloudArticleTTS.Selection(
                    model: ArticleSpeechCatalog.grokModelID,
                    voice: "eve"
                )
            )
        }

        #expect(request.url?.host == "openrouter.ai")
        #expect(request.url?.path == "/api/v1/audio/speech")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == ArticleSpeechCatalog.grokModelID)
        #expect(payload["input"] as? String == "A short narration probe.")
        #expect(payload["voice"] as? String == "eve")
        #expect(payload["response_format"] as? String == "mp3")
        #expect(payload["voice_id"] == nil)
    }

    @Test("the speech catalog keeps its default and its recorded retirements")
    func speechCatalogKeepsDefaultAndRetirements() throws {
        #expect(MacArticleSpeechSettings.defaultOpenRouterModel == "google/gemini-3.1-flash-tts-preview")
        #expect(MacArticleSpeechSettings.defaultOpenRouterVoice == "Kore")
        #expect(MacArticleSpeechSettings.isRetiredModel("canopylabs/orpheus-3b-0.1-ft"))
        #expect(MacArticleSpeechSettings.isRetiredModel("zyphra/zonos-v0.1-transformer"))
        #expect(MacArticleSpeechSettings.isRetiredModel("zyphra/zonos-v0.1-hybrid"))
        // One provider for every model: what a manifest records.
        #expect(ArticleSpeechCatalog.provider == "openrouter")
        #expect(MacArticleSpeechSettings.openRouterModels.contains("sesame/csm-1b"))
        #expect(!MacArticleSpeechSettings.preferredModels(for: .togetherAI).contains {
            $0.localizedCaseInsensitiveContains("kokoro")
        })
    }

    @Test("router-only narration keeps OpenRouter's media route")
    func routerOnlyNarrationUsesOpenRouterMedia() throws {
        // The learner's own OpenRouter key: the request goes straight to OpenRouter.
        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let request = try AIUsageAttribution.$task.withValue("read_aloud") {
            try CloudArticleTTS.speechRequest(
                text: "A short narration probe.",
                selection: CloudArticleTTS.Selection(
                    model: "sesame/csm-1b",
                    voice: "read_speech_a"
                )
            )
        }

        #expect(request.url?.host == "openrouter.ai")
        #expect(request.url?.path == "/api/v1/audio/speech")
    }

    @Test("transcription goes to OpenRouter for every model, GPT-4o mini included")
    func transcriptionRoutingIsOpenRouterOnly() {
        // The balance's routes; a key in the developer's Keychain would move them.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let mini = ManagedTranscriptionClient.route(for: "openai/gpt-4o-mini-transcribe")
        #expect(mini.providerName == "OpenRouter")
        #expect(mini.model == "openai/gpt-4o-mini-transcribe")
        #expect(mini.endpoint.host == "openrouter.ai")

        let routed = ManagedTranscriptionClient.route(for: "nvidia/parakeet-tdt-0.6b-v3")
        #expect(routed.providerName == "OpenRouter")
        #expect(routed.model == "nvidia/parakeet-tdt-0.6b-v3")
    }

    @Test("mobile cloud narration accepts metered MP3 responses")
    func mobileCloudNarrationAcceptsMeteredMP3Responses() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://ai.foreverlm.com")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "audio/mpeg",
                "x-foreverlm-request-id": "request-123",
            ]
        ))
        let data = Data([0xFF, 0xFB] + Array(repeating: 0, count: 256))

        let validated = try CloudArticleTTS.validatedSpeechResponse(data: data, response: response)

        #expect(validated.data == data)
        #expect(validated.requestID == "request-123")
        #expect(validated.contentType == "audio/mpeg")
        #expect(validated.fileExtension == "mp3")
    }

    @Test("Gemini PCM narration is transcoded into a playable M4A")
    func mobileCloudNarrationTranscodesGeminiPCM() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://ai.foreverlm.com")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "audio/pcm",
                "x-foreverlm-request-id": "request-pcm-123",
            ]
        ))
        // One second of 24 kHz, mono, signed 16-bit silence.
        let pcm = Data(repeating: 0, count: 24_000 * MemoryLayout<Int16>.size)

        let validated = try CloudArticleTTS.validatedSpeechResponse(
            data: pcm,
            response: response,
            model: "google/gemini-3.1-flash-tts-preview"
        )

        #expect(validated.data != pcm)
        #expect(validated.requestID == "request-pcm-123")
        #expect(validated.contentType == "audio/mp4")
        #expect(validated.fileExtension == "m4a")
        let player = try AVAudioPlayer(data: validated.data)
        #expect(player.duration > 0.9)
        #expect(player.duration < 1.1)
    }

    @Test("mobile cloud narration rejects non-audio success responses")
    func mobileCloudNarrationRejectsNonAudioSuccessResponses() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://ai.foreverlm.com")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "application/json",
                "x-foreverlm-request-id": "request-123",
            ]
        ))

        #expect(throws: CloudArticleTTS.GenerationError.self) {
            try CloudArticleTTS.validatedSpeechResponse(
                data: Data("{\"error\":\"not audio\"}".utf8),
                response: response
            )
        }
    }

    @Test("mobile cloud narration rejects unmetered audio")
    func mobileCloudNarrationRejectsUnmeteredAudio() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://ai.foreverlm.com")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "audio/mpeg"]
        ))
        let data = Data([0xFF, 0xFB] + Array(repeating: 0, count: 256))

        #expect(throws: CloudArticleTTS.GenerationError.self) {
            try CloudArticleTTS.validatedSpeechResponse(data: data, response: response)
        }
    }

    @Test("audio an own OpenRouter key bought needs no ForeverLM receipt")
    func ownKeyNarrationNeedsNoProxyReceipt() throws {
        // `ManagedAI.rewrite` sends an own-key request to openrouter.ai itself,
        // so the proxy never sees it and has no debit to give a receipt for.
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://openrouter.ai/api/v1/audio/speech")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "audio/mpeg"]
        ))
        let data = Data([0xFF, 0xFB] + Array(repeating: 0, count: 256))

        let validated = try CloudArticleTTS.validatedSpeechResponse(data: data, response: response)

        #expect(validated.data == data)
        #expect(validated.requestID == nil)
    }

    @Test("mobile cloud narration rejects corrupt MP3 bytes")
    func mobileCloudNarrationRejectsCorruptMP3Bytes() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://ai.foreverlm.com")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "audio/mpeg",
                "x-foreverlm-request-id": "request-123",
            ]
        ))

        #expect(throws: CloudArticleTTS.GenerationError.self) {
            try CloudArticleTTS.validatedSpeechResponse(
                data: Data(repeating: 0, count: 512),
                response: response
            )
        }
    }

    // MARK: - Text-to-speech catalog and model selection

    /// Both platforms read one catalog, so a model offered in the iPhone's
    /// picker is a model the Mac's picker offers too — and every model this
    /// build curates names at least one voice. (A directory model with no
    /// voice list is offered too; `SpeechDirectoryTests` covers it.)
    @Test("the text-to-speech catalog is the one both platforms offer")
    func textToSpeechCatalogIsShared() {
        #expect(MacArticleSpeechSettings.openRouterModels == ArticleSpeechCatalog.models.map(\.id))
        #expect(ArticleSpeechCatalog.model(id: ArticleSpeechCatalog.defaultModelID) != nil)
        #expect(!ArticleSpeechCatalog.models.isEmpty)

        for model in ArticleSpeechCatalog.models {
            #expect(!ArticleSpeechCatalog.isRetiredModel(model.id))
            #expect(model.leadChunkLimit <= model.chunkLimit)
            #expect(model.chunkLimit > 0)
            #expect(!model.voices.isEmpty)
            for voice in model.voices {
                #expect(!voice.id.isEmpty)
                #expect(ArticleSpeechCatalog.voiceLabel(model: model.id, voice: voice.id) == voice.name)
            }
        }

        // Voice labels are display metadata; the Mac's picker reads them from
        // the same place as the phone's.
        #expect(
            MacArticleSpeechSettings.openRouterVoiceLabel(
                model: "deepgram/aura-2",
                voice: "aura-2-thalia-en"
            ) == "🇺🇸 Thalia"
        )
        #expect(
            MacArticleSpeechSettings.openRouterVoiceLabel(
                model: "microsoft/mai-voice-2",
                voice: "en-US-Harper:MAI-Voice-2"
            ) == "🇺🇸 Harper"
        )
        #expect(
            MacArticleSpeechSettings.openRouterVoiceLabel(
                model: "microsoft/mai-voice-2",
                voice: "de-DE-Klaus:MAI-Voice-2"
            ) == "🇩🇪 Klaus"
        )
        #expect(
            MacArticleSpeechSettings.openRouterVoiceLabel(
                model: ArticleSpeechCatalog.grokModelID,
                voice: "eve"
            ) == "Eve"
        )
        #expect(MacArticleSpeechSettings.geminiVoices.contains("Kore"))
    }

    /// A selection stored by an older build must never travel to the wire: an
    /// unknown model or a voice its model does not list is exactly the 400 this
    /// resolution exists to prevent.
    @Test("a stored selection the catalog no longer offers resolves to the default")
    func storedSelectionOutsideTheCatalogResolvesToTheDefault() throws {
        let suiteName = "readAloudSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ArticleSpeechSelection.modelID(defaults: defaults) == ArticleSpeechCatalog.defaultModelID)

        defaults.set("canopylabs/orpheus-3b-0.1-ft", forKey: ArticleSpeechSelection.modelDefaultsKey)
        #expect(ArticleSpeechSelection.modelID(defaults: defaults) == ArticleSpeechCatalog.defaultModelID)

        // What the request path does with a stored model the list does not
        // offer is the repair's (`PhoneTextToSpeechPickTests`): it depends on
        // whether this host has read OpenRouter's list.
        defaults.set("some/model-that-never-existed", forKey: ArticleSpeechSelection.modelDefaultsKey)
        #expect(ArticleSpeechSelection.modelID(defaults: defaults) == ArticleSpeechCatalog.defaultModelID)

        ArticleSpeechSelection.selectModel("deepgram/aura-2", defaults: defaults)
        #expect(ArticleSpeechSelection.modelID(defaults: defaults) == "deepgram/aura-2")

        // A Gemini voice is not an Aura voice: the stored id is dropped for the
        // model's own first voice rather than sent.
        defaults.set(
            "Kore",
            forKey: ArticleSpeechSelection.voiceDefaultsKey(forModel: "deepgram/aura-2")
        )
        #expect(
            ArticleSpeechSelection.voiceID(forModel: "deepgram/aura-2", defaults: defaults)
                == "aura-2-thalia-en"
        )
        // The request path repairs it, as the Mac repairs its own, and writes
        // the repair back; it no longer sends the listener to Settings.
        #expect(
            try CloudArticleTTS.currentSelection(defaults: defaults)
                == CloudArticleTTS.Selection(model: "deepgram/aura-2", voice: "aura-2-thalia-en")
        )
        #expect(
            defaults.string(forKey: ArticleSpeechSelection.voiceDefaultsKey(forModel: "deepgram/aura-2"))
                == "aura-2-thalia-en"
        )

        ArticleSpeechSelection.selectVoice("aura-2-zeus-en", forModel: "deepgram/aura-2", defaults: defaults)
        #expect(
            ArticleSpeechSelection.voiceID(forModel: "deepgram/aura-2", defaults: defaults)
                == "aura-2-zeus-en"
        )
    }

    @Test("the account's text-to-speech pick is adopted on this device, with the voice resolved against the model")
    func syncedSelectionIsAdopted() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "ArticleSpeechSelectionSyncTests-\(UUID().uuidString)")
        )

        let applied = ArticleSpeechSelection.adoptSyncedSelection(
            model: "deepgram/aura-2",
            voice: "aura-2-zeus-en",
            defaults: defaults
        )
        #expect(applied?.model == "deepgram/aura-2")
        #expect(applied?.voice == "aura-2-zeus-en")
        #expect(ArticleSpeechSelection.modelID(defaults: defaults) == "deepgram/aura-2")
        #expect(
            ArticleSpeechSelection.voiceID(forModel: "deepgram/aura-2", defaults: defaults)
                == "aura-2-zeus-en"
        )

        // The Mac keeps one voice row for whichever model is current, so a
        // voice recorded for another model resolves to this model's first voice.
        let gemini = ArticleSpeechSelection.adoptSyncedSelection(
            model: ArticleSpeechCatalog.defaultModelID,
            voice: "aura-2-zeus-en",
            defaults: defaults
        )
        #expect(gemini?.voice == ArticleSpeechCatalog.model(id: ArticleSpeechCatalog.defaultModelID)?.defaultVoiceID)
        #expect(gemini?.voice != "aura-2-zeus-en")

        // A retired or unknown model on the account leaves this device's pick alone.
        #expect(ArticleSpeechSelection.adoptSyncedSelection(
            model: "canopylabs/orpheus-3b-0.1-ft", voice: nil, defaults: defaults
        ) == nil)
        #expect(ArticleSpeechSelection.adoptSyncedSelection(
            model: "nobody/nothing", voice: nil, defaults: defaults
        ) == nil)
        #expect(ArticleSpeechSelection.adoptSyncedSelection(
            model: nil, voice: nil, defaults: defaults
        ) == nil)
        #expect(ArticleSpeechSelection.modelID(defaults: defaults) == ArticleSpeechCatalog.defaultModelID)
    }

    /// The phone writes the rows the Mac's text-to-speech Settings read, so the
    /// two cannot drift apart without this failing.
    @Test("the phone's synced text-to-speech rows are the Mac's")
    func syncedSelectionKeysMatchTheMacs() {
        #expect(ArticleSpeechSelection.syncedModelKey == KeychainService.Key.ttsModelOpenRouter.rawValue)
        #expect(ArticleSpeechSelection.syncedProviderKey == KeychainService.Key.ttsProvider.rawValue)
        #expect(ArticleSpeechSelection.syncedProvider == MacArticleSpeechMode.openRouter.rawValue)
        #expect(SyncedPreferenceKeys.isSynced(ArticleSpeechSelection.syncedModelKey))
        #expect(SyncedPreferenceKeys.isSynced(ArticleSpeechSelection.syncedVoiceKey))
        #expect(SyncedPreferenceKeys.isSynced(ArticleSpeechSelection.syncedProviderKey))
    }

    // MARK: - Source language

    /// The whole point of the language check: a source in another language must
    /// not be handed to an English-only voice, which would generate — and bill
    /// for — fluent-sounding nonsense.
    @Test("a non-English source moves off an English-only voice to one that speaks it")
    func nonEnglishSourceLeavesAnEnglishOnlyVoice() {
        let fit = ArticleSpeechCatalog.languageFit(
            for: "nl",
            model: "deepgram/aura-2",
            voice: "aura-2-thalia-en"
        )
        let replacement = fit.replacement
        #expect(replacement != nil)
        #expect(replacement?.model == ArticleSpeechCatalog.defaultModelID)
        #expect(replacement?.voice == ArticleSpeechCatalog.defaultVoiceID)
        #expect(fit != .supported)
    }

    /// A voice built for the language beats changing models: MAI ships one
    /// voice per language, and German text belongs on the German one.
    @Test("a language another voice of the same model speaks stays on that model")
    func aSiblingVoiceIsPreferredOverANewModel() {
        let fit = ArticleSpeechCatalog.languageFit(
            for: "de",
            model: "microsoft/mai-voice-2",
            voice: "en-US-Harper:MAI-Voice-2"
        )
        #expect(fit == .otherVoice(model: "microsoft/mai-voice-2", voice: "de-DE-Klaus:MAI-Voice-2"))
    }

    /// English on an English voice, and any language on a multilingual model,
    /// must both leave the listener's own selection alone.
    @Test("a selection that already speaks the language is left alone")
    func aCapableSelectionIsUntouched() {
        #expect(
            ArticleSpeechCatalog.languageFit(
                for: "en",
                model: "deepgram/aura-2",
                voice: "aura-2-thalia-en"
            ) == .supported
        )
        #expect(
            ArticleSpeechCatalog.languageFit(
                for: "ja",
                model: ArticleSpeechCatalog.defaultModelID,
                voice: ArticleSpeechCatalog.defaultVoiceID
            ) == .supported
        )
    }

    /// Every model in the picker has to declare what it can narrate, or a new
    /// entry silently inherits "reads everything" and the check goes quiet.
    @Test("every catalog model narrates the language its voices claim")
    func everyModelDeclaresItsLanguages() {
        for model in ArticleSpeechCatalog.models {
            for voice in model.voices {
                let support = model.languageSupport(voice: voice.id)
                if case .languages(let codes) = support {
                    #expect(!codes.isEmpty)
                    for code in codes {
                        #expect(model.speaks(code, voice: voice.id))
                    }
                }
            }
        }
    }

    /// The default model is what every other model falls back to, so its
    /// language list is the app's real text-to-speech reach. Google publishes more
    /// than seventy languages for Gemini TTS; a regression that quietly
    /// shrinks the set would silently reroute non-English sources to a
    /// best-effort free model without anyone noticing.
    @Test("the default model narrates the languages Gemini publishes")
    func geminiNarratesItsPublishedLanguages() throws {
        let gemini = try #require(ArticleSpeechCatalog.model(id: ArticleSpeechCatalog.defaultModelID))
        guard case .languages(let codes) = gemini.languages else {
            Issue.record("Gemini must publish an explicit language list, not .multilingual")
            return
        }
        #expect(codes.count >= 70)
        #expect(codes.allSatisfy { $0 == $0.lowercased() })

        // One per script family the recognizer can actually return, so the set
        // is checked for reach rather than for size.
        for code in ["nl", "de", "es", "pt", "ja", "zh", "ko", "hi", "ar", "he",
                     "ru", "uk", "el", "th", "vi", "ta", "sw", "tr", "id", "fa"] {
            #expect(
                ArticleSpeechCatalog.languageFit(
                    for: code,
                    model: ArticleSpeechCatalog.defaultModelID,
                    voice: ArticleSpeechCatalog.defaultVoiceID
                ) == .supported,
                "Gemini should narrate \(code)"
            )
        }
    }

    /// The other half of declaring a list: a language Google does not publish
    /// must not be claimed. Gemini returns billable audio for Welsh either
    /// way — the declaration is what turns that into a substitution the
    /// listener is told about instead of fluent-sounding nonsense.
    @Test("a language Gemini does not publish moves off the default selection")
    func anUnpublishedLanguageLeavesGemini() {
        let fit = ArticleSpeechCatalog.languageFit(
            for: "cy",
            model: ArticleSpeechCatalog.defaultModelID,
            voice: ArticleSpeechCatalog.defaultVoiceID
        )
        #expect(fit != .supported)
        #expect(fit.replacement?.model != ArticleSpeechCatalog.defaultModelID)
    }

    /// A non-English source on an English-only model belongs on Gemini rather
    /// than on whichever multilingual model happens to sort first: it is the
    /// product default, and it publishes the language by name.
    @Test("English-only selections fall back to Gemini for languages it publishes")
    func englishOnlySelectionsFallBackToGemini() {
        for code in ["nl", "ja", "hi", "ar", "uk", "vi"] {
            let fit = ArticleSpeechCatalog.languageFit(
                for: code,
                model: "deepgram/aura-2",
                voice: "aura-2-thalia-en"
            )
            #expect(fit.replacement?.model == ArticleSpeechCatalog.defaultModelID, "for \(code)")
            #expect(fit.replacement?.voice == ArticleSpeechCatalog.defaultVoiceID, "for \(code)")
        }
    }

    /// Detection is deliberately quiet: a title, a heading, or a fragment must
    /// never be enough to move the listener off their chosen voice.
    @Test("short or ambiguous text is not classified")
    func shortTextIsNotClassified() {
        #expect(ArticleSpeechLanguage.detect(in: "") == nil)
        #expect(ArticleSpeechLanguage.detect(in: "Hallo daar.") == nil)
        #expect(ArticleSpeechLanguage.sample(from: String(repeating: "a ", count: 10)) == nil)
    }

    @Test("real prose is classified, and the resolution follows it")
    func proseIsClassified() {
        let dutch = String(
            repeating: """
                De onderzoekers beschrijven hoe het geheugen zich gedraagt wanneer een \
                herinnering telkens opnieuw wordt opgehaald. Elke ophaalpoging verandert \
                het spoor zelf, waardoor de herinnering na verloop van tijd stabieler \
                maar ook onnauwkeuriger wordt.

                """,
            count: 4
        )
        #expect(ArticleSpeechLanguage.detect(in: dutch) == "nl")

        let resolution = ArticleSpeechLanguageResolution.resolve(
            text: dutch,
            model: "deepgram/aura-2",
            voice: "aura-2-thalia-en"
        )
        #expect(resolution.languageCode == "nl")
        #expect(resolution.changesSelection)
        #expect(resolution.model != "deepgram/aura-2")
        #expect(resolution.message?.contains(ArticleSpeechLanguage.displayName(for: "nl")) == true)

        let english = String(
            repeating: """
                The researchers describe how memory behaves when a recollection is \
                retrieved again and again. Every retrieval changes the trace itself, so \
                over time the memory becomes both more stable and less accurate.

                """,
            count: 4
        )
        let unchanged = ArticleSpeechLanguageResolution.resolve(
            text: english,
            model: "deepgram/aura-2",
            voice: "aura-2-thalia-en"
        )
        #expect(unchanged.outcome == .supported)
        #expect(unchanged.model == "deepgram/aura-2")
        #expect(unchanged.message == nil)
    }

    /// Script and region variants are the same narration problem as the bare
    /// language, and the catalog declares support by language.
    @Test("script and region subtags collapse to the language")
    func subtagsCollapse() {
        #expect(ArticleSpeechLanguage.primaryCode("zh-Hans") == "zh")
        #expect(ArticleSpeechLanguage.primaryCode("pt-BR") == "pt")
        #expect(ArticleSpeechLanguage.primaryCode("und") == nil)
    }

    /// Chunk sizes belong to the model, so switching models has to re-chunk:
    /// a section sized for Gemini's context is a rejected request elsewhere.
    @Test("narration chunks respect the selected model's limits")
    func narrationChunksRespectTheSelectedModelsLimits() {
        let paragraph = String(
            repeating: "This sentence carries a complete thought for the narrator to read. ",
            count: 200
        ).trimmingCharacters(in: .whitespaces)

        for model in ArticleSpeechCatalog.models {
            let chunks = CloudArticleTTS.chunk(
                paragraph,
                limit: model.chunkLimit,
                leadLimit: model.leadChunkLimit
            )
            #expect(!chunks.isEmpty)
            #expect(chunks.allSatisfy { $0.count <= model.chunkLimit })
            #expect((chunks.first?.count ?? 0) <= model.leadChunkLimit)
        }
    }

    @Test("Grok text-to-speech units stay ahead of fast playback")
    func grokTextToSpeechUsesLatencyBoundedChunks() throws {
        let grok = try #require(ArticleSpeechCatalog.model(id: "x-ai/grok-voice-tts-1.0"))

        #expect(grok.leadChunkLimit == 1_000)
        #expect(grok.chunkLimit == 1_000)
    }

    @Test("Gemini starts with one short sentence-sized synthesis request")
    func geminiTextToSpeechUsesFastOpeningChunk() throws {
        let gemini = try #require(
            ArticleSpeechCatalog.model(id: "google/gemini-3.1-flash-tts-preview")
        )

        #expect(gemini.leadChunkLimit == 240)
        #expect(gemini.chunkLimit == 800)

        let text = """
        Twenty Years In Early Stage Biotech VC (Part 1): Science

        In the blink of an eye, twenty years have passed: in mid-October 2005, I joined Atlas Venture as a principal on the global life science team. We closed Fund VII a few months later. The team began its next chapter together.
        """
        let chunks = CloudArticleTTS.chunk(
            text,
            limit: gemini.chunkLimit,
            leadLimit: gemini.leadChunkLimit
        )

        #expect(chunks.count == 2)
        #expect(chunks[0].contains("global life science team."))
        #expect(chunks[0].count <= 240)
    }

    /// The lead is short so sound starts within seconds; the unit after it is
    /// lead-sized too, since it is requested alongside the opening and has to
    /// land while the opening plays; the units after that double until the
    /// model's limit, so playback never falls silent between them.
    @Test("narration units ramp up from the lead to the model's limit")
    func narrationUnitsRampUpFromTheLead() {
        let sentence = "This sentence carries a complete thought for the narrator to read. "
        let text = String(repeating: sentence, count: 120)
            .trimmingCharacters(in: .whitespaces)
        let chunks = CloudArticleTTS.chunk(text, limit: 800, leadLimit: 240)

        #expect(chunks.count >= 5)
        #expect(chunks[0].count <= 240)
        #expect(chunks[1].count <= 240)
        #expect(chunks[2].count <= 480)
        #expect(chunks[2].count > 240)
        #expect(chunks[3].count <= 800)
        #expect(chunks[3].count > 480)
        #expect(chunks.dropFirst(4).allSatisfy { $0.count <= 800 })
        // Nothing is lost or reordered by the ramp.
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test("a model whose lead is its limit does not ramp")
    func narrationUnitsWithoutARampStayUniform() {
        let sentence = "This sentence carries a complete thought for the narrator to read. "
        let text = String(repeating: sentence, count: 60)
            .trimmingCharacters(in: .whitespaces)
        let chunks = CloudArticleTTS.chunk(text, limit: 1_000, leadLimit: 1_000)

        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.count <= 1_000 })
        #expect(chunks.dropLast().allSatisfy { $0.count > 900 })
    }

    @Test("out-of-order narration results release only a contiguous prefix")
    func narrationResultsReleaseContiguously() {
        var results = CloudArticleTTS.ContiguousResultBuffer<String>(count: 4)

        #expect(results.insert("third", at: 2).isEmpty)
        #expect(results.insert("first", at: 0) == ["first"])
        #expect(results.insert("second", at: 1) == ["second", "third"])
        #expect(results.orderedValues == nil)
        #expect(results.insert("fourth", at: 3) == ["fourth"])
        #expect(results.orderedValues == ["first", "second", "third", "fourth"])
    }

    @Test("opening narration requests jump ahead of queued continuation chunks")
    func openingNarrationRequestsHavePriority() async throws {
        let scheduler = ArticleSpeechRequestScheduler(maxConcurrentRequests: 1)
        let recorder = SpeechSchedulerRecorder()

        // Hold the only permit while the deliberately out-of-order queue is
        // assembled. Waiting after each insert makes arrival order deterministic
        // without depending on Task scheduling.
        try await scheduler.acquire(priority: .opening)
        let laterContinuation = Task {
            try await scheduler.acquire(priority: .continuation(index: 2))
            await recorder.append("third")
            await scheduler.release()
        }
        try await waitForScheduler(scheduler, waitingCount: 1)

        let earlierContinuation = Task {
            try await scheduler.acquire(priority: .continuation(index: 0))
            await recorder.append("second")
            await scheduler.release()
        }
        try await waitForScheduler(scheduler, waitingCount: 2)

        let newOpening = Task {
            try await scheduler.acquire(priority: .opening)
            await recorder.append("opening")
            await scheduler.release()
        }
        try await waitForScheduler(scheduler, waitingCount: 3)

        await scheduler.release()
        try await newOpening.value
        try await earlierContinuation.value
        try await laterContinuation.value

        let recordedValues = await recorder.values
        #expect(recordedValues == ["opening", "second", "third"])
    }

    private func waitForScheduler(
        _ scheduler: ArticleSpeechRequestScheduler,
        waitingCount: Int
    ) async throws {
        for _ in 0..<100 {
            if await scheduler.snapshot().waitingCount == waitingCount { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(waitingCount) queued speech requests.")
    }

    /// Regression for the observed Grok response: 444 words were compressed
    /// into 78.5 seconds by skipping paragraphs and inventing speech. The first
    /// five chunks established a real pace of about 158 words per minute.
    @Test("implausibly short long-form TTS is rejected")
    func implausiblyShortLongFormSpeechIsRejected() {
        let text = Array(repeating: "narrated", count: 444).joined(separator: " ")

        #expect(ArticleSpeechAudioValidation.failureReason(text: text, duration: 78.5) != nil)
        #expect(ArticleSpeechAudioValidation.failureReason(text: text, duration: 171) == nil)
    }

    @Test("short voice previews do not use long-form duration heuristics")
    func shortVoicePreviewSkipsLongFormDurationHeuristic() {
        let text = Array(repeating: "preview", count: 20).joined(separator: " ")

        #expect(ArticleSpeechAudioValidation.failureReason(text: text, duration: 1) == nil)
    }

    @Test("voice preview warm-up covers every catalog voice with the fixed sample")
    func voicePreviewWarmupCoverage() {
        #expect(
            ArticleSpeechVoicePreviewRepository.sampleText
                == "Mitochondria are much more than just the powerhouse of the cell"
        )
        let pairs = ArticleSpeechVoicePreviewRepository.previewPairs(
            prioritizedModelID: ArticleSpeechCatalog.defaultModelID
        )
        #expect(pairs.count == ArticleSpeechCatalog.models.reduce(0) { $0 + $1.voices.count })
        #expect(Set(pairs.map { "\($0.modelID)|\($0.voiceID)" }).count == pairs.count)
        #expect(pairs.first?.modelID == ArticleSpeechCatalog.defaultModelID)

        let visiblePairs = ArticleSpeechVoicePreviewRepository.previewPairs(
            forModelID: "deepgram/flux-tts:free"
        )
        #expect(visiblePairs.count == ArticleSpeechCatalog.fluxVoices.count)
        #expect(visiblePairs.allSatisfy { $0.modelID == "deepgram/flux-tts:free" })
        #expect(Set(visiblePairs.map(\.voiceID)) == Set(ArticleSpeechCatalog.fluxVoices.map(\.id)))
    }

    /// The recovery for a section a model refuses: halve it and send both
    /// halves as their own ordered chunks. Nothing is concatenated, so the
    /// halves must together still be the whole text.
    @Test("a refused section splits at a sentence boundary without losing text")
    func refusedSectionSplitsAtSentenceBoundary() throws {
        let sentence = "The narrator reads one complete thought aloud. "
        let text = String(repeating: sentence, count: 40).trimmingCharacters(in: .whitespaces)

        let halves = try #require(CloudArticleTTS.split(text))
        #expect(halves.count == 2)
        #expect(halves.allSatisfy { !$0.isEmpty })
        #expect(halves.joined(separator: " ") == text)
        #expect(halves[0].hasSuffix("."))
        // Neither half may run away with the whole section, or splitting would
        // repeat the same rejected request.
        #expect(halves.allSatisfy { $0.count < text.count })

        // Short text is not the length the model objected to, so it is not
        // split again — the failure is surfaced instead.
        #expect(CloudArticleTTS.split("Too short to be a length problem.") == nil)
    }

    /// A selected model remains the only paid model attempted. In particular,
    /// Grok must not create a second Gemini charge after a failed request.
    @Test("Grok never starts a second paid provider after failure")
    func grokHasNoPaidFallbackModel() {
        let selection = CloudArticleTTS.Selection(
            model: ArticleSpeechCatalog.grokModelID,
            voice: "eve"
        )
        let candidates = CloudArticleTTS.candidateSelections(startingWith: selection)

        #expect(candidates == [selection])
    }

    @Test("non-Grok models have no substitute candidates")
    func nonGrokModelsHaveNoSubstituteCandidates() {
        let selection = CloudArticleTTS.Selection(model: "sesame/csm-1b", voice: "read_speech_a")
        let candidates = CloudArticleTTS.candidateSelections(startingWith: selection)

        #expect(candidates == [selection])
    }

    @Test("an unmetered speech response fails without splitting")
    func unmeteredSpeechResponseDoesNotCreateMorePaidRequests() {
        let unmetered = CloudArticleTTS.GenerationError.rejected(
            model: ArticleSpeechCatalog.grokModelID,
            statusCode: 502,
            reason: "ForeverLM AI could not price this speech request."
        )
        let malformedAudio = CloudArticleTTS.GenerationError.rejected(
            model: ArticleSpeechCatalog.grokModelID,
            statusCode: 200,
            reason: "The audio was implausibly short."
        )

        #expect(!unmetered.isSplittableRejection)
        #expect(malformedAudio.isSplittableRejection)
    }

    /// An empty balance or a lapsed session is about the account, not the
    /// model: retrying it against three more models spends nothing and tells
    /// the listener nothing.
    @Test("account failures are not retried against other models")
    func accountFailuresAreNotRetriedAgainstOtherModels() {
        for code in ["credits_empty", "invalid_session", "account_disabled", "spend_cap_reached"] {
            #expect(CloudArticleTTS.isAccountFailure(
                ManagedAI.ServiceError(code: code, message: "…")
            ))
        }
        #expect(!CloudArticleTTS.isAccountFailure(
            ManagedAI.ServiceError(code: "bad_request", message: "…")
        ))
    }

    /// A phone between cells has not been refused anything. The lost
    /// connection must not spend the retries that exist for an overloaded
    /// provider, or twenty seconds in a lift ends a paid generation.
    @Test("a lost connection is retried well past the provider budget")
    func transportFailuresKeepTheirOwnRetryBudget() {
        #expect(CloudArticleTTS.shouldRetryTransport(attempt: 1, elapsed: 0))
        // The fourth attempt is where the provider budget would have stopped.
        #expect(CloudArticleTTS.shouldRetryTransport(attempt: 4, elapsed: 30))
        #expect(CloudArticleTTS.shouldRetryTransport(attempt: 5, elapsed: 120))
        #expect(!CloudArticleTTS.shouldRetryTransport(attempt: 6, elapsed: 30))
        #expect(!CloudArticleTTS.shouldRetryTransport(
            URLError(.timedOut),
            attempt: 1,
            elapsed: 1
        ))
    }

    /// Retrying forever is its own failure: a listener held indefinitely never
    /// learns that the network, not the app, is what stopped.
    @Test("transport retries stop once being offline stops looking temporary")
    func transportRetriesStopAfterTheWindow() {
        #expect(!CloudArticleTTS.shouldRetryTransport(attempt: 2, elapsed: 300))
        #expect(!CloudArticleTTS.shouldRetryTransport(attempt: 2, elapsed: 900))
        #expect(CloudArticleTTS.shouldRetryTransport(attempt: 2, elapsed: 299))
    }

    /// Naming the real condition matters because this message is also spoken
    /// aloud: "Could not generate audio" sends a listener to Settings to change
    /// a voice that was never the problem.
    @Test("an offline failure is named as one, not as a failed request")
    func offlineFailuresAreNamedAsNetworkFailures() {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .dataNotAllowed,
            .internationalRoamingOff,
            .callIsActive,
            .dnsLookupFailed,
            .cannotFindHost,
            .cannotConnectToHost,
        ]
        for code in offlineCodes {
            #expect(CloudArticleTTS.isOfflineError(URLError(code)))
        }

        let offline = CloudArticleTTS.transportFailure(URLError(.networkConnectionLost))
        #expect(offline.errorDescription == CloudArticleTTS.GenerationError.networkUnavailable.errorDescription)
        #expect(offline.errorDescription?.contains("network connection") == true)
        #expect(offline.errorDescription?.contains("Could not generate audio") == false)

        // A slow provider is not an absent network, and a malformed answer is
        // not one either — both keep the plain retry-exhausted wording.
        #expect(!CloudArticleTTS.isOfflineError(URLError(.timedOut)))
        #expect(!CloudArticleTTS.isOfflineError(URLError(.badServerResponse)))
        #expect(
            CloudArticleTTS.transportFailure(URLError(.badServerResponse))
                .errorDescription?
                .hasPrefix("Could not generate audio:") == true
        )
    }

    /// The session, not the retry loop, is what survives a request made while
    /// the radio is down: without this the attempt fails instantly and the
    /// budget drains without one request reaching the rail.
    @Test("speech requests wait for connectivity instead of failing instantly")
    func speechSessionWaitsForConnectivity() {
        let configuration = CloudArticleTTS.session.configuration
        #expect(configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest == 240)
        #expect(configuration.timeoutIntervalForResource == CloudArticleTTS.resourceTimeout)
    }

    @Test("a text-to-speech estimate prices characters at the model's list rate")
    func textToSpeechEstimatePricesCharactersAtListRate() {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            // Kokoro is $0.62 per 1M characters.
            let kokoro = ArticleSpeechCostEstimate(
                characters: 1_000_000,
                provider: "openrouter",
                model: "hexgrad/kokoro-82m"
            )
            #expect(kokoro.usd == 0.62)
            #expect(kokoro.costLabel == "$0.62")

            // A free route reads as free, not as an unpriced model.
            let free = ArticleSpeechCostEstimate(
                characters: 1_000_000,
                provider: "openrouter",
                model: "deepgram/flux-tts:free"
            )
            #expect(free.usd == 0)
            #expect(free.costLabel == "free")

            // A model this build has no rate for must never render as free.
            let unknown = ArticleSpeechCostEstimate(
                characters: 1_000_000,
                provider: "openrouter",
                model: "some-lab/unlisted-tts"
            )
            #expect(unknown.usd == nil)
            #expect(unknown.costLabel == "price unknown")

            // A model OpenRouter bills by its tokens gets no total made up
            // from a character count; the quote states its own price instead.
            let gemini = ArticleSpeechCostEstimate(
                characters: 1_000_000,
                provider: "openrouter",
                model: "google/gemini-3.1-flash-tts-preview"
            )
            #expect(gemini.usd == nil)
            #expect(gemini.costLabel == "priced at $1 / $20 per 1M tokens")

            // A real charge below a cent is still a charge.
            let tiny = ArticleSpeechCostEstimate(
                characters: 100,
                provider: "openrouter",
                model: "hexgrad/kokoro-82m"
            )
            #expect(tiny.costLabel == "less than $0.01")
        }
    }

    @Test("a text-to-speech estimate reports listening length beside the price")
    func textToSpeechEstimateReportsListeningLength() {
        #expect(ArticleSpeechCostEstimate(characters: 300, usd: 0).durationLabel == "under a minute")
        #expect(ArticleSpeechCostEstimate(characters: 30_000, usd: 0).durationLabel == "about 40 min")
        #expect(ArticleSpeechCostEstimate(characters: 45_000, usd: 0).durationLabel == "about 1 hr")
        #expect(ArticleSpeechCostEstimate(characters: 90_750, usd: 0).durationLabel == "about 2 hr 1 min")
    }

    /// Listening auto-advances through a book, so the confirmation adds the
    /// chapter in hand to every other chapter that still needs generating. A
    /// chapter-sized quote for a book-sized charge is the bug this prevents.
    @Test("a book's estimate sums the chapter in hand with the rest of the book")
    func bookEstimateSumsChapterWithRemainingChapters() {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let chapter = ArticleSpeechCostEstimate(
                characters: 24_000,
                provider: "openrouter",
                model: "fish-audio/s2.1-pro"
            )
            let remaining = ArticleSpeechCostEstimate(
                characters: 776_000,
                sourceCount: 37,
                provider: "openrouter",
                model: "fish-audio/s2.1-pro"
            )
            let wholeBook = chapter.adding(remaining)

            #expect(wholeBook.characters == 800_000)
            #expect(wholeBook.sourceCount == 38)
            #expect(wholeBook.costLabel == "$12.00")
            #expect(
                wholeBook.summary(countingSourcesAs: "chapter")
                    == "38 chapters · \(800_000.formatted()) characters · about 17 hr 47 min · $12.00"
            )
            #expect(chapter.summary == "\(24_000.formatted()) characters · about 32 min · $0.36")
        }
    }

    /// Book chapters usually carry only a word count until their narration is
    /// prepared, so the chapter in hand calibrates the ratio for the rest.
    @Test("characters per word are calibrated from the chapter being generated")
    func charactersPerWordAreCalibratedFromTheChapterBeingGenerated() {
        #expect(
            ArticleSpeechCostEstimate.charactersPerWord(narrationCharacters: 24_000, wordCount: 4_000) == 6
        )
        // No word count, no narration: fall back to English prose.
        #expect(
            ArticleSpeechCostEstimate.charactersPerWord(narrationCharacters: 24_000, wordCount: nil)
                == ArticleSpeechCostEstimate.fallbackCharactersPerWord
        )
        #expect(
            ArticleSpeechCostEstimate.charactersPerWord(narrationCharacters: 0, wordCount: 4_000)
                == ArticleSpeechCostEstimate.fallbackCharactersPerWord
        )
        // A stale word count is clamped rather than quoting a wild price.
        #expect(
            ArticleSpeechCostEstimate.charactersPerWord(narrationCharacters: 24_000, wordCount: 100) == 20
        )
        #expect(
            ArticleSpeechCostEstimate.charactersPerWord(narrationCharacters: 24_000, wordCount: 100_000) == 3
        )
    }

    /// An unpriced model must not turn into a priced one by being added to a
    /// priced estimate — the whole-book total is unknown as soon as any part is.
    @Test("an unpriced part leaves the combined estimate unpriced")
    func unpricedPartLeavesCombinedEstimateUnpriced() {
        let priced = ArticleSpeechCostEstimate(characters: 1_000, usd: 0.5)
        let unpriced = ArticleSpeechCostEstimate(characters: 1_000, usd: nil)

        #expect(priced.adding(unpriced).usd == nil)
        #expect(unpriced.adding(priced).usd == nil)
        #expect(priced.adding(unpriced).characters == 2_000)
    }

    /// An outage stops text-to-speech generation as firmly as an exhausted balance
    /// does, but "Switch Voice Provider" is the wrong offer: no provider is
    /// reachable without a network, and the listener would be changing a
    /// setting that was never the problem.
    @Test("an offline Mac failure stops generation without blaming the provider")
    func macNetworkFailureDoesNotSuggestAnotherProvider() {
        let offline = MacArticleTTSError.networkUnavailable
        #expect(offline.abortsGeneration)
        #expect(!offline.suggestsProviderSwitch)
        // Both text-to-speech paths say the same thing about the same condition.
        #expect(
            offline.errorDescription
                == CloudArticleTTS.GenerationError.networkUnavailable.errorDescription
        )

        let rejected = MacArticleTTSError.providerRejected(
            provider: "Gemini",
            statusCode: 402,
            reason: "Insufficient credit."
        )
        #expect(rejected.abortsGeneration)
        #expect(rejected.suggestsProviderSwitch)

        let malformed = MacArticleTTSError.badResponse("The returned audio could not be decoded.")
        #expect(!malformed.abortsGeneration)
        #expect(!malformed.suggestsProviderSwitch)
    }

    /// A refusal of the model, its voice or its format holds for every chunk
    /// of the generation, so it stops it and offers another model, naming
    /// the one refused. Audio that would not play stays a per-chunk failure.
    @Test("a refused model stops generation, names the model and offers another")
    func macModelRefusalStopsGeneration() {
        for status in [400, 404, 410, 422] {
            #expect(MacArticleTTSClient.isModelRefusal(statusCode: status))
        }
        for status in [401, 402, 403, 408, 429, 500, 503] {
            #expect(!MacArticleTTSClient.isModelRefusal(statusCode: status), "status \(status)")
        }
        let refused = MacArticleTTSError.modelRefused(
            model: "fish-audio/s2.1-pro",
            statusCode: 400,
            reason: "Invalid reference_id."
        )
        #expect(refused.abortsGeneration)
        #expect(refused.suggestsProviderSwitch)
        #expect(refused.errorDescription == "OpenRouter refused Fish Audio S2.1 Pro (HTTP 400): Invalid reference_id.")

        let unplayable = MacArticleTTSError.unplayableAudio(model: "x/y", message: "The returned audio could not be decoded.")
        #expect(!unplayable.abortsGeneration)
        #expect(!unplayable.suggestsProviderSwitch)

        // An OpenAI voice is OpenAI's refusal, not OpenRouter's.
        let openAI = MacArticleTTSError.modelRefused(
            model: ArticleSpeechCatalog.openAIRealtimeModelID,
            statusCode: 400,
            reason: "No."
        )
        #expect(openAI.errorDescription?.hasPrefix("OpenAI refused ") == true)
    }

    /// One section OpenAI would not read word for word stopped a 246-section
    /// book (2026-11-26): that refusal is told apart from a model refusal.
    @Test("a section read off the text is told apart from a refused model")
    func notVerbatimRefusalIsRecognised() {
        let body = Data(#"{"error":{"code":"narration_not_verbatim","message":"x"}}"#.utf8)
        #expect(OpenAIRealtimeNarration.isNotVerbatimRefusal(body))
        let other = Data(#"{"error":{"code":"bad_request","message":"x"}}"#.utf8)
        #expect(!OpenAIRealtimeNarration.isNotVerbatimRefusal(other))
        #expect(!OpenAIRealtimeNarration.isNotVerbatimRefusal(Data("not json".utf8)))
    }

    /// With every interface down, loopback still answers while the path
    /// monitor reports `.unsatisfied` — so gating on the network would break
    /// the one voice provider that never needed it.
    @Test("a local voice server is not gated on an internet path")
    func localVoiceServerIsNotGatedOnTheNetwork() {
        for local in [
            "http://localhost:8080/v1/audio/speech",
            "http://127.0.0.1:8080/v1/audio/speech",
            "http://studio.local:1234/v1/audio/speech",
        ] {
            #expect(!MacArticleTTSClient.needsNetworkPath(URL(string: local)!))
        }

        #expect(
            MacArticleTTSClient.needsNetworkPath(
                URL(string: "https://openrouter.ai/api/v1/audio/speech")!
            )
        )
    }

}

private actor SpeechSchedulerRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
