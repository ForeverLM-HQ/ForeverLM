import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Memory review and cards.
    enum Memory {
        /// The day's new cards, which also set how many sources are drafted
        /// in the background a day; whether they are drafted at all; and
        /// whether the "Cards to check" card is shown. Statements about the
        /// learner's day and spend, not the Mac they were said on.
        static let newCardsPerDay = AccountKey<Int?>("memory.new_cards_per_day")
        static let autoDraftCards = AccountKey<Bool>("memory.auto_draft_cards", default: false)
        static let draftNudges = AccountKey<Bool>("memory.draft_nudges", default: true)
        /// How many minutes a day the memory review gets. It sizes the review
        /// wherever it is planned and is a statement about the learner's day,
        /// not the device it was said on, so it follows the account; the phone
        /// writes the same row from its own Settings.
        static let budgetMinutes = AccountKey<Int?>("memoryReview.budgetMinutes.v1", .phoneWritable)
        /// Whether today's memory review is prepared ahead of the click — one
        /// planner call and one opening message a day, billed whether or not the
        /// review is opened. A spending decision, so it follows the account; the
        /// hour it runs at is the device's and stays below.
        static let dailyPreparationEnabled = AccountKey<Bool>("memoryReview.dailyPreparation.enabled.v1", default: false, .phoneWritable)
        /// Whether ForeverLM keeps notes about the learner's work: it is about
        /// the learner, and the notes' Doc follows the account.
        static let workingNotesEnabled = AccountKey<Bool>("workingNotes.enabled.v1", default: true)
        /// The hour today's review should be waiting is a property of this
        /// machine's mornings, not of the account; the other Mac may keep another.
        /// The offer marker is one-shot, and the attempt receipt describes what
        /// this device did today, which the other device must not inherit.
        static let dailyPreparationHour = DeviceKey<Int?>("memoryReview.dailyPreparation.hour.v1", reason: "device-local hour for the daily review preparation")
        static let dailyPreparationOfferDecided = DeviceKey<Bool?>("memoryReview.dailyPreparation.offerDecided.v1", reason: "one-shot marker: the in-chat offer was answered here")
        static let dailyPreparationOfferShownCount = DeviceKey<Int?>("memoryReview.dailyPreparation.offerShown.v1", reason: "how many planning waits showed the in-chat offer here")
        static let dailyPreparationLastAttempt = DeviceKey<Data?>("memoryReview.dailyPreparation.lastAttempt.v1", reason: "this device's preparation receipt for today")
        /// The card review ran out of cards on this Mac today, which made the
        /// day done here (`MemoryReviewEngagementTracker.finishDayByCards`).
        static let cardsFinishedDay = DeviceKey<String?>("memoryReview.cardsFinishedDay", reason: "the day this Mac's card review ran out of cards")
        static let sessionEnd = DeviceKey<Data?>("memoryReview.sessionEnd", reason: "when this Mac's last memory review session ended")
        /// The id this device signs its review-time rows with; the rows themselves
        /// sync, the name of the device that wrote them does not need to.
        static let activityDeviceID = DeviceKey<String?>("memoryReview.activity.deviceID.v1", reason: "identifies this device's memory_review_activity rows")
        /// The same for background card drafting, and what this Mac's last
        /// run did; and the day this Mac's "Cards to check" card was put off,
        /// which, like "Plan your day?", is asked on the Mac being sat at.
        static let autoDraftFailures = DeviceKey<[String: Any]?>("memory.autoDraft.failures.v1", coding: .dictionary, reason: "device-local retry backoff for background card drafting")
        static let autoDraftLastRun = DeviceKey<Data?>("memory.autoDraft.lastRun.v1", reason: "this device's last background card drafting run")
        static let draftNudgePutOffOn = DeviceKey<String?>("memory.draftNudge.putOffOn.v1", reason: "the day this Mac's Cards to check card was put off")
        static let draftBannerLedger = DeviceKey<Data?>("memory.draftBanner.ledger.v1", reason: "which sources this Mac's morning cards banner has told, and the banner it has queued with this Mac's notification centre")
        /// Which sources the model could not turn into ideas, and when. Cache: a
        /// failure remembered here only stops this device re-billing the same
        /// call for a day, and the other device is welcome to try once itself.
        static let ideaExtractionFailures = DeviceKey<[String: Any]?>("sourceIdeas.extractionFailures.v1", coding: .dictionary, reason: "device-local retry backoff for idea extraction")
        static let reviewLayout = DeviceKey<String?>("memoryReviewLayout", reason: "how this device lays out the memory review")
        static let cohortDismissedSignatures = DeviceKey<[String: Any]?>("cohortReview.dismissedSignatures.v1", coding: .dictionary, reason: "\"not right now\" is about the machine being sat at; syncing it would let a dismissal here swallow the phone's morning nudge")
        static let dailyPreparationLastAttemptDay = DeviceKey<String?>("memoryReview.dailyPreparation.lastAttemptDay.v1", reason: "the day this phone last tried to prepare the review")
        static let dailyPreparationLastAttemptMessage = DeviceKey<String?>("memoryReview.dailyPreparation.lastAttemptMessage.v1", reason: "what this phone did the last time it tried to prepare the review")

        static let all: [AnyPreferenceKey] = [
            newCardsPerDay.erased,
            autoDraftCards.erased,
            draftNudges.erased,
            budgetMinutes.erased,
            dailyPreparationEnabled.erased,
            workingNotesEnabled.erased,
            dailyPreparationHour.erased,
            dailyPreparationOfferDecided.erased,
            dailyPreparationOfferShownCount.erased,
            dailyPreparationLastAttempt.erased,
            cardsFinishedDay.erased,
            sessionEnd.erased,
            activityDeviceID.erased,
            autoDraftFailures.erased,
            autoDraftLastRun.erased,
            draftNudgePutOffOn.erased,
            draftBannerLedger.erased,
            ideaExtractionFailures.erased,
            reviewLayout.erased,
            cohortDismissedSignatures.erased,
            dailyPreparationLastAttemptDay.erased,
            dailyPreparationLastAttemptMessage.erased,
        ]
    }
}
