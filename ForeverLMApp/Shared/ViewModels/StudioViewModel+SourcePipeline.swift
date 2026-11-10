import Foundation
import CryptoKit
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

    // MARK: - Lossless Display Names

    nonisolated static func importedBookChapterTitle(_ title: String, bookTitle: String) -> String {
        trimmedTableOfContentsRun(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A chapter title that runs on into the table of contents — "11)
    /// Small-Molecule Transport and Electrical Properties of Membranes Chapter
    /// 12 Intracellular Organization and Protein Sorting Chapter 13 …" — is cut
    /// back to its own heading. Seen on Molecular Biology of the Cell
    /// (2026-09-09): the splitter echoed a candidate whose text was a run of
    /// contents lines, and every citation into the chapter read all of them.
    ///
    /// A run is a title with two further heading labels after its own words, or
    /// one whose leading candidate number says the next label is the next
    /// chapter's ("11) … Chapter 12 …"). A title with a single label and no
    /// such number is left alone: "How Life Works: Chapter 6 Cells" is a
    /// title, not a run. The candidate number is dropped with the run; a title
    /// that is not a run keeps every character.
    nonisolated static func trimmedTableOfContentsRun(_ title: String) -> String {
        let labelPattern = #"\s+(?:chapter|part)\s+(?:\d{1,3}|[ivxlcdm]+)\b"#
        guard let regex = try? NSRegularExpression(pattern: labelPattern, options: [.caseInsensitive]) else { return title }
        let nsTitle = title as NSString
        let labels = regex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))
            .filter { $0.range.location > 0 }
        guard let first = labels.first else { return title }

        var isRun = labels.count >= 2
        if !isRun, let numberRange = title.range(of: #"^\d{1,3}\)\s+"#, options: .regularExpression) {
            let own = Int(title[numberRange].filter(\.isNumber))
            let next = Int(nsTitle.substring(with: first.range).filter(\.isNumber))
            if let own, let next, next == own + 1 { isRun = true }
        }
        guard isRun else { return title }

        let cut = nsTitle.substring(to: first.range.location)
            .replacingOccurrences(of: #"^\d{1,3}\)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? title : cut
    }

    /// Preserve the filename stem until a configurable metadata AI task supplies a title.
    static func chapterTitle(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract the numeric sort key from a chapter filename for natural ordering.
    /// "03 Coding Attention.pdf" → 3, "chapter_12.pdf" → 12, "Appendix A.pdf" → 1000
    static func chapterSortKey(_ filename: String) -> Int {
        let name = (filename as NSString).deletingPathExtension
        // Try leading number: "03 Foo" → 3
        if let match = name.range(of: #"^\d+"#, options: .regularExpression) {
            return Int(name[match]) ?? Int.max
        }
        // Try "chapter_NN" pattern
        if let match = name.range(of: #"(?i)chapter[_ ]*(\d+)"#, options: .regularExpression) {
            let numPart = name[match].filter(\.isNumber)
            return Int(numPart) ?? Int.max
        }
        // Non-numeric entries (Appendix, Index, etc.) sort after all numbered chapters
        return Int.max
    }

    /// Attach a local PDF to a paper article (copies to ForeverLM/Papers/ and fetches content).
    func attachPDF(to articleId: String, pdfPath: String) async throws {
        try await attachPDF(to: articleId, pdfURL: URL(fileURLWithPath: pdfPath))
    }

    /// Returns whether the PDF was attached. It is not when the paper is
    /// gone, the learner declined the title check, or the discovery attempt
    /// that found the file was superseded.
    ///
    /// A file a resolution found for itself — the AI browser agent's — comes
    /// with that resolution's `identity` and the address it was
    /// `downloadedFrom`, and is held to the paper before anything reads it
    /// (`admitsPDFAttachment`). Another paper's file throws
    /// `PaperPDFIdentityMismatchError` and stays where it is for the caller to
    /// remove. A PDF the learner picks passes neither.
    @discardableResult
    func attachPDF(
        to articleId: String,
        pdfURL: URL,
        cancelsActiveDiscovery: Bool = true,
        expectedDiscoveryAttemptID: UUID? = nil,
        identity: PaperPDFIdentityGate? = nil,
        downloadedFrom origin: String? = nil
    ) async throws -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        attachingPDFIds.insert(articleId)
        defer { attachingPDFIds.remove(articleId) }
        let article = articles[idx]
        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")

        let didAccess = pdfURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { pdfURL.stopAccessingSecurityScopedResource() }
        }

        let plan = try await Self.localPDFAttachmentPlan(article: article, pdfURL: pdfURL, papersDir: papersDir)
        if let expectedDiscoveryAttemptID,
           activePaperBrowserAttemptIDs[articleId] != expectedDiscoveryAttemptID {
            return false
        }
        guard try await Self.admitsPDFAttachment(
            at: plan.sourcePath,
            from: origin ?? pdfURL.absoluteString,
            identity: identity,
            titleCheck: {
                try await confirmPDFAttachmentIfTitleLooksMismatched(article: article, pdfPath: plan.sourcePath)
            }
        ) else {
            return false
        }
        if let expectedDiscoveryAttemptID,
           activePaperBrowserAttemptIDs[articleId] != expectedDiscoveryAttemptID {
            return false
        }
        if cancelsActiveDiscovery {
            cancelPaperPDFDiscovery(for: articleId)
        }
        do {
            try await Self.installLocalPDFAttachment(
                plan,
                replacesExisting: cancelsActiveDiscovery
            )
        } catch SourceError.pdfReadFailed {
            showToast("Could not read PDF")
            throw SourceError.pdfReadFailed
        }
        if let expectedDiscoveryAttemptID,
           activePaperBrowserAttemptIDs[articleId] != expectedDiscoveryAttemptID {
            return false
        }

        guard let currentIndex = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        convertPaperToLocalPDF(at: currentIndex, destPath: plan.destinationPath, doi: plan.doi, updateDateAdded: true)
        guard await persistSource(articles[currentIndex], context: "Save PDF attachment") else {
            throw SourceError.fetchFailed
        }
        // Papers store no content — the indexer extracts PDF text on the fly — so a
        // stored-content refresh can't cover this; ask the indexer to close the gap now.
        kickSourceEmbeddingIndexing()
        await mergeEquivalentPaperDuplicates(into: articleId)
        let metadataComplete = await enrichPaperMetadataAfterPDFAttachment(articleId: articleId, userInitiated: true)
        if metadataComplete {
            showToast("PDF attached")
        }
        return true
    }

    /// Whether the PDF at `path` may be attached. With a resolution's
    /// `identity`, the file is held to the paper first: another paper's throws
    /// (the file is kept; the caller owns it). A file the gate confirms — its
    /// opening pages print the paper's title, or its DOI with no title against
    /// it — is attached without the model's `titleCheck`. That check compares
    /// only the PDF's metadata title or file name with the paper's, which is
    /// weaker evidence than the text itself, and it costs a model call and can
    /// raise a sheet in the middle of a background batch. It still runs when
    /// the gate cannot tell (a scan, or a paper known by neither DOI nor a
    /// title), and when there is no gate at all.
    static func admitsPDFAttachment(
        at path: String,
        from origin: String,
        identity: PaperPDFIdentityGate?,
        titleCheck: () async throws -> Bool
    ) async throws -> Bool {
        if let identity,
           try await identity.admit(pdfAt: path, from: origin, keepsRejectedFile: true) == .confirmed {
            return true
        }
        return try await titleCheck()
    }

    /// Attach a local text file (.txt, .html, .md) to a paywalled article, storing its content.
    func attachTextFile(to articleId: String, filePath: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let article = articles[idx]
        let articlesDir = (knowledgeBasePath as NSString).appendingPathComponent("Articles")

        let sourceURL = URL(fileURLWithPath: filePath)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let prepared: AttachedTextFileResult
        do {
            prepared = try await Self.prepareAttachedTextFile(sourceURL: sourceURL, article: article, articlesDir: articlesDir)
        } catch SourceError.pdfReadFailed {
            showToast("Could not read file")
            return
        } catch SourceError.insufficientContent {
            showToast("Could not extract text from file")
            return
        } catch {
            showToast("Could not attach file: \(error.localizedDescription)")
            return
        }

        guard let currentIndex = articles.firstIndex(where: { $0.id == articleId }) else { return }
        articles[currentIndex].localFilePath = prepared.relativePath
        articles[currentIndex].content = prepared.text
        articles[currentIndex].wordCount = prepared.wordCount
        articles[currentIndex].state = .ready
        articles[currentIndex].errorMessage = nil
        articles[currentIndex].isPaywalled = false
        articles[currentIndex].paywallSuspicion = nil
        guard await persistSource(articles[currentIndex], context: "Attach text file", syncImmediately: true) else { return }
        queueSourceEmbeddingRefreshIfReady(articleId)
        showToast("Text file attached")
    }

    nonisolated static func decodeAttachedTextData(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .ascii)
    }

    nonisolated static func localPDFAttachmentPlan(
        article: StudioArticle,
        pdfURL: URL,
        papersDir: String
    ) async throws -> LocalPDFAttachmentPlan {
        try await Task.detached(priority: .userInitiated) {
            let pdfPath = pdfURL.path
            let fm = FileManager.default
            try fm.createDirectory(atPath: papersDir, withIntermediateDirectories: true)
            guard SourceService.canOpenPDF(at: pdfPath) else {
                throw SourceError.pdfReadFailed
            }
            var doi = paperDOI(for: article)
            #if canImport(PDFKit)
            if doi == nil {
                doi = extractDOIFromPDF(at: pdfPath)
            }
            #endif
            let filename = preferredPaperFilename(doi: doi, url: article.url)
            let destPath = (papersDir as NSString).appendingPathComponent(filename)
            return LocalPDFAttachmentPlan(sourcePath: pdfPath, destinationPath: destPath, doi: doi)
        }.value
    }

    nonisolated static func installLocalPDFAttachment(
        _ plan: LocalPDFAttachmentPlan,
        replacesExisting: Bool = false
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let sourceURL = URL(fileURLWithPath: plan.sourcePath).standardizedFileURL
            let destinationURL = URL(fileURLWithPath: plan.destinationPath).standardizedFileURL
            if sourceURL == destinationURL {
                guard SourceService.canOpenPDF(at: plan.destinationPath) else {
                    throw SourceError.pdfReadFailed
                }
                return
            }
            if fm.fileExists(atPath: plan.destinationPath), !SourceService.canOpenPDF(at: plan.destinationPath) {
                try? fm.removeItem(atPath: plan.destinationPath)
            }
            if replacesExisting {
                let stagedURL = destinationURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".\(destinationURL.lastPathComponent).incoming-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: stagedURL) }
                try fm.copyItem(at: sourceURL, to: stagedURL)
                guard SourceService.canOpenPDF(at: stagedURL.path) else {
                    throw SourceError.pdfReadFailed
                }
                if fm.fileExists(atPath: destinationURL.path) {
                    _ = try fm.replaceItemAt(
                        destinationURL,
                        withItemAt: stagedURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try fm.moveItem(at: stagedURL, to: destinationURL)
                }
            } else if !fm.fileExists(atPath: plan.destinationPath) {
                try fm.copyItem(atPath: plan.sourcePath, toPath: plan.destinationPath)
            }
            guard SourceService.canOpenPDF(at: plan.destinationPath) else {
                throw SourceError.pdfReadFailed
            }
        }.value
    }

    nonisolated static func prepareAttachedTextFile(
        sourceURL: URL,
        article: StudioArticle,
        articlesDir: String
    ) async throws -> AttachedTextFileResult {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: sourceURL)
            guard let raw = decodeAttachedTextData(data),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceError.pdfReadFailed
            }

            let ext = sourceURL.pathExtension.lowercased()
            let text = (ext == "html" || ext == "htm" || ext == "xhtml")
                ? EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                : raw.removingSoftHyphens().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw SourceError.insufficientContent
            }

            let attachedPath = try copyAttachedArticleFile(sourceURL: sourceURL, article: article, articlesDir: articlesDir)
            return AttachedTextFileResult(
                attachedPath: attachedPath,
                relativePath: StorageService.relativeSourcePath(attachedPath),
                text: text,
                wordCount: text.split(separator: " ").count
            )
        }.value
    }

    nonisolated static func copyAttachedArticleFile(
        sourceURL: URL,
        article: StudioArticle,
        articlesDir: String
    ) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: articlesDir, withIntermediateDirectories: true)

        let sourceExt = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = sourceExt.isEmpty ? "txt" : sourceExt
        let baseName = safeAttachedArticleFilenameBase(article.title)
        var destURL = URL(fileURLWithPath: articlesDir)
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)
        var suffix = 2
        while fm.fileExists(atPath: destURL.path), destURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
            destURL = URL(fileURLWithPath: articlesDir)
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }

        if destURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
            try fm.copyItem(at: sourceURL, to: destURL)
        }
        return destURL.path
    }

    nonisolated static func safeAttachedArticleFilenameBase(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "article" : String(cleaned.prefix(120))
    }

    /// Download a PDF from a user-provided URL and attach it to an article.
    func attachPDFFromURL(to articleId: String, urlString: String) async throws {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        // A paper's supplementary file is not the paper, whoever found the link.
        guard !PaperService.isSupplementaryPDFURL(urlString) else {
            throw SourceError.paperIngestionFailed(
                "That file is the paper's supplementary material, not the paper."
            )
        }
        attachingPDFIds.insert(articleId)
        defer { attachingPDFIds.remove(articleId) }

        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        await Self.ensureDirectoryExists(at: papersDir)

        let doi = Self.paperDOI(for: articles[idx], sourceURL: urlString)
        let filename = Self.preferredPaperFilename(doi: doi, url: articles[idx].url)

        let destPath = (papersDir as NSString).appendingPathComponent(filename)
        var shouldRemoveDownloadedFileOnCancel = false
        if await Self.fileExists(at: destPath), !(await Self.canOpenPDF(at: destPath)) {
            await Self.removeItem(at: destPath)
            shouldRemoveDownloadedFileOnCancel = true
        }
        if !(await Self.fileExists(at: destPath)) {
            try await sourceService.downloadPDF(from: urlString, to: destPath)
            shouldRemoveDownloadedFileOnCancel = true
        }
        guard await Self.canOpenPDF(at: destPath) else {
            throw SourceError.pdfReadFailed
        }

        if let idx = articles.firstIndex(where: { $0.id == articleId }) {
            guard try await confirmPDFAttachmentIfTitleLooksMismatched(article: articles[idx], pdfPath: destPath) else {
                if shouldRemoveDownloadedFileOnCancel {
                    await Self.removeItem(at: destPath)
                }
                return
            }
            let doi = await Self.paperDOIOffMain(for: articles[idx], attachedPDFPath: destPath)
            convertPaperToLocalPDF(at: idx, destPath: destPath, doi: doi, updateDateAdded: true)
            guard await persistSource(articles[idx], context: "Save PDF attachment") else {
                throw SourceError.fetchFailed
            }
            // Papers store no content — the indexer extracts PDF text on the fly — so a
            // stored-content refresh can't cover this; ask the indexer to close the gap now.
            kickSourceEmbeddingIndexing()
            await mergeEquivalentPaperDuplicates(into: articleId)
            let metadataComplete = await enrichPaperMetadataAfterPDFAttachment(articleId: articleId, userInitiated: true)
            if metadataComplete {
                showToast("PDF attached from URL")
            }
            return
        }
    }

    func confirmPDFAttachmentIfTitleLooksMismatched(article: StudioArticle, pdfPath: String) async throws -> Bool {
        let warning: (paperTitle: String, pdfTitle: String)?
        do {
            warning = try await pdfAttachmentTitleMismatchWarning(article: article, pdfPath: pdfPath)
        } catch {
            logger.warning("PDF attachment title verification failed for \(article.id): \(error.localizedDescription)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Attach PDF without title check?"
            alert.informativeText = "ForeverLM could not verify whether this PDF matches the selected paper: \(error.localizedDescription)"
            alert.addButton(withTitle: "Attach Anyway")
            alert.addButton(withTitle: "Cancel")
            return await presentPDFAttachmentAlert(alert)
        }

        guard let warning else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Attach PDF to this paper?"
        alert.informativeText = "This PDF looks like \"\(warning.pdfTitle)\", but the selected paper is \"\(warning.paperTitle)\". Are you sure you want to attach it anyway?"
        alert.addButton(withTitle: "Attach Anyway")
        alert.addButton(withTitle: "Cancel")
        return await presentPDFAttachmentAlert(alert)
    }

    private func presentPDFAttachmentAlert(_ alert: NSAlert) async -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            logger.error("Could not present PDF attachment confirmation because no app window is available")
            return false
        }

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        return response == .alertFirstButtonReturn
    }

    func pdfAttachmentTitleMismatchWarning(article: StudioArticle, pdfPath: String) async throws -> (paperTitle: String, pdfTitle: String)? {
        guard article.sourceType == .paper else { return nil }
        let paperTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperTitle.isEmpty else { return nil }
        guard let pdfTitle = await Self.pdfTitleCandidateForAttachmentCheck(at: pdfPath) else { return nil }
        guard let config = KeychainService.resolveConfig(for: .paperAttachmentCheck) else { return nil }
        guard try await aiService.shouldWarnForPDFAttachment(
            source: AIUsageSource(source: article),
            selectedPaperTitle: paperTitle,
            pdfTitleCandidate: pdfTitle,
            config: config
        ) else { return nil }
        return (paperTitle, pdfTitle)
    }

    nonisolated static func pdfTitleCandidateForAttachmentCheck(at path: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            #if canImport(PDFKit)
            if let metadataTitle = rawPDFMetadataTitle(from: path) {
                return metadataTitle
            }
            #endif

            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stem.isEmpty ? nil : stem
        }.value
    }

    /// Persist an already-downloaded remote PDF and convert the article to a local-PDF paper.
    /// Used by the direct PDF reader path, where the PDF bytes have already been fetched for display.
    ///
    /// `userInitiated` is false for the pipeline's own attempts, which neither
    /// toast nor date the paper as if the learner had just added it; the
    /// metadata step then runs the way the rest of a background resolution does.
    /// The pipeline also passes its `identity` gate, which the file must pass
    /// before it is attached, and the `destinationPath` its other candidates
    /// use. A PDF the learner saves from the reader is theirs to choose, so
    /// those callers pass neither.
    func attachDownloadedPDFData(
        to articleId: String,
        data: Data,
        sourceURL: URL? = nil,
        userInitiated: Bool = true,
        forceAIForMissingAuthor: Bool = false,
        identity: PaperPDFIdentityGate? = nil,
        destinationPath: String? = nil,
        replacingDerivedData: Bool = false
    ) async throws {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard articles[idx].resolvedPDFPath == nil else { return }
        if let sourceURL, PaperService.isSupplementaryPDFURL(sourceURL.absoluteString) {
            throw SourceError.paperIngestionFailed(
                "That file is the paper's supplementary material, not the paper."
            )
        }
        guard SourceService.looksLikePDFData(data), await Self.canOpenPDFData(data) else {
            throw SourceError.pdfReadFailed
        }
        cancelPaperPDFDiscovery(for: articleId)

        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        await Self.ensureDirectoryExists(at: papersDir)

        let articleURL = articles[idx].url
        let sourceURLString = sourceURL?.absoluteString ?? articleURL
        let doi = Self.paperDOI(for: articles[idx], sourceURL: sourceURLString)
        let destPath = destinationPath ?? (papersDir as NSString).appendingPathComponent(
            Self.preferredPaperFilename(doi: doi, url: articleURL)
        )
        let filename = (destPath as NSString).lastPathComponent

        // `installDownloadedPDFData` keeps a readable file already at the path,
        // which this download did not write and so may not remove.
        let fileWasThere = await Self.fileExists(at: destPath)
        try await Self.installDownloadedPDFData(data, at: destPath)
        try await identity?.admit(pdfAt: destPath, from: sourceURLString, keepsRejectedFile: fileWasThere)

        if let idx = articles.firstIndex(where: { $0.id == articleId }) {
            let savedDOI = await Self.paperDOIOffMain(
                for: articles[idx],
                attachedPDFPath: destPath,
                sourceURL: sourceURLString
            )
            convertPaperToLocalPDF(at: idx, destPath: destPath, doi: savedDOI, updateDateAdded: userInitiated)
            if replacingDerivedData {
                try await storage.saveSourceReplacingDerivedData(articles[idx])
            } else {
                try await storage.saveSource(articles[idx])
            }
            logger.info("Saved remote PDF to local paper store: \(filename)")
            let metadataComplete = await enrichPaperMetadataAfterPDFAttachment(
                articleId: articleId,
                userInitiated: userInitiated,
                forceAIForMissingAuthor: forceAIForMissingAuthor
            )
            if userInitiated, metadataComplete {
                showToast("PDF saved")
            }
        }
    }

    nonisolated static func canOpenPDFData(_ data: Data) async -> Bool {
        let task = Task.detached(priority: .userInitiated) {
            guard SourceService.looksLikePDFData(data),
                  let document = PDFDocument(data: data) else { return false }
            return document.pageCount > 0
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func canOpenPDF(at path: String) async -> Bool {
        let task = Task.detached(priority: .userInitiated) {
            SourceService.canOpenPDF(at: path)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Off-main filesystem helpers so paper-download paths never block the main
    /// actor on synchronous `FileManager` I/O.
    nonisolated static func ensureDirectoryExists(at path: String) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }.value
    }

    nonisolated static func fileExists(at path: String) async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
    }

    nonisolated static func removeItem(at path: String) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(atPath: path)
        }.value
    }

    /// A path beside `path` that no file holds yet, numbered the way
    /// `paperDestinationPath` numbers a dropped PDF ("name 2.pdf", "name 3.pdf"…),
    /// for a download that must neither replace nor remove the file there.
    nonisolated static func unusedPaperPath(besides path: String) async -> String {
        await Task.detached(priority: .utility) {
            let directory = (path as NSString).deletingLastPathComponent
            let baseName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let ext = (path as NSString).pathExtension
            var suffix = 2
            while true {
                let name = ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)"
                let candidate = (directory as NSString).appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: candidate) { return candidate }
                suffix += 1
            }
        }.value
    }

    nonisolated static func installDownloadedPDFData(_ data: Data, at path: String) async throws {
        let task = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let directory = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: path), !SourceService.canOpenPDF(at: path) {
                try? fileManager.removeItem(atPath: path)
            }
            if !fileManager.fileExists(atPath: path) {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            guard SourceService.canOpenPDF(at: path) else {
                throw SourceError.pdfReadFailed
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Download a remote PDF that is ordinary source material rather than an
    /// academic paper. Course handouts, assignments, syllabi, and slides keep
    /// their `.course` identity and therefore never enter Paper Metadata AI.
    ///
    /// The file lands before the article is published back to SwiftUI, and its
    /// resolved-path cache is warmed off-main. The visible row can immediately
    /// render `BookCoverThumbnail` from page one without requiring a click.
    func downloadDocumentPDF(for articleId: String) async -> Bool {
        guard let initial = articles.first(where: { $0.id == articleId }),
              initial.sourceType != .paper else { return false }

        let sourceURL = initial.url
        let destinationPath = await documentPDFDestination(for: initial)
        var downloadedNewFile = false

        do {
            if await Self.fileExists(at: destinationPath) {
                if !(await Self.canOpenPDF(at: destinationPath)) {
                    await Self.removeItem(at: destinationPath)
                }
            }
            if !(await Self.fileExists(at: destinationPath)) {
                try await sourceService.downloadPDF(from: sourceURL, to: destinationPath)
                downloadedNewFile = true
            }
            guard await Self.canOpenPDF(at: destinationPath) else {
                if downloadedNewFile {
                    await Self.removeItem(at: destinationPath)
                }
                throw SourceError.pdfReadFailed
            }

            guard await recordDocumentPDF(
                at: destinationPath,
                for: articleId,
                context: "Save downloaded document PDF"
            ) else {
                if downloadedNewFile,
                   articles.first(where: { $0.id == articleId })?.sourceType == .paper {
                    await Self.removeItem(at: destinationPath)
                }
                return false
            }
            logger.info("Downloaded document PDF without paper ingestion: \(sourceURL) -> \(destinationPath)")
            return true
        } catch {
            logger.warning("Document PDF download failed for \(sourceURL): \(error.localizedDescription)")
            return false
        }
    }

    /// Attach a PDF the learner has — picked in Finder, or downloaded in the
    /// reader — to an article the app could not read (a publisher check, a
    /// paywall). The article stays an article: the file is kept the way
    /// `downloadDocumentPDF` keeps one, its text becomes the article's, and the
    /// reader shows the PDF. Attaching a paper's PDF is `attachPDF`.
    func attachDocumentPDF(to articleId: String, pdfURL: URL) async throws {
        guard let article = articles.first(where: { $0.id == articleId }) else { throw SourceError.fetchFailed }
        guard article.sourceType != .paper else {
            try await attachPDF(to: articleId, pdfURL: pdfURL)
            return
        }
        let didAccess = pdfURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { pdfURL.stopAccessingSecurityScopedResource() }
        }
        guard await Self.canOpenPDF(at: pdfURL.path) else { throw SourceError.pdfReadFailed }
        let destinationPath = await documentPDFDestination(for: article)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destination = URL(fileURLWithPath: destinationPath)
            if fm.fileExists(atPath: destinationPath) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: pdfURL, to: destination)
        }.value
        guard await recordDocumentPDF(at: destinationPath, for: articleId, context: "Attach PDF to article") else {
            throw SourceError.fetchFailed
        }
        queueSourceEmbeddingRefreshIfReady(articleId)
    }

    /// Join a journal's supplementary PDF to a paper that has its own PDF: its
    /// pages follow the article's (`PaperSupplementPDF`), and the paper points
    /// at the joined file. Nothing is billed: the paper keeps its metadata.
    @discardableResult
    func attachSupplementaryPDF(to articleId: String, pdfURL: URL) async throws -> PaperSupplementPDF.Outcome {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper,
              let stored = article.localFilePath, !stored.isEmpty else {
            throw SourceError.pdfReadFailed
        }
        attachingPDFIds.insert(articleId)
        defer { attachingPDFIds.remove(articleId) }
        let didAccess = pdfURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { pdfURL.stopAccessingSecurityScopedResource() }
        }
        let paperPath = StorageService.absoluteSourcePath(stored)
        let rereadsText = article.content != nil
        let (outcome, text) = try await Task.detached(priority: .userInitiated) { () throws -> (PaperSupplementPDF.Outcome, String?) in
            let outcome = try PaperSupplementPDF.append(supplementAt: pdfURL.path, toPaperAt: paperPath)
            // A paper that keeps its text keeps the supplement's too, so a
            // chat reading it sees the supplementary captions; one that keeps
            // none is read from the PDF when needed.
            let text = rereadsText ? try? SourceService.shared.extractTextFromPDF(at: outcome.path) : nil
            return (outcome, text)
        }.value
        guard let index = articles.firstIndex(where: { $0.id == articleId }) else { throw SourceError.fetchFailed }
        StudioArticle.recordExistingLocalPath(outcome.path)
        articles[index].localFilePath = StorageService.relativeSourcePath(outcome.path)
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            articles[index].content = text
            articles[index].wordCount = text.split(separator: " ").count
        }
        guard await persistSource(articles[index], context: "Attach supplementary PDF", syncImmediately: true) else {
            throw SourceError.fetchFailed
        }
        if let usedElsewhere = try? await storage.otherSourceUsesLocalFile(stored, excludingSourceID: articleId) {
            PaperSupplementPDF.removeReplacedFile(storedPath: stored, usedElsewhere: usedElsewhere)
        }
        kickSourceEmbeddingIndexing()
        return outcome
    }

    /// Where a non-paper source keeps its PDF: one file per source, named for
    /// its id, under Articles (Courses for a course's handout).
    private func documentPDFDestination(for article: StudioArticle) async -> String {
        let directoryName = article.sourceType == .course ? "Courses" : "Articles"
        let destinationDirectory = (knowledgeBasePath as NSString)
            .appendingPathComponent(directoryName)
        await Self.ensureDirectoryExists(at: destinationDirectory)
        let digest = SHA256.hash(data: Data(article.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return (destinationDirectory as NSString).appendingPathComponent("\(digest).pdf")
    }

    /// Make the PDF at `destinationPath` the source's document: its file, its
    /// text, and a ready state. False when the source is gone or has become a
    /// paper (whose PDF `attachPDF` owns), or the save failed.
    private func recordDocumentPDF(at destinationPath: String, for articleId: String, context: String) async -> Bool {
        guard var updated = articles.first(where: { $0.id == articleId }),
              updated.sourceType != .paper else { return false }
        updated.localFilePath = destinationPath
        updated.state = .ready
        updated.errorMessage = nil
        updated.isPaywalled = false
        updated.paywallSuspicion = nil

        #if canImport(PDFKit)
        let extracted = await Task.detached(priority: .utility) { () -> (text: String, wordCount: Int)? in
            guard let document = PDFDocument(url: URL(fileURLWithPath: destinationPath)) else {
                return nil
            }
            let text = PDFTextExtractor.textWithFigureReferences(
                from: document,
                pages: 0..<document.pageCount
            )
            guard !text.isEmpty else { return nil }
            return (text, text.split(separator: " ").count)
        }.value
        if let extracted {
            updated.content = extracted.text
            updated.wordCount = extracted.wordCount
        }
        #endif

        _ = await Task.detached(priority: .utility) {
            StudioArticle.warmResolvedLocalPathCache(forRawPaths: [destinationPath])
        }.value
        guard await persistSource(updated, context: context) else {
            return false
        }
        if let currentIndex = articles.firstIndex(where: { $0.id == articleId }) {
            articles[currentIndex] = updated
        }
        return true
    }

    func downloadRemoteBookPDF(for articleId: String) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .book else { return false }

        var article = articles[idx]
        Self.normalizeWholeBookSource(&article)

        let sourceURL = article.remotePDFURL?.absoluteString ?? article.url
        let fm = FileManager.default
        let booksDir = (knowledgeBasePath as NSString).appendingPathComponent("Books")
        let bookDirName = Self.safeAttachedArticleFilenameBase(article.title)
        let bookDir = (booksDir as NSString).appendingPathComponent(bookDirName)
        try? fm.createDirectory(atPath: bookDir, withIntermediateDirectories: true)

        let sourceFilename = URL(string: sourceURL)?.lastPathComponent.removingPercentEncoding
        let filenameBase = sourceFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (filenameBase?.isEmpty == false ? filenameBase! : "\(bookDirName).pdf")
        let pdfFilename = filename.lowercased().hasSuffix(".pdf") ? filename : "\(filename).pdf"
        let destPath = (bookDir as NSString).appendingPathComponent(pdfFilename)

        do {
            if !fm.fileExists(atPath: destPath) {
                try await sourceService.downloadPDF(from: sourceURL, to: destPath)
            }
            guard await Self.canOpenPDF(at: destPath) else {
                try? fm.removeItem(atPath: destPath)
                throw SourceError.pdfReadFailed
            }

            article.localFilePath = destPath
            article.state = .ready
            article.errorMessage = nil
            article.domain = URL(string: article.url)?.host ?? "Local PDF"

            #if canImport(PDFKit)
            // Whole-book PDF parsing and text extraction stay off the main actor.
            let extracted = await Task.detached(priority: .userInitiated) { () -> (text: String, wordCount: Int)? in
                guard let document = PDFDocument(url: URL(fileURLWithPath: destPath)) else { return nil }
                let text = PDFTextExtractor.textWithFigureReferences(
                    from: document,
                    pages: 0..<document.pageCount
                )
                guard !text.isEmpty else { return nil }
                return (text, text.split(separator: " ").count)
            }.value
            if let extracted {
                article.content = extracted.text
                article.wordCount = extracted.wordCount
            }
            #endif

            guard await persistSource(article, context: "Save downloaded book PDF") else { return false }
            await persistWholeBookMetadataIfNeeded(for: article)
            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2] = article
            }
            logger.info("Downloaded remote book PDF: \(sourceURL) -> \(destPath)")
            return true
        } catch {
            logger.warning("Remote book PDF download failed for \(sourceURL): \(error.localizedDescription)")
            try? fm.removeItem(atPath: destPath)
            return false
        }
    }

    /// Resolve DOI values that are already in memory. Opening a PDF is deliberately
    /// excluded so this synchronous helper is always safe for main-actor callers.
    nonisolated static func paperDOI(for article: StudioArticle, sourceURL: String? = nil) -> String? {
        if let doi = article.doi, !doi.isEmpty { return doi }
        if let doi = PaperService.extractDOI(from: article.url) { return doi }
        if let sourceURL, let doi = PaperService.extractDOI(from: sourceURL) { return doi }
        return nil
    }

    nonisolated static func paperDOIOffMain(
        for article: StudioArticle,
        attachedPDFPath: String? = nil,
        sourceURL: String? = nil
    ) async -> String? {
        if let doi = paperDOI(for: article, sourceURL: sourceURL) { return doi }
        #if canImport(PDFKit)
        guard let attachedPDFPath else { return nil }
        return await Task.detached(priority: .utility) {
            extractDOIFromPDF(at: attachedPDFPath)
        }.value
        #else
        return nil
        #endif
    }

    /// The metadata step every PDF attachment ends with. By the time it runs the
    /// attachment is saved and the row's attestation is cleared, so this step is
    /// the only thing that can finish the paper, and it runs in a task of its own
    /// that the caller's cancellation does not reach. The reader attaches the PDF
    /// it downloaded from inside its view's `.task`, and the attachment itself
    /// swaps that remote-PDF view for the local one, cancelling the task: the
    /// extraction then returned at its first cancellation check and left the
    /// paper under "Metadata incomplete" with nothing working on it until a
    /// later refresh's sweep (2026-10-10, a Nature Communications paper the
    /// reader had just found).
    func enrichPaperMetadataAfterPDFAttachment(
        articleId: String,
        userInitiated: Bool,
        forceAIForMissingAuthor: Bool = false
    ) async -> Bool {
        await Task {
            await runPaperMetadataEnrichmentAfterPDFAttachment(
                articleId: articleId,
                userInitiated: userInitiated,
                forceAIForMissingAuthor: forceAIForMissingAuthor
            )
        }.value
    }

    private func runPaperMetadataEnrichmentAfterPDFAttachment(
        articleId: String,
        userInitiated: Bool,
        forceAIForMissingAuthor: Bool
    ) async -> Bool {
        if paperMetadataEnrichmentInFlight.contains(articleId) {
            while paperMetadataEnrichmentInFlight.contains(articleId) {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              shouldEnrichPaperMetadataAfterPDFAttachment(articles[idx]) else { return false }

        // Nothing can pay for the extraction. The source itself is already saved
        // and readable; firing the calls anyway would spend the wait, mark the
        // row a failed ingestion, and end at the same prompt. Leave it pending so
        // a later pass picks it up the moment credits arrive.
        guard !AICreditEntitlement.isOutOfCredits else {
            NotificationCenter.default.post(name: .managedAICreditsEmpty, object: nil)
            return false
        }

        paperMetadataEnrichmentInFlight.insert(articleId)
        let previousProcessingStep = paperProcessingSteps[articleId]
        defer {
            paperMetadataEnrichmentInFlight.remove(articleId)
            if let previousProcessingStep {
                paperProcessingSteps[articleId] = previousProcessingStep
            } else {
                paperProcessingSteps.removeValue(forKey: articleId)
            }
            // See `dropPaperProcessingStepIfIdle`: a caption restored here is
            // only valid while some other pass still owns the row.
            dropPaperProcessingStepIfIdle(articleId)
        }

        let previousStep = paperDownloadStep
        // A non-nil prefix hands `paperDownloadStep` to this flow and to the
        // phases inside `extractPaperMetadataWithAI`; nil leaves it alone.
        let progressPrefix: String? = (userInitiated || forceAIForMissingAuthor) ? "" : nil
        // The PDF's first page is the source of truth, and the Paper Metadata
        // model reads it for the title, authors, venue, year and DOI in one call.
        // The publisher landing page and the Crossref/OpenAlex cascade used to run
        // first, one request after another with 15-second timeouts each; a slow
        // nature.com or a rate-limited catalog held the row under "Looking up
        // paper metadata…" for over a minute before the model was even asked.
        // Nothing waits on the network now. `extractPaperMetadataWithAI` publishes
        // its own "Extracting paper metadata…" caption once the page text is read.
        let metadataComplete = await extractPaperMetadataWithAI(
            id: articleId,
            showToasts: userInitiated,
            progressPrefix: progressPrefix
        )
        if progressPrefix != nil {
            paperDownloadStep = previousStep
        }
        if metadataComplete {
            Task { [weak self] in
                await self?.resolvePublishedVersionIdentityAfterIngestion(for: articleId)
            }
        }
        return metadataComplete
    }

    /// Report the stage that actually stopped ingestion. PDF attachment is
    /// already durable by this point, so callers must not flatten a cleanup or
    /// persistence failure into a claim that metadata was empty.
    func stalledPaperIngestionError(for articleId: String) -> SourceError {
        guard let article = articles.first(where: { $0.id == articleId }) else {
            return AICreditEntitlement.isOutOfCredits
                ? .aiCreditsRequired
                : .paperIngestionFailed("Paper ingestion did not finish.")
        }
        if let message = article.errorMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return .paperIngestionFailed(message)
        }
        if AICreditEntitlement.isOutOfCredits { return .aiCreditsRequired }
        if !article.hasPaperIngestionAttestation {
            return .paperMetadataExtractionFailed
        }
        if !article.hasCompletedPaperContentCleanup {
            return .paperIngestionFailed("Paper content cleanup did not finish.")
        }
        return .paperIngestionFailed("Paper ingestion did not finish.")
    }

    func shouldEnrichPaperMetadataAfterPDFAttachment(_ article: StudioArticle) -> Bool {
        article.sourceType == .paper
        && article.resolvedPDFPath != nil
    }

    /// What a paper's downloaded PDFs are held to (`PaperPDFIdentity`): its
    /// DOI, and its title once that is a real one rather than the domain, URL
    /// or bot-check chrome a row wears before its title is resolved.
    nonisolated static func paperPDFIdentityRequest(for article: StudioArticle) -> PaperPDFIdentity.Request {
        PaperPDFIdentity.Request(
            doi: paperDOI(for: article),
            titles: titleNeedsResolution(article.title, domain: article.domain, url: article.url) ? [] : [article.title]
        )
    }

    /// The paper one PDF resolution holds every downloaded file to, and the
    /// files it has turned away. An index can list another paper's copy under
    /// this paper's DOI (OpenAlex did on 2026-09-28, for a DOI cut short at
    /// its parenthesis), and once the Paper Metadata model has read that copy
    /// it rewrites the title, DOI, authors and year to match, so a wrong file
    /// has to be stopped before it is attached.
    ///
    /// One gate spans every candidate a resolution tries — the publisher's
    /// link, the reader's session, each open-access copy, the AI browser
    /// agent's download — so the DOI's
    /// registered title is asked for at most once, and the message left on
    /// the paper can name every file that was not it. It is built from the row
    /// before `adoptOpenAccessAlternativeIfAvailable` swaps a candidate's
    /// address onto it: that address says nothing about which paper this is.
    @MainActor
    final class PaperPDFIdentityGate {
        let sourceID: String
        /// The paper's own address, for the diagnostics line.
        let requestedURL: String
        private(set) var request: PaperPDFIdentity.Request
        private(set) var rejections: [PaperPDFIdentityMismatchError] = []
        private let registeredTitle: (String) async -> String?
        /// Writes a turned-away file to the ingestion log. A test stands in for
        /// it, so its fixtures stay out of the real log.
        private let recordMismatch: @MainActor (_ gate: PaperPDFIdentityGate, _ rejection: PaperPDFIdentityMismatchError) -> Void

        init(
            article: StudioArticle,
            registeredTitle: @escaping (String) async -> String? = { await PaperService.registeredTitleIfKnown(forDOI: $0) },
            recordMismatch: @escaping @MainActor (_ gate: PaperPDFIdentityGate, _ rejection: PaperPDFIdentityMismatchError) -> Void = { gate, rejection in
                PaperIngestionDiagnostics.recordPDFIdentityMismatch(
                    sourceID: gate.sourceID,
                    requestedURL: gate.requestedURL,
                    requestedDOI: gate.request.doi,
                    pdfURL: rejection.pdfURL,
                    reason: rejection.reason
                )
            }
        ) {
            sourceID = article.id
            requestedURL = article.url
            request = StudioViewModel.paperPDFIdentityRequest(for: article)
            self.registeredTitle = registeredTitle
            self.recordMismatch = recordMismatch
        }

        /// Hold the PDF at `path`, which came from `pdfURL`, to the paper.
        /// Another paper's file is logged as `PDF_IDENTITY_MISMATCH` and thrown
        /// as a `PaperPDFIdentityMismatchError`, so the caller treats it as a
        /// candidate that failed and goes on to its next one. The file is
        /// removed first, unless `keepsRejectedFile`: one that was already on
        /// disk may be another row's PDF, and a caller may own the file.
        /// Otherwise returns `.confirmed` or `.unverifiable`.
        @discardableResult
        func admit(pdfAt path: String, from pdfURL: String, keepsRejectedFile: Bool = false) async throws -> PaperPDFIdentity.Verdict {
            var request = self.request
            let verdict = await PaperPDFIdentity.verdict(
                forPDFAt: URL(fileURLWithPath: path),
                request: &request,
                registeredTitle: registeredTitle
            )
            self.request = request
            guard case .mismatch(let reason) = verdict else { return verdict }
            if !keepsRejectedFile {
                await StudioViewModel.removeItem(at: path)
            }
            let rejection = PaperPDFIdentityMismatchError(pdfURL: pdfURL, reason: reason)
            rejections.append(rejection)
            recordMismatch(self, rejection)
            throw rejection
        }
    }

    /// A batch summary's word on the PDFs it turned away as other papers:
    /// one is named, more are counted. The ingestion log names every one.
    nonisolated static func turnedAwayPDFsSummary(_ rejections: [PaperPDFIdentityMismatchError]) -> String? {
        switch rejections.count {
        case 0: return nil
        case 1: return "turned away the PDF found at \(rejections[0].origin), a different paper"
        default: return "turned away \(rejections.count) PDFs that were other papers"
        }
    }

    /// Result of a paper PDF download attempt.
    struct PaperDownloadResult {
        let success: Bool
        let lastError: Error?
        let metadataComplete: Bool?
        /// Step-by-step log of the download flow for debugging.
        var debugLog: [String] = []

        init(
            success: Bool,
            lastError: Error?,
            metadataComplete: Bool? = nil,
            debugLog: [String] = []
        ) {
            // This result describes PDF acquisition. Mandatory ingestion status
            // is carried independently so callers can report the metadata error
            // without treating an already-downloaded PDF as a failed download and
            // attempting to acquire or replace it again.
            self.success = success
            self.lastError = lastError
            self.metadataComplete = metadataComplete
            self.debugLog = debugLog
        }
    }

    enum PaperAIBrowserAttemptResult {
        case downloaded
        case paywalled
        /// The agent thinks the page is paywalled but had no explicit evidence
        /// to mark it; the reason is recorded on the paper, whose attention
        /// row now offers Mark as Paywalled.
        case suspectedPaywall(String)
        /// The agent found a news story or commentary, not a paper; the
        /// source has already been moved to Articles.
        case notAPaper(String)
        case cancelled
        case failed(Error)
    }

    /// Manual attachment owns the paper from this point forward. Cancel the
    /// actual browser task/service, clear queued discovery, and invalidate the
    /// attempt id so a late WebKit or model result cannot attach a second PDF.
    func cancelPaperPDFDiscovery(for articleId: String) {
        activePaperBrowserTasks.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserServices.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserAttemptIDs.removeValue(forKey: articleId)
        resolvingPaperPDFIds.remove(articleId)
        pendingPaperProcessingIds.remove(articleId)
        queuedPaperPDFResolutionIds.remove(articleId)
        autoFetchPaperQueue.removeAll { $0 == articleId }
        paperProcessingSteps.removeValue(forKey: articleId)
        if activePaperBrowserAttemptIDs.isEmpty {
            paperDownloadStep = ""
        }
    }

    /// Convert a source to a local-PDF paper after a PDF has been attached.
    /// Keeps the original URL as the stable source identity and stores the
    /// downloaded PDF in `localFilePath`, so future discovery can still dedup
    /// against the original scholarly URL. Callers verify `destPath` before
    /// entering this method.
    func convertPaperToLocalPDF(at idx: Int, destPath: String, doi: String?, updateDateAdded: Bool = false) {
        StudioArticle.recordExistingLocalPath(destPath)
        var updated = articles[idx]
        let oldURL = updated.url
        updated.localFilePath = destPath
        updated.sourceType = .paper
        updated.domain = "Local PDF"
        updated.prepareForPaperMetadataExtraction()
        updated.isPaywalled = false
        updated.paywallSuspicion = nil
        if updateDateAdded {
            updated.dateAdded = Date()
        }
        if let doi, !doi.isEmpty, updated.doi == nil {
            updated.doi = doi
        }
        _ = Self.finalizeRequiredPaperMetadata(for: &updated)
        articles[idx] = updated
        logger.info("Attached local PDF to paper: \(oldURL) → \(destPath)")
    }

    /// Fold `articleId` together with any paper that now shares its identity,
    /// keeping whichever side is the better copy rather than assuming the caller's
    /// row should survive. Attaching a PDF names its own winner; learning that a
    /// saved preprint was published does not — the journal record already in the
    /// library may be the one holding the PDF and the peer-reviewed metadata.
    @discardableResult
    func mergePaperIntoBestEquivalent(_ articleId: String) async -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }
        let equivalents = articles.filter { candidate in
            candidate.id != articleId
                && candidate.sourceType == .paper
                && candidate.teamID == article.teamID
                && Self.paperDedupKeysMatch(article, candidate)
        }
        guard !equivalents.isEmpty else { return false }

        let canonical = (equivalents + [article])
            .max { Self.paperStorageScore($0) < Self.paperStorageScore($1) } ?? article
        return await mergeEquivalentPaperDuplicates(into: canonical.id)
    }

    /// When a PDF is attached to one paper row, fold equivalent URL-discovered
    /// paper rows into that user-targeted row. This prevents publisher URL
    /// variants like ScienceDirect `/abs/pii/...` from reappearing as "PDF not
    /// available" after the PDF was attached to the sibling record.
    @discardableResult
    func mergeEquivalentPaperDuplicates(
        into canonicalId: String,
        knownDuplicateIDs: Set<String>? = nil
    ) async -> Bool {
        guard let canonicalIdx = articles.firstIndex(where: { $0.id == canonicalId }),
              articles[canonicalIdx].sourceType == .paper else { return false }

        // A team library lists the learner's own sources beside the team's
        // (docs/teams-design.md, decision 19). A merge archives the duplicate,
        // and archiving a team row takes it from every member, so a duplicate
        // is only ever one from the canonical's own library.
        let canonicalPaper = articles[canonicalIdx]
        let canonicalTeamID = canonicalPaper.teamID
        let duplicates = articles.filter { candidate in
            guard candidate.id != canonicalId,
                  candidate.sourceType == .paper,
                  candidate.teamID == canonicalTeamID else { return false }
            if let knownDuplicateIDs {
                return knownDuplicateIDs.contains(candidate.id)
            }
            return Self.paperDedupKeysMatch(canonicalPaper, candidate)
        }
        guard !duplicates.isEmpty else { return false }

        var canonical = articles[canonicalIdx]
        var changedCanonical = false
        for duplicate in duplicates {
            if canonical.localFilePath == nil, let duplicatePath = duplicate.localFilePath {
                canonical.localFilePath = duplicatePath
                changedCanonical = true
            }
            if canonical.wordCount == nil, let wordCount = duplicate.wordCount {
                canonical.wordCount = wordCount
                changedCanonical = true
            }
            if canonical.artworkURL == nil, let artworkURL = duplicate.artworkURL {
                canonical.artworkURL = artworkURL
                changedCanonical = true
            }
            if canonical.isPaywalled && !duplicate.isPaywalled {
                canonical.isPaywalled = false
                changedCanonical = true
            }
            if canonical.content == nil, let content = duplicate.content {
                canonical.content = content
                changedCanonical = true
            }
            if Self.mergePaperMetadata(from: duplicate, into: &canonical) {
                changedCanonical = true
            }
        }

        if changedCanonical {
            guard await persistSource(canonical, context: "Save merged paper duplicate") else {
                return false
            }
            if let idx = articles.firstIndex(where: { $0.id == canonicalId }) {
                articles[idx] = canonical
            }
        }

        let duplicateIds = Set(duplicates.map(\.id))
        var archivedDuplicateIds = Set<String>()
        for duplicateId in duplicateIds {
            do {
                try await storage.archivePaperIdentityDuplicate(
                    duplicateId,
                    replacingWith: canonicalId
                )
                archivedDuplicateIds.insert(duplicateId)
            } catch {
                logger.error("Failed to archive duplicate paper \(duplicateId): \(error.localizedDescription)")
            }
        }
        guard !archivedDuplicateIds.isEmpty else { return false }
        articles.removeAll { archivedDuplicateIds.contains($0.id) }
        if let selectedArticleId, archivedDuplicateIds.contains(selectedArticleId) {
            self.selectedArticleId = canonicalId
        }
        logger.info("Merged \(archivedDuplicateIds.count) equivalent paper duplicate(s) into \(canonicalId)")
        return true
    }

    /// Extract a `.pdf` filename from a web URL, URL-decoded. Returns nil for
    /// non-http(s) URLs or paths that don't end in `.pdf`. Used to detect when
    /// an imported PDF matches an existing URL-based source (e.g. a thesis URL
    /// like `https://…/Final_Report%20…pdf?sequence=1`).
    static func pdfFilenameFromWebURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let lastComponent = url.lastPathComponent
        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        guard decoded.lowercased().hasSuffix(".pdf") else { return nil }
        return decoded
    }

    /// Attempt to download a paper PDF from a known academic URL.
    /// Converts abstract URLs to PDF URLs for supported providers (arXiv, bioRxiv, etc.),
    /// downloads the PDF to ForeverLM/Papers/, and updates the article state.
    ///
    /// Every file is held to `identity` before it is attached. A caller trying
    /// open-access copies passes the gate it built from the paper before the
    /// row took a candidate's address; without one, the row as it is now is
    /// the paper.
    ///
    /// With `replacingDerivedData`, the save that attaches an accepted PDF
    /// also clears the paper's old text and everything derived from it, in one
    /// transaction (`persistSource(replacingDerivedData:)`). Nothing is
    /// cleared for a file that is never accepted.
    func downloadPaperPDF(
        for articleId: String,
        userInitiated: Bool = true,
        forceMetadataExtractionForMissingAuthor: Bool = false,
        identity: PaperPDFIdentityGate? = nil,
        replacingDerivedData: Bool = false
    ) async -> PaperDownloadResult {
        var log: [String] = []
        func setDownloadStep(_ step: String) {
            if userInitiated {
                paperDownloadStep = step
            }
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else {
            return PaperDownloadResult(success: false, lastError: nil, debugLog: ["Article not found"])
        }
        guard articles[idx].sourceType == .paper else {
            logger.error("Refused paper download pipeline for non-paper source \(articleId)")
            return PaperDownloadResult(
                success: false,
                lastError: SourceError.fetchFailed,
                debugLog: ["Source is not a paper"]
            )
        }
        let gate = identity ?? PaperPDFIdentityGate(article: articles[idx])
        let url = articles[idx].url
        log.append("URL: \(url)")
        setDownloadStep("Downloading PDF…")
        defer {
            if userInitiated {
                paperDownloadStep = ""
            }
        }

        var pdfURL = PaperService.paperPDFURL(from: url)
        // eLife's page advertises no PDF link; its API names the file on the CDN.
        if pdfURL == nil, let elife = PaperService.eLifeArticle(from: url) {
            log.append("No direct PDF — asking eLife's API for \(elife.collection)/\(elife.id)...")
            setDownloadStep("Asking eLife for the PDF…")
            if let elifePDF = await PaperService.lookupELifePDFURL(elife) {
                log.append("eLife API found PDF: \(elifePDF)")
                pdfURL = elifePDF
            } else {
                log.append("eLife API named no PDF for \(elife.collection)/\(elife.id)")
            }
        }
        // For PMC URLs without a direct PDF URL, try PMCID-based lookup via EuropePMC
        if pdfURL == nil, let pmcid = PaperService.extractPMCID(from: url) {
            log.append("No direct PDF — trying EuropePMC for PMCID \(pmcid)...")
            setDownloadStep("Searching PubMed Central…")
            if let pmcResult = await PaperService.lookupPMCByPMCID(pmcid: pmcid) {
                // NCBI's own route first: Europe PMC's render answers apps with
                // 403 (2026-09-23), and `downloadPDF` answers NCBI's check.
                if let pmcPdfURL = pmcResult.orderedPDFURLs.first {
                    log.append("PMC PDF candidate: \(pmcPdfURL)")
                    pdfURL = pmcPdfURL
                } else if let pmcid = pmcResult.pmcid {
                    // No direct PDF, but we have PMCID — try BioC full text
                    log.append("No PDF URL from EuropePMC, trying BioC full text for \(pmcid)...")
                    if let fullText = await PaperService.fetchPMCFullText(pmcid: pmcid) {
                        log.append("BioC full text SUCCESS (\(fullText.count) chars)")
                        if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                            articles[idx].content = fullText
                            articles[idx].domain = "PubMed Central"
                            articles[idx].prepareForPaperMetadataExtraction()
                            guard await persistSource(articles[idx], context: "Save PubMed Central full text") else {
                                log.append("BioC full text save FAILED")
                                return PaperDownloadResult(success: false, lastError: SourceError.fetchFailed, debugLog: log)
                            }
                            await backfillPaperMetadata(onlyIds: [articleId])
                            _ = await extractPaperMetadataWithAI(id: articleId, showToasts: userInitiated)
                            let currentArticle = articles.first(where: { $0.id == articleId })
                            logger.info("Loaded PMC full text for: \(currentArticle?.title ?? articleId)")
                            let metadataComplete = currentArticle?.hasFinishedPaperIngestion == true
                            if userInitiated, metadataComplete {
                                showToast("Full text loaded from PubMed Central")
                            }
                            // Full text is useful reader/AI content, but it is not
                            // a PDF attachment. Keep resolving below instead of
                            // reporting a successful PDF download and leaving the
                            // paper in "needs attention".
                            log.append("BioC full text stored; continuing PDF resolution")
                        }
                    } else {
                        log.append("BioC full text FAILED")
                    }
                }
            } else {
                log.append("EuropePMC: no entry found for \(pmcid)")
            }
        }
        // Generic fallback: fetch the web page and look for citation_pdf_url meta tag.
        // This covers any publisher that follows Google Scholar's metadata conventions.
        if pdfURL == nil {
            log.append("No known pattern — fetching page to extract citation_pdf_url…")
            setDownloadStep("Scanning page for PDF link…")
            if let metaPdfURL = await PaperService.extractPDFURLFromWebPage(at: url) {
                log.append("Found PDF via meta tag: \(metaPdfURL)")
                pdfURL = metaPdfURL
            } else {
                log.append("No PDF meta tag found on page")
            }
        }
        guard let pdfURL else {
            log.append("Could not derive PDF URL from article URL")
            return PaperDownloadResult(success: false, lastError: SourceError.invalidURL, debugLog: log)
        }
        log.append("PDF URL: \(pdfURL)")

        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        await Self.ensureDirectoryExists(at: papersDir)

        let initialDOI = Self.paperDOI(for: articles[idx], sourceURL: pdfURL)
        let filename = Self.preferredPaperFilename(doi: initialDOI, url: url)
        var destPath = (papersDir as NSString).appendingPathComponent(filename)
        log.append("Dest: \(filename)")

        /// Attach the PDF at `destPath` once it is this paper, and run the
        /// metadata pass. `candidateURL` is where it was downloaded from, nil
        /// for a file that was already there. Another paper's file is thrown
        /// (`PaperPDFIdentityGate.admit`) before the Paper Metadata model can
        /// read it, so each step's catch below goes on to the next candidate.
        func attachDownloadedPDF(
            from candidateURL: String?,
            step: String,
            saveContext: String,
            successToast: String = "PDF downloaded",
            route: String
        ) async throws -> PaperDownloadResult {
            try await gate.admit(
                pdfAt: destPath,
                from: candidateURL ?? URL(fileURLWithPath: destPath).absoluteString,
                keepsRejectedFile: candidateURL == nil
            )
            log.append("\(step): SUCCESS")
            if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                let doi = await Self.paperDOIOffMain(
                    for: articles[idx],
                    attachedPDFPath: destPath,
                    sourceURL: candidateURL ?? pdfURL
                )
                convertPaperToLocalPDF(at: idx, destPath: destPath, doi: doi, updateDateAdded: userInitiated)
                guard await persistSource(
                    articles[idx],
                    context: saveContext,
                    replacingDerivedData: replacingDerivedData
                ) else {
                    log.append("\(step): DB save FAILED")
                    return PaperDownloadResult(success: false, lastError: SourceError.fetchFailed, debugLog: log)
                }
                let metadataComplete = await enrichPaperMetadataAfterPDFAttachment(
                    articleId: articleId,
                    userInitiated: userInitiated,
                    forceAIForMissingAuthor: forceMetadataExtractionForMissingAuthor
                )
                logger.info("Downloaded paper PDF \(route, privacy: .public): \((destPath as NSString).lastPathComponent)")
                if userInitiated {
                    showToast(metadataComplete ? successToast : "PDF downloaded, but AI metadata extraction failed")
                }
            }
            return PaperDownloadResult(
                success: true,
                lastError: nil,
                metadataComplete: articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion,
                debugLog: log
            )
        }

        // Don't re-download if file already exists
        if await Self.fileExists(at: destPath) {
            if await Self.canOpenPDF(at: destPath) {
                log.append("File already exists — using cached")
                do {
                    return try await attachDownloadedPDF(
                        from: nil,
                        step: "Cached file",
                        saveContext: "Save cached PDF attachment",
                        route: "from the Papers folder"
                    )
                } catch {
                    // Two papers can share a file name (DOIs cut to the same
                    // prefix did), so another paper's file here may be another
                    // row's PDF: it stays, and this paper downloads beside it.
                    destPath = await Self.unusedPaperPath(besides: destPath)
                    log.append("Cached file: FAILED — \(error.localizedDescription); downloading to \((destPath as NSString).lastPathComponent)")
                }
            } else {
                log.append("Cached file is not a readable PDF — removing and retrying")
                await Self.removeItem(at: destPath)
            }
        }

        var lastError: Error?

        // Step 1: Try unauthenticated download
        let pdfSource = Self.pdfSourceLabel(from: pdfURL)
        setDownloadStep("Downloading from \(pdfSource)…")
        log.append("Step 1: Unauthenticated download from \(pdfSource)...")
        do {
            try await sourceService.downloadPDF(from: pdfURL, to: destPath)
            guard await Self.canOpenPDF(at: destPath) else {
                await Self.removeItem(at: destPath)
                throw SourceError.pdfReadFailed
            }
            return try await attachDownloadedPDF(
                from: pdfURL,
                step: "Step 1",
                saveContext: "Save downloaded PDF",
                route: "from \(pdfSource)"
            )
        } catch {
            lastError = error
            log.append("Step 1: FAILED — \(error.localizedDescription)")
            logger.warning("PDF download failed for \(pdfURL): \(error.localizedDescription)")
            await Self.removeItem(at: destPath)

            if ScienceDirectService.isScienceDirectURL(pdfURL) || ScienceDirectService.isScienceDirectURL(url) {
                log.append("Step 1a: Trying authenticated ScienceDirect browser session...")
                setDownloadStep("Trying authenticated ScienceDirect session…")
                do {
                    try await ScienceDirectService.downloadPDFWithAuthenticatedWebSession(
                        from: pdfURL,
                        to: destPath,
                        label: articles.first(where: { $0.id == articleId })?.title
                    )
                    guard await Self.canOpenPDF(at: destPath) else {
                        await Self.removeItem(at: destPath)
                        throw SourceError.pdfReadFailed
                    }
                    return try await attachDownloadedPDF(
                        from: pdfURL,
                        step: "Step 1a",
                        saveContext: "Save authenticated ScienceDirect PDF",
                        successToast: "PDF downloaded from ScienceDirect",
                        route: "from ScienceDirect with the authenticated browser session"
                    )
                } catch {
                    lastError = error
                    log.append("Step 1a: FAILED — \(error.localizedDescription)")
                    logger.warning("Authenticated ScienceDirect download failed: \(error.localizedDescription)")
                    await Self.removeItem(at: destPath)
                }
            }

            // Step 1c: the publisher answered ForeverLM's own client with a
            // page — a bot check, or a refusal aimed at anything that is not a
            // browser — while the reader holds a session for the host. Ask
            // again as the reader: a hidden web view on the reader's data
            // store downloads the file, and when a bare request for it is
            // bounced (nature.com sends `<id>.pdf` back to the article page)
            // opens the paper's page and clicks its Download PDF control, the
            // way the reader's own button does. The file goes through the same
            // attach path as a PDF the reader downloaded.
            if let lastError, let pdfURLValue = URL(string: pdfURL) {
                let readerCookies = await InAppWebSession.cookies(for: pdfURLValue)
                switch WebSessionPDFDownload.decision(
                    pdfURL: pdfURL,
                    after: lastError,
                    cookies: readerCookies,
                    paperHasPDF: paperHasLocalPDF(articleId)
                ) {
                case .attempt:
                    log.append("Step 1c: Downloading through the reader's web session (\(readerCookies.count) cookies for \(pdfURLValue.host ?? pdfSource))...")
                    setDownloadStep("Downloading from \(pdfSource) as the reader…")
                    do {
                        let data = try await WebSessionPDFDownloader.download(
                            pdfURLValue,
                            landingPage: URL(string: url) ?? WebSessionPDFDownloader.landingPageURL(forPDF: pdfURLValue)
                        )
                        try await attachDownloadedPDFData(
                            to: articleId,
                            data: data,
                            sourceURL: pdfURLValue,
                            userInitiated: userInitiated,
                            forceAIForMissingAuthor: forceMetadataExtractionForMissingAuthor,
                            identity: gate,
                            destinationPath: destPath,
                            replacingDerivedData: replacingDerivedData
                        )
                        guard paperHasLocalPDF(articleId) else { throw SourceError.pdfReadFailed }
                        log.append("Step 1c: SUCCESS")
                        let current = articles.first(where: { $0.id == articleId })
                        PaperIngestionDiagnostics.recordWebSessionPDFDownload(
                            sourceID: articleId,
                            title: current?.title ?? "",
                            url: pdfURL
                        )
                        logger.info("Downloaded paper PDF through the reader's web session: \(pdfURL)")
                        if userInitiated {
                            let metadataComplete = current?.hasFinishedPaperIngestion == true
                            showToast(metadataComplete ? "PDF downloaded" : "PDF downloaded, but AI metadata extraction failed")
                        }
                        return PaperDownloadResult(
                            success: true,
                            lastError: nil,
                            metadataComplete: current?.hasFinishedPaperIngestion,
                            debugLog: log
                        )
                    } catch {
                        // The publisher's own answer stays the recorded failure:
                        // a wall met twice is the same wall.
                        log.append("Step 1c: FAILED — \(error.localizedDescription)")
                        logger.warning("Web-session PDF download failed for \(pdfURL): \(error.localizedDescription)")
                    }
                case .skipped(let reason):
                    log.append("Step 1c: Skipped — \(reason)")
                }
            }

            // For DOI links with 10.1101/ prefix, the paper might be on medRxiv instead of bioRxiv.
            if url.lowercased().contains("doi.org/10.1101/"), pdfURL.contains("biorxiv.org") {
                let medrxivURL = pdfURL.replacingOccurrences(of: "biorxiv.org", with: "medrxiv.org")
                log.append("Step 1b: Trying medRxiv fallback...")
                do {
                    try await sourceService.downloadPDF(from: medrxivURL, to: destPath)
                    guard await Self.canOpenPDF(at: destPath) else {
                        await Self.removeItem(at: destPath)
                        throw SourceError.pdfReadFailed
                    }
                    return try await attachDownloadedPDF(
                        from: medrxivURL,
                        step: "Step 1b",
                        saveContext: "Save downloaded PDF",
                        route: "from the medRxiv fallback"
                    )
                } catch {
                    lastError = error
                    log.append("Step 1b: FAILED — \(error.localizedDescription)")
                    logger.warning("medRxiv fallback also failed: \(error.localizedDescription)")
                    await Self.removeItem(at: destPath)
                }
            }

            log.append("Step 2: Scanning article page for an alternate PDF link...")
            setDownloadStep("Scanning page for PDF link…")
            if let alternatePDFURL = await PaperService.extractPDFURLFromWebPage(at: url),
               alternatePDFURL != pdfURL {
                log.append("Step 2: Found alternate PDF URL: \(alternatePDFURL)")
                do {
                    try await sourceService.downloadPDF(from: alternatePDFURL, to: destPath)
                    guard await Self.canOpenPDF(at: destPath) else {
                        await Self.removeItem(at: destPath)
                        throw SourceError.pdfReadFailed
                    }
                    return try await attachDownloadedPDF(
                        from: alternatePDFURL,
                        step: "Step 2",
                        saveContext: "Save downloaded alternate PDF",
                        route: "from the article page's alternate link"
                    )
                } catch {
                    lastError = error
                    log.append("Step 2: FAILED — \(error.localizedDescription)")
                    logger.warning("Alternate PDF download failed for \(alternatePDFURL): \(error.localizedDescription)")
                    await Self.removeItem(at: destPath)
                }
            } else {
                log.append("Step 2: No alternate PDF link found")
            }
            return PaperDownloadResult(success: false, lastError: lastError, debugLog: log)
        }
    }

    /// Start a background pass that tries to resolve every non-paywalled paper
    /// that still needs PDF attention. The command returns immediately so the
    /// sidebar and reader stay usable while network downloads continue.
    func downloadMissingPaperPDFs() {
        if missingPaperPDFDownloadTask != nil || isResolvingMissingPaperPDFs {
            showToast("Already checking papers")
            return
        }

        // Recover papers left stuck in `.fetching` by a download that was
        // interrupted (app quit or crashed mid-fetch). They're hidden from the
        // visible attention list and badge so an in-flight download can't strand
        // the badge, but this manual pass is the safe place to retry them: the
        // guard above means no batch is running, and `isFetchingContent` rules out
        // an active single-paper download whose row also sits in `.fetching`.
        let stuckIds = isFetchingContent ? [] : papersStuckFetchingPDF.map(\.id)

        var seen = Set<String>()
        let missingIds = (papersNeedingPDFAttention.map(\.id) + stuckIds)
            .filter { seen.insert($0).inserted }
        guard !missingIds.isEmpty else {
            let waiting = unavailableRecordedPDFCount
            showToast(
                waiting > 0
                    ? "No papers need PDF attention. \(waiting) PDFs are waiting for iCloud to download them."
                    : "No papers need PDF attention"
            )
            return
        }

        isResolvingMissingPaperPDFs = true
        paperPDFResolutionKind = .missingPDFs
        isStoppingPaperPDFResolution = false
        paperDownloadStep = "Checking \(missingIds.count) paper\(missingIds.count == 1 ? "" : "s") in background…"
        missingPaperPDFDownloadTask = Task { [weak self] in
            await self?.runMissingPaperPDFDownload(for: missingIds, recovering: stuckIds)
        }
    }

    /// Which batch owns the in-flight PDF-resolution pass. Both batches share
    /// `missingPaperPDFDownloadTask`, so the sidebar needs this to put Cancel on
    /// the button the learner actually pressed.
    enum PaperPDFResolutionKind {
        case missingPDFs
        case paywallRecheck
    }

    /// Ask the running batch to stop. Deliberately cooperative: the paper being
    /// worked on right now finishes its download/cleanup/persist sequence, and
    /// the loop then breaks instead of starting the next one. Hard-cancelling the
    /// task would abort mid-persist and could strand a row in `.fetching`.
    /// The per-paper phase captions keep writing to `paperDownloadStep` while the
    /// current paper finishes, so the stopping state is published through this
    /// flag and the sidebar renders its own caption from it.
    func stopPaperPDFResolution() {
        guard isResolvingMissingPaperPDFs, !isStoppingPaperPDFResolution else { return }
        isStoppingPaperPDFResolution = true
    }

    /// Revisit papers the learner previously marked paywalled. Unlike the normal
    /// missing-PDF pass, this deliberately includes paywall markers and keeps them
    /// in place unless a readable PDF is successfully attached. The command is
    /// manual: open-access availability changes over time, but repeatedly spending
    /// network/AI work in the background would be surprising.
    func recheckPaywalledPaperPDFs() {
        if missingPaperPDFDownloadTask != nil || isResolvingMissingPaperPDFs {
            showToast("Already checking papers")
            return
        }

        let paywalledIds = paywalledPapersEligibleForRecheck.map(\.id)
        guard !paywalledIds.isEmpty else {
            showToast("No paywalled papers to recheck")
            return
        }

        isResolvingMissingPaperPDFs = true
        paperPDFResolutionKind = .paywallRecheck
        isStoppingPaperPDFResolution = false
        paperDownloadStep = "Rechecking \(paywalledIds.count) paywalled paper\(paywalledIds.count == 1 ? "" : "s")…"
        missingPaperPDFDownloadTask = Task { [weak self] in
            await self?.runPaywalledPaperRecheck(for: paywalledIds)
        }
    }

    func runPaywalledPaperRecheck(for paperIds: [String]) async {
        logger.info("Rechecking \(paperIds.count) paywalled paper(s) for open-access copies")
        var recovered = 0
        var stillPaywalled = 0
        var movedToArticles = 0
        var failed = 0
        var skippedBrowserChecks = 0
        var turnedAway: [PaperPDFIdentityMismatchError] = []
        var stoppedAfter: Int?
        let browserConfig = KeychainService.resolveConfig(for: .paperBrowserAgent)

        defer {
            paperDownloadStep = ""
            isResolvingMissingPaperPDFs = false
            paperPDFResolutionKind = nil
            isStoppingPaperPDFResolution = false
            missingPaperPDFDownloadTask = nil
        }

        for (index, articleId) in paperIds.enumerated() {
            if isStoppingPaperPDFResolution {
                stoppedAfter = index
                break
            }
            paperDownloadStep = "Rechecking paper \(index + 1)/\(paperIds.count)…"
            let identity = articles.first(where: { $0.id == articleId }).map { PaperPDFIdentityGate(article: $0) }
            let outcome = await resolveMissingPaperPDF(
                for: articleId,
                browserConfig: browserConfig,
                recheckingPaywall: true,
                identity: identity,
                onReachingBrowserStep: { [weak self] in
                    self?.paperDownloadStep = "Browsing for paper \(index + 1)/\(paperIds.count)…"
                }
            )
            turnedAway += identity?.rejections ?? []
            switch outcome {
            case .downloaded:
                recovered += 1
            case .textRecovered:
                recovered += 1
            case .paywalled, .suspectedPaywall:
                stillPaywalled += 1
            case .reclassifiedAsArticle:
                movedToArticles += 1
            case .failed:
                failed += 1
            case .skippedNoBrowserConfig:
                skippedBrowserChecks += 1
            }
        }

        var parts = ["recovered \(recovered)"]
        if stillPaywalled > 0 { parts.append("\(stillPaywalled) still paywalled") }
        if movedToArticles > 0 { parts.append("moved \(movedToArticles) to Articles") }
        if failed > 0 { parts.append("\(failed) checks failed") }
        if skippedBrowserChecks > 0 { parts.append("\(skippedBrowserChecks) need an AI browser model") }
        if let turnedAwaySummary = Self.turnedAwayPDFsSummary(turnedAway) { parts.append(turnedAwaySummary) }
        if let stoppedAfter {
            showToast(
                "Paywall recheck stopped after \(stoppedAfter) of \(paperIds.count) papers: \(parts.joined(separator: ", "))"
            )
        } else {
            showToast("Paywall recheck complete: \(parts.joined(separator: ", "))")
        }
    }

    func runMissingPaperPDFDownload(for missingIds: [String], recovering stuckIds: [String] = []) async {
        // Un-stick papers left in `.fetching` before retrying them, so that even a
        // failed retry leaves them back in `.ready` — visible in the attention list
        // and counted by the badge again — instead of orphaned. Persist through
        // storage so the recovery survives relaunch and keeps CloudKit sync
        // metadata consistent. `downloadPaperPDF` never re-enters `.fetching` on
        // this path, so a failed attempt cannot re-strand them.
        for id in Set(stuckIds) {
            guard let idx = articles.firstIndex(where: { $0.id == id }),
                  articles[idx].state == .fetching else { continue }
            articles[idx].prepareForPaperMetadataExtraction()
            _ = await persistSource(articles[idx], context: "Recover stuck paper download state")
        }

        logger.info("Checking \(missingIds.count) paper(s) needing PDF attention")
        var downloaded = 0
        var textRecovered = 0
        var incompleteMetadata = 0
        var paywalled = 0
        var suspectedPaywall = 0
        var movedToArticles = 0
        var failed = 0
        let browserConfig = KeychainService.resolveConfig(for: .paperBrowserAgent)
        var skippedBrowserChecks = 0
        var turnedAway: [PaperPDFIdentityMismatchError] = []
        var stoppedAfter: Int?

        defer {
            paperDownloadStep = ""
            isResolvingMissingPaperPDFs = false
            paperPDFResolutionKind = nil
            isStoppingPaperPDFResolution = false
            missingPaperPDFDownloadTask = nil
        }

        for (i, articleId) in missingIds.enumerated() {
            if isStoppingPaperPDFResolution {
                stoppedAfter = i
                break
            }
            paperDownloadStep = "Trying paper \(i + 1)/\(missingIds.count)…"

            let identity = articles.first(where: { $0.id == articleId }).map { PaperPDFIdentityGate(article: $0) }
            let outcome = await resolveMissingPaperPDF(
                for: articleId,
                browserConfig: browserConfig,
                identity: identity,
                onReachingBrowserStep: { [weak self] in
                    self?.paperDownloadStep = "Checking page \(i + 1)/\(missingIds.count)…"
                }
            )
            turnedAway += identity?.rejections ?? []
            switch outcome {
            case .downloaded(metadataComplete: let metadataComplete):
                downloaded += 1
                if !metadataComplete {
                    incompleteMetadata += 1
                }
            case .textRecovered(metadataComplete: let metadataComplete):
                textRecovered += 1
                if !metadataComplete {
                    incompleteMetadata += 1
                }
            case .paywalled:
                paywalled += 1
            case .suspectedPaywall:
                suspectedPaywall += 1
            case .reclassifiedAsArticle:
                movedToArticles += 1
            case .failed:
                failed += 1
            case .skippedNoBrowserConfig:
                skippedBrowserChecks += 1
                failed += 1
            }
        }

        var parts: [String] = []
        if downloaded > 0 {
            parts.append("downloaded \(downloaded) PDF\(downloaded == 1 ? "" : "s")")
        }
        if textRecovered > 0 {
            parts.append("recovered text for \(textRecovered) paper\(textRecovered == 1 ? "" : "s")")
        }
        if incompleteMetadata > 0 {
            parts.append("\(incompleteMetadata) still missing metadata")
        }
        if paywalled > 0 {
            parts.append("marked \(paywalled) paywalled")
        }
        if suspectedPaywall > 0 {
            parts.append("\(suspectedPaywall) look\(suspectedPaywall == 1 ? "s" : "") paywalled (Mark as Paywalled is on the row)")
        }
        if movedToArticles > 0 {
            parts.append("moved \(movedToArticles) to Articles")
        }
        if failed > 0 {
            parts.append("\(failed) still need attention")
        }
        if let turnedAwaySummary = Self.turnedAwayPDFsSummary(turnedAway) {
            parts.append(turnedAwaySummary)
        }
        if parts.isEmpty {
            parts.append("no changes")
        }
        let suffix = skippedBrowserChecks > 0 ? ". Set an API key to check paywalls." : ""
        if let stoppedAfter {
            showToast(
                "Paper check stopped after \(stoppedAfter) of \(missingIds.count) papers: \(parts.joined(separator: ", "))\(suffix)"
            )
        } else {
            showToast("Paper check complete: \(parts.joined(separator: ", "))\(suffix)")
        }
    }

    func paperHasLocalPDF(_ articleId: String) -> Bool {
        articles.first(where: { $0.id == articleId })?.resolvedPDFPath != nil
    }

    func paperIsMarkedPaywalled(_ articleId: String) -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }) else { return false }
        return article.hasPaywallMarker
    }

    enum MissingPaperPDFOutcome {
        case downloaded(metadataComplete: Bool)
        case textRecovered(metadataComplete: Bool)
        case paywalled
        /// Still needs attention, but its row now offers Mark as Paywalled
        /// with the AI browser's reason behind it.
        case suspectedPaywall
        /// Not a paper after all; it now lives in Articles and left the
        /// attention list for good.
        case reclassifiedAsArticle
        case failed
        /// Reached the AI-browser step but no browser API key is configured.
        case skippedNoBrowserConfig
    }

    /// Retry a failed Source Content Cleanup from the paper row. The row moves
    /// back to Processing immediately, while the durable retry continues in the
    /// view model even if that row scrolls offscreen or changes sections.
    @discardableResult
    func fixPaperContentCleanup(for articleId: String) -> Task<Void, Never>? {
        guard !processingPaperIDs.contains(articleId),
              let index = articles.firstIndex(where: { $0.id == articleId }),
              articles[index].isPaperContentCleanupFailure else { return nil }

        let previous = articles[index]
        articles[index].prepareForPaperMetadataExtraction()
        let queued = articles[index]
        pendingPaperProcessingIds.insert(articleId)

        return Task {
            defer { pendingPaperProcessingIds.remove(articleId) }

            guard !Task.isCancelled else {
                if let currentIndex = articles.firstIndex(where: { $0.id == articleId }),
                   articles[currentIndex].state == .queued {
                    articles[currentIndex] = previous
                }
                return
            }

            guard await persistSource(
                queued,
                context: "Restart paper content cleanup",
                showErrorToast: true
            ) else {
                if let currentIndex = articles.firstIndex(where: { $0.id == articleId }),
                   articles[currentIndex].state == .queued {
                    articles[currentIndex] = previous
                }
                return
            }

            let outcome = await resolveMissingPaperPDF(
                for: articleId,
                browserConfig: KeychainService.resolveConfig(for: .paperBrowserAgent)
            )
            if let current = articles.first(where: { $0.id == articleId }),
               current.hasFinishedPaperIngestion {
                showToast(
                    current.isPaperReadyForListenPreparation
                        ? "Paper cleanup fixed"
                        : "Paper metadata saved; its text is being cleaned up in the background"
                )
                return
            }

            // Recovery can restore canonical text but still stop at the required
            // metadata step (for example when credits run out). Never let that
            // incomplete paper fall into the ordinary ready list.
            if let currentIndex = articles.firstIndex(where: { $0.id == articleId }),
               articles[currentIndex].state != .error {
                let message = "Paper ingestion still needs attention: \(stalledPaperIngestionError(for: articleId).localizedDescription)"
                articles[currentIndex].failPaperIngestionMetadata(message)
                PaperIngestionDiagnostics.recordFailure(
                    sourceID: articleId,
                    title: articles[currentIndex].title,
                    message: message
                )
                _ = await persistSource(
                    articles[currentIndex],
                    context: "Save incomplete paper cleanup retry",
                    showErrorToast: false
                )
            }

            switch outcome {
            case .downloaded, .textRecovered:
                showToast("Paper text recovered, but metadata still needs attention")
            case .paywalled:
                showToast("Paper cleanup still needs attention because the source is paywalled")
            case .suspectedPaywall:
                showToast("Paper cleanup still needs attention; the page looks paywalled — Mark as Paywalled is on the row")
            case .reclassifiedAsArticle:
                showToast("This source is an article, not a paper; it moved to Articles")
            case .failed, .skippedNoBrowserConfig:
                showToast("Paper cleanup still needs attention")
            }
        }
    }

    /// Run the full PDF-resolution pipeline for a single paper needing attention:
    /// direct download, then open-access alternative, then (macOS) the AI browser
    /// agent. Shared by the bulk "papers needing attention" pass and the one-shot
    /// automatic attempt for newly added papers. Stays quiet (no toasts) so callers
    /// own user-facing messaging.
    ///
    /// Every PDF it finds is held to `identity`; a batch passes one per paper
    /// so its summary can count the files turned away as other papers.
    func resolveMissingPaperPDF(
        for articleId: String,
        browserConfig: AITaskConfig?,
        recheckingPaywall: Bool = false,
        identity: PaperPDFIdentityGate? = nil,
        onReachingBrowserStep: (() -> Void)? = nil
    ) async -> MissingPaperPDFOutcome {
        resolvingPaperPDFIds.insert(articleId)
        defer { resolvingPaperPDFIds.remove(articleId) }

        // A page the URL already proves is not a paper never had a PDF to
        // find. Settle it here, before any download or browser run, so every
        // library that imported the same link reaches the same state.
        if let article = articles.first(where: { $0.id == articleId }),
           PaperService.isNatureNewsURL(article.url),
           await reclassifyPaperAsArticle(
               articleId: articleId,
               reason: "Nature news article id; the journal's journalism has no paper PDF."
           ) {
            return .reclassifiedAsArticle
        }

        // A terminal cleanup/metadata failure can still have a perfectly good
        // PDF attached. Retrying that attention row must resume ingestion from
        // the saved PDF/raw text, not download the same document again.
        if paperHasLocalPDF(articleId) {
            let recoveredText = await recoverReadablePaperText(for: articleId)
            var metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            if recoveredText && !metadataComplete {
                metadataComplete = await enrichPaperMetadataAfterPDFAttachment(
                    articleId: articleId,
                    userInitiated: false,
                    forceAIForMissingAuthor: true
                )
            }
            return recoveredText
                ? .textRecovered(metadataComplete: metadataComplete)
                : .failed
        }

        // Every candidate below — open-access copies and the paper's own link
        // alike — is held to the paper as it is now, before any copy's address
        // is swapped onto the row.
        let identity = identity ?? articles.first(where: { $0.id == articleId }).map { PaperPDFIdentityGate(article: $0) }

        // A paper that was closed last month may now have a repository copy or
        // an expired embargo. During a recheck, query the structured OA sources
        // first; this is faster, cheaper, and more reliable than browser driving.
        if recheckingPaywall {
            _ = await adoptOpenAccessAlternativeIfAvailable(
                for: articleId,
                userInitiated: false,
                markFailure: false,
                forceMetadataExtractionForMissingAuthor: true,
                identity: identity
            )
            if paperHasLocalPDF(articleId) {
                let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .downloaded(metadataComplete: metadataComplete)
            }
        }

        let result = await downloadPaperPDF(
            for: articleId,
            userInitiated: false,
            forceMetadataExtractionForMissingAuthor: true,
            identity: identity
        )
        if result.success { return .downloaded(metadataComplete: result.metadataComplete == true) }
        if paperHasLocalPDF(articleId) {
            return .downloaded(metadataComplete: false)
        }

        if !recheckingPaywall {
            _ = await adoptOpenAccessAlternativeIfAvailable(
                for: articleId,
                userInitiated: false,
                markFailure: false,
                forceMetadataExtractionForMissingAuthor: true,
                identity: identity
            )
        }

        if paperHasLocalPDF(articleId) {
            let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            return .downloaded(metadataComplete: metadataComplete)
        }
        if paperIsMarkedPaywalled(articleId), !recheckingPaywall {
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .paywalled
        }

        guard let browserConfig else {
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .skippedNoBrowserConfig
        }
        onReachingBrowserStep?()
        let browserResult = await attemptPaperPDFDownloadWithAIBrowser(
            for: articleId,
            config: browserConfig,
            showPaywallToast: false,
            identity: identity
        )
        switch browserResult {
        case .downloaded:
            let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            return .downloaded(metadataComplete: metadataComplete)
        case .paywalled:
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .paywalled
        case .suspectedPaywall:
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .suspectedPaywall
        case .notAPaper:
            return .reclassifiedAsArticle
        case .cancelled:
            if paperHasLocalPDF(articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .downloaded(metadataComplete: complete)
            }
            return .failed
        case .failed:
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .failed
        }
    }

    /// Recover a paper's text from a preserved extraction or its saved PDF,
    /// through the same cleanup/metadata gates so CloudKit receives the
    /// canonical `sourceContentAsset` CarPlay uses.
    ///
    /// A paper is a PDF. When every PDF route is blocked this leaves the row
    /// asking for the file: the publisher's page is never read as the paper on
    /// the app's own initiative. Until build 70 it was, and the abstract, the
    /// figure titles and the Extended Data legends of a paper the learner had
    /// no access to were stored as the paper. The one route from a page to a
    /// paper is the reader's **Save Paper from Page**, which the learner asks
    /// for with the page in front of them, and which prints that page to the
    /// PDF as well.
    private func recoverReadablePaperText(for articleId: String) async -> Bool {
        if let stored = await storage.loadSourceContent(articleId),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Text that is the publisher's preview rather than the paper is not
            // "recovered"; it is dropped here so the reader sees a paper without
            // text again, and shows the publisher's page.
            if !(await discardStoredPublisherWallTextIfNeeded(for: articleId, stored: stored)) {
                return true
            }
        }
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }

        let raw: String
        if let preparedRaw = await storage.loadRawPaperContent(articleId),
           !preparedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = preparedRaw
        } else if article.resolvedPDFPath != nil {
            raw = await Self.fullPaperTextOffMain(for: article)
        } else {
            logger.info("Paper \(articleId) has no PDF and no preserved extraction; the row keeps asking for the PDF")
            return false
        }
        return await installRecoveredPaperText(for: articleId, raw: raw)
    }

    /// Builds before 70 could store a publisher's preview — the abstract, one-line
    /// figure titles and the Extended Data legends, thousands of words with no
    /// Main, Results or Methods — as a paper's text, because the length check ran
    /// on the whole page and the wall check on text the chrome filter had already
    /// stripped of the purchase panel. Such text is worse than none: the row read
    /// as finished, and the reader showed the text instead of the publisher's
    /// page, which is where the learner signs in. Drop it, with everything derived
    /// from it, so the paper asks for its PDF again. Returns whether it did.
    @discardableResult
    func discardStoredPublisherWallTextIfNeeded(for articleId: String, stored: String? = nil) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil else { return false }
        let text: String
        if let stored {
            text = stored
        } else if let loaded = await storage.loadSourceContent(articleId) {
            text = loaded
        } else {
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !PaperService.looksLikePaperFullText(text) else { return false }

        await storage.clearSourceDerivedData(articleId)
        guard let current = articles.firstIndex(where: { $0.id == articleId }) else { return true }
        articles[current].content = nil
        articles[current].wordCount = nil
        if articles[current].errorMessage?.isEmpty ?? true {
            articles[current].state = .queued
        }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        PaperIngestionDiagnostics.recordDiscardedWallText(
            sourceID: articleId,
            title: articles[current].title,
            wordCount: wordCount
        )
        logger.info(
            "Dropped \(wordCount) words of publisher preview stored as the text of paper \(articleId); the paper needs its PDF"
        )
        return true
    }

    /// Save a PDF printed from the publisher's page as the paper's file. The
    /// paper's text, metadata and attestation are already in place from the page,
    /// so unlike a downloaded PDF this neither re-queues metadata extraction nor
    /// re-reads the text: the file is what was missing. Returns whether it saved.
    @discardableResult
    func attachRenderedPublisherPagePDF(to articleId: String, data: Data) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil else { return false }
        guard SourceService.looksLikePDFData(data), await Self.canOpenPDFData(data) else {
            logger.warning("The printed page for \(articleId) is not a readable PDF; not saved")
            return false
        }
        let article = articles[idx]
        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        await Self.ensureDirectoryExists(at: papersDir)
        let doi = Self.paperDOI(for: article, sourceURL: article.url)
        let filename = Self.preferredPaperFilename(doi: doi, url: article.url)
        let destPath = (papersDir as NSString).appendingPathComponent(filename)
        do {
            try await Self.installDownloadedPDFData(data, at: destPath)
        } catch {
            logger.warning("Could not save the printed page for \(articleId): \(error.localizedDescription)")
            return false
        }
        StudioArticle.recordExistingLocalPath(destPath)

        guard let current = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        articles[current].localFilePath = destPath
        if articles[current].doi == nil, let doi, !doi.isEmpty {
            articles[current].doi = doi
        }
        guard await persistSource(
            articles[current],
            context: "Save PDF printed from the publisher's page",
            showErrorToast: false,
            syncImmediately: true
        ) else { return false }
        let pageCount = await Task.detached(priority: .utility) {
            #if os(macOS)
            return PublisherPagePDFRenderer.pdfPageCount(of: data)
            #else
            return 0
            #endif
        }.value
        PaperIngestionDiagnostics.recordRenderedPublisherPagePDF(
            sourceID: articleId,
            title: articles[current].title,
            pageCount: pageCount
        )
        logger.info("Saved the publisher's page for \(articleId) as a \(pageCount)-page PDF: \(filename)")
        kickSourceEmbeddingIndexing()
        showToast("Saved a PDF of the publisher's page")
        return true
    }

    /// Store text recovered for a paper that has no readable text yet — from a
    /// preserved extraction, its PDF, the publisher's page, or the page the
    /// reader has on screen — through the same cleanup and metadata gates a
    /// downloaded PDF passes. Returns whether the paper came out ready.
    func installRecoveredPaperText(for articleId: String, raw: String) async -> Bool {
        guard var article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            article.state = .error
            article.errorMessage = "Paper ingestion failed: no readable paper text could be recovered."
            PaperIngestionDiagnostics.recordFailure(
                sourceID: article.id,
                title: article.title,
                message: article.errorMessage ?? "No readable paper text could be recovered."
            )
            _ = await persistSource(
                article,
                context: "Save unreadable repaired paper",
                showErrorToast: false
            )
            if let index = articles.firstIndex(where: { $0.id == articleId }) {
                articles[index] = article
            }
            return false
        }

        if article.hasPaperIngestionAttestation {
            do {
                let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                    source: AIUsageSource(source: article),
                    rawText: raw
                )
                article.installPreparedPaperContent(
                    raw: prepared.raw,
                    clean: prepared.clean,
                    metadata: prepared.metadata,
                    wordCount: prepared.wordCount
                )
                article.state = .ready
                article.errorMessage = nil
                guard await persistSource(
                    article,
                    context: "Save recovered paper text",
                    showErrorToast: false,
                    syncImmediately: true
                ) else { return false }
                article.discardPersistedPaperContentFromMemory()
                if let index = articles.firstIndex(where: { $0.id == articleId }) {
                    articles[index] = article
                }
                return true
            } catch {
                let failureMessage = error.localizedDescription
                let rawSHA256 = await Self.contentSHA256OffMain(raw)
                article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
                let shouldRetryAutomatically =
                    AITransientErrorClassifier.shouldRetryAutomatically(error)
                article.state = shouldRetryAutomatically ? .queued : .error
                article.errorMessage = shouldRetryAutomatically
                    ? nil
                    : StudioArticle.paperContentCleanupFailureMessage(failureMessage)
                PaperIngestionDiagnostics.recordFailure(
                    sourceID: article.id,
                    title: article.title,
                    message: article.errorMessage ?? "Paper cleanup will retry automatically: \(failureMessage)"
                )
                let persisted = await persistSource(
                    article,
                    context: "Save recovered paper cleanup error",
                    showErrorToast: false
                )
                // Raw extraction is ingestion-only. In particular, leaving it
                // in memory on an auto-retry lets the generic queued-content
                // path mistake it for canonical text and promote the paper.
                if shouldRetryAutomatically {
                    article.discardPersistedPaperContentFromMemory()
                } else {
                    article.content = raw
                }
                if persisted, let index = articles.firstIndex(where: { $0.id == articleId }) {
                    articles[index] = article
                }
                return false
            }
        }

        let rawSHA256 = await Self.contentSHA256OffMain(raw)
        article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
        article.prepareForPaperMetadataExtraction()
        guard await persistSource(
            article,
            context: "Stage recovered paper text",
            showErrorToast: false
        ) else { return false }
        // The metadata model needs an opening excerpt before the durable raw
        // preparation is loaded later in its pipeline. Restore it only after
        // persistence so the queued save cannot publish raw text as canonical.
        article.content = raw
        if let index = articles.firstIndex(where: { $0.id == articleId }) {
            articles[index] = article
        }
        return await extractPaperMetadataWithAI(id: articleId, showToasts: false)
    }

    nonisolated static func contentSHA256OffMain(_ text: String) async -> String {
        await Task.detached(priority: .utility) {
            PaperContentPreparationService.sha256(text)
        }.value
    }

    /// One-shot automatic PDF resolution for a newly added paper, so the user no
    /// longer has to click "papers needing attention" for every new paper. Runs the
    /// exact same pipeline as the bulk pass — direct download, open-access
    /// alternative, then the AI browser agent — so every paper gets the full
    /// treatment at least once automatically. Returns the outcome so the drain loop
    /// can report a summary; returns `nil` only when the paper no longer needs
    /// attention (already has a PDF, has a terminal paywall error, or isn't fetchable). The
    /// bulk-pass guard lives in the drain loop, which yields its turn without burning
    /// the attempt; this function always runs when called.
    @discardableResult
    func autoResolveNewPaperPDF(for articleId: String) async -> MissingPaperPDFOutcome? {
        defer {
            pendingPaperProcessingIds.remove(articleId)
            queuedPaperPDFResolutionIds.remove(articleId)
        }
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper,
              (!article.hasPaywallMarker || article.state == .queued) else { return nil }

        if article.resolvedPDFPath != nil {
            guard article.state == .queued,
                  (article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            else { return nil }
            autoFetchAttemptedPaperIDs.insert(articleId)
            let recovered = await recoverReadablePaperText(for: articleId)
            let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            return recovered ? .textRecovered(metadataComplete: metadataComplete) : .failed
        }
        guard article.url.hasPrefix("http") else { return nil }
        // Mark attempted only now that we are actually running the pipeline, so a
        // paper deferred because a manual bulk pass was active keeps its turn and is
        // retried by a later sweep instead of being silently marked done.
        autoFetchAttemptedPaperIDs.insert(articleId)
        let browserConfig = KeychainService.resolveConfig(for: .paperBrowserAgent)
        return await resolveMissingPaperPDF(for: articleId, browserConfig: browserConfig)
    }

    /// True for a paper that still needs a PDF and hasn't already been
    /// queued/attempted for automatic fetch this session. Covers the existing
    /// backlog too, so the user never has to press "papers needing attention" — the
    /// once-per-session `alreadyAttempted` guard keeps us from retrying the same
    /// paper repeatedly within a session. `nonisolated` so the candidate scan can
    /// run off the main actor over a snapshot.
    ///
    /// `dedupKeysWithPDF` is the set of dedup keys of papers that already have a
    /// PDF (see `paperDedupKeysForPapersWithPDF`). A paper whose keys intersect it
    /// is a duplicate of one we already have — the visible "needs attention" list
    /// hides it via the same dedup, so auto-fetch skips it too. Without this guard
    /// the auto check keeps counting and retrying duplicates the user can never see
    /// in the Papers tab.
    ///
    /// `unavailableRecordedPDFIDs` is the storage-degraded set (see
    /// `unavailableRecordedPaperPDFIDs(in:)`): papers whose PDF exists on record
    /// but whose file storage is currently unreachable at scale. Auto-fetch must
    /// not re-download those from publishers. The callers add the papers whose
    /// record says another device finished their ingestion
    /// (`StorageService.sourceIDsIngestedOnAnotherDevice`): their PDF is on that
    /// device and arrives here as a satellite, so a search for it is the same
    /// work done twice.
    nonisolated static func paperNeedsAutoFetch(
        _ article: StudioArticle,
        alreadyAttempted: Set<String>,
        dedupKeysWithPDF: Set<String>,
        unavailableRecordedPDFIDs: Set<String>
    ) -> Bool {
        let needsSavedPDFTextRecovery = article.resolvedPDFPath != nil
            && article.state == .queued
            && (article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let needsPDFResolution = article.resolvedPDFPath == nil
            && article.url.hasPrefix("http")
            && dedupKeysWithPDF.isDisjoint(with: paperDedupLookupKeys(for: article))
        return article.sourceType == .paper
            && !unavailableRecordedPDFIDs.contains(article.id)
            // Schema v37 deliberately requeues historical paywalled papers
            // that never stored source text. Give that queued repair one
            // automatic pass; terminal paywall errors remain excluded.
            && (!article.hasPaywallMarker || article.state == .queued)
            && article.state != .fetching
            && !alreadyAttempted.contains(article.id)
            && (needsSavedPDFTextRecovery || needsPDFResolution)
    }

    /// Sweep for papers that still need a PDF and enqueue a silent background fetch
    /// for each. Safe to call from any path that loads or replaces `articles`, no
    /// matter how the paper was added (URL bar, browser reading list, suggested
    /// sources, or an MCP write picked up on the next reload). The full-library scan
    /// runs off the main actor over a snapshot so it never costs main-actor time
    /// during a refresh; only the tiny enqueue hops back. Deferred until after
    /// launch by `loadQueue` so startup stays read-only and fast.
    func autoFetchNewlyAddedPapers() {
        let snapshot = articles
        let attempted = autoFetchAttemptedPaperIDs
        let storage = storage
        Task.detached(priority: .utility) { [weak self] in
            let dedupKeysWithPDF = Self.paperDedupKeysForPapersWithPDF(in: snapshot)
            // A paper another device finished ingesting has its PDF on that device and as a satellite on its
            // way here; searching for it again, with the AI browser, is the work being done twice.
            let finishedElsewhere = await storage.sourceIDsIngestedOnAnotherDevice()
            let unavailableIDs = Self.unavailableRecordedPaperPDFIDs(in: snapshot).union(finishedElsewhere)
            let candidates = snapshot
                .filter {
                    Self.paperNeedsAutoFetch(
                        $0,
                        alreadyAttempted: attempted,
                        dedupKeysWithPDF: dedupKeysWithPDF,
                        unavailableRecordedPDFIDs: unavailableIDs
                    )
                }
                .map(\.id)
            guard !candidates.isEmpty else { return }
            await self?.enqueueAutoPaperFetch(
                candidates,
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: unavailableIDs
            )
        }
    }

    /// Enqueue papers for automatic background PDF resolution, deduplicated per
    /// session so a paper is never auto-fetched twice. Re-validates against live
    /// state because the off-main scan worked from a snapshot. `dedupKeysWithPDF`
    /// and `unavailableRecordedPDFIDs` are threaded through from that scan so the
    /// re-validation reuses them without re-running the stat-heavy
    /// paper-with-PDF scan on the main actor. Cheap main-actor work.
    func enqueueAutoPaperFetch(
        _ articleIds: [String],
        dedupKeysWithPDF: Set<String>,
        unavailableRecordedPDFIDs: Set<String>
    ) {
        var didEnqueue = false
        for id in articleIds {
            guard let article = articlesById[id],
                  Self.paperNeedsAutoFetch(
                      article,
                      alreadyAttempted: autoFetchAttemptedPaperIDs,
                      dedupKeysWithPDF: dedupKeysWithPDF,
                      unavailableRecordedPDFIDs: unavailableRecordedPDFIDs
                  )
            else {
                pendingPaperProcessingIds.remove(id)
                queuedPaperPDFResolutionIds.remove(id)
                continue
            }
            guard !autoFetchPaperQueue.contains(id) else { continue }
            autoFetchPaperQueue.append(id)
            queuedPaperPDFResolutionIds.insert(id)
            didEnqueue = true
        }
        if didEnqueue { drainAutoPaperFetchQueue() }
    }

    /// Convenience for direct add paths (e.g. the URL bar) that enqueue a single
    /// paper. Computes the paper-with-PDF dedup key set off the main actor over a
    /// snapshot so re-adding a paper we already have a PDF for is skipped, just
    /// like the bulk scan.
    func enqueueAutoPaperFetch(_ articleId: String) {
        let snapshot = articles
        let storage = storage
        Task.detached(priority: .utility) { [weak self] in
            let dedupKeysWithPDF = Self.paperDedupKeysForPapersWithPDF(in: snapshot)
            let finishedElsewhere = await storage.sourceIDsIngestedOnAnotherDevice()
            let unavailableIDs = Self.unavailableRecordedPaperPDFIDs(in: snapshot).union(finishedElsewhere)
            await self?.enqueueAutoPaperFetch(
                [articleId],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: unavailableIDs
            )
        }
    }

    /// True for a source that has never had its content fetched and can be
    /// fetched without asking the user first.
    ///
    /// Papers are excluded: `autoFetchNewlyAddedPapers` already covers them and
    /// knows about PDF resolution, paywalls, and duplicate detection, none of
    /// which the generic content path understands. Non-http sources are local
    /// documents read from disk, so there is nothing to fetch.
    ///
    /// `nonisolated` so the candidate scan can run off the main actor over a
    /// snapshot.
    nonisolated static func sourceNeedsInitialContentFetch(
        _ article: StudioArticle,
        alreadyAttempted: Set<String>
    ) -> Bool {
        // General failures remain manual retries. This narrow exception heals
        // rows stranded when the old archive path accepted Figshare's empty 202
        // WAF response and never reached its browser fallback.
        let isFigshareWAFRepair = article.state == .error
            && URL(string: article.url).flatMap(SourceService.figshareResource(from:)) != nil

        // An X post is only readable offline once its thread has been captured
        // to disk, and a bookmark arrives `.ready` with the post's text and no
        // capture at all. Those rows need the fetch as much as an empty one
        // does — that is what makes them survive an offline Mac or a Screen
        // Time block — so they qualify on a missing capture rather than on
        // missing text. The capture writes `localFilePath`, so a post that has
        // one is done.
        if article.sourceType == .xPost {
            return article.localFilePath?.isEmpty != false
                && article.state != .fetching
                && article.url.hasPrefix("http")
                && !alreadyAttempted.contains(article.id)
        }

        return (article.state == .queued || isFigshareWAFRepair)
            && article.sourceType != .paper
            && article.url.hasPrefix("http")
            && (article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !alreadyAttempted.contains(article.id)
    }

    /// Fetch content for sources that have never had any.
    ///
    /// A source is created `queued` and its content is fetched when the learner
    /// opens it. A source nobody opens is therefore never fetched, never
    /// embedded — `queueSourceEmbeddingRefreshIfReady` requires `.ready` — and
    /// so invisible to search and to the assistant, while still appearing in
    /// the library as though it were part of the knowledge base. 161 Safari
    /// articles had been sitting in exactly that state, the oldest for seven
    /// months. Ingesting a source should leave it readable without waiting for
    /// a click.
    ///
    /// Mirrors `autoFetchNewlyAddedPapers`: the full-library scan runs off the
    /// main actor over a snapshot, only the tiny enqueue hops back, and it is
    /// deferred until after launch by `loadQueue` so startup stays read-only
    /// and fast. It covers the existing backlog for the same reason the paper
    /// sweep does — a source added before this existed is no less invisible.
    func autoFetchUnfetchedSources() {
        let snapshot = articles
        let attempted = autoFetchAttemptedContentIDs
        Task.detached(priority: .utility) { [weak self] in
            let candidates = snapshot
                .filter { Self.sourceNeedsInitialContentFetch($0, alreadyAttempted: attempted) }
                .map(\.id)
            guard !candidates.isEmpty else { return }
            await self?.enqueueInitialContentFetch(candidates)
        }
    }

    /// Enqueue sources for their first content fetch. Re-validates against live
    /// state because the scan worked from a snapshot. Cheap main-actor work.
    func enqueueInitialContentFetch(_ articleIds: [String]) {
        var didEnqueue = false
        for id in articleIds {
            guard let article = articlesById[id],
                  Self.sourceNeedsInitialContentFetch(article, alreadyAttempted: autoFetchAttemptedContentIDs),
                  !autoFetchContentQueue.contains(id)
            else { continue }
            autoFetchContentQueue.append(id)
            didEnqueue = true
        }
        if didEnqueue { drainInitialContentFetchQueue() }
    }

    /// Drain one source at a time.
    ///
    /// Serial on purpose. This walks a backlog that can run to hundreds of URLs
    /// across many hosts, and firing them in parallel is how an app collects
    /// rate limits and blocks. Each id is marked attempted *before* the fetch,
    /// so a source that fails or hangs is not retried for the rest of the
    /// session; a real failure sets `.error` and leaves the candidate set for
    /// good.
    private func drainInitialContentFetchQueue() {
        guard !isDrainingInitialContentFetchQueue else { return }
        isDrainingInitialContentFetchQueue = true
        Task {
            while !autoFetchContentQueue.isEmpty {
                let articleId = autoFetchContentQueue.removeFirst()
                autoFetchAttemptedContentIDs.insert(articleId)
                await fetchContent(for: articleId)
            }
            isDrainingInitialContentFetchQueue = false
        }
    }

    /// True for a paper that has paper content but no durable LLM attestation and
    /// hasn't already been attempted this session. A title alone is never enough:
    /// the Paper Metadata task must receive PDF or full-text paper content.
    /// `nonisolated` so the candidate scan can run off the main actor over a snapshot.
    nonisolated static func paperNeedsAutoMetadataExtraction(
        _ article: StudioArticle,
        alreadyAttempted: Set<String>
    ) -> Bool {
        article.sourceType == .paper
            && article.requiresPaperMetadataAI
            && article.state != .fetching
            && !alreadyAttempted.contains(article.id)
            && (article.resolvedPDFPath != nil
                || !(article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    /// Sweep for papers that still show unknown metadata and enqueue a silent
    /// background AI extraction for each. Together with `autoFetchNewlyAddedPapers`
    /// this guarantees no paper is left with "Unknown authors" regardless of how it
    /// was added. Skipped entirely when no metadata API key is configured — we never
    /// fall back to heuristics. The full-library scan runs off the main actor over a
    /// snapshot so it never costs main-actor time; only the tiny enqueue hops back.
    /// Deferred until after launch so startup stays read-only and fast.
    func autoExtractMissingPaperMetadata() {
        let snapshot = articles
        let attempted = autoExtractMetadataAttemptedPaperIDs
        // Papers an earlier build failed over a blank field are healed with no
        // model call at all, so this half runs even with no metadata AI
        // configured and with an empty balance.
        let hasMetadataConfig = KeychainService.resolveConfig(for: .paperMetadata) != nil
        let storage = storage
        Task.detached(priority: .utility) { [weak self] in
            // The metadata gate was passed on the device that finished the paper; its record says so.
            var finishedElsewhere = Set<String>()
            if hasMetadataConfig { finishedElsewhere = await storage.sourceIDsIngestedOnAnotherDevice() }
            let healable = snapshot
                .filter(\.canAttestPaperIngestionAfterBlankMetadataFailure)
                .map(\.id)
            let candidates = hasMetadataConfig
                ? snapshot
                    .filter {
                        !finishedElsewhere.contains($0.id)
                            && Self.paperNeedsAutoMetadataExtraction($0, alreadyAttempted: attempted)
                    }
                    .map(\.id)
                : []
            guard !healable.isEmpty || !candidates.isEmpty else { return }
            // Heal first and let it commit: a healed paper drops out of the
            // extraction candidates when `enqueueAutoMetadataExtraction`
            // re-validates it against live state.
            await self?.attestPapersFailedOnBlankMetadata(healable)
            guard !candidates.isEmpty else { return }
            await self?.enqueueAutoMetadataExtraction(candidates)
        }
    }

    /// Promote papers whose only recorded problem was a bibliographic field the
    /// document does not print. The metadata stage already ran for these rows —
    /// see `canAttestPaperIngestionAfterBlankMetadataFailure` — so this spends
    /// nothing and simply stops presenting a readable paper as a failed ingestion.
    func attestPapersFailedOnBlankMetadata(_ articleIds: [String]) async {
        for id in articleIds {
            guard var article = articlesById[id] else { continue }
            guard article.attestPaperIngestionAfterBlankMetadataFailure() else { continue }
            guard await persistSource(
                article,
                context: "Attest paper ingestion after blank metadata",
                showErrorToast: false
            ) else { continue }
            if let idx = articles.firstIndex(where: { $0.id == id }) {
                articles[idx] = article
            }
            logger.info(
                "Attested paper ingestion for \(id): the extractor left \(article.missingRequiredPaperMetadataFields.joined(separator: ", ")) blank, which the document does not print"
            )
        }
    }

    /// Enqueue papers for automatic background AI metadata extraction, deduplicated
    /// per session so a paper is never auto-extracted twice. Re-validates against live
    /// state because the off-main scan worked from a snapshot. Cheap main-actor work.
    func enqueueAutoMetadataExtraction(_ articleIds: [String]) {
        var didEnqueue = false
        for id in articleIds {
            guard let article = articlesById[id],
                  Self.paperNeedsAutoMetadataExtraction(article, alreadyAttempted: autoExtractMetadataAttemptedPaperIDs)
            else { continue }
            autoExtractMetadataAttemptedPaperIDs.insert(id)
            autoExtractMetadataQueue.append(id)
            queuedPaperMetadataExtractionIds.insert(id)
            didEnqueue = true
        }
        if didEnqueue { drainAutoMetadataExtractionQueue() }
    }

    /// The next paper to work on from a background paper queue. The queues are
    /// filled by a library-wide sweep, so a paper the learner just filed in a
    /// notebook would otherwise wait behind every paper in the library, with a
    /// spinner on its row the whole time. Papers that belong to a notebook go
    /// first, in the order they were queued; the rest keep their order after them.
    private func takeNextAutoPaperID(from queue: inout [String]) -> String {
        let members = Set(notebooks.flatMap(\.approvedSourceIDs).map(canonicalSourceID))
        let index = queue.firstIndex { members.contains(canonicalSourceID($0)) } ?? 0
        return queue.remove(at: index)
    }

    /// Extract metadata for queued papers one at a time so we never run several AI
    /// calls concurrently. The loop only coordinates on the main actor; the AI
    /// request and PDF parsing happen off-main inside `extractPaperMetadataWithAI`.
    private func drainAutoMetadataExtractionQueue() {
        guard !isDrainingAutoExtractMetadataQueue else { return }
        isDrainingAutoExtractMetadataQueue = true
        Task {
            while !autoExtractMetadataQueue.isEmpty {
                let articleId = takeNextAutoPaperID(from: &autoExtractMetadataQueue)
                _ = await extractPaperMetadataWithAI(id: articleId, showToasts: false)
                queuedPaperMetadataExtractionIds.remove(articleId)
            }
            isDrainingAutoExtractMetadataQueue = false
        }
    }

    /// Resolve queued papers one at a time so we never run several downloads
    /// concurrently. Each paper goes through the same full pipeline as the manual
    /// "papers needing attention" pass — including the AI browser agent. This is an
    /// automatic background pass the user didn't ask for, so it stays silent: any
    /// download it lands is reflected in the Papers badge and list, and unresolved
    /// papers remain visible there. Only the user-initiated bulk pass
    /// (`runMissingPaperPDFDownload`) reports a toast. The loop only coordinates on
    /// the main actor; the actual download and PDF parsing happen off-main inside
    /// `downloadPaperPDF`'s `nonisolated` / `Task.detached` helpers, so the main
    /// actor stays free.
    private func drainAutoPaperFetchQueue() {
        guard !isDrainingAutoPaperFetchQueue else { return }
        isDrainingAutoPaperFetchQueue = true
        Task {
            while !autoFetchPaperQueue.isEmpty {
                // A manual bulk pass owns the same papers-needing-attention set.
                // Yield to it: drop the queue (these papers stay un-attempted, so a
                // later sweep re-enqueues any the bulk pass doesn't resolve).
                if isResolvingMissingPaperPDFs || missingPaperPDFDownloadTask != nil {
                    pendingPaperProcessingIds.subtract(autoFetchPaperQueue)
                    queuedPaperPDFResolutionIds.subtract(autoFetchPaperQueue)
                    autoFetchPaperQueue.removeAll()
                    break
                }
                let articleId = takeNextAutoPaperID(from: &autoFetchPaperQueue)
                _ = await autoResolveNewPaperPDF(for: articleId)
            }
            isDrainingAutoPaperFetchQueue = false
        }
    }

    /// Try downloading a paper PDF, resetting error state first.
    func tryPaperPDFDownload(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        resolvingPaperPDFIds.insert(articleId)
        defer { resolvingPaperPDFIds.remove(articleId) }
        // One paper the publisher's file and every open-access copy are held
        // to, so the message below can name each file that was not it.
        let identity = PaperPDFIdentityGate(article: articles[idx])

        articles[idx].state = .fetching
        articles[idx].errorMessage = nil
        isFetchingContent = true
        guard await persistSource(articles[idx], context: "Save paper download state") else {
            isFetchingContent = false
            return
        }

        let result = await downloadPaperPDF(for: articleId, identity: identity)
        if result.success {
            await extractPaperTitle(for: articleId)
            isFetchingContent = false
            return
        }
        // The PDF landed but the mandatory metadata model failed. Its explicit
        // error state is already persisted; do not discard/re-download the PDF.
        if paperHasLocalPDF(articleId) {
            isFetchingContent = false
            return
        }

        if await adoptOpenAccessAlternativeIfAvailable(for: articleId, identity: identity) {
            isFetchingContent = false
            return
        }

        // Download failed — set error state with debug log
        if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
            articles[idx2].state = .error
            let debugTrace = result.debugLog.joined(separator: "\n")
            let detail = result.lastError?.localizedDescription ?? "unknown error"
            articles[idx2].errorMessage = "PDF download failed: \(detail)\n\n--- Debug Log ---\n\(debugTrace)"
            PaperIngestionDiagnostics.recordFailure(
                sourceID: articleId,
                title: articles[idx2].title,
                message: articles[idx2].errorMessage ?? "PDF download failed: \(detail)"
            )
            logger.error("Paper PDF download debug log:\n\(debugTrace)")
            debugAlertMessage = debugTrace
            showDebugAlert = true
            await persistSource(articles[idx2], context: "Save the failed download")
        }
        isFetchingContent = false
    }

    /// Where a browser agent's PDF came from when WebKit named no address,
    /// so a file turned away names the agent rather than a temporary file.
    nonisolated static let paperBrowserAgentPDFOrigin = "a link the AI browser chose"

    /// Let the AI browser agent look for the paper's PDF and attach what it
    /// downloads. A resolution passes its `identity`, which the file is held
    /// to like every other candidate: a file that is some other paper comes
    /// back as `.failed`, so the row stays as it was and the batch counts the
    /// file among those it turned away. The learner's own **Try with AI
    /// Browser** passes none; the learner is there to answer the title check.
    func attemptPaperPDFDownloadWithAIBrowser(
        for articleId: String,
        config: AITaskConfig,
        showPaywallToast: Bool,
        identity: PaperPDFIdentityGate? = nil
    ) async -> PaperAIBrowserAttemptResult {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else {
            return .failed(SourceError.fetchFailed)
        }
        guard articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil,
              articles[idx].url.hasPrefix("http") else {
            return .failed(SourceError.fetchFailed)
        }

        let article = articles[idx]
        let service = SourceDiscovery.PaperAIBrowserDownloadService(aiService: aiService)
        let attemptID = UUID()
        activePaperBrowserTasks.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserServices.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserAttemptIDs[articleId] = attemptID
        activePaperBrowserServices[articleId] = service
        // The progress closure below publishes browser steps into paperDownloadStep.
        // Always clear it on exit: callers like autoResolveNewPaperPDF have no cleanup
        // of their own, and without this the last step (e.g. "Downloading PDF...")
        // stays in the sidebar forever after a failed automatic attempt.
        defer {
            if activePaperBrowserAttemptIDs[articleId] == attemptID {
                activePaperBrowserAttemptIDs.removeValue(forKey: articleId)
                activePaperBrowserServices.removeValue(forKey: articleId)
                activePaperBrowserTasks.removeValue(forKey: articleId)
                paperDownloadStep = ""
            }
        }
        do {
            // The task is stored in `activePaperBrowserTasks` (owned by self), so
            // both nested escaping closures must capture self weakly. Matching the
            // ownership at both levels avoids retaining the view model and satisfies
            // Swift's nested-capture ownership rules.
            let browserTask = Task<SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF, Error> { [weak self] in
                try Task.checkCancellation()
                let download = try await service.findAndDownloadPDF(
                    article: article,
                    config: config
                ) { [weak self] step in
                    guard self?.activePaperBrowserAttemptIDs[articleId] == attemptID else { return }
                    self?.paperDownloadStep = step
                }
                try Task.checkCancellation()
                return download
            }
            activePaperBrowserTasks[articleId] = browserTask
            let download = try await browserTask.value
            return try await attachPaperBrowserDownload(download, to: articleId, attemptID: attemptID, identity: identity)
        } catch is CancellationError {
            return .cancelled
        } catch SourceDiscovery.PaperAIBrowserDownloadService.BrowserAgentError.paywalled(let evidence) {
            logger.info("AI browser detected paywall evidence for \(articleId): \(evidence)")
            // A recheck starts with an existing marker. Leave that durable state
            // untouched instead of writing/syncing it again or showing a redundant
            // "marked paywalled" toast for every paper in the batch.
            if !article.hasPaywallMarker {
                await markPaywalled(articleId: articleId, evidence: evidence, showEvidenceToast: showPaywallToast)
            }
            return .paywalled
        } catch SourceDiscovery.PaperAIBrowserDownloadService.BrowserAgentError.likelyPaywalled(let reason) {
            logger.info("AI browser suspects a paywall for \(articleId): \(reason)")
            await recordPaywallSuspicion(articleId: articleId, reason: reason)
            return .suspectedPaywall(reason)
        } catch SourceDiscovery.PaperAIBrowserDownloadService.BrowserAgentError.notAPaper(let reason) {
            logger.info("AI browser found that \(articleId) is not a paper: \(reason)")
            await reclassifyPaperAsArticle(articleId: articleId, reason: reason)
            return .notAPaper(reason)
        } catch {
            logger.warning("AI browser paper download failed for \(articleId): \(error.localizedDescription)")
            return .failed(error)
        }
    }

    /// Attach the file the AI browser agent downloaded in attempt
    /// `attemptID`, then remove the temporary download whatever happened.
    /// `.cancelled` when the attempt was superseded, the paper already has a
    /// PDF, or the attachment was declined; throws when the file is the
    /// paper's supplementary material or, held to `identity`, another paper.
    func attachPaperBrowserDownload(
        _ download: SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF,
        to articleId: String,
        attemptID: UUID,
        identity: PaperPDFIdentityGate?
    ) async throws -> PaperAIBrowserAttemptResult {
        let file = download.file
        guard activePaperBrowserAttemptIDs[articleId] == attemptID,
              articles.first(where: { $0.id == articleId })?.resolvedPDFPath == nil else {
            await Self.removeItem(at: file.path)
            return .cancelled
        }
        // A paper's supplementary file is not the paper, whoever found the
        // link — and it often prints the paper's title and DOI.
        if let served = download.sourceURL, PaperService.isSupplementaryPDFURL(served.absoluteString) {
            await Self.removeItem(at: file.path)
            throw SourceError.paperIngestionFailed(
                "That file is the paper's supplementary material, not the paper."
            )
        }
        let attached: Bool
        do {
            attached = try await attachPDF(
                to: articleId,
                pdfURL: file,
                cancelsActiveDiscovery: false,
                expectedDiscoveryAttemptID: attemptID,
                identity: identity,
                downloadedFrom: download.sourceURL?.absoluteString ?? Self.paperBrowserAgentPDFOrigin
            )
        } catch {
            await Self.removeItem(at: file.path)
            throw error
        }
        await Self.removeItem(at: file.path)
        guard attached else { return .cancelled }
        await refreshArticles()
        return .downloaded
    }

    /// Use an AI-guided WKWebView session to look for an open-access PDF, then
    /// attach the downloaded file to the same paper source.
    func tryPaperPDFDownloadWithAIBrowser(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil,
              articles[idx].url.hasPrefix("http") else {
            showToast("This paper already has a PDF")
            return
        }
        guard let config = KeychainService.resolveConfig(for: .paperBrowserAgent) else {
            showToast(
                KeychainService.backgroundAIUnavailableMessage(for: .paperBrowserAgent)
                    ?? "Set an API key in Settings first"
            )
            return
        }

        resolvingPaperPDFIds.insert(articleId)
        defer { resolvingPaperPDFIds.remove(articleId) }

        isFetchingContent = true
        paperDownloadStep = "Starting AI browser..."
        defer {
            isFetchingContent = false
            paperDownloadStep = ""
        }

        let result = await attemptPaperPDFDownloadWithAIBrowser(
            for: articleId,
            config: config,
            showPaywallToast: true
        )
        if case .failed(let error) = result {
            showToast("AI browser could not find a PDF: \(error.localizedDescription)")
        }
        if case .suspectedPaywall(let reason) = result {
            showToast("Looks paywalled: \(reason) — Mark as Paywalled is on the paper's row.")
        }
        if case .notAPaper(let reason) = result {
            showToast("Moved to Articles: \(reason)")
        }
    }

    /// Durable exit from the paper pipeline for a page that is not a paper.
    /// Rewrites the source as an article, drops the paper-only state, persists
    /// and syncs it at once, and hands it to the article pipeline so it is
    /// fetched and prepared like any other web page. Returns false when the
    /// source is gone, already not a paper, or could not be saved.
    @discardableResult
    func reclassifyPaperAsArticle(articleId: String, reason: String) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper else { return false }
        pendingPaperProcessingIds.remove(articleId)
        queuedPaperPDFResolutionIds.remove(articleId)
        autoFetchPaperQueue.removeAll { $0 == articleId }
        paperProcessingSteps.removeValue(forKey: articleId)

        var updated = articles[idx]
        updated.convertPaperToArticle()
        logger.info("Reclassified paper as article: \(updated.title) — \(reason)")
        PaperIngestionDiagnostics.recordReclassifiedAsArticle(
            sourceID: articleId,
            title: updated.title,
            reason: reason
        )
        await storage.clearSourceDerivedData(articleId)
        guard await persistSource(updated, context: "Save source type", syncImmediately: true) else {
            return false
        }
        if let currentIndex = articles.firstIndex(where: { $0.id == articleId }) {
            articles[currentIndex] = updated
        }
        Task { [weak self] in
            await self?.fetchContent(for: articleId)
        }
        return true
    }

    /// Fetch the HTML page for a paper URL and try to extract the title.
    /// Updates the article's title in-place if a better one is found.
    /// For direct PDF URLs (arXiv, bioRxiv, etc.), converts to the abstract page first.
    func extractPaperTitle(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].url.hasPrefix("http") else { return }
        let url = articles[idx].url

        // Only bother if the title looks like a domain/URL/filename (not already set to something meaningful)
        guard Self.titleNeedsResolution(articles[idx].title, domain: articles[idx].domain, url: url) else { return }

        // Strategy 1: Fetch HTML from abstract/landing page and extract title from meta tags
        if let title = await PaperService.fetchPaperPageMetadata(at: url)?.title {
            await applyExtractedPaperTitle(title, to: articleId, source: "HTML")
            return
        }

        // Strategy 2: Extract title from the downloaded local PDF metadata / first-page text
        #if canImport(PDFKit)
        if let localPath = articles.first(where: { $0.id == articleId })?.localFilePath,
           let pdfTitle = await Self.extractPDFTitleOffMain(from: localPath) {
            await applyExtractedPaperTitle(pdfTitle, to: articleId, source: "PDF metadata")
            return
        }
        #endif

    }

    /// Re-resolves the article by id (the index captured before the network
    /// awaits above may be stale after a concurrent refresh), applies the title,
    /// and persists it.
    private func applyExtractedPaperTitle(_ title: String, to articleId: String, source: String) async {
        guard mutateArticle(id: articleId, { $0.title = title }),
              let current = articles.first(where: { $0.id == articleId }) else { return }
        if await persistSource(current, context: "Save paper title", showErrorToast: false) {
            logger.info("Extracted paper title from \(source): \(title)")
        }
    }

    // Keep title derivation available cross-platform.

    /// Filenames are identity-bearing structure, not human-authored title metadata.
    /// Leave resolution to the configured paper-metadata task.
    nonisolated static func titleFromPDFURL(_ urlString: String) -> String? {
        nil
    }

}

// MARK: - Supplementary material

/// A journal's supplementary file, joined to its paper: the supplement's pages
/// follow the article's own, in one PDF.
///
/// ForeverLM keeps one PDF per paper, and most journals ship supplementary
/// figures (and some ship Extended Data) as a separate file. A paper whose text
/// names "Supplementary Fig. 3" could not show it: 403 of the library's 474
/// papers that mention supplementary figures did not carry them (survey,
/// 2026-11-08). Appending the file is what Nature already does with Extended
/// Data, so everything that reads a paper's PDF — the figure index, the Reader,
/// search, chat — reads the supplement with no change of its own (product
/// owner, 2026-11-08: "it should be able to attach those at the end of the
/// current pdf or something").
///
/// The joined PDF is written to a new file beside the paper's, never over it.
/// Everything that keeps derived data for a paper notices a new path — the
/// figure index (`paperFigureIndexIsCurrent`), the search index
/// (`sourcesMissingIndex`) and the synced file, which another device fetches
/// only for a path it does not hold. The article's pages keep their numbers,
/// so highlights, reading positions and figure ids stay where they were. No
/// model reads the paper again: its metadata is the article's. Once the paper
/// points at the joined file, the file it replaced is removed unless another
/// source keeps it (`removeReplacedFile`).
enum PaperSupplementPDF {
    struct Outcome: Equatable, Sendable {
        /// The joined PDF, absolute.
        let path: String
        let articlePageCount: Int
        let addedPageCount: Int
    }

    enum Failure: LocalizedError, Equatable {
        case unreadablePaper
        case unreadableSupplement
        case emptySupplement
        /// The supplement's first page is already one of the paper's pages:
        /// it was attached before, or it is the article itself.
        case alreadyAttached
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadablePaper: "The paper's own PDF could not be read."
            case .unreadableSupplement: "The supplementary file is not a readable PDF."
            case .emptySupplement: "The supplementary PDF has no pages."
            case .alreadyAttached: "This PDF is already part of the paper: its first page is one of the paper's pages."
            case .writeFailed: "The joined PDF could not be written."
            }
        }
    }

    /// The suffix a joined PDF's file name carries, before any counter.
    static let fileSuffix = "-with-supplement"

    /// Join `supplementPath`'s pages after `paperPath`'s into a new file beside
    /// the paper's, and return it. The paper's file is left as it was.
    static func append(supplementAt supplementPath: String, toPaperAt paperPath: String) throws -> Outcome {
        guard let paper = PDFDocument(url: URL(fileURLWithPath: paperPath)), paper.pageCount > 0 else {
            throw Failure.unreadablePaper
        }
        guard let supplement = PDFDocument(url: URL(fileURLWithPath: supplementPath)) else {
            throw Failure.unreadableSupplement
        }
        guard supplement.pageCount > 0 else { throw Failure.emptySupplement }
        if holdsPage(paper, matching: supplement) { throw Failure.alreadyAttached }

        let articlePageCount = paper.pageCount
        for index in 0..<supplement.pageCount {
            guard let page = supplement.page(at: index)?.copy() as? PDFPage else { throw Failure.unreadableSupplement }
            paper.insert(page, at: paper.pageCount)
        }
        let fm = FileManager.default
        let destination = destinationPath(for: paperPath) { fm.fileExists(atPath: $0) }
        let destinationURL = URL(fileURLWithPath: destination)
        let staged = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).incoming-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        guard paper.write(to: staged),
              let written = PDFDocument(url: staged),
              written.pageCount == articlePageCount + supplement.pageCount else {
            throw Failure.writeFailed
        }
        do {
            try fm.moveItem(at: staged, to: destinationURL)
        } catch {
            throw Failure.writeFailed
        }
        return Outcome(path: destination, articlePageCount: articlePageCount, addedPageCount: supplement.pageCount)
    }

    /// Remove the paper's file the joined PDF replaced, once the paper points
    /// at the joined one. Only a file in the Papers folder that no other
    /// source keeps is removed: the copy on another device is that device's,
    /// and a file two rows share stays for the other. Returns whether it was
    /// removed.
    @discardableResult
    static func removeReplacedFile(storedPath: String, usedElsewhere: Bool) -> Bool {
        guard !usedElsewhere, StorageService.relativeSourcePath(storedPath).hasPrefix("Papers/") else { return false }
        return (try? FileManager.default.removeItem(atPath: StorageService.absoluteSourcePath(storedPath))) != nil
    }

    /// Where the joined PDF goes: beside the paper's file, named for it with
    /// `fileSuffix`, and a counter when a second supplement joins a paper that
    /// already has one ("x.pdf" → "x-with-supplement.pdf" →
    /// "x-with-supplement-2.pdf").
    static func destinationPath(for paperPath: String, fileExists: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: paperPath)
        let folder = url.deletingLastPathComponent()
        var base = url.deletingPathExtension().lastPathComponent
        if let range = base.range(of: #"-with-supplement(-\d+)?$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        var counter = 1
        while true {
            let name = base + fileSuffix + (counter == 1 ? "" : "-\(counter)") + ".pdf"
            let candidate = folder.appendingPathComponent(name).path
            if candidate != paperPath, !fileExists(candidate) { return candidate }
            counter += 1
        }
    }

    /// Whether `paper` already holds `supplement`'s first page, by its text.
    /// A page with too little text to tell (a scan, a cover with a logo) never
    /// matches, so such a supplement is attached rather than refused.
    static func holdsPage(_ paper: PDFDocument, matching supplement: PDFDocument) -> Bool {
        guard let first = supplement.page(at: 0).map({ normalizedPageText($0.string) }), first.count >= 80 else {
            return false
        }
        for index in 0..<paper.pageCount where normalizedPageText(paper.page(at: index)?.string) == first {
            return true
        }
        return false
    }

    static func normalizedPageText(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
