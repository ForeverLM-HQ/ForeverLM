import Foundation
import OSLog

/// Clears, once, what the retired question calibration left in the synced
/// preferences.
///
/// The calibration distilled the learner's thumbs on tutor turns into the
/// `review.questionCalibration.v1` preference, and every client appended it
/// to its review and study prompts. The thumbs left the chat footer on
/// 2026-09-27 and the pipeline went with them, so this build neither writes
/// nor reads the preference. It is cleared rather than left to sit because
/// older clients still read it: an installed Mac that has not updated yet,
/// and an iPhone build from before the change, keep appending whatever it
/// last said. The one value it held in the wild was a single rule, "Do not
/// include images when they are not relevant.", which pulls against the
/// pictures a quiz now shows. The deletion syncs as a tombstone, so those
/// clients drop the block on their next sync. Nothing is lost: the value
/// was derived from the ratings, which stay on their exchanges.
///
/// Works on the stored row rather than through `PreferenceStore.remove`,
/// which ignores keys that no longer sync; the key is excluded now, so a
/// value an older Mac writes again never comes back into `UserDefaults`
/// here. The marker retires the sweep after its first success.
enum RetiredQuestionCalibration {
    static let preferenceKey = Prefs.Lifecycle.retiredQuestionCalibration.name
    static let clearedKey = Prefs.Lifecycle.retiredQuestionCalibrationCleared.name
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RetiredQuestionCalibration")

    static func clearOnce(storage: StorageService, defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: clearedKey) else { return }
        do {
            // Only a library that held one gets a tombstone; the rest, which
            // is nearly every library, queue nothing.
            if try await storage.allPreferences()[preferenceKey] != nil {
                try await storage.deletePreference(key: preferenceKey)
                logger.notice("Cleared the retired question calibration; the deletion syncs to older clients.")
            }
        } catch {
            logger.error(
                "Could not clear the retired question calibration; trying again next launch: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        defaults.removeObject(forKey: preferenceKey)
        defaults.set(true, forKey: clearedKey)
    }
}
