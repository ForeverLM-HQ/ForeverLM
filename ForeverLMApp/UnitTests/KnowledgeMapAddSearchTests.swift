import Foundation
import Testing
@testable import ForeverLM

// Adding to the canvas (docs/knowledge-map-design.md, "Adding to the canvas"):
// what the canvas points at (Related), what a query finds (the add box and the
// find field) and the list those draw. The names are made up.

private enum Fixture {
    static func node(
        _ ref: String,
        _ kind: String,
        _ title: String,
        sub: String = "",
        src: String? = nil
    ) -> KnowledgeMapNode {
        KnowledgeMapNode(
            ref: ref,
            kind: kind,
            type: kind == "source" ? "paper" : kind,
            title: title,
            sub: sub,
            detail: [],
            shore: "Test",
            src: src
        )
    }

    static func idea(_ id: String, _ title: String, note: String? = nil) -> KnowledgeMapNode {
        node("idea:" + id, "idea", title, sub: note ?? KnowledgeMapAddSearch.noteLessIdeaLine)
    }

    static func source(_ id: String, _ title: String) -> KnowledgeMapNode { node("source:" + id, "source", title) }
    static func doc(_ id: String, _ title: String) -> KnowledgeMapNode { node("doc:" + id, "doc", title) }
    static func clip(_ id: String, _ title: String, paper: String) -> KnowledgeMapNode {
        node("clip:" + id, "clip", title, src: "source:" + paper)
    }
    static func page(_ source: String, _ number: Int) -> KnowledgeMapNode {
        node("page:\(source):\(number)", "page", "Page \(number)", src: "source:" + source)
    }

    static func link(_ a: String, _ b: String, _ kind: String) -> KnowledgeMapLink {
        KnowledgeMapLink(a: a, b: b, kind: kind)
    }
}

@Suite("Related: what a canvas points at")
struct KnowledgeMapRelatedTests {
    private typealias F = Fixture

