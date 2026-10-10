import Foundation
import Testing
@testable import ForeverLM

@Suite("Transcript Slide Anchoring")
struct TranscriptSlideAnchoringTests {

    private func timings(_ starts: [Double]) -> [(start: Double, end: Double)] {
        starts.enumerated().map { offset, start in
            let next = starts[(offset + 1)...].first { $0 >= 0 }
            let end = next ?? (start >= 0 ? start + 30 : -1)
            return (start: start, end: max(end, start + 0.5))
        }
    }

    private func slide(_ index: Int, at seconds: Double?) -> YouTubeSlideFrameContext {
        YouTubeSlideFrameContext(
            index: index,
            timeSeconds: seconds,
            windows: seconds.map { [SlideTimeWindow(start: $0, end: nil)] } ?? [],
            imagePath: "slide-\(index).jpg",
            recognizedText: ""
        )
    }

    /// Regression: a real talk's transcript runs 2:38 → 25:40 → 3:05, and the stray
    /// 25:40 used to stop the anchor search dead. Every slide from 3:10 to the end of
    /// the talk — 26 of 29 — collapsed onto the 2:38 row, which rendered as a wall of
    /// slides with a single sentence under it.
    @Test("A stray late timestamp does not swallow the rest of the talk")
    func strayTimestampDoesNotSwallowTheTalk() {
        let starts: [Double] = [103, 158, 1540, 185, 208, 238]  // 1:43, 2:38, 25:40, 3:05, 3:28, 3:58
        let slides = [slide(1, at: 190), slide(2, at: 220), slide(3, at: 240)]

        let grouped = TranscriptSlideAnchoring.group(slides: slides, timings: timings(starts))

        #expect(grouped[3]?.map(\.index) == [1])  // 3:10 → the 3:05 segment
        #expect(grouped[4]?.map(\.index) == [2])  // 3:40 → the 3:28 segment
        #expect(grouped[5]?.map(\.index) == [3])  // 4:00 → the 3:58 segment
        #expect(grouped[1] == nil)                // nothing piles onto 2:38
        #expect(grouped[2] == nil)                // and the outlier anchors nothing
    }

    @Test("The out-of-order timestamp is dropped, not the segments after it")
    func dropsTheOutlierRatherThanItsSuccessors() {
        let starts: [Double] = [103, 158, 1540, 185, 208]

        let anchors = TranscriptSlideAnchoring.monotonicAnchors(timings: timings(starts))

        #expect(anchors == [0, 1, 3, 4])
    }

    /// A running-maximum filter would keep 25:40 and discard everything below it —
    /// the exact inversion of what the transcript means.
    @Test("Kept anchors are always non-decreasing")
    func anchorsAreNonDecreasing() {
        let cases: [[Double]] = [
            [103, 158, 1540, 185, 208],   // one spike
            [0, 70, 0, 90, 120],          // one dip
            [60, 30, 900, 45, 50, 55],    // several disagreements
            [500, 400, 300, 200, 100]     // fully reversed
        ]

        for starts in cases {
            let resolved = timings(starts)
            let anchors = TranscriptSlideAnchoring.monotonicAnchors(timings: resolved)
            let values = anchors.map { resolved[$0].start }
            #expect(values == values.sorted(), "not sorted for \(starts): \(values)")
            #expect(!anchors.isEmpty)
        }
    }

    /// The filter must be inert on well-formed transcripts — most of the library.
    @Test("A monotonic transcript keeps every timed segment")
    func monotonicTranscriptKeepsEverySegment() {
        let starts: [Double] = [0, 20, 47, 74, 103, 158, 185, 208]

        let anchors = TranscriptSlideAnchoring.monotonicAnchors(timings: timings(starts))

        #expect(anchors == Array(starts.indices))
    }

