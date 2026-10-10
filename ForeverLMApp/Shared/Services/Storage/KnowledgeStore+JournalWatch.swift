import Foundation
import SQLite3

/// Journals: followed feeds, the articles they announced, and the verdicts.
///
/// Nothing here touches `sync_metadata` or `sync_changes`. The tables are
/// device-local by design (see the schema comment and docs/journals-design.md);
/// the one thing that becomes synced data is the Source an accepted match is
/// imported as, and that goes through the ordinary source pipeline.
extension KnowledgeStore {

    // MARK: - Feeds

    func loadJournalFeeds() throws -> [JournalFeed] {
        var feeds: [JournalFeed] = []
        try query("""
            SELECT id, feed_url, title, site_url, added_at, last_checked_at, last_succeeded_at,
                   last_error, etag, last_modified, item_count
            FROM journal_feeds
            ORDER BY title COLLATE NOCASE ASC, added_at ASC
        """) { stmt in
            if let feed = self.journalFeed(from: stmt) { feeds.append(feed) }
        }
        return feeds
    }

    func loadJournalFeed(feedURL: String) throws -> JournalFeed? {
        var feed: JournalFeed?
        try queryBind("""
            SELECT id, feed_url, title, site_url, added_at, last_checked_at, last_succeeded_at,
                   last_error, etag, last_modified, item_count
            FROM journal_feeds WHERE feed_url = ?
        """, bind: { stmt in self.bind(stmt, 1, feedURL) }) { stmt in
            feed = self.journalFeed(from: stmt)
        }
        return feed
    }

    /// Follows a feed. Following one already followed returns the existing row
    /// unchanged rather than failing: pasting the same journal twice is not an
    /// error worth showing.
    @discardableResult
    func addJournalFeed(feedURL: String, title: String, siteURL: String?, now: Date = Date()) throws -> (feed: JournalFeed, inserted: Bool) {
        let trimmedURL = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw KnowledgeStoreError.invalidData("A journal needs a feed address.")
        }
        if let existing = try loadJournalFeed(feedURL: trimmedURL) {
            return (existing, false)
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let feed = JournalFeed(
            feedURL: trimmedURL,
            title: trimmedTitle.isEmpty ? (URL(string: trimmedURL)?.host ?? trimmedURL) : trimmedTitle,
            siteURL: siteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            addedAt: now
        )
        try execBind("""
            INSERT INTO journal_feeds (id, feed_url, title, site_url, added_at, item_count)
            VALUES (?, ?, ?, ?, ?, 0)
        """) { stmt in
            self.bind(stmt, 1, feed.id)
            self.bind(stmt, 2, feed.feedURL)
            self.bind(stmt, 3, feed.title)
            self.bind(stmt, 4, feed.siteURL)
            self.bind(stmt, 5, feed.addedAt.timeIntervalSinceReferenceDate)
        }
        return (feed, true)
    }

