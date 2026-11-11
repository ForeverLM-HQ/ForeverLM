import Foundation
import os

private let logger = Logger(subsystem: "com.foreverlm", category: "YouTubeTranscriptCheck")

/// A video transcript the check rewrote, as it is now stored.
struct RewrittenYouTubeTranscript: Sendable, Equatable {
    let sourceID: String
    let content: String
}

struct YouTubeTranscriptCheckResult: Sendable {
    let rewritten: [RewrittenYouTubeTranscript]
    let checkedCount: Int
    let remainingCount: Int
}

/// Holds each staged YouTube video's stored transcript to its captions, once.
///
/// Transcript Formatting dropped caption runs, repeated and invented text, and
/// set markers on the wrong words (measured 2026-09-28 on the fourteen
/// lectures behind the product owner's quizzes); since 441dbce7b a new transcript is held
/// to its captions as it is formatted (`ReadableTranscriptMarkers.checked`).
/// Schema 148 staged every personal YouTube video in
/// `youtube_transcript_check_queue` for the ones stored before. A video keeps
/// no raw captions, so this fetches them again — one InnerTube and one
/// timed-text request, no model — a few videos at a time, runs the same check
/// over the stored text, and writes the result only when it differs and
/// nothing anchored to the old text would move: a highlight's passage, a
/// course quiz question's quote or the lines it rests on, a Memory item's
/// excerpt (`movedAnchor`). A transcript of raw captions comes out as it went
/// in, and a check the captions refuse leaves the text alone. The slide
/// frames block after the transcript is kept as it is.
///
/// An answered row leaves the queue. A row whose captions could not be
/// fetched counts an attempt and is fetched again on a later drain; a batch
/// in which no fetch succeeded ends the drain — the Mac is offline or YouTube
/// is refusing — until the next trigger, the same event-driven ones canonical
/// cleanup runs on.
actor YouTubeTranscriptCheckService {
    /// Videos checked at once, one after another: a once-per-library backfill
    /// has no reason to hurry YouTube.
    static let batchSize = 2

    typealias CaptionFetch = @Sendable (String) async throws -> String

    private let storage: StorageService
    private let fetchCaptions: CaptionFetch
    private var isDraining = false

    init(
        storage: StorageService,
        fetchCaptions: @escaping CaptionFetch = { url in
            try await YouTubeTranscriptService.shared.fetchCaptions(from: url)
        }
    ) {
        self.storage = storage
        self.fetchCaptions = fetchCaptions
    }

    private enum Outcome: Sendable {
        case rewritten(RewrittenYouTubeTranscript)
        case answered
        case unanswered
    }

    func drain() async -> YouTubeTranscriptCheckResult {
        guard !isDraining else {
            return await result(rewritten: [], checked: 0)
        }
        isDraining = true
        defer { isDraining = false }

        do {
            try await storage.dropYouTubeTranscriptChecksWithoutVideos()
        } catch {
            logger.error("Could not tidy the YouTube transcript check queue: \(error.localizedDescription, privacy: .public)")
        }

        var rewritten: [RewrittenYouTubeTranscript] = []
        var checked = 0
        while !Task.isCancelled {
            let candidates: [YouTubeTranscriptCheckCandidate]
            do {
                candidates = try await storage.youTubeTranscriptCheckCandidates(limit: Self.batchSize)
            } catch {
                logger.error("Could not read the YouTube transcript check queue: \(error.localizedDescription, privacy: .public)")
                break
            }
            if candidates.isEmpty { break }

            var answered = 0
            for candidate in candidates {
                switch await check(candidate) {
                case .rewritten(let transcript):
                    rewritten.append(transcript)
                    answered += 1
                case .answered:
                    answered += 1
                case .unanswered:
                    break
                }
            }
            checked += answered
            // No captions came back: offline or refused. Stop here rather
            // than spend every row's attempts at network speed.
            if answered == 0 { break }
            try? await Task.sleep(for: .seconds(1))
        }
        return await result(rewritten: rewritten, checked: checked)
    }

    private func check(_ candidate: YouTubeTranscriptCheckCandidate) async -> Outcome {
        let sourceID = candidate.sourceID
        let stored = await storage.loadStoredSourceContents(for: [sourceID])[sourceID] ?? ""
        let parts = Self.transcriptParts(of: stored)
        guard Self.isTimed(parts.body) else {
            // No transcript yet, or text that was never timed captions.
            do {
                try await storage.completeYouTubeTranscriptCheck(sourceID: sourceID)
            } catch {
                logger.error("Could not complete the YouTube transcript check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        }

        let captions: String
        do {
            captions = try await fetchCaptions(candidate.url)
        } catch YouTubeTranscriptError.noTranscriptAvailable {
            do {
                try await storage.completeYouTubeTranscriptCheck(sourceID: sourceID)
            } catch {
                logger.error("Could not complete the YouTube transcript check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        } catch YouTubeTranscriptError.invalidURL {
            do {
                try await storage.completeYouTubeTranscriptCheck(sourceID: sourceID)
            } catch {
                logger.error("Could not complete the YouTube transcript check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        } catch {
            // An interrupted drain is not a failed fetch: leave the row as it
            // is, so the next drain fetches again without counting an attempt.
            guard !Task.isCancelled else { return .unanswered }
            do {
                try await storage.recordYouTubeTranscriptCheckFailure(
                    sourceID: sourceID,
                    message: error.localizedDescription
                )
            } catch {
                logger.error("Could not record the YouTube transcript check failure: \(error.localizedDescription, privacy: .public)")
            }
            return .unanswered
        }
        guard !Task.isCancelled else { return .unanswered }

        let body = parts.body
        let checkedText = await Task.detached(priority: .utility) {
            ReadableTranscriptMarkers.checked(body, against: captions, restoringDroppedCaptions: true)
        }.value
        guard let checkedText else {
            logger.notice("Kept the transcript of \(sourceID, privacy: .public): it does not hold to its captions")
            do {
                try await storage.completeYouTubeTranscriptCheck(sourceID: sourceID)
            } catch {
                logger.error("Could not complete the YouTube transcript check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        }
        let content = parts.lead + checkedText.text + parts.tail
        guard Self.differs(content, from: stored) else {
            do {
                try await storage.completeYouTubeTranscriptCheck(sourceID: sourceID)
            } catch {
                logger.error("Could not complete the YouTube transcript check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        }

        do {
            if let anchor = try await movedAnchor(sourceID: sourceID, old: stored, new: content) {
                logger.notice("Kept the transcript of \(sourceID, privacy: .public): the check would move \(anchor, privacy: .public)")
                try await storage.completeYouTubeTranscriptCheck(sourceID: sourceID)
                return .answered
            }
            let changed = try await storage.replaceCheckedYouTubeTranscript(
                sourceID: sourceID,
                checkedContent: stored,
                content: content
            )
            guard changed else { return .answered }
            logger.notice(
                "Held the transcript of \(sourceID, privacy: .public) to its captions: \(checkedText.restoredWords) caption words put back, \(checkedText.removedWords) model words taken out"
            )
            return .rewritten(RewrittenYouTubeTranscript(sourceID: sourceID, content: content))
        } catch {
            logger.error(
                "Could not record the transcript check for \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            do {
                try await storage.recordYouTubeTranscriptCheckFailure(
                    sourceID: sourceID,
                    message: error.localizedDescription
                )
            } catch {
                logger.error("Could not record the YouTube transcript check failure: \(error.localizedDescription, privacy: .public)")
            }
            return .unanswered
        }
    }

    /// What anchored to `old` would not be found in `new`, named for the log,
    /// or nil when nothing moves. A highlight is resolved as the transcript
    /// reader resolves it; a quiz question's quote must stay inside the lines
    /// it names, and a question without one must keep those lines' words; a
    /// Memory excerpt must stay a run of the text's words. Only what the old
    /// text still holds is protected: an anchor already lost cannot move.
    private func movedAnchor(sourceID: String, old: String, new: String) async throws -> String? {
        let highlights = try await storage.sourceHighlights(sourceID: sourceID)
        if !highlights.isEmpty {
            let oldText = Self.readerText(of: old)
            let newText = Self.readerText(of: new)
            for highlight in highlights
            where highlight.anchor.resolve(in: oldText) != nil && highlight.anchor.resolve(in: newText) == nil {
                return "highlight \(highlight.id)"
            }
        }

        let questions = try await storage.loadCourseQuizzes()
            .flatMap(\.questions)
            .filter { $0.sourceID == sourceID }
        if !questions.isEmpty {
            let oldLines = CourseQuizPlanning.lines(from: old)
            let newLines = CourseQuizPlanning.lines(from: new)
            let oldWords = MemoryGroundingText(oldLines.map(\.text).joined(separator: "\n"))
            let newWords = MemoryGroundingText(newLines.map(\.text).joined(separator: "\n"))
            func stretch(_ question: CourseQuizQuestion, in lines: [LectureQuizLine]) -> String? {
                guard let last = question.lastLine else { return nil }
                let first = min(question.firstLine ?? last, last)
                return lines.filter { $0.number >= first && $0.number <= last }.map(\.text).joined(separator: "\n")
            }
            for question in questions {
                let quote = question.quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !quote.isEmpty, oldWords.contains(quote), !newWords.contains(quote) {
                    return "the quote of quiz question \(question.id)"
                }
                guard let oldStretch = stretch(question, in: oldLines), !oldStretch.isEmpty else { continue }
                let newStretch = MemoryGroundingText(stretch(question, in: newLines) ?? "")
                if !quote.isEmpty {
                    if MemoryGroundingText(oldStretch).contains(quote), !newStretch.contains(quote) {
                        return "the lines of quiz question \(question.id)"
                    }
                } else if !newStretch.contains(oldStretch)
                            || newStretch.letterCount != MemoryGroundingText(oldStretch).letterCount {
                    // Without a quote, the lines are the question's only
                    // anchor: their words must stay the same.
                    return "the lines of quiz question \(question.id)"
                }
            }
        }

        let excerpts = try await storage.memoryAnchorExcerpts(sourceID: sourceID)
        if !excerpts.isEmpty {
            let oldText = MemoryGroundingText(old)
            let newText = MemoryGroundingText(new)
            for excerpt in excerpts where oldText.contains(excerpt) && !newText.contains(excerpt) {
                return "a Memory excerpt"
            }
        }
        return nil
    }

    private func result(rewritten: [RewrittenYouTubeTranscript], checked: Int) async -> YouTubeTranscriptCheckResult {
        let remaining: Int
        do {
            remaining = try await storage.youTubeTranscriptCheckQueueCount()
        } catch {
            logger.error("Could not count the YouTube transcript check queue: \(error.localizedDescription, privacy: .public)")
            remaining = 0
        }
        if checked > 0 {
            logger.info(
                "Checked \(checked) YouTube transcript(s) against their captions, rewrote \(rewritten.count); \(remaining) remaining"
            )
        }
        return YouTubeTranscriptCheckResult(
            rewritten: rewritten,
            checkedCount: checked,
            remainingCount: remaining
        )
    }

    // MARK: Text

    /// A stored video text as the check reads it: the transcript, with the
    /// whitespace around it and the slide frames block after it kept as they
    /// are.
    static func transcriptParts(of content: String) -> (lead: String, body: String, tail: String) {
        let transcript: Substring
        let slides: Substring
        if let header = content.range(of: SlideFrameExtraction.slideSectionHeader) {
            transcript = content[..<header.lowerBound]
            slides = content[header.lowerBound...]
        } else {
            transcript = content[...]
            slides = ""
        }
        guard let first = transcript.firstIndex(where: { !$0.isWhitespace }),
              let last = transcript.lastIndex(where: { !$0.isWhitespace }) else {
            return (String(transcript), "", String(slides))
        }
        return (
            String(transcript[..<first]),
            String(transcript[first...last]),
            String(transcript[transcript.index(after: last)...]) + slides
        )
    }

    private static let marker = try! NSRegularExpression(pattern: #"\[\d{1,2}:\d{2}(?::\d{2})?\]"#)

    /// Whether a transcript carries caption markers to hold it to.
    static func isTimed(_ transcript: String) -> Bool {
        marker.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) != nil
    }

    /// Whether two texts differ in more than their whitespace: a transcript
    /// of raw captions laid out again is the same transcript, and rewriting it
    /// would re-derive everything keyed to the text for nothing.
    static func differs(_ lhs: String, from rhs: String) -> Bool {
        !lhs.split(whereSeparator: \.isWhitespace).elementsEqual(rhs.split(whereSeparator: \.isWhitespace))
    }

    /// The transcript as the transcript reader lays it out for its
    /// highlights (`TranscriptDocumentText`).
    static func readerText(of content: String) -> String {
        let transcript = YouTubeSlideContentParser.parse(content).transcriptContent
        return TranscriptDocumentText(segments: YouTubeTranscriptDisplayParser.parse(transcript).segments).joined
    }
}
