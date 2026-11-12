// Own OpenRouter key media route and speech directory tests.

import AVFoundation
import Foundation
import Testing
@testable import ForeverLM

/// Routes an own OpenRouter key changes. Each test pins
/// `ManagedAI.ownKeyOverrideForTesting`, a process-wide value, so the suite is
/// serialized the way the other key-pinning suites are.
@Suite("Own OpenRouter key media routes", .serialized)
struct OwnOpenRouterKeyMediaRouteTests {
    @Test("own-key speech is charged what OpenRouter's generation record says")
    func ownKeySpeechCostComesFromTheGenerationRecord() {
        // Ordinary credit: OpenRouter's charge is the whole cost.
        #expect(CloudArticleTTS.generationCostUSD(["total_cost": 0.0012, "is_byok": false]) == 0.0012)
        // BYOK: OpenRouter's fee plus the provider's own invoice, as the proxy counts it.
        let byok = CloudArticleTTS.generationCostUSD([
            "total_cost": 0.0001, "is_byok": true, "upstream_inference_cost": 0.002,
        ])
        #expect(abs((byok ?? 0) - 0.0021) < 1e-12)
        // An incomplete record is no cost at all, never a guess.
        #expect(CloudArticleTTS.generationCostUSD(["is_byok": false]) == nil)
        #expect(CloudArticleTTS.generationCostUSD(["total_cost": 0.001, "is_byok": true]) == nil)
        #expect(CloudArticleTTS.generationCostUSD(["total_cost": -1, "is_byok": false]) == nil)
    }

    @Test("an own OpenRouter key takes Gemini and Grok narration straight to OpenRouter")
    func ownKeyNarrationLeavesFirstPartyRoutes() throws {
        // The product owner (2026-09-22): an own key pays for everything OpenRouter
        // serves. Every voice is on OpenRouter's speech endpoint, so on the
        // key the request goes there directly, not through the proxy.
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        for (model, voice) in [
            (ArticleSpeechCatalog.defaultModelID, "Kore"),
            (ArticleSpeechCatalog.grokModelID, "eve"),
        ] {
            let request = try AIUsageAttribution.$task.withValue("read_aloud") {
                try CloudArticleTTS.speechRequest(
                    text: "A short narration probe.",
                    selection: CloudArticleTTS.Selection(model: model, voice: voice)
                )
            }
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/speech", "\(model)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test-key")
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["model"] as? String == model)
            #expect(payload["voice"] as? String == voice)
            #expect(payload["input"] as? String == "A short narration probe.")
        }
    }

    /// Listen on OpenAI (product owner, 2026-11-11): OpenRouter lists no OpenAI
    /// voice, so the proxy speaks gpt-realtime-2.1-mini itself.
    @Test("an OpenAI voice is read through the proxy's own route")
    func openAIVoiceGoesThroughTheProxy() throws {
        let openAI = try #require(ArticleSpeechCatalog.model(id: ArticleSpeechCatalog.openAIRealtimeModelID))
        #expect(openAI.speaksThroughOpenAI)
        #expect(openAI.wireModelID == "gpt-realtime-2.1-mini")
        #expect(openAI.defaultVoiceID == "marin")
        #expect(openAI.responseFormat == .pcm(sampleRate: 24_000))
        // The price is still said, OpenAI's own, with whose key pays.
        #expect(openAI.priceLabel == "$0.6 / $20 per 1M tokens · BYOK")
        // The settings tool words the price from the slug alone, and must say
        // the same thing as the card: not "Price unknown" for a voice
        // OpenRouter does not list.
        #expect(ArticleSpeechCatalog.priceLabel(forModel: ArticleSpeechCatalog.openAIRealtimeModelID) == openAI.priceLabel)
        #expect(openAI.ratePerMillionCharacters == 0)

        // Even on the learner's own OpenRouter key, the request stays on the
        // proxy: OpenRouter cannot serve it.
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let request = try CloudArticleTTS.speechRequest(
            text: "Two sentences. One voice.",
            selection: CloudArticleTTS.Selection(model: openAI.id, voice: "cedar")
        )
        #expect(request.url?.absoluteString == "https://ai.foreverlm.com/v1/openai/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") != "Bearer sk-or-test-key")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "gpt-realtime-2.1-mini")
        #expect(payload["voice"] as? String == "cedar")
        #expect(payload["response_format"] as? String == "pcm")

        // OpenRouter models keep their own endpoint and slug.
        let gemini = try CloudArticleTTS.speechRequest(
            text: "Two sentences. One voice.",
            selection: CloudArticleTTS.Selection(model: ArticleSpeechCatalog.defaultModelID, voice: "Kore")
        )
        #expect(gemini.url?.absoluteString == "https://openrouter.ai/api/v1/audio/speech")
    }

    @Test("an own OpenRouter key takes GPT-4o mini transcription to OpenRouter")
    func ownKeyTranscriptionLeavesOpenAIRoute() {
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        let route = ManagedTranscriptionClient.route(for: "gpt-4o-mini-transcribe")
        #expect(route.providerName == "OpenRouter")
        #expect(route.model == "openai/gpt-4o-mini-transcribe")
        #expect(route.endpoint.host == "openrouter.ai")

        // Without the key it is the same OpenRouter request, which
        // `ManagedAI.rewrite` sends through the proxy on the balance.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        let balance = ManagedTranscriptionClient.route(for: "gpt-4o-mini-transcribe")
        #expect(balance.providerName == "OpenRouter")
        #expect(balance.model == "openai/gpt-4o-mini-transcribe")
    }
}

