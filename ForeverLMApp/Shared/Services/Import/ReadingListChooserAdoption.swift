import Foundation
import os

/// Clears the reading-list browser toggles a retired chooser once wrote.
///
/// Early builds asked which browsers' reading lists to import and stored the
/// answer as `hasChosenReadingList` plus `readingListSafari`, `readingListChrome`
/// and `readingListBrave`. That chooser is gone. The three toggles came back as
/// the browser switches in setup's Articles step and Settings → Sources
/// (`ReadingListBrowser`), which write
/// them without the marker; unset still means on (`DefaultsEscapeHatch`).
///
/// A Mac that answered the old chooser keeps its answer forever, silently: on
/// 2026-09-08 the production plist here still carried `readingListBrave = 0`
/// from that dialog, so Brave's reading list was never scanned, with no setting
/// anywhere to show why. `hasChosenReadingList` is the fingerprint of the
/// chooser — a hand-written `defaults write` never sets it — so when it is
/// present the four keys are the dialog's, and they are removed together. A
/// toggle set by hand, without the marker, is left alone.
enum ReadingListChooserAdoption {
    static let chooserMarkerKey = "hasChosenReadingList"
    static let toggleKeys = ["readingListSafari", "readingListChrome", "readingListBrave"]

    /// Removes the chooser's keys when its marker is present. Returns the toggles
    /// that were removed, so the caller can log what changed; empty when the
    /// marker was absent and nothing was touched.
    @discardableResult
    static func adoptIfNeeded(defaults: UserDefaults = .standard) -> [String] {
        guard defaults.object(forKey: chooserMarkerKey) != nil else { return [] }
        var removed: [String] = []
        for key in toggleKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        defaults.removeObject(forKey: chooserMarkerKey)
        if !removed.isEmpty {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
                .info("Removed reading-list toggles left by the retired chooser: \(removed.joined(separator: ", "), privacy: .public)")
        }
        return removed
    }
}
