import Testing
import Foundation
@testable import ForeverLM

@Suite("Paper Browser Verification Detection")
struct PaperBrowserVerificationDetectionTests {
    @Test("A title the page supplied may be renamed by the metadata model; one the learner typed stays")
    func articleTitleIsPageSupplied() {
        var evidence = PaperService.WebArticleTitleEvidence()
        evidence.documentTitle = "Waypoint Bio: Immune Engineering \u{2014} Amplify Partners"
        evidence.headline = "Waypoint Bio: Immune Engineering"
        evidence.siteName = "Amplify Partners"
        let url = "https://www.amplifypartners.com/blog-posts/waypoint-bio-immune-engineering"
        let domain = "www.amplifypartners.com"
        #expect(StudioViewModel.articleTitleIsPageSupplied(
            "Waypoint Bio: Immune Engineering \u{2014} Amplify Partners",
            pageTitle: "Waypoint Bio: Immune Engineering \u{2014} Amplify Partners", evidence: evidence, domain: domain, url: url
        ), "the head's title is the page's")
        #expect(StudioViewModel.articleTitleIsPageSupplied("Waypoint Bio: Immune Engineering", pageTitle: nil, evidence: evidence, domain: domain, url: url), "so is the headline")
        #expect(StudioViewModel.articleTitleIsPageSupplied("Amplify Partners", pageTitle: nil, evidence: evidence, domain: domain, url: url), "and the site's name")
        #expect(StudioViewModel.articleTitleIsPageSupplied("www.amplifypartners.com", pageTitle: nil, evidence: evidence, domain: domain, url: url), "and the host placeholder")
        #expect(!StudioViewModel.articleTitleIsPageSupplied(
            "Amplify's essay on Waypoint",
            pageTitle: "Waypoint Bio: Immune Engineering \u{2014} Amplify Partners", evidence: evidence, domain: domain, url: url
        ), "a title a person typed is theirs")
    }

    @Test("Recognizes a Cloudflare managed challenge")
    func recognizesCloudflareChallenge() {
        #expect(SourceDiscovery.PaperAIBrowserDownloadService.isSecurityVerificationPage(
            title: "Just a moment...",
            visibleText: "Enable JavaScript and cookies to continue",
            url: "https://www.science.org/doi/pdf/10.1126/sciadv.aed9156?__cf_chl_rt_tk=token"
        ))
        #expect(SourceDiscovery.PaperAIBrowserDownloadService.isSecurityVerificationPage(
            title: "Security Verification",
            visibleText: "",
            url: "https://pubs.rsc.org/en/content/articlepdf/2022/cs/d0cs01610a"
        ))
    }

    @Test("Does not confuse a normal article with a security challenge")
    func acceptsNormalArticlePage() {
        #expect(!SourceDiscovery.PaperAIBrowserDownloadService.isSecurityVerificationPage(
            title: "Illuminating aging with multimodal optical metabolic imaging",
            visibleText: "Download PDF References Supporting information",
            url: "https://www.science.org/doi/10.1126/sciadv.aed9156"
        ))
    }

    @Test("Refuses to store a bot-check page as source content")
    func rejectsChallengeTextAsContent() {
        // The exact wall this library stored for two Wiley papers, which then
        // sat `.ready` over it while their PDFs were on disk all along.
        let wiley = """
        Pasta, a Versatile Transcriptomic Clock, Maps the Chemical and Genetic \
        Determinants of Aging and Rejuvenation

        advanced.onlinelibrary.wiley.com
        Performing security verification
        This website uses a security service to protect against malicious bots. \
        This page is displayed while the website verifies you are not a bot.
        Ray ID: a3153a3008358f67
        Performance and Security by Cloudflare
        Privacy
        """
        #expect(SourceDiscovery.isSecurityVerificationContent(
            text: wiley,
            title: "Pasta, a Versatile Transcriptomic Clock",
            url: "https://advanced.onlinelibrary.wiley.com/doi/10.1002/advs.76740"
        ))
    }

    @Test("A paper about bot detection is not mistaken for a bot check")
    func keepsRealDocumentAboutChallenges() {
        // Same trigger phrases, but at document length. The persistence gate
        // must not discard a real paper on its own subject matter.
        let paper = String(
            repeating: "We evaluate how often users are asked to verify you are human "
                + "when checking your browser against a managed challenge. ",
            count: 60
        )
        #expect(paper.count > SourceDiscovery.securityVerificationContentCeiling)
        #expect(!SourceDiscovery.isSecurityVerificationContent(
            text: paper,
            title: "Measuring the cost of interactive bot challenges",
            url: "https://example.org/paper.pdf"
        ))
    }

    @Test("A short real abstract survives the persistence gate")
    func keepsShortAbstract() {
        let abstract = """
        Mitochondrial free radical production and aging in mammals and birds. \
        We compared rates of hydrogen peroxide generation across species and \
        found that longer-lived birds produce less per unit of oxygen consumed.
        """
        #expect(!SourceDiscovery.isSecurityVerificationContent(
            text: abstract,
            title: "Mitochondrial Free Radical Production and Aging",
            url: "https://example.org/abstract"
        ))
    }

    @Test("A redirect page's title never sticks to a source")
    func redirectTitleNeedsResolution() {
        // Elsevier's linkinghub answers every 10.1016 DOI with a page titled
        // "Redirecting"; four papers wore it as their title on 2026-09-18.
        #expect(StudioViewModel.titleNeedsResolution(
            "Redirecting",
            domain: "linkinghub.elsevier.com",
            url: "https://doi.org/10.1016/j.cmet.2022.02.001"
        ))
        #expect(StudioViewModel.titleNeedsResolution(
            "linkinghub.elsevier.com",
            domain: "doi.org",
            url: "https://linkinghub.elsevier.com/retrieve/pii/S1550413122000456"
        ))
        #expect(!StudioViewModel.titleNeedsResolution(
            "Redirecting T cells against cancer",
            domain: "www.cell.com",
            url: "https://www.cell.com/immunity/fulltext/S1074-7613(20)30001-1"
        ))
    }

    @Test("A bot-check title never sticks to a source")
    func challengeTitleNeedsResolution() {
        #expect(StudioViewModel.titleNeedsResolution(
            "Just a moment...",
            domain: "www.cell.com",
            url: "https://www.cell.com/action/showPdf?pii=S0092-8674%2824%2900304-0"
        ))
        #expect(!StudioViewModel.titleNeedsResolution(
            "Apoptotic stress causes mtDNA release during senescence",
            domain: "www.nature.com",
            url: "https://www.nature.com/articles/s41586-023-06621-4"
        ))
    }

    @Test("Waits for a metadata-only page before asking the AI browser")
    func waitsForMetadataOnlyPage() {
        #expect(SourceDiscovery.PaperAIBrowserDownloadService.pageNeedsContentWait(
            visibleText: "  \n ",
            candidateCount: 0
        ))
        #expect(!SourceDiscovery.PaperAIBrowserDownloadService.pageNeedsContentWait(
            visibleText: "Open-access article",
            candidateCount: 0
        ))
        #expect(!SourceDiscovery.PaperAIBrowserDownloadService.pageNeedsContentWait(
            visibleText: "",
            candidateCount: 1
        ))
    }
}

// MARK: - Safari Reading List Parsing

@Suite("Safari Reading List Parsing")
struct SafariReadingListParsingTests {