/// The text-to-speech catalog follows OpenRouter's speech directory (product owner,
/// 2026-09-27: "show all models at
/// https://openrouter.ai/models?output_modalities=speech"). Unit tests never
/// read it — `OpenRouterAudioDirectory` answers nil under XCTest, so the
/// catalog is `curatedModels` — and the merge is pure, so it is pinned here
/// on a directory response of the real shape.
@Suite("Speech Directory")
struct SpeechDirectoryTests {
    static let directory = #"""
    {"data":[
      {"id":"deepgram/aura-2","name":"Deepgram: Aura-2","created":1784237167,
       "architecture":{"output_modalities":["speech"]},
       "supported_voices":["aura-2-thalia-en","aura-2-agathe-fr","aura-2-zeus-en","aura-2-thalia-en"]},
      {"id":"fish-audio/s2.1-pro","name":"Fish Audio: S2.1 Pro","supported_voices":null},
      {"id":"bytedance-seed/seed-audio-1-0","name":"ByteDance Seed: Seed Audio 1.0","supported_voices":null},
      {"id":"canopylabs/orpheus-3b-0.1-ft","name":"Canopy Labs: Orpheus 3B","supported_voices":["tara"]},
      {"id":"google/gemini-3.1-flash-tts-preview","name":"Google: Gemini 3.1 Flash TTS Preview",
       "supported_voices":["Zephyr","Kore"]},
      {"id":"heygen/heygen-voice-1-turbo:free","name":"HeyGen: HeyGen Voice Turbo (free)",
       "supported_voices":["nadine","tabitha"]},
      {"id":"acme/new-voice","name":"Acme: New Voice","supported_voices":["a_b","c"]},
      {"id":"~google/gemini-latest","name":"Google: Gemini (alias)"},
      {"id":"acme/transcriber","name":"Acme: Ears","architecture":{"output_modalities":["transcription"]}}
    ]}
    """#

    static func options() throws -> [ArticleSpeechModelOption] {
        let rows = try OpenRouterAudioDirectory.rows(fromDirectory: Data(directory.utf8), kind: .speech)
        return ArticleSpeechCatalog.options(fromDirectory: rows)
    }

    @Test("a directory response parses to speech rows, without aliases or other kinds")
    func directoryParses() throws {
        let rows = try OpenRouterAudioDirectory.rows(fromDirectory: Data(Self.directory.utf8), kind: .speech)
        #expect(rows.map(\.id) == [
            "deepgram/aura-2", "fish-audio/s2.1-pro", "bytedance-seed/seed-audio-1-0",
            "canopylabs/orpheus-3b-0.1-ft", "google/gemini-3.1-flash-tts-preview",
            "heygen/heygen-voice-1-turbo:free", "acme/new-voice",
        ])
        let aura = try #require(rows.first)
        #expect(aura.maker == "Deepgram")
        #expect(aura.name == "Aura-2")
        // A voice the directory repeats is listed once, in its order.
        #expect(aura.supportedVoices == ["aura-2-thalia-en", "aura-2-agathe-fr", "aura-2-zeus-en"])
        #expect(rows.first { $0.id == "fish-audio/s2.1-pro" }?.supportedVoices == [])
        #expect(throws: OpenRouterAudioDirectory.Failure.self) {
            try OpenRouterAudioDirectory.rows(fromDirectory: Data("not json".utf8), kind: .speech)
        }
    }

    @Test("the overlay names the voices it curates and lists the directory's others after them")
    func overlayMergesOverTheDirectory() throws {
        let options = try Self.options()
        // Orpheus 3B is retired for a recorded reason, directory or not.
        #expect(!options.contains { $0.id == "canopylabs/orpheus-3b-0.1-ft" })

        let aura = try #require(options.first { $0.id == "deepgram/aura-2" })
        #expect(aura.name == "Deepgram Aura 2")
        #expect(aura.voices.map(\.id) == ["aura-2-thalia-en", "aura-2-zeus-en", "aura-2-agathe-fr"])
        #expect(aura.curatedVoiceCount == 2)
        #expect(aura.voice(id: "aura-2-thalia-en")?.name == "Thalia")
        // The curated voices are English; a voice the directory adds beside
        // them is not assumed to share that — it is unstated.
        #expect(aura.languageSupport(voice: "aura-2-thalia-en") == .languages(["en"]))
        #expect(aura.languageSupport(voice: "aura-2-agathe-fr") == .unstated)

        // Gemini's languages are the model's, so every voice it lists has them.
        let gemini = try #require(options.first { $0.id == ArticleSpeechCatalog.defaultModelID })
        #expect(gemini.voices.map(\.id) == ["Zephyr", "Kore"])
        #expect(gemini.languageSupport(voice: "Kore") == ArticleSpeechCatalog.geminiLanguages)
        #expect(gemini.responseFormat == .pcm(sampleRate: 24_000))
        #expect(gemini.maker == "Google")

        // HeyGen's adapter is PCM-only. A directory-only model defaults to
        // MP3, so this overlay is the contract that keeps a live row usable.
        let heygen = try #require(options.first { $0.id == "heygen/heygen-voice-1-turbo:free" })
        // Its PCM is 44.1 kHz, not the 24 kHz Gemini and OpenAI send.
        #expect(heygen.responseFormat == .pcm(sampleRate: 44_100))
        #expect(heygen.responseFormat.wireValue == "pcm")
        #expect(heygen.voices.map(\.id) == ["nadine", "tabitha"])

        // OpenRouter lists no voices for Fish Audio; the voice its model page
        // plays is the one recorded, so the model still takes a voice.
        let fish = try #require(options.first { $0.id == "fish-audio/s2.1-pro" })
        #expect(fish.voices.map(\.id) == ArticleSpeechCatalog.fishS21Voices.map(\.id))

        // Seed Audio lists none and nothing names one, so it is not offered:
        // a request without a voice lets the provider pick the speaker, a
        // different one per request (product owner, 2026-11-11).
        #expect(!options.contains { $0.id == "bytedance-seed/seed-audio-1-0" })
        #expect(!options.contains { !$0.takesVoice })
    }

    @Test("a request that names no voice is refused before it is sent")
    func everyRequestNamesAVoice() {
        for voice in [nil, "", "  "] as [String?] {
            #expect(throws: CloudArticleTTS.GenerationError.self) {
                _ = try CloudArticleTTS.speechRequest(
                    text: "Two sentences. One voice.",
                    selection: CloudArticleTTS.Selection(model: ArticleSpeechCatalog.defaultModelID, voice: voice)
                )
            }
        }
    }

    /// A Fish request with no reference voice is spoken by a different random
    /// speaker each time: a paper narrated by Drama 3 changed voice every few
    /// sentences on the iPhone (2026-11-11).
    @Test("a Fish model the overlay does not know still takes the Fish reference voice")
    func uncuratedFishModelTakesTheReferenceVoice() throws {
        let rows = try OpenRouterAudioDirectory.rows(fromDirectory: Data(#"""
        {"data":[{"id":"fish-audio/drama-3","name":"Fish Audio: Drama 3","supported_voices":null}]}
        """#.utf8), kind: .speech)
        let drama = try #require(ArticleSpeechCatalog.options(fromDirectory: rows).first { $0.id == "fish-audio/drama-3" })
        #expect(drama.takesVoice)
        #expect(drama.defaultVoiceID == ArticleSpeechCatalog.fishS21Voices.first?.id)
    }

    @Test("a model the overlay does not know is offered with nothing about it guessed")
    func unknownModelIsOfferedHonestly() throws {
        let acme = try #require(try Self.options().first { $0.id == "acme/new-voice" })
        #expect(acme.maker == "Acme")
        #expect(acme.name == "New Voice")
        #expect(acme.voices.map(\.id) == ["a_b", "c"])
        #expect(acme.curatedVoiceCount == 0)
        // Not English by default: unstated, until something documents it.
        #expect(acme.languages == .unstated)
        #expect(acme.summary.contains("languages not published"))
        // OpenRouter's speech endpoint takes MP3 for every model; PCM only
        // where the sample format is known.
        #expect(acme.responseFormat == .mp3)
        #expect(acme.chunkLimit == ArticleSpeechCatalog.untunedChunkLimit)
        #expect(acme.leadChunkLimit == ArticleSpeechCatalog.untunedLeadChunkLimit)
        // Unpinned, the price is unknown rather than zero.
        #expect(acme.ratePerMillionCharacters == nil)
        #expect(acme.priceLabel == OpenRouterAudioPrices.unknownPriceLabel)
    }

    @Test("the list is cheapest first by OpenRouter's per-character price, the rest after by name")
    func optionsAreOrderedByPrice() throws {
        let ids = try OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            try Self.options().map(\.id)
        }
        #expect(ids == [
            ArticleSpeechCatalog.openAIRealtimeModelID, // BYOK: $0 to the learner
            "heygen/heygen-voice-1-turbo:free",     // Free
            "fish-audio/s2.1-pro",                  // $15 / 1M UTF-8 bytes
            "deepgram/aura-2",                      // $30 / 1M characters
            "google/gemini-3.1-flash-tts-preview",  // tokens: no per-character rate
            "acme/new-voice",                       // unpriced
        ])
    }

    @Test("only a documented language moves a source; an unstated one leaves the pick alone")
    func unstatedLanguagesNeitherConfirmNorReplace() throws {
        let options = try Self.options()
        func fit(_ code: String, _ model: String, _ voice: String) -> ArticleSpeechCatalog.LanguageFit {
            ArticleSpeechCatalog.languageFit(for: code, model: model, voice: voice, in: options)
        }
        #expect(fit("de", "acme/new-voice", "a_b") == .unverified)
        #expect(fit("de", "deepgram/aura-2", "aura-2-agathe-fr") == .unverified)
        // A documented English voice asked for German still moves, to the
        // default model's default voice, which Google documents for German.
        #expect(fit("de", "deepgram/aura-2", "aura-2-thalia-en")
                == .otherModel(model: ArticleSpeechCatalog.defaultModelID, voice: ArticleSpeechCatalog.defaultVoiceID))
        // Nothing unstated, and nothing without a voice, is ever the substitute.
        for code in ["cy", "zu", "xx"] {
            let replacement = fit(code, "deepgram/aura-2", "aura-2-thalia-en").replacement?.model
            #expect(replacement != "acme/new-voice", "\(code)")
            #expect(replacement != "bytedance-seed/seed-audio-1-0", "\(code)")
        }
        // And the listener is told nothing for an unverified source: the card
        // already says the model publishes no languages.
        let unverified = ArticleSpeechLanguageResolution(
            languageCode: "de",
            model: "acme/new-voice",
            voice: "a_b",
            outcome: .unverified
        )
        #expect(unverified.message == nil)
        #expect(!unverified.changesSelection)
    }

    @Test("unit tests see the catalog this build records, never this Mac's last read")
    func unitTestsNeverReadTheDirectory() {
        #expect(OpenRouterAudioDirectory.rows(.speech) == nil)
        #expect(OpenRouterAudioDirectory.rows(.transcription) == nil)
        #expect(!ArticleSpeechCatalog.isDirectoryBacked)
        #expect(ArticleSpeechCatalog.models.map(\.id) == ArticleSpeechCatalog.curatedModels.map(\.id))
        #expect(TranscriptionModelCatalog.models.map(\.id)
                == TranscriptionModelCatalog.offeredBeforeDirectory.map(\.id))
    }

    /// Audio already paid for plays whether or not OpenRouter still lists —
    /// or this device has yet read — the model that made it.
    @Test("a recording plays whatever model made it, unless that model was retired")
    func playbackDoesNotDependOnTheDirectory() {
        func manifest(model: String, voice: String = "Kore") -> SyncedArticleAudioManifest {
            SyncedArticleAudioManifest(
                schemaVersion: SyncedArticleAudioManifest.schemaVersion,
                sourceID: "article-1",
                title: "An article",
                subtitle: nil,
                sourceType: "article",
                sourceURL: "https://example.com/article",
                provider: ArticleSpeechCatalog.provider,
                model: model,
                voice: voice,
                voiceLabel: voice,
                contentSignature: "content-signature",
                totalCharacters: 120,
                createdAt: Date(),
                chunks: [
                    SyncedArticleAudioManifest.Chunk(index: 0, fileName: "chunk-0000.mp3", byteCount: 128, text: nil)
                ],
                sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
                generatedOnPlatform: "macos"
            )
        }
        #expect(manifest(model: "google/gemini-3.8-flash-tts").usesSupportedPlaybackFormat)
        #expect(!manifest(model: "canopylabs/orpheus-3b-0.1-ft").usesSupportedPlaybackFormat)
        // Audio made with no voice named changes speaker every request, so it
        // is made again; with one it plays.
        #expect(!manifest(model: "fish-audio/drama-3", voice: "").usesSupportedPlaybackFormat)
        #expect(manifest(model: "fish-audio/drama-3", voice: "b347db033a6549378b48d00acb0d06cd").usesSupportedPlaybackFormat)
        // Any audio made with no voice named is made again, whatever its model.
        #expect(!manifest(model: "bytedance-seed/seed-audio-1-0", voice: "").usesSupportedPlaybackFormat)
    }

    /// One second of a 440 Hz tone as the raw 16-bit mono PCM a speech model
    /// sends at `sampleRate`.
    private func tonePCM(sampleRate: Int) -> Data {
        var pcm = Data(capacity: sampleRate * 2)
        for index in 0..<sampleRate {
            let sample = Int16(12_000 * sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }

    /// HeyGen sends 44.1 kHz PCM. Wrapped at the 24 kHz Gemini sends, a second
    /// of it lasted 1.84 s: slow, and nearly an octave low (product owner,
    /// 2026-11-11: "crazy slowed down. And way too deep").
    @Test("PCM is wrapped at the rate its model sends, so a second of speech lasts a second")
    func pcmIsWrappedAtItsModelsSampleRate() throws {
        let heygen = "heygen/heygen-voice-1-turbo:free"
        #expect(ArticleSpeechCatalog.pcmSampleRate(forModel: heygen) == 44_100)
        #expect(ArticleSpeechCatalog.pcmSampleRate(forModel: "heygen/heygen-voice-1") == 44_100)
        #expect(ArticleSpeechCatalog.pcmSampleRate(forModel: ArticleSpeechCatalog.defaultModelID) == 24_000)
        #expect(ArticleSpeechCatalog.pcmSampleRate(forModel: ArticleSpeechCatalog.openAIRealtimeModelID) == 24_000)
        // MP3 describes itself, and nothing is assumed of an unknown model.
        #expect(ArticleSpeechCatalog.pcmSampleRate(forModel: ArticleSpeechCatalog.grokModelID) == nil)
        #expect(ArticleSpeechCatalog.pcmSampleRate(forModel: "acme/new-voice") == nil)

        let pcm = tonePCM(sampleRate: 44_100)
        let wrapped = try ArticleSpeechPCMTranscode.m4aData(fromPCM: pcm, sampleRate: 44_100)
        let player = try AVAudioPlayer(data: wrapped)
        #expect(player.format.sampleRate == 44_100)
        #expect(abs(player.duration - 1) < 0.1)
        #expect(ArticleSpeechAudioValidation.isWrappedAtModelSampleRate(wrapped, modelID: heygen))

        // What the earlier build stored: the same samples in a 24 kHz
        // container. A request cache or a voice sample holding it is not reused.
        let slow = try ArticleSpeechPCMTranscode.m4aData(fromPCM: pcm, sampleRate: 24_000)
        #expect(abs(try AVAudioPlayer(data: slow).duration - 1.8375) < 0.1)
        #expect(!ArticleSpeechAudioValidation.isWrappedAtModelSampleRate(slow, modelID: heygen))
        // The same container is right for a model that does send 24 kHz, and
        // an MP3 model's audio is never judged by a rate.
        #expect(ArticleSpeechAudioValidation.isWrappedAtModelSampleRate(
            slow, modelID: ArticleSpeechCatalog.defaultModelID
        ))
        #expect(ArticleSpeechAudioValidation.isWrappedAtModelSampleRate(
            slow, modelID: ArticleSpeechCatalog.grokModelID
        ))
    }

    @Test("a recording wrapped at another rate than its model sends is made again")
    func slowRecordingsAreMadeAgain() {
        func manifest(model: String, pcmSampleRate: Int?) -> SyncedArticleAudioManifest {
            SyncedArticleAudioManifest(
                schemaVersion: SyncedArticleAudioManifest.schemaVersion,
                sourceID: "article-1",
                title: "An article",
                subtitle: nil,
                sourceType: "article",
                sourceURL: "https://example.com/article",
                provider: ArticleSpeechCatalog.provider,
                model: model,
                voice: "nadine",
                voiceLabel: "Nadine",
                contentSignature: "content-signature",
                totalCharacters: 120,
                createdAt: Date(),
                chunks: [
                    SyncedArticleAudioManifest.Chunk(index: 0, fileName: "chunk-0000.m4a", byteCount: 128, text: nil)
                ],
                sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
                generatedOnPlatform: "ios",
                pcmSampleRate: pcmSampleRate
            )
        }
        // A manifest that records no rate was wrapped at 24 kHz: wrong for
        // HeyGen, right for Gemini, whose recordings keep playing.
        let heygen = "heygen/heygen-voice-1-turbo"
        #expect(!manifest(model: heygen, pcmSampleRate: nil).playsAtRecordedSpeed)
        #expect(!manifest(model: heygen, pcmSampleRate: nil).usesSupportedPlaybackFormat)
        #expect(manifest(model: heygen, pcmSampleRate: 44_100).usesSupportedPlaybackFormat)
        #expect(manifest(model: ArticleSpeechCatalog.defaultModelID, pcmSampleRate: nil).usesSupportedPlaybackFormat)
        #expect(manifest(model: ArticleSpeechCatalog.defaultModelID, pcmSampleRate: 24_000).usesSupportedPlaybackFormat)
        // MP3 models and models this build does not know have no rate to miss.
        #expect(manifest(model: ArticleSpeechCatalog.grokModelID, pcmSampleRate: nil).usesSupportedPlaybackFormat)
        #expect(manifest(model: "acme/new-voice", pcmSampleRate: nil).usesSupportedPlaybackFormat)

        // An interrupted generation is not resumed from a prefix that plays
        // slow: the journal an earlier build wrote records no rate either.
        let journal = ArticleSpeechGenerationProgress(
            sourceID: "article-1",
            contentSignature: "content-signature",
            model: heygen,
            voice: "nadine",
            plannedRequestCount: 4,
            completedRequestCount: 2,
            chunks: [],
            updatedAt: Date()
        )
        #expect(journal.pcmSampleRate == 44_100)
    }
}