    @Test("Anchors are the selected cards, else every placed card, and the paper of each")
    func anchors() {
        let content = KnowledgeMapContent(
            nodes: [
                F.source("p1", "Mitochondrial membrane potential"),
                F.clip("c1", "Figure 1", paper: "p1"),
                F.page("p1", 3),
                F.idea("i1", "Heteroplasmy drifts"),
                F.idea("i2", "An unrelated thought"),
            ],
            links: []
        )
        let placed: Set<String> = ["clip:c1", "idea:i1"]
        #expect(KnowledgeMapAddSearch.anchors(selection: [], placed: placed, content: content)
            == ["clip:c1", "idea:i1", "source:p1"], "nothing selected: everything placed, and the clip's paper")
        #expect(KnowledgeMapAddSearch.anchors(selection: ["idea:i1"], placed: placed, content: content)
            == ["idea:i1"], "an Idea has no paper, and the placed clip is not asked about")
        #expect(KnowledgeMapAddSearch.anchors(selection: ["page:p1:3"], placed: placed, content: content)
            == ["page:p1:3", "source:p1"], "a page's paper too")
        #expect(KnowledgeMapAddSearch.anchors(selection: [], placed: [], content: content).isEmpty, "an empty canvas points at nothing")
    }

    @Test("Each link kind has its weight, and the weights of one card sum over the anchors")
    func weightsAndSums() {
        let content = KnowledgeMapContent(
            nodes: [
                F.source("a", "Anchor paper"),
                F.source("b", "Another anchor paper"),
                F.idea("i", "A thought about both"),
                F.doc("d", "A review citing a"),
                F.source("chatted", "Discussed with a"),
                F.source("quiet", "Linked by something unknown"),
            ],
            links: [
                F.link("idea:i", "source:a", "idea"),
                F.link("idea:i", "source:b", "idea"),
                F.link("doc:d", "source:a", "doc"),
                F.link("source:a", "source:chatted", "chat"),
                F.link("source:a", "source:quiet", "mystery"),
            ]
        )
        let placed: Set<String> = ["source:a", "source:b"]
        let anchors = KnowledgeMapAddSearch.anchors(selection: [], placed: placed, content: content)
        // idea 3 + 3, doc 2, chat 1; a kind with no weight counts for nothing.
        #expect(KnowledgeMapAddSearch.related(anchors: anchors, content: content, placed: placed)
            == ["idea:i", "doc:d", "source:chatted"])
        // One anchor alone: the Idea counts once, 3.
        #expect(KnowledgeMapAddSearch.related(anchors: ["source:b"], content: content, placed: placed) == ["idea:i"])
        #expect(KnowledgeMapAddSearch.linkWeights == ["idea": 3, "clip": 3, "doc": 2, "chat": 1])
    }

    @Test("Placed cards, evidence under a placed Idea, pages and refs that are no card are left out")
    func exclusions() {
        let content = KnowledgeMapContent(
            nodes: [
                F.idea("home", "A placed thought"),
                F.source("evidence", "Its evidence"),
                F.source("bare", "A source nobody placed"),
                F.source("placedToo", "A source placed apart"),
                F.page("bare", 2),
                F.clip("c", "Figure 2", paper: "bare"),
            ],
            links: [
                F.link("idea:home", "source:evidence", "idea"),
                F.link("clip:c", "source:bare", "clip"),
                F.link("clip:c", "page:bare:2", "clip"),
                F.link("clip:c", "source:ghost", "chat"),
                F.link("idea:home", "source:placedToo", "idea"),
                F.link("clip:c", "source:evidence", "chat"),
            ]
        )
        let placed: Set<String> = ["idea:home", "clip:c", "source:placedToo"]
        let anchors = KnowledgeMapAddSearch.anchors(selection: [], placed: placed, content: content)
        let related = KnowledgeMapAddSearch.related(anchors: anchors, content: content, placed: placed)
        #expect(related == ["source:bare"], "the paper is near; the rest is placed, hanging, a page or no card")
        #expect(KnowledgeMapAddSearch.evidence(content: content, placed: placed) == ["source:evidence", "source:placedToo"])
    }

    @Test("A clip's paper brings the paper, its other clips, and the Ideas written about it")
    func paperBringsItsNeighbours() {
        let content = KnowledgeMapContent(
            nodes: [
                F.idea("about", "About the paper"),
                F.clip("one", "Figure 1", paper: "p"),
                F.clip("two", "Figure 2", paper: "p"),
                F.clip("three", "Figure 3", paper: "p"),
                F.source("p", "The paper"),
                F.doc("d", "A review of the paper"),
                F.idea("lonely", "Linked to nothing"),
            ],
            links: [
                F.link("clip:one", "source:p", "clip"),
                F.link("clip:two", "source:p", "clip"),
                F.link("clip:three", "source:p", "clip"),
                F.link("idea:about", "source:p", "idea"),
                F.link("doc:d", "source:p", "doc"),
            ]
        )
        let placed: Set<String> = ["clip:one"]
        let anchors = KnowledgeMapAddSearch.anchors(selection: [], placed: placed, content: content)
        // The paper is weighed by the placed clip (3); the Idea, the other clips and the
        // Doc by the paper (3, 3, 3, 2). An Idea linked to nothing is in no Related.
        #expect(KnowledgeMapAddSearch.related(anchors: anchors, content: content, placed: placed)
            == ["idea:about", "clip:two", "clip:three", "source:p", "doc:d"])
        #expect(!KnowledgeMapAddSearch.related(anchors: anchors, content: content, placed: placed).contains("idea:lonely"))
    }

    @Test("Order: weight, then kind, then Ideas oldest first and the rest in the cards' order")
    func order() {
        // The cards list Ideas newest first: i3 was written last.
        let content = KnowledgeMapContent(
            nodes: [
                F.node("chat:c", "chat", "A chat"),
                F.doc("d", "A doc"),
                F.source("s1", "First source"),
                F.source("s2", "Second source"),
                F.clip("k", "A clip", paper: "x"),
                F.idea("i3", "Newest idea"),
                F.idea("i2", "Middle idea"),
                F.idea("i1", "Oldest idea"),
                F.source("heavy", "Weighs more"),
                F.source("anchor", "The anchor"),
            ],
            links: [
                F.link("source:anchor", "chat:c", "chat"),
                F.link("source:anchor", "doc:d", "doc"),
                F.link("source:anchor", "source:s1", "doc"),
                F.link("source:anchor", "source:s2", "doc"),
                F.link("source:anchor", "clip:k", "doc"),
                F.link("source:anchor", "idea:i3", "doc"),
                F.link("source:anchor", "idea:i2", "doc"),
                F.link("source:anchor", "idea:i1", "doc"),
                F.link("source:heavy", "source:anchor", "idea"),
            ]
        )
        let related = KnowledgeMapAddSearch.related(anchors: ["source:anchor"], content: content, placed: ["source:anchor"])
        #expect(related == [
            "source:heavy",                           // 3
            "idea:i1", "idea:i2", "idea:i3",          // 2, Ideas first, oldest first
            "clip:k",                                 // 2, then clip
            "source:s1", "source:s2",                 // 2, sources in the cards' order
            "doc:d",                                  // 2, then Doc
            "chat:c",                                 // 1
        ])
    }

    @Test("At most the limit, 40 unless asked otherwise, and none for no anchors")
    func limit() {
        let sources = (0..<60).map { F.source("s\($0)", "Source \($0)") }
        let content = KnowledgeMapContent(
            nodes: [F.source("anchor", "Anchor")] + sources,
            links: sources.map { F.link("source:anchor", $0.ref, "doc") }
        )
        let placed: Set<String> = ["source:anchor"]
        let all = KnowledgeMapAddSearch.related(anchors: placed, content: content, placed: placed)
        #expect(all.count == 40)
        #expect(all.first == "source:s0" && all.last == "source:s39")
        #expect(KnowledgeMapAddSearch.related(anchors: placed, content: content, placed: placed, limit: 5).count == 5)
        #expect(KnowledgeMapAddSearch.related(anchors: [], content: content, placed: placed).isEmpty)
    }

    @Test("The newest unplaced Ideas, apart from the ones already shown")
    func recentIdeas() {
        let content = KnowledgeMapContent(
            nodes: (1...8).map { F.idea("i\($0)", "Idea \($0)") } + [F.source("s", "A source")],
            links: []
        )
        // The cards list Ideas newest first, so i1 is the newest.
        let recent = KnowledgeMapAddSearch.recentIdeas(content: content, placed: ["idea:i2"], excluding: ["idea:i3"])
        #expect(recent == ["idea:i1", "idea:i4", "idea:i5", "idea:i6", "idea:i7"])
    }
}