    @Test("Parses reading list entries from valid plist data")
    func parseValidPlist() throws {
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "com.apple.ReadingList",
                    "Children": [
                        [
                            "URLString": "https://example.com/article1",
                            "URIDictionary": ["title": "Example Article"],
                            "ReadingList": ["DateAdded": Date(timeIntervalSince1970: 1_700_000_000)],
                            "imageURL": "https://example.com/og-image.jpg"
                        ] as [String: Any],
                        [
                            "URLString": "https://example.com/article2",
                            "URIDictionary": ["title": "Another Article"],
                            "ReadingList": [:] as [String: Any]
                        ] as [String: Any],
                    ]
                ] as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let result = SourceDiscovery.parseSafariReadingList(data: data)

        #expect(result.count == 2)
        #expect(result[0].url == "https://example.com/article1")
        #expect(result[0].title == "Example Article")
        #expect(result[0].dateAdded != nil)
        #expect(result[0].imageURL == "https://example.com/og-image.jpg")
        #expect(result[1].url == "https://example.com/article2")
        #expect(result[1].title == "Another Article")
        #expect(result[1].dateAdded == nil)
        #expect(result[1].imageURL == nil)
    }

    @Test("Falls back to PreviewText when title is missing")
    func fallbackToPreviewText() throws {
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "com.apple.ReadingList",
                    "Children": [
                        [
                            "URLString": "https://example.com/no-title",
                            "URIDictionary": [:] as [String: Any],
                            "ReadingList": ["PreviewText": "A preview of the article"]
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let result = SourceDiscovery.parseSafariReadingList(data: data)

        #expect(result.count == 1)
        #expect(result[0].title == "A preview of the article")
    }

    @Test("Decodes HTML character references in titles")
    func decodesHTMLCharacterReferencesInTitles() throws {
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "com.apple.ReadingList",
                    "Children": [
                        [
                            "URLString": "https://example.com/portuguese",
                            "URIDictionary": ["title": "de Magalh&#227;es &amp; mem&#xF3;ria"],
                            "ReadingList": [:] as [String: Any]
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let result = SourceDiscovery.parseSafariReadingList(data: data)

        #expect(result.count == 1)
        #expect(result[0].title == "de Magalh\u{00E3}es & mem\u{00F3}ria")
    }

    @Test("Falls back to URL when title and preview are both missing")
    func fallbackToURL() throws {
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "com.apple.ReadingList",
                    "Children": [
                        [
                            "URLString": "https://example.com/bare-url",
                            "URIDictionary": [:] as [String: Any],
                            "ReadingList": [:] as [String: Any]
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let result = SourceDiscovery.parseSafariReadingList(data: data)

        #expect(result.count == 1)
        #expect(result[0].title == "https://example.com/bare-url")
    }

    @Test("Returns empty for plist without Reading List node")
    func noReadingListNode() throws {
        let plist: [String: Any] = [
            "Children": [
                ["Title": "BookmarksBar", "Children": [] as [[String: Any]]] as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let result = SourceDiscovery.parseSafariReadingList(data: data)
        #expect(result.isEmpty)
    }

    @Test("Returns empty for invalid data")
    func invalidData() {
        let result = SourceDiscovery.parseSafariReadingList(data: Data("not a plist".utf8))
        #expect(result.isEmpty)
    }

    @Test("Skips items without URLString")
    func skipsItemsWithoutURL() throws {
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "com.apple.ReadingList",
                    "Children": [
                        ["URIDictionary": ["title": "No URL"]] as [String: Any],
                        [
                            "URLString": "https://valid.com",
                            "URIDictionary": ["title": "Has URL"],
                            "ReadingList": [:] as [String: Any]
                        ] as [String: Any],
                    ]
                ] as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let result = SourceDiscovery.parseSafariReadingList(data: data)
        #expect(result.count == 1)
        #expect(result[0].url == "https://valid.com")
    }

}

// MARK: - Chrome/Brave Bookmarks Parsing

@Suite("Chrome Bookmarks Parsing")
struct ChromeBookmarksParsingTests {

    @Test("Parses reading list from Chrome Bookmarks JSON")
    func parseValidJSON() throws {
        let json: [String: Any] = [
            "roots": [
                "reading_list": [
                    "children": [
                        [
                            "url": "https://chrome-article.com",
                            "name": "Chrome Article",
                            "date_added": "13350000000000000"
                        ] as [String: Any]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = SourceDiscovery.parseChromeBookmarks(data: data)

        #expect(result.count == 1)
        #expect(result[0].url == "https://chrome-article.com")
        #expect(result[0].title == "Chrome Article")
        #expect(result[0].dateAdded != nil)
    }

    @Test("Decodes HTML character references in titles")
    func decodesHTMLCharacterReferencesInTitles() throws {
        let json: [String: Any] = [
            "roots": [
                "reading_list": [
                    "children": [
                        [
                            "url": "https://chrome-article.com",
                            "name": "Jo&atilde;o Magalh&#227;es &amp; mem&#xF3;ria",
                        ] as [String: Any]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = SourceDiscovery.parseChromeBookmarks(data: data)

        #expect(result.count == 1)
        #expect(result[0].title == "Jo\u{00E3}o Magalh\u{00E3}es & mem\u{00F3}ria")
    }

    @Test("Parses nested Chromium reading list folder layouts")
    func parseNestedReadingListLayout() throws {
        let json: [String: Any] = [
            "roots": [
                "reading_list": [
                    "children": [
                        [
                            "name": "Unread",
                            "type": "folder",
                            "children": [
                                [
                                    "url": "https://nested-entry.com",
                                    "name": "Nested Entry",
                                    "date_added": "13350000000000000",
                                ] as [String: Any],
                            ],
                        ] as [String: Any],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = SourceDiscovery.parseChromeBookmarks(data: data)

        #expect(result.count == 1)
        #expect(result[0].url == "https://nested-entry.com")
        #expect(result[0].title == "Nested Entry")
        #expect(result[0].dateAdded != nil)
    }

    @Test("Falls back to URL when name is missing")
    func fallbackToURL() throws {
        let json: [String: Any] = [
            "roots": [
                "reading_list": [
                    "children": [
                        ["url": "https://no-name.com"] as [String: Any]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = SourceDiscovery.parseChromeBookmarks(data: data)

        #expect(result.count == 1)
        #expect(result[0].title == "https://no-name.com")
    }

    @Test("Returns empty when no reading_list root")
    func noReadingListRoot() throws {
        let json: [String: Any] = [
            "roots": [
                "bookmark_bar": ["children": [] as [[String: Any]]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = SourceDiscovery.parseChromeBookmarks(data: data)
        #expect(result.isEmpty)
    }

    @Test("Returns empty for invalid JSON")
    func invalidJSON() {
        let result = SourceDiscovery.parseChromeBookmarks(data: Data("not json".utf8))
        #expect(result.isEmpty)
    }

    @Test("Handles missing date_added gracefully")
    func missingDateAdded() throws {
        let json: [String: Any] = [
            "roots": [
                "reading_list": [
                    "children": [
                        ["url": "https://no-date.com", "name": "No Date"] as [String: Any]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let result = SourceDiscovery.parseChromeBookmarks(data: data)

        #expect(result.count == 1)
        #expect(result[0].dateAdded == nil)
    }
}

// MARK: - TTML Store Track ID Extraction

@Suite("TTML Store Track ID Extraction")
struct TTMLStoreTrackIdTests {

    @Test("Extracts store track ID from standard TTML path", arguments: [
        ("/path/to/TTML/PodcastContent221/v4/xx/yy/zz/uuid/transcript_1000751939405.ttml-1000751939405.ttml", Int64(1000751939405)),
        ("/path/transcript_42.ttml-42.ttml", Int64(42)),
        ("/deep/nested/transcript_1000688682418.ttml-1000688682418.ttml", Int64(1000688682418)),
    ])
    func validPaths(path: String, expectedId: Int64) {
        let result = SourceDiscovery.storeTrackId(fromTTMLPath: path)
        #expect(result == expectedId)
    }

    @Test("Returns nil for non-transcript filenames", arguments: [
        "/path/to/other_file.ttml",
        "/path/to/transcript_.ttml",
        "/path/to/something.xml",
        "/path/to/readme.md",
    ])
    func invalidPaths(path: String) {
        let result = SourceDiscovery.storeTrackId(fromTTMLPath: path)
        #expect(result == nil)
    }
}

// MARK: - Artwork URL Resolution

@Suite("Artwork URL Resolution")
struct ArtworkURLResolutionTests {

    @Test("Resolves template with all placeholders")
    func resolveFullTemplate() {
        let template = "https://is1-ssl.mzstatic.com/image/thumb/Podcasts/v4/abc/{w}x{h}bb.{f}"
        let result = SourceDiscovery.resolveArtworkURL(template: template, width: 100, height: 100)
        #expect(result == "https://is1-ssl.mzstatic.com/image/thumb/Podcasts/v4/abc/100x100bb.jpg")
    }

    @Test("Uses custom dimensions")
    func customDimensions() {
        let template = "https://example.com/{w}x{h}bb.{f}"
        let result = SourceDiscovery.resolveArtworkURL(template: template, width: 300, height: 300)
        #expect(result == "https://example.com/300x300bb.jpg")
    }

    @Test("Returns nil for empty template")
    func emptyTemplate() {
        let result = SourceDiscovery.resolveArtworkURL(template: "")
        #expect(result == nil)
    }

    @Test("Handles template without placeholders (already a concrete URL)")
    func concreteURL() {
        let url = "https://example.com/image/100x100bb.jpg"
        let result = SourceDiscovery.resolveArtworkURL(template: url)
        #expect(result == url)
    }
}

// MARK: - Source Type Detection

@Suite("Source Type Detection")
struct SourceTypeDetectionTests {

    @Test("Detects source types from URLs", arguments: [
        ("https://arxiv.org/abs/2401.12345", StudioSourceType.paper),
        ("https://nature.com/articles/s41586-024-07xxx", StudioSourceType.paper),
        ("https://www.biorxiv.org/content/10.1101/2024.01.01.001", StudioSourceType.paper),
        // Generic local paths (including a Podcasts folder) are no longer force-typed;
        // only /scrape/ paths and .ttml files are deterministic podcast markers, so
        // this falls through to LLM classification.
        ("/Users/test/Documents/Podcasts/episode.txt", StudioSourceType.unclassified),
        ("/Users/test/Documents/Scrape/dwarkesh/ep.md", StudioSourceType.podcast),
        ("/path/to/transcript_123.ttml", StudioSourceType.podcast),
        ("/Users/test/Books/chapter.pdf", StudioSourceType.book),
        ("/Users/test/articles/paper.pdf", StudioSourceType.paper),
        ("/Users/test/ForeverLM/Papers/aging_review.pdf", StudioSourceType.paper),
        ("/Users/test/ForeverLM/Courses/Stat110_Probability/hw1.pdf", StudioSourceType.course),
        ("/Users/test/ForeverLM/Courses/Neuro140_Bio_AI/lecture.pdf", StudioSourceType.course),
        ("https://substack.com/@author/post-title", StudioSourceType.unclassified),
        ("https://paulgraham.com/greatwork.html", StudioSourceType.unclassified),
    ])
    @MainActor func detectSourceType(url: String, expected: StudioSourceType) {
        let result = StudioViewModel.detectSourceType(url: url)
        #expect(result == expected)
    }
}

// MARK: - Name Parsing

#if os(macOS)
@Suite("Book and Course Name Parsing")
struct NameParsingTests {

    @Test("Preserves PDF metadata titles for book metadata AI", arguments: [
        ("Build a Large Language Model (From Scratch) MEAP V06", "Build a Large Language Model (From Scratch) MEAP V06"),
        ("Build a Reasoning Model (From Scratch) MEAP V01", "Build a Reasoning Model (From Scratch) MEAP V01"),
    ])
    @MainActor func normalizedBookTitle(rawTitle: String, expected: String) {
        let result = StudioViewModel.normalizedBookTitle(rawTitle)
        #expect(result == expected)
    }

    @Test("Preserves chapter filename stems", arguments: [
        ("chapter_03.pdf", "chapter_03"),
        ("chapter_01.pdf", "chapter_01"),
        ("Appendix A_ Introduction to PyTorch.pdf", "Appendix A_ Introduction to PyTorch"),
    ])
    @MainActor func chapterTitle(filename: String, expected: String) {
        let result = StudioViewModel.chapterTitle(filename)
        #expect(result == expected)
    }

}
#endif

// MARK: - Apple Podcasts SQLite Metadata Lookup

#if os(macOS)
import SQLite3

@Suite("Apple Podcasts DB Lookup")
struct PodcastMetadataLookupTests {

    private func createTempDB() throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let dbPath = tmpDir.appendingPathComponent("test_podcasts_\(UUID().uuidString).sqlite").path

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }

        sqlite3_exec(db, """
            CREATE TABLE ZMTPODCAST (
                Z_PK INTEGER PRIMARY KEY,
                ZTITLE TEXT,
                ZIMAGEURL TEXT,
                ZARTWORKTEMPLATEURL TEXT,
                ZSUBSCRIBED INTEGER,
                ZISIMPLICITLYFOLLOWED INTEGER,
                ZSTORECOLLECTIONID INTEGER
            );
            CREATE TABLE ZMTEPISODE (
                Z_PK INTEGER PRIMARY KEY,
                ZPODCAST INTEGER,
                ZSTORETRACKID INTEGER,
                ZTITLE TEXT,
                ZTRANSCRIPTIDENTIFIER TEXT,
                ZARTWORKTEMPLATEURL TEXT,
                ZWEBPAGEURL TEXT,
                ZUUID TEXT,
                ZGUID TEXT,
                ZITEMDESCRIPTIONWITHOUTHTML TEXT,
                ZITEMDESCRIPTION TEXT,
                ZITUNESSUBTITLE TEXT,
                ZENCLOSUREURL TEXT,
                ZLASTDATEPLAYED REAL,
                ZPLAYSTATELASTMODIFIEDDATE REAL,
                ZPLAYSTATE INTEGER,
                ZPLAYHEAD REAL,
                ZHASBEENPLAYED INTEGER,
                ZPLAYCOUNT INTEGER,
                ZLISTENNOWEPISODE INTEGER,
                ZISBOOKMARKED INTEGER,
                ZDOWNLOADDATE REAL,
                ZDOWNLOADPATH TEXT,
                ZUSERDELETED INTEGER,
                ZPUBDATE REAL
            );
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE, ZARTWORKTEMPLATEURL)
            VALUES (1, 'Dwarkesh Podcast', 'https://example.com/podcast/{w}x{h}bb.{f}');
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE, ZIMAGEURL)
            VALUES (2, 'Owl Posting', 'https://example.com/owl/300x300bb.jpg');
            INSERT INTO ZMTEPISODE (Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE)
            VALUES (1, 1, 987654321, 'Interview with Scientist');
            INSERT INTO ZMTEPISODE (Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE)
            VALUES (2, 2, 123456789, 'How vaccines work');
        """, nil, nil, nil)

        sqlite3_close(db)
        return dbPath
    }

    @Test("Looks up episode metadata by store track ID")
    func lookupMetadata() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let results = SourceDiscovery.lookupPodcastMetadata(
            dbPath: dbPath,
            storeTrackIds: [987654321, 123456789]
        )

        #expect(results.count == 2)

        let ep1 = results[987654321]
        #expect(ep1?.episodeTitle == "Interview with Scientist")
        #expect(ep1?.podcastName == "Dwarkesh Podcast")
        #expect(ep1?.artworkURL?.contains("100x100bb.jpg") == true)

        let ep2 = results[123456789]
        #expect(ep2?.episodeTitle == "How vaccines work")
        #expect(ep2?.podcastName == "Owl Posting")
        // Owl Posting has ZIMAGEURL instead of template
        #expect(ep2?.artworkURL != nil)
    }

    @Test("Returns empty for non-existent DB path")
    func nonExistentDB() {
        let results = SourceDiscovery.lookupPodcastMetadata(
            dbPath: "/nonexistent/path/MTLibrary.sqlite",
            storeTrackIds: [123]
        )
        #expect(results.isEmpty)
    }

    @Test("Returns empty for empty track ID list")
    func emptyTrackIds() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let results = SourceDiscovery.lookupPodcastMetadata(dbPath: dbPath, storeTrackIds: [])
        #expect(results.isEmpty)
    }

    @Test("Returns empty when no matching track IDs")
    func noMatchingIds() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let results = SourceDiscovery.lookupPodcastMetadata(dbPath: dbPath, storeTrackIds: [999999999])
        #expect(results.isEmpty)
    }

    @Test("Discovers private RSS episodes without store track IDs")
    func discoversPrivateRSSEpisodes() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let playedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 2,
            day: 1
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE, ZIMAGEURL)
            VALUES (3, 'The Peter Attia Drive - Private Subscriber Feed', 'https://example.com/drive.jpg');
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE, ZUUID, ZGUID,
                ZITEMDESCRIPTIONWITHOUTHTML, ZENCLOSUREURL, ZLASTDATEPLAYED, ZPLAYSTATE
            ) VALUES (
                3, 3, 0, '#387 - AMA #83', 'LOCAL-PRIVATE-UUID',
                'https://peterattia.supercast.tech/episodes/988695?key=secret',
                'Private feed show notes about peptides.',
                'https://feeds.supercast.com/episodes/private-audio', \(playedAt), 1
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(status == .ok)
        #expect(episodes.contains { episode in
            episode.storeTrackId == nil
                && episode.episodeUUID == "LOCAL-PRIVATE-UUID"
                && episode.episodeTitle == "#387 - AMA #83"
                && episode.episodeDescription == "Private feed show notes about peptides."
        })
    }

    @Test("Discovers in-progress episodes without last played timestamps")
    func discoversInProgressEpisodesWithoutLastPlayed() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let modifiedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 5,
            day: 1
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE,
                ZPLAYHEAD, ZPLAYSTATELASTMODIFIEDDATE, ZPLAYSTATE
            ) VALUES (
                6, 1, 555123, 'Partially Started Episode',
                42.0, \(modifiedAt), 1
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(status == .ok)
        #expect(episodes.contains { episode in
            episode.storeTrackId == 555123
                && episode.episodeTitle == "Partially Started Episode"
                && episode.lastDatePlayed == Date(timeIntervalSinceReferenceDate: modifiedAt)
        })
    }

    @Test("Skips old episodes touched by Apple play-state migration")
    func skipsOldEpisodesTouchedByPlayStateMigration() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let oldPlayedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2023,
            month: 6,
            day: 22
        ).date!.timeIntervalSinceReferenceDate
        let migrationTouchedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 1,
            day: 2
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE,
                ZLASTDATEPLAYED, ZPLAYHEAD, ZPLAYSTATELASTMODIFIEDDATE, ZPLAYSTATE
            ) VALUES (
                9, 1, 999123, 'Old Biotech Episode',
                \(oldPlayedAt), 1449.0, \(migrationTouchedAt), 1
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(status == .noEpisodesFound)
        #expect(episodes.isEmpty)
    }

    @Test("Skips migrated play counts without playback position")
    func skipsMigratedPlayCountsWithoutPlaybackPosition() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let migrationTouchedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 1,
            day: 2
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE,
                ZPLAYCOUNT, ZPLAYSTATELASTMODIFIEDDATE, ZPLAYHEAD
            ) VALUES (
                10, 1, 111123, 'Migrated Counter Episode',
                1, \(migrationTouchedAt), 0
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(status == .noEpisodesFound)
        #expect(episodes.isEmpty)
    }

    @Test("Skips transcript catalog episodes without engagement state")
    func skipsTranscriptCatalogEpisodesWithoutEngagement() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE,
                ZTRANSCRIPTIDENTIFIER, ZITEMDESCRIPTIONWITHOUTHTML
            ) VALUES (
                7, 1, 777123, 'Energy Resistance Principle',
                'PodcastContent/v4/transcript_777123.ttml',
                'A conversation with Martin Picard about mitochondria.'
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.searchPodcastCatalogEpisodes(
            dbPath: dbPath,
            query: "Martin Picard",
            scope: .listened
        )

        #expect(status == .noEpisodesFound)
        #expect(episodes.isEmpty)
    }

    @Test("Searches transcript catalog episodes with listening progress")
    func searchesTranscriptCatalogEpisodesWithListeningProgress() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE,
                ZTRANSCRIPTIDENTIFIER, ZITEMDESCRIPTIONWITHOUTHTML, ZPLAYHEAD, ZPLAYSTATELASTMODIFIEDDATE
            ) VALUES (
                8, 1, 888123, 'Energy Resistance Principle',
                'PodcastContent/v4/transcript_888123.ttml',
                'A conversation with Martin Picard about mitochondria.',
                12.0,
                \(DateComponents(calendar: .init(identifier: .gregorian), year: 2026, month: 5, day: 1).date!.timeIntervalSinceReferenceDate)
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.searchPodcastCatalogEpisodes(
            dbPath: dbPath,
            query: "Martin Picard",
            scope: .listened
        )

        #expect(status == .ok)
        #expect(episodes.contains { episode in
            episode.storeTrackId == 888123
                && episode.episodeTitle == "Energy Resistance Principle"
        })
    }

    @Test("Builds stable private podcast URLs without leaking feed tokens")
    func privatePodcastURLDoesNotLeakToken() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let playedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 2,
            day: 1
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE)
            VALUES (4, 'Private Feed');
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE, ZGUID,
                ZITEMDESCRIPTIONWITHOUTHTML, ZLASTDATEPLAYED
            ) VALUES (
                4, 4, 0, 'Private Episode',
                'https://private.example/episodes/1?key=secret-token',
                'Private show notes.', \(playedAt)
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)
        let episode = try #require(episodes.first { $0.episodeTitle == "Private Episode" })
        let url = try #require(SourceDiscovery.podcastEpisodeURL(for: episode))

        #expect(status == .ok)
        #expect(url.hasPrefix("apple-podcast://episode/private/"))
        #expect(!url.contains("secret-token"))
    }

    @Test("Private RSS episode URL is stable across local UUID changes")
    func privateRSSEpisodeURLIgnoresLocalUUIDWhenFeedIdentityExists() throws {
        let first = PodcastEpisodeMetadata(
            storeTrackId: nil,
            episodeUUID: "local-a",
            episodeGUID: "https://private.example/episodes/1?key=secret-token",
            episodeTitle: "Private Episode",
            podcastName: "Private Feed",
            artworkURL: nil,
            webPageURL: nil,
            episodeDescription: nil,
            enclosureURL: nil,
            ttmlIdentifier: nil,
            lastDatePlayed: nil,
            podcastCollectionId: nil
        )
        let second = PodcastEpisodeMetadata(
            storeTrackId: nil,
            episodeUUID: "local-b",
            episodeGUID: first.episodeGUID,
            episodeTitle: first.episodeTitle,
            podcastName: first.podcastName,
            artworkURL: nil,
            webPageURL: nil,
            episodeDescription: nil,
            enclosureURL: nil,
            ttmlIdentifier: nil,
            lastDatePlayed: nil,
            podcastCollectionId: nil
        )

        #expect(SourceDiscovery.podcastEpisodeURL(for: first) == SourceDiscovery.podcastEpisodeURL(for: second))
        #expect(SourceDiscovery.podcastEpisodeURL(for: first)?.hasPrefix("apple-podcast://episode/private/") == true)
    }

    @Test("Discovers private RSS episodes even when no notes are available")
    func discoversPrivateRSSEpisodesWithoutNotes() throws {
        let dbPath = try createTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let playedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 2,
            day: 1
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE)
            VALUES (5, 'Private Feed With Sparse Metadata');
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE, ZUUID, ZGUID, ZLASTDATEPLAYED
            ) VALUES (
                5, 5, 0, 'Sparse Private Episode',
                'SPARSE-PRIVATE-UUID',
                'sparse-private-guid', \(playedAt)
            );
        """, nil, nil, nil)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(status == .ok)
        #expect(episodes.contains { episode in
            episode.storeTrackId == nil
                && episode.episodeUUID == "SPARSE-PRIVATE-UUID"
                && episode.episodeTitle == "Sparse Private Episode"
        })
    }

    enum TestError: Error {
        case dbCreationFailed
    }
}

@Suite("Apple Podcasts DB Lookup (modern schema)")
struct PodcastModernSchemaLookupTests {

    /// Builds a fixture matching the macOS 26.x layout: descriptions live in
    /// ZMTEPISODEDESCRIPTION and enclosure/transcript/download fields in ZMTMEDIAENCLOSURE.
    private func createModernTempDB() throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let dbPath = tmpDir.appendingPathComponent("test_podcasts_modern_\(UUID().uuidString).sqlite").path

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw PodcastMetadataLookupTests.TestError.dbCreationFailed
        }

        let playedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 6,
            day: 1
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            CREATE TABLE ZMTPODCAST (
                Z_PK INTEGER PRIMARY KEY,
                ZTITLE TEXT,
                ZIMAGEURL TEXT,
                ZARTWORKTEMPLATEURL TEXT,
                ZSUBSCRIBED INTEGER,
                ZISIMPLICITLYFOLLOWED INTEGER,
                ZSTORECOLLECTIONID INTEGER
            );
            CREATE TABLE ZMTEPISODE (
                Z_PK INTEGER PRIMARY KEY,
                ZPODCAST INTEGER,
                ZSTORETRACKID INTEGER,
                ZTITLE TEXT,
                ZARTWORKTEMPLATEURL TEXT,
                ZWEBPAGEURL TEXT,
                ZUUID TEXT,
                ZGUID TEXT,
                ZLASTDATEPLAYED REAL,
                ZPLAYSTATELASTMODIFIEDDATE REAL,
                ZPLAYSTATE INTEGER,
                ZPLAYHEAD REAL,
                ZHASBEENPLAYED INTEGER,
                ZPLAYCOUNT INTEGER,
                ZLISTENNOWEPISODE INTEGER,
                ZISBOOKMARKED INTEGER,
                ZUSERDELETED INTEGER,
                ZCURRENTMEDIAENCLOSURE INTEGER,
                ZDESCRIPTIONOBJECT INTEGER,
                ZPUBDATE REAL
            );
            CREATE TABLE ZMTMEDIAENCLOSURE (
                Z_PK INTEGER PRIMARY KEY,
                ZEPISODE INTEGER,
                ZTRANSCRIPTIDENTIFIER TEXT,
                ZREMOTEURL TEXT,
                ZDOWNLOADDATE REAL,
                ZLOCALURL TEXT
            );
            CREATE TABLE ZMTEPISODEDESCRIPTION (
                Z_PK INTEGER PRIMARY KEY,
                ZEPISODE INTEGER,
                ZPLAINTEXT TEXT,
                ZTEXT TEXT
            );
            INSERT INTO ZMTPODCAST (Z_PK, ZTITLE, ZARTWORKTEMPLATEURL)
            VALUES (1, 'Dwarkesh Podcast', 'https://example.com/podcast/{w}x{h}bb.{f}');
            INSERT INTO ZMTMEDIAENCLOSURE (Z_PK, ZEPISODE, ZTRANSCRIPTIDENTIFIER, ZREMOTEURL)
            VALUES (11, 1, 'PodcastContent/v4/transcript_987654321.ttml', 'https://feeds.example.com/ep1.mp3');
            INSERT INTO ZMTEPISODEDESCRIPTION (Z_PK, ZEPISODE, ZPLAINTEXT, ZTEXT)
            VALUES (21, 1, 'A conversation with Martin Picard about mitochondria.', '<p>A conversation…</p>');
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE,
                ZLASTDATEPLAYED, ZPLAYSTATE, ZCURRENTMEDIAENCLOSURE, ZDESCRIPTIONOBJECT
            ) VALUES (
                1, 1, 987654321, 'Interview with Scientist',
                \(playedAt), 1, 11, 21
            );
        """, nil, nil, nil)

        sqlite3_close(db)
        return dbPath
    }

    @Test("Looks up metadata via ZMTMEDIAENCLOSURE and ZMTEPISODEDESCRIPTION")
    func lookupMetadataModern() throws {
        let dbPath = try createModernTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let results = SourceDiscovery.lookupPodcastMetadata(dbPath: dbPath, storeTrackIds: [987654321])

        let ep = try #require(results[987654321])
        #expect(ep.episodeTitle == "Interview with Scientist")
        #expect(ep.podcastName == "Dwarkesh Podcast")
        #expect(ep.ttmlIdentifier == "PodcastContent/v4/transcript_987654321.ttml")
        #expect(ep.enclosureURL == "https://feeds.example.com/ep1.mp3")
        #expect(ep.episodeDescription == "A conversation with Martin Picard about mitochondria.")
    }

    @Test("Discovers played episodes in the modern layout")
    func discoverPlayedEpisodesModern() throws {
        let dbPath = try createModernTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(status == .ok)
        #expect(episodes.contains { episode in
            episode.storeTrackId == 987654321
                && episode.ttmlIdentifier == "PodcastContent/v4/transcript_987654321.ttml"
                && episode.episodeDescription == "A conversation with Martin Picard about mitochondria."
        })
    }

    @Test("Searches catalog text stored in ZMTEPISODEDESCRIPTION")
    func searchCatalogModern() throws {
        let dbPath = try createModernTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let (episodes, status) = SourceDiscovery.searchPodcastCatalogEpisodes(
            dbPath: dbPath,
            query: "Martin Picard",
            scope: .listened
        )

        #expect(status == .ok)
        #expect(episodes.contains { $0.storeTrackId == 987654321 })
    }

    @Test("Downloaded scope reads download state from ZMTMEDIAENCLOSURE")
    func downloadedScopeModern() throws {
        let dbPath = try createModernTempDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw PodcastMetadataLookupTests.TestError.dbCreationFailed
        }
        defer { sqlite3_close(db) }

        let downloadedAt = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2026,
            month: 6,
            day: 15
        ).date!.timeIntervalSinceReferenceDate
        sqlite3_exec(db, """
            INSERT INTO ZMTMEDIAENCLOSURE (Z_PK, ZEPISODE, ZREMOTEURL, ZDOWNLOADDATE, ZLOCALURL)
            VALUES (12, 2, 'https://feeds.example.com/ep2.mp3', \(downloadedAt), 'file:///downloads/ep2.mp3');
            INSERT INTO ZMTEPISODE (
                Z_PK, ZPODCAST, ZSTORETRACKID, ZTITLE, ZCURRENTMEDIAENCLOSURE
            ) VALUES (
                2, 1, 555444333, 'Downloaded But Unplayed', 12
            );
        """, nil, nil, nil)

        let (listenedOnly, _) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)
        #expect(!listenedOnly.contains { $0.storeTrackId == 555444333 })

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .downloadedOrListened)
        #expect(status == .ok)
        #expect(episodes.contains { $0.storeTrackId == 555444333 })
    }

    @Test("Reports schema change when no supported layout matches")
    func unsupportedLayoutReportsSchemaChange() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let dbPath = tmpDir.appendingPathComponent("test_podcasts_broken_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw PodcastMetadataLookupTests.TestError.dbCreationFailed
        }
        // Shared episode/podcast columns present, but neither legacy columns
        // nor the modern enclosure/description tables exist.
        sqlite3_exec(db, """
            CREATE TABLE ZMTPODCAST (
                Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZIMAGEURL TEXT, ZARTWORKTEMPLATEURL TEXT,
                ZSUBSCRIBED INTEGER, ZISIMPLICITLYFOLLOWED INTEGER, ZSTORECOLLECTIONID INTEGER
            );
            CREATE TABLE ZMTEPISODE (
                Z_PK INTEGER PRIMARY KEY, ZPODCAST INTEGER, ZSTORETRACKID INTEGER, ZTITLE TEXT,
                ZARTWORKTEMPLATEURL TEXT, ZWEBPAGEURL TEXT, ZUUID TEXT, ZGUID TEXT,
                ZLASTDATEPLAYED REAL, ZPLAYSTATELASTMODIFIEDDATE REAL, ZPLAYSTATE INTEGER,
                ZPLAYHEAD REAL, ZHASBEENPLAYED INTEGER, ZPLAYCOUNT INTEGER,
                ZLISTENNOWEPISODE INTEGER, ZISBOOKMARKED INTEGER, ZUSERDELETED INTEGER
            );
        """, nil, nil, nil)
        sqlite3_close(db)

        let (episodes, status) = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath, scope: .listened)

        #expect(episodes.isEmpty)
        guard case .schemaChanged = status else {
            Issue.record("Expected .schemaChanged, got \(status)")
            return
        }
    }
}

