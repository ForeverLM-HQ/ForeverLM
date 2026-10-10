import Foundation
import Testing
@testable import ForeverLM

// Ask the Canvas and written faces (docs/sensemaking-design.md): what the
// model's answers are kept as, what keeping and dismissing write, what the
// next ask is told, and when a source's faces are written again.

private func paper(_ id: String, _ title: String? = nil) -> StudioArticle {
    StudioArticle(url: "https://example.com/\(id)", title: title ?? "Paper \(id)", sourceType: .paper, id: id)
}

private func askItem(
    _ ref: String,
    _ kind: KnowledgeMap.ItemKind = .source,
    title: String? = nil,
    placed: Bool = true,
    region: String? = nil
) -> CanvasAskService.Snapshot.Item {
    CanvasAskService.Snapshot.Item(
        ref: ref,
        kind: kind,
        title: title ?? "Title of \(ref)",
        byline: "",
        type: kind == .idea ? "idea" : "paper",
        placed: placed,
        region: region,
        note: nil
    )
}

private func askCard(_ id: String, _ ref: String, _ kind: KnowledgeMap.ItemKind = .source, placed: Bool = true) -> CanvasAskService.Card {
    CanvasAskService.Card(id: id, item: askItem(ref, kind, placed: placed))
}

private func proposalSet(_ tool: CanvasAskTool, _ proposals: [KnowledgeMapProposal], anchor: [String] = []) -> KnowledgeMapProposalSet {
    KnowledgeMapProposalSet(id: "set", tool: tool, title: tool.title, anchor: anchor, proposals: proposals, createdAt: Date())
}

private func spot(_ placement: KnowledgeMapLayout.Placement?) -> [Double]? {
    placement.map { [$0.x, $0.y] }
}

@Suite("Ask the Canvas: reading the answer")
struct CanvasAskAnswerTests {
    static let bridgeContext = CanvasAskService.Context(
        tool: .bridge,
        cards: [askCard("c1", "source:a"), askCard("c2", "idea:i", .idea)],
        passages: [
            .init(id: "p1", ref: "source:a", text: "TMRM reads membrane potential."),
            .init(id: "p2", ref: "source:x", text: "PINK1 builds up on depolarised mitochondria."),
        ],
        candidates: ["x", "y", "a", "d", "e", "f", "g"].enumerated().map { index, id in
            CanvasAskService.Candidate(id: "s\(index + 1)", sourceID: id, title: "Paper \(id)", byline: "", type: "paper", onCanvas: false, passageID: nil)
        }
    )

    @Test("A Bridge keeps only candidates it was given, never an asked source or one twice, at most five, why cut at a word")
    func bridge() throws {
        let response = """
        ```json
        {"proposals": [
          {"candidate": "s1", "why": "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen", "near": ["c1", "c2", "c9"], "cites": ["p2", "p99"]},
          {"candidate": "S2", "why": "short", "near": "c1"},
          {"candidate": "s3", "why": "the asked source itself"},
          {"candidate": "s1", "why": "again"},
          {"candidate": "s42", "why": "not given"},
          {"candidate": "s4"}, {"candidate": "s5"}, {"candidate": "s6"}, {"candidate": "s7"}
        ]}
        ```
        """
        let answers = try CanvasAskService.answers(from: response, context: Self.bridgeContext)
        #expect(answers.map(\.proposal.ref) == ["source:x", "source:y", "source:d", "source:e", "source:f"])
        #expect(answers.allSatisfy { $0.proposal.kind == .source })
        let first = try #require(answers.first)
        #expect(first.proposal.why == "one two three four five six seven eight nine ten eleven twelve thirteen fourteen…")
        #expect(first.proposal.near == ["source:a", "idea:i"], "an id it was not given is dropped")
        #expect(first.cites == ["p2"])
        #expect(answers[1].proposal.near == ["source:a"])
        #expect(answers[2].proposal.why == nil)
    }

