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

    private(set) var phase: Phase = .idle {
        didSet {
            // The plane's Esc closes the bar first while it shows.
            if (oldValue == .idle) != (phase == .idle) {
                AppModelBridge.studio?.knowledgeMap.send(.voiceShowing(phase != .idle))
            }
        }
    }
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
    /// The request's plan as the model writes it, an edit at a time: each
    /// shows the moment its line arrives ("Finding “sleep” in your
    /// library…"), then what it did, or why it could not. With hidden
    /// thinking off for speed, this is how the learner sees what it is doing.
    private(set) var steps: [Step] = []

    struct Step: Identifiable, Equatable {
        enum State: Equatable { case doing, done, failed }
        let id: Int
        var text: String
        var state: State
    }
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
    /// The arrows the request being carried out has drawn, by their ends: a
    /// model that writes one, then corrects itself and writes it again (a
    /// label the learner never said, taken back), changes the first.
    @ObservationIgnored private var arrowsDrawn: Set<String> = []

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
            steps = []
            remark = nil
            phase = .changing
        }
        return request
    }
    #endif

    var isShowing: Bool { phase != .idle }

    #if DEBUG
    /// Puts the capsule in a state, for a test that draws it.
    func debugShow(_ phase: Phase, heard: String = "", changes: [String] = [], steps: [Step] = [], remark: String? = nil, offersUndo: Bool = false, needsMicrophone: Bool = false) {
        fading?.cancel()
        self.phase = phase
        self.heard = heard
        self.changes = changes
        self.steps = steps
        self.remark = remark
        canUndoRequest = offersUndo
        self.needsMicrophone = needsMicrophone
        hearsOnDevice = true
    }
    #endif

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
        steps = []
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
        steps = []
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

    /// The words, finalized, from whichever way the request was heard. Heard
    /// on this Mac, the words showed as they were said; the recording kept of
    /// them then goes to the transcription model the chat uses, whose words
    /// the request runs on (the on-device ones when that call fails).
    private func finishHearing() async -> String? {
        if #available(macOS 26.0, *), let listener = listener as? KnowledgeMapVoiceListener {
            self.listener = nil
            let (words, recording) = await listener.finish()
            guard let recording else { return words.isEmpty ? nil : words }
            defer { try? FileManager.default.removeItem(at: recording) }
            do {
                let transcribed = try await dictation.transcribeRecording(at: recording)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcribed.isEmpty { return transcribed }
            } catch {
                voiceLogger.error("Transcribing the canvas request failed, using the words heard on this Mac: \(error.localizedDescription, privacy: .public)")
            }
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
        /// The first request was slow to answer, so a second went out.
        var hedged = false
        /// The canvas as the model was told it (the eval writes it out).
        var listing = ""
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
        reasoning: Bool = false,
        earlierTurns: [CanvasVoice.Turn]? = nil
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
        // Just after launch the library may not have reached the canvas yet:
        // its cards are placed but none has content, and the model would be
        // told the canvas is empty (seen in Dev, 2026-10-14). Wait for it, a
        // few seconds at most.
        if snapshot == nil {
            var tries = 0
            while tries < 10, !map.layout.placements.isEmpty,
                  !map.layout.placements.keys.contains(where: { map.nodesByRef[$0] != nil }) {
                try? await Task.sleep(for: .milliseconds(500))
                tries += 1
                await studio.refreshKnowledgeMapContent()
            }
        }
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
            earlier: earlierTurns ?? (snapshot == nil ? earlier : [])
        )
        let placedBefore = map.layout.placements
        // The instructions and the edits are the same every time, so they are
        // the request's stable, cached head; the canvas and the words are its
        // volatile tail, and the user's turn is fixed, so every request shares
        // one prompt-cache session and keeps to the host that cached the head.
        let system = (AITask.canvasVoice.effectivePrompt ?? Prompts.canvasVoice) + "\n\n" + Self.operationsReference
        let volatile = "\n\n" + context.message
        report.listing = context.message
        let ai = studio.aiService
        let activityID = UUID().uuidString
        let sent = Date()
        report.contextMS = ms(contextStarted, sent)

        // The model is called off the main actor; its answer comes back a line
        // at a time, and each line is carried out here as soon as it is whole.
        let (lines, sink) = AsyncStream<String>.makeStream()
        let firstToken = CanvasVoice.Stamp()
        // A request that has not begun to answer by `hedgeAfter`, or failed
        // before it did, is sent again; whichever answers first is carried out
        // and the other stopped, so a slow host costs the learner a fraction
        // of a second, not two, and one failed call is not the end of it.
        let race = CanvasVoice.Race()
        let requestConfig = config
        @Sendable func attempt(_ n: Int) -> Task<Error?, Never> {
            Task.detached(priority: .userInitiated) { () -> Error? in
                defer { race.finish(n) }
                let reader = CanvasVoice.LineReader()
                do {
                    try await AIUsageAttribution.$activityID.withValue(activityID) {
                        try await AIUsageAttribution.$learnerAsked.withValue(true) {
                            try await ai.streamChat(
                                config: requestConfig,
                                system: system,
                                volatileSystem: volatile,
                                messages: [(role: "user", content: n == 1 ? CanvasVoice.userTurn : CanvasVoice.retryTurn)],
                                maxTokens: 1200,
                                // An edit of the canvas is a choice, not a puzzle:
                                // hidden thinking cost the fastest models a second
                                // or more before their first edit (the eval,
                                // KnowledgeMapVoice+Eval.swift). `reasoning` keeps
                                // it, at the lowest effort, for the eval to compare.
                                disablesReasoning: !reasoning
                            ) { delta in
                                guard !delta.isEmpty, race.claim(n) else { return }
                                firstToken.mark()
                                for line in reader.feed(delta) { sink.yield(line) }
                            }
                        }
                    }
                    // An answer of nothing at all still ends the request.
                    if race.claim(n) { for line in reader.finish() { sink.yield(line) } }
                    return nil
                } catch {
                    return error
                }
            }
        }
        let producer = Task.detached(priority: .userInitiated) { () -> Error? in
            let first = attempt(1)
            race.add(first, as: 1)
            let hedgeAt = Date().addingTimeInterval(CanvasVoice.hedgeAfter)
            while Date() < hedgeAt, race.won == nil, !race.isDone(1), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Also when the first failed before saying a word (a refusal, a
            // dropped connection): the second is then a retry, at once. An
            // answer of nothing still claims the race, so it is not repeated.
            let second: Task<Error?, Never>? = race.won == nil && !Task.isCancelled ? attempt(2) : nil
            if let second { race.add(second, as: 2) }
            let errors = await withTaskCancellationHandler {
                // Bound before the tuple: AGENTS.md's Release miscompile.
                let firstError = await first.value
                let secondError = await second?.value ?? nil
                return (firstError, secondError)
            } onCancel: {
                first.cancel()
                second?.cancel()
            }
            sink.finish()
            switch race.won {
            case 1: return errors.0
            case 2: return errors.1
            default: return errors.0 ?? errors.1
            }
        }

        var firstEdit: Date?
        var seen: Set<String> = []
        let stepBefore = map.newestUndoStep
        arrowsDrawn = []
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
                    let resolved = CanvasVoice.matchingKinds(
                        CanvasVoice.Edit(tool: edit.tool, arguments: CanvasVoice.resolved(edit.arguments, in: context)), said: said, context: context
                    )
                    // As it would be carried out, against the regions the canvas listed.
                    if let meant = CanvasVoice.meant(resolved, said: said, regionNames: context.regionNames) { report.edits.append(meant) }
                    continue
                }
                // Shown before it is carried out, so a slow step (a library
                // search) says what it is doing while it does it.
                let step = edit.tool == "say" || !owns(id) ? nil : beginStep(Self.intent(of: edit))
                do {
                    if let done = try await perform(edit, said: said, context: context, studio: studio, map: map, id: id) {
                        firstEdit = firstEdit ?? Date()
                        report.done.append(done)
                        if owns(id) { changes.append(done) }
                        if let step { endStep(step, done, .done) }
                    } else {
                        if edit.tool == "say" { report.remark = (edit.arguments["text"] as? String) ?? report.remark }
                        if let step { steps.removeAll { $0.id == step } }
                    }
                    report.edits.append(edit)
                } catch {
                    report.failures.append(error.localizedDescription)
                    if let step { endStep(step, error.localizedDescription, .failed) }
                }
            }
        }
        if applying { map.endEditGroup() }
        if !isLive(id) || Task.isCancelled { producer.cancel() }
        let streamError = await producer.value
        let finished = Date()
        report.firstTokenMS = ms(sent, firstToken.at)
        report.hedged = race.attempts > 1
        report.modelMS = ms(sent, finished)
        report.firstEditMS = ms(transcribed, firstEdit)
        report.totalMS = ms(began, finished)
        if let streamError, !(streamError is CancellationError) {
            report.failures.insert(streamError.localizedDescription, at: 0)
        }

        let logged = report
        voiceLogger.notice(
            "Canvas voice model=\(logged.model, privacy: .public) transcribe_ms=\(logged.transcribeMS ?? -1, privacy: .public) context_ms=\(logged.contextMS ?? -1, privacy: .public) first_token_ms=\(logged.firstTokenMS ?? -1, privacy: .public) first_edit_ms=\(logged.firstEditMS ?? -1, privacy: .public) total_ms=\(logged.totalMS ?? -1, privacy: .public) edits=\(logged.edits.count, privacy: .public) failed=\(logged.failures.count, privacy: .public) unreadable=\(logged.unreadable, privacy: .public) hedged=\(logged.hedged, privacy: .public)"
        )

        // A say line beside a library search guesses what it would find (seen:
        // "No papers about NAD were found" beside six added); the search says
        // what it found, so the guess is neither shown nor remembered.
        if applying, report.edits.contains(where: { $0.tool == "find_and_place" }), report.failures.isEmpty, !report.done.isEmpty {
            report.remark = nil
            if owns(id) { remark = nil }
        }
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

    private func beginStep(_ text: String) -> Int {
        let id = (steps.map(\.id).max() ?? 0) + 1
        steps.append(Step(id: id, text: text, state: .doing))
        return id
    }

    private func endStep(_ id: Int, _ text: String, _ state: Step.State) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].text = text
        steps[index].state = state
    }

    /// What an edit is about to do, in a few words, from what the model
    /// wrote (the cards it names are counted, not yet looked up).
    static func intent(of edit: CanvasVoice.Edit) -> String {
        let a = edit.arguments
        let cards = (a["item_ids"] as? [Any])?.count ?? 0
        let some = cards == 1 ? "a card" : cards > 1 ? "\(cards) cards" : "cards"
        func quoted(_ key: String) -> String? { (a[key] as? String).map { "“\(short($0))”" } }
        switch edit.tool {
        case "find_and_place":
            let words = (a["words"] as? [Any])?.compactMap { $0 as? String }.joined(separator: ", ") ?? (a["words"] as? String) ?? ""
            return "Finding “\(short(words))” in your library…"
        case "place_on_canvas":
            if let name = quoted("new_region") { return "Grouping \(some) as \(name)…" }
            return "Placing \(some)…"
        case "move": return a["region"] != nil && cards == 0 ? "Moving a region…" : "Moving \(some)…"
        case "write_note": return "Writing \(quoted("text") ?? "a note")…"
        case "create_canvas_region": return "Drawing \(quoted("name") ?? "a region")…"
        case "update_canvas_region": return "Changing a region…"
        case "delete_canvas_region": return "Deleting a region…"
        case "draw_canvas_arrow": return "Drawing an arrow…"
        case "update_canvas_arrow": return "Changing an arrow…"
        case "delete_canvas_arrow": return "Deleting an arrow…"
        case "take_off_canvas": return "Taking \(some) off…"
        case "update_canvas_card": return "Changing \(some)…"
        case "arrange_on_canvas": return "Arranging \(some)…"
        case "undo_canvas": return "Undoing…"
        case "focus_map": return "Showing it…"
        case "ask_canvas": return "Asking the canvas…"
        case "open_card": return "Opening it…"
        case "keep_proposals": return "Keeping proposals…"
        case "dismiss_proposals": return "Setting proposals aside…"
        default: return "\(edit.tool.replacingOccurrences(of: "_", with: " "))…"
        }
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
        _ written: CanvasVoice.Edit,
        said: String,
        context: CanvasVoice.Context,
        studio: StudioViewModel,
        map: KnowledgeMapModel,
        id: Int
    ) async throws -> String? {
        let resolved = CanvasVoice.matchingKinds(
            CanvasVoice.Edit(tool: written.tool, arguments: CanvasVoice.resolved(written.arguments, in: context)), said: said, context: context
        )
        guard let edit = CanvasVoice.meant(resolved, said: said, regionNames: map.layout.regions.values.map(\.name)) else { return nil }
        let arguments = edit.arguments
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
            // Its step says what it is looking for while the search runs.
            return try await findAndPlace(arguments, map: map)
        case "ask_canvas":
            // Ask the Canvas, as its inspector asks: the answer comes later
            // as proposals the learner keeps or dismisses.
            let raw = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard let tool = CanvasAskTool(rawValue: raw) else {
                throw MCPError.invalidInput("Ask the Canvas has no “\(raw)”.")
            }
            // The cards named, else a region's ("what's missing in the NAD
            // region"), else the selection.
            let regionCards = (arguments["region"] as? String).flatMap { Self.regionID($0, map: map) }.map { map.refsInRegion($0) } ?? []
            try studio.beginCanvasAsk(tool, refs: !refs.isEmpty ? refs : !regionCards.isEmpty ? regionCards : map.selection)
            return "Asking: \(tool.title)"
        case "keep_proposals", "dismiss_proposals":
            // What an Ask came back with: kept (sources placed, questions
            // written as notes, arrows drawn) or set aside, as its banner does.
            guard let set = map.proposals else { throw MCPError.invalidInput("No proposals are showing.") }
            let named = (arguments["proposal_ids"] as? [Any])?.compactMap { $0 as? String }.filter { id in set.proposals.contains { $0.id == id } } ?? []
            let keeping = edit.tool == "keep_proposals"
            if named.isEmpty {
                if keeping { map.keepAllProposals() } else { map.dismissAllProposals() }
            } else {
                for proposalID in named {
                    if keeping { map.keepProposal(proposalID, selectsIdea: false) } else { map.dismissProposal(proposalID) }
                }
            }
            let count = named.isEmpty ? set.proposals.count : named.count
            let what = count == 1 ? "a proposal" : "\(count) proposals"
            return keeping ? "Kept \(what)" : "Set aside \(what)"
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
        case "place_on_canvas" where Self.side(arguments, map: map) != nil:
            // A side is the voice's own word, not place_on_canvas's: the
            // cards are set down, then put on that side.
            guard let (side, target) = Self.side(arguments, map: map) else { return nil }
            _ = try await MCPDataStore.editCanvas("place_on_canvas", arguments: ["item_ids": refs])
            Self.setDown(Self.movable(refs, map: map), side, of: target, map: map)
            return "Placed \(Self.naming(refs, map: map))"
        case _ where Self.canvasTools.contains(edit.tool):
            var arguments = arguments
            if edit.tool.hasSuffix("_canvas_arrow") {
                // An arrow's end written as a bare region name (one made
                // earlier in the same answer, which the listing could not
                // give an id) is that region.
                for key in ["from", "to"] {
                    guard let end = arguments[key] as? String, map.layout.placements[end] == nil, !end.hasPrefix("region:"),
                          let id = map.layout.regions.first(where: {
                              $0.value.name.compare(end, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                          })?.key else { continue }
                    arguments[key] = "region:\(id)"
                }
            }
            if edit.tool == "draw_canvas_arrow", let from = arguments["from"] as? String, let to = arguments["to"] as? String {
                guard arrowsDrawn.insert(from + "\u{1}" + to).inserted else {
                    // Drawn already in this answer: the second says how it should be.
                    var again = arguments
                    again["label"] = arguments["label"] as? String ?? ""
                    _ = try await MCPDataStore.editCanvas("update_canvas_arrow", arguments: again)
                    return nil
                }
            }
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
        if let (side, target) = Self.side(arguments, map: map) {
            // A region to a side of something moves with its cards.
            if let named = arguments["region"] as? String, let id = Self.regionID(named, map: map), let region = map.layout.regions[id] {
                let others = map.layout.regions.compactMap { other, r -> KnowledgeMapArranging.Rect? in
                    other == id ? nil : .init(x: r.x, y: r.y, w: r.w, h: r.h)
                }
                var wanted = KnowledgeMapArranging.origin(size: (region.w, region.h), side: side, of: target)
                // A region's name sits above its frame: room for it below the
                // one above, as the canvas leaves between regions.
                if side == .below { wanted.y += KnowledgeMapArranging.insetY }
                if side == .above { wanted.y -= KnowledgeMapArranging.insetY }
                let spot = KnowledgeMapArranging.nearestFreeOrigin(
                    size: (region.w, region.h), near: .init(x: wanted.x + region.w / 2, y: wanted.y + region.h / 2), occupied: others
                )
                _ = try await MCPDataStore.editCanvas("update_canvas_region", arguments: ["region": id, "x": spot.x, "y": spot.y])
                return "Moved “\(Self.short(region.name.isEmpty ? "Untitled region" : region.name))”"
            }
            let placed = Self.movable(arguments["item_ids"] as? [String] ?? [], map: map)
            guard !placed.isEmpty else { throw MCPError.invalidInput("Those cards are not on the canvas, or are in a locked or folded region.") }
            Self.setDown(placed, side, of: target, map: map)
            return "Moved \(Self.naming(placed, map: map))"
        }
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
        let map = studio.knowledgeMap
        let between = (arguments["between"] as? [Any])?.compactMap { Self.rect(of: $0 as? String, map: map) } ?? []
        // Between two things wins over a side of one.
        let side = between.count == 2 ? nil : Self.side(arguments, map: map)
        var place = between.count == 2 || side != nil ? [:] : Self.whereTo(arguments, map: map)
        place["item_ids"] = [ref]
        _ = try await MCPDataStore.editCanvas("place_on_canvas", arguments: place)
        if let (side, target) = side { Self.setDown([ref], side, of: target, map: map) }
        if between.count == 2 {
            // Halfway between the two, as the learner said: set down first,
            // then moved there in the same Undo step.
            // The nearest spot there clear of the cards, so it never lands on one.
            let a = between[0], b = between[1]
            let w = map.cardWidth(of: ref), h = map.cardHeight(of: ref)
            let cards = map.layout.placements.compactMap { other, at -> KnowledgeMapArranging.Rect? in
                other == ref ? nil : .init(x: at.x, y: at.y, w: map.cardWidth(of: other), h: map.cardHeight(of: other))
            }
            let spot = KnowledgeMapArranging.nearestFreeOrigin(
                size: (w, h), near: .init(x: (a.midX + b.midX) / 2, y: (a.midY + b.midY) / 2), occupied: cards
            )
            map.place([(ref: ref, x: spot.x, y: spot.y)])
            map.growRegions(toHold: [ref])
        }
        return "Wrote “\(Self.short(text))”"
    }

    /// The side the learner named ("below the Drp1 note"), and where that
    /// card or region is; nil when none was named, or its target is not on
    /// the canvas.
    private static func side(_ arguments: [String: Any], map: KnowledgeMapModel) -> (KnowledgeMapArranging.Side, KnowledgeMapArranging.Rect)? {
        for side in KnowledgeMapArranging.Side.allCases {
            // One card or region, or several ("below them"): all of them together.
            let named = (arguments[side.rawValue] as? [Any])?.compactMap { $0 as? String } ?? [arguments[side.rawValue] as? String].compactMap { $0 }
            let rects = named.compactMap { rect(of: $0, map: map) }
            if let first = rects.first { return (side, rects.dropFirst().reduce(first) { $0.union($1) }) }
        }
        return nil
    }

    /// The cards of `refs` a spoken edit may move: placed, and in no locked
    /// region (kept where it is) nor folded one (not drawn).
    private static func movable(_ refs: [String], map: KnowledgeMapModel) -> [String] {
        let folded = map.layout.regions.values.filter(\.isCollapsed).map { KnowledgeMapArranging.Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
        return refs.filter { ref in
            guard let at = map.layout.placements[ref], map.lockedRegionID(holding: ref) == nil else { return false }
            let middle = (x: at.x + map.cardWidth(of: ref) / 2, y: at.y + map.cardHeight(of: ref) / 2)
            return !folded.contains { $0.holds(x: middle.x, y: middle.y) }
        }
    }

    /// A region's id, by its id or its name.
    private static func regionID(_ value: String, map: KnowledgeMapModel) -> String? {
        let bare = value.hasPrefix("region:") ? String(value.dropFirst("region:".count)) : value
        if map.layout.regions[bare] != nil { return bare }
        return map.layout.regions.first { $0.value.name.compare(bare, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.key
    }

    /// Sets placed cards down together on `side` of `target`, keeping their
    /// places to one another, at the nearest spot there clear of the other
    /// cards; the regions they land in grow to hold them.
    private static func setDown(_ refs: [String], _ side: KnowledgeMapArranging.Side, of target: KnowledgeMapArranging.Rect, map: KnowledgeMapModel) {
        let moving = Set(refs)
        let rects = refs.compactMap { ref in
            map.layout.placements[ref].map { KnowledgeMapArranging.Rect(x: $0.x, y: $0.y, w: map.cardWidth(of: ref), h: map.cardHeight(of: ref)) }
        }
        guard let first = rects.first else { return }
        let block = rects.dropFirst().reduce(first) { $0.union($1) }
        let wanted = KnowledgeMapArranging.origin(size: (block.w, block.h), side: side, of: target)
        let others = map.layout.placements.compactMap { ref, at -> KnowledgeMapArranging.Rect? in
            moving.contains(ref) ? nil : .init(x: at.x, y: at.y, w: map.cardWidth(of: ref), h: map.cardHeight(of: ref))
        }
        let spot = KnowledgeMapArranging.nearestFreeOrigin(
            size: (block.w, block.h), near: .init(x: wanted.x + block.w / 2, y: wanted.y + block.h / 2), occupied: others
        )
        let dx = spot.x - block.x, dy = spot.y - block.y
        guard dx != 0 || dy != 0 else { return }
        map.place(refs.compactMap { ref in
            map.layout.placements[ref].map { (ref: ref, x: ($0.x + dx).rounded(), y: ($0.y + dy).rounded()) }
        })
        map.growRegions(toHold: refs)
    }

    /// Where a card or a region is on the plane, by its ref, its region id
    /// or its name.
    private static func rect(of value: String?, map: KnowledgeMapModel) -> KnowledgeMapArranging.Rect? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let placement = map.layout.placements[value] {
            return .init(x: placement.x, y: placement.y, w: map.cardWidth(of: value), h: map.cardHeight(of: value))
        }
        let bare = value.hasPrefix("region:") ? String(value.dropFirst("region:".count)) : value
        let region = map.layout.regions[bare] ?? map.layout.regions.values.first {
            $0.name.compare(bare, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return region.map { .init(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
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
        var titles: Set<String> = []
        // A card whose title is one already found (the same note written
        // twice, a paper saved twice) is left out: three alike read as a bug.
        func add(_ ref: String) {
            guard !found.contains(ref), let node = map.nodesByRef[ref] else { return }
            guard titles.insert(node.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)).inserted else { return }
            found.append(ref)
        }
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
        let side = Self.side(arguments, map: map)
        var place = side != nil ? [:] : Self.whereTo(arguments, map: map)
        place["item_ids"] = found
        _ = try await MCPDataStore.editCanvas("place_on_canvas", arguments: place)
        // Cards already in a locked or folded region stay there.
        if let (side, target) = side { Self.setDown(Self.movable(found, map: map), side, of: target, map: map) }
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
            waiting: waiting,
            proposals: map.proposals?.proposals.map { proposal in
                let text: String
                switch proposal.kind {
                case .source: text = proposal.ref.map { map.title(of: $0) } ?? proposal.text ?? ""
                case .question: text = proposal.text ?? ""
                case .edge:
                    let ends = [proposal.from, proposal.to].map { $0.map { map.title(of: $0) } ?? "?" }.joined(separator: " → ")
                    text = ends + ((proposal.label ?? "").isEmpty ? "" : ": \(proposal.label ?? "")")
                }
                return CanvasVoice.Proposal(id: proposal.id, kind: proposal.kind == .edge ? "arrow" : proposal.kind.rawValue, text: text, why: proposal.why)
            },
            proposalsTitle: map.proposals?.title
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
            "- move(item_ids?: [string], region?: string, dx?: number, dy?: number, below?|above?|left_of?|right_of?: string or [string]): Shift placed cards by dx and dy, keeping them where they are to each other; or a region, its cards going with it; or put the cards together below, above, left of or right of a card or region.",
            "- write_note(text: string, region?: string, beside?: string, new_region?: string, between?: [string, string], below?|above?|left_of?|right_of?: string or [string]): A new note card of the learner's words, set down there (between: halfway between two cards or regions; below and the rest: on that side of a card or region), else in the middle of the view.",
            "- find_and_place(words: [string], limit?: integer, region?: string, beside?: string, new_region?: string, below?|above?|left_of?|right_of?: string or [string]): Find what the learner asked for in their library (each entry of words is one search, a short phrase of what they said, such as \"ketone bodies\"; titles first, then by meaning), and set the best (6 unless limit says) down there.",
            "- ask_canvas(question: \"bridge\"|\"connect\"|\"gaps\"|\"summarize\"|\"break_down\"|\"mind_map\"|\"question_map\", item_ids?: [string], region?: string): Ask the Canvas about cards (a region's when a region is named, the SELECTED ones when nothing is): bridge (what links them), connect (arrows between them), gaps (what they leave open), summarize (one Idea of them), break_down (one source into its concepts), mind_map, question_map. Its answer comes later as proposals the learner keeps or dismisses.",
            "- open_card(item_id: string): Open a card beside the canvas to read it.",
            "- keep_proposals(proposal_ids?: [string]): Keep the PROPOSALS the learner wants (all showing when none are named): sources are placed, questions become notes, arrows are drawn.",
            "- dismiss_proposals(proposal_ids?: [string]): Set PROPOSALS aside (all showing when none are named); the next Ask does not offer them again.",
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
    /// Where a local edit sets its cards down: one of a new region, beside a
    /// card, or a region, in that order. The model now and then names two
    /// ("below them" as beside, and the canvas's own name as region), which
    /// place_on_canvas refuses.
    /// A region or card the canvas does not hold (the canvas's own name, a
    /// region the request meant to make) is passed over, and the cards go
    /// to the middle of the view rather than nowhere.
    private static func whereTo(_ arguments: [String: Any], map: KnowledgeMapModel) -> [String: Any] {
        for key in ["new_region", "beside", "region"] {
            guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            switch key {
            case "beside":
                guard map.layout.placements[value] != nil else { continue }
            case "region":
                let bare = value.hasPrefix("region:") ? String(value.dropFirst("region:".count)) : value
                guard map.layout.regions[bare] != nil || map.layout.regions.values.contains(where: {
                    $0.name.compare(bare, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) else { continue }
            default:
                break
            }
            return [key: value]
        }
        return [:]
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
        case "update_canvas_region":
            // Which region, and what became of it: the capsule says so, and so
            // does EARLIER, where "open it again" needs to know what "it" was.
            let region = "“\(short(regionName(arguments["region"], map: map)))”"
            if let collapsed = arguments["collapsed"] as? Bool { return (collapsed ? "Folded up " : "Opened ") + region }
            if let name = arguments["name"] as? String { return "Renamed it “\(short(name))”" }
            if let locked = arguments["locked"] as? Bool { return (locked ? "Locked " : "Unlocked ") + region }
            if arguments["color"] != nil { return "Recoloured \(region)" }
            if arguments["x"] != nil || arguments["y"] != nil { return "Moved \(region)" }
            if arguments["w"] != nil || arguments["h"] != nil || arguments["fit_to_content"] != nil || arguments["grow_to_hold"] != nil {
                return "Resized \(region)"
            }
            return "Changed \(region)"
        case "delete_canvas_region": return "Deleted a region"
        case "draw_canvas_arrow": return "Drew an arrow"
        case "update_canvas_arrow": return "Changed an arrow"
        case "delete_canvas_arrow": return "Deleted an arrow"
        case "update_canvas_card":
            // What became of the cards, as the bar and EARLIER say it.
            if let folded = arguments["folded"] as? Bool { return (folded ? "Folded " : "Unfolded ") + named }
            if let colour = arguments["color"] as? String {
                let name = CanvasVoice.tintTitles[colour.uppercased()].map { " " + $0 } ?? ""
                return colour.isEmpty ? "Took the colour off \(named)" : "Coloured \(named)\(name)"
            }
            if arguments["annotation"] != nil { return "Wrote under \(named)" }
            if let answered = arguments["answered"] as? Bool { return (answered ? "Marked answered: " : "Marked open: ") + named }
            if arguments["page"] != nil { return "Turned the page of \(named)" }
            if arguments["w"] != nil || arguments["h"] != nil || arguments["fit_to_content"] != nil { return "Resized \(named)" }
            return "Restyled \(named)"
        case "arrange_on_canvas":
            switch arguments["arrangement"] as? String {
            case "column": return "Stacked \(named) in a column"
            case "grid": return "Laid \(named) out in a grid"
            default: return "Lined up \(named)"
            }
        case "undo_canvas": return (arguments["redo"] as? Bool ?? false) ? "Redid" : "Undid"
        default: return tool
        }
    }

    /// A region's name, by its id or the name the edit gave it.
    private static func regionName(_ value: Any?, map: KnowledgeMapModel) -> String {
        guard let text = value as? String, !text.isEmpty else { return "the region" }
        let bare = text.hasPrefix("region:") ? String(text.dropFirst("region:".count)) : text
        let name = map.layout.regions[bare]?.name ?? bare
        return name.isEmpty ? "Untitled region" : name
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
        VStack(alignment: .leading, spacing: 5) {
            topRow
            // The plan, a line an edit, as the model writes it.
            if (voice.phase == .changing || voice.phase == .done), !voice.steps.isEmpty {
                ForEach(voice.steps) { step in
                    HStack(spacing: 7) {
                        switch step.state {
                        case .doing: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        case .done: Image(systemName: "checkmark").zoomedSystemFont(size: 9.5, weight: .semibold).foregroundStyle(.secondary).frame(width: 12)
                        case .failed: Image(systemName: "xmark").zoomedSystemFont(size: 9.5, weight: .semibold).foregroundStyle(.red).frame(width: 12)
                        }
                        Text(step.text)
                            .foregroundStyle(step.state == .done ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 2)
                }
                if let remark = voice.remark {
                    Text(remark).italic().foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .zoomedSystemFont(size: 12.5)
        .textSelection(.disabled)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .mapFloatingChrome(cornerRadius: 16)
        // As wide as what it says, up to 560: a short line is a short bar.
        .modifier(CappedWidth(maximum: 560))
        .accessibilityIdentifier("knowledgeMap.voice")
    }

    private var listsSteps: Bool { !voice.steps.isEmpty }

    private var topRow: some View {
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
                // The words heard on this Mac stay while the transcription
                // model writes them out properly.
                ProgressView().controlSize(.small)
                if voice.heard.isEmpty {
                    Text("Hearing…").foregroundStyle(.secondary)
                } else {
                    said
                }
            case .changing:
                ProgressView().controlSize(.small)
                said
                if !listsSteps { changed }
            case .done:
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                // Listed, the steps say what it did; else one line does, and
                // the words heard give way to it.
                if listsSteps || voice.changes.isEmpty { said }
                if !listsSteps { changed }
                if voice.canUndoRequest {
                    Button("Undo") { voice.undoRequest() }
                        .fixedSize()
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
                    .fixedSize()
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

/// Offers its content at most `maximum` wide and takes the width the content
/// wants, so the capsule hugs a short line rather than spreading to its cap.
private struct CappedWidth: ViewModifier {
    let maximum: CGFloat

    func body(content: Content) -> some View {
        CappedWidthLayout(maximum: maximum) { content }
    }
}

private struct CappedWidthLayout: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maximum, maximum), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
