import Foundation
import Testing
@testable import ForeverLM

@Suite("Reader: figure mentions in a paper's text")
struct PrintedFigureMentionTests {
    private func read(_ text: String) -> [(words: String, label: String, panels: String?)] {
        PrintedFigureMentions.mentions(in: text).map {
            ((text as NSString).substring(with: $0.range), $0.label, $0.panels)
        }
    }

    @Test("Extended Data Fig. 1c-g in parentheses names Extended Data Figure 1")
    func extendedDataWithPanels() {
        let found = read("cells were sorted (Extended Data Fig. 1c-g) before")
        #expect(found.count == 1)
        #expect(found.first?.words == "Extended Data Fig. 1c-g")
        #expect(found.first?.label == "Extended Data Figure 1")
        #expect(found.first?.panels == "c-g")
    }

    @Test("A main figure with a list of panels is one mention")
    func panelList() {
        let found = read("as shown (Fig. 2a, b). However")
        #expect(found.map(\.words) == ["Fig. 2a, b"])
        #expect(found.map(\.label) == ["Figure 2"])
        #expect(found.first?.panels == "a, b")
    }

    @Test("Several figures after Figs. are a mention each")
    func pluralList() {
        let found = read("(Figs. 2 and 3; Extended Data Figs. 1c–g, 4a)")
        #expect(found.map(\.words) == ["Figs. 2", "3", "Extended Data Figs. 1c–g", "4a"])
        #expect(found.map(\.label) == ["Figure 2", "Figure 3", "Extended Data Figure 1", "Extended Data Figure 4"])
    }

    @Test("A range names its two ends")
    func range() {
        #expect(read("Figs. 2–4").map(\.label) == ["Figure 2", "Figure 4"])
    }

    @Test("After a single Fig., a comma and a number are not another figure")
    func singularCommaStops() {
        #expect(read("(Fig. 4, 12 of 15 mice)").map(\.words) == ["Fig. 4"])
    }

    @Test("A word that starts after the number is not a panel")
    func wordAfterNumber() {
        #expect(read("Figure 2 shows").map(\.words) == ["Figure 2"])
        #expect(read("Fig. 2, as before").map(\.words) == ["Fig. 2"])
        #expect(read("Fig. 2a and Fig. 3").map(\.words) == ["Fig. 2a", "Fig. 3"])
    }

    @Test("Upper-case panels, and a label broken across lines")
    func upperCaseAndLineBreak() {
        let found = read("(Extended Data\nFig. 3A–C)")
        #expect(found.map(\.label) == ["Extended Data Figure 3"])
        #expect(found.first?.panels == "A–C")
    }

    @Test("Supplementary figures, spelled either way")
    func supplementary() {
        #expect(read("Supplementary Fig. 5").map(\.label) == ["Supplementary Figure 5"])
        #expect(read("(fig. S2B)").map(\.label) == ["Figure S2"])
        #expect(read("ED Fig. 6").map(\.label) == ["Extended Data Figure 6"])
    }

    @Test("Cell's main and supplementary figures in one mention")
    func cellStyleList() {
        let found = read("(Figures 1C, S1A, and S2D–S3)")
        #expect(found.map(\.words) == ["Figures 1C", "S1A", "S2D", "S3"])
        #expect(found.map(\.label) == ["Figure 1", "Figure S1", "Figure S2", "Figure S3"])
    }

    @Test("Not a figure: inside a word, a year, a textbook's 3.4")
    func notMentions() {
        #expect(read("configure 2 workers").isEmpty)
        #expect(read("Fig. 2017").isEmpty)
        #expect(read("Figure 3.4 shows").isEmpty)
        #expect(read("Supplementary Table 2").isEmpty)
    }

    @Test("The range is in UTF-16 offsets, past letters outside the BMP")
    func utf16Range() {
        let text = "𝛼 cells (Fig. 1)"
        let mention = try! #require(PrintedFigureMentions.mentions(in: text).first)
        #expect((text as NSString).substring(with: mention.range) == "Fig. 1")
    }

    @Test("A mention finds its figure in the index however each spells it")
    func matching() {
        let index = ["Figure 1", "Figure 2", "Extended Data Figure 1", "Figure S3", "Supplementary Figure 4"]
        #expect(PrintedFigureMentions.matchingLabel("Extended Data Figure 1", among: index) == "Extended Data Figure 1")
        #expect(PrintedFigureMentions.matchingLabel("Figure 1", among: index) == "Figure 1")
        #expect(PrintedFigureMentions.matchingLabel("Supplementary Figure 3", among: index) == "Figure S3")
        #expect(PrintedFigureMentions.matchingLabel("Figure S4", among: index) == "Supplementary Figure 4")
        #expect(PrintedFigureMentions.matchingLabel("Extended Data Figure 2", among: index) == nil)
        #expect(PrintedFigureMentions.matchingLabel("Figure 2", among: ["Figure 2B"]) == "Figure 2B")
    }
}
