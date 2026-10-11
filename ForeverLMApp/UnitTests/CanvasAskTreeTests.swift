import Foundation
import Testing
@testable import ForeverLM

// Mind Map and Question Map (docs/knowledge-map-design.md, "What Sapience
// showed", "Mind Map and Question Map (Ask)"): how the model's tree is read,
// what the ask is told, and what keeping the whole tree or one ghost of it
// writes. The older asks are in CanvasAskTests and CanvasAskNewToolsTests.

private func treeItem(_ ref: String, _ kind: KnowledgeMap.ItemKind = .source, title: String? = nil, placed: Bool = true) -> CanvasAskService.Snapshot.Item {
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

private func treeCard(_ id: String, _ ref: String, _ kind: KnowledgeMap.ItemKind = .source, title: String? = nil, placed: Bool = true) -> CanvasAskService.Card {
    CanvasAskService.Card(id: id, item: treeItem(ref, kind, title: title, placed: placed))
}

/// The reply of a model: `nodes` as (id, parent, title) lines under a root.
private func treeReply(root: String? = "Mitochondrial quality control", _ nodes: [(String, String, String)]) -> String {
    let lines = nodes.map { #"{"id": "\#($0.0)", "parent": "\#($0.1)", "title": "\#($0.2)", "note": "Note on \#($0.0).", "cites": ["p1", "p9"]}"# }
    let head = root.map { #""root": {"title": "\#($0)", "note": "What it is about."}, "# } ?? ""
    return "{\(head)\"nodes\": [\(lines.joined(separator: ", "))]}"
}

@Suite("Mind Map and Question Map: reading the answer")
struct CanvasAskTreeParseTests {
    static let asked = ["source:a", "source:b", "idea:i"]
    static let mindContext = CanvasAskService.Context(
        tool: .mindMap,
        cards: [treeCard("c1", "source:a"), treeCard("c2", "source:b"), treeCard("c3", "idea:i", .idea)],
        passages: [.init(id: "p1", ref: "source:a", text: "PINK1 builds up on depolarised mitochondria.")]
    )
    static let questionContext = CanvasAskService.Context(
        tool: .questionMap,
        cards: mindContext.cards,
        passages: mindContext.passages
    )
    static let rootedContext = CanvasAskService.Context(
        tool: .mindMap,
        cards: [treeCard("c1", "idea:r", .idea, title: "Mitophagy fails first in aged neurons")],
        passages: []
    )

    static let eight: [(String, String, String)] = [
        ("n1", "root", "Sensing damage"), ("n2", "root", "Clearing it"), ("n3", "root", "Making new ones"),
        ("n4", "n1", "PINK1 stabilises"), ("n5", "n1", "Membrane potential falls"),
        ("n6", "n2", "Parkin recruited"), ("n7", "n6", "Ubiquitin chains"), ("n8", "n3", "PGC-1α"),
    ]

    @Test("A Mind Map is the root first, then the nodes in order, each a question proposal near the asked cards; the plan's arrows run parent to child")
    func validTree() throws {
        let parsed = try CanvasAskService.parsed(from: treeReply(Self.eight), context: Self.mindContext)
        #expect(parsed.answers.map(\.proposal.id) == ["p:root"] + (1...8).map { "p:n\($0)" })
        let root = try #require(parsed.answers.first)
        #expect(root.proposal.kind == .question && root.proposal.text == "Mitochondrial quality control")
        #expect(root.proposal.note == "What it is about.")
        #expect(root.proposal.near == Self.asked)
        let node = try #require(parsed.answers.dropFirst(4).first)
        #expect(node.proposal.text == "PINK1 stabilises" && node.proposal.note == "Note on n4.")
        #expect(node.proposal.near == Self.asked)
        #expect(node.proposal.why == nil, "the ghost shows the node's words, not a why")
        #expect(node.cites == ["p1"], "a passage it was not given is dropped")
        let plan = try #require(parsed.plan)
        #expect(plan.tree == true && plan.rootRef == nil)
        #expect(plan.sourceRef == "source:a" && plan.regionName == "Mitochondrial quality control")
        #expect(plan.arrows == [
            .init(from: "p:root", to: "p:n1", label: ""), .init(from: "p:root", to: "p:n2", label: ""), .init(from: "p:root", to: "p:n3", label: ""),
            .init(from: "p:n1", to: "p:n4", label: ""), .init(from: "p:n1", to: "p:n5", label: ""),
            .init(from: "p:n2", to: "p:n6", label: ""), .init(from: "p:n6", to: "p:n7", label: ""), .init(from: "p:n3", to: "p:n8", label: ""),
        ])
    }

    @Test("A node whose parent is not the root or a node that came earlier is dropped, and so is everything that hung from it")
    func unknownParents() throws {
        let reply = treeReply([
            ("n1", "root", "Kept"), ("n2", "n9", "Parent unknown"), ("n3", "n2", "Hung from the dropped one"),
            ("n4", "n6", "Parent comes later"), ("n5", "c1", "Not the root here"), ("n6", "root", "Second branch"),
            ("n7", "n1", "A leaf"), ("n8", "", "No parent"),
        ])
        let parsed = try CanvasAskService.parsed(from: reply, context: Self.mindContext)
        #expect(parsed.answers.compactMap(\.proposal.text) == ["Mitochondrial quality control", "Kept", "Second branch", "A leaf"])
        #expect(parsed.plan?.arrows.map(\.to) == ["p:n1", "p:n6", "p:n7"])
    }

    @Test("At most three levels under the root, at most thirty nodes, and a title or id the tree has is dropped")
    func caps() throws {
        let deep = try CanvasAskService.parsed(from: treeReply([
            ("n1", "root", "One"), ("n2", "n1", "Two"), ("n3", "n2", "Three"), ("n4", "n3", "Four is too deep"), ("n5", "n4", "Five hangs from it"),
            ("n6", "root", "Another"),
        ]), context: Self.mindContext)
        #expect(deep.answers.compactMap(\.proposal.text) == ["Mitochondrial quality control", "One", "Two", "Three", "Another"])

        let many = try CanvasAskService.parsed(from: treeReply((1...40).map { ("n\($0)", "root", "Topic number \($0)") }), context: Self.mindContext)
        #expect(many.plan?.arrows.count == CanvasAskService.maximumTreeNodes)
        #expect(many.answers.count == CanvasAskService.maximumTreeNodes + 1, "thirty nodes besides the root")
        #expect(many.answers.last?.proposal.text == "Topic number 30")

        let repeats = try CanvasAskService.parsed(from: treeReply([
            ("n1", "root", "Sensing damage"), ("n2", "root", "sensing DAMAGE"), ("n3", "n2", "Child of a repeat"),
            ("n4", "root", "Mitochondrial quality control"), ("n1", "root", "Same id again"), ("root", "root", "Reserved id"),
            ("n5", "root", "Clearing it"), ("n6", "n1", "Leaf"),
        ]), context: Self.mindContext)
        #expect(repeats.answers.compactMap(\.proposal.text) == ["Mitochondrial quality control", "Sensing damage", "Clearing it", "Leaf"])
    }

    @Test("A Mind Map title is cut at eight words, a trailing full stop is not part of it, and a note at 28 words")
    func titles() throws {
        let long = "one two three four five six seven eight nine ten"
        let note = (1...40).map { "w\($0)" }.joined(separator: " ")
        let reply = #"{"root": {"title": "A root."}, "nodes": [{"id": "n1", "parent": "root", "title": "\#(long)", "note": "\#(note)"}, {"id": "n2", "parent": "root", "title": "Short."}, {"id": "n3", "parent": "root", "title": "   "}, {"id": "n4", "parent": "root", "title": "Fourth"}]}"#
        let parsed = try CanvasAskService.parsed(from: reply, context: Self.mindContext)
        #expect(parsed.answers.compactMap(\.proposal.text) == ["A root", "one two three four five six seven eight", "Short", "Fourth"])
        let cut = try #require(parsed.answers.dropFirst().first?.proposal.note)
        #expect(cut.split(separator: " ").count == CanvasAskService.treeNoteWords && cut.hasSuffix("…"))
        #expect(parsed.answers.first?.proposal.note == nil)
    }

    @Test("Hung from an Idea on the canvas: no root is written, the first branches start at the card, and the region is named for the Idea")
    func rooted() throws {
        let context = Self.rootedContext
        #expect(context.rootCard?.id == "c1")
        let reply = treeReply(root: nil, [
            ("n1", "c1", "Damage sensing"), ("n2", "c1", "Clearance"), ("n3", "root", "Renewal"),
            ("n4", "n1", "PINK1"), ("c1", "c1", "The card's own id"), ("n5", "n9", "Unknown parent"),
            ("n6", "n4", "Deepest"), ("n7", "n6", "Too deep"), ("n8", "c1", "Mitophagy fails first in aged neurons"),
        ])
        let parsed = try CanvasAskService.parsed(from: reply, context: context)
        #expect(parsed.answers.map(\.proposal.id) == ["p:n1", "p:n2", "p:n3", "p:n4", "p:n6"], "nothing is proposed for the root, and a node never repeats it")
        #expect(parsed.answers.allSatisfy { $0.proposal.near == ["idea:r"] })
        let plan = try #require(parsed.plan)
        #expect(plan.tree == true && plan.rootRef == "idea:r" && plan.sourceRef == "idea:r")
        #expect(plan.regionName == "Mitophagy fails first in aged neurons")
        #expect(plan.arrows == [
            .init(from: "idea:r", to: "p:n1", label: ""), .init(from: "idea:r", to: "p:n2", label: ""), .init(from: "idea:r", to: "p:n3", label: ""),
            .init(from: "p:n1", to: "p:n4", label: ""), .init(from: "p:n4", to: "p:n6", label: ""),
        ])
    }

    @Test("Only the one card asked about, an Idea on the canvas, is a root; the model writes the root of anything else")
    func whenRooted() {
        let placedIdea = [treeCard("c1", "idea:r", .idea)]
        #expect(CanvasAskService.Context(tool: .questionMap, cards: placedIdea, passages: []).rootCard?.item.ref == "idea:r")
        #expect(CanvasAskService.Context(tool: .mindMap, cards: [treeCard("c1", "idea:r", .idea, placed: false)], passages: []).rootCard == nil)
        #expect(CanvasAskService.Context(tool: .mindMap, cards: [treeCard("c1", "source:a")], passages: []).rootCard == nil)
        #expect(CanvasAskService.Context(tool: .mindMap, cards: placedIdea + [treeCard("c2", "idea:s", .idea)], passages: []).rootCard == nil)
        #expect(CanvasAskService.Context(tool: .gaps, cards: placedIdea, passages: []).rootCard == nil, "a tree's ask only")
    }

    @Test("A Question Map keeps only questions: a node that is not one is dropped with what hung from it, one is never cut, and a root that is not a question is no tree")
    func questions() throws {
        let tooLong = Array(repeating: "word", count: 21).joined(separator: " ") + "?"
        let reply = treeReply(root: "What keeps mitochondria healthy?", [
            ("n1", "root", "How is damage sensed?"), ("n2", "root", "Clearing damage is done by Parkin"), ("n3", "n2", "What does Parkin ubiquitinate?"),
            ("n4", "n1", "Does PINK1 need the membrane potential？"), ("n5", "root", tooLong), ("n6", "root", "“Is it renewed?”"),
            ("n7", "n1", "how is damage sensed?"), ("n8", "n4", "Which kinase phosphorylates ubiquitin in neurons?"),
        ])
        let parsed = try CanvasAskService.parsed(from: reply, context: Self.questionContext)
        #expect(parsed.answers.compactMap(\.proposal.text) == [
            "What keeps mitochondria healthy?", "How is damage sensed?", "Does PINK1 need the membrane potential？",
            "Is it renewed?", "Which kinase phosphorylates ubiquitin in neurons?",
        ])
        #expect(parsed.plan?.arrows.map(\.to) == ["p:n1", "p:n4", "p:n6", "p:n8"])
        let notQuestion = try CanvasAskService.parsed(
            from: treeReply(root: "A topic, not a question", Self.eight),
            context: Self.questionContext
        )
        #expect(notQuestion.answers.isEmpty && notQuestion.plan == nil)
        #expect(try CanvasAskService.parsed(from: treeReply(root: "Why?", Self.eight), context: Self.mindContext).answers.count == 9, "a Mind Map takes any words")
    }

    @Test("A Question Map hung from an Idea takes questions under it, and the card's own title is not offered again")
    func questionsRooted() throws {
        let context = CanvasAskService.Context(tool: .questionMap, cards: [treeCard("c1", "idea:r", .idea, title: "Why does mitophagy fail?")], passages: [])
        let parsed = try CanvasAskService.parsed(from: treeReply(root: nil, [
            ("n1", "c1", "Is PINK1 lost?"), ("n2", "c1", "Is Parkin lost?"), ("n3", "n2", "why does mitophagy fail?"), ("n4", "n2", "Is it recruited late?"),
            ("n5", "c1", "Not a question"),
        ]), context: context)
        #expect(parsed.answers.compactMap(\.proposal.text) == ["Is PINK1 lost?", "Is Parkin lost?", "Is it recruited late?"])
        #expect(parsed.plan?.rootRef == "idea:r")
    }

    @Test("Fewer than three nodes, no root, or no nodes is no answer; a reply that is not an object cannot be read")
    func nothing() throws {
        let two = try CanvasAskService.parsed(from: treeReply([("n1", "root", "One"), ("n2", "root", "Two")]), context: Self.mindContext)
        #expect(two.answers.isEmpty && two.plan == nil)
        let noRoot = try CanvasAskService.parsed(from: treeReply(root: nil, Self.eight), context: Self.mindContext)
        #expect(noRoot.answers.isEmpty && noRoot.plan == nil, "the model writes the root unless the tree hangs from a card")
        let blankRoot = try CanvasAskService.parsed(from: treeReply(root: "  ", Self.eight), context: Self.mindContext)
        #expect(blankRoot.answers.isEmpty)
        let noNodes = try CanvasAskService.parsed(from: #"{"root": {"title": "Alone"}}"#, context: Self.mindContext)
        #expect(noNodes.answers.isEmpty && noNodes.plan == nil)
        let fenced = try CanvasAskService.parsed(from: "```json\n\(treeReply(Self.eight))\n```", context: Self.mindContext)
        #expect(fenced.answers.count == 9)
        #expect(throws: CanvasAskService.ParseError.self) { try CanvasAskService.parsed(from: "[]", context: Self.mindContext) }
        #expect(throws: CanvasAskService.ParseError.self) { try CanvasAskService.parsed(from: "not json", context: Self.questionContext) }
    }
}

