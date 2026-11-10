import Testing
import Foundation
@testable import ForeverLM

// MARK: - Helpers

private func makeArticle(
    url: String = "https://example.com",
    title: String = "Test",
    sourceType: StudioSourceType = .article,
    parentGroup: String? = nil,
    discoveryOrigin: DiscoveryOrigin? = nil
) -> StudioArticle {
    StudioArticle(
        url: url,
        title: title,
        sourceType: sourceType,
        discoveryOrigin: discoveryOrigin,
        parentGroup: parentGroup
    )
}

// MARK: - removeArticle

@Suite("removeArticle")
@MainActor
struct RemoveArticleTests {

    @Test("keeps removed article in memory as hidden")
    func keepsHiddenRecordInArray() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        try? await vm.storage.saveSource(a1)
        try? await vm.storage.saveSource(a2)
        vm.articles = [a1, a2]

        await vm.removeArticle(id: a1.id)

        #expect(vm.articles.count == 2)
        #expect(vm.articles.first(where: { $0.id == a1.id })?.isHidden == true)
        #expect(vm.articles.filter { !vm.isSourceHidden($0) }.map(\.id) == [a2.id])
    }

    @Test("updates selectedArticleId to next article when removed is selected")
    func updatesSelectionToNext() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        try? await vm.storage.saveSource(a1)
        try? await vm.storage.saveSource(a2)
        vm.articles = [a1, a2]
        vm.selectedArticleId = a1.id

        await vm.removeArticle(id: a1.id)

        #expect(vm.selectedArticleId == a2.id)
    }

    @Test("clears selectedArticleId when it is the only article")
    func clearsSelectionWhenOnly() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        try? await vm.storage.saveSource(a1)
        vm.articles = [a1]
        vm.selectedArticleId = a1.id

        await vm.removeArticle(id: a1.id)

        #expect(vm.selectedArticleId == nil)
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].isHidden)
        #expect(vm.articles.filter { !vm.isSourceHidden($0) }.isEmpty)
    }

    @Test("non-existent ID is a no-op")
    func nonExistentIdNoOp() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        try? await vm.storage.saveSource(a1)
        vm.articles = [a1]

        await vm.removeArticle(id: "nonexistent-id")

        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].id == a1.id)
    }

    @Test("does not affect other articles")
    func doesNotAffectOthers() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        let a3 = makeArticle(url: "https://c.com", title: "C")
        try? await vm.storage.saveSource(a1)
        try? await vm.storage.saveSource(a2)
        try? await vm.storage.saveSource(a3)
        vm.articles = [a1, a2, a3]

        await vm.removeArticle(id: a2.id)

        #expect(vm.articles.count == 3)
        #expect(vm.articles.first(where: { $0.id == a2.id })?.isHidden == true)
        #expect(vm.articles.filter { !vm.isSourceHidden($0) }.map(\.id) == [a1.id, a3.id])
    }
}

// MARK: - removeSelected

@Suite("removeSelected")
@MainActor
struct RemoveSelectedTests {

    @Test("hides all specified articles without deleting their records")
    func hidesAllSpecified() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        let a3 = makeArticle(url: "https://c.com", title: "C")
        try? await vm.storage.saveSource(a1)
        try? await vm.storage.saveSource(a2)
        try? await vm.storage.saveSource(a3)
        vm.articles = [a1, a2, a3]

        await vm.removeSelected(Set([a1.id, a3.id]))

