// StorageService: course quizzes and textbook readings.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: Course quizzes (schema 138)

    func loadCourseQuizzes(courseID: String? = nil) throws -> [CourseQuiz] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseQuizzes(courseID: courseID)
    }

    /// The course outline a chat about these sources reads
    /// (`CourseChatOutline`); nil when none of them is lecture material.
    /// A read beside the catalog's `sourceContentLengths`, so like it this
    /// creates nothing.
    func courseChatOutlineMaterial(forSourceIDs sourceIDs: [String]) throws -> CourseChatOutline.Material? {
        try knowledgeStore().courseChatOutlineMaterial(forSourceIDs: sourceIDs)
    }

    func loadCourseQuiz(_ id: String) throws -> CourseQuiz? {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseQuiz(id)
    }

    /// The quizzes whose questions' JSON holds any of `texts`
    /// (`KnowledgeStore.loadCourseQuizzes(mentioning:)`).
    func loadCourseQuizzes(mentioning texts: [String]) throws -> [CourseQuiz] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseQuizzes(mentioning: texts)
    }

    func saveCourseQuiz(_ quiz: CourseQuiz) throws {
        try ensureStoreExists()
        try knowledgeStore().saveCourseQuiz(quiz)
        scheduleCloudKitSync(.coalesced)
    }

    func deleteCourseQuiz(_ id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteCourseQuiz(id)
        scheduleCloudKitSync(.coalesced)
    }

    func loadCourseArtworkURLs() throws -> [String: String] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseArtworkURLs()
    }

    func saveCourseLecture(_ lecture: CourseSession) throws {
        try ensureStoreExists()
        try knowledgeStore().saveCourseLecture(lecture)
        scheduleCloudKitSync(.immediate)
    }

    @discardableResult
    func saveCourseLectureItem(_ item: CourseLectureItem) throws -> Int {
        try ensureStoreExists()
        let store = try knowledgeStore()
        // A team's course files the team's rows: an own source goes into the
        // team first (teams-design.md, decision 21), and the store files it.
        if let courseID = try store.courseNameForLecture(item.lectureId), try store.courseTeamID(courseID) != nil {
            let needed = try courseItemSourceIDs([item], store: store)
            let filed = try courseLibrarySourceIDs(courseID: courseID, needed)
            guard needed.allSatisfy({ filed[$0] != nil }) else {
                throw KnowledgeStoreError.invalidData("This source could not be copied into the team that holds the course.")
            }
        }
        let notebookSourcesAdded = try store.saveCourseLectureItem(item)
        scheduleCloudKitSync(.immediate)
        return notebookSourcesAdded
    }

    /// Every source a lecture item names: its own, and the chapter its page
    /// unit reads.
    private func courseItemSourceIDs(_ items: [CourseLectureItem], store: KnowledgeStore) throws -> [String] {
        let unitSources = try store.loadSourceUnits(ids: items.compactMap(\.sourceUnitId)).map(\.sourceId)
        return items.compactMap(\.sourceId) + unitSources
    }

    func deleteCourseLectureItem(_ itemId: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteCourseLectureItem(itemId)
        scheduleCloudKitSync(.immediate)
    }

    func deleteCourseLecture(_ lectureId: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteCourseLecture(lectureId)
        scheduleCloudKitSync(.immediate)
    }

    func saveSourceUnit(_ unit: SourceUnit) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSourceUnit(unit)
        scheduleCloudKitSync()
    }

    func saveCourseOutline(courseName: String, lectures: [CourseSession], items: [CourseLectureItem]) throws {
        try ensureStoreExists()
        let store = try knowledgeStore()
        var items = items
        // A team's course files the team's rows: own sources go into the team
        // first (teams-design.md, decision 21), and an item whose source could
        // not be copied is left out rather than naming a row only this
        // library holds.
        if try store.courseTeamID(courseName) != nil {
            let unitSources = Dictionary(
                try store.loadSourceUnits(ids: items.compactMap(\.sourceUnitId)).map { ($0.id, $0.sourceId) },
                uniquingKeysWith: { first, _ in first }
            )
            let filed = try courseLibrarySourceIDs(
                courseID: courseName,
                items.compactMap(\.sourceId) + Array(unitSources.values)
            )
            items = items.filter { item in
                let needed = [item.sourceId, item.sourceUnitId.flatMap { unitSources[$0] }].compactMap { $0 }
                return needed.allSatisfy { filed[$0] != nil }
            }
        }
        try store.saveCourseOutline(courseName: courseName, lectures: lectures, items: items)
        scheduleCloudKitSync()
    }

    // MARK: Textbook readings (docs/textbook-readings-design.md)

    /// Replaces a book's readings in a course; see
    /// `KnowledgeStore.replaceTextbookReadings`. The book's chapters are read
    /// here, archived and hidden ones included, so a chapter hidden since the
    /// last plan still loses the readings that plan gave it.
    @discardableResult
    func replaceTextbookReadings(
        courseID: String,
        bookID: String,
        placements: [TextbookReadingPlacement]
    ) throws -> [CourseLectureItem] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        let chapterIDs = try store.bookChapterSourceIDs(bookID: bookID, includingUnavailable: true)
        var bookChapterIDs = Set(chapterIDs.map(\.sourceID))
        var placements = placements
        // A team's course reads the team's copies of the chapters
        // (teams-design.md, decision 21): the ones placed are copied into the
        // team first, files included, and the plan names them; every chapter's
        // team copy counts as the book's, so planning again replaces the
        // readings an earlier plan gave the team's course.
        if let teamID = try store.courseTeamID(courseID) {
            let filed = try courseLibrarySourceIDs(courseID: courseID, placements.map(\.chapterSourceID))
            for chapter in chapterIDs {
                if let url = try store.loadSourceWithoutContent(chapter.sourceID)?.url {
                    bookChapterIDs.insert(try store.teamSourceCopyID(teamID: teamID, url: url))
                }
            }
            placements = placements.compactMap { placement in
                filed[placement.chapterSourceID].map { chapterSourceID in
                    TextbookReadingPlacement(
                        lectureID: placement.lectureID,
                        lectureNumber: placement.lectureNumber,
                        chapterSourceID: chapterSourceID,
                        chapterNumber: placement.chapterNumber,
                        chapterTitle: placement.chapterTitle,
                        pages: placement.pages,
                        title: placement.title,
                        reason: placement.reason
                    )
                }
            }
        }
        let items = try store.replaceTextbookReadings(
            courseID: courseID,
            bookChapterIDs: bookChapterIDs,
            placements: placements
        )
        scheduleCloudKitSync(.immediate)
        return items
    }

    /// The chapters the reading planner may offer, in reading order: active,
    /// not hidden, and not kept from AI (`knowledgeSearchExcludedSourceIDs`).
    func textbookChapterSources(bookID: String) throws -> [(sourceID: String, title: String, sortIndex: Int?)] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs()
        return try store.bookChapterSourceIDs(bookID: bookID).filter { !excluded.contains($0.sourceID) }
    }

    /// Sources the learner keeps from AI, which no planner reads.
    func knowledgeBoundaryExcludedSourceIDs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().knowledgeSearchExcludedSourceIDs()
    }

    /// The same boundary with archived sources counted too, as a tool that
    /// opens one source by id asks it.
    func knowledgeSearchExcludedSourceIDs(includeArchived: Bool) throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: includeArchived)
    }

    func loadCourseSourceUnits() throws -> [String: SourceUnit] {
        try ensureStoreExists()
        return try knowledgeStore().loadCourseSourceUnits()
    }

    func learnerContextNotebooks(courseID: String) throws -> [CourseLearnerContext.Notebook] {
        try ensureStoreExists()
        return try knowledgeStore().learnerContextNotebooks(courseID: courseID)
    }

    /// Returns the course sources hidden because the deletion left them in no
    /// course — see `KnowledgeStore.hideCourseSourcesWithoutCourse`.
    @discardableResult
    func deleteCourseGroup(name: String) throws -> [String] {
        try ensureStoreExists()
        let hiddenSourceIDs = try knowledgeStore().deleteCourseGroup(name: name)
        scheduleCloudKitSync(.immediate)
        return hiddenSourceIDs
    }

}
