#if os(macOS)
import Foundation

/// Where a source's narration stands, as the Reader's Listen button and the
/// Studio source row read it.
///
/// The source owns its narration: one file per source, shared by every
/// notebook that holds the source, with no per-notebook tile. Listen is
/// "make it, then play": a source with no narration yet is made in the
/// background (the same Generate Audio the source's menu has), and once it is
/// there Listen is Play and starts at once. Nothing is generated live while
/// the learner listens.
enum SourceNarrationState: Equatable {
    /// No narration yet. Listen makes one.
    case notMade
    /// A narration is being made in the background. `percent` is nil until
    /// the first part of it lands, so a run still being prepared never shows
    /// a number.
    case making(percent: Int?)
    /// The narration is there. Listen is Play.
    case ready

    init(hasNarration: Bool, isMaking: Bool, progress: ArticleSpeechChunkProgress?) {
        // A narration that exists wins over a run still winding down: a
        // finished file is what Play plays, whatever else is in flight.
        if hasNarration {
            self = .ready
        } else if isMaking {
            let percent = progress.flatMap { $0.completedChunks > 0 ? $0.percentCompleted : nil }
            self = .making(percent: percent)
        } else {
            self = .notMade
        }
    }

    var isMaking: Bool {
        if case .making = self { return true }
        return false
    }

    /// What pressing Listen does in this state: play (a source with no
    /// narration starts playing as its first parts land and keeps them, a
    /// voice that speaks on the device speaks at once), or wait for a run
    /// already making the narration in the background.
    func listenAction() -> SourceNarrationListenAction {
        switch self {
        case .ready, .notMade: return .play
        case .making: return .wait
        }
    }

    /// The line under the Listen control while a narration is being made.
    static let makingLine = "Making narration, this takes a while"

    /// The hover text of the same state: why nothing plays yet, and that
    /// leaving does not stop it.
    static let makingHelp = "A narration takes a while to make. It keeps going if you leave."

    /// "Making narration, this takes a while" with the share done, once there is one.
    var statusLine: String? {
        guard case .making(let percent) = self else { return nil }
        guard let percent else { return Self.makingLine }
        return "\(Self.makingLine) · \(percent)%"
    }

    /// The line with what the run is doing, once it says: "Cleaning up the
    /// text for easier listening", then "Generating audio · 40%" as parts land.
    func statusLine(stage: String?) -> String? {
        guard case .making(let percent) = self else { return nil }
        if let percent { return "Generating audio · \(percent)%" }
        if let stage, !stage.isEmpty { return stage }
        return Self.makingLine
    }

    /// The fraction the progress ring draws; nil while there is none to draw.
    var fraction: Double? {
        guard case .making(let percent) = self, let percent else { return nil }
        return Double(percent) / 100
    }
}

/// What Listen does for a source.
enum SourceNarrationListenAction: Equatable {
    /// Play the narration there is (or speak on the device).
    case play
    /// A narration is being made; the control shows its progress and Stop.
    case wait
}

/// The narrations the learner asked Listen to make, until each one ends, so
/// the one that finishes while they are still looking at its source starts
/// playing at once.
struct SourceNarrationRequests: Equatable {
    private(set) var sourceIDs: Set<String> = []

    func contains(_ sourceID: String) -> Bool { sourceIDs.contains(sourceID) }

    /// Listen was pressed on a source that has no narration.
    mutating func begin(_ sourceID: String) {
        sourceIDs.insert(sourceID)
    }

    /// The learner stopped it, or it could not start.
    mutating func cancel(_ sourceID: String) {
        sourceIDs.remove(sourceID)
    }

    /// A background run for the source ended. True when the learner asked for
    /// this narration with Listen and it is now there: it should play. A run
    /// started some other way (the source's menu, an assistant, automatic
    /// audio) ends quietly.
    mutating func end(_ sourceID: String, outcome: ArticleSpeechBackgroundGenerationOutcome) -> Bool {
        guard sourceIDs.remove(sourceID) != nil else { return false }
        return outcome == .ready
    }
}

/// Where a finished narration starts playing, and where it is listed.
enum SourceNarration {
    /// Whether a narration that just finished starts playing by itself: only
    /// while the learner is still at the source, and never over audio they are
    /// already hearing.
    static func startsPlayingWhenMade(otherSourceIsActive: Bool) -> Bool {
        !otherSourceIsActive
    }

    /// Whether a source's narration is listed in a notebook's Studio as a
    /// Narration.
    /// A spoken script (an explainer's, an audio overview's) is the narration
    /// of its own artifact, which lists itself.
    static func isListedAsArtifact(sourceURL: String) -> Bool {
        !TextToSpeechPreparationPolicy.isSpokenScript(url: sourceURL)
    }

    /// The card's caption.
    static func caption(forSourceTitled title: String) -> String {
        "Narration of \(title)"
    }
}
#endif
