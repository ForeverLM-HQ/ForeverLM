import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The navigation rail, the icon strip and the setup guide.
    enum Rail {
        /// The navigation rail's hidden rows and its folds. Hiding a row is the
        /// same act as `studio.hiddenTabs` and the pins above,
        /// and a fold is the same act as `studio.expandedPanel` — all of which
        /// already sync, so these did the opposite of their neighbours until
        /// 2026-09-14.
        static let hiddenItems = AccountKey<String>("studio.navigation.hiddenItems.v1", default: "")
        /// The places kept on the icon strip (2026-10-12): the same act as
        /// hiding a row there.
        static let shortcuts = AccountKey<String>("studio.navigation.shortcuts.v1", default: "")
        /// The order the learner dragged the strip's icons into (2026-11-08).
        static let stripOrder = AccountKey<String>("studio.navigation.stripOrder.v1", default: "")
        static let stripFooterOrder = AccountKey<String>("studio.navigation.stripFooterOrder.v1", default: "")
        /// The strip's bottom icons the learner hid (2026-11-08): the same act
        /// as hiding a row there.
        static let hiddenFooterItems = AccountKey<String>("studio.navigation.hiddenFooterItems.v1", default: "")
        static let chatsExpanded = AccountKey<Bool>("studio.navigation.chatsExpanded.v1", default: true)
        static let hiddenChatsExpanded = AccountKey<Bool>("studio.navigation.hiddenChatsExpanded.v1", default: false)
        static let expandedNotebookIDs = AccountKey<[String]?>("studio.navigation.expandedProjectIDs.v1", .record)
        /// Absolute pixels, tied to display size.
        static let width = DeviceKey<Double?>("studio.navigationRailWidth", reason: "absolute pixels, display-dependent")
        static let gettingStartedCompleted = AccountKey<Bool>("gettingStarted.completed", default: false)
        static let gettingStartedDismissed = AccountKey<Bool>("gettingStarted.dismissed", default: false)
        static let gettingStartedCompletedSteps = AccountKey<Int>("gettingStarted.completedSteps", default: 0)
        /// Which AI apps the learner pays for, asked in setup: a fact about the
        /// person, so the other Mac's guide does not ask again.
        static let aiSubscriptions = AccountKey<String>("gettingStarted.aiSubscriptions", default: "")
        /// Don't Ask Again on the offer to leave a slow free chat model
        /// (`SlowFreeModelWait.dismissedKey`): "forever" means on every Mac.
        static let slowFreeModelOfferDismissed = AccountKey<Bool>("chat.slowFreeModelOffer.dismissed", default: false)
        static let suggestionsArmed = DeviceKey<Bool>("gettingStarted.suggestionsArmed", default: false, reason: "device-local as it stands: declared with the synced wrapper but never listed as synced, so it never left this Mac; whether it should follow the account is undecided")
        static let suggestionsDone = DeviceKey<Int>("gettingStarted.suggestionsDone", default: 0, reason: "device-local as it stands: declared with the synced wrapper but never listed as synced, so it never left this Mac; whether it should follow the account is undecided")
        static let welcomeSeen = DeviceKey<Bool>("gettingStarted.welcomeSeen", default: false, reason: "device-local as it stands: declared with the synced wrapper but never listed as synced, so it never left this Mac; whether it should follow the account is undecided")

        static let all: [AnyPreferenceKey] = [
            hiddenItems.erased,
            shortcuts.erased,
            stripOrder.erased,
            stripFooterOrder.erased,
            hiddenFooterItems.erased,
            chatsExpanded.erased,
            hiddenChatsExpanded.erased,
            expandedNotebookIDs.erased,
            width.erased,
            gettingStartedCompleted.erased,
            gettingStartedDismissed.erased,
            gettingStartedCompletedSteps.erased,
            aiSubscriptions.erased,
            slowFreeModelOfferDismissed.erased,
            suggestionsArmed.erased,
            suggestionsDone.erased,
            welcomeSeen.erased,
        ]
    }
}
