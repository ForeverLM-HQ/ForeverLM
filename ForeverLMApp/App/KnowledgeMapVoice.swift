import Foundation
import os
import SwiftUI

// MARK: - Speaking to the Canvas, on the Mac
//
// Hold S on the plane and speak, then let go; or tap S (or pick Speak to the
// Canvas in the canvas's menu), speak, and stop: it listens until you pause.
// The words are transcribed through OpenRouter, the Canvas Voice model answers
// with edits one a line, and each is carried out as it arrives through the
// edits the MCP canvas tools make. Why it is shaped this way, and the parts
// with no app state, are in Shared/Models/CanvasVoice.swift.
//
// The chrome is on-state only (the canvas's quiet rule): a capsule at the foot
// of the plane while it listens, works, and for a few seconds after, saying
// what it heard and what it changed. Nothing is added to the tool, zoom or
// switch bars.

/// One line per request with where its time went, at `.notice` so it stays in
/// the unified log: "it is slow" is answerable only with these numbers.
private let voiceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "CanvasVoice"
)

@MainActor
@Observable
final class KnowledgeMapVoice {
    /// One for the app: there is one microphone and one open canvas model
    /// (`StudioViewModel.knowledgeMap`).
    static let shared = KnowledgeMapVoice()

    enum Phase: Equatable {
        case idle
        case listening
        /// The recording is being transcribed.
        case hearing
        /// The model is answering, and its edits are carried out as they come.
        case changing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What the learner said, once transcribed.
    private(set) var heard = ""
    /// What was done, a few words an edit.
    private(set) var changes: [String] = []
    /// A line the model said instead of an edit, or the first edit that failed.
    private(set) var remark: String?
    /// Listening until the learner pauses (a tap of S, or the menu) rather
    /// than until they let go of S.
    private(set) var isHandsFree = false

    /// The recorder and its level meter, which the capsule draws.
    @ObservationIgnored let dictation = ReviewDictationService(usageTask: "canvas_voice_dictation")
    @ObservationIgnored private var heldSince: Date?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var fading: Task<Void, Never>?
    /// The newest request, which the capsule shows.
    @ObservationIgnored private var request = 0
    /// Requests up to this one were stopped with the ×.
    @ObservationIgnored private var stoppedThrough = 0

    private init() {}

    var isShowing: Bool { phase != .idle }

    // MARK: Keys, the menu and the ×

    /// S went down on the plane.
    func keyDown() {
        // The recorder takes one recording at a time; the one being
        // transcribed finishes first (about a second).
        guard !dictation.isTranscribing else { return }
        if phase == .listening {
            // A tap started hands-free listening; the next press ends it.
            if isHandsFree { finishListening() }
            return
        }
        startListening()
        heldSince = Date()
    }

    /// S came up, or the plane lost the keyboard while S was held.
    func keyUp() {
        guard let since = heldSince else { return }
        heldSince = nil
        guard phase == .listening else { return }
        if Date().timeIntervalSince(since) < CanvasVoice.tapLimit {
            isHandsFree = true
        } else {
            finishListening()
        }
    }

    /// Speak to the Canvas, from the canvas's menu: listen until the learner
    /// pauses, or stop listening.
    func toggle() {
        if phase == .listening {
            finishListening()
            return
        }
        guard !dictation.isTranscribing else { return }
        startListening()
        isHandsFree = true
    }

    /// The capsule's ×: stop listening, or stop the request, and change
    /// nothing more. What it changed already stays, one Undo away.
    func stop() {
        stoppedThrough = request
        heldSince = nil
        if dictation.isRecording { dictation.cancelRecording() }
        starting?.cancel()
        running?.cancel()
        fading?.cancel()
        phase = .idle
    }

    private func owns(_ id: Int) -> Bool { id == request }
    private func isLive(_ id: Int) -> Bool { id > stoppedThrough }

    // MARK: Listening