    @Test("Connect draws only between placed cards, never a pair already joined or twice, with a short label and a known relation")
    func connect() throws {
        let context = CanvasAskService.Context(
            tool: .connect,
            cards: [
                askCard("c1", "source:a"), askCard("c2", "source:b"), askCard("c3", "idea:i", .idea),
                askCard("c4", "source:u", placed: false), askCard("c5", "source:v"),
            ],
            passages: [],
            arrows: [.init(from: "c2", to: "c1", label: "")]
        )
        let response = """
        [
          {"from": "c1", "to": "c2", "label": "supports", "relation": "supports"},
          {"from": "c1", "to": "c3", "label": "\\"explains the steep drop in\\"", "relation": "Explains", "why": "TMRM dims as ΔΨm falls"},
          {"from": "c3", "to": "c1", "label": "again"},
          {"from": "c1", "to": "c4", "label": "measures"},
          {"from": "c2", "to": "c3", "label": "", "relation": "same question"},
          {"from": "c2", "to": "c2", "label": "itself"},
          {"from": "c2", "to": "c9", "label": "nobody"},
          {"from": "c5", "to": "c1", "relation": "vibes"},
          {"from": "c5", "to": "c2", "label": "extends", "relation": "vibes"}
        ]
        """
        let answers = try CanvasAskService.answers(from: response, context: context)
        let arrows = answers.map(\.proposal)
        #expect(arrows.map { [$0.from ?? "", $0.to ?? ""] } == [["source:a", "idea:i"], ["source:b", "idea:i"], ["source:v", "source:b"]])
        #expect(arrows.map(\.label) == ["explains the steep drop", "same question", "extends"])
        #expect(arrows.map(\.relation) == ["explains", "same_question", nil])
        #expect(arrows[0].near == ["source:a", "idea:i"])
        #expect(arrows[0].why == "TMRM dims as ΔΨm falls")
        #expect(arrows.allSatisfy { $0.kind == .edge })
    }

    @Test("Gaps keeps up to four distinct questions, cut at 25 words, near the cards it names")
    func gaps() throws {
        let context = CanvasAskService.Context(tool: .gaps, cards: [askCard("c1", "source:a"), askCard("c2", "source:b")], passages: [])
        let long = (1...30).map { "w\($0)" }.joined(separator: " ") + "?"
        let response = """
        {"proposals": [
          {"question": "\(long)", "why": "the cards stop at mice", "near": ["c1"]},
          {"question": "Does ΔΨm fall before mitophagy?", "near": ["c2", "c2", "c7"]},
          {"question": "does ΔΨm fall before mitophagy?"},
          {"question": "   "},
          {"question": "Q3?"}, {"question": "Q4?"}, {"question": "Q5?"}
        ]}
        """
        let answers = try CanvasAskService.answers(from: response, context: context)
        #expect(answers.map(\.proposal.text) == [
            (1...25).map { "w\($0)" }.joined(separator: " ") + "…",
            "Does ΔΨm fall before mitophagy?",
            "Q3?",
            "Q4?",
        ])
        #expect(answers[0].proposal.near == ["source:a"])
        #expect(answers[1].proposal.near == ["source:b"])
        #expect(answers.allSatisfy { $0.proposal.kind == .question })
    }

    @Test("A reply that is not JSON is no answer")
    func unreadable() {
        #expect(throws: CanvasAskService.ParseError.self) {
            try CanvasAskService.answers(from: "I could not find anything.", context: Self.bridgeContext)
        }
        #expect((try? CanvasAskService.answers(from: #"{"proposals": []}"#, context: Self.bridgeContext))?.isEmpty == true)
    }

    @Test("Lines are cut at a word, and an excerpt is cut around the asked words, else from the start")
    func textCuts() {
        #expect(CanvasAskService.words("a b c d e", max: 3) == "a b c…")
        #expect(CanvasAskService.words("a b c d e", max: 3, ellipsis: false) == "a b c")
        #expect(CanvasAskService.words("  a   b \n", max: 3) == "a b")
        #expect(CanvasAskService.words(nil, max: 3) == "")

        let long = (0..<400).map { "w\($0)" }.joined(separator: " ") + " PINK1 " + (0..<400).map { "v\($0)" }.joined(separator: " ")
        let around = CanvasAskService.excerpt(long, terms: ["pink1"], length: 200)
        #expect(around.contains("PINK1"))
        #expect(around.hasPrefix("…") && around.hasSuffix("…"))
        #expect(around.count <= 202)
        let start = CanvasAskService.excerpt(long, terms: [], length: 200)
        #expect(start.hasPrefix("w0 w1 "))
        #expect(start.hasSuffix("…"))
        #expect(CanvasAskService.excerpt("short   text", terms: [], length: 200) == "short text")
    }
}

