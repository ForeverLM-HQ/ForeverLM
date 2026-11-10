import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The Ideas tab's storage (docs/ideas-design.md): what a jotted thought keeps,
/// what a link may point at, and what survives a store from before schema 126.
@Suite("Idea persistence")
struct IdeaPersistenceTests {

    /// A source the store accepts, so a link has something real to name.
    @discardableResult
    private func seedSource(_ store: KnowledgeStore, id: String, title: String) throws -> StudioArticle {
        var article = StudioArticle(
            url: "https://example.com/\(id)", title: title, sourceType: .article,
            discoveryOrigin: .manual, id: id
        )
        article.domain = "example.com"
        article.normalizedURL = URLNormalizer.normalize(article.url)
        article.content = "Readable text this library holds for the test."
        article.wordCount = 8
        article.state = .ready
        try store.saveSource(article)
        return article
    }

    @Test("An Idea keeps the words as written and reads newest first")
    func ideaKeepsItsWords() throws {
        let store = try KnowledgeStore(inMemory: true)
        let first = try store.createIdea(title: "  Magnetogenetics might explain the\n  sleep pressure result  ")
        #expect(first.title == "Magnetogenetics might explain the sleep pressure result", "collapsed to one line, trimmed")
        #expect(first.notes == nil)
        #expect(first.status == .open)

        let second = try store.createIdea(title: "MMP as a cheap proxy", notes: "  ")
        #expect(second.notes == nil, "a blank note is no note")

        let listed = try store.loadIdeas()
        #expect(listed.map(\.id) == [second.id, first.id], "newest first")

        let withNote = try store.updateIdea(first.id, notes: "The pressure curve looks like a field effect.")
        #expect(withNote.notes == "The pressure curve looks like a field effect.")
        #expect(withNote.title == first.title, "a note does not touch the words")
        #expect(withNote.updatedAt >= first.updatedAt)

        let cleared = try store.updateIdea(first.id, notes: "")
        #expect(cleared.notes == nil, "an emptied note is stored as none")
    }

    @Test("An archived Idea stays readable and comes back")
    func archivingKeepsTheIdea() throws {
        let store = try KnowledgeStore(inMemory: true)
        let idea = try store.createIdea(title: "Ideas as a corollary to goals")

        let archived = try store.setIdeaStatus(idea.id, status: .archived)
        #expect(archived.isArchived)
        #expect(try store.loadIdeas(includeArchived: false).isEmpty, "the open list leaves it out")
        #expect(try store.loadIdeas().map(\.id) == [idea.id], "the full list still has it")

        let reopened = try store.setIdeaStatus(idea.id, status: .open)
        #expect(reopened.isOpen)
        #expect(try store.loadIdeas(includeArchived: false).map(\.id) == [idea.id])
    }

    @Test("A link may only name a record this library holds")
    func linksAreCheckedAgainstTheLibrary() throws {
        let store = try KnowledgeStore(inMemory: true)
        try seedSource(store, id: "source-a", title: "The pressure to sleep")
        let goal = try store.createCompanionGoal(
            title: "Write the magnetogenetics piece", topic: "magnetogenetics",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let idea = try store.createIdea(title: "Field effects on sleep pressure")

        let linked = try store.linkIdea(idea.id, kind: .source, targetIDs: ["source-a"])
        #expect(linked.added == 1)
        #expect(linked.idea.linkedIDs(.source) == ["source-a"])

        let again = try store.linkIdea(idea.id, kind: .source, targetIDs: ["source-a"])
        #expect(again.added == 0, "the same link twice adds nothing")
        #expect(again.idea.links.count == 1)

        let toGoal = try store.linkIdea(idea.id, kind: .goal, targetIDs: [goal.id])
        #expect(toGoal.added == 1)
        #expect(toGoal.idea.linkedIDs(.goal) == [goal.id])

        #expect(throws: KnowledgeStoreError.self, "an id no record holds is refused") {
            try store.linkIdea(idea.id, kind: .source, targetIDs: ["not-a-source"])
        }
        #expect(throws: KnowledgeStoreError.self, "a Goal id under the source kind is refused") {
            try store.linkIdea(idea.id, kind: .source, targetIDs: [goal.id])
        }
        let after = try #require(try store.loadIdea(idea.id))
        #expect(after.links.count == 2, "a refused link writes nothing")

        let unlinked = try store.unlinkIdea(idea.id, kind: .source, targetIDs: ["source-a"])
        #expect(unlinked.removed == 1)
        #expect(unlinked.idea.linkedIDs(.source).isEmpty)
        #expect(unlinked.idea.linkedIDs(.goal) == [goal.id], "the other kind is untouched")
    }

    @Test("Deleting an Idea leaves everything it linked to")
    func deletingAnIdeaKeepsItsTargets() throws {
        let store = try KnowledgeStore(inMemory: true)
        try seedSource(store, id: "source-b", title: "Membrane potential as a proxy")
        let idea = try store.createIdea(
            title: "MMP is the cheapest readout we have",
            links: [IdeaLink(kind: .source, targetID: "source-b")]
        )
        #expect(idea.links.count == 1)

        try store.deleteIdea(idea.id)
        #expect(try store.loadIdea(idea.id) == nil)
        #expect(try store.hasIdea(idea.id) == false)
        #expect(try store.sourceExists("source-b"), "the source it named stays in the library")
        #expect(throws: KnowledgeStoreError.self, "deleting it twice is refused") {
            try store.deleteIdea(idea.id)
        }
    }

    @Test("A record from a newer build keeps what this build understands")
    func unknownLinkKindIsDropped() throws {
        let json = """
        {
          "id": "idea-1",
          "title": "From a later build",
          "status": "wondering",
          "links": [
            {"kind": "source", "targetID": "source-a", "addedAt": 780000000},
            {"kind": "sculpture", "targetID": "whatever", "addedAt": 780000000}
          ],
          "createdAt": 780000000,
          "updatedAt": 780000000
        }
        """
        let decoder = JSONDecoder()
        let idea = try decoder.decode(IdeaRecord.self, from: Data(json.utf8))
        #expect(idea.status == .open, "an unknown status reads as open")
        #expect(idea.links.map(\.targetID) == ["source-a"], "a kind this build lacks is dropped, the record survives")
    }
}
