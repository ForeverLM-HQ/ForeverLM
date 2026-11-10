// StorageService: video cited papers.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Video Cited Papers

    func saveVideoCitedPaper(_ paper: VideoCitedPaper) throws {
        try ensureStoreExists()
        try knowledgeStore().saveVideoCitedPaper(paper)
        scheduleCloudKitSync(.immediate)
    }

    func loadVideoCitedPapers(forSourceID sourceID: String) throws -> [VideoCitedPaper] {
        try ensureStoreExists()
        return try knowledgeStore().loadVideoCitedPapers(forSourceID: sourceID)
    }

    func loadVideoCitedPaper(id: String) throws -> VideoCitedPaper? {
        try ensureStoreExists()
        return try knowledgeStore().loadVideoCitedPaper(id: id)
    }

    func deleteVideoCitedPaper(id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteVideoCitedPaper(id: id)
        scheduleCloudKitSync(.immediate)
    }

    func upsertCompanionGaps(goalID: String, gaps: [LearningGoalGap]) throws {
        try knowledgeStore().upsertCompanionGaps(goalID: goalID, gaps: gaps)
        scheduleCloudKitSync(.immediate)
    }

    func saveLearningGoalGap(_ gap: LearningGoalGap, goalID: String) throws {
        try knowledgeStore().saveLearningGoalGap(gap, goalID: goalID)
        try knowledgeStore().touchLearningGoal(goalID)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func addCompanionSeedSources(goalID: String, sourceIDs: [String]) throws -> Int {
        let sourceIDs = try sourceIDsForGoalLibrary(goalID: goalID, sourceIDs)
        let added = try knowledgeStore().addCompanionSeedSources(goalID: goalID, sourceIDs: sourceIDs)
        scheduleCloudKitSync(.immediate)
        return added
    }

    @discardableResult
    func linkCourseToNotebook(goalID: String, courseID: String, sourceIDs: [String]) throws -> Int {
        let sourceIDs = try sourceIDsForGoalLibrary(goalID: goalID, sourceIDs)
        let added = try knowledgeStore().linkCourseToNotebook(
            goalID: goalID,
            courseID: courseID,
            sourceIDs: sourceIDs
        )
        scheduleCloudKitSync(.immediate)
        return added
    }

    /// The Sources sidebar's Remove All on a course the notebook follows.
    @discardableResult
    func unlinkCourseFromNotebook(goalID: String, courseID: String) throws -> Bool {
        let unlinked = try knowledgeStore().unlinkCourseFromNotebook(goalID: goalID, courseID: courseID)
        if unlinked { scheduleCloudKitSync(.immediate) }
        return unlinked
    }

    func linkedCourseIDsForNotebook(goalID: String) throws -> [String] {
        try knowledgeStore().linkedCourseIDsForNotebook(goalID: goalID)
    }

}
