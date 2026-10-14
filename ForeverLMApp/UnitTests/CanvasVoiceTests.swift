import Foundation
import Testing
@testable import ForeverLM

// Speaking to the Canvas (Shared/Models/CanvasVoice.swift, App/KnowledgeMapVoice.swift):
// what the model is told, how its streamed answer is read, how its short ids
// become the canvas's own, and that a spoken request is one Undo step.

@Suite("Canvas voice: what the model reads and how its answer is read")
struct CanvasVoiceTests {
    private func card(_ ref: String, _ title: String, x: Double, y: Double, region: String? = nil, inView: Bool = false, selected: Bool = false) -> CanvasVoice.Card {
        CanvasVoice.Card(ref: ref, type: "paper", title: title, x: x, y: y, w: 240, h: 120, regionID: region, inView: inView, selected: selected)
    }

    private func snapshot(cards: [CanvasVoice.Card], regions: [CanvasVoice.Region] = [], arrows: [CanvasVoice.Arrow] = [], waiting: [CanvasVoice.Card] = []) -> CanvasVoice.Snapshot {
        CanvasVoice.Snapshot(
            canvasName: "Mitochondria",
            viewCenterX: 0, viewCenterY: 0, viewWidth: 1600, viewHeight: 1000,
            selectedRegionID: nil,
            cards: cards, regions: regions, arrows: arrows, waiting: waiting
        )
    }

    @Test("Cards are listed selected first, then in view, then nearest the view's middle, each with a short id")
    func listingOrder() {
        let context = CanvasVoice.context(snapshot(cards: [
            card("source:far", "Far", x: 5000, y: 5000),
            card("source:near", "Near", x: 300, y: 0),
            card("source:seen", "Seen", x: 900, y: 0, inView: true),
            card("source:chosen", "Chosen", x: 4000, y: 0, selected: true),
        ]), said: "group these")
        #expect(context.cards == ["c1": "source:chosen", "c2": "source:seen", "c3": "source:near", "c4": "source:far"])
        #expect(context.message.contains("SELECTED: c1"))
        #expect(context.message.contains("c2 paper \"Seen\" 900,0 240×120 in view"))
        #expect(context.message.hasSuffix("THE LEARNER SAID: \"group these\""))
    }

    @Test("Regions are r1 and on in reading order; arrows and a card's region use the short ids; waiting cards follow the placed ones")
    func regionsArrowsWaiting() {
        let context = CanvasVoice.context(snapshot(
            cards: [card("source:a", "A", x: 0, y: 500, region: "rlow"), card("idea:b", "B", x: 0, y: 0)],
            regions: [
                CanvasVoice.Region(id: "rlow", name: "Lower", x: 0, y: 400, w: 600, h: 400, cardCount: 1),
                CanvasVoice.Region(id: "rtop", name: "", x: 0, y: -400, w: 600, h: 300, cardCount: 0),
            ],
            arrows: [
                CanvasVoice.Arrow(from: "idea:b", to: "source:a", label: "explains"),
                CanvasVoice.Arrow(from: "region:rtop", to: "idea:b", label: ""),
                CanvasVoice.Arrow(from: "source:gone", to: "idea:b", label: "dropped: an end not listed"),
            ],
            waiting: [CanvasVoice.Card(ref: "idea:w", type: "idea", title: "Waiting")]
        ), said: "x")
        #expect(context.regions == ["r1": "rtop", "r2": "rlow"])
        #expect(context.message.contains("r1 \"Untitled region\" 0,-400 600×300 0"))
        #expect(context.message.contains("\"A\" 0,500 240×120 r2"))
        #expect(context.message.contains("c1 → c2 \"explains\"") || context.message.contains("c2 → c1 \"explains\""))
        #expect(context.message.contains("r1 → "))
        #expect(!context.message.contains("dropped"))
        #expect(context.cards["c3"] == "idea:w")
        #expect(context.message.contains("c3 idea \"Waiting\""))
    }

