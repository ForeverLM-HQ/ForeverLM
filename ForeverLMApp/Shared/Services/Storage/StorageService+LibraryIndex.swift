// StorageService: the article archive mirror, book folder adoption, source index, reading list and user preferences.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Article archive mirror

    /// A couple of seconds after launch, build the device-local mirror of every
    /// saved article's archive that does not have one yet, so the first open of
    /// an older article does not wait on it. Already-mirrored archives cost one
    /// directory-metadata check each. Detached from the main actor.
    static func scheduleArticleArchiveWarmAfterLaunch() {
        #if os(macOS)
        Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            _ = await ArticleArchiveCache.shared.warmExistingArchives(
                canonicalArticlesRoot: URL(
                    fileURLWithPath: localContentRootPath,
                    isDirectory: true
                ).appendingPathComponent("Articles", isDirectory: true)
            )
        }
        #endif
    }

    // MARK: - Book folder adoption

    private static let bookFolderAdoptionDefaultsKey = "StorageService.didAdoptBookFolderNames.v1"
    private nonisolated(unsafe) static var bookFolderAdoptionIsRunning = false
    private static let bookFolderAdoptionLock = NSLock()

    /// The one directory imported books live in, under this instance's content
    /// root — the same place `importBook` writes and the store's relative
    /// `Books/…` paths resolve against.
    var booksDirectoryURL: URL {
        contentRoot.appendingPathComponent("Books", isDirectory: true)
    }

    /// Drop the archive tag from the book folders that were imported before
    /// `BookFolderNaming` existed, on disk and in every row that names them.
    ///
    /// Disk first, then rows, one book at a time. A folder that will not move
    /// keeps its rows; rows are rewritten only once the clean folder is really
    /// there, so at no point does a chapter URL name a folder that does not
    /// exist. The store's own enumeration of tagged references is the safety
    /// net for a run that stopped between the two halves.
    ///
    /// Bounded by the number of books, which is small everywhere, and by the
    /// number of chapter rows for the rewrite. Not a startup migration: it
    /// touches files, so it runs from the launch-time deferred pass below,
    /// off-main, and retires itself through UserDefaults once nothing tagged
    /// remains.
    func adoptTaggedBookFolders() throws -> BookFolderAdoption.Report {
        let fm = FileManager.default
        let booksDirectory = booksDirectoryURL
        var report = BookFolderAdoption.Report()

        for rename in BookFolderAdoption.plannedRenames(in: booksDirectory, fileManager: fm) {
            do {
                if try BookFolderAdoption.performRename(rename, in: booksDirectory, fileManager: fm) {
                    report.renamed.append(rename)
                } else {
                    report.skippedBecauseDestinationExists.append(rename.oldName)
                }
            } catch {
                report.failed.append(rename.oldName)
                migrationLogger.error(
                    "Book folder rename failed for \(rename.oldName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        try ensureStoreExists()
        let ks = try knowledgeStore()
        var taggedNames = try ks.referencedTaggedBookFolderNames()
        taggedNames.formUnion(report.renamed.map(\.oldName))
        for oldName in taggedNames.sorted() {
            let newName = BookFolderNaming.cleanedFolderName(fromFileBaseName: oldName)
            guard newName != oldName else { continue }
            let cleanFolder = booksDirectory.appendingPathComponent(newName, isDirectory: true).path
            let taggedFolder = booksDirectory.appendingPathComponent(oldName, isDirectory: true).path
            // Rows follow the folder. If the tagged folder is still there the
            // rename did not happen (or the clean name is taken by another
            // edition), and rewriting the rows would point them at the wrong
            // book. If neither exists there is nothing to point them at.
            guard !fm.fileExists(atPath: taggedFolder), fm.fileExists(atPath: cleanFolder) else {
                if !report.skippedBecauseDestinationExists.contains(oldName), !report.failed.contains(oldName) {
                    report.unresolvedReferences.append(oldName)
                }
                continue
            }
            report.rewrittenChapterCount += try ks.rewriteBookFolderReferences(from: oldName, to: newName)
        }

        if report.didChangeAnything {
            StudioArticle.invalidateAllResolvedPathCaches()
            // Observers of these are views and the view model, so the posts are
            // delivered on the main thread.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .syncedArtworkDidInstall, object: nil)
                // Rows changed underneath the view model's snapshot; this is the
                // same event an inbound CloudKit change raises, and it reloads
                // from the store rather than merely re-resolving cached paths.
                NotificationCenter.default.post(
                    name: .cloudKitSyncRemoteStoreDidChange,
                    object: nil,
                    userInfo: [
                        CloudKitSyncNotificationInfo.affectedEntitiesKey: [
                            CloudKitSyncEntity.source.rawValue,
                            CloudKitSyncEntity.book.rawValue,
                        ],
                        CloudKitSyncNotificationInfo.requiresFullRefreshKey: true,
                    ]
                )
            }
        }
        return report
    }

    /// Run `adoptTaggedBookFolders()` once per install, a few seconds after
    /// launch so first paint never waits on it. A complete run sets the
    /// defaults flag and later launches cost one `bool(forKey:)`; an incomplete
    /// one — a folder that would not move — runs again next launch.
    static func scheduleBookFolderAdoptionAfterLaunch(storage: StorageService) {
        guard !ForeverLMRuntimeIdentity.isTestHost else { return }
        guard !UserDefaults.standard.bool(forKey: bookFolderAdoptionDefaultsKey) else { return }
        Task.detached(priority: .utility) {
            let shouldProceed = bookFolderAdoptionLock.withLock { () -> Bool in
                if bookFolderAdoptionIsRunning { return false }
                bookFolderAdoptionIsRunning = true
                return true
            }
            guard shouldProceed else { return }
            defer { bookFolderAdoptionLock.withLock { bookFolderAdoptionIsRunning = false } }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "StorageMigration"
            )
            do {
                let report = try await storage.adoptTaggedBookFolders()
                if report.didChangeAnything {
                    logger.notice(
                        "Book folders: renamed \(report.renamed.count) folder(s), rewrote \(report.rewrittenChapterCount) chapter path(s)"
                    )
                }
                if report.isComplete {
                    UserDefaults.standard.set(true, forKey: bookFolderAdoptionDefaultsKey)
                } else {
                    logger.error(
                        "Book folders: \(report.skippedBecauseDestinationExists.count) skipped (clean name taken), \(report.failed.count) failed, \(report.unresolvedReferences.count) unresolved; will retry next launch"
                    )
                }
            } catch {
                logger.error("Book folder adoption failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Check whether a specific iCloud file is a placeholder (.icloud stub) and trigger
    /// its download if so. Returns true if the real file exists and is ready to read.
    func ensureICloudFileDownloaded(at url: URL) -> Bool {
        Self.ensureICloudFileDownloaded(at: url, fileManager: fileManager)
    }

    nonisolated static func ensureICloudFileDownloaded(at url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        // Check for .icloud placeholder: parent/.filename.icloud
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fileManager.fileExists(atPath: placeholder.path) {
            try? fileManager.startDownloadingUbiquitousItem(at: placeholder)
        }
        return false
    }

    // MARK: - Source Index

    /// Normalize a source path so that sources from different machines
    /// (different macOS usernames) or with different path formats (absolute vs relative)
    /// map to the same key. Uses `relativeSourcePath` so both `/Users/foo/.../Courses/X.pdf`
    /// and `Courses/X.pdf` normalize to `Courses/X.pdf`.
    /// Web URLs are returned unchanged.
    static func normalizedSourceKey(_ url: String) -> String {
        relativeSourcePath(url)
    }

    // MARK: - Reading List

    func loadSources() throws -> [StudioArticle] {
        try ensureStoreExists()
        return try knowledgeStore().loadSourcesWithoutContent()
    }

    /// Lenient batch read by id — returns only the rows that exist, skipping any
    /// missing ids instead of throwing. Use when a stale in-memory snapshot must
    /// be reconciled against the freshest persisted truth (e.g. metadata backfill).
    func loadPersistedSources(ids: [String]) throws -> [StudioArticle] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        var sources: [StudioArticle] = []
        var seen = Set<String>()
        for id in ids {
            let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, seen.insert(cleanID).inserted else { continue }
            if let source = try store.loadSourceForSync(cleanID) {
                sources.append(source)
            }
        }
        return sources
    }

    func loadSourcesForExport(sourceIDs: [String]) throws -> [StudioArticle] {
        try ensureStoreExists()
        let uniqueIDs = sourceIDs.reduce(into: [String]()) { result, sourceID in
            let cleanID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, !result.contains(cleanID) else { return }
            result.append(cleanID)
        }

        var sources: [StudioArticle] = []
        var missingIDs: [String] = []
        for sourceID in uniqueIDs {
            if let source = try knowledgeStore().loadSourceForSync(sourceID) {
                sources.append(source)
            } else {
                missingIDs.append(sourceID)
            }
        }
        guard missingIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("Could not export Notebook sources because \(missingIDs.count) linked source(s) could not be loaded: \(missingIDs.joined(separator: ", "))")
        }
        return sources
    }

    // MARK: - Dismissed Sources

    // MARK: - User preferences

    /// Persist a locally-changed preference and queue it for CloudKit.
    func writePreference(key: String, valuePlistXML: String) throws {
        try knowledgeStore().writePreference(key: key, valuePlistXML: valuePlistXML)
    }

    /// Clear a preference locally and tombstone it for CloudKit.
    func deletePreference(key: String) throws {
        try knowledgeStore().deletePreference(key: key)
    }

    /// Every stored preference as `key -> plist XML`, for rehydrating UserDefaults.
    func allPreferences() throws -> [String: String] {
        try knowledgeStore().loadAllPreferences()
    }

    /// Rewrite preference rows stored in a form hydration cannot read, and report
    /// what was repaired and what could not be.
    func repairUnreadablePreferences() throws -> KnowledgeStore.PreferenceRepairReport {
        try knowledgeStore().repairUnreadablePreferences()
    }

    func dismissSources(_ articles: [StudioArticle]) throws {
        try ensureStoreExists()
        let ks = try knowledgeStore()
        for article in articles {
            try ks.dismissSource(url: article.url, title: article.title)
            if let webURL = article.podcastWebPageURL {
                try ks.dismissSource(url: webURL, title: article.title)
            }
        }
        scheduleCloudKitSync(.immediate)
    }

    func loadDismissedSourceURLs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadDismissedSourceURLs()
    }

    /// Dismissal timestamps keyed by the stored URL.
    func loadDismissedSourceDates() throws -> [String: Date] {
        try ensureStoreExists()
        return try knowledgeStore().loadDismissedSourceDates()
    }

    func loadHiddenPodcastShows() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadHiddenPodcastShows()
    }

    /// Returns the ids of episodes an unhide revealed along with the show.
    @discardableResult
    func setPodcastShowHidden(_ showName: String, hidden: Bool) throws -> [String] {
        try ensureStoreExists()
        let revealed = try knowledgeStore().setPodcastShowHidden(showName, hidden: hidden)
        scheduleCloudKitSync(.immediate)
        return revealed
    }

    func loadHiddenYouTubeChannels() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadHiddenYouTubeChannels()
    }

    func setYouTubeChannelHidden(_ channelName: String, hidden: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setYouTubeChannelHidden(channelName, hidden: hidden)
        scheduleCloudKitSync(.immediate)
    }

    func loadHiddenPodcastEpisodeIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadHiddenPodcastEpisodeIDs()
    }

    func setPodcastEpisodeHidden(_ sourceID: String, hidden: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setPodcastEpisodeHidden(sourceID, hidden: hidden)
        scheduleCloudKitSync(.immediate)
    }

    func setSourceHidden(_ sourceID: String, hidden: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setSourceHidden(sourceID, hidden: hidden)
        scheduleCloudKitSync(.immediate)
    }

    func loadVisiblePodcastEpisodeOverrideIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadVisiblePodcastEpisodeOverrideIDs()
    }

    func setPodcastEpisodeVisibleOverride(_ sourceID: String, visible: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setPodcastEpisodeVisibleOverride(sourceID, visible: visible)
        scheduleCloudKitSync(.immediate)
    }

    func loadVisibleYouTubeVideoOverrideIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().loadVisibleYouTubeVideoOverrideIDs()
    }

    func setYouTubeVideoVisibleOverride(_ sourceID: String, visible: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().setYouTubeVideoVisibleOverride(sourceID, visible: visible)
        scheduleCloudKitSync(.immediate)
    }

}
