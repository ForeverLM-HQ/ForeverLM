import Foundation
import OSLog

/// Finds the papers a talk cites on its slides and resolves them to real records.
///
/// Runs after ingestion so candidates are ready before the learner opens the video.
///
/// A frame normally takes one vision pass: citation extraction also says whether the image
/// is a deck page or a room photograph. A user's older custom extraction prompt may omit
/// that verdict; only then does the separately configurable `slideFrameClassification` task
/// run as a compatibility fallback. The verdict becomes the Non-slide mark that hides a
/// slide's camera-shot twin.
actor SlideCitationService {
    static let shared = SlideCitationService()

    /// Split complete transcript or notes material into overlapping model-sized
    /// reads. The overlap keeps a citation that straddles a boundary intact;
    /// callers scan every returned chunk rather than silently truncating long
    /// meetings or course documents.
    nonisolated static func materialChunks(
        _ content: String,
        maxCharacters: Int = 24_000,
        overlapCharacters: Int = 1_200
    ) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let chunkSize = max(1, maxCharacters)
        let overlap = max(0, min(overlapCharacters, chunkSize - 1))
        var chunks: [String] = []
        var start = trimmed.startIndex

        while start < trimmed.endIndex {
            let end = trimmed.index(
                start,
                offsetBy: chunkSize,
                limitedBy: trimmed.endIndex
            ) ?? trimmed.endIndex
            let chunk = String(trimmed[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            guard end < trimmed.endIndex else { break }
            start = overlap == 0
                ? end
                : trimmed.index(end, offsetBy: -overlap)
        }
        return chunks
    }

    /// What one video's scan produced. Carries the failure count so a partial read is
    /// reported rather than passing silently as "this talk cites nothing".
    struct ScanResult: Sendable {
        let candidates: [VideoCitedPaper]
        let slidesScanned: Int
        let slidesFailed: Int
        /// Every distinct captured slide that was available when the scan began. An ordinary
        /// scan deliberately reads only the first bounded set; keeping that total prevents a
        /// successful bounded pass from being reported as a complete-deck scan.
        let slidesAvailable: Int
        /// Image paths of frames the model judged to be photographs of the room rather than
        /// deck pages — a wide shot of the speaker at the lectern, the audience, a seated
        /// panel. A conference recording cuts between the slide feed and a locked-off podium
        /// camera, and that camera holds still enough to survive slide detection as its own
        /// run, so the deck page and a photo of it reach the reader as two entries. The caller
        /// marks these in the stored deck so the reader hides them and one deck page shows once.
        let nonSlideFramePaths: [String]
        /// Every frame this scan actually looked at, marked or not. The caller needs the full
        /// set, not just the flagged one, to clear a stale mark off a frame the model reversed
        /// its judgement on — and to gauge, against the flagged count, whether the model
        /// misfired on the whole deck.
        let scannedFramePaths: [String]

        init(
            candidates: [VideoCitedPaper],
            slidesScanned: Int,
            slidesFailed: Int,
            slidesAvailable: Int? = nil,
            nonSlideFramePaths: [String],
            scannedFramePaths: [String]
        ) {
            self.candidates = candidates
            self.slidesScanned = slidesScanned
            self.slidesFailed = slidesFailed
            self.slidesAvailable = max(slidesScanned, slidesAvailable ?? slidesScanned)
            self.nonSlideFramePaths = nonSlideFramePaths
            self.scannedFramePaths = scannedFramePaths
        }

        var slidesSkipped: Int { max(0, slidesAvailable - slidesScanned) }
        var isComplete: Bool { slidesFailed == 0 && slidesSkipped == 0 }
    }

    struct ExtractedCitation: Decodable, Sendable {
        /// Absent when the slide credited a figure without printing the paper's title.
        let title: String?
        let authors: String?
        let year: String?
        let journal: String?
        let doi: String?
        /// Text-material discovery may return a literal paper link. Slide
        /// extraction normally leaves this absent.
        let url: String?
        /// Where the entry says the paper sits in its journal. Reference lists print these;
        /// slides and transcripts almost never do.
        let volume: String?
        /// The page range or article number as printed ("257–262", "e136055", "22").
        let pages: String?

        init(
            title: String?, authors: String?, year: String?, journal: String?,
            doi: String?, url: String?, volume: String? = nil, pages: String? = nil
        ) {
            self.title = title
            self.authors = authors
            self.year = year
            self.journal = journal
            self.doi = doi
            self.url = url
            self.volume = volume
            self.pages = pages
        }

        private enum CodingKeys: String, CodingKey {
            case title, authors, year, journal, doi, url, volume, pages
        }

        /// Lenient about numbers: a model writes a year or a volume as `2014` as often as
        /// `"2014"`, and one bare number must not fail the whole slide's read.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
                if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                    return value.rounded() == value ? String(Int(value)) : String(value)
                }
                return nil
            }
            self.init(
                title: text(.title), authors: text(.authors), year: text(.year),
                journal: text(.journal), doi: text(.doi), url: text(.url),
                volume: text(.volume), pages: text(.pages)
            )
        }
    }

    /// Where a reference entry says a paper sits in its journal: the volume and the first
    /// page or article number. A Nature-style reference list prints exactly this and no
    /// title — "Sturm, G. et al. Commun. Biol. 6, 22 (2023)" — and together with the first
    /// author's surname and the year, or with the journal alone ("PNAS, 1980 77:3430-4"), it
    /// names one paper as surely as a title does. Lookup evidence only: it is spent during
    /// resolution and never stored on the candidate row.
    struct BibliographicLocator: Sendable, Equatable {
        let volume: String?
        let firstPage: String?

        init?(volume: String?, pages: String?) {
            var volume = volume?.nilIfBlank
            var pages = pages?.nilIfBlank
            // "77:3430-4" or "171(8):2029-50" handed over whole as the pages: the volume is
            // what comes before the colon, less an issue in parentheses.
            if volume == nil, let printed = pages, let colon = printed.firstIndex(of: ":"),
               let lead = printed[..<colon].split(separator: "(").first?
                .trimmingCharacters(in: .whitespaces),
               !lead.isEmpty, lead.allSatisfy(\.isNumber) {
                volume = lead
                pages = String(printed[printed.index(after: colon)...]).nilIfBlank
            }
            let firstPage = pages.map(Self.firstPage(of:))?.nilIfBlank
            guard volume != nil || firstPage != nil else { return nil }
            self.volume = volume
            self.firstPage = firstPage
        }

        /// "257–262" → "257", "pp. 12-19" → "12", "e136055" → "e136055".
        static func firstPage(of pages: String) -> String {
            var text = pages.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["pp.", "pp", "p."] where text.lowercased().hasPrefix(prefix + " ") {
                text = String(text.dropFirst(prefix.count + 1))
            }
            let separators = CharacterSet(charactersIn: "-\u{2013}\u{2014}\u{2010}, ")
            let first = text.components(separatedBy: separators).first { !$0.isEmpty } ?? text
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// One frame's read: whether it is a slide at all, and the papers on it if it is.
    struct SlideRead: Sendable {
        /// Nil only for a legacy bare-array response or a custom prompt that omitted the
        /// verdict. Callers keep treating absence as a slide, while a deck scan asks the
        /// dedicated classifier before it writes any Non-slide mark.
        let presentationVerdict: Bool?
        let citations: [ExtractedCitation]

        var isPresentationSlide: Bool { presentationVerdict ?? true }
    }

    /// The object the model returns per frame. A missing `isPresentationSlide` is kept as nil
    /// so a deck scan can ask the compatibility classifier rather than inventing a verdict.
    private struct SlideReplyPayload: Decodable {
        let isPresentationSlide: Bool?
        let citations: [ExtractedCitation]?
    }

    enum SlideCitationError: LocalizedError {
        case notConfigured
        case malformedResponse
        case modelCannotReadImages(task: AITask, model: String, providerMessage: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Sign in to ForeverLM in Settings to scan slides for papers."
            case .malformedResponse:
                return "The citation model returned a response that wasn't valid citation JSON."
            case let .modelCannotReadImages(task, model, providerMessage):
                // Names the task whose model refused: classification and extraction
                // are pinned separately, so "which setting do I change" has two answers.
                return """
                \(model) can't read images, and slide frames are read from the image itself.

                Pick a vision-capable model under Settings → AI Models → Background → \
                Advanced → \(task.displayName).

                The provider said: \(providerMessage)
                """
            }
        }
    }

    /// Whether a provider rejected the request because the model has no vision input.
    ///
    /// Model IDs are not a reliable way to know this up front — the list changes constantly,
    /// and wrongly hiding a capable new model is worse than the problem it solves. So the
    /// capability is discovered from the provider's own refusal, which cannot go stale, and
    /// translated into something that names the setting to change.
    nonisolated static func isMissingVisionSupport(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let mentionsImages = ["image", "vision", "multimodal", "multi-modal"]
            .contains { message.contains($0) }
        guard mentionsImages else { return false }
        return ["not support", "unsupported", "no endpoints", "only supported", "cannot process",
                "does not accept", "invalid content type"]
            .contains { message.contains($0) }
    }

    private let logger = Logger(subsystem: "com.foreverlm", category: "SlideCitations")

    /// Ceiling on slides sent by an ordinary per-video scan. The explicit
    /// all-papers lecture workflow opts into the complete captured deck.
    private static let maxSlidesPerScan = 40
    /// Slide reads are independent. Four in flight keeps managed-model concurrency useful
    /// without turning a long deck into a burst that trips provider limits; the shared request
    /// pacer still applies each configured model's own lane limits and backoff.
    private static let maxConcurrentSlideReads = 4
    /// Ceiling on paid web-search lookups for an ordinary per-video scan. Resolution
    /// reaches for the web only after the free catalog lookup fails; the explicit
    /// all-papers lecture workflow opts into resolving the complete leftover set.
    private static let maxWebLookupsPerScan = 8

    // MARK: - Slide selection

    /// Which slides to show the model.
    ///
    /// Every one of them, bounded only by a spend ceiling. There used to be a filter here
    /// that only forwarded slides whose *locally recognised text* looked like a citation —
    /// a DOI, an "et al.", a year beside publication wording. It made the model's reach
    /// depend on Apple Vision reading the frame first, and that dependency is silent when it
    /// fails: a talk whose frames came out too small to OCR produced no recognised text, so
    /// every slide was filtered out, the model was never called, and the result was
    /// indistinguishable from a talk that cites nothing.
    ///
    /// The model reads the image. Let it be the one that decides what is on the slide.
    nonisolated static func slidesToScan(
        _ slides: [YouTubeSlideFrameContext],
        exhaustive: Bool = false
    ) -> [YouTubeSlideFrameContext] {
        exhaustive ? slides : Array(slides.prefix(maxSlidesPerScan))
    }

    // MARK: - Non-slide marks

    /// A scan is treated as misclassified when it flags more than half the frames it looked at
    /// as photographs of the room. A talk is overwhelmingly slides, so a majority verdict is
    /// the classifier failing, not a deck that is mostly camera shots — and acting on it would
    /// hide most of the talk. Callers apply no marks from such a run, leaving whatever an
    /// earlier, sane scan wrote. This is the backstop for the failure that once blanked a deck.
    nonisolated static func isMisclassifiedScan(_ result: ScanResult) -> Bool {
        let scanned = result.scannedFramePaths.count
        return scanned > 0 && Set(result.nonSlideFramePaths).count * 2 > scanned
    }

    /// The stored content rewritten with this scan's non-slide judgements applied — flagged
    /// frames marked, reversed ones cleared — or `nil` when nothing should change (including a
    /// scan judged misclassified by `isMisclassifiedScan`). Marks are added, never blocks
    /// removed, so a misjudgement is reversible and a bad scan can never lose a real slide.
    nonisolated static func contentMarkingNonSlideFrames(
        for result: ScanResult,
        in content: String
    ) -> String? {
        guard !isMisclassifiedScan(result) else { return nil }
        let scanned = Set(result.scannedFramePaths)
        guard !scanned.isEmpty else { return nil }
        return YouTubeSlideContentParser.markingNonSlideFrames(
            Set(result.nonSlideFramePaths), clearingAmong: scanned, in: content
        )
    }

    // MARK: - Talk context

    /// What the model is told about the talk before it reads a slide.
    ///
    /// A citation is read against a subject: venues on slides are routinely abbreviated, and
    /// an acronym means different things in different fields. Title and channel carry that
    /// in two lines — the transcript would be a large prompt repeated on every slide for
    /// very little more. The prompt is explicit that this must never add a paper the slide
    /// does not show, so it narrows readings rather than supplying them.
    nonisolated static func videoContext(title: String, channel: String?) -> String {
        var lines = ["Talk: \(title)"]
        if let channel = channel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channel.isEmpty {
            lines.append("Channel: \(channel)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Scan

    /// Shows every slide of one video to the model and resolves what it finds.
    func scan(
        source: AIUsageSource,
        sourceContent: String,
        videoContext: String? = nil,
        aiService: AIService,
        exhaustive: Bool = false
    ) async throws -> ScanResult {
        let parsed = YouTubeSlideContentParser.parse(sourceContent)
        // An ordinary per-video scan remains spend-bounded. The explicit
        // lecture-ingest workflow asks for every associated paper, so it opts into
        // the complete captured deck and resolves every leftover citation.
        let gated = Self.slidesToScan(parsed.slides, exhaustive: exhaustive)
        if parsed.slides.count > gated.count {
            logger.warning(
                "Capped slide scan for \(source.id, privacy: .public) at \(gated.count) of \(parsed.slides.count) slide(s)"
            )
        }
        return try await AIUsageAttribution.withSource(source) {
            try await scanSlides(
                gated,
                sourceID: source.id,
                videoContext: videoContext,
                aiService: aiService,
                webLookupLimit: exhaustive ? nil : Self.maxWebLookupsPerScan,
                retrying: true,
                slidesAvailable: parsed.slides.count
            )
        }
    }

    /// Reads a single slide the learner pointed at.
    ///
    /// Scanning the whole deck is the expensive way to answer a question that is usually
    /// already answered on screen — the citation is printed on the slide they are looking at.
    /// One slide is normally one citation read; a custom extraction prompt that omits the
    /// slide verdict adds one classification fallback.
    func scanSlide(
        source: AIUsageSource,
        slide: YouTubeSlideFrameContext,
        videoContext: String? = nil,
        aiService: AIService
    ) async throws -> ScanResult {
        try await AIUsageAttribution.withSource(source) {
            try await scanSlides(
                [slide],
                sourceID: source.id,
                videoContext: videoContext,
                aiService: aiService,
                webLookupLimit: Self.maxWebLookupsPerScan,
                retrying: false,
                slidesAvailable: 1
            )
        }
    }

    /// Looks one unresolved citation up again, because the learner asked.
    ///
    /// The scan that left it unresolved was bounded: at most `maxWebLookupsPerScan` web
    /// searches, spread across the whole deck, and a slide read that kept only author,
    /// journal and year. This spends on one row instead. When the row came off a slide, that
    /// slide is read again for everything it prints about this paper — the volume and page
    /// ("171(8):2029-50") are what let the catalogs place a citation that prints no title —
    /// and then the catalog pass and an uncapped web search both get their turn.
    ///
    /// Returns the row with the same id, `.pending` with a DOI when it was found and still
    /// `.unresolved` when it was not.
    func find(
        _ paper: VideoCitedPaper,
        slide: YouTubeSlideFrameContext?,
        source: AIUsageSource,
        videoContext: String?,
        aiService: AIService
    ) async -> VideoCitedPaper {
        await AIUsageAttribution.withSource(source) {
            var candidate = paper
            var locators: [String: BibliographicLocator] = [:]
            if let slide, let reread = await rereadCitation(of: paper, on: slide, videoContext: videoContext, aiService: aiService) {
                candidate = Self.merging(reread, into: paper)
                if let locator = BibliographicLocator(volume: reread.volume, pages: reread.pages) {
                    locators[candidate.id] = locator
                }
            }
            candidate.status = .unresolved
            let resolved = await resolve(
                [candidate],
                videoContext: videoContext,
                aiService: aiService,
                webLookupLimit: nil,
                locators: locators
            )
            return resolved.first ?? paper
        }
    }

    /// The citation on `slide` that is `paper`, read afresh. Nil when the slide cannot be
    /// read or none of its citations is this one — the lookup then goes on with what the row
    /// already holds.
    private func rereadCitation(
        of paper: VideoCitedPaper,
        on slide: YouTubeSlideFrameContext,
        videoContext: String?,
        aiService: AIService
    ) async -> ExtractedCitation? {
        guard let config = KeychainService.resolveConfig(for: .slideCitationExtraction) else { return nil }
        let system = AITask.slideCitationExtraction.effectivePrompt ?? Prompts.slideCitationExtraction
        do {
            let read = try await Self.readSlide(
                imageData: await Self.frameImageData(for: slide),
                slide: slide,
                videoContext: videoContext,
                system: system,
                config: config,
                retrying: false,
                aiService: aiService
            )
            return Self.citation(matching: paper, in: read.citations)
        } catch {
            logger.error(
                "Slide re-read failed for cited paper \(paper.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Which of a slide's citations is the stored row: the same printed title, or for a
    /// title-less attribution the same first author and a year that agrees, or for a row that
    /// printed no author at all — "PNAS, 1980" — the same venue and year. A slide citing one
    /// paper answers for that paper, since that is the slide the row was read from.
    nonisolated static func citation(
        matching paper: VideoCitedPaper,
        in citations: [ExtractedCitation]
    ) -> ExtractedCitation? {
        let matched = citations.first { citation in
            if !paper.isAttributionOnly, let title = citation.title?.nilIfBlank {
                return titlesMatch(paper.title, title)
            }
            if let surname = firstAuthorSurname(paper.authors) {
                guard let other = firstAuthorSurname(citation.authors?.nilIfBlank) else { return false }
                return surnamesMatch(surname, other) && yearsAgree(paper.year, citation.year?.nilIfBlank)
            }
            guard let journal = paper.journal?.nilIfBlank,
                  let other = citation.journal?.nilIfBlank else { return false }
            return (journalsCompatible(journal, other) || journalsCompatible(other, journal))
                && yearsAgree(paper.year, citation.year?.nilIfBlank)
        }
        if let matched { return matched }
        return citations.count == 1 ? citations.first : nil
    }

    /// The stored row with the gaps a fresh read of its slide fills. What the row already
    /// holds wins: it is what the learner has been looking at, and the fresh read is only
    /// there to add what the first one dropped.
    nonisolated static func merging(
        _ citation: ExtractedCitation,
        into paper: VideoCitedPaper
    ) -> VideoCitedPaper {
        var merged = paper
        let authors = paper.authors ?? citation.authors?.nilIfBlank
        let year = paper.year ?? citation.year?.nilIfBlank
        let journal = paper.journal ?? citation.journal?.nilIfBlank
        if paper.isAttributionOnly, let title = citation.title?.nilIfBlank {
            merged.title = title
        } else if paper.isAttributionOnly {
            merged.title = VideoCitedPaper.attributionLabel(authors: authors, journal: journal, year: year)
        }
        merged.authors = authors
        merged.year = year
        merged.journal = journal
        merged.doi = paper.doi ?? citation.doi?.nilIfBlank
        return merged
    }

    /// `retrying` is true for a deck scan, which paces and retries each slide's calls,
    /// and false for a slide the learner is waiting on (`slideCall`).
    private struct SlideAnalysis: Sendable {
        let position: Int
        let slide: YouTubeSlideFrameContext
        let read: SlideRead?
        let isNonSlide: Bool
        let classificationFailure: String?
        let readFailure: String?
    }

    /// Read one frame without touching actor state so independent slides can overlap. The
    /// extraction response normally carries both citations and the slide verdict. Only a
    /// custom or legacy response that omits the verdict pays for the classifier fallback.
    private nonisolated static func analyzeSlide(
        _ slide: YouTubeSlideFrameContext,
        position: Int,
        videoContext: String?,
        classifySystem: String,
        classifyConfig: AITaskConfig?,
        extractSystem: String,
        extractConfig: AITaskConfig,
        retrying: Bool,
        aiService: AIService
    ) async throws -> SlideAnalysis {
        let imageData = await frameImageData(for: slide)
        let read: SlideRead
        do {
            read = try await readSlide(
                imageData: imageData,
                slide: slide,
                videoContext: videoContext,
                system: extractSystem,
                config: extractConfig,
                retrying: retrying,
                aiService: aiService
            )
        } catch {
            if let citationError = error as? SlideCitationError,
               case .modelCannotReadImages = citationError {
                throw citationError
            }
            return SlideAnalysis(
                position: position,
                slide: slide,
                read: nil,
                isNonSlide: false,
                classificationFailure: nil,
                readFailure: error.localizedDescription
            )
        }

        if read.presentationVerdict == false {
            return SlideAnalysis(
                position: position,
                slide: slide,
                read: read,
                isNonSlide: true,
                classificationFailure: nil,
                readFailure: nil
            )
        }

        var classificationFailure: String?
        if read.presentationVerdict == nil, let classifyConfig {
            do {
                if try await classifyFrame(
                    imageData: imageData,
                    system: classifySystem,
                    config: classifyConfig,
                    retrying: retrying,
                    aiService: aiService
                ) == false {
                    return SlideAnalysis(
                        position: position,
                        slide: slide,
                        read: read,
                        isNonSlide: true,
                        classificationFailure: nil,
                        readFailure: nil
                    )
                }
            } catch {
                // Extraction already read this image successfully. A fallback classifier
                // that cannot read it must not discard those citations or abort the deck;
                // keep the frame visible and surface the diagnostic in the log.
                classificationFailure = error.localizedDescription
            }
        }

        return SlideAnalysis(
            position: position,
            slide: slide,
            read: read,
            isNonSlide: false,
            classificationFailure: classificationFailure,
            readFailure: nil
        )
    }

    private func scanSlides(
        _ slides: [YouTubeSlideFrameContext],
        sourceID: String,
        videoContext: String?,
        aiService: AIService,
        webLookupLimit: Int?,
        retrying: Bool,
        slidesAvailable: Int
    ) async throws -> ScanResult {
        guard let extractConfig = KeychainService.resolveConfig(for: .slideCitationExtraction) else {
            throw SlideCitationError.notConfigured
        }
        let classifyConfig = KeychainService.resolveConfig(for: .slideFrameClassification)
        guard !slides.isEmpty else {
            return ScanResult(
                candidates: [], slidesScanned: 0, slidesFailed: 0,
                slidesAvailable: slidesAvailable,
                nonSlideFramePaths: [], scannedFramePaths: []
            )
        }

        let classifySystem = AITask.slideFrameClassification.effectivePrompt
            ?? Prompts.slideFrameClassification
        let extractSystem = AITask.slideCitationExtraction.effectivePrompt
            ?? Prompts.slideCitationExtraction
        var found: [VideoCitedPaper] = []
        var locators: [String: BibliographicLocator] = [:]
        var seen = Set<String>()
        var failed = 0
        var nonSlideFramePaths: [String] = []

        // Each batch overlaps four independent frames. Results are merged back in deck
        // order, so concurrency changes elapsed time but never candidate precedence or
        // which duplicate keeps the first slide locator.
        for batchStart in stride(from: 0, to: slides.count, by: Self.maxConcurrentSlideReads) {
            let batchEnd = min(slides.count, batchStart + Self.maxConcurrentSlideReads)
            let analyses = try await withThrowingTaskGroup(of: SlideAnalysis.self) { group in
                for position in batchStart..<batchEnd {
                    let slide = slides[position]
                    group.addTask {
                        // Bind the awaited value before returning it: a tuple around `try
                        // await` miscompiled in Release on the pinned Swift toolchain.
                        let analysis = try await Self.analyzeSlide(
                            slide,
                            position: position,
                            videoContext: videoContext,
                            classifySystem: classifySystem,
                            classifyConfig: classifyConfig,
                            extractSystem: extractSystem,
                            extractConfig: extractConfig,
                            retrying: retrying,
                            aiService: aiService
                        )
                        return analysis
                    }
                }

                var completed: [SlideAnalysis] = []
                for try await analysis in group {
                    completed.append(analysis)
                }
                return completed.sorted { $0.position < $1.position }
            }

            for analysis in analyses {
                let slide = analysis.slide
                if let message = analysis.classificationFailure {
                    logger.error(
                        "Slide classification failed for \(sourceID, privacy: .public) slide \(slide.index): \(message, privacy: .public)"
                    )
                }
                if analysis.isNonSlide {
                    nonSlideFramePaths.append(slide.imagePath)
                    continue
                }
                if let message = analysis.readFailure {
                    // One unreadable slide must not be reported as a slide with no papers.
                    failed += 1
                    logger.error(
                        "Slide citation read failed for \(sourceID, privacy: .public) slide \(slide.index): \(message, privacy: .public)"
                    )
                    continue
                }

                // Only an explicit non-slide verdict above drops the frame. A missing
                // verdict or failed fallback keeps the successfully read citations.
                guard let read = analysis.read, read.isPresentationSlide else { continue }

                for citation in read.citations {
                    let authors = citation.authors?.nilIfBlank
                    let year = citation.year?.nilIfBlank
                    let journal = citation.journal?.nilIfBlank
                    let title = citation.title?.nilIfBlank
                    let doi = Self.printedDOI(citation.doi)
                    let locator = BibliographicLocator(volume: citation.volume, pages: citation.pages)

                    // A corner attribution — "Hayashida et al. BMC Medicine, 2023" — is a real
                    // citation with no title on the slide, and is how most figures are credited.
                    // So is a bare "(PNAS, 1980 77:3430-4)" after a bullet, which names its paper
                    // by venue, volume and page, and so is a DOI printed on its own. Keep them
                    // all, and stand in a readable label until a lookup supplies the title.
                    guard Self.readsAsCitation(
                        title: title, authors: authors, year: year, journal: journal,
                        doi: doi, locator: locator
                    ) else {
                        continue
                    }
                    let candidate = VideoCitedPaper(
                        sourceID: sourceID,
                        title: title ?? VideoCitedPaper.attributionLabel(
                            authors: authors, journal: journal, year: year
                        ),
                        authors: authors,
                        year: year,
                        journal: journal,
                        doi: doi,
                        slideTimeSeconds: slide.timeSeconds,
                        slideImagePath: slide.imagePath,
                        status: .unresolved
                    )
                    guard seen.insert(Self.scanIdentity(of: candidate, locator: locator)).inserted else { continue }
                    found.append(candidate)
                    // "Szeto, Br J Pharmacol 2014; 171(8):2029-50" names one paper by its
                    // volume and first page even though the slide prints no title.
                    if let locator {
                        locators[candidate.id] = locator
                    }
                }
            }
        }

        // Deduplicated again on the way out. `seen` above keys on what was read off the
        // slide, where "Denham Harman, 1954" and "Harman, 1954" are two different strings;
        // they only collapse once resolution gives them the same DOI.
        return ScanResult(
            candidates: Self.collapsingDuplicates(
                await resolve(
                    found,
                    videoContext: videoContext,
                    aiService: aiService,
                    webLookupLimit: webLookupLimit,
                    locators: locators
                )
            ),
            slidesScanned: slides.count,
            slidesFailed: failed,
            slidesAvailable: slidesAvailable,
            nonSlideFramePaths: nonSlideFramePaths,
            scannedFramePaths: slides.map(\.imagePath)
        )
    }

    /// Drops candidates that resolution proved to be the same paper, keeping the first.
    nonisolated static func collapsingDuplicates(
        _ candidates: [VideoCitedPaper]
    ) -> [VideoCitedPaper] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.dedupKey).inserted }
    }

    /// The frame's JPEG bytes, loaded once per frame and shared by both passes.
    /// The KB lives in iCloud Drive, where reading an evicted file blocks until CloudDocs
    /// fetches it. Never on a caller's actor.
    private nonisolated static func frameImageData(for slide: YouTubeSlideFrameContext) async -> Data? {
        let storedPath = slide.imagePath
        return await Task.detached(priority: .utility) {
            // Resolve across every known content root (stats the filesystem, so
            // it stays off the caller's actor). A build without the iCloud
            // entitlement resolves the single content root to the non-existent
            // local fallback, so a relative frame path must be tried against all
            // roots the way source files are, or the frame reads as absent.
            let resolved = StorageService.locateSourceFile(storedPath)
                ?? StorageService.absoluteSourcePath(storedPath)
            return try? Data(contentsOf: URL(fileURLWithPath: resolved))
        }.value
    }

    /// One model call for a slide, on `config` and then its backups.
    ///
    /// A deck scan is background work, so it is paced and retried like the rest of
    /// import's (`AIBackgroundRetry`). On 2026-09-27 free Nemotron's NVIDIA host was
    /// full ("Worker local total request limit reached (16/16)") and every free backup
    /// was rate-limited at the same moment. Asked only once, that slide was counted
    /// unreadable and its papers never listed. A slide the learner pointed at is asked
    /// once, because they are waiting on the answer.
    private nonisolated static func slideCall(
        config: AITaskConfig,
        retrying: Bool,
        _ operation: (AITaskConfig) async throws -> String
    ) async throws -> String {
        guard retrying else { return try await operation(config) }
        return try await AIBackgroundRetry.run(config: config, operation)
    }

    /// One classification look at a frame: deck page or photograph of the room.
    /// Cheap by construction — a one-field reply — and now reserved for the compatibility
    /// path where a custom extraction prompt did not return that verdict itself.
    private nonisolated static func classifyFrame(
        imageData: Data?,
        system: String,
        config: AITaskConfig,
        retrying: Bool,
        aiService: AIService
    ) async throws -> Bool {
        let reply: String
        do {
            reply = try await slideCall(config: config, retrying: retrying) { config in
                try await aiService.call(
                    config: config,
                    system: system,
                    user: "Judge whether this frame is a presentation slide.",
                    maxTokens: 60,
                    temperature: 0,
                    imageJPEGData: imageData
                )
            }
        } catch {
            if Self.isMissingVisionSupport(error) {
                throw SlideCitationError.modelCannotReadImages(
                    task: .slideFrameClassification,
                    model: config.model,
                    providerMessage: error.localizedDescription
                )
            }
            throw error
        }
        return Self.decodeClassification(reply)
    }

    /// Reads the classification pass's verdict. False only on an explicit
    /// `isPresentationSlide: false` — a reply that cannot be parsed keeps the frame,
    /// because hiding a real slide costs more than showing a room shot twice.
    nonisolated static func decodeClassification(_ reply: String) -> Bool {
        let text = stripFences(reply)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(SlideReplyPayload.self, from: data) else {
            return true
        }
        return payload.isPresentationSlide ?? true
    }

    private nonisolated static func readSlide(
        imageData: Data?,
        slide: YouTubeSlideFrameContext,
        videoContext: String?,
        system: String,
        config: AITaskConfig,
        retrying: Bool,
        aiService: AIService
    ) async throws -> SlideRead {
        // The image is the only evidence. There is no on-device text-recognition pass feeding
        // this any more: it produced a worse copy of what the model reads directly, and its
        // failures were silent, which is how a citation-dense talk came back empty.
        var parts: [String] = []
        // What talk this is. A citation is read against a subject: it tells an abbreviated
        // venue apart from an acronym on the slide, and the speaker's own affiliation apart
        // from a reference. The prompt is explicit that it must never add a paper the slide
        // does not show — the context is for reading what is there, not for supplying what
        // a talk on this subject would plausibly cite.
        if let videoContext = videoContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !videoContext.isEmpty {
            parts.append(videoContext)
        }
        if let timeSeconds = slide.timeSeconds {
            parts.append("Slide timestamp: \(YouTubeTranscriptTime.display(timeSeconds))")
        }
        parts.append("Read the slide image and list the papers it cites.")

        let reply: String
        let user = parts.joined(separator: "\n\n")
        do {
            reply = try await slideCall(config: config, retrying: retrying) { config in
                try await aiService.call(
                    config: config,
                    system: system,
                    user: user,
                    maxTokens: 900,
                    temperature: 0,
                    imageJPEGData: imageData,
                    // A reply that is not citation JSON is no read of the slide — the free router
                    // once gave one to a safety classifier, whose "User Safety: safe" then cost the
                    // Find its volume and page. The next backup model reads it instead, and the
                    // reply is never kept to be replayed.
                    validateResponse: { _ = try SlideCitationService.decodeReply($0) }
                )
            }
        } catch {
            // Translate the provider's refusal into something that names the setting to
            // change. Left raw, this reads as an opaque 400 that says nothing about slides.
            if Self.isMissingVisionSupport(error) {
                throw SlideCitationError.modelCannotReadImages(
                    task: .slideCitationExtraction,
                    model: config.model,
                    providerMessage: error.localizedDescription
                )
            }
            throw error
        }
        return try Self.decodeReply(reply)
    }

    /// Parses the extraction reply into a frame classification and its citations.
    ///
    /// The default prompt returns both fields. Older custom prompts may return an object
    /// without the verdict or a bare legacy array; both preserve a nil verdict so the deck
    /// scan can ask the dedicated compatibility classifier.
    nonisolated static func decodeReply(_ reply: String) throws -> SlideRead {
        let text = stripFences(reply)

        // An object carries the classification; anything else is the legacy array shape.
        if text.first == "{",
           let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end,
           let data = String(text[start...end]).data(using: .utf8),
           let payload = try? JSONDecoder().decode(SlideReplyPayload.self, from: data) {
            return SlideRead(
                presentationVerdict: payload.isPresentationSlide,
                citations: payload.citations ?? []
            )
        }

        return SlideRead(presentationVerdict: nil, citations: try decodeCitations(reply))
    }

    /// Parses a bare citation array.
    ///
    /// An empty array is a real answer — this slide cites nothing. A reply that is not an
    /// array at all is a failure and says so, rather than being quietly read as "none".
    nonisolated static func decodeCitations(_ reply: String) throws -> [ExtractedCitation] {
        let text = stripFences(reply)
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else {
            throw SlideCitationError.malformedResponse
        }
        guard let data = String(text[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ExtractedCitation].self, from: data) else {
            throw SlideCitationError.malformedResponse
        }
        return decoded
    }

    private nonisolated static func stripFences(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Resolution

    /// Turn citations read from text course material into the same verified,
    /// importable candidates produced by a slide scan.
    ///
    /// Titles/authors are semantic descriptors and can be resolved against the
    /// scholarly catalogs. URLs and DOIs determine identity, so a value returned
    /// by the model is accepted only when it occurs literally in the supplied
    /// material text.
    ///
    /// `webLookupLimit` caps the paid web-search fallback; nil resolves every leftover,
    /// which the lecture, meeting and reference-list workflows opt into: each is one
    /// explicit request to find every paper a source cites, and the free catalog pass —
    /// which now places a title-less entry by author, year, volume and page — leaves the
    /// web only the entries no catalog holds.
    func resolveExtractedCitations(
        _ citations: [ExtractedCitation],
        sourceID: String,
        sourceText: String,
        context: String?,
        aiService: AIService,
        webLookupLimit: Int? = nil
    ) async -> [VideoCitedPaper] {
        let (candidates, locators) = Self.candidatesAndLocators(
            citations,
            sourceID: sourceID,
            sourceText: sourceText
        )
        return Self.collapsingDuplicates(
            await resolve(
                candidates,
                videoContext: context,
                aiService: aiService,
                webLookupLimit: webLookupLimit,
                locators: locators
            )
        )
    }

    // MARK: - Reference lists

    /// The part of a paper's text that is its reference list, or the whole text when no
    /// bibliography heading can be found.
    ///
    /// This is a structural cut, not a reading: it looks for the last line that is a
    /// bibliography heading by itself ("References", "Bibliography", "Literature Cited" and
    /// their variants, optionally numbered) and hands everything from there on to the model,
    /// which does the reading. A paper's own text can print "references" inside a sentence,
    /// so only a line consisting of the heading counts, and the *last* such line wins because
    /// a paper that mentions "References" early (a table of contents, a running header)
    /// still has its list at the end. When nothing matches — a two-column layout whose
    /// heading came out glued to the first entry, a scanned paper — the whole text goes to
    /// the model rather than guessing at a tail, and the prompt tells it to read the
    /// reference list out of it.
    nonisolated static func referenceSection(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let headingIndex = lines.lastIndex(where: isReferenceHeadingLine) else {
            return text
        }
        let section = lines[headingIndex...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A heading with nothing under it is a running header or a table-of-contents entry
        // that happened to come last; the list itself is somewhere else.
        return section.count > 200 ? section : text
    }

    private nonisolated static let referenceHeadings: Set<String> = [
        "references", "reference list", "references cited", "references and notes",
        "notes and references", "bibliography", "literature cited", "works cited",
        "cited literature", "reference",
    ]

    /// Whether a line is a bibliography heading by itself: the heading words, optionally
    /// preceded by a section number and followed by a colon or period, nothing else.
    nonisolated static func isReferenceHeadingLine(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        // A leading section number: "7.", "7", "VII.", "(7)".
        if let range = trimmed.range(
            of: #"^\(?([0-9]{1,2}|[ivx]{1,4})[.)]?\s+"#, options: .regularExpression
        ) {
            trimmed.removeSubrange(range)
        }
        while let last = trimmed.last, [":", ".", " "].contains(last) {
            trimmed.removeLast()
        }
        return referenceHeadings.contains(trimmed)
    }

    /// Pure candidate construction, kept separate from catalog/web resolution so
    /// the identity boundary can be tested without making external requests.
    nonisolated static func candidatesFromExtractedCitations(
        _ citations: [ExtractedCitation],
        sourceID: String,
        sourceText: String
    ) -> [VideoCitedPaper] {
        candidatesAndLocators(citations, sourceID: sourceID, sourceText: sourceText).candidates
    }

    /// The candidates plus, keyed by candidate id, where each entry said its paper sits in
    /// its journal. The locator rides beside the candidate rather than on it: the row that
    /// is stored and synced has no place for it, and once resolution has spent it there is
    /// nothing left for it to do.
    nonisolated static func candidatesAndLocators(
        _ citations: [ExtractedCitation],
        sourceID: String,
        sourceText: String
    ) -> (candidates: [VideoCitedPaper], locators: [String: BibliographicLocator]) {
        let lowercasedSourceText = sourceText.lowercased()
        var candidates: [VideoCitedPaper] = []
        var locators: [String: BibliographicLocator] = [:]
        var seen = Set<String>()

        for citation in citations {
            let authors = citation.authors?.nilIfBlank
            let year = citation.year?.nilIfBlank
            let journal = citation.journal?.nilIfBlank
            let title = citation.title?.nilIfBlank
            let locator = BibliographicLocator(volume: citation.volume, pages: citation.pages)
            guard title != nil || (authors != nil && (year != nil || journal != nil))
                    || isVenueLocator(journal: journal, locator: locator) else {
                continue
            }

            let literalDOI = citation.doi?.nilIfBlank.flatMap { doi in
                lowercasedSourceText.contains(doi.lowercased()) ? doi : nil
            }
            let literalURL = citation.url?.nilIfBlank.flatMap { rawURL -> String? in
                guard sourceText.contains(rawURL),
                      let components = URLComponents(string: rawURL),
                      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                      components.host != nil else {
                    return nil
                }
                return rawURL
            }
            var candidate = VideoCitedPaper(
                sourceID: sourceID,
                title: title ?? VideoCitedPaper.attributionLabel(
                    authors: authors, journal: journal, year: year
                ),
                authors: authors,
                year: year,
                journal: journal,
                doi: literalDOI,
                url: literalURL,
                status: literalURL == nil ? .unresolved : .pending
            )
            // A literal DOI has a deterministic canonical landing URL.
            if let literalDOI {
                candidate.url = "https://doi.org/\(literalDOI)"
                candidate.status = .pending
            }
            guard seen.insert(scanIdentity(of: candidate, locator: locator)).inserted else { continue }
            candidates.append(candidate)
            if let locator {
                locators[candidate.id] = locator
            }
        }
        return (candidates, locators)
    }

    /// Whether a citation that printed neither title nor author still names its paper: a
    /// journal with a volume and a first page — "(PNAS, 1980 77:3430-4)" — places a paper as
    /// surely as a title does, and is what citation linking has always matched on.
    nonisolated static func isVenueLocator(journal: String?, locator: BibliographicLocator?) -> Bool {
        journal?.nilIfBlank != nil && locator?.volume != nil && locator?.firstPage != nil
    }

    /// Whether what was read off a slide names a paper at all: a title; an author with a
    /// year or a venue; a venue with its volume and first page; or a DOI. A DOI names its
    /// paper by itself — a lecturer's "Next class" slide showed nothing but a doi.org link
    /// over a screenshot of the article's header, and until 2026-09-27 that read as a slide
    /// citing nothing, because a citation had to carry a title or an attribution to be kept.
    nonisolated static func readsAsCitation(
        title: String?,
        authors: String?,
        year: String?,
        journal: String?,
        doi: String?,
        locator: BibliographicLocator?
    ) -> Bool {
        if title?.nilIfBlank != nil { return true }
        if doi?.nilIfBlank != nil { return true }
        if authors?.nilIfBlank != nil, year?.nilIfBlank != nil || journal?.nilIfBlank != nil { return true }
        return isVenueLocator(journal: journal, locator: locator)
    }

    /// The DOI a slide prints, in the form the catalogs take: the bare
    /// "10.1016/j.redox.2018.101065" out of a doi.org link, a "doi:" prefix, or the
    /// "10.1016%2Fj.redox…" a browser's address bar shows, which is what a lecturer pastes
    /// onto a slide. Nil when what was read is not a DOI at all.
    nonisolated static func printedDOI(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        text = text.removingPercentEncoding ?? text
        if let range = text.range(of: "doi.org/", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
        }
        if text.lowercased().hasPrefix("doi:") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;)]"))
        guard text.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    /// What a read collapses repeated citations on before any lookup: the candidate's own
    /// dedup key, except for a citation with no title, no author and no link. Its only title is
    /// the stand-in label — "PNAS, 1980" — which two papers in one journal and year share, so
    /// its volume and first page join the key, and resolution tells the two apart by DOI.
    nonisolated static func scanIdentity(
        of candidate: VideoCitedPaper,
        locator: BibliographicLocator?
    ) -> String {
        guard let locator,
              candidate.doi?.nilIfBlank == nil,
              candidate.url?.nilIfBlank == nil,
              candidate.authors?.nilIfBlank == nil,
              candidate.isAttributionOnly else { return candidate.dedupKey }
        return [candidate.dedupKey, locator.volume ?? "", locator.firstPage ?? ""].joined(separator: "|")
    }

    /// Turns titles read off slides into papers with a DOI. The catalog pass is free — Crossref
    /// and OpenAlex are public APIs — so it runs first at ingest. What it cannot place is then
    /// handed to a web search (`webResolve`), and only what survives both stays `.unresolved`,
    /// still surfaced, because a failed lookup is not an absent citation.
    private func resolve(
        _ candidates: [VideoCitedPaper],
        videoContext: String?,
        aiService: AIService,
        webLookupLimit: Int?,
        locators: [String: BibliographicLocator] = [:]
    ) async -> [VideoCitedPaper] {
        var resolved = candidates
        var needsLookup: [Int] = []
        var needsRecord: [Int] = []

        for index in candidates.indices {
            var candidate = candidates[index]
            if candidate.status == .pending, candidate.url?.nilIfBlank != nil {
                continue
            }
            if let doi = candidate.doi?.nilIfBlank {
                candidate.url = "https://doi.org/\(doi)"
                candidate.status = .pending
                // A slide that printed only the DOI gave the row nothing to be called by.
                if candidate.isAttributionOnly { needsRecord.append(index) }
                resolved[index] = candidate
                continue
            }
            needsLookup.append(index)
        }

        // A DOI with no title beside it is looked up for its record, so the row reads
        // "Strategies to detect mitochondrial oxidants" rather than "Cited paper". The DOI
        // stands whether or not Crossref answers: it was printed, and it is the identity.
        for index in needsRecord {
            guard let doi = resolved[index].doi, let record = await Self.crossrefRecord(doi: doi) else { continue }
            var candidate = resolved[index]
            candidate.title = record.title
            candidate.authors = candidate.authors ?? record.authors
            candidate.journal = candidate.journal ?? record.journal
            candidate.year = candidate.year ?? record.year
            resolved[index] = candidate
        }

        // Catalog lookups run a few at a time, in order-preserving batches. A slide deck
        // cites a handful of papers; a reference list cites a hundred, and two public-API
        // round trips each, one after another, is minutes of waiting for a click. Four at a
        // time stays well inside the politeness the mailto User-Agent buys from Crossref.
        let maxConcurrentLookups = 4
        var offset = 0
        while offset < needsLookup.count {
            let end = min(offset + maxConcurrentLookups, needsLookup.count)
            let batch = needsLookup[offset..<end]
            await withTaskGroup(of: (Int, VideoCitedPaper).self) { group in
                for index in batch {
                    let candidate = candidates[index]
                    let locator = locators[candidate.id]
                    group.addTask { (index, await Self.catalogResolved(candidate, locator: locator)) }
                }
                for await (index, candidate) in group {
                    resolved[index] = candidate
                }
            }
            offset = end
        }
        return await webResolve(
            resolved,
            videoContext: videoContext,
            aiService: aiService,
            lookupLimit: webLookupLimit,
            locators: locators
        )
    }

    /// One candidate after the free catalog pass: identified with a DOI when Crossref or
    /// OpenAlex holds exactly one record matching what was read, otherwise returned as it
    /// came in for the web-search fallback to try.
    private nonisolated static func catalogResolved(
        _ candidate: VideoCitedPaper,
        locator: BibliographicLocator?
    ) async -> VideoCitedPaper {
        var candidate = candidate
        // Read before anything is filled in: the flag is derived from authors/journal/year,
        // so mutating those first would change the answer.
        let wasAttributionOnly = candidate.isAttributionOnly
        let match = wasAttributionOnly
            ? await bestAttributionMatch(for: candidate, locator: locator)
            : await bestMatch(for: candidate, locator: locator)

        if let match {
            candidate.title = Self.title(of: candidate, identifiedAs: match, wasAttributionOnly: wasAttributionOnly)
            candidate.doi = match.doi
            candidate.url = "https://doi.org/\(match.doi)"
            candidate.journal = candidate.journal ?? match.journal
            candidate.year = candidate.year ?? match.year
            candidate.status = .pending
        }
        return candidate
    }

    /// The title a candidate carries once `record` has identified it. The stand-in label gives
    /// way to the record's title. So does a printed "title" on a citation with no author that
    /// the record does not carry: only the venue, volume and page can have made that match,
    /// and the words the slide set beside them — "Selective detergents (PNAS, 1980
    /// 77:3430-4)" — were the slide's own, not the paper's. Any other printed title stays as
    /// it was read, which is also what a paper's reference rescan pairs an unmatched row by.
    nonisolated static func title(
        of candidate: VideoCitedPaper,
        identifiedAs record: ResolvedPaper,
        wasAttributionOnly: Bool
    ) -> String {
        if wasAttributionOnly { return record.title }
        guard candidate.authors?.nilIfBlank == nil,
              !titlesMatch(candidate.title, record.title) else { return candidate.title }
        return record.title
    }

    // MARK: - Web-search fallback

    /// Second-chance resolution, over the web, for what the catalog could not place.
    ///
    /// The free APIs match by string, so the citations they miss are the ones a person resolves
    /// in a single search: an abbreviated venue the journal comparison scores at zero ("JBC" vs
    /// "Journal of Biological Chemistry"), a figure credited with an author and year but no
    /// title, a slide title clipped by OCR. A web-search model finds those the way a reader
    /// would, then the returned DOI is confirmed against Crossref before anything is trusted.
    ///
    /// Each candidate is its own request on purpose: OpenRouter's fallback search engine runs
    /// one search per request, so several citations in one prompt would search for the first
    /// and guess at the rest. Ordinary per-video scans are bounded because this is the only
    /// step here that spends; the explicit all-papers lecture workflow removes that bound.
    private func webResolve(
        _ candidates: [VideoCitedPaper],
        videoContext: String?,
        aiService: AIService,
        lookupLimit: Int?,
        locators: [String: BibliographicLocator] = [:]
    ) async -> [VideoCitedPaper] {
        guard let config = KeychainService.resolveConfig(for: .citationResolution) else {
            return candidates
        }
        let unresolved = candidates.indices.filter { candidates[$0].status == .unresolved }
        guard !unresolved.isEmpty else { return candidates }

        let targeted = lookupLimit.map { Array(unresolved.prefix($0)) } ?? unresolved
        if unresolved.count > targeted.count {
            logger.warning(
                "Web citation lookup capped at \(targeted.count) of \(unresolved.count) unresolved citation(s)"
            )
        }

        let system = AITask.citationResolution.effectivePrompt ?? Prompts.citationResolution
        var result = candidates
        // The exhaustive lecture workflow can leave far more than the ordinary
        // eight-candidate ceiling. Resolve all of them, but in small batches so
        // one reference wall does not burst the account's request-rate limit.
        let maxConcurrentLookups = 4
        var offset = 0
        while offset < targeted.count {
            let end = min(offset + maxConcurrentLookups, targeted.count)
            let batch = targeted[offset..<end]
            await withTaskGroup(of: (Int, VideoCitedPaper?).self) { group in
                for index in batch {
                    let candidate = candidates[index]
                    let locator = locators[candidate.id]
                    group.addTask {
                        let resolved = await self.webResolveOne(
                            candidate, locator: locator, videoContext: videoContext,
                            system: system, config: config, aiService: aiService
                        )
                        return (index, resolved)
                    }
                }
                while let (index, resolved) = await group.next() {
                    if let resolved { result[index] = resolved }
                }
            }
            offset = end
        }
        return result
    }

    /// Resolves one candidate by web search, or returns nil to leave it `.unresolved`.
    ///
    /// Nonisolated: it touches no actor state, so the fleet of lookups a scan kicks off run in
    /// genuine parallel rather than queuing on the service's executor.
    nonisolated private func webResolveOne(
        _ candidate: VideoCitedPaper,
        locator: BibliographicLocator?,
        videoContext: String?,
        system: String,
        config: AITaskConfig,
        aiService: AIService
    ) async -> VideoCitedPaper? {
        // Derived from authors/journal/year, so read before the record below overwrites them.
        let wasAttributionOnly = candidate.isAttributionOnly
        var user = Self.webLookupPrompt(for: candidate, locator: locator)
        if let videoContext = videoContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !videoContext.isEmpty {
            user = videoContext + "\n\n" + user
        }

        let reply: String
        do {
            var accumulated = ""
            // The reply is one small JSON object, but the budget has to hold whatever the
            // model says on the way to it. At 600 every lookup of 2026-09-27 stopped on
            // "length" before the object was closed — DeepSeek V4.1 Flash reasons over the
            // search results first, and that counted against the same limit — so the whole
            // web fallback was silently dead and every citation the catalogs missed came
            // back "No matching record".
            let stream = await aiService.streamChat(
                system: system,
                messages: [(role: "user", content: user)],
                config: config,
                maxTokens: 2_000,
                webSearch: true
            )
            for try await chunk in stream {
                accumulated += chunk
            }
            reply = accumulated
        } catch {
            logger.error(
                "Web citation lookup failed for \(candidate.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        guard let doi = Self.decodeWebLookup(reply)?.nilIfBlank else { return nil }
        // The model can name a plausible DOI for the wrong paper, or a well-formed one that does
        // not exist. Confirm it against Crossref and hold the record to the same bar the catalog
        // path does — minus the journal-string agreement that abbreviations fail, which is what
        // sent this citation here to begin with.
        guard let record = await Self.crossrefRecord(doi: doi),
              Self.webMatchAccepted(read: candidate, candidate: record, locator: locator) else {
            return nil
        }

        var updated = candidate
        updated.title = Self.title(of: candidate, identifiedAs: record, wasAttributionOnly: wasAttributionOnly)
        updated.doi = record.doi
        updated.url = "https://doi.org/\(record.doi)"
        updated.journal = updated.journal ?? record.journal
        updated.year = updated.year ?? record.year
        updated.status = .pending
        return updated
    }

    /// The lines describing one citation to the web-lookup model. An attribution-only candidate
    /// has a synthetic title, so it is left out rather than fed back as if the slide printed it.
    /// A reference entry's volume and page go in when known: for a title-less entry they are
    /// most of what there is to search for.
    nonisolated static func webLookupPrompt(
        for paper: VideoCitedPaper,
        locator: BibliographicLocator? = nil
    ) -> String {
        var lines = ["Find this paper and return its DOI."]
        if !paper.isAttributionOnly { lines.append("Title: \(paper.title)") }
        if let authors = paper.authors?.nilIfBlank { lines.append("Authors: \(authors)") }
        if let journal = paper.journal?.nilIfBlank { lines.append("Journal: \(journal)") }
        if let year = paper.year?.nilIfBlank { lines.append("Year: \(year)") }
        if let volume = locator?.volume { lines.append("Volume: \(volume)") }
        if let firstPage = locator?.firstPage { lines.append("First page or article number: \(firstPage)") }
        return lines.joined(separator: "\n")
    }

    /// The DOI from the model's reply, or nil. Only the DOI is read — title, journal, and year
    /// come from the confirmed Crossref record, not the model, so their JSON type (a year is as
    /// often a number as a string) can never fail the decode and lose the one field that counts.
    nonisolated static func decodeWebLookup(_ reply: String) -> String? {
        struct Payload: Decodable { let doi: String? }
        let text = stripFences(reply)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return payload.doi
    }

    /// Whether a web-search DOI, once confirmed against Crossref, matches the slide well enough
    /// to import. Deliberately does not require the journal strings to agree: an abbreviated
    /// venue is exactly what the catalog path could not match, and re-imposing that test here
    /// would reject the very papers this fallback exists to catch. Author and year carry the
    /// check instead — the cited first author must be on the record, or (for a printed title)
    /// the titles must agree — a year on the slide must not contradict the record's beyond the
    /// online-first slack the catalog path allows, and a printed volume or page must not
    /// contradict the record's either.
    ///
    /// A printed venue, volume and first page that all agree identify the paper by themselves,
    /// as they do in the catalog pass (`venueLocatorAccepted`). Then a printed title the record
    /// does not carry — a slide's bullet read as one — no longer rejects it, and a citation
    /// with no author needs none; a printed author still has to be on the record.
    nonisolated static func webMatchAccepted(
        read: VideoCitedPaper,
        candidate: ResolvedPaper,
        locator: BibliographicLocator? = nil
    ) -> Bool {
        guard yearsAgree(read.year, candidate.year) else { return false }
        if let locator {
            if agreement(locator.volume, candidate.volume, key: volumeKey) == false { return false }
            if agreement(locator.firstPage, candidate.firstPage, key: pageKey) == false { return false }
        }
        if !read.isAttributionOnly, titlesMatch(read.title, candidate.title) { return true }
        // Whichever way each side spelt its author names.
        let authorOnRecord = firstAuthorSurname(read.authors).map { surname in
            recordSurnames(candidate.authors).contains { surnamesMatch(surname, $0) }
        }
        if let locator, venueLocatorAccepted(read: read, locator: locator, record: candidate) {
            return authorOnRecord ?? true
        }
        // Attribution-only slides have no title to compare; the cited surname has to be on
        // the record.
        guard read.isAttributionOnly else { return false }
        return authorOnRecord ?? false
    }

    /// Fetches one work by DOI. Because the lookup path's DOIs come from a model's web search,
    /// this doubles as the existence check: a hallucinated DOI 404s and resolves to nil.
    static func crossrefRecord(doi: String) async -> ResolvedPaper? {
        let trimmed = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)"),
              let json = await fetchJSON(url) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return nil }
        return parseCrossrefItem(message)
    }

    /// A candidate record from a scholarly lookup.
    struct ResolvedPaper: Sendable, Equatable {
        let doi: String
        /// Plain text: a catalog's `K<sup>+</sup>` arrives as `K⁺`.
        let title: String
        let journal: String?
        let year: String?
        /// Author names, semicolon-separated — Crossref hands over surnames, OpenAlex full
        /// display names. The only way to verify an attribution, which names an author but
        /// no title.
        let authors: String?
        let volume: String?
        /// The first page, or the article number where the journal numbers articles instead.
        let firstPage: String?
        /// The venue's abbreviated forms where the catalog lists them ("Commun Biol").
        let journalAliases: [String]

        init(
            doi: String, title: String, journal: String?, year: String?, authors: String? = nil,
            volume: String? = nil, firstPage: String? = nil, journalAliases: [String] = []
        ) {
            self.doi = doi
            self.title = title.decodingTitleMarkup()
            self.journal = journal
            self.year = year
            self.authors = authors
            self.volume = volume
            self.firstPage = firstPage
            self.journalAliases = journalAliases
        }
    }

    /// Resolve only an unambiguous exact bibliographic identity: a record whose title is the
    /// printed one, letter for letter. When the titles disagree in their words — a subtitle
    /// one side lacks, a title the list truncated — a reference entry's volume and page can
    /// still settle it, by the same test a title-less entry gets.
    static func bestMatch(
        for paper: VideoCitedPaper,
        locator: BibliographicLocator? = nil
    ) async -> ResolvedPaper? {
        var pool = await crossrefCandidates(bibliographic: paper.title, author: paper.authors)
        pool += await openAlexCandidates(search: paper.title)
        let exact = pool.filter { candidate in
            guard titlesMatch(paper.title, candidate.title) else { return false }
            return yearsAgree(paper.year, candidate.year)
        }
        let byDOI = Dictionary(grouping: exact, by: { exactIdentityKey($0.doi) })
        if byDOI.count == 1, let match = byDOI.values.first?.first { return match }
        guard let locator else { return nil }
        return await bestLocatorMatch(for: paper, locator: locator)
    }

    /// The paper a whole reference-list entry names, for the Reader's citation
    /// preview: Crossref's bibliographic matches for the entry as printed,
    /// accepted only when the record's title appears in the entry letter for
    /// letter (case, spacing and punctuation aside) and exactly one DOI does.
    /// Nil for anything else — an affiliation, a table caption, a book or
    /// dataset Crossref does not hold under that title.
    static func bestMatch(forReferenceEntry entry: String) async -> ResolvedPaper? {
        let pool = await crossrefCandidates(bibliographic: entry, author: nil)
        let printed = pool.filter { referenceEntry(entry, printsTitle: $0.title) }
        let byDOI = Dictionary(grouping: printed, by: { exactIdentityKey($0.doi) })
        guard byDOI.count == 1 else { return nil }
        return byDOI.values.first?.first
    }

    /// Whether `title` is printed in a reference entry. Compared on letters and
    /// digits alone, so a word the page split across a line ("hu man") and
    /// Crossref's inline markup (`<i>E. coli</i>`) do not matter; a title too
    /// short to identify anything by containment never matches.
    nonisolated static func referenceEntry(_ entry: String, printsTitle title: String) -> Bool {
        PDFReferenceEntries.entry(entry, printsTitle: title)
    }

    /// Whether a printed year is consistent with a catalog record's. A year off by one is
    /// the same paper: a reference list cites the issue year while Crossref's `issued` is
    /// often the online-first date, and the two straddle a New Year for a large share of
    /// papers. Two years apart is a different paper. A citation that prints no year, or a
    /// year that is not a number, constrains nothing.
    nonisolated static func yearsAgree(_ printed: String?, _ candidate: String?) -> Bool {
        guard let printedYear = printed.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            return true
        }
        guard let candidateYear = candidate.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            return false
        }
        return abs(printedYear - candidateYear) <= 1
    }

    /// Resolves a citation that printed no title.
    ///
    /// A reference-list entry prints the volume and the first page or article number, and
    /// those with the first author and the year name exactly one paper, so the locator path
    /// settles it. A slide's attribution — "Szeto et al., Br J Pharmacol, 2014" — usually
    /// carries no locator, only a first author, a venue and a year; `bestVenueAttributionMatch`
    /// asks the catalogs for everything that first author published in that venue around
    /// that year and accepts the answer only when it is one paper. It also takes over when a
    /// locator places nothing — a page misread off small print — holding every record to
    /// the locator it was given, so a volume or page that disagrees still rejects.
    static func bestAttributionMatch(
        for paper: VideoCitedPaper,
        locator: BibliographicLocator?
    ) async -> ResolvedPaper? {
        if let locator, let match = await bestLocatorMatch(for: paper, locator: locator) {
            return match
        }
        return await bestVenueAttributionMatch(for: paper, locator: locator)
    }

    // MARK: - Venue attribution matching

    /// The one catalog record a slide attribution names, or nil.
    ///
    /// This is the free path for the corner credit most figures carry, and it has to work
    /// without the web fallback. Crossref is asked for the first author's works in a year window around the printed year, ranked against the venue as
    /// printed. Crossref's ranking does not read abbreviations — "Br J Pharmacol" sinks
    /// the British Journal of Pharmacology below every "Clinical Pharmacology" hit — so when
    /// that shortlist holds nothing that agrees, the author's complete output for the window
    /// is fetched instead, but only when it is complete: an author with at most
    /// `maxAttributionPool` works in those three years. A uniqueness test over a slice of a
    /// common surname's output proves nothing, so a Cai or a Wang stops at the shortlist.
    /// Either pool is held to `attributionMatch`.
    static func bestVenueAttributionMatch(
        for paper: VideoCitedPaper,
        locator: BibliographicLocator? = nil
    ) async -> ResolvedPaper? {
        guard let surname = firstAuthorSurname(paper.authors),
              let journal = paper.journal?.nilIfBlank,
              let year = paper.year.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            return nil
        }
        let window = URLQueryItem(
            name: "filter", value: "from-pub-date:\(year - 1)-01-01,until-pub-date:\(year + 1)-12-31"
        )
        let author = URLQueryItem(name: "query.author", value: surname)
        let fields = URLQueryItem(name: "select", value: Self.crossrefWorkFields)

        let ranked = await crossrefWorkList([
            author, URLQueryItem(name: "query.bibliographic", value: journal), window,
            URLQueryItem(name: "rows", value: "20"), fields,
        ])?.works ?? []
        if let match = attributionMatch(read: paper, locator: locator, pool: ranked) { return match }
        // Several agreeing records is an ambiguity the complete list cannot undo.
        guard !ranked.contains(where: { attributionAgrees(read: paper, locator: locator, record: $0) }) else {
            return nil
        }

        guard let count = await crossrefWorkList([author, window, URLQueryItem(name: "rows", value: "0")])?.total,
              count > 0, count <= maxAttributionPool,
              let complete = await crossrefWorkList([
                  author, window, URLQueryItem(name: "rows", value: String(count)), fields,
              ]),
              complete.itemCount >= count else {
            return nil
        }
        return attributionMatch(read: paper, locator: locator, pool: complete.works)
    }

    /// The largest author output, over an attribution's three-year window, fetched whole to
    /// test an attribution for uniqueness. Crossref's page ceiling.
    static let maxAttributionPool = 1000

    /// The one paper in `pool` a title-less attribution names, or nil when none or several do.
    ///
    /// A surname and a year alone name nothing — "1954 Denham Harman" once resolved to a
    /// dairy-science meeting programme — so the printed venue is required, and every record
    /// is held to `attributionAgrees`. Agreement is not identity by itself: an author can
    /// publish twice in one journal in a year. So the answer must be a single DOI, and when
    /// the year window holds two, the one in the printed year is taken only if it stands alone.
    nonisolated static func attributionMatch(
        read: VideoCitedPaper,
        locator: BibliographicLocator? = nil,
        pool: [ResolvedPaper]
    ) -> ResolvedPaper? {
        let agreeing = pool.filter { attributionAgrees(read: read, locator: locator, record: $0) }
        let byDOI = Dictionary(grouping: agreeing, by: { exactIdentityKey($0.doi).lowercased() })
        if byDOI.count == 1 { return byDOI.values.first?.first }
        guard byDOI.count > 1, let printedYear = read.year?.nilIfBlank else { return nil }
        let sameYear = byDOI.values.compactMap(\.first).filter {
            $0.year?.trimmingCharacters(in: .whitespacesAndNewlines) == printedYear
        }
        return sameYear.count == 1 ? sameYear[0] : nil
    }

    /// Whether a catalog record fits a slide attribution: the printed surname is the record's
    /// *first* author ("Szeto et al." credits the lead author, not the last), the years agree
    /// within the online-first slack, the venue agrees abbreviation-aware, and every other
    /// surname the slide printed is on the record. A volume or first page the slide printed
    /// must not contradict the record's. A notice attached to a paper — an erratum, a
    /// correction — carries the paper's authors and venue and is never the citation.
    nonisolated static func attributionAgrees(
        read: VideoCitedPaper,
        locator: BibliographicLocator? = nil,
        record: ResolvedPaper
    ) -> Bool {
        let printedSurnames = (read.authors ?? "").split(separator: ";")
            .compactMap { surname(inAuthorEntry: String($0)) }
        guard let first = printedSurnames.first,
              let printedJournal = read.journal?.nilIfBlank,
              read.year?.nilIfBlank != nil,
              !isAttachedNotice(record.title) else { return false }
        let recordAuthors = recordSurnames(record.authors)
        guard let recordFirst = recordAuthors.first, surnamesMatch(first, recordFirst),
              yearsAgree(read.year, record.year) else { return false }
        if let locator {
            if agreement(locator.volume, record.volume, key: volumeKey) == false { return false }
            if agreement(locator.firstPage, record.firstPage, key: pageKey) == false { return false }
        }
        guard ([record.journal] + record.journalAliases)
            .compactMap({ $0 })
            .contains(where: { journalsCompatible(printedJournal, $0) }) else { return false }
        return printedSurnames.dropFirst().allSatisfy { coauthor in
            recordAuthors.contains { coauthorMatches(coauthor, $0) }
        }
    }

    /// A co-author as a slide prints it against a record's. Looser than `surnamesMatch` by a
    /// clipped ending — a slide's small print read "Tamminen" for Tammineni — because the
    /// co-author only narrows a first author already confirmed; it never identifies alone.
    private nonisolated static func coauthorMatches(_ printed: String, _ record: String) -> Bool {
        if surnamesMatch(printed, record) { return true }
        let a = surnameKey(printed), b = surnameKey(record)
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 5 && long.hasPrefix(short)
    }

    private nonisolated static let attachedNoticePrefixes = [
        "erratum", "errata", "correction", "corrigendum", "author correction", "publisher correction",
        "retraction", "retracted", "expression of concern", "addendum",
    ]

    private nonisolated static func isAttachedNotice(_ title: String) -> Bool {
        let key = exactIdentityKey(title).lowercased()
        return attachedNoticePrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - Locator matching

    /// The one catalog record a reference entry's author, year, volume and page point at, or
    /// nil when the catalogs hold none or more than one.
    ///
    /// OpenAlex is asked first, because it indexes exactly these fields: the first author's
    /// name, a year window, the volume and the first page. A journal that numbers articles
    /// instead of paging them ("J. Clin. Invest. 131, e136055") files under no first page
    /// there, so a miss is retried without the page; that shortlist is then held to the venue
    /// as well, and the article number is confirmed against Crossref, which does record it.
    /// Crossref's bibliographic search — built to take a reference entry whole — is the last
    /// resort. Every record from every pool passes the same `locatorAccepted` test, and the
    /// answer has to be one DOI. A citation that prints no author is placed by its venue
    /// instead (`bestVenueLocatorMatch`).
    static func bestLocatorMatch(
        for paper: VideoCitedPaper,
        locator: BibliographicLocator
    ) async -> ResolvedPaper? {
        guard let surname = firstAuthorSurname(paper.authors) else {
            return await bestVenueLocatorMatch(for: paper, locator: locator)
        }
        let year = paper.year.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var pool = await openAlexLocatorCandidates(
            surname: surname, year: year, volume: locator.volume, firstPage: locator.firstPage
        )
        if pool.isEmpty, locator.volume != nil, locator.firstPage != nil {
            pool = await openAlexLocatorCandidates(
                surname: surname, year: year, volume: locator.volume, firstPage: nil
            )
        }
        var accepted = pool.filter { locatorAccepted(read: paper, locator: locator, record: $0) }
        if accepted.isEmpty {
            let entry = [paper.authors ?? surname, paper.journal, locator.volume, locator.firstPage, paper.year]
                .compactMap { $0?.nilIfBlank }
                .joined(separator: " ")
            accepted = await crossrefCandidates(bibliographic: entry, author: nil)
                .filter { locatorAccepted(read: paper, locator: locator, record: $0) }
        }

        // Records the catalog itself settled: the page agreed, or the entry printed none.
        let printedPage = locator.firstPage
        let settled = accepted.filter { printedPage == nil || $0.firstPage != nil }
        let settledByDOI = Dictionary(grouping: settled, by: { exactIdentityKey($0.doi) })
        if settledByDOI.count == 1, let match = settledByDOI.values.first?.first { return match }
        guard settledByDOI.isEmpty, let printedPage else { return nil }

        // What is left agrees on author, year, volume and venue but files no page: an
        // article-numbered journal, where a common surname can put several of the year's
        // articles on the shortlist. Crossref records the article number, so it settles
        // which one prints the number the entry did. A lone candidate whose Crossref record
        // has no page either — or cannot be fetched — stands on the agreement it has; a
        // record that prints a different number is a different paper.
        var unpaged: [ResolvedPaper] = []
        var seenDOIs = Set<String>()
        for record in accepted where record.firstPage == nil && seenDOIs.insert(exactIdentityKey(record.doi)).inserted {
            unpaged.append(record)
        }
        let shortlist = Array(unpaged.prefix(12))
        let confirmed = await withTaskGroup(of: (Int, ResolvedPaper?, Bool).self) { group in
            for (index, record) in shortlist.enumerated() {
                group.addTask {
                    let crossref = await crossrefRecord(doi: record.doi)
                    return (index, crossref, crossref?.firstPage != nil)
                }
            }
            var results: [(Int, ResolvedPaper?, Bool)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        var matches: [ResolvedPaper] = []
        for (index, crossref, hasPage) in confirmed {
            let record = shortlist[index]
            if let crossref, hasPage, let recordPage = crossref.firstPage {
                guard pageKey(recordPage) == pageKey(printedPage) else { continue }
                matches.append(ResolvedPaper(
                    doi: record.doi, title: record.title, journal: record.journal ?? crossref.journal,
                    year: record.year ?? crossref.year, authors: record.authors ?? crossref.authors,
                    volume: record.volume ?? crossref.volume, firstPage: recordPage,
                    journalAliases: record.journalAliases + crossref.journalAliases
                ))
            } else if shortlist.count == 1 {
                matches.append(record)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The one catalog record a citation's venue, volume and first page point at, for a
    /// citation that prints no author — "Selective detergents (PNAS, 1980 77:3430-4)" on a
    /// slide. OpenAlex is asked for the works at that volume and first page in the year
    /// window, and Crossref's bibliographic search takes the citation whole when that finds
    /// nothing, as on the author path. With no author to hold a record to, each is held to
    /// `venueLocatorAccepted`, and the answer has to be one DOI.
    static func bestVenueLocatorMatch(
        for paper: VideoCitedPaper,
        locator: BibliographicLocator
    ) async -> ResolvedPaper? {
        guard let journal = paper.journal?.nilIfBlank,
              let volume = locator.volume,
              let firstPage = locator.firstPage else { return nil }
        let year = paper.year.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var accepted = await openAlexLocatorCandidates(
            surname: nil, year: year, volume: volume, firstPage: firstPage
        ).filter { venueLocatorAccepted(read: paper, locator: locator, record: $0) }
        if accepted.isEmpty {
            let entry = [journal, volume, firstPage, paper.year?.nilIfBlank]
                .compactMap { $0 }
                .joined(separator: " ")
            accepted = await crossrefCandidates(bibliographic: entry, author: nil)
                .filter { venueLocatorAccepted(read: paper, locator: locator, record: $0) }
        }
        let byDOI = Dictionary(grouping: accepted, by: { exactIdentityKey($0.doi) })
        guard byDOI.count == 1 else { return nil }
        return byDOI.values.first?.first
    }

    /// Whether a catalog record is the paper a citation's venue, volume and first page point
    /// at, with no author to hold the record to. All three have to be printed and all three
    /// have to agree — the venue abbreviation-aware, since "PNAS" is how a slide prints the
    /// Proceedings of the National Academy of Sciences — and a printed year has to agree too.
    /// A notice attached to a paper is never the citation.
    nonisolated static func venueLocatorAccepted(
        read: VideoCitedPaper,
        locator: BibliographicLocator,
        record: ResolvedPaper
    ) -> Bool {
        guard let printed = read.journal?.nilIfBlank,
              agreement(locator.volume, record.volume, key: volumeKey) == true,
              agreement(locator.firstPage, record.firstPage, key: pageKey) == true,
              yearsAgree(read.year, record.year),
              !isAttachedNotice(record.title) else { return false }
        return ([record.journal] + record.journalAliases)
            .compactMap { $0 }
            .contains { journalsCompatible(printed, $0) }
    }

    /// Whether a catalog record is the paper a reference entry's locator points at.
    ///
    /// The first author's surname must be on the record and the year must agree (with the
    /// online-first slack the title path allows). Then the locator: a volume or page the
    /// record prints differently rejects it outright, and the record is accepted when both
    /// volume and page agree, or when one of them agrees and the venue does too — the venue
    /// compared abbreviation-aware, since that is how reference lists print it. A record that
    /// confirms neither volume nor page is not identified, however well the venue and year fit.
    nonisolated static func locatorAccepted(
        read: VideoCitedPaper,
        locator: BibliographicLocator,
        record: ResolvedPaper
    ) -> Bool {
        guard let surname = firstAuthorSurname(read.authors),
              recordSurnames(record.authors).contains(where: { surnamesMatch(surname, $0) }),
              yearsAgree(read.year, record.year) else { return false }

        let volumeAgrees = agreement(locator.volume, record.volume, key: volumeKey)
        let pageAgrees = agreement(locator.firstPage, record.firstPage, key: pageKey)
        if volumeAgrees == false || pageAgrees == false { return false }
        if volumeAgrees == true && pageAgrees == true { return true }
        guard volumeAgrees == true || pageAgrees == true, let printed = read.journal?.nilIfBlank else {
            return false
        }
        return ([record.journal] + record.journalAliases)
            .compactMap { $0 }
            .contains { journalsCompatible(printed, $0) }
    }

    /// Agreement between a printed value and a record's: nil when either side is missing,
    /// so a missing value neither confirms nor contradicts.
    private nonisolated static func agreement(
        _ printed: String?, _ record: String?, key: (String) -> String
    ) -> Bool? {
        guard let printed = printed?.nilIfBlank, let record = record?.nilIfBlank else { return nil }
        return key(printed) == key(record)
    }

    nonisolated static func volumeKey(_ value: String) -> String {
        exactIdentityKey(value).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// "e136055", "E136055" and "136055" are one article number; "022" and "22" one page.
    nonisolated static func pageKey(_ value: String) -> String {
        var key = exactIdentityKey(value).lowercased().filter { $0.isLetter || $0.isNumber }
        if key.first == "e", key.dropFirst().allSatisfy(\.isNumber), key.count > 1 { key.removeFirst() }
        while key.count > 1, key.first == "0" { key.removeFirst() }
        return key
    }

    /// OpenAlex works filtered on exactly what a reference entry prints. The author filter is
    /// a name search, so it takes the surname as printed, diacritics included — OpenAlex
    /// indexes "Desdín-Micó" and does not find it under "Desdin-Mico". Without a surname the
    /// volume and page are shared across journals, so the page of results is wider, and the
    /// caller holds each to the venue.
    private static func openAlexLocatorCandidates(
        surname: String?,
        year: Int?,
        volume: String?,
        firstPage: String?
    ) async -> [ResolvedPaper] {
        var filters: [String] = []
        if let surname { filters.append("raw_author_name.search:\(surname.filter { $0 != "," && $0 != ":" })") }
        if let year { filters.append("publication_year:\(year - 1)-\(year + 1)") }
        if let volume = volume.map(volumeKey), !volume.isEmpty { filters.append("biblio.volume:\(volume)") }
        if let firstPage = firstPage?.nilIfBlank { filters.append("biblio.first_page:\(firstPage)") }
        guard !filters.isEmpty,
              var components = URLComponents(string: "https://api.openalex.org/works") else { return [] }
        let perPage = surname == nil ? "50" : (firstPage == nil ? "100" : "10")
        components.queryItems = [
            URLQueryItem(name: "filter", value: filters.joined(separator: ",")),
            URLQueryItem(name: "per-page", value: perPage),
            URLQueryItem(name: "select", value: "doi,title,biblio,publication_year,authorships,primary_location"),
        ]
        guard let url = components.url,
              let json = await fetchJSON(url) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap(parseOpenAlexWork)
    }

    // MARK: - Names and venues

    /// The first author's surname out of an authors string, whichever way the source wrote
    /// it: "Argov, Z.; Bank, W. J.", "Sturm", "Naviaux, R. K. et al.", "Denham Harman".
    nonisolated static func firstAuthorSurname(_ authors: String?) -> String? {
        guard let first = authors?.split(separator: ";").first else { return nil }
        return surname(inAuthorEntry: String(first))
    }

    /// Each author on a catalog record, reduced to a surname. Crossref hands over family
    /// names already; OpenAlex hands over display names.
    private nonisolated static func recordSurnames(_ authors: String?) -> [String] {
        guard let authors else { return [] }
        return authors.split(separator: ";").compactMap { surname(inAuthorEntry: String($0)) }
    }

    /// The surname in one author entry. Before the comma when there is one ("Argov, Z.");
    /// otherwise the last word that is not an initial, with any lowercase particles in front
    /// of it kept ("Z. Argov", "Gabriel Sturm", "J. van der Berg", "Argov Z").
    nonisolated static func surname(inAuthorEntry entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["et al.", "et al", "and others"] where text.lowercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = text.last, last == "," || last == " " { text.removeLast() }
        }
        if let comma = text.firstIndex(of: ",") {
            text = String(text[..<comma])
        }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !isInitial($0) }
        guard let last = words.last else { return nil }
        var surname = [last]
        var index = words.count - 2
        while index >= 0, isNameParticle(words[index]) {
            surname.insert(words[index], at: 0)
            index -= 1
        }
        return surname.joined(separator: " ").nilIfBlank
    }

    /// "Z.", "WJ", "R.K." — one to three letters, capitals, periods optional.
    private nonisolated static func isInitial(_ word: String) -> Bool {
        let letters = word.filter { $0 != "." }
        guard !letters.isEmpty, letters.count <= 3, word.count <= 6 else { return false }
        return letters.allSatisfy { $0.isUppercase }
    }

    private nonisolated static let nameParticles: Set<String> = [
        "van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "la", "le", "ten", "ter", "af", "zu",
    ]

    private nonisolated static func isNameParticle(_ word: String) -> Bool {
        nameParticles.contains(word.lowercased())
    }

    /// Whether two surnames are the same name: the same letters once case, diacritics, spaces
    /// and hyphens are folded away, or one ending in the other where a record kept the
    /// particles a list dropped ("Berg" against "van der Berg").
    nonisolated static func surnamesMatch(_ a: String, _ b: String) -> Bool {
        let keyA = surnameKey(a)
        let keyB = surnameKey(b)
        guard !keyA.isEmpty, !keyB.isEmpty else { return false }
        if keyA == keyB { return true }
        let (short, long) = keyA.count < keyB.count ? (keyA, keyB) : (keyB, keyA)
        return short.count >= 4 && long.hasSuffix(short)
    }

    private nonisolated static func surnameKey(_ value: String) -> String {
        exactIdentityKey(value).lowercased().filter(\.isLetter)
    }

    /// Whether a venue as a reference list prints it names the venue a catalog record holds.
    ///
    /// Reference lists abbreviate: "Commun. Biol." for Communications Biology, "J. Clin.
    /// Invest." for the Journal of Clinical Investigation, "Proc Natl Acad Sci USA", "JBC".
    /// So the printed words are read as abbreviations of the record's, in order: each opens
    /// the record's next word ("commun" → "communications") or is spelt from its letters in
    /// that order ("natl" → "national"), and a single printed word may be the initials of the
    /// record's words. Every record word has to be accounted for — "Nature" is not Nature
    /// Metabolism, and BMC Medicine is not BMC Emergency Medicine — while one printed word
    /// may go spare on a longer name, for the "USA" a record's title does not carry.
    nonisolated static func journalsCompatible(_ printed: String, _ record: String) -> Bool {
        let printedTokens = venueTokens(printed)
        let recordTokens = venueTokens(record)
        guard !printedTokens.isEmpty, !recordTokens.isEmpty else { return false }
        if printedTokens == recordTokens { return true }
        if printedTokens.count == 1, printedTokens[0].count >= 2, recordTokens.count >= 2,
           printedTokens[0] == recordTokens.compactMap(\.first).map(String.init).joined() {
            return true
        }
        var recordIndex = 0
        var spare = 0
        for token in printedTokens {
            if recordIndex < recordTokens.count, abbreviation(token, opens: recordTokens[recordIndex]) {
                recordIndex += 1
            } else {
                spare += 1
            }
        }
        return recordIndex == recordTokens.count && spare <= (printedTokens.count >= 3 ? 1 : 0)
    }

    private nonisolated static let venueStopwords: Set<String> = [
        "of", "the", "and", "for", "in", "on", "de", "la", "le", "des", "et", "a", "an", "der", "und", "du", "di", "del",
    ]

    private nonisolated static func venueTokens(_ value: String) -> [String] {
        // Crossref's container titles keep their HTML entities: "Trends in Endocrinology &amp;
        // Metabolism". Left in, "amp" is a venue word nothing printed accounts for.
        exactIdentityKey(value.replacingOccurrences(of: "&amp;", with: "&")).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !venueStopwords.contains($0) }
    }

    /// Whether `token` abbreviates `word`: opens it, or spells it from its letters in order.
    private nonisolated static func abbreviation(_ token: String, opens word: String) -> Bool {
        if word.hasPrefix(token) { return true }
        guard token.count >= 3, token.first == word.first else { return false }
        var remainder = word[...]
        for letter in token {
            guard let index = remainder.firstIndex(of: letter) else { return false }
            remainder = remainder[remainder.index(after: index)...]
        }
        return true
    }

    private static func crossrefCandidates(bibliographic: String, author: String?) async -> [ResolvedPaper] {
        let items = [URLQueryItem(name: "query.bibliographic", value: bibliographic),
                     URLQueryItem(name: "rows", value: "5"),
                     URLQueryItem(name: "select", value: Self.crossrefWorkFields)]
        return await crossrefWorks(items)
    }

    private static let crossrefWorkFields =
        "DOI,title,container-title,short-container-title,issued,author,volume,page,article-number"

    private static func crossrefWorks(_ items: [URLQueryItem]) async -> [ResolvedPaper] {
        await crossrefWorkList(items)?.works ?? []
    }

    /// One page of a Crossref `/works` query: how many works match in all, how many items
    /// the page carried (title-less ones included, so a caller can tell a page that holds
    /// every match from one that does not), and the usable ones. Nil when the request failed.
    private static func crossrefWorkList(
        _ items: [URLQueryItem]
    ) async -> (total: Int, itemCount: Int, works: [ResolvedPaper])? {
        guard var components = URLComponents(string: "https://api.crossref.org/works") else { return nil }
        components.queryItems = items
        guard let url = components.url,
              let json = await fetchJSON(url) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let rawItems = message["items"] as? [[String: Any]] else { return nil }

        return (
            total: message["total-results"] as? Int ?? rawItems.count,
            itemCount: rawItems.count,
            works: rawItems.compactMap(parseCrossrefItem)
        )
    }

    /// One Crossref work — an entry from a `/works` search or the `message` of a `/works/{doi}`
    /// fetch — as a `ResolvedPaper`, or nil when it carries no usable title.
    nonisolated static func parseCrossrefItem(_ item: [String: Any]) -> ResolvedPaper? {
        guard let doi = item["DOI"] as? String,
              // Crossref returns title-less records (theses, datasets) that would
              // otherwise occupy the top slot and sink the whole lookup.
              let title = (item["title"] as? [String])?.first, !title.isEmpty else { return nil }
        let year = ((item["issued"] as? [String: Any])?["date-parts"] as? [[Int?]])?
            .first?.first.flatMap { $0 }
        let authors = (item["author"] as? [[String: Any]])?
            .compactMap { $0["family"] as? String }
            .joined(separator: "; ")
        // A paged article prints its range; an article-numbered one prints the number instead.
        let firstPage = (item["page"] as? String)?.nilIfBlank.map(BibliographicLocator.firstPage(of:))
            ?? (item["article-number"] as? String)?.nilIfBlank
        return ResolvedPaper(
            doi: doi,
            title: title,
            journal: (item["container-title"] as? [String])?.first,
            year: year.map(String.init),
            authors: authors?.nilIfBlank,
            volume: (item["volume"] as? String)?.nilIfBlank,
            firstPage: firstPage,
            journalAliases: (item["short-container-title"] as? [String]) ?? []
        )
    }

    private static func openAlexCandidates(search: String) async -> [ResolvedPaper] {
        guard var components = URLComponents(string: "https://api.openalex.org/works") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "search", value: search),
            URLQueryItem(name: "per-page", value: "5"),
        ]
        guard let url = components.url,
              let json = await fetchJSON(url) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.compactMap(parseOpenAlexWork)
    }

    /// One OpenAlex work as a `ResolvedPaper`, or nil when it has no title or DOI.
    nonisolated static func parseOpenAlexWork(_ work: [String: Any]) -> ResolvedPaper? {
        guard let title = work["title"] as? String, !title.isEmpty,
              let rawDOI = work["doi"] as? String else { return nil }
        let doi = rawDOI
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://dx.doi.org/", with: "")
        guard !doi.isEmpty else { return nil }
        let journal = ((work["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String
        let authors = (work["authorships"] as? [[String: Any]])?
            .compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
            .joined(separator: "; ")
        let biblio = work["biblio"] as? [String: Any]
        return ResolvedPaper(
            doi: doi,
            title: title,
            journal: journal,
            year: (work["publication_year"] as? Int).map(String.init),
            authors: authors?.nilIfBlank,
            volume: (biblio?["volume"] as? String)?.nilIfBlank,
            firstPage: (biblio?["first_page"] as? String)?.nilIfBlank
        )
    }

    private static func fetchJSON(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Crossref and OpenAlex both ask for a contact address and give politer rate limits
        // to requests that carry one.
        request.setValue("ForeverLM (mailto:support@foreverlm.com)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Whether a title read off a slide or out of a reference list names the same paper as a
    /// catalog record's title.
    ///
    /// Compared letter for letter, but only the letters: case, diacritics, spacing and every
    /// punctuation mark are folded away first. A reference list prints "NAD^(+) repletion" and
    /// "Mitochondrial–nuclear communications" where Crossref holds "NAD+ Repletion" and
    /// "Mitochondrial-nuclear communications", and a title ending in a period is the same
    /// title. Scripts fold the same way: a slide's "H2O2" is the catalog's
    /// `H<sub>2</sub>O<sub>2</sub>`, which the library keeps as "H₂O₂". What still fails is
    /// any difference in the words themselves — a truncated title, a subtitle one side has and
    /// the other lacks, another paper — which is the identity question this exists to answer.
    nonisolated static func titlesMatch(_ read: String, _ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let readKey = titleIdentityKey(read)
        return !readKey.isEmpty && readKey == titleIdentityKey(candidate)
    }

    private nonisolated static func titleIdentityKey(_ value: String) -> String {
        let plain = value.decodingTitleMarkup().precomposedStringWithCompatibilityMapping
        return String(exactIdentityKey(plain).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    nonisolated static func journalsMatch(_ slide: String, _ candidate: String) -> Bool {
        exactIdentityKey(slide) == exactIdentityKey(candidate)
    }

    nonisolated static func titleOverlap(_ read: String, _ candidate: String) -> Double {
        titlesMatch(read, candidate) ? 1 : 0
    }

    private nonisolated static func exactIdentityKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
