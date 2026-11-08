import Foundation
import Testing
@testable import ForeverLM

@Suite("Cards the learner writes")
struct WrittenCardTests {
    @Test("A sitting keeps the sources in order, once each, and walks them to the last")
    func sittingWalksTheSources() throws {
        #expect(CardWritingSession(sourceIDs: ["", "  "], notebookID: nil) == nil)
        var session = try #require(CardWritingSession(sourceIDs: ["a", " a ", "b", "", "c"], notebookID: "bio"))
        #expect(session.sourceIDs == ["a", "b", "c"])
        #expect(session.notebookID == "bio")
        #expect(session.sourceID == "a")
        #expect(session.progressLabel == "1 of 3")

        session.noteSaved()
        session.noteSaved()
        #expect(session.savedHere == 2)
        let movedToB = session.advance()
        #expect(movedToB)
        #expect(session.sourceID == "b")
        #expect(session.savedHere == 0, "each source counts its own cards")
        let movedToC = session.advance()
        #expect(movedToC)
        #expect(session.isLast)
        let movedPastLast = session.advance()
        #expect(!movedPastLast, "the last source stays")
        #expect(session.sourceID == "c")
        session.noteSaved()
        #expect(session.savedInAll == 3)

        let one = try #require(CardWritingSession(sourceIDs: ["a"], notebookID: nil))
        #expect(one.progressLabel == nil)
        #expect(one.isLast)
    }

    @Test("A card needs its question, its answer and its passage, asked for in that order")
    func cardNeedsEveryPart() {
        var input = WrittenCardInput()
        #expect(input.isEmpty)
        #expect(input.missing == .front)
        #expect(input.card() == nil)
        input.front = "  Why do frog embryos grow extra eyes?  "
        #expect(input.missing == .back)
        input.back = "Stomach cells given extra ion channels take on the eye's voltage pattern."
        #expect(input.missing == .passage)
        input.passage = "   "
        #expect(input.missing == .passage)
        input.passage = "extra ion channels reproduce the electric face pattern"
        #expect(input.missing == nil)

        let card = input.card(id: "written-1")
        #expect(card?.cardID == "written-1")
        #expect(card?.front == "Why do frog embryos grow extra eyes?", "trimmed")
        #expect(card?.origin == .manual)
        #expect(card?.deckID == nil, "no draft deck: it was never a draft")
        #expect(MemoryCardOrigin.manual.rawValue == "manual", "Card.origin's wire word")
    }

    @Test("A Reader selection becomes the passage on one line; a selection of no words is none")
    func selectionBecomesThePassage() {
        #expect(WrittenCardInput.passage(fromSelection: "  extra ion\nchannels \t reproduce  ") == "extra ion channels reproduce")
        #expect(WrittenCardInput.passage(fromSelection: " \n ") == nil)
    }

    @Test("A written card is kept at once on the passage it stands on, and goes out as Card origin manual")
    func writtenCardIsKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WrittenCard_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        var source = StudioArticle(url: "https://example.org/talk", title: "Bioelectric Eyes", sourceType: .article, discoveryOrigin: .manual, id: "talk")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = "In Zara Holt's lab, stomach cells given extra ion channels reproduce the electric face pattern, and eyes grow there."
        source.state = .ready
        try await storage.saveSource(source)

        let input = WrittenCardInput(
            front: "What makes stomach cells grow an eye?",
            back: "Extra ion channels give them the eye's voltage pattern.",
            passage: try #require(WrittenCardInput.passage(fromSelection: "extra ion channels\nreproduce the electric face pattern"))
        )
        let card = try #require(input.card())
        let item = try await storage.keepMemoryCard(card, sourceID: "talk", quote: input.passage)
        #expect(item.sources.map(\.sourceID) == ["talk"])
        #expect(item.target == "Extra ion channels give them the eye's voltage pattern.")
        #expect(MemoryCard(storedIn: item)?.origin == .manual)
        #expect(CardProjection.origin(of: item, seedKey: nil) == "manual")

        await #expect(throws: (any Error).self, "a passage the source does not print keeps nothing") {
            _ = try await storage.validatedMemorySourceAnchor(sourceID: "talk", excerpt: "a sentence the talk never says")
        }
    }
}
