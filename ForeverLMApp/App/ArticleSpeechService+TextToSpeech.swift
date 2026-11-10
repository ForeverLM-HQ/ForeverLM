// Starting text to speech and generating audio for a source.
#if os(macOS)
import Foundation
import SwiftUI

extension ArticleSpeechService {
    /// UI entry point. It publishes preparation state in the button's action
    /// turn, then performs the asynchronous source and TTS work. Keeping that
    /// first state transition out of an unstructured Task prevents a Listen
    /// click from looking ignored while the task waits to be scheduled.
    func startTextToSpeech(article: StudioArticle) {
        guard let requestID = beginTextToSpeech(article: article) else { return }
        Task { [weak self] in
            await self?.continueTextToSpeech(article: article, requestID: requestID)
        }
    }

    /// Async compatibility for automatic chapter continuation and existing
    /// non-UI callers. UI controls should call `startTextToSpeech` directly.
    func textToSpeech(article: StudioArticle) async {
        guard let requestID = beginTextToSpeech(article: article) else { return }
        await continueTextToSpeech(article: article, requestID: requestID)
    }

    func beginTextToSpeech(article: StudioArticle) -> UUID? {
        refreshConfiguration()
        // Switching sources must not throw away in-flight generation work:
        // detach it so the previous source keeps generating in the background.
        stop(detachingGeneration: true)
        // A fresh generation for this source supersedes any background one
        // still running for it. Cancel without deleting partial audio — the
        // new generation reuses those chunks via the per-request cache.
        cancelBackgroundGeneration(sourceID: article.id, cleaningUpPartialAudio: false)
        finishedListeningArticleID = nil
        languageNotice = nil
        activeAppleVoiceIdentifier = nil
        // An approved book price covers that book only. Leaving it — to another
        // book, or to any single source — makes the next paid generation ask
        // again.
        if approvedBookGeneration?.groupID != article.parentGroup {
            approvedBookGeneration = nil
        }

        guard ArticleSpeechContent.canAttemptRead(article) else {
            if article.sourceType == .podcast {
                errorMessage = "Podcasts already have native audio, so ForeverLM does not generate text-to-speech speech for them."
            } else if article.isYouTubeURL {
                errorMessage = "YouTube videos already have native audio, so ForeverLM does not generate text-to-speech speech for them."
            } else if article.sourceType == .meeting, ArticleSpeechContent.isOriginalAudioSource(article) {
                errorMessage = "This meeting's recording plays in the reader, so ForeverLM does not generate text-to-speech speech for it."
            } else {
                errorMessage = "This source does not have readable text yet."
            }
            ArticleSpeechDiagnostics.append(
                "LISTEN_REJECTED source=\(article.id) type=\(article.sourceType.rawValue)"
            )
            return nil
        }

        let requestID = UUID()
        preparationRequestID = requestID
        preparingArticleID = article.id
        nowPlayingTitle = article.title
        nowPlayingSubtitle = displaySubtitle(for: article)
        loadNowPlayingArtwork(for: article)
        isLoading = true
        preparationStatus = "Preparing text…"
        errorMessage = nil
        // Every Listen click leaves a trace here. A click that ends in silence
        // is the one failure this service cannot explain after the fact, so the
        // request, and each way it can end early, is written to the log.
        ArticleSpeechDiagnostics.append(
            "LISTEN_REQUESTED source=\(article.id) type=\(article.sourceType.rawValue)"
        )
        return requestID
    }

    private func continueTextToSpeech(article: StudioArticle, requestID: UUID) async {
        // The synchronous entry point may run inside a SwiftUI button update.
        // Yield before subsequent publications while preserving the immediate
        // preparation state it already set.
        await Task.yield()

        let content = await ArticleSpeechContent.text(for: article)

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=text source=\(article.id)")
            return
        }

        guard let content else {
            preparingArticleID = nil
            isLoading = false
            preparationStatus = nil
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            errorMessage = "This source does not have readable text yet."
            ArticleSpeechDiagnostics.append("LISTEN_FAILED stage=text source=\(article.id) no readable text")
            return
        }

