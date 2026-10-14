import AppKit
import Foundation
import SwiftUI
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

    @Test("The kind the learner says wins: the PINK1 note, not the PINK1 paper the model chose; and the other way round")
    func matchingKinds() {
        let note = CanvasVoice.Card(ref: "idea:n", type: "idea", title: "PINK1 builds up when the potential drops", x: 0, y: 300, w: 240, h: 120, inView: true)
        let context = CanvasVoice.context(snapshot(cards: [
            card("source:p", "PINK1 stabilization recruits Parkin", x: 0, y: 0, inView: true),
            card("source:k", "Parkin is activated by phospho-ubiquitin", x: 300, y: 0, inView: true),
            note,
        ]), said: "put the PINK1 note and the Parkin paper together")
        let wrong = CanvasVoice.Edit(tool: "place_on_canvas", arguments: ["item_ids": ["source:p", "source:k"], "new_region": "Upstream"])
        let fixed = CanvasVoice.matchingKinds(wrong, said: "put the PINK1 note and the Parkin paper together", context: context)
        #expect(fixed.arguments["item_ids"] as? [String] == ["idea:n", "source:k"])
        let paper = CanvasVoice.matchingKinds(
            CanvasVoice.Edit(tool: "take_off_canvas", arguments: ["item_ids": ["idea:n"]]), said: "take the PINK1 paper off", context: context
        )
        #expect(paper.arguments["item_ids"] as? [String] == ["source:p"])
        let right = CanvasVoice.matchingKinds(
            CanvasVoice.Edit(tool: "take_off_canvas", arguments: ["item_ids": ["source:k"]]), said: "take the Parkin paper off", context: context
        )
        #expect(right.arguments["item_ids"] as? [String] == ["source:k"], "already the kind said: left alone")

        // The eval's canvas: the model chose right, and nothing may be swapped.
        let eval = CanvasVoice.context(snapshot(cards: [
            card("source:p_pink1", "PINK1 stabilization on depolarized mitochondria recruits Parkin", x: 30, y: 60, inView: true),
            card("source:p_parkin", "Parkin is activated by PINK1-dependent phosphorylation of ubiquitin", x: 300, y: 60, inView: true),
            card("source:p_mptp", "MPTP toxicity models of parkinsonism", x: 1030, y: 760),
            CanvasVoice.Card(ref: "idea:i_pink1note", type: "idea", title: "PINK1 builds up only when the membrane potential drops", x: 30, y: 230, w: 240, h: 120, inView: true),
            CanvasVoice.Card(ref: "idea:i_q1", type: "idea", title: "Does Parkin act without PINK1?", x: 300, y: 230, w: 240, h: 120, inView: true),
        ]), said: "x")
        let said = "take the review papers off, then put the PINK1 note and the Parkin paper together under a new group called upstream signals, and connect that group to the question about fission"
        let kept = CanvasVoice.matchingKinds(
            CanvasVoice.Edit(tool: "place_on_canvas", arguments: ["item_ids": ["idea:i_pink1note", "source:p_parkin"], "new_region": "upstream signals"]), said: said, context: eval
        )
        #expect(kept.arguments["item_ids"] as? [String] == ["idea:i_pink1note", "source:p_parkin"],
                "a note that also says PINK1 never displaces the Parkin paper when the PINK1 note is already chosen")
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
        #expect(context.message.contains("c3 note \"Waiting\""), "an Idea is listed as the learner says it, a note")
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
        let request = "take the three review papers off the canvas, then put the PINK1 note and the Parkin paper together under a new group called upstream signals"
        #expect(CanvasVoice.context(snapshot(cards: []), said: request).message.hasSuffix("THE LEARNER SAID: \"\(request)\""), "the learner's words are never cut")
        let earlier = CanvasVoice.context(snapshot(cards: []), said: "x", earlier: [CanvasVoice.Turn(said: request, done: [])]).message
        #expect(earlier.contains("\"\(request)\" → nothing changed"))
    }

    @Test("Earlier requests are listed oldest first, at most three, before what the learner said now")
    func earlierRequests() {
        let turns = (1...4).map { CanvasVoice.Turn(said: "request \($0)", done: $0 == 2 ? [] : ["Moved \($0) cards"]) }
        let message = CanvasVoice.context(snapshot(cards: [card("source:a", "A", x: 0, y: 0)]), said: "again", earlier: turns).message
        #expect(!message.contains("\"request 1\""), "only the last three")
        #expect(message.contains("\"request 2\" → nothing changed"))
        #expect(message.contains("\"request 4\" → Moved 4 cards"))
        let order = ["request 2", "request 3", "request 4", "THE LEARNER SAID"].map { message.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        #expect(!CanvasVoice.context(snapshot(cards: []), said: "x").message.contains("EARLIER"))
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
        let grouped = CanvasVoice.Context(message: "", cards: ["c1": "source:a"], regions: ["r1": "rab12"], regionCards: ["rab12": ["source:a", "idea:b"]])
        #expect(CanvasVoice.resolved(["item_ids": ["r1", "c1"]], in: grouped)["item_ids"] as? [String] == ["source:a", "idea:b"], "a region where cards are meant is its cards, each once")
        #expect(CanvasVoice.resolved(["region": "r1"], in: grouped)["region"] as? String == "rab12", "a region where a region is meant stays one")
        let notes = CanvasVoice.resolved(["annotations": ["c1": "why"]], in: context)["annotations"] as? [String: Any]
        #expect(notes?["source:a"] as? String == "why")
        #expect(CanvasVoice.resolved(["dx": 40], in: context)["dx"] as? Int == 40)
        #expect(CanvasVoice.resolved(["color": "Orange"], in: context)["color"] as? String == "#D85A30", "a tint by its name")
        #expect(CanvasVoice.resolved(["color": "red"], in: context)["color"] as? String == "#D85A30", "a colour the canvas lacks, by its nearest")
        #expect(CanvasVoice.resolved(["color": "#378ADD"], in: context)["color"] as? String == "#378ADD")
        #expect(CanvasVoice.resolved(["name": "orange"], in: context)["name"] as? String == "orange", "a name is words, not a colour")
    }

    @Test("What the learner meant wins: cards gathered into a new region unless they said around, an existing region never made twice, a move of nothing skipped")
    func meant() throws {
        typealias E = CanvasVoice.Edit
        let gather = try #require(CanvasVoice.meant(
            E(tool: "create_canvas_region", arguments: ["name": "Fission", "item_ids": ["source:a", "source:b"]]),
            said: "put the fission papers in a region called Fission", regionNames: []
        ))
        #expect(gather.tool == "place_on_canvas" && gather.arguments["new_region"] as? String == "Fission")
        #expect(gather.arguments["item_ids"] as? [String] == ["source:a", "source:b"])
        let around = try #require(CanvasVoice.meant(
            E(tool: "create_canvas_region", arguments: ["name": "Open questions", "item_ids": ["idea:q"]]),
            said: "draw a region called open questions around my question", regionNames: []
        ))
        #expect(around.tool == "create_canvas_region", "around: the frame is drawn where the cards are")
        let existing = try #require(CanvasVoice.meant(
            E(tool: "write_note", arguments: ["text": "fission first", "new_region": "fission"]),
            said: "write a note in fission", regionNames: ["Mitophagy", "Fission"]
        ))
        #expect(existing.arguments["new_region"] == nil && existing.arguments["region"] as? String == "Fission")
        #expect(CanvasVoice.meant(E(tool: "move", arguments: ["region": "", "dx": 0, "dy": 0]), said: "", regionNames: []) == nil)
        #expect(CanvasVoice.meant(E(tool: "move", arguments: ["item_ids": ["c1"], "dx": -120, "dy": 0]), said: "", regionNames: []) != nil)
        #expect(CanvasVoice.meant(E(tool: "move", arguments: ["item_ids": ["c1"], "right_of": "c2"]), said: "", regionNames: []) != nil,
                "a move to a side has no distance and is not nothing")
        let row = CanvasVoice.meant(E(tool: "arrange_on_canvas", arguments: ["item_ids": ["c1", "c2"], "arrangement": "grid"]),
                                    said: "line up the mitophagy papers in a row", regionNames: [])
        #expect(row?.arguments["arrangement"] as? String == "row", "the arrangement the learner named")
        let tidy = CanvasVoice.meant(E(tool: "arrange_on_canvas", arguments: ["item_ids": ["c1", "c2"], "arrangement": "grid"]),
                                     said: "tidy these up", regionNames: [])
        #expect(tidy?.arguments["arrangement"] as? String == "grid", "none named: the model's")
        let align = CanvasVoice.meant(E(tool: "arrange_on_canvas", arguments: ["item_ids": ["c1", "c2"], "align": "top"]),
                                      said: "align the cards in the left column to the top", regionNames: [])
        #expect(align?.arguments["arrangement"] == nil, "an alignment alone stays an alignment")
        let nudge = CanvasVoice.meant(E(tool: "move", arguments: ["item_ids": ["idea:n"], "left_of": "source:p"]), said: "move the PINK1 note to the left", regionNames: [])
        #expect(nudge?.arguments["left_of"] == nil && nudge?.arguments["dx"] as? Double == -300, "no card named: a nudge to the left")
        let named = CanvasVoice.meant(E(tool: "move", arguments: ["item_ids": ["idea:n"], "left_of": "source:p"]), said: "move the note to the left of the Parkin paper", regionNames: [])
        #expect(named?.arguments["left_of"] as? String == "source:p", "a card named: that side of it")
        let into = CanvasVoice.meant(E(tool: "move", arguments: ["item_ids": ["source:p"], "region": "rdyn"]), said: "move the pink one paper into the fission group", regionNames: [])
        #expect(into?.tool == "place_on_canvas" && into?.arguments["region"] as? String == "rdyn", "cards and a region, no distance: into the region")
        #expect(CanvasVoice.meant(E(tool: "align_on_canvas", arguments: ["item_ids": ["c1", "c2"], "align": "top"]), said: "", regionNames: [])?.tool == "arrange_on_canvas")
        let shorthand = CanvasVoice.meant(E(tool: "align", arguments: ["item_ids": ["c1", "c2"], "align": "top"]), said: "align these to the top", regionNames: [])
        #expect(shorthand?.tool == "arrange_on_canvas" && shorthand?.arguments["align"] as? String == "top", "an edit written by what it does is the edit")
        let beside = CanvasVoice.meant(E(tool: "move", arguments: ["item_ids": ["source:a"], "beside": "idea:b"]), said: "", regionNames: [])
        #expect(beside?.tool == "place_on_canvas" && beside?.arguments["beside"] as? String == "idea:b", "a move beside a card is the placement beside it")
    }

    @Test("Of two requests, the first to say a word is carried out and the other is stopped")
    func race() async {
        let race = CanvasVoice.Race()
        let slow = Task<Error?, Never> {
            do { try await Task.sleep(for: .seconds(30)); return nil } catch { return error }
        }
        race.add(slow, as: 1)
        let quick = Task<Error?, Never> { nil }
        race.add(quick, as: 2)
        #expect(race.attempts == 2)
        #expect(race.claim(2), "the first word wins")
        #expect(race.claim(2), "and keeps winning")
        #expect(!race.claim(1), "the slow one's words are dropped")
        #expect(await slow.value is CancellationError, "and it is stopped")
        let late = Task<Error?, Never> {
            do { try await Task.sleep(for: .seconds(30)); return nil } catch { return error }
        }
        race.add(late, as: 3)
        #expect(await late.value is CancellationError, "a request added after the race is won is stopped at once")
        #expect(race.won == 2)
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
        for local in ["move", "write_note", "find_and_place", "ask_canvas", "open_card", "say"] {
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
            let before = model.newestUndoStep
            model.beginEditGroup()
            model.place([(ref: "source:b", x: 300, y: 0)])
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.place([(ref: "source:c", x: 600, y: 0)])
            model.endEditGroup()
            let step = model.newestUndoStep
            #expect(step != nil && step != before, "the request is a step of its own, which the capsule's Undo looks for")
            model.undo()
            #expect(model.newestUndoStep == before, "once undone, the newest step is the learner's own again")
            #expect(model.layout.placements["source:b"] == nil && model.layout.placements["source:c"] == nil, "the request goes in one Undo")
            #expect(model.layout.placements["source:a"] != nil, "the learner's own edit just before stays")
            model.undo()
            #expect(model.layout.placements["source:a"] == nil)
        }
    }
}

