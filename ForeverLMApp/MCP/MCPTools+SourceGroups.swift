// MCPDataStore: Group renames, review session edits, lectures and source types.
import CryptoKit
import Foundation
import ImageIO
import Network
import OSLog
import PDFKit
import SQLite3

extension MCPDataStore {
    /// Rename a course, video-playlist, or meeting group by updating its metadata title.
    /// `groupKey` is the course name, the video-playlist id, or the meeting group name.
    func renameGroup(groupType: String, groupKey: String, newTitle: String) throws -> String {
        let store = try knowledgeStore()
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = groupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPError.invalidInput("new_title is required.") }
        guard !key.isEmpty else { throw MCPError.invalidInput("group_key is required.") }

        switch groupType {
        case "course":
            guard var meta = try store.loadCourseGroups()[key] else { throw MCPError.notFound("Course group not found: \(key)") }
            meta.title = title
            try store.saveCourseGroup(name: key, metadata: meta)
        case "video_playlist":
            guard var meta = try store.loadVideoPlaylistGroups()[key] else { throw MCPError.notFound("Video playlist not found: \(key)") }
            meta.title = title
            try store.saveVideoPlaylistGroup(id: key, metadata: meta)
        case "meeting":
            guard var meta = try store.loadMeetingGroups()[key] else { throw MCPError.notFound("Meeting group not found: \(key)") }
            meta.title = title
            try store.saveMeetingGroup(name: key, metadata: meta)
        default:
            throw MCPError.invalidInput("group_type must be one of: course, video_playlist, meeting.")
        }
        return "Renamed \(groupType) '\(key)' to '\(title)'."
    }

    /// Hide or unhide a course, video-playlist, or meeting group.
    func setGroupHidden(groupType: String, groupKey: String, hidden: Bool) throws -> String {
        let store = try knowledgeStore()
        let key = groupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MCPError.invalidInput("group_key is required.") }

        switch groupType {
        case "course":
            guard var meta = try store.loadCourseGroups()[key] else { throw MCPError.notFound("Course group not found: \(key)") }
            meta.isHidden = hidden
            try store.saveCourseGroup(name: key, metadata: meta)
        case "video_playlist":
            guard var meta = try store.loadVideoPlaylistGroups()[key] else { throw MCPError.notFound("Video playlist not found: \(key)") }
            meta.isHidden = hidden
            try store.saveVideoPlaylistGroup(id: key, metadata: meta)
        case "meeting":
            guard var meta = try store.loadMeetingGroups()[key] else { throw MCPError.notFound("Meeting group not found: \(key)") }
            meta.isHidden = hidden
            try store.saveMeetingGroup(name: key, metadata: meta)
        default:
            throw MCPError.invalidInput("group_type must be one of: course, video_playlist, meeting.")
        }
        return "\(hidden ? "Hid" : "Unhid") \(groupType) '\(key)'."
    }

    // MARK: - review session edits (MCP/UI parity)

    /// Delete a review session (or external session link) by ID.
    func deleteReviewSession(sessionID: String) throws -> String {
        let store = try knowledgeStore()
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("session_id is required.") }
        try store.deleteReviewSession(id)
        return "Deleted review session \(id)."
    }

    /// Replace the set of sources linked to a review session.
    func updateReviewSessionLinkedSources(sessionID: String, sourceIDs: [String]) throws -> String {
        let store = try knowledgeStore()
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("session_id is required.") }
        // A memory review's record is not the whole story: its briefing lists
        // the day's material too, and a reopen restores from it whatever the
        // record lost. Leaving a source out of a memory review therefore
        // records the removal there as well, the way the strip's × does.
        var removedFromReview: [String] = []
        if MemoryReviewSession.isMemorySession(id),
           let existing = try store.loadReviewSessionForSync(id),
           var briefing = try store.loadReviewSessionBriefing(sessionID: id) {
            let kept = Set(sourceIDs)
            removedFromReview = existing.sourceIDs.filter { !kept.contains($0) }
            if !removedFromReview.isEmpty {
                for sourceID in removedFromReview {
                    briefing = MemoryReviewTutoring.briefing(briefing, removingSource: sourceID)
                }
                try store.setReviewSessionBriefing(sessionID: id, briefing: briefing)
            }
        }
        // The junction's foreign key points at `sources`, so an id that is not a
        // source here would fail the whole replace with a bare constraint error.
        // A memory review may also list chats, which are not sources.
        if !MemoryReviewSession.isMemorySession(id) {
            let unknown = try sourceIDs.filter { try store.loadSourceWithoutContent($0) == nil }
            if !unknown.isEmpty {
                throw MCPError.notFound("No source with id \(unknown.joined(separator: ", ")) in this library. Add it first (add_sources, add_notebook_sources), then link it.")
            }
        }
        try store.updateReviewSessionSources(sessionID: id, sourceIDs: sourceIDs)
        var message = "Updated review session \(id) to \(sourceIDs.count) linked source\(sourceIDs.count == 1 ? "" : "s")."
        if !removedFromReview.isEmpty {
            message += " Removed \(removedFromReview.count) source\(removedFromReview.count == 1 ? "" : "s") from today's memory review; "
                + "the tutor stops asking about them when the review is next opened."
        }
        return message
    }

    /// The sidebar row's Rename, Move to Notebook and Hide, for a chat the
    /// assistant knows only by id.
    func updateReviewSession(
        sessionID: String,
        title: String?,
        notebookID: String?,
        isHidden: Bool? = nil,
        isPinned: Bool? = nil
    ) throws -> String {
        let store = try knowledgeStore()
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("session_id is required.") }
        guard title != nil || notebookID != nil || isHidden != nil || isPinned != nil else {
            throw MCPError.invalidInput("Pass title, notebook_id, is_hidden, is_pinned, or several.")
        }
        if isPinned != nil, MemoryReviewSession.isMemorySession(id) {
            throw MCPError.invalidInput("A day's memory review is Memory's and is never pinned.")
        }
        guard try store.loadReviewSessionForSync(id) != nil else {
            throw MCPError.notFound("Review session not found: \(id). Call get_review_sessions for the current ids.")
        }
        if let title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { throw MCPError.invalidInput("title cannot be empty.") }
            try store.updateReviewSessionTitle(sessionID: id, title: trimmedTitle)
        }
        if let notebookID {
            let trimmedNotebookID = notebookID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNotebookID.isEmpty {
                try store.updateReviewSessionGoal(sessionID: id, goalID: nil)
            } else {
                let goal = try resolveMCPChatHome(notebookID: trimmedNotebookID, store: store)
                try store.updateReviewSessionGoal(sessionID: id, goalID: goal.id)
            }
        }
        // Hiding is the learner's view of the chat, not a record change: the
        // chat is not republished and no team copy follows it; the hide
        // syncs as a record of its own.
        if let isHidden {
            try store.setReviewSessionHidden(id, hidden: isHidden)
        }
        // A pin is the learner's synced preference row (`ChatPins`), written
        // as Pin Chat writes it; the open window reseeds its pins from the
        // rows on the data-change reload.
        var pins = ChatPinRows.read()
        if let isPinned, isPinned != pins.isPinned(id) {
            if isPinned {
                let seconds = pins.newPinValue(at: Date())
                ChatPinRows.write(String(seconds), sessionID: id)
                pins = pins.setting(seconds, for: id)
            } else {
                ChatPinRows.write(nil, sessionID: id)
                pins = pins.setting(nil, for: id)
            }
        }
        guard let updated = try store.loadReviewSessionForSync(id) else {
            throw MCPError.notFound("Review session not found: \(id).")
        }
        let hiddenAt = try store.reviewSessionHiddenAt(sessionID: id)
        let placement = updated.goalID == nil
            ? "‘\(updated.topic)’ is in the ungrouped Chats list."
            : "‘\(updated.topic)’ is filed under Notebook \(updated.goalID ?? "")."
        return try jsonString([
            "status": "updated",
            "session_id": id,
            "title": updated.topic,
            "notebook_id": updated.goalID.map { $0 as Any } ?? NSNull(),
            "is_hidden": hiddenAt != nil,
            "hidden_at": hiddenAt.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
            "is_pinned": pins.isPinned(id),
            "message": (hiddenAt == nil
                ? placement
                : placement + " It is hidden from the sidebar; the Hidden fold under Chats lists it.")
                + (pins.isPinned(id) ? " It is pinned: Home's sidebar lists it under Pinned." : ""),
        ] as [String: Any])
    }

    // MARK: - Plugin auto-import preferences (MCP/UI parity)

    /// Toggle automatic import for the YouTube plugin.
    func setPluginAutoImport(plugin: String, enabled: Bool) throws -> String {
        switch plugin {
        case "youtube", "you_tube":
            StudioViewModel.setYouTubeAutoImportEnabled(enabled)
            return "YouTube auto-import \(enabled ? "enabled" : "disabled")."
        default:
            throw MCPError.invalidInput("plugin must be youtube.")
        }
    }

    // MARK: - Course lectures (MCP/UI parity)

    /// Create a numbered lecture inside a course. The number is auto-assigned as the
    /// next available number for that course unless `number` is given.
    func createCourseLecture(courseName: String, title: String?, number: Int?) throws -> String {
        let store = try knowledgeStore()
        let course = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !course.isEmpty else { throw MCPError.invalidInput("course_name is required.") }

        let existing = try store.loadCourseLectures().filter { $0.courseName == course }
        let resolvedNumber = number ?? ((existing.map(\.number).max() ?? 0) + 1)
        let lecture = CourseSession(courseName: course, number: resolvedNumber, title: Self.nilIfBlank(title ?? ""))
        try store.saveCourseLecture(lecture)
        // The new lecture's id rides on its own line (Prompts.hiddenIDs).
        return "Created lecture \(resolvedNumber)\(lecture.title.map { " '\($0)'" } ?? "") in course '\(course)'.\nlecture_id: \(lecture.id)"
    }

    /// Rename a course lecture by ID.
    func renameCourseLecture(lectureID: String, title: String) throws -> String {
        let store = try knowledgeStore()
        let id = lectureID.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("lecture_id is required.") }
        guard !newTitle.isEmpty else { throw MCPError.invalidInput("title is required.") }
        guard var lecture = try store.loadCourseLectures().first(where: { $0.id == id }) else {
            throw MCPError.notFound("Lecture not found: \(id)")
        }
        lecture.title = newTitle
        try store.saveCourseLecture(lecture)
        return "Renamed lecture \(lecture.number) of course '\(lecture.courseName)' to '\(newTitle)'."
    }

    /// Attach a source to a course lecture as a material.
    func addSourceToLecture(lectureID: String, sourceID: String, role: String?) throws -> String {
        let store = try knowledgeStore()
        let lecture = lectureID.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lecture.isEmpty else { throw MCPError.invalidInput("lecture_id is required.") }
        guard !source.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let lectureRecord = try store.loadCourseLectures().first(where: { $0.id == lecture }) else {
            throw MCPError.notFound("Lecture not found: \(lecture)")
        }

        let existingItems = try store.loadCourseLectureItems().filter { $0.lectureId == lecture }
        let nextSort = (existingItems.map(\.sortIndex).max() ?? -1) + 1
        let resolvedRole = role.flatMap { CourseLectureItemRole(rawValue: $0) } ?? .other
        let item = CourseLectureItem(lectureId: lecture, sourceId: source, role: resolvedRole, sortIndex: nextSort)
        try store.saveCourseLectureItem(item)
        let sourceName = (try store.loadSourceForSync(source)).map { "'\($0.title)'" } ?? "the source"
        return "Added \(sourceName) to lecture \(lectureRecord.number) of course '\(lectureRecord.courseName)' (role: \(resolvedRole.rawValue))."
    }

    /// Remove a material from a course lecture by lecture-item ID.
    func removeCourseLectureItem(itemID: String) throws -> String {
        let store = try knowledgeStore()
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("item_id is required.") }
        try store.deleteCourseLectureItem(id)
        return "Removed lecture item \(id)."
    }

    // MARK: - Misc source/group ops (MCP/UI parity)

    /// Change a source's type (e.g. reclassify an article as a paper).
    func moveSourceType(sourceID: String, newType: String) throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = newType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        let valid = ["article", "paper", "podcast", "book", "course", "video", "meeting", "manual", "unclassified"]
        guard valid.contains(type) else {
            throw MCPError.invalidInput("new_type must be one of: \(valid.joined(separator: ", ")).")
        }
        try store.updateSourceType(id, to: type)
        let title = (try store.loadSourceForSync(id))?.title
        return "Changed the type of \(title.map { "'\($0)'" } ?? "the source") to \(type)."
    }

    /// Remove every episode of a podcast show (matched by show name), the same way the
    /// Studio "Remove All from <show>" action does: dismiss + archive each, and
    /// stop importing the show, so playing another episode does not bring it
    /// back. `set_podcast_show_import_blocked` with `false` undoes the block.
    func removeAllFromPodcastShow(showName: String) throws -> String {
        let store = try knowledgeStore()
        let name = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MCPError.invalidInput("show_name is required.") }
        let episodes = try store.loadActiveSources().filter { $0.sourceType == .podcast && $0.domain == name }
        guard !episodes.isEmpty else { return "No episodes found for podcast show '\(name)'." }
        var removed = 0
        for episode in episodes {
            _ = try removeSource(episode.id)
            removed += 1
        }
        SourceDiscovery.setPodcastShowBlocked(name, blocked: true)
        return "Removed \(removed) episode\(removed == 1 ? "" : "s") from podcast show '\(name)', and stopped importing it."
    }

    // MARK: - AI metadata extraction (MCP/UI parity)
}
