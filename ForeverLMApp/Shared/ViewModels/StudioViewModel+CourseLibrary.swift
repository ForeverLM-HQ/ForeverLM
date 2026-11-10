// Adding sources to courses, and creating, organizing and describing courses.

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

    /// Add an article to a course by attaching it to the first lecture. This
    /// preserves the source's primary library home instead of moving parentGroup.
    func addArticleToCourse(articleId: String, courseName: String) async {
        guard let article = articles.first(where: { $0.id == articleId }),
              let lecture = await matchingOrFirstLecture(in: courseName, for: article) else { return }
        await addArticleToLecture(articleId: articleId, lectureId: lecture.id)
    }

    /// Whether the lecture holds the source afterwards. A failed write is
    /// shown and leaves the lecture as it was stored.
    @discardableResult
    func addArticleToLecture(articleId: String, lectureId: String, sortIndex: Int? = nil) async -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }),
              let lecture = courseLecturesByCourse.values.flatMap({ $0 }).first(where: { $0.id == lectureId }) else { return false }
        if (courseLectureItemsByLectureId[lectureId] ?? []).contains(where: { $0.sourceId == articleId }) { return true }
        let items = courseLectureItemsByLectureId[lectureId] ?? []
        let item = CourseLectureItem(
            lectureId: lectureId,
            sourceId: articleId,
            role: inferredLectureItemRole(for: article),
            sortIndex: sortIndex ?? (items.map(\.sortIndex).max() ?? -1) + 1
        )
        userCourseNames.insert(lecture.courseName)
        saveUserCourseNames()
        do {
            let notebookSourcesAdded = try await storage.saveCourseLectureItem(item)
            var stored = courseLectureItemsByLectureId[lectureId] ?? []
            stored.append(item)
            courseLectureItemsByLectureId[lectureId] = stored.sorted { $0.sortIndex < $1.sortIndex }
            if notebookSourcesAdded > 0 {
                await loadLearningGoals()
            }
            return true
        } catch {
            logger.error("Failed to attach source to lecture: \(error.localizedDescription)")
            showToast("Could not add “\(article.title)” to the lecture: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove an article from course lectures.
    ///
    /// Each lecture lets the source go as the store deletes its item, and the
    /// source leaves the course's folder once its row is saved. A failure is
    /// shown and stops there, so what the course shows is what it stores.
    func removeArticleFromCourse(articleId: String) async {
        for (lectureId, items) in courseLectureItemsByLectureId {
            for item in items where item.sourceId == articleId {
                do {
                    try await storage.deleteCourseLectureItem(item.id)
                } catch {
                    logger.error("Could not take source \(articleId, privacy: .public) out of lecture \(lectureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    showToast("Could not remove it from the course: \(error.localizedDescription)")
                    return
                }
                courseLectureItemsByLectureId[lectureId]?.removeAll { $0.id == item.id }
            }
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType != .course,
              articles[idx].sourceType != .book else { return }
        if let group = articles[idx].parentGroup, allCourseGroupNames.contains(group) {
            var removed = articles[idx]
            removed.parentGroup = nil
            guard await persistSource(removed, context: "Remove from the course") else { return }
            mutateArticle(id: articleId) { $0.parentGroup = nil }
        }
    }

    func removeLectureItem(_ itemId: String) async {
        do {
            try await storage.deleteCourseLectureItem(itemId)
            for lectureId in courseLectureItemsByLectureId.keys {
                courseLectureItemsByLectureId[lectureId]?.removeAll { $0.id == itemId }
            }
        } catch {
            logger.error("Failed to remove lecture material: \(error.localizedDescription)")
        }
    }

    /// Create an empty course collection.
    func createCourse(name: String, metadata: CourseMetadata = CourseMetadata()) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !courseMetadata.values.contains(where: { ($0.title ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            errorMessage = "A course named \"\(trimmed)\" already exists."
            return
        }
        let courseID = UUID().uuidString
        var metadata = metadata
        if metadata.title == nil {
            metadata.title = trimmed
        }
        userCourseNames.insert(courseID)
        saveUserCourseNames()
        courseMetadata[courseID] = metadata
        do {
            try await storage.saveCourseGroup(name: courseID, metadata: metadata)
        } catch {
            logger.error("Failed to persist course group '\(trimmed)': \(error.localizedDescription)")
        }
        courseMetadata[courseID] = metadata
    }

    /// Hide a course immediately, then delete its structure after the shared
    /// Undo grace period. Sources remain in the library after final deletion.
    func removeCourse(name: String) async {
        guard !hasPendingDeletion(forDeletionKey: Self.courseRemovalKey(name)) else { return }
        let title = courseDisplayName(name)
        let originalMetadata = courseMetadata[name] ?? CourseMetadata(title: title)
        var hiddenMetadata = originalMetadata
        hiddenMetadata.isHidden = true
        let sourceIDs = sourceIdsForGroup(name)
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds

        do {
            try await storage.saveCourseGroup(name: name, metadata: hiddenMetadata)
        } catch {
            logger.error("Failed to remove course group '\(name)': \(error.localizedDescription)")
            errorMessage = "Could not remove \(title): \(error.localizedDescription)"
            return
        }
        courseMetadata[name] = hiddenMetadata
        userCourseNames.insert(name)
        saveUserCourseNames()
        deselectSourcesInEveryWindow(sourceIDs)
        if let selectedArticleId, sourceIDs.contains(selectedArticleId) {
            self.selectedArticleId = articles.first(where: {
                !sourceIDs.contains($0.id) && !isSourceHidden($0)
            })?.id
            currentCardIndex = 0
        }

        deferDeletion(
            message: "Removed “\(title)”",
            sourceIDs: sourceIDs,
            deletionKey: Self.courseRemovalKey(name),
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.saveCourseGroup(name: name, metadata: originalMetadata)
                    self.courseMetadata[name] = originalMetadata
                    self.userCourseNames.insert(name)
                    self.saveUserCourseNames()
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } catch {
                    self.logger.error("Failed to undo course removal '\(name)': \(error.localizedDescription)")
                    self.showToast("Undo failed for “\(title)”: \(error.localizedDescription)")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                let hiddenSourceIDs: [String]
                do {
                    hiddenSourceIDs = try await self.storage.deleteCourseGroup(name: name)
                } catch {
                    try? await self.storage.saveCourseGroup(name: name, metadata: originalMetadata)
                    self.courseMetadata[name] = originalMetadata
                    self.logger.error("Failed to finalize course removal '\(name)': \(error.localizedDescription)")
                    self.showToast("Removing “\(title)” failed: \(error.localizedDescription)")
                    return
                }

                self.userCourseNames.remove(name)
                self.saveUserCourseNames()
                self.courseMetadata[name] = nil
                if let lectures = self.courseLecturesByCourse.removeValue(forKey: name) {
                    for lecture in lectures {
                        self.courseLectureItemsByLectureId[lecture.id] = nil
                    }
                }
                for index in self.articles.indices where self.articles[index].parentGroup == name {
                    self.articles[index].parentGroup = nil
                }
                // Course material the deleted course was the only home for is
                // hidden with it, and the sidebar's hidden menu is where it
                // can be brought back from.
                let hidden = Set(hiddenSourceIDs)
                for index in self.articles.indices where hidden.contains(self.articles[index].id) {
                    self.articles[index].isHidden = true
                }
            }
        )
    }

    /// Organize items in a course: the Course Ordering model orders them when
    /// one is set up, and a natural title sort ("Chapter 1", "Lecture 2a")
    /// does when none is. A model call that fails is shown and changes
    /// nothing: the learner's order is never swapped for a title sort they
    /// did not ask for.
    func organizeCourse(name: String) async {
        let orderConfig = KeychainService.resolveConfig(for: .courseOrdering)
        let aiService = self.aiService
        await organizeCourse(
            name: name,
            modelOrder: orderConfig.map { config in
                { items in try await aiService.organizeCourse(items: items, courseName: name, config: config) }
            }
        )
    }

    /// `organizeCourse(name:)` with its model call handed in; nil orders by
    /// title. The new order is stored first and shown after, so a failed
    /// write leaves the course as it was too.
    func organizeCourse(
        name: String,
        modelOrder: ((_ items: [(id: String, title: String)]) async throws -> [String])?
    ) async {
        guard !organizingCourseNames.contains(name) else { return }
        organizingCourseNames.insert(name)
        defer { organizingCourseNames.remove(name) }

        let courseItems = courseArticles(for: name)
        guard courseItems.count >= 2 else {
            logger.warning("[Organize] Course '\(name)' has \(courseItems.count) items (need ≥2)")
            return
        }

        logger.info("[Organize] Organizing '\(name)' with \(courseItems.count) items")

        let orderedIds: [String]
        if let modelOrder {
            do {
                orderedIds = try await modelOrder(courseItems.map { (id: $0.id, title: $0.title) })
            } catch {
                logger.error("[Organize] Course ordering failed for '\(name)': \(error.localizedDescription)")
                showToast("Could not organize \(courseDisplayName(name)): \(error.localizedDescription)")
                return
            }
        } else {
            orderedIds = courseItems.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }.map(\.id)
        }

        let ordering: [(String, Int)] = orderedIds.enumerated().compactMap { index, id in
            articles.contains(where: { $0.id == id }) ? (id, index) : nil
        }
        logger.info("[Organize] Applying sort order: \(ordering.count)/\(orderedIds.count) IDs matched")
        do {
            try await storage.updateCourseSortOrder(ordering)
        } catch {
            logger.error("[Organize] Could not save the order of '\(name)': \(error.localizedDescription)")
            showToast("Could not save the order of \(courseDisplayName(name)): \(error.localizedDescription)")
            return
        }
        for (id, index) in ordering {
            mutateArticle(id: id) { $0.courseSortIndex = index }
        }
        await refreshArticles()
    }

    func saveUserCourseNames() {
        PreferenceStore.set(Array(userCourseNames), forKey: "userCourseNames")
    }

    func courseDisplayName(_ groupName: String) -> String {
        courseMetadata[groupName]?.title ?? groupName
    }

    func existingCourseID(forTitle title: String) -> String? {
        courseMetadata.first { key, metadata in
            (metadata.title ?? key).caseInsensitiveCompare(title) == .orderedSame
        }?.key
    }

    func courseID(forTitle title: String) -> String {
        existingCourseID(forTitle: title) ?? UUID().uuidString
    }

    func courseDisplaySubtitle(_ groupName: String) -> String? {
        let meta = courseMetadata[groupName]
        let parts = [meta?.courseCode, meta?.instructors, meta?.institution].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The image a course row shows in the sidebar: the YouTube thumbnail of its
    /// first video lecture, which is the cover YouTube itself uses for the
    /// playlist. Returns nil for a course with no video lecture yet, so the row
    /// falls back to the graduation-cap glyph. The persisted outline cache is
    /// authoritative because archived lecture sources are intentionally absent
    /// from `articlesById`.
    func courseArtworkURL(_ groupName: String) -> String? {
        if let persistedArtworkURL = courseCoverArtworkURLs[groupName] {
            return persistedArtworkURL
        }
        for id in sourceIDsForGroupInOrder(groupName) {
            if let article = articlesById[id],
               let thumbnail = article.artworkURL ?? article.youtubeThumbnailURL {
                return thumbnail
            }
        }
        return nil
    }

    /// Update a single field of course metadata.
    func updateCourseMetadata(groupName: String, update: (inout CourseMetadata) -> Void) async {
        var meta = courseMetadata[groupName] ?? CourseMetadata()
        update(&meta)
        courseMetadata[groupName] = meta
        userCourseNames.insert(groupName)
        saveUserCourseNames()
        do { try await storage.saveCourseGroup(name: groupName, metadata: meta) }
        catch { logger.error("Failed to save course group: \(error.localizedDescription)") }
        courseMetadata[groupName] = meta
    }

    func setCourseHidden(_ groupName: String, hidden: Bool) async {
        if !hidden,
           await undoPendingDeletion(forDeletionKey: Self.courseRemovalKey(groupName)) {
            guard courseMetadata[groupName]?.isHidden == true else { return }
        }
        await updateCourseMetadata(groupName: groupName) { metadata in
            metadata.isHidden = hidden
        }
        showToast(
            hidden ? "Hid \(courseDisplayName(groupName))" : "Unhid \(courseDisplayName(groupName))",
            undo: hidden ? { [weak self] in await self?.setCourseHidden(groupName, hidden: false) } : nil
        )
    }

    func persistCoursePlaylist(_ playlistURL: String, for courseName: String, defaultTitle: String?) async {
        var metadata = courseMetadata[courseName] ?? CourseMetadata()
        metadata.playlistURL = playlistURL
        if metadata.title == nil, let defaultTitle {
            metadata.title = defaultTitle
        }
        courseMetadata[courseName] = metadata
        userCourseNames.insert(courseName)
        saveUserCourseNames()

        do {
            try await storage.saveCourseGroup(name: courseName, metadata: metadata)
        } catch {
            logger.error("Failed to persist playlist for course '\(courseName)': \(error.localizedDescription)")
        }
    }

}
