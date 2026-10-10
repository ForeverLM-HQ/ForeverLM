import Testing
@testable import ForeverLM

@Suite("normalizedPaperTitle")
@MainActor
struct NormalizedPaperTitleTests {
    @Test("Lowercases title")
    func lowercases() {
        let result = StudioViewModel.normalizedPaperTitle("Attention Is All You Need")
        #expect(result == "attention is all you need")
    }

    @Test("Preserves publisher suffix after pipe")
    func preservesPipeSuffix() {
        let result = StudioViewModel.normalizedPaperTitle("Mitochondria as signaling organelles | BMC Biology | Springer Nature Link")
        #expect(result == "mitochondria as signaling organelles | bmc biology | springer nature link")
    }

    @Test("Preserves publisher suffix after dash")
    func preservesDashSuffix() {
        let result = StudioViewModel.normalizedPaperTitle("Some Paper Title - ScienceDirect")
        #expect(result == "some paper title - sciencedirect")
    }

    @Test("Does not collapse whitespace around colons")
    func preservesColonSpacing() {
        let a = StudioViewModel.normalizedPaperTitle("SCALE:Scalable Conditional Atlas-Level Endpoint transport")
        let b = StudioViewModel.normalizedPaperTitle("SCALE: Scalable Conditional Atlas-Level Endpoint transport")
        #expect(a != b)
    }

    @Test("Preserves multiple spaces")
    func preservesMultipleSpaces() {
        let result = StudioViewModel.normalizedPaperTitle("Title  with   extra    spaces")
        #expect(result == "title  with   extra    spaces")
    }

}
