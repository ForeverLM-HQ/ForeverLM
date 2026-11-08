#if os(macOS)
import Foundation
import ImageIO

// MARK: - The Canvas's Heptabase parity build over MCP (2026-10-09)
//
// What an assistant can do to the learner's Canvas that Heptabase's own CLI
// can: restyle cards (`update_canvas_card`), tidy and align a selection
// (`arrange_on_canvas`), check the layout (`lint_canvas`) and look at it
// (`screenshot_canvas`), beside the arrow, region and `build_canvas` fields
// in MCPTools+KnowledgeMap.swift. Every edit is the learner's own, one Undo
// step, on their word (docs/knowledge-map-design.md, "Over MCP"); the two
// that only look change nothing.

extension MCPToolRegistry {
    private static var onTheirWord: String {
        "Only on the learner's word: the Canvas is where they think, so never arrange it on your own initiative; to suggest an arrangement, show a lens (apply_map_lens) or ask_canvas. Each call is one edit of theirs, which Undo (⌘Z, or undo_canvas) takes back."
    }

    static var canvasParityToolDefs: [MCPToolDef] {
        let itemIDs: (Int, Int) -> [String: Any] = { minimum, maximum in
            [
                "type": "array",
                "items": ["type": "string"],
                "description": "Cards by item_id as get_knowledge_map gives them: source:<source_id>, doc:<doc_id>, idea:<idea_id>, canvas:<canvas_id>, chat:<session_id>, picture:<image_id>, clip:<id> or page:<source_id>:<n>. A bare source, Doc or Idea id is accepted too.",
                "minItems": minimum,
                "maxItems": maximum,
            ]
        }
        return [
            MCPToolDef(
                name: "update_canvas_card",
                description: "Change how cards already on the learner's Canvas look, as their right-click menu and handles do: tint them (color), fold them to their title line (folded true; false opens them), give them a width or height of their own (w from 160 to 720 and h from 56 to 2000, in the Canvas's own units; a card is 240 by 120 unless its kind says otherwise), or give them back the size their kind has (fit_to_content true: the width and height they were given are cleared). Beyond the look: show a source as a page of its PDF (page, one-based, drawn as the card with its title and authors under it, as a paper placed for the first time is; 0 shows the usual card again; a page past the PDF's end is its last; sources only), write the learner's words about why a card is on this canvas under it (annotation, at most 600 characters, an empty string takes it off; any card but an Idea, whose own note holds its words, so change an Idea's with update_idea), draw an Idea as plain words with no sticky note (plain true; false brings the note back; Ideas only) and mark a question, an Idea whose title ends with ?, answered or open again (answered; questions only). One call changes every card named; a region that holds a card made wider or taller than it is grows to hold it. Cards not on the Canvas are listed and left alone (place_on_canvas sets them down first). get_knowledge_map gives each card's rect and what it has been given. \(onTheirWord) Returns the cards as they now are.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": itemIDs(1, 200),
                        "color": [
                            "type": "string",
                            "description": "A tint as #RRGGBB (the Canvas's own eight: #7F77DD, #1D9E75, #D85A30, #D4537E, #BA7517, #378ADD, #639922, #888780), or an empty string to give the card its kind's own tint again.",
                        ],
                        "folded": [
                            "type": "boolean",
                            "description": "Fold the cards to their title line (true) or open them again (false).",
                        ],
                        "w": [
                            "type": "number",
                            "description": "The cards' width, 160 to 720.",
                        ],
                        "h": [
                            "type": "number",
                            "description": "The cards' height, 56 to 2000.",
                        ],
                        "fit_to_content": [
                            "type": "boolean",
                            "description": "Clear the width and height the cards were given, so each is the size its kind has (an Idea grows with its text, a clip, page or picture is as tall as its picture). Not with w or h.",
                        ],
                        "page": [
                            "type": "integer",
                            "description": "Show these sources as this page of their PDF (one-based), or 0 to show the usual card again. Sources only; a page past the end of the PDF is its last.",
                        ],
                        "annotation": [
                            "type": "string",
                            "description": "The learner's words about why these cards are on this canvas, drawn under them: at most 600 characters. An empty string takes them off. Not for an Idea.",
                        ],
                        "plain": [
                            "type": "boolean",
                            "description": "Draw these Ideas as plain words with no sticky note (true), or as notes again (false). Ideas only.",
                        ],
                        "answered": [
                            "type": "boolean",
                            "description": "Mark these questions (Ideas whose title ends with ?) answered (true) or open again (false). Questions only.",
                        ],
                    ] as [String: Any],
                    "required": ["item_ids"],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "arrange_on_canvas",
                description: "Tidy or align cards already on the learner's Canvas, as Tidy Up and Align in its right-click menu do. arrangement lays the cards out as a row (left to right), a column (top to bottom) or a grid (about half again as wide as tall), taking them in reading order of where they sit now, each by its own width and height, 30 apart, with the selection's top left staying where it is. align then moves every card to the selection's left, center (the middle of its width), right, top, middle (the middle of its height) or bottom, by its own size; with both, the arrangement comes first. A region that held a card grows to hold it where it lands. Pass arrangement, align or both, and at least two cards that are on the Canvas; a card in a locked region is not moved: a call naming one is refused whole (unlock the region with update_canvas_region first). \(onTheirWord) Returns how many cards moved and the cards as they now are, each with its rect.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": itemIDs(2, 200),
                        "arrangement": [
                            "type": "string",
                            "enum": ["row", "column", "grid"],
                            "description": "Lay the cards out as a row, a column or a grid.",
                        ],
                        "align": [
                            "type": "string",
                            "enum": ["left", "center", "right", "top", "middle", "bottom"],
                            "description": "Then align them on this edge or middle of the selection's bounds.",
                        ],
                    ] as [String: Any],
                    "required": ["item_ids"],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "lint_canvas",
                description: "Check the learner's Canvas for layout faults, as Heptabase's lint does, before telling them a layout is done: cards drawn over one another (overlap), a card whose middle is in a region but whose edge crosses the region's (card_outside_region), an arrow that runs across a card it does not join (arrow_over_card; a default arrow is judged by the curve the Canvas draws, which bends round the cards in its way, and a straight or elbow arrow, or one drawn into a brace with others, by the straight line between the middles of its ends) and a region that holds no card and no region (empty_region; a notebook's frame is never empty). A card in a region folded up is not drawn and is not checked. Changes nothing. Each issue has its kind, a one-line message, the cards it is about (item_ids) and the region_id or edge_id; get_knowledge_map gives each card's rect, and a fault can be mended with arrange_on_canvas, update_canvas_card, update_canvas_region (fit_to_content, grow_to_hold) or place_on_canvas. Call it after build_canvas or any layout you made, then screenshot_canvas to look at it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "Most issues listed (default 100, at most 500); issue_count is the whole number.",
                        ],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "screenshot_canvas",
                description: "Take a picture of the learner's Canvas as the Canvas draws it: the whole plane, or just the bounds of item_ids, at scale times its size (1 by default, 0.1 to 4; a picture is held to 8,192 pixels a side), without the selection, handles or controls. The PNG is saved under Exports/ in ForeverLM's library folder and returned as file_path with its width and height, and attached as an image when it is small enough to send (4 MB). Needs the Canvas showing on the Mac (build_canvas, open_canvas and focus_map show it), and changes nothing on it. Look at it after laying cards out, with lint_canvas, to check what words cannot.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "scale": [
                            "type": "number",
                            "description": "How large to draw it, as a multiple of its size on the plane (default 1, 0.1 to 4).",
                        ],
                        "item_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Draw only the bounds of these cards (on the Canvas), by item_id as get_knowledge_map gives them. Omit for the whole plane.",
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            ),
        ]
    }
}

