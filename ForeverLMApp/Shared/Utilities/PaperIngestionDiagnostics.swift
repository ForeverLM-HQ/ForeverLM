import Foundation
import OSLog

/// A durable, user-visible companion to the unified log for paper ingestion.
/// Unified logs are difficult to retrieve on managed Macs and can disappear
/// across debugger sessions, so every failed attempt is mirrored to a bounded
/// file without ever performing file I/O on the main actor.
enum PaperIngestionDiagnostics {
    private static let writer = Writer()

    static func recordDropAccepted(filename: String) {
        Task(priority: .utility) {
            await writer.append("DROP_ACCEPTED filename=\(quoted(filename))")
        }
    }

    static func recordDropImported(filename: String, sourceID: String) {
        Task(priority: .utility) {
            await writer.append(
                "DROP_IMPORTED filename=\(quoted(filename)) source_id=\(quoted(sourceID))"
            )
        }
    }

    static func recordDropFailure(filename: String, message: String) {
        Task(priority: .utility) {
            await writer.append(
                "DROP_FAILED filename=\(quoted(filename)) error=\(quoted(message))"
            )
        }
    }

    static func recordAttempt(
        sourceID: String,
        provider: String,
        attempt: Int,
        maximumAttempts: Int,
        message: String
    ) {
        Task(priority: .utility) {
            await writer.append(
                "ATTEMPT_FAILED source_id=\(quoted(sourceID)) provider=\(quoted(provider)) "
                    + "attempt=\(attempt)/\(maximumAttempts) error=\(quoted(message))"
            )
        }
    }

    static func recordReclassifiedAsArticle(
        sourceID: String,
        title: String,
        reason: String
    ) {
        Task(priority: .utility) {
            await writer.append(
                "RECLASSIFIED_ARTICLE source_id=\(quoted(sourceID)) title=\(quoted(title)) "
                    + "reason=\(quoted(reason))"
            )
        }
    }

    /// A paper's stored text turned out to be the publisher's access wall or
    /// its front matter rather than the paper, and was dropped so the row asks
    /// for the PDF again and the reader shows the publisher's page.
    static func recordDiscardedWallText(
        sourceID: String,
        title: String,
        wordCount: Int
    ) {
        Task(priority: .utility) {
            await writer.append(
                "WALL_TEXT_DISCARDED source_id=\(quoted(sourceID)) title=\(quoted(title)) "
                    + "words=\(wordCount)"
            )
        }
    }

    /// The publisher's page, read with the learner's own session, was printed
    /// to a PDF because the publisher served the text but not the file.
    static func recordRenderedPublisherPagePDF(
        sourceID: String,
        title: String,
        pageCount: Int
    ) {
        Task(priority: .utility) {
            await writer.append(
                "PDF_RENDERED_FROM_PAGE source_id=\(quoted(sourceID)) title=\(quoted(title)) "
                    + "pages=\(pageCount)"
            )
        }
    }

    /// The publisher refused the app's own client and the file came through
    /// the reader's web session instead (`WebSessionPDFDownloader`).
    static func recordWebSessionPDFDownload(
        sourceID: String,
        title: String,
        url: String
    ) {
        Task(priority: .utility) {
            await writer.append(
                "PDF_FROM_READER_SESSION source_id=\(quoted(sourceID)) title=\(quoted(title)) "
                    + "url=\(quoted(url))"
            )
        }
    }

    /// A PDF offered for a paper was some other paper (`PaperPDFIdentity`)
    /// and was turned away before the metadata model could read it. A URL
    /// import has no source id yet when it turns a file away.
    static func recordPDFIdentityMismatch(
        sourceID: String?,
        requestedURL: String,
        requestedDOI: String?,
        pdfURL: String,
        reason: String
    ) {
        var line = "PDF_IDENTITY_MISMATCH"
        if let sourceID { line += " source_id=\(quoted(sourceID))" }
        line += " url=\(quoted(requestedURL))"
        if let requestedDOI { line += " doi=\(quoted(requestedDOI))" }
        line += " pdf_url=\(quoted(pdfURL)) reason=\(quoted(reason))"
        Task(priority: .utility) { [line] in
            await writer.append(line)
        }
    }

