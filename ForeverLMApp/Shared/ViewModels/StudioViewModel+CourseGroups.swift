// Book and course group lists, their sources, and the reader selection.

import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    struct BookGroupNamesCacheKey: Equatable {
        let articlesRevision: Int
        let bookTitles: [String: String]
        let bookSubtitles: [String: String]
        let bookEditions: [String: String]
    }

    var allBookGroupNames: [String] {
        // The key reads stay observation-tracked, so callers still re-render
        // when the article list or book metadata changes; only the scan and
        // localized sort are skipped on repeat evaluation.
        let key = BookGroupNamesCacheKey(
            articlesRevision: articlesRevision,
            bookTitles: bookTitles,
            bookSubtitles: bookSubtitles,
            bookEditions: bookEditions
        )
        if allBookGroupNamesCacheKey == key, let cached = allBookGroupNamesCache {
            return cached
        }
        var names = Set<String>()
        for article in activeArticles where article.sourceType == .book {
            if let g = article.parentGroup { names.insert(g) }
        }
        // Resolve each display name once instead of per sort comparison.
        let sorted = names
            .map { (group: $0, display: bookDisplayName($0)) }
            .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
            .map(\.group)
        allBookGroupNamesCacheKey = key
        allBookGroupNamesCache = sorted
        return sorted
    }

    var visibleBookGroupNames: [String] {
        allBookGroupNames.filter { !isBookHidden($0) }
    }

    struct FilteredBookGroupNamesCacheKey: Equatable {
        let filter: SidebarFilterCacheKey
        let bookTitles: [String: String]
        let bookSubtitles: [String: String]
        let bookEditions: [String: String]
        let bookAuthors: [String: String]
        let bookKinds: [String: String]
    }

    var filteredBookGroupNames: [String] {
        // The key reads every input `bookMatchesSearch` consults, so the view
        // stays observation-tracked on a cache hit and a renamed book or a new
        // category still recomputes; only the per-book scan is skipped.
        let key = FilteredBookGroupNamesCacheKey(
            filter: currentSidebarFilterCacheKey,
            bookTitles: bookTitles,
            bookSubtitles: bookSubtitles,
            bookEditions: bookEditions,
            bookAuthors: bookAuthors,
            bookKinds: bookKinds
        )
        if sidebarStore.filteredBookGroupNamesCacheKey == key,
           let cached = sidebarStore.filteredBookGroupNamesCache {
            return cached
        }
        // Books matched on their own metadata (or a chapter's) first, then books
        // that only answer for a chapter's text. The second set arrives a debounce
        // after the first is on screen, and must not slot in between rows the
        // learner is already reading — see `computeFilteredActiveItems`.
        var metadataMatches: [String] = []
        var contentOnlyMatches: [String] = []
        for groupName in visibleBookGroupNames where bookMatchesMetadataFilters(groupName) {
            if bookMatchesSearchMetadata(groupName) {
                metadataMatches.append(groupName)
            } else if bookMatchesSearchContent(groupName) {
                contentOnlyMatches.append(groupName)
            }
        }
        let names = metadataMatches + contentOnlyMatches
        sidebarStore.filteredBookGroupNamesCache = names
        sidebarStore.filteredBookGroupNamesCacheKey = key
        return names
    }

    func bookGroupMatchesCurrentFilters(_ groupName: String) -> Bool {
        bookMatchesMetadataFilters(groupName) && bookMatchesSearch(groupName)
    }

    func bookMatchesMetadataFilters(_ groupName: String) -> Bool {
        guard let selectedBookKind else { return true }
        return bookKinds[groupName] == selectedBookKind
    }

    func bookMatchesSearch(_ groupName: String) -> Bool {
        bookMatchesSearchMetadata(groupName) || bookMatchesSearchContent(groupName)
    }

    /// The synchronous half of `bookMatchesSearch`: the book's own metadata and its
    /// chapters' metadata, which the list can answer as the learner types.
    func bookMatchesSearchMetadata(_ groupName: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsed = SidebarSearchQuery(parsing: query)
        guard !parsed.isEmpty else { return true }

        let bookMetadata = [
            groupName,
            bookDisplayName(groupName),
            bookDisplaySubtitle(groupName),
            bookDisplayAuthor(groupName),
            bookDisplayEdition(groupName),
            bookFormat(groupName),
            bookDisplayKind(groupName),
        ]
        .compactMap { $0 }

        if Self.sidebarGroupMatchesSearch(
            parsed,
            metadata: bookMetadata,
            titles: [groupName, bookDisplayName(groupName), bookDisplaySubtitle(groupName)].compactMap { $0 },
            authors: [bookDisplayAuthor(groupName)].compactMap { $0 }
        ) {
            return true
        }

        return bookSourceArticles(for: groupName).contains(where: { sourceMatchesSearch($0, query: query) })
    }

    /// The asynchronous half of `bookMatchesSearch`: the indexed pass behind the
    /// search field records chapters whose text contains every typed term, and a
    /// book answers for any chapter it owns, so a term that appears only inside a
    /// chapter still finds the book. False while no search is running — this is
    /// only ever asked after `bookMatchesSearchMetadata` said no.
    func bookMatchesSearchContent(_ groupName: String) -> Bool {
        let parsed = SidebarSearchQuery(parsing: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !parsed.isEmpty else { return false }
        // A scoped search reads metadata only; the indexed pass is cleared for it
        // and must not be consulted from a stale unscoped query.
        guard !parsed.isScoped else { return false }
        let contentMatches = sidebarStore.contentSearchMatchIDs
        guard !contentMatches.isEmpty else { return false }
        return (articlesStore.articleIDsByParentGroup[groupName] ?? [])
            .contains(where: contentMatches.contains)
    }

    func bookSourceArticles(for groupName: String) -> [StudioArticle] {
        // Read from the parent-group index rather than scanning the library. This
        // sits under every per-book question the sidebar asks — visibility, format,
        // search — and a whole-library scan per book made all of them quadratic.
        (articlesStore.articleIDsByParentGroup[groupName] ?? [])
            .compactMap { articlesById[$0] }
            .filter { $0.sourceType == .book }
    }

    func courseArticles(for courseName: String) -> [StudioArticle] {
        let ids = sourceIdsForGroup(courseName)
        return articles.filter { ids.contains($0.id) }
    }

    /// Course-owned sources that are not attached to a numbered lecture still
    /// belong in the course's Materials folder. Lecture relationships and
    /// parent-group ownership are independent, so removing a lecture item must
    /// not make its source disappear from the course UI.
    func unassignedCourseArticles(for courseName: String) -> [StudioArticle] {
        let assignedSourceIDs = Set(
            courseLectures(for: courseName).flatMap { lecture in
                courseLectureItems(for: lecture.id).compactMap(\.sourceId)
            }
        )
        return (articlesStore.articleIDsByParentGroup[courseName] ?? [])
            .compactMap { articlesById[$0] }
            .filter { !assignedSourceIDs.contains($0.id) }
            .sorted(by: learningGoalArticleOrder)
    }

    func courseLectures(for courseName: String) -> [CourseSession] {
        let lectures = courseLecturesByCourse[courseName]?.sorted { $0.number < $1.number } ?? []
        guard lectures.count > 1 else { return lectures }
        return lectures.filter { !isEmptyPlaceholderLecture($0) }
    }

    func courseLectureItems(for lectureId: String) -> [CourseLectureItem] {
        courseLectureItemsByLectureId[lectureId]?.sorted { $0.sortIndex < $1.sortIndex } ?? []
    }

    /// The papers attached to a lecture that has a video only because they are
    /// cited in it, which the course's path does not list: they open from the
    /// video's context menu the way a standalone YouTube video's papers do
    /// (product owner, 2026-09-27: "those attached papers should just be shown maybe
    /// upon right click on the video"). A paper whose item role is `reading`
    /// is assigned reading and keeps its row: "only if we deem it worth while
    /// that reading a paper is ACTUALLY necessary as assigned reading; but if
    /// it's just a citation on one of the slides, then no need to put it under
    /// a course". A lecture with no video keeps all its papers as rows, since
    /// nothing else could offer them. Paper identity is the source type.
    func lectureVideoPapers(for lectureId: String) -> [(item: CourseLectureItem, article: StudioArticle)] {
        guard lectureHasVideo(lectureId) else { return [] }
        return courseLectureItems(for: lectureId).compactMap { item in
            article(for: item).map { (item: item, article: $0) }
        }
        .filter { $0.article.sourceType == .paper && $0.item.role != .reading }
    }

    /// Whether a lecture has a video, which is what can offer its cited papers.
    func lectureHasVideo(_ lectureId: String) -> Bool {
        courseLectureItems(for: lectureId).contains { item in
            item.role == .video && article(for: item).map { $0.sourceType != .paper } == true
        }
    }

    /// Whether a paper on a lecture video's lecture is assigned reading (a row
    /// of the course's path, quizzed with the lecture) or only cited in the
    /// video (under the video's Papers menu).
    func setLectureItemRole(_ itemId: String, to role: CourseLectureItemRole) async {
        guard var item = courseLectureItemsByLectureId.values.lazy.flatMap({ $0 }).first(where: { $0.id == itemId }),
              item.role != role else { return }
        item.role = role
        do {
            _ = try await storage.saveCourseLectureItem(item)
            if let index = courseLectureItemsByLectureId[item.lectureId]?.firstIndex(where: { $0.id == itemId }) {
                courseLectureItemsByLectureId[item.lectureId]?[index] = item
            }
        } catch {
            logger.error("Failed to change lecture material role: \(error.localizedDescription)")
        }
    }

    /// The course row's completion, over the same lecture items its path
    /// lists (videos, papers, readings and materials). A lecture video's
    /// papers are not on the path, so they do not count either. Watch progress is read whatever the
    /// source's type: some playlist lectures are stored as `course` sources and
    /// still record it through the YouTube reader.
    func courseProgress(for courseName: String) -> CourseProgress {
        // Positions are unobserved; this re-renders the row when a lecture finishes.
        _ = readingProgressStore.finishedVideoRevision
        var items: [CourseProgress.Item] = []
        for lecture in courseLectures(for: courseName) {
            let videoPaperItemIDs = Set(lectureVideoPapers(for: lecture.id).map(\.item.id))
            for item in courseLectureItems(for: lecture.id) where !videoPaperItemIDs.contains(item.id) {
                guard let article = article(for: item) else { continue }
                let watched = readingProgressStore.videoWatchProgress(
                    for: article.id,
                    fallbackLocator: article.readingPositionLocator
                )?.isEssentiallyWatched == true
                items.append(CourseProgress.Item(
                    isLectureVideo: item.role == .video && article.sourceType != .paper,
                    isFinished: watched || article.isRead || sourceReviewedAt[article.id] != nil,
                    isStarted: readingProgressStore.hasProgress(for: article.id)
                        || article.hasSavedReadingPosition
                ))
            }
        }
        return CourseProgress(items: items)
    }

    func invalidateCourseDerivedState() {
        courseGroupIDsBySourceIDCache = nil
        allCourseGroupNamesCache = nil
        visibleCourseGroupNamesCache = nil
        invalidateSidebarCachesInEveryWindow()
        refreshScreenRecordShownCourses()
    }

    private func buildCourseGroupIDsBySourceID() -> [String: Set<String>] {
        let knownCourseNames = Set(courseMetadata.keys).union(courseLecturesByCourse.keys)
        var memberships: [String: Set<String>] = [:]

        for courseName in knownCourseNames {
            for sourceID in articlesStore.articleIDsByParentGroup[courseName] ?? [] {
                memberships[sourceID, default: []].insert(courseName)
            }
        }

        for (courseName, lectures) in courseLecturesByCourse {
            for lecture in lectures {
                for item in courseLectureItemsByLectureId[lecture.id] ?? [] {
                    guard let sourceID = item.sourceId else { continue }
                    memberships[sourceID, default: []].insert(courseName)
                }
            }
        }
        return memberships
    }

    func courseGroupIDs(for article: StudioArticle) -> Set<String> {
        if let cached = courseGroupIDsBySourceIDCache {
            return cached[article.id] ?? []
        }
        let memberships = buildCourseGroupIDsBySourceID()
        courseGroupIDsBySourceIDCache = memberships
        return memberships[article.id] ?? []
    }

    func article(for lectureItem: CourseLectureItem) -> StudioArticle? {
        guard let sourceId = lectureItem.sourceId else { return nil }
        return articlesById[sourceId]
    }

    func sourceIdsForGroup(_ groupName: String) -> Set<String> {
        Set(sourceIDsForGroupInOrder(groupName))
    }

    func selectBookGroup(_ groupName: String) async {
        guard let chapter = resumeBookChapter(for: groupName) else { return }
        await selectReaderSource(chapter.id)
    }

    func selectReaderSource(_ articleId: String) async {
        selectedArticleIds = [articleId]
        await selectArticle(articleId)
    }

    @discardableResult
    func selectReaderSource(matchingLocalPath path: String) async -> String? {
        guard let article = sourceMatchingLocalPath(path) else { return nil }
        await selectReaderSource(article.id)
        return article.id
    }

    func updateReadingPosition(forLocalPath path: String, page: Int) {
        guard let article = sourceMatchingLocalPath(path) else { return }
        updateReadingPosition(for: article.id, page: page)
    }

    func updateReadingLocator(forLocalPath path: String, locator: String) {
        guard let article = sourceMatchingLocalPath(path) else { return }
        updateReadingLocator(for: article.id, locator: locator)
    }

    func sourceMatchingLocalPath(_ path: String) -> StudioArticle? {
        let target = Self.standardizedReaderPath(path)
        return articles.first { article in
            // A chapter of a book kept as one file shares the book's path with
            // every other chapter, so a path names none of them.
            guard article.bookPages == nil else { return false }
            let candidates = [
                article.cachedResolvedLocalPath,
                article.localFilePath,
                article.url.hasPrefix("/") ? article.url : nil,
            ]
            .compactMap { $0 }
            return candidates.contains { Self.standardizedReaderPath($0) == target }
        }
    }

    nonisolated static func standardizedReaderPath(_ path: String) -> String {
        URL(fileURLWithPath: StorageService.absoluteSourcePath(path)).standardizedFileURL.path
    }

}
