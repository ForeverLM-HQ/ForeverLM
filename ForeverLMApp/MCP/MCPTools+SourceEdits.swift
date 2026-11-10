// MCPDataStore: Video transcripts, archive fetches, source actions and source updates.
import CryptoKit
import Foundation
import ImageIO
import Network
import OSLog
import PDFKit
import SQLite3

extension MCPDataStore {
    /// A download (YouTube, a Zoom recording) holds no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the source is checked, and a transcript
    /// already stored marked ready, in one short stretch held alone, and what a
    /// download brought is saved in another.
    func fetchVideoTranscript(sourceID: String, passcode: String? = nil) async throws -> String {
        enum Start {
            case notFound
            case cached(StudioArticle)
            case download(StudioArticle)
        }
        let start: Start = try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            guard var article = try store.loadSourceForSync(sourceID) else {
                return .notFound
            }
            let isZoom = ZoomRecordingService.isZoomRecordingURL(article.url)
            // A Zoom recording is a meeting session; the gateway's transcript
            // nudge and an assistant's retry both reach it through this tool.
            guard article.sourceType == .video || (article.sourceType == .meeting && isZoom) else {
                throw MCPError.invalidInput("fetch_video_transcript requires a video source or a Zoom meeting session.")
            }
            guard YouTubeTranscriptService.isYouTubeURL(article.url) || isZoom || TeachableCourseService.isLectureURL(article.url) else {
                throw MCPError.invalidInput("fetch_video_transcript currently supports YouTube URLs, Zoom recording links and Teachable lectures.")
            }

            if let cachedTranscript = try store.loadSourceContent(sourceID),
               !cachedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                article.content = cachedTranscript
                article.wordCount = cachedTranscript.split(separator: " ").count
                article.state = .ready
                article.errorMessage = nil
                try store.saveSource(article)
                return .cached(article)
            }
            return .download(article)
        }
        let article: StudioArticle
        switch start {
        case .notFound:
            throw MCPError.notFound("Source not found: \(sourceID)")
        case .cached(let cached):
            return "Transcript already cached for '\(cached.title)' (\(cached.wordCount ?? 0) words)"
        case .download(let found):
            article = found
        }
        let isZoom = ZoomRecordingService.isZoomRecordingURL(article.url)
        let isTeachable = TeachableCourseService.isLectureURL(article.url)

        if isTeachable {
            let workID = try await MainActor.run { try Self.startTeachableTranscript(sourceID: sourceID) }
            return "Transcribing '\(article.title)' from its audio in ForeverLM (work_id: \(workID); cancel_ai_work stops it). This takes a few minutes; call fetch_video_transcript or get_source_content again for the transcript. If the source shows an error instead, it names the cause — most often that the learner must sign in to the school in ForeverLM's browser."
        }

        if isZoom {
            let trimmedPasscode = passcode?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suppliedPasscode = trimmedPasscode.flatMap { $0.isEmpty ? nil : $0 }
            let savedPasscode: String?
            if suppliedPasscode == nil {
                savedPasscode = await Task.detached(priority: .userInitiated) {
                    KeychainService.zoomRecordingPasscode(forSourceID: sourceID)
                }.value
            } else {
                savedPasscode = nil
            }

            let result: ZoomRecordingService.RecordingTranscript
            do {
                result = try await ZoomRecordingService.shared.fetchTranscript(
                    from: article.url,
                    passcode: suppliedPasscode ?? savedPasscode
                )
            } catch ZoomRecordingService.ZoomRecordingError.passcodeRequired {
                throw MCPError.invalidInput(
                    "This Zoom recording requires a passcode. Ask the user for the recording passcode and call fetch_video_transcript again with the passcode argument."
                )
            } catch {
                if savedPasscode != nil,
                   case ZoomRecordingService.ZoomRecordingError.wrongPasscode = error {
                    _ = await Task.detached(priority: .utility) {
                        KeychainService.deleteZoomRecordingPasscode(forSourceID: sourceID)
                    }.value
                }
                throw error
            }
            let passcodeSaved: Bool?
            if let suppliedPasscode {
                passcodeSaved = await Task.detached(priority: .utility) {
                    KeychainService.saveZoomRecordingPasscode(suppliedPasscode, forSourceID: sourceID)
                }.value
            } else {
                passcodeSaved = nil
            }
            let saved = try await saveSourceAfterWait(sourceID) { stored in
                if let topic = result.topic, !topic.isEmpty {
                    stored.title = topic
                }
                stored.content = result.transcript
                stored.wordCount = result.transcript.split(separator: " ").count
                stored.state = .ready
                stored.errorMessage = nil
                return true
            }
            let keychainStatus = passcodeSaved == false
                ? ". Warning: the passcode could not be saved to Keychain"
                : ""
            return "Fetched Zoom transcript for '\(saved.title)' (\(saved.wordCount ?? 0) words)\(keychainStatus)"
        }

        let (transcript, videoTitle) = try await YouTubeTranscriptService.shared.fetchTranscript(from: article.url)
        let fetchedTitle = videoTitle.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let slideResult = await YouTubeSlideExtractionService.shared.appendingSlideContext(
            to: transcript,
            videoURL: article.url,
            sourceID: article.id,
            videoTitle: videoTitle ?? article.title
        )
        let saved = try await saveSourceAfterWait(sourceID) { stored in
            if let fetchedTitle {
                stored.title = fetchedTitle
            }
            stored.content = slideResult.content
            stored.wordCount = slideResult.content.split(separator: " ").count
            stored.state = .ready
            stored.errorMessage = nil
            return true
        }
        var message = "Fetched transcript for '\(saved.title)' (\(saved.wordCount ?? 0) words"
        if slideResult.slideCount > 0 {
            message += ", \(slideResult.slideCount) slide frame screenshots"
        }
        message += ")"
        if let errorMessage = slideResult.errorMessage {
            message += "\nSlide extraction unavailable: \(errorMessage)"
        }
        return message
    }

    func fetchSourceFromArchive(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard [.article, .manual, .unclassified].contains(article.sourceType) else {
            throw MCPError.invalidInput("fetch_source_from_archive is available for article, manual, and unclassified sources.")
        }
        guard article.url.hasPrefix("http://") || article.url.hasPrefix("https://") else {
            throw MCPError.invalidInput("fetch_source_from_archive requires a web URL.")
        }

        let content = try await SourceService.shared.fetchArchiveContent(for: article.url)
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
        article.errorMessage = nil
        article.isPaywalled = false
        try store.saveSource(article)
        return "Fetched archive.ph content for '\(article.title)' (\(article.wordCount ?? 0) words)"
    }

    func clearSourceDerivedData(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.clearSourceDerivedData(sourceID)
        return "Cleared cached text and embeddings for '\(article.title)'"
    }

    func listSourceActions(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }

        var lines = [
            "Available durable actions for '\(article.title)' (type: \(article.sourceType.rawValue)):",
            "- get_source_content: read source text",
            "- update_source: rename, edit author, edit parent_group, update content, or change source_type",
            "- assign_sources_to_day: put on the Schedule",
            "- get_review_sessions: show review sessions for this source",
            "- add_notebook_sources: add to an explicitly identified Notebook",
            "- set_source_hidden: hide or unhide source",
            "- remove_source: Studio Remove behavior with dismissal plus archive/delete",
            "- archive_source: archive without dismissal",
            "- delete_source: permanently delete",
            "- clear_source_derived_data: clear cached text and embeddings"
        ]

        switch article.sourceType {
        case .article, .paper, .unclassified:
            lines.append("- set_source_paywall_status: mark or clear paywalled status")
        default:
            break
        }

        if [.article, .manual, .unclassified].contains(article.sourceType) {
            lines.append("- attach_text_file_to_source: attach local text/Markdown/HTML as source content")
        }

        if StudioViewModel.supportsLinkDiscovery(article) {
            lines.append("- scan_article_for_linked_sources: read this article's links for the sources it points at (other articles, papers, videos, podcasts)")
            lines.append("- list_video_cited_papers: list the linked sources found, with what the article says about each")
            lines.append("- import_video_cited_paper: add one of those sources to the library")
            lines.append("- update_video_cited_paper_status: dismiss one of those sources, or restore a dismissed one")
        }

        if article.sourceType == .paper {
            lines.append("- update_source: edit paper journal, published_year, DOI, and paywall status")
            lines.append("- attach_pdf_to_paper: attach a local PDF and extract text")
            if article.resolvedPDFPath == nil, article.url.hasPrefix("http") {
                // A paper caught in a storage-level outage has a PDF on record and
                // must not be advertised as re-downloadable — see
                // `downloadPapersNeedingAttention`. Only a paper that HAS a
                // recorded path can be in that set, so papers that never had a
                // PDF skip the whole-library load entirely.
                let hasRecordedPDF = !(article.localFilePath ?? "").isEmpty
                let isUnavailable = hasRecordedPDF && StudioViewModel.unavailableRecordedPaperPDFIDs(
                    in: (try? store.loadActiveSources()) ?? []
                ).contains(article.id)
                if isUnavailable {
                    lines.append("- (PDF on record but its file isn't available on this Mac yet — usually iCloud Drive still downloading. Not a candidate for paper download or paywall recheck.)")
                } else if article.hasPaywallMarker {
                    lines.append("- recheck_paywalled_papers: look again for a legitimate free PDF and attach it if found")
                } else {
                    lines.append("- download_papers_needing_attention: bulk-download missing paper PDFs (this paper qualifies)")
                }
            }
        }

        if article.sourceType == .podcast {
            lines.append("- set_podcast_episode_hidden: hide or unhide this episode")
            lines.append("- set_podcast_show_hidden: hide or unhide show '\(article.domain)'")
            lines.append("- set_podcast_show_import_blocked: stop importing show '\(article.domain)' entirely, or let it back in")
            lines.append("- set_podcast_episode_visible_override: force-show this episode while its show is hidden")
        }

        if article.sourceType == .video {
            lines.append("- fetch_video_transcript: fetch and store a YouTube transcript (plus slide frame context) or a Zoom recording transcript (pass passcode if the recording is protected)")
            lines.append("- list_video_cited_papers: list the papers found on this video's slides")
            lines.append("- import_video_cited_paper: add one of those papers to the library")
            lines.append("- update_video_cited_paper_status: dismiss one of those papers, or restore a dismissed one")
            lines.append("- scan_video_for_cited_papers: read this video's slides for cited papers (catch-up for videos ingested before slide scanning existed)")
            if article.isYouTubeURL {
                lines.append("- set_youtube_channel_hidden: hide or unhide channel '\(article.domain)'")
                lines.append("- set_youtube_video_visible_override: force-show this video while its channel is hidden")
            }
        }

        lines.append("")
        lines.append("Unavailable to MCP because they operate local UI instead of durable app state:")
        lines.append("- Open in Window, Open in Safari, Open in VS Code, Reveal in Finder, native file picker, clipboard copy")
        return lines.joined(separator: "\n")
    }

    func updateSource(
        sourceID: String,
        title: String?,
        author: String?,
        sourceType: String? = nil,
        journal: String? = nil,
        publishedYear: String? = nil,
        doi: String? = nil,
        isPaywalled: Bool? = nil,
        parentGroup: String?,
        content: String?
    ) throws -> String {
        try Self.requirePlausibleSourceAuthor(author)
        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        var changedFields: [String] = []

        if let title {
            article.title = title
            changedFields.append("title")
        }
        if let author {
            article.author = author
            changedFields.append("author")
        }
        if let sourceType {
            guard let type = StudioSourceType(rawValue: sourceType) else {
                throw MCPError.invalidInput("Unsupported source_type: \(sourceType)")
            }
            let previousType = article.sourceType
            article.sourceType = type
            if type == .paper, previousType != .paper {
                article.prepareForPaperMetadataExtraction()
            }
            changedFields.append("source_type")
        }
        if let journal {
            article.journal = Self.nilIfBlank(journal)
            changedFields.append("journal")
        }
        if let publishedYear {
            article.publishedYear = Self.nilIfBlank(publishedYear)
            changedFields.append("published_year")
        }
        if let doi {
            article.doi = Self.nilIfBlank(doi)
            changedFields.append("doi")
        }
        if let isPaywalled {
            guard [.article, .paper, .unclassified].contains(article.sourceType) else {
                throw MCPError.invalidInput("is_paywalled is only available for article, paper, or unclassified sources.")
            }
            article.isPaywalled = isPaywalled
            if isPaywalled {
                article.state = article.sourceType == .paper ? .error : .ready
                article.statusFlag = .paywall
            } else if article.statusFlag == .paywall {
                article.errorMessage = nil
                article.state = article.sourceType == .paper && !article.hasPaperIngestionAttestation
                    ? .queued
                    : .ready
            }
            changedFields.append("is_paywalled")
        }
        if let parentGroup {
            article.parentGroup = try resolveGroupID(input: parentGroup, preferredType: article.sourceType.rawValue, store: store)
            changedFields.append("parent_group")
        }
        if let content {
            article.content = content
            article.wordCount = content.split(separator: " ").count
            if article.sourceType == .paper {
                article.prepareForPaperMetadataExtraction()
            } else {
                article.state = .ready
            }
            changedFields.append("content")
        }
        if changedFields.isEmpty {
            return "No fields to update."
        }
        try store.saveSource(article)
        if article.sourceType == .meeting, changedFields.contains("parent_group"), let groupID = article.parentGroup {
            // The session's recording and transcript rows name its series
            // too, and go where the session goes.
            try store.moveMeetingArtifacts(sourceID: sourceID, toGroupID: groupID)
        }
        return "Updated source \(sourceID): \(changedFields.joined(separator: ", "))"
    }

    static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func decodeTextData(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .ascii)
    }

    func copyFileIntoContentRoot(
        _ sourceURL: URL,
        folder: String,
        baseName: String,
        fallbackExtension: String
    ) throws -> URL {
        let destinationDirectory = sourceContentRoot.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackExtension
            : sourceURL.pathExtension
        var destination = destinationDirectory
            .appendingPathComponent(Self.safeFilenameBase(baseName))
            .appendingPathExtension(fileExtension)
        var suffix = 2
        while destination.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
            if !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                    return destination
                } catch {
                    // Imports run side by side: another one took the name
                    // between the look and the copy, which never overwrites.
                    guard FileManager.default.fileExists(atPath: destination.path), suffix < 100 else { throw error }
                }
            }
            destination = destinationDirectory
                .appendingPathComponent("\(Self.safeFilenameBase(baseName))-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return destination
    }

    static func safeFilenameBase(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "source" : String(cleaned.prefix(120))
    }
}
