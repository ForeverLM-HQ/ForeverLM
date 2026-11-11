import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Keys and prefixes the system, AppKit or a framework owns. ForeverLM reads at most one of them and only keeps the rest out of sync.
    enum System {
        static let actionOnDoubleClick = DeviceKey<String?>("AppleActionOnDoubleClick", reason: "a macOS setting of the Mac's own, which ForeverLM only reads")

        static let all: [AnyPreferenceKey] = [
            actionOnDoubleClick.erased,
        ]

        static let windowFrames = DeviceFamily<String, Any?>.unread(prefix: "NSWindow Frame", reason: "AppKit window geometry, about 180 of these in the plist")
        static let splitViews = DeviceFamily<String, Any?>.unread(prefix: "NSSplitView", reason: "AppKit splitter geometry")
        static let navPanels = DeviceFamily<String, Any?>.unread(prefix: "NSNavPanel", reason: "AppKit open/save panel state")
        static let lastRootDirectory = DeviceFamily<String, Any?>.unread(prefix: "NSOSPLastRootDirectory", reason: "AppKit open/save panel state")
        static let cloudKit = DeviceFamily<String, Any?>.unread(prefix: "CK", reason: "a foreign domain's keys that land in the app's defaults (CloudKit)")
        static let sparkle = DeviceFamily<String, Any?>.unread(prefix: "SU", reason: "a foreign domain's keys that land in the app's defaults (Sparkle)")
        static let storeKit = DeviceFamily<String, Any?>.unread(prefix: "SK", reason: "a foreign domain's keys that land in the app's defaults (StoreKit)")
        static let apple = DeviceFamily<String, Any?>.unread(prefix: "com.apple.", reason: "a foreign domain's keys that land in the app's defaults (Apple frameworks)")
        static let appleAccountUI = DeviceFamily<String, Any?>.unread(prefix: "kAOSUI", reason: "a foreign domain's keys that land in the app's defaults (Apple Account UI)")

        static let prefixes: [AnyPreferenceFamily] = [
            windowFrames.erased,
            splitViews.erased,
            navPanels.erased,
            lastRootDirectory.erased,
            cloudKit.erased,
            sparkle.erased,
            storeKit.erased,
            apple.erased,
            appleAccountUI.erased,
        ]
    }
}
