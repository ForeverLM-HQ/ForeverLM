import Testing
@testable import ForeverLM

@Suite("YouTube Slide Extraction")
struct YouTubeSlideExtractionServiceTests {

    @Test("Parses storyboard levels from YouTube spec")
    func parsesStoryboardSpec() {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sigh=$A|48#27#100#10#10#5000#default#sig0|160#90#240#5#5#2000#M$M#sig1"

        let levels = YouTubeSlideExtractionService.parseStoryboardSpec(spec)

        #expect(levels.count == 2)
        #expect(levels[0].levelIndex == 0)
        #expect(levels[0].width == 48)
        #expect(levels[0].height == 27)
        #expect(levels[0].thumbnailCount == 100)
        #expect(levels[0].columns == 10)
        #expect(levels[0].rows == 10)
        #expect(levels[0].intervalMilliseconds == 5000)
        #expect(levels[0].signature == "sig0")
        #expect(levels[1].width == 160)
        #expect(levels[1].tilesPerSheet == 25)
    }

    @Test("Builds storyboard sheet URLs")
    func buildsStoryboardSheetURL() throws {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sigh=$A|160#90#240#5#5#2000#M$M#sig1"
        let level = try #require(YouTubeSlideExtractionService.parseStoryboardSpec(spec).first)

        let url = try #require(level.sheetURL(sheetIndex: 3))

        #expect(url.absoluteString == "https://i.ytimg.com/sb/abc/storyboard3_L0/M3.jpg?sigh=sig1")
    }

    /// Regression: YouTube's untimed overview names its only sheet `default`. Replacing `$N`
    /// with `M0` instead returned 404 and left videos with no slide frames.
    @Test("Uses the per-level storyboard sheet name")
    func usesPerLevelStoryboardSheetName() throws {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sigh=$A|48#27#100#10#10#0#default#sig0"
        let level = try #require(YouTubeSlideExtractionService.parseStoryboardSpec(spec).first)

        let url = try #require(level.sheetURL(sheetIndex: 0))

        #expect(url.absoluteString == "https://i.ytimg.com/sb/abc/storyboard3_L0/default.jpg?sigh=sig0")
    }

    /// Regression: a real talk's spec carried the signature only as a per-level field, with
    /// no `$A` in the template. Substitution silently did nothing, every sheet returned 403,
    /// and the video ended up with no slides at all.
    @Test("Appends the signature when the template has no placeholder")
    func appendsSignatureWithoutPlaceholder() throws {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sqp=xyz|160#90#115#5#5#10000#M$M#rs$AOn4CLBHP"
        let level = try #require(YouTubeSlideExtractionService.parseStoryboardSpec(spec).first)

        let url = try #require(level.sheetURL(sheetIndex: 2))

        #expect(url.absoluteString == "https://i.ytimg.com/sb/abc/storyboard3_L0/M2.jpg?sqp=xyz&sigh=rs$AOn4CLBHP")
    }

    @Test("Substitutes the signature when the template does carry a placeholder")
    func substitutesSignaturePlaceholder() throws {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sigh=$A|160#90#240#5#5#2000#M$M#sig1"
        let level = try #require(YouTubeSlideExtractionService.parseStoryboardSpec(spec).first)

        let url = try #require(level.sheetURL(sheetIndex: 1))

        #expect(url.absoluteString == "https://i.ytimg.com/sb/abc/storyboard3_L0/M1.jpg?sigh=sig1")
    }

    @Test("Parses direct MP4 streams from player JSON")
    func parsesVideoFrameStreams() throws {
        let json: [String: Any] = [
            "streamingData": [
                "formats": [
                    [
                        "url": "https://rr.example.com/videoplayback?itag=22",
                        "mimeType": "video/mp4; codecs=\"avc1.64001F, mp4a.40.2\"",
                        "width": 1280,
                        "height": 720,
                        "qualityLabel": "720p",
                    ],
                    [
                        "signatureCipher": "url=https%3A%2F%2Fexample.com%2Fblocked",
                        "mimeType": "video/mp4",
                        "width": 1920,
                        "height": 1080,
                    ],
                    [
                        "url": "https://rr.example.com/videoplayback?itag=244",
                        "mimeType": "video/webm",
                        "width": 854,
                        "height": 480,
                    ],
                ]
            ]
        ]

        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(json)

        #expect(streams.count == 1)
        #expect(streams[0].url.absoluteString == "https://rr.example.com/videoplayback?itag=22")
        #expect(streams[0].width == 1280)
        #expect(streams[0].height == 720)
        #expect(streams[0].qualityLabel == "720p")
    }