@Suite("Search: what a query finds")
struct KnowledgeMapSearchTests {
    private typealias F = Fixture

    private let content = KnowledgeMapContent(
        nodes: [
            F.source("1", "Calcium waves in heteroplasmy"),
            F.source("2", "Heteroplasmy and aging"),
            F.source("3", "On the nature of heteroplasmy"),
            F.doc("4", "Notes on mitochondria"),
            F.idea("5", "Is it drift?", note: "Heteroplasmy may only drift"),
            F.idea("6", "Plain thought"),
            F.page("1", 4),
            F.clip("7", "Heteroplasmy figure", paper: "1"),
        ],
        links: [KnowledgeMapLink(a: "idea:6", b: "source:3", kind: "idea")],
        notebooks: [
            KnowledgeMapNotebook(id: "n1", title: "Mitochondria and aging", summary: "", refs: ["source:1"]),
            KnowledgeMapNotebook(id: "n2", title: "Aging, the empty notebook", summary: "", refs: []),
            KnowledgeMapNotebook(id: "n3", title: "Heteroplasmy", summary: "", refs: ["source:2"]),
        ]
    )

    private func found(_ query: String, placed: Set<String> = []) -> KnowledgeMapAddSearch.Matches {
        let onPlane = placed.union(KnowledgeMapAddSearch.evidence(content: content, placed: placed))
        return KnowledgeMapAddSearch.matches(query, content: content, placed: placed, onPlane: onPlane)
    }

