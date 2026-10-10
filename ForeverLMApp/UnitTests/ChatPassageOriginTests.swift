import Foundation
import Testing
@testable import ForeverLM

/// The passage a chat was opened on, read back off the message that carried
/// it, so the chat can show the highlighted words and open the Reader on them.
@Suite("Chat passage origin")
struct ChatPassageOriginTests {

    @Test("A reader selection's block names its source, and reads back whole")
    func readerSelectionRoundTrips() {
        let request = ReaderSelectionExplanationRequest(
            sourceID: "src-1",
            selectedText: "So are these DNA encoded libraries and the way they work is you have a small molecule"
        )
        let stored = request.contextualContent(fallbackTitle: "Writings - The Missing Dimension in Pooled Screens")
        #expect(stored.contains("\n\nSource ID: src-1"))

        let passage = ChatPassageOrigin.parse(contextContent: stored)
        #expect(passage == ChatPassageOrigin.Passage(
            quote: "So are these DNA encoded libraries and the way they work is you have a small molecule",
            sourceID: "src-1",
            contextTitle: "Writings - The Missing Dimension in Pooled Screens"
        ))
    }

    @Test("A multi-line selection keeps its lines and loses the quote dressing")
    func multiLineQuote() {
        let stored = "Selected passage:\n> first line\n>\n> third line\n\nContext: A paper"
        let passage = ChatPassageOrigin.parse(contextContent: stored)
        #expect(passage?.quote == "first line\n\nthird line")
        #expect(passage?.sourceID == nil)
        #expect(passage?.contextTitle == "A paper")
    }

    @Test("A block from before the source line names no source, but still reads")
    func legacyBlockWithoutSource() {
        let stored = "Selected passage:\n> SS31 / elamipretide\n\nContext: Mitochondrial phenotyping"
        let passage = ChatPassageOrigin.parse(contextContent: stored)
        #expect(passage?.quote == "SS31 / elamipretide")
        #expect(passage?.sourceID == nil)
        #expect(passage?.contextTitle == "Mitochondrial phenotyping")
    }

    @Test("A doc's passage is not a source passage")
    func docPassageIsSkipped() {
        let stored = "Selected passage:\n> SS31 / elamipretide\n\nArticle ID: mito-doc"
        #expect(ChatPassageOrigin.parse(contextContent: stored) == nil)
    }

    @Test("The block is found under the marks that may sit above it")
    func readsUnderMarks() {
        let reference = ReaderSelectionExplanationRequest(sourceID: "src-9", selectedText: "quoted words")
            .contextualContent(fallbackTitle: "Title")
        let withAdditions = ChatContextAdditions.contextContent(
            added: [ChatContextAdditions.Source(id: "a1", title: "Added", type: "article")],
            referenceContext: reference
        )
        #expect(ChatPassageOrigin.parse(contextContent: withAdditions)?.sourceID == "src-9")

        let asSideQuestion = ChatSideQuestion.contextContent(openQuestion: "Why?", referenceContext: reference)
        #expect(ChatPassageOrigin.parse(contextContent: asSideQuestion)?.quote == "quoted words")
    }

    @Test("Nothing quoted, or reference material of another shape, is no passage")
    func otherContextsAreNotPassages() {
        #expect(ChatPassageOrigin.parse(contextContent: nil) == nil)
        #expect(ChatPassageOrigin.parse(contextContent: "") == nil)
        #expect(ChatPassageOrigin.parse(contextContent: "Selected passage:\n\nContext: nothing quoted") == nil)
        #expect(ChatPassageOrigin.parse(contextContent: "> a bare quote with no heading") == nil)
        #expect(ChatPassageOrigin.parse(contextContent: ChatSideQuestion.contextContent(openQuestion: "Why?")) == nil)
    }

    @Test("Only a single source gets the source line")
    func sourceLineNeedsOneSource() {
        #expect(ChatPassageOrigin.sourceIDLine(for: ["a"]) == "Source ID: a")
        #expect(ChatPassageOrigin.sourceIDLine(for: ["a", "b"]) == nil)
        #expect(ChatPassageOrigin.sourceIDLine(for: []) == nil)
        #expect(ChatPassageOrigin.sourceIDLine(for: [" "]) == nil)
    }

    @Test("A doc passage's block does not gain a source line")
    func docBlockUnchanged() {
        let request = ReaderSelectionExplanationRequest(
            sourceIDs: ["s1"],
            selectedText: "words",
            contextTitle: "Note: Plan",
            artifactID: "doc-1",
            artifactRevision: "r1"
        )
        let stored = request.contextualContent()
        #expect(stored.contains("Article ID: doc-1"))
        #expect(!stored.contains("Source ID:"))
    }
}
