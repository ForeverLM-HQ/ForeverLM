// MCPDataStore: Importing local PDFs and files as sources.
import Foundation
import OSLog
import PDFKit

extension MCPDataStore {
    /// A PDF on its way in as a new paper, a local file's or one
    /// `import_paper_from_url` downloaded: in the Papers folder and saved
    /// there as a pending paper, its Paper Metadata and Source Content Cleanup
    /// still to run.
    struct StagedLocalPaper {
        var article: StudioArticle
        let destination: URL
        let firstPageText: String
        /// The sentence `importDocumentMarks` returned for the PDF's own marks.
        let marks: String
        /// The address the PDF was downloaded from; nil for a file on the Mac.
        var downloadedFrom: String? = nil

        /// How the import's answers begin.
        var answerLead: String {
            downloadedFrom == nil ? "Imported local PDF as paper" : "Imported paper"
        }
    }

    /// What staging a local or downloaded PDF came to.
    enum LocalPaperStaging {
        /// Nothing left to read: the library already held the paper, or a
        /// paper it held without a PDF took this one.
        case settled(PaperImportOutcome)
        case staged(StagedLocalPaper)
    }

    /// What reads a staged paper: the Paper Metadata model and Source Content
    /// Cleanup (`extractRequiredPaperMetadataWithAI`) unless a test hands in
    /// its own. It fills in the article and answers with its status line.
    typealias StagedPaperReader = (inout StudioArticle, String) async throws -> String

    /// Import a local PDF file from disk as a NEW paper source (copies into the synced
    /// Papers folder, extracts text). For attaching to an existing paper use attach_pdf_to_paper.
    ///
    /// The paper is saved with its PDF before any model reads it, as the app's
    /// own import saves its pending row, and a failure is saved on it rather
    /// than the PDF being taken back. On 2026-10-12 a call whose client timed
    /// out was cancelled during Source Content Cleanup: the metadata step had
    /// saved the paper as pending, and this function then deleted the PDF it
    /// had just copied, leaving a paper reading "PDF needed" with no content.
    func importLocalPDFAsPaperOutcome(
        filePath: String,
        title: String?,
        canonicalURL: String? = nil,
        connectorLabel: String? = nil
    ) async throws -> PaperImportOutcome {
        switch try await stageLocalPDFAsPaper(
            filePath: filePath,
            title: title,
            canonicalURL: canonicalURL,
            connectorLabel: connectorLabel
        ) {
        case .settled(let outcome):
            return outcome
        case .staged(let staged):
            return try await finishStagedLocalPaper(staged)
        }
    }

    /// `importLocalPDFAsPaperOutcome`'s answer alone.
    func importLocalPDFAsPaper(
        filePath: String,
        title: String?,
        canonicalURL: String? = nil,
        connectorLabel: String? = nil
    ) async throws -> String {
        try await importLocalPDFAsPaperOutcome(
            filePath: filePath,
            title: title,
            canonicalURL: canonicalURL,
            connectorLabel: connectorLabel
        ).message
    }

    /// The half of a local PDF's import that needs no model: the file checked,
    /// matched against the papers the library holds (by its provenance URL or
    /// its DOI), copied into the Papers folder and read, then saved as a
    /// pending paper together with its PDF's own highlights. The store is
    /// held only for the match and the save, so the copy and the text
    /// extraction of a long PDF queue nobody.
    func stageLocalPDFAsPaper(
        filePath: String,
        title: String?,
        canonicalURL: String? = nil,
        connectorLabel: String? = nil
    ) async throws -> LocalPaperStaging {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw MCPError.invalidInput("file_path is required.") }
        let fileURL = try validateClientProvidedPath(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MCPError.invalidInput("File not found: \(path)")
        }
        guard SourceService.canOpenPDF(at: fileURL.path) else {
            throw MCPError.invalidInput("Could not read PDF: \(path)")
        }

        let doi = Self.extractDOIFromPDF(at: fileURL.path).map(Self.normalizeDOI)
        if let settled = try await settleLocalPDFForExistingPaper(fileURL: fileURL, canonicalURL: canonicalURL, doi: doi) {
            return .settled(settled)
        }
        let baseName = doi.map { Self.safeFilenameBase($0.replacingOccurrences(of: "/", with: "-")) }
            ?? Self.safeFilenameBase(fileURL.deletingPathExtension().lastPathComponent)
        let destination = try copyFileIntoContentRoot(fileURL, folder: "Papers", baseName: baseName, fallbackExtension: "pdf")

