import Testing
import Foundation
@testable import ForeverLM

private final class ChromiumReadingListFixtureAnchor {}

/// The fixture is a real LevelDB written by `scripts/make_brave_sync_fixture.mjs`:
/// `brave-sync-000005.ldb` is the compacted table (alpha, beta with its first
/// title, a `removed` entry deleted before compaction, a metadata key and 400
/// padding keys so the table has several blocks), and `brave-sync-000004.log`
/// is the write-ahead log written afterwards (beta renamed and marked read,
/// gamma added).
@Suite("Chromium Reading List Store")
struct ChromiumReadingListStoreTests {
    private static let alphaCreated = Date(timeIntervalSince1970: 1788926302.227587)
    private static let betaCreated = Date(timeIntervalSince1970: 1788926376.142953)
    private static let betaFirstRead = Date(timeIntervalSince1970: 1788930000)
    private static let gammaCreated = Date(timeIntervalSince1970: 1788926396.871453)

    /// A temporary `Sync Data/LevelDB` directory holding the named fixture files
    /// under the names LevelDB gives them.
    private static func syncDirectory(files: [(fixture: String, ext: String, name: String)]) throws -> String {
        let bundle = Bundle(for: ChromiumReadingListFixtureAnchor.self)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromium-reading-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let source = try #require(
                bundle.url(forResource: file.fixture, withExtension: file.ext),
                "\(file.fixture).\(file.ext) missing from UnitTests/Fixtures"
            )
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(file.name))
        }
        return dir.path
    }

    private static func fullStore() throws -> String {
        try syncDirectory(files: [
            ("brave-sync-000005", "ldb", "000005.ldb"),
            ("brave-sync-000004", "log", "000004.log"),
        ])
    }

    private static func close(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < 0.001
    }

    @Test("The log's newer records win over the compacted table, and a deleted entry stays gone")
    func logOverridesTable() throws {
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: try Self.fullStore())
        #expect(entries.map(\.url) == [
            "https://example.org/alpha",
            "https://example.org/beta",
            "https://example.org/gamma",
        ])

        let alpha = try #require(entries.first { $0.url.hasSuffix("/alpha") })
        #expect(alpha.title == "Alpha &amp; Omega")
        #expect(alpha.status == .unseen)
        #expect(!alpha.isRead)
        #expect(Self.close(alpha.creationTime, Self.alphaCreated))
        #expect(alpha.firstReadTime == nil)

        let beta = try #require(entries.first { $0.url.hasSuffix("/beta") })
        #expect(beta.title == "Beta (renamed)")
        #expect(beta.status == .read)
        #expect(beta.isRead)
        #expect(Self.close(beta.creationTime, Self.betaCreated))
        #expect(Self.close(beta.firstReadTime, Self.betaFirstRead))

        let gamma = try #require(entries.first { $0.url.hasSuffix("/gamma") })
        #expect(gamma.title == "Gamma")
        #expect(Self.close(gamma.creationTime, Self.gammaCreated))
    }

    @Test("A compacted table is read on its own, snappy blocks and all")
    func tableAlone() throws {
        let dir = try Self.syncDirectory(files: [("brave-sync-000005", "ldb", "000005.ldb")])
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: dir)
        #expect(entries.map(\.url) == ["https://example.org/alpha", "https://example.org/beta"])
        let beta = try #require(entries.last)
        #expect(beta.title == "Beta (first title)")
        #expect(beta.status == .unread)
        #expect(beta.firstReadTime == nil)
    }

    @Test("A write-ahead log is read on its own")
    func logAlone() throws {
        let dir = try Self.syncDirectory(files: [("brave-sync-000004", "log", "000004.log")])
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: dir)
        #expect(entries.map(\.url) == ["https://example.org/beta", "https://example.org/gamma"])
        #expect(entries.first?.isRead == true)
    }

    @Test("A deletion recorded after a put removes the entry")
    func deletionInLog() throws {
        let key = Array("reading_list-dt-https://example.org/gone".utf8)
        let value = Self.readingListLocal(url: "https://example.org/gone", title: "Gone", creationMicros: 1_700_000_000_000_000, status: 0)
        let log = Self.logRecord(batch: Self.writeBatch(sequence: 10, operations: [.put(key, value)]))
            + Self.logRecord(batch: Self.writeBatch(sequence: 11, operations: [.delete(key)]))
        let dir = try Self.directory(withFile: "000001.log", bytes: log)
        #expect(ChromiumReadingListStore.entries(inSyncDirectory: dir).isEmpty)
    }

    @Test("A file that is not LevelDB still yields the URLs stored in the clear")
    func fallbackScan() throws {
        var bytes = Array("garbage before ".utf8)
        bytes += Array("reading_list-dt-https://example.org/scanned".utf8)
        bytes += [0x00, 0x01, 0x02]
        bytes += Array("reading_list-dt-https://example.org/scanned\n".utf8)
        bytes += Array("reading_list-md-https://example.org/metadata".utf8)
        let dir = try Self.directory(withFile: "000007.log", bytes: bytes)
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: dir)
        #expect(entries.count == 1)
        #expect(entries.first?.url == "https://example.org/scanned")
        #expect(entries.first?.title == "https://example.org/scanned")
        #expect(entries.first?.creationTime == nil)
    }

    @Test("Files that are neither log nor table are ignored, and a missing directory yields nothing")
    func ignoresOtherFiles() throws {
        let dir = try Self.directory(withFile: "MANIFEST-000001", bytes: Array("reading_list-dt-https://example.org/manifest".utf8))
        #expect(ChromiumReadingListStore.entries(inSyncDirectory: dir).isEmpty)
        #expect(ChromiumReadingListStore.entries(inSyncDirectory: "/nonexistent/\(UUID().uuidString)").isEmpty)
    }

    @Test("SourceDiscovery maps a store entry onto a Reading List entry with the same fields Safari fills")
    func sourceDiscoveryMapping() throws {
        let entries = SourceDiscovery.parseChromiumSyncReadingList(syncDir: try Self.fullStore())
        #expect(entries.count == 3)

        let alpha = try #require(entries.first { $0.url.hasSuffix("/alpha") })
        #expect(alpha.title == "Alpha & Omega", "HTML character references are decoded, as for Safari titles")
        #expect(!alpha.isRead)
        #expect(Self.close(alpha.dateAdded, Self.alphaCreated))
        #expect(alpha.dateLastViewed == nil)

        let beta = try #require(entries.first { $0.url.hasSuffix("/beta") })
        #expect(beta.title == "Beta (renamed)")
        #expect(beta.isRead)
        #expect(Self.close(beta.dateAdded, Self.betaCreated))
        #expect(Self.close(beta.dateLastViewed, Self.betaFirstRead))
    }

    @Test("A signed-in Chrome account's entries are read from its A- store")
    func accountStore() throws {
        let url = "https://example.org/account"
        let log = Self.logRecord(batch: Self.writeBatch(sequence: 5, operations: [
            .put(Array("A-reading_list-dt-\(url)".utf8), Self.readingListLocal(
                url: url, title: "Account", creationMicros: 1_700_000_000_000_000, status: 1,
                firstReadMicros: 1_700_000_100_000_000
            )),
            .put(Array("A-reading_list-md-\(url)".utf8), [0x0a, 0x00]),
        ]))
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: try Self.directory(withFile: "000003.log", bytes: log))
        #expect(entries.map(\.url) == [url])
        #expect(entries.first?.title == "Account")
        #expect(entries.first?.isRead == true)
        #expect(Self.close(entries.first?.firstReadTime, Date(timeIntervalSince1970: 1_700_000_100)))
    }

    @Test("Chrome's sync-to-signin migration moves the list to the account store and nothing is lost")
    func migrationToAccountStore() throws {
        let urls = ["https://example.org/one", "https://example.org/two"]
        func value(_ url: String) -> [UInt8] {
            Self.readingListLocal(url: url, title: url, creationMicros: 1_700_000_000_000_000, status: 0)
        }
        // Chrome renames each unprefixed key to its A- twin in one batch; a
        // removal made afterwards is a deletion in the account store.
        let saved = urls.map { Operation.put(Array("reading_list-dt-\($0)".utf8), value($0)) }
        let migration = urls.flatMap { url in [
            Operation.delete(Array("reading_list-dt-\(url)".utf8)),
            Operation.put(Array("A-reading_list-dt-\(url)".utf8), value(url)),
        ] }
        let log = Self.logRecord(batch: Self.writeBatch(sequence: 1, operations: saved))
            + Self.logRecord(batch: Self.writeBatch(sequence: 3, operations: migration))
            + Self.logRecord(batch: Self.writeBatch(sequence: 7, operations: [
                .delete(Array("A-reading_list-dt-https://example.org/two".utf8)),
            ]))
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: try Self.directory(withFile: "000003.log", bytes: log))
        #expect(entries.map(\.url) == ["https://example.org/one"])
    }

    @Test("An entry in both stores is one entry, merged the way Chrome merges it")
    func entryInBothStores() throws {
        let saved: UInt64 = 1_700_000_000_000_000
        let later: UInt64 = 1_700_000_500_000_000
        let accountNewer = "https://example.org/account-newer"
        let localNewer = "https://example.org/local-newer"
        let log = Self.logRecord(batch: Self.writeBatch(sequence: 1, operations: [
            .put(Array("reading_list-dt-\(accountNewer)".utf8), Self.readingListLocal(
                url: accountNewer, title: "Local title", creationMicros: saved, status: 2,
                updateMicros: saved, titleUpdateMicros: saved
            )),
            .put(Array("A-reading_list-dt-\(accountNewer)".utf8), Self.readingListLocal(
                url: accountNewer, title: "Account title", creationMicros: saved, status: 1,
                updateMicros: later, firstReadMicros: later, titleUpdateMicros: later
            )),
            .put(Array("reading_list-dt-\(localNewer)".utf8), Self.readingListLocal(
                url: localNewer, title: "Read here", creationMicros: saved + 1_000_000, status: 1,
                updateMicros: later, firstReadMicros: later, titleUpdateMicros: later
            )),
            .put(Array("A-reading_list-dt-\(localNewer)".utf8), Self.readingListLocal(
                url: localNewer, title: "Unread there", creationMicros: saved + 1_000_000, status: 0,
                updateMicros: saved, titleUpdateMicros: saved
            )),
        ]))
        let entries = ChromiumReadingListStore.entries(inSyncDirectory: try Self.directory(withFile: "000003.log", bytes: log))
        #expect(entries.map(\.url) == [accountNewer, localNewer])

        let first = try #require(entries.first)
        #expect(first.title == "Account title")
        #expect(first.status == .read)
        #expect(Self.close(first.firstReadTime, Date(timeIntervalSince1970: 1_700_000_500)))

        let second = try #require(entries.last)
        #expect(second.title == "Read here")
        #expect(second.status == .read)
    }

    @Test("Every Chrome profile's reading list is read, and the guest profile's is not")
    func everyChromeProfile() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = (home as NSString).appendingPathComponent("Library/Application Support/Google/Chrome")
        try Self.writeProfileStore(root: root, profile: "Default", url: "https://example.org/first-account")
        try Self.writeProfileStore(root: root, profile: "Profile 1", url: "https://example.org/second-account")
        try Self.writeProfileStore(root: root, profile: "Profile 3", url: "https://example.org/third-account")
        try Self.writeProfileStore(root: root, profile: "Guest Profile", url: "https://example.org/guest")

        let result = StudioViewModel.discoverChromeReadingListOffMain(browser: "Google/Chrome", homeDir: home)
        #expect(result.warnings.isEmpty)
        #expect(Set(result.articles.map(\.url)) == [
            "https://example.org/first-account",
            "https://example.org/second-account",
            "https://example.org/third-account",
        ])

        // A save in a second profile changes what the watcher compares.
        let snapshot = StudioViewModel.browserReadingListModificationSnapshot(
            homeDir: home, safariEnabled: false, chromeEnabled: true, braveEnabled: false
        )
        #expect(snapshot.keys.contains { $0.hasSuffix("/Profile 1/Sync Data/LevelDB") })
        #expect(!snapshot.keys.contains { $0.contains("Guest Profile") })
    }

    @Test("A Brave profile other than Default is read, even when Default has no store")
    func braveSecondProfile() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = (home as NSString).appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser")
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent("Default"), withIntermediateDirectories: true
        )
        try Self.writeProfileStore(root: root, profile: "Profile 2", url: "https://example.org/brave-second")

        let result = StudioViewModel.discoverBraveReadingListOffMain(homeDir: home)
        #expect(result.warnings.isEmpty)
        #expect(result.articles.map(\.url) == ["https://example.org/brave-second"])

        let snapshot = StudioViewModel.browserReadingListModificationSnapshot(
            homeDir: home, safariEnabled: false, chromeEnabled: false, braveEnabled: true
        )
        #expect(snapshot.keys.contains { $0.hasSuffix("/Profile 2/Sync Data/LevelDB") })
    }

    // MARK: - Hand-built LevelDB bytes

    private enum Operation {
        case put([UInt8], [UInt8])
        case delete([UInt8])
    }

    private static func directory(withFile name: String, bytes: [UInt8]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromium-reading-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes).write(to: dir.appendingPathComponent(name))
        return dir.path
    }

    private static func temporaryHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromium-profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    /// One unread entry in a profile's account store, as a signed-in Chrome
    /// profile saves it.
    private static func writeProfileStore(root: String, profile: String, url: String) throws {
        let dir = URL(fileURLWithPath: root)
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("Sync Data/LevelDB", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = logRecord(batch: writeBatch(sequence: 1, operations: [
            .put(Array("A-reading_list-dt-\(url)".utf8), readingListLocal(
                url: url, title: url, creationMicros: 1_700_000_000_000_000, status: 0
            )),
        ]))
        try Data(log).write(to: dir.appendingPathComponent("000003.log"))
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    private static func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
    }

    /// `ReadingListLocal`: 1 entry_id, 2 title, 3 url, 4 creation_time_us,
    /// 5 update_time_us, 6 status, 11 first_read_time_us, 12 update_title_time_us.
    private static func readingListLocal(
        url: String,
        title: String,
        creationMicros: UInt64,
        status: UInt64,
        updateMicros: UInt64? = nil,
        firstReadMicros: UInt64? = nil,
        titleUpdateMicros: UInt64? = nil
    ) -> [UInt8] {
        func string(_ field: UInt64, _ text: String) -> [UInt8] {
            let bytes = Array(text.utf8)
            return varint(field << 3 | 2) + varint(UInt64(bytes.count)) + bytes
        }
        func number(_ field: UInt64, _ value: UInt64) -> [UInt8] { varint(field << 3) + varint(value) }
        var bytes = string(1, url) + string(2, title) + string(3, url) + number(4, creationMicros) + number(6, status)
        if let updateMicros { bytes += number(5, updateMicros) }
        if let firstReadMicros { bytes += number(11, firstReadMicros) }
        if let titleUpdateMicros { bytes += number(12, titleUpdateMicros) }
        return bytes
    }

    private static func writeBatch(sequence: UInt64, operations: [Operation]) -> [UInt8] {
        var batch = littleEndian(sequence, count: 8) + littleEndian(UInt64(operations.count), count: 4)
        for operation in operations {
            switch operation {
            case .put(let key, let value):
                batch += [1] + varint(UInt64(key.count)) + key + varint(UInt64(value.count)) + value
            case .delete(let key):
                batch += [0] + varint(UInt64(key.count)) + key
            }
        }
        return batch
    }

    /// One full (type 1) log record; the reader does not check the CRC.
    private static func logRecord(batch: [UInt8]) -> [UInt8] {
        [0, 0, 0, 0, UInt8(batch.count & 0xff), UInt8(batch.count >> 8), 1] + batch
    }
}
