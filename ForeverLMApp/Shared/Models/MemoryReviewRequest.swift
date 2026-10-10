import Foundation

/// What the Memory row hands the Chat panel when today's review does not exist
/// yet: the day's session id and the material already assembled for it.
///
/// Mac only — `LearningCohort` is assembled from `knowledge.db`, which the
/// phone does not have. The day's identity itself is `MemoryReviewSession`.
struct MemoryReviewRequest: Equatable, Sendable {
    let sessionID: String
    let cohort: LearningCohort
}
