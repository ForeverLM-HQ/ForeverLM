import Foundation
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    /// Import a PDF file as a new paper article.
    /// Copies the file to ForeverLM/Papers/ and creates a new StudioArticle.
    /// Finder drops pass `selectInReader: false`: PDFKit 26 starts its private
    /// Vision document-analysis renderer as soon as a selected document is
    /// displayed, and assigning the document while AppKit is completing the
    /// drag can deadlock or abort inside the framework. Importing and rendering
    /// are separate user actions; the row is visible without opening PDFKit.
    ///
    /// Highlights and notes another app saved inside the PDF come in with it
    /// as the paper's own highlights (`importPDFMarks`). A caller that brings
    /// marks of its own for the same file (the Zotero import) passes
    /// `importsDocumentMarks: false` and reads both in one pass.
    @discardableResult
    func importPDF(
        from sourcePath: String,
        revealInLibrary: Bool = true,
        reportsExistingPaper: Bool = true,
        destinationFilename: String? = nil,
        processImmediately: Bool = true,
        selectInReader: Bool = true,
        importsDocumentMarks: Bool = true
    ) async throws -> String {
        let presentsPaperImportUI = revealInLibrary || reportsExistingPaper
        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        let preferredPath = (papersDir as NSString).appendingPathComponent(
            destinationFilename ?? (sourcePath as NSString).lastPathComponent
        )

        // File checks, the copy into the iCloud-synced Papers directory, and the
        // two PDFDocument opens all block — keep them off the main actor.
        let extraction = try await Task.detached(priority: .userInitiated) { () -> (destPath: String, title: String?, doi: String?) in
            let fm = FileManager.default
            guard fm.fileExists(atPath: sourcePath) else {
                throw SourceError.fileNotFound
            }
            try? fm.createDirectory(atPath: papersDir, withIntermediateDirectories: true)

            // A Papers file with this name may already hold a different paper:
            // every PDF dropped without a filename used to land on
            // `Dropped Paper.pdf`, so the second such drop skipped its copy and
            // "imported" whatever paper the first drop had left there. Only a
            // byte-identical file is the same paper; anything else gets a
            // numbered sibling.
            let destPath = Self.paperDestinationPath(
                preferred: preferredPath,
                source: sourcePath,
                fileManager: fm
            )
            if sourcePath != destPath && !fm.fileExists(atPath: destPath) {
                try fm.copyItem(atPath: sourcePath, toPath: destPath)
            }
            guard SourceService.canOpenPDF(at: destPath) else {
                throw SourceError.pdfReadFailed
            }
            // The main actor answers `resolvedPDFPath` from the path cache alone,
            // and a path it has never statted reads as absent. Left cold, the
            // metadata step below decided the freshly copied PDF was not there,
            // returned without a model call, and the row sat at "Unknown authors"
            // until a later sweep noticed it. Stat it here, off the main actor.
            StudioArticle.invalidateResolvedPathCache(forRawPaths: [destPath])
            _ = StudioArticle.warmResolvedLocalPathCache(forRawPaths: [destPath])

            #if canImport(PDFKit)
            return (destPath, Self.extractPDFTitle(from: destPath), Self.extractDOIFromPDF(at: destPath))
            #else
            return (destPath, nil, nil)
            #endif
        }.value
        let destPath = extraction.destPath
        let filename = (destPath as NSString).lastPathComponent

        // Check if already in the queue by file path
        if let existingIndex = articles.firstIndex(where: { $0.url == destPath || $0.localFilePath == destPath }) {
            let articleID = articles[existingIndex].id
            attachingPDFIds.insert(articleID)
            defer { attachingPDFIds.remove(articleID) }
            if articles[existingIndex].sourceType != .paper {
                convertPaperToLocalPDF(
                    at: existingIndex,
                    destPath: destPath,
                    doi: extraction.doi,
                    updateDateAdded: true
                )
                guard await persistSource(articles[existingIndex], context: "Save imported PDF") else {
                    throw SourceError.fetchFailed
                }
            }
            if importsDocumentMarks {
                await importPDFMarksReportingFailure(into: articleID, pdfPath: destPath)
            }
            if processImmediately && !articles[existingIndex].isPaperReadyForListenPreparation {
                guard await enrichPaperMetadataAfterPDFAttachment(
                    articleId: articleID,
                    userInitiated: presentsPaperImportUI
                ) else {
                    throw stalledPaperIngestionError(for: articleID)
                }
            }
            await mergeEquivalentPaperDuplicates(into: articleID)
            if reportsExistingPaper {
                errorMessage = "This paper is already in your queue."
            }
            if revealInLibrary {
                switchTab(to: .papers)
                if selectInReader {
                    selectedArticleId = articleID
                } else if selectedArticleId == articleID {
                    selectedArticleId = nil
                    deselectSourcesInEveryWindow([articleID])
                }
            }
            return articleID
        }

        let cleanName = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
        let title = extraction.title ?? cleanName
        let doi = extraction.doi

        // Check if an existing source matches — by DOI, normalized title, or
        // PDF filename in the URL path. Covers both existing .paper rows and
        // URL-based .article/.manual/.unclassified rows whose web URL points
        // to the same PDF (e.g. studenttheses.uu.nl/…/foo.pdf?sequence=1).
        // When a match is found, convert the existing row to a local-PDF paper
        // instead of creating a duplicate.
        let normalizedTitle = Self.normalizedPaperTitle(title)
        if let existingIdx = articles.firstIndex(where: { existing in
            switch existing.sourceType {
            case .paper, .article, .manual, .unclassified: break
            default: return false
            }
            if let doi, !doi.isEmpty, let eDOI = existing.doi, eDOI.lowercased() == doi.lowercased() { return true }
            if !normalizedTitle.isEmpty && Self.normalizedPaperTitle(existing.title) == normalizedTitle { return true }
            if let webFilename = Self.pdfFilenameFromWebURL(existing.url),
               webFilename.caseInsensitiveCompare(filename) == .orderedSame { return true }
            return false
        }) {
            let articleId = articles[existingIdx].id
            attachingPDFIds.insert(articleId)
            defer { attachingPDFIds.remove(articleId) }
            convertPaperToLocalPDF(at: existingIdx, destPath: destPath, doi: doi, updateDateAdded: true)
            guard await persistSource(articles[existingIdx], context: "Save imported PDF") else {
                throw SourceError.fetchFailed
            }
            if importsDocumentMarks {
                await importPDFMarksReportingFailure(into: articleId, pdfPath: destPath)
            }
            if revealInLibrary {
                switchTab(to: .papers)
                if selectInReader {
                    selectedArticleId = articleId
                } else if selectedArticleId == articleId {
                    selectedArticleId = nil
                    deselectSourcesInEveryWindow([articleId])
                }
            }
            await mergeEquivalentPaperDuplicates(into: articleId)
            if processImmediately {
                guard await enrichPaperMetadataAfterPDFAttachment(
                    articleId: articleId,
                    userInitiated: presentsPaperImportUI
                ) else {
                    throw stalledPaperIngestionError(for: articleId)
                }
            }
            return articleId
        }

        var article = StudioArticle(
            url: destPath,
            title: title,
            sourceType: .paper,
            discoveryOrigin: .localPapers,
            localFilePath: destPath
        )
        article.domain = "Local PDF"
        article.prepareForPaperMetadataExtraction()
        article.doi = doi
        // Persist a visible pending row, then synchronously run the mandatory
        // paper-content LLM gate. A failed call leaves an explicit error record;
        // it never becomes a successfully ingested paper.
        _ = Self.finalizeRequiredPaperMetadata(for: &article)

        // Claim the row for Processing before its first observable insertion.
        // `await enrichPaperMetadataAfterPDFAttachment` may yield before its own
        // phase marker is installed; without this outer marker SwiftUI can draw
        // one frame of the ordinary Papers list with placeholder metadata.
        attachingPDFIds.insert(article.id)
        defer { attachingPDFIds.remove(article.id) }
        let inserted = try await storage.insertSourceIfNew(&article)
        guard inserted else {
            throw SourceError.fetchFailed
        }
        articles.insert(article, at: 0)
        if revealInLibrary {
            switchTab(to: .papers)
            if selectInReader {
                selectedArticleId = article.id
            }
        }
        if importsDocumentMarks {
            await importPDFMarksReportingFailure(into: article.id, pdfPath: destPath)
        }

        if processImmediately {
            if !(await enrichPaperMetadataAfterPDFAttachment(
                articleId: article.id,
                userInitiated: presentsPaperImportUI
            )) {
                throw stalledPaperIngestionError(for: article.id)
            }
        }
        return article.id
    }

    /// Brings the highlights and notes another app made on a paper's PDF in
    /// as the paper's own highlights, and returns how many were new: those
    /// saved inside the file at `pdfPath` (Preview, Acrobat, a PDF exported
    /// with its annotations from Paperpile or Mendeley), plus `libraryMarks` a
    /// reference manager keeps outside it (Zotero), measured against the same
    /// file. Reading the PDF happens off the main actor; the insert goes
    /// through the storage actor, which skips marks already brought in.
    @discardableResult
    func importPDFMarks(
        into sourceID: String,
        pdfPath: String,
        libraryMarks: [ImportedPDFMark] = []
    ) async throws -> Int {
        let now = Date()
        let highlights = await Task.detached(priority: .utility) { () -> [SourceHighlight] in
            guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return [] }
            let marks = ReaderPDFHighlightSupport.embeddedMarks(in: document) + libraryMarks
            return ReaderPDFHighlightSupport.importedHighlights(
                marks,
                sourceID: sourceID,
                in: document,
                importedAt: now
            )
        }.value
        guard !highlights.isEmpty else { return 0 }
        let added = try await storage.insertImportedSourceHighlights(highlights)
        if added > 0, readerHighlights[sourceID] != nil {
            await reloadReaderHighlights(for: sourceID)
        }
        return added
    }

    /// For a PDF dropped or chosen by hand: the paper is in either way, so a
    /// failure to bring its marks costs only the marks, and says so.
    private func importPDFMarksReportingFailure(into sourceID: String, pdfPath: String) async {
        do {
            let added = try await importPDFMarks(into: sourceID, pdfPath: pdfPath)
            if added > 0 {
                logger.info("[PDFImport] Brought in \(added) highlights saved in \((pdfPath as NSString).lastPathComponent, privacy: .public)")
            }
        } catch {
            logger.error("[PDFImport] Could not bring in the PDF's highlights: \(error.localizedDescription, privacy: .public)")
            showToast("Imported the paper, but not the highlights saved in its PDF")
        }
    }

    /// Where an imported PDF lands inside Papers. The preferred name is kept
    /// when nothing is there yet, or when the file already there is the same
    /// bytes (a re-import of the same paper dedups on the path). A different
    /// file under that name is a different paper, so the import moves to the
    /// first free numbered sibling — `Dropped Paper 2.pdf` — instead of
    /// silently adopting the existing paper's row.
    nonisolated static func paperDestinationPath(
        preferred: String,
        source: String,
        fileManager: FileManager = .default
    ) -> String {
        guard preferred != source, fileManager.fileExists(atPath: preferred) else { return preferred }
        if filesHaveIdenticalContents(preferred, source, fileManager: fileManager) { return preferred }

        let directory = (preferred as NSString).deletingLastPathComponent
        let baseName = ((preferred as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        for suffix in 2...999 {
            let candidateName = ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)"
            let candidate = (directory as NSString).appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate)
                || filesHaveIdenticalContents(candidate, source, fileManager: fileManager) {
                return candidate
            }
        }
        return preferred
    }

    nonisolated private static func filesHaveIdenticalContents(
        _ lhs: String,
        _ rhs: String,
        fileManager: FileManager
    ) -> Bool {
        guard let lhsSize = try? fileManager.attributesOfItem(atPath: lhs)[.size] as? NSNumber,
              let rhsSize = try? fileManager.attributesOfItem(atPath: rhs)[.size] as? NSNumber,
              lhsSize == rhsSize else { return false }
        return fileManager.contentsEqual(atPath: lhs, andPath: rhs)
    }

    struct ReferenceLibraryImportReport: Sendable {
        let discoveredCount: Int
        let importedCount: Int
        let existingCount: Int
        let failedCount: Int
        /// Highlights and notes brought in with the papers, new ones only.
        var highlightCount: Int = 0
        let warnings: [String]

        var summary: String {
            var parts = ["Imported \(importedCount) paper\(importedCount == 1 ? "" : "s")"]
            if existingCount > 0 { parts.append("\(existingCount) already in your library") }
            if highlightCount > 0 {
                parts.append("\(highlightCount) highlight\(highlightCount == 1 ? "" : "s") and note\(highlightCount == 1 ? "" : "s")")
            }
            if failedCount > 0 { parts.append("\(failedCount) failed") }
            return parts.joined(separator: " · ")
        }

        var summaryAndWarnings: (summary: String, warnings: [String]) { (summary, warnings) }
    }

    /// Import a complete reference-manager library from a Zotero data directory,
    /// BibTeX/RIS export, PDF folder, or any combination of those selections.
    /// Inventory parsing and PDF inspection stay off-main; inserts go through the
    /// storage actor so CloudKit metadata/change rows remain atomic with sources.
    func importReferenceLibrary(from selections: [URL]) async throws -> ReferenceLibraryImportReport {
        guard !selections.isEmpty else {
            return ReferenceLibraryImportReport(
                discoveredCount: 0,
                importedCount: 0,
                existingCount: 0,
                failedCount: 0,
                warnings: []
            )
        }

        isImportingReferenceLibrary = true
        referenceLibraryImportStatus = "Reading library…"
        defer {
            isImportingReferenceLibrary = false
            referenceLibraryImportStatus = nil
        }

        let inventory = try await Task.detached(priority: .userInitiated) {
            try ReferenceLibraryImportService.inventory(from: selections)
        }.value

        var imported = 0
        var existing = 0
        var failed = 0
        var highlights = 0
        var warnings = inventory.warnings

        for (offset, entry) in inventory.entries.enumerated() {
            guard !Task.isCancelled else { throw CancellationError() }
            referenceLibraryImportStatus = "Importing \(offset + 1) of \(inventory.entries.count)…"
            await Task.yield()

            do {
                let matchingID = matchingReferenceLibraryPaperID(for: entry)
                let hadExistingPaper = matchingID != nil
                let articleID: String

                if let pdfPath = entry.pdfPath,
                   matchingID.flatMap({ id in
                       articles.first(where: { $0.id == id })?.localFilePath
                   }) == nil {
                    articleID = try await importPDF(
                        from: pdfPath,
                        revealInLibrary: false,
                        reportsExistingPaper: false,
                        destinationFilename: entry.destinationFilename,
                        processImmediately: false,
                        importsDocumentMarks: false
                    )
                } else if let matchingID {
                    articleID = matchingID
                } else {
                    var article = StudioArticle(
                        url: entry.stableCatalogURL,
                        title: entry.title,
                        sourceType: .paper,
                        discoveryOrigin: .localPapers,
                        publicURL: entry.url,
                        author: entry.authors,
                        journal: entry.journal,
                        publishedYear: entry.year
                    )
                    article.domain = entry.sourceName
                    article.doi = entry.doi
                    if let dateAdded = entry.dateAdded { article.dateAdded = dateAdded }
                    article.prepareForPaperMetadataExtraction()
                    guard try await storage.insertSourceIfNew(&article) else {
                        existing += 1
                        continue
                    }
                    articles.insert(article, at: 0)
                    articleID = article.id
                }

                guard let current = articles.first(where: { $0.id == articleID }) else {
                    throw SourceError.fetchFailed
                }
                var updated = current
                mergeReferenceLibraryMetadata(entry, into: &updated, overwriteTitle: !hadExistingPaper)
                guard await persistSource(
                    updated,
                    context: "Save imported reference-library metadata",
                    showErrorToast: false
                ) else {
                    throw SourceError.fetchFailed
                }
                if let latestIndex = articles.firstIndex(where: { $0.id == articleID }) {
                    articles[latestIndex] = updated
                }

                // The marks are measured against the reference manager's own
                // copy of the PDF, which is also what was copied into Papers.
                // A paper already here keeps its own PDF and gains the marks;
                // the reader re-finds them by their words if its pages differ.
                if let pdfPath = entry.pdfPath {
                    do {
                        highlights += try await importPDFMarks(
                            into: articleID,
                            pdfPath: pdfPath,
                            libraryMarks: entry.marks
                        )
                    } catch {
                        warnings.append("\(entry.title): the paper was imported without its highlights (\(error.localizedDescription)).")
                    }
                }

                if hadExistingPaper {
                    existing += 1
                } else {
                    imported += 1
                }
            } catch {
                failed += 1
                warnings.append("\(entry.title): \(error.localizedDescription)")
            }
        }

        // Start the existing serial paper queue only after the complete catalog
        // is visible. Large libraries therefore import quickly and then ingest
        // PDFs one at a time without a burst of AI/network work.
        autoFetchNewlyAddedPapers()

        switchTab(to: .papers)
        return ReferenceLibraryImportReport(
            discoveredCount: inventory.entries.count,
            importedCount: imported,
            existingCount: existing,
            failedCount: failed,
            highlightCount: highlights,
            warnings: warnings
        )
    }

    /// Import the saved articles of a read-later app from its export: a CSV,
    /// bookmarks HTML, JSON or a folder holding them. Each URL becomes a source
    /// the way a Reading List entry does, with the export's title, date and read
    /// state; nothing is fetched here. The serial initial-fetch queue and the
    /// paper queue read them afterwards, so a library of thousands arrives in
    /// seconds without a burst of network work.
    func importReadLaterExport(from selections: [URL]) async throws -> ReadLaterImportReport {
        guard !selections.isEmpty else {
            return ReadLaterImportReport(importedCount: 0, existingCount: 0, skippedCount: 0, failedCount: 0, warnings: [])
        }

        isImportingReadLaterExport = true
        readLaterImportStatus = "Reading export…"
        defer {
            isImportingReadLaterExport = false
            readLaterImportStatus = nil
        }

        let inventory = try await Task.detached(priority: .userInitiated) {
            try ReadLaterExportImportService.inventory(from: selections)
        }.value

        var imported = 0
        var existing = 0
        var skipped = 0
        var failed = 0
        var warnings = inventory.warnings
        let knownURLs = Set(articles.map { URLNormalizer.normalize($0.url) })
        // `articles` re-indexes the library on every change, so new rows join it
        // in batches rather than one insert per row.
        var pending: [StudioArticle] = []
        func publishPending() {
            guard !pending.isEmpty else { return }
            articles.insert(contentsOf: pending.reversed(), at: 0)
            pending.removeAll()
        }
        defer { publishPending() }

        for (offset, entry) in inventory.entries.enumerated() {
            guard !Task.isCancelled else { throw CancellationError() }
            if offset % 50 == 0 {
                publishPending()
                readLaterImportStatus = "Importing \(offset + 1) of \(inventory.entries.count)…"
                await Task.yield()
            }
            // What the source bar would refuse or send elsewhere (a linked page,
            // a playlist, a podcast page) is not an article here either.
            if Self.linkedPageKind(forSourceURL: entry.url) != nil
                || Self.sourceRefusal(forSourceURL: entry.url) != nil
                || YouTubePlaylistService.isPlaylistURL(entry.url)
                || GeminiNotebookService.isNotebookURL(entry.url) {
                skipped += 1
                continue
            }
            let sourceType = Self.detectSourceType(url: entry.url)
            guard sourceType != .podcast else {
                skipped += 1
                continue
            }
            if knownURLs.contains(URLNormalizer.normalize(entry.url)) {
                existing += 1
                continue
            }

            let host = URL(string: entry.url)?.host ?? entry.url
            var article = StudioArticle(
                url: entry.url,
                title: entry.title ?? host,
                sourceType: sourceType,
                discoveryOrigin: .manual
            )
            article.domain = host
            if let dateAdded = entry.dateAdded { article.dateAdded = dateAdded }
            if entry.isRead { article.readAt = entry.dateAdded ?? Date() }
            if sourceType == .paper { article.prepareForPaperMetadataExtraction() }
            do {
                guard try await storage.insertSourceIfNew(&article) else {
                    existing += 1
                    continue
                }
                pending.append(article)
                imported += 1
            } catch {
                failed += 1
                warnings.append("\(entry.title ?? entry.url): \(error.localizedDescription)")
            }
        }

        publishPending()
        autoFetchUnfetchedSources()
        autoFetchNewlyAddedPapers()
        return ReadLaterImportReport(
            importedCount: imported,
            existingCount: existing,
            skippedCount: skipped,
            failedCount: failed,
            warnings: warnings
        )
    }

    struct ReadLaterImportReport: Sendable {
        let importedCount: Int
        let existingCount: Int
        let skippedCount: Int
        let failedCount: Int
        let warnings: [String]

        var summary: String {
            var parts = ["Imported \(importedCount) article\(importedCount == 1 ? "" : "s")"]
            if existingCount > 0 { parts.append("\(existingCount) already in your library") }
            if skippedCount > 0 { parts.append("\(skippedCount) not articles") }
            if failedCount > 0 { parts.append("\(failedCount) failed") }
            return parts.joined(separator: " · ")
        }
    }

    private func matchingReferenceLibraryPaperID(for entry: ReferenceLibraryImportService.Entry) -> String? {
        if let doi = entry.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty {
            let normalized = Self.normalizeDOI(doi)
            if let match = articles.first(where: {
                $0.sourceType == .paper
                    && ($0.doi.map(Self.normalizeDOI) == normalized
                        || PaperService.extractDOI(from: $0.url).map(Self.normalizeDOI) == normalized)
            }) {
                return match.id
            }
        }
        let normalizedTitle = Self.normalizedPaperTitle(entry.title)
        guard !normalizedTitle.isEmpty else { return nil }
        return articles.first(where: {
            $0.sourceType == .paper && Self.normalizedPaperTitle($0.title) == normalizedTitle
        })?.id
    }

    private func mergeReferenceLibraryMetadata(
        _ entry: ReferenceLibraryImportService.Entry,
        into article: inout StudioArticle,
        overwriteTitle: Bool
    ) {
        if overwriteTitle || Self.titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
            article.title = entry.title
        }
        if article.paperAuthorNeedsEnrichment, let authors = entry.authors, !authors.isEmpty {
            article.author = authors
        }
        if article.paperJournalNeedsEnrichment, let journal = entry.journal, !journal.isEmpty {
            article.journal = journal
        }
        if article.paperYearNeedsEnrichment, let year = entry.year, !year.isEmpty {
            article.publishedYear = year
        }
        if article.doi?.isEmpty != false, let doi = entry.doi, !doi.isEmpty {
            article.doi = doi
        }
        if article.publicURL?.isEmpty != false,
           let url = entry.url,
           url.hasPrefix("http://") || url.hasPrefix("https://") {
            article.publicURL = url
        }
        if overwriteTitle, let dateAdded = entry.dateAdded {
            article.dateAdded = dateAdded
        }
    }

    /// Import a book (PDF, EPUB, or DRM-free Kindle): copy to ForeverLM/Books/, split into chapters, and add entries.
    #if canImport(PDFKit)
    /// Imports one book. A book asked for while another is importing waits
    /// for it, so the learner can keep adding books without the two runs
    /// writing over each other's progress, identity checks or library reload.
    func importBook(from sourcePath: String, kind: String? = nil) async throws {
        try await enqueueBookImport(from: sourcePath, kind: kind).value
    }

    /// Puts a book in line now and returns its run, so books picked together
    /// import in the order they were picked.
    func enqueueBookImport(from sourcePath: String, kind: String? = nil) -> Task<Void, Error> {
        bookImportsPending += 1
        let previous = bookImportTail
        let run = Task { @MainActor in
            defer { self.bookImportsPending -= 1 }
            _ = await previous?.value
            try await self.importBookNow(from: sourcePath, kind: kind)
        }
        bookImportTail = Task { _ = await run.result }
        return run
    }

    private func importBookNow(from sourcePath: String, kind: String?) async throws {
        let fm = FileManager.default
        logger.info("[BookImport] Starting import from: \(sourcePath)")
        guard fm.fileExists(atPath: sourcePath) else {
            logger.error("[BookImport] File not found at: \(sourcePath)")
            throw SourceError.fileNotFound
        }

        let sourceExt = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
        guard Self.supportedBookFileExtensions.contains(sourceExt) else {
            throw SourceError.unsupportedBookFormat
        }

        let isKindle = Self.kindleBookFileExtensions.contains(sourceExt)
        var importPath = sourcePath
        var convertedKindleTempDir: String?
        if isKindle {
            logger.info("[BookImport] File type: Kindle")
            bookImportStatus = "Converting Kindle book to EPUB…"
            await Task.yield()
            let converted = try await Task.detached(priority: .userInitiated) {
                try Self.convertKindleBookToEPUB(sourcePath: sourcePath)
            }.value
            importPath = converted.epubPath
            convertedKindleTempDir = converted.tempDir
        }
        defer {
            if let convertedKindleTempDir {
                try? FileManager.default.removeItem(atPath: convertedKindleTempDir)
            }
        }

        let isEPUB = importPath.lowercased().hasSuffix(".epub")
        logger.info("[BookImport] File type: \(isEPUB ? "EPUB" : "PDF")")
        bookImportStatus = isEPUB ? "Copying EPUB…" : "Copying PDF…"
        sidebarTab = .books
        await Task.yield()
        defer { bookImportStatus = "" }

        let booksDir = (knowledgeBasePath as NSString).appendingPathComponent("Books")
        logger.info("[BookImport] Books dir: \(booksDir)")

        let importedFile = try await Task.detached(priority: .userInitiated) {
            try Self.copyBookFileAndExtractMetadata(sourcePath: importPath, booksDir: booksDir)
        }.value
        logger.info("[BookImport] Prepared file at: \(importedFile.destPath)")

        var bookTitle = importedFile.importedTitle
        var bookSubtitle = importedFile.importedSubtitle
        var bookAuthor = importedFile.importedAuthor
        var bookEdition = importedFile.importedEdition
        let trimmedImportedTitle = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preflightTitle = trimmedImportedTitle.isEmpty
            ? (importedFile.destPath as NSString).deletingPathExtension
            : trimmedImportedTitle
        let preflightCleanTitle = Self.cleanBookTitle(
            preflightTitle,
            subtitle: bookSubtitle,
            edition: bookEdition
        )
        // Choose the durable book identity before the first model call. The book
        // directory check preserves an existing ID even when AI improves its title.
        let bookID = existingBookID(
            forCleanedTitle: preflightCleanTitle,
            bookDir: importedFile.bookDir
        ) ?? UUID().uuidString
        let usageSource = AIUsageSource(id: bookID, type: "book", title: preflightTitle)

        if let config = KeychainService.resolveConfig(for: .bookAuthor) {
            bookImportStatus = "Extracting book metadata…"
            await Task.yield()
            if let aiMetadata = await aiService.extractBookMetadata(
                source: usageSource,
                filename: (importedFile.destPath as NSString).lastPathComponent,
                title: bookTitle,
                author: bookAuthor,
                firstPagesText: importedFile.firstPagesText,
                config: config
            ) {
                if let title = aiMetadata.title {
                    bookTitle = title
                }
                if let subtitle = aiMetadata.subtitle {
                    bookSubtitle = subtitle
                }
                if let author = aiMetadata.author {
                    bookAuthor = author
                }
                if let edition = aiMetadata.edition {
                    bookEdition = edition
                }
            }
        }

        guard let extractedTitle = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extractedTitle.isEmpty else {
            throw SourceError.bookMetadataMissing
        }
        // Guard against importing a scholarly paper as a book. Instead of matching
        // hardcoded title patterns, ask the source classifier (LLM) using the title
        // and extracted front matter. Best-effort: if classification is unavailable
        // or fails it returns nil, and we honor the user's explicit book import.
        if let classifyConfig = KeychainService.resolveConfig(for: .sourceClassification),
           await aiService.classifySourceType(
               source: usageSource,
               url: importedFile.destPath,
               title: extractedTitle,
               contentPreview: importedFile.firstPagesText,
               config: classifyConfig
           ) == .paper {
            throw SourceError.scholarlyPaperNotBook
        }
        let cleanedBookTitle = Self.cleanBookTitle(extractedTitle, subtitle: bookSubtitle, edition: bookEdition)

        bookTitles[bookID] = cleanedBookTitle
        if let bookSubtitle { bookSubtitles[bookID] = bookSubtitle }
        if let bookAuthor { bookAuthors[bookID] = bookAuthor }
        if let bookEdition { bookEditions[bookID] = bookEdition }
        if let kind, !kind.isEmpty { bookKinds[bookID] = kind }

        // An explicit re-import of a known book revives its chapter records.
        let groupedChapterCount = (try? await storage.sourceCountByParentGroup(bookID)) ?? 0
        if groupedChapterCount > 0 {
            if isEPUB {
                logger.info("[BookImport] Rebuilding existing EPUB chapter records for explicit re-import")
                try? await storage.saveBookMetadata(
                    groupName: bookID,
                    title: cleanedBookTitle,
                    subtitle: bookSubtitle,
                    author: bookAuthor,
                    edition: bookEdition,
                    coverPath: bookCoverPaths[bookID],
                    kind: kind
                )
            } else {
                logger.info("[BookImport] Rebuilding existing PDF chapter records for explicit re-import")
            }
        }

        if isEPUB {
            logger.info("[BookImport] Extracting EPUB chapters…")
            try await importEPUBChapters(from: importedFile.destPath, bookID: bookID, bookTitle: cleanedBookTitle, bookDir: importedFile.bookDir, chaptersDir: importedFile.chaptersDir)
        } else {
            logger.info("[BookImport] Extracting PDF chapters…")
            try await importPDFChapters(from: importedFile.destPath, baseName: importedFile.baseName, bookID: bookID, bookTitle: cleanedBookTitle, bookDir: importedFile.bookDir, chaptersDir: importedFile.chaptersDir)
        }

        // Immediately register the cover so it's visible after loadQueue
        let coverPath = (importedFile.bookDir as NSString).appendingPathComponent("cover.jpg")
        if FileManager.default.fileExists(atPath: coverPath) {
            bookTitles[bookID] = cleanedBookTitle
            bookCoverPaths[bookID] = coverPath
            try? await storage.saveBookMetadata(
                groupName: bookID,
                title: cleanedBookTitle,
                subtitle: bookSubtitle,
                author: bookAuthor,
                edition: bookEdition,
                coverPath: coverPath
            )
            // Pre-warm the thumbnail cache so it renders instantly
            prewarmBookCoverThumbnail(coverPath: coverPath)
        }

        bookImportStatus = "Refreshing library…"
        sidebarTab = .books
        await loadQueue()
        var needsSave = false
        if let bookSubtitle, !bookSubtitle.isEmpty {
            bookSubtitles[bookID] = bookSubtitle
            needsSave = true
        }
        if let bookAuthor, !bookAuthor.isEmpty {
            bookAuthors[bookID] = bookAuthor
            needsSave = true
        }
        if let bookEdition, !bookEdition.isEmpty {
            bookEditions[bookID] = bookEdition
            needsSave = true
        }
        if let kind, !kind.isEmpty {
            bookKinds[bookID] = kind
            needsSave = true
        }
        let finalCoverPath = bookCoverPaths[bookID]
        do {
            try await storage.saveBookMetadata(
                groupName: bookID,
                title: cleanedBookTitle,
                subtitle: bookSubtitle,
                author: bookAuthor,
                edition: bookEdition,
                coverPath: finalCoverPath,
                kind: kind
            )
        } catch {
            logger.error("Failed to save final book metadata: \(error.localizedDescription)")
            if needsSave { saveBooksToDisk() }
        }
        logger.info("[BookImport] Import complete for \(importedFile.baseName)")
    }

    /// Turns browser-authored book-file Source shells into the same chapterized
    /// Book records produced by the native Add Book flow. CloudKit materializes
    /// the original off-main before publishing the queued shell, and this drain
    /// is launched only from initial-load or remote-change events.
    func drainPendingWebBookImports() async {
        let candidates = articles.filter { article in
            guard article.sourceType == .book,
                  article.state == .queued,
                  article.url.split(separator: "/").contains("Web Imports"),
                  let path = article.localFilePath else { return false }
            let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            return fileExtension == "pdf" || fileExtension == "epub"
        }

        for article in candidates {
            guard !pendingWebBookImportsAttempted.contains(article.id),
                  pendingWebBookImportsInFlight.insert(article.id).inserted,
                  let path = article.localFilePath else { continue }
            pendingWebBookImportsAttempted.insert(article.id)
            defer { pendingWebBookImportsInFlight.remove(article.id) }
            do {
                try await importBook(from: path)
                try await storage.deleteSource(article.id)
                await refreshArticles()
                logger.info("[BookImport] Expanded Web Studio book \(article.id, privacy: .public)")
            } catch {
                logger.error(
                    "[BookImport] Failed to expand Web Studio book \(article.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                errorMessage = "Could not import \(article.title): \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func copyBookFileAndExtractMetadata(sourcePath: String, booksDir: String) throws -> ImportedBookFile {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let booksURL = URL(fileURLWithPath: booksDir, isDirectory: true).standardizedFileURL
        let sourceFilename = sourceURL.lastPathComponent
        let sourceExtension = sourceURL.pathExtension
        let sourceParent = sourceURL.deletingLastPathComponent()
        let sourceIsManagedBookFile = sourceParent.deletingLastPathComponent().path == booksURL.path

        // The folder is the book's identity on disk and inside every chapter URL,
        // so it is named after the file — minus the download-site tag some files
        // arrive with. A file already inside the managed library keeps the folder
        // it is in, whatever that folder is called.
        let baseName: String
        if sourceIsManagedBookFile {
            baseName = sourceParent.lastPathComponent
        } else {
            baseName = BookFolderNaming.cleanedFolderName(
                fromFileBaseName: (sourceFilename as NSString).deletingPathExtension
            )
        }

        // Per-book folder: Books/BookName/. Files already there came from iCloud and
        // should be used in place instead of copied into a new folder.
        let bookDir: String
        if sourceIsManagedBookFile {
            bookDir = sourceParent.path
        } else {
            bookDir = booksURL.appendingPathComponent(baseName, isDirectory: true).path
        }
        try fm.createDirectory(atPath: bookDir, withIntermediateDirectories: true)

        let destPath: String
        if sourceIsManagedBookFile {
            destPath = sourceURL.path
        } else {
            let managedFilename = sourceExtension.isEmpty ? baseName : "\(baseName).\(sourceExtension)"
            destPath = (bookDir as NSString).appendingPathComponent(managedFilename)
        }

        // Copy the full book into its folder. On re-import the source file may have
        // changed (e.g. the user fixed chapter order or added chapters), so refresh the
        // managed copy when it differs from the source. Skipping this leaves the app
        // extracting a stale copy and the user's edits never take effect.
        if sourceURL.path != destPath {
            let destExists = fm.fileExists(atPath: destPath)
            if !destExists || !filesHaveSameContents(sourceURL.path, destPath, fm: fm) {
                if destExists {
                    try fm.removeItem(atPath: destPath)
                }
                try fm.copyItem(atPath: sourceURL.path, toPath: destPath)
            }
        }

        let importedMetadata = extractBookMetadata(fromBookFile: destPath)
        let chaptersDir = (bookDir as NSString).appendingPathComponent("Chapters")

        return ImportedBookFile(
            baseName: baseName,
            bookDir: bookDir,
            destPath: destPath,
            chaptersDir: chaptersDir,
            importedTitle: importedMetadata.title,
            importedSubtitle: importedMetadata.subtitle,
            importedAuthor: importedMetadata.author,
            importedEdition: importedMetadata.edition,
            firstPagesText: importedMetadata.firstPagesText
        )
    }

    /// Cheap equality check for two files: compare size first, then full contents.
    /// Used to decide whether a re-imported book file should overwrite the managed copy.
    nonisolated private static func filesHaveSameContents(_ pathA: String, _ pathB: String, fm: FileManager) -> Bool {
        let sizeA = (try? fm.attributesOfItem(atPath: pathA)[.size] as? NSNumber)?.int64Value
        let sizeB = (try? fm.attributesOfItem(atPath: pathB)[.size] as? NSNumber)?.int64Value
        if let sizeA, let sizeB, sizeA != sizeB { return false }
        return fm.contentsEqual(atPath: pathA, andPath: pathB)
    }

    nonisolated private static func convertKindleBookToEPUB(sourcePath: String) throws -> KindleConversionResult {
        guard let converterURL = ebookConvertExecutableURL() else {
            throw SourceError.kindleConversionToolMissing
        }

        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ForeverLMKindleImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let epubURL = tempDir.appendingPathComponent("\(baseName).epub")
        let logURL = tempDir.appendingPathComponent("ebook-convert.log")
        fm.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = converterURL
        process.arguments = [sourceURL.path, epubURL.path]

        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? logHandle.close()
            try? fm.removeItem(at: tempDir)
            throw SourceError.kindleConversionFailed("Could not run Calibre's ebook-convert: \(error.localizedDescription)")
        }
        try? logHandle.close()

        let logData = (try? Data(contentsOf: logURL)) ?? Data()
        let logText = String(data: logData, encoding: .utf8) ?? ""
        let convertedFileIsUsable = fm.fileExists(atPath: epubURL.path)
            && ((try? fm.attributesOfItem(atPath: epubURL.path)[.size] as? NSNumber)?.intValue ?? 0) > 0
        guard process.terminationStatus == 0, convertedFileIsUsable else {
            try? fm.removeItem(at: tempDir)
            throw kindleConversionError(from: logText)
        }

        return KindleConversionResult(epubPath: epubURL.path, tempDir: tempDir.path)
    }

    nonisolated private static func ebookConvertExecutableURL() -> URL? {
        let fm = FileManager.default
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("ebook-convert").path }
        let candidates = [
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            "/opt/homebrew/bin/ebook-convert",
            "/usr/local/bin/ebook-convert"
        ] + pathCandidates

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func kindleConversionError(from output: String) -> SourceError {
        let lower = output.lowercased()
        if lower.contains("drm") || lower.contains("encrypted") || lower.contains("locked") {
            return .kindleConversionFailed("This Kindle file appears to be DRM-protected. ForeverLM can import DRM-free Kindle files only.")
        }

        let summary = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: "\n")
        if summary.isEmpty {
            return .kindleConversionFailed("Kindle conversion failed.")
        }
        return .kindleConversionFailed("Kindle conversion failed:\n\(summary)")
    }

    /// Import chapters from a PDF book. The book stays one file: each chapter
    /// is the run of its pages the chapter splitting model chose
    /// (`StudioArticle.bookPages`), and no chapter file is written. A book
    /// imported again while it was still split into chapter files (`chaptersDir`)
    /// loses that folder once its chapters point at the book.
    func importPDFChapters(from pdfPath: String, baseName: String, bookID: String, bookTitle: String, bookDir: String, chaptersDir: String) async throws {
        bookImportStatus = "Reading PDF…"
        await Task.yield()
        try await addTextToScannedPages(pdfPath: pdfPath, bookID: bookID, bookTitle: bookTitle)
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try Self.readPDFBookSnapshot(pdfPath: pdfPath, bookDir: bookDir)
        }.value

        guard let config = KeychainService.resolveConfig(for: .bookChapterSplitting) else {
            let message = "Book chapter splitting AI is not configured."
            errorMessage = message
            throw SourceError.bookChapterBoundaryMismatch(message)
        }

        bookImportStatus = "Asking AI to identify chapters…"
        let aiChapters = try await aiService.selectBookChapterBoundaries(
            source: AIUsageSource(id: bookID, type: "book", title: bookTitle),
            bookTitle: bookTitle,
            pageCount: snapshot.pageCount,
            outlineEntries: snapshot.outlineEntries.map { (title: $0.title, pageIndex: $0.pageIndex, depth: $0.depth) },
            tocEntries: snapshot.tocEntries.map { (title: $0.title, printedPage: $0.printedPage, text: $0.text) },
            chapterHeadingEntries: snapshot.detectedChapterEntries.map { (title: $0.title, pageIndex: $0.pageIndex) },
            pageEntries: snapshot.pageEntries.map { (pageIndex: $0.pageIndex, text: $0.text) },
            frontMatterPages: snapshot.frontMatterPages.map { (pageIndex: $0.pageIndex, text: $0.text) },
            config: config
        )
        let chapters = aiChapters.map {
            (title: $0.title, pageIndex: $0.pageIndex, endPageIndexExclusive: $0.endPageIndexExclusive)
        }
        guard !chapters.isEmpty else {
            let message = "The book chapter splitting AI did not identify any chapters."
            errorMessage = message
            throw SourceError.bookChapterBoundaryMismatch(message)
        }
        if let issue = Self.bookChapterSelectionIssue(
            chapters: chapters.map { (title: $0.title, pageIndex: $0.pageIndex) },
            pageCount: snapshot.pageCount
        ) {
            let message = "The book chapter splitting AI returned an unsafe chapter list: \(issue)"
            errorMessage = message
            throw SourceError.bookChapterBoundaryMismatch(message)
        }

        let progress = BookImportProgress(self)
        let drafts = try await Task.detached(priority: .userInitiated) {
            try Self.preparePDFChapterDrafts(
                pdfPath: pdfPath,
                bookTitle: bookTitle,
                preselectedChapters: chapters,
                progress: progress
            )
        }.value

        guard !drafts.isEmpty else {
            errorMessage = "The book chapter splitting AI did not identify chapters in this PDF."
            throw SourceError.pdfReadFailed
        }

        try await storage.archiveSourcesByParentGroup(bookID)
        for draft in drafts {
            bookImportStatus = "Saving chapter \(draft.sortIndex + 1)/\(drafts.count): \(draft.title)…"
            let url = draft.pages.map { StudioArticle.bookChapterURL(bookFilePath: draft.path, pages: $0) } ?? draft.path
            var article = StudioArticle(
                url: url,
                title: draft.title,
                sourceType: .book,
                discoveryOrigin: .manual,
                localFilePath: draft.path
            )
            article.parentGroup = bookID
            article.state = .ready
            article.courseSortIndex = draft.sortIndex
            article.bookPages = draft.pages
            if !draft.plainText.isEmpty {
                article.content = draft.plainText
                article.wordCount = draft.wordCount
            }

            try await saveImportedBookChapterDraft(article)
        }
        // Every chapter now names the book's pages: a folder of chapter files
        // an earlier import left is no longer anyone's, nor is the book's
        // place in the merge queue.
        try? await storage.dropBookFileMerge(bookID: bookID)
        try? await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: chaptersDir) {
                try FileManager.default.removeItem(atPath: chaptersDir)
            }
        }.value

        logger.info("[BookImport] Inserted \(drafts.count) chapters of \(pdfPath)")
    }

    /// A scanned book is pictures of pages: PDFKit finds no text in them, so
    /// the chapter splitter was handed nothing and a chapter's text came out
    /// empty. Pages with no text of their own are read by OCR, Scanned Page
    /// Proofreading corrects what OCR read against each page's picture, and
    /// the result is written into the library's copy of the PDF as the pages'
    /// text — before the chapter split, which reads it, and for the reader's
    /// search and highlights afterwards. A book whose pages all carry text
    /// passes through untouched.
    private func addTextToScannedPages(pdfPath: String, bookID: String, bookTitle: String) async throws {
        let progress = BookImportProgress(self)
        let pages = try await Task.detached(priority: .userInitiated) {
            try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: pdfPath) { read, total in
                progress.update("Reading scanned page \(read)/\(total)…")
            }
        }.value
        defer { pages.discardPictures() }
        guard !pages.lines.isEmpty else { return }

        guard let config = KeychainService.resolveConfig(for: .scannedPageProofreading) else {
            let message = KeychainService.backgroundAIUnavailableMessage(for: .scannedPageProofreading)
                ?? "Scanned page proofreading AI is not configured."
            errorMessage = message
            throw AIError.apiError(message)
        }
        bookImportStatus = "Proofreading scanned pages…"
        let corrected = try await ScannedPageProofreading.proofread(
            pages,
            bookTitle: bookTitle,
            source: AIUsageSource(id: bookID, type: "book", title: bookTitle),
            aiService: aiService,
            config: config
        ) { proofread, total in
            progress.update("Proofreading scanned page \(proofread)/\(total)…")
        }
        bookImportStatus = "Writing the book's text…"
        try await Task.detached(priority: .userInitiated) {
            try ScannedPDFTextLayer.writeTextLayer(corrected, intoPDFAt: URL(fileURLWithPath: pdfPath))
        }.value
    }

    nonisolated private static func readPDFBookSnapshot(pdfPath: String, bookDir: String) throws -> PDFBookSnapshot {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw SourceError.pdfReadFailed
        }
        extractPDFCover(from: doc, to: bookDir)
        let outlineEntries = extractPDFOutlineEntries(doc).map {
            PDFOutlineChapterEntry(title: $0.title, pageIndex: $0.pageIndex, depth: $0.depth)
        }
        let frontMatterPages = extractPDFFrontMatterEntries(doc).map {
            PDFPageChapterEntry(pageIndex: $0.pageIndex, text: $0.text)
        }
        let tocEntries = extractPDFTOCChapterEntries(frontMatterPages.map(\.text)).map {
            PDFTOCChapterEntry(title: $0.title, printedPage: $0.printedPage, text: $0.text)
        }
        let detectedChapterEntries = extractPDFChapterHeadingEntries(doc).map {
            PDFOutlineChapterEntry(title: $0.title, pageIndex: $0.pageIndex, depth: 0)
        }
        let pageEntries = extractPDFPageStartEntries(doc).map {
            PDFPageChapterEntry(pageIndex: $0.pageIndex, text: $0.text)
        }
        return PDFBookSnapshot(
            pageCount: doc.pageCount,
            outlineEntries: outlineEntries,
            tocEntries: tocEntries,
            detectedChapterEntries: detectedChapterEntries,
            pageEntries: pageEntries,
            frontMatterPages: frontMatterPages
        )
    }

    nonisolated private static func preparePDFChapterDrafts(
        pdfPath: String,
        bookTitle: String,
        preselectedChapters: [(title: String, pageIndex: Int, endPageIndexExclusive: Int)],
        progress: BookImportProgress
    ) throws -> [BookChapterImportDraft] {
        progress.update("Reading PDF…")
        guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw SourceError.pdfReadFailed
        }

        progress.update("Preparing AI-selected chapters…")
        var chapters = preselectedChapters

        if chapters.isEmpty {
            throw SourceError.bookChapterBoundaryMismatch("The book chapter splitting AI did not identify any chapters.")
        }

        chapters = try validatePDFChapterRanges(chapters, pageCount: doc.pageCount)

        var drafts: [BookChapterImportDraft] = []
        for (i, chapter) in chapters.enumerated() {
            progress.update("Reading chapter \(i + 1)/\(chapters.count): \(chapter.title)…")
            let startPage = chapter.pageIndex
            let endPage = chapter.endPageIndexExclusive - 1

            guard startPage <= endPage else { continue }

            let title = sanitizedPDFOutlineLabel(chapter.title)
            let chapterTitle = importedBookChapterTitle(title, bookTitle: bookTitle)

            // Extract plain text from the chapter's pages for MCP/search, falling back to OCR for scanned pages.
            let pageLabel = chapters.count == 1 ? "OCR page" : "OCR chapter \(i + 1) page"
            let plainText = PDFTextExtractor.textWithFigureReferences(
                from: doc,
                pages: startPage..<(endPage + 1)
            ) { current, total in
                progress.update("\(pageLabel) \(current)/\(total)…")
            }

            drafts.append(BookChapterImportDraft(
                path: pdfPath,
                title: chapterTitle,
                sortIndex: i,
                plainText: plainText,
                wordCount: plainText.split(separator: " ").count,
                pages: startPage..<(endPage + 1)
            ))
        }
        return drafts
    }

    /// Import chapters from an EPUB book. The code unpacks the book (keeping
    /// every intact file of a damaged one) and lists what it holds; the book
    /// chapter splitting model decides which documents make each chapter, names
    /// them, and names the chapters a damaged file has lost, which the learner
    /// is then told about.
    ///
    /// The book stays one file (`EPUBBookFiles`): it is unpacked only into a
    /// staging folder to be read, and what the import made there — the
    /// chapters that join several documents — is packed back into the book's
    /// `.epub`. A chapter is addressed `<book folder>/Chapters/<entry>`, the
    /// entry of that file, and no `Chapters` folder is left on disk; one an
    /// earlier import left goes once the chapters are saved.
    func importEPUBChapters(from epubPath: String, bookID: String, bookTitle: String, bookDir: String, chaptersDir: String) async throws {
        bookImportStatus = "Reading EPUB…"
        logger.info("[BookImport] EPUB path: \(epubPath)")

        // Unpacked to be read, never kept: a failed import leaves the book's files alone.
        let stagingDir = chaptersDir + ".incoming-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: stagingDir) }
        let staged: EPUBParser.Inventory
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                try EPUBParser.extractInventory(from: epubPath, to: stagingDir)
            }.value
        } catch {
            logger.error("[BookImport] EPUBParser.extractInventory failed: \(error.localizedDescription)")
            errorMessage = "Could not read the EPUB: \(error.localizedDescription)."
            throw error
        }

        guard let config = KeychainService.resolveConfig(for: .bookChapterSplitting) else {
            let message = "Book chapter splitting AI is not configured."
            errorMessage = message
            throw SourceError.bookChapterBoundaryMismatch(message)
        }
        bookImportStatus = "Asking AI to identify chapters…"
        let selection = try await aiService.selectEPUBChapters(
            source: AIUsageSource(id: bookID, type: "book", title: bookTitle),
            bookTitle: bookTitle,
            inventory: staged,
            config: config
        )
        guard !selection.chapters.isEmpty else {
            let message = "The book chapter splitting AI did not identify any chapters in this EPUB."
            errorMessage = message
            throw SourceError.bookChapterBoundaryMismatch(message)
        }
        logger.info("[BookImport] Chapter model chose \(selection.chapters.count) chapters; \(selection.missingChapters.count) missing")

        let progress = BookImportProgress(self)
        let staging = try await Task.detached(priority: .userInitiated) {
            try Self.prepareEPUBChapterDrafts(
                epubPath: epubPath,
                inventory: staged,
                spans: selection.chapters,
                bookTitle: bookTitle,
                bookDir: bookDir,
                progress: progress
            )
        }.value

        guard !staging.isEmpty else {
            logger.error("[BookImport] No chapters found in EPUB")
            errorMessage = "No chapters found in EPUB."
            throw SourceError.pdfReadFailed
        }

        // The staging tree, with the chapters made in it, becomes the book's one file.
        bookImportStatus = "Saving the book…"
        try await Task.detached(priority: .userInitiated) {
            let original = URL(fileURLWithPath: epubPath)
            try EPUBBookFiles.pack(
                URL(fileURLWithPath: stagingDir, isDirectory: true),
                original: EPUBParser.isDirectoryEPUB(at: epubPath) ? nil : original,
                to: original
            )
        }.value
        let drafts = staging.map { draft in
            BookChapterImportDraft(
                path: chaptersDir + String(draft.path.dropFirst(stagingDir.count)),
                title: draft.title,
                sortIndex: draft.sortIndex,
                plainText: draft.plainText,
                wordCount: draft.wordCount
            )
        }

        try await storage.archiveSourcesByParentGroup(bookID)
        for draft in drafts {
            bookImportStatus = "Saving chapter \(draft.sortIndex + 1)/\(drafts.count): \(draft.title)…"
            var article = StudioArticle(
                url: draft.path,
                title: draft.title,
                sourceType: .book,
                discoveryOrigin: .manual,
                localFilePath: draft.path
            )
            article.parentGroup = bookID
            article.state = .ready
            article.courseSortIndex = draft.sortIndex
            if !draft.plainText.isEmpty {
                article.content = draft.plainText
                article.wordCount = draft.wordCount
            }

            try await saveImportedBookChapterDraft(article)
        }
        // A folder of chapter files an earlier import left is no one's now, nor
        // the book's place in the merge queue.
        try? await storage.dropBookFileMerge(bookID: bookID)
        try? await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: chaptersDir) {
                try FileManager.default.removeItem(atPath: chaptersDir)
            }
        }.value
        StudioArticle.invalidateResolvedPathCache(forRawPaths: drafts.map(\.path))

        logger.info("[BookImport] Inserted \(drafts.count) chapter sources for \"\(bookTitle)\"")
        if let notice = Self.damagedEPUBNotice(
            bookTitle: bookTitle,
            missingChapters: selection.missingChapters,
            missingFileCount: staged.missingFiles.count
        ) {
            bookImportNotice = notice
            showBookImportNotice = true
        }
    }

    /// What the learner is told when a damaged file left chapters behind, or
    /// nil when the book came in whole.
    nonisolated static func damagedEPUBNotice(
        bookTitle: String,
        missingChapters: [String],
        missingFileCount: Int
    ) -> String? {
        let lost: String
        if !missingChapters.isEmpty {
            lost = missingChapters.count == 1
                ? "this part of the file is damaged and could not be read: \(missingChapters[0])"
                : "these \(missingChapters.count) parts of the file are damaged and could not be read: "
                    + missingChapters.joined(separator: "; ")
        } else if missingFileCount > 0 {
            lost = missingFileCount == 1
                ? "one part of the file is damaged and could not be read"
                : "\(missingFileCount) parts of the file are damaged and could not be read"
        } else {
            return nil
        }
        return "\(bookTitle) was imported, but \(lost). Drop a fresh copy of the book on Add Book to fill them in."
    }

    private func saveImportedBookChapterDraft(_ article: StudioArticle) async throws {
        var draft = article
        draft.normalizedURL = URLNormalizer.normalize(draft.url)
        if await storage.isSourceDismissed(url: draft.url) { return }
        if let existing = await storage.existingImportedChapterRecord(for: draft) {
            try await refreshExistingImportedBookChapter(
                existingID: existing.id,
                replacement: draft
            )
            return
        }
        if try await storage.insertSourceIfNew(&draft) {
            articles.append(draft)
        }
    }

    func refreshExistingImportedBookChapter(
        existingID: String,
        replacement: StudioArticle
    ) async throws {
        let persistedSources = try? await storage.loadSourcesForExport(sourceIDs: [existingID])
        let persisted = persistedSources?.first
        var updated = persisted ?? StudioArticle(
            url: replacement.url,
            title: replacement.title,
            sourceType: replacement.sourceType,
            artworkURL: replacement.artworkURL,
            discoveryOrigin: replacement.discoveryOrigin,
            parentGroup: replacement.parentGroup,
            localFilePath: replacement.localFilePath,
            publicURL: replacement.publicURL,
            author: replacement.author,
            journal: replacement.journal,
            publishedYear: replacement.publishedYear,
            id: existingID
        )
        updated.url = replacement.url
        updated.normalizedURL = replacement.normalizedURL
        updated.title = replacement.title
        updated.domain = replacement.domain
        updated.content = replacement.content
        updated.wordCount = replacement.wordCount
        updated.state = replacement.state
        updated.errorMessage = replacement.errorMessage
        updated.sourceType = replacement.sourceType
        updated.artworkURL = replacement.artworkURL
        updated.discoveryOrigin = replacement.discoveryOrigin
        updated.parentGroup = replacement.parentGroup
        updated.localFilePath = replacement.localFilePath
        updated.publicURL = replacement.publicURL
        updated.author = replacement.author
        updated.journal = replacement.journal
        updated.publishedYear = replacement.publishedYear
        updated.status = .active
        updated.archivedAt = nil
        updated.courseSortIndex = replacement.courseSortIndex
        updated.lectureGroupId = replacement.lectureGroupId
        updated.bookPages = replacement.bookPages

        try await storage.saveSource(updated)
        if let index = articles.firstIndex(where: { $0.id == updated.id }) {
            articles[index] = updated
        } else {
            articles.append(updated)
        }
    }

    nonisolated private static func prepareEPUBChapterDrafts(
        epubPath: String,
        inventory: EPUBParser.Inventory,
        spans: [EPUBParser.ChapterSpan],
        bookTitle: String,
        bookDir: String,
        progress: BookImportProgress
    ) throws -> [BookChapterImportDraft] {
        let chapters = try EPUBParser.buildStructure(from: inventory, spans: spans)
        guard !chapters.isEmpty else { return [] }

        // Save cover image into the per-book folder.
        if let coverData = EPUBParser.extractCoverImage(from: epubPath) {
            let coverPath = (bookDir as NSString).appendingPathComponent("cover.jpg")
            try? coverData.write(to: URL(fileURLWithPath: coverPath))
        }

        var drafts: [BookChapterImportDraft] = []
        for (i, chapter) in chapters.enumerated() {
            progress.update("Adding chapter \(i + 1)/\(chapters.count): \(chapter.title)…")

            // Extract plain text for MCP/search (stored in DB content field).
            let plainText: String
            if let raw = EPUBParser.readText(atPath: chapter.xhtmlPath), !raw.isEmpty {
                plainText = EPUBParser.stripHTML(raw)
            } else {
                plainText = ""
            }

            drafts.append(BookChapterImportDraft(
                path: chapter.xhtmlPath,
                title: importedBookChapterTitle(chapter.title, bookTitle: bookTitle),
                sortIndex: i,
                plainText: plainText,
                wordCount: plainText.split(separator: " ").count
            ))
        }
        return drafts
    }

    /// Why a chapter list from the splitting AI must not be imported, or nil
    /// when it may be. This is a shape check, not a second opinion on where
    /// the chapters fall: it rejects lists that cannot be a book's chapters
    /// however the AI arrived at them.
    ///
    /// Molecular Biology of the Cell (7th ed., 1532 pages, 24 chapters) came
    /// back on 2026-08-24 as 130 chapters: some 120 of them one to four pages
    /// long and titled after contents lines ("Polymerization", "Summary",
    /// "Problems"), the rest lumps of 100–370 pages whose titles ran on
    /// through the table of contents ("11) Small-Molecule Transport …
    /// Chapter 12 … Chapter 13 …"). Each of those shapes is refused here:
    ///
    /// - a long book cut into many chapters whose median length is a few
    ///   pages, or where most chapters are a page or two;
    /// - a chapter titled with a section word ("Summary", "Problems",
    ///   "References");
    /// - a title that runs on into the table of contents, which is the
    ///   candidate the lumps were built from.
    ///
    /// A single chapter is always importable, and the length rules only
    /// apply to books of at least `bookChapterLengthRuleMinimumPages` pages,
    /// so a pamphlet or a paper imported as a book keeps its short sections.
    nonisolated static func bookChapterSelectionIssue(
        chapters: [(title: String, pageIndex: Int)],
        pageCount: Int
    ) -> String? {
        guard chapters.count > 1 else { return nil }

        if pageCount >= bookChapterLengthRuleMinimumPages {
            let starts = chapters.map(\.pageIndex).sorted()
            var lengths: [Int] = []
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] : pageCount
                lengths.append(max(end - start, 0))
            }
            let median = lengths.sorted()[lengths.count / 2]

            if chapters.count > bookChapterFragmentationCountFloor, median < bookChapterFragmentationMedianPages {
                let pages = median == 1 ? "1 page" : "\(median) pages"
                return "\(chapters.count) chapters with a median length of \(pages) in a \(pageCount)-page book; those are section headings, not chapters."
            }

            let tiny = lengths.filter { $0 < bookChapterTinyPages }.count
            if tiny * 2 > lengths.count {
                return "\(tiny) of \(chapters.count) chapters are under \(bookChapterTinyPages) pages in a \(pageCount)-page book; those are section headings, not chapters."
            }
        }

        let sectionTitled = chapters.filter { isBookSectionHeadingTitle($0.title) }
        if !sectionTitled.isEmpty {
            var seen = Set<String>()
            let examples = sectionTitled
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { seen.insert($0.lowercased()).inserted }
                .prefix(3)
                .map { "\u{201C}\($0)\u{201D}" }
                .joined(separator: ", ")
            let noun = sectionTitled.count == 1 ? "chapter is" : "chapters are"
            return "\(sectionTitled.count) \(noun) titled after a section heading rather than a chapter (\(examples))."
        }

        if let run = chapters.enumerated().first(where: { entry in
            let title = entry.element.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTableOfContentsRun(title) != title
        }) {
            let title = run.element.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = title.count > 90 ? String(title.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" : title
            return "the title of chapter \(run.offset + 1) runs on into the table of contents (\u{201C}\(shown)\u{201D}), so its boundary comes from a contents line rather than a chapter heading."
        }

        return nil
    }

    /// Books shorter than this keep whatever sections the splitter found; the
    /// length rules in `bookChapterSelectionIssue` are for books long enough
    /// that a few-page "chapter" cannot be real.
    nonisolated static let bookChapterLengthRuleMinimumPages = 100
    /// More chapters than this with a median under `bookChapterFragmentationMedianPages` is a contents listing.
    nonisolated static let bookChapterFragmentationCountFloor = 8
    nonisolated static let bookChapterFragmentationMedianPages = 5
    /// A chapter under this many pages is a fragment; a list that is mostly fragments is refused.
    nonisolated static let bookChapterTinyPages = 3

    /// Section words that head a part of a chapter, never a chapter of their
    /// own: the splitter picked a contents line when one of these is a title.
    /// "Introduction", "Preface" and "Epilogue" are real chapters in many
    /// books and are deliberately absent.
    nonisolated static let bookSectionHeadingWords: Set<String> = [
        "summary", "problems", "references", "exercises", "questions", "review questions",
        "key terms", "key concepts", "further reading", "suggested reading", "bibliography",
        "glossary", "index", "contents", "table of contents", "acknowledgments", "acknowledgements",
        "learning objectives", "chapter summary", "chapter review", "end-of-chapter problems"
    ]

    nonisolated static func isBookSectionHeadingTitle(_ title: String) -> Bool {
        var normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"^\d{1,3}\s*[).:\-–—]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(chapter|section)\s+(\d{1,3}|[ivxlcdm]+)\s*[).:\-–—]?\s*"#, with: "", options: .regularExpression)
        normalized = normalized
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return bookSectionHeadingWords.contains(normalized)
    }

    func existingBookID(forCleanedTitle title: String, bookDir: String) -> String? {
        let normalizedTitle = Self.normalizedBookLookupKey(title)
        if let match = bookTitles.first(where: { Self.normalizedBookLookupKey($0.value) == normalizedTitle }) {
            return match.key
        }

        let standardizedBookDir = URL(fileURLWithPath: bookDir).standardizedFileURL.path
        return bookCoverPaths.first { entry in
            URL(fileURLWithPath: entry.value)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path == standardizedBookDir
        }?.key
    }

    nonisolated private static func normalizedBookLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Extract a cover image from the first page of a PDF and save it as cover.jpg in `bookDir`.
    nonisolated static func extractPDFCover(from doc: PDFDocument, to bookDir: String) {
        let coverPath = (bookDir as NSString).appendingPathComponent("cover.jpg")
        guard !FileManager.default.fileExists(atPath: coverPath) else { return }
        guard let page = doc.page(at: 0) else { return }
        let bounds = page.bounds(for: .mediaBox)
        // Render at 2x for decent quality covers
        let scale: CGFloat = 2.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        try? jpeg.write(to: URL(fileURLWithPath: coverPath))
    }

    struct ImportedBookMetadata: Sendable {
        let title: String?
        let subtitle: String?
        let author: String?
        let edition: String?
        let firstPagesText: String
    }

    nonisolated private static func extractBookMetadata(fromBookFile path: String) -> ImportedBookMetadata {
        if path.lowercased().hasSuffix(".epub") {
            let metadata = EPUBParser.extractMetadata(from: path)
            return ImportedBookMetadata(
                title: normalizedBookTitle(metadata.title) ?? bookTitleFromFilename(path),
                subtitle: normalizedBookSubtitle(metadata.subtitle),
                author: normalizedBookAuthor(metadata.author),
                edition: normalizedBookEdition(metadata.edition),
                firstPagesText: [metadata.title, metadata.subtitle, metadata.author, metadata.edition]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            )
        }

        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return ImportedBookMetadata(title: nil, subtitle: nil, author: nil, edition: nil, firstPagesText: "")
        }
        let firstPagesText = extractBookFrontMatterText(doc)
        let metadataTitle = extractBookTitle(from: doc) ?? bookTitleFromFilename(path)
        let metadataSubtitle = normalizedBookSubtitle(doc.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String)
        let metadataAuthor = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        return ImportedBookMetadata(
            title: metadataTitle,
            subtitle: metadataSubtitle,
            author: normalizedBookAuthor(metadataAuthor),
            edition: extractBookEditionFromFrontMatter(firstPagesText),
            firstPagesText: firstPagesText
        )
    }

    nonisolated private static func bookTitleFromFilename(_ path: String) -> String? {
        normalizedBookTitle((URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension)
    }

    nonisolated private static func extractBookFrontMatterText(_ doc: PDFDocument) -> String {
        let maxPages = min(doc.pageCount, 8)
        var parts: [String] = []
        for pageIndex in 0..<maxPages {
            if let text = doc.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    nonisolated private static func extractBookTitle(from doc: PDFDocument) -> String? {
        let metadataTitle = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return normalizedBookTitle(metadataTitle)
    }

    nonisolated static func normalizedBookTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func cleanBookTitle(_ title: String, subtitle: String?, edition: String?) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedBookSubtitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func normalizedBookEdition(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated private static func normalizedBookAuthor(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated private static func extractBookEditionFromFrontMatter(_ text: String) -> String? {
        return nil
    }

    // MARK: - Chapter Extraction Helpers

    struct PDFOutlineChapterEntry: Sendable {
        let title: String
        let pageIndex: Int
        let depth: Int
    }

    nonisolated static func sanitizedPDFOutlineLabel(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> String in
            if scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        return scalars
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func extractPDFOutlineEntries(_ doc: PDFDocument) -> [(title: String, pageIndex: Int, depth: Int)] {
        guard let outline = doc.outlineRoot, outline.numberOfChildren > 0 else { return [] }

        var entries: [(title: String, pageIndex: Int, depth: Int)] = []

        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i),
                      let rawLabel = child.label,
                      !rawLabel.isEmpty else { continue }
                let label = sanitizedPDFOutlineLabel(rawLabel)
                guard
                      !label.isEmpty else { continue }

                if let dest = child.destination, let page = dest.page,
                   let pageIndex = doc.index(for: page) as Int? {
                    entries.append((title: label, pageIndex: pageIndex, depth: depth))
                }

                // Recurse into children
                if child.numberOfChildren > 0 {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(outline, depth: 0)

        return entries
    }

    nonisolated private static func extractPDFPageStartEntries(_ doc: PDFDocument) -> [(pageIndex: Int, text: String)] {
        var entries: [(pageIndex: Int, text: String)] = []
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex),
                  let text = page.string else { continue }
            let snippet = pdfPageStartSnippet(text)
            guard !snippet.isEmpty else { continue }
            entries.append((pageIndex: pageIndex, text: snippet))
        }
        return entries
    }

    nonisolated private static func extractPDFFrontMatterEntries(_ doc: PDFDocument) -> [(pageIndex: Int, text: String)] {
        var entries: [(pageIndex: Int, text: String)] = []
        for pageIndex in 0..<min(doc.pageCount, 12) {
            guard let page = doc.page(at: pageIndex),
                  let text = page.string else { continue }
            let snippet = pdfPageSnippet(text, lineLimit: 60, characterLimit: 4_000)
            guard !snippet.isEmpty else { continue }
            entries.append((pageIndex: pageIndex, text: snippet))
        }
        return entries
    }

    nonisolated static func extractPDFTOCChapterEntries(_ pageTexts: [String]) -> [(title: String, printedPage: Int?, text: String)] {
        let tocPattern = #"^\s*(Chapter\s+(?:[0-9]{1,3}|[IVXLCDM]+)\s*[-–—:]\s*.+?)(?:\s*\.{2,}|\s{2,})\s*([0-9]+)?\s*$"#
        guard let tocRegex = try? NSRegularExpression(pattern: tocPattern, options: [.caseInsensitive]) else {
            return []
        }

        var entries: [(title: String, printedPage: Int?, text: String)] = []
        var seenKeys: Set<String> = []
        for text in pageTexts {
            let lines = text
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .components(separatedBy: .newlines)

            for rawLine in lines {
                let line = sanitizedPDFOutlineLabel(rawLine)
                guard !line.isEmpty else { continue }
                let nsRange = NSRange(line.startIndex..., in: line)
                guard let match = tocRegex.firstMatch(in: line, range: nsRange),
                      match.range.location == 0,
                      match.range.length == nsRange.length,
                      let titleRange = Range(match.range(at: 1), in: line) else { continue }

                let title = sanitizedPDFOutlineLabel(String(line[titleRange]))
                let key = title.lowercased()
                guard !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)

                let printedPage: Int?
                if match.range(at: 2).location != NSNotFound,
                   let pageRange = Range(match.range(at: 2), in: line) {
                    printedPage = Int(line[pageRange])
                } else {
                    printedPage = nil
                }
                entries.append((title: title, printedPage: printedPage, text: line))
            }
        }
        return entries
    }

    nonisolated private static func extractPDFChapterHeadingEntries(_ doc: PDFDocument) -> [(title: String, pageIndex: Int)] {
        var pageTexts: [String] = []
        for pageIndex in 0..<doc.pageCount {
            pageTexts.append(doc.page(at: pageIndex)?.string ?? "")
        }
        return detectPDFChapterHeadingEntries(pageTexts: pageTexts)
    }

    nonisolated static func detectPDFChapterHeadingEntries(pageTexts: [String]) -> [(title: String, pageIndex: Int)] {
        let headingPattern = #"^\s*Chapter\s+([0-9]{1,3}|[IVXLCDM]+)\s*[-–—:]\s*(\S.*)$"#
        guard let headingRegex = try? NSRegularExpression(pattern: headingPattern, options: [.caseInsensitive]) else {
            return []
        }

        var entries: [(title: String, pageIndex: Int)] = []
        var seenChapterKeys: Set<String> = []
        for (pageIndex, text) in pageTexts.enumerated() {
            let lines = text
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .components(separatedBy: .newlines)

            for rawLine in lines {
                let line = sanitizedPDFOutlineLabel(rawLine)
                guard !line.isEmpty,
                      line.count <= 180,
                      !line.contains("..."),
                      !line.contains("…") else { continue }

                let nsRange = NSRange(line.startIndex..., in: line)
                guard let match = headingRegex.firstMatch(in: line, range: nsRange),
                      match.range.location == 0,
                      match.range.length == nsRange.length,
                      let chapterRange = Range(match.range(at: 1), in: line) else { continue }

                let chapterKey = String(line[chapterRange]).lowercased()
                guard !seenChapterKeys.contains(chapterKey) else { continue }
                seenChapterKeys.insert(chapterKey)
                entries.append((title: line, pageIndex: pageIndex))
                break
            }
        }
        return entries
    }

    nonisolated private static func pdfPageStartSnippet(_ text: String) -> String {
        pdfPageSnippet(text, lineLimit: 12, characterLimit: 900)
    }

    nonisolated private static func pdfPageSnippet(_ text: String, lineLimit: Int, characterLimit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(lineLimit)
        let snippet = lines.joined(separator: "\n")
        return String(snippet.prefix(characterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func validatePDFChapterStartPages(
        _ chapters: [(title: String, pageIndex: Int)],
        doc: PDFDocument
    ) throws -> [(title: String, pageIndex: Int)] {
        var validated: [(title: String, pageIndex: Int)] = []
        for chapter in chapters {
            let title = sanitizedPDFOutlineLabel(chapter.title)
            guard !title.isEmpty else { continue }
            guard chapter.pageIndex >= 0, chapter.pageIndex < doc.pageCount else {
                throw SourceError.bookChapterBoundaryMismatch(
                    "Could not split “\(title)”: its detected start page is outside the PDF."
                )
            }

            if let previous = validated.last, chapter.pageIndex <= previous.pageIndex {
                throw SourceError.bookChapterBoundaryMismatch(
                    "Could not split “\(title)”: the AI returned overlapping or out-of-order chapter pages."
                )
            }

            validated.append((title: title, pageIndex: chapter.pageIndex))
        }

        return validated.count == chapters.count ? validated : chapters
    }

    nonisolated static func validatePDFChapterRanges(
        _ chapters: [(title: String, pageIndex: Int, endPageIndexExclusive: Int)],
        pageCount: Int
    ) throws -> [(title: String, pageIndex: Int, endPageIndexExclusive: Int)] {
        var validated: [(title: String, pageIndex: Int, endPageIndexExclusive: Int)] = []
        for chapter in chapters {
            let title = sanitizedPDFOutlineLabel(chapter.title)
            guard !title.isEmpty,
                  chapter.pageIndex >= 0,
                  chapter.endPageIndexExclusive > chapter.pageIndex,
                  chapter.endPageIndexExclusive <= pageCount else {
                throw SourceError.bookChapterBoundaryMismatch(
                    "Could not split “\(title)”: its selected page range is outside the PDF."
                )
            }
            if let previous = validated.last,
               chapter.pageIndex != previous.endPageIndexExclusive {
                throw SourceError.bookChapterBoundaryMismatch(
                    "Could not split “\(title)”: the AI returned a gap or overlap between chapter ranges."
                )
            }
            validated.append((title, chapter.pageIndex, chapter.endPageIndexExclusive))
        }
        return validated
    }

    #endif

    /// Import a plain text / Markdown file as a new article source.
    /// Reads the file content directly and creates a ready-to-use StudioArticle.
    func importTextFile(from sourcePath: String) async throws {
        // File check and full read stay off the main actor — dropped files can be
        // large or iCloud-evicted, and either blocks a synchronous read.
        let loaded = try await Task.detached(priority: .userInitiated) { () -> (text: String, wordCount: Int) in
            guard FileManager.default.fileExists(atPath: sourcePath) else { throw SourceError.fileNotFound }
            let text = try String(contentsOfFile: sourcePath, encoding: .utf8)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed, trimmed.split(separator: " ").count)
        }.value
        let trimmed = loaded.text
        guard !trimmed.isEmpty else { return }

        if articles.contains(where: { $0.url == sourcePath || $0.localFilePath == sourcePath }) {
            errorMessage = "This file is already in your sources."
            return
        }

        let filename = (sourcePath as NSString).lastPathComponent
        let originalTitle = (filename as NSString).deletingPathExtension
        var article = StudioArticle(
            url: sourcePath,
            title: originalTitle,
            sourceType: .article,
            discoveryOrigin: .manual,
            localFilePath: sourcePath
        )
        if let config = KeychainService.resolveConfig(for: .articleMetadata),
           let resolved = await aiService.fixArticleTitle(
               source: AIUsageSource(source: article),
               currentTitle: originalTitle,
               url: sourcePath,
               content: trimmed,
               config: config
           )?.title {
            article.title = resolved
        }
        article.domain = "Local File"
        article.state = .ready
        article.content = trimmed
        article.wordCount = loaded.wordCount

        _ = try await storage.insertSourceIfNew(&article)
        articles.insert(article, at: 0)
    }

    /// Import a plain text string dragged from another app.
    /// Creates an in-memory article with the text as content and auto-adds to context.
    func importDroppedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let droppedURL = "dropped-text-\(UUID().uuidString)"
        var article = StudioArticle(
            url: droppedURL,
            title: "Pasted Text",
            sourceType: .article
        )
        if let config = KeychainService.resolveConfig(for: .articleMetadata),
           let resolved = await aiService.fixArticleTitle(
               source: AIUsageSource(source: article),
               currentTitle: "Pasted Text",
               url: "",
               content: trimmed,
               config: config
           )?.title {
            article.title = resolved
        }
        article.domain = "Dropped Text"
        article.state = .ready
        article.content = trimmed
        article.wordCount = trimmed.split(separator: " ").count

        _ = try? await storage.insertSourceIfNew(&article)
        articles.insert(article, at: 0)
        addSourceToContext(article.id)
    }

    /// Import any dropped file URL (PDF, text, or audio) and auto-add to KB context.
    func importDroppedFile(url: URL) async {
        let ext = url.pathExtension.lowercased()

        // Audio files — no longer supported as artifacts
        if ["mp3", "m4a", "wav", "aac", "caf", "aiff"].contains(ext) {
            errorMessage = "Audio file import is no longer supported."
            return
        }

        let countBefore = articles.count
        do {
            if ext == "pdf" {
                try await importPDF(from: url.path, selectInReader: false)
            } else if Self.supportedBookFileExtensions.contains(ext), ext != "pdf" {
                try await importBook(from: url.path)
            } else if ["txt", "md", "markdown"].contains(ext) {
                try await importTextFile(from: url.path)
            }
        } catch {
            errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
        }
        // Auto-add the newly inserted article to context
        if articles.count > countBefore, let newArticle = articles.first {
            addSourceToContext(newArticle.id)
        }
    }

}