@Suite("Ask the Canvas: what the model is told")
struct CanvasAskMessageTests {
    @Test("The search is built from the learner's own words first: Ideas, then region names, then titles")
    func searchQuery() {
        let items = [
            askItem("source:a", title: "In vivo imaging of membrane potential", region: "Membrane potential"),
            askItem("idea:i", .idea, title: "Nobody reads absolute ΔΨm in humans", placed: true),
            askItem("source:b", title: "TMRM calibration", region: "Membrane potential"),
        ]
        #expect(CanvasAskService.searchQuery(for: items)
            == "Nobody reads absolute ΔΨm in humans. Membrane potential. In vivo imaging of membrane potential. TMRM calibration")
        let many = (0..<80).map { askItem("source:\($0)", title: "A rather long title about mitochondria number \($0)") }
        #expect(CanvasAskService.searchQuery(for: many).count <= CanvasAskService.queryCharacters)
    }

    @Test("What the learner set aside goes with the next ask of that tool, and nothing is said when there is none")
    func setAsideInTheMessage() {
        var context = CanvasAskService.Context(
            tool: .gaps,
            cards: [askCard("c1", "source:a")],
            passages: [.init(id: "p1", ref: "source:a", text: "TMRM reads membrane potential.")],
            regions: ["Membrane potential"],
            setAside: ["Is ΔΨm lower in aged neurons?"]
        )
        context.cards[0].passageID = "p1"
        let message = CanvasAskService.message(context)
        #expect(message.hasPrefix(Prompts.canvasAskGaps))
        #expect(message.contains(Prompts.canvasAskSetAside))
        #expect(message.contains("Is ΔΨm lower in aged neurons?"))
        #expect(message.contains(#""id":"p1""#))
        #expect(message.contains(#""regions":["Membrane potential"]"#))
        context.setAside = []
        #expect(!CanvasAskService.message(context).contains("set_aside"))
    }

    @Test("The asked cards are read Ideas first, with their region and the arrows among them; a refused ask says why")
    @MainActor
    func snapshot() throws {
        let suite = UserDefaults(suiteName: "CanvasAskTests.\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasAsk_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
            let map = vm.knowledgeMap
            let idea = IdeaRecord(id: "i", title: "Nobody reads absolute ΔΨm in humans")
            map.rebuildContent(articles: [paper("a"), paper("b"), paper("u")], ideas: [idea], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            map.place([(ref: "source:a", x: 0, y: 0), (ref: "source:b", x: 300, y: 0), (ref: "idea:i", x: 0, y: 400)])
            map.saveRegion(id: "r1", name: "Membrane potential", x: -50, y: -50, w: 700, h: 300, color: "#7F77DD")
            _ = map.addEdge(from: "source:a", to: "source:b")
            map.showProposals(proposalSet(.gaps, [KnowledgeMapProposal(id: "q1", kind: .question, text: "Is ΔΨm lower in aged neurons?")]), makeIdea: nil)
            map.dismissProposal("q1")

            let snapshot = try vm.canvasAskSnapshot(.gaps, refs: ["source:a", "idea:i", "source:b", "source:u", "source:missing", "source:a"])
            #expect(snapshot.items.map(\.ref) == ["idea:i", "source:a", "source:b", "source:u"])
            #expect(snapshot.items.map(\.region) == [nil, "Membrane potential", "Membrane potential", nil])
            #expect(snapshot.items.map(\.placed) == [true, true, true, false])
            #expect(snapshot.arrows == [CanvasAskService.Arrow(from: "source:a", to: "source:b", label: "")])
            #expect(snapshot.setAside == ["Is ΔΨm lower in aged neurons?"])
            #expect(try vm.canvasAskSnapshot(.bridge, refs: ["source:a"]).setAside.isEmpty, "set aside per tool")

            #expect(throws: StudioViewModel.CanvasAskRefusal.needsTwoPlacedCards) {
                try vm.canvasAskSnapshot(.connect, refs: ["source:a", "source:u"])
            }
            #expect(throws: StudioViewModel.CanvasAskRefusal.noCards) {
                try vm.canvasAskSnapshot(.bridge, refs: ["source:missing"])
            }
            var lens = KnowledgeMapLensRequest(title: "Lens", layout: .groups)
            lens.groups = [.init(label: "G", items: [KnowledgeMap.ItemRef(kind: .source, id: "u")])]
            try map.apply(lens)
            #expect(throws: StudioViewModel.CanvasAskRefusal.lensShowing) {
                try vm.beginCanvasAsk(.bridge, refs: ["source:a"])
            }
            #expect(map.asking == nil)
        }
    }

    @Test("ask_canvas takes a tool and 1 to 24 cards, and is paid work an AI app's call shows")
    func toolArguments() throws {
        let request = try MCPDataStore.canvasAskRequest(from: ["tool": "Connect", "item_ids": ["source:a", " b ", "source:a"]])
        #expect(request.tool == .connect)
        #expect(request.itemIDs == ["source:a", "b"])
        #expect(throws: MCPError.self) { try MCPDataStore.canvasAskRequest(from: ["tool": "summarize", "item_ids": ["a"]]) }
        #expect(throws: MCPError.self) { try MCPDataStore.canvasAskRequest(from: ["tool": "gaps", "item_ids": [String]()]) }
        #expect(throws: MCPError.self) { try MCPDataStore.canvasAskRequest(from: ["tool": "gaps", "item_ids": (0..<25).map { "s\($0)" }]) }
        #expect(MCPToolRegistry.paidWorkToolNames.contains("ask_canvas"))
        #expect(MCPToolActivityTitle.forTool("ask_canvas", arguments: ["tool": "gaps"]) != nil)
        #expect(MCPToolRegistry.storeGateExemptToolNames.contains("ask_canvas"))
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "ask_canvas" })
        #expect(tool.description.contains("No tool keeps a proposal"))
    }
}

