import Foundation
import Testing
@testable import ForeverLM

// Summarize into an Idea and Break Down This Source (docs/knowledge-map-design.md,
// "Ask the Canvas"): what the model's answer is kept as, and what keeping it
// writes. The older three asks are in CanvasAskTests.

private func newToolItem(_ ref: String, _ kind: KnowledgeMap.ItemKind = .source, title: String? = nil, placed: Bool = true) -> CanvasAskService.Snapshot.Item {
    CanvasAskService.Snapshot.Item(
        ref: ref,
        kind: kind,
        title: title ?? "Title of \(ref)",
        byline: "",
        type: kind == .idea ? "idea" : "paper",
        placed: placed,
        region: nil,
        note: nil
    )
}

private func newToolCard(_ id: String, _ ref: String, _ kind: KnowledgeMap.ItemKind = .source, title: String? = nil, placed: Bool = true) -> CanvasAskService.Card {
    CanvasAskService.Card(id: id, item: newToolItem(ref, kind, title: title, placed: placed))
}

@Suite("Ask the Canvas: Summarize and Break Down, reading the answer")
struct CanvasAskNewToolsParseTests {
    static let summarizeContext = CanvasAskService.Context(
        tool: .summarize,
        cards: [newToolCard("c1", "source:a"), newToolCard("c2", "idea:i", .idea), newToolCard("c3", "source:u", placed: false)],
        passages: [.init(id: "p1", ref: "source:a", text: "TMRM reads membrane potential.")]
    )

    @Test("A Summarize is one question proposal: a title of at most 120 characters, a note of at most five sentences, near the asked cards on the canvas")
    func summarize() throws {
        let title = String(repeating: "word ", count: 40)
        let note = "One sentence. Two sentences here. Three. Four. Five. Six goes. Seven goes."
        let response = #"{"proposals": [{"title": "\#(title)", "note": "\#(note)", "cites": ["p1", "p9"]}]}"#
        let answers = try CanvasAskService.answers(from: response, context: Self.summarizeContext)
        let answer = try #require(answers.first)
        #expect(answers.count == 1)
        #expect(answer.proposal.kind == .question)
        let text = try #require(answer.proposal.text)
        #expect(text.count <= CanvasAskService.summaryTitleCharacters && text.hasSuffix("…"), "cut at a word and marked")
        #expect(answer.proposal.note == "One sentence. Two sentences here. Three. Four. Five.")
        #expect(answer.proposal.why == "One sentence.", "the ghost shows the note's first sentence")
        #expect(answer.proposal.near == ["source:a", "idea:i"], "only cards that are on the canvas")
        #expect(answer.cites == ["p1"], "a passage it was not given is dropped")
    }

    @Test("The one Idea may come bare, an entry with no title is skipped, and nothing usable is no proposal")
    func summarizeShapes() throws {
        let bare = try CanvasAskService.answers(from: #"{"title": "A claim", "note": "It holds."}"#, context: Self.summarizeContext)
        #expect(bare.map(\.proposal.text) == ["A claim"])
        let skipped = try CanvasAskService.answers(
            from: #"{"proposals": [{"note": "no title"}, {"title": "   "}, {"title": "Second", "note": "y"}, {"title": "Third"}]}"#,
            context: Self.summarizeContext
        )
        #expect(skipped.map(\.proposal.text) == ["Second"], "one proposal, the first usable")
        let titleOnly = try CanvasAskService.answers(from: #"{"proposals": [{"title": "Just this"}]}"#, context: Self.summarizeContext)
        #expect(titleOnly.first?.proposal.note == nil && titleOnly.first?.proposal.why == nil)
        #expect(try CanvasAskService.answers(from: #"{"proposals": []}"#, context: Self.summarizeContext).isEmpty)
        #expect(throws: CanvasAskService.ParseError.self) {
            try CanvasAskService.answers(from: "not json", context: Self.summarizeContext)
        }
    }

    static let breakContext = CanvasAskService.Context(
        tool: .breakDown,
        cards: [newToolCard("c1", "source:a", title: "PINK1 senses membrane potential and recruits Parkin to damaged mitochondria: a review of the pathway in full detail")],
        passages: [
            .init(id: "p1", ref: "source:a", text: "PINK1 builds up on depolarised mitochondria."),
            .init(id: "p2", ref: "source:a", text: "Parkin ubiquitinates outer membrane proteins."),
        ]
    )

    @Test("A Break Down is the concepts as question proposals with their notes, and a plan: a region named for the source and the arrows among them")
    func breakDown() throws {
        let concepts = (1...14).map { #"{"id": "k\#($0)", "title": "Concept \#($0).", "note": "Note number \#($0).", "cites": ["p1", "p7"]}"# }
        let response = """
        {"concepts": [\(concepts.joined(separator: ", ")),
          {"id": "k2", "title": "Same id again"}, {"id": "k99", "title": "concept 3"}, {"id": "", "title": "No id"}],
         "arrows": [
          {"from": "k1", "to": "k2", "label": "recruits"},
          {"from": "k1", "to": "k1", "label": "itself"},
          {"from": "k2", "to": "k1", "label": "the same pair reversed"},
          {"from": "k3", "to": "k77", "label": "unknown end"},
          {"from": "k3", "to": "k4", "label": ""},
          {"from": "K3", "to": "k5", "label": "“is measured by the slow assay”."}
         ]}
        """
        let parsed = try CanvasAskService.parsed(from: response, context: Self.breakContext)
        #expect(parsed.answers.count == CanvasAskService.maximumConcepts)
        #expect(parsed.answers.map(\.proposal.id) == (1...12).map { "p:k\($0)" })
        let first = try #require(parsed.answers.first)
        #expect(first.proposal.kind == .question && first.proposal.text == "Concept 1", "a trailing full stop is not part of a title")
        #expect(first.proposal.note == "Note number 1." && first.proposal.why == "Note number 1.")
        #expect(first.proposal.near == ["source:a"])
        #expect(first.cites == ["p1"])
        let plan = try #require(parsed.plan)
        #expect(plan.sourceRef == "source:a")
        #expect(plan.regionName.count <= 81 && plan.regionName.hasPrefix("PINK1 senses membrane potential"), "named for the source")
        #expect(plan.arrows == [
            .init(from: "p:k1", to: "p:k2", label: "recruits"),
            .init(from: "p:k3", to: "p:k5", label: "is measured by the"),
        ])
    }