        #expect(vm.articles.count == 3)
        #expect(vm.articles.first(where: { $0.id == a1.id })?.isHidden == true)
        #expect(vm.articles.first(where: { $0.id == a2.id })?.isHidden == false)
        #expect(vm.articles.first(where: { $0.id == a3.id })?.isHidden == true)
    }

    @Test("removes only the deleted IDs from selectedArticleIds set")
    func clearsSelectedArticleIds() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        try? await vm.storage.saveSource(a1)
        try? await vm.storage.saveSource(a2)
        vm.articles = [a1, a2]
        vm.selectedArticleIds = Set([a1.id, a2.id])

        await vm.removeSelected(Set([a1.id]))

        // removeSelected subtracts only the removed IDs, preserving the rest of the
        // selection so the surviving article stays selected.
        #expect(vm.selectedArticleIds == Set([a2.id]))
    }

    @Test("updates selectedArticleId when current selection removed")
    func updatesSelectedArticleId() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        let a2 = makeArticle(url: "https://b.com", title: "B")
        let a3 = makeArticle(url: "https://c.com", title: "C")
        try? await vm.storage.saveSource(a1)
        try? await vm.storage.saveSource(a2)
        try? await vm.storage.saveSource(a3)
        vm.articles = [a1, a2, a3]
        vm.selectedArticleId = a1.id

        await vm.removeSelected(Set([a1.id]))

        // selectedArticleId should be updated to the first remaining active article
        #expect(vm.selectedArticleId == a2.id)
    }

    @Test("empty set is a no-op")
    func emptySetNoOp() async {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://a.com", title: "A")
        try? await vm.storage.saveSource(a1)
        vm.articles = [a1]
        vm.selectedArticleId = a1.id

        await vm.removeSelected(Set<String>())

        #expect(vm.articles.count == 1)
        #expect(vm.selectedArticleId == a1.id)
    }

    @Test("paper without PDF stays untouched during the Undo window")
    func paperWithoutPDFStaysUntouchedWhileUndoable() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceRemovalTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        var paper = makeArticle(
            url: "https://arxiv.org/abs/1706.03762",
            title: "Attention Is All You Need",
            sourceType: .paper
        )
        _ = try await service.insertSourceIfNew(&paper)
        vm.articles = try await service.loadActiveSources()

        await vm.removeSelected([paper.id])

        let all = try await service.loadSources()
        #expect(all.contains { $0.id == paper.id && $0.status == .active && $0.isHidden })
        #expect(vm.articles.first(where: { $0.id == paper.id })?.isHidden == true)
    }

    @Test("Undo restores the original source and selection")
    func undoRestoresOriginalSourceAndSelection() async throws {
        let vm = makeViewModel()
        var video = makeArticle(
            url: "https://youtube.com/watch?v=undo",
            title: "Lecture",
            sourceType: .video
        )
        video.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 420,
            watchedSeconds: 600,
            durationSeconds: 900
        ).encoded
        try await vm.storage.saveSource(video)
        vm.articles = [video]
        vm.selectedArticleId = video.id
        vm.selectedArticleIds = [video.id]

        await vm.removeSelected([video.id])
        #expect(vm.pendingDeletionNotices.count == 1)
        #expect(vm.articles[0].isHidden)

        await vm.undoLatestDeletion()

        let storedSources = try await vm.storage.loadSources()
        let restored = try #require(storedSources.first { $0.id == video.id })
        #expect(vm.pendingDeletionNotices.isEmpty)
        #expect(vm.articles[0].isHidden == false)
        #expect(restored.status == .active)
        #expect(restored.isHidden == false)
        #expect(restored.readingPositionLocator == video.readingPositionLocator)
        #expect(vm.selectedArticleId == video.id)
        #expect(vm.selectedArticleIds == [video.id])
    }

    @Test("destructive removal runs after the Undo window expires")
    func removalCommitsAfterGracePeriod() async throws {
        let vm = makeViewModel()
        vm.deletionGracePeriod = .milliseconds(1)
        var paper = makeArticle(
            url: "https://arxiv.org/abs/1706.03762",
            title: "Attention Is All You Need",
            sourceType: .paper
        )
        _ = try await vm.storage.insertSourceIfNew(&paper)
        vm.articles = try await vm.storage.loadActiveSources()

        await vm.removeSelected([paper.id])
        try await Task.sleep(for: .milliseconds(25))

        #expect(vm.pendingDeletionNotices.isEmpty)
        #expect(try await vm.storage.loadSources().contains { $0.id == paper.id } == false)
        #expect(vm.articles.contains { $0.id == paper.id } == false)
    }
}

// MARK: - removeBookGroup

@Suite("removeBookGroup")
@MainActor
struct RemoveBookGroupTests {

    @Test("hides all articles with matching parentGroup")
    func hidesMatchingGroup() async {
        let vm = makeViewModel()
        let b1 = makeArticle(url: "/books/ch1.pdf", title: "Ch 1", sourceType: .book, parentGroup: "MyBook")
        let b2 = makeArticle(url: "/books/ch2.pdf", title: "Ch 2", sourceType: .book, parentGroup: "MyBook")
        let other = makeArticle(url: "https://a.com", title: "A", sourceType: .article)
        try? await vm.storage.saveSource(b1)
        try? await vm.storage.saveSource(b2)
        try? await vm.storage.saveSource(other)
        vm.articles = [b1, b2, other]

        await vm.removeBookGroup("MyBook", deleteFiles: false)

        #expect(vm.articles.count == 3)
        #expect(vm.articles.first(where: { $0.id == b1.id })?.isHidden == true)
        #expect(vm.articles.first(where: { $0.id == b2.id })?.isHidden == true)
        #expect(vm.articles.filter { !vm.isSourceHidden($0) }.map(\.id) == [other.id])
    }

    @Test("does not affect articles in different group")
    func doesNotAffectDifferentGroup() async {
        let vm = makeViewModel()
        let b1 = makeArticle(url: "/books/ch1.pdf", title: "Ch 1", sourceType: .book, parentGroup: "BookA")
        let b2 = makeArticle(url: "/books/ch2.pdf", title: "Ch 2", sourceType: .book, parentGroup: "BookB")
        try? await vm.storage.saveSource(b1)
        try? await vm.storage.saveSource(b2)
        vm.articles = [b1, b2]

        await vm.removeBookGroup("BookA", deleteFiles: false)

        #expect(vm.articles.count == 2)
        #expect(vm.articles.first(where: { $0.id == b1.id })?.isHidden == true)
        #expect(vm.articles.filter { !vm.isSourceHidden($0) }.map(\.id) == [b2.id])
    }

    @Test("updates selectedArticleId when removed article was selected")
    func updatesSelectionWhenRemoved() async {
        let vm = makeViewModel()
        let b1 = makeArticle(url: "/books/ch1.pdf", title: "Ch 1", sourceType: .book, parentGroup: "MyBook")
        let other = makeArticle(url: "https://a.com", title: "A", sourceType: .article)
        try? await vm.storage.saveSource(b1)
        try? await vm.storage.saveSource(other)
        vm.articles = [b1, other]
        vm.selectedArticleId = b1.id

        await vm.removeBookGroup("MyBook", deleteFiles: false)

        #expect(vm.articles.count == 2)
        #expect(vm.articles.first(where: { $0.id == b1.id })?.isHidden == true)
        // Should fall back to a remaining article
        #expect(vm.selectedArticleId == other.id)
    }
}