        let isPaper = article.sourceType == .paper
        preparationStatus = article.sourceType == .book
            ? "Preparing audio…"
            : "Preparing narration…"
        let listenablePlayback: PreparedListenablePlayback
        do {
            listenablePlayback = try await prepareListenablePlayback(
                for: article,
                initialContent: content,
                learnerAsked: true
            )
        } catch {
            guard preparationRequestID == requestID,
                  preparingArticleID == article.id else {
                ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=narration source=\(article.id)")
                return
            }
            preparingArticleID = nil
            isLoading = false
            preparationStatus = nil
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            let kind = isPaper ? "paper" : "source"
            errorMessage = "Could not prepare this \(kind) for reading aloud: \(error.localizedDescription)"
            articleSpeechLogger.error(
                "Listen preparation failed for \(article.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            ArticleSpeechDiagnostics.append(
                "LISTEN_FAILED stage=narration source=\(article.id) \(error.localizedDescription)"
            )
            return
        }

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=prepared source=\(article.id)")
            return
        }
        preparationStatus = "Preparing audio…"

        // Which voice reads this source is settled before it is chunked: a
        // source in another language can need a different model, and chunk
        // sizes, cache keys, and the price quoted below all follow the model
        // that will actually synthesize it.
        let provider = mode
        let sourceID = article.id
        let selection = await resolveSpeechSelection(
            provider: provider,
            content: listenablePlayback.content,
            sourceID: sourceID
        )

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=language source=\(article.id)")
            return
        }

        // Generation 2: narration another device made is laid into the working folder, chunks and all,
        // before the cache is probed, or the audio the account already owns would be made again.
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: sourceID)
        // Narration cleanup, chunking, and cache probing all run over large
        // strings and stat files in the iCloud-synced Audio folder — strictly
        // off the main actor. The main actor only publishes the result.
        let accountPosition = await accountListenPosition(sourceID: sourceID)
        let preparation = await Task.detached(priority: .userInitiated) {
            Self.preparePlayback(
                sourceID: sourceID,
                content: listenablePlayback.content,
                provider: provider,
                model: selection.model,
                voice: selection.voice,
                isPaper: isPaper,
                sourceContentSignature: listenablePlayback.sourceContentSignature,
                narrationPreparationSignature: listenablePlayback.narrationPreparationSignature,
                accountPosition: accountPosition
            )
        }.value

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=chunking source=\(article.id)")
            return
        }

        // A language no available voice speaks is asked about before the price
        // is: an unlistenable narration is not worth any amount of money.
        let willGenerate = provider.isCloudProvider
            && preparation.manifest == nil
            && preparation.uncachedCharacterCount > 0
        guard acceptLanguageResolution(selection, article: article, isBillable: willGenerate) else {
            languageNotice = nil
            preparingArticleID = nil
            isLoading = false
            preparationStatus = nil
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            return
        }
        activeAppleVoiceIdentifier = selection.appleVoiceIdentifier
        // The alert above spins a nested run loop; another source may have
        // taken over preparation while it was up.
        guard preparationRequestID == requestID,
              preparingArticleID == article.id else { return }

        // Paid generation is a choice, not a surprise: before any billable TTS
        // request goes out, show what it will roughly cost and let the user
        // back out. Fully cached sources and free providers skip the ask.
        //
        // A book is priced as a book. Listening auto-advances into the next
        // chapter, so starting chapter one commits to the whole book, and
        // quoting only the chapter in hand would understate that by orders of
        // magnitude. The listener approves the book once and is not asked again
        // at every chapter break.
        if willGenerate, MacArticleSpeechSettings.confirmsCostBeforeListening(for: preparation.model) {
            let approval = (article.sourceType == .book ? article.parentGroup : nil).map {
                BookGenerationApproval(
                    groupID: $0,
                    signature: "\(preparation.model)\u{1f}\(preparation.voice)"
                )
            }
            if approval == nil || approval != approvedBookGeneration {
                let book = await bookGenerationEstimate(
                    for: article,
                    provider: provider,
                    model: preparation.model,
                    narrationCharacters: preparation.narrationText.count
                )
                guard preparationRequestID == requestID,
                      preparingArticleID == article.id else { return }
                let approved = Self.confirmGenerationCost(
                    provider: provider,
                    model: preparation.model,
                    uncachedCharacters: preparation.uncachedCharacterCount,
                    book: book
                )
                // The modal alert spins a nested run loop; re-check that no other
                // source took over playback preparation while it was up.
                guard preparationRequestID == requestID,
                      preparingArticleID == article.id else { return }
                guard approved else {
                    preparingArticleID = nil
                    isLoading = false
                    preparationStatus = nil
                    nowPlayingTitle = nil
                    nowPlayingSubtitle = nil
                    return
                }
                approvedBookGeneration = approval
            }
        }

        preparingArticleID = nil
        preparationStatus = nil

        startPlayback(article: article, preparation: preparation, provider: provider)
    }

    /// Generates and syncs a source's complete text-to-speech audio without
    /// starting playback or interrupting whatever the listener is hearing.
    ///
    /// `.interactive` asks the listener about cost and language with alerts, as
    /// the sidebar action always has. `.headless` never blocks on a dialog: a
    /// billable run the caller has not approved returns `.needsCostApproval`
    /// with the exact quote, and a source in a language no voice speaks
    /// returns `.unsupportedLanguage` unless the caller allowed it.
    func generateAudio(
        article: StudioArticle,
        interaction: ArticleSpeechGenerationInteraction = .interactive
    ) async -> ArticleSpeechGenerationRequestResult {
        let result = await generateAudioRun(article: article, interaction: interaction)
        // A run that started shows its progress from here; any other end
        // leaves no stage behind.
        if case .started = result {} else { narrationStages[article.id] = nil }
        return result
    }

    private func setNarrationStage(_ stage: String, for sourceID: String) {
        // A source already generating keeps its own run's line.
        guard !backgroundGenerationSourceIDs.contains(sourceID) else { return }
        narrationStages[sourceID] = stage
    }

    private func generateAudioRun(
        article: StudioArticle,
        interaction: ArticleSpeechGenerationInteraction
    ) async -> ArticleSpeechGenerationRequestResult {
        guard ArticleSpeechContent.canAttemptRead(article) else {
            return .failed("This source does not have readable text yet.")
        }

        let provider = MacArticleSpeechSettings.provider
        guard provider.isCloudProvider else {
            return .failed("Choose a file-generating voice in Text-to-Speech settings first.")
        }

        if backgroundGenerationSourceIDs.contains(article.id)
            || activeArticleID == article.id
            || preparingArticleID == article.id {
            return .alreadyGenerating
        }

        setNarrationStage("Reading the text", for: article.id)
        guard let content = await ArticleSpeechContent.text(for: article) else {
            return .failed("This source does not have readable text yet.")
        }

        setNarrationStage(
            TextToSpeechPreparationPolicy.usesAIPreparation(
                sourceType: article.sourceType.rawValue,
                url: article.url
            ) ? "Cleaning up the text for easier listening" : "Preparing the text",
            for: article.id
        )
        let listenablePlayback: PreparedListenablePlayback
        do {
            listenablePlayback = try await prepareListenablePlayback(
                for: article,
                initialContent: content,
                learnerAsked: interaction == .interactive
            )
        } catch {
            return .failed("Could not prepare this source for audio: \(error.localizedDescription)")
        }

        let sourceID = article.id
        let isPaper = article.sourceType == .paper
        setNarrationStage("Choosing the voice", for: sourceID)
        let selection = await resolveSpeechSelection(
            provider: provider,
            content: listenablePlayback.content,
            sourceID: sourceID
        )
        setNarrationStage("Splitting the text into parts", for: sourceID)
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: sourceID)
        let accountPosition = await accountListenPosition(sourceID: sourceID)
        let preparation = await Task.detached(priority: .userInitiated) {
            Self.preparePlayback(
                sourceID: sourceID,
                content: listenablePlayback.content,
                provider: provider,
                model: selection.model,
                voice: selection.voice,
                isPaper: isPaper,
                sourceContentSignature: listenablePlayback.sourceContentSignature,
                narrationPreparationSignature: listenablePlayback.narrationPreparationSignature,
                accountPosition: accountPosition
            )
        }.value

        guard preparation.speakableText != nil, !preparation.chunks.isEmpty else {
            return .failed("This source does not have readable text yet.")
        }

        if preparation.manifest != nil {
            await Task.detached(priority: .utility) {
                ArticleSpeechAudioCache.markCached(articleID: article.id)
            }.value
            return .alreadyReady
        }

        let isBillable = preparation.uncachedCharacterCount > 0
        switch interaction {
        case .interactive:
            guard acceptLanguageResolution(
                selection,
                article: article,
                isBillable: isBillable,
                showsNotice: false
            ) else { return .cancelled }

            if isBillable,
               MacArticleSpeechSettings.confirmsCostBeforeListening(for: preparation.model) {
                setNarrationStage("Waiting for your OK on the price", for: article.id)
                let approved = Self.confirmGenerationCost(
                    provider: provider,
                    model: preparation.model,
                    uncachedCharacters: preparation.uncachedCharacterCount
                )
                guard approved else { return .cancelled }
            }
        case .headless(let costApproved, let allowsUnsupportedLanguage):
            if isBillable,
               selection.unnarratableLanguage != nil,
               let message = selection.notice?.message,
               !allowsUnsupportedLanguage {
                return .unsupportedLanguage(message)
            }
            // The in-app "don't ask again for this model" switch is the
            // listener's answer for their own clicks. A caller with no one at
            // the Mac gets the quote every time and answers it explicitly.
            if isBillable, !costApproved {
                return .needsCostApproval(
                    ArticleSpeechCostEstimate(
                        characters: preparation.uncachedCharacterCount,
                        provider: provider.rawValue,
                        model: preparation.model
                    ),
                    model: preparation.model
                )
            }
        }

        // Re-check after the confirmation's nested run loop: a reader or a
        // second menu action may have started this source while it was open.
        if backgroundGenerationSourceIDs.contains(article.id)
            || activeArticleID == article.id
            || preparingArticleID == article.id {
            return .alreadyGenerating
        }

        let context = SyncedArticleAudioContext(
            sourceID: article.id,
            title: article.title,
            subtitle: displaySubtitle(for: article),
            sourceType: article.sourceType.rawValue,
            sourceURL: article.url,
            provider: provider,
            model: preparation.model,
            voice: preparation.voice,
            voiceLabel: providerVoiceLabel(
                provider: provider,
                voice: preparation.voice,
                model: preparation.model
            ),
            contentSignature: preparation.contentSignature,
            sourceContentSignature: preparation.sourceContentSignature,
            narrationPreparationSignature: preparation.narrationPreparationSignature,
            totalCharacters: preparation.narrationText.count,
            sourceText: preparation.narrationText,
            fileExtension: Self.syncedAudioFileExtension(provider: provider, model: preparation.model),
            createdAt: Date()
        )

        // One background writer per source. Existing partial chunks remain on
        // disk and in the request cache, so a restart reuses them without a
        // second provider charge.
        cancelBackgroundGeneration(sourceID: article.id, cleaningUpPartialAudio: false)
        let generationID = UUID()
        detachedGenerations[generationID] = DetachedAudioGeneration(
            context: context,
            chunkTexts: preparation.chunks,
            tasks: [:],
            completedChunks: [],
            failedChunkCount: 0,
            hasScheduledRemainingChunks: true
        )
        backgroundGenerationSourceIDs.insert(article.id)
        backgroundGenerationProgress[article.id] = ArticleSpeechChunkProgress(
            completedChunks: 0,
            totalChunks: preparation.chunks.count
        )
        narrationStages[article.id] = "Generating audio, \(preparation.chunks.count) part\(preparation.chunks.count == 1 ? "" : "s")"
        fillMissingDetachedChunkTasks(generationID: generationID)
        articleSpeechLogger.info(
            "Background text-to-speech generation started: \(preparation.chunks.count) chunks for \(article.id)"
        )
        ArticleSpeechDiagnostics.append(
            "BACKGROUND_GENERATION_STARTED source=\(article.id) chunks=\(preparation.chunks.count)"
        )
        return .started
    }
}
#endif
