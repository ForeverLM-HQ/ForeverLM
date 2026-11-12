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
            for: AIError.apiError("Your ForeverLM AI balance is empty — top up in Settings to continue.")
        )
        #expect(proxyFailure == PaperContentPreparationService.contentCleanupCreditsPausedMessage)

        // A row that stored the service sentence behind the pipeline's stage
        // prefix reads as the paused sentence too.
        let wrappedServiceWording =
            "Article ingestion failed during Source Content Cleanup: Your ForeverLM AI balance is empty — top up in Settings to continue."
        #expect(
            PaperContentPreparationService.articleCreditsMessage(for: wrappedServiceWording)
                == PaperContentPreparationService.contentCleanupCreditsPausedMessage
        )
        #expect(PaperContentPreparationService.isEmptyBalanceFailure(wrappedServiceWording))

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
}