    static func recordFailure(
        sourceID: String,
        title: String,
        message: String
    ) {
        Task(priority: .utility) {
            await writer.append(
                "INGESTION_FAILED source_id=\(quoted(sourceID)) title=\(quoted(title)) "
                    + "error=\(quoted(message))"
            )
        }
    }

    /// Records the currently displayed failure before returning the log URL.
    /// This makes Show Log useful for failures persisted by an older app build,
    /// not just failures that occurred after file logging was introduced.
    static func logURLRecordingCurrentFailure(
        sourceID: String,
        title: String,
        message: String
    ) async -> URL? {
        await writer.append(
            "DISPLAYED_FAILURE source_id=\(quoted(sourceID)) title=\(quoted(title)) "
                + "error=\(quoted(message))"
        )
        return await writer.logURL()
    }

    private static func quoted(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(flattened)\""
    }

    private actor Writer {
        private static let maxLogBytes = 2_000_000
        private let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
            category: "PaperIngestion"
        )
        private let formatter = KnowledgeStore.iso8601Formatter

        func append(_ line: String) {
            do {
                let url = try preparedLogURL()
                let entry = "\(formatter.string(from: Date())) \(line)\n"
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(entry.utf8))
                } else {
                    try Data(entry.utf8).write(to: url, options: .atomic)
                }
            } catch {
                logger.error(
                    "Could not write paper-ingestion diagnostics: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        func logURL() -> URL? {
            do {
                return try preparedLogURL()
            } catch {
                logger.error(
                    "Could not prepare paper-ingestion diagnostics: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        private func preparedLogURL() throws -> URL {
            let directory = ForeverLMRuntimeIdentity.diagnosticsRootURL
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("paper-ingestion-log.txt")
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > Self.maxLogBytes {
                let previous = directory.appendingPathComponent("paper-ingestion-log.previous.txt")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: url, to: previous)
            }
            return url
        }
    }
}

/// Owns the bytes supplied by an `NSItemProvider` before the provider revokes
/// its temporary URL. Data writes and cleanup stay on a detached executor, and
/// the original filename is retained so a successful import never becomes a
/// permanent `ForeverLM-Dropped-<UUID>.pdf` source.
enum PaperDropStager {
    struct StagedFile: Sendable {
        let url: URL
        let displayName: String
        fileprivate let directoryURL: URL
    }

    static func stage(data: Data, suggestedName: String?) async throws -> StagedFile {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
                "ForeverLM-Paper-Drop-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            do {
                var displayName = safePDFFilename(suggestedName)
                var url = directoryURL.appendingPathComponent(displayName, isDirectory: false)
                try data.write(to: url, options: .atomic)
                // A browser download shelf or a mail attachment hands over the
                // bytes with no filename. Rather than file every such paper as
                // "Dropped Paper", name it after the title the PDF carries when
                // that title is a real one and not a typesetter's job tag.
                if suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   let embeddedTitle = StudioViewModel.extractPDFTitle(from: url.path) {
                    let titledName = safePDFFilename(embeddedTitle)
                    let titledURL = directoryURL.appendingPathComponent(titledName, isDirectory: false)
                    if titledURL != url, (try? fileManager.moveItem(at: url, to: titledURL)) != nil {
                        displayName = titledName
                        url = titledURL
                    }
                }
                return StagedFile(
                    url: url,
                    displayName: displayName,
                    directoryURL: directoryURL
                )
            } catch {
                try? fileManager.removeItem(at: directoryURL)
                throw error
            }
        }.value
    }

    static func cleanup(_ stagedFile: StagedFile) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: stagedFile.directoryURL)
        }
    }

    nonisolated static func safePDFFilename(_ suggestedName: String?) -> String {
        let rawName = suggestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = rawName.map { ($0 as NSString).lastPathComponent }
        let base = lastComponent?
            .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive, .anchored, .backwards])
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableBase = base?.isEmpty == false ? String(base!.prefix(180)) : "Dropped Paper"
        return "\(usableBase).pdf"
    }
}
