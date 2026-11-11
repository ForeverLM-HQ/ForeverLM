import Foundation
import CryptoKit
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
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
        if let usedElsewhere = await loggedRead("whether another source uses the replaced file", { try await storage.otherSourceUsesLocalFile(stored, excludingSourceID: articleId) }) {
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

}