    @Test("A long title is cut, quotes and line breaks are tamed, and a canvas past the limit says how many it left out")
    func titlesAndLimit() {
        let long = String(repeating: "x", count: 200)
        var cards = [card("source:long", "Line one\n\"quoted\" " + long, x: 0, y: 0)]
        for index in 0..<CanvasVoice.maximumCards { cards.append(card("source:\(index)", "T\(index)", x: Double(index) * 10 + 100, y: 0)) }
        let context = CanvasVoice.context(snapshot(cards: cards), said: "tidy")
        let line = context.message.split(separator: "\n").first { $0.contains("Line one") }
        #expect(line?.contains("'quoted'") == true)
        #expect(line?.contains("…") == true)
        #expect(context.cards.count == CanvasVoice.maximumCards)
        #expect(context.message.contains("(1 more cards, far from the view, are not listed)"))
    }

    @Test("The stream is cut into whole lines across deltas, and the last line needs no newline")
    func lineReader() {
        let reader = CanvasVoice.LineReader()
        #expect(reader.feed("{\"tool\":\"und").isEmpty)
        #expect(reader.feed("o_canvas\"}\n{\"tool\"") == ["{\"tool\":\"undo_canvas\"}"])
        #expect(reader.feed(":\"say\",\"text\":\"hi\"}\n\n") == ["{\"tool\":\"say\",\"text\":\"hi\"}", ""])
        #expect(reader.feed("{\"tool\":\"move\"}").isEmpty)
        #expect(reader.finish() == ["{\"tool\":\"move\"}"])
        #expect(reader.finish().isEmpty)
    }

