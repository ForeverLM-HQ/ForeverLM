import Testing
import Foundation
@testable import ForeverLM

@Suite("YouTube video search")
struct YouTubeVideoSearchTests {
    @Test("Podcast searches are not filtered by caption availability")
    func doesNotFilterForUploaderCaptions() throws {
        let url = try #require(YouTubeService.videoSearchURL(query: "Episode Show", maxResults: 50))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(parameters["type"] == "video")
        // videoCaption=closedCaption hides auto-captioned podcast uploads,
        // which the transcript importer reads without trouble.
        #expect(parameters["videoCaption"] == nil)
        #expect(parameters["q"] == "Episode Show")
        #expect(parameters["maxResults"] == "10")
    }

    @Test("YouTube consent asks for its own scope alone, never Drive's alongside it")
    func doesNotCombineScopesWithAPreviousDriveGrant() throws {
        let url = try #require(YouTubeService.authorizationURL(
            clientID: "client.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:8080/youtube-oauth",
            codeChallenge: "challenge",
            state: "state"
        ))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(parameters["scope"] == YouTubeService.authorizationScope)
        // Incremental authorization re-requests whatever the account already
        // granted this client. Combined with a prior Drive picker grant that
        // becomes [youtube.readonly, drive.file], which Google refuses outright
        // — so a Drive user could not connect YouTube at all.
        #expect(parameters["include_granted_scopes"] == "false")
        #expect(parameters["scope"]?.contains("drive") == false)
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(parameters["access_type"] == "offline")
    }

    @Test("Data API search results preserve identity and readable metadata")
    func decodesVideoCandidates() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": { "videoId": "abc123def45" },
              "snippet": {
                "title": "Mind &amp; Matter: An Episode",
                "channelTitle": "Mind &amp; Matter",
                "publishedAt": "2026-08-10T12:30:00Z"
              }
            },
            {
              "id": {},
              "snippet": { "title": "A playlist, not a video" }
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(VideoSearchResponse.self, from: data)
        let results = YouTubeService.videoSearchResults(from: response)

        #expect(results.count == 1)
        #expect(results[0].id == "abc123def45")
        #expect(results[0].title == "Mind & Matter: An Episode")
        #expect(results[0].channelTitle == "Mind & Matter")
        #expect(results[0].url == "https://www.youtube.com/watch?v=abc123def45")
        #expect(results[0].publishedAt != nil)
    }
}

// MARK: - Video ID Extraction

@Suite("YouTube Video ID Extraction")
struct YouTubeVideoIdTests {

    @Test("Extracts ID from standard watch URL")
    func standardWatchURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Extracts ID from watch URL with extra params")
    func watchURLWithExtraParams() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42&list=PLx")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Extracts ID from short youtu.be URL")
    func shortURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Extracts ID from youtu.be URL with query params")
    func shortURLWithParams() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ?t=120")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Extracts ID from embed URL")
    func embedURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/embed/dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Extracts ID from /v/ URL")
    func vPathURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/v/dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Extracts ID from shorts URL")
    func shortsURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Returns nil for non-YouTube URL")
    func nonYouTubeURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://vimeo.com/123456")
        #expect(id == nil)
    }

    @Test("Returns nil for YouTube URL with empty v param")
    func emptyVParam() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/watch?v=")
        #expect(id == nil)
    }

    @Test("Returns nil for malformed URL")
    func malformedURL() {
        let id = YouTubeTranscriptService.extractVideoId(from: "not a url at all")
        #expect(id == nil)
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        let id = YouTubeTranscriptService.extractVideoId(from: "")
        #expect(id == nil)
    }

    @Test("Truncates IDs longer than 11 characters")
    func longId() {
        let id = YouTubeTranscriptService.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQextra")
        #expect(id == "dQw4w9WgXcQ")
    }
}

// MARK: - YouTube URL Detection

@Suite("YouTube URL Detection")
struct YouTubeURLDetectionTests {

    @Test("Detects standard watch URL")
    func standardWatch() {
        #expect(YouTubeTranscriptService.isYouTubeURL("https://www.youtube.com/watch?v=abc123"))
    }

    @Test("Detects short URL")
    func shortURL() {
        #expect(YouTubeTranscriptService.isYouTubeURL("https://youtu.be/abc123"))
    }

    @Test("Detects embed URL")
    func embedURL() {
        #expect(YouTubeTranscriptService.isYouTubeURL("https://www.youtube.com/embed/abc123"))
    }

    @Test("Detects /v/ URL")
    func vPathURL() {
        #expect(YouTubeTranscriptService.isYouTubeURL("https://www.youtube.com/v/abc123"))
    }

    @Test("Detects shorts URL")
    func shortsURL() {
        #expect(YouTubeTranscriptService.isYouTubeURL("https://www.youtube.com/shorts/abc123"))
    }

    @Test("Rejects non-YouTube URL")
    func nonYouTube() {
        #expect(!YouTubeTranscriptService.isYouTubeURL("https://vimeo.com/123"))
    }

    @Test("Rejects YouTube homepage without path")
    func youtubeHomepage() {
        #expect(!YouTubeTranscriptService.isYouTubeURL("https://www.youtube.com/"))
    }

    @Test("Case insensitive detection")
    func caseInsensitive() {
        #expect(YouTubeTranscriptService.isYouTubeURL("HTTPS://WWW.YOUTUBE.COM/WATCH?V=abc"))
        #expect(YouTubeTranscriptService.isYouTubeURL("https://YOUTU.BE/abc"))
    }
}

// MARK: - Title Extraction

