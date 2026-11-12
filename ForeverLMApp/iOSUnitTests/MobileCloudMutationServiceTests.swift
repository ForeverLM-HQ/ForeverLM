import CloudKit
import CryptoKit
import XCTest
@testable import ForeverLM

/// OpenRouter's catalog prices for the curated text-to-speech models, in their
/// units, as it showed them on 2026-09-27. The app ships no prices and unit
/// tests never read OpenRouter, so a test that needs one pins this table
/// (`OpenRouterAudioPrices.$pinnedTable`). `:free` ids need no row.
enum IOSAudioPriceFixture {
    static let table: OpenRouterAudioPrices.Table = [
        "hexgrad/kokoro-82m": .init(kind: .speech, unit: .character, rate: 0.00000062),
        "sesame/csm-1b": .init(kind: .speech, unit: .character, rate: 0.000007),
        "fish-audio/s2.1-pro": .init(kind: .speech, unit: .utf8Byte, rate: 0.000015),
        "x-ai/grok-voice-tts-1.0": .init(kind: .speech, unit: .character, rate: 0.000015),
        "microsoft/mai-voice-2-flash": .init(kind: .speech, unit: .character, rate: 0.000015),
        "qwen/qwen-audio-3.0-tts-flash": .init(kind: .speech, unit: .character, rate: 0.000015),
        "mistralai/voxtral-mini-tts-2603": .init(kind: .speech, unit: .character, rate: 0.000016),
        "microsoft/mai-voice-2": .init(kind: .speech, unit: .character, rate: 0.000022),
        "deepgram/aura-2": .init(kind: .speech, unit: .character, rate: 0.00003),
        "google/gemini-3.1-flash-tts-preview": .init(kind: .speech, unit: .token, rate: 0.000001, outputRate: 0.00002),
        "minimax/speech-2.8-turbo": .init(kind: .speech, unit: .character, rate: 0.00006),
        "minimax/speech-2.8-hd": .init(kind: .speech, unit: .character, rate: 0.0001),
    ]
}

final class CloudArticleTTSRoutingTests: XCTestCase {
    func testAudioCompletionAcceptsOnlyTheNaturalFinalClockTick() {
        XCTAssertFalse(MobileAudioPlaybackCompletion.reachedEnd(elapsed: .nan, duration: 60))
        XCTAssertFalse(MobileAudioPlaybackCompletion.reachedEnd(elapsed: 59.89, duration: 60))
        XCTAssertTrue(MobileAudioPlaybackCompletion.reachedEnd(elapsed: 59.9, duration: 60))
        XCTAssertTrue(MobileAudioPlaybackCompletion.reachedEnd(elapsed: 60, duration: 60))
        XCTAssertFalse(MobileAudioPlaybackCompletion.reachedEnd(elapsed: 0, duration: 0))
    }

