// Narration that plays at once and is kept as it is made.
#if os(macOS)
import AVFoundation
import Foundation
import SwiftUI

extension ArticleSpeechService {
    // MARK: - Narration: play at once, keep it as it is made

    /// The Listen entry point. Listen on a source with no narration asks the
    /// price and starts playing as soon as the opening parts land, while the
    /// rest are made ahead of the playhead and kept (product owner, 2026-10-08: a
    /// narration that took 30 minutes to make before a word played "has to be
    /// sub one minute"; making the whole narration before playing is unusable
    /// with a model that takes a minute a part). Listen on one that
    /// has it plays it. A run already being made in the background (the
    /// source's Generate Audio, an assistant's queue) is waited for.
    ///
    /// The Reader's control knows whether the narration is there and says so
    /// in `hasNarration`; a caller that does not (a context menu) leaves it
    /// nil and the check runs off the main actor first.
    func listen(to article: StudioArticle, hasNarration: Bool? = nil) {
        guard let hasNarration else {
            let sourceID = article.id
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    ArticleSpeechAudioCache.hasCachedAudio(sourceID: sourceID)
                }.value
                self?.listen(to: article, hasNarration: found)
            }
            return
        }
        let state = SourceNarrationState(
            hasNarration: hasNarration,
            isMaking: isMakingNarration(article.id),
            progress: backgroundGenerationProgress[article.id]
        )
        switch state.listenAction() {
        case .play:
            startTextToSpeech(article: article)
        case .wait:
            break
        }
    }

    /// Whether a narration for the source is being made, however it was asked
    /// for: Listen, the source's Generate Audio, an assistant's
    /// `generate_source_audio`, or automatic audio. The queue's own entries
    /// (`SourceAudioGenerationQueue.activeSourceIDs`) are the caller's to add,
    /// since a source waiting its turn there has no run yet.
    func isMakingNarration(_ sourceID: String) -> Bool {
        narrationRequests.contains(sourceID) || backgroundGenerationSourceIDs.contains(sourceID)
    }

    /// Stop on a narration being made: the run, the source's place in the
    /// assistant queue, and the request that would have played it.
    func stopMakingNarration(sourceID: String) {
        narrationRequests.cancel(sourceID)
        if SourceAudioGenerationQueue.shared.activeSourceIDs.contains(sourceID) {
            _ = SourceAudioGenerationQueue.shared.cancel(sourceIDs: [sourceID])
        }
        // A stop keeps what finished: starting again asks for only the parts
        // that are missing, never the hundred that landed.
        cancelBackgroundGeneration(sourceID: sourceID, cleaningUpPartialAudio: false)
    }

    /// The control showing the source takes the finished narration, once, and
    /// plays it.
    func consumeMadeNarration(sourceID: String) -> Bool {
        guard madeNarrationSourceID == sourceID else { return false }
        madeNarrationSourceID = nil
        return true
    }

    /// Every background run ends here: the queue's hook, the progress the
    /// Reader and the rows show, and a narration Listen made.
    func noteBackgroundGenerationEnded(
        sourceID: String,
        outcome: ArticleSpeechBackgroundGenerationOutcome
    ) {
        backgroundGenerationProgress[sourceID] = nil
        narrationStages[sourceID] = nil
        if narrationRequests.end(sourceID, outcome: outcome) {
            madeNarrationSourceID = sourceID
        }
        backgroundGenerationDidEnd?(sourceID, outcome)
    }

    /// Builds a source-bound narration snapshot. A cleanup or CloudKit update
    /// can legitimately replace canonical text while preparation is in flight;
    /// refresh once and prepare the new snapshot instead of surfacing that race
    /// as a text-to-speech error. A second change still fails loudly and remains
    /// queued for the durable background preparer.
    ///
    /// `learnerAsked` is true for Listen and the sidebar's Generate Audio: a
    /// Text-to-Speech Preparation the learner stopped in the background-work
    /// list still runs for a source they asked to hear.
    func prepareListenablePlayback(
        for article: StudioArticle,
        initialContent: String,
        learnerAsked: Bool
    ) async throws -> PreparedListenablePlayback {
        var content = initialContent

        for attempt in 0..<2 {
            do {
                return try await prepareListenablePlaybackSnapshot(
                    for: article,
                    content: content,
                    learnerAsked: learnerAsked
                )
            } catch KnowledgeStoreError.sourceContentChanged where attempt == 0 {
                guard let refreshed = await ArticleSpeechContent.persistedText(sourceID: article.id) else {
                    throw KnowledgeStoreError.sourceContentChanged
                }
                content = refreshed
            }
        }

        throw KnowledgeStoreError.sourceContentChanged
    }

    private func prepareListenablePlaybackSnapshot(
        for article: StudioArticle,
        content: String,
        learnerAsked: Bool
    ) async throws -> PreparedListenablePlayback {
        let usesAITextToSpeechPreparation = TextToSpeechPreparationPolicy.usesAIPreparation(
            sourceType: article.sourceType.rawValue,
            url: article.url
        )
        let sourceHash = await Task.detached(priority: .utility) {
            PaperContentPreparationService.sha256(
                content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
        let storedListenable = await ArticleSpeechContent.listenableContent(sourceID: article.id)
        let currentPreparationSignature = usesAITextToSpeechPreparation
            ? await PaperTextToSpeechPreparationService.currentPreparationSignature()
            : nil
        let validStoredListenable: StoredSourceListenableContent? = storedListenable.flatMap { stored in
            guard stored.metadata.sourceSHA256 == sourceHash else { return nil }
            if usesAITextToSpeechPreparation {
                guard let currentSignature = currentPreparationSignature,
                      stored.metadata.preparationSignature == currentSignature else { return nil }
            }
            return stored
        }

        if let validStoredListenable {
            return PreparedListenablePlayback(
                content: validStoredListenable.text,
                sourceContentSignature: usesAITextToSpeechPreparation ? sourceHash : nil,
                narrationPreparationSignature: usesAITextToSpeechPreparation
                    ? validStoredListenable.metadata.preparationSignature
                    : nil
            )
        }

        let candidate = SourceListenableContentCandidate(
            sourceID: article.id,
            title: article.title,
            sourceType: article.sourceType,
            canonicalText: content,
            sourceSHA256: sourceHash
        )
        if usesAITextToSpeechPreparation {
            let source = AIUsageSource(
                id: article.id,
                sourceType: article.sourceType,
                title: article.title
            )
            let preparedSource = try await Task.detached(priority: .userInitiated) {
                try await AIUsageAttribution.$learnerAsked.withValue(learnerAsked) {
                    try await PaperTextToSpeechPreparationService().prepare(
                        source: source,
                        canonicalText: content
                    )
                }
            }.value
            try await ArticleSpeechContent.saveListenableContent(
                candidate: candidate,
                text: preparedSource.text,
                preparationSignature: preparedSource.preparationSignature
            )
            return PreparedListenablePlayback(
                content: preparedSource.text,
                sourceContentSignature: preparedSource.sourceContentSignature,
                narrationPreparationSignature: preparedSource.preparationSignature
            )
        }

        let preparedText = await Task.detached(priority: .userInitiated) {
            MacArticleSpeechText.narrationText(from: content)
        }.value
        try await ArticleSpeechContent.saveListenableContent(
            candidate: candidate,
            text: preparedText,
            preparationSignature: nil
        )
        return PreparedListenablePlayback(
            content: preparedText,
            sourceContentSignature: nil,
            narrationPreparationSignature: nil
        )
    }

    /// One book approved for paid generation, remembered so auto-advance does
    /// not re-ask at every chapter. The signature pins the quote to the model
    /// and voice it was given for: changing either reprices the book and
    /// invalidates its cached audio, so the listener is asked again.
    struct BookGenerationApproval: Equatable {
        let groupID: String
        let signature: String
    }

    /// Renders the Now Playing picture for the source about to play: the book's
    /// cover for a chapter, a paper's first page, an article's artwork, or the
    /// ForeverLM mark. Off-main, and applied only if this source is still the
    /// one playing when the image is ready.
    func loadNowPlayingArtwork(for article: StudioArticle) {
        if nowPlayingArtworkSourceID != article.id {
            nowPlayingArtwork = nil
        }
        nowPlayingArtworkSourceID = article.id
        var coverPath: String?
        if article.sourceType == .book, let groupID = article.parentGroup {
            coverPath = bookScopeProvider?(groupID)?.coverPath
        }
        let cover = coverPath
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                await NowPlayingArtwork.image(for: article, bookCoverPath: cover)
            }.value
            guard let self, self.nowPlayingArtworkSourceID == article.id else { return }
            self.nowPlayingArtwork = NowPlayingArtwork.artwork(from: image)
            self.updateNowPlayingInfo()
        }
    }

    /// The line under the title in Now Playing and in the synced audio
    /// manifest: the book a chapter belongs to, otherwise the author or the
    /// site. A book's `parentGroup` is its stable group id — a bare UUID for an
    /// imported book — so the title is resolved through Studio's book scope,
    /// and when Studio has not supplied one the line falls back to the author
    /// rather than ever showing the id.
    func displaySubtitle(for article: StudioArticle) -> String? {
        if let overviewID = GeneratedAudioOverview.artifactID(ofCarrier: article) {
            let kind = AudioOverviewScript.kindLabel
            guard let notebook = audioOverviewNotebookTitleProvider?(overviewID)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !notebook.isEmpty else { return kind }
            return "\(kind) · \(notebook)"
        }
        if article.sourceType == .book, let groupID = article.parentGroup, groupID != article.id {
            if let title = bookScopeProvider?(groupID)?.title.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty, title != groupID {
                return title
            }
        } else if article.sourceType != .book, let group = article.parentGroup, !group.isEmpty {
            return group
        }
        return article.displayAuthor ?? article.displayDomain
    }

    /// The book behind a chapter, priced as the listener will actually hear it.
    struct BookGenerationEstimate {
        let groupID: String
        let title: String
        /// Chapters beyond the one being started that still have no cached
        /// audio — what auto-advance goes on to generate and be billed for.
        let remainingChapters: ArticleSpeechCostEstimate
    }

    /// Prices the rest of the book behind the chapter about to start. Nil for a
    /// source that is not a book chapter, when Studio has not supplied the
    /// book's chapters, or when every other chapter is already cached — the
    /// confirmation then quotes the single source, which is the whole charge.
    func bookGenerationEstimate(
        for article: StudioArticle,
        provider: MacArticleSpeechMode,
        model: String,
        narrationCharacters: Int
    ) async -> BookGenerationEstimate? {
        guard article.sourceType == .book,
              let groupID = article.parentGroup,
              let scope = bookScopeProvider?(groupID) else { return nil }
        let others = scope.chapters
            .filter { $0.id != article.id && ArticleSpeechContent.canAttemptRead($0) }
        guard !others.isEmpty else { return nil }
        let chapterIDs = others.map(\.id)
        let wordCounts = Dictionary(
            others.compactMap { chapter in chapter.wordCount.map { (chapter.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // This chapter's own narration is the best ratio available for the
        // chapters whose narration has not been prepared yet.
        let charactersPerWord = ArticleSpeechCostEstimate.charactersPerWord(
            narrationCharacters: narrationCharacters,
            wordCount: article.wordCount
        )

        // Cache probing stats files and the length lookup reads across the whole
        // book, so both run off the main actor — and the lengths come from
        // `LENGTH(content)`, never by pulling a chapter's text into memory.
        let storage = activityStorage
        let pending = await Task.detached(priority: .userInitiated) { () async -> (chapters: Int, characters: Int) in
            let uncached = chapterIDs.filter {
                !ArticleSpeechAudioCache.hasCachedAudio(sourceID: $0)
            }
            guard !uncached.isEmpty else { return (0, 0) }
            // A chapter whose text has not been extracted into `source_content`
            // yet has no stored length, so its word count stands in. One with
            // neither is still counted as a chapter but adds no characters,
            // which understates the book rather than inventing a number.
            let lengths = await storage.sourceContentLengths(for: uncached)
            let characters = uncached.reduce(0) { total, id in
                if let length = lengths[id] { return total + length }
                guard let words = wordCounts[id] else { return total }
                return total + Int((Double(words) * charactersPerWord).rounded())
            }
            return (uncached.count, characters)
        }.value
        guard pending.chapters > 0, pending.characters > 0 else { return nil }

        return BookGenerationEstimate(
            groupID: groupID,
            title: scope.title,
            remainingChapters: ArticleSpeechCostEstimate(
                characters: pending.characters,
                sourceCount: pending.chapters,
                provider: provider.rawValue,
                model: model
            )
        )
    }
}
#endif
