// MCPToolRegistry: runs the source maintenance and import tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the source maintenance and import tools; nil for any other name.
    func executeSourceToolsTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
        case "move_source_type":
            return try store.moveSourceType(
                sourceID: arguments["source_id"] as? String ?? "",
                newType: arguments["new_type"] as? String ?? ""
            )
        case "remove_all_from_podcast":
            return try store.removeAllFromPodcastShow(showName: arguments["show_name"] as? String ?? "")
        case "delete_review_session":
            return try store.deleteReviewSession(sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]))
        case "update_review_session_sources":
            return try store.updateReviewSessionLinkedSources(
                sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                sourceIDs: arguments["source_ids"] as? [String] ?? []
            )
        case "update_review_session":
            return try store.updateReviewSession(
                sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                title: arguments["title"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                isHidden: arguments["is_hidden"] as? Bool,
                isPinned: arguments["is_pinned"] as? Bool
            )
        case "extract_paper_metadata":
            return try await store.extractPaperMetadataForSource(sourceID: arguments["source_id"] as? String ?? "")
        case "extract_article_metadata":
            return try await store.extractArticleMetadataForSource(sourceID: arguments["source_id"] as? String ?? "")
        case "find_duplicate_papers":
            return try await store.findDuplicatePapers(archiveDuplicates: arguments["archive_duplicates"] as? Bool ?? false)
        case "find_podcast_match":
            return try await store.findPodcastMatch(sourceID: arguments["source_id"] as? String ?? "")
        case "resolve_podcast_match":
            return try await store.resolvePodcastMatch(
                sourceID: arguments["source_id"] as? String ?? "",
                confirm: arguments["confirm"] as? Bool ?? false
            )
        case "find_podcast_on_youtube":
            return try await store.findPodcastOnYouTube(
                sourceID: arguments["source_id"] as? String ?? "",
                alwaysForShow: arguments["always_for_show"] as? Bool
            )
        case "import_podcast_youtube_transcript":
            return try await store.importPodcastYouTubeTranscript(
                sourceID: arguments["source_id"] as? String ?? "",
                video: arguments["video"] as? String ?? "",
                replace: arguments["replace"] as? Bool ?? false
            )
        case "refetch_source_content":
            return try await store.refetchSourceContent(sourceID: arguments["source_id"] as? String ?? "")
        case "import_local_pdf_as_paper":
            return try await store.importLocalPDFAsPaperInBackground(
                filePath: arguments["file_path"] as? String ?? "",
                title: arguments["title"] as? String,
                tool: "import_local_pdf_as_paper",
                approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
            )
        case "import_local_file":
            return try await store.importLocalFile(
                filePath: arguments["file_path"] as? String ?? "",
                kind: arguments["kind"] as? String,
                title: arguments["title"] as? String,
                approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
            )
        case "fetch_video_transcript":
            return try await store.fetchVideoTranscript(
                sourceID: arguments["source_id"] as? String ?? "",
                passcode: arguments["passcode"] as? String
            )
        case "list_video_cited_papers":
            return try store.listVideoCitedPapers(sourceID: arguments["source_id"] as? String ?? "")
        case "import_video_cited_paper":
            return try await store.importVideoCitedPaper(
                citedPaperID: arguments["cited_paper_id"] as? String ?? ""
            )
        case "update_video_cited_paper_status":
            return try store.updateVideoCitedPaperStatus(
                citedPaperID: arguments["cited_paper_id"] as? String ?? "",
                status: arguments["status"] as? String ?? ""
            )
        case "extract_video_slides":
            return try await store.extractVideoSlides(sourceID: arguments["source_id"] as? String ?? "")
        case "scan_video_for_cited_papers":
            return try await store.scanVideoForCitedPapers(
                sourceID: arguments["source_id"] as? String ?? "",
                force: arguments["force"] as? Bool ?? false,
                exhaustive: arguments["all_slides"] as? Bool ?? false
            )
        case "scan_meeting_for_mentioned_papers":
            return try await store.scanMeetingForMentionedPapers(
                sourceID: arguments["source_id"] as? String ?? "",
                force: arguments["force"] as? Bool ?? false
            )
        case "make_article_reading_view":
            return try await store.makeArticleReadingView(
                sourceID: arguments["source_id"] as? String ?? "",
                instruction: arguments["instruction"] as? String ?? ""
            )
        case "get_article_reading_view":
            return try store.getArticleReadingView(sourceID: arguments["source_id"] as? String ?? "")
        case "set_article_reading_view_shown":
            return try store.setArticleReadingViewShown(
                sourceID: arguments["source_id"] as? String ?? "",
                shown: arguments["shown"] as? Bool ?? true
            )
        case "clear_article_reading_view":
            return try store.clearArticleReadingView(sourceID: arguments["source_id"] as? String ?? "")
        case "scan_article_for_linked_sources":
            return try await store.scanArticleForLinkedSources(
                sourceID: arguments["source_id"] as? String ?? "",
                force: arguments["force"] as? Bool ?? false
            )
        case "fetch_source_from_archive":
            return try await store.fetchSourceFromArchive(sourceID: arguments["source_id"] as? String ?? "")
        case "clear_source_derived_data":
            return try store.clearSourceDerivedData(arguments["source_id"] as? String ?? "")
        case "set_source_read":
            return try store.setSourceRead(
                sourceID: arguments["source_id"] as? String ?? "",
                read: arguments["read"] as? Bool ?? true
            )
        case "update_source":
            return try store.updateSource(
                sourceID: arguments["source_id"] as? String ?? "",
                title: arguments["title"] as? String,
                author: arguments["author"] as? String,
                sourceType: arguments["source_type"] as? String,
                journal: arguments["journal"] as? String,
                publishedYear: arguments["published_year"] as? String,
                doi: arguments["doi"] as? String,
                isPaywalled: arguments["is_paywalled"] as? Bool,
                parentGroup: arguments["parent_group"] as? String,
                content: arguments["content"] as? String
            )
        default:
            return nil
        }
    }
}
