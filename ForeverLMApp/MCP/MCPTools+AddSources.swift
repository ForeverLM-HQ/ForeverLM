// MCPDataStore: Adding, batching, updating and removing sources.
import Foundation

extension MCPDataStore {
    /// - Parameter connectorLabel: non-nil only for ingest-scoped plugin
    ///   clients. Stamps `discovery_origin = plugin` plus the label, both
    ///   derived from the caller's authenticated OAuth client — never from tool
    ///   arguments — so provenance can't be spoofed and bulk removal stays
    ///   trustworthy.
    /// - Parameter occurredAt: when a meeting happened, as ISO 8601. Meetings
    ///   are dated by it — the Meetings tab, the Schedule, and a source search's
    ///   `occurred:` all read `dateAdded`, which for a meeting means the meeting
    ///   date, not the push date. Without it a plugin's whole history lands
    ///   on the day it first ran (a hundred-odd meetings dated one day).
    /// - Parameter videoChannel: a YouTube video's uploader, looked up before
    ///   the store gate was taken (`addSourceNamingVideoChannel`).
    func addSource(url: String, title: String, sourceType: String, content: String?, parentGroup: String?, author: String?, occurredAt: String? = nil, connectorLabel: String? = nil, videoChannel: String? = nil) throws -> String {
        try Self.requirePlausibleSourceAuthor(author)
        let store = try knowledgeStore()
        let type = Self.filedSourceType(claimed: sourceType, url: url)
        let occurredAtDate = try Self.parsedOccurredAt(occurredAt, sourceType: type)
        guard type != .paper else {
            throw MCPError.invalidInput(
                "add_source cannot ingest papers. Use import_paper_from_url or import_local_pdf_as_paper so the mandatory Paper Metadata LLM call runs on the paper."
            )
        }
        // A page ForeverLM links is never a source (product owner, 2026-09-09: "codex
        // sites should always obviously be ingested as a 'site' not as an
        // article"). The app's routes all send such a link to `linkPage`; the
        // tool contract has a tool for it, so the caller is sent there rather
        // than redirected — add_source answers with a line, link_page with the
        // entry, and a plugin's batch reports the refusal per item.
        if let kind = StudioViewModel.linkedPageKind(forSourceURL: url) {
            throw MCPError.invalidInput(
                "add_source does not import a \(kind.label). ForeverLM links that kind of page instead of scraping it — a Codex site answers an anonymous fetch with its sign-in page, so an article made from it would hold nothing. Call link_page with the same url; the entry lands in \(kind.section.title)."
            )
        }
        // Convoke results are not sources (product owner, 2026-09-12): a plugin
        // pushed two under platform.convoke.bio/mcp addresses, and the batch
        // route reports this per item the way it reports a linked page.
        if let refusal = StudioViewModel.sourceRefusal(forSourceURL: url) {
            throw MCPError.invalidInput("add_source does not import this url. \(refusal)")
        }
        // A path on this Mac is read later as the source's text, so it is held to the folders a
        // client may read (a client could otherwise file ~/.ssh and read it back).
        if Self.isLocalPathURL(url) { _ = try validateClientProvidedPath(url) }
        // A playlist is a course, never a source. Asked to ingest one, an
        // assistant with only this tool builds the course by hand: the
        // playlist page becomes a course source, the course takes its title
        // as its ID, and lessons go in as `course` material instead of
        // videos. The app's own importer does it right, and
        // import_youtube_playlist runs it, so the caller is sent there.
        if YouTubePlaylistService.isPlaylistURL(url) {
            throw MCPError.invalidInput(
                "add_source does not import a YouTube playlist: a playlist is a course, not a source. Call import_youtube_playlist with this url — it creates the course (or fills the one that already names this playlist), puts each video on its own numbered lecture and fetches the transcripts."
            )
        }
        // A Teachable lecture page is the course's sidebar and a player; saved
        // as a source it would hold the outline, not the talk. The importer
        // reads the page as the learner and transcribes the audio.
        if TeachableCourseService.isLectureURL(url), (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPError.invalidInput(
                "add_source does not import a Teachable lecture: its page holds the course outline, not the talk. Call import_teachable_course with this url — it files the course's video lectures and transcribes their audio."
            )
        }
        // A Gemini Notebook address is a whole notebook; fetched as a page it
        // is Google's sign-in. The importer reads it as the learner and files
        // its sources, chats and notes as a Notebook.
        if GeminiNotebookService.isNotebookURL(url) {
            throw MCPError.invalidInput(
                "add_source does not import a Gemini Notebook: its address is a whole notebook, not a page. Call import_gemini_notebook with this url — it files the notebook as a Notebook with its sources, its chats and its notes."
            )
        }
        // Course material reaches a list only through a course, so a course
        // source with no course is a source nothing can show. Ask for the course
        // instead of adding an invisible row.
        if type == .course, (parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            throw MCPError.invalidInput(
                "A course source needs parent_group set to the course it belongs to — the Courses tab lists courses, so course material outside one is never shown. Call list_courses or create_course first, or add this as a different source_type."
            )
        }
        // The same for a chapter: the Books tab lists books, and a book source
        // with no group is a loose row above them carrying a raw file path where
        // a cover and a book title belong. Nothing files it afterwards either —
        // `saveSource` writes a `group_members` row only when the article names a
        // group, and only the book importer ever names one. This is what happened
        // to "Radical Life Extension": thirteen of its fourteen chapters were
        // re-added here with no parent_group, and the fourteenth stayed in the
        // book only because it already existed and was skipped.
        if type == .book, (parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            throw MCPError.invalidInput(
                "A book source needs parent_group set to the book it belongs to — the Books tab lists books, so a chapter outside one is a loose row with no cover and no book to open it from. Pass the book's display title (created when it does not exist yet) or its book_id from list_sources, or add this as a different source_type."
            )
        }
        let normalizedURL = URLNormalizer.normalize(url)
        if let existing = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url) {
            if existing.status == .archived, store.isSourceDismissed(url: url) {
                return Self.removedSourceRefusal(title: title)
            }
            return "Source already exists (id: \(existing.id), status: \(existing.status.rawValue))"
        }
        // A URL the learner removed is a tombstone, not a gap. `dismissed_sources`
        // outlives the archived row — deleting a meeting series takes its
        // sessions' rows with it — and every in-app discovery route already
        // refuses it (`insertSourceIfNew`, the feed mirrors, sync). This route
        // did not: it asked only whether the row still existed, so a plugin
        // or the recordings mailbox could file a recording the learner had
        // removed that afternoon. Only an explicit re-add in the app lifts the
        // tombstone (`prepareExplicitSourceReAdd`); a caller here never does.
        if store.isSourceDismissed(url: url) {
            return Self.removedSourceRefusal(title: title)
        }
        if type == .meeting, let parentGroup,
           let refusal = try Self.removedMeetingSeriesRefusal(parentGroup: parentGroup, sessionTitle: title, store: store) {
            return refusal
        }
        let domain = Self.newSourceDomain(url: url, sourceType: type, parentGroup: parentGroup, videoChannel: videoChannel)
        var resolvedParentGroup: String?
        var resolvedParentGroupTitle: String?