    /// Grok went to xAI's own API until 2026-09-27; every voice is an
    /// OpenRouter model now (the product owner: "it can just be done via openrouter").
    func testGrokUsesOpenRouterSpeechRoute() throws {
        let request = try AIUsageAttribution.$task.withValue("read_aloud") {
            try CloudArticleTTS.speechRequest(
                text: "A short narration probe.",
                selection: CloudArticleTTS.Selection(
                    model: ArticleSpeechCatalog.grokModelID,
                    voice: "eve"
                )
            )
        }

        XCTAssertEqual(request.url?.host, "ai.foreverlm.com")
        XCTAssertEqual(request.url?.path, "/v1/proxy/openrouter/api/v1/audio/speech")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["input"] as? String, "A short narration probe.")
        XCTAssertEqual(payload["voice"] as? String, "eve")
        XCTAssertEqual(payload["model"] as? String, ArticleSpeechCatalog.grokModelID)
        XCTAssertEqual(payload["response_format"] as? String, "mp3")
        XCTAssertNil(payload["voice_id"])
    }

    func testRouterOnlyTTSUsesOpenRouterMediaRoute() throws {
        let request = try AIUsageAttribution.$task.withValue("read_aloud") {
            try CloudArticleTTS.speechRequest(
                text: "A short narration probe.",
                selection: CloudArticleTTS.Selection(
                    model: "sesame/csm-1b",
                    voice: "read_speech_a"
                )
            )
        }

        XCTAssertEqual(request.url?.host, "ai.foreverlm.com")
        XCTAssertEqual(request.url?.path, "/v1/proxy/openrouter/api/v1/audio/speech")
    }

    func testGrokNeverStartsASecondPaidProviderAfterFailure() {
        let grok = CloudArticleTTS.Selection(
            model: ArticleSpeechCatalog.grokModelID,
            voice: "eve"
        )

        XCTAssertEqual(CloudArticleTTS.candidateSelections(startingWith: grok), [grok])

        let gemini = CloudArticleTTS.Selection(
            model: ArticleSpeechCatalog.defaultModelID,
            voice: ArticleSpeechCatalog.defaultVoiceID
        )
        XCTAssertEqual(CloudArticleTTS.candidateSelections(startingWith: gemini), [gemini])
    }

    func testUnmeteredSpeechResponseDoesNotSplitIntoMorePaidRequests() {
        let failure = CloudArticleTTS.GenerationError.rejected(
            model: ArticleSpeechCatalog.grokModelID,
            statusCode: 502,
            reason: "ForeverLM AI could not price this speech request."
        )

        XCTAssertFalse(failure.isSplittableRejection)
    }

    func testGrokCostDisclosureUsesItsExactCharacterRate() throws {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        try OpenRouterAudioPrices.$pinnedTable.withValue(IOSAudioPriceFixture.table) {
            let confirmation = MobileTextToSpeechCostConfirmation(
                sourceID: "article-1",
                sourceTitle: "An article",
                characterCount: 10_000,
                modelID: ArticleSpeechCatalog.grokModelID
            )

            XCTAssertEqual(try XCTUnwrap(confirmation.estimatedUSD), 0.15, accuracy: 0.000_001)
            XCTAssertTrue(confirmation.title.contains("15¢"))
            XCTAssertFalse(confirmation.message.contains("fallback"))
        }
    }

    func testFreeOpenRouterSpeechIsDisclosedAsFree() throws {
        let confirmation = MobileTextToSpeechCostConfirmation(
            sourceID: "article-free",
            sourceTitle: "A free narration",
            characterCount: 10_000,
            modelID: "fish-audio/s2.1-pro-free:free"
        )

        XCTAssertEqual(try XCTUnwrap(confirmation.estimatedUSD), 0, accuracy: 0.000_001)
        XCTAssertEqual(confirmation.title, "Generate audio for free?")
        XCTAssertTrue(confirmation.message.contains("This model is free"))
    }

    /// Playback carries on into the next chapter and generates it in the
    /// background without a second prompt, so a chapter's confirmation is the
    /// only place the book's real cost can be stated. Quoting 36 cents for a
    /// twelve-dollar book is the failure this covers.
    func testBookChapterDisclosureQuotesTheWholeBook() throws {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        try OpenRouterAudioPrices.$pinnedTable.withValue(IOSAudioPriceFixture.table) {
            let confirmation = MobileTextToSpeechCostConfirmation(
                sourceID: "chapter-1",
                sourceTitle: "Chapter 1",
                characterCount: 24_000,
                modelID: "fish-audio/s2.1-pro",
                book: MobileTextToSpeechCostConfirmation.BookScope(
                    title: "Thinking, Fast and Slow",
                    remainingChapters: 37,
                    remainingCharacters: 776_000
                )
            )

            // 24,000 + 776,000 characters at $15 per million.
            XCTAssertEqual(try XCTUnwrap(confirmation.chapterEstimate.usd), 0.36, accuracy: 0.000_001)
            XCTAssertEqual(try XCTUnwrap(confirmation.estimatedUSD), 12, accuracy: 0.000_001)
            XCTAssertEqual(confirmation.totalEstimate.sourceCount, 38)
            XCTAssertTrue(confirmation.title.contains("whole book"), confirmation.title)
            XCTAssertTrue(confirmation.message.contains("Thinking, Fast and Slow"), confirmation.message)
            XCTAssertTrue(confirmation.message.contains("38 chapters"), confirmation.message)
            XCTAssertTrue(confirmation.message.contains("This chapter"), confirmation.message)
            // The listener is told why the book, not the chapter, is what is priced.
            XCTAssertTrue(
                confirmation.message.contains("without asking again"),
                confirmation.message
            )
        }
    }

    /// A standalone source keeps the single-source wording: there is no book
    /// behind it, so nothing extra is being agreed to.
    func testStandaloneSourceKeepsItsOwnPrice() throws {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        try OpenRouterAudioPrices.$pinnedTable.withValue(IOSAudioPriceFixture.table) {
            let confirmation = MobileTextToSpeechCostConfirmation(
                sourceID: "article-1",
                sourceTitle: "An article",
                characterCount: 24_000,
                modelID: "fish-audio/s2.1-pro"
            )

            XCTAssertEqual(try XCTUnwrap(confirmation.estimatedUSD), 0.36, accuracy: 0.000_001)
            XCTAssertFalse(confirmation.title.contains("whole book"), confirmation.title)
            XCTAssertFalse(confirmation.message.contains("chapters"), confirmation.message)
            XCTAssertTrue(confirmation.message.contains("about 32 min"), confirmation.message)
        }
    }

    /// Every model shows OpenRouter's price in the unit it bills the model
    /// by; a per-character rate only where that is the unit.
    func testEveryTextToSpeechModelShowsItsPrice() {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        OpenRouterAudioPrices.$pinnedTable.withValue(IOSAudioPriceFixture.table) {
            for model in ArticleSpeechCatalog.models {
                XCTAssertNotEqual(model.priceLabel, OpenRouterAudioPrices.unknownPriceLabel, model.id)
                if model.ratePerMillionCharacters == nil {
                    XCTAssertTrue(model.priceLabel.hasSuffix("per 1M tokens"), "\(model.id): \(model.priceLabel)")
                }
            }
        }
    }

    func testTextToSpeechSettingsLabelsUseLanguageFlagsWithoutInventingAnAccent() throws {
        let harper = try XCTUnwrap(
            ArticleSpeechCatalog.model(id: "microsoft/mai-voice-2")?
                .voice(id: "en-US-Harper:MAI-Voice-2")
        )
        XCTAssertEqual(harper.settingsLabel, "🇺🇸 Harper")

        let klaus = try XCTUnwrap(
            ArticleSpeechCatalog.model(id: "microsoft/mai-voice-2")?
                .voice(id: "de-DE-Klaus:MAI-Voice-2")
        )
        XCTAssertEqual(klaus.settingsLabel, "🇩🇪 Klaus")

        let grok = try XCTUnwrap(
            ArticleSpeechCatalog.model(id: ArticleSpeechCatalog.grokModelID)?
                .voice(id: "eve")
        )
        XCTAssertEqual(
            ArticleSpeechCatalog.voiceSettingsLabel(
                model: ArticleSpeechCatalog.grokModelID,
                voice: grok.id
            ),
            "Eve"
        )
    }
}