@Suite("Mind Map and Question Map: what the model is told, what is asked")
struct CanvasAskTreeMessageTests {
    @Test("The tool's task text leads the message, the rooted one when the tree hangs from an Idea")
    func instructions() {
        let free = CanvasAskTreeParseTests.mindContext
        #expect(CanvasAskService.message(free).hasPrefix(Prompts.canvasAskMindMap))
        #expect(CanvasAskService.message(CanvasAskTreeParseTests.questionContext).hasPrefix(Prompts.canvasAskQuestionMap))
        let rooted = CanvasAskTreeParseTests.rootedContext
        #expect(CanvasAskService.message(rooted).hasPrefix(Prompts.canvasAskMindMapRooted))
        #expect(rooted.cards.first?.item.kind == .idea)
        let question = CanvasAskService.Context(tool: .questionMap, cards: rooted.cards, passages: [])
        #expect(CanvasAskService.message(question).hasPrefix(Prompts.canvasAskQuestionMapRooted))
        for text in [Prompts.canvasAskMindMap, Prompts.canvasAskQuestionMap] {
            #expect(text.contains(#""root""#) && text.contains("8 to 30") && text.contains("3 to 7"))
        }
        for text in [Prompts.canvasAskMindMapRooted, Prompts.canvasAskQuestionMapRooted] {
            #expect(text.contains("c1") && text.contains("do not write a root") && !text.contains(#""root": {"#))
        }
    }