    @Test("Fewer than two concepts, a card that is not a source, or an unreadable answer is no breakdown")
    func breakDownNothing() throws {
        let one = try CanvasAskService.parsed(from: #"{"concepts": [{"id": "k1", "title": "Only one"}]}"#, context: Self.breakContext)
        #expect(one.answers.isEmpty && one.plan == nil)
        let idea = CanvasAskService.Context(tool: .breakDown, cards: [newToolCard("c1", "idea:i", .idea)], passages: [])
        let notSource = try CanvasAskService.parsed(from: #"{"concepts": [{"id": "k1", "title": "A"}, {"id": "k2", "title": "B"}]}"#, context: idea)
        #expect(notSource.answers.isEmpty && notSource.plan == nil)
        #expect(throws: CanvasAskService.ParseError.self) {
            try CanvasAskService.parsed(from: "[]", context: Self.breakContext)
        }
    }

    @Test("A source is read as passages spread from its start to its end, in order, never more than asked for")
    func spreadPassages() {
        let content = (0..<40_000).map { "w\($0)" }.joined(separator: " ")
        let passages = CanvasAskService.spreadPassages(from: content)
        #expect(passages.count == CanvasAskService.breakDownPassageCount)
        #expect(passages.allSatisfy { $0.count <= CanvasAskService.breakDownPassageCharacters + 2 })
        #expect(passages.first?.hasPrefix("w0 ") == true)
        let starts = passages.compactMap { passage -> Int? in
            guard let word = passage.split(separator: " ").first(where: { $0.hasPrefix("w") }) else { return nil }
            return Int(word.dropFirst())
        }
        #expect(starts.count == passages.count && starts == starts.sorted() && Set(starts).count == starts.count)
        #expect((starts.last ?? 0) > 30_000, "the last passage is from the end")
        #expect(CanvasAskService.spreadPassages(from: "").isEmpty)
        #expect(CanvasAskService.spreadPassages(from: "a short source").count == 1)
    }

    @Test("Cutting at a word and at a sentence")
    func cutting() {
        #expect(CanvasAskService.cut("one two three four", characters: 12) == "one two…")
        #expect(CanvasAskService.cut("short", characters: 12) == "short")
        #expect(CanvasAskService.cut(nil, characters: 12).isEmpty)
        #expect(CanvasAskService.sentences("A. B. C. D.", max: 2, characters: 100) == "A. B.")
        #expect(CanvasAskService.sentences("  ", max: 2, characters: 100).isEmpty)
    }
}

@Suite("Ask the Canvas: Summarize and Break Down, keeping and refusing")
@MainActor
struct CanvasAskNewToolsKeepTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "CanvasAskNewToolsKeepTests.\(UUID().uuidString)")!
    }

    private func set(_ tool: CanvasAskTool, _ proposals: [KnowledgeMapProposal], plan: KnowledgeMapBreakDownPlan? = nil) -> KnowledgeMapProposalSet {
        KnowledgeMapProposalSet(id: "set", tool: tool, title: tool.title, anchor: [], proposals: proposals, createdAt: Date(), plan: plan)
    }

    @Test("A kept Summarize writes its Idea with its note where the ghost was, and the asks have titles for the menu")
    func keepSummary() async {
        await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            var written: [String] = []
            model.showProposals(
                set(.summarize, [KnowledgeMapProposal(id: "q1", kind: .question, text: "ΔΨm decides it", note: "Three sources agree. One does not.")]),
                makeIdea: nil,
                writeIdea: { text, note, spot in
                    written.append("\(text)|\(note ?? "-")|\(spot.map { "\($0.x),\($0.y)" } ?? "unplaced")")
                    model.place([(ref: "idea:new", x: spot?.x ?? 0, y: spot?.y ?? 0)])
                    return "idea:new"
                }
            )
            model.receiveProposalMessage("proposalKeep", ["id": "q1", "x": 40, "y": 60])
            await model.askState.ideaWrites?.value
            #expect(written == ["ΔΨm decides it|Three sources agree. One does not.|40.0,60.0"])
            #expect(model.selection == ["idea:new"])
            #expect(CanvasAskTool.summarize.menuTitle == "Summarize into an Idea")
            #expect(CanvasAskTool.breakDown.menuTitle == "Break Down This Source")
            #expect(CanvasAskTool.overMCP == [.bridge, .connect, .gaps], "an assistant summarizes and breaks down itself")
        }
    }

    @Test("Keep All on a Break Down writes every concept unplaced, then sets them down as one block in a region named for the source with the arrows drawn")
    func keepBreakDown() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "source:a", x: 0, y: 0)])
            var written = 0
            var spots: [Bool] = []
            let proposals = (1...6).map { KnowledgeMapProposal(id: "p:k\($0)", kind: .question, text: "Concept \($0)", near: ["source:a"], note: "Note \($0).") }
            let plan = KnowledgeMapBreakDownPlan(sourceRef: "source:a", regionName: "A paper", arrows: [
                .init(from: "p:k1", to: "p:k2", label: "recruits"),
                .init(from: "p:k2", to: "p:k9", label: "to nowhere"),
            ])
            model.showProposals(set(.breakDown, proposals, plan: plan), makeIdea: nil, writeIdea: { _, _, spot in
                written += 1
                spots.append(spot == nil)
                return "idea:c\(written)"
            })
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect(written == 6 && spots.allSatisfy { $0 }, "written unplaced: the block places them")
            let ideas = model.layout.placements.keys.filter { $0.hasPrefix("idea:") }.sorted()
            #expect(ideas == (1...6).map { "idea:c\($0)" })
            let region = try #require(model.layout.regions.values.first)
            #expect(model.layout.regions.count == 1 && region.name == "A paper")
            for ref in ideas {
                let spot = try #require(model.layout.placements[ref])
                #expect(spot.x >= region.x && spot.x + KnowledgeMap.cardWidth <= region.x + region.w)
                #expect(spot.y >= region.y && spot.y + KnowledgeMap.cardHeight <= region.y + region.h)
            }
            #expect(spot(of: model, "source:a") == [0, 0], "the source stays where it is")
            #expect(model.layout.edges.values.map(\.label) == ["recruits"], "an arrow to a concept that is not there is not drawn")
            #expect(Set(model.selection) == Set(ideas))
            #expect(model.proposals == nil)
        }
    }

    private func spot(of model: KnowledgeMapModel, _ ref: String) -> [Double]? {
        model.layout.placements[ref].map { [$0.x, $0.y] }
    }

    @Test("A Break Down takes one source; a Summarize takes any card")
    func refusals() throws {
        let suite = suite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasAskNewTools_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
            let paper = { (id: String) in StudioArticle(url: "https://example.com/\(id)", title: "Paper \(id)", sourceType: .paper, id: id) }
            vm.knowledgeMap.rebuildContent(articles: [paper("a"), paper("b")], ideas: [IdeaRecord(id: "i", title: "An idea")], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            #expect(throws: StudioViewModel.CanvasAskRefusal.needsOneSource) {
                try vm.canvasAskSnapshot(.breakDown, refs: ["source:a", "source:b"])
            }
            #expect(throws: StudioViewModel.CanvasAskRefusal.needsOneSource) {
                try vm.canvasAskSnapshot(.breakDown, refs: ["idea:i"])
            }
            let oneSource = try vm.canvasAskSnapshot(.breakDown, refs: ["source:a"])
            #expect(oneSource.items.map(\.ref) == ["source:a"])
            let oneIdea = try vm.canvasAskSnapshot(.summarize, refs: ["idea:i"])
            #expect(oneIdea.items.map(\.ref) == ["idea:i"])
            let three = try vm.canvasAskSnapshot(.summarize, refs: ["source:a", "source:b", "idea:i"])
            #expect(three.items.count == 3)
            #expect(throws: (any Error).self) {
                try MCPDataStore.canvasAskRequest(from: ["tool": "summarize", "item_ids": ["source:a"]])
            }
            let gaps = try MCPDataStore.canvasAskRequest(from: ["tool": "gaps", "item_ids": ["source:a"]])
            #expect(gaps.tool == .gaps)
        }
    }
}
