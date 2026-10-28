import Foundation
import Testing
@testable import ForeverLM

@Suite("Reader: figure legends beside the paper")
struct ReaderFigureLegendsTests {
    private func record(_ label: String, page: Int, _ caption: String) -> PaperFigureRecord {
        PaperFigureRecord(
            id: "fig-\(label)-\(page)",
            sourceID: "paper-1",
            figureLabel: label,
            pageIndex: page,
            caption: caption,
            analysis: nil
        )
    }

    @Test("A legend is its words with the label off, on one line")
    func legendWordsLoseTheirLabel() {
        let words = PaperFigureCaptionTitle.words(
            from: "Fig. 2. Bats keep a low ROS output per\nunit of oxygen. (A) Liver, (B) heart."
        )
        #expect(words == "Bats keep a low ROS output per unit of oxygen. (A) Liver, (B) heart.")
        // The title is still the first sentence of the same words.
        #expect(PaperFigureCaptionTitle.title(from: "Fig. 2. Bats keep a low ROS output. (A) Liver.") == "Bats keep a low ROS output")
    }

    @Test("A caption that prints only its label has no words")
    func labelAloneHasNoWords() {
        #expect(PaperFigureCaptionTitle.words(from: "Figure 1.").isEmpty)
    }

    @Test("One entry a figure, in page order, each carrying its legend")
    func entriesFollowThePages() {
        let entries = ReaderFigureLegends.entries(from: [
            record("Figure 2", page: 6, "Figure 2. Second result."),
            record("Figure 1", page: 3, "Figure 1. First result. (A) Cells."),
        ])
        #expect(entries.map(\.label) == ["Figure 1", "Figure 2"])
        #expect(entries.map(\.pageNumber) == [4, 7])
        #expect(entries[0].legend == "First result. (A) Cells.")
    }

    @Test("A figure's legend continued onto the next page is one entry, on the figure's page")
    func continuedCaptionIsOneEntry() {
        let entries = ReaderFigureLegends.entries(from: [
            record("Extended Data Figure 1", page: 8, "Extended Data Fig. 1 | See next page for caption."),
            record("Extended Data Figure 1", page: 9, "Extended Data Fig. 1 | Atlas of cells. a, Liver. b, Heart."),
        ])
        #expect(entries.count == 1)
        #expect(entries[0].pageIndex == 8)
        #expect(entries[0].legend == "Atlas of cells. a, Liver. b, Heart.")
    }

    @Test("A figure whose legend words were not found still lists, with an empty legend")
    func stubWithNoWordsStillLists() {
        let entries = ReaderFigureLegends.entries(from: [record("Figure 4", page: 11, "Figure 4.")])
        #expect(entries.count == 1)
        #expect(entries[0].legend.isEmpty)
    }

    @Test("The entries on the page being read are the ones whose figure is drawn there")
    func entriesOnThePage() {
        let entries = ReaderFigureLegends.entries(from: [
            record("Figure 1", page: 3, "Figure 1. First."),
            record("Figure 2", page: 3, "Figure 2. Second."),
            record("Figure 3", page: 7, "Figure 3. Third."),
        ])
        #expect(ReaderFigureLegends.entryIDs(onPage: 3, in: entries).count == 2)
        #expect(ReaderFigureLegends.entryIDs(onPage: 7, in: entries) == [entries[2].id])
        #expect(ReaderFigureLegends.entryIDs(onPage: 5, in: entries).isEmpty)
        #expect(ReaderFigureLegends.entryIDs(onPage: nil, in: entries).isEmpty)
    }
}
