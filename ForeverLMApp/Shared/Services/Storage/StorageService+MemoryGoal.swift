import Foundation

extension StorageService {

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