final class MobileCloudMutationServiceTests: XCTestCase {
    // MARK: - Context notebooks (Add a Notebook to Context, Take Out of Context)

    /// When `seedNotebook`'s notebooks were last changed: yesterday, so any
    /// write today is later.
    private var seededUpdatedAt: Double? {
        Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))?
            .timeIntervalSinceReferenceDate
    }

    // MARK: - Explainers

    func testExplainerIDMatchesTheMac() {
        // `ExplainerGenerationTests.explainerIDMatchesThePhone` pins the Mac's
        // `GeneratedExplainer.sourceID(explaining:)` to this same literal.
        XCTAssertEqual(
            MobileCloudMutationService.explainerSourceID(explaining: "abc-123"),
            "src_4ae5c6f243bdc2a50887a7b61658eb97d1465399eed34cec38b2e01b92d2f89a"
        )
        XCTAssertEqual(MobileURLNormalizer.normalize("foreverlm://explainer/abc-123"), "explainer/abc-123")
    }

    func testExplainersAreListedUnderTheirSourceNotOnTheirOwn() {
        // The product owner (2026-09-10): "an explainer of an article shouldn't be stored
        // as a separate entity; it should just be linked to that original
        // article somehow". The record is unchanged; the lists leave it out and
        // the source's badge, menu item and reader control reach it.
        func source(id: String, url: String, sourceType: String = "article") -> MobileCloudSource {
            MobileCloudSource(
                id: id,
                title: id,
                subtitle: "example.com",
                sourceType: sourceType,
                dateAdded: Date(),
                hasAudio: false,
                isArchived: false,
                url: url,
                normalizedURL: MobileURLNormalizer.normalize(url)
            )
        }
        let article = source(id: "abc-123", url: "https://journal.example/p")
        let explainer = source(
            id: MobileCloudMutationService.explainerSourceID(explaining: "abc-123"),
            url: "foreverlm://explainer/abc-123"
        )
        var paywalled = source(id: "pw-1", url: "https://journal.example/locked", sourceType: "paper")
        paywalled.isPaywalled = true
        let paper = source(id: "pap-1", url: "https://doi.org/10.1/x", sourceType: "paper")

        XCTAssertTrue(MobileSourceListing.isSpokenScript(explainer))
        XCTAssertFalse(MobileSourceListing.isSpokenScript(article))
        XCTAssertEqual(
            MobileSourceListing.listed([article, explainer, paywalled, paper]).map(\.id),
            ["abc-123", "pap-1"]
        )
    }

    // MARK: - Audio overviews

    func testAudioOverviewIDMatchesTheMac() {
        // `AudioOverviewTests.carrierGrammar` pins the Mac's
        // `GeneratedAudioOverview.carrierSourceID(artifactID:)` to this same
        // literal: SHA-256 of "source:v1:audio-overview/abc-123".
        XCTAssertEqual(
            MobileCloudMutationService.audioOverviewSourceID(artifactID: "abc-123"),
            "src_fdae6341ed2b4c48f243fa5adf047366b1207d743dd2710ca92ccaf060bb8546"
        )
        XCTAssertEqual(MobileURLNormalizer.normalize("foreverlm://audio-overview/abc-123"), "audio-overview/abc-123")
        XCTAssertEqual(MobileAudioOverviewRecord.artifactKind, "audio_overview")
    }

    func testAudioOverviewScriptsAreNeverRowsOfTheirOwn() {
        func source(id: String, url: String) -> MobileCloudSource {
            MobileCloudSource(
                id: id,
                title: id,
                subtitle: "ForeverLM",
                sourceType: "article",
                dateAdded: Date(),
                hasAudio: false,
                isArchived: false,
                url: url,
                normalizedURL: MobileURLNormalizer.normalize(url)
            )
        }
        let article = source(id: "art-1", url: "https://journal.example/a")
        let carrier = source(
            id: MobileCloudMutationService.audioOverviewSourceID(artifactID: "overview-1"),
            url: "foreverlm://audio-overview/overview-1"
        )
        XCTAssertTrue(MobileSourceListing.isSpokenScript(carrier))
        XCTAssertFalse(MobileSourceListing.isSpokenScript(article))
        XCTAssertEqual(MobileSourceListing.listed([article, carrier]).map(\.id), ["art-1"])
        // Its narration is the Explainers switch's, never the Articles one's.
        XCTAssertEqual(
            SourceAudioAutomation.kind(forSourceType: "article", url: carrier.url),
            SourceAudioAutomation.explainerKind
        )
    }

    func testExplainerScriptsAreNarratedFromTheirOwnText() {
        // Papers and articles wait for the Mac's prepared narration…
        XCTAssertTrue(MobileTextToSpeechNarrationPolicy.requiresMacPreparedNarration(sourceType: "paper", url: "https://j.example/p"))
        XCTAssertTrue(MobileTextToSpeechNarrationPolicy.requiresMacPreparedNarration(sourceType: "article", url: nil))
        XCTAssertTrue(MobileTextToSpeechNarrationPolicy.mayHaveMacPreparedNarration(sourceType: "book", url: "https://b.example"))
        XCTAssertFalse(MobileTextToSpeechNarrationPolicy.requiresMacPreparedNarration(sourceType: "book", url: "https://b.example"))
        // …and an explainer, an article written for the ear, never does.
        let script = "foreverlm://explainer/abc-123"
        XCTAssertFalse(MobileTextToSpeechNarrationPolicy.requiresMacPreparedNarration(sourceType: "article", url: script))
        XCTAssertFalse(MobileTextToSpeechNarrationPolicy.mayHaveMacPreparedNarration(sourceType: "article", url: script))
    }

    private func mobileSource(id: String, url: String) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: "Lesson",
            subtitle: "example.com",
            sourceType: "article",
            dateAdded: Date(),
            hasAudio: false,
            isArchived: false,
            url: url,
            normalizedURL: MobileURLNormalizer.normalize(url)
        )
    }

    private static func listenablePayload(sourceText: String) throws -> Data {
        let digest = SHA256.hash(data: Data(sourceText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try JSONSerialization.data(withJSONObject: [
            "listenableContentMetadata": [
                "sourceSHA256": digest,
                "generatorVersion": SourceListenableContentMetadata.currentVersion,
                "preparationSignature": "\(PaperNarrationFilter.preparationContractPrefix)test",
                "preparedAt": Date().timeIntervalSinceReferenceDate,
            ],
        ])
    }

}
