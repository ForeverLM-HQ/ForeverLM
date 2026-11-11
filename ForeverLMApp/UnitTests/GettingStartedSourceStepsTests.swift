import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Setup's Podcasts, Articles and Papers steps decide what comes in before
/// anything is imported: the shows in Apple Podcasts, how far back the Reading
/// List reaches, and the Zotero library found on this Mac.
@Suite("Getting Started source steps")
struct GettingStartedSourceStepsTests {
    typealias Window = SourceDiscovery.ReadingListImportWindow

    // MARK: Reading List backlog

    @Test("Each backlog option cuts off where it says, measured from now")
    func readingListWindowCutoffs() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(Window.everything.cutoff(now: now) == nil)
        #expect(Window.fromNowOn.cutoff(now: now) == now)
        let month = try #require(Window.lastMonth.cutoff(now: now))
        let days = Calendar.current.dateComponents([.day], from: month, to: now).day
        #expect(days == Window.recentDays)
    }

    @Test("Only pages saved on or after the cutoff are admitted; no cutoff admits all")
    func readingListWindowAdmits() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let saved = [Date(timeIntervalSince1970: 999), cutoff, Date(timeIntervalSince1970: 1_001)]
        #expect(Window.admitting(saved, cutoff: cutoff, savedAt: { $0 }) == Array(saved.dropFirst()))
        #expect(Window.admitting(saved, cutoff: nil, savedAt: { $0 }) == saved)
    }

    @Test("Only a wider window asks for another sync")
    func readingListWindowWidens() {
        #expect(Window.widens(from: .fromNowOn, to: .lastMonth))
        #expect(Window.widens(from: .lastMonth, to: .everything))
        #expect(!Window.widens(from: .everything, to: .lastMonth))
        #expect(!Window.widens(from: nil, to: .fromNowOn))
        #expect(!Window.widens(from: .lastMonth, to: .lastMonth))
    }

    @Test("The backlog choice stays on this Mac, like the browser choice it qualifies")
    func readingListWindowIsPerMac() {
        #expect(!SyncedPreferenceKeys.isSynced(Window.sinceKey))
        #expect(!SyncedPreferenceKeys.isSynced(Window.windowKey))
    }

    // MARK: Zotero

    @Test("Zotero's prefs.js yields its moved data directory, escapes undone")
    func zoteroPreferencesParse() {
        let prefs = """
        // Mozilla User Preferences
        user_pref("extensions.zotero.dataDir", "/Users/ada/Library/Mobile Documents/Zotero \\"lab\\"");
        user_pref("extensions.zotero.useDataDir", true);
        user_pref("extensions.zotero.lastViewedFolder", "L1");
        """
        let values = ReferenceLibraryImportService.zoteroPreferences(in: prefs)
        #expect(values["extensions.zotero.dataDir"] == "/Users/ada/Library/Mobile Documents/Zotero \"lab\"")
        #expect(values["extensions.zotero.useDataDir"] == "true")
        #expect(values["extensions.zotero.lastViewedFolder"] == "L1")
    }

    @Test("A moved Zotero data directory wins over ~/Zotero, and ~/Zotero is found without one")
    func zoteroDataDirectoryLookup() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default

        #expect(ReferenceLibraryImportService.zoteroDataDirectory(homeDir: home.path) == nil)

        let standard = home.appendingPathComponent("Zotero", isDirectory: true)
        try fm.createDirectory(at: standard, withIntermediateDirectories: true)
        try Data().write(to: standard.appendingPathComponent("zotero.sqlite"))
        #expect(ReferenceLibraryImportService.zoteroDataDirectory(homeDir: home.path)?.path == standard.path)

        let moved = home.appendingPathComponent("Research/Zotero Data", isDirectory: true)
        try fm.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data().write(to: moved.appendingPathComponent("zotero.sqlite"))
        let profile = home.appendingPathComponent("Library/Application Support/Zotero/Profiles/abc.default", isDirectory: true)
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try """
        user_pref("extensions.zotero.dataDir", "\(moved.path)");
        user_pref("extensions.zotero.useDataDir", true);
        """.write(to: profile.appendingPathComponent("prefs.js"), atomically: true, encoding: .utf8)
        #expect(ReferenceLibraryImportService.zoteroDataDirectory(homeDir: home.path)?.path == moved.path)
    }

    // MARK: Apple Podcasts shows

    @Test("The show list has every followed show and every show with a played episode, counted as discovery would import")
    func podcastShowInventory() throws {
        let dbPath = try Self.podcastLibrary()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let result = SourceDiscovery.podcastShowInventory(dbPath: dbPath, scope: .listened)
        #expect(result.status == .ok)
        let byName = Dictionary(uniqueKeysWithValues: result.shows.map { ($0.name, $0) })

        // Most played first; a followed show with nothing played is still listed.
        #expect(result.shows.map(\.name) == ["Deep Dive", "Owl Posting", "Followed Only"])
        #expect(byName["Deep Dive"]?.importableEpisodeCount == 2)
        #expect(byName["Deep Dive"]?.isFollowed == false)
        #expect(byName["Owl Posting"]?.importableEpisodeCount == 1)
        #expect(byName["Followed Only"]?.importableEpisodeCount == 0)
        #expect(byName["Followed Only"]?.isFollowed == true)
        // Played before discovery's cutoff, deleted, or never played and not
        // followed: nothing would arrive, so the show is not asked about.
        #expect(byName["Old Times"] == nil)
        #expect(byName["Never Heard"] == nil)
        #expect(byName["Deep Dive"]?.artworkURL?.contains("80x80bb.jpg") == true)
    }

    @Test("A missing Apple Podcasts library says so instead of listing nothing")
    func podcastShowInventoryWithoutLibrary() {
        let result = SourceDiscovery.podcastShowInventory(dbPath: "/nonexistent/MTLibrary.sqlite")
        #expect(result.shows.isEmpty)
        #expect(result.status == .appNotInstalled)
    }

    /// An older-layout Apple Podcasts database: every column discovery's
    /// schema check and episode projection read.
    private static func podcastLibrary() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-podcasts-\(UUID().uuidString).sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }

        // Seconds since 2001-01-01, as Core Data stores dates: one in 2026
        // (after discovery's 2026-01-01 cutoff) and one in 2025.
        let played2026 = Date(timeIntervalSince1970: 1_780_000_000).timeIntervalSinceReferenceDate
        let played2025 = Date(timeIntervalSince1970: 1_740_000_000).timeIntervalSinceReferenceDate
        let sql = """
            CREATE TABLE ZMTPODCAST (
                Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZIMAGEURL TEXT, ZARTWORKTEMPLATEURL TEXT,
                ZSUBSCRIBED INTEGER, ZISIMPLICITLYFOLLOWED INTEGER, ZSTORECOLLECTIONID INTEGER
            );
            CREATE TABLE ZMTEPISODE (
                Z_PK INTEGER PRIMARY KEY, ZPODCAST INTEGER, ZSTORETRACKID INTEGER, ZTITLE TEXT,
                ZTRANSCRIPTIDENTIFIER TEXT, ZARTWORKTEMPLATEURL TEXT, ZWEBPAGEURL TEXT, ZUUID TEXT, ZGUID TEXT,
                ZITEMDESCRIPTIONWITHOUTHTML TEXT, ZITEMDESCRIPTION TEXT, ZITUNESSUBTITLE TEXT, ZENCLOSUREURL TEXT,
                ZLASTDATEPLAYED REAL, ZPLAYSTATELASTMODIFIEDDATE REAL, ZPLAYSTATE INTEGER, ZPLAYHEAD REAL,
                ZHASBEENPLAYED INTEGER, ZPLAYCOUNT INTEGER, ZLISTENNOWEPISODE INTEGER, ZISBOOKMARKED INTEGER,
                ZDOWNLOADDATE REAL, ZDOWNLOADPATH TEXT, ZUSERDELETED INTEGER, ZPUBDATE REAL
            );
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE, ZARTWORKTEMPLATEURL, ZSUBSCRIBED) VALUES
                (1, 'Deep Dive', 'https://example.com/dd/{w}x{h}bb.{f}', 0),
                (2, 'Owl Posting', NULL, 1),
                (3, 'Followed Only', NULL, 1),
                (4, 'Old Times', NULL, 0),
                (5, 'Never Heard', NULL, 0);
            INSERT INTO ZMTEPISODE (Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE, ZLASTDATEPLAYED, ZUSERDELETED) VALUES
                (1, 1, 101, 'One', \(played2026), 0),
                (2, 1, 102, 'Two', \(played2026), 0),
                (3, 1, 103, 'Deleted', \(played2026), 1),
                (4, 2, 201, 'Owl', \(played2026), 0),
                (5, 4, 401, 'Last year', \(played2025), 0),
                (6, 5, 501, 'Unplayed', NULL, 0);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        return path
    }
}