        let pdfText: String
        do {
            pdfText = try SourceService.shared.extractTextFromPDF(at: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let relativePath = relativeSourceContentPath(destination) ?? StorageService.relativeSourcePath(destination.path)
        let resolvedTitle = Self.nilIfBlank(title ?? "")
            ?? Self.extractPDFTitle(from: destination.path)
            ?? fileURL.deletingPathExtension().lastPathComponent

        var article = StudioArticle(
            url: canonicalURL ?? relativePath,
            title: resolvedTitle,
            sourceType: .paper,
            discoveryOrigin: connectorLabel == nil ? .manual : .plugin,
            localFilePath: relativePath,
            author: StudioArticle.unknownPaperAuthor,
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: StudioArticle.unknownPaperYear
        )
        article.normalizedURL = URLNormalizer.normalize(canonicalURL ?? relativePath)
        article.connectorLabel = connectorLabel
        article.content = pdfText
        article.wordCount = pdfText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.prepareForPaperMetadataExtraction()
        article.isPaywalled = false
        article.doi = doi
        let firstPageText = PDFDocument(url: destination)?.page(at: 0)?.string ?? ""

        let pending = article
        let saved: (settled: PaperImportOutcome?, marks: String)
        do {
            saved = try await withStoreGate(.exclusive) { () async throws -> (settled: PaperImportOutcome?, marks: String) in
                // Another call may have brought in the same paper while this
                // one copied and read the file.
                if let settled = try await settleLocalPDFForExistingPaper(fileURL: fileURL, canonicalURL: canonicalURL, doi: doi) {
                    return (settled, "")
                }
                try knowledgeStore().saveSource(pending)
                return (nil, importDocumentMarks(sourceID: pending.id, pdfPath: destination.path))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if let settled = saved.settled {
            try? FileManager.default.removeItem(at: destination)
            return .settled(settled)
        }
        return .staged(StagedLocalPaper(
            article: article,
            destination: destination,
            firstPageText: firstPageText,
            marks: saved.marks
        ))
    }

    /// The paper the library already holds for a local PDF, by the PDF's
    /// provenance URL or its DOI, and what became of the PDF: a paper listed
    /// without one (paywalled, or its PDF gone) takes it, any other answers
    /// that it already exists. Nil when the paper is new.
    private func settleLocalPDFForExistingPaper(
        fileURL: URL,
        canonicalURL: String?,
        doi: String?
    ) async throws -> PaperImportOutcome? {
        try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            if let canonicalURL {
                let normalized = URLNormalizer.normalize(canonicalURL)
                if let existing = store.sourceExistsByNormalizedURL(normalized) ?? store.sourceExistsByURL(canonicalURL) {
                    if let adopted = try await adoptPDFForExistingPaper(id: existing.id, stagedPDF: fileURL, attachedFrom: fileURL.path) {
                        return PaperImportOutcome(message: adopted, sourceID: existing.id)
                    }
                    return PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                }
            }
            if let doi, let existing = try existingPaperByDOI(doi) {
                // The same paper, listed but unread — paywalled, or its PDF gone —
                // takes this file rather than turning it away.
                if let adopted = try await adoptPDFForExistingPaper(id: existing.id, stagedPDF: fileURL, attachedFrom: fileURL.path) {
                    return PaperImportOutcome(message: adopted, sourceID: existing.id)
                }
                return PaperImportOutcome(message: "Paper already exists for DOI \(doi) (id: \(existing.id)).", sourceID: existing.id)
            }
            return nil
        }
    }

    /// The half of a paper's import that the models do: Paper Metadata
    /// and Source Content Cleanup on the staged paper, then its save. It holds
    /// the store only for its reads and writes, never across a model call.
    /// Whatever stops it, the paper keeps its PDF: a failure is saved on the
    /// paper (Papers that need attention shows it, extract_paper_metadata
    /// retries it), and a stopped read leaves it pending for the app's own
    /// metadata pass to finish.
    func finishStagedLocalPaper(
        _ staged: StagedLocalPaper,
        reader: StagedPaperReader? = nil
    ) async throws -> PaperImportOutcome {
        var article = staged.article
        let metadataStatus: String
        do {
            if let reader {
                metadataStatus = try await reader(&article, staged.firstPageText)
            } else {
                metadataStatus = try await extractRequiredPaperMetadataWithAI(
                    article: &article,
                    firstPageText: staged.firstPageText
                )
            }
        } catch {
            try? await saveFinishedLocalPaper(article)
            if Task.isCancelled || AITransientErrorClassifier.isCancellation(error) { throw error }
            throw MCPError.invalidInput(
                "\(error.localizedDescription) The paper '\(article.title)' stays in the library with its PDF (id: \(article.id)), marked with this failure; extract_paper_metadata retries it."
            )
        }
        try await saveFinishedLocalPaper(article)
        guard staged.downloadedFrom != nil else {
            return PaperImportOutcome(
                message: "\(staged.answerLead) '\(article.title)' (id: \(article.id), \(article.wordCount ?? 0) words; \(metadataStatus)).\(staged.marks)",
                sourceID: article.id
            )
        }
        let metadataSummary = [
            article.author.map { "author: \($0)" },
            article.journal.map { "journal: \($0)" },
            article.publishedYear.map { "year: \($0)" },
            article.doi.map { "doi: \($0)" },
        ].compactMap { $0 }.joined(separator: ", ")
        return PaperImportOutcome(
            message: "\(staged.answerLead) '\(article.title)' (id: \(article.id), PDF: \(article.localFilePath ?? staged.destination.path), \(metadataSummary); \(metadataStatus))\(staged.marks)",
            sourceID: article.id
        )
    }

    /// Saves what the models made of a staged paper, holding the store alone
    /// for the write only. A paper deleted while they read it is not written
    /// back. A team Notebook the paper was filed in while it was read holds a
    /// copy taken from the pending row; once the paper is ready, that copy
    /// takes it again (`refreshTeamCopiesAwaitingText`), as it does after the
    /// app's own save.
    private func saveFinishedLocalPaper(_ article: StudioArticle) async throws {
        try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            guard try store.loadSourceForSync(article.id) != nil else {
                throw MCPError.notFound("The paper '\(article.title)' was deleted while its metadata was read, so nothing was saved to it.")
            }
            try store.saveSource(article)
        }
        await notebookFileStorage.refreshTeamCopiesAwaitingText(of: [article])
    }

    // MARK: - A local paper in the background

    /// At most this many local papers are read by the models at once. An
    /// assistant importing a folder sends its PDFs together; each answers as
    /// soon as it is staged, and the rest wait their turn here rather than
    /// asking the learner's models for a dozen cleanups at once.
    nonisolated static let localPaperReadingLine = MCPWaitingLine(width: 3)

    /// `import_local_pdf_as_paper` and `import_local_file`'s paper route:
    /// the paper is staged at once (in the library with its PDF) and read by
    /// the models in the background, so the call answers in seconds with the
    /// paper's id and the work's id. Before 2026-10-12 the call held the
    /// store alone for the whole read, a minute or more a paper: seven
    /// imports sent together ran one after another, every other call waited
    /// behind them, and the later imports' clients timed out.
    func importLocalPDFAsPaperInBackground(
        filePath: String,
        title: String?,
        tool: String,
        approvedSpendUSD: Double?
    ) async throws -> String {
        // Nothing could read the paper: say so now rather than after the answer.
        guard KeychainService.resolveConfig(for: .paperMetadata) != nil else {
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperMetadata)
                ?? "Paper Metadata AI is not configured. Sign in with Apple in ForeverLM and configure the Paper Metadata task."
            throw MCPError.invalidInput("Paper ingestion failed: \(reason)")
        }
        switch try await stageLocalPDFAsPaper(filePath: filePath, title: title) {
        case .settled(let outcome):
            return outcome.message
        case .staged(let staged):
            return try await readStagedPaperInBackground(staged, tool: tool, approvedSpendUSD: approvedSpendUSD)
        }
    }