    @Test("A line is an edit with its arguments, blank, or unreadable; a nested argument object, a list marker and a trailing comma are read too")
    func lines() throws {
        guard case .edit(let edit) = CanvasVoice.line(#"{"tool":"arrange_on_canvas","item_ids":["c1","c2"],"arrangement":"row"}"#) else {
            Issue.record("not an edit"); return
        }
        #expect(edit.tool == "arrange_on_canvas")
        #expect(edit.arguments["tool"] == nil)
        #expect(edit.arguments["item_ids"] as? [String] == ["c1", "c2"])
        guard case .edit(let nested) = CanvasVoice.line(#"- {"tool":"move","arguments":{"item_ids":["c1"],"dx":-300}},"#) else {
            Issue.record("nested not read"); return
        }
        #expect(nested.tool == "move" && (nested.arguments["dx"] as? NSNumber)?.doubleValue == -300)
        if case .blank = CanvasVoice.line("```json") {} else { Issue.record("a fence is blank") }
        if case .blank = CanvasVoice.line("   ") {} else { Issue.record("spaces are blank") }
        if case .unreadable = CanvasVoice.line("Sure, here are the edits:") {} else { Issue.record("prose is unreadable") }
        if case .unreadable = CanvasVoice.line(#"{"item_ids":["c1"]}"#) {} else { Issue.record("no tool is unreadable") }
        guard case .edit(let said) = CanvasVoice.line(#"{"say":"Which one?"}"#), said.tool == "say", said.arguments["text"] as? String == "Which one?" else {
            Issue.record("{\"say\": …} is a say"); return
        }
        guard case .edit(let keyed) = CanvasVoice.line(#"{"move":{"item_ids":["c2"],"dx":40}}"#), keyed.tool == "move", keyed.arguments["item_ids"] as? [String] == ["c2"] else {
            Issue.record("an edit named by its one key is read"); return
        }
    }

    @Test("Short ids become the canvas's own: cards, a region by id (region:<id> for an arrow's end); names, labels and words stay as written")
    func resolving() {
        let context = CanvasVoice.Context(message: "", cards: ["c1": "source:a", "c2": "idea:b"], regions: ["r1": "rab12"])
        let place = CanvasVoice.resolved(["item_ids": ["c1", "c2", "c9"], "region": "r1", "beside": "c2", "new_region": "c1"], in: context)
        #expect(place["item_ids"] as? [String] == ["source:a", "idea:b", "c9"])
        #expect(place["region"] as? String == "rab12")
        #expect(place["beside"] as? String == "idea:b")
        #expect(place["new_region"] as? String == "c1", "a new region's name is the learner's words")
        let arrow = CanvasVoice.resolved(["from": "r1", "to": "c1", "label": "r1"], in: context)
        #expect(arrow["from"] as? String == "region:rab12")
        #expect(arrow["to"] as? String == "source:a")
        #expect(arrow["label"] as? String == "r1")
        #expect(CanvasVoice.resolved(["from": "region:r1"], in: context)["from"] as? String == "region:rab12")
        #expect(CanvasVoice.resolved(["region": "Biology"], in: context)["region"] as? String == "Biology", "a region by its name")
        let notes = CanvasVoice.resolved(["annotations": ["c1": "why"]], in: context)["annotations"] as? [String: Any]
        #expect(notes?["source:a"] as? String == "why")
        #expect(CanvasVoice.resolved(["dx": 40], in: context)["dx"] as? Int == 40)
        #expect(CanvasVoice.resolved(["color": "Orange"], in: context)["color"] as? String == "#D85A30", "a tint by its name")
        #expect(CanvasVoice.resolved(["color": "red"], in: context)["color"] as? String == "#D85A30", "a colour the canvas lacks, by its nearest")
        #expect(CanvasVoice.resolved(["color": "#378ADD"], in: context)["color"] as? String == "#378ADD")
        #expect(CanvasVoice.resolved(["name": "orange"], in: context)["name"] as? String == "orange", "a name is words, not a colour")
    }

    @Test("The request asks for the model's lowest effort, and for none when it offers none")
    func quickestEffort() {
        #expect(CanvasVoice.quickestEffort([.high, .low, .medium]) == .low)
        #expect(CanvasVoice.quickestEffort([.max, .noReasoning]) == .noReasoning)
        #expect(CanvasVoice.quickestEffort([]) == nil)
    }
}

@Suite("Canvas voice: the edits the model may write")
@MainActor
struct CanvasVoiceReferenceTests {
    @Test("Every canvas tool it names is an MCP tool, with its arguments from the tool's schema, required first, ids it never sees left out")
    func reference() {
        let reference = KnowledgeMapVoice.operationsReference
        for (name, _) in KnowledgeMapVoice.toolLines {
            #expect(reference.contains("- \(name)("), "\(name) is in the reference")
        }
        #expect(reference.contains("- place_on_canvas(item_ids: [string], "))
        #expect(reference.contains("face?: \"page\"|\"card\""))
        #expect(reference.contains("arrangement?: \"row\"|\"column\"|\"grid\""))
        #expect(!reference.contains("notebook_id") && !reference.contains("edge_id"))
        for local in ["move", "write_note", "find_and_place", "say"] {
            #expect(reference.contains("- \(local)("))
        }
        #expect(KnowledgeMapVoice.operationsReference == reference, "built once, the same every time")
    }
}

@Suite("Canvas voice: one spoken request is one Undo step")
@MainActor
struct CanvasVoiceUndoTests {
    @Test("Edits inside a group join its first however far apart they come; the group's first never joins the learner's edit before it")
    func editGroup() {
        let suite = UserDefaults(suiteName: "CanvasVoiceUndoTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(
                articles: ["a", "b", "c"].map { StudioArticle(url: "https://example.com/\($0)", title: "Paper \($0)", sourceType: .paper, id: $0) },
                ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:]
            )
            model.place([(ref: "source:a", x: 0, y: 0)])
            model.beginEditGroup()
            model.place([(ref: "source:b", x: 300, y: 0)])
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.place([(ref: "source:c", x: 600, y: 0)])
            model.endEditGroup()
            model.undo()
            #expect(model.layout.placements["source:b"] == nil && model.layout.placements["source:c"] == nil, "the request goes in one Undo")
            #expect(model.layout.placements["source:a"] != nil, "the learner's own edit just before stays")
            model.undo()
            #expect(model.layout.placements["source:a"] == nil)
        }
    }
}
