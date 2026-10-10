import Foundation
import Testing
@testable import ForeverLM

/// The thinking mark's pace setting. The slider stores a multiplier; every
/// reader goes through `clamped`, so a stale or corrupt value can never stop
/// the animation or make it strobe, and the label matches the players' "1.5×".
@Suite("Loading indicator speed")
struct LoadingIndicatorSpeedTests {

    @Test("Nothing stored means the pace that shipped")
    func defaultWhenUnset() {
        let defaults = UserDefaults(suiteName: "loading-indicator-speed-\(UUID().uuidString)")!
        #expect(LoadingIndicatorSpeed.stored(in: defaults) == 1)
        #expect(LoadingIndicatorSpeed.clamped(nil) == 1)
    }

    @Test("Values snap to the slider's quarter steps and stay inside its range")
    func snapsAndClamps() {
        #expect(LoadingIndicatorSpeed.clamped(1.3) == 1.25)
        #expect(LoadingIndicatorSpeed.clamped(1.4) == 1.5)
        #expect(LoadingIndicatorSpeed.clamped(0) == 0.25)
        #expect(LoadingIndicatorSpeed.clamped(-4) == 0.25)
        #expect(LoadingIndicatorSpeed.clamped(12) == 3)
        #expect(LoadingIndicatorSpeed.clamped(2) == 2)
    }

    @Test("A corrupt value falls back rather than freezing the mark")
    func nonFiniteFallsBack() {
        #expect(LoadingIndicatorSpeed.clamped(.nan) == 1)
        #expect(LoadingIndicatorSpeed.clamped(.infinity) == 1)
        let defaults = UserDefaults(suiteName: "loading-indicator-speed-\(UUID().uuidString)")!
        defaults.set("fast", forKey: LoadingIndicatorSpeed.key)
        #expect(LoadingIndicatorSpeed.stored(in: defaults) == 1)
    }

    @Test("A stored value reads back through the same snapping")
    func storedRoundTrip() {
        let defaults = UserDefaults(suiteName: "loading-indicator-speed-\(UUID().uuidString)")!
        defaults.set(2.5, forKey: LoadingIndicatorSpeed.key)
        #expect(LoadingIndicatorSpeed.stored(in: defaults) == 2.5)
        defaults.set(0.6, forKey: LoadingIndicatorSpeed.key)
        #expect(LoadingIndicatorSpeed.stored(in: defaults) == 0.5)
    }

    @Test("Labels drop trailing zeros and use the multiplication sign")
    func labels() {
        #expect(LoadingIndicatorSpeed.label(for: 1) == "1×")
        #expect(LoadingIndicatorSpeed.label(for: 0.5) == "0.5×")
        #expect(LoadingIndicatorSpeed.label(for: 0.75) == "0.75×")
        #expect(LoadingIndicatorSpeed.label(for: 1.25) == "1.25×")
        #expect(LoadingIndicatorSpeed.label(for: 3) == "3×")
        #expect(LoadingIndicatorSpeed.label(for: 7) == "3×")
    }

    @Test("The key stays out of the account sync rail")
    func deviceLocal() {
        #expect(!SyncedPreferenceKeys.isSynced(LoadingIndicatorSpeed.key))
        #expect(SyncedPreferenceKeys.excluded[LoadingIndicatorSpeed.key] != nil)
    }
}