    /// Starts the models on a staged paper in the background and answers with
    /// the paper's id and the work's. With no Paper Metadata model set up the
    /// paper is read at once instead, which fails before any model call, saves
    /// that failure on the paper (it keeps its PDF) and throws it, so the
    /// client hears it now rather than from Papers that need attention.
    func readStagedPaperInBackground(
        _ staged: StagedLocalPaper,
        tool: String,
        approvedSpendUSD: Double?
    ) async throws -> String {
        guard KeychainService.resolveConfig(for: .paperMetadata) != nil else {
            return try await finishStagedLocalPaper(staged).message
        }
        let workID = startStagedLocalPaperReading(staged, tool: tool, spendLimitUSD: approvedSpendUSD)
        let article = staged.article
        let pdf = staged.downloadedFrom == nil ? "" : "PDF: \(article.localFilePath ?? staged.destination.path), "
        return """
        \(staged.answerLead) '\(article.title)' (id: \(article.id), \(pdf)\(article.wordCount ?? 0) words): it is in the library with its PDF. The Paper Metadata model and Source Content Cleanup read it in the background, usually within a minute or two.\(staged.marks)
        work_id: \(workID) (list_running_ai_work shows it while it runs; cancel_ai_work stops it, and the paper keeps its PDF for extract_paper_metadata to finish)
        When it is done, the paper carries its title, authors, venue and year, and get_source_content returns its cleaned text. A failure is saved on the paper and shows under Papers that need attention.
        """
    }