    // MARK: - Frame stream selection

    /// The regression that made every slide come out as a 160x90 storyboard tile.
    ///
    /// Sorting streams by resolution alone picks the 1080p entry from `adaptiveFormats`,
    /// which is video-only fragmented DASH that `AVURLAsset` cannot open from a bare URL. All
    /// captures then fail together and silently fall back to storyboard tiles, which carry no
    /// legible text. A seekable 640x360 frame beats an unopenable 1080p one.
    @Test("Prefers a seekable progressive stream over a higher-resolution adaptive one")
    func prefersProgressiveStream() throws {
        let json: [String: Any] = [
            "streamingData": [
                "formats": [
                    [
                        "url": "https://rr.example.com/videoplayback?itag=18",
                        "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                        "width": 640, "height": 360, "qualityLabel": "360p",
                    ]
                ],
                "adaptiveFormats": [
                    [
                        "url": "https://rr.example.com/videoplayback?itag=137",
                        "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                        "width": 1920, "height": 1080, "qualityLabel": "1080p",
                    ]
                ],
            ]
        ]

        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(json)
        #expect(streams.count == 2)

        let best = try #require(YouTubeSlideExtractionService.bestVideoFrameStream(from: streams))
        #expect(best.isProgressive)
        #expect(best.width == 640)
    }

    @Test("Falls back to an adaptive stream when no progressive one exists")
    func fallsBackToAdaptiveStream() throws {
        let json: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    [
                        "url": "https://rr.example.com/videoplayback?itag=136",
                        "mimeType": "video/mp4; codecs=\"avc1.64001f\"",
                        "width": 1280, "height": 720, "qualityLabel": "720p",
                    ],
                    [
                        "url": "https://rr.example.com/videoplayback?itag=137",
                        "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                        "width": 1920, "height": 1080, "qualityLabel": "1080p",
                    ],
                ]
            ]
        ]

        let best = try #require(
            YouTubeSlideExtractionService.bestVideoFrameStream(
                from: YouTubeSlideExtractionService.parseVideoFrameStreams(json)
            )
        )

        #expect(!best.isProgressive)
        #expect(best.width == 1920)
    }

    // MARK: - Storyboard level selection

    /// Detection downsamples every tile to the same 17x16 dHash and the stored image comes
    /// from the MP4 capture, so the level that dates slide changes most finely wins even when
    /// another level carries larger tiles.
    @Test("Prefers the finest-interval level over the largest-tile one")
    func bestStoryboardLevelPrefersFinerInterval() {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sigh=$A|48#27#200#10#10#3000#default#s0|320#180#60#2#2#10000#M$M#s1"
        let levels = YouTubeSlideExtractionService.parseStoryboardSpec(spec)

        let best = YouTubeSlideExtractionService.bestStoryboardLevel(from: levels)

        #expect(best?.levelIndex == 0)
        #expect(best?.intervalMilliseconds == 3000)
    }

    /// A real CS336 lecture exposed an interval-0 overview before two 10-second levels.
    /// Zero means "untimed", so it must not win the finest-interval sort.
    @Test("Prefers a timed storyboard over the untimed overview")
    func bestStoryboardLevelSkipsUntimedOverview() {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sqp=xyz|48#27#100#10#10#0#default#s0|80#45#494#10#10#10000#M$M#s1|160#90#494#5#5#10000#M$M#s2"
        let levels = YouTubeSlideExtractionService.parseStoryboardSpec(spec)

        let best = YouTubeSlideExtractionService.bestStoryboardLevel(from: levels)

        #expect(levels.first?.intervalMilliseconds == nil)
        #expect(best?.levelIndex == 2)
        #expect(best?.width == 160)
    }
}
