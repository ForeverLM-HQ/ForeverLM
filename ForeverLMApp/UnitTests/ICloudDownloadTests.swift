import Darwin
import Foundation
import Testing
@testable import ForeverLM

@Suite("iCloud download failures")
struct ICloudDownloadTests {
    @Test("Dataless File Provider metadata is never treated as locally available")
    func recognizesDatalessMetadata() {
        #expect(ICloudDownload.isDatalessFileMetadata(
            size: 1_669_732,
            blocks: 0,
            flags: UInt32(SF_DATALESS),
            path: "/tmp/paper.pdf"
        ))
        #expect(ICloudDownload.isDatalessFileMetadata(
            size: 1_669_732,
            blocks: 0,
            flags: 0,
            path: "/Users/test/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/paper.pdf"
        ))
        #expect(!ICloudDownload.isDatalessFileMetadata(
            size: 1_669_732,
            blocks: 0,
            flags: 0,
            path: "/tmp/local-sparse-file.pdf"
        ))
        #expect(!ICloudDownload.isDatalessFileMetadata(
            size: 1_669_732,
            blocks: 3_264,
            flags: 0,
            path: "/Users/test/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/paper.pdf"
        ))
    }

    @Test("No-space errors are preserved through File Provider wrappers")
    func recognizesNestedNoSpaceError() {
        let noSpace = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSUnderlyingErrorKey: noSpace]
        )

        #expect(
            ICloudDownload.classifiedFailure(for: wrapper, availableCapacity: nil)
                == .insufficientStorage
        )
    }

    @Test("A generic plug-in error is made actionable when disk space is exhausted")
    func recognizesLowCapacityBehindGenericPluginError() {
        let pluginError = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSLocalizedDescriptionKey: "The plug-in returned an error."]
        )

        #expect(
            ICloudDownload.classifiedFailure(for: pluginError, availableCapacity: 1_000_000_000)
                == .insufficientStorage
        )
        #expect(
            ICloudDownload.classifiedFailure(for: pluginError, availableCapacity: 10_000_000_000)
                == .requestFailed("The plug-in returned an error.")
        )
    }
}

@Suite("Article archive cache")
struct ArticleArchiveCacheTests {
    @Test("Missing rich archive lazily loads durable article text")
    func missingArchiveLoadsPersistedFallback() async {
        var loadCount = 0
        let fallback = await ArchivedArticleFallback.resolve(inMemory: nil) {
            loadCount += 1
            return "Text retained in source_content."
        }

        #expect(fallback == "Text retained in source_content.")
        #expect(loadCount == 1)
    }

    @Test("Loaded article text avoids a redundant durable read")
    func inMemoryArchiveFallbackWins() async {
        var loadCount = 0
        let fallback = await ArchivedArticleFallback.resolve(inMemory: "Already loaded.") {
            loadCount += 1
            return "Persisted text."
        }

        #expect(fallback == "Already loaded.")
        #expect(loadCount == 0)
    }

    @Test("Background warm migrates historical article directories once")
    func backgroundWarmMigratesHistoricalArchives() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleArchiveWarmTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let articlesRoot = temporaryRoot.appendingPathComponent("Articles", isDirectory: true)
        let sourceRoot = articlesRoot.appendingPathComponent("src_historical", isDirectory: true)
        let cacheRoot = temporaryRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try "<html>historical</html>".write(
            to: sourceRoot.appendingPathComponent("article.html"),
            atomically: true,
            encoding: .utf8
        )
        let cache = ArticleArchiveCache(rootURL: cacheRoot)

        let firstWarm = await cache.warmExistingArchives(canonicalArticlesRoot: articlesRoot)
        let secondWarm = await cache.warmExistingArchives(canonicalArticlesRoot: articlesRoot)

