import Foundation

/// How fast the ForeverLM mark animates while the app is thinking — the goo
/// running its loop in a chat, and the sheen crossing the mark on a surface
/// held empty at startup.
///
/// A multiplier on the artwork's own pace, so 1 is exactly what shipped before
/// the setting existed and 2 is a lap in half the time. The range is wide on
/// purpose: this is a taste setting with no correctness to protect, and a mark
/// that crawls or races is the point for whoever picks it. It stops short of
/// anything that would strobe.
///
/// Device-local, and read straight from `UserDefaults` on both platforms: the
/// pace of a logo is not something worth carrying across an account, and the
/// iPhone has no synchronous view of the synced preference rows. The key is
/// named in `SyncedPreferenceKeys.excluded` so the boundary review sees it.
enum LoadingIndicatorSpeed {
    static let key = Prefs.Planner.loadingIndicatorSpeed.name

    static let defaultValue: Double = 1
    static let minimum: Double = 0.25
    static let maximum: Double = 3
    /// Quarter steps: coarse enough that the label never needs more than two
    /// decimals, fine enough that 0.75× and 1.25× are both on the slider.
    static let step: Double = 0.25
    static var range: ClosedRange<Double> { minimum...maximum }

    /// The value the animation actually runs at for a stored number. A missing
    /// or unreadable value (nothing stored, a NaN from a corrupt plist) is the
    /// default, and anything else is snapped to the nearest step and clamped,
    /// so a stale value written by a build with a different range still lands
    /// on the slider.
    static func clamped(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultValue }
        let snapped = (value / step).rounded() * step
        return min(max(snapped, minimum), maximum)
    }

    /// "1×", "0.75×", "2.5×" — the multiplier with the trailing zeros dropped,
    /// in the same shape the players use for playback speed.
    static func label(for value: Double) -> String {
        let speed = clamped(value)
        if speed.rounded() == speed {
            return "\(Int(speed))×"
        }
        var formatted = String(format: "%.2f", speed)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        return formatted + "×"
    }

    static func stored(in defaults: UserDefaults = .standard) -> Double {
        clamped(Preferences.withStorage(defaults) { Preferences.value(Prefs.Planner.loadingIndicatorSpeed) })
    }
}
