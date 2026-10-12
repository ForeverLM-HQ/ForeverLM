import AVFoundation
import Foundation
import Testing
@testable import ForeverLM

@Suite("Article Speech Content")
struct ArticleSpeechContentTests {
    @Test func toolbarShowsPlaybackTime() {
        #expect(
            ArticleSpeechToolbarText.playbackTimeLabel(
                current: 162,
                duration: 991,
                durationIsEstimated: true
            ) == "2:42 / ~16:31"
        )
        #expect(
            ArticleSpeechToolbarText.playbackTimeLabel(
                current: 162,
                duration: 991,
                durationIsEstimated: false
            ) == "2:42 / 16:31"
        )
    }

    @Test("automatic audio opt-ins are independent by source type")
    func automaticAudioOptInsAreIndependentBySourceType() throws {
        let suiteName = "automaticSourceAudioTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for type in SourceAudioAutomation.automatable {
            #expect(!SourceAudioAutomation.isEnabled(for: type.sourceType, defaults: defaults))
        }
        #expect(!SourceAudioAutomation.isEnabled(for: "podcast", defaults: defaults))

        defaults.set(true, forKey: SourceAudioAutomation.articlesPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: "article", defaults: defaults))
        #expect(!SourceAudioAutomation.isEnabled(for: "paper", defaults: defaults))

        defaults.set(true, forKey: SourceAudioAutomation.papersPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: "paper", defaults: defaults))
        #expect(!SourceAudioAutomation.isEnabled(for: "book", defaults: defaults))

        defaults.set(true, forKey: SourceAudioAutomation.booksPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: "book", defaults: defaults))
        #expect(!SourceAudioAutomation.isEnabled(for: "course", defaults: defaults))

        defaults.set(true, forKey: SourceAudioAutomation.coursesPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: "course", defaults: defaults))
        // Four switches on, and the explainers' switch is still its own.
        #expect(!SourceAudioAutomation.isEnabled(for: SourceAudioAutomation.explainerKind, defaults: defaults))

        defaults.set(true, forKey: SourceAudioAutomation.explainersPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: SourceAudioAutomation.explainerKind, defaults: defaults))
    }

    /// The product owner (2026-09-20): "always generate audio for explainers". An
    /// explainer is stored as an article-typed source, so the Articles switch
    /// would have covered it — and every other article with it. The kind is
    /// the one place that tells them apart, and every surface keys by it.
    @Test("an explainer has an automatic-audio switch of its own and never falls under Articles")
    func explainerHasItsOwnAutomaticAudioSwitch() throws {
        let explainerURL = ExplainerScript.url(explaining: "paper-1")
        #expect(SourceAudioAutomation.kind(forSourceType: "article", url: explainerURL) == SourceAudioAutomation.explainerKind)
        #expect(SourceAudioAutomation.kind(forSourceType: "article", url: "https://example.org/mito") == "article")
        #expect(SourceAudioAutomation.kind(forSourceType: "Paper", url: nil) == "paper")
        #expect(SourceAudioAutomation.kind(forSourceType: "book", url: "") == "book")

        var explainer = StudioArticle(url: explainerURL, title: "Explainer: A paper", sourceType: .article)
        explainer.content = "Spoken script."
        #expect(explainer.audioAutomationKind == SourceAudioAutomation.explainerKind)
        let article = StudioArticle(url: "https://example.org/mito", title: "An article", sourceType: .article)
        #expect(article.audioAutomationKind == "article")

        // A fifth switch, keyed, named and synced like the four types.
        let type = try #require(SourceAudioAutomation.automatableType(for: SourceAudioAutomation.explainerKind))
        #expect(type.preferenceKey == SourceAudioAutomation.explainersPreferenceKey)
        #expect(type.switchTitle == "Explainers")
        #expect(SourceAudioAutomation.noun(forSourceType: SourceAudioAutomation.explainerKind, count: 1) == "explainer")
        #expect(SourceAudioAutomation.noun(forSourceType: SourceAudioAutomation.explainerKind, count: 2) == "explainers")
        #expect(SourceAudioAutomation.enableConfirmationTitle(sourceType: SourceAudioAutomation.explainerKind)
            == "Automatically generate audio for explainers?")
        #expect(SourceAudioAutomation.constraintPreferenceKey(for: SourceAudioAutomation.explainerKind)
            == "readAloud.autoGenerate.constraint.explainer")
        #expect(SyncedPreferenceKeys.isSynced(SourceAudioAutomation.explainersPreferenceKey))
        #expect(SyncedPreferenceKeys.isSynced("readAloud.autoGenerate.constraint.explainer"))
        #expect(SourceAudioAutomation.GenerationProgress(
            completedCount: 0, totalCount: 1,
            currentSourceType: SourceAudioAutomation.explainerKind, currentTitle: "Explainer: A paper"
        ).currentSourceSystemImage == "lightbulb")

        // The Articles switch alone never narrates an explainer, and the
        // Explainers switch alone never narrates an article.
        let suiteName = "explainerAutomationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SourceAudioAutomation.articlesPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: article.audioAutomationKind, defaults: defaults))
        #expect(!SourceAudioAutomation.isEnabled(for: explainer.audioAutomationKind, defaults: defaults))
        defaults.set(false, forKey: SourceAudioAutomation.articlesPreferenceKey)
        defaults.set(true, forKey: SourceAudioAutomation.explainersPreferenceKey)
        #expect(SourceAudioAutomation.isEnabled(for: explainer.audioAutomationKind, defaults: defaults))
        #expect(!SourceAudioAutomation.isEnabled(for: article.audioAutomationKind, defaults: defaults))
    }

    /// The switch stands in for the per-run cost question — for the Explain
    /// button and for `generate_explainer` — exactly when the selected voice is
    /// one automation may spend on. It never opens a route the worker itself
    /// would refuse.
    @Test("an explainer's audio starts without the quote only when its switch is on and the voice qualifies")
    func explainerAudioStartsWithoutConfirmationOnlyBehindItsSwitch() throws {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        try OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let suiteName = "explainerAutomationStart.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let kind = SourceAudioAutomation.explainerKind
            let free = AutomaticAudioSelection(
                provider: .openRouter, model: "deepgram/flux-tts:free", voice: "aura", allowsPaidVoices: false
            )
            let paid = AutomaticAudioSelection(
                provider: .openRouter, model: "hexgrad/kokoro-82m", voice: "af_heart", allowsPaidVoices: false
            )
            var consented = paid
            consented.allowsPaidVoices = true
            let unpriced = AutomaticAudioSelection(
                provider: .openRouter, model: "nobody/unlisted-voice", voice: "", allowsPaidVoices: true
            )
            let otherProvider = AutomaticAudioSelection(
                provider: .groq, model: "deepgram/flux-tts:free", voice: "", allowsPaidVoices: true
            )

            // Off: every selection asks.
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: kind, selection: free, defaults: defaults))

            defaults.set(true, forKey: SourceAudioAutomation.explainersPreferenceKey)
            #expect(MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: kind, selection: free, defaults: defaults))
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: kind, selection: paid, defaults: defaults))
            #expect(MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: kind, selection: consented, defaults: defaults))
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: kind, selection: unpriced, defaults: defaults))
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: kind, selection: otherProvider, defaults: defaults))
            // The explainers' switch says nothing about articles.
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: "article", selection: free, defaults: defaults))

            // The selection explains itself when it cannot run, and is silent when it can.
            #expect(free.isAllowed && free.unavailableReason == nil)
            #expect(paid.unavailableReason?.contains("Allow paid voices") == true)
            #expect(unpriced.unavailableReason?.contains("no published price") == true)
            #expect(otherProvider.unavailableReason?.contains("groq") == true)
            #expect(paid.requiresPaidVoiceConsent && !free.requiresPaidVoiceConsent)
        }
    }

    @Test("automatic audio progress is source-level and bounded")
    func automaticAudioProgressIsSourceLevelAndBounded() {
        let progress = SourceAudioAutomation.GenerationProgress(
            completedCount: 111,
            totalCount: 468,
            currentSourceType: "paper",
            currentTitle: "Feed Forward Loops"
        )
        #expect(progress.countLabel == "111 of 468")
        #expect(progress.fractionCompleted == 111.0 / 468.0)
        #expect(progress.currentTitle == "Feed Forward Loops")
        #expect(progress.currentSourceLabel == "Paper · Feed Forward Loops")
        #expect(progress.currentSourceSystemImage == "doc.text.magnifyingglass")

        #expect(SourceAudioAutomation.GenerationProgress(
            completedCount: 3,
            totalCount: 0,
            currentSourceType: nil,
            currentTitle: nil
        ).fractionCompleted == 0)
        #expect(SourceAudioAutomation.GenerationProgress(
            completedCount: 7,
            totalCount: 4,
            currentSourceType: "article",
            currentTitle: nil
        ).fractionCompleted == 1)
    }

    @Test("automatic audio constraints are portable and preview exact character cost")
    func automaticAudioConstraintsAndPreview() throws {
        let suiteName = "automaticSourceAudioConstraintTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = try #require(SourceAudioAutomation.constraintPreferenceKey(for: "paper"))
        #expect(key == "readAloud.autoGenerate.constraint.paper")
        defaults.set("  mitochondria  ", forKey: key)
        #expect(SourceAudioAutomation.constraint(for: "paper", defaults: defaults) == "mitochondria")

        let preview = SourceAudioAutomation.FilterPreview(
            constraint: "mitochondria",
            matches: [
                .init(
                    id: "paper-1",
                    sourceType: "paper",
                    title: "One",
                    author: nil,
                    journal: nil,
                    year: nil,
                    collection: nil,
                    url: nil,
                    description: nil,
                    characterCount: 25_000
                ),
                .init(
                    id: "paper-2",
                    sourceType: "paper",
                    title: "Two",
                    author: nil,
                    journal: nil,
                    year: nil,
                    collection: nil,
                    url: nil,
                    description: nil,
                    characterCount: 75_000
                ),
            ]
        )
        #expect(preview.characterCount == 100_000)
        #expect(preview.speechCost(ratePerMillionCharacters: 15) == 1.5)
    }

    @Test("automation covers the reading types and never the audio-native ones")
    func automationCoversTheReadingTypesAndNeverTheAudioNativeOnes() {
        #expect(SourceAudioAutomation.automatableSourceTypes == ["article", "paper", "book", "course", "explainer"])

        // Sources that arrive as audio must never be narrated from their
        // transcripts, so they have no switch to turn on.
        for sourceType in ["podcast", "video", "meeting", "xPost", "manual", "unclassified"] {
            #expect(SourceAudioAutomation.preferenceKey(for: sourceType) == nil)
            #expect(SourceAudioAutomation.automatableType(for: sourceType) == nil)
        }

        // Every entry is a real source type — or the explainer kind, an
        // article-typed row with a switch of its own — keyed and named for
        // sentences.
        for type in SourceAudioAutomation.automatable {
            #expect(
                StudioSourceType(rawValue: type.sourceType) != nil
                    || type.sourceType == SourceAudioAutomation.explainerKind
            )
            #expect(type.preferenceKey.hasPrefix("readAloud.autoGenerate."))
            #expect(!type.singular.isEmpty && !type.plural.isEmpty)
            #expect(SourceAudioAutomation.switchTitle(forSourceType: type.sourceType) == type.switchTitle)
        }

        // A book's sources are chapters; the count has to say chapters.
        #expect(SourceAudioAutomation.noun(forSourceType: "book", count: 1) == "book chapter")
        #expect(SourceAudioAutomation.noun(forSourceType: "book", count: 3) == "book chapters")
        #expect(SourceAudioAutomation.switchTitle(forSourceType: "book") == "Books")
        #expect(SourceAudioAutomation.enableConfirmationTitle(sourceType: "course")
            == "Automatically generate audio for course documents?")

        // An unknown type never resolves to a real switch or a wrong noun.
        #expect(SourceAudioAutomation.noun(forSourceType: "podcast", count: 1) == "source")
        #expect(SourceAudioAutomation.switchTitle(forSourceType: "podcast") == "Sources")
    }

    @Test("a backlog is priced from its characters and the selected model rate")
    func backlogIsPricedFromCharactersAndTheSelectedModelRate() {
        let oneMillionCharacters = SourceAudioAutomation.Backlog(
            sourceCount: 4,
            characterCount: 1_000_000
        )
        #expect(oneMillionCharacters.estimatedCost(ratePerMillionCharacters: 40) == 40)
        // Changing the selected model rate changes the quote deterministically.
        #expect(oneMillionCharacters.estimatedCost(ratePerMillionCharacters: 10) == 10)

        let charactersOnly = SourceAudioAutomation.Backlog(
            sourceCount: 4,
            characterCount: 500_000
        )
        #expect(charactersOnly.estimatedCost(ratePerMillionCharacters: 40) == 20)

        // Without a character total or a current model rate, quote no number
        // rather than substituting unrelated usage history.
        #expect(
            SourceAudioAutomation.Backlog(sourceCount: 4)
                .estimatedCost(ratePerMillionCharacters: 40) == nil
        )
        #expect(
            SourceAudioAutomation.Backlog(sourceCount: 4, characterCount: 500_000)
                .estimatedCost(ratePerMillionCharacters: nil) == nil
        )
        #expect(oneMillionCharacters.estimatedCost(ratePerMillionCharacters: 0) == 0)
        #expect(
            SourceAudioAutomation.estimateLabel(for: oneMillionCharacters, ratePerMillionCharacters: 0)
                == "1,000,000 characters · free"
        )
        // Nothing waiting costs nothing, whatever the rate card says.
        #expect(SourceAudioAutomation.Backlog().estimatedCost(ratePerMillionCharacters: 40) == 0)

        // A rate-card estimate prices the speech alone — automation also
        // prepares each source's narration — so it must not read as the total.
        #expect(
            SourceAudioAutomation.estimateLabel(for: charactersOnly, ratePerMillionCharacters: 40)
                == "500,000 characters · about $20.00 of speech"
        )
        #expect(
            SourceAudioAutomation.estimateLabel(for: oneMillionCharacters, ratePerMillionCharacters: 40)
                == "1,000,000 characters · about $40.00 of speech"
        )
        #expect(
            SourceAudioAutomation.estimateLabel(
                for: SourceAudioAutomation.Backlog(sourceCount: 4),
                ratePerMillionCharacters: 40
            ) == nil
        )
        #expect(
            SourceAudioAutomation.estimateLabel(
                for: SourceAudioAutomation.Backlog(),
                ratePerMillionCharacters: 40
            ) == nil
        )
    }

    @Test("narration characters fall back to the word count")
    func narrationCharactersFallBackToTheWordCount() {
        #expect(
            SourceAudioAutomation.estimatedCharacters(wordCount: 900, contentCharacterCount: 5_400) == 5_400
        )
        #expect(SourceAudioAutomation.estimatedCharacters(wordCount: 900, contentCharacterCount: nil) == 5_400)
        #expect(SourceAudioAutomation.estimatedCharacters(wordCount: nil, contentCharacterCount: 0) == nil)
        #expect(SourceAudioAutomation.estimatedCharacters(wordCount: 0, contentCharacterCount: nil) == nil)
    }

    @Test("the paid consent dialog prices the whole pending library before it is granted")
    func paidConsentDialogPricesTheWholeLibrary() {
        #expect(SyncedPreferenceKeys.isSynced(
            SourceAudioAutomation.paidVoiceConsentPreferenceKey
        ))

        let preview = SourceAudioAutomation.LibraryCostPreview(
            backlogs: [
                "article": .init(sourceCount: 1, characterCount: 500_000),
                "paper": .init(sourceCount: 2, characterCount: 500_000),
                // Nothing waiting, so it is left out of the quote entirely.
                "book": .init(sourceCount: 0, characterCount: nil),
            ],
            ratePerMillionCharacters: 40
        )
        #expect(preview.sourceCount == 3)
        #expect(preview.characterCount == 1_000_000)
        // Presentation order, and empty types omitted.
        #expect(preview.lines.map(\.sourceType) == ["article", "paper"])
        #expect(preview.totalLabel.contains("3 sources"))
        #expect(preview.totalLabel.contains("$40.00"))

        let message = SourceAudioAutomation.paidVoiceConsentMessage(
            voiceName: "Gemini 3.1 Flash TTS",
            preview: preview
        )
        #expect(message.contains("Gemini 3.1 Flash TTS costs $40 / 1M characters."))
        #expect(message.contains("Articles · 1 article"))
        #expect(message.contains("Papers · 2 papers"))
        #expect(message.contains("Total: 3 sources"))

        // One unsized type must not let a partial sum read as the whole bill.
        let partial = SourceAudioAutomation.LibraryCostPreview(
            backlogs: [
                "article": .init(sourceCount: 1, characterCount: 500_000),
                "paper": .init(sourceCount: 1, characterCount: nil),
            ],
            ratePerMillionCharacters: 40
        )
        #expect(partial.characterCount == nil)
        #expect(partial.total == nil)
        #expect(partial.totalLabel.contains("total size unavailable"))

        // Nothing waiting still warns that later arrivals are charged.
        let empty = SourceAudioAutomation.LibraryCostPreview(
            backlogs: [:],
            ratePerMillionCharacters: 40
        )
        #expect(empty.isEmpty)
        #expect(SourceAudioAutomation.paidVoiceConsentMessage(
            voiceName: "Gemini 3.1 Flash TTS",
            preview: empty
        ).contains("Nothing is waiting right now"))
    }

    @Test("stopping a run says the switches are still on")
    func stoppingARunSaysTheSwitchesAreStillOn() {
        // Stop halts the batch in flight only. Saying so is the whole point:
        // the learner has to know the next arrival starts it again.
        let message = SourceAudioAutomation.stoppedRunMessage(completedCount: 38)
        #expect(message.contains("38 sources were generated and are billed"))
        #expect(message.contains("stay switched on"))
        #expect(message.contains("Switch them off to stop for good"))
        #expect(SourceAudioAutomation.stoppedRunMessage(completedCount: 1)
            .contains("1 source was generated and is billed"))
    }

    @Test("automatic audio runs free, runs paid only on consent, never runs unpriced")
    func automaticAudioRunsPaidOnlyOnConsent() {
        // Prices are OpenRouter's catalog's, which unit tests pin rather than read.
        OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            // Free needs no consent, and granting consent does not change it.
            #expect(SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "fish-audio/s2.1-pro-free:free"
            ))
            #expect(SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "deepgram/flux-tts:free"
            ))
            #expect(!SourceAudioAutomation.requiresPaidVoiceConsent(
                provider: ArticleSpeechCatalog.provider,
                model: "deepgram/flux-tts:free"
            ))

            // Paid fails closed until consent, then runs.
            #expect(!SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "hexgrad/kokoro-82m"
            ))
            #expect(SourceAudioAutomation.requiresPaidVoiceConsent(
                provider: ArticleSpeechCatalog.provider,
                model: "hexgrad/kokoro-82m"
            ))
            #expect(SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "hexgrad/kokoro-82m",
                allowsPaidVoices: true
            ))

            // Gemini is billed by its tokens, so it has no per-character rate
            // to put to the learner, and automation never runs on it.
            #expect(!SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "google/gemini-3.1-flash-tts-preview",
                allowsPaidVoices: true
            ))

            // An unpriced entry stays closed even with consent: consent covers a
            // number the learner was shown, never an unknown one.
            #expect(!SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "missing-model"
            ))
            #expect(!SourceAudioAutomation.allowsAutomaticGeneration(
                provider: ArticleSpeechCatalog.provider,
                model: "missing-model",
                allowsPaidVoices: true
            ))
            #expect(!SourceAudioAutomation.requiresPaidVoiceConsent(
                provider: ArticleSpeechCatalog.provider,
                model: "missing-model"
            ))

            let paid = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "article",
                backlog: SourceAudioAutomation.Backlog(sourceCount: 12, characterCount: 18_000),
                ratePerMillionCharacters: 40
            )
            #expect(paid.contains("allow paid voices first"))
            #expect(!paid.contains("12 articles"))

            // Consented, the same switch prices the backlog instead of refusing it.
            let consented = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "article",
                backlog: SourceAudioAutomation.Backlog(sourceCount: 12, characterCount: 18_000),
                ratePerMillionCharacters: 40,
                allowsPaidVoices: true
            )
            #expect(consented.contains("$40 / 1M characters"))
            #expect(consented.contains("12 articles already in your library"))
            #expect(consented.contains("already been narrated is billed"))

            // Unpriced refuses whatever the consent says.
            let unpriced = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "article",
                backlog: SourceAudioAutomation.Backlog(sourceCount: 12, characterCount: 18_000),
                ratePerMillionCharacters: nil,
                allowsPaidVoices: true
            )
            #expect(unpriced.contains("no published price"))

            // One waiting source reads as one, not as "1 articles ... have".
            let single = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "paper",
                backlog: SourceAudioAutomation.Backlog(sourceCount: 1, characterCount: 12_500),
                ratePerMillionCharacters: 0
            )
            #expect(single.contains("1 paper already in your library has no audio yet"))
            #expect(single.contains("generating it now"))

            // No backlog still says the switch spends on what arrives next.
            let empty = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "article",
                backlog: SourceAudioAutomation.Backlog(),
                ratePerMillionCharacters: 0
            )
            #expect(empty.contains("nothing is generated until the next one arrives"))

            // Without paid consent, an unpriced model is blocked rather than guessed
            // to be free. Distinct from the consented case above, which refuses for
            // want of a published price.
            let unpricedWithoutConsent = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "article",
                backlog: SourceAudioAutomation.Backlog(sourceCount: 3),
                ratePerMillionCharacters: nil
            )
            #expect(unpricedWithoutConsent.contains("no published price"))
            #expect(!unpricedWithoutConsent.contains("3 articles"))

            let free = SourceAudioAutomation.enableConfirmationMessage(
                sourceType: "article",
                backlog: SourceAudioAutomation.Backlog(sourceCount: 2, characterCount: 3_000),
                ratePerMillionCharacters: 0
            )
            #expect(free.contains("selected free voice"))
            #expect(free.contains("2 articles"))

            #expect(SourceAudioAutomation.enableConfirmationTitle(sourceType: "paper")
                == "Automatically generate audio for papers?")
            #expect(SourceAudioAutomation.switchTitle(forSourceType: "paper") == "Papers")
        }
    }

    @Test("the standing disclosure names the free, consented, and unpriced states")
    func standingDisclosureNamesEveryState() {
        let priced = SourceAudioAutomation.costDisclosure(ratePerMillionCharacters: 40)
        #expect(priced.contains("off for paid voices"))
        #expect(priced.contains("$40 / 1M characters"))

        let consented = SourceAudioAutomation.costDisclosure(
            ratePerMillionCharacters: 40,
            allowsPaidVoices: true
        )
        #expect(consented.contains("Paid voices are allowed"))
        #expect(consented.contains("billed to your OpenRouter key"))

        // Consent never unlocks a model this build cannot price.
        let unpriced = SourceAudioAutomation.costDisclosure(
            ratePerMillionCharacters: nil,
            allowsPaidVoices: true
        )
        #expect(unpriced.contains("no published price"))

        let free = SourceAudioAutomation.costDisclosure(ratePerMillionCharacters: 0)
        #expect(free.contains("selected free voice"))

        // Formatting is shared with Listen's quote, down to the zero case.
        #expect(SourceAudioAutomation.costLabel(0.004) == "less than $0.01")
        #expect(SourceAudioAutomation.costLabel(0) == "free")
        #expect(SourceAudioAutomation.costLabel(1.239) == "$1.24")
        #expect(
            SourceAudioAutomation.costLabel(1.239)
                == ArticleSpeechCostEstimate(characters: 0, usd: 1.239).costLabel
        )
        #expect(SourceAudioAutomation.rateLabel(ratePerMillionCharacters: 0.62) == "$0.62 / 1M characters")
        #expect(SourceAudioAutomation.rateLabel(ratePerMillionCharacters: 0) == "free")
        #expect(SourceAudioAutomation.rateLabel(ratePerMillionCharacters: nil) == nil)
    }

    @Test("podcasts are not eligible for generated text to speech")
    func podcastsAreNotEligibleForGeneratedTextToSpeech() async {
        var podcast = StudioArticle(
            url: "apple-podcast://episode/123",
            title: "Podcast Episode",
            sourceType: .podcast
        )
        podcast.content = "A transcript exists, but the original source is already audio."

        let podcastText = await ArticleSpeechContent.text(for: podcast)

        #expect(!ArticleSpeechContent.canAttemptRead(podcast))
        #expect(podcastText == nil)
        #expect(!StudioSourceType.podcast.configurableMetadataFields.contains(.ttsCache))
    }

    @Test("YouTube transcripts are not eligible for generated text to speech")
    func youtubeTranscriptsAreNotEligibleForGeneratedTextToSpeech() async {
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "YouTube Lecture",
            sourceType: .video
        )
        video.content = "A transcript exists, but the original video is already audio."

        let videoText = await ArticleSpeechContent.text(for: video)

        #expect(!ArticleSpeechContent.canAttemptRead(video))
        #expect(videoText == nil)
    }

    @Test("meetings with a playable recording are not eligible for generated text to speech")
    func recordedMeetingsAreNotEligibleForGeneratedTextToSpeech() async {
        var recorded = StudioArticle(
            url: "meeting://team-sync/2026-07-21",
            title: "Team Sync",
            sourceType: .meeting
        )
        recorded.content = "A transcript exists, but the recording plays in the reader."

        var transcriptOnly = StudioArticle(
            url: "meeting://team-sync/2026-07-14",
            title: "Team Sync (Read AI)",
            sourceType: .meeting
        )
        transcriptOnly.content = "Speaker: transcript text."

        MeetingRecordingAvailability.update(from: [
            recorded.id: [
                MeetingArtifact(
                    sourceId: recorded.id,
                    groupId: "team-sync",
                    kind: .recording,
                    title: "Recording.mp4",
                    localFilePath: "/meetings/team-sync/Recording.mp4"
                )
            ],
            transcriptOnly.id: [
                MeetingArtifact(
                    sourceId: transcriptOnly.id,
                    groupId: "team-sync",
                    kind: .transcript,
                    title: "Transcript.txt",
                    localFilePath: "/meetings/team-sync/Transcript.txt"
                )
            ]
        ])

        let recordedText = await ArticleSpeechContent.text(for: recorded)

        #expect(!ArticleSpeechContent.canAttemptRead(recorded))
        #expect(recordedText == nil)
        #expect(ArticleSpeechContent.canAttemptRead(transcriptOnly))
    }

    @Test("non-YouTube videos with transcripts remain eligible for text to speech")
    func nonYouTubeVideosRemainEligibleForTextToSpeech() async {
        var recording = StudioArticle(
            url: "https://app.read.ai/analytics/meetings/123",
            title: "Team Meeting Recording",
            sourceType: .video
        )
        recording.content = "Meeting transcript text."

        #expect(ArticleSpeechContent.canAttemptRead(recording))
        #expect(await ArticleSpeechContent.text(for: recording) == "Meeting transcript text.")
    }

    @Test("articles with text remain eligible for text to speech")
    func articlesWithTextRemainEligibleForTextToSpeech() async {
        var article = StudioArticle(
            url: "https://example.com/article",
            title: "Article",
            sourceType: .article
        )
        article.content = "Readable article text."

        let articleText = await ArticleSpeechContent.text(for: article)

        #expect(ArticleSpeechContent.canAttemptRead(article))
        #expect(articleText == "Readable article text.")
    }

    @Test("speakable TTS input must contain letters or digits")
    func speakableTTSInputRequiresLettersOrDigits() {
        #expect(MacArticleSpeechText.speakableInput(from: " \n--- ... \t ") == nil)
        #expect(MacArticleSpeechText.speakableInput(from: "  Section 1.  ") == "Section 1.")
    }

    @Test("soft-wrapped PDF lines are rejoined into a flowing paragraph")
    func softWrappedLinesAreRejoined() {
        let extracted = """
        Maintaining order at the tissue level is crucial throughout the lifespan, as failure
        can lead to cancer and an accumulation of molecular and cellular disorders. We
        argue here that the most consistent and pervasive result of these failures is aging.
        """

        #expect(
            MacArticleSpeechText.reflowedForSpeech(extracted) ==
            "Maintaining order at the tissue level is crucial throughout the lifespan, as failure can lead to cancer and an accumulation of molecular and cellular disorders. We argue here that the most consistent and pervasive result of these failures is aging."
        )
    }

    @Test("blank lines are preserved as paragraph breaks when reflowing")
    func blankLinesSeparateParagraphs() {
        let extracted = """
        First paragraph line one
        first paragraph line two.

        Second paragraph here.
        """

        #expect(
            MacArticleSpeechText.reflowedForSpeech(extracted) ==
            "First paragraph line one first paragraph line two.\n\nSecond paragraph here."
        )
    }

    @Test("words hyphenated across a line break are de-hyphenated")
    func hyphenatedLineBreaksAreJoined() {
        let extracted = """
        driven by abroga-
        tion of the endogenous bioelectric signaling.
        """

        #expect(
            MacArticleSpeechText.reflowedForSpeech(extracted) ==
            "driven by abrogation of the endogenous bioelectric signaling."
        )
    }

    @Test("sentence splitting keeps abbreviations, initials, and decimals intact")
    func sentenceSplittingRespectsAbbreviations() {
        let paragraph = "See Fig. 3 for details. J. Levin measured a 3.14 cm shift. It worked!"

        #expect(
            MacArticleSpeechText.sentences(in: paragraph) == [
                "See Fig. 3 for details.",
                "J. Levin measured a 3.14 cm shift.",
                "It worked!"
            ]
        )
    }

    @Test("trailing references section is preserved in narration")
    func referencesSectionIsPreserved() {
        let paper = """
        The body of the paper explains the core idea in enough words to fill out the front half of the document.

        It continues with a second substantial paragraph of real content that a listener would actually want to hear.

        References

        [1] Smith, J. A study of things. Journal, 2020.
        [2] Jones, R. Another study. Journal, 2019.
        """

        let narration = MacArticleSpeechText.narrationText(from: paper)
        #expect(narration.contains("Smith, J."))
        #expect(narration.lowercased().contains("references"))
        #expect(narration.contains("core idea"))
    }

    @Test("paper narration preserves publisher front matter and source text")
    func academicPaperFrontMatterIsPreserved() {
        let paper = """
        nature aging
        Perspective
        https://doi.org/10.1038/s43587-024-00716-x
        The brain–body energy conservation model
        of aging
        Received: 21 November 2023
        Evan D. Shaulson1, Alan A. Cohen
        2,3 & Martin Picard
        1,2,4,5
        Accepted: 4 September 2024
        Published online: 08 October 2024
        Check for updates
        Aging involves seemingly paradoxical changes in energy metabolism.
        Molecular damage accumulation increases cellular energy expenditure,
        yet whole-body energy expenditure remains stable or decreases with age.
        All aging mammals have a brain that evolved to promote survival.
        This is another substantial body sentence that belongs in the narration.
        1Department of Psychiatry, Columbia University, New York, NY, USA.
        2Robert N. Butler Columbia Aging Center, New York, NY, USA. e-mail: author@example.com
        Nature Aging
        \u{000C}
        Perspective
        https://doi.org/10.1038/s43587-024-00716-x
        Distributed control of mammalian aging
        The geroscience agenda has primarily focused on cellular processes.
        This body paragraph provides enough useful detail for a listener to hear.
        Nature Aging
        \u{000C}
        Perspective
        https://doi.org/10.1038/s43587-024-00716-x
        Conclusion
        The model connects cellular energy use to organism-level aging phenotypes.
        This final body paragraph makes the intended document comfortably longer.
        References
        1. Smith, J. A study of things. Journal, 2020.
        2. Jones, R. Another study. Journal, 2019.
        Nature Aging
        """

        let narration = MacArticleSpeechText.narrationText(from: paper)

        #expect(narration.contains("The brain–body energy conservation model"))
        #expect(narration.contains("of aging"))
        #expect(narration.contains("Aging involves seemingly paradoxical changes"))
        #expect(narration.contains("Distributed control of mammalian aging"))
        #expect(narration.localizedCaseInsensitiveContains("nature aging"))
        #expect(narration.contains("Perspective"))
        #expect(narration.contains("doi.org"))
        #expect(narration.contains("Received:"))
        #expect(narration.contains("Evan D. Shaulson"))
        #expect(narration.contains("Department of Psychiatry"))
        #expect(narration.contains("author@example.com"))
        #expect(narration.contains("Smith, J."))
    }

    @Test("paper narration preserves figure captions")
    func paperNarrationPreservesFigureCaptions() {
        let paper = """
        A Useful Paper

        The opening paragraph establishes the question being studied.

        Fig. 1 | Experimental overview. Panel a shows the cohort and panel b shows the intervention.

        Figure 2: Outcomes by treatment group. Error bars show standard deviations.

        Extended Data Fig. 3. Sensitivity analysis across all model specifications.

        Figure 4 shows why the treatment effect matters in the main argument.

        The conclusion explains what follows from the results.
        """

        let narration = MacArticleSpeechText.paperNarrationText(from: paper)

        #expect(narration.contains("The opening paragraph"))
        #expect(narration.contains("Figure 4 shows why"))
        #expect(narration.contains("The conclusion"))
        #expect(narration.contains("Experimental overview"))
        #expect(narration.contains("Outcomes by treatment group"))
        #expect(narration.contains("Sensitivity analysis"))
    }

    @Test("paper cleanup is a configurable cheap-default deletion task")
    func paperCleanupTaskConfiguration() {
        #expect(AITask.advancedTasks.contains(.paperNarrationPreparation))
        #expect(AITask.paperNarrationPreparation.sourceType == nil)
        #expect(AITask.paperNarrationPreparation.defaultPrompt == Prompts.paperNarrationPreparation)
        #expect(Prompts.paperNarrationPreparation.contains("never rewrite or return cleaned source prose"))
        #expect(Prompts.paperNarrationPreparation.contains("deletion-and-relocation plan"))
        #expect(Prompts.paperNarrationPreparation.lowercased().contains("main paragraph must finish before any box begins"))
        #expect(Prompts.paperNarrationPreparation.contains("Identify bibliography entries from their content"))

        #expect(AITask.paperNarrationPreparation.usesBackgroundModelDefault)
    }

    @Test("article cleanup puts an empty-credit action before pipeline detail")
    func articleCleanupCreditsPresentation() {
        let failure = PaperContentPreparationService.articleIngestionFailureMessage(
            for: AIError.apiError(PaperContentPreparationService.contentCleanupCreditsPausedMessage)
        )
        #expect(failure == PaperContentPreparationService.contentCleanupCreditsPausedMessage)
        #expect(failure.hasPrefix("Source Content Cleanup paused:"))

        let proxyFailure = PaperContentPreparationService.articleIngestionFailureMessage(
            for: AIError.apiError("ForeverLM AI credits are empty — top up in Settings to continue.")
        )
        #expect(proxyFailure == PaperContentPreparationService.contentCleanupCreditsPausedMessage)

        // Rows paused before the prepaid balance was retired kept its wording.
        let retiredPausedWording =
            "Source Content Cleanup paused: your ForeverLM AI balance is empty. Top up to finish ingesting this source."
        #expect(
            PaperContentPreparationService.articleCreditsMessage(for: retiredPausedWording)
                == PaperContentPreparationService.contentCleanupCreditsPausedMessage
        )
        #expect(PaperContentPreparationService.isEmptyBalanceFailure(retiredPausedWording))

        let legacy = "Article ingestion failed during Source Content Cleanup: Source Content Cleanup is not configured."
        #expect(
            PaperContentPreparationService.articleCreditsMessage(
                for: legacy,
                creditsAreEmpty: true
            ) == PaperContentPreparationService.contentCleanupCreditsPausedMessage
        )
        #expect(
            PaperContentPreparationService.articleCreditsMessage(
                for: legacy,
                creditsAreEmpty: false
            ) == nil
        )

        // The rows a second Mac wrote while re-ingesting synced sources carry the
        // older service wording. They state the balance was empty themselves, so
        // they reclassify without consulting the live account.
        let legacyServiceWording =
            "Article ingestion failed during Source Content Cleanup: ForeverLM AI credits are empty — top up in Settings to continue."
        for creditsAreEmpty in [true, false] {
            #expect(
                PaperContentPreparationService.articleCreditsMessage(
                    for: legacyServiceWording,
                    creditsAreEmpty: creditsAreEmpty
                ) == PaperContentPreparationService.contentCleanupCreditsPausedMessage
            )
        }

        let networkFailure = PaperContentPreparationService.articleIngestionFailureMessage(
            for: URLError(.networkConnectionLost)
        )
        #expect(networkFailure.contains("Source Content Cleanup"))
        #expect(networkFailure.contains("network connection was lost"))
    }

    @Test("only code-owned transient cleanup failures are auto-recoverable")
    func transientCleanupFailureClassification() {
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            "Article ingestion failed during Source Content Cleanup: The request timed out."
        ))
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            StudioArticle.paperContentCleanupFailureMessage("The network connection was lost.")
        ))
        #expect(!PaperContentPreparationService.isTransientIngestionFailure(
            "Article ingestion failed during Source Content Cleanup: Source Content Cleanup is not configured."
        ))
        #expect(!PaperContentPreparationService.isTransientIngestionFailure(
            "My notes say the request timed out."
        ))
    }

    @Test("a cancelled pass is never a source's own failure")
    func cancellationIsNotAFailure() {
        // Three faces of one event: a cooperative checkpoint, a request already
        // on the wire, and either of those after a caller flattened it to text.
        #expect(AITransientErrorClassifier.isCancellation(CancellationError()))
        #expect(AITransientErrorClassifier.isCancellation(URLError(.cancelled)))
        #expect(AITransientErrorClassifier.isCancellation(
            AIError.apiError(CancellationError().localizedDescription)
        ))
        #expect(!AITransientErrorClassifier.isCancellation(URLError(.timedOut)))
        #expect(!AITransientErrorClassifier.isCancellation(AIError.apiError("Rate limit hit.")))
        // A provider sentence that merely contains the word is not a
        // cancellation: Foundation's own description is the whole message, or
        // the detail at the end of one the app wrapped.
        #expect(AITransientErrorClassifier.isCancellation(AIError.apiError("cancelled")))
        #expect(!AITransientErrorClassifier.isCancellation(
            AIError.apiError("Generation cancelled by the content filter, then resumed.")
        ))

        // An in-process retry loop must still stop on a cancellation, while
        // durable work that was cancelled has simply not been attempted yet.
        #expect(!AITransientErrorClassifier.isTransient(CancellationError()))
        #expect(AITransientErrorClassifier.shouldRetryAutomatically(CancellationError()))
        #expect(AITransientErrorClassifier.shouldRetryAutomatically(URLError(.timedOut)))
        #expect(!AITransientErrorClassifier.shouldRetryAutomatically(
            AIError.apiError("Source Content Cleanup is not configured.")
        ))
    }

    @Test("papers parked by an interrupted cleanup re-stage themselves")
    func parkedCancellationFailuresAreRecoverable() {
        // An earlier build recorded the interrupted drain as the paper's own
        // verdict. Those rows describe work that never ran, so the resume sweep
        // has to claim them instead of leaving a Retry button per paper.
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            StudioArticle.paperContentCleanupFailureMessage(
                CancellationError().localizedDescription
            )
        ))
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            PaperContentPreparationService.articleIngestionFailureMessage(
                for: URLError(.cancelled)
            )
        ))
        // A cancelled URLSession task reduces to the single word, while a
        // URLError with no localized string of its own gives the generic form.
        // Both have been persisted, so both have to be claimed back.
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            StudioArticle.paperContentCleanupFailureMessage("cancelled")
        ))
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            "Article ingestion failed during Source Content Cleanup: cancelled"
        ))
        // Still only the app's own cleanup sentences, never arbitrary text.
        #expect(!PaperContentPreparationService.isTransientIngestionFailure(
            CancellationError().localizedDescription
        ))
    }

    @Test("automatic audio filtering is a configurable background task")
    func automaticAudioFilteringTaskConfiguration() {
        // The rule needs an LLM, so the task has to be selectable in Settings
        // like every other background task rather than pinned to one model.
        #expect(AITask.advancedTasks.contains(.automaticAudioFiltering))
        #expect(AITask.automaticAudioFiltering.sourceType == nil)
        #expect(AITask.automaticAudioFiltering.displayName == "Automatic Audio Filtering")
        #expect(AITask.automaticAudioFiltering.usesBackgroundModelDefault)
        #expect(AITask.automaticAudioFiltering.requiresVision == false)
        #expect(AITask.automaticAudioFiltering.defaultPrompt == Prompts.automaticAudioFiltering)
        #expect(Prompts.automaticAudioFiltering.contains("matching_ids"))
        #expect(Prompts.automaticAudioFiltering.contains("Do not rewrite, merge, or invent IDs"))
    }

    @Test("source text-to-speech adaptation is a distinct configurable task")
    func paperTextToSpeechTaskConfiguration() {
        #expect(AITask.advancedTasks.contains(.paperTextToSpeechPreparation))
        #expect(AITask.paperTextToSpeechPreparation.sourceType == nil)
        #expect(AITask.paperTextToSpeechPreparation.displayName == "Text-to-Speech Preparation")
        #expect(AITask.paperTextToSpeechPreparation.usesBackgroundModelDefault)
        #expect(AITask.paperTextToSpeechPreparation.defaultPrompt == Prompts.paperTextToSpeechPreparation)
        #expect(Prompts.paperTextToSpeechPreparation.contains("Do not read cells"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("main pattern"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("Never paraphrase prose"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("finish the main paragraph"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("relocations"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("disease1"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("(Brandt et al)"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("article or academic paper"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("narrator says it only once"))
        #expect(Prompts.paperTextToSpeechPreparation.contains("photo credits"))
    }

    @Test("article text-to-speech omits a figure caption already stated in adjacent prose")
    func articleTextToSpeechOmitsRedundantFigureCaption() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "In one month, liver toxicity flagged three major drugs and erased five billion dollars in market value."
            ),
            AIService.PaperContentBlock(
                id: "B000002",
                text: "In a single week in 2024, liver toxicity signals wiped out $5 billion in market value."
            ),
            AIService.PaperContentBlock(
                id: "B000003",
                text: "The article next examines two of those failed drugs."
            ),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002"],
                spokenText: nil
            ),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(narration.contains("liver toxicity flagged three major drugs"))
        #expect(narration.contains("next examines two of those failed drugs"))
        #expect(!narration.contains("In a single week in 2024"))
    }

    /// Two-column PDF order puts a table between the halves of a sentence
    /// (heard on 2026-09-09: "the number, length, perimeter, This table
    /// compares methods … and area of mitochondria are reduced in disease").
    /// The spoken table waits until the sentence it interrupted has ended.
    @Test("a table read inside a sentence waits until the sentence has ended")
    func tableSummaryInsideASentenceWaitsForTheSentence() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "Mitochondria morphology can be determined by electron microscopy, and the number, length, perimeter,"
            ),
            AIService.PaperContentBlock(
                id: "B000002",
                text: "Table 2 Comparison of methods | Respirometry | Comprehensive"
            ),
            AIService.PaperContentBlock(
                id: "B000003",
                text: "and area of mitochondria are reduced in disease."
            ),
            AIService.PaperContentBlock(
                id: "B000004",
                text: "Impaired mitochondrial morphology correlates with frailty."
            ),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002"],
                spokenText: "This table compares methods for measuring mitochondrial dysfunction."
            ),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        let sentenceEnd = try #require(narration.range(of: "reduced in disease."))
        let summary = try #require(narration.range(of: "This table compares"))
        let nextParagraph = try #require(narration.range(of: "Impaired mitochondrial"))
        #expect(sentenceEnd.upperBound <= summary.lowerBound)
        #expect(summary.upperBound <= nextParagraph.lowerBound)
        #expect(!narration.contains("Table 2 Comparison"))
    }

    @Test("a table after a complete sentence is read in place")
    func tableSummaryAfterASentenceStaysInPlace() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Several methods are compared below."),
            AIService.PaperContentBlock(id: "B000002", text: "Table 1 | Method | Cost"),
            AIService.PaperContentBlock(id: "B000003", text: "Respirometry remains the reference."),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(blockIDs: ["B000002"], spokenText: "This table lists each method and its cost."),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        let summary = try #require(narration.range(of: "This table lists"))
        let following = try #require(narration.range(of: "Respirometry remains"))
        #expect(summary.upperBound <= following.lowerBound)
    }

    @Test("paper narration strips linked numeric and inline author citations without rewriting prose")
    func paperNarrationStripsInlineCitations() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "Aging is a mitochondrial disease1 (Brandt et al)."
            ),
            AIService.PaperContentBlock(
                id: "B000002",
                text: "CO2 increased by 12 percent in 2020."
            ),
        ]
        let response = """
        {"adaptations":[],"removeText":[
          {"blockID":"B000001","exactText":"1","occurrence":1},
          {"blockID":"B000001","exactText":" (Brandt et al)","occurrence":1}
        ]}
        """
        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(narration == "Aging is a mitochondrial disease. CO2 increased by 12 percent in 2020.")
        #expect(!narration.contains("Brandt"))
        #expect(narration.contains("CO2"))
        #expect(narration.contains("12 percent"))
        #expect(narration.contains("2020"))
    }

    @Test("paper speech plan replaces a table with a concise explanation and preserves prose")
    func paperSpeechPlanReconstruction() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "The experiment compared three treatments."),
            AIService.PaperContentBlock(id: "B000002", text: "Table 1. Outcomes by treatment"),
            AIService.PaperContentBlock(id: "B000003", text: "Group Mean SD p"),
            AIService.PaperContentBlock(id: "B000004", text: "A 14.2 3.1 .004"),
            AIService.PaperContentBlock(id: "B000005", text: "B 10.1 2.8 .110"),
            AIService.PaperContentBlock(id: "B000006", text: "The treatment effect remained after adjustment."),
        ]
        let plan = AIService.PaperSpeechAdaptationPlan(adaptations: [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002", "B000003", "B000004", "B000005"],
                spokenText: "Table one compares outcomes across the treatment groups; group A has the strongest result."
            ),
        ])

        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(narration.contains("The experiment compared three treatments."))
        #expect(narration.contains("Table one compares outcomes"))
        #expect(narration.contains("The treatment effect remained after adjustment."))
        #expect(!narration.contains("Group Mean SD p"))
        #expect(!narration.contains("14.2 3.1"))
    }

    @Test("paper speech plan finishes interrupted prose before a boxed sidebar")
    func paperSpeechPlanRelocatesInterruptingSidebar() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "R&D on direct-acting hepatitis C antiviral"
            ),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Antibacterial discovery"),
            AIService.PaperContentBlock(id: "B000003", text: "The box preserves its substantive case study."),
            AIService.PaperContentBlock(
                id: "B000004",
                text: "drugs was impractical until the invention of replicons"
            ),
            AIService.PaperContentBlock(
                id: "B000005",
                text: "that made reliable screening possible."
            ),
        ]
        let response = """
        {"adaptations":[],"relocations":[
          {"blockIDs":["B000002","B000003"],"insertAfterBlockID":"B000005"}
        ],"removeText":[]}
        """
        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)
        let narration = try PaperTextToSpeechPreparationService.reconstruct(
            blocks: blocks,
            applying: plan
        )

        #expect(
            narration.contains(
                "R&D on direct-acting hepatitis C antiviral drugs was impractical until the invention of replicons that made reliable screening possible."
            )
        )
        let paragraph = try #require(narration.range(of: "that made reliable screening possible."))
        let box = try #require(narration.range(of: "Box 1 | Antibacterial discovery"))
        #expect(paragraph.upperBound < box.lowerBound)
        #expect(narration.contains("The box preserves its substantive case study."))
    }

    @Test("paper speech plan rejects backward or self-anchored sidebar moves")
    func paperSpeechRelocationValidation() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Main prose."),
            AIService.PaperContentBlock(id: "B000002", text: "Box heading"),
            AIService.PaperContentBlock(id: "B000003", text: "Box body."),
            AIService.PaperContentBlock(id: "B000004", text: "Main continuation."),
        ]
        let response = """
        {"adaptations":[],"relocations":[
          {"blockIDs":["B000002","B000003"],"insertAfterBlockID":"B000004"},
          {"blockIDs":["B000001"],"insertAfterBlockID":"B000001"},
          {"blockIDs":["B000004"],"insertAfterBlockID":"B000001"},
          {"blockIDs":["B999999"],"insertAfterBlockID":"B000004"}
        ],"removeText":[]}
        """

        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)
        #expect(plan.relocations == [
            AIService.PaperSpeechRelocation(
                blockIDs: ["B000002", "B000003"],
                insertAfterBlockID: "B000004"
            ),
        ])
    }

    @Test("paper speech plan validation rejects unsafe block ranges")
    func paperSpeechPlanValidation() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Prose before."),
            AIService.PaperContentBlock(id: "B000002", text: "Table header"),
            AIService.PaperContentBlock(id: "B000003", text: "Table row"),
            AIService.PaperContentBlock(id: "B000004", text: "Prose after."),
        ]
        let response = """
        {"adaptations":[
          {"blockIDs":["B000002","B000003"],"spokenText":"The table reports one comparison."},
          {"blockIDs":["B000001","B000004"],"spokenText":"Noncontiguous and unsafe."},
          {"blockIDs":["B999999"],"spokenText":"Unknown."},
          {"blockIDs":["B000003"],"spokenText":"Overlapping."}
        ]}
        """

        let plan = try AIService.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)

        #expect(plan.adaptations == [
            AIService.PaperSpeechAdaptation(
                blockIDs: ["B000002", "B000003"],
                spokenText: "The table reports one comparison."
            ),
        ])
    }

    @Test("paper deletion-plan validation conservatively normalizes unsafe entries")
    func paperDeletionPlanValidation() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Authors"),
            AIService.PaperContentBlock(id: "B000002", text: "A result [12] remains."),
            AIService.PaperContentBlock(id: "B000003", text: "References")
        ]
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":["B000001","B000003"],"removeText":[]}"#,
                blocks: blocks
            ).removeBlocks == ["B000001", "B000003"]
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":["B999999"],"removeText":[]}"#,
                blocks: blocks
            ).removeBlocks.isEmpty
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":["B000001","B000001"],"removeText":[]}"#,
                blocks: blocks
            ).removeBlocks == ["B000001"]
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                "```json\n{\"removeBlocks\":[],\"removeText\":[]}\n```",
                blocks: blocks
            ) == .empty
        )
        let oversizedInlineHunk = String(repeating: "x", count: 161)
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                "{\"removeBlocks\":[],\"removeText\":[{\"blockID\":\"B000002\",\"exactText\":\"\(oversizedInlineHunk)\",\"occurrence\":1}]}",
                blocks: blocks
            ).removeText.isEmpty
        )
        #expect(
            try AIService.validatedPaperContentDeletionPlan(
                #"{"removeBlocks":[],"removeText":[{"blockID":"B000002","exactText":" [12]","occurrence":1},{"blockID":"B000002","exactText":"not verbatim","occurrence":1}]}"#,
                blocks: blocks
            ).removeText == [
                AIService.PaperContentTextDeletion(
                    blockID: "B000002",
                    exactText: " [12]",
                    occurrence: 1
                )
            ]
        )
        let relocationPlan = try AIService.validatedPaperContentDeletionPlan(
            #"{"removeBlocks":[],"relocations":[{"blockIDs":["B000002"],"insertAfterBlockID":"B000003"},{"blockIDs":["B000003"],"insertAfterBlockID":"B000001"}],"removeText":[]}"#,
            blocks: blocks
        )
        #expect(relocationPlan.relocations == [
            AIService.PaperSpeechRelocation(
                blockIDs: ["B000002"],
                insertAfterBlockID: "B000003"
            )
        ])

        let boxBlocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Box 1 | Preserved structure"),
            AIService.PaperContentBlock(id: "B000002", text: "Substantive Box body."),
        ]
        let boxPlan = try AIService.validatedPaperContentDeletionPlan(
            #"{"removeBlocks":["B000001"],"relocations":[],"keepInPlaceBoxHeadingIDs":["B000001"],"removeText":[{"blockID":"B000001","exactText":"Box 1 | ","occurrence":1}]}"#,
            blocks: boxBlocks
        )
        #expect(boxPlan.removeBlocks.isEmpty)
        #expect(boxPlan.removeText.isEmpty)
        #expect(boxPlan.keepInPlaceBoxHeadingIDs == ["B000001"])
    }

    @Test("paper deletion diffs remove blocks and exact inline noise without rewriting prose")
    func paperDeletionPlanReconstruction() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "A Useful Paper"),
            AIService.PaperContentBlock(id: "B000002", text: "The abstract [12] remains byte-for-byte."),
            AIService.PaperContentBlock(id: "B000003", text: "The substantive body also remains byte-for-byte."),
            AIService.PaperContentBlock(id: "B000004", text: "Publisher boilerplate")
        ]
        let clean = try PaperContentPreparationService.reconstruct(
            title: "A Useful Paper",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: ["B000001", "B000004"],
                removeText: [
                    AIService.PaperContentTextDeletion(
                        blockID: "B000002",
                        exactText: " [12]",
                        occurrence: 1
                    )
                ]
            )
        )
        #expect(
            clean == "A Useful Paper\n\nThe abstract remains byte-for-byte.\nThe substantive body also remains byte-for-byte."
        )

        let preserved = try PaperContentPreparationService.reconstruct(
            title: "A Useful Paper",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: ["B000001", "B000002", "B000003", "B000004"],
                removeText: []
            )
        )
        #expect(
            preserved == "A Useful Paper\n\nA Useful Paper\nThe abstract [12] remains byte-for-byte.\nThe substantive body also remains byte-for-byte.\nPublisher boilerplate"
        )
        #expect(throws: CanonicalContentCleanupContractError.self) {
            try PaperContentPreparationService.reconstruct(
                title: "A Useful Paper",
                blocks: blocks,
                applying: AIService.PaperContentDeletionPlan(
                    removeBlocks: ["B000001", "B000004"],
                    removeText: [
                        AIService.PaperContentTextDeletion(
                            blockID: "B000002",
                            exactText: "not verbatim",
                            occurrence: 1
                        )
                    ]
                )
            )
        }
    }

    /// The 2026-09-23 Cell paper: a deletion run that starts at References and
    /// runs on through the STAR★Methods printed after them.
    private static let methodsAfterReferencesBlocks = [
        AIService.PaperContentBlock(id: "B000001", text: "Cell 189, 4581–4593, July 23, 2026"),
        AIService.PaperContentBlock(id: "B000002", text: "Treating cells with nocodazole disrupted the microtubule network."),
        AIService.PaperContentBlock(id: "B000003", text: "REFERENCES"),
        AIService.PaperContentBlock(id: "B000004", text: "1. Maritan, M., Autin, L., and Goodsell, D.S. (2022). J. Mol. Biol. 434, 167351."),
        AIService.PaperContentBlock(id: "B000005", text: "KEY RESOURCES TABLE"),
        AIService.PaperContentBlock(id: "B000006", text: "Nocodazole MedChemExpress Cat#HY-13520"),
        AIService.PaperContentBlock(id: "B000007", text: "Cal27 cells were cultured in DMEM with 10% FBS."),
    ]

    @Test("deletion check sees each maximal deleted run with the kept block on either side")
    func deletionAuditRunsCarryTheirKeptNeighbours() {
        let blocks = Self.methodsAfterReferencesBlocks
        let runs = PaperContentPreparationService.deletionAuditRuns(
            blocks: blocks,
            removing: ["B000001", "B000003", "B000004", "B000005", "B000006", "B000007"]
        )
        #expect(runs == [
            AIService.PaperContentDeletionAuditRun(
                keptBefore: nil,
                removed: [blocks[0]],
                keptAfter: blocks[1]
            ),
            AIService.PaperContentDeletionAuditRun(
                keptBefore: blocks[1],
                removed: Array(blocks[2...6]),
                keptAfter: nil
            ),
        ])
        #expect(PaperContentPreparationService.deletionAuditRuns(blocks: blocks, removing: []).isEmpty)
    }

    @Test("deletion check restores only blocks it was shown as deletions")
    func deletionAuditValidation() throws {
        let blocks = Self.methodsAfterReferencesBlocks
        let runs = PaperContentPreparationService.deletionAuditRuns(
            blocks: blocks,
            removing: ["B000003", "B000004", "B000005", "B000006", "B000007"]
        )
        // B000002 is context, never deleted; B000099 was never shown.
        let restored = try AIService.validatedPaperContentDeletionAudit(
            #"{"keepBlocks":["B000005","B000006","B000007","B000002","B000099"]}"#,
            runs: runs
        )
        #expect(restored == ["B000005", "B000006", "B000007"])
        #expect(try AIService.validatedPaperContentDeletionAudit(
            "```json\n{\"keepBlocks\":[]}\n```",
            runs: runs
        ).isEmpty)
        #expect(throws: AIError.self) {
            try AIService.validatedPaperContentDeletionAudit(
                #"{"removeBlocks":["B000003"]}"#,
                runs: runs
            )
        }

        let plan = AIService.PaperContentDeletionPlan(
            removeBlocks: ["B000001", "B000003", "B000004", "B000005", "B000006", "B000007"]
                .filter { !restored.contains($0) },
            removeText: []
        )
        let clean = try PaperContentPreparationService.reconstruct(
            title: "Whole-cell digital twins",
            blocks: blocks,
            applying: plan
        )
        #expect(clean == """
        Whole-cell digital twins

        Treating cells with nocodazole disrupted the microtubule network.
        KEY RESOURCES TABLE
        Nocodazole MedChemExpress Cat#HY-13520
        Cal27 cells were cultured in DMEM with 10% FBS.
        """)
    }

    @Test("deletion check request shows the deletions and their context, and splits only past the window")
    func deletionAuditRequestChunking() throws {
        let blocks = Self.methodsAfterReferencesBlocks
        let runs = PaperContentPreparationService.deletionAuditRuns(
            blocks: blocks,
            removing: ["B000001", "B000003", "B000004", "B000005", "B000006", "B000007"]
        )
        let request = AIService.paperContentDeletionAuditRequest(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: runs,
            chunkIndex: 0,
            chunkCount: 1
        )
        #expect(request.system == Prompts.paperContentDeletionAudit)
        #expect(request.user.contains(#"{"keptBefore":null,"delete":["#))
        #expect(request.user.contains(#""keptAfter":null}"#))
        #expect(request.user.contains("Cat#HY-13520"))

        #expect(try PaperContentPreparationService.deletionAuditRequestChunks(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: runs,
            inputBudget: nil
        ) == [runs])

        let scaffold = AIService.paperContentDeletionAuditRequest(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: [],
            chunkIndex: 999_998,
            chunkCount: 999_999
        ).inputCharacterCount
        let longestRun = AIService.paperContentDeletionAuditSerializedRun(runs[1]).count
        let chunks = try PaperContentPreparationService.deletionAuditRequestChunks(
            sourceTitle: "Whole-cell digital twins",
            sourceType: .paper,
            runs: runs,
            inputBudget: scaffold + longestRun * 3 / 4
        )
        #expect(chunks.count > 1)
        // Every deleted block is still judged, once, in document order.
        #expect(chunks.flatMap { $0.flatMap(\.removed) } == runs.flatMap(\.removed))
        for chunk in chunks {
            let size = AIService.paperContentDeletionAuditRequest(
                sourceTitle: "Whole-cell digital twins",
                sourceType: .paper,
                runs: chunk,
                chunkIndex: 0,
                chunkCount: chunks.count
            ).inputCharacterCount
            #expect(size <= scaffold + longestRun * 3 / 4)
        }
        let parts = chunks.flatMap { $0 }.filter { $0.removed.contains(blocks[2]) || $0.removed.contains(blocks[6]) }
        #expect(parts.first?.keptBefore == blocks[1])
        #expect(parts.last?.keptAfter == nil)
    }

    @Test("cleanup splits only when the complete request exceeds model context")
    func cleanupSplitsOnlyForActualModelContextLimit() throws {
        let blocks = (1...100).map { index in
            AIService.PaperContentBlock(
                id: String(format: "B%06d", index),
                text: String(repeating: "x", count: 800)
            )
        }
        let title = "A long context-aware paper"

        let largeWindowChunks = try PaperContentPreparationService.cleanupRequestChunks(
            system: Prompts.paperNarrationPreparation,
            sourceTitle: title,
            sourceType: .paper,
            blocks: blocks,
            provider: .openai,
            model: "gpt-5.6-luna"
        )
        #expect(largeWindowChunks == [blocks])

        let smallWindowChunks = try PaperContentPreparationService.cleanupRequestChunks(
            system: Prompts.paperNarrationPreparation,
            sourceTitle: title,
            sourceType: .paper,
            blocks: blocks,
            provider: .cerebras,
            model: "llama3.1-8b"
        )
        #expect(smallWindowChunks.count > 1)
        #expect(smallWindowChunks.flatMap { $0 } == blocks)

        let inputBudget = try #require(AIService.inputCharacterBudget(
            provider: .cerebras,
            model: "llama3.1-8b",
            requestedMaxTokens: AIService.paperContentDeletionMaxTokens
        ))
        for (index, chunk) in smallWindowChunks.enumerated() {
            let request = AIService.paperContentDeletionRequest(
                system: Prompts.paperNarrationPreparation,
                sourceTitle: title,
                sourceType: .paper,
                blocks: chunk,
                chunkIndex: index,
                chunkCount: smallWindowChunks.count
            )
            #expect(request.inputCharacterCount <= inputBudget)
        }
    }

    @Test("oversized cleanup requests identify their chunk in usage logs")
    func cleanupChunkUsageTitleIsVisible() {
        #expect(
            AIService.paperContentDeletionUsageTitle(
                sourceTitle: "A Paper",
                chunkIndex: 0,
                chunkCount: 1
            ) == "A Paper"
        )
        #expect(
            AIService.paperContentDeletionUsageTitle(
                sourceTitle: "A Paper",
                chunkIndex: 1,
                chunkCount: 3
            ) == "Chunk 2/3 · A Paper"
        )
        let request = AIService.paperContentDeletionRequest(
            system: Prompts.paperNarrationPreparation,
            sourceTitle: "A Paper",
            sourceType: .paper,
            blocks: [AIService.PaperContentBlock(id: "B000001", text: "Body")],
            chunkIndex: 1,
            chunkCount: 3
        )
        #expect(request.user.contains("This is Chunk 2/3"))
    }

    @Test("canonical cleanup finishes Scannell main prose before Box 1")
    func canonicalCleanupRelocatesScannellBoxAfterInterruptedParagraph() throws {
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000346",
                text: "R&D on direct-acting hepatitis C antiviral"
            ),
            AIService.PaperContentBlock(
                id: "B000347",
                text: "Box 1 | 1930s decision tool quality beat 1990s decision tool quantity in antibacterials"
            ),
            AIService.PaperContentBlock(
                id: "B000348",
                text: "Domagk tested drug candidates against Streptococcus haemolyticus."
            ),
            AIService.PaperContentBlock(
                id: "B000449",
                text: "The box concludes with the consequences for antibacterial screening."
            ),
            AIService.PaperContentBlock(
                id: "B000452",
                text: "drugs was impractical until the invention of replicons that made reliable screening possible."
            ),
            AIService.PaperContentBlock(
                id: "B000453",
                text: "The next main-text paragraph starts here."
            ),
        ]
        let response = """
        {"removeBlocks":[],"relocations":[
          {"blockIDs":["B000347","B000348","B000449"],"insertAfterBlockID":"B000452"}
        ],"removeText":[]}
        """
        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        let clean = try PaperContentPreparationService.reconstruct(
            title: "Predictive validity in drug discovery: what it is, why it matters and how to improve it",
            blocks: blocks,
            applying: plan
        )

        let completedParagraph = try #require(
            clean.range(of: "R&D on direct-acting hepatitis C antiviral\ndrugs was impractical")
        )
        let box = try #require(clean.range(of: "Box 1 |"))
        let nextParagraph = try #require(clean.range(of: "The next main-text paragraph"))
        #expect(completedParagraph.upperBound < box.lowerBound)
        #expect(box.lowerBound < nextParagraph.lowerBound)
        #expect(clean.contains("Domagk tested drug candidates"))
    }

    @Test("compact sidebar boundaries expand to the complete exact box interval")
    func compactSidebarBoundariesExpandDeterministically() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Main fragment"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Case study"),
            AIService.PaperContentBlock(id: "B000003", text: "Complete box body"),
            AIService.PaperContentBlock(id: "B000004", text: "main prose resumes here"),
            AIService.PaperContentBlock(id: "B000005", text: "and finishes here."),
        ]
        let response = """
        {"removeBlocks":[],"relocations":[{
          "blockIDs":["B000002"],
          "resumeAtBlockID":"B000004",
          "insertAfterBlockID":"B000005"
        }],"removeText":[]}
        """

        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.relocations == [
            AIService.PaperSpeechRelocation(
                blockIDs: ["B000002", "B000003"],
                insertAfterBlockID: "B000005"
            )
        ])
    }

    @Test("Box relocation survives deletion of noise inside its exact range")
    func compactSidebarRelocationCanContainRemovedNoise() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "R&D on direct-acting hepatitis C antiviral"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Antibacterial discovery"),
            AIService.PaperContentBlock(id: "B000003", text: "Downloaded from publisher header"),
            AIService.PaperContentBlock(id: "B000004", text: "Substantive Box body."),
            AIService.PaperContentBlock(id: "B000005", text: "drugs was impractical until replicons existed."),
        ]
        let response = """
        {"removeBlocks":["B000003"],"relocations":[{
          "blockIDs":["B000002"],
          "resumeAtBlockID":"B000005",
          "insertAfterBlockID":"B000005"
        }],"removeText":[]}
        """

        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.relocations.first?.blockIDs == ["B000002", "B000003", "B000004"])
        let clean = try PaperContentPreparationService.reconstruct(
            title: "Predictive validity",
            blocks: blocks,
            applying: plan
        )
        #expect(clean.contains("antiviral\ndrugs was impractical until replicons existed.\nBox 1"))
        #expect(!clean.contains("Downloaded from publisher header"))
        #expect(clean.contains("Substantive Box body."))
    }

    @Test("compact sidebar cleanup rejects a body-line start")
    func compactSidebarCleanupRejectsBodyLineStart() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "Main fragment"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Case study"),
            AIService.PaperContentBlock(id: "B000003", text: "Box body"),
            AIService.PaperContentBlock(id: "B000004", text: "main prose resumes"),
            AIService.PaperContentBlock(id: "B000005", text: "and finishes."),
        ]
        let response = #"{"removeBlocks":[],"relocations":[{"blockIDs":["B000003"],"resumeAtBlockID":"B000004","insertAfterBlockID":"B000005"}],"removeText":[]}"#
        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.relocations.isEmpty)
    }

    @Test("full-document cleanup explicitly classifies every Box without punctuation guesses")
    func fullDocumentCleanupClassifiesEveryBoxSemantically() throws {
        let blocks = [
            AIService.PaperContentBlock(id: "B000001", text: "causal relationship between target and disease)"),
            AIService.PaperContentBlock(id: "B000002", text: "Box 1 | Complete bullet follows"),
            AIService.PaperContentBlock(id: "B000003", text: "Substantive first Box body."),
            AIService.PaperContentBlock(id: "B000004", text: "The next main-text paragraph."),
            AIService.PaperContentBlock(id: "B000005", text: "attributes of being complete, consistent,"),
            AIService.PaperContentBlock(id: "B000006", text: "Box 2 | Interrupting sidebar"),
            AIService.PaperContentBlock(id: "B000007", text: "Substantive second Box body."),
            AIService.PaperContentBlock(id: "B000008", text: "enduring and available."),
            AIService.PaperContentBlock(id: "B000009", text: "volume 20 | January 2021 | 69"),
            AIService.PaperContentBlock(id: "B000010", text: "Box 3 | Follows a page header"),
        ]

        #expect(
            PaperContentPreparationService.sidebarHeadingIDs(in: blocks)
                == Set(["B000002", "B000006", "B000010"])
        )
        let response = """
        {"removeBlocks":[],"relocations":[{
          "blockIDs":["B000006"],
          "resumeAtBlockID":"B000008",
          "insertAfterBlockID":"B000008"
        }],"keepInPlaceBoxHeadingIDs":["B000002","B000010"],"removeText":[]}
        """
        let plan = try AIService.validatedPaperContentDeletionPlan(response, blocks: blocks)
        #expect(plan.keepInPlaceBoxHeadingIDs == ["B000002", "B000010"])
        try PaperContentPreparationService.validateSidebarDecisions(
            in: blocks,
            applying: plan
        )

        let omittedDecision = try AIService.validatedPaperContentDeletionPlan(
            response.replacingOccurrences(
                of: #""B000002","B000010""#,
                with: #""B000002""#
            ),
            blocks: blocks
        )
        #expect(throws: AIError.self) {
            try PaperContentPreparationService.validateSidebarDecisions(
                in: blocks,
                applying: omittedDecision
            )
        }

        let contradictoryDecision = try AIService.validatedPaperContentDeletionPlan(
            response.replacingOccurrences(
                of: #""B000002","B000010""#,
                with: #""B000002","B000006","B000010""#
            ),
            blocks: blocks
        )
        #expect(throws: AIError.self) {
            try PaperContentPreparationService.validateSidebarDecisions(
                in: blocks,
                applying: contradictoryDecision
            )
        }
    }

    @Test("article cleanup allows boilerplate-heavy web pages")
    func articleCleanupAllowsBoilerplateHeavyWebPages() throws {
        var blocks: [AIService.PaperContentBlock] = []
        var removeBlocks: [String] = []
        for index in 1...80 {
            let id = String(format: "B%06d", index)
            blocks.append(
                AIService.PaperContentBlock(
                    id: id,
                    text: "Patreon navigation, subscription prompt, related links, footer, and site chrome \(index)."
                )
            )
            removeBlocks.append(id)
        }
        blocks.append(
            AIService.PaperContentBlock(
                id: "B000081",
                text: "Preparatory notes for a manifesto begin with an actual substantive claim about the notebook, its audience, and why the argument matters."
            )
        )
        blocks.append(
            AIService.PaperContentBlock(
                id: "B000082",
                text: "The next note develops the premise in concrete terms, preserving the source prose exactly instead of summarizing or rewriting it."
            )
        )

        let clean = try PaperContentPreparationService.reconstruct(
            title: "Preparatory notes for a manifesto | Patreon",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: removeBlocks,
                removeText: []
            )
        )

        #expect(clean.contains("Preparatory notes for a manifesto begin"))
        #expect(clean.contains("The next note develops the premise"))
        #expect(!clean.contains("Patreon navigation"))
    }

    /// The stored extraction of a locked Patreon post, verbatim: 29 lines of
    /// navigation, counters, and subscription prompts around a single 143-character
    /// teaser. Cleanup removed exactly the right 29 lines and was still rejected,
    /// because an absolute retained-character floor cannot be satisfied by a page
    /// that never contained more body than this.
    @Test("article cleanup keeps a paywall teaser shorter than any absolute floor")
    func articleCleanupKeepsShortPaywallTeaser() throws {
        let joinPrompt = """
            To access this whole post, join Patreon today. When you become a member, \
            you get instant access to exclusive posts and benefits.
            """
        let noise: [String] = [
            "Preparatory notes for a manifesto | Patreon", "Skip navigation",
            "Home", "Posts", "Collections", "Membership",
            "Home", "Posts", "Collections", "Membership",
            "Become a member", "Preparatory notes for a manifesto",
            "Andy Matuschak", "May 31, 2025", "New", "Join to unlock",
            "45", "9", "Share", "Locked", joinPrompt,
            "Join to unlock", "45", "9", "Share", "Locked",
            "Andy Matuschak", "Creating tools for thought", "Become a member"
        ]
        let teaser = """
            A personal note: a long book project has eaten up my weeks, and I've \
            been quite distracted these past few weeks
            """
        var blocks: [AIService.PaperContentBlock] = []
        var removeBlocks: [String] = []
        for (offset, text) in noise.enumerated() {
            let id = String(format: "B%06d", offset + 1)
            blocks.append(AIService.PaperContentBlock(id: id, text: text))
            removeBlocks.append(id)
        }
        // Insert the teaser where the extraction has it, after "Locked".
        blocks.insert(
            AIService.PaperContentBlock(id: "B000999", text: teaser),
            at: 20
        )

        let clean = try PaperContentPreparationService.reconstruct(
            title: "Preparatory notes for a manifesto | Patreon",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: removeBlocks,
                removeText: []
            )
        )

        #expect(clean.hasSuffix(teaser))
        #expect(!clean.contains("Join to unlock"))
        #expect(!clean.contains("Skip navigation"))
    }

    @Test("cleanup does not judge a valid deletion plan by retained character ratio")
    func cleanupHasNoRetainedCharacterRatioHeuristic() throws {
        var blocks: [AIService.PaperContentBlock] = []
        var removeBlocks: [String] = []
        for index in 1...400 {
            let id = String(format: "B%06d", index)
            blocks.append(
                AIService.PaperContentBlock(
                    id: id,
                    text: "Model-classified removable source text in block \(index)."
                )
            )
            removeBlocks.append(id)
        }
        blocks.append(
            AIService.PaperContentBlock(id: "B000401", text: "One retained sentence.")
        )

        let clean = try PaperContentPreparationService.reconstruct(
            title: "A Long Source",
            blocks: blocks,
            applying: AIService.PaperContentDeletionPlan(
                removeBlocks: removeBlocks,
                removeText: []
            )
        )

        #expect(clean == "A Long Source\n\nOne retained sentence.")
    }

    @Test("cleanup deletion units preserve every nonempty extracted line")
    func paperCleanupUsesPhysicalLines() {
        let blocks = PaperContentPreparationService.semanticBlocks(
            "Publisher header\nAging involves a real result.\nThe result continues here.\n\nReferences"
        )
        #expect(blocks.map(\.text) == [
            "Publisher header",
            "Aging involves a real result.",
            "The result continues here.",
            "References"
        ])
    }

    /// Dario Amodei's "The Adolescence of Technology" (2026-10-06): both
    /// prompts listed endnotes as noise, and a cleanup deleted the essay's 46
    /// footnotes of the author's own commentary.
    @Test("cleanup keeps footnotes in the author's words and drops only notes that just cite")
    func cleanupPromptsKeepProseNotes() {
        for prompt in [Prompts.paperNarrationPreparation, Prompts.paperContentDeletionAudit] {
            #expect(prompt.contains("does nothing but cite a source"))
            #expect(!prompt.contains("entries or endnotes"))
            #expect(!prompt.contains(", an endnote,"))
        }
        #expect(Prompts.paperNarrationPreparation.contains("Keep every footnote and endnote written in the author's own words"))
        #expect(Prompts.paperContentDeletionAudit.contains("footnotes and endnotes written in the author's own words"))
    }

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
    /// the same slug, on OpenRouter's speech endpoint through the proxy.
    @Test("Gemini narration goes to OpenRouter's speech endpoint")
    func mobileCloudNarrationUsesOpenRouterSpeechRoute() throws {
        // The balance's routes; a key in the developer's Keychain would move them.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
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

        #expect(request.url?.host == "ai.foreverlm.com")
        #expect(request.url?.path == "/v1/proxy/openrouter/api/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "X-ForeverLM-Task") == "read_aloud")
        let encodedTitle = try #require(request.value(forHTTPHeaderField: "X-ForeverLM-Source-Title"))
        #expect(encodedTitle.removingPercentEncoding == "Learning — 100%")

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
        // The balance's routes; a key in the developer's Keychain would move them.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
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

        #expect(request.url?.host == "ai.foreverlm.com")
        #expect(request.url?.path == "/v1/proxy/openrouter/api/v1/audio/speech")
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
        // The balance's routes; a key in the developer's Keychain would move them.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
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

        #expect(request.url?.host == "ai.foreverlm.com")
        #expect(request.url?.path == "/v1/proxy/openrouter/api/v1/audio/speech")
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
            "canopylabs/orpheus-3b-0.1-ft", "google/gemini-3.1-flash-tts-preview", "acme/new-voice",
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
        #expect(gemini.responseFormat == .pcm)
        #expect(gemini.maker == "Google")

        // OpenRouter lists no voices for Fish Audio; the voice its model page
        // plays is the one recorded, so the model still takes a voice.
        let fish = try #require(options.first { $0.id == "fish-audio/s2.1-pro" })
        #expect(fish.voices.map(\.id) == ArticleSpeechCatalog.fishS21Voices.map(\.id))

        // Seed Audio lists none and nothing names one: the request leaves
        // `voice` out, and its unit size keeps under its two-minute cap.
        let seed = try #require(options.first { $0.id == "bytedance-seed/seed-audio-1-0" })
        #expect(!seed.takesVoice)
        #expect(seed.summary.hasPrefix(ArticleSpeechCatalog.providerDefaultVoiceName))
        #expect(seed.chunkLimit == ArticleSpeechCatalog.seedAudioChunkLimit)
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
            "fish-audio/s2.1-pro",                  // $15 / 1M UTF-8 bytes
            "deepgram/aura-2",                      // $30 / 1M characters
            "google/gemini-3.1-flash-tts-preview",  // tokens: no per-character rate
            "acme/new-voice",                       // unpriced
            "bytedance-seed/seed-audio-1-0",        // per minute of audio
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
        func manifest(model: String) -> SyncedArticleAudioManifest {
            SyncedArticleAudioManifest(
                schemaVersion: SyncedArticleAudioManifest.schemaVersion,
                sourceID: "article-1",
                title: "An article",
                subtitle: nil,
                sourceType: "article",
                sourceURL: "https://example.com/article",
                provider: ArticleSpeechCatalog.provider,
                model: model,
                voice: "Kore",
                voiceLabel: "Kore",
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
    }
}