@Suite("Apple Podcasts Auto-Sync")
struct PodcastAutoSyncTests {
    @Test("Watches only the Podcasts database and WAL")
    func relevantPodcastLibraryPaths() {
        let content = LocalSourceFileWatcher.Content.applePodcasts
        #expect(content.isRelevantPath("/tmp/Documents/MTLibrary.sqlite"))
        #expect(content.isRelevantPath("/tmp/Documents/MTLibrary.sqlite-wal"))
        #expect(!content.isRelevantPath("/tmp/Documents/MTLibrary.sqlite-shm"))
        #expect(!content.isRelevantPath("/tmp/Documents/Downloads.db"))
    }

    @Test("Protected Podcasts data is rejected before SQLite is opened")
    func unreadablePodcastDatabaseUsesNonPromptingGate() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnreadablePodcasts-\(UUID().uuidString).sqlite")
        try Data("not a database".utf8).write(to: database)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: database.path
            )
            try? FileManager.default.removeItem(at: database)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: database.path
        )

        #expect(!FileManager.default.isReadableFile(atPath: database.path))
        let (db, layout, status) = SourceDiscovery.openPodcastsDB(at: database.path)

        #expect(db == nil)
        #expect(layout == nil)
        #expect(status == .permissionDenied)
    }

    @Test("Database snapshot changes when the WAL changes")
    func podcastLibraryModificationSnapshotTracksWAL() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAutoSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let documents = home.appendingPathComponent(
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let database = documents.appendingPathComponent("MTLibrary.sqlite")
        let wal = documents.appendingPathComponent("MTLibrary.sqlite-wal")
        try Data([0]).write(to: database)
        try Data([1]).write(to: wal)

        let before = StudioViewModel.podcastLibraryModificationSnapshot(homeDir: home.path)
        try Data([1, 2, 3]).write(to: wal)
        let after = StudioViewModel.podcastLibraryModificationSnapshot(homeDir: home.path)

        #expect(before["database"] == after["database"])
        #expect(before["wal"] != after["wal"])
        #expect(after["wal"]?.size == 3)
    }

    @Test("Discovery creates a queued placeholder before transcript hydration")
    func podcastDiscoveryCreatesPlaceholder() throws {
        let playedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let metadata = PodcastEpisodeMetadata(
            storeTrackId: 123_456,
            episodeUUID: "episode-uuid",
            episodeGUID: "episode-guid",
            episodeTitle: "A newly synced episode",
            podcastName: "Example Show",
            artworkURL: "https://example.com/art.jpg",
            webPageURL: "https://example.com/episode",
            episodeDescription: nil,
            enclosureURL: "https://example.com/audio.mp3",
            ttmlIdentifier: nil,
            lastDatePlayed: playedAt,
            podcastCollectionId: 987
        )
        let result = StudioViewModel.podcastDiscoveryResult(from: .init(
            dbPath: "/tmp/MTLibrary.sqlite",
            episodeMetadata: [metadata],
            status: .ok,
            databaseExists: true
        ))

        let article = try #require(result.articles.first)
        #expect(result.warnings.isEmpty)
        #expect(article.url == "apple-podcast://episode/123456")
        #expect(article.title == "A newly synced episode")
        #expect(article.domain == "Example Show")
        #expect(article.dateAdded == playedAt)
        #expect(article.state == .queued)
        #expect(article.discoveryOrigin == .applePodcasts)
    }

    @Test("Private feed audio is queued for managed transcription")
    func privatePodcastDiscoveryCreatesTranscriptWork() throws {
        let metadata = PodcastEpisodeMetadata(
            storeTrackId: nil,
            episodeUUID: "private-episode-uuid",
            episodeGUID: "https://private.example/episode?token=secret",
            episodeTitle: "Private episode",
            podcastName: "Private Show",
            artworkURL: nil,
            webPageURL: nil,
            episodeDescription: nil,
            enclosureURL: "https://private.example/audio?token=secret",
            ttmlIdentifier: nil,
            lastDatePlayed: Date(timeIntervalSinceReferenceDate: 800_000_000),
            podcastCollectionId: nil
        )
        let result = StudioViewModel.podcastDiscoveryResult(from: .init(
            dbPath: "/tmp/MTLibrary.sqlite",
            episodeMetadata: [metadata],
            status: .ok,
            databaseExists: true
        ))

        let article = try #require(result.articles.first)
        #expect(article.url.hasPrefix("apple-podcast://episode/private/"))
        #expect(!article.url.contains("secret"))
        #expect(article.state == .queued)
        #expect(article.errorMessage == nil)
    }

    @Test("Auto-sync persistence inserts each episode once")
    func podcastAutoSyncPersistenceDeduplicates() async throws {
        let storage = try StorageService(inMemory: true)
        let playedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var episode = StudioArticle(
            url: "apple-podcast://episode/654321",
            title: "One episode",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts
        )
        episode.dateAdded = playedAt
        episode.domain = "Example Show"

        let first = await StudioViewModel.persistPodcastAutoSync(
            scannedSources: [episode],
            storage: storage
        )
        let second = await StudioViewModel.persistPodcastAutoSync(
            scannedSources: [episode],
            storage: storage
        )
        let stored = try await storage.loadActiveSources()

        #expect(first.insertedIDs.count == 1)
        #expect(first.insertedSources.count == 1)
        #expect(second.insertedIDs.isEmpty)
        #expect(stored.filter { $0.url == episode.url }.count == 1)
    }
}