    private func startListening() {
        fading?.cancel()
        request &+= 1
        let id = request
        heard = ""
        changes = []
        remark = nil
        isHandsFree = false
        phase = .listening
        starting = Task { [weak self] in
            guard let self else { return }
            await self.dictation.startRecording(automaticallyStopsAfterSilence: true) { [weak self] in
                self?.heardPause()
            }
            guard self.owns(id), self.isLive(id) else {
                if self.dictation.isRecording { self.dictation.cancelRecording() }
                return
            }
            if !self.dictation.isRecording {
                self.fail(self.dictation.errorMessage ?? "Could not start listening", id: id)
            }
        }
    }

    /// The recorder heard speech and then a pause. Held, S decides when to
    /// stop; hands-free, the pause does.
    private func heardPause() {
        guard phase == .listening, heldSince == nil else { return }
        finishListening()
    }

    private func finishListening() {
        guard phase == .listening else { return }
        phase = .hearing
        isHandsFree = false
        heldSince = nil
        let id = request
        let starting = starting
        // A request still changing the canvas finishes first: its edits and
        // this one's are one Undo step each, in the order they were said.
        let previous = running
        running = Task { [weak self] in
            await starting?.value
            guard let self, self.isLive(id) else { return }
            let began = Date()
            let said = await self.dictation.stopAndTranscribe()
            guard self.isLive(id) else { return }
            guard let said, !said.isEmpty else {
                self.fail(self.dictation.errorMessage ?? "Nothing was heard", id: id)
                return
            }
            let transcribed = Date()
            if self.owns(id) {
                self.heard = said
                self.phase = .changing
            }
            await previous?.value
            guard self.isLive(id) else { return }
            await self.change(said, id: id, began: began, transcribed: transcribed)
        }
    }

    // MARK: Changing the canvas

