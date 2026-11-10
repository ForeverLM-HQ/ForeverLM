// KnowledgeStore: dismissed sources, hidden shows, channels and episodes, and source types.
import Foundation
import SQLite3

extension KnowledgeStore {

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
        if !affectedOverrideIDs.isEmpty {
            noteStoreChanged()
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
        if !affectedOverrideIDs.isEmpty {
            noteStoreChanged()
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
        noteStoreChanged()
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
        noteStoreChanged()
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
        } else {
            try execBind("DELETE FROM visible_podcast_episode_overrides WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
        }
        try execBind("DELETE FROM podcast_transcript_cleanup_queue WHERE source_id = ?") { stmt in
            bind(stmt, 1, trimmed)
        }
        try enqueuePodcastTranscriptCleanupIfNeeded(sourceID: trimmed)
        noteStoreChanged()
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
        } else {
            try execBind("DELETE FROM visible_youtube_video_overrides WHERE source_id = ?") { stmt in
                bind(stmt, 1, key)
            }
        }
        noteStoreChanged()
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

}