@Suite("Canvas voice: the capsule as it draws")
@MainActor
struct CanvasVoiceCapsuleTests {
    @Test("In every state the capsule stays one bar: no taller than two lines, no wider than its 560")
    func capsuleSizes() throws {
        let voice = KnowledgeMapVoice.shared
        defer { voice.stop() }
        let long = "put the three papers about PINK1 and Parkin together under a new group called Upstream signals and connect it to the question about fission"
        let states: [(String, () -> Void)] = [
            ("listening", { voice.debugShow(.listening) }),
            ("hearing-words", { voice.debugShow(.listening, heard: long) }),
            ("changing", { voice.debugShow(.changing, heard: long) }),
            ("done-undo", { voice.debugShow(.done, heard: long, changes: ["Grouped 3 cards as “Upstream signals”", "Drew an arrow"], offersUndo: true) }),
            ("failed-mic", { voice.debugShow(.failed("Microphone access is required to speak to the canvas."), needsMicrophone: true) }),
        ]
        let folder = ProcessInfo.processInfo.environment["FOREVERLM_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        var widths: [String: CGFloat] = [:]
        for (name, show) in states {
            show()
            let size = try #require(ImageRenderer(content: KnowledgeMapVoiceCapsule()).nsImage, "\(name)").size
            widths[name] = size.width
            #expect(size.width <= 560 && size.height <= 60, "\(name) is \(size.width) by \(size.height)")
            guard let folder else { continue }
            let renderer = ImageRenderer(content: KnowledgeMapVoiceCapsule().padding(20).background(Color(white: 0.92)).frame(width: 700))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent("capsule-\(name).png"))
            }
        }
        #expect((widths["listening"] ?? 560) < 400, "a short line is a short bar, not one spread to the cap")
    }
}

