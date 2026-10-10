import Foundation

extension StudioViewModel {
    nonisolated static func dailyReviewPlanCacheDay(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Refresh the small global memory queue used by Review Chat's morning
    /// action. SQLite work stays on `StorageService`; only the final immutable
    /// plan is published on the main actor.
    func refreshMemoryCompanionPlan(limit: Int = 5, surfaceErrors: Bool = false) async {
        let now = Date()
        let cacheDay = Self.dailyReviewPlanCacheDay(for: now)
        let cap = max(1, min(limit, 25))
        let availableSourceIDs = articlesStore.articleIDs
        do {
            async let dueRequest = storage.dueMemoryItems(
                now: now,
                limit: cap,
                restrictToSourceIDs: availableSourceIDs
            )
            async let firstReviewRequest = storage.firstReviewMemoryItems(
                now: now,
                limit: cap,
                restrictToSourceIDs: availableSourceIDs
            )
            async let recentActivityRequest = storage.recentReviewSourceActivity(now: now)
            let (due, firstReviews, recentActivity) = try await (
                dueRequest,
                firstReviewRequest,
                recentActivityRequest
            )
            guard !Task.isCancelled else { return }

            let refreshedPlan = MemoryCompanionPlan.assemble(
                dueItems: due,
                firstReviews: firstReviews,
                availableSourceIDs: availableSourceIDs,
                recentSourceActivity: recentActivity,
                limit: cap,
                now: now
            )
            // `generatedAt` is diagnostic metadata, not visible queue state.
            // Preserve the current value when sync delivered no semantic change
            // so SwiftUI does not re-render the Review surface unnecessarily.
            let queueChanged = memoryCompanionPlan?.targets != refreshedPlan?.targets
                || memoryCompanionPlan?.topic != refreshedPlan?.topic
                || memoryCompanionPlan?.goalID != refreshedPlan?.goalID
            if queueChanged {
                memoryCompanionPlan = refreshedPlan
            }
            memoryCompanionPlanDay = cacheDay
        } catch {
            // A broken memory store must not be presented as an empty queue.
            // Keep the previous snapshot. Explicit learner actions get the
            // existing global toast; passive completion notifications only log.
            logger.error("Failed to refresh the memory companion plan: \(error.localizedDescription)")
            if surfaceErrors {
                showToast("Memory check couldn’t refresh. \(error.localizedDescription)")
            }
        }
    }

    private func resolvedDailyReviewGoalID(for goalID: String?) -> String? {
        if let goalID,
           notebooks.contains(where: { $0.id == goalID }) {
            return goalID
        }
        if let activeNotebookId,
           notebooks.contains(where: { $0.id == activeNotebookId }) {
            return activeNotebookId
        }
        return notebooks.first?.id
    }

    func preloadedDailyReviewPlan(for goalID: String? = nil) -> DailyReviewPlan? {
        guard preloadedDailyReviewPlanDay == Self.dailyReviewPlanCacheDay(),
              let resolvedGoalID = resolvedDailyReviewGoalID(for: goalID) else {
            return nil
        }
        return preloadedDailyReviewPlans[resolvedGoalID]
    }

    @discardableResult
    func refreshDailyReviewPlan(for goalID: String? = nil) async -> DailyReviewPlan? {
        guard let resolvedGoalID = resolvedDailyReviewGoalID(for: goalID) else { return nil }
        await refreshDailyReviewPlans(goalIDs: [resolvedGoalID])
        return preloadedDailyReviewPlan(for: resolvedGoalID)
    }

    func refreshDailyReviewPlans(goalIDs requestedGoalIDs: [String]? = nil) async {
        let cacheDay = Self.dailyReviewPlanCacheDay()
        let currentGoalIDs = Set(notebooks.map(\.id))
        let goalIDs = requestedGoalIDs ?? notebooks.map(\.id)

        guard !goalIDs.isEmpty else {
            preloadedDailyReviewPlanDay = cacheDay
            preloadedDailyReviewPlans = [:]
            return
        }

        var nextPlans = preloadedDailyReviewPlanDay == cacheDay ? preloadedDailyReviewPlans : [:]
        for goalID in goalIDs where currentGoalIDs.contains(goalID) {
            if Task.isCancelled { return }
            if let plan = await dailyReviewPlan(for: goalID) {
                nextPlans[goalID] = plan
            } else {
                nextPlans.removeValue(forKey: goalID)
            }
        }

        guard !Task.isCancelled else { return }
        let validGoalIDs = Set(notebooks.map(\.id))
        preloadedDailyReviewPlanDay = cacheDay
        preloadedDailyReviewPlans = nextPlans.filter { validGoalIDs.contains($0.key) }
    }

    /// Assemble today's chat-first review plan for a companion notebook (off-main memory
    /// lookup; main-actor snapshot for reading positions).
    func dailyReviewPlan(for goalID: String? = nil) async -> DailyReviewPlan? {
        guard let resolvedGoalID = resolvedDailyReviewGoalID(for: goalID),
              let goal = notebooks.first(where: { $0.id == resolvedGoalID }) else {
            return nil
        }

        let approved = Set(goal.items.filter(\.isApproved).map(\.sourceID))
        guard !approved.isEmpty else { return nil }

        let readingInProgress = Set(articlesById.values.compactMap { article -> String? in
            guard approved.contains(article.id) else { return nil }
            // Not a bare non-nil locator: a video marked not watched keeps one.
            if article.hasSavedReadingPosition {
                return article.id
            }
            return nil
        })

        let memoryDue: [MemoryReviewDueItem]
        do {
            let stats = try await storage.memoryReviewStats(restrictToSourceIDs: approved)
            memoryDue = MemoryReviewScheduler.dueItems(from: stats, now: Date(), limit: 50)
        } catch {
            logger.error("Failed to load memory review stats for daily plan: \(error.localizedDescription)")
            memoryDue = []
        }

        return DailyReviewPlan.assemble(
            goal: goal,
            memoryDue: memoryDue,
            readingInProgressSourceIDs: readingInProgress
        )
    }

    /// Open Review Chat with today's smart daily plan (no schedule writes).
    func startDailyReviewChat(goalID: String? = nil) async {
        let plan: DailyReviewPlan?
        if let preloaded = preloadedDailyReviewPlan(for: goalID) {
            plan = preloaded
        } else {
            plan = await refreshDailyReviewPlan(for: goalID)
        }
        guard let plan else { return }
        startDailyReviewChat(using: plan)
    }

    func startDailyReviewChat(using plan: DailyReviewPlan) {
        guard !plan.doneToday, !plan.sourceIDs.isEmpty else { return }
        startCompanionReview(
            goalID: plan.goalID,
            sourceIDs: plan.sourceIDs,
            topic: plan.topic,
            rationale: plan.rationale
        )
    }
}
