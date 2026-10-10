import Foundation
import Testing
@testable import ForeverLM

/// A notebook whose title brings no emoji is drawn with one its words choose,
/// the same on the Mac, the iPhone and the web: the web's
/// `defaultNotebookEmoji` (library-notebooks.js) writes and runs the same
/// vectors (docs-site/website/test/notebook-emoji-vectors.json).
@Suite("Notebook default emoji")
struct NotebookDefaultEmojiTests {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let title: String
            let emoji: String
        }
        struct TintCase: Decodable {
            let id: String
            let tint: Int
        }
        let cases: [Case]
        let tints: [TintCase]
    }

    private static func vectors() throws -> Vectors {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("docs-site/website/test/notebook-emoji-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    @Test("Every shared vector draws the web's emoji")
    func sharedVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.cases.count > 700, "every keyword of the table is a case")
        for vector in vectors.cases {
            #expect(NotebookDefaultEmoji.emoji(for: vector.title) == vector.emoji, "\(vector.title)")
        }
    }

    @Test("Specific topics win over broad ones, and a keyword ending in = takes whole words only")
    func priority() {
        #expect(NotebookDefaultEmoji.emoji(for: "Understand the mitochondrial origins of sleep paper") == "😴")
        #expect(NotebookDefaultEmoji.emoji(for: "Mito Phenotyping") == "🔋")
        #expect(NotebookDefaultEmoji.emoji(for: "Landscape of Aging") == "⏳")
        #expect(NotebookDefaultEmoji.emoji(for: "AI & Machine Learning") == "🤖")
        #expect(NotebookDefaultEmoji.emoji(for: "Pooled in vivo screening") == "🐭")
        #expect(NotebookDefaultEmoji.emoji(for: "Aim high") != "🤖")
    }

    @Test("A title no keyword matches gets a fallback, the same one every time")
    func fallback() {
        let first = NotebookDefaultEmoji.emoji(for: "Acme Nexus")
        #expect(NotebookDefaultEmoji.fallback.contains(first))
        #expect(NotebookDefaultEmoji.emoji(for: "  acme   NEXUS ") == first, "case and spacing do not change it")
        #expect(NotebookDefaultEmoji.fallback.contains(NotebookDefaultEmoji.emoji(for: "")))
    }

    @Test("A notebook's card is drawn in the colour its id chooses, as the web draws it")
    func tints() throws {
        let vectors = try Self.vectors()
        #expect(NotebookTint.light.count == NotebookTint.dark.count)
        #expect(vectors.tints.count >= NotebookTint.light.count * 2)
        for vector in vectors.tints {
            #expect(NotebookTint.index(for: vector.id) == vector.tint, "\(vector.id)")
        }
        #expect(Set(vectors.tints.map(\.tint)).count == NotebookTint.light.count, "every colour is a vector")
    }

    @Test("A title's own leading emoji is its icon; without one the icon is the default")
    func titleIcon() {
        #expect(NotebookTitle("🧬 Mitochondria").displayIcon == "🧬")
        #expect(NotebookTitle("Mitochondria").icon == nil)
        #expect(NotebookTitle("Mitochondria").displayIcon == "🔋")
        #expect(NotebookTitle("Mitochondria").text == "Mitochondria")
        #expect(NotebookTitle("🎉 Mitochondria").displayIcon == "🎉", "typing an emoji first replaces the default")
    }
}
