import Foundation
import SQLite3

/// What `unarchiveSourceRestoringContent` did, for the sentence the caller
/// shows or returns.
struct SourceUnarchiveOutcome: Equatable {
    let title: String
    /// The text archiving removed was rebuilt from the source's local file.
    let rebuiltContent: Bool
}

/// A `sources` row named by id, at the resolution a list that only needs to
/// say what a source is called and whether it is archived asks for.
struct SourceRowSummary: Equatable {
    let id: String
    /// The stored title, or the URL when no title was ever recorded.
    let title: String
    let status: SourceStatus
    /// What kind of source it is, so a row can name it for what it is — a
    /// meeting's text is a transcript, not a reading.
    let type: StudioSourceType
}

/// One batch of the word count repair (`drainSourceWordCountRepairBatch`):
/// the counts it wrote, by source id, and the last id it read, which the next
/// batch starts after. A nil `lastSourceID` means nothing was left to read.
struct SourceWordCountRepairBatch: Equatable, Sendable {
    var counts: [String: Int]
    var lastSourceID: String?
}

/// The one library the Studio lists, whichever team is open: the learner's own
/// sources and every team's, a team copy folded into the row it copies
/// (`loadLibrarySources()`). No source is a team's alone (product owner,
/// 2026-11-07: "all the papers should just be in my library and findable").
struct LibrarySourceList {
    /// Every listed row, newest first.
    var sources: [StudioArticle]
    /// Team copy id → the id of the listed row at the same address.
    var teamCopyAliases: [String: String]

    /// Folds `team` into `own` by address: a team row at an address an own
    /// row, or an earlier team row, holds becomes an alias of that row; every
    /// other team row is listed. Both inputs are newest first, and so is the
    /// result.
    init(own: [StudioArticle], team: [StudioArticle]) {
        var listedIDsByAddress: [String: String] = [:]
        for article in own {
            let key = Self.addressKey(article)
            if listedIDsByAddress[key] == nil { listedIDsByAddress[key] = article.id }
        }
        var aliases: [String: String] = [:]
        var teamListed: [StudioArticle] = []
        for article in team {
            let key = Self.addressKey(article)
            if let listedID = listedIDsByAddress[key] {
                aliases[article.id] = listedID
            } else {
                listedIDsByAddress[key] = article.id
                teamListed.append(article)
            }
        }
        self.sources = teamListed.isEmpty
            ? own
            : (own + teamListed).sorted { $0.dateAdded > $1.dateAdded }
        self.teamCopyAliases = aliases
    }

    /// The address a team copy shares with its original: the stored
    /// normalized URL the copy carries over, or the URL normalized the way
    /// `TeamContentIdentity.sourceID` keys it. By address and never by id,
    /// because a copy whose address was rewritten after it was made keeps
    /// the id it was made under (`teamSourceCopyID`).
    private static func addressKey(_ article: StudioArticle) -> String {
        if let normalized = article.normalizedURL, !normalized.isEmpty { return normalized }
        return URLNormalizer.normalize(article.url)
    }
}

extension KnowledgeStore {

    // MARK: - Targeted Source CRUD

    /// Load all active (non-archived) sources, excluding content for performance.
    ///
    /// One library at a time: nil is the learner's own library, a team id is
    /// that team's. A team's copies are separate rows and never appear beside
    /// the learner's own, so a paper shared with two teams is still one row in
    /// My Library.
    func loadActiveSources(teamID: String? = nil) throws -> [StudioArticle] {
        let scope = teamID == nil ? "sp.team_id IS NULL" : "sp.team_id = ?"
        let sql = "SELECT \(Self.sourceColumns) \(Self.sourceJoins) WHERE sp.status = 'active' AND \(scope) ORDER BY sp.date_added DESC"
        var articles: [StudioArticle] = []
        try queryBind(sql, bind: { stmt in
            if let teamID { bind(stmt, 1, teamID) }
        }) { stmt in
            if let article = readSourceRow(stmt) {
                articles.append(article)
            }
        }
        return articles
    }

    /// The sources the Studio lists, the same whichever library is open: every
    /// one of the learner's own and every row of each team they belong to. A
    /// team copy of a listed source is that source seen once, so it is left out
    /// of the list and named in `teamCopyAliases`, which resolves the copy's id
    /// — the one a team Notebook, team Doc card or team chat snapshot names —
    /// to the listed row. A team the learner left (no `teams` row) lists nothing.
    func loadLibrarySources() throws -> LibrarySourceList {
        let sql = """
            SELECT \(Self.sourceColumns) \(Self.sourceJoins)
            WHERE sp.status = 'active'
              AND (sp.team_id IS NULL OR sp.team_id IN (SELECT id FROM teams))
            ORDER BY sp.date_added DESC
            """
        var own: [StudioArticle] = []
        var team: [StudioArticle] = []
        try queryBind(sql, bind: { _ in }) { stmt in
            guard let article = readSourceRow(stmt) else { return }
            if article.teamID == nil { own.append(article) } else { team.append(article) }
        }
        return LibrarySourceList(own: own, team: team)
    }

    /// Targeted source metadata read that never materializes source content.
    /// Relationship lookups use this instead of scanning the library or loading a
    /// paper's potentially large text just to validate its identity and type.
    func loadSourceWithoutContent(_ sourceID: String) throws -> StudioArticle? {
        var article: StudioArticle?
        let sql = "SELECT \(Self.sourceColumns) \(Self.sourceJoins) WHERE sp.id = ? LIMIT 1"
        try queryBind(sql, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            article = readSourceRow(stmt)
        }
        return article
    }

