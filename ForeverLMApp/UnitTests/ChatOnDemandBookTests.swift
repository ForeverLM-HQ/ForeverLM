// A book dropped into a chat joins on demand: its chapters are in the
// catalog and the "in context" count, and none of their text is pasted in.

import Testing
import Foundation
@testable import ForeverLM

@Suite("A dropped book joins a chat on demand")
struct ChatOnDemandBookTests {

    private func chapter(_ n: Int) -> StudioArticle {
        StudioArticle(url: "file:///books/sample/\(n).pdf", title: "Chapter \(n)", sourceType: .book)
    }

    @Test("a whole book's chapters join on demand")
    func wholeBookIsOnDemand() {
        let chapters = (1...14).map(chapter)
        #expect(ReviewSessionManager.onDemandDrop(chapters) == Set(chapters.map(\.id)))
    }

    @Test("one chapter alone, an article, or a paper is read in")
    func singleSourcesAreReadIn() {
        let article = StudioArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        let paper = StudioArticle(url: "https://example.com/paper", title: "A Paper", sourceType: .paper)
        #expect(ReviewSessionManager.onDemandDrop([chapter(1)]).isEmpty)
        #expect(ReviewSessionManager.onDemandDrop([chapter(1), article, paper]).isEmpty)
    }

    @Test("beside an article, the book's chapters stay on demand and the article does not")
    func mixedDrop() {
        let article = StudioArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        let chapters = [chapter(1), chapter(2)]
        #expect(ReviewSessionManager.onDemandDrop(chapters + [article]) == Set(chapters.map(\.id)))
    }

    @Test("a reopened chat reads its added, still attached, unloaded sources on demand")
    func resumeReadsMarks() {
        let added = [
            ChatContextAdditions.Source(id: "ch-1", title: "Chapter 1", type: "book"),
            ChatContextAdditions.Source(id: "ch-2", title: "Chapter 2", type: "book"),
            ChatContextAdditions.Source(id: "ch-3", title: "Chapter 3", type: "book"),
        ]
        let exchange = ReviewExchangeRecord(
            id: "ex-1",
            sessionID: "chat-1",
            sequenceNumber: 1,
            question: "What is the proton-motive force?",
            userAnswer: nil,
            evaluation: nil,
            score: nil,
            sourceRefs: [],
            knowledgeNote: nil,
            answeredAt: Date(),
            contextContent: ChatContextAdditions.contextContent(added: added, referenceContext: nil),
            ideaCoverage: nil
        )
        let onDemand = ReviewSessionManager.onDemandSourceIDsOnResume(
            attached: ["ch-1", "ch-2", "paper-1"],
            loaded: ["ch-2"],
            exchanges: [exchange]
        )
        // ch-2 is held in full; ch-3 was removed since.
        #expect(onDemand == ["ch-1"])
    }

    @Test("a readable source the text budget has no room for joins on demand")
    func overflowJoinsOnDemand() {
        let overflow = ReviewSessionManager.onDemandOverflow(
            dropped: ["paper-1", "paper-2", "empty-1", "ch-1"],
            readable: ["paper-1", "paper-2", "ch-1"],
            readIn: ["paper-1"],
            alreadyOnDemand: ["ch-1"]
        )
        // paper-1 was read in, ch-1 is already on demand, empty-1 has no text.
        #expect(overflow == ["paper-2"])
    }
}
