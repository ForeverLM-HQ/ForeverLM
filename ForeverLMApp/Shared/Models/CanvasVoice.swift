import Foundation

// MARK: - Speaking to the Canvas (2026-10-13)
//
// The learner holds S on the Canvas (or taps it, or picks Speak to the Canvas
// in its menu) and says what to change; the canvas changes as they said:
// cards set down, moved, grouped, joined or taken off, regions drawn. (product
// owner, 2026-10-13: "in the mac app; i should also be able to speak and it
// should super quickly be able to modify the visual space", and "i cannot be
// waiting 30 seconds for the agent to move some things around".)
//
// Speed is the design:
// - The words are transcribed once the learner stops, through OpenRouter on
//   the synced Dictation model, on a connection opened while they speak.
// - One call to the Canvas Voice model (`AITask.canvasVoice`, a model of its
//   own so the learner can pick a fast one), at its lowest effort, with no
//   tool round trips: the model writes its edits as JSON, one a line, and each
//   line is carried out the moment it arrives, while the rest still streams.
// - The canvas goes to the model as a short listing with short ids (c1, r1)
//   in place of the library's long ones, so both the request and the answer
//   are small; the layout itself (where a group lands, how a row lines up) is
//   worked out here by the Canvas's own edits, never by the model.
//
// The edits are the ones the MCP canvas tools make (`MCPDataStore.editCanvas`),
// so each is the learner's own write, syncs, and the whole request is one
// Undo step (`KnowledgeMapModel.beginEditGroup`). The Mac side is
// `KnowledgeMapVoice` (App/KnowledgeMapVoice.swift); this file is the part
// with no app state, so it can be tested on its own.

enum CanvasVoice {
    /// A card on the plane, or waiting in the canvas's Library, as the model
    /// is told of it.
    struct Card: Codable, Equatable, Sendable {
        var ref: String
        /// The card's kind as its dot shows it: `paper`, `article`, `idea`…
        var type: String
        var title: String
        /// Its rect on the plane; nil for a card not placed.
        var x: Double?
        var y: Double?
        var w: Double?
        var h: Double?
        var regionID: String?
        var inView = false
        var selected = false
    }