    @Test("A title that starts with the query ranks first, then a word that does, then the rest, each in the cards' order")
    func ranking() {
        #expect(found("heteroplasmy").library == [
            "source:2",   // starts with it
            "clip:7",     // starts with it, later in the cards
            "source:1",   // a word starts with it
            "source:3",
            "idea:5",     // only its note holds it
        ])
        #expect(found("aging heteroplasmy").library == ["source:2"], "every word, in any order")
        #expect(found("HETERO").library.first == "source:2", "lower-cased on both sides")
        #expect(found("het").library == found("heteroplasmy").library, "a word's start is enough")
        #expect(found("lasm").library.first == "source:1" && found("lasm").library.count == 5, "inside a word counts, last")
    }

    @Test("An Idea's note counts; the line an Idea without a note wears does not")
    func ideaNotes() {
        #expect(found("may only drift").library == ["idea:5"])
        #expect(found("idea").library.isEmpty, "no Idea is found by the word Idea alone")
        #expect(found("drift").library == ["idea:5"], "title and note")
    }

    @Test("Cards placed or hanging as evidence are on the canvas; the rest are the library's, never pages")
    func onCanvasAndLibrary() {
        // source:3 hangs under the placed Idea idea:6 as its evidence.
        let result = found("heteroplasmy", placed: ["source:1", "idea:6", "page:1:4"])
        #expect(result.onCanvas == ["source:1", "source:3"], "placed, and hanging as evidence")
        #expect(result.library == ["source:2", "clip:7", "idea:5"], "the rest, best first")
        #expect(found("nature", placed: ["idea:6"]).onCanvas == ["source:3"])
        #expect(found("nature", placed: ["idea:6"]).library.isEmpty)
        #expect(found("nature").library == ["source:3"])
        // A page is a card only once placed: found on the canvas, never offered from the library.
        #expect(found("page", placed: ["page:1:4"]).onCanvas == ["page:1:4"])
        #expect(found("page").library.isEmpty && found("page").onCanvas.isEmpty)
    }

    @Test("Notebooks are found by title, once they have cards to set down, in the same rank")
    func notebooks() {
        #expect(found("aging").notebookIDs == ["n1"], "the notebook with nothing to set down is not offered")
        #expect(found("heteroplasmy").notebookIDs == ["n3"])
        #expect(found("mito").notebookIDs == ["n1"])
        #expect(found("zebra").isEmpty)
    }

    @Test("Words outside ASCII are found and ranked as any other, a dash or a quote ending the word before")
    func nonASCII() {
        let accented = KnowledgeMapContent(
            nodes: [
                F.source("1", "Les évolutions de la cellule"),
                F.source("2", "Évolution des mitochondries"),
                F.source("3", "Naïve cells—and “zeta” waves"),
                F.source("4", "Understanding standards"),
            ],
            links: []
        )
        func found(_ query: String) -> [String] {
            KnowledgeMapAddSearch.matches(query, content: accented, placed: [], onPlane: []).library
        }
        #expect(found("évol") == ["source:2", "source:1"], "a title that starts with it, then a word that does")
        #expect(found("and") == ["source:3", "source:4"], "after an em dash is a word's start; inside a word is not")
        #expect(found("zeta") == ["source:3"], "after an opening quote is a word's start")
        #expect(found("naïve cells") == ["source:3"])
    }

    @Test("An index made for the cards gives what none does; one made for other cards is not trusted")
    func index() {
        let first = KnowledgeMapAddSearch.matches("heteroplasmy", content: content, placed: [], onPlane: [])
        let index = KnowledgeMapAddSearch.Index(content: content)
        #expect(KnowledgeMapAddSearch.matches("heteroplasmy", content: content, placed: [], onPlane: [], index: index) == first)
        let other = KnowledgeMapContent(nodes: [F.source("9", "Heteroplasmy elsewhere")], links: [])
        #expect(KnowledgeMapAddSearch.matches("heteroplasmy", content: other, placed: [], onPlane: [], index: index).library == ["source:9"])
    }

    @Test("An empty query finds nothing")
    func emptyQuery() {
        #expect(found("").isEmpty)
        #expect(found("   \n ").isEmpty)
    }
}

@Suite("The list the add box and the find field draw")
struct KnowledgeMapAddListingTests {
    private typealias F = Fixture

    /// An anchor paper with 12 sources it cites, 5 more Ideas and 3 written about it.
    private let content: KnowledgeMapContent = {
        let cited = (1...12).map { F.source("c\($0)", "Cited paper \($0)") }
        let ideas = (1...8).map { F.idea("i\($0)", "Idea \($0)") }
        let nodes = [F.source("anchor", "The anchor")] + cited + ideas
        var links = cited.map { F.link("source:anchor", $0.ref, "doc") }
        for id in ["i1", "i2", "i3"] { links.append(F.link("idea:" + id, "source:anchor", "idea")) }
        return KnowledgeMapContent(nodes: nodes, links: links)
    }()

    @Test("Nothing typed: the first 8 of Related, then up to 5 of the newest Ideas that are not in it")
    func emptyBox() {
        let listing = KnowledgeMapAddSearch.listing(query: "", mode: .box, content: content, placed: ["source:anchor"], selection: [])
        #expect(listing.sections.map(\.title) == ["Related", "Recent ideas"])
        let related = listing.sections[0].rows
        #expect(related.count == 8)
        // Weight 3 (the three Ideas, oldest first), then the cited papers at 2.
        #expect(related.prefix(3).map(\.id) == ["place:idea:i3", "place:idea:i2", "place:idea:i1"])
        let recent = listing.sections[1].rows.map(\.id)
        #expect(recent == ["place:idea:i4", "place:idea:i5", "place:idea:i6", "place:idea:i7", "place:idea:i8"])
        #expect(Set(related.map(\.id)).isDisjoint(with: recent))
        #expect(listing.rows.count == 13)
    }