// MARK: - removeArticleFromCourse

@Suite("removeArticleFromCourse")
@MainActor
struct RemoveArticleFromCourseTests {

    @Test("clears parentGroup for article type")
    func clearsParentGroupForArticle() async {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://a.com", title: "A", sourceType: .article, parentGroup: "CS101")
        vm.articles = [a]
        // Course groups now exist only via course metadata/lectures, not via
        // article parentGroup values alone (commit 0fb9c76b).
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")

        await vm.removeArticleFromCourse(articleId: a.id)

        #expect(vm.articles[0].parentGroup == nil)
    }

    @Test("does NOT clear parentGroup for .course sourceType")
    func doesNotClearForCourse() async {
        let vm = makeViewModel()
        let a = makeArticle(url: "/courses/lecture.pdf", title: "Lecture", sourceType: .course, parentGroup: "CS101")
        vm.articles = [a]

        await vm.removeArticleFromCourse(articleId: a.id)

        #expect(vm.articles[0].parentGroup == "CS101")
    }

    @Test("does NOT clear parentGroup for .book sourceType")
    func doesNotClearForBook() async {
        let vm = makeViewModel()
        let a = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "MyBook")
        vm.articles = [a]

        await vm.removeArticleFromCourse(articleId: a.id)

        #expect(vm.articles[0].parentGroup == "MyBook")
    }
}

// MARK: - removeCourse

@Suite("removeCourse")
@MainActor
struct RemoveCourseTests {

    @Test("stale userCourseNames do not create empty course groups")
    func staleUserCourseNamesDoNotCreateGroups() {
        let vm = makeViewModel()
        vm.userCourseNames = Set(["CS101"])

        #expect(vm.allCourseGroupNames.isEmpty)
    }

    @Test("unattached local course videos do not create empty course groups")
    func unattachedLocalCourseVideosDoNotCreateGroups() {
        let vm = makeViewModel()
        let video = makeArticle(
            url: "https://youtube.com/watch?v=1",
            title: "Lecture 1",
            sourceType: .video,
            discoveryOrigin: .localCourses
        )
        vm.articles = [video]

        #expect(vm.allCourseGroupNames.isEmpty)
    }

    @Test("attached local course videos still create their course group")
    func attachedLocalCourseVideosCreateGroup() {
        let vm = makeViewModel()
        let video = makeArticle(
            url: "https://youtube.com/watch?v=1",
            title: "Lecture 1",
            sourceType: .video,
            parentGroup: "CS101",
            discoveryOrigin: .localCourses
        )
        vm.articles = [video]
        // Course groups now exist only via course metadata/lectures, not via
        // article parentGroup values alone (commit 0fb9c76b). The attached
        // video still belongs to the group through its parentGroup.
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")

        #expect(vm.allCourseGroupNames == ["CS101"])
        #expect(vm.sourceIdsForGroup("CS101") == Set([video.id]))
    }

    @Test("course lecture items link ordinary videos to course groups")
    func lectureItemsLinkOrdinaryVideosToCourses() {
        let vm = makeViewModel()
        let video = makeArticle(
            url: "https://youtube.com/watch?v=1",
            title: "Lecture 1",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )
        let lecture = CourseSession(id: "lecture-1", courseName: "CS101", number: 1)
        let item = CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video)
        vm.articles = [video]
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")
        vm.courseLecturesByCourse["CS101"] = [lecture]
        vm.courseLectureItemsByLectureId[lecture.id] = [item]

