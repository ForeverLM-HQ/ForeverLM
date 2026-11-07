import Foundation
import Testing
@testable import ForeverLM

/// OpenRouter's speech and transcription prices as the unit tests pin them
/// (`OpenRouterAudioPrices.$pinnedTable`). The app ships no prices — every one
/// is read from OpenRouter's catalog (product owner, 2026-09-26: "It never have
/// hard-coded prices") — and unit tests never read OpenRouter, so a test that
/// needs a price pins this table. The rows have the catalog's own shape
/// (`/api/frontend/v1/catalog/models`, `endpoint.pricing.display_pricing`),
/// with the figures and units it showed on 2026-09-27, so the unit parser runs
/// on every test that uses them.
enum AudioPriceFixture {
    static func unitRow(
        _ slug: String,
        _ kind: String,
        price: String,
        multiplier: Double,
        label: String,
        variant: String? = nil,
        discount: Double? = nil
    ) -> [String: Any] {
        var pricing: [String: Any] = [
            "display_pricing": [
                ["kind": "unit", "sku_label": "Units", "price": price,
                 "displayMultiplier": multiplier, "unitLabel": label],
            ],
        ]
        if let discount { pricing["discount"] = discount }
        return [
            "slug": slug,
            "output_modalities": [kind],
            "endpoint": [
                "model_variant_slug": variant ?? slug,
                "pricing": pricing,
            ] as [String: Any],
        ]
    }

    static func tokenRow(
        _ slug: String,
        _ kind: String,
        input: String,
        output: String,
        variant: String? = nil
    ) -> [String: Any] {
        [
            "slug": slug,
            "output_modalities": [kind],
            "endpoint": [
                "model_variant_slug": variant ?? slug,
                "pricing": [
                    "display_pricing": [
                        ["kind": "token", "sku_label": "Input Price", "price": input,
                         "displayMultiplier": 1_000_000, "unitLabel": "/M tokens"],
                        ["kind": "token", "sku_label": "Output Price", "price": output,
                         "displayMultiplier": 1_000_000, "unitLabel": "/M tokens"],
                    ],
                ],
            ] as [String: Any],
        ]
    }

    static var rows: [[String: Any]] { [
        // Speech.
        tokenRow("fish-audio/s2.1-pro-free", "speech", input: "0", output: "0", variant: "fish-audio/s2.1-pro-free:free"),
        tokenRow("deepgram/flux-tts", "speech", input: "0", output: "0", variant: "deepgram/flux-tts:free"),
        // The routed host's price (DeepInfra), not the $4 the public directory quotes.
        unitRow("hexgrad/kokoro-82m", "speech", price: "0.00000062", multiplier: 1_000_000, label: "/M characters"),
        unitRow("sesame/csm-1b", "speech", price: "0.000007", multiplier: 1_000_000, label: "/M characters"),
        unitRow("fish-audio/s2.1-pro", "speech", price: "0.000015", multiplier: 1_000_000, label: "/M UTF-8 bytes"),
        unitRow("x-ai/grok-voice-tts-1.0", "speech", price: "0.000015", multiplier: 1_000_000, label: "/M characters"),
        unitRow("microsoft/mai-voice-2-flash", "speech", price: "0.000015", multiplier: 1_000_000, label: "/M characters"),
        unitRow("qwen/qwen-audio-3.0-tts-flash", "speech", price: "0.000015", multiplier: 1_000_000, label: "/M characters"),
        unitRow("deepgram/aura-2", "speech", price: "0.00003", multiplier: 1_000_000, label: "/M characters"),
        tokenRow("google/gemini-3.1-flash-tts-preview", "speech", input: "0.000001", output: "0.00002"),
        unitRow("bytedance-seed/seed-audio-1-0", "speech", price: "0.0025", multiplier: 60, label: "/minute"),
        // Transcription.
        unitRow("nvidia/parakeet-tdt-0.6b-v3", "transcription", price: "0.000025", multiplier: 1, label: "/second"),
        unitRow("openai/whisper-large-v3", "transcription", price: "0.0000075", multiplier: 1, label: "/second"),
        unitRow("openai/whisper-large-v3-turbo", "transcription", price: "0.00000333", multiplier: 1, label: "/second"),
        unitRow("qwen/qwen3-asr-flash-2026-02-10", "transcription", price: "0.000035", multiplier: 1, label: "/second"),
        unitRow("mistralai/voxtral-mini-transcribe", "transcription", price: "0.00005", multiplier: 1, label: "/second"),
        unitRow("deepgram/nova-3", "transcription", price: "0.0000716666666667", multiplier: 1, label: "/second"),
        unitRow("openai/whisper-1", "transcription", price: "0.0001", multiplier: 1, label: "/second"),
        unitRow("google/chirp-3", "transcription", price: "0.000266666666667", multiplier: 1, label: "/second"),
        // Priced by the hour: read as seconds it would be $1,296 an hour.
        unitRow("microsoft/mai-transcribe-1.5", "transcription", price: "0.36", multiplier: 1, label: "/hour"),
        tokenRow("openai/gpt-4o-mini-transcribe", "transcription", input: "0.00000125", output: "0.000005"),
        tokenRow("openai/gpt-4o-transcribe", "transcription", input: "0.0000025", output: "0.00001"),
    ] }

