import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// What the learner allows a model host to do with their words.
    enum AIPolicy {
        /// Whether OpenRouter may route to hosts that keep or train on prompts.
        /// A statement about the learner's data, not the device, so it follows
        /// the account; the phone writes the same row from its own Settings.
        static let denyDataCollection = AccountKey<Bool?>("aiPrivacy.denyDataCollection", .phoneWritable)
        static let observedTrainingSlugs = DeviceKey<[String]?>("aiPrivacy.openRouterTrainingSlugs", reason: "remote observation cache: the hosts this device saw train on prompts")
        static let freeModelRefusals = DeviceKey<[String: Any]?>("aiFreeModelRestrictions.refusedAt.v1", coding: .dictionary, reason: "device-local backoff: when a free model last refused this device")

        static let all: [AnyPreferenceKey] = [
            denyDataCollection.erased,
            observedTrainingSlugs.erased,
            freeModelRefusals.erased,
        ]
    }
}
