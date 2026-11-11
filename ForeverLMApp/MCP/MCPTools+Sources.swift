import Foundation
import ApplicationServices
import PDFKit

extension MCPDataStore {

    // MARK: - Sources

    func listSources() throws -> String {
        // Lists every source family participating in ambient knowledge. Notebook
        // scope is explicit: resolve its ID, then pass it to list_notebook_sources.
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)
        return try withDB { db in
            let rows = try query(db, """
                SELECT id, url, title, domain, date_added, word_count, state,
                       source_type, parent_group, COALESCE(parent_group_title, parent_group) AS group_name,
                       group_sort_index, author
                FROM source_projection
                ORDER BY date_added DESC
            """)
            let items = rows
                .filter { row in
                    guard let id = row["id"] as? String else { return false }
                    return !excludedSourceIDs.contains(id)
                }
                .map(MCPSourceListItem.init(row:))
            let groupedBookItems = items.filter(\.isGroupedBookChapter)
            guard !groupedBookItems.isEmpty else {
                var lines: [String] = ["Sources (\(items.count)):"]
                for item in items {
                    lines.append(sourceListLine(for: item))
                }
                return lines.joined(separator: "\n")
            }

            let bookGroups = Dictionary(grouping: groupedBookItems, by: \.parentGroup)
            let bookGroupIDs = bookGroups.keys.sorted { lhs, rhs in
                let lhsName = bookGroups[lhs]?.first?.displayGroupName ?? lhs
                let rhsName = bookGroups[rhs]?.first?.displayGroupName ?? rhs
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
            let otherItems = items.filter { !$0.isGroupedBookChapter }

            var lines: [String] = ["Sources (\(items.count)):"]

            if !bookGroupIDs.isEmpty {
                lines.append("Books (\(bookGroupIDs.count)):")
                for groupID in bookGroupIDs {
                    let chapters = (bookGroups[groupID] ?? []).sorted(by: compareBookChapterListItems)
                    let groupName = chapters.first?.displayGroupName ?? groupID
                    let totalWords = chapters.reduce(0) { $0 + $1.words }
                    lines.append("- [book] \(groupName) (book_id: \(groupID), chapters: \(chapters.count), \(totalWords) words)")
                    for chapter in chapters {
                        lines.append("  - [chapter] \(chapter.title) (id: \(chapter.id), \(chapter.words) words)")
                    }
                }
            }

            if !otherItems.isEmpty {
                if !bookGroupIDs.isEmpty { lines.append("") }
                lines.append("Other sources (\(otherItems.count)):")
                for item in otherItems {
                    lines.append(sourceListLine(for: item))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    struct MCPSourceListItem {
        let id: String
        let title: String
        let type: String
        let words: Int
        let parentGroup: String
        let displayGroupName: String
        let sortIndex: Int?
        let author: String

        var isGroupedBookChapter: Bool {
            type == "book" && !parentGroup.isEmpty
        }

        init(row: [String: Any]) {
            id = row["id"] as? String ?? ""
            title = row["title"] as? String ?? "Untitled"
            type = row["source_type"] as? String ?? ""
            words = row["word_count"] as? Int ?? 0
            parentGroup = row["parent_group"] as? String ?? ""
            displayGroupName = row["group_name"] as? String ?? parentGroup
            sortIndex = row["group_sort_index"] as? Int
            author = row["author"] as? String ?? ""
        }
    }

    func compareBookChapterListItems(_ lhs: MCPSourceListItem, _ rhs: MCPSourceListItem) -> Bool {
        if let lhsIndex = lhs.sortIndex, let rhsIndex = rhs.sortIndex, lhsIndex != rhsIndex {
            return lhsIndex < rhsIndex
        }
        if lhs.sortIndex != nil { return true }
        if rhs.sortIndex != nil { return false }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// A library source as a reply shows it: its title linked to
    /// `foreverlm://source/<id>`, the shape search_sources_semantic's rows
    /// carry. A tool result hands the model this ready-made link, so it has
    /// something to show the learner other than the id (Prompts.hiddenIDs).
    /// The title is escaped as `StudioEntityLink.markdown` escapes one, so a
    /// bracket in it cannot close the link early.
    static func sourceLink(title: String, id: String) -> String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text.isEmpty ? "Untitled" : text)](foreverlm://source/\(StudioEntityLink.encode(id)))"
    }

    func sourceListLine(for item: MCPSourceListItem) -> String {
        let groupSuffix = item.displayGroupName.isEmpty ? "" : ", \(item.displayGroupName)"
        let authorSuffix = item.author.isEmpty ? "" : ", by \(item.author)"
        return "- [\(item.type)] \(item.title) (id: \(item.id), \(item.words) words\(groupSuffix)\(authorSuffix))"
    }

    // MARK: - Shows and metadata filters

    /// One podcast show or YouTube channel as the library files it: the show
    /// name is the podcast row's `domain` (the feed's own title, the same value
    /// the Studio sidebar groups by and `set_podcast_show_hidden` takes), and a
    /// channel is the video row's `domain`.
    struct MCPShow: Hashable {
        let name: String
        let kind: String
    }

    /// Every show and channel whose episodes are in knowledge, with how many.
    ///
    /// A semantic search ranks the whole library at once, so "which Huberman
    /// episodes are about mitochondria" competes with every other mitochondria
    /// podcast for eight slots and loses episodes of the show that was asked
    /// about (2026-09-22: the Jared Rutter episode never surfaced). Naming the
    /// show exactly is what lets `filter_sources` or a `show`-scoped search
    /// answer that exhaustively.
    func listShows(kind: String?) throws -> String {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let sourceTypes: [String]
        switch normalizedKind {
        case "", "all": sourceTypes = [StudioSourceType.podcast.rawValue, StudioSourceType.video.rawValue]
        case "podcast": sourceTypes = [StudioSourceType.podcast.rawValue]
        case "youtube", "video": sourceTypes = [StudioSourceType.video.rawValue]
        default: throw MCPError.invalidInput("kind must be podcast, youtube, or all.")
        }
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let rows: [[String: Any]] = try withDB { db in
            try query(db, """
                SELECT id, source_type, domain, date_added
                FROM source_projection
                WHERE status = 'active'
                  AND source_type IN (\(sourceTypes.map { _ in "?" }.joined(separator: ", ")))
                  AND COALESCE(domain, '') != ''
            """, params: sourceTypes)
        }
        var counts: [MCPShow: Int] = [:]
        var latest: [MCPShow: Double] = [:]
        for row in rows {
            guard let id = row["id"] as? String, !excludedSourceIDs.contains(id),
                  let name = row["domain"] as? String,
                  let type = row["source_type"] as? String else { continue }
            let show = MCPShow(name: name, kind: type == StudioSourceType.video.rawValue ? "youtube" : "podcast")
            counts[show, default: 0] += 1
            latest[show] = max(latest[show] ?? 0, row["date_added"] as? Double ?? 0)
        }
        guard !counts.isEmpty else {
            return "No podcast shows or YouTube channels are in knowledge."
        }
        let shows = counts.keys.sorted { lhs, rhs in
            if counts[lhs] != counts[rhs] { return (counts[lhs] ?? 0) > (counts[rhs] ?? 0) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let day = Self.sourceFilterDayFormatter()
        var lines = ["Shows and channels (\(shows.count)), most episodes first. Pass a name exactly as written to filter_sources or to a search's show argument:"]
        for show in shows {
            let count = counts[show] ?? 0
            let last = latest[show].map { day.string(from: Date(timeIntervalSinceReferenceDate: $0)) } ?? "unknown"
            lines.append("- [\(show.kind)] \(show.name) — \(count) episode\(count == 1 ? "" : "s"), latest added \(last)")
        }
        return lines.joined(separator: "\n")
    }

    /// The source IDs of one podcast show or YouTube channel, for scoping a
    /// search or a listing to it.
    ///
    /// An exact (case-insensitive) name wins; otherwise every show whose name
    /// contains the text is taken, so "Huberman" means "Huberman Lab" and
    /// "Attia" takes both of Peter Attia's feeds. Throws with a pointer to
    /// `list_shows` when nothing matches, because an empty scope would read as
    /// "the show has nothing on this".
    func showScopedSourceIDs(_ showText: String, includeArchived: Bool = false) throws -> (names: [String], sourceIDs: Set<String>) {
        let wanted = showText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { throw MCPError.invalidInput("show must name a podcast show or YouTube channel.") }
        let rows: [[String: Any]] = try withDB { db in
            try query(db, """
                SELECT id, domain, status
                FROM source_projection
                WHERE source_type IN (?, ?) AND COALESCE(domain, '') != ''
            """, params: [StudioSourceType.podcast.rawValue, StudioSourceType.video.rawValue])
        }
        // Names resolve against every episode, archived ones included, so a
        // show whose episodes are all archived still says so rather than
        // "no such show"; the IDs are the active ones unless asked otherwise.
        let byName = Dictionary(grouping: rows.compactMap { row -> (String, String?)? in
            guard let id = row["id"] as? String, let name = row["domain"] as? String else { return nil }
            let active = (row["status"] as? String) == "active"
            return (name, active || includeArchived ? id : nil)
        }, by: { $0.0 })
        let exact = byName.keys.filter { $0.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let names = exact.isEmpty
            ? byName.keys.filter { $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            : exact
        guard !names.isEmpty else {
            throw MCPError.invalidInput("No podcast show or YouTube channel is named like '\(wanted)'. Call list_shows for the exact names.")
        }
        // The knowledge boundary every library tool draws: a muted show's
        // episodes and the families kept from AI in Settings are not in scope.
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let ids = Set(names.flatMap { byName[$0]?.compactMap { $0.1 } ?? [] }).subtracting(excludedSourceIDs)
        return (names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, ids)
    }

    /// Every source whose metadata matches, listed exhaustively.
    ///
    /// The metadata counterpart of `search_sources_keyword`: "every Huberman
    /// episode", "every paper by Martin Picard", "everything with Picard in the
    /// title or byline". A ranked search answers a topic; it is the wrong tool
    /// for a complete list, because it stops at its limit and orders by
    /// similarity. All filters are case-insensitive substrings and combine with
    /// AND.
    func filterSources(
        show: String?,
        author: String?,
        titleContains: String?,
        text: String?,
        sourceType: String?,
        includeArchived: Bool,
        limit: Int
    ) throws -> String {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let show = clean(show), author = clean(author), titleContains = clean(titleContains), text = clean(text)
        let normalizedSourceType = clean(sourceType)
        guard show != nil || author != nil || titleContains != nil || text != nil || normalizedSourceType != nil else {
            throw MCPError.invalidInput("filter_sources needs at least one of show, author, title_contains, text, or source_type.")
        }
        var sourceTypeFamily: [String] = []
        if let normalizedSourceType {
            guard let family = StudioSourceType.searchFamily(named: normalizedSourceType) else {
                throw MCPError.invalidInput("Unknown source_type '\(normalizedSourceType)'. Use one of: \(StudioSourceType.searchFamilyNames.joined(separator: ", ")).")
            }
            sourceTypeFamily = family
        }
        let scope = try show.map { try showScopedSourceIDs($0, includeArchived: includeArchived) }
        let requestedLimit = max(1, min(limit, 1000))
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)

        var predicates: [String] = []
        var params: [Any] = []
        if !includeArchived { predicates.append("sp.status = 'active'") }
        if !sourceTypeFamily.isEmpty {
            predicates.append("sp.source_type IN (\(sourceTypeFamily.map { _ in "?" }.joined(separator: ", ")))")
            params.append(contentsOf: sourceTypeFamily)
        }
        let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
        let rows: [[String: Any]] = try withDB { db in
            try query(db, """
                SELECT sp.id, sp.title, sp.source_type, sp.domain,
                       COALESCE(NULLIF(sp.author, ''), NULLIF(bk.author, ''), NULLIF(co.instructors, '')) AS author,
                       sp.journal, sp.published_year,
                       sp.word_count, sp.date_added, sp.status, sp.state,
                       COALESCE(sp.parent_group_title, sp.parent_group) AS group_name,
                       bk.subtitle AS group_subtitle
                FROM source_projection sp
                LEFT JOIN books bk ON bk.id = sp.parent_group AND sp.source_type = 'book'
                LEFT JOIN courses co ON co.id = sp.parent_group AND sp.source_type = 'course'
                \(whereClause)
                ORDER BY sp.date_added DESC
            """, params: params)
        }

        func contains(_ field: Any?, _ needle: String) -> Bool {
            guard let field = field as? String else { return false }
            return field.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let matches = rows.filter { row in
            guard let id = row["id"] as? String, !excludedSourceIDs.contains(id) else { return false }
            if let scope, !scope.sourceIDs.contains(id) { return false }
            if let author, !contains(row["author"], author) { return false }
            if let titleContains, !contains(row["title"], titleContains) { return false }
            if let text {
                let fields: [Any?] = [row["title"], row["author"], row["domain"], row["journal"], row["group_name"], row["group_subtitle"]]
                if !fields.contains(where: { contains($0, text) }) { return false }
            }
            return true
        }

        var filters: [String] = []
        if let scope { filters.append("show \(scope.names.map { "'\($0)'" }.joined(separator: " or "))") }
        if let author { filters.append("author contains '\(author)'") }
        if let titleContains { filters.append("title contains '\(titleContains)'") }
        if let text { filters.append("title, author, show or journal contains '\(text)'") }
        if let normalizedSourceType { filters.append("type \(normalizedSourceType)") }
        if !includeArchived { filters.append("archived sources left out") }
        let filterNote = filters.joined(separator: ", ")
        guard !matches.isEmpty else {
            return "No source matches \(filterNote). These filters read metadata only — for what a source's text says, use search_sources_keyword or search_sources_semantic."
        }

        // The minute, not just the day: "the latest video" among five saved the
        // same afternoon is only answerable when the order shows (2026-09-22).
        let addedAt = Self.sourceFilterMinuteFormatter()
        let shown = matches.prefix(requestedLimit)
        let countNote = matches.count > shown.count
            ? "\(matches.count) sources, showing the \(shown.count) most recently added"
            : "\(matches.count) source\(matches.count == 1 ? "" : "s")"
        var lines = ["Sources where \(filterNote) — \(countNote), newest first:"]
        for row in shown {
            let id = row["id"] as? String ?? ""
            let title = row["title"] as? String ?? "Untitled"
            let type = row["source_type"] as? String ?? ""
            var metadata = ["id: \(id)"]
            if type == StudioSourceType.podcast.rawValue || type == StudioSourceType.video.rawValue,
               let domain = row["domain"] as? String, !domain.isEmpty {
                metadata.append(domain)
            }
            if let byline = row["author"] as? String, !byline.isEmpty { metadata.append("by \(byline)") }
            if let journal = row["journal"] as? String, !journal.isEmpty { metadata.append(journal) }
            if let year = row["published_year"].map({ "\($0)" }), !year.isEmpty, year != "0" { metadata.append(year) }
            if let group = row["group_name"] as? String, !group.isEmpty { metadata.append("in \(group)") }
            let words = row["word_count"] as? Int ?? 0
            metadata.append(words > 0 ? "\(words) words" : "no text yet (\(row["state"] as? String ?? "unknown"))")
            if let added = row["date_added"] as? Double {
                metadata.append("added \(addedAt.string(from: Date(timeIntervalSinceReferenceDate: added)))")
            }
            if (row["status"] as? String) == "archived" { metadata.append("archived") }
            lines.append("- [\(type)] \(title) (\(metadata.joined(separator: ", ")))")
        }
        return lines.joined(separator: "\n")
    }

    static func sourceFilterMinuteFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    static func sourceFilterDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    func getSourceContent(_ sourceID: String) throws -> String {
        try loadSourceContentResponse(sourceID).response
    }

    /// `get_source_content` as an assistant calls it: the text, and today's chat
    /// activity for the source. The tool shares the store gate as a reader, so
    /// its one write goes through the storage actor's own connection. Run as a
    /// transaction on the cached connection, a second reader's call at the same
    /// moment began its own inside it and failed.
    func getSourceContent(_ sourceID: String, recordChatActivity: Bool) async throws -> String {
        let loaded = try loadSourceContentResponse(sourceID)
        if recordChatActivity, let resolvedSourceID = loaded.resolvedSourceID {
            _ = try await notebookFileStorage.recordScheduledSourceActivity(
                sourceID: resolvedSourceID,
                on: Date(),
                kind: .chat
            )
        }
        return loaded.response
    }

    /// The text `get_source_content` answers with, and the library id it
    /// resolved when the source is one the learner lets AI read.
    private func loadSourceContentResponse(_ sourceID: String) throws -> (response: String, resolvedSourceID: String?) {
        // Search results also carry a shortened citation token. Resolve exact ids
        // and unique prefixes through the same deterministic path as Chat links,
        // so a model cannot turn a valid search result into "Source not found".
        guard let resolvedSourceID = try knowledgeStore().resolveSourceID(forLinkToken: sourceID) else {
            return ("Source not found. Search the library again and use the returned source.", nil)
        }
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !KnowledgeStore.isBlockedFromOpening(resolvedSourceID, excluded: excludedSourceIDs) else {
            return ("Source is excluded from knowledge search and AI in ForeverLM Settings. Include its source family there before loading it.", nil)
        }
        let response: String = try withDB { db in
            let rows = try query(db, """
                SELECT sp.title, sp.source_type, sp.author, sp.word_count, sp.url, sp.local_file_path,
                       sp.book_page_start, sp.book_page_count,
                       COALESCE(sp.is_paywalled, 0) as is_paywalled, sc.content
                FROM source_projection sp
                LEFT JOIN source_content sc ON sp.id = sc.source_id
                WHERE sp.id = ?
            """, params: [resolvedSourceID])
            guard let r = rows.first else { throw MCPError.notFound("Source not found. Search the library again and use the returned source.") }
            let title = r["title"] as? String ?? "Untitled"
            let type = r["source_type"] as? String ?? ""
            let words = r["word_count"] as? Int ?? 0
            let url = r["url"] as? String ?? ""
            let localPath = r["local_file_path"] as? String
            let isPaywalled = (r["is_paywalled"] as? Int ?? 0) != 0
            var content = r["content"] as? String
            var contentIsPersistedCanonical = content?.isEmpty == false
            let googleDocsResource = URL(string: url).flatMap(SourceService.googleDocsResource(from:))

            if googleDocsResource != nil,
               let storedContent = content,
               SourceService.isGoogleDocsInterfaceContent(storedContent) {
                content = nil
                contentIsPersistedCanonical = false
            }

            // If no stored content, try extracting from local file on the fly
            if type != "paper", content == nil || content?.isEmpty == true {
                if let path = localPath ?? (url.hasPrefix("/") ? url : nil) {
                    content = Self.extractTextFromLocalFile(path, pages: Self.bookPages(r))
                    contentIsPersistedCanonical = false
                }
            }

            // For podcasts: try raw TTML transcript
            if (content == nil || content?.isEmpty == true) && type == "podcast" {
                let ttmlRows = try query(db, "SELECT raw_ttml FROM podcasts WHERE source_id = ?", params: [resolvedSourceID])
                if let ttml = ttmlRows.first?["raw_ttml"] as? String, !ttml.isEmpty {
                    content = try? SourceService.extractTextFromTTMLContent(ttml)
                    contentIsPersistedCanonical = false
                }
            }

            // For non-paywalled web articles: return URL so Claude can fetch the content itself
            let isWebURL = url.hasPrefix("http://") || url.hasPrefix("https://")
            if let googleDocsResource, content == nil || content?.isEmpty == true {
                return """
                # \(title)
                Type: \(type) | Words: 0 | URL: \(url)

                \(googleDocsResource.kind.label) content is not loaded. Retry this source in ForeverLM so it can use Google's text export. The file must be link-accessible (Anyone with the link) — ForeverLM holds no Google Drive connection, so private files cannot be fetched.
                """
            }
            if isWebURL && !isPaywalled && type == "article" && (content == nil || content?.isEmpty == true) {
                return "# \(title)\nType: \(type) | Words: \(words) | URL: \(url)\n\nThis article is publicly accessible. Fetch the URL above for full content."
            }

            let wordDisplay = content.map { $0.split(separator: " ").count } ?? words
            let revision = contentIsPersistedCanonical
                ? content.map(PaperContentPreparationService.sha256)
                : nil
            let revisionLine = revision.map { "\ncontent_sha256: \($0)" } ?? ""
            // A PDF's page boundaries become `[page N]` lines here, after the
            // revision was taken from the stored text, so a citation can name
            // the page a passage sits on (`?page=N`) while `content_sha256`
            // still describes the text on disk.
            let shownContent = content.map(PDFPageMarkers.labeled)
            return "# \(title)\nType: \(type) | Words: \(wordDisplay)\(isWebURL ? " | URL: \(url)" : "")\(revisionLine)\n\n\(shownContent ?? "(No content available)")"
        }
        return (response, resolvedSourceID)
    }

    /// Persist a caller-generated review curriculum against the exact canonical
    /// source revision it was generated from. The storage layer rechecks the hash
    /// in the write transaction, clears the durable generation queue, and records
    /// the Source change for CloudKit; MCP never writes the derived table directly.
    func saveSourceReviewGuide(
        sourceID: String,
        expectedContentSHA256: String,
        guide: String
    ) throws -> String {
        let trimmedSourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpectedSHA256 = expectedContentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedGuide = guide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceID.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard trimmedExpectedSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw MCPError.invalidInput("content_sha256 must be the 64-character value returned by get_source_content.")
        }
        guard !trimmedGuide.isEmpty else { throw MCPError.invalidInput("guide is required.") }
        guard trimmedGuide.utf8.count <= 64 * 1024 else {
            throw MCPError.invalidInput("guide must be 64 KB or smaller.")
        }

        let candidate: SourceReviewGuideCandidate = try withDB { db in
            let rows = try query(db, """
                SELECT sp.title, sp.source_type, sc.content
                FROM source_projection sp
                JOIN source_content sc ON sc.source_id = sp.id
                WHERE sp.id = ?
                LIMIT 1
            """, params: [trimmedSourceID])
            guard let row = rows.first else {
                throw MCPError.notFound("Source not found or canonical text is unavailable: \(trimmedSourceID)")
            }
            let title = row["title"] as? String ?? "Untitled"
            let sourceType = StudioSourceType(
                rawValue: row["source_type"] as? String ?? ""
            ) ?? .unclassified
            let content = row["content"] as? String ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidInput("Source \(trimmedSourceID) has no canonical text to bind a review guide to.")
            }
            let currentSHA256 = PaperContentPreparationService.sha256(content)
            guard currentSHA256 == trimmedExpectedSHA256 else {
                throw MCPError.invalidInput(
                    "Source \(trimmedSourceID) changed after the review guide was generated. Call get_source_content again and regenerate the guide from the current text."
                )
            }
            return SourceReviewGuideCandidate(
                sourceID: trimmedSourceID,
                sourceType: sourceType,
                title: title,
                content: content,
                sourceSHA256: currentSHA256,
                attemptCount: 0
            )
        }

        try knowledgeStore().applySourceReviewGuide(candidate: candidate, guide: trimmedGuide)
        return "Saved Source Review Guide for '\(candidate.title)'."
    }

    func listMeetingGroups() throws -> String {
        // Screen record mode (admin only): a folder is listed only with a
        // session on screen, and counts only those. Nil scope lists every one.
        let screenScope = screenRecordScope()
        let hiddenSessions = try screenRecordHiddenSourceIDs(scope: screenScope)
        return try withDB { db in
            let rows = try query(db, """
                SELECT mg.id, mg.title, mg.drive_folder_url, mg.local_folder_path, mg.recurrence_rule,
                       COUNT(DISTINCT s.id) AS session_count,
                       GROUP_CONCAT(DISTINCT s.id) AS session_ids
                FROM meeting_groups mg
                LEFT JOIN group_members gm ON gm.group_id = mg.id
                LEFT JOIN sources s ON s.id = gm.source_id AND s.source_type = 'meeting' AND s.status = 'active'
                WHERE mg.is_hidden = 0
                GROUP BY mg.id, mg.title, mg.drive_folder_url, mg.local_folder_path, mg.recurrence_rule
                ORDER BY mg.title
            """)
            let folderImages = StudioViewModel.meetingFolderImageURLsFromDefaults()
            let groups: [[String: Any]] = rows.compactMap { row in
                let id = row["id"] as? String ?? ""
                let title = row["title"] as? String ?? id
                var count = row["session_count"] as? Int ?? 0
                if screenScope != nil {
                    let sessions = (row["session_ids"] as? String ?? "")
                        .split(separator: ",").map(String.init)
                    count = sessions.filter { !hiddenSessions.contains($0) }.count
                    if count == 0 { return nil }
                }
                let driveURL = row["drive_folder_url"] as? String ?? ""
                let localPath = row["local_folder_path"] as? String ?? ""
                let recurrence = row["recurrence_rule"] as? String ?? ""
                let image = folderImages[id] ?? ""
                var group: [String: Any] = [
                    "group_id": id,
                    "title": title,
                    "session_count": count,
                ]
                if !recurrence.isEmpty { group["recurrence_rule"] = recurrence }
                if !driveURL.isEmpty { group["drive_folder_url"] = driveURL }
                if !localPath.isEmpty { group["local_folder_path"] = localPath }
                if !image.isEmpty { group["image_url"] = image }
                return group
            }
            return try jsonString([
                "meeting_groups": groups,
                "count": groups.count,
            ] as [String: Any])
        }
    }

    func getMeetingGroup(_ groupID: String) throws -> String {
        let trimmed = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPError.invalidInput("group_id is required.") }
        return try withDB { db in
            let groupRows = try query(db, """
                SELECT id, title, drive_folder_url, local_folder_path, recurrence_rule, timezone
                FROM meeting_groups
                WHERE id = ?
                LIMIT 1
            """, params: [trimmed])
            guard let group = groupRows.first else {
                throw MCPError.notFound(
                    "Meeting group not found: \(trimmed). Call list_meeting_groups for current group_id values."
                )
            }
            let title = group["title"] as? String ?? trimmed
            var payload: [String: Any] = [
                "group_id": trimmed,
                "title": title,
            ]
            if let recurrence = group["recurrence_rule"] as? String, !recurrence.isEmpty { payload["recurrence_rule"] = recurrence }
            if let timezone = group["timezone"] as? String, !timezone.isEmpty { payload["timezone"] = timezone }
            if let drive = group["drive_folder_url"] as? String, !drive.isEmpty { payload["drive_folder_url"] = drive }
            if let local = group["local_folder_path"] as? String, !local.isEmpty { payload["local_folder_path"] = local }
            if let image = StudioViewModel.meetingFolderImageURLsFromDefaults()[trimmed] { payload["image_url"] = image }

            let sessions = try query(db, """
                SELECT sp.id, sp.title, sp.date_added, sp.word_count, sp.state, sp.error_message
                FROM source_projection sp
                WHERE sp.source_type = 'meeting' AND sp.parent_group = ? AND sp.status = 'active'
                ORDER BY sp.date_added DESC, sp.title
            """, params: [trimmed])
            let sessionPayloads: [[String: Any]] = try sessions.map { session in
                let sourceID = session["id"] as? String ?? ""
                let sessionTitle = session["title"] as? String ?? "Untitled"
                let words = session["word_count"] as? Int ?? 0
                let state = session["state"] as? String ?? ""
                let error = session["error_message"] as? String ?? ""
                let artifacts = try query(db, """
                    SELECT kind, title, COALESCE(url, local_file_path, '') AS locator
                    FROM meeting_artifacts
                    WHERE source_id = ?
                    ORDER BY sort_index, title
                """, params: [sourceID])
                let artifactPayloads: [[String: Any]] = artifacts.map { artifact in
                    var value: [String: Any] = [
                        "kind": artifact["kind"] as? String ?? "attachment",
                        "title": artifact["title"] as? String ?? "",
                    ]
                    if let locator = artifact["locator"] as? String, !locator.isEmpty {
                        value["locator"] = locator
                    }
                    return value
                }
                var value: [String: Any] = [
                    "source_id": sourceID,
                    "title": sessionTitle,
                    "word_count": words,
                    "state": state,
                    "artifacts": artifactPayloads,
                ]
                if let dateAdded = session["date_added"] { value["date_added"] = dateAdded }
                if !error.isEmpty { value["error_message"] = error }
                return value
            }
            payload["sessions"] = sessionPayloads
            payload["session_count"] = sessionPayloads.count
            return try jsonString(payload)
        }
    }

    /// Point one meeting folder's sidebar tile at an image, exactly as
    /// "Set Folder Image…" in the meetings context menu does.
    ///
    /// Writes through `PreferenceStore` rather than `UserDefaults` directly, so the
    /// choice reaches all three places the menu item puts it: the defaults the
    /// sidebar reads, the `user_preferences` row that survives a rebuild, and the
    /// CloudKit outbox that carries it to the learner's other devices. The
    /// `foreverLMDataDidChange` post every mutating tool makes is what re-reads it
    /// into an open window, so the tile changes while the learner is looking at it.
    func setMeetingFolderImage(groupID: String, imageURL: String?) throws -> String {
        let trimmedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw MCPError.invalidInput("group_id is required.") }

        let title: String = try withDB { db in
            let rows = try query(
                db,
                "SELECT title FROM meeting_groups WHERE id = ? LIMIT 1",
                params: [trimmedID]
            )
            guard let row = rows.first else {
                throw MCPError.invalidInput(
                    "Meeting group not found: \(trimmedID). Call list_meeting_groups for the group ids — a meeting folder's id is not its title."
                )
            }
            return row["title"] as? String ?? trimmedID
        }

        let key = Prefs.Families.meetingFolderImage.key(trimmedID)
        guard let resolved = try Self.resolvedMeetingFolderImage(imageURL) else {
            Preferences.reset(key)
            return try jsonString([
                "updated": true,
                "group_id": trimmedID,
                "title": title,
                "image_url": NSNull(),
                "reach": "default_icon",
            ] as [String: Any])
        }

        Preferences.set(resolved, for: key)
        return try jsonString([
            "updated": true,
            "group_id": trimmedID,
            "title": title,
            "image_url": resolved,
            "reach": resolved.hasPrefix("file:") ? "this_mac" : "account",
        ] as [String: Any])
    }

    // MARK: - Settings › Sources (MCP/UI parity)

    /// The id an assistant names a source family by. A tab's raw value is the
    /// title Settings shows ("YouTube", "X"), so the id is a lowercase word a
    /// caller can type; both spellings are accepted on the way in.
    static func sourceFamilyID(_ tab: StudioSidebarTab) -> String {
        switch tab {
        case .articles: return "articles"
        case .papers: return "papers"
        case .books: return "books"
        case .meetings: return "meetings"
        case .podcasts: return "podcasts"
        case .videos: return "youtube"
        case .xPosts: return "x"
        }
    }

    /// Every family id, in the enum's order — the schema enum for `family`.
    static let sourceFamilyIDs: [String] = StudioSidebarTab.allCases.map(sourceFamilyID)

    static func sourceFamilyTab(_ raw: String) throws -> StudioSidebarTab {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = sourceFamilyIDs.joined(separator: ", ")
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("family is required. One of: \(choices).")
        }
        if let tab = StudioSidebarTab.allCases.first(where: {
            sourceFamilyID($0).caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return tab
        }
        if let tab = StudioSidebarTab.fromPersistedRawValue(trimmed) { return tab }
        throw MCPError.invalidInput("Unknown source family: \(trimmed). One of: \(choices).")
    }

    /// The Settings › Sources pane as stored: the same four preferences the
    /// pane's switches read and write, loaded from `UserDefaults` the way
    /// `StudioViewModel` seeds them.
    struct SourceFamilySettings {
        var order: [StudioSidebarTab]
        var hidden: Set<StudioSidebarTab>
        var excludedFromKnowledge: Set<StudioSidebarTab>
        var autoUnpinnedIntegrationTabs: Set<StudioSidebarTab>

        static func load(from defaults: UserDefaults = .standard) -> SourceFamilySettings {
            func tabs(_ key: String) -> Set<StudioSidebarTab> {
                Set((defaults.stringArray(forKey: key) ?? []).compactMap(StudioSidebarTab.fromPersistedRawValue))
            }
            let rawOrder = defaults.stringArray(forKey: Prefs.Studio.tabOrder.name) ?? []
            return SourceFamilySettings(
                order: StudioSidebarTab.reconciledOrder(rawOrder.compactMap(StudioSidebarTab.fromPersistedRawValue)),
                hidden: tabs(Prefs.Studio.hiddenTabs.name),
                excludedFromKnowledge: StudioSidebarTab.excludedKnowledgeTabs(in: defaults),
                autoUnpinnedIntegrationTabs: tabs(Prefs.Studio.integrationTabsUnpinnedByDefault.name)
            )
        }

        var visible: [StudioSidebarTab] { order.filter { !hidden.contains($0) } }

        /// Mirrors `StudioViewModel.canUnpinTab`: the tab bar keeps at least one
        /// pinned family, so the last one stays put.
        func canUnpin(_ tab: StudioSidebarTab) -> Bool {
            hidden.contains(tab) || visible.count > 1
        }

        func row(_ tab: StudioSidebarTab) -> [String: Any] {
            [
                "family": MCPDataStore.sourceFamilyID(tab),
                "label": tab.rawValue,
                "include_in_search_and_ai": !excludedFromKnowledge.contains(tab),
                "pinned": !hidden.contains(tab),
                "can_unpin": canUnpin(tab),
            ]
        }

        func payload() -> [String: Any] {
            [
                "settings_pane": "Settings › Sources",
                "families": order.map(row),
                "tab_order": order.map(MCPDataStore.sourceFamilyID),
                "reach": "account",
            ]
        }
    }

    /// AI Usage › API keys, read. The payload never carries the
    /// key: a plugin learns which router bills the learner and the key's
    /// last four characters, which is what the pane shows too.
    func getOwnRouterKey() throws -> String {
        try jsonString(Self.ownRouterKeyPayload(changed: nil))
    }

    /// The router carries its own scope: OpenRouter serves text and also the
    /// text-to-speech voices and speech-to-text models ForeverLM routes through
    /// it. A single "text models" line here once told a plugin that wrong.
    static func ownRouterKeyPayload(changed: Bool?) -> [String: Any] {
        var payload: [String: Any] = [
            "routers": ManagedAI.OwnKeyRouter.allCases.map { router in
                [
                    "id": router.rawValue,
                    "label": router.label,
                    "keys_url": router.keysURL.absoluteString,
                    "key_pays_for": router.billedScope,
                ] as [String: Any]
            },
            // Bring your own key since 2026-09-25. The key runs AI features
            // for every signed-in account; only MCP is paid for.
        ]
        if let own = ManagedAI.ownKey {
            payload["configured"] = true
            payload["router"] = own.router.rawValue
            payload["router_label"] = own.router.label
            payload["key_suffix"] = own.suffix
            payload["key_pays_for"] = own.router.billedScope
            payload["billed_to"] = "\(own.router.label) account"
            // The key pays for every model since realtime voice, the one
            // thing OpenRouter could not serve, went on 2026-10-01.
            payload["balance_still_pays_for"] = "nothing while the key is stored"
        } else {
            payload["configured"] = false
            payload["router"] = NSNull()
            payload["key_suffix"] = NSNull()
            payload["key_pays_for"] = NSNull()
            payload["billed_to"] = "leftover ForeverLM balance, while any is left; AI features otherwise need the learner's own OpenRouter key"
            payload["balance_still_pays_for"] = "every AI request, while any is left"
        }
        if let changed { payload["changed"] = changed }
        return payload
    }

    /// AI Usage › API keys, written: what pasting a key into the
    /// pane, or pressing Remove, does. The write goes through `ManagedAI`, so
    /// the Keychain, the in-memory routing snapshot, the "balance is empty"
    /// flag and the change notification all move together; the open AI Usage
    /// pane re-reads on that notification.
    func setOwnRouterKey(router rawRouter: String, key: String?, clear: Bool) throws -> String {
        guard let router = ManagedAI.OwnKeyRouter(rawValue: rawRouter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw MCPError.invalidInput(
                "router must be one of \(ManagedAI.OwnKeyRouter.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        let before = ManagedAI.ownKey
        if clear {
            guard key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
                throw MCPError.invalidInput("Pass either key or clear: true, not both.")
            }
            ManagedAI.setOwnKey(nil, router: router)
        } else {
            let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                throw MCPError.invalidInput("Pass key to store one for \(router.label), or clear: true to remove the stored key.")
            }
            // The proxy refuses anything else before it reaches the router; the
            // same shape check here keeps a paste error from being stored.
            guard trimmed.count >= 8, trimmed.count <= 512,
                  trimmed.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else {
                throw MCPError.invalidInput("That does not look like a \(router.label) API key: expected 8–512 printable ASCII characters with no spaces.")
            }
            ManagedAI.setOwnKey(trimmed, router: router)
        }
        return try jsonString(Self.ownRouterKeyPayload(changed: ManagedAI.ownKey != before))
    }

    // MARK: - Zoom recordings only Zoom can convert

    /// The waiting recordings as the Meetings tab and Settings › Sources list
    /// them, from the same scan (`zoomLocalRecordingsNeedingConversion`), with
    /// the title recovered through the library's series the way the row's is.
    func listUnconvertedZoomRecordings() async throws -> String {
        let (recordings, ignored) = try await Self.unconvertedZoomRecordings(knownTitles: try meetingSeriesTitles())
        let formatter = KnowledgeStore.iso8601Formatter
        let rows: [[String: Any]] = recordings.map { recording in
            var row: [String: Any] = [
                "folder_path": recording.folder.path,
                "title": recording.title,
                "folder_topic": recording.folder.folderTopic,
                "started_at": formatter.string(from: recording.folder.startedAt),
                "last_written_at": formatter.string(from: recording.folder.modifiedAt),
                "ignored": ignored.contains(recording.folder.path),
            ]
            if let raw = recording.folder.unconvertedPath,
               let bytes = (try? FileManager.default.attributesOfItem(atPath: raw))?[.size] as? Int {
                row["raw_bytes"] = bytes
            }
            return row
        }
        return try jsonString([
            "folders": StudioViewModel.zoomLocalTranscriptRoots(homeDir: BookmarkAccessManager.realHomeDirectory),
            "recordings": rows,
            "count": rows.count,
            // Whether ForeverLM may answer Zoom's unknown-source dialog, and so
            // converts waiting recordings by itself.
            "converts_automatically": AXIsProcessTrusted(),
        ])
    }

    /// The row's two buttons, as words. `convert` opens only a folder the scan
    /// itself listed — a client path is matched against that list, never
    /// opened — so the tool cannot be made to open an arbitrary file in Zoom.
    func resolveUnconvertedZoomRecording(folderPath: String, action: String) async throws -> String {
        let (recordings, ignored) = try await Self.unconvertedZoomRecordings(knownTitles: try meetingSeriesTitles())
        let wanted = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath).standardizedFileURL.path
        guard let recording = recordings.first(where: {
            URL(fileURLWithPath: $0.folder.path).standardizedFileURL.path == wanted
        }) else {
            throw MCPError.invalidInput(
                "No Zoom recording waiting for conversion at \(folderPath). Pass folder_path from list_unconverted_zoom_recordings; a recording Zoom converted, or wrote in the last fifteen minutes, is not listed."
            )
        }
        var payload: [String: Any] = [
            "folder_path": recording.folder.path,
            "title": recording.title,
            "action": action,
        ]
        switch action {
        case "convert":
            let opened = await MainActor.run { StudioViewModel.openZoomLocalRecordingInZoom(recording.folder, activate: true) }
            guard opened else {
                throw MCPError.invalidInput(
                    "Nothing on this Mac opens .zoom files; Zoom is not installed or does not claim them. The recording stays unconverted."
                )
            }
            payload["opened_in_zoom"] = true
            payload["answers_zoom"] = AXIsProcessTrusted()
            payload["next"] = AXIsProcessTrusted()
                ? "Zoom asks whether to convert files from an unknown source and ForeverLM answers Convert Anyway itself; ForeverLM files the recording as a session of its series and transcribes it once the converted media is in the folder."
                : "Zoom asks the learner whether to convert files from an unknown source, then converts; ForeverLM files the recording as a session of its series and transcribes it once the converted media is in the folder. Allowing ForeverLM under System Settings › Privacy & Security › Accessibility lets it answer Zoom itself."
        case "ignore", "unignore":
            var folders = ignored
            let changed = action == "ignore"
                ? folders.insert(recording.folder.path).inserted
                : folders.remove(recording.folder.path) != nil
            if changed { StudioViewModel.saveZoomLocalRecordingIgnoredFolders(folders) }
            payload["ignored"] = action == "ignore"
            payload["changed"] = changed
        default:
            throw MCPError.invalidInput("action must be convert, ignore or unignore.")
        }
        return try jsonString(payload)
    }

    /// The scan the watcher runs, off the store's thread: it is directory
    /// listings, not SQL.
    private static func unconvertedZoomRecordings(
        knownTitles: [String]
    ) async throws -> (recordings: [StudioViewModel.ZoomLocalRecordingAwaitingConversion], ignored: Set<String>) {
        let roots = StudioViewModel.zoomLocalTranscriptRoots(homeDir: BookmarkAccessManager.realHomeDirectory)
        return await Task.detached(priority: .utility) {
            let folders = StudioViewModel.zoomLocalRecordingFolders(roots: roots)
            let captions = StudioViewModel.zoomLocalTranscriptFiles(roots: roots)
            let recordings = StudioViewModel.zoomLocalRecordingsNeedingConversion(folders, captions: captions).map {
                StudioViewModel.ZoomLocalRecordingAwaitingConversion(
                    folder: $0,
                    title: StudioViewModel.zoomLocalRecordingTopic(folderTopic: $0.folderTopic, knownTitles: knownTitles)
                )
            }
            return (recordings, StudioViewModel.zoomLocalRecordingIgnoredFoldersFromDefaults())
        }.value
    }

    private func meetingSeriesTitles() throws -> [String] {
        try withDB { db in
            try query(db, "SELECT title FROM meeting_groups WHERE title IS NOT NULL")
                .compactMap { $0["title"] as? String }
        }
    }

    /// Settings › Sources, read: every family's Search & AI and Tab switches.
    func getSourceSettings() throws -> String {
        try jsonString(Self.SourceFamilySettings.load().payload())
    }

    /// Settings › Sources, written: exactly what flipping the pane's switches
    /// does. `include_in_search_and_ai` is the per-family knowledge boundary
    /// (`StudioViewModel.excludedKnowledgeTabs`); `pinned` is whether the
    /// family's tab is on the tab bar (`hiddenTabs`, through `showTab` /
    /// `hideTab`, whose one rule — the bar keeps at least one tab — holds here
    /// too). Writes go through `PreferenceStore`, so the choice reaches the
    /// defaults the app reads, the `user_preferences` row that survives a
    /// rebuild, and the CloudKit outbox to the learner's other devices; the
    /// pending write is flushed before the `foreverLMDataDidChange` post
    /// re-reads preferences into the open window, so the store cannot hand
    /// back the old value.
    func setSourceSettings(family: String, includeInSearchAndAI: Bool?, pinned: Bool?) async throws -> String {
        let tab = try Self.sourceFamilyTab(family)
        guard includeInSearchAndAI != nil || pinned != nil else {
            throw MCPError.invalidInput(
                "Pass include_in_search_and_ai, pinned, or both; nothing to change for \(Self.sourceFamilyID(tab))."
            )
        }
        var settings = Self.SourceFamilySettings.load()
        var changed: [String] = []

        if let includeInSearchAndAI {
            let wasIncluded = !settings.excludedFromKnowledge.contains(tab)
            if includeInSearchAndAI != wasIncluded {
                if includeInSearchAndAI {
                    settings.excludedFromKnowledge.remove(tab)
                } else {
                    settings.excludedFromKnowledge.insert(tab)
                }
                Preferences.set(
                    settings.excludedFromKnowledge.map(\.rawValue).sorted(),
                    for: Prefs.Studio.excludedKnowledgeSourceTabs
                )
                changed.append("include_in_search_and_ai")
            }
        }

        if let pinned {
            let wasPinned = !settings.hidden.contains(tab)
            if pinned != wasPinned {
                if pinned {
                    settings.hidden.remove(tab)
                } else {
                    guard settings.canUnpin(tab) else {
                        throw MCPError.invalidInput(
                            "\(tab.rawValue) is the only pinned source family; the tab bar keeps at least one. Pin another family first."
                        )
                    }
                    settings.hidden.insert(tab)
                }
                Preferences.set(settings.hidden.map(\.rawValue).sorted(), for: Prefs.Studio.hiddenTabs)
                // Either way the tab is the learner's call from now on, exactly
                // as showTab/hideTab record it: Studio must not pin an
                // integration tab back on its own after this.
                if settings.autoUnpinnedIntegrationTabs.remove(tab) != nil {
                    Preferences.set(
                        settings.autoUnpinnedIntegrationTabs.map(\.rawValue).sorted(),
                        for: Prefs.Studio.integrationTabsUnpinnedByDefault
                    )
                }
                changed.append("pinned")
            }
        }

        await PreferenceStore.flushPendingWrites()

        var payload = settings.row(tab)
        payload["updated"] = !changed.isEmpty
        payload["changed"] = changed
        payload["settings_pane"] = "Settings › Sources"
        payload["reach"] = "account"
        return try jsonString(payload)
    }

    // MARK: - Read state and meeting series (MCP/UI parity)

    /// The reader's Mark as Read, for the source types that track one; for a
    /// video, the sidebar's Mark as Watched and Mark as Not Watched.
    func setSourceRead(sourceID: String, read: Bool) throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let article = try store.loadSourceForSync(id) else {
            throw MCPError.notFound("Source not found: \(id). Call list_sources for the current ids.")
        }
        if article.offersWatchedMarks {
            return try setVideoWatched(article, watched: read, in: store)
        }
        guard article.supportsReadTracking else {
            throw MCPError.invalidInput(
                "‘\(article.title)’ is a \(article.sourceType.rawValue) source; only web articles, papers and videos track a read state."
            )
        }
        let readAt: Date? = read ? Date() : nil
        try store.updateSourceReadAt(sourceID: id, readAt: readAt)
        return try jsonString([
            "status": "updated",
            "source_id": id,
            "title": article.title,
            "is_read": read,
            "read_at": readAt.map { KnowledgeStore.iso8601Formatter.string(from: $0) as Any } ?? NSNull(),
            "message": read ? "Marked ‘\(article.title)’ as read." : "Marked ‘\(article.title)’ as unread.",
        ] as [String: Any])
    }

    /// `set_source_read` on a video: read is watched. Not watched clears the
    /// watch progress, in a way every device honours, and any read stamp;
    /// watched finishes a video the Reader has played, since it needs the
    /// video's length. Either answers a video already as asked without a write.
    private func setVideoWatched(_ article: StudioArticle, watched: Bool, in store: KnowledgeStore) throws -> String {
        let progress = VideoWatchProgress(encoded: article.readingPositionLocator)
        let isWatched = article.isRead || progress?.isEssentiallyWatched == true
        if watched, !isWatched, progress?.markedWatched() == nil {
            throw MCPError.invalidInput(
                "ForeverLM doesn't know how long ‘\(article.title)’ is yet: it learns a video's length the first time the video plays in the Reader, and only then can it be marked watched."
            )
        }
        let mark: VideoWatchedMark
        if watched, isWatched {
            mark = VideoWatchedMark(locator: article.readingPositionLocator, readAt: article.readAt, changed: false)
        } else {
            mark = try store.setVideoWatched(sourceID: article.id, watched: watched)
        }
        let label = watched ? "watched" : "not watched"
        return try jsonString([
            "status": mark.changed ? "updated" : "unchanged",
            "source_id": article.id,
            "title": article.title,
            "is_watched": watched,
            "read_at": mark.readAt.map { KnowledgeStore.iso8601Formatter.string(from: $0) as Any } ?? NSNull(),
            "message": mark.changed
                ? "Marked ‘\(article.title)’ as \(label)."
                : "‘\(article.title)’ was already \(label).",
        ] as [String: Any])
    }

    /// The meeting group row behind a group_id, or the error every meeting tool
    /// gives for an id that is not one.
    private func requireMeetingGroup(_ groupID: String, argument: String) throws -> (id: String, title: String) {
        let trimmed = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPError.invalidInput("\(argument) is required.") }
        return try withDB { db in
            let rows = try query(db, "SELECT id, title FROM meeting_groups WHERE id = ? LIMIT 1", params: [trimmed])
            guard let row = rows.first else {
                throw MCPError.notFound(
                    "Meeting group not found: \(trimmed). Call list_meeting_groups for the group ids — a meeting folder's id is not its title."
                )
            }
            return (trimmed, row["title"] as? String ?? trimmed)
        }
    }