    @Test("A selection narrows Related to what it points at")
    func selectionNarrows() {
        let narrowed = KnowledgeMapAddSearch.listing(
            query: " ",
            mode: .box,
            content: content,
            placed: ["source:anchor", "source:c1"],
            selection: ["source:c1"]
        )
        // c1 is linked only to the anchor (placed): nothing else to show but the newest Ideas.
        #expect(narrowed.sections.map(\.title) == ["Recent ideas"])
        #expect(narrowed.sections[0].rows.count == 5)
    }

    @Test("The find field offers nothing until something is typed")
    func emptyFind() {
        #expect(KnowledgeMapAddSearch.listing(query: "  ", mode: .find, content: content, placed: [], selection: []).rows.isEmpty)
    }

    @Test("Typing: the canvas at most 4, the library at most 12, notebooks at most 4, then New idea last")
    func typing() {
        var nodes: [KnowledgeMapNode] = (1...9).map { F.source("on\($0)", "Cell source \($0)") }
        nodes += (1...20).map { F.source("lib\($0)", "Cell library \($0)") }
        let notebooks = (1...6).map { KnowledgeMapNotebook(id: "n\($0)", title: "Cell notebook \($0)", summary: "", refs: ["source:on1"]) }
        let big = KnowledgeMapContent(nodes: nodes, links: [], notebooks: notebooks)
        let placed = Set((1...9).map { "source:on\($0)" })
        let listing = KnowledgeMapAddSearch.listing(query: " cell ", mode: .box, content: big, placed: placed, selection: [])
        #expect(listing.sections.map(\.title) == ["On this canvas", "From your library", "Notebooks", nil])
        #expect(listing.sections.map(\.rows.count) == [4, 12, 4, 1])
        #expect(listing.rows.last == .newIdea("cell"), "the words typed, trimmed")
        #expect(!listing.nothingMatched)
        #expect(!listing.rows.contains { if case .showAll = $0 { return true } else { return false } }, "no Show All in the box")
        #expect(listing.sections[0].rows.first == .show("source:on1"))
        #expect(listing.sections[1].rows.first == .place("source:lib1"))
        #expect(listing.sections[2].rows.first == .notebook("n1"))
    }

    @Test("Under the find field, more than one match on the canvas starts with Show All, up to 40")
    func showAll() {
        let sources = (1...50).map { F.source("s\($0)", "Tubulin \($0)") }
        let big = KnowledgeMapContent(nodes: sources, links: [])
        let placed = Set(sources.map(\.ref))
        let listing = KnowledgeMapAddSearch.listing(query: "tubulin", mode: .find, content: big, placed: placed, selection: [])
        guard case .showAll(let refs)? = listing.sections.first?.rows.first else {
            Issue.record("the first row is Show All")
            return
        }
        #expect(refs.count == 40 && refs.first == "source:s1")
        #expect(listing.sections[0].rows.count == 1 + 4)

        let one = KnowledgeMapAddSearch.listing(query: "tubulin 50", mode: .find, content: big, placed: placed, selection: [])
        #expect(one.sections[0].rows == [.show("source:s50")], "a single match is just that card")
    }

    @Test("With no match anywhere, the list says so and still offers New idea")
    func nothingMatched() {
        let listing = KnowledgeMapAddSearch.listing(query: "zebra", mode: .find, content: content, placed: [], selection: [])
        #expect(listing.nothingMatched)
        #expect(listing.rows == [.newIdea("zebra")])
        #expect(Set(listing.rows.map(\.id)).count == listing.rows.count)
    }
}

@Suite("The Library's choice")
struct KnowledgeMapLibraryChoiceTests {
    @Test("The Library is closed until opened, remembered on this Mac, and a new model reads it")
    @MainActor
    func libraryChoiceIsThisMacs() {
        let suite = UserDefaults(suiteName: "KnowledgeMapLibraryChoiceTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: "cnv-x")
            #expect(!model.showsLibrary)
            #expect(model.addBox == nil && model.findFocusRequests == 0)
            model.showsLibrary = true
            #expect(suite.bool(forKey: "knowledgeMap.library.v1"))
            #expect(KnowledgeMapModel(mapID: "cnv-y").showsLibrary)
            model.showsLibrary = false
            #expect(!suite.bool(forKey: "knowledgeMap.library.v1"))
        }
    }
}