    /// Unfollows a feed and forgets its unanswered articles: the pending
    /// suggestions it produced and the articles nothing was decided about.
    /// Decided verdicts stay, with the article row they name, so a dismissal
    /// is remembered when the same article arrives again through another feed
    /// or a re-follow. Sources an accepted match created stay in the library —
    /// they are the learner's now.
    func deleteJournalFeed(_ feedID: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                DELETE FROM journal_article_matches
                WHERE state = 'pending'
                  AND item_url IN (SELECT item_url FROM journal_feed_items WHERE feed_id = ?)
            """) { stmt in self.bind(stmt, 1, feedID) }
            try execBind("""
                DELETE FROM journal_feed_items
                WHERE feed_id = ?
                  AND item_url NOT IN (SELECT item_url FROM journal_article_matches)
            """) { stmt in self.bind(stmt, 1, feedID) }
            try execBind("DELETE FROM journal_feeds WHERE id = ?") { stmt in self.bind(stmt, 1, feedID) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Records the outcome of one fetch. A failure keeps the previous
    /// validators so the next attempt can still come back 304.
    func recordJournalFeedCheck(
        feedID: String,
        at now: Date,
        succeeded: Bool,
        error: String?,
        etag: String?,
        lastModified: String?,
        title: String?
    ) throws {
        if succeeded {
            try execBind("""
                UPDATE journal_feeds
                SET last_checked_at = ?, last_succeeded_at = ?, last_error = NULL,
                    etag = COALESCE(?, etag), last_modified = COALESCE(?, last_modified),
                    title = COALESCE(?, title),
                    item_count = (SELECT COUNT(*) FROM journal_feed_items WHERE feed_id = journal_feeds.id)
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                self.bind(stmt, 2, now.timeIntervalSinceReferenceDate)
                self.bind(stmt, 3, etag)
                self.bind(stmt, 4, lastModified)
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.bind(stmt, 5, (trimmed?.isEmpty ?? true) ? nil : trimmed)
                self.bind(stmt, 6, feedID)
            }
        } else {
            try execBind("UPDATE journal_feeds SET last_checked_at = ?, last_error = ? WHERE id = ?") { stmt in
                self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                self.bind(stmt, 2, error)
                self.bind(stmt, 3, feedID)
            }
        }
    }

    // MARK: - Items

    /// Stores the articles a fetch returned and reports the ones not seen
    /// before. Idempotent on the URL: re-fetching a feed adds nothing twice,
    /// and an article two feeds both carry stays one row.
    @discardableResult
    func recordJournalFeedItems(feedID: String, items: [ParsedJournalItem], now: Date = Date()) throws -> [JournalFeedItem] {
        guard !items.isEmpty else { return [] }
        var inserted: [JournalFeedItem] = []
        try exec("BEGIN IMMEDIATE")
        do {
            for parsed in items {
                let url = parsed.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                let authors = parsed.authors.isEmpty ? nil : parsed.authors.joined(separator: ", ")
                try execBind("""
                    INSERT OR IGNORE INTO journal_feed_items
                        (item_url, feed_id, title, summary, authors, doi, journal, published_at, first_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    self.bind(stmt, 1, url)
                    self.bind(stmt, 2, feedID)
                    self.bind(stmt, 3, parsed.title)
                    self.bind(stmt, 4, parsed.summary)
                    self.bind(stmt, 5, authors)
                    self.bind(stmt, 6, parsed.doi)
                    self.bind(stmt, 7, parsed.journal)
                    self.bind(stmt, 8, parsed.publishedAt?.timeIntervalSinceReferenceDate)
                    self.bind(stmt, 9, now.timeIntervalSinceReferenceDate)
                }
                if sqlite3_changes(db) > 0 {
                    inserted.append(JournalFeedItem(
                        itemURL: url,
                        feedID: feedID,
                        title: parsed.title,
                        summary: parsed.summary,
                        authors: authors,
                        doi: parsed.doi,
                        journal: parsed.journal,
                        publishedAt: parsed.publishedAt,
                        firstSeenAt: now,
                        judgedAt: nil
                    ))
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return inserted
    }

    /// Articles the matching call has not seen yet, oldest first.
    func loadUnjudgedJournalItems(limit: Int = 500) throws -> [JournalFeedItem] {
        var items: [JournalFeedItem] = []
        try queryBind("""
            SELECT item_url, feed_id, title, summary, authors, doi, journal, published_at, first_seen_at, judged_at
            FROM journal_feed_items
            WHERE judged_at IS NULL
            ORDER BY first_seen_at ASC
            LIMIT ?
        """, bind: { stmt in self.bind(stmt, 1, limit) }) { stmt in
            if let item = self.journalFeedItem(from: stmt) { items.append(item) }
        }
        return items
    }

    func markJournalItemsJudged(_ itemURLs: [String], at now: Date = Date()) throws {
        guard !itemURLs.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            for url in itemURLs {
                try execBind("UPDATE journal_feed_items SET judged_at = ? WHERE item_url = ?") { stmt in
                    self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                    self.bind(stmt, 2, url)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Drops judged articles older than the retention window that matched
    /// nothing. Bounded by the `judged_at` index; runs after a check.
    @discardableResult
    func pruneJournalItems(olderThan cutoff: Date) throws -> Int {
        try execBind("""
            DELETE FROM journal_feed_items
            WHERE judged_at IS NOT NULL AND judged_at < ?
              AND item_url NOT IN (SELECT item_url FROM journal_article_matches)
        """) { stmt in
            self.bind(stmt, 1, cutoff.timeIntervalSinceReferenceDate)
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Matches

    /// Files verdicts as pending suggestions. A verdict for a pair that already
    /// has a row — pending, accepted or dismissed — changes nothing.
    @discardableResult
    func recordJournalMatches(_ verdicts: [JournalArticleVerdict], at now: Date = Date()) throws -> [JournalArticleMatch] {
        guard !verdicts.isEmpty else { return [] }
        var recorded: [JournalArticleMatch] = []
        try exec("BEGIN IMMEDIATE")
        do {
            for verdict in verdicts {
                try execBind("""
                    INSERT OR IGNORE INTO journal_article_matches (item_url, notebook_id, reason, matched_at, state)
                    VALUES (?, ?, ?, ?, 'pending')
                """) { stmt in
                    self.bind(stmt, 1, verdict.itemID)
                    self.bind(stmt, 2, verdict.notebookID)
                    self.bind(stmt, 3, verdict.reason.isEmpty ? nil : verdict.reason)
                    self.bind(stmt, 4, now.timeIntervalSinceReferenceDate)
                }
                if sqlite3_changes(db) > 0 {
                    recorded.append(JournalArticleMatch(
                        itemURL: verdict.itemID,
                        notebookID: verdict.notebookID,
                        reason: verdict.reason.isEmpty ? nil : verdict.reason,
                        matchedAt: now,
                        state: .pending
                    ))
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return recorded
    }

    func setJournalMatchState(
        itemURL: String,
        notebookID: String,
        state: JournalArticleMatchState,
        sourceID: String? = nil,
        at now: Date = Date()
    ) throws {
        try execBind("""
            UPDATE journal_article_matches
            SET state = ?, decided_at = ?, source_id = COALESCE(?, source_id)
            WHERE item_url = ? AND notebook_id = ?
        """) { stmt in
            self.bind(stmt, 1, state.rawValue)
            self.bind(stmt, 2, now.timeIntervalSinceReferenceDate)
            self.bind(stmt, 3, sourceID)
            self.bind(stmt, 4, itemURL)
            self.bind(stmt, 5, notebookID)
        }
    }

    /// Pending suggestions, newest match first, joined with their article and
    /// feed. `notebookID` nil returns every Notebook's.
    func loadPendingJournalSuggestions(notebookID: String? = nil) throws -> [JournalArticleSuggestion] {
        var suggestions: [JournalArticleSuggestion] = []
        let sql = """
            SELECT m.item_url, m.notebook_id, m.reason, m.matched_at, m.state, m.decided_at, m.source_id,
                   i.item_url, i.feed_id, i.title, i.summary, i.authors, i.doi, i.journal, i.published_at, i.first_seen_at, i.judged_at,
                   COALESCE(f.title, '')
            FROM journal_article_matches m
            JOIN journal_feed_items i ON i.item_url = m.item_url
            LEFT JOIN journal_feeds f ON f.id = i.feed_id
            WHERE m.state = 'pending' \(notebookID == nil ? "" : "AND m.notebook_id = ?")
            ORDER BY m.matched_at DESC, i.published_at DESC
        """
        let handler: (OpaquePointer?) throws -> Void = { stmt in
            guard let match = self.journalArticleMatch(from: stmt),
                  let item = self.journalFeedItem(from: stmt, offset: 7) else { return }
            suggestions.append(JournalArticleSuggestion(
                match: match,
                item: item,
                feedTitle: self.string(stmt, 17) ?? ""
            ))
        }
        if let notebookID {
            try queryBind(sql, bind: { stmt in self.bind(stmt, 1, notebookID) }, handler)
        } else {
            try query(sql, handler)
        }
        return suggestions
    }

    func pendingJournalSuggestionCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try query("""
            SELECT notebook_id, COUNT(*) FROM journal_article_matches
            WHERE state = 'pending' GROUP BY notebook_id
        """) { stmt in
            if let notebookID = self.string(stmt, 0) {
                counts[notebookID] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return counts
    }

    /// Item URLs that already have a verdict for a Notebook, any state — the
    /// set the runner subtracts so a dismissed article is never re-offered.
    func journalMatchedItemURLs(notebookID: String) throws -> Set<String> {
        var urls = Set<String>()
        try queryBind("SELECT item_url FROM journal_article_matches WHERE notebook_id = ?", bind: { stmt in
            self.bind(stmt, 1, notebookID)
        }) { stmt in
            if let url = self.string(stmt, 0) { urls.insert(url) }
        }
        return urls
    }

    // MARK: - Notebook exclusions

    func journalWatchExcludedNotebookIDs() throws -> Set<String> {
        var ids = Set<String>()
        try query("SELECT notebook_id FROM journal_watch_excluded_notebooks") { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    func setJournalWatchNotebookExcluded(_ notebookID: String, excluded: Bool, at now: Date = Date()) throws {
        if excluded {
            try execBind("INSERT OR IGNORE INTO journal_watch_excluded_notebooks (notebook_id, excluded_at) VALUES (?, ?)") { stmt in
                self.bind(stmt, 1, notebookID)
                self.bind(stmt, 2, now.timeIntervalSinceReferenceDate)
            }
        } else {
            try execBind("DELETE FROM journal_watch_excluded_notebooks WHERE notebook_id = ?") { stmt in
                self.bind(stmt, 1, notebookID)
            }
        }
    }

    // MARK: - Library lookups

    /// Whether an announced article is already in the library, by URL or DOI.
    /// Deterministic identity, so a paper the learner saved yesterday is never
    /// offered back as new.
    func journalItemExistsInLibrary(url: String, doi: String?) -> Bool {
        if sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) != nil || sourceExistsByURL(url) != nil {
            return true
        }
        guard let doi, !doi.isEmpty else { return false }
        return !((try? searchPaperDOI(doi, limit: 1)) ?? []).isEmpty
    }

    // MARK: - Row readers

    private func journalFeed(from stmt: OpaquePointer?) -> JournalFeed? {
        guard let id = string(stmt, 0), let feedURL = string(stmt, 1), let title = string(stmt, 2) else { return nil }
        return JournalFeed(
            id: id,
            feedURL: feedURL,
            title: title,
            siteURL: string(stmt, 3),
            addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            lastCheckedAt: optionalDouble(stmt, 5).map { Date(timeIntervalSinceReferenceDate: $0) },
            lastSucceededAt: optionalDouble(stmt, 6).map { Date(timeIntervalSinceReferenceDate: $0) },
            lastError: string(stmt, 7),
            etag: string(stmt, 8),
            lastModified: string(stmt, 9),
            itemCount: Int(sqlite3_column_int64(stmt, 10))
        )
    }

    private func journalFeedItem(from stmt: OpaquePointer?, offset: Int = 0) -> JournalFeedItem? {
        guard let url = string(stmt, offset), let feedID = string(stmt, offset + 1), let title = string(stmt, offset + 2) else { return nil }
        return JournalFeedItem(
            itemURL: url,
            feedID: feedID,
            title: title,
            summary: string(stmt, offset + 3),
            authors: string(stmt, offset + 4),
            doi: string(stmt, offset + 5),
            journal: string(stmt, offset + 6),
            publishedAt: optionalDouble(stmt, offset + 7).map { Date(timeIntervalSinceReferenceDate: $0) },
            firstSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, Int32(offset + 8))),
            judgedAt: optionalDouble(stmt, offset + 9).map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }

    private func journalArticleMatch(from stmt: OpaquePointer?) -> JournalArticleMatch? {
        guard let itemURL = string(stmt, 0), let notebookID = string(stmt, 1) else { return nil }
        return JournalArticleMatch(
            itemURL: itemURL,
            notebookID: notebookID,
            reason: string(stmt, 2),
            matchedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            state: JournalArticleMatchState(rawValue: string(stmt, 4) ?? "") ?? .pending,
            decidedAt: optionalDouble(stmt, 5).map { Date(timeIntervalSinceReferenceDate: $0) },
            sourceID: string(stmt, 6)
        )
    }
}
