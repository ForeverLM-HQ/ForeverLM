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
        #expect(streams[0].codecs == ["avc1.64001F", "mp4a.40.2"])
        #expect(streams[0].isProgressive)
        #expect(streams[0].initRange == nil)
        #expect(streams[0].indexRange == nil)
    }

    /// The fields the segmented read depends on, in the shape YouTube sends them: the two
    /// byte ranges as objects of decimal strings.
    @Test("Parses an adaptive stream's codec, rate and byte ranges")
    func parsesAdaptiveStreamFields() throws {
        let json: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    Self.adaptiveFormat(itag: 137, codec: "avc1.640028", width: 1920, height: 1080, fps: 25, bitrate: 2_287_389),
                    [
                        "itag": 140,
                        "url": "https://rr.example.com/videoplayback?itag=140",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                    ],
                ]
            ]
        ]

        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(json)

        let stream = try #require(streams.first)
        #expect(streams.count == 1)
        #expect(!stream.isProgressive)
        #expect(stream.codecs == ["avc1.640028"])
        #expect(stream.isH264)
        #expect(stream.framesPerSecond == 25)
        #expect(stream.bitrate == 2_287_389)
        #expect(stream.initRange == 0...741)
        #expect(stream.indexRange == 742...13_277)
    }

    @Test("Reads codecs and byte ranges defensively")
    func parsesCodecsAndByteRanges() {
        #expect(YouTubeSlideExtractionService.codecs(fromMimeType: "video/mp4; codecs=\"av01.0.08M.08\"") == ["av01.0.08M.08"])
        #expect(YouTubeSlideExtractionService.codecs(fromMimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"; profile=x") == ["avc1.42001E", "mp4a.40.2"])
        #expect(YouTubeSlideExtractionService.codecs(fromMimeType: "video/mp4").isEmpty)

        #expect(YouTubeSlideExtractionService.byteRange(["start": "742", "end": "13277"]) == 742...13_277)
        #expect(YouTubeSlideExtractionService.byteRange(["start": 0, "end": 741]) == 0...741)
        #expect(YouTubeSlideExtractionService.byteRange(["start": "900", "end": "100"]) == nil)
        #expect(YouTubeSlideExtractionService.byteRange(["start": "-1", "end": "100"]) == nil)
        #expect(YouTubeSlideExtractionService.byteRange(["start": "0"]) == nil)
        #expect(YouTubeSlideExtractionService.byteRange(nil) == nil)
    }

    /// The visionOS request is turned away as a bot without the visitor id the ANDROID
    /// answer carries.
    @Test("Reads the visitor id from a player answer")
    func readsVisitorData() {
        #expect(YouTubeSlideExtractionService.visitorData(from: ["responseContext": ["visitorData": "CgtBdzhPVnd1"]]) == "CgtBdzhPVnd1")
        #expect(YouTubeSlideExtractionService.visitorData(from: ["responseContext": ["visitorData": ""]]) == nil)
        #expect(YouTubeSlideExtractionService.visitorData(from: [:]) == nil)
    }

    // MARK: - Frame stream selection

    /// The regression that made every slide come out as a 160x90 storyboard tile.
    ///
    /// The progressive pick is the stream `AVURLAsset` opens from its URL. An adaptive stream
    /// fails to open there (-12190), and the ANDROID client's copies answer 403 past their
    /// first minute besides, so choosing one sent every capture to a storyboard tile. A 640x360
    /// progressive frame beats that, and 1080p comes through the segmented read instead.
    @Test("The progressive pick never takes a higher-resolution adaptive stream")
    func progressivePickIgnoresAdaptiveStreams() throws {
        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(Self.talkStreamingData)
        #expect(streams.count == 4)

        let best = try #require(YouTubeSlideExtractionService.bestProgressiveFrameStream(from: streams))
        #expect(best.isProgressive)
        #expect(best.width == 640)
    }

    @Test("Offers no progressive stream when YouTube lists only adaptive ones")
    func noProgressiveStreamFromAdaptiveOnly() {
        let json: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    Self.adaptiveFormat(itag: 136, codec: "avc1.64001f", width: 1280, height: 720, fps: 25, bitrate: 1_065_464),
                    Self.adaptiveFormat(itag: 137, codec: "avc1.640028", width: 1920, height: 1080, fps: 25, bitrate: 2_287_389),
                ]
            ]
        ]

        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(json)

        #expect(YouTubeSlideExtractionService.bestProgressiveFrameStream(from: streams) == nil)
        #expect(YouTubeSlideExtractionService.bestSegmentedFrameStream(from: streams)?.width == 1920)
    }

    /// What a 90-minute talk offered on 2026-10-13: the 1080p H.264 stream is the one slides
    /// are read from, not the AV1 copy at the same size nor the muxed 360p.
    @Test("Reads slides from the 1080p H.264 adaptive stream")
    func segmentedPickTakesFullHDH264() throws {
        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(Self.talkStreamingData)

        let best = try #require(YouTubeSlideExtractionService.bestSegmentedFrameStream(from: streams))

        #expect(!best.isProgressive)
        #expect(best.url.absoluteString.hasSuffix("itag=137"))
        #expect(best.width == 1920)
        #expect(best.height == 1080)
    }

    /// AV1 decodes in hardware only on recent chips, so a sharper AV1 copy loses to H.264 that
    /// every Mac decodes; a stream without its segment index cannot be read at all.
    @Test("Skips AV1 and adaptive streams without a segment index")
    func segmentedPickNeedsH264AndIndex() throws {
        var unindexed = Self.adaptiveFormat(itag: 137, codec: "avc1.640028", width: 1920, height: 1080, fps: 25, bitrate: 2_287_389)
        unindexed["indexRange"] = nil
        let json: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    unindexed,
                    Self.adaptiveFormat(itag: 399, codec: "av01.0.08M.08", width: 1920, height: 1080, fps: 25, bitrate: 1_338_726),
                    Self.adaptiveFormat(itag: 136, codec: "avc1.64001F", width: 1280, height: 720, fps: 25, bitrate: 1_065_464),
                ]
            ]
        ]

        let best = try #require(
            YouTubeSlideExtractionService.bestSegmentedFrameStream(
                from: YouTubeSlideExtractionService.parseVideoFrameStreams(json)
            )
        )

        #expect(best.url.absoluteString.hasSuffix("itag=136"))
    }

    /// Pixels beyond the capture's 1920x1080 are scaled away, so a larger stream keeps no more
    /// than one that fills the capture, and a 60 fps copy holds the same slide in more bytes.
    @Test("Takes the cheapest stream among those that fill the capture")
    func segmentedPickPrefersCheaperAmongEqualCaptures() throws {
        let json: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    Self.adaptiveFormat(itag: 264, codec: "avc1.640032", width: 2560, height: 1440, fps: 30, bitrate: 6_000_000),
                    Self.adaptiveFormat(itag: 299, codec: "avc1.64002a", width: 1920, height: 1080, fps: 60, bitrate: 4_000_000),
                    Self.adaptiveFormat(itag: 137, codec: "avc1.640028", width: 1920, height: 1080, fps: 30, bitrate: 2_500_000),
                    Self.adaptiveFormat(itag: 136, codec: "avc1.64001F", width: 1280, height: 720, fps: 30, bitrate: 1_100_000),
                ]
            ]
        ]

        let best = try #require(
            YouTubeSlideExtractionService.bestSegmentedFrameStream(
                from: YouTubeSlideExtractionService.parseVideoFrameStreams(json)
            )
        )

        #expect(best.url.absoluteString.hasSuffix("itag=137"))
    }

    /// A portrait stream is fitted by its height: 1080x1920 keeps 607.5x1080 of a 1920x1080
    /// capture, no more than a 720x1280 copy of it would.
    @Test("Counts the pixels a capture keeps after fitting the stream")
    func capturedAreaFitsTheCapture() throws {
        let json: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    Self.adaptiveFormat(itag: 137, codec: "avc1.640028", width: 1080, height: 1920, fps: 30, bitrate: 2_500_000),
                    Self.adaptiveFormat(itag: 136, codec: "avc1.64001F", width: 720, height: 1280, fps: 30, bitrate: 1_100_000),
                    Self.adaptiveFormat(itag: 135, codec: "avc1.4d401f", width: 480, height: 854, fps: 30, bitrate: 600_000),
                ]
            ]
        ]
        let streams = YouTubeSlideExtractionService.parseVideoFrameStreams(json)
        let maximumSize = YouTubeSlideExtractionService.captureMaximumSize

        #expect(streams[0].capturedArea(within: maximumSize) == 607.5 * 1_080)
        #expect(streams[1].capturedArea(within: maximumSize) == 607.5 * 1_080)
        #expect(streams[2].capturedArea(within: maximumSize) == 480 * 854)
        let best = try #require(YouTubeSlideExtractionService.bestSegmentedFrameStream(from: streams))
        #expect(best.url.absoluteString.hasSuffix("itag=136"))
    }

    /// The streams of the 2026-10-13 talk that matter here, trimmed to what the choice reads.
    private static let talkStreamingData: [String: Any] = [
        "streamingData": [
            "formats": [
                [
                    "itag": 18,
                    "url": "https://rr.example.com/videoplayback?itag=18",
                    "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                    "width": 640, "height": 360, "qualityLabel": "360p", "fps": 25, "bitrate": 224_347,
                ]
            ],
            "adaptiveFormats": [
                Self.adaptiveFormat(itag: 137, codec: "avc1.640028", width: 1920, height: 1080, fps: 25, bitrate: 2_287_389),
                Self.adaptiveFormat(itag: 399, codec: "av01.0.08M.08", width: 1920, height: 1080, fps: 25, bitrate: 1_338_726),
                Self.adaptiveFormat(itag: 136, codec: "avc1.64001F", width: 1280, height: 720, fps: 25, bitrate: 1_065_464),
                [
                    "itag": 248,
                    "url": "https://rr.example.com/videoplayback?itag=248",
                    "mimeType": "video/webm; codecs=\"vp9\"",
                    "width": 1920, "height": 1080, "fps": 25,
                    "initRange": ["start": "0", "end": "220"],
                    "indexRange": ["start": "221", "end": "18920"],
                ],
            ],
        ]
    ]

    private static func adaptiveFormat(
        itag: Int,
        codec: String,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int
    ) -> [String: Any] {
        [
            "itag": itag,
            "url": "https://rr.example.com/videoplayback?itag=\(itag)",
            "mimeType": "video/mp4; codecs=\"\(codec)\"",
            "width": width,
            "height": height,
            "qualityLabel": "\(height)p",
            "fps": fps,
            "bitrate": bitrate,
            "initRange": ["start": "0", "end": "741"],
            "indexRange": ["start": "742", "end": "13277"],
        ]
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
