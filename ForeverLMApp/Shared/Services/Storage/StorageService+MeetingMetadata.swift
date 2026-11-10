// StorageService: meeting metadata.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Meeting Metadata

    func loadMeetingMetadata() throws -> [String: MeetingMetadata] {
        try ensureStoreExists()
        return try knowledgeStore().loadMeetingGroups()
    }

    func saveMeetingGroup(name: String, metadata: MeetingMetadata) throws {
        try ensureStoreExists()
        try knowledgeStore().saveMeetingGroup(name: name, metadata: metadata)
        scheduleCloudKitSync(.immediate)
    }

    /// The series that meet at a fixed time, for the Planner's import.
    func scheduledMeetingGroups() throws -> [(id: String, title: String, schedule: MeetingSchedule)] {
        try ensureStoreExists()
        return try knowledgeStore().scheduledMeetingGroups()
    }

    func canonicalMeetingGroupID(_ groupID: String) throws -> String {
        try ensureStoreExists()
        return try knowledgeStore().canonicalMeetingGroupID(groupID)
    }

    func meetingGroupIDs() throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().meetingGroupIDs()
    }

    /// A series' schedule, set or cleared; the series' record syncs at once
    /// and the Planner is told so today is redrawn.
    func setMeetingSchedule(_ schedule: MeetingSchedule?, groupID: String) throws {
        try ensureStoreExists()
        let store = try knowledgeStore()
        guard var metadata = try store.loadMeetingGroups()[groupID] else {
            throw KnowledgeStoreError.invalidData("Meeting group not found: \(groupID)")
        }
        metadata.schedule = schedule
        try store.saveMeetingGroup(name: groupID, metadata: metadata)
        scheduleCloudKitSync(.immediate)
        NotificationCenter.default.post(name: .meetingSchedulesDidChange, object: nil)
    }

    func loadMeetingActionItems(groupID: String? = nil, sourceID: String? = nil) throws -> [MeetingActionItem] {
        try ensureStoreExists()
        return try knowledgeStore().loadMeetingActionItems(groupID: groupID, sourceID: sourceID)
    }

    func hasMeetingActionItems(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().hasMeetingActionItems(sourceID: sourceID)
    }

    func saveMeetingActionItems(_ items: [MeetingActionItem], groupID: String, sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().saveMeetingActionItems(items, groupID: groupID, sourceID: sourceID)
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
    }

    @discardableResult
    func setMeetingActionItemDone(_ id: String, done: Bool) throws -> MeetingActionItem {
        try ensureStoreExists()
        let item = try knowledgeStore().setMeetingActionItemDone(id, done: done)
        scheduleCloudKitSync(.immediate)
        NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
        return item
    }

    /// The active meeting group a plugin's stable ID or title names, after
    /// any merge alias — the same lookup the MCP tools use to file a session.
    func resolvedMeetingGroupID(matching input: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().resolvedMeetingGroupID(matching: input)
    }

    func loadMeetingArtifacts(groupID: String? = nil, sourceID: String? = nil) throws -> [MeetingArtifact] {
        try ensureStoreExists()
        return try knowledgeStore().loadMeetingArtifacts(groupID: groupID, sourceID: sourceID)
    }

    func saveMeetingArtifact(_ artifact: MeetingArtifact) throws {
        try ensureStoreExists()
        try knowledgeStore().saveMeetingArtifact(artifact)
        scheduleCloudKitSync()
    }

    func deleteMeetingGroup(name: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteMeetingGroup(name: name)
        scheduleCloudKitSync(.immediate)
    }

    /// Delete a meeting series and its sessions for good, and drop each deleted
    /// session out of the search indexes the way `deleteSource` does.
    /// Returns the source IDs that were deleted.
    func deleteMeetingGroupWithSessions(
        name: String,
        additionalSessionIDs: Set<String> = []
    ) throws -> [String] {
        try ensureStoreExists()
        let deleted = try knowledgeStore().deleteMeetingGroupWithSessions(
            name: name,
            additionalSessionIDs: additionalSessionIDs
        )
        for sourceID in deleted {
            removeFromSearchIndexes(sourceID)
        }
        scheduleCloudKitSync(.immediate)
        return deleted
    }

    /// Atomically update a source's type in the database and mark it as manually set.
    func updateSourceType(_ sourceId: String, to newType: String) throws {
        try knowledgeStore().updateSourceType(sourceId, to: newType)
        scheduleCloudKitSync(.immediate)
    }

    /// Sanitize filename: stem must match [0-9a-zA-Z]{4,16}
    static func sanitizeFilename(_ filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        var stem = url.deletingPathExtension().lastPathComponent
        
        // Remove non-alphanumeric characters
        stem = stem.filter { $0.isLetter || $0.isNumber }
        
        // Ensure length 4-16
        if stem.count < 4 {
            stem = stem + String(repeating: "x", count: 4 - stem.count)
        }
        if stem.count > 16 {
            stem = String(stem.prefix(16))
        }
        
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

}
