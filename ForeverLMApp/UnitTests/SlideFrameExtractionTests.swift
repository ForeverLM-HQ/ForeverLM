import Foundation
import Testing
@testable import ForeverLM

/// The source-neutral half of slide extraction: run detection over a hash sequence,
/// deduplication, on-screen windows, and the stored markdown block the reader parses back.
///
/// Exercised here once rather than per source, because `YouTubeSlideExtractionService` and
/// `RecordingSlideExtractionService` differ only in how they come by the frames.
@Suite("Slide Frame Extraction")
struct SlideFrameExtractionTests {

    @Test("Formats extracted slide frame markdown")
    func formatsSlideMarkdown() {
        let frames = [
            SlideFrameExtraction.SlideFrame(
                index: 1,
                timeSeconds: 125,
                windows: [SlideTimeWindow(start: 120, end: 190)],
                localImagePath: "Videos/src_1/Slides/slide_001_000125s.jpg"
            ),
            // A page the presenter came back to: one stored frame, two appearances.
            SlideFrameExtraction.SlideFrame(
                index: 2,
                timeSeconds: 205,
                windows: [
                    SlideTimeWindow(start: 200, end: 260),
                    SlideTimeWindow(start: 700, end: 3730),
                ],
                localImagePath: "Videos/src_1/Slides/slide_002_000205s.jpg"
            ),
            SlideFrameExtraction.SlideFrame(
                index: 3,
                timeSeconds: nil,
                windows: [],
                localImagePath: "Videos/src_1/Slides/slide_003.jpg"
            ),
        ]

        let markdown = SlideFrameExtraction.formatSlideMarkdown(frames)

        #expect(markdown.contains("## Extracted video slide frames"))
        #expect(markdown.contains("### Slide frame 1 [2:00–3:10]"))
        #expect(markdown.contains("Image: Videos/src_1/Slides/slide_001_000125s.jpg"))
        #expect(markdown.contains("### Slide frame 2 [3:20–4:20] [11:40–1:02:10]"))
        #expect(markdown.contains("### Slide frame 3\n"))
        // Slides carry no transcribed text: a vision model reads the image directly, so
        // nothing here should be recording a second-hand copy of it.
        #expect(!markdown.contains("Recognized slide text:"))
    }

