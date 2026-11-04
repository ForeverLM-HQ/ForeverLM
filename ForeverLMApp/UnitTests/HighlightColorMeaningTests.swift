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
        #expect(SourceHighlightColor.allCases.map(\.meaning) == ["Remember", "Key idea", "Follow up", "Doubt", "Connect"])
        #expect(Set(SourceHighlightColor.allCases.map(\.meaning)).count == SourceHighlightColor.allCases.count)
        #expect(SourceHighlightColor.allCases.allSatisfy { (1...3).contains($0.meaning.split(separator: " ").count) })
        #expect(SourceHighlightColor.blue.spokenName == "Follow up, blue")
        #expect(SourceHighlightColor.meaningGuide == "yellow (Remember), green (Key idea), blue (Follow up), pink (Doubt), purple (Connect)")
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
}