@Suite("Ask the Canvas: keeping and dismissing")
@MainActor
struct CanvasAskKeepTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "CanvasAskKeepTests.\(UUID().uuidString)")!
    }

    @Test("A kept source is placed once where it was dropped or drawn, one undo step; one already placed is shown, not moved")
    func keepSource() {
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: ["a", "b", "c", "d"].map { paper($0) }, ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "source:c", x: 900, y: 900)])
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.showProposals(proposalSet(.bridge, [
                KnowledgeMapProposal(id: "p1", kind: .source, ref: "source:b", near: ["source:a"]),
                KnowledgeMapProposal(id: "p2", kind: .source, ref: "source:c", near: ["source:a"]),
                KnowledgeMapProposal(id: "p3", kind: .source, ref: "source:d", near: ["source:a"]),
            ], anchor: ["source:a"]), makeIdea: nil)
            model.receiveProposalMessage("proposalLayout", ["positions": ["p1": ["x": 300, "y": 10], "p2": ["x": 600, "y": 10], "p3": ["x": 0, "y": 300]]])
            #expect(model.askState.positions["p1"].map { [$0.x, $0.y] } == [300, 10])

            model.receiveProposalMessage("proposalKeep", ["id": "p1"])
            #expect(spot(model.layout.placements["source:b"]) == [300, 10], "where its ghost was drawn")
            model.receiveProposalMessage("proposalKeep", ["id": "p3", "x": 420.4, "y": -30])
            #expect(spot(model.layout.placements["source:d"]) == [420, -30], "where it was dropped")
            #expect(model.proposals?.proposals.map(\.id) == ["p2"])

            #expect(model.keepProposal("p2") == .shown("source:c"))
            #expect(spot(model.layout.placements["source:c"]) == [900, 900], "a placed card is never moved")
            #expect(model.commands.last?.action == .focus(refs: ["source:c"], regionID: nil))
            #expect(model.proposals == nil, "the banner goes with the last proposal")
            #expect(model.keepProposal("p2") == .unknown)

            model.undo()
            #expect(model.layout.placements["source:b"] == nil && model.layout.placements["source:d"] == nil, "keeping is an undo step of the learner's")
            #expect(model.layout.placements["source:a"] != nil)
        }
    }

    @Test("A kept arrow is drawn with its label between two placed cards, never over one that joins them already")
    func keepArrow() {
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: ["a", "b", "c", "z"].map { paper($0) }, ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "source:b", x: 300, y: 0), (ref: "source:c", x: 600, y: 0)])
            _ = model.addEdge(from: "source:b", to: "source:c")
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.showProposals(proposalSet(.connect, [
                KnowledgeMapProposal(id: "e1", kind: .edge, from: "source:a", to: "source:b", label: "explains", relation: "explains"),
                KnowledgeMapProposal(id: "e2", kind: .edge, from: "source:c", to: "source:b", label: "supports", relation: "supports"),
                KnowledgeMapProposal(id: "e3", kind: .edge, from: "source:a", to: "source:z", label: "measures", relation: "measures"),
            ]), makeIdea: nil)

            guard case .arrow(let id) = model.keepProposal("e1") else {
                Issue.record("the arrow was not drawn")
                return
            }
            #expect(model.layout.edges[id]?.from == "source:a" && model.layout.edges[id]?.to == "source:b")
            #expect(model.layout.edges[id]?.label == "explains")
            #expect(model.keepProposal("e2") == .skipped, "b and c are joined already")
            #expect(model.keepProposal("e3") == .skipped, "z is not on the plane")
            #expect(model.layout.edges.count == 2)
            #expect(model.proposals == nil)

            model.undo()
            #expect(model.layout.edges.count == 1, "the arrow and its label go back in one step")
        }
    }

    @Test("A kept question becomes an Idea where its ghost was, selected without flying there")
    func keepQuestion() async {
        await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            var asked: [String] = []
            model.showProposals(
                proposalSet(.gaps, [KnowledgeMapProposal(id: "q1", kind: .question, text: "Is ΔΨm lower in aged neurons?")]),
                makeIdea: { text, spot in
                    asked.append(text)
                    model.place([(ref: "idea:new", x: spot.x, y: spot.y)])
                    return "idea:new"
                }
            )
            model.receiveProposalMessage("proposalKeep", ["id": "q1", "x": 120, "y": -40])
            await model.askState.ideaWrites?.value
            #expect(asked == ["Is ΔΨm lower in aged neurons?"])
            #expect(spot(model.layout.placements["idea:new"]) == [120, -40])
            #expect(model.selection == ["idea:new"])
            #expect(model.askState.takePendingSelection() == ["idea:new"], "the page selects it without a flight")
            #expect(model.askState.takePendingSelection() == nil)
            #expect(model.proposals == nil)
            #expect(!model.commands.contains { if case .select = $0.action { return true } else { return false } })
        }
    }

    @Test("Keep All keeps every proposal where its ghost is drawn; Dismiss All sets every one aside")
    func keepAllAndDismissAll() async {
        await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: ["a", "b", "c"].map { paper($0) }, ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "source:b", x: 300, y: 0)])
            var made: [String] = []
            model.showProposals(proposalSet(.bridge, [
                KnowledgeMapProposal(id: "p1", kind: .source, ref: "source:c", near: ["source:a"]),
                KnowledgeMapProposal(id: "p2", kind: .edge, from: "source:a", to: "source:b", label: "measures"),
                KnowledgeMapProposal(id: "p3", kind: .question, text: "Which comes first?"),
            ]), makeIdea: { text, _ in
                made.append(text)
                return nil
            })
            model.receiveProposalMessage("proposalLayout", ["positions": ["p1": ["x": 30, "y": 400], "p3": ["x": 330, "y": 400]]])
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect(spot(model.layout.placements["source:c"]) == [30, 400])
            #expect(model.layout.edges.values.map(\.label) == ["measures"])
            #expect(made == ["Which comes first?"])
            #expect(model.proposals == nil)
            #expect(model.selection.isEmpty, "Keep All selects nothing")

            model.showProposals(proposalSet(.gaps, [
                KnowledgeMapProposal(id: "q1", kind: .question, text: "One?"),
                KnowledgeMapProposal(id: "q2", kind: .question, text: "Two?"),
            ]), makeIdea: nil)
            model.dismissAllProposals()
            #expect(model.proposals == nil)
            #expect(model.setAsideExamples(for: .gaps) == ["One?", "Two?"])
        }
    }

    @Test("Dismissing remembers what was set aside, per tool, newest last and each once; a Bridge's source is never offered again")
    func dismissing() {
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: [paper("a", "PINK1 imaging"), paper("b", "Parkin recruitment")], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            model.showProposals(proposalSet(.bridge, [
                KnowledgeMapProposal(id: "p1", kind: .source, ref: "source:a", why: "links the two", near: []),
                KnowledgeMapProposal(id: "p2", kind: .source, ref: "source:b", near: []),
            ]), makeIdea: nil)
            model.receiveProposalMessage("proposalDismiss", ["id": "p1"])
            #expect(model.proposals?.proposals.map(\.id) == ["p2"])
            #expect(model.setAsideExamples(for: .bridge) == ["“PINK1 imaging” (offered because: links the two)"])
            #expect(model.askState.setAsideSourceIDs == ["a"])
            #expect(model.setAsideExamples(for: .gaps).isEmpty)

            model.showProposals(proposalSet(.connect, [
                KnowledgeMapProposal(id: "e1", kind: .edge, from: "source:a", to: "source:b", label: "recruits"),
            ]), makeIdea: nil)
            model.dismissProposal("e1")
            #expect(model.setAsideExamples(for: .connect) == ["“PINK1 imaging” — recruits→ “Parkin recruitment”"])
            #expect(model.proposals == nil)

            @MainActor func dismissQuestion(_ text: String) {
                model.showProposals(proposalSet(.gaps, [KnowledgeMapProposal(id: "q", kind: .question, text: text)]), makeIdea: nil)
                model.dismissProposal("q")
            }
            for round in 0..<15 { dismissQuestion("Q\(round)?") }
            var gaps = model.setAsideExamples(for: .gaps)
            #expect(gaps.count == KnowledgeMapAskState.setAsideLimit)
            #expect(gaps.first == "Q3?" && gaps.last == "Q14?", "the newest are kept")
            dismissQuestion("Q5?")
            gaps = model.setAsideExamples(for: .gaps)
            #expect(gaps.last == "Q5?", "a repeat moves to the end rather than standing twice")
            #expect(gaps.count == KnowledgeMapAskState.setAsideLimit)
            #expect(Set(gaps).count == gaps.count)
        }
    }

    @Test("A lens and proposals never show together")
    func lensClearsProposals() throws {
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: [paper("a")], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            let set = proposalSet(.gaps, [KnowledgeMapProposal(id: "q", kind: .question, text: "Q?")])
            #expect(model.showProposals(set, makeIdea: nil))
            let revision = model.proposalsRevision
            var lens = KnowledgeMapLensRequest(title: "Lens", layout: .groups)
            lens.groups = [.init(label: "G", items: [KnowledgeMap.ItemRef(kind: .source, id: "a")])]
            try model.apply(lens)
            #expect(model.proposals == nil)
            #expect(model.proposalsRevision != revision, "the canvas is told")
            #expect(!model.showProposals(set, makeIdea: nil))
            #expect(model.proposals == nil)
            model.clearLens()
            #expect(model.showProposals(set, makeIdea: nil))
            #expect(model.proposals?.id == set.id)
        }
    }
}