@Suite("Reading List Auto-Sync")
struct ReadingListAutoSyncTests {
    @Test("Reading-list refresh preserves ForeverLM read-state changes")
    func readingListRefreshPreservesLocalReadState() async throws {
        let storage = try StorageService(inMemory: true)
        let safariReadAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var safariArticle = StudioArticle(
            url: "https://example.com/safari-article",
            title: "Safari article",
            sourceType: .article,
            discoveryOrigin: .safari
        )
        safariArticle.readAt = safariReadAt

        let initial = await StudioViewModel.persistReadingListAutoSync(
            browserResult: .init(articles: [safariArticle], warnings: []),
            existingArticles: [],
            storage: storage
        )
        let initiallyStored = try await storage.loadActiveSources()
        #expect(initial.insertedSources.count == 1)
        #expect(initiallyStored.first?.readAt == safariReadAt)

        try await storage.updateSourceReadAt(sourceID: safariArticle.id, readAt: nil)
        let unreadSources = try await storage.loadActiveSources()
        let unreadArticle = try #require(unreadSources.first)
        var anotherArticle = StudioArticle(
            url: "https://example.com/new-reading-list-item",
            title: "New Reading List item",
            sourceType: .article,
            discoveryOrigin: .safari
        )
        anotherArticle.readAt = safariReadAt

        let refresh = await StudioViewModel.persistReadingListAutoSync(
            browserResult: .init(articles: [safariArticle, anotherArticle], warnings: []),
            existingArticles: [unreadArticle],
            storage: storage
        )
        let refreshed = try await storage.loadActiveSources()
        let original = try #require(refreshed.first(where: { $0.id == safariArticle.id }))
        let newlyInserted = try #require(refreshed.first(where: { $0.id == anotherArticle.id }))

        #expect(original.readAt == nil)
        #expect(newlyInserted.readAt == safariReadAt)
        #expect(!refresh.changedIDs.contains(safariArticle.id))
        #expect(refresh.changedIDs.contains(anotherArticle.id))
    }
}

