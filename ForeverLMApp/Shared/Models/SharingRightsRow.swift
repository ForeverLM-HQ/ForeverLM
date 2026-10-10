import Foundation

/// The Mac's reads and writes of the learner's `sharing.rightsAffirmation`
/// row (`SharingRightsAffirmation`, docs/teams-design.md decision 22).
///
/// Reading writes nothing. `affirm` is the one write, made only when the
/// learner ticks the box and presses Share in "Before you share", or when an
/// assistant passes `rights_affirmed_by_learner: true` after asking them; it
/// goes through `PreferenceStore`, which queues the row for the learner's
/// other devices, so the iPhone and the web do not ask again.
enum SharingRightsRow {
    /// A test's own defaults, bound for the task that runs it (as
    /// `NotebookChatSelection.overrideDefaults`). The row otherwise lives in
    /// `UserDefaults.standard`, which every test shares with its neighbours
    /// and with the Dev build, and a write there would reach the learner's
    /// other devices. While bound, writes go to the suite and never to the
    /// sync rail.
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    /// A Sendable carrier for `overrideDefaults`; the suite is only ever
    /// touched by the task that bound it.
    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    private static var rowValue: Any? {
        defaults.object(forKey: SharingRightsAffirmation.preferenceKey)
    }

    /// The learner's affirmation as stored, when the row reads.
    static var stored: SharingRightsAffirmation? {
        SharingRightsAffirmation(rowValue: rowValue)
    }

    /// Whether the next share must ask "Before you share" first.
    static var needsAsking: Bool {
        SharingRightsAffirmation.needsAsking(rowValue: rowValue)
    }

    /// Records that the learner affirmed, at the current version. Never
    /// called while holding a lock: a defaults write posts its change
    /// notification on the writing thread.
    @discardableResult
    static func affirm(at date: Date = Date()) -> SharingRightsAffirmation {
        let affirmation = SharingRightsAffirmation(affirmedAt: date)
        if let override = overrideDefaults {
            override.defaults.set(affirmation.rowValue, forKey: SharingRightsAffirmation.preferenceKey)
        } else {
            PreferenceStore.set(affirmation.rowValue, forKey: SharingRightsAffirmation.preferenceKey)
        }
        return affirmation
    }
}