    private func change(_ said: String, id: Int, began: Date, transcribed: Date) async {
        let prepared: (StudioViewModel, KnowledgeMapModel)
        do {
            prepared = try await MCPDataStore.preparedMap(opening: false)
        } catch {
            fail(error.localizedDescription, id: id)
            return
        }
        let (studio, map) = prepared
        guard map.lens == nil else {
            fail("Back to My Canvas first", id: id)
            return
        }
        guard var config = KeychainService.resolveConfig(for: .canvasVoice) else {
            fail(KeychainService.backgroundAIUnavailableMessage(for: .canvasVoice) ?? "Set up AI in Settings to speak to the canvas", id: id)
            return
        }
        config.effort = CanvasVoice.quickestEffort(
            AIRequestOptionSupport.supportedEfforts(provider: config.provider, model: config.model)
        )
        let context = CanvasVoice.context(Self.snapshot(of: map, named: studio.openCanvasName), said: said)
        let system = (AITask.canvasVoice.effectivePrompt ?? Prompts.canvasVoice) + "\n\n" + Self.operationsReference
        let ai = studio.aiService
        let activityID = UUID().uuidString

        // The model is called off the main actor; its answer comes back a line
        // at a time, and each line is carried out here as soon as it is whole.
        let (lines, sink) = AsyncStream<String>.makeStream()
        let producer = Task.detached(priority: .userInitiated) { () -> Error? in
            let reader = CanvasVoice.LineReader()
            do {
                try await AIUsageAttribution.$activityID.withValue(activityID) {
                    try await AIUsageAttribution.$learnerAsked.withValue(true) {
                        try await ai.streamChat(
                            config: config,
                            system: system,
                            messages: [(role: "user", content: context.message)],
                            maxTokens: 1200
                        ) { delta in
                            for line in reader.feed(delta) { sink.yield(line) }
                        }
                    }
                }
                for line in reader.finish() { sink.yield(line) }
                sink.finish()
                return nil
            } catch {
                sink.finish()
                return error
            }
        }

        var applied = 0
        var unreadable = 0
        var failures: [String] = []
        var firstEdit: Date?
        map.beginEditGroup()
        for await raw in lines {
            guard isLive(id), !Task.isCancelled else { break }
            switch CanvasVoice.line(raw) {
            case .blank:
                continue
            case .unreadable:
                unreadable += 1
            case .edit(let edit):
                do {
                    if let done = try await perform(edit, context: context, studio: studio, map: map, id: id) {
                        firstEdit = firstEdit ?? Date()
                        applied += 1
                        if owns(id) { changes.append(done) }
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        }
        map.endEditGroup()
        if !isLive(id) || Task.isCancelled { producer.cancel() }
        let streamError = await producer.value

        func ms(_ from: Date, _ to: Date?) -> Int { to.map { Int(($0.timeIntervalSince(from) * 1000).rounded()) } ?? -1 }
        let model = config.model
        let transcribeMS = ms(began, transcribed), firstEditMS = ms(transcribed, firstEdit), totalMS = ms(began, Date())
        let edits = applied, failed = failures.count, unread = unreadable
        voiceLogger.notice(
            "Canvas voice model=\(model, privacy: .public) transcribe_ms=\(transcribeMS, privacy: .public) first_edit_ms=\(firstEditMS, privacy: .public) total_ms=\(totalMS, privacy: .public) edits=\(edits, privacy: .public) failed=\(failed, privacy: .public) unreadable=\(unread, privacy: .public)"
        )

        guard owns(id), isLive(id) else { return }
        if let streamError, !(streamError is CancellationError) {
            failures.insert(streamError.localizedDescription, at: 0)
        }
        if applied == 0, remark == nil {
            fail(failures.first ?? (unreadable > 0 ? "The answer held no canvas edit" : "Nothing to change"), id: id)
            return
        }
        if remark == nil, let first = failures.first { remark = first }
        phase = .done
        fade(after: 4)
    }

    /// Carries out one edit; what it did in a few words, or nil for a `say`.
    private func perform(
        _ edit: CanvasVoice.Edit,
        context: CanvasVoice.Context,
        studio: StudioViewModel,
        map: KnowledgeMapModel,
        id: Int
    ) async throws -> String? {
        let arguments = CanvasVoice.resolved(edit.arguments, in: context)
        let refs = arguments["item_ids"] as? [String] ?? []
        switch edit.tool {
        case "say":
            let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty, owns(id) { remark = text }
            return nil
        case "move":
            return try move(arguments, map: map)
        case "write_note":
            return try await writeNote(arguments, studio: studio)
        case "find_and_place":
            return try await findAndPlace(arguments, map: map)
        case "focus_map":
            _ = try await MCPDataStore.focusKnowledgeMap(
                itemIDs: refs,
                region: arguments["region"] as? String,
                select: arguments["select"] as? Bool ?? false
            )
            return "Showed \(Self.naming(refs, map: map))"
        case _ where Self.canvasTools.contains(edit.tool):
            _ = try await MCPDataStore.editCanvas(edit.tool, arguments: arguments)
            return Self.done(edit.tool, arguments: arguments, map: map)
        default:
            throw MCPError.invalidInput("“\(edit.tool)” is not a canvas edit.")
        }
    }

    /// `move`: the cards shifted by dx and dy, keeping their places relative
    /// to each other. A region that held one grows to hold it where it lands,
    /// as after a drag; a card in a locked region stays.
    private func move(_ arguments: [String: Any], map: KnowledgeMapModel) throws -> String {
        let placed = (arguments["item_ids"] as? [String] ?? []).filter { map.layout.placements[$0] != nil }
        guard !placed.isEmpty else { throw MCPError.invalidInput("Those cards are not on the canvas.") }
        let dx = MCPDataStore.canvasNumber(arguments["dx"]) ?? 0
        let dy = MCPDataStore.canvasNumber(arguments["dy"]) ?? 0
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { throw MCPError.invalidInput("A move needs a distance.") }
        let free = placed.filter { map.lockedRegionID(holding: $0) == nil }
        guard !free.isEmpty else { throw MCPError.invalidInput("Those cards are in a locked region.") }
        map.place(free.compactMap { ref in
            map.layout.placements[ref].map { (ref: ref, x: ($0.x + dx).rounded(), y: ($0.y + dy).rounded()) }
        })
        map.growRegions(toHold: free)
        return "Moved \(Self.naming(free, map: map))"
    }

    /// `write_note`: a new Idea of the learner's words, set down where they
    /// said (a region, beside a card, a new region), else in the middle of
    /// the view.
    private func writeNote(_ arguments: [String: Any], studio: StudioViewModel) async throws -> String {
        let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw MCPError.invalidInput("A note needs its words.") }
        guard let ref = await studio.createCanvasIdea(title: text) else {
            throw MCPError.database("The note could not be saved.")
        }
        var place = Self.whereTo(arguments)
        place["item_ids"] = [ref]
        _ = try await MCPDataStore.editCanvas("place_on_canvas", arguments: place)
        return "Wrote “\(Self.short(text))”"
    }

    /// `find_and_place`: the library's cards whose titles hold each set of
    /// words, as the canvas's Find or add… finds them, best first, set down
    /// together. A card already on the canvas moves there.
    private func findAndPlace(_ arguments: [String: Any], map: KnowledgeMapModel) async throws -> String {
        let searches = (arguments["words"] as? [Any])?.compactMap { $0 as? String } ?? (arguments["words"] as? String).map { [$0] } ?? []
        let limit = min(max(Int(MCPDataStore.canvasNumber(arguments["limit"]) ?? 6), 1), 24)
        let placed = Set(map.layout.placements.keys)
        var found: [String] = []
        for words in searches {
            let matches = KnowledgeMapAddSearch.matches(words, content: map.content, placed: placed, onPlane: [], index: map.addSearchIndex)
            for ref in matches.library + matches.onCanvas where !found.contains(ref) {
                found.append(ref)
            }
        }
        found = Array(found.prefix(limit))
        guard !found.isEmpty else {
            throw MCPError.notFound("Nothing in your library has “\(searches.joined(separator: "”, “"))” in its title.")
        }
        var place = Self.whereTo(arguments)
        place["item_ids"] = found
        _ = try await MCPDataStore.editCanvas("place_on_canvas", arguments: place)
        return "Added \(Self.naming(found, map: map))"
    }

    private func fail(_ message: String, id: Int) {
        guard owns(id), isLive(id) else { return }
        remark = nil
        phase = .failed(message)
        fade(after: 6)
    }

    private func fade(after seconds: Double) {
        fading?.cancel()
        let id = request
        fading = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.owns(id) else { return }
            switch self.phase {
            case .done, .failed: self.phase = .idle
            default: break
            }
        }
    }

    // MARK: What the model is told

    /// The canvas as it is, in one cheap pass on the main actor.
    static func snapshot(of map: KnowledgeMapModel, named name: String) -> CanvasVoice.Snapshot {
        let layout = map.layout
        let view = map.viewport
        let selected = Set(map.selection)
        let inView = Set(view.visibleRefs)
        let cards: [CanvasVoice.Card] = layout.placements.keys.sorted().compactMap { ref in
            guard let node = map.nodesByRef[ref], let spot = layout.placements[ref] else { return nil }
            return CanvasVoice.Card(
                ref: ref,
                type: node.type,
                title: node.title,
                x: spot.x,
                y: spot.y,
                w: map.cardWidth(of: ref),
                h: map.cardHeight(of: ref),
                regionID: map.regionID(containing: ref),
                inView: inView.contains(ref),
                selected: selected.contains(ref)
            )
        }
        var counts: [String: Int] = [:]
        for card in cards { if let id = card.regionID { counts[id, default: 0] += 1 } }
        let regions = layout.regions.map { id, region in
            CanvasVoice.Region(
                id: id,
                name: map.notebook(ofRegion: id)?.title ?? region.name,
                x: region.x, y: region.y, w: region.w, h: region.h,
                cardCount: counts[id] ?? 0
            )
        }
        let arrows = layout.edges.sorted { $0.key < $1.key }.map {
            CanvasVoice.Arrow(from: $0.value.from, to: $0.value.to, label: $0.value.label)
        }
        let waiting = map.unplacedIdeaRefs.compactMap { ref in
            map.nodesByRef[ref].map { CanvasVoice.Card(ref: ref, type: $0.type, title: $0.title) }
        }
        return CanvasVoice.Snapshot(
            canvasName: name,
            viewCenterX: view.center.x,
            viewCenterY: view.center.y,
            viewWidth: view.span.w,
            viewHeight: view.span.h,
            selectedRegionID: map.selectedRegionID,
            cards: cards,
            regions: regions,
            arrows: arrows,
            waiting: waiting
        )
    }

    /// The MCP canvas tools a spoken request may use, in the order the
    /// model reads them, each with a line of what it is for. Their arguments
    /// are read from the tools' own schemas (`operationsReference`).
    static let toolLines: [(name: String, use: String)] = [
        ("place_on_canvas", "Set cards down, or move cards already placed: into a region, beside a card, or together inside a new region (new_region), else in the middle of the view."),
        ("take_off_canvas", "Take cards off the canvas; they stay in the library."),
        ("create_canvas_region", "Draw a region of that name around cards where they are (all placed), or around cards set down together inside it."),
        ("update_canvas_region", "Rename, recolour, move (x, y: its top left, carrying its cards), resize, fold (collapsed), lock or fit a region."),
        ("delete_canvas_region", "Delete a region; its cards stay unless take_cards_off."),
        ("draw_canvas_arrow", "Draw an arrow from one card (or region:r1) to another."),
        ("update_canvas_arrow", "Change the arrow between two ends: its label, look or stance."),
        ("delete_canvas_arrow", "Delete the arrow between two ends."),
        ("update_canvas_card", "Tint, fold, resize, annotate or restyle cards on the canvas."),
        ("arrange_on_canvas", "Lay at least two placed cards out as a row, a column or a grid, and/or align them."),
        ("undo_canvas", "Take back the last change (redo: true puts it back)."),
        ("focus_map", "Fly the view to cards or a region; nothing moves."),
    ]

    /// The tools `perform` hands to `MCPDataStore.editCanvas`.
    static let canvasTools: Set<String> = Set(toolLines.map(\.name)).subtracting(["focus_map"])

    /// Arguments the model is not given: ids it never sees.
    static let hiddenArguments: Set<String> = ["notebook_id", "edge_id"]

    /// The edits the model may write, after its instructions: the canvas
    /// tools with their arguments as their MCP schemas give them (so the two
    /// cannot drift apart), then the edits only speaking has. Built once, in
    /// a fixed order, so the request's stable head is the same every time
    /// and stays cached.
    static let operationsReference: String = {
        let definitions = Dictionary(
            MCPToolRegistry.knowledgeMapToolDefs.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var lines = ["Edits (one per line, as {\"tool\": name, ...arguments}; ? marks an optional argument):"]
        for (name, use) in toolLines {
            guard let definition = definitions[name] else {
                assertionFailure("No MCP canvas tool named \(name)")
                continue
            }
            lines.append("- \(name)(\(signature(of: definition.inputSchema))): \(use)")
        }
        lines.append(contentsOf: [
            "- move(item_ids: [string], dx: number, dy: number): Shift placed cards by dx and dy, keeping them where they are to each other.",
            "- write_note(text: string, region?: string, beside?: string, new_region?: string): A new note card of the learner's words, set down there, else in the middle of the view.",
            "- find_and_place(words: [string], limit?: integer, region?: string, beside?: string, new_region?: string): Find cards in the learner's library whose titles hold all of one entry's words (each entry is its own search, a few title words), and set the best (6 unless limit says) down there.",
            "- say(text: string): One short sentence to the learner, when you change nothing or must say why.",
        ])
        return lines.joined(separator: "\n")
    }()

    /// A tool's arguments as `name: type`, the required ones first and the
    /// rest in name order.
    static func signature(of schema: [String: Any]) -> String {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        let names = properties.keys.filter { !hiddenArguments.contains($0) }.sorted { a, b in
            let ra = required.contains(a), rb = required.contains(b)
            return ra != rb ? ra : a < b
        }
        return names.map { name in
            let type = typeText(properties[name] as? [String: Any] ?? [:])
            return required.contains(name) ? "\(name): \(type)" : "\(name)?: \(type)"
        }.joined(separator: ", ")
    }

    private static func typeText(_ schema: [String: Any]) -> String {
        if let options = schema["enum"] as? [String] {
            return options.map { "\"\($0)\"" }.joined(separator: "|")
        }
        switch schema["type"] as? String {
        case "array": return "[" + typeText(schema["items"] as? [String: Any] ?? [:]) + "]"
        case "object": return "{card: string}"
        case let type?: return type
        default: return "string"
        }
    }

    // MARK: Words for what was done

    /// Where a note or a find is set down: the arguments of place_on_canvas
    /// that say where.
    private static func whereTo(_ arguments: [String: Any]) -> [String: Any] {
        arguments.filter { ["region", "beside", "new_region"].contains($0.key) }
    }

    private static func done(_ tool: String, arguments: [String: Any], map: KnowledgeMapModel) -> String {
        let refs = arguments["item_ids"] as? [String] ?? []
        let named = naming(refs, map: map)
        switch tool {
        case "place_on_canvas":
            if let region = arguments["new_region"] as? String { return "Grouped \(named) as “\(short(region))”" }
            return "Placed \(named)"
        case "take_off_canvas": return "Took \(named) off"
        case "create_canvas_region": return "Drew “\(short(arguments["name"] as? String ?? "a region"))”"
        case "update_canvas_region": return "Changed a region"
        case "delete_canvas_region": return "Deleted a region"
        case "draw_canvas_arrow": return "Drew an arrow"
        case "update_canvas_arrow": return "Changed an arrow"
        case "delete_canvas_arrow": return "Deleted an arrow"
        case "update_canvas_card": return "Restyled \(named)"
        case "arrange_on_canvas": return "Lined up \(named)"
        case "undo_canvas": return (arguments["redo"] as? Bool ?? false) ? "Redid" : "Undid"
        default: return tool
        }
    }

    /// One card by its title, else how many.
    private static func naming(_ refs: [String], map: KnowledgeMapModel) -> String {
        if refs.count == 1 { return "“\(short(map.title(of: refs[0])))”" }
        return refs.isEmpty ? "it" : "\(refs.count) cards"
    }

    private static func short(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}

// MARK: - The capsule

/// At the foot of the plane while the canvas listens, works, and for a few
/// seconds after: the level while listening, then what was heard and what
/// changed. The × stops it.
struct KnowledgeMapVoiceCapsule: View {
    private var voice: KnowledgeMapVoice { .shared }

    var body: some View {
        HStack(spacing: 10) {
            switch voice.phase {
            case .listening:
                KnowledgeMapVoiceLevels(dictation: voice.dictation)
                Text(voice.isHandsFree ? "Listening" : "Listening… let go of S when done")
                    .foregroundStyle(.secondary)
            case .hearing:
                ProgressView().controlSize(.small)
                Text("Hearing…")
                    .foregroundStyle(.secondary)
            case .changing:
                ProgressView().controlSize(.small)
                said
                changed
            case .done:
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                said
                changed
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .lineLimit(2)
            case .idle:
                EmptyView()
            }
            Button {
                voice.stop()
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.12))
            .help(voice.phase == .listening ? "Stop listening" : "Stop")
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("knowledgeMap.voice.stop")
        }
        .zoomedSystemFont(size: 12.5)
        .textSelection(.disabled)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: 560)
        .mapFloatingChrome(cornerRadius: 16)
        .accessibilityIdentifier("knowledgeMap.voice")
    }

    @ViewBuilder
    private var said: some View {
        if !voice.heard.isEmpty {
            Text("“\(voice.heard)”")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    @ViewBuilder
    private var changed: some View {
        let words = (voice.changes + [voice.remark].compactMap { $0 }).joined(separator: " · ")
        if !words.isEmpty {
            Text(words)
                .lineLimit(2)
                .layoutPriority(1)
        }
    }
}

/// The microphone's level while the canvas listens: a few bars.
private struct KnowledgeMapVoiceLevels: View {
    @ObservedObject var dictation: ReviewDictationService

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(dictation.audioLevels.suffix(9).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: max(3, 16 * level))
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}