    @Test("One source asked is read whole, as a Break Down reads it; several cards, or an Idea, are read by their best passage")
    func readsWholeSource() {
        #expect(CanvasAskService.readsWholeSource(.breakDown, kinds: [.source]))
        #expect(CanvasAskService.readsWholeSource(.mindMap, kinds: [.source]))
        #expect(CanvasAskService.readsWholeSource(.questionMap, kinds: [.source]))
        #expect(!CanvasAskService.readsWholeSource(.mindMap, kinds: [.source, .source]))
        #expect(!CanvasAskService.readsWholeSource(.mindMap, kinds: [.idea]))
        #expect(!CanvasAskService.readsWholeSource(.gaps, kinds: [.source]))
        var one = CanvasAskService.Context(
            tool: .mindMap,
            cards: [treeCard("c1", "source:a")],
            passages: [.init(id: "p1", ref: "source:a", text: "Start."), .init(id: "p2", ref: "source:a", text: "End.")]
        )
        #expect(CanvasAskService.message(one).contains(#""source_passages":[{"id":"p1","text":"Start."},{"id":"p2","text":"End."}]"#))
        one.cards.append(treeCard("c2", "source:b"))
        #expect(!CanvasAskService.message(one).contains(#""source_passages":["#), "the task text names the key; the Canvas holds it only for one source")
    }

