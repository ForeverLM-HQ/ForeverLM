// MCPDataStore: Plugin inbox and paper import from a URL.
import Foundation
import Network
import OSLog
import PDFKit

extension MCPDataStore {
    func normalizedPaperImportURL(_ rawURL: String) throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("url is required")
        }
        if trimmed.lowercased().hasPrefix("doi:") {
            return "https://doi.org/\(String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if trimmed.hasPrefix("10.") {
            return "https://doi.org/\(trimmed)"
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw MCPError.invalidInput("url must be an http(s) URL or DOI")
        }
        return trimmed
    }

    /// A plugin may stage a private PDF locally, but an ingest-scoped token
    /// must not be able to point the app at arbitrary PDFs elsewhere on disk.
    /// Each authenticated plugin therefore gets one private inbox under the
    /// app's local support directory. The plugin name comes from its OAuth
    /// registration and is already sanitized by MCPOAuthProvider.
    func pluginInboxURL(connectorLabel: String, create: Bool = true) throws -> URL {
        let base: URL
        if dbPathOverride != nil {
            base = URL(fileURLWithPath: knowledgeDBPath)
                .deletingLastPathComponent()
                .appendingPathComponent("ConnectorInbox", isDirectory: true)
        } else {
            base = localAppDataDir.appendingPathComponent("ConnectorInbox", isDirectory: true)
        }
        let label = MCPOAuthProvider.sanitizedPluginLabel(connectorLabel)
        let inbox = base.appendingPathComponent(Self.safeFilenameBase(label), isDirectory: true)
        if create {
            try FileManager.default.createDirectory(
                at: inbox,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
        }
        return inbox.standardizedFileURL.resolvingSymlinksInPath()
    }

    func getConnectorInbox(connectorLabel: String) throws -> String {
        let inbox = try pluginInboxURL(connectorLabel: connectorLabel)
        return try jsonString([
            "connector": MCPOAuthProvider.sanitizedPluginLabel(connectorLabel),
            "path": inbox.path,
            "max_file_bytes": Self.maxClientProvidedFileBytes,
        ] as [String: Any])
    }

    func validatePluginStagedPDF(_ rawPath: String, connectorLabel: String) throws -> URL {
        let candidate = try validateClientProvidedPath(rawPath)
        let inbox = try pluginInboxURL(connectorLabel: connectorLabel)
        guard candidate.path == inbox.path || candidate.path.hasPrefix(inbox.path + "/") else {
            throw MCPError.invalidInput(
                "file_path must be inside this plugin's staging directory. Call get_connector_inbox first."
            )
        }
        guard candidate.pathExtension.lowercased() == "pdf" else {
            throw MCPError.invalidInput("import_connector_paper accepts PDF files only.")
        }
        return candidate
    }

    /// Reject obvious local-network and machine-local targets before allowing an
    /// ingest plugin to ask ForeverLM to resolve a paper URL. Full-access
    /// assistants retain the historical import_paper_from_url behavior; this is
    /// the narrower plugin boundary. Redirects remain subject to URLSession's
    /// normal HTTP policy, while the Slack plugin itself only submits links it
    /// classified as academic papers.
    func validatePluginPaperURL(_ rawURL: String) throws -> String {
        let normalized = try normalizedPaperImportURL(rawURL)
        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw MCPError.invalidInput("url must be a public paper URL or DOI.")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw MCPError.invalidInput("Plugin paper URLs must use HTTPS.")
        }
        if let port = components.port, port != 443 {
            throw MCPError.invalidInput("Plugin paper URLs may use only the standard HTTPS port.")
        }
        let blockedNames = ["localhost", "localhost.localdomain"]
        guard !blockedNames.contains(host),
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else {
            throw MCPError.invalidInput("Plugin paper URLs must not target this Mac or a private network host.")
        }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            let blocked = bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || bytes[0] >= 224
            guard !blocked else {
                throw MCPError.invalidInput("Plugin paper URLs must not target a private or reserved IP address.")
            }
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            let isUnspecifiedOrLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && (bytes.last == 0 || bytes.last == 1)
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            guard !isUnspecifiedOrLoopback, !isUniqueLocal, !isLinkLocal else {
                throw MCPError.invalidInput("Plugin paper URLs must not target a private or reserved IP address.")
            }
        }
        let academicHosts = [
            "acm.org", "arxiv.org", "biorxiv.org", "cell.com", "doi.org",
            "ieee.org", "medrxiv.org", "nature.com", "openreview.net", "osf.io",
            "pubmed.ncbi.nlm.nih.gov", "science.org", "sciencedirect.com",
            "semanticscholar.org", "springer.com", "wiley.com", "zenodo.org",
        ]
        guard academicHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw MCPError.invalidInput(
                "Plugin URL imports are limited to recognized academic hosts. Download a direct PDF into get_connector_inbox and import it by file_path instead."
            )
        }
        return normalized
    }

    func importPluginPaper(
        url: String?,
        filePath: String?,
        sourceURL: String?,
        title: String?,
        connectorLabel: String
    ) async throws -> String {
        let remoteURL = Self.nilIfBlank(url ?? "")
        let localPath = Self.nilIfBlank(filePath ?? "")
        guard (remoteURL == nil) != (localPath == nil) else {
            throw MCPError.invalidInput("Supply exactly one of url or file_path.")
        }

        if let remoteURL {
            let safeURL = try validatePluginPaperURL(remoteURL)
            return try await importPaperFromURL(
                safeURL,
                title: title,
                connectorLabel: connectorLabel
            )
        }

        let staged = try validatePluginStagedPDF(localPath!, connectorLabel: connectorLabel)
        guard let canonicalURL = Self.httpURLString(sourceURL ?? ""),
              URL(string: canonicalURL)?.scheme?.lowercased() == "https" else {
            throw MCPError.invalidInput(
                "source_url is required for a staged PDF and must be its stable public HTTPS provenance URL."
            )
        }
        return try await importLocalPDFAsPaper(
            filePath: staged.path,
            title: title,
            canonicalURL: canonicalURL,
            connectorLabel: connectorLabel
        )
    }

    /// Imports a paper whose PDF is served at one address and whose identity is
    /// another — a Slack file's `download_url` and its permalink, for instance.
    ///
    /// The download address is transport, so it is never stored: the paper's
    /// canonical URL and dedup key is `sourceURL`, the same rule
    /// `import_connector_paper` applies to a staged PDF. The bytes are fetched
    /// through the importer's ordinary PDF download (which carries the managed
    /// session when the host is ForeverLM's own gateway), staged under the
    /// temporary directory, and filed by the local-PDF path so identity, dedup
    /// and the required metadata step are the ones every paper goes through.
    func importPaperFromDownloadURLOutcome(
        _ rawURL: String,
        sourceURL rawSourceURL: String,
        title: String?
    ) async throws -> PaperImportOutcome {
        switch try await stagePaperFromDownloadURL(rawURL, sourceURL: rawSourceURL, title: title) {
        case .settled(let outcome):
            return outcome
        case .staged(let staged):
            return try await finishStagedLocalPaper(staged)
        }
    }

    /// `importPaperFromDownloadURLOutcome` up to the models: the PDF
    /// downloaded, holding nothing, and staged as a local PDF
    /// (`stageLocalPDFAsPaper`), which saves it as a pending paper in a
    /// stretch of its own.
    func stagePaperFromDownloadURL(
        _ rawURL: String,
        sourceURL rawSourceURL: String,
        title: String?
    ) async throws -> LocalPaperStaging {
        let downloadURL = try normalizedPaperImportURL(rawURL)
        guard let canonicalURL = Self.httpURLString(rawSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPError.invalidInput(
                "source_url must be an http(s) URL: the file's stable provenance address, such as a Slack file permalink."
            )
        }
        let held = try await withStoreGate(.shared) { () -> (id: String, status: SourceStatus)? in
            let store = try knowledgeStore()
            guard let existing = store.sourceExistsByNormalizedURL(URLNormalizer.normalize(canonicalURL))
                    ?? store.sourceExistsByURL(canonicalURL),
                  let article = try store.loadSourceForSync(existing.id),
                  !Self.existingPaperTakesArrivingPDF(article) else { return nil }
            return (existing.id, existing.status)
        }
        if let held {
            return .settled(PaperImportOutcome(message: "Source already exists (id: \(held.id), status: \(held.status.rawValue))", sourceID: held.id))
        }

        let pdfURL = try await resolvedPDFURLForAttachment(downloadURL)
        let leaf = URL(string: pdfURL)?.deletingPathExtension().lastPathComponent
        let baseName = Self.safeFilenameBase(Self.nilIfBlank(leaf ?? "") ?? "paper")
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLM-paper-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let staged = stagingDir.appendingPathComponent(baseName).appendingPathExtension("pdf")
        try await downloadPaperPDFForImport(from: pdfURL, sourceURL: canonicalURL, to: staged)
        return try await stageLocalPDFAsPaper(filePath: staged.path, title: title, canonicalURL: canonicalURL)
    }

    func resolvedPaperPDFURL(
        sourceURL: String,
        pageMetadata: PaperService.PaperPageMetadata?,
        doi storedDOI: String? = nil
    ) async throws -> String {
        if let direct = PaperService.paperPDFURL(from: sourceURL) {
            return direct
        }

        // A PMC article is fetched from NCBI's own PDF route, whose
        // proof-of-work check `downloadPDF` answers. Europe PMC's render, which
        // the lookup returns, answers apps with 403.
        if let route = PaperService.ncbiPMCPDFURL(forArticleURL: sourceURL),
           PaperService.isNCBIPMCURL(sourceURL) {
            return route
        }

        if let pmcid = PaperService.extractPMCID(from: sourceURL),
           let pmcResult = await PaperService.lookupPMCByPMCID(pmcid: pmcid),
           let pdfURL = pmcResult.orderedPDFURLs.first {
            return pdfURL
        }

        if let pmid = PaperService.extractPMID(from: sourceURL),
           let pmcResult = await PaperService.lookupPMCByPMID(pmid: pmid),
           let pdfURL = pmcResult.orderedPDFURLs.first {
            return pdfURL
        }

        if let metaPDF = pageMetadata?.pdfURL,
           let resolved = Self.resolveURL(metaPDF, relativeTo: sourceURL) {
            return resolved
        }

        if let extracted = await PaperService.extractPDFURLFromWebPage(at: sourceURL) {
            return extracted
        }

        let doi = PaperService.openAccessLookupDOI(url: sourceURL, storedDOI: storedDOI)
            ?? PaperService.openAccessLookupDOI(url: "", storedDOI: pageMetadata?.doi)
        if let doi {
            if let pmcResult = await PaperService.lookupPMC(doi: doi), let pdfURL = pmcResult.orderedPDFURLs.first {
                return pdfURL
            }
            if let unpaywallURL = await PaperService.lookupUnpaywall(doi: doi) {
                return unpaywallURL
            }
        }

        throw PaperPDFUnavailableError(sourceURL: sourceURL)
    }

    func existingPaperByDOI(_ doi: String) throws -> (id: String, status: SourceStatus)? {
        let normalizedDOI = Self.normalizeDOI(doi)
        return try withDB { db in
            let rows = try query(
                db,
                "SELECT id, status FROM source_projection WHERE LOWER(doi) = ? LIMIT 1",
                params: [normalizedDOI.lowercased()]
            )
            guard let row = rows.first, let id = row["id"] as? String else { return nil }
            let status = (row["status"] as? String).flatMap { SourceStatus(rawValue: $0) } ?? .active
            return (id: id, status: status)
        }
    }

    func uniquePaperDestination(in papersDir: URL, doi: String?, url: String) -> URL {
        let filename = Self.preferredPaperFilename(doi: doi, url: url)
        var candidate = papersDir.appendingPathComponent(filename)
        let ext = candidate.pathExtension.isEmpty ? "pdf" : candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = papersDir
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    func cleanedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func fallbackPaperTitle(from sourceURL: String, pdfURL: String) -> String {
        let candidateURL = URL(string: sourceURL) ?? URL(string: pdfURL)
        let stem = candidateURL?.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stem, !stem.isEmpty, stem != "/" {
            return stem
        }
        return URL(string: sourceURL)?.host ?? "Imported Paper"
    }

    func titleNeedsReplacement(_ title: String, sourceURL: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasPrefix("http") { return true }
        if trimmed.lowercased().hasSuffix(".pdf") { return true }
        // Blank, the host's own name, a redirect page's "Redirecting", a bot
        // check's "Just a moment…": chrome a landing page wore, never a paper's
        // title. Four Elsevier DOIs were saved as "Redirecting" this way.
        if PaperService.isInterstitialPageTitle(trimmed, url: sourceURL) { return true }
        return false
    }

    /// The landing page's title when it is worth keeping: trimmed, and not a
    /// URL, a filename or an interstitial's. Nil otherwise, so a caller falls
    /// through to the next source rather than saving or searching by chrome.
    func usablePageTitle(_ title: String?, sourceURL: String) -> String? {
        guard let title = cleanedOptional(title), !titleNeedsReplacement(title, sourceURL: sourceURL) else {
            return nil
        }
        return title
    }

    static func preferredPaperFilename(doi: String?, url: String) -> String {
        let filename: String
        if let doi, !doi.isEmpty {
            filename = normalizeDOI(doi).replacingOccurrences(of: "/", with: "_") + ".pdf"
        } else if let parsed = URL(string: url), parsed.pathExtension.lowercased() == "pdf", !parsed.lastPathComponent.isEmpty {
            filename = parsed.lastPathComponent
        } else {
            let fallbackStem = url
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            filename = String(fallbackStem.prefix(80)) + ".pdf"
        }
        return sanitizeFilename(filename, fallback: "paper.pdf")
    }

    static func sanitizeFilename(_ filename: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = filename
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".pdf" else { return fallback }
        return cleaned.lowercased().hasSuffix(".pdf") ? cleaned : "\(cleaned).pdf"
    }

    static func resolveURL(_ value: String, relativeTo baseURLString: String) -> String? {
        guard let baseURL = URL(string: baseURLString) else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute.absoluteString
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    static func extractPDFTitle(from path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              let attrs = doc.documentAttributes,
              let title = attrs[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count < 300, !trimmed.lowercased().hasSuffix(".pdf") else {
            return nil
        }
        return trimmed
    }

    static func extractDOIFromPDF(at path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        if let attrs = doc.documentAttributes {
            for key in [PDFDocumentAttribute.subjectAttribute, PDFDocumentAttribute.keywordsAttribute] {
                if let value = attrs[key] as? String, let doi = extractDOIFromText(value) {
                    return doi
                }
            }
        }
        if let firstPageText = doc.page(at: 0)?.string, let doi = extractDOIFromText(firstPageText) {
            return doi
        }
        return nil
    }

    static func extractDOIFromText(_ text: String) -> String? {
        PaperService.firstPrintedDOI(in: text).map(normalizeDOI)
    }

    static func normalizeDOI(_ doi: String) -> String {
        var value = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"^https?://(?:dx\.)?doi\.org/"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"^doi:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        while value.hasSuffix(".") || value.hasSuffix(",") || value.hasSuffix(";") {
            value.removeLast()
        }
        return value
    }

    func recordPaperPDFIdentityMismatch(
        _ rejection: PaperPDFIdentityMismatchError,
        requestedURL: String,
        request: PaperPDFIdentity.Request,
        sourceID: String?
    ) {
        logger.warning(
            "Turned away the PDF at \(rejection.pdfURL, privacy: .public) for \(requestedURL, privacy: .public): \(rejection.reason, privacy: .public)"
        )
        PaperIngestionDiagnostics.recordPDFIdentityMismatch(
            sourceID: sourceID,
            requestedURL: requestedURL,
            requestedDOI: request.doi,
            pdfURL: rejection.pdfURL,
            reason: rejection.reason
        )
    }

    /// `paperHasPDF` is the existing paper's state when one is being rechecked;
    /// a paper that already has its file is never fetched again as the reader.
    func downloadPaperPDFForImport(
        from pdfURL: String,
        sourceURL: String,
        to destination: URL,
        label: String? = nil,
        paperHasPDF: Bool = false
    ) async throws {
        do {
            try await SourceService.shared.downloadPDF(from: pdfURL, to: destination.path)
        } catch {
            if ScienceDirectService.isScienceDirectURL(pdfURL) || ScienceDirectService.isScienceDirectURL(sourceURL) {
                try await ScienceDirectService.downloadPDFWithAuthenticatedWebSession(
                    from: pdfURL,
                    to: destination.path,
                    label: label
                )
                return
            }
            // The publisher answered ForeverLM's own client with a page while
            // the reader holds a session for the host: fetch the file as the
            // reader, so Recheck all recovers a paper the subscription covers.
            // See `WebSessionPDFDownload` for the gates.
            guard let url = URL(string: pdfURL) else { throw error }
            let readerCookies = await InAppWebSession.cookies(for: url)
            let decision = WebSessionPDFDownload.decision(
                pdfURL: pdfURL,
                after: error,
                cookies: readerCookies,
                paperHasPDF: paperHasPDF
            )
            guard decision == .attempt else { throw error }
            let data = try await WebSessionPDFDownloader.download(
                url,
                landingPage: URL(string: sourceURL) ?? WebSessionPDFDownloader.landingPageURL(forPDF: url)
            )
            try data.write(to: destination)
        }
    }

    /// The answer an import gives and the library source it produced or
    /// matched. The id is the one the import itself saved or found — never
    /// parsed back out of the answer — so a caller can file that source
    /// somewhere (`import_paper_from_url`'s notebook_id). Nil when the import
    /// ended with no row it can name.
    struct PaperImportOutcome: Sendable {
        let message: String
        let sourceID: String?
    }

    /// `import_paper_from_url` for a caller that wants the paper read before
    /// it answers (a connector's paper, a course's citations, a video's cited
    /// paper): staged with its PDF, then read by the models in the same call.
    /// A failure is saved on the paper, which keeps its PDF.
    func importPaperFromURLOutcome(
        _ rawURL: String,
        title titleOverride: String?,
        connectorLabel: String? = nil
    ) async throws -> PaperImportOutcome {
        switch try await stagePaperFromURL(rawURL, title: titleOverride, connectorLabel: connectorLabel) {
        case .settled(let outcome):
            return outcome
        case .staged(let staged):
            return try await finishStagedLocalPaper(staged)
        }
    }

    /// The half of a URL import that needs no model: the paper's PDF found and
    /// downloaded (the publisher's, then open-access copies, each held to the
    /// paper asked for), its text extracted and its bibliography looked up,
    /// then saved as a pending paper with its PDF, ready for
    /// `finishStagedLocalPaper`. A publisher that blocks the PDF leaves a
    /// paywalled paper, and a paper the library already holds by URL or DOI
    /// answers with its id (or, when it has no PDF, takes this one).
    ///
    /// The store is held only for each lookup and save, never across a
    /// download or a scholarly lookup. Holding it alone for
    /// the whole import, models included, would run several imports sent
    /// together one after another, queue every other call behind them, and
    /// time out the later clients. Imports run side by side, so the
    /// PDF is downloaded into a folder of its own and claimed in the Papers
    /// folder by the move that puts it there (`movePaperIntoPapersFolder`),
    /// and the library is asked again for the paper inside the stretch that
    /// saves it.
    func stagePaperFromURL(
        _ rawURL: String,
        title titleOverride: String?,
        connectorLabel: String? = nil
    ) async throws -> LocalPaperStaging {
        let sourceURL = try normalizedPaperImportURL(rawURL)
        let normalizedURL = URLNormalizer.normalize(sourceURL)
        if let existing = try await withStoreGate(.shared, { try existingSource(atPaperURL: sourceURL, normalizedURL: normalizedURL) }) {
            return .settled(PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id))
        }

        let pageMetadata = await PaperService.fetchPaperPageMetadata(at: sourceURL)
        var doi = (PaperService.extractDOI(from: sourceURL) ?? pageMetadata?.doi).map(Self.normalizeDOI)
        if let settled = try await existingPaperAnswer(doi: doi) {
            return .settled(settled)
        }

        let papersDir = sourceContentRoot.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papersDir, withIntermediateDirectories: true)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLM-paper-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let destination = stagingDir.appendingPathComponent(Self.preferredPaperFilename(doi: doi, url: sourceURL))

        // What was asked for, before any PDF speaks for itself. Every file
        // below is held to it (`PaperPDFIdentity`): an index can list another
        // paper's copy under this DOI, and once the Paper Metadata model has
        // read that copy it rewrites the bibliography to match, so a wrong
        // file has to be caught here or it passes for the paper.
        var identity = PaperPDFIdentity.Request(
            doi: doi,
            titles: [cleanedOptional(titleOverride), usablePageTitle(pageMetadata?.title, sourceURL: sourceURL)]
                .compactMap { $0 }
        )
        var rejectedPDFs: [PaperPDFIdentityMismatchError] = []
        /// Whether the file just written to `destination` is the paper asked
        /// for. Another paper's file is removed and recorded, and the caller
        /// goes on to its next candidate.
        func acceptsDownloadedPDF(from pdfURL: String) async -> Bool {
            let verdict = await PaperPDFIdentity.verdict(forPDFAt: destination, request: &identity)
            guard case .mismatch(let reason) = verdict else { return true }
            try? FileManager.default.removeItem(at: destination)
            let rejection = PaperPDFIdentityMismatchError(pdfURL: pdfURL, reason: reason)
            rejectedPDFs.append(rejection)
            recordPaperPDFIdentityMismatch(rejection, requestedURL: sourceURL, request: identity, sourceID: nil)
            return false
        }

        // Resolve and download the publisher's PDF, then fall back to open-access
        // copies. Resolution and download fail in the same paywall-shaped ways
        // (no PDF link anywhere, 401/402/403, an HTML page served instead of the
        // file), so the publisher's own failure is kept aside and classified
        // once every fallback has also come up empty.
        var downloadedPDFURL: String?
        var publisherError: Error?
        do {
            let resolved = try await resolvedPaperPDFURL(sourceURL: sourceURL, pageMetadata: pageMetadata)
            do {
                try await downloadPaperPDFForImport(from: resolved, sourceURL: sourceURL, to: destination)
                if await acceptsDownloadedPDF(from: resolved) {
                    downloadedPDFURL = resolved
                }
            } catch {
                publisherError = error
                try? FileManager.default.removeItem(at: destination)
                if sourceURL.lowercased().contains("doi.org/10.1101/"), resolved.contains("biorxiv.org") {
                    let medrxivURL = resolved.replacingOccurrences(of: "biorxiv.org", with: "medrxiv.org")
                    do {
                        try await downloadPaperPDFForImport(from: medrxivURL, sourceURL: sourceURL, to: destination)
                        if await acceptsDownloadedPDF(from: medrxivURL) {
                            downloadedPDFURL = medrxivURL
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
            }
        } catch {
            publisherError = error
        }

        var lastDownloadError = publisherError
        if downloadedPDFURL == nil {
            let alternatives = await PaperService.findOpenAccessAlternatives(
                url: sourceURL,
                title: cleanedOptional(titleOverride) ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL) ?? "",
                doi: doi
            )
            for alternative in alternatives {
                do {
                    let alternativePDFURL = try await resolvedPaperPDFURL(
                        sourceURL: alternative.replacementURL,
                        pageMetadata: nil
                    )
                    try await downloadPaperPDFForImport(
                        from: alternativePDFURL,
                        sourceURL: alternative.replacementURL,
                        to: destination
                    )
                    guard await acceptsDownloadedPDF(from: alternativePDFURL) else { continue }
                    downloadedPDFURL = alternativePDFURL
                    break
                } catch {
                    lastDownloadError = error
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }

        guard let pdfURL = downloadedPDFURL else {
            let failure = lastDownloadError ?? PaperPDFUnavailableError(sourceURL: sourceURL)
            // The publisher blocking the PDF is not a reason to lose the paper.
            // Studio keeps a paper whose download hits a paywall as a paywalled
            // row, and the bulk download pass marks one the same way; the URL
            // import must not be the one path that throws and saves nothing:
            // the assistant would tell the learner the paper "wasn't added"
            // even though every recovery path here works from a saved row. A file
            // turned away as another paper counts as no PDF of this one, and
            // the evidence names it.
            let evidence = (publisherError.flatMap(Self.paperPaywallEvidence(for:))
                ?? Self.paperPaywallEvidence(for: failure))
                .map { Self.paperPaywallEvidence($0, rejecting: rejectedPDFs) }
            if let evidence {
                let scholarlyMetadata = await PaperService.fetchPaperMetadata(
                    url: sourceURL,
                    title: cleanedOptional(titleOverride) ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL) ?? "",
                    doi: doi
                )
                if doi == nil, let metaDOI = scholarlyMetadata?.doi {
                    doi = Self.normalizeDOI(metaDOI)
                }
                let paywalledDOI = doi
                // Asked again where the row is saved: another call may have
                // brought the paper in while this one looked for its PDF.
                let saved = try await withStoreGate(.exclusive) { () -> PaperImportOutcome? in
                    if let existing = try existingSource(atPaperURL: sourceURL, normalizedURL: normalizedURL) {
                        return PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                    }
                    if let paywalledDOI, let existing = try existingPaperByDOI(paywalledDOI) {
                        return PaperImportOutcome(message: "Paper already exists for DOI \(paywalledDOI) (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                    }
                    guard let message = try savePaywalledPaperImport(
                        sourceURL: sourceURL,
                        normalizedURL: normalizedURL,
                        titleOverride: titleOverride,
                        pageMetadata: pageMetadata,
                        scholarlyMetadata: scholarlyMetadata,
                        doi: paywalledDOI,
                        evidence: evidence,
                        connectorLabel: connectorLabel
                    ) else { return nil }
                    // Saved under the address it was asked for, which is how
                    // its row is found again.
                    return PaperImportOutcome(message: message, sourceID: try knowledgeStore().sourceExistsByNormalizedURL(normalizedURL)?.id)
                }
                if let saved {
                    return .settled(saved)
                }
            }
            throw failure
        }
        if doi == nil {
            doi = PaperService.extractDOI(from: pdfURL).map(Self.normalizeDOI)
        }
        if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
            return .settled(settled)
        }

        guard SourceService.canOpenPDF(at: destination.path) else {
            throw SourceError.pdfReadFailed
        }

        let pdfText = try SourceService.shared.extractTextFromPDF(at: destination.path)
        if doi == nil {
            doi = Self.extractDOIFromPDF(at: destination.path) ?? Self.extractDOIFromText(pdfText)
        }
        if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
            return .settled(settled)
        }

        var resolvedTitle = cleanedOptional(titleOverride)
            ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL)
            ?? Self.extractPDFTitle(from: destination.path)
            ?? fallbackPaperTitle(from: sourceURL, pdfURL: pdfURL)

        var metadata = await PaperService.fetchPaperMetadata(url: sourceURL, title: resolvedTitle, doi: doi)
        if let metaTitle = metadata?.title, titleNeedsReplacement(resolvedTitle, sourceURL: sourceURL) {
            resolvedTitle = metaTitle
        }
        if doi == nil {
            doi = metadata?.doi.map(Self.normalizeDOI)
        }
        if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
            return .settled(settled)
        }

        if metadata == nil, let pageTitle = usablePageTitle(pageMetadata?.title, sourceURL: sourceURL), pageTitle != resolvedTitle {
            metadata = await PaperService.fetchPaperMetadata(url: sourceURL, title: pageTitle, doi: doi)
        }
        if doi == nil, let metaDOI = metadata?.doi {
            doi = Self.normalizeDOI(metaDOI)
            if let settled = try await settleDownloadedPDFForExistingPaper(doi: doi, pdf: destination, pdfURL: pdfURL) {
                return .settled(settled)
            }
        }

        let paperPDF = try movePaperIntoPapersFolder(destination, papersDir: papersDir, doi: doi, sourceURL: sourceURL)
        let host = URL(string: sourceURL)?.host ?? "Paper"
        var article = StudioArticle(
            url: sourceURL,
            title: resolvedTitle,
            sourceType: .paper,
            discoveryOrigin: connectorLabel == nil ? .manual : .plugin,
            localFilePath: relativeSourceContentPath(paperPDF) ?? StorageService.relativeSourcePath(paperPDF.path),
            author: pageMetadata?.authorsDisplay ?? metadata?.authorsDisplay ?? StudioArticle.unknownPaperAuthor,
            journal: pageMetadata?.journal ?? metadata?.journal ?? StudioArticle.unknownPaperJournal,
            publishedYear: pageMetadata?.year ?? metadata?.year ?? StudioArticle.unknownPaperYear
        )
        article.normalizedURL = normalizedURL
        article.connectorLabel = connectorLabel
        article.domain = host
        article.content = pdfText
        article.wordCount = pdfText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.prepareForPaperMetadataExtraction()
        article.doi = doi ?? metadata?.doi.map(Self.normalizeDOI)
        article.isPaywalled = false
        // Scholarly APIs provide context, but every successful paper import must
        // read the paper itself with the configured Paper Metadata model.
        let firstPageText = PDFDocument(url: paperPDF)?.page(at: 0)?.string ?? ""

        let pending = article
        let settled: PaperImportOutcome?
        do {
            settled = try await withStoreGate(.exclusive) { () -> PaperImportOutcome? in
                // Another call may have brought in the same paper while this
                // one downloaded and read it.
                if let existing = try existingSource(atPaperURL: sourceURL, normalizedURL: normalizedURL) {
                    return PaperImportOutcome(message: "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
                }
                if let settled = try await settleDownloadedPDFForExistingPaper(doi: pending.doi, pdf: paperPDF, pdfURL: pdfURL) {
                    return settled
                }
                try knowledgeStore().saveSource(pending)
                return nil
            }
        } catch {
            try? FileManager.default.removeItem(at: paperPDF)
            throw error
        }
        if let settled {
            try? FileManager.default.removeItem(at: paperPDF)
            return .settled(settled)
        }
        return .staged(StagedLocalPaper(
            article: article,
            destination: paperPDF,
            firstPageText: firstPageText,
            marks: "",
            downloadedFrom: pdfURL
        ))
    }

    /// The library's source at a paper's address, by its normalized URL or
    /// the URL as given. Read inside a store stretch.
    private func existingSource(atPaperURL sourceURL: String, normalizedURL: String) throws -> (id: String, status: SourceStatus)? {
        let store = try knowledgeStore()
        guard let existing = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(sourceURL) else {
            return nil
        }
        return (existing.id, existing.status)
    }

    /// "Paper already exists" for a DOI the library holds; nil when it holds
    /// none (or there is no DOI). Reads in a shared stretch of its own.
    private func existingPaperAnswer(doi: String?) async throws -> PaperImportOutcome? {
        guard let doi, let existing = try await withStoreGate(.shared, { try existingPaperByDOI(doi) }) else {
            return nil
        }
        return PaperImportOutcome(message: "Paper already exists for DOI \(doi) (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
    }

    /// What became of a downloaded PDF whose DOI the library already holds: a
    /// paper listed without a PDF (paywalled, or its file gone) takes a copy
    /// of it (`adoptPDFForExistingPaper`, which reads it with the Paper
    /// Metadata model as attach_pdf_to_paper does, holding the store alone),
    /// any other answers that it already exists. Nil when the DOI is new, found
    /// in a shared stretch so a new paper never waits for the store alone. The
    /// caller removes its own file.
    private func settleDownloadedPDFForExistingPaper(doi: String?, pdf: URL, pdfURL: String) async throws -> PaperImportOutcome? {
        guard let doi, try await withStoreGate(.shared, { try existingPaperByDOI(doi) }) != nil else { return nil }
        return try await withStoreGate(.exclusive) { () -> PaperImportOutcome? in
            guard let existing = try existingPaperByDOI(doi) else { return nil }
            let adopted = try await adoptPDFForExistingPaper(id: existing.id, stagedPDF: pdf, attachedFrom: pdfURL)
            return PaperImportOutcome(message: adopted ?? "Paper already exists for DOI \(doi) (id: \(existing.id), status: \(existing.status.rawValue))", sourceID: existing.id)
        }
    }

    /// Moves a downloaded PDF into the Papers folder under the paper's own
    /// name (`preferredPaperFilename`), or that name numbered when it is
    /// taken. URL imports run side by side, so the name is claimed by the move
    /// itself, which never overwrites, rather than by a look beforehand: two
    /// papers whose links both end in `fulltext.pdf` would otherwise be
    /// written to the same file.
    func movePaperIntoPapersFolder(_ downloaded: URL, papersDir: URL, doi: String?, sourceURL: String) throws -> URL {
        var lastError: Error?
        for _ in 0..<20 {
            let candidate = uniquePaperDestination(in: papersDir, doi: doi, url: sourceURL)
            do {
                try FileManager.default.moveItem(at: downloaded, to: candidate)
                return candidate
            } catch {
                // Taken between the look and the move: the next free name.
                guard FileManager.default.fileExists(atPath: candidate.path) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? SourceError.pdfReadFailed
    }

    /// `importPaperFromURLOutcome`'s answer alone.
    func importPaperFromURL(
        _ rawURL: String,
        title titleOverride: String?,
        connectorLabel: String? = nil
    ) async throws -> String {
        try await importPaperFromURLOutcome(rawURL, title: titleOverride, connectorLabel: connectorLabel).message
    }

    /// Save a paper whose PDF the publisher blocks as the paywalled row Studio
    /// would have kept: the paper itself, with whatever bibliography the landing
    /// page and the scholarly APIs gave, marked paywalled with the same state
    /// `set_source_paywall_status` writes. No PDF and no text are stored, so the
    /// row is exactly what `attach_pdf_to_paper`, a PDF dropped into the Papers
    /// folder, and `recheck_paywalled_papers` all know how to finish.
    ///
    /// Returns nil when nothing identifies the page as a paper at all: no DOI,
    /// no citation metadata on the page, and no scholarly record. Saving that
    /// as a paywalled paper would file an arbitrary web page under Papers, so
    /// the caller reports the download failure instead.
    func savePaywalledPaperImport(
        sourceURL: String,
        normalizedURL: String,
        titleOverride: String?,
        pageMetadata: PaperService.PaperPageMetadata?,
        scholarlyMetadata: PaperService.CrossrefMetadata?,
        doi: String?,
        evidence: String,
        connectorLabel: String?
    ) throws -> String? {
        guard doi != nil || pageMetadata != nil || scholarlyMetadata != nil else { return nil }
        let store = try knowledgeStore()

        // The scholarly record is keyed by the DOI, so its title is the paper's.
        // The landing page's is whatever the publisher served instead of the
        // PDF — for an Elsevier DOI, linkinghub's "Redirecting" page — so it
        // stands in only when no record was found, and never when it is an
        // interstitial's.
        var resolvedTitle = cleanedOptional(titleOverride)
            ?? cleanedOptional(scholarlyMetadata?.title)
            ?? usablePageTitle(pageMetadata?.title, sourceURL: sourceURL)
            ?? fallbackPaperTitle(from: sourceURL, pdfURL: sourceURL)
        if let metaTitle = cleanedOptional(scholarlyMetadata?.title),
           titleNeedsReplacement(resolvedTitle, sourceURL: sourceURL) {
            resolvedTitle = metaTitle
        }

        var article = StudioArticle(
            url: sourceURL,
            title: resolvedTitle,
            sourceType: .paper,
            discoveryOrigin: connectorLabel == nil ? .manual : .plugin,
            author: cleanedOptional(pageMetadata?.authorsDisplay)
                ?? cleanedOptional(scholarlyMetadata?.authorsDisplay)
                ?? StudioArticle.unknownPaperAuthor,
            journal: cleanedOptional(pageMetadata?.journal)
                ?? cleanedOptional(scholarlyMetadata?.journal)
                ?? StudioArticle.unknownPaperJournal,
            publishedYear: cleanedOptional(pageMetadata?.year)
                ?? cleanedOptional(scholarlyMetadata?.year)
                ?? StudioArticle.unknownPaperYear
        )
        article.normalizedURL = normalizedURL
        article.connectorLabel = connectorLabel
        article.domain = URL(string: sourceURL)?.host ?? "Paper"
        article.doi = doi.map(Self.normalizeDOI)
        // Mirrors setSourcePaywallStatus(isPaywalled: true) for a paper.
        article.state = .error
        article.statusFlag = .paywall
        article.isPaywalled = true
        try store.saveSource(article)

        let metadataSummary = [
            article.author.map { "author: \($0)" },
            article.journal.map { "journal: \($0)" },
            article.publishedYear.map { "year: \($0)" },
            article.doi.map { "doi: \($0)" },
        ].compactMap { $0 }.joined(separator: ", ")
        return "Added paper '\(article.title)' (id: \(article.id)) and marked it paywalled: \(evidence). "
            + "Its bibliography is saved (\(metadataSummary)) but no PDF or full text yet. "
            + "To finish it: call attach_pdf_to_paper with a local PDF path (or a PDF URL you can reach), "
            + "drop the PDF into the ForeverLM/Papers folder in iCloud Drive, "
            + "or call recheck_paywalled_papers later to look for a legitimate free copy."
    }

    /// An author handed to a source-writing tool must be a name
    /// (`SourceAuthor`). The field would drop markup or a web address on its
    /// own; a tool says so instead, so the caller learns the value was not kept.
    static func requirePlausibleSourceAuthor(_ author: String?) throws {
        guard let author, !SourceAuthor.isPlausible(author) else { return }
        let shown = author.count > 80 ? "\(author.prefix(80))…" : author
        throw MCPError.invalidInput(
            "author must be a name or a list of names — not markup, a web address or a paragraph (got \"\(shown)\")."
        )
    }
}
