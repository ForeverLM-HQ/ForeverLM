import Foundation
import Testing
@testable import ForeverLM

/// URL normalization v1 (§4.1), now in the sync core with its local-path branch injected: on the
/// Mac through `StorageService.relativeSourcePath`, and refused on clients that hold no local files.
/// `schema/vectors/url-normalize.json` pins v1 over the Mac's own fixtures, one edge case per branch
/// and the live library's URLs, so moving the code changed no source id.
@Suite("URL normalizer")
struct URLNormalizerTests {

    @Test("The URL vectors normalize and mint source ids as the Mac always has")
    func vectors() {
        SyncVectorRunner.expectCases("url-normalize", normalizeURL: URLNormalizer.normalize)
    }

    @Test("The Mac's SourceIdentity mints the vectors' source ids")
    func sourceIdentity() throws {
        let directory = try #require(SyncVectorRunner.directory)
        let file = try SyncJSON(parsing: Data(contentsOf: directory.appendingPathComponent("url-normalize.json")))
        for entry in file["cases"]?.arrayValue ?? [] {
            guard let input = entry["input"]?.stringValue, let id = entry["sourceID"]?.stringValue else { continue }
            #expect(SourceIdentity.stableID(for: input) == id, Comment(rawValue: input))
        }
    }

    @Test("Only the Mac normalizes a local path; a client without local files refuses it")
    func localPathsAreInjected() {
        let path = "/Users/someone/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/X.pdf"
        #expect(URLNormalizer.normalize(path) == "Papers/X.pdf")
        #expect(URLNormalizer.normalize(path, localPath: { _ in "injected" }) == "injected")
        #expect(URLNormalizer.normalizeRemote(path) == nil)
        #expect(URLNormalizer.normalizeRemote("https://www.example.com/page/") == "example.com/page")
        #expect(URLNormalizer.normalizeRemote("Papers/X.pdf") == "Papers/X.pdf")
        // The Mac's work key takes the same roots; a client without local files has no key for the path.
        #expect(WorkKey.normalize("url:" + path) == "url:Papers/X.pdf")
        #expect(WorkKey.normalizeRemote("url:" + path) == nil)
    }

    // MARK: - Stored paths (the roots and patterns are resolved once per process)

    @Test func contentRootsAreStableAcrossReads() {
        #expect(StorageService.knownContentRoots == StorageService.knownContentRoots)
        #expect(StorageService.knownContentRoots.first == StorageService.libraryRootPath)
        #expect(StorageService.libraryRootPath == StorageService.localContentRootPath)
    }

    @Test func libraryPathNormalizesToItsRelativeForm() {
        let absolute = (StorageService.libraryRootPath as NSString).appendingPathComponent("Papers/attention.pdf")
        #expect(URLNormalizer.normalize(absolute) == "Papers/attention.pdf")
        #expect(StorageService.absoluteSourcePath("Papers/attention.pdf") == absolute)
    }

