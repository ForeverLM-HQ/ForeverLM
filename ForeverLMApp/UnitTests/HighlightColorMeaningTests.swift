import Foundation
import Testing
@testable import ForeverLM

// The five marker colors and what each means (`SourceHighlightColor.meaning`),
// the one place the reader, the lists, the phone and the MCP tools read them from.

@Suite("Highlight color meanings")
struct HighlightColorMeaningTests {
    @Test("Each of the five colors has its own one-to-three-word meaning, and the stored values are unchanged")
    func meanings() {
        #expect(SourceHighlightColor.allCases.map(\.rawValue) == ["yellow", "green", "blue", "pink", "purple"])
        #expect(SourceHighlightColor.allCases.map(\.meaning) == ["Remember", "Key idea", "Question", "Doubt", "Connect"])
        #expect(Set(SourceHighlightColor.allCases.map(\.meaning)).count == SourceHighlightColor.allCases.count)
        #expect(SourceHighlightColor.allCases.allSatisfy { (1...3).contains($0.meaning.split(separator: " ").count) })
        #expect(SourceHighlightColor.blue.spokenName == "Question, blue")
        #expect(SourceHighlightColor.meaningGuide == "yellow (Remember), green (Key idea), blue (Question), pink (Doubt), purple (Connect)")
    }

    @Test("The MCP tools name the colors by meaning, and a mark's payload carries it beside the stored color")
    func mcpCarriesTheMeanings() throws {
        let tools = MCPToolRegistry().tools
        for name in ["create_source_highlight", "update_source_highlight"] {
            let tool = try #require(tools.first { $0.name == name })
            let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
            let color = try #require(properties["color"] as? [String: Any])
            let description = try #require(color["description"] as? String)
            #expect(description.contains(SourceHighlightColor.meaningGuide), "\(name)'s color")
        }
        #expect(MCPDataStore.highlightColorList == SourceHighlightColor.meaningGuide)
    }

    // MARK: - The meaning reaches the work

    private func mark(
        _ id: String, _ quote: String, note: String = "", color: SourceHighlightColor, at seconds: TimeInterval = 0
    ) -> SourceHighlight {
        SourceHighlight(
            id: id, sourceID: "s", quote: quote, note: note, color: color,
            anchor: ReaderTextAnchor(exact: quote), pdfAnchor: nil,
            createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("Blue and pink are the open marks; the tags and their guide name every color")
    func openItemsAndTags() {
        #expect(SourceHighlightColor.allCases.filter(\.isOpenItem) == [.blue, .pink])
        #expect(SourceHighlightColor.allCases.map(\.promptTag) == ["[REMEMBER]", "[KEY IDEA]", "[QUESTION]", "[DOUBT]", "[CONNECT]"])
        #expect(SourceHighlightColor.promptTagGuide.contains("[QUESTION] a question the learner has"))
        #expect(SourceHighlightColor.promptTagGuide.contains("[DOUBT] doubted"))
    }

    @Test("While every mark is yellow the learner has said nothing with color, so no tag is added")
    func noTagsWhileAllYellow() {
        let lines = SourceIdeaDrafting.highlightLines([
            mark("a", "First", color: .yellow, at: 1),
            mark("b", "Second", note: "mine", color: .yellow, at: 2),
        ])
        #expect(lines == ["Second — THEIR OWN NOTE: mine", "First"])
    }

    @Test("Once a color is chosen every mark is tagged, and the marks to follow up or doubt come first")
    func tagsAndOrder() {
        let lines = SourceIdeaDrafting.highlightLines([
            mark("a", "Plain yellow", color: .yellow, at: 3),
            mark("b", "Key claim", note: "why", color: .green, at: 2),
            mark("c", "Check this later", color: .blue, at: 1),
            mark("d", "Not convinced", color: .pink, at: 0),
        ])
        #expect(lines == [
            "[QUESTION] Check this later",
            "[DOUBT] Not convinced",
            "[KEY IDEA] Key claim — THEIR OWN NOTE: why",
            "[REMEMBER] Plain yellow",
        ])
    }

    @Test("A prompt's cap on marks never drops the ones set aside to follow up")
    func openMarksSurviveTheCap() {
        var marks = (0..<12).map { mark("n\($0)", "Settled \($0)", color: .green, at: TimeInterval(100 + $0)) }
        marks.append(mark("old", "Look into this", color: .blue, at: 0))
        let kept = SourceIdeaDrafting.highlightLines(marks).prefix(CohortSourceBrief.maxHighlights)
        #expect(kept.first == "[QUESTION] Look into this")
    }

    @Test("A bare slide mark is still no highlight, tagged or not")
    func bareSlideMarkStaysOut() {
        let bare = ReaderClip.slideHighlight(sourceID: "talk", slide: 3, title: "Slide 3", pixelWidth: 16, pixelHeight: 9)
        #expect(SourceIdeaDrafting.highlightLines([bare, mark("x", "Real", color: .blue)]) == ["[QUESTION] Real"])
    }

    @Test("Card seeds name the color's meaning once colors are used, and settled marks are offered before open ones")
    func cardSeeds() {
        let seeds = CardDraftingSeed.highlights([
            mark("open", "Unsettled claim", color: .blue),
            mark("noted", "Settled and noted", note: "mine", color: .green),
            mark("plain", "Settled", color: .yellow),
            mark("doubt", "Doubted", note: "why", color: .pink),
        ])
        #expect(seeds.map(\.key) == [
            CardDraftingSeedKey.highlight("noted"),
            CardDraftingSeedKey.highlight("plain"),
            CardDraftingSeedKey.highlight("doubt"),
            CardDraftingSeedKey.highlight("open"),
        ])
        #expect(seeds[0].text == "Highlighted [KEY IDEA]: \u{201C}Settled and noted\u{201D}\nTheir note: mine")
        #expect(seeds.last?.text == "Highlighted [QUESTION]: \u{201C}Unsettled claim\u{201D}")

        let untouched = CardDraftingSeed.highlights([mark("p", "Only yellow", color: .yellow)])
        #expect(untouched.first?.text == "Highlighted: \u{201C}Only yellow\u{201D}")
    }

    @Test("The prompts that read marks say what the tags mean, and chat knows to look for follow-ups")
    func promptsExplainTheTags() {
        #expect(Prompts.sourceIdeaExtraction.contains(SourceHighlightColor.promptTagGuide))
        #expect(Prompts.cohortSessionPlanner.contains(SourceHighlightColor.promptTagGuide))
        #expect(Prompts.cardDrafter.contains("[QUESTION] or [DOUBT]"))
        // Follow-ups are the flag now, whatever the color; doubts are still pink.
        #expect(Prompts.mcpServerInstructions.contains("search_source_highlights with follow_up true"))
        #expect(Prompts.mcpServerInstructions.contains("for what they doubt with color \"pink\""))
        #expect(Prompts.mcpServerInstructions.contains(SourceHighlightColor.meaningGuide))
    }

    @Test("search_source_highlights takes a color, named by meaning")
    func searchTakesAColor() throws {
        let tool = try #require(MCPToolRegistry().tools.first { $0.name == "search_source_highlights" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let color = try #require(properties["color"] as? [String: Any])
        #expect((color["description"] as? String)?.contains(SourceHighlightColor.meaningGuide) == true)
    }
}
