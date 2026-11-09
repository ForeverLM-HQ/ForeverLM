import Foundation

// MARK: - Settings › Background › Memory review over MCP
//
// Every setting the pane holds is readable and writable from a chat
// (product owner, 2026-09-11: "setting any of the settings needs to be possible
// via MCP as well"), through the exact entry points the pane's own controls
// call, so the UI and MCP cannot accept different values:
//
// - `get_memory_review_settings` is Settings › Background › Memory review as JSON: the daily
//   budget, the day's new cards, background card drafting and its corner
//   card, review questions written ahead of time, the "Have today's review
//   ready" switch, this Mac's hour, and what this Mac last did about each.
// - `set_memory_review_settings` writes any of the seven.

extension MCPDataStore {

    private static let receiptFormatter = ISO8601DateFormatter()

    @MainActor
    static func memoryReviewSettingsPayload() -> [String: Any] {
        let preparation = MemoryReviewPreparationRunner.shared
        let newCards = MemoryCardSettings.newCardsPerDay()
        var payload: [String: Any] = [
            "budget_minutes": MemoryReviewBudget.minutes,
            "new_cards_per_day": newCards,
            "auto_draft_cards": MemoryCardSettings.autoDraftsCards(),
            "draft_nudges": MemoryCardSettings.showsDraftNudges(),
            "prepare_daily": DailyReviewPreparation.isEnabled,
            "ready_by_hour": DailyReviewPreparation.hour,
            "scope": [
                "budget_minutes": "your account",
                "new_cards_per_day": "your account",
                "auto_draft_cards": "your account",
                "draft_nudges": "your account",
                "prepare_daily": "your account",
                "ready_by_hour": "this Mac",
            ],
            "automatic_drafting": automaticDraftingPayload(newCardsPerDay: newCards),
            "next_preparation_at": preparation.nextInstant.map(receiptFormatter.string(from:)) ?? NSNull(),
        ]
        if let attempt = preparation.lastAttempt {
            payload["last_preparation"] = [
                "day": attempt.day,
                "at": receiptFormatter.string(from: attempt.at),
                "succeeded": attempt.succeeded,
                "message": attempt.message ?? NSNull(),
                "kind": attempt.kind.rawValue,
                "cards": attempt.cardsLine ?? NSNull(),
                "session_id": attempt.sessionID ?? NSNull(),
            ] as [String: Any]
        } else {
            payload["last_preparation"] = NSNull()
        }
        return payload
    }

    /// What background drafting does with the settings, and what this Mac's
    /// last run did: the sources a day, the last run's cards and what it
    /// left waiting, and the sources that failed today (retried tomorrow).
    @MainActor
    static func automaticDraftingPayload(newCardsPerDay: Int, now: Date = Date()) -> [String: Any] {
        var payload: [String: Any] = [
            "sources_a_day": AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: newCardsPerDay),
            "failed": AutomaticCardDraftingFailures.recent(now: now).map { failure in
                [
                    "source_id": failure.sourceID,
                    "title": failure.title,
                    "at": receiptFormatter.string(from: failure.failedAt),
                    "message": failure.message,
                ] as [String: Any]
            },
        ]
        if let run = AutomaticCardDraftingRun.last() {
            payload["last_run"] = [
                "at": receiptFormatter.string(from: run.at),
                "drafted_cards": run.draftedCards,
                "drafted_sources": run.draftedSources,
                "waiting": run.waiting(asOf: now),
            ] as [String: Any]
        } else {
            payload["last_run"] = NSNull()
        }
        return payload
    }

    func getMemoryReviewSettings() async throws -> String {
        try jsonString(await Self.memoryReviewSettingsPayload())
    }

    func setMemoryReviewSettings(
        budgetMinutes: Int?,
        prepareDaily: Bool?,
        readyByHour: Int?,
        newCardsPerDay: Int? = nil,
        autoDraftCards: Bool? = nil,
        draftNudges: Bool? = nil
    ) async throws -> String {
        let given: [Any?] = [
            budgetMinutes, prepareDaily, readyByHour, newCardsPerDay, autoDraftCards, draftNudges,
        ]
        guard given.contains(where: { $0 != nil }) else {
            throw MCPError.invalidInput("Pass budget_minutes, new_cards_per_day, auto_draft_cards, draft_nudges, prepare_daily, ready_by_hour, or several; nothing to change.")
        }
        if let budgetMinutes, MemoryReviewBudget.clamp(budgetMinutes) != budgetMinutes {
            throw MCPError.invalidInput("budget_minutes must be between \(MemoryReviewBudget.minimumMinutes) and \(MemoryReviewBudget.maximumMinutes).")
        }
        if let newCardsPerDay, !MemoryCardQueue.newPerDayRange.contains(newCardsPerDay) {
            throw MCPError.invalidInput("new_cards_per_day must be between \(MemoryCardQueue.newPerDayRange.lowerBound) and \(MemoryCardQueue.newPerDayRange.upperBound).")
        }
        if let readyByHour, !(0...23).contains(readyByHour) {
            throw MCPError.invalidInput("ready_by_hour must be an hour from 0 to 23.")
        }

        let changed: [String] = await MainActor.run {
            var changed: [String] = []
            if let budgetMinutes, budgetMinutes != MemoryReviewBudget.minutes {
                MemoryReviewBudget.setMinutes(budgetMinutes)
                changed.append("budget_minutes")
            }
            if let newCardsPerDay, newCardsPerDay != MemoryCardSettings.newCardsPerDay() {
                MemoryCardSettings.setNewCardsPerDay(newCardsPerDay)
                // Today's new cards change at once in the rail and Memory.
                Task { await AppModelBridge.studio?.refreshMemoryCardCounts() }
                changed.append("new_cards_per_day")
            }
            if let autoDraftCards, autoDraftCards != MemoryCardSettings.autoDraftsCards() {
                MemoryCardSettings.setAutoDraftsCards(autoDraftCards)
                Task(priority: .utility) { await AppModelBridge.studio?.refreshCardsToCheckBanner() }
                changed.append("auto_draft_cards")
            }
            if let draftNudges, draftNudges != MemoryCardSettings.showsDraftNudges() {
                MemoryCardSettings.setShowsDraftNudges(draftNudges)
                Task(priority: .utility) { await AppModelBridge.studio?.refreshCardsToCheckBanner() }
                changed.append("draft_nudges")
            }
            if let prepareDaily, prepareDaily != DailyReviewPreparation.isEnabled {
                // The switch's side effects, exactly as the pane's toggle has
                // them: the offer is answered, the reminder follows the switch,
                // and the runner re-reads its clock.
                DailyReviewPreparation.setEnabled(prepareDaily)
                DailyReviewPreparation.markOfferDecided()
                if prepareDaily {
                    Task {
                        _ = await CohortReviewNotifications.requestAuthorization()
                        // Scheduled only while the next morning holds a card.
                        await MemoryReviewPreparationRunner.shared.refreshReminder()
                    }
                } else {
                    CohortReviewNotifications.cancel()
                }
                changed.append("prepare_daily")
            }
            if let readyByHour, readyByHour != DailyReviewPreparation.hour {
                DailyReviewPreparation.hour = readyByHour
                Task { await MemoryReviewPreparationRunner.shared.refreshReminder() }
                changed.append("ready_by_hour")
            }
            if !changed.isEmpty {
                MemoryReviewPreparationRunner.shared.scheduleRefresh()
            }
            return changed
        }
        await PreferenceStore.flushPendingWrites()

        var payload = await Self.memoryReviewSettingsPayload()
        payload["changed"] = changed
        return try jsonString(payload)
    }
}