    /// Reads a staged paper as background work and returns the work's id.
    /// The open window shows the paper as being read while it waits and
    /// while it is read, which also keeps the app's own metadata pass off it.
    @discardableResult
    func startStagedLocalPaperReading(
        _ staged: StagedLocalPaper,
        tool: String,
        spendLimitUSD: Double?,
        reader: StagedPaperReader? = nil
    ) -> String {
        let sourceID = staged.article.id
        // A store over another database (a test's) has no window.
        let showsInWindow = dbPathOverride == nil
        return MCPRunningWork.shared.startBackground(
            tool: tool,
            about: "paper \(staged.article.title)",
            spendLimitUSD: spendLimitUSD
        ) { @MainActor [self] in
            if showsInWindow { AppModelBridge.studio?.paperMetadataEnrichmentInFlight.insert(sourceID) }
            let callID = MCPRunningWork.currentCallID
            if let callID { MCPRunningWork.shared.setDetail(callID, "Waiting for the papers ahead of it") }
            await Self.localPaperReadingLine.enter()
            if let callID { MCPRunningWork.shared.setDetail(callID, "Reading its metadata and cleaning its text") }
            if !Task.isCancelled {
                do {
                    _ = try await finishStagedLocalPaper(staged, reader: reader)
                } catch {
                    logger.warning("MCP local paper \(sourceID, privacy: .public) was not finished: \(error.localizedDescription, privacy: .public)")
                }
            }
            await Self.localPaperReadingLine.leave()
            if showsInWindow, let studio = AppModelBridge.studio {
                studio.paperMetadataEnrichmentInFlight.remove(sourceID)
                studio.dropPaperProcessingStepIfIdle(sourceID)
            }
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
    }

    // MARK: - Any local file

    /// What `import_local_file` makes of a file.
    enum LocalFileImportKind: String {
        case paper, book, text
    }

    /// A PDF this long is taken for a book when the caller leaves `kind` to the
    /// tool: papers and reviews run to tens of pages, books to hundreds.
    nonisolated static let localPDFBookPageThreshold = 100

    nonisolated static let localTextFileExtensions: Set<String> = ["txt", "md", "markdown"]

    /// The route a file takes, from its extension, its page count (a PDF's)
    /// and the kind the caller asked for ("auto" or none lets the tool choose).
    nonisolated static func localFileImportKind(
        fileExtension rawExtension: String,
        pdfPageCount: Int?,
        requested rawRequested: String?
    ) throws -> LocalFileImportKind {
        let ext = rawExtension.lowercased()
        let requestedWord = (rawRequested ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requested: LocalFileImportKind?
        if requestedWord.isEmpty || requestedWord == "auto" {
            requested = nil
        } else if let kind = LocalFileImportKind(rawValue: requestedWord) {
            requested = kind
        } else {
            throw MCPError.invalidInput("kind must be auto, paper, book or text, not \(rawRequested ?? "").")
        }

        if ext == "pdf" {
            if requested == .text {
                throw MCPError.invalidInput("A PDF imports as a paper or a book, not as text.")
            }
            return requested ?? ((pdfPageCount ?? 0) >= localPDFBookPageThreshold ? .book : .paper)
        }
        if StudioViewModel.supportedBookFileExtensions.contains(ext) {
            guard requested == nil || requested == .book else {
                throw MCPError.invalidInput("A .\(ext) file imports only as a book.")
            }
            return .book
        }
        if localTextFileExtensions.contains(ext) {
            guard requested == nil || requested == .text else {
                throw MCPError.invalidInput("A .\(ext) file imports only as text.")
            }
            return .text
        }
        throw MCPError.invalidInput(
            "import_local_file takes PDF, EPUB, Kindle (azw, azw3, mobi, prc), plain text and Markdown (txt, md, markdown) files, not .\(ext.isEmpty ? "(none)" : ext). An audio or video file has its own tools: transcribe_meeting_recording, import_video_overview."
        )
    }

    /// Import any file on this Mac the way the app's own import of it does: a
    /// PDF as a paper (`import_local_pdf_as_paper`) or a book, an EPUB or
    /// Kindle file as a book through Add Book's importer, a text or Markdown
    /// file as a text source. A book is chapterized in the background, since a
    /// long one outlasts a tool call; the answer names its work.
    func importLocalFile(
        filePath: String,
        kind: String?,
        title: String?,
        approvedSpendUSD: Double?
    ) async throws -> String {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw MCPError.invalidInput("file_path is required.") }
        let fileURL = try validateClientProvidedPath(path)
        var isDirectory: ObjCBool = false
        // An unpacked .epub (Apple Books keeps them as folders) is a book too.
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw MCPError.invalidInput("File not found: \(path)")
        }
        let ext = fileURL.pathExtension.lowercased()
        if isDirectory.boolValue && ext != "epub" {
            throw MCPError.invalidInput("file_path names a folder, not a file: \(path)")
        }
        var pageCount: Int?
        if ext == "pdf" {
            guard let document = PDFDocument(url: fileURL) else {
                throw MCPError.invalidInput("Could not read PDF: \(path)")
            }
            pageCount = document.pageCount
        }

        let requestedWord = (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let leftToTheTool = requestedWord.isEmpty || requestedWord == "auto"
        switch try Self.localFileImportKind(fileExtension: ext, pdfPageCount: pageCount, requested: kind) {
        case .paper:
            return try await importLocalPDFAsPaperInBackground(
                filePath: fileURL.path,
                title: title,
                tool: "import_local_file",
                approvedSpendUSD: approvedSpendUSD
            )
        case .book:
            return try await Self.startLocalBookImport(
                fileURL: fileURL,
                pageCount: pageCount,
                chosenByPageCount: leftToTheTool && ext == "pdf",
                spendLimitUSD: approvedSpendUSD
            )
        case .text:
            return try await Self.importLocalTextFile(fileURL: fileURL)
        }
    }

    /// Puts a book in Add Book's line and answers at once. The import runs as
    /// this call's background work, so its model calls count against the
    /// call's spend ceiling; a failure shows in the app as Add Book's does.
    @MainActor
    private static func startLocalBookImport(
        fileURL: URL,
        pageCount: Int?,
        chosenByPageCount: Bool,
        spendLimitUSD: Double?
    ) throws -> String {
        let studio = try AppModelBridge.requireStudio()
        let name = fileURL.lastPathComponent
        let workID = MCPRunningWork.shared.startBackground(
            tool: "import_local_file",
            about: "book \(name)",
            spendLimitUSD: spendLimitUSD
        ) { @MainActor in
            do {
                try await studio.importBook(from: fileURL.path)
            } catch {
                if studio.bookImportsPending == 0 { studio.bookImportStatus = "" }
                studio.errorMessage = "Couldn’t import \(name): \(error.localizedDescription)"
                studio.showBookImportError = true
            }
        }
        let pages = pageCount.map { " (\($0) pages)" } ?? ""
        let why = chosenByPageCount
            ? " It was taken for a book because it runs to \(localPDFBookPageThreshold) pages or more; pass kind paper to import it as a paper instead."
            : ""
        return """
        Importing \(name)\(pages) as a book in the background, the way Add Book does: ForeverLM reads its title and author, splits it into chapters and files each chapter under the book. A long book takes a few minutes.\(why)
        work_id: \(workID) (list_running_ai_work shows it while it runs; cancel_ai_work stops it)
        When it is done, list_sources with source_type book, or search_sources_keyword for its title, lists the chapters. A failure shows in the app and ends the work.
        """
    }

    /// A text or Markdown file as a text source, as dropping it on the app does.
    @MainActor
    private static func importLocalTextFile(fileURL: URL) async throws -> String {
        let studio = try AppModelBridge.requireStudio()
        let path = fileURL.path
        if let held = studio.articles.first(where: { $0.url == path || $0.localFilePath == path }) {
            return "Already in the library: '\(held.title)' (id: \(held.id))."
        }
        let known = Set(studio.articles.map(\.id))
        try await studio.importTextFile(from: path)
        guard let made = studio.articles.first(where: { !known.contains($0.id) }) else {
            throw MCPError.invalidInput("Nothing was imported from \(fileURL.lastPathComponent): the file holds no text.")
        }
        return "Imported '\(made.title)' as a text source (id: \(made.id), \(made.wordCount ?? 0) words)."
    }

    static func httpURLString(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }
        return value
    }

