import Foundation
import Testing
@testable import ForeverLM

// The Library's Follow up list: the marks set aside to follow up (blue) or
// doubt (pink), newest first, and how the list follows a color change.

@Suite("Follow up list")
struct FollowUpListTests {
    private func mark(
        _ id: String,
        source: String = "s1",
        color: SourceHighlightColor,
        at seconds: TimeInterval = 0,
        quote: String = "A passage"
    ) -> FollowUpMark {
        FollowUpMark(
            highlight: SourceHighlight(
                id: id, sourceID: source, quote: quote, note: "", color: color,
                anchor: ReaderTextAnchor(exact: quote), pdfAnchor: nil,
                createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds)
            ),
            sourceID: source
        )
    }

    @Test("Only blue and pink marks are listed, newest first, ties in id order")
    func openMarksNewestFirst() {
        let listed = FollowUpList.open([
            mark("old-blue", color: .blue, at: 1),
            mark("yellow", color: .yellow, at: 5),
            mark("green", color: .green, at: 6),
            mark("purple", color: .purple, at: 7),
            mark("new-pink", color: .pink, at: 9),
            mark("b-tie", color: .blue, at: 3),
            mark("a-tie", color: .pink, at: 3),
        ], isPutAway: { _ in false })
        #expect(listed.map(\.id) == ["new-pink", "a-tie", "b-tie", "old-blue"])
    }

    @Test("A mark on a hidden or archived source leaves with it")
    func putAwaySourcesDropTheirMarks() {
        let listed = FollowUpList.open([
            mark("kept", source: "kept-source", color: .blue, at: 2),
            mark("gone", source: "put-away", color: .blue, at: 3),
        ], isPutAway: { $0 == "put-away" })
        #expect(listed.map(\.id) == ["kept"])
    }

    @Test("A slide set down on the canvas and never written on is no follow-up")
    func bareSlideMarkIsNotListed() {
        let slide = ReaderClip.slideHighlight(sourceID: "talk", slide: 3, title: "Slide 3", pixelWidth: 16, pixelHeight: 9)
        let bare = FollowUpMark(highlight: slide, sourceID: "talk")
        var blue = slide
        blue.color = .blue
        let blueBare = FollowUpMark(highlight: blue, sourceID: "talk")
        #expect(bare.highlight.isBareSlideMark)
        #expect(FollowUpList.open([blueBare], isPutAway: { _ in false }).isEmpty)
    }

    @Test("Changing a mark's color adds it to the list, or takes it off")
    func colorChangesMoveMarksInAndOut() {
        var marks = [mark("a", color: .blue, at: 1)]

        // Yellow to blue: a new open mark joins.
        var b = mark("b", color: .blue, at: 2).highlight
        marks = FollowUpList.applying(b, to: marks)
        #expect(Set(marks.map(\.id)) == ["a", "b"])

        // Blue to pink: still open, replaced once, not duplicated.
        b.color = .pink
        marks = FollowUpList.applying(b, to: marks)
        #expect(marks.count == 2)
        #expect(marks.first { $0.id == "b" }?.highlight.color == .pink)

        // Pink to yellow (Followed Up): it leaves.
        b.color = .default
        marks = FollowUpList.applying(b, to: marks)
        #expect(marks.map(\.id) == ["a"])

        // Deleting a mark takes it off, and deleting an absent one changes nothing.
        #expect(FollowUpList.removing("a", from: marks).isEmpty)
        #expect(FollowUpList.removing("nope", from: marks).map(\.id) == ["a"])
    }

    @Test("The list's sections are the To Read sections, so both lists read alike")
    func sectionsMatchToRead() {
        let now = Date()
        let marks = [
            mark("today", color: .blue, at: now.timeIntervalSince1970 - 60),
            mark("old", color: .pink, at: now.timeIntervalSince1970 - 40 * 86_400),
        ]
        let sections = ToReadList.sections(marks, dateAdded: { $0.highlight.createdAt }, now: now)
        #expect(sections.map(\.section.title) == ["Today", "Earlier"])
    }
}
