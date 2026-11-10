import Foundation
import OSLog

private let slideCitationLogger = Logger(subsystem: "com.foreverlm", category: "SlideCitations")

/// Slides and the papers they cite, for any video the app can read frames from — a
/// YouTube lecture, or a meeting recording in Google Drive or a local folder.
///
/// Both steps are opt-in per video and never run at ingest: `extractSlideFrames`
/// (the reader's "Show slides" button) captures the deck's frames, and the paper
/// scan below reads them for citations only when the learner asks. Capture streams
/// or decodes the whole video and the scan spends a vision call per slide, so
/// neither is worth paying for on a video no one opens.
extension StudioViewModel {

    // MARK: - Extract slides (Step 1, opt-in, no AI)

    /// Whether this source is one the app can read video frames from at all.
    ///
    /// Two routes exist and neither is a special case of a named provider: a YouTube URL is
    /// read through YouTube's storyboards, and a meeting is read from its recording file,
    /// wherever that recording lives. A meeting without a recording still passes here and
    /// fails later with the specific reason, which is a better message than refusing the
    /// whole source type up front.
    static func supportsSlideExtraction(_ article: StudioArticle) -> Bool {
        YouTubeTranscriptService.isYouTubeURL(article.url) || article.sourceType == .meeting
    }

    /// "Show individual slides" — opt-in, on-demand extraction of a video's slide
    /// frames so the reader can render them inline against the transcript. No AI
    /// and no paper scan; reading the slides for cited papers is a separate,
    /// explicit step (`extractPapersFromSlides`). Idempotent — a video that
    /// already has its slides just returns. Capture reads the whole video for
    /// full-resolution frames, so this runs only when the learner asks, never at
    /// ingest.
    ///
    /// Returns true when the video's slides are available afterwards (freshly
    /// extracted or already present), false when there was nothing to show (not a
    /// video frames can be read from, no stored content, extraction failed, or no
    /// slides on screen) — the reason is surfaced by a toast.
    @discardableResult
    func extractSlideFrames(for sourceID: String) async -> Bool {
        guard let article = articles.first(where: { $0.id == sourceID }) else { return false }
        guard Self.supportsSlideExtraction(article) else {
            showToast("Slides can only be shown for YouTube videos and meeting recordings.")
            return false
        }
        guard let content = await storage.loadSourceContent(sourceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            showToast("\(article.title) has no transcript yet, so there are no slides to show.")
            return false
        }
        // Already captured: the reader is already showing them, so this is a no-op
        // rather than a second (expensive) pass over the video.
        guard !SlideFrameExtraction.containsSlideSection(content) else { return true }

        showToast("Finding slides in \(article.title)…")
        guard let extracted = await extractingSlideContent(
            for: sourceID, article: article, content: content
        ) else {
            return false
        }
        showToast("Found \(extracted.slideCount) slide\(extracted.slideCount == 1 ? "" : "s") in \(article.title).")
        return true
    }