    static let table: OpenRouterAudioPrices.Table = OpenRouterAudioPrices.parseCatalog(rows: rows)
}

/// The Settings price label and the request's actual rail must agree.
///
/// These read as trivia until you know what they caught: the label used to ask
/// the rate table for whichever provider slot the picker was sitting in, while
/// the route sent router-only models to OpenRouter regardless of the slot, and
/// `openai/whisper-large-v3` advertised Groq's rate for a request OpenRouter
/// would bill. Since 2026-09-27 every model routes to OpenRouter, and every
/// price is OpenRouter's, in the unit it bills the model by.
@Suite("Speech-to-Text Pricing")
struct SpeechToTextPricingTests {
    @Test("Every model offered before the directory is read carries OpenRouter's price in its unit")
    func everyOfferedModelHasARate() throws {
        // A card with no price reads as "free" rather than "unknown", which
        // is the one way this label can actively mislead.
        OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            for model in TranscriptionModelCatalog.models {
                #expect(model.priceLabel != OpenRouterAudioPrices.unknownPriceLabel, "\(model.id) has no price")
                if let rate = model.ratePerHour {
                    #expect(rate > 0, "\(model.id) priced at zero")
                    #expect(model.priceLabel.hasSuffix("/ hour of audio"), "\(model.id): \(model.priceLabel)")
                } else {
                    // Billed by tokens: its label says so, with no made-up hourly figure.
                    #expect(model.priceLabel.hasSuffix("per 1M tokens"), "\(model.id): \(model.priceLabel)")
                }
            }
        }
    }

    @Test("Every transcription model goes to OpenRouter under its slug")
    func everyModelRoutesToOpenRouter() throws {
        // The balance's routes; a key in the developer's Keychain would move them.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        for model in ManagedTranscriptionClient.catalog + ["gpt-4o-mini-transcribe"] {
            let route = ManagedTranscriptionClient.route(for: model)
            #expect(route.providerName == "OpenRouter", "\(model)")
            #expect(route.endpoint.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
        }
        // The default until 2026-09-27 named OpenAI's own route under its bare
        // id. It now names the same model's OpenRouter slug.
        #expect(ManagedTranscriptionClient.route(for: "gpt-4o-mini-transcribe").model == "openai/gpt-4o-mini-transcribe")
        #expect(AIModelDefaults.batchTranscription == "openai/gpt-4o-mini-transcribe")
    }

    @Test("Hourly prices come in OpenRouter's own unit, per hour for MAI-Transcribe")
    func pricingFollowsOpenRouterUnits() throws {
        try OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let parakeet = try #require(AIProviderPricing.sttDisplayRatePerHour(model: "nvidia/parakeet-tdt-0.6b-v3"))
            #expect(abs(parakeet - 0.09) < 0.0001)
            // Groq's direct whisper-large-v3 rate was $0.111/hr, and a table
            // typed in July said $0.09; OpenRouter's is $0.027.
            let whisper = try #require(AIProviderPricing.sttDisplayRatePerHour(model: "openai/whisper-large-v3"))
            #expect(abs(whisper - 0.027) < 0.0001)
            // The turbo variant is a genuinely different price and must not be
            // swallowed by the plain whisper-large-v3 prefix.
            let turbo = try #require(AIProviderPricing.sttDisplayRatePerHour(model: "openai/whisper-large-v3-turbo"))
            #expect(abs(turbo - 0.012) < 0.0001)
            // The directory prints MAI-Transcribe's price bare; OpenRouter
            // bills it per hour, and read as seconds it would be $1,296.
            let mai = try #require(AIProviderPricing.sttDisplayRatePerHour(model: "microsoft/mai-transcribe-1.5"))
            #expect(abs(mai - 0.36) < 0.0001)
            #expect(OpenRouterAudioPrices.label(slug: "microsoft/mai-transcribe-1.5", kind: .transcription)
                    == "$0.36 / hour of audio")
            // Token-billed: no hourly rate, and the label quotes the tokens.
            #expect(AIProviderPricing.sttDisplayRatePerHour(model: "gpt-4o-mini-transcribe") == nil)
            #expect(OpenRouterAudioPrices.label(slug: "openai/gpt-4o-mini-transcribe", kind: .transcription)
                    == "$1.25 / $5 per 1M tokens")
            // The ledger estimate reads the same table: ten minutes of Parakeet.
            let cost = try #require(AIProviderPricing.estimatedCostUSD(
                provider: "OpenRouter",
                model: "nvidia/parakeet-tdt-0.6b-v3",
                report: AIUsageReport(durationSeconds: 600)
            ))
            #expect(abs(cost - 0.015) < 0.000_001)
        }
    }

    @Test("A token-billed audio call is priced at the catalog's token rates, never left unpriced")
    func tokenBilledAudioIsPriced() throws {
        try OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            // A meeting chunk as the ledger recorded it on 2026-11-07:
            // OpenRouter's transcription answer said `cost: 0`, ten minutes of
            // audio, 6,000 tokens in and 832 out.
            let transcription = try #require(AIProviderPricing.estimatedCostUSD(
                provider: "OpenRouter",
                model: "openai/gpt-4o-mini-transcribe",
                report: AIUsageReport(
                    inputTokens: 6_000,
                    outputTokens: 832,
                    totalTokens: 6_832,
                    durationSeconds: 600,
                    rawUsageJSON: #"{"cost":0,"input_tokens":6000,"output_tokens":832,"total_tokens":6832}"#
                )
            ))
            #expect(abs(transcription - (6_000 * 0.00000125 + 832 * 0.000005)) < 0.000_000_1)

            // A speech model billed by tokens: text in, audio tokens out.
            let speech = try #require(AIProviderPricing.estimatedCostUSD(
                provider: "OpenRouter",
                model: "google/gemini-3.1-flash-tts-preview",
                report: AIUsageReport(inputTokens: 1_000, audioOutputTokens: 20_000)
            ))
            #expect(abs(speech - (1_000 * 0.000001 + 20_000 * 0.00002)) < 0.000_000_1)
        }
    }

    @Test("A pick left by an older picker routes under the id its rail knows")
    func retiredModelIDsAreRepaired() throws {
        // Settings once offered these bare — `whisper-1` and
        // `gpt-4o-transcribe` in the OpenAI slot, `whisper-large-v3` in the
        // Groq one — and such a pick is still in `stt_model_openai` on installs
        // from that era. Sent verbatim, OpenRouter's directory has no such
        // model, the proxy cannot price it, and every dictation attempt comes
        // back 403 model_not_managed.
        #expect(ManagedTranscriptionClient.route(for: "whisper-1").model == "openai/whisper-1")
        #expect(ManagedTranscriptionClient.route(for: "gpt-4o-transcribe").model
                == "openai/gpt-4o-transcribe")
        #expect(ManagedTranscriptionClient.route(for: "whisper-large-v3").model
                == "openai/whisper-large-v3")
        #expect(ManagedTranscriptionClient.route(for: " Whisper-1 ").model == "openai/whisper-1")
        #expect(ManagedTranscriptionClient.canonicalModel("gpt-4o-mini-transcribe")
                == "openai/gpt-4o-mini-transcribe")

        // Everything the picker offers is already the id it routes under, so
        // nothing currently selectable is being rewritten.
        for model in ManagedTranscriptionClient.catalog {
            #expect(
                ManagedTranscriptionClient.canonicalModel(model) == model,
                "\(model) is not the id its route uses"
            )
        }

        // A repaired id is priced on the rail it takes.
        try OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let repaired = try #require(AIProviderPricing.sttDisplayRatePerHour(model: "whisper-large-v3"))
            #expect(abs(repaired - 0.027) < 0.0001)
            let whisper1 = try #require(AIProviderPricing.sttDisplayRatePerHour(model: "whisper-1"))
            #expect(abs(whisper1 - 0.36) < 0.0001)
        }
    }

    @Test("The transcription list is OpenRouter's directory, cheapest first, unpriced last")
    func transcriptionDirectoryParsesAndOrders() throws {
        let json = #"""
        {"data":[
          {"id":"openai/whisper-1","name":"OpenAI: Whisper 1","created":1777332905,"architecture":{"output_modalities":["transcription"]}},
          {"id":"nvidia/parakeet-tdt-0.6b-v3","name":"NVIDIA: Parakeet TDT 0.6B v3","architecture":{"output_modalities":["transcription"]}},
          {"id":"acme/new-ears","name":"Acme: New Ears","architecture":{"output_modalities":["transcription"]}},
          {"id":"openai/gpt-4o-mini-transcribe","name":"OpenAI: GPT-4o Mini Transcribe"},
          {"id":"openai/whisper-1","name":"OpenAI: Whisper 1 (again)"},
          {"id":"~openai/whisper-latest","name":"OpenAI: Whisper (alias)"},
          {"id":"acme/voice","name":"Acme: Voice","architecture":{"output_modalities":["speech"]}}
        ]}
        """#
        let rows = try OpenRouterAudioDirectory.rows(fromDirectory: Data(json.utf8), kind: .transcription)
        // The duplicate, the rolling alias and the speech row are left out.
        #expect(rows.map(\.id) == [
            "openai/whisper-1", "nvidia/parakeet-tdt-0.6b-v3", "acme/new-ears", "openai/gpt-4o-mini-transcribe",
        ])
        #expect(rows.first?.maker == "OpenAI")
        #expect(rows.first?.name == "Whisper 1")
        #expect(rows.first?.created == Date(timeIntervalSince1970: 1777332905))

        OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let options = TranscriptionModelCatalog.options(fromDirectory: rows)
            // A model OpenRouter added is offered with no guessed price; one
            // billed by tokens sorts with the unpriced, after every hourly
            // one, by name.
            #expect(options.map(\.id) == [
                "nvidia/parakeet-tdt-0.6b-v3", "openai/whisper-1", "openai/gpt-4o-mini-transcribe", "acme/new-ears",
            ])
            #expect(options.first { $0.id == "acme/new-ears" }?.priceLabel == "Price unknown")
            #expect(options.first { $0.id == "acme/new-ears" }?.maker == "Acme")
        }
    }

    @Test("Catalog prices are read in the unit OpenRouter states, and nothing else is")
    func catalogUnitsAreParsed() throws {
        let table = AudioPriceFixture.table
        // Per character, per UTF-8 byte, per minute of output, and tokens.
        #expect(OpenRouterAudioPrices.speechUSDPerMillionCharacters(slug: "hexgrad/kokoro-82m", in: table) == 0.62)
        #expect(OpenRouterAudioPrices.label(slug: "fish-audio/s2.1-pro", kind: .speech, in: table)
                == "$15 / 1M UTF-8 bytes")
        #expect(OpenRouterAudioPrices.label(slug: "bytedance-seed/seed-audio-1-0", kind: .speech, in: table)
                == "$0.15 / minute of audio")
        #expect(OpenRouterAudioPrices.speechUSDPerMillionCharacters(slug: "bytedance-seed/seed-audio-1-0", in: table) == nil)
        #expect(OpenRouterAudioPrices.label(slug: "google/gemini-3.1-flash-tts-preview", kind: .speech, in: table)
                == "$1 / $20 per 1M tokens")
        #expect(OpenRouterAudioPrices.speechUSDPerMillionCharacters(slug: "google/gemini-3.1-flash-tts-preview", in: table) == nil)
        // A `:free` variant is keyed under its own id, and is free.
        #expect(OpenRouterAudioPrices.label(slug: "deepgram/flux-tts:free", kind: .speech, in: table) == "Free")
        // A price of one kind does not answer for the other.
        #expect(OpenRouterAudioPrices.transcriptionUSDPerHour(slug: "hexgrad/kokoro-82m", in: table) == nil)

        // A unit the parser does not know, or a price it cannot read, prices
        // nothing — never zero.
        let odd = OpenRouterAudioPrices.parseCatalog(rows: [
            AudioPriceFixture.unitRow("acme/odd", "speech", price: "0.01", multiplier: 1, label: "/song"),
            AudioPriceFixture.unitRow("acme/broken", "transcription", price: "n/a", multiplier: 1, label: "/second"),
            AudioPriceFixture.unitRow("acme/negative", "transcription", price: "-1", multiplier: 1, label: "/second"),
            AudioPriceFixture.unitRow("acme/image", "image", price: "0.04", multiplier: 1, label: "/image"),
        ])
        #expect(odd.isEmpty)

        // Before any read (and in every unit test that pins nothing) only a
        // `:free` id is priced, by OpenRouter's definition of the variant.
        #expect(OpenRouterAudioPrices.label(slug: "fish-audio/s2.1-pro-free:free", kind: .speech, in: [:]) == "Free")
        #expect(OpenRouterAudioPrices.label(slug: "deepgram/aura-2", kind: .speech, in: [:]) == nil)
        #expect(OpenRouterAudioPrices.current.isEmpty)
    }

    @Test("A catalog row's discount travels with its price, which already includes it")
    func catalogDiscountIsKept() throws {
        // AssemblyAI's Universal 3.5 Pro on 2026-09-29: $0.225 an hour, 50% off.
        let table = OpenRouterAudioPrices.parseCatalog(rows: [
            AudioPriceFixture.unitRow("assemblyai/universal-3-5-pro", "transcription",
                                      price: "0.0000625", multiplier: 1, label: "/second", discount: 0.5),
            AudioPriceFixture.unitRow("openai/whisper-1", "transcription",
                                      price: "0.0001", multiplier: 1, label: "/second", discount: 0),
        ])
        let promoted = try #require(OpenRouterAudioPrices.price(for: "assemblyai/universal-3-5-pro", kind: .transcription, in: table))
        #expect(promoted.discountBasisPoints == 5_000)
        #expect(OpenRouterAudioPrices.label(slug: "assemblyai/universal-3-5-pro", kind: .transcription, in: table)
                == "$0.225 / hour of audio")
        // The list figure Settings strikes through, in the label's own unit.
        #expect(OpenRouterAudioPrices.amount(of: promoted, kind: .transcription, scale: 2) == "$0.45")
        #expect(OpenRouterAudioPrices.price(for: "openai/whisper-1", kind: .transcription, in: table)?.discountBasisPoints == nil)

        // A table kept before prices carried a discount still reads.
        let kept = #"{"acme/voice":{"kind":"speech","unit":"character","rate":0.000015}}"#
        let decoded = try JSONDecoder().decode(OpenRouterAudioPrices.Table.self, from: Data(kept.utf8))
        #expect(decoded["acme/voice"]?.rate == 0.000015)
        #expect(decoded["acme/voice"]?.discountBasisPoints == nil)
    }

    @Test("Dictation and batch media resolve independent stored models")
    func purposesReadSeparateSettings() {
        let dictation = ManagedTranscriptionClient.Purpose.dictation.storedModel
        let media = ManagedTranscriptionClient.Purpose.media.storedModel
        // Both are non-empty out of the box: an unset media model falls back to
        // the same default dictation uses, so an existing install keeps working
        // exactly as before until the learner chooses something else.
        #expect(!dictation.isEmpty)
        #expect(!media.isEmpty)

        let previous = KeychainService.mediaTranscriptionModel
        defer { KeychainService.mediaTranscriptionModel = previous }

        KeychainService.mediaTranscriptionModel = "deepgram/nova-3"
        #expect(ManagedTranscriptionClient.Purpose.media.storedModel == "deepgram/nova-3")
        // Changing the recordings model must not disturb dictation.
        #expect(ManagedTranscriptionClient.Purpose.dictation.storedModel == dictation)
    }
}
