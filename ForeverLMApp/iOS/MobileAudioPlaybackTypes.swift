// The playback, book and sync status types the audio view model publishes.

import Foundation

struct MobileSourceSyncDiagnostic: Equatable {
    let accountStatus: String
    let knowledgeZoneStatus: String
    let sourceRecordCount: Int?
    let decodedSourceCount: Int?
    let zoneRecordCount: Int?
    let zoneRecordTypes: String?
    let errorMessage: String?
    let checkedAt: Date

    var lines: [String] {
        var values = [
            "iCloud account: \(accountStatus)",
            "Knowledge zone: \(knowledgeZoneStatus)",
        ]
        if let sourceRecordCount {
            values.append("Source records: \(sourceRecordCount)")
        }
        if let decodedSourceCount {
            values.append("Decoded sources: \(decodedSourceCount)")
        }
        if let zoneRecordCount {
            values.append("Zone records: \(zoneRecordCount)")
        }
        if let zoneRecordTypes {
            values.append("Zone record types: \(zoneRecordTypes)")
        }
        if let errorMessage {
            values.append("Error: \(errorMessage)")
        }
        values.append("Checked: \(checkedAt.formatted(date: .omitted, time: .standard))")
        return values
    }
}

enum MobileAudioPlaybackSpeed {
    /// Speeds the Listen tab offers. Playback goes through `AVPlayer`, whose
    /// default time-pitch algorithm (`.timeDomain`) keeps speech
    /// intelligible from 1/32× to 32×, so nothing below caps the table at 2×.
    static let options: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0]
    static let minimum: Float = 0.5
    static let maximum: Float = 3.0
    /// The span a voice agent may pick from: the slowest and fastest of `options`.
    static let agentRange: ClosedRange<Double> = 0.75...3.0

    static func clamped(_ speed: Float) -> Float {
        min(max(speed, minimum), maximum)
    }

    static func label(for speed: Float) -> String {
        let value = clamped(speed)
        if value.rounded() == value {
            return "\(Int(value))x"
        }
        var formatted = String(format: "%.2f", value)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return "\(formatted)x"
    }
}

/// Listen's sleep timer: playback pauses when it runs out, at the place it
/// had reached, so the next Listen carries on from there (product owner,
/// 2026-11-13: "add a sleep timer for when i listen to a book or paper").
enum MobileSleepTimer: Equatable {
    /// Pause at this moment.
    case at(Date)
    /// Pause when what is playing ends, and do not carry on into the next
    /// chapter of a book.
    case endOfSource

    static let minuteOptions = [5, 10, 15, 30, 45, 60]

    static func minutes(_ minutes: Int, from now: Date) -> MobileSleepTimer {
        .at(now.addingTimeInterval(TimeInterval(minutes) * 60))
    }

    /// True once a timed timer has run out. The end of a source is not a
    /// time; the player says when that comes.
    func isDue(at now: Date) -> Bool {
        if case .at(let date) = self { return now >= date }
        return false
    }

    /// "14:05" left on a timed timer, rounded up so it never reads 0:00
    /// while it still runs; nil for the end of a source.
    func remainingLabel(at now: Date) -> String? {
        guard case .at(let date) = self else { return nil }
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum MobileBookPlaybackPreferences {
    static var automaticallyContinues: Bool {
        get { Preferences.value(Prefs.Mobile.automaticallyContinuesBooks) }
        set { Preferences.set(newValue, for: Prefs.Mobile.automaticallyContinuesBooks) }
    }

    static var hasAskedToAutomaticallyContinue: Bool {
        get { Preferences.value(Prefs.Mobile.hasAskedToAutomaticallyContinueBooks) }
        set { Preferences.set(newValue, for: Prefs.Mobile.hasAskedToAutomaticallyContinueBooks) }
    }
}

struct MobileBookContinuationOffer: Equatable {
    let completedSourceID: String
    let nextSourceID: String
    let nextTitle: String
}

/// One line of catalog sync state for the home screen: what is running, step
/// + detail text, and a 0–1 fraction when the phase can honestly estimate one
/// (nil → indeterminate spinner).
struct MobileCatalogSyncStatus: Equatable {
    enum Phase: Equatable {
        /// The library is arriving on this phone for the first time.
        case arriving
        /// That arrival's round failed; nothing is fetching until the next one.
        case interrupted
        /// The iCloud Drive manifest pass, which decides the audio badges. It
        /// runs alongside the library's arrival and is shown only once that
        /// has nothing left to say.
        case narrations
    }

    var phase: Phase
    var stepText: String
    var detailText: String
    var fractionComplete: Double?

    /// Whether something is running now: a spinner belongs to this, never to
    /// a round that stopped.
    var isRunning: Bool { phase != .interrupted }

    /// What the phone says while its library arrives for the first time
    /// (`MobileLibraryArrival`), nil once nothing is arriving. The count is
    /// the sources on screen, so the line and the lists agree.
    static func arrival(_ arrival: MobileLibraryArrival, sourceCount: Int) -> MobileCatalogSyncStatus? {
        switch arrival {
        case .settled:
            return nil
        case .arriving:
            let detail: String
            switch sourceCount {
            case 0: detail = "Connecting to iCloud…"
            case 1: detail = "1 source so far"
            default: detail = "\(sourceCount.formatted()) sources so far"
            }
            return MobileCatalogSyncStatus(phase: .arriving, stepText: "Syncing your library", detailText: detail)
        case .interrupted:
            return MobileCatalogSyncStatus(
                phase: .interrupted,
                stepText: "Sync paused",
                detailText: "iCloud did not answer. ForeverLM will try again."
            )
        }
    }
}

/// The narration voice mode handed the audio to (`listen_to_source`,
/// `RealtimeVoiceListen`): the conversation ended and this source plays. The
/// car's screen shows it in place of the conversation, with a way back to
/// talking, and the assistant comes back when it ends.
struct MobileVoiceListen: Equatable, Sendable {
    enum Ended: Equatable, Sendable {
        /// It played to its end.
        case finished
        /// It could not be played, and why.
        case failed(String)
    }

    let sourceID: String
    let title: String
    var ended: Ended?
}

enum MobileTextToSpeechPreparationError: LocalizedError {
    case alreadyPreparing(String?)
    case sourceNotFound
    /// The selected voice does not speak the source's language, and nobody
    /// is looking at the phone to be asked (a narration started by voice).
    case unnarratableLanguage(String)

    var errorDescription: String? {
        switch self {
        case .unnarratableLanguage(let message):
            return message
        case .alreadyPreparing(let title):
            return title.map { "Audio is already being prepared for \($0)." }
                ?? "Another source's audio is already being prepared."
        case .sourceNotFound:
            return "That source is not available on this phone."
        }
    }
}

enum MobileAudioPlayerError: LocalizedError {
    case couldNotBuildComposition
    case missingAudioTrack(String)

    var errorDescription: String? {
        switch self {
        case .couldNotBuildComposition:
            return "Could not prepare the synced audio for playback."
        case .missingAudioTrack(let fileName):
            return "The audio file \(fileName) does not contain a playable audio track."
        }
    }
}
