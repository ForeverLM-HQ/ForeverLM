import Foundation
import OSLog

/// Teachable courses: a lecture link becomes a video source whose transcript
/// is the lecture's own audio, speech-to-text; a whole course becomes a
/// Course whose lectures are its video lectures, in the school's order.
///
/// The reading and the audio are `TeachableCourseService`'s; this file only
/// files what it returns into the library the way a YouTube playlist import
/// does (`StudioViewModel+Playlists`).
extension StudioViewModel {

    /// Fetch (or re-fetch) the transcript of a Teachable lecture source. The
    /// row shows Fetching while the audio downloads and transcribes, and the
    /// reason when it cannot, most often that Teachable wants a sign-in made
    /// inside ForeverLM.
    func fetchTeachableTranscript(for articleId: String, forceRefresh: Bool = false) async {
        guard !teachableTranscriptFetchInFlight.contains(articleId) else { return }
        teachableTranscriptFetchInFlight.insert(articleId)
        defer { teachableTranscriptFetchInFlight.remove(articleId) }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let urlString = articles[idx].url
        guard TeachableCourseService.isLectureURL(urlString), let url = URL(string: urlString) else {
            articles[idx].state = .error
            articles[idx].errorMessage = "Not a Teachable lecture link."
            return
        }
        articles[idx].state = .fetching
        articles[idx].errorMessage = nil

        if !forceRefresh,
           let cached = await storage.loadSourceContent(articleId),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx].content = cached
            articles[idx].wordCount = cached.split(separator: " ").count
            articles[idx].state = .ready
            try? await storage.saveSource(articles[idx])
            return
        }

        do {
            let page = try await TeachableCourseService.fetchLecturePage(url)
            if let idx = articles.firstIndex(where: { $0.id == articleId }),
               Self.titleLooksBad(articles[idx].title, domain: articles[idx].domain, url: articles[idx].url) {
                articles[idx].title = page.title
            }
            let transcript = try await TeachableCourseService.transcribe(page)
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx].content = transcript
            articles[idx].wordCount = transcript.split(separator: " ").count
            articles[idx].state = .ready
            articles[idx].errorMessage = nil
            try await storage.saveSource(articles[idx])
            logger.info("Transcribed Teachable lecture \(page.lectureID, privacy: .public)")
        } catch {
            let stopped = AITransientErrorClassifier.isCancellation(error)
            logger.warning("Teachable lecture transcript \(stopped ? "stopped" : "failed", privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx].state = .error
            articles[idx].errorMessage = stopped ? Self.teachableTranscriptStoppedMessage : error.localizedDescription
            try? await storage.saveSource(articles[idx])
        }
    }

    /// What a lecture says when its transcript was stopped before it was made.
    static let teachableTranscriptStoppedMessage = "Stopped before the transcript was made. Fetch it again to make it."

    /// Transcribes Teachable lectures one at a time, then saves them to
    /// iCloud: what the MCP tools start in the background. Stopped
    /// (`cancel_ai_work`), it ends the lecture in flight and marks the ones it
    /// never reached, so none is left looking as if it were still coming.
    func transcribeTeachableLectures(_ articleIds: [String]) async {
        for (index, articleId) in articleIds.enumerated() {
            guard !Task.isCancelled else {
                for skipped in articleIds[index...] {
                    guard let idx = articles.firstIndex(where: { $0.id == skipped }),
                          articles[idx].content == nil else { continue }
                    articles[idx].state = .error
                    articles[idx].errorMessage = Self.teachableTranscriptStoppedMessage
                    try? await storage.saveSource(articles[idx])
                }
                return
            }
            await fetchTeachableTranscript(for: articleId)
        }
        _ = await storage.syncCloudKitNowAndWaitForDrain()
    }

    /// Import a Teachable course from any of its lecture links. Every lecture
    /// in the course outline that holds a video becomes a `.video` source filed
    /// under its own lecture; lectures with only text (a CME form, a survey)
    /// are left out. Transcripts are then made one lecture at a time.
    ///
    /// `intoCourse` adds the lectures to an existing course. Without it, a
    /// course with the same title is reused rather than duplicated. Returns the
    /// course id, or nil with `errorMessage` saying why.
    ///
    /// Transcribing is minutes of download and speech-to-text per lecture, so
    /// `waitForTranscripts: false` (the MCP tool) returns once the lectures are
    /// filed and leaves the transcripts to the caller, which starts
    /// `transcribeTeachableLectures` where `cancel_ai_work` can stop it; each
    /// row shows its own progress or failure.
    @discardableResult
    func importTeachableCourse(url: String, intoCourse: String? = nil, waitForTranscripts: Bool = true) async -> String? {
        urlInput = ""
        playlistImportBannerHidden = false
        playlistImportStatus = "Reading the course…"
        defer { playlistImportStatus = nil }

        guard let lectureURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              TeachableCourseService.isLectureURL(lectureURL.absoluteString) else {
            errorMessage = "That is not a Teachable lecture link."
            return nil
        }

        do {
            let first = try await TeachableCourseService.fetchLecturePage(lectureURL)
            let outline = first.allLectures.isEmpty
                ? [TeachableCourseService.LectureLink(id: first.lectureID, url: first.url, title: first.title)]
                : first.allLectures
            let courseTitle = first.courseTitle
                ?? first.sections.first?.title
                ?? first.title

            let courseName: String
            if let intoCourse {
                courseName = intoCourse
            } else if let existing = existingCourseID(forTitle: courseTitle) {
                courseName = existing
            } else {
                courseName = UUID().uuidString
                var metadata = CourseMetadata()
                metadata.title = courseTitle
                courseMetadata[courseName] = metadata
                userCourseNames.insert(courseName)
                saveUserCourseNames()
                try await storage.saveCourseGroup(name: courseName, metadata: metadata)
            }
            importingCourseNames.insert(courseName)
            defer { importingCourseNames.remove(courseName) }
            playlistImportStatus = "Importing “\(courseDisplayName(courseName))”…"

            // Read each lecture once: its heading is the source's title and
            // its attachments say whether it has a video at all.
            var pages: [TeachableCourseService.LecturePage] = []
            var failures: [String] = []
            for link in outline {
                if link.id == first.lectureID {
                    pages.append(first)
                    continue
                }
                do {
                    pages.append(try await TeachableCourseService.fetchLecturePage(link.url))
                } catch {
                    failures.append("\(link.title.isEmpty ? link.url.absoluteString : link.title): \(error.localizedDescription)")
                }
            }
            let videoPages = pages.filter(\.hasVideo)

            var tally = PlaylistImportTally()
            var usedLectureIds = Set<String>()
            for (position, page) in videoPages.enumerated() {
                let sourceURL = TeachableCourseService.canonicalLectureURL(page.url).absoluteString
                do {
                    let articleId: String?
                    if let existingIndex = existingArticleIndex(matchingSourceURL: sourceURL) {
                        articleId = articles[existingIndex].id
                    } else {
                        var article = StudioArticle(
                            url: sourceURL,
                            title: page.title,
                            sourceType: .video,
                            discoveryOrigin: .manual
                        )
                        article.domain = page.url.host ?? article.domain
                        if try await storage.insertSourceIfNew(&article) {
                            articles.insert(article, at: tally.added)
                            articleId = article.id
                        } else if let revivedID = try await storage.unarchiveSourceMatchingURL(
                            sourceURL,
                            clearingDismissal: true
                        ) {
                            await refreshArticles()
                            articleId = articles.contains(where: { $0.id == revivedID }) ? revivedID : nil
                            tally.revived += 1
                        } else if try await storage.insertSourceIfNew(&article) {
                            articles.insert(article, at: tally.added)
                            articleId = article.id
                            tally.revived += 1
                        } else {
                            articleId = nil
                        }
                    }
                    guard let articleId else { continue }
                    let lecture = await playlistItemLecture(
                        in: courseName,
                        title: page.title,
                        playlistPosition: position + 1,
                        existingArticle: articles.first { $0.id == articleId },
                        usedLectureIds: usedLectureIds
                    )
                    if let lecture {
                        usedLectureIds.insert(lecture.id)
                        tally.lectureIdsInOrder.append(lecture.id)
                        await moveArticle(articleId, toLecture: lecture.id, inCourse: courseName)
                        await updateLectureItemSortIndex(articleId: articleId, lectureId: lecture.id, sortIndex: 0)
                        tally.added += 1
                    }
                } catch {
                    logger.error("Teachable import could not add lecture \(page.lectureID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failures.append("\(page.title): \(error.localizedDescription)")
                }
            }

            guard tally.added > 0 else {
                if intoCourse == nil, courseLectures(for: courseName).isEmpty {
                    await discardEmptyPlaylistCourse(courseName)
                }
                if let failure = failures.first {
                    errorMessage = "Couldn’t import “\(courseTitle)”: \(failure)"
                } else if videoPages.isEmpty {
                    errorMessage = "“\(courseTitle)” has no video lectures to import."
                } else {
                    errorMessage = "Every video lecture of “\(courseTitle)” is already in your library."
                }
                return nil
            }

            await normalizePlaylistLectureOrder(tally.lectureIdsInOrder, in: courseName)
            await refreshArticles()
            openCourse(courseName)
            if let firstLecture = courseLectures(for: courseName).first,
               let firstItem = courseLectureItems(for: firstLecture.id).first,
               let firstId = firstItem.sourceId {
                selectedArticleId = firstId
            }
            logger.info("Imported \(tally.added) Teachable lectures into '\(courseTitle, privacy: .public)'")

            let courseSourceIds = Set(courseLectures(for: courseName)
                .flatMap { courseLectureItems(for: $0.id) }
                .compactMap(\.sourceId))
            let pending = articles
                .filter { courseSourceIds.contains($0.id) && $0.sourceType == .video && $0.content == nil }
                .map(\.id)
            if waitForTranscripts {
                for (index, articleId) in pending.enumerated() {
                    playlistImportStatus = "Transcribing lecture \(index + 1) of \(pending.count)…"
                    await fetchTeachableTranscript(for: articleId)
                }
                playlistImportStatus = "Saving course to iCloud…"
                let unsynced = await storage.syncCloudKitNowAndWaitForDrain()
                if unsynced > 0 {
                    errorMessage = "The course is saved on this Mac, but \(unsynced) iCloud change\(unsynced == 1 ? " is" : "s are") still waiting to sync. Keep ForeverLM open and online."
                }
            }
            if !failures.isEmpty {
                errorMessage = "Added \(tally.added) lecture\(tally.added == 1 ? "" : "s") to “\(courseTitle)”. \(failures.count) couldn’t be read: \(failures[0])"
            }
            return courseName
        } catch {
            errorMessage = error.localizedDescription
            logger.warning("Teachable course import failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
