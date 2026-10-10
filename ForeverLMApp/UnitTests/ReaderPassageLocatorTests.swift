import Foundation
import Testing
@testable import ForeverLM

/// A citation's excerpt is copied from the stored text; the reader has PDFKit's
/// or the DOM's rendering of the same passage. The locator has to land on the
/// passage anyway, and to land on nothing rather than on a stray common phrase
/// when the excerpt is not there.
@Suite("Reader passage locator")
struct ReaderPassageLocatorTests {
    /// Page text the way PDFKit hands it back: line breaks inside sentences, a
    /// word hyphenated across a line, a ligature and curly quotes.
    private let pageText = """
    Patients can consume more oxygen for a given amount of body mass or physical
    work, indicating lower energetic eﬃciency rather than simply low metabolism.
    Under free-living conditions, total expenditure was similar because patients
    were substantially less physically active — possibly behavioural compen-
    sation within a constrained energy budget. “Energy expenditure per unit of
    movement” was markedly elevated in the ten patients studied.
    """

    private func located(_ passage: String) -> (text: String, complete: Bool)? {
        guard let match = ReaderPassageLocator.locate(passage, in: pageText) else { return nil }
        return (String(pageText[match.range]), match.isComplete)
    }

    @Test("An excerpt is found across line breaks, case and a ligature")
    func excerptCrossesLineBreaksAndLigatures() throws {
        let found = try #require(located("lower energetic efficiency rather than simply low metabolism"))
        #expect(found.complete)
        #expect(found.text == "lower energetic eﬃciency rather than simply low metabolism")

        let wrapped = try #require(located("Physical work, indicating lower energetic efficiency"))
        #expect(wrapped.complete)
        #expect(wrapped.text.hasPrefix("physical\nwork, indicating"))
    }

    @Test("A word hyphenated at a line end reads as one word")
    func hyphenationAtLineEndIsJoined() throws {
        let found = try #require(located("possibly behavioural compensation within a constrained energy budget"))
        #expect(found.complete)
        #expect(found.text.contains("compen-\nsation"))
    }

    @Test("Quotation marks around and inside the excerpt do not matter")
    func quotationMarksAreFolded() throws {
        let found = try #require(located("\"Energy expenditure per unit of movement\" was markedly elevated"))
        #expect(found.complete)
        // The excerpt's own quotation marks are trimmed, so the match starts on
        // the first word rather than on the page's curly quote.
        #expect(found.text.hasPrefix("Energy expenditure per unit of\nmovement” was markedly elevated"))
    }

    @Test("An excerpt the source only partly carries lands on the run of words it does carry")
    func partialExcerptFallsBackToItsLongestRun() throws {
        // The model paraphrased the ending; the head of the sentence is real.
        let found = try #require(located("Patients can consume more oxygen for a given amount of body weight"))
        #expect(!found.complete)
        #expect(found.text == "Patients can consume more oxygen for a given amount of body")

        // And an invented start with a real ending.
        let tail = try #require(located("Hypermetabolic patients were substantially less physically active"))
        #expect(!tail.complete)
        #expect(tail.text == "patients\nwere substantially less physically active")
    }

    @Test("An excerpt with an ellipsis inside is found by its longest piece")
    func ellipsisPicksTheLongestPiece() throws {
        let found = try #require(located("total expenditure was similar … constrained energy budget"))
        #expect(found.complete)
        #expect(found.text == "total expenditure was similar")
    }

    @Test("Too little in common with the source is no match, not a random one")
    func unrelatedExcerptFindsNothing() {
        #expect(ReaderPassageLocator.locate("mitochondrial biogenesis and glycolytic upregulation", in: pageText) == nil)
        // Three words in a row in common are below the floor a partial match needs.
        #expect(ReaderPassageLocator.locate("among the ten enrolled participants at baseline", in: pageText) == nil)
        #expect(ReaderPassageLocator.locate("", in: pageText) == nil)
        #expect(ReaderPassageLocator.locate("anything", in: "") == nil)
    }

    @Test("Candidates run from the whole excerpt down to four-word windows at either end")
    func candidatesShrinkFromBothEnds() {
        let candidates = ReaderPassageLocator.candidates(for: "One two three four five six")
        #expect(candidates.map(\.needle) == [
            "one two three four five six",
            "one two three four five",
            "two three four five six",
            "one two three four",
            "three four five six",
        ])
        #expect(candidates.map(\.isComplete) == [true, false, false, false, false])
        #expect(ReaderPassageLocator.candidates(for: "  Short  quote ").map(\.needle) == ["short quote"])
    }

    @Test("Separators are dropped, so a hyphenated line end and a hyphenated compound both match")
    func separatorsAreDropped() throws {
        #expect(ReaderPassageLocator.project("free-living\nconditions").text == "freelivingconditions")
        #expect(ReaderPassageLocator.project("compen-\nsation").text == "compensation")
        #expect(ReaderPassageLocator.project("soft\u{00AD}hyphen — dash").text == "softhyphendash")
        #expect(ReaderPassageLocator.normalize("whole-body energy — “efficiency”") == "whole body energy \"efficiency")

        // The same hyphen-plus-newline is a broken word in one place and a
        // compound followed by a word in the other; both excerpts land.
        let pageText = "determinants of whole-body\nenergy efficiency and compen-\nsation for it"
        let compound = try #require(ReaderPassageLocator.locate("determinants of whole-body energy efficiency", in: pageText))
        #expect(compound.isComplete)
        #expect(String(pageText[compound.range]) == "determinants of whole-body\nenergy efficiency")
        let broken = try #require(ReaderPassageLocator.locate("energy efficiency and compensation for it", in: pageText))
        #expect(broken.isComplete)
        #expect(String(pageText[broken.range]) == "energy efficiency and compen-\nsation for it")
    }
}
