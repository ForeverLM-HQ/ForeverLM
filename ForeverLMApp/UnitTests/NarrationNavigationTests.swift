import Foundation
import Testing
@testable import ForeverLM

@Suite("Going to a part of a narration")
struct NarrationNavigationTests {
    // A narration as the preparation pass writes it: no headings, no
    // citations, no paragraph breaks, hyphenated words joined. Each chunk runs
    // on past its opening, as a real one does for a few thousand characters.
    private static let filler = String(repeating: " Each sentence here is ordinary prose that carries the chunk on.", count: 4)
    private let chunks = [
        "Mitochondria are tiny. They power the cell by moving electrons along a chain of proteins." + filler,
        "When the chain is mismatched, free radicals leak and the cell may die by apoptosis." + filler,
        "The rate of ageing depends on how strictly this threshold is set in each species over time." + filler,
    ]

    @Test("A passage is found despite citations and a word broken across lines")
    func passageWithCitationsAndHyphenation() throws {
        let passage = "When the chain is mis-\nmatched, free radicals leak [12, 13] and the cell may die (Lane, 2011)."
        let spot = try #require(NarrationPassageLocator.spot(of: passage, in: chunks))
        #expect(spot.chunkIndex == 1)
        #expect(spot.fraction < 0.05)
    }

    @Test("A passage whose opening words are not narrated is found from a later word")
    func passageStartingInACaption() throws {
        let passage = "Figure 2 legend panel B shows The rate of ageing depends on how strictly this threshold is set"
        let spot = try #require(NarrationPassageLocator.spot(of: passage, in: chunks))
        #expect(spot.chunkIndex == 2)
    }

    @Test("Text the narration never speaks is not found")
    func unnarratedPassage() {
        let passage = "1. Fenster CB, Galloway LF. Inbreeding and outbreeding depression in natural populations."
        #expect(NarrationPassageLocator.spot(of: passage, in: chunks) == nil)
    }

    @Test("A spot's fraction is how far into its chunk the passage starts")
    func spotFraction() throws {
        let spot = try #require(NarrationPassageLocator.spot(of: "free radicals leak and the cell may die by apoptosis", in: chunks))
        #expect(spot.chunkIndex == 1)
        #expect(spot.fraction > 0.05 && spot.fraction < 0.4)
        #expect(spot.offset(inChunkOfDuration: 10) == 10 * spot.fraction)
    }

    @Test("Sections come out in narration order, with a running header found out of order dropped")
    func sectionsInOrder() {
        let candidates = [
            NarrationSectionCandidate(title: "Introduction", opening: "Mitochondria are tiny. They power the cell by moving electrons"),
            NarrationSectionCandidate(title: "Ageing", opening: "The rate of ageing depends on how strictly this threshold is set"),
            // A header repeated on a later page, whose following text is earlier.
            NarrationSectionCandidate(title: "BioEssays", opening: "When the chain is mismatched, free radicals leak and the cell"),
            NarrationSectionCandidate(title: "References", opening: "1. Fenster CB, Galloway LF. Inbreeding and outbreeding depression"),
        ]
        let sections = NarrationSectionResolver.sections(from: candidates, in: chunks)
        #expect(sections.map(\.title) == ["Introduction", "Ageing"])
        #expect(sections.map(\.spot.chunkIndex) == [0, 2])
    }

    @Test("A large-type title over the first paragraph is the beginning; a named section keeps its name")
    func openingSection() {
        let banner = [NarrationSectionCandidate(title: "Problems & Paradigms", opening: "Mitochondria are tiny. They power the cell")]
        #expect(NarrationSectionResolver.sections(from: banner, in: chunks).first?.title == "Beginning")
        let summary = [NarrationSectionCandidate(title: "Summary", opening: "Mitochondria are tiny. They power the cell")]
        #expect(NarrationSectionResolver.sections(from: summary, in: chunks).first?.title == "Summary")
    }

    @Test("A first section past the opening gets a Beginning before it")
    func beginningInserted() {
        let longer = [String(repeating: "Opening words that run for a while before any heading. ", count: 10)] + chunks
        let candidates = [NarrationSectionCandidate(title: "Ageing", opening: "The rate of ageing depends on how strictly")]
        let sections = NarrationSectionResolver.sections(from: candidates, in: longer)
        #expect(sections.map(\.title) == ["Beginning", "Ageing"])
        #expect(sections.first?.spot == NarrationSpot(chunkIndex: 0, fraction: 0))
    }

    @Test("Standard section names are recognised, numbered or run in")
    func standardNames() {
        #expect(PaperPDFSections.isStandardSectionName("Introduction"))
        #expect(PaperPDFSections.isStandardSectionName("2. Results"))
        #expect(PaperPDFSections.isStandardSectionName("MATERIALS AND METHODS"))
        #expect(PaperPDFSections.isStandardSectionName("Introduction: Mitochondria are essential"))
        #expect(!PaperPDFSections.isStandardSectionName("Results show that mitochondria"))
        #expect(!PaperPDFSections.isStandardSectionName("Mitochondrial genes"))
    }

    @Test("Headings that are not places to go are skipped")
    func skippedHeadings() {
        #expect(PaperPDFSections.isSkippedHeading("References"))
        #expect(PaperPDFSections.isSkippedHeading("Figure 3. Hypermetabolism"))
        #expect(PaperPDFSections.isSkippedHeading("Acknowledgements"))
        #expect(!PaperPDFSections.isSkippedHeading("Discussion"))
    }

    @Test("Titles are tidied: ligatures, shouting, a trailing colon, a compound broken over lines")
    func titles() {
        #expect(PaperPDFSections.cleanTitle("Signi\u{FB01}cance") == "Significance")
        #expect(PaperPDFSections.cleanTitle("INTRODUCTION:") == "Introduction")
        #expect(PaperPDFSections.joinedHeading(["Loss of match drives age-", "related diseases"]) == "Loss of match drives age-related diseases")
        #expect(PaperPDFSections.joinedHeading(["The origin of species", "and evolution of sexes"]) == "The origin of species and evolution of sexes")
    }
}
