import Foundation
import Testing
@testable import ForeverLM

/// A production preferences file of build 210 held 1,093 window frames that
/// AppKit saved under SwiftUI type names (1.7 MB of names) and a few keys
/// nothing reads, and every defaults write made the next read diff all of it.
/// The cleanup removes them once, in one CFPreferences call, and must never
/// touch the frames of the scenes that exist or any key still in use. Every
/// test runs on a throwaway suite, never the standard domain.
@Suite("Retired defaults cleanup")
struct RetiredDefaultsCleanupTests {
    /// The shortest stale key of each family in a copy of that file
    /// (2026-10-11), with the retired product's module renamed `OldApp`.
    static let typeNamedFrameShapes = [
        "NSWindow Frame SwiftUI.WindowGroup<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<OldApp.ContentView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.StudioViewModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.PurchaseManager>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.AppUpdateController>>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>, OldApp.(unknown context at $10a78045c).AppUIZoomModifier>, SwiftUI.TextSelectabilityModifier<SwiftUI.EnabledTextSelectability>>, SwiftUI._ValueActionModifier2<OldApp.AppearanceMode>>, SwiftUI._AppearanceActionModifier>, SwiftUI._TaskModifier>, SwiftUI._TaskModifier>, SwiftUI._ValueActionModifier2<Swift.Bool>>, SwiftUI._AppearanceActionModifier>>-1-AppWindow-1",
        "NSWindow Frame SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<OldApp.ContentView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.StudioViewModel>>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>, SwiftUI.TextSelectabilityModifier<SwiftUI.EnabledTextSelectability>>, SwiftUI._TaskModifier>, SwiftUI._TaskModifier>-1-AppWindow-1",
        "NSSplitView Subview Frames SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<OldApp.ContentView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.ReviewViewModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.AuthSession>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.BillingManager>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.StudioViewModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.ConceptBrowserViewModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.InboxViewModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<OldApp.Model3DStore>>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>, SwiftUI.TextSelectabilityModifier<SwiftUI.EnabledTextSelectability>>, SwiftUI._TaskModifier>, SwiftUI._TaskModifier>-1-AppWindow-1, SidebarNavigationSplitView",
    ]

    /// Many builds' worth of the three shapes, each with its own root view, as
    /// a modifier change made a new name per build.
    static let typeNamedFrameKeys: [String] = typeNamedFrameShapes + (0..<300).map { index in
        typeNamedFrameShapes[index % typeNamedFrameShapes.count]
            .replacingOccurrences(of: "OldApp.ContentView,", with: "OldApp.ContentView\(index),")
    }

    /// Every short frame key in that copy, and the frames today's scenes and a
    /// split view in one of them would save. All stay.
    static let currentFrameKeys = [
        "NSWindow Frame studio-AppWindow-1",
        "NSWindow Frame source-reader-AppWindow-1",
        "NSWindow Frame review-chat-AppWindow-1",
        "NSWindow Frame research-canvas-AppWindow-1",
        "NSWindow Frame GoToSheet",
        "NSWindow Frame NSSpellCheckerSpellingPanel",
        "NSWindow Frame NSSpellCheckerSubstitutionsPanel2",
        "NSWindow Frame third-party-licenses-AppWindow-1",
        "NSWindow Frame studio-AppWindow-2",
        "NSSplitView Subview Frames studio-AppWindow-1, SidebarNavigationSplitView",
    ]

    /// Keys from the same copy that are still read: settings, live caches,
    /// canvases, other frameworks' own. All stay.
    static let liveKeys = [
        BetaReleases.preferenceKey,
        "uiZoomStep",
        "studio.chatOrder",
        "map.layout.library",
        "notebook.chatExcluded.9DEDD041-CEBB-4132-A651-B20DFD8FC0D2",
        "aiPricing.openRouterRemotePrices",
        "aiCapabilities.openRouterVision",
        "openRouterAudioDirectory.speech.rows.v1",
        "NSNavPanelExpandedSizeForOpenMode",
        "NSOSPLastRootDirectory",
        "SUEnableAutomaticChecks",
        "CKStartupTime",
    ]

    /// Keys from the same copy that nothing reads. All go.
    static let retiredKeys = [
        "enrichedChapterTitles",
        "readai.importedMeetingIDs",
        "bookNameOverrides",
        "drive.lastDisconnectReason",
        "usage_records_2026-03-29",
        "usage_records_2026-03-30",
        "usage_records_2026-03-31",
        "usage_records_2026-04-01",
        "usage_daily_total_2026-03-30",
    ]

