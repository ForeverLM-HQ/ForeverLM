import Foundation
import Testing
@testable import ForeverLM

/// The Canvas summaries' cache was about 300 KB in `UserDefaults`, re-diffed
/// after every defaults write in the process and decoded on the main actor by
/// each Map model. It is a file in the profile's Application Support folder
/// now, and the first read moves an older build's copy there. These run on a
/// throwaway suite and a temporary folder, never the standard domain or the
/// profile's folder.
@Suite("Canvas summary cache")
struct KnowledgeMapSummaryCacheTests {
    typealias Summary = KnowledgeMapSummaries.Summary

    static let cached: [String: Summary] = [
        "r:frame-1": Summary(short: "Mitochondria", long: "How cells make energy", fingerprint: "f1", takeaways: ["ATP", "Membranes"]),
        "r:frame-2": Summary(short: "Sleep", long: "Why we sleep", fingerprint: "f2"),
    ]

    private func withScratch(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeMapSummaryCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(defaults, folder.appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("KnowledgeMapSummaries.json"))
    }

    @Test("The first read moves an older build's copy into the file, byte for byte, and removes the key")
    func movesTheCacheOutOfDefaults() throws {
        try withScratch { defaults, fileURL in
            let stored = try JSONEncoder().encode(Self.cached)
            defaults.set(stored, forKey: KnowledgeMapSummaries.cacheKey)

            let loaded = KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: defaults)

            #expect(loaded == Self.cached)
            #expect(try Data(contentsOf: fileURL) == stored)
            #expect(defaults.object(forKey: KnowledgeMapSummaries.cacheKey) == nil)
            // The next launch reads the file alone.
            #expect(KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: defaults) == Self.cached)
        }
    }

    @Test("A copy written by an older build after the move is merged into the file, its entries winning")
    func mergesALaterDefaultsCopy() throws {
        try withScratch { defaults, fileURL in
            KnowledgeMapSummaries.writeCache(Self.cached, to: fileURL)
            let newer = Summary(short: "Sleep, revised", long: "Why we sleep, revised", fingerprint: "f2b")
            let third = Summary(short: "Ketones", long: "Fuel in a fast", fingerprint: "f3")
            defaults.set(try JSONEncoder().encode(["r:frame-2": newer, "r:frame-3": third]), forKey: KnowledgeMapSummaries.cacheKey)

            let loaded = KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: defaults)

            let expected = ["r:frame-1": Self.cached["r:frame-1"]!, "r:frame-2": newer, "r:frame-3": third]
            #expect(loaded == expected)
            #expect(KnowledgeMapSummaries.readCache(at: fileURL) == expected)
            #expect(defaults.object(forKey: KnowledgeMapSummaries.cacheKey) == nil)
        }
    }

    @Test("An unreadable copy is removed and leaves the file as it was")
    func dropsAnUnreadableCopy() throws {
        try withScratch { defaults, fileURL in
            defaults.set(Data("not json".utf8), forKey: KnowledgeMapSummaries.cacheKey)
            #expect(KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: defaults).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
            #expect(defaults.object(forKey: KnowledgeMapSummaries.cacheKey) == nil)

            KnowledgeMapSummaries.writeCache(Self.cached, to: fileURL)
            defaults.set(Data("not json".utf8), forKey: KnowledgeMapSummaries.cacheKey)
            #expect(KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: defaults) == Self.cached)
            #expect(KnowledgeMapSummaries.readCache(at: fileURL) == Self.cached)
            #expect(defaults.object(forKey: KnowledgeMapSummaries.cacheKey) == nil)
        }
    }

    @Test("Without defaults to move from, a read leaves them alone; a missing file reads as empty")
    func readsWithoutMoving() throws {
        try withScratch { defaults, fileURL in
            #expect(KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: nil).isEmpty)
            let stored = try JSONEncoder().encode(Self.cached)
            defaults.set(stored, forKey: KnowledgeMapSummaries.cacheKey)
            #expect(KnowledgeMapSummaries.loadCache(fileURL: fileURL, movingFrom: nil).isEmpty)
            #expect(defaults.data(forKey: KnowledgeMapSummaries.cacheKey) == stored)
        }
    }

    @Test("The cache never synced, and its file sits in the profile's own folder")
    func cacheIsLocalToTheProfile() {
        #expect(!SyncedPreferenceKeys.isSynced(KnowledgeMapSummaries.cacheKey, for: .one))
        #expect(!SyncedPreferenceKeys.isSynced(KnowledgeMapSummaries.cacheKey, for: .two))
        let root = ForeverLMRuntimeIdentity.applicationSupportRootURL.standardizedFileURL.path
        #expect(KnowledgeMapSummaries.cacheFileURL.standardizedFileURL.path.hasPrefix(root + "/"))
    }
}
