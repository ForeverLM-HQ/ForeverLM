import Foundation

/// A stored text-to-speech pick OpenRouter's speech list no longer offers is
/// repaired where it is used, by one rule on both apps: the Mac's
/// `MacArticleSpeechSettings.repairSelectionForUse` and the phone's
/// `repairSelectionForUse` below. The learner is told once, in the notice
/// they already see: "<old> is no longer offered; using <new>." A failed
/// request is never answered with another model; the repair happens before
/// one goes out.
extension ArticleSpeechSelection {
    /// The pick a repair settles on, from what is stored and what is offered:
    /// the stored model while it is offered, failed test or not (the learner
    /// chose it); otherwise the first offered model that has not failed its
    /// test in the voice it would get, or the first offered when every one
    /// has. The voice is the stored one when the model offers it, else the
    /// model's first. Pure, so the rule is tested without storage.
    static func resolvedPick(
        storedModel: String,
        storedVoice: String,
        offered: [String],
        voices: (String) -> [String],
        failed: (_ model: String, _ voice: String) -> Bool
    ) -> (model: String, voice: String) {
        func voice(for model: String) -> String {
            let available = voices(model)
            return available.contains(storedVoice) ? storedVoice : (available.first ?? storedVoice)
        }
        let model: String
        if offered.contains(storedModel) {
            model = storedModel
        } else {
            model = offered.first { !failed($0, voice(for: $0)) } ?? offered.first ?? storedModel
        }
        return (model, voice(for: model))
    }

    /// A stored text-to-speech pick OpenRouter's speech list no longer
    /// offers, and what replaced it.
    struct Repair: Equatable, Sendable {
        let oldModel: String
        let newModel: String
        let newVoice: String

        /// Said once, in the notice or the answer the learner already sees.
        var message: String {
            let old = ArticleSpeechCatalog.model(id: oldModel)?.name
                ?? (ArticleSpeechCatalog.curatedModels + ArticleSpeechCatalog.learnedModels)
                    .first { $0.id == oldModel }?.name
                ?? oldModel
            let new = ArticleSpeechCatalog.selectionLabel(model: newModel, voice: newVoice)
            return "\(old) is no longer offered; using \(new)."
        }

        /// Two repairs in a row, said as one: from the model the learner
        /// last heard to the one in use now; nil when they are the same.
        static func combined(_ earlier: Repair?, then later: Repair?) -> Repair? {
            guard let later else { return earlier }
            let combined = Repair(
                oldModel: earlier?.oldModel ?? later.oldModel,
                newModel: later.newModel,
                newVoice: later.newVoice
            )
            return combined.oldModel == combined.newModel ? nil : combined
        }
    }

    // MARK: The phone's stored pick

    /// The phone's pick, repaired by `resolvedPick` and written back: the
    /// model under `modelDefaultsKey` (nothing stored reads as the default
    /// model, which OpenRouter can stop offering too) and its voice under the
    /// model's own key. Before this device has read OpenRouter's list, the
    /// catalog is only what this build records, and a stored model missing
    /// from that may be one OpenRouter added since; it is left as it is, as
    /// the Mac leaves it. A voice the model no longer offers becomes its first
    /// without a word, as on the Mac; only a model that changed is returned,
    /// for the caller to say.
    @discardableResult
    static func repairStoredPick(
        defaults: UserDefaults = .standard,
        offered: [String] = ArticleSpeechCatalog.models.map(\.id),
        isDirectoryBacked: Bool = ArticleSpeechCatalog.isDirectoryBacked,
        voices: (String) -> [String] = { ArticleSpeechCatalog.voices(forModel: $0).map(\.id) },
        failed: (_ model: String, _ voice: String) -> Bool = {
            // A model whose test run failed in the voice it would get is
            // passed over for the next one; it stays in the picker.
            AIModelQualification.isSpeechKnownToFail(model: $0, voice: $1)
        }
    ) -> Repair? {
        let stored = defaults.string(forKey: modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedModel = stored.isEmpty ? ArticleSpeechCatalog.defaultModelID : stored
        guard isDirectoryBacked || offered.contains(storedModel) else { return nil }
        let storedVoice = Preferences.withStorage(defaults) { Preferences.value(Prefs.Families.readAloudDeviceVoice.key(storedModel)) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pick = resolvedPick(
            storedModel: storedModel,
            storedVoice: storedVoice,
            offered: offered,
            voices: voices,
            failed: failed
        )
        let modelChanged = pick.model != storedModel
        if modelChanged {
            defaults.set(pick.model, forKey: modelDefaultsKey)
        }
        // A voice is written only where it changes what is sent: for the
        // new model, or in place of a stored voice its model dropped. Nothing
        // stored already reads as the model's first voice.
        let voiceKey = Prefs.Families.readAloudDeviceVoice.key(pick.model)
        let currentVoice = Preferences.withStorage(defaults) { Preferences.value(voiceKey) } ?? ""
        if !voices(pick.model).isEmpty, pick.voice != currentVoice, modelChanged || !currentVoice.isEmpty {
            Preferences.withStorage(defaults) { Preferences.set(pick.voice, for: voiceKey) }
        }
        return modelChanged
            ? Repair(oldModel: storedModel, newModel: pick.model, newVoice: pick.voice)
            : nil
    }

    private static let pendingRepairLock = AppLock()
    nonisolated(unsafe) private static var pendingRepair: Repair?

    /// Before a text-to-speech request goes out on the phone (Listen,
    /// generated and automatic audio): the stored pick, repaired, with what
    /// changed for the caller to say once, including a repair a directory
    /// read made since the last use; nil when nothing did.
    static func repairSelectionForUse(defaults: UserDefaults = .standard) -> Repair? {
        let now = repairStoredPick(defaults: defaults)
        let pending: Repair? = pendingRepairLock.withLock {
            defer { pendingRepair = nil }
            return pendingRepair
        }
        return Repair.combined(pending, then: now)
    }

    /// After a read of OpenRouter's speech list: the same repair, kept for
    /// the next use to say.
    static func repairAfterDirectoryRead(defaults: UserDefaults = .standard) {
        guard let repair = repairStoredPick(defaults: defaults) else { return }
        pendingRepairLock.withLock {
            pendingRepair = Repair.combined(pendingRepair, then: repair)
        }
    }
}