        #expect(vm.allCourseGroupNames == ["CS101"])
        #expect(vm.sourceIdsForGroup("CS101") == Set([video.id]))
    }

    @Test("keeps stable course identity for restoration")
    func keepsCourseIdentity() async {
        let vm = makeViewModel()
        vm.userCourseNames = Set(["CS101", "Math200"])

        await vm.removeCourse(name: "CS101")

        #expect(vm.userCourseNames.contains("CS101"))
        #expect(vm.userCourseNames.contains("Math200"))
        #expect(vm.courseMetadata["CS101"]?.isHidden == true)
    }

    @Test("preserves course source membership")
    func preservesCourseSources() async {
        let vm = makeViewModel()
        vm.userCourseNames = Set(["CS101"])
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")
        let coursePdf = makeArticle(url: "/courses/slides.pdf", title: "Slides", sourceType: .course, parentGroup: "CS101")
        let otherArticle = makeArticle(url: "https://a.com", title: "Unrelated")
        vm.articles = [coursePdf, otherArticle]

        await vm.removeCourse(name: "CS101")

        #expect(vm.articles.first(where: { $0.id == coursePdf.id })?.parentGroup == "CS101")
        #expect(vm.articles.contains(where: { $0.id == otherArticle.id }))
        #expect(vm.courseMetadata["CS101"]?.isHidden == true)
    }

    @Test("preserves non-course sources assigned to course")
    func preservesNonCourseSourcesAssignedToCourse() async {
        let vm = makeViewModel()
        vm.userCourseNames = Set(["CS101"])
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")
        let coursePdf = makeArticle(url: "/courses/slides.pdf", title: "Slides", sourceType: .course, parentGroup: "CS101")
        let linkedArticle = makeArticle(url: "https://a.com", title: "Related Reading", sourceType: .article, parentGroup: "CS101")
        let otherArticle = makeArticle(url: "https://b.com", title: "Unrelated")
        vm.articles = [coursePdf, linkedArticle, otherArticle]

        await vm.removeCourse(name: "CS101")

        #expect(vm.articles.first(where: { $0.id == linkedArticle.id })?.parentGroup == "CS101")
        #expect(vm.articles.first(where: { $0.id == coursePdf.id })?.parentGroup == "CS101")
        #expect(vm.articles.contains(where: { $0.id == otherArticle.id }))
    }

    @Test("preserves sources linked through course lecture items")
    func preservesSourcesLinkedThroughLectureItems() async {
        let vm = makeViewModel()
        vm.userCourseNames = Set(["CS101"])
        let linkedVideo = makeArticle(url: "https://youtube.com/watch?v=1", title: "Lecture 1", sourceType: .video)
        let otherArticle = makeArticle(url: "https://b.com", title: "Unrelated")
        let lecture = CourseSession(id: "lecture-1", courseName: "CS101", number: 1)
        let item = CourseLectureItem(lectureId: lecture.id, sourceId: linkedVideo.id, role: .video)
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")
        vm.courseLecturesByCourse["CS101"] = [lecture]
        vm.courseLectureItemsByLectureId[lecture.id] = [item]
        vm.articles = [linkedVideo, otherArticle]

        await vm.removeCourse(name: "CS101")

        #expect(vm.articles.contains(where: { $0.id == linkedVideo.id }))
        #expect(vm.articles.contains(where: { $0.id == otherArticle.id }))
        #expect(vm.courseLecturesByCourse["CS101"] == [lecture])
        #expect(vm.courseLectureItemsByLectureId[lecture.id] == [item])
        #expect(vm.courseMetadata["CS101"]?.isHidden == true)
    }

    @Test("moves selection away from a course pending removal")
    func movesSelectionWhileCourseIsPendingRemoval() async {
        let vm = makeViewModel()
        vm.userCourseNames = Set(["CS101"])
        let linkedArticle = makeArticle(url: "https://a.com", title: "Related Reading", sourceType: .article, parentGroup: "CS101")
        let otherArticle = makeArticle(url: "https://b.com", title: "Unrelated")
        vm.articles = [linkedArticle, otherArticle]
        vm.selectedArticleId = linkedArticle.id

        await vm.removeCourse(name: "CS101")

        #expect(vm.selectedArticleId == otherArticle.id)
        #expect(vm.currentCardIndex == 0)
    }

    @Test("Undo restores a course before any structure or watch progress is deleted")
    func undoRestoresCourseExactly() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseProgressRemovalTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        vm.userCourseNames = Set(["CS101"])
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")
        try await service.saveCourseGroup(
            name: "CS101",
            metadata: CourseMetadata(title: "CS101")
        )

        var linkedVideo = makeArticle(
            url: "https://youtube.com/watch?v=1",
            title: "Lecture 1",
            sourceType: .video,
            parentGroup: "CS101"
        )
        linkedVideo.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 850,
            watchedSeconds: 850,
            durationSeconds: 900
        ).encoded
        _ = try await service.insertSourceIfNew(&linkedVideo)
        let lecture = CourseSession(id: "lecture-1", courseName: "CS101", number: 1, title: "Lecture 1")
        let item = CourseLectureItem(id: "item-1", lectureId: lecture.id, sourceId: linkedVideo.id, role: .video)
        try await service.saveCourseLecture(lecture)
        try await service.saveCourseLectureItem(item)
        vm.courseLecturesByCourse["CS101"] = [lecture]
        vm.courseLectureItemsByLectureId[lecture.id] = [item]
        vm.articles = try await service.loadActiveSources()

        await vm.removeCourse(name: "CS101")

        let preserved = try await service.loadSources().first(where: { $0.id == linkedVideo.id })
        #expect(preserved?.parentGroup == "CS101")
        #expect(preserved?.readingPositionLocator == linkedVideo.readingPositionLocator)
        #expect(preserved?.status == .active)
        #expect(try await service.loadCourseMetadata()["CS101"]?.isHidden == true)
        #expect(try await service.loadCourseLectures() == [lecture])
        #expect(try await service.loadCourseLectureItems() == [item])

        await vm.undoLatestDeletion()
        #expect(try await service.loadCourseMetadata()["CS101"]?.isHidden == false)
        #expect(try await service.loadCourseLectures() == [lecture])
        #expect(try await service.loadCourseLectureItems() == [item])
        let restoredSources = try await service.loadSources()
        #expect(restoredSources.first { $0.id == linkedVideo.id }?.readingPositionLocator == linkedVideo.readingPositionLocator)
        #expect(vm.pendingDeletionNotices.isEmpty)
    }

    @Test("course structure is deleted only after the Undo window expires")
    func courseRemovalCommitsAfterGracePeriod() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDeferredRemovalTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        vm.deletionGracePeriod = .milliseconds(1)
        vm.userCourseNames = ["CS101"]
        vm.courseMetadata["CS101"] = CourseMetadata(title: "CS101")
        try await service.saveCourseGroup(name: "CS101", metadata: CourseMetadata(title: "CS101"))

        var video = makeArticle(
            url: "https://youtube.com/watch?v=commit",
            title: "Lecture 1",
            sourceType: .video,
            parentGroup: "CS101"
        )
        _ = try await service.insertSourceIfNew(&video)
        let lecture = CourseSession(id: "lecture-1", courseName: "CS101", number: 1)
        let item = CourseLectureItem(id: "item-1", lectureId: lecture.id, sourceId: video.id, role: .video)
        try await service.saveCourseLecture(lecture)
        try await service.saveCourseLectureItem(item)
        vm.courseLecturesByCourse["CS101"] = [lecture]
        vm.courseLectureItemsByLectureId[lecture.id] = [item]
        vm.articles = try await service.loadActiveSources()

        await vm.removeCourse(name: "CS101")
        try await Task.sleep(for: .milliseconds(25))

        #expect(vm.pendingDeletionNotices.isEmpty)
        #expect(try await service.loadCourseMetadata()["CS101"] == nil)
        #expect(try await service.loadCourseLectures().isEmpty)
        #expect(try await service.loadCourseLectureItems().isEmpty)
        let sources = try await service.loadSources()
        let preserved = try #require(sources.first { $0.id == video.id })
        #expect(preserved.status == .active)
        #expect(preserved.parentGroup == nil)
    }
}

