import Foundation

extension StorageService {

    /// Today against its goal, and the streak, from every device's rows. The
    /// goal for today is the budget as this Mac knows it now; past days keep
    /// the goal they were worked under.
    func memoryReviewGoalSnapshot(now: Date = Date()) throws -> MemoryReviewGoalSnapshot {
        let rows = try cohortKnowledgeStore().loadMemoryReviewActivities()
        return MemoryReviewProgress.snapshot(
            rows: rows,
            today: MemoryReviewGoal.dayKey(for: now),
            goalSecondsNow: MemoryReviewGoal.goalSeconds(budgetMinutes: MemoryReviewBudget.minutes)
        )
    }

    func loadMemoryReviewActivities() throws -> [MemoryReviewActivity] {
        try cohortKnowledgeStore().loadMemoryReviewActivities()
    }

    /// The days with a memory review chat the learner wrote in; see
    /// `KnowledgeStore.answeredMemoryReviewDays`.
    func answeredMemoryReviewDays() throws -> Set<String> {
        try cohortKnowledgeStore().answeredMemoryReviewDays()
    }

    /// This device's total for the day so far, if it has one.
    func memoryReviewActivity(day: String, deviceID: String) throws -> MemoryReviewActivity? {
        try cohortKnowledgeStore().loadMemoryReviewActivity(MemoryReviewGoal.activityID(day: day, deviceID: deviceID))
    }

    func recordMemoryReviewActivity(_ activity: MemoryReviewActivity) throws {
        try cohortKnowledgeStore().recordMemoryReviewActivity(activity)
    }
}