@Suite("Written faces")
struct KnowledgeMapFacesTests {
    @Test("A face is written from the ideas when there are some, else the first 3,000 characters, and again only when they or the title change")
    func fingerprint() {
        let start = String(repeating: "a", count: KnowledgeMapFaces.fingerprintCharacters)
        let text = KnowledgeMapFaces.SourceText(start: start, ideas: [])
        let base = KnowledgeMapFaces.fingerprint(title: "T", text: text)
        #expect(base.count == 64)
        #expect(base == KnowledgeMapFaces.fingerprint(title: "T", text: .init(start: start + "more", ideas: [])), "past 3,000 characters nothing counts")
        #expect(base != KnowledgeMapFaces.fingerprint(title: "T2", text: text))
        #expect(base != KnowledgeMapFaces.fingerprint(title: "T", text: .init(start: "b" + start.dropFirst(), ideas: [])))
        let ideas = KnowledgeMapFaces.fingerprint(title: "T", text: .init(start: "one", ideas: ["PINK1 builds up on damaged mitochondria."]))
        #expect(ideas == KnowledgeMapFaces.fingerprint(title: "T", text: .init(start: "two", ideas: ["PINK1 builds up on damaged mitochondria."])))
        #expect(ideas != base)
        #expect(KnowledgeMapFaces.SourceText(start: "  ", ideas: []).isEmpty)
    }

