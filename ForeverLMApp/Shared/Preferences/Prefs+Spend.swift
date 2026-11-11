import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// AI spend: the background cap, stopped steps, and the price and ledger caches.
    enum Spend {
        /// The learner's daily cap on background AI spend
        /// (`BackgroundAIDailyCap.preferenceKey`): a decision about the
        /// account's spend, and every Mac reads the same synced ledger.
        static let backgroundDailyCapUSD = AccountKey<Double?>("aiSpend.backgroundDailyCapUSD")
        /// The background steps the learner stopped until they resume them
        /// (`AIInFlightCalls.stoppedStepsKey`): every Mac of the account runs
        /// the same queues, and a stop is meant for all of them.
        static let stoppedSteps = AccountKey<[String]?>("aiSpend.stoppedSteps")
        static let backgroundDailyCapNoticeDay = DeviceKey<String?>("aiSpend.backgroundDailyCapNoticeDay", reason: "the day this Mac last said the background cap was reached")
        static let remotePrices = DeviceKey<Data?>("aiPricing.openRouterRemotePrices", reason: "remote price cache")
        static let remotePricesFetchedAt = DeviceKey<Date?>("aiPricing.openRouterRemotePricesFetchedAt", reason: "remote price cache")
        static let ledgerLastFailure = DeviceKey<String?>("ai.usage.ledger_last_failure", reason: "diagnostics counters")
        static let ledgerWriteFailures = DeviceKey<Int?>("ai.usage.ledger_write_failures", reason: "diagnostics counters")

        static let all: [AnyPreferenceKey] = [
            backgroundDailyCapUSD.erased,
            stoppedSteps.erased,
            backgroundDailyCapNoticeDay.erased,
            remotePrices.erased,
            remotePricesFetchedAt.erased,
            ledgerLastFailure.erased,
            ledgerWriteFailures.erased,
        ]
    }
}