    struct Region: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var cardCount: Int
    }

    struct Arrow: Codable, Equatable, Sendable {
        var from: String
        var to: String
        var label: String
    }

    /// The canvas as it is when the learner stops speaking, read in one cheap
    /// pass on the main actor.
    struct Snapshot: Codable, Equatable, Sendable {
        var canvasName: String
        var viewCenterX: Double
        var viewCenterY: Double
        var viewWidth: Double
        var viewHeight: Double
        var selectedRegionID: String?
        /// The placed cards.
        var cards: [Card]
        var regions: [Region]
        var arrows: [Arrow]
        /// Cards waiting in the canvas's Library (its unplaced Ideas), which a
        /// request may name to set down.
        var waiting: [Card]
    }

    /// A request spoken earlier in this sitting and what it did, so the next
    /// can say "again", "undo that" or "the same for the others".
    struct Turn: Codable, Equatable, Sendable {
        var said: String
        var done: [String]
    }

    /// The most earlier requests the model is told of.
    static let maximumTurns = 3

    /// What the model reads, and the short ids it may answer with.
    struct Context: Sendable {
        var message: String
        /// `c1` and on, to the card's ref.
        var cards: [String: String]
        /// `r1` and on, to the region's id.
        var regions: [String: String]
        /// Each region's cards (refs), by region id: a region named where
        /// cards are meant ("take the misc group off") stands for them.
        var regionCards: [String: [String]] = [:]
        /// The regions' names, as the canvas listed them.
        var regionNames: [String] = []
    }

    /// The most cards listed: the selected and in-view ones first, then the
    /// rest by how near the view's middle they are. A canvas with more says
    /// how many it left out.
    static let maximumCards = 240
    static let maximumWaiting = 30
    static let maximumRegions = 60
    static let maximumArrows = 80
    /// A title longer than this is cut, with an ellipsis: enough to tell
    /// cards apart by.
    static let titleLimit = 80

    // MARK: The model's message

    static func context(_ snapshot: Snapshot, said: String, earlier: [Turn] = []) -> Context {
        let middleX = snapshot.viewCenterX, middleY = snapshot.viewCenterY
        func distance(_ card: Card) -> Double {
            let dx = (card.x ?? 0) + (card.w ?? 0) / 2 - middleX
            let dy = (card.y ?? 0) + (card.h ?? 0) / 2 - middleY
            return dx * dx + dy * dy
        }
        let ordered = snapshot.cards.enumerated().sorted { a, b in
            let ra = a.element.selected ? 0 : a.element.inView ? 1 : 2
            let rb = b.element.selected ? 0 : b.element.inView ? 1 : 2
            if ra != rb { return ra < rb }
            let da = distance(a.element), db = distance(b.element)
            if da != db { return da < db }
            return a.offset < b.offset
        }.map(\.element)
        let listed = Array(ordered.prefix(maximumCards))
        let waiting = Array(snapshot.waiting.prefix(maximumWaiting))

        var cardIDs: [String: String] = [:]
        var aliasOfRef: [String: String] = [:]
        for (index, card) in (listed + waiting).enumerated() {
            let alias = "c\(index + 1)"
            cardIDs[alias] = card.ref
            aliasOfRef[card.ref] = alias
        }
        let regions = snapshot.regions
            .sorted { ($0.y, $0.x, $0.id) < ($1.y, $1.x, $1.id) }
            .prefix(maximumRegions)
        var regionIDs: [String: String] = [:]
        var aliasOfRegion: [String: String] = [:]
        for (index, region) in regions.enumerated() {
            let alias = "r\(index + 1)"
            regionIDs[alias] = region.id
            aliasOfRegion[region.id] = alias
        }

        var lines: [String] = []
        // The canvas's own name, said so the model never takes it for a region's.
        lines.append("CANVAS NAME (the whole canvas, not a region) \(quoted(snapshot.canvasName))")
        lines.append("VIEW middle \(number(middleX)),\(number(middleY)), \(number(snapshot.viewWidth)) wide and \(number(snapshot.viewHeight)) high")
        let selected = listed.filter(\.selected).compactMap { aliasOfRef[$0.ref] }
        var selection = selected.isEmpty ? "none" : selected.joined(separator: " ")
        if let id = snapshot.selectedRegionID, let alias = aliasOfRegion[id] {
            selection = selected.isEmpty ? "region \(alias)" : selection + ", region \(alias)"
        }
        lines.append("SELECTED: \(selection)")
        lines.append("")
        lines.append("CARDS (id kind \"title\" x,y w×h, region; the first ones are in view):")
        if listed.isEmpty { lines.append("none") }
        for card in listed {
            guard let alias = aliasOfRef[card.ref] else { continue }
            var line = "\(alias) \(kind(card.type)) \(quoted(card.title))"
            if let x = card.x, let y = card.y {
                line += " \(number(x)),\(number(y)) \(number(card.w ?? 0))×\(number(card.h ?? 0))"
            }
            if let region = card.regionID.flatMap({ aliasOfRegion[$0] }) { line += " \(region)" }
            if card.inView { line += " in view" }
            lines.append(line)
        }
        if snapshot.cards.count > listed.count {
            lines.append("(\(snapshot.cards.count - listed.count) more cards, far from the view, are not listed)")
        }
        if !regions.isEmpty {
            lines.append("")
            lines.append("REGIONS (id \"name\" x,y w×h, cards in it):")
            for region in regions {
                guard let alias = aliasOfRegion[region.id] else { continue }
                let name = region.name.isEmpty ? "Untitled region" : region.name
                lines.append("\(alias) \(quoted(name)) \(number(region.x)),\(number(region.y)) \(number(region.w))×\(number(region.h)) \(region.cardCount)")
            }
        }
        let arrows = snapshot.arrows.compactMap { arrow -> String? in
            guard let from = end(arrow.from, cards: aliasOfRef, regions: aliasOfRegion),
                  let to = end(arrow.to, cards: aliasOfRef, regions: aliasOfRegion) else { return nil }
            return arrow.label.isEmpty ? "\(from) → \(to)" : "\(from) → \(to) \(quoted(arrow.label))"
        }.prefix(maximumArrows)
        if !arrows.isEmpty {
            lines.append("")
            lines.append("ARROWS:")
            lines.append(contentsOf: arrows)
        }
        if !waiting.isEmpty {
            lines.append("")
            lines.append("WAITING IN THE CANVAS'S LIBRARY (not placed):")
            for card in waiting {
                guard let alias = aliasOfRef[card.ref] else { continue }
                lines.append("\(alias) \(kind(card.type)) \(quoted(card.title))")
            }
        }
        let turns = earlier.suffix(maximumTurns)
        if !turns.isEmpty {
            lines.append("")
            lines.append("EARLIER (oldest first; the cards they changed are SELECTED now):")
            for turn in turns {
                let done = turn.done.isEmpty ? "nothing changed" : turn.done.joined(separator: "; ")
                lines.append("\(quoted(turn.said, cut: false)) → \(done)")
            }
        }
        lines.append("")
        // The learner's words whole: a title is cut to fit the listing, a
        // request never (a ten-second request cut at 80 characters lost its
        // second half, and the model guessed at it).
        lines.append("THE LEARNER SAID: \(quoted(said.trimmingCharacters(in: .whitespacesAndNewlines), cut: false))")
        var regionCards: [String: [String]] = [:]
        for card in snapshot.cards { if let id = card.regionID { regionCards[id, default: []].append(card.ref) } }
        return Context(
            message: lines.joined(separator: "\n"), cards: cardIDs, regions: regionIDs, regionCards: regionCards,
            regionNames: snapshot.regions.map(\.name)
        )
    }

    /// A card's kind in the learner's word: an Idea is a "note", as they
    /// say it ("the PINK1 note" was taken for the PINK1 paper when the
    /// listing said "idea").
    private static func kind(_ type: String) -> String {
        type == "idea" ? "note" : type
    }

    private static func end(_ ref: String, cards: [String: String], regions: [String: String]) -> String? {
        if ref.hasPrefix("region:") { return regions[String(ref.dropFirst("region:".count))] }
        return cards[ref]
    }

    private static func quoted(_ text: String, cut: Bool = true) -> String {
        var line = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        if cut, line.count > titleLimit { line = String(line.prefix(titleLimit - 1)) + "…" }
        return "\"\(line)\""
    }

    private static func number(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// The user's turn of every request. The canvas and the words ride in the
    /// system message's volatile tail, so this turn, and with it the
    /// prompt-cache session the request is routed by, never changes.
    static let userTurn = "Write the edits for what the learner said, one JSON object per line."
    /// The hedged second request's turn: the same ask in other words, so its
    /// prompt-cache session (which hashes the opening turn) is its own and
    /// OpenRouter's sticky routing does not send it to the host the first is
    /// still waiting on.
    static let retryTurn = "Write the edits for what the learner said, one JSON object per line, starting now."

    /// When something first happened, set once from wherever it happens and
    /// read after the work is done.
    final class Stamp: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date?

        func mark() {
            lock.lock()
            if time == nil { time = Date() }
            lock.unlock()
        }

        var at: Date? {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
    }

    // MARK: A second request when the first is slow to answer

    /// How long the first request may go without a word before an identical
    /// second one goes out (a hedged request). Measured 2026-10-14: the same
    /// request's first token came in 0.44 to 1.9 s on one host, 4.4 s at
    /// worst, and in under 0.8 s nine times in ten.
    static let hedgeAfter: TimeInterval = 0.8

    /// Which of the requests answered first: its words are carried out, and
    /// the others are stopped the moment it starts.
    final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var winner: Int?
        private var tasks: [Int: Task<Error?, Never>] = [:]
        private var done: Set<Int> = []

        /// The request `n` has a word: true when it is the one being carried
        /// out (it is first, or was already).
        func claim(_ n: Int) -> Bool {
            lock.lock()
            if winner == nil {
                winner = n
                let others = tasks.filter { $0.key != n }.map(\.value)
                lock.unlock()
                for task in others { task.cancel() }
                return true
            }
            let won = winner == n
            lock.unlock()
            return won
        }

        func add(_ task: Task<Error?, Never>, as n: Int) {
            lock.lock()
            tasks[n] = task
            let lost = winner != nil && winner != n
            lock.unlock()
            if lost { task.cancel() }
        }

        func finish(_ n: Int) {
            lock.lock()
            done.insert(n)
            lock.unlock()
        }

        var won: Int? {
            lock.lock()
            defer { lock.unlock() }
            return winner
        }

        /// How many requests went out: 2 when the second was sent.
        var attempts: Int {
            lock.lock()
            defer { lock.unlock() }
            return tasks.count
        }

        func isDone(_ n: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return done.contains(n)
        }
    }

    // MARK: Reading the answer as it streams

    /// Cuts the streamed answer into lines as they complete. Fed from the
    /// stream's callback, one delta at a time, in order.
    final class LineReader: @unchecked Sendable {
        private var buffer = ""

        /// The lines this delta completed.
        func feed(_ delta: String) -> [String] {
            buffer += delta
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: "\n") {
                lines.append(String(buffer[..<newline]))
                buffer = String(buffer[buffer.index(after: newline)...])
            }
            return lines
        }

        /// The last line, which no newline ended.
        func finish() -> [String] {
            defer { buffer = "" }
            return buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [buffer]
        }
    }

    /// One edit the model wrote: the tool and its arguments, as the line had them.
    struct Edit {
        var tool: String
        var arguments: [String: Any]
    }

    enum Line {
        /// Nothing to do: blank, or a code fence a model wrote despite being told not to.
        case blank
        case edit(Edit)
        case unreadable(String)
    }

    /// A line of the answer: an object with a `tool`, or a line that is no
    /// edit (counted, so an answer of nothing but those surfaces as a failure).
    static func line(_ raw: String) -> Line {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("```") { return .blank }
        // A list marker or a trailing comma, as a model writing an array might.
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
        if text.hasSuffix(",") { text = String(text.dropLast()) }
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable(text) }
        guard let tool = (object["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else {
            // The edit named by its one key, as some models write it:
            // {"say": "…"} or {"move": {…}}.
            guard object.count == 1, let only = object.first else { return .unreadable(text) }
            if only.key == "say", let words = only.value as? String { return .edit(Edit(tool: "say", arguments: ["text": words])) }
            if let arguments = only.value as? [String: Any] { return .edit(Edit(tool: only.key, arguments: arguments)) }
            return .unreadable(text)
        }
        var arguments = object
        arguments.removeValue(forKey: "tool")
        // A model that nests the arguments, as a tool call would.
        if arguments.count == 1, let nested = arguments["arguments"] as? [String: Any] ?? arguments["args"] as? [String: Any] {
            arguments = nested
        }
        return .edit(Edit(tool: tool, arguments: arguments))
    }

    // MARK: Short ids back to the canvas's own

    /// The arguments with every short id the context gave turned back into
    /// the canvas's own: a card's `c3` into its ref, a region's `r2` into its
    /// id (or `region:<id>` where an arrow's end is meant). Anything else,
    /// such as a region named by its name, is left as it is for the edit to
    /// read.
    static func resolved(_ arguments: [String: Any], in context: Context) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in arguments {
            switch value {
            case let text as String:
                out[key] = resolved(text, key: key, in: context)
            case let list as [Any] where ["item_ids", "grow_to_hold"].contains(key):
                // Cards: a region among them stands for the cards in it.
                var refs: [String] = []
                for item in list {
                    guard let text = item as? String else { continue }
                    let id = resolved(text, key: key, in: context)
                    let named = context.regions.values.contains(id) ? context.regionCards[id] ?? [] : [id]
                    for ref in named where !refs.contains(ref) { refs.append(ref) }
                }
                out[key] = refs
            case let list as [Any]:
                out[key] = list.map { item -> Any in
                    guard let text = item as? String else { return item }
                    return resolved(text, key: key, in: context)
                }
            case let object as [String: Any] where key == "annotations":
                var words: [String: Any] = [:]
                for (card, text) in object { words[context.cards[card] ?? card] = text }
                out[key] = words
            default:
                out[key] = value
            }
        }
        return out
    }

    /// Each tint by the one name the bar says it with.
    static let tintTitles: [String: String] = [
        "#7F77DD": "violet", "#1D9E75": "green", "#D85A30": "orange", "#D4537E": "pink",
        "#BA7517": "amber", "#378ADD": "blue", "#639922": "lime", "#888780": "grey",
    ]

    /// The canvas's eight tints by the names the inspector gives them
    /// (`KnowledgeMapInspectorChoices.tints`), and the colours people say for
    /// them: a model told to write `#RRGGBB` still writes "orange" now and then.
    static let tintNames: [String: String] = [
        "violet": "#7F77DD", "purple": "#7F77DD", "lavender": "#7F77DD",
        "green": "#1D9E75", "teal": "#1D9E75",
        "orange": "#D85A30", "red": "#D85A30",
        "pink": "#D4537E", "magenta": "#D4537E",
        "amber": "#BA7517", "yellow": "#BA7517", "brown": "#BA7517", "gold": "#BA7517",
        "blue": "#378ADD",
        "lime": "#639922",
        "grey": "#888780", "gray": "#888780",
    ]

    private static func resolved(_ text: String, key: String, in context: Context) -> String {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "color", let hex = tintNames[id.lowercased()] { return hex }
        // Free words are never ids: a note's text, a region's new name, a label.
        guard !["text", "name", "new_region", "label", "words"].contains(key) else { return text }
        if let ref = context.cards[id] { return ref }
        let region = id.hasPrefix("region:") ? String(id.dropFirst("region:".count)) : id
        if let regionID = context.regions[region] {
            return ["from", "to"].contains(key) ? "region:\(regionID)" : regionID
        }
        return text
    }

    // MARK: The request

    /// The lowest effort the model offers: a canvas edit needs no long
    /// deliberation, and the learner is watching. Nil when it offers none.
    static func quickestEffort(_ offered: [AIEffort]) -> AIEffort? {
        let order = AIEffort.allCases
        return offered.min { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
    }

    /// How long a press of S may last and still be a tap: a tap listens until
    /// the learner stops speaking, a hold until they let go.
    static let tapLimit: TimeInterval = 0.35

    // MARK: What the learner meant, over what the model wrote

    /// An edit (its ids already resolved) brought back to what the learner
    /// asked for where a model, now and then, writes otherwise (measured in
    /// whole spoken sessions, 2026-10-14):
    /// - "put these in a region called Fission" written as create_canvas_region
    ///   draws a frame round cards wherever they lie, one region ending up
    ///   inside another; unless the learner said "around", the cards are
    ///   gathered into the new region (place_on_canvas new_region).
    /// - a new_region named as a region that is already there means that
    ///   region, so gathering cards never makes a second "Fission".
    /// - a move of no distance is nothing to do (nil), not a failure; a move
    ///   beside a card is the placement beside it.
    /// - "in a row", "a column", "a grid": the arrangement the learner named,
    ///   whichever the model wrote ("line them up in a row" came back a grid);
    ///   an alignment alone is left an alignment.
    static func meant(_ edit: Edit, said: String, regionNames: [String]) -> Edit? {
        var edit = edit
        // A shorthand for an edit by what it does ("align", "tidy", "row"):
        // the arrangement it names.
        if ["align", "tidy", "tidy_up", "arrange"].contains(edit.tool) {
            edit = Edit(tool: "arrange_on_canvas", arguments: edit.arguments)
        }
        if edit.tool == "arrange_on_canvas", edit.arguments["arrangement"] != nil {
            let words = Set(said.lowercased().split { !$0.isLetter }.map(String.init))
            let named = ["row", "column", "grid"].filter { words.contains($0) || words.contains($0 + "s") }
            if named.count == 1 { edit.arguments["arrangement"] = named[0] }
        }
        // "Move the note to the left" written as left of a card the learner
        // never named: with no "of", "below", "above" or the like in what
        // they said, a side is a nudge that way.
        if edit.tool == "move", edit.arguments["region"] == nil {
            let words = " " + said.lowercased() + " "
            let named = [" of ", " below ", " above ", " under ", " underneath ", " over ", " beneath ", " next to ", " beside "].contains { words.contains($0) }
            let nudges: [(String, Double, Double)] = [("left_of", -300, 0), ("right_of", 300, 0), ("above", 0, -200), ("below", 0, 200)]
            if !named, let nudge = nudges.first(where: { edit.arguments[$0.0] != nil }) {
                for (key, _, _) in nudges { edit.arguments[key] = nil }
                edit.arguments["dx"] = nudge.1
                edit.arguments["dy"] = nudge.2
            }
        }
        // "Move it next to the Drp1 note" written as move with beside: a
        // move takes a distance or a side, so it is the placement beside.
        if edit.tool == "move", let beside = edit.arguments["beside"], edit.arguments["dx"] == nil, edit.arguments["dy"] == nil,
           let cards = edit.arguments["item_ids"] as? [String], !cards.isEmpty {
            edit = Edit(tool: "place_on_canvas", arguments: ["item_ids": cards, "beside": beside])
        }
        if edit.tool == "move", !["below", "above", "left_of", "right_of"].contains(where: { edit.arguments[$0] != nil }) {
            let dx = (edit.arguments["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (edit.arguments["dy"] as? NSNumber)?.doubleValue ?? 0
            if dx == 0, dy == 0 { return nil }
        }
        if edit.tool == "create_canvas_region",
           let cards = edit.arguments["item_ids"] as? [String], !cards.isEmpty,
           !["x", "y", "w", "h"].contains(where: { edit.arguments[$0] != nil }),
           said.range(of: "around", options: .caseInsensitive) == nil,
           let name = edit.arguments["name"] as? String {
            edit = Edit(tool: "place_on_canvas", arguments: ["item_ids": cards, "new_region": name])
        }
        if let name = (edit.arguments["new_region"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let existing = regionNames.first(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            edit.arguments["new_region"] = nil
            edit.arguments["region"] = existing
        }
        return edit
    }
}