    private func meetingSessionCount(groupID: String) throws -> Int {
        try withDB { db in
            let rows = try query(db, """
                SELECT COUNT(*) AS n FROM source_projection
                WHERE source_type = 'meeting' AND parent_group = ? AND status = 'active'
            """, params: [groupID])
            return (rows.first?["n"] as? Int64).map(Int.init) ?? (rows.first?["n"] as? Int ?? 0)
        }
    }

    /// Dropping one meeting folder onto another in Sources.
    func mergeMeetingGroups(sourceGroupID: String, targetGroupID: String) throws -> String {
        let source = try requireMeetingGroup(sourceGroupID, argument: "source_group_id")
        let target = try requireMeetingGroup(targetGroupID, argument: "target_group_id")
        guard source.id != target.id else {
            throw MCPError.invalidInput("source_group_id and target_group_id name the same meeting group.")
        }
        let moved = try meetingSessionCount(groupID: source.id)
        try knowledgeStore().mergeMeetingGroup(source.id, into: target.id)
        return try jsonString([
            "status": "merged",
            "source_group_id": source.id,
            "source_title": source.title,
            "target_group_id": target.id,
            "target_title": target.title,
            "sessions_moved": moved,
            "sessions_in_target": try meetingSessionCount(groupID: target.id),
            "message": "Merged ‘\(source.title)’ into ‘\(target.title)’. Its id keeps resolving to the merged folder.",
        ] as [String: Any])
    }