@Suite("X Bookmark Sync")
struct XBookmarkServiceTests {
    private func bookmark(_ id: String) -> XBookmark {
        XBookmark(
            tweetId: id,
            text: "Post \(id)",
            authorName: "Author",
            authorUsername: "author",
            createdAt: nil,
            urls: []
        )
    }

    @Test("Production OAuth client is built in")
    func productionOAuthClientIsBuiltIn() {
        #expect(!XBookmarkService.appOwnedOAuthClientID.isEmpty)
        // The test host is the Dev build, whose scheme is foreverlm-dev; the
        // production build answers on foreverlm://x-callback.
        #expect(XBookmarkService.oauthRedirectURI == "\(ForeverLMRuntimeIdentity.urlScheme)://x-callback")
        #expect(ForeverLMRuntimeIdentity.profile(isDevelopment: false).urlScheme == "foreverlm")
        #expect(Set(XBookmarkService.oauthScopes.split(separator: " ")) == [
            "bookmark.read", "tweet.read", "tweet.write", "users.read", "offline.access",
        ])
    }

    @Test("Watermark page keeps candidates after the watermark")
    func watermarkPageKeepsLaterCandidates() {
        let result = XBookmarkService.reconciliationCandidates(
            in: [bookmark("new-before"), bookmark("watermark"), bookmark("new-after")],
            stopAtTweetID: "watermark"
        )

        #expect(result.hitStop)
        #expect(result.bookmarks.map(\.tweetId) == ["new-before", "new-after"])
    }

    @Test("Page without watermark remains intact and continues pagination")
    func pageWithoutWatermarkContinues() {
        let result = XBookmarkService.reconciliationCandidates(
            in: [bookmark("one"), bookmark("two")],
            stopAtTweetID: "older-watermark"
        )

        #expect(!result.hitStop)
        #expect(result.bookmarks.map(\.tweetId) == ["one", "two"])
    }

    @Test("A saved post stops pagination when the watermark is gone")
    func savedPostStopsPagination() {
        // A new device, or a watermark the learner has since un-bookmarked:
        // the library still knows these posts, so the sync must not walk
        // every bookmark the account has.
        let result = XBookmarkService.reconciliationCandidates(
            in: [bookmark("new"), bookmark("saved"), bookmark("older")],
            stopAtTweetID: "gone-watermark",
            savedPostIDs: ["saved"]
        )

        #expect(result.hitStop)
        #expect(result.bookmarks.map(\.tweetId) == ["new", "older"])
    }

    @Test("A routine sync asks X for a small page")
    func routineSyncPageIsSmall() {
        // X bills every post a page returns, new or not.
        #expect(XBookmarkService.incrementalPageSize <= 10)
        #expect(XBookmarkService.fullPageSize == 100)
    }

    @Test("First sync keeps the complete page")
    func firstSyncKeepsCompletePage() {
        let result = XBookmarkService.reconciliationCandidates(
            in: [bookmark("one"), bookmark("two")],
            stopAtTweetID: nil
        )

        #expect(!result.hitStop)
        #expect(result.bookmarks.map(\.tweetId) == ["one", "two"])
    }

    @Test("TLS failures show recovery guidance instead of transport jargon")
    func tlsFailureIsUserFacing() {
        let message = XBookmarkError.userFacingMessage(
            for: URLError(.secureConnectionFailed),
            action: .syncBookmarks
        )

        #expect(message == "Couldn’t securely connect to X. Check your internet connection and your device’s date and time, then try again.")
        #expect(!message.localizedCaseInsensitiveContains("TLS"))
    }

    @Test("Offline failures give a concrete next step")
    func offlineFailureIsUserFacing() {
        let message = XBookmarkError.userFacingMessage(
            for: URLError(.notConnectedToInternet),
            action: .syncBookmarks
        )

        #expect(message == "You’re offline. Connect to the internet, then try again.")
    }

    @Test("X API details are not exposed in plugin UI")
    func apiDetailsAreRedacted() {
        let internalDetail = "HTTP 500: internal upstream response"
        let message = XBookmarkError.userFacingMessage(
            for: XBookmarkError.apiFailed(internalDetail),
            action: .syncBookmarks
        )

        #expect(message == "X bookmarks couldn’t be synced right now. Try again later.")
        #expect(!message.contains(internalDetail))
    }

    @Test("A 402 says ForeverLM's X credits ran out, and offers no reconnect")
    func creditsDepletedIsToldAndNotReconnectable() {
        let sync = XBookmarkError.userFacingMessage(for: XBookmarkError.creditsDepleted, action: .syncBookmarks)
        #expect(sync == "ForeverLM’s X API credits have run out, so bookmarks can’t sync until they’re topped up. Reconnecting won’t help.")
        #expect(!XBookmarkError.reconnectMayHelp(after: XBookmarkError.creditsDepleted))
        // A 402 has no reset time to wait for, so nothing pauses the retry
        // that runs once the credits are topped up.
        #expect(StudioViewModel.xSyncPause(after: XBookmarkError.creditsDepleted, now: Date()) == nil)
    }

    @Test("Reconnect is offered only where a new sign-in could help")
    func reconnectOfferFollowsTheFailure() {
        #expect(XBookmarkError.reconnectMayHelp(after: XBookmarkError.apiFailed("HTTP 403: Forbidden")))
        #expect(XBookmarkError.reconnectMayHelp(after: XBookmarkError.authFailed("Token exchange failed")))
        #expect(XBookmarkError.reconnectMayHelp(after: XBookmarkError.sessionExpired))
        #expect(!XBookmarkError.reconnectMayHelp(after: XBookmarkError.rateLimited(resetAt: nil)))
        #expect(!XBookmarkError.reconnectMayHelp(after: XBookmarkError.usageCapExceeded))
        #expect(!XBookmarkError.reconnectMayHelp(after: XBookmarkError.appAccessUnavailable))
        #expect(!XBookmarkError.reconnectMayHelp(after: URLError(.notConnectedToInternet)))
        #expect(!XBookmarkError.reconnectMayHelp(after: URLError(.timedOut)))
    }

    @Test("A failed sync becomes a red dot on the X tab, not a toast")
    func syncFailureIsTabAttention() {
        let failure = "X bookmarks couldn’t be synced right now. Try again later."

        #expect(StudioViewModel.xPluginAttention(
            errorMessage: failure, needsReauth: false, isSignedIn: true
        ) == failure)
        #expect(StudioViewModel.xPluginAttention(
            errorMessage: nil, needsReauth: true, isSignedIn: true
        ) == "Reconnect to X to keep syncing bookmarks.")
        // The sync's own message wins over the generic reconnect line.
        #expect(StudioViewModel.xPluginAttention(
            errorMessage: failure, needsReauth: true, isSignedIn: true
        ) == failure)
        // Nothing to flag once a sync goes through, and nothing to nag about
        // when X was never connected — that tab has its own Connect row.
        #expect(StudioViewModel.xPluginAttention(
            errorMessage: nil, needsReauth: false, isSignedIn: true
        ) == nil)
        #expect(StudioViewModel.xPluginAttention(
            errorMessage: failure, needsReauth: true, isSignedIn: false
        ) == nil)
    }

    @Test("A 429 is a rate limit with X's reset time, or a spent monthly cap")
    func rateLimitResponsesAreTold() {
        let window = "{\"title\":\"Too Many Requests\",\"detail\":\"Too Many Requests\",\"type\":\"about:blank\",\"status\":429}"
        #expect(XBookmarkService.rateLimitError(status: 429, resetHeader: "1788000000", body: window)
            == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_788_000_000)))
        // No header: still a rate limit, with no known end.
        #expect(XBookmarkService.rateLimitError(status: 429, resetHeader: nil, body: window)
            == .rateLimited(resetAt: nil))
        // The monthly cap arrives as the same status; only the body tells.
        let cap = "{\"title\":\"UsageCapExceeded\",\"detail\":\"Usage cap exceeded: Monthly product cap\",\"period\":\"Monthly\",\"scope\":\"Product\",\"status\":429}"
        #expect(XBookmarkService.rateLimitError(status: 429, resetHeader: "1788000000", body: cap) == .usageCapExceeded)
        // Every other status is not a rate limit.
        #expect(XBookmarkService.rateLimitError(status: 500, resetHeader: "1788000000", body: window) == nil)
        #expect(XBookmarkService.rateLimitError(status: 200, resetHeader: nil, body: "") == nil)
        #expect(XBookmarkService.rateLimitReset(fromHeader: " 1788000000 ") == Date(timeIntervalSince1970: 1_788_000_000))
        #expect(XBookmarkService.rateLimitReset(fromHeader: "soon") == nil)
    }

    @Test("Log lines carry X's title and detail, not the raw body")
    func errorSummaryReadsTitleAndDetail() {
        let cap = "{\"title\":\"UsageCapExceeded\",\"detail\":\"Usage cap exceeded: Monthly product cap\",\"status\":429}"
        #expect(XBookmarkService.errorSummary(fromBody: cap) == "UsageCapExceeded · Usage cap exceeded: Monthly product cap")
        #expect(XBookmarkService.errorSummary(fromBody: "<html>Bad gateway</html>") == "<html>Bad gateway</html>")
        #expect(XBookmarkService.errorSummary(fromBody: "{\"errors\":[]}") == "{\"errors\":[]}")
    }

    @Test("A rate limit names when the sync resumes instead of inviting a retry")
    func rateLimitMessagesNameTheReset() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let resetAt = now.addingTimeInterval(9 * 60)
        let time = resetAt.formatted(date: .omitted, time: .shortened)

        let sync = XBookmarkError.rateLimitedMessage(resetAt: resetAt, action: .syncBookmarks, now: now)
        #expect(sync == "X is limiting bookmark reads right now. ForeverLM will sync again at \(time).")
        #expect(!sync.contains("Try again"))
        let connect = XBookmarkError.rateLimitedMessage(resetAt: resetAt, action: .connect, now: now)
        #expect(connect == "X is limiting requests right now. Try again after \(time).")
        // A reset in the past, or none at all, is a short wait with no clock.
        #expect(XBookmarkError.rateLimitedMessage(resetAt: now.addingTimeInterval(-1), action: .syncBookmarks, now: now)
            == "X is limiting bookmark reads right now. Try again in a few minutes.")
        #expect(XBookmarkError.rateLimitedMessage(resetAt: nil, action: .syncBookmarks, now: now)
            == "X is limiting bookmark reads right now. Try again in a few minutes.")

        // The plugin UI takes these through the same door as every other failure.
        #expect(XBookmarkError.userFacingMessage(for: XBookmarkError.usageCapExceeded, action: .syncBookmarks)
            == "ForeverLM has used up its monthly allowance of X reads. Bookmarks sync again once X resets it.")
        #expect(XBookmarkError.userFacingMessage(for: XBookmarkError.rateLimited(resetAt: nil), action: .syncBookmarks)
            == "X is limiting bookmark reads right now. Try again in a few minutes.")
    }

    @Test("Only a 429 with a future reset pauses syncing, and only until then")
    func rateLimitPausesSyncUntilReset() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let resetAt = now.addingTimeInterval(15 * 60)

        #expect(StudioViewModel.xSyncPause(after: XBookmarkError.rateLimited(resetAt: resetAt), now: now) == resetAt)
        // A window that already closed, or a limit with no clock, pauses nothing.
        #expect(StudioViewModel.xSyncPause(after: XBookmarkError.rateLimited(resetAt: now.addingTimeInterval(-60)), now: now) == nil)
        #expect(StudioViewModel.xSyncPause(after: XBookmarkError.rateLimited(resetAt: nil), now: now) == nil)
        // A spent monthly cap has no reset we know; a 500 or being offline is
        // worth retrying the moment the learner asks.
        #expect(StudioViewModel.xSyncPause(after: XBookmarkError.usageCapExceeded, now: now) == nil)
        #expect(StudioViewModel.xSyncPause(after: XBookmarkError.apiFailed("HTTP 500"), now: now) == nil)
        #expect(StudioViewModel.xSyncPause(after: URLError(.notConnectedToInternet), now: now) == nil)

        #expect(StudioViewModel.isXSyncPaused(until: resetAt, now: now))
        #expect(!StudioViewModel.isXSyncPaused(until: resetAt, now: resetAt))
        #expect(!StudioViewModel.isXSyncPaused(until: nil, now: now))
    }
}
#endif