    /// The windows written at extraction must come back out of the transcript parser
    /// intact: they are what decides when a slide's papers are on screen.
    @Test("Round-trips slide windows through markdown")
    func roundTripsSlideWindows() throws {
        let frames = [
            SlideFrameExtraction.SlideFrame(
                index: 1,
                timeSeconds: 125,
                windows: [
                    SlideTimeWindow(start: 120, end: 190),
                    SlideTimeWindow(start: 700, end: 760),
                ],
                localImagePath: "Videos/src_1/Slides/slide_001_000125s.jpg"
            )
        ]
        let content = "Transcript body.\n\n" + SlideFrameExtraction.formatSlideMarkdown(frames)

        let slide = try #require(YouTubeSlideContentParser.parse(content).slides.first)

        #expect(slide.windows == [
            SlideTimeWindow(start: 120, end: 190),
            SlideTimeWindow(start: 700, end: 760),
        ])
        // The slide's headline time is its first appearance, which is where seeks land.
        #expect(slide.timeSeconds == 120)
    }

    /// A heading with a single timestamp parses as an open-ended window for the display
    /// layer to close at the next slide.
    @Test("Parses a single-timestamp heading as an open window")
    func parsesSingleTimestampSlideHeading() throws {
        let content = """
        Transcript body.

        ## Extracted video slide frames

        Representative slide screenshots extracted from YouTube video frames.

        ### Slide frame 1 [2:05]
        Image: Videos/src_1/Slides/slide_001_000125s.jpg
        """

        let slide = try #require(YouTubeSlideContentParser.parse(content).slides.first)

        #expect(slide.windows == [SlideTimeWindow(start: 125, end: nil)])
        #expect(slide.timeSeconds == 125)
    }
    // MARK: - Slide detection

    /// Builds a hash with the given bit positions set, so tests can dial an exact
    /// Hamming distance between frames.
    private func hash(bitsSet count: Int) -> SlideFrameExtraction.PerceptualHash {
        var words = [UInt64](repeating: 0, count: 4)
        for bit in 0..<count {
            words[bit / 64] |= UInt64(1) << UInt64(bit % 64)
        }
        return SlideFrameExtraction.PerceptualHash(words: words)
    }

    @Test("Hamming distance counts differing bits across words")
    func measuresHashDistance() {
        #expect(hash(bitsSet: 0).distance(to: hash(bitsSet: 80)) == 80)
        #expect(hash(bitsSet: 80).distance(to: hash(bitsSet: 80)) == 0)
        #expect(hash(bitsSet: 4).distance(to: hash(bitsSet: 0)) == 4)
    }

    @Test("Splits a steady deck into one run per slide")
    func detectsOneRunPerSlide() {
        let slideA = hash(bitsSet: 0)
        let slideB = hash(bitsSet: 80)
        let hashes = [slideA, slideA, slideA, slideB, slideB, slideB]

        let runs = SlideFrameExtraction.detectSlideRuns(hashes: hashes)

        #expect(runs.count == 2)
        #expect(runs[0].startIndex == 0)
        #expect(runs[0].endIndex == 2)
        #expect(runs[1].startIndex == 3)
        #expect(runs[1].endIndex == 5)
    }

    @Test("Samples the representative frame from mid-run")
    func picksMidRunRepresentative() {
        let hashes = [hash(bitsSet: 0), hash(bitsSet: 0), hash(bitsSet: 0)]

        let runs = SlideFrameExtraction.detectSlideRuns(hashes: hashes)

        #expect(runs.count == 1)
        #expect(runs[0].representativeIndex == 1)
    }

    @Test("Ignores footage that never settles")
    func skipsUnstableFootage() {
        let a = hash(bitsSet: 0)
        let b = hash(bitsSet: 80)
        let hashes = [a, b, a, b, a]

        let runs = SlideFrameExtraction.detectSlideRuns(hashes: hashes)

        #expect(runs.isEmpty)
    }

    /// Run detection deliberately does not collapse repeats. A cutaway splits one deck page
    /// into two runs, and both survive to the frame pass that can actually tell them apart.
    @Test("Keeps every stable run, including a repeat of an earlier slide")
    func keepsRepeatedSlideAsItsOwnRun() {
        let slideA = hash(bitsSet: 0)
        let slideB = hash(bitsSet: 80)
        let slideANearlyIdentical = hash(bitsSet: 4)
        let hashes = [
            slideA, slideA, slideA,
            slideB, slideB, slideB,
            slideANearlyIdentical, slideANearlyIdentical, slideANearlyIdentical,
        ]

        let runs = SlideFrameExtraction.detectSlideRuns(hashes: hashes)

        #expect(runs.count == 3)
    }

    // MARK: - Stored-frame deduplication

    @Test("Collapses a slide the presenter returns to")
    func collapsesRepeatedSlide() {
        let slideA = hash(bitsSet: 0)
        let slideB = hash(bitsSet: 80)
        let slideANearlyIdentical = hash(bitsSet: 4)

        #expect(SlideFrameExtraction.isRepeat(slideANearlyIdentical, of: [slideA, slideB]))
        #expect(!SlideFrameExtraction.isRepeat(slideB, of: [slideA]))
        #expect(!SlideFrameExtraction.isRepeat(slideA, of: []))
    }

    /// The repeat must name *which* kept frame it duplicates: its on-screen window is
    /// merged into that frame, so dropping the image never drops the appearance.
    @Test("Names the frame a repeat collapses into")
    func namesRepeatedFrame() {
        let slideA = hash(bitsSet: 0)
        let slideB = hash(bitsSet: 80)
        let slideBNearlyIdentical = hash(bitsSet: 84)

        #expect(SlideFrameExtraction.repeatIndex(slideBNearlyIdentical, in: [slideA, slideB]) == 1)
        #expect(SlideFrameExtraction.repeatIndex(slideA, in: [slideB]) == nil)
    }

    /// The regression this pass exists for, in the numbers measured off a real talk.
    ///
    /// Deduplication used to run on the 160x90 storyboard tiles, where a deck page shown
    /// twice hashes 32-36 bits apart — at or above the 32 that means "different picture", so
    /// no threshold could separate a repeat from a scene change and 26 detected runs
    /// deduplicated to 26. The captured frames of those same moments are 0-9 apart.
    @Test("Recognizes repeats at captured-frame distances but not at storyboard-tile ones")
    func separatesRepeatsOnlyAtFrameResolution() {
        let slide = hash(bitsSet: 0)

        // Distances between captured frames of one deck page seen twice.
        for measured in [0, 9] {
            #expect(SlideFrameExtraction.isRepeat(hash(bitsSet: measured), of: [slide]))
        }
        // The same pairs, as the storyboard tiles they were located by. Nothing collapses,
        // which is why the pass cannot live there.
        for measured in [32, 36] {
            #expect(!SlideFrameExtraction.isRepeat(hash(bitsSet: measured), of: [slide]))
        }
        // …and the nearest genuinely-distinct pair in that talk, which must survive.
        #expect(!SlideFrameExtraction.isRepeat(hash(bitsSet: 20), of: [slide]))
    }

    /// The regression that motivated the finer hash: consecutive slides sharing a template
    /// but listing different papers must both survive, or the citation-dense slides are the
    /// exact ones thrown away.
    @Test("Keeps distinct slides that share a template")
    func keepsTemplateSimilarSlides() {
        let firstSlide = hash(bitsSet: 0)
        let secondSlide = hash(bitsSet: 40)
        let hashes = [firstSlide, firstSlide, firstSlide, secondSlide, secondSlide, secondSlide]

        let runs = SlideFrameExtraction.detectSlideRuns(hashes: hashes)

        #expect(runs.count == 2)
    }

    /// Storyboard density varies a lot between videos. Two tiles means 20 seconds on a spec
    /// observed at 10s per tile but only 4 on a denser one, so the floor is expressed in
    /// seconds and converted.
    @Test("Scales the stability floor to the tile interval")
    func scalesStabilityFloorToInterval() {
        let slideA = hash(bitsSet: 0)
        let slideB = hash(bitsSet: 80)
        // Each slide held for two tiles.
        let hashes = [slideA, slideA, slideB, slideB]

        // At 10s per tile, two tiles is 20 seconds — comfortably stable.
        #expect(SlideFrameExtraction.detectSlideRuns(hashes: hashes, tileIntervalSeconds: 10).count == 2)
        // At 1s per tile, two tiles is 2 seconds — a transition, not a slide.
        #expect(SlideFrameExtraction.detectSlideRuns(hashes: hashes, tileIntervalSeconds: 1).isEmpty)
    }

    @Test("Leaves a normal-length deck unthinned")
    func keepsAllRunsUnderCap() {
        let runs = (0..<10).map { index in
            SlideFrameExtraction.SlideRun(
                startIndex: index * 3,
                endIndex: index * 3 + 2,
                representativeIndex: index * 3 + 1,
                hash: hash(bitsSet: 0)
            )
        }

        #expect(SlideFrameExtraction.boundedRuns(runs).count == 10)
    }

    // MARK: - Slide window timing

    @Test("Dates a slide's window from the transition midpoints, not the lagging tile")
    func slideWindowUsesTransitionMidpoints() throws {
        // Tiles every 10s at 0,10,…,50. The run holds tiles 3 and 4 (30s and 40s).
        let scans = (0..<6).map { index in
            SlideFrameExtraction.TileScan(
                tileIndex: index, timeSeconds: Double(index) * 10, hash: hash(bitsSet: 0))
        }
        let run = SlideFrameExtraction.SlideRun(
            startIndex: 3, endIndex: 4, representativeIndex: 3, hash: hash(bitsSet: 0))

        let window = try #require(
            SlideFrameExtraction.slideWindow(for: run, scans: scans, tileIntervalSeconds: 10))

        // Start = midpoint(20, 30), end = midpoint(40, 50) — a half-interval earlier than the
        // tiles bounding the run (30 and 50), which is where the lag used to sit.
        #expect(window == SlideTimeWindow(start: 25, end: 45))
    }

    @Test("The first run opens at its first tile, since nothing precedes it")
    func slideWindowFirstRunClampsToStart() throws {
        let scans = (0..<4).map { index in
            SlideFrameExtraction.TileScan(
                tileIndex: index, timeSeconds: Double(index) * 10, hash: hash(bitsSet: 0))
        }
        let run = SlideFrameExtraction.SlideRun(
            startIndex: 0, endIndex: 1, representativeIndex: 0, hash: hash(bitsSet: 0))

        let window = try #require(
            SlideFrameExtraction.slideWindow(for: run, scans: scans, tileIntervalSeconds: 10))

        #expect(window.start == 0)     // no earlier tile to split the difference with
        #expect(window.end == 15)      // midpoint(10, 20)
    }

    @Test("The last run closes one interval past its final tile")
    func slideWindowLastRunExtendsByInterval() throws {
        let scans = (0..<4).map { index in
            SlideFrameExtraction.TileScan(
                tileIndex: index, timeSeconds: Double(index) * 10, hash: hash(bitsSet: 0))
        }
        let run = SlideFrameExtraction.SlideRun(
            startIndex: 2, endIndex: 3, representativeIndex: 3, hash: hash(bitsSet: 0))

        let window = try #require(
            SlideFrameExtraction.slideWindow(for: run, scans: scans, tileIntervalSeconds: 10))

        #expect(window.start == 15)    // midpoint(10, 20)
        #expect(window.end == 40)      // last tile 30 + one 10s interval
    }

    // MARK: - Frames this Mac lacks

    private func slide(_ imagePath: String, start: Double = 30, end: Double? = 90) -> YouTubeSlideFrameContext {
        YouTubeSlideFrameContext(
            index: 1,
            timeSeconds: start,
            windows: [SlideTimeWindow(start: start, end: end)],
            imagePath: imagePath,
            recognizedText: ""
        )
    }

    @Test("A frame is taken again at the second its file name records, not when the slide came on")
    func capturedSecondsReadsTheFileName() {
        // The name records the middle of the run (450), the window when the slide came on (420).
        #expect(SlideFrameExtraction.capturedSeconds(
            of: slide("Videos/src_1/Slides/slide_013_000450s.jpg", start: 420, end: 500)
        ) == 450)
        // A name without a second falls back to the middle of the first window.
        #expect(SlideFrameExtraction.capturedSeconds(of: slide("Videos/src_1/Slides/slide_013.jpg")) == 60)
        // And with no window end to take a middle of, the slide's own time.
        #expect(SlideFrameExtraction.capturedSeconds(of: slide("Videos/src_1/Slides/slide_013.jpg", end: nil)) == 30)
    }

    @Test("Only frames kept under the content root and absent from this Mac are listed to restore")
    func missingFramesListsOnlyRestorableAbsentFrames() {
        let absent = "Videos/src_test_\(UUID().uuidString)/Slides/slide_002_000042s.jpg"
        let missing = SlideFrameExtraction.missingFrames([
            slide(absent),
            // Neither can be put back where the block's readers look for it.
            slide("https://example.com/Videos/src_1/Slides/slide_001_000010s.jpg"),
            slide("/nonexistent-\(UUID().uuidString)/Videos/src_1/Slides/slide_001_000010s.jpg"),
        ])
        #expect(missing == [SlideFrameExtraction.StoredFrame(relativePath: absent, seconds: 42)])
    }
}