@Suite("YouTube Title Extraction")
struct YouTubeTitleExtractionTests {

    @Test("Extracts from og:title meta tag")
    func ogTitle() {
        let html = """
        <html><head>
        <meta property="og:title" content="My Video Title">
        </head></html>
        """
        #expect(YouTubeTranscriptService.extractTitle(from: html) == "My Video Title")
    }

    @Test("Does not interpret provider-like text inside metadata titles")
    func preservesMetadataTitleText() {
        let html = """
        <html><head>
        <meta property="og:title" content="My Video Title | YouTube">
        </head></html>
        """
        #expect(YouTubeTranscriptService.extractTitle(from: html) == "My Video Title | YouTube")
    }

    @Test("Preserves YouTube text in video titles")
    func preservesYouTubeText() {
        #expect(YouTubeTranscriptService.sanitizedVideoTitle("YouTube - My Video") == "YouTube - My Video")
        #expect(YouTubeTranscriptService.sanitizedVideoTitle("My YouTube Video") == "My YouTube Video")
        #expect(YouTubeTranscriptService.sanitizedVideoTitle("YouTube") == "YouTube")
    }

    @Test("Extracts from og:title with reversed attribute order")
    func ogTitleReversed() {
        let html = """
        <html><head>
        <meta content="Reversed Order Title" property="og:title">
        </head></html>
        """
        #expect(YouTubeTranscriptService.extractTitle(from: html) == "Reversed Order Title")
    }

    @Test("Extracts the title tag without interpreting its suffix")
    func titleTag() {
        let html = "<html><head><title>My Great Video - YouTube</title></head></html>"
        #expect(YouTubeTranscriptService.extractTitle(from: html) == "My Great Video - YouTube")
    }

    @Test("Decodes HTML entities in title")
    func htmlEntities() {
        let html = """
        <html><head>
        <meta property="og:title" content="Test &amp; More &lt;stuff&gt;">
        </head></html>
        """
        #expect(YouTubeTranscriptService.extractTitle(from: html) == "Test & More <stuff>")
    }

    @Test("Returns nil for empty HTML")
    func emptyHTML() {
        #expect(YouTubeTranscriptService.extractTitle(from: "") == nil)
    }

    @Test("Returns nil for HTML with no title elements")
    func noTitle() {
        let html = "<html><head></head><body>no title here</body></html>"
        #expect(YouTubeTranscriptService.extractTitle(from: html) == nil)
    }

    @Test("Prefers og:title over title tag")
    func prefersOgTitle() {
        let html = """
        <html><head>
        <meta property="og:title" content="OG Title">
        <title>Regular Title - YouTube</title>
        </head></html>
        """
        #expect(YouTubeTranscriptService.extractTitle(from: html) == "OG Title")
    }

    @Test("Rejects extremely long titles")
    func longTitle() {
        let longTitle = String(repeating: "a", count: 400)
        let html = "<meta property=\"og:title\" content=\"\(longTitle)\">"
        // Should skip the overly long og:title. No <title> fallback → nil.
        #expect(YouTubeTranscriptService.extractTitle(from: html) == nil)
    }
}

// MARK: - Chapter Parsing

@Suite("YouTube Chapter Parsing")
struct YouTubeChapterParsingTests {