    @Test func storedPathsUnderRenamedRootFoldersResolveToTheLibrary() {
        let expected = (StorageService.libraryRootPath as NSString).appendingPathComponent("Papers/attention.pdf")
        // A numbered iCloud fork of the current folder, the Dev folder, and the
        // stray " 4/" a previous normalizer left.
        #expect(StorageService.absoluteSourcePath("ForeverLM 2/Papers/attention.pdf") == expected)
        #expect(StorageService.absoluteSourcePath("ForeverLM Dev/Papers/attention.pdf") == expected)
        #expect(StorageService.absoluteSourcePath(" 4/Papers/attention.pdf") == expected)
        // A folder that merely starts with the name is not a root.
        #expect(StorageService.absoluteSourcePath("ForeverLM Notes/attention.pdf")
            == (StorageService.libraryRootPath as NSString).appendingPathComponent("ForeverLM Notes/attention.pdf"))
    }

    @Test func lowercasesHost() {
        #expect(URLNormalizer.normalize("https://Example.COM/path") == "example.com/path")
    }

    @Test func stripsWWW() {
        #expect(URLNormalizer.normalize("https://www.example.com/page") == "example.com/page")
    }

    @Test func stripsTrailingSlash() {
        #expect(URLNormalizer.normalize("https://example.com/page/") == "example.com/page")
    }

    @Test func stripsTrackingParams() {
        #expect(URLNormalizer.normalize("https://example.com/page?utm_source=twitter&id=5") == "example.com/page?id=5")
    }

    @Test func stripsAllTrackingParamsRemovesQueryEntirely() {
        #expect(URLNormalizer.normalize("https://example.com/page?utm_source=twitter&utm_medium=social") == "example.com/page")
    }

    @Test func stripsFragment() {
        #expect(URLNormalizer.normalize("https://example.com/page#section") == "example.com/page")
    }

    @Test func youTubeCanonical() {
        let expected = "youtube.com/watch?v=dQw4w9WgXcQ"
        #expect(URLNormalizer.normalize("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf") == expected)
        #expect(URLNormalizer.normalize("https://youtu.be/dQw4w9WgXcQ") == expected)
        #expect(URLNormalizer.normalize("https://m.youtube.com/watch?v=dQw4w9WgXcQ") == expected)
    }

    @Test func stripsScheme() {
        #expect(URLNormalizer.normalize("http://example.com/page") == "example.com/page")
    }

    @Test func handlesGarbageInputGracefully() {
        let garbage = "not a url at all"
        #expect(URLNormalizer.normalize(garbage) == garbage)
    }

    @Test func stripsFbclidAndGclid() {
        #expect(URLNormalizer.normalize("https://example.com/page?fbclid=abc123&real=yes") == "example.com/page?real=yes")
        #expect(URLNormalizer.normalize("https://example.com/page?gclid=abc123") == "example.com/page")
    }

    @Test func idempotent() {
        let once = URLNormalizer.normalize("https://www.Example.COM/page/?utm_source=twitter#section")
        #expect(URLNormalizer.normalize(once) == once)
    }

    @Test func localFilePathStripsToRelative() {
        let path = "/Users/reader/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/10.1038_s41419.pdf"
        #expect(URLNormalizer.normalize(path) == "Papers/10.1038_s41419.pdf")
    }

    @Test func localFilePathDifferentUsername() {
        let pathA = "/Users/learner/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/X.pdf"
        let pathB = "/Users/reader/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/X.pdf"
        #expect(URLNormalizer.normalize(pathA) == URLNormalizer.normalize(pathB))
    }

    @Test func foreignApplicationSupportPathReducesWhateverBuildWroteIt() {
        // Another Mac's local content root carries no `Documents/<root>` marker,
        // so only the home-relative suffix can reduce it — and that suffix names
        // the build that wrote the path, not the one reading it. A release Mac's
        // path must reduce in a Dev build and a Dev Mac's in a release build.
        #expect(StorageService.relativeSourcePath("/Users/another/Library/Application Support/ForeverLM/Content/Articles/synced-archive/article.html")
            == "Articles/synced-archive/article.html")
        #expect(StorageService.relativeSourcePath("/Users/another/Library/Application Support/ForeverLM Dev/Content/Papers/X.pdf") == "Papers/X.pdf")
        // A folder that is not a library root is not a root, however deep.
        #expect(StorageService.relativeSourcePath("/Users/another/Library/Application Support/Other/Content/Papers/X.pdf")
            == "/Users/another/Library/Application Support/Other/Content/Papers/X.pdf")
    }

    @Test func numberedICloudConflictFolderNormalizesToCanonicalRelativePath() {
        let path = "/Users/reader/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM 4/Papers/X.pdf"
        #expect(URLNormalizer.normalize(path) == "Papers/X.pdf")
        #expect(StorageService.relativeSourcePath("ForeverLM 4/Papers/X.pdf") == "Papers/X.pdf")
        // Root-layout independent: the conflict remnant must resolve to the same
        // absolute file as the clean relative path, whatever root this build uses.
        #expect(StorageService.absoluteSourcePath(" 4/Papers/X.pdf") == StorageService.absoluteSourcePath("Papers/X.pdf"))
    }

    @Test func localPathNormalizationIsLexical() {
        let path = "/Users/reader//Library/Mobile Documents/iCloud~com~foreverlm/Documents/./ForeverLM 4/Papers/Drafts/../X.pdf"
        #expect(URLNormalizer.normalize(path) == "Papers/X.pdf")
    }

    @Test func similarFolderNamesAreNotTreatedAsLibraryRoot() {
        let path = "/Users/reader/Library/Mobile Documents/iCloud~com~apple~CloudDocs/Documents/ForeverLMVision/Papers/X.pdf"
        #expect(URLNormalizer.normalize(path) == path)
    }

    @Test func alreadyRelativePathUnchanged() {
        #expect(URLNormalizer.normalize("Papers/X.pdf") == "Papers/X.pdf")
    }

    @Test func applePodcastEpisodeURLsUseCanonicalSchemeForm() {
        #expect(URLNormalizer.normalize("apple-podcast:/episode/1000758651501") == "apple-podcast://episode/1000758651501")
        #expect(URLNormalizer.normalize("apple-podcast://episode/1000758651501") == "apple-podcast://episode/1000758651501")
        #expect(URLNormalizer.normalize("apple-podcast://episode/private/stable-feed-hash") == "apple-podcast://episode/private/stable-feed-hash")
    }

    @Test func scienceDirectPIIURLsCanonicalizeAcrossAbstractAndArticleForms() {
        let canonical = "sciencedirect.com/science/article/pii/S1568163724001284"
        #expect(URLNormalizer.normalize("https://www.sciencedirect.com/science/article/pii/S1568163724001284") == canonical)
        #expect(URLNormalizer.normalize("https://www.sciencedirect.com/science/article/abs/pii/S1568163724001284?via%3Dihub") == canonical)
    }

    /// On 2026-09-12 a Nature paper saved from a recommendation link kept
    /// `?fromPaywallRec=false` in its key, so the chat's web sources footer did
    /// not recognise the bare address a web search cited and offered Add to
    /// Sources for a paper already in the library.
    @Test func springerNatureArticleURLsCanonicalizeAcrossPageRecommendationAndPDFForms() {
        let canonical = "nature.com/articles/s42003-022-04303-x"
        #expect(URLNormalizer.normalize("https://www.nature.com/articles/s42003-022-04303-x") == canonical)
        #expect(URLNormalizer.normalize("https://www.nature.com/articles/s42003-022-04303-x?fromPaywallRec=false") == canonical)
        #expect(URLNormalizer.normalize("https://www.nature.com/articles/s42003-022-04303-x.pdf") == canonical)
        // Other nature.com pages keep their own address.
        #expect(URLNormalizer.normalize("https://www.nature.com/commsbio/") == "nature.com/commsbio")
        #expect(URLNormalizer.normalize("https://www.nature.com/search?q=oxphos") == "nature.com/search?q=oxphos")
    }

    @Test func cellPressPIIURLsCanonicalizeAcrossLandingAndPDFForms() {
        let canonical = "cell.com/pii/S1097-2765(26)00310-2"
        #expect(URLNormalizer.normalize("https://www.cell.com/molecular-cell/fulltext/S1097-2765(26)00310-2?utm_source=li&utm_medium=organic&utm_campaign=hl") == canonical)
        #expect(URLNormalizer.normalize("https://www.cell.com/action/showPdf?pii=S1097-2765(26)00310-2") == canonical)
    }
}
