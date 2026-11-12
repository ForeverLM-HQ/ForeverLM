import Foundation
import Observation

/// The Atlas pane's state (docs/atlas-design.md): the Atlas on screen, the
/// concept in focus and the way back to the ones before it, the level of
/// abstraction and the view, and what ForeverLM is writing. One for each
/// window (`StudioWindowState.atlas`), as the Canvas's is: a second window
/// showing the Atlas keeps its own focus, level and way back.
@Observable @MainActor
final class AtlasModel {
    struct Building: Equatable {
        var topic: String
        var stage: AtlasBuilder.Stage
    }

    struct ConceptError: Equatable {
        var conceptID: String
        var message: String
    }

    /// The Atlas on screen.
    private(set) var current: Atlas?
    private(set) var focusID: String?
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    var level: AtlasLevel = .line
    var viewMode: AtlasViewMode = .fisheye
    /// Rows of the Ladder folded shut.
    var collapsed: Set<String> = []

    /// What is being laid out, while a build runs.
    private(set) var building: Building?
    /// Why the last build failed, until the next one starts.
    var buildError: String?
    /// The concept being written in depth.
    private(set) var deepeningID: String?
    var deepenError: ConceptError?
    /// The concept whose cards are being drafted.
    var learningID: String?

    /// Every Atlas made, the latest first, for the title's menu.
    private(set) var listings: [AtlasListing] = []
    /// How the kept cards on each cited source stand, by source id.
    private(set) var memoryMarks: [String: KnowledgeMapMemoryMark] = [:]
    /// The empty state's field.
    var draftTopic = ""

    @ObservationIgnored var buildTask: Task<Result<Atlas, Error>, Never>?
    @ObservationIgnored var deepenTask: Task<Void, Never>?
    @ObservationIgnored private var buildGeneration = 0

    var focusedConcept: AtlasConcept? {
        guard let current, let focusID else { return nil }
        return current.concept(focusID)
    }

    // MARK: Showing

    /// Shows `atlas` at its root, or at `focus`; the same Atlas again keeps
    /// the learner's focus and its history, unless it was written anew
    /// (`asNew`: a Rebuild, whose concept ids name other concepts).
    func show(_ atlas: Atlas, focus: String? = nil, asNew: Bool = false) {
        let same = current?.id == atlas.id && !asNew
        current = atlas
        draftTopic = ""
        if let focus, atlas.concept(focus) != nil {
            if same { self.focus(focus) } else { focusID = focus }
        } else if !same || focusID.flatMap(atlas.concept) == nil {
            focusID = atlas.rootID
        }
        if !same {
            backStack = []
            forwardStack = []
            collapsed = []
            deepenTask?.cancel()
            deepenTask = nil
            deepeningID = nil
            deepenError = nil
        }
    }

    /// A newer copy of the Atlas on screen (a concept deepened); the focus
    /// and history stay.
    func replace(_ atlas: Atlas) {
        guard current?.id == atlas.id else { return }
        current = atlas
    }

    /// Nothing on screen: the Atlas was deleted.
    func clear() {
        buildTask?.cancel()
        deepenTask?.cancel()
        current = nil
        focusID = nil
        backStack = []
        forwardStack = []
        deepeningID = nil
        deepenError = nil
        memoryMarks = [:]
    }

    // MARK: Focus

    /// Focuses `id`, remembering where the learner was for Back. Moving on
    /// stops a deepening still being written for another concept.
    func focus(_ id: String) {
        guard let current, current.concept(id) != nil, id != focusID else { return }
        if let focusID { backStack.append(focusID) }
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack = []
        focusID = id
        settleDeepening(for: id)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let focusID { forwardStack.append(focusID) }
        focusID = previous
        settleDeepening(for: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let focusID { backStack.append(focusID) }
        focusID = next
        settleDeepening(for: next)
    }

    /// The level the focused concept is read at: the chosen one in the
    /// Fisheye, one deeper in the Ladder, whose focused branch reads deeper.
    var focusLevel: AtlasLevel {
        viewMode == .ladder ? level.deeper : level
    }

    /// ↑: one rung more abstract. ↓: one more concrete.
    func climb() { level = level.shallower }
    func descend() { level = level.deeper }

    private func settleDeepening(for id: String) {
        if let deepeningID, deepeningID != id {
            deepenTask?.cancel()
            deepenTask = nil
            self.deepeningID = nil
        }
        if deepenError?.conceptID != id { deepenError = nil }
    }

    // MARK: Writing

    /// A build begins; its number tells a finishing build whether it is
    /// still the latest.
    func beginBuilding(topic: String) -> Int {
        buildGeneration += 1
        building = Building(topic: topic, stage: .reading)
        buildError = nil
        return buildGeneration
    }

    func setStage(_ stage: AtlasBuilder.Stage, generation: Int) {
        guard generation == buildGeneration, building != nil else { return }
        building?.stage = stage
    }

    /// The build numbered `generation` ended, with `error` when it failed.
    func finishBuilding(generation: Int, error: String?) {
        guard generation == buildGeneration else { return }
        building = nil
        buildError = error
        buildTask = nil
    }

    func stopBuilding() {
        buildTask?.cancel()
    }

    func beginDeepening(_ id: String) {
        deepeningID = id
        deepenError = nil
    }

    func endDeepening(_ id: String, error: String?) {
        guard deepeningID == id else { return }
        deepeningID = nil
        deepenTask = nil
        if let error { deepenError = ConceptError(conceptID: id, message: error) }
    }

    func setListings(_ listings: [AtlasListing]) {
        if listings != self.listings { self.listings = listings }
    }

    func setMemoryMarks(_ marks: [String: KnowledgeMapMemoryMark]) {
        if marks != memoryMarks { memoryMarks = marks }
    }

    func memory(of conceptID: String) -> AtlasMemoryStanding {
        guard let current else { return AtlasMemoryStanding(cards: 0, due: 0, fading: 0) }
        return AtlasMemoryStanding.of(sourceIDs: current.groundingSourceIDs(of: conceptID), marks: memoryMarks)
    }
}

extension AtlasConcept {
    /// Whether `level` asks for more than the concept holds yet: a paragraph
    /// or steps not written. The gist and the line are always there.
    func needsDeepening(at level: AtlasLevel) -> Bool {
        guard !deepened else { return false }
        switch level {
        case .gist, .line: return false
        case .paragraph: return paragraph == nil
        case .steps: return steps == nil
        }
    }

    /// What the concept says at `level`, as far as it is written: a level
    /// not written yet reads as the deepest one that is.
    func prose(at level: AtlasLevel) -> String {
        switch level {
        case .gist: return gist
        case .line: return line
        case .paragraph: return paragraph ?? line
        case .steps:
            if let steps, !steps.isEmpty {
                return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            }
            return paragraph ?? line
        }
    }
}
