import Foundation
import SQLite3
import CloudKit

/// What Mark as Watched or Mark as Not Watched left on a source
/// (`KnowledgeStore.setVideoWatched`), for the caller's in-memory copies.
struct VideoWatchedMark: Equatable, Sendable {
    let locator: String?
    let readAt: Date?
    /// False when the video already was as asked and nothing was written.
    let changed: Bool
}

extension KnowledgeStore {
    // MARK: - Sources (StudioArticle)

    static func persistedTitle(for article: StudioArticle) -> String {
        guard article.sourceType == .video,
              YouTubeURLMetadata.isYouTubeURL(article.url) else {
            return article.title
        }
        return YouTubeURLMetadata.sanitizedVideoTitle(article.title) ?? "Untitled Video"
    }

    /// Writes a source's full text, replacing the row it already had. `source_content` is not a
    /// registered sync table, so this is a plain replace, not an outbox write.
    func writeSourceContent(sourceID: String, content: String) throws {
        try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, content)
        }
    }

    func saveSource(_ article: StudioArticle) throws {
        // Upserts the sources row, source_content, the per-type subtype row, group
        // membership, and hidden-source state, then records sync bookkeeping — all in
        // one atomic transaction so a partial write can never leave the projection or
        // the CloudKit change queue inconsistent. BEGIN IMMEDIATE takes the write lock
        // up front to avoid non-retryable SQLITE_BUSY_SNAPSHOT against the sync/MCP
        // connections.
        try exec("BEGIN IMMEDIATE")
        let keptStored: Bool
        do {
            let sourceWasMissing = !(try sourceExists(article.id))
            keptStored = try persistSourceRows(article)
            if sourceWasMissing {
                try restoreDeferredReviewSessionSourceLinks(sourceID: article.id)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        // The copy was behind the row (another device's change, most often): whoever shows it reads the
        // sources again, as after an inbound apply, rather than keep showing what this save did not write.
        if keptStored {
            var changes = AppliedRemoteChanges()
            changes.note(.source, localID: article.id)
            appliedRemoteChangesHandler?(changes)
        }
    }

    /// Save a source whose text has just been replaced at its root (a new PDF
    /// of the paper accepted in place of what it held), removing the old text
    /// and everything derived from it (`clearSourceText`: review guides,
    /// walkthroughs and their progress, narration, figures, search rows) in
    /// the same transaction. A failure rolls both back, so the source never
    /// ends with its old work gone and nothing in its place; nothing is
    /// cleared before the replacement is in hand.
    func saveSourceReplacingDerivedData(_ article: StudioArticle) throws {
        try exec("BEGIN IMMEDIATE")
        let keptStored: Bool
        do {
            let sourceWasMissing = !(try sourceExists(article.id))
            try clearSourceText(article.id)
            keptStored = try persistSourceRows(article)
            if sourceWasMissing {
                try restoreDeferredReviewSessionSourceLinks(sourceID: article.id)
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        if keptStored {
            var changes = AppliedRemoteChanges()
            changes.note(.source, localID: article.id)
            appliedRemoteChangesHandler?(changes)
        }
    }

    /// The row writes behind `saveSource`, inside the caller's transaction.
    /// Not private: a write that folds several sources into one
    /// (`mergeMeetingSessions`) saves the survivor in the same transaction
    /// that archives the rest.
    ///
    /// A write writes what it changes. Under generation 2 a copy read from the
    /// store is written over the row as it is stored now, with only the fields
    /// its holder changed since (`StudioArticle.written(over:)`): every column
    /// whose value changes is sent with a new stamp and wins on every device, so
    /// a copy taken before another device's change must not write the old value
    /// back. Answers whether the row held a value the copy did not change and
    /// lacked. A copy never read from the store, and generation 1, write whole.
    @discardableResult
    func persistSourceRows(
        _ copy: StudioArticle,
        publishedDOI: String? = nil
    ) throws -> Bool {
        let (article, keptStored) = try writtenOverStoredRow(copy)
        let incomingReadableContent = article.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let podcastStateCanBeDemoted = article.sourceType == .podcast
            && (article.state == .queued || article.state == .fetching)
        let podcastAlreadyHasReadableContent: Bool
        if podcastStateCanBeDemoted {
            if incomingReadableContent {
                podcastAlreadyHasReadableContent = true
            } else {
                podcastAlreadyHasReadableContent = try hasReadableSourceContent(article.id)
            }
        } else {
            podcastAlreadyHasReadableContent = false
        }
        let persistedState: StudioArticleState
        let persistedErrorMessage: String?
        if podcastAlreadyHasReadableContent {
            // A podcast transcript is the completed import. Metadata refreshes
            // and older CloudKit payloads must not demote that durable source
            // back into a queue that can never truthfully describe its work.
            persistedState = .ready
            persistedErrorMessage = nil
        } else {
            persistedState = article.state
            persistedErrorMessage = article.errorMessage
        }
        if article.state == .ready, !incomingReadableContent {
            if article.content != nil {
                throw KnowledgeStoreError.invalidData(
                    "A source cannot become ready until durable readable text has been stored."
                )
            }
            if !(try hasReadableSourceContent(article.id)) {
                throw KnowledgeStoreError.invalidData(
                    "A source cannot become ready until durable readable text has been stored."
                )
            }
        }
        if article.sourceType == .paper,
           article.state == .ready,
           !article.hasPaperIngestionAttestation {
            throw KnowledgeStoreError.invalidData(
                "Paper ingestion requires a successful Paper Metadata LLM call that resolved at least one of author, venue, and year before the source can become ready."
            )
        }
        if article.sourceType == .paper,
           article.state == .ready,
           article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           article.paperContentPreparationForPersistence == nil,
           !(try hasPaperContentPreparation(article.id)) {
            throw KnowledgeStoreError.invalidData(
                "Paper ingestion requires successful Source Content Cleanup before the source can become ready."
            )
        }

        let title = Self.persistedTitle(for: article)
        // An author is a name. Markup, a web address or a "name" longer than
        // any name is some other field a reader misread (two articles once
        // stored a kilobyte of their page's head here), and it never reaches
        // the row, whichever path wrote it. `StudioArticle.author` refuses the
        // same values as they arrive; this is the store's own guarantee.
        let author = SourceAuthor.storable(
            article.sourceType == .paper
                ? StudioArticle.canonicalPaperAuthor(article.author)
                : article.author
        )
        let persistURL = StorageService.relativeSourcePath(article.url)
        let persistLocalPath = article.localFilePath.map { StorageService.relativeSourcePath($0) }
        let normalizedURL = URLNormalizer.normalize(article.url)
        let cleanPublicURL = article.publicURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicURL = cleanPublicURL?.isEmpty == false ? cleanPublicURL : Self.defaultPublicURL(for: article)
        // A copy of a video taken before a Mark as Not Watched this row already
        // holds (a transcript or metadata save racing the mark) must not bring
        // the watching, or the read stamp the mark cleared, back. A row without
        // the epoch is saved exactly as before.
        var persistedLocator = article.readingPositionLocator
        var persistedReadAt = article.readAt
        if article.offersWatchedMarks,
           let stored = try loadSourceProgress(sourceID: article.id),
           stored.locator?.contains(VideoWatchProgress.unwatchedAtKey) == true,
           let unwatchedAt = VideoWatchProgress.unwatchedEpoch(
            in: stored.locator,
            unseenBy: article.readingPositionLocator
           ) {
            persistedLocator = stored.locator
            if let stamp = persistedReadAt, stamp <= unwatchedAt {
                persistedReadAt = stored.readAt
            }
        }
        // Generation 2 keeps reading values in reading_states only; a new source's go there once.
        let seedsReadingState = try scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(article.id)]) != 1
        let hasPublicURLColumn = try tableColumnNames("sources").contains("public_url")
        if hasPublicURLColumn {
            try execBind("""
                INSERT INTO sources
                (id, date_added, state, error_message, source_type, existing_card_count, status, archived_at, public_url, reading_position_page, reading_position_locator, read_at, connector_label, team_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    date_added = excluded.date_added,
                    state = excluded.state,
                    error_message = excluded.error_message,
                    source_type = excluded.source_type,
                    existing_card_count = excluded.existing_card_count,
                    status = excluded.status,
                    archived_at = excluded.archived_at,
                    public_url = excluded.public_url,
                    reading_position_page = excluded.reading_position_page,
                    reading_position_locator = excluded.reading_position_locator,
                    read_at = excluded.read_at,
                    connector_label = excluded.connector_label,
                    -- A team copy stays the team's; a payload that omits the
                    -- field (an older client) must not pull it into My Library.
                    team_id = COALESCE(excluded.team_id, sources.team_id)
            """) { stmt in
                bind(stmt, 1, article.id)
                sqlite3_bind_double(stmt, 2, article.dateAdded.timeIntervalSinceReferenceDate)
                bind(stmt, 3, persistedState.rawValue)
                bind(stmt, 4, persistedErrorMessage)
                bind(stmt, 5, article.sourceType.rawValue)
                sqlite3_bind_int(stmt, 6, 0)
                bind(stmt, 7, article.status.rawValue)
                if let archivedAt = article.archivedAt {
                    bind(stmt, 8, Self.iso8601Formatter.string(from: archivedAt))
                } else {
                    bind(stmt, 8, nil as String?)
                }
                bind(stmt, 9, publicURL)
                bind(stmt, 10, article.readingPositionPage)
                bind(stmt, 11, persistedLocator)
                if let readAt = persistedReadAt {
                    sqlite3_bind_double(stmt, 12, readAt.timeIntervalSinceReferenceDate)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }
                bind(stmt, 13, article.connectorLabel)
                bind(stmt, 14, article.teamID)
            }
        } else {
            try execBind("""
                INSERT INTO sources
                (id, date_added, state, error_message, source_type, existing_card_count, status, archived_at, reading_position_page, reading_position_locator, read_at, connector_label)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    date_added = excluded.date_added,
                    state = excluded.state,
                    error_message = excluded.error_message,
                    source_type = excluded.source_type,
                    existing_card_count = excluded.existing_card_count,
                    status = excluded.status,
                    archived_at = excluded.archived_at,
                    reading_position_page = excluded.reading_position_page,
                    reading_position_locator = excluded.reading_position_locator,
                    read_at = excluded.read_at,
                    connector_label = excluded.connector_label
            """) { stmt in
                bind(stmt, 1, article.id)
                sqlite3_bind_double(stmt, 2, article.dateAdded.timeIntervalSinceReferenceDate)
                bind(stmt, 3, persistedState.rawValue)
                bind(stmt, 4, persistedErrorMessage)
                bind(stmt, 5, article.sourceType.rawValue)
                sqlite3_bind_int(stmt, 6, 0)
                bind(stmt, 7, article.status.rawValue)
                if let archivedAt = article.archivedAt {
                    bind(stmt, 8, Self.iso8601Formatter.string(from: archivedAt))
                } else {
                    bind(stmt, 8, nil as String?)
                }
                bind(stmt, 9, article.readingPositionPage)
                bind(stmt, 10, persistedLocator)
                if let readAt = persistedReadAt {
                    sqlite3_bind_double(stmt, 11, readAt.timeIntervalSinceReferenceDate)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }
                bind(stmt, 12, article.connectorLabel)
            }
        }

        if seedsReadingState {
            try seedReadingState(sourceID: article.id, page: article.readingPositionPage, macLocator: persistedLocator, readAt: persistedReadAt)
        }
        // A save that rewrites the text (an MCP client's `update_source_content`, an edit, a fetch over an
        // older text) owes what every writer of a source's text owes: the index goes and the text is
        // published again. Some branches below do it themselves; the plain ones (a book chapter, a course
        // source, a podcast or video, an article or paper with no preparation) did not, so a text replaced
        // after its satellite went up stayed behind its pointer on every other device. Checked after the
        // write too: a branch that keeps the stored text (a podcast's clean-up input) replaced nothing.
        let replacesText = try article.content.map { try replacesStoredText(sourceID: article.id, with: $0) } ?? false
        try persistCanonicalContent(for: article)
        if replacesText, let content = article.content, try scalarInteger(
            "SELECT EXISTS (SELECT 1 FROM source_content WHERE source_id = ? AND content IS ?)",
            [.text(article.id), .text(content)]
        ) == 1 {
            try invalidateReplacedText(sourceID: article.id)
        }
        if let content = article.content {
            try enqueueSourceListenableContentPreparation(sourceID: article.id, content: content)
        } else if !article.supportsListenableContentPreparation {
            // A save carrying no in-memory text is not evidence the source lost
            // its stored text — the handoff is discarded after every successful
            // ingest. Only a source narration can never apply to retires the
            // queued work; the candidate query owns which states may run.
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
            if article.sourceType == .podcast || article.sourceType == .video {
                try execBind("DELETE FROM source_listenable_content WHERE source_id = ?") { stmt in
                    bind(stmt, 1, article.id)
                }
            }
        }

        try deleteSubtypeRows(for: article.id, except: article.sourceType)

        switch article.sourceType {
        case .article, .manual, .unclassified:
            try execBind("""
                INSERT INTO articles
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, author)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    author = excluded.author
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
                bind(stmt, 10, author)
            }
        case .paper:
            // A locally resolved published DOI and one arriving from sync are the
            // same fact, and either may be the only one present. The ON CONFLICT
            // clause coalesces on top of this, so a save that knows neither can
            // never erase a value another path already established.
            let localPublishedDOI = article.publishedDOI?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let resolvedPublishedDOI = publishedDOI
                ?? (localPublishedDOI?.isEmpty == false ? localPublishedDOI : nil)
            try execBind("""
                INSERT INTO papers
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, author, doi, published_doi, journal, published_year, is_paywalled, paper_ingestion_method, paywall_suspicion)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    author = excluded.author,
                    doi = excluded.doi,
                    published_doi = COALESCE(excluded.published_doi, papers.published_doi),
                    journal = excluded.journal,
                    published_year = excluded.published_year,
                    is_paywalled = excluded.is_paywalled,
                    paper_ingestion_method = excluded.paper_ingestion_method,
                    paywall_suspicion = excluded.paywall_suspicion
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
                bind(stmt, 10, author)
                bind(stmt, 11, article.doi?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased())
                bind(stmt, 12, resolvedPublishedDOI)
                bind(stmt, 13, article.journal)
                bind(stmt, 14, article.publishedYear)
                sqlite3_bind_int(stmt, 15, article.isPaywalled ? 1 : 0)
                bind(stmt, 16, article.paperIngestionMethod?.rawValue)
                bind(stmt, 17, article.paywallSuspicion)
            }
        case .podcast:
            // The count is the stored transcript's. A save carrying the text
            // counts what it just stored; one without it (the in-memory text is
            // let go after every ingest) keeps the count stored with the text,
            // which the in-memory copy may never have seen: hydration, a
            // refetch and every transcript rewrite count it in the store.
            let podcastWordCount: Int?
            if let content = article.content {
                podcastWordCount = Self.storedWordCount(of: content)
            } else {
                let stored = try scalarInteger("""
                    SELECT p.word_count FROM podcasts p
                    JOIN source_content sc ON sc.source_id = p.source_id
                    WHERE p.source_id = ?
                """, [.text(article.id)])
                podcastWordCount = stored.flatMap { $0 > 0 ? Int($0) : nil } ?? article.wordCount
            }
            try execBind("""
                INSERT INTO podcasts
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, show_name, web_page_url, raw_ttml)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    show_name = excluded.show_name,
                    web_page_url = excluded.web_page_url,
                    raw_ttml = COALESCE(excluded.raw_ttml, podcasts.raw_ttml)
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, podcastWordCount)
                bind(stmt, 9, article.artworkURL)
                bind(stmt, 10, article.domain)
                bind(stmt, 11, article.podcastWebPageURL)
                bind(stmt, 12, nil as String?)
            }
        case .book:
            try execBind("""
                INSERT INTO book_sources
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, page_start, page_count)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    page_start = excluded.page_start,
                    page_count = excluded.page_count
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
                bind(stmt, 10, article.bookPages?.lowerBound)
                bind(stmt, 11, article.bookPages?.count)
            }
        case .course:
            try execBind("""
                INSERT INTO course_sources
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
            }
        case .meeting:
            try execBind("""
                INSERT INTO meeting_sources
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, occurred_at, transcript_status, presenter)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    occurred_at = excluded.occurred_at,
                    transcript_status = excluded.transcript_status,
                    presenter = excluded.presenter
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
                sqlite3_bind_double(stmt, 10, article.dateAdded.timeIntervalSinceReferenceDate)
                bind(stmt, 11, article.state == .ready ? "ready" : "missing")
                bind(stmt, 12, author)
            }
        case .video:
            try execBind("""
                INSERT INTO videos
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, platform, liked_at, video_published_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    platform = excluded.platform,
                    -- A save that doesn't carry the feed dates (a rename, a
                    -- transcript write, an inbound CloudKit row from a peer that
                    -- hasn't re-synced yet) must not blank dates we already have.
                    liked_at = COALESCE(excluded.liked_at, videos.liked_at),
                    video_published_at = COALESCE(excluded.video_published_at, videos.video_published_at)
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
                bind(stmt, 10, nil as String?)
                bind(stmt, 11, article.likedAt?.timeIntervalSinceReferenceDate)
                bind(stmt, 12, article.videoPublishedAt?.timeIntervalSinceReferenceDate)
            }
        case .xPost:
            try execBind("""
                INSERT INTO x_posts
                (source_id, url, local_file_path, normalized_url, title, domain, discovery_origin, word_count, artwork_url, author_handle, post_text, author)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url,
                    author_handle = excluded.author_handle,
                    post_text = excluded.post_text,
                    author = excluded.author
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, persistURL)
                bind(stmt, 3, persistLocalPath)
                bind(stmt, 4, normalizedURL)
                bind(stmt, 5, article.title)
                bind(stmt, 6, article.domain)
                bind(stmt, 7, article.discoveryOrigin?.rawValue)
                bind(stmt, 8, article.wordCount)
                bind(stmt, 9, article.artworkURL)
                bind(stmt, 10, nil as String?)
                bind(stmt, 11, article.content)
                // The display name the author backfill looks up; the projection
                // reads it back as `author`, which is what keeps a named post
                // named across reloads.
                bind(stmt, 12, author)
            }
        }

        if article.sourceType == .paper, let persistLocalPath, !persistLocalPath.isEmpty {
            try enqueuePaperFigureIndexIfNeeded(
                sourceID: article.id,
                pdfPath: persistLocalPath,
                // A newly prepared extraction proves that the PDF attachment was
                // read again. Reindex even when it reused the same portable path.
                force: article.paperContentPreparationForPersistence != nil
            )
            // The paper's references are read from this file once it is saved: a queue row
            // only (no PDF is opened here), left as it is when this file was already read.
            try enqueuePaperReferenceRead(sourceID: article.id, pdfPath: persistLocalPath)
        } else if article.sourceType != .paper {
            try dropPaperReferences(sourceID: article.id)
            try execBind("DELETE FROM paper_figure_index_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
            try execBind("DELETE FROM paper_figure_index_state WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
            try execBind("DELETE FROM paper_figures WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
        }

        try execBind("DELETE FROM group_members WHERE source_id = ?") { stmt in
            bind(stmt, 1, article.id)
        }
        // `parentGroup == id` is the whole-book convention: a book that is its own
        // group. It is meaningless for every other type, and a source that leaves
        // `.book` (LLM reclassification, move_source_type, the paper repair) would
        // otherwise keep a self-group whose "name" is a raw source id — which then
        // surfaces as a `src_…` subtitle in the UI. Enforce the invariant here, at
        // the one write choke point, rather than at each individual call site.
        let isWholeBookSelfGroup = article.parentGroup == article.id
        let group = article.sourceType == .book || !isWholeBookSelfGroup
            ? article.parentGroup
            : nil
        if article.sourceType != .book, group == nil {
            // Also covers a source whose `parentGroup` was already cleared in
            // memory by a caller: the `books` row keyed by its own id is orphaned
            // either way. A chapter of a real book keeps a group name that isn't
            // its id, so this never reaches a genuine book's metadata.
            try deleteOrphanedWholeBookMetadata(for: article.id)
        }
        if let group {
            try execBind("""
                INSERT INTO group_members (source_id, group_id, sort_index, lecture_group_id)
                VALUES (?,?,?,?)
            """) { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, group)
                if let sortIndex = article.courseSortIndex {
                    sqlite3_bind_int(stmt, 3, Int32(sortIndex))
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                bind(stmt, 4, article.lectureGroupId)
            }
            if article.status == .active {
                _ = try addSourcesToNotebooksLinkedToCourseInCurrentTransaction(
                    courseID: group,
                    sourceIDs: [article.id]
                )
            }
        }

        if article.status == .archived {
            var affectedGoalIDs: [String] = []
            try queryBind(
                "SELECT DISTINCT goal_id FROM learning_goal_items WHERE source_id = ?",
                bind: { stmt in bind(stmt, 1, article.id) }
            ) { stmt in
                if let goalID = self.string(stmt, 0) {
                    affectedGoalIDs.append(goalID)
                }
            }
            try execBind("DELETE FROM learning_goal_items WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
            let now = Date()
            for goalID in affectedGoalIDs {
                try touchLearningGoal(goalID, at: now)
            }
        }

        let pendingHiddenAt = try loadPendingHiddenSourceDate(article.id)
        // Generation 2: a hide the store already holds keeps its date. `hidden_at` feeds
        // `Mark(hidden).at`, so dating it again sent the Mark to every device on each save of a
        // hidden source, though nothing was hidden again.
        let hideIsStored = try pendingHiddenAt == nil && sourceHideIsStored(article.id)
        let shouldHideSource = (article.isHidden || pendingHiddenAt != nil) && !hideIsStored
        if shouldHideSource {
            try writeSourceHidden(article.id, hidden: true, hiddenAt: pendingHiddenAt ?? Date())
            try deletePendingHiddenSource(article.id)
        }
        if article.sourceType == .podcast, shouldHideSource {
            let hideKey = try personalStateSourceKey(article.id)
            try execBind("""
                INSERT INTO hidden_podcast_episodes (source_id, hidden_at)
                VALUES (?, ?)
                ON CONFLICT(source_id) DO UPDATE SET hidden_at = excluded.hidden_at
            """) { stmt in
                bind(stmt, 1, hideKey)
                sqlite3_bind_double(stmt, 2, (pendingHiddenAt ?? Date()).timeIntervalSinceReferenceDate)
            }
        }
        try retireSourceReviewGuidePreparation(sourceID: article.id)
        _ = try reconcileMemoryItemSourceAnchors(forSourceID: article.id)
        _ = try reconcileScheduledSourcePlacements(forSourceID: article.id)
        // Generation 2 keeps the source's work keys with every save; they only ever add (§4.2).
        try addWorkKeys(workKeys(for: article, hashingFile: false), to: article.id)
        // A show, channel or playlist first met after the activation gets its Collection now: the
        // activation's derivations ran once, and the Source names it by id (§4.4).
        try deriveSourceCollections(onlySource: article.id)
        try derivePlaylistCollections(onlySource: article.id)
        noteStoreChanged()
        return keptStored
    }

    /// The copy `persistSourceRows` writes: under generation 2, a copy read from the store merged over
    /// the row as it is stored now; otherwise the copy itself.
    private func writtenOverStoredRow(_ copy: StudioArticle) throws -> (article: StudioArticle, keptStored: Bool) {
        guard copy.edits.isTracking,
              let stored = try loadSourceWithoutContent(copy.id),
              let written = copy.written(over: stored) else {
            return (copy, false)
        }
        return written
    }

    /// Whether this source's hide is already stored, in either table a hide of it is kept in.
    private func sourceHideIsStored(_ sourceID: String) throws -> Bool {
        let key = try personalStateSourceKey(sourceID)
        return try scalarInteger("""
            SELECT EXISTS(SELECT 1 FROM hidden_sources WHERE source_id = ?1)
                OR EXISTS(SELECT 1 FROM hidden_podcast_episodes WHERE source_id = ?1)
        """, [.text(key)]) == 1
    }

    private func hasPaperContentPreparation(_ sourceID: String) throws -> Bool {
        var exists = false
        try queryBind(
            "SELECT 1 FROM paper_content_preparations WHERE source_id = ? LIMIT 1",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { _ in exists = true }
        return exists
    }

    /// Whether durable readable text exists for this source. `persistSourceRows`
    /// enforces it as the precondition for `ready`; callers that *choose* a state
    /// ahead of a save consult it so they never ask for a state the save rejects.
    func hasReadableSourceContent(_ sourceID: String) throws -> Bool {
        var exists = false
        try queryBind(
            "SELECT 1 FROM source_content WHERE source_id = ? AND TRIM(content) != '' LIMIT 1",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { _ in exists = true }
        return exists
    }

    private func contentPreparationVersion(table: String, sourceID: String) throws -> Int? {
        var version: Int?
        try queryBind(
            "SELECT cleaner_version FROM \(table) WHERE source_id = ? LIMIT 1",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { stmt in version = Int(sqlite3_column_int(stmt, 0)) }
        return version
    }

    func enqueueCanonicalContentCleanupIfNeeded(
        sourceID: String,
        preparationTable: String
    ) throws {
        let target = PaperContentPreparationMetadata.currentVersion
        guard (try contentPreparationVersion(table: preparationTable, sourceID: sourceID) ?? 0) < target else {
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }
        // Hash exactly the text the drain will read, so the queued attempt budget
        // is anchored to the work it was spent on.
        let sourceSHA256 = try canonicalCleanupSourceText(
            sourceID: sourceID,
            preparationTable: preparationTable
        ).map(PaperContentPreparationService.sha256)

        // Re-saving metadata must not revive an exhausted budget — the same text
        // fails the same way, and reviving it re-spends model calls and re-raises
        // the same toast on every activation. Re-extracted text or a newer cleaner
        // contract is genuinely new work and earns a fresh budget.
        try execBind("""
            INSERT INTO canonical_content_cleanup_queue
                (source_id, target_version, enqueued_at, attempt_count, last_error, source_sha256)
            VALUES (?, ?, ?, 0, NULL, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                enqueued_at = excluded.enqueued_at,
                source_sha256 = excluded.source_sha256,
                attempt_count = 0,
                last_error = NULL
            WHERE canonical_content_cleanup_queue.source_sha256 IS NOT excluded.source_sha256
               OR excluded.target_version > canonical_content_cleanup_queue.target_version
        """) { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(target))
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
            if let sourceSHA256 {
                bind(stmt, 4, sourceSHA256)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
        }
    }

    /// The exact text `nextCanonicalContentCleanupCandidate` would hand the
    /// cleaner for this source: the preserved raw extraction when one exists,
    /// otherwise the stored canonical content.
    private func canonicalCleanupSourceText(
        sourceID: String,
        preparationTable: String
    ) throws -> String? {
        var text: String?
        try queryBind("""
            SELECT COALESCE(p.raw_content, sc.content)
            FROM sources s
            LEFT JOIN \(preparationTable) p ON p.source_id = s.id
            LEFT JOIN source_content sc ON sc.source_id = s.id
            WHERE s.id = ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            text = self.string(stmt, 0)
        }
        return text
    }

    private func persistCanonicalContent(for article: StudioArticle) throws {
        let isArticle = article.sourceType == .article
            || article.sourceType == .manual
            || article.sourceType == .unclassified
        guard article.sourceType == .paper || isArticle else {
            if article.sourceType == .podcast,
               let input = article.podcastTranscriptInputForPersistence,
               let clean = article.content,
               let metadata = article.podcastTranscriptCleanupForPersistence {
                guard PaperContentPreparationService.sha256(input) == metadata.inputSHA256,
                      PaperContentPreparationService.sha256(clean) == metadata.cleanSHA256 else {
                    throw KnowledgeStoreError.invalidData(
                        "Synced podcast transcript cleanup failed its integrity check."
                    )
                }
                try writeSourceContent(sourceID: article.id, content: clean)
                try upsertPodcastTranscriptPreparation(
                    sourceID: article.id,
                    input: input,
                    metadata: metadata
                )
                try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, article.id)
                }
                try invalidateCanonicalContentIndexes(sourceID: article.id)
                return
            }
            if let content = article.content,
               try !(article.sourceType == .podcast && isPodcastTranscriptCleanupInput(content, sourceID: article.id)) {
                try writeSourceContent(sourceID: article.id, content: content)
            }
            // Outside the content branch on purpose: a remote update that only
            // restores or unhides an episode carries no transcript, and that
            // episode is exactly the one owed a cleanup it never had. The
            // enqueue reads stored content and visibility itself.
            if article.sourceType == .podcast, article.state == .ready {
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: article.id)
            }
            return
        }

        if article.sourceType == .paper {
            try execBind("DELETE FROM article_content_preparations WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
        } else {
            try execBind("DELETE FROM paper_content_preparations WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
        }

        if isArticle {
            if let raw = article.rawArticleContentForPersistence,
               let clean = article.content,
               let metadata = article.articleContentPreparationForPersistence {
                try writeSourceContent(sourceID: article.id, content: clean)
                try upsertArticleContentPreparation(sourceID: article.id, raw: raw, metadata: metadata)
                if metadata.cleanerVersion >= PaperContentPreparationMetadata.currentVersion {
                    try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                        bind(stmt, 1, article.id)
                    }
                } else {
                    try enqueueCanonicalContentCleanupIfNeeded(
                        sourceID: article.id,
                        preparationTable: "article_content_preparations"
                    )
                }
                try invalidateCanonicalContentIndexes(sourceID: article.id)
                return
            }

            if let raw = article.rawArticleContentForPersistence,
               let metadata = article.articleContentPreparationForPersistence,
               article.state != .ready {
                try upsertArticleContentPreparation(sourceID: article.id, raw: raw, metadata: metadata)
                try execBind("DELETE FROM source_content WHERE source_id = ?") { stmt in
                    bind(stmt, 1, article.id)
                }
                try invalidateCanonicalContentIndexes(sourceID: article.id)
                if article.state == .queued {
                    try enqueueCanonicalContentCleanupIfNeeded(
                        sourceID: article.id,
                        preparationTable: "article_content_preparations"
                    )
                }
                return
            }

            if let content = article.content {
                try writeSourceContent(sourceID: article.id, content: content)
                if article.state == .ready {
                    if TextToSpeechPreparationPolicy.isSpokenScript(url: article.url) {
                        // A spoken script (an explainer, an audio overview's
                        // script) is ForeverLM's own text, written for the
                        // ear and narrated as written. The paid clean-up pass
                        // would rewrite it after its audio was made.
                        try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                            bind(stmt, 1, article.id)
                        }
                    } else {
                        try enqueueCanonicalContentCleanupIfNeeded(
                            sourceID: article.id,
                            preparationTable: "article_content_preparations"
                        )
                    }
                }
            }
            return
        }

        if let raw = article.rawPaperContentForPersistence,
           let clean = article.content,
           let metadata = article.paperContentPreparationForPersistence {
            try writeSourceContent(sourceID: article.id, content: clean)
            try upsertPaperContentPreparation(sourceID: article.id, raw: raw, metadata: metadata)
            if metadata.cleanerVersion >= PaperContentPreparationMetadata.currentVersion {
                try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, article.id)
                }
            } else {
                try enqueueCanonicalContentCleanupIfNeeded(
                    sourceID: article.id,
                    preparationTable: "paper_content_preparations"
                )
            }
            try invalidateCanonicalContentIndexes(sourceID: article.id)
            return
        }

        if let raw = article.rawPaperContentForPersistence,
           let metadata = article.paperContentPreparationForPersistence,
           article.state != .ready {
            try upsertPaperContentPreparation(sourceID: article.id, raw: raw, metadata: metadata)
            try execBind("DELETE FROM source_content WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
            try invalidateCanonicalContentIndexes(sourceID: article.id)
            if article.state == .queued, article.hasPaperIngestionAttestation {
                try enqueueCanonicalContentCleanupIfNeeded(
                    sourceID: article.id,
                    preparationTable: "paper_content_preparations"
                )
            }
            return
        }

        if article.state != .ready, let raw = article.content {
            let metadata = PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: nil,
                preparedAt: nil
            )
            try upsertPaperContentPreparation(sourceID: article.id, raw: raw, metadata: metadata)
            try execBind("DELETE FROM source_content WHERE source_id = ?") { stmt in
                bind(stmt, 1, article.id)
            }
            try invalidateCanonicalContentIndexes(sourceID: article.id)
            return
        }

        if let content = article.content {
            try writeSourceContent(sourceID: article.id, content: content)
            if article.state == .ready {
                try enqueueCanonicalContentCleanupIfNeeded(
                    sourceID: article.id,
                    preparationTable: "paper_content_preparations"
                )
            }
        }
    }

    /// Queues the clean-up an episode's stored transcript is owed.
    ///
    /// - Parameter formatting: set when the transcript just saved is the raw
    ///   one, laid out but never formatted, whose hash is `inputSHA256`. The
    ///   row then owes the whole formatting pass for that text (schema 172),
    ///   and one the learner asked for is queued even while hidden. Any other
    ///   enqueue (a rename, a hide, a synced copy) leaves a pass the row
    ///   already owes as it is: the drain formats only while the stored text
    ///   still hashes to `format_input_sha256`.
    func enqueuePodcastTranscriptCleanupIfNeeded(
        sourceID: String,
        formatting: (request: PodcastTranscriptFormattingRequest, inputSHA256: String)? = nil
    ) throws {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO podcast_transcript_cleanup_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error,
                 format_input_sha256, learner_asked)
            SELECT s.id, ?1, NULL, ?2, 0, NULL, ?4, ?5
            FROM sources s
            JOIN podcasts p ON p.source_id = s.id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN podcast_transcript_preparations prep ON prep.source_id = s.id
            WHERE s.id = ?3
              AND s.source_type = 'podcast'
              AND s.state = 'ready'
              AND s.status = 'active'
              AND TRIM(sc.content) != ''
              AND COALESCE(prep.cleaner_version, 0) < ?1
              AND (?5 = 1 OR (\(Self.podcastEpisodeVisibleSQL(source: "s", podcast: "p"))))
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                source_sha256 = NULL,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL,
                format_input_sha256 = COALESCE(excluded.format_input_sha256, format_input_sha256),
                learner_asked = CASE
                    WHEN excluded.format_input_sha256 IS NULL THEN learner_asked
                    ELSE MAX(learner_asked, excluded.learner_asked)
                END
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(PodcastTranscriptCleanupMetadata.currentVersion))
            sqlite3_bind_double(stmt, 2, now)
            bind(stmt, 3, sourceID)
            if let formatting {
                bind(stmt, 4, formatting.inputSHA256)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, formatting?.request == .learnerAsked ? 1 : 0)
        }
    }

    /// True for an episode the learner sees: not hidden itself, and not on a
    /// hidden show unless the learner made it visible. `source` and `podcast`
    /// are the aliases of its `sources` and `podcasts` rows.
    static func podcastEpisodeVisibleSQL(source: String, podcast: String) -> String {
        """
        NOT EXISTS (SELECT 1 FROM hidden_sources h WHERE h.source_id IN (\(source).id, \(source).wire_key))
        AND NOT EXISTS (SELECT 1 FROM hidden_podcast_episodes h WHERE h.source_id IN (\(source).id, \(source).wire_key))
        AND (
              EXISTS (SELECT 1 FROM visible_podcast_episode_overrides v WHERE v.source_id IN (\(source).id, \(source).wire_key))
           OR NOT EXISTS (
                  SELECT 1 FROM hidden_podcast_shows h
                  WHERE h.show_name = \(podcast).domain OR h.show_name = \(podcast).show_name
              )
        )
        """
    }

    /// A preparation row is an attestation: `raw_sha256` names the exact
    /// text in `raw_content`, and CloudKit, the cleanup drain's compare-and-
    /// swap and every other device rely on it. The one writer of the row
    /// refuses a pair that disagrees, so a row that contradicts itself can
    /// never be stored — it would sync as a record every peer rejects.
    private func requireContentPreparationAttestsRaw(
        _ raw: String,
        metadata: PaperContentPreparationMetadata,
        sourceID: String
    ) throws {
        guard PaperContentPreparationService.sha256(raw) == metadata.rawSHA256 else {
            throw KnowledgeStoreError.invalidData(
                "Source text for \(sourceID) does not match the hash its preparation records."
            )
        }
    }

    func upsertPaperContentPreparation(
        sourceID: String,
        raw: String,
        metadata: PaperContentPreparationMetadata
    ) throws {
        try requireContentPreparationAttestsRaw(raw, metadata: metadata, sourceID: sourceID)
        try execBind("""
            INSERT INTO paper_content_preparations
                (source_id, raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                raw_content = excluded.raw_content,
                raw_sha256 = excluded.raw_sha256,
                clean_sha256 = excluded.clean_sha256,
                cleaner_version = excluded.cleaner_version,
                prepared_at = excluded.prepared_at
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, raw)
            bind(stmt, 3, metadata.rawSHA256)
            bind(stmt, 4, metadata.cleanSHA256)
            sqlite3_bind_int(stmt, 5, Int32(metadata.cleanerVersion))
            if let preparedAt = metadata.preparedAt {
                sqlite3_bind_double(stmt, 6, preparedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
        }
    }

    func upsertArticleContentPreparation(
        sourceID: String,
        raw: String,
        metadata: PaperContentPreparationMetadata
    ) throws {
        try requireContentPreparationAttestsRaw(raw, metadata: metadata, sourceID: sourceID)
        try execBind("""
            INSERT INTO article_content_preparations
                (source_id, raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                raw_content = excluded.raw_content,
                raw_sha256 = excluded.raw_sha256,
                clean_sha256 = excluded.clean_sha256,
                cleaner_version = excluded.cleaner_version,
                prepared_at = excluded.prepared_at
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, raw)
            bind(stmt, 3, metadata.rawSHA256)
            bind(stmt, 4, metadata.cleanSHA256)
            sqlite3_bind_int(stmt, 5, Int32(metadata.cleanerVersion))
            if let preparedAt = metadata.preparedAt {
                sqlite3_bind_double(stmt, 6, preparedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
        }
    }

    /// Drops a source's embeddings, full-text row and index state, so the
    /// indexer derives them again from the text now stored.
    func invalidateCanonicalContentIndexes(sourceID: String) throws {
        try dropCanonicalContentIndexes(sourceID: sourceID)
        // The canonical text changed, so the text satellite other devices take it from is out of date
        // (generation 2: the publisher lays it out and uploads it again; a no-op under generation 1).
        try queueSourceFilesRefresh(sourceID: sourceID)
    }

    /// This Mac's search index of a source's text: its vectors, its keyword rows and the stamp naming the
    /// text they were built from. Dropped whenever the text changes, so the indexer builds them again; the
    /// indexer notices a change of length by itself (`sourcesMissingIndex`), but not new words of the same
    /// length.
    func dropCanonicalContentIndexes(sourceID: String) throws {
        try execBind("DELETE FROM embeddings WHERE entity_type = ? AND entity_id = ?") { stmt in
            bind(stmt, 1, KnowledgeEntityType.source.rawValue)
            bind(stmt, 2, sourceID)
        }
        try deleteEmbeddings(
            entityType: .sourceChunk,
            entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: sourceID)
        )
        try deleteSourceFTS(sourceID: sourceID)
        try deleteSourceIndexState(sourceID: sourceID)
    }

}