        let pluginOrigin = type == .meeting
            ? connectorLabel.flatMap(MeetingProvider.forPluginLabel)?.pluginDiscoveryOrigin
            : nil
        var article = StudioArticle(
            url: url,
            title: title,
            sourceType: type,
            discoveryOrigin: pluginOrigin ?? (connectorLabel != nil ? .plugin : .manual),
            author: author
        )
        article.connectorLabel = connectorLabel
        article.normalizedURL = normalizedURL
        article.domain = domain
        // A podcast's text is its transcript, which the app fetches once it
        // has found the episode on Apple Podcasts (`findAndOfferPodcast`, run
        // for a queued web podcast with no text). What a caller holds for a
        // web address is the episode's page, its show notes; kept, the row
        // would read as ready and never be looked up.
        let looksUpEpisode = type == .podcast && url.lowercased().hasPrefix("http")
        let droppedPodcastText = looksUpEpisode
            && !(content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let content, !looksUpEpisode {
            // Text an assistant copied off a page keeps the page's soft
            // hyphens; they are no part of the words.
            let text = content.removingSoftHyphens()
            article.content = text
            article.wordCount = text.split(separator: " ").count
            article.state = .ready
        }
        if let occurredAtDate {
            article.dateAdded = occurredAtDate
        }

        if let parentGroup {
            let groupID = try resolveGroupID(input: parentGroup, preferredType: sourceType, store: store)
            resolvedParentGroup = groupID
            resolvedParentGroupTitle = parentGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            article.parentGroup = groupID
        }

        try store.saveSource(article)
        // A meeting whose transcript arrived with it is a stored transcript:
        // the funnel folds it into the sitting it continues and reads the
        // series' action items, as for a transcript the app fetched itself.
        if type == .meeting, article.state == .ready {
            MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id)
        }