    /// Check if a source with this normalized URL already exists in My Library.
    /// Returns the ID and status if found. A team's copy of the same paper is
    /// not a match: nothing belongs to a team's library alone, so an import or
    /// a Notebook's add still makes the learner's own row (the team copy has a
    /// team-scoped id, so the two never collide).
    func sourceExistsByNormalizedURL(_ normalizedURL: String) -> (id: String, status: SourceStatus)? {
        var result: (id: String, status: SourceStatus)?
        try? queryBind("SELECT id, status FROM source_projection WHERE normalized_url = ? AND team_id IS NULL LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, normalizedURL)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                let statusStr = self.string(stmt, 1)
                let status = statusStr.flatMap { SourceStatus(rawValue: $0) } ?? .active
                result = (id: id, status: status)
            }
        }
        return result
    }

    /// Active source counts per plugin label, for the Plugins place's
    /// "Build Your Own" list.
    func activePluginSourceCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try query("""
            SELECT connector_label, COUNT(*) FROM sources
            WHERE connector_label IS NOT NULL AND status = 'active'
            GROUP BY connector_label
        """) { stmt in
            if let label = self.string(stmt, 0) {
                counts[label] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        return counts
    }

    /// Active sources a user-built plugin added, newest first — keyed on the
    /// provenance label stamped at ingest. Used for bulk plugin cleanup.
    func activeSourceIDs(withPluginLabel label: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT id FROM sources
            WHERE connector_label = ? AND status = 'active'
            ORDER BY date_added DESC
        """, bind: { stmt in
            self.bind(stmt, 1, label)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Check if a book chapter whose file is this persisted local file path already exists. Only a
    /// chapter that is a file of its own can be found by its file: every chapter of a book kept as
    /// one file has the book's.
    func sourceExistsByBookLocalFilePath(_ localFilePath: String) -> (id: String, status: SourceStatus)? {
        let persistedPath = StorageService.relativeSourcePath(localFilePath)
        var result: (id: String, status: SourceStatus)?
        try? queryBind("""
            SELECT s.id, s.status
            FROM book_sources bs
            JOIN sources s ON s.id = bs.source_id
            WHERE bs.local_file_path = ? AND bs.page_start IS NULL
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, persistedPath)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                let statusStr = self.string(stmt, 1)
                let status = statusStr.flatMap { SourceStatus(rawValue: $0) } ?? .active
                result = (id: id, status: status)
            }
        }
        return result
    }

    /// Check if a source with this persisted URL already exists in My Library.
    /// Returns the ID and status if found.
    func sourceExistsByURL(_ url: String) -> (id: String, status: SourceStatus)? {
        let persistedURL = StorageService.relativeSourcePath(url)
        var result: (id: String, status: SourceStatus)?
        try? queryBind("SELECT id, status FROM source_projection WHERE url = ? AND team_id IS NULL LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, persistedURL)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                let statusStr = self.string(stmt, 1)
                let status = statusStr.flatMap { SourceStatus(rawValue: $0) } ?? .active
                result = (id: id, status: status)
            }
        }
        if result == nil, let trackID = Self.extractTrackIdFromURL(url) {
            result = sourceExistsByPodcastTrackID(trackID)
        }
        return result
    }

    /// Check if a podcast episode already exists under its canonical URL.
    func sourceExistsByPodcastTrackID(_ trackID: Int64) -> (id: String, status: SourceStatus)? {
        let canonicalURL = "apple-podcast://episode/\(trackID)"
        var result: (id: String, status: SourceStatus)?
        try? queryBind("""
            SELECT s.id, s.status
            FROM podcasts p
            JOIN sources s ON s.id = p.source_id
            WHERE (p.url = ?
               OR p.normalized_url = ?)
              AND s.team_id IS NULL
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, canonicalURL)
            self.bind(stmt, 2, canonicalURL)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                let statusStr = self.string(stmt, 1)
                let status = statusStr.flatMap { SourceStatus(rawValue: $0) } ?? .active
                result = (id: id, status: status)
            }
        }
        return result
    }

    /// Private RSS episodes can get a new Apple-local UUID for the same feed item.
    /// Match them by stable visible metadata when no public track ID is available.
    func sourceExistsByPodcastShowAndTitle(_ article: StudioArticle) -> (id: String, status: SourceStatus)? {
        var result: (id: String, status: SourceStatus)?
        try? queryBind("""
            SELECT s.id, s.status
            FROM podcasts p
            JOIN sources s ON s.id = p.source_id
            WHERE s.source_type = 'podcast'
              AND s.team_id IS NULL
              AND p.title = ?
              AND (p.domain = ? OR p.show_name = ?)
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, article.title)
            self.bind(stmt, 2, article.domain)
            self.bind(stmt, 3, article.domain)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                let statusStr = self.string(stmt, 1)
                let status = statusStr.flatMap { SourceStatus(rawValue: $0) } ?? .active
                result = (id: id, status: status)
            }
        }
        return result
    }

    /// The active source a web reference points at, if the library holds it.
    ///
    /// A reference in a doc is an ordinary web link, so it is matched the way the
    /// importers dedup one: by the persisted URL, by the normalized URL, and for
    /// a paper by the DOI the link carries — including the published DOI recorded
    /// for a saved preprint, which is the journal version arriving second — or
    /// by its arXiv identifier, so the `abs` and `pdf` spellings of one paper are
    /// one paper — or, for a Nature paper's PDF hosted off nature.com, by the
    /// article id the file is named after, matched against the saved DOI's
    /// suffix. Only an active source counts: an archived or removed one is not
    /// in the library to the reader, and Add to Sources is how it comes back.
    ///
    /// One library at a time, as everywhere else: nil is the learner's own
    /// library, a team id is that team's copies. A team Doc's cards ask the
    /// team, so a paper only one member holds privately is not "in the library"
    /// to the team, and Add to Sources is what puts it there for everyone.
    func activeSourceID(forReferenceURL rawURL: String, teamID: String? = nil) -> String? {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        // A source card names its source by id — `foreverlm://source/<id>`, the
        // line a dropped source writes — so it is answered by id, the way a
        // chat citation is: the id itself, or a prefix only one source has.
        if let token = Self.sourceAddressToken(url) {
            return activeSourceID(matchingID: token, teamID: teamID)
        }
        if let id = activeSourceID(matchingAddress: url, teamID: teamID) { return id }
        let doi = PaperService.extractDOI(from: url)
        if let doi, let id = activePaperID(matchingDOI: doi, teamID: teamID) {
            return id
        }
        // arXiv papers carry two names for one identity: the arXiv identifier in
        // their address and the DataCite DOI `10.48550/arXiv.<id>` that a PDF
        // import records. A reference may use either, so both are tried.
        if let arxivID = PaperService.extractArxivID(from: url) ?? doi.flatMap(Self.arxivID(fromDOI:)) {
            if let id = activePaperID(matchingDOI: "10.48550/arxiv.\(arxivID)", teamID: teamID) { return id }
            if let id = activePaperID(matchingArxivID: arxivID, teamID: teamID) { return id }
        }
        // A company's own copy of its Nature paper — insitro.com hosting
        // `s41467-025-66778-6.pdf` — names no DOI, but the file is named after
        // the article id, which is the DOI's suffix. The prefix is not guessed:
        // Springer and BMC issue ids of the same shape under other prefixes, so
        // the saved DOI is matched on its suffix.
        if doi == nil, let articleID = PaperService.extractSpringerNatureArticleID(from: url),
           let id = activePaperID(matchingDOISuffix: articleID, teamID: teamID) {
            return id
        }
        return nil
    }

    /// The `WHERE` fragment that keeps a `source_projection` query to one
    /// library: the learner's own rows carry no team, a team's copies carry
    /// its id. `parameter` is the `?N` slot the team id binds to.
    private static func libraryScopeSQL(teamID: String?, parameter: Int) -> String {
        teamID == nil ? "team_id IS NULL" : "team_id = ?\(parameter)"
    }

    /// The source id a private source address names — the stored
    /// `foreverlm://source/<id>` spelling or the editor's
    /// `https://foreverlm.invalid/source/<id>` stand-in — with any query or
    /// fragment dropped. Nil for every other address.
    static func sourceAddressToken(_ address: String) -> String? {
        guard let url = URL(string: address) else { return nil }
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let rawToken: String?
        if scheme == "foreverlm", host == "source" {
            rawToken = url.pathComponents.first { $0 != "/" }
        } else if scheme == "https", host == "foreverlm.invalid" {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.first?.lowercased() == "source", components.count >= 2 else { return nil }
            rawToken = components[1]
        } else {
            return nil
        }
        guard let token = rawToken?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// The active source with this id in one library — or, when no source has
    /// exactly this id, the one source whose id begins with it. A chat cites a
    /// source by the shortest prefix that names it, so a card written from a
    /// citation may carry one; a prefix that fits two sources names neither.
    private func activeSourceID(matchingID token: String, teamID: String?) -> String? {
        var exact: String?
        try? queryBind("""
            SELECT id FROM source_projection
            WHERE status = 'active' AND id = ?1
              AND \(Self.libraryScopeSQL(teamID: teamID, parameter: 2))
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, token)
            if let teamID { self.bind(stmt, 2, teamID) }
        }) { stmt in
            exact = self.string(stmt, 0)
        }
        if let exact { return exact }
        guard token.count >= 8 else { return nil }
        var prefixed: [String] = []
        try? queryBind("""
            SELECT id FROM source_projection
            WHERE status = 'active' AND substr(id, 1, length(?1)) = ?1
              AND \(Self.libraryScopeSQL(teamID: teamID, parameter: 2))
            LIMIT 2
        """, bind: { stmt in
            self.bind(stmt, 1, token)
            if let teamID { self.bind(stmt, 2, teamID) }
        }) { stmt in
            if let id = self.string(stmt, 0) { prefixed.append(id) }
        }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// The active source saved under this address — as persisted, or under
    /// its normalized form — in one library.
    func activeSourceID(matchingAddress url: String, teamID: String?) -> String? {
        let persistedURL = StorageService.relativeSourcePath(url)
        let normalized = URLNormalizer.normalize(url)
        var result: String?
        try? queryBind("""
            SELECT id FROM source_projection
            WHERE status = 'active'
              AND (url = ?1 OR (?2 != '' AND normalized_url = ?2))
              AND \(Self.libraryScopeSQL(teamID: teamID, parameter: 3))
            ORDER BY is_hidden ASC
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, persistedURL)
            self.bind(stmt, 2, normalized)
            if let teamID { self.bind(stmt, 3, teamID) }
        }) { stmt in
            result = self.string(stmt, 0)
        }
        // A podcast episode is saved under Apple's track id, so its address may
        // differ from the one a reference uses; the id is the identity.
        if result == nil, let trackID = Self.extractTrackIdFromURL(url),
           let match = sourceExistsByPodcastTrackID(trackID), match.status == .active,
           sourceTeamID(match.id) == teamID {
            result = match.id
        }
        return result
    }

    /// The library a source row belongs to: nil for My Library, else the team.
    private func sourceTeamID(_ sourceID: String) -> String? {
        var teamID: String?
        try? queryBind("SELECT team_id FROM source_projection WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            teamID = self.string(stmt, 0)
        }
        return teamID
    }

    /// The arXiv identifier inside arXiv's own DataCite DOI, `10.48550/arXiv.2401.12345`.
    static func arxivID(fromDOI doi: String) -> String? {
        let pattern = #"^10\.48550/arxiv\.(\d{4}\.\d{4,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: doi, range: NSRange(doi.startIndex..., in: doi)),
              let range = Range(match.range(at: 1), in: doi) else { return nil }
        return String(doi[range])
    }

    /// An active paper whose DOI or published DOI is this one, a preprint's
    /// version aside (`PaperService.unversionedDOI`): `10.1101/2024.11.04.615786v3`
    /// and the unversioned DOI are the same preprint, whichever side carries the
    /// `v3`, while `10.1093/nar/gkv1344` and `10.1093/nar/gkv1157` are two papers.
    private func activePaperID(matchingDOI doi: String, teamID: String?) -> String? {
        let key = PaperService.unversionedDOI(doi)
        guard !key.isEmpty else { return nil }
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        // Every DOI that starts with the key is a candidate (a version follows the
        // key directly, or after a `.` or `/`); the rule itself decides which match.
        var result: String?
        try? queryBind("""
            SELECT id, doi, published_doi FROM source_projection
            WHERE status = 'active'
              AND (LOWER(doi) LIKE ?1 ESCAPE '\\' OR LOWER(published_doi) LIKE ?1 ESCAPE '\\')
              AND \(Self.libraryScopeSQL(teamID: teamID, parameter: 2))
            ORDER BY is_hidden ASC
        """, bind: { stmt in
            self.bind(stmt, 1, escaped + "%")
            if let teamID { self.bind(stmt, 2, teamID) }
        }) { stmt in
            guard result == nil else { return }
            let candidates = [self.string(stmt, 1), self.string(stmt, 2)].compactMap { $0 }
            if candidates.contains(where: { PaperService.unversionedDOI($0) == key }) {
                result = self.string(stmt, 0)
            }
        }
        return result
    }

    /// An active paper whose DOI or published DOI ends in `/<articleID>` — a
    /// Springer Nature article id, unique across the publisher's journals, so
    /// the suffix names one paper whichever prefix registered it.
    private func activePaperID(matchingDOISuffix articleID: String, teamID: String?) -> String? {
        let key = articleID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var result: String?
        try? queryBind("""
            SELECT id FROM source_projection
            WHERE status = 'active'
              AND (LOWER(doi) LIKE ?1 ESCAPE '\\' OR LOWER(published_doi) LIKE ?1 ESCAPE '\\')
              AND \(Self.libraryScopeSQL(teamID: teamID, parameter: 2))
            ORDER BY is_hidden ASC
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, "%/" + escaped)
            if let teamID { self.bind(stmt, 2, teamID) }
        }) { stmt in
            result = self.string(stmt, 0)
        }
        return result
    }

    /// An active paper saved from arXiv under this identifier, whichever arXiv
    /// address — abstract page or PDF, with or without a version — it was saved
    /// from. Candidates come from a LIKE over the address and are confirmed by
    /// extracting the identifier again, so `1706.0376` never claims `1706.03762`.
    private func activePaperID(matchingArxivID arxivID: String, teamID: String?) -> String? {
        var result: String?
        try? queryBind("""
            SELECT id, url FROM source_projection
            WHERE status = 'active' AND source_type = ?1
              AND (url LIKE ?2 OR normalized_url LIKE ?2)
              AND \(Self.libraryScopeSQL(teamID: teamID, parameter: 3))
            ORDER BY is_hidden ASC
        """, bind: { stmt in
            self.bind(stmt, 1, StudioSourceType.paper.rawValue)
            self.bind(stmt, 2, "%arxiv.org/%/" + arxivID + "%")
            if let teamID { self.bind(stmt, 3, teamID) }
        }) { stmt in
            guard result == nil, let id = self.string(stmt, 0), let url = self.string(stmt, 1) else { return }
            if PaperService.extractArxivID(from: url) == arxivID { result = id }
        }
        return result
    }

    /// Check if a paper with this DOI already exists (case-insensitive).
    func paperExistsByDOI(_ doi: String) -> Bool {
        var found = false
        try? queryBind("SELECT 1 FROM papers p JOIN sources s ON s.id = p.source_id WHERE LOWER(p.doi) = ? AND s.team_id IS NULL LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, doi.lowercased())
        }) { _ in
            found = true
        }
        return found
    }

    /// Fast prefilter for discovery refreshes. Avoids querying source_projection once
    /// per browser Reading List item before heavier classification/enrichment work.
    func newSourceCandidates(from articles: [StudioArticle]) throws -> [StudioArticle] {
        guard !articles.isEmpty else { return [] }

        let candidates = articles.map { article in
            (
                article: article,
                persistedURL: StorageService.relativeSourcePath(article.url),
                normalizedURL: URLNormalizer.normalize(article.url)
            )
        }

        let persistedURLs = Set(candidates.map { $0.persistedURL })
        let normalizedURLs = Set(candidates.map { $0.normalizedURL })
        var existingPersistedURLs = Set<String>()
        var existingNormalizedURLs = Set<String>()

        let sourceTables = [
            "articles",
            "papers",
            "podcasts",
            "book_sources",
            "course_sources",
            "meeting_sources",
            "videos",
            "x_posts"
        ]

        for table in sourceTables {
            try collectExistingValues(
                table: table,
                column: "url",
                values: Array(persistedURLs),
                into: &existingPersistedURLs
            )
            try collectExistingValues(
                table: table,
                column: "normalized_url",
                values: Array(normalizedURLs),
                into: &existingNormalizedURLs
            )
        }

        var dismissedPersistedURLs = Set<String>()
        var dismissedNormalizedURLs = Set<String>()
        try query("SELECT url FROM dismissed_sources") { stmt in
            guard let url = self.string(stmt, 0) else { return }
            dismissedPersistedURLs.insert(url)
            dismissedNormalizedURLs.insert(URLNormalizer.normalize(url))
        }

        return candidates.compactMap { candidate in
            if existingPersistedURLs.contains(candidate.persistedURL) { return nil }
            if existingNormalizedURLs.contains(candidate.normalizedURL) { return nil }
            if dismissedPersistedURLs.contains(candidate.persistedURL) { return nil }
            if dismissedPersistedURLs.contains(candidate.normalizedURL) { return nil }
            if dismissedNormalizedURLs.contains(candidate.normalizedURL) { return nil }
            return candidate.article
        }
    }

    func collectExistingValues(
        table: String,
        column: String,
        values: [String],
        into result: inout Set<String>
    ) throws {
        guard !values.isEmpty else { return }
        let chunkSize = 500
        var start = 0
        while start < values.count {
            let end = min(start + chunkSize, values.count)
            let chunk = Array(values[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try queryBind("SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))", bind: { stmt in
                for (index, value) in chunk.enumerated() {
                    self.bind(stmt, index + 1, value)
                }
            }) { stmt in
                if let value = self.string(stmt, 0) {
                    result.insert(value)
                }
            }
            start = end
        }
    }

    /// Insert a source if its normalized URL doesn't exist. Archived sources are left alone
    /// (the user explicitly removed them). Returns true if inserted, false if skipped
    /// because the source already exists or was dismissed. Throws if the underlying
    /// write fails — a failed insert must not be reported as success.
    @discardableResult
    func insertSourceIfNew(_ article: inout StudioArticle) throws -> Bool {
        let normalizedURL = URLNormalizer.normalize(article.url)
        article.normalizedURL = normalizedURL
        article.title = Self.persistedTitle(for: article)

        // User explicitly removed this source — don't re-add it
        if isSourceDismissed(url: article.url) { return false }

        // Generation 2 looks every key the import knows up before it mints (schema v2 §4.2): a hit is
        // that source, which gains the new keys, never a second one, and the caller's article becomes it.
        // Generation 1 mints as it always has.
        var importKeys: [String] = []
        importKeys = workKeys(for: article, hashingFile: true)
        if let existingID = try sourceID(forWorkKeys: importKeys, teamID: article.teamID) {
            try addWorkKeys(importKeys, to: existingID)
            if let existing = try loadSourceWithoutContent(existingID) { article = existing }
            return false
        }

        if sourceExistsByNormalizedURL(normalizedURL) != nil || sourceExistsByURL(article.url) != nil {
            // Already exists (active or archived) — skip
            return false
        }
        if article.sourceType == .podcast,
           Self.extractTrackIdFromURL(article.url) == nil,
           sourceExistsByPodcastShowAndTitle(article) != nil {
            return false
        }

        // Papers: check by DOI to catch duplicates across URL forms and local PDFs
        if article.sourceType == .paper, let doi = article.doi, !doi.isEmpty {
            if paperExistsByDOI(doi) { return false }
        }

        article.status = .active
        article.archivedAt = nil
        try saveSource(article)
        // The keys only an import knows (a local original's `file:` hash) join the ones every save keeps.
        try addWorkKeys(importKeys, to: article.id)
        return true
    }

    /// Archive a source in a single transaction: set status='archived',
    /// archived_at=now, and clear its text, derived indexes, and fetch state
    /// through `clearSourceText`.
    func archiveSource(_ sourceId: String) throws {
        let now = Self.iso8601Formatter.string(from: Date())
        var affectedGoalIds: [String] = []
        try exec("BEGIN IMMEDIATE")
        do {
            try queryBind("SELECT DISTINCT goal_id FROM learning_goal_items WHERE source_id = ?", bind: { stmt in
                self.bind(stmt, 1, sourceId)
            }) { stmt in
                if let id = self.string(stmt, 0) {
                    affectedGoalIds.append(id)
                }
            }
            try execBind("DELETE FROM learning_goal_items WHERE source_id = ?") { stmt in
                self.bind(stmt, 1, sourceId)
            }
            try execBind("UPDATE sources SET status = ?, archived_at = ? WHERE id = ?") { stmt in
                self.bind(stmt, 1, SourceStatus.archived.rawValue)
                self.bind(stmt, 2, now)
                self.bind(stmt, 3, sourceId)
            }
            // Archiving takes the source's text with it, so the row must stop
            // claiming it has any — otherwise reviving it later brings back a
            // source that reports `ready` with nothing behind it.
            try clearSourceText(sourceId)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Clear derived text and embeddings for a source without archiving or deleting it.
    func clearSourceDerivedData(_ sourceId: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try clearSourceText(sourceId)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Per-type tables carrying `word_count`. A source's row lives in exactly
    /// one of them, so clearing the count is a fan-out rather than a lookup.
    private static let sourceWordCountTables = [
        "articles", "papers", "podcasts", "videos", "x_posts",
        "book_sources", "course_sources", "meeting_sources"
    ]

    /// The words in a source's stored text, as the store counts them: runs of
    /// anything but whitespace, newlines included. `word_count` is how the chat
    /// catalog and `filter_sources` tell a source with text from one without.
    static func storedWordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Write the count of the text just stored into whichever per-type table
    /// holds the source. A writer of `source_content` knows the text, so it
    /// writes the count with it; a count left for the caller to remember is
    /// what leaves podcast transcripts reading "no text yet".
    func writeStoredWordCount(sourceID: String, text: String) throws {
        let count = Int64(Self.storedWordCount(of: text))
        for table in Self.sourceWordCountTables {
            try execBind("UPDATE \(table) SET word_count = ? WHERE source_id = ? AND word_count IS NOT ?") { stmt in
                sqlite3_bind_int64(stmt, 1, count)
                self.bind(stmt, 2, sourceID)
                sqlite3_bind_int64(stmt, 3, count)
            }
        }
    }

    /// One bounded batch of the word count repair: up to `limit` sources of the
    /// learner's own library, after `cursor` in id order, whose text is stored
    /// but whose count is missing or zero, each counted from that text.
    ///
    /// Not a migration and not a queue: the candidates are their own predicate
    /// (text stored, count missing), which a scan answers in milliseconds on
    /// the largest library, and a counted source leaves it. So the pass is
    /// idempotent, resumable after a quit, and a no-op once nothing is missing;
    /// run again at activation it also counts text another device published
    /// without a count. The cursor walks each run past a text with no words,
    /// whose count stays zero. A team's copy is left to the library it was
    /// shared from, as the soft hyphen repair leaves it: the count is a field
    /// of the team zone's record, which a read-only member cannot write.
    func drainSourceWordCountRepairBatch(after cursor: String?, limit: Int) throws -> SourceWordCountRepairBatch {
        let candidateSQL = Self.sourceWordCountTables.map { table in
            """
            SELECT '\(table)' AS subtype_table, t.source_id AS source_id
            FROM \(table) t
            JOIN sources s ON s.id = t.source_id
            JOIN source_content sc ON sc.source_id = t.source_id
            WHERE COALESCE(t.word_count, 0) = 0
              AND s.team_id IS NULL
              AND t.source_id > ?1
            """
        }.joined(separator: "\nUNION ALL\n") + "\nORDER BY source_id\nLIMIT ?2"

        try exec("BEGIN IMMEDIATE")
        do {
            var candidates: [(table: String, sourceID: String)] = []
            try query(candidateSQL, [.text(cursor ?? ""), .integer(Int64(max(1, min(limit, 200))))]) { row in
                guard let table = row.text(0), let sourceID = row.text(1) else { return }
                candidates.append((table, sourceID))
            }
            var batch = SourceWordCountRepairBatch(counts: [:], lastSourceID: candidates.last?.sourceID)
            for candidate in candidates {
                guard let text = try scalarText(
                    "SELECT content FROM source_content WHERE source_id = ?",
                    [.text(candidate.sourceID)]
                ) else { continue }
                let count = Self.storedWordCount(of: text)
                guard count > 0 else { continue }
                try execute(
                    "UPDATE \(candidate.table) SET word_count = ? WHERE source_id = ?",
                    [.integer(Int64(count)), .text(candidate.sourceID)]
                )
                batch.counts[candidate.sourceID] = count
            }
            try exec("COMMIT")
            return batch
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Remove a source's text and everything derived from it, and put the
    /// source's own row back in step with that.
    ///
    /// **This is the only place source text is deleted**, deliberately. Both
    /// callers that drop the content while leaving `state = 'ready'`
    /// and the per-type `word_count` untouched produced 57
    /// videos advertising a nine-thousand-word transcript they no longer had.
    /// `ready` means "content fetched, available" — so nothing requeued them,
    /// nothing flagged them, and every consumer downstream believed the claim.
    /// A source with no text is invisible as a problem precisely because it
    /// reports success.
    ///
    /// Keeping the state reset inside the delete is the point: a future path
    /// that removes text gets the reset for free instead of having to remember
    /// it. `archiveSource` and `clearSourceDerivedData` share it, so the MCP
    /// `clear_source_derived_data` wrapper and its in-app twin reset the state alike.
    ///
    /// A source whose fetch is known to fail keeps its `error_message` and its
    /// state: requeuing a paywalled paper would retry a doomed fetch forever.
    /// Not private: `mergeMeetingSessions` clears the text of a session it
    /// folded into another inside its own transaction, as `archiveSource` does.
    func clearSourceText(_ sourceId: String) throws {
        try execBind("DELETE FROM source_content WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM paper_content_preparations WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM article_content_preparations WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM canonical_content_cleanup_queue WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM source_review_guide_queue WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM source_review_guides WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM source_walkthroughs WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try deleteWalkthroughProgress(sourceId)
        try execBind("DELETE FROM source_listenable_content_queue WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM source_listenable_content WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM paper_figure_index_queue WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM paper_figure_index_state WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        try execBind("DELETE FROM paper_figures WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceId)
        }
        // Search goes with the text: the vectors, the stamp that says they exist
        // (left behind, it would survive a restore that brings the same text back
        // and keep the source out of the embedding gap query) and the full-text
        // row, which keyword search would otherwise still find.
        try dropSourceSearchRows(sourceID: sourceId)

        try execBind("""
            UPDATE sources SET state = ?
            WHERE id = ? AND COALESCE(error_message, '') = ''
        """) { stmt in
            self.bind(stmt, 1, StudioArticleState.queued.rawValue)
            self.bind(stmt, 2, sourceId)
        }
        // The count described text that no longer exists. Left behind it makes
        // the chat catalog offer the model a size it cannot load.
        for table in Self.sourceWordCountTables {
            try execBind("UPDATE \(table) SET word_count = NULL WHERE source_id = ?") { stmt in
                self.bind(stmt, 1, sourceId)
            }
        }
    }

    /// Unarchive all sources belonging to a parent group (e.g. a book).
    func unarchiveSourcesByParentGroup(_ parentGroup: String) throws {
        var sourceIDs: [String] = []
        try queryBind("""
            SELECT s.id
            FROM sources s
            JOIN group_members gm ON gm.source_id = s.id
            WHERE gm.group_id = ? AND s.status = 'archived'
        """, bind: { stmt in
            self.bind(stmt, 1, parentGroup)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                sourceIDs.append(id)
            }
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE sources
                SET status = 'active', archived_at = NULL
                WHERE id IN (SELECT source_id FROM group_members WHERE group_id = ?)
                  AND status = 'archived'
            """) { stmt in
                self.bind(stmt, 1, parentGroup)
            }
            for sourceID in sourceIDs {
                // An unarchived podcast that kept its transcript is visible
                // again and may never have been through ad cleanup.
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
                noteStoreChanged()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Bring an archived source back, refetching if it has no text.
    ///
    /// `clearSourceText` now requeues at the point text is removed, so an
    /// ordinary archive→revive round trip already comes back as `queued`. This
    /// check is the read-side backstop: it catches rows that predate that fix
    /// (57 videos revived by the liked-YouTube sweep still claim `ready` with a
    /// word count and no transcript) and any future path that removes text
    /// without going through the store. Reviving a source that reports success
    /// with nothing behind it is the failure worth spending a subquery on.
    ///
    /// A source that legitimately has no text carries an `error_message` (a
    /// paywalled paper, say) and is left as it is: requeuing it would retry a
    /// fetch that is known to fail, forever.
    func unarchiveSource(_ sourceID: String) throws {
        try execBind("""
            UPDATE sources
            SET status = 'active',
                archived_at = NULL,
                state = CASE
                    WHEN COALESCE(error_message, '') = ''
                     AND NOT EXISTS (
                            SELECT 1 FROM source_content sc
                            WHERE sc.source_id = sources.id
                              AND COALESCE(LENGTH(sc.content), 0) > 0
                         )
                    THEN ?
                    ELSE state
                END
            WHERE id = ?
        """) { stmt in
            self.bind(stmt, 1, StudioArticleState.queued.rawValue)
            self.bind(stmt, 2, sourceID)
        }
        // A revived podcast that still has its text is owed ad cleanup; one
        // that came back textless is requeued above and stages the cleanup when
        // its transcript is saved.
        try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceID)
        noteStoreChanged()
    }

    /// `unarchive_source` as the MCP tool does it, in one place so the app's
    /// own Unarchive action and the tool cannot drift apart: the source goes
    /// back to active, the dismissal that `remove_source` left on its URL is
    /// cleared so sync or discovery does not archive it again on the spot, and
    /// a source backed by a local file (a book chapter, saved article HTML)
    /// gets the text that archiving removed rebuilt from that file. Nil when
    /// no `sources` row carries the id.
    func unarchiveSourceRestoringContent(_ sourceID: String) throws -> SourceUnarchiveOutcome? {
        guard let article = try loadSourceForSync(sourceID) else { return nil }

        _ = try undismissSource(url: article.url)
        if let webURL = article.podcastWebPageURL {
            _ = try undismissSource(url: webURL)
        }
        try unarchiveSource(sourceID)

        var rebuiltContent = false
        if let path = article.resolvedLocalPath,
           let raw = Self.textOfLocalFile(atPath: path),
           !raw.isEmpty {
            let lower = path.lowercased()
            let isMarkup = lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml")
            let text = (isMarkup ? EPUBParser.stripHTML(raw) : raw.removingSoftHyphens())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                try saveTranscript(sourceID, text)
                rebuiltContent = true
            }
        }
        return SourceUnarchiveOutcome(title: article.title, rebuiltContent: rebuiltContent)
    }

    /// A source's local file read as its text, or nil when the file is not
    /// text. A web or EPUB document is read wherever it is (on disk or inside
    /// its book's `.epub`), Latin-1 when not UTF-8, as a few older EPUB exports
    /// are; any other file only as UTF-8. A PDF's text is in its pages, never
    /// its bytes: read through the Latin-1 fallback, which decodes any bytes,
    /// a paper or a PDF book's chapter would take its file's raw bytes as its text
    /// on unarchive.
    static func textOfLocalFile(atPath path: String) -> String? {
        let lower = path.lowercased()
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml") {
            return EPUBBookFiles.text(atPath: path)
        }
        guard !lower.hasSuffix(".pdf") else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The library's answer for each id whatever the row's status: its title
    /// and whether it is active or archived. Ids with no `sources` row are
    /// absent, which is the one case that means the source is gone; a planner
    /// block or a Now-chip row that only checked the active list read an
    /// archived paper as deleted.
    func sourceRowSummaries(for sourceIDs: some Collection<String>) throws -> [String: SourceRowSummary] {
        let uniqueIDs = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return [:] }
        var summaries: [String: SourceRowSummary] = [:]
        let chunkSize = 400
        var offset = 0
        while offset < uniqueIDs.count {
            let chunk = Array(uniqueIDs[offset..<min(offset + chunkSize, uniqueIDs.count)])
            offset += chunkSize
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT sp.id, sp.title, sp.url, sp.status, sp.source_type FROM source_projection sp WHERE sp.id IN (\(placeholders))"
            try queryBind(sql, bind: { stmt in
                for (index, sourceID) in chunk.enumerated() {
                    self.bind(stmt, index + 1, sourceID)
                }
            }) { stmt in
                guard let id = self.string(stmt, 0) else { return }
                let title = self.string(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let url = self.string(stmt, 2) ?? ""
                let status = self.string(stmt, 3).flatMap(SourceStatus.init(rawValue:)) ?? .active
                let type = self.string(stmt, 4).flatMap(StudioSourceType.init(rawValue:)) ?? .unclassified
                summaries[id] = SourceRowSummary(id: id, title: title.isEmpty ? url : title, status: status, type: type)
            }
        }
        return summaries
    }

    func sourceIDsByParentGroup(_ parentGroup: String) throws -> [String] {
        var sourceIDs: [String] = []
        try queryBind("""
            SELECT s.id
            FROM sources s
            JOIN group_members gm ON gm.source_id = s.id
            WHERE gm.group_id = ?
            ORDER BY gm.sort_index, s.date_added
        """, bind: { stmt in
            self.bind(stmt, 1, parentGroup)
        }) { stmt in
            if let id = self.string(stmt, 0) {
                sourceIDs.append(id)
            }
        }
        return sourceIDs
    }

    /// Count persisted source rows belonging to a parent group, including archived rows.
    func sourceCountByParentGroup(_ parentGroup: String) throws -> Int {
        var count = 0
        try queryBind("""
            SELECT COUNT(*)
            FROM sources s
            JOIN group_members gm ON gm.source_id = s.id
            WHERE gm.group_id = ?
        """, bind: { stmt in
            self.bind(stmt, 1, parentGroup)
        }) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    /// Every ingested chapter of a book group keyed by its path relative to the
    /// extracted `Chapters` directory, mapped to whether that chapter is archived.
    /// Used to reconcile the EPUB reader's Contents menu with the app's source
    /// model: spine files that were never ingested (cover, copyright, ads) are absent
    /// from the map and get filtered out, and archived chapters are marked so the
    /// reader can flag them.
    func bookChapterArchivedByRelativePath(groupID: String) throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        try queryBind("""
            SELECT bs.local_file_path, s.status
            FROM group_members gm
            JOIN sources s ON s.id = gm.source_id
            JOIN book_sources bs ON bs.source_id = gm.source_id
            WHERE gm.group_id = ?
        """, bind: { stmt in
            self.bind(stmt, 1, groupID)
        }) { stmt in
            guard let path = self.string(stmt, 0), !path.isEmpty else { return }
            guard let relativePath = Self.chapterRelativePathKey(path), !relativePath.isEmpty else { return }
            let status = self.string(stmt, 1) ?? SourceStatus.active.rawValue
            result[relativePath] = (status == SourceStatus.archived.rawValue)
        }
        return result
    }

    private static func chapterRelativePathKey(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let chaptersIndex = components.lastIndex(where: { component in
            component == "Chapters" || component.hasSuffix("_Chapters")
        }) else {
            return (normalized as NSString).lastPathComponent
        }
        let relativeComponents = components.dropFirst(chaptersIndex + 1)
        guard !relativeComponents.isEmpty else { return nil }
        return relativeComponents.joined(separator: "/")
    }

    /// Give a podcast episode the public Apple Podcasts identity it was found
    /// to have: a private-feed placeholder or an episode filed under its web
    /// page becomes `apple-podcast://episode/<track id>`, the page it came
    /// from is kept as the episode's web page, and everything derived from a
    /// non-transcript body goes. A page's text is never a podcast's content —
    /// the fetch path already refuses to scrape one — so a row that arrives
    /// here holding page text leaves without it and queued for its transcript.
    ///
    /// Throws `duplicateSourceIdentity` when another active source already
    /// carries the public identity; the caller merges the two instead.
    func rebindPodcastEpisodeIdentity(
        _ sourceID: String,
        toPublicURL publicURL: String,
        webPageURL: String?
    ) throws {
        let normalized = URLNormalizer.normalize(publicURL)
        try exec("BEGIN IMMEDIATE")
        do {
            var previousURL: String?
            try queryBind(
                "SELECT url FROM podcasts WHERE source_id = ?",
                bind: { stmt in self.bind(stmt, 1, sourceID) }
            ) { stmt in previousURL = self.string(stmt, 0) }
            guard let previousURL else {
                throw KnowledgeStoreError.invalidData("Podcast source \(sourceID) was not found.")
            }
            var holder: String?
            try queryBind("""
                SELECT p.source_id
                FROM podcasts p
                JOIN sources s ON s.id = p.source_id
                WHERE p.source_id != ?
                  AND s.status = ?
                  AND (p.normalized_url = ? OR p.url = ?)
                LIMIT 1
            """, bind: { stmt in
                self.bind(stmt, 1, sourceID)
                self.bind(stmt, 2, SourceStatus.active.rawValue)
                self.bind(stmt, 3, normalized)
                self.bind(stmt, 4, publicURL)
            }) { stmt in holder = self.string(stmt, 0) }
            if let holder {
                throw KnowledgeStoreError.duplicateSourceIdentity(existingSourceID: holder)
            }

            let previousPage = previousURL.lowercased().hasPrefix("http") ? previousURL : nil
            try execBind("""
                UPDATE podcasts
                SET url = ?,
                    normalized_url = ?,
                    web_page_url = COALESCE(?, web_page_url)
                WHERE source_id = ?
            """) { stmt in
                self.bind(stmt, 1, publicURL)
                self.bind(stmt, 2, normalized)
                self.bind(stmt, 3, webPageURL ?? previousPage)
                self.bind(stmt, 4, sourceID)
            }
            if previousPage != nil {
                try clearSourceText(sourceID)
                try execBind("UPDATE sources SET state = ?, error_message = NULL WHERE id = ?") { stmt in
                    self.bind(stmt, 1, StudioArticleState.queued.rawValue)
                    self.bind(stmt, 2, sourceID)
                }
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Fold a podcast row that resolved to an identity another row already
    /// holds into that row. The duplicate is archived, not deleted, and every
    /// relationship authored against it — Notebook membership, chats, schedule
    /// placements, highlights — moves to the surviving episode.
    func archivePodcastEpisodeDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try archivePaperIdentityDuplicate(duplicateID, replacingWith: canonicalID)
    }

    /// The fraction of an existing transcript a replacement must keep before it
    /// is treated as data loss rather than an edit.
    ///
    /// Verified ad removal takes out whole sponsor reads and is the only pass
    /// that legitimately shrinks a stored transcript; even on a sponsor-heavy
    /// show that is far short of half the episode. The retired
    /// 50,000-character import cap, which went unnoticed for as long as it did
    /// because only the AI paths read this column, left episodes at 3.6% to 26%
    /// of their words. Refusing a halving draws the line between the two and
    /// costs a correct write nothing.
    static let podcastTranscriptDowngradeFloor = 0.5

    /// Save content for a source and update its state to 'ready'.
    ///
    /// - Parameters:
    ///   - podcastCleanupInput: the raw transcript `text` was formatted from;
    ///     the episode is then owed nothing more.
    ///   - podcastFormatting: set when `text` is the raw transcript, laid out
    ///     but unformatted: it reads at once and the episode is queued for its
    ///     formatting pass. Never together with `podcastCleanupInput`.
    func saveTranscript(
        _ sourceId: String,
        _ text: String,
        rawTTML: String? = nil,
        podcastCleanupInput: String? = nil,
        podcastFormatting: PodcastTranscriptFormattingRequest? = nil,
        allowsShorterTranscript: Bool = false
    ) throws {
        guard podcastCleanupInput == nil || podcastFormatting == nil else {
            throw KnowledgeStoreError.invalidData(
                "A transcript saved with the raw text it was formatted from is owed no formatting."
            )
        }
        try exec("BEGIN IMMEDIATE")
        do {
            // A transcript that is being replaced by a fresh full extraction
            // carries its TTML, and an explicit override covers a learner-driven
            // swap. Anything else that would drop half an episode on the floor
            // is a bug in the caller, and failing the write keeps it out of
            // `source_content` — and out of CloudKit — instead of leaving chat
            // to answer from the remainder.
            if rawTTML == nil, !allowsShorterTranscript {
                var existingCount = 0
                try queryBind(
                    "SELECT length(content) FROM source_content WHERE source_id = ?",
                    bind: { stmt in self.bind(stmt, 1, sourceId) }
                ) { stmt in
                    existingCount = Int(sqlite3_column_int64(stmt, 0))
                }
                let floor = Double(existingCount) * Self.podcastTranscriptDowngradeFloor
                if existingCount > 0, Double(text.count) < floor {
                    throw KnowledgeStoreError.invalidData(
                        """
                        Refusing to replace the \(existingCount)-character transcript for \
                        \(sourceId) with \(text.count) characters. Pass \
                        allowsShorterTranscript when the shorter text is intended.
                        """
                    )
                }
            }
            let replacesText = try replacesStoredText(sourceID: sourceId, with: text)
            try writeSourceContent(sourceID: sourceId, content: text)
            if replacesText {
                try invalidateReplacedText(sourceID: sourceId)
            }
            try writeStoredWordCount(sourceID: sourceId, text: text)
            if let rawTTML {
                try execBind("""
                    UPDATE podcasts SET raw_ttml = ? WHERE source_id = ?
                """) { stmt in
                    self.bind(stmt, 1, rawTTML)
                    self.bind(stmt, 2, sourceId)
                }
                // Hydration derived this transcript from the whole TTML, so the
                // completeness audit has nothing to find here.
                try recordPodcastTranscriptFullExtraction(
                    sourceID: sourceId,
                    ttmlSHA256: PaperContentPreparationService.sha256(rawTTML)
                )
            } else {
                try enqueuePodcastTranscriptDetruncationIfNeeded(sourceID: sourceId)
            }
            try execBind("UPDATE sources SET state = ? WHERE id = ? AND source_type != ?") { stmt in
                self.bind(stmt, 1, StudioArticleState.ready.rawValue)
                self.bind(stmt, 2, sourceId)
                self.bind(stmt, 3, StudioSourceType.paper.rawValue)
            }
            if let podcastCleanupInput {
                let metadata = PodcastTranscriptCleanupMetadata(
                    cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                    inputSHA256: PaperContentPreparationService.sha256(podcastCleanupInput),
                    cleanSHA256: PaperContentPreparationService.sha256(text),
                    preparedAt: Date()
                )
                try upsertPodcastTranscriptPreparation(
                    sourceID: sourceId,
                    input: podcastCleanupInput,
                    metadata: metadata
                )
                try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                    self.bind(stmt, 1, sourceId)
                }
            } else {
                try execBind("DELETE FROM podcast_transcript_preparations WHERE source_id = ?") { stmt in
                    self.bind(stmt, 1, sourceId)
                }
                try enqueuePodcastTranscriptCleanupIfNeeded(
                    sourceID: sourceId,
                    formatting: podcastFormatting.map { ($0, PaperContentPreparationService.sha256(text)) }
                )
            }
            try enqueueSourceListenableContentPreparation(sourceID: sourceId, content: text)
            try retireSourceReviewGuidePreparation(sourceID: sourceId)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Whether `text` replaces a different text this Mac stores for the
    /// source. Read before the write. A first text needs nothing more: the
    /// indexer finds a source it has not indexed, and the publisher finds
    /// text that no pointer names (`queueUnpublishedSourceFiles`).
    func replacesStoredText(sourceID: String, with text: String) throws -> Bool {
        try scalarInteger("""
            SELECT EXISTS (
                SELECT 1 FROM source_content
                WHERE source_id = ? AND length(content) > 0 AND content IS NOT ?
            )
        """, [.text(sourceID), .text(text)]) == 1
    }

    /// A text that replaced another (a transcript fetched again, formatted
    /// again, speakers named again, or YouTube captions taken instead; any
    /// source's text a save rewrote, such as a book chapter an MCP client
    /// edited) is new text for this Mac's search index and for the copy other
    /// devices read, as every other writer of a source's text treats it: the
    /// index goes and the text is queued to be published again. Without this
    /// a replaced text kept its old words searchable when the length matched,
    /// and under generation 2 reached the iPhone or another Mac only if
    /// something wrote it again afterwards, since the publisher's sweep looks
    /// only for text no pointer names. A text still owed its clean-up is left
    /// to the clean-up's own write, which does the same, so another Mac never
    /// records the raw text as cleaned.
    func invalidateReplacedText(sourceID: String) throws {
        guard try scalarInteger(
            "SELECT EXISTS (SELECT 1 FROM canonical_content_cleanup_queue WHERE source_id = ?)",
            [.text(sourceID)]
        ) != 1 else { return }
        try invalidateCanonicalContentIndexes(sourceID: sourceID)
    }

    /// Atomically attach a learner-confirmed YouTube caption transcript to an
    /// existing podcast episode. The podcast's stable Apple identity remains in
    /// `podcasts.url`; `sources.public_url` records where this transcript came
    /// from and already participates in the ordinary source CloudKit payload.
    func savePodcastYouTubeTranscript(
        _ sourceId: String,
        _ text: String,
        youtubeURL: String?,
        cleanupInput: String? = nil
    ) throws {
        let wordCount = Self.storedWordCount(of: text)
        try exec("BEGIN IMMEDIATE")
        do {
            let replacesText = try replacesStoredText(sourceID: sourceId, with: text)
            try writeSourceContent(sourceID: sourceId, content: text)
            if replacesText {
                try invalidateReplacedText(sourceID: sourceId)
            }
            try execBind("UPDATE podcasts SET raw_ttml = NULL, word_count = ? WHERE source_id = ?") { stmt in
                self.bind(stmt, 1, wordCount)
                self.bind(stmt, 2, sourceId)
            }
            guard sqlite3_changes(db) == 1 else {
                throw KnowledgeStoreError.invalidData("Podcast source \(sourceId) was not found.")
            }
            if let cleanupInput {
                let metadata = PodcastTranscriptCleanupMetadata(
                    cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                    inputSHA256: PaperContentPreparationService.sha256(cleanupInput),
                    cleanSHA256: PaperContentPreparationService.sha256(text),
                    preparedAt: Date()
                )
                try upsertPodcastTranscriptPreparation(
                    sourceID: sourceId,
                    input: cleanupInput,
                    metadata: metadata
                )
                try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
                    self.bind(stmt, 1, sourceId)
                }
            } else {
                try execBind("DELETE FROM podcast_transcript_preparations WHERE source_id = ?") { stmt in
                    self.bind(stmt, 1, sourceId)
                }
                try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: sourceId)
            }
            try execBind("""
                UPDATE sources
                SET state = ?, error_message = NULL, public_url = COALESCE(?, public_url)
                WHERE id = ? AND source_type = ?
            """) { stmt in
                self.bind(stmt, 1, StudioArticleState.ready.rawValue)
                self.bind(stmt, 2, youtubeURL)
                self.bind(stmt, 3, sourceId)
                self.bind(stmt, 4, StudioSourceType.podcast.rawValue)
            }
            guard sqlite3_changes(db) == 1 else {
                throw KnowledgeStoreError.invalidData("Podcast source \(sourceId) was not found.")
            }
            try enqueueSourceListenableContentPreparation(sourceID: sourceId, content: text)
            try retireSourceReviewGuidePreparation(sourceID: sourceId)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Return the set of Apple Podcasts track IDs that already have transcript content in the DB.
    func podcastTrackIdsWithContent() -> Set<Int64> {
        var result = Set<Int64>()
        let sql = """
            SELECT pod.url FROM podcasts pod
            JOIN sources s ON s.id = pod.source_id
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.source_type = 'podcast' AND s.status = 'active'
        """
        try? query(sql) { stmt in
            if let url = self.string(stmt, 0) {
                if let trackId = Self.extractTrackIdFromURL(url) {
                    result.insert(trackId)
                }
            }
        }
        return result
    }

    /// Extract an Apple Podcasts track ID from the stable episode URL.
    static func extractTrackIdFromURL(_ url: String) -> Int64? {
        let pattern = #"(?i)^apple-podcast:/+episode/(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: url)
        else {
            return nil
        }
        return Int64(url[range])
    }

    /// Update a source's group membership (removes from all groups if group is nil).
    func updateParentGroup(_ sourceId: String, _ group: String?) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM group_members WHERE source_id = ?") { stmt in
                self.bind(stmt, 1, sourceId)
            }
            if let group {
                try execBind("INSERT OR IGNORE INTO group_members (source_id, group_id) VALUES (?,?)") { stmt in
                    self.bind(stmt, 1, sourceId)
                    self.bind(stmt, 2, group)
                }
                _ = try addSourcesToNotebooksLinkedToCourseInCurrentTransaction(
                    courseID: group,
                    sourceIDs: [sourceId]
                )
            }
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func updateCourseSortIndex(_ sourceId: String, _ sortIndex: Int) throws -> Bool {
        try execBind("UPDATE group_members SET sort_index = ? WHERE source_id = ? AND sort_index IS NOT ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(sortIndex))
            self.bind(stmt, 2, sourceId)
            sqlite3_bind_int(stmt, 3, Int32(sortIndex))
        }
        guard sqlite3_changes(db) > 0 else { return false }
        noteStoreChanged()
        return true
    }

    /// Update sort order for multiple sources in a single transaction.
    func updateCourseSortOrder(_ ordering: [(String, Int)]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for (sourceId, index) in ordering {
                try execBind("UPDATE group_members SET sort_index = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(index))
                    self.bind(stmt, 2, sourceId)
                }
            }
            if !ordering.isEmpty {
                noteStoreChanged()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Update sort order for book chapters in a single transaction.
    func updateBookSortOrder(_ ordering: [(String, Int)]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for (sourceId, index) in ordering {
                try execBind("UPDATE group_members SET sort_index = ? WHERE source_id = ?") { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(index))
                    self.bind(stmt, 2, sourceId)
                }
            }
            if !ordering.isEmpty {
                noteStoreChanged()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Rewrite an absolute path from a different Mac's home directory to the current user's home.
    /// Handles iCloud-synced databases where paths like `/Users/olduser/Library/...` need to
    /// become `/Users/currentuser/Library/...`. Returns the path unchanged if it already matches
    /// the current home or isn't a `/Users/` path.
    func normalizePathForCurrentUser(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/Users/") else { return path }
        if path.hasPrefix(currentHome) { return path }
        // Split: ["", "Users", "<username>", "Library/..."]
        // Find the third "/" to extract the relative portion after /Users/<username>/
        var slashCount = 0
        var cutIndex = path.startIndex
        for i in path.indices {
            if path[i] == "/" {
                slashCount += 1
                if slashCount == 3 {
                    cutIndex = path.index(after: i)
                    break
                }
            }
        }
        guard slashCount >= 3 else { return path }
        let relativePart = String(path[cutIndex...])
        return (currentHome as NSString).appendingPathComponent(relativePart)
    }

    /// Read a source row from a query using the explicit `sourceColumns` layout.
    /// Column order must match `sourceColumns`:
    ///  0: id, 1: url, 2: title, 3: domain, 4: date_added, 5: word_count,
    ///  6: state, 7: error_message, 8: source_type, 9: artwork_url,
    /// 10: discovery_origin, 11: local_file_path, 12: author,
    /// 13: status, 14: archived_at, 15: normalized_url,
    /// 16: public_url, 17: reading_position_page, 18: reading_position_locator,
    /// 19: journal (papers), 20: published_year (papers), 21: is_paywalled (papers),
    /// 22: doi, 23: podcast_web_page_url,
    /// 24: parent_group, 25: sort_index, 26: lecture_group_id,
    /// 27: is_hidden, 28: read_at,
    /// 29: liked_at (videos), 30: video_published_at (videos),
    /// 31: connector_label, 32: paper_ingestion_method,
    /// 33: raw paper-content SHA-256 when current cleanup is complete,
    /// 34: current listenable-content derivative is ready,
    /// 35: published_doi (papers) — the journal DOI a preprint resolved to,
    /// 36: team_id, 37: paywall_suspicion (papers)
    func readSourceRow(_ stmt: OpaquePointer?) -> StudioArticle? {
        guard let id = string(stmt, 0),
              let url = string(stmt, 1),
              let title = string(stmt, 2),
              let domain = string(stmt, 3),
              let stateStr = string(stmt, 6),
              let state = StudioArticleState(rawValue: stateStr),
              let sourceTypeStr = string(stmt, 8),
              let sourceType = StudioSourceType(rawValue: sourceTypeStr)
        else { return nil }

        let dateAdded = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
        let wordCount = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let errorMessage = string(stmt, 7)
        let artworkURL = string(stmt, 9)
        let discoveryOriginStr = string(stmt, 10)
        let discoveryOrigin = discoveryOriginStr.flatMap { DiscoveryOrigin(rawValue: $0) }
        let localFilePath = string(stmt, 11)
        let author = string(stmt, 12)
        let statusStr = string(stmt, 13)
        let sourceStatus = statusStr.flatMap { SourceStatus(rawValue: $0) } ?? .active
        let archivedAtStr = string(stmt, 14)
        let archivedAt: Date? = archivedAtStr.flatMap { Self.iso8601Formatter.date(from: $0) }
        let dbNormalizedURL = string(stmt, 15)

        let publicURL = string(stmt, 16)
        let readingPositionPage = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 17))
        let readingPositionLocator = string(stmt, 18)
        let journal = string(stmt, 19)
        let publishedYear = string(stmt, 20)
        let isPaywalledVal = sqlite3_column_type(stmt, 21) == SQLITE_NULL ? false : sqlite3_column_int(stmt, 21) != 0
        let doi = string(stmt, 22)
        let podcastWebPageURL = string(stmt, 23)
        let parentGroup = string(stmt, 24)
        let courseSortIndex = sqlite3_column_type(stmt, 25) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 25))
        let lectureGroupId = string(stmt, 26)
        let isHidden = sqlite3_column_int(stmt, 27) != 0
        let readAt = sqlite3_column_type(stmt, 28) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 28))
        let likedAt = sqlite3_column_type(stmt, 29) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 29))
        let videoPublishedAt = sqlite3_column_type(stmt, 30) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 30))
        let connectorLabel = string(stmt, 31)
        let paperIngestionMethod = string(stmt, 32).flatMap(PaperIngestionMethod.init(rawValue:))
        let paperContentSHA256 = string(stmt, 33)
        let paperListenableContentReady = sqlite3_column_int(stmt, 34) != 0

        // Resolve paths: relative paths get expanded to absolute;
        // absolute paths from a different Mac get re-homed to the current user.
        let normalizedURL = StorageService.absoluteSourcePath(url).hasPrefix("/")
            ? (normalizePathForCurrentUser(StorageService.absoluteSourcePath(url)) ?? StorageService.absoluteSourcePath(url))
            : url
        let normalizedLocalFilePath: String? = localFilePath.map { lp in
            let abs = StorageService.absoluteSourcePath(lp)
            return abs.hasPrefix("/") ? (normalizePathForCurrentUser(abs) ?? abs) : lp
        }

        var article = reconstructStudioArticle(
            id: id, url: normalizedURL, title: title, domain: domain, dateAdded: dateAdded,
            content: nil, wordCount: wordCount, state: state,
            errorMessage: errorMessage, sourceType: sourceType,
            artworkURL: artworkURL,
            discoveryOrigin: discoveryOrigin, parentGroup: parentGroup,
            localFilePath: normalizedLocalFilePath, podcastWebPageURL: podcastWebPageURL,
            author: author, publicURL: publicURL, journal: journal, publishedYear: publishedYear,
            doi: doi, paperIngestionMethod: paperIngestionMethod,
            courseSortIndex: courseSortIndex, lectureGroupId: lectureGroupId
        )
        article?.isPaywalled = isPaywalledVal
        article?.status = sourceStatus
        article?.archivedAt = archivedAt
        article?.normalizedURL = dbNormalizedURL
        article?.publicURL = publicURL
        article?.isHidden = isHidden
        article?.readingPositionPage = readingPositionPage
        article?.readingPositionLocator = readingPositionLocator
        article?.readAt = readAt
        article?.likedAt = likedAt
        article?.videoPublishedAt = videoPublishedAt
        article?.connectorLabel = connectorLabel
        article?.paperContentSHA256 = paperContentSHA256
        article?.paperListenableContentReady = paperListenableContentReady
        article?.publishedDOI = string(stmt, 35)
        article?.teamID = string(stmt, 36)
        article?.paywallSuspicion = string(stmt, 37)
        article?.bookPages = bookPages(stmt, startColumn: 38)
        // From here on the copy notes what its holder changes, which is all its save writes
        // (`StudioArticle.written(over:)`).
        article?.edits = .read
        return article
    }

    func sourceIdentities(for sourceIDs: [String]) throws -> [CloudKitSourceIdentityPayload] {
        let uniqueSourceIDs = dictUnique(sourceIDs)
        guard !uniqueSourceIDs.isEmpty else { return [] }

        var identities: [CloudKitSourceIdentityPayload] = []
        for sourceID in uniqueSourceIDs {
            try queryBind("""
                SELECT sp.id, sp.url, sp.normalized_url, sp.doi, p.published_doi
                FROM source_projection sp
                LEFT JOIN papers p ON p.source_id = sp.id
                WHERE sp.id = ?
                LIMIT 1
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
            }) { stmt in
                guard let id = self.string(stmt, 0) else { return }
                let url = self.string(stmt, 1)
                let normalizedURL = self.string(stmt, 2) ?? url.map(URLNormalizer.normalize)
                identities.append(
                    CloudKitSourceIdentityPayload(
                        sourceID: id,
                        url: url,
                        normalizedURL: normalizedURL,
                        doi: self.string(stmt, 3),
                        publishedDOI: self.string(stmt, 4)
                    )
                )
            }
        }
        return identities
    }

    func resolveSourceIDs(_ sourceIDs: [String], identities: [CloudKitSourceIdentityPayload]) throws -> [String] {
        let identityBySourceID = sourceIdentityLookup(identities)
        var resolved: [String] = []
        var seen = Set<String>()
        for sourceID in sourceIDs {
            let mapped = try resolveSourceID(sourceID, identitiesBySourceID: identityBySourceID)
            if seen.insert(mapped).inserted {
                resolved.append(mapped)
            }
        }
        return resolved
    }

    func resolveSourceID(_ sourceID: String, identities: [CloudKitSourceIdentityPayload]) throws -> String {
        let identityBySourceID = sourceIdentityLookup(identities)
        return try resolveSourceID(sourceID, identitiesBySourceID: identityBySourceID)
    }

    func sourceIdentityLookup(_ identities: [CloudKitSourceIdentityPayload]) -> [String: CloudKitSourceIdentityPayload] {
        var lookup: [String: CloudKitSourceIdentityPayload] = [:]
        for identity in identities where lookup[identity.sourceID] == nil {
            lookup[identity.sourceID] = identity
        }
        return lookup
    }

    func resolveSourceID(_ sourceID: String, identitiesBySourceID: [String: CloudKitSourceIdentityPayload]) throws -> String {
        if try sourceExists(sourceID) {
            return sourceID
        }
        guard let identity = identitiesBySourceID[sourceID] else {
            return sourceID
        }

        let doiCandidates = dictUnique([identity.doi, identity.publishedDOI].compactMap { cleanIdentityValue($0) })
        for doi in doiCandidates {
            if let match = try sourceIDByDOI(doi) {
                return match
            }
        }

        if let normalizedURL = cleanIdentityValue(identity.normalizedURL),
           let match = try sourceIDByNormalizedURL(normalizedURL) {
            return match
        }
        if let url = cleanIdentityValue(identity.url) {
            if let match = try sourceIDByNormalizedURL(URLNormalizer.normalize(url)) {
                return match
            }
            if let match = try sourceIDByURL(url) {
                return match
            }
        }
        return sourceID
    }

    func cleanIdentityValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func sourceIDByDOI(_ doi: String) throws -> String? {
        var match: String?
        try queryBind("""
            SELECT source_id
            FROM papers INDEXED BY idx_papers_doi_nocase
            WHERE doi = ? COLLATE NOCASE
            ORDER BY source_id ASC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, doi.lowercased())
        }) { stmt in
            match = self.string(stmt, 0)
        }
        if match != nil { return match }
        try queryBind("""
            SELECT source_id
            FROM papers INDEXED BY idx_papers_published_doi_nocase
            WHERE published_doi = ? COLLATE NOCASE
            ORDER BY source_id ASC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, doi.lowercased())
        }) { stmt in
            match = self.string(stmt, 0)
        }
        return match
    }

    func sourceIDByNormalizedURL(_ normalizedURL: String) throws -> String? {
        var match: String?
        try queryBind("""
            SELECT id
            FROM source_projection
            WHERE normalized_url = ?
            ORDER BY id ASC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, normalizedURL)
        }) { stmt in
            match = self.string(stmt, 0)
        }
        return match
    }

    func sourceIDByURL(_ url: String) throws -> String? {
        var match: String?
        try queryBind("""
            SELECT id
            FROM source_projection
            WHERE url = ?
            ORDER BY id ASC
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, url)
        }) { stmt in
            match = self.string(stmt, 0)
        }
        return match
    }

    // MARK: - Context Source IDs

}