    /// The series' Merge Same-Day Sessions: one sitting, one session
    /// (`KnowledgeStore+MeetingSessionMerge`). Goes through the StorageService
    /// so the absorbed sessions leave the search indexes and the change is
    /// queued for sync, as the sidebar's does; the survivor's action items are
    /// then read again, exactly as after the automatic fold.
    func mergeMeetingSessions(groupID: String?, date: String?, sourceIDs: [String]?) async throws -> String {
        let store = try knowledgeStore()
        var outcomes: [MeetingSessionMergeOutcome] = []
        var scope: [String: Any] = [:]

        let explicitIDs = (sourceIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !explicitIDs.isEmpty {
            guard Set(explicitIDs).count >= 2 else {
                throw MCPError.invalidInput("source_ids needs at least two distinct session ids to merge.")
            }
            do {
                if let outcome = try await notebookFileStorage.mergeMeetingSessions(explicitIDs) {
                    outcomes.append(outcome)
                }
            } catch let error as KnowledgeStoreError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            scope["source_ids"] = explicitIDs
        } else {
            let trimmedGroup = (groupID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedGroup.isEmpty else {
                throw MCPError.invalidInput("Pass group_id (with an optional date) or source_ids.")
            }
            guard let resolved = try store.resolvedMeetingGroupID(matching: trimmedGroup) else {
                throw MCPError.notFound(
                    "Meeting group not found: \(trimmedGroup). Call list_meeting_groups for the group ids — a meeting folder's id is not its title."
                )
            }
            var day: String?
            if let raw = date?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                guard DayPlan.isValidDateString(raw) else {
                    throw MCPError.invalidInput("date must be a local day formatted YYYY-MM-DD (got \"\(raw)\").")
                }
                day = raw
            }
            outcomes = try await notebookFileStorage.mergeSameDayMeetingSessions(groupID: resolved, date: day)
            scope["group_id"] = resolved
            scope["group_title"] = try store.loadMeetingGroups()[resolved]?.title ?? resolved
            if let day { scope["date"] = day }
        }

        for outcome in outcomes {
            MeetingActionItemExtractor.shared.noteSessionsMerged(survivorID: outcome.survivorID)
        }
        let merges: [[String: Any]] = outcomes.map { outcome in
            [
                "date": outcome.date,
                "group_id": outcome.groupID,
                "survivor_id": outcome.survivorID,
                "survivor_title": outcome.survivorTitle,
                "absorbed_ids": outcome.absorbedIDs,
                "sessions_merged": outcome.absorbedIDs.count + 1,
            ]
        }
        let folded = outcomes.reduce(0) { $0 + $1.absorbedIDs.count }
        var result = scope
        result["status"] = outcomes.isEmpty ? "nothing_to_merge" : "merged"
        result["merges"] = merges
        result["sessions_folded"] = folded
        result["message"] = outcomes.isEmpty
            ? "Nothing to merge: every day already has one session."
            : "Folded \(folded) session\(folded == 1 ? "" : "s") into \(outcomes.count) sitting\(outcomes.count == 1 ? "" : "s"). The surviving session keeps its id; the others are archived and their files, blocks and links now name the survivor."
        return try jsonString(result)
    }

    /// The app's Delete Series: the folder, every session in it, and their
    /// artifacts. Goes through the StorageService so the deleted sessions leave
    /// the search indexes and the deletion is queued for sync, as the UI's does.
    func deleteMeetingGroup(groupID: String) async throws -> String {
        let group = try requireMeetingGroup(groupID, argument: "group_id")
        let deleted = try await notebookFileStorage.deleteMeetingGroupWithSessions(name: group.id)
        return try jsonString([
            "status": "deleted",
            "group_id": group.id,
            "title": group.title,
            "deleted_session_ids": deleted,
            "message": "Deleted meeting series ‘\(group.title)’ and \(deleted.count) session\(deleted.count == 1 ? "" : "s"). The Drive folder and recordings were not touched.",
        ] as [String: Any])
    }

    /// Validate an assistant's folder image and normalize it the way the app's own
    /// field does. `nil` means "clear the choice".
    ///
    /// Stricter than that text field on purpose. A person who pastes something
    /// unfetchable sees a blank tile and pastes again; an assistant cannot see the
    /// tile at all, so a stored address that renders nothing would look like
    /// success forever. The two shapes the tile actually draws — a web address, and
    /// a file that is really there — are the two this accepts, and anything else
    /// comes back as the reason it was refused.
    static func resolvedMeetingFolderImage(_ raw: String?) throws -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = StudioViewModel.normalizedMeetingFolderImageURL(trimmed)
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased() else {
            throw MCPError.invalidInput(
                "\"\(trimmed)\" is not an image address or a path to a file on this Mac."
            )
        }

        switch scheme {
        case "http", "https":
            guard url.host?.isEmpty == false else {
                throw MCPError.invalidInput(
                    "\"\(trimmed)\" names no host, so there is nothing to fetch the image from."
                )
            }
            return normalized
        case "file":
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MCPError.invalidInput(
                    "No file at \(url.path). A folder image given as a path has to be a file that exists on this Mac — and it only draws on this Mac. Pass a web address instead to have it follow the account to the learner's other devices."
                )
            }
            return normalized
        default:
            throw MCPError.invalidInput(
                "\(scheme): addresses cannot be used as a folder image. Pass an http(s) image address, or an absolute path to an image on this Mac."
            )
        }
    }

    /// What is open in ForeverLM: each Studio window's notebook, frontmost
    /// first (`MCPAppWindows`), then the sources the frontmost window's
    /// notebook chats read — its own ticked sources and those of the context
    /// notebooks the learner put in. A window outside any notebook says so.
    /// What a window holds is never an implicit MCP default.
    func getAppContext(windows: [MCPAppWindows.Window] = MCPAppWindows.current) throws -> String {
        guard !windows.isEmpty else {
            return "No ForeverLM window is open. What a window holds is never an implicit MCP default: resolve a Notebook the learner names with list_notebooks."
        }
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var lines = [
            windows.count == 1
                ? "One ForeverLM window is open. What it holds is never an implicit MCP default: pass notebook_id explicitly to Notebook tools."
                : "\(windows.count) ForeverLM windows are open, frontmost first. What they hold is never an implicit MCP default: pass notebook_id explicitly to Notebook tools."
        ]
        var frontmost: (notebook: LearningGoalRecord, sourceIDs: [String])?
        for window in windows {
            let label = window.isFrontmost ? "Frontmost window" : "Window"
            guard let notebookID = window.notebookID,
                  let notebook = try store.loadLearningGoal(notebookID),
                  notebook.isNotebook else {
                lines.append("- \(label): no notebook open")
                continue
            }
            let sourceIDs = try notebookChatSourceIDs(goal: notebook, store: store)
                .filter { !excluded.contains($0) }
            let count = "\(sourceIDs.count) source\(sourceIDs.count == 1 ? "" : "s")"
            let archived = notebook.isArchived ? ", archived" : ""
            lines.append("- \(label): Notebook '\(notebook.title)' (notebook_id: \(notebook.id), \(count)\(archived))")
            if window.isFrontmost { frontmost = (notebook, sourceIDs) }
        }
        guard let frontmost, !frontmost.sourceIDs.isEmpty else {
            return lines.joined(separator: "\n")
        }
        let sources = try formatAppContext(
            sourceIDs: frontmost.sourceIDs,
            heading: "Sources the frontmost window's Notebook '\(frontmost.notebook.title)' reads (\(frontmost.sourceIDs.count))"
        )
        return lines.joined(separator: "\n") + "\n\n" + sources
    }

    func formatAppContext(sourceIDs: [String], heading: String, maxCharsPerSource: Int? = nil) throws -> String {
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let ids = sanitizedSourceIDs(sourceIDs).filter { !excludedSourceIDs.contains($0) }
        guard !ids.isEmpty else { return "\(heading):\n- No sources." }

        return try withDB { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, """
                SELECT sp.id, sp.title, sp.source_type, sp.word_count, sp.url, sp.local_file_path,
                       sp.book_page_start, sp.book_page_count,
                       COALESCE(sp.is_paywalled, 0) as is_paywalled, sc.content
                FROM source_projection sp
                LEFT JOIN source_content sc ON sp.id = sc.source_id
                WHERE sp.id IN (\(placeholders))
            """, params: ids)
            let rowsByID = rows.reduce(into: [String: [String: Any]]()) { result, row in
                guard let id = row["id"] as? String, result[id] == nil else { return }
                result[id] = row
            }

            var parts: [String] = ["\(heading):"]
            for sourceID in ids {
                guard let r = rowsByID[sourceID] else {
                    parts.append("\n---\n## Missing source\nSource ID: \(sourceID)")
                    continue
                }
                let title = r["title"] as? String ?? "Untitled"
                let type = r["source_type"] as? String ?? ""
                let words = r["word_count"] as? Int ?? 0
                let url = r["url"] as? String ?? ""
                let localPath = r["local_file_path"] as? String
                let isPaywalled = (r["is_paywalled"] as? Int ?? 0) != 0
                var content = r["content"] as? String

                // If no stored content, try extracting from local file
                if type != "paper", content == nil || content?.isEmpty == true {
                    if let path = localPath ?? (url.hasPrefix("/") ? url : nil) {
                        content = Self.extractTextFromLocalFile(path, pages: Self.bookPages(r))
                    }
                }

                // For podcasts: try raw TTML transcript
                if (content == nil || content?.isEmpty == true) && type == "podcast",
                   let sourceId = r["id"] as? String {
                    let ttmlRows = try query(db, "SELECT raw_ttml FROM podcasts WHERE source_id = ?", params: [sourceId])
                    if let ttml = ttmlRows.first?["raw_ttml"] as? String, !ttml.isEmpty {
                        content = try? SourceService.extractTextFromTTMLContent(ttml)
                    }
                }

                let isWebURL = url.hasPrefix("http://") || url.hasPrefix("https://")
                let wordDisplay = content.map { $0.split(separator: " ").count } ?? words
                let body: String
                if isWebURL && !isPaywalled && type == "article" && (content == nil || content?.isEmpty == true) {
                    body = "This article is publicly accessible. Fetch the URL above for full content."
                } else {
                    body = content ?? "(No content)"
                }
                var displayBody = body
                if let maxChars = maxCharsPerSource, maxChars > 0, displayBody.count > maxChars {
                    displayBody = String(displayBody.prefix(maxChars)) + "\n…(truncated; use get_source_content for full text)"
                }
                if isWebURL && !isPaywalled && type == "article" && (content == nil || content?.isEmpty == true) {
                    parts.append("\n---\n## \(title) (\(wordDisplay) words)\nURL: \(url)\n\(displayBody)")
                } else {
                    parts.append("\n---\n## \(title) (\(wordDisplay) words)\(isWebURL ? "\nURL: \(url)" : "")\n\(displayBody)")
                }
            }
            return parts.joined(separator: "\n")
        }
    }
}

