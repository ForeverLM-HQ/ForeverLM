// MCPDataStore: Reading views, visibility, PDF attachments and paper downloads.
import Foundation
import PDFKit

extension MCPDataStore {
    private func readingViewArticle(_ rawSourceID: String) throws -> StudioArticle {
        let store = try knowledgeStore()
        let sourceID = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.invalidInput("Source not found: \(sourceID)")
        }
        guard article.sourceType == .article else {
            throw MCPError.invalidInput("A reading view is only for web articles; '\(article.title)' is a \(article.sourceType.rawValue).")
        }
        return article
    }

    private func readingViewPayload(_ article: StudioArticle, view: ArticleReadingView?) throws -> String {
        guard let view else {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "has_reading_view": false,
            ] as [String: Any])
        }
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "has_reading_view": true,
            "instruction": view.instruction,
            "shown_in_reader": view.isShown,
            "hidden_piece_count": view.removals.count,
            "examples": Array(view.removals.prefix(20)),
        ] as [String: Any])
    }

    func makeArticleReadingView(sourceID: String, instruction: String) async throws -> String {
        let article = try readingViewArticle(sourceID)
        let view = try await ArticleReadingViewService.make(
            sourceID: article.id,
            title: article.title,
            instruction: instruction
        )
        if view.removals.isEmpty {
            return try jsonString([
                "source_id": article.id,
                "source_title": article.title,
                "saved": false,
                "message": "The model found nothing in '\(article.title)' that matches \"\(view.instruction)\", so nothing was changed.",
            ] as [String: Any])
        }
        return try jsonString([
            "source_id": article.id,
            "source_title": article.title,
            "saved": true,
            "instruction": view.instruction,
            "hidden_piece_count": view.removals.count,
            "examples": Array(view.removals.prefix(20)),
            "message": "The Reader now hides these pieces of '\(article.title)'. Open the article in the Reader to see it; set_article_reading_view_shown switches back to the original.",
        ] as [String: Any])
    }

    func getArticleReadingView(sourceID: String) throws -> String {
        let article = try readingViewArticle(sourceID)
        return try readingViewPayload(article, view: ArticleReadingViewStore.load(sourceID: article.id))
    }

    func setArticleReadingViewShown(sourceID: String, shown: Bool) throws -> String {
        let article = try readingViewArticle(sourceID)
        guard let view = ArticleReadingViewStore.setShown(shown, sourceID: article.id) else {
            throw MCPError.invalidInput("'\(article.title)' has no reading view yet. Make one with make_article_reading_view.")
        }
        return try readingViewPayload(article, view: view)
    }

    func clearArticleReadingView(sourceID: String) throws -> String {
        let article = try readingViewArticle(sourceID)
        let had = ArticleReadingViewStore.load(sourceID: article.id) != nil
        ArticleReadingViewStore.remove(sourceID: article.id)
        return had
            ? "Removed the reading view of '\(article.title)'; the Reader shows the original."
            : "'\(article.title)' had no reading view."
    }

    func setSourceHidden(sourceID: String, hidden: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.setSourceHidden(sourceID, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") source '\(article.title)'"
    }

    func setSourcePaywallStatus(sourceID: String, isPaywalled: Bool) throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard [.article, .paper, .unclassified].contains(article.sourceType) else {
            throw MCPError.invalidInput("Paywall status is only available for article, paper, or unclassified sources.")
        }

        article.isPaywalled = isPaywalled
        if isPaywalled {
            article.state = article.sourceType == .paper ? .error : .ready
            article.statusFlag = .paywall
        } else if article.statusFlag == .paywall {
            article.errorMessage = nil
            // Metadata attestation alone does not make a paper readable — see the
            // twin in StudioViewModel.clearPaywalledStatus. Require the durable
            // text too, so clearing a paywall marker cannot promote a paper the
            // reader, chat and CarPlay will all fail to open.
            article.state = article.sourceType == .paper
                && !(article.hasPaperIngestionAttestation
                     && ((try? store.hasReadableSourceContent(sourceID)) ?? false))
                ? .queued
                : .ready
        }
        try store.saveSource(article)
        return "\(isPaywalled ? "Marked" : "Cleared paywall status for") source '\(article.title)'\(isPaywalled ? " as paywalled" : "")"
    }

    func setPodcastEpisodeHidden(sourceID: String, hidden: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .podcast else {
            throw MCPError.invalidInput("set_podcast_episode_hidden requires a podcast source.")
        }
        try store.setPodcastEpisodeHidden(sourceID, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") podcast episode '\(article.title)'"
    }

    func setPodcastShowHidden(showName: String, hidden: Bool) throws -> String {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("show_name is required.")
        }
        try knowledgeStore().setPodcastShowHidden(trimmed, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") podcast show '\(trimmed)'"
    }

    /// Block or unblock a show's future imports — the same preference the
    /// Studio menu's "Never Import <show>" writes, so the two cannot disagree
    /// about what is blocked or about how show names are matched.
    func setPodcastShowImportBlocked(showName: String, blocked: Bool) throws -> String {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("show_name is required.")
        }
        guard SourceDiscovery.setPodcastShowBlocked(trimmed, blocked: blocked) else {
            return blocked
                ? "Podcast show '\(trimmed)' was already blocked from importing."
                : "Podcast show '\(trimmed)' was not blocked."
        }
        return blocked
            ? "Blocked podcast show '\(trimmed)': its episodes will no longer be imported. Episodes already in the library are unchanged."
            : "Importing podcast show '\(trimmed)' again."
    }

    func setPodcastEpisodeVisibleOverride(sourceID: String, visible: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .podcast else {
            throw MCPError.invalidInput("set_podcast_episode_visible_override requires a podcast source.")
        }
        try store.setPodcastEpisodeVisibleOverride(sourceID, visible: visible)
        return "\(visible ? "Force-showing" : "Removed force-show override for") podcast episode '\(article.title)'"
    }

    func setYouTubeChannelHidden(channelName: String, hidden: Bool) throws -> String {
        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("channel_name is required.")
        }
        try knowledgeStore().setYouTubeChannelHidden(trimmed, hidden: hidden)
        return "\(hidden ? "Hid" : "Unhid") YouTube channel '\(trimmed)'"
    }

    func setYouTubeVideoVisibleOverride(sourceID: String, visible: Bool) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .video, article.isYouTubeURL else {
            throw MCPError.invalidInput("set_youtube_video_visible_override requires a YouTube video source.")
        }
        try store.setYouTubeVideoVisibleOverride(sourceID, visible: visible)
        return "\(visible ? "Force-showing" : "Removed force-show override for") YouTube video '\(article.title)'"
    }

    func attachTextFileToSource(sourceID: String, filePath: String) throws -> String {
        let sourceURL = try validateClientProvidedPath(filePath)
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard [.article, .manual, .unclassified].contains(article.sourceType) else {
            throw MCPError.invalidInput("attach_text_file_to_source is available for article, manual, and unclassified sources.")
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MCPError.invalidInput("File not found: \(filePath)")
        }
        let data = try Data(contentsOf: sourceURL)
        guard let raw = Self.decodeTextData(data),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidInput("Could not read text from \(filePath)")
        }

        let ext = sourceURL.pathExtension.lowercased()
        let text = (ext == "html" || ext == "htm" || ext == "xhtml")
            ? EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            : raw.removingSoftHyphens().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MCPError.invalidInput("Could not extract non-empty text from \(filePath)")
        }

        let destination = try copyFileIntoContentRoot(
            sourceURL,
            folder: "Articles",
            baseName: article.title,
            fallbackExtension: ext.isEmpty ? "txt" : ext
        )
        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        article.errorMessage = nil
        article.isPaywalled = false
        try store.saveSource(article)
        return "Attached text file to '\(article.title)' (path: \(article.localFilePath ?? destination.path))"
    }

    func attachPDFToPaper(sourceID: String, filePath: String?, pdfURL: String?) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("attach_pdf_to_paper requires a paper source.")
        }

        let trimmedPDFURL = Self.nilIfBlank(pdfURL ?? "")
        let trimmedFilePath = Self.nilIfBlank(filePath ?? "")
        let input = trimmedPDFURL ?? trimmedFilePath
        guard let input else {
            throw MCPError.invalidInput("attach_pdf_to_paper requires file_path or pdf_url.")
        }

        let destination: URL
        let attachedFrom: String
        if let remoteURL = Self.httpURLString(input) {
            let pdfDownloadURL = try await resolvedPDFURLForAttachment(remoteURL)
            let doi = Self.nilIfBlank(article.doi ?? "")
                ?? PaperService.extractDOI(from: article.url)
                ?? PaperService.extractDOI(from: pdfDownloadURL)
            let papersDir = sourceContentRoot.appendingPathComponent("Papers", isDirectory: true)
            try FileManager.default.createDirectory(at: papersDir, withIntermediateDirectories: true)
            destination = uniquePaperDestination(in: papersDir, doi: doi, url: pdfDownloadURL)
            try await downloadPaperPDFForImport(from: pdfDownloadURL, sourceURL: article.url, to: destination)
            attachedFrom = pdfDownloadURL
        } else {
            let sourceURL = try validateClientProvidedPath(input)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw MCPError.invalidInput("File not found: \(input)")
            }
            guard SourceService.canOpenPDF(at: sourceURL.path) else {
                throw MCPError.invalidInput("Could not read PDF: \(input)")
            }
            let doi = Self.nilIfBlank(article.doi ?? "") ?? PaperService.extractDOI(from: article.url)
            let baseName = doi.map { Self.safeFilenameBase($0.replacingOccurrences(of: "/", with: "-")) }
                ?? Self.safeFilenameBase(article.title)
            destination = try copyFileIntoContentRoot(
                sourceURL,
                folder: "Papers",
                baseName: baseName,
                fallbackExtension: "pdf"
            )
            attachedFrom = sourceURL.path
        }

        return try await finishAttachingPDF(article: &article, sourceID: sourceID, destination: destination, attachedFrom: attachedFrom, namesID: false)
    }

    /// attach_supplementary_pdf: the journal's supplementary file joined after
    /// the paper's own pages (`PaperSupplementPDF`). No model runs: the paper
    /// keeps its metadata, and its figure index is read again from the joined
    /// file the next time anything asks for a figure.
    func attachSupplementaryPDF(sourceID: String, filePath: String?, pdfURL: String?) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("attach_supplementary_pdf requires a paper source.")
        }
        guard let stored = Self.nilIfBlank(article.localFilePath ?? ""),
              FileManager.default.fileExists(atPath: StorageService.absoluteSourcePath(stored)) else {
            throw MCPError.invalidInput("'\(article.title)' has no PDF of its own on this Mac yet. Attach the article first with attach_pdf_to_paper.")
        }
        guard let input = Self.nilIfBlank(pdfURL ?? "") ?? Self.nilIfBlank(filePath ?? "") else {
            throw MCPError.invalidInput("attach_supplementary_pdf requires file_path or pdf_url.")
        }

        let supplementPath: String
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        if let remoteURL = Self.httpURLString(input) {
            let download = FileManager.default.temporaryDirectory
                .appendingPathComponent("supplement-\(UUID().uuidString).pdf")
            staged = download
            try await downloadPaperPDFForImport(from: remoteURL, sourceURL: article.url, to: download, paperHasPDF: true)
            supplementPath = download.path
        } else {
            let sourceURL = try validateClientProvidedPath(input)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw MCPError.invalidInput("File not found: \(input)")
            }
            supplementPath = sourceURL.path
        }

        let outcome: PaperSupplementPDF.Outcome
        do {
            outcome = try PaperSupplementPDF.append(
                supplementAt: supplementPath,
                toPaperAt: StorageService.absoluteSourcePath(stored)
            )
        } catch let failure as PaperSupplementPDF.Failure {
            throw MCPError.invalidInput(failure.localizedDescription)
        }
        let destination = URL(fileURLWithPath: outcome.path)
        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(outcome.path)
        // A paper that keeps its text keeps the supplement's too.
        if article.content != nil,
           let text = try? SourceService.shared.extractTextFromPDF(at: outcome.path),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            article.content = text
            article.wordCount = text.split(separator: " ").count
        }
        try store.saveSource(article)
        if let usedElsewhere = try? store.otherSourceUsesLocalFile(stored, excludingSourceID: sourceID) {
            PaperSupplementPDF.removeReplacedFile(storedPath: stored, usedElsewhere: usedElsewhere)
        }
        let firstAdded = outcome.articlePageCount + 1
        let lastAdded = outcome.articlePageCount + outcome.addedPageCount
        return "Joined \(outcome.addedPageCount) supplementary pages to '\(article.title)' as pages \(firstAdded)–\(lastAdded), after its \(outcome.articlePageCount) article pages (path: \(article.localFilePath ?? outcome.path)). "
            + "Call show_source_image with this source_id to list its figures, supplementary ones included."
    }

    /// Whether a PDF that arrives for `article` should be attached to it rather
    /// than refused as a duplicate: a paper the library lists but cannot read —
    /// paywalled, or with no PDF on disk — is not really there yet.
    ///
    /// Decided against the disk, not `resolvedPDFPath`: on the main thread that
    /// property answers from a cache that is empty for a row nobody has drawn
    /// yet, which would read a paper with its PDF as one without.
    static func existingPaperTakesArrivingPDF(_ article: StudioArticle) -> Bool {
        guard article.sourceType == .paper else { return false }
        for candidate in [article.localFilePath, article.url].compactMap({ $0 }) {
            let absolute = StorageService.absoluteSourcePath(candidate)
            if absolute.hasPrefix("/"),
               absolute.lowercased().hasSuffix(".pdf"),
               FileManager.default.fileExists(atPath: absolute) {
                return false
            }
        }
        return true
    }

    /// A PDF that arrives for a paper the library already lists — the same DOI
    /// in a file posted to Slack, a download of a paywalled paper's open copy —
    /// completes that paper when it has none of its own, instead of being
    /// answered "already exists" and dropped. Returns nil when the existing
    /// paper already has a readable PDF, in which case the duplicate answer
    /// stands. The staged file is copied, never moved; callers clean up theirs.
    func adoptPDFForExistingPaper(id: String, stagedPDF: URL, attachedFrom: String) async throws -> String? {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(id), Self.existingPaperTakesArrivingPDF(article) else { return nil }
        let doi = Self.nilIfBlank(article.doi ?? "")
            ?? PaperService.extractDOI(from: article.url)
            ?? Self.extractDOIFromPDF(at: stagedPDF.path)
        let baseName = doi.map { Self.safeFilenameBase($0.replacingOccurrences(of: "/", with: "-")) }
            ?? Self.safeFilenameBase(article.title)
        let destination = try copyFileIntoContentRoot(stagedPDF, folder: "Papers", baseName: baseName, fallbackExtension: "pdf")
        return try await finishAttachingPDF(article: &article, sourceID: id, destination: destination, attachedFrom: attachedFrom, namesID: true)
    }

    /// The half of attach_pdf_to_paper after the file is in the Papers folder:
    /// read it, extract text and the required metadata, clear the paywall
    /// state, and save. `namesID` is false for attach_pdf_to_paper, whose
    /// caller passed the id (Prompts.hiddenIDs), and true where a paper import
    /// adopted the PDF: that answer keeps the paper imports' "(id: …" shape.
    private func finishAttachingPDF(article: inout StudioArticle, sourceID: String, destination: URL, attachedFrom: String, namesID: Bool) async throws -> String {
        let store = try knowledgeStore()
        guard SourceService.canOpenPDF(at: destination.path),
              let document = PDFDocument(url: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw MCPError.invalidInput("Could not read PDF: \(attachedFrom)")
        }

        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        let firstPageText = document.page(at: 0)?.string ?? ""
        let text: String
        do {
            text = try SourceService.shared.extractTextFromPDF(at: destination.path)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceError.pdfReadFailed
            }
        } catch {
            // Keep the attached file and an explicit retryable error in the
            // library. Discarding the path here made the failed operation look
            // as if the learner had never selected a PDF at all.
            article.content = nil
            article.wordCount = nil
            article.state = .error
            article.errorMessage = "Attached PDF has no readable paper text."
            try store.saveSource(article)
            throw MCPError.invalidInput("Attached PDF has no readable paper text: \(attachedFrom)")
        }

        article.content = text
        article.wordCount = article.content?.split(separator: " ").count
        article.prepareForPaperMetadataExtraction()
        article.isPaywalled = false
        if article.doi == nil {
            article.doi = PaperService.extractDOI(from: article.url)
                ?? Self.extractDOIFromPDF(at: destination.path)
                ?? Self.extractDOIFromText(firstPageText)
        }
        let metadataStatus: String
        do {
            metadataStatus = try await extractRequiredPaperMetadataWithAI(
                article: &article,
                firstPageText: firstPageText
            )
        } catch {
            // Keep the attachment as an explicit failed/pending paper so the
            // operation cannot look successful and can be retried in place.
            try? store.saveSource(article)
            throw error
        }
        try store.saveSource(article)
        let marks = importDocumentMarks(sourceID: sourceID, pdfPath: destination.path)
        let idText = namesID ? "id: \(sourceID), " : ""
        return "Attached PDF to '\(article.title)' (\(idText)path: \(article.localFilePath ?? destination.path), \(article.wordCount ?? 0) words; \(metadataStatus))\(marks)"
    }

    /// Human-readable paywall evidence when a paper-PDF download failure indicates
    /// the paper sits behind a paywall, or nil when the failure looks transient
    /// (network error, 404, unreadable file) and the paper should stay in the
    /// needs-attention pool for a future retry. Every paywall-shaped error here is
    /// only reached after the open-access fallbacks (PMC, Unpaywall, mirror hosts)
    /// have also failed.
    static func paperPaywallEvidence(for error: Error) -> String? {
        if let unavailable = error as? PaperPDFUnavailableError {
            return "no open-access PDF found for \(unavailable.sourceURL) (direct link, PMC, and Unpaywall all came up empty)"
        }
        // Another paper's file is no PDF of this one.
        if let mismatch = error as? PaperPDFIdentityMismatchError {
            return mismatch.evidence
        }
        // A `PDFFetchRefusal` carries the host's own answer; its
        // classification decides, and its sentence is the evidence.
        let refusal = error as? PDFFetchRefusal
        switch SourceError.classifying(error) {
        case .accessDenied?:
            return refusal?.message ?? "publisher denied access (HTTP 403)"
        case .httpError(let code)? where code == 401 || code == 402:
            return refusal?.message ?? "publisher requires login or payment (HTTP \(code))"
        case .fetchFailed?:
            return refusal?.message ?? "publisher served a web page instead of the PDF"
        default:
            return nil
        }
    }

    /// Paywall evidence that also names each file turned away as another
    /// paper, so the learner is told why a PDF that was found was not used.
    static func paperPaywallEvidence(_ evidence: String, rejecting rejected: [PaperPDFIdentityMismatchError]) -> String {
        ([evidence] + rejected.map(\.evidence)).joined(separator: "; ")
    }

    /// Bulk-resolve PDFs for every paper that still needs one — the MCP equivalent of
    /// the Studio "Try Papers Needing Attention" button. Selects papers with no local
    /// PDF, an http(s) landing URL, and no paywall marker, then runs the same
    /// resolve → open-access fallback → download → extract → persist pipeline used by
    /// import_paper_from_url. Papers whose failure is paywall-shaped (access denied,
    /// login/payment required, HTML served instead of a PDF, or no open-access copy
    /// anywhere) are automatically marked paywalled so they leave the retry pool;
    /// transient failures are left untouched and reported with source IDs. No failure
    /// is ever masked with a fabricated PDF.
    ///
    /// Processes at most `limit` papers per call (default 25) so a single request stays
    /// within HTTP timeouts; call again to continue draining the backlog.
    ///
    /// The store gate is held per paper, not for the batch
    /// (`MCPToolRegistry.selfGatedToolNames`): a paper's import rewrites its whole row
    /// with what the metadata model returned, so it holds the gate alone for that one
    /// paper, and calls that arrive meanwhile run between papers.
    func downloadPapersNeedingAttention(sourceIDs: [String]?, limit: Int?) async throws -> String {
        let allSources = try await withStoreGate(.shared) {
            try knowledgeStore().loadActiveSources()
        }

        // Storage-degraded guard, mirroring the visible attention list: when many
        // recorded PDFs fail to stat at once (iCloud Drive rebuilding its local
        // replica after an OS upgrade, KB folder not synced yet), those papers are
        // NOT missing their PDFs and re-downloading them from publishers is the
        // wrong remedy. They are excluded even when explicitly requested by ID.
        let unavailableIDs = StudioViewModel.unavailableRecordedPaperPDFIDs(in: allSources)
        let unavailableNote = unavailableIDs.isEmpty ? "" :
            "\n\nNote: \(unavailableIDs.count) papers have a recorded PDF whose file isn't currently available on this Mac (usually iCloud Drive still downloading). They were excluded from this pass instead of being re-downloaded from publishers."

        func needsAttention(_ a: StudioArticle) -> Bool {
            a.sourceType == .paper
                && a.resolvedPDFPath == nil
                && !unavailableIDs.contains(a.id)
                && !a.hasPaywallMarker
                && a.url.hasPrefix("http")
                && a.state != .fetching
        }

        let allCandidates = allSources.filter(needsAttention)
        var targets = allCandidates
        if let sourceIDs, !sourceIDs.isEmpty {
            let wanted = Set(sourceIDs)
            targets = allCandidates.filter { wanted.contains($0.id) }
        }

        let totalPending = targets.count
        guard totalPending > 0 else { return "No papers need PDF attention." + unavailableNote }

        let batchSize = max(1, min(limit ?? 25, 100))
        let batch = Array(targets.prefix(batchSize))

        var downloaded: [String] = []
        var markedPaywalled: [String] = []
        var failed: [String] = []
        for article in batch {
            do {
                let detail = try await withStoreGate(.exclusive) {
                    try await downloadPaperPDFForExistingSource(
                        article.id,
                        preferOpenAccessAlternative: true
                    )
                }
                downloaded.append("✓ \(Self.sourceLink(title: article.title, id: article.id)) — \(detail)")
            } catch {
                if let evidence = Self.paperPaywallEvidence(for: error) {
                    do {
                        _ = try await withStoreGate(.exclusive) {
                            try setSourcePaywallStatus(sourceID: article.id, isPaywalled: true)
                        }
                        markedPaywalled.append("⊘ \(Self.sourceLink(title: article.title, id: article.id)) — \(evidence)")
                    } catch {
                        failed.append("✗ \(Self.sourceLink(title: article.title, id: article.id)): detected paywall (\(evidence)) but could not mark it: \(error.localizedDescription)")
                    }
                } else {
                    failed.append("✗ \(Self.sourceLink(title: article.title, id: article.id)): \(error.localizedDescription)")
                }
            }
        }

        let remaining = totalPending - batch.count
        var report = "Paper download pass: \(downloaded.count) downloaded, \(markedPaywalled.count) marked paywalled, \(failed.count) failed (of \(batch.count) attempted; \(remaining) still pending)."
        if !downloaded.isEmpty { report += "\n\nDownloaded:\n" + downloaded.joined(separator: "\n") }
        if !markedPaywalled.isEmpty {
            report += "\n\nMarked paywalled (excluded from future passes; attach a PDF with attach_pdf_to_paper or clear with set_source_paywall_status):\n"
                + markedPaywalled.joined(separator: "\n")
        }
        if !failed.isEmpty { report += "\n\nFailed (left unchanged; if you know a source is paywalled, mark it with set_source_paywall_status):\n" + failed.joined(separator: "\n") }
        if remaining > 0 { report += "\n\nCall download_papers_needing_attention again to continue (\(remaining) remaining)." }
        report += unavailableNote
        return report
    }

    /// Revisit acknowledged paywalls without first clearing their marker. A paper
    /// leaves this set only when the normal import pipeline has attached a readable
    /// PDF and persisted the cleared state. This is deliberately separate from
    /// `downloadPapersNeedingAttention`: acknowledged paywalls should not be retried
    /// during ordinary background maintenance, but an assistant must be able to
    /// perform the same explicit recheck as the Studio UI.
    ///
    /// Holds the store gate per paper, as `downloadPapersNeedingAttention` does.
    func recheckPaywalledPapers(sourceIDs: [String]?, limit: Int?) async throws -> String {
        let store = try knowledgeStore()
        let allSources = try await withStoreGate(.shared) {
            try store.loadActiveSources()
        }
        let unavailableIDs = StudioViewModel.unavailableRecordedPaperPDFIDs(in: allSources)
        let unavailableNote = unavailableIDs.isEmpty ? "" :
            "\n\nNote: \(unavailableIDs.count) papers have a recorded PDF whose file isn't currently available on this Mac. They were excluded while iCloud finishes making those files available."

        func needsRecheck(_ article: StudioArticle) -> Bool {
            article.sourceType == .paper
                && article.resolvedPDFPath == nil
                && !unavailableIDs.contains(article.id)
                && article.hasPaywallMarker
                && article.url.hasPrefix("http")
                && article.state != .fetching
        }

        var targets = allSources.filter(needsRecheck)
        if let sourceIDs, !sourceIDs.isEmpty {
            let wanted = Set(sourceIDs)
            targets = targets.filter { wanted.contains($0.id) }
        }

        let totalPending = targets.count
        guard totalPending > 0 else { return "No paywalled papers need rechecking." + unavailableNote }

        let batchSize = max(1, min(limit ?? 25, 100))
        let batch = Array(targets.prefix(batchSize))
        var recovered: [String] = []
        var failed: [String] = []

        for article in batch {
            do {
                let detail = try await withStoreGate(.exclusive) {
                    try await downloadPaperPDFForExistingSource(article.id)
                }
                recovered.append("✓ \(Self.sourceLink(title: article.title, id: article.id)) — \(detail)")
            } catch {
                // Metadata extraction can fail loudly after the readable PDF has
                // already been attached and persisted. That is still a successful
                // paywall recovery, with an explicit metadata warning.
                let reloaded: StudioArticle?
                do {
                    reloaded = try await withStoreGate(.shared) { try store.loadSourceForSync(article.id) }
                } catch {
                    logger.error("Reloading the source after a failed recovery failed: \(error.localizedDescription, privacy: .public)")
                    reloaded = nil
                }
                if let updated = reloaded,
                   updated.resolvedPDFPath != nil,
                   !updated.hasPaywallMarker {
                    recovered.append("✓ \(Self.sourceLink(title: article.title, id: article.id)) — PDF recovered; metadata processing failed: \(error.localizedDescription)")
                } else {
                    failed.append("✗ \(Self.sourceLink(title: article.title, id: article.id)): \(error.localizedDescription)")
                }
            }
        }

        let remaining = totalPending - batch.count
        var report = "Paywall recheck: \(recovered.count) recovered, \(failed.count) not recovered (of \(batch.count) attempted; \(remaining) still pending)."
        if !recovered.isEmpty { report += "\n\nRecovered:\n" + recovered.joined(separator: "\n") }
        if !failed.isEmpty { report += "\n\nStill marked paywalled:\n" + failed.joined(separator: "\n") }
        if remaining > 0 { report += "\n\nCall recheck_paywalled_papers again to continue (\(remaining) remaining)." }
        report += unavailableNote
        return report
    }

    /// Resolve and download the PDF for an existing paper source from its landing URL,
    /// falling back to an open-access alternative, then extract text + AI metadata and
    /// persist (clearing error/paywall state). Throws on any failure so the caller can
    /// classify it (paywall-shaped vs transient) and report it rather than masking it.
    func downloadPaperPDFForExistingSource(
        _ sourceID: String,
        preferOpenAccessAlternative: Bool = false
    ) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.invalidInput("Source not found: \(sourceID)")
        }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("download_papers_needing_attention requires a paper source.")
        }
        let landingURL = article.url
        let storedDOI = article.doi
        let doi = Self.nilIfBlank(storedDOI ?? "")
            ?? PaperService.extractDOI(from: landingURL)

        let papersDir = sourceContentRoot.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papersDir, withIntermediateDirectories: true)
        let destination = uniquePaperDestination(in: papersDir, doi: doi, url: landingURL)

        var alternatives: [PaperService.OpenAccessAlternativeResult] = []
        if preferOpenAccessAlternative {
            alternatives = await PaperService.findOpenAccessAlternatives(
                url: landingURL,
                title: article.title,
                doi: storedDOI
            )
        }

        // The paper this row already is: every file below is held to it, as
        // an import holds its files to the request (`PaperPDFIdentity`).
        var identity = PaperPDFIdentity.Request(
            doi: doi,
            titles: [article.title].filter { !titleNeedsReplacement($0, sourceURL: landingURL) }
        )

        func attemptDownload(from sourceURL: String) async throws -> String {
            let pageMetadata: PaperService.PaperPageMetadata?
            if sourceURL == landingURL {
                pageMetadata = await PaperService.fetchPaperPageMetadata(at: sourceURL)
            } else {
                pageMetadata = nil
            }
            let pdfURL = try await resolvedPaperPDFURL(
                sourceURL: sourceURL,
                pageMetadata: pageMetadata,
                doi: storedDOI
            )
            let paperHasPDF = article.resolvedPDFPath != nil
            let downloadedURL: String
            do {
                try await downloadPaperPDFForImport(
                    from: pdfURL, sourceURL: sourceURL, to: destination, paperHasPDF: paperHasPDF
                )
                downloadedURL = pdfURL
            } catch {
                guard sourceURL.lowercased().contains("doi.org/10.1101/"), pdfURL.contains("biorxiv.org") else {
                    throw error
                }
                let medrxivURL = pdfURL.replacingOccurrences(of: "biorxiv.org", with: "medrxiv.org")
                try await downloadPaperPDFForImport(
                    from: medrxivURL, sourceURL: sourceURL, to: destination, paperHasPDF: paperHasPDF
                )
                downloadedURL = medrxivURL
            }
            // Another paper's file throws, so the caller removes it and goes
            // on to its next candidate.
            if case .mismatch(let reason) = await PaperPDFIdentity.verdict(forPDFAt: destination, request: &identity) {
                let rejection = PaperPDFIdentityMismatchError(pdfURL: downloadedURL, reason: reason)
                recordPaperPDFIdentityMismatch(rejection, requestedURL: landingURL, request: identity, sourceID: sourceID)
                throw rejection
            }
            return downloadedURL
        }

        var candidates: [String] = []
        candidates.append(contentsOf: alternatives.map(\.replacementURL))
        candidates.append(landingURL)

        var downloadedPDFURL: String?
        var lastDownloadError: Error?
        for sourceURL in candidates {
            do {
                downloadedPDFURL = try await attemptDownload(from: sourceURL)
                break
            } catch {
                lastDownloadError = error
                try? FileManager.default.removeItem(at: destination)
            }
        }

        if downloadedPDFURL == nil, alternatives.isEmpty {
            alternatives = await PaperService.findOpenAccessAlternatives(
                url: landingURL,
                title: article.title,
                doi: storedDOI
            )
            for alternative in alternatives {
                do {
                    downloadedPDFURL = try await attemptDownload(from: alternative.replacementURL)
                    break
                } catch {
                    lastDownloadError = error
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }

        guard downloadedPDFURL != nil else {
            throw lastDownloadError ?? PaperPDFUnavailableError(sourceURL: landingURL)
        }

        guard SourceService.canOpenPDF(at: destination.path), let document = PDFDocument(url: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw MCPError.invalidInput("Downloaded file is not a readable PDF")
        }

        let firstPageText = document.page(at: 0)?.string ?? ""
        let text = try SourceService.shared.extractTextFromPDF(at: destination.path)

        article.localFilePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        article.content = text
        article.wordCount = article.content?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.prepareForPaperMetadataExtraction()
        article.isPaywalled = false
        if article.doi == nil {
            article.doi = doi
                ?? PaperService.extractDOI(from: landingURL)
                ?? Self.extractDOIFromPDF(at: destination.path)
                ?? Self.extractDOIFromText(firstPageText)
        }
        let metadataStatus: String
        do {
            metadataStatus = try await extractRequiredPaperMetadataWithAI(
                article: &article,
                firstPageText: firstPageText
            )
        } catch {
            try? store.saveSource(article)
            throw error
        }
        try store.saveSource(article)
        return "\(article.wordCount ?? 0) words; \(metadataStatus)"
    }

    // MARK: - Group management (MCP/UI parity)
}