        let groupText: String
        if let groupID = resolvedParentGroup {
            let title = resolvedParentGroupTitle?.isEmpty == false ? resolvedParentGroupTitle! : groupID
            let label = (sourceType == "book" || sourceType == "course" || sourceType == "meeting") ? sourceType : "group"
            groupText = ", \(label): \(title), group_id: \(groupID)"
        } else {
            groupText = ""
        }
        let occurredText = occurredAtDate.map { ", occurred_at: \(Self.iso8601String($0))" } ?? ""
        var message = "Added source '\(title)' (id: \(article.id), type: \(type.rawValue)\(groupText)\(occurredText))"
        if article.content == nil, ZoomRecordingService.isZoomRecordingURL(url) {
            message += ". This is a Zoom recording link — call fetch_video_transcript with this id to fetch its transcript."
        }
        if looksUpEpisode {
            let claimedType = StudioSourceType(rawValue: sourceType)
            if claimedType != .podcast {
                message += ". Filed as a podcast, not \(sourceType): \(URL(string: url)?.host ?? url) hosts podcast episodes"
            }
            message += ". ForeverLM reads a podcast from its transcript: it looks this episode up on Apple Podcasts, and the learner confirms the match in the app — or call find_podcast_match, then resolve_podcast_match with this id"
            if droppedPodcastText {
                message += ". The content passed was not kept: an episode's page holds its show notes, not what was said"
            }
            message += "."
        }
        return message
    }

    /// The type a new source is filed under: the caller's, except that a link
    /// on a podcast host is an episode whatever the caller called it, as the
    /// app files a pasted one (`addArticle`). Otherwise an assistant filing a
    /// podcasts.apple.com episode as a video leaves it in the YouTube tab with
    /// no picture, the episode page's text standing in for a transcript.
    static func filedSourceType(claimed: String, url: String) -> StudioSourceType {
        if StudioViewModel.isPodcastHostURL(url) { return .podcast }
        return StudioSourceType(rawValue: claimed) ?? .manual
    }

    /// `add_source` as the tool runs it. A YouTube video's uploader is looked
    /// up first, holding nothing, and the save then holds the store gate alone
    /// (`MCPToolRegistry.selfGatedToolNames`), so no other call waits on
    /// YouTube. Naming the channel up front keeps the row from taking the URL's
    /// host ("www.youtube.com") for its channel until the app's backfill names
    /// it, which leaves it out of reach of a `show` search.
    ///
    /// `notebookID` is add_source's notebook_id: checked before anything is
    /// added, and the source the save produced or matched then joins that
    /// Notebook (`fileImportedSources`), said after the save's own answer.
    func addSourceNamingVideoChannel(
        url: String,
        title: String,
        sourceType: String,
        content: String?,
        parentGroup: String?,
        author: String?,
        occurredAt: String?,
        connectorLabel: String?,
        notebookID: String? = nil
    ) async throws -> String {
        let notebook: LearningGoalRecord? = Self.nilIfBlank(notebookID ?? "") == nil
            ? nil
            : try await withStoreGate(.shared) { try notebookForImport(notebookID: notebookID) }
        let channel = await Self.uploaderChannelForNewVideo(url: url, sourceType: sourceType)
        let (message, sourceID) = try await withStoreGate(.exclusive) { () -> (String, String?) in
            let message = try addSource(
                url: url,
                title: title,
                sourceType: sourceType,
                content: content,
                parentGroup: parentGroup,
                author: author,
                occurredAt: occurredAt,
                connectorLabel: connectorLabel,
                videoChannel: channel
            )
            guard let notebook, !message.hasPrefix(Self.removedByLearnerPrefix) else { return (message, nil) }
            return (message, importedLibrarySourceID(url: url, notebook: notebook, store: try knowledgeStore()))
        }
        guard let notebook else { return message }
        let filing = await fileImportedSources(sourceID.map { [$0] } ?? [], in: notebook)
        return message + "\n" + filing.answer(for: notebook, batch: false)
    }

    /// The uploader of a YouTube video about to be added. Nil for anything
    /// that is not a YouTube video, and when YouTube names no uploader; the
    /// save then keeps the URL's host until the app's channel backfill
    /// (`backfillMissingVideoChannels`) names it.
    static func uploaderChannelForNewVideo(url: String, sourceType: String) async -> String? {
        guard StudioSourceType(rawValue: sourceType) == .video,
              YouTubeTranscriptService.isYouTubeURL(url),
              !YouTubePlaylistService.isPlaylistURL(url),
              let videoId = YouTubeTranscriptService.extractVideoId(from: url),
              let metadata = await YouTubeTranscriptService.shared.fetchVideoMetadata(videoId: videoId) else {
            return nil
        }
        return YouTubeTranscriptService.channelName(of: metadata)
    }

    /// What a new source stores as `domain`. For a video that is its
    /// uploader's channel — the name list_shows reports, filter_sources' `show`
    /// matches and the Videos sidebar prints under the title — whenever it is
    /// known; otherwise the URL's host stands in.
    static func newSourceDomain(url: String, sourceType: StudioSourceType, parentGroup: String?, videoChannel: String?) -> String {
        if sourceType == .video,
           let channel = videoChannel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channel.isEmpty {
            return channel
        }
        if let host = URL(string: url)?.host { return host }
        return parentGroup ?? "Local"
    }

    /// `occurred_at` parsed for a source of `sourceType`. Only meetings carry a
    /// date of their own; for every other type `dateAdded` means what it says,
    /// so a value there is a plugin bug worth reporting rather than a field
    /// to quietly drop. Unparseable input is refused for the same reason: a
    /// meeting silently dated by its push would look exactly like the bug this
    /// field exists to fix.
    static func parsedOccurredAt(_ raw: String?, sourceType: StudioSourceType) throws -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard sourceType == .meeting else {
            throw MCPError.invalidInput(
                "occurred_at is only accepted for source_type \"meeting\"; other sources are dated by when they were added."
            )
        }
        guard let date = parseFlexibleTimestamp(raw) else {
            throw MCPError.invalidInput(
                "occurred_at must be an ISO 8601 timestamp such as 2026-09-02T16:55:00Z (got \"\(raw)\")."
            )
        }
        return date
    }

    static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Every refusal that stands in for a learner's removal starts with this,
    /// so `add_sources` can count it apart from an addition and a caller can
    /// tell "the learner took this out" from "this failed".
    static let removedByLearnerPrefix = "Not added:"

    /// The answer for a URL the learner removed. A plain result, not a tool
    /// error: the recordings mailbox files a notice once and marks it done on
    /// any answer, and an assistant reads it as the decision it is rather than
    /// as something to retry.
    static func removedSourceRefusal(title: String) -> String {
        "\(removedByLearnerPrefix) '\(title)' was removed by the learner, so it stays removed. Only re-adding it from the app brings it back."
    }

    /// Whether filing a meeting under `parentGroup` would bring back a series
    /// the learner removed, and the answer to give if so.
    ///
    /// `removeMeetingGroup` records the series' stable identity and title
    /// (`StudioViewModel.recordMeetingGroupRemoval`), hides the row while the
    /// Undo notice is up, and then deletes it. `resolveGroupID` knew none of
    /// that: an unknown title made a fresh group, and a known one was matched
    /// by title even while hidden — so a Read AI push or a recordings-mailbox
    /// notice could stand a removed series straight back up. The tombstone
    /// speaks only for a series that is gone or hidden: one the learner has
    /// visibly back (an explicit import lifts the tombstone, but an older
    /// title-only entry can outlive that) is a series to file into.
    static func removedMeetingSeriesRefusal(
        parentGroup: String,
        sessionTitle: String,
        store: KnowledgeStore
    ) throws -> String? {
        let trimmed = parentGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let removed: Bool
        let seriesTitle: String
        if let existingID = try store.resolvedMeetingGroupID(matching: trimmed) {
            let metadata = try store.loadMeetingGroups()[existingID] ?? MeetingMetadata(title: trimmed)
            guard metadata.isHidden else { return nil }
            removed = StudioViewModel.isMeetingGroupRemoved(groupID: existingID, metadata: metadata)
            seriesTitle = metadata.title ?? trimmed
        } else {
            removed = StudioViewModel.isMeetingGroupTitleRemoved(trimmed)
                || StudioViewModel.loadRemovedMeetingGroupIdentities().contains("group:\(trimmed)")
            seriesTitle = trimmed
        }
        guard removed else { return nil }
        return "\(removedByLearnerPrefix) the meeting series '\(seriesTitle)' was removed by the learner, so it stays removed and '\(sessionTitle)' was not filed into it. Only importing the series again from the app brings it back."
    }

    /// Batch form of `addSource` for plugin feeds: one metered tool call, one
    /// result line per item, and nothing silently dropped — every item is
    /// accounted for as added, updated, already existing, or failed. Items that
    /// already exist are only touched when that item sets `update_existing`,
    /// and updates go through `updateSourceContent`, which enforces plugin
    /// ownership for ingest-scoped callers. A meeting's `occurred_at` and
    /// `parent_group` travel with the update too, so a plugin that first
    /// pushed its history without them can re-push once and have every meeting
    /// take its real date and its series.
    func addSources(_ items: [[String: Any]], connectorLabel: String?) throws -> String {
        try addSourcesBatch(items, connectorLabel: connectorLabel).text
    }

    /// `add_sources`' answer, and the address of every item the library holds
    /// afterwards — added, updated or already there — so the batch can be
    /// filed in a Notebook (notebook_id) by the addresses it deduplicated on.
    struct SourceBatchResult {
        let text: String
        let heldURLs: [String]
    }

    func addSourcesBatch(_ items: [[String: Any]], connectorLabel: String?) throws -> SourceBatchResult {
        guard !items.isEmpty else {
            return SourceBatchResult(text: "Error: sources must be a non-empty array of {url, title, source_type, ...} items.", heldURLs: [])
        }
        guard items.count <= MCPToolRegistry.maxBatchSourceItems else {
            return SourceBatchResult(
                text: "Error: add_sources accepts at most \(MCPToolRegistry.maxBatchSourceItems) items per call (got \(items.count)). Split the batch into smaller calls.",
                heldURLs: []
            )
        }

        var lines: [String] = []
        var heldURLs: [String] = []
        var added = 0, updated = 0, alreadyExisting = 0, failed = 0, removedByLearner = 0
        let store = try knowledgeStore()

        for (index, item) in items.enumerated() {
            let url = (item["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !title.isEmpty else {
                failed += 1
                lines.append("[\(index)] Error: url and title are required")
                continue
            }

            do {
                let normalizedURL = URLNormalizer.normalize(url)
                let existing = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url)
                if let existing {
                    if item["update_existing"] as? Bool == true {
                        let message = try updateSourceContent(
                            sourceID: existing.id,
                            url: nil,
                            content: item["content"] as? String,
                            title: item["title"] as? String,
                            author: item["author"] as? String,
                            parentGroup: item["parent_group"] as? String,
                            occurredAt: item["occurred_at"] as? String,
                            restrictToPluginLabel: connectorLabel
                        )
                        if message.hasPrefix("Error:") {
                            failed += 1
                        } else {
                            updated += 1
                            heldURLs.append(url)
                        }
                        lines.append("[\(index)] \(message)")
                    } else {
                        alreadyExisting += 1
                        heldURLs.append(url)
                        lines.append("[\(index)] Already exists (id: \(existing.id), status: \(existing.status.rawValue))")
                    }
                } else {
                    let message = try addSource(
                        url: url,
                        title: title,
                        sourceType: item["source_type"] as? String ?? "article",
                        content: item["content"] as? String,
                        parentGroup: item["parent_group"] as? String,
                        author: item["author"] as? String,
                        occurredAt: item["occurred_at"] as? String,
                        connectorLabel: connectorLabel
                    )
                    if message.hasPrefix(Self.removedByLearnerPrefix) {
                        removedByLearner += 1
                    } else {
                        added += 1
                        heldURLs.append(url)
                    }
                    lines.append("[\(index)] \(message)")
                }
            } catch {
                failed += 1
                lines.append("[\(index)] Error: \(error.localizedDescription)")
            }
        }

        let prefix = failed == items.count ? "Error: every item failed. " : ""
        let removedText = removedByLearner > 0 ? ", \(removedByLearner) removed by the learner" : ""
        let summary = "\(prefix)Batch complete: \(added) added, \(updated) updated, \(alreadyExisting) already existed\(removedText), \(failed) failed (of \(items.count))."
        return SourceBatchResult(text: ([summary] + lines).joined(separator: "\n"), heldURLs: heldURLs)
    }

    /// Replace an existing source's stored text (and optionally title/author),
    /// matched by ID or canonical URL. `restrictToPluginLabel` is non-nil for
    /// ingest-scoped callers and confines them to sources stamped with their own
    /// label — an ingest client must not be able to overwrite the user's own
    /// sources, another plugin's, or anything else it didn't add.
    ///
    /// `parentGroup` and `occurredAt` apply to meetings only: the series the
    /// meeting belongs to (resolved by id or title, created when new, exactly as
    /// `addSource` does) and when it happened. Both exist so a re-push can
    /// correct a meeting that was first pushed without them; for other types
    /// the group is left alone and a date is refused.
    func updateSourceContent(
        sourceID: String?,
        url: String?,
        content: String?,
        title: String?,
        author: String?,
        parentGroup: String? = nil,
        occurredAt: String? = nil,
        restrictToPluginLabel: String?
    ) throws -> String {
        try Self.requirePlausibleSourceAuthor(author)
        let store = try knowledgeStore()

        var resolvedID: String?
        if let sourceID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
            resolvedID = sourceID
        } else if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            let normalizedURL = URLNormalizer.normalize(url)
            resolvedID = (store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url))?.id
            if resolvedID == nil {
                return "Error: no source found for url \(url). Add it first with add_source."
            }
        }
        guard let id = resolvedID else {
            return "Error: provide source_id or url of an existing source."
        }
        guard var article = try store.loadSourceForSync(id) else {
            throw MCPError.notFound("Source not found: \(id)")
        }

        if let restrictToPluginLabel {
            guard article.connectorLabel == restrictToPluginLabel else {
                let owner = article.connectorLabel.map { "plugin '\($0)'" } ?? "the app or another origin"
                return "Error: this ingest connection ('\(restrictToPluginLabel)') can only update sources it added itself. '\(article.title)' was added by \(owner)."
            }
        }

        var changedFields: [String] = []
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Soft hyphens are no part of the words (`removingSoftHyphens()`).
            let text = content.removingSoftHyphens()
            article.content = text
            article.wordCount = text.split(separator: " ").count
            if article.sourceType == .paper {
                article.prepareForPaperMetadataExtraction()
            } else {
                article.state = .ready
            }
            changedFields.append("content")
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != article.title {
            article.title = title
            changedFields.append("title")
        }
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty, author != article.author {
            article.author = author
            changedFields.append("author")
        }
        if let occurredAtDate = try Self.parsedOccurredAt(occurredAt, sourceType: article.sourceType),
           occurredAtDate != article.dateAdded {
            article.dateAdded = occurredAtDate
            changedFields.append("occurred_at")
        }
        if article.sourceType == .meeting,
           let parentGroup = parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !parentGroup.isEmpty {
            // Moving a session into a removed series would recreate the series.
            if let refusal = try Self.removedMeetingSeriesRefusal(
                parentGroup: parentGroup, sessionTitle: article.title, store: store
            ) {
                return "Error: \(refusal)"
            }
            let groupID = try resolveGroupID(input: parentGroup, preferredType: "meeting", store: store)
            // Compare through the merge aliases: a meeting already filed under a
            // series the learner merged into this one is where it belongs.
            let currentGroupID = try article.parentGroup.map { try store.canonicalMeetingGroupID($0) }
            if currentGroupID != groupID {
                article.parentGroup = groupID
                changedFields.append("parent_group")
            }
        }
        guard !changedFields.isEmpty else {
            return "Error: nothing to update — provide content, title, or author."
        }

        try store.saveSource(article)
        let wordText = changedFields.contains("content") ? " (\(article.wordCount ?? 0) words)" : ""
        return "Updated \(changedFields.joined(separator: ", ")) of '\(article.title)'\(wordText)"
    }

    /// Remove every active source a user-built plugin added, by its stamped
    /// label. Full-scope connections only (the registry never exposes this to
    /// ingest clients). Each source goes through the same path as
    /// `remove_source` — URL dismissed so discovery won't re-add it, then
    /// archived (undownloaded papers are deleted) — so a revoked plugin's
    /// content disappears the same way a manual Studio removal would.
    func removePluginSources(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: connector_label is required."
        }
        let store = try knowledgeStore()
        let ids = try store.activeSourceIDs(withPluginLabel: trimmed)
        guard !ids.isEmpty else {
            return "No active sources found for plugin '\(trimmed)'."
        }

        var lines: [String] = []
        var removed = 0, failed = 0
        for id in ids {
            do {
                lines.append(try removeSource(id))
                removed += 1
            } catch {
                failed += 1
                lines.append("Error removing \(id): \(error.localizedDescription)")
            }
        }
        let summary = "Removed \(removed) of \(ids.count) sources added by plugin '\(trimmed)'\(failed > 0 ? " (\(failed) failed)" : "")."
        return ([summary] + lines).joined(separator: "\n")
    }

    func deleteSource(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.deleteSource(sourceID)
        return "Deleted source '\(article.title)'"
    }

    func removeSource(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }

        try store.dismissSource(url: article.url, title: article.title)
        if let webURL = article.podcastWebPageURL {
            try store.dismissSource(url: webURL, title: article.title)
        }

        if article.sourceType == .paper && article.resolvedPDFPath == nil {
            try store.deleteSource(sourceID)
            return "Removed and deleted undownloaded paper '\(article.title)'"
        }

        try store.archiveSource(sourceID)
        return "Removed and archived source '\(article.title)'"
    }

    func archiveSource(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        guard let article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        try store.archiveSource(sourceID)
        return "Archived source '\(article.title)'"
    }

    /// Restore an archived source to active. This is also the inverse of
    /// `removeSource`: an explicit restore clears the URL dismissal tombstones that
    /// removal created, or the next sync would immediately archive the source again.
    /// When a local file's text was wiped on archive, rebuild the cached content from
    /// that file so the source is immediately readable and reviewable. Schedule
    /// assignments are not restored (archiving dropped them); re-add via Schedule tools.
    func unarchiveSourceRestoringContent(_ sourceID: String) throws -> String {
        let store = try knowledgeStore()
        // The work is the store's, shared with the app's own Unarchive action
        // on a planner block's source row; only the sentence is composed here.
        guard let outcome = try store.unarchiveSourceRestoringContent(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        let note = outcome.rebuiltContent
            ? " and rebuilt its content from the local file"
            : " (no local file content to rebuild; re-fetch if the source needs text)"
        return "Unarchived source '\(outcome.title)'\(note)"
    }

    // MARK: - Article reading view
}
