import Testing
@testable import ForeverLM

@Suite("Deep Research")
struct DeepResearchServiceTests {
    @Test("Candidates use deterministic URL identity across search passes")
    func mergesTrackingVariants() throws {
        let passes = [
            DeepResearchPass(
                id: "overview",
                title: "Landscape",
                notes: "",
                citations: [
                    AIWebCitation(
                        url: "https://www.example.com/report?utm_source=search",
                        title: "Example report"
                    )
                ]
            ),
            DeepResearchPass(
                id: "primary",
                title: "Primary evidence",
                notes: "",
                citations: [
                    AIWebCitation(
                        url: "https://example.com/report#results",
                        title: "Example report — results"
                    )
                ]
            ),
        ]

        let candidates = DeepResearchService.mergeCandidates(from: passes)

        #expect(candidates.count == 1)
        #expect(candidates[0].id == "example.com/report")
        #expect(candidates[0].foundBy == ["Landscape", "Primary evidence"])
    }

    @Test("Only importable web citations become candidates")
    func filtersNonWebCitations() throws {
        let pass = DeepResearchPass(
            id: "overview",
            title: "Landscape",
            notes: "",
            citations: [
                AIWebCitation(url: "file:///tmp/private.pdf", title: "Local"),
                AIWebCitation(url: "not a URL", title: "Broken"),
                AIWebCitation(url: "https://example.org/source", title: "Source"),
            ]
        )

        let candidates = DeepResearchService.mergeCandidates(from: [pass])

        #expect(candidates.map(\.url) == ["https://example.org/source"])
    }

    @Test("Provider citation streams expose sources cited in the final answer")
    func collectsProviderCitations() {
        var accumulator = AIToolCallStreamAccumulator()
        accumulator.consume([
            "choices": [[
                "delta": [
                    "content": "The evidence",
                    "annotations": [[
                        "type": "url_citation",
                        "url_citation": ["url": "https://example.org/evidence", "title": "Cited evidence"],
                    ]],
                ],
            ]],
        ])
        // A top-level citations array lists every page a search agent
        // encountered, including pages not cited in the answer. Only the
        // answer's annotations are safe to present as citations.
        accumulator.consume([
            "citations": [
                "https://example.org/encountered",
                "https://example.org/encountered",
            ],
            "choices": [["delta": ["content": "."]]],
        ])

        #expect(accumulator.webCitations == [
            AIWebCitation(url: "https://example.org/evidence", title: "Cited evidence"),
        ])
    }
}