    @Test("The asks have their titles and menu words, the plan keeps its old shape for a Break Down, and ask_canvas offers neither")
    func tools() throws {
        #expect(CanvasAskTool.mindMap.rawValue == "mind_map" && CanvasAskTool.questionMap.rawValue == "question_map")
        #expect(CanvasAskTool.mindMap.title == "Mind Map" && CanvasAskTool.mindMap.menuTitle == "Make a Mind Map")
        #expect(CanvasAskTool.questionMap.title == "Question Map" && CanvasAskTool.questionMap.menuTitle == "Break Into Questions")
        #expect(CanvasAskTool.allCases.contains(.mindMap) && CanvasAskTool.allCases.contains(.questionMap))
        #expect(CanvasAskTool.mindMap.drawsTree && CanvasAskTool.questionMap.drawsTree && !CanvasAskTool.breakDown.drawsTree)
        #expect(CanvasAskTool.overMCP == [.bridge, .connect, .gaps], "an assistant draws a mind map with build_canvas")
        for name in ["mind_map", "question_map"] {
            #expect(throws: MCPError.self) { try MCPDataStore.canvasAskRequest(from: ["tool": name, "item_ids": ["source:a"]]) }
        }
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "ask_canvas" })
        let schema = try #require(tool.inputSchema["properties"] as? [String: Any])
        let offered = try #require((schema["tool"] as? [String: Any])?["enum"] as? [String])
        #expect(offered == ["bridge", "connect", "gaps"])

        let old = try JSONDecoder().decode(
            KnowledgeMapBreakDownPlan.self,
            from: Data(#"{"sourceRef": "source:a", "regionName": "A paper", "arrows": [{"from": "p:k1", "to": "p:k2", "label": "recruits"}]}"#.utf8)
        )
        #expect(old.tree == nil && old.rootRef == nil)
        let tree = KnowledgeMapBreakDownPlan(sourceRef: "idea:r", regionName: "Root", arrows: [], tree: true, rootRef: "idea:r")
        #expect(try JSONDecoder().decode(KnowledgeMapBreakDownPlan.self, from: JSONEncoder().encode(tree)) == tree)
    }

    @Test("Both asks take 1 to 24 cards, a source on its own is read whole, and an Idea on the canvas is the root")
    @MainActor
    func snapshot() throws {
        let suite = UserDefaults(suiteName: "CanvasAskTreeTests.\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasAskTree_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
            let papers = (0..<30).map { StudioArticle(url: "https://example.com/\($0)", title: "Paper \($0)", sourceType: .paper, id: "s\($0)") }
            vm.knowledgeMap.rebuildContent(
                articles: papers, ideas: [IdeaRecord(id: "i", title: "Mitophagy fails first"), IdeaRecord(id: "u", title: "Not placed")],
                notebooks: [], chats: [], artifacts: [], firstHighlights: [:]
            )
            vm.knowledgeMap.place([(ref: "idea:i", x: 0, y: 0)])
            for tool in [CanvasAskTool.mindMap, .questionMap] {
                let many = try vm.canvasAskSnapshot(tool, refs: papers.map { "source:\($0.id)" })
                #expect(many.items.count == CanvasAskService.maximumCards && !many.readsWholeSource)
                let one = try vm.canvasAskSnapshot(tool, refs: ["source:s1"])
                #expect(one.items.map(\.ref) == ["source:s1"] && one.readsWholeSource)
                let idea = try vm.canvasAskSnapshot(tool, refs: ["idea:i"])
                #expect(idea.items.map(\.placed) == [true] && !idea.readsWholeSource)
                #expect(try vm.canvasAskSnapshot(tool, refs: ["idea:u"]).items.map(\.placed) == [false])
                #expect(throws: StudioViewModel.CanvasAskRefusal.noCards) { try vm.canvasAskSnapshot(tool, refs: ["source:missing"]) }
            }
            let asked = try vm.canvasAskSnapshot(.mindMap, refs: ["idea:i"])
            let context = CanvasAskService.Context(tool: .mindMap, cards: [CanvasAskService.Card(id: "c1", item: asked.items[0])], passages: [])
            #expect(context.rootCard?.item.ref == "idea:i")
        }
    }
}