        #expect(firstWarm.discovered == 1)
        #expect(firstWarm.newlyCached == 1)
        #expect(firstWarm.failed == 0)
        #expect(secondWarm.discovered == 1)
        #expect(secondWarm.alreadyCached == 1)
        #expect(secondWarm.newlyCached == 0)
    }

    @Test("A complete archive stays readable after the canonical copy disappears")
    func cachedArchiveIsIndependentFromCanonicalCopy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let cache = ArticleArchiveCache(rootURL: fixture.cacheRoot)
        let cachedPath = try await cache.prepare(
            canonicalHTMLPath: fixture.htmlURL.path,
            sourceID: "src_article"
        )
        let cachedURL = URL(fileURLWithPath: cachedPath)
        let cachedImageURL = cachedURL
            .deletingLastPathComponent()
            .appendingPathComponent("images/figure.png")

        #expect(try String(contentsOf: cachedURL, encoding: .utf8) == "<html>version one</html>")
        #expect(try Data(contentsOf: cachedImageURL) == Data([0x01, 0x02, 0x03]))

        try FileManager.default.removeItem(at: fixture.canonicalRoot)
        let reopenedPath = try await cache.prepare(
            canonicalHTMLPath: fixture.htmlURL.path,
            sourceID: "src_article"
        )

        #expect(reopenedPath == cachedPath)
        #expect(try String(contentsOfFile: reopenedPath, encoding: .utf8) == "<html>version one</html>")
    }

    @Test("Existing local archives repair mojibake without rewriting canonical data")
    func existingCacheRepairsMojibake() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
        let cache = ArticleArchiveCache(rootURL: fixture.cacheRoot)
        let cachedPath = try await cache.prepare(
            canonicalHTMLPath: fixture.htmlURL.path,
            sourceID: "src_article"
        )
        try "<html>itâ€™s cached</html>".write(
            toFile: cachedPath,
            atomically: true,
            encoding: .utf8
        )

        _ = try await cache.prepare(
            canonicalHTMLPath: fixture.htmlURL.path,
            sourceID: "src_article"
        )

        #expect(try String(contentsOfFile: cachedPath, encoding: .utf8) == "<html>it’s cached</html>")
        #expect(try String(contentsOf: fixture.htmlURL, encoding: .utf8) == "<html>version one</html>")
    }

    @Test("Import refresh replaces an older local archive")
    func refreshReplacesCachedArchive() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let cache = ArticleArchiveCache(rootURL: fixture.cacheRoot)
        _ = try await cache.prepare(
            canonicalHTMLPath: fixture.htmlURL.path,
            sourceID: "src_article"
        )
        try "<html>version two</html>".write(
            to: fixture.htmlURL,
            atomically: true,
            encoding: .utf8
        )

        let refreshedPath = try await cache.prepare(
            canonicalHTMLPath: fixture.htmlURL.path,
            sourceID: "src_article",
            refresh: true
        )

        #expect(try String(contentsOfFile: refreshedPath, encoding: .utf8) == "<html>version two</html>")
    }

    private func makeFixture() throws -> (
        temporaryRoot: URL,
        canonicalRoot: URL,
        cacheRoot: URL,
        htmlURL: URL
    ) {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleArchiveCacheTests-\(UUID().uuidString)", isDirectory: true)
        let canonicalRoot = temporaryRoot.appendingPathComponent("Canonical", isDirectory: true)
        let imagesRoot = canonicalRoot.appendingPathComponent("images", isDirectory: true)
        let cacheRoot = temporaryRoot.appendingPathComponent("Cache", isDirectory: true)
        let htmlURL = canonicalRoot.appendingPathComponent("article.html")

        try FileManager.default.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        try "<html>version one</html>".write(to: htmlURL, atomically: true, encoding: .utf8)
        try Data([0x01, 0x02, 0x03]).write(to: imagesRoot.appendingPathComponent("figure.png"))
        return (temporaryRoot, canonicalRoot, cacheRoot, htmlURL)
    }
}