    func resolvedPDFURLForAttachment(_ urlString: String) async throws -> String {
        if let direct = PaperService.paperPDFURL(from: urlString) {
            return direct
        }
        if let extracted = await PaperService.extractPDFURLFromWebPage(at: urlString) {
            return extracted
        }
        throw MCPError.invalidInput("No downloadable PDF URL found for \(urlString)")
    }

    func extractRequiredPaperMetadataWithAI(
        article: inout StudioArticle,
        firstPageText: String
    ) async throws -> String {
        let paperText = firstPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperText.isEmpty else {
            let message = "Paper ingestion failed: no readable paper text was available for the Paper Metadata LLM call."
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }
        guard let config = KeychainService.resolveConfig(for: .paperMetadata) else {
            // A plugin sees only this sentence, so it has to name the actual
            // blocker. Signing in fixes an absent account and nothing else.
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperMetadata)
                ?? "Paper Metadata AI is not configured. Sign in with Apple in ForeverLM and configure the Paper Metadata task."
            let message = "Paper ingestion failed: \(reason)"
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }
        let articleID = article.id
        let maximumAttempts = 3
        var result: AIService.PaperMetadataResult?
        var lastError: Error?
        var metadataMaxTokens = AIService.paperMetadataMaxTokens

        for attempt in 1...maximumAttempts {
            do {
                result = try await AIService().extractPaperMetadata(
                    source: AIUsageSource(source: article),
                    url: article.url,
                    title: article.title,
                    firstPageText: paperText,
                    maxTokens: metadataMaxTokens,
                    config: config
                )
                break
            } catch {
                // A stopped call is not a failed extraction. Retrying would
                // fail twice more at once, and recording it would mark a paper
                // failed that nothing was wrong with; the paper stays pending.
                if Task.isCancelled || AITransientErrorClassifier.isCancellation(error) { throw error }
                lastError = error
                logger.warning(
                    "MCP paper metadata extraction attempt \(attempt)/\(maximumAttempts) failed for \(articleID) using \(config.provider.shortName): \(error.localizedDescription)"
                )
                PaperIngestionDiagnostics.recordAttempt(
                    sourceID: articleID,
                    provider: config.provider.shortName,
                    attempt: attempt,
                    maximumAttempts: maximumAttempts,
                    message: error.localizedDescription
                )
                // A reasoning model that spent its whole output ceiling thinking
                // answers within a larger one.
                if case AIError.outputTokenLimit = error,
                   let raised = AIService.paperMetadataRaisedMaxTokens(after: metadataMaxTokens) {
                    metadataMaxTokens = raised
                    continue
                }
                if attempt < maximumAttempts {
                    try? await Task.sleep(for: .seconds(attempt))
                }
            }
        }

