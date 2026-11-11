import Foundation
import Testing
@testable import ForeverLM

/// The keys the phone's screens may set are named twice: `MobileSettingCatalog`
/// carries each with its type and range, and the key declarations (`Prefs`)
/// mark the same keys `.phoneWritable`. The two must name the same keys.
@Suite("Preference registry on the phone", .serialized)
struct PreferenceRegistryPhoneTests {

    @Test("The keys declared phone-writable are the catalog's keys")
    func phoneWritableKeysAreTheCatalogKeys() {
        let declared = Set(PreferenceRegistry.keys.filter { $0.accountTraits?.contains(.phoneWritable) == true }.map(\.name))
        #expect(declared == Set(MobileSettingCatalog.keys.keys))
    }

    @Test("The families declared phone-writable are the catalog's families")
    func phoneWritableFamiliesAreTheCatalogFamilies() {
        let declared = Set(PreferenceRegistry.families.filter { $0.accountTraits?.phoneWritable == true }.map(\.prefix))
        #expect(declared == Set(MobileSettingCatalog.families.keys))
    }

    @Test("Every key the phone writes is an account key, and its stored shape is one the phone can write")
    func phoneWritableKeysHaveAShapeThePhoneWrites() {
        for key in PreferenceRegistry.keys where key.accountTraits?.contains(.phoneWritable) == true {
            #expect([.bool, .int, .string, .strings].contains(key.kind), "\(key.name) is stored as \(key.kind.rawValue)")
            #expect(MobileSettingCatalog.entry(for: key.name) != nil)
        }
    }

    @Test("A device key reads and writes this phone's defaults, typed")
    func deviceKeysReadAndWriteDefaults() throws {
        let suite = "PreferenceRegistryPhoneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Preferences.withStorage(defaults) {
            #expect(Preferences.value(Prefs.Mobile.automaticallyContinuesBooks) == false)
            Preferences.set(true, for: Prefs.Mobile.automaticallyContinuesBooks)
            #expect(defaults.bool(forKey: "ios.listen.automaticallyContinuesBooks"))
            #expect(Preferences.value(Prefs.Mobile.playbackSpeed) == nil)
            Preferences.set(1.5, for: Prefs.Mobile.playbackSpeed)
            #expect(defaults.float(forKey: "ios.listen.playbackSpeed") == 1.5)
            Preferences.reset(Prefs.Mobile.playbackSpeed)
            #expect(defaults.object(forKey: "ios.listen.playbackSpeed") == nil)
        }
    }

    @Test("The typed store methods read and write the same Settings as the string ones")
    func typedStoreMethodsReachTheSameSettings() async throws {
        let replica = try await MobileWriterFixture.replica(space: nil)
        let writer = MobileWriterFixture.writer(replica)
        let store = MobileModelPreferenceStore(writer: { writer })

        #expect(try await store.valueOrDefault(for: Prefs.Memory.budgetMinutes) == nil, "no value, and the key has no default")
        #expect(try await store.valueOrDefault(for: Prefs.Memory.dailyPreparationEnabled) == false, "no value reads as the key's default")

        try await store.set(45, for: Prefs.Memory.budgetMinutes)
        #expect(try await store.int(forKey: MemoryReviewBudget.preferenceKey) == 45)
        #expect(try await store.valueOrDefault(for: Prefs.Memory.budgetMinutes) == 45)

        try await store.set(true, for: Prefs.AIPolicy.denyDataCollection)
        #expect(try await store.bool(forKey: AIDataPolicy.denyDataCollectionKey) == true)
        try await store.set(nil, for: Prefs.AIPolicy.denyDataCollection)
        #expect(try await store.bool(forKey: AIDataPolicy.denyDataCollectionKey) == nil, "an optional key set to nil is cleared")

        try await store.set(["m1", "m2"], for: Prefs.ReadAloud.costConfirmationSuppressedModels)
        #expect(try await store.valueOrDefault(for: Prefs.ReadAloud.costConfirmationSuppressedModels) == ["m1", "m2"])

        await #expect(throws: MobileModelPreferenceStore.UnsupportedPreferenceShape.self) {
            _ = try await store.value(for: Prefs.ReadAloud.speed)
        }
    }
}
