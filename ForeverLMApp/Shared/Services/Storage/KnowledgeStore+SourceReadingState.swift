// KnowledgeStore: reading position, watched state, hidden state and link lookups of a source.
import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    func updateSourceReadingPosition(sourceID: String, page: Int?) throws {
        try writeReadingPlace(sourceID: sourceID, page: .some(page))
        return
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
        try writeReadingPlace(sourceID: sourceID, macLocator: .some(locator))
        return
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
            try writeReadingPlace(sourceID: sourceID, macLocator: .some(next.locator), readAt: .some(next.readAt), at: date)
            if !watched { try updateReadingState(sourceID: sourceID) { self.resetReadingProgress(&$0) } }
            try exec("COMMIT")
            return VideoWatchedMark(locator: next.locator, readAt: next.readAt, changed: true)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadSourceReadingLocator(sourceID: String) throws -> String? {
        return try readingMacLocator(sourceID: sourceID)
    }

    /// The locator and read stamp a source has now, or nil when there is no
    /// such source: the two fields a video's watched state is made of.
    func loadSourceProgress(sourceID: String) throws -> (locator: String?, readAt: Date?)? {
        guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE id = ?)", [.text(sourceID)]) == 1 else { return nil }
        let row = try loadReadingState(sourceID: sourceID)
        return (ReadingLocatorCodec.macLocator(wire: row?.locator), row?.readAt.map(Date.init(timeIntervalSinceReferenceDate:)))
    }

    func updateSourceReadAt(sourceID: String, readAt: Date?) throws {
        // Marking it unread also starts the furthest progress over (§3.5.18).
        try updateReadingState(sourceID: sourceID) { row in
            row.readAt = readAt?.timeIntervalSinceReferenceDate
            if readAt == nil { self.resetReadingProgress(&row) }
        }
        if let readAt { try completeAssignedTasks(forSourceID: sourceID, at: readAt) }
        return
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
        noteStoreChanged()
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

}
