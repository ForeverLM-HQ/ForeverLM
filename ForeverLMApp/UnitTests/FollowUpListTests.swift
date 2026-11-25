import Foundation
import Testing
@testable import ForeverLM

// The Library's Follow up list: the marks flagged to follow up, whatever
// their color, newest first, and how the list follows a flag set or taken off.

@Suite("Follow up list")
struct FollowUpListTests {
    private func mark(
        _ id: String,
        source: String = "s1",
        color: SourceHighlightColor = .default,
        flagged: Bool = true,
        at seconds: TimeInterval = 0,
        quote: String = "A passage"
    ) -> FollowUpMark {
        FollowUpMark(
            highlight: SourceHighlight(
                id: id, sourceID: source, quote: quote, note: "", color: color,
                anchor: ReaderTextAnchor(exact: quote), pdfAnchor: nil,
                followUpAt: flagged ? Date(timeIntervalSince1970: seconds) : nil,
                createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds)
            ),
            sourceID: source
        )
    }

    @Test("Only flagged marks are listed, whatever their color, newest first, ties in id order")
    func flaggedMarksNewestFirst() {
        let listed = FollowUpList.open([
            mark("old-yellow", color: .yellow, at: 1),
            mark("unflagged-blue", color: .blue, flagged: false, at: 5),
            mark("unflagged-pink", color: .pink, flagged: false, at: 6),
            mark("new-green", color: .green, at: 9),
            mark("b-tie", color: .purple, at: 3),
            mark("a-tie", color: .pink, at: 3),
        ], isPutAway: { _ in false })
        #expect(listed.map(\.id) == ["new-green", "a-tie", "b-tie", "old-yellow"])
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
        var flagged = slide
        flagged.followUpAt = Date()
        let flaggedBare = FollowUpMark(highlight: flagged, sourceID: "talk")
        #expect(bare.highlight.isBareSlideMark)
        #expect(FollowUpList.open([flaggedBare], isPutAway: { _ in false }).isEmpty)
    }

    @Test("Flagging a mark adds it to the list, a color change leaves it, and taking the flag off takes it off")
    func flagMovesMarksInAndOut() {
        var marks = [mark("a", at: 1)]

        // Flagged: a new mark joins.
        var b = mark("b", color: .yellow, at: 2).highlight
        marks = FollowUpList.applying(b, to: marks)
        #expect(Set(marks.map(\.id)) == ["a", "b"])

        // A color change keeps it on, replaced once, not duplicated.
        b.color = .pink
        marks = FollowUpList.applying(b, to: marks)
        #expect(marks.count == 2)
        #expect(marks.first { $0.id == "b" }?.highlight.color == .pink)

        // Blue without the flag is not on the list.
        var c = mark("c", color: .blue, flagged: false, at: 3).highlight
        marks = FollowUpList.applying(c, to: marks)
        #expect(Set(marks.map(\.id)) == ["a", "b"])
        c.followUpAt = Date()
        marks = FollowUpList.applying(c, to: marks)
        #expect(Set(marks.map(\.id)) == ["a", "b", "c"])

        // Followed Up: the flag comes off and it leaves, its color kept.
        b.followUpAt = nil
        marks = FollowUpList.applying(b, to: marks)
        #expect(Set(marks.map(\.id)) == ["a", "c"])
        marks = FollowUpList.removing("c", from: marks)

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
