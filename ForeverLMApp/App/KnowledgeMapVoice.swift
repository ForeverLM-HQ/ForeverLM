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
    /// What the learner said: as they say it when this Mac hears them
    /// (`KnowledgeMapVoiceListener`), else once it is transcribed.
    private(set) var heard = ""
    /// The microphone's last levels, 0…1, newest last, while this Mac hears.
    private(set) var levels: [Double] = Array(repeating: 0.08, count: 9)
    /// Whether this Mac is hearing the request itself, rather than recording
    /// it for the Dictation model.
    private(set) var hearsOnDevice = false
    /// What was done, a few words an edit.
    private(set) var changes: [String] = []
    /// A line the model said instead of an edit, or the first edit that failed.
    private(set) var remark: String?
    /// The failure showing is the microphone refused: the capsule offers the
    /// privacy pane that allows it.
    private(set) var needsMicrophone = false
    /// Listening until the learner pauses (a tap of S, or the menu) rather
    /// than until they let go of S.
    private(set) var isHandsFree = false
    /// The request showing changed the canvas and is still the newest Undo
    /// step: the capsule offers to take it back.
    private(set) var canUndoRequest = false
    @ObservationIgnored private weak var undoMap: KnowledgeMapModel?
    @ObservationIgnored private var undoStep: Date?

    /// The recorder and its level meter, which the capsule draws, when the
    /// words go to the Dictation model.
    @ObservationIgnored let dictation = ReviewDictationService(usageTask: "canvas_voice_dictation")
    /// The on-device listener while it hears (a `KnowledgeMapVoiceListener`,
    /// which needs macOS 26).
    @ObservationIgnored private var listener: AnyObject?
    /// Hands-free listening ends on a pause: speech heard, then this long
    /// below the quiet level.
    @ObservationIgnored private var spokeAt: Date?
    @ObservationIgnored private var quietSince: Date?
    private static let speechLevel = 0.16
    private static let quietLevel = 0.12
    private static let pauseLength: TimeInterval = 1.2
    @ObservationIgnored private var heldSince: Date?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var fading: Task<Void, Never>?
    @ObservationIgnored private var embeddingWarmed = false
    /// The requests spoken in this sitting and what they did, newest last.
    @ObservationIgnored private var earlier: [CanvasVoice.Turn] = []
    /// The newest request, which the capsule shows.
    @ObservationIgnored private var request = 0
    /// Requests up to this one were stopped with the ×.
    @ObservationIgnored private var stoppedThrough = 0

    private init() {
        #if DEBUG
        listenForEvals()
        #endif
    }

    #if DEBUG
    /// The eval's request (KnowledgeMapVoice+Eval.swift): a new id, shown in
    /// the capsule when its edits are carried out.
    func beginEvalRequest(said: String, showing: Bool) -> Int {
        request &+= 1
        if showing {
            fading?.cancel()
            heard = said
            changes = []
            remark = nil
            phase = .changing
        }
        return request
    }
    #endif

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
        cancelListener()
        starting?.cancel()
        running?.cancel()
        fading?.cancel()
        canUndoRequest = false
        phase = .idle
    }

    /// The capsule's Undo: the request just carried out, taken back in one
    /// step, as ⌘Z would, while nothing has been changed since.
    func undoRequest() {
        guard canUndoRequest, let map = undoMap, let step = undoStep, map.newestUndoStep == step else {
            canUndoRequest = false
            return
        }
        map.undo()
        canUndoRequest = false
        earlier.append(CanvasVoice.Turn(said: "undo that", done: ["Undid it"]))
        if earlier.count > CanvasVoice.maximumTurns { earlier.removeFirst(earlier.count - CanvasVoice.maximumTurns) }
        changes = ["Undone"]
        remark = nil
        phase = .done
        fade(after: 2.5)
    }

    private func owns(_ id: Int) -> Bool { id == request }
    private func isLive(_ id: Int) -> Bool { id > stoppedThrough }

    // MARK: Listening

    private func startListening() {
        fading?.cancel()
        needsMicrophone = false
        canUndoRequest = false
        request &+= 1
        let id = request
        heard = ""
        changes = []
        remark = nil
        isHandsFree = false
        hearsOnDevice = false
        levels = Array(repeating: 0.08, count: levels.count)
        spokeAt = nil
        quietSince = nil
        phase = .listening
        warm()
        starting = Task { [weak self] in
            guard let self else { return }
            if await self.startHearingOnDevice(id: id) { return }
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

    /// Hears the request on this Mac, the words showing as they are said,
    /// when it has a speech model for the learner's language. False when it
    /// has none (yet): the request is recorded for the Dictation model.
    private func startHearingOnDevice(id: Int) async -> Bool {
        guard #available(macOS 26.0, *),
              let locale = await KnowledgeMapVoiceListener.locale(),
              await KnowledgeMapVoiceListener.isReady(for: locale),
              owns(id), isLive(id), phase == .listening || phase == .hearing else { return false }
        let listener = KnowledgeMapVoiceListener()
        listener.onWords = { [weak self] words in
            guard let self, self.owns(id), self.phase == .listening else { return }
            self.heard = words
        }
        listener.onLevel = { [weak self] level in
            guard let self, self.owns(id) else { return }
            self.hear(level: level)
        }
        self.listener = listener
        hearsOnDevice = true
        do {
            try await listener.start(locale: locale)
        } catch KnowledgeMapVoiceListener.Failure.microphoneDenied {
            cancelListener()
            fail(KnowledgeMapVoiceListener.Failure.microphoneDenied.localizedDescription, id: id)
            needsMicrophone = owns(id)
            return true
        } catch {
            // This Mac cannot hear it after all (a speech model mid-update, a
            // permission the recognizer wants): the request is recorded for
            // the Dictation model, as on a Mac with no speech model.
            voiceLogger.error("On-device listening did not start, recording for the Dictation model: \(error.localizedDescription, privacy: .public)")
            cancelListener()
            hearsOnDevice = false
            return false
        }
        if !owns(id) || !isLive(id) || phase != .listening && phase != .hearing { cancelListener() }
        return true
    }

    /// The level while this Mac hears: the capsule's bars, and the pause that
    /// ends hands-free listening.
    private func hear(level: Double) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
        let now = Date()
        if level >= Self.speechLevel {
            spokeAt = now
            quietSince = nil
        } else if level <= Self.quietLevel, spokeAt != nil {
            if quietSince == nil { quietSince = now }
            if let quiet = quietSince, now.timeIntervalSince(quiet) >= Self.pauseLength { heardPause() }
        }
    }

    private func cancelListener() {
        if #available(macOS 26.0, *), let listener = listener as? KnowledgeMapVoiceListener { listener.cancel() }
        listener = nil
    }

    /// The words, finalized, from whichever way the request was heard.
    private func finishHearing() async -> String? {
        if #available(macOS 26.0, *), let listener = listener as? KnowledgeMapVoiceListener {
            self.listener = nil
            let words = await listener.finish()
            return words.isEmpty ? nil : words
        }
        return await dictation.stopAndTranscribe()
    }

    /// Readies the request while the learner is still speaking: the
    /// connection to the model's host, its endpoints and tiers, so letting go
    /// of S starts the request at once.
    private func warm() {
        guard let config = Self.config() else { return }
        let ai = AppModelBridge.studio?.aiService
        Task.detached(priority: .userInitiated) { await ai?.warmTextRoute(config) }
        // The on-device embedding model a library search loads (find_and_place),
        // once a launch: loaded cold it added two seconds to the first search.
        guard !embeddingWarmed else { return }
        embeddingWarmed = true
        Task.detached(priority: .utility) { _ = try? await AIService().embedText("canvas") }
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
            let onDevice = self.hearsOnDevice
            let said = await self.finishHearing()
            guard self.isLive(id) else { return }
            guard let said, !said.isEmpty else {
                self.fail((onDevice ? nil : self.dictation.errorMessage) ?? "Nothing was heard", id: id)
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

    /// What one request did and where its time went: logged, and what the
    /// DEBUG eval writes out (KnowledgeMapVoice+Eval.swift).
    struct Report {
        var model = ""
        var said = ""
        /// From letting go to the words.
        var transcribeMS: Int?
        /// Reading the canvas and writing the request.
        var contextMS: Int?
        /// From sending the request to the model's first token, and to its last line.
        var firstTokenMS: Int?
        var modelMS: Int?
        /// From the words to the first edit carried out (or, not applying, read).
        var firstEditMS: Int?
        /// From letting go to the last edit.
        var totalMS: Int?
        var lines: [String] = []
        var edits: [CanvasVoice.Edit] = []
        var done: [String] = []
        var failures: [String] = []
        var unreadable = 0
        var remark: String?
        /// Why the request was never sent.
        var refused: String?
    }

    /// Asks the Canvas Voice model for the edits `said` asks of the open
    /// canvas and carries each out as its line arrives. `applying` false
    /// reads the edits without carrying them out, `model` asks another
    /// OpenRouter model than the task's own and `snapshot` stands in for the
    /// open canvas: the DEBUG eval's ways in. The learner's path passes none.
    @discardableResult
    func change(
        _ said: String,
        id: Int,
        began: Date,
        transcribed: Date,
        applying: Bool = true,
        model: String? = nil,
        snapshot: CanvasVoice.Snapshot? = nil,
        reasoning: Bool = false
    ) async -> Report {
        var report = Report(said: said)
        func ms(_ from: Date, _ to: Date?) -> Int? { to.map { Int(($0.timeIntervalSince(from) * 1000).rounded()) } }
        report.transcribeMS = ms(began, transcribed)
        func refuse(_ message: String) -> Report {
            report.refused = message
            if applying { fail(message, id: id) }
            return report
        }
        let prepared: (StudioViewModel, KnowledgeMapModel)
        do {
            prepared = try await MCPDataStore.preparedMap(opening: false)
        } catch {
            return refuse(error.localizedDescription)
        }
        let (studio, map) = prepared
        if applying, map.lens != nil { return refuse("Back to My Canvas first") }
        guard var config = Self.config(model: model) else {
            return refuse(KeychainService.backgroundAIUnavailableMessage(for: .canvasVoice) ?? "Set up AI in Settings to speak to the canvas")
        }
        report.model = config.model
        config.effort = CanvasVoice.quickestEffort(
            AIRequestOptionSupport.supportedEfforts(provider: config.provider, model: config.model)
        )
        let contextStarted = Date()
        let context = CanvasVoice.context(
            snapshot ?? Self.snapshot(of: map, named: studio.openCanvasName),
            said: said,
            earlier: snapshot == nil ? earlier : []
        )
        let placedBefore = map.layout.placements
        // The instructions and the edits are the same every time, so they are
        // the request's stable, cached head; the canvas and the words are its
        // volatile tail, and the user's turn is fixed, so every request shares
        // one prompt-cache session and keeps to the host that cached the head.
        let system = (AITask.canvasVoice.effectivePrompt ?? Prompts.canvasVoice) + "\n\n" + Self.operationsReference
        let volatile = "\n\n" + context.message
        let ai = studio.aiService
        let activityID = UUID().uuidString
        let sent = Date()
        report.contextMS = ms(contextStarted, sent)

        // The model is called off the main actor; its answer comes back a line
        // at a time, and each line is carried out here as soon as it is whole.
        let (lines, sink) = AsyncStream<String>.makeStream()
        let firstToken = CanvasVoice.Stamp()
        let producer = Task.detached(priority: .userInitiated) { () -> Error? in
            let reader = CanvasVoice.LineReader()
            do {
                try await AIUsageAttribution.$activityID.withValue(activityID) {
                    try await AIUsageAttribution.$learnerAsked.withValue(true) {
                        try await ai.streamChat(
                            config: config,
                            system: system,
                            volatileSystem: volatile,
                            messages: [(role: "user", content: CanvasVoice.userTurn)],
                            maxTokens: 1200,
                            // An edit of the canvas is a choice, not a puzzle:
                            // hidden thinking cost the fastest models a second
                            // or more before their first edit (the eval,
                            // KnowledgeMapVoice+Eval.swift). `reasoning` keeps
                            // it, at the lowest effort, for the eval to compare.
                            disablesReasoning: !reasoning
                        ) { delta in
                            if !delta.isEmpty { firstToken.mark() }
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

        var firstEdit: Date?
        var seen: Set<String> = []
        let stepBefore = map.newestUndoStep
        if applying { map.beginEditGroup() }
        for await raw in lines {
            guard isLive(id), !Task.isCancelled else { break }
            report.lines.append(raw)
            // A model now and then writes an edit twice; it is carried out once.
            guard seen.insert(raw.trimmingCharacters(in: .whitespacesAndNewlines)).inserted else { continue }
            switch CanvasVoice.line(raw) {
            case .blank:
                continue
            case .unreadable:
                report.unreadable += 1
            case .edit(let edit):
                guard applying else {
                    firstEdit = firstEdit ?? Date()
                    report.edits.append(CanvasVoice.Edit(tool: edit.tool, arguments: CanvasVoice.resolved(edit.arguments, in: context)))
                    continue
                }
                do {
                    if let done = try await perform(edit, context: context, studio: studio, map: map, id: id) {
                        firstEdit = firstEdit ?? Date()
                        report.done.append(done)
                        if owns(id) { changes.append(done) }
                    } else if edit.tool == "say" {
                        report.remark = (edit.arguments["text"] as? String) ?? report.remark
                    }
                    report.edits.append(edit)
                } catch {
                    report.failures.append(error.localizedDescription)
                }
            }
        }
        if applying { map.endEditGroup() }
        if !isLive(id) || Task.isCancelled { producer.cancel() }
        let streamError = await producer.value
        let finished = Date()
        report.firstTokenMS = ms(sent, firstToken.at)
        report.modelMS = ms(sent, finished)
        report.firstEditMS = ms(transcribed, firstEdit)
        report.totalMS = ms(began, finished)
        if let streamError, !(streamError is CancellationError) {
            report.failures.insert(streamError.localizedDescription, at: 0)
        }

        let logged = report
        voiceLogger.notice(
            "Canvas voice model=\(logged.model, privacy: .public) transcribe_ms=\(logged.transcribeMS ?? -1, privacy: .public) context_ms=\(logged.contextMS ?? -1, privacy: .public) first_token_ms=\(logged.firstTokenMS ?? -1, privacy: .public) first_edit_ms=\(logged.firstEditMS ?? -1, privacy: .public) total_ms=\(logged.totalMS ?? -1, privacy: .public) edits=\(logged.edits.count, privacy: .public) failed=\(logged.failures.count, privacy: .public) unreadable=\(logged.unreadable, privacy: .public)"
        )

        if applying {
            earlier.append(CanvasVoice.Turn(said: said, done: report.done + [report.remark].compactMap { $0 }))
            if earlier.count > CanvasVoice.maximumTurns { earlier.removeFirst(earlier.count - CanvasVoice.maximumTurns) }
            // The cards the request set down, moved or restyled are selected,
            // so the learner sees what changed and "these" in the next
            // request means them. Undo selects nothing: what it restored is
            // not what was asked for.
            let touched = map.layout.placements.filter { placedBefore[$0.key] != $0.value }.keys.sorted()
            if !touched.isEmpty, !report.edits.contains(where: { $0.tool == "undo_canvas" }) {
                map.selection = touched
                map.send(.select(refs: touched))
            }
        }
        guard applying, owns(id), isLive(id) else { return report }
        let applied = report.done.count
        if applied == 0, remark == nil {
            fail(report.failures.first ?? (report.unreadable > 0 ? "The answer held no canvas edit" : "Nothing to change"), id: id)
            return report
        }
        if remark == nil, let first = report.failures.first { remark = first }
        // A request that made a step of its own (not an undo) can be taken
        // back from the capsule.
        let step = map.newestUndoStep
        if step != stepBefore, step != nil, !report.edits.contains(where: { $0.tool == "undo_canvas" }) {
            undoMap = map
            undoStep = step
            canUndoRequest = true
        }
        phase = .done
        fade(after: canUndoRequest ? 6 : 4)
        return report
    }

    /// The Canvas Voice task's config; in a DEBUG eval, a named model's.
    static func config(model: String? = nil) -> AITaskConfig? {
        #if DEBUG
        if let model { return AIModelQualification.evalConfig(model: model, task: .canvasVoice) }
        #endif
        KeychainService.seedCanvasVoiceRoute()
        return KeychainService.resolveConfig(for: .canvasVoice)
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
            return try await move(arguments, map: map)
        case "write_note":
            return try await writeNote(arguments, studio: studio)
        case "find_and_place":
            return try await findAndPlace(arguments, map: map)
        case "ask_canvas":
            // Ask the Canvas, as its inspector asks: the answer comes later
            // as proposals the learner keeps or dismisses.
            let raw = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard let tool = CanvasAskTool(rawValue: raw) else {
                throw MCPError.invalidInput("Ask the Canvas has no “\(raw)”.")
            }
            try studio.beginCanvasAsk(tool, refs: refs.isEmpty ? map.selection : refs)
            return "Asking: \(tool.title)"
        case "open_card":
            guard let ref = (arguments["item_id"] as? String).flatMap({ map.nodesByRef[$0] != nil ? $0 : nil }) else {
                throw MCPError.invalidInput("That card is not on the canvas or in the library.")
            }
            await studio.openKnowledgeMapItemBeside(ref, in: studio.activeWindowState)
            return "Opened \(Self.naming([ref], map: map))"
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
    /// as after a drag; a card in a locked region stays. A region named moves
    /// with its cards, as dragging its frame does.
    private func move(_ arguments: [String: Any], map: KnowledgeMapModel) async throws -> String {
        let dx = MCPDataStore.canvasNumber(arguments["dx"]) ?? 0
        let dy = MCPDataStore.canvasNumber(arguments["dy"]) ?? 0
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { throw MCPError.invalidInput("A move needs a distance.") }
        if let named = (arguments["region"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            // Its id, or the name the model wrote for it instead.
            let bare = named.hasPrefix("region:") ? String(named.dropFirst("region:".count)) : named
            let byName = map.layout.regions.first { $0.value.name.compare(bare, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            guard let id = map.layout.regions[bare] != nil ? bare : byName?.key, let region = map.layout.regions[id] else {
                throw MCPError.invalidInput("No region “\(named)” on the canvas.")
            }
            _ = try await MCPDataStore.editCanvas("update_canvas_region", arguments: [
                "region": id, "x": (region.x + dx).rounded(), "y": (region.y + dy).rounded(),
            ])
            return "Moved “\(Self.short(region.name.isEmpty ? "Untitled region" : region.name))”"
        }
        let placed = (arguments["item_ids"] as? [String] ?? []).filter { map.layout.placements[$0] != nil }
        guard !placed.isEmpty else { throw MCPError.invalidInput("Those cards are not on the canvas.") }
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

    /// `find_and_place`: the library's cards for each search, best first, set
    /// down together. A card whose title holds every word of the search comes
    /// first, as the canvas's Find or add… finds it; then the library's own
    /// search by meaning fills the rest (so "ketone bodies" finds the paper on
    /// beta-hydroxybutyrate), run off the main actor. A card already on the
    /// canvas moves there.
    private func findAndPlace(_ arguments: [String: Any], map: KnowledgeMapModel) async throws -> String {
        let searches = (arguments["words"] as? [Any])?.compactMap { $0 as? String } ?? (arguments["words"] as? String).map { [$0] } ?? []
        let limit = min(max(Int(MCPDataStore.canvasNumber(arguments["limit"]) ?? 6), 1), 24)
        let placed = Set(map.layout.placements.keys)
        // One phrase split into single words ("ketone", "bodies") is searched
        // as the phrase it was; alone, "bodies" would find every Lewy body.
        let split = searches.count > 1 && searches.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).contains(" ") }
        let phrases = split ? [searches.joined(separator: " ")] : searches
        var found: [String] = []
        func add(_ ref: String) { if !found.contains(ref), map.nodesByRef[ref] != nil { found.append(ref) } }
        for phrase in phrases {
            let matches = KnowledgeMapAddSearch.matches(phrase, content: map.content, placed: placed, onPlane: [], index: map.addSearchIndex)
            for ref in matches.library + matches.onCanvas { add(ref) }
        }
        if found.count < limit {
            for phrase in phrases {
                let ids = try await Task.detached(priority: .userInitiated) {
                    try await MCPDataStore().rankedSourceIDs(query: phrase, limit: limit)
                }.value
                for id in ids { add(KnowledgeMap.ItemRef(kind: .source, id: id).description) }
            }
        }
        found = Array(found.prefix(limit))
        guard !found.isEmpty else {
            throw MCPError.notFound("Nothing in your library matches “\(phrases.joined(separator: "”, “"))”.")
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
            case .done, .failed:
                self.canUndoRequest = false
                self.phase = .idle
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
            "- move(item_ids?: [string], region?: string, dx: number, dy: number): Shift placed cards by dx and dy, keeping them where they are to each other; or a region, its cards going with it.",
            "- write_note(text: string, region?: string, beside?: string, new_region?: string): A new note card of the learner's words, set down there, else in the middle of the view.",
            "- find_and_place(words: [string], limit?: integer, region?: string, beside?: string, new_region?: string): Find what the learner asked for in their library (each entry of words is one search, a short phrase of what they said, such as \"ketone bodies\"; titles first, then by meaning), and set the best (6 unless limit says) down there.",
            "- ask_canvas(question: \"bridge\"|\"connect\"|\"gaps\"|\"summarize\"|\"break_down\"|\"mind_map\"|\"question_map\", item_ids?: [string]): Ask the Canvas about cards (the SELECTED ones when none are named): bridge (what links them), connect (arrows between them), gaps (what they leave open), summarize (one Idea of them), break_down (one source into its concepts), mind_map, question_map. Its answer comes later as proposals the learner keeps or dismisses.",
            "- open_card(item_id: string): Open a card beside the canvas to read it.",
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
                if voice.hearsOnDevice {
                    KnowledgeMapVoiceBars(levels: voice.levels)
                } else {
                    KnowledgeMapVoiceLevels(dictation: voice.dictation)
                }
                if voice.heard.isEmpty {
                    Text(voice.isHandsFree ? "Listening" : "Listening… let go of S when done")
                        .foregroundStyle(.secondary)
                } else {
                    Text(voice.heard)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
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
                if voice.canUndoRequest {
                    Button("Undo") { voice.undoRequest() }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.12))
                        .help("Take back what this request changed (⌘Z)")
                        .accessibilityIdentifier("knowledgeMap.voice.undo")
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .lineLimit(2)
                if voice.needsMicrophone {
                    Button("Open Settings") {
                        // The Ventura+ anchor first, then the older ones.
                        for raw in [
                            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                        ] {
                            if let url = URL(string: raw), NSWorkspace.shared.open(url) { break }
                        }
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.12))
                    .accessibilityIdentifier("knowledgeMap.voice.microphoneSettings")
                }
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

/// The recorder's level while the canvas records for the Dictation model.
private struct KnowledgeMapVoiceLevels: View {
    @ObservedObject var dictation: ReviewDictationService

    var body: some View {
        KnowledgeMapVoiceBars(levels: Array(dictation.audioLevels.suffix(9)))
    }
}

/// The microphone's level while the canvas listens: a few bars.
private struct KnowledgeMapVoiceBars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: max(3, 16 * level))
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}