        guard let result else {
            let detail = lastError?.localizedDescription ?? "unknown error"
            let message = "Paper ingestion failed: Paper Metadata AI (\(config.provider.shortName)) failed after \(maximumAttempts) attempts: \(detail)"
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }

        // The title the model read off the PDF can have lost a glyph its font
        // could not map; the DOI's registered title restores it when the two
        // are otherwise the same title (`RegisteredPaperTitle`).
        let lookupDOI = result.doi ?? article.doi
        let registeredTitle = await PaperService.registeredTitleIfKnown(forDOI: lookupDOI)
        let updatedFields = Self.applyExtractedPaperMetadata(
            result,
            to: &article,
            registeredTitle: registeredTitle
        )
        // Mirrors the app: a field the document never prints is a blank to fill
        // in later, not a failed ingestion. Only a result that resolved no
        // bibliographic field at all reads as an extraction that did not happen.
        guard article.hasAttestablePaperMetadata else {
            // `article` keeps whatever the extractor did resolve; the caller
            // persists it, so the learner finishes from a real title rather than
            // from the dropped filename.
            let message = StudioArticle.paperMetadataIncompleteMessage(
                missing: article.missingRequiredPaperMetadataFields
            )
            recordPaperIngestionFailure(&article, message: message)
            throw MCPError.invalidInput(message)
        }