extension MCPDataStore {
    // MARK: Reading a call's words

    /// A number from a call, not a boolean (JSON's `true` is a number to Foundation).
    static func canvasNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// A width or a height from a call, within what a card may be.
    static func cardSize(_ value: Any?, named name: String, in range: ClosedRange<Double>) throws -> Double? {
        guard value != nil, !(value is NSNull) else { return nil }
        guard let number = canvasNumber(value), number.isFinite, range.contains(number) else {
            throw MCPError.invalidInput("\(name) is a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)).")
        }
        return number
    }

    /// A card's tint from a call: nothing leaves it as it is, an empty string
    /// gives it its kind's own, anything else is `#RRGGBB`.
    static func cardColorChange(_ value: Any?) throws -> KnowledgeMapFieldChange<String> {
        guard let raw = value as? String else { return .keep }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .clear }
        guard trimmed.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            throw MCPError.invalidInput("A card's color is #RRGGBB, such as #1D9E75, or an empty string for its own tint.")
        }
        return .set(trimmed.uppercased())
    }

    /// The look a `place_on_canvas` call gives the cards it sets down; nil
    /// when it names none.
    static func cardStyle(from arguments: [String: Any]) throws -> KnowledgeMapCardStyle? {
        var style = KnowledgeMapCardStyle()
        style.w = try cardSize(arguments["w"], named: "w", in: KnowledgeMap.cardWidthRange)
        style.h = try cardSize(arguments["h"], named: "h", in: KnowledgeMap.cardHeightRange)
        if let folded = arguments["folded"] as? Bool, folded { style.folded = true }
        if case .set(let color) = try cardColorChange(arguments["color"]) { style.color = color }
        if let raw = (arguments["face"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            switch raw {
            case "page": style.page = 1
            case "card": style.page = 0
            default: throw MCPError.invalidInput("face is page or card, not \"\(raw)\".")
            }
        }
        return style.isEmpty ? nil : style
    }

    /// A card's page from a call: nothing leaves it as it is, 0 shows the
    /// usual card, a whole number of one or more is that page of a source's PDF.
    static func cardPageChange(_ value: Any?) throws -> KnowledgeMapFieldChange<Int> {
        guard value != nil, !(value is NSNull) else { return .keep }
        guard let number = canvasNumber(value), number >= 0, let page = Int(exactly: number) else {
            throw MCPError.invalidInput("page is a page number from 1, or 0 to show the usual card again.")
        }
        return page == 0 ? .clear : .set(page)
    }

    /// The words a call gives a card: nothing leaves them as they are, an empty
    /// text takes them off, else at most `KnowledgeMap.annotationLimit` characters.
    static func cardAnnotationChange(_ value: Any?) throws -> KnowledgeMapFieldChange<String> {
        guard value != nil, !(value is NSNull) else { return .keep }
        guard let raw = value as? String else { throw MCPError.invalidInput("annotation is text, or an empty string to take it off.") }
        return try cardAnnotation(raw).map { .set($0) } ?? .clear
    }

    /// Some words for a card, trimmed: nil for an empty text; a text past the
    /// limit is refused rather than cut.
    static func cardAnnotation(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= KnowledgeMap.annotationLimit else {
            throw MCPError.invalidInput("An annotation is at most \(KnowledgeMap.annotationLimit) characters; this one is \(trimmed.count).")
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `annotations` of a call, by card: `{item_id: words}` with each card
    /// one of `refs` (the cards the call sets down) and not an Idea, whose own
    /// note holds its words. Empty words write nothing.
    @MainActor
    static func annotationWords(_ value: Any?, among refs: [String], in map: KnowledgeMapModel) throws -> [String: String] {
        guard value != nil, !(value is NSNull) else { return [:] }
        guard let given = value as? [String: Any] else {
            throw MCPError.invalidInput("annotations is an object of item_id to words.")
        }
        var words: [String: String] = [:]
        for (key, raw) in given.sorted(by: { $0.key < $1.key }) {
            guard let text = raw as? String else { throw MCPError.invalidInput("The annotation for \(key) is text.") }
            guard let ref = cardRefs([key], in: map).known.first else {
                throw MCPError.notFound("annotations names \(key), which is not in the library.")
            }
            guard refs.contains(ref) else {
                throw MCPError.invalidInput("annotations names \(key), which this call does not set down.")
            }
            guard KnowledgeMap.ItemRef(ref)?.kind != .idea else {
                throw MCPError.invalidInput("An Idea's own note holds its words, so “\(map.title(of: ref))” takes no annotation; change an Idea's note with update_idea.")
            }
            if let cleaned = try cardAnnotation(text) { words[ref] = cleaned }
        }
        return words
    }

    /// An arrow's stance from a call: nil when it names none, an empty string
    /// takes it off, else `supports` or `contradicts`.
    static func edgeStance(_ value: Any?) throws -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        guard raw.isEmpty || KnowledgeMapEdgeStance(rawValue: raw) != nil else {
            throw MCPError.invalidInput("stance is supports or contradicts, or an empty string to take it off, not \"\(raw)\".")
        }
        return raw
    }

    /// An arrow's route from a call; nil when it names none.
    static func edgeRoute(_ value: Any?) throws -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        guard KnowledgeMapEdgeRoute(rawValue: raw) != nil else {
            throw MCPError.invalidInput("route is curve, straight or elbow, not \"\(raw)\".")
        }
        return raw
    }

    /// Where an arrow's heads are, from a call; nil when it names none.
    static func edgeHeads(_ value: Any?) throws -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        guard KnowledgeMapEdgeHeads(rawValue: raw) != nil else {
            throw MCPError.invalidInput("heads is end, both or none, not \"\(raw)\".")
        }
        return raw
    }

    /// An arrow's colour from a call: nil when it names none, an empty string
    /// for the usual one, else `#RRGGBB`.
    static func edgeColor(_ value: Any?) throws -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard raw.isEmpty || raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            throw MCPError.invalidInput("An arrow's color is #RRGGBB, such as #1D9E75.")
        }
        return raw.uppercased()
    }

    // MARK: Entries a call answers with

    /// An arrow's end as the Canvas knows it: a card, or a region.
    @MainActor
    static func endEntry(_ ref: String, in map: KnowledgeMapModel) -> [String: Any] {
        guard let id = KnowledgeMap.regionID(fromRef: ref) else { return card(ref, in: map) }
        let name = map.layout.regions[id]?.name ?? ""
        return ["item_id": ref, "kind": "region", "region_id": id, "title": name.isEmpty ? "Untitled region" : name]
    }

    /// An arrow with its ends and its look; a part it has by default is left out.
    @MainActor
    static func arrowEntry(_ id: String, in map: KnowledgeMapModel) -> [String: Any] {
        guard let edge = map.layout.edges[id] else { return ["edge_id": id, "deleted": true] }
        var arrow: [String: Any] = ["edge_id": id, "from": endEntry(edge.from, in: map), "to": endEntry(edge.to, in: map)]
        if !edge.label.isEmpty { arrow["label"] = edge.label }
        if let route = edge.route { arrow["route"] = route }
        if edge.isDashed { arrow["dashed"] = true }
        if let heads = edge.heads { arrow["heads"] = heads }
        if let color = edge.color { arrow["color"] = color }
        if edge.isTree { arrow["tree"] = true }
        if let stance = edge.knownStance { arrow["stance"] = stance.rawValue }
        return arrow
    }

    /// An arrow's end from a call: a card by item_id, or a region as
    /// `region:<region_id or name>`. A card must be on the Canvas.
    @MainActor
    static func arrowEnd(_ raw: Any?, named field: String, in map: KnowledgeMapModel) throws -> String {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MCPError.invalidInput("\(field) needs a card's item_id, or region:<region_id>.")
        }
        if text.hasPrefix(KnowledgeMap.regionRefPrefix) {
            let named = String(text.dropFirst(KnowledgeMap.regionRefPrefix.count))
            return KnowledgeMap.regionRef(try regionID(named, in: map))
        }
        return try cardRef(text, named: field, in: map)
    }

    // MARK: Map-level helpers

    /// A ref as the map knows it: a bare id is a source when the map has that
    /// source, else a Doc, else an Idea.
    @MainActor
    static func resolved(_ ref: KnowledgeMap.ItemRef, in map: KnowledgeMapModel) -> KnowledgeMap.ItemRef {
        if map.nodesByRef[ref.description] != nil { return ref }
        for kind in [KnowledgeMap.ItemKind.doc, .idea] {
            let other = KnowledgeMap.ItemRef(kind: kind, id: ref.id)
            if map.nodesByRef[other.description] != nil { return other }
        }
        return ref
    }


    @MainActor
    static func card(_ ref: String, in map: KnowledgeMapModel) -> [String: Any] {
        var card: [String: Any] = ["item_id": ref, "title": map.title(of: ref)]
        // What kind of card it is, and the id of what it stands for when that
        // is not a source, a Doc or an Idea.
        if let item = KnowledgeMap.ItemRef(ref) {
            card["kind"] = item.kind.rawValue
            switch item.kind {
            case .canvas: card["canvas_id"] = item.id
            case .chat: card["session_id"] = item.id
            case .picture: card["image_id"] = item.id
            case .source, .doc, .idea, .clip, .page: break
            }
        }
        // Where a placed card is and the size it is drawn at, and what the
        // learner gave it: a width or a height, a fold, a tint.
        if let placement = map.layout.placements[ref] {
            card["rect"] = ["x": placement.x, "y": placement.y, "w": map.cardWidth(of: ref), "h": map.cardHeight(of: ref)]
            if let w = placement.w { card["w"] = w }
            if let h = placement.h { card["h"] = h }
            if placement.isFolded { card["folded"] = true }
            if let color = placement.color { card["color"] = color }
            // A source drawn as a page of its PDF says which page, and how many
            // the PDF has once this Mac has read it; the learner's words and an
            // Idea's marks are what is not default.
            if let page = placement.page, let item = KnowledgeMap.ItemRef(ref), item.kind == .source {
                card["page"] = page
                if let pages = map.pageFaces[item.id]?.pageCount, pages > 0 { card["pages"] = pages }
            }
            if let annotation = placement.annotation { card["annotation"] = annotation }
            if placement.isPlain { card["plain"] = true }
            if placement.isAnswered, KnowledgeMap.isQuestion(map.title(of: ref)) { card["answered"] = true }
        }
        // A question is an Idea whose title ends with a question mark.
        if ref.hasPrefix("idea:"), KnowledgeMap.isQuestion(map.title(of: ref)) { card["question"] = true }
        // A clip (clip:<highlight_id>) says where it was cut from: the source,
        // the page, and the picture as a link the chat can show.
        // A page (page:<source_id>:<n>) says which page of which source.
        if let parts = KnowledgeMap.ItemRef(ref)?.pageParts {
            card["source_id"] = parts.sourceID
            card["page"] = parts.page
        }
        // A talk's slide (Lay Out the Talk) says which slide of which video.
        if let item = KnowledgeMap.ItemRef(ref), item.kind == .clip, let clip = map.clips[item.id],
           let reference = ReaderClip.reference(of: clip) {
            card["source_id"] = clip.sourceID
            switch reference.location {
            case .page(let page): card["page"] = page
            case .slide(let slide): card["slide"] = slide
            default: break
            }
            card["picture"] = reference.markdown(alt: ReaderClip.title(of: clip))
            if clip.hasNote { card["note"] = clip.note }
        }
        return card
    }


    /// The library refs `raw` names, resolved as the map knows them, and the
    /// ones the library does not hold.
    @MainActor
    static func cardRefs(_ raw: [String], in map: KnowledgeMapModel) -> (known: [String], unknown: [String]) {
        var known: [String] = []
        var unknown: [String] = []
        for id in raw {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let ref = resolved(KnowledgeMap.ItemRef(trimmed) ?? KnowledgeMap.ItemRef(kind: .source, id: trimmed), in: map).description
            if map.nodesByRef[ref] == nil { unknown.append(trimmed) } else if !known.contains(ref) { known.append(ref) }
        }
        return (known, unknown)
    }


    @MainActor
    static func cardRef(_ raw: Any?, named field: String, in map: KnowledgeMapModel) throws -> String {
        guard let raw = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw MCPError.invalidInput("\(field) needs a card's item_id.")
        }
        guard let ref = cardRefs([raw], in: map).known.first else {
            throw MCPError.notFound("No card in the library is \(raw).")
        }
        return ref
    }


    /// A region by id, by name, or a notebook's frame by its notebook's name.
    @MainActor
    static func regionID(_ raw: Any?, in map: KnowledgeMapModel) throws -> String {
        guard let raw = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw MCPError.invalidInput("Name the region by its name or region_id, as get_knowledge_map lists it.")
        }
        if map.layout.regions[raw] != nil { return raw }
        let named = map.layout.regions.keys.sorted().filter { id in
            let shown = map.notebook(ofRegion: id)?.title ?? map.layout.regions[id]?.name ?? ""
            return shown.caseInsensitiveCompare(raw) == .orderedSame
                || (map.layout.regions[id]?.name ?? "").caseInsensitiveCompare(raw) == .orderedSame
        }
        guard let id = named.first else { throw MCPError.notFound("No region on the canvas is called \(raw).") }
        guard named.count == 1 else { throw MCPError.invalidInput("\(named.count) regions are called \(raw); name one by its region_id: \(named.joined(separator: ", ")).") }
        return id
    }


    @MainActor
    static func regionColor(_ raw: Any?) throws -> String? {
        guard let raw = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            throw MCPError.invalidInput("A region's color is #RRGGBB, such as \(KnowledgeMapModel.regionColors[1]).")
        }
        return raw.uppercased()
    }


    /// What an arrow's end is called: a card's title, or a region's name.
    @MainActor
    static func endName(_ ref: String, in map: KnowledgeMapModel) -> String {
        guard let id = KnowledgeMap.regionID(fromRef: ref) else { return "“\(map.title(of: ref))”" }
        let name = map.layout.regions[id]?.name ?? ""
        return "the region \(name.isEmpty ? id : name)"
    }


    @MainActor
    static func regionEntry(_ id: String, in map: KnowledgeMapModel) -> [String: Any] {
        guard let region = map.layout.regions[id] else { return ["region_id": id, "deleted": true] }
        var entry: [String: Any] = [
            "region_id": id,
            "name": map.notebook(ofRegion: id)?.title ?? (region.name.isEmpty ? "Untitled region" : region.name),
            "rect": ["x": region.x, "y": region.y, "w": region.w, "h": region.h],
            "color": region.color,
        ]
        if region.isCollapsed { entry["collapsed"] = true }
        if region.isLocked { entry["locked"] = true }
        if region.isTree { entry["layout"] = KnowledgeMapLayout.treeLayout }
        if let notebookID = region.notebookID { entry["notebook_id"] = notebookID }
        if let parent = map.layout.parentRegionID(of: id) { entry["parent_region_id"] = parent }
        let nested = map.layout.nestedRegionIDs(in: id)
        if !nested.isEmpty { entry["nested_region_ids"] = nested }
        return entry
    }

    // MARK: build_canvas trees

    /// One note of a mind map, in the order it is written: `parent` is the
    /// index of its parent's note (nil for the root).
    struct CanvasTreeNote: Equatable {
        var key: String?
        var title: String
        var text: String?
        var parent: Int?
    }

    /// A mind map a `build_canvas` call asks for: its region's name and colour
    /// and its notes, the root first, each note after its parent and the
    /// children of one parent in the order given.
    struct CanvasTreeSpec: Equatable {
        var name: String
        var color: String?
        var notes: [CanvasTreeNote]
    }

    /// At most this many notes across the trees of one `build_canvas` call.
    static let maximumTreeNotes = 120

    /// The mind maps a call asks for, checked whole before anything is
    /// written: each needs a name, a root and a title on every note.
    @MainActor
    static func treeSpecs(from trees: [[String: Any]]) throws -> [CanvasTreeSpec] {
        var specs: [CanvasTreeSpec] = []
        var total = 0
        for tree in trees {
            let name = (tree["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { throw MCPError.invalidInput("Every tree needs a name for its region.") }
            let color = try regionColor(tree["color"])
            guard let root = tree["root"] as? [String: Any] else {
                throw MCPError.invalidInput("The tree \(name) needs a root note (title, text, children).")
            }
            var notes: [CanvasTreeNote] = []
            // Depth first, a node's children in the order given: the stack takes them in reverse.
            var stack: [([String: Any], Int?)] = [(root, nil)]
            while let (node, parent) = stack.popLast() {
                total += 1
                guard total <= maximumTreeNotes else {
                    throw MCPError.invalidInput("At most \(maximumTreeNotes) notes across the trees in one call.")
                }
                let title = (node["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { throw MCPError.invalidInput("Every note in the tree \(name) needs a title.") }
                let key = (node["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = (node["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                notes.append(CanvasTreeNote(key: key?.isEmpty == false ? key : nil, title: title, text: text?.isEmpty == false ? text : nil, parent: parent))
                let index = notes.count - 1
                for child in (node["children"] as? [[String: Any]] ?? []).reversed() { stack.append((child, index)) }
            }
            specs.append(CanvasTreeSpec(name: name, color: color, notes: notes))
        }
        return specs
    }

    // MARK: place_on_canvas

    @MainActor
    static func placeOnCanvas(_ arguments: [String: Any], map: KnowledgeMapModel) throws -> [String: Any] {
        let (refs, unknown) = cardRefs(arguments["item_ids"] as? [String] ?? [], in: map)
        guard !refs.isEmpty else {
            throw MCPError.notFound("None of the item_ids is in the library\(unknown.isEmpty ? "" : ": " + unknown.prefix(20).joined(separator: ", ")).")
        }
        let targets = ["region", "beside", "new_region"].filter { ((arguments[$0] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard targets.count <= 1 else { throw MCPError.invalidInput("Pass one of region, beside and new_region, not \(targets.joined(separator: " and ")).") }
        let style = try cardStyle(from: arguments)
        let annotations = try annotationWords(arguments["annotations"], among: refs, in: map)
        // A locked region keeps its cards where they are: nothing placed already inside one is moved,
        // and nothing is set down inside one (it would have to grow).
        let held = refs.filter { map.layout.placements[$0] != nil && map.lockedRegionID(holding: $0) != nil }
        guard held.isEmpty else { throw lockedRefusal(held, in: map) }
        var regionID: String?
        switch targets.first {
        case "region":
            let id = try Self.regionID(arguments["region"], in: map)
            if map.layout.regions[id]?.isLocked == true {
                throw MCPError.invalidInput("That region is locked: it would have to grow to hold the cards. Unlock it first (update_canvas_region with locked false).")
            }
            map.place(refs, inRegion: id, style: style, annotations: annotations)
            regionID = id
        case "beside":
            let anchor = try cardRef(arguments["beside"], named: "beside", in: map)
            guard let spot = map.spot(of: anchor) else {
                throw MCPError.invalidInput("\(map.title(of: anchor)) is not on the Canvas, so nothing can be set down beside it; place it first.")
            }
            let setDown = refs.filter { $0 != anchor }
            let widths: [Double]? = style?.w.map { width in setDown.map { _ in width } }
            let heights = setDown.map { map.heightWhenSetDown($0, width: style?.w ?? KnowledgeMap.cardWidth, style: style, annotation: annotations[$0]) }
            let block = KnowledgeMapArranging.block(heights: heights, widths: widths, origin: .init(x: 0, y: 0)).frame
            map.placeBlock(setDown, near: .init(
                x: spot.x + map.cardWidth(of: anchor) + 60 + block.w / 2,
                y: spot.y + block.h / 2 - KnowledgeMapArranging.insetY
            ), style: style, annotations: annotations)
            // The card the cards are set down beside is on the Canvas already.
            if let words = annotations[anchor] { map.setCardAnnotation(anchor, words) }
            // The block lands in free space, so only a region that holds what was set down is named.
            regionID = setDown.first.flatMap { map.regionID(containing: $0) }
        case "new_region":
            let title = (arguments["new_region"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            regionID = map.placeBlock(refs, near: map.arrivalCenter(), regionName: title, style: style, annotations: annotations)
        default:
            map.placeBlock(refs, near: map.arrivalCenter(), style: style, annotations: annotations)
        }
        map.send(.focus(refs: refs, regionID: regionID))
        var result: [String: Any] = ["placed": refs.map { card($0, in: map) }]
        if let regionID { result["region"] = regionEntry(regionID, in: map) }
        if !unknown.isEmpty { result["not_in_library"] = Array(unknown.prefix(50)) }
        return result
    }

    /// The refusal for cards a locked region keeps where they are.
    @MainActor
    static func lockedRefusal(_ refs: [String], in map: KnowledgeMapModel) -> MCPError {
        let names = refs.prefix(5).map { "“\(map.title(of: $0))”" }.joined(separator: ", ")
        return .invalidInput("\(names) \(refs.count == 1 ? "is" : "are") in a locked region, which keeps its cards where they are; unlock it first (update_canvas_region with locked false).")
    }

    // MARK: Regions

    /// A notebook a call names: its id and the name its frame takes, or nil
    /// when the library has no such notebook.
    typealias NotebookLookup = (String) -> (id: String, title: String)?

    @MainActor
    static func createCanvasRegion(_ arguments: [String: Any], map: KnowledgeMapModel, notebook lookup: NotebookLookup) throws -> [String: Any] {
        var notebook: (id: String, title: String)?
        if let raw = (arguments["notebook_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let found = lookup(raw) else {
                throw MCPError.notFound("No Notebook has the id \(raw); list_notebooks gives them.")
            }
            if let frame = map.layout.regions.first(where: { $0.value.notebookID == found.id })?.key {
                map.send(.focus(refs: [], regionID: frame))
                return ["created": false, "region": regionEntry(frame, in: map), "note": "This notebook's frame is on the Canvas already."]
            }
            notebook = found
        }
        let given = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = notebook?.title ?? given
        guard !title.isEmpty else { throw MCPError.invalidInput("create_canvas_region needs a name, or a notebook_id to frame.") }
        let color = try regionColor(arguments["color"])
        let locked = arguments["locked"] as? Bool ?? false
        let (refs, unknown) = cardRefs(arguments["item_ids"] as? [String] ?? [], in: map)
        let id: String?
        if !refs.isEmpty, refs.allSatisfy({ map.layout.placements[$0] != nil }) {
            // Drawn round cards where they are, moving none of them.
            id = map.makeRegion(around: refs, name: title, notebookID: notebook?.id, color: color, locked: locked)
            map.joinFrames(refs)
        } else {
            // The cards move into a new block: a locked region keeps its cards where they are.
            let held = refs.filter { map.layout.placements[$0] != nil && map.lockedRegionID(holding: $0) != nil }
            guard held.isEmpty else { throw lockedRefusal(held, in: map) }
            id = map.placeBlock(refs, near: map.arrivalCenter(), regionName: title, notebookID: notebook?.id, color: color, locked: locked)
        }
        guard let id else { throw MCPError.invalidInput("The region could not be drawn.") }
        map.send(.focus(refs: refs, regionID: id))
        var result: [String: Any] = ["created": true, "region": regionEntry(id, in: map)]
        if !unknown.isEmpty { result["not_in_library"] = Array(unknown.prefix(50)) }
        return result
    }

    @MainActor
    static func updateCanvasRegion(_ arguments: [String: Any], map: KnowledgeMapModel, notebook lookup: NotebookLookup) throws -> [String: Any] {
        let id = try regionID(arguments["region"], in: map)
        let name = (arguments["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name?.isEmpty == true { throw MCPError.invalidInput("A region's name cannot be empty.") }
        if name != nil, map.notebook(ofRegion: id) != nil {
            throw MCPError.invalidInput("This region is a notebook's frame and takes the notebook's name; rename the notebook with update_notebook, or unlink the frame (notebook_id \"\") first.")
        }
        let color = try regionColor(arguments["color"])
        let number = { (key: String) in canvasNumber(arguments[key]) }
        guard let region = map.layout.regions[id] else { throw MCPError.notFound("No region on the canvas is \(id).") }
        let origin: KnowledgeMapArranging.Spot? = number("x") == nil && number("y") == nil
            ? nil : .init(x: number("x") ?? region.x, y: number("y") ?? region.y)
        let size: (w: Double, h: Double)? = number("w") == nil && number("h") == nil
            ? nil : (number("w") ?? region.w, number("h") ?? region.h)
        var notebookID: String??
        if let raw = (arguments["notebook_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if raw.isEmpty {
                notebookID = .some(nil)
            } else {
                guard let found = lookup(raw) else {
                    throw MCPError.notFound("No Notebook has the id \(raw); list_notebooks gives them.")
                }
                if let other = map.layout.regions.first(where: { $0.key != id && $0.value.notebookID == found.id })?.key {
                    throw MCPError.invalidInput("\(found.title) is framed by region \(other) already.")
                }
                notebookID = .some(found.id)
            }
        }
        let collapsed = arguments["collapsed"] as? Bool
        let wantsLock = arguments["locked"] as? Bool
        let layoutName = (arguments["layout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let layoutName, !layoutName.isEmpty, !["free", "tree"].contains(layoutName) {
            throw MCPError.invalidInput("layout is free or tree, not \"\(layoutName)\".")
        }
        let fit = arguments["fit_to_content"] as? Bool ?? false
        let (growCards, growUnknown) = cardRefs(arguments["grow_to_hold"] as? [String] ?? [], in: map)
        let growing = growCards.filter { map.layout.placements[$0] != nil }
        if arguments["grow_to_hold"] != nil, growing.isEmpty {
            throw MCPError.invalidInput("None of grow_to_hold is on the Canvas\(growUnknown.isEmpty ? "" : "; not in the library: " + growUnknown.prefix(20).joined(separator: ", ")).")
        }
        let touchesGeometry = origin != nil || size != nil || fit || !growing.isEmpty || (layoutName?.isEmpty == false)
        if region.isLocked, touchesGeometry, wantsLock != false {
            throw MCPError.invalidInput("The region “\(region.name.isEmpty ? id : region.name)” is locked, which keeps it and its cards where they are; unlock it first, or pass locked false with this change.")
        }
        if let wantsLock { map.setRegionLocked(id, wantsLock) }
        let editsBase = name != nil || color != nil || origin != nil || size != nil || notebookID != nil || collapsed != nil
        let editsNew = wantsLock != nil || (layoutName?.isEmpty == false) || fit || !growing.isEmpty
        if editsBase || !editsNew {
            map.editRegion(id, name: name, color: color, origin: origin, size: size, notebookID: notebookID, collapsed: collapsed)
        }
        if let layoutName, !layoutName.isEmpty { map.setRegionLayout(id, layoutName) }
        if fit { map.fitRegionToContent(id) }
        if !growing.isEmpty { map.growRegion(id, toHold: growing) }
        map.send(.focus(refs: [], regionID: id))
        return ["region": regionEntry(id, in: map)]
    }

    // MARK: Arrows

    @MainActor
    static func drawCanvasArrow(_ arguments: [String: Any], map: KnowledgeMapModel) throws -> [String: Any] {
        let from = try arrowEnd(arguments["from"], named: "from", in: map)
        let to = try arrowEnd(arguments["to"], named: "to", in: map)
        let tree = arguments["tree"] as? Bool ?? false
        if let reason = map.edgeRefusal(from: from, to: to, tree: tree) { throw MCPError.invalidInput(reason) }
        guard let edgeID = map.addEdge(
            from: from, to: to,
            label: arguments["label"] as? String,
            tree: tree,
            route: try edgeRoute(arguments["route"]),
            dashed: arguments["dashed"] as? Bool,
            heads: try edgeHeads(arguments["heads"]),
            color: try edgeColor(arguments["color"]),
            stance: try edgeStance(arguments["stance"])
        ) else {
            throw MCPError.invalidInput("The arrow could not be drawn.")
        }
        map.send(.focus(
            refs: [from, to].filter { KnowledgeMap.regionID(fromRef: $0) == nil },
            regionID: [from, to].lazy.compactMap { KnowledgeMap.regionID(fromRef: $0) }.first
        ))
        return arrowEntry(edgeID, in: map)
    }

    /// update_canvas_arrow and delete_canvas_arrow: an arrow by its edge_id or by its two ends.
    @MainActor
    static func changeCanvasArrow(_ arguments: [String: Any], map: KnowledgeMapModel, deleting: Bool) throws -> [String: Any] {
        let edgeID: String
        if let raw = (arguments["edge_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard map.layout.edges[raw] != nil else { throw MCPError.notFound("No arrow on the Canvas is \(raw).") }
            edgeID = raw
        } else {
            let from = try arrowEnd(arguments["from"], named: "from (or edge_id)", in: map)
            let to = try arrowEnd(arguments["to"], named: "to (or edge_id)", in: map)
            guard let found = map.layout.edges.first(where: { $0.value.from == from && $0.value.to == to })?.key else {
                throw MCPError.notFound("No arrow runs from \(endName(from, in: map)) to \(endName(to, in: map)).")
            }
            edgeID = found
        }
        if deleting {
            map.deleteEdge(edgeID)
            return ["deleted": edgeID]
        }
        let label = arguments["label"] as? String
        let route = try edgeRoute(arguments["route"])
        let dashed = arguments["dashed"] as? Bool
        let heads = try edgeHeads(arguments["heads"])
        let color = try edgeColor(arguments["color"])
        let tree = arguments["tree"] as? Bool
        let stance = try edgeStance(arguments["stance"])
        guard label != nil || route != nil || dashed != nil || heads != nil || color != nil || tree != nil || stance != nil else {
            throw MCPError.invalidInput("update_canvas_arrow needs label, route, dashed, heads, color, tree or stance.")
        }
        if tree == true, let edge = map.layout.edges[edgeID], !edge.isTree,
           let reason = map.edgeRefusal(from: edge.from, to: edge.to, tree: true, replacing: edgeID) {
            throw MCPError.invalidInput(reason)
        }
        let changed = map.updateEdgeStyle(edgeID, route: route, dashed: dashed, heads: heads, color: color, tree: tree, label: label, stance: stance)
        var entry = arrowEntry(edgeID, in: map)
        entry["changed"] = changed
        return entry
    }

    // MARK: update_canvas_card

    @MainActor
    static func updateCanvasCard(_ arguments: [String: Any], map: KnowledgeMapModel) throws -> [String: Any] {
        let raw = arguments["item_ids"] as? [String] ?? []
        let (refs, unknown) = cardRefs(raw, in: map)
        guard !refs.isEmpty else {
            throw MCPError.notFound("None of the item_ids is in the library\(unknown.isEmpty ? "" : ": " + unknown.prefix(20).joined(separator: ", ")).")
        }
        let placed = refs.filter { map.layout.placements[$0] != nil }
        guard !placed.isEmpty else {
            throw MCPError.invalidInput("None of those cards is on the Canvas; place_on_canvas sets them down first.")
        }
        let color = try cardColorChange(arguments["color"])
        let w = try cardSize(arguments["w"], named: "w", in: KnowledgeMap.cardWidthRange)
        let h = try cardSize(arguments["h"], named: "h", in: KnowledgeMap.cardHeightRange)
        let folded: KnowledgeMapFieldChange<Bool> = (arguments["folded"] as? Bool).map { $0 ? .set(true) : .clear } ?? .keep
        let page = try cardPageChange(arguments["page"])
        let annotation = try cardAnnotationChange(arguments["annotation"])
        let plain: KnowledgeMapFieldChange<Bool> = (arguments["plain"] as? Bool).map { .set($0) } ?? .keep
        let answered: KnowledgeMapFieldChange<Bool> = (arguments["answered"] as? Bool).map { .set($0) } ?? .keep
        let fit = arguments["fit_to_content"] as? Bool ?? false
        if fit, w != nil || h != nil {
            throw MCPError.invalidInput("fit_to_content gives the cards the size their kind has; do not pass w or h with it.")
        }
        guard fit || w != nil || h != nil || !folded.isKeep || !color.isKeep || !page.isKeep || !annotation.isKeep || !plain.isKeep || !answered.isKeep else {
            throw MCPError.invalidInput("update_canvas_card needs color, folded, w, h or fit_to_content (or page, annotation, plain or answered).")
        }
        // What a field is for is refused before anything is written.
        func names(_ refs: [String]) -> String {
            refs.prefix(5).map { "“\(map.title(of: $0))”" }.joined(separator: ", ") + (refs.count > 5 ? " and more" : "")
        }
        func kind(_ ref: String) -> KnowledgeMap.ItemKind? { KnowledgeMap.ItemRef(ref)?.kind }
        let notSources = placed.filter { kind($0) != .source }
        if !page.isKeep, !notSources.isEmpty {
            throw MCPError.invalidInput("page shows a source as a page of its PDF; \(names(notSources)) \(notSources.count == 1 ? "is" : "are") not a source.")
        }
        let ideas = placed.filter { kind($0) == .idea }
        if !annotation.isKeep, !ideas.isEmpty {
            throw MCPError.invalidInput("An Idea's own note holds its words, so \(names(ideas)) take\(ideas.count == 1 ? "s" : "") no annotation; change an Idea's note with update_idea.")
        }
        let notIdeas = placed.filter { kind($0) != .idea }
        if !plain.isKeep, !notIdeas.isEmpty {
            throw MCPError.invalidInput("plain draws an Idea as words; \(names(notIdeas)) \(notIdeas.count == 1 ? "is" : "are") not an Idea.")
        }
        let notQuestions = placed.filter { !($0.hasPrefix("idea:") && KnowledgeMap.isQuestion(map.title(of: $0))) }
        if !answered.isKeep, !notQuestions.isEmpty {
            throw MCPError.invalidInput("answered marks a question, an Idea whose title ends with ?; \(names(notQuestions)) \(notQuestions.count == 1 ? "is" : "are") not one.")
        }
        let edits = placed.map { ref -> KnowledgeMapPlacementStyle in
            var shown = page
            if case .set(let number) = page { shown = .set(map.clampedPage(number, for: ref)) }
            return KnowledgeMapPlacementStyle(
                ref: ref,
                w: fit ? .clear : (w.map { .set($0) } ?? .keep),
                h: fit ? .clear : (h.map { .set($0) } ?? .keep),
                folded: folded,
                color: color,
                page: shown,
                annotation: annotation,
                plain: plain,
                answered: answered
            )
        }
        let changed = map.setPlacementStyle(edits)
        // A card made larger, a page face or words under it may now reach past its region.
        if w != nil || h != nil || !page.isKeep || !annotation.isKeep { map.growRegions(toHold: placed) }
        map.send(.focus(refs: placed, regionID: nil))
        var result: [String: Any] = ["updated": changed, "cards": placed.map { card($0, in: map) }]
        let off = refs.filter { map.layout.placements[$0] == nil }
        if !off.isEmpty { result["not_on_canvas"] = off.map { card($0, in: map) } }
        if !unknown.isEmpty { result["not_in_library"] = Array(unknown.prefix(50)) }
        return result
    }

    // MARK: arrange_on_canvas

    @MainActor
    static func arrangeOnCanvas(_ arguments: [String: Any], map: KnowledgeMapModel) throws -> [String: Any] {
        var arrangement: KnowledgeMapArrangement?
        if let text = (arguments["arrangement"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty {
            guard let found = KnowledgeMapArrangement(rawValue: text) else {
                throw MCPError.invalidInput("arrangement is row, column or grid, not \"\(text)\".")
            }
            arrangement = found
        }
        var alignment: KnowledgeMapAlignment?
        if let text = (arguments["align"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty {
            switch text {
            case "left": alignment = .left
            case "center": alignment = .centerX
            case "right": alignment = .right
            case "top": alignment = .top
            case "middle": alignment = .centerY
            case "bottom": alignment = .bottom
            default: throw MCPError.invalidInput("align is left, center, right, top, middle or bottom, not \"\(text)\".")
            }
        }
        guard arrangement != nil || alignment != nil else {
            throw MCPError.invalidInput("arrange_on_canvas needs arrangement (row, column or grid), align, or both.")
        }
        let (refs, unknown) = cardRefs(arguments["item_ids"] as? [String] ?? [], in: map)
        let placed = refs.filter { map.layout.placements[$0] != nil }
        guard placed.count >= 2 else {
            throw MCPError.invalidInput("Arranging needs at least two cards that are on the Canvas; \(placed.count) of those named \(placed.count == 1 ? "is" : "are").")
        }
        let locked = placed.filter { map.lockedRegionID(holding: $0) != nil }
        guard locked.isEmpty else { throw lockedRefusal(locked, in: map) }
        let moved = map.arrange(placed, as: arrangement, align: alignment)
        map.send(.focus(refs: placed, regionID: nil))
        var result: [String: Any] = ["moved": moved, "cards": placed.map { card($0, in: map) }]
        let off = refs.filter { map.layout.placements[$0] == nil }
        if !off.isEmpty { result["not_on_canvas"] = off.map { card($0, in: map) } }
        if !unknown.isEmpty { result["not_in_library"] = Array(unknown.prefix(50)) }
        return result
    }

    // MARK: lint_canvas

    @MainActor
    static func lintCanvas(_ arguments: [String: Any], map: KnowledgeMapModel) -> [String: Any] {
        let limit = min(max(canvasNumber(arguments["limit"]).map { Int($0) } ?? 100, 1), 500)
        let issues = map.lint()
        func name(_ kind: KnowledgeMapLintIssue.Kind) -> String {
            switch kind {
            case .overlap: return "overlap"
            case .cardOutsideRegion: return "card_outside_region"
            case .arrowOverCard: return "arrow_over_card"
            case .emptyRegion: return "empty_region"
            }
        }
        var counts: [String: Int] = [:]
        for issue in issues { counts[name(issue.kind), default: 0] += 1 }
        var result: [String: Any] = [
            "ok": issues.isEmpty,
            "issue_count": issues.count,
            "issues": issues.prefix(limit).map { issue -> [String: Any] in
                var entry: [String: Any] = ["kind": name(issue.kind), "message": issue.message]
                if !issue.refs.isEmpty { entry["item_ids"] = issue.refs }
                if let regionID = issue.regionID { entry["region_id"] = regionID }
                if let edgeID = issue.edgeID { entry["edge_id"] = edgeID }
                return entry
            },
            "canvas": ["canvas_id": map.mapID],
        ]
        if !counts.isEmpty { result["by_kind"] = counts }
        if issues.count > limit { result["truncated"] = true }
        return result
    }

    // MARK: screenshot_canvas

    /// How large a picture is attached to the answer as an image; a larger one
    /// is only a file.
    static let screenshotInlineLimit = 4_000_000

    /// The picture of the Canvas `screenshot_canvas` takes, from the canvas
    /// `map` shows (`isOnScreen`: whether a Canvas pane shows it), saved in
    /// `exportsFolder`.
    @MainActor
    static func canvasScreenshot(
        _ arguments: [String: Any],
        map: KnowledgeMapModel,
        canvasName: String,
        isOnScreen: Bool,
        exportsFolder: URL
    ) async throws -> MediaToolResult {
        let scale: Double
        if arguments["scale"] == nil || arguments["scale"] is NSNull {
            scale = 1
        } else {
            guard let given = canvasNumber(arguments["scale"]), given.isFinite, (0.1...4).contains(given) else {
                throw MCPError.invalidInput("scale is a number from 0.1 to 4.")
            }
            scale = given
        }
        var refs: [String]?
        let raw = arguments["item_ids"] as? [String] ?? []
        if !raw.isEmpty {
            let (known, unknown) = cardRefs(raw, in: map)
            let placed = known.filter { map.layout.placements[$0] != nil }
            guard !placed.isEmpty else {
                throw MCPError.notFound("None of those cards is on the Canvas\(unknown.isEmpty ? "" : "; not in the library: " + unknown.prefix(20).joined(separator: ", ")).")
            }
            refs = placed
        }
        guard isOnScreen else {
            throw MCPError.invalidInput("The Canvas is not showing on the Mac, so there is nothing to draw a picture of. open_canvas (or focus_map, build_canvas) shows it; then ask again.")
        }
        // The pane installs its exporter once its page is ready: a Canvas just opened may need a moment.
        var waited = 0
        while map.imageExporter == nil, waited < 30 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let export = map.imageExporter else {
            throw MCPError.invalidInput("The Canvas pane has not finished drawing yet; ask again in a moment.")
        }
        let data: Data
        do {
            data = try await export(scale, refs)
        } catch {
            throw MCPError.invalidInput("The Canvas could not be drawn to a picture: \(error.localizedDescription)")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw MCPError.invalidInput("The Canvas drew something that is not a picture.")
        }
        let path = try writeScreenshot(data, canvasName: canvasName, into: exportsFolder)
        var result: [String: Any] = [
            "file_path": path,
            "width": width,
            "height": height,
            "scale": scale,
            "canvas": ["canvas_id": map.mapID, "name": canvasName],
        ]
        if let refs { result["item_ids"] = refs }
        let attached = data.count <= screenshotInlineLimit
        result["attached"] = attached
        let text = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        return MediaToolResult(
            text: String(decoding: text, as: UTF8.self),
            images: attached ? [MCPToolImage(data: data, mimeType: "image/png")] : [],
            isError: false
        )
    }

    /// Saves a picture of the Canvas in `folder` and returns its path.
    private static func writeScreenshot(_ data: Data, canvasName: String, into folder: URL) throws -> String {
        let slug = canvasName.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { text, character in
                if character == "-", text.last == "-" || text.isEmpty { return }
                text.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "Canvas-\(slug.isEmpty ? "untitled" : String(slug.prefix(40)))-\(stamp.string(from: Date()))"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Two pictures in one second (two scales asked at once) each keep
        // their own file rather than the second writing over the first.
        var file = folder.appendingPathComponent(base + ".png")
        var copy = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(base)-\(copy).png")
            copy += 1
        }
        try data.write(to: file, options: .atomic)
        return file.path
    }
}
#endif
