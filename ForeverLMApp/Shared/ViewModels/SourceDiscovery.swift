import AppKit
import Foundation
import CryptoKit
import OSLog
import SQLite3
import WebKit

// MARK: - Source Discovery (testable static functions)

/// Pure parsing and lookup functions extracted from StudioViewModel for testability.
enum SourceDiscovery {

    // MARK: - Publisher security checks

    /// Whether a page is a publisher bot check rather than the document.
    /// Re-exported from the browser downloader that owns the detection, so
    /// ingestion paths can ask the question without reaching through a
    /// WebView download service to do it.
    nonisolated static func isSecurityVerificationPage(
        title: String,
        visibleText: String,
        url: String
    ) -> Bool {
        PaperAIBrowserDownloadService.isSecurityVerificationPage(
            title: title,
            visibleText: visibleText,
            url: url
        )
    }

    /// Longest text still small enough to be a bot-check interstitial rather
    /// than a document. The real ones this library collected are 340–470
    /// characters; the shortest genuine paper text in it is ~700. The ceiling
    /// sits well above both, so a wall is caught and a short abstract is not.
    nonisolated static let securityVerificationContentCeiling = 2_000

    /// Whether text about to be stored as a source's body is a publisher bot
    /// check rather than the document.
    ///
    /// Deliberately stricter than `isSecurityVerificationPage`. That one judges
    /// a live page mid-navigation, where a match only means "keep waiting" and a
    /// false positive costs a second. This one gates persistence, where a false
    /// positive discards a real document — so a match additionally requires the
    /// text to be far too short to be one. Without that, a paper *about* bot
    /// detection or CAPTCHAs would match on its own subject matter.
    nonisolated static func isSecurityVerificationContent(
        text: String,
        title: String,
        url: String
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= securityVerificationContentCeiling else { return false }
        return isSecurityVerificationPage(title: title, visibleText: trimmed, url: url)
    }

    /// A single reading list entry parsed from a plist or JSON file.
    struct ReadingListEntry {
        let url: String
        let title: String
        let dateAdded: Date?
        let imageURL: String?
        var isRead: Bool = false
        var dateLastViewed: Date?

        init(url: String, title: String, dateAdded: Date?, imageURL: String?, isRead: Bool = false, dateLastViewed: Date? = nil) {
            self.url = url
            self.title = title.decodingHTMLCharacterReferences()
            self.dateAdded = dateAdded
            self.imageURL = imageURL
            self.isRead = isRead
            self.dateLastViewed = dateLastViewed
        }
    }

    // MARK: - Reading List import window

    /// How far back the Reading List import reaches, chosen in Setup's
    /// Articles step (product owner, 2026-09-24). A browser's Reading List can hold
    /// years of saved pages, and every one of them is fetched, classified and
    /// cleaned up once imported; the learner decides whether that backlog
    /// comes in, only its recent part, or nothing but what they save from now
    /// on. Stored as the earliest saved date a new Reading List page may carry
    /// to be imported; absent means everything, as before Setup asked. Per
    /// Mac, like the browser choice it qualifies.
    enum ReadingListImportWindow: String, CaseIterable, Identifiable, Sendable {
        case everything
        case lastMonth
        case fromNowOn

        static let sinceKey = "readingList.importSince"
        /// Which option set `sinceKey`, so Setup and Settings show it.
        static let windowKey = "readingList.importWindow"
        static let recentDays = 30

        var id: String { rawValue }

        /// The saved date a page must reach to be imported, measured from
        /// `now`; nil imports every page.
        func cutoff(now: Date = Date()) -> Date? {
            switch self {
            case .everything: return nil
            case .lastMonth: return Calendar.current.date(byAdding: .day, value: -Self.recentDays, to: now)
            case .fromNowOn: return now
            }
        }

        static var storedCutoff: Date? {
            let seconds = UserDefaults.standard.double(forKey: sinceKey)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }

        var title: String {
            switch self {
            case .everything: return "Everything"
            case .lastMonth: return "Last \(Self.recentDays) days"
            case .fromNowOn: return "Only new saves"
            }
        }

        /// The option last chosen, or nil when none was: then every page is
        /// imported, as it was before Setup asked.
        static var chosen: ReadingListImportWindow? {
            UserDefaults.standard.string(forKey: windowKey).flatMap(ReadingListImportWindow.init(rawValue:))
        }

        /// Choose how far back the import reaches, measured from now. The one
        /// writer for Setup, Settings and `set_app_setting`.
        static func choose(_ window: ReadingListImportWindow, now: Date = Date()) {
            UserDefaults.standard.set(window.rawValue, forKey: windowKey)
            if let cutoff = window.cutoff(now: now) {
                UserDefaults.standard.set(cutoff.timeIntervalSince1970, forKey: sinceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sinceKey)
            }
        }

        /// Whether moving from one option to another reaches pages the last
        /// sync left behind, so a sync has to run again.
        static func widens(from old: ReadingListImportWindow?, to new: ReadingListImportWindow) -> Bool {
            func rank(_ window: ReadingListImportWindow?) -> Int {
                switch window {
                case nil, .everything?: return 0
                case .lastMonth?: return 1
                case .fromNowOn?: return 2
                }
            }
            return rank(new) < rank(old)
        }

        /// The pages a sync may add: those saved on or after the cutoff. A
        /// page the browser recorded no saved date for carries the time it was
        /// read, so it counts as new; Safari and Chromium both date every
        /// entry they write today.
        static func admitting<Source>(
            _ sources: [Source],
            cutoff: Date?,
            savedAt: (Source) -> Date
        ) -> [Source] {
            guard let cutoff else { return sources }
            return sources.filter { savedAt($0) >= cutoff }
        }
    }

    // MARK: - Safari Reading List