        // Cleanup runs once. A paper that already carries canonical text is here
        // for its metadata alone, and a second full-document pass would charge
        // the learner twice for the same text.
        let cleanupStatus: String
        if article.hasCompletedPaperContentCleanup {
            cleanupStatus = "Source Content Cleanup already had the canonical text"
        } else {
            // The store is read and written in stretches of their own, so a
            // caller that holds no gate (a paper import finishing in the
            // background) lets every other call run during the model calls.
            let storedRaw = try await withStoreGate(.shared) {
                try knowledgeStore().loadPaperContentPreparation(articleID)?.raw
            }
            let rawText = storedRaw ?? article.content ?? firstPageText
            do {
                let prepared = try await PaperContentPreparationService().prepare(
                    source: AIUsageSource(source: article),
                    rawText: rawText
                )
                article.installPreparedPaperContent(
                    raw: prepared.raw,
                    clean: prepared.clean,
                    metadata: prepared.metadata,
                    wordCount: prepared.wordCount
                )
            } catch where AITransientErrorClassifier.isCancellation(error) {
                // The caller went away mid-request. Nothing is known about this
                // paper, so leave the staged text queued for the durable drain
                // instead of parking it behind a failure it never earned.
                article.stagePaperContentCleanup(
                    raw: rawText,
                    rawSHA256: PaperContentPreparationService.sha256(rawText)
                )
                article.state = .queued
                article.errorMessage = nil
                let pending = article
                try? await withStoreGate(.exclusive) { try knowledgeStore().saveSource(pending) }
                NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                throw error
            } catch {
                let message = StudioArticle.paperContentCleanupFailureMessage(
                    error.localizedDescription
                )
                recordPaperIngestionFailure(&article, message: message)
                throw MCPError.invalidInput(message)
            }
            cleanupStatus = "Source Content Cleanup saved the canonical text"
        }
        guard article.completePaperMetadataExtractionAfterLLM() else {
            throw MCPError.invalidInput("Paper metadata attestation failed after content cleanup.")
        }
        let fieldSummary = updatedFields.isEmpty ? "confirmed existing metadata" : "updated \(updatedFields.joined(separator: ", "))"
        let blanks = article.missingRequiredPaperMetadataFields
        let blankSummary = blanks.isEmpty ? "" : "; the document prints no \(blanks.joined(separator: ", "))"
        return "Paper Metadata AI \(fieldSummary); \(cleanupStatus)\(blankSummary)"
    }

    private func recordPaperIngestionFailure(
        _ article: inout StudioArticle,
        message: String
    ) {
        article.failPaperIngestionMetadata(message)
        PaperIngestionDiagnostics.recordFailure(
            sourceID: article.id,
            title: article.title,
            message: message
        )
    }

    /// `registeredTitle` is the title the paper's DOI is registered under,
    /// when known; see `StudioViewModel.applyExtractedPaperMetadata`, whose
    /// rule this is.
    static func applyExtractedPaperMetadata(
        _ result: AIService.PaperMetadataResult,
        to article: inout StudioArticle,
        registeredTitle: String? = nil
    ) -> [String] {
        var updatedFields: [String] = []
        if let title = result.title, !title.isEmpty, article.title != title {
            article.title = title
            updatedFields.append("title")
        }
        if let restored = RegisteredPaperTitle.restoringLostCharacters(
            in: article.title,
            registered: registeredTitle
        ) {
            article.title = restored
            if !updatedFields.contains("title") { updatedFields.append("title") }
        }
        if let doi = result.doi, article.doi != doi {
            article.doi = doi
            updatedFields.append("DOI")
        }
        if let author = result.author, article.author != author {
            article.author = author
            updatedFields.append("author")
        }
        if let journal = result.journal, article.journal != journal {
            article.journal = journal
            updatedFields.append("journal")
        }
        if let year = result.year, article.publishedYear != year {
            article.publishedYear = year
            updatedFields.append("year")
        }
        return updatedFields
    }
}