    @Test("Only faces that are missing or were written from other text are asked for, twelve to a call")
    func needingAndBatches() {
        let row = { (id: String, fingerprint: String) in
            SourceFacesRow(sourceID: id, fingerprint: fingerprint, far: "f", mid: "m", near: [], model: nil, createdAt: Date())
        }
        let needing = KnowledgeMapFaces.needingFaces(
            ["fresh", "same", "changed", "unanswered", "unreadable"],
            fingerprints: ["fresh": "f1", "same": "f2", "changed": "f3", "unanswered": "f4"],
            rows: ["same": row("same", "f2"), "changed": row("changed", "old")],
            unanswered: ["f4"]
        )
        #expect(needing == ["fresh", "changed"])
        #expect(KnowledgeMapFaces.batches(Array(0..<25)).map(\.count) == [12, 12, 1])
        #expect(KnowledgeMapFaces.batches([Int]()).isEmpty)
    }

    @Test("The model reads each source under a short id, its ideas over its text, and its faces are kept only for ids it was given")
    func messageAndParsing() throws {
        let inputs = [
            KnowledgeMapFaces.Input(sourceID: "a", title: "PINK1 imaging", byline: "Smith · 2021", type: "paper", text: .init(start: "Abstract. PINK1…", ideas: ["PINK1 builds up."]), fingerprint: "fa"),
            KnowledgeMapFaces.Input(sourceID: "b", title: "Parkin", byline: "", type: "paper", text: .init(start: "Parkin is recruited.", ideas: []), fingerprint: "fb"),
        ]
        let message = KnowledgeMapFaces.message(inputs)
        #expect(message.contains(#""id":"s1""#) && message.contains(#""id":"s2""#))
        #expect(message.contains("PINK1 builds up.") && !message.contains("Abstract. PINK1"))
        #expect(message.contains("Parkin is recruited."))

        let faces = try KnowledgeMapFaces.faces(from: """
        {"faces": [
          {"id": "s1", "far": "PINK1 marks damaged mitochondria for removal fast", "mid": "PINK1 builds up on depolarised mitochondria.", "near": ["Question: a", "Approach: b", "Finding: c", "Extra: d"]},
          {"id": "s2", "far": "", "mid": "No far line"},
          {"id": "s9", "far": "Not asked", "mid": "Not asked."}
        ]}
        """, asked: inputs)
        #expect(Array(faces.keys) == ["a"])
        #expect(faces["a"]?.far == "PINK1 marks damaged mitochondria for removal")
        #expect(faces["a"]?.near == ["Question: a", "Approach: b", "Finding: c"])
        #expect(throws: KnowledgeMapFaces.ParseError.self) { try KnowledgeMapFaces.faces(from: "no", asked: inputs) }
    }

