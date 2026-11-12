// KnowledgeStore: the source column lists and the loaders of sources and their content.
import Foundation
import SQLite3

extension KnowledgeStore {

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

    /// The X posts in the library whose saved capture holds only the opening
    /// of a post, newest first: the ones `fillCutXPosts` reads the rest of.
    func xPostSourceIDsSavedCutShort() throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT x.source_id FROM x_posts x
            JOIN sources s ON s.id = x.source_id
            JOIN source_content c ON c.source_id = x.source_id
            WHERE s.status = 'active' AND instr(c.content, ?) > 0
            ORDER BY s.date_added DESC
            """, bind: { stmt in
            self.bind(stmt, 1, XPostThreadService.cutPostNotePrefix)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
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

}
