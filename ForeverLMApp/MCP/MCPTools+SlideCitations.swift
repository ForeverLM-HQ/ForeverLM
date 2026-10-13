import Foundation

// MARK: - Sources cited, mentioned or linked by source evidence (MCP/UI parity)
//
// The reader can list a source's candidates — the papers a video's slides cite, a meeting
// mentions or a paper's reference list cites, and the sources an article's links point at
// — import one, dismiss one, and restore a dismissal. These tools give an external
// assistant the same reach, plus the scans that fill the list.
//
// Two rules carry over from the app and are enforced here rather than left to the caller:
// a candidate that never resolved to an address cannot be imported (there is nothing to
// fetch), and a rescan never overwrites a row the learner has already decided on.

extension MCPDataStore {

    // MARK: Validation

    /// Resolve the source a citation tool targets.
    ///
    /// Every tool in this file either reports on or mutates rows keyed to a source, so a
    /// missing id, or one of a type that has nothing to cite, has to fail before any write
    /// rather than yielding an empty result that reads like "this source cites nothing".
    /// Candidates are read from a video's slides, a meeting's transcript and notes, a
    /// paper's reference list, and a web article's links.
    func requireCitedPaperSource(
        _ rawSourceID: String
    ) throws -> (store: KnowledgeStore, article: StudioArticle) {
        let sourceID = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else {
            throw MCPError.invalidInput("source_id is required.")
        }
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID). Use list_sources to see valid IDs.")
        }
        let readsCitations = article.sourceType == .video
            || article.sourceType == .meeting
            || StudioViewModel.supportsReferenceExtraction(article)
            || StudioViewModel.supportsLinkDiscovery(article)
        guard readsCitations else {
            throw MCPError.invalidInput(
                "Source candidates are read from a video's slides, a meeting's transcript and notes, a paper's reference list, or a web article's links; '\(article.title)' is a \(article.sourceType.rawValue) source."
            )
        }
        return (store, article)
    }

    /// Resolve the web article a link scan targets.
    func requireLinkedSourceArticle(_ rawSourceID: String) throws -> (store: KnowledgeStore, article: StudioArticle) {
        let result = try requireCitedPaperSource(rawSourceID)
        guard StudioViewModel.supportsLinkDiscovery(result.article) else {
            throw MCPError.invalidInput(
                "scan_article_for_linked_sources reads a web article's links; '\(result.article.title)' is a \(result.article.sourceType.rawValue) source. Use scan_video_for_cited_papers for a video or scan_meeting_for_mentioned_papers for a meeting."
            )
        }
        return result
    }

    func requireVideoSource(_ rawSourceID: String) throws -> (store: KnowledgeStore, article: StudioArticle) {
        let result = try requireCitedPaperSource(rawSourceID)
        guard result.article.sourceType == .video else {
            throw MCPError.invalidInput(
                "Slide tools require a video source; '\(result.article.title)' is a meeting source."
            )
        }
        return result
    }

    /// Slide frames are appended to the text they were captured from, so they are saved
    /// only onto that same text. A transcript another call replaced while the video
    /// streamed is kept, and this call fails and says so.
    static func requireUnchangedTranscript(_ stored: StudioArticle, since started: String?, during work: String) throws {
        guard stored.content == started else {
            throw MCPError.invalidInput(
                "'\(stored.title)' changed while \(work), so nothing was saved. Call again to work from its new text."
            )
        }
    }

    func requireCitedPaper(_ rawID: String, store: KnowledgeStore) throws -> VideoCitedPaper {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw MCPError.invalidInput("cited_paper_id is required.")
        }
        guard let paper = try store.loadVideoCitedPaper(id: id) else {
            throw MCPError.notFound(
                "Cited paper not found: \(id). Use list_video_cited_papers with the video's source_id to see valid ids."
            )
        }
        return paper
    }

    // MARK: Payloads

    /// One candidate, in the shape follow-up tool calls key on: `cited_paper_id` for the
    /// mutating tools, `imported_source_id` for reaching the library source it produced.
    func citedPaperPayload(_ paper: VideoCitedPaper) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "cited_paper_id": paper.id,
            "source_id": paper.sourceID,
            "title": paper.title,
            "kind": paper.kind.rawValue,
            "status": paper.status.rawValue,
            "created_at": iso.string(from: paper.createdAt),
            "updated_at": iso.string(from: paper.updatedAt),
        ]
        if let site = paper.linkedSiteName { payload["site"] = site }
        if let context = cleanedOptional(paper.context) { payload["context"] = context }
        if let authors = cleanedOptional(paper.authors) { payload["authors"] = authors }
        if let year = cleanedOptional(paper.year) { payload["year"] = year }
        if let journal = cleanedOptional(paper.journal) { payload["journal"] = journal }
        if let doi = cleanedOptional(paper.doi) { payload["doi"] = doi }
        if let url = cleanedOptional(paper.url) { payload["url"] = url }
        if let seconds = paper.slideTimeSeconds {
            payload["slide_time_seconds"] = seconds
            payload["slide_timestamp"] = YouTubeTranscriptTime.display(seconds)
        }
        if let importedSourceID = cleanedOptional(paper.importedSourceID) {
            payload["imported_source_id"] = importedSourceID
        }
        return payload
    }

    /// Every status counted, including the zeroes, so a caller can compare two calls
    /// without having to know which keys a given video happened to produce.
    func citedPaperStatusCounts(_ papers: [VideoCitedPaper]) -> [String: Int] {
        [
            "pending": papers.filter { $0.status == .pending }.count,
            "unresolved": papers.filter { $0.status == .unresolved }.count,
            "imported": papers.filter { $0.status == .imported }.count,
            "dismissed": papers.filter { $0.status == .dismissed }.count,
        ]
    }

    // MARK: list_video_cited_papers

    func listVideoCitedPapers(sourceID rawSourceID: String) throws -> String {
        let (store, article) = try requireCitedPaperSource(rawSourceID)
        let papers = try store.loadVideoCitedPapers(forSourceID: article.id)

        var payload: [String: Any] = [
            "source_id": article.id,
            "source_title": article.title,
            "cited_paper_count": papers.count,
            "counts_by_status": citedPaperStatusCounts(papers),
            "cited_papers": papers.map(citedPaperPayload),
        ]

        if papers.isEmpty, article.sourceType == .video {
            // An empty list is ambiguous on its own — never scanned, or scanned and found
            // nothing. Whether the video even has slide frames separates the two, and it is
            // only worth reading the transcript for that when the list is empty.
            var hasSlides = false
            if let content = try? store.loadSourceContent(article.id) {
                hasSlides = SlideFrameExtraction.containsSlideSection(content)
            }
            payload["has_slide_frames"] = hasSlides
            payload["message"] = hasSlides
                ? "No papers are recorded from this video's slides. It has slide frames, so it may simply never have been scanned — run scan_video_for_cited_papers."
                : "No papers are recorded from this video's slides, and no slide frames have been captured for it. Capture them with extract_video_slides (or let scan_video_for_cited_papers capture them first); neither runs automatically."
        } else if papers.isEmpty, article.sourceType == .meeting {
            payload["message"] = "No papers are recorded from this meeting's transcript or notes. Run scan_meeting_for_mentioned_papers to read them."
        } else if papers.isEmpty, StudioViewModel.supportsLinkDiscovery(article) {
            payload["message"] = "No linked sources are recorded for this article. Run scan_article_for_linked_sources to read its links."
        } else if papers.isEmpty {
            payload["message"] = "No cited papers are recorded for this paper. Its reference list is read from the app's reader (Find Cited Papers)."
        }

        payload["guidance"] = "pending candidates carry an address and can be imported with import_video_cited_paper; show them to the learner first and import only the ones they choose. unresolved ones were observed but no matching record was found, so they can only be dismissed. Use update_video_cited_paper_status to dismiss or restore."
        return try jsonString(payload)
    }

    // MARK: scan_article_for_linked_sources

    /// Read one web article's saved page for the sources its links point at, merging new
    /// candidates without overwriting prior import or dismissal decisions.
    ///
    /// The same two steps as the reader's Find Linked Sources: the links are found
    /// deterministically off the archived page (fetched and archived first when there is
    /// none), and a model judges which the article uses as sources. Identity never passes
    /// through the model.
    func scanArticleForLinkedSources(
        sourceID rawSourceID: String,
        force: Bool
    ) async throws -> String {
        let (store, article) = try requireLinkedSourceArticle(rawSourceID)

        let existing = try store.loadVideoCitedPapers(forSourceID: article.id)
        if !existing.isEmpty, !force {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "scanned": false,
                "reason": "already_scanned",
                "cited_paper_count": existing.count,
                "counts_by_status": citedPaperStatusCounts(existing),
                "cited_papers": existing.map(citedPaperPayload),
                "message": "'\(article.title)' already has \(existing.count) recorded candidate(s). Show the learner the pending ones and import the ones they pick with import_video_cited_paper. Pass force: true to read the links again and merge while preserving existing decisions.",
            ] as [String: Any])
        }

        guard let config = KeychainService.resolveConfig(for: .articleLinkDiscovery) else {
            throw MCPError.invalidInput(
                KeychainService.backgroundAIUnavailableMessage(for: .articleLinkDiscovery)
                    ?? "Article Link Discovery is not configured."
            )
        }
        guard let html = try await StudioViewModel.archivedPageHTML(for: article) else {
            throw MCPError.invalidInput(
                "'\(article.title)' has no saved page to read links from, and fetching one produced nothing."
            )
        }
        let pageURL = URL(string: article.url)
        let reading = await Task.detached(priority: .userInitiated) {
            ArticleLinkDiscoveryService.read(html: html, pageURL: pageURL)
        }.value
        guard !reading.links.isEmpty else {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "scanned": true,
                "forced": force,
                "links_found": 0,
                "sources_found": 0,
                "added_count": 0,
                "already_in_library_count": 0,
                "cited_paper_count": existing.count,
                "counts_by_status": citedPaperStatusCounts(existing),
                "cited_papers": existing.map(citedPaperPayload),
                "message": "'\(article.title)' links to nothing outside itself.",
            ] as [String: Any])
        }

        let aiService = AIService()
        let picks = try await AIUsageAttribution.withSource(AIUsageSource(source: article)) {
            var picks: [ArticleLinkDiscoveryService.Pick] = []
            for chunk in ArticleLinkDiscoveryService.chunks(of: reading) {
                picks += try await aiService.discoverArticleLinkedSources(
                    articleTitle: article.title,
                    markedText: chunk,
                    linkIndex: reading.linkIndex,
                    config: config
                )
            }
            return picks
        }
        let candidates = ArticleLinkDiscoveryService.candidates(
            from: picks, reading: reading, sourceID: article.id
        )

        let existingKeys = Set(existing.map(\.dedupKey))
        var added: [VideoCitedPaper] = []
        var alreadyInLibrary: [VideoCitedPaper] = []
        for var candidate in candidates where !existingKeys.contains(candidate.dedupKey) {
            if let url = candidate.url,
               let sourceID = try importedPaperSourceID(for: candidate, url: url, store: store) {
                candidate.status = .imported
                candidate.importedSourceID = sourceID
                alreadyInLibrary.append(candidate)
            } else {
                added.append(candidate)
            }
            try store.saveVideoCitedPaper(candidate)
        }

        let final = try store.loadVideoCitedPapers(forSourceID: article.id)
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "scanned": true,
            "forced": force,
            "links_found": reading.links.count,
            "sources_found": candidates.count,
            "added_count": added.count,
            "already_in_library_count": alreadyInLibrary.count,
            "cited_paper_count": final.count,
            "counts_by_status": citedPaperStatusCounts(final),
            "cited_papers": final.map(citedPaperPayload),
            "message": candidates.isEmpty
                ? "None of the \(reading.links.count) link(s) in '\(article.title)' is used as a source."
                : "Found \(candidates.count) linked source(s) among \(reading.links.count) link(s) in '\(article.title)'. Show them to the learner and import only the ones they choose.",
        ] as [String: Any])
    }

    // MARK: scan_meeting_for_mentioned_papers

    /// Read one meeting's complete stored transcript and notes, merging new
    /// candidates without overwriting prior import or dismissal decisions.
    func scanMeetingForMentionedPapers(
        sourceID rawSourceID: String,
        force: Bool
    ) async throws -> String {
        let (store, article) = try requireCitedPaperSource(rawSourceID)
        guard article.sourceType == .meeting else {
            throw MCPError.invalidInput(
                "Meeting paper discovery requires a meeting source; '\(article.title)' is a video source."
            )
        }

        let existing = try store.loadVideoCitedPapers(forSourceID: article.id)
        if !existing.isEmpty, !force {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "scanned": false,
                "reason": "already_scanned",
                "cited_paper_count": existing.count,
                "counts_by_status": citedPaperStatusCounts(existing),
                "cited_papers": existing.map(citedPaperPayload),
                "message": "'\(article.title)' already has \(existing.count) recorded candidate(s). Pass force: true to rescan and merge while preserving existing decisions.",
            ] as [String: Any])
        }

        let content: String
        if let stored = cleanedOptional(try store.loadSourceContent(article.id)) {
            content = stored
        } else {
            // Match the reader action: a recording-only Drive session is still
            // actionable. Transcription is on-device and persists through the
            // normal source/artifact path before the paper scan starts.
            _ = try await transcribeMeetingRecording(sourceID: article.id)
            guard let transcribed = cleanedOptional(try store.loadSourceContent(article.id)) else {
                throw MCPError.invalidInput(
                    "'\(article.title)' still has no readable transcript after transcription."
                )
            }
            content = transcribed
        }
        guard let config = KeychainService.resolveConfig(for: .meetingPaperDiscovery) else {
            throw MCPError.invalidInput(
                KeychainService.backgroundAIUnavailableMessage(for: .meetingPaperDiscovery)
                    ?? "Meeting Paper Discovery is not configured."
            )
        }

        let chunks = SlideCitationService.materialChunks(content)
        let aiService = AIService()
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
                sourceID: article.id,
                sourceText: content,
                context: "Meeting: \(article.title)",
                aiService: aiService
            )
        }

        let existingKeys = Set(existing.map(\.dedupKey))
        var added: [VideoCitedPaper] = []
        var alreadyInLibrary: [VideoCitedPaper] = []
        let textbooks = try citedTextbookCandidates(forSourceID: article.id, store: store)
        for var candidate in candidates where !existingKeys.contains(candidate.dedupKey) {
            if let url = candidate.url,
               let sourceID = try importedPaperSourceID(for: candidate, url: url, store: store) {
                candidate.status = .imported
                candidate.importedSourceID = sourceID
                alreadyInLibrary.append(candidate)
            } else if let book = CitedTextbookMatch.book(
                for: candidate, courseTextbooks: textbooks.course, libraryBooks: textbooks.library
            ) {
                candidate = CitedTextbookMatch.held(candidate, in: book)
                alreadyInLibrary.append(candidate)
            } else {
                added.append(candidate)
            }
            try store.saveVideoCitedPaper(candidate)
        }

        let final = try store.loadVideoCitedPapers(forSourceID: article.id)
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "scanned": true,
            "forced": force,
            "material_chunks_scanned": chunks.count,
            "papers_found": candidates.count,
            "added_count": added.count,
            "already_in_library_count": alreadyInLibrary.count,
            "cited_paper_count": final.count,
            "counts_by_status": citedPaperStatusCounts(final),
            "cited_papers": final.map(citedPaperPayload),
            "message": candidates.isEmpty
                ? "No academic papers were explicitly mentioned in '\(article.title)'."
                : "Found \(candidates.count) explicitly mentioned paper candidate(s) in '\(article.title)'.",
        ] as [String: Any])
    }

    // MARK: import_video_cited_paper

    func importVideoCitedPaper(citedPaperID rawID: String) async throws -> String {
        let store = try knowledgeStore()
        let paper = try requireCitedPaper(rawID, store: store)

        // Re-importing would re-download the PDF and re-run metadata extraction for a paper
        // already in the library. Reported explicitly rather than treated as an error, so a
        // repeated call does not break an assistant's plan.
        if paper.status == .imported {
            var payload: [String: Any] = [
                "cited_paper_id": paper.id,
                "source_id": paper.sourceID,
                "imported": false,
                "already_imported": true,
                "cited_paper": citedPaperPayload(paper),
                "message": "'\(paper.title)' was already imported into the library.",
            ]
            if let linked = cleanedOptional(paper.importedSourceID) {
                payload["imported_source_id"] = linked
            } else {
                payload["warning"] = "This candidate is marked imported but carries no imported_source_id, so the library source it produced cannot be identified from here."
            }
            return try jsonString(payload)
        }

        guard let url = cleanedOptional(paper.url) else {
            throw MCPError.invalidInput(
                "'\(paper.title)' (status: \(paper.status.rawValue)) has not been matched to a paper record, so there is no URL to import. Read it off the slide and add it by hand with import_paper_from_url, or dismiss it with update_video_cited_paper_status."
            )
        }

        let importDetail = try await importCitedSource(paper, url: url, store: store)

        // Identity stays deterministic — the produced source is found by lookup, never by
        // parsing importDetail. Without this link a second Mac cannot tell the candidate is
        // satisfied and offers it again.
        let linkedSourceID = try importedPaperSourceID(for: paper, url: url, store: store)

        var updated = paper
        updated.status = .imported
        updated.importedSourceID = linkedSourceID
        updated.updatedAt = Date()
        try store.saveVideoCitedPaper(updated)

        var payload: [String: Any] = [
            "cited_paper_id": updated.id,
            "source_id": updated.sourceID,
            "imported": true,
            "import_detail": importDetail,
            "cited_paper": citedPaperPayload(updated),
        ]
        if let linkedSourceID {
            payload["imported_source_id"] = linkedSourceID
        } else {
            payload["warning"] = "The paper was imported, but the library source it produced could not be identified, so imported_source_id is empty. The candidate is marked imported here; another Mac may still offer it."
        }
        return try jsonString(payload)
    }

    /// Adds one candidate through the pipeline its kind takes, and says what happened.
    ///
    /// A paper goes through the normal paper path, so it gets the same deduplication,
    /// metadata enrichment and PDF handling as any other paper — with no title override,
    /// because a slide title is OCR output and a link's words are the article's, and the
    /// pipeline resolves a better one. A YouTube video is added and its transcript fetched;
    /// a page is added and fetched, which archives it and runs the article pipeline. A
    /// podcast episode is added as its row; its transcript comes from Apple Podcasts on the
    /// Mac, which only the app can read. A URL the paper pipeline refuses as not a paper
    /// (`detectSourceType` and the library can disagree about a landing page) is not lost:
    /// it is added as an article instead, and the result says so.
    private func importCitedSource(_ paper: VideoCitedPaper, url: String, store: KnowledgeStore) async throws -> String {
        switch paper.kind {
        case .paper:
            return try await importPaperFromURL(url, title: nil)
        case .video:
            let added = try await addSourceNamingVideoChannel(
                url: url,
                title: paper.title,
                sourceType: StudioSourceType.video.rawValue,
                content: nil,
                parentGroup: nil,
                author: nil,
                occurredAt: nil,
                connectorLabel: nil
            )
            guard let sourceID = store.sourceExistsByNormalizedURL(URLNormalizer.normalize(url))?.id
                ?? store.sourceExistsByURL(url)?.id else { return added }
            if YouTubeTranscriptService.isYouTubeURL(url) || ZoomRecordingService.isZoomRecordingURL(url) {
                do {
                    return added + " " + (try await fetchVideoTranscript(sourceID: sourceID))
                } catch {
                    return added + " The transcript could not be fetched yet: \(error.localizedDescription)"
                }
            }
            return added
        case .podcast:
            return try addSource(url: url, title: paper.title, sourceType: StudioSourceType.podcast.rawValue, content: nil, parentGroup: nil, author: nil)
                + " The episode's transcript is read from Apple Podcasts by the app."
        case .xPost:
            let added = try addSource(url: url, title: paper.title, sourceType: StudioSourceType.xPost.rawValue, content: nil, parentGroup: nil, author: nil)
            return added + " " + (try await refetchSourceContentIfPossible(url: url, store: store))
        case .article:
            let added = try addSource(url: url, title: paper.title, sourceType: StudioSourceType.article.rawValue, content: nil, parentGroup: nil, author: nil)
            return added + " " + (try await refetchSourceContentIfPossible(url: url, store: store))
        }
    }

    /// Fetch a just-added source's content by its address. A fetch that fails leaves the
    /// row in place for the app's own retry and says why, rather than undoing the add.
    private func refetchSourceContentIfPossible(url: String, store: KnowledgeStore) async throws -> String {
        guard let sourceID = store.sourceExistsByNormalizedURL(URLNormalizer.normalize(url))?.id
            ?? store.sourceExistsByURL(url)?.id else { return "" }
        do {
            return try await refetchSourceContent(sourceID: sourceID)
        } catch {
            return "Its content could not be fetched yet: \(error.localizedDescription)"
        }
    }

    /// The library source an import produced, or the one that already covered it when the
    /// paper turned out to be a duplicate. URL first, then DOI — the same two identities the
    /// reader overlay links on.
    /// The books a source's citations are matched against (`CitedTextbookMatch`): the
    /// textbooks read with the course the source is a lecture of, then every other book in
    /// the library. The same lists `StudioViewModel.citedTextbookCandidates` builds from
    /// memory, read here from the store.
    func citedTextbookCandidates(
        forSourceID sourceID: String,
        store: KnowledgeStore
    ) throws -> (course: [CitedTextbookMatch.Book], library: [CitedTextbookMatch.Book]) {
        let books = try store.loadBooks()
        guard !books.titles.isEmpty else { return ([], []) }

        let lectures = try store.loadCourseLectures()
        let items = try store.loadCourseLectureItems()
        let courseIDs = Set(items.filter { $0.sourceId == sourceID }.compactMap { item in
            lectures.first { $0.id == item.lectureId }?.courseName
        })
        var courseBookIDs: [String] = []
        var seen = Set<String>()
        if !courseIDs.isEmpty {
            let bookByChapter = try store.bookIDsByChapterSourceID()
            let lectureIDs = Set(lectures.filter { courseIDs.contains($0.courseName) }.map(\.id))
            for item in items where item.role == .reading && lectureIDs.contains(item.lectureId) {
                guard let chapterID = item.sourceId,
                      let bookID = bookByChapter[chapterID],
                      seen.insert(bookID).inserted else { continue }
                courseBookIDs.append(bookID)
            }
        }

        func book(_ id: String) -> CitedTextbookMatch.Book {
            CitedTextbookMatch.Book(
                id: id,
                title: books.titles[id] ?? id,
                subtitle: books.subtitles[id],
                edition: books.editions[id],
                author: books.authors[id],
                openingChapterID: (try? store.bookChapterSourceIDs(bookID: id))?.first?.sourceID
            )
        }
        let libraryBookIDs = books.titles.keys.sorted().filter { !seen.contains($0) }
        return (courseBookIDs.map(book), libraryBookIDs.map(book))
    }

    func importedPaperSourceID(for paper: VideoCitedPaper, url: String, store: KnowledgeStore) throws -> String? {
        if let existing = store.sourceExistsByNormalizedURL(URLNormalizer.normalize(url))
            ?? store.sourceExistsByURL(url) {
            return existing.id
        }
        guard let doi = cleanedOptional(paper.doi) ?? PaperService.extractDOI(from: url) else {
            return nil
        }
        return try existingPaperByDOI(doi)?.id
    }

    // MARK: update_video_cited_paper_status

    func updateVideoCitedPaperStatus(citedPaperID rawID: String, status rawStatus: String) throws -> String {
        let requested = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["dismissed", "pending"].contains(requested) else {
            throw MCPError.invalidInput(
                "status must be one of: dismissed, pending. Received: \"\(rawStatus)\". Use import_video_cited_paper to import a candidate; \"imported\" and \"unresolved\" are set by the app, not by this tool."
            )
        }

        let store = try knowledgeStore()
        let paper = try requireCitedPaper(rawID, store: store)

        // An imported candidate describes a source that exists in the library. Flipping it
        // back would leave the two disagreeing, so the library source is what has to change.
        guard paper.status != .imported else {
            let linked = cleanedOptional(paper.importedSourceID).map { " (source id: \($0))" } ?? ""
            throw MCPError.invalidInput(
                "'\(paper.title)' is already imported into the library\(linked), so its status cannot be changed here. Remove the library source with remove_source or delete_source instead."
            )
        }

        let newStatus: VideoCitedPaper.Status
        if requested == "dismissed" {
            newStatus = .dismissed
        } else {
            // Restoring mirrors the reader's Restore button: a candidate that never resolved
            // to an address goes back to `unresolved`, not `pending`, so a failed lookup is
            // never dressed up as an importable source.
            newStatus = StudioViewModel.restoredStatus(for: paper)
        }

        guard newStatus != paper.status else {
            return try jsonString([
                "cited_paper_id": paper.id,
                "source_id": paper.sourceID,
                "changed": false,
                "status": paper.status.rawValue,
                "cited_paper": citedPaperPayload(paper),
                "message": "'\(paper.title)' is already \(paper.status.rawValue); nothing was changed.",
            ] as [String: Any])
        }

        var updated = paper
        updated.status = newStatus
        updated.updatedAt = Date()
        try store.saveVideoCitedPaper(updated)

        var payload: [String: Any] = [
            "cited_paper_id": updated.id,
            "source_id": updated.sourceID,
            "changed": true,
            "previous_status": paper.status.rawValue,
            "status": updated.status.rawValue,
            "cited_paper": citedPaperPayload(updated),
        ]
        if requested == "pending", updated.status == .unresolved {
            payload["note"] = "Restored to unresolved rather than pending: this candidate has no DOI and never matched a paper record, so it still cannot be imported."
        }
        return try jsonString(payload)
    }

    // MARK: extract_video_slides

    /// Capture a library video's slide frames without reading them for papers.
    ///
    /// The opt-in first step, mirroring the reader's "Show slides" button: slides are no
    /// longer captured at ingest (it streams the video for frames, minutes on a long talk),
    /// so a video has none until asked. Idempotent — a video that already has its frames just
    /// reports them. No model calls, so it is not gated by the citation-scan toggle; reading
    /// the frames for the papers they cite is the separate `scanVideoForCitedPapers`.
    ///
    /// Streaming the frames holds no store gate (`MCPToolRegistry.selfGatedToolNames`): the
    /// video is read in one shared stretch and the slides saved in one held alone.
    func extractVideoSlides(sourceID rawSourceID: String) async throws -> String {
        let (article, storedContent) = try await withStoreGate(.shared) {
            let (store, found) = try requireVideoSource(rawSourceID)
            return (found, try store.loadSourceContent(found.id))
        }
        guard let content = cleanedOptional(storedContent) else {
            throw MCPError.invalidInput(
                "'\(article.title)' has no stored transcript yet, so there are no slides to capture. Call fetch_video_transcript first."
            )
        }

        // Already captured — report rather than pay to stream the video a second time.
        if SlideFrameExtraction.containsSlideSection(content) {
            let slideCount = YouTubeSlideContentParser.parse(content).displaySlides.count
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "extracted": false,
                "already_extracted": true,
                "slide_count": slideCount,
                "message": "'\(article.title)' already has \(slideCount) slide(s) captured. Read them for cited papers with scan_video_for_cited_papers.",
            ] as [String: Any])
        }

        guard YouTubeTranscriptService.isYouTubeURL(article.url) else {
            throw MCPError.invalidInput(
                "Slide frames come from YouTube storyboards, and '\(article.title)' is not a YouTube video, so there are no slides to capture."
            )
        }

        let extraction = await YouTubeSlideExtractionService.shared.appendingSlideContext(
            to: content,
            videoURL: article.url,
            sourceID: article.id,
            videoTitle: article.title
        )
        if let message = extraction.errorMessage {
            throw MCPError.invalidInput(
                "Couldn't capture slide frames from '\(article.title)': \(message)"
            )
        }
        guard extraction.slideCount > 0 else {
            throw MCPError.invalidInput(
                "No distinct slide frames could be captured from '\(article.title)'."
            )
        }

        try await saveSourceAfterWait(article.id) { stored in
            try Self.requireUnchangedTranscript(stored, since: storedContent, during: "its slides were captured")
            stored.content = extraction.content
            stored.wordCount = extraction.content.split(separator: " ").count
            return true
        }

        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "extracted": true,
            "slide_count": extraction.slideCount,
            "message": "Captured \(extraction.slideCount) slide(s) from '\(article.title)'. Read them for cited papers with scan_video_for_cited_papers.",
        ] as [String: Any])
    }

    // MARK: scan_video_for_cited_papers

    /// Read a library video's slides for cited papers.
    ///
    /// Slides are captured and read only on request, never at ingest. This captures the
    /// frames itself when a video has none (the same catch-up `extract_video_slides` does),
    /// then reads them; with `force` it re-extracts and merges rather than replaces.
    ///
    /// Streaming the frames and the model's reading of them hold no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the video is read in one shared stretch, and
    /// each thing the scan saves is written in a stretch held alone.
    func scanVideoForCitedPapers(
        sourceID rawSourceID: String,
        force: Bool,
        exhaustive: Bool = false
    ) async throws -> String {
        let (article, existing, storedContent) = try await withStoreGate(.shared) {
            let (store, found) = try requireVideoSource(rawSourceID)
            return (
                found,
                try store.loadVideoCitedPapers(forSourceID: found.id),
                try store.loadSourceContent(found.id)
            )
        }

        // A plain rescan of a video that already has candidates would put back what the
        // learner imported or waved off. Refused by default, and a merge when forced.
        // Checked before extraction, so a refusal never pays for downloading frames first.
        if !existing.isEmpty, !force {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "scanned": false,
                "reason": "already_scanned",
                "cited_paper_count": existing.count,
                "counts_by_status": citedPaperStatusCounts(existing),
                "cited_papers": existing.map(citedPaperPayload),
                "message": "'\(article.title)' already has \(existing.count) recorded candidate(s) and was not rescanned, because a rescan would put back papers you have already imported or dismissed. Pass force: true to rescan and merge: decisions on existing candidates are kept and only genuinely new papers are added.",
            ] as [String: Any])
        }

        guard var content = cleanedOptional(storedContent) else {
            throw MCPError.invalidInput(
                "'\(article.title)' has no stored transcript yet, so there are no slides to read. Call fetch_video_transcript first."
            )
        }

        // Videos ingested before slide extraction existed have no frames, and neither do
        // videos whose extraction failed. Extract here rather than refusing: otherwise the
        // whole back catalogue is unreachable, since fetch_video_transcript returns early
        // once a transcript is cached and so never re-runs extraction.
        let hadSlides = SlideFrameExtraction.containsSlideSection(content)
        var extractedSlideCount: Int?
        if !hadSlides || force {
            guard YouTubeTranscriptService.isYouTubeURL(article.url) else {
                throw MCPError.invalidInput(
                    "Slide frames come from YouTube storyboards, and '\(article.title)' is not a YouTube video, so there are no slides to read."
                )
            }
            // A forced pass re-extracts from scratch. Frames stored by an earlier run were
            // chosen by the old even-sampling, so re-reading them would inherit its gaps
            // rather than picking up what transition detection now finds.
            let base = hadSlides ? YouTubeSlideContentParser.parse(content).transcriptContent : content
            let extraction = await YouTubeSlideExtractionService.shared.appendingSlideContext(
                to: base,
                videoURL: article.url,
                sourceID: article.id,
                videoTitle: article.title
            )
            if let message = extraction.errorMessage {
                throw MCPError.invalidInput(
                    "Couldn't extract slide frames from '\(article.title)': \(message)"
                )
            }
            guard extraction.slideCount > 0 else {
                throw MCPError.invalidInput(
                    "No distinct slide frames could be extracted from '\(article.title)', so there is nothing to read citations from."
                )
            }

            content = extraction.content
            extractedSlideCount = extraction.slideCount
            let extracted = content
            try await saveSourceAfterWait(article.id) { stored in
                try Self.requireUnchangedTranscript(stored, since: storedContent, during: "its slides were extracted")
                stored.content = extracted
                stored.wordCount = extracted.split(separator: " ").count
                return true
            }
        }

        // A deck captured on the other Mac has no frames here to read until
        // they are taken again from the video.
        await SlideFrameRestorer.shared.restore(
            YouTubeSlideContentParser.parse(content).slides,
            of: article,
            storage: nil
        )

        let result = try await SlideCitationService.shared.scan(
            source: AIUsageSource(source: article),
            sourceContent: content,
            videoContext: SlideCitationService.videoContext(
                title: article.title, channel: article.domain
            ),
            aiService: AIService(),
            exhaustive: exhaustive
        )

        // Mark the frames the model judged to be photographs of the room rather than deck
        // pages, the same as the in-app scan does, so a slide and a camera shot of it stop
        // showing as two entries whichever surface ran the scan. The frame is marked, never
        // deleted, so a misjudgement is reversible; a scan that flags a majority is ignored.
        // The marks go onto the text as it is stored when they are saved.
        if SlideCitationService.contentMarkingNonSlideFrames(for: result, in: content) != nil {
            try await saveSourceAfterWait(article.id) { stored in
                guard let marked = SlideCitationService.contentMarkingNonSlideFrames(for: result, in: stored.content ?? "") else {
                    return false
                }
                stored.content = marked
                stored.wordCount = marked.split(separator: " ").count
                return true
            }
        }

        // Recorded in one stretch held alone, against the rows the video has by then, so
        // a decision made on a candidate while the slides were read is kept.
        var added: [VideoCitedPaper] = []
        var alreadyInLibrary: [VideoCitedPaper] = []
        var matchedKeys = Set<String>()
        let (current, final) = try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            let rows = try store.loadVideoCitedPapers(forSourceID: article.id)
            let existingKeys = Set(rows.map(\.dedupKey))
            let textbooks = try citedTextbookCandidates(forSourceID: article.id, store: store)
            for candidate in result.candidates {
                if existingKeys.contains(candidate.dedupKey) {
                    // Already known. Left exactly as it is — its status is the learner's
                    // decision, and overwriting it is precisely what a merge must not do.
                    matchedKeys.insert(candidate.dedupKey)
                    continue
                }

                // A paper already in the library is recorded as held, not offered for import
                // again. A citation-dense talk in a subject the learner already reads will cite
                // plenty they own. So is the course's textbook, which no catalog can place.
                var candidate = candidate
                if let url = candidate.url,
                   let existingSourceID = try importedPaperSourceID(for: candidate, url: url, store: store) {
                    candidate.status = .imported
                    candidate.importedSourceID = existingSourceID
                    alreadyInLibrary.append(candidate)
                } else if let book = CitedTextbookMatch.book(
                    for: candidate, courseTextbooks: textbooks.course, libraryBooks: textbooks.library
                ) {
                    candidate = CitedTextbookMatch.held(candidate, in: book)
                    alreadyInLibrary.append(candidate)
                } else {
                    added.append(candidate)
                }
                try store.saveVideoCitedPaper(candidate)
            }
            return (rows, try store.loadVideoCitedPapers(forSourceID: article.id))
        }

        // Existing rows this scan did not turn up again are kept rather than deleted:
        // a slide the model failed to read this time is not evidence the paper was never
        // cited, and deleting would throw away an import or a dismissal.
        let unmatchedExisting = current.filter { !matchedKeys.contains($0.dedupKey) }

        var payload: [String: Any] = [
            "source_id": article.id,
            "source_title": article.title,
            "scanned": true,
            "forced": force,
            "scan_scope": exhaustive ? "all_captured_slides" : "bounded",
            "slides_scanned": result.slidesScanned,
            "slides_available": result.slidesAvailable,
            "slides_skipped": result.slidesSkipped,
            "slides_failed": result.slidesFailed,
            "scan_complete": result.isComplete,
            "papers_found": result.candidates.count,
            "added_count": added.count,
            // Cited papers the library already held. Recorded as imported and linked, so
            // they are never offered for import a second time.
            "already_in_library_count": alreadyInLibrary.count,
            "already_known_count": matchedKeys.count,
            "kept_unmatched_count": unmatchedExisting.count,
            "cited_paper_count": final.count,
            "counts_by_status": citedPaperStatusCounts(final),
            "cited_papers": final.map(citedPaperPayload),
        ]

        // Only present when this call extracted the frames itself, which is the normal case
        // for a video ingested before slide extraction existed.
        if let extractedSlideCount {
            payload["slides_extracted"] = extractedSlideCount
        }

        payload["summary"] = scanSummary(
            title: article.title,
            result: result,
            addedCount: added.count,
            alreadyKnownCount: matchedKeys.count
        )

        // A bounded or partly-failed video must never look like a fully-read one.
        var warnings: [String] = []
        if result.slidesSkipped > 0 {
            warnings.append(
                "The bounded scan skipped \(result.slidesSkipped) of \(result.slidesAvailable) captured slide(s). Run scan_video_for_cited_papers with all_slides: true to read the complete distinct deck."
            )
        }
        if result.slidesFailed > 0 {
            warnings.append(
                "\(result.slidesFailed) of \(result.slidesScanned) attempted slide(s) could not be read. Run scan_video_for_cited_papers again with force: true to retry; anything already found is kept."
            )
        }
        if !warnings.isEmpty {
            payload["warning"] = warnings.joined(separator: " ")
        }

        return try jsonString(payload)
    }

    /// One sentence saying what the scan actually did, so an empty result never reads as
    /// "the scan did not run".
    func scanSummary(
        title: String,
        result: SlideCitationService.ScanResult,
        addedCount: Int,
        alreadyKnownCount: Int
    ) -> String {
        if result.slidesScanned == 0 {
            return "Scanned '\(title)': no slide looked like it cited a paper, so none were read. This video appears to cite nothing on screen."
        }
        let slideScope = result.slidesSkipped > 0
            ? "\(result.slidesScanned) of \(result.slidesAvailable) captured slides"
            : "\(result.slidesScanned) captured slide(s)"
        if result.candidates.isEmpty {
            let readable = result.slidesScanned - result.slidesFailed
            return "Scanned '\(title)': read \(readable) successfully across \(slideScope) and found no papers cited on them."
        }
        if addedCount == 0 {
            return "Scanned '\(title)': found \(result.candidates.count) paper(s) across \(slideScope), all of which were already recorded. Nothing new was added and no existing decision was changed."
        }
        var summary = "Scanned '\(title)': found \(result.candidates.count) paper(s) across \(slideScope) and added \(addedCount) new candidate(s)."
        if alreadyKnownCount > 0 {
            summary += " \(alreadyKnownCount) were already recorded and kept as they are."
        }
        return summary
    }
}