// MARK: - Meeting transcript helpers

extension MCPDataStore {
    /// Parse a timestamp from common export formats, including ISO 8601 with a
    /// timezone, with fractional seconds, and naive timestamps without a timezone
    /// (e.g. Read AI's `2026-06-10T16:53:52.988310`), which are treated as UTC.
    static func parseFlexibleTimestamp(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: trimmed) { return date }
        let iso = KnowledgeStore.iso8601Formatter
        if let date = iso.date(from: trimmed) { return date }

        // Naive timestamps with no timezone: assume UTC. Normalize the fractional
        // seconds to a fixed width since DateFormatter's `S` is greedy.
        let hasZone = trimmed.contains("Z") || trimmed.range(of: "[+-]\\d\\d:?\\d\\d$", options: .regularExpression) != nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = hasZone ? nil : TimeZone(identifier: "UTC")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Import meeting transcripts from JSON files on disk into one meeting group.
    /// Each file holds one session: {"title", "started_at" (ISO 8601, optional),
    /// "transcript", "notes" (optional), "chat" (optional), "url" (optional)}.
    /// Uses the same group/session-URL scheme as the Read AI importer so meetings
    /// later re-imported through a connected Read AI account dedup cleanly.
    func importMeetingTranscriptFiles(groupTitle: String, folderPath: String, source: String?) async throws -> String {
        let title = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPError.invalidInput("group_title is required.")
        }
        let folder = try validateClientProvidedPath(folderPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPError.invalidInput("folder_path does not exist or is not a directory: \(folder.path)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw MCPError.invalidInput("No .json transcript files found in \(folder.path).")
        }
        guard files.count <= Self.maxClientProvidedFolderFiles else {
            throw MCPError.invalidInput("Folder holds \(files.count) .json files; the limit is \(Self.maxClientProvidedFolderFiles) per import. Split the folder and re-run.")
        }
        let origin: DiscoveryOrigin = (source?.lowercased() == "readai") ? .readAI : .localMeetings

        let store = try knowledgeStore()
        // An explicit import of this group title revokes a prior in-app removal.
        StudioViewModel.liftRemovedMeetingGroupTitle(title)
        let groupID = try resolveGroupID(input: title, preferredType: "meeting", store: store)

        var imported: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        for file in files {
            // Re-validate every entry: a symlink inside the folder must not pull
            // in a read from outside the allowed roots, and oversized files skip.
            guard let validatedFile = try? validateClientProvidedPath(file.path),
                  let data = try? Data(contentsOf: validatedFile),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionTitle = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionTitle.isEmpty,
                  let transcript = (object["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty else {
                failed.append(file.lastPathComponent)
                continue
            }
            let startedAtString = (object["started_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let startedAt = Self.parseFlexibleTimestamp(startedAtString)

            // Fall back to the file name (e.g. an ISO timestamp) so multiple
            // sessions never collapse onto one date-less session key.
            let sessionSeed = startedAt != nil ? sessionTitle : "\(sessionTitle) \((file.lastPathComponent as NSString).deletingPathExtension)"
            let sessionKey = StudioViewModel.readAISessionKey(title: sessionSeed, date: startedAt, includeTime: true)
            let sourceURL = "meeting://\(groupID)/\(StudioViewModel.percentEncodedMeetingPathComponent(sessionKey))"
            if store.sourceExistsByURL(sourceURL) != nil {
                skipped.append(sessionKey)
                continue
            }
            // Deleting the series tombstoned each session's URL; this explicit
            // import lifts those the way it lifted the series title above, with
            // a synced deletion, or the arriving DismissedSource record would
            // archive the session again on the next sync pass.
            if store.isSourceDismissed(url: sourceURL) {
                try store.undismissSource(url: sourceURL)
            }

            var sections: [(kind: MeetingArtifactKind, label: String, text: String)] = [(.transcript, "Transcript", transcript)]
            if let notes = (object["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                sections.append((.notes, "Notes", notes))
            }
            if let chat = (object["chat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !chat.isEmpty {
                sections.append((.chat, "Chat", chat))
            }

            var article = StudioArticle(
                url: sourceURL,
                title: sessionKey,
                sourceType: .meeting,
                discoveryOrigin: origin,
                parentGroup: groupID
            )
            article.domain = title
            if let startedAt { article.dateAdded = startedAt }
            article.content = "# \(sessionKey)\n\n" + sections.map { "## \($0.label)\n\n\($0.text)" }.joined(separator: "\n\n")
            article.wordCount = article.content?.split(separator: " ").count
            article.state = .ready
            // Who was there, when the transcript's speaker labels say.
            let speakers = StudioViewModel.zoomCaptionSpeakers(transcript)
            article.author = StudioViewModel.zoomSessionParticipantLine(speakers: speakers, invited: [])
            try store.saveSource(article)

            let externalURL = (object["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, section) in sections.enumerated() {
                let artifact = MeetingArtifact(
                    id: SourceIdentity.stableID(for: "\(article.id):file-import:\(section.kind.rawValue)"),
                    sourceId: article.id,
                    groupId: groupID,
                    kind: section.kind,
                    title: "\(sessionTitle) \(section.label)",
                    url: (externalURL?.isEmpty == false) ? externalURL : nil,
                    localFilePath: file.path,
                    mimeType: "text/plain",
                    modifiedAt: startedAt,
                    sortIndex: index
                )
                try store.saveMeetingArtifact(artifact)
            }
            // The meeting may be on the Mac's Calendar, drawn there before it
            // happened; its invitation says who was asked, the way it does
            // for a session the Zoom watcher files.
            if let startedAt {
                let invited = await MeetingCalendarEvent.invitedNames(startedAt: startedAt, title: sessionTitle)
                // A transcript with no speaker labels leaves the invitation
                // as the session's one word on who was there.
                if article.author == nil,
                   let line = StudioViewModel.zoomSessionParticipantLine(speakers: speakers, invited: invited) {
                    article.author = line
                    try store.saveSource(article)
                }
            }
            // The one funnel every stored transcript ends in: the sitting it
            // continues, if any, and the series' action items.
            MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id)
            imported.append(sessionKey)
        }

        return try jsonString([
            "group_id": groupID,
            "group_title": title,
            "imported": imported.count,
            "imported_sessions": imported,
            "skipped_already_imported": skipped,
            "failed_to_parse": failed,
        ] as [String: Any])
    }

    // MARK: - YouTube plugin (MCP/UI parity)

    /// Stable video-playlist group id, matching the in-app derivation so a playlist
    /// followed via MCP and via the app resolve to the same group.
    private func youtubePlaylistGroupID(for url: String) -> String {
        "playlist_" + URLNormalizer.normalize(url)
    }

    /// The connected YouTube account a call names by channel title or id; the
    /// only one when nothing is named, and an error listing them when several
    /// are connected.
    func youTubeAccount(named requested: String?) throws -> YouTubeAccount {
        let accounts = YouTubeService.shared.connectedAccounts
        guard !accounts.isEmpty else {
            throw MCPError.invalidInput("YouTube is not connected. Connect YouTube in Plugins → YouTube first.")
        }
        let name = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self.pluginPick(
            accounts,
            requested: name?.isEmpty == false ? name : nil,
            id: \.id,
            label: \.title,
            what: "YouTube account",
            argument: "account"
        )
    }

    /// Make an account's "Liked videos" its import source: import them now via
    /// the authenticated YouTube Data API and mark the group for background
    /// auto-import. The Liked feed is private, so this requires a connected
    /// YouTube account.
    func followYouTubeLikedVideosMCP(
        account requested: String? = nil,
        importExisting: Bool = true,
        automaticallyFormatTranscripts: Bool = false
    ) async throws -> String {
        let account = try youTubeAccount(named: requested)
        var choices = account.choices
        choices.source = .likedVideos
        choices.foreverLMPlaylistID = nil
        choices.likedPolicy = importExisting ? .importExisting : .futureOnly
        choices.likedCutoff = importExisting
            ? nil
            : Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        guard let updated = YouTubeService.shared.setChoices(choices, forAccount: account.id) else {
            throw MCPError.notFound("The YouTube account \(account.title) is no longer connected.")
        }
        StudioViewModel.setLikedYouTubeTranscriptFormattingEnabled(
            automaticallyFormatTranscripts
        )
        StudioViewModel.setYouTubeAutoImportEnabled(true)
        await PreferenceStore.flushPendingWrites()
        let items = try await YouTubeService.shared.listLikedVideos(accountID: account.id)
        let summary = try insertYouTubePluginVideos(
            url: YouTubeService.likedVideosPlaylistURL,
            title: "Liked videos",
            items: items,
            kind: YouTubeImportSource.likedVideos.connectorKind,
            assignsParentGroup: false,
            account: updated
        )
        YouTubeService.notifyConnectionChanged()
        return summary
    }

    /// Make an account's owned playlist named "ForeverLM" its import source.
    /// This is the MCP counterpart of the source choice in Settings.
    func followYouTubeForeverLMPlaylistMCP(account requested: String? = nil) async throws -> String {
        let account = try youTubeAccount(named: requested)
        let summary = try await importYouTubeForeverLMPlaylistMCP(account: account)
        StudioViewModel.setYouTubeAutoImportEnabled(true)
        YouTubeService.notifyConnectionChanged()
        return summary
    }

    /// Read the account's ForeverLM playlist, remember it as the account's
    /// source, and mirror it into its group.
    private func importYouTubeForeverLMPlaylistMCP(account: YouTubeAccount) async throws -> String {
        let feed = try await YouTubeService.shared.listForeverLMPlaylistFeed(accountID: account.id)
        var choices = account.choices
        choices.source = .foreverLMPlaylist
        choices.foreverLMPlaylistID = feed.playlist.id
        guard let updated = YouTubeService.shared.setChoices(choices, forAccount: account.id) else {
            throw MCPError.notFound("The YouTube account \(account.title) is no longer connected.")
        }
        let summary = try insertYouTubePluginVideos(
            url: feed.playlist.url,
            title: feed.playlist.title,
            items: feed.items,
            kind: YouTubeImportSource.foreverLMPlaylist.connectorKind,
            assignsParentGroup: true,
            account: updated
        )
        if feed.isComplete {
            try archiveMissingYouTubePlaylistVideosMCP(
                groupID: youtubePlaylistGroupID(for: feed.playlist.url),
                currentURLKeys: Set(feed.items.map { StudioViewModel.sourceURLIdentityKey($0.url) })
            )
        }
        return summary
    }

    /// Re-check the import source of the named account, or of every connected
    /// account when none is named.
    func refreshYouTubeSourcesMCP(account requested: String? = nil) async throws -> String {
        let name = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accounts = name?.isEmpty == false
            ? [try youTubeAccount(named: name)]
            : YouTubeService.shared.connectedAccounts
        guard !accounts.isEmpty else {
            throw MCPError.invalidInput("YouTube is not connected. Connect YouTube in Plugins → YouTube first.")
        }
        var summaries: [[String: Any]] = []
        var skipped: [String] = []
        for account in accounts {
            switch account.choices.source {
            case .foreverLMPlaylist:
                let summary = try await importYouTubeForeverLMPlaylistMCP(account: account)
                if let obj = Self.jsonObject(summary) { summaries.append(obj) }
            case .likedVideos where account.choices.likedPolicy != .undecided:
                let items = try await YouTubeService.shared.listLikedVideos(accountID: account.id)
                let summary = try insertYouTubePluginVideos(
                    url: YouTubeService.likedVideosPlaylistURL,
                    title: "Liked videos",
                    items: items,
                    kind: YouTubeImportSource.likedVideos.connectorKind,
                    assignsParentGroup: false,
                    account: account
                )
                if let obj = Self.jsonObject(summary) { summaries.append(obj) }
            case .likedVideos, nil:
                skipped.append(account.title)
            }
        }
        YouTubeService.notifyConnectionChanged()
        var result: [String: Any] = ["refreshed": summaries.count, "groups": summaries]
        if !skipped.isEmpty {
            result["skipped_accounts"] = skipped
            result["message"] = "No import source (or no liked-video choice) is set for: \(skipped.joined(separator: ", ")). Choose one in Plugins → YouTube."
        }
        return try jsonString(result)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Insert an authenticated plugin feed and persist its followed state
    /// through KnowledgeStore so CloudKit metadata stays intact. `account` is
    /// the one whose feed this is: its policy filters a Liked import.
    private func insertYouTubePluginVideos(
        url: String,
        title playlistTitle: String,
        items: [YouTubePlaylistItem],
        kind: String,
        assignsParentGroup: Bool,
        account: YouTubeAccount
    ) throws -> String {
        let store = try knowledgeStore()
        let groupID = youtubePlaylistGroupID(for: url)
        let currentGroups = try store.loadVideoPlaylistGroups()
        let inlineGroupIDs = Set(currentGroups.compactMap { id, metadata in
            YouTubeImportSource.allCases.contains { $0.connectorKind == metadata.connectorKind }
                ? id
                : nil
        })
        let existingURLKeys = Set(
            try store.loadActiveSources().map { StudioViewModel.sourceURLIdentityKey($0.url) }
        )
        let importItems = kind == YouTubeImportSource.likedVideos.connectorKind
            ? StudioViewModel.eligibleLikedVideoItems(
                items,
                policy: account.choices.likedPolicy,
                cutoff: account.choices.likedCutoff,
                existingURLKeys: existingURLKeys
            )
            : items
        var added = 0
        for (index, item) in importItems.enumerated() {
            if let existing = store.sourceExistsByURL(item.url) {
                if existing.status == .active,
                   var article = try store.loadSourceForSync(existing.id) {
                    if assignsParentGroup {
                        article.parentGroup = groupID
                    } else if let currentGroup = article.parentGroup,
                              inlineGroupIDs.contains(currentGroup) {
                        article.parentGroup = nil
                    }
                    article.domain = item.channelTitle ?? playlistTitle
                    article.courseSortIndex = max(0, (item.playlistIndex ?? index + 1) - 1)
                    article.likedAt = item.likedAt
                    article.videoPublishedAt = item.videoPublishedAt
                    try store.saveSource(article)
                }
                continue
            }
            var article = StudioArticle(
                url: item.url,
                title: item.title,
                sourceType: .video,
                discoveryOrigin: .youtubePlaylist,
                parentGroup: assignsParentGroup ? groupID : nil
            )
            article.normalizedURL = URLNormalizer.normalize(item.url)
            article.domain = item.channelTitle ?? playlistTitle
            article.courseSortIndex = max(0, (item.playlistIndex ?? index + 1) - 1)
            article.artworkURL = article.youtubeThumbnailURL
            article.likedAt = item.likedAt
            article.videoPublishedAt = item.videoPublishedAt
            try store.saveSource(article)
            added += 1
        }

        let existing = currentGroups[groupID]
        let metadata = VideoPlaylistMetadata(
            title: (existing?.title.isEmpty == false ? existing!.title : playlistTitle),
            playlistURL: url,
            lastRefreshedAt: Date(),
            isHidden: existing?.isHidden ?? false,
            autoImport: true,
            connectorKind: kind
        )
        try store.saveVideoPlaylistGroup(id: groupID, metadata: metadata)

        // Release a source group no account reads any more.
        let wantedKinds = StudioViewModel.youtubeSourceGroupKinds(accounts: YouTubeService.shared.accounts)
        let supportedKinds = Set(YouTubeImportSource.allCases.map(\.connectorKind))
        for (otherID, var other) in currentGroups
            where otherID != groupID
                && wantedKinds[otherID] == nil
                && other.autoImport
                && other.connectorKind.map({ supportedKinds.contains($0) }) == true {
            other.autoImport = false
            other.connectorKind = nil
            try store.saveVideoPlaylistGroup(id: otherID, metadata: other)
        }

        return try jsonString([
            "group_id": groupID,
            "title": metadata.title,
            "kind": kind,
            "added_videos": added,
            "eligible_videos": importItems.count,
            "total_videos": items.count,
            "auto_import": true,
        ] as [String: Any])
    }

    private func archiveMissingYouTubePlaylistVideosMCP(
        groupID: String,
        currentURLKeys: Set<String>
    ) throws {
        let store = try knowledgeStore()
        let courseLectureSourceIDs = Set(try store.loadCourseLectureItems().compactMap(\.sourceId))
        for article in try store.loadActiveSources()
            where StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
                article,
                groupID: groupID,
                currentURLKeys: currentURLKeys,
                courseLectureSourceIDs: courseLectureSourceIDs
            ) {
            try store.archiveSource(article.id)
        }
    }


    /// Transcribe a meeting session's recording through managed OpenAI STT and
    /// attach the resulting text as the session's transcript artifact.
    ///
    /// The minutes of speech-to-text hold no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the session is read through the
    /// storage actor, and the transcript attached in one stretch held alone,
    /// which reads the session again before it merges the text in.
    func transcribeMeetingRecording(sourceID: String) async throws -> String {
        guard let article = try await notebookFileStorage.loadSourceWithoutContent(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .meeting else {
            throw MCPError.invalidInput("transcribe_meeting_recording requires a meeting session source. Use get_meeting_group to find session source ids.")
        }
        let artifacts = try await notebookFileStorage.loadMeetingArtifacts(sourceID: sourceID)
        guard let recording = artifacts.first(where: { $0.kind == .recording }) else {
            throw MCPError.invalidInput("This session has no recording artifact to transcribe.")
        }

        let transcript: String
        if let driveURL = cleanedOptional(recording.url) {
            transcript = try await MeetingTranscriptionService.shared.transcribe(driveFileURLOrID: driveURL)
        } else if let localPath = cleanedOptional(recording.localFilePath) {
            let resolved = StorageService.locateSourceFile(localPath)
                ?? StorageService.absoluteSourcePath(localPath)
            transcript = try await MeetingTranscriptionService.shared.transcribe(
                localMediaURL: URL(fileURLWithPath: resolved)
            )
        } else {
            throw MCPError.invalidInput("This session's recording has no readable Drive URL or local path.")
        }

        // Reuse the attach path: write to a temp file and merge as the transcript section.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(sourceID).txt")
        try transcript.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await withStoreGate(.exclusive) {
            try attachMeetingArtifact(sourceID: sourceID, filePath: tempURL.path, kindString: "transcript")
        }
    }

    /// Attach a local text file to a meeting session source as an additional
    /// artifact. The text becomes a section of the session content (ordered
    /// transcript -> notes -> chat) so one meeting can hold multiple sources.
    func attachMeetingArtifact(sourceID: String, filePath: String, kindString: String?) throws -> String {
        let kind: MeetingArtifactKind
        switch (kindString ?? "transcript").lowercased() {
        case "transcript": kind = .transcript
        case "notes": kind = .notes
        case "chat": kind = .chat
        case "attachment": kind = .attachment
        default:
            throw MCPError.invalidInput("kind must be transcript, notes, chat, or attachment.")
        }

        let store = try knowledgeStore()
        guard var article = try store.loadSourceForSync(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID)")
        }
        guard article.sourceType == .meeting else {
            throw MCPError.invalidInput("attach_meeting_artifact requires a meeting session source. Use get_meeting_group to find session source ids.")
        }

        let fileURL = try validateClientProvidedPath(filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MCPError.invalidInput("File not found: \(filePath)")
        }
        let data = try Data(contentsOf: fileURL)
        guard let raw = Self.decodeTextData(data)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw MCPError.invalidInput("Could not read text from \(filePath)")
        }

        let destination = try copyFileIntoContentRoot(
            fileURL,
            folder: "Meetings",
            baseName: "\(article.title) - \(kind.label)",
            fallbackExtension: fileURL.pathExtension.isEmpty ? "txt" : fileURL.pathExtension
        )

        article.content = Self.meetingContentInserting(section: kind, text: raw, into: article.content, title: article.title)
        article.wordCount = article.content?.split(separator: " ").count
        article.state = .ready
        article.errorMessage = nil
        try store.saveSource(article)

        let artifact = MeetingArtifact(
            id: SourceIdentity.stableID(for: "\(article.id):attached:\(kind.rawValue)"),
            sourceId: article.id,
            groupId: article.parentGroup ?? "",
            kind: kind,
            title: "\(article.title) - \(kind.label)",
            url: nil,
            localFilePath: relativeSourceContentPath(destination) ?? destination.path,
            mimeType: "text/plain",
            modifiedAt: Date(),
            sortIndex: kind.sortRank
        )
        try store.saveMeetingArtifact(artifact)
        if kind == .transcript {
            MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: sourceID)
        }

        return "Attached \(kind.label) to '\(article.title)' (\(raw.split(separator: " ").count) words)"
    }

    /// Insert or replace one "## <Kind>" section in a meeting session's merged
    /// content, keeping sections in transcript -> notes -> chat -> recording ->
    /// attachment order.
    nonisolated static func meetingContentInserting(
        section kind: MeetingArtifactKind,
        text: String,
        into content: String?,
        title: String
    ) -> String {
        MeetingContent.inserting(section: kind, text: text, into: content, title: title)
    }

}

// MARK: - Screen record mode

/// The listings a filmed "@ForeverLM" take reads, narrowed to the one
/// `ScreenRecordScope` the app's windows show. Sources are already scoped by
/// `knowledgeSearchExcludedSourceIDs`, which folds the scope in; these helpers
/// cover what that boundary does not reach — Notebooks, Goals, chats, Docs,
/// Ideas and tasks. Every one answers "unchanged" when the scope
/// is nil, which it is for every learner but the admin.
extension MCPDataStore {
    /// The scope, or nil when screen record mode is off. Fails closed: with
    /// the mode on and a store that will not open, the scope still comes back
    /// (holding no recording-Notebook sources) rather than nil, so an error
    /// never widens a take to the whole library.
    func screenRecordScope() -> ScreenRecordScope? {
        guard ScreenRecordMode.isEffective else { return nil }
        if let store = try? knowledgeStore() { return store.screenRecordScope() }
        return ScreenRecordScope.resolve { _ in [] }
    }

    /// Stored source ids the scope keeps off screen; empty when it is nil.
    func screenRecordHiddenSourceIDs(scope: ScreenRecordScope?) throws -> Set<String> {
        guard let scope else { return [] }
        return try knowledgeStore().screenRecordExcludedSourceIDs(scope: scope)
    }

    /// Each Goal's Notebook, so an item filed under a Goal nested in the
    /// recording Notebook counts as filed under the Notebook.
    func screenRecordParentNotebookIDs() throws -> [String: String] {
        let goals = try knowledgeStore().loadLearningGoals()
        return Dictionary(
            goals.compactMap { goal in goal.parentNotebookID.map { (goal.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The Notebook ids an item linked to `goalIDs` is filed under: the ids
    /// themselves and each one's parent Notebook (the notebook rule,
    /// `NotebookMembership.filingNotebookIDs`).
    func screenRecordNotebookIDs(
        linkedTo goalIDs: [String?],
        parents: [String: String]
    ) -> [String?] {
        NotebookMembership.filingNotebookIDs(goalIDs, goalParents: parents)
    }

    /// A Notebook shows when it is the recording one or was made during the
    /// take; a Goal when it was made during the take or sits in the recording
    /// Notebook.
    func screenRecordAllowsGoal(_ goal: LearningGoalRecord, scope: ScreenRecordScope) -> Bool {
        if goal.isNotebook {
            return scope.allowsNotebook(id: goal.id, createdAt: goal.createdAt)
        }
        return scope.allowsItem(createdAt: goal.createdAt, notebookIDs: [goal.id, goal.parentNotebookID])
    }

    /// Docs, Sites and Animations: made during the take, or filed under or
    /// linked to the recording Notebook. Citing a filmed source is not enough.
    func screenRecordAllowsArtifact(_ artifact: ArtifactRecord, scope: ScreenRecordScope) -> Bool {
        scope.allowsItem(
            createdAt: artifact.createdAt,
            notebookIDs: NotebookMembership.filingNotebookIDs(of: artifact)
        )
    }

    /// The ids of the chats the scope keeps off screen: every chat not made
    /// during the take and not filed under the recording Notebook (or one of
    /// its Goals). A chat about a filmed source is still the learner's own
    /// and stays off. Empty when the scope is nil.
    func screenRecordHiddenReviewSessionIDs(scope: ScreenRecordScope?) throws -> Set<String> {
        guard let scope else { return [] }
        let parents = try screenRecordParentNotebookIDs()
        return Set(try knowledgeStore().loadReviewSessionLinks().filter { session in
            !scope.allowsItem(
                createdAt: session.createdAt,
                notebookIDs: screenRecordNotebookIDs(linkedTo: [session.goalID], parents: parents)
            )
        }.map(\.id))
    }
}

// MARK: - Saying a listing is narrowed

/// A take's listings are narrowed, and a client that cannot tell would read
/// "the library holds only this" and confidently pick the closest match: on
/// 2026-10-11 a client asking for the Notebook about a paper got the one empty
/// Notebook a recording Mac listed, from the learner's other Mac, and chose it.
/// So while the mode is on, each listing it narrows says so in one field.
///
/// The note names nothing that is left out, and no count of it either. A count
/// would put the size of the learner's private library on screen during a take,
/// it would not change what the client should do (say it cannot see the thing),
/// and it would cost every listing a second, unscoped pass.
extension MCPDataStore {
    /// The one sentence every narrowed answer carries, or nil while screen
    /// record mode is off, which it is for every learner but the admin.
    static var screenRecordNarrowedNote: String? {
        guard ScreenRecordMode.isEffective else { return nil }
        return "Screen record mode is on on this Mac, so Notebooks, sources and other work from before the take are not listed. If what the learner asked for is not here, say you can't see it from this Mac; don't pick the closest match."
    }

    /// `text` carrying `note`: a JSON object gains a `narrowed` field, and any
    /// other answer (a text listing, an empty-listing sentence) opens with a
    /// `Narrowed:` line, ahead of what a long listing might get cut at.
    static func addingNarrowedNote(_ note: String, to text: String) -> String {
        if text.first == "{",
           var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            object["narrowed"] = note
            // The same writing options as `jsonString`, which made the object.
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let noted = String(data: data, encoding: .utf8) {
                return noted
            }
        }
        return text.isEmpty ? "Narrowed: \(note)" : "Narrowed: \(note)\n\n\(text)"
    }
}

extension MCPToolRegistry {
    /// The listings and searches that ask `ScreenRecordScope` (directly, or
    /// through `knowledgeSearchExcludedSourceIDs`), and so answer for the take
    /// rather than the library while the mode is on. A new listing that asks
    /// the scope belongs here too.
    static let screenRecordNarrowedToolNames: Set<String> = [
        // Notebooks and Goals
        "list_notebooks", "list_goals", "list_notebook_collections", "list_notebook_sources",
        // Sources
        "list_sources", "filter_sources", "list_shows", "search_sources_semantic", "search_sources_keyword",
        "get_app_context", "get_today_sources", "list_courses", "search_source_highlights", "list_meeting_groups",
        // The learner's own work
        "list_docs", "list_animations", "list_spaces", "list_ideas", "list_images", "list_scheduled_tasks",
        "list_walkthroughs", "get_review_sessions", "search_review_sessions", "list_review_session_links",
        "list_cards", "list_source_card_coverage", "find_card_sources", "get_due_cards", "list_directions",
        // The day
        "get_calendar_events", "get_day_activity", "get_schedule",
    ]

    /// `outcome` with the narrowed note when `toolName` is a listing screen
    /// record mode narrows and the mode is on; otherwise `outcome` unchanged.
    /// A refusal is left as it is: a Notebook the take keeps off screen reads
    /// as absent, the same answer an unknown id gets (`getNotebookDetail`).
    static func notingScreenRecordNarrowing(_ outcome: ToolCallOutcome, toolName: String) -> ToolCallOutcome {
        guard !outcome.isError,
              screenRecordNarrowedToolNames.contains(toolName),
              let note = MCPDataStore.screenRecordNarrowedNote else { return outcome }
        return ToolCallOutcome(
            text: MCPDataStore.addingNarrowedNote(note, to: outcome.text),
            isError: false,
            images: outcome.images
        )
    }
}