    @Test("Untimed segments never anchor a slide")
    func untimedSegmentsNeverAnchor() {
        let starts: [Double] = [-1, 60, -1, -1, 120, -1]
        let slides = [slide(1, at: 90), slide(2, at: 130)]

        let grouped = TranscriptSlideAnchoring.group(slides: slides, timings: timings(starts))

        #expect(grouped[1]?.map(\.index) == [1])
        #expect(grouped[4]?.map(\.index) == [2])
        #expect(grouped.keys.allSatisfy { starts[$0] >= 0 })
    }

    @Test("A slide before the first timestamp falls to the earliest anchor")
    func slideBeforeFirstTimestampUsesEarliestAnchor() {
        let starts: [Double] = [60, 120, 180]
        let slides = [slide(1, at: 5)]

        let grouped = TranscriptSlideAnchoring.group(slides: slides, timings: timings(starts))

        #expect(grouped[0]?.map(\.index) == [1])
    }

    @Test("Slides without a timestamp are skipped")
    func untimedSlidesAreSkipped() {
        let starts: [Double] = [0, 60]
        let slides = [slide(1, at: nil), slide(2, at: 70)]

        let grouped = TranscriptSlideAnchoring.group(slides: slides, timings: timings(starts))

        #expect(grouped.values.flatMap { $0 }.map(\.index) == [2])
    }

    // MARK: - Playback selection

    /// The real transcript this guards had [11:29], two untimed display
    /// paragraphs, then [11:49]. The 11:29 row's 30-second fallback overlapped
    /// 11:49, and the old first-range match kept the sidebar one marker behind.
    @Test("A later real timestamp wins an overlapping fallback range")
    func laterTimestampWinsOverlappingFallback() {
        let resolved: [(start: Double, end: Double)] = [
            (start: 689, end: 719),
            (start: -1, end: -0.5),
            (start: -1, end: -0.5),
            (start: 709, end: 739),
        ]

        #expect(TranscriptSlideAnchoring.activeSegmentIndex(at: 708, timings: resolved) == 0)
        #expect(TranscriptSlideAnchoring.activeSegmentIndex(at: 710, timings: resolved) == 3)
    }

    @Test("Playback does not activate a row before its first timestamp")
    func playbackBeforeFirstTimestampIsInactive() {
        let resolved: [(start: Double, end: Double)] = [
            (start: -1, end: -0.5),
            (start: 60, end: 90),
        ]

        #expect(TranscriptSlideAnchoring.activeSegmentIndex(at: 30, timings: resolved) == nil)
    }

    // MARK: - Interior placement

    private func isSlide(_ item: TranscriptSlideAnchoring.SegmentItem) -> Bool {
        if case .slide = item { return true }
        return false
    }

    private func textPart(_ item: TranscriptSlideAnchoring.SegmentItem) -> String? {
        if case .text(let value, _) = item { return value }
        return nil
    }

    /// The interleaved text runs must reconstruct the body exactly — no sentence dropped at a
    /// split point, no space doubled.
    @Test("Interleaving never drops or duplicates the body text")
    func preservesBodyText() {
        let body = "Alpha beta. Gamma delta! Epsilon zeta? Eta theta."
        let items = TranscriptSlideAnchoring.interleaveSlides(
            into: body, slides: [slide(1, at: 15), slide(2, at: 40)], segmentStart: 0, segmentEnd: 60)

        #expect(items.compactMap(textPart).joined() == body)
    }

    @Test("Text with no slides is a single run")
    func noSlidesSingleRun() {
        let items = TranscriptSlideAnchoring.interleaveSlides(
            into: "One sentence. Two sentence.", slides: [], segmentStart: 0, segmentEnd: 30)

        #expect(items == [.text("One sentence. Two sentence.", sourceUTF16Offset: 0)])
    }

