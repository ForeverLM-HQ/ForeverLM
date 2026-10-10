import Testing
@testable import ForeverLM

@Suite("Siri source resolution")
struct SiriSourceRankingTests {

    private func item(
        id: String,
        title: String,
        author: String? = nil,
        domain: String? = nil,
        groupTitle: String? = nil
    ) -> SiriSourceItem {
        SiriSourceItem(
            id: id,
            title: title,
            author: author,
            domain: domain,
            sourceType: "article",
            groupTitle: groupTitle
        )
    }

    @Test("Exact title match resolves without guessing")
    func exactTitleResolves() {
        let items = [
            item(id: "a", title: "Thermodynamics of Computation"),
            item(id: "b", title: "Quantum Computation Basics"),
            item(id: "c", title: "Gardening at Night")
        ]
        let ranked = SiriKnowledgeCatalog.rank("thermodynamics of computation", in: items, limit: 10)
        #expect(ranked.first?.id == "a")
        #expect(!ranked.contains { $0.id == "c" })
    }

    @Test("Exact matching is case- and diacritic-insensitive")
    func foldedMatching() {
        let items = [item(id: "a", title: "Schrödinger's Equation")]
        let ranked = SiriKnowledgeCatalog.rank("schrodinger's equation", in: items, limit: 10)
        #expect(ranked.first?.id == "a")
    }

    @Test("An exact group title can resolve a source")
    func exactGroupTitleMatches() {
        let items = [
            item(id: "a", title: "Chapter 3: Entropy", groupTitle: "Feynman Lectures"),
            item(id: "b", title: "Entropy in Ecology")
        ]
        let ranked = SiriKnowledgeCatalog.rank("Feynman Lectures", in: items, limit: 10)
        #expect(ranked.first?.id == "a")
    }

    @Test("Partial semantic matches are not used for identity")
    func partialMatchesDoNotResolve() {
        let items = [item(id: "a", title: "Entropy")]
        let ranked = SiriKnowledgeCatalog.rank("the entropy source", in: items, limit: 10)
        #expect(ranked.isEmpty)
    }

    @Test("Empty query falls back to recency order with limit")
    func emptyQueryReturnsRecent() {
        let items = (0..<5).map { item(id: "\($0)", title: "Source \($0)") }
        let ranked = SiriKnowledgeCatalog.rank("  ", in: items, limit: 3)
        #expect(ranked.map(\.id) == ["0", "1", "2"])
    }
}