// MARK: - archiveUnlikedYouTubeVideos

@Suite("archiveUnlikedYouTubeVideos")
@MainActor
struct ArchiveUnlikedYouTubeVideosTests {

    @Test("selection fallback skips hidden articles")
    func selectionFallbackSkipsHiddenArticles() async {
        let vm = makeViewModel()
        let hiddenFirst = makeArticle(url: "https://a.com", title: "Hidden A")
        let visible = makeArticle(url: "https://b.com", title: "Visible B")
        let unliked = makeArticle(
            url: "https://www.youtube.com/watch?v=UNLIKEDVID1",
            title: "Unliked video",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )
        try? await vm.storage.saveSource(hiddenFirst)
        try? await vm.storage.saveSource(visible)
        try? await vm.storage.saveSource(unliked)
        vm.articles = [hiddenFirst, visible, unliked]
        await vm.removeArticle(id: hiddenFirst.id)
        vm.selectedArticleId = unliked.id

        let archivedCount = await vm.archiveUnlikedYouTubeVideos(
            likedGroupID: "liked-group",
            likedURLKeys: []
        )

        #expect(archivedCount == 1)
        #expect(vm.articles.map(\.id) == [hiddenFirst.id, visible.id])
        // The hidden row sits first in `articles`, but no sidebar tab displays
        // it — selection must land on the first visible article instead.
        #expect(vm.selectedArticleId == visible.id)
        #expect(vm.currentCardIndex == 0)
    }

    @Test("selection clears when only hidden articles remain")
    func selectionClearsWhenOnlyHiddenArticlesRemain() async {
        let vm = makeViewModel()
        let hidden = makeArticle(url: "https://a.com", title: "Hidden A")
        let unliked = makeArticle(
            url: "https://www.youtube.com/watch?v=UNLIKEDVID2",
            title: "Unliked video",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )
        try? await vm.storage.saveSource(hidden)
        try? await vm.storage.saveSource(unliked)
        vm.articles = [hidden, unliked]
        await vm.removeArticle(id: hidden.id)
        vm.selectedArticleId = unliked.id

        _ = await vm.archiveUnlikedYouTubeVideos(
            likedGroupID: "liked-group",
            likedURLKeys: []
        )

        #expect(vm.selectedArticleId == nil)
    }
}

// MARK: - sidebarRemovalTargets

/// A Books-tab row is tagged with the chapter it would resume, so the Delete
/// key and the selection menu hand chapter ids to the removal flow. The flow
/// has to read them as the book the learner selected.
@Suite("Sidebar removal targets")
@MainActor
struct SidebarRemovalTargetsTests {

    private func makeChapter(_ book: String, _ n: Int) -> StudioArticle {
        makeArticle(
            url: "file:///Books/\(book)/Chapters/ch\(n).pdf",
            title: "\(book) chapter \(n)",
            sourceType: .book,
            parentGroup: book
        )
    }

    @Test("A chapter id on the Books tab resolves to its whole book")
    func chapterResolvesToBook() {
        let vm = makeViewModel()
        let chapters = [makeChapter("Zebra Book", 1), makeChapter("Zebra Book", 2), makeChapter("Zebra Book", 3)]
        let article = makeArticle(url: "https://a.com", title: "Loose article")
        vm.articles = chapters + [article]

        let targets = vm.sidebarRemovalTargets(for: [chapters[1].id], expandingBooks: true)

        #expect(targets == StudioViewModel.SidebarRemovalTargets(bookGroups: ["Zebra Book"], sourceIDs: []))
        #expect(targets.count == 1)
    }

    @Test("Several chapters of one book are one book; several books sort by display name")
    func chaptersCollapseAndBooksSort() {
        let vm = makeViewModel()
        let zebra = [makeChapter("Zebra Book", 1), makeChapter("Zebra Book", 2)]
        let apple = [makeChapter("Apple Book", 1)]
        vm.articles = zebra + apple

        let targets = vm.sidebarRemovalTargets(
            for: Set((zebra + apple).map(\.id)),
            expandingBooks: true
        )

        #expect(targets.bookGroups == ["Apple Book", "Zebra Book"])
        #expect(targets.sourceIDs.isEmpty)
        #expect(targets.count == 2)
    }

    @Test("A loose source beside a book stays a source, in title order")
    func mixedSelectionKeepsLooseSources() {
        let vm = makeViewModel()
        let chapter = makeChapter("Zebra Book", 1)
        let b = makeArticle(url: "https://b.com", title: "Beta")
        let a = makeArticle(url: "https://a.com", title: "Alpha")
        vm.articles = [chapter, b, a]

        let targets = vm.sidebarRemovalTargets(for: [chapter.id, a.id, b.id], expandingBooks: true)

        #expect(targets.bookGroups == ["Zebra Book"])
        #expect(targets.sourceIDs == [a.id, b.id])
        #expect(targets.count == 3)
    }

