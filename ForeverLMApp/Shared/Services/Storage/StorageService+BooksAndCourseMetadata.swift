// StorageService: books, course metadata and video playlist metadata.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Books

    struct BookRecord {
        var titles: [String: String]
        var subtitles: [String: String]
        var authors: [String: String]
        var editions: [String: String]
        var coverPaths: [String: String]
        var kinds: [String: String]
    }

    func loadBooks() throws -> BookRecord {
        try ensureStoreExists()
        let row = try knowledgeStore().loadBooks()
        return BookRecord(
            titles: row.titles,
            subtitles: row.subtitles,
            authors: row.authors,
            editions: row.editions,
            coverPaths: row.coverPaths,
            kinds: row.kinds
        )
    }

    /// Set or clear one field of one book (`KnowledgeStore.setBookField`).
    @discardableResult
    func setBookField(_ field: KnowledgeStore.BookField, of groupName: String, to value: String?) throws -> String? {
        try ensureStoreExists()
        let stored = try knowledgeStore().setBookField(field, of: groupName, to: value)
        scheduleCloudKitSync()
        return stored
    }

    func saveBookMetadata(
        groupName: String,
        title: String? = nil,
        subtitle: String? = nil,
        author: String? = nil,
        edition: String? = nil,
        coverPath: String?,
        kind: String? = nil
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().saveBookMetadata(
            groupName: groupName,
            title: title,
            subtitle: subtitle,
            author: author,
            edition: edition,
            coverPath: coverPath,
            kind: kind
        )
        scheduleCloudKitSync()
    }

    func renameBookGroup(from oldName: String, to newName: String) throws {
        try ensureStoreExists()
        try knowledgeStore().renameBookGroup(from: oldName, to: newName)
        scheduleCloudKitSync(.immediate)
    }

    func unarchiveSource(_ sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().unarchiveSource(sourceID)
        scheduleCloudKitSync()
    }

    /// The full restore the `unarchive_source` MCP tool performs — status,
    /// dismissal, and text rebuilt from a local file — for the app's own
    /// Unarchive actions. Nil when no source row carries the id.
    func unarchiveSourceRestoringContent(_ sourceID: String) throws -> SourceUnarchiveOutcome? {
        try ensureStoreExists()
        let outcome = try knowledgeStore().unarchiveSourceRestoringContent(sourceID)
        if outcome != nil { scheduleCloudKitSync() }
        return outcome
    }

    /// Title and status for each id that has a `sources` row, archived rows
    /// included; ids without a row are absent.
    func sourceRowSummaries(for sourceIDs: some Collection<String>) throws -> [String: SourceRowSummary] {
        try ensureStoreExists()
        return try knowledgeStore().sourceRowSummaries(for: sourceIDs)
    }

    /// Whether a source row with this id exists in the library, regardless of its
    /// active/archived status. Used to safely resolve Chat citations that may point at
    /// archived sources before mutating any state.
    func sourceExists(_ sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().sourceExists(sourceID)
    }

    /// Resolve the id carried by a Chat citation link to a real `sources.id`, tolerating
    /// truncated or shortened ids (see `KnowledgeStore.resolveSourceID(forLinkToken:)`).
    func resolveSourceID(forLinkToken token: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().resolveSourceID(forLinkToken: token)
    }

    func archiveSourcesByParentGroup(_ parentGroup: String) throws {
        try ensureStoreExists()
        let sourceIDs = try knowledgeStore().sourceIDsByParentGroup(parentGroup)
        for sourceID in sourceIDs {
            try archiveSource(sourceID)
        }
    }

    /// Inverse of `archiveSourcesByParentGroup`. Group membership outlives
    /// archiving, so this finds the archived members and sets them active again.
    /// Archiving cleared their text, so callers that can re-fetch (a Drive-backed
    /// meeting group, say) should refresh the group afterwards.
    func unarchiveSourcesByParentGroup(_ parentGroup: String) throws {
        try ensureStoreExists()
        let sourceIDs = try knowledgeStore().sourceIDsByParentGroup(parentGroup)
        for sourceID in sourceIDs {
            try unarchiveSource(sourceID)
        }
    }

    func sourceCountByParentGroup(_ parentGroup: String) throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceCountByParentGroup(parentGroup)
    }

    /// Chapter paths relative to the extracted `Chapters` directory, mapped to their archived state, for
    /// aligning the EPUB reader's Contents menu with ingested chapter sources.
    func bookChapterArchivedByRelativePath(groupID: String) throws -> [String: Bool] {
        try ensureStoreExists()
        return try knowledgeStore().bookChapterArchivedByRelativePath(groupID: groupID)
    }

    // MARK: - Course Metadata

    func loadCourseMetadata() throws -> [String: CourseMetadata] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseGroups()
    }

    func saveCourseGroup(name: String, metadata: CourseMetadata) throws {
        try ensureStoreExists()
        try knowledgeStore().saveCourseGroup(name: name, metadata: metadata)
        scheduleCloudKitSync(.immediate)
    }

    // MARK: - Video Playlist Metadata

    func loadVideoPlaylistMetadata() throws -> [String: VideoPlaylistMetadata] {
        try ensureStoreExists()
        return try knowledgeStore().loadVideoPlaylistGroups()
    }

    func saveVideoPlaylistGroup(id: String, metadata: VideoPlaylistMetadata) throws {
        try ensureStoreExists()
        try knowledgeStore().saveVideoPlaylistGroup(id: id, metadata: metadata)
        scheduleCloudKitSync(.immediate)
    }

    func deleteVideoPlaylistGroup(id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteVideoPlaylistGroup(id: id)
        scheduleCloudKitSync(.immediate)
    }

    func loadCourseLectures() throws -> [CourseSession] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseLectures()
    }

    func loadCourseLectureItems() throws -> [CourseLectureItem] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseLectureItems()
    }

}
