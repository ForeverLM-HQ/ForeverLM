import Foundation
import Testing
@testable import ForeverLM

@Suite("Transcript highlight placement")
struct TranscriptHighlightPlacementTests {
    private func segment(_ index: Int, _ text: String, heading: String? = nil) -> PodcastTranscriptSegment {
        PodcastTranscriptSegment(
            index: index,
            speakerID: "s\(index % 2)",
            speakerLabel: "Speaker \(index % 2 + 1)",
            startTime: "0:\(String(format: "%02d", index))",
            endTime: nil,
            text: text,
            heading: heading
        )
    }

    private var segments: [PodcastTranscriptSegment] {
        [
            segment(0, "Yeah."),
            segment(1, "Interesting. So just to say it explicitly for people, normally when we think about memory, we think about neurons."),
            segment(2, "Right. Memory obviously has a neurobiological and a psychological sense, but it also has an engineering sense.\n\nSo, Dennard's electronic memory is a two-component system. Yeah."),
            segment(3, "So, human beings dreamed up and built this type of system.", heading: "Nature got there first"),
        ]
    }

    private func highlight(_ quote: String, anchor: ReaderTextAnchor, id: String = "hl_1") -> SourceHighlight {
        SourceHighlight(
            id: id,
            sourceID: "src",
            quote: quote,
            note: "",
            color: .yellow,
            anchor: anchor,
            pdfAnchor: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("A selection in one paragraph anchors against the whole transcript, with context across the turn boundary")
    func selectionAnchorsAcrossTurns() throws {
        let document = TranscriptDocumentText(segments: segments)
        // "Memory obviously has a neurobiological" inside segment 2's first paragraph.
        let body = segments[2].text as NSString
        let range = body.range(of: "Memory obviously has a neurobiological")
        let passage = TranscriptPassage(segmentIndex: 2, field: .body, rangeInField: range)

        let anchored = try #require(document.anchor(for: passage))
        #expect(anchored.quote == "Memory obviously has a neurobiological")
        #expect(anchored.anchor.exact == anchored.quote)
        // The prefix reaches back into the previous speaker's turn — context a
        // paragraph-local anchor could never carry.
        #expect(anchored.anchor.prefix.contains("neurons."))
        #expect(anchored.anchor.prefix.hasSuffix("Right. "))
        #expect(anchored.anchor.suffix.hasPrefix(" and a psychological"))

        // And it resolves back to the same words in the same segment.
        let placements = document.placements(for: [highlight(anchored.quote, anchor: anchored.anchor)])
        #expect(placements.keys.sorted() == [2])
        #expect(placements[2]?.first?.passage.rangeInField == range)
    }

    @Test("A repeated short passage lands only on the copy that was marked")
    func repeatedPassageResolvesOnce() throws {
        let document = TranscriptDocumentText(segments: segments)
        // Mark the "Yeah." that closes segment 2, not the one that is all of segment 0.
        let body = segments[2].text as NSString
        let range = body.range(of: "Yeah.", options: .backwards)
        let anchored = try #require(document.anchor(for: TranscriptPassage(
            segmentIndex: 2, field: .body, rangeInField: range
        )))

        let placements = document.placements(for: [highlight("Yeah.", anchor: anchored.anchor)])
        #expect(placements.keys.sorted() == [2])
        #expect(placements[0] == nil)
        #expect(placements[2]?.count == 1)
        #expect(placements[2]?.first?.passage.rangeInField == range)
    }

    @Test("A highlight saved from the stored text is found by its words, and a heading is its own field")
    func anchorsFromElsewhereAndHeadings() {
        let document = TranscriptDocumentText(segments: segments)
        // What create_source_highlight writes: an anchor with the quote alone.
        let fromMCP = highlight(
            "human beings dreamed up",
            anchor: ReaderTextAnchor(exact: "human beings dreamed up"),
            id: "hl_mcp"
        )
        let onHeading = highlight(
            "Nature got there first",
            anchor: ReaderTextAnchor(exact: "Nature got there first"),
            id: "hl_heading"
        )
        let gone = highlight(
            "this sentence was edited away",
            anchor: ReaderTextAnchor(exact: "this sentence was edited away"),
            id: "hl_gone"
        )

        let placements = document.placements(for: [fromMCP, onHeading, gone])
        let inThree = placements[3] ?? []
        #expect(inThree.count == 2)
        #expect(inThree.first { $0.highlightID == "hl_mcp" }?.passage.field == .body)
        #expect(inThree.first { $0.highlightID == "hl_heading" }?.passage.field == .heading)
        #expect(inThree.first { $0.highlightID == "hl_heading" }?.passage.rangeInField == NSRange(location: 0, length: 22))
        #expect(placements.values.joined().contains { $0.highlightID == "hl_gone" } == false)
    }

    @Test("A passage spanning two paragraphs of one turn is split into each paragraph's share")
    func spanningParagraphs() throws {
        let document = TranscriptDocumentText(segments: segments)
        let body = segments[2].text as NSString
        let start = body.range(of: "engineering sense.")
        let end = body.range(of: "So, Dennard's")
        let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        let anchored = try #require(document.anchor(for: TranscriptPassage(
            segmentIndex: 2, field: .body, rangeInField: range
        )))
        let placement = try #require(document.placements(for: [highlight(anchored.quote, anchor: anchored.anchor)])[2]?.first)

        let slices = TranscriptTextLayout.paragraphSlices(in: segments[2].text)
        #expect(slices.count == 2)
        let firstShare = placement.localRange(inField: .body, sliceRange: slices[0].sourceUTF16Range)
        let secondShare = placement.localRange(inField: .body, sliceRange: slices[1].sourceUTF16Range)
        #expect(firstShare == NSRange(location: start.location, length: slices[0].sourceUTF16Range.length - start.location))
        #expect(secondShare == NSRange(location: 0, length: "So, Dennard's".utf16.count))
        // The heading field of the same segment gets nothing.
        #expect(placement.localRange(inField: .heading, sliceRange: NSRange(location: 0, length: 40)) == nil)
    }

    @Test("Empty and whitespace selections make no anchor")
    func emptySelections() {
        let document = TranscriptDocumentText(segments: segments)
        #expect(document.anchor(for: TranscriptPassage(segmentIndex: 1, field: .body, rangeInField: NSRange(location: 0, length: 0))) == nil)
        #expect(document.anchor(for: TranscriptPassage(segmentIndex: 1, field: .body, rangeInField: NSRange(location: 12, length: 1))) == nil)
        #expect(document.anchor(for: TranscriptPassage(segmentIndex: 9, field: .body, rangeInField: NSRange(location: 0, length: 4))) == nil)
        #expect(document.anchor(for: TranscriptPassage(segmentIndex: 1, field: .heading, rangeInField: NSRange(location: 0, length: 4))) == nil)
    }
}