    @Test("Off the Books tab a chapter is just a source, and unknown ids drop out")
    func chapterStaysSourceElsewhere() {
        let vm = makeViewModel()
        let chapter = makeChapter("Zebra Book", 1)
        vm.articles = [chapter]

        let targets = vm.sidebarRemovalTargets(for: [chapter.id, "missing"], expandingBooks: false)

        #expect(targets.bookGroups.isEmpty)
        #expect(targets.sourceIDs == [chapter.id])
        #expect(vm.sidebarRemovalTargets(for: ["missing"], expandingBooks: true).isEmpty)
    }

    @Test("Hiding the targets hides every chapter of the book and the loose source, nothing else")
    func hideTargetsHidesWholeBook() async {
        let vm = makeViewModel()
        let zebra = [makeChapter("Zebra Book", 1), makeChapter("Zebra Book", 2)]
        let apple = [makeChapter("Apple Book", 1)]
        let article = makeArticle(url: "https://a.com", title: "Loose article")
        let kept = makeArticle(url: "https://kept.com", title: "Kept")
        for source in zebra + apple + [article, kept] {
            try? await vm.storage.saveSource(source)
        }
        vm.articles = zebra + apple + [article, kept]

        let targets = vm.sidebarRemovalTargets(for: [zebra[0].id, article.id], expandingBooks: true)
        await vm.hideSidebarRemovalTargets(targets)

        let hidden = Set(vm.articles.filter(\.isHidden).map(\.id))
        #expect(hidden == Set(zebra.map(\.id) + [article.id]))
        #expect(vm.articles.first(where: { $0.id == apple[0].id })?.isHidden == false)
        #expect(vm.articles.first(where: { $0.id == kept.id })?.isHidden == false)
    }

    @Test("Removing the targets takes every chapter of the book into the undo window")
    func removeTargetsRemovesWholeBook() async {
        let vm = makeViewModel()
        let zebra = [makeChapter("Zebra Book", 1), makeChapter("Zebra Book", 2)]
        let apple = [makeChapter("Apple Book", 1)]
        for source in zebra + apple {
            try? await vm.storage.saveSource(source)
        }
        vm.articles = zebra + apple

        let targets = vm.sidebarRemovalTargets(for: [zebra[1].id], expandingBooks: true)
        await vm.removeSidebarRemovalTargets(targets)

        #expect(vm.hasPendingDeletion(forDeletionKey: "book:Zebra Book"))
        for chapter in zebra {
            #expect(vm.articles.first(where: { $0.id == chapter.id })?.isHidden == true)
        }
        #expect(vm.articles.first(where: { $0.id == apple[0].id })?.isHidden == false)
        #expect(!vm.hasPendingDeletion(forDeletionKey: "book:Apple Book"))
    }
}

// MARK: - hideSources

@Suite("hideSources")
@MainActor
struct HideSourcesTests {

    @Test("Hides every listed source of any type in one gesture and leaves the rest")
    func hidesSelectionAcrossTypes() async {
        let vm = makeViewModel()
        let episode = makeArticle(url: "https://pod.example/ep1", title: "Episode", sourceType: .podcast)
        let paper = makeArticle(url: "https://doi.org/10.1/x", title: "Paper", sourceType: .paper)
        let article = makeArticle(url: "https://a.com", title: "Article")
        let kept = makeArticle(url: "https://kept.com", title: "Kept")
        for source in [episode, paper, article, kept] {
            try? await vm.storage.saveSource(source)
        }
        vm.articles = [episode, paper, article, kept]
        vm.selectedArticleId = paper.id

        await vm.hideSources([episode.id, paper.id, article.id, "missing"])

        let hidden = Set(vm.articles.filter(\.isHidden).map(\.id))
        #expect(hidden == Set([episode.id, paper.id, article.id]))
        #expect(vm.articles.first(where: { $0.id == kept.id })?.isHidden == false)
        #expect(vm.selectedArticleId == nil)
        #expect(vm.toastMessage == "Hid 3 sources")

        let stored = try? await vm.storage.loadSources()
        #expect(stored?.first(where: { $0.id == episode.id })?.isHidden == true)
        #expect(stored?.first(where: { $0.id == kept.id })?.isHidden == false)
    }

    @Test("A single id takes the single-source path and names the source")
    func singleSourceNamesTitle() async {
        let vm = makeViewModel()
        let episode = makeArticle(url: "https://pod.example/ep1", title: "Episode", sourceType: .podcast)
        try? await vm.storage.saveSource(episode)
        vm.articles = [episode]

        await vm.hideSources([episode.id])

        #expect(vm.articles.first?.isHidden == true)
        #expect(vm.toastMessage == "Hid Episode")
    }

    /// The product owner, 2026-09-18: "when i hide a paper and i get a popup message;
    /// that popup needs to allow me to undo it." The toast that reports the
    /// hide carries the Undo, and taking it restores the row and the store.
    @Test("Hiding a paper offers Undo on its toast, and Undo brings the paper back")
    func hidingOfferedUndoRestoresPaper() async {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://doi.org/10.1/x", title: "Paper", sourceType: .paper)
        try? await vm.storage.saveSource(paper)
        vm.articles = [paper]

        await vm.setSourceHidden(paper.id, hidden: true)
        #expect(vm.toastMessage == "Hid Paper")
        #expect(vm.toastUndo != nil)

        await vm.undoToast()

        #expect(vm.articles.first?.isHidden == false)
        #expect(vm.toastMessage == "Unhid Paper")
        #expect(vm.toastUndo == nil, "Unhiding is not itself offered for undo")
        let stored = try? await vm.storage.loadSources()
        #expect(stored?.first(where: { $0.id == paper.id })?.isHidden == false)
    }