    /// A slide with no time — or a segment with no timing — has no interior position to take,
    /// so it stacks ahead of the text, the way slides did before interior placement.
    @Test("A slide with no time stacks ahead of the text")
    func untimedSlideStacksFirst() {
        let items = TranscriptSlideAnchoring.interleaveSlides(
            into: "One. Two. Three.", slides: [slide(1, at: nil)], segmentStart: 0, segmentEnd: 30)

        guard case .slide = items.first else {
            Issue.record("expected the untimed slide ahead of the text")
            return
        }
    }

    /// The core of the fix: a slide late in a segment's span lands after the earlier
    /// sentences, not jumped up to the paragraph's first word.
    @Test("A slide lands at the point in the text where it came on screen")
    func slidePlacedByInterpolatedTime() {
        let body = "Alpha one two three. Beta four five six. Gamma seven eight nine. Delta ten eleven twelve."
        // Segment spans 0–100s; a slide at 80s is four-fifths through the spoken text.
        let items = TranscriptSlideAnchoring.interleaveSlides(
            into: body, slides: [slide(1, at: 80)], segmentStart: 0, segmentEnd: 100)

        guard let index = items.firstIndex(where: isSlide) else {
            Issue.record("expected a slide item")
            return
        }
        #expect(index > 0)  // not stacked at the top
        #expect(items[..<index].compactMap(textPart).joined().contains("Alpha"))
        #expect(items[(index + 1)...].compactMap(textPart).joined().contains("Delta"))
    }

    @Test("Multiple slides in one segment are spread to their own moments, in order")
    func multipleSlidesSpreadByTime() {
        let body = "Alpha one two three. Beta four five six. Gamma seven eight nine. Delta ten eleven twelve."
        let items = TranscriptSlideAnchoring.interleaveSlides(
            into: body, slides: [slide(1, at: 15), slide(2, at: 85)], segmentStart: 0, segmentEnd: 100)

        let slideOrder = items.compactMap { item -> Int? in
            if case .slide(let frame) = item { return frame.index }
            return nil
        }
        #expect(slideOrder == [1, 2])
        #expect(items.firstIndex(where: isSlide) != items.lastIndex(where: isSlide))
    }
}

@Suite("Transcript Find")
struct TranscriptFindEngineTests {
    private func segment(index: Int, text: String, heading: String? = nil) -> PodcastTranscriptSegment {
        PodcastTranscriptSegment(
            index: index,
            speakerID: "speaker",
            speakerLabel: "Speaker",
            startTime: nil,
            endTime: nil,
            text: text,
            heading: heading
        )
    }

    @Test("Every occurrence is a separate result")
    func everyOccurrenceIsSeparate() {
        let matches = TranscriptFindEngine.matches(
            in: [segment(index: 0, text: "Retro first. RETRO second. retro third.")],
            query: "retro"
        )

        #expect(matches.count == 3)
        #expect(matches.map(\.location) == [0, 13, 27])
    }

    @Test("A result anchors to its paragraph rather than its whole segment")
    func resultAnchorsToParagraph() {
        let text = "First paragraph.\n\nThe target is in this paragraph."
        let matches = TranscriptFindEngine.matches(
            in: [segment(index: 4, text: text)],
            query: "target"
        )

        let match = try! #require(matches.first)
        #expect(match.segmentIndex == 4)
        #expect(match.anchorLocation == ("First paragraph.\n\n" as NSString).length)
    }

    @Test("Next and previous wrap across results")
    func navigationWraps() {
        #expect(TranscriptFindEngine.nextIndex(current: 2, count: 3, backwards: false) == 0)
        #expect(TranscriptFindEngine.nextIndex(current: 0, count: 3, backwards: true) == 2)
        #expect(TranscriptFindEngine.nextIndex(current: 1, count: 3, backwards: false) == 2)
    }

    @Test("Headings and body text are both searchable")
    func headingsAndBodyAreSearchable() {
        let matches = TranscriptFindEngine.matches(
            in: [segment(index: 0, text: "Body target", heading: "Target chapter")],
            query: "target"
        )

        #expect(matches.map(\.field) == [.heading, .body])
    }
}