    @Test("Parses, sorts, cleans, and deduplicates player-bar chapters")
    func playerBarChapters() {
        let json: [String: Any] = [
            "contents": [
                "multiMarkersPlayerBarRenderer": [
                    "markersMap": [
                        [
                            "key": "HEATSEEKER",
                            "value": ["heatMarkers": []],
                        ],
                        [
                            "key": "AUTO_CHAPTERS",
                            "value": [
                                "chapters": [
                                    [
                                        "chapterRenderer": [
                                            "title": ["simpleText": " Later "],
                                            "timeRangeStartMillis": "90000",
                                        ]
                                    ],
                                    [
                                        "chapterRenderer": [
                                            "title": [
                                                "runs": [
                                                    ["text": "Intro"],
                                                    ["text": "duction"],
                                                ]
                                            ],
                                            "timeRangeStartMillis": NSNumber(value: 0),
                                        ]
                                    ],
                                    [
                                        "chapterRenderer": [
                                            "title": ["simpleText": "Duplicate start"],
                                            "timeRangeStartMillis": NSNumber(value: 200),
                                        ]
                                    ],
                                    [
                                        "chapterRenderer": [
                                            "title": ["simpleText": "   "],
                                            "timeRangeStartMillis": NSNumber(value: 120_000),
                                        ]
                                    ],
                                    [
                                        "chapterRenderer": [
                                            "title": ["simpleText": "Invalid time"],
                                            "timeRangeStartMillis": "nan",
                                        ]
                                    ],
                                ]
                            ],
                        ],
                    ]
                ]
            ]
        ]

        let chapters = YouTubeTranscriptService.parseChapterMarkers(from: json)

        #expect(chapters == [
            .init(startSeconds: 0, title: "Introduction"),
            .init(startSeconds: 90, title: "Later"),
        ])
    }

    @Test("Falls back to macro markers when the player bar has no chapters")
    func macroMarkerFallback() {
        let json: [String: Any] = [
            "engagementPanels": [
                [
                    "macroMarkersListRenderer": [
                        "contents": [
                            [
                                "macroMarkersListItemRenderer": [
                                    "title": ["simpleText": "Opening"],
                                    "onTap": [
                                        "watchEndpoint": ["startTimeSeconds": NSNumber(value: 0)]
                                    ],
                                ]
                            ],
                            [
                                "macroMarkersListItemRenderer": [
                                    "title": ["runs": [["text": "Deep dive"]]],
                                    "onTap": [
                                        "watchEndpoint": ["startTimeSeconds": "42"]
                                    ],
                                ]
                            ],
                        ]
                    ]
                ]
            ]
        ]

        #expect(YouTubeTranscriptService.parseChapterMarkers(from: json) == [
            .init(startSeconds: 0, title: "Opening"),
            .init(startSeconds: 42, title: "Deep dive"),
        ])
    }

    @Test("Prefers player-bar chapters over duplicate engagement-panel markers")
    func playerBarPrecedence() {
        let json: [String: Any] = [
            "multiMarkersPlayerBarRenderer": [
                "markersMap": [
                    [
                        "value": [
                            "chapters": [
                                [
                                    "chapterRenderer": [
                                        "title": ["simpleText": "Player bar"],
                                        "timeRangeStartMillis": NSNumber(value: 0),
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            "macroMarkersListRenderer": [
                "contents": [
                    [
                        "macroMarkersListItemRenderer": [
                            "title": ["simpleText": "Engagement panel"],
                            "onTap": [
                                "watchEndpoint": ["startTimeSeconds": NSNumber(value: 0)]
                            ],
                        ]
                    ]
                ]
            ],
        ]

        #expect(YouTubeTranscriptService.parseChapterMarkers(from: json) == [
            .init(startSeconds: 0, title: "Player bar")
        ])
    }
}

// MARK: - Chapter Markup

@Suite("YouTube Chapter Markup")
struct YouTubeChapterMarkupTests {

    @Test("Replaces inferred headings with official chapters at the nearest caption")
    func replacesHeadings() {
        let transcript = """
        ## Guessed opening
        [0:00] Opening words.

        [0:40] The middle.

        ### Guessed ending
        [1:10] Closing words.
        """
        let chapters: [YouTubeTranscriptService.VideoChapter] = [
            .init(startSeconds: 0, title: "Introduction"),
            .init(startSeconds: 65, title: "Conclusion"),
        ]
        let expected = """
        ## Introduction
        [0:00] Opening words.

        [0:40] The middle.

        ## Conclusion
        [1:10] Closing words.
        """

        let updated = YouTubeChapterMarkup.applyingOfficialChapters(chapters, to: transcript)

        #expect(updated == expected)
        #expect(YouTubeChapterMarkup.applyingOfficialChapters(chapters, to: updated) == expected)
    }

    @Test("Leaves the transcript byte-for-byte unchanged without usable chapters or timing")
    func noOpFallbacks() {
        let timed = "## Inferred\r\n[0:00] Keep this formatting."
        let untimed = "## Inferred\r\nA transcript without timestamp anchors."
        let chapter = YouTubeTranscriptService.VideoChapter(startSeconds: 0, title: "Official")

        #expect(YouTubeChapterMarkup.applyingOfficialChapters([], to: timed) == timed)
        #expect(YouTubeChapterMarkup.applyingOfficialChapters([chapter], to: untimed) == untimed)
    }
}

// MARK: - Error Types

@Suite("YouTube Transcript Errors")
struct YouTubeTranscriptErrorTests {

    @Test("Error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [YouTubeTranscriptError] = [
            .invalidURL,
            .fetchFailed,
            .rateLimited,
            .parsingFailed("detail"),
            .noTranscriptAvailable,
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("Parsing failed includes detail")
    func parsingFailedDetail() {
        let error = YouTubeTranscriptError.parsingFailed("Could not find captions")
        #expect(error.errorDescription!.contains("Could not find captions"))
    }
}

@Suite("YouTube Caption Decoding")
struct YouTubeCaptionDecodingTests {
    /// YouTube escapes an already-escaped caption, so `R&D` arrives as
    /// `R&amp;amp;D`. Decoding one level left a visible `&amp;` in the stored
    /// transcript, which every reader then showed verbatim.
    @Test("Decodes doubly escaped caption text")
    func decodesDoublyEscapedCaptionText() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <transcript>
          <text start="0.0" dur="3.0">two to 12 times speed ups in these R&amp;amp;D programs</text>
          <text start="3.0" dur="3.0">and that&amp;#39;s the &amp;quot;whole point&amp;quot;</text>
        </transcript>
        """

        let transcript = try YouTubeTranscriptService.transcript(fromCaptionXML: xml)

        #expect(transcript.contains("R&D programs"))
        #expect(transcript.contains("that's the \"whole point\""))
        #expect(!transcript.contains("&amp;"))
        #expect(!transcript.contains("&#39;"))
    }

    @Test("Leaves a singly escaped ampersand as one ampersand")
    func leavesSinglyEscapedAmpersandAlone() throws {
        let xml = """
        <transcript>
          <text start="0.0" dur="2.0">Ernst &amp; Young hired them</text>
        </transcript>
        """

        let transcript = try YouTubeTranscriptService.transcript(fromCaptionXML: xml)

        #expect(transcript.contains("Ernst & Young hired them"))
    }
}

// MARK: - Readable Transcript Markers

/// `ReadableTranscriptMarkers`: a formatted transcript's markers are the
/// captions', each on the words it times, whatever the formatting model did
/// with them.
@Suite("Readable transcript markers")
struct ReadableTranscriptMarkersTests {
    /// "Mitochondrial Cell Biology 3" from 11:14, as its captions came and as
    /// Transcript Formatting returned them: the model began "Mitochondria and
    /// the ER" where 11:52 was, dropped that marker, and put 12:24 and 12:57
    /// on the text before their own (2026-09-28), so a quiz question on the
    /// exchange of phospholipids rewatched from half a minute after it.
    private let raw = """
    [11:14] and that shows us that myosin also acts as a motor in mitochondrial transport there are also proteins that are accessory to mitochondrial trafficking such as miro and milton

    [11:52] around the cell they can relate to different organelles in the cell and there actually studies that show that mitochondria interact with every single organelle

    [12:24] specific proteins but also there's a functional importance of the relationship between mitochondria and the er there's an exchange of phospholipids
    """

    private let formatted = """
    [11:14] And that shows us that myosin also acts as a motor in mitochondrial transport. There are also proteins that are accessory to mitochondrial trafficking, such as Miro and Milton.

    ## Mitochondria and the ER
    [12:24] Around the cell they can relate to different organelles in the cell, and there actually studies that show that mitochondria interact with every single organelle

    [12:57] specific proteins, but also there's a functional importance of the relationship between mitochondria and the ER. There's an exchange of phospholipids.
    """

    @Test("Each caption marker opens the model's words for its block, under the heading the model began there")
    func markersBackOnTheirWords() {
        #expect(ReadableTranscriptMarkers.anchored(formatted, to: raw) == """
        [11:14] And that shows us that myosin also acts as a motor in mitochondrial transport. There are also proteins that are accessory to mitochondrial trafficking, such as Miro and Milton.

        ## Mitochondria and the ER
        [11:52] Around the cell they can relate to different organelles in the cell, and there actually studies that show that mitochondria interact with every single organelle

        [12:24] specific proteins, but also there's a functional importance of the relationship between mitochondria and the ER. There's an exchange of phospholipids.
        """)
    }

    @Test("Blocks the model ran together are cut apart again, each under its own marker")
    func mergedParagraphsSplit() {
        let merged = """
        [11:14] And that shows us that myosin also acts as a motor in mitochondrial transport. There are also proteins that are accessory to mitochondrial trafficking, such as Miro and Milton, around the cell they can relate to different organelles in the cell, and there actually studies that show that mitochondria interact with every single organelle.
        """
        let twoBlocks = raw.components(separatedBy: "\n\n").prefix(2).joined(separator: "\n\n")
        let anchored = ReadableTranscriptMarkers.anchored(merged, to: twoBlocks)
        #expect(anchored.hasPrefix("[11:14] And that shows us"))
        #expect(anchored.contains("such as Miro and Milton,\n\n[11:52] around the cell they can relate"))
    }

    @Test("A block the model left out has no paragraph, and a transcript without markers is left as it is")
    func droppedBlockAndNoMarkers() {
        let withoutAd = """
        [11:14] And that shows us that myosin also acts as a motor in mitochondrial transport. There are also proteins that are accessory to mitochondrial trafficking, such as Miro and Milton.

        [12:24] Specific proteins, but also there's a functional importance of the relationship between mitochondria and the ER. There's an exchange of phospholipids.
        """
        let anchored = ReadableTranscriptMarkers.anchored(withoutAd, to: raw)
        #expect(!anchored.contains("[11:52]"))
        #expect(anchored.contains("\n\n[12:24] Specific proteins"))
        #expect(ReadableTranscriptMarkers.anchored(formatted, to: "no markers in these captions at all") == formatted)
    }

    @Test("A heading inside a block stays where the model put it, and the words after it are timed within the block")
    func headingInsideABlock() {
        let words = (0..<40).map { "w\($0)" }
        let raw = "[5:30] " + words.joined(separator: " ") + "\n\n[6:00] the next block begins here"
        let formatted = """
        [5:30] \(words[..<20].joined(separator: " ")).

        ## A new topic
        [5:30] \(words[20...].joined(separator: " ")) the next block begins here.
        """
        #expect(ReadableTranscriptMarkers.anchored(formatted, to: raw) == """
        [5:30] \(words[..<20].joined(separator: " ")).

        ## A new topic
        [5:45] \(words[20...].joined(separator: " "))

        [6:00] the next block begins here.
        """, "halfway through the block's captions, halfway through its thirty seconds")
    }

    @Test("A heading a word or two from a block's edge moves the edge, and no sentence is split")
    func headingNearAnEdge() {
        let words = (0..<40).map { "w\($0)" }
        let raw = "[5:30] " + words.joined(separator: " ") + "\n\n[6:00] the next block begins here"
        let formatted = "[5:30] \(words[..<38].joined(separator: " ")).\n\n## A new topic\n\(words[38...].joined(separator: " ")) the next block begins here."
        #expect(ReadableTranscriptMarkers.anchored(formatted, to: raw) == """
        [5:30] \(words[..<38].joined(separator: " ")).

        ## A new topic
        [6:00] \(words[38...].joined(separator: " ")) the next block begins here.
        """)
    }

    @Test("A heading the model wrote after a marker is a heading, a line's opening punctuation stays with it, and the model's [?] goes")
    func headingAfterAMarker() {
        let raw = """
        [0:00] so this is an overview of the structure as it

        [0:32] is important for mitochondria this here is an electron microscopy image

        [1:04] of what could be the typical mitochondrion
        """
        let formatted = """
        [0:00] So this is an overview of the structure as it is important for mitochondria.

        [0:32] ## Mitochondrial architecture
        [?] … This here is an electron microscopy image of what could be the typical mitochondrion.
        """
        #expect(ReadableTranscriptMarkers.anchored(formatted, to: raw) == """
        [0:00] So this is an overview of the structure as it

        [0:32] is important for mitochondria.

        ## Mitochondrial architecture
        [0:43] … This here is an electron microscopy image

        [1:04] of what could be the typical mitochondrion.
        """, "four of the block's eleven caption words in: 0:32 plus 4/11 of 32 s")
    }

    @Test("A lecture longer than one alignment window keeps every marker on its block's first word")
    func longLecture() {
        // Forty blocks of forty words, formatted into four paragraphs with
        // one marker each and a heading halfway.
        let blocks = (0..<40).map { block in (0..<40).map { "b\(block)w\($0)" } }
        let raw = blocks.enumerated()
            .map { "[\($0.offset / 2):\(String(format: "%02d", ($0.offset % 2) * 30))] " + $0.element.joined(separator: " ") }
            .joined(separator: "\n\n")
        var paragraphs: [String] = []
        for group in 0..<4 {
            let words = blocks[(group * 10)..<(group * 10 + 10)].flatMap { $0 }
            paragraphs.append((group == 2 ? "## Halfway\n" : "") + "[0:00] " + words.joined(separator: " ") + ".")
        }
        let anchored = ReadableTranscriptMarkers.anchored(paragraphs.joined(separator: "\n\n"), to: raw)
        let lines = anchored.components(separatedBy: "\n\n")
        #expect(lines.count == 40)
        for (index, line) in lines.enumerated() {
            let marker = "[\(index / 2):\(String(format: "%02d", (index % 2) * 30))] b\(index)w0 "
            #expect(line.hasPrefix(index == 20 ? "## Halfway\n" + marker : marker), "block \(index)")
        }
    }
}

// MARK: - Readable Transcript Fidelity

/// `ReadableTranscriptMarkers.checked`: a formatted transcript says what its
/// captions say. Each fixture is Transcript Formatting's output as stored for
/// one of the fourteen quizzed lectures on 2026-09-28, beside YouTube's
/// captions for the same stretch.
@Suite("Readable transcript fidelity")
struct ReadableTranscriptFidelityTests {
    private func checked(_ formatted: String, _ raw: String, restoring: Bool = true) throws -> ReadableTranscriptMarkers.Checked {
        try #require(ReadableTranscriptMarkers.checked(formatted, against: raw, restoringDroppedCaptions: restoring))
    }

    /// "Isolated Mitochondria and Permeabilized Cells/Tissues 3" at 8:47: the
    /// model lost a clause inside the block and the opening of the next one.
    private let droppedRaw = """
    [8:47] of the mitochondrial inner membrane and the matrix and they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another sometimes these probes can block these reactions so they can be inhibitors of lipid oxidation so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation

    [9:15] and inhibiting this process in your media because of your probe and not because it's not happening one of my pet peeves about membrane potential measurements and this is very important is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential
    """

    private let droppedFormatted = """
    [8:47] of the mitochondrial inner membrane and the matrix and they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another sometimes these probes can block these reactions so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation

    [9:15] And not because it's not happening; one of my pet peeves about membrane potential measurements, and this is very important, is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential.
    """

    @Test("Caption runs the model left out are put back where they were said")
    func droppedRunsRestored() throws {
        let result = try checked(droppedFormatted, droppedRaw)
        #expect(result.text == """
        [8:47] of the mitochondrial inner membrane and the matrix and they can act as quenchers and blockers of lipid oxidation processes that happen by chain reactions in which one lipid will oxidize another and oxidize another sometimes these probes can block these reactions so they can be inhibitors of lipid oxidation so you may be measuring membrane potential and you're not aware of the fact that you're actually using a pretty good quencher of lipid oxidation

        [9:15] And inhibiting this process in your media because of your probe and not because it's not happening; one of my pet peeves about membrane potential measurements, and this is very important, is that a change in fluorescence or a change in absorbance does not correlate one to one with your inner mitochondrial membrane potential.
        """)
        #expect(result.restoredWords == 19)
        #expect(result.removedWords == 0)
    }

    @Test("Holding a transcript to its captions a second time changes nothing")
    func checkingIsIdempotent() throws {
        // Two Macs check the same synced transcript; the second must find
        // nothing to do, or they would rewrite each other's text.
        let once = try checked(droppedFormatted, droppedRaw)
        let twice = try checked(once.text, droppedRaw)
        #expect(twice.text == once.text)
        #expect(twice.restoredWords == 0)
        #expect(twice.removedWords == 0)
    }

    @Test("A podcast's captions stay out where the model was asked to take ad reads out")
    func droppedRunsKeptOutForAdReads() throws {
        let raw = """
        [20:00] and that is why the gut matters so much for sleep when your microbiome is off your melatonin rhythm is off too and most people never connect the two this episode is brought to you by athletic greens go to athleticgreens dot com slash show for a free year's supply of vitamin d

        [20:30] now back to the microbiome the bacteria in your colon ferment fiber into short chain fatty acids and those fatty acids talk to your brain through the vagus nerve which is one of the most exciting findings of the last decade

        [21:00] so what should you actually eat the short answer is more plants and more kinds of plants than you think thirty different plants a week is the number that keeps coming up in the studies
        """
        let formatted = """
        [20:00] And that is why the gut matters so much for sleep: when your microbiome is off, your melatonin rhythm is off too, and most people never connect the two.

        [20:30] Now, back to the microbiome. The bacteria in your colon ferment fiber into short-chain fatty acids, and those fatty acids talk to your brain through the vagus nerve, which is one of the most exciting findings of the last decade.

        [21:00] So what should you actually eat? The short answer is more plants, and more kinds of plants than you think. Thirty different plants a week is the number that keeps coming up in the studies.
        """
        let withoutAd = try checked(formatted, raw, restoring: false)
        #expect(withoutAd.restoredWords == 0)
        #expect(!withoutAd.text.contains("athletic"))
        #expect(withoutAd.text == ReadableTranscriptMarkers.anchored(formatted, to: raw))

        let video = try checked(formatted, raw)
        #expect(video.text.contains("connect the two. This episode is brought to you by athletic greens"))
    }

    @Test("A sentence no caption says is taken out, and the model's correction beside it kept")
    func inventedSentenceRemoved() throws {
        // "Mitochondrial Cell Biology 1" at 3:13, where the model wrote a
        // sentence of its own under the heading it began.
        let raw = """
        [2:40] Christy also have a junction area which is the area in which Christy meets the inner membrane that needs the outer membrane junctions are

        [3:13] important because they can have different properties under different conditions and they separate the Christy area from the inter membrane space now when you see a figure like that you start to think that all mitochondria have these very thin tubules forming their crista and they're always parallel

        [3:43] mitochondria three dimensions what they saw is that the structure of christy is actually much more complex
        """
        let formatted = """
        [2:08] Cristae also have a junction area, which is the area in which cristae meet the inner membrane; the outer membrane junctions are important because they can have different properties under different conditions and they separate the cristae from the intermembrane space.

        [2:40] ## Cristae and inner membrane architecture
        [?] The structure and properties of the inner and outer mitochondrial membranes continue to be explored, as cristae shape and membrane contact dynamics influence transport and energy generation.

        [3:13] Now when you see a figure like that you start to think that all mitochondria have these very thin tubules forming their cristae and they're always parallel. In three dimensions, what they saw is that the structure of cristae is actually much more complex.
        """
        let result = try checked(formatted, raw)
        #expect(result.text == """
        [2:40] Cristae also have a junction area, which is the area in which cristae meet the inner membrane; the outer membrane junctions are

        [3:13] important because they can have different properties under different conditions and they separate the cristae from the intermembrane space.

        ## Cristae and inner membrane architecture
        [3:26] Now when you see a figure like that you start to think that all mitochondria have these very thin tubules forming their cristae and they're always parallel.

        [3:43] In three dimensions, what they saw is that the structure of cristae is actually much more complex.
        """)
        #expect(result.removedWords == 27)
        #expect(result.restoredWords == 0)
    }

    @Test("A sentence the model wrote twice is kept once")
    func repeatedSentenceRemoved() throws {
        // "Mitochondrial Cell Biology 3" at 1:06: the block repeats the
        // sentence the one before it ends with.
        let raw = """
        [0:34] first of all because you need a minimum of mitochondria a minimum of mitochondria is not just enough to generate another ATP for the cell but actually to have a little bit of a

        [1:06] reserve energy capacity for situations in which the cell needs more ATP and can survive this energy emergency because there is some reserve capacity however mitochondria are not cheap to make synthesis has to be controlled because it can't be excessive

        [1:38] generating too many mitochondria therefore is undesirable
        """
        let formatted = """
        [0:34] First of all, because you need a minimum of mitochondria—a minimum of mitochondria is not just enough to generate another ATP for the cell, but actually to have a little bit of a reserve energy capacity for situations in which the cell needs more ATP and can survive this energy emergency because there is some reserve capacity.

        [1:06] Reserve energy capacity for situations in which the cell needs more ATP and can survive this energy emergency because there is some reserve capacity. However, mitochondria are not cheap to make; synthesis has to be controlled because it can't be excessive.

        [1:38] Generating too many mitochondria therefore is undesirable.
        """
        let result = try checked(formatted, raw)
        #expect(result.text == """
        [0:34] First of all, because you need a minimum of mitochondria—a minimum of mitochondria is not just enough to generate another ATP for the cell, but actually to have a little bit of a

        [1:06] reserve energy capacity for situations in which the cell needs more ATP and can survive this energy emergency because there is some reserve capacity. However, mitochondria are not cheap to make; synthesis has to be controlled because it can't be excessive.

        [1:38] Generating too many mitochondria therefore is undesirable.
        """)
        #expect(result.removedWords == 24)
    }

    @Test("A word of the model's that a repeat taken out leaves opening a sentence gets its capital")
    func sentenceOpenedByRemoval() throws {
        // "Mitochondrial Cell Biology 1" at 5:17 opens by saying again the
        // five words that close 4:43.
        let raw = """
        [4:43] is quite different from the light scattering of mitochondria that it argumented in high ATP and therefore are doing oxidative phosphorylation when we

        [5:17] call the state 3 and this was named condensed and Orthodox mitochondrial configurations at the time just based on these light scattering properties
        """
        let formatted = """
        [4:43] Is quite different from the light scattering of mitochondria that are energized in high ATP and therefore are doing oxidative phosphorylation, when we call the state 3.

        [5:17] We call the state 3, and this was named condensed and orthodox mitochondrial configurations at the time just based on these light scattering properties.
        """
        let result = try checked(formatted, raw)
        #expect(result.text == """
        [4:43] Is quite different from the light scattering of mitochondria that are energized in high ATP and therefore are doing oxidative phosphorylation, when we

        [5:17] call the state 3. And this was named condensed and orthodox mitochondrial configurations at the time just based on these light scattering properties.
        """)
        #expect(result.removedWords == 5)
    }

    @Test("Where the model wrote an earlier passage again in place of what was said, the captions' words replace it")
    func replacedPassageRestored() throws {
        // "Intact Cell Measurements 1" at 13:06.
        let raw = """
        [12:37] to these different stimuli a very important point about the modulators you're going to use and you're not only going to use oligomycin fccp and rhodonandomycin you might use other modulators too is that you must titrate these modulators because typically these are substances that are membrane permeable they're for lipophilic they're going to accumulate in membranes and if you use too much of them they're going to have toxic effects on the other hand depending on

        [13:06] what kind of media you have the constitution of your media if there's protein or not if you don't have protein the amount of effective oligomyces and fccp or road known antimycin might change and also different cells respond to different quantities of these inhibitors so it's really important that you titrate so you have the expected respiratory effect and you use the lowest amount of this inhibitor that generates the expected effect so always titrate these substances

        [13:40] having said that although this oligomycin uncoupler and respiratory inhibitor experiment is a very common one it's not the only experiment you can do under these conditions you can also design experiments in which you inhibit the use of different substrates you inhibit the use of fatty acids or you inhibit the use of glucose or you inhibit the use of amino acids you can design experiments in which you look at the changes in ph and oxygen consumption with
        """
        let formatted = """
        [12:37] to these different stimuli. A very important point about the modulators you're going to use—and you're not only going to use oligomycin, FCCP, and rotenone/antimycin; you might use other modulators too—is that you must titrate these modulators, because typically these are substances that are membrane-permeable, they're lipophilic, they're going to accumulate in membranes, and if you use too much of them they're going to have toxic effects. On the other hand, depending on

        [13:06] you must titrate these modulators because typically these are substances that are membrane permeable, they're for lipophilic, they're going to accumulate in membranes, and if you use too much of them they're going to have toxic effects. On the other hand, depending on Really important that you titrate so you have the expected respiratory effect, and you use the lowest amount of this inhibitor that generates the expected effect. So always titrate these substances.

        [13:40] Having said that, although this oligomycin uncoupler and respiratory inhibitor experiment is a very common one, it's not the only experiment you can do under these conditions. You can also design experiments in which you inhibit the use of different substrates: you inhibit the use of fatty acids, or you inhibit the use of glucose, or you inhibit the use of amino acids. You can design experiments in which you look at the changes in pH and oxygen consumption with
        """
        let result = try checked(formatted, raw)
        let block = try #require(result.text.components(separatedBy: "\n\n").first { $0.hasPrefix("[13:06]") })
        #expect(block == "[13:06] what kind of media you have the constitution of your media if there's protein or not if you don't have protein the amount of effective oligomyces and fccp or road known antimycin might change and also different cells respond to different quantities of these inhibitors so it's Really important that you titrate so you have the expected respiratory effect, and you use the lowest amount of this inhibitor that generates the expected effect. So always titrate these substances.")
        #expect(result.restoredWords == 47)
        #expect(result.removedWords == 43)
    }

    @Test("Fillers and false starts the model took out of spontaneous speech stay out")
    func lightEditsKept() throws {
        // Stanford CS336 lecture 8 at 55:22, as YouTube's automatic captions
        // write it.
        let raw = """
        [55:22] Um and then, um you know, you can sort of skip some computation or sorry, some overhead uh in the backward pass. So what you're going to do is two all gathers and one reduce scatter per layer, which is

        [55:43] kind of the whole idea of FSDP.
        """
        let formatted = """
        [55:22] And then you can skip some computation—or sorry, some overhead—in the backward pass. So what you're going to do is two all-gathers and one reduce-scatter per layer, which is kind of the whole idea of FSDP.
        """
        let result = try checked(formatted, raw)
        #expect(result.restoredWords == 0)
        #expect(result.removedWords == 0)
        #expect(result.text == """
        [55:22] And then you can skip some computation—or sorry, some overhead—in the backward pass. So what you're going to do is two all-gathers and one reduce-scatter per layer, which is

        [55:43] kind of the whole idea of FSDP.
        """)
    }

    @Test("A section the model appended that repeats the lecture goes, heading and all")
    func appendedSectionRemoved() throws {
        // "Mitochondrial Ion Transport 3" ended with a heading and 185
        // words of what it had said before.
        let raw = """
        [11:14] adding a potassium transporter plus a proton transporter in this case this is illustrated by the addition of nigericin which is a potassium proton exchanging molecule

        [11:44] so that's what i wanted to tell you about potassium transport so till then
        """
        let formatted = """
        [11:14] Adding a potassium transporter plus a proton transporter. In this case, this is illustrated by the addition of nigericin, which is a potassium-proton exchanging molecule.

        [11:44] So that's what I wanted to tell you about potassium transport, so till then.

        ## Swelling Assays for Studying Transport
        Adding a potassium transporter plus a proton transporter. In this case, this is illustrated by the addition of nigericin.
        """
        let result = try checked(formatted, raw)
        #expect(result.text == """
        [11:14] Adding a potassium transporter plus a proton transporter. In this case, this is illustrated by the addition of nigericin, which is a potassium-proton exchanging molecule.

        [11:44] So that's what I wanted to tell you about potassium transport, so till then.
        """)
    }

    @Test("Text that would need a quarter of its captions put back, or shares none, is refused")
    func unfaithfulTextRefused() {
        let blocks = (0..<4).map { block in (0..<40).map { "b\(block)w\($0)" }.joined(separator: " ") }
        let raw = blocks.enumerated().map { "[\($0.offset):00] \($0.element)" }.joined(separator: "\n\n")
        #expect(ReadableTranscriptMarkers.checked("[0:00] \(blocks[0]).", against: raw, restoringDroppedCaptions: true) == nil)
        #expect(ReadableTranscriptMarkers.checked("[0:00] \(blocks[0]).", against: raw, restoringDroppedCaptions: false) != nil)
        #expect(ReadableTranscriptMarkers.checked("Nothing the lecture says.", against: raw, restoringDroppedCaptions: true) == nil)
        #expect(ReadableTranscriptMarkers.checked(blocks[0], against: blocks[0], restoringDroppedCaptions: true) == nil,
                "captions without markers cannot be checked")
    }
}

// MARK: - Video Metadata Lookup

/// oEmbed answers 401 for a private video and for a public one whose uploader
/// turned embedding off, so it cannot say which a refused video is. On
/// 2026-09-28 eighteen Stanford CS336 lectures — public, playable, every one
/// embed-disabled — had been filed under the channel "www.youtube.com" since
/// July, and the channel backfill remembered each as private at every launch.
@Suite("YouTube video metadata lookup")
struct YouTubeVideoMetadataLookupTests {
    /// The InnerTube player's answer for CS336 lecture 1, trimmed to the
    /// fields the lookup reads: public and playable, embedding off.
    private let embedDisabledLecture: [String: Any] = [
        "playabilityStatus": ["status": "OK", "playableInEmbed": false],
        "videoDetails": [
            "videoId": "JuoVZkPBiKk",
            "title": "Stanford CS336 Language Modeling from Scratch | Spring 2026 | Lecture 1: Overview, Tokenization",
            "author": "Stanford Online",
            "channelId": "UCBa5G_ESCn8Yd4vw5U-gIcg",
            "isPrivate": false,
        ],
    ]

    @Test("The player names the uploader of a video whose embedding is off")
    func playerNamesEmbedDisabledUploader() {
        let lookup = YouTubeTranscriptService.playerMetadataLookup(fromPlayerResponse: embedDisabledLecture)

        #expect(lookup == .found(YouTubeTranscriptService.VideoMetadata(
            title: "Stanford CS336 Language Modeling from Scratch | Spring 2026 | Lecture 1: Overview, Tokenization",
            channelName: "Stanford Online",
            thumbnailURL: nil
        )))
    }

    @Test("A video the player does not describe is unavailable, unless the refusal is a bot check")
    func playerVerdicts() {
        let deleted: [String: Any] = ["playabilityStatus": ["status": "ERROR", "reason": "This video is unavailable"]]
        let privateVideo: [String: Any] = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "This video is private"]]
        let botCheck: [String: Any] = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you’re not a bot"]]

        #expect(YouTubeTranscriptService.playerMetadataLookup(fromPlayerResponse: deleted) == .unavailable)
        #expect(YouTubeTranscriptService.playerMetadataLookup(fromPlayerResponse: privateVideo) == .unavailable)
        // A bot check is about the request, not the video: ask again later.
        #expect(YouTubeTranscriptService.playerMetadataLookup(fromPlayerResponse: botCheck) == .failed)
        #expect(YouTubeTranscriptService.playerMetadataLookup(fromPlayerResponse: [:]) == .failed)
    }

    @Test("oEmbed's refusal alone never makes a video unavailable")
    func oEmbedRefusalIsNotAVerdict() {
        let player = YouTubeTranscriptService.playerMetadataLookup(fromPlayerResponse: embedDisabledLecture)

        // oEmbed refused and the player described the video: it is named.
        let named = YouTubeTranscriptService.combinedMetadataLookup(oEmbed: nil, player: player)
        #expect(named.metadata?.channelName == "Stanford Online")
        // oEmbed refused and the player could not be asked: nothing is known,
        // so the backfill asks again instead of remembering the video as private.
        #expect(YouTubeTranscriptService.combinedMetadataLookup(oEmbed: nil, player: .failed) == .failed)
        #expect(YouTubeTranscriptService.combinedMetadataLookup(oEmbed: nil, player: .unavailable) == .unavailable)
    }

    @Test("oEmbed's title and thumbnail stay when the player supplies the uploader")
    func combinedKeepsOEmbedTitleAndThumbnail() {
        let thumbnail = "https://i.ytimg.com/vi/JuoVZkPBiKk/hqdefault.jpg"
        let oEmbed = YouTubeTranscriptService.VideoMetadata(title: "Lecture 1", channelName: nil, thumbnailURL: thumbnail)
        let player = YouTubeTranscriptService.MetadataLookup.found(YouTubeTranscriptService.VideoMetadata(
            title: "Lecture 1 as the player titles it",
            channelName: "Stanford Online",
            thumbnailURL: nil
        ))

        #expect(YouTubeTranscriptService.combinedMetadataLookup(oEmbed: oEmbed, player: player) == .found(
            YouTubeTranscriptService.VideoMetadata(title: "Lecture 1", channelName: "Stanford Online", thumbnailURL: thumbnail)
        ))
        // What oEmbed found is kept when the player has nothing to add.
        #expect(YouTubeTranscriptService.combinedMetadataLookup(oEmbed: oEmbed, player: .failed) == .found(oEmbed))
        #expect(YouTubeTranscriptService.combinedMetadataLookup(oEmbed: oEmbed, player: .unavailable) == .found(oEmbed))
    }

    @Test("A blank uploader name is no channel")
    func blankUploaderIsNoChannel() {
        #expect(YouTubeTranscriptService.channelName(of: .init(title: "A talk", channelName: "  ", thumbnailURL: nil)) == nil)
        #expect(YouTubeTranscriptService.channelName(of: .init(title: "A talk", channelName: nil, thumbnailURL: nil)) == nil)
        #expect(YouTubeTranscriptService.channelName(of: .init(title: "A talk", channelName: " Peter Attia MD ", thumbnailURL: nil)) == "Peter Attia MD")
    }
}