    /// Captures a video's slide frames into its stored content when they are not
    /// there yet, writing the updated content back to storage and the in-memory
    /// source. Returns the new content and how many slides were captured, or nil
    /// on a failure or an empty result (a toast already explains). The caller is
    /// responsible for the "already extracted" fast path — this always extracts.
    ///
    /// Shared by the opt-in "Show slides" button and the paper scan's catch-up
    /// path (a video whose slides were never captured), so choosing the extractor
    /// and handling its failures lives in one place.
    private func extractingSlideContent(
        for sourceID: String,
        article: StudioArticle,
        content: String
    ) async -> (content: String, slideCount: Int)? {
        let extraction: SlideFrameExtraction.AppendResult
        if YouTubeTranscriptService.isYouTubeURL(article.url) {
            extraction = await YouTubeSlideExtractionService.shared.appendingSlideContext(
                to: content,
                videoURL: article.url,
                sourceID: sourceID,
                videoTitle: article.title
            )
        } else {
            // A meeting recording has no storyboard to read, so the frames are decoded from
            // the file itself — the same one playback and transcription already use, resolved
            // through the Drive cache when the recording lives there.
            do {
                let mediaURL = try await meetingRecordingURL(for: sourceID)
                extraction = await RecordingSlideExtractionService.shared.appendingSlideContext(
                    to: content,
                    mediaURL: mediaURL,
                    sourceID: sourceID,
                    videoTitle: article.title
                )
            } catch {
                showToast("Couldn't read slides: \(error.localizedDescription)")
                return nil
            }
        }
        if let message = extraction.errorMessage {
            showToast("Couldn't read slides: \(message)")
            return nil
        }
        guard extraction.slideCount > 0 else {
            showToast("No slides could be extracted from \(article.title).")
            return nil
        }
        if let index = articles.firstIndex(where: { $0.id == sourceID }) {
            articles[index].content = extraction.content
            articles[index].wordCount = extraction.content.split(separator: " ").count
            do {
                try await storage.saveSource(articles[index])
            } catch {
                logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (extraction.content, extraction.slideCount)
    }

    // MARK: - Extract papers from slides (Step 2, opt-in, vision model)

    /// "Extract papers" from the reader action bar or a video's context menu.
    ///
    /// Reads the video's already-shown slides for the papers they cite. When the
    /// slides were never captured (a video whose reader was never opened, or one
    /// ingested before this feature existed), it captures them first — the same
    /// catch-up path the MCP tool takes — since the transcript fetch returns early
    /// once a transcript is cached and so never re-runs extraction.
    func extractPapersFromSlides(for sourceID: String) async {
        guard let article = articles.first(where: { $0.id == sourceID }) else { return }
        guard Self.supportsSlideExtraction(article) else {
            showToast("Slides can only be read from YouTube videos and meeting recordings.")
            return
        }
        guard var content = await storage.loadSourceContent(sourceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            showToast("\(article.title) has no transcript yet, so there are no slides to read.")
            return
        }

        showToast("Reading slides in \(article.title)…")

        if !SlideFrameExtraction.containsSlideSection(content) {
            guard let extracted = await extractingSlideContent(
                for: sourceID, article: article, content: content
            ) else {
                return
            }
            content = extracted.content
        }

        // A deck captured on the other Mac has no frames here to read until
        // they are taken again from the video.
        let deck = content
        let slides = await Task.detached(priority: .utility) {
            YouTubeSlideContentParser.parse(deck).slides
        }.value
        await SlideFrameRestorer.shared.restore(slides, of: article, storage: storage)

        let existingKeys = Set(
            (try? await storage.loadVideoCitedPapers(forSourceID: sourceID))?.map(\.dedupKey) ?? []
        )
        do {
            let result = try await SlideCitationService.shared.scan(
                source: AIUsageSource(source: article),
                sourceContent: content,
                videoContext: slideCitationVideoContext(for: sourceID),
                aiService: aiService
            )
            // Existing rows are left alone: their status is a decision already made, and a
            // rescan must not put back what was imported or waved off.
            var added = 0
            var alreadyHeld = 0
            for candidate in result.candidates where !existingKeys.contains(candidate.dedupKey) {
                let stamped = markingIfAlreadyInLibrary(candidate)
                if stamped.status == .imported { alreadyHeld += 1 } else { added += 1 }
                try await storage.saveVideoCitedPaper(stamped)
            }
            await markNonSlideFrames(result, sourceID: sourceID, content: content)
            noteCitedPapersChanged()

            if added == 0 && alreadyHeld == 0 {
                showToast(result.candidates.isEmpty
                    ? "No papers were cited on \(article.title)'s slides."
                    : "No new papers — \(article.title) was already up to date.")
            } else {
                var parts: [String] = []
                if added > 0 { parts.append("\(added) new paper\(added == 1 ? "" : "s")") }
                if alreadyHeld > 0 { parts.append("\(alreadyHeld) already in your library") }
                showToast("\(article.title): \(parts.joined(separator: ", ")).")
            }
            // A slide that could not be read is not a slide with no papers on it.
            if !result.isComplete {
                showToast("\(result.slidesFailed) slide\(result.slidesFailed == 1 ? "" : "s") couldn't be read.")
            }
        } catch {
            showToast("Couldn't read slides: \(error.localizedDescription)")
        }
    }

    /// Read a meeting's complete stored transcript and notes for papers that
    /// participants explicitly mentioned. This is deliberately user-initiated:
    /// a long meeting can require several configured background-model calls and
    /// citation lookups, while many recordings are never opened.
    func extractMentionedPapersFromMeeting(for sourceID: String) async {
        guard let article = articles.first(where: { $0.id == sourceID }),
              article.sourceType == .meeting else {
            showToast("Mentioned papers can only be read from a meeting.")
            return
        }
        let loadedArtifacts = (try? await storage.loadMeetingArtifacts(sourceID: sourceID)) ?? []
        let artifacts = meetingArtifactsBySourceId[sourceID] ?? loadedArtifacts
        if artifacts.contains(where: { $0.kind == .recording }) {
            do {
                if try await ensureMeetingTranscript(for: sourceID) {
                    showToast("Transcribed \(article.title). Finding mentioned papers…")
                }
            } catch MeetingTranscriptError.ownTranscriptionDisabled {
                // Not a failure: ForeverLM is set to read Google's transcript
                // rather than make one. Whatever notes the import did bring back
                // still name papers, so read those instead of abandoning the run.
            } catch {
                showToast("Couldn't transcribe meeting: \(error.localizedDescription)")
                return
            }
        }
        let storedContent = await storage.loadSourceContent(sourceID)
        let normalizedStoredContent = await Task.detached(priority: .utility) {
            storedContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        let content: String
        guard let stored = normalizedStoredContent, !stored.isEmpty else {
            showToast("This meeting has no transcript or notes to read.")
            return
        }
        content = stored
        guard let config = KeychainService.resolveConfig(for: .meetingPaperDiscovery) else {
            showToast(
                KeychainService.backgroundAIUnavailableMessage(for: .meetingPaperDiscovery)
                    ?? "Meeting Paper Discovery is not configured."
            )
            return
        }

        showToast("Finding papers mentioned in \(article.title)…")
        let chunks = await Task.detached(priority: .userInitiated) {
            SlideCitationService.materialChunks(content)
        }.value
        let existingKeys = Set(
            (try? await storage.loadVideoCitedPapers(forSourceID: sourceID))?.map(\.dedupKey) ?? []
        )

        do {
            let candidates = try await AIUsageAttribution.withSource(
                AIUsageSource(source: article)
            ) {
                var citations: [SlideCitationService.ExtractedCitation] = []
                for chunk in chunks {
                    citations += try await aiService.discoverMeetingPaperCitations(
                        meetingTitle: article.title,
                        content: chunk,
                        config: config
                    )
                }
                return await SlideCitationService.shared.resolveExtractedCitations(
                    citations,
                    sourceID: sourceID,
                    sourceText: content,
                    context: "Meeting: \(article.title)",
                    aiService: aiService
                )
            }

            var added = 0
            var alreadyHeld = 0
            for candidate in candidates where !existingKeys.contains(candidate.dedupKey) {
                let stamped = markingIfAlreadyInLibrary(candidate)
                if stamped.status == .imported { alreadyHeld += 1 } else { added += 1 }
                try await storage.saveVideoCitedPaper(stamped)
            }
            noteCitedPapersChanged()

            if added == 0 && alreadyHeld == 0 {
                showToast(candidates.isEmpty
                    ? "No papers were explicitly mentioned in \(article.title)."
                    : "No new papers — \(article.title) was already up to date.")
            } else {
                var parts: [String] = []
                if added > 0 { parts.append("\(added) new paper\(added == 1 ? "" : "s")") }
                if alreadyHeld > 0 { parts.append("\(alreadyHeld) already in your library") }
                showToast("\(article.title): \(parts.joined(separator: ", ")).")
            }
        } catch {
            // A failed chunk is a failed scan, not evidence that the meeting
            // mentioned no papers. Persist nothing and surface the real error.
            showToast("Couldn't find mentioned papers: \(error.localizedDescription)")
        }
    }

    /// "Find Papers on This Slide" from a slide thumbnail in the transcript.
    ///
    /// The cheap counterpart to `extractPapersFromSlides`: the learner can see the citation
    /// on the slide in front of them, so reading the other thirty-nine to find it is spend
    /// with no question behind it. Returns the video's candidates so the reader can show the
    /// result without a reload.
    @discardableResult
    func extractPapersFromSlide(
        sourceID: String,
        slide: YouTubeSlideFrameContext
    ) async -> [VideoCitedPaper] {
        let existingKeys = Set(
            (try? await storage.loadVideoCitedPapers(forSourceID: sourceID))?.map(\.dedupKey) ?? []
        )
        do {
            guard let article = articles.first(where: { $0.id == sourceID }) else {
                showToast("Couldn't find the source for this slide.")
                return await loadCitedPapers(forSourceID: sourceID)
            }
            await SlideFrameRestorer.shared.restore([slide], of: article, storage: storage)
            let result = try await SlideCitationService.shared.scanSlide(
                source: AIUsageSource(source: article),
                slide: slide,
                videoContext: slideCitationVideoContext(for: sourceID),
                aiService: aiService
            )
            // Existing rows are decisions already made; a rescan must not put back what was
            // imported or waved off.
            var added = 0
            for candidate in result.candidates where !existingKeys.contains(candidate.dedupKey) {
                try await storage.saveVideoCitedPaper(markingIfAlreadyInLibrary(candidate))
                added += 1
            }
            noteCitedPapersChanged()

            // A slide that could not be read is not a slide that cites nothing.
            if !result.isComplete {
                showToast("Slide \(slide.index) couldn't be read.")
            } else if added > 0 {
                showToast("Slide \(slide.index): \(added) paper\(added == 1 ? "" : "s") found.")
            } else {
                showToast(result.candidates.isEmpty
                    ? "No papers are cited on slide \(slide.index)."
                    : "Slide \(slide.index) cites nothing you don't already have.")
            }
        } catch {
            showToast("Couldn't read slide \(slide.index): \(error.localizedDescription)")
        }
        return await loadCitedPapers(forSourceID: sourceID)
    }

    /// "Find" on a cited paper that came back with no matching record.
    ///
    /// The scan that left it unmatched spent a bounded amount across the whole source; this
    /// spends on the one row the learner is looking at — its slide read again for the volume
    /// and page, then the catalogs and an uncapped web search. The row keeps its id, so a
    /// found paper becomes the same card with Add on it rather than a second one.
    @discardableResult
    func findCitedPaper(_ paper: VideoCitedPaper) async -> [VideoCitedPaper] {
        guard paper.status == .unresolved, paper.kind == .paper,
              let article = articles.first(where: { $0.id == paper.sourceID }) else {
            return await loadCitedPapers(forSourceID: paper.sourceID)
        }

        // The shelf first, before anything is spent: a citation the catalogs could not
        // place is often the course's own textbook, and no re-read or web search will
        // ever give a book a DOI.
        if let book = citedTextbook(for: paper) {
            var held = CitedTextbookMatch.held(paper, in: book)
            held.updatedAt = Date()
            showToast("\(paper.title) is \(bookDisplayName(book.id)) — it's already in your library.")
            return await persistCitedPaper(held)
        }

        var slide: YouTubeSlideFrameContext?
        if paper.slideImagePath != nil || paper.slideTimeSeconds != nil,
           let content = await storage.loadSourceContent(paper.sourceID) {
            let slides = await Task.detached(priority: .userInitiated) {
                YouTubeSlideContentParser.parse(content).slides
            }.value
            slide = VideoCitedPaperWindow.slide(for: paper, in: slides)
        }
        let context = article.sourceType == .meeting
            ? "Meeting: \(article.title)"
            : slideCitationVideoContext(for: paper.sourceID)

        let found = await SlideCitationService.shared.find(
            paper,
            slide: slide,
            source: AIUsageSource(source: article),
            videoContext: context,
            aiService: aiService
        )
        guard found.status != .unresolved else {
            showToast("Still no matching record for \(paper.title).")
            return await loadCitedPapers(forSourceID: paper.sourceID)
        }

        // Found as a paper the source already lists under another row: that row is the
        // one to act on, so this one is dismissed rather than shown twice.
        let existing = (try? await storage.loadVideoCitedPapers(forSourceID: paper.sourceID)) ?? []
        var updated = markingIfAlreadyInLibrary(found)
        if existing.contains(where: { $0.id != paper.id && $0.dedupKey == updated.dedupKey }) {
            updated.status = .dismissed
        }
        updated.updatedAt = Date()
        showToast(updated.status == .imported
            ? "Found \(updated.title) — it's already in your library."
            : "Found \(updated.title).")
        return await persistCitedPaper(updated)
    }

    // MARK: - Reader actions

    func loadCitedPapers(forSourceID sourceID: String) async -> [VideoCitedPaper] {
        (try? await storage.loadVideoCitedPapers(forSourceID: sourceID)) ?? []
    }

    /// Adds a cited source to the library through the normal add path, which types it off
    /// its URL: a paper gets the same deduplication, metadata enrichment and PDF handling as
    /// any other paper, a YouTube link its transcript, a page its archived article.
    @discardableResult
    func importCitedPaper(_ paper: VideoCitedPaper) async -> [VideoCitedPaper] {
        guard let url = paper.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            errorMessage = "That paper hasn't been matched to a record yet, so there's nothing to import."
            return await loadCitedPapers(forSourceID: paper.sourceID)
        }

        do {
            // Adds and switches the sources panel to the tab it landed in, so the source is
            // visible where it landed — but leaves the reader on the source that cited it.
            // Following the citation is a separate decision, made by clicking the new row.
            try await addArticle(url: url, revealInReader: false)
        } catch {
            let noun = paper.kind == .paper ? "paper" : paper.kind.label.lowercased()
            errorMessage = "Couldn't add the \(noun): \(error.localizedDescription)"
            return await loadCitedPapers(forSourceID: paper.sourceID)
        }

        var updated = paper
        updated.status = .imported
        // Link the candidate to the source it produced. Without this the record still syncs,
        // but a second Mac cannot tell the candidate was satisfied and offers it again.
        updated.importedSourceID = importedSourceID(for: paper, url: url)
        updated.updatedAt = Date()
        return await persistCitedPaper(updated)
    }

    /// Adds the candidate stored under `id` — the Add beside a slide the chat
    /// showed, which knows the paper only by id. A candidate already added, or
    /// gone since the chat drew it, is left as it is.
    func importCitedPaper(id: String) async {
        guard let paper = try? await storage.loadVideoCitedPaper(id: id), paper.status == .pending else { return }
        await importCitedPaper(paper)
    }

    @discardableResult
    func dismissCitedPaper(_ paper: VideoCitedPaper) async -> [VideoCitedPaper] {
        var updated = paper
        updated.status = .dismissed
        updated.updatedAt = Date()
        return await persistCitedPaper(updated)
    }

    /// Puts a dismissed candidate back in play. Dismissal is always undoable.
    ///
    /// A candidate that never resolved to anything importable goes back to `unresolved`,
    /// not `pending`, so a failed lookup is never dressed up as an importable source. What
    /// makes one importable is an address: a DOI, or the URL a linked page carries.
    @discardableResult
    func restoreCitedPaper(_ paper: VideoCitedPaper) async -> [VideoCitedPaper] {
        var updated = paper
        updated.status = Self.restoredStatus(for: paper)
        updated.updatedAt = Date()
        return await persistCitedPaper(updated)
    }

    private func persistCitedPaper(_ paper: VideoCitedPaper) async -> [VideoCitedPaper] {
        do {
            try await storage.saveVideoCitedPaper(paper)
        } catch {
            errorMessage = "Couldn't save that change: \(error.localizedDescription)"
        }
        noteCitedPapersChanged()
        return await loadCitedPapers(forSourceID: paper.sourceID)
    }

    /// Tells every view showing a source's cited papers that the set changed. The video
    /// readers hold their own copy and refresh it from the call that changed it; the paper
    /// reader's toolbar control observes this instead, so a scan started from the sidebar
    /// or the overflow menu reaches it too.
    func noteCitedPapersChanged() {
        citedPapersRevision &+= 1
    }

    /// Marks the frames the vision pass judged to be photographs of the room rather than deck
    /// pages, so a deck page and a camera shot of it stop showing as two slides in the reader.
    ///
    /// The frame is marked, not deleted: `displaySlides` hides a marked frame, but the block
    /// stays in the stored content, so a misjudgement is reversible and a bad scan can never
    /// lose a real slide. The rewrite syncs to a second Mac like any other content edit, and
    /// the in-memory copy the reader renders is updated in step. A no-op when the scan touched
    /// nothing or the source is no longer loaded.
    private func markNonSlideFrames(
        _ result: SlideCitationService.ScanResult,
        sourceID: String,
        content: String
    ) async {
        if SlideCitationService.isMisclassifiedScan(result) {
            slideCitationLogger.warning(
                "Ignoring non-slide marks for \(sourceID, privacy: .public): \(result.nonSlideFramePaths.count) of \(result.scannedFramePaths.count) scanned frame(s) flagged, which reads as a misclassified scan rather than that many camera shots"
            )
            return
        }
        guard let index = articles.firstIndex(where: { $0.id == sourceID }),
              let rewritten = SlideCitationService.contentMarkingNonSlideFrames(
                  for: result, in: content
              ) else { return }

        articles[index].content = rewritten
        articles[index].wordCount = rewritten.split(separator: " ").count
        do {
            try await storage.saveSource(articles[index])
            slideCitationLogger.info(
                "Marked \(result.nonSlideFramePaths.count) non-slide frame(s) in \(sourceID, privacy: .public)"
            )
        } catch {
            slideCitationLogger.error(
                "Couldn't persist non-slide frame marks for \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func slideCitationVideoContext(for sourceID: String) -> String? {
        guard let article = articles.first(where: { $0.id == sourceID }) else { return nil }
        return SlideCitationService.videoContext(title: article.title, channel: article.domain)
    }

    /// Records a candidate that is already in the library as imported, rather than offering
    /// it for import again.
    ///
    /// A citation-dense talk in a subject you already read will cite plenty of papers you
    /// own. Without this they arrive as fresh suggestions, and the duplicate is only caught
    /// on click — by the dedup inside `addArticle`, which reports it as an error.
    func markingIfAlreadyInLibrary(_ candidate: VideoCitedPaper) -> VideoCitedPaper {
        if candidate.status == .pending,
           let url = candidate.url,
           let existingID = importedSourceID(for: candidate, url: url) {
            var updated = candidate
            updated.status = .imported
            updated.importedSourceID = existingID
            return updated
        }
        // A citation the catalogs could not place may be the course's textbook, which no
        // catalog holds: "Nicholls et al., Bioenergetics" is the book on the shelf.
        if candidate.status == .unresolved || candidate.status == .pending,
           let book = citedTextbook(for: candidate) {
            return CitedTextbookMatch.held(candidate, in: book)
        }
        return candidate
    }

    /// The book a citation names, if the library holds it (`CitedTextbookMatch`).
    func citedTextbook(for candidate: VideoCitedPaper) -> CitedTextbookMatch.Book? {
        guard candidate.kind == .paper, !bookTitles.isEmpty else { return nil }
        let books = citedTextbookCandidates(forSourceID: candidate.sourceID)
        return CitedTextbookMatch.book(for: candidate, courseTextbooks: books.course, libraryBooks: books.library)
    }

    /// The books a source's citations are matched against: the textbooks read with the
    /// course the source is a lecture of, then every other book in the library.
    func citedTextbookCandidates(
        forSourceID sourceID: String
    ) -> (course: [CitedTextbookMatch.Book], library: [CitedTextbookMatch.Book]) {
        var courseBookIDs: [String] = []
        var seen = Set<String>()
        for courseID in courseLecturesByCourse.keys.sorted() {
            let lectures = courseLectures(for: courseID)
            guard lectures.contains(where: { lecture in
                courseLectureItems(for: lecture.id).contains { $0.sourceId == sourceID }
            }) else { continue }
            for bookID in textbookIDs(inCourse: courseID) where seen.insert(bookID).inserted {
                courseBookIDs.append(bookID)
            }
        }
        let libraryBookIDs = bookTitles.keys.sorted().filter { !seen.contains($0) }
        return (courseBookIDs.map(citedTextbook), libraryBookIDs.map(citedTextbook))
    }

    private func citedTextbook(_ bookID: String) -> CitedTextbookMatch.Book {
        CitedTextbookMatch.Book(
            id: bookID,
            title: bookTitles[bookID] ?? bookID,
            subtitle: bookSubtitles[bookID],
            edition: bookEditions[bookID],
            author: bookAuthors[bookID],
            openingChapterID: bookChapterArticlesInOrder(for: bookID).first?.id
        )
    }

    /// The status a dismissed candidate is restored to: `pending` when it can be imported —
    /// it carries a DOI or a URL — and `unresolved` when it never resolved to an address.
    nonisolated static func restoredStatus(for paper: VideoCitedPaper) -> VideoCitedPaper.Status {
        let hasDOI = !(paper.doi ?? "").isEmpty
        let hasURL = !(paper.url ?? "").isEmpty
        return hasDOI || hasURL ? .pending : .unresolved
    }

    /// Finds the source the import produced, or the one that already covered it when the
    /// candidate was a duplicate of something in the library. Addresses are compared on
    /// their normalized form, the key the library dedups on: a Substack post linked with
    /// its tracking parameters is the post the library saved without them.
    private func importedSourceID(for paper: VideoCitedPaper, url: String) -> String? {
        if let exact = articles.first(where: { $0.url == url }) {
            return exact.id
        }
        let normalized = URLNormalizer.normalize(url)
        if let sameAddress = articles.first(where: { URLNormalizer.normalize($0.url) == normalized }) {
            return sameAddress.id
        }
        guard let doi = paper.doi else { return nil }
        let target = Self.normalizeDOI(doi)
        return articles.first { article in
            guard let existing = PaperService.extractDOI(from: article.url) else { return false }
            return Self.normalizeDOI(existing) == target
        }?.id
    }
}

// MARK: - A walkthrough's cited works

/// A walkthrough step's cited work as its card draws it
/// (`WalkthroughCitedWorkCard`): the citation — lent the DOI or address the
/// walked source's recorded cited papers resolved, when the walk named it
/// with neither — and the library source it is, when the library holds it.
struct WalkthroughCitationMatch: Equatable, Sendable {
    var citation: PaperWalkthroughCitation
    var librarySourceID: String?
}

extension StudioViewModel {
    /// The library source a cited work is by what it names outright: the
    /// id the walk gave, while the library still holds it; then its DOI;
    /// then its address. A hash lookup each (`librarySourceID(forURL:)`), so
    /// a card's body may ask, and a work added since the walk was written is
    /// found by the next render.
    func librarySourceID(for citation: PaperWalkthroughCitation) -> String? {
        if let id = citation.sourceID, articlesById[id] != nil { return id }
        if let doi = PaperWalkthroughCitation.normalizedDOI(citation.doi),
           let id = librarySourceID(forURL: "https://doi.org/\(doi)") {
            return id
        }
        if let url = citation.url, let id = librarySourceID(forURL: url) { return id }
        return nil
    }

    /// Everything a card can learn about a cited work beyond the outright
    /// keys, off the main actor where it costs more than a hash. First the
    /// papers the walked source's own reference list, slides or links were
    /// read into (`VideoCitedPaper`), matched by DOI, address or exact
    /// title: a row lends a work named without an address the one the
    /// catalogs resolved, and says when the learner added it already. Then,
    /// for a work still named by title alone, a book the library holds
    /// (`citedTextbook(for:)`, which wants the first author to agree), and
    /// last a saved source of exactly that title, when one and only one has
    /// it. Deterministic keys only: nothing here asks a model which record a
    /// citation is.
    func walkthroughCitationMatch(
        _ citation: PaperWalkthroughCitation,
        citedBy walkedSourceID: String
    ) async -> WalkthroughCitationMatch {
        if let id = librarySourceID(for: citation) {
            return WalkthroughCitationMatch(citation: citation, librarySourceID: id)
        }
        var lent = citation
        let recorded = (try? await storage.loadVideoCitedPapers(forSourceID: walkedSourceID)) ?? []
        if let row = Self.recordedCitedPaper(matching: citation, in: recorded) {
            if lent.doi == nil, let doi = PaperWalkthroughCitation.normalizedDOI(row.doi) { lent.doi = doi }
            if lent.url == nil, let url = row.url, URL(string: url)?.scheme?.lowercased().hasPrefix("http") == true {
                lent.url = url
            }
            if row.status == .imported, let id = row.importedSourceID, articlesById[id] != nil {
                return WalkthroughCitationMatch(citation: lent, librarySourceID: id)
            }
            if let id = librarySourceID(for: lent) {
                return WalkthroughCitationMatch(citation: lent, librarySourceID: id)
            }
        }
        guard lent.address == nil else { return WalkthroughCitationMatch(citation: lent, librarySourceID: nil) }

        let asCandidate = VideoCitedPaper(
            sourceID: walkedSourceID,
            title: lent.title,
            authors: lent.authors,
            year: lent.year,
            journal: lent.venue,
            status: .unresolved
        )
        if let book = citedTextbook(for: asCandidate), let chapterID = book.openingChapterID, articlesById[chapterID] != nil {
            return WalkthroughCitationMatch(citation: lent, librarySourceID: chapterID)
        }

        let key = PaperWalkthroughCitation.foldedTitle(lent.title)
        guard Self.isDistinctiveCitedTitle(key) else { return WalkthroughCitationMatch(citation: lent, librarySourceID: nil) }
        let titled: [(id: String, title: String)] = articles.compactMap { article in
            guard article.id != walkedSourceID else { return nil }
            switch article.sourceType {
            case .paper, .article, .book, .video, .podcast: return (article.id, article.title)
            default: return nil
            }
        }
        let match = await Task.detached(priority: .userInitiated) {
            Self.soleSource(titled: key, among: titled)
        }.value
        return WalkthroughCitationMatch(citation: lent, librarySourceID: match)
    }

    /// The walked source's recorded cited paper that is the same work as
    /// `citation`: the same DOI, the same address, or — only for a citation
    /// that names neither — exactly the same title.
    nonisolated static func recordedCitedPaper(
        matching citation: PaperWalkthroughCitation,
        in recorded: [VideoCitedPaper]
    ) -> VideoCitedPaper? {
        if let doi = PaperWalkthroughCitation.normalizedDOI(citation.doi),
           let row = recorded.first(where: { PaperWalkthroughCitation.normalizedDOI($0.doi) == doi }) {
            return row
        }
        if let url = citation.url {
            let key = URLNormalizer.normalize(url)
            if let row = recorded.first(where: { $0.url.map(URLNormalizer.normalize) == key }) { return row }
        }
        guard citation.address == nil else { return nil }
        let title = PaperWalkthroughCitation.foldedTitle(citation.title)
        guard isDistinctiveCitedTitle(title) else { return nil }
        let rows = recorded.filter { !$0.isAttributionOnly && PaperWalkthroughCitation.foldedTitle($0.title) == title }
        return rows.count == 1 ? rows[0] : nil
    }

    /// Whether a folded title says enough to name one work: three words and
    /// sixteen letters at least, so "Introduction" or "Results" never names
    /// a source.
    nonisolated static func isDistinctiveCitedTitle(_ folded: String) -> Bool {
        folded.count >= 16 && folded.split(separator: " ").count >= 3
    }

    /// The one source whose folded title is `key`; nil when none or several are.
    nonisolated static func soleSource(titled key: String, among sources: [(id: String, title: String)]) -> String? {
        var found: String?
        for source in sources where PaperWalkthroughCitation.foldedTitle(source.title) == key {
            guard found == nil else { return nil }
            found = source.id
        }
        return found
    }
}