    /// Parse Safari Reading List entries from Bookmarks.plist binary data.
    static func parseSafariReadingList(data: Data) -> [ReadingListEntry] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let children = plist["Children"] as? [[String: Any]],
              let readingListNode = children.first(where: { ($0["Title"] as? String) == "com.apple.ReadingList" }),
              let items = readingListNode["Children"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let urlString = item["URLString"] as? String else { return nil }
            let readingListInfo = item["ReadingList"] as? [String: Any]
            let title = (item["URIDictionary"] as? [String: Any])?["title"] as? String
                ?? readingListInfo?["PreviewText"] as? String
                ?? urlString
            let dateAdded = readingListInfo?["DateAdded"] as? Date
            let imageURL = item["imageURL"] as? String
            let dateLastViewed = readingListInfo?["DateLastViewed"] as? Date
            let isRead = dateLastViewed != nil
            return ReadingListEntry(url: urlString, title: title, dateAdded: dateAdded, imageURL: imageURL, isRead: isRead, dateLastViewed: dateLastViewed)
        }
    }

    // MARK: - Chrome / Brave Reading List

    /// Parse Chrome/Brave reading list entries from Bookmarks JSON data.
    static func parseChromeBookmarks(data: Data) -> [ReadingListEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any],
              let readingList = roots["reading_list"] as? [String: Any] else {
            return []
        }

        var entries: [ReadingListEntry] = []
        collectChromeReadingListEntries(from: readingList, into: &entries)
        return entries
    }

    /// Chromium stores reading list in slightly different nested folder layouts
    /// across browser versions, so we recursively collect all URL nodes.
    private static func collectChromeReadingListEntries(from node: [String: Any], into entries: inout [ReadingListEntry]) {
        if let urlString = node["url"] as? String {
            let title = node["name"] as? String ?? urlString

            var dateAdded: Date?
            if let dateAddedStr = node["date_added"] as? String,
               let microseconds = Int64(dateAddedStr) {
                // Chrome stores dates as microseconds since 1601-01-01 (Windows FILETIME)
                let windowsToUnixOffset: Int64 = 11_644_473_600_000_000
                let unixMicroseconds = microseconds - windowsToUnixOffset
                dateAdded = Date(timeIntervalSince1970: Double(unixMicroseconds) / 1_000_000)
            }

            entries.append(ReadingListEntry(url: urlString, title: title, dateAdded: dateAdded, imageURL: nil))
        }

        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            collectChromeReadingListEntries(from: child, into: &entries)
        }
    }

    // MARK: - Chromium Sync Data Reading List

    /// Reading-list entries from a Chromium profile's `Sync Data/LevelDB` store,
    /// where Chrome (2024+) and Brave keep them. `ChromiumReadingListStore`
    /// reads the store as the LevelDB it is, so removed entries stay removed,
    /// compacted tables are still read, and each entry arrives with the title,
    /// saved date and read state the browser recorded — the same fields a
    /// Safari Reading List entry carries.
    static func parseChromiumSyncReadingList(syncDir: String) -> [ReadingListEntry] {
        ChromiumReadingListStore.entries(inSyncDirectory: syncDir).map { entry in
            ReadingListEntry(
                url: entry.url,
                title: entry.title,
                dateAdded: entry.creationTime,
                imageURL: nil,
                isRead: entry.isRead,
                dateLastViewed: entry.firstReadTime
            )
        }
    }

    // MARK: - Firefox Bookmarks

    /// Parse all Firefox bookmarks from places.sqlite.
    /// Firefox has no reading list — we import all bookmarks.
    static func parseFirefoxBookmarks(dbPath: String) -> [ReadingListEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT b.title, p.url, b.dateAdded
            FROM moz_bookmarks b
            JOIN moz_places p ON b.fk = p.id
            WHERE b.type = 1
              AND p.url NOT LIKE 'place:%'
            ORDER BY b.dateAdded
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var entries: [ReadingListEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlCStr = sqlite3_column_text(stmt, 1) else { continue }
            let url = String(cString: urlCStr)
            guard !url.isEmpty else { continue }

            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? url

            var dateAdded: Date?
            let us = sqlite3_column_int64(stmt, 2)
            if us > 0 {
                dateAdded = Date(timeIntervalSince1970: Double(us) / 1_000_000)
            }

            entries.append(ReadingListEntry(url: url, title: title, dateAdded: dateAdded, imageURL: nil))
        }
        return entries
    }

    // MARK: - DuckDuckGo Bookmarks

    /// Parse all DuckDuckGo bookmarks from Bookmarks.sqlite (CoreData).
    /// DuckDuckGo has no reading list — we import all bookmarks.
    static func parseDuckDuckGoBookmarks(dbPath: String) -> [ReadingListEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT ZTITLE, ZURL, ZMODIFIEDAT
            FROM ZBOOKMARKENTITY
            WHERE ZISFOLDER = 0
              AND (ZISPENDINGDELETION IS NULL OR ZISPENDINGDELETION = 0)
              AND ZURL IS NOT NULL
            ORDER BY Z_PK
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var entries: [ReadingListEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlCStr = sqlite3_column_text(stmt, 1) else { continue }
            let url = String(cString: urlCStr)
            guard !url.isEmpty else { continue }

            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? url

            var dateAdded: Date?
            let raw = sqlite3_column_double(stmt, 2)
            if raw > 0 {
                // CoreData NSDate epoch: seconds since 2001-01-01
                dateAdded = Date(timeIntervalSinceReferenceDate: raw)
            }

            entries.append(ReadingListEntry(url: url, title: title, dateAdded: dateAdded, imageURL: nil))
        }
        return entries
    }

    // MARK: - URL Normalization

    /// Normalize a URL for cross-browser deduplication.
    /// Delegates to URLNormalizer for canonical, deterministic normalization.
    static func normalizedURL(_ urlString: String) -> String {
        URLNormalizer.normalize(urlString)
    }

    // MARK: - TTML Store Track ID

    /// Extract the Apple Podcasts store track ID from a TTML filename.
    /// Filenames follow the pattern: `transcript_{STORE_TRACK_ID}.ttml-{STORE_TRACK_ID}.ttml`
    static func storeTrackId(fromTTMLPath path: String) -> Int64? {
        let filename = (path as NSString).lastPathComponent
        // Match the first numeric ID after "transcript_"
        guard let regex = try? NSRegularExpression(pattern: #"transcript_(\d+)\.ttml"#),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename),
              let id = Int64(filename[range]) else {
            return nil
        }
        return id
    }

    /// Stable placeholder URL for an Apple Podcasts episode.
    static func podcastEpisodePlaceholderURL(trackId: Int64) -> String {
        "apple-podcast://episode/\(trackId)"
    }

    /// Stable source URL for Apple Podcasts episodes.
    /// Public catalog episodes use their store track ID. Private RSS episodes often
    /// have no store ID, so prefer stable feed fields before Apple's local UUID.
    static func podcastEpisodeURL(for meta: PodcastEpisodeMetadata) -> String? {
        if let trackId = meta.storeTrackId, trackId > 0 {
            return podcastEpisodePlaceholderURL(trackId: trackId)
        }
        let privateSeed = [meta.episodeGUID, meta.enclosureURL]
            .compactMap { cleanedIdentifier($0) }
            .first
        if let privateSeed {
            let digest = SHA256.hash(data: Data(privateSeed.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "apple-podcast://episode/private/\(digest)"
        }
        if let uuid = cleanedIdentifier(meta.episodeUUID) {
            return "apple-podcast://episode/local/\(uuid.lowercased())"
        }
        return nil
    }

    private static func cleanedIdentifier(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
    // MARK: - Artwork URL

    /// Resolve an Apple Podcasts artwork template URL to a concrete image URL.
    /// Templates contain `{w}x{h}bb.{f}` which we replace with actual dimensions and format.
    static func resolveArtworkURL(template: String, width: Int = 100, height: Int = 100) -> String? {
        guard !template.isEmpty else { return nil }
        return template
            .replacingOccurrences(of: "{w}", with: "\(width)")
            .replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{f}", with: "jpg")
            .replacingOccurrences(of: "{c}", with: "bb")
    }

    // MARK: - Apple Podcasts SQLite Metadata Lookup


    /// Apple Podcasts database layouts we can read.
    enum PodcastSchemaLayout {
        /// Transcript, enclosure, download, and description fields live directly on ZMTEPISODE.
        case legacy
        /// macOS 26.x normalized the store: descriptions moved to ZMTEPISODEDESCRIPTION and
        /// enclosure/transcript/download fields moved to ZMTMEDIAENCLOSURE, both referenced
        /// from ZMTEPISODE via ZDESCRIPTIONOBJECT / ZCURRENTMEDIAENCLOSURE.
        case modern
    }

    /// Tables and columns required in every supported layout.
    /// If Apple changes the schema beyond the known layouts, `validateSchema` will
    /// catch it and report exactly what's missing instead of silently returning empty results.
    private static let sharedRequiredColumns: [(table: String, columns: [String])] = [
        ("ZMTEPISODE", ["ZSTORETRACKID", "ZTITLE", "ZWEBPAGEURL",
                        "ZLASTDATEPLAYED", "ZPLAYSTATELASTMODIFIEDDATE", "ZPLAYSTATE",
                        "ZPLAYHEAD", "ZHASBEENPLAYED", "ZPLAYCOUNT", "ZLISTENNOWEPISODE",
                        "ZISBOOKMARKED", "ZUSERDELETED",
                        "ZPODCAST", "ZARTWORKTEMPLATEURL",
                        "ZUUID", "ZGUID"]),
        ("ZMTPODCAST", ["Z_PK", "ZTITLE", "ZARTWORKTEMPLATEURL", "ZIMAGEURL", "ZSUBSCRIBED", "ZISIMPLICITLYFOLLOWED"])
    ]

    /// ZMTEPISODE columns that only exist in the legacy layout.
    private static let legacyEpisodeColumns = [
        "ZTRANSCRIPTIDENTIFIER", "ZDOWNLOADDATE", "ZDOWNLOADPATH",
        "ZITEMDESCRIPTIONWITHOUTHTML", "ZITEMDESCRIPTION", "ZITUNESSUBTITLE", "ZENCLOSUREURL"
    ]

    /// Tables and columns that only exist in the modern layout.
    private static let modernRequiredColumns: [(table: String, columns: [String])] = [
        ("ZMTEPISODE", ["ZCURRENTMEDIAENCLOSURE", "ZDESCRIPTIONOBJECT"]),
        ("ZMTMEDIAENCLOSURE", ["Z_PK", "ZTRANSCRIPTIDENTIFIER", "ZREMOTEURL", "ZDOWNLOADDATE", "ZLOCALURL"]),
        ("ZMTEPISODEDESCRIPTION", ["Z_PK", "ZPLAINTEXT", "ZTEXT"])
    ]

    /// Layout-specific SQL fragments. `e` is ZMTEPISODE, `p` is ZMTPODCAST;
    /// the modern layout adds `enc` (ZMTMEDIAENCLOSURE) and `d` (ZMTEPISODEDESCRIPTION).
    struct PodcastSQLFragments {
        let joins: String
        let transcriptIdentifier: String
        let enclosureURL: String
        let episodeDescription: String
        let downloadDate: String
        let downloadPath: String

        init(layout: PodcastSchemaLayout) {
            switch layout {
            case .legacy:
                joins = ""
                transcriptIdentifier = "e.ZTRANSCRIPTIDENTIFIER"
                enclosureURL = "e.ZENCLOSUREURL"
                episodeDescription = "COALESCE(NULLIF(e.ZITEMDESCRIPTIONWITHOUTHTML, ''), NULLIF(e.ZITUNESSUBTITLE, ''), NULLIF(e.ZITEMDESCRIPTION, ''))"
                downloadDate = "e.ZDOWNLOADDATE"
                downloadPath = "e.ZDOWNLOADPATH"
            case .modern:
                joins = """
                    LEFT JOIN ZMTMEDIAENCLOSURE enc ON e.ZCURRENTMEDIAENCLOSURE = enc.Z_PK
                    LEFT JOIN ZMTEPISODEDESCRIPTION d ON e.ZDESCRIPTIONOBJECT = d.Z_PK
                """
                transcriptIdentifier = "enc.ZTRANSCRIPTIDENTIFIER"
                enclosureURL = "enc.ZREMOTEURL"
                episodeDescription = "COALESCE(NULLIF(d.ZPLAINTEXT, ''), NULLIF(d.ZTEXT, ''))"
                downloadDate = "enc.ZDOWNLOADDATE"
                downloadPath = "enc.ZLOCALURL"
            }
        }
    }

    private static func tableColumns(db: OpaquePointer?, table: String) -> Set<String>? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    /// Verify that the Apple Podcasts database matches a supported layout.
    /// Returns the detected layout with `.ok`, or `nil` with `.schemaChanged` details.
    static func validateSchema(db: OpaquePointer?) -> (layout: PodcastSchemaLayout?, status: PodcastDiscoveryStatus) {
        var episodeColumns: Set<String> = []
        for (table, expectedCols) in sharedRequiredColumns {
            guard let foundColumns = tableColumns(db: db, table: table) else {
                return (nil, .schemaChanged(details: "Cannot inspect table '\(table)'"))
            }
            if foundColumns.isEmpty {
                return (nil, .schemaChanged(details: "Table '\(table)' does not exist"))
            }
            let missing = expectedCols.filter { !foundColumns.contains($0) }
            if !missing.isEmpty {
                return (nil, .schemaChanged(details: "Table '\(table)' missing columns: \(missing.joined(separator: ", "))"))
            }
            if table == "ZMTEPISODE" {
                episodeColumns = foundColumns
            }
        }

        if legacyEpisodeColumns.allSatisfy(episodeColumns.contains) {
            return (.legacy, .ok)
        }

        var modernProblems: [String] = []
        for (table, expectedCols) in modernRequiredColumns {
            guard let foundColumns = tableColumns(db: db, table: table), !foundColumns.isEmpty else {
                modernProblems.append("table '\(table)' does not exist")
                continue
            }
            let missing = expectedCols.filter { !foundColumns.contains($0) }
            if !missing.isEmpty {
                modernProblems.append("'\(table)' missing columns: \(missing.joined(separator: ", "))")
            }
        }
        if modernProblems.isEmpty {
            return (.modern, .ok)
        }
        return (nil, .schemaChanged(details: "No supported episode layout: \(modernProblems.joined(separator: "; "))"))
    }

    /// Try to open the Apple Podcasts database read-only.
    /// Returns the db pointer, detected schema layout, and `.ok`, or `nil` with the appropriate status.
    static func openPodcastsDB(at path: String) -> (db: OpaquePointer?, layout: PodcastSchemaLayout?, status: PodcastDiscoveryStatus) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return (nil, nil, .appNotInstalled)
        }

        // This is deliberately a non-prompting TCC gate. Background discovery
        // must never provoke macOS's "access data from other apps" dialog; the
        // user-controlled Full Disk Access flow handles the permission instead.
        // Opening SQLite directly when this check is false causes macOS to
        // present that modal again on later refresh events.
        guard fm.isReadableFile(atPath: path) else {
            return (nil, nil, .permissionDenied)
        }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK else {
            let errMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            let systemErrno = db.map { sqlite3_system_errno($0) } ?? 0
            Logger(subsystem: "com.foreverlm", category: "Studio")
                .warning("Podcasts DB open failed: rc=\(rc), errno=\(systemErrno) (\(errMsg))")
            if let db { sqlite3_close(db) }
            if rc == SQLITE_PERM || rc == SQLITE_AUTH || systemErrno == EACCES || systemErrno == EPERM {
                return (nil, nil, .permissionDenied)
            }
            return (nil, nil, .openFailed(details: errMsg))
        }

        let (layout, schemaStatus) = validateSchema(db: db)
        guard let layout, schemaStatus == .ok else {
            sqlite3_close(db)
            return (nil, nil, schemaStatus)
        }

        return (db, layout, .ok)
    }

    /// Parse a row from the standard episode metadata query into PodcastEpisodeMetadata.
    private static func parseEpisodeRow(stmt: OpaquePointer?) -> (trackId: Int64, meta: PodcastEpisodeMetadata) {
        let rawTrackId = sqlite3_column_int64(stmt, 0)
        let trackId = rawTrackId > 0 ? rawTrackId : 0
        let storeTrackId: Int64? = rawTrackId > 0 ? rawTrackId : nil
        let episodeTitle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Unknown Episode"
        let podcastName = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Unknown Podcast"
        let artworkTemplate = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let webPageURL = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let ttmlId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        // Core Data timestamps are seconds since 2001-01-01
        let lastPlayedTS = sqlite3_column_double(stmt, 6)
        let lastPlayed: Date? = lastPlayedTS > 0 ? Date(timeIntervalSinceReferenceDate: lastPlayedTS) : nil
        let collectionId = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7) as Int64?
        let episodeUUID = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let episodeGUID = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let episodeDescription = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let enclosureURL = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        // The publish date is the twelfth column of the shared projection; the
        // track-id lookup's older SELECT stops at the enclosure, so read it only
        // when the statement carries it.
        var publishedAt: Date?
        if sqlite3_column_count(stmt) > 12, sqlite3_column_type(stmt, 12) != SQLITE_NULL {
            let publishedTS = sqlite3_column_double(stmt, 12)
            if publishedTS > 0 { publishedAt = Date(timeIntervalSinceReferenceDate: publishedTS) }
        }
        let artworkURL = artworkTemplate.flatMap { resolveArtworkURL(template: $0) }
        return (trackId, PodcastEpisodeMetadata(
            storeTrackId: storeTrackId,
            episodeUUID: episodeUUID,
            episodeGUID: episodeGUID,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            artworkURL: artworkURL,
            webPageURL: webPageURL,
            episodeDescription: episodeDescription,
            enclosureURL: enclosureURL,
            ttmlIdentifier: ttmlId,
            lastDatePlayed: lastPlayed,
            podcastCollectionId: collectionId,
            publishedAt: publishedAt
        ))
    }

    /// Query the Apple Podcasts database for episode metadata matching the given store track IDs.
    static func lookupPodcastMetadata(dbPath: String, storeTrackIds: [Int64]) -> [Int64: PodcastEpisodeMetadata] {
        guard !storeTrackIds.isEmpty else { return [:] }

        let (db, layout, status) = openPodcastsDB(at: dbPath)
        guard let db, let layout, status == .ok else { return [:] }
        defer { sqlite3_close(db) }

        var results: [Int64: PodcastEpisodeMetadata] = [:]

        let cols = PodcastSQLFragments(layout: layout)
        let placeholders = storeTrackIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT e.ZSTORETRACKID, e.ZTITLE, p.ZTITLE,
                   COALESCE(p.ZARTWORKTEMPLATEURL, p.ZIMAGEURL, e.ZARTWORKTEMPLATEURL),
                   e.ZWEBPAGEURL, \(cols.transcriptIdentifier), e.ZLASTDATEPLAYED,
                   p.ZSTORECOLLECTIONID, e.ZUUID, e.ZGUID,
                   \(cols.episodeDescription),
                   \(cols.enclosureURL)
            FROM ZMTEPISODE e
            JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
            \(cols.joins)
            WHERE e.ZSTORETRACKID IN (\(placeholders))
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        for (i, trackId) in storeTrackIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), trackId)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let (trackId, meta) = parseEpisodeRow(stmt: stmt)
            results[trackId] = meta
        }

        return results
    }

    private static func podcastDiscoveryCutoffTimestamp() -> TimeInterval {
        DateComponents(calendar: .init(identifier: .gregorian), year: 2026, month: 1, day: 1).date!.timeIntervalSinceReferenceDate
    }

    private static func sqlNumber(_ value: TimeInterval) -> String {
        String(format: "%.6f", value)
    }

    private static func podcastImportPredicate(for scope: ApplePodcastDiscoveryScope, columns cols: PodcastSQLFragments) -> String {
        let cutoff = sqlNumber(podcastDiscoveryCutoffTimestamp())
        let listened = """
            (
                e.ZLASTDATEPLAYED > \(cutoff)
                OR (
                    e.ZLASTDATEPLAYED IS NULL
                    AND
                    COALESCE(e.ZPLAYSTATELASTMODIFIEDDATE, 0) > \(cutoff)
                    AND COALESCE(e.ZPLAYHEAD, 0) > 0
                )
            )
        """

        switch scope {
        case .listened:
            return listened
        case .downloadedOrListened:
            return """
                (
                    \(listened)
                    OR COALESCE(\(cols.downloadDate), 0) > \(cutoff)
                    OR NULLIF(\(cols.downloadPath), '') IS NOT NULL
                )
            """
        case .completed:
            return """
                (
                    e.ZLASTDATEPLAYED > \(cutoff)
                    AND (
                        COALESCE(e.ZPLAYSTATE, 0) = 2
                        OR COALESCE(e.ZPLAYCOUNT, 0) > 0
                        OR COALESCE(e.ZHASBEENPLAYED, 0) = 1
                    )
                )
            """
        }
    }

    /// Search Apple Podcasts' local catalog cache for transcript-capable episodes.
    /// This is intentionally query-gated so ForeverLM can surface specific episodes
    /// a learner asks for without importing the user's entire podcast catalog.
    static func searchPodcastCatalogEpisodes(
        dbPath: String,
        query: String,
        limit: Int = 25,
        scope: ApplePodcastDiscoveryScope = .current
    ) -> (episodes: [PodcastEpisodeMetadata], status: PodcastDiscoveryStatus) {
        let tokens = Array(query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
            .prefix(6))
        guard !tokens.isEmpty else { return ([], .noEpisodesFound) }

        let (db, layout, status) = openPodcastsDB(at: dbPath)
        guard let db, let layout, status == .ok else { return ([], status) }
        defer { sqlite3_close(db) }

        let cols = PodcastSQLFragments(layout: layout)
        let importPredicate = podcastImportPredicate(for: scope, columns: cols)
        let searchable = """
            lower(coalesce(e.ZTITLE, '') || ' ' || coalesce(p.ZTITLE, '') || ' ' ||
                  coalesce(\(cols.episodeDescription), ''))
        """
        let predicates = tokens.map { _ in "\(searchable) LIKE ?" }.joined(separator: " AND ")
        let sql = """
            SELECT e.ZSTORETRACKID, e.ZTITLE, p.ZTITLE,
                   COALESCE(p.ZARTWORKTEMPLATEURL, p.ZIMAGEURL, e.ZARTWORKTEMPLATEURL),
                   e.ZWEBPAGEURL, \(cols.transcriptIdentifier),
                   COALESCE(e.ZLASTDATEPLAYED, e.ZPLAYSTATELASTMODIFIEDDATE),
                   p.ZSTORECOLLECTIONID, e.ZUUID, e.ZGUID,
                   \(cols.episodeDescription),
                   \(cols.enclosureURL),
                   e.ZPUBDATE
            FROM ZMTEPISODE e
            JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
            \(cols.joins)
            WHERE COALESCE(e.ZUSERDELETED, 0) = 0
              AND NULLIF(\(cols.transcriptIdentifier), '') IS NOT NULL
              AND (
                COALESCE(e.ZSTORETRACKID, 0) > 0
                OR NULLIF(e.ZUUID, '') IS NOT NULL
                OR NULLIF(e.ZGUID, '') IS NOT NULL
                OR NULLIF(\(cols.enclosureURL), '') IS NOT NULL
              )
              AND \(importPredicate)
              AND \(predicates)
            ORDER BY
              CASE WHEN e.ZLASTDATEPLAYED IS NULL THEN 1 ELSE 0 END,
              COALESCE(e.ZLASTDATEPLAYED, e.ZPLAYSTATELASTMODIFIEDDATE) DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ([], .schemaChanged(details: "Failed to prepare podcast catalog search query"))
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, token) in tokens.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), "%\(token)%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int(stmt, Int32(tokens.count + 1), Int32(limit))

        var results: [PodcastEpisodeMetadata] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let (_, meta) = parseEpisodeRow(stmt: stmt)
            results.append(meta)
        }

        return (results, results.isEmpty ? .noEpisodesFound : .ok)
    }

    /// Query the Apple Podcasts database for episodes the user has engaged with.
    /// Public catalog episodes usually have store track IDs and may fetch TTML transcripts.
    /// Private RSS episodes often have no store track ID, so they are discoverable when
    /// Apple has a local UUID/GUID or enclosure URL, even if no transcript is exposed.
    /// Episodes listened on iPhone sync their play state to the Mac DB via iCloud, though
    /// some partial listens only surface as progress/Listen Now state rather than last-played.
    static func discoverPlayedEpisodes(
        dbPath: String,
        limit: Int = 1000,
        scope: ApplePodcastDiscoveryScope = .current
    ) -> (episodes: [PodcastEpisodeMetadata], status: PodcastDiscoveryStatus) {
        let (db, layout, status) = openPodcastsDB(at: dbPath)
        guard let db, let layout, status == .ok else { return ([], status) }
        defer { sqlite3_close(db) }

        var results: [PodcastEpisodeMetadata] = []
        let cols = PodcastSQLFragments(layout: layout)
        let importPredicate = podcastImportPredicate(for: scope, columns: cols)

        let sql = episodeSelectSQL(
            columns: cols,
            where: importPredicate,
            orderBy: "COALESCE(e.ZLASTDATEPLAYED, e.ZPLAYSTATELASTMODIFIEDDATE) DESC"
        )

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ([], .schemaChanged(details: "Failed to prepare episode query"))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let (_, meta) = parseEpisodeRow(stmt: stmt)
            results.append(meta)
        }

        return (results, results.isEmpty ? .noEpisodesFound : .ok)
    }

    /// Every episode Apple Podcasts holds locally for one show, played or not.
    /// Discovery imports what the learner listened to; this is the deliberate
    /// "I want the whole show" answer for a feed worth having in full. It is
    /// scoped to one show by its exact title, so the catalog is never swept
    /// wholesale, and it applies no play-state predicate at all.
    static func discoverAllEpisodes(
        dbPath: String,
        showName: String,
        limit: Int = 2000
    ) -> (episodes: [PodcastEpisodeMetadata], status: PodcastDiscoveryStatus) {
        let (db, layout, status) = openPodcastsDB(at: dbPath)
        guard let db, let layout, status == .ok else { return ([], status) }
        defer { sqlite3_close(db) }

        let cols = PodcastSQLFragments(layout: layout)
        let sql = episodeSelectSQL(
            columns: cols,
            where: "p.ZTITLE = ?",
            orderBy: "COALESCE(e.ZPUBDATE, e.ZLASTDATEPLAYED, 0) DESC"
        )

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ([], .schemaChanged(details: "Failed to prepare show episode query"))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, showName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [PodcastEpisodeMetadata] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let (_, meta) = parseEpisodeRow(stmt: stmt)
            results.append(meta)
        }
        return (results, results.isEmpty ? .noEpisodesFound : .ok)
    }

    /// Discovery's listened episodes plus every episode of the followed shows,
    /// each episode once. An episode the learner listened to keeps its
    /// discovery row (which carries the last-played date); a followed show's
    /// remaining episodes follow. Keyed by the address the library would give
    /// the episode, so the two passes cannot disagree about identity.
    static func mergeEpisodes(
        listened: [PodcastEpisodeMetadata],
        followed: [PodcastEpisodeMetadata]
    ) -> [PodcastEpisodeMetadata] {
        var seen = Set<String>()
        var merged: [PodcastEpisodeMetadata] = []
        for episode in listened + followed {
            let key = podcastEpisodeURL(for: episode) ?? "\(episode.podcastName)\u{1}\(episode.episodeTitle)"
            guard seen.insert(key).inserted else { continue }
            merged.append(episode)
        }
        return merged
    }

    /// The comparison key for a podcast show name. Apple writes the show title
    /// into every episode row, so the same show always spells itself the same
    /// way — but a name the learner blocked is a name ForeverLM stored, and the
    /// two meet again only by string. Trimmed and case-folded, so a stored
    /// "epic radio " still refuses "EPIC RADIO".
    static func podcastShowKey(_ showName: String) -> String {
        showName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Drop every episode of a show the learner blocked, before those episodes
    /// can become sources at all.
    ///
    /// This is the one filter that runs *before* persistence. Hiding a show acts
    /// on rows that already exist; blocking one means the rows are never
    /// created, which is the only thing that helps when a show is not study
    /// material in the first place — a DJ mix has a transcript's worth of
    /// nothing to say, and playing one in Apple Podcasts should not put it in
    /// the library.
    static func removingBlockedShows(
        from episodes: [PodcastEpisodeMetadata],
        blockedShows: Set<String>
    ) -> [PodcastEpisodeMetadata] {
        guard !blockedShows.isEmpty else { return episodes }
        let blocked = Set(blockedShows.map(podcastShowKey))
        return episodes.filter { !blocked.contains(podcastShowKey($0.podcastName)) }
    }

    // MARK: - The blocked-show list

    /// Where the blocked shows are kept. A preference rather than a row in the
    /// library, like the followed-show list it inverts: both steer the Mac-only
    /// Apple Podcasts import instead of describing something in the library.
    /// It is synced — `SyncedPreferenceKeys` says why it has to be.
    /// Under generation 2 the list is this Mac's, and each show's block
    /// travels as its `Mark(importBlocked)` (`BlockedShowsSync`).
    static let blockedPodcastShowsPreferenceKey = "podcasts.blockedShows"

    static func blockedPodcastShowNames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: blockedPodcastShowsPreferenceKey) ?? [])
    }

    static func isPodcastShowBlocked(_ showName: String) -> Bool {
        let key = podcastShowKey(showName)
        guard !key.isEmpty else { return false }
        return blockedPodcastShowNames().contains { podcastShowKey($0) == key }
    }

    /// Add or drop a show, and say whether the list actually changed. The one
    /// writer, so the menu, the removal flow and MCP cannot drift apart on what
    /// blocking means or on how the names are matched.
    @discardableResult
    static func setPodcastShowBlocked(_ showName: String, blocked: Bool) -> Bool {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = podcastShowKey(trimmed)
        var names = blockedPodcastShowNames()
        if blocked {
            guard !names.contains(where: { podcastShowKey($0) == key }) else { return false }
            names.insert(trimmed)
        } else {
            let before = names.count
            names = names.filter { podcastShowKey($0) != key }
            guard names.count != before else { return false }
        }
        if names.isEmpty {
            PreferenceStore.remove(forKey: blockedPodcastShowsPreferenceKey)
        } else {
            PreferenceStore.set(names.sorted(), forKey: blockedPodcastShowsPreferenceKey)
        }
        // Generation 2: a block is the member's `Mark(importBlocked)`, kept beside this Mac's list.
        BlockedShowsSync.mirror(names)
        return true
    }

    /// The one episode projection `parseEpisodeRow` reads, over whichever rows
    /// `predicate` selects. Every episode needs some identity ForeverLM can
    /// address it by: a store track id, Apple's local UUID, the feed GUID, or
    /// the enclosure URL.
    private static func episodeSelectSQL(
        columns cols: PodcastSQLFragments,
        where predicate: String,
        orderBy: String
    ) -> String {
        """
            SELECT e.ZSTORETRACKID, e.ZTITLE, p.ZTITLE,
                   COALESCE(p.ZARTWORKTEMPLATEURL, p.ZIMAGEURL, e.ZARTWORKTEMPLATEURL),
                   e.ZWEBPAGEURL, \(cols.transcriptIdentifier),
                   COALESCE(e.ZLASTDATEPLAYED, e.ZPLAYSTATELASTMODIFIEDDATE),
                   p.ZSTORECOLLECTIONID, e.ZUUID, e.ZGUID,
                   \(cols.episodeDescription),
                   \(cols.enclosureURL),
                   e.ZPUBDATE
            FROM ZMTEPISODE e
            JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
            \(cols.joins)
            WHERE COALESCE(e.ZUSERDELETED, 0) = 0
              AND \(predicate)
              AND (
                COALESCE(e.ZSTORETRACKID, 0) > 0
                OR NULLIF(e.ZUUID, '') IS NOT NULL
                OR NULLIF(e.ZGUID, '') IS NOT NULL
                OR NULLIF(\(cols.enclosureURL), '') IS NOT NULL
              )
            ORDER BY \(orderBy)
            LIMIT ?
        """
    }

    /// One show in the learner's Apple Podcasts library, as Setup lists it
    /// before anything is imported.
    struct PodcastShowInventoryItem: Identifiable, Hashable, Sendable {
        let name: String
        /// Followed in Apple Podcasts (explicitly or implicitly).
        let isFollowed: Bool
        /// Episodes discovery would import for this show under the current
        /// scope: what choosing Keep or Hide brings in right away.
        let importableEpisodeCount: Int
        let artworkURL: String?
        var id: String { SourceDiscovery.podcastShowKey(name) }
    }

    /// Every show the learner follows in Apple Podcasts, and every show with
    /// an episode discovery would import, with how many it would. Setup reads
    /// this so each show can be kept, hidden or refused before the first
    /// import (product owner, 2026-09-24). It reads Apple's database only, never
    /// the library, and applies the same predicate as `discoverPlayedEpisodes`
    /// so the counts are the episodes that would really arrive.
    static func podcastShowInventory(
        dbPath: String,
        scope: ApplePodcastDiscoveryScope = .current
    ) -> (shows: [PodcastShowInventoryItem], status: PodcastDiscoveryStatus) {
        let (db, layout, status) = openPodcastsDB(at: dbPath)
        guard let db, let layout, status == .ok else { return ([], status) }
        defer { sqlite3_close(db) }

        let cols = PodcastSQLFragments(layout: layout)
        let importPredicate = podcastImportPredicate(for: scope, columns: cols)
        let sql = """
            SELECT p.ZTITLE,
                   MAX(COALESCE(p.ZSUBSCRIBED, 0), COALESCE(p.ZISIMPLICITLYFOLLOWED, 0)),
                   COUNT(e.Z_PK),
                   COALESCE(p.ZARTWORKTEMPLATEURL, p.ZIMAGEURL)
            FROM ZMTPODCAST p
            LEFT JOIN (
                SELECT e.Z_PK, e.ZPODCAST
                FROM ZMTEPISODE e
                \(cols.joins)
                WHERE COALESCE(e.ZUSERDELETED, 0) = 0
                  AND \(importPredicate)
                  AND (
                    COALESCE(e.ZSTORETRACKID, 0) > 0
                    OR NULLIF(e.ZUUID, '') IS NOT NULL
                    OR NULLIF(e.ZGUID, '') IS NOT NULL
                    OR NULLIF(\(cols.enclosureURL), '') IS NOT NULL
                  )
            ) e ON e.ZPODCAST = p.Z_PK
            WHERE NULLIF(TRIM(p.ZTITLE), '') IS NOT NULL
            GROUP BY p.Z_PK
            HAVING COUNT(e.Z_PK) > 0
                OR COALESCE(p.ZSUBSCRIBED, 0) = 1
                OR COALESCE(p.ZISIMPLICITLYFOLLOWED, 0) = 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ([], .schemaChanged(details: "Failed to prepare show inventory query"))
        }
        defer { sqlite3_finalize(stmt) }

        // Apple can hold one show twice (a private feed beside the public
        // one); the library matches shows by name, so Setup does too.
        var byKey: [String: PodcastShowInventoryItem] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let titlePointer = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: titlePointer).trimmingCharacters(in: .whitespacesAndNewlines)
            let artwork = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let item = PodcastShowInventoryItem(
                name: name,
                isFollowed: sqlite3_column_int(stmt, 1) != 0,
                importableEpisodeCount: Int(sqlite3_column_int(stmt, 2)),
                artworkURL: artwork.flatMap { resolveArtworkURL(template: $0, width: 80, height: 80) }
            )
            if let existing = byKey[item.id] {
                byKey[item.id] = PodcastShowInventoryItem(
                    name: existing.name,
                    isFollowed: existing.isFollowed || item.isFollowed,
                    importableEpisodeCount: existing.importableEpisodeCount + item.importableEpisodeCount,
                    artworkURL: existing.artworkURL ?? item.artworkURL
                )
            } else {
                byKey[item.id] = item
            }
        }
        // Most listened first, then followed shows with nothing played yet.
        let shows = byKey.values.sorted {
            if $0.importableEpisodeCount != $1.importableEpisodeCount {
                return $0.importableEpisodeCount > $1.importableEpisodeCount
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (shows, .ok)
    }

@MainActor
final class PaperAIBrowserDownloadService: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    private struct PageCandidate: Codable {
        let id: String
        let tag: String
        let text: String
        let href: String?
        let title: String?
        let ariaLabel: String?
    }

    private struct PageSnapshot: Codable {
        let url: String
        let title: String
        let visibleText: String
        let metadata: [String]
        let candidates: [PageCandidate]
    }

    /// Compact, prompt-facing representation of a browser control. The full DOM
    /// snapshot remains available locally for executing the chosen candidate id;
    /// the model only needs the control's label and a bounded destination hint.
    private struct AgentPageCandidate: Codable {
        let id: String
        let label: String
        let destination: String?
    }

    private struct AgentPageSnapshot: Codable {
        let url: String
        let title: String
        let visibleText: String
        let metadata: [String]
        let candidates: [AgentPageCandidate]
    }

    private struct AgentDecision: Codable {
        let action: String
        let candidateId: String?
        let url: String?
        let reason: String?
    }

    /// A PDF the agent's browser downloaded: the temporary file, and the
    /// address that served it, so a file turned away as some other paper
    /// names the host it came from rather than a temporary file name.
    struct DownloadedPDF: Sendable {
        let file: URL
        /// Nil only when WebKit named no address for the download.
        let sourceURL: URL?
    }

    enum BrowserAgentError: LocalizedError {
        case invalidURL
        case pageLoadFailed(String)
        case noOpenAccessPDF(String)
        case paywalled(String)
        /// The agent thinks the page is paywalled — an abstract-only publisher
        /// page, a sign-in prompt beside the article — but the explicit
        /// purchase or subscription text `paywalled` demands was not there.
        /// The paper is not marked; the reason is kept so the learner can
        /// mark it in one click from the attention row.
        case likelyPaywalled(String)
        /// The loaded page is not a scholarly paper at all (news, editorial,
        /// comment), so there is no PDF to find and the source should leave
        /// the paper pipeline rather than wait for a recheck.
        case notAPaper(String)
        case blockedAction(String)
        case invalidAgentResponse(String)
        case downloadFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid paper URL."
            case .pageLoadFailed(let detail):
                return "Could not load page: \(detail)"
            case .noOpenAccessPDF(let detail):
                return detail
            case .paywalled(let detail):
                return "Paywall detected: \(detail)"
            case .likelyPaywalled(let detail):
                return "Looks paywalled: \(detail)"
            case .notAPaper(let detail):
                return "Not a paper: \(detail)"
            case .blockedAction(let detail):
                return "Stopped before unsafe action: \(detail)"
            case .invalidAgentResponse(let detail):
                return "AI browser returned an invalid action: \(detail)"
            case .downloadFailed(let detail):
                return "Browser PDF download failed: \(detail)"
            case .verificationFailed(let detail):
                return "Website verification did not complete: \(detail)"
            }
        }
    }

    private let aiService: AIService
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var activeDownloadContinuation: CheckedContinuation<Void, Error>?
    private var downloadInProgress = false
    private var pendingDownload: DownloadedPDF?
    private var completedDownload: DownloadedPDF?
    private var verificationContinuation: CheckedContinuation<Void, Error>?
    private var verificationPresentationTask: Task<Void, Never>?
    private var verificationTimeoutTask: Task<Void, Never>?
    private var verificationWindow: NSWindow?
    /// Identifier of the parked `WebVerificationRequests` entry, if any.
    private var verificationRequestID: UUID?
    /// Title of the paper currently being fetched, for the verification banner.
    private var currentSourceLabel: String?

    init(aiService: AIService) {
        self.aiService = aiService
        super.init()
    }

    /// Stop every browser-owned wait. `WKWebView.stopLoading()` alone does not
    /// resume checked continuations, which is how an abandoned navigation can
    /// otherwise leave its source under Processing forever.
    func cancel() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        webView?.stopLoading()

        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if let continuation = activeDownloadContinuation {
            activeDownloadContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        downloadInProgress = false
        if verificationContinuation != nil {
            finishSecurityVerification(.failure(CancellationError()))
        }

        let temporaryURLs = [pendingDownload, completedDownload].compactMap { $0?.file }
        pendingDownload = nil
        completedDownload = nil
        if !temporaryURLs.isEmpty {
            Task.detached(priority: .utility) {
                for url in temporaryURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    func findAndDownloadPDF(
        article: StudioArticle,
        config: AITaskConfig,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> DownloadedPDF {
        try Task.checkCancellation()
        guard let url = URL(string: article.url) else {
            throw BrowserAgentError.invalidURL
        }

        let webView = makeWebView()
        self.webView = webView
        currentSourceLabel = article.title
        defer {
            dismissVerificationWindow()
            self.webView = nil
        }
        progress("Opening paper page...")
        try await load(url, in: webView)
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(800))

        var actionLog: [String] = []
        var step = 1
        while step <= 6 {
            try Task.checkCancellation()
            if let download = takeCompletedDownload() {
                return download
            }
            if downloadInProgress {
                progress("Downloading PDF...")
                try await waitForActiveDownload()
                if let download = takeCompletedDownload() {
                    return download
                }
                throw BrowserAgentError.downloadFailed("No downloaded file was produced.")
            }

            let snapshot = try await pageSnapshot(in: webView)
            if Self.isSecurityVerificationPage(
                title: snapshot.title,
                visibleText: snapshot.visibleText,
                url: snapshot.url
            ) {
                progress("Waiting for website verification...")
                try await waitForSecurityVerification(in: webView)
                continue
            }

            let readySnapshot: PageSnapshot
            if Self.pageNeedsContentWait(
                visibleText: snapshot.visibleText,
                candidateCount: snapshot.candidates.count
            ) {
                progress("Waiting for page content...")
                do {
                    _ = try await waitForPageContent(in: webView)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A client-side redirect destroys the document that owns the
                    // MutationObserver. Let the replacement document settle, then
                    // inspect it below; a real WebKit failure will fail that snapshot.
                    try await Task.sleep(for: .milliseconds(500))
                }
                readySnapshot = try await pageSnapshot(in: webView)
                guard !Self.pageNeedsContentWait(
                    visibleText: readySnapshot.visibleText,
                    candidateCount: readySnapshot.candidates.count
                ) else {
                    throw BrowserAgentError.pageLoadFailed(
                        "The website did not expose any readable content or controls."
                    )
                }
            } else {
                readySnapshot = snapshot
            }

            if Self.isSecurityVerificationPage(
                title: readySnapshot.title,
                visibleText: readySnapshot.visibleText,
                url: readySnapshot.url
            ) {
                progress("Waiting for website verification...")
                try await waitForSecurityVerification(in: webView)
                continue
            }

            progress("AI browser step \(step)/6...")
            let decision = try await askAgent(
                article: article,
                snapshot: readySnapshot,
                actionLog: actionLog,
                config: config
            )
            try Task.checkCancellation()

            let reason = decision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            actionLog.append("\(decision.action): \(reason)")
            step += 1

            switch decision.action.lowercased() {
            case "download":
                guard let rawURL = decision.url,
                      let downloadURL = URL(string: rawURL),
                      Self.isHTTPURL(downloadURL) else {
                    throw BrowserAgentError.invalidAgentResponse("download action needs an http(s) URL")
                }
                // Navigate in the shared browser session instead of starting a
                // blind WKDownload. If the endpoint serves a Cloudflare HTML
                // challenge first, the next loop can recognize and clear it;
                // a genuine PDF response is converted to a download by the
                // navigation delegate below.
                progress("Opening PDF...")
                try await load(downloadURL, in: webView)
                if let completed = takeCompletedDownload() {
                    return completed
                }
                try await Task.sleep(for: .milliseconds(800))

            case "click":
                guard let id = decision.candidateId,
                      let candidate = readySnapshot.candidates.first(where: { $0.id == id }) else {
                    throw BrowserAgentError.invalidAgentResponse("click action needs a known candidateId")
                }
                progress("Clicking \(Self.displayLabel(for: candidate))...")
                let clicked = try await clickCandidate(id, in: webView)
                guard clicked else {
                    throw BrowserAgentError.invalidAgentResponse("candidate \(id) could not be clicked")
                }
                try await Task.sleep(for: .seconds(2))
                if let download = takeCompletedDownload() {
                    return download
                }

            case "wait":
                progress("Waiting for page...")
                try await Task.sleep(for: .seconds(2))
                if let download = takeCompletedDownload() {
                    return download
                }

            case "paywalled":
                throw BrowserAgentError.paywalled(Self.reasonOrDefault(reason, fallback: "The AI browser found paywall or access-control requirements on the page."))

            case "likely_paywalled":
                throw BrowserAgentError.likelyPaywalled(Self.reasonOrDefault(reason, fallback: "The page looks paywalled, but no explicit purchase or subscription text was visible."))

            case "not_a_paper":
                throw BrowserAgentError.notAPaper(Self.reasonOrDefault(reason, fallback: "The page is a news story or commentary, not a scholarly paper."))

            case "give_up":
                throw BrowserAgentError.noOpenAccessPDF(reason.isEmpty ? "No open-access PDF found." : reason)

            default:
                throw BrowserAgentError.invalidAgentResponse(decision.action)
            }
        }

        throw BrowserAgentError.noOpenAccessPDF("No open-access PDF found after the AI browser search.")
    }

    private func takeCompletedDownload() -> DownloadedPDF? {
        let download = completedDownload
        completedDownload = nil
        return download
    }

    private func waitForActiveDownload() async throws {
        guard downloadInProgress else { return }
        try await withCheckedThrowingContinuation { continuation in
            activeDownloadContinuation = continuation
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // macOS WKWebView autoplays media *with sound* by default; this view is
        // invisible, so autoplaying ads/embeds would leak random audio into the app.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // Cloudflare's managed challenge evaluates browser viewport properties.
        // A zero-sized hidden WebView can stay pinned to the interstitial even
        // though the same page succeeds in a normal browser window.
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = SharedWebKit.desktopSafariUserAgent
        return webView
    }

    /// Cloudflare and similar publisher checks are an intermediate browser state,
    /// not evidence that no PDF exists. Keep them out of the model's decision and
    /// surface the existing WebView so an interactive check can be completed when
    /// the automatic JavaScript challenge does not clear on its own.
    private func waitForSecurityVerification(in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            verificationContinuation = continuation
            verificationPresentationTask?.cancel()
            // Most managed challenges clear themselves unattended, so wait before
            // involving the user at all — and then only offer the window through
            // the Studio banner rather than throwing it on screen.
            verificationPresentationTask = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled,
                      let self,
                      let webView,
                      self.verificationContinuation != nil,
                      self.verificationWindow == nil,
                      self.verificationRequestID == nil else { return }
                self.verificationRequestID = WebVerificationRequests.shared.request(
                    message: "A publisher check needs you before this paper can download.",
                    detail: self.currentSourceLabel,
                    open: { [weak self, weak webView] in
                        guard let self else { return }
                        self.verificationRequestID = nil
                        guard let webView else { return }
                        self.presentVerificationWindow(hosting: webView)
                    },
                    skip: { [weak self] in
                        guard let self else { return }
                        self.verificationRequestID = nil
                        self.finishSecurityVerification(
                            .failure(BrowserAgentError.verificationFailed("The publisher check was skipped."))
                        )
                    }
                )
            }
            verificationTimeoutTask?.cancel()
            verificationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.finishSecurityVerification(
                    .failure(BrowserAgentError.verificationFailed("Timed out waiting for the publisher check."))
                )
            }
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                await self.finishSecurityVerificationIfResolved(in: webView)
            }
        }
    }

    private func presentVerificationWindow(hosting webView: WKWebView) {
        if let verificationWindow {
            verificationWindow.makeKeyAndOrderFront(nil)
            return
        }

        let contentSize = NSSize(width: 920, height: 820)
        webView.frame = NSRect(origin: .zero, size: contentSize)
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Verify publisher access"
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        verificationWindow = window
        // No `NSApp.activate(ignoringOtherApps:)`: the user opened this from the
        // banner, so the app is already frontmost.
        window.makeKeyAndOrderFront(nil)
        // Restart the clock — the remaining headless budget was not sized for a
        // human working through a CAPTCHA.
        verificationTimeoutTask?.cancel()
        verificationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.finishSecurityVerification(
                .failure(BrowserAgentError.verificationFailed("Timed out waiting for the publisher check."))
            )
        }
    }

    private func finishSecurityVerification(_ result: Result<Void, Error>) {
        guard let continuation = verificationContinuation else { return }
        verificationContinuation = nil
        verificationPresentationTask?.cancel()
        verificationPresentationTask = nil
        verificationTimeoutTask?.cancel()
        verificationTimeoutTask = nil
        dismissVerificationWindow()
        continuation.resume(with: result)
    }

    private func finishSecurityVerificationIfResolved(in webView: WKWebView) async {
        guard verificationContinuation != nil else { return }
        do {
            let snapshot = try await pageSnapshot(in: webView)
            guard !Self.isSecurityVerificationPage(
                title: snapshot.title,
                visibleText: snapshot.visibleText,
                url: snapshot.url
            ) else { return }
            finishSecurityVerification(.success(()))
        } catch {
            finishSecurityVerification(.failure(error))
        }
    }

    private func dismissVerificationWindow() {
        WebVerificationRequests.shared.withdraw(verificationRequestID)
        verificationRequestID = nil
        guard let window = verificationWindow else { return }
        window.delegate = nil
        webView?.removeFromSuperview()
        window.contentView = nil
        window.close()
        verificationWindow = nil
    }

    nonisolated static func isSecurityVerificationPage(
        title: String,
        visibleText: String,
        url: String
    ) -> Bool {
        let lowerTitle = title.lowercased()
        let lowerText = visibleText.lowercased()
        let lowerURL = url.lowercased()

        if lowerURL.contains("__cf_chl_") || lowerURL.contains("/cdn-cgi/challenge-platform/") {
            return true
        }
        if lowerTitle.contains("just a moment")
            || lowerTitle.contains("attention required")
            || lowerTitle.contains("security verification") {
            return true
        }
        return lowerText.contains("verify you are human")
            || lowerText.contains("checking your browser")
            || lowerText.contains("performing security verification")
            || lowerText.contains("enable javascript and cookies to continue")
    }

    /// A document whose head has loaded but whose body has no readable text or
    /// controls is not evidence that the paper lacks an open-access PDF. Modern
    /// publisher pages commonly reach this state while their JavaScript app is
    /// still rendering. Keep that transient state away from the model so it cannot
    /// turn an incomplete snapshot into a false "no PDF" decision.
    nonisolated static func pageNeedsContentWait(
        visibleText: String,
        candidateCount: Int
    ) -> Bool {
        visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && candidateCount == 0
    }

    /// Wait event-first for a JavaScript-rendered page to expose text or browser
    /// controls. The timeout is only a bounded backstop; MutationObserver resolves
    /// the promise as soon as the DOM becomes useful.
    private func waitForPageContent(in webView: WKWebView) async throws -> Bool {
        let js = """
        const hasPageContent = () => {
          const text = (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim();
          const control = document.querySelector('a, button, [role="button"], input[type="button"], input[type="submit"]');
          return text.length > 0 || control !== null;
        };

        if (hasPageContent()) return true;

        return await new Promise((resolve) => {
          let finished = false;
          const finish = (result) => {
            if (finished) return;
            finished = true;
            observer.disconnect();
            clearTimeout(timeout);
            resolve(result);
          };
          const observer = new MutationObserver(() => {
            if (hasPageContent()) finish(true);
          });
          observer.observe(document.documentElement || document, {
            subtree: true,
            childList: true,
            characterData: true,
            attributes: true
          });
          const timeout = setTimeout(() => finish(false), 8000);
        });
        """

        return (try await webView.callAsyncJavaScript(
            js,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool) ?? false
    }

    private func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled,
                      let self,
                      let continuation = self.loadContinuation else { return }
                self.loadContinuation = nil
                self.loadTimeoutTask = nil
                webView?.stopLoading()
                continuation.resume(
                    throwing: BrowserAgentError.pageLoadFailed("Timed out opening the publisher page.")
                )
            }
        }
    }

    private func pageSnapshot(in webView: WKWebView) async throws -> PageSnapshot {
        let js = """
        (() => {
          const clean = (value, limit = 240) => (value || '').replace(/\\s+/g, ' ').trim().slice(0, limit);
          const nodes = Array.from(document.querySelectorAll('a, button, [role="button"], input[type="button"], input[type="submit"]')).slice(0, 90);
          const candidates = nodes.map((node, index) => {
            const id = 'c' + (index + 1);
            node.setAttribute('data-foreverlm-agent-id', id);
            const href = node.href || node.getAttribute('href') || node.getAttribute('data-href') || null;
            let absoluteHref = null;
            try { absoluteHref = href ? new URL(href, document.baseURI).href : null; } catch (e) {}
            return {
              id,
              tag: (node.tagName || '').toLowerCase(),
              text: clean(node.innerText || node.textContent || node.value || node.getAttribute('aria-label') || node.getAttribute('title')),
              href: absoluteHref,
              title: clean(node.getAttribute('title')),
              ariaLabel: clean(node.getAttribute('aria-label'))
            };
          }).filter(item => item.text || item.href || item.title || item.ariaLabel);
          const metadata = Array.from(document.querySelectorAll('meta[name], meta[property], link[rel]')).slice(0, 80).map(node => {
            const key = node.getAttribute('name') || node.getAttribute('property') || node.getAttribute('rel') || '';
            const value = node.getAttribute('content') || node.getAttribute('href') || '';
            return clean(key + ': ' + value, 500);
          }).filter(Boolean);
          return JSON.stringify({
            url: location.href,
            title: document.title || '',
            visibleText: clean(document.body ? document.body.innerText : '', 5000),
            metadata,
            candidates
          });
        })();
        """

        guard let json = try await webView.evaluateJavaScript(js) as? String,
              let data = json.data(using: .utf8) else {
            throw BrowserAgentError.pageLoadFailed("Could not inspect the page.")
        }
        return try JSONDecoder().decode(PageSnapshot.self, from: data)
    }

    private func askAgent(
        article: StudioArticle,
        snapshot: PageSnapshot,
        actionLog: [String],
        config: AITaskConfig
    ) async throws -> AgentDecision {
        let snapshotJSON = try Self.agentSnapshotJSON(snapshot)
        let system = AITask.paperBrowserAgent.effectivePrompt ?? Prompts.paperBrowserAgent
        let previousActions = actionLog.suffix(6).map {
            String($0.prefix(160))
        }
        let user = """
        Paper title: \(String(article.title.prefix(300)))
        Paper URL: \(String(article.url.prefix(600)))

        Previous actions:
        \(previousActions.isEmpty ? "None" : previousActions.joined(separator: "\n"))

        Current page snapshot JSON:
        \(snapshotJSON)
        """

        let raw = try await aiService.chat(
            system: system,
            messages: [("user", user)],
            config: config,
            maxTokens: 500
        )
        return try Self.decodeDecision(from: raw)
    }

    /// OpenRouter can impose a credit-tier prompt ceiling below a model's
    /// advertised context window. Keep this browser step comfortably below that
    /// independent ceiling instead of sending an unbounded DOM serialization.
    ///
    /// Candidate ids remain unchanged so the decision can still be executed
    /// against the full local snapshot. Direct PDFs are placed first; all other
    /// controls retain document order until the exact JSON character budget is
    /// exhausted.
    private static func agentSnapshotJSON(_ snapshot: PageSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let characterBudget = 5_000

        let directPDFs = snapshot.candidates.filter { candidate in
            guard let href = candidate.href,
                  let url = URL(string: href) else { return false }
            return url.pathExtension.lowercased() == "pdf"
        }
        let directPDFIDs = Set(directPDFs.map(\.id))
        let orderedCandidates = directPDFs + snapshot.candidates.filter {
            !directPDFIDs.contains($0.id)
        }

        var compact = AgentPageSnapshot(
            url: String(snapshot.url.prefix(500)),
            title: String(snapshot.title.prefix(240)),
            visibleText: String(snapshot.visibleText.prefix(1_200)),
            metadata: snapshot.metadata.prefix(8).map { String($0.prefix(160)) },
            candidates: []
        )

        for candidate in orderedCandidates {
            let label = [candidate.text, candidate.ariaLabel, candidate.title]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? ""
            let destination = candidateDestinationHint(candidate.href)
            let promptCandidate = AgentPageCandidate(
                id: candidate.id,
                label: String(label.prefix(100)),
                destination: destination
            )
            let proposed = AgentPageSnapshot(
                url: compact.url,
                title: compact.title,
                visibleText: compact.visibleText,
                metadata: compact.metadata,
                candidates: compact.candidates + [promptCandidate]
            )
            let proposedData = try encoder.encode(proposed)
            guard proposedData.count <= characterBudget else { break }
            compact = proposed
        }

        let data = try encoder.encode(compact)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func candidateDestinationHint(_ href: String?) -> String? {
        guard let href, let url = URL(string: href) else { return nil }
        if url.pathExtension.lowercased() == "pdf" {
            return String(href.prefix(500))
        }
        guard let host = url.host else { return String(href.prefix(160)) }
        return String((host + url.path).prefix(160))
    }

    private static func decodeDecision(from raw: String) throws -> AgentDecision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end {
            json = String(trimmed[start...end])
        } else {
            throw BrowserAgentError.invalidAgentResponse(trimmed)
        }
        guard let data = json.data(using: .utf8) else {
            throw BrowserAgentError.invalidAgentResponse(trimmed)
        }
        return try JSONDecoder().decode(AgentDecision.self, from: data)
    }

    private func clickCandidate(_ id: String, in webView: WKWebView) async throws -> Bool {
        let js = """
        (() => {
          const node = document.querySelector('[data-foreverlm-agent-id="\(id)"]');
          if (!node) return false;
          node.scrollIntoView({block: 'center', inline: 'center'});
          node.click();
          return true;
        })();
        """
        return (try await webView.evaluateJavaScript(js) as? Bool) ?? false
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func reasonOrDefault(_ reason: String, fallback: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= 180 { return trimmed }
        return String(trimmed.prefix(180)) + "..."
    }

    private static func displayLabel(for candidate: PageCandidate) -> String {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return "\"\(text.prefix(40))\"" }
        if let href = candidate.href { return URL(string: href)?.host ?? "PDF link" }
        return candidate.id
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadContinuation?.resume()
        loadContinuation = nil

        guard verificationContinuation != nil else { return }
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.finishSecurityVerificationIfResolved(in: webView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === verificationWindow else { return }
        closingWindow.delegate = nil
        webView?.removeFromSuperview()
        closingWindow.contentView = nil
        verificationWindow = nil
        finishSecurityVerification(
            .failure(BrowserAgentError.verificationFailed("The verification window was closed."))
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        let failure = BrowserAgentError.pageLoadFailed(error.localizedDescription)
        if downloadInProgress {
            downloadInProgress = false
            activeDownloadContinuation?.resume(throwing: failure)
            activeDownloadContinuation = nil
        }
        if verificationContinuation != nil {
            finishSecurityVerification(.failure(failure))
            return
        }
        loadContinuation?.resume(throwing: failure)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        let failure = BrowserAgentError.pageLoadFailed(error.localizedDescription)
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if downloadInProgress {
            downloadInProgress = false
            activeDownloadContinuation?.resume(throwing: failure)
            activeDownloadContinuation = nil
        }
        if verificationContinuation != nil {
            finishSecurityVerification(.failure(failure))
            return
        }
        loadContinuation?.resume(throwing: failure)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // Let the request reach the response delegate. A PDF-looking link can
        // still return an HTML security challenge; deciding to download at the
        // action stage would save that interstitial as a fake PDF and prevent
        // the verification flow from ever seeing it.
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let mimeType = navigationResponse.response.mimeType?.lowercased() ?? ""
        if mimeType == "application/pdf" || !navigationResponse.canShowMIMEType {
            downloadInProgress = true
            decisionHandler(.download)
            return
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            downloadInProgress = true
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadInProgress = true
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadInProgress = true
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: destination)
        // The response's address is where the bytes came from, after any
        // redirect; the request is the fallback when WebKit gives none.
        pendingDownload = DownloadedPDF(file: destination, sourceURL: response.url ?? download.originalRequest?.url)
        completionHandler(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        downloadInProgress = false
        pendingDownload = nil
        let failure = BrowserAgentError.downloadFailed(error.localizedDescription)
        if let continuation = activeDownloadContinuation {
            activeDownloadContinuation = nil
            continuation.resume(throwing: failure)
        }
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(throwing: failure)
        } else if verificationContinuation != nil {
            finishSecurityVerification(.failure(failure))
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        guard let finished = pendingDownload else {
            downloadInProgress = false
            let failure = BrowserAgentError.downloadFailed("No downloaded file was produced.")
            if let continuation = activeDownloadContinuation {
                activeDownloadContinuation = nil
                continuation.resume(throwing: failure)
            }
            if let continuation = loadContinuation {
                loadContinuation = nil
                continuation.resume(throwing: failure)
            } else if verificationContinuation != nil {
                finishSecurityVerification(.failure(failure))
            }
            return
        }
        downloadInProgress = false
        pendingDownload = nil
        completedDownload = finished
        activeDownloadContinuation?.resume()
        activeDownloadContinuation = nil
        loadContinuation?.resume()
        loadContinuation = nil
        if verificationContinuation != nil {
            finishSecurityVerification(.success(()))
        }
    }
}
}
