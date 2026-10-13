import Foundation
import SQLite3
import OSLog
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

    /// Source payload identity is derived from the canonical subtype rows rather
    /// than duplicated onto `StudioArticle`. Apply it in the same transaction as
    /// the aggregate so a published DOI can never arrive without its Source row.
    func saveSourceFromSync(
        _ article: StudioArticle,
        portableIdentity: CloudKitSourceIdentityPayload?
    ) throws {
        if let portableIdentity, portableIdentity.sourceID != article.id {
            throw KnowledgeStoreError.invalidData(
                "Synced Source portable identity points to a different source."
            )
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let sourceWasMissing = !(try sourceExists(article.id))
            let publishedDOI = portableIdentity?.publishedDOI?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            // Persist portable identity before the targeted anchor reconciliation
            // at the end of persistSourceRows. Item-before-Source delivery may
            // have only publishedDOI available to map the remote source ID.
            try persistSourceRows(
                article,
                publishedDOI: publishedDOI?.isEmpty == false ? publishedDOI : nil
            )
            if sourceWasMissing {
                try restoreDeferredReviewSessionSourceLinks(sourceID: article.id)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
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
        let seedsReadingState = try keepsReadingStates
            && scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(article.id)]) != 1
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
        try persistCanonicalContent(for: article)
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
        } else if article.sourceType != .paper {
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
                try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            }
        }

        let pendingHiddenAt = try loadPendingHiddenSourceDate(article.id)
        // Generation 2: a hide the store already holds keeps its date. `hidden_at` feeds
        // `Mark(hidden).at`, so dating it again sent the Mark to every device on each save of a
        // hidden source, though nothing was hidden again.
        let hideIsStored = try pendingHiddenAt == nil && syncGeneration == .two && sourceHideIsStored(article.id)
        let shouldHideSource = (article.isHidden || pendingHiddenAt != nil) && !hideIsStored
        if shouldHideSource {
            try writeSourceHidden(article.id, hidden: true, hiddenAt: pendingHiddenAt ?? Date())
            try deletePendingHiddenSource(article.id)
            try markRecordChanged(entity: .hiddenSource, logicalKey: article.id)
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
        if syncGeneration == .two {
            try addWorkKeys(workKeys(for: article, hashingFile: false), to: article.id)
            // A show, channel or playlist first met after the activation gets its Collection now: the
            // activation's derivations ran once, and the Source names it by id (§4.4).
            try deriveSourceCollections(onlySource: article.id)
            try derivePlaylistCollections(onlySource: article.id)
        }
        try markRecordChanged(entity: .source, logicalKey: article.id)
        return keptStored
    }

    /// The copy `persistSourceRows` writes: under generation 2, a copy read from the store merged over
    /// the row as it is stored now; otherwise the copy itself.
    private func writtenOverStoredRow(_ copy: StudioArticle) throws -> (article: StudioArticle, keptStored: Bool) {
        guard syncGeneration == .two, copy.edits.isTracking,
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

    private func enqueueCanonicalContentCleanupIfNeeded(
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
                try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?,?)") { stmt in
                    bind(stmt, 1, article.id)
                    bind(stmt, 2, clean)
                }
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
                try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?,?)") { stmt in
                    bind(stmt, 1, article.id)
                    bind(stmt, 2, content)
                }
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
                try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?,?)") { stmt in
                    bind(stmt, 1, article.id)
                    bind(stmt, 2, clean)
                }
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
                try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?,?)") { stmt in
                    bind(stmt, 1, article.id)
                    bind(stmt, 2, content)
                }
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
            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?,?)") { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, clean)
            }
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
            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?,?)") { stmt in
                bind(stmt, 1, article.id)
                bind(stmt, 2, content)
            }
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

    private func upsertPaperContentPreparation(
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

    private func upsertArticleContentPreparation(
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

    func updateSourceReadingPosition(sourceID: String, page: Int?) throws {
        if keepsReadingStates {
            try writeReadingPlace(sourceID: sourceID, page: .some(page))
            return
        }
        try execBind("""
            UPDATE sources
            SET reading_position_page = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, page)
            bind(stmt, 2, sourceID)
        }
        try markSourceProgressChanged(sourceID: sourceID)
    }

    /// A video's progress is joined with what is stored rather than written
    /// over it (`VideoWatchProgress.mergedLocator`, the new write owning the
    /// position): a reader's write that was already on its way when the video
    /// was marked not watched, here or by a record from another device, cannot
    /// bring back what the mark cleared, and a lower watched mark never
    /// replaces a higher one. Every other locator is written as given.
    func updateSourceReadingLocator(sourceID: String, locator: String?) throws {
        guard let locator, VideoWatchProgress(encoded: locator) != nil else {
            try writeSourceReadingLocator(sourceID: sourceID, locator: locator)
            return
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let merged = VideoWatchProgress.mergedLocator(
                owner: locator,
                other: try loadSourceReadingLocator(sourceID: sourceID)
            )
            try writeSourceReadingLocator(sourceID: sourceID, locator: merged)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func writeSourceReadingLocator(sourceID: String, locator: String?) throws {
        if keepsReadingStates {
            try writeReadingPlace(sourceID: sourceID, macLocator: .some(locator))
            return
        }
        try execBind("""
            UPDATE sources
            SET reading_position_locator = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, locator)
            bind(stmt, 2, sourceID)
        }
        try markSourceProgressChanged(sourceID: sourceID)
    }

    /// Mark as Watched and Mark as Not Watched (the Sources sidebar, the
    /// Reader, `set_source_read`), in one transaction.
    ///
    /// Not watched clears everything that makes a video read as watched: the
    /// watch progress becomes `VideoWatchProgress.notWatched`, whose new epoch
    /// outranks every earlier save when the record meets another device's copy,
    /// and the read stamp a finished Schedule item or Log as Listened left is
    /// cleared. Nothing else moves: the Schedule placement, the activity
    /// history and any review keep what happened (a review still finishes a
    /// course lecture). A video with nothing to clear is left alone.
    ///
    /// Watched sets the progress to the end (`markedWatched`) and leaves the
    /// read stamp as it is, the same as playing the video to its end; a video
    /// already watched is left alone. It needs the length, so a video that has
    /// never played throws.
    ///
    /// Both queue the source as a progress-only change, the way a reader's
    /// position does, so a rename made on another Mac still wins its fields.
    @discardableResult
    func setVideoWatched(sourceID: String, watched: Bool, at date: Date = Date()) throws -> VideoWatchedMark {
        try exec("BEGIN IMMEDIATE")
        do {
            guard let row = try loadSourceProgress(sourceID: sourceID) else {
                throw KnowledgeStoreError.invalidData("Source not found: \(sourceID)")
            }
            let current = VideoWatchProgress(encoded: row.locator)
            let unchanged = VideoWatchedMark(locator: row.locator, readAt: row.readAt, changed: false)
            let next: (locator: String?, readAt: Date?)
            if watched {
                if current?.isEssentiallyWatched == true {
                    try exec("COMMIT")
                    return unchanged
                }
                guard let finished = current?.markedWatched() else {
                    throw KnowledgeStoreError.invalidData(
                        "This video's length isn't known yet. It is learned the first time the video plays in the Reader."
                    )
                }
                next = (finished.encoded, row.readAt)
            } else {
                if current?.recordsWatching != true, row.readAt == nil {
                    try exec("COMMIT")
                    return unchanged
                }
                next = (VideoWatchProgress.notWatched(from: current, at: date).encoded, nil)
            }
            if keepsReadingStates {
                try writeReadingPlace(sourceID: sourceID, macLocator: .some(next.locator), readAt: .some(next.readAt), at: date)
                if !watched { try updateReadingState(sourceID: sourceID) { self.resetReadingProgress(&$0) } }
                try exec("COMMIT")
                return VideoWatchedMark(locator: next.locator, readAt: next.readAt, changed: true)
            }
            try execBind("""
                UPDATE sources
                SET reading_position_locator = ?1,
                    read_at = ?2
                WHERE id = ?3
            """) { stmt in
                bind(stmt, 1, next.locator)
                bind(stmt, 2, next.readAt?.timeIntervalSinceReferenceDate)
                bind(stmt, 3, sourceID)
            }
            try markSourceProgressChanged(sourceID: sourceID, at: date)
            try exec("COMMIT")
            return VideoWatchedMark(locator: next.locator, readAt: next.readAt, changed: true)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadSourceReadingLocator(sourceID: String) throws -> String? {
        if keepsReadingStates { return try readingMacLocator(sourceID: sourceID) }
        var locator: String?
        try queryBind("""
            SELECT reading_position_locator
            FROM sources
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            locator = string(stmt, 0)
        }
        return locator
    }

    /// The locator and read stamp a source has now, or nil when there is no
    /// such source: the two fields a video's watched state is made of.
    func loadSourceProgress(sourceID: String) throws -> (locator: String?, readAt: Date?)? {
        if keepsReadingStates {
            guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(sourceID)]) == 1 else { return nil }
            let row = try loadReadingState(sourceID: sourceID)
            return (ReadingLocatorCodec.macLocator(wire: row?.locator), row?.readAt.map(Date.init(timeIntervalSinceReferenceDate:)))
        }
        var progress: (locator: String?, readAt: Date?)?
        try queryBind("""
            SELECT reading_position_locator, read_at
            FROM sources
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            progress = (string(stmt, 0), optionalDouble(stmt, 1).map(Date.init(timeIntervalSinceReferenceDate:)))
        }
        return progress
    }

    func updateSourceReadAt(sourceID: String, readAt: Date?) throws {
        if keepsReadingStates {
            // Marking it unread also starts the furthest progress over (§3.5.18).
            try updateReadingState(sourceID: sourceID) { row in
                row.readAt = readAt?.timeIntervalSinceReferenceDate
                if readAt == nil { self.resetReadingProgress(&row) }
            }
            if let readAt { try completeAssignedTasks(forSourceID: sourceID, at: readAt) }
            return
        }
        try execBind("""
            UPDATE sources
            SET read_at = ?
            WHERE id = ?
        """) { stmt in
            if let readAt {
                sqlite3_bind_double(stmt, 1, readAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            bind(stmt, 2, sourceID)
        }
        try markSourceProgressChanged(sourceID: sourceID)
        // Finishing a source finishes what was assigned for it
        // (docs/family-design.md). Marking it unread leaves the task alone.
        if let readAt {
            try completeAssignedTasks(forSourceID: sourceID, at: readAt)
        }
    }

    /// Reinstate this device's reading progress after an inbound record wrote
    /// the sending device's progress over it. Only used by the conflict path,
    /// where the local progress is newer by definition; the ordinary inbound
    /// apply has no local edit to protect and takes the record as sent.
    ///
    /// Returns whether anything actually changed, so the caller only republishes
    /// a row that now differs from the server snapshot it just adopted.
    @discardableResult
    func restoreSourceReadingProgress(
        sourceID: String,
        page: Int?,
        locator: String?,
        readAt: Date?
    ) throws -> Bool {
        try execBind("""
            UPDATE sources
            SET reading_position_page = ?1,
                reading_position_locator = ?2,
                read_at = ?3
            WHERE id = ?4
              AND (reading_position_page IS NOT ?1
                OR reading_position_locator IS NOT ?2
                OR read_at IS NOT ?3)
        """) { stmt in
            bind(stmt, 1, page)
            bind(stmt, 2, locator)
            if let readAt {
                sqlite3_bind_double(stmt, 3, readAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bind(stmt, 4, sourceID)
        }
        return sqlite3_changes(db) > 0
    }

    /// Record the Liked-feed dates for a video. Called per item on every Liked
    /// sync, which is also what backfills rows that predate these columns —
    /// there is no separate migration. Each argument is only written when
    /// non-nil, so a feed that omits one date can't erase a stored one.
    @discardableResult
    func updateVideoFeedDates(sourceID: String, likedAt: Date?, videoPublishedAt: Date?) throws -> Bool {
        guard likedAt != nil || videoPublishedAt != nil else { return false }
        try execBind("""
            UPDATE videos
            SET liked_at = COALESCE(?1, liked_at),
                video_published_at = COALESCE(?2, video_published_at)
            WHERE source_id = ?3
              AND ((?1 IS NOT NULL AND liked_at IS NOT ?1)
                OR (?2 IS NOT NULL AND video_published_at IS NOT ?2))
        """) { stmt in
            bind(stmt, 1, likedAt?.timeIntervalSinceReferenceDate)
            bind(stmt, 2, videoPublishedAt?.timeIntervalSinceReferenceDate)
            bind(stmt, 3, sourceID)
        }
        guard sqlite3_changes(db) > 0 else { return false }
        try markRecordChanged(entity: .source, logicalKey: sourceID)
        return true
    }

    static func defaultPublicURL(for article: StudioArticle) -> String? {
        func http(_ value: String?) -> String? {
            guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  clean.hasPrefix("http://") || clean.hasPrefix("https://") else {
                return nil
            }
            return clean
        }
        func searchURL(_ base: String, itemName: String, query: String) -> String {
            var components = URLComponents(string: base)
            components?.queryItems = [URLQueryItem(name: itemName, value: query)]
            return components?.url?.absoluteString ?? base
        }

        switch article.sourceType {
        case .podcast:
            if let url = http(article.url), URL(string: url)?.host?.lowercased().contains("podcasts.apple.com") == true {
                return url
            }
            if let url = http(article.podcastWebPageURL) ?? http(article.url) ?? http(article.normalizedURL) {
                return url
            }
            return searchURL("https://podcasts.apple.com/us/search", itemName: "term", query: article.title)
        case .paper:
            if let url = http(article.url) ?? http(article.normalizedURL) {
                return url
            }
            if let doi = article.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty {
                return "https://doi.org/\(doi.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            }
            return searchURL("https://scholar.google.com/scholar", itemName: "q", query: article.title)
        case .book:
            if let url = http(article.url) ?? http(article.normalizedURL) {
                return url
            }
            return searchURL("https://www.amazon.com/s", itemName: "k", query: article.parentGroup ?? article.title)
        case .article, .video, .xPost, .manual, .unclassified, .course, .meeting:
            return http(article.url) ?? http(article.normalizedURL)
        }
    }

    /// A hide is the member's, kept under the source's wire id under generation 2 so a team's copy and the
    /// personal copy share it (`personalStateSourceKey`); under generation 1 the caller's id.
    func writeSourceHidden(_ sourceID: String, hidden: Bool, hiddenAt: Date = Date()) throws {
        let key = try personalStateSourceKey(sourceID)
        if hidden {
            try execBind("""
                INSERT INTO hidden_sources (source_id, hidden_at)
                VALUES (?, ?)
                ON CONFLICT(source_id) DO UPDATE SET hidden_at = excluded.hidden_at
            """) { stmt in
                bind(stmt, 1, key)
                sqlite3_bind_double(stmt, 2, hiddenAt.timeIntervalSinceReferenceDate)
            }
        } else {
            try execBind("DELETE FROM hidden_sources WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
        }
    }

    func sourceExists(_ sourceID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM sources WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { _ in
            found = true
        }
        return found
    }

    /// Resolve a source id carried by a `foreverlm://source/<token>` citation link to a
    /// real `sources.id`, tolerating the ways an assistant mangles the long id when it
    /// writes the link. Tries, in order:
    ///   1. Exact match (the id was copied verbatim).
    ///   2. Unique prefix match (the id was truncated from the end — the common failure,
    ///      and also how the shortened deep-link tokens resolve). Only resolves when
    ///      exactly one source id starts with the token, so a token can never open the
    ///      wrong source.
    /// Returns the canonical id, or nil when nothing matches or a prefix is ambiguous.
    func resolveSourceID(forLinkToken token: String) throws -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if try sourceExists(trimmed) { return trimmed }

        // Guard against very short tokens matching too broadly. A real id prefix carries
        // plenty of entropy well before this; anything shorter is not worth guessing on.
        guard trimmed.count >= 8 else { return nil }

        // Escape LIKE metacharacters so a token containing % or _ can't widen the match.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var matches: [String] = []
        try queryBind(
            "SELECT id FROM sources WHERE id LIKE ? ESCAPE '\\' LIMIT 2",
            bind: { stmt in bind(stmt, 1, escaped + "%") }
        ) { stmt in
            if let id = string(stmt, 0) { matches.append(id) }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func loadPendingHiddenSourceDate(_ sourceID: String) throws -> Date? {
        var date: Date?
        try queryBind("SELECT hidden_at FROM pending_hidden_sources WHERE source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return date
    }

    func savePendingHiddenSource(_ sourceID: String, hiddenAt: Date) throws {
        try execBind("""
            INSERT INTO pending_hidden_sources (source_id, hidden_at)
            VALUES (?, ?)
            ON CONFLICT(source_id) DO UPDATE SET hidden_at = excluded.hidden_at
        """) { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, hiddenAt.timeIntervalSinceReferenceDate)
        }
    }

    func deletePendingHiddenSource(_ sourceID: String) throws {
        try execBind("DELETE FROM pending_hidden_sources WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    /// Drop the `books` metadata row a whole-book source keyed under its own id,
    /// once that source is no longer a book. Mirrors `deleteSubtypeRows`: stale
    /// rows from a previous type must not outlive the type change. Only ever
    /// touches self-keyed rows, so real books (UUID group ids, many chapters)
    /// are untouched even if a chapter is reclassified.
    func deleteOrphanedWholeBookMetadata(for sourceId: String) throws {
        var exists = false
        try queryBind("SELECT 1 FROM books WHERE id = ?", bind: { stmt in
            bind(stmt, 1, sourceId)
        }) { _ in exists = true }
        guard exists else { return }
        try execBind("DELETE FROM books WHERE id = ?") { stmt in
            bind(stmt, 1, sourceId)
        }
        try markRecordDeleted(entity: .book, logicalKey: sourceId)
    }

    func deleteSubtypeRows(for sourceId: String, except sourceType: StudioSourceType) throws {
        let tableByType: [(StudioSourceType, String)] = [
            (.article, "articles"),
            (.manual, "articles"),
            (.unclassified, "articles"),
            (.paper, "papers"),
            (.podcast, "podcasts"),
            (.book, "book_sources"),
            (.course, "course_sources"),
            (.meeting, "meeting_sources"),
            (.video, "videos"),
            (.xPost, "x_posts"),
        ]

        let keepTables = Set(tableByType.filter { $0.0 == sourceType }.map(\.1))
        let allTables = Set(tableByType.map(\.1))
        for table in allTables where !keepTables.contains(table) {
            try execBind("DELETE FROM \(table) WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceId)
            }
        }
    }

    static let sourceColumns = """
        sp.id, sp.url, sp.title, sp.domain, sp.date_added, sp.word_count, sp.state, sp.error_message,
        sp.source_type, sp.artwork_url, sp.discovery_origin, sp.local_file_path, sp.author,
        sp.status, sp.archived_at, sp.normalized_url, sp.public_url,
        sp.reading_position_page, sp.reading_position_locator,
        sp.journal, sp.published_year, sp.is_paywalled,
        sp.doi,
        sp.podcast_web_page_url,
        sp.parent_group, sp.group_sort_index, sp.lecture_group_id,
        sp.is_hidden, sp.read_at,
        sp.liked_at, sp.video_published_at,
        sp.connector_label,
        sp.paper_ingestion_method,
        CASE
            WHEN pcp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
             AND pcp.clean_sha256 IS NOT NULL
            THEN pcp.raw_sha256
        END,
        CASE
            WHEN lc.source_id IS NOT NULL
             AND lc.generator_version >= \(SourceListenableContentMetadata.currentVersion)
             AND lc.preparation_signature LIKE '\(PaperNarrationFilter.preparationContractPrefix)%'
             AND lcq.source_id IS NULL
            THEN 1 ELSE 0
        END,
        sp.published_doi,
        sp.team_id,
        sp.paywall_suspicion,
        sp.book_page_start, sp.book_page_count
    """

    static let sourceJoins = """
        FROM source_projection sp
        LEFT JOIN paper_content_preparations pcp ON pcp.source_id = sp.id
        LEFT JOIN source_listenable_content lc ON lc.source_id = sp.id
        LEFT JOIN source_listenable_content_queue lcq ON lcq.source_id = sp.id
    """

    func loadSources() throws -> [StudioArticle] {
        var articles = try loadSourcesWithoutContent()
        guard !articles.isEmpty else { return [] }
        let contents = try loadSourceContents(for: articles.map(\.id))
        for index in articles.indices {
            articles[index].content = contents[articles[index].id]
        }
        return articles
    }

    func loadSourceContents(for sourceIDs: [String]) throws -> [String: String] {
        let uniqueIDs = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return [:] }

        var contents: [String: String] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < uniqueIDs.count {
            let chunk = Array(uniqueIDs[offset..<min(offset + chunkSize, uniqueIDs.count)])
            offset += chunkSize
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT source_id, content FROM source_content WHERE source_id IN (\(placeholders))"
            try queryBind(sql, bind: { stmt in
                for (index, sourceID) in chunk.enumerated() {
                    self.bind(stmt, index + 1, sourceID)
                }
            }) { stmt in
                guard let sourceID = self.string(stmt, 0),
                      let content = self.string(stmt, 1) else { return }
                contents[sourceID] = content
            }
        }
        return contents
    }

    /// Stored content length per source, without materializing any text.
    ///
    /// The chat manifest needs an honest size signal for every attached source
    /// and the readability probe needs to know which sources have text at all.
    /// Answering either question by loading the documents themselves is what
    /// this avoids: a notebook pool can hold hundreds of sources, and a book
    /// chapter set alone runs to hundreds of thousands of characters.
    ///
    /// Sources with no `source_content` row are absent from the result rather
    /// than reported as zero — a missing row is not proof of missing text,
    /// since PDF text extracted at index time lands in `source_fts` without
    /// being written back here.
    func sourceContentLengths(for sourceIDs: [String]) throws -> [String: Int] {
        let uniqueIDs = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return [:] }

        var lengths: [String: Int] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < uniqueIDs.count {
            let chunk = Array(uniqueIDs[offset..<min(offset + chunkSize, uniqueIDs.count)])
            offset += chunkSize
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT source_id, LENGTH(content) FROM source_content WHERE source_id IN (\(placeholders))"
            try queryBind(sql, bind: { stmt in
                for (index, sourceID) in chunk.enumerated() {
                    self.bind(stmt, index + 1, sourceID)
                }
            }) { stmt in
                guard let sourceID = self.string(stmt, 0),
                      let length = self.optionalInt(stmt, 1) else { return }
                lengths[sourceID] = length
            }
        }
        return lengths
    }

    func loadSourcesWithoutContent() throws -> [StudioArticle] {
        let sql = "SELECT \(Self.sourceColumns) \(Self.sourceJoins) ORDER BY sp.date_added DESC"
        var articles: [StudioArticle] = []
        try query(sql) { stmt in
            if let article = readSourceRow(stmt) {
                articles.append(article)
            }
        }
        return articles
    }

    func loadSourceContent(_ sourceId: String) throws -> String? {
        var result: String?
        try queryBind("SELECT content FROM source_content WHERE source_id = ?", bind: { stmt in
            self.bind(stmt, 1, sourceId)
        }) { stmt in
            result = self.string(stmt, 0)
        }
        return result
    }

    func loadPaperContentPreparation(
        _ sourceID: String
    ) throws -> (raw: String, metadata: PaperContentPreparationMetadata)? {
        var result: (String, PaperContentPreparationMetadata)?
        try queryBind("""
            SELECT raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at
            FROM paper_content_preparations
            WHERE source_id = ?
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let raw = self.string(stmt, 0), let rawHash = self.string(stmt, 1) else { return }
            let preparedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            result = (
                raw,
                PaperContentPreparationMetadata(
                    cleanerVersion: Int(sqlite3_column_int(stmt, 3)),
                    rawSHA256: rawHash,
                    cleanSHA256: self.string(stmt, 2),
                    preparedAt: preparedAt
                )
            )
        }
        return result
    }

    func loadArticleContentPreparation(
        _ sourceID: String
    ) throws -> (raw: String, metadata: PaperContentPreparationMetadata)? {
        var result: (String, PaperContentPreparationMetadata)?
        try queryBind("""
            SELECT raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at
            FROM article_content_preparations
            WHERE source_id = ?
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let raw = self.string(stmt, 0), let rawHash = self.string(stmt, 1) else { return }
            let preparedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            result = (
                raw,
                PaperContentPreparationMetadata(
                    cleanerVersion: Int(sqlite3_column_int(stmt, 3)),
                    rawSHA256: rawHash,
                    cleanSHA256: self.string(stmt, 2),
                    preparedAt: preparedAt
                )
            )
        }
        return result
    }

    func nextCanonicalContentCleanupCandidate() throws -> CanonicalContentCleanupCandidate? {
        try canonicalContentCleanupCandidates(limit: 1).first
    }

    /// Durable preparation work is meaningful only while its source remains
    /// active and in the supported article/paper set. Normal archive paths
    /// already remove these rows transactionally; this bounded set-based prune
    /// handles historical or synced status changes that predate that invariant.
    func pruneIneligibleCanonicalContentCleanupQueue() throws -> Int {
        // A spoken script is never cleaned (see `saveSource`); an explainer
        // queued by a build before that rule leaves the queue here.
        try exec("""
            DELETE FROM canonical_content_cleanup_queue
            WHERE EXISTS (
                SELECT 1
                FROM sources s
                WHERE s.id = canonical_content_cleanup_queue.source_id
                  AND (
                        s.status != 'active'
                     OR s.source_type NOT IN ('article', 'paper')
                  )
            )
            OR EXISTS (
                SELECT 1
                FROM articles a
                WHERE a.source_id = canonical_content_cleanup_queue.source_id
                  AND \(Self.spokenScriptURLMatch("a.url"))
            )
        """)
        return Int(sqlite3_changes(db))
    }

    /// SQL that is true for a row whose URL `column` names a spoken script
    /// ForeverLM wrote: an explainer, or an audio overview's script
    /// (`TextToSpeechPreparationPolicy.spokenScriptURLPrefixes`; neither prefix
    /// holds a LIKE wildcard).
    static func spokenScriptURLMatch(_ column: String) -> String {
        "(" + TextToSpeechPreparationPolicy.spokenScriptURLPrefixes
            .map { "COALESCE(\(column), '') LIKE '\($0)%'" }
            .joined(separator: " OR ") + ")"
    }

    /// SQL that is true for every row but an audio overview's script, by its
    /// URL `column`: the retelling is kept out of Memory, idea extraction and
    /// the search indexes, so a review or a citation never lands on it
    /// instead of the sources it retells.
    static func notAudioOverviewScriptURL(_ column: String) -> String {
        "COALESCE(\(column), '') NOT LIKE '\(TextToSpeechPreparationPolicy.audioOverviewURLPrefix)%'"
    }

    /// - Parameter pendingIngestionOnly: restrict the batch to sources whose
    ///   ingestion is waiting on this pass (`queued`), leaving the historical
    ///   re-clean rows for a drain that is allowed to spend a model on them.
    func canonicalContentCleanupCandidates(
        limit: Int,
        pendingIngestionOnly: Bool = false
    ) throws -> [CanonicalContentCleanupCandidate] {
        guard limit > 0 else { return [] }
        var results: [CanonicalContentCleanupCandidate] = []
        let stateClause = pendingIngestionOnly
            ? "s.state = 'queued'"
            : "s.state IN ('ready', 'queued')"
        try queryBind("""
            SELECT s.id,
                   COALESCE(p.title, a.title, 'Untitled'),
                   s.source_type,
                   CASE WHEN s.source_type = 'paper'
                        THEN COALESCE(pp.raw_content, sc.content)
                        ELSE COALESCE(ap.raw_content, sc.content)
                   END,
                   s.state,
                   CASE WHEN s.source_type = 'paper' THEN p.local_file_path ELSE a.local_file_path END
            FROM canonical_content_cleanup_queue q
            JOIN sources s ON s.id = q.source_id
            LEFT JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN papers p ON p.source_id = s.id
            LEFT JOIN articles a ON a.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            WHERE \(stateClause)
              AND s.status = 'active'
              AND NOT \(Self.spokenScriptURLMatch("a.url"))
              AND q.target_version <= \(PaperContentPreparationMetadata.currentVersion)
              -- A bulk re-queue waits for the learner (schema 135).
              AND \(Self.bulkHoldExclusion(.canonicalCleanup))
            -- Untouched work goes first so one provider-sensitive paper cannot
            -- repeatedly occupy a catch-up batch and starve the rest. Within
            -- each group, newly ingested sources still become usable first.
            ORDER BY CASE WHEN q.last_error IS NULL THEN 0 ELSE 1 END,
                     s.date_added DESC,
                     q.enqueued_at,
                     s.id
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }) { stmt in
            guard let sourceID = string(stmt, 0),
                  let title = string(stmt, 1),
                  let rawType = string(stmt, 2),
                  let sourceType = StudioSourceType(rawValue: rawType),
                  let raw = string(stmt, 3),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            results.append(CanonicalContentCleanupCandidate(
                sourceID: sourceID,
                title: title,
                sourceType: sourceType,
                raw: raw,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                isPendingIngestion: self.string(stmt, 4) == StudioArticleState.queued.rawValue,
                localFilePath: self.string(stmt, 5)
            ))
        }
        return results
    }

    func canonicalContentCleanupQueueCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*) FROM canonical_content_cleanup_queue
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// One bounded batch of the schema-134 integrity audit.
    ///
    /// Until `SQLiteText`, a text bind stopped at the string's first U+0000, so
    /// a PDF whose extraction carried one (PDFKit's unmapped glyph) stored only
    /// the text before it while the preparation's hashes, computed in Swift,
    /// described the whole extraction. Such a row claims a cleanup it does not
    /// hold, so the audit hashes each queued row's stored raw text and, where it
    /// disagrees with `raw_sha256`, restates the preparation as what it is — an
    /// uncleaned extraction of the stored text, version 0 — and queues the
    /// source for the canonical cleanup, whose drain extracts the PDF again.
    /// Rows that agree are only dequeued. No model is called here, and the
    /// Source record is marked changed so the copy other devices hold stops
    /// contradicting itself too.
    func auditCanonicalContentIntegrity(
        limit: Int
    ) throws -> (audited: Int, requeuedSourceIDs: [String], remaining: Int) {
        let pending = try canonicalContentIntegrityAuditQueueCount()
        // Once the queue is empty — every launch after the first — the audit
        // is one count and never takes the write lock.
        guard limit > 0, pending > 0 else { return (0, [], pending) }
        try exec("BEGIN IMMEDIATE")
        do {
            var rows: [(sourceID: String, table: String?, raw: String?, rawSHA256: String?)] = []
            try queryBind("""
                SELECT q.source_id,
                       CASE WHEN pp.source_id IS NOT NULL THEN 'paper_content_preparations'
                            WHEN ap.source_id IS NOT NULL THEN 'article_content_preparations'
                       END,
                       COALESCE(pp.raw_content, ap.raw_content),
                       COALESCE(pp.raw_sha256, ap.raw_sha256)
                FROM canonical_content_integrity_audit_queue q
                LEFT JOIN paper_content_preparations pp ON pp.source_id = q.source_id
                LEFT JOIN article_content_preparations ap ON ap.source_id = q.source_id
                ORDER BY q.enqueued_at, q.source_id
                LIMIT ?
            """, bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            }) { stmt in
                guard let sourceID = self.string(stmt, 0) else { return }
                rows.append((sourceID, self.string(stmt, 1), self.string(stmt, 2), self.string(stmt, 3)))
            }

            var requeued: [String] = []
            for row in rows {
                if let table = row.table, let raw = row.raw, let recorded = row.rawSHA256 {
                    let actual = PaperContentPreparationService.sha256(raw)
                    if actual != recorded {
                        try execBind("""
                            UPDATE \(table)
                            SET raw_sha256 = ?, clean_sha256 = NULL, cleaner_version = 0, prepared_at = NULL
                            WHERE source_id = ? AND raw_sha256 = ?
                        """) { stmt in
                            bind(stmt, 1, actual)
                            bind(stmt, 2, row.sourceID)
                            bind(stmt, 3, recorded)
                        }
                        try enqueueCanonicalContentCleanupIfNeeded(
                            sourceID: row.sourceID,
                            preparationTable: table
                        )
                        try markRecordChanged(entity: .source, logicalKey: row.sourceID)
                        requeued.append(row.sourceID)
                    }
                }
                try execBind("DELETE FROM canonical_content_integrity_audit_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, row.sourceID)
                }
            }
            let remaining = try canonicalContentIntegrityAuditQueueCount()
            try exec("COMMIT")
            return (rows.count, requeued, remaining)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func canonicalContentIntegrityAuditQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM canonical_content_integrity_audit_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// - Parameter consumesAttempt: `false` for provider, network, or
    ///   configuration failures. Those say nothing about whether this source can
    ///   ever be cleaned, so they record the error and move the source to the
    ///   back of the queue without spending its budget.
    func recordCanonicalContentCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String? = nil,
        consumesAttempt: Bool = true
    ) throws {
        try execBind("""
            UPDATE canonical_content_cleanup_queue
            SET attempt_count = attempt_count + ?,
                last_error = ?,
                enqueued_at = ?,
                source_sha256 = COALESCE(?, source_sha256)
            WHERE source_id = ?
        """) { stmt in
            sqlite3_bind_int(stmt, 1, consumesAttempt ? 1 : 0)
            bind(stmt, 2, message)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 4, sourceSHA256)
            bind(stmt, 5, sourceID)
        }
    }

    /// A queued source is a new ingestion, not a historical re-clean. When its
    /// durable retry reaches a permanent failure, surface that failure and
    /// retire only this queue row. Ready sources keep their last good canonical
    /// text and remain eligible for a later historical cleanup retry.
    func failPendingCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        message: String
    ) throws {
        guard candidate.isPendingIngestion else { return }
        let visibleMessage = candidate.sourceType == .paper
            ? StudioArticle.paperContentCleanupFailureMessage(message)
            : PaperContentPreparationService.articleIngestionFailureMessage(
                for: AIError.apiError(message)
            )
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE sources
                SET state = 'error', error_message = ?
                WHERE id = ? AND state = 'queued'
            """) { stmt in
                bind(stmt, 1, visibleMessage)
                bind(stmt, 2, candidate.sourceID)
            }
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            try markRecordChanged(entity: .source, logicalKey: candidate.sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Older builds could commit canonical text and leave the preceding cleanup
    /// timeout on the ready Source row. Clear only a code-owned cleanup failure,
    /// and only when the current preparation contract and clean hash prove that
    /// cleanup actually completed. This never calls AI or rewrites content.
    @discardableResult
    func clearCompletedCanonicalContentCleanupFailure(sourceID: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE sources
                SET error_message = NULL
                WHERE id = ?
                  AND state = 'ready'
                  AND (
                        error_message LIKE 'Article ingestion failed during Source Content Cleanup:%'
                     OR error_message LIKE 'Paper cleanup couldn''t finish.%'
                     OR error_message LIKE '%Paper ingestion failed during Source Content Cleanup:%'
                  )
                  AND (
                        EXISTS (
                            SELECT 1 FROM article_content_preparations ap
                            WHERE ap.source_id = sources.id
                              AND ap.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                              AND ap.clean_sha256 IS NOT NULL
                        )
                     OR EXISTS (
                            SELECT 1 FROM paper_content_preparations pp
                            WHERE pp.source_id = sources.id
                              AND pp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                              AND pp.clean_sha256 IS NOT NULL
                        )
                  )
            """) { stmt in
                bind(stmt, 1, sourceID)
            }
            let changed = sqlite3_changes(db) > 0
            if changed {
                try markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            try exec("COMMIT")
            return changed
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func applyCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        prepared: PreparedPaperContent
    ) throws {
        guard prepared.metadata.cleanerVersion == PaperContentPreparationMetadata.currentVersion,
              prepared.metadata.rawSHA256 == candidate.rawSHA256,
              PaperContentPreparationService.sha256(prepared.clean) == prepared.metadata.cleanSHA256 else {
            throw KnowledgeStoreError.invalidData("Canonical content cleanup hashes or version did not validate.")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            let currentRaw: String?
            if candidate.sourceType == .paper {
                currentRaw = try loadPaperContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            } else {
                currentRaw = try loadArticleContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            }
            // The stored row must still be the text the candidate was read
            // from; `prepared.raw` may be a fresh extraction of the PDF.
            guard let currentRaw,
                  PaperContentPreparationService.sha256(currentRaw) == candidate.storedTextSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Source text changed while canonical cleanup was running; it will be retried."
                )
            }

            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, prepared.clean)
            }
            if candidate.isPendingIngestion {
                try execBind("""
                    UPDATE sources
                    SET state = 'ready', error_message = NULL
                    WHERE id = ? AND state = 'queued'
                """) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            } else {
                // A successful historical re-clean supersedes any cleanup
                // failure previously attached to this otherwise-ready row.
                try execBind("""
                    UPDATE sources
                    SET error_message = NULL
                    WHERE id = ?
                      AND (
                            error_message LIKE 'Article ingestion failed during Source Content Cleanup:%'
                         OR error_message LIKE 'Paper cleanup couldn''t finish.%'
                         OR error_message LIKE '%Paper ingestion failed during Source Content Cleanup:%'
                      )
                """) { stmt in
                    bind(stmt, 1, candidate.sourceID)
                }
            }
            if candidate.sourceType == .paper {
                try upsertPaperContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: prepared.raw,
                    metadata: prepared.metadata
                )
                try execBind("UPDATE papers SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(prepared.clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count))
                    bind(stmt, 2, candidate.sourceID)
                }
            } else {
                try upsertArticleContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: prepared.raw,
                    metadata: prepared.metadata
                )
                try execBind("UPDATE articles SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(prepared.clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count))
                    bind(stmt, 2, candidate.sourceID)
                }
            }
            try invalidateCanonicalContentIndexes(sourceID: candidate.sourceID)
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            // Listen is prepared when the learner asks for it, or now for
            // automatic-audio kinds.
            try enqueueSourceListenableContentPreparation(
                sourceID: candidate.sourceID,
                content: prepared.clean
            )
            // Any preparation recorded against the pre-cleanup text is void.
            // The cleaned derivative is prepared when a review asks for it.
            try retireSourceReviewGuidePreparation(sourceID: candidate.sourceID)
            try markRecordChanged(entity: .source, logicalKey: candidate.sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Finish a pending ingestion without a model: the raw extraction becomes
    /// the canonical text and the source turns `ready`. This is the Dev build's
    /// route (`PaidSourceCleanupPolicy`); the installed app never takes it.
    ///
    /// The preparation row records the deterministic version with the raw
    /// text's own hash as its clean hash — the same attribution a synced record
    /// without preparation metadata receives — so the paper counts as ingested
    /// while any later `saveSource` still sees a version below the current
    /// contract and re-queues it for a drain that may spend a model. No Listen
    /// derivative is queued: that stage is paid too.
    func publishCanonicalContentWithoutCleanup(
        candidate: CanonicalContentCleanupCandidate
    ) throws {
        guard candidate.isPendingIngestion else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let currentRaw: String?
            if candidate.sourceType == .paper {
                currentRaw = try loadPaperContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            } else {
                currentRaw = try loadArticleContentPreparation(candidate.sourceID)?.raw
                    ?? loadSourceContent(candidate.sourceID)
            }
            guard let currentRaw,
                  PaperContentPreparationService.sha256(currentRaw) == candidate.storedTextSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Source text changed while it was being published; it will be retried."
                )
            }

            let metadata = PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.deterministicVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: candidate.rawSHA256,
                preparedAt: Date()
            )
            let wordCount = Int64(
                candidate.raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            )
            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, candidate.raw)
            }
            try execBind("""
                UPDATE sources
                SET state = 'ready', error_message = NULL
                WHERE id = ? AND state = 'queued'
            """) { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            if candidate.sourceType == .paper {
                try upsertPaperContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: candidate.raw,
                    metadata: metadata
                )
                try execBind("UPDATE papers SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, wordCount)
                    bind(stmt, 2, candidate.sourceID)
                }
            } else {
                try upsertArticleContentPreparation(
                    sourceID: candidate.sourceID,
                    raw: candidate.raw,
                    metadata: metadata
                )
                try execBind("UPDATE articles SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, wordCount)
                    bind(stmt, 2, candidate.sourceID)
                }
            }
            try invalidateCanonicalContentIndexes(sourceID: candidate.sourceID)
            try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            try markRecordChanged(entity: .source, logicalKey: candidate.sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Podcast transcript ad cleanup

    static let maximumPodcastTranscriptCleanupAttempts = 3

    /// The next episodes the clean-up drain works on: one the learner asked to
    /// be formatted first, then rows that have not failed, transcripts owed
    /// their formatting ahead of the ad backlog, oldest first.
    ///
    /// A row owed the formatting pass is offered for it only while its stored
    /// text is still the raw text it was queued for. A transcript replaced
    /// since (YouTube captions, the learner's own speaker names, a synced
    /// copy) is someone's text and is not formatted over: the row falls back
    /// to the ad pass, and loses its place and its exemption from hiding, here.
    ///
    /// - Parameter formattingOnly: only rows owed the formatting pass, as past
    ///   the daily background cap, where the ad backlog waits for the next day
    ///   but a transcript just fetched is still formatted.
    func podcastTranscriptCleanupCandidates(
        limit: Int,
        formattingOnly: Bool = false
    ) throws -> [PodcastTranscriptCleanupCandidate] {
        guard limit > 0 else { return [] }
        try reviveReasoningRejectedPodcastTranscriptCleanups()
        while true {
            var results: [PodcastTranscriptCleanupCandidate] = []
            var replaced: [(sourceID: String, formatInputSHA256: String)] = []
            try queryBind("""
                SELECT s.id,
                       COALESCE(p.title, 'Untitled episode'),
                       COALESCE(NULLIF(p.show_name, ''), NULLIF(p.domain, ''), 'Podcast'),
                       sc.content,
                       q.format_input_sha256
                FROM podcast_transcript_cleanup_queue q
                JOIN sources s ON s.id = q.source_id
                JOIN podcasts p ON p.source_id = s.id
                JOIN source_content sc ON sc.source_id = s.id
                LEFT JOIN podcast_transcript_preparations prep ON prep.source_id = s.id
                WHERE s.source_type = 'podcast'
                  AND s.state = 'ready'
                  AND s.status = 'active'
                  AND TRIM(sc.content) != ''
                  AND q.target_version <= \(PodcastTranscriptCleanupMetadata.currentVersion)
                  AND q.attempt_count < \(Self.maximumPodcastTranscriptCleanupAttempts)
                  AND COALESCE(prep.cleaner_version, 0) < q.target_version
                  AND (? = 0 OR q.format_input_sha256 IS NOT NULL)
                  -- A bulk re-queue waits for the learner (schema 135).
                  AND \(Self.bulkHoldExclusion(.podcastTranscriptCleanup))
                  AND (q.learner_asked = 1 OR (\(Self.podcastEpisodeVisibleSQL(source: "s", podcast: "p"))))
                ORDER BY q.learner_asked DESC,
                         CASE WHEN q.last_error IS NULL THEN 0 ELSE 1 END,
                         CASE WHEN q.format_input_sha256 IS NULL THEN 1 ELSE 0 END,
                         q.enqueued_at,
                         s.id
                LIMIT ?
            """, bind: { stmt in
                sqlite3_bind_int(stmt, 1, formattingOnly ? 1 : 0)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }) { stmt in
                guard let sourceID = string(stmt, 0),
                      let title = string(stmt, 1),
                      let podcastName = string(stmt, 2),
                      let input = string(stmt, 3) else { return }
                let inputSHA256 = PaperContentPreparationService.sha256(input)
                let formatInputSHA256 = string(stmt, 4)
                if let formatInputSHA256, formatInputSHA256 != inputSHA256 {
                    replaced.append((sourceID, formatInputSHA256))
                    return
                }
                results.append(PodcastTranscriptCleanupCandidate(
                    sourceID: sourceID,
                    title: title,
                    podcastName: podcastName,
                    input: input,
                    inputSHA256: inputSHA256,
                    formatsTranscript: formatInputSHA256 != nil
                ))
            }
            guard !replaced.isEmpty else { return results }
            // Each pass takes at least one row out of the formatting pass, so
            // this ends; the next selects what the batch should hold now.
            for row in replaced {
                try execBind("""
                    UPDATE podcast_transcript_cleanup_queue
                    SET format_input_sha256 = NULL, learner_asked = 0
                    WHERE source_id = ? AND format_input_sha256 = ?
                """) { stmt in
                    bind(stmt, 1, row.sourceID)
                    bind(stmt, 2, row.formatInputSHA256)
                }
            }
        }
    }

    func podcastTranscriptCleanupQueueCount() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM podcast_transcript_cleanup_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN podcasts p ON p.source_id = s.id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN podcast_transcript_preparations prep ON prep.source_id = s.id
            WHERE s.source_type = 'podcast'
              AND s.state = 'ready'
              AND s.status = 'active'
              AND TRIM(sc.content) != ''
              AND q.attempt_count < \(Self.maximumPodcastTranscriptCleanupAttempts)
              AND COALESCE(prep.cleaner_version, 0) < q.target_version
              -- A bulk re-queue waits for the learner (schema 135).
              AND \(Self.bulkHoldExclusion(.podcastTranscriptCleanup))
              AND (q.learner_asked = 1 OR (\(Self.podcastEpisodeVisibleSQL(source: "s", podcast: "p"))))
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Schema 172's columns on `podcast_transcript_cleanup_queue`.
    static let podcastTranscriptFormattingColumns: [(table: String, name: String, definition: String)] = [
        // NULL on every existing row is the truth: each owes the ad pass alone.
        ("podcast_transcript_cleanup_queue", "format_input_sha256", "TEXT"),
        // 0 on every existing row is the truth: no row was the learner's ask.
        ("podcast_transcript_cleanup_queue", "learner_asked", "INTEGER NOT NULL DEFAULT 0"),
    ]

    func holdsPodcastTranscriptFormattingColumns() throws -> Bool {
        let existing = try tableColumnNames("podcast_transcript_cleanup_queue")
        return Self.podcastTranscriptFormattingColumns.allSatisfy { existing.contains($0.name) }
    }

    /// Inside the caller's transaction.
    func addPodcastTranscriptFormattingColumns() throws {
        let existing = try tableColumnNames("podcast_transcript_cleanup_queue")
        for column in Self.podcastTranscriptFormattingColumns where !existing.contains(column.name) {
            try exec("ALTER TABLE \(column.table) ADD COLUMN \(column.name) \(column.definition)")
        }
    }

    /// Until 2026-09-03 the cleanup request asked OpenRouter to turn reasoning
    /// off entirely, and first-generation GPT-5 models refused with a 400
    /// ("Reasoning is mandatory for this endpoint and cannot be disabled").
    /// That failure was counted as a real attempt, so an episode on such a
    /// model burned its whole budget without the cleaner ever reading a word.
    /// The request now asks for the lowest effort the model accepts; give those
    /// rows their attempts back so the next drain picks them up. Idempotent and
    /// bounded by the queue's size, so it can run ahead of every drain.
    private func reviveReasoningRejectedPodcastTranscriptCleanups() throws {
        try exec("""
            UPDATE podcast_transcript_cleanup_queue
            SET attempt_count = 0,
                last_error = NULL
            WHERE attempt_count > 0
              AND last_error LIKE '%Reasoning is mandatory%'
        """)
    }

    func recordPodcastTranscriptCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String,
        consumesAttempt: Bool
    ) throws {
        try execBind("""
            UPDATE podcast_transcript_cleanup_queue
            SET attempt_count = attempt_count + ?,
                last_error = ?,
                source_sha256 = ?,
                enqueued_at = ?
            WHERE source_id = ?
        """) { stmt in
            sqlite3_bind_int(stmt, 1, consumesAttempt ? 1 : 0)
            bind(stmt, 2, message)
            bind(stmt, 3, sourceSHA256)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 5, sourceID)
        }
    }

    func loadPodcastTranscriptPreparation(
        _ sourceID: String
    ) throws -> (input: String, metadata: PodcastTranscriptCleanupMetadata)? {
        var result: (String, PodcastTranscriptCleanupMetadata)?
        try queryBind("""
            SELECT input_content, input_sha256, clean_sha256, cleaner_version, prepared_at
            FROM podcast_transcript_preparations
            WHERE source_id = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let input = string(stmt, 0),
                  let inputSHA = string(stmt, 1),
                  let cleanSHA = string(stmt, 2) else { return }
            let preparedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            result = (input, PodcastTranscriptCleanupMetadata(
                cleanerVersion: Int(sqlite3_column_int(stmt, 3)),
                inputSHA256: inputSHA,
                cleanSHA256: cleanSHA,
                preparedAt: preparedAt
            ))
        }
        return result
    }

    /// Whether `text` is what an episode's stored clean-up was made from, while
    /// storage holds what it became. A loaded row keeps the transcript it was
    /// given until the drain's refresh reaches it, and a `saveSource` of that
    /// row in between (a rename, a hide) would write the raw or ad-laden text
    /// back over the formatted one and leave the record saying the pass ran.
    func isPodcastTranscriptCleanupInput(_ text: String, sourceID: String) throws -> Bool {
        var hashes: (input: String, clean: String)?
        try queryBind("""
            SELECT input_sha256, clean_sha256
            FROM podcast_transcript_preparations
            WHERE source_id = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let input = string(stmt, 0), let clean = string(stmt, 1) else { return }
            hashes = (input, clean)
        }
        guard let hashes, hashes.input != hashes.clean else { return false }
        return PaperContentPreparationService.sha256(text) == hashes.input
    }

    func upsertPodcastTranscriptPreparation(
        sourceID: String,
        input: String,
        metadata: PodcastTranscriptCleanupMetadata
    ) throws {
        try execBind("""
            INSERT INTO podcast_transcript_preparations
                (source_id, input_content, input_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                input_content = excluded.input_content,
                input_sha256 = excluded.input_sha256,
                clean_sha256 = excluded.clean_sha256,
                cleaner_version = excluded.cleaner_version,
                prepared_at = excluded.prepared_at
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, input)
            bind(stmt, 3, metadata.inputSHA256)
            bind(stmt, 4, metadata.cleanSHA256)
            sqlite3_bind_int(stmt, 5, Int32(metadata.cleanerVersion))
            if let preparedAt = metadata.preparedAt {
                sqlite3_bind_double(stmt, 6, preparedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
        }
    }

    func applyPodcastTranscriptCleanup(
        candidate: PodcastTranscriptCleanupCandidate,
        prepared: PreparedPodcastTranscriptCleanup
    ) throws {
        guard prepared.metadata.cleanerVersion == PodcastTranscriptCleanupMetadata.currentVersion,
              prepared.metadata.inputSHA256 == candidate.inputSHA256,
              PaperContentPreparationService.sha256(prepared.input) == candidate.inputSHA256,
              PaperContentPreparationService.sha256(prepared.clean) == prepared.metadata.cleanSHA256,
              !prepared.clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prepared.clean.count * 100 >= prepared.input.count * 55 else {
            throw KnowledgeStoreError.invalidData(
                "Podcast transcript cleanup hashes, version, or deletion limit did not validate."
            )
        }

        try exec("BEGIN IMMEDIATE")
        do {
            guard let current = try loadSourceContent(candidate.sourceID),
                  PaperContentPreparationService.sha256(current) == candidate.inputSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Podcast transcript changed while ad cleanup was running; it will be retried."
                )
            }
            try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, prepared.clean)
            }
            try upsertPodcastTranscriptPreparation(
                sourceID: candidate.sourceID,
                input: prepared.input,
                metadata: prepared.metadata
            )
            try execBind("UPDATE podcasts SET word_count = ? WHERE source_id = ?") { stmt in
                sqlite3_bind_int64(
                    stmt,
                    1,
                    Int64(prepared.clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
                )
                bind(stmt, 2, candidate.sourceID)
            }
            try invalidateCanonicalContentIndexes(sourceID: candidate.sourceID)
            try retireSourceReviewGuidePreparation(sourceID: candidate.sourceID)
            try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            try markRecordChanged(entity: .source, logicalKey: candidate.sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Restores recent cleanup results from their versioned, hash-proven input.
    /// Used by a guarded maintenance pilot when review finds that the prompt
    /// contract was too broad; the source, derivatives, durable queue, and sync
    /// rail are repaired together rather than by editing SQLite out of band.
    func restorePodcastTranscriptCleanups(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        var sourceIDs: [String] = []
        try queryBind("""
            SELECT source_id
            FROM podcast_transcript_preparations
            ORDER BY prepared_at DESC, source_id
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }) { stmt in
            if let sourceID = string(stmt, 0) { sourceIDs.append(sourceID) }
        }

        var restored: [String] = []
        for sourceID in sourceIDs {
            try exec("BEGIN IMMEDIATE")
            do {
                guard let preparation = try loadPodcastTranscriptPreparation(sourceID) else {
                    try exec("COMMIT")
                    continue
                }
                try execBind("INSERT OR REPLACE INTO source_content (source_id, content) VALUES (?, ?)") { stmt in
                    bind(stmt, 1, sourceID)
                    bind(stmt, 2, preparation.input)
                }
                try execBind("UPDATE podcasts SET word_count = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int64(
                        stmt,
                        1,
                        Int64(preparation.input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
                    )
                    bind(stmt, 2, sourceID)
                }
                try execBind("DELETE FROM podcast_transcript_preparations WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
                try invalidateCanonicalContentIndexes(sourceID: sourceID)
                try enqueueSourceListenableContentPreparation(sourceID: sourceID, content: preparation.input)
                try retireSourceReviewGuidePreparation(sourceID: sourceID)
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
                try markRecordChanged(entity: .source, logicalKey: sourceID)
                try exec("COMMIT")
                restored.append(sourceID)
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
        return restored
    }

    // MARK: - Listenable source content

    /// Couples the Listen derivative to canonical text. Callers invoke this in
    /// the same transaction that writes source_content, so stale narration can
    /// never survive a canonical-text change.
    ///
    /// The paid preparation is queued now only when automatic audio covers
    /// the source's kind, since automatic generation waits for the prepared
    /// derivative and never makes one. Any other change only retires the
    /// stale derivative, and Listen prepares when someone presses it
    /// (`ArticleSpeechService`, and the iPhone's own pass). Cleaner v19 queued
    /// a paid preparation for every one of ~1,380 re-cleaned sources nobody
    /// had asked to hear; on 2026-09-25 the product owner asked that a new import wait
    /// for a listener too, since most papers are read, not heard.
    func enqueueSourceListenableContentPreparation(
        sourceID: String,
        content: String
    ) throws {
        var eligibleSourceType: StudioSourceType?
        try queryBind("""
            SELECT s.source_type
            FROM sources s
            WHERE s.id = ?
              -- `error` is deliberate: a paper that failed the metadata gate has
              -- canonical text all the same, and Listen narrates the text. See
              -- StudioArticle.isEligibleForListenableContentPreparation.
              AND s.state IN ('ready', 'error')
              AND s.status = 'active'
              AND s.source_type IN ('article', 'paper')
              -- A spoken script (an explainer, an audio overview's carrier)
              -- is written for the ear and is never prepared; its URL lives on
              -- the articles row (`TextToSpeechPreparationPolicy.spokenScriptURLPrefixes`).
              AND NOT EXISTS (
                  SELECT 1 FROM articles a
                  WHERE a.source_id = s.id
                    AND (a.url LIKE 'foreverlm://explainer/%' OR a.url LIKE 'foreverlm://audio-overview/%')
              )
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue q WHERE q.source_id = s.id
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let rawType = self.string(stmt, 0) else { return }
            eligibleSourceType = StudioSourceType(rawValue: rawType)
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eligibleSourceType != nil, !trimmed.isEmpty else {
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        let sourceSHA256 = PaperContentPreparationService.sha256(trimmed)
        var alreadyPrepared = false
        try queryBind("""
            SELECT 1
            FROM source_listenable_content
            WHERE source_id = ?
              AND source_sha256 = ?
              AND generator_version = ?
              AND COALESCE(preparation_signature, '') LIKE ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, sourceSHA256)
            sqlite3_bind_int(stmt, 3, Int32(SourceListenableContentMetadata.currentVersion))
            bind(stmt, 4, "\(PaperNarrationFilter.preparationContractPrefix)%")
        }) { _ in alreadyPrepared = true }
        if alreadyPrepared {
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        try execBind("DELETE FROM source_listenable_content WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
        if let eligibleSourceType,
           !automaticAudioSourceTypes().contains(eligibleSourceType.rawValue) {
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }
        try execBind("""
            INSERT INTO source_listenable_content_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            VALUES (?, ?, ?, ?, 0, NULL)
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                source_sha256 = excluded.source_sha256,
                enqueued_at = excluded.enqueued_at,
                attempt_count = CASE
                    WHEN source_listenable_content_queue.source_sha256 = excluded.source_sha256
                    THEN source_listenable_content_queue.attempt_count ELSE 0 END,
                last_error = CASE
                    WHEN source_listenable_content_queue.source_sha256 = excluded.source_sha256
                    THEN source_listenable_content_queue.last_error ELSE NULL END
        """) { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(SourceListenableContentMetadata.currentVersion))
            bind(stmt, 3, sourceSHA256)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSinceReferenceDate)
        }
    }

    /// Queues one source's Listen preparation from its stored text, for
    /// automatic audio that found none ready: a kind switched on after the
    /// text arrived was never queued (`enqueueSourceListenableContentPreparation`).
    /// Returns whether the source is now queued. A row already queued is left
    /// as it is, so a bulk re-queue held for the learner stays held.
    @discardableResult
    func queueSourceListenableContentPreparation(sourceID: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            func isQueued() throws -> Bool {
                var queued = false
                try queryBind("SELECT 1 FROM source_listenable_content_queue WHERE source_id = ?", bind: { stmt in
                    bind(stmt, 1, sourceID)
                }) { _ in queued = true }
                return queued
            }
            if try !isQueued() {
                var content: String?
                try queryBind("SELECT content FROM source_content WHERE source_id = ?", bind: { stmt in
                    bind(stmt, 1, sourceID)
                }) { stmt in
                    content = self.string(stmt, 0)
                }
                if let content {
                    try enqueueSourceListenableContentPreparation(sourceID: sourceID, content: content)
                }
            }
            let queued = try isQueued()
            try exec("COMMIT")
            return queued
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func sourceListenableContentCandidates(limit: Int) throws -> [SourceListenableContentCandidate] {
        guard limit > 0 else { return [] }

        var results: [SourceListenableContentCandidate] = []
        var changedHashes: [(sourceID: String, sourceSHA256: String)] = []
        try queryBind("""
            SELECT q.source_id,
                   COALESCE(p.title, a.title, b.title, c.title, m.title, x.title, 'Untitled'),
                   s.source_type,
                   sc.content,
                   q.source_sha256
            FROM source_listenable_content_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN papers p ON p.source_id = s.id
            LEFT JOIN articles a ON a.source_id = s.id
            LEFT JOIN book_sources b ON b.source_id = s.id
            LEFT JOIN course_sources c ON c.source_id = s.id
            LEFT JOIN meeting_sources m ON m.source_id = s.id
            LEFT JOIN x_posts x ON x.source_id = s.id
            -- Matches the enqueue predicate: `error` sources carry canonical text
            -- too, and Listen narrates the text, not the bibliography.
            WHERE s.state IN ('ready', 'error')
              AND s.status = 'active'
              AND s.source_type IN ('article', 'paper')
              AND COALESCE(a.url, '') NOT LIKE 'foreverlm://explainer/%'
              AND COALESCE(a.url, '') NOT LIKE 'foreverlm://audio-overview/%'
              AND q.target_version <= \(SourceListenableContentMetadata.currentVersion)
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id
              )
              -- A bulk re-queue waits for the learner (schema 135).
              AND \(Self.bulkHoldExclusion(.listenPreparation))
            ORDER BY q.attempt_count,
                     s.date_added DESC,
                     q.enqueued_at,
                     q.source_id
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }) { stmt in
            guard let sourceID = string(stmt, 0),
                  let title = string(stmt, 1),
                  let rawType = string(stmt, 2),
                  let sourceType = StudioSourceType(rawValue: rawType),
                  let canonicalText = string(stmt, 3) else { return }
            let normalized = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            let actualHash = PaperContentPreparationService.sha256(normalized)
            results.append(SourceListenableContentCandidate(
                sourceID: sourceID,
                title: title,
                sourceType: sourceType,
                canonicalText: canonicalText,
                sourceSHA256: actualHash
            ))
            if self.string(stmt, 4) != actualHash {
                changedHashes.append((sourceID, actualHash))
            }
        }
        for changedHash in changedHashes {
            try? execBind("""
                UPDATE source_listenable_content_queue
                SET source_sha256 = ?, attempt_count = 0, last_error = NULL
                WHERE source_id = ?
            """) { update in
                bind(update, 1, changedHash.sourceSHA256)
                bind(update, 2, changedHash.sourceID)
            }
        }
        return results
    }

    func nextSourceListenableContentCandidate() throws -> SourceListenableContentCandidate? {
        try sourceListenableContentCandidates(limit: 1).first
    }

    func sourceListenableContentQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_listenable_content_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func recordSourceListenableContentFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String
    ) throws {
        try execBind("""
            UPDATE source_listenable_content_queue
            SET attempt_count = attempt_count + 1,
                last_error = ?,
                source_sha256 = ?,
                enqueued_at = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, message)
            bind(stmt, 2, sourceSHA256)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 4, sourceID)
        }
    }

    func applySourceListenableContent(
        candidate: SourceListenableContentCandidate,
        text: String,
        preparationSignature: String?
    ) throws {
        let narration = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MacArticleSpeechText.containsLetterOrDigit(narration) else {
            throw KnowledgeStoreError.invalidData("Listenable-content preparation returned no narratable text.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            guard let current = try loadSourceContent(candidate.sourceID),
                  PaperContentPreparationService.sha256(
                    current.trimmingCharacters(in: .whitespacesAndNewlines)
                  ) == candidate.sourceSHA256 else {
                throw KnowledgeStoreError.sourceContentChanged
            }
            try execBind("""
                INSERT INTO source_listenable_content
                    (source_id, source_sha256, content, generator_version, preparation_signature, prepared_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source_sha256 = excluded.source_sha256,
                    content = excluded.content,
                    generator_version = excluded.generator_version,
                    preparation_signature = excluded.preparation_signature,
                    prepared_at = excluded.prepared_at
            """) { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, candidate.sourceSHA256)
                bind(stmt, 3, narration)
                sqlite3_bind_int(stmt, 4, Int32(SourceListenableContentMetadata.currentVersion))
                bind(stmt, 5, preparationSignature)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            try markRecordChanged(entity: .source, logicalKey: candidate.sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadSourceListenableContent(_ sourceID: String) throws -> StoredSourceListenableContent? {
        var result: StoredSourceListenableContent?
        try queryBind("""
            SELECT content, source_sha256, generator_version, preparation_signature, prepared_at
            FROM source_listenable_content
            WHERE source_id = ?
              AND generator_version = ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int(stmt, 2, Int32(SourceListenableContentMetadata.currentVersion))
        }) { stmt in
            guard let text = string(stmt, 0), let sourceSHA256 = string(stmt, 1) else { return }
            result = StoredSourceListenableContent(
                text: text,
                metadata: SourceListenableContentMetadata(
                    sourceSHA256: sourceSHA256,
                    generatorVersion: Int(sqlite3_column_int(stmt, 2)),
                    preparationSignature: string(stmt, 3),
                    characterCount: text.count,
                    preparedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
                )
            )
        }
        return result
    }

    /// Listen-ready length and preparation identity per source without loading
    /// the narration bodies into memory. This is the exact persisted derivative
    /// family consumed by Listen, not canonical source text.
    func sourceListenableContentSummaries(
        for sourceIDs: [String]
    ) throws -> [String: SourceListenableContentSummary] {
        let uniqueIDs = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return [:] }

        var summaries: [String: SourceListenableContentSummary] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < uniqueIDs.count {
            let chunk = Array(uniqueIDs[offset..<min(offset + chunkSize, uniqueIDs.count)])
            offset += chunkSize
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT source_id, LENGTH(content), preparation_signature
                FROM source_listenable_content
                WHERE generator_version = ?
                  AND source_id IN (\(placeholders))
            """
            try queryBind(sql, bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(SourceListenableContentMetadata.currentVersion))
                for (index, sourceID) in chunk.enumerated() {
                    self.bind(stmt, index + 2, sourceID)
                }
            }) { stmt in
                guard let sourceID = self.string(stmt, 0),
                      let characterCount = self.optionalInt(stmt, 1),
                      characterCount > 0 else { return }
                summaries[sourceID] = SourceListenableContentSummary(
                    characterCount: characterCount,
                    preparationSignature: self.string(stmt, 2)
                )
            }
        }
        return summaries
    }

    func saveSourceListenableContentFromSync(
        sourceID: String,
        content: String,
        metadata: SourceListenableContentMetadata
    ) throws {
        let narration = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard metadata.generatorVersion == SourceListenableContentMetadata.currentVersion,
              metadata.characterCount.map({ $0 == narration.count }) ?? true,
              MacArticleSpeechText.containsLetterOrDigit(narration),
              let canonical = try loadSourceContent(sourceID),
              PaperContentPreparationService.sha256(
                canonical.trimmingCharacters(in: .whitespacesAndNewlines)
              ) == metadata.sourceSHA256 else {
            throw KnowledgeStoreError.invalidData(
                "Synced listenable content failed its source integrity check for \(sourceID)."
            )
        }
        try execBind("""
            INSERT OR REPLACE INTO source_listenable_content
                (source_id, source_sha256, content, generator_version, preparation_signature, prepared_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, metadata.sourceSHA256)
            bind(stmt, 3, narration)
            sqlite3_bind_int(stmt, 4, Int32(metadata.generatorVersion))
            bind(stmt, 5, metadata.preparationSignature)
            sqlite3_bind_double(stmt, 6, metadata.preparedAt.timeIntervalSinceReferenceDate)
        }
        try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    // MARK: - Source review guide preparation

    /// Keeps review-guide work transactionally coupled to canonical source text.
    /// Re-saving metadata does not reset a failed attempt unless the text changed.
    func enqueueSourceReviewGuidePreparation(sourceID: String, content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        let sourceSHA256 = PaperContentPreparationService.sha256(content)
        // Any readable guide for this exact text is enough. Matching only the
        // current generator version would re-enqueue the whole library on every
        // version bump, which is regeneration, not preparation.
        var hasUsableGuide = false
        try queryBind("""
            SELECT g.generator_version, s.source_type
            FROM source_review_guides g
            JOIN sources s ON s.id = g.source_id
            WHERE g.source_id = ?
              AND g.source_sha256 = ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
            self.bind(stmt, 2, sourceSHA256)
        }) { stmt in
            guard let rawSourceType = self.string(stmt, 1),
                  let sourceType = StudioSourceType(rawValue: rawSourceType) else { return }
            hasUsableGuide = SourceReviewGuide.isCompatible(
                generatorVersion: Int(sqlite3_column_int(stmt, 0)),
                sourceType: sourceType
            )
        }

        if hasUsableGuide {
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            return
        }

        try execBind("""
            INSERT INTO source_review_guide_queue
                (source_id, source_sha256, enqueued_at, attempt_count, last_error)
            VALUES (?, ?, ?, 0, NULL)
            ON CONFLICT(source_id) DO UPDATE SET
                source_sha256 = excluded.source_sha256,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
            WHERE source_review_guide_queue.source_sha256 != excluded.source_sha256
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, sourceSHA256)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
        }
    }

    /// A source becomes eligible only when `source_content` is its stable
    /// canonical derivative. Papers and web articles must have completed the
    /// current cleanup contract; transcript-backed source types are canonical
    /// when their ready `source_content` row is committed.
    func reconcileSourceReviewGuidePreparation(sourceID: String) throws {
        var content: String?
        try queryBind("""
            SELECT sc.content
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            WHERE s.id = ?
              AND s.state = 'ready'
              AND s.status = 'active'
              AND CASE
                    WHEN s.source_type = 'paper' THEN
                        pp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND pp.clean_sha256 IS NOT NULL
                    WHEN s.source_type IN ('article', 'manual', 'unclassified') THEN
                        ap.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND ap.clean_sha256 IS NOT NULL
                    ELSE 1
                  END
              AND NOT EXISTS (
                  SELECT 1
                  FROM canonical_content_cleanup_queue cq
                  WHERE cq.source_id = s.id
              )
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in content = self.string(stmt, 0) }

        if let content {
            try enqueueSourceReviewGuidePreparation(sourceID: sourceID, content: content)
        } else {
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
        }
    }

    /// The one place preparation is ever scheduled: a review is starting and
    /// this source has no usable guide. Nothing enqueues speculatively.
    func ensureSourceReviewGuidePreparation(sourceID: String) throws {
        try reconcileSourceReviewGuidePreparation(sourceID: sourceID)
    }

    /// Saving a source never schedules preparation. It only retires a pending
    /// row, whose recorded attempt describes text that has just changed; the
    /// next review request recreates it against the new canonical text.
    func retireSourceReviewGuidePreparation(sourceID: String) throws {
        try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    /// The requested source's pending preparation, validated against the exact
    /// canonical text that was queued. There is no ordered backlog to pick from:
    /// preparation is always for the one source a review is about to start.
    func sourceReviewGuideCandidate(sourceID: String) throws -> SourceReviewGuideCandidate? {
        var row: (
            sourceID: String,
            sourceType: StudioSourceType,
            title: String,
            content: String,
            queuedSHA256: String,
            attemptCount: Int
        )?
        try queryBind("""
            SELECT q.source_id,
                   s.source_type,
                   COALESCE(sp.title, 'Untitled'),
                   sc.content,
                   q.source_sha256,
                   q.attempt_count
            FROM source_review_guide_queue q
            JOIN sources s ON s.id = q.source_id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            LEFT JOIN source_projection sp ON sp.id = s.id
            WHERE q.source_id = ?
              AND s.state = 'ready'
              AND s.status = 'active'
              AND CASE
                    WHEN s.source_type = 'paper' THEN
                        pp.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND pp.clean_sha256 IS NOT NULL
                    WHEN s.source_type IN ('article', 'manual', 'unclassified') THEN
                        ap.cleaner_version >= \(PaperContentPreparationMetadata.currentVersion)
                        AND ap.clean_sha256 IS NOT NULL
                    ELSE 1
                  END
              AND NOT EXISTS (
                  SELECT 1
                  FROM canonical_content_cleanup_queue cq
                  WHERE cq.source_id = s.id
              )
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let resolvedSourceID = self.string(stmt, 0),
                  let sourceTypeRaw = self.string(stmt, 1),
                  let sourceType = StudioSourceType(rawValue: sourceTypeRaw),
                  let title = self.string(stmt, 2),
                  let content = self.string(stmt, 3),
                  let queuedSHA256 = self.string(stmt, 4) else { return }
            row = (
                resolvedSourceID,
                sourceType,
                title,
                content,
                queuedSHA256,
                Int(sqlite3_column_int(stmt, 5))
            )
        }
        guard let row else { return nil }
        guard !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "Canonical source content is empty before review preparation for \(row.sourceID)."
            )
        }
        let sourceSHA256 = PaperContentPreparationService.sha256(row.content)
        guard sourceSHA256 == row.queuedSHA256 else {
            throw KnowledgeStoreError.invalidData(
                "Canonical source content changed before review preparation for \(row.sourceID)."
            )
        }
        return SourceReviewGuideCandidate(
            sourceID: row.sourceID,
            sourceType: row.sourceType,
            title: row.title,
            content: row.content,
            sourceSHA256: sourceSHA256,
            attemptCount: row.attemptCount
        )
    }

    /// The sources a review is likely to happen on soon that have no guide
    /// yet, most likely first: an unfinished placement the learner put on
    /// today's Schedule, then a source actually engaged with (two minutes, or
    /// a finished read/listen) within `lookbackDays`, latest first. Only ready,
    /// active sources with text qualify, and a source whose guide already
    /// failed twice is left to an on-demand request rather than retried here.
    func likelyReviewSourceIDsWithoutGuide(
        now: Date,
        calendar: Calendar,
        lookbackDays: Int,
        limit: Int
    ) throws -> [String] {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let activityCutoff = now.addingTimeInterval(-Double(max(1, lookbackDays)) * 86_400)
        var ids: [String] = []
        try queryBind("""
            WITH candidates AS (
                SELECT ss.source_id AS source_id, 0 AS tier, ss.planned_at AS rank_at
                FROM scheduled_sources ss
                WHERE ss.completed_at IS NULL
                  AND ss.is_automatic = 0
                  AND ss.planned_at >= ?
                  AND ss.planned_at < ?
                UNION ALL
                SELECT sad.source_id, 1, MAX(sad.last_activity_at)
                FROM source_activity_days sad
                WHERE sad.last_activity_at >= ?
                  AND (sad.engaged_seconds >= 120 OR sad.completed_kinds != 0)
                GROUP BY sad.source_id
            )
            SELECT c.source_id
            FROM candidates c
            JOIN sources s ON s.id = c.source_id
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.state = 'ready'
              AND s.status = 'active'
              AND NOT EXISTS (
                  SELECT 1 FROM source_review_guides rg WHERE rg.source_id = s.id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM source_review_guide_queue q
                  WHERE q.source_id = s.id AND q.attempt_count >= 2
              )
            GROUP BY c.source_id
            ORDER BY MIN(c.tier), MAX(c.rank_at) DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, dayEnd.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, activityCutoff.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 4, Int32(max(0, limit)))
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func sourceReviewGuideQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM source_review_guide_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func recordSourceReviewGuideFailure(sourceID: String, message: String) throws {
        try execBind("""
            UPDATE source_review_guide_queue
            SET attempt_count = attempt_count + 1,
                last_error = ?,
                enqueued_at = ?
            WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, message)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 3, sourceID)
        }
    }

    func sourceReviewGuideFailure(sourceID: String) throws -> String? {
        var message: String?
        try queryBind(
            "SELECT last_error FROM source_review_guide_queue WHERE source_id = ? LIMIT 1",
            bind: { stmt in self.bind(stmt, 1, sourceID) }
        ) { stmt in message = self.string(stmt, 0) }
        return message
    }

    func applySourceReviewGuide(candidate: SourceReviewGuideCandidate, guide: String) throws {
        let trimmedGuide = guide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuide.isEmpty else {
            throw KnowledgeStoreError.invalidData("Review guide generation returned empty content.")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            var currentContent: String?
            try queryBind("""
                SELECT sc.content
                FROM sources s
                JOIN source_content sc ON sc.source_id = s.id
                WHERE s.id = ?
                  AND s.state = 'ready'
                  AND s.status = 'active'
                LIMIT 1
            """, bind: { stmt in
                self.bind(stmt, 1, candidate.sourceID)
            }) { stmt in currentContent = self.string(stmt, 0) }
            guard let currentContent,
                  PaperContentPreparationService.sha256(currentContent) == candidate.sourceSHA256 else {
                throw KnowledgeStoreError.invalidData(
                    "Source text changed while its review guide was being prepared; it will be retried."
                )
            }
            let generatedAt = Date()
            try execBind("""
                INSERT INTO source_review_guides
                    (source_id, source_sha256, guide, generator_version, generated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source_sha256 = excluded.source_sha256,
                    guide = excluded.guide,
                    generator_version = excluded.generator_version,
                    generated_at = excluded.generated_at
            """) { stmt in
                bind(stmt, 1, candidate.sourceID)
                bind(stmt, 2, candidate.sourceSHA256)
                bind(stmt, 3, trimmedGuide)
                sqlite3_bind_int(stmt, 4, Int32(SourceReviewGuide.currentVersion))
                sqlite3_bind_double(stmt, 5, generatedAt.timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, candidate.sourceID)
            }
            try markRecordChanged(entity: .source, logicalKey: candidate.sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadSourceReviewGuide(_ sourceID: String) throws -> SourceReviewGuide? {
        var result: SourceReviewGuide?
        try queryBind("""
            SELECT rg.source_sha256, rg.guide, rg.generator_version, rg.generated_at,
                   sc.content, s.source_type
            FROM source_review_guides rg
            JOIN sources s ON s.id = rg.source_id
            JOIN source_content sc ON sc.source_id = rg.source_id
            WHERE rg.source_id = ?
              AND s.state = 'ready'
              AND s.status = 'active'
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let sourceSHA256 = self.string(stmt, 0),
                  let guide = self.string(stmt, 1),
                  let content = self.string(stmt, 4),
                  let rawSourceType = self.string(stmt, 5),
                  let sourceType = StudioSourceType(rawValue: rawSourceType),
                  SourceReviewGuide.isCompatible(
                    generatorVersion: Int(sqlite3_column_int(stmt, 2)),
                    sourceType: sourceType
                  ),
                  PaperContentPreparationService.sha256(content) == sourceSHA256 else { return }
            result = SourceReviewGuide(
                sourceSHA256: sourceSHA256,
                guide: guide,
                generatorVersion: Int(sqlite3_column_int(stmt, 2)),
                generatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            )
        }
        return result
    }

    /// Applies an encrypted CloudKit payload only when it belongs to the local
    /// canonical text. Older payloads omit the guide and leave local preparation queued.
    func saveSourceReviewGuideFromSync(sourceID: String, guide: SourceReviewGuide?) throws {
        guard let guide,
              let sourceType = try loadSourceForSync(sourceID)?.sourceType,
              SourceReviewGuide.isCompatible(
                generatorVersion: guide.generatorVersion,
                sourceType: sourceType
              ),
              let content = try loadSourceContent(sourceID),
              PaperContentPreparationService.sha256(content) == guide.sourceSHA256 else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO source_review_guides
                    (source_id, source_sha256, guide, generator_version, generated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source_sha256 = excluded.source_sha256,
                    guide = excluded.guide,
                    generator_version = excluded.generator_version,
                    generated_at = excluded.generated_at
            """) { stmt in
                bind(stmt, 1, sourceID)
                bind(stmt, 2, guide.sourceSHA256)
                bind(stmt, 3, guide.guide)
                sqlite3_bind_int(stmt, 4, Int32(guide.generatorVersion))
                sqlite3_bind_double(stmt, 5, guide.generatedAt.timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// `restrictedTo` narrows the scan to an explicit set of sources, applied
    /// in SQL so a small pool gets its own results rather than whatever
    /// survives a corpus-wide `LIMIT`.
    func searchSourceContent(
        query: String,
        maxResults: Int,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) throws -> [String: Float] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty, maxResults > 0 else { return [:] }
        if let restrictedTo, restrictedTo.isEmpty { return [:] }

        // Analyzed rather than merely split on punctuation, so this fallback answers the
        // same way the full-text index does: "GDF15" and "GDF-15" both reduce to `gdf`
        // and `15`, and a body spelling it either way satisfies both queries. Without
        // this, the window while the index is behind silently changed which spelling
        // worked.
        let rawTerms = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .flatMap { SourceSearchEngine.alphanumericParts(in: $0) }
        let terms = rawTerms.filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [:] }

        let exactPredicate = "lower(content) LIKE ? ESCAPE '\\'"
        let termPredicate = terms
            .map { _ in "lower(content) LIKE ? ESCAPE '\\'" }
            .joined(separator: " AND ")
        let restriction = restrictedTo.map(Array.init) ?? []
        let restrictionClause = restriction.isEmpty
            ? ""
            : "\n  AND source_id IN (\(restriction.map { _ in "?" }.joined(separator: ", ")))"
        let sql = """
            SELECT source_id, content
            FROM source_content
            WHERE content IS NOT NULL
              AND content != ''
              AND (\(exactPredicate) OR (\(termPredicate)))\(restrictionClause)
            LIMIT ?
            """

        let baseRowLimit = min(max(maxResults * 8, maxResults), 800)
        let rowLimit = min(baseRowLimit + excludedSources.count, 800)
        var scores: [String: Float] = [:]
        try queryBind(sql, bind: { stmt in
            self.bind(stmt, 1, "%\(Self.escapedLikePattern(normalizedQuery))%")
            for (offset, term) in terms.enumerated() {
                self.bind(stmt, offset + 2, "%\(Self.escapedLikePattern(term))%")
            }
            var nextIndex = terms.count + 2
            for sourceID in restriction {
                self.bind(stmt, nextIndex, sourceID)
                nextIndex += 1
            }
            sqlite3_bind_int(stmt, Int32(nextIndex), Int32(rowLimit))
        }) { stmt in
            guard scores.count < maxResults else { return }
            guard let sourceId = self.string(stmt, 0),
                  let content = self.string(stmt, 1) else { return }
            guard !excludedSources.contains(sourceId) else { return }
            let searchable = content.lowercased()
            var score: Float = searchable.contains(normalizedQuery) ? 1.5 : 0
            let matchCount = terms.filter { searchable.contains($0) }.count
            score += Float(matchCount) / Float(terms.count)
            guard score > 0 else { return }
            scores[sourceId] = max(scores[sourceId] ?? 0, score)
        }

        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(maxResults)
            .reduce(into: [:]) { result, item in
                result[item.key] = item.value
            }
    }

    /// Every active source whose title, author, or body contains the keywords
    /// literally, with a mention count and a few passages for each.
    ///
    /// The scan reads the text rather than `source_fts`, because the index
    /// tokenizes and this search must not: the whole point is that `uncoupler`
    /// finds a body that says `uncouplers`. It takes two reads. The first lists
    /// the sources in scope, newest first, without their text, so nothing
    /// book-sized is ever sorted; the second reads each text by id, one row at
    /// a time, and drops it, so a library of book-length sources costs one
    /// source's text in memory rather than the corpus.
    ///
    /// The keywords are not in the SQL. Until 2026-09-26 a `LIKE` per keyword
    /// chose the rows and Swift counted in them, and the two disagreed: `LIKE`
    /// folds ASCII case only and compares the text's own characters, so `Δψ`,
    /// bound as `δψ`, found nothing in a chapter that says `Δψ` 58 times, and
    /// `Differential` missed the PDFs that extract `Diﬀerential` — while the
    /// count, which folds as Unicode does, found both whenever another keyword
    /// let the row in. `SourceKeywordSearch.Screen` now rules texts out from
    /// their bytes with the count's own folding, and the count decides.
    func sourcesContainingKeywords(
        _ keywords: [String],
        matchAll: Bool,
        maxSources: Int,
        snippetsPerSource: Int,
        restrictedTo: Set<String>? = nil,
        sourceTypes: [String] = [],
        excluding excludedSourceIDs: Set<String> = []
    ) throws -> (matches: [SourceKeywordMatch], truncated: Bool) {
        let terms = SourceKeywordSearch.normalized(keywords)
        guard !terms.isEmpty, maxSources > 0 else { return ([], false) }
        if let restrictedTo, restrictedTo.isEmpty { return ([], false) }
        let searchKeywords = terms.map(SourceKeywordSearch.Keyword.init)
        var screen = SourceKeywordSearch.Screen(searchKeywords)

        let restriction = restrictedTo.map(Array.init) ?? []
        let restrictionClause = restriction.isEmpty
            ? ""
            : " AND sp.id IN (\(restriction.map { _ in "?" }.joined(separator: ", ")))"
        let typeClause = sourceTypes.isEmpty
            ? ""
            : " AND sp.source_type IN (\(sourceTypes.map { _ in "?" }.joined(separator: ", ")))"
        // Hidden sources are searched like any other: hiding is visual only
        // (product owner, 2026-09-11), so a hidden episode or an orphaned course
        // lecture is still an answer. Archived sources are out by status.
        // `excludedSourceIDs` carries the knowledge policy (the sidebar families
        // the learner keeps away from AI), which depends on preferences the SQL
        // cannot see. There is no SQL LIMIT: the cap counts sources the caller
        // will actually see, so an excluded row cannot use up a page and make a
        // truncated answer claim more matches than it shows.
        let sql = """
            SELECT sp.id, sp.title, sp.source_type, sp.author,
                   COALESCE(sp.parent_group_title, sp.parent_group) AS group_name
            FROM source_projection sp
            WHERE sp.status = 'active'\(restrictionClause)\(typeClause)
            ORDER BY sp.date_added DESC
            """
        var candidates: [(id: String, title: String?, sourceType: String?, author: String?, groupName: String?)] = []
        try queryBind(sql, bind: { stmt in
            var index = 1
            for sourceID in restriction {
                self.bind(stmt, index, sourceID)
                index += 1
            }
            for sourceType in sourceTypes {
                self.bind(stmt, index, sourceType)
                index += 1
            }
        }) { stmt in
            guard let sourceID = self.string(stmt, 0), !excludedSourceIDs.contains(sourceID) else { return }
            candidates.append((sourceID, self.string(stmt, 1), self.string(stmt, 2), self.string(stmt, 3), self.string(stmt, 4)))
        }

        let contentSQL = "SELECT content FROM source_content WHERE source_id = ?"
        var contentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, contentSQL, -1, &contentStmt, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw KnowledgeStoreError.execFailed(contentSQL, msg)
        }
        defer { sqlite3_finalize(contentStmt) }

        var matches: [SourceKeywordMatch] = []
        var truncated = false
        for candidate in candidates {
            sqlite3_reset(contentStmt)
            bind(contentStmt, 1, candidate.id)
            let rc = sqlite3_step(contentStmt)
            guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed (\(rc))"
                throw KnowledgeStoreError.execFailed(contentSQL, msg)
            }
            // A source with no body row is still searched by title and author.
            let text = rc == SQLITE_ROW ? sqlite3_column_text(contentStmt, 0) : nil
            let byteCount = text == nil ? 0 : Int(sqlite3_column_bytes(contentStmt, 0))
            let title = candidate.title ?? ""
            let author = candidate.author ?? ""
            var possible = screen.mayContain(UnsafeRawBufferPointer(start: text, count: byteCount))
            for field in [title, author] {
                for (index, mayContain) in screen.mayContain(field).enumerated() where mayContain {
                    possible[index] = true
                }
            }
            let possibleKeywords = zip(searchKeywords, possible).filter(\.1).map(\.0)
            if possibleKeywords.isEmpty || (matchAll && possibleKeywords.count < searchKeywords.count) { continue }

            // Only now is the text worth a Swift string. Past the cap only
            // whether one more source matches is worth knowing, so one
            // mention of each keyword settles it.
            let content = text.map { String(decoding: UnsafeBufferPointer(start: $0, count: byteCount), as: UTF8.self) } ?? ""
            let counts = SourceKeywordSearch.counts(
                of: possibleKeywords,
                inFields: [title, author, content],
                countCeiling: matches.count < maxSources ? 500 : 1
            )
            guard !counts.isEmpty else { continue }
            if matchAll, counts.count < searchKeywords.count { continue }
            guard matches.count < maxSources else {
                truncated = true
                break
            }
            let matched = Set(counts.map(\.keyword))
            matches.append(SourceKeywordMatch(
                sourceID: candidate.id,
                title: candidate.title ?? "Untitled",
                sourceType: candidate.sourceType ?? "unknown",
                author: candidate.author,
                groupName: candidate.groupName,
                keywordCounts: counts,
                snippets: SourceKeywordSearch.snippets(
                    for: possibleKeywords.filter { matched.contains($0.text) },
                    in: content.isEmpty ? [title, author].joined(separator: "\n") : content,
                    limit: snippetsPerSource
                )
            ))
        }

        // Most mentions first: the sources the keyword is actually about lead,
        // and a passing mention sinks, without any ranking model in between.
        matches.sort { lhs, rhs in
            let left = lhs.totalMentions
            let right = rhs.totalMentions
            if left != right { return left > right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return (matches, truncated)
    }

    func deleteSource(_ sourceId: String) throws {
        // Deletes the source plus its goal items and embeddings and records the
        // tombstones in one atomic transaction.
        // An audio overview's carrier names its Artifact in its URL.
        let overviewID = try loadSourceWithoutContent(sourceId).flatMap(GeneratedAudioOverview.artifactID(ofCarrier:))
        try exec("BEGIN IMMEDIATE")
        do {
            try deleteSourceRows(sourceId)
            // An explainer is written about one source and has no life of its
            // own: it goes with the source it explains, in the same transaction
            // (explainer-design.md). Its id is fixed by the URL grammar, so one
            // lookup says whether there is one.
            let explainerID = GeneratedExplainer.sourceID(explaining: sourceId)
            if explainerID != sourceId, try loadSourceWithoutContent(explainerID) != nil {
                try deleteSourceRows(explainerID)
            }
            // An audio overview is its Artifact and its carrier together: the
            // carrier going takes the Artifact, as the Artifact going takes the
            // carrier (`deleteArtifactRecord`). An inbound delete runs
            // sync-suppressed, and a client that deleted only the carrier
            // never tombstoned the Artifact, so that tombstone is published here.
            if let overviewID, try loadArtifact(overviewID) != nil {
                try deleteArtifactRecord(overviewID)
                if syncTrackingSuppressionDepth > 0 {
                    try enqueueCascadingRecordDeletion(entity: .artifact, logicalKey: overviewID)
                }
            }
            try exec("COMMIT")
            // Source-scoped credentials should not outlive their source. This
            // also covers MCP and inbound CloudKit deletions, both of which
            // delete through KnowledgeStore rather than StorageService.
            KeychainService.deleteZoomRecordingPasscode(forSourceID: sourceId)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The row-level half of `deleteSource`, without a transaction of its own,
    /// so a caller deleting several sources at once — a whole meeting series —
    /// gets one atomic delete instead of one per source.
    ///
    /// Generation 1 removes the source's highlights, hidden marks, visible
    /// overrides and Understanding row with it, as their foreign keys did
    /// before schema 154, and tombstones the synced ones. Generation 2 keeps
    /// them, the learner's own state outliving the source (D18).
    func deleteSourceRows(_ sourceId: String) throws {
        let removesPerMemberRows = syncGeneration == .one
        let wasHidden = try removesPerMemberRows && loadHiddenSourceForSync(sourceId) != nil
        let highlightIDs = try removesPerMemberRows ? sourceHighlightIDs(sourceID: sourceId) : []
        var affectedGoalIds: [String] = []
        try queryBind("SELECT DISTINCT goal_id FROM learning_goal_items WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceId)
        }) { stmt in
            if let id = string(stmt, 0) {
                affectedGoalIds.append(id)
            }
        }
        // Generation 2 leaves the source's notebook items: their Entries stay live on the server and
        // hide on read while the source is missing, and a re-import of the same id shows them again
        // (schema v2 §3.5.8, §5.4). The item table has no foreign key to `sources`.
        if syncGeneration == .one {
            try execBind("DELETE FROM learning_goal_items WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceId)
            }
        }
        for goalId in affectedGoalIds {
            try markRecordChanged(entity: .learningGoal, logicalKey: goalId)
        }
        // Its vectors, full-text row and stamps: a deleted source left in search is found by
        // keyword search and, at the next launch, by meaning.
        try dropSourceSearchRows(sourceID: sourceId)
        for highlightID in highlightIDs {
            try markRecordDeleted(entity: .sourceHighlight, logicalKey: highlightID)
        }
        try removePerMemberRowsOfDeletedSource(sourceId)
        try execBind("DELETE FROM sources WHERE id = ?") { stmt in
            bind(stmt, 1, sourceId)
        }
        if wasHidden {
            try markRecordDeleted(entity: .hiddenSource, logicalKey: sourceId)
        }
        try markRecordDeleted(entity: .source, logicalKey: sourceId)
    }

    /// Delete all locally-discovered sources that duplicate a CloudKit-synced source.
    /// Matches by URL (relative or normalized) and deletes every duplicate whose ID differs.
    /// Called inside `withoutSyncTracking` so it does not queue spurious changes for
    /// unrelated entities. Each removed duplicate's own sync state is still reconciled
    /// via `purgeSyncStateForDeletedDuplicate` so it leaves no orphaned `sync_metadata`.
    func deleteLocalDuplicate(of article: StudioArticle) throws {
        // Deletes every duplicate row and reconciles each one's sync state in a
        // single atomic transaction so a partial delete can't orphan sync_metadata.
        try exec("BEGIN IMMEDIATE")
        do {
            try deleteLocalDuplicateRows(of: article)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Archive one paper identity duplicate after moving every user-authored
    /// relationship that names it to the canonical source. Derived paper rows stay
    /// attached to the archived record until ordinary cleanup removes them; this
    /// keeps the merge bounded and reversible while Notebooks, chats, Schedule, and
    /// highlights immediately converge on the surviving identity.
    func archivePaperIdentityDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try archiveSourceIdentityDuplicate(duplicateID, replacingWith: canonicalID)
    }

    /// Archive one meeting session that a retired session-key rule filed a
    /// second time, handing its schedule placements, Notebook membership, chats
    /// and highlights to the session that survives.
    ///
    /// Its artifacts are discarded rather than moved: both rows were read from
    /// the same Drive files, the surviving session already carries a row per
    /// file, and an artifact id is derived from the session that owns it — so
    /// moving them would leave every file listed twice under one meeting.
    func archiveMeetingSessionDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try archiveSourceIdentityDuplicate(
            duplicateID,
            replacingWith: canonicalID,
            discardingMeetingArtifacts: true
        )
    }

    private func archiveSourceIdentityDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String,
        discardingMeetingArtifacts: Bool = false
    ) throws {
        guard duplicateID != canonicalID,
              try sourceExists(duplicateID),
              try sourceExists(canonicalID) else { return }

        try exec("BEGIN IMMEDIATE")
        do {
            try archiveSourceIdentityDuplicateRows(
                duplicateID,
                replacingWith: canonicalID,
                discardingMeetingArtifacts: discardingMeetingArtifacts,
                at: Date()
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The row-level half of `archiveSourceIdentityDuplicate`, inside the
    /// caller's transaction: every relationship authored against the duplicate
    /// — Notebook items, review sessions, schedule placements, highlights,
    /// memory items, group membership, and its meeting artifacts unless they
    /// are discarded — moves to the canonical source, and the duplicate is
    /// archived. Not private, so a caller folding several rows into one at
    /// once (`mergeMeetingSessions`) gets one atomic write rather than one
    /// transaction per row.
    func archiveSourceIdentityDuplicateRows(
        _ duplicateID: String,
        replacingWith canonicalID: String,
        discardingMeetingArtifacts: Bool,
        at now: Date
    ) throws {
        do {
            var discardedMeetingGroupIDs: Set<String> = []
            if discardingMeetingArtifacts {
                try queryBind(
                    "SELECT DISTINCT group_id FROM meeting_artifacts WHERE source_id = ?",
                    bind: { stmt in bind(stmt, 1, duplicateID) }
                ) { stmt in
                    if let id = string(stmt, 0) { discardedMeetingGroupIDs.insert(id) }
                }
                try execBind("DELETE FROM meeting_artifacts WHERE source_id = ?") { stmt in
                    bind(stmt, 1, duplicateID)
                }
            }
            let affectedGoalIDs = try reassignLearningGoalItems(
                from: duplicateID,
                to: canonicalID
            )
            let affectedSessionIDs = try reassignReviewSessionSources(
                from: duplicateID,
                to: canonicalID
            )
            let scheduleChanges = try reassignScheduledSource(
                from: duplicateID,
                to: canonicalID
            )
            let relationshipChanges = try reassignSimpleSourceRelationships(
                from: duplicateID,
                to: canonicalID
            )

            try execBind("UPDATE sources SET status = ?, archived_at = ? WHERE id = ?") { stmt in
                bind(stmt, 1, SourceStatus.archived.rawValue)
                bind(stmt, 2, Self.iso8601Formatter.string(from: now))
                bind(stmt, 3, duplicateID)
            }
            // The canonical source is searched in its place; the duplicate's rows would answer for it.
            try dropSourceSearchRows(sourceID: duplicateID)

            for goalID in affectedGoalIDs {
                try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
            }
            for sessionID in affectedSessionIDs {
                try markRecordChanged(entity: .reviewSession, logicalKey: sessionID, at: now)
            }
            for highlightID in relationshipChanges.highlightIDs {
                try markRecordChanged(entity: .sourceHighlight, logicalKey: highlightID, at: now)
            }
            for memoryItemID in relationshipChanges.memoryItemIDs {
                try markRecordChanged(entity: .memoryItem, logicalKey: memoryItemID, at: now)
            }
            for goalID in relationshipChanges.learningGoalIDs {
                try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
            }
            for meetingGroupID in relationshipChanges.meetingGroupIDs.union(discardedMeetingGroupIDs) {
                try markRecordChanged(entity: .meetingGroup, logicalKey: meetingGroupID, at: now)
            }
            for citedPaperID in relationshipChanges.videoCitedPaperIDs {
                try markRecordChanged(entity: .videoCitedPaper, logicalKey: citedPaperID, at: now)
            }
            for groupID in relationshipChanges.groupIDs {
                if try loadBookForSync(groupID) != nil {
                    try markRecordChanged(entity: .book, logicalKey: groupID, at: now)
                }
                if try loadVideoPlaylistForSync(groupID) != nil {
                    try markRecordChanged(entity: .videoPlaylist, logicalKey: groupID, at: now)
                }
            }
            for placementID in scheduleChanges.savedPlacementIDs {
                try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: now)
            }
            for placementID in scheduleChanges.deletedPlacementIDs {
                try markRecordDeleted(entity: .scheduledSource, logicalKey: placementID, at: now)
            }
            try markRecordChanged(entity: .source, logicalKey: canonicalID, at: now)
            try markRecordChanged(entity: .source, logicalKey: duplicateID, at: now)
        }
    }

    /// Merge Notebook membership and learning evidence for a duplicate source.
    /// An approved item wins over a pending/rejected copy, while monotonic study
    /// evidence is combined so deduplication cannot erase completion or quiz work.
    private func reassignLearningGoalItems(
        from duplicateID: String,
        to canonicalID: String
    ) throws -> [String] {
        var goalIDs: [String] = []
        try queryBind(
            "SELECT DISTINCT goal_id FROM learning_goal_items WHERE source_id IN (?, ?)",
            bind: { stmt in
                bind(stmt, 1, duplicateID)
                bind(stmt, 2, canonicalID)
            }
        ) { stmt in
            if let goalID = string(stmt, 0) { goalIDs.append(goalID) }
        }

        // Move non-overlapping Notebook membership without changing its stable item id.
        try execBind("""
            UPDATE learning_goal_items
            SET source_id = ?
            WHERE source_id = ?
              AND NOT EXISTS (
                  SELECT 1 FROM learning_goal_items canonical
                  WHERE canonical.goal_id = learning_goal_items.goal_id
                    AND canonical.source_id = ?
              )
        """) { stmt in
            bind(stmt, 1, canonicalID)
            bind(stmt, 2, duplicateID)
            bind(stmt, 3, canonicalID)
        }

        // Overlapping membership is one logical Notebook item. Fold the duplicate's
        // evidence into the canonical row before deleting the redundant item.
        try execBind("""
            UPDATE learning_goal_items AS canonical
            SET added_at = MIN(canonical.added_at, (
                    SELECT duplicate.added_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                completed_at = COALESCE(MAX(canonical.completed_at, (
                    SELECT duplicate.completed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.completed_at, (
                    SELECT duplicate.completed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                origin = COALESCE(canonical.origin, (
                    SELECT duplicate.origin FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                review_state = CASE
                    WHEN canonical.review_state = 'approved' OR EXISTS (
                        SELECT 1 FROM learning_goal_items duplicate
                        WHERE duplicate.goal_id = canonical.goal_id
                          AND duplicate.source_id = ? AND duplicate.review_state = 'approved'
                    ) THEN 'approved'
                    WHEN canonical.review_state = 'pending' OR EXISTS (
                        SELECT 1 FROM learning_goal_items duplicate
                        WHERE duplicate.goal_id = canonical.goal_id
                          AND duplicate.source_id = ? AND duplicate.review_state = 'pending'
                    ) THEN 'pending'
                    ELSE COALESCE(canonical.review_state, 'rejected')
                END,
                relevance = COALESCE(MAX(canonical.relevance, (
                    SELECT duplicate.relevance FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.relevance, (
                    SELECT duplicate.relevance FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                last_quizzed_at = COALESCE(MAX(canonical.last_quizzed_at, (
                    SELECT duplicate.last_quizzed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.last_quizzed_at, (
                    SELECT duplicate.last_quizzed_at FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                quiz_count = COALESCE(MAX(canonical.quiz_count, (
                    SELECT duplicate.quiz_count FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.quiz_count, (
                    SELECT duplicate.quiz_count FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                last_score = COALESCE(MAX(canonical.last_score, (
                    SELECT duplicate.last_score FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.last_score, (
                    SELECT duplicate.last_score FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )),
                sequence = COALESCE(MIN(canonical.sequence, (
                    SELECT duplicate.sequence FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                )), canonical.sequence, (
                    SELECT duplicate.sequence FROM learning_goal_items duplicate
                    WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
                ))
            WHERE canonical.source_id = ?
              AND EXISTS (
                  SELECT 1 FROM learning_goal_items duplicate
                  WHERE duplicate.goal_id = canonical.goal_id AND duplicate.source_id = ?
              )
        """) { stmt in
            for index in 1...16 { bind(stmt, index, duplicateID) }
            bind(stmt, 17, canonicalID)
            bind(stmt, 18, duplicateID)
        }
        try execBind("DELETE FROM learning_goal_items WHERE source_id = ?") { stmt in
            bind(stmt, 1, duplicateID)
        }
        return goalIDs
    }

    /// Session JSON is the canonical relationship and the junction is its local
    /// projection. Rewrite both so the next CloudKit save cannot resurrect the
    /// duplicate id.
    private func reassignReviewSessionSources(
        from duplicateID: String,
        to canonicalID: String
    ) throws -> [String] {
        var sessions: [(id: String, sourceIDs: [String])] = []
        try queryBind("""
            SELECT id, source_ids FROM review_sessions
            WHERE EXISTS (
                SELECT 1 FROM json_each(
                    CASE WHEN json_valid(review_sessions.source_ids)
                         THEN review_sessions.source_ids ELSE '[]' END
                ) WHERE value = ?
            )
        """, bind: { stmt in
            bind(stmt, 1, duplicateID)
        }) { stmt in
            guard let id = string(stmt, 0) else { return }
            let raw = string(stmt, 1) ?? "[]"
            let ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
            sessions.append((id, ids))
        }

        for session in sessions {
            var seen = Set<String>()
            let rewritten = session.sourceIDs.compactMap { sourceID -> String? in
                let resolved = sourceID == duplicateID ? canonicalID : sourceID
                return seen.insert(resolved).inserted ? resolved : nil
            }
            try execBind("UPDATE review_sessions SET source_ids = ? WHERE id = ?") { stmt in
                bind(stmt, 1, jsonString(from: rewritten))
                bind(stmt, 2, session.id)
            }
            try replaceReviewSessionSources(sessionID: session.id, sourceIDs: rewritten)
        }
        return sessions.map(\.id)
    }

    private struct DuplicateScheduleChanges {
        var savedPlacementIDs: [String] = []
        var deletedPlacementIDs: [String] = []
    }

    /// Schedule is source-global. If both duplicate ids were placed, merge their
    /// goal tags and activity ledger into the canonical placement; otherwise move
    /// the sole placement without changing its stable id.
    private func reassignScheduledSource(
        from duplicateID: String,
        to canonicalID: String
    ) throws -> DuplicateScheduleChanges {
        struct Placement {
            let id: String
            let isAutomatic: Bool
        }
        func placement(for sourceID: String) throws -> Placement? {
            var result: Placement?
            try queryBind(
                "SELECT id, is_automatic FROM scheduled_sources WHERE source_id = ? LIMIT 1",
                bind: { stmt in bind(stmt, 1, sourceID) }
            ) { stmt in
                if let id = string(stmt, 0) {
                    result = Placement(id: id, isAutomatic: sqlite3_column_int(stmt, 1) != 0)
                }
            }
            return result
        }

        guard let duplicate = try placement(for: duplicateID) else { return .init() }
        guard let canonical = try placement(for: canonicalID) else {
            try execBind("""
                UPDATE scheduled_sources
                SET source_id = ?,
                    source_url = (SELECT url FROM source_projection WHERE id = ?),
                    source_normalized_url = (SELECT normalized_url FROM source_projection WHERE id = ?),
                    source_doi = (SELECT doi FROM source_projection WHERE id = ?),
                    source_published_doi = (SELECT published_doi FROM source_projection WHERE id = ?),
                    updated_at = ?
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, canonicalID)
                bind(stmt, 2, canonicalID)
                bind(stmt, 3, canonicalID)
                bind(stmt, 4, canonicalID)
                bind(stmt, 5, canonicalID)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSinceReferenceDate)
                bind(stmt, 7, duplicate.id)
            }
            // The placement keeps its id and moves; its ledger follows under
            // the canonical source's own day ids.
            try moveSourceActivityDays(
                fromPlacement: duplicate.id,
                toPlacement: duplicate.id,
                canonicalID: canonicalID
            )
            return DuplicateScheduleChanges(savedPlacementIDs: [duplicate.id])
        }

        try execBind("""
            INSERT OR IGNORE INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
            SELECT ?, goal_id, added_at FROM scheduled_source_goals
            WHERE scheduled_source_id = ?
        """) { stmt in
            bind(stmt, 1, canonical.id)
            bind(stmt, 2, duplicate.id)
        }
        try moveSourceActivityDays(
            fromPlacement: duplicate.id,
            toPlacement: canonical.id,
            canonicalID: canonicalID
        )
        try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?") { stmt in
            bind(stmt, 1, duplicate.id)
        }
        // An explicit placement wins over an automatic history row. Otherwise
        // keep the canonical day and only combine monotonic completion evidence.
        try execBind("""
            UPDATE scheduled_sources
            SET planned_at = CASE WHEN is_automatic = 1 AND ? = 0
                                  THEN (SELECT planned_at FROM scheduled_sources WHERE id = ?)
                                  ELSE planned_at END,
                completed_at = COALESCE(MAX(completed_at, (
                    SELECT completed_at FROM scheduled_sources WHERE id = ?
                )), completed_at, (
                    SELECT completed_at FROM scheduled_sources WHERE id = ?
                )),
                added_at = MIN(added_at, (SELECT added_at FROM scheduled_sources WHERE id = ?)),
                updated_at = MAX(updated_at, (SELECT updated_at FROM scheduled_sources WHERE id = ?)),
                is_automatic = CASE WHEN is_automatic = 0 OR ? = 0 THEN 0 ELSE 1 END
            WHERE id = ?
        """) { stmt in
            sqlite3_bind_int(stmt, 1, duplicate.isAutomatic ? 1 : 0)
            bind(stmt, 2, duplicate.id)
            bind(stmt, 3, duplicate.id)
            bind(stmt, 4, duplicate.id)
            bind(stmt, 5, duplicate.id)
            bind(stmt, 6, duplicate.id)
            sqlite3_bind_int(stmt, 7, duplicate.isAutomatic ? 1 : 0)
            bind(stmt, 8, canonical.id)
        }
        try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
            bind(stmt, 1, duplicate.id)
        }
        return DuplicateScheduleChanges(
            savedPlacementIDs: [canonical.id],
            deletedPlacementIDs: [duplicate.id]
        )
    }

    /// Move a duplicate placement's activity ledger under the canonical source.
    /// A day the canonical source already has folds into that row (earliest
    /// first, latest last, kinds OR-ed, depth and engaged time by MAX); a day it
    /// lacks keeps the duplicate's row, re-keyed to the canonical source under
    /// the id the canonical source gives that day (`sourceActivityDayID`, so a
    /// device syncing the same day derives the same row).
    ///
    /// This used to copy the rows under their old ids with an upsert on
    /// `(source_id, day_start)`. The row being copied was still in the table, so
    /// whenever the duplicate had a day the canonical did not, the copy hit the
    /// primary key instead of the upsert's target and the whole merge failed —
    /// which is how Merge Same-Day Sessions refused two standup calls that had
    /// both been read, and so both placed on the calendar (2026-09-19).
    private func moveSourceActivityDays(
        fromPlacement duplicatePlacementID: String,
        toPlacement canonicalPlacementID: String,
        canonicalID: String
    ) throws {
        struct Row {
            let id: String
            let dayStart: Double
        }
        var rows: [Row] = []
        try queryBind(
            "SELECT id, day_start FROM source_activity_days WHERE scheduled_source_id = ?",
            bind: { stmt in bind(stmt, 1, duplicatePlacementID) }
        ) { stmt in
            if let id = string(stmt, 0) {
                rows.append(Row(id: id, dayStart: sqlite3_column_double(stmt, 1)))
            }
        }
        guard !rows.isEmpty else { return }
        let canonicalKey = try portableMemorySourceKey(sourceID: canonicalID)

        for row in rows {
            var canonicalRowID: String?
            try queryBind(
                "SELECT id FROM source_activity_days WHERE source_id = ? AND day_start = ? AND id != ? LIMIT 1",
                bind: { stmt in
                    bind(stmt, 1, canonicalID)
                    bind(stmt, 2, row.dayStart)
                    bind(stmt, 3, row.id)
                }
            ) { stmt in
                canonicalRowID = string(stmt, 0)
            }

            if let canonicalRowID {
                // Both sources were used that day: one row keeps the union of
                // the evidence. Engaged time merges by MAX, as a synced total
                // does, because the duplicate's seconds are the same sitting
                // counted under another id, not a fresh slice.
                try execBind("""
                    UPDATE source_activity_days SET
                        first_activity_at = MIN(first_activity_at, (SELECT first_activity_at FROM source_activity_days WHERE id = ?)),
                        last_activity_at = MAX(last_activity_at, (SELECT last_activity_at FROM source_activity_days WHERE id = ?)),
                        kinds = kinds | (SELECT kinds FROM source_activity_days WHERE id = ?),
                        completed_kinds = completed_kinds | (SELECT completed_kinds FROM source_activity_days WHERE id = ?),
                        max_fraction = MAX(max_fraction, (SELECT max_fraction FROM source_activity_days WHERE id = ?)),
                        engaged_seconds = MAX(engaged_seconds, (SELECT engaged_seconds FROM source_activity_days WHERE id = ?))
                    WHERE id = ?
                """) { stmt in
                    bind(stmt, 1, row.id)
                    bind(stmt, 2, row.id)
                    bind(stmt, 3, row.id)
                    bind(stmt, 4, row.id)
                    bind(stmt, 5, row.id)
                    bind(stmt, 6, row.id)
                    bind(stmt, 7, canonicalRowID)
                }
                try execBind("DELETE FROM source_activity_days WHERE id = ?") { stmt in
                    bind(stmt, 1, row.id)
                }
            } else {
                let derivedID = MemoryTutorIdentity.sourceActivityDayID(
                    portableSourceKey: canonicalKey,
                    dayStart: Date(timeIntervalSinceReferenceDate: row.dayStart)
                )
                var derivedIDTaken = false
                try queryBind(
                    "SELECT 1 FROM source_activity_days WHERE id = ? AND id != ? LIMIT 1",
                    bind: { stmt in
                        bind(stmt, 1, derivedID)
                        bind(stmt, 2, row.id)
                    }
                ) { _ in derivedIDTaken = true }
                try execBind("""
                    UPDATE source_activity_days
                    SET id = ?, scheduled_source_id = ?, source_id = ?
                    WHERE id = ?
                """) { stmt in
                    bind(stmt, 1, derivedIDTaken ? row.id : derivedID)
                    bind(stmt, 2, canonicalPlacementID)
                    bind(stmt, 3, canonicalID)
                    bind(stmt, 4, row.id)
                }
            }
        }
    }

    /// Move source relationships whose rows have their own stable identity. The
    /// duplicate Source itself remains archived, so source-owned derived products
    /// do not need an unbounded copy during this user-visible repair.
    private struct DuplicateRelationshipChanges {
        var highlightIDs = Set<String>()
        var memoryItemIDs = Set<String>()
        var learningGoalIDs = Set<String>()
        var meetingGroupIDs = Set<String>()
        var videoCitedPaperIDs = Set<String>()
        var groupIDs = Set<String>()
    }

    private func reassignSimpleSourceRelationships(
        from duplicateID: String,
        to canonicalID: String
    ) throws -> DuplicateRelationshipChanges {
        var changes = DuplicateRelationshipChanges()
        try queryBind("SELECT highlight_id FROM source_highlights WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, duplicateID)
        }) { stmt in
            if let id = string(stmt, 0) { changes.highlightIDs.insert(id) }
        }

        func tableExists(_ table: String) throws -> Bool {
            var exists = false
            try queryBind(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
                bind: { stmt in bind(stmt, 1, table) }
            ) { _ in exists = true }
            return exists
        }

        func collectParentIDs(table: String, column: String, into ids: inout Set<String>) throws {
            guard try tableExists(table) else { return }
            try queryBind(
                "SELECT DISTINCT \(column) FROM \(table) WHERE source_id = ?",
                bind: { stmt in bind(stmt, 1, duplicateID) }
            ) { stmt in
                if let id = string(stmt, 0) { ids.insert(id) }
            }
        }

        try collectParentIDs(
            table: "memory_item_sources",
            column: "memory_item_id",
            into: &changes.memoryItemIDs
        )
        try collectParentIDs(
            table: "learning_goal_gaps",
            column: "goal_id",
            into: &changes.learningGoalIDs
        )
        try collectParentIDs(
            table: "meeting_artifacts",
            column: "group_id",
            into: &changes.meetingGroupIDs
        )
        if try tableExists("video_cited_papers") {
            try queryBind(
                "SELECT id FROM video_cited_papers WHERE imported_source_id = ?",
                bind: { stmt in bind(stmt, 1, duplicateID) }
            ) { stmt in
                if let id = string(stmt, 0) { changes.videoCitedPaperIDs.insert(id) }
            }
        }
        if try tableExists("group_members") {
            try queryBind(
                "SELECT DISTINCT group_id FROM group_members WHERE source_id = ?",
                bind: { stmt in bind(stmt, 1, duplicateID) }
            ) { stmt in
                if let id = string(stmt, 0) { changes.groupIDs.insert(id) }
            }
        }

        let simpleTables = [
            "source_highlights", "memory_item_sources", "learning_goal_gaps",
            "meeting_artifacts", "research_canvas_items",
            "research_canvas_slide_blocks", "draft_cards"
        ]
        for table in simpleTables {
            guard try tableExists(table) else { continue }
            try execBind("UPDATE \(table) SET source_id = ? WHERE source_id = ?") { stmt in
                bind(stmt, 1, canonicalID)
                bind(stmt, 2, duplicateID)
            }
        }
        try execBind("UPDATE video_cited_papers SET imported_source_id = ? WHERE imported_source_id = ?") { stmt in
            bind(stmt, 1, canonicalID)
            bind(stmt, 2, duplicateID)
        }
        try execBind("""
            INSERT OR IGNORE INTO group_members (source_id, group_id, sort_index, lecture_group_id)
            SELECT ?, group_id, sort_index, lecture_group_id
            FROM group_members WHERE source_id = ?
        """) { stmt in
            bind(stmt, 1, canonicalID)
            bind(stmt, 2, duplicateID)
        }
        try execBind("DELETE FROM group_members WHERE source_id = ?") { stmt in
            bind(stmt, 1, duplicateID)
        }
        return changes
    }

    private func deleteLocalDuplicateRows(of article: StudioArticle) throws {
        let persistedURL = StorageService.relativeSourcePath(article.url)
        let normURL = article.normalizedURL ?? URLNormalizer.normalize(article.url)

        var duplicateIds: [String] = []
        try queryBind("""
            SELECT id FROM source_projection
            WHERE (url = ? OR normalized_url = ?) AND id != ?
        """, bind: { stmt in
            bind(stmt, 1, persistedURL)
            bind(stmt, 2, normURL)
            bind(stmt, 3, article.id)
        }) { stmt in
            if let id = string(stmt, 0) {
                duplicateIds.append(id)
            }
        }

        for dupId in duplicateIds {
            try execBind("DELETE FROM embeddings WHERE entity_type = ? AND entity_id = ?") { stmt in
                bind(stmt, 1, KnowledgeEntityType.source.rawValue)
                bind(stmt, 2, dupId)
            }
            try deleteEmbeddings(
                entityType: .sourceChunk,
                entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: dupId),
                model: StorageService.sourceEmbeddingModel
            )
            // Generation 1: what the foreign keys removed before schema 154.
            try removePerMemberRowsOfDeletedSource(dupId)
            try execBind("DELETE FROM sources WHERE id = ?") { stmt in
                bind(stmt, 1, dupId)
            }
            try purgeSyncStateForDeletedDuplicate(dupId)
        }
    }

    /// Remove the CloudKit sync bookkeeping for a locally-deleted duplicate source.
    ///
    /// `deleteLocalDuplicate` runs under `withoutSyncTracking`, which suppresses
    /// `markRecordDeleted`. Without this, deleting the `sources` row leaves the
    /// duplicate's `sync_metadata` behind as a live orphan (metadata says synced &
    /// alive, but the row is gone) — and if it had already been pushed, CloudKit
    /// would resurrect it on the next fetch. So we record the deletion directly:
    /// tombstone + queue a delete when it was synced, otherwise drop the stale
    /// metadata outright.
    func purgeSyncStateForDeletedDuplicate(_ sourceID: String) throws {
        guard let metadata = try loadSyncMetadata(entity: .source, logicalKey: sourceID) else { return }
        guard metadata.systemFieldsData != nil else {
            // Never reached CloudKit — just drop the stale local metadata.
            try clearSyncMetadata(entity: .source, logicalKey: sourceID)
            return
        }
        // Was synced — tombstone and queue a delete so the redundant CloudKit
        // record is removed instead of resurrecting the duplicate.
        try saveSyncMetadata(
            CloudKitSyncMetadata(
                entity: .source,
                logicalKey: sourceID,
                recordName: metadata.recordName,
                systemFieldsData: nil,
                userModificationDate: Date(),
                isDeleted: true
            )
        )
        try execBind("""
            INSERT INTO sync_changes (entity_type, logical_key, record_name, operation, changed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                record_name = excluded.record_name,
                operation = excluded.operation,
                changed_at = excluded.changed_at
        """) { stmt in
            bind(stmt, 1, CloudKitSyncEntity.source.rawValue)
            bind(stmt, 2, sourceID)
            bind(stmt, 3, metadata.recordName)
            bind(stmt, 4, CloudKitSyncOperation.delete.rawValue)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSinceReferenceDate)
        }
    }

    /// Return content from a local duplicate before replacing it with a CloudKit-synced source.
    /// This prevents metadata-only remote records from discarding text already extracted locally.
    func loadLocalDuplicateContent(of article: StudioArticle) throws -> String? {
        let persistedURL = StorageService.relativeSourcePath(article.url)
        let normalizedURL = article.normalizedURL ?? URLNormalizer.normalize(article.url)
        var content: String?
        try queryBind("""
            SELECT sc.content
            FROM source_projection sp
            JOIN source_content sc ON sc.source_id = sp.id
            WHERE sp.id != ?
              AND sc.content IS NOT NULL
              AND sc.content != ''
              AND (
                sp.url = ?
                OR sp.url = ?
                OR sp.normalized_url = ?
                OR sp.normalized_url = ?
              )
            ORDER BY length(sc.content) DESC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, article.id)
            bind(stmt, 2, persistedURL)
            bind(stmt, 3, article.url)
            bind(stmt, 4, normalizedURL)
            bind(stmt, 5, persistedURL)
        }) { stmt in
            content = string(stmt, 0)
        }
        return content
    }

    /// Mark a source URL as dismissed so it won't be re-discovered.
    func dismissSource(url: String, title: String?) throws {
        let persistedURL = StorageService.relativeSourcePath(url)
        // Never dismiss book chapters. Dismissal is for re-discoverable web/feed
        // sources; a book chapter's local-file URL persisting in dismissed_sources
        // would silently re-archive the chapter on every sync (see
        // archiveSourcesMatchingDismissedURL).
        if try isBookSourceURL(persistedURL) { return }
        try execBind("""
            INSERT INTO dismissed_sources (url, title, dismissed_at)
            VALUES (?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET title = excluded.title, dismissed_at = excluded.dismissed_at
        """) { stmt in
            bind(stmt, 1, persistedURL)
            bind(stmt, 2, title)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSinceReferenceDate)
        }
        try archiveSourcesMatchingDismissedURL(persistedURL)
        try markRecordChanged(entity: .dismissedSource, logicalKey: persistedURL)
    }

    /// Whether a (persisted) URL belongs to a book source. Book chapters are keyed
    /// by a local file path and must be exempt from the dismissal mechanism.
    func isBookSourceURL(_ persistedURL: String) throws -> Bool {
        let normalizedURL = URLNormalizer.normalize(persistedURL)
        var isBook = false
        try queryBind("""
            SELECT 1 FROM source_projection
            WHERE source_type = 'book'
              AND (url = ? OR normalized_url = ?)
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, persistedURL)
            bind(stmt, 2, normalizedURL)
        }) { _ in
            isBook = true
        }
        return isBook
    }

    /// Check whether a source URL has been dismissed by the user.
    func isSourceDismissed(url: String) -> Bool {
        let persistedURL = StorageService.relativeSourcePath(url)
        let normalizedURL = URLNormalizer.normalize(url)
        var found = false
        try? queryBind("SELECT 1 FROM dismissed_sources WHERE url = ? OR url = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, persistedURL)
            bind(stmt, 2, normalizedURL)
        }) { _ in
            found = true
        }
        if found { return true }

        try? query("SELECT url FROM dismissed_sources") { stmt in
            guard !found, let dismissedURL = string(stmt, 0) else { return }
            found = URLNormalizer.normalize(dismissedURL) == normalizedURL
        }
        return found
    }

    /// Clear a dismissal so a deliberately re-added source can come back.
    ///
    /// Dismissal is a "don't re-discover this" tombstone and it blocks *both*
    /// ways a source can return: `insertSourceIfNew` refuses the URL and
    /// `unarchiveSourceMatchingURL` refuses to revive it. That is correct for
    /// passive re-discovery, but when the user re-adds the same URL through an
    /// explicit upstream action — liking the video again on YouTube — the newer
    /// intent wins and the tombstone has to be removed rather than bypassed:
    /// leaving the row in place would let the next inbound CloudKit source
    /// record re-archive the source through `archiveSourcesMatchingDismissedURL`.
    ///
    /// Also records deletions for the supplied and normalized spellings even
    /// when no local row exists yet. An older DismissedSource record may still
    /// be in flight from CloudKit; the explicit re-add must publish a newer
    /// deletion before that stale record arrives and archives the new source.
    ///
    /// Returns every DismissedSource logical key tombstoned by this call.
    @discardableResult
    func undismissSource(url: String) throws -> [String] {
        let persistedURL = StorageService.relativeSourcePath(url)
        let normalizedURL = URLNormalizer.normalize(url)
        // Match exactly the way `isSourceDismissed` does, fuzzy pass included: a
        // tombstone that can block a source has to be clearable by the same key,
        // or the block it causes is unfixable. Collect the stored spellings first
        // so each deletion is tracked under the logical key CloudKit knows.
        var matches: [String] = []
        try query("SELECT url FROM dismissed_sources") { stmt in
            guard let dismissedURL = string(stmt, 0) else { return }
            if dismissedURL == persistedURL
                || dismissedURL == normalizedURL
                || URLNormalizer.normalize(dismissedURL) == normalizedURL {
                matches.append(dismissedURL)
            }
        }
        var deletionKeys = Set(matches)
        deletionKeys.insert(persistedURL)
        deletionKeys.insert(normalizedURL)
        deletionKeys.remove("")
        for dismissedURL in deletionKeys {
            try execBind("DELETE FROM dismissed_sources WHERE url = ?") { stmt in
                bind(stmt, 1, dismissedURL)
            }
            try markRecordDeleted(entity: .dismissedSource, logicalKey: dismissedURL)
        }
        return deletionKeys.sorted()
    }

    @discardableResult
    func archiveSourcesMatchingDismissedURL(_ url: String) throws -> [String] {
        let persistedURL = StorageService.relativeSourcePath(url)
        let normalizedURL = URLNormalizer.normalize(url)
        var sourceIDs: [String] = []
        // The dismissal mechanism exists to stop re-discovered *web/feed* sources
        // from coming back. Book chapters are manually imported and keyed by a local
        // file path; a stale dismissal of that path must never archive (and content-
        // wipe) them. Excluding books here is the single chokepoint that guarantees
        // it, covering the dismiss action and both CloudKit resurrection paths.
        try queryBind("""
            SELECT DISTINCT id
            FROM source_projection
            WHERE status = ?
              AND source_type != 'book'
              AND (
                url = ?
                OR url = ?
                OR normalized_url = ?
                OR normalized_url = ?
                OR podcast_web_page_url = ?
                OR podcast_web_page_url = ?
              )
        """, bind: { stmt in
            bind(stmt, 1, SourceStatus.active.rawValue)
            bind(stmt, 2, url)
            bind(stmt, 3, persistedURL)
            bind(stmt, 4, url)
            bind(stmt, 5, normalizedURL)
            bind(stmt, 6, url)
            bind(stmt, 7, persistedURL)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                sourceIDs.append(id)
            }
        }

        for sourceID in sourceIDs {
            try archiveSource(sourceID)
            // `archiveSource` records its own sync change, but two of the three
            // callers run inside `withoutSyncTracking` — the inbound
            // DismissedSource record, and an inbound Source record whose URL is
            // already dismissed locally — where that call is a no-op. The
            // suppression is there to stop the *arriving* record from echoing
            // back; these archives are not an echo, they are a local change no
            // other device knows about, so they must still publish.
            //
            // Without this the server keeps serving the source as active with
            // its text wiped, and every full pass re-sends it and re-archives it
            // here: a loop that never converges, and other devices list a source
            // they cannot open. `upsertSyncSave` is deliberately not
            // suppression-gated, which is what lets the archive out.
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: Date())
        }
        return sourceIDs
    }

    /// Load all dismissed source URLs, resolving relative paths to absolute.
    func loadDismissedSourceURLs() throws -> Set<String> {
        var urls = Set<String>()
        try query("SELECT url FROM dismissed_sources") { stmt in
            if let url = string(stmt, 0) {
                urls.insert(StorageService.absoluteSourcePath(url))
            }
        }
        return urls
    }

    /// Load dismissal timestamps keyed by the stored URL, so a feed mirror can
    /// weigh an upstream action's date against when the user removed the same
    /// source here.
    func loadDismissedSourceDates() throws -> [String: Date] {
        var dates: [String: Date] = [:]
        try query("SELECT url, dismissed_at FROM dismissed_sources") { stmt in
            if let url = string(stmt, 0) {
                dates[url] = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            }
        }
        return dates
    }

    func loadHiddenPodcastShows() throws -> Set<String> {
        var names = Set<String>()
        try query("SELECT show_name FROM hidden_podcast_shows") { stmt in
            if let name = string(stmt, 0) {
                names.insert(name)
            }
        }
        return names
    }

    /// Hides or unhides a whole show. Unhiding also reveals the episodes that
    /// were hidden one by one *after* the show was: another device syncing the
    /// show's hidden state writes a hidden record per episode, so a show
    /// unhidden on its own came back empty. Episodes hidden before the show
    /// was are the learner's own choices and stay hidden. Returns the ids of
    /// the episodes revealed this way.
    @discardableResult
    func setPodcastShowHidden(_ showName: String, hidden: Bool) throws -> [String] {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let affectedOverrideIDs = try loadVisiblePodcastEpisodeOverrideIDs(forShow: trimmed)
        var revealedEpisodeIDs: [String] = []
        if hidden {
            try execBind("""
                INSERT INTO hidden_podcast_shows (show_name, hidden_at)
                VALUES (?, ?)
                ON CONFLICT(show_name) DO UPDATE SET hidden_at = excluded.hidden_at
            """) { stmt in
                bind(stmt, 1, trimmed)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            }
            try deleteVisiblePodcastEpisodeOverrides(forShow: trimmed)
            try execBind("""
                DELETE FROM podcast_transcript_cleanup_queue
                WHERE source_id IN (
                    SELECT source_id FROM podcasts
                    WHERE domain = ? OR show_name = ?
                )
            """) { stmt in
                bind(stmt, 1, trimmed)
                bind(stmt, 2, trimmed)
            }
        } else {
            let showHiddenAt = try hiddenPodcastShowHiddenAt(trimmed)
            try execBind("DELETE FROM hidden_podcast_shows WHERE show_name = ?") { stmt in
                bind(stmt, 1, trimmed)
            }
            if let showHiddenAt {
                revealedEpisodeIDs = try podcastEpisodeIDsHidden(since: showHiddenAt, forShow: trimmed)
                for sourceID in revealedEpisodeIDs {
                    try setPodcastEpisodeHidden(sourceID, hidden: false)
                }
            }
            for sourceID in try podcastSourceIDs(forShow: trimmed) {
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
            }
        }
        for sourceID in affectedOverrideIDs {
            try markRecordChanged(entity: .source, logicalKey: sourceID)
        }
        if hidden {
            try markRecordChanged(entity: .hiddenPodcastShow, logicalKey: trimmed)
        } else {
            try markRecordDeleted(entity: .hiddenPodcastShow, logicalKey: trimmed)
        }
        return revealedEpisodeIDs
    }

    private func hiddenPodcastShowHiddenAt(_ showName: String) throws -> Date? {
        var hiddenAt: Date?
        try queryBind("SELECT hidden_at FROM hidden_podcast_shows WHERE show_name = ?", bind: { stmt in
            bind(stmt, 1, showName)
        }) { stmt in
            hiddenAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return hiddenAt
    }

    /// Episodes of `showName` whose own hidden record is not older than
    /// `since`, whichever table holds it.
    private func podcastEpisodeIDsHidden(since: Date, forShow showName: String) throws -> [String] {
        var ids: [String] = []
        let cutoff = since.timeIntervalSinceReferenceDate
        try queryBind("""
            SELECT DISTINCT p.source_id
            FROM podcasts p
            JOIN sources ps ON ps.id = p.source_id
            LEFT JOIN hidden_podcast_episodes he ON he.source_id IN (ps.id, ps.wire_key)
            LEFT JOIN hidden_sources hs ON hs.source_id IN (ps.id, ps.wire_key)
            WHERE (p.domain = ? OR p.show_name = ?)
              AND (he.hidden_at >= ? OR hs.hidden_at >= ?)
        """, bind: { stmt in
            bind(stmt, 1, showName)
            bind(stmt, 2, showName)
            sqlite3_bind_double(stmt, 3, cutoff)
            sqlite3_bind_double(stmt, 4, cutoff)
        }) { stmt in
            if let id = string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func loadHiddenYouTubeChannels() throws -> Set<String> {
        var names = Set<String>()
        try query("SELECT channel_name FROM hidden_youtube_channels") { stmt in
            if let name = string(stmt, 0) { names.insert(name) }
        }
        return names
    }

    func setYouTubeChannelHidden(_ channelName: String, hidden: Bool) throws {
        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let affectedOverrideIDs = try loadVisibleYouTubeVideoOverrideIDs(forChannel: trimmed)
        if hidden {
            try execBind("""
                INSERT INTO hidden_youtube_channels (channel_name, hidden_at)
                VALUES (?, ?)
                ON CONFLICT(channel_name) DO UPDATE SET hidden_at = excluded.hidden_at
            """) { stmt in
                bind(stmt, 1, trimmed)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            }
            try deleteVisibleYouTubeVideoOverrides(forChannel: trimmed)
        } else {
            try execBind("DELETE FROM hidden_youtube_channels WHERE channel_name = ?") { stmt in
                bind(stmt, 1, trimmed)
            }
        }
        for sourceID in affectedOverrideIDs {
            try markRecordChanged(entity: .source, logicalKey: sourceID)
        }
        if hidden {
            try markRecordChanged(entity: .hiddenYouTubeChannel, logicalKey: trimmed)
        } else {
            try markRecordDeleted(entity: .hiddenYouTubeChannel, logicalKey: trimmed)
        }
    }

    func loadHiddenPodcastEpisodeIDs() throws -> Set<String> {
        var ids = Set<String>()
        try query("""
            SELECT s.id FROM hidden_podcast_episodes h JOIN sources s ON h.source_id IN (s.id, s.wire_key)
            UNION
            SELECT s.id
            FROM hidden_sources hs
            JOIN sources s ON hs.source_id IN (s.id, s.wire_key)
            WHERE s.source_type = 'podcast'
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                ids.insert(sourceID)
            }
        }
        return ids
    }

    func setPodcastEpisodeHidden(_ sourceID: String, hidden: Bool) throws {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = try personalStateSourceKey(trimmed)

        if hidden {
            try execBind("""
                INSERT INTO hidden_podcast_episodes (source_id, hidden_at)
                VALUES (?, ?)
                ON CONFLICT(source_id) DO UPDATE SET hidden_at = excluded.hidden_at
            """) { stmt in
                bind(stmt, 1, key)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            }
            try writeSourceHidden(trimmed, hidden: true)
            try execBind("DELETE FROM visible_podcast_episode_overrides WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
            try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                bind(stmt, 1, trimmed)
            }
        } else {
            try execBind("DELETE FROM hidden_podcast_episodes WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
            try writeSourceHidden(trimmed, hidden: false)
            try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: trimmed)
        }
        if hidden {
            try markRecordChanged(entity: .hiddenSource, logicalKey: trimmed)
        } else {
            try markRecordDeleted(entity: .hiddenSource, logicalKey: trimmed)
        }
        try markRecordChanged(entity: .source, logicalKey: trimmed)
    }

    func setSourceHidden(_ sourceID: String, hidden: Bool) throws {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try writeSourceHidden(trimmed, hidden: hidden)
        if isPodcastSource(trimmed) {
            let key = try personalStateSourceKey(trimmed)
            if hidden {
                try execBind("""
                    INSERT INTO hidden_podcast_episodes (source_id, hidden_at)
                    VALUES (?, ?)
                    ON CONFLICT(source_id) DO UPDATE SET hidden_at = excluded.hidden_at
                """) { stmt in
                    bind(stmt, 1, key)
                    sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
                }
                try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                    bind(stmt, 1, trimmed)
                }
            } else {
                try execBind("DELETE FROM hidden_podcast_episodes WHERE source_id = ?") { stmt in
                    bind(stmt, 1, key)
                }
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: trimmed)
            }
        }
        if hidden {
            try markRecordChanged(entity: .hiddenSource, logicalKey: trimmed)
        } else {
            try markRecordDeleted(entity: .hiddenSource, logicalKey: trimmed)
        }
        try markRecordChanged(entity: .source, logicalKey: trimmed)
    }

    func isPodcastSource(_ sourceID: String) -> Bool {
        var result = false
        try? queryBind("SELECT 1 FROM sources WHERE id = ? AND source_type = 'podcast' LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { _ in
            result = true
        }
        return result
    }

    func loadVisiblePodcastEpisodeOverrideIDs() throws -> Set<String> {
        var ids = Set<String>()
        try query("""
            SELECT s.id FROM visible_podcast_episode_overrides v JOIN sources s ON v.source_id IN (s.id, s.wire_key)
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                ids.insert(sourceID)
            }
        }
        return ids
    }

    func loadVisiblePodcastEpisodeOverrideIDs(forShow showName: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT p.source_id
            FROM visible_podcast_episode_overrides v
            JOIN sources s ON v.source_id IN (s.id, s.wire_key)
            JOIN podcasts p ON p.source_id = s.id
            WHERE p.domain = ? OR p.show_name = ?
        """, bind: { stmt in
            bind(stmt, 1, showName)
            bind(stmt, 2, showName)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                ids.append(sourceID)
            }
        }
        return ids
    }

    func podcastSourceIDs(forShow showName: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT source_id FROM podcasts
            WHERE domain = ? OR show_name = ?
        """, bind: { stmt in
            bind(stmt, 1, showName)
            bind(stmt, 2, showName)
        }) { stmt in
            if let sourceID = string(stmt, 0) { ids.append(sourceID) }
        }
        return ids
    }

    func deleteVisiblePodcastEpisodeOverrides(forShow showName: String) throws {
        try execBind("""
            DELETE FROM visible_podcast_episode_overrides
            WHERE source_id IN (
                SELECT s.id FROM podcasts p JOIN sources s ON s.id = p.source_id WHERE p.domain = ? OR p.show_name = ?
                UNION
                SELECT s.wire_key FROM podcasts p JOIN sources s ON s.id = p.source_id WHERE p.domain = ? OR p.show_name = ?
            )
        """) { stmt in
            bind(stmt, 1, showName)
            bind(stmt, 2, showName)
            bind(stmt, 3, showName)
            bind(stmt, 4, showName)
        }
    }

    func isPodcastEpisodeVisibleOverride(_ sourceID: String) throws -> Bool {
        var found = false
        let key = try personalStateSourceKey(sourceID)
        try queryBind("SELECT 1 FROM visible_podcast_episode_overrides WHERE source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, key)
        }) { _ in
            found = true
        }
        return found
    }

    func setPodcastEpisodeVisibleOverride(_ sourceID: String, visible: Bool) throws {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = try personalStateSourceKey(trimmed)

        if visible {
            try execBind("""
                INSERT INTO visible_podcast_episode_overrides (source_id, visible_at)
                VALUES (?, ?)
                ON CONFLICT(source_id) DO UPDATE SET visible_at = excluded.visible_at
            """) { stmt in
                bind(stmt, 1, key)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            }
            try execBind("DELETE FROM hidden_podcast_episodes WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
            try writeSourceHidden(trimmed, hidden: false)
            try markRecordDeleted(entity: .hiddenSource, logicalKey: trimmed)
        } else {
            try execBind("DELETE FROM visible_podcast_episode_overrides WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
        }
        try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, trimmed)
        }
        try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: trimmed)
        try markRecordChanged(entity: .source, logicalKey: trimmed)
    }

    func loadVisibleYouTubeVideoOverrideIDs() throws -> Set<String> {
        var ids = Set<String>()
        try query("""
            SELECT s.id FROM visible_youtube_video_overrides o JOIN sources s ON o.source_id IN (s.id, s.wire_key)
        """) { stmt in
            if let sourceID = string(stmt, 0) { ids.insert(sourceID) }
        }
        return ids
    }

    func loadVisibleYouTubeVideoOverrideIDs(forChannel channelName: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT v.source_id
            FROM visible_youtube_video_overrides o
            JOIN sources s ON o.source_id IN (s.id, s.wire_key)
            JOIN videos v ON v.source_id = s.id
            WHERE v.domain = ? COLLATE NOCASE
        """, bind: { stmt in
            bind(stmt, 1, channelName)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) { ids.append(sourceID) }
        }
        return ids
    }

    func deleteVisibleYouTubeVideoOverrides(forChannel channelName: String) throws {
        try execBind("""
            DELETE FROM visible_youtube_video_overrides
            WHERE source_id IN (
                SELECT s.id FROM videos v JOIN sources s ON s.id = v.source_id WHERE v.domain = ?1 COLLATE NOCASE
                UNION
                SELECT s.wire_key FROM videos v JOIN sources s ON s.id = v.source_id WHERE v.domain = ?1 COLLATE NOCASE
            )
        """) { stmt in
            bind(stmt, 1, channelName)
        }
    }

    func isYouTubeVideoVisibleOverride(_ sourceID: String) throws -> Bool {
        var found = false
        let key = try personalStateSourceKey(sourceID)
        try queryBind("SELECT 1 FROM visible_youtube_video_overrides WHERE source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, key)
        }) { _ in found = true }
        return found
    }

    func setYouTubeVideoVisibleOverride(_ sourceID: String, visible: Bool) throws {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = try personalStateSourceKey(trimmed)

        if visible {
            try execBind("""
                INSERT INTO visible_youtube_video_overrides (source_id, visible_at)
                VALUES (?, ?)
                ON CONFLICT(source_id) DO UPDATE SET visible_at = excluded.visible_at
            """) { stmt in
                bind(stmt, 1, key)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            }
            try writeSourceHidden(trimmed, hidden: false)
            try markRecordDeleted(entity: .hiddenSource, logicalKey: trimmed)
        } else {
            try execBind("DELETE FROM visible_youtube_video_overrides WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
        }
        try markRecordChanged(entity: .source, logicalKey: trimmed)
    }

    func updateSourceType(_ sourceId: String, to newType: String) throws {
        guard let type = StudioSourceType(rawValue: newType),
              var article = try loadSourceForSync(sourceId) else { return }
        article.sourceType = type
        if type == .paper {
            article.prepareForPaperMetadataExtraction()
        }
        if article.sourceType == .paper, let journal = article.journal?.trimmingCharacters(in: .whitespacesAndNewlines), journal.isEmpty {
            article.journal = nil
        }
        try saveSource(article)
    }

    func sourceIds() throws -> Set<String> {
        var ids = Set<String>()
        try query("SELECT id FROM sources") { stmt in
            if let id = string(stmt, 0) {
                ids.insert(id)
            }
        }
        return ids
    }
}