    @Test("Hiding several sources offers one Undo that restores them all")
    func batchHideUndoRestoresAll() async {
        let vm = makeViewModel()
        let episode = makeArticle(url: "https://pod.example/ep1", title: "Episode", sourceType: .podcast)
        let paper = makeArticle(url: "https://doi.org/10.1/x", title: "Paper", sourceType: .paper)
        let kept = makeArticle(url: "https://kept.com", title: "Kept")
        for source in [episode, paper, kept] {
            try? await vm.storage.saveSource(source)
        }
        vm.articles = [episode, paper, kept]

        await vm.hideSources([episode.id, paper.id])
        #expect(vm.toastMessage == "Hid 2 sources")
        #expect(vm.toastUndo != nil)

        await vm.undoToast()

        #expect(vm.articles.allSatisfy { !$0.isHidden })
        #expect(vm.toastMessage == "Unhid 2 sources")
        let stored = try? await vm.storage.loadSources()
        #expect(stored?.allSatisfy { !$0.isHidden } == true)
    }
}

// MARK: - Knowledge inclusion

/// Hiding one source is visual only; hiding a whole show or channel mutes
/// its episodes for chat, search and reviews as well, unless one is unhidden.
@Suite("Knowledge inclusion and hiding")
@MainActor
struct KnowledgeInclusionHidingTests {

    @Test("A source hidden by itself stays in knowledge")
    func hiddenSourceStaysInKnowledge() async {
        let vm = makeViewModel()
        var episode = makeArticle(url: "https://pod.example/ep", title: "Episode", sourceType: .podcast)
        episode.domain = "Open Show"
        let paper = makeArticle(url: "https://doi.org/10.1/x", title: "Paper", sourceType: .paper)
        try? await vm.storage.saveSource(episode)
        try? await vm.storage.saveSource(paper)
        vm.articles = [episode, paper]

        await vm.hideSources([episode.id, paper.id])

        #expect(vm.articles.allSatisfy { $0.isHidden })
        #expect(vm.isSourceIncludedInKnowledge(vm.articles[0]))
        #expect(vm.isSourceIncludedInKnowledge(vm.articles[1]))
        #expect(!vm.isSourceCollectionHidden(vm.articles[0]))
    }

    @Test("An episode of a hidden show leaves knowledge until it is unhidden on its own")
    func hiddenShowMutesEpisodesExceptOverrides() {
        let vm = makeViewModel()
        var muted = makeArticle(url: "https://pod.example/1", title: "Muted", sourceType: .podcast)
        muted.domain = "Muted Show"
        var unhidden = makeArticle(url: "https://pod.example/2", title: "Unhidden", sourceType: .podcast)
        unhidden.domain = "Muted Show"
        var other = makeArticle(url: "https://pod.example/3", title: "Other show", sourceType: .podcast)
        other.domain = "Open Show"
        vm.articles = [muted, unhidden, other]
        vm.hiddenPodcastShows = ["Muted Show"]
        vm.visiblePodcastEpisodeOverrideIDs = [unhidden.id]

        #expect(vm.isSourceCollectionHidden(muted))
        #expect(!vm.isSourceIncludedInKnowledge(muted))
        #expect(vm.isSourceHidden(muted))

        #expect(!vm.isSourceCollectionHidden(unhidden))
        #expect(vm.isSourceIncludedInKnowledge(unhidden))
        #expect(!vm.isSourceHidden(unhidden))

        #expect(vm.isSourceIncludedInKnowledge(other))
    }
}

// MARK: - Hidden items while a removal is pending

/// A removal hides first and deletes when the Undo banner expires. For those
/// seconds the source or group is hidden in every store, but it is being
/// removed, not kept out of sight: the hidden-items footer must not count it.
/// A deleted meeting folder used to spend the window as "1 hidden meeting
/// group" at the foot of the Meetings list (product owner, 2026-09-20).
@Suite("Hidden items while a removal is pending")
@MainActor
struct HiddenItemsDuringRemovalTests {

    @Test("a source inside its removal's Undo window is not a hidden item")
    func removedSourceIsNotCountedAsHidden() async {
        let vm = makeViewModel()
        vm.deletionGracePeriod = .seconds(60)
        let kept = makeArticle(url: "https://a.com", title: "Kept")
        let removed = makeArticle(url: "https://b.com", title: "Removed")
        let hidden = makeArticle(url: "https://c.com", title: "Hidden")
        for article in [kept, removed, hidden] { try? await vm.storage.saveSource(article) }
        vm.articles = [kept, removed, hidden]
        await vm.setSourceHidden(hidden.id, hidden: true)
        #expect(vm.hiddenSourceArticles(for: .articles).map(\.id) == [hidden.id])

        await vm.removeSelected([removed.id])

        // Off the sidebar, on its way out, and not a hidden item.
        #expect(vm.articles.first(where: { $0.id == removed.id })?.isHidden == true)
        #expect(vm.isSourceBeingRemoved(removed.id))
        #expect(vm.hiddenSourceArticles(for: .articles).map(\.id) == [hidden.id])
        #expect(HiddenItemsModel.footerCounts(for: .articles, vm: vm) == (0, 1))

        await vm.undoLatestDeletion()

        #expect(vm.articles.first(where: { $0.id == removed.id })?.isHidden == false)
        #expect(!vm.isSourceBeingRemoved(removed.id))
        #expect(vm.hiddenSourceArticles(for: .articles).map(\.id) == [hidden.id])
    }

