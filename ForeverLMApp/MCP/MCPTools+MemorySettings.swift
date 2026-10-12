import Foundation

// MARK: - Settings › General › Memory review over MCP, and the day close
//
// Every setting the pane holds is readable and writable from a chat
// (product owner, 2026-09-11: "setting any of the settings needs to be possible
// via MCP as well"), through the exact entry points the pane's own controls
// call, so the UI and MCP cannot accept different values:
//
// - `get_memory_review_settings` is Settings › General › Memory review as JSON: the daily
//   budget, the day's new cards, background card drafting and its corner
//   card, review questions written ahead of time, the "Have today's review
//   ready" switch, the day close's own switch, this Mac's two hours, and what
//   this Mac last did about each.
// - `set_memory_review_settings` writes any of the nine.
// - `close_day` runs the day close now — the evening's own work, from a chat
//   ("close my day") — and answers with what it folded in and the next
//   morning's cards. Since the card review (2026-10-01) no review chat is
//   planned or made: the morning selects the day's cards with no model.

extension MCPDataStore {

    private static let receiptFormatter = ISO8601DateFormatter()

    @MainActor
    static func memoryReviewSettingsPayload() -> [String: Any] {
        let preparation = MemoryReviewPreparationRunner.shared
        let dayClose = DayCloseRunner.shared
        let newCards = MemoryCardSettings.newCardsPerDay()
        var payload: [String: Any] = [
            "budget_minutes": MemoryReviewBudget.minutes,
            "new_cards_per_day": newCards,
            "auto_draft_cards": MemoryCardSettings.autoDraftsCards(),
            "draft_nudges": MemoryCardSettings.showsDraftNudges(),
            "prepare_review_questions": MemoryCardSettings.preparesReviewQuestions(),
            "prepare_daily": DailyReviewPreparation.isEnabled,
            "ready_by_hour": DailyReviewPreparation.hour,
            "close_day_daily": DayClosePreferences.isEnabled,
            "close_day_hour": DayClosePreferences.hour,
            "scope": [
                "budget_minutes": "your account",
                "new_cards_per_day": "your account",
                "auto_draft_cards": "your account",
                "draft_nudges": "your account",
                "prepare_review_questions": "your account",
                "prepare_daily": "your account",
                "ready_by_hour": "this Mac",
                "close_day_daily": "your account",
                "close_day_hour": "this Mac",
            ],
            "automatic_drafting": automaticDraftingPayload(newCardsPerDay: newCards),
            "next_preparation_at": preparation.nextInstant.map(receiptFormatter.string(from:)) ?? NSNull(),
            "next_day_close_at": dayClose.nextInstant.map(receiptFormatter.string(from:)) ?? NSNull(),
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
        if let run = dayClose.lastRun {
            payload["last_day_close"] = dayCloseReceiptPayload(run)
        } else {
            payload["last_day_close"] = NSNull()
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

    @MainActor
    static func dayCloseReceiptPayload(_ receipt: DayCloseRunner.Receipt) -> [String: Any] {
        [
            "day": receipt.day,
            "at": receiptFormatter.string(from: receipt.at),
            "reason": receipt.reason.rawValue,
            "succeeded": receipt.succeeded,
            "consolidated_chats": receipt.consolidatedChats,
            "updated_understanding_documents": receipt.updatedUnderstandingDocuments,
            "warmed_sources": receipt.warmedSources,
            "next_day_cards": receipt.nextDayCards ?? NSNull(),
            "preparation_message": receipt.preparationMessage ?? NSNull(),
            "failures": receipt.failures,
            "varied_cards": receipt.variedCards ?? 0,
            "drafted_cards": receipt.draftedCards ?? 0,
            "drafted_sources": receipt.draftedSources ?? 0,
            "drafts_waiting": receipt.draftsWaiting ?? 0,
            "standalone_reworded_cards": receipt.standaloneRewordedCards ?? 0,
            "notes": receipt.notes ?? [],
        ]
    }

    func getMemoryReviewSettings() async throws -> String {
        try jsonString(await Self.memoryReviewSettingsPayload())
    }

    func setMemoryReviewSettings(
        budgetMinutes: Int?,
        prepareDaily: Bool?,
        readyByHour: Int?,
        closeDayHour: Int?,
        newCardsPerDay: Int? = nil,
        autoDraftCards: Bool? = nil,
        draftNudges: Bool? = nil,
        closeDayDaily: Bool? = nil,
        prepareReviewQuestions: Bool? = nil
    ) async throws -> String {
        let given: [Any?] = [
            budgetMinutes, prepareDaily, readyByHour, closeDayHour, newCardsPerDay, autoDraftCards, draftNudges,
            closeDayDaily, prepareReviewQuestions,
        ]
        guard given.contains(where: { $0 != nil }) else {
            throw MCPError.invalidInput("Pass budget_minutes, new_cards_per_day, auto_draft_cards, draft_nudges, prepare_review_questions, prepare_daily, ready_by_hour, close_day_daily, close_day_hour, or several; nothing to change.")
        }
        if let budgetMinutes, MemoryReviewBudget.clamp(budgetMinutes) != budgetMinutes {
            throw MCPError.invalidInput("budget_minutes must be between \(MemoryReviewBudget.minimumMinutes) and \(MemoryReviewBudget.maximumMinutes).")
        }
        if let newCardsPerDay, !MemoryCardQueue.newPerDayRange.contains(newCardsPerDay) {
            throw MCPError.invalidInput("new_cards_per_day must be between \(MemoryCardQueue.newPerDayRange.lowerBound) and \(MemoryCardQueue.newPerDayRange.upperBound).")
        }
        for (name, hour) in [("ready_by_hour", readyByHour), ("close_day_hour", closeDayHour)] {
            if let hour, !(0...23).contains(hour) {
                throw MCPError.invalidInput("\(name) must be an hour from 0 to 23.")
            }
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
            if let prepareReviewQuestions, prepareReviewQuestions != MemoryCardSettings.preparesReviewQuestions() {
                MemoryCardSettings.setPreparesReviewQuestions(prepareReviewQuestions)
                changed.append("prepare_review_questions")
            }
            if let prepareDaily, prepareDaily != DailyReviewPreparation.isEnabled {
                // The switch's side effects, exactly as the pane's toggle has
                // them: the offer is answered, the reminder follows the switch,
                // and both runners re-read their clocks. The evening close
                // stops following this switch first; it keeps what it did.
                DayClosePreferences.pinBeforeReminderChange(reminderWas: DailyReviewPreparation.isEnabled)
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
            if let closeDayDaily, closeDayDaily != DayClosePreferences.isEnabled {
                DayClosePreferences.setEnabled(closeDayDaily)
                changed.append("close_day_daily")
            }
            if let closeDayHour, closeDayHour != DayClosePreferences.hour {
                DayClosePreferences.hour = closeDayHour
                changed.append("close_day_hour")
            }
            if !changed.isEmpty {
                MemoryReviewPreparationRunner.shared.scheduleRefresh()
                DayCloseRunner.shared.scheduleRefresh()
            }
            return changed
        }
        await PreferenceStore.flushPendingWrites()

        var payload = await Self.memoryReviewSettingsPayload()
        payload["changed"] = changed
        return try jsonString(payload)
    }

    /// The day close, now. Waits for the pass — one closer call per chat the
    /// learner wrote in today, and idea extraction for what was read — so the
    /// answer can take a minute on a full day. Counting the next morning's
    /// cards calls no model.
    func closeDay(prepareTomorrow: Bool) async throws -> String {
        guard ManagedAI.isSignedIn else {
            throw MCPError.invalidInput("Sign in with Apple in ForeverLM first; the day close runs on the managed AI rail.")
        }
        let receipt = await DayCloseRunner.shared.closeDay(reason: .manual, prepareTomorrow: prepareTomorrow)
        guard let receipt else {
            throw MCPError.invalidInput("A day close is already running on this Mac. Ask again when it has finished.")
        }
        var payload = await Self.dayCloseReceiptPayload(receipt)
        payload["instructions"] = receipt.nextDayCards == nil
            ? "The day is closed. The next morning's cards were not counted; the message says why, or prepare_tomorrow was false."
            : "The day is closed. next_day_cards is what the next morning's card review holds; the learner starts it from Memory."
        return try jsonString(payload)
    }
}