    @Test("The drawn source cards are the placed ones and a placed Idea's evidence, and their faces go to the page by ref")
    @MainActor
    func drawnSourcesAndPayload() {
        let suite = UserDefaults(suiteName: "KnowledgeMapFacesTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let idea = IdeaRecord(id: "i", title: "Mitophagy fails with age", links: [IdeaLink(kind: .source, targetID: "c")])
            model.rebuildContent(articles: ["a", "b", "c"].map { paper($0) }, ideas: [idea], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
            #expect(model.drawnSourceIDs.isEmpty)
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "idea:i", x: 300, y: 0)])
            #expect(model.drawnSourceIDs == ["a", "c"])

            let revision = model.facesRevision
            model.storeFaces([SourceFacesRow(sourceID: "a", fingerprint: "f", far: "Far", mid: "Mid.", near: ["Finding: x"], model: nil, createdAt: Date())])
            #expect(model.facesRevision != revision)
            #expect(model.faces["source:a"] == KnowledgeMapFaces.Face(far: "Far", mid: "Mid.", near: ["Finding: x"]))
            #expect(model.facesState.rows["a"]?.fingerprint == "f")
            #expect(model.facesPayload.faces.keys.sorted() == ["source:a"])
            #expect(model.facesPayload.enabled == model.showsWrittenFaces)
        }
    }
}