    @Test("a source stays out of the hidden items through its deletion")
    func removedSourceStaysOutThroughDeletion() async throws {
        let vm = makeViewModel()
        vm.deletionGracePeriod = .milliseconds(20)
        let removed = makeArticle(url: "https://b.com", title: "Removed")
        try? await vm.storage.saveSource(removed)
        vm.articles = [removed]

        await vm.removeSelected([removed.id])
        #expect(vm.hiddenSourceArticles(for: .articles).isEmpty)

        // The window closes and the commit takes the row out of the library.
        for _ in 0..<200 where vm.articles.contains(where: { $0.id == removed.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!vm.articles.contains(where: { $0.id == removed.id }))
        #expect(!vm.hasPendingDeletion(forSourceID: removed.id))
        #expect(vm.hiddenSourceArticles(for: .articles).isEmpty)
    }

    @Test("a meeting series inside its removal's Undo window is not a hidden group")
    func removedMeetingGroupIsNotCountedAsHidden() async {
        // removeMeetingGroup records a removal tombstone in UserDefaults; leave
        // the learner's list as it was.
        let identityKey = StudioViewModel.removedMeetingGroupIdentitiesKey
        let titleKey = StudioViewModel.removedMeetingGroupTitlesKey
        let priorIdentities = UserDefaults.standard.stringArray(forKey: identityKey)
        let priorTitles = UserDefaults.standard.stringArray(forKey: titleKey)
        defer {
            if let priorIdentities {
                UserDefaults.standard.set(priorIdentities, forKey: identityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: identityKey)
            }
            if let priorTitles {
                UserDefaults.standard.set(priorTitles, forKey: titleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: titleKey)
            }
        }

        let vm = makeViewModel()
        vm.deletionGracePeriod = .seconds(60)
        let removedID = "series-\(UUID().uuidString)"
        let hiddenID = "series-\(UUID().uuidString)"
        vm.meetingMetadata = [
            removedID: MeetingMetadata(title: "Comp Bio Reading Group"),
            hiddenID: MeetingMetadata(title: "Hidden Series", isHidden: true),
        ]
        let session = makeArticle(
            url: "https://drive.google.com/file/d/session",
            title: "Session",
            sourceType: .meeting,
            parentGroup: removedID
        )
        try? await vm.storage.saveSource(session)
        vm.articles = [session]
        #expect(vm.visibleMeetingGroupNames == [removedID])
        #expect(vm.hiddenMeetingGroupNames == [hiddenID])

        await vm.removeMeetingGroup(name: removedID)

        // Gone from the list, and the footer still counts only the series the
        // learner hid.
        #expect(vm.visibleMeetingGroupNames.isEmpty)
        #expect(vm.meetingMetadata[removedID]?.isHidden == true)
        #expect(vm.hiddenMeetingGroupNames == [hiddenID])
        #expect(HiddenItemsModel.footerCounts(for: .meetings, vm: vm) == (1, 0))
        #expect(vm.pendingDeletionNotices.last?.message == "Removed “Comp Bio Reading Group”")

        await vm.undoLatestDeletion()

        #expect(vm.visibleMeetingGroupNames == [removedID])
        #expect(vm.hiddenMeetingGroupNames == [hiddenID])
    }
}

// MARK: - Courses home list

/// Set from `withObservationTracking`'s Sendable onChange.
private final class RedrawFlag: @unchecked Sendable {
    var fired = false
}

@Suite("Courses home list")
@MainActor
struct CoursesHomeListTests {

    /// The course-name caches are observation-ignored. A Courses home drawn
    /// from a cache another reader filled before the courses loaded must still
    /// hear the load, or it keeps "No courses yet." (2026-09-28).
    @Test("a list served from the cache redraws when the courses load")
    func cachedListRedrawsWhenCoursesLoad() {
        let vm = makeViewModel()
        _ = vm.allCourseGroupNames
        let redraw = RedrawFlag()
        let shown = withObservationTracking { vm.visibleCourseGroupNames } onChange: { redraw.fired = true }
        #expect(shown.isEmpty)

        vm.courseMetadata = ["CS101": CourseMetadata(title: "CS101")]

        #expect(redraw.fired)
        #expect(vm.visibleCourseGroupNames == ["CS101"])
    }

    @Test("a list served from the cache redraws when a course is hidden")
    func cachedListRedrawsWhenCourseHidden() {
        let vm = makeViewModel()
        vm.courseMetadata = [
            "CS101": CourseMetadata(title: "CS101"),
            "Math200": CourseMetadata(title: "Math200"),
        ]
        _ = vm.visibleCourseGroupNames
        let redraw = RedrawFlag()
        let shown = withObservationTracking { vm.visibleCourseGroupNames } onChange: { redraw.fired = true }
        #expect(Set(shown) == ["CS101", "Math200"])

        vm.courseMetadata["CS101"]?.isHidden = true

        #expect(redraw.fired)
        #expect(vm.visibleCourseGroupNames == ["Math200"])
    }
}
