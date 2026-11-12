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

/// One line of catalog sync state for the home screen: which of the two
/// phases is running, step + detail text, and a 0–1 fraction when the phase
/// can honestly estimate one (nil → indeterminate spinner).
struct MobileCatalogSyncStatus: Equatable {
    enum Phase: Equatable {
        case scanning
        case downloading
        /// The iCloud Drive manifest pass, which decides the audio badges. It
        /// runs alongside the two CloudKit phases and is shown only once they
        /// have nothing left to say.
        case narrations
    }

    var phase: Phase
    var stepText: String
    var detailText: String
    var fractionComplete: Double?
}

enum MobileTextToSpeechPreparationError: LocalizedError {
    case alreadyPreparing(String?)
    case sourceNotFound

    var errorDescription: String? {
        switch self {
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