    private func withSuite(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    private func seed(_ defaults: UserDefaults) {
        for key in Self.typeNamedFrameKeys { defaults.set("144 141 1440 900 0 0 1728 1084 ", forKey: key) }
        for key in Self.currentFrameKeys { defaults.set("frame of \(key)", forKey: key) }
        for key in Self.liveKeys { defaults.set("value of \(key)", forKey: key) }
        for key in Self.retiredKeys { defaults.set(Data("retired \(key)".utf8), forKey: key) }
    }

    @Test("Type-named frames and retired keys go; today's frames and every live key stay as they were")
    func removesOnlyTheRetired() throws {
        try withSuite { defaults, suite in
            seed(defaults)

            let removed = RetiredDefaultsCleanup.removeRetiredKeysIfNeeded(applicationID: suite as CFString)

            #expect(removed == Self.typeNamedFrameKeys.count + Self.retiredKeys.count)
            for key in Self.typeNamedFrameKeys + Self.retiredKeys {
                #expect(defaults.object(forKey: key) == nil, Comment(rawValue: String(key.prefix(80))))
            }
            for key in Self.currentFrameKeys {
                #expect(defaults.string(forKey: key) == "frame of \(key)", Comment(rawValue: key))
            }
            for key in Self.liveKeys {
                #expect(defaults.string(forKey: key) == "value of \(key)", Comment(rawValue: key))
            }
            #expect(defaults.bool(forKey: RetiredDefaultsCleanup.completionKey))
            let left = defaults.persistentDomain(forName: suite) ?? [:]
            #expect(Set(left.keys) == Set(Self.currentFrameKeys + Self.liveKeys + [RetiredDefaultsCleanup.completionKey]))
        }
    }

    @Test("Once done, a domain is not listed again, and a run on a clean domain removes nothing")
    func runsOnce() throws {
        try withSuite { defaults, suite in
            seed(defaults)
            #expect(RetiredDefaultsCleanup.removeRetiredKeysIfNeeded(applicationID: suite as CFString) > 0)
            // Marked done: a key that looks retired written later is not looked for.
            defaults.set("x", forKey: Self.typeNamedFrameShapes[1])
            #expect(RetiredDefaultsCleanup.removeRetiredKeysIfNeeded(applicationID: suite as CFString) == 0)
            #expect(defaults.string(forKey: Self.typeNamedFrameShapes[1]) == "x")
        }
        try withSuite { defaults, suite in
            for key in Self.currentFrameKeys + Self.liveKeys { defaults.set("kept", forKey: key) }
            #expect(RetiredDefaultsCleanup.removeRetiredKeysIfNeeded(applicationID: suite as CFString) == 0)
            #expect(defaults.bool(forKey: RetiredDefaultsCleanup.completionKey))
            for key in Self.currentFrameKeys + Self.liveKeys {
                #expect(defaults.string(forKey: key) == "kept", Comment(rawValue: key))
            }
        }
    }

    @Test("Only a Swift type name where a scene id would be makes a frame key stale")
    func typeNamedFrameKeysAreRecognised() {
        for key in Self.typeNamedFrameKeys {
            #expect(RetiredDefaultsCleanup.isTypeNamedFrameKey(key), Comment(rawValue: String(key.prefix(80))))
        }
        for key in Self.currentFrameKeys + Self.liveKeys + Self.retiredKeys {
            #expect(!RetiredDefaultsCleanup.isTypeNamedFrameKey(key), Comment(rawValue: key))
        }
        #expect(!RetiredDefaultsCleanup.isTypeNamedFrameKey("NSToolbar Configuration SwiftUI.Toolbar<X>"))
        #expect(!RetiredDefaultsCleanup.isTypeNamedFrameKey("studio.panel<x>"))
    }

    @Test("A type-named frame that names this build's module stays: a scene of this build could restore it")
    func ownModuleFramesStay() throws {
        #expect(RetiredDefaultsCleanup.ownModuleName == "ForeverLM")
        let own = Self.typeNamedFrameShapes.map { $0.replacingOccurrences(of: "OldApp.", with: "ForeverLM.") }
        for key in own {
            #expect(!RetiredDefaultsCleanup.isTypeNamedFrameKey(key), Comment(rawValue: String(key.prefix(80))))
        }
        try withSuite { defaults, suite in
            for key in own { defaults.set("kept", forKey: key) }
            for key in Self.typeNamedFrameShapes { defaults.set("stale", forKey: key) }
            #expect(RetiredDefaultsCleanup.removeRetiredKeysIfNeeded(applicationID: suite as CFString) == Self.typeNamedFrameShapes.count)
            for key in own {
                #expect(defaults.string(forKey: key) == "kept", Comment(rawValue: String(key.prefix(80))))
            }
        }
    }

    @Test("The completion mark stays on this Mac")
    func completionMarkIsLocal() {
        #expect(!SyncedPreferenceKeys.isSynced(RetiredDefaultsCleanup.completionKey))
        for key in Self.retiredKeys {
            #expect(!SyncedPreferenceKeys.isSynced(key), Comment(rawValue: key))
        }
    }
}
