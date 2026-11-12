// StorageService: a course and its notebooks, archiving, deleting and importing sources.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - A course and its notebooks (docs/courses-design.md, "A course is its own thing")

    func screenRecordShownCourseIDs(scope: ScreenRecordScope) throws -> Set<String> {
        try knowledgeStore().screenRecordShownCourseIDs(scope: scope)
    }

    /// A notebook follows a course, validated: Link to Notebook, a course
    /// made or imported from a notebook, an MCP `notebook_id`
    /// (`KnowledgeStore.followCourse`). A personal notebook shared with teams
    /// passes the course's sources on, as any addition to it does
    /// (teams-design.md, decision 10). Returns how many sources joined.
    @discardableResult
    func followCourse(courseID: String, notebookID: String) throws -> Int {
        let store = try knowledgeStore()
        let added = try store.followCourse(courseID: courseID, notebookID: notebookID)
        scheduleCloudKitSync(.immediate)
        return added
    }

    /// "Make Study Notebook" on a course (`KnowledgeStore.makeStudyNotebook`).
    @discardableResult
    func makeStudyNotebook(courseID: String) throws -> CourseStudyNotebook {
        let store = try knowledgeStore()
        let made = try store.makeStudyNotebook(courseID: courseID)
        scheduleCloudKitSync(.immediate)
        return made
    }

    /// The notebook as `NotebookMembership` asks it, for a list filtered to it.
    func notebookMembership(notebookID: String) throws -> NotebookMembership {
        try knowledgeStore().notebookMembership(notebookID: notebookID)
    }

    /// Every course each notebook follows, keyed by course.
    func loadCourseFollowers() throws -> [String: [String]] {
        try knowledgeStore().loadCourseFollowers()
    }

    func setLearningGoalStatus(goalID: String, status: LearningGoalStatus) throws {
        try knowledgeStore().setLearningGoalStatus(goalID: goalID, status: status)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalDeadline(goalID: String, endAt: Date) throws {
        try knowledgeStore().setLearningGoalDeadline(goalID: goalID, endAt: endAt)
        scheduleCloudKitSync(.immediate)
    }

    func setLearningGoalParentNotebook(goalID: String, parentNotebookID: String?) throws {
        try knowledgeStore().setLearningGoalParentNotebook(goalID: goalID, parentNotebookID: parentNotebookID)
        scheduleCloudKitSync(.immediate)
    }

    /// Archive a source: mark as archived, delete content and embeddings,
    /// and drop it from both search indexes.
    func archiveSource(_ sourceId: String) throws {
        try knowledgeStore().archiveSource(sourceId)
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(sourceId)
    }

    /// Take every preprint's published DOI out of its work keys, so the journal
    /// version is no duplicate of it (`KnowledgeStore.removePublishedDOIWorkKeys`).
    @discardableResult
    func removePublishedDOIWorkKeys() throws -> Int {
        let removed = try knowledgeStore().removePublishedDOIWorkKeys()
        if removed > 0 { scheduleCloudKitSync(.immediate) }
        return removed
    }

    /// Collapse a deterministic paper duplicate without dropping relationships
    /// authored against the losing source id.
    func archivePaperIdentityDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try knowledgeStore().archivePaperIdentityDuplicate(
            duplicateID,
            replacingWith: canonicalID
        )
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(duplicateID)
    }

    /// Collapse a meeting session that a retired session-key rule filed twice,
    /// keeping every relationship authored against the losing session id.
    func archiveMeetingSessionDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try knowledgeStore().archiveMeetingSessionDuplicate(
            duplicateID,
            replacingWith: canonicalID
        )
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(duplicateID)
    }

    /// Permanently delete a source and propagate the deletion to CloudKit.
    func deleteSource(_ sourceId: String) throws {
        let explainerID = GeneratedExplainer.sourceID(explaining: sourceId)
        let hadExplainer = try knowledgeStore().loadSourceWithoutContent(explainerID) != nil
        // An audio overview's carrier takes its Artifact with it, in the
        // store's transaction; the Artifact's body directory goes here.
        let overviewID = try knowledgeStore().loadSourceWithoutContent(sourceId)
            .flatMap(GeneratedAudioOverview.artifactID(ofCarrier:))
        let overviewDirectory = try overviewID.flatMap { id in
            try knowledgeStore().loadArtifact(id) == nil ? nil : try artifactDirectoryURL(artifactID: id, createIfNeeded: false)
        }
        try knowledgeStore().deleteSource(sourceId)
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(sourceId)
        // The store deleted the source's explainer with it; its index rows go too.
        if hadExplainer {
            removeFromSearchIndexes(explainerID)
        }
        if let overviewDirectory {
            try? FileManager.default.removeItem(at: overviewDirectory)
        }
    }

    /// Drop a source from the in-memory vector index and from every search row the store keeps
    /// for it (`KnowledgeStore.dropSourceSearchRows`: full-text row, stamps, vectors), so an
    /// archived or deleted source stops surfacing in search now and after the next launch.
    func removeFromSearchIndexes(_ sourceId: String) {
        do {
            let ks = try knowledgeStore()
            SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: Self.sourceEmbeddingDimensions) { index in
                index.replace(
                    sourceID: sourceId,
                    chunks: [],
                    sourceIDForChunk: Self.sourceId(fromSourceChunkEmbeddingId:)
                )
            }
            try ks.dropSourceSearchRows(sourceID: sourceId)
        } catch {
            perfLogger.error("Failed to drop search index rows for \(sourceId, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Take out of search up to `limit` sources that are out of it yet still hold a part of it
    /// (`KnowledgeStore.sourcesOutOfSearchHoldingSearchRows`: archived or deleted by sync, indexed
    /// while being archived, or left by a writer that did not clear them), and return how many. Each one's rows go
    /// from the store; the vectors in memory go one source at a time for a few, and for more the
    /// index is dropped once and rebuilt from the store by the next search, since each removal
    /// rewrites the whole matrix.
    func dropSearchRowsOfSourcesOutOfSearch(limit: Int) throws -> Int {
        let ks = try knowledgeStore()
        let sourceIDs = try ks.sourcesOutOfSearchHoldingSearchRows(limit: limit)
        guard !sourceIDs.isEmpty else { return 0 }
        for sourceID in sourceIDs {
            try ks.dropSourceSearchRows(sourceID: sourceID)
        }
        SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: Self.sourceEmbeddingDimensions) { index in
            guard sourceIDs.count <= Self.searchSweepInPlaceRemovals else {
                index.invalidate()
                return
            }
            for sourceID in sourceIDs {
                index.replace(sourceID: sourceID, chunks: [], sourceIDForChunk: Self.sourceId(fromSourceChunkEmbeddingId:))
            }
        }
        return sourceIDs.count
    }

    /// Sources a sweep takes out of the vectors in memory one by one; more drop the index.
    static let searchSweepInPlaceRemovals = 4

    /// Check all active sources with local file paths.
    /// Archive any whose file no longer exists on disk.
    /// Returns the count of archived sources.
    func reconcileLocalFiles() throws -> Int {
        try ensureStoreExists()
        let ks = try knowledgeStore()
        let sources = try ks.loadActiveSources()
        let fm = FileManager.default
        var archivedCount = 0

        for source in sources {
            guard let filePath = source.localFilePath, !filePath.isEmpty else { continue }

            // Resolve through the app's single list of relocation rules rather
            // than a local existence check. This pass decides whether to archive
            // a source, so a rule it doesn't know about is a source it would
            // wrongly declare gone — a file iCloud hasn't downloaded yet is
            // present.
            if let located = Self.locateSourceFile(filePath) {
                if !fm.fileExists(atPath: located) {
                    try? fm.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: located))
                }
                continue
            }

            if Self.isAppManagedSourcePath(filePath) {
                continue
            }

            // If the source has a web URL, don't archive — just clear the local
            // file path. The web URL is still valid and the PDF can be re-downloaded.
            let sourceURL = source.url
            if sourceURL.hasPrefix("http://") || sourceURL.hasPrefix("https://") {
                var updated = source
                updated.localFilePath = nil
                try ks.saveSource(updated)
                continue
            }

            try ks.archiveSource(source.id)
            archivedCount += 1
        }

        return archivedCount
    }

    /// Save content for a source and update its state to 'ready'. See
    /// `KnowledgeStore.saveTranscript` for the podcast clean-up parameters.
    func saveTranscript(
        _ sourceId: String,
        _ text: String,
        rawTTML: String? = nil,
        podcastCleanupInput: String? = nil,
        podcastFormatting: PodcastTranscriptFormattingRequest? = nil,
        allowsShorterTranscript: Bool = false
    ) throws {
        try knowledgeStore().saveTranscript(
            sourceId,
            text,
            rawTTML: rawTTML,
            podcastCleanupInput: podcastCleanupInput,
            podcastFormatting: podcastFormatting,
            allowsShorterTranscript: allowsShorterTranscript
        )
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Move a podcast episode onto its public Apple Podcasts identity. See
    /// `KnowledgeStore.rebindPodcastEpisodeIdentity`.
    func rebindPodcastEpisodeIdentity(
        _ sourceId: String,
        toPublicURL publicURL: String,
        webPageURL: String?
    ) throws {
        try knowledgeStore().rebindPodcastEpisodeIdentity(
            sourceId,
            toPublicURL: publicURL,
            webPageURL: webPageURL
        )
        scheduleCloudKitSync()
        removeFromSearchIndexes(sourceId)
    }

    /// Fold a podcast row into the row that already holds its public identity.
    func archivePodcastEpisodeDuplicate(
        _ duplicateID: String,
        replacingWith canonicalID: String
    ) throws {
        try knowledgeStore().archivePodcastEpisodeDuplicate(
            duplicateID,
            replacingWith: canonicalID
        )
        scheduleCloudKitSync(.immediate)
        removeFromSearchIndexes(duplicateID)
    }

    func savePodcastYouTubeTranscript(
        _ sourceId: String,
        _ text: String,
        youtubeURL: String?,
        cleanupInput: String? = nil
    ) throws {
        try knowledgeStore().savePodcastYouTubeTranscript(
            sourceId,
            text,
            youtubeURL: youtubeURL,
            cleanupInput: cleanupInput
        )
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Load the original Apple Podcasts TTML for display-only transcript rendering.
    func loadPodcastRawTTML(_ sourceId: String) throws -> String? {
        try knowledgeStore().loadPodcastRawTTML(sourceId)
    }

    /// Return the set of Apple Podcasts track IDs that already have transcript content in the DB.
    func podcastTrackIdsWithContent() -> Set<Int64> {
        guard let store = try? knowledgeStore() else { return [] }
        return store.podcastTrackIdsWithContent()
    }

    /// Look up an existing source row by its normalized URL.
    func sourceRecordByNormalizedURL(_ normalizedURL: String) -> (id: String, status: SourceStatus)? {
        guard let store = try? knowledgeStore() else { return nil }
        return store.sourceExistsByNormalizedURL(normalizedURL)
    }

    /// Which of a doc's web references the library already holds, as address →
    /// active source id. An address with no active source is left out. The
    /// library is the Doc's: nil asks My Library, a team id asks that team's
    /// copies and nothing else.
    func librarySourceIDs(forReferenceURLs urls: [String], teamID: String? = nil) -> [String: String] {
        guard !urls.isEmpty, let store = try? knowledgeStore() else { return [:] }
        var matches: [String: String] = [:]
        for url in urls {
            if let id = store.activeSourceID(forReferenceURL: url, teamID: teamID) { matches[url] = id }
        }
        return matches
    }

    /// Look up an existing source row by its persisted URL.
    func sourceRecordByURL(_ url: String) -> (id: String, status: SourceStatus)? {
        guard let store = try? knowledgeStore() else { return nil }
        return store.sourceExistsByURL(url)
    }

    /// Resolve an imported book chapter to an existing source row, even when only
    /// the normalized URL or local file path matches.
    func existingImportedChapterRecord(for article: StudioArticle) -> (id: String, status: SourceStatus)? {
        guard let store = try? knowledgeStore() else { return nil }
        let normalizedURL = article.normalizedURL ?? URLNormalizer.normalize(article.url)
        if let match = store.sourceExistsByURL(article.url) { return match }
        if let match = store.sourceExistsByNormalizedURL(normalizedURL) { return match }
        if let localFilePath = article.localFilePath,
           let match = store.sourceExistsByBookLocalFilePath(localFilePath) {
            return match
        }
        // A chapter of a book kept as one file is addressed by its first page, so a re-import that
        // moved the chapter's start, or one of a book split into chapter files before, finds it by
        // its title among the chapters the re-import just archived: it keeps its id, and with it
        // its highlights, reading position and notebooks.
        if article.bookPages != nil, let bookID = article.parentGroup,
           let match = store.archivedBookChapter(bookID: bookID, title: article.title) {
            return match
        }
        return nil
    }

    func isSourceDismissed(url: String) -> Bool {
        guard let store = try? knowledgeStore() else { return false }
        return store.isSourceDismissed(url: url)
    }

    /// Persist the learner's explicit re-add intent before inserting the source.
    /// This writes a synced DismissedSource deletion even when this Mac has not
    /// received an older dismissal yet, preventing delayed CloudKit delivery
    /// from silently archiving the newly added row.
    func prepareExplicitSourceReAdd(_ url: String) throws {
        try ensureStoreExists()
        _ = try knowledgeStore().undismissSource(url: url)
        scheduleCloudKitSync(.immediate)
    }

    /// Bring back a source that a feed mirror had archived, for feeds where
    /// archived-ness is derived from the feed rather than chosen by the user —
    /// the YouTube Liked mirror archives on unlike, so a re-like has to be able
    /// to undo that. Without this, `insertSourceIfNew` refuses the re-insert
    /// (the row still exists) while every later lookup goes through
    /// `loadActiveSources`, which cannot see it: the video is dropped silently
    /// and never returns.
    ///
    /// Returns the revived source id, or nil when there is nothing to revive —
    /// no row, or already active.
    ///
    /// Pass `clearingDismissal: true` when the caller mirrors an explicit user
    /// action upstream rather than passive re-discovery. A dismissal normally
    /// blocks the revive, which is right for a feed that merely re-suggests a
    /// URL — but it made a re-liked video permanently unreachable, because
    /// dismissal also blocks `insertSourceIfNew`, so neither revive nor insert
    /// could bring the row back no matter how often the user liked it again.
    /// The caller owns the freshness check: it must pass `true` only after
    /// establishing that the upstream action is *newer* than the dismissal (the
    /// liked sync compares each entry's `likedAt` against `dismissed_at`). A
    /// video merely still liked from before an in-app removal must never clear
    /// the tombstone — that would resurrect the removal on every sync.
    func unarchiveSourceMatchingURL(_ url: String, clearingDismissal: Bool = false) throws -> String? {
        try ensureStoreExists()
        let store = try knowledgeStore()
        var clearedDismissal = false
        if store.isSourceDismissed(url: url) {
            guard clearingDismissal else { return nil }
            clearedDismissal = try !store.undismissSource(url: url).isEmpty
        }
        let normalizedURL = URLNormalizer.normalize(url)
        guard let match = store.sourceExistsByNormalizedURL(normalizedURL) ?? store.sourceExistsByURL(url),
              match.status == .archived else {
            // No row survived to revive, but a cleared tombstone is itself a
            // change worth syncing — and it unblocks the caller's re-insert.
            if clearedDismissal { scheduleCloudKitSync() }
            return nil
        }
        try store.unarchiveSource(match.id)
        scheduleCloudKitSync()
        return match.id
    }

    /// Update a source's parent_group (set to NULL if group is nil).
    func updateParentGroup(_ sourceId: String, _ group: String?) throws {
        try knowledgeStore().updateParentGroup(sourceId, group)
        scheduleCloudKitSync()
    }

    func mergeMeetingGroup(_ sourceGroupID: String, into targetGroupID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().mergeMeetingGroup(sourceGroupID, into: targetGroupID)
        scheduleCloudKitSync(.immediate)
    }

}