@Suite("Mind Map and Question Map: keeping")
@MainActor
struct CanvasAskTreeKeepTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "CanvasAskTreeKeepTests.\(UUID().uuidString)")!
    }

    /// The Ideas of a tree as the model gave it: a root, two branches and two
    /// leaves under the first (`p:n1`), the plan's arrows between them.
    private func freeTree() -> (proposals: [KnowledgeMapProposal], plan: KnowledgeMapBreakDownPlan) {
        let titles = ["p:root": "Quality control", "p:n1": "Sensing", "p:n2": "Clearing", "p:n3": "PINK1", "p:n4": "Potential"]
        let proposals = ["p:root", "p:n1", "p:n2", "p:n3", "p:n4"].map {
            KnowledgeMapProposal(id: $0, kind: .question, text: titles[$0], near: ["source:a"], note: "Note on \(titles[$0] ?? "")")
        }
        let plan = KnowledgeMapBreakDownPlan(sourceRef: "source:a", regionName: "Quality control", arrows: [
            .init(from: "p:root", to: "p:n1", label: ""), .init(from: "p:root", to: "p:n2", label: ""),
            .init(from: "p:n1", to: "p:n3", label: ""), .init(from: "p:n1", to: "p:n4", label: ""),
        ], tree: true)
        return (proposals, plan)
    }

    /// The same under an Idea on the canvas (`idea:r`): no root proposal.
    private func hungTree() -> (proposals: [KnowledgeMapProposal], plan: KnowledgeMapBreakDownPlan) {
        let free = freeTree()
        let plan = KnowledgeMapBreakDownPlan(sourceRef: "idea:r", regionName: "Root", arrows: [
            .init(from: "idea:r", to: "p:n1", label: ""), .init(from: "idea:r", to: "p:n2", label: ""),
            .init(from: "p:n1", to: "p:n3", label: ""), .init(from: "p:n1", to: "p:n4", label: ""),
        ], tree: true, rootRef: "idea:r")
        return (Array(free.proposals.dropFirst()), plan)
    }

    private func set(_ tool: CanvasAskTool, _ tree: (proposals: [KnowledgeMapProposal], plan: KnowledgeMapBreakDownPlan)) -> KnowledgeMapProposalSet {
        KnowledgeMapProposalSet(id: "set", tool: tool, title: tool.title, anchor: [], proposals: tree.proposals, createdAt: Date(), plan: tree.plan)
    }

    /// Writes Ideas as the app's closures do: a ref per call (`idea:t1`, …)
    /// and, with a spot, the Idea placed there.
    @MainActor
    private final class Writes {
        var titles: [String] = []
        var notes: [String?] = []
        var spots: [(x: Double, y: Double)?] = []
        var refs: [String: String] = [:]
        var failing: Set<String> = []

        func write(_ model: KnowledgeMapModel) -> (String, String?, (x: Double, y: Double)?) async -> String? {
            { [self] title, note, spot in
                titles.append(title)
                notes.append(note)
                spots.append(spot)
                guard !failing.contains(title) else { return nil }
                let ref = "idea:t\(titles.count)"
                refs[title] = ref
                if let spot { model.place([(ref: ref, x: spot.x, y: spot.y)]) }
                return ref
            }
        }
    }

    private func edges(_ model: KnowledgeMapModel) -> Set<String> {
        Set(model.layout.edges.values.map { "\($0.from)>\($0.to)\($0.isTree ? " tree" : "")" })
    }

    private func spot(_ model: KnowledgeMapModel, _ ref: String) -> [Double]? {
        model.layout.placements[ref].map { [$0.x, $0.y] }
    }

    private func layoutMessage(_ ids: [String: [Double]]) -> [String: Any] {
        ["positions": ids.mapValues { ["x": $0[0], "y": $0[1]] }]
    }

    @Test("Keep All on a tree the model rooted writes every node with its note, lays them out in a region named for the root with a tree layout, and draws the branches, in one Undo step")
    func keepAllFree() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "source:a", x: 0, y: 0)])
            try await Task.sleep(for: .seconds(KnowledgeMapModel.editBurst + 0.05))
            let writes = Writes()
            model.showProposals(set(.mindMap, freeTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalLayout", layoutMessage([
                "p:root": [400, 0], "p:n1": [700, -60], "p:n2": [700, 100], "p:n3": [1000, -120], "p:n4": [1000, 0],
            ]))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value

            #expect(writes.titles == ["Quality control", "Sensing", "Clearing", "PINK1", "Potential"], "in the order of the set, a parent before its children")
            #expect(writes.notes == ["Note on Quality control", "Note on Sensing", "Note on Clearing", "Note on PINK1", "Note on Potential"])
            #expect(writes.spots.allSatisfy { $0 == nil }, "written unplaced: the tree places them")
            let ideas = (1...5).map { "idea:t\($0)" }
            #expect(ideas.allSatisfy { model.layout.placements[$0] != nil })
            #expect(edges(model) == ["idea:t1>idea:t2 tree", "idea:t1>idea:t3 tree", "idea:t2>idea:t4 tree", "idea:t2>idea:t5 tree"])
            let region = try #require(model.layout.regions.values.first)
            #expect(model.layout.regions.count == 1 && region.name == "Quality control" && region.isTree)
            for ref in ideas {
                let placement = try #require(model.layout.placements[ref])
                #expect(placement.x >= region.x && placement.x + model.cardWidth(of: ref) <= region.x + region.w + 0.5)
                #expect(placement.y >= region.y && placement.y + model.cardHeight(of: ref) <= region.y + region.h + 0.5)
            }
            #expect(spot(model, "source:a") == [0, 0])
            #expect(Set(model.selection) == Set(ideas) && model.proposals == nil)

            model.undo()
            #expect(model.layout.placements.keys.sorted() == ["source:a"], "the Ideas, the region and the branches go in one step")
            #expect(model.layout.edges.isEmpty && model.layout.regions.isEmpty)
        }
    }

    @Test("Without the page's layout the tree is still set down in free space in its own region, branches drawn")
    func keepAllFreeWithoutGhosts() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "source:a", x: 0, y: 0)])
            let writes = Writes()
            model.showProposals(set(.questionMap, freeTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect((1...5).allSatisfy { model.layout.placements["idea:t\($0)"] != nil })
            #expect(edges(model) == ["idea:t1>idea:t2 tree", "idea:t1>idea:t3 tree", "idea:t2>idea:t4 tree", "idea:t2>idea:t5 tree"])
            let region = try #require(model.layout.regions.values.first)
            #expect(region.name == "Quality control" && region.isTree)
        }
    }

    @Test("A node whose parent could not be written is not written, and what hangs from the rest is still drawn")
    func keepAllFailedWrite() async {
        await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let writes = Writes()
            writes.failing = ["Sensing"]
            model.showProposals(set(.mindMap, freeTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect(writes.titles == ["Quality control", "Sensing", "Clearing"], "PINK1 and Potential hung from the one that failed")
            #expect(edges(model) == ["idea:t1>idea:t3 tree"])
        }
    }

    @Test("A tree hung from an Idea sets its nodes where the ghosts were, branches from the card; the mind-map region the card is in grows to hold them, and no region is made")
    func keepAllHungInATree() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "idea:r", x: 0, y: 0)])
            model.saveRegion(id: "r1", name: "Topic", x: -50, y: -60, w: 400, h: 300, color: "#7F77DD")
            #expect(model.setRegionLayout("r1", KnowledgeMapLayout.treeLayout))
            let before = try #require(model.layout.regions["r1"])
            let rootSpot = spot(model, "idea:r")
            try await Task.sleep(for: .seconds(KnowledgeMapModel.editBurst + 0.05))
            let writes = Writes()
            model.showProposals(set(.questionMap, hungTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalLayout", layoutMessage(["p:n1": [500, -40], "p:n2": [500, 120], "p:n3": [800, -80], "p:n4": [800, 20]]))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value

            #expect(writes.titles == ["Sensing", "Clearing", "PINK1", "Potential"], "the card is the root: nothing is written for it")
            #expect(spot(model, "idea:t1") == [500, -40] && spot(model, "idea:t4") == [800, 20], "where the ghosts were drawn")
            #expect(spot(model, "idea:r") == rootSpot, "the card never moves")
            #expect(edges(model) == ["idea:r>idea:t1 tree", "idea:r>idea:t2 tree", "idea:t1>idea:t3 tree", "idea:t1>idea:t4 tree"])
            let region = try #require(model.layout.regions["r1"])
            #expect(model.layout.regions.count == 1 && region.isTree)
            #expect(region.x + region.w > before.x + before.w, "grown to hold the new Ideas")
            for ref in (1...4).map({ "idea:t\($0)" }) {
                let placement = try #require(model.layout.placements[ref])
                #expect(placement.x + model.cardWidth(of: ref) <= region.x + region.w + 0.5)
            }
            model.undo()
            #expect(model.layout.placements.keys.sorted() == ["idea:r"] && model.layout.edges.isEmpty)
            let restored = try #require(model.layout.regions["r1"])
            #expect([restored.x, restored.y, restored.w, restored.h] == [before.x, before.y, before.w, before.h], "the growth is part of the one step")
        }
    }

    @Test("A tree hung from an Idea that is in no mind map gets a mind map of its own around the Idea, which stays where it is")
    func keepAllHungFree() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "idea:r", x: 0, y: 0)])
            model.saveRegion(id: "r1", name: "Loose", x: -50, y: -60, w: 400, h: 300, color: "#7F77DD")
            let before = try #require(model.layout.regions["r1"])
            let writes = Writes()
            model.showProposals(set(.mindMap, hungTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalLayout", layoutMessage(["p:n1": [500, -40], "p:n2": [500, 120], "p:n3": [800, -80], "p:n4": [800, 20]]))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect(spot(model, "idea:t2") == [500, 120])
            #expect(edges(model).count == 4 && edges(model).allSatisfy { $0.hasSuffix(" tree") })
            #expect(spot(model, "idea:r") == [0, 0])
            #expect(model.layout.regions["r1"] == before && model.layout.regions.count == 2)
            let tree = try #require(model.layout.regions.first { $0.key != "r1" }?.value)
            #expect(tree.isTree && tree.x <= 0 && tree.x + tree.w >= 800 + model.cardWidth(of: "idea:t3"))
        }
    }

    @Test("Without the page's layout a hung tree is laid out here as a tree from the card, which stays")
    func keepAllHungWithoutGhosts() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "idea:r", x: 100, y: 200)])
            let writes = Writes()
            model.showProposals(set(.mindMap, hungTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect(spot(model, "idea:r") == [100, 200])
            let column = try (1...2).map { try #require(model.layout.placements["idea:t\($0)"]) }
            #expect(column.allSatisfy { $0.x > 100 + model.cardWidth(of: "idea:r") }, "to the right of the card")
            #expect(column[0].y < column[1].y)
            #expect(edges(model).count == 4)
        }
    }

    @Test("Keeping one ghost writes that Idea at its spot and draws its branch when its parent is the root card or an Idea kept before, whichever was kept first")
    func keepOne() async {
        await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "idea:r", x: 0, y: 0)])
            let writes = Writes()
            model.showProposals(set(.mindMap, hungTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalLayout", layoutMessage(["p:n1": [500, -40], "p:n2": [500, 120], "p:n3": [800, -80], "p:n4": [800, 20]]))

            // A leaf first: its parent is not an Idea yet, so nothing joins it.
            model.receiveProposalMessage("proposalKeep", ["id": "p:n3"])
            await model.askState.ideaWrites?.value
            #expect(writes.spots.count == 1 && writes.spots[0]?.x == 800 && spot(model, "idea:t1") == [800, -80])
            #expect(edges(model).isEmpty)
            #expect(model.selection == ["idea:t1"])

            // Its parent next: joined to the card, and to the leaf kept before.
            model.receiveProposalMessage("proposalKeep", ["id": "p:n1", "x": 520, "y": -30])
            await model.askState.ideaWrites?.value
            #expect(spot(model, "idea:t2") == [520, -30], "where it was dropped")
            #expect(edges(model) == ["idea:r>idea:t2 tree", "idea:t2>idea:t1 tree"])

            // A leaf whose parent was kept: joined to it.
            model.receiveProposalMessage("proposalKeep", ["id": "p:n4"])
            await model.askState.ideaWrites?.value
            #expect(edges(model).contains("idea:t2>idea:t3 tree"))
            #expect(model.proposals?.proposals.map(\.id) == ["p:n2"])

            model.receiveProposalMessage("proposalKeep", ["id": "p:n2"])
            await model.askState.ideaWrites?.value
            #expect(edges(model).contains("idea:r>idea:t4 tree") && edges(model).count == 4)
            #expect(model.proposals == nil)
        }
    }

    @Test("A node kept alone under an Idea in a mind map grows the region to hold it")
    func keepOneGrowsTheRegion() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "idea:r", x: 0, y: 0)])
            model.saveRegion(id: "r1", name: "Topic", x: -50, y: -60, w: 400, h: 300, color: "#7F77DD")
            #expect(model.setRegionLayout("r1", KnowledgeMapLayout.treeLayout))
            let before = try #require(model.layout.regions["r1"])
            let writes = Writes()
            model.showProposals(set(.mindMap, hungTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalKeep", ["id": "p:n1", "x": 900, "y": 0])
            await model.askState.ideaWrites?.value
            #expect(edges(model) == ["idea:r>idea:t1 tree"])
            let region = try #require(model.layout.regions["r1"])
            #expect(region.x + region.w >= 900 + model.cardWidth(of: "idea:t1") && region.w > before.w)
            #expect(model.layout.regions.count == 1)
        }
    }

    @Test("Keeping the ghosts of a tree the model rooted one at a time joins each to the Idea its parent became, in one mind map")
    func keepOneFree() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let writes = Writes()
            model.showProposals(set(.questionMap, freeTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalKeep", ["id": "p:root", "x": 0, "y": 0])
            model.receiveProposalMessage("proposalKeep", ["id": "p:n1", "x": 300, "y": 0])
            model.receiveProposalMessage("proposalKeep", ["id": "p:n3", "x": 600, "y": 0])
            await model.askState.ideaWrites?.value
            #expect(writes.titles == ["Quality control", "Sensing", "PINK1"], "written one after another, in the order they were kept")
            #expect(edges(model) == ["idea:t1>idea:t2 tree", "idea:t2>idea:t3 tree"])
            let region = try #require(model.layout.regions.values.first)
            #expect(model.layout.regions.count == 1 && region.isTree && region.name == "Quality control", "the first branch kept makes the mind map")
            for ref in ["idea:t1", "idea:t2", "idea:t3"] {
                #expect(model.regionID(containing: ref) == model.layout.regions.keys.first, "\(ref) is in it")
            }
            // The next answer starts afresh.
            model.showProposals(set(.questionMap, freeTree()), makeIdea: nil, writeIdea: writes.write(model))
            #expect(model.askState.keptTreeIdeas.isEmpty)
            model.receiveProposalMessage("proposalKeep", ["id": "p:n2", "x": 0, "y": 300])
            await model.askState.ideaWrites?.value
            #expect(edges(model).count == 2, "its parent was not kept in this answer")
        }
    }

    @Test("Keep All after some ghosts were kept one at a time writes the rest, hangs them from the Ideas kept before, and draws the region round all of the tree")
    func keepOneThenAll() async throws {
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let writes = Writes()
            model.showProposals(set(.mindMap, freeTree()), makeIdea: nil, writeIdea: writes.write(model))
            model.receiveProposalMessage("proposalKeep", ["id": "p:n1", "x": 300, "y": 0])
            await model.askState.ideaWrites?.value
            #expect(edges(model).isEmpty, "its parent is not an Idea yet")
            model.receiveProposalMessage("proposalLayout", layoutMessage(["p:root": [0, 0], "p:n2": [300, 200], "p:n3": [600, -60], "p:n4": [600, 60]]))
            model.keepAllProposals()
            await model.askState.ideaWrites?.value
            #expect(writes.titles == ["Sensing", "Quality control", "Clearing", "PINK1", "Potential"], "Sensing is not written again")
            #expect(edges(model) == ["idea:t2>idea:t1 tree", "idea:t2>idea:t3 tree", "idea:t1>idea:t4 tree", "idea:t1>idea:t5 tree"])
            let region = try #require(model.layout.regions.values.first)
            #expect(model.layout.regions.count == 1 && region.isTree)
            for ref in (1...5).map({ "idea:t\($0)" }) {
                let placement = try #require(model.layout.placements[ref])
                #expect(placement.x >= region.x && placement.x + model.cardWidth(of: ref) <= region.x + region.w + 0.5, "\(ref) is in the region")
            }
        }
    }

    @Test("A kept Connect proposal that supports or contradicts draws its arrow with that stance, and the others draw none")
    func keepConnectStance() {
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "source:b", x: 400, y: 0), (ref: "source:c", x: 800, y: 0)])
            model.showProposals(KnowledgeMapProposalSet(id: "set", tool: .connect, title: "Connect", anchor: [], proposals: [
                KnowledgeMapProposal(id: "e1", kind: .edge, from: "source:a", to: "source:b", label: "agrees with", relation: "supports"),
                KnowledgeMapProposal(id: "e2", kind: .edge, from: "source:b", to: "source:c", label: "clashes with", relation: "contradicts"),
                KnowledgeMapProposal(id: "e3", kind: .edge, from: "source:a", to: "source:c", label: "measures", relation: "measures"),
            ], createdAt: Date()), makeIdea: nil)
            model.keepAllProposals()
            let stances = Dictionary(uniqueKeysWithValues: model.layout.edges.values.map { ($0.label, $0.stance) })
            #expect(stances == ["agrees with": "supports", "clashes with": "contradicts", "measures": nil])
        }
    }
}
