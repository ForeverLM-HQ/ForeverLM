// Going to a part of a narration: a paper's sections, and "Listen from Here".
#if os(macOS)
import AppKit
import Foundation
import PDFKit

extension ArticleSpeechService {
    /// Reads the paper's headings from its PDF and finds each in the narration
    /// that has just started, off the main thread. Nothing for a source that is
    /// not a paper with a PDF on this Mac, or whose headings are not found.
    func loadNarrationSections(for article: StudioArticle) {
        clearNarrationSections()
        guard article.sourceType == .paper, !audioChunks.isEmpty else { return }
        let chunks = audioChunks
        let sourceID = article.id
        narrationSectionsTask = Task.detached(priority: .utility) { [weak self, article, chunks] in
            guard let path = article.resolvedPDFPath,
                  let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return }
            let candidates = PaperPDFSections.candidates(in: document)
            guard !Task.isCancelled else { return }
            let sections = NarrationSectionResolver.sections(from: candidates, in: chunks)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled,
                      self.activeArticleID == sourceID, self.audioChunks == chunks else { return }
                // One section is no table of contents.
                self.narrationSections = sections.count >= 2 ? sections : []
            }
        }
    }

    func clearNarrationSections() {
        narrationSectionsTask?.cancel()
        narrationSectionsTask = nil
        if !narrationSections.isEmpty { narrationSections = [] }
        narrationTextIndexCache = nil
    }

    /// The section playing now: the last one that starts at or before the
    /// current chunk and point in it.
    var currentNarrationSectionID: Int? {
        guard !narrationSections.isEmpty else { return nil }
        let chunk = currentlyPlayingChunkIndex
        let duration = chunkDuration(at: chunk)
        let fraction = duration > 0 ? (audioPlayer?.currentTime ?? 0) / duration : 0
        return narrationSections.last { section in
            section.spot.chunkIndex < chunk
                || (section.spot.chunkIndex == chunk && section.spot.fraction <= fraction + 0.001)
        }?.id
    }

    /// Seconds into the narration where `spot` is, once every chunk before it
    /// has a known length; nil before then, rather than a guess.
    func narrationTime(of spot: NarrationSpot) -> TimeInterval? {
        guard spot.chunkIndex < totalChunkCount else { return nil }
        var elapsed: TimeInterval = 0
        for index in 0..<spot.chunkIndex {
            guard let duration = chunkDurations[index], duration > 0 else { return nil }
            elapsed += duration
        }
        guard let duration = chunkDurations[spot.chunkIndex], duration > 0 else { return nil }
        return elapsed + spot.offset(inChunkOfDuration: duration)
    }

    /// Plays from `spot`. False when that part of the narration is not on this
    /// Mac yet, or nothing is playing.
    @discardableResult
    func play(from spot: NarrationSpot) -> Bool {
        guard activeArticleID != nil, canSeek,
              spot.chunkIndex < totalChunkCount,
              spot.chunkIndex <= availableSeekChunkLimit() else { return false }
        let offset = spot.offset(inChunkOfDuration: chunkDuration(at: spot.chunkIndex))
        // Going somewhere means hearing it: a paused player starts there.
        isPaused = false
        startPlaybackTask { [weak self] in
            await self?.jumpToChunk(spot.chunkIndex, offset: offset)
            self?.savePlaybackPositionNow()
            self?.updateNowPlayingInfo()
        }
        return true
    }

    func play(section: NarrationSection) {
        if !play(from: section.spot) { NSSound.beep() }
    }

    /// Where the playing narration speaks `passage`.
    func narrationSpot(of passage: String) -> NarrationSpot? {
        guard !audioChunks.isEmpty else { return nil }
        let index: NarrationTextIndex
        if let cache = narrationTextIndexCache, cache.chunks == audioChunks {
            index = cache.index
        } else {
            index = NarrationTextIndex(chunks: audioChunks)
            narrationTextIndexCache = (audioChunks, index)
        }
        return NarrationPassageLocator.offset(of: passage, in: index).flatMap(index.spot(atOffset:))
    }

    /// "Listen from Here": plays the source's narration from the passage. If
    /// another source (or none) is playing, Listen starts this one there; if
    /// the narration has yet to be made, it starts there once it is.
    func listen(fromPassage passage: String, article: StudioArticle) {
        if activeArticleID == article.id, !audioChunks.isEmpty {
            guard let spot = narrationSpot(of: passage), play(from: spot) else {
                NSSound.beep()
                return
            }
            return
        }
        if activeArticleID != nil { stop() }
        pendingStartPassage = (article.id, passage)
        listen(to: article)
    }

    /// The spot a pending "Listen from Here" asks the starting narration to
    /// begin at, taken once; nil when there is none for this source or the
    /// passage is not in the narration (it then starts as it would have).
    func takePendingStartSpot() -> NarrationSpot? {
        guard let pending = pendingStartPassage else { return nil }
        pendingStartPassage = nil
        guard pending.sourceID == activeArticleID else { return nil }
        return narrationSpot(of: pending.passage)
    }
}
#endif
